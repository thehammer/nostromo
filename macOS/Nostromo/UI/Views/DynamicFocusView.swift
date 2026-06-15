import AppKit
import Combine
import SwiftUI

/// Renders a focus's agent-authored pane tree as nested NSSplitViews.
///
/// The tree shape comes from `AppStore.focusLayouts[focus.tag]` and is rebuilt
/// whenever the daemon broadcasts a structural `FocusLayout` message. Content
/// updates (`PaneContent`) refresh individual leaf views without touching split
/// geometry — this is what lets an operator's manual drag-resize survive content
/// refreshes.
///
/// Split ratios are persisted in `UserDefaults` keyed by focus tag + tree path
/// so the workspace looks the same after switching tabs or restarting the app.
/// Only a structural `FocusLayout` broadcast (create_pane / reset_panes /
/// set_pane_layout) overrides the saved ratios.
final class DynamicFocusView: NSView {

    // MARK: - Init

    private let focus: Focus
    private var cancellables = Set<AnyCancellable>()

    /// Leaf views keyed by pane_id (ReplView or PaneContentNSView wrappers).
    private var leafViews: [String: NSView] = [:]

    /// The tree that's currently rendered (used to detect structural changes).
    private var renderedTreePaneIds: [String] = []

    init(focus: Focus) {
        self.focus = focus
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = .clear

        // Render whatever layout the store already has.
        let initial = AppStore.shared.focusLayouts[focus.sessionTag] ?? FocusLayoutModel.initial
        renderLayout(initial)

        // Subscribe to layout changes.
        AppStore.shared.$focusLayouts
            .receive(on: DispatchQueue.main)
            .map { $0[self.focus.sessionTag] }
            .sink { [weak self] layout in
                guard let self else { return }
                let model = layout ?? FocusLayoutModel.initial
                self.handleLayoutUpdate(model)
            }
            .store(in: &cancellables)
    }

    // MARK: - Layout update handling

    private func handleLayoutUpdate(_ model: FocusLayoutModel) {
        let newIds = model.tree.paneIds
        if newIds != renderedTreePaneIds {
            // Structural change — rebuild the whole split view.
            renderLayout(model)
        } else {
            // Content-only change — update leaf views in place.
            updateContent(model.paneContent)
        }
    }

    private func renderLayout(_ model: FocusLayoutModel) {
        // Remove existing content.
        subviews.forEach { $0.removeFromSuperview() }
        leafViews = [:]
        renderedTreePaneIds = model.tree.paneIds

        let rootView = buildView(for: model.tree, tag: focus.sessionTag, path: "root")
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Apply any initial content.
        updateContent(model.paneContent)
    }

    // MARK: - Tree rendering

    private func buildView(for tree: PaneTree, tag: String, path: String) -> NSView {
        switch tree {
        case .leaf(let paneId):
            return makeLeafView(paneId: paneId)
        case .split(let direction, let children, let ratios):
            return makeSplitView(
                direction: direction,
                children: children,
                ratios: ratios,
                tag: tag,
                path: path
            )
        }
    }

    private func makeLeafView(paneId: String) -> NSView {
        if paneId == "repl" {
            let repl = ReplView(
                tag:              focus.sessionTag,
                agentName:        focus.agentTag,
                displayName:      focus.displayName,
                workingDirectory: focus.projectPath,
                quickActions:     focus.quickActions.isEmpty
                                      ? [QuickAction.clearContext]
                                      : focus.quickActions
            )
            leafViews[paneId] = repl
            return repl
        } else {
            let wrapper = PaneContentNSView()
            // Wire pr_list row actions through AppStore so the existing
            // PerriState load path fires (D2: reuse existing PerriAction path).
            wrapper.onLoadPR    = { repo, number in AppStore.shared.loadPR(repo: repo, number: number) }
            // macOS approve: no native approve path exists in Phase 1 (the
            // legacy macOS PerriView had no swipe-approve). The context menu item
            // is wired to a no-op; full macOS approve is Phase 2 work.
            wrapper.onApprovePR = { _, _ in }
            leafViews[paneId] = wrapper
            return wrapper
        }
    }

