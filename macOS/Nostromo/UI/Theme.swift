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
    // Widened from 80 → 160 to accommodate the Org → Repo → Agent hierarchy.
    // The extra width is required: repo names like "Admin Portal" and left-aligned
    // indented labels are not legible at 80px.
    static let sidebarWidth:    CGFloat = 160
    static let statusBarHeight: CGFloat = 22
    /// Tall enough for 2–3 pace bars (top ~30px) + agent attribution text row (~16px).
    static let paceBarsHeight:  CGFloat = 46

    // MARK: Sidebar hierarchy layout

    /// Height of an org-section header row (e.g. "CAREFEED").
    static let navOrgHeaderHeight:  CGFloat = 28
    /// Height of a repo-group header row (non-clickable; sits above indented agent rows).
    static let navRepoHeaderHeight: CGFloat = 28
    /// Height of a clickable focus item row.
    static let navItemHeight:       CGFloat = 40
    /// Height of a clickable focus item row that carries a secondary subtitle label.
    static let navItemSubtitleHeight: CGFloat = 52
    /// Extra leading inset for agent rows nested under a repo-group header.
    static let navChildIndent:      CGFloat = 12
    /// Font for org section labels (uppercase, small, muted).
    static let navOrgFont  = NSFont.systemFont(ofSize: 10, weight: .semibold)
    /// Font for repo-group header labels.
    static let navRepoFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    /// Font for optional secondary disambiguation line on agent rows.
    static let navSubFont  = NSFont.systemFont(ofSize: 10, weight: .regular)

    // MARK: - Helpers

    /// Smooth spectrum color sweeping HSB hue from 180° (aqua) → 0° (alarm red).
    /// t=0 → aqua, t=0.25 → green, t=0.5 → yellow, t=0.75 → orange, t=1 → red.
    static func spectrumColor(t: Float) -> NSColor {
        let hue        = CGFloat(0.65 * (1.0 - Double(t)))
        let saturation = CGFloat(1.0)
        let brightness = CGFloat(0.88)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    /// Pace text color: maps pace linearly across the spectrum (0.5× → aqua, 1.5× → red).
    static func paceColor(_ pace: Float) -> NSColor {
        let t = max(0, min(1, (pace - 0.5) / 1.0))
        return spectrumColor(t: t)
    }

    /// Gradient for a pace bar, sampling the aqua→red HSB spectrum.
    ///
    /// Every bar starts at aqua. The point where budget hits 100% is treated as
    /// red; if that point falls beyond the current fill, the bar shows only the
    /// cooler portion of the spectrum. If pace is high enough that exhaustion
    /// falls inside the fill, the gradient reaches red at that point and holds
    /// solid red for the remainder.
    ///
    /// - pace: used_pct / elapsed_pct
    /// - elapsedFrac: fraction of window elapsed (0–1), which determines fill width
    static func paceBarGradient(pace: Float, elapsedFrac: Float,
                                paceSmoothed: Float? = nil, usedPct: Float = 0) -> NSGradient? {
        guard elapsedFrac > 0, pace > 0 else {
            return NSGradient(colors: [spectrumColor(t: 0), spectrumColor(t: 0)])
        }
        // When the OAuth API has capped used_pct at 100, `pace` is derived from 100/elapsed
        // and gives usedFrac ≈ 1.0 — the red boundary collapses to one invisible pixel.
        // Use pace_smoothed instead: it's a rolling average that reflects true burn rate
        // independently of the cap, so it correctly places the exhaustion boundary.
        // When usedPct is capped at 100, fall back to paceSmoothed for a realistic
        // exhaustion boundary; otherwise pace × elapsed collapses to ≈ 1.0 exactly.
        let effectivePace: Float
        if usedPct >= 100, let ps = paceSmoothed, ps > pace {
            effectivePace = ps
        } else {
            effectivePace = pace
        }
        let usedFrac = CGFloat(effectivePace) * CGFloat(elapsedFrac)

        // Sample at 16 equidistant steps — enough to make the hue sweep visually
        // smooth when NSGradient interpolates linearly in RGB space.
        // min(1.0, u * usedFrac) naturally clamps at red and holds it flat when
        // usedFrac > 1.0 (budget already exceeded at some point in the fill).
        let steps = 16
        var colors:    [NSColor]  = []
        var locations: [CGFloat]  = []
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            let t = Float(min(1.0, u * usedFrac))
            colors.append(spectrumColor(t: t))
            locations.append(u)
        }
        var locs = locations
        return NSGradient(colors: colors, atLocations: &locs, colorSpace: .genericRGB)
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
