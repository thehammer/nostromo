import XCTest
import AppKit
import Combine
import NostromoKit

// The Compact button: a second pill after Clear Context on every REPL focus without quick actions of its own.
// Clicking it sends exactly the typed `/compact` through the session's ordinary send path (so the daemon
// answers with one muted record and the transcript stays). It is available only while the session is healthy
// and idle; otherwise it is dimmed, ignores clicks, and says why in its tooltip and VoiceOver help. After a
// click it stays unavailable until the `/compact` record has arrived and the turn is over.
//
// ReplView, QuickActionStripView, ChatSession, QuickAction and the NostromoKit types are compiled into this
// target directly. DynamicFocusView is NOT, so its wiring is read as text (as DynamicFocusViewWiringTests does).
// The pane's session is the shared registry's, fed through the shared client's `messages` the way the daemon
// feeds it. Nothing here is connected to a daemon: what was sent is what the session's transcript shows as sent.

final class CompactButtonTests: XCTestCase {

    private let compactID = QuickAction.compact.id
    private let clearID = QuickAction.clearContext.id

    private var tag: String!
    private var repl: ReplView!
    private var session: ChatSession!
    private var strip: QuickActionStripView!
    private var window: NSWindow!

    private var client: NostromodClient { AppStore.shared.client }

    override func setUp() {
        super.setUp()
        tag = "compact-\(UUID().uuidString)"
        let world = FV4StoreWorld(self)
        repl = ReplView(tag: tag, quickActions: QuickAction.replDefaults, foldStore: world.store)
        session = AppStore.shared.session(for: tag)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        repl.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.contentView = repl
        repl.layoutSubtreeIfNeeded()
        modelFlushMain()
        strip = repl.quickActionStripForTesting
    }

    override func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
        session.detach()
        strip = nil
        repl = nil
        session = nil
        window = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func feed(_ msg: ServerMsg) {
        client.messages.send(msg)
        modelFlushMain()
    }

    private func state(_ s: DaemonSessionState) { feed(.sessionState(tag: tag, state: s)) }

    /// The `/compact` messages the session has sent (each send leaves one echo turn).
    private var compactsSent: Int { session.turns.filter { $0.userInput == "/compact" }.count }

    private var anythingSent: Int { session.turns.count }

    private func click() {
        strip.tap(actionID: compactID)
        modelFlushMain()
    }

    private func compactRecordTurn(id: String = "c1") -> DaemonTurn {
        DaemonTurn(id: id, userInput: "/compact", timestamp: nil, blocks: [], isComplete: true,
                   origin: .localCommand(command: "compact", args: "", output: "Compacted", stream: "stdout",
                                         truncated: false, compact: CompactInfoWire(preTokens: 45_123, postTokens: 19_700)))
    }

    private func deliverCompactRecord() {
        feed(.sessionTurnDelta(tag: tag, delta: .turnStarted(compactRecordTurn())))
    }

    private var compactEnabled: Bool { strip.isEnabled(actionID: compactID) }

    private var tip: String { strip.tooltip(forActionID: compactID) ?? "" }

    private func pillHelp(_ id: String) -> String? { strip.pill(forActionID: id)?.accessibilityHelp() }

    // MARK: Defaults

    func testAFocusWithNoQuickActionsOfItsOwnGetsClearContextThenCompact() {
        XCTAssertEqual(QuickAction.replDefaults.map(\.label), ["Clear Context", "Compact"])
        XCTAssertEqual(QuickAction.replDefaults.map(\.id), [clearID, compactID])
        XCTAssertEqual(QuickAction.compact.prompt, "/compact")
        XCTAssertFalse(QuickAction.compact.clearFirst, "Compact keeps the conversation")
        XCTAssertTrue(QuickAction.clearContext.clearFirst)
    }

