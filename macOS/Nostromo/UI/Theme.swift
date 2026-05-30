import AppKit

// MARK: - DarkSplitView

/// NSSplitView with a divider color that matches the dark theme border.
/// Used everywhere we need a resizable pane split.
class DarkSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.borderInactive }
}

// MARK: - Theme

/// Color palette and font constants — ported from the TUI's theme.rs.
enum Theme {

    // MARK: - Colors

    /// Vivid green — all-clear / low load.
    static let sage        = NSColor(red:  34/255, green: 197/255, blue:  94/255, alpha: 1)
    /// Warm amber — attention / moderate load.
    static let amber       = NSColor(red: 234/255, green: 179/255, blue:   8/255, alpha: 1)
    /// Red — alert / high load.
    static let redSweater  = NSColor(red: 239/255, green:  68/255, blue:  68/255, alpha: 1)
    /// Cornflower — active tab / border highlight.
    static let cornflower  = NSColor(red: 100/255, green: 149/255, blue: 237/255, alpha: 1)

    static let fg               = NSColor(white: 220/255, alpha: 1)
    static let fgMuted          = NSColor(white: 140/255, alpha: 1)
    static let borderActive     = cornflower
    static let borderInactive   = NSColor(red: 70/255, green: 70/255, blue: 80/255, alpha: 1)

    static let bg           = NSColor(calibratedWhite: 0.05, alpha: 1)
    static let bgBar        = NSColor(calibratedWhite: 0.07, alpha: 1)
    static let bgBarActive  = cornflower

    // MARK: - Fonts

    static let tabFont       = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let tabFontBold   = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let statusFont    = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let monoFont      = firaCode(size: 13)
    static let paceBarFont   = firaCode(size: 11)

    /// Fira Code Nerd Font with SF Mono fallback.
    static func firaCode(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .light:    name = "FiraCodeNF-Light"
        case .medium:   name = "FiraCodeNF-Med"
        case .semibold: name = "FiraCodeNF-SemBd"
        case .bold:     name = "FiraCodeNF-Bold"
        default:        name = "FiraCodeNF-Reg"
        }
        return NSFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Metrics

    static let tabBarHeight:    CGFloat = 26   // legacy; kept for reference
    static let sidebarWidth:    CGFloat = 80
    static let statusBarHeight: CGFloat = 22
    static let paceBarsHeight:  CGFloat = 28   // enough for 2 bars at ~10px each + padding

    // MARK: - Helpers

    /// Map a pace value to a vivid tip color: ≥1.5 → red, ≥1.1 → amber, else green.
    static func paceColor(_ pace: Float) -> NSColor {
        if pace >= 1.5 { return redSweater }
        if pace >= 1.1 { return amber }
        return sage
    }

    /// Gradient stops for a pace bar. All bars start vivid green; critical bars
    /// show the full journey green → amber → red.
    static func paceGradientStops(_ pace: Float) -> ([NSColor], [CGFloat]) {
        if pace >= 1.5 {
            return ([sage, amber, redSweater], [0, 0.5, 1.0])
        } else if pace >= 1.1 {
            return ([sage, amber], [0, 1.0])
        } else {
            // Subtle: slightly deeper green start so there's still a visible gradient
            let dimGreen = NSColor(red: 0.04, green: 0.30, blue: 0.13, alpha: 1)
            return ([dimGreen, sage], [0, 1.0])
        }
    }

    /// Percent-to-color for rate-limit bars: ≥80% → red, ≥50% → amber, else sage.
    static func pctColor(_ pct: Int) -> NSColor {
        if pct >= 80 { return redSweater }
        if pct >= 50 { return amber }
        return sage
    }

    /// Format remaining seconds as "Xh" or "Xm".
    static func formatReset(_ secs: TimeInterval) -> String {
        if secs >= 3600 { return "\(Int(secs / 3600))h" }
        return "\(max(1, Int(secs / 60)))m"
    }
}
