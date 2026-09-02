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

// MARK: - DaemonStoreDecisionTests

/// Verifies `DaemonStore`'s handling of `decision_request` / `decision_resolved`
/// broadcasts (W3 — iOS decision answering): FIFO enqueue into
/// `pendingDecisions`, de-duplication of a re-broadcast for the same
/// `requestId`, dropping a request for an id that already has a claimed
/// resolution, `answerDecision(requestId:choiceId:)` popping the matching
/// entry, a resolution silently removing a still-queued entry, resolution
/// mapping into `decisionStore` (`"answered"` + a `choiceId` → `.choice`,
/// `"dismissed"` → `.dismissed`, anything else — `"timeout"`, `"cancelled"`
/// — → `.resolvedElsewhere`), and `pendingDecisions` clearing on disconnect.
///
/// Since `ServerMsg.decisionRequest`/`.decisionResolved` wire decoding is
/// covered separately in `DecisionWireTests.swift`, these tests construct the
/// `ServerMsg` enum cases directly in Swift and push them through
/// `client.messages`, exactly like `DaemonStoreActivityTests`'s `.activity`
/// tests above — no JSON involved at this layer. Same construction technique
/// as `DaemonStoreTests`/`DaemonStoreActivityTests`: a real `NetworkClient`
/// that never calls `start()` (so no socket ever opens), and a short sleep
/// after each send to let `DaemonStore`'s `.receive(on: RunLoop.main)`
/// pipeline flush.
///
/// `store.decisionStore` is read from these (non-isolated) `async` test
/// methods as `await store.decisionStore.resolution(for:)` — reading the
/// `@MainActor`-isolated `decisionStore` property requires the `await`, but
/// the returned `DecisionStore` is a plain object, so the trailing
/// `.resolution(for:)` call itself is NOT guaranteed to execute on the main
/// thread just because the property fetch was awaited — it runs back on the
/// calling (non-isolated) context. `DecisionStore` asserts
/// `Thread.isMainThread` internally, so that pattern crashes. Wrapping the
/// whole expression in `await MainActor.run { ... }` forces both the
/// property read and the method call onto the main actor's executor.
final class DaemonStoreDecisionTests: XCTestCase {

