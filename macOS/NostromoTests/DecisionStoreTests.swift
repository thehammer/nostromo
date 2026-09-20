import XCTest
import AppKit

// DecisionStore, DecisionAnswerRecord are compiled into this target directly
// (logic test — no host app, no `@testable import`), matching the convention
// documented in TurnInteractionTests.swift.

// MARK: - DecisionStoreTests

/// `DecisionStore` is the app-wide ("outside any single window") source of
/// truth for a daemon-driven decision request's resolution — the fix for the
/// reported bug (a decision sheet presented on every open window, answerable
/// twice with contradictory choices). Two independent claims are tracked
/// here:
///
/// - `claimAnswer`/`resolution(for:)` — has this request already been
///   resolved (by ANY window), and what was the resolution? First writer
///   wins; every later attempt is told "no, you weren't the one" and must
///   not disturb the recorded resolution.
/// - `claimPresentation`/`releasePresentation` — is some window CURRENTLY
///   presenting a sheet for this request right now? This is what makes
///   presentation happen exactly once app-wide, independent of whether the
///   request has been answered yet.
final class DecisionStoreTests: XCTestCase {

    // MARK: 1. A fresh store has nothing resolved

    func testFreshStoreHasNoResolutionForAnyRequestId() {
        let store = DecisionStore()
        XCTAssertNil(store.resolution(for: "r1"))
        XCTAssertNil(store.resolution(for: "anything-else"))
    }

    // MARK: 2. claimAnswer for a fresh id succeeds and records a choice

    func testClaimAnswerForAFreshIdWithAChoiceSucceedsAndIsReadableAfterward() {
        let store = DecisionStore()
        let claimed = store.claimAnswer(requestId: "r1", record: .choice("approve"))

        XCTAssertTrue(claimed, "the first claim for a fresh request id must succeed")
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"))
    }

    // MARK: 3. claimAnswer for a fresh id succeeds and records a dismissal

    func testClaimAnswerForAFreshIdWithADismissalSucceedsAndIsReadableAfterward() {
        let store = DecisionStore()
        let claimed = store.claimAnswer(requestId: "r1", record: .dismissed)

        XCTAssertTrue(claimed, "the first claim for a fresh request id must succeed")
        XCTAssertEqual(store.resolution(for: "r1"), .dismissed)
    }

    // MARK: 4. A second claimAnswer for the same id always loses — regression test for RC3
    // (the client answer-once gate: two windows racing to answer the same
    // request must not both believe they own the answer).

