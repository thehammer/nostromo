import XCTest
import AppKit
import Combine
import NostromoKit

// CL2 (criteria B1-B7, D7/D8): the Mac sign-in card.
//
// Behaviour only: what the store knows and sends, what the buttons do for a person and for a refused
// gesture, what the launcher runs and writes, that the overlay never moves the transcript, and a source
// scan that stands in for "never types into, automates or steals focus for the login".

// MARK: - Fixtures

private enum LoginFixture {
    static func frame(tags: [(String, String?)], bin: String? = "/opt/homebrew/bin/claude",
                      phase: String = "waiting", watch: String = "keychain") throws -> ClaudeLoginStateFrame {
        let sessions: [[String: Any]] = tags.map { tag, hold in
            var s: [String: Any] = ["tag": tag, "phase": phase, "queued": 0,
                                    "failed_at": "2026-01-01T00:00:00Z", "auto_resends_left": 1]
            if let hold { s["hold_id"] = hold }
            return s
        }
        var obj: [String: Any] = ["type": "claude_login_state", "needs_login": !tags.isEmpty,
                                  "watch": watch, "sessions": sessions]
        if let bin { obj["claude_bin"] = bin }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(ClaudeLoginStateFrame.self, from: data)
    }

    static func session(tag: String = "cody-1", hold: String? = "h1", bin: String? = "/opt/homebrew/bin/claude") throws -> ClaudeLoginSession {
        try XCTUnwrap(frame(tags: [(tag, hold)], bin: bin).sessions.first)
    }
}

private typealias Sent = (action: ClaudeLoginActionKind, tag: String, hold: String)

private final class SendLog {
    var sent: [Sent] = []
    var advertised = true
    var canSend = true
    /// The timeouts the store asked for, held until a test fires them (nothing waits on a real clock).
    var timers: [(delay: TimeInterval, work: () -> Void)] = []
    func makeStore() -> ClaudeLoginStore {
        ClaudeLoginStore(send: { [self] in sent.append(($0, $1, $2)) },
                         featureAdvertised: { [self] in advertised },
                         canSend: { [self] in canSend },
                         after: { [self] delay, work in timers.append((delay, work)) })
    }
    /// Fire every pending timeout, oldest first.
    func fireTimers() {
        let due = timers
        timers = []
        for t in due { t.work() }
    }
}

private final class FakeProcess: ProcessLaunching {
    var executables: Set<String> = []
    /// What `tmux list-clients -F #{client_session}` prints; nil when it fails or does not run.
    var clientsOutput: String?
    var newWindowStatus: Int32? = 0
    /// Every `run` call.
    var runs: [(exe: String, args: [String])] = []
    /// Every `output` call.
    var outputs: [(exe: String, args: [String])] = []
    var opened: [URL] = []
    var openResult = true

    func isExecutable(atPath path: String) -> Bool { executables.contains(path) }
    func run(_ executable: String, arguments: [String]) -> Int32? {
        runs.append((executable, arguments))
        return newWindowStatus
    }
    func output(of executable: String, arguments: [String]) -> String? {
        outputs.append((executable, arguments))
        return clientsOutput
    }
    func openInTerminal(_ file: URL) -> Bool { opened.append(file); return openResult }
    /// Nothing was launched, listed or opened.
    var didNothing: Bool { runs.isEmpty && outputs.isEmpty && opened.isEmpty }
}

private let tmuxBin = LoginTerminalLauncher.tmuxPaths[0]

private let human: ClaudeSignInCardView.GesturePermit = { _ in .human(sourcePid: nil, sourceState: nil) }

// MARK: - Store

final class ClaudeLoginStoreTests: XCTestCase {

