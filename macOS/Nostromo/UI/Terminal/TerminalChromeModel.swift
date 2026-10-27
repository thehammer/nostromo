import AppKit

/// What makes a remote pane unmistakable, derived from the daemon's `TerminalInfo` alone: no view
/// state, no SwiftTerm. Every pane that is not known to be local (`ecs`, or a kind this app does not
/// know, which decodes to `.unknown`) is hazard red whatever its environment (production, canada,
/// demo, staging), each labelled with its own name; one without a target says "REMOTE".
enum TerminalChromeModel {

    /// Width of the red frame around a remote pane.
    static let frameWidth: CGFloat = 3

    /// Only a pane known to be local is not remote: anything else fails toward the warning.
    static func isRemote(_ info: TerminalInfo) -> Bool {
        isRemote(kind: info.kind)
    }

    /// `nil` (no pane information yet) is remote too.
    static func isRemote(kind: TerminalKind?) -> Bool {
        kind != .local
    }

    /// Shown where a target's environment would be when the daemon sent none.
    static let unknownEnvironment = "REMOTE"

    /// What the paste confirmation calls a shell whose target is not known.
    static let unknownTargetText = "REMOTE shell"

    /// "PRODUCTION", or "REMOTE" when there is no target.
    static func environmentToken(for info: TerminalInfo) -> String {
        guard let environment = info.target?.environment, !environment.isEmpty else { return unknownEnvironment }
        return environment.uppercased()
    }

    /// "PRODUCTION · admin-portal · scheduler", or "REMOTE shell" when the target (or the pane) is unknown.
    static func pasteTargetText(for info: TerminalInfo?) -> String {
        info?.target.map(targetText) ?? unknownTargetText
    }

    /// The header text after the environment token: "admin-portal · scheduler · shell", or the label.
    static func headerDetail(for info: TerminalInfo) -> String {
        guard isRemote(info), let target = info.target else { return info.label }
        return [target.project, target.service, target.shellType].joined(separator: " \u{00B7} ")
    }

    /// "PRODUCTION · admin-portal · scheduler · shell" for a remote shell; the label for a local one.
    static func headerText(for info: TerminalInfo) -> String {
        guard isRemote(info), let target = info.target else { return info.label }
        return targetText(target) + " \u{00B7} " + target.shellType
    }

    /// "PRODUCTION · admin-portal · scheduler".
    static func targetText(_ target: TerminalTarget) -> String {
        [target.environment.uppercased(), target.project, target.service].joined(separator: " \u{00B7} ")
    }

    /// Hazard red for a remote pane, nil for a local one.
    static func frameColor(for info: TerminalInfo) -> NSColor? {
        isRemote(info) ? Theme.hazardRed : nil
    }

    /// The distinct environments (uppercased) of the open remote panes in focus `tag`: production
    /// first, the rest alphabetical. An ended pane is not open.
    static func focusEnvironmentLabels(_ terminals: [TerminalInfo], tag: String) -> [String] {
        let names = Set(terminals.compactMap { info -> String? in
            guard info.tag == tag, isRemote(info), info.status != .ended else { return nil }
            return environmentToken(for: info)
        })
        return names.sorted { a, b in
            if (a == "PRODUCTION") != (b == "PRODUCTION") { return a == "PRODUCTION" }
            return a < b
        }
    }

    /// "PRODUCTION — <focus label>" (environments joined with ", "), or the plain label. The environment
    /// is first: the focus label is agent-controllable and the Window menu and Mission Control cut a
    /// long title's tail.
    static func windowTitle(focusLabel: String, environments: [String]) -> String {
        environments.isEmpty ? focusLabel : "\(environments.joined(separator: ", ")) \u{2014} \(focusLabel)"
    }

    /// WCAG contrast ratio of two colours (1...21).
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            func lin(_ v: CGFloat) -> Double {
                let x = Double(v)
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
