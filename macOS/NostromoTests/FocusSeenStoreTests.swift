import XCTest
import Foundation
import NostromoKit

// What the operator last saw of each focus, kept across app relaunches.
//
// `FocusSeenStore` is the Mac app's own bookkeeping (UserDefaults, one key): per focus tag, the activity
// epoch and the three counters at the moment the focus was last looked at. It is bounded (200 tags, the
// least recently SAVED dropped first) and it must survive garbage: a corrupt value is "nothing saved",
// which only ever means a silent re-baseline, never a crash and never a false mark.
//
// Logic test (no host app, no `@testable import`): the type is compiled into this target directly. Every
// store here runs on its own throwaway `UserDefaults` suite; the real defaults are never touched.
//
// Mutations caught here: (cap) a cap of 199 or 201 -> testTheCapIsExactlyTwoHundred; (recency) reads
// refreshing the LRU -> testReadingATagDoesNotProtectItFromTheCap; saves not refreshing -> testSavingAgain...

final class FocusSeenStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.removeSuite(named: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A clock that moves one second on every look at it, so every save is strictly later than the last.
    private final class Clock {
        private var t: TimeInterval = 1_000_000
        func now() -> Date { t += 1; return Date(timeIntervalSince1970: t) }
    }

    private func makeStore(_ clock: Clock = Clock()) -> FocusSeenStore {
        FocusSeenStore(defaults: defaults, now: { clock.now() })
    }

    private func marks(_ n: UInt64 = 1, epoch: String = "e1") -> FocusSeenMarks {
        FocusSeenMarks(epoch: epoch, turns: n, messages: n + 1, problems: n + 2)
    }

    // MARK: - Constants

    func testTheKeyAndCapAreTheSpecifiedOnes() {
        XCTAssertEqual(FocusSeenStore.defaultsKey, "nostromo.focus.activity.seen")
        XCTAssertEqual(FocusSeenStore.capacity, 200)
    }

    // MARK: - Basics

    func testAFreshStoreHasNothing() {
        let store = makeStore()
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertNil(store.marks(for: "cody-a"))
    }

    func testSavedMarksAreReadBackAndOverwrittenBySavingAgain() {
        let store = makeStore()
        store.save(marks(1), for: "cody-a")
        XCTAssertEqual(store.marks(for: "cody-a"), marks(1))
        store.save(marks(9, epoch: "e2"), for: "cody-a")
        XCTAssertEqual(store.marks(for: "cody-a"), marks(9, epoch: "e2"))
        XCTAssertEqual(store.tags, ["cody-a"])
    }

    func testTwoTagsAreIndependent() {
        let store = makeStore()
        store.save(marks(1), for: "a")
        store.save(marks(2), for: "b")
        XCTAssertEqual(store.marks(for: "a"), marks(1))
        XCTAssertEqual(store.marks(for: "b"), marks(2))
        store.save(marks(3), for: "a")
        XCTAssertEqual(store.marks(for: "b"), marks(2), "saving a leaves b alone")
        XCTAssertEqual(store.tags, ["a", "b"])
    }

    // MARK: - Persistence

    func testMarksSurviveARelaunchOnTheSameDefaults() {
        let first = makeStore()
        first.save(FocusSeenMarks(epoch: "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f", turns: 12, messages: 7, problems: 3), for: "cody-a")
        first.save(marks(5, epoch: "other"), for: "cody-b")

        let second = makeStore()
        XCTAssertEqual(second.marks(for: "cody-a"),
                       FocusSeenMarks(epoch: "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f", turns: 12, messages: 7, problems: 3))
        XCTAssertEqual(second.marks(for: "cody-b"), marks(5, epoch: "other"))
        XCTAssertEqual(second.tags, ["cody-a", "cody-b"])
    }

    func testCountersAboveInt32AndAnAwkwardEpochRoundTripExactly() {
        let big = FocusSeenMarks(epoch: "épöch ✓ \"quoted\" / slash \\ back", turns: 5_000_000_000,
                                 messages: 4_294_967_296, problems: 9_007_199_254_740_993)
        makeStore().save(big, for: "cody-a")
        XCTAssertEqual(makeStore().marks(for: "cody-a"), big)
    }

    func testZeroCountersRoundTrip() {
        let zero = FocusSeenMarks(epoch: "e", turns: 0, messages: 0, problems: 0)
        makeStore().save(zero, for: "cody-a")
        XCTAssertEqual(makeStore().marks(for: "cody-a"), zero, "a saved zero is a saved value, not absence")
    }

    func testSavingWritesOnlyUnderTheOneKey() {
        let store = makeStore()
        store.save(marks(1), for: "a")
        store.save(marks(2), for: "b")
        store.forget(tag: "a")
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(domain.keys), [FocusSeenStore.defaultsKey], "nothing else may be written")
    }

    // MARK: - Corrupt data

    func testGarbageStoredUnderTheKeyIsIgnored() {
        let garbage: [Any] = [
            "not what we wrote",
            Data([0xff, 0x00, 0x13, 0x37]),
            42,
            3.14,
            true,
            [1, 2, 3],
            ["a", "b"],
            ["cody-a": "a string where a record belongs"],
            ["cody-a": ["turns": "x"]],
            ["cody-a": [String: Any]()],
            ["cody-a": 5],
            [String: Any](),
        ]
        for value in garbage {
            defaults.set(value, forKey: FocusSeenStore.defaultsKey)
            let store = makeStore()
            XCTAssertNil(store.marks(for: "cody-a"), "garbage \(value) must read as nothing saved")
            XCTAssertTrue(store.tags.isEmpty, "garbage \(value)")
        }
    }

    func testAStoreThatReadGarbageStillWorksAndOverwritesIt() {
        defaults.set("garbage", forKey: FocusSeenStore.defaultsKey)
        let store = makeStore()
        store.save(marks(4), for: "cody-a")
        XCTAssertEqual(store.marks(for: "cody-a"), marks(4))
        XCTAssertEqual(makeStore().marks(for: "cody-a"), marks(4), "and what it saved is what a relaunch reads")
    }

    // MARK: - The cap

    func testTheCapIsExactlyTwoHundred() {
        let store = makeStore()
        for i in 0 ..< 200 { store.save(marks(UInt64(i)), for: "t\(i)") }
        XCTAssertEqual(store.tags.count, 200, "200 fit")
        XCTAssertNotNil(store.marks(for: "t0"))

        store.save(marks(999), for: "t200")
        XCTAssertEqual(store.tags.count, 200, "the 201st evicts one")
        XCTAssertNil(store.marks(for: "t0"), "the least recently saved is the one that goes")
        XCTAssertEqual(store.marks(for: "t1"), marks(1))
        XCTAssertEqual(store.marks(for: "t200"), marks(999))
    }

    func testTheCapHoldsOnDiskTooAndForAFreshStore() {
        let store = makeStore()
        for i in 0 ..< 230 { store.save(marks(UInt64(i)), for: "t\(i)") }
        XCTAssertEqual(store.tags.count, 200)
        let fresh = makeStore()
        XCTAssertEqual(fresh.tags.count, 200)
        XCTAssertEqual(fresh.tags, Set((30 ..< 230).map { "t\($0)" }), "exactly the 200 most recently saved")
    }

    func testSavingAnExistingTagMakesItTheMostRecentSoAnotherIsDropped() {
        let store = makeStore()
        for i in 0 ..< 200 { store.save(marks(UInt64(i)), for: "t\(i)") }
        store.save(marks(500), for: "t0")                  // t0 was the oldest; now the newest
        store.save(marks(501), for: "fresh")
        XCTAssertEqual(store.tags.count, 200)
        XCTAssertEqual(store.marks(for: "t0"), marks(500), "re-saved, so it stays")
        XCTAssertNil(store.marks(for: "t1"), "the next oldest went instead")
        XCTAssertNotNil(store.marks(for: "t2"))
    }

    func testReadingATagDoesNotProtectItFromTheCap() {
        let store = makeStore()
        for i in 0 ..< 200 { store.save(marks(UInt64(i)), for: "t\(i)") }
        for _ in 0 ..< 5 { XCTAssertNotNil(store.marks(for: "t0")) }
        _ = store.tags
        store.save(marks(501), for: "fresh")
        XCTAssertNil(store.marks(for: "t0"), "a read is not a use: t0 is still the least recently saved")
        XCTAssertNotNil(store.marks(for: "t1"))
    }

    func testTheOrderOfSavesSurvivesARelaunchSoTheCapStillDropsTheOldest() {
        let clock = Clock()
        let first = makeStore(clock)
        for i in 0 ..< 200 { first.save(marks(UInt64(i)), for: "t\(i)") }
        first.save(marks(500), for: "t0")                  // t1 is now the oldest

        let second = makeStore(clock)
        second.save(marks(501), for: "fresh")
        XCTAssertNil(second.marks(for: "t1"), "the oldest by save order goes, not an arbitrary entry")
        XCTAssertEqual(second.marks(for: "t0"), marks(500))
        XCTAssertEqual(second.tags.count, 200)
    }

    // MARK: - Forget

    func testForgetRemovesTheTagFromMemoryAndFromAFreshStore() {
        let store = makeStore()
        store.save(marks(1), for: "a")
        store.save(marks(2), for: "b")
        store.forget(tag: "a")
        XCTAssertNil(store.marks(for: "a"))
        XCTAssertEqual(store.tags, ["b"])
        XCTAssertEqual(store.marks(for: "b"), marks(2), "the other tag is untouched")

        let fresh = makeStore()
        XCTAssertNil(fresh.marks(for: "a"), "gone from disk too")
        XCTAssertEqual(fresh.marks(for: "b"), marks(2))
    }

    func testForgettingATagThatIsNotThereIsHarmless() {
        let store = makeStore()
        store.save(marks(1), for: "a")
        store.forget(tag: "ghost")
        store.forget(tag: "a")
        store.forget(tag: "a")
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(makeStore().tags.isEmpty)
    }

    func testAForgottenTagCanBeSavedAgain() {
        let store = makeStore()
        store.save(marks(1), for: "a")
        store.forget(tag: "a")
        store.save(marks(7), for: "a")
        XCTAssertEqual(makeStore().marks(for: "a"), marks(7))
    }
}