    func testAFrameListingATagShowsItAndALaterFrameWithoutItClearsIt() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1"), ("b", "h2")]))
        XCTAssertNotNil(store.session(tag: "a"))
        XCTAssertNotNil(store.session(tag: "b"))
        store.handle(try LoginFixture.frame(tags: [("b", "h2")]))
        XCTAssertNil(store.session(tag: "a"), "REPLACE: a tag missing from the new frame is gone")
        XCTAssertNotNil(store.session(tag: "b"))
        store.handle(try LoginFixture.frame(tags: []))
        XCTAssertNil(store.session(tag: "b"))
    }

    func testADecodedDaemonFrameReachesTheStoreThroughTheAppStore() throws {
        let log = SendLog(), store = log.makeStore()
        store.attach(to: AppStore.shared.claudeLoginEvents)
        AppStore.shared.applyForTesting(.claudeLoginState(try LoginFixture.frame(tags: [("cody-1", "h1")])))
        XCTAssertEqual(store.session(tag: "cody-1")?.holdId, "h1")
        XCTAssertEqual(store.claudeBin, "/opt/homebrew/bin/claude")
        AppStore.shared.applyForTesting(.claudeLoginState(try LoginFixture.frame(tags: [])))
        XCTAssertNil(store.session(tag: "cody-1"))
    }

    func testAtMostOneActionIsSentPerHoldID() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertFalse(store.discard(tag: "a"), "retry then discard is still one send")
        XCTAssertEqual(log.sent.count, 1)
        XCTAssertEqual(log.sent.first?.action, .retry)
        XCTAssertEqual(log.sent.first?.hold, "h1")

        store.handle(try LoginFixture.frame(tags: [("a", "h2")]))
        XCTAssertTrue(store.discard(tag: "a"), "a new hold_id may be acted on")
        XCTAssertEqual(log.sent.map(\.hold), ["h1", "h2"])
    }

    func testNothingIsSentWhenTheFeatureIsNotAdvertisedOrThereIsNoConnection() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        log.advertised = false
        XCTAssertFalse(store.retry(tag: "a"))
        log.advertised = true; log.canSend = false
        XCTAssertFalse(store.discard(tag: "a"))
        XCTAssertTrue(log.sent.isEmpty)

        XCTAssertEqual(store.notice(tag: "a"), "Couldn't discard; try again.", "a blocked attempt says so")

        log.canSend = true
        XCTAssertTrue(store.retry(tag: "a"), "a blocked attempt does not use up the hold_id")
        XCTAssertEqual(log.sent.count, 1)
        XCTAssertNil(store.notice(tag: "a"), "the next action clears the notice")
    }

    func testABlockedResendSaysCouldntResend() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        log.advertised = false
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(log.sent.isEmpty)
    }

    func testTheStoreExposesTheWatchFromTheLastFrame() throws {
        let store = SendLog().makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], watch: "unavailable"))
        XCTAssertEqual(store.watch, .unavailable)
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], watch: "keychain"))
        XCTAssertEqual(store.watch, .keychain)
    }

    // MARK: In-flight actions: a failed action releases the hold with a notice

    func testAnActionInFlightBlocksAnotherUntilTheHoldChangesOrIsReleased() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertFalse(store.retry(tag: "a"), "the same frame again does not free the hold")
        XCTAssertFalse(store.discard(tag: "a"))
        XCTAssertEqual(log.sent.count, 1)
    }

    func testAResendUndoneToWaitingFreesTheHoldWithANotice() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "resending"))
        XCTAssertFalse(store.retry(tag: "a"), "while it is resending the hold stays protected")
        XCTAssertNil(store.notice(tag: "a"))

        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "waiting"))
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(store.retry(tag: "a"), "the same hold_id may be tried again")
        XCTAssertEqual(log.sent.map(\.hold), ["h1", "h1"])
        XCTAssertNil(store.notice(tag: "a"), "a new action clears the notice")
    }

    func testAResendUndoneToNotResendableFreesTheHoldWithANotice() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "not_resendable"))
        XCTAssertTrue(store.retry(tag: "a"))
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "resending"))
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "not_resendable"))
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertEqual(log.sent.count, 2)
    }

    func testADiscardThatIsUndoneSaysCouldntDiscard() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.discard(tag: "a"))
        store.actionRefused()
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't discard; try again.")
        XCTAssertTrue(store.discard(tag: "a"))
        XCTAssertEqual(log.sent.map(\.action), [.discard, .discard])
    }

    func testTheDaemonRefusingAnActionFreesTheHoldWithANotice() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertFalse(store.retry(tag: "a"))
        store.actionRefused()
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertEqual(log.sent.count, 2)
    }

    func testARefusalWithNothingInFlightChangesNothing() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        var fired = false
        let sub = store.changes.sink { _ in fired = true }
        store.actionRefused()
        XCTAssertNil(store.notice(tag: "a"))
        XCTAssertFalse(fired)
        withExtendedLifetime(sub) {}
    }

    func testAnActionThatGetsNoAnswerIsFreedWithANoticeWhenItsTimeoutPasses() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertEqual(log.timers.map(\.delay), [ClaudeLoginStore.actionTimeout])
        XCTAssertFalse(store.retry(tag: "a"), "before the timeout the action is still in flight")
        XCTAssertNil(store.notice(tag: "a"))

        log.fireTimers()
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertEqual(log.sent.count, 2)
    }

    func testAHoldStillResendingWhenTheTimeoutPassesStaysProtected() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "resending"))
        log.fireTimers()
        XCTAssertNil(store.notice(tag: "a"), "a resend that is under way is not a failure")
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertEqual(log.sent.count, 1)

        // The undo still frees it when it arrives after the timeout.
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "waiting"))
        XCTAssertEqual(store.notice(tag: "a"), "Couldn't resend; try again.")
        XCTAssertTrue(store.retry(tag: "a"))
    }

    func testAHoldThatLeavesTheFrameDropsTheActionWithoutANotice() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.handle(try LoginFixture.frame(tags: []))
        log.fireTimers()
        XCTAssertNil(store.notice(tag: "a"), "the action worked, so there is nothing to apologise for")

        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"), "nothing is left in flight for a hold that went away")
        store.handle(try LoginFixture.frame(tags: [("a", "h2")]))
        log.fireTimers()
        XCTAssertNil(store.notice(tag: "a"), "the turn moved on to another hold")
    }

    func testANoticeGoesAwayWhenTheHoldChangesOrGoes() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.actionRefused()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")], phase: "not_resendable"))
        XCTAssertNotNil(store.notice(tag: "a"), "the same hold keeps its notice across frames")

        store.handle(try LoginFixture.frame(tags: [("a", "h2")]))
        XCTAssertNil(store.notice(tag: "a"), "a different hold is a different situation")

        XCTAssertTrue(store.retry(tag: "a"))
        store.actionRefused()
        XCTAssertNotNil(store.notice(tag: "a"))
        store.handle(try LoginFixture.frame(tags: []))
        XCTAssertNil(store.notice(tag: "a"))
    }

    func testAFreshTimeoutIsNotCutShortByAnEarlierActionsTimer() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        let firstTimer = try XCTUnwrap(log.timers.first)
        store.actionRefused()
        XCTAssertTrue(store.retry(tag: "a"), "tried again after the refusal")
        XCTAssertEqual(log.sent.count, 2)

        firstTimer.work()   // the first action's timeout, long after it was answered
        XCTAssertFalse(store.retry(tag: "a"), "the second action has had none of its own time yet")
        XCTAssertEqual(log.sent.count, 2)
        XCTAssertNil(store.notice(tag: "a"))
    }

    func testADisconnectClearsEverythingTheStoreKnewAndSaysWhichTagsChanged() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1"), ("b", "h2")]))
        XCTAssertTrue(store.retry(tag: "a"))
        store.actionRefused()
        XCTAssertNotNil(store.notice(tag: "a"))
        XCTAssertTrue(store.discard(tag: "b"))
        var changed: [Set<String>] = []
        let sub = store.changes.sink { changed.append($0) }

        store.reset()
        XCTAssertNil(store.session(tag: "a"))
        XCTAssertNil(store.session(tag: "b"))
        XCTAssertNil(store.claudeBin)
        XCTAssertNil(store.notice(tag: "a"))
        XCTAssertEqual(changed, [["a", "b"]])

        store.handle(try LoginFixture.frame(tags: [("b", "h2")]))
        XCTAssertTrue(store.discard(tag: "b"), "nothing from before the disconnect is still in flight")
        withExtendedLifetime(sub) {}
    }

    func testNothingIsSentForASessionWithNoHoldOrNoSession() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", nil)], phase: "paused_no_hold"))
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertFalse(store.discard(tag: "a"))
        XCTAssertFalse(store.retry(tag: "unknown"))
        XCTAssertTrue(log.sent.isEmpty)
    }
}

