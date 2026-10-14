import AppKit
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
/// Laid out like `ChatTurnView`: members are frame-positioned and each measured detached with
/// `ChatTurnView.measureIsland`, so no constraint links one member to another, and this
/// view's own height is arithmetic over cached member heights. It occupies the block column
/// (members keep today's x and width); the 2 pt leading rule sits in the turn's gutter, to
/// the left of the column.
final class ToolGroupView: NSView, WidthPresettable {

    /// Space between the row and the first member, and between members.
    static let memberSpacing: CGFloat = TurnHeightEstimator.blockSpacing
    /// The leading rule's x, inside the turn's 14 pt gutter.
    static let ruleX: CGFloat = -8
    static let ruleWidth: CGFloat = 2

    let row: ToolGroupRowView
    private(set) var group: ToolGroup

    /// The operator toggled the group (the new state). Already applied to this view.
    var onToggle: ((Bool) -> Void)?
    /// A member result (or agent activity) fold was toggled: its block index and new state.
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?
    /// A member changed height; the group re-measured it already.
    var onHeightChange: (() -> Void)?

    /// The blocks this group shows (members and subagent blocks), by block index. Copied
    /// out of the turn's array rather than holding the array: a view that kept it would
    /// make every block the session appends to that turn copy the whole array.
    private var blocks: [Int: TurnBlock] = [:]
    private let contentAvailable: Bool
    private let interaction: TurnInteractionState
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
    private let rule = NSView()

    init(group: ToolGroup, blocks: [TurnBlock],
         contentAvailable: Bool, interaction: TurnInteractionState, isExpanded: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.group = group
        self.contentAvailable = contentAvailable
        self.interaction = interaction
        self.isExpanded = isExpanded
        self.row = ToolGroupRowView(group: group, isExpanded: isExpanded, payloadAvailable: contentAvailable,
                                    reduceMotion: reduceMotion)
        super.init(frame: .zero)
        takeBlocks(of: group, from: blocks)
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

    /// Open or close without it counting as the operator's click (no `onToggle`).
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        row.setExpanded(expanded, animated: false)
        applyExpanded(expanded)
    }

    /// The group grew (or its counts changed). Returns whether this view's height changed.
    @discardableResult
    func update(group: ToolGroup, blocks: [TurnBlock]) -> Bool {
        self.group = group
        takeBlocks(of: group, from: blocks)
        row.update(group: group)
        guard isExpanded else { return false }
        let before = contentHeight
        syncMembers()
        return contentHeight != before
    }

    // MARK: - Members

    private func takeBlocks(of group: ToolGroup, from all: [TurnBlock]) {
        for index in group.memberIndices.reversed() {
            guard blocks[index] == nil else { break }   // members only ever grow at the end
            blocks[index] = all[index]
        }
        for indices in group.subagentBlocks.values {
            for index in indices where blocks[index] == nil { blocks[index] = all[index] }
        }
    }

