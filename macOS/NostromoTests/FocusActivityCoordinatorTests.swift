import XCTest
import AppKit
import Combine
import Foundation
import NostromoKit

// The brain behind the sidebar's quiet unread mark: which focuses the operator is looking at right now,
// what the daemon's counters say, and what was last seen. `FocusActivityCoordinator` takes
// `session_list_resp` readings (`ingest`) and window sightings (`reportWindow`) and answers
// `state(for:)`: none, activity (ring), unread (dot, count) or problem (dot with "!").
//
// A focus is SEEN while it is the visible focus of a KEY window (visible = not minimised, not occluded,
// app not hidden). Seen means: marks cleared at that moment, and kept equal to the counters while it
// stays seen. The first sight of a focus, a new epoch, or a counter that went DOWN is a silent baseline.
//
// Logic test (no host app, no `@testable import`): compiled into this target directly. Every store runs
// on its own throwaway `UserDefaults` suite, removed in teardown; the real defaults are never touched.
//
// Mutations caught here:
//   (1) a tag never treated as seen        -> testASeenFocusNeverFlagsAndLeavesNothingBehindWhenItStopsBeingSeen,
//                                             testBecomingSeenClearsEveryKindOfMark, the multi-window tests
//   (2) the epoch ignored                  -> testANewEpochBaselinesSilentlyAndTheNewEpochIsWhatIsComparedNext,
//                                             testARelaunchWithADifferentEpochShowsNothing
//   (4) UNREAD losing to ACTIVITY          -> testPrecedenceThroughTheCoordinator
//   (8) a non-key window counted as seeing -> testSightingsThatDoNotCountAsSeeingLetTheMarkThrough ("not the
//                                             key window" row), testOnlyTheKeyWindowSeesAFocus

final class FocusActivityCoordinatorTests: XCTestCase {

    // MARK: - Rig

    private final class Clock {
        private var t: TimeInterval = 2_000_000
        func now() -> Date { t += 1; return Date(timeIntervalSince1970: t) }
    }

    private final class Rig {
        let suite: String
        let defaults: UserDefaults
        let clock: Clock
        var store: FocusSeenStore
        var coordinator: FocusActivityCoordinator

        init() {
            let suite = "test.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let clock = Clock()
            let store = FocusSeenStore(defaults: defaults, now: { clock.now() })
            self.suite = suite
            self.defaults = defaults
            self.clock = clock
            self.store = store
            self.coordinator = FocusActivityCoordinator(store: store)
        }

        /// The app quits and starts again on the same defaults: a new store and a new coordinator.
        func relaunch() {
            let clock = self.clock
            store = FocusSeenStore(defaults: defaults, now: { clock.now() })
            coordinator = FocusActivityCoordinator(store: store)
        }

        /// What a reader of the defaults sees, independent of the coordinator's own store.
        func persisted() -> FocusSeenStore { FocusSeenStore(defaults: defaults) }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            defaults.removeSuite(named: suite)
        }

        func ingest(_ tag: String, _ counters: FocusActivityCounters?) {
            coordinator.ingest([SessionActivityEntry(tag: tag, activity: counters)])
        }

        func window(_ id: Int, _ tag: String?, key: Bool = true, visible: Bool = true) {
            coordinator.reportWindow(id: id, sighting: FocusWindowSighting(tag: tag, isKey: key, isVisible: visible))
        }

        func closeWindow(_ id: Int) { coordinator.reportWindow(id: id, sighting: nil) }

