import XCTest
import Combine
import Darwin

// The message queue wire (`session_queue_v1`, docs/message-queue.md) as the Mac reads and writes it.
//
// The daemon's golden frames live in `tests/fixtures/session_queue/` and the Rust tests read the same
// files, so a drift on either side fails a test on that side. Server frames go through
// `NostromodClient.decode(type_:json:raw:)`, the decoder the read loop calls for every frame, and come out
// as the `ServerMsg` the app acts on. Client frames are what the client really writes: a `FakeDaemon`
// (NostromodClientHandshakeTests.swift) speaks the framing over a real AF_UNIX socket and records them.
//
// NostromodClient, ServerMsg and the wire types are compiled into this target directly (logic test).

final class SessionQueueWireTests: XCTestCase {

    // MARK: Fixtures

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoTests
        .deletingLastPathComponent()   // macOS
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/session_queue")

    private struct Fixture {
        let name: String
        let raw: Data
        let json: [String: Any]
        var type: String { json["type"] as? String ?? "" }
    }

    private static func fixture(_ name: String) throws -> Fixture {
        let raw = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any], name)
        return Fixture(name: name, raw: raw, json: json)
    }

    private static func allFixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    private let client = NostromodClient(socketPath: "/dev/null")

    private func decode(_ f: Fixture) -> ServerMsg {
        client.decode(type_: f.type, json: f.json, raw: f.raw)
    }

    private func decode(json: [String: Any]) throws -> ServerMsg {
        let raw = try JSONSerialization.data(withJSONObject: json)
        return client.decode(type_: json["type"] as? String ?? "", json: json, raw: raw)
    }

    private func snapshot(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionQueueWire {
        guard case .sessionQueue(let wire) = decode(try Self.fixture(name)) else {
            XCTFail("\(name) did not decode to .sessionQueue", file: file, line: line)
            throw DecodeFailure()
        }
        return wire
    }

    private func result(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionQueueResultWire {
        guard case .sessionQueueResult(let wire) = decode(try Self.fixture(name)) else {
            XCTFail("\(name) did not decode to .sessionQueueResult", file: file, line: line)
            throw DecodeFailure()
        }
        return wire
    }

    private struct DecodeFailure: Error {}

    // MARK: Server frames: every golden frame is understood

    private static let snapshotFixtures = [
        "snapshot_empty", "snapshot_held", "snapshot_typed_app_command", "snapshot_merge_group",
        "change_queued", "change_delivered", "change_taken_back", "change_removed", "change_stopped",
        "change_session_stopped",
    ]
    private static let resultFixtures = [
        "result_taken_back", "result_removed", "result_already_delivered", "result_not_found", "result_not_allowed",
    ]
    private static let returnedFixtures = ["returned"]
    private static let clientFixtures = [
        "client_session_queue_watch", "client_session_queue_take_back", "client_session_queue_remove",
        "client_session_send_client_ref", "old_client_session_send",
    ]
    private static let handshakeFixtures = ["old_server_welcome"]

    func testEveryGoldenFixtureIsAccountedForSoANewOneCannotGoUntested() throws {
        let known = Set(Self.snapshotFixtures + Self.resultFixtures + Self.returnedFixtures
                        + Self.clientFixtures + Self.handshakeFixtures)
        XCTAssertEqual(Set(try Self.allFixtureNames()), known,
                       "a fixture was added or removed: classify it here and decode or encode it below")
    }

    func testEveryServerFixtureDecodesToTheRightFrameForTheTagItNames() throws {
        for name in Self.snapshotFixtures {
            let f = try Self.fixture(name)
            guard case .sessionQueue(let wire) = decode(f) else { XCTFail("\(name): not .sessionQueue"); continue }
            XCTAssertEqual(wire.tag, "cody-1", name)
            XCTAssertEqual(wire.daemonEpoch, "3f9a1c2e-0000-4000-8000-000000000001", name)
        }
        for name in Self.resultFixtures {
            let f = try Self.fixture(name)
            guard case .sessionQueueResult(let wire) = decode(f) else { XCTFail("\(name): not .sessionQueueResult"); continue }
            XCTAssertEqual(wire.tag, "cody-1", name)
            XCTAssertEqual(wire.requestId, "req-1", name)
            XCTAssertEqual(wire.id, "q3f9a1c2e-1", name)
        }
        for name in Self.returnedFixtures {
            let f = try Self.fixture(name)
            guard case .sessionQueueReturned(let wire) = decode(f) else { XCTFail("\(name): not .sessionQueueReturned"); continue }
            XCTAssertEqual(wire.tag, "cody-1", name)
        }
    }

    func testTheMergeGroupSnapshotCarriesTheGroupOnlyOnTheEntriesThatWillMerge() throws {
        let wire = try snapshot("snapshot_merge_group")
        XCTAssertEqual(wire.entries.map(\.mergeGroup), [1, 1, nil, 2, 2])
        XCTAssertEqual(wire.entries.map(QueuedMessage.init).map(\.mergeGroup), [1, 1, nil, 2, 2])
    }

    func testTheTypedAppAndCommandSnapshotKeepsItsOrderAndEveryField() throws {
        let wire = try snapshot("snapshot_typed_app_command")

        XCTAssertEqual(wire.rev, 7)
        XCTAssertNil(wire.held)
        XCTAssertNil(wire.change)
        XCTAssertEqual(wire.entries.map(\.id), ["q3f9a1c2e-1", "q3f9a1c2e-4", "q3f9a1c2e-2", "q3f9a1c2e-3"],
                       "the daemon's order (oldest first) is kept")
        let typed = wire.entries[0], app = wire.entries[1], command = wire.entries[2], images = wire.entries[3]
        XCTAssertEqual(typed.kind, "typed")
        XCTAssertEqual(typed.text, "fix the picker")
        XCTAssertEqual(typed.clientRef, "c-1")
        XCTAssertTrue(typed.canTakeBack)
        XCTAssertFalse(typed.command)
        XCTAssertEqual(app.kind, "app")
        XCTAssertEqual(app.appLabel, "mother_overview")
        XCTAssertFalse(app.canTakeBack)
        XCTAssertNil(app.clientRef)
        XCTAssertTrue(command.command)
        XCTAssertEqual(command.text, "/compact")
        XCTAssertEqual(images.imageCount, 2)
        XCTAssertNil(images.clientRef, "a message from a phone carries no client_ref of ours")
    }

    func testTheHeldSnapshotCarriesTheHeldMessageWithNoText() throws {
        let wire = try snapshot("snapshot_held")
        XCTAssertEqual(wire.rev, 9)
        XCTAssertEqual(wire.held, SessionQueueHeldWire(id: "q3f9a1c2e-0", holdId: "hold-1", canTakeBack: true))
        XCTAssertEqual(wire.entries.map(\.id), ["q3f9a1c2e-1"], "the held message is not in entries")
    }

    func testTheEmptySnapshotIsEmptyAndHasNoChange() throws {
        let wire = try snapshot("snapshot_empty")
        XCTAssertEqual(wire.rev, 8)
        XCTAssertTrue(wire.entries.isEmpty)
        XCTAssertNil(wire.held)
        XCTAssertNil(wire.change)
    }

    func testEveryChangeReasonAndItsIdsDecode() throws {
        let expected: [(String, String, [String])] = [
            ("change_queued", "queued", ["q3f9a1c2e-3"]),
            ("change_delivered", "delivered", ["q3f9a1c2e-1"]),
            ("change_taken_back", "taken_back", ["q3f9a1c2e-1"]),
            ("change_removed", "removed", ["q3f9a1c2e-1"]),
            ("change_stopped", "stopped", ["q3f9a1c2e-1", "q3f9a1c2e-2"]),
            ("change_session_stopped", "session_stopped", ["q3f9a1c2e-1", "q3f9a1c2e-3"]),
        ]
        for (name, reason, ids) in expected {
            let wire = try snapshot(name)
            XCTAssertEqual(wire.change, SessionQueueChangeWire(reason: reason, ids: ids), name)
            XCTAssertEqual(wire.rev, 10, name)
        }
        XCTAssertTrue(try snapshot("change_session_stopped").entries.isEmpty)
    }

    func testEveryResultCodeDecodesAndOnlyTakenBackCarriesTextAndImages() throws {
        let taken = try result("result_taken_back")
        XCTAssertEqual(taken.code, "taken_back")
        XCTAssertEqual(taken.text, "fix the picker")
        XCTAssertEqual(taken.images, ["/tmp/shot-1.png"])
        for (name, code) in [("result_removed", "removed"), ("result_already_delivered", "already_delivered"),
                             ("result_not_found", "not_found"), ("result_not_allowed", "not_allowed")] {
            let wire = try result(name)
            XCTAssertEqual(wire.code, code, name)
            XCTAssertNil(wire.text, name)
            XCTAssertNil(wire.images, name)
        }
    }

    func testTheReturnedFrameKeepsTheHeldMessageFirstAndTheImagesOfEachEntry() throws {
        guard case .sessionQueueReturned(let wire) = decode(try Self.fixture("returned")) else {
            return XCTFail("returned did not decode")
        }
        XCTAssertEqual(wire.reason, "stopped")
        XCTAssertEqual(wire.entries.map(\.text), ["held message", "fix the picker"])
        XCTAssertEqual(wire.entries.map(\.id), ["q3f9a1c2e-0", "q3f9a1c2e-1"])
        XCTAssertNil(wire.entries[0].images)
        XCTAssertEqual(wire.entries[1].images, ["/tmp/shot-1.png"])
    }

    // MARK: Tolerance

    func testAnUnknownExtraFieldAnywhereInASnapshotIsIgnored() throws {
        var json = try Self.fixture("snapshot_typed_app_command").json
        json["future_top_level"] = ["x": 1]
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        entries[0]["future_entry_field"] = "later"
        json["entries"] = entries
        json["change"] = ["reason": "queued", "ids": ["q3f9a1c2e-3"], "future_change_field": true]
        json["held"] = ["id": "h", "hold_id": "hold", "can_take_back": true, "future_held_field": 3]

        guard case .sessionQueue(let wire) = try decode(json: json) else { return XCTFail("did not decode") }
        XCTAssertEqual(wire.entries.count, 4)
        XCTAssertEqual(wire.change?.reason, "queued")
        XCTAssertEqual(wire.held?.holdId, "hold")
    }

    func testAnUnknownExtraFieldInAResultAndInAReturnedFrameIsIgnored() throws {
        var resultJSON = try Self.fixture("result_taken_back").json
        resultJSON["future"] = ["a", "b"]
        guard case .sessionQueueResult(let wire) = try decode(json: resultJSON) else { return XCTFail("result") }
        XCTAssertEqual(wire.code, "taken_back")

        var returned = try Self.fixture("returned").json
        returned["future"] = 1
        var entries = try XCTUnwrap(returned["entries"] as? [[String: Any]])
        entries[0]["future"] = "x"
        returned["entries"] = entries
        guard case .sessionQueueReturned(let ret) = try decode(json: returned) else { return XCTFail("returned") }
        XCTAssertEqual(ret.entries.count, 2)
    }

    func testAResultCodeThisAppDoesNotKnowStillDecodesAsAResult() throws {
        var json = try Self.fixture("result_not_found").json
        json["code"] = "some_future_code"
        guard case .sessionQueueResult(let wire) = try decode(json: json) else { return XCTFail("did not decode") }
        XCTAssertEqual(wire.code, "some_future_code")
    }

    // MARK: Old daemon

    func testTheOldWelcomeDoesNotAdvertiseTheQueueAndANewOneDoes() throws {
        let old = try Self.fixture("old_server_welcome")
        guard case .welcome = decode(old) else { return XCTFail("the old welcome no longer decodes") }
        let oldFeatures = try XCTUnwrap(old.json["features"] as? [String])
        XCTAssertFalse(oldFeatures.contains(sessionQueueFeature))
        XCTAssertEqual(sessionQueueFeature, "session_queue_v1")

        let daemon = FakeDaemon(scripts: [.init(features: oldFeatures)])
        try daemon.start()
        addTeardownBlock { daemon.stop() }
        let oldClient = NostromodClient(socketPath: daemon.path)
        oldClient.start()
        XCTAssertTrue(waitUntil { oldClient.connected.value }, "connected to the old fake daemon")
        XCTAssertFalse(oldClient.daemonAdvertisesSessionQueue)

        oldClient.setAdvertisedFeaturesForTesting(oldFeatures + [sessionQueueFeature])
        XCTAssertTrue(oldClient.daemonAdvertisesSessionQueue)
    }

    // MARK: Client frames, as written to a socket

    /// A client connected to a fake daemon that advertises `features` and (optionally) issued a nonce.
    private func connect(features: [String]?, nonce: String? = nil) throws -> (NostromodClient, FakeDaemon) {
        let daemon = FakeDaemon(scripts: [.init(features: features, operatorNonce: nonce)])
        try daemon.start()
        addTeardownBlock { daemon.stop() }
        let c = NostromodClient(socketPath: daemon.path)
        c.start()
        XCTAssertTrue(waitUntil { c.connected.value }, "the client never connected")
        return (c, daemon)
    }

    /// Frames of `type` the daemon has seen, once a later `session_attach` proves the earlier writes arrived.
    private func frames(_ daemon: FakeDaemon, _ client: NostromodClient, ofType type: String) -> [[String: Any]] {
        let marker = "marker-\(UUID().uuidString.prefix(6))"
        client.sessionAttach(tag: marker)
        XCTAssertTrue(waitUntil { !daemon.frames(connection: 0, ofType: "session_attach").filter { $0.tag == marker }.isEmpty },
                      "the marker frame never arrived")
        return daemon.frames(connection: 0, ofType: type).map(\.json)
    }

    /// `fixture`'s every key and value is in `frame`; `extra` names the keys the frame may add.
    private func assertFrame(_ frame: [String: Any], matches fixture: Fixture, allowingExtra extra: Set<String> = [],
                             file: StaticString = #filePath, line: UInt = #line) {
        for (key, value) in fixture.json {
            XCTAssertEqual(frame[key] as? NSObject, value as? NSObject,
                           "\(fixture.name): `\(key)` is \(String(describing: frame[key])), the fixture says \(value)",
                           file: file, line: line)
        }
        XCTAssertEqual(Set(frame.keys).subtracting(fixture.json.keys), extra,
                       "\(fixture.name): the frame has keys the fixture does not", file: file, line: line)
    }

    func testTheWatchFrameIsTheFixtureExactly() throws {
        let fixture = try Self.fixture("client_session_queue_watch")
        let (c, daemon) = try connect(features: [sessionQueueFeature])

        c.sessionQueueWatch(tag: "cody-1")

        let sent = frames(daemon, c, ofType: "session_queue_watch")
        XCTAssertEqual(sent.count, 1)
        assertFrame(try XCTUnwrap(sent.first), matches: fixture)
    }

    func testTakeBackAndRemoveFramesAreTheFixturesExactlyAndAreWritten() throws {
        let takeBack = try Self.fixture("client_session_queue_take_back")
        let remove = try Self.fixture("client_session_queue_remove")
        let (c, daemon) = try connect(features: [sessionQueueFeature], nonce: "n-1")

        XCTAssertTrue(c.sendSessionQueueTakeBack(tag: "cody-1", id: "q3f9a1c2e-1", requestId: "req-1"))
        XCTAssertTrue(c.sendSessionQueueRemove(tag: "cody-1", id: "q3f9a1c2e-1", requestId: "req-2"))

        assertFrame(try XCTUnwrap(frames(daemon, c, ofType: "session_queue_take_back").first), matches: takeBack)
        assertFrame(try XCTUnwrap(frames(daemon, c, ofType: "session_queue_remove").first), matches: remove)
    }

    func testTakeBackAndRemoveWriteNothingAndReportItWithoutTheOperatorNonce() throws {
        let (c, daemon) = try connect(features: [sessionQueueFeature], nonce: nil)

        XCTAssertFalse(c.sendSessionQueueTakeBack(tag: "cody-1", id: "q-1", requestId: "r-1"))
        XCTAssertFalse(c.sendSessionQueueRemove(tag: "cody-1", id: "q-1", requestId: "r-2"))

        XCTAssertTrue(frames(daemon, c, ofType: "session_queue_take_back").isEmpty)
        XCTAssertTrue(frames(daemon, c, ofType: "session_queue_remove").isEmpty)
    }

    func testNothingQueueRelatedIsWrittenToADaemonThatDidNotAdvertiseTheFeature() throws {
        let (c, daemon) = try connect(features: ["work", "model"], nonce: "n-1")

        c.sessionQueueWatch(tag: "cody-1")
        XCTAssertFalse(c.sendSessionQueueTakeBack(tag: "cody-1", id: "q-1", requestId: "r-1"))
        XCTAssertFalse(c.sendSessionQueueRemove(tag: "cody-1", id: "q-1", requestId: "r-2"))

        for type in ["session_queue_watch", "session_queue_take_back", "session_queue_remove"] {
            XCTAssertTrue(frames(daemon, c, ofType: type).isEmpty, type)
        }
    }

    func testSendWithAClientRefCarriesItWhenTheDaemonAdvertisedTheQueue() throws {
        let fixture = try Self.fixture("client_session_send_client_ref")
        let (c, daemon) = try connect(features: [sessionQueueFeature])

        c.sessionSend(tag: "cody-1", text: "fix the picker", clientRef: "c-1")

        let frame = try XCTUnwrap(frames(daemon, c, ofType: "session_send").first)
        assertFrame(frame, matches: fixture, allowingExtra: ["images"])
        XCTAssertEqual(frame["images"] as? [String], [], "images keeps today's shape")
    }

    func testTheOldSendHasNoClientRefEvenWhenTheDaemonAdvertisedTheQueue() throws {
        let fixture = try Self.fixture("old_client_session_send")
        let (c, daemon) = try connect(features: [sessionQueueFeature])

        c.sessionSend(tag: "cody-1", text: "fix the picker")

        let frame = try XCTUnwrap(frames(daemon, c, ofType: "session_send").first)
        XCTAssertNil(frame["client_ref"])
        assertFrame(frame, matches: fixture, allowingExtra: ["images"])
    }

    func testAClientRefIsNeverSentToADaemonThatDidNotAdvertiseTheQueue() throws {
        let (c, daemon) = try connect(features: ["work"])

        c.sessionSend(tag: "cody-1", text: "fix the picker", clientRef: "c-1")

        let frame = try XCTUnwrap(frames(daemon, c, ofType: "session_send").first)
        XCTAssertNil(frame["client_ref"], "an old daemon is sent today's frame")
        XCTAssertEqual(frame["text"] as? String, "fix the picker")
    }

    func testSendsWithAndWithoutImagesKeepTheirImagePaths() throws {
        let (c, daemon) = try connect(features: [sessionQueueFeature])

        c.sessionSend(tag: "cody-1", text: "look", imagePaths: ["/tmp/a.png", "/tmp/b.png"], clientRef: "c-2")

        let frame = try XCTUnwrap(frames(daemon, c, ofType: "session_send").first)
        XCTAssertEqual(frame["images"] as? [String], ["/tmp/a.png", "/tmp/b.png"])
        XCTAssertEqual(frame["client_ref"] as? String, "c-2")
    }

    // MARK: Helpers

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}
