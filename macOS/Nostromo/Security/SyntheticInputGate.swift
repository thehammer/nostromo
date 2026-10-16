import AppKit

/// Tells input the app-control socket synthesised from input a person made.
///
/// Controls that answer an agent (a decision's choices today, an approval's
/// Allow next) must accept only a human gesture: an agent can drive the
/// app-control socket (`bin/nostromo-app click/key/type`), so a click from
/// there must never answer for the human. Two signals, either one enough:
///
/// - **Depth.** `AppControlServer` runs every request between `begin()` and
///   `end()` on the main thread, so anything a control sees while the depth is
///   above zero came from app-control.
/// - **Marker.** Key events app-control synthesises carry `marker` in their
///   `CGEvent` `.eventSourceUserData`, so one that is delivered later is still
///   recognised. (Its clicks can't be stamped; see `stamped(_:)`.)
///
/// Main thread only, like the events it judges.
enum SyntheticInputGate {

    /// Stamped into `.eventSourceUserData` of every synthesised event
    /// ("NSTMOAP1"). Arbitrary but fixed; real input carries 0 here.
    static let marker: Int64 = 0x4E53_544D_4F41_5031

    /// How many app-control requests are running on the main thread right now.
    private(set) static var depth = 0

    static func begin() {
        depth += 1
    }

    /// Never drops below zero, so a stray `end()` can't mask the next request.
    static func end() {
        depth = max(0, depth - 1)
    }

    /// True while app-control is running a request, or when `event` carries the marker.
    static func isSynthetic(_ event: NSEvent?) -> Bool {
        if depth > 0 { return true }
        return event?.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// A synthesised key event with the marker stamped in, keeping its window,
    /// characters, key code and modifiers. Built through the event's own
    /// `CGEvent` (a `CGEvent` made from scratch loses the window). Returns the
    /// event unchanged if the round trip changes anything.
    ///
    /// Key events only: `NSEvent(cgEvent:)` rebuilds a mouse event's window
    /// location from its screen location, and does so unreliably (the same
    /// `CGEvent` converted twice lands on different points), so app-control's
    /// clicks are not stamped. They are delivered while the request runs, so
    /// the depth marks them synthetic.
    static func stamped(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown || event.type == .keyUp, let cg = event.cgEvent else { return event }
        cg.setIntegerValueField(.eventSourceUserData, value: marker)
        guard let out = NSEvent(cgEvent: cg), out.type == event.type,
              out.windowNumber == event.windowNumber, out.keyCode == event.keyCode,
              out.characters == event.characters,
              out.charactersIgnoringModifiers == event.charactersIgnoringModifiers,
              out.modifierFlags.intersection(.deviceIndependentFlagsMask)
                == event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        else { return event }
        return out
    }

    /// Whether this process may accept synthetic input as human: only a QA
    /// build (bundle id other than the user's app) started with
    /// `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1`. The user's app never does.
    static var allowsSynthetic: Bool {
        allowsSynthetic(bundleIdentifier: Bundle.main.bundleIdentifier,
                        environment: ProcessInfo.processInfo.environment)
    }

    static func allowsSynthetic(bundleIdentifier: String?, environment: [String: String]) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != userAppBundleIdentifier else { return false }
        return environment["NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT"] == "1"
    }

    private static let userAppBundleIdentifier = "com.hammer.nostromo"
}