    private func makeSplitView(
        direction: SplitDirection,
        children: [PaneTree],
        ratios: [Double],
        tag: String,
        path: String
    ) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = (direction == .horizontal)
        split.dividerStyle = .thin

        for (i, child) in children.enumerated() {
            let childPath = "\(path).\(i)"
            let childView = buildView(for: child, tag: tag, path: childPath)
            split.addArrangedSubview(childView)
        }

        // Restore saved ratios (from a previous session or operator drag) or
        // apply the agent-supplied defaults, then keep ratios in sync on drag.
        let udKey = "nostromo.dynlayout.\(tag).\(path)"
        split.translatesAutoresizingMaskIntoConstraints = false

        // Post-layout ratio application — deferred so the split has a real size.
        let savedRatios = UserDefaults.standard.array(forKey: udKey) as? [Double]
        let effectiveRatios = savedRatios ?? ratios
        DispatchQueue.main.async {
            self.applyRatios(effectiveRatios, to: split)
        }

        // Persist the operator's drag-resize.
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split,
            queue: .main
        ) { _ in
            let newRatios = DynamicFocusView.currentRatios(for: split)
            UserDefaults.standard.set(newRatios, forKey: udKey)
        }

        return split
    }

    // MARK: - Ratio helpers

    private func applyRatios(_ ratios: [Double], to split: NSSplitView) {
        let subviews = split.subviews
        guard ratios.count == subviews.count, !subviews.isEmpty else { return }
        let totalSize = split.isVertical
            ? split.bounds.width
            : split.bounds.height
        guard totalSize > 0 else { return }

        // Distribute sizes proportionally, leaving divider thickness accounted for.
        // NSSplitView has (subviews.count - 1) dividers, indexed 0..<(count-1).
        // Divider i sits between subviews[i] and subviews[i+1].
        // The last subview has no trailing divider — skip setPosition for it.
        let dividerTotal = split.dividerThickness * Double(subviews.count - 1)
        let usable = totalSize - dividerTotal
        var offset: CGFloat = 0
        for (i, _) in subviews.enumerated() {
            let size = usable * ratios[i]
            if i < subviews.count - 1 {
                split.setPosition(offset + size, ofDividerAt: i)
            }
            offset += size + split.dividerThickness
        }
        split.adjustSubviews()
    }

    private static func currentRatios(for split: NSSplitView) -> [Double] {
        let subviews = split.subviews
        let totalSize = split.isVertical
            ? split.bounds.width
            : split.bounds.height
        guard totalSize > 0 else { return Array(repeating: 1.0 / Double(subviews.count), count: subviews.count) }
        return subviews.map { sv in
            let size = split.isVertical ? sv.frame.width : sv.frame.height
            return Double(size / totalSize)
        }
    }

    // MARK: - Content update

    private func updateContent(_ paneContent: [String: PaneContentWire]) {
        for (paneId, content) in paneContent {
            guard let leafView = leafViews[paneId] as? PaneContentNSView else { continue }
            leafView.update(content: content)
        }
    }
}

// MARK: - PaneContentNSView

/// An NSView wrapper around the SwiftUI PaneContentView, used for non-repl panes.
final class PaneContentNSView: NSView {

    private var hostingView: NSHostingView<PaneContentView>?
    private var currentContent: PaneContentWire?

    /// Injected by `DynamicFocusView.makeLeafView` — called when a `pr_list` row is loaded.
    var onLoadPR:    (String, Int) -> Void = { _, _ in }
    /// Injected by `DynamicFocusView.makeLeafView` — called when a `pr_list` row is approved.
    var onApprovePR: (String, Int) -> Void = { _, _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Start with an empty state.
        let hosting = NSHostingView(rootView: PaneContentView(content: nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = hosting
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(content: PaneContentWire) {
        // Replace rather than mutate rootView — setting rootView on an existing
        // NSHostingView inside a split view doesn't reliably trigger a SwiftUI
        // layout pass. Creating a fresh NSHostingView guarantees the content renders.
        hostingView?.removeFromSuperview()
        var view = PaneContentView(content: content)
        view.onLoadPR    = onLoadPR
        view.onApprovePR = onApprovePR
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.appearance = NSAppearance(named: .darkAqua)
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = hosting
    }
}
