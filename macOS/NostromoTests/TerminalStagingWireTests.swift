import XCTest
import Foundation

// The staging wire: `terminal_staging_list` (daemon -> app) and the three client frames
// (`terminal_staging_inserted`, `_remove`, `_clear`), against the golden files the daemon's tests pin
// (`tests/fixtures/terminal_staging/`).
//
//   * Every list fixture decodes (active, frozen, none, fractional-second timestamps); an unknown `state`
//     decodes as `none`, so a drawer for a state this app does not know never appears.
//   * The client frames encode key for key to the golden JSON.
//   * `NostromodClient.decode` turns the frame into `ServerMsg.terminalStagingList`, and this app declares
//     `terminal_staging_ui`, which is what makes the daemon send it at all.

final class TerminalStagingWireTests: XCTestCase {

    private let id = "5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11"

    // 2026-10-30T15:04:05Z, 15:06:01Z, 15:07:30Z
    private let t0 = Date(timeIntervalSince1970: 1_793_372_645)
    private let t1 = Date(timeIntervalSince1970: 1_793_372_761)
    private let t2 = Date(timeIntervalSince1970: 1_793_372_850)

    private func list(_ fixture: String) throws -> TerminalStagingList {
        try JSONDecoder().decode(TerminalStagingList.self, from: try StagingFixtures.fixtureData(fixture))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Decoding the list

    func testTheActiveFrameDecodesEveryField() throws {
        let list = try self.list("frame-terminal-staging-list-active.json")

        XCTAssertEqual(list.terminalId, id)
        XCTAssertEqual(list.paneId, "terminal-00000001")
        XCTAssertEqual(list.state, .active)
        XCTAssertEqual(list.ownerTag, "cody-fixture")
        XCTAssertEqual(list.agentName, "Cody")
        XCTAssertEqual(list.revision, 7)
        XCTAssertEqual(list.entries.count, 2)

        let first = list.entries[0]
        XCTAssertEqual(first.id, "s-00000001")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.command, "git status --short")
        XCTAssertEqual(first.note, "see what changed")
        XCTAssertEqual(first.stagedAt, t0)
        XCTAssertEqual(first.changedAt, t0)
        XCTAssertEqual(first.insertedCount, 0)
        XCTAssertNil(first.lastInsertedAt)

        let second = list.entries[1]
        XCTAssertEqual(second.id, "s-00000002")
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.command, "ls -la src/terminal")
        XCTAssertNil(second.note, "a missing note is nil")
        XCTAssertEqual(second.stagedAt, t0)
        XCTAssertEqual(second.changedAt, t1)
        XCTAssertEqual(second.insertedCount, 2)
        XCTAssertEqual(second.lastInsertedAt, t2)
    }

    func testTheFrozenFrameDecodesAsFrozenWithItsEntries() throws {
        let list = try self.list("frame-terminal-staging-list-frozen.json")

        XCTAssertEqual(list.state, .frozen)
        XCTAssertEqual(list.revision, 8)
        XCTAssertEqual(list.entries.map(\.command), ["git status --short", "ls -la src/terminal"])
    }

    func testTheNoneFrameDecodesAsNoneWithNoEntries() throws {
        let list = try self.list("frame-terminal-staging-list-none.json")

        XCTAssertEqual(list.state, TerminalStagingState.none)
        XCTAssertEqual(list.revision, 9)
        XCTAssertEqual(list.agentName, "")
        XCTAssertTrue(list.entries.isEmpty)
    }

    func testFractionalSecondTimestampsDecodeToTheMillisecond() throws {
        let list = try self.list("frame-terminal-staging-list-fractional.json")

        XCTAssertEqual(list.revision, 11)
        let entry = try XCTUnwrap(list.entries.first)
        XCTAssertEqual(entry.stagedAt.timeIntervalSince1970, 1_793_372_645.123, accuracy: 0.001)
        XCTAssertEqual(entry.changedAt.timeIntervalSince1970, 1_793_372_761.456, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(entry.lastInsertedAt).timeIntervalSince1970, 1_793_372_850.789, accuracy: 0.001)
        XCTAssertEqual(entry.insertedCount, 1)
    }

    func testAnUnknownStateDecodesAsNoneSoNoDrawerAppears() throws {
        var frame = try jsonObject(try StagingFixtures.fixtureData("frame-terminal-staging-list-active.json"))
        for state in ["archived", "ACTIVE", "", "Frozen "] {
            frame["state"] = state
            let decoded = try JSONDecoder().decode(TerminalStagingList.self, from: try JSONSerialization.data(withJSONObject: frame))
            XCTAssertEqual(decoded.state, TerminalStagingState.none, "state \"\(state)\"")
        }
    }

    func testAMissingStateDecodesAsNone() throws {
        var frame = try jsonObject(try StagingFixtures.fixtureData("frame-terminal-staging-list-active.json"))
        frame["state"] = nil
        let decoded = try JSONDecoder().decode(TerminalStagingList.self, from: try JSONSerialization.data(withJSONObject: frame))
        XCTAssertEqual(decoded.state, TerminalStagingState.none)
    }

    func testMissingOptionalFieldsDefaultInsteadOfDroppingTheFrame() throws {
        let json = """
        {"type":"terminal_staging_list","terminal_id":"t1","revision":3,
         "entries":[{"id":"s-1","number":1,"command":"ls","staged_at":"2026-10-30T15:04:05Z","changed_at":"2026-10-30T15:04:05Z"}]}
        """
        let decoded = try JSONDecoder().decode(TerminalStagingList.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.paneId, "")
        XCTAssertEqual(decoded.ownerTag, "")
        XCTAssertEqual(decoded.agentName, "")
        XCTAssertEqual(decoded.entries.first?.insertedCount, 0)
        XCTAssertNil(decoded.entries.first?.lastInsertedAt)
    }

    func testATimestampThatIsNotRFC3339IsAnErrorNotAMadeUpDate() throws {
        var frame = try jsonObject(try StagingFixtures.fixtureData("frame-terminal-staging-list-active.json"))
        var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
        entries[0]["changed_at"] = "yesterday"
        frame["entries"] = entries
        let data = try JSONSerialization.data(withJSONObject: frame)

        XCTAssertThrowsError(try JSONDecoder().decode(TerminalStagingList.self, from: data))
    }

    func testACommandIsDecodedExactlyAsSentWithoutTrimming() throws {
        var frame = try jsonObject(try StagingFixtures.fixtureData("frame-terminal-staging-list-active.json"))
        var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
        let odd = "  echo\u{00A0}hi\u{202E}  "
        entries[0]["command"] = odd
        frame["entries"] = entries
        let decoded = try JSONDecoder().decode(TerminalStagingList.self, from: try JSONSerialization.data(withJSONObject: frame))

        XCTAssertEqual(Array(decoded.entries[0].command.utf8), Array(odd.utf8), "the app never edits what was staged")
    }

    // MARK: The client frames

    private func assertEncodes(_ message: TerminalClientMessage, as fixture: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = try jsonObject(try StagingFixtures.fixtureData(fixture))
        let encoded = try jsonObject(try XCTUnwrap(message.encoded(), file: file, line: line))

        XCTAssertEqual(Set(encoded.keys), Set(golden.keys), "same keys as \(fixture)", file: file, line: line)
        XCTAssertEqual(NSDictionary(dictionary: encoded), NSDictionary(dictionary: golden), fixture, file: file, line: line)
    }

    func testStagingInsertedEncodesToTheGoldenFrame() throws {
        try assertEncodes(.stagingInserted(terminalId: id, entryId: "s-00000002", bytes: 19, confirmed: false),
                          as: "client-terminal-staging-inserted.json")
    }

    func testStagingRemoveEncodesToTheGoldenFrame() throws {
        try assertEncodes(.stagingRemove(terminalId: id, entryId: "s-00000001"), as: "client-terminal-staging-remove.json")
    }

    func testStagingClearEncodesToTheGoldenFrame() throws {
        try assertEncodes(.stagingClear(terminalId: id), as: "client-terminal-staging-clear.json")
    }

    func testTheClientFramesCarryTheirWireNames() {
        XCTAssertEqual(TerminalClientMessage.stagingInserted(terminalId: id, entryId: "e", bytes: 1, confirmed: false).wireType,
                       "terminal_staging_inserted")
        XCTAssertEqual(TerminalClientMessage.stagingRemove(terminalId: id, entryId: "e").wireType, "terminal_staging_remove")
        XCTAssertEqual(TerminalClientMessage.stagingClear(terminalId: id).wireType, "terminal_staging_clear")
    }

    func testAnInsertedFrameCarriesCountsAndIdsNeverText() throws {
        let frame = try jsonObject(try XCTUnwrap(
            TerminalClientMessage.stagingInserted(terminalId: id, entryId: "s-1", bytes: 7, confirmed: false).encoded()))

        XCTAssertEqual(Set(frame.keys), ["type", "terminal_id", "entry_id", "bytes", "confirmed"])
    }

    func testTheNewRefusalOpsHaveTheWireNamesTheDaemonExpects() {
        XCTAssertEqual(TerminalRefusedOp.stageInsert.rawValue, "stage_insert")
        XCTAssertEqual(TerminalRefusedOp.stagingCopy.rawValue, "staging_copy")
        XCTAssertEqual(TerminalRefusedOp.stagingRemove.rawValue, "staging_remove")
        XCTAssertEqual(TerminalRefusedOp.stagingClear.rawValue, "staging_clear")
    }

    // MARK: ServerMsg

    private func decodedMessage(fixture: String) throws -> ServerMsg {
        let raw = try StagingFixtures.fixtureData(fixture)
        let object = try jsonObject(raw)
        return NostromodClient(socketPath: "/dev/null").decode(type_: try XCTUnwrap(object["type"] as? String), json: object, raw: raw)
    }

    func testTheClientTurnsATerminalStagingListFrameIntoAServerMessage() throws {
        let message = try decodedMessage(fixture: "frame-terminal-staging-list-active.json")

        guard case .terminalStagingList(let list) = message else { return XCTFail("decoded as \(message)") }
        XCTAssertEqual(list.terminalId, id)
        XCTAssertEqual(list.state, .active)
        XCTAssertEqual(list.revision, 7)
        XCTAssertEqual(list.entries.count, 2)
    }

    func testEveryListFixtureReachesTheStoreAsAServerMessage() throws {
        for (fixture, state) in [("frame-terminal-staging-list-frozen.json", TerminalStagingState.frozen),
                                 ("frame-terminal-staging-list-none.json", TerminalStagingState.none),
                                 ("frame-terminal-staging-list-fractional.json", .active)] {
            guard case .terminalStagingList(let list) = try decodedMessage(fixture: fixture) else {
                return XCTFail("\(fixture) did not decode as a staging list")
            }
            XCTAssertEqual(list.state, state, fixture)
        }
    }

    // MARK: A frame that does not decode

    private func decodedMessage(object: [String: Any]) throws -> ServerMsg {
        let raw = try JSONSerialization.data(withJSONObject: object)
        return NostromodClient(socketPath: "/dev/null").decode(type_: "terminal_staging_list", json: object, raw: raw)
    }

    private func activeFrameObject() throws -> [String: Any] {
        try jsonObject(try StagingFixtures.fixtureData("frame-terminal-staging-list-active.json"))
    }

    func testAFrameThatDoesNotDecodeButNamesItsTerminalIsReportedUnreadableForThatTerminal() throws {
        var frame = try activeFrameObject()
        var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
        entries[0]["staged_at"] = "not a time"
        frame["entries"] = entries

        let message = try decodedMessage(object: frame)

        guard case .terminalStagingUnreadable(let terminalId) = message else {
            return XCTFail("an undecodable frame that names its terminal must say so (decoded as \(message))")
        }
        XCTAssertEqual(terminalId, id)
    }

    func testAFrameWithAnEntryMissingItsCommandIsReportedUnreadableToo() throws {
        var frame = try activeFrameObject()
        var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
        entries[1]["command"] = nil
        frame["entries"] = entries

        guard case .terminalStagingUnreadable(let terminalId) = try decodedMessage(object: frame) else {
            return XCTFail("a frame that lost an entry's command must be reported unreadable")
        }
        XCTAssertEqual(terminalId, id)
    }

    func testAFrameWithNoReadableTerminalIdIsNotReportedUnreadableForAnyTerminal() throws {
        for bad: Any? in [nil, 42, NSNull()] {
            var frame = try activeFrameObject()
            frame["terminal_id"] = bad
            var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
            entries[0]["staged_at"] = "not a time"
            frame["entries"] = entries

            let message = try decodedMessage(object: frame)

            if case .terminalStagingUnreadable = message {
                XCTFail("terminal_id \(String(describing: bad)) names no terminal; the frame stays dropped")
            }
            if case .terminalStagingList = message { XCTFail("it does not decode as a list either") }
        }
    }

    func testAnUndecodableFrameWithoutATerminalIdDecodesAsUnknown() throws {
        var frame = try activeFrameObject()
        frame["terminal_id"] = nil
        var entries = try XCTUnwrap(frame["entries"] as? [[String: Any]])
        entries[0]["staged_at"] = "not a time"
        frame["entries"] = entries

        guard case .unknown = try decodedMessage(object: frame) else {
            return XCTFail("a frame that names no terminal is dropped as unknown")
        }
    }

    func testAGoodFrameStillDecodesAsAListNotAsUnreadable() throws {
        guard case .terminalStagingList(let list) = try decodedMessage(object: try activeFrameObject()) else {
            return XCTFail("a good frame is a list")
        }
        XCTAssertEqual(list.terminalId, id)
    }

    // MARK: The capability that makes the daemon send it

    func testTheOperatorAppDeclaresTheStagingUICapability() {
        XCTAssertEqual(NostromodClient.terminalStagingUICapability, "terminal_staging_ui")
        XCTAssertTrue(NostromodClient.operatorCapabilities.contains("terminal_staging_ui"))
    }

    func testTheOlderCapabilitiesAreStillDeclared() {
        for capability in [NostromodClient.terminalUICapability, NostromodClient.remoteShellConfirmCapability,
                           NostromodClient.terminalFollowUICapability] {
            XCTAssertTrue(NostromodClient.operatorCapabilities.contains(capability), capability)
        }
    }
}


