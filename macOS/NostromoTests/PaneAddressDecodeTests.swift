import XCTest

// `Anchor`, `Emphasis`, `PaneAddress` are macOS-local types declared in
// Models.swift and compiled into this test target directly (logic test — no
// host app, no `@testable import`), the same idiom as
// `PaneContentWireEqualityTests` / `ScrollDecisionTests`. They intentionally
// shadow NostromoKit's identically-named types within this module — see the
// header comment on Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift.
//
// The mirrored NostromoKit-side coverage for the same decode behaviour lives
// in Shared/NostromoKit/Tests/NostromoKitTests/PaneContentWireTests.swift,
// under "PaneAddress.emphasis decodes element-by-element, not all-or-nothing
// (W3 — detail-region-materialization)".

/// Coverage for `PaneAddress.emphasis` decoding element-by-element instead of
/// all-or-nothing (W3 — detail-region-materialization).
///
/// Before this fix, `PaneAddress`'s decoder read
/// `emphasis = (try? c.decode([Emphasis].self, forKey: .emphasis)) ?? []` —
/// `Emphasis`'s own decoder throws `DecodingError.dataCorruptedError` on an
/// unrecognised `kind`, `Array<Emphasis>`'s decode propagates that throw for
/// the *whole* array, and the outer `try?` swallows it, silently replacing
/// every element — known or not — with `[]`. A daemon shipping one emphasis
/// kind this client understands alongside a newer kind it doesn't made the
/// client render NO emphasis at all, with no log and no way for the operator
/// to tell "the daemon sent nothing" from "the client threw it away".
final class PaneAddressDecodeTests: XCTestCase {

    private func decodeAddress(_ jsonString: String) throws -> PaneAddress {
        try JSONDecoder().decode(PaneAddress.self, from: Data(jsonString.utf8))
    }

    // MARK: - Emphasis decodes element-by-element, not all-or-nothing