    func testThePaneDrawsTheTwoPillsInThatOrder() throws {
        let clear = try XCTUnwrap(strip.pill(forActionID: clearID))
        let compact = try XCTUnwrap(strip.pill(forActionID: compactID))

        XCTAssertEqual(clear.attributedTitle.string, "Clear Context")
        XCTAssertEqual(compact.attributedTitle.string, "Compact")
        let a = clear.convert(clear.bounds, to: strip)
        let b = compact.convert(compact.bounds, to: strip)
        XCTAssertLessThan(a.maxX, b.minX, "Clear Context first, Compact after it")
    }

    func testDynamicFocusViewBuildsItsReplWithTheSharedDefaultsAndKeepsAFocusOwnActions() throws {
        let source = try String(contentsOf: Self.sourceRoot.appendingPathComponent("UI/Views/DynamicFocusView.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func makeLeafView("), "makeLeafView")
        let body = String(source[start.lowerBound...].prefix(2_500))

        XCTAssertTrue(body.contains("focus.quickActions.isEmpty"), "a focus's own actions still decide")
        XCTAssertTrue(body.contains("QuickAction.replDefaults"), "the default strip is the shared defaults")
        XCTAssertFalse(body.contains("[QuickAction.clearContext]"), "no longer Clear Context alone")
        XCTAssertTrue(body.contains(": focus.quickActions"), "a focus with its own actions gets exactly those")
    }

    func testPerrisBuiltInActionsAreUnchangedAndHaveNoCompact() throws {
        let perri = try XCTUnwrap(Focus.builtIns.first { $0.id == "perri" })

        XCTAssertEqual(perri.quickActions.map(\.label), ["Start Reviewing", "Reset Layout"])
        XCTAssertFalse(perri.quickActions.contains { $0.id == compactID })
    }

    // MARK: Click

    func testClickingCompactSendsExactlyOneTypedCompactThroughTheSession() {
        XCTAssertTrue(compactEnabled)
        let before = anythingSent

        click()

        XCTAssertEqual(compactsSent, 1)
        XCTAssertEqual(anythingSent, before + 1, "nothing else is sent")
        XCTAssertEqual(session.turns.last?.userInput, "/compact")
    }

    func testClickingCompactDoesNotClearTheTranscript() {
        session.send("hello there")
        state(.idle)
        XCTAssertTrue(compactEnabled)

        click()

        XCTAssertEqual(session.turns.map(\.userInput), ["hello there", "/compact"], "the earlier turn is still there")
    }

    func testPressingCompactTwiceInARowSendsItOnce() {
        click()
        click()
        strip.tap(actionID: compactID)
        modelFlushMain()

        XCTAssertEqual(compactsSent, 1)
    }

    // MARK: Availability

    func testCompactIsEnabledWhenTheSessionIsHealthyAndIdle() {
        state(.idle)

        XCTAssertTrue(compactEnabled)
    }

    func testCompactIsDisabledWhileATurnIsRunningAndAClickSendsNothing() {
        state(.midTurn)
        XCTAssertFalse(compactEnabled)
        let before = anythingSent

        click()

        XCTAssertEqual(anythingSent, before)
        XCTAssertEqual(compactsSent, 0)
    }

    func testCompactIsDisabledWhileAnApprovalIsPending() {
        state(.awaitingPermission)

        XCTAssertFalse(compactEnabled)
    }

    func testCompactIsDisabledWhileTheSessionIsRecoveringAndComesBackWhenItIsHealthy() {
        state(.crashed)
        XCTAssertFalse(compactEnabled)
        let before = anythingSent
        click()
        XCTAssertEqual(anythingSent, before, "a click while recovering sends nothing")

        state(.idle)

        XCTAssertTrue(compactEnabled)
    }

    func testCompactIsDisabledWhenTheSessionIsPermanentlyDown() {
        feed(.sessionDown(tag: tag, reason: .crashLoopGuard))
        XCTAssertFalse(compactEnabled)
        let before = anythingSent

        click()

        XCTAssertEqual(anythingSent, before)
    }

