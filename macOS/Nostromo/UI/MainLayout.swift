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

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = Theme.bg.cgColor

        // Wire TabBarView callbacks
        tabBar.onSwitch      = { [weak self] focus in self?.switchFocus(focus) }
        tabBar.onAdd         = { [weak self] in self?.presentCreateFocusSheet() }
        tabBar.onRemove      = { [weak self] focus in self?.removeFocus(focus) }
        tabBar.onForceStart  = { [weak self] focus in self?.forceStart(focus) }

        // Subscribe to FocusStore so the tab bar rebuilds when focuses change
        FocusStore.shared.$focuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] focuses in
                guard let self else { return }
                self.tabBar.setFocuses(focuses)
                self.tabBar.activeFocus = self.activeFocus
            }
            .store(in: &cancellables)

        // Threshold events → toast banners.
        FileWatchers.shared.thresholdEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.toastView.showToast(event) }
            .store(in: &cancellables)

        // Publish the initial active focus so StatusBarView has a tag from the start.
        AppStore.shared.setActiveFocusAgentTag(activeFocus.agentTag)

        showContent(for: activeFocus)
    }

    // MARK: - Focus switching

    private func switchFocus(_ focus: Focus) {
        activeFocus          = focus
        tabBar.activeFocus   = focus
        UserDefaults.standard.set(focus.id, forKey: udKey)
        UserDefaults.standard.synchronize()
        AppStore.shared.setActiveFocusAgentTag(focus.agentTag)
        showContent(for: focus)
    }

    private func forceStart(_ focus: Focus) {
        AppStore.shared.session(
            for: focus.sessionTag,
            agentName: focus.agentTag,
            displayName: focus.displayName,
            workingDirectory: focus.projectPath
        ).restart()
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
        case "fred":   v = FredView()
        case "teri":   v = TeriView()
        default:
            // Dynamic focuses: full-screen REPL, no split pane.
            // sessionTag keys the session; agentTag is the --agent name.
            // Show Clear Context by default; respect any custom actions the focus defines in JSON.
            v = ReplView(tag: focus.sessionTag,
                         agentName: focus.agentTag,
                         displayName: focus.displayName,
                         workingDirectory: focus.projectPath,
                         quickActions: focus.quickActions.isEmpty
                             ? [QuickAction.clearContext]
                             : focus.quickActions)
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
            guard let self else { return }
            if let existing = FocusStore.shared.existing(
                projectPath: focus.projectPath, agentTag: focus.agentTag) {
                self.switchFocus(existing)
            } else {
                FocusStore.shared.add(focus)
                self.switchFocus(focus)
            }
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

// MARK: - TeriView

/// Teri agent view — todos panel (left, ~40%) + Teri REPL (right, ~60%), draggable vertical split.
///
/// The todos panel is an NSHostingView wrapping a small SwiftUI list that observes
/// AppStore.shared.teriTodos.  The REPL panel reuses the existing ReplView/PTY plumbing.
private class TeriView: NSView, NSSplitViewDelegate {

    private let split = DarkSplitView()
    private var didSetInitialPosition = false
    private var isReadyToSave        = false
    private static let udKey = "nostromo.teri.todosWidth"

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        split.isVertical   = true       // vertical divider (left | right)
        split.dividerStyle = .thin
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        // ── Left: todos panel ────────────────────────────────────────────────
        let todosPanel = NSHostingView(rootView: TeriTodosPanel())
        todosPanel.translatesAutoresizingMaskIntoConstraints = false

        // ── Right: REPL ──────────────────────────────────────────────────────
        let repl = ReplView(tag: "teri", agentName: "teri", displayName: "Teri",
                            quickActions: [QuickAction.clearContext])

        split.addSubview(todosPanel)
        split.addSubview(repl)
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSetInitialPosition, window != nil else { return }
        didSetInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.width > 0 else { return }
            let saved = UserDefaults.standard.double(forKey: Self.udKey)
            let pos   = saved > 10 ? saved : self.bounds.width * 0.4
            self.split.setPosition(pos, ofDividerAt: 0)
            self.isReadyToSave = true
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? max(pos, 200) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.width - 300) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let w = split.subviews.first?.frame.width, w > 10 else { return }
        UserDefaults.standard.set(w, forKey: Self.udKey)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - TeriTodosPanel (SwiftUI list inside NSHostingView)

/// SwiftUI todos list rendered inside the left pane of the macOS TeriView.
private struct TeriTodosPanel: View {
    @ObservedObject private var store = AppStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Text("Todos")
                    .font(.headline)
                Spacer()
                if store.teriTodos?.stale == true {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let err = store.teriTodos?.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Todos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(items) { todo in
                        NostromoKit.TeriTodoRow(model: rowModel(for: todo))
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Active todos sorted by priority ASC, then nulls-last on due_date, then due_date ASC.
    private var items: [TeriTodo] {
        guard let snap = store.teriTodos else { return [] }
        return snap.items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            switch (lhs.dueDate, rhs.dueDate) {
            case (nil, nil):       return false
            case (nil, _):         return false
            case (_, nil):         return true
            case (let l?, let r?): return l < r
            }
        }
    }

    private func rowModel(for todo: TeriTodo) -> TeriTodoRowModel {
        TeriTodoRowModel(
            id:          todo.id,
            title:       todo.title,
            priority:    todo.priority,
            jiraKey:     todo.jiraKey,
            relativeDue: relativeDue(for: todo.dueDate),
            rawDueDate:  todo.dueDate
        )
    }

    private func relativeDue(for dateStr: String?) -> String? {
        guard let dateStr else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone   = .gmt
        guard let date = fmt.date(from: dateStr) else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