// MARK: - Card rigs

private final class Copies { var texts: [String] = [] }

/// Background work the launcher was handed, held until a test runs it (a launch "in flight").
private final class DeferredWork {
    var pending: [() -> Void] = []
    func runAll() {
        let work = pending
        pending = []
        for w in work { w() }
    }
}

private let claudeBinPath = "/opt/homebrew/bin/claude"

private func inlineLauncher(_ process: FakeProcess,
                            background: @escaping (@escaping () -> Void) -> Void = { $0() }) -> LoginTerminalLauncher {
    LoginTerminalLauncher(process: process,
                          temporaryDirectory: NSTemporaryDirectory() + "claude-sign-in-test-\(UUID().uuidString)/",
                          background: background, deliver: { $0() })
}

/// A card on its own (no overlay host): clicks reach the store and the launcher, and nothing re-renders
/// it until the test calls `update`.
private func makeCard(permit: ClaudeSignInCardView.GesturePermit?, bin: String?, watch: String = "keychain",
                      phase: String = "waiting", width: CGFloat = 500,
                      background: @escaping (@escaping () -> Void) -> Void = { $0() }) throws
    -> (card: ClaudeSignInCardView, log: SendLog, store: ClaudeLoginStore, process: FakeProcess, copies: Copies) {
    let log = SendLog(), process = FakeProcess(), copies = Copies()
    process.executables = Set([tmuxBin] + (bin.map { [$0] } ?? []))
    process.clientsOutput = "main\n"
    let store = log.makeStore()
    store.handle(try LoginFixture.frame(tags: [("cody-1", "h1")], bin: bin, phase: phase, watch: watch))
    let card = ClaudeSignInCardView(tag: "cody-1", session: try XCTUnwrap(store.session(tag: "cody-1")),
                                    claudeBin: bin, watch: store.watch, store: store,
                                    launcher: inlineLauncher(process, background: background), permit: permit,
                                    copyToPasteboard: { copies.texts.append($0) })
    card.frame = NSRect(x: 0, y: 0, width: width, height: 160)
    card.layoutSubtreeIfNeeded()
    return (card, log, store, process, copies)
}

private func cardFrame(_ hold: String = "h1", phase: String = "waiting", watch: String = "keychain",
                       bin: String? = claudeBinPath) throws -> ClaudeLoginStateFrame {
    try LoginFixture.frame(tags: [("cody-1", hold)], bin: bin, phase: phase, watch: watch)
}

/// A card inside its overlay host, which re-renders it whenever the store reports a change.
private func makeHostedCard(phase: String = "waiting", watch: String = "keychain", bin: String? = claudeBinPath) throws
    -> (host: ClaudeSignInOverlayHost, card: ClaudeSignInCardView, log: SendLog, store: ClaudeLoginStore, process: FakeProcess) {
    let log = SendLog(), process = FakeProcess()
    process.executables = Set([tmuxBin] + (bin.map { [$0] } ?? []))
    process.clientsOutput = "main\n"
    let store = log.makeStore()
    store.handle(try cardFrame(phase: phase, watch: watch, bin: bin))
    let host = ClaudeSignInOverlayHost(tag: "cody-1", store: store, launcher: inlineLauncher(process), permit: human)
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    host.layoutSubtreeIfNeeded()
    return (host, try XCTUnwrap(host.card), log, store, process)
}

private let resendFailed = "Couldn't resend; try again."

// MARK: - Card buttons

final class ClaudeSignInCardButtonTests: XCTestCase {

