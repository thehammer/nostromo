import AppKit
import Combine
import SwiftUI

/// Renders a focus's agent-authored pane tree as nested NSSplitViews (plus, as
/// of W1 — curated-agent-views, `TabRegionView` for any `PaneTree.tabs` node).
///
/// The tree shape comes from `AppStore.focusLayouts[focus.tag]` and is rebuilt
/// whenever the daemon broadcasts a structural `FocusLayout` message. Content
/// updates (`PaneContent`) refresh individual leaf views without touching split
/// geometry — this is what lets an operator's manual drag-resize survive content
/// refreshes.
///
/// Split ratios are persisted in `UserDefaults` keyed by focus tag + tree path
/// so the workspace looks the same after switching tabs or restarting the app.
/// Only a genuine split-topology change (see `LayoutChangeClassifier`) overrides
/// the saved ratios — opening, closing, or switching an agent-authored tab does
/// not, and neither does the very first render of a freshly (re)launched app
/// (see `renderLayout(_:clearRatios:)`).
final class DynamicFocusView: NSView {

    // MARK: - Init

    private let focus: Focus
    private var cancellables = Set<AnyCancellable>()

    /// Leaf views keyed by pane_id (ReplView or PaneContentNSView wrappers).
    /// Includes panes hosted inside a `TabRegionView` — the tabs container is
    /// purely a presentation wrapper; this map always holds the raw content view.
    private var leafViews: [String: NSView] = [:]

    /// The tree that's currently rendered, used to classify the next incoming
    /// tree via `LayoutChangeClassifier`. `nil` only before the first render.
    private var renderedTree: PaneTree?

    /// Every live `TabRegionView`, keyed by its structural path (the same
    /// dotted path scheme `LayoutChangeClassifier` uses), so a
    /// `.activeTabOnly`/`.tabMembership` update can find the right container
    /// without a full rebuild.
    private var tabRegionsByPath: [String: TabRegionView] = [:]

    /// Reverse lookup: which `TabRegionView` (if any) currently hosts a given
    /// pane id — used by `updateContent` to route captions/unread state.
    private var tabRegionForPaneId: [String: TabRegionView] = [:]

    /// The `focused_pane` value last actually applied via
    /// `applyFocusedPaneHint`. `handleLayoutUpdate` runs on *every*
    /// `FocusLayoutModel` publish — including a pure content push that never
    /// touched `focused_pane` at all, since content/freshness/address live on
    /// the same model `AppStore` republishes as a whole. Without this,
    /// re-applying the hint unconditionally on every branch (needed so a
    /// `focused_pane`-only change with no tree change still takes effect)
    /// also re-selects the same tab on every unrelated content update,
    /// silently undoing whatever tab the operator just clicked into.
    private var lastAppliedFocusedPane: String?

    /// Tokens for every `NSSplitView.didResizeSubviewsNotification` observer
    /// registered by `makeSplitView`, so a structural rebuild can remove them
    /// all instead of leaking one observer per split per rebuild (D7).
    private var splitObserverTokens: [NSObjectProtocol] = []

    init(focus: Focus) {
        self.focus = focus
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeSplitObservers()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = .clear

        // Render whatever layout the store already has. This is NOT a
        // `.splitTopology` change (there is no previous tree to compare
        // against), so saved ratios are left alone — this is what makes a
        // relaunch's first `FocusLayout` broadcast able to actually restore
        // the operator's last dragged ratios instead of wiping them.
        //
        // Routed through `reconcile` rather than a direct `renderLayout`
        // call: with `renderedTree` still `nil` and `leafViews`/
        // `tabRegionsByPath` still empty, `matchesRenderedHierarchy` is
        // guaranteed to report a mismatch, so this is just the ordinary
        // "nothing rendered yet" case of the same single choke point every
        // later update goes through — not a special case.
        let initial = AppStore.shared.focusLayouts[focus.sessionTag] ?? FocusLayoutModel.initial
        reconcile(initial, clearRatios: false)
        applyFocusedPaneHint(initial.focusedPane)

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
        // `focused_pane` is authoritative over a tabs node's own `active`
        // index: when it names a live tab child, bring that tab to front.
        // Applied on every branch below (not just structural ones), via
        // `defer` so it can't be skipped by an early return — a
        // `FocusLayout` broadcast can update `focused_pane` alone.
        defer { applyFocusedPaneHint(model.focusedPane) }

        guard let previousTree = renderedTree else {
            reconcile(model)
            updateContent(model.paneContent, freshness: model.paneFreshness, address: model.paneAddress)
            return
        }

        switch LayoutChangeClassifier.classify(old: previousTree, new: model.tree) {
        case .identical, .contentOnly:
            reconcile(model)

        case .activeTabOnly(let paths):
            applyActiveTabOnly(paths: paths, newTree: model.tree)
            reconcile(model)

        case .tabMembership(let paths):
            applyTabMembership(paths: paths, newTree: model.tree)
            reconcile(model)

        case .splitTopology:
            // The only case that clears saved ratios — an agent-authored
            // structural change (a real split direction/ratio/shape change,
            // not merely a tab being opened/closed/switched) supersedes
            // whatever the operator had dragged.
            reconcile(model, clearRatios: true)
        }

        // `reconcile` above rebuilds (and internally re-pushes content) only
        // when the hierarchy needed it. Every branch — including the ones
        // that just did an in-place repair with no rebuild — still needs
        // this pane content push; it's a no-op for panes whose content
        // didn't change (each renderer's own idempotent-push guard), so
        // calling it unconditionally here is cheap, not redundant work.
        updateContent(model.paneContent, freshness: model.paneFreshness, address: model.paneAddress)
    }

