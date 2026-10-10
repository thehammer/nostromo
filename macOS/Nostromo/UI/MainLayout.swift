import AppKit
import Combine
import NostromoKit
import SwiftUI

/// Root content view — vertical nav sidebar (left), content area (right of sidebar),
/// pace bars (just above status bar), status bar (bottom of content area).
///
/// Content area swaps between per-focus views as they're built.
class MainLayout: NSView {

    // MARK: - Chrome

    private let tabBar    = TabBarView()
    private let paceBars  = PaceBarsView()
    private let statusBar = StatusBarView()
    /// Toast overlay — renders above all content, passes through non-toast clicks.
    private let toastView = ToastBannerView()
    /// Ambient-activity ticker overlay — always visible, pinned to the bottom
    /// edge of the content area; passes through non-ticker clicks (D6).
    private let activityTicker = ActivityTickerView()

    // MARK: - Content

    private let contentContainer = NSView()
    private var currentContentView: NSView?
    private var viewCache: [String: NSView] = [:]  // keyed by focus.id

    // MARK: - Per-window focus state

    private let windowIndex: Int
    private var activeFocus: Focus
    private var udKey: String { "nostromo.window\(windowIndex).activeTab" }

    private var cancellables = Set<AnyCancellable>()
    private var presentedSheet: CreateFocusSheet?  // retained for sheet lifetime
    private var presentedRenameSheet: RenameFocusSheet?

    // MARK: - Init

    init(windowIndex: Int) {
        self.windowIndex = windowIndex
        // Restore active focus by ID from UserDefaults; fall back to mother
        let savedId = UserDefaults.standard.string(forKey: "nostromo.window\(windowIndex).activeTab")
        let allFocuses = FocusStore.shared.focuses
        self.activeFocus = allFocuses.first { $0.id == savedId } ?? allFocuses.first { $0.id == "mother" } ?? Focus.builtIns[1]
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Pin all chrome views explicitly
        for v in [tabBar, contentContainer, paceBars, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Sidebar — full height, left edge, fixed width
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabBar.widthAnchor.constraint(equalToConstant: Theme.sidebarWidth),

            // Status bar — bottom of right column
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),

            // Pace bars — above status bar, right column. Offset by the
            // ticker's own line height (not just statusBar.topAnchor) so the
            // always-visible activity ticker gets its own reserved strip
            // between pace bars and the status bar, instead of its 22pt line
            // drawing on top of the bottom of the pace bars (F1 / D1).
            paceBars.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -ActivityTickerView.lineHeight),
            paceBars.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            paceBars.trailingAnchor.constraint(equalTo: trailingAnchor),
            paceBars.heightAnchor.constraint(equalToConstant: Theme.paceBarsHeight),