    func testRefusedGesturesDoNothing() throws {
        let reasons: [HumanGestureRefusal] = [.appControl, .staleEvent, .accessibilityPress]
        for reason in reasons {
            let refuse: ClaudeSignInCardView.GesturePermit = { _ in .refused(reason: reason) }

            let withBin = try makeCard(permit: refuse, bin: claudeBinPath)
            withBin.card.openButton.performClick(nil)
            withBin.card.resendButton.performClick(nil)
            withBin.card.discardButton.performClick(nil)
            XCTAssertTrue(withBin.process.didNothing, "\(reason): open launches nothing")
            XCTAssertTrue(withBin.log.sent.isEmpty, "\(reason): resend and discard send nothing")

            let noBin = try makeCard(permit: refuse, bin: nil)
            noBin.card.copyButton.performClick(nil)
            XCTAssertTrue(noBin.copies.texts.isEmpty, "\(reason): copy does not copy")
        }
    }

    func testAPersonsClicksRunTheActions() throws {
        let a = try makeCard(permit: human, bin: claudeBinPath)
        a.card.openButton.performClick(nil)
        XCTAssertEqual(a.process.runs.last?.args.first, "new-window", "open starts the sign-in")
        a.card.resendButton.performClick(nil)
        XCTAssertEqual(a.log.sent.map(\.action), [.retry])

        let b = try makeCard(permit: human, bin: claudeBinPath)
        b.card.discardButton.performClick(nil)
        XCTAssertEqual(b.log.sent.map(\.action), [.discard])

        let c = try makeCard(permit: human, bin: nil)
        c.card.copyButton.performClick(nil)
        XCTAssertEqual(c.copies.texts, [ClaudeLoginCardModel.manualCommand])
    }

    func testNoButtonIsADefaultButtonOrAnEnterShortcut() throws {
        let c = try makeCard(permit: human, bin: claudeBinPath)
        for b in [c.card.openButton, c.card.copyButton, c.card.resendButton, c.card.discardButton] {
            XCTAssertEqual(b.keyEquivalent, "", "\(b.title) must not answer to Return or Esc")
        }
    }

    /// The one test that does not stub the gesture gate: a click with no user event behind it (the
    /// shape of an Accessibility press or a script) must do nothing. The card is in no window, so even
    /// a stray current event cannot belong to its window; the only way to a `.human` verdict is no event
    /// at all with VoiceOver on, which is why the test steps aside on a machine running it.
    func testWithTheRealGestureGateAClickWithNoUserEventDoesNothing() throws {
        try XCTSkipIf(NSWorkspace.shared.isVoiceOverEnabled,
                      "with VoiceOver on, an event-less press is allowed by design; nothing to assert here")
        let withBin = try makeCard(permit: nil, bin: claudeBinPath)
        withBin.card.openButton.performClick(nil)
        withBin.card.resendButton.performClick(nil)
        withBin.card.discardButton.performClick(nil)
        XCTAssertTrue(withBin.process.didNothing, "open launches nothing")
        XCTAssertTrue(withBin.log.sent.isEmpty, "resend and discard send nothing")

        let noBin = try makeCard(permit: nil, bin: nil)
        noBin.card.copyButton.performClick(nil)
        XCTAssertTrue(noBin.copies.texts.isEmpty)
    }
}

// MARK: - Card: actions in flight, failures, and what it says

final class ClaudeSignInCardActionTests: XCTestCase {

