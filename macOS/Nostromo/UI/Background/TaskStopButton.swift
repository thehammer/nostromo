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

/// A compact Stop button: `Stop` → (click) `Stop?` for `confirmInterval` seconds → (second click)
/// `Stopping…`, disabled. It is hidden when Stop is not offered (the task is over, or the CLI cannot
/// stop tasks). `update` feeds it what the store says; it never decides a task's status.
///
/// Every click, ⌘. and menu selection runs the injected `permit` first and does nothing when refused.
/// The revert timer sends nothing and needs no permit.
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

    /// The button was clicked: `Stop` → `Stop?`, `Stop?` → send.
    @objc func clicked(_ sender: Any?) {
        guard BackgroundGesture.isHuman(permit(self)) else { return }
        advance()
    }

    /// ⌘. (the caller checked the key): the same two steps, each behind its own permit.
    func shortcut() {
        guard isOffered, BackgroundGesture.isHuman(permit(self)) else { return }
        advance()
    }

    /// The context menu's Stop: puts the button into `confirm`; the second click is still required.
    /// Runs `menuPermit` (`menuSelection: true`).
    func arm() {
        guard isOffered, phase == .stop, BackgroundGesture.isHuman(menuPermit(self)) else { return }
        advance()
    }

    /// Stop the revert timer (popover close, window close, focus eviction).
    func invalidate() {
        timerToken += 1
    }

    // MARK: Private

    private func advance() {
        guard isOffered else { return }
        switch phase {
        case .stop:
            phase = .confirm
            timerToken += 1
            let token = timerToken
            schedule(Self.confirmInterval) { [weak self] in
                guard let self, self.timerToken == token, self.phase == .confirm else { return }
                self.phase = .stop
                self.refreshAppearance()
            }
        case .confirm:
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
