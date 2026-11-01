import AppKit
import Combine
import NostromoKit

// MARK: - ToolGroupView

/// One tool group as a single island of `ChatTurnView`: its row, and, once expanded, its
/// members exactly as they rendered before folding (`ToolCallView`, `ToolResultView`, and an
/// `AgentActivityView` under an Agent/Task call that has subagent blocks).
///
/// Collapsed, it holds only the row, so its layout cost does not depend on the group's size:
/// a 60-call group costs what a 1-call group costs. Members are built on first expand and
/// kept (hidden) when collapsed again, until the turn view itself goes.
///
/// Opening a large group builds the first `memberBatchSize` members at once (more than a
/// pane shows) and the rest in batches on the next main-queue turns, with estimated heights
/// standing in for them meanwhile so the group is about its final height from the first
/// pass. Building and measuring every member of a 60-call group in the click's own pass was
/// most of what that click cost.
///
/// Laid out like `ChatTurnView`: members are frame-positioned and each measured detached with
/// `ChatTurnView.measureIsland`, so no constraint links one member to another, and this
/// view's own height is arithmetic over cached member heights. It occupies the block column
/// (members keep today's x and width); the 2 pt leading rule sits in the turn's gutter, to
/// the left of the column.
final class ToolGroupView: NSView, WidthPresettable, ArithmeticIsland {

    /// Space between the row and the first member, and between members.
    static let memberSpacing: CGFloat = TurnHeightEstimator.blockSpacing
    /// The leading rule's x, inside the turn's 14 pt gutter.
    static let ruleX: CGFloat = -8
    static let ruleWidth: CGFloat = 2
    /// Members built in the pass that opens the group, and in each later batch: about twelve
    /// calls with their results.
    static let memberBatchSize = 24

    /// Runs the next batch of member building: the main queue's next turn. Tests inject theirs.
    var scheduleBatch: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    let row: ToolGroupRowView
    private(set) var group: ToolGroup

    /// The operator toggled the group (the new state). Already applied to this view.
    var onToggle: ((Bool) -> Void)?
    /// A member result (or agent activity) fold was toggled: its block index and new state.
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?
    /// A member changed height; the group re-measured it already.
    var onHeightChange: (() -> Void)?
    /// A batch of member building is about to change this view's height on its own (no click
    /// caused it), so the owner can note the reading position first.
    var onBatchWillBuild: (() -> Void)?

    /// The blocks this group shows (members and subagent blocks), by block index. Copied
    /// out of the turn's array rather than holding the array: a view that kept it would
    /// make every block the session appends to that turn copy the whole array.
    private var blocks: [Int: TurnBlock] = [:]
    private let contentAvailable: Bool
    /// How the turn's result folds resolve (the operator's saved choices), for members built from here on.
    private var folds: FoldResolver
    private(set) var isExpanded: Bool

    private enum MemberKey: Equatable {
        case block(Int)
        /// The `AgentActivityView` under the Agent/Task call at this block index.
        case activity(Int)
    }

    private struct Member {
        let key: MemberKey
        let view: NSView
        let widthConstraint: NSLayoutConstraint
        var height: CGFloat
    }

    private var members: [Member] = []
    /// How many of `group.memberIndices` have a member view.
    private var builtMemberCount = 0
    /// The width member heights were measured at; 0 before any.
    private var memberWidth: CGFloat = 0
    /// Set when members exist but were measured at another width (resized while collapsed).
    private var membersStale = false
    /// A batch of member building is scheduled.
    private var batchPending = false
    /// Estimated height of the members not built yet (with their spacing).
    private var unbuiltEstimate: CGFloat = 0
    private let rule = NSView()

    convenience init(group: ToolGroup, blocks: [TurnBlock],
                     contentAvailable: Bool, folds: FoldResolver, isExpanded: Bool,
                     reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                     now: @escaping () -> Date = Date.init, approvals: ApprovalStore? = nil) {
        self.init(group: group, blockAt: { blocks.indices.contains($0) ? blocks[$0] : nil },
                  contentAvailable: contentAvailable, folds: folds, isExpanded: isExpanded,
                  reduceMotion: reduceMotion, now: now, approvals: approvals)
    }