    /// The operator's escape hatch (D5) when a saved ratio has left a pane
    /// unusable and "apply your standard layout" alone can't fix it — the
    /// agent's re-broadcast still loses to whatever is saved on disk (D2
    /// closes that for *future* corruption, but this is the in-app way to
    /// clear a *current* one without `defaults delete`). Rebuilds from
    /// whatever tree the store currently holds via the same `clearRatios:
    /// true` path a genuine `.splitTopology` change takes — not a special
    /// case, just invoked directly instead of waiting for the daemon to send
    /// a structurally different tree.
    ///
    /// Not `private`/`fileprivate`: `ReplView.runQuickAction` calls this
    /// directly on the `DynamicFocusView` it finds by walking its own
    /// superview chain (every `ReplView` is built as a leaf under exactly
    /// one live `DynamicFocusView` — see `makeLeafView` — so that ancestor
    /// always exists once the pane is on screen).
    func performLayoutReset() {
        let model = AppStore.shared.focusLayouts[focus.sessionTag] ?? FocusLayoutModel.initial
        reconcile(model, clearRatios: true)
    }

    /// Every structural repair ends here. If the hierarchy we actually hold
    /// no longer matches the tree we were told to render — because an
    /// incremental repair above silently failed to reach it — rebuild from
    /// scratch rather than leaving a half-applied state no later update can
    /// escape. The sole place `renderedTree` is assigned: every render
    /// path, incremental repair or full rebuild, funnels through here, so
    /// "did the repair actually succeed" is checked in exactly one place
    /// instead of trusted blindly by whichever branch of
    /// `handleLayoutUpdate` ran.
    ///
    /// `clearRatios` is true only for a genuine agent-authored
    /// `.splitTopology` change — a rebuild triggered because an incremental
    /// repair's own bookkeeping turned out to be wrong is not agent intent
    /// and must not wipe the operator's dragged ratios.
    private func reconcile(_ model: FocusLayoutModel, clearRatios: Bool = false) {
        let expected = PaneRenderPlan.build(from: model.tree)
        if clearRatios || !matchesRenderedHierarchy(expected) {
            renderLayout(model, clearRatios: clearRatios)
        }
        renderedTree = model.tree
    }

    /// Whether the view hierarchy this instance actually holds matches
    /// `expected` — every leaf resident under its expected pane id, every
    /// tabs node's membership/active pane correct, and nothing registered
    /// that isn't actually reachable from `self`.
    ///
    /// That last check is what catches the specific failure mode
    /// `replaceInPlace` can produce: `TabRegionView.init` re-parents a tabs
    /// node's children into the *new* region (`addSubview` implicitly
    /// removes them from their old superview) before `replaceInPlace` ever
    /// runs, so if `replaceInPlace` then fails to insert that new region
    /// into the hierarchy, the region and its children are fully built,
    /// fully wired into `tabRegionsByPath`/`leafViews` — and structurally
    /// orphaned. A plain `view.superview != nil` check would miss this
    /// entirely (the orphan's children still have *a* superview, just not
    /// one that reaches `self`), which is why this walks the chain via
    /// `isInHierarchy` instead.
    private func matchesRenderedHierarchy(_ expected: PaneRenderPlan) -> Bool {
        guard Set(leafViews.keys) == expected.paneIds else { return false }
        guard Set(tabRegionsByPath.keys) == Set(expected.tabsNodes.map(\.path)) else { return false }

        for node in expected.tabsNodes {
            guard let region = tabRegionsByPath[node.path],
                  region.paneIds == node.paneIds,
                  region.activePaneId == node.activePaneId,
                  isInHierarchy(region)
            else { return false }
        }

        for (_, view) in leafViews where !isInHierarchy(view) {
            return false
        }

        return true
    }

