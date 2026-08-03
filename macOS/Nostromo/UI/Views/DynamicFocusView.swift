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
        // Snapshot existing leaf views before tearing anything down. A leaf
        // whose pane_id persists across this structural change — "repl" in
        // particular, whose content has nothing to do with tree shape — gets
        // re-parented into the new split hierarchy below instead of being
        // destroyed and recreated. Recreating ReplView on every structural
        // rebuild (every apply_layout/create_pane/reset_panes call) was
        // silently resetting scroll position and the pinned-to-bottom state
        // on a fresh instance each time, undoing the user's manual scroll.
        let previousLeafViews = leafViews

        // Remove existing content.
        subviews.forEach { $0.removeFromSuperview() }
        leafViews = [:]
        renderedTreePaneIds = model.tree.paneIds
        // Clear any previously saved operator-drag ratios so the agent's
        // layout intent takes effect on each structural rebuild. The operator
        // can drag to adjust after the agent assembles; those new ratios will
        // be persisted until the next structural change.
        clearSavedRatios(for: focus.sessionTag)

        let rootView = buildView(for: model.tree, tag: focus.sessionTag, path: "root", reusing: previousLeafViews)
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

    private func buildView(for tree: PaneTree, tag: String, path: String, reusing previous: [String: NSView]) -> NSView {
        switch tree {
        case .leaf(let paneId):
            return makeLeafView(paneId: paneId, reusing: previous[paneId])
        case .split(let direction, let children, let ratios):
            return makeSplitView(
                direction: direction,
                children: children,
                ratios: ratios,
                tag: tag,
                path: path,
                reusing: previous
            )
        }
    }

    private func makeLeafView(paneId: String, reusing existing: NSView?) -> NSView {
        if let existing {
            // Same pane_id as before this structural change — reuse the
            // instance verbatim (already detached from its old superview by
            // the caller) rather than tearing down and recreating it. For
            // ReplView this is what preserves scroll position and the
            // pinned-to-bottom flag across a layout rebuild; for
            // PaneContentNSView it just avoids a pointless flicker, since
            // updateContent() below re-pushes current content regardless.
            leafViews[paneId] = existing
            return existing
        }
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
            // Generic refresh affordance: nudge the owning focus's session.
            // The agent (Perri, Mother, Fred, Teri, ...) decides what
            // "refresh" means for its own pane content and re-pushes via
            // set_pane_content — no wire protocol changes needed.
            wrapper.onRefresh = { [weak self] in
                guard let self else { return }
                AppStore.shared.session(for: self.focus.sessionTag).send("refresh")
            }
            leafViews[paneId] = wrapper
            return wrapper
        }
    }

    private func makeSplitView(
        direction: SplitDirection,
        children: [PaneTree],
        ratios: [Double],
        tag: String,
        path: String,
        reusing previous: [String: NSView]
    ) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = (direction == .horizontal)
        split.dividerStyle = .thin

        for (i, child) in children.enumerated() {
            let childPath = "\(path).\(i)"
            let childView = buildView(for: child, tag: tag, path: childPath, reusing: previous)
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

    /// Remove all UserDefaults ratio keys for this focus so the next
    /// `applyRatios` call uses the agent's ratios rather than stale drag values.
    private func clearSavedRatios(for tag: String) {
        let prefix = "nostromo.dynlayout.\(tag)."
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

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
    /// Injected by `DynamicFocusView.makeLeafView` — called when the operator
    /// clicks the pane's refresh button.
    var onRefresh: () -> Void = {}

    /// Persistent AppKit chrome — lives above the SwiftUI content, which is
    /// torn down and rebuilt on every `update(content:)` call.
    private let refreshButton = NSButton()

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

        // Force dark appearance explicitly rather than relying on inheritance —
        // `hosting` below gets the same forced .darkAqua, and a mismatch here
        // (e.g. this button rendering under a light-appearance ancestor while
        // hosting forces dark) can leave the glyph an invisible color against
        // this view's manually-black layer.
        refreshButton.appearance      = NSAppearance(named: .darkAqua)
        refreshButton.isBordered       = false
        refreshButton.wantsLayer       = true
        // A faint background pill so the button has a visible presence even
        // if contentTintColor doesn't tint a plain-string title the way a
        // template image would — the corner should never be totally blank.
        refreshButton.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        refreshButton.layer?.cornerRadius     = 4
        let refreshAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ]
        refreshButton.attributedTitle  = NSAttributedString(string: "↺", attributes: refreshAttrs)
        refreshButton.toolTip          = "Ask the agent to refresh this pane"
        refreshButton.target           = self
        refreshButton.action           = #selector(didTapRefresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)
        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func didTapRefresh() { onRefresh() }

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
        // Explicitly reassert the button's z-order every time, rather than
        // trusting a single one-time `positioned:relativeTo:` insertion —
        // NSHostingView's own layer promotion timing has been unreliable
        // here, and this is cheap enough to just redo unconditionally.
        refreshButton.removeFromSuperview()
        addSubview(refreshButton)
    }
}
