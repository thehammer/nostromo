import AppKit

/// What makes a remote pane unmistakable, derived from the daemon's `TerminalInfo` alone: no view
/// state, no SwiftTerm. Every `ecs` pane is hazard red whatever its environment (production, canada,
/// demo, staging), each labelled with its own name.
enum TerminalChromeModel {

    /// Width of the red frame around a remote pane.
    static let frameWidth: CGFloat = 3

    static func isRemote(_ info: TerminalInfo) -> Bool {
        info.kind == .ecs
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
            guard info.tag == tag, isRemote(info), info.status != .ended,
                  let environment = info.target?.environment, !environment.isEmpty else { return nil }
            return environment.uppercased()
        })
        return names.sorted { a, b in
            if (a == "PRODUCTION") != (b == "PRODUCTION") { return a == "PRODUCTION" }
            return a < b
        }
    }

    /// "<focus label> — PRODUCTION" (environments joined with ", "), or the plain label.
    static func windowTitle(focusLabel: String, environments: [String]) -> String {
        environments.isEmpty ? focusLabel : "\(focusLabel) \u{2014} \(environments.joined(separator: ", "))"
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
