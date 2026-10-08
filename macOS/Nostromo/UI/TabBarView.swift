import AppKit
import Combine

/// Vertical navigation sidebar — Org → Repo → Agent hierarchy, scrollable.
///
/// Built-in and dynamic focuses are grouped by org ("Carefeed" / "Personal"),
/// then by repo within each org, then by agent within each repo.  The grouped
/// layout lives inside an NSScrollView so the list can grow beyond the window
/// height without clipping or pushing the "+" button off-screen.
///
/// Active focus: 3px cornflower left-accent + subtle bg highlight + bold label.
/// Sweater indicator: small colored dot to the right of the Mother label.
/// Right border separates sidebar from content area.
class TabBarView: NSView {

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var items: [String: NavTabItem] = [:]   // keyed by focus.id

    /// The focuses last passed to `setFocuses` — remembered so a
    /// `perriDetailByTag` change (a PR loading/clearing in some focus) can
    /// rebuild the same rows with fresh labels, without waiting for
    /// `FocusStore` to also publish. Deliberately NOT sourced from the
    /// single per-window "which focus is active" global `AppStore` exposes
    /// elsewhere (see `MainLayout.swift`'s `setActiveFocusAgentTag` calls) —
    /// this is a plain, per-window-agnostic list rebuild keyed by
    /// `AppStore.shared.perriDetailByTag`, which is app-wide and therefore
    /// reads identically in every window by construction.
    private var currentFocuses: [Focus] = []

    /// The rows last built, so an attention change can re-flag them without a rebuild.
    private var currentRows: [NavRow] = []

    /// Set by MainLayout when the active focus changes. Drives highlight state.
    var activeFocus: Focus? {
        didSet {
            updateStates()
            // Switching focus is a cheap moment to re-check that checkout's branch.
            if activeFocus?.projectPath != nil {
                BranchProvider.shared.refresh(FocusStore.shared.focuses.compactMap { $0.projectPath })
            }
        }
    }

    /// Called when the user taps a focus item.
    var onSwitch: ((Focus) -> Void)?

    /// Called when the user taps the "+" button.
    var onAdd: (() -> Void)?

    /// Called when the user selects "Remove Focus" from a dynamic item's context menu.
    var onRemove: ((Focus) -> Void)?

    /// Called when the user selects "Rename…" from a dynamic item's context menu.
    var onRename: ((Focus) -> Void)?

    /// Called when the user selects "Force Start" from a dynamic item's context menu.
    var onForceStart: ((Focus) -> Void)?

    // Layout sub-views managed across reloads
    private var addButton: NSView?
    private var documentView: FlippedView!

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