        func state(_ tag: String) -> FocusActivityState { coordinator.state(for: tag) }
    }

    private func makeRig() -> Rig {
        let rig = Rig()
        addTeardownBlock { rig.cleanup() }
        return rig
    }

    private func c(_ turns: UInt64, _ messages: UInt64, _ problems: UInt64, epoch: String = "e1",
                   last: ProblemKind? = nil) -> FocusActivityCounters {
        FocusActivityCounters(epoch: epoch, turns: turns, messages: messages, problems: problems, lastProblem: last)
    }

    private func marks(_ counters: FocusActivityCounters) -> FocusSeenMarks { FocusSeenMarks(counters) }

    /// The baseline every scenario starts from: counters the operator has "seen" as of first sight.
    private let base = (turns: UInt64(5), messages: UInt64(3), problems: UInt64(1))
    private var baseline: FocusActivityCounters { c(base.turns, base.messages, base.problems) }

    // MARK: - Baselines

    func testFirstSightBaselinesSilentlyWhateverTheCountersAre() {
        for counters in [c(0, 0, 0), c(5, 3, 1), c(500, 300, 100, last: .crashed), c(1, 0, 9, last: .apiError)] {
            let rig = makeRig()
            rig.ingest("a", counters)
            XCTAssertEqual(rig.state("a"), .none, "\(counters)")
            XCTAssertEqual(rig.store.marks(for: "a"), marks(counters), "the baseline is saved")
        }
    }

    func testNothingNewAfterTheBaselineShowsNothing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", baseline)
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testANewEpochBaselinesSilentlyAndTheNewEpochIsWhatIsComparedNext() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1), "precondition: flagged in epoch e1")

        // The daemon restarted: new epoch, higher counters. Nothing to compare, so nothing shows.
        rig.ingest("a", c(50, 40, 30, epoch: "e2", last: .crashed))
        XCTAssertEqual(rig.state("a"), .none, "a different epoch is a silent re-baseline")
        XCTAssertEqual(rig.store.marks(for: "a"), marks(c(50, 40, 30, epoch: "e2")))

        // And from there the comparison is against e2's numbers.
        rig.ingest("a", c(51, 40, 30, epoch: "e2"))
        XCTAssertEqual(rig.state("a"), .activity)
    }

    func testANewEpochWithLowerCountersIsAlsoSilent() {
        let rig = makeRig()
        rig.ingest("a", c(50, 40, 30))
        rig.ingest("a", c(1, 0, 0, epoch: "e2"))
        XCTAssertEqual(rig.state("a"), .none)
        rig.ingest("a", c(2, 0, 0, epoch: "e2"))
        XCTAssertEqual(rig.state("a"), .activity)
    }

    func testACounterThatGoesDownReBaselinesSilently() {
        let anomalies: [(String, FocusActivityCounters)] = [
            ("turns", c(4, 3, 1)), ("messages", c(5, 2, 1)), ("problems", c(5, 3, 0)),
            ("one lower, others higher", c(9, 1, 9, last: .stopped)),
        ]
        for (name, lower) in anomalies {
            let rig = makeRig()
            rig.ingest("a", baseline)
            rig.ingest("a", lower)
            XCTAssertEqual(rig.state("a"), .none, "\(name): counters only increase, so this is a re-baseline")
            XCTAssertEqual(rig.store.marks(for: "a"), marks(lower), "\(name): saved := current")
        }
        // and the re-baselined numbers are what later readings are compared with.
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(4, 3, 1))
        rig.ingest("a", c(5, 3, 1))
        XCTAssertEqual(rig.state("a"), .activity, "5 > 4: advanced since the re-baseline")
    }

    // MARK: - What shows, and precedence

    func testCountersAdvancingSinceLastSeenShowTheRightMark() {
        let table: [(String, FocusActivityCounters, FocusActivityState)] = [
            ("turns only", c(6, 3, 1), .activity),
            ("a message", c(6, 4, 1), .unread(count: 1)),
            ("three messages", c(8, 6, 1), .unread(count: 3)),
            ("a problem with a kind", c(6, 3, 2, last: .rateLimited), .problem(.rateLimited)),
            ("a problem with no kind", c(5, 3, 2), .problem(nil)),
            ("a problem of an unknown kind", c(5, 3, 2, last: .unknown), .problem(.unknown)),
        ]
        for (name, current, expected) in table {
            let rig = makeRig()
            rig.ingest("a", baseline)
            rig.ingest("a", current)
            XCTAssertEqual(rig.state("a"), expected, name)
            XCTAssertEqual(rig.state("other"), .none, "a tag it has never heard of shows nothing: \(name)")
        }
    }

    func testPrecedenceThroughTheCoordinator() {
        let rig = makeRig()
        rig.ingest("a", baseline)

        rig.ingest("a", c(6, 3, 1))
        XCTAssertEqual(rig.state("a"), .activity)

        rig.ingest("a", c(7, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1), "UNREAD beats ACTIVITY")

        rig.ingest("a", c(9, 6, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 3), "the count is relative to what was last seen")

        rig.ingest("a", c(10, 6, 2, last: .noText))
        XCTAssertEqual(rig.state("a"), .problem(.noText), "PROBLEM beats UNREAD and ACTIVITY")
    }

    func testEachTagIsEvaluatedOnItsOwn() {
        let rig = makeRig()
        rig.coordinator.ingest([SessionActivityEntry(tag: "a", activity: baseline),
                                SessionActivityEntry(tag: "b", activity: baseline),
                                SessionActivityEntry(tag: "c", activity: baseline)])
        rig.coordinator.ingest([SessionActivityEntry(tag: "a", activity: c(6, 3, 1)),
                                SessionActivityEntry(tag: "b", activity: c(6, 4, 1)),
                                SessionActivityEntry(tag: "c", activity: baseline)])
        XCTAssertEqual(rig.state("a"), .activity)
        XCTAssertEqual(rig.state("b"), .unread(count: 1))
        XCTAssertEqual(rig.state("c"), .none)
    }

    // MARK: - Seen

    func testASeenFocusNeverFlagsAndLeavesNothingBehindWhenItStopsBeingSeen() {
        let rig = makeRig()
        rig.window(1, "a")
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])
        rig.ingest("a", baseline)

        for latest in [c(6, 3, 1), c(7, 4, 1), c(9, 6, 2, last: .crashed)] {
            rig.ingest("a", latest)
            XCTAssertEqual(rig.state("a"), .none, "arrival while seen never flags: \(latest)")
            XCTAssertEqual(rig.store.marks(for: "a"), marks(latest), "and the saved marks follow the counters")
        }

        rig.closeWindow(1)
        XCTAssertEqual(rig.coordinator.seenTags, [])
        XCTAssertEqual(rig.state("a"), .none, "nothing shows once it stops being seen: what arrived, was seen")
        rig.ingest("a", c(9, 6, 2, last: .crashed))
        XCTAssertEqual(rig.state("a"), .none, "even on the next reading")

        rig.ingest("a", c(10, 6, 2))
        XCTAssertEqual(rig.state("a"), .activity, "and only what arrives after that flags")
    }

    func testAFocusThatMovesOnFromASeenWindowKeepsWhatItSaw() {
        let rig = makeRig()
        rig.window(1, "a")
        rig.ingest("a", baseline)
        rig.ingest("a", c(7, 4, 1))
        rig.window(1, "b")                       // the window now shows another focus
        XCTAssertEqual(rig.coordinator.seenTags, ["b"])
        XCTAssertEqual(rig.state("a"), .none)
    }

    /// A sighting that is not "the visible focus of a key window" lets a mark through.
    func testSightingsThatDoNotCountAsSeeingLetTheMarkThrough() {
        let sightings: [(String, FocusWindowSighting)] = [
            ("not the key window", FocusWindowSighting(tag: "a", isKey: false, isVisible: true)),
            ("key but not visible (minimised, occluded or the app hidden)", FocusWindowSighting(tag: "a", isKey: true, isVisible: false)),
            ("neither key nor visible", FocusWindowSighting(tag: "a", isKey: false, isVisible: false)),
            ("showing another focus", FocusWindowSighting(tag: "other", isKey: true, isVisible: true)),
            ("showing no focus", FocusWindowSighting(tag: nil, isKey: true, isVisible: true)),
        ]
        for (name, sighting) in sightings {
            let rig = makeRig()
            rig.ingest("a", baseline)
            rig.coordinator.reportWindow(id: 1, sighting: sighting)
            rig.ingest("a", c(6, 4, 1))
            XCTAssertEqual(rig.state("a"), .unread(count: 1), name)
            XCTAssertFalse(rig.coordinator.seenTags.contains("a"), name)
        }
    }

    func testAKeyVisibleWindowShowingTheFocusIsTheOnlyThingThatCountsAsSeeing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: true, visible: true)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testAWindowGoingKeyOrVisibleLaterStartsSeeing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: false, visible: true)
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))
        rig.window(1, "a", key: true, visible: true)
        XCTAssertEqual(rig.state("a"), .none, "it became the key window: seen")

        let hidden = makeRig()
        hidden.ingest("a", baseline)
        hidden.window(1, "a", key: true, visible: false)
        hidden.ingest("a", c(6, 4, 1))
        XCTAssertEqual(hidden.state("a"), .unread(count: 1))
        hidden.window(1, "a", key: true, visible: true)
        XCTAssertEqual(hidden.state("a"), .none, "it came back on screen: seen")
    }

    func testAWindowThatStopsBeingKeyStopsSeeing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a")
        rig.window(1, "a", key: false)
        XCTAssertEqual(rig.coordinator.seenTags, [])
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))
    }

    // MARK: - Becoming seen clears the marks

    func testBecomingSeenClearsEveryKindOfMark() {
        let flagged: [(String, FocusActivityCounters, FocusActivityState)] = [
            ("activity", c(6, 3, 1), .activity),
            ("unread", c(8, 5, 1), .unread(count: 2)),
            ("problem", c(8, 5, 2, last: .crashed), .problem(.crashed)),
        ]
        for (name, latest, expected) in flagged {
            let rig = makeRig()
            rig.ingest("a", baseline)
            rig.ingest("a", latest)
            XCTAssertEqual(rig.state("a"), expected, "precondition: \(name)")

            rig.window(1, "a")
            XCTAssertEqual(rig.state("a"), .none, "\(name): cleared at once, without waiting for the next reading")
            XCTAssertEqual(rig.store.marks(for: "a"), marks(latest), "\(name): saved := the latest counters it held")

            rig.closeWindow(1)
            XCTAssertEqual(rig.state("a"), .none, "\(name): and it stays cleared")

            // A relaunch reading the same counters has nothing to show either.
            rig.relaunch()
            rig.ingest("a", latest)
            XCTAssertEqual(rig.state("a"), .none, "\(name): the cleared marks were persisted")
        }
    }

    func testBecomingSeenBeforeAnyCountersArrivesIsHarmless() {
        let rig = makeRig()
        rig.window(1, "a")
        XCTAssertEqual(rig.state("a"), .none)
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.store.marks(for: "a"), marks(c(6, 4, 1)))
    }

    func testBecomingSeenClearsOnlyThatFocus() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("b", baseline)
        rig.ingest("a", c(6, 4, 1))
        rig.ingest("b", c(6, 4, 1))
        rig.window(1, "a")
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.state("b"), .unread(count: 1), "b was not looked at")
    }

    // MARK: - Counters that do not arrive

    func testAnOlderDaemonShowsNothingAndNeverWritesMarks() {
        let rig = makeRig()
        rig.coordinator.ingest([SessionActivityEntry(tag: "a", activity: nil), SessionActivityEntry(tag: "b", activity: nil)])
        rig.window(1, "a")
        rig.coordinator.ingest([SessionActivityEntry(tag: "a", activity: nil)])
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.state("b"), .none)
        XCTAssertTrue(rig.store.tags.isEmpty, "no counters means nothing to remember")
        XCTAssertTrue(rig.persisted().tags.isEmpty)
    }

    func testATagThatHadMarksAndThenArrivesWithoutCountersKeepsItsSavedMarksButShowsNothing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))

        rig.ingest("a", nil)
        XCTAssertEqual(rig.state("a"), .none, "no counters: nothing to show")
        XCTAssertEqual(rig.store.marks(for: "a"), marks(baseline), "the saved marks are untouched")

        // The counters come back: what advanced since the saved marks shows again.
        rig.ingest("a", c(7, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))
    }

    func testATagMissingFromALaterIngestLosesItsStateButKeepsItsSavedMarks() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))

        rig.coordinator.ingest([])
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.store.marks(for: "a"), marks(baseline))

        rig.coordinator.ingest([SessionActivityEntry(tag: "other", activity: baseline)])
        XCTAssertEqual(rig.state("a"), .none)

        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1), "back, and still unread relative to the saved marks")
    }

    // MARK: - Relaunch

    func testARelaunchOnTheSameEpochShowsWhatAdvancedWhileTheAppWasClosed() {
        let table: [(String, FocusActivityCounters, FocusActivityState)] = [
            ("activity", c(7, 3, 1), .activity),
            ("unread", c(7, 5, 1), .unread(count: 2)),
            ("problem", c(7, 5, 2, last: .loginHold), .problem(.loginHold)),
            ("nothing", c(5, 3, 1), .none),
        ]
        for (name, whileClosed, expected) in table {
            let rig = makeRig()
            rig.ingest("a", baseline)
            rig.relaunch()
            XCTAssertEqual(rig.state("a"), .none, "a new coordinator starts with no readings: \(name)")
            rig.ingest("a", whileClosed)
            XCTAssertEqual(rig.state("a"), expected, name)
        }
    }

    func testARelaunchWithADifferentEpochShowsNothing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.relaunch()
        rig.ingest("a", c(50, 40, 30, epoch: "after-a-daemon-restart", last: .crashed))
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testARelaunchWithTheFocusSeenWhenItWasSavedShowsNothing() {
        let rig = makeRig()
        rig.window(1, "a")
        rig.ingest("a", baseline)
        rig.ingest("a", c(9, 6, 2, last: .crashed))        // seen while it arrived: saved follows
        rig.relaunch()
        rig.ingest("a", c(9, 6, 2, last: .crashed))
        XCTAssertEqual(rig.state("a"), .none)
        rig.ingest("a", c(10, 6, 2))
        XCTAssertEqual(rig.state("a"), .activity)
    }

    // MARK: - Several windows

    func testOnlyTheKeyWindowSeesAFocus() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: false)
        rig.window(2, "a", key: false)
        XCTAssertEqual(rig.coordinator.seenTags, [], "no key window: not seen anywhere")
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))

        rig.window(2, "a", key: true)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testTheSameFocusInTwoWindowsIsSeenWhileEitherIsKeyAndVisible() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: true)
        rig.window(2, "a", key: false)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])

        rig.window(1, "a", key: false)
        rig.window(2, "a", key: true)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"], "the other window took over as key")
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testClosingTheSeeingWindowEndsTheSeeing() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: true)
        rig.window(2, "a", key: false)
        rig.closeWindow(1)
        XCTAssertEqual(rig.coordinator.seenTags, [], "the other window is not key")
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))
    }

    func testAFocusIsStillSeenInASecondWindowAfterTheFirstCloses() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: true)
        rig.window(2, "a", key: true)
        rig.closeWindow(1)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testWithTwoDifferentFocusesOnlyTheOneInTheKeyWindowIsSeen() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("b", baseline)
        rig.window(1, "a", key: true)
        rig.window(2, "b", key: false)
        XCTAssertEqual(rig.coordinator.seenTags, ["a"])

        rig.ingest("a", c(6, 4, 1))
        rig.ingest("b", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.state("b"), .unread(count: 1))

        // Focus moves to the other window.
        rig.window(1, "a", key: false)
        rig.window(2, "b", key: true)
        XCTAssertEqual(rig.coordinator.seenTags, ["b"])
        XCTAssertEqual(rig.state("b"), .none, "b is now looked at")
        rig.ingest("a", c(7, 4, 1))
        XCTAssertEqual(rig.state("a"), .activity, "and a is not")
    }

    func testAMinimisedKeyWindowDoesNotCountEvenWhileAnotherWindowShowsTheFocusWithoutBeingKey() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.window(1, "a", key: true, visible: false)
        rig.window(2, "a", key: false, visible: true)
        XCTAssertEqual(rig.coordinator.seenTags, [])
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .unread(count: 1))
    }

    func testReportingTheSameWindowAgainReplacesItsSighting() {
        let rig = makeRig()
        rig.window(1, "a")
        rig.window(1, "b")
        XCTAssertEqual(rig.coordinator.seenTags, ["b"], "one window shows one focus at a time")
    }

    // MARK: - Callbacks and changes

    func testChangesFiresOnARealChangeAndNotOnARepeatedIdenticalIngest() {
        let rig = makeRig()
        var count = 0
        let sub = rig.coordinator.changes.sink { count += 1 }
        defer { sub.cancel() }

        rig.ingest("a", baseline)
        let afterBaseline = count

        rig.ingest("a", c(6, 3, 1))
        XCTAssertEqual(count, afterBaseline + 1, "none -> activity is a change")

        rig.ingest("a", c(6, 3, 1))
        rig.ingest("a", c(6, 3, 1))
        XCTAssertEqual(count, afterBaseline + 1, "the same reading again changes nothing, so nothing is published")

        rig.ingest("a", c(7, 4, 1))
        XCTAssertEqual(count, afterBaseline + 2, "activity -> unread is a change")

        rig.ingest("a", c(9, 4, 1))
        XCTAssertEqual(count, afterBaseline + 2, "more turns, same mark: no change")

        rig.ingest("a", c(9, 5, 1))
        XCTAssertEqual(count, afterBaseline + 3, "unread(1) -> unread(2) is a change")
    }

    func testChangesFiresWhenBecomingSeenClearsAMarkAndNotWhenThereWasNoMark() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        var count = 0
        let sub = rig.coordinator.changes.sink { count += 1 }
        defer { sub.cancel() }

        rig.window(1, "a")
        XCTAssertGreaterThanOrEqual(count, 1, "unread -> none")
        let afterClear = count

        rig.ingest("a", c(7, 5, 1))
        XCTAssertEqual(count, afterClear, "arrival while seen leaves the state at none: no change")
        rig.closeWindow(1)
        XCTAssertEqual(count, afterClear, "closing the window changes no state")
    }

    func testChangesFiresWhenAFocusIsForgottenWhileItShowedAMark() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        var count = 0
        let sub = rig.coordinator.changes.sink { count += 1 }
        defer { sub.cancel() }
        rig.coordinator.forget(tag: "a")
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertEqual(rig.state("a"), .none)
    }

    func testOnFocusBecameSeenFiresWithTheTagExactlyWhenATagNewlyBecomesSeen() {
        let rig = makeRig()
        var tags: [String] = []
        rig.coordinator.onFocusBecameSeen = { tags.append($0) }

        rig.window(1, "a", key: false)
        rig.window(2, "a", key: true, visible: false)
        rig.window(3, nil, key: true)
        XCTAssertEqual(tags, [], "none of those is a key, visible window showing a focus")

        rig.window(1, "a", key: true)
        XCTAssertEqual(tags, ["a"])

        rig.window(1, "a", key: true)
        XCTAssertEqual(tags, ["a"], "the same sighting again is not news")

        rig.window(2, "a", key: true)
        XCTAssertEqual(tags, ["a"], "already seen by the first window: not newly seen")

        rig.closeWindow(1)
        XCTAssertEqual(tags, ["a"], "still seen through window 2")

        rig.closeWindow(2)
        rig.window(1, "a", key: true)
        XCTAssertEqual(tags, ["a", "a"], "seen again after it had stopped")

        rig.window(1, "b", key: true)
        XCTAssertEqual(tags, ["a", "a", "b"], "the window moved to another focus")

        rig.window(1, "b", key: false)
        rig.window(1, "b", key: true)
        XCTAssertEqual(tags, ["a", "a", "b", "b"], "went away from key and came back")
    }

    func testOnFocusBecameSeenIsCalledAfterTheMarkHasBeenCleared() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        var stateInsideTheCallback: FocusActivityState?
        var seenInsideTheCallback: Set<String>?
        rig.coordinator.onFocusBecameSeen = { [unowned rig] tag in
            stateInsideTheCallback = rig.state(tag)
            seenInsideTheCallback = rig.coordinator.seenTags
        }
        rig.window(1, "a")
        XCTAssertEqual(stateInsideTheCallback, FocusActivityState.none, "listeners see the cleared state")
        XCTAssertEqual(seenInsideTheCallback, ["a"])
    }

    func testOnAnyWindowVisibleChangedFiresOnlyWhenTheAnyVisibleFlagFlips() {
        let rig = makeRig()
        var flips: [Bool] = []
        rig.coordinator.onAnyWindowVisibleChanged = { flips.append($0) }
        XCTAssertFalse(rig.coordinator.anyWindowVisible)

        rig.window(1, "a", key: false, visible: false)
        XCTAssertEqual(flips, [], "an invisible window is not a visible one")
        XCTAssertFalse(rig.coordinator.anyWindowVisible)

        rig.window(1, "a", key: false, visible: true)
        XCTAssertEqual(flips, [true], "visible does not need key")
        XCTAssertTrue(rig.coordinator.anyWindowVisible)

        rig.window(1, "a", key: true, visible: true)
        rig.window(2, nil, key: false, visible: true)
        XCTAssertEqual(flips, [true], "more visible windows: still just 'some window is visible'")

        rig.closeWindow(1)
        XCTAssertEqual(flips, [true])
        XCTAssertTrue(rig.coordinator.anyWindowVisible, "window 2 is still visible")

        rig.window(2, nil, key: false, visible: false)
        XCTAssertEqual(flips, [true, false])
        XCTAssertFalse(rig.coordinator.anyWindowVisible)

        rig.window(3, "b", key: true, visible: true)
        rig.closeWindow(3)
        XCTAssertEqual(flips, [true, false, true, false], "a window that closes while visible flips it off")
    }

    // MARK: - Forget

    func testForgetClearsTheStateTheCountersAndThePersistedMarks() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("b", baseline)
        rig.ingest("a", c(6, 4, 1))
        rig.ingest("b", c(6, 4, 1))

        rig.coordinator.forget(tag: "a")
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertNil(rig.store.marks(for: "a"), "the saved marks go with the focus")
        XCTAssertNil(rig.persisted().marks(for: "a"), "and from the defaults")
        XCTAssertEqual(rig.state("b"), .unread(count: 1), "another focus is untouched")
        XCTAssertNotNil(rig.persisted().marks(for: "b"))

        // A new run that sees the same advanced counters baselines again: the old marks are gone.
        rig.relaunch()
        rig.ingest("a", c(6, 4, 1))
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertEqual(rig.store.marks(for: "a"), marks(c(6, 4, 1)))
    }

    func testAForgottenFocusLosesItsCountersSoALaterWindowFindsNothingToClearAndNothingBreaks() {
        let rig = makeRig()
        rig.ingest("a", baseline)
        rig.ingest("a", c(6, 4, 1))
        rig.coordinator.forget(tag: "a")
        rig.window(1, "a")
        XCTAssertEqual(rig.state("a"), .none)
        XCTAssertNil(rig.store.marks(for: "a"), "forgotten, with no counters held, nothing is saved by looking at it")
    }

    func testForgettingATagItNeverHeardOfIsHarmless() {
        let rig = makeRig()
        rig.coordinator.forget(tag: "never-seen")
        XCTAssertEqual(rig.state("never-seen"), .none)
    }

    // MARK: - The cap

    func testTheTwoHundredTagCapGoesThroughToTheStore() {
        let rig = makeRig()
        for i in 0 ... 200 { rig.ingest("t\(i)", baseline) }
        XCTAssertEqual(rig.store.tags.count, FocusSeenStore.capacity)
        XCTAssertEqual(rig.store.tags.count, 200)
        XCTAssertNil(rig.store.marks(for: "t0"), "the first-saved is the one that went")
        XCTAssertNotNil(rig.store.marks(for: "t200"))
        XCTAssertEqual(rig.persisted().tags.count, 200)
    }

    func testATagDroppedByTheCapBaselinesSilentlyAgainInsteadOfFlagging() {
        let rig = makeRig()
        for i in 0 ... 200 { rig.ingest("t\(i)", baseline) }       // t0's marks are dropped
        rig.ingest("t0", c(9, 9, 9, last: .crashed))
        XCTAssertEqual(rig.state("t0"), .none, "no saved marks: a first sight, never a mark")
    }

    // MARK: - isVisible

    func testIsVisibleIsTrueOnlyForAVisibleUnminimisedUnoccludedWindowInAVisibleApp() {
        for windowVisible in [false, true] {
            for miniaturized in [false, true] {
                for occluded in [false, true] {
                    for appHidden in [false, true] {
                        let expected = windowVisible && !miniaturized && !occluded && !appHidden
                        XCTAssertEqual(
                            FocusActivityCoordinator.isVisible(windowVisible: windowVisible, miniaturized: miniaturized,
                                                               occluded: occluded, appHidden: appHidden),
                            expected,
                            "windowVisible \(windowVisible), miniaturized \(miniaturized), occluded \(occluded), appHidden \(appHidden)")
                    }
                }
            }
        }
    }
}
