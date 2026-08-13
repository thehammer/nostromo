import XCTest
import NostromoKit

// `PaneContentWire`, `PaneTree`, `SplitDirection`, `FocusLayoutModel` are
// macOS-local types declared in Models.swift and compiled into this test
// target directly (logic test — no host app, same as PerriModelTests /
// MotherBrokerClientTests). They intentionally shadow NostromoKit's
// identically-named types within this module — see the header comment on
// Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift.
//
// `PrListItemModel` is NOT shadowed locally, so it resolves to
// `NostromoKit.PrListItemModel` here — hence the explicit `import NostromoKit`
// and the fully-qualified `NostromoKit.CiState` below (the macOS module also
// declares its own, unrelated, local `CiState` enum for `PRQueueItem`, so an
// unqualified `CiState` here would resolve to the WRONG type and fail to
// compile against `PrListItemModel.ciState`).
//
// Per-field equality coverage for `PrListItemModel` itself lives in
// Shared/NostromoKit/Tests/NostromoKitTests/PaneContentWireTests.swift, since
// that's the only module where the type is actually declared. This file only
// covers the macOS-local `PaneContentWire`'s own Equatable contract.

// MARK: - PaneContentWireEqualityTests

/// Equality-contract tests for the macOS-local `PaneContentWire` (Models.swift).
/// Mirrors the equivalent NostromoKit suite in `PaneContentWireTests.swift` —
/// the two `PaneContentWire` types are separate, deliberately-duplicated
/// copies; this file exercises only the macOS one.
final class PaneContentWireEqualityTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decode(_ jsonString: String) throws -> PaneContentWire {
        let data = Data(jsonString.utf8)
        return try decoder.decode(PaneContentWire.self, from: data)
    }

    private func makeItem(
        title: String = "feat: auth"
    ) -> PrListItemModel {
        PrListItemModel(
            repo: "acme/web",
            number: 42,
            title: title,
            author: "alice",
            bucket: "requested",
            ciState: NostromoKit.CiState.success,
            newActivity: true,
            url: "https://github.com/acme/web/pull/42",
            headSha: "abc123"
        )
    }

    // MARK: - .text

    func testTextCasesWithSameStringAreEqual() {
        XCTAssertEqual(PaneContentWire.text("hello"), PaneContentWire.text("hello"))
    }

    func testTextCasesWithDifferentStringsAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.text("goodbye"))
    }

    // MARK: - .loading

    func testLoadingCasesAreAlwaysEqual() {
        XCTAssertEqual(PaneContentWire.loading, PaneContentWire.loading)
    }

    // MARK: - .error

    func testErrorCasesWithSameMessageAreEqual() {
        XCTAssertEqual(PaneContentWire.error("boom"), PaneContentWire.error("boom"))
    }

    func testErrorCasesWithDifferentMessagesAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.error("kaboom"))
    }

    // MARK: - .prList

    func testPrListCasesWithIdenticalItemArraysAreEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem()])
        XCTAssertEqual(lhs, rhs)
    }

    func testPrListCasesWithADifferingItemAreNotEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem(title: "fix: something else")])
        XCTAssertNotEqual(lhs, rhs)
    }

    // MARK: - .jsonSnapshot (structural, via NSObject bridging)
    //
    // `.jsonSnapshot` carries `Any`, so `==` bridges the payload to `NSObject`
    // and compares with `isEqual` — structurally equal payloads (even from two
    // independent decodes) must compare equal, and `x == x` must always hold,
    // per `Equatable`'s reflexivity requirement.
    //
    // NOTE: the macOS-local `AnyDecodable` (Models.swift) has no keyed-container
    // decode branch — it can only produce String/Bool/Int/Double/[Any], never
    // [String: Any]. That's a real, pre-existing, out-of-scope bug, and it means
    // a nested-*object* payload can't be exercised here (it collapses to an
    // empty string). Nesting is exercised via an array-of-arrays instead, which
    // the macOS decoder can build via its unkeyed-container branch.

    func testJsonSnapshotIsReflexive() throws {
        let value = try decode("""
        {"kind": "json_snapshot", "value": [[1, 2], [3, 4]]}
        """)
        XCTAssertEqual(
            value, value,
            "x == x must hold for .jsonSnapshot — Equatable's reflexivity requirement"
        )
    }

    func testJsonSnapshotCasesWithIdenticalPayloadsAreEqual() throws {
        // An object `value` would collapse to an empty string via the macOS
        // decoder's missing keyed-container branch (see note above) — using an
        // array here keeps this a meaningful (non-trivial) equality check.
        let json = """
        {"kind": "json_snapshot", "value": [1, 2, 3]}
        """
        let lhs = try decode(json)
        let rhs = try decode(json)
        XCTAssertEqual(
            lhs, rhs,
            ".jsonSnapshot must compare equal for byte-identical payloads, even though each " +
            "side was decoded independently"
        )
    }

    func testJsonSnapshotCasesDifferingInANestedArrayValueAreNotEqual() throws {
        let lhs = try decode("""
        {"kind": "json_snapshot", "value": [[1, 2], [3, 4]]}
        """)
        let rhs = try decode("""
        {"kind": "json_snapshot", "value": [[1, 2], [3, 5]]}
        """)
        XCTAssertNotEqual(
            lhs, rhs,
            ".jsonSnapshot must detect a difference nested inside an array-of-arrays payload"
        )
    }

    // MARK: - .unknown (structural, via NSObject bridging)
    //
    // The macOS `default:` decode branch re-decodes the *whole* top-level
    // object through `AnyDecodable`, which (per the note above) has no
    // keyed-container branch — so every decoded `.unknown` collapses to the
    // same `""` payload regardless of the source JSON. Reflexivity and
    // identical-payload equality still hold meaningfully through the decoder
    // (and are a real regression guard against the old unconditional
    // `return false`); differing-payload detection is exercised via direct
    // case construction instead, since decoding can never produce two
    // different `.unknown` payloads to compare here.

    func testUnknownIsReflexive() throws {
        let value = try decode("""
        {"kind": "future_type_not_yet_known", "some_field": "some_value"}
        """)
        XCTAssertEqual(
            value, value,
            "x == x must hold for .unknown — Equatable's reflexivity requirement"
        )
    }

    func testUnknownCasesWithIdenticalPayloadsAreEqual() throws {
        let json = """
        {"kind": "future_type_not_yet_known", "some_field": "some_value"}
        """
        let lhs = try decode(json)
        let rhs = try decode(json)
        XCTAssertEqual(
            lhs, rhs,
            ".unknown must compare equal for byte-identical payloads, even though each side " +
            "was decoded independently"
        )
    }

    func testUnknownCasesWithDifferingPayloadsAreNotEqual() {
        let lhs = PaneContentWire.unknown(["future_field": "a"])
        let rhs = PaneContentWire.unknown(["future_field": "b"])
        XCTAssertNotEqual(lhs, rhs, ".unknown must detect a difference in its payload")
    }

    // MARK: - Cross-case inequality

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.loading)
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.text("boom"))
        XCTAssertNotEqual(PaneContentWire.prList([makeItem()]), PaneContentWire.loading)
    }
}