        // Right border — 1px, full height, always on top
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.widthAnchor.constraint(equalToConstant: 1),
        ])

        // Add-focus button pinned to bottom (set up first so scrollView can pin to it)
        let btn = makeAddButton()
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            btn.bottomAnchor.constraint(equalTo: bottomAnchor),
            btn.heightAnchor.constraint(equalToConstant: 32),
        ])
        addButton = btn

        // Scroll view — occupies the space between the top edge and the "+" button
        let sv = NSScrollView()
        sv.drawsBackground    = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers  = true
        sv.verticalScrollElasticity   = .allowed
        sv.hasHorizontalScroller      = false
        sv.horizontalScrollElasticity = .none
        sv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            sv.bottomAnchor.constraint(equalTo: btn.topAnchor),
        ])

        // Document view — flipped so the top-anchor chain runs top-to-bottom
        let dv = FlippedView()
        dv.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = dv
        // Width tracks the scroll view's content area; height driven by item chain.
        dv.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor).isActive = true
        documentView = dv

        // Mother sweater dots — global state, same on all windows
        AppStore.shared.$motherJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSweaters() }
            .store(in: &cancellables)

        // Session health badges — update dots when any session's health changes
        AppStore.shared.$sessionHealth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSweaters() }
            .store(in: &cancellables)

        // Live git branch per checkout (second line of a row). Published only on
        // change, so this rebuilds the rows only when a branch actually moved.
        // `dropFirst`: `setFocuses` renders the current branches itself.
        BranchProvider.shared.$branches
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setFocuses(self.currentFocuses)
            }
            .store(in: &cancellables)
        BranchProvider.shared.startPolling {
            FocusStore.shared.focuses.compactMap { $0.projectPath }
        }

        // Focuses with an outstanding request for the operator (a pending
        // decision, today). Flags rows in place: no rebuild, no height change.
        AppStore.shared.$attentionTags
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAttention() }
            .store(in: &cancellables)

        // Per-focus PR under review (W8) — rebuild the rows with fresh
        // labels whenever any focus's pin loads or clears. `perriDetailByTag`
        // is app-wide (not per-window), so every window's sidebar reacts to
        // the same change and shows the same label — see `currentFocuses`'s
        // doc comment for why this deliberately does not route through the
        // single per-window active-focus global instead.
        AppStore.shared.$perriDetailByTag
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setFocuses(self.currentFocuses)
            }
            .store(in: &cancellables)
    }

    // MARK: - Focus list management

    /// Tears down and rebuilds the grouped item list from a new focuses array.
    func setFocuses(_ focuses: [Focus]) {
        // A new/removed checkout needs its branch looked up now, not at the next tick.
        let paths = Set(focuses.compactMap { $0.projectPath })
        if paths != Set(currentFocuses.compactMap { $0.projectPath }) {
            BranchProvider.shared.refresh(Array(paths))
        }
        currentFocuses = focuses

        // Clear previous content
        documentView.subviews.forEach { $0.removeFromSuperview() }
        items = [:]

        let perriDetailByTag = AppStore.shared.perriDetailByTag
        let branches = BranchProvider.shared.branches
        let rows = buildNavRows(
            focuses,
            prFor: { tag in
                let detail = perriDetailByTag[tag]
                return (detail?.repo, detail?.prNumber)
            },
            branchFor: { $0.projectPath.flatMap { branches[$0] } }
        )
        currentRows = rows
        var prev: NSView? = nil
        var isFirstOrg = true

        for row in rows {
            let view: NSView

            switch row {
            case .orgHeader(let title):
                view = OrgHeaderView(title: title, showTopSeparator: !isFirstOrg)
                isFirstOrg = false

            case .repoHeader(let name):
                view = RepoGroupView(name: name)

            case .focus(let focus, let label, let secondary, let indented):
                let item = NavTabItem(focus: focus, label: label, secondary: secondary, indented: indented)
                item.onTap = { [weak self] in self?.onSwitch?(focus) }

                if !focus.isBuiltIn {
                    let menu = NSMenu()

                    let renameItem = NSMenuItem(
                        title: "Rename…",
                        action: #selector(renameTapped(_:)),
                        keyEquivalent: ""
                    )
                    renameItem.target = self
                    renameItem.representedObject = focus
                    menu.addItem(renameItem)

                    let forceStartItem = NSMenuItem(
                        title: "Force Start",
                        action: #selector(forceStartTapped(_:)),
                        keyEquivalent: ""
                    )
                    forceStartItem.target = self
                    forceStartItem.representedObject = focus
                    menu.addItem(forceStartItem)

                    let removeItem = NSMenuItem(
                        title: "Remove Focus",
                        action: #selector(removeFocusTapped(_:)),
                        keyEquivalent: ""
                    )
                    removeItem.target = self
                    removeItem.representedObject = focus
                    menu.addItem(removeItem)

                    item.menu = menu
                }

                items[focus.id] = item
                view = item
            }

            view.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(view)

            // Height for this row type
            let height: CGFloat
            switch row {
            case .orgHeader:  height = Theme.navOrgHeaderHeight
            case .repoHeader: height = Theme.navRepoHeaderHeight
            case .focus(_, _, let secondary, _):
                height = secondary != nil ? Theme.navItemSubtitleHeight : Theme.navItemHeight
            }

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                view.heightAnchor.constraint(equalToConstant: height),
            ])

            if let p = prev {
                view.topAnchor.constraint(equalTo: p.bottomAnchor).isActive = true
            } else {
                view.topAnchor.constraint(equalTo: documentView.topAnchor).isActive = true
            }
            prev = view
        }

        // Pin last row's bottom to documentView so the scroll view knows the content height
        if let last = prev {
            last.bottomAnchor.constraint(equalTo: documentView.bottomAnchor).isActive = true
        }

        updateStates()
        updateSweaters()
        updateAttention()
    }

    @objc private func renameTapped(_ sender: NSMenuItem) {
        guard let focus = sender.representedObject as? Focus else { return }
        onRename?(focus)
    }

    @objc private func forceStartTapped(_ sender: NSMenuItem) {
        guard let focus = sender.representedObject as? Focus else { return }
        onForceStart?(focus)
    }

    @objc private func removeFocusTapped(_ sender: NSMenuItem) {
        guard let focus = sender.representedObject as? Focus else { return }
        onRemove?(focus)
    }

    // MARK: - Add button

    private func makeAddButton() -> NSView {
        let btn = NSView()
        btn.wantsLayer = true
        btn.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "+")
        label.font      = NSFont.systemFont(ofSize: 18, weight: .thin)
        label.textColor = Theme.fgMuted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(addTapped))
        btn.addGestureRecognizer(click)

        return btn
    }

    @objc private func addTapped() { onAdd?() }

    // MARK: - State updates

    private func updateAttention() {
        let tags = AppStore.shared.attentionTags
        for row in currentRows {
            guard case .focus(let focus, _, _, _) = row else { continue }
            items[focus.id]?.needsAttention = row.needsAttention(in: tags)
        }
    }

    private func updateStates() {
        items.forEach { id, item in item.isActive = (id == activeFocus?.id) }
    }

    private func updateSweaters() {
        let jobs   = AppStore.shared.motherJobs
        let health = AppStore.shared.sessionHealth

        let threshold: TimeInterval = 15 * 60
        let now = Date()
        let anyLong = jobs.contains {
            $0.state == "running" && $0.startedAt.map { now.timeIntervalSince($0) > threshold } == true
        }

        for (focusId, item) in items {
            // Resolve the agent tag for this focus so we can look up health.
            let agentTag = FocusStore.shared.focuses.first { $0.id == focusId }?.agentTag
            let sessionH = agentTag.flatMap { health[$0] }

            // Health takes precedence over Mother sweater.
            switch sessionH {
            case .permanentlyDown:
                item.sweaterColor = Theme.redSweater
            case .recovering:
                item.sweaterColor = Theme.amber
            case .healthy, .none:
                // Fall back to Mother sweater for the Mother focus.
                if focusId == "mother" {
                    item.sweaterColor = anyLong ? Theme.amber : nil
                } else {
                    item.sweaterColor = nil
                }
            }
        }
    }
}

