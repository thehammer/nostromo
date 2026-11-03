import AppKit
import Combine
import NostromoKit

// The Mother view's quota strip: the live quota windows, the gate's state badge and the three-state
// gate control. Human-only: nothing the agent can reach (no MCP tool, URL scheme or AppleScript hook)
// ends in `AppStore.requestQuotaGate`, and that needs a `QuotaGateConfirmation`, which only the control
// below can make, after its own gesture steps.

/// Proof that a gate change went through the control's gesture steps: one permitted gesture for ON, a
/// permitted arm and a permitted, distinct confirm for either OFF. `AppStore.requestQuotaGate` takes one;
/// the initializer is `fileprivate` to this file, so a call from anywhere else does not compile.
struct QuotaGateConfirmation {
    fileprivate init() {}
}

// MARK: - MotherQuotaGateControl

/// On · Off until reset · Off, as three small buttons; the one that matches the broker's gate is marked.
///
/// ON is one gesture. Either OFF is two: the first click arms (`Turn gate off? Click again to confirm`),
/// a second, distinct click on the same option within `confirmInterval` seconds confirms. Arming expires on
/// its own, when the window loses key, and when the armed button loses focus.
///
/// Every click and key press runs `permit` (`HumanGesture.permit`) first and does nothing when refused. A
/// confirm is refused when it is the same event as the arm, comes within `BackgroundGesture.minConfirmDelay`
/// of it (on the event clock and on the handler clock), is a key repeat or the second click of a
/// double-click, or was not aimed at the button. A refused confirm leaves the armed state and its timer as
/// they were. The control never decides the gate's state: it shows what `update` is given.
final class MotherQuotaGateControl: NSView {
    static let confirmInterval: TimeInterval = 3
    static let options: [MotherQuotaGateRequest] = [.on, .offUntilReset, .off]

    /// The option waiting for its confirming click, if any.
    private(set) var armed: MotherQuotaGateRequest?
    private(set) var gate: MotherQuotaGate = .unknown("")
    private(set) var inFlight = false
    /// Called when arming starts or ends, so the strip can show or drop the prompt.
    var onArmedChange: ((MotherQuotaGateRequest?) -> Void)?

