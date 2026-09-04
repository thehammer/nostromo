// NostromoKit — DaemonStoreTests.swift
//
// Verifies DaemonStore's handling of pane_content broadcasts, specifically
// the "loading suppression" rule: a `.loading` update must never clobber
// already-painted content for a pane, but it IS stored as the first paint
// when nothing (or another `.loading`) is currently held for that pane.
//
// We construct a real `NetworkClient` without calling `start()` so it never
// opens a socket, then push `ServerMsg` values directly through its public
// `messages` subject — the same technique used by
// macOS/NostromoTests/SessionHealthTests.swift for the macOS-local client.
//
// `DaemonStore` is `@MainActor`, so every call that touches it or its
// `NetworkClient` must be `await`ed from these (non-isolated) test methods.
// `DaemonStore`'s `client.messages` pipeline is `.receive(on: RunLoop.main)`,
// so delivery is asynchronous even though we're already on the main thread;
// a short `Task.sleep` after each send gives the main run loop a tick to
// flush the scheduled handler before we assert.

import XCTest
@testable import NostromoKit

final class DaemonStoreTests: XCTestCase {

    private func deliver(_ msg: ServerMsg, via client: NetworkClient) async {
        await client.messages.send(msg)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func makeItems() -> [PrListItemModel] {
        [
            PrListItemModel(
                repo: "acme/web", number: 1, title: "feat: auth", author: "alice",
                bucket: "requested", ciState: .success, newActivity: false,
                url: "https://github.com/acme/web/pull/1", headSha: "abc123"
            )
        ]
    }

    // MARK: - .loading is ignored when non-loading content already exists

    func testLoadingUpdateIsIgnoredWhenNonLoadingContentAlreadyStored() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let items  = makeItems()

        // First paint: a real pr_list.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .prList(items), freshness: nil, address: nil),
            via: client
        )
        let storedBefore = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        XCTAssertEqual(storedBefore, .prList(items), "sanity check: pr_list should be stored on first paint")

