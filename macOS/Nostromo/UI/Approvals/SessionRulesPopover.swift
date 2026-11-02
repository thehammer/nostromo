import AppKit
import Combine
import NostromoKit

// AP4: the list behind the session-rules chip. Every active rule of the focus: its exact text, what
// it covers, when it was granted, how often it was used, the sub-agent it is bound to, and Revoke.
//
// Revoke only ever narrows what is allowed, so it is one human gesture (`SessionRuleGesture.single`):
// it refuses a synthetic input, an event aimed elsewhere, a repeat and a multi-click. The rule leaves
// the list when the daemon's next `approval_session_rules` says so, not before.

/// One row of the popover, as the listing and the tests read it.
struct SessionRuleRowListing: Equatable {
    let ruleID: String
    let ruleText: String
    let summary: String
    let detail: String
}

final class SessionRulesPopoverContent: NSView {

    static let width: CGFloat = 380
    private static let padding: CGFloat = 12
    private static let rowGap: CGFloat = 10

    private let focusTag: String
    private let store: ApprovalStore
    private let gesture: SessionRuleGesture
    private let currentEvent: () -> NSEvent?
    private let timeZone: TimeZone
    private var subscription: AnyCancellable?
    private(set) var revokeButtons: [String: ApprovalButton] = [:]
    private(set) var rows: [SessionRuleRowListing] = []
    /// Called when the last rule is gone (the popover has nothing left to show).
    var onEmpty: (() -> Void)?

    override var isFlipped: Bool { true }

    init(tag: String, store: ApprovalStore, gesture: SessionRuleGesture = SessionRuleGesture(),
         currentEvent: @escaping () -> NSEvent? = { NSApp.currentEvent }, timeZone: TimeZone = .current) {
        self.focusTag = tag
        self.store = store
        self.gesture = gesture
        self.currentEvent = currentEvent
        self.timeZone = timeZone
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 60))
        appearance = NSAppearance(named: .darkAqua)
        subscription = store.sessionRulesChanges.filter { $0 == tag }.sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `granted 2:47 pm`
    static func grantedText(atMs: UInt64, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        let clock = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)).lowercased()
        return "granted \(clock)"
    }

    /// `granted 2:47 pm · used 3 times · for sub-agent agent_x`
    static func detailText(for rule: ApprovalSessionRule, timeZone: TimeZone) -> String {
        var parts = [grantedText(atMs: rule.createdAtMs, timeZone: timeZone),
                     "used \(rule.uses) \(rule.uses == 1 ? "time" : "times")"]
        if let agent = rule.agentId, !agent.isEmpty {
            parts.append("for sub-agent \(ApprovalDisplayModel.contextText(agent, keepingLineFeeds: false))")
        }
        return parts.joined(separator: " · ")
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        revokeButtons = [:]
        let rules = store.sessionRules(tag: focusTag)
        rows = rules.map {
            SessionRuleRowListing(ruleID: $0.id, ruleText: $0.ruleText, summary: $0.summary,
                                  detail: Self.detailText(for: $0, timeZone: timeZone))
        }
        let pad = Self.padding
        let inner = Self.width - 2 * pad
        var y = pad
        for rule in rules {
            let ruleLabel = NSTextField(wrappingLabelWithString: "")
            ApprovalContextText.set(ruleLabel, rule.ruleText, wraps: false,
                                    font: .monospacedSystemFont(ofSize: 12, weight: .semibold),
                                    color: ApprovalPalette.commandText)
            ruleLabel.lineBreakMode = .byCharWrapping
            ruleLabel.isSelectable = true
            let summary = NSTextField(wrappingLabelWithString: "")
            ApprovalContextText.set(summary, rule.summary, font: .systemFont(ofSize: 11), color: ApprovalPalette.mutedText)
            let detail = NSTextField(wrappingLabelWithString: Self.detailText(for: rule, timeZone: timeZone))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = ApprovalPalette.mutedText
            let revoke = ApprovalButton(title: "Revoke", target: self, action: #selector(revokePressed(_:)))
            revoke.identifier = NSUserInterfaceItemIdentifier(rule.id)
            revoke.bezelStyle = .rounded
            revoke.controlSize = .small
            revoke.font = .systemFont(ofSize: 11)
            revoke.setAccessibilityLabel("Revoke \(ApprovalDisplayModel.contextText(rule.ruleText, keepingLineFeeds: false))")
            revokeButtons[rule.id] = revoke

            let buttonWidth: CGFloat = 64
            let textWidth = inner - buttonWidth - 8
            for label in [ruleLabel, summary, detail] {
                label.preferredMaxLayoutWidth = textWidth
                let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 14)
                label.frame = NSRect(x: pad, y: y, width: textWidth, height: height)
                addSubview(label)
                y += height + 2
            }
            revoke.frame = NSRect(x: pad + textWidth + 8, y: y - 2 - 22 - 2, width: buttonWidth, height: 22)
            addSubview(revoke)
            y += Self.rowGap
        }
        if rules.isEmpty {
            let none = NSTextField(labelWithString: "No session rules")
            none.font = .systemFont(ofSize: 12)
            none.textColor = ApprovalPalette.mutedText
            none.frame = NSRect(x: pad, y: y, width: inner, height: 16)
            addSubview(none)
            y += 16 + Self.rowGap
            DispatchQueue.main.async { [weak self] in self?.onEmpty?() }
        }
        setFrameSize(NSSize(width: Self.width, height: y + pad - Self.rowGap))
    }

    /// Revoke pressed: a human gesture aimed at this button, then the store sends it.
    @objc private func revokePressed(_ sender: ApprovalButton) {
        guard let ruleID = sender.identifier?.rawValue else { return }
        revoke(ruleID: ruleID, button: sender)
    }

    /// The gate and the send, for the press (and for tests with their own gate and event).
    @discardableResult
    func revoke(ruleID: String, button: ApprovalButton) -> Bool {
        switch gesture.single(event: currentEvent(), button: button) {
        case .allowed:
            return store.revoke(tag: focusTag, ruleId: ruleID)
        case .refused(let refusal):
            if case .notHuman(let reason) = refusal {
                let channel: ApprovalRefusalChannel
                switch reason {
                case .appControl: channel = .appControl
                case .accessibilityPress: channel = .accessibility
                default: channel = .unknown
                }
                store.reportRefusal(requestId: nil, control: "revoke_session_rule", channel: channel)
            }
            return false
        }
    }
}

/// The popover the chip opens.
final class SessionRulesPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    let content: SessionRulesPopoverContent
    var onDidClose: (() -> Void)?

    init(tag: String, store: ApprovalStore) {
        content = SessionRulesPopoverContent(tag: tag, store: store)
        super.init()
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        content.onEmpty = { [weak self] in self?.close() }
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo view: NSView) {
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() { popover.close() }

    func popoverDidClose(_ notification: Notification) { onDidClose?() }
}
