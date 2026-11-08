import AppKit
import Combine
import NostromoKit

// AP6: the Rules list. Every persisted "Always allow…" rule, with where it is written, its scope, which
// request it was created from (a link into the Approvals window), how often it was used, whether it is
// active (a rule Nostromo would no longer offer stays listed as inactive and never matches) and Remove.
//
// Remove only narrows what is allowed, so it is one human gesture (`SessionRuleGesture.single`). Nothing here
// can write a rule: that is the card's two-step panel. When the rules file changed outside Nostromo, the
// daemon turns every rule off and this window says so; getting them back is two gestures (`Review…`, then
// `Turn these rules on`, `select` then `confirm`) and sends the hash of the file that was reviewed.
// `Discard` (replace the file with an empty rule set) is one gesture: it only narrows.
//
// The window is a panel opened from Window ▸ Approval Rules, from the session-rules popover's
// `All rules…` link and from the Approvals window's `Rules…` button. It is not in `AppDelegate.windows`, so
// app-control's `screenshot`, `tree` and `click` cannot reach it. The only app-control command is the
// read-only `approvals rules`.

/// One row of the list, as the listing and the tests read it.
struct PersistedRuleRowListing: Equatable {
    let ruleID: String
    let ruleText: String
    let detail: String
    let file: String
    let active: Bool
    let createdFromRequestID: String
}

final class PersistedRulesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class PersistedRulesWindowManager: NSObject, NSWindowDelegate {

    static let shared = PersistedRulesWindowManager()

    static let defaultSize = NSSize(width: 640, height: 420)
    static let minimumSize = NSSize(width: 460, height: 260)
    static let defaultsKey = "nostromo.approvalRulesWindow.frame"

    private(set) var panel: PersistedRulesPanel?
    private(set) var rulesView: PersistedRulesView?

    private let defaults: UserDefaults
    private let visibleScreens: () -> [NSRect]
    private var isPlacing = false

    init(defaults: UserDefaults = .standard,
         visibleScreens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.defaults = defaults
        self.visibleScreens = visibleScreens
        super.init()
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Open the window (or bring it forward). It never makes itself key.
    func show() {
        let (panel, _) = ensureWindow()
        if !panel.isVisible { place(panel) }
        ActivationAudit.note("approval-rules-window:orderFront")
        panel.orderFront(nil)
    }

    func close() { panel?.close() }

    private func ensureWindow() -> (PersistedRulesPanel, PersistedRulesView) {
        if let panel, let rulesView { return (panel, rulesView) }
        let panel = PersistedRulesPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                        styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                        backing: .buffered, defer: true)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = ApprovalPalette.cardBackground
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.minSize = Self.minimumSize
        panel.title = "Approval Rules"
        let view = PersistedRulesView(store: ApprovalStore.shared)
        panel.contentView = view
        panel.delegate = self
        self.panel = panel
        rulesView = view
        return (panel, view)
    }

    private func place(_ panel: PersistedRulesPanel) {
        isPlacing = true
        defer { isPlacing = false }
        let screens = visibleScreens()
        if let saved = defaults.string(forKey: Self.defaultsKey).map(NSRectFromString), saved.width > 0, saved.height > 0,
           let clamped = TaskWindowFrame.clamp(saved, to: screens) {
            panel.setFrame(clamped, display: false)
            return
        }
        panel.setContentSize(Self.defaultSize)
        if let screen = screens.first {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 120, y: screen.maxY - 120))
            if let clamped = TaskWindowFrame.clamp(panel.frame, to: screens) { panel.setFrame(clamped, display: false) }
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard !isPlacing, let panel else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: Self.defaultsKey)
    }
}

final class PersistedRulesView: NSView {

    static let padding: CGFloat = 14
    static let rowGap: CGFloat = 12
    /// How long the review of a quarantined file stands before it reverts: longer than a card's pick, since it
    /// is read, not just chosen.
    static let reviewLifetime: TimeInterval = 120

    private let store: ApprovalStore
    private let gesture: SessionRuleGesture
    private let currentEvent: () -> NSEvent?
    private let home: String
    private let timeZone: TimeZone
    private let openRequest: (ApprovalsLogLink) -> Void
    private var subscription: AnyCancellable?