// MARK: - FlippedView

/// NSView subclass with a flipped coordinate system so Auto Layout top-anchor chains
/// read naturally top-to-bottom inside an NSScrollView's document view.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - OrgHeaderView

/// Non-interactive org-section header (e.g. "CAREFEED").
///
/// Shows an optional 1px top separator — used for all org sections except the first.
private class OrgHeaderView: NSView {

    init(title: String, showTopSeparator: Bool) {
        super.init(frame: .zero)
        wantsLayer = true

        if showTopSeparator {
            let sep = NSView()
            sep.wantsLayer = true
            sep.layer?.backgroundColor = Theme.borderInactive.cgColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sep)
            NSLayoutConstraint.activate([
                sep.topAnchor.constraint(equalTo: topAnchor),
                sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                sep.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        let label = NSTextField(labelWithString: title)
        label.font          = Theme.navOrgFont
        label.textColor     = Theme.fgMuted
        label.alignment     = .left
        label.isEditable    = false
        label.isBordered    = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - RepoGroupView

/// Non-interactive repo-group header shown when a repo has ≥2 agent sessions.
private class RepoGroupView: NSView {

    init(name: String) {
        super.init(frame: .zero)
        wantsLayer = true

        let label = NSTextField(labelWithString: name)
        label.font          = Theme.navRepoFont
        label.textColor     = Theme.fgMuted
        label.alignment     = .left
        label.isEditable    = false
        label.isBordered    = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + Theme.navChildIndent),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - NavTabItem

private class NavTabItem: NSView {

    let focus: Focus
    var onTap: (() -> Void)?

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    /// An outstanding request (e.g. a pending decision) is waiting on this focus.
    var needsAttention: Bool = false {
        didSet { attentionDot.isHidden = !needsAttention }
    }

    var sweaterColor: NSColor? = nil {
        didSet { updateAppearance() }
    }

    private let accentBar      = NSView()
    private let label          = NSTextField(labelWithString: "")
    private let dot            = NSView()
    private let attentionDot   = NSView()
    private let displayOverride: String
    private let secondaryLabel: NSTextField?

    init(focus: Focus, label displayLabel: String, secondary: String?, indented: Bool) {
        self.focus           = focus
        self.displayOverride = displayLabel
        self.secondaryLabel  = secondary.map { text in
            let tf = NSTextField(labelWithString: text)
            tf.font           = Theme.navSubFont
            tf.textColor      = Theme.fgMuted
            tf.alignment      = .left
            tf.lineBreakMode  = .byTruncatingTail
            tf.maximumNumberOfLines = 1
            tf.translatesAutoresizingMaskIntoConstraints = false
            return tf
        }
        super.init(frame: .zero)
        wantsLayer = true

        let leadingInset: CGFloat = indented ? 6 + Theme.navChildIndent : 6

        // Left accent bar — 3px, full height
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Theme.cornflower.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
        ])

        // Primary label — left-aligned
        label.stringValue    = displayLabel
        label.font           = Theme.tabFont
        label.textColor      = Theme.fgMuted
        label.alignment      = .left
        label.lineBreakMode  = .byTruncatingTail
        label.isEditable     = false
        label.isBordered     = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Sweater dot — 6px circle, right-aligned, hidden by default
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Attention dot — 8px, in the same trailing column as the sweater dot but
        // on the label's line, so it never shares a position with it. An overlay:
        // it takes no space in the label constraints, so showing or hiding it can
        // never move text or change the row's height.
        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = 4
        attentionDot.layer?.backgroundColor = Theme.attention.cgColor
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.setAccessibilityElement(true)
        attentionDot.setAccessibilityRole(.image)
        attentionDot.setAccessibilityLabel("needs your attention")
        addSubview(attentionDot)
        NSLayoutConstraint.activate([
            attentionDot.widthAnchor.constraint(equalToConstant: 8),
            attentionDot.heightAnchor.constraint(equalToConstant: 8),
            attentionDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            attentionDot.centerYAnchor.constraint(equalTo: topAnchor, constant: 13),
        ])

        // Label constraints — different depending on whether secondary is shown
        if let sl = secondaryLabel {
            addSubview(sl)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                label.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),

                sl.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                sl.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                sl.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    private func updateAppearance() {
        accentBar.isHidden = !isActive
        layer?.backgroundColor = isActive
            ? Theme.cornflower.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor

        if isActive {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFontBold, .foregroundColor: NSColor.white,
            ]
            label.attributedStringValue = NSAttributedString(string: displayOverride, attributes: attrs)
        } else {
            let color = sweaterColor ?? Theme.fgMuted
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFont, .foregroundColor: color,
            ]
            label.attributedStringValue = NSAttributedString(string: displayOverride, attributes: attrs)
        }

        if let sc = sweaterColor {
            dot.isHidden = false
            dot.layer?.backgroundColor = sc.cgColor
        } else {
            dot.isHidden = true
        }
    }
}
