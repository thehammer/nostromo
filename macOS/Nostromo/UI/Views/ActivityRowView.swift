import AppKit
import NostromoKit

// MARK: - ActivityRowView

/// One activity row of the Focus view (PRD "The activity row"; FV contract §2.5) as a single
/// island of `ChatTurnView`: a fixed 22 pt row, and, once expanded, the **activity lane**: a
/// 2 pt rule at the row's inset with the segment's members 12 pt past it, in original order.
/// Folded messages are `TextBlockView`s in the folded tone (`Theme.foldedProse`); tool groups
/// are TF2's `ToolGroupView`s, collapsed unless the pane's resolver opens them.
///
/// The lane is built **lazily on first expand**: a collapsed row holds the row alone, so its
/// cost does not depend on how much it folds, folded prose is never laid out, and no text the
/// operator cannot see is in the view tree to be selected or copied. Members are kept (hidden)
/// when it collapses again, until the turn view itself goes.
///
/// Laid out like `ToolGroupView`: members are frame-positioned and each measured detached with
/// `ChatTurnView.measureIsland`, and this view's height is arithmetic over cached heights.
///
/// Classification is `FocusPlanner`'s: this view only renders the segment it is handed.
final class ActivityRowView: NSView, TurnIsland, ArithmeticIsland, WidthPresettable {

    /// The lane's rule: at the row's inset (x = 0 here), this wide.
    static let laneRuleWidth: CGFloat = 2
    /// Where lane members start: past the rule, one 12 pt step.
    static let laneInset: CGFloat = laneRuleWidth + 12
    /// Space between the row and the first member, and between members.
    static let memberSpacing: CGFloat = TurnHeightEstimator.blockSpacing

    let row: ActivityRowHeaderView
    var segment: ActivitySegment { row.segment }
    private(set) var isExpanded: Bool
    /// The lane's rule. Hidden while collapsed.
    let laneRule = NSView()

    /// The operator toggled the row (the new state). Already applied to this view.
    var onToggle: ((Bool) -> Void)?
    /// The operator toggled a tool group inside the lane.
    var onGroupToggle: ((_ groupKey: String, _ isExpanded: Bool) -> Void)?
    /// A result (or agent activity) fold inside a lane group was toggled.
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?
    /// A lane member changed height by itself; this view re-measured it already.
    var onHeightChange: (() -> Void)?
    /// A lane group is about to build its next batch of rows (see `ToolGroupView`).
    var onBatchWillBuild: (() -> Void)?

    /// Where Copy Messages / Copy Commands / Copy Summary put text. Injectable for tests.
    var pasteboard: NSPasteboard {
        get { row.pasteboard }
        set { row.pasteboard = newValue }
    }

    /// The blocks the segment's members use, by block index (see `ToolGroupView.blocks`).
    private var blocks: [Int: TurnBlock]
    private let contentAvailable: Bool
    private var folds: FoldResolver
    private let reduceMotion: () -> Bool
    private let now: () -> Date
    private let approvals: ApprovalStore?
    private let backgroundTasks: BackgroundRowBinding?

    private struct Member {
        /// Anchor key: the message key (`<segmentKey>/m<ordinal>`) for a message's first text
        /// block, `b<i>` for its later ones, the group key for a group.
        let key: String
        let view: NSView
        let widthConstraint: NSLayoutConstraint
        var height: CGFloat
        /// The text block this member shows (messages only).
        let blockIndex: Int?
    }

    private var members: [Member] = []
    /// Group id → its index in `members`.
    private var groupSlots: [Int: Int] = [:]
    /// Segment members (a message or a group) that have views. The lane is built when > 0 or
    /// once expanded.
    private var builtSegmentMembers = 0
    private var laneBuilt = false
    /// The island width; lane members are `laneInset` narrower. 0 before any.
    private var width: CGFloat = 0
    /// Members exist but were measured at another width (resized while collapsed).
    private var membersStale = false

