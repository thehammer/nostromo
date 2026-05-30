import AppKit
import Combine

/// Root content view — vertical nav sidebar (left), content area (right of sidebar),
/// pace bars (just above status bar), status bar (bottom of content area).
///
/// Content area swaps between per-focus views as they're built.
class MainLayout: NSView {

    // MARK: - Chrome

    private let tabBar    = TabBarView()
    private let paceBars  = PaceBarsView()
    private let statusBar = StatusBarView()

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

            // Pace bars — above status bar, right column
            paceBars.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            paceBars.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            paceBars.trailingAnchor.constraint(equalTo: trailingAnchor),
            paceBars.heightAnchor.constraint(equalToConstant: Theme.paceBarsHeight),

            // Content — right column, top to pace bars
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: paceBars.topAnchor),
        ])

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = Theme.bg.cgColor

        // Wire TabBarView callbacks
        tabBar.onSwitch = { [weak self] focus in self?.switchFocus(focus) }
        tabBar.onAdd    = { [weak self] in self?.presentCreateFocusSheet() }
        tabBar.onRemove = { [weak self] focus in self?.removeFocus(focus) }

        // Subscribe to FocusStore so the tab bar rebuilds when focuses change
        FocusStore.shared.$focuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focuses in
                guard let self else { return }
                self.tabBar.setFocuses(focuses)
                self.tabBar.activeFocus = self.activeFocus
            }
            .store(in: &cancellables)

        showContent(for: activeFocus)
    }

    // MARK: - Focus switching

    private func switchFocus(_ focus: Focus) {
        activeFocus          = focus
        tabBar.activeFocus   = focus
        UserDefaults.standard.set(focus.id, forKey: udKey)
        UserDefaults.standard.synchronize()
        showContent(for: focus)
    }

    private func removeFocus(_ focus: Focus) {
        FocusStore.shared.remove(focus)
        // If the removed focus was active, fall back to Mother
        if activeFocus.id == focus.id {
            let mother = FocusStore.shared.focuses.first { $0.id == "mother" } ?? Focus.builtIns[1]
            switchFocus(mother)
        }
        // Evict from cache so it doesn't leak memory
        viewCache.removeValue(forKey: focus.id)
    }

    // MARK: - Content switching

    private func makeView(for focus: Focus) -> NSView {
        if let cached = viewCache[focus.id] { return cached }
        let v: NSView
        switch focus.id {
        case "mother": v = MotherView()
        case "perri":  v = PerriView()
        case "fred":   v = AgentView(tag: "fred",  label: "Fred")
        case "teri":   v = AgentView(tag: "teri",  label: "Teri")
        default:
            // Dynamic focuses: full-screen REPL, no split pane.
            // sessionTag keys the session; agentTag is the --agent name.
            v = ReplView(tag: focus.sessionTag,
                         agentName: focus.agentTag,
                         workingDirectory: focus.projectPath)
        }
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

    private func presentCreateFocusSheet() {
        guard let window else { return }
        let sheet = CreateFocusSheet { [weak self] focus in
            FocusStore.shared.add(focus)
            self?.switchFocus(focus)
            self?.presentedSheet = nil
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

    init(tag: String, label: String, agentName: String? = nil, workingDirectory: String? = nil) {
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

        let repl = ReplView(tag: agentTag, agentName: agentName, workingDirectory: workingDirectory)

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
