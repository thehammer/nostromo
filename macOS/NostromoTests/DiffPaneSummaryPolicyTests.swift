import XCTest

// DiffPaneSummaryPolicy is compiled into this target directly (logic test —
// no host app, no window), same as RatioPersistencePolicyTests. `PaneTree`
// and `PaneContentWire` are macOS-local types declared in Models.swift and
// are already compiled into this target too (see PaneContentWireEqualityTests),
// so no `@testable import` is needed here either.

// MARK: - DiffPaneSummaryPolicyTests

/// Behavioural tests for `DiffPaneSummaryPolicy.shouldWriteSummary`
/// (fix-appstore-phantom-diff-pane).
///
/// `AppStore.pushDetailToDiffPane` used to write a PR summary straight into
/// `focusLayouts["perri"].paneContent["diff"]` with no regard for whether the
/// active `perri` layout actually has a pane named `"diff"`. In
/// `perri-curated` it never does — that layout's detail panes are dynamically
/// created `detail.0` / `detail.1` leaves — so the write invented a pane id
/// the daemon never sent, and the UI logged an `.error` MISS line about it
/// forever. `shouldWriteSummary` is the yes/no decision pulled out of that
/// write into a pure, dependency-free policy so this exact regression is
/// enforceable by a test instead of by re-reading the call site and hoping
/// nobody reintroduces the blind write.
final class DiffPaneSummaryPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors the real `perri-curated` layout (`queue` + `repl` declared up
    /// front) plus a detail region the placement engine creates on the first
    /// `nostromo.show` that needs one — a `.tabs` region holding two PR tabs,
    /// `detail.0` and `detail.1`. Deliberately has NO leaf named `diff`
    /// anywhere: that absence is the entire point of `perri-curated` (see
    /// `src/mcp/layouts/perri-curated.yaml`'s description) and is exactly
    /// what used to get silently violated by the phantom write.
    private func curatedTree() -> PaneTree {
        .split(
            direction: .vertical,
            children: [
                .split(
                    direction: .horizontal,
                    children: [
                        .leaf(paneId: "queue"),
                        .tabs(
                            children: [.leaf(paneId: "detail.0"), .leaf(paneId: "detail.1")],
                            labels: ["PR #1", "PR #2"],
                            active: 0
                        ),
                    ],
                    ratios: [0.5, 0.5]
                ),
                .leaf(paneId: "repl"),
            ],
            ratios: [0.6, 0.4]
        )
    }

    /// Mirrors the real `perri-standard` layout (`src/mcp/layouts/perri-standard.yaml`):
    /// a fixed `diff` pane declared up front, alongside `queue` and `repl`.
    /// This is the fallback layout for an agent still driving the raw pane
    /// tools, and the one shape where the old hard-coded `"diff"` write was
    /// actually correct.
    private func standardTree() -> PaneTree {
        .split(
            direction: .vertical,
            children: [
                .split(
                    direction: .horizontal,
                    children: [.leaf(paneId: "queue"), .leaf(paneId: "diff")],
                    ratios: [0.5, 0.5]
                ),
                .leaf(paneId: "repl"),
            ],
            ratios: [0.6, 0.4]
        )
    }

    // MARK: - 1. The regression case: perri-curated has no "diff" pane

    func testCuratedLayoutWithNoDiffLeafAndNoExistingContentRefusesTheWrite() {
        // This is the actual bug this fix closes: perri-curated's paneIds are
        // exactly ["queue", "detail.0", "detail.1", "repl"] — "diff" is not
        // among them, so writing to paneContent["diff"] invents a pane id the
        // daemon never sent, and the UI's MISS logging fires an .error line
        // about it forever. The membership check must refuse here.
        XCTAssertFalse(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: curatedTree(), existing: nil),
            """
            perri-curated has no pane literally named "diff" (its detail panes are \
            detail.0/detail.1) — writing a PR summary into paneContent["diff"] here is \
            exactly the phantom-diff-pane regression this policy exists to close. \
            shouldWriteSummary must return false so AppStore never fabricates this pane id.
            """
        )
    }

    // MARK: - 2. Ownership must not override a membership refusal

    func testCuratedLayoutWithStaleExistingTextStillRefusesTheWrite() {
        // Even though `.text(...)` is exactly the shape the ownership arm
        // would happily overwrite, the membership arm must refuse first:
        // there is still no "diff" pane in this tree to write into, and a
        // stale leftover value under a phantom key does not make writing to
        // that key legitimate.
        XCTAssertFalse(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: curatedTree(), existing: .text("stale summary")),
            """
            the ownership check (existing is nil or .text) must never override a membership \
            refusal — perri-curated still has no "diff" pane regardless of what phantom value \
            happens to already be sitting under that key.
            """
        )
    }

    // MARK: - 3. First paint on perri-standard still works

    func testStandardLayoutWithNoExistingContentAllowsTheWrite() {
        XCTAssertTrue(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: standardTree(), existing: nil),
            """
            perri-standard declares a real "diff" pane up front, and there is nothing there yet \
            (existing: nil) — this is the ordinary first-paint case and must still be allowed, \
            or PR summaries would stop appearing entirely on the layout that has always supported them.
            """
        )
    }

    // MARK: - 4. Refresh on subsequent PR loads still works

    func testStandardLayoutWithExistingTextSummaryAllowsTheWrite() {
        XCTAssertTrue(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: standardTree(), existing: .text("previous summary")),
            """
            a previously-written text summary is exactly the shape this function has always \
            owned — refusing to refresh it would leave the diff pane stuck showing the PREVIOUS \
            PR's summary every time the operator selects a new PR from the queue.
            """
        )
    }

    // MARK: - 5 & 6. Never clobber daemon-structured content (pre-existing W2 guarantee)

    func testStandardLayoutWithExistingCodeContentRefusesTheWrite() {
        // Pins the pre-existing W2 "never clobber daemon-structured content"
        // guarantee: once the daemon's perri.get_pr_diff source has pushed a
        // real .code/.diff payload into this pane, this function must never
        // stomp it back to a plain-text summary — that would flicker the
        // pane back to text within milliseconds of the structured content
        // arriving, on every PR load.
        XCTAssertFalse(
            DiffPaneSummaryPolicy.shouldWriteSummary(
                tree: standardTree(),
                existing: .code(CodePayload(path: "", revision: "", firstLine: 1, text: ""))
            ),
            """
            once the daemon is driving this pane with structured .code content, \
            shouldWriteSummary must refuse — .code and .diff are not among the states this \
            function has ever owned (only nil and .text are), and clobbering daemon-structured \
            content is the exact W2 regression this guard exists to prevent.
            """
        )
    }

    func testStandardLayoutWithExistingDiffContentRefusesTheWrite() {
        // Sibling of the .code case above, same W2 guarantee: a real
        // structured .diff payload from the daemon must never be clobbered
        // by this function's plain-text summary either.
        XCTAssertFalse(
            DiffPaneSummaryPolicy.shouldWriteSummary(
                tree: standardTree(),
                existing: .diff(DiffPayload(repo: "acme/web", number: 42, files: []))
            ),
            """
            once the daemon is driving this pane with structured .diff content, \
            shouldWriteSummary must refuse — .code and .diff are not among the states this \
            function has ever owned (only nil and .text are), and clobbering daemon-structured \
            content is the exact W2 regression this guard exists to prevent.
            """
        )
    }

    // MARK: - 7. tree: nil is deliberately permissive — not a bug, don't tighten it

    func testNoTreeYetAndNoExistingContentAllowsTheWrite() {
        // Deliberate, not a bug: `tree: nil` means no FocusLayoutModel has
        // been received yet for the "perri" focus. The pre-fix code fabricated
        // FocusLayoutModel.initial (a bare repl leaf, via
        // `focusLayouts["perri"] ?? FocusLayoutModel.initial`) and wrote anyway
        // in this situation. Refusing here would be a behavior change on a
        // path this fix isn't targeting — the phantom-pane bug is specifically
        // about a KNOWN tree that lacks a "diff" leaf, not about the
        // not-yet-known-at-all case. A future reader must not "tighten" this
        // arm to also require a tree to exist.
        XCTAssertTrue(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: nil, existing: nil),
            """
            tree: nil (no FocusLayoutModel received yet for "perri") must allow the write, \
            matching the pre-fix fabricate-FocusLayoutModel.initial-and-write-anyway behavior — \
            this is a deliberately out-of-scope path for this fix, not a gap to close.
            """
        )
    }

    // MARK: - 8. Membership uses full depth-first paneIds, not just top-level children

    func testDiffLeafNestedInsideATabsRegionStillAllowsTheWrite() {
        // "diff" here is not a direct child of the top-level .split — it's
        // nested two levels down, inside a .tabs region alongside another
        // pane. PaneTree.paneIds is depth-first across BOTH .split and .tabs
        // children, and the membership check must use that full traversal —
        // a shallower check that only looked at top-level split children
        // would wrongly refuse this legitimate case.
        let tree = PaneTree.split(
            direction: .horizontal,
            children: [
                .leaf(paneId: "queue"),
                .tabs(
                    children: [.leaf(paneId: "diff"), .leaf(paneId: "detail.0")],
                    labels: ["Diff", "PR #1"],
                    active: 0
                ),
            ],
            ratios: [0.5, 0.5]
        )
        XCTAssertTrue(
            DiffPaneSummaryPolicy.shouldWriteSummary(tree: tree, existing: nil),
            """
            "diff" is nested inside a .tabs region rather than being a top-level split child — \
            the membership check must consult PaneTree.paneIds' full depth-first traversal \
            (which recurses through both .split and .tabs children), not just immediate children, \
            or this legitimate case would be wrongly refused.
            """
        )
    }
}
