import AppKit
import NostromoKit

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
    /// "This focus needs you" marker in the sidebar — violet, so it reads as
    /// distinct from the cornflower selection highlight and the sage/amber/red
    /// session-health dots on a dark background.
    static let attention   = NSColor(red: 192/255, green: 132/255, blue: 252/255, alpha: 1)
    /// "Needs you now" pill background (a pending approval): an explicit dark red so the pill's
    /// white digit reads at 5.6:1 (WCAG AA needs 4.5:1). Not `redSweater`, which is too light for white text.
    static let needsYouNow = NSColor(red: 198/255, green: 40/255, blue: 40/255, alpha: 1)
    /// Cornflower — active tab / border highlight.
    static let cornflower  = NSColor(red: 100/255, green: 149/255, blue: 237/255, alpha: 1)

    static let fg               = NSColor(white: 220/255, alpha: 1)
    static let fgMuted          = NSColor(white: 140/255, alpha: 1)
    static let borderActive     = cornflower
    static let borderInactive   = NSColor(red: 70/255, green: 70/255, blue: 80/255, alpha: 1)

    /// The `N failed` badge on a collapsed tool group. Not `redSweater`: on the row's hover
    /// fill that measures about 4.2:1, under the 4.5:1 floor (see `ToolGroupAppearanceTests`).
    static let foldFailure = NSColor(srgbRed: 248/255, green: 113/255, blue: 113/255, alpha: 1)
    /// A tool group row under the pointer.
    static let foldHover   = NSColor(white: 0.13, alpha: 1)
    /// An agent message folded into an activity row's lane (Focus view): the agent talking,
    /// but quieter than the conversation (`fg`). Same font and size as prose.
    static let foldedProse = NSColor(white: 175/255, alpha: 1)
    /// The 2 pt rule down the left of an expanded activity row's lane.
    static let foldLaneRule = NSColor(white: 100/255, alpha: 1)

    static let bg           = NSColor(calibratedWhite: 0.05, alpha: 1)
    static let bgBar        = NSColor(calibratedWhite: 0.07, alpha: 1)
    /// The selected tab's fill. Deliberately a deeper blue than `cornflower`:
    /// on cornflower, the tab's own label (`fg`) measured 2.48:1 and its
    /// dimmed caption 1.15:1 (live QA, 2026-10-06) — both far under the 4.5:1
    /// WCAG AA minimum, which is why a caption "wasn't visible". On this fill
    /// `fg` is ~6.4:1 and `tabCaptionOnActive` ~5.2:1 (pinned in
    /// `TabRegionViewTests`).
    static let bgBarActive  = NSColor(red: 40/255, green: 70/255, blue: 150/255, alpha: 1)
    /// The dimmed caption's colour on the selected tab (see `bgBarActive`).
    static let tabCaptionOnActive = NSColor(white: 200/255, alpha: 1)

    /// Selected transcript text: an opaque blue (not the system selection colour,
    /// which follows the Mac's light/dark setting rather than this always-dark
    /// theme) with white text on it. Contrast is the WCAG luminance ratio
    /// (L1 + 0.05) / (L2 + 0.05): the fill's luminance is ~0.213, so white on it
    /// is ~4.0:1, and against the near-black card/row surfaces (grey 0.085,
    /// luminance ~0.008) the fill is ~4.5:1, so the highlight stands out
    /// (pinned in `TranscriptSelectionColorTests`).
    static let selectionBackground = NSColor(red: 80/255, green: 125/255, blue: 215/255, alpha: 1)
    static let selectionForeground = NSColor.white
    static let selectionAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: selectionBackground,
        .foregroundColor: selectionForeground,
    ]

    /// Fenced code blocks in a `MarkdownCardView`. Explicit (component-based) and
    /// appearance-independent, like the rest of the always-dark transcript. Against
    /// `bgBar` (the card fill) it is ~1.3:1, so the block reads as a surface; `fg` on
    /// it is ~10:1 and `selectionBackground` on it is ~3.6:1 (all pinned in
    /// `MarkdownCodeBlockTests`).
    static let codeBlockBackground = NSColor(white: 0.16, alpha: 1)

    // MARK: - Syntax highlighting

    /// Token colours in fenced code blocks: explicit sRGB components, appearance-
    /// independent (the app pins Dark Aqua). Contrast on `codeBlockBackground`:
    /// keyword 6.6, type/key 8.4, string 7.6, number/literal 6.5, comment 5.5
    /// (quieter than `fg`), variable 6.2, meta 6.8, inserted 8.3, deleted 5.5.
    private static func syntaxPaletteComponents(_ kind: SyntaxTokenKind) -> (CGFloat, CGFloat, CGFloat) {
        switch kind {
        case .keyword:          return (204, 153, 255)
        case .type, .key:       return (229, 192, 123)
        case .string:           return (152, 200, 121)
        case .number, .literal: return (222, 160, 104)
        case .comment:          return (150, 160, 170)
        case .variable:         return (240, 140, 148)
        case .meta:             return (102, 190, 204)
        case .inserted:         return (126, 214, 140)
        case .deleted:          return (248, 120, 120)
        }
    }

    /// Colour of a token. `dimmed == false` is the palette colour. `dimmed == true`
    /// is for a message folded into an activity lane (`foldedProse`, ~6.6:1 on the
    /// block): the palette colour blended toward `codeBlockBackground` (neutral
    /// grey, so the hue is unchanged) by the largest `t <= 0.25` that keeps WCAG
    /// contrast >= 4.6:1 on `codeBlockBackground`. Dimmed tokens sit at 4.6-6:1. A
    /// fixed `t = 0.25` would drop comment and deleted to ~3.7:1, hence the clamp.
    static func syntaxColor(_ kind: SyntaxTokenKind, dimmed: Bool) -> NSColor {
        let (r, g, b) = syntaxPaletteComponents(kind)
        let base = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        guard dimmed else { return base }
        let t = dimBlend(for: kind)
        let bg = srgbComponents(codeBlockBackground)
        return NSColor(srgbRed: r / 255 + (bg.0 - r / 255) * t,
                       green: g / 255 + (bg.1 - g / 255) * t,
                       blue: b / 255 + (bg.2 - b / 255) * t, alpha: 1)
    }

    private static var dimBlendCache: [SyntaxTokenKind: CGFloat] = [:]
    private static let dimMaxBlend: CGFloat = 0.25
    private static let dimMinContrast: CGFloat = 4.6

    private static func dimBlend(for kind: SyntaxTokenKind) -> CGFloat {
        if let cached = dimBlendCache[kind] { return cached }
        let (r, g, b) = syntaxPaletteComponents(kind)
        let fg = (r / 255, g / 255, b / 255)
        let bg = srgbComponents(codeBlockBackground)
        let bgL = relativeLuminance(bg)
        func contrast(_ t: CGFloat) -> CGFloat {
            let c = (fg.0 + (bg.0 - fg.0) * t, fg.1 + (bg.1 - fg.1) * t, fg.2 + (bg.2 - fg.2) * t)
            let l = relativeLuminance(c)
            return (max(l, bgL) + 0.05) / (min(l, bgL) + 0.05)
        }
        let result: CGFloat
        if contrast(dimMaxBlend) >= dimMinContrast {
            result = dimMaxBlend
        } else {
            var lo: CGFloat = 0, hi = dimMaxBlend
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if contrast(mid) >= dimMinContrast { lo = mid } else { hi = mid }
            }
            result = lo
        }
        dimBlendCache[kind] = result
        return result
    }

    private static func srgbComponents(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    private static func relativeLuminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

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

    /// The code font: Fira Code with its ligatures off. `.ligature: 0` alone does
    /// not do it: Fira Code draws `->`, `::`, `---`, `!=`, `=>`, `<=`, `/*`, `//`
    /// through the OpenType `calt` (contextual alternates) feature. A spike on
    /// 2026-10-16 laid out `"-> :: --- != => <= /* // www"` (28 characters) in
    /// FiraCodeNF-Reg 12 pt through TextKit 1: 20 glyphs differed from the font's
    /// plain glyph for their character with `.ligature: 0` (and with `1`), and 0
    /// with `liga` and `calt` off in the font descriptor. Advance widths and line
    /// height were identical, so turning them off changes no metric. SF Mono
    /// fallback is returned unchanged. Main-thread use only (the cache is unlocked).
    static func codeFont(size: CGFloat) -> NSFont {
        if let cached = codeFontCache[size] { return cached }
        let base = firaCode(size: size)
        let font: NSFont
        if base.fontName.hasPrefix("FiraCodeNF") {
            let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
                [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            ]
            let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: settings])
            font = NSFont(descriptor: descriptor, size: size) ?? base
        } else {
            font = base
        }
        codeFontCache[size] = font
        return font
    }

    private static var codeFontCache: [CGFloat: NSFont] = [:]

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
    static let navRepoHeaderHeight: CGFloat = 32
    /// Height of a clickable focus item row.
    static let navItemHeight:       CGFloat = 40
    /// Height of a clickable focus item row that carries a secondary subtitle label.
    static let navItemSubtitleHeight: CGFloat = 52
    /// Extra leading inset for agent rows nested under a repo-group header.
    static let navChildIndent:      CGFloat = 12
    /// Font for org section labels (uppercase, small, muted).
    static let navOrgFont  = NSFont.systemFont(ofSize: 10, weight: .semibold)
    /// Font for repo-group header labels and for the top-level (non-indented) focus rows.
    static let navRepoFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Colour for repo-group header labels and inactive top-level focus rows (a step brighter than `fgMuted`).
    static let navRepoColor = NSColor(white: 175/255, alpha: 1)
    /// Leading inset of a repo-group header label (agent rows nested under it sit at `6 + navChildIndent`).
    static let navRepoHeaderLeading: CGFloat = 6
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