    /// `blockAt`: the turn's block at an index (read during the call only).
    init(group: ToolGroup, blockAt: (Int) -> TurnBlock?,
         contentAvailable: Bool, folds: FoldResolver, isExpanded: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         now: @escaping () -> Date = Date.init, approvals: ApprovalStore? = nil) {
        self.group = group
        self.contentAvailable = contentAvailable
        self.folds = folds
        self.isExpanded = isExpanded
        self.row = ToolGroupRowView(group: group, isExpanded: isExpanded, payloadAvailable: contentAvailable,
                                    reduceMotion: reduceMotion, now: now, approvals: approvals)
        super.init(frame: .zero)
        takeBlocks(of: group, from: blockAt)
        row.subagentToolUseIds = subagentToolUseIds(of: group)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        // The rule lives in the turn's gutter, outside these bounds.
        clipsToBounds = false
        layer?.masksToBounds = false

        row.translatesAutoresizingMaskIntoConstraints = true
        addSubview(row)
        row.onToggle = { [weak self] expanded in
            guard let self else { return }
            self.applyExpanded(expanded)
            self.onToggle?(expanded)
        }

        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.borderInactive.cgColor
        rule.isHidden = true
        addSubview(rule)

        if isExpanded { syncMembers() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Member views built so far, in display order. Empty until the first expand.
    var memberViews: [NSView] { members.map(\.view) }

    /// Every member has a view (none is waiting for a batch).
    var isFullyBuilt: Bool { builtMemberCount == group.memberIndices.count }

    /// Open or close without it counting as the operator's click (no `onToggle`).
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        row.setExpanded(expanded, animated: false)
        applyExpanded(expanded)
    }

    /// Follow the result folds (and subagent-activity folds) in `folds`: a change made elsewhere
    /// (another window). Not the operator's click, so `onBlockExpansion` stays quiet; members built
    /// from here on use `folds` too. Returns whether any member changed.
    @discardableResult
    func applyResultFolds(_ folds: FoldResolver) -> Bool {
        self.folds = folds
        var changed = false
        for i in members.indices {
            let followed: Bool
            switch members[i].key {
            case .block(let index):
                guard let result = members[i].view as? ToolResultView else { continue }
                followed = result.apply(explicitState: folds.explicitResult(block: blocks[index], index: index))
            case .activity(let agentIndex):
                guard let activity = members[i].view as? AgentActivityView else { continue }
                followed = activity.apply(explicitState: folds.explicitResult(block: blocks[agentIndex], index: agentIndex))
            }
            if followed {
                remeasureMember(at: i)
                changed = true
            }
        }
        return changed
    }

    /// The group grew (or its counts changed). Returns whether this view's height changed.
    @discardableResult
    func update(group: ToolGroup, blocks: [TurnBlock]) -> Bool {
        update(group: group, blockAt: { blocks.indices.contains($0) ? blocks[$0] : nil })
    }

    /// `update(group:blocks:)`, with the turn's blocks by lookup.
    @discardableResult
    func update(group: ToolGroup, blockAt: (Int) -> TurnBlock?) -> Bool {
        self.group = group
        takeBlocks(of: group, from: blockAt)
        row.subagentToolUseIds = subagentToolUseIds(of: group)
        row.update(group: group)
        guard isExpanded else { return false }
        let before = contentHeight
        // While batches are still building the members, the next batch picks these up too.
        if batchPending { estimateUnbuilt() } else { syncMembers() }
        return contentHeight != before
    }

    // MARK: - Members

    /// The calls subagents made under this group's Agent/Task members: their approval requests show on this row.
    private func subagentToolUseIds(of group: ToolGroup) -> [String] {
        group.subagentBlocks.values.flatMap { $0 }.compactMap { index -> String? in
            guard case .toolCall(let call)? = blocks[index] else { return nil }
            return call.toolUseId
        }
    }

    private func takeBlocks(of group: ToolGroup, from blockAt: (Int) -> TurnBlock?) {
        for index in group.memberIndices.reversed() {
            guard blocks[index] == nil else { break }   // members only ever grow at the end
            blocks[index] = blockAt(index)
        }
        for indices in group.subagentBlocks.values {
            for index in indices where blocks[index] == nil { blocks[index] = blockAt(index) }
        }
    }

    private func applyExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded { releaseFocus(from: members.map(\.view), to: row) }
        // Hidden at once, not at the next layout pass: a collapsed group must hold no
        // visible (or selectable) member text in between.
        for member in members { member.view.isHidden = !expanded }
        if expanded {
            // Existing members first, so the ones `syncMembers` adds are measured once.
            if membersStale { remeasureMembers() }
            syncMembers(limit: Self.memberBatchSize)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Build member views for members the group gained since (at most `limit` of them, the
    /// rest in later batches), and keep agent activity in step with the subagent blocks.
    private func syncMembers(limit: Int = .max) {
        let indices = group.memberIndices
        var built = 0
        while builtMemberCount < indices.count, built < limit {
            let index = indices[builtMemberCount]
            builtMemberCount += 1
            built += 1
            appendMember(.block(index), view: makeMemberView(at: index))
        }
        for (agentIndex, subagent) in group.subagentBlocks {
            if let i = members.firstIndex(where: { $0.key == .activity(agentIndex) }) {
                let view = members[i].view as! AgentActivityView
                guard view.blockIndices != subagent else { continue }
                view.update(blockIndices: subagent, blocks: blocks)
                remeasureMember(at: i)
            } else if let callPosition = members.firstIndex(where: { $0.key == .block(agentIndex) }) {
                insertMember(.activity(agentIndex), view: makeActivityView(agentIndex: agentIndex, blockIndices: subagent),
                             at: callPosition + 1)
            }
        }
        estimateUnbuilt()
        if !isFullyBuilt && !batchPending {
            batchPending = true
            scheduleBatch { [weak self] in self?.buildNextBatch() }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The next batch: build, then tell the turn the group's height changed (estimates became
    /// measurements). Stops while the group is closed; opening it again carries on.
    private func buildNextBatch() {
        batchPending = false
        guard isExpanded, !isFullyBuilt else { return }
        onBatchWillBuild?()
        syncMembers(limit: Self.memberBatchSize)
        onHeightChange?()
    }

    /// What the members still to be built will roughly take (`TurnHeightEstimator`'s rules).
    private func estimateUnbuilt() {
        let indices = group.memberIndices
        guard builtMemberCount < indices.count else {
            unbuiltEstimate = 0
            return
        }
        let width = max(memberWidth, 1)
        var height: CGFloat = 0
        for index in indices[builtMemberCount...] {
            guard let block = blocks[index] else { continue }
            var characters = 0
            if case .toolResult(let result) = block, result.isError { characters = result.content.utf8.count }
            height += Self.memberSpacing + TurnHeightEstimator.estimate(block: block, characters: characters, width: width)
            if group.subagentBlocks[index] != nil {
                height += Self.memberSpacing + TurnHeightEstimator.toolResultCollapsed
            }
        }
        unbuiltEstimate = height
    }

    /// The same views `ChatTurnView` built for these blocks before folding.
    private func makeMemberView(at index: Int) -> NSView {
        guard let block = blocks[index] else { return NSView() }
        switch block {
        case .toolCall(let d):
            return ToolCallView(data: d)
        case .toolResult(let d):
            let view = ToolResultView(data: d, contentAvailable: contentAvailable,
                                      explicitState: folds.explicitResult(block: block, index: index))
            view.onExpansionChange = { [weak self, weak view] isExpanded in
                guard let self, let view else { return }
                self.onBlockExpansion?(index, isExpanded)
                self.memberChangedHeight(view)
            }
            return view
        case .text, .resultSummary, .errorMessage, .askQuestion, .note:
            // The planner only puts calls and results in a group.
            assertionFailure("block \(index) is not a tool call or result")
            return NSView()
        }
    }

    private func makeActivityView(agentIndex: Int, blockIndices: [Int]) -> AgentActivityView {
        let view = AgentActivityView(blockIndices: blockIndices, blocks: blocks, contentAvailable: contentAvailable,
                                     folds: folds,
                                     startExpanded: folds.explicitResult(block: blocks[agentIndex], index: agentIndex) ?? false)
        view.onExpansionChange = { [weak self, weak view] isExpanded in
            guard let self, let view else { return }
            self.onBlockExpansion?(agentIndex, isExpanded)
            self.memberChangedHeight(view)
        }
        view.onBlockExpansion = { [weak self] index, isExpanded in self?.onBlockExpansion?(index, isExpanded) }
        view.onHeightChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.memberChangedHeight(view)
        }
        return view
    }

    private func appendMember(_ key: MemberKey, view: NSView) {
        insertMember(key, view: view, at: members.count)
    }

    private func insertMember(_ key: MemberKey, view: NSView, at position: Int) {
        view.translatesAutoresizingMaskIntoConstraints = true
        let constraint = view.widthAnchor.constraint(equalToConstant: max(memberWidth, 1))
        constraint.isActive = true
        // Measured before it is attached: `measureIsland` would otherwise detach it from a group
        // that is in the window and attach it again, and that round trip through the window's
        // constraint engine, once per member, was most of what opening a 60-call group cost.
        let height = memberWidth > 0 ? ChatTurnView.measureIsland(view, width: memberWidth) : 0
        view.isHidden = !isExpanded
        addSubview(view)
        members.insert(Member(key: key, view: view, widthConstraint: constraint, height: height), at: position)
    }

    private func memberChangedHeight(_ view: NSView) {
        guard let i = members.firstIndex(where: { $0.view === view }) else { return }
        remeasureMember(at: i)
        onHeightChange?()
    }

    private func remeasureMember(at i: Int) {
        guard memberWidth > 0 else { return }
        members[i].height = ChatTurnView.measureIsland(members[i].view, width: memberWidth)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func remeasureMembers() {
        membersStale = false
        guard memberWidth > 0 else { return }
        for i in members.indices {
            members[i].widthConstraint.constant = memberWidth
            members[i].height = ChatTurnView.measureIsland(members[i].view, width: memberWidth)
        }
    }

    // MARK: - Geometry

    func presetLayoutWidth(_ width: CGFloat) {
        guard abs(width - memberWidth) > 0.5 else { return }
        memberWidth = width
        // Measured only while visible: a collapsed group's cost stays one row.
        if isExpanded { remeasureMembers() } else { membersStale = !members.isEmpty }
        estimateUnbuilt()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    private var contentHeight: CGFloat {
        var height = ToolGroupRowView.height
        if isExpanded {
            for member in members { height += Self.memberSpacing + member.height }
            height += unbuiltEstimate
        }
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    /// The row plus the members, summed: no solve, and no detaching this view (and every member
    /// in it) from the window to ask.
    func arithmeticHeight(atWidth width: CGFloat) -> CGFloat {
        presetLayoutWidth(width)
        return contentHeight
    }

    /// Top of the member showing block `index` (a call or result), in this view's coordinates;
    /// for a subagent's block, the top of the agent-activity row that holds it. Nil when the
    /// group is collapsed or shows no such block.
    func offset(ofMemberBlock index: Int) -> CGFloat? {
        guard isExpanded else { return nil }
        let key: MemberKey
        if group.memberIndices.contains(index) {
            key = .block(index)
        } else if let agent = group.subagentBlocks.first(where: { $0.value.contains(index) })?.key {
            key = .activity(agent)
        } else {
            return nil
        }
        var y = ToolGroupRowView.height
        for member in members {
            y += Self.memberSpacing
            if member.key == key { return y }
            y += member.height
        }
        return nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        row.setFrameIfChanged(NSRect(x: 0, y: 0, width: width, height: ToolGroupRowView.height))
        var y = ToolGroupRowView.height
        for member in members {
            member.view.isHidden = !isExpanded
            guard isExpanded else { continue }
            y += Self.memberSpacing
            member.view.setFrameIfChanged(NSRect(x: 0, y: y, width: width, height: member.height))
            y += member.height
        }
        rule.isHidden = !isExpanded || members.isEmpty
        if !rule.isHidden {
            let top = ToolGroupRowView.height + Self.memberSpacing
            rule.setFrameIfChanged(NSRect(x: Self.ruleX, y: top, width: Self.ruleWidth, height: max(0, y - top)))
        }
    }
}

// MARK: - FoldSummaryField

/// The row's summary label: selectable, so the summary copies like other transcript text,
/// but it never takes the mouse itself. The row decides whether a press is a click (toggle)
/// or a drag (forwarded here to select), and the row's pointing hand stays the cursor.
final class FoldSummaryField: CopyMenuTextField {

    // No `hitTest` override: the owning row's `hitTest` answers for its whole frame, so this
    // field is never reached by a click; the row forwards a drag to `beginSelectionDrag`.
    override func resetCursorRects() {}

    /// Start a text selection from the row's mouse-down. AppKit's own tracking loop then
    /// follows the drag to its mouse-up.
    func beginSelectionDrag(with mouseDown: NSEvent) {
        super.mouseDown(with: mouseDown)
    }
}

// MARK: - Fold container helpers

/// What `ToolGroupView` and `ActivityRowView` (frame-positioned containers of a fold row and
/// its members) both do.
extension NSView {
    /// Set the frame only when it differs, so an unchanged layout pass does no work.
    func setFrameIfChanged(_ rect: NSRect) {
        guard frame != rect else { return }
        frame = rect
    }

    /// A selection (or focus) inside a member must not outlive the collapse: ⌘C would copy
    /// hidden text. The operator just toggled `row`, so focus moves to it.
    func releaseFocus(from members: [NSView], to row: NSView) {
        guard let window, let responder = window.firstResponder as? NSView else { return }
        let editorOwner = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
        let owner = editorOwner ?? responder
        guard members.contains(where: { owner.isDescendant(of: $0) }) else { return }
        if !window.makeFirstResponder(row) { window.makeFirstResponder(nil) }
    }
}

// MARK: - FoldRowView

/// A fold's 22 pt row: disclosure triangle, summary, failure badge, time, and (for a tool group)
/// an activity dot, a call icon and `· stopped`. A control: click, Space/Return/→/← toggle it.
/// The shared base of `ToolGroupRowView` and the Focus view's `ActivityRowHeaderView`, which
/// differ only in what they say and what they copy.
///
/// Every colour is explicit (`palette`), never a semantic or system colour, so the row reads
/// the same in key and non-key windows whatever the system appearance (the Teri tab lesson).
/// Everything drawn is sanitized (`FoldTextSanitizer`); the copy actions are not.
class FoldRowView: NSView {

    static let height: CGFloat = 22
    /// A mouse-up within this distance of its mouse-down is a click; further is a drag that
    /// selects the summary text.
    static let clickSlop: CGFloat = 4
    /// Every colour the row draws with, all explicit (never semantic/system).
    static let palette: [NSColor] = [Theme.fgMuted, Theme.foldFailure, Theme.foldHover, Theme.borderInactive]
    /// The same leading inset as a call row's content (`ToolCallView`).
    static let leadingInset: CGFloat = 10
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let rotationDuration: CFTimeInterval = 0.15
    /// The activity dot's opacity pulse (one way; it autoreverses).
    static let pulseDuration: CFTimeInterval = 1.2
    static let activityDotSize: CGFloat = 6

    /// The operator toggled the row (new state).
    var onToggle: ((Bool) -> Void)?
    /// Where the copy actions and ⌘C put text. Injectable for tests.
    var pasteboard: NSPasteboard = .general

    let reduceMotion: () -> Bool
    private(set) var isExpanded = false

    private let triangleView = NSView()
    private let triangle = CAShapeLayer()
    /// The calm activity dot a running row shows before `Running`.
    private let activityView = NSView()
    let iconField = NSTextField(labelWithString: "")
    private let summary = FoldSummaryField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let stopped = NSTextField(labelWithString: "")
    private let approval = NSTextField(labelWithString: "")
    /// Where the approval status is read from (AP2b), and what the row shows of it now.
    private var approvalStore: ApprovalStore?
    private var approvalSubscription: AnyCancellable?
    private(set) var approvalStatus: ApprovalRowStatus?
    /// The activity dot is wanted (the group is running), pulsing or not.
    private var activityWanted = false
    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var forwardedDrag = false

    init(reduceMotion: @escaping () -> Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 4
        focusRingType = .default

        setUpTriangle()
        setUpActivityDot()
        setUpLabels()
        iconField.isHidden = true
        badge.isHidden = true
        time.isHidden = true
        stopped.isHidden = true
        approval.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pointer is over the row (drives the hover fill).
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            layer?.backgroundColor = isHovered ? Theme.foldHover.cgColor : nil
        }
    }

    /// The selectable label holding the summary (or header) text.
    var summaryField: NSTextField { summary }
    /// `· N failed`, hidden when nothing failed.
    var badgeField: NSTextField { badge }
    /// `· 4.1 s`, hidden when the time is unknown. While running: the running call's elapsed
    /// time (`· 42 s`) once it has run 10 s.
    var timeField: NSTextField { time }
    /// `· stopped`, shown only for a group the operator stopped mid-call.
    var stoppedField: NSTextField { stopped }
    /// `· awaiting your approval`, `· approved by you · 14:02`, …: a tool call's permission request
    /// in place (AP2b). Hidden when no call of the row has one.
    var approvalField: NSTextField { approval }
    /// The running row's activity dot.
    var activityLayer: CALayer { activityView.layer! }
    /// Whether the activity dot is showing (the group is running).
    var isShowingActivity: Bool { !activityView.isHidden }
    /// The rotating triangle (for the Reduce Motion check).
    var triangleLayer: CALayer { triangle }

    // MARK: Content (for subclasses)

    func setSummary(_ text: String) { setText(text, on: summary, color: Theme.fgMuted) }

    /// `· N failed`, or hidden for nil.
    func setFailure(_ text: String?) {
        badge.isHidden = text == nil
        setText(text.map { "· \($0)" } ?? "", on: badge, color: Theme.foldFailure)
    }

    /// `· 41 s`, or hidden for nil.
    func setTime(_ text: String?) {
        time.isHidden = text == nil
        setText(text.map { "· \($0)" } ?? "", on: time, color: Theme.fgMuted)
    }

    /// `· stopped`, or hidden for nil.
    func setStopped(_ text: String?) {
        stopped.isHidden = text == nil
        setText(text.map { "· \($0)" } ?? "", on: stopped, color: Theme.fgMuted)
    }

    /// Show or hide the activity dot. It pulses unless Reduce Motion is on, or a call of the row is
    /// waiting for the person's approval (the row says so instead of a spinner).
    func setActivity(_ active: Bool) {
        activityWanted = active
        applyActivity()
    }

    private func applyActivity() {
        guard let dot = activityView.layer else { return }
        activityView.isHidden = !activityWanted
        guard activityWanted, !reduceMotion(), approvalStatus?.isAwaiting != true else {
            dot.removeAnimation(forKey: "pulse")
            return
        }
        guard dot.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = Self.pulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }

    // MARK: Approval status (AP2b)

    /// The `tool_use_id`s of the calls this row stands for (a subclass says which).
    var approvalToolUseIds: [String] { [] }

    /// Read approval statuses from `store`: the row updates in place whenever one of its calls changes.
    /// Call before the first `refreshApproval()`.
    func attachApprovals(_ store: ApprovalStore?) {
        approvalStore = store
        approvalSubscription = store?.statusChanges.sink { [weak self] toolUseId in
            guard let self, self.approvalToolUseIds.contains(toolUseId) else { return }
            self.refreshApproval()
        }
    }

    /// Re-read the status of this row's calls. In place: the field's text and visibility, and whether the
    /// dot pulses, change; the row's height never does, and nothing is announced.
    func refreshApproval() {
        let status = approvalStore?.rowStatus(toolUseIds: approvalToolUseIds)
        guard status != approvalStatus else { return }
        approvalStatus = status
        let text = status?.text()
        approval.isHidden = text == nil
        setText(text.map { "· \($0)" } ?? "", on: approval, color: Theme.fgMuted)
        approval.setAccessibilityLabel(text)
        applyActivity()
    }

    /// `label`, then the approval status when there is one (read when the row is focused; never posted).
    func accessibilityLabel(adding label: String?) -> String? {
        guard let text = approvalStatus?.text() else { return label }
        return [label, text].compactMap { $0 }.joined(separator: ", ")
    }

    private func setUpActivityDot() {
        activityView.wantsLayer = true
        activityView.translatesAutoresizingMaskIntoConstraints = false
        activityView.layer?.backgroundColor = Theme.fgMuted.cgColor
        activityView.layer?.cornerRadius = Self.activityDotSize / 2
        activityView.isHidden = true
        NSLayoutConstraint.activate([
            activityView.widthAnchor.constraint(equalToConstant: Self.activityDotSize),
            activityView.heightAnchor.constraint(equalToConstant: Self.activityDotSize),
        ])
    }

    private func setUpTriangle() {
        triangleView.wantsLayer = true
        triangleView.translatesAutoresizingMaskIntoConstraints = false
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1.5, y: 0.5))
        path.addLine(to: CGPoint(x: 7.5, y: 4))
        path.addLine(to: CGPoint(x: 1.5, y: 7.5))
        path.closeSubpath()
        triangle.path = path
        triangle.fillColor = Theme.fgMuted.cgColor
        triangle.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        triangle.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        triangle.position = CGPoint(x: 5, y: 5)
        // Only the explicit rotation animates, never an implicit one.
        triangle.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
        triangleView.layer?.addSublayer(triangle)
        NSLayoutConstraint.activate([
            triangleView.widthAnchor.constraint(equalToConstant: 10),
            triangleView.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    private func setUpLabels() {
        iconField.font = .systemFont(ofSize: 11)
        iconField.textColor = Theme.fgMuted
        iconField.setContentHuggingPriority(.required, for: .horizontal)
        iconField.setContentCompressionResistancePriority(.required, for: .horizontal)

        summary.isSelectable = true   // copyable transcript content
        summary.font = Self.font
        summary.textColor = Theme.fgMuted
        summary.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 1
        summary.usesSingleLineMode = true
        summary.cell?.wraps = false
        summary.cell?.truncatesLastVisibleLine = true
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.menuProvider = { [weak self] in self?.contextMenu() ?? NSMenu() }

        for (field, color) in [(badge, Theme.foldFailure), (time, Theme.fgMuted), (stopped, Theme.fgMuted), (approval, Theme.fgMuted)] {
            field.font = Self.font
            field.textColor = color
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // The status can be ~190 pt wide, and the row doesn't clip: in a narrow pane it gives way too,
        // truncating at the tail, but only after the summary has (a higher resistance than the summary's).
        approval.lineBreakMode = .byTruncatingTail
        approval.maximumNumberOfLines = 1
        approval.usesSingleLineMode = true
        approval.cell?.wraps = false
        approval.cell?.truncatesLastVisibleLine = true
        approval.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 260), for: .horizontal)

        let stack = NSStackView(views: [triangleView, activityView, iconField, summary, badge, time, stopped, approval])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.leadingInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setText(_ text: String, on field: NSTextField, color: NSColor) {
        guard field.stringValue != text else { return }
        // Font and colour go in the string *and* on the cell: the field editor that takes
        // over on selection reads the cell (see `ToolCallView`).
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    // MARK: State

    /// Set the state shown, animating unless Reduce Motion is on. Does not fire `onToggle`.
    func setExpanded(_ expanded: Bool, animated: Bool) {
        let from: CGFloat = isExpanded ? -.pi / 2 : 0
        let to: CGFloat = expanded ? -.pi / 2 : 0
        isExpanded = expanded
        triangle.removeAnimation(forKey: "rotate")
        triangle.transform = CATransform3DMakeRotation(to, 0, 0, 1)
        if animated && from != to && !reduceMotion() {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Self.rotationDuration
            triangle.add(animation, forKey: "rotate")
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// What a click does: flip and tell `onToggle`.
    func toggle() {
        setExpanded(!isExpanded, animated: true)
        onToggle?(isExpanded)
    }

    // MARK: Mouse

    /// The whole row is the control: its labels never take the press.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit hands `point` over in the SUPERVIEW's coordinates (the #185 bug class).
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        forwardedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !forwardedDrag,
              distance(event.locationInWindow, down.locationInWindow) > Self.clickSlop
        else { return }
        // A drag, not a click: select the summary text, as anywhere else in the transcript.
        forwardedDrag = true
        mouseDownEvent = nil
        summary.beginSelectionDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil; forwardedDrag = false }
        guard let down = mouseDownEvent, !forwardedDrag,
              distance(event.locationInWindow, down.locationInWindow) <= Self.clickSlop
        else { return }
        toggle()
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: Keyboard

    /// Focusable from the keyboard, but a click never takes focus from the composer: the
    /// window asks this during the mouse-down it is about to deliver. Nothing else here ever
    /// makes a row first responder, so a row updating cannot either.
    override var acceptsFirstResponder: Bool {
        guard let type = NSApp?.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }

    override func keyDown(with event: NSEvent) {
        // ⌘→, ⌥←, ⌃↑… belong to someone else (FV4's Focus / Show All among them).
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 49, 36, 76:            toggle()                          // Space, Return, keypad Enter
        case 124:                   if !isExpanded { toggle() }       // →
        case 123:                   if isExpanded { toggle() }        // ←
        case 126:                   moveFocus(by: -1)                 // ↑
        case 125:                   moveFocus(by: 1)                  // ↓
        default:                    super.keyDown(with: event)
        }
    }

    /// Focus the previous/next fold row (tool group or activity row) that exists (is
    /// materialized) and shows in this pane.
    private func moveFocus(by step: Int) {
        guard let window else { return }
        let root = enclosingScrollView?.documentView ?? window.contentView ?? self
        let rows = Self.rows(in: root).sorted {
            $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
        }
        guard let i = rows.firstIndex(where: { $0 === self }), rows.indices.contains(i + step) else { return }
        let target = rows[i + step]
        window.makeFirstResponder(target)
        target.scrollToVisible(target.bounds)
    }

    private static func rows(in view: NSView) -> [FoldRowView] {
        view.subviews.flatMap { sub -> [FoldRowView] in
            if let row = sub as? FoldRowView { return sub.isHiddenOrHasHiddenAncestor ? [] : [row] }
            return rows(in: sub)
        }
    }

    /// ⌘C with the row focused (and so no text selected): the summary.
    @objc func copy(_ sender: Any?) { copySummary() }

    // MARK: Copy (for subclasses)

    func contextMenu() -> NSMenu { NSMenu() }

    func copySummary() {}

    func put(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityValue() -> Any? { isExpanded ? "expanded" : "collapsed" }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}

// MARK: - ToolGroupRowView

/// The group's row: summary (or, for a group of one, the call's own header), failure badge,
/// time; while running, the live text and the activity dot.
final class ToolGroupRowView: FoldRowView {

    private(set) var group: ToolGroup
    private let payloadAvailable: Bool
    /// The clock the running call's elapsed time is read from. Injected by tests.
    private let now: () -> Date

    init(group: ToolGroup, isExpanded: Bool, payloadAvailable: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         now: @escaping () -> Date = Date.init, approvals: ApprovalStore? = nil) {
        self.group = group
        self.payloadAvailable = payloadAvailable
        self.now = now
        super.init(reduceMotion: reduceMotion)
        attachApprovals(approvals)
        update(group: group)
        setExpanded(isExpanded, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `tool_use_id`s of subagent calls under this group's Agent/Task members (their requests belong to this row too).
    var subagentToolUseIds: [String] = [] {
        didSet { if subagentToolUseIds != oldValue { refreshApproval() } }
    }

    override var approvalToolUseIds: [String] {
        group.calls.compactMap(\.toolUseId) + subagentToolUseIds
    }

    // MARK: Content

    #if DEBUG
    /// Every `update(group:)`, so tests can hold a turn build to one summary per group.
    static var updateCount = 0
    #endif

    /// Show `group` as it stands. In place: the row's height never changes, so an update never
    /// needs a re-measure, and it posts nothing to VoiceOver (no announcement per call).
    func update(group: ToolGroup) {
        #if DEBUG
        Self.updateCount += 1
        #endif
        self.group = group
        refreshApproval()
        let running = ToolGroupSummary.runningTitle(for: group)
        if let running {
            iconField.isHidden = true
            setSummary(running)
        } else if let text = ToolGroupSummary.summary(for: group) {
            iconField.isHidden = true
            setSummary(text)
        } else if let call = group.calls.first {
            // A group of one reads as its call's own header.
            iconField.isHidden = false
            iconField.stringValue = ToolCallView.icon(for: call.name)
            setSummary(ToolGroupSummary.header(for: call))
        }
        setActivity(running != nil)
        setFailure(ToolGroupSummary.failureText(for: group))
        setStopped(ToolGroupSummary.stoppedSuffix(for: group))
        refreshElapsed()
    }

    /// Re-read the clock: the running call's elapsed time, or the settled group's duration.
    func refreshElapsed() {
        setTime(group.state == .running
            ? ToolGroupSummary.runningElapsedText(for: group, now: now())
            : ToolGroupSummary.durationText(for: group))
    }

    // MARK: Copy

    override func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Commands", action: #selector(copyCommandsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Summary", action: #selector(copySummaryAction), keyEquivalent: "").target = self
        TranscriptViewMenu.appendModeItems(to: menu)
        return menu
    }

    @objc private func copyCommandsAction() { copyCommands() }
    @objc private func copySummaryAction() { copySummary() }

    /// Every call's complete input, verbatim (never the drawn, sanitized text).
    func copyCommands() {
        put(ToolGroupSummary.commandsText(for: group, payloadAvailable: payloadAvailable))
    }

    override func copySummary() {
        put(ToolGroupSummary.plainText(for: group))
    }

    // MARK: Accessibility

    /// While running, the live text (VoiceOver reads it when the row is focused; nothing is
    /// announced per call).
    override func accessibilityLabel() -> String? {
        accessibilityLabel(adding: ToolGroupSummary.accessibilityLabel(for: group, now: now()))
    }
}

// MARK: - AgentActivityView

/// Under an Agent/Task member: the subagent's own calls, results and (dimmed) prose, behind a
/// disclosure in the result-fold style, collapsed by default. It is that call's own detail,
/// not a third fold level; its state is kept like a result fold's, under the Agent call's
/// block index.
///
/// Constraint-based inside, like `ToolResultView`, and built lazily on first expand.
final class AgentActivityView: NSView {

    var onExpansionChange: ((Bool) -> Void)?
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?
    var onHeightChange: (() -> Void)?

    private(set) var blockIndices: [Int]
    /// Its blocks by block index (see `ToolGroupView.blocks`).
    private var blocks: [Int: TurnBlock]
    private let contentAvailable: Bool
    private let folds: FoldResolver
    private(set) var isExpanded: Bool
    private let disclosure = NSButton()
    private let content = NSStackView()
    private var contentBuilt = false

    init(blockIndices: [Int], blocks: [Int: TurnBlock], contentAvailable: Bool,
         folds: FoldResolver, startExpanded: Bool) {
        self.blockIndices = blockIndices
        self.blocks = blocks
        self.contentAvailable = contentAvailable
        self.folds = folds
        self.isExpanded = startExpanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Theme.borderInactive.withAlphaComponent(0.6).cgColor

        disclosure.isBordered = false
        disclosure.target = self
        disclosure.action = #selector(toggleExpand)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .width
        content.spacing = TurnHeightEstimator.blockSpacing
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [disclosure, content])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            disclosure.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyState()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(blockIndices: [Int], blocks: [Int: TurnBlock]) {
        let added = blockIndices.dropFirst(self.blockIndices.count)
        self.blockIndices = blockIndices
        self.blocks = blocks
        if contentBuilt { for index in added { appendRow(for: index) } }
        applyState()
    }

    /// Follow a choice made elsewhere: open is `explicitState`, else closed. Quiet (not a click).
    @discardableResult
    func apply(explicitState: Bool?) -> Bool {
        let target = explicitState ?? false
        guard target != isExpanded else { return false }
        isExpanded = target
        applyState()
        return true
    }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        applyState()
        onExpansionChange?(isExpanded)
    }

    private func applyState() {
        let calls = blockIndices.filter { if case .toolCall? = blocks[$0] { return true } else { return false } }.count
        let title = calls == 0 ? "subagent activity" : "\(calls) subagent call\(calls == 1 ? "" : "s")"
        disclosure.attributedTitle = NSAttributedString(string: "\(isExpanded ? "▼" : "▶")  \(title)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.fgMuted,
        ])
        if isExpanded && !contentBuilt {
            contentBuilt = true
            for index in blockIndices { appendRow(for: index) }
        }
        content.isHidden = !isExpanded
    }

    private func appendRow(for index: Int) {
        let view: NSView
        guard let block = blocks[index] else { return }
        switch block {
        case .toolCall(let d):
            view = ToolCallView(data: d)
        case .toolResult(let d):
            let result = ToolResultView(data: d, contentAvailable: contentAvailable,
                                        explicitState: folds.explicitResult(block: block, index: index))
            result.onExpansionChange = { [weak self] isExpanded in
                self?.onBlockExpansion?(index, isExpanded)
                self?.onHeightChange?()
            }
            view = result
        case .text(let text):
            // The subagent's prose: dimmed, so it never reads as the main agent speaking.
            let label = CopyMenuTextField(labelWithString: text)
            label.isSelectable = true   // copyable transcript content
            label.font = .systemFont(ofSize: 12)
            label.textColor = Theme.fgMuted
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view = label
        case .resultSummary, .errorMessage, .askQuestion, .note:
            return
        }
        content.addArrangedSubview(view)
    }
}

// MARK: - ElapsedTicker

/// Something holding running group rows whose elapsed time needs a periodic refresh.
protocol ElapsedTicking: AnyObject {
    /// When its running rows next need a refresh after `now`; nil when nothing is running.
    func nextElapsedTick(after now: Date) -> Date?
    func refreshElapsed()
}

/// One pane's elapsed-time tick for running tool-group rows: at most once a second, and only
/// while a running call has been running for 10 s (`ChatTurnView.nextElapsedTick`).
///
/// Not a repeating timer: one one-shot at a time, aimed at the earliest moment any
/// materialized row's text changes, re-aimed after every tick and every pass. So nothing is
/// scheduled while no call is running, and the tick stops by itself when the group settles,
/// the turn completes or the view is evicted (it is no longer among `islands`). A hidden pane
/// calls `stop()`.
final class ElapsedTicker {

    /// Run `fire` after `delay` seconds; returns a cancel closure.
    typealias Schedule = (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    /// The pane's materialized turn views.
    var islands: () -> [ElapsedTicking] = { [] }
    /// Whether the pane can be seen (in a window, not hidden, not occluded). Nothing ticks
    /// while it cannot.
    var isActive: () -> Bool = { true }
    /// Ticks delivered so far.
    private(set) var fireCount = 0
    var isScheduled: Bool { cancel != nil }

    private let now: () -> Date
    private let schedule: Schedule
    private var cancel: (() -> Void)?
    private var due: Date?
    private var lastFire: Date?

    init(now: @escaping () -> Date = Date.init, schedule: @escaping Schedule = ElapsedTicker.onMainQueue) {
        self.now = now
        self.schedule = schedule
    }

    /// Aim the next tick at the earliest row that needs one, or stop when none does.
    func reevaluate() {
        guard isActive() else {
            stop()
            return
        }
        let current = now()
        guard var next = islands().compactMap({ $0.nextElapsedTick(after: current) }).min() else {
            stop()
            return
        }
        // At most once a second, whatever the clocks say.
        if let lastFire { next = max(next, lastFire.addingTimeInterval(1)) }
        if isScheduled, due == next { return }
        stop()
        due = next
        cancel = schedule(max(0, next.timeIntervalSince(current))) { [weak self] in self?.fire() }
    }

    func stop() {
        cancel?()
        cancel = nil
        due = nil
    }

    private func fire() {
        cancel = nil
        due = nil
        fireCount += 1
        lastFire = now()
        for island in islands() { island.refreshElapsed() }
        reevaluate()
    }

    static func onMainQueue(_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}

// MARK: - ToolActivityAnnouncer

/// Tells VoiceOver, once, that a tool group finished with failures, in the pane the operator
/// is working in. Nothing per call, nothing for a clean or stopped group, nothing for a pane
/// that is not focused.
final class ToolActivityAnnouncer {

    private let post: (String) -> Void
    /// Groups already settled with failures, so each is spoken at most once, whichever path
    /// reported it (a turn view, or the pane for a live turn with no view). Bounded crudely.
    private var announced: Set<String> = []
    private static let announcedLimit = 1_000

    /// `post` speaks the text; `voiceOver(from:)` is the app's.
    init(post: @escaping (String) -> Void) {
        self.post = post
    }

    func groupSettled(_ group: ToolGroup, in pane: NSView) {
        guard group.state == .settled, group.failedCount > 0 else { return }
        if announced.count >= Self.announcedLimit { announced.removeAll() }
        guard announced.insert(group.key).inserted, Self.paneHasFocus(pane) else { return }
        post(ToolGroupSummary.settledAnnouncement(failedCount: group.failedCount))
    }

    /// Forget what was spoken (the transcript was cleared).
    func reset() {
        announced.removeAll()
    }

    /// The group that `turn`'s newest block just closed: that block ends a group (non-empty
    /// prose, or anything that is not a tool call or result) and the item before it is a group.
    /// For a live turn with no view to report its groups settling. Plans the turn, so it is
    /// called only when the newest block can end a group.
    static func groupClosed(byLastBlockOf turn: ChatTurn) -> ToolGroup? {
        guard let last = turn.blocks.last else { return nil }
        switch last {
        case .toolCall, .toolResult:
            return nil
        case .text(let text):
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        case .resultSummary, .errorMessage, .askQuestion, .note:
            break
        }
        let items = ToolFoldAdapter.plan(turn)
        guard items.count >= 2, items.last == .block(turn.blocks.count - 1),
              case .group(let group) = items[items.count - 2]
        else { return nil }
        return group
    }

    /// The pane's window is key and the first responder (a field editor counts as the label it
    /// edits) is inside the pane.
    static func paneHasFocus(_ pane: NSView) -> Bool {
        guard let window = pane.window, window.isKeyWindow, !pane.isHiddenOrHasHiddenAncestor,
              let responder = window.firstResponder as? NSView
        else { return false }
        let editorOwner = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
        return (editorOwner ?? responder).isDescendant(of: pane)
    }

    /// An `.announcementRequested` from `element`, at medium priority.
    static func voiceOver(from element: NSView) -> (String) -> Void {
        { [weak element] text in
            guard let element else { return }
            NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }
}