            // Content — right column, top to pace bars
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: paceBars.topAnchor),
        ])

        // Toast overlay — covers content + pace bars, above all other subviews.
        // hitTest passthrough means clicks reach views below for non-toast areas.
        toastView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toastView)   // added last → draws on top
        NSLayoutConstraint.activate([
            toastView.topAnchor.constraint(equalTo: topAnchor),
            toastView.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            toastView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toastView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        // Ambient-activity ticker overlay — same content-area span as the
        // toast overlay (so it draws over content without shrinking it), and
        // added after it so it's always on top. hitTest passthrough means
        // clicks reach views below everywhere except the ticker's own line
        // (and its expanded panel when open).
        activityTicker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityTicker)   // added last → draws on top of the toast overlay too
        NSLayoutConstraint.activate([
            activityTicker.topAnchor.constraint(equalTo: topAnchor),
            activityTicker.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            activityTicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            activityTicker.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = Theme.bg.cgColor

        // Wire TabBarView callbacks
        tabBar.onSwitch      = { [weak self] focus in self?.switchFocus(focus) }
        tabBar.onAdd         = { [weak self] in self?.presentCreateFocusSheet() }
        tabBar.onRename      = { [weak self] focus in self?.presentRenameSheet(for: focus) }
        tabBar.onRemove      = { [weak self] focus in self?.removeFocus(focus) }
        tabBar.onForceStart  = { [weak self] focus in self?.forceStart(focus) }

        // Subscribe to FocusStore so the tab bar rebuilds when focuses change.
        //
        // FocusStore is the one app-wide truth on which focuses exist; every
        // window's sink reacts uniformly to a removal here — not just the
        // window whose tab bar was clicked (`removeFocus` below no longer
        // does either of these itself). Before this, a focus closed from
        // Window A left its content and its `viewCache` entry alive forever
        // in Window B: the tab disappeared from B's tab bar (rebuilt below)
        // while B's content view, if it was showing that focus, stayed on
        // screen — and B's cached `NSView` kept its `ChatSession` reachable
        // no matter what `AppStore.evictPerFocusState` did.
        FocusStore.shared.$focuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focuses in
                guard let self else { return }
                self.tabBar.setFocuses(focuses)
                self.tabBar.activeFocus = self.activeFocus
                // This window's active focus was removed — fall back to
                // Mother, exactly like a click-to-close used to for the one
                // window that initiated it.
                if !focuses.contains(where: { $0.id == self.activeFocus.id }) {
                    let mother = focuses.first { $0.id == "mother" } ?? Focus.builtIns[1]
                    self.switchFocus(mother)
                }
                // Evict this window's cached view for any focus that's gone —
                // the other half of what makes eviction in AppStore actually
                // free memory rather than just unlink a dictionary entry.
                let liveIds = Set(focuses.map { $0.id })
                self.viewCache = self.viewCache.filter { liveIds.contains($0.key) }
            }
            .store(in: &cancellables)

        // A focus this client asked the daemon to create (`select_for_client`)
        // is selected in the key window only, never in every window.
        AppStore.shared.focusSelectionRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focus in
                guard let self, self.window?.isKeyWindow == true else { return }
                self.switchFocus(focus)
            }
            .store(in: &cancellables)

        // Threshold events → toast banners.
        FileWatchers.shared.thresholdEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.toastView.showToast(event) }
            .store(in: &cancellables)

        // Memory warnings and shed notices → the same banner surface.
        AppStore.shared.onMemoryToast = { [weak self] message, severity in
            self?.toastView.showToast(message: message, severity: severity)
        }

        // Daemon-originated notifications (W5 — current-pr-collision) → the
        // same banner surface. No production trigger sends one yet.
        AppStore.shared.onNotification = { [weak self] message, severity in
            self?.toastView.showToast(message: message, severity: severity)
        }

        // Publish the initial active focus so StatusBarView has a tag from the start.
        AppStore.shared.setActiveFocusAgentTag(activeFocus.agentTag)
        AppStore.shared.setActiveFocusSessionTag(activeFocus.sessionTag)

        showContent(for: activeFocus)
    }

    // MARK: - Focus switching

    private func switchFocus(_ focus: Focus) {
        activeFocus          = focus
        tabBar.activeFocus   = focus
        UserDefaults.standard.set(focus.id, forKey: udKey)
        UserDefaults.standard.synchronize()
        AppStore.shared.setActiveFocusAgentTag(focus.agentTag)
        AppStore.shared.setActiveFocusSessionTag(focus.sessionTag)
        showContent(for: focus)
    }

    /// The `sessionTag` of the focus this window is showing right now. Read-only:
    /// `DecisionPresenter` targets popups by it but never changes it.
    var activeFocusTag: String { activeFocus.sessionTag }

    private func forceStart(_ focus: Focus) {
        AppStore.shared.session(
            for: focus.sessionTag,
            agentName: focus.agentTag,
            displayName: focus.displayName,
            workingDirectory: focus.projectPath
        ).restart()
    }

    private func removeFocus(_ focus: Focus) {
        // The switch-away and the viewCache prune used to happen right here,
        // for this window only. They've moved into the `$focuses` sink above
        // so every window reacts uniformly — this window included, since it
        // also observes `$focuses` — rather than only the one whose tab bar
        // was clicked. `FocusStore.remove` is the one thing that has to
        // happen here: everything else follows from its `focusRemovals`/
        // `$focuses` announcements.
        FocusStore.shared.remove(focus)
    }

    // MARK: - Content switching

    private func makeView(for focus: Focus) -> NSView {
        if let cached = viewCache[focus.id] { return cached }
        // Every focus is now a DynamicFocusView: the daemon's pane tree drives
        // the layout, starting as a single REPL pane and growing as the agent
        // calls create_pane on its first turn.
        //
        // Mother, Teri and Fred get a daemon-seeded native pane (`mother_queue`,
        // `teri_surface`, `fred_hud`) that DynamicFocusView.makeLeafView maps to
        // the native view, so their surface shows with no agent turn. The old
        // dedicated TeriView is gone; FredView/MotherView/PerriView remain in
        // the project, unused, until their follow-up removals.
        let v = DynamicFocusView(focus: focus, windowId: String(windowIndex))
        viewCache[focus.id] = v
        return v
    }

    private func showContent(for focus: Focus) {
        currentContentView?.removeFromSuperview()
        let view = makeView(for: focus)
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentContentView = view
    }

    // MARK: - Sheet presentation

    private func presentRenameSheet(for focus: Focus) {
        guard let window else { return }
        let sheet = RenameFocusSheet(currentLabel: focus.label) { label in
            if FocusStore.shared.rename(id: focus.id, label: label),
               let renamed = FocusStore.shared.focuses.first(where: { $0.id == focus.id }) {
                AppStore.shared.updateSessionLabel(tag: renamed.sessionTag, displayName: renamed.displayName)
            }
        }
        presentedRenameSheet = sheet  // retain for the sheet's lifetime
        window.beginSheet(sheet.window!) { [weak self] _ in
            self?.presentedRenameSheet = nil
        }
    }

    private func presentCreateFocusSheet() {
        guard let window else { return }
        let sheet = CreateFocusSheet { [weak self] focus in
            guard let self else { return }
            FocusCreation.commit(focus, store: FocusStore.shared) { self.switchFocus($0) }
            self.presentedSheet = nil
        }
        presentedSheet = sheet  // retain for the sheet's lifetime
        window.beginSheet(sheet.window!) { [weak self] _ in
            self?.presentedSheet = nil
        }
    }
}

