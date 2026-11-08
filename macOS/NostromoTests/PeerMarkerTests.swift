import XCTest
import AppKit
import Combine
import NostromoKit

// A user-role message the CLI injected (a message from another Claude session, a loaded skill, a
// conversation summary, other context) is ONE muted line in the transcript's user slot, never a user
// bubble and never the raw `<cross-session-message ...>` text. The marker has no target, so it is plain
// text for VoiceOver (not a button), and its Copy menu ("Copy Text") copies the message body, not the
// stand-in `userInput`.
//
// WakeMarkerView, ChatTurnView, ChatTurn, ChatSession, TurnHeightEstimator and the NostromoKit types are
// compiled into this target directly. No real pasteboard, no wall clock. Reuses the fixtures of
// WakeMarkerTests.swift (`MotherNoticeFixtures`, `TaskWakeFixtures`) and TurnOriginTests.swift
// (`OriginFixtures`).

// MARK: - Fixtures

enum PeerFixtures {

    static let body = "run the tests please"
    /// What the agent received (`userInput` of a peer turn): the raw tag, untrusted, never drawn.
    static let rawTag = "<cross-session-message from=\"/tmp/pdo.sock\" from-name=\"PDO Demo\" from-mode=\"bypass\">\n\(body)\n</cross-session-message>"
    static let line = "↘ Peer PDO Demo · bypass: run the tests please"

    static func item(name: String? = "PDO Demo", mode: String? = "bypass", body: String = PeerFixtures.body) -> PeerMessageItemWire {
        PeerMessageItemWire(fromName: name, fromMode: mode, fromSocket: nil, body: body, truncated: false)
    }

    /// `n` messages from one sender; the first one's body is `body`, the others `message 1`, `message 2`...
    static func origin(_ n: Int = 1, omitted: Int = 0, name: String? = "PDO Demo", mode: String? = "bypass") -> TurnOriginWire {
        .peerMessage(items: (0 ..< n).map { item(name: name, mode: mode, body: $0 == 0 ? body : "message \($0)") }, omitted: omitted)
    }

    static func turn(userInput: String = rawTag, origin: TurnOriginWire? = PeerFixtures.origin(), blocks: [TurnBlock] = [], seq: Int = 0) -> ChatTurn {
        OriginFixtures.turn(userInput: userInput, origin: origin, blocks: blocks, seq: seq)
    }

    /// The raw text of an injected turn: not what the marker shows or copies.
    static let standIn = "STAND-IN raw user input"
    static let skillText = "# Commit helper\nDo the thing.\nThen the other thing."

    static func injected(kind: String = "skill", title: String = "commit-helper", text: String = skillText,
                         truncated: Bool = false) -> TurnOriginWire {
        .injectedContext(kind: kind, title: title, text: text, truncated: truncated)
    }

    static func injectedTurn(userInput: String = standIn, origin: TurnOriginWire? = PeerFixtures.injected(), blocks: [TurnBlock] = [],
                             seq: Int = 0) -> ChatTurn {
        OriginFixtures.turn(userInput: userInput, origin: origin, blocks: blocks, seq: seq)
    }
}

// MARK: - The turn

final class PeerMarkerTurnViewTests: MouseQueueTestCase {

    func testAPeerMessageTurnDrawsTheMarkerAndNoBubbleOrDeliveryBlocks() {
        let view = MotherNoticeFixtures.turnView(PeerFixtures.turn())

        XCTAssertEqual(view.wakeMarkerView?.shownText, PeerFixtures.line)
        XCTAssertFalse(view.hasUserBubble)
        XCTAssertTrue(view.deliveryBlockViews.isEmpty)
    }

    func testNoViewInAPeerTurnHoldsTheRawTag() {
        let view = MotherNoticeFixtures.turnView(PeerFixtures.turn(blocks: [.text("On it.")]))
        view.setIslandWidth(700)
        _ = view.islandHeight()

        let strings = MotherNoticeFixtures.strings(in: view)

        XCTAssertTrue(strings.contains(PeerFixtures.line), "the walk reaches the marker: \(strings.count) strings")
        XCTAssertFalse(strings.contains { $0.contains("<cross-session-message") || $0.contains("</cross-session-message>") },
                       "no raw tag is drawn, announced or in a tooltip")
        XCTAssertFalse(strings.contains { $0.contains("from-mode=") || $0.contains("from-name=") })
    }