        // A subsequent .loading update for the same pane must be dropped entirely.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil, address: nil),
            via: client
        )
        let storedAfter = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        XCTAssertEqual(
            storedAfter, .prList(items),
            "a .loading update must be ignored when non-loading content is already stored for this pane"
        )
    }

    // MARK: - .loading IS stored when there's no prior content (first paint)

    func testLoadingUpdateIsStoredWhenNoPriorContentExistsForPane() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil, address: nil),
            via: client
        )

        let stored = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        XCTAssertEqual(
            stored, .loading,
            "a .loading update must be stored as the first paint when no prior content exists for this pane"
        )
    }

    // MARK: - .loading IS stored when the prior content was itself .loading

    func testLoadingUpdateReplacesAnExistingLoadingState() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil, address: nil),
            via: client
        )
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil, address: nil),
            via: client
        )

        let stored = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        XCTAssertEqual(
            stored, .loading,
            "a second .loading update must still be stored when the existing content is itself .loading"
        )
    }

    // MARK: - Suppression is scoped to (tag, pane) — a different pane is unaffected

    func testLoadingSuppressionIsScopedToTheSpecificPane() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let items  = makeItems()

        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .prList(items), freshness: nil, address: nil),
            via: client
        )
        // A .loading update for a *different* pane on the same focus is a first
        // paint for that pane and must be stored, without disturbing pane1.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane2", content: .loading, freshness: nil, address: nil),
            via: client
        )

        let pane1 = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        let pane2 = await store.focusLayouts["focus1"]?.paneContent["pane2"]
        XCTAssertEqual(pane1, .prList(items), "pane1 must be untouched by pane2's update")
        XCTAssertEqual(pane2, .loading, "pane2 has no prior content, so .loading is stored as first paint")
    }

    // MARK: - paneContentVersion (W5 — ios-curated-view-parity, D7)
    //
    // `FocusLayoutModel.paneContentVersion` is a per-pane counter that must
    // increment only when a `pane_content` push is actually *applied* —
    // i.e. after the `.loading`-suppression early-return above, never before
    // it. It is what `FocusRegionState.isUnread` (D7) is compared against.

    func testPaneContentVersionIncrementsOnlyForAppliedPushes() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .text("v1"), freshness: nil, address: nil),
            via: client
        )
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .text("v2"), freshness: nil, address: nil),
            via: client
        )

        let versionAfterTwoRealPushes = await store.focusLayouts["focus1"]?.paneContentVersion["pane1"]
        XCTAssertEqual(versionAfterTwoRealPushes, 2, "two applied pushes to the same pane must bump the version twice")

        // A `.loading` push the existing suppression guard drops must not
        // bump the version — it never reaches the "applied" line.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil, address: nil),
            via: client
        )
        let versionAfterSuppressedLoading = await store.focusLayouts["focus1"]?.paneContentVersion["pane1"]
        XCTAssertEqual(
            versionAfterSuppressedLoading, 2,
            "a .loading push suppressed by the existing guard must not bump paneContentVersion"
        )
    }

    // MARK: - focusRegionStates (W5 — ios-curated-view-parity, D4)
    //
    // A `.focusLayout` arrival must classify the incoming tree against the
    // previously-stored one and apply the resulting `LayoutChange` into
    // `focusRegionStates[tag]`, resolving `treeActivePaneId` from the new
    // tree's own `resolvedActivePaneId`.

    func testFocusLayoutArrivalAppliesAnActiveTabOnlyTransitionIntoFocusRegionState() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"

        let treeActive0 = PaneTree.split(direction: .horizontal, children: [
            .leaf(paneId: "repl"),
            .tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0)
        ], ratios: [0.5, 0.5])
        let treeActive1 = PaneTree.split(direction: .horizontal, children: [
            .leaf(paneId: "repl"),
            .tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 1)
        ], ratios: [0.5, 0.5])

        await deliver(.focusLayout(tag: tag, tree: treeActive0, focusedPane: nil), via: client)
        await deliver(.focusLayout(tag: tag, tree: treeActive1, focusedPane: nil), via: client)

        let frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: FocusRegionState.compactRegion, available: ["repl", "a", "b"], fallback: "repl"
        )
        XCTAssertEqual(
            frontmost, "b",
            "a pure activeTabOnly transition must move the compact region's frontmost pane to the new active pane"
        )
    }

    func testTwoIdenticalFocusLayoutFramesInARowLeaveFocusRegionStateUnchanged() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = PaneTree.tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0)

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        let before = await store.focusRegionStates[tag]

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        let after = await store.focusRegionStates[tag]

        XCTAssertEqual(before, after, "an .identical focus_layout frame must not change focusRegionStates")
    }

    /// Same seam `DaemonStoreActivityTests.testStoppingTheClientClearsActivityState`
    /// uses: `client.stop()` unconditionally sets `connected = false`, driving
    /// the exact `$connected`-driven clearing branch in `DaemonStore.bind()`.
    func testStoppingTheClientClearsFocusRegionStatesAlongsideFocusLayouts() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = PaneTree.tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0)

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        let before = await store.focusRegionStates[tag]
        XCTAssertNotNil(before, "sanity check: focusRegionStates must be populated before we stop the client")

        await client.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let after = await store.focusRegionStates
        XCTAssertTrue(after.isEmpty, "focusRegionStates must be cleared on disconnect, same as focusLayouts")
    }

    // MARK: - selectPane (the operator-tap entry point)

    func testSelectPaneUpdatesFrontmostAndClearsTheUnreadMarkForThatPane() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let region = FocusRegionState.compactRegion

        let tree = PaneTree.split(direction: .horizontal, children: [
            .leaf(paneId: "repl"),
            .tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0)
        ], ratios: [0.5, 0.5])
        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)

        // "a" is frontmost (active: 0). A content push to "b" — not
        // frontmost — must register as unread.
        await deliver(
            .paneContent(tag: tag, paneId: "b", content: .text("hello"), freshness: nil, address: nil),
            via: client
        )

        var versionForB = await store.focusLayouts[tag]?.paneContentVersion["b"] ?? 0
        var unreadBeforeSelect = await store.focusRegionStates[tag]?.isUnread(
            paneId: "b", regionPath: region, contentVersion: versionForB)
        XCTAssertEqual(unreadBeforeSelect, true, "sanity check: b must be unread before it is selected")

        await store.selectPane(tag: tag, regionPath: region, paneId: "b")

        let frontmostAfterSelect = await store.focusRegionStates[tag]?.frontmostPane(
            for: region, available: ["repl", "a", "b"], fallback: "repl")
        XCTAssertEqual(frontmostAfterSelect, "b", "selectPane must make the tapped pane frontmost")

        versionForB = await store.focusLayouts[tag]?.paneContentVersion["b"] ?? 0
        unreadBeforeSelect = await store.focusRegionStates[tag]?.isUnread(
            paneId: "b", regionPath: region, contentVersion: versionForB)
        XCTAssertEqual(unreadBeforeSelect, false, "selectPane must clear the pane's unread mark")
    }

    // MARK: - W6: per-region state at regular width
    //
    // At regular width the daemon reports a tree with two simultaneously-
    // visible tabbed regions ("root.0" hosting "a"/"b", "root.1" hosting
    // "c"/"d"), each with its own tab strip and its own frontmost tab. The
    // store-level guarantee this section exists to prove: a show that
    // changes the frontmost tab of one region must never change the
    // frontmost tab of another — and, doubling the surface a show can land
    // on unseen, an unread mark must be legible per region. Every test below
    // drives this through the real `.focusLayout`/`.paneContent` ingestion
    // path, never by poking `FocusRegionState` directly, because the point
    // is to prove the STORE wires the pure per-region logic up correctly.

    private func twoRegionTree() -> PaneTree {
        .split(direction: .horizontal, children: [
            .tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0),
            .tabs(children: [.leaf(paneId: "c"), .leaf(paneId: "d")], labels: ["C", "D"], active: 0)
        ], ratios: [0.5, 0.5])
    }

    func testFocusedPaneMovesOnlyTheRegionItLandsInLeavingASiblingRegionsFrontmostUnmoved() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)

        // Move "root.0"'s frontmost away from its default ("a") first, so
        // "unmoved" below is a real assertion, not the fallback happening
        // to agree with the default.
        await store.selectPane(tag: tag, regionPath: "root.0", paneId: "b")

        // Same tree, only `focused_pane` differs — a deliberate show landing in "root.1".
        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: "d"), via: client)

        let root0Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.0", available: ["a", "b"], fallback: "a")
        XCTAssertEqual(root0Frontmost, "b", "a show landing in \"root.1\" must not move \"root.0\"'s frontmost pane")

        let root1Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.1", available: ["c", "d"], fallback: "c")
        XCTAssertEqual(root1Frontmost, "d", "focused_pane \"d\" must make \"d\" frontmost in the region that actually hosts it")
    }

    func testFocusedPaneMirroredIntoTheOtherRegionLeavesItsSiblingUnmoved() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)

        // Move BOTH regions away from their defaults, so each assertion
        // below is checked against a specific, known-different value.
        await store.selectPane(tag: tag, regionPath: "root.0", paneId: "b")
        await store.selectPane(tag: tag, regionPath: "root.1", paneId: "d")

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: "a"), via: client)

        let root0Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.0", available: ["a", "b"], fallback: "a")
        XCTAssertEqual(root0Frontmost, "a", "focused_pane \"a\" must make \"a\" frontmost in the region that actually hosts it")

        let root1Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.1", available: ["c", "d"], fallback: "c")
        XCTAssertEqual(root1Frontmost, "d", "a show landing in \"root.0\" must not move \"root.1\"'s frontmost pane")
    }

    func testFocusedPaneNamingAPaneInNeitherRegionMovesNeitherRegionsFrontmost() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        await store.selectPane(tag: tag, regionPath: "root.0", paneId: "b")
        await store.selectPane(tag: tag, regionPath: "root.1", paneId: "d")

        // "ghost" names no pane in this tree at all.
        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: "ghost"), via: client)

        let root0Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.0", available: ["a", "b"], fallback: "a")
        let root1Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.1", available: ["c", "d"], fallback: "c")
        XCTAssertEqual(root0Frontmost, "b", "a focused_pane naming no pane in this region must not move its frontmost")
        XCTAssertEqual(root1Frontmost, "d", "a focused_pane naming no pane in this region must not move its frontmost")
    }

    func testAPushToAPaneNotFrontmostInItsOwnRegionReadsUnreadForThatRegion() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        // "a" is "root.0"'s default frontmost (active: 0); "b" is not.
        await deliver(
            .paneContent(tag: tag, paneId: "b", content: .text("hello"), freshness: nil, address: nil), via: client)

        let version = await store.focusLayouts[tag]?.paneContentVersion["b"] ?? 0
        let unreadInRoot0 = await store.focusRegionStates[tag]?.isUnread(
            paneId: "b", regionPath: "root.0", contentVersion: version)
        XCTAssertEqual(
            unreadInRoot0, true,
            "a show landing on \"b\" while \"a\" is frontmost in \"root.0\" must read unread when asked about \"root.0\"")
    }

    func testAPushToAPaneHostedByTheOtherRegionMarksNothingUnreadInThisRegion() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        // "d" lives entirely in "root.1" — "root.0" has never heard of it.
        await deliver(
            .paneContent(tag: tag, paneId: "d", content: .text("hello"), freshness: nil, address: nil), via: client)

        let version = await store.focusLayouts[tag]?.paneContentVersion["d"] ?? 0
        let unreadInRoot0 = await store.focusRegionStates[tag]?.isUnread(
            paneId: "d", regionPath: "root.0", contentVersion: version)
        XCTAssertEqual(
            unreadInRoot0, false,
            "a push to a pane hosted only by \"root.1\" must not register as unread in the unrelated \"root.0\"")
    }

    func testAPushToThePaneAlreadyFrontmostInItsRegionIsNeverUnreadThere() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        // "a" is "root.0"'s default frontmost pane (active: 0).
        await deliver(
            .paneContent(tag: tag, paneId: "a", content: .text("hello"), freshness: nil, address: nil), via: client)

        let version = await store.focusLayouts[tag]?.paneContentVersion["a"] ?? 0
        let unreadInRoot0 = await store.focusRegionStates[tag]?.isUnread(
            paneId: "a", regionPath: "root.0", contentVersion: version)
        XCTAssertEqual(unreadInRoot0, false, "a push to the pane already frontmost in its region must never read unread")
    }

    func testTheCompactRegionKeepsW5sFrontmostAndUnreadBehaviourAlongsideRegularWidthRegions() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()
        let compact = FocusRegionState.compactRegion

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: "d"), via: client)

        let compactFrontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: compact, available: ["a", "b", "c", "d"], fallback: "a")
        XCTAssertEqual(
            compactFrontmost, "d",
            "the compact strip's frontmost must still follow focused_pane exactly as W5 required, even though regular-width regions now also exist")

        await deliver(
            .paneContent(tag: tag, paneId: "b", content: .text("hello"), freshness: nil, address: nil), via: client)
        let version = await store.focusLayouts[tag]?.paneContentVersion["b"] ?? 0
        let unreadInCompact = await store.focusRegionStates[tag]?.isUnread(
            paneId: "b", regionPath: compact, contentVersion: version)
        XCTAssertEqual(
            unreadInCompact, true,
            "the compact strip must remain correct while the iPad is landscape, because it is what appears the instant it rotates")
    }

    func testSelectPaneInARegularWidthRegionAlsoUpdatesTheCompactRegionWithoutDisturbingASiblingRegion() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()
        let compact = FocusRegionState.compactRegion

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)

        // Give "root.0" a known, non-default frontmost so "unmoved" below is real.
        await store.selectPane(tag: tag, regionPath: "root.0", paneId: "b")
        // Move "root.1" away from its default too, so selecting "c" next is a genuine move.
        await store.selectPane(tag: tag, regionPath: "root.1", paneId: "d")

        await store.selectPane(tag: tag, regionPath: "root.1", paneId: "c")

        let root1Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.1", available: ["c", "d"], fallback: "d")
        XCTAssertEqual(root1Frontmost, "c", "selecting \"c\" must make it frontmost in \"root.1\"")

        let compactFrontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: compact, available: ["a", "b", "c", "d"], fallback: "a")
        XCTAssertEqual(
            compactFrontmost, "c",
            "selecting a pane at regular width must also bridge into the compact region, so rotating to portrait shows the surface the operator was actually reading")

        let root0Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.0", available: ["a", "b"], fallback: "a")
        XCTAssertEqual(root0Frontmost, "b", "selecting a pane in \"root.1\" must not disturb \"root.0\"'s own frontmost")
    }

    func testAPaneContentPushArrivingBeforeAnyFocusLayoutStillRecordsUnreadUnderTheCompactRegion() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"

        // No .focusLayout has been delivered for this tag yet, so the
        // daemon's tree is still FocusLayoutModel.initial and
        // LayoutRegions.hostingPaths(of:in:) cannot place "x" anywhere —
        // this is the W5-preservation guard: the compact region must still
        // be recorded regardless.
        await deliver(
            .paneContent(tag: tag, paneId: "x", content: .text("hello"), freshness: nil, address: nil), via: client)

        let version = await store.focusLayouts[tag]?.paneContentVersion["x"] ?? 0
        let unreadInCompact = await store.focusRegionStates[tag]?.isUnread(
            paneId: "x", regionPath: FocusRegionState.compactRegion, contentVersion: version)
        XCTAssertEqual(
            unreadInCompact, true,
            "a push arriving before any focus_layout must still register unread under the compact region, same as W5")
    }

    func testAFocusLayoutThatDropsARegionDiscardsThatRegionsFrontmostAndUnreadState() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        await store.selectPane(tag: tag, regionPath: "root.1", paneId: "d")
        await deliver(
            .paneContent(tag: tag, paneId: "c", content: .text("hello"), freshness: nil, address: nil), via: client)

        let version = await store.focusLayouts[tag]?.paneContentVersion["c"] ?? 0
        let unreadBefore = await store.focusRegionStates[tag]?.isUnread(
            paneId: "c", regionPath: "root.1", contentVersion: version)
        XCTAssertEqual(
            unreadBefore, true,
            "sanity check: \"c\" must be recorded unread in \"root.1\" before that region is ever dropped")

        // Collapse to a single tabs node at root — "root.1", "c", and "d" no longer exist anywhere in the tree.
        let collapsed = PaneTree.tabs(children: [.leaf(paneId: "a"), .leaf(paneId: "b")], labels: ["A", "B"], active: 0)
        await deliver(.focusLayout(tag: tag, tree: collapsed, focusedPane: nil), via: client)

        let unreadAfter = await store.focusRegionStates[tag]?.isUnread(
            paneId: "c", regionPath: "root.1", contentVersion: version)
        XCTAssertEqual(
            unreadAfter, false,
            "state recorded for a region the new tree drops entirely must be discarded, not merely unreachable")

        let root1FrontmostAfter = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.1", available: ["c", "d"], fallback: "c")
        XCTAssertEqual(
            root1FrontmostAfter, "c",
            "\"root.1\"'s recorded frontmost (\"d\") must be discarded, not resurrected if the same path ever reappears")
    }

    func testResendingTheSameTreeNeverFightsTheOperatorsPerRegionTabChoiceAtRegularWidth() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "focus1"
        let tree = twoRegionTree()

        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)
        await store.selectPane(tag: tag, regionPath: "root.0", paneId: "b")

        // Byte-identical tree, no focused_pane — a content-only republish.
        // The tree's own `active` (index 0) still points at "a", exactly as
        // it did before "b" was tapped.
        await deliver(.focusLayout(tag: tag, tree: tree, focusedPane: nil), via: client)

        let root0Frontmost = await store.focusRegionStates[tag]?.frontmostPane(
            for: "root.0", available: ["a", "b"], fallback: "a")
        XCTAssertEqual(
            root0Frontmost, "b",
            "a content-only republish must never fight the operator's own tab choice — true at regular width, in each region, same as W5's compact rule")
    }
}