    /// Whether `view` is reachable from `self` by walking `superview` —
    /// deliberately stronger than `view.superview != nil`, which an
    /// orphaned subtree (re-parented into a container that was itself never
    /// inserted into the hierarchy) still satisfies.
    private func isInHierarchy(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v === self { return true }
            current = v.superview
        }
        return false
    }

    /// When `paneId` names a pane currently hosted inside a `TabRegionView`,
    /// bring that tab to front. A no-op for `nil`, for a pane not (yet) in
    /// any tabs region, or for a pane already frontmost.
    ///
    /// Gated on an actual change from `lastAppliedFocusedPane` — this is
    /// called on every `handleLayoutUpdate`, including pure content pushes
    /// that never touched `focused_pane`, and re-selecting the same tab on
    /// every one of those would silently undo an operator's manual tab
    /// click the moment anything else in the focus updates.
    private func applyFocusedPaneHint(_ paneId: String?) {
        guard paneId != lastAppliedFocusedPane else { return }
        lastAppliedFocusedPane = paneId
        guard let paneId, let region = tabRegionForPaneId[paneId] else { return }
        region.selectTab(paneId)
    }

    /// Full rebuild. `clearRatios` is true only for a genuine
    /// `.splitTopology` classification — the initial render in `setup()`
    /// passes `false` so a freshly (re)launched app can still read back
    /// ratios the operator dragged in a previous session (D7).
    private func renderLayout(_ model: FocusLayoutModel, clearRatios: Bool) {
        // Snapshot existing leaf views before tearing anything down. A leaf
        // whose pane_id persists across this structural change — "repl" in
        // particular, whose content has nothing to do with tree shape — gets
        // re-parented into the new hierarchy below instead of being destroyed
        // and recreated. Recreating ReplView on every structural rebuild was
        // silently resetting scroll position and the pinned-to-bottom state
        // on a fresh instance each time, undoing the user's manual scroll.
        let previousLeafViews = leafViews

        // Remove every registered split-resize observer before tearing down
        // the views that own them — otherwise each rebuild leaks one
        // observer per split, forever (D7).
        removeSplitObservers()

        // Remove existing content.
        subviews.forEach { $0.removeFromSuperview() }
        leafViews = [:]
        tabRegionsByPath = [:]
        tabRegionForPaneId = [:]
        // NB: `renderedTree` is NOT assigned here — `reconcile` (the only
        // caller of `renderLayout`) is the single place that happens, once,
        // after this method returns.

        if clearRatios {
            // Clear any previously saved operator-drag ratios so the agent's
            // layout intent takes effect on this structural rebuild. The
            // operator can drag to adjust after the agent assembles; those
            // new ratios will be persisted until the next such change.
            clearSavedRatios(for: focus.sessionTag)
        }

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
        updateContent(model.paneContent, freshness: model.paneFreshness, address: model.paneAddress)
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
        case .tabs(let children, let labels, let active):
            return makeTabsView(
                children: children,
                labels: labels,
                active: active,
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
        let split = RatioSplitView()
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

        // A saved ratio set is trusted only after it passes
        // `RatioPersistencePolicy.isWellFormed` — the same shape check that
        // gates writing one — plus a count check against this split's actual
        // child count (fix-collapsed-split-ratio-persistence D2). This is
        // what heals an already-corrupt value like `[0.977, 0.022]` on the
        // very next launch with no migration step, and closes the path-key
        // reuse hazard: `udKey` is keyed by tag + tree path, so a
        // structurally different split that lands at the same path would
        // otherwise silently inherit its predecessor's ratios. There's no
        // real size to check a `total` against yet at this point in
        // `makeSplitView`, which is exactly why this asks `isWellFormed`
        // (shape only) rather than the fuller `shouldPersist`.
        let savedRatios = UserDefaults.standard.array(forKey: udKey) as? [Double]
        let validatedRatios = savedRatios.flatMap { saved -> [Double]? in
            guard saved.count == children.count, RatioPersistencePolicy.isWellFormed(ratios: saved)
            else { return nil }
            return saved
        }
        if savedRatios != nil && validatedRatios == nil {
            UserDefaults.standard.removeObject(forKey: udKey)
        }

        // Applied on the first layout pass where `split` actually has a
        // size (see `RatioSplitView.layout()`) — not a one-shot
        // `DispatchQueue.main.async` dispatch, which used to silently
        // abandon the ratios forever whenever the split still reported
        // zero size on the one run-loop turn that block happened to fire: a
        // fresh launch, or a window created for a display attached after
        // launch, both leave a split with no real size for at least one
        // turn. `RatioSplitView` instead keeps trying on every layout pass
        // until it succeeds, then stops — so it can never fight an operator
        // drag either.
        split.desiredRatios = validatedRatios ?? ratios

        // Persist the operator's drag-resize — and only that. The policy
        // check is what stops this observer from writing the transient
        // near-zero state of a region being inserted, or our own
        // programmatic `applyRatios` call re-entering this same
        // notification, back to disk as if the operator had chosen it
        // (fix-collapsed-split-ratio-persistence D1/RC1). The token is
        // retained so a future structural rebuild can remove this observer
        // instead of leaking it (D7) — see `removeSplitObservers`.
        let token = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split,
            queue: .main
        ) { _ in
            let total = Double(DynamicFocusView.extent(of: split.bounds.size, isVertical: split.isVertical))
            let newRatios = DynamicFocusView.currentRatios(for: split)
            guard RatioPersistencePolicy.shouldPersist(
                ratios: newRatios,
                total: total,
                isProgrammatic: split.isApplyingProgrammatically
            ) else { return }
            UserDefaults.standard.set(newRatios, forKey: udKey)
        }
        splitObserverTokens.append(token)

        return split
    }

    /// Build a `TabRegionView` for a `PaneTree.tabs` node (W1). In v1 every
    /// tab child is a `Leaf` (enforced by the registry), so each tab's pane id
    /// is simply that leaf's id; `buildView` is still used to construct the
    /// child so leaf reuse/`leafViews` bookkeeping stays uniform with the
    /// split path.
    private func makeTabsView(
        children: [PaneTree],
        labels: [String],
        active: Int,
        tag: String,
        path: String,
        reusing previous: [String: NSView]
    ) -> NSView {
        let (tabs, activePaneId) = buildTabs(children: children, labels: labels, active: active, tag: tag, path: path, reusing: previous)
        let region = TabRegionView(tabs: tabs, activePaneId: activePaneId)
        registerTabRegion(region, tabs: tabs, at: path)
        return region
    }

    /// Build the `[TabRegionView.Tab]`/active-pane-id pair a tabs node's
    /// children resolve to — shared by `makeTabsView` (a fresh tabs node
    /// during a full rebuild) and `applyTabMembership` (rebuilding just one
    /// tabs node's children in place). Both contexts differ only in which
    /// `reusing` dict they pass (the whole previous tree vs. a pruned one) —
    /// this helper doesn't need to know which.
    private func buildTabs(
        children: [PaneTree],
        labels: [String],
        active: Int,
        tag: String,
        path: String,
        reusing previous: [String: NSView]
    ) -> (tabs: [TabRegionView.Tab], activePaneId: String) {
        var tabs: [TabRegionView.Tab] = []
        for (i, child) in children.enumerated() {
            let childView = buildView(for: child, tag: tag, path: "\(path).tab\(i)", reusing: previous)
            let paneId = child.paneIds.first ?? "unknown"
            let label = i < labels.count ? labels[i] : paneId
            tabs.append(TabRegionView.Tab(paneId: paneId, label: label, view: childView))
        }
        let activePaneId = tabs.indices.contains(active) ? tabs[active].paneId : (tabs.first?.paneId ?? "")
        return (tabs, activePaneId)
    }

    /// Record `region`'s path and every one of its tabs' pane ids in the two
    /// lookup tables `applyFocusedPaneHint`/`updateContent` consult — shared
    /// by `makeTabsView` and `applyTabMembership`.
    private func registerTabRegion(_ region: TabRegionView, tabs: [TabRegionView.Tab], at path: String) {
        tabRegionsByPath[path] = region
        for tab in tabs {
            tabRegionForPaneId[tab.paneId] = region
        }
    }

    // MARK: - Targeted tabs updates (LayoutChangeClassifier: no full rebuild)

    /// One or more tabs nodes changed only which child is `active` — flip
    /// visibility/selection in place, no teardown, no saved-ratio impact.
    ///
    /// Returns `false` when any path failed to resolve — a signal
    /// `reconcile`'s hierarchy check independently rediscovers and repairs
    /// via a full rebuild; this return exists so no failure here goes
    /// unpropagated, not because a caller currently branches on it.
    @discardableResult
    private func applyActiveTabOnly(paths: [String], newTree: PaneTree) -> Bool {
        var allSucceeded = true
        for path in paths {
            if let region = tabRegionsByPath[path],
               case .tabs(let children, _, let active)? = node(at: path, in: newTree),
               children.indices.contains(active) {
                let activePaneId = children[active].paneIds.first ?? ""
                region.selectTab(activePaneId)
            } else {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// One or more tabs nodes' `children`/`labels` changed (a tab opened,
    /// closed, reordered, or relabeled) while the surrounding split topology
    /// did not — rebuild only the affected `TabRegionView`s in place, and
    /// deliberately do NOT call `clearSavedRatios`.
    ///
    /// Returns `false` when any path failed to resolve, or its in-place
    /// swap failed — same non-branching-but-non-silent contract as
    /// `applyActiveTabOnly`: `reconcile`'s hierarchy check is what actually
    /// catches and repairs the failure.
    @discardableResult
    private func applyTabMembership(paths: [String], newTree: PaneTree) -> Bool {
        var allSucceeded = true
        for path in paths {
            if let oldRegion = tabRegionsByPath[path],
               case .tabs(let children, let labels, let active)? = node(at: path, in: newTree) {

                // Drop bookkeeping for any pane this region no longer hosts.
                let newPaneIds = Set(children.compactMap { $0.paneIds.first })
                for oldPaneId in oldRegion.paneIds where !newPaneIds.contains(oldPaneId) {
                    leafViews.removeValue(forKey: oldPaneId)
                    tabRegionForPaneId.removeValue(forKey: oldPaneId)
                }

                let previousLeafViews = leafViews
                let (tabs, activePaneId) = buildTabs(children: children, labels: labels, active: active, tag: focus.sessionTag, path: path, reusing: previousLeafViews)
                let newRegion = TabRegionView(tabs: tabs, activePaneId: activePaneId)

                // `registerTabRegion` must never run for a swap that didn't
                // actually land — that's exactly how a `TabRegionView`
                // re-parented by its own `init` (see `matchesRenderedHierarchy`'s
                // doc comment) but never inserted into the hierarchy used to
                // get registered anyway, wedging every later update for its
                // panes into a region nothing can ever see again.
                if replaceInPlace(oldRegion, with: newRegion) {
                    registerTabRegion(newRegion, tabs: tabs, at: path)
                } else {
                    allSucceeded = false
                }
            } else {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Swap `oldView` for `newView` in whatever container currently holds it
    /// — an `NSSplitView`'s arranged subviews (preserving position), or a
    /// plain superview (the rare case of a tabs node at the tree root).
    /// Returns `false` when `oldView` has no superview to swap within —
    /// the caller must not treat that as success.
    @discardableResult
    private func replaceInPlace(_ oldView: NSView, with newView: NSView) -> Bool {
        guard let parent = oldView.superview else { return false }
        if let splitParent = parent as? NSSplitView, let idx = splitParent.arrangedSubviews.firstIndex(of: oldView) {
            splitParent.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
            splitParent.insertArrangedSubview(newView, at: idx)
        } else {
            newView.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(newView)
            NSLayoutConstraint.activate([
                newView.topAnchor.constraint(equalTo: parent.topAnchor),
                newView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                newView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                newView.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
            oldView.removeFromSuperview()
        }
        return true
    }

    /// Walk `tree` along `path` (`LayoutChangeClassifier`'s dotted scheme:
    /// `"root"`, `"root.0"`, `"root.tab1"`, …) and return the node found
    /// there, or `nil` if the path no longer resolves.
    private func node(at path: String, in tree: PaneTree) -> PaneTree? {
        let components = path.split(separator: ".").dropFirst() // drop leading "root"
        var current = tree
        for component in components {
            switch current {
            case .split(_, let children, _):
                guard let idx = Int(component), children.indices.contains(idx) else { return nil }
                current = children[idx]
            case .tabs(let children, _, _):
                guard component.hasPrefix("tab"),
                      let idx = Int(component.dropFirst(3)),
                      children.indices.contains(idx)
                else { return nil }
                current = children[idx]
            case .leaf:
                return nil
            }
        }
        return current
    }

    // MARK: - Ratio helpers

    /// The dimension a split's ratios are measured along: width for a
    /// vertical-oriented (side-by-side) split, height for a horizontal
    /// (stacked) one. Shared by `applyRatios`/`currentRatios`, which each
    /// need this same "which axis" decision — once for the split's own
    /// bounds, and (in `currentRatios`) again per child frame.
    private static func extent(of size: CGSize, isVertical: Bool) -> CGFloat {
        isVertical ? size.width : size.height
    }

    /// Turn `ratios` into actual divider positions via `RatioSolver` and
    /// apply them. A `nil` from the solver (no real size yet, a count
    /// mismatch, or ratios that don't sum to ~1.0) means "don't touch the
    /// split" — obedience is everything this does; every judgement call
    /// about whether it's safe to apply lives in `RatioSolver`. Returns
    /// whether the ratios were actually applied, so `RatioSplitView.layout()`
    /// can tell a real application apart from a refusal (D3) — the exact
    /// distinction `RatioSolver`'s own doc comment says the caller must
    /// honour: keep trying next layout pass on `false`, stop trying on
    /// `true`.
    ///
    /// `fileprivate` rather than `private`: `RatioSplitView`, a separate
    /// top-level type in this same file, is the only other caller.
    @discardableResult
    fileprivate static func applyRatios(_ ratios: [Double], to split: NSSplitView) -> Bool {
        let subviews = split.subviews
        let total = extent(of: split.bounds.size, isVertical: split.isVertical)
        guard let positions = RatioSolver.dividerPositions(
            ratios: ratios,
            total: Double(total),
            dividerThickness: Double(split.dividerThickness),
            subviewCount: subviews.count
        ) else { return false }
        for (i, position) in positions.enumerated() {
            split.setPosition(CGFloat(position), ofDividerAt: i)
        }
        split.adjustSubviews()
        return true
    }

    /// The operator's actual current split, normalized so the result sums to
    /// 1.0 (fix-collapsed-split-ratio-persistence D4). Divides each child's
    /// extent by the *sum of the children's own extents*, not by the split's
    /// full bounds — the split's bounds also include divider thickness,
    /// which belongs to no child, so normalizing against it produced a set
    /// that systematically summed to `1 - dividerThickness/total` (observed:
    /// 0.9995, 0.9993, 0.9994). On a narrow split that deficit is large
    /// enough to trip `RatioSolver.dividerPositions`'s `abs(sum - 1.0) < 0.01`
    /// tolerance, and a solver refusal used to be indistinguishable from a
    /// successful application (see `RatioSplitView.layout()`), silently
    /// abandoning the ratios. Normalizing against the child-extent sum makes
    /// `applyRatios` → `currentRatios` a round trip.
    private static func currentRatios(for split: NSSplitView) -> [Double] {
        let subviews = split.subviews
        let sizes = subviews.map { extent(of: $0.frame.size, isVertical: split.isVertical) }
        let sum = sizes.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1.0 / Double(subviews.count), count: subviews.count) }
        return sizes.map { Double($0 / sum) }
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

    private func removeSplitObservers() {
        for token in splitObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        splitObserverTokens.removeAll()
    }

    private func updateContent(
        _ paneContent: [String: PaneContentWire],
        freshness: [String: PaneFreshness],
        address: [String: PaneAddress]
    ) {
        for (paneId, content) in paneContent {
            if let leafView = leafViews[paneId] as? PaneContentNSView {
                leafView.update(content: content, freshness: freshness[paneId], address: address[paneId])

                // A tabs-hosted pane also gets its caption refreshed and,
                // when it isn't the frontmost tab, an unread indication —
                // both purely client-derived (D6), never sent by the daemon.
                if let region = tabRegionForPaneId[paneId] {
                    region.setCaption(address[paneId]?.reason, for: paneId)
                    region.noteContentPushed(for: paneId)
                }
            }
            // A miss here — no materialised view for a pane id `paneContent`
            // names — means the hierarchy has already diverged from what's
            // expected. Silently dropping the push (the old `continue`) is
            // exactly the bug this file fixes; `reconcile`, called from
            // every branch of `handleLayoutUpdate` right around this, is
            // what actually detects and repairs that divergence.
        }
    }
}

// MARK: - RatioSplitView

/// An `NSSplitView` that remembers the ratios it was asked for and applies
/// them on the first layout pass where it actually has a real size — then
/// stops, so it never fights an operator drag.
///
/// Replaces a one-shot `DispatchQueue.main.async` application, which used to
/// silently abandon the ratios forever whenever the split still reported
/// zero size on the one run-loop turn that block happened to fire — a fresh
/// launch, or a window created for a display attached after launch, both
/// leave a split with no real size for at least one turn. Overriding
/// `layout()` instead means every layout pass gets another try until one
/// actually lands.
final class RatioSplitView: NSSplitView {

    /// Set once by `DynamicFocusView.makeSplitView`; cleared only once
    /// `applyRatios` actually succeeds (D3). `nil` means either "never
    /// asked" or "already successfully applied" — both mean "leave the
    /// split alone." A solver refusal (no real size yet, a count mismatch,
    /// or ratios that don't sum to ~1.0) leaves this set so the next layout
    /// pass tries again, exactly the contract `RatioSolver`'s own doc
    /// comment describes — clearing this unconditionally, before knowing
    /// whether the apply landed, used to silently abandon the ratios
    /// forever on a refusal.
    var desiredRatios: [Double]?

    /// True for the duration of a programmatic ratio application —
    /// `DynamicFocusView.makeSplitView`'s resize observer consults this via
    /// `RatioPersistencePolicy` so `setPosition`/`adjustSubviews` below
    /// (which post `NSSplitView.didResizeSubviewsNotification` just like an
    /// operator drag does) can never be mistaken for one and written to
    /// disk. This — not clearing `desiredRatios` before applying — is what
    /// actually guards re-entrancy through that observer
    /// (fix-collapsed-split-ratio-persistence D1/D3).
    private(set) var isApplyingProgrammatically = false

    override func layout() {
        super.layout()
        guard let ratios = desiredRatios, bounds.width > 0, bounds.height > 0 else { return }
        isApplyingProgrammatically = true
        let applied = DynamicFocusView.applyRatios(ratios, to: self)
        isApplyingProgrammatically = false
        if applied {
            desiredRatios = nil
        }
    }
}

// MARK: - PaneContentNSView

/// An NSView wrapper around the SwiftUI PaneContentView, used for non-repl panes.
///
/// Model-driven (D9): the `NSHostingView` is built once in `init` and never
/// torn down or replaced. `update(content:freshness:)` pushes new state
/// through `PaneContentModel`'s `@Published` properties instead — SwiftUI's
/// own diffing on that state is what preserves scroll position and
/// `pr_list`/text identity across a refresh, which rebuilding the hosting
/// view on every push (the old approach) reset every time.
final class PaneContentNSView: NSView {

    private let model = PaneContentModel()
    private var currentContent: PaneContentWire?

    /// The line-addressable renderer for the `code`/`diff` kinds (W2 —
    /// curated-agent-views). A persistent sibling of the hosting view, shown
    /// for those two kinds and hidden for the other five — never torn down, so
    /// a pane that flips kinds and flips back keeps its scroll position, the
    /// same D9 discipline the hosting view itself follows.
    private let codeView = CodeContentView()
    /// The `pr_conversation` renderer (W3 — curated-agent-views). Same
    /// persistent-sibling discipline as `codeView`.
    private let conversationView = ConversationContentView()
    /// The `ticket` renderer (W4 — curated-agent-views). Same
    /// persistent-sibling discipline as `codeView`/`conversationView`.
    private let ticketView = TicketContentView()

    /// Injected by `DynamicFocusView.makeLeafView` — called when a `pr_list` row is loaded.
    var onLoadPR: (String, Int) -> Void = { _, _ in } {
        didSet { model.onLoadPR = onLoadPR }
    }
    /// Injected by `DynamicFocusView.makeLeafView` — called when a `pr_list` row is approved.
    var onApprovePR: (String, Int) -> Void = { _, _ in } {
        didSet { model.onApprovePR = onApprovePR }
    }
    /// Injected by `DynamicFocusView.makeLeafView` — called when the operator
    /// clicks the pane's refresh button.
    var onRefresh: () -> Void = {}

    /// Persistent AppKit chrome, added after the (also persistent) SwiftUI
    /// content so it always renders on top.
    private let refreshButton = NSButton()
    /// D11: quiet "stale · as of HH:MM" footnote. Hidden unless the pane is
    /// badly stale, so there is no chrome during normal operation.
    private let staleLabel = NSTextField(labelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let hosting = NSHostingView(rootView: PaneContentHost(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.appearance = NSAppearance(named: .darkAqua)
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Each of `codeView`/`conversationView`/`ticketView` is added after
        // `hosting` (so it draws on top) and before the chrome below (so the
        // refresh button and stale footnote stay on top of all three), hidden
        // by default, shown only for its own content kind (W2/W3/W4 —
        // curated-agent-views).
        addFullBleedHiddenSibling(codeView)
        addFullBleedHiddenSibling(conversationView)
        addFullBleedHiddenSibling(ticketView)

        // Force dark appearance explicitly rather than relying on inheritance —
        // `hosting` above gets the same forced .darkAqua, and a mismatch here
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

        staleLabel.font             = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        staleLabel.textColor        = .tertiaryLabelColor
        staleLabel.appearance       = NSAppearance(named: .darkAqua)
        staleLabel.isBordered       = false
        staleLabel.drawsBackground  = false
        staleLabel.isEditable       = false
        staleLabel.isSelectable     = false
        staleLabel.isHidden         = true
        staleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(staleLabel)
        NSLayoutConstraint.activate([
            staleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            staleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Add `view` as a subview pinned to all four edges, hidden by default —
    /// the shape every content-kind sibling (`codeView`/`conversationView`/
    /// `ticketView`) shares. `update(content:freshness:address:)` is what
    /// flips `isHidden` back off for whichever one currently handles the
    /// pane's content kind.
    private func addFullBleedHiddenSibling(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func didTapRefresh() { onRefresh() }

    /// Push new content/freshness/address for this pane. Skips the
    /// `@Published` content write entirely when `content` is unchanged (D9)
    /// — an idempotent push must be visually invisible: no flicker, no
    /// scroll reset, no spinner.
    func update(content: PaneContentWire, freshness: PaneFreshness?, address: PaneAddress? = nil) {
        if content != currentContent {
            model.content = content
            currentContent = content
        }
        // W2/W3: `code`/`diff`/`pr_conversation` each render in AppKit, not
        // SwiftUI — there is no gutter, no scroll-to-offset, and no range
        // highlighting available in a SwiftUI `Text`. The model write above
        // still happens so all views never disagree about what the pane
        // holds; only visibility decides which one the operator sees.
        // Each `else` below drops whatever that sibling renderer was holding
        // the moment it stops being the pane's renderer — otherwise a later
        // re-show of the same kind resurfaces a *previous* document's
        // gutter/text over the new content, or (via that renderer's own
        // idempotent-push guard) gets mistaken for an already-rendered
        // no-op. See each `clearContent()`'s doc comment for the
        // scroll-position trade-off this accepts.
        if CodeContentView.handles(content) {
            codeView.isHidden = false
            codeView.update(content: content, address: address)
        } else {
            codeView.isHidden = true
            codeView.clearContent()
        }
        if ConversationContentView.handles(content) {
            conversationView.isHidden = false
            conversationView.update(content: content, address: address)
        } else {
            conversationView.isHidden = true
            conversationView.clearContent()
        }
        if TicketContentView.handles(content) {
            ticketView.isHidden = false
            ticketView.update(content: content, address: address)
        } else {
            ticketView.isHidden = true
            ticketView.clearContent()
        }
        // Freshness and address are cheap to always re-assign — neither ever
        // rebuilds anything; freshness toggles the footnote below, and
        // address's `reason` is read by the caller (`DynamicFocusView`) to
        // drive the owning `TabRegionView`'s caption, not rendered here.
        model.freshness = freshness
        model.address = address
        updateStaleLabel(freshness)
    }

    private func updateStaleLabel(_ freshness: PaneFreshness?) {
        guard let freshness, freshness.badlyStale else {
            staleLabel.isHidden = true
            return
        }
        if let asOf = freshness.asOf {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            staleLabel.stringValue = "stale · as of \(formatter.string(from: asOf))"
        } else {
            staleLabel.stringValue = "stale"
        }
        staleLabel.isHidden = false
    }
}