    private let scroll = NSScrollView()
    private let document = FlippedDocumentView()
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No persisted rules")
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var removeButtons: [String: ApprovalButton] = [:]
    private(set) var createdFromButtons: [String: NSButton] = [:]
    private(set) var reviewButton: ApprovalButton?
    private(set) var turnOnButton: ApprovalButton?
    private(set) var cancelReviewButton: ApprovalButton?
    private(set) var discardButton: ApprovalButton?
    private(set) var rows: [PersistedRuleRowListing] = []
    /// The parsed rules of the quarantined file as the review shows them, one line each (nil until `Review…`).
    private(set) var reviewLines: [String]?
    /// The hash of the file the person is reviewing: the only one `Turn these rules on` ever sends.
    private var reviewedHash: String?
    private var reviewGeneration = 0
    private var laidOutWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    init(store: ApprovalStore,
         gesture: SessionRuleGesture = SessionRuleGesture(lifetime: PersistedRulesView.reviewLifetime),
         currentEvent: @escaping () -> NSEvent? = { NSApp.currentEvent },
         home: String = NSHomeDirectory(), timeZone: TimeZone = .current,
         openRequest: @escaping (ApprovalsLogLink) -> Void = { ApprovalsWindowManager.shared.show(link: $0) }) {
        self.store = store
        self.gesture = gesture
        self.currentEvent = currentEvent
        self.home = home
        self.timeZone = timeZone
        self.openRequest = openRequest
        super.init(frame: NSRect(x: 0, y: 0, width: PersistedRulesWindowManager.defaultSize.width,
                                 height: PersistedRulesWindowManager.defaultSize.height))
        appearance = NSAppearance(named: .darkAqua)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        subscription = store.persistedRulesChanges.sink { [weak self] in self?.storeChanged() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Text

    /// `File: ~/.nostromo/approvals/rules.json`
    var fileText: String {
        "File: " + ApprovalKinds.homeAbbreviated(store.rulesPath, home: home)
    }

    /// The banner while the file is off, else nil.
    var bannerText: String? {
        store.rulesQuarantine == nil ? nil : PersistedRulesText.quarantineBanner
    }

    // MARK: Store

    private func storeChanged() {
        // A different file than the one reviewed: the review no longer stands.
        if let reviewed = reviewedHash, store.rulesQuarantine?.fileSha256 != reviewed { endReview() }
        rebuild()
    }

    // MARK: Build

    private func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }
        removeButtons = [:]
        createdFromButtons = [:]
        rowViews = [:]
        reviewViews = []
        reviewButton = nil
        turnOnButton = nil
        cancelReviewButton = nil
        discardButton = nil
        let list = store.persistedRules
        rows = list.map {
            PersistedRuleRowListing(ruleID: $0.id, ruleText: $0.ruleText,
                                    detail: PersistedRulesText.detailText($0, home: home, timeZone: timeZone),
                                    file: fileText, active: $0.active, createdFromRequestID: $0.createdFromRequestId)
        }
        pathLabel.stringValue = fileText
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = ApprovalPalette.mutedText
        document.addSubview(pathLabel)

        if let q = store.rulesQuarantine {
            bannerLabel.stringValue = PersistedRulesText.quarantineBanner
            bannerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            bannerLabel.textColor = ApprovalPalette.warning
            document.addSubview(bannerLabel)
            reasonLabel.stringValue = PersistedRulesText.quarantineReasonText(q.reason)
            reasonLabel.font = .systemFont(ofSize: 11)
            reasonLabel.textColor = ApprovalPalette.mutedText
            document.addSubview(reasonLabel)
            if reviewLines == nil {
                reviewButton = makeButton("Review…", id: "review", action: #selector(reviewPressed(_:)),
                                          label: "Review the changed rules file")
            } else {
                turnOnButton = makeButton("Turn these rules on", id: "turn_on", action: #selector(turnOnPressed(_:)),
                                          label: "Turn on the rules in the file you reviewed")
                cancelReviewButton = makeButton("Cancel", id: "cancel_review", action: #selector(cancelReviewPressed(_:)),
                                                label: "Stop reviewing")
            }
            discardButton = makeButton("Discard", id: "discard", action: #selector(discardPressed(_:)),
                                       label: "Discard the changed rules file; no rules are kept")
            for line in reviewLines ?? [] {
                let label = NSTextField(wrappingLabelWithString: line)
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.textColor = line.contains("inactive") || line.contains("ALL repositories") ? ApprovalPalette.warning : ApprovalPalette.commandText
                label.isSelectable = true
                document.addSubview(label)
                reviewViews.append(label)
            }
        }
        for rule in list { addRow(rule) }
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = ApprovalPalette.mutedText
        if list.isEmpty && store.rulesQuarantine == nil { document.addSubview(emptyLabel) }
        laidOutWidth = 0
        needsLayout = true
    }

