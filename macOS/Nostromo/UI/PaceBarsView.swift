import AppKit
import Combine

/// Pace-bars / health-status strip — the fixed-height row just above the status bar.
///
/// **Normal mode**: draws 2–3 horizontal gradient bars (5h, 7d, Sonnet 7d).
/// **Health mode**: when the active focus session is unhealthy, replaces the bars
/// with a plain-text status line and Restart / New session / Dismiss buttons.
/// Switching the active focus re-evaluates which mode to show.
///
/// Health mode is exception-only: when all sessions are healthy, the view renders
/// exactly as before.
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

    private var cancellables     = Set<AnyCancellable>()
    private var healthView:      SessionHealthStatusView?

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
            .sink { [weak self] _ in self?.updateHealthOrBars() }
            .store(in: &cancellables)

        AppStore.shared.$sessionHealth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHealthOrBars() }
            .store(in: &cancellables)

        AppStore.shared.$activeFocusAgentTag
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHealthOrBars() }
            .store(in: &cancellables)
    }

    // MARK: - Health vs. bars switching

    /// Derive the active focus's health and update the view accordingly.
    private func updateHealthOrBars() {
        let activeTag    = AppStore.shared.activeFocusAgentTag
        let chatSession  = activeTag.flatMap { AppStore.shared.sessionForHealthView(tag: $0) }
        // `displayedHealth` folds the dismissed flag: returns .healthy when dismissed.
        let activeHealth = chatSession?.displayedHealth
                        ?? activeTag.flatMap { AppStore.shared.sessionHealth[$0] }
                        ?? .healthy

        if activeHealth == .healthy {
            // Remove health overlay (if present) and restore normal bars drawing.
            if let hv = healthView {
                hv.removeFromSuperview()
                healthView = nil
            }
            // Always mark dirty — posture data may have arrived after the first
            // draw (startup race) or changed since. Without this, bars stay blank
            // if posture was nil during the initial layout pass.
            needsDisplay = true
        } else {
            // Show or update health status view.
            if healthView == nil {
                let hv = SessionHealthStatusView()
                hv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(hv)
                NSLayoutConstraint.activate([
                    hv.topAnchor.constraint(equalTo: topAnchor),
                    hv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    hv.trailingAnchor.constraint(equalTo: trailingAnchor),
                    hv.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                healthView = hv
                // Erase the pace-bars drawing underneath.
                needsDisplay = true
            }
            healthView?.configure(health: activeHealth, chatSession: chatSession)
        }
    }

    // MARK: - Drawing (normal mode)

    override func draw(_ dirtyRect: NSRect) {
        // When the health overlay is active, just fill with bg so the bar drawing
        // doesn't bleed through the transparent overlay.
        if healthView != nil {
            Theme.bg.setFill()
            bounds.fill()
            return
        }

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