    func testABurstFromOneSenderDrawsTheCountedMarker() {
        let view = MotherNoticeFixtures.turnView(PeerFixtures.turn(origin: PeerFixtures.origin(3)))

        XCTAssertEqual(view.wakeMarkerView?.shownText, "↘ 3 peer messages from PDO Demo · bypass")
        XCTAssertFalse(view.hasUserBubble)
    }

    func testAPeerTurnWithTheConfirmReplySentinelStillShowsTheMarker() {
        let view = MotherNoticeFixtures.turnView(PeerFixtures.turn(userInput: PeerFixtures.rawTag + "\n(This answers your question: yes)"))

        XCTAssertEqual(view.wakeMarkerView?.shownText, PeerFixtures.line)
        XCTAssertFalse(view.hasUserBubble)
    }

    func testAnInjectedContextTurnDrawsItsMarkerAndNoBubbleWhateverTheKind() {
        let cases: [(origin: TurnOriginWire, line: String)] = [
            (PeerFixtures.injected(kind: "skill", title: "commit-helper"), "ⓘ Skill loaded: commit-helper"),
            (PeerFixtures.injected(kind: "summary", title: ""), "ⓘ Conversation summary"),
            (PeerFixtures.injected(kind: "other", title: ""), "ⓘ Injected context"),
        ]
        for (origin, line) in cases {
            let view = MotherNoticeFixtures.turnView(PeerFixtures.injectedTurn(origin: origin, blocks: [.text("On it.")]))
            view.setIslandWidth(700)
            _ = view.islandHeight()

            XCTAssertEqual(view.wakeMarkerView?.shownText, line)
            XCTAssertFalse(view.hasUserBubble, line)
            XCTAssertFalse(MotherNoticeFixtures.strings(in: view).contains { $0.contains("STAND-IN") },
                           "\(line): the stand-in text is not drawn or announced")
        }
    }

    func testAPlainTurnWhoseTextLooksLikeAPeerOrInjectedMessageIsABubble() {
        for text in [PeerFixtures.rawTag, PeerFixtures.line, "ⓘ Skill loaded: x", "ⓘ Conversation summary"] {
            let view = MotherNoticeFixtures.turnView(ChatTurn(userInput: text, timestamp: Date(), blocks: [], isComplete: true))

            XCTAssertNil(view.wakeMarkerView, text)
            XCTAssertTrue(view.hasUserBubble, text)
            XCTAssertEqual(view.userBubbleContent?.text, text, "nothing the agent received is hidden")
        }
    }

    func testATurnWhoseOriginHasNoReadableItemShowsAMarkerNotABubble() throws {
        let json = """
        {"id":"t1","user_input":\(String(data: try JSONEncoder().encode(PeerFixtures.rawTag), encoding: .utf8)!),
         "timestamp":null,"blocks":[],"is_complete":true,"origin":{"type":"peer_message","items":[7,"x"]}}
        """
        let decoded = try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))

        let view = MotherNoticeFixtures.turnView(PeerFixtures.turn(userInput: decoded.userInput, origin: decoded.origin))

        XCTAssertNotNil(view.wakeMarkerView)
        XCTAssertFalse(view.hasUserBubble)
    }

    // MARK: Origin predicates

    func testPeerAndInjectedTurnsAreInjectedMarkerOriginsAndNothingElse() {
        for turn in [PeerFixtures.turn(), PeerFixtures.turn(origin: PeerFixtures.origin(3)), PeerFixtures.injectedTurn()] {
            XCTAssertTrue(turn.hasInjectedOrigin)
            XCTAssertTrue(turn.hasMarkerOrigin)
            XCTAssertFalse(turn.hasTerminalOrigin)
            XCTAssertFalse(turn.hasMotherNoticeOrigin)
            XCTAssertFalse(turn.hasTaskWakeOrigin)
            XCTAssertNil(turn.motherNoticeMarker)
            XCTAssertNotNil(turn.markerContent)
        }
    }

    func testOtherTurnsAreNotInjectedOrigins() {
        let others = [MotherNoticeFixtures.turn(), TaskWakeFixtures.turn(), OriginFixtures.turn(),
                      ChatTurn(userInput: "hello", timestamp: Date(), blocks: [], isComplete: true)]
        for turn in others {
            XCTAssertFalse(turn.hasInjectedOrigin)
        }
        XCTAssertTrue(MotherNoticeFixtures.turn().hasMarkerOrigin)
        XCTAssertTrue(TaskWakeFixtures.turn().hasMarkerOrigin)
        XCTAssertFalse(OriginFixtures.turn().hasMarkerOrigin)
        XCTAssertFalse(others[3].hasMarkerOrigin)
    }

    func testTheMarkerContentOfAPeerTurnIsTheKitsText() {
        XCTAssertEqual(PeerFixtures.turn().markerContent, WakeMarkerText.peerMessage([PeerFixtures.item()], omitted: 0))
        XCTAssertEqual(PeerFixtures.injectedTurn().markerContent,
                       WakeMarkerText.injectedContext(kind: "skill", title: "commit-helper", text: PeerFixtures.skillText, truncated: false))
    }
}

