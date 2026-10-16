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
enum HumanGesture {

    static func permit(_ event: NSEvent?, control: NSView,
                       voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
                       allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic })
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
        let source = event.cgEvent
        return .human(sourcePid: source?.getIntegerValueField(.eventSourceUnixProcessID),
                      sourceState: source?.getIntegerValueField(.eventSourceStateID))
    }
}