    private var buttons: [MotherQuotaGateRequest: GateOptionButton] = [:]
    private var timerToken = 0
    private var armedAt: TimeInterval = 0
    private var armedBy: GestureStamp?
    private var keyboardBlockedUntil: TimeInterval = 0
    private let permit: BackgroundGesture.Permit
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let send: (MotherQuotaGateRequest, QuotaGateConfirmation) -> Void
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - permit: the human-gesture check, given the pressed button (tests script it).
    ///   - schedule: runs the arm's expiry after a delay on the main thread (tests pass a manual one).
    ///   - send: asks Mother for the new state; runs only after the gesture steps.
    init(permit: @escaping BackgroundGesture.Permit = BackgroundGesture.defaultPermit,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         send: @escaping (MotherQuotaGateRequest, QuotaGateConfirmation) -> Void) {
        self.permit = permit
        self.schedule = schedule
        self.send = send
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for request in Self.options {
            let button = GateOptionButton(control: self)
            button.target = self
            button.action = #selector(optionPressed(_:))
            buttons[request] = button
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Quota gate")
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The button for one option (tests press it).
    func button(for request: MotherQuotaGateRequest) -> NSButton { buttons[request]! }

    /// The control works only while the gate's state is known and no command is waiting for its ack.
    var isActive: Bool { !inFlight && !gate.isUnknown }

    /// Show what the broker says. A gate that changed under an armed OFF, to any state, ends the arm.
    func update(gate: MotherQuotaGate, inFlight: Bool) {
        let changed = self.gate != gate
        self.gate = gate
        self.inFlight = inFlight
        // Any change of the gate's state ends an arm: the second click must not apply to a state the operator
        // never saw armed.
        if armed != nil, changed || !isActive { disarm() }
        refreshAppearance()
    }

    /// How long after any key other than Space the keyboard cannot arm or confirm.
    static let strayKeyBlock: TimeInterval = 1.5

    /// A key that is not a deliberate Space press reached a focused option (ordinary typing): drop any arm and
    /// refuse keyboard arming and confirming for `strayKeyBlock` seconds, so typing can never finish the two steps.
    fileprivate func strayKey() {
        keyboardBlockedUntil = BackgroundGesture.now() + Self.strayKeyBlock
        disarm()
    }

    fileprivate var keyboardIsBlocked: Bool { BackgroundGesture.now() < keyboardBlockedUntil }

    /// Drop the arm (focus loss, expiry, window close). Sends nothing.
    func disarm() {
        timerToken += 1
        guard armed != nil else { return }
        armed = nil
        refreshAppearance()
        onArmedChange?(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { disarm(); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in self?.disarm()
        })
    }

    // MARK: Pressing

    @objc private func optionPressed(_ sender: NSButton) {
        guard let request = buttons.first(where: { $0.value === sender })?.key else { return }
        let event = BackgroundGesture.currentEvent()
        guard isActive, request.resultingGate != gate,
              BackgroundGesture.isHuman(permit(sender)), isAimed(event, at: sender) else { return }
        if let event, event.continuesAGesture { return }

        if !request.isTurningOff {
            // ON is one gesture; it also ends any arm.
            disarm()
            sendRequest(request)
            return
        }
        if armed == request {
            // The same gesture as the arm is not a confirmation: nothing changes, the expiry still runs.
            if let event, armedBy?.isSame(as: event) == true { return }
            guard secondsSinceArm(event) >= BackgroundGesture.minConfirmDelay else { return }
            disarm()
            sendRequest(request)
        } else {
            arm(request, by: event)
        }
    }

    private func arm(_ request: MotherQuotaGateRequest, by event: NSEvent?) {
        let changed = armed != request
        armed = request
        armedAt = BackgroundGesture.now()
        armedBy = event.map(GestureStamp.init)
        timerToken += 1
        let token = timerToken
        schedule(Self.confirmInterval) { [weak self] in
            guard let self, self.timerToken == token, self.armed != nil else { return }
            self.disarm()
        }
        refreshAppearance()
        if changed { onArmedChange?(request) }
    }

    private func sendRequest(_ request: MotherQuotaGateRequest) {
        inFlight = true
        refreshAppearance()
        send(request, QuotaGateConfirmation())
    }

    /// A mouse event must land inside the button; a key event must reach it as the first responder and be
    /// Space (never Return or Enter, which ordinary typing ends with), outside a stray-key block. No event (an Accessibility press with VoiceOver on) has nothing to aim, so the
    /// gate's own rule for it stands.
    private func isAimed(_ event: NSEvent?, at button: NSButton) -> Bool {
        guard let event else { return true }
        if event.isMouse {
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
        guard event.type == .keyDown, button.window?.firstResponder === button else { return false }
        return event.keyCode == 49 && !keyboardIsBlocked   // Space
    }

    /// Seconds from the arm to this confirm; the smaller of the event clock's and the handler clock's gap,
    /// so neither a forged timestamp nor a bunched handler can shorten it.
    private func secondsSinceArm(_ event: NSEvent?) -> TimeInterval {
        let handlerGap = BackgroundGesture.now() - armedAt
        if let event, let armedBy { return min(event.timestamp - armedBy.timestamp, handlerGap) }
        return handlerGap
    }

    // MARK: Appearance

    private func refreshAppearance() {
        for request in Self.options {
            guard let button = buttons[request] else { continue }
            let selected = request.resultingGate == gate
            let isArmed = armed == request
            button.isEnabled = isActive
            let title = isArmed ? MotherQuotaPresentation.armedTitle(request) : Self.shortTitle(request)
            let color: NSColor = isArmed ? Theme.amber : (selected ? Theme.fg : Theme.fgMuted)
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: selected || isArmed ? .semibold : .regular),
                .foregroundColor: color,
            ])
            button.layer?.backgroundColor = (selected ? NSColor(white: 1, alpha: 0.12) : .clear).cgColor
            button.layer?.borderColor = (isArmed ? Theme.amber : .clear).cgColor
            button.setAccessibilityLabel(isArmed ? MotherQuotaPresentation.armedSpokenLabel(request)
                                                 : MotherQuotaPresentation.optionSpokenLabel(request))
            button.setAccessibilityValue(selected ? "selected" : "not selected")
            button.toolTip = isArmed ? MotherQuotaPresentation.armedPrompt : MotherQuotaPresentation.optionTitle(request)
            button.invalidateIntrinsicContentSize()
        }
    }