// MARK: - DaemonStoreActivityTests

/// Verifies `DaemonStore`'s handling of the three ambient-activity broadcasts
/// (`.activity` / `.activitySnapshot` / `.activityHealth`) — per-focus
/// attribution (including the unattributed bucket, never dropped), snapshot
/// replacement scoped to one tag, the D8 rate-limited gap-triggered
/// resnapshot request, and daemon-wide health storage. Same construction
/// technique as `DaemonStoreTests` above: a real `NetworkClient` that never
/// calls `start()` (so no socket ever opens), messages pushed directly
/// through its public `messages` subject, and a short sleep after each send
/// to let `DaemonStore`'s `.receive(on: RunLoop.main)` pipeline flush.
final class DaemonStoreActivityTests: XCTestCase {

    private func deliver(_ msg: ServerMsg, via client: NetworkClient) async {
        await client.messages.send(msg)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// `ActivityEvent` has no hand-written initializer — this uses the
    /// compiler-synthesized memberwise init, matching the real field list:
    /// ts, agent, kind, summary, focusTag, sessionId, agentId, agentType,
    /// parentAgentId, toolName, toolUseId, cwd, seq.
    private func makeEvent(
        agent: String = "perri",
        kind: String = "tool_use",
        summary: String = "reading a file",
        focusTag: String? = "perri",
        agentId: String? = nil,
        seq: UInt64? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            ts: Date(), agent: agent, kind: kind, summary: summary,
            focusTag: focusTag, sessionId: nil,
            agentId: agentId, agentType: nil, parentAgentId: nil,
            toolName: nil, toolUseId: nil, cwd: nil, seq: seq)
    }

