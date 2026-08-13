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
            .paneContent(tag: "focus1", paneId: "pane1", content: .prList(items), freshness: nil),
            via: client
        )
        let storedBefore = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        XCTAssertEqual(storedBefore, .prList(items), "sanity check: pr_list should be stored on first paint")

        // A subsequent .loading update for the same pane must be dropped entirely.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil),
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
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil),
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
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil),
            via: client
        )
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane1", content: .loading, freshness: nil),
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
            .paneContent(tag: "focus1", paneId: "pane1", content: .prList(items), freshness: nil),
            via: client
        )
        // A .loading update for a *different* pane on the same focus is a first
        // paint for that pane and must be stored, without disturbing pane1.
        await deliver(
            .paneContent(tag: "focus1", paneId: "pane2", content: .loading, freshness: nil),
            via: client
        )

        let pane1 = await store.focusLayouts["focus1"]?.paneContent["pane1"]
        let pane2 = await store.focusLayouts["focus1"]?.paneContent["pane2"]
        XCTAssertEqual(pane1, .prList(items), "pane1 must be untouched by pane2's update")
        XCTAssertEqual(pane2, .loading, "pane2 has no prior content, so .loading is stored as first paint")
    }
}
