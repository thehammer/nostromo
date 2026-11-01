import AppKit
import NostromoKit

// AP4: the session-rules chip in the input bar, and the two-step human gate every session-rule
// control goes through.
//
// The chip says how many "Allow for this session" rules the focus has (`1 session rule`,
// `3 session rules`), and nothing when it has none. It sits in its own fixed-width slot
// (`SessionRulesChip.slotWidth`) so it appearing, changing or going never moves the composer or the
// transcript. A click opens `SessionRulesPopover`, where every rule is listed and can be revoked.

// MARK: - The gate

/// An event identified closely enough to tell two apart: its type, its timestamp and its number
/// (`eventNumber` for a mouse event, `keyCode` for a key).
struct SessionRuleEventStamp: Equatable {
    let type: NSEvent.EventType
    let timestamp: TimeInterval
    let number: Int

    init?(_ event: NSEvent?) {
        guard let event else { return nil }
        type = event.type
        timestamp = event.timestamp
        switch event.type {
        case .leftMouseUp, .leftMouseDown, .rightMouseUp: number = event.eventNumber
        case .keyDown: number = Int(event.keyCode)
        default: number = 0
        }
    }
}

/// The two-step gate of "Allow for this session" (and the single step of Revoke).
///
/// Creating a rule is an Allow that outlives the request, so it takes two separate human gestures:
/// choosing the rule (a menu pick: `HumanGesture.permit(menuSelection: true, contextMenuPick: true)`,
/// which is allowed only because the pick cannot itself confirm), then pressing `Allow for this session`
/// (`permit` with the strict defaults). The confirm refuses, changing nothing and keeping the selection:
/// the same event as the pick, an event less than `minimumGap` after it (measured on the events' own
/// timestamps, so a slow main thread cannot make two instants of one gesture look apart), a held-key
/// repeat, a multi-click, a mouse event outside the button, and a key while the button is not the first
/// responder or is not Space/Return. A selection also expires (`selectionLifetime`).
///
/// Nothing here can be driven by the app-control socket or by Accessibility with VoiceOver off:
/// `HumanGesture.permit` refuses those.
final class SessionRuleGesture {

    /// `(event, control, menuSelection)`: `HumanGesture.permit`, or a test's stand-in.
    typealias Permit = (NSEvent?, NSView, Bool) -> HumanGestureVerdict

    /// The least time between the pick and the confirm.
    static let minimumGap: TimeInterval = 0.3
    /// How long a pick stands before it reverts.
    static let selectionLifetime: TimeInterval = 15

    enum Refusal: Equatable {
        /// `HumanGesture.permit` refused it (a synthetic, event-less, stale or foreign input).
        case notHuman(HumanGestureRefusal)
        case noSelection
        case expired
        case sameEvent
        case tooSoon
        case repeatedKey
        case multiClick
        case outsideControl
        case notFocused
        case wrongKey
    }

    enum Verdict: Equatable {
        case allowed
        case refused(Refusal)
    }

    private let permit: Permit
    private let uptime: () -> TimeInterval
    private var selection: (stamp: SessionRuleEventStamp?, handlerTime: TimeInterval)?

    init(permit: @escaping Permit = { event, view, menu in
             HumanGesture.permit(event, control: view, menuSelection: menu, contextMenuPick: menu)
         },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.permit = permit
        self.uptime = uptime
    }

    var hasSelection: Bool { selection != nil }

    /// Step 1: the human chose a rule from the menu of `control`. Records the event it was chosen with.
    func select(event: NSEvent?, control: NSView) -> Verdict {
        if case .refused(let reason) = permit(event, control, true) {
            selection = nil
            return .refused(.notHuman(reason))
        }
        selection = (SessionRuleEventStamp(event), uptime())
        return .allowed
    }

    /// Step 2: the human pressed the confirm button. On a refusal nothing changes (the selection stays).
    func confirm(event: NSEvent?, button: NSView) -> Verdict {
        if case .refused(let reason) = permit(event, button, false) { return .refused(.notHuman(reason)) }
        guard let pick = selection else { return .refused(.noSelection) }
        let now = uptime()
        if now - pick.handlerTime > Self.selectionLifetime {
            selection = nil
            return .refused(.expired)
        }
        let stamp = SessionRuleEventStamp(event)
        if let stamp, let first = pick.stamp {
            if stamp == first { return .refused(.sameEvent) }
            // Both events exist: the gap is theirs, not the handlers'.
            if stamp.timestamp - first.timestamp < Self.minimumGap { return .refused(.tooSoon) }
        } else if now - pick.handlerTime < Self.minimumGap {
            // An event-less press (VoiceOver): only the handler clock is there to measure with.
            return .refused(.tooSoon)
        }
        if let refusal = targeting(event, button) { return .refused(refusal) }
        selection = nil
        return .allowed
    }