    private func deliver(_ msg: ServerMsg, via client: NetworkClient) async {
        await client.messages.send(msg)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func makeChoices() -> [DecisionChoice] {
        [DecisionChoice(id: "yes", label: "Yes", detail: nil)]
    }

    // MARK: - A single decision_request enqueues exactly one matching entry

    func testSingleDecisionRequestEnqueuesExactlyOneMatchingEntry() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let choices = makeChoices()

        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "Continue?",
                              detail: "some detail", choices: choices, contextPaneId: "pane-1"),
            via: client
        )

        let pending = await store.pendingDecisions
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.tag, "fred")
        XCTAssertEqual(pending.first?.requestId, "req-1")
        XCTAssertEqual(pending.first?.prompt, "Continue?")
        XCTAssertEqual(pending.first?.detail, "some detail")
        XCTAssertEqual(pending.first?.choices, choices)
        XCTAssertEqual(pending.first?.contextPaneId, "pane-1")
    }

    // MARK: - A duplicate decision_request for the same id is not enqueued twice

    func testDuplicateDecisionRequestForSameIdIsNotEnqueuedTwice() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let msg = ServerMsg.decisionRequest(
            tag: "fred", requestId: "req-1", prompt: "Continue?",
            detail: nil, choices: makeChoices(), contextPaneId: nil)

        await deliver(msg, via: client)
        await deliver(msg, via: client)

        let pending = await store.pendingDecisions
        XCTAssertEqual(pending.count, 1, "a duplicate re-broadcast for the same requestId must not enqueue a second entry")
    }

    // MARK: - Two decision_requests for different tags preserve arrival order

    func testTwoDecisionRequestsForDifferentTagsPreserveArrivalOrder() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let choices = makeChoices()

        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "First?",
                              detail: nil, choices: choices, contextPaneId: nil),
            via: client
        )
        await deliver(
            .decisionRequest(tag: "perri", requestId: "req-2", prompt: "Second?",
                              detail: nil, choices: choices, contextPaneId: nil),
            via: client
        )

        let pending = await store.pendingDecisions
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].tag, "fred")
        XCTAssertEqual(pending[0].requestId, "req-1")
        XCTAssertEqual(pending[1].tag, "perri")
        XCTAssertEqual(pending[1].requestId, "req-2")
    }

    // MARK: - answerDecision removes the head entry and promotes the next one

    func testAnswerDecisionRemovesHeadEntryAndPromotesTheNextOne() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)
        let choices = makeChoices()

        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "First?",
                              detail: nil, choices: choices, contextPaneId: nil),
            via: client
        )
        await deliver(
            .decisionRequest(tag: "perri", requestId: "req-2", prompt: "Second?",
                              detail: nil, choices: choices, contextPaneId: nil),
            via: client
        )

        await store.answerDecision(requestId: "req-1", choiceId: "yes")

        let pending = await store.pendingDecisions
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].requestId, "req-2", "the second entry must become the new head after the first is answered")
    }

    // MARK: - decision_resolved for a still-queued request removes it silently

    func testDecisionResolvedForAQueuedRequestRemovesItSilently() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "Continue?",
                              detail: nil, choices: makeChoices(), contextPaneId: nil),
            via: client
        )
        await deliver(
            .decisionResolved(tag: "fred", requestId: "req-1", resolution: "dismissed", choiceId: nil),
            via: client
        )

        let pending = await store.pendingDecisions
        XCTAssertTrue(pending.isEmpty, "a resolved decision must be removed from the pending queue, without crashing")
    }

    // MARK: - decision_resolved resolution mapping into decisionStore

    func testDecisionResolvedAnsweredWithChoiceIdRecordsChoiceInDecisionStore() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionResolved(tag: "fred", requestId: "req-1", resolution: "answered", choiceId: "approve"),
            via: client
        )

        let resolution = await MainActor.run { store.decisionStore.resolution(for: "req-1") }
        XCTAssertEqual(resolution, .choice("approve"))
    }

    func testDecisionResolvedDismissedRecordsDismissedInDecisionStore() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionResolved(tag: "fred", requestId: "req-1", resolution: "dismissed", choiceId: nil),
            via: client
        )

        let resolution = await MainActor.run { store.decisionStore.resolution(for: "req-1") }
        XCTAssertEqual(resolution, .dismissed)
    }

    func testDecisionResolvedTimeoutRecordsResolvedElsewhereInDecisionStore() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionResolved(tag: "fred", requestId: "req-1", resolution: "timeout", choiceId: nil),
            via: client
        )

        let resolution = await MainActor.run { store.decisionStore.resolution(for: "req-1") }
        XCTAssertEqual(resolution, .resolvedElsewhere("timeout"))
    }

    // MARK: - A decision_request for an already-resolved id is dropped

    func testDecisionRequestForAnAlreadyResolvedIdIsDropped() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionResolved(tag: "fred", requestId: "req-1", resolution: "timeout", choiceId: nil),
            via: client
        )
        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "Too late?",
                              detail: nil, choices: makeChoices(), contextPaneId: nil),
            via: client
        )

        let pending = await store.pendingDecisions
        XCTAssertTrue(
            pending.isEmpty,
            "a request for an id that already has a claimed resolution must be dropped, never enqueued"
        )
    }

    // MARK: - Disconnect clears pendingDecisions

    /// Same seam as `DaemonStoreActivityTests.testStoppingTheClientClearsActivityState`:
    /// `NetworkClient.connected` has no test-only setter, so `client.stop()`
    /// is the only public way to re-drive `DaemonStore`'s "not connected"
    /// clearing branch without opening a real socket.
    func testDisconnectClearsPendingDecisions() async {
        let client = await NetworkClient()
        let store  = await DaemonStore(client: client)

        await deliver(
            .decisionRequest(tag: "fred", requestId: "req-1", prompt: "Continue?",
                              detail: nil, choices: makeChoices(), contextPaneId: nil),
            via: client
        )
        let beforeStop = await store.pendingDecisions.count
        XCTAssertEqual(beforeStop, 1, "sanity check: the request must be queued before we stop the client")

        await client.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let afterStop = await store.pendingDecisions
        XCTAssertTrue(afterStop.isEmpty, "pendingDecisions must be cleared on disconnect")
    }
}