    private var rowViews: [String: [NSView]] = [:]
    private var reviewViews: [NSView] = []

    private func makeButton(_ title: String, id: String, action: Selector, label: String) -> ApprovalButton {
        let b = ApprovalButton(title: title, target: self, action: action)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.title = title
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.setAccessibilityLabel(label)
        document.addSubview(b)
        return b
    }

    private func addRow(_ rule: PersistedRule) {
        let ruleLabel = NSTextField(wrappingLabelWithString: "")
        ApprovalContextText.set(ruleLabel, rule.ruleText, wraps: false,
                                font: .monospacedSystemFont(ofSize: 12, weight: .semibold),
                                color: rule.active ? ApprovalPalette.commandText : ApprovalPalette.mutedText)
        ruleLabel.lineBreakMode = .byCharWrapping
        ruleLabel.isSelectable = true
        let detail = NSTextField(wrappingLabelWithString: PersistedRulesText.detailText(rule, home: home, timeZone: timeZone))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = rule.active ? ApprovalPalette.mutedText : ApprovalPalette.warning
        let remove = ApprovalButton(title: "Remove", target: self, action: #selector(removePressed(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(rule.id)
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.font = .systemFont(ofSize: 11)
        remove.setAccessibilityLabel(PersistedRulesText.removeAccessibilityLabel(rule))
        removeButtons[rule.id] = remove
        let link = NSButton(title: "Created from this request", target: self, action: #selector(createdFromPressed(_:)))
        link.identifier = NSUserInterfaceItemIdentifier(rule.id)
        link.bezelStyle = .inline
        link.controlSize = .small
        link.font = .systemFont(ofSize: 11)
        link.refusesFirstResponder = true
        link.isEnabled = !rule.createdFromRequestId.isEmpty
        createdFromButtons[rule.id] = link
        let views: [NSView] = [ruleLabel, detail, remove, link]
        rowViews[rule.id] = views
        views.forEach(document.addSubview)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = bounds.width
        guard width != laidOutWidth else { return }
        laidOutWidth = width
        let pad = Self.padding
        let inner = max(120, width - 2 * pad - 15)   // 15: the scroller's gutter
        var y = pad
        func height(_ label: NSTextField, _ w: CGFloat) -> CGFloat {
            label.preferredMaxLayoutWidth = w
            return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 14)
        }
        func place(_ label: NSTextField) {
            let h = height(label, inner)
            label.frame = NSRect(x: pad, y: y, width: inner, height: h)
            y += h + 4
        }
        place(pathLabel)
        y += 6
        if store.rulesQuarantine != nil {
            place(bannerLabel)
            place(reasonLabel)
            var x = pad
            for button in [reviewButton, turnOnButton, cancelReviewButton, discardButton].compactMap({ $0 }) {
                let w = max(64, ceil(button.attributedTitle.size().width) + 28)
                button.frame = NSRect(x: x, y: y, width: w, height: 22)
                x += w + 8
            }
            y += 30
            for case let label as NSTextField in reviewViews { place(label) }
            if !reviewViews.isEmpty { y += 6 }
        }
        for rule in store.persistedRules {
            guard let views = rowViews[rule.id], views.count == 4,
                  let ruleLabel = views[0] as? NSTextField, let detail = views[1] as? NSTextField else { continue }
            let buttonWidth: CGFloat = 72
            let textWidth = inner - buttonWidth - 8
            let rh = height(ruleLabel, textWidth)
            ruleLabel.frame = NSRect(x: pad, y: y, width: textWidth, height: rh)
            views[2].frame = NSRect(x: pad + textWidth + 8, y: y, width: buttonWidth, height: 22)
            y += rh + 2
            let dh = height(detail, textWidth)
            detail.frame = NSRect(x: pad, y: y, width: textWidth, height: dh)
            y += dh + 2
            views[3].frame = NSRect(x: pad, y: y, width: 170, height: 18)
            y += 18 + Self.rowGap
        }
        if emptyLabel.superview != nil {
            emptyLabel.frame = NSRect(x: pad, y: y, width: inner, height: 16)
            y += 16
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, y + pad))
    }