    /// Compact titles; the tooltip and the spoken label carry the full words.
    private static func shortTitle(_ request: MotherQuotaGateRequest) -> String {
        switch request {
        case .on: return "On"
        case .offUntilReset: return "Off to reset"
        case .off: return "Off"
        }
    }
}

/// One option of the gate control. Losing focus ends an arm made from the keyboard.
private final class GateOptionButton: NSButton {
    private weak var control: MotherQuotaGateControl?

    init(control: MotherQuotaGateControl) {
        self.control = control
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        controlSize = .small
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Focusable only as a standard button is (full keyboard access), never always: an agent must not be able
    /// to park focus here for the person's next keystrokes to land on.
    override var acceptsFirstResponder: Bool { isEnabled && super.acceptsFirstResponder }

    /// Space presses the button; any other key is ordinary typing and disarms (see `strayKey`).
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 49 {
            performClick(nil)
        } else {
            control?.strayKey()
        }
    }

    override func resignFirstResponder() -> Bool {
        control?.disarm()
        return super.resignFirstResponder()
    }
}

// MARK: - MotherQuotaStrip

/// One compact row under the counts strip: `5h 15% / 90 · resets 8:40 pm   7d 100% / 90 · paused · resets Thu 8 pm`,
/// the gate badge and the control. Zero height while the broker sends no quota block (an older Mother).
///
/// Layout: the text on the left is the one thing that gives way (it truncates, then is all that is lost);
/// the badge and the control keep their width. It re-renders only when what it would show changes, so the
/// block arriving every few seconds moves nothing.
final class MotherQuotaStrip: NSView {
    static let visibleHeight: CGFloat = 26

    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let control: MotherQuotaGateControl

    private var heightConstraint: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()
    private var quota: MotherQuota?
    private var gateError: String?
    private var armed: MotherQuotaGateRequest?
    private var lastShown: Shown?

    /// Everything the strip draws, so an unchanged render is skipped.
    private struct Shown: Equatable {
        var text: NSAttributedString
        var badge: String
        var badgeOff: Bool
        var spoken: String
        var gate: MotherQuotaGate?
        var inFlight: Bool
    }

    /// The accessibility text of the whole strip as last drawn.
    private(set) var spokenSummary = ""
    /// The plain text of the label as last drawn.
    var labelText: String { label.stringValue }
    /// The badge text as last drawn.
    var badgeText: String { badge.stringValue }
    var isOffBadge: Bool { quota?.gate.isOff == true }
    var isShown: Bool { !isHidden }

    var now: () -> Date = { Date() }
    var timeZone: TimeZone = MotherQuotaPresentation.displayTimeZone

    /// - Parameter observeStore: tests pass false and drive `apply` themselves.
    init(control: MotherQuotaGateControl? = nil, observeStore: Bool = true) {
        self.control = control ?? MotherQuotaGateControl { request, confirmation in
            AppStore.shared.requestQuotaGate(request, confirmation: confirmation)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.fgMuted
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.lineBreakMode = .byTruncatingTail
        badge.maximumNumberOfLines = 1
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        self.control.onArmedChange = { [weak self] armed in
            self?.armed = armed
            self?.render()
        }

        addSubview(label)
        addSubview(badge)
        addSubview(self.control)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: self.control.leadingAnchor, constant: -10),
            self.control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            self.control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The badge never pushes the control off the row, whatever the width.
        badge.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16).isActive = true