// MARK: - The marker view

/// The marker has no target: plain static text for VoiceOver, no focus, and a click, Return or Space does nothing.
final class PeerMarkerViewTests: MouseQueueTestCase {

    private var routed: [WakeMarkerTarget] = []

    private func marker(_ content: WakeMarkerContent) -> WakeMarkerView {
        WakeMarkerView(content: content, noticeText: "unused", router: { [weak self] in self?.routed.append($0) },
                       copyMenuTitle: WakeMarkerView.copyTextMenuTitle, pasteboard: MotherNoticeFixtures.pasteboard(self))
    }

    private var peer: WakeMarkerView { marker(WakeMarkerText.peerMessage([PeerFixtures.item()], omitted: 0)) }

    func testThePeerMarkerIsStaticTextNotAButtonLabelledWithTheSpokenSentence() {
        let view = peer

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertNotEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "Message from session PDO Demo, bypass mode: run the tests please.")
        XCTAssertNil(view.accessibilityHelp())
    }

    func testAnInjectedMarkerIsStaticTextToo() {
        let view = marker(WakeMarkerText.injectedContext(kind: "skill", title: "commit-helper", text: PeerFixtures.skillText, truncated: false))

        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertTrue(view.accessibilityLabel()?.hasPrefix("Skill loaded: commit-helper") == true)
        XCTAssertFalse(view.accessibilityPerformPress())
    }

    func testTheMarkerTakesNoKeyboardFocusAndClickReturnAndSpaceRouteNothing() {
        let view = peer

        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.canBecomeKeyView)
        view.activate()
        view.keyDown(with: MotherNoticeFixtures.keyDown(36, "\r"))
        view.keyDown(with: MotherNoticeFixtures.keyDown(49, " "))
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertEqual(routed, [])
    }

    func testTheTooltipIsTheBodyAndTheViewIsOneFixedHeightLine() {
        let view = peer

        XCTAssertEqual(view.toolTip, PeerFixtures.body)
        XCTAssertEqual(view.shownText, PeerFixtures.line)
        for width: CGFloat in [1, 220, 900] {
            XCTAssertEqual(view.arithmeticHeight(atWidth: width), TurnHeightEstimator.wakeMarkerHeight, "width \(width)")
        }
    }
}

// MARK: - Copy Text

/// The Copy menu of an injected marker copies the message, never the raw tag or the stand-in text.
final class PeerMarkerCopyTests: MouseQueueTestCase {

    private func choose(_ marker: WakeMarkerView) throws {
        let menu = try XCTUnwrap(marker.menu(for: MotherNoticeFixtures.rightClick()), "a marker has a context menu")
        let item = try XCTUnwrap(menu.items.first)
        _ = (item.target as? NSObject)?.perform(try XCTUnwrap(item.action), with: item)
    }

    /// What the turn's marker puts on a pasteboard when its Copy menu item is chosen, built the way the turn view builds it.
    private func copied(from turn: ChatTurn) throws -> String? {
        let board = MotherNoticeFixtures.pasteboard(self)
        let marker = WakeMarkerView(content: try XCTUnwrap(turn.markerContent), noticeText: turn.markerCopyText,
                                    copyMenuTitle: WakeMarkerView.copyTextMenuTitle, pasteboard: board)
        try choose(marker)
        return board.string(forType: .string)
    }

    func testTheMenuItemIsNamedCopyTextOnPeerAndInjectedTurns() {
        XCTAssertEqual(WakeMarkerView.copyTextMenuTitle, "Copy Text")
        for turn in [PeerFixtures.turn(), PeerFixtures.turn(origin: PeerFixtures.origin(3)), PeerFixtures.injectedTurn()] {
            let view = MotherNoticeFixtures.turnView(turn)

            XCTAssertEqual(view.wakeMarkerView?.menu(for: MotherNoticeFixtures.rightClick())?.items.map(\.title), ["Copy Text"])
        }
    }