    init(segment: ActivitySegment, blocks: [Int: TurnBlock], contentAvailable: Bool,
         folds: FoldResolver, isExpanded: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         now: @escaping () -> Date = Date.init, approvals: ApprovalStore? = nil,
         backgroundTasks: BackgroundRowBinding? = nil) {
        self.blocks = blocks
        self.contentAvailable = contentAvailable
        self.folds = folds
        self.isExpanded = isExpanded
        self.reduceMotion = reduceMotion
        self.now = now
        self.approvals = approvals
        self.backgroundTasks = backgroundTasks
        row = ActivityRowHeaderView(segment: segment, isExpanded: isExpanded,
                                    payloadAvailable: contentAvailable, reduceMotion: reduceMotion,
                                    approvals: approvals, backgroundTasks: backgroundTasks)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        row.subagentToolUseIds = subagentToolUseIds(of: segment)
        row.blockText = { [weak self] index in
            guard case .text(let text)? = self?.blocks[index] else { return nil }
            return text
        }
        row.translatesAutoresizingMaskIntoConstraints = true
        addSubview(row)
        row.onToggle = { [weak self] expanded in
            guard let self else { return }
            self.applyExpanded(expanded)
            self.onToggle?(expanded)
        }

        laneRule.wantsLayer = true
        laneRule.layer?.backgroundColor = Theme.foldLaneRule.cgColor
        laneRule.isHidden = true
        addSubview(laneRule)

        if isExpanded { syncLane() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    /// The lane's member views, in display order. Empty until the first expand.
    var laneMemberViews: [NSView] { members.map(\.view) }

    /// The lane's tool groups, in order. Empty until the first expand.
    var laneGroupViews: [ToolGroupView] { members.compactMap { $0.view as? ToolGroupView } }

    /// The lane group with this key, if the lane is built and has it.
    func groupView(forKey key: String) -> ToolGroupView? {
        laneGroupViews.first { $0.group.key == key }
    }

    /// Open or close without it counting as the operator's click (no `onToggle`).
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        row.setExpanded(expanded, animated: false)
        applyExpanded(expanded)
    }

    /// The turn's fold state as it is now, for lane members built from here on (members already
    /// built keep theirs).
    func updateState(folds: FoldResolver) {
        self.folds = folds
    }

    /// Re-resolve the lane's groups (a change made elsewhere). Returns whether any changed.
    @discardableResult
    func applyFolds(_ folds: FoldResolver) -> Bool {
        self.folds = folds
        var changed = false
        for i in members.indices {
            guard let group = members[i].view as? ToolGroupView else { continue }
            var touched = group.applyResultFolds(folds)
            let expanded = folds.isExpanded(group.group)
            if expanded != group.isExpanded {
                group.setExpanded(expanded)
                touched = true
            }
            guard touched else { continue }
            remeasureMember(at: i)
            changed = true
        }
        return changed
    }

    /// The segment as it stands: the counts update in place (the row's height never changes),
    /// and members that joined append to a built lane. `blockAt` reads the turn's blocks during
    /// the call only. Returns whether this view's height changed.
    @discardableResult
    func update(segment: ActivitySegment, blockAt: (Int) -> TurnBlock?) -> Bool {
        takeBlocks(of: segment, from: blockAt)
        row.subagentToolUseIds = subagentToolUseIds(of: segment)
        row.update(segment: segment)
        guard laneBuilt else { return false }
        let before = contentHeight
        // Groups already in the lane that changed (a quiet completion, a late result).
        for case .group(let group) in segment.members.prefix(builtSegmentMembers) {
            guard let slot = groupSlots[group.id], let view = members[slot].view as? ToolGroupView,
                  view.group != group else { continue }
            if view.update(group: group, blockAt: { self.blocks[$0] }) { remeasureMember(at: slot) }
        }
        syncLane()
        return contentHeight != before
    }

    // MARK: - Lane

    private func subagentToolUseIds(of segment: ActivitySegment) -> [String] {
        segment.members.flatMap { member -> [String] in
            guard case .group(let group) = member else { return [] }
            return group.subagentBlocks.values.flatMap { $0 }.compactMap { index in
                guard case .toolCall(let call)? = blocks[index] else { return nil }
                return call.toolUseId
            }
        }
    }

    private func takeBlocks(of segment: ActivitySegment, from blockAt: (Int) -> TurnBlock?) {
        Self.collectBlocks(of: segment, from: blockAt, into: &blocks)
    }

    /// The blocks `segment`'s members use, by block index, added to `blocks` (those already
    /// there are kept: blocks are append-only).
    static func collectBlocks(of segment: ActivitySegment, from blockAt: (Int) -> TurnBlock?,
                              into blocks: inout [Int: TurnBlock]) {
        func take(_ index: Int) {
            if blocks[index] == nil { blocks[index] = blockAt(index) }
        }
        for member in segment.members {
            switch member {
            case .message(let message):
                message.blockIndices.forEach(take)
            case .group(let group):
                group.memberIndices.forEach(take)
                for indices in group.subagentBlocks.values { indices.forEach(take) }
            }
        }
    }

    private func applyExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded { releaseFocus(from: members.map(\.view), to: row) }
        // Hidden at once, not at the next layout pass: a collapsed row must hold no visible (or
        // selectable) member text in between.
        for member in members { member.view.isHidden = !expanded }
        if expanded {
            if membersStale { remeasureMembers() }
            syncLane()
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Build views for the segment members that have none yet. Only once the row has been
    /// expanded: until then the lane does not exist.
    private func syncLane() {
        guard isExpanded || laneBuilt else { return }
        laneBuilt = true
        let all = segment.members
        while builtSegmentMembers < all.count {
            switch all[builtSegmentMembers] {
            case .message(let message):
                appendMessage(message)
            case .group(let group):
                groupSlots[group.id] = members.count
                appendMember(key: group.key, view: makeGroupView(group), blockIndex: nil)
            }
            builtSegmentMembers += 1
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Whether a folded message's block gets a view in the lane: visible text only (the
    /// estimator's `FoldShape` asks the same).
    static func showsInLane(_ block: TurnBlock) -> Bool {
        guard case .text(let text) = block else { return false }
        return text.contains { !$0.isWhitespace }
    }

    /// A folded message: one `TextBlockView` per non-empty text block, in the folded tone.
    private func appendMessage(_ message: MessageRef) {
        var first = true
        for index in message.blockIndices {
            guard let block = blocks[index], Self.showsInLane(block), case .text(let text) = block else { continue }
            let key = first ? "\(segment.key)/m\(message.ordinal)" : "b\(index)"
            first = false
            appendMember(key: key, view: TextBlockView(text: text, tone: .folded), blockIndex: index)
        }
    }

    private func makeGroupView(_ group: ToolGroup) -> ToolGroupView {
        let view = ToolGroupView(group: group, blockAt: { self.blocks[$0] },
                                 contentAvailable: contentAvailable, folds: folds,
                                 isExpanded: folds.isExpanded(group), reduceMotion: reduceMotion, now: now,
                                 approvals: approvals, backgroundTasks: backgroundTasks)
        view.onToggle = { [weak self, weak view] isExpanded in
            guard let self, let view else { return }
            self.folds.groupStates[view.group.key] = isExpanded
            self.memberChangedHeight(view)
            self.onGroupToggle?(view.group.key, isExpanded)
        }
        view.onBlockExpansion = { [weak self] index, isExpanded in self?.onBlockExpansion?(index, isExpanded) }
        view.onHeightChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.memberChangedHeight(view)
            self.onHeightChange?()
        }
        view.onBatchWillBuild = { [weak self] in self?.onBatchWillBuild?() }
        return view
    }

    private func appendMember(key: String, view: NSView, blockIndex: Int?) {
        view.translatesAutoresizingMaskIntoConstraints = true
        let constraint = view.widthAnchor.constraint(equalToConstant: max(laneWidth, 1))
        constraint.isActive = true
        // Measured before it is attached (see `ToolGroupView.insertMember`).
        let height = width > 0 ? ChatTurnView.measureIsland(view, width: laneWidth) : 0
        view.isHidden = !isExpanded
        addSubview(view)
        members.append(Member(key: key, view: view, widthConstraint: constraint, height: height,
                              blockIndex: blockIndex))
    }

    private func memberChangedHeight(_ view: NSView) {
        guard let i = members.firstIndex(where: { $0.view === view }) else { return }
        remeasureMember(at: i)
    }

    private func remeasureMember(at i: Int) {
        guard width > 0 else { return }
        members[i].height = ChatTurnView.measureIsland(members[i].view, width: laneWidth)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func remeasureMembers() {
        membersStale = false
        guard width > 0 else { return }
        for i in members.indices {
            members[i].widthConstraint.constant = laneWidth
            members[i].height = ChatTurnView.measureIsland(members[i].view, width: laneWidth)
        }
    }

    // MARK: - Geometry

    private var laneWidth: CGFloat { max(width - Self.laneInset, 1) }

    func presetLayoutWidth(_ width: CGFloat) {
        guard abs(width - self.width) > 0.5 else { return }
        self.width = width
        // Measured only while visible: a collapsed row's cost stays one row.
        if isExpanded { remeasureMembers() } else { membersStale = !members.isEmpty }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func arithmeticHeight(atWidth width: CGFloat) -> CGFloat {
        presetLayoutWidth(width)
        return contentHeight
    }

    func setIslandWidth(_ width: CGFloat) { presetLayoutWidth(width) }

    func islandHeight() -> CGFloat { contentHeight }

    override var isFlipped: Bool { true }

    private var contentHeight: CGFloat {
        var height = FoldRowView.height
        if isExpanded {
            for member in members { height += Self.memberSpacing + member.height }
        }
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    /// Each shown member with its top, in order, until `body` returns a value.
    private func firstMember<T>(where body: (_ member: Member, _ top: CGFloat) -> T?) -> T? {
        guard isExpanded else { return nil }
        var y = FoldRowView.height
        for member in members {
            y += Self.memberSpacing
            if let found = body(member, y) { return found }
            y += member.height
        }
        return nil
    }

    func anchorItem(atY y: CGFloat) -> (key: String, offset: CGFloat)? {
        if y < FoldRowView.height { return (segment.key, y) }
        if let found = firstMember(where: { member, top in
            top + member.height > y ? (member.key, y - top) : nil
        }) { return found }
        // Past the last member (or collapsed and below the row): nothing here.
        return isExpanded && !members.isEmpty ? nil : (segment.key, y)
    }

    func offset(ofItemKey key: String) -> CGFloat? {
        if key == segment.key { return 0 }
        let block = key.hasPrefix("b") ? Int(key.dropFirst()) : nil
        if let shown = firstMember(where: { member, top -> CGFloat? in
            if member.key == key || (block != nil && member.blockIndex == block) { return top }
            guard let block, let group = member.view as? ToolGroupView else { return nil }
            if let inside = group.offset(ofMemberBlock: block) { return top + inside }
            // In a collapsed lane group: its row stands in for it.
            return group.group.memberIndices.contains(block) ? top : nil
        }) { return shown }
        // Folded away (the row is collapsed, or its lane not built): the row stands in for what
        // it holds, so an anchor on a message or group that just rolled in stays put.
        return holds(itemKey: key, block: block) ? 0 : nil
    }

    /// Whether `key` (a message key, a group key or `b<i>`) names something in this segment.
    private func holds(itemKey key: String, block: Int?) -> Bool {
        segment.members.contains { member in
            switch member {
            case .message(let message):
                return key == "\(segment.key)/m\(message.ordinal)"
                    || block.map(message.blockIndices.contains) == true
            case .group(let group):
                return key == group.key
                    || block.map { b in group.memberIndices.contains(b) || group.subagentBlocks.values.contains { $0.contains(b) } } == true
            }
        }
    }

    func rowRect(forGroupKey key: String) -> NSRect? {
        firstMember { member, top in
            guard let group = member.view as? ToolGroupView, group.group.key == key else { return nil }
            return NSRect(x: Self.laneInset, y: top, width: laneWidth, height: FoldRowView.height)
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        row.setFrameIfChanged(NSRect(x: 0, y: 0, width: width, height: FoldRowView.height))
        var y = FoldRowView.height
        for member in members {
            member.view.isHidden = !isExpanded
            guard isExpanded else { continue }
            y += Self.memberSpacing
            member.view.setFrameIfChanged(NSRect(x: Self.laneInset, y: y, width: laneWidth, height: member.height))
            y += member.height
        }
        laneRule.isHidden = !isExpanded || members.isEmpty
        if !laneRule.isHidden {
            let top = FoldRowView.height + Self.memberSpacing
            laneRule.setFrameIfChanged(NSRect(x: 0, y: top, width: Self.laneRuleWidth, height: max(0, y - top)))
        }
    }

    // MARK: - Copy

    /// Copy Messages: the folded messages' full text, in order, a blank line between.
    func copyMessages() { row.copyMessages() }
    /// Copy Commands: every call's complete input, across the row's groups.
    func copyCommands() { row.copyCommands() }
    /// Copy Summary: what the row reads.
    func copySummary() { row.copySummary() }
}

// MARK: - ActivityRowHeaderView

/// The activity row's 22 pt row: `3 messages, ran 9 commands, +4 more`, then `· N failed` in the
/// failure colour, then `· 41 s` (`ActivitySummary`). A disclosure triangle for VoiceOver, with
/// the full summary as its label.
final class ActivityRowHeaderView: FoldRowView {

    private(set) var segment: ActivitySegment
    private let payloadAvailable: Bool
    /// A block's text, for Copy Messages (set by `ActivityRowView`).
    var blockText: (Int) -> String? = { _ in nil }

    init(segment: ActivitySegment, isExpanded: Bool, payloadAvailable: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         approvals: ApprovalStore? = nil, backgroundTasks: BackgroundRowBinding? = nil) {
        self.segment = segment
        self.payloadAvailable = payloadAvailable
        super.init(reduceMotion: reduceMotion)
        attachApprovals(approvals)
        attachBackgroundTasks(backgroundTasks)
        update(segment: segment)
        setExpanded(isExpanded, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var approvalToolUseIds: [String] { segment.calls.compactMap(\.toolUseId) }

    /// `tool_use_id`s of the calls subagents made under the segment's Agent/Task calls: a task one of them
    /// started shows its `◷` on this row too (set by `ActivityRowView`, which holds the blocks).
    var subagentToolUseIds: [String] = [] {
        didSet { if subagentToolUseIds != oldValue { refreshBackground() } }
    }

    override var backgroundToolUseIds: [String] { approvalToolUseIds + subagentToolUseIds }

    /// Show `segment` as it stands. In place: the row's height never changes, and nothing is
    /// announced (no announcement per roll-in).
    func update(segment: ActivitySegment) {
        self.segment = segment
        refreshApproval()
        refreshBackground()
        setSummary(ActivitySummary.title(for: segment))
        setFailure(ActivitySummary.failureText(for: segment))
        setTime(ActivitySummary.durationText(for: segment))
    }

    // MARK: Copy

    override func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Messages", action: #selector(copyMessagesAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Commands", action: #selector(copyCommandsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Summary", action: #selector(copySummaryAction), keyEquivalent: "").target = self
        if let open = openInBackgroundActivityItem() { menu.addItem(open) }
        TranscriptViewMenu.appendModeItems(to: menu)
        return menu
    }

    @objc private func copyMessagesAction() { copyMessages() }
    @objc private func copyCommandsAction() { copyCommands() }
    @objc private func copySummaryAction() { copySummary() }

    /// The folded messages' full text, verbatim.
    func copyMessages() {
        put(ActivitySummary.messagesText(for: segment, blockText: blockText))
    }

    /// Every call's complete input across the row's groups, verbatim.
    func copyCommands() {
        put(ActivitySummary.commandsText(for: segment, payloadAvailable: payloadAvailable))
    }

    override func copySummary() {
        put(ActivitySummary.plainText(for: segment))
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { accessibilityLabel(adding: ActivitySummary.accessibilityLabel(for: segment)) }
}
