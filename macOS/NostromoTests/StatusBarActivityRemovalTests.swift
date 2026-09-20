import XCTest

/// A fitness function, not a behavioural test — same spirit as
/// `ImageDecodePolicyTests`/`TurnInteractionWiringTests`. `StatusBarView` is
/// not part of this logic-test target, so it is read as text.
///
/// This is the D9 regression guard: the ambient-activity ticker
/// (`ActivityTickerView`, see `ActivityTickerWiringTests`) replaces
/// `StatusBarView`'s activity segment — `buildLeft()`'s
/// `store.recentActivity.last` branch and the `Publishers.CombineLatest4`
/// subscription leg that reads `store.$recentActivity` — so the same
/// information is not shown in two places at once.
///
/// This test FAILS against the current, unmodified `StatusBarView.swift`.
/// That is expected: it is the regression guard Cody's D9 change must
/// satisfy, and it goes green the moment `recentActivity` is fully removed
/// from that file.
final class StatusBarActivityRemovalTests: XCTestCase {

    func testStatusBarViewNoLongerReferencesRecentActivity() throws {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/StatusBarActivityRemovalTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/UI/StatusBarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(source.contains("recentActivity"), """
            StatusBarView.swift must no longer reference recentActivity — the ambient \
            activity ticker (ActivityTickerView) is now the single place that shows \
            this information. Remove buildLeft()'s `store.recentActivity.last` branch \
            and drop `store.$recentActivity` from the CombineLatest4 subscription (it \
            can shrink to CombineLatest3, or whatever subset of signals still drives \
            StatusBarView's other segments).
            """)
    }
}
