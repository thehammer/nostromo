// NostromoKit — FocusActivityModelTests.swift
//
// The rule that turns "counters the daemon reports" and "what the operator last saw" into the quiet mark
// on a focus row: none, activity (hollow ring), unread (filled dot with a count), problem (dot with "!").
//
// `FocusActivityModel.evaluate(current:saved:isSeen:)` is pure, so the whole rule table lives here:
//
//   current nil                 -> (.none, saved untouched)   an older daemon shows nothing
//   saved nil                   -> baseline: (.none, saved = current)
//   epoch differs               -> baseline
//   any counter below the saved -> baseline (counters only ever increase within an epoch)
//   isSeen                      -> (.none, saved = current)
//   otherwise deltas: problems > 0 -> .problem(lastProblem); messages > 0 -> .unread(n);
//                     turns > 0 -> .activity; else .none. `saved` is returned unchanged.
//
// Mutations caught here:
//   (1) `isSeen` ignored                -> testSeenFocusNeverFlagsAndRecordsWhatItSaw and the seen rows of
//                                          testUnseenDeltasMapToTheStrongestState
//   (2) the epoch ignored               -> testADifferentEpochBaselinesSilentlyEvenWhenEveryCounterIsHigher
//   (4) UNREAD losing to ACTIVITY       -> testUnseenDeltasMapToTheStrongestState (messages+turns rows) and
//                                          testUnreadBeatsActivityAndProblemBeatsBoth

import XCTest
@testable import NostromoKit

final class FocusActivityModelTests: XCTestCase {

    // MARK: - Helpers

    private func counters(_ turns: UInt64, _ messages: UInt64, _ problems: UInt64, epoch: String = "e1",
                          last: ProblemKind? = nil) -> FocusActivityCounters {
        FocusActivityCounters(epoch: epoch, turns: turns, messages: messages, problems: problems, lastProblem: last)
    }

    private func marks(_ turns: UInt64, _ messages: UInt64, _ problems: UInt64, epoch: String = "e1") -> FocusSeenMarks {
        FocusSeenMarks(epoch: epoch, turns: turns, messages: messages, problems: problems)
    }

    private func evaluate(_ current: FocusActivityCounters?, _ saved: FocusSeenMarks?, seen: Bool = false)
        -> FocusActivityModel.Result {
        FocusActivityModel.evaluate(current: current, saved: saved, isSeen: seen)
    }

    // MARK: - An older daemon

    func testNoCountersShowNothingAndLeaveTheSavedMarksUntouched() {
        for seen in [false, true] {
            XCTAssertEqual(evaluate(nil, nil, seen: seen), .init(state: .none, saved: nil), "seen \(seen), nothing saved")
            let saved = marks(4, 3, 2)
            XCTAssertEqual(evaluate(nil, saved, seen: seen), .init(state: .none, saved: saved),
                           "seen \(seen): an older daemon must not wipe what was saved")
        }
    }

    // MARK: - Baselines

    func testFirstSightOfAFocusBaselinesSilently() {
        let current = counters(40, 30, 20, last: .crashed)
        for seen in [false, true] {
            XCTAssertEqual(evaluate(current, nil, seen: seen),
                           .init(state: .none, saved: FocusSeenMarks(current)),
                           "no saved marks: the first reading is the baseline, never a mark (seen \(seen))")
        }
    }

    func testFirstSightOfAZeroedFocusBaselinesToZero() {
        XCTAssertEqual(evaluate(counters(0, 0, 0), nil), .init(state: .none, saved: marks(0, 0, 0)))
    }

    func testADifferentEpochBaselinesSilentlyEvenWhenEveryCounterIsHigher() {
        let saved = marks(1, 1, 1, epoch: "old")
        let current = counters(50, 40, 30, epoch: "new", last: .crashed)
        for seen in [false, true] {
            XCTAssertEqual(evaluate(current, saved, seen: seen),
                           .init(state: .none, saved: FocusSeenMarks(current)),
                           "a restarted daemon or a new Claude session starts a new count: nothing to compare (seen \(seen))")
        }
    }

    func testADifferentEpochBaselinesWhenCountersAreLowerToo() {
        let saved = marks(50, 40, 30, epoch: "old")
        let current = counters(2, 1, 0, epoch: "new")
        XCTAssertEqual(evaluate(current, saved), .init(state: .none, saved: FocusSeenMarks(current)))
    }

    func testEpochsAreComparedExactly() {
        let saved = marks(1, 1, 1, epoch: "abc")
        for other in ["abd", "ABC", "abc ", "", "abcd"] {
            let current = counters(9, 9, 9, epoch: other)
            XCTAssertEqual(evaluate(current, saved).state, .none, "epoch '\(other)' is not 'abc'")
            XCTAssertEqual(evaluate(current, saved).saved, FocusSeenMarks(current), "epoch '\(other)' re-baselines")
        }
    }