    /// One step (Revoke: it only narrows what is allowed): a human gesture aimed at `button`.
    func single(event: NSEvent?, button: NSView) -> Verdict {
        if case .refused(let reason) = permit(event, button, false) { return .refused(.notHuman(reason)) }
        if let refusal = targeting(event, button) { return .refused(refusal) }
        return .allowed
    }

    /// Forget the pick (the card changed, left its window, or the pick timed out).
    func clear() { selection = nil }

    /// The event must be aimed at `button`: not a repeat or a multi-click, a mouse event inside its
    /// bounds, a key event only while it is the first responder and only Space or Return.
    private func targeting(_ event: NSEvent?, _ button: NSView) -> Refusal? {
        guard let event else { return nil }   // an event-less press: VoiceOver on (`permit` checked)
        switch event.type {
        case .keyDown:
            if event.isARepeat { return .repeatedKey }
            guard button.window?.firstResponder === button else { return .notFocused }
            // Space, Return, keypad Enter.
            guard [49, 36, 76].contains(Int(event.keyCode)) else { return .wrongKey }
        case .leftMouseUp, .leftMouseDown:
            if event.clickCount > 1 { return .multiClick }
            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point) else { return .outsideControl }
        default:
            break
        }
        return nil
    }
}

// MARK: - The chip

/// `N session rules` in the input bar. Hidden with no rules; right-aligned in its fixed slot.
final class SessionRulesChip: NSButton {

    /// How much of its text the chip shows.
    enum Fit: Equatable {
        case full
        case countOnly
        case hidden
    }

    static let height: CGFloat = ModelChip.height
    static let horizontalPadding: CGFloat = 9
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let textColor = NSColor(white: 170 / 255, alpha: 1)
    static let fillColor = ModelChip.fillColor
    private static let pressedFillColor = NSColor.white.withAlphaComponent(0.18)

    /// The most rules a session may hold; the slot fits its text.
    static let countCap = 32

    /// The width the input bar reserves when there is room: the widest `N session rules` for any N up to the cap
    /// (proportional digits make `20` wider than `32`), plus padding.
    static let slotWidth: CGFloat = widest(.full)

    /// The narrowest slot the bare count fits, plus padding.
    static let countWidth: CGFloat = widest(.countOnly)

    private static func widest(_ fit: Fit) -> CGFloat {
        let width = (1 ... countCap)
            .map { NSAttributedString(string: text(count: $0, fit: fit), attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(width) + 2 * horizontalPadding
    }

    /// What the chip says for `count` rules at `fit`.
    static func text(count: Int, fit: Fit) -> String {
        switch fit {
        case .full: return count == 1 ? "1 session rule" : "\(count) session rules"
        case .countOnly: return "\(count)"
        case .hidden: return ""
        }
    }

    private(set) var count = 0
    private(set) var fit: Fit = .full
    private(set) var hasKeyboardFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
        refusesFirstResponder = false
        // The slot gives way, never the chip (see `BackgroundChip`).
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `count` rules. Hidden for zero. Never touches the window's first responder.
    func apply(count: Int) {
        self.count = count
        refresh()
    }

    /// Show `fit` of the text: only what the chip draws and whether it is hidden change.
    func setFit(_ fit: Fit) {
        guard fit != self.fit else { return }
        self.fit = fit
        refresh()
    }

    private func refresh() {
        title = Self.text(count: count, fit: fit)
        isHidden = count == 0 || fit == .hidden
        let noun = count == 1 ? "1 session rule" : "\(count) session rules"
        setAccessibilityLabel(count == 0 ? nil : "\(noun), allowed for this session. Press to review or revoke")
        toolTip = count == 0 ? nil : "\(noun) allowed for this session"
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let text = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        return NSSize(width: min(Self.slotWidth, text + 2 * Self.horizontalPadding), height: Self.height)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasKeyboardFocus = true; needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { hasKeyboardFocus = false; needsDisplay = true }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        (isHighlighted ? Self.pressedFillColor : Self.fillColor).setFill()
        pill.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: Self.font, .foregroundColor: Self.textColor, .paragraphStyle: paragraph,
        ])
        if hasKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor.white.withAlphaComponent(ModelChip.normalAlpha).setStroke()
            ring.stroke()
        }
        let inner = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        let lineHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: inner.minX, y: inner.midY - lineHeight / 2, width: inner.width, height: lineHeight))
    }
}