    func testASecondClaimAnswerForTheSameIdAfterAChoiceFailsAndLeavesTheChoiceUntouched() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("approve")))

        let secondClaimed = store.claimAnswer(requestId: "r1", record: .dismissed)

        XCTAssertFalse(secondClaimed, "a second claim for an already-claimed request id must fail")
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"),
                       "the FIRST recorded resolution must stand, untouched by the losing second claim")
    }

    func testASecondClaimAnswerForTheSameIdAfterADismissalFailsAndLeavesTheDismissalUntouched() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .dismissed))

        let secondClaimed = store.claimAnswer(requestId: "r1", record: .choice("approve"))

        XCTAssertFalse(secondClaimed, "a second claim for an already-claimed request id must fail")
        XCTAssertEqual(store.resolution(for: "r1"), .dismissed,
                       "the FIRST recorded resolution must stand, untouched by the losing second claim")
    }

    // MARK: 5. Two different request ids are claimed independently

    func testTwoDifferentRequestIdsAreClaimedIndependently() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("approve")))

        XCTAssertNil(store.resolution(for: "r2"),
                     "claiming r1's answer must not leak into r2's state")

        XCTAssertTrue(store.claimAnswer(requestId: "r2", record: .dismissed))
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"),
                       "claiming r2's answer must not disturb r1's already-recorded state")
        XCTAssertEqual(store.resolution(for: "r2"), .dismissed)
    }

    // MARK: 6. claimPresentation is exactly-once until released — regression test for RC1
    // (exactly-once presentation: only one window may ever have a sheet up
    // for a given request at a time).

    func testClaimPresentationForAFreshIdSucceedsASecondClaimBeforeReleaseFailsAndAfterReleaseSucceedsAgain() {
        let store = DecisionStore()

        XCTAssertTrue(store.claimPresentation(requestId: "r1"),
                     "the first presentation claim for a fresh request id must succeed")
        XCTAssertFalse(store.claimPresentation(requestId: "r1"),
                       "a second presentation claim while the first is still held must fail — this is exactly the multi-window bug: two windows both believing they should show the sheet")

        store.releasePresentation(requestId: "r1")

        XCTAssertTrue(store.claimPresentation(requestId: "r1"),
                     "after releasing, a fresh presentation claim for the same id must succeed again")
    }

    // MARK: 7. claimPresentation and claimAnswer are independent axes

    func testClaimPresentationAndClaimAnswerAreIndependentOfEachOther() {
        let store = DecisionStore()

        // Claiming presentation says nothing about whether it's been answered.
        XCTAssertTrue(store.claimPresentation(requestId: "r1"))
        XCTAssertNil(store.resolution(for: "r1"),
                     "claiming presentation must not itself record any resolution")

        // Claiming the answer says nothing about presentation state.
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("approve")))
        XCTAssertFalse(store.claimPresentation(requestId: "r1"),
                       "answering must not release or otherwise affect an outstanding presentation claim")

        store.releasePresentation(requestId: "r1")
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"),
                       "releasing presentation must not disturb the recorded answer")
    }

    // MARK: 8. forget removes a tracked resolution but not presentation-claim state

    func testForgetRemovesTheTrackedResolutionButLeavesPresentationClaimStateAlone() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("approve")))
        XCTAssertEqual(store.trackedRequestCount, 1)

        store.forget(requestId: "r1")

        XCTAssertNil(store.resolution(for: "r1"))
        XCTAssertEqual(store.trackedRequestCount, 0)

        // Independent bookkeeping: forgetting the answer doesn't touch
        // presentation-claim state one way or the other.
        XCTAssertTrue(store.claimPresentation(requestId: "r1"),
                     "presentation claiming for a forgotten id must behave as if fresh (no stale claim survives a forget)")
    }

    // MARK: 9. trackedRequestCount reflects live claimAnswer calls, starting at 0

    func testTrackedRequestCountReflectsLiveClaimAnswerCallsStartingAtZero() {
        let store = DecisionStore()
        XCTAssertEqual(store.trackedRequestCount, 0)

        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("approve")))
        XCTAssertEqual(store.trackedRequestCount, 1)

        XCTAssertTrue(store.claimAnswer(requestId: "r2", record: .dismissed))
        XCTAssertEqual(store.trackedRequestCount, 2)

        store.forget(requestId: "r1")
        XCTAssertEqual(store.trackedRequestCount, 1)

        store.forget(requestId: "r2")
        XCTAssertEqual(store.trackedRequestCount, 0)
    }

    // MARK: 10. Bounded FIFO — the 65th distinct id evicts the oldest

    func testClaimingA65thDistinctRequestIdEvictsTheOldestTrackedResolution() {
        let store = DecisionStore()
        for i in 0...64 {
            XCTAssertTrue(store.claimAnswer(requestId: "r\(i)", record: .choice("approve")),
                         "claim #\(i) for a fresh id must succeed")
        }

        XCTAssertEqual(store.trackedRequestCount, 64,
                       "tracked resolutions must be capped at 64")
        XCTAssertNil(store.resolution(for: "r0"),
                     "the oldest tracked id (r0) must have been evicted to make room for the 65th")
        XCTAssertEqual(store.resolution(for: "r64"), .choice("approve"),
                       "the newest id (r64) must still be tracked")
    }

    // MARK: 11. Bounded FIFO — a presentation claim protects its id from eviction

    func testAPresentationClaimOnTheOldestIdProtectsItFromEvictionSkippingToTheNextOldest() {
        let store = DecisionStore()
        for i in 0...63 {
            XCTAssertTrue(store.claimAnswer(requestId: "r\(i)", record: .choice("approve")))
        }
        XCTAssertEqual(store.trackedRequestCount, 64)

        // Protect the oldest id's resolution from eviction by claiming its
        // presentation BEFORE the 65th distinct id arrives.
        XCTAssertTrue(store.claimPresentation(requestId: "r0"))

        XCTAssertTrue(store.claimAnswer(requestId: "r64", record: .choice("approve")))

        XCTAssertEqual(store.trackedRequestCount, 64,
                       "the cap holds regardless of which id was skipped for eviction")
        XCTAssertEqual(store.resolution(for: "r0"), .choice("approve"),
                       "r0 must survive eviction because it currently has an active presentation claim")
        XCTAssertEqual(store.resolution(for: "r64"), .choice("approve"),
                       "the newly-claimed 65th id must be tracked")
        // Eviction skipped forward past the presenting-claimed r0 to the
        // next-oldest evictable id — r1.
        XCTAssertNil(store.resolution(for: "r1"),
                     "eviction must skip past the protected oldest id (r0) and evict the next-oldest evictable id (r1) instead")

        store.releasePresentation(requestId: "r0")
    }
}