    func testTwoQuickClicksOnResendSendOnce() throws {
        let r = try makeCard(permit: human, bin: claudeBinPath)
        r.card.resendButton.performClick(nil)
        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.map(\.action), [.retry])
        r.card.discardButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 1, "discarding while the resend is in flight sends nothing")
    }

    func testTwoQuickClicksOnDiscardSendOnce() throws {
        let r = try makeCard(permit: human, bin: claudeBinPath)
        r.card.discardButton.performClick(nil)
        r.card.discardButton.performClick(nil)
        XCTAssertEqual(r.log.sent.map(\.action), [.discard])
    }

    func testAFreshCardOverTheSameHoldDoesNotSendAgainWhileTheActionIsInFlight() throws {
        let r = try makeCard(permit: human, bin: claudeBinPath)
        r.card.resendButton.performClick(nil)
        let again = ClaudeSignInCardView(tag: "cody-1", session: try XCTUnwrap(r.store.session(tag: "cody-1")),
                                         claudeBin: claudeBinPath, store: r.store, permit: human)
        again.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 1)
    }

    func testARefusedActionShowsANoticeAndTheCardCanTryAgain() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)
        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 1)

        r.store.actionRefused()
        XCTAssertTrue(r.card.resendButton.isEnabled)
        XCTAssertFalse(r.card.statusLabel.isHidden)
        XCTAssertEqual(r.card.statusLabel.stringValue, resendFailed)

        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 2, "the person can try again")
    }

    func testTheNoticeLeavesTheCardWhenThePersonTriesAgain() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)
        r.store.actionRefused()
        XCTAssertEqual(r.card.statusLabel.stringValue, resendFailed)
        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.card.statusLabel.stringValue, "", "a card must not keep saying it failed while it is trying again")
        XCTAssertTrue(r.card.statusLabel.isHidden)
    }

    func testADiscardThatFailsSaysSo() throws {
        let r = try makeHostedCard()
        r.card.discardButton.performClick(nil)
        r.store.actionRefused()
        XCTAssertEqual(r.card.statusLabel.stringValue, "Couldn't discard; try again.")
        r.card.discardButton.performClick(nil)
        XCTAssertEqual(r.log.sent.map(\.action), [.discard, .discard])
    }

    func testAResendUndoneByTheDaemonBringsTheButtonsBackWithANotice() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)

        r.store.handle(try cardFrame(phase: "resending"))
        XCTAssertFalse(r.card.resendButton.isEnabled, "while it is being sent the button is off")
        XCTAssertTrue(r.card.discardButton.isHidden, "and there is nothing left to discard")

        r.store.handle(try cardFrame(phase: "waiting"))
        XCTAssertTrue(r.card.resendButton.isEnabled)
        XCTAssertFalse(r.card.discardButton.isHidden)
        XCTAssertEqual(r.card.statusLabel.stringValue, resendFailed)

        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 2, "the same hold can be tried again")
    }

    func testAnActionWithNoAnswerShowsTheNoticeWhenItsTimeoutPasses() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)
        XCTAssertTrue(r.card.statusLabel.isHidden, "nothing is said while it may still work")
        r.log.fireTimers()
        XCTAssertEqual(r.card.statusLabel.stringValue, resendFailed)
        r.card.resendButton.performClick(nil)
        XCTAssertEqual(r.log.sent.count, 2)
    }

    func testAResendUnderWayAtTheTimeoutIsLeftAlone() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)
        r.store.handle(try cardFrame(phase: "resending"))
        r.log.fireTimers()
        XCTAssertTrue(r.card.statusLabel.isHidden)
        XCTAssertFalse(r.card.resendButton.isEnabled)
    }

    func testTheNoticeGoesWhenTheHeldMessageIsReplaced() throws {
        let r = try makeHostedCard()
        r.card.resendButton.performClick(nil)
        r.store.actionRefused()
        XCTAssertFalse(r.card.statusLabel.isHidden)
        r.store.handle(try cardFrame("h2"))
        XCTAssertTrue(r.card.statusLabel.isHidden)
    }

    // MARK: Opening a terminal

    func testAfterOpeningATerminalTheCardRepeatsWhatHappensOnceTheyAreSignedIn() throws {
        let kc = try makeHostedCard(watch: "keychain")
        kc.card.openButton.performClick(nil)
        XCTAssertFalse(kc.card.statusLabel.isHidden)
        XCTAssertTrue(kc.card.statusLabel.stringValue.contains("claude-sign-in"), kc.card.statusLabel.stringValue)
        XCTAssertTrue(kc.card.statusLabel.stringValue.contains("Nostromo sends your message once Claude is signed in."),
                      kc.card.statusLabel.stringValue)

        let na = try makeHostedCard(watch: "unavailable")
        na.card.openButton.performClick(nil)
        XCTAssertTrue(na.card.statusLabel.stringValue.contains("After you sign in, press Resend now."),
                      na.card.statusLabel.stringValue)

        let held = try makeHostedCard(phase: "not_resendable", watch: "keychain")
        held.card.openButton.performClick(nil)
        XCTAssertTrue(held.card.statusLabel.stringValue.contains("After you sign in, press Resend anyway."),
                      held.card.statusLabel.stringValue)
    }

    func testTheTerminalAppFallbackAlsoSaysWhatHappensNext() throws {
        let r = try makeHostedCard(watch: "unavailable")
        r.process.clientsOutput = ""   // a tmux server nobody is attached to
        r.card.openButton.performClick(nil)
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("Opened Terminal"), r.card.statusLabel.stringValue)
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("After you sign in, press Resend now."))
    }

    func testWhenNoTerminalCanBeOpenedTheCardSaysSo() throws {
        let r = try makeHostedCard()
        r.process.clientsOutput = nil
        r.process.openResult = false
        r.card.openButton.performClick(nil)
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("Couldn't open a terminal"), r.card.statusLabel.stringValue)
    }

    func testTheLaunchMessageClearsWhenThePhaseOrTheHoldChanges() throws {
        let r = try makeHostedCard()
        r.card.openButton.performClick(nil)
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("Opened"))

        r.store.handle(try cardFrame())
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("Opened"), "the same state keeps the message")

        r.store.handle(try cardFrame(phase: "not_resendable"))
        XCTAssertTrue(r.card.statusLabel.isHidden, "a new phase is a new situation")
        XCTAssertEqual(r.card.statusLabel.stringValue, "")

        r.card.openButton.performClick(nil)
        XCTAssertTrue(r.card.statusLabel.stringValue.contains("Opened"))
        r.store.handle(try cardFrame("h2", phase: "not_resendable"))
        XCTAssertTrue(r.card.statusLabel.isHidden, "a new held message is a new situation")
    }

    func testTwoQuickClicksOnOpenLaunchOnce() throws {
        let work = DeferredWork()
        let r = try makeCard(permit: human, bin: claudeBinPath, background: { work.pending.append($0) })
        r.card.openButton.performClick(nil)
        r.card.openButton.performClick(nil)
        XCTAssertEqual(work.pending.count, 1, "the second click found a launch already under way")
        XCTAssertTrue(r.process.didNothing, "the launch runs off the click")

        work.runAll()
        XCTAssertEqual(r.process.runs.filter { $0.args.first == "new-window" }.count, 1)

        r.card.openButton.performClick(nil)
        XCTAssertEqual(work.pending.count, 1, "once the first launch is done a person may open another")
    }
}

// MARK: - Card layout

final class ClaudeSignInCardLayoutTests: XCTestCase {

    private func controls(_ card: ClaudeSignInCardView) -> [NSView] {
        let all: [NSView] = [card.titleLabel, card.bodyLabel, card.statusLabel, card.manualLabel,
                             card.openButton, card.copyButton, card.resendButton, card.discardButton]
        return all.filter { !$0.isHidden }
    }