    func testACounterBelowTheSavedOneIsAnAnomalyAndReBaselinesSilently() {
        let saved = marks(10, 10, 10)
        let cases: [(String, FocusActivityCounters)] = [
            ("turns lower", counters(9, 10, 10)),
            ("messages lower", counters(10, 9, 10)),
            ("problems lower", counters(10, 10, 9)),
            ("one lower, the others higher", counters(20, 5, 20, last: .crashed)),
            ("all lower", counters(0, 0, 0)),
        ]
        for (name, current) in cases {
            for seen in [false, true] {
                XCTAssertEqual(evaluate(current, saved, seen: seen),
                               .init(state: .none, saved: FocusSeenMarks(current)), "\(name), seen \(seen)")
            }
        }
    }

    // MARK: - Seen

    func testSeenFocusNeverFlagsAndRecordsWhatItSaw() {
        let saved = marks(10, 5, 1)
        let cases: [(String, FocusActivityCounters)] = [
            ("nothing changed", counters(10, 5, 1)),
            ("turns advanced", counters(12, 5, 1)),
            ("messages advanced", counters(12, 8, 1)),
            ("problems advanced", counters(12, 8, 3, last: .apiError)),
        ]
        for (name, current) in cases {
            XCTAssertEqual(evaluate(current, saved, seen: true),
                           .init(state: .none, saved: FocusSeenMarks(current)), name)
        }
    }

    func testWhatASeenFocusRecordedLeavesNothingToShowWhenItIsNoLongerSeen() {
        let saved = marks(10, 5, 1)
        let current = counters(12, 8, 3, last: .crashed)
        let whileSeen = evaluate(current, saved, seen: true)
        let after = evaluate(current, whileSeen.saved, seen: false)
        XCTAssertEqual(after.state, .none)
        XCTAssertEqual(after.saved, whileSeen.saved)
    }

    // MARK: - Unseen deltas

    private struct DeltaCase {
        let name: String
        let turns: UInt64, messages: UInt64, problems: UInt64
        let last: ProblemKind?
        let expected: FocusActivityState
    }

    /// Saved is (100, 50, 10); each row adds these deltas to it.
    private let deltaTable: [DeltaCase] = [
        DeltaCase(name: "nothing", turns: 0, messages: 0, problems: 0, last: nil, expected: .none),
        DeltaCase(name: "a turn", turns: 1, messages: 0, problems: 0, last: nil, expected: .activity),
        DeltaCase(name: "many turns", turns: 40, messages: 0, problems: 0, last: .crashed, expected: .activity),
        DeltaCase(name: "a message without a turn", turns: 0, messages: 1, problems: 0, last: nil, expected: .unread(count: 1)),
        DeltaCase(name: "turns and one message: unread beats activity", turns: 5, messages: 1, problems: 0, last: nil,
                  expected: .unread(count: 1)),
        DeltaCase(name: "turns and three messages", turns: 5, messages: 3, problems: 0, last: .noText, expected: .unread(count: 3)),
        DeltaCase(name: "more messages than turns", turns: 1, messages: 6, problems: 0, last: nil, expected: .unread(count: 6)),
        DeltaCase(name: "a huge message delta", turns: 0, messages: 5_000_000_000, problems: 0, last: nil,
                  expected: .unread(count: 5_000_000_000)),
        DeltaCase(name: "a problem alone", turns: 0, messages: 0, problems: 1, last: .crashed, expected: .problem(.crashed)),
        DeltaCase(name: "a problem and a turn: problem beats activity", turns: 1, messages: 0, problems: 1, last: .stopped,
                  expected: .problem(.stopped)),
        DeltaCase(name: "problem, messages and turns: problem beats unread", turns: 3, messages: 4, problems: 2,
                  last: .rateLimited, expected: .problem(.rateLimited)),
        DeltaCase(name: "a problem with no kind reported", turns: 0, messages: 0, problems: 1, last: nil, expected: .problem(nil)),
        DeltaCase(name: "a problem of a kind this build does not know", turns: 0, messages: 2, problems: 1, last: .unknown,
                  expected: .problem(.unknown)),
    ]

    func testUnseenDeltasMapToTheStrongestState() {
        let saved = marks(100, 50, 10)
        for row in deltaTable {
            let current = counters(100 + row.turns, 50 + row.messages, 10 + row.problems, last: row.last)
            let unseen = evaluate(current, saved, seen: false)
            XCTAssertEqual(unseen.state, row.expected, row.name)
            XCTAssertEqual(unseen.saved, saved, "an unseen focus leaves the saved marks alone: \(row.name)")

            // The very same readings while the focus is seen show nothing and are recorded.
            let seen = evaluate(current, saved, seen: true)
            XCTAssertEqual(seen.state, .none, "seen: \(row.name)")
            XCTAssertEqual(seen.saved, FocusSeenMarks(current), "seen: \(row.name)")
        }
    }