// MARK: - DecisionSheetWiringTests

/// Fitness functions, not behavioural tests — the same spirit as
/// `TurnInteractionWiringTests`. `MainLayout.swift`, `DecisionPresenter.swift`,
/// and `DecisionSheet.swift` build the AppKit call sites that actually wire
/// the decision-modal flow together, and none of them is part of this
/// logic-test target (they need a real window to mean anything). Reading
/// them as text is the only way left to enforce that the wiring is actually
/// correct rather than merely available.
final class DecisionSheetWiringTests: XCTestCase {

    // MARK: 1. Presentation lives in exactly one place: UI/DecisionPresenter.swift

    /// This is the regression test for the reported bug itself: a decision
    /// sheet appearing on EVERY open window, answerable twice with
    /// contradictory choices, instead of exactly once app-wide. That bug is a
    /// direct consequence of presentation logic (constructing `DecisionSheet`,
    /// subscribing to the pending-decision publisher) living inside
    /// `MainLayout`, which is instantiated once PER WINDOW. Moving that logic
    /// to a single app-wide `DecisionPresenter` is the fix; this test pins
    /// that MainLayout can never again grow either half of that logic back.
    func testMainLayoutNoLongerConstructsDecisionSheetsOrSubscribesToThePendingDecisionPublisher() throws {
        let mainLayout = try Self.mainLayoutSource()

        XCTAssertFalse(mainLayout.contains("DecisionSheet("), """
            MainLayout.swift must not construct DecisionSheet directly. MainLayout is instantiated once \
            PER WINDOW — any DecisionSheet( construction site here means a sheet is built once per open \
            window, which is exactly the reported bug (a modal shown on every window, answerable twice \
            with contradictory choices). Presentation must happen exactly once, app-wide, in \
            UI/DecisionPresenter.swift.
            """)
        XCTAssertFalse(mainLayout.contains("pendingDecision"), """
            MainLayout.swift must not subscribe to the decision-request publisher (pendingDecision, or \
            whatever it is renamed to) at all. That subscription, replicated once per window, is exactly \
            what drives the reported bug — MainLayout must not know a decision request exists; only \
            UI/DecisionPresenter.swift may.
            """)

        // DecisionPresenter.swift does not exist yet at RED time — reading it
        // here is itself part of the assertion: presentation must live there.
        // This `try` throws (failing the test) until the file is created.
        let presenter = try Self.decisionPresenterSource()
        XCTAssertTrue(presenter.contains("DecisionSheet("), """
            UI/DecisionPresenter.swift must be the (single) construction site for DecisionSheet — that's \
            the whole point of centralizing presentation there.
            """)
    }

    // MARK: 2. No file under Nostromo/UI or Nostromo/Data calls runModal()

    /// Every native modal in this app must be a sheet anchored to a window
    /// (`window.beginSheet(_:)`) — never `alert.runModal()` / `NSApp.runModal(for:)` —
    /// because a free-floating modal has no window association and can end up
    /// stranded on another Space/display, blocking the app's main thread with
    /// no visible way to dismiss it (see `DecisionSheet.swift`'s own header
    /// comment, and the two existing sites in `ReplView.swift`/`MotherView.swift`
    /// that document the same rationale).
    ///
    /// Those very comments mention `alert.runModal()` in prose, so a naive
    /// whole-file substring search would false-positive on itself. This test
    /// strips full-line `//`/`///` comments before searching, which is enough
    /// for the codebase as it stands today (every existing mention is a
    /// standalone comment line, never a trailing comment on a code line). If
    /// a future file adds a trailing "// ...runModal()..." comment on a real
    /// code line, this check would need to get smarter — flagging that
    /// explicitly rather than pretending this is a airtight parse.
    ///
    /// NOTE: once `UI/DecisionPresenter.swift` exists, it is automatically
    /// covered by this same sweep (it lives under `UI/`) with no changes
    /// needed here.
    func testNoFileUnderUIOrDataCallsRunModalAnywhere() throws {
        let root = try Self.nostromoSourceRoot()
        let dirs = [
            root.appendingPathComponent("UI", isDirectory: true),
            root.appendingPathComponent("Data", isDirectory: true),
        ]
        var checkedAtLeastOneFile = false
        for dir in dirs {
            for file in Self.swiftFiles(under: dir) {
                let text = try String(contentsOf: file, encoding: .utf8)
                checkedAtLeastOneFile = true
                for line in Self.codeLines(of: text) {
                    XCTAssertFalse(line.contains("runModal("), """
                        \(file.lastPathComponent) calls runModal() outside a comment — a free-floating \
                        modal has no window association and can block the whole app looking exactly \
                        like a hang. Use window.beginSheet(_:) instead. Line: \(line)
                        """)
                }
            }
        }
        XCTAssertTrue(checkedAtLeastOneFile, "expected to find at least one .swift file under UI/Data to check")
    }

