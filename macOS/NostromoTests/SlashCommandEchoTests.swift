import XCTest
import AppKit
import Combine
import NostromoKit

// Typing a slash command (`/context`) into a focus: the transcript shows ONE muted line, `/context · sent`,
// never a user bubble, until the daemon says what the command was. Its turn then ADOPTS that echo: a
// `local_command` origin turns it into a muted, collapsible record; a turn with no origin (a prompt-type
// command such as a skill) turns it into the ordinary bubble. Only a daemon that advertised
// `slash_commands_v1` makes such a turn, so with an older one the echo stays today's plain bubble.
//
// ChatSession, ChatTurn, ChatTurnView, NostromodClient, TurnHeightEstimator and the NostromoKit types are
// compiled into this target directly. The client points at `/dev/null`; the daemon's turns are fed to
// `client.messages`, as `PeerMarkerSessionTests` does. Reuses `MotherNoticeFixtures` (WakeMarkerTests.swift)
// and `PeerFixtures` (PeerMarkerTests.swift).

final class SlashCommandEchoTests: XCTestCase {

    private let newDaemon = [NostromodClient.slashCommandsFeature]

    private var client: NostromodClient!
    private var session: ChatSession!
    private var changes: [TurnChange] = []
    private var subscription: AnyCancellable?

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
        session = ChatSession(tag: "test", agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)
        changes = []
        subscription = session.changes.sink { [weak self] in self?.changes.append($0) }
    }

    override func tearDown() {
        subscription?.cancel()
        subscription = nil
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func advertiseSlashCommands() {
        client.setAdvertisedFeaturesForTesting(newDaemon)
    }

    private func localCommand(_ command: String = "context", args: String = "", output: String = "3k tokens used",
                              stream: String = "stdout") -> TurnOriginWire {
        .localCommand(command: command, args: args, output: output, stream: stream, truncated: false)
    }

    private func daemonTurn(_ id: String = "t0", input: String, origin: TurnOriginWire?, complete: Bool = true) -> DaemonTurn {
        DaemonTurn(id: id, userInput: input, timestamp: nil, blocks: [], isComplete: complete, origin: origin)
    }

    private func deliver(_ turn: DaemonTurn) {
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnStarted(turn)))
        modelFlushMain()
    }

    private func view(_ turn: ChatTurn, width: CGFloat = 700) -> ChatTurnView {
        let v = MotherNoticeFixtures.turnView(turn)
        v.setIslandWidth(width)
        _ = v.islandHeight()
        return v
    }

    private func splicedFrom() -> [Int] {
        changes.compactMap { if case .spliced(let from) = $0 { return from } else { return nil } }
    }

    // MARK: The pending echo

    func testSendingASlashCommandMakesAPendingEchoThatIsOneMutedLineAndNoBubble() {
        advertiseSlashCommands()

        session.send("/context")

        XCTAssertEqual(session.turns.count, 1)
        let echo = session.turns[0]
        XCTAssertTrue(echo.pendingCommand)
        XCTAssertTrue(echo.isPendingCommandEcho)
        XCTAssertNil(echo.daemonId)
        XCTAssertEqual(echo.markerContent?.line, "/context · sent")
        XCTAssertEqual(echo.markerContent?.accessibilityLabel, "Command /context, sent")

        let rendered = view(echo)
        XCTAssertEqual(rendered.wakeMarkerView?.shownText, "/context · sent")
        XCTAssertFalse(rendered.hasUserBubble, "a command is not a message from the user")
        XCTAssertNil(rendered.localCommandRecordView)
    }

    func testTheEchoLineKeepsTheArgumentsButTheAnnouncementNamesOnlyTheCommand() {
        advertiseSlashCommands()

        session.send("/model haiku")

        XCTAssertEqual(session.turns[0].markerContent?.line, "/model haiku · sent")
        XCTAssertEqual(session.turns[0].markerContent?.accessibilityLabel, "Command /model, sent")
    }

    func testAPendingEchoIsEstimatedAsOneMarkerLine() {
        advertiseSlashCommands()
        session.send("/context")

        for width: CGFloat in [300, 700] {
            XCTAssertEqual(TurnHeightEstimator.estimate(session.turns[0], width: width),
                           TurnHeightEstimator.turnChrome + TurnHeightEstimator.wakeMarkerHeight + TurnHeightEstimator.userSlotGap,
                           accuracy: 0.001, "width \(width)")
        }
    }

    // MARK: Old daemon

    func testAnOldDaemonKeepsTodaysPlainBubbleForASlashCommand() {
        // No `welcome.features` at all, an empty list, and a list without the feature.
        let featureLists: [[String]?] = [nil, [], ["work", "model"]]
        for features in featureLists {
            let client = NostromodClient(socketPath: "/dev/null")
            if let features { client.setAdvertisedFeaturesForTesting(features) }
            let session = ChatSession(tag: "test", agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)

            session.send("/context")

            XCTAssertFalse(session.turns[0].pendingCommand, "features \(String(describing: features))")
            XCTAssertNil(session.turns[0].markerContent)
            let rendered = view(session.turns[0])
            XCTAssertTrue(rendered.hasUserBubble, "features \(String(describing: features))")
            XCTAssertEqual(rendered.userBubbleContent?.text, "/context")
            XCTAssertNil(rendered.wakeMarkerView)
        }
    }

    // MARK: Text that is not a command

    func testTextThatIsNotACommandIsNeverAPendingEchoEvenForANewDaemon() {
        advertiseSlashCommands()
        let texts = ["/usr/bin/env x", "//", "hello /x", "/", "/ context", "context", "/tmp/x.log is full", "/a/b"]

        for text in texts { session.send(text) }

        XCTAssertEqual(session.turns.count, texts.count)
        for (turn, text) in zip(session.turns, texts) {
            XCTAssertFalse(turn.pendingCommand, text)
            XCTAssertFalse(turn.isPendingCommandEcho, text)
            XCTAssertNil(turn.markerContent, text)
            XCTAssertEqual(turn.userInput, text)
        }
    }

    func testACommandSentWithImagesIsABubbleNotAPendingEcho() {
        advertiseSlashCommands()

        session.send("/context", images: [URL(fileURLWithPath: "/tmp/slash-echo-test.png")])

        XCTAssertFalse(session.turns[0].pendingCommand)
    }

    func testIsTypedSlashCommandTable() {
        let commands = ["/context", "/model haiku", "/model   haiku", "/x", "/context\n", "\n/context", "  /context  ",
                        "/hookify:list", "/review-pr 123", "/model haiku\nsecond line"]
        let notCommands = ["", " ", "/", " / ", "//", "///x", "/ x", "/usr/bin/env x", "/a/b arg", "hello /x", "context",
                           "x /context", "\\/context"]

        for text in commands { XCTAssertTrue(ChatSession.isTypedSlashCommand(text), "\(text.debugDescription) is a command") }
        for text in notCommands { XCTAssertFalse(ChatSession.isTypedSlashCommand(text), "\(text.debugDescription) is not a command") }
    }

    // MARK: Adoption by the daemon's turn

    func testALocalCommandTurnAdoptsTheEchoAndBecomesARecordInPlace() {
        advertiseSlashCommands()
        session.send("/context")
        changes = []

        deliver(daemonTurn(input: "/context", origin: localCommand(output: "3k tokens used")))

        XCTAssertEqual(session.turns.count, 1, "the echo is adopted, not duplicated")
        let turn = session.turns[0]
        XCTAssertEqual(turn.daemonId, "t0")
        XCTAssertEqual(turn.origin, localCommand(output: "3k tokens used"))
        XCTAssertFalse(turn.pendingCommand)
        XCTAssertFalse(turn.isPendingCommandEcho)
        XCTAssertTrue(turn.hasLocalCommandOrigin)
        XCTAssertEqual(splicedFrom(), [0], "the turn's view is rebuilt: its user slot changed kind")

        let rendered = view(turn)
        XCTAssertEqual(rendered.localCommandRecordView?.headerText, "/context · 3k tokens used")
        XCTAssertNil(rendered.wakeMarkerView, "the sent line is gone")
        XCTAssertFalse(rendered.hasUserBubble)
    }

    func testARecordKeepsTheCommandsArgumentsAndStream() {
        advertiseSlashCommands()
        session.send("/model nope")

        deliver(daemonTurn(input: "/model nope", origin: localCommand("model", args: "nope", output: "Unknown model", stream: "stderr")))

        XCTAssertEqual(view(session.turns[0]).localCommandRecordView?.headerText, "/model nope · error · Unknown model")
    }

    func testATurnWithNoOriginAdoptsTheEchoAndBecomesTheOrdinaryBubble() {
        advertiseSlashCommands()
        session.send("/review-pr 12")
        XCTAssertTrue(session.turns[0].isPendingCommandEcho)
        changes = []

        deliver(daemonTurn(input: "/review-pr 12", origin: nil, complete: false))

        XCTAssertEqual(session.turns.count, 1)
        let turn = session.turns[0]
        XCTAssertEqual(turn.daemonId, "t0")
        XCTAssertNil(turn.origin)
        XCTAssertFalse(turn.pendingCommand)
        XCTAssertFalse(turn.isPendingCommandEcho)
        XCTAssertEqual(splicedFrom(), [0], "the user slot changes from a sent line to a bubble")

        let rendered = view(turn)
        XCTAssertTrue(rendered.hasUserBubble)
        XCTAssertEqual(rendered.userBubbleContent?.text, "/review-pr 12")
        XCTAssertNil(rendered.wakeMarkerView)
        XCTAssertNil(rendered.localCommandRecordView)
    }

    func testALocalCommandTurnWithNoEchoIsAppendedAsARecord() {
        advertiseSlashCommands()

        deliver(daemonTurn(input: "/context", origin: localCommand()))

        XCTAssertEqual(session.turns.count, 1)
        XCTAssertTrue(session.turns[0].hasLocalCommandOrigin)
        XCTAssertNotNil(view(session.turns[0]).localCommandRecordView)
    }

    func testAnInjectedOrPeerTurnWhoseTextEqualsThePendingCommandNeverAdoptsIt() {
        advertiseSlashCommands()
        session.send("/context")

        deliver(daemonTurn("t0", input: "/context",
                           origin: .injectedContext(kind: "skill", title: "x", text: "body", truncated: false)))
        _ = modelWaitUntil { self.session.turns.count == 2 }
        deliver(daemonTurn("t1", input: "/context", origin: PeerFixtures.origin()))
        _ = modelWaitUntil { self.session.turns.count == 3 }

        XCTAssertNil(session.turns[0].daemonId, "the human's echo stays unbound, waiting for its own turn")
        XCTAssertTrue(session.turns[0].isPendingCommandEcho)
        XCTAssertNil(session.turns[0].origin)

        deliver(daemonTurn("t2", input: "/context", origin: localCommand()))

        XCTAssertEqual(session.turns.count, 3, "the command's own turn then adopts its echo")
        XCTAssertEqual(session.turns[0].daemonId, "t2")
        XCTAssertTrue(session.turns[0].hasLocalCommandOrigin)
    }

    // MARK: The wire, through the Mac's own turn decoder

    func testTheMacTurnDecoderReadsALocalCommandOriginAndFallsBackToNilWithoutACommand() throws {
        func turn(_ origin: String) throws -> DaemonTurn {
            let json = #"{"id":"t1","user_input":"/context","timestamp":null,"blocks":[],"is_complete":true,"origin":\#(origin)}"#
            return try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try turn(#"{"type":"local_command","command":"context","output":"x"}"#).origin,
                       .localCommand(command: "context", args: "", output: "x", stream: "stdout", truncated: false))
        XCTAssertNil(try turn(#"{"type":"local_command","output":"orphan"}"#).origin,
                     "a record with no command is the plain bubble of its user_input")
    }
}