    func testUnreadBeatsActivityAndProblemBeatsBoth() {
        let saved = marks(0, 0, 0)
        XCTAssertEqual(evaluate(counters(2, 2, 0), saved).state, .unread(count: 2))
        XCTAssertEqual(evaluate(counters(2, 2, 1, last: .turnError), saved).state, .problem(.turnError))
        XCTAssertEqual(evaluate(counters(2, 0, 0), saved).state, .activity)
    }

    func testTheUnreadCountIsTheMessagesSinceTheSavedMarksNotTheTotal() {
        XCTAssertEqual(evaluate(counters(30, 25, 0), marks(20, 22, 0)).state, .unread(count: 3))
        XCTAssertEqual(evaluate(counters(30, 25, 0), marks(20, 24, 0)).state, .unread(count: 1))
    }

    func testEvaluatingAgainWithTheSameInputsGivesTheSameResult() {
        let saved = marks(1, 1, 1)
        let current = counters(5, 3, 2, last: .loginHold)
        XCTAssertEqual(evaluate(current, saved), evaluate(current, saved))
        // And a baseline is a fixed point: evaluating its own output flags nothing.
        let baseline = evaluate(current, nil)
        XCTAssertEqual(evaluate(current, baseline.saved), .init(state: .none, saved: baseline.saved))
    }

    // MARK: - FocusActivityState strings

    func testNoneHasNoPhraseAndNoToolTip() {
        XCTAssertNil(FocusActivityState.none.accessibilityPhrase)
        XCTAssertNil(FocusActivityState.none.toolTip)
    }

    func testActivityStrings() {
        XCTAssertEqual(FocusActivityState.activity.accessibilityPhrase, "activity since you last looked")
        XCTAssertEqual(FocusActivityState.activity.toolTip, "Activity since you last looked")
    }

    func testUnreadStringsAreSingularForOneAndPluralOtherwise() {
        XCTAssertEqual(FocusActivityState.unread(count: 1).accessibilityPhrase, "unread response")
        XCTAssertEqual(FocusActivityState.unread(count: 1).toolTip, "1 new message")
        let plural: [UInt64] = [2, 3, 99, 100, 100_000, 5_000_000_000]
        for n in plural {
            XCTAssertEqual(FocusActivityState.unread(count: n).accessibilityPhrase, "\(n) unread responses", "\(n)")
            XCTAssertEqual(FocusActivityState.unread(count: n).toolTip, "\(n) new messages", "\(n)")
        }
    }

    func testProblemStringsCarryTheKindsSummary() {
        for (kind, summary) in Self.summaries {
            XCTAssertEqual(FocusActivityState.problem(kind).accessibilityPhrase, "problem: \(summary)", "\(kind)")
            XCTAssertEqual(FocusActivityState.problem(kind).toolTip, "Problem: \(summary)", "\(kind)")
        }
        XCTAssertEqual(FocusActivityState.problem(nil).accessibilityPhrase, "problem: something went wrong")
        XCTAssertEqual(FocusActivityState.problem(nil).toolTip, "Problem: something went wrong")
        XCTAssertEqual(FocusActivityState.problem(.crashed).toolTip, "Problem: the session crashed")
    }

    func testStatesAreEqualOnlyToThemselves() {
        XCTAssertEqual(FocusActivityState.unread(count: 3), .unread(count: 3))
        XCTAssertNotEqual(FocusActivityState.unread(count: 3), .unread(count: 4))
        XCTAssertNotEqual(FocusActivityState.problem(.crashed), .problem(.stopped))
        XCTAssertNotEqual(FocusActivityState.problem(nil), .problem(.unknown))
        XCTAssertNotEqual(FocusActivityState.none, .activity)
    }

    // MARK: - ProblemKind.summary

    /// The full table: every kind, exactly its fragment.
    static let summaries: [(ProblemKind, String)] = [
        (.crashed, "the session crashed"),
        (.stopped, "the session was stopped"),
        (.crashLoopGuard, "the session stopped after repeated crashes"),
        (.turnError, "a turn ended in an error"),
        (.apiError, "a turn ended on an API error"),
        (.rateLimited, "a turn hit a usage limit"),
        (.loginHold, "a message is held until Claude signs in"),
        (.sendRefused, "a message could not be sent"),
        (.noText, "a turn finished without a reply"),
        (.unknown, "something went wrong"),
    ]

    func testEveryProblemKindHasExactlyItsSummary() {
        XCTAssertEqual(Self.summaries.count, 10, "nine kinds and unknown")
        for (kind, summary) in Self.summaries {
            XCTAssertEqual(kind.summary, summary, "\(kind)")
        }
    }

    func testNoTwoProblemKindsShareASummary() {
        XCTAssertEqual(Set(Self.summaries.map { $0.1 }).count, Self.summaries.count)
    }
}
