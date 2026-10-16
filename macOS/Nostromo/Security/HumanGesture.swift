import AppKit

/// Why a control refused to act on an input.
enum HumanGestureRefusal: String, Equatable {
    /// The app-control socket synthesised it.
    case appControl
    /// No current event and VoiceOver is off: an Accessibility press
    /// (`AXPress`) from another process.
    case accessibilityPress
    /// Not a mouse-up/mouse-down/key-down in the control's own window.
    case notAUserEvent
    /// The current event is older than `HumanGesture.maxEventAge`. AppKit
    /// keeps `NSApp.currentEvent` set to the last event it dispatched, even in
    /// later timer and dispatch callbacks, so an event-less action (an
    /// `AXPress` from another process) can arrive while a stale human event is
    /// still "current".
    case staleEvent
}

enum HumanGestureVerdict: Equatable {
    /// A person did it. The event's source pid and source state id (from its
    /// `CGEvent`; nil without an event) are recorded for the OS-level question
    /// of events posted by another process.
    case human(sourcePid: Int64?, sourceState: Int64?)
    case refused(reason: HumanGestureRefusal)
}

/// Decides whether the input that triggered a control's action was a human
/// gesture. Controls that answer an agent call `permit` first and do nothing
/// on `.refused`.
///
/// The event's `eventSourceUnixProcessID` is recorded, not judged. Refusing
/// a nonzero pid other than our own would close OS-level event posting, but
/// the value a real hardware event carries can't be produced in a test here,
/// and a wrong guess would refuse every real click (breaking decisions, which
/// is not a safe failure). It is logged on each permitted answer so the real
/// values can be collected first.
enum HumanGesture {

    /// How old (in seconds) the current event may be and still count as the
    /// gesture behind an action. A real click or key press reaches its control
    /// within milliseconds; one second leaves room for a busy main thread.
    static let maxEventAge: TimeInterval = 1.0

    /// - Parameters:
    ///   - now: the current time on `NSEvent.timestamp`'s clock (seconds since
    ///     boot). A seam for tests.
    ///   - maxEventAge: an event older than this is `.staleEvent`.
    static func permit(_ event: NSEvent?, control: NSView,
                       voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
                       allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic },
                       now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                       maxEventAge: TimeInterval = HumanGesture.maxEventAge)
        -> HumanGestureVerdict {
        if SyntheticInputGate.isSynthetic(event) && !allowsSynthetic() {
            return .refused(reason: .appControl)
        }
        guard let event else {
            return voiceOverEnabled() ? .human(sourcePid: nil, sourceState: nil)
                                      : .refused(reason: .accessibilityPress)
        }
        guard [.leftMouseUp, .leftMouseDown, .keyDown].contains(event.type) else {
            return .refused(reason: .notAUserEvent)
        }
        guard let window = control.window, event.window === window else {
            return .refused(reason: .notAUserEvent)
        }
        guard now() - event.timestamp <= maxEventAge else {
            return .refused(reason: .staleEvent)
        }
        let source = event.cgEvent
        return .human(sourcePid: source?.getIntegerValueField(.eventSourceUnixProcessID),
                      sourceState: source?.getIntegerValueField(.eventSourceStateID))
    }
}