// MARK: - S2 frames

extension TerminalStagingWireTests {

    private func body(_ message: TerminalClientMessage) throws -> [String: Any] {
        let data = try XCTUnwrap(message.encoded())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheSwitchArchiveAndUIEventFramesEncodeAsTheDaemonReadsThem() throws {
        let id = StagingFixtures.terminalId
        XCTAssertEqual(NSDictionary(dictionary: try body(.stagingSetEnabled(terminalId: id, enabled: false))),
                       ["type": "terminal_staging_set_enabled", "terminal_id": id, "enabled": false] as NSDictionary)
        XCTAssertEqual(NSDictionary(dictionary: try body(.stagingSetGlobal(enabled: true))),
                       ["type": "terminal_staging_set_global", "enabled": true] as NSDictionary)
        XCTAssertEqual(NSDictionary(dictionary: try body(.stagingUIEvent(terminalId: id, event: "confirm_cancelled"))),
                       ["type": "terminal_staging_ui_event", "terminal_id": id, "event": "confirm_cancelled"] as NSDictionary)
        XCTAssertEqual(NSDictionary(dictionary: try body(.stagingRemove(terminalId: id, entryId: "s-1", archive: "manual"))),
                       ["type": "terminal_staging_remove", "terminal_id": id, "entry_id": "s-1", "archive": "manual"] as NSDictionary)
        XCTAssertNil(try body(.stagingRemove(terminalId: id, entryId: "s-1"))["archive"], "a plain Remove has no archive field")
    }

    func testAStagedInsertInputCarriesViaAndOtherInputDoesNot() throws {
        let staged = try body(.input(terminalId: "t1", bytes: [0x61], autoReply: false, via: "stage_insert"))
        XCTAssertEqual(staged["via"] as? String, "stage_insert")
        XCTAssertNil(staged["auto_reply"])
        XCTAssertNil(try body(.input(terminalId: "t1", bytes: [0x61]))["via"], "omitted when nil")
    }

    func testTheNewRefusalOpsHaveTheirWireNames() {
        XCTAssertEqual(TerminalRefusedOp.stagingArchive.rawValue, "staging_archive")
        XCTAssertEqual(TerminalRefusedOp.stagingHide.rawValue, "staging_hide")
        XCTAssertEqual(TerminalRefusedOp.stagingSwitch.rawValue, "staging_switch")
        XCTAssertEqual(TerminalRefusedOp.stagingConfirm.rawValue, "staging_confirm")
    }

    func testAListFrameCarriesEnabledAndForegroundAndAnOlderDaemonsDefaultsToEnabled() throws {
        let withFields = Data("""
            {"type":"terminal_staging_list","terminal_id":"t","pane_id":"p","state":"none","revision":4,"enabled":false,"foreground":"ssh"}
            """.utf8)
        let decoded = try JSONDecoder().decode(TerminalStagingList.self, from: withFields)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.foreground, "ssh")
        let older = Data(#"{"type":"terminal_staging_list","terminal_id":"t","state":"active","revision":1,"entries":[]}"#.utf8)
        let defaulted = try JSONDecoder().decode(TerminalStagingList.self, from: older)
        XCTAssertTrue(defaulted.enabled, "an S1 daemon sends no `enabled`")
        XCTAssertNil(defaulted.foreground)
    }
}