    private func applyExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded { releaseFocusFromMembers() }
        // Hidden at once, not at the next layout pass: a collapsed group must hold no
        // visible (or selectable) member text in between.
        for member in members { member.view.isHidden = !expanded }
        if expanded {
            // Existing members first, so the ones `syncMembers` adds are measured once.
            if membersStale { remeasureMembers() }
            syncMembers()
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Build member views for members the group gained since, and keep agent activity in
    /// step with the subagent blocks.
    private func syncMembers() {
        let indices = group.memberIndices
        while builtMemberCount < indices.count {
            let index = indices[builtMemberCount]
            builtMemberCount += 1
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
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// A selection (or focus) inside a member must not outlive the collapse: ⌘C would copy
    /// hidden output. The operator just toggled this row, so focus moves to it.
    private func releaseFocusFromMembers() {
        guard let window, let responder = window.firstResponder as? NSView else { return }
        let editorOwner = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
        let owner = editorOwner ?? responder
        guard members.contains(where: { owner.isDescendant(of: $0.view) }) else { return }
        if !window.makeFirstResponder(row) { window.makeFirstResponder(nil) }
    }

    /// The same views `ChatTurnView` built for these blocks before folding.
    private func makeMemberView(at index: Int) -> NSView {
        guard let block = blocks[index] else { return NSView() }
        switch block {
        case .toolCall(let d):
            return ToolCallView(data: d)
        case .toolResult(let d):
            let view = ToolResultView(data: d, contentAvailable: contentAvailable,
                                      startExpanded: interaction.expandedBlocks.contains(index))
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
                                     interaction: interaction,
                                     startExpanded: interaction.expandedBlocks.contains(agentIndex))
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
        addSubview(view)
        let height = memberWidth > 0 ? ChatTurnView.measureIsland(view, width: memberWidth) : 0
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
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    private var contentHeight: CGFloat {
        var height = ToolGroupRowView.height
        if isExpanded {
            for member in members { height += Self.memberSpacing + member.height }
        }
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        place(row, NSRect(x: 0, y: 0, width: width, height: ToolGroupRowView.height))
        var y = ToolGroupRowView.height
        for member in members {
            member.view.isHidden = !isExpanded
            guard isExpanded else { continue }
            y += Self.memberSpacing
            place(member.view, NSRect(x: 0, y: y, width: width, height: member.height))
            y += member.height
        }
        rule.isHidden = !isExpanded || members.isEmpty
        if !rule.isHidden {
            let top = ToolGroupRowView.height + Self.memberSpacing
            place(rule, NSRect(x: Self.ruleX, y: top, width: Self.ruleWidth, height: max(0, y - top)))
        }
    }

    private func place(_ view: NSView, _ rect: NSRect) {
        guard view.frame != rect else { return }
        view.frame = rect
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

// MARK: - ToolGroupRowView

/// The group's 22 pt row: disclosure triangle, summary (or, for a group of one, the call's
/// own header), failure badge, time. A control: click, Space/Return/→/← toggle it.
///
/// Every colour is explicit (`palette`), never a semantic or system colour, so the row reads
/// the same in key and non-key windows whatever the system appearance (the Teri tab lesson).
/// Everything drawn is sanitized (`FoldTextSanitizer`); the copy actions are not.
final class ToolGroupRowView: NSView {

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

    /// The operator toggled the row (new state).
    var onToggle: ((Bool) -> Void)?
    /// Where Copy Commands / Copy Summary / ⌘C put text. Injectable for tests.
    var pasteboard: NSPasteboard = .general

    private(set) var group: ToolGroup
    private let payloadAvailable: Bool
    private let reduceMotion: () -> Bool
    private(set) var isExpanded = false

    private let triangleView = NSView()
    private let triangle = CAShapeLayer()
    private let iconField = NSTextField(labelWithString: "")
    private let summary = FoldSummaryField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var forwardedDrag = false

    init(group: ToolGroup, isExpanded: Bool, payloadAvailable: Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.group = group
        self.payloadAvailable = payloadAvailable
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 4
        focusRingType = .default

        setUpTriangle()
        setUpLabels()
        update(group: group)
        setExpanded(isExpanded, animated: false)
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
    /// `· 4.1 s`, hidden when the time is unknown.
    var timeField: NSTextField { time }
    /// The rotating triangle (for the Reduce Motion check).
    var triangleLayer: CALayer { triangle }

    // MARK: Content

    #if DEBUG
    /// Every `update(group:)`, so tests can hold a turn build to one summary per group.
    static var updateCount = 0
    #endif

    func update(group: ToolGroup) {
        #if DEBUG
        Self.updateCount += 1
        #endif
        self.group = group
        if let text = ToolGroupSummary.summary(for: group) {
            iconField.isHidden = true
            setText(text, on: summary, color: Theme.fgMuted)
        } else if let call = group.calls.first {
            // A group of one reads as its call's own header.
            iconField.isHidden = false
            iconField.stringValue = ToolCallView.icon(for: call.name)
            setText(ToolGroupSummary.header(for: call), on: summary, color: Theme.fgMuted)
        }
        let failure = ToolGroupSummary.failureText(for: group)
        badge.isHidden = failure == nil
        setText(failure.map { "· \($0)" } ?? "", on: badge, color: Theme.foldFailure)
        let duration = ToolGroupSummary.durationText(for: group)
        time.isHidden = duration == nil
        setText(duration.map { "· \($0)" } ?? "", on: time, color: Theme.fgMuted)
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

        for (field, color) in [(badge, Theme.foldFailure), (time, Theme.fgMuted)] {
            field.font = Self.font
            field.textColor = color
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [triangleView, iconField, summary, badge, time])
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

    private func setText(_ text: String, on field: NSTextField, color: NSColor) {
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
    /// makes a row first responder, so a group updating cannot either.
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
        // ⌘→, ⌥←, ⌃↑… belong to someone else (TF4's Expand/Collapse All among them).
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

    /// Focus the previous/next group row that exists (is materialized) in this pane.
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

    private static func rows(in view: NSView) -> [ToolGroupRowView] {
        view.subviews.flatMap { sub -> [ToolGroupRowView] in
            if let row = sub as? ToolGroupRowView { return sub.isHiddenOrHasHiddenAncestor ? [] : [row] }
            return rows(in: sub)
        }
    }

    /// ⌘C with the row focused (and so no text selected): the summary.
    @objc func copy(_ sender: Any?) { copySummary() }

    // MARK: Copy

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Commands", action: #selector(copyCommandsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Summary", action: #selector(copySummaryAction), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyCommandsAction() { copyCommands() }
    @objc private func copySummaryAction() { copySummary() }

    /// Every call's complete input, verbatim (never the drawn, sanitized text).
    func copyCommands() {
        put(ToolGroupSummary.commandsText(for: group, payloadAvailable: payloadAvailable))
    }

    func copySummary() {
        put(ToolGroupSummary.plainText(for: group))
    }

    private func put(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { ToolGroupSummary.accessibilityLabel(for: group) }
    override func accessibilityValue() -> Any? { isExpanded ? "expanded" : "collapsed" }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
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
    private let interaction: TurnInteractionState
    private(set) var isExpanded: Bool
    private let disclosure = NSButton()
    private let content = NSStackView()
    private var contentBuilt = false

    init(blockIndices: [Int], blocks: [Int: TurnBlock], contentAvailable: Bool,
         interaction: TurnInteractionState, startExpanded: Bool) {
        self.blockIndices = blockIndices
        self.blocks = blocks
        self.contentAvailable = contentAvailable
        self.interaction = interaction
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
                                        startExpanded: interaction.expandedBlocks.contains(index))
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
