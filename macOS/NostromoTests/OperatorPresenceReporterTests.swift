import XCTest
import AppKit

// Whether the operator is at this Mac, as the app tells the daemon: `active` or `away`. Built on private
// notification centers, an injected idle clock and a scheduler the test drives; nothing talks to a daemon.
final class OperatorPresenceReporterTests: XCTestCase {

    private var reporters: [OperatorPresenceReporter] = []

    override func tearDown() {
        reporters.forEach { $0.stop() }
        reporters = []
        super.tearDown()
    }

    /// Runs nothing until told to: the test is the clock.
    private final class ManualScheduler {
        private final class Item { let work: () -> Void; var cancelled = false
            init(_ w: @escaping () -> Void) { work = w } }
        private var items: [Item] = []
        private(set) var delays: [TimeInterval] = []
        var pending: Int { items.filter { !$0.cancelled }.count }
        var scheduler: OperatorPresenceReporter.Scheduler {
            return { [unowned self] delay, work in
                let item = Item(work)
                self.items.append(item)
                self.delays.append(delay)
                return { item.cancelled = true }
            }
        }
        func fireAll() {
            let due = items.filter { !$0.cancelled }
            items = []
            due.forEach { $0.work() }
        }
    }

    private final class Rig {
        var sent: [String] = []
        var idle: TimeInterval = 0
        var supported = true
        let distributed = NotificationCenter()
        let workspace = NotificationCenter()
        let clock = ManualScheduler()
        private(set) var reporter: OperatorPresenceReporter!
        init() {
            reporter = OperatorPresenceReporter(
                supported: { [unowned self] in self.supported },
                send: { [unowned self] in self.sent.append($0) },
                idleSeconds: { [unowned self] in self.idle },
                distributedCenter: distributed, workspaceCenter: workspace,
                schedule: clock.scheduler)
        }
        func lock() { post("com.apple.screenIsLocked") }
        func unlock() { post("com.apple.screenIsUnlocked") }
        func post(_ name: String) {
            distributed.post(name: Notification.Name(name), object: nil)
            APT.flushMain()
        }
        func postWorkspace(_ name: Notification.Name) {
            workspace.post(name: name, object: nil)
            APT.flushMain()
        }
    }

    private func makeRig(started: Bool = true) -> Rig {
        let rig = Rig()
        reporters.append(rig.reporter)
        if started { rig.reporter.start() }
        return rig
    }

    func testAnOperatorAtTheMacIsReportedActiveAtOnce() {
        let rig = makeRig()
        XCTAssertEqual(rig.sent, ["active"])
        XCTAssertEqual(rig.clock.pending, 0)
    }

    func testLockingTheScreenSendsAwayAtOnce() {
        let rig = makeRig()
        rig.lock()
        XCTAssertEqual(rig.sent, ["active", "away"])
        XCTAssertEqual(rig.clock.pending, 0, "away is not debounced")
    }

    func testUnlockingWithFreshInputSendsActiveOnlyAfterTheDebounce() {
        let rig = makeRig()
        rig.lock()
        rig.unlock()
        XCTAssertEqual(rig.sent, ["active", "away"], "active is held back")
        XCTAssertEqual(rig.clock.pending, 1)
        XCTAssertEqual(rig.clock.delays, [1], "the debounce is one second")
        rig.clock.fireAll()
        XCTAssertEqual(rig.sent, ["active", "away", "active"])
    }

    func testLockingAgainBeforeTheDebounceEndsSendsNothingMore() {
        let rig = makeRig()
        rig.lock(); rig.unlock(); rig.lock()
        rig.clock.fireAll()
        XCTAssertEqual(rig.sent, ["active", "away"])
    }

    func testIdleBelowTwoMinutesIsActiveAndAtTwoMinutesIsAway() {
        let rig = makeRig()
        rig.idle = 119
        XCTAssertEqual(rig.reporter.evaluate(), .active)
        XCTAssertEqual(rig.sent, ["active"])
        rig.idle = 121
        XCTAssertEqual(rig.reporter.evaluate(), .away)
        XCTAssertEqual(rig.sent, ["active", "away"])
    }

    func testExactlyTwoMinutesIdleIsAway() {
        let rig = makeRig()
        rig.idle = 120
        XCTAssertEqual(rig.reporter.evaluate(), .away)
        XCTAssertEqual(rig.sent, ["active", "away"])
    }

    func testSleepIsAwayAndWakeIsActiveAfterTheDebounce() {
        let rig = makeRig()
        rig.postWorkspace(NSWorkspace.willSleepNotification)
        XCTAssertEqual(rig.sent, ["active", "away"])
        rig.postWorkspace(NSWorkspace.didWakeNotification)
        XCTAssertEqual(rig.sent, ["active", "away"])
        rig.clock.fireAll()
        XCTAssertEqual(rig.sent, ["active", "away", "active"])
    }

    func testNothingIsSentWhileTheDaemonDoesNotAdvertisePresence() {
        let rig = makeRig(started: false)
        rig.supported = false
        rig.reporter.start()
        rig.lock()
        rig.idle = 500
        rig.reporter.evaluate()
        rig.unlock()
        rig.clock.fireAll()
        XCTAssertEqual(rig.sent, [])
    }

    func testTheCurrentStateIsSentOnceTheDaemonSupportsPresence() {
        let rig = makeRig(started: false)
        rig.supported = false
        rig.reporter.start()
        rig.lock()
        XCTAssertEqual(rig.sent, [])
        rig.supported = true
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["away"])
    }

    func testTheStateIsSentAgainAfterAReconnect() {
        let rig = makeRig()
        XCTAssertEqual(rig.sent, ["active"])
        rig.reporter.connectionLost()
        rig.reporter.connectionStarted()
        XCTAssertEqual(rig.sent, ["active", "active"])
    }

    func testAnAwayStateIsResentAfterAReconnect() {
        let rig = makeRig()
        rig.lock()
        rig.reporter.connectionLost()
        rig.reporter.connectionStarted()
        XCTAssertEqual(rig.sent, ["active", "away", "away"])
    }

    func testAChangePendingWhenTheConnectionDropsIsNotSentLater() {
        let rig = makeRig()
        rig.lock(); rig.unlock()
        rig.reporter.connectionLost()
        rig.clock.fireAll()
        XCTAssertEqual(rig.sent, ["active", "away"])
    }

    func testRepeatedEvaluationsOfAnUnchangedStateSendNothingMore() {
        let rig = makeRig()
        for _ in 0..<5 { rig.reporter.evaluate() }
        rig.idle = 60
        for _ in 0..<5 { rig.reporter.evaluate() }
        XCTAssertEqual(rig.sent, ["active"])
        rig.lock()
        rig.lock()
        for _ in 0..<5 { rig.reporter.evaluate() }
        XCTAssertEqual(rig.sent, ["active", "away"])
    }

    func testAStoppedReporterListensToNothing() {
        let rig = makeRig()
        rig.reporter.stop()
        rig.lock()
        XCTAssertEqual(rig.sent, ["active"])
    }
}
