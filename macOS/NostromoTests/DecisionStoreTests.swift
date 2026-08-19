import XCTest
import AppKit

// DecisionStore, DecisionAnswerRecord are compiled into this target directly
// (logic test — no host app, no `@testable import`), matching the convention
// documented in TurnInteractionTests.swift.

// MARK: - DecisionStoreTests

/// `DecisionStore` is the "outside the sheet" source of truth for whether a
/// daemon-driven decision request has already been resolved — the same
/// discipline `TurnInteractionStore` enforces for `AskQuestionView`, applied
/// here so a duplicate broadcast, a future app-relaunch replay, or a second
/// construction site can never re-arm a sheet for a request that is already
/// done.
final class DecisionStoreTests: XCTestCase {

    // MARK: 1. A fresh store has nothing resolved

    func testFreshStoreHasNothingResolvedForAnyRequestId() {
        let store = DecisionStore()
        XCTAssertFalse(store.isResolved(requestId: "r1"))
        XCTAssertNil(store.answeredChoiceId(for: "r1"))
        XCTAssertFalse(store.isResolved(requestId: "anything-else"))
        XCTAssertNil(store.answeredChoiceId(for: "anything-else"))
    }

    // MARK: 2. Recording a choice resolves it and exposes the chosen id

    func testRecordingAChoiceResolvesTheRequestAndExposesTheChosenId() {
        let store = DecisionStore()
        store.recordAnswer(requestId: "r1", record: .choice("approve"))

        XCTAssertTrue(store.isResolved(requestId: "r1"))
        XCTAssertEqual(store.answeredChoiceId(for: "r1"), "approve")
    }

    // MARK: 3. Recording a dismissal resolves it but exposes no chosen id

    func testRecordingADismissalResolvesTheRequestButExposesNoChosenId() {
        let store = DecisionStore()
        store.recordAnswer(requestId: "r1", record: .dismissed)

        XCTAssertTrue(store.isResolved(requestId: "r1"),
                      "a dismissal is still a resolution")
        XCTAssertNil(store.answeredChoiceId(for: "r1"),
                     "there is no chosen option to render for a dismissal")
    }

    // MARK: 4. Two different request ids are tracked independently

    func testTwoDifferentRequestIdsAreTrackedIndependently() {
        let store = DecisionStore()
        store.recordAnswer(requestId: "r1", record: .choice("approve"))

        XCTAssertFalse(store.isResolved(requestId: "r2"),
                       "recording r1's answer must not leak into r2's state")
        XCTAssertNil(store.answeredChoiceId(for: "r2"))

        store.recordAnswer(requestId: "r2", record: .dismissed)
        XCTAssertEqual(store.answeredChoiceId(for: "r1"), "approve",
                       "recording r2's answer must not disturb r1's already-recorded state")
        XCTAssertTrue(store.isResolved(requestId: "r2"))
    }

    // MARK: 5. forget removes tracking

    func testForgetRemovesTheRequestAndDecreasesTheTrackedCount() {
        let store = DecisionStore()
        store.recordAnswer(requestId: "r1", record: .choice("approve"))
        XCTAssertEqual(store.trackedRequestCount, 1)

        store.forget(requestId: "r1")

        XCTAssertFalse(store.isResolved(requestId: "r1"))
        XCTAssertNil(store.answeredChoiceId(for: "r1"))
        XCTAssertEqual(store.trackedRequestCount, 0)
    }

    // MARK: 6. trackedRequestCount reflects live tracking, starting at 0

    func testTrackedRequestCountReflectsCurrentlyTrackedRequestsStartingAtZero() {
        let store = DecisionStore()
        XCTAssertEqual(store.trackedRequestCount, 0)

        store.recordAnswer(requestId: "r1", record: .choice("approve"))
        XCTAssertEqual(store.trackedRequestCount, 1)

        store.recordAnswer(requestId: "r2", record: .dismissed)
        XCTAssertEqual(store.trackedRequestCount, 2)

        store.forget(requestId: "r1")
        XCTAssertEqual(store.trackedRequestCount, 1)

        store.forget(requestId: "r2")
        XCTAssertEqual(store.trackedRequestCount, 0)
    }

