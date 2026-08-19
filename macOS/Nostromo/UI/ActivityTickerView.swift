import AppKit
import Combine

/// Always-visible one-line ambient-activity ticker.
///
/// Modeled on `ToastBannerView`'s "pin over content, `hitTest` passthrough
/// for non-content areas" idiom — installed the same way in `MainLayout`,
/// spanning the content area between the sidebar and the status bar so it
/// draws on top without stealing space from a content pane (R1: the activity
/// surface "is not a tab in the detail region and never competes with
/// content for it").
///
/// Unlike `ToastBannerView` this view has **none of its transience**: no
/// auto-dismiss timer, no fade. It is always present, pinned to the bottom
/// edge of its bounds, and shows exactly one line until the operator clicks
/// it to expand a taller per-agent panel.
///
/// Inviolable property (PRD): an arriving activity event must never take
/// focus, never change scroll position, and never change the first
/// responder. This view only ever updates its own label text/subviews in
/// response to `AppStore` changes — it never steals first-responder status
/// or moves a scroll position, and (unlike the toast it's modeled on) it
/// never schedules a delayed dismissal of itself.
///
/// (Enforced by `ActivityTickerWiringTests`, which greps this file's raw
/// source for the exact AppKit call names — so this doc comment
/// deliberately avoids spelling them out verbatim.)
class ActivityTickerView: NSView {

    // MARK: - Constants

    private static let lineHeight: CGFloat = 22

    // MARK: - Subviews

    private let line = NSTextField(labelWithString: "")
    private var expandedPanel: NSStackView?

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var currentFocusTag: String?
    private var isExpanded = false

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
        // Fully transparent except for the line/panel subviews — only they
        // are visible, matching ToastBannerView's own container.

        line.font = Theme.statusFont
        line.textColor = Theme.fgMuted
        line.lineBreakMode = .byTruncatingTail
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.bgBar.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: Self.lineHeight),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded))
        line.addGestureRecognizer(click)

        // Re-render on every focus switch (a different tag's stream), on
        // every activity ingest, and on every health update.
        AppStore.shared.$activeFocusAgentTag
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tag in
                self?.currentFocusTag = tag
                self?.render()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(AppStore.shared.$activityModels, AppStore.shared.$activityHealth)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.render() }
            .store(in: &cancellables)

        render()
    }

    // MARK: - Hit testing passthrough

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let all non-ticker-subview clicks fall through to views underneath
        // — the ticker never blocks interaction with the content pane it's
        // drawn over.
        for sub in subviews {
            let converted = sub.convert(point, from: self)
            if sub.bounds.contains(converted) {
                return sub.hitTest(converted)
            }
        }
        return nil
    }

    // MARK: - Rendering

    private func render() {
        let store = AppStore.shared
        let model = store.activityModel(for: focusTagForRendering)
        line.stringValue = "  " + model.displayText(health: store.activityHealth)
        renderExpandedPanel(using: model)
    }

    private var focusTagForRendering: String {
        currentFocusTag ?? AppStore.unattributedActivityKey
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        renderExpandedPanel(using: AppStore.shared.activityModel(for: focusTagForRendering))
    }

    /// A taller panel with one row per agent (main + every subagent, running
    /// or finished) — deliberately not `PaneTree` tabs, since an activity
    /// stream isn't a view in the placement vocabulary and reusing the tab
    /// node would let ambient events reach the detail region.
    private func renderExpandedPanel(using model: ActivityStreamModel) {
        expandedPanel?.removeFromSuperview()
        expandedPanel = nil
        guard isExpanded else { return }

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 2
        panel.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bgBar.cgColor

        for (title, summary) in agentRows(for: model) {
            let rowLabel = NSTextField(labelWithString: "\(title): \(summary)")
            rowLabel.font = Theme.statusFont
            rowLabel.textColor = Theme.fg
            rowLabel.lineBreakMode = .byTruncatingTail
            panel.addArrangedSubview(rowLabel)
        }

        addSubview(panel)
        expandedPanel = panel
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            panel.bottomAnchor.constraint(equalTo: line.topAnchor),
        ])
    }

    private func agentRows(for model: ActivityStreamModel) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let main = model.mainStream, let last = main.events.last {
            rows.append((last.agent, last.summary))
        }
        for sub in model.subagentStreams {
            guard let last = sub.events.last else { continue }
            let title = (sub.agentType ?? "subagent") + (sub.finished ? " ✓" : " …")
            rows.append((title, last.summary))
        }
        if rows.isEmpty {
            rows.append(("—", "no activity yet"))
        }
        return rows
    }
}