// MARK: - AgentView

/// Generic agent view — placeholder HUD (top) + REPL (bottom), draggable split.
/// Used for Fred, Teri, and all dynamic focuses until their HUDs are built.
private class AgentView: NSView, NSSplitViewDelegate {

    private let split    = DarkSplitView()
    private let agentTag: String
    private let agentName: String
    private var didSetInitialPosition = false
    private var isReadyToSave        = false

    init(tag: String, label: String, agentName: String? = nil, workingDirectory: String? = nil,
         quickActions: [QuickAction] = []) {
        self.agentTag  = tag
        self.agentName = agentName ?? tag
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Placeholder HUD
        let hud = NSView()
        hud.wantsLayer = true
        hud.layer?.backgroundColor = Theme.bg.cgColor
        let hintLabel = NSTextField(labelWithString: label)
        hintLabel.font      = NSFont.systemFont(ofSize: 18, weight: .thin)
        hintLabel.textColor = Theme.borderInactive
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: hud.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: hud.centerYAnchor),
        ])

        let repl = ReplView(tag: agentTag, agentName: agentName, displayName: label,
                            workingDirectory: workingDirectory, quickActions: quickActions)

        split.isVertical   = false     // horizontal divider (top / bottom)
        split.dividerStyle = .thin
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addSubview(hud)
        split.addSubview(repl)
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var udKey: String { "nostromo.agent.\(agentTag).hudHeight" }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSetInitialPosition, window != nil else { return }
        didSetInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.height > 0 else { return }
            let saved = UserDefaults.standard.double(forKey: self.udKey)
            let pos   = saved > 10 ? saved : self.bounds.height * 0.55
            self.split.setPosition(pos, ofDividerAt: 0)
            self.isReadyToSave = true
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? max(pos, 120) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.height - 150) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let h = split.subviews.first?.frame.height, h > 10 else { return }
        UserDefaults.standard.set(h, forKey: udKey)
        UserDefaults.standard.synchronize()
    }
}