    // MARK: 7. A second recordAnswer for the same id overwrites (last write wins)

    /// The daemon is the actual source of truth for "already answered" — its
    /// `AnswerOutcome::AlreadyAnswered` rejection is what actually prevents a
    /// second answer from reaching a live session. The client-side store's job
    /// is only to gate the sheet's own UI (render as answered / go inert), not
    /// to reimplement that state machine. So a second local record for the
    /// same request id is expected to simply overwrite the first — this test
    /// asserts that behavior explicitly, so it reads as intentional rather
    /// than an accident of a dictionary's default semantics.
    func testASecondRecordAnswerForTheSameRequestIdOverwritesTheFirstLastWriteWins() {
        let store = DecisionStore()
        store.recordAnswer(requestId: "r1", record: .choice("approve"))
        XCTAssertEqual(store.answeredChoiceId(for: "r1"), "approve")

        store.recordAnswer(requestId: "r1", record: .choice("reject"))
        XCTAssertEqual(store.answeredChoiceId(for: "r1"), "reject",
                       "a second local record for the same id must overwrite the first (last write wins)")

        store.recordAnswer(requestId: "r1", record: .dismissed)
        XCTAssertTrue(store.isResolved(requestId: "r1"))
        XCTAssertNil(store.answeredChoiceId(for: "r1"),
                     "overwriting with a dismissal must clear the previously-recorded choice")
    }
}

// MARK: - DecisionSheetWiringTests

/// Fitness functions, not behavioural tests — the same spirit as
/// `TurnInteractionWiringTests`. `MainLayout.swift` and `DecisionSheet.swift`
/// build the AppKit call sites that actually wire the decision-modal flow
/// together, and neither is part of this logic-test target (they need a real
/// window to mean anything). Reading them as text is the only way left to
/// enforce that the wiring is actually correct rather than merely available.
final class DecisionSheetWiringTests: XCTestCase {

    // MARK: 1. DecisionSheet is never constructed with a hardcoded nil answeredChoiceId

    func testDecisionSheetIsNeverConstructedWithAHardcodedNilAnsweredChoiceId() throws {
        let calls = Self.balancedCalls(startingAt: "DecisionSheet(", in: try Self.mainLayoutSource())
        XCTAssertFalse(calls.isEmpty, "DecisionSheet( construction site not found — did it move or rename?")
        for call in calls {
            XCTAssertFalse(call.contains("answeredChoiceId: nil"), """
                a hard-coded nil throws away DecisionStore's record on every construction — the exact \
                duplicate-message/re-arm bug DecisionStore exists to prevent:
                \(call)
                """)
        }
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

    // MARK: 3. DecisionSheet records into DecisionStore before sending the answer onward

    /// Best-effort structural check, in the same spirit as `ReplView.swift`'s
    /// documented "record before sending" rule (`ReplView.swift:1362-1370`):
    /// whichever line first mentions `DecisionStore`'s `recordAnswer` must
    /// appear, in file order, before the line that invokes the `onAnswer`
    /// completion. This is a textual heuristic, not a control-flow proof — if
    /// `DecisionSheet`'s resolution logic ever grows multiple resolution
    /// paths such that a single whole-file text-order check stops being
    /// meaningful, this test (or `DecisionSheet`) should be revisited rather
    /// than trusted blindly.
    func testDecisionSheetRecordsIntoDecisionStoreBeforeSendingTheAnswerOnward() throws {
        let source = try Self.decisionSheetSource()

        guard let recordRange = source.range(of: "recordAnswer") else {
            XCTFail("DecisionStore.recordAnswer( usage not found in DecisionSheet.swift — did the answer path move or rename?")
            return
        }
        guard let sendRange = source.range(of: "onAnswer(") else {
            XCTFail("onAnswer( call not found in DecisionSheet.swift — did the answer path move or rename?")
            return
        }

        XCTAssertTrue(recordRange.lowerBound < sendRange.lowerBound, """
            DecisionSheet must record into DecisionStore before calling onAnswer, so a mid-flight \
            teardown of the send path can never lose the fact that this request is already resolved.
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