    // MARK: 3. No DecisionSheet( construction site hard-codes a nil resolution

    /// Mirrors the old `answeredChoiceId: nil` check against the new
    /// `resolution:` parameter name. Checks every file that actually contains
    /// a `DecisionSheet(` construction call among the known candidate sites
    /// (`MainLayout.swift` is expected to have none per the test above;
    /// `DecisionPresenter.swift` is expected to be the real one) — a
    /// hard-coded `resolution: nil` throws away `DecisionStore`'s record on
    /// every construction, which is the exact duplicate-message/re-arm bug
    /// `DecisionStore` exists to prevent.
    func testNoDecisionSheetConstructionSitePassesAHardcodedNilResolution() throws {
        var candidates: [(name: String, source: String)] = [
            ("MainLayout.swift", try Self.mainLayoutSource()),
        ]
        // DecisionPresenter.swift doesn't exist at RED time; once it does,
        // include it in the sweep too.
        if let presenter = try? Self.decisionPresenterSource() {
            candidates.append(("DecisionPresenter.swift", presenter))
        }

        var checkedAtLeastOneCall = false
        for (name, source) in candidates {
            let calls = Self.balancedCalls(startingAt: "DecisionSheet(", in: source)
            for call in calls {
                checkedAtLeastOneCall = true
                XCTAssertFalse(call.contains("resolution: nil"), """
                    a hard-coded `resolution: nil` throws away DecisionStore's record on every \
                    construction — the exact duplicate-message/re-arm bug DecisionStore exists to \
                    prevent, in \(name):
                    \(call)
                    """)
            }
        }
        XCTAssertTrue(checkedAtLeastOneCall, """
            expected to find at least one DecisionSheet( construction call across \
            MainLayout.swift/DecisionPresenter.swift — did the construction site move or rename? \
            (DecisionPresenter.swift not existing yet is expected to fail this at RED time.)
            """)
    }

    // MARK: 4. DecisionSheet invokes onAnswer exactly once in its own source

    /// As of this file's PRE-FIX structure, `onAnswer` also appears in two
    /// declaration spots — the stored property's type
    /// (`onAnswer: (_ choiceId: String?) -> Void`) and the matching init
    /// parameter — but both use `onAnswer:` (a colon), not `onAnswer(` (an
    /// open paren), so neither matches this substring search. The only
    /// `onAnswer(` in the file today is the actual completion invocation
    /// inside `resolve(choiceId:)`. This is a textual heuristic, not a
    /// control-flow proof: if a future refactor introduces a second real
    /// call site, or a declaration shape that happens to contain the literal
    /// `onAnswer(` substring, this check breaks and needs a smarter parse —
    /// an acceptable, documented risk for a fitness function like this one.
    func testDecisionSheetInvokesOnAnswerExactlyOnce() throws {
        let source = try Self.decisionSheetSource()
        let occurrences = source.components(separatedBy: "onAnswer(").count - 1

        XCTAssertEqual(occurrences, 1, """
            expected exactly one `onAnswer(` invocation in DecisionSheet.swift — the single completion \
            call inside its one resolution path. Found \(occurrences). If this legitimately changed, \
            verify there is still only one call site that can ever actually fire (not two paths that \
            could each independently answer the request).
            """)
    }

    // MARK: 5. claimAnswer happens before onAnswer, in file order

    /// Best-effort structural check, in the same spirit as `ReplView.swift`'s
    /// documented "record before sending" rule (`ReplView.swift:1362-1370`)
    /// and the equivalent `recordAnswer`-ordering check this replaces:
    /// whichever line first mentions `DecisionStore`'s `claimAnswer` must
    /// appear, in file order, before the line that invokes the `onAnswer`
    /// completion. This is a textual heuristic, not a control-flow proof — if
    /// `DecisionSheet`'s resolution logic ever grows multiple resolution
    /// paths such that a single whole-file text-order check stops being
    /// meaningful, this test (or `DecisionSheet`) should be revisited rather
    /// than trusted blindly.
    func testDecisionSheetClaimsTheAnswerInDecisionStoreBeforeSendingItOnward() throws {
        let source = try Self.decisionSheetSource()

        guard let claimRange = source.range(of: "claimAnswer(") else {
            XCTFail("DecisionStore.claimAnswer( usage not found in DecisionSheet.swift — did the answer path move or rename?")
            return
        }
        guard let sendRange = source.range(of: "onAnswer(") else {
            XCTFail("onAnswer( call not found in DecisionSheet.swift — did the answer path move or rename?")
            return
        }

        XCTAssertTrue(claimRange.lowerBound < sendRange.lowerBound, """
            DecisionSheet must claim the answer in DecisionStore (claimAnswer) before calling onAnswer, \
            so a mid-flight teardown of the send path can never lose the fact that this request is \
            already resolved.
            """)
    }

