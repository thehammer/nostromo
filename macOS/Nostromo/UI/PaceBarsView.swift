import AppKit
import Combine

/// Native gradient pace bars — the macOS replacement for the TUI's pixel-rendered
/// Kitty-graphics hack (pace_bars_image.rs).
///
/// Draws 2–3 horizontal bars (5h, 7d, Sonnet 7d) using NSGradient + NSBezierPath.
/// Fill length = elapsed_pct; tip color = pace_color(pace).
/// Hidden automatically when no PostureSnapshot is available.
class PaceBarsView: NSView {

    // MARK: - Layout

    private let labelWidth:      CGFloat = 28
    private let valueWidth:      CGFloat = 36
    private let barHPad:         CGFloat = 4
    private let barVPad:         CGFloat = 3
    private let barCorner:       CGFloat = 2
    /// Height reserved at the bottom of the view for agent attribution text.
    /// When no agent data is present the area is simply empty.
    private let agentLineHeight: CGFloat = 16

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        AppStore.shared.$posture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let posture = AppStore.shared.posture else {
            // No data — fill with background so the row doesn't flash white.
            Theme.bg.setFill()
            bounds.fill()
            return
        }

        Theme.bg.setFill()
        bounds.fill()

        var bars: [(label: String, window: WindowPace)] = []
        if let w = posture.fiveHour       { bars.append(("5h",  w)) }
        if let w = posture.sevenDay       { bars.append(("7d",  w)) }
        if let w = posture.sonnetSevenDay { bars.append(("S",   w)) }

        guard !bars.isEmpty else { return }

        // Reserve the bottom agentLineHeight pixels for attribution text.
        let barsRegion = bounds.height - agentLineHeight
        let totalVPad  = barVPad * CGFloat(bars.count + 1)
        let barHeight  = max(4, (barsRegion - totalVPad) / CGFloat(bars.count))
        let railX      = labelWidth
        let railW      = bounds.width - labelWidth - valueWidth - barHPad * 2

        for (i, (label, window)) in bars.enumerated() {
            let y = agentLineHeight + barsRegion
                  - barVPad   * CGFloat(i + 1)
                  - barHeight * CGFloat(i + 1)
            drawBar(label: label, window: window,
                    railX: railX, railY: y, railW: railW, barH: barHeight)
        }

        // Agent attribution row (bottom strip).
        drawAgentLine(posture)
    }

    // MARK: - Agent attribution row

    /// Draws a compact agent attribution line in the bottom agentLineHeight pixels.
    ///
    /// Shows each agent's share of the Mother-attributed token total for the
    /// preferred window — "cody 58%  archie 31%  perri 11%  (attr)" — so the
    /// operator can see where the budget is going.
    ///
    /// ⚠️  These are shares of **attributed** usage only, not shares of the full
    /// window budget.  Non-Mother usage is not included.
    private func drawAgentLine(_ posture: PostureSnapshot) {
        guard !posture.agents.isEmpty else { return }

        // Prefer 7d window; fall back to 5h.
        let windowKey = posture.sevenDay != nil ? "7d" : "5h"
        let shares    = posture.attributedShares(for: windowKey)
        guard !shares.isEmpty else { return }

        // Show at most 5 agents to avoid overflow.
        let parts = shares.prefix(5).map { "\($0.name) \(Int(($0.fraction * 100).rounded()))%" }
        let text  = parts.joined(separator: "  ") + "  (attr \(windowKey))"

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            Theme.firaCode(size: 9),
            .foregroundColor: Theme.fgMuted,
        ]
        text.draw(at: NSPoint(x: labelWidth, y: 3), withAttributes: attrs)
    }

    private func drawBar(label: String, window: WindowPace,
                         railX: CGFloat, railY: CGFloat, railW: CGFloat, barH: CGFloat) {
        // ── Label ──────────────────────────────────────────────────────────
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font:            Theme.paceBarFont,
            .foregroundColor: Theme.fgMuted,
        ]
        label.draw(at: NSPoint(x: 4, y: railY + (barH - 10) / 2), withAttributes: labelAttrs)

        // ── Rail background ────────────────────────────────────────────────
        let railRect = NSRect(x: railX, y: railY, width: railW, height: barH)
        let railPath = NSBezierPath(roundedRect: railRect, xRadius: barCorner, yRadius: barCorner)
        Theme.borderInactive.withAlphaComponent(0.4).setFill()
        railPath.fill()

        // ── Filled portion (elapsed_pct) ───────────────────────────────────
        let fillFraction = CGFloat(max(0, min(100, window.elapsedPct))) / 100
        let fillW = railW * fillFraction

        if fillW > 0 {
            let fillRect = NSRect(x: railX, y: railY, width: fillW, height: barH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barCorner, yRadius: barCorner)

            // All bars start vivid green; tip color reflects current pace.
            // Critical bars show the full journey: green → amber → red.
            let (colors, stops) = Theme.paceGradientStops(window.pace)
            if let gradient = NSGradient(colors: colors, atLocations: stops,
                                         colorSpace: .genericRGB) {
                gradient.draw(in: fillPath, angle: 0)
            }
        }

        // ── Pace value ─────────────────────────────────────────────────────
        let paceStr   = String(format: "%.1fx", window.pace)
        let paceColor = Theme.paceColor(window.pace)
        let paceAttrs: [NSAttributedString.Key: Any] = [
            .font:            Theme.paceBarFont,
            .foregroundColor: paceColor,
        ]
        let paceSize = paceStr.size(withAttributes: paceAttrs)
        let paceX = bounds.width - valueWidth + (valueWidth - paceSize.width) / 2
        paceStr.draw(at: NSPoint(x: paceX, y: railY + (barH - 10) / 2), withAttributes: paceAttrs)
    }
}
