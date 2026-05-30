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

    private let labelWidth:  CGFloat = 28
    private let valueWidth:  CGFloat = 36
    private let barHPad:     CGFloat = 4
    private let barVPad:     CGFloat = 3
    private let barCorner:   CGFloat = 2

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

        let totalVPad = barVPad * CGFloat(bars.count + 1)
        let barHeight = max(4, (bounds.height - totalVPad) / CGFloat(bars.count))
        let railX     = labelWidth
        let railW     = bounds.width - labelWidth - valueWidth - barHPad * 2

        for (i, (label, window)) in bars.enumerated() {
            let y = bounds.height - barVPad * CGFloat(i + 1) - barHeight * CGFloat(i + 1)
            drawBar(label: label, window: window,
                    railX: railX, railY: y, railW: railW, barH: barHeight)
        }
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

            // Draw the full green→yellow→orange→red spectrum scaled to the whole
            // rail, clipped to the fill region.  The visible tip naturally shows
            // where in the budget you sit — no need to pick a tip color manually.
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()
            let spectrumColors: [NSColor] = [
                NSColor(red: 0.04, green: 0.30, blue: 0.16, alpha: 1),  // deep forest
                NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1),  // vivid green
                NSColor(red: 0.92, green: 0.70, blue: 0.03, alpha: 1),  // yellow
                NSColor(red: 0.95, green: 0.35, blue: 0.08, alpha: 1),  // orange
                NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1),  // red
            ]
            let stops: [CGFloat] = [0, 0.38, 0.65, 0.82, 1.0]
            if let gradient = NSGradient(colors: spectrumColors,
                                         atLocations: stops,
                                         colorSpace: .genericRGB) {
                gradient.draw(in: NSRect(x: railX, y: railY, width: railW, height: barH),
                              angle: 0)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // ── Pace value ─────────────────────────────────────────────────────
        let paceStr   = String(format: "%.2f", window.pace)
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
