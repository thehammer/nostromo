import AppKit
import NostromoKit

/// The one human-gesture check every Background Stop route runs first (`HumanGesture.permit`, as
/// Approvals and `TerminalInputGuard.allowsControl` do). Stop changes the world and the daemon verb is
/// not nonce-gated, so this is the only human check: a refused gesture does nothing.
enum BackgroundGesture {
    typealias Permit = (NSView) -> HumanGestureVerdict

    /// The current event, held to `HumanGesture`'s rules for `control`'s window.
    static let defaultPermit: Permit = { control in
        HumanGesture.permit(NSApp?.currentEvent, control: control)
    }

    /// A context menu's Stop: its mouse event belongs to the menu, not to the control's window.
    static let defaultMenuPermit: Permit = { control in
        HumanGesture.permit(NSApp?.currentEvent, control: control, menuSelection: true)
    }

    /// The event behind the action being handled (a seam: tests script it; `permit` still reads AppKit's).
    static var currentEvent: () -> NSEvent? = { NSApp?.currentEvent }
    /// Seconds on `NSEvent.timestamp`'s clock; the arm/confirm spacing is measured with it (a seam).
    static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// A confirm sooner than this after the arm is the same gesture (a double-click, a held key), not a second.
    static let minConfirmDelay: TimeInterval = 0.3

    static func isHuman(_ verdict: HumanGestureVerdict) -> Bool {
        if case .human = verdict { return true }
        return false
    }

    /// ⌘. (no other modifier).
    static func isStopShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags == .command && event.charactersIgnoringModifiers == "."
    }
}

/// What identifies the event that armed Stop, so the confirming one can be told apart from it.
private struct GestureStamp {
    let timestamp: TimeInterval
    let type: NSEvent.EventType
    /// Mouse events only (`eventNumber` is not valid on a key event).
    let eventNumber: Int?
    let keyCode: UInt16?

    init(_ event: NSEvent) {
        timestamp = event.timestamp
        type = event.type
        if event.isMouse {
            eventNumber = event.eventNumber
            keyCode = nil
        } else {
            eventNumber = nil
            keyCode = event.type == .keyDown ? event.keyCode : nil
        }
    }

    func isSame(as event: NSEvent) -> Bool {
        guard event.timestamp == timestamp, event.type == type else { return false }
        return event.isMouse ? event.eventNumber == eventNumber : event.keyCode == keyCode
    }
}

private extension NSEvent {
    var isMouse: Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    /// A key repeat or the second click of a multi-click: the continuation of a gesture, never a new one.
    var continuesAGesture: Bool {
        if type == .keyDown { return isARepeat }
        return isMouse && clickCount > 1
    }
}

/// A compact Stop button: `Stop` → (click) `Stop?` for `confirmInterval` seconds → (second click)
/// `Stopping…`, disabled. It is hidden when Stop is not offered (the task is over, or the CLI cannot
/// stop tasks). `update` feeds it what the store says; it never decides a task's status.
///
/// Every click, ⌘. and menu selection runs the injected `permit` first and does nothing when refused.
/// The revert timer sends nothing and needs no permit.
///
/// One human gesture never arms and confirms: the arm records its event and time, and the confirm is
/// refused when it is the same event, comes within `BackgroundGesture.minConfirmDelay` of the arm, is a
/// key repeat or is a click after the first of a double-click. Arming refuses repeats and multi-clicks
/// too. A refused confirm leaves the armed state and its revert timer as they were.
final class TaskStopButton: NSButton {
    enum Phase: Equatable {
        case stop, confirm, stopping
    }

    static let confirmInterval: TimeInterval = 3
    static let maxDescriptionInLabel = 80

    private(set) var phase: Phase = .stop
    private(set) var isOffered = false
    /// The task's description (sanitised by the caller), for the accessibility label.
    private var taskDescription = ""
    private var timerToken = 0
    private var armedAt: TimeInterval = 0
    private var armedBy: GestureStamp?
    private let permit: BackgroundGesture.Permit
    private let menuPermit: BackgroundGesture.Permit
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let requestStop: () -> Void

