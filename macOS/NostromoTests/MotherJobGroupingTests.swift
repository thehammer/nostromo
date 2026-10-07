import XCTest

// MotherJobGrouping / MotherJob are compiled into this target directly (logic test).

final class MotherJobGroupingTests: XCTestCase {

    private func job(_ id: String, _ state: String, started: TimeInterval? = nil) -> MotherJob {
        MotherJob(id: id, state: state, repo: "r", isolation: "worktree", title: "title-\(id)",
                  createdAt: Date(timeIntervalSince1970: 1_000),
                  startedAt: started.map { Date(timeIntervalSince1970: $0) },
                  finishedAt: nil, planPath: nil, question: nil, pausedReason: nil,
                  adherenceStatus: nil, currentTier: nil)
    }

    func testExactlyOneGroupPerStateEvenWhenQueuedAndReadyInterleave() {
        // Same rank in the old code, no start times: they used to interleave.
        let jobs = [job("a", "ready"), job("b", "queued"), job("c", "ready"), job("d", "queued")]
        let groups = MotherJobGrouping.groups(from: jobs)
        XCTAssertEqual(groups.map(\.state), ["queued", "ready"])
        XCTAssertEqual(Set(groups[0].jobs.map(\.id)), ["b", "d"])
        XCTAssertEqual(Set(groups[1].jobs.map(\.id)), ["a", "c"])
    }

    func testSucceededAndCancelledAreSeparateSections() {
        let jobs = [job("a", "cancelled"), job("b", "succeeded"), job("c", "cancelled")]
        XCTAssertEqual(MotherJobGrouping.groups(from: jobs).map(\.state), ["succeeded", "cancelled"])
    }

    func testDisplayOrderAndUnknownStatesLast() {
        let jobs = ["cancelled", "failed", "weird", "ready", "awaiting", "running", "queued", "succeeded"]
            .enumerated().map { job("j\($0.offset)", $0.element) }
        XCTAssertEqual(MotherJobGrouping.groups(from: jobs).map(\.state),
                       ["awaiting", "running", "queued", "ready", "failed", "succeeded", "cancelled", "weird"])
    }

    func testNewestFirstWithAStableTiebreak() {
        let jobs = [job("b", "running", started: 100), job("a", "running", started: 100), job("c", "running", started: 200)]
        XCTAssertEqual(MotherJobGrouping.groups(from: jobs)[0].jobs.map(\.id), ["c", "a", "b"])
    }

    func testEmptyInputGivesNoGroups() {
        XCTAssertTrue(MotherJobGrouping.groups(from: []).isEmpty)
    }
}