        if observeStore {
            AppStore.shared.$motherQuota
                .combineLatest(AppStore.shared.$motherQuotaGateInFlight, AppStore.shared.$motherQuotaGateError)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] quota, inFlight, error in self?.apply(quota: quota, inFlight: inFlight, error: error) }
                .store(in: &cancellables)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the broker's quota block (nil: unavailable, the strip and the control disappear), whether a
    /// command is in flight, and the broker's last refusal.
    func apply(quota: MotherQuota?, inFlight: Bool, error: String?) {
        let previousGate = self.quota?.gate
        // An arm is for the block it was made against: a changed reset time alters what "Off until reset" means.
        if control.armed != nil, let old = self.quota, let new = quota, old.until != new.until
            || old.fiveHour?.resetsAt != new.fiveHour?.resetsAt || old.sevenDay?.resetsAt != new.sevenDay?.resetsAt {
            control.disarm()
        }
        self.quota = quota
        gateError = error
        control.update(gate: quota?.gate ?? .unknown(""), inFlight: inFlight)
        render(inFlight: inFlight)
        // The OFF states are announced, once, when the gate becomes one of them.
        if let gate = quota?.gate, gate.isOff, previousGate != gate { announce() }
    }

    private func render(inFlight: Bool? = nil) {
        guard let quota else {
            if !isHidden || lastShown != nil {
                isHidden = true
                heightConstraint.constant = 0
                lastShown = nil
                control.disarm()
            }
            return
        }
        let current = now()
        let text = attributedText(for: quota, now: current)
        let badgeString = MotherQuotaPresentation.badgeText(quota, now: current, timeZone: timeZone)
        let spoken = MotherQuotaPresentation.badgeSpokenText(quota, now: current, timeZone: timeZone)
        let shown = Shown(text: text, badge: badgeString, badgeOff: quota.gate.isOff, spoken: spoken,
                          gate: quota.gate, inFlight: inFlight ?? control.inFlight)
        guard shown != lastShown else { return }
        lastShown = shown

        isHidden = false
        heightConstraint.constant = Self.visibleHeight
        label.attributedStringValue = text
        label.toolTip = text.string
        label.setAccessibilityLabel(text.string)
        badge.stringValue = badgeString
        badge.toolTip = spoken
        badge.setAccessibilityLabel(spoken)
        badge.setAccessibilityRole(.staticText)
        if quota.gate.isOff {
            badge.textColor = NSColor(white: 0.1, alpha: 1)
            badge.layer?.backgroundColor = Theme.amber.cgColor
            badge.drawsBackground = false
        } else {
            badge.textColor = quota.gate.isUnknown ? Theme.amber : Theme.fgMuted
            badge.layer?.backgroundColor = NSColor.clear.cgColor
        }
        spokenSummary = [text.string, spoken].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The text: a prompt while armed, else the broker's refusal, the stale feed and the cap note (all in the
    /// warning colour), then the windows. The notes come first so truncation takes the windows, not them.
    private func attributedText(for quota: MotherQuota, now: Date) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, warning: Bool) {
            if out.length > 0 { out.append(NSAttributedString(string: "   ")) }
            out.append(NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: warning ? .medium : .regular),
                .foregroundColor: warning ? Theme.amber : Theme.fgMuted,
            ]))
        }
        if armed != nil { add(MotherQuotaPresentation.armedPrompt, warning: true) }
        if let gateError { add(gateError, warning: true) }
        if let stale = MotherQuotaPresentation.staleText(quota) { add(stale, warning: true) }
        if quota.capInvalid { add(MotherQuotaPresentation.capInvalidText, warning: true) }
        if armed == nil {
            for (label, window) in [("5h", quota.fiveHour), ("7d", quota.sevenDay)] {
                guard let window else { continue }
                add(MotherQuotaPresentation.windowText(label: label, window, now: now, timeZone: timeZone,
                                                       gate: quota.gate),
                    warning: window.isOverCap)
            }
        }
        return out
    }

    private func announce() {
        NSAccessibility.post(element: badge, notification: .announcementRequested, userInfo: [
            .announcement: badge.accessibilityLabel() ?? badge.stringValue,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