    /// The headline regression test. An agent anchors line 531 and asks for an
    /// emphasis band on it (`line_range`, which this client understands), in
    /// the same push as some newer emphasis kind this client build predates.
    /// This test fails against `main`, where `addr.emphasis` comes back `[]`
    /// instead of containing the line_range.
    func testEmphasisArrayKeepsAKnownElementWhenASiblingElementHasAnUnrecognisedKind() throws {
        let json = """
        {
            "emphasis": [
                {"kind": "line_range", "start": 531, "end": 531},
                {"kind": "some_future_kind", "x": 1}
            ]
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertEqual(addr.emphasis, [.lineRange(path: nil, start: 531, end: 531)], """
            an agent anchored line 531 and asked for an emphasis band on it; the daemon also sent a \
            newer emphasis kind this client doesn't recognise yet. The known line_range element must \
            still decode and survive in PaneAddress.emphasis — dropping it because an unrelated sibling \
            element failed to decode is the W3 detail-region-materialization bug: the operator sees a \
            pane that scrolled but has no visible mark, with no way to tell "the daemon sent nothing" \
            from "the client silently discarded what it was sent."
            """)
    }

    /// If every element in the array is unrecognised, the array decodes to `[]` —
    /// same externally-visible result as before the fix — but critically must not
    /// throw out of `PaneAddress.init`, which would propagate through
    /// `ServerMsg.decode`'s own `try?` and discard the whole pane_content message
    /// (content and freshness included), not just the address.
    func testEmphasisArrayOfOnlyUnrecognisedKindsDecodesToEmptyWithoutThrowingOutOfPaneAddressInit() throws {
        let json = """
        {
            "anchor": {"kind": "line", "line": 7},
            "emphasis": [{"kind": "some_future_kind"}],
            "reason": "opened from the queue"
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertEqual(addr.emphasis, [], """
            an emphasis array containing only unrecognised kinds must decode to [], not throw — but \
            (per the test above) that must be because every element genuinely failed to decode, not \
            because one bad element took a good sibling down with it.
            """)
        XCTAssertEqual(addr.anchor, .line(path: nil, line: 7), """
            a malformed emphasis array must not prevent the rest of PaneAddress (its anchor) from \
            decoding — these are decoded independently and a failure in one must be contained to it.
            """)
        XCTAssertEqual(addr.reason, "opened from the queue", """
            a malformed emphasis array must not prevent PaneAddress.reason from decoding either — the \
            whole point of per-element decoding is that a failure is contained to the element that \
            actually failed, not smeared across sibling fields.
            """)
    }

    /// Regression guard: emphasis absent entirely must still decode to `[]` without
    /// throwing — the per-element rewrite must not turn "no emphasis key at all"
    /// into a new failure mode.
    func testEmphasisKeyAbsentEntirelyStillDecodesToEmptyArrayWithoutThrowing() throws {
        let json = """
        {
            "anchor": {"kind": "section", "name": "Overview"},
            "reason": "no emphasis pushed for this pane"
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertEqual(addr.emphasis, [], "an absent \"emphasis\" key must decode to [], the same as before this fix")
        XCTAssertEqual(addr.anchor, .section(name: "Overview"))
        XCTAssertEqual(addr.reason, "no emphasis pushed for this pane")
    }

    /// Regression guard: a fully-valid, multi-element, mixed-kind emphasis array
    /// must still decode every element, in wire order — the per-element rewrite
    /// must not, say, accidentally keep only the first element or reorder them.
    func testFullyValidMultiElementEmphasisArrayKeepsEveryElementInWireOrder() throws {
        let json = """
        {
            "emphasis": [
                {"kind": "line_range", "start": 10, "end": 20},
                {"kind": "comment", "id": "c-9"},
                {"kind": "queue_row", "repo": "acme/web", "number": 7}
            ]
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertEqual(addr.emphasis, [
            .lineRange(path: nil, start: 10, end: 20),
            .comment(id: "c-9"),
            .queueRow(repo: "acme/web", number: 7)
        ], "a fully-valid emphasis array must keep every element, in the order the daemon sent them")
    }

    /// Regression guard: `"emphasis": 7` (present, but not an array at all) must
    /// decode to `[]` without throwing, same as before this fix — the per-element
    /// container decode still has to fail closed on a shape it can't even open an
    /// unkeyed container from.
    func testEmphasisPresentButNotAnArrayDecodesToEmptyArrayWithoutThrowing() throws {
        let json = """
        {
            "emphasis": 7,
            "reason": "malformed shape, not a malformed element"
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertEqual(addr.emphasis, [], "\"emphasis\" being present but not an array must still fail closed to [], not throw")
        XCTAssertEqual(addr.reason, "malformed shape, not a malformed element")
    }

    /// Regression guard, pinning the existing sibling behaviour this fix must not
    /// disturb: a malformed *anchor* (unrecognised kind) drops only the anchor —
    /// emphasis and reason must decode normally alongside it.
    func testMalformedAnchorDropsOnlyTheAnchorLeavingEmphasisAndReasonIntact() throws {
        let json = """
        {
            "anchor": {"kind": "some_future_anchor_kind"},
            "emphasis": [{"kind": "text_range", "start": 0, "end": 5}],
            "reason": "still explains itself"
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertNil(addr.anchor, "an unrecognised anchor kind must drop only the anchor")
        XCTAssertEqual(addr.emphasis, [.textRange(start: 0, end: 5)], "a malformed anchor must not affect emphasis decoding")
        XCTAssertEqual(addr.reason, "still explains itself", "a malformed anchor must not affect reason decoding")
    }

    /// `marks(repo:number:)` must still find a `queue_row` emphasis element sitting
    /// in a partially-decoded array — the row-marking feature (W5) must keep
    /// working on exactly the array shape this fix produces, not just on arrays
    /// that decoded cleanly.
    func testMarksStillFindsAQueueRowEmphasisInAPartiallyDecodedEmphasisArray() throws {
        let json = """
        {
            "emphasis": [
                {"kind": "queue_row", "repo": "acme/web", "number": 7},
                {"kind": "some_future_kind"}
            ]
        }
        """
        let addr = try decodeAddress(json)
        XCTAssertTrue(addr.marks(repo: "acme/web", number: 7), """
            marks(repo:number:) must find the queue_row element even though a sibling element in the \
            same emphasis array failed to decode — the W5 row-marking feature must not go blind just \
            because the daemon also sent an emphasis kind this client doesn't recognise yet.
            """)
        XCTAssertFalse(addr.marks(repo: "acme/web", number: 8), "marks must still be number-specific, not true for any decoded queue_row")
    }
}