    // MARK: - Per-focus attribution

    func testActivityEventWithAFocusTagLandsUnderThatTagsActivityModelOnly() async throws {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(.activity(makeEvent(summary: "perri's event", focusTag: "perri")), via: client)

        let perriMain = await store.activityModels["perri"]?.mainStream
        XCTAssertEqual(perriMain?.events.map(\.summary), ["perri's event"])

        let fredModel = await store.activityModels["fred"]
        XCTAssertTrue(
            fredModel == nil || (fredModel?.mainStream?.events.contains { $0.summary == "perri's event" } != true),
            "an event tagged for 'perri' must never appear under a different focus's model"
        )
    }

    // MARK: - Cross-focus isolation

    func testActivityEventWithADifferentFocusTagNeverAppearsUnderAnUnrelatedTag() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(.activity(makeEvent(summary: "fred's event", focusTag: "fred")), via: client)

        let perriMain = await store.activityModels["perri"]?.mainStream
        XCTAssertFalse(
            perriMain?.events.contains { $0.summary == "fred's event" } ?? false,
            "an event tagged for 'fred' must never appear under 'perri'"
        )
    }

    // MARK: - Unattributed events are reachable, not dropped

    func testActivityEventWithNoFocusTagLandsUnderTheUnattributedKey() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(.activity(makeEvent(summary: "mystery event", focusTag: nil)), via: client)

        let unattributed = await store.activityModels[DaemonStore.unattributedActivityKey]?.mainStream
        XCTAssertEqual(unattributed?.events.map(\.summary), ["mystery event"],
                        "an event the daemon could not attribute must still be reachable, not silently dropped")
    }

    // MARK: - Snapshot replaces one tag wholesale, leaves others untouched

    func testActivitySnapshotReplacesOnlyItsOwnTagsModelLeavingOtherTagsUntouched() async throws {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        // Live event for tag "a".
        await deliver(.activity(makeEvent(summary: "a's live event", focusTag: "a")), via: client)
        // Separately-populated tag "b".
        await deliver(.activity(makeEvent(summary: "b's event", focusTag: "b")), via: client)

        // A snapshot for "a" with entirely different content.
        let snapshotEvent = makeEvent(summary: "a's snapshot event", focusTag: "a")
        let snapshotStream = ActivityStreamWireFixture.make(events: [snapshotEvent], finished: false)
        await deliver(.activitySnapshot(tag: "a", streams: [snapshotStream]), via: client)

        let aMain = await store.activityModels["a"]?.mainStream
        XCTAssertEqual(aMain?.events.map(\.summary), ["a's snapshot event"],
                        "a's model must reflect the snapshot's content, not the earlier live event")

        let bMain = await store.activityModels["b"]?.mainStream
        XCTAssertEqual(bMain?.events.map(\.summary), ["b's event"],
                        "tag 'b' must be untouched by a snapshot delivered for tag 'a'")
    }

    // MARK: - Gap-triggered resnapshot request, rate-limited to one outstanding per tag (D8)

    func testAGapTriggersExactlyOneOutstandingSnapshotRequestPerTagUntilTheSnapshotArrives() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let tag = "gapper"

        // seq 1 then seq 5 — a gap (2,3,4 skipped) on tag "gapper"'s main stream.
        await deliver(.activity(makeEvent(focusTag: tag, seq: 1)), via: client)
        await deliver(.activity(makeEvent(focusTag: tag, seq: 5)), via: client)

        var pending = await store.pendingActivitySnapshotRequests
        var counts  = await store.activitySnapshotRequestCount
        XCTAssertTrue(pending.contains(tag), "a detected gap must mark the tag as having an outstanding snapshot request")
        XCTAssertEqual(counts[tag], 1, "exactly one snapshot request must be issued for the first gap")

        // A second gap on the same tag while the request is still outstanding
        // must NOT trigger a second send (D8 rate limit).
        await deliver(.activity(makeEvent(focusTag: tag, seq: 10)), via: client)

        counts = await store.activitySnapshotRequestCount
        XCTAssertEqual(counts[tag], 1, "a second gap while a request is already outstanding must not issue another")

        // The snapshot arrives, clearing the outstanding-request marker for this tag.
        await deliver(.activitySnapshot(tag: tag, streams: []), via: client)

        pending = await store.pendingActivitySnapshotRequests
        XCTAssertFalse(pending.contains(tag), "an arriving snapshot must clear the tag's outstanding-request marker")

        // A fresh baseline, then a fresh gap after the snapshot must be free to
        // trigger a second request.
        await deliver(.activity(makeEvent(focusTag: tag, seq: 1)), via: client)
        await deliver(.activity(makeEvent(focusTag: tag, seq: 5)), via: client)

        counts = await store.activitySnapshotRequestCount
        XCTAssertEqual(counts[tag], 2, "a new gap after the outstanding request cleared must issue a second request")
    }

    // MARK: - Health is stored once, daemon-wide, with lastEventAt retained

    func testActivityHealthIsStoredDaemonWideIncludingLastEventAt() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let lastEventAt = Date(timeIntervalSince1970: 1_800_000_000)

        await deliver(
            .activityHealth(ingesting: false, reason: "socket closed", lastEventAt: lastEventAt, hookInstalled: true),
            via: client
        )

        let health = await store.activityHealth
        XCTAssertEqual(health.ingesting, false)
        XCTAssertEqual(health.reason, "socket closed")
        XCTAssertEqual(health.hookInstalled, true)
        XCTAssertEqual(health.lastEventAt, lastEventAt,
                        "lastEventAt must be retained (D2) — unlike macOS's AppStore, this wedge keeps it")
    }

    // MARK: - Disconnect clears activity state

    /// `NetworkClient.connected` is `@Published public private(set)`, so test
    /// code outside `NetworkClient.swift` cannot assign `client.connected =
    /// false` directly, and calling `client.start()` would open a real
    /// socket — not acceptable in this suite. The only public, non-socket-
    /// opening seam that re-drives `DaemonStore`'s "not connected" handling
    /// is `client.stop()`: it unconditionally sets `connected = false`, and
    /// `@Published` republishes on every assignment regardless of whether
    /// the value actually changed, so this exercises the exact
    /// `$connected`-driven clearing branch in `DaemonStore.bind()` — just not
    /// a genuine "was connected, then disconnected" transition, since we
    /// never called `start()` to begin with. This is the strongest test the
    /// current `NetworkClient` API surface allows; if `connected` ever grows
    /// a test-only setter, this test should be upgraded to drive a real
    /// true-to-false transition.
    func testStoppingTheClientClearsActivityState() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(.activity(makeEvent(summary: "will be cleared", focusTag: "perri")), via: client)
        let beforeStop = await store.activityModels["perri"]?.mainStream?.events.count
        XCTAssertEqual(beforeStop, 1, "sanity check: the event must be stored before we stop the client")

        await client.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let afterStop = await store.activityModels
        XCTAssertTrue(afterStop.isEmpty || afterStop["perri"]?.mainStream == nil,
                       "activity state must be cleared on disconnect, same as sessions/focuses/mother jobs")
    }
}

/// Tiny helper for constructing `ActivityStreamWire` fixtures in tests.
/// `ActivityStreamWire` has no hand-written initializer either, so this uses
/// its compiler-synthesized memberwise init directly.
private enum ActivityStreamWireFixture {
    static func make(
        agentId: String? = nil,
        agentType: String? = nil,
        parentAgentId: String? = nil,
        events: [ActivityEvent],
        finished: Bool
    ) -> ActivityStreamWire {
        ActivityStreamWire(
            agentId: agentId, agentType: agentType, parentAgentId: parentAgentId,
            events: events, finished: finished)
    }
}