    // MARK: 6. closeWithoutAnswering never invokes onAnswer

    /// A system-initiated close (another window's answer/timeout/cancel
    /// resolved this request elsewhere; the daemon says it's done) must
    /// close this sheet WITHOUT ever calling `onAnswer` — doing so would look
    /// exactly like an operator dismissal on the wire and could incorrectly
    /// cancel something the operator actually approved elsewhere.
    ///
    /// Approach taken: the SIMPLER total-count argument, not a brace-matched
    /// scan of `closeWithoutAnswering`'s own function body. `testDecisionSheetInvokesOnAnswerExactlyOnce`
    /// above already proves there is exactly one `onAnswer(` call in the
    /// entire file, and `testDecisionSheetClaimsTheAnswerInDecisionStoreBeforeSendingItOnward`
    /// (indirectly, by requiring `claimAnswer(` before it) anchors that one
    /// call to the real answer path. If that single call lives inside
    /// `resolve(choiceId:)` (the operator-driven path), no other function —
    /// including `closeWithoutAnswering` — can also contain it, since there
    /// is only one to find. This sidesteps needing a `{`/`}`-balancing helper
    /// to isolate the function body; it holds only as long as the two
    /// sibling tests above keep passing, which is noted here explicitly.
    func testCloseWithoutAnsweringNeverInvokesOnAnswer() throws {
        let source = try Self.decisionSheetSource()

        guard source.contains("closeWithoutAnswering") else {
            XCTFail("""
                closeWithoutAnswering( not found in DecisionSheet.swift — a system-initiated close path \
                (driven by a DecisionResolved notice from elsewhere, e.g. another window's answer) must \
                exist, and it must never call onAnswer.
                """)
            return
        }

        let occurrences = source.components(separatedBy: "onAnswer(").count - 1
        XCTAssertEqual(occurrences, 1, """
            expected exactly one `onAnswer(` call in the whole file — proven elsewhere to live inside \
            resolve(choiceId:) — which is what proves closeWithoutAnswering never answers. If this count \
            changes, this test's argument no longer holds and needs a real brace-matched scan of \
            closeWithoutAnswering's own body instead.
            """)
    }

    // MARK: - Helpers

    /// `.../macOS/Nostromo` — the source root both `UI` and `Data` hang off.
    private static func nostromoSourceRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/DecisionStoreTests.swift
            .deletingLastPathComponent()   // …/macOS/NostromoTests
            .deletingLastPathComponent()   // …/macOS
            .appendingPathComponent("Nostromo")
    }

    private static func mainLayoutSource() throws -> String {
        try String(contentsOf: nostromoSourceRoot().appendingPathComponent("UI/MainLayout.swift"), encoding: .utf8)
    }

    private static func decisionSheetSource() throws -> String {
        try String(contentsOf: nostromoSourceRoot().appendingPathComponent("UI/DecisionSheet.swift"), encoding: .utf8)
    }

    /// `UI/DecisionPresenter.swift` — the new app-wide (not per-window) home
    /// for decision-modal presentation. Does not exist until this job's
    /// implementation phase; reading it is expected to throw until then.
    private static func decisionPresenterSource() throws -> String {
        try String(contentsOf: nostromoSourceRoot().appendingPathComponent("UI/DecisionPresenter.swift"), encoding: .utf8)
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// Every line of `source` with full-line `//`/`///` comments dropped
    /// entirely (see the doc comment on the test that uses this).
    private static func codeLines(of source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    /// Every call `marker` … `)` in `source`, matching parentheses so a nested
    /// call (e.g. building an argument inline) doesn't truncate the match.
    /// Duplicated from `TurnInteractionWiringTests` — that helper is `private`
    /// to its own file, so it isn't reachable from here.
    private static func balancedCalls(startingAt marker: String, in source: String) -> [String] {
        var calls: [String] = []
        var searchStart = source.startIndex
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1   // `marker` already includes the opening "("
            var idx = markerRange.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "(" { depth += 1 }
                if source[idx] == ")" { depth -= 1 }
                idx = source.index(after: idx)
            }
            calls.append(String(source[markerRange.lowerBound..<idx]))
            searchStart = idx
        }
        return calls
    }
}