    /// Size the card to what it asks for at `width` and lay it out; returns that height.
    @discardableResult
    private func layOut(_ card: ClaudeSignInCardView, width: CGFloat) -> CGFloat {
        let h = card.preferredHeight(forWidth: width)
        card.frame = NSRect(x: 0, y: 0, width: width, height: h)
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        return h
    }

    private func assertNothingClippedOrOverlapping(_ card: ClaudeSignInCardView, _ what: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let room = card.bounds.insetBy(dx: -0.5, dy: -0.5)
        let shown = controls(card)
        for v in shown {
            XCTAssertTrue(room.contains(v.frame), "\(what): \(v.identifier?.rawValue ?? String(describing: type(of: v))) at \(v.frame) leaves the card \(card.bounds)", file: file, line: line)
            XCTAssertGreaterThan(v.frame.width, 0, "\(what): a control has no width", file: file, line: line)
        }
        for (i, a) in shown.enumerated() {
            for b in shown[(i + 1)...] {
                XCTAssertFalse(a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame.insetBy(dx: 0.5, dy: 0.5)),
                               "\(what): \(a.frame) overlaps \(b.frame)", file: file, line: line)
            }
        }
    }

    private typealias Variant = (name: String, build: () throws -> ClaudeSignInCardView)

    private var variants: [Variant] {
        [
            ("waiting, terminal button", { try makeCard(permit: human, bin: claudeBinPath).card }),
            ("waiting, manual command", { try makeCard(permit: human, bin: nil).card }),
            ("held message, terminal button, no watch", {
                try makeCard(permit: human, bin: claudeBinPath, watch: "unavailable", phase: "not_resendable").card
            }),
            ("after opening a terminal", {
                let r = try makeCard(permit: human, bin: claudeBinPath, watch: "unavailable")
                r.card.openButton.performClick(nil)
                return r.card
            }),
            ("with a failure notice", {
                let r = try makeCard(permit: human, bin: claudeBinPath)
                r.card.resendButton.performClick(nil)
                r.store.actionRefused()
                r.card.update(session: try XCTUnwrap(r.store.session(tag: "cody-1")), claudeBin: claudeBinPath, watch: r.store.watch)
                return r.card
            }),
            ("manual command with a failure notice", {
                let r = try makeCard(permit: human, bin: nil)
                r.card.discardButton.performClick(nil)
                r.store.actionRefused()
                r.card.update(session: try XCTUnwrap(r.store.session(tag: "cody-1")), claudeBin: nil, watch: r.store.watch)
                return r.card
            }),
        ]
    }

    func testEveryControlStaysInsideACardAsNarrowAs260And340Points() throws {
        for width in [260.0, 340.0] as [CGFloat] {
            for variant in variants {
                let card = try variant.build()
                let h = layOut(card, width: width)
                let what = "\(variant.name) @\(Int(width))pt"
                assertNothingClippedOrOverlapping(card, what)
                XCTAssertLessThan(h, 320, "\(what): the wrapped card stays a sensible height")
                XCTAssertGreaterThan(h, 0)
            }
        }
    }

    func testNarrowControlsWrapOntoFurtherLinesAndTheHeightGrowsToMatch() throws {
        let card = try makeCard(permit: human, bin: claudeBinPath).card
        let wide = layOut(card, width: 500)
        let rowsWide = Set(controls(card).filter { $0 is NSButton }.map { $0.frame.minY.rounded() }).count
        XCTAssertEqual(rowsWide, 1)

        let narrow = layOut(card, width: 260)
        let rowsNarrow = Set(controls(card).filter { $0 is NSButton }.map { $0.frame.minY.rounded() }).count
        XCTAssertGreaterThan(rowsNarrow, 1, "260pt cannot hold every button on one line")
        XCTAssertGreaterThan(narrow, wide)
    }

    func testWhereEverythingFitsOnOneRowTheCardIsExactlyOneRowOfControlsTall() throws {
        let card = try makeCard(permit: human, bin: claudeBinPath).card
        layOut(card, width: 500)
        let buttons = controls(card).filter { $0 is NSButton }
        XCTAssertEqual(buttons.count, 3, "terminal, resend, discard")
        assertNothingClippedOrOverlapping(card, "500pt")

        let row = try XCTUnwrap(buttons.first)
        let pad = ClaudeSignInCardView.padding
        XCTAssertEqual(Set(buttons.map { $0.frame.minY.rounded() }).count, 1, "one row")
        XCTAssertEqual(row.frame.minY, pad, accuracy: 0.5, "the row sits on the bottom padding")
        XCTAssertEqual(card.bounds.height - card.titleLabel.frame.maxY, pad, accuracy: 0.5, "no spare space above the title")
        XCTAssertEqual(card.bodyLabel.frame.minY - row.frame.maxY, ClaudeSignInCardView.rowGap,
                       accuracy: 0.5, "no blank line between the text and the one row")
    }
}

// MARK: - Terminal launcher

final class LoginTerminalLauncherTests: XCTestCase {

    private var tmp: String!
    private let bin = "/x/claude"

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "claude-sign-in-test-\(UUID().uuidString)/"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    /// `claude` is executable; tmux is installed when `tmux`; `clients` is what `list-clients` prints.
    private func fake(tmux: Bool = false, clients: String? = nil, executable: [String] = []) -> FakeProcess {
        let p = FakeProcess()
        p.executables = Set([bin] + executable + (tmux ? [tmuxBin] : []))
        p.clientsOutput = clients
        return p
    }