    func testCopyTextOnAPeerTurnCopiesTheBodyNotTheRawTag() throws {
        let turn = PeerFixtures.turn()

        XCTAssertEqual(turn.markerCopyText, PeerFixtures.body)
        XCTAssertNotEqual(turn.markerCopyText, turn.userInput)
        XCTAssertEqual(try copied(from: turn), PeerFixtures.body)
    }

    func testCopyTextOnAMultiLinePeerBodyCopiesAllOfIt() throws {
        let body = "first line\nsecond line\n\nfourth line"
        let turn = PeerFixtures.turn(origin: .peerMessage(items: [PeerFixtures.item(body: body)], omitted: 0))

        XCTAssertEqual(try copied(from: turn), body)
    }

    func testCopyTextOnABurstCopiesEveryBodySeparatedByABlankLine() throws {
        let turn = PeerFixtures.turn(origin: PeerFixtures.origin(3))

        XCTAssertEqual(try copied(from: turn), "\(PeerFixtures.body)\n\nmessage 1\n\nmessage 2")
    }

    func testCopyTextOnAnInjectedTurnCopiesItsTextNotTheStandIn() throws {
        let turn = PeerFixtures.injectedTurn()

        XCTAssertEqual(turn.markerCopyText, PeerFixtures.skillText)
        XCTAssertNotEqual(turn.markerCopyText, turn.userInput)
        XCTAssertEqual(try copied(from: turn), PeerFixtures.skillText)
    }

    func testCopyTextIsNeverTheMarkerLine() throws {
        for turn in [PeerFixtures.turn(), PeerFixtures.injectedTurn()] {
            let copy = try XCTUnwrap(try copied(from: turn))

            XCTAssertFalse(copy.contains("↘"))
            XCTAssertFalse(copy.contains("ⓘ"))
        }
    }

    func testTheMotherAndWakeCopyBehaviourIsUnchanged() {
        XCTAssertEqual(MotherNoticeFixtures.turn().markerCopyText, MotherNoticeFixtures.rawText)
        XCTAssertEqual(TaskWakeFixtures.turn().markerCopyText, TaskWakeFixtures.line)
        XCTAssertEqual(MotherNoticeFixtures.turnView(MotherNoticeFixtures.turn()).wakeMarkerView?.menu(for: MotherNoticeFixtures.rightClick())?.items.first?.title,
                       "Copy Notice Text")
        XCTAssertEqual(MotherNoticeFixtures.turnView(TaskWakeFixtures.turn()).wakeMarkerView?.menu(for: MotherNoticeFixtures.rightClick())?.items.first?.title,
                       "Copy Event Text")
    }
}

// MARK: - Height

/// A peer or injected turn's user slot is the same fixed 22 pt marker and 8 pt gap whatever the text
/// holds: the estimate is what is drawn.
final class PeerMarkerHeightTests: MouseQueueTestCase {

    private let fiftyKB = String(repeating: "padding of the message body. ", count: 1_800)

    private func drawn(_ turn: ChatTurn, width: CGFloat) -> CGFloat {
        let view = MotherNoticeFixtures.turnView(turn)
        view.setIslandWidth(width)
        return view.islandHeight()
    }

    private var turns: [(name: String, turn: ChatTurn)] {
        [("peer", PeerFixtures.turn()),
         ("peer burst", PeerFixtures.turn(origin: PeerFixtures.origin(25, omitted: 5))),
         ("peer 50 KB", PeerFixtures.turn(userInput: PeerFixtures.rawTag + fiftyKB,
                                          origin: .peerMessage(items: [PeerFixtures.item(body: fiftyKB)], omitted: 0))),
         ("peer long name", PeerFixtures.turn(origin: PeerFixtures.origin(name: String(repeating: "W", count: 400)))),
         ("skill", PeerFixtures.injectedTurn()),
         ("summary 50 KB", PeerFixtures.injectedTurn(userInput: fiftyKB, origin: PeerFixtures.injected(kind: "summary", text: fiftyKB)))]
    }

    func testTheEstimateIsChromePlusMarkerPlusGapWhateverTheTextLength() {
        let expected = TurnHeightEstimator.turnChrome + TurnHeightEstimator.wakeMarkerHeight + TurnHeightEstimator.userSlotGap
        for (name, turn) in turns {
            for width: CGFloat in [220, 700, 900] {
                XCTAssertEqual(TurnHeightEstimator.estimate(turn, width: width), expected, accuracy: 0.001, "\(name) at width \(width)")
            }
        }
    }

