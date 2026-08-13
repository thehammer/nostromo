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

    // MARK: - .jsonSnapshot (conservative "always changed")

    func testJsonSnapshotCasesWithIdenticalPayloadsAreNeverEqual() {
        let payload: [String: Any] = ["x": 1]
        let lhs = PaneContentWire.jsonSnapshot(payload)
        let rhs = PaneContentWire.jsonSnapshot(payload)
        XCTAssertNotEqual(
            lhs, rhs,
            ".jsonSnapshot must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    // MARK: - .unknown (conservative "always changed")

    func testUnknownCasesWithIdenticalPayloadsAreNeverEqual() {
        let payload: [String: Any] = ["future_field": "value"]
        let lhs = PaneContentWire.unknown(payload)
        let rhs = PaneContentWire.unknown(payload)
        XCTAssertNotEqual(
            lhs, rhs,
            ".unknown must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    // MARK: - Cross-case inequality

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.loading)
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.text("boom"))
        XCTAssertNotEqual(PaneContentWire.prList([makeItem()]), PaneContentWire.loading)
    }
}