    /// - Parameters:
    ///   - permit: the human-gesture check, given this button; `menuPermit` the context menu's.
    ///   - schedule: runs the 3 s revert after a delay on the main thread (tests pass a manual one).
    ///   - requestStop: sends the stop (the store's `requestStop`); runs only after a permitted second click.
    init(permit: @escaping BackgroundGesture.Permit = BackgroundGesture.defaultPermit,
         menuPermit: @escaping BackgroundGesture.Permit = BackgroundGesture.defaultMenuPermit,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         requestStop: @escaping () -> Void) {
        self.permit = permit
        self.menuPermit = menuPermit
        self.schedule = schedule
        self.requestStop = requestStop
        super.init(frame: .zero)
        bezelStyle = .inline
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        isBordered = true
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked(_:))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show what the store says about the task. `stopping` forces the `Stopping…` state; when the
    /// store's stop state is gone (failed, or the task is over) a `Stopping…` button goes back to `Stop`.
    func update(_ display: BackgroundTaskStore.StopDisplay, description: String) {
        taskDescription = description
        isOffered = display.offered
        if display.stopping {
            invalidate()
            phase = .stopping
        } else if phase == .stopping || !display.offered {
            invalidate()
            phase = .stop
        }
        refreshAppearance()
    }

    /// The button was clicked (or activated by Space or Return): `Stop` → `Stop?`, `Stop?` → send.
    @objc func clicked(_ sender: Any?) {
        guard BackgroundGesture.isHuman(permit(self)) else { return }
        advance(by: BackgroundGesture.currentEvent())
    }

    /// ⌘. (the caller checked the key; `event` is that key event): the same two steps, each behind its own permit.
    func shortcut(_ event: NSEvent? = nil) {
        guard isOffered, BackgroundGesture.isHuman(permit(self)) else { return }
        advance(by: event ?? BackgroundGesture.currentEvent())
    }

    /// The context menu's Stop: puts the button into `confirm`; the second click is still required.
    /// Runs `menuPermit` (`menuSelection: true`).
    func arm() {
        guard isOffered, phase == .stop, BackgroundGesture.isHuman(menuPermit(self)) else { return }
        advance(by: BackgroundGesture.currentEvent())
    }

    /// Stop the revert timer (popover close, window close, focus eviction).
    func invalidate() {
        timerToken += 1
    }

    // MARK: Private

    private func advance(by event: NSEvent?) {
        guard isOffered else { return }
        if let event, event.continuesAGesture { return }
        switch phase {
        case .stop:
            phase = .confirm
            armedAt = BackgroundGesture.now()
            armedBy = event.map(GestureStamp.init)
            timerToken += 1
            let token = timerToken
            schedule(Self.confirmInterval) { [weak self] in
                guard let self, self.timerToken == token, self.phase == .confirm else { return }
                self.phase = .stop
                self.refreshAppearance()
            }
        case .confirm:
            // The same gesture as the arm is not a confirmation: nothing changes, the revert still runs.
            if let event, armedBy?.isSame(as: event) == true { return }
            guard BackgroundGesture.now() - armedAt >= BackgroundGesture.minConfirmDelay else { return }
            invalidate()
            phase = .stopping
            requestStop()
        case .stopping:
            break
        }
        refreshAppearance()
    }

    private func refreshAppearance() {
        isHidden = !isOffered
        isEnabled = phase != .stopping
        let label = taskDescription.isEmpty ? "task" : taskDescription
        switch phase {
        case .stop:
            title = "Stop"
            setAccessibilityLabel("Stop \(label)")
        case .confirm:
            title = "Stop?"
            setAccessibilityLabel("Confirm stop \(label)")
        case .stopping:
            title = "Stopping\u{2026}"
            setAccessibilityLabel("Stopping \(label)")
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: BackgroundPalette.text,
        ])
        invalidateIntrinsicContentSize()
    }
}

/// The inline text beside a task's real status when Stop did not work (`Couldn't stop: <reason>`), or
/// when this Claude Code cannot stop tasks. One line, truncating: it never grows its row or header.
enum TaskStopNotice {
    static let unsupportedText = "This Claude Code version can't stop tasks from Nostromo"

    static func failureText(_ reason: String) -> String { "Couldn't stop: \(reason)" }

    static func text(for display: BackgroundTaskStore.StopDisplay, showUnsupported: Bool) -> String? {
        if let reason = display.failure { return failureText(reason) }
        if showUnsupported, display.unsupported { return unsupportedText }
        return nil
    }

    /// A label for the notice: one line, truncating, with a low compression resistance.
    static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = BackgroundPalette.failed
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isSelectable = false
        label.drawsBackground = false
        label.cell?.truncatesLastVisibleLine = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    static func apply(_ text: String?, unsupported: Bool, to label: NSTextField) {
        label.isHidden = text == nil
        label.stringValue = text ?? ""
        label.toolTip = text
        label.textColor = unsupported ? BackgroundPalette.muted : BackgroundPalette.failed
        label.setAccessibilityLabel(text)
    }
}