    func testTheEstimateEqualsTheDrawnHeightWithinOnePoint() {
        for (name, turn) in turns {
            for width: CGFloat in [220, 700, 900] {
                XCTAssertEqual(drawn(turn, width: width), TurnHeightEstimator.estimate(turn, width: width), accuracy: 1,
                               "\(name) at width \(width)")
            }
        }
    }

    func testTheAgentsAnswerBelowAddsTheSameHeightAsBelowAMotherMarker() {
        let blocks: [TurnBlock] = [.text("On it."), .text("Done.")]
        for width: CGFloat in [220, 700] {
            let mother = TurnHeightEstimator.estimate(MotherNoticeFixtures.turn(blocks: blocks), width: width)

            XCTAssertEqual(TurnHeightEstimator.estimate(PeerFixtures.turn(blocks: blocks), width: width), mother, accuracy: 0.001)
            XCTAssertEqual(TurnHeightEstimator.estimate(PeerFixtures.injectedTurn(blocks: blocks), width: width), mother, accuracy: 0.001)
        }
    }

    func testATurnWhoseOriginDidNotDecodeEstimatesItsBubbleSoItCannotBeUnderEstimated() {
        let plain = PeerFixtures.turn(userInput: PeerFixtures.rawTag + fiftyKB, origin: nil)
        let peer = PeerFixtures.turn(userInput: PeerFixtures.rawTag + fiftyKB)

        XCTAssertGreaterThan(TurnHeightEstimator.estimate(plain, width: 700), TurnHeightEstimator.estimate(peer, width: 700))
    }
}

// MARK: - Session frames

/// A `session_turn_origin` frame merging a later peer message into an open peer turn updates its marker;
/// a peer frame can never create a marker where there was none.
final class PeerMarkerSessionTests: XCTestCase {

    private func makeSession() -> (ChatSession, NostromodClient) {
        let client = NostromodClient(socketPath: "/dev/null")
        return (ChatSession(tag: "test", agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client), client)
    }

    private func daemonTurn(_ n: Int, input: String? = nil, origin: TurnOriginWire? = nil) -> DaemonTurn {
        DaemonTurn(id: "d\(n)", userInput: input ?? "message \(n)", timestamp: "2026-11-01T15:00:0\(n).000Z",
                   blocks: [], isComplete: true, origin: origin)
    }

    private func load(_ turns: [DaemonTurn], into client: NostromodClient, session: ChatSession) {
        client.messages.send(.sessionTurns(tag: "test", turns: turns))
        _ = modelWaitUntil { session.turns.count == turns.count }
        modelFlushMain()
    }

    private func frame(_ client: NostromodClient, id: String, _ origin: TurnOriginWire, tag: String = "test") {
        client.messages.send(.sessionTurnOrigin(tag: tag, turnId: id, origin: origin))
        modelFlushMain()
    }

    private func isSplice(_ change: TurnChange) -> Bool {
        if case .spliced = change { return true }
        return false
    }

    private func peerSession() -> (ChatSession, NostromodClient) {
        let (session, client) = makeSession()
        load([daemonTurn(0), daemonTurn(1, input: PeerFixtures.rawTag, origin: PeerFixtures.origin(1))], into: client, session: session)
        return (session, client)
    }

    func testAFrameMergesASecondPeerMessageIntoTheOpenPeerTurnAndKeepsItsIdentityAndText() {
        let (session, client) = peerSession()
        let before = session.turns[1]
        var changes: [TurnChange] = []
        let sub = session.changes.sink { changes.append($0) }

        frame(client, id: "d1", PeerFixtures.origin(2))

        XCTAssertEqual(session.turns[1].origin, PeerFixtures.origin(2))
        XCTAssertEqual(session.turns[1].id, before.id)
        XCTAssertEqual(session.turns[1].userInput, before.userInput)
        XCTAssertEqual(session.turns[1].identityKey, before.identityKey)
        XCTAssertEqual(session.turns[1].markerContent?.line, "↘ 2 peer messages from PDO Demo · bypass")
        XCTAssertTrue(changes.contains { if case .spliced(let from) = $0 { return from == 1 } else { return false } })
        sub.cancel()
    }

    func testMessagesTheDaemonDroppedCountTowardWhatTheFrameHolds() {
        let (session, client) = peerSession()

        frame(client, id: "d1", PeerFixtures.origin(1, omitted: 2))

        XCTAssertEqual(session.turns[1].markerContent?.line, "↘ 3 peer messages from PDO Demo · bypass")
    }

