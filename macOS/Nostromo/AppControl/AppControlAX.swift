import AppKit

/// A findable thing on screen: a real NSView, or an accessibility element inside a SwiftUI hosting
/// view (SwiftUI draws its own text, so there is no NSView to find: only its accessibility tree knows
/// what is shown).
struct AppControlHit {
    let cls: String
    let text: String?
    let rectInWindow: NSRect      // AppKit window coordinates (bottom-left origin)
}

/// What `AppControlServer`'s `tree`, `find` and `ax` read out of the accessibility tree. Split out of
/// the server so the test target can run it over its own views.
///
/// Everything here reads `accessibilityLabel`, `accessibilityTitle` and `accessibilityValue`, so a
/// view that puts private text in its accessibility value hands it to app-control. A terminal view
/// must therefore not (`TerminalScreenAccess`): an agent may read a terminal's screen only through
/// `nostromo_read_terminal_screen`, which follows and redacts.
enum AppControlAX {

    /// Read an accessibility property from an element that may not formally
    /// conform to `NSAccessibilityProtocol` (AppKit's `NSOutlineRow` row proxies
    /// do not), via KVC on the getter of the same name.
    static func value(_ e: AnyObject, _ key: String) -> Any? {
        guard let o = e as? NSObject, o.responds(to: Selector(key)) else { return nil }
        return o.value(forKey: key)
    }

    /// Accessibility elements under `view`, depth-limited, as hits.
    static func hits(under view: NSView, in w: NSWindow) -> [AppControlHit] {
        var out: [AppControlHit] = []
        func walk(_ element: AnyObject, depth: Int) {
            guard depth < 14 else { return }
            let frame = (value(element, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            let strings = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                .compactMap { value(element, $0) as? String }.filter { !$0.isEmpty }
            let winFrame = w.convertFromScreen(frame)
            if !strings.isEmpty, winFrame.width > 0, winFrame.height > 0 {
                let role = (value(element, "accessibilityRole") as? String) ?? "AXElement"
                out.append(AppControlHit(cls: "ax:" + role, text: strings.joined(separator: " — "), rectInWindow: winFrame))
            }
            for child in (value(element, "accessibilityChildren") as? [AnyObject]) ?? [] { walk(child, depth: depth + 1) }
        }
        for child in view.accessibilityChildren() ?? [] { if let c = child as AnyObject? { walk(c, depth: 0) } }
        return out
    }

    /// The raw accessibility tree under `element` (type, role, label, value, children), as `ax` prints it.
    static func dump(_ e: Any, _ d: Int) -> [String: Any] {
        guard let ax = e as? NSAccessibilityProtocol else { return ["raw": "\(e)"] }
        var n: [String: Any] = ["type": "\(Swift.type(of: ax))", "role": ax.accessibilityRole()?.rawValue ?? ""]
        if let l = ax.accessibilityLabel() { n["label"] = l }
        if let v = ax.accessibilityValue() as? String { n["value"] = v }
        if d < 6 { n["children"] = (ax.accessibilityChildren() ?? []).map { dump($0, d + 1) } }
        return n
    }
}
