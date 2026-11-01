import AppKit
import Combine

/// The bottom 1-row status bar.
///
/// Left side:  Mother counts · activity feed
/// Right side: Budget posture chip · rate-limit windows (5h, 7d)
///
/// Matches the TUI's status_bar.rs layout and color logic.
class StatusBarView: NSView {

    // MARK: - Subviews

    private let leftLabel  = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        for label in [leftLabel, rightLabel] {
            label.font = Theme.statusFont
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])

        // Subscribe to store
        let store = AppStore.shared
        Publishers.CombineLatest(
            store.$motherStatus,
            store.$posture
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.render() }
        .store(in: &cancellables)

        // Re-render whenever the active focus changes (for per-tab attribution).
        store.$activeFocusAgentTag
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        render()

        // Coarse tick so a passed reset or a stale snapshot disappears without a file change.
        // The block captures self weakly, so the run loop's timer does not retain the view.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Rendering

    private func render() {
        leftLabel.attributedStringValue  = buildLeft()
        rightLabel.attributedStringValue = buildRight()
    }

    // MARK: - Left side

    private func buildLeft() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let store = AppStore.shared

        // Mother segment
        if !store.motherStatus.isEmpty {
            out.append(motherSegment(store.motherStatus))
        }

        // Activity is no longer shown here — the ActivityTickerView overlay
        // (see MainLayout) is now the single place that surfaces it, so the
        // same information isn't rendered in two places at once (D9).

        return out
    }

    private func motherSegment(_ s: MotherStatus) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(muted("🏭 "))

        if s.running > 0 {
            out.append(colored("▶\(s.running)", Theme.sage))
            out.append(muted(" "))
        }
        if s.queued > 0 {
            out.append(colored("⏸\(s.queued)", Theme.fgMuted))
            out.append(muted(" "))
        }
        if s.awaiting > 0 {
            out.append(colored("?\(s.awaiting)", Theme.amber))
            out.append(muted(" "))
        }
        if s.failed > 0 {
            out.append(colored("!\(s.failed)", Theme.redSweater))
        }
        return out
    }

    // MARK: - Right side

    private func buildRight() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let store = AppStore.shared
        let now = Date().timeIntervalSince1970

        // A snapshot from a dead Bishop shows no numbers and no posture chip.
        let fresh = store.posture.map { !$0.isStale(now: now) } ?? false

        // Per-tab agent attribution — shown when the active focus's agent tag
        // appears in the agents map.  Shows share of Mother-attributed tokens only.
        if fresh,
           let tag  = store.activeFocusAgentTag,
           let snap = store.posture,
           !snap.agents.isEmpty {
            let windowKey = snap.sevenDay != nil ? "7d" : "5h"
            let shares    = snap.attributedShares(for: windowKey)
            if let mine = shares.first(where: { $0.name == tag }), mine.fraction > 0 {
                let pct = Int((mine.fraction * 100).rounded())
                out.append(muted("\(tag) · \(pct)% attr  "))
            }
        }

        // Budget posture chip — hidden when normal
        if fresh, let p = store.posture?.posture, !p.isHidden {
            out.append(colored(p.chipLabel + "  ", postureChipColor(p)))
        }

        // 5h / 7d windows from Bishop's posture (never a stale number)
        let windows = store.posture?.statusWindows(now: now) ?? []
        for (i, w) in windows.enumerated() {
            out.append(muted("\(w.label) "))
            out.append(colored("\(w.pct)%", Theme.pctColor(w.pct)))
            out.append(muted(" · \(w.remaining)"))
            if i < windows.count - 1 { out.append(muted("  ")) }
        }

        return out
    }

    // MARK: - Attributed string helpers

    private func muted(_ s: String) -> NSAttributedString {
        colored(s, Theme.fgMuted)
    }

    private func colored(_ s: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font:            Theme.statusFont,
            .foregroundColor: color,
        ])
    }

    private func sep() -> NSAttributedString {
        NSAttributedString(string: " │ ", attributes: [
            .font:            Theme.statusFont,
            .foregroundColor: Theme.borderInactive,
        ])
    }

    private func postureChipColor(_ p: BudgetPosture) -> NSColor {
        switch p {
        case .flush, .putTheHammerDown: return Theme.sage
        case .critical, .pumpTheBrakes, .conservative: return Theme.redSweater
        default: return Theme.amber
        }
    }
}