    private func launcher(_ p: FakeProcess) -> LoginTerminalLauncher {
        LoginTerminalLauncher(process: p, temporaryDirectory: tmp, background: { $0() }, deliver: { $0() })
    }

    private func perms(_ url: URL) throws -> Int {
        let n = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(n).intValue
    }

    func testWithAnAttachedTmuxClientItOpensANamedWindowInThatSessionAndWritesNoScript() {
        let p = fake(tmux: true, clients: "main\n")
        let l = launcher(p)
        XCTAssertEqual(l.openNow(claudeBin: bin), .tmuxWindow)
        XCTAssertEqual(p.outputs.last?.args, ["list-clients", "-F", "#{client_session}"])
        XCTAssertEqual(p.runs.last?.args, ["new-window", "-t", "main:", "-n", "claude-sign-in", "--", bin, "auth", "login"])
        XCTAssertEqual(p.runs.last?.exe, tmuxBin)
        XCTAssertTrue(p.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
    }

    func testTmuxIsLookedForInHomebrewThenUsrLocalThenUsr() {
        XCTAssertEqual(LoginTerminalLauncher.tmuxPaths, ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
        let p = fake(clients: "main\n", executable: ["/usr/local/bin/tmux", "/usr/bin/tmux"])
        _ = launcher(p).openNow(claudeBin: bin)
        XCTAssertEqual(p.outputs.first?.exe, "/usr/local/bin/tmux")
        XCTAssertEqual(p.runs.first?.exe, "/usr/local/bin/tmux")
    }

    func testATmuxServerWithNoAttachedClientFallsBackToATerminalCommandFile() throws {
        for printed in ["", "\n"] {
            let p = fake(tmux: true, clients: printed)
            let l = launcher(p)
            XCTAssertEqual(l.openNow(claudeBin: bin), .terminalApp, "list-clients printed \(printed.debugDescription)")
            XCTAssertTrue(p.runs.isEmpty, "no window is opened where nobody is looking")
            XCTAssertEqual(p.opened, [l.scriptURL])
            XCTAssertEqual(try String(contentsOf: l.scriptURL, encoding: .utf8), "#!/bin/sh\nexec '/x/claude' auth login\n")
            XCTAssertEqual(try perms(l.scriptURL), 0o700)
            XCTAssertEqual(try perms(l.scriptURL.deletingLastPathComponent()), 0o700)
        }
    }

    func testWhenTmuxCannotListItsClientsItFallsBackToTheTerminalApp() {
        let p = fake(tmux: true, clients: nil)
        let l = launcher(p)
        XCTAssertEqual(l.openNow(claudeBin: bin), .terminalApp)
        XCTAssertFalse(p.runs.contains { $0.args.first == "new-window" })
        XCTAssertEqual(p.opened, [l.scriptURL])
    }

    func testWhenTheTmuxWindowCannotBeOpenedItFallsBackToTheTerminalApp() {
        for status: Int32? in [1, nil] {
            let p = fake(tmux: true, clients: "main\n")
            p.newWindowStatus = status
            XCTAssertEqual(launcher(p).openNow(claudeBin: bin), .terminalApp, "new-window status \(String(describing: status))")
            XCTAssertEqual(p.opened.count, 1)
        }
    }

    func testWithNoTmuxAtAllItUsesTheTerminalFallback() {
        let p = fake()
        XCTAssertEqual(launcher(p).openNow(claudeBin: bin), .terminalApp)
        XCTAssertTrue(p.runs.isEmpty)
        XCTAssertEqual(p.opened.count, 1)
    }

    func testAPathWithASpaceAndAQuoteIsQuotedForTheShell() throws {
        let odd = "/Users/o'brien/my tools/claude"
        let p = fake(executable: [odd])
        let l = launcher(p)
        XCTAssertEqual(l.openNow(claudeBin: odd), .terminalApp)
        XCTAssertEqual(try String(contentsOf: l.scriptURL, encoding: .utf8),
                       "#!/bin/sh\nexec '/Users/o'\\''brien/my tools/claude' auth login\n")
    }

    func testAPathWithANewlineOrNulOrNothingAtAllIsRefusedAndNothingRunsOrIsWritten() {
        for bad in ["/x/claude\nrm -rf ~", "/x/claude\0--evil", ""] {
            let p = fake(tmux: true, clients: "main\n", executable: [bad])
            let l = launcher(p)
            XCTAssertNil(l.openNow(claudeBin: bad), "\(bad.debugDescription)")
            XCTAssertTrue(p.didNothing, "\(bad.debugDescription)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
        }
    }

    func testAPathThatIsNotAbsoluteIsRefusedEvenIfSomethingByThatNameRuns() {
        for relative in ["claude", "bin/claude", "./claude", "~/bin/claude"] {
            let p = fake(tmux: true, clients: "main\n", executable: [relative])
            let l = launcher(p)
            XCTAssertNil(l.openNow(claudeBin: relative), relative)
            XCTAssertTrue(p.didNothing, relative)
            XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
        }
    }

    func testAnAbsolutePathThatIsNotExecutableIsRefusedAndNothingRunsOrIsWritten() {
        let p = FakeProcess()
        p.executables = [tmuxBin]   // /x/claude is not executable
        p.clientsOutput = "main\n"
        let l = launcher(p)
        XCTAssertNil(l.openNow(claudeBin: bin))
        XCTAssertTrue(p.didNothing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
    }

    // MARK: Off the main thread

    func testOpenDoesItsWorkInTheBackgroundAndDeliversTheOutcome() {
        let p = fake(tmux: true, clients: "main\n")
        let work = DeferredWork()
        let l = LoginTerminalLauncher(process: p, temporaryDirectory: tmp,
                                      background: { work.pending.append($0) }, deliver: { $0() })
        var calls = 0
        var outcome: LoginTerminalOutcome?
        l.open(claudeBin: bin) { calls += 1; outcome = $0 }
        XCTAssertTrue(p.didNothing, "open itself does not touch tmux or the Terminal")
        XCTAssertEqual(calls, 0)

        work.runAll()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome, .tmuxWindow)
        XCTAssertEqual(p.runs.last?.args.first, "new-window")
    }

    func testOpenDeliversNilWhenNothingCouldBeOpened() {
        let p = FakeProcess()   // /x/claude is not executable
        var calls = 0
        var outcome: LoginTerminalOutcome? = .terminalApp
        launcher(p).open(claudeBin: bin) { calls += 1; outcome = $0 }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(outcome)
    }
}

// MARK: - Overlay host

final class ClaudeSignInOverlayHostTests: XCTestCase {

    func testTheCardShowsOnlyWhileTheStoreListsItsTagAndOnlyTheCardTakesHits() throws {
        let store = SendLog().makeStore()
        let host = ClaudeSignInOverlayHost(tag: "cody-1", store: store, permit: human)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(host.card)

        store.handle(try LoginFixture.frame(tags: [("other", "h9")]))
        XCTAssertNil(host.card, "another focus's session does not show here")

        store.handle(try LoginFixture.frame(tags: [("cody-1", "h1")]))
        host.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(host.card)
        XCTAssertTrue(card.superview === host)
        XCTAssertNil(host.hitTest(NSPoint(x: 1, y: 399)), "outside the card the click goes to the transcript")
        XCTAssertNotNil(host.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)), "inside the card it is the card's")

        store.handle(try LoginFixture.frame(tags: []))
        XCTAssertNil(host.card)
        XCTAssertNil(card.superview)
    }

    private func overlay(on rig: SafetyRig, store: ClaudeLoginStore) -> ClaudeSignInOverlayHost {
        let host = ClaudeSignInOverlayHost(tag: "cody-1", store: store, permit: human)
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = rig.window.contentView!
        content.addSubview(host, positioned: .above, relativeTo: rig.overlay)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: rig.scrollView.topAnchor),
            host.leadingAnchor.constraint(equalTo: rig.scrollView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: rig.scrollView.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: rig.scrollView.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return host
    }

    func testTheCardArrivingAndLeavingMovesNothingAndKeepsTheComposer() throws {
        for following in [true, false] {
            let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
            let store = SendLog().makeStore()
            let host = overlay(on: rig, store: store)
            let scrollFrame = rig.scrollView.frame, barFrame = rig.inputBar.frame
            let arrive = try LoginFixture.frame(tags: [("cody-1", "h1")])
            let leave = try LoginFixture.frame(tags: [])

            rig.assertNoMove("sign-in card arrives (following: \(following))", following: following) {
                store.handle(arrive)
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
            XCTAssertNotNil(host.card)
            XCTAssertEqual(rig.scrollView.frame, scrollFrame)
            XCTAssertEqual(rig.inputBar.frame, barFrame)
            XCTAssertTrue(rig.window.firstResponder === rig.textView, "the composer keeps focus")
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)

            rig.assertNoMove("sign-in card leaves (following: \(following))", following: following) {
                store.handle(leave)
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
            XCTAssertNil(host.card)
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
        }
    }
}

// MARK: - Source scan

final class ClaudeSignInSourceScanTests: XCTestCase {

    private func files() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/Login")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    func testTheScanSeesTheFourLoginFiles() throws {
        let found = try files()
        for f in ["ClaudeLoginStore.swift", "ClaudeSignInCardView.swift", "ClaudeSignInOverlayHost.swift", "LoginTerminalLauncher.swift"] {
            XCTAssertTrue(found.contains(f), "\(f) missing from UI/Login: \(found)")
        }
    }

    func testTheLoginUINeverAutomatesTheLoginOrTouchesFocusOrTheKeychain() throws {
        let forbidden = ["send-keys", "osascript", "NSAppleScript", "CGEvent", "security", "keyEquivalent", "makeFirstResponder"]
            + DecisionCoordinatorTests.forbiddenForegroundAndFocusCalls
        for file in try files() {
            let lines = try DecisionCoordinatorTests.codeLines(ofSourceAt: "UI/Login/\(file)")
            for needle in forbidden {
                let hits = lines.filter { $0.contains(needle) }
                XCTAssertTrue(hits.isEmpty, "UI/Login/\(file) must not use `\(needle)`: \(hits)")
            }
        }
    }

    func testTheInstalledAppStillHasNoEntitlements() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("signing/Nostromo.installed.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])
        // Parsed, not grepped: the file's comment names the forbidden keys.
        for key in ["get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
                    "allow-dyld-environment-variables", "com.apple.security.cs.disable-library-validation",
                    "disable-library-validation"] {
            XCTAssertNil(dict[key], "\(key) must never be an entitlement of the installed app")
        }
        XCTAssertTrue(dict.isEmpty, "the installed app's entitlements stay empty: \(dict.keys)")
    }
}