    // MARK: Actions

    /// Remove pressed: one human gesture aimed at this button, then the store sends it.
    @objc private func removePressed(_ sender: ApprovalButton) {
        guard let ruleID = sender.identifier?.rawValue else { return }
        remove(ruleID: ruleID, button: sender)
    }

    /// The gate and the send, for the press (and for tests with their own gate and event).
    @discardableResult
    func remove(ruleID: String, button: ApprovalButton) -> Bool {
        switch gesture.single(event: currentEvent(), button: button) {
        case .allowed: return store.removeRule(id: ruleID)
        case .refused(let refusal):
            report(refusal, control: "remove_rule")
            return false
        }
    }

    /// `Created from this request`: opens the Approvals window on that request's row. Read-only navigation.
    @objc private func createdFromPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let rule = store.persistedRules.first(where: { $0.id == id }), !rule.createdFromRequestId.isEmpty else { return }
        openRequest(ApprovalsLogLink(requestId: rule.createdFromRequestId))
    }

    /// Step 1 of turning the rules back on: show what is in the file. Nothing is sent.
    @objc private func reviewPressed(_ sender: ApprovalButton) { _ = review(button: sender) }

    @discardableResult
    func review(button: NSView) -> Bool {
        guard let q = store.rulesQuarantine else { return false }
        switch gesture.select(event: currentEvent(), control: button) {
        case .allowed:
            reviewedHash = q.fileSha256
            var lines = q.rulesInFile.map { "\($0.ruleText)  ·  \(PersistedRulesText.reviewText($0, home: home))" }
            if lines.isEmpty { lines = ["No rules could be read from the file"] }
            reviewLines = lines
            reviewGeneration += 1
            let generation = reviewGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reviewLifetime) { [weak self] in
                guard let self, self.reviewGeneration == generation else { return }
                self.endReview()
                self.rebuild()
            }
            rebuild()
            return true
        case .refused(let refusal):
            report(refusal, control: "keep_rules")
            return false
        }
    }

    /// Step 2: `Turn these rules on`, a distinct gesture at least 0.3 s later. Sends the hash that was reviewed.
    @objc private func turnOnPressed(_ sender: ApprovalButton) { _ = turnOn(button: sender) }

    @discardableResult
    func turnOn(button: NSView) -> Bool {
        guard let hash = reviewedHash, reviewLines != nil, store.rulesQuarantine?.fileSha256 == hash else { return false }
        switch gesture.confirm(event: currentEvent(), button: button) {
        case .allowed:
            let sent = store.keepQuarantinedRules(fileSha256: hash)
            endReview()
            rebuild()
            return sent
        case .refused(let refusal):
            report(refusal, control: "keep_rules")
            return false
        }
    }

    @objc private func cancelReviewPressed(_ sender: ApprovalButton) {
        endReview()
        rebuild()
    }

    private func endReview() {
        reviewLines = nil
        reviewedHash = nil
        reviewGeneration += 1
        gesture.clear()
    }

    /// Discard: one gesture (it only narrows what is allowed).
    @objc private func discardPressed(_ sender: ApprovalButton) { _ = discard(button: sender) }

    @discardableResult
    func discard(button: NSView) -> Bool {
        switch gesture.single(event: currentEvent(), button: button) {
        case .allowed:
            endReview()
            return store.discardQuarantinedRules()
        case .refused(let refusal):
            report(refusal, control: "discard_rules")
            return false
        }
    }

    /// A refusal by `HumanGesture.permit` is reported to the daemon, which logs it; the others change nothing.
    private func report(_ refusal: SessionRuleGesture.Refusal, control: String) {
        guard case .notHuman(let reason) = refusal else { return }
        let channel: ApprovalRefusalChannel
        switch reason {
        case .appControl: channel = .appControl
        case .accessibilityPress: channel = .accessibility
        default: channel = .unknown
        }
        store.reportRefusal(requestId: nil, control: control, channel: channel)
    }
}

/// A top-down document view for the scroll view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
