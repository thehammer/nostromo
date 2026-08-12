import XCTest

// LoadHarnessTargeting is compiled into this target directly (logic test —
// Foundation-only, no dependency on NostromodClient/ChatSession/AppKit).

/// `TranscriptLoadHarness.start()` used to fall back to a hard-coded guessed
/// tag (`["claudia"]`) after ~30 s of finding no registered panes, and drove
/// it — which is exactly the failure its own doc comment names ("guessing
/// tags is how the first harness run measured nothing"). Nothing marked that
/// run invalid; it just quietly measured zero panes and reported success.
///
/// `LoadHarnessTargeting.resolve` is that decision pulled out into a pure,
/// dependency-free type so the failure mode is enforceable by a test instead
/// of by re-reading a doc comment and hoping nobody reintroduces the guess.
final class LoadHarnessTargetingTests: XCTestCase {

    // MARK: - Helpers

    private func unwrapPlan(_ result: Result<LoadHarnessTargeting.Plan, LoadHarnessTargeting.Failure>,
                            file: StaticString = #filePath, line: UInt = #line) -> LoadHarnessTargeting.Plan? {
        switch result {
        case .success(let plan):
            return plan
        case .failure(let failure):
            XCTFail("expected a plan, got failure(\(failure))", file: file, line: line)
            return nil
        }
    }

    // MARK: - 1. No registered panes is a failure, never a guessed tag

    func testNoRegisteredPanesIsAFailureRatherThanAGuessedTag() {
        let result = LoadHarnessTargeting.resolve(registered: [], activeTag: nil,
                                                   requested: 4, waitedSeconds: 32.5)
        switch result {
        case .success(let plan):
            XCTFail("must never drive a tag nobody registered; got \(plan.tags)")
        case .failure(let failure):
            XCTAssertEqual(failure, .noRegisteredPanes(waitedSeconds: 32.5),
                           "the wait time must be carried through, or the failure can't be reported honestly")
        }
    }

    // MARK: - 2. The active pane is moved to the front

    func testTheActivePaneIsMovedToTheFrontBecauseAHiddenPaneMaterializesNothing() throws {
        let result = LoadHarnessTargeting.resolve(registered: ["a", "b"], activeTag: "b",
                                                   requested: 1, waitedSeconds: 0)
        let plan = try XCTUnwrap(unwrapPlan(result))
        XCTAssertEqual(plan.tags, ["b"])
    }

    // MARK: - 3. The original requested count is preserved for reporting

    func testRequestedCountAboveWhatsRegisteredIsCarriedThroughSoTheGapIsReportable() throws {
        let result = LoadHarnessTargeting.resolve(registered: ["a"], activeTag: nil,
                                                   requested: 8, waitedSeconds: 0)
        let plan = try XCTUnwrap(unwrapPlan(result))
        XCTAssertEqual(plan.tags, ["a"], "only what's actually registered can be driven")
        XCTAssertEqual(plan.requested, 8,
                       "the original request must survive so the 8-vs-1 gap can be reported, not hidden")
    }

    // MARK: - 4. An active tag that isn't registered is harmless

    func testAnActiveTagNotAmongRegisteredPanesDoesNotCrashAndLeavesOrderUnchanged() throws {
        let result = LoadHarnessTargeting.resolve(registered: ["a", "b", "c"], activeTag: "z",
                                                   requested: 3, waitedSeconds: 0)
        let plan = try XCTUnwrap(unwrapPlan(result))
        XCTAssertEqual(plan.tags, ["a", "b", "c"])
    }

    func testANilActiveTagLeavesRegistrationOrderUnchanged() throws {
        let result = LoadHarnessTargeting.resolve(registered: ["a", "b"], activeTag: nil,
                                                   requested: 2, waitedSeconds: 0)
        let plan = try XCTUnwrap(unwrapPlan(result))
        XCTAssertEqual(plan.tags, ["a", "b"])
    }
}