    func testCompactIsDisabledFromTheClickUntilTheRecordAndTheTurnEndThenEnabledAgain() {
        click()
        XCTAssertFalse(compactEnabled, "pending the moment it is clicked")

        state(.midTurn)
        XCTAssertFalse(compactEnabled, "still pending while the daemon works")

        deliverCompactRecord()
        XCTAssertFalse(compactEnabled, "the record has arrived but the turn has not ended")

        state(.idle)
        XCTAssertTrue(compactEnabled, "available again once the record is in and the turn is over")
    }

    func testCompactComesBackWhenTheTurnEndsEvenIfNoRecordEverArrives() {
        click()
        state(.midTurn)

        state(.idle)

        XCTAssertTrue(compactEnabled, "a failed compaction must not leave the button dead")
    }

    func testAClickWhileDisabledSendsNothingEvenIfTheButtonIsPressedRepeatedly() {
        state(.midTurn)

        for _ in 0..<3 { click() }

        XCTAssertEqual(compactsSent, 0)
    }

    func testCompactCanBeUsedAgainAfterItFinishes() {
        click()
        state(.midTurn)
        deliverCompactRecord()
        state(.idle)

        click()

        XCTAssertEqual(compactsSent, 2)
    }

    func testClearContextStaysAvailableWhileCompactIsDisabled() {
        state(.midTurn)

        XCTAssertFalse(compactEnabled)
        XCTAssertTrue(strip.isEnabled(actionID: clearID), "disabling Compact does not dim its neighbour")
    }

    // MARK: Tooltip and VoiceOver

    func testTheEnabledTooltipExplainsWhatCompactDoes() {
        state(.idle)

        let text = tip.lowercased()
        XCTAssertTrue(text.contains("summar"), tip)
        XCTAssertTrue(text.contains("free context"), tip)
        XCTAssertTrue(text.contains("transcript stays"), tip)
        XCTAssertTrue(text.contains("while a turn is running"), tip)
    }

    func testTheHelpVoiceOverReadsIsTheTooltip() {
        XCTAssertEqual(pillHelp(compactID), tip)
        XCTAssertFalse(tip.isEmpty)
    }

    func testVoiceOverNamesTheButtonCompactConversationAndClearContextKeepsItsLabel() {
        XCTAssertEqual(strip.pill(forActionID: compactID)?.accessibilityLabel(), "Compact conversation")
        XCTAssertEqual(strip.pill(forActionID: clearID)?.accessibilityLabel(), "Clear Context")
    }

    func testADisabledTooltipSaysWhyAndStillExplainsTheButton() {
        state(.idle)
        let enabledTip = tip

        state(.midTurn)

        XCTAssertNotEqual(tip, enabledTip)
        XCTAssertTrue(tip.contains(enabledTip), "the reason comes first, then the usual explanation: \(tip)")
        XCTAssertTrue(tip.lowercased().contains("turn is running"), tip)
        XCTAssertEqual(pillHelp(compactID), tip, "VoiceOver hears the reason too")
        XCTAssertEqual(strip.pill(forActionID: compactID)?.accessibilityLabel(), "Compact conversation")
    }

    func testTheDisabledTooltipForADownSessionSaysTheSessionIsNotRunning() {
        feed(.sessionDown(tag: tag, reason: .crashLoopGuard))

        XCTAssertTrue(tip.lowercased().contains("session is not running"), tip)
        XCTAssertEqual(pillHelp(compactID), tip)
    }

    func testTheReasonDisappearsFromTheTooltipWhenCompactIsAvailableAgain() {
        state(.idle)
        let enabledTip = tip
        state(.midTurn)
        state(.idle)

        XCTAssertEqual(tip, enabledTip)
        XCTAssertEqual(pillHelp(compactID), enabledTip)
    }

    func testAPendingCompactTooltipSaysItIsUnavailable() {
        let enabledTip = tip

        click()

        XCTAssertNotEqual(tip, enabledTip)
        XCTAssertTrue(tip.contains(enabledTip))
    }

    // MARK: Helpers (source)

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)           // …/macOS/NostromoTests/CompactButtonTests.swift
            .deletingLastPathComponent()           // …/macOS/NostromoTests
            .deletingLastPathComponent()           // …/macOS
            .appendingPathComponent("Nostromo")
    }
}
