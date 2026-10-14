import XCTest
import Combine

// RED tests for `TranscriptFoldStore` (FV1). Source of truth: design contract
// `.claude/plans/transcript-focus-view-design-contract.md` §0 (D1), §2.2
// (mode-change semantics), §2.4 (persistence). `TranscriptFoldStore` is compiled into this
// target directly (logic test — no host app).
//
// Conventions enforced here, per the repo's test rules:
//  - never the real ~/.nostromo: every store gets a temp-dir file URL;
//  - never UserDefaults.standard: a per-test suite, removed in tearDown;
//  - no wall-clock sleeps: a recording fake `WorkScheduler` and a fake clock;
//  - the store encodes off-main, so "the write finished" is observed through
//    the store's `onWriteCompleted` (main queue) hook and `writeCount`,
//    never by sleeping.
//
// API assumed beyond the contract's sketch (see the report to Cody):
//  - `private(set) var writeCount: Int` — number of completed file writes;
//  - `var onWriteCompleted: (() -> Void)?` — called on the main queue after
//    each write completes, with `writeCount` already incremented;
//  - `init(fileURL:defaults:scheduler:now:)`, the `now` clock stamping `touched`;
//  - the debounce delay handed to `WorkScheduler.schedule` is 1 second.

// MARK: - Fakes

/// Records scheduled work instead of running it; `fire()` runs everything
/// that is still pending (not cancelled) exactly once.
private final class FakeScheduler {
    private final class Entry {
        let delay: TimeInterval
        let work: () -> Void
        var cancelled = false
        init(delay: TimeInterval, work: @escaping () -> Void) { self.delay = delay; self.work = work }
    }

    private var entries: [Entry] = []
    private(set) var scheduleCount = 0

    var scheduler: WorkScheduler {
        WorkScheduler { [self] delay, work in
            scheduleCount += 1
            let entry = Entry(delay: delay, work: work)
            entries.append(entry)
            return { entry.cancelled = true }
        }
    }

    var pendingCount: Int { entries.filter { !$0.cancelled }.count }
    var pendingDelays: [TimeInterval] { entries.filter { !$0.cancelled }.map(\.delay) }

    /// Runs and clears the pending work.
    func fire() {
        let live = entries.filter { !$0.cancelled }
        entries.removeAll()
        for entry in live { entry.work() }
    }
}

private final class FakeClock {
    private(set) var current = Date(timeIntervalSince1970: 1_760_000_000)
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval = 1) { current = current.addingTimeInterval(seconds) }
}

/// Collects `changes`. Keys and tags are sorted so order-unspecified payloads compare equal.
private final class ChangeRecorder {
    private(set) var events: [FoldStoreChange] = []
    private var sub: AnyCancellable?

    init(_ store: TranscriptFoldStore) {
        sub = store.changes.sink { [weak self] in self?.events.append($0) }
    }

    var normalized: [FoldStoreChange] { events.map(Self.normalize) }
    func reset() { events.removeAll() }

    static func normalize(_ e: FoldStoreChange) -> FoldStoreChange {
        switch e {
        case .folds(let tag, let keys): return .folds(tag: tag, keys: keys.sorted())
        case .mode(let tags):           return .mode(tags: tags.sorted())
        case .defaultMode:              return .defaultMode
        }
    }
}

/// One store plus everything injected into it.
private final class Rig {
    let url: URL
    let defaults: UserDefaults
    let sched = FakeScheduler()
    let clock: FakeClock
    let store: TranscriptFoldStore
    let recorder: ChangeRecorder

    init(url: URL, defaults: UserDefaults, clock: FakeClock = FakeClock()) {
        self.url = url
        self.defaults = defaults
        self.clock = clock
        store = TranscriptFoldStore(fileURL: url, defaults: defaults, scheduler: sched.scheduler,
                                    now: { [clock] in clock.now() })
        recorder = ChangeRecorder(store)
    }
}

// MARK: - Tests