    func testARepeatFrameChangesNothingAndTellsNoOne() {
        let (session, client) = makeSession()
        load([daemonTurn(0), daemonTurn(1, input: PeerFixtures.rawTag, origin: PeerFixtures.origin(3))], into: client, session: session)
        var changes: [TurnChange] = []
        let sub = session.changes.sink { changes.append($0) }

        frame(client, id: "d1", PeerFixtures.origin(3))

        XCTAssertEqual(session.turns[1].origin, PeerFixtures.origin(3))
        XCTAssertFalse(changes.contains(where: isSplice), "a repeat frame does not rebuild the turn view: \(changes)")
        sub.cancel()
    }

    func testAFrameWithFewerMessagesThanTheMarkerShowsDoesNotShrinkTheMarker() {
        let (session, client) = makeSession()
        load([daemonTurn(0), daemonTurn(1, input: PeerFixtures.rawTag, origin: PeerFixtures.origin(3))], into: client, session: session)
        var changes: [TurnChange] = []
        let sub = session.changes.sink { changes.append($0) }

        frame(client, id: "d1", PeerFixtures.origin(2))
        frame(client, id: "d1", PeerFixtures.origin(1))

        XCTAssertEqual(session.turns[1].origin, PeerFixtures.origin(3), "the marker never goes back to a smaller count")
        XCTAssertFalse(changes.contains(where: isSplice), "and the turn view is not rebuilt for it: \(changes)")
        sub.cancel()
    }

    func testAPeerFrameNeverTurnsABubbleOrAnotherOriginIntoAPeerMarker() {
        let (session, client) = makeSession()
        let mother = MotherNoticeFixtures.singleOrigin
        let terminal = OriginFixtures.combinedOrigin
        let wake = TaskWakeFixtures.origin(1)
        let injected = PeerFixtures.injected()
        load([daemonTurn(0), daemonTurn(1, origin: mother), daemonTurn(2, input: OriginFixtures.combinedText, origin: terminal),
              daemonTurn(3, input: TaskWakeFixtures.fallback, origin: wake), daemonTurn(4, input: PeerFixtures.standIn, origin: injected)],
             into: client, session: session)

        for id in ["d0", "d1", "d2", "d3", "d4", "nope"] { frame(client, id: id, PeerFixtures.origin(2)) }

        XCTAssertNil(session.turns[0].origin, "a plain bubble stays a bubble")
        XCTAssertEqual(session.turns[1].origin, mother)
        XCTAssertEqual(session.turns[2].origin, terminal)
        XCTAssertEqual(session.turns[3].origin, wake, "a wake turn does not become a peer turn")
        XCTAssertEqual(session.turns[4].origin, injected)
        XCTAssertFalse(session.turns[0].hasMarkerOrigin)
    }

    func testAnInjectedContextFrameNeverTurnsABubbleIntoAMarker() {
        let (session, client) = makeSession()
        load([daemonTurn(0), daemonTurn(1, input: PeerFixtures.rawTag, origin: PeerFixtures.origin(1))], into: client, session: session)

        frame(client, id: "d0", PeerFixtures.injected())
        frame(client, id: "d1", PeerFixtures.injected())

        XCTAssertNil(session.turns[0].origin)
        XCTAssertEqual(session.turns[1].origin, PeerFixtures.origin(1), "a peer turn does not become an injected-context turn")
    }

    func testAFrameWithAnotherKindOfOriginOrAnotherTagChangesNothingOnAPeerTurn() {
        let (session, client) = peerSession()

        frame(client, id: "d1", TaskWakeFixtures.origin(3))
        frame(client, id: "d1", MotherNoticeFixtures.singleOrigin)
        frame(client, id: "d1", OriginFixtures.combinedOrigin)
        frame(client, id: "d1", PeerFixtures.origin(3), tag: "other")

        XCTAssertEqual(session.turns[1].origin, PeerFixtures.origin(1))
    }

    func testAMergeMissedWhileDisconnectedShowsAfterReattachWithTheSameTurn() {
        let (session, client) = peerSession()
        let ids = session.turns.map(\.id)

        client.messages.send(.sessionTurns(tag: "test", turns: [daemonTurn(0),
            daemonTurn(1, input: PeerFixtures.rawTag, origin: PeerFixtures.origin(2))]))
        modelFlushMain()

        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(session.turns.filter { $0.isGapMarker }.count, 0)
        XCTAssertEqual(session.turns.map(\.id), ids)
        XCTAssertEqual(session.turns[1].markerContent?.line, "↘ 2 peer messages from PDO Demo · bypass")
    }
}
