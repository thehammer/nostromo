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

    /// Height of the always-visible line. Not `private` — `MainLayout`
    /// reads this to reserve the ticker its own strip above the status bar
    /// (D1), rather than letting the ticker overlay draw over the bottom of
    /// the pace bars.
    static let lineHeight: CGFloat = 22

    // MARK: - Subviews

    /// Hairline separator marking the top edge of the ticker's own strip —
    /// distinguishes it from the pace bars now sitting directly above it
    /// (D1/D2): before D1, the two visually overlapped, and this separator
    /// would have looked like it was cutting through the pace bars.
    private let separator = NSView()
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

        // D2: fg (not fgMuted) so the line is actually legible against the
        // app background — fgMuted-on-bgBar-on-bg was low enough contrast
        // that a live QA pass hunting for this exact line, with a written
        // checklist, missed it four times.
        line.font = Theme.statusFont
        line.textColor = Theme.fg
        line.lineBreakMode = .byTruncatingTail
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.bgBar.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.borderInactive.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: Self.lineHeight),

            // Hairline marking the top edge of the ticker's own strip (D2).
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: line.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded))
        line.addGestureRecognizer(click)

        // Re-render on every focus switch (a different tag's stream), on
        // every activity ingest, and on every health update.
        //
        // D5/F4: keyed by the active focus's SESSION tag, not its agent tag
        // — Focus.agentTag == Focus.sessionTag for built-in focuses, which
        // is why this worked by coincidence before; a project-scoped focus's
        // sessionTag differs, and that's what the daemon actually stamps
        // every activity event's focus_tag with.
        AppStore.shared.$activeFocusSessionTag
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tag in
                self?.currentFocusTag = tag
                self?.render()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(AppStore.shared.$activityStreams, AppStore.shared.$activityHealth)
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
        // D2: a disclosure glyph so the click-to-expand behavior below is
        // actually discoverable, rather than a plain line that happens to
        // react to clicks with no visual hint that it does.
        let glyph = isExpanded ? "▾" : "▸"
        line.stringValue = "\(glyph)  " + model.displayText(health: store.activityHealth)
        renderExpandedPanel(using: model)
    }

    private var focusTagForRendering: String {
        currentFocusTag ?? AppStore.unattributedActivityKey
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        render()
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