final class TranscriptFoldStoreTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        tempDirs = []
        suiteNames = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-fold-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeDefaults() -> UserDefaults {
        let name = "test.TranscriptFoldStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private var defaultViewKey: String { "nostromo.transcript.defaultView" }

    private func makeRig(url: URL? = nil, defaults: UserDefaults? = nil, clock: FakeClock = FakeClock()) throws -> Rig {
        let fileURL = try url ?? makeDir().appendingPathComponent("transcript-folds.v1.json")
        return Rig(url: fileURL, defaults: defaults ?? makeDefaults(), clock: clock)
    }

    /// A fresh store over the same file and defaults — a relaunch.
    private func relaunch(_ rig: Rig) -> Rig {
        Rig(url: rig.url, defaults: rig.defaults)
    }

    /// Fires the debounce scheduler once and waits (bounded, no sleeping) for the write to land.
    private func flushWrite(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard rig.sched.pendingCount > 0 else {
            XCTFail("expected a pending debounced write, but nothing was scheduled", file: file, line: line)
            return
        }
        let done = expectation(description: "store write completed")
        done.assertForOverFulfill = false
        rig.store.onWriteCompleted = { done.fulfill() }
        rig.sched.fire()
        wait(for: [done], timeout: 10)
        rig.store.onWriteCompleted = nil
    }

    private func fold(_ rig: Rig, _ tag: String, _ key: String) -> (open: Bool, origin: FoldOrigin)? {
        rig.store.foldState(tag: tag, key: key)
    }

    private func corruptSiblings(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                    includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    // MARK: 1. Relaunch round trip

    func testFoldsResultsAndExplicitModeSurviveARelaunch() throws {
        let rig = try makeRig()
        let s = rig.store
        // Modes first: a mode change starts the tag's folds afresh (§2.2).
        s.setMode(tag: "claudia-AAAA", .allActivity)
        s.setMode(tag: "cody-BBBB", .focus)
        s.setFold(tag: "claudia-AAAA", key: "a:g:toolu_01", turnKey: "turn-1", open: true, origin: .user)
        s.setFold(tag: "claudia-AAAA", key: "g:toolu_02", turnKey: "turn-1", open: false, origin: .auto)
        s.setResult(tag: "claudia-AAAA", key: "r:toolu_03", turnKey: "turn-2", open: true)
        s.setResult(tag: "cody-BBBB", key: "r:toolu_04", turnKey: "turn-9", open: false)
        flushWrite(rig)

        let reopened = relaunch(rig)
        XCTAssertEqual(fold(reopened, "claudia-AAAA", "a:g:toolu_01")?.open, true)
        XCTAssertEqual(fold(reopened, "claudia-AAAA", "a:g:toolu_01")?.origin, .user)
        XCTAssertEqual(fold(reopened, "claudia-AAAA", "g:toolu_02")?.open, false)
        XCTAssertEqual(fold(reopened, "claudia-AAAA", "g:toolu_02")?.origin, .auto)
        XCTAssertEqual(reopened.store.resultState(tag: "claudia-AAAA", key: "r:toolu_03"), true)
        XCTAssertEqual(reopened.store.resultState(tag: "cody-BBBB", key: "r:toolu_04"), false)
        XCTAssertEqual(reopened.store.explicitMode(tag: "claudia-AAAA"), .allActivity)
        XCTAssertEqual(reopened.store.explicitMode(tag: "cody-BBBB"), .focus,
                       "an explicit choice equal to the default is still explicit after relaunch (D1)")
        XCTAssertNil(fold(reopened, "cody-BBBB", "a:g:toolu_01"), "entries stay per tag")
        XCTAssertNil(reopened.store.resultState(tag: "claudia-AAAA", key: "r:nope"))
    }

    func testATagWithNoExplicitModeStillHasNoneAfterARelaunch() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "t1", key: "a:k", turnKey: "turn", open: true, origin: .user)
        flushWrite(rig)

        let reopened = relaunch(rig)
        XCTAssertNil(reopened.store.explicitMode(tag: "t1"))
        XCTAssertEqual(reopened.store.mode(tag: "t1"), reopened.store.defaultMode)
    }

    // MARK: 2. Clear Context / new session (F3) — nothing resets fold state

    /// `newSession()` (Clear Context) must leave the tag's mode and folds
    /// alone (F3 / D1: mode survives Clear Context and a new Claude session
    /// in the same focus). The store has no "clear" entry point on purpose, so
    /// the guard is that `newSession` never reaches for it.
    func testNewSessionDoesNotTouchTheFoldStore() throws {
        let source = try Self.source("Nostromo/Data/ChatSession.swift")
        let body = try Self.functionBody("func newSession()", in: source, fileName: "ChatSession.swift")
        XCTAssertFalse(body.contains("TranscriptFoldStore"), """
            ChatSession.newSession() must not touch TranscriptFoldStore: a Clear Context keeps the \
            focus's Focus/All-activity mode and its fold states (design contract §2.4, "Not cleared \
            on .cleared (F3)").
            """)
    }

    func testChatSessionNeverRemovesAFocusFromTheFoldStore() throws {
        let source = try Self.source("Nostromo/Data/ChatSession.swift")
        XCTAssertFalse(source.contains("removeFocus"), """
            ChatSession.swift must never call TranscriptFoldStore.removeFocus — that is for a \
            removed FOCUS only (AppStore.evictPerFocusState). A session ending, being replaced or \
            being cleared leaves the focus, and its fold state, in place.
            """)
    }

    func testRemoveFocusIsCalledOnlyFromTheAppStoreEvictionPath() throws {
        let root = try Self.sourceRoot().appendingPathComponent("Nostromo")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "AppStore.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("TranscriptFoldStore.shared.removeFocus") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "removeFocus must only be called from AppStore.evictPerFocusState")
    }

    // MARK: 3. Default semantics (D1)

    func testAMissingDefaultViewValueReadsAsFocus() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.store.defaultMode, .focus)
        XCTAssertEqual(rig.store.mode(tag: "t1"), .focus)
    }

    func testAGarbageDefaultViewValueReadsAsFocus() throws {
        for garbage: Any in ["bogus", "", 42, true, "ALLACTIVITY"] {
            let defaults = makeDefaults()
            defaults.set(garbage, forKey: defaultViewKey)
            let rig = try makeRig(defaults: defaults)
            XCTAssertEqual(rig.store.defaultMode, .focus, "\(garbage) must read as .focus")
            XCTAssertEqual(rig.store.mode(tag: "t1"), .focus)
        }
    }

    func testTheDefaultModeIsStoredUnderTheDocumentedKeyAndSurvivesARelaunch() throws {
        let rig = try makeRig()
        rig.store.defaultMode = .allActivity
        XCTAssertEqual(rig.defaults.string(forKey: defaultViewKey), "allActivity")

        XCTAssertEqual(relaunch(rig).store.defaultMode, .allActivity)

        rig.store.defaultMode = .focus
        XCTAssertEqual(rig.defaults.string(forKey: defaultViewKey), "focus")
    }

    func testAFocusWithNoExplicitModeFollowsTheDefaultAsItChanges() throws {
        let rig = try makeRig()
        XCTAssertNil(rig.store.explicitMode(tag: "t1"))
        XCTAssertEqual(rig.store.mode(tag: "t1"), .focus)

        rig.store.defaultMode = .allActivity
        XCTAssertEqual(rig.store.mode(tag: "t1"), .allActivity)
        XCTAssertNil(rig.store.explicitMode(tag: "t1"), "following the default is not an explicit choice")

        rig.store.defaultMode = .focus
        XCTAssertEqual(rig.store.mode(tag: "t1"), .focus)
    }

    func testAnExplicitModeIsUnaffectedByDefaultChangesWhetherOrNotItEqualsTheDefault() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "same", .focus)            // equals the default (.focus): still explicit
        rig.store.setMode(tag: "other", .allActivity)     // differs from the default

        rig.store.defaultMode = .allActivity
        XCTAssertEqual(rig.store.mode(tag: "same"), .focus, "explicit-equal must not flip when the default changes")
        XCTAssertEqual(rig.store.mode(tag: "other"), .allActivity)

        rig.store.defaultMode = .focus
        XCTAssertEqual(rig.store.mode(tag: "same"), .focus)
        XCTAssertEqual(rig.store.mode(tag: "other"), .allActivity, "explicit-unequal must not flip either")
        XCTAssertEqual(rig.store.explicitMode(tag: "same"), .focus)
        XCTAssertEqual(rig.store.explicitMode(tag: "other"), .allActivity)
    }

    func testClearingAnExplicitModeReturnsTheFocusToFollowingTheDefault() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "t1", .allActivity)
        XCTAssertEqual(rig.store.mode(tag: "t1"), .allActivity)

        rig.store.clearMode(tag: "t1")
        XCTAssertNil(rig.store.explicitMode(tag: "t1"))
        XCTAssertEqual(rig.store.mode(tag: "t1"), .focus, "back on the default")

        rig.store.defaultMode = .allActivity
        XCTAssertEqual(rig.store.mode(tag: "t1"), .allActivity, "and it follows the default again")
    }

    func testReadingAModeNeverSchedulesAWrite() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "t1", .allActivity)
        flushWrite(rig)
        let scheduledBefore = rig.sched.scheduleCount

        _ = rig.store.mode(tag: "t1")
        _ = rig.store.mode(tag: "never-seen")
        _ = rig.store.explicitMode(tag: "t1")

        XCTAssertEqual(rig.sched.scheduleCount, scheduledBefore,
                       "reading a mode on focus open touches it in memory only (§2.4) — no write")
        XCTAssertEqual(rig.sched.pendingCount, 0)
    }

    // MARK: 4. Mode change sets folds (§2.2)

    func testSettingAModeDropsThatTagsFoldEntriesButNotItsResultsAndNotOtherTags() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setFold(tag: "A", key: "a:user", turnKey: "t1", open: true, origin: .user)
        s.setFold(tag: "A", key: "g:auto", turnKey: "t1", open: true, origin: .auto)
        s.setResult(tag: "A", key: "r:one", turnKey: "t1", open: true)
        s.setFold(tag: "B", key: "a:user", turnKey: "t1", open: true, origin: .user)
        s.setFold(tag: "B", key: "g:auto", turnKey: "t1", open: true, origin: .auto)
        s.setResult(tag: "B", key: "r:one", turnKey: "t1", open: true)

        s.setMode(tag: "A", .allActivity)

        XCTAssertNil(fold(rig, "A", "a:user"), "explicit fold entries die with a mode change")
        XCTAssertNil(fold(rig, "A", "g:auto"), "auto fold entries die with a mode change")
        XCTAssertEqual(s.resultState(tag: "A", key: "r:one"), true, "result entries are not fold entries (§2.2)")
        XCTAssertEqual(fold(rig, "B", "a:user")?.open, true, "other tags are untouched")
        XCTAssertEqual(fold(rig, "B", "g:auto")?.open, true)
        XCTAssertEqual(s.resultState(tag: "B", key: "r:one"), true)
        XCTAssertNil(s.explicitMode(tag: "B"))
    }

    func testChangingAModeBackAlsoDropsTheFoldEntriesMadeSince() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "A", .allActivity)
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: false, origin: .user)

        rig.store.setMode(tag: "A", .focus)

        XCTAssertNil(fold(rig, "A", "a:k"))
        XCTAssertEqual(rig.store.explicitMode(tag: "A"), .focus)
    }

    func testPinStuckWritesExplicitFoldEntriesWithTheRequestedState() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setFold(tag: "A", key: "g:stuck1", turnKey: "t1", open: true, origin: .auto)   // earlier auto-open
        s.setMode(tag: "A", .focus)                                                      // drops it
        XCTAssertNil(fold(rig, "A", "g:stuck1"))

        s.pinStuck(tag: "A", keys: ["g:stuck1", "g:stuck2"], open: false)
        XCTAssertEqual(fold(rig, "A", "g:stuck1")?.open, false, "Focus mode closes even a stuck group")
        XCTAssertEqual(fold(rig, "A", "g:stuck1")?.origin, .user)
        XCTAssertEqual(fold(rig, "A", "g:stuck2")?.open, false)
        XCTAssertEqual(fold(rig, "A", "g:stuck2")?.origin, .user)

        s.pinStuck(tag: "A", keys: ["g:stuck1"], open: true)
        XCTAssertEqual(fold(rig, "A", "g:stuck1")?.open, true, "All activity opens every group")
        XCTAssertEqual(fold(rig, "A", "g:stuck1")?.origin, .user)
        XCTAssertEqual(fold(rig, "A", "g:stuck2")?.open, false, "keys not named are untouched")
        XCTAssertNil(fold(rig, "B", "g:stuck1"), "pinning is per tag")
    }

    func testPinStuckOverwritesAnAutoEntryWithAnExplicitOne() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "g:s", turnKey: "t1", open: true, origin: .auto)

        rig.store.pinStuck(tag: "A", keys: ["g:s"], open: false)

        XCTAssertEqual(fold(rig, "A", "g:s")?.open, false)
        XCTAssertEqual(fold(rig, "A", "g:s")?.origin, .user)
    }

    func testChangingTheDefaultDropsFoldEntriesOnlyForTagsFollowingTheDefault() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setMode(tag: "explicitSame", .allActivity)    // equals the NEW default
        s.setMode(tag: "explicitOther", .focus)         // differs from the NEW default
        for tag in ["followerA", "followerB", "explicitSame", "explicitOther"] {
            s.setFold(tag: tag, key: "a:k", turnKey: "t1", open: true, origin: .user)
            s.setFold(tag: tag, key: "g:k", turnKey: "t1", open: true, origin: .auto)
            s.setResult(tag: tag, key: "r:k", turnKey: "t1", open: true)
        }
        rig.recorder.reset()

        s.defaultMode = .allActivity

        for tag in ["followerA", "followerB"] {
            XCTAssertNil(fold(rig, tag, "a:k"), "\(tag) follows the default, so its folds are dropped")
            XCTAssertNil(fold(rig, tag, "g:k"))
            XCTAssertEqual(s.resultState(tag: tag, key: "r:k"), true, "results are never dropped by a mode change")
            XCTAssertEqual(s.mode(tag: tag), .allActivity)
        }
        for tag in ["explicitSame", "explicitOther"] {
            XCTAssertEqual(fold(rig, tag, "a:k")?.open, true, "\(tag) has an explicit mode; the default change leaves it alone")
            XCTAssertEqual(fold(rig, tag, "g:k")?.origin, .auto)
            XCTAssertEqual(s.resultState(tag: tag, key: "r:k"), true)
        }
        XCTAssertEqual(s.mode(tag: "explicitSame"), .allActivity)
        XCTAssertEqual(s.mode(tag: "explicitOther"), .focus)
    }

    func testChangingTheDefaultEmitsModeForFollowingTagsAndThenDefaultMode() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setMode(tag: "explicit", .focus)
        s.setFold(tag: "explicit", key: "a:k", turnKey: "t1", open: true, origin: .user)
        s.setFold(tag: "followerA", key: "a:k", turnKey: "t1", open: true, origin: .user)
        s.setFold(tag: "followerB", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.recorder.reset()

        s.defaultMode = .allActivity

        let events = rig.recorder.normalized
        XCTAssertEqual(events.count, 2, "exactly two events: .mode(followers) and .defaultMode — got \(events)")
        XCTAssertTrue(events.contains(.mode(tags: ["followerA", "followerB"])),
                      "the .mode event names exactly the tags that follow the default — got \(events)")
        XCTAssertTrue(events.contains(.defaultMode), "got \(events)")
    }

    func testChangingTheDefaultWhenNoTagFollowsItStillEmitsDefaultMode() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "explicit", .focus)
        rig.recorder.reset()

        rig.store.defaultMode = .allActivity

        XCTAssertTrue(rig.recorder.normalized.contains(.defaultMode), "menu validation relies on .defaultMode")
        for event in rig.recorder.normalized {
            if case .mode(let tags) = event {
                XCTAssertEqual(tags, [], "no tag follows the default, so a .mode event may not name one")
            }
        }
    }

    func testSettingTheDefaultToItsCurrentValueEmitsNothingAndDropsNothing() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "follower", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.recorder.reset()

        rig.store.defaultMode = .focus     // already .focus

        XCTAssertEqual(rig.recorder.events, [])
        XCTAssertEqual(fold(rig, "follower", "a:k")?.open, true)

        rig.store.defaultMode = .allActivity
        rig.recorder.reset()
        rig.store.defaultMode = .allActivity
        XCTAssertEqual(rig.recorder.events, [])
    }

    // MARK: 5. Bounds

    /// Per-fold-or-result probe used by the cap tests: entry `i` is a fold when
    /// even, a result when odd, so the cap is exercised on both kinds together.
    private func entryPresent(_ rig: Rig, tag: String, index i: Int) -> Bool {
        i % 2 == 0
            ? rig.store.foldState(tag: tag, key: "a:k\(i)") != nil
            : rig.store.resultState(tag: tag, key: "r:k\(i)") != nil
    }

    private func writeEntry(_ rig: Rig, tag: String, index i: Int) {
        rig.clock.advance()
        if i % 2 == 0 {
            rig.store.setFold(tag: tag, key: "a:k\(i)", turnKey: "turn-\(i)", open: true, origin: .user)
        } else {
            rig.store.setResult(tag: tag, key: "r:k\(i)", turnKey: "turn-\(i)", open: false)
        }
    }

    func testFoldAndResultEntriesAreCappedAtTenThousandOverallEvictingTheOldestTouched() throws {
        let rig = try makeRig()
        let total = 12_000
        let tags = (0..<8).map { "tag-\($0)" }
        for i in 0..<total { writeEntry(rig, tag: tags[i % 8], index: i) }   // 1,500 per tag: under the per-tag cap
        flushWrite(rig)

        let reopened = relaunch(rig)
        let present = (0..<total).map { entryPresent(reopened, tag: tags[$0 % 8], index: $0) }
        let survivors = present.filter { $0 }.count
        XCTAssertLessThanOrEqual(survivors, 10_000, "folds + results are capped at 10,000 in total")
        XCTAssertGreaterThanOrEqual(survivors, 9_000, "eviction must not throw away far more than the overflow")

        let oldestSurvivor = try XCTUnwrap(present.firstIndex(of: true))
        XCTAssertGreaterThanOrEqual(oldestSurvivor, 2_000, "the 2,000 oldest-touched entries are the victims")
        XCTAssertTrue(present[oldestSurvivor...].allSatisfy { $0 }, "survivors are exactly the newest — no holes")
        XCTAssertFalse(present[..<oldestSurvivor].contains(true))
        XCTAssertTrue(present[(total - 100)...].allSatisfy { $0 }, "the newest entries are always kept")
    }

    func testFoldAndResultEntriesAreCappedAtTwoThousandPerTagWithoutTouchingOtherTags() throws {
        let rig = try makeRig()
        // Quiet tag first, so its entries are the globally OLDEST. Only the
        // per-tag cap (not the 10,000 global one) may be what spares them.
        for i in 0..<10 { writeEntry(rig, tag: "quiet", index: i) }
        for i in 0..<2_500 { writeEntry(rig, tag: "busy", index: i) }
        flushWrite(rig)

        let reopened = relaunch(rig)
        let busy = (0..<2_500).map { entryPresent(reopened, tag: "busy", index: $0) }
        XCTAssertLessThanOrEqual(busy.filter { $0 }.count, 2_000, "≤ 2,000 fold+result entries per tag")
        XCTAssertGreaterThanOrEqual(busy.filter { $0 }.count, 1_800)
        let oldestSurvivor = try XCTUnwrap(busy.firstIndex(of: true))
        XCTAssertGreaterThanOrEqual(oldestSurvivor, 500, "the busy tag evicts its own oldest")
        XCTAssertTrue(busy[oldestSurvivor...].allSatisfy { $0 })
        XCTAssertTrue((0..<10).allSatisfy { entryPresent(reopened, tag: "quiet", index: $0) },
                      "another tag's overflow must not evict a quiet tag's entries")
    }

    func testExplicitModesAreCappedAtOneThousandTagsEvictingTheOldestTouched() throws {
        let rig = try makeRig()
        for i in 0..<1_200 {
            rig.clock.advance()
            rig.store.setMode(tag: "tag-\(i)", i % 2 == 0 ? .allActivity : .focus)
        }
        flushWrite(rig)

        let reopened = relaunch(rig)
        // explicitMode(tag:) rather than mode(tag:): reads must not be what decides survival.
        let present = (0..<1_200).map { reopened.store.explicitMode(tag: "tag-\($0)") != nil }
        let survivors = present.filter { $0 }.count
        XCTAssertLessThanOrEqual(survivors, 1_000)
        XCTAssertGreaterThanOrEqual(survivors, 900)
        let oldestSurvivor = try XCTUnwrap(present.firstIndex(of: true))
        XCTAssertGreaterThanOrEqual(oldestSurvivor, 200, "the 200 oldest-touched modes are evicted")
        XCTAssertTrue(present[oldestSurvivor...].allSatisfy { $0 }, "no holes among the survivors")
        XCTAssertEqual(reopened.store.explicitMode(tag: "tag-1199"), .focus)
        XCTAssertEqual(reopened.store.explicitMode(tag: "tag-1198"), .allActivity)
        XCTAssertNil(reopened.store.explicitMode(tag: "tag-0"))
    }

    func testTheFileStaysUnderTwoMegabytesAtTheCaps() throws {
        let rig = try makeRig()
        let uuidish = "3F2504E0-4F89-11D3-9A0C-0305E82C"   // 32 chars, like a ChatTurn identity
        for t in 0..<5 {                                    // 5 tags x 2,000 = 10,000 entries
            let tag = "claudia-\(String(format: "%08X", t))"
            for i in 0..<2_000 {
                rig.clock.advance()
                let id = "toolu_01\(String(format: "%022d", i))"   // 30 chars, like a tool_use_id
                if i % 2 == 0 {
                    rig.store.setFold(tag: tag, key: "a:g:\(id)", turnKey: "\(uuidish)-\(i % 10)", open: true, origin: .user)
                } else {
                    rig.store.setResult(tag: tag, key: "r:\(id)", turnKey: "\(uuidish)-\(i % 10)", open: false)
                }
            }
        }
        for m in 0..<1_000 {
            rig.clock.advance()
            rig.store.setMode(tag: "claudia-\(String(format: "%08X", 1_000 + m))", .allActivity)
        }
        flushWrite(rig)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: rig.url.path)[.size] as? Int)
        XCTAssertLessThan(size, 2 * 1024 * 1024, "transcript-folds.v1.json must stay under 2 MB at the caps (was \(size) bytes)")
        XCTAssertGreaterThan(size, 100_000, "test premise: the file really holds the capped content")
    }

    // MARK: 6. removeFocus / prune

    func testRemoveFocusDropsFoldsResultsAndModeOfThatTagOnly() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setMode(tag: "gone", .allActivity)
        s.setFold(tag: "gone", key: "a:k", turnKey: "t1", open: true, origin: .user)
        s.setFold(tag: "gone", key: "g:k", turnKey: "t1", open: true, origin: .auto)
        s.setResult(tag: "gone", key: "r:k", turnKey: "t1", open: true)
        s.setMode(tag: "stays", .allActivity)
        s.setFold(tag: "stays", key: "a:k", turnKey: "t1", open: true, origin: .user)
        s.setResult(tag: "stays", key: "r:k", turnKey: "t1", open: true)

        s.removeFocus(tag: "gone")

        XCTAssertNil(fold(rig, "gone", "a:k"))
        XCTAssertNil(fold(rig, "gone", "g:k"))
        XCTAssertNil(s.resultState(tag: "gone", key: "r:k"))
        XCTAssertNil(s.explicitMode(tag: "gone"))
        XCTAssertEqual(s.mode(tag: "gone"), s.defaultMode)
        XCTAssertEqual(fold(rig, "stays", "a:k")?.open, true)
        XCTAssertEqual(s.resultState(tag: "stays", key: "r:k"), true)
        XCTAssertEqual(s.explicitMode(tag: "stays"), .allActivity)

        flushWrite(rig)
        let reopened = relaunch(rig)
        XCTAssertNil(fold(reopened, "gone", "a:k"), "the removal is persisted")
        XCTAssertNil(reopened.store.explicitMode(tag: "gone"))
        XCTAssertEqual(reopened.store.explicitMode(tag: "stays"), .allActivity)
    }

    func testRemoveFocusOnAnUnknownTagIsHarmless() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.store.removeFocus(tag: "never-existed")
        XCTAssertEqual(fold(rig, "A", "a:k")?.open, true)
    }

    func testPruneDropsOnlyTheEntriesOfTurnsThatWereNotKept() throws {
        let rig = try makeRig()
        let s = rig.store
        s.setMode(tag: "A", .allActivity)
        for turn in ["t1", "t2", "t3"] {
            s.setFold(tag: "A", key: "a:\(turn)", turnKey: turn, open: true, origin: .user)
            s.setFold(tag: "A", key: "g:\(turn)", turnKey: turn, open: false, origin: .auto)
            s.setResult(tag: "A", key: "r:\(turn)", turnKey: turn, open: true)
        }
        s.setFold(tag: "B", key: "a:t2", turnKey: "t2", open: true, origin: .user)
        s.setResult(tag: "B", key: "r:t2", turnKey: "t2", open: true)

        s.prune(tag: "A", keepingTurnKeys: ["t1", "t3"])

        for turn in ["t1", "t3"] {
            XCTAssertEqual(fold(rig, "A", "a:\(turn)")?.open, true, "turn \(turn) was kept")
            XCTAssertEqual(fold(rig, "A", "g:\(turn)")?.origin, .auto)
            XCTAssertEqual(s.resultState(tag: "A", key: "r:\(turn)"), true)
        }
        XCTAssertNil(fold(rig, "A", "a:t2"), "fold entries of a dropped turn go")
        XCTAssertNil(fold(rig, "A", "g:t2"))
        XCTAssertNil(s.resultState(tag: "A", key: "r:t2"), "result entries of a dropped turn go")
        XCTAssertEqual(fold(rig, "B", "a:t2")?.open, true, "another tag's entry for the same turn key is untouched")
        XCTAssertEqual(s.resultState(tag: "B", key: "r:t2"), true)
        XCTAssertEqual(s.explicitMode(tag: "A"), .allActivity, "prune never touches the mode")
    }

    func testPruneWithAnEmptyKeepSetDropsEveryEntryOfThatTagButNotItsMode() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "A", .allActivity)
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.store.setResult(tag: "A", key: "r:k", turnKey: "t1", open: true)

        rig.store.prune(tag: "A", keepingTurnKeys: [])

        XCTAssertNil(fold(rig, "A", "a:k"))
        XCTAssertNil(rig.store.resultState(tag: "A", key: "r:k"))
        XCTAssertEqual(rig.store.explicitMode(tag: "A"), .allActivity)
    }

    // MARK: 7. Corruption

    func testGarbageFileStartsEmptyAndIsRenamedAsideAsCorrupt() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("transcript-folds.v1.json")
        let garbage = Data([0x00, 0xFF, 0xFE, 0x7B, 0x7B, 0x21, 0x23])
        try garbage.write(to: url)

        let rig = try makeRig(url: url)

        XCTAssertNil(rig.store.explicitMode(tag: "t1"))
        XCTAssertEqual(rig.store.mode(tag: "t1"), rig.store.defaultMode, "mode falls back to the global default")
        let siblings = try corruptSiblings(of: url)
        XCTAssertEqual(siblings.count, 1, "the unreadable file is kept as *.corrupt-<unix> beside the original")
        XCTAssertEqual(try Data(contentsOf: siblings[0]), garbage, "the corrupt file is the original bytes, renamed")
        if FileManager.default.fileExists(atPath: url.path) {
            XCTAssertNotEqual(try Data(contentsOf: url), garbage, "the original path no longer holds the bad content")
        }
        let suffix = String(siblings[0].lastPathComponent.split(separator: "-").last ?? "")
        XCTAssertNotNil(Int(suffix), "the suffix after '.corrupt-' is a unix time, got \(siblings[0].lastPathComponent)")
    }

    func testAnUnknownSchemaVersionStartsEmptyAndIsRenamedAsideAsCorrupt() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("transcript-folds.v1.json")
        let futureFile = """
        {"version":2,
         "folds":[{"tag":"A","key":"a:k","turnKey":"t1","open":true,"origin":"user","touched":1760000000.0}],
         "results":[{"tag":"A","key":"r:k","turnKey":"t1","open":true,"touched":1760000000.0}],
         "modes":{"A":{"mode":"allActivity","touched":1760000000.0}}}
        """
        try Data(futureFile.utf8).write(to: url)

        let rig = try makeRig(url: url)

        XCTAssertNil(fold(rig, "A", "a:k"), "a future-version file is not read")
        XCTAssertNil(rig.store.resultState(tag: "A", key: "r:k"))
        XCTAssertNil(rig.store.explicitMode(tag: "A"))
        XCTAssertEqual(rig.store.mode(tag: "A"), rig.store.defaultMode)
        let siblings = try corruptSiblings(of: url)
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(try String(contentsOf: siblings[0], encoding: .utf8), futureFile,
                       "the future file is preserved verbatim, not overwritten")
    }

    func testAStoreThatStartedFromACorruptFileStillPersistsNewState() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("transcript-folds.v1.json")
        try Data("not json at all".utf8).write(to: url)
        let rig = try makeRig(url: url)

        rig.store.setMode(tag: "A", .allActivity)
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: true, origin: .user)
        flushWrite(rig)

        let reopened = relaunch(rig)
        XCTAssertEqual(reopened.store.explicitMode(tag: "A"), .allActivity)
        XCTAssertEqual(fold(reopened, "A", "a:k")?.open, true)
    }

    func testASecondCorruptLaunchDoesNotCrashAndStillStartsEmpty() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("transcript-folds.v1.json")
        let defaults = makeDefaults()
        let clock = FakeClock()   // same instant both times: the rename target may collide

        try Data("garbage one".utf8).write(to: url)
        _ = try makeRig(url: url, defaults: defaults, clock: clock)
        let second = Data("garbage two".utf8)
        try second.write(to: url)

        let rig = try makeRig(url: url, defaults: defaults, clock: clock)

        XCTAssertNil(rig.store.explicitMode(tag: "t1"))
        XCTAssertEqual(rig.store.mode(tag: "t1"), rig.store.defaultMode)
        XCTAssertGreaterThanOrEqual(try corruptSiblings(of: url).count, 1)
        if FileManager.default.fileExists(atPath: url.path) {
            XCTAssertNotEqual(try Data(contentsOf: url), second,
                              "the bad file must not be left in place to be re-detected on every launch")
        }
    }

    // MARK: 8. Debounce

    func testManyMutationsProduceOneDebouncedWrite() throws {
        let rig = try makeRig()
        for i in 0..<50 {
            rig.store.setFold(tag: "A", key: "a:k\(i)", turnKey: "t\(i)", open: i % 2 == 0, origin: .user)
        }

        XCTAssertGreaterThanOrEqual(rig.sched.scheduleCount, 1, "mutations schedule a write")
        XCTAssertEqual(rig.store.writeCount, 0, "nothing is written until the debounce fires")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.url.path), "no file before the debounce fires")
        XCTAssertFalse(rig.sched.pendingDelays.isEmpty)
        for delay in rig.sched.pendingDelays {
            XCTAssertEqual(delay, 1.0, accuracy: 0.001, "the write is debounced by 1 second (§2.4)")
        }

        flushWrite(rig)

        XCTAssertEqual(rig.store.writeCount, 1, "50 mutations inside one debounce window are one write")
        XCTAssertEqual(rig.sched.pendingCount, 0)
        let reopened = relaunch(rig)
        XCTAssertEqual(fold(reopened, "A", "a:k0")?.open, true)
        XCTAssertEqual(fold(reopened, "A", "a:k49")?.open, false, "the one write carries every mutation")
    }

    func testAMutationAfterAWriteSchedulesANewWrite() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "a:first", turnKey: "t1", open: true, origin: .user)
        flushWrite(rig)
        XCTAssertEqual(rig.store.writeCount, 1)

        rig.store.setFold(tag: "A", key: "a:second", turnKey: "t1", open: false, origin: .user)
        XCTAssertGreaterThanOrEqual(rig.sched.pendingCount, 1, "a mutation after the write must schedule another")
        flushWrite(rig)

        XCTAssertEqual(rig.store.writeCount, 2)
        let reopened = relaunch(rig)
        XCTAssertEqual(fold(reopened, "A", "a:first")?.open, true)
        XCTAssertEqual(fold(reopened, "A", "a:second")?.open, false)
    }

    func testModeAndRemovalMutationsAreDebouncedLikeFoldMutations() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "A", .allActivity)
        rig.store.setFold(tag: "B", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.store.removeFocus(tag: "B")
        rig.store.clearMode(tag: "A")
        rig.store.setMode(tag: "C", .focus)

        XCTAssertEqual(rig.store.writeCount, 0)
        flushWrite(rig)
        XCTAssertEqual(rig.store.writeCount, 1)
        let reopened = relaunch(rig)
        XCTAssertNil(reopened.store.explicitMode(tag: "A"))
        XCTAssertNil(fold(reopened, "B", "a:k"))
        XCTAssertEqual(reopened.store.explicitMode(tag: "C"), .focus)
    }

    // MARK: 9. Change events

    func testSetFoldEmitsOneFoldsEventNamingTheKey() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: true, origin: .user)
        XCTAssertEqual(rig.recorder.normalized, [.folds(tag: "A", keys: ["a:k"])])
    }

    func testSetResultEmitsOneFoldsEventNamingTheKey() throws {
        let rig = try makeRig()
        rig.store.setResult(tag: "A", key: "r:k", turnKey: "t1", open: true)
        XCTAssertEqual(rig.recorder.normalized, [.folds(tag: "A", keys: ["r:k"])])
    }

    func testPinStuckEmitsOneFoldsEventNamingEveryPinnedKey() throws {
        let rig = try makeRig()
        rig.store.pinStuck(tag: "A", keys: ["g:2", "g:1", "g:3"], open: false)
        XCTAssertEqual(rig.recorder.normalized, [.folds(tag: "A", keys: ["g:1", "g:2", "g:3"])])
    }

    func testSetModeEmitsExactlyOneModeEventEvenWhenItDropsFolds() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.recorder.reset()

        rig.store.setMode(tag: "A", .allActivity)

        XCTAssertEqual(rig.recorder.normalized, [.mode(tags: ["A"])],
                       "the .mode event already tells every pane on A to re-resolve; no extra .folds event")
    }

    func testClearModeEmitsOneModeEvent() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "A", .allActivity)
        rig.recorder.reset()

        rig.store.clearMode(tag: "A")

        XCTAssertEqual(rig.recorder.normalized, [.mode(tags: ["A"])])
    }

    /// Our pick for the unspecified case: `removeFocus` emits `.mode([tag])`
    /// only if the tag HAD an explicit mode, and `.folds(tag, keys)` (every
    /// fold and result key it held) only if it HAD entries. Nothing existed:
    /// nothing is emitted.
    func testRemoveFocusEmitsModeOnlyIfItHadAModeAndFoldsOnlyIfItHadEntries() throws {
        let rig = try makeRig()
        rig.store.setMode(tag: "full", .allActivity)
        rig.store.setFold(tag: "full", key: "a:k", turnKey: "t1", open: true, origin: .user)
        rig.store.setResult(tag: "full", key: "r:k", turnKey: "t1", open: true)
        rig.store.setMode(tag: "modeOnly", .focus)
        rig.store.setFold(tag: "foldsOnly", key: "a:z", turnKey: "t1", open: true, origin: .user)
        rig.recorder.reset()

        rig.store.removeFocus(tag: "full")
        let full = rig.recorder.normalized
        XCTAssertEqual(full.count, 2, "got \(full)")
        XCTAssertTrue(full.contains(.mode(tags: ["full"])), "got \(full)")
        XCTAssertTrue(full.contains(.folds(tag: "full", keys: ["a:k", "r:k"])), "got \(full)")

        rig.recorder.reset()
        rig.store.removeFocus(tag: "modeOnly")
        XCTAssertEqual(rig.recorder.normalized, [.mode(tags: ["modeOnly"])])

        rig.recorder.reset()
        rig.store.removeFocus(tag: "foldsOnly")
        XCTAssertEqual(rig.recorder.normalized, [.folds(tag: "foldsOnly", keys: ["a:z"])])

        rig.recorder.reset()
        rig.store.removeFocus(tag: "never-existed")
        XCTAssertEqual(rig.recorder.events, [], "removing a tag the store never held emits nothing")
    }

    func testEachMutationInASequenceEmitsExactlyOneEvent() throws {
        let rig = try makeRig()
        rig.store.setFold(tag: "A", key: "a:1", turnKey: "t1", open: true, origin: .user)
        rig.store.setFold(tag: "A", key: "a:2", turnKey: "t1", open: false, origin: .auto)
        rig.store.setResult(tag: "A", key: "r:1", turnKey: "t1", open: true)
        rig.store.setMode(tag: "A", .focus)
        rig.store.clearMode(tag: "A")
        XCTAssertEqual(rig.recorder.normalized, [
            .folds(tag: "A", keys: ["a:1"]),
            .folds(tag: "A", keys: ["a:2"]),
            .folds(tag: "A", keys: ["r:1"]),
            .mode(tags: ["A"]),
            .mode(tags: ["A"]),
        ])
    }

    // MARK: - Source helpers (textual fitness functions, same style as PerFocusEvictionWiringTests)

    private static func sourceRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/TranscriptFoldStoreTests.swift
            .deletingLastPathComponent()    // …/macOS/NostromoTests
            .deletingLastPathComponent()    // …/macOS
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Brace-counted body of the function starting at `signature`. A textual
    /// heuristic, enough for "does this body mention X". Fails clearly when
    /// the function can't be found.
    private static func functionBody(_ signature: String, in source: String, fileName: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let sig = source.range(of: signature) else {
            XCTFail("\(signature) not found in \(fileName) — update this test if it was renamed", file: file, line: line)
            throw XCTSkip("\(signature) not found")
        }
        guard let open = source[sig.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) has no body in \(fileName)", file: file, line: line)
            throw XCTSkip("no body")
        }
        var depth = 0
        var idx = open
        while idx < source.endIndex {
            if source[idx] == "{" { depth += 1 }
            if source[idx] == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<idx]) }
            }
            idx = source.index(after: idx)
        }
        XCTFail("no matching closing brace for \(signature) in \(fileName)", file: file, line: line)
        throw XCTSkip("unbalanced braces")
    }
}
