import XCTest
import AppKit
import Combine
import NostromoKit

// MotherBrokerClient and BrokerEvent are compiled into this target directly.
//
// The quota gate on the broker socket, over the in-process fake broker `MotherBrokerClientTests` uses (these
// tests are an extension of that class, so they share its socket harness). The wire contract is Mother's
// golden fixture, `tests/fixtures/mother-contract/quota_block.json`:
//
//   - A `snapshot` carries the `quota` block as `data.quota`; the client reports it as `.quota(block)` after
//     the `.snapshot` (nil when the broker sent none: an older Mother).
//   - A top-level `quota` event (`data: {quota, job: "", category: "quota"}`) is a `.quota(block)` too. It has
//     no job id, so it must not be dropped by the job-keyed handling of the other event kinds. A block the
//     client cannot read changes nothing.
//   - `setQuotaGate` sends exactly `{t: "quota-gate", data: {state, origin: "nostromo"}}` (no `job`), reports
//     the ack's own `quota` block (the broker's read-back, not an echo of the request) and the broker's error.
//   - It refuses locally, writing nothing, when the hello does not advertise `quota-gate`.
//   - A refusal's code is kept: `no_reset_known` is its own error, a code this build does not know is carried
//     as that code (never guessed to be an internal failure).
//   - `stop()` ends a client for good: no reconnect follows, and commands still waiting fail as disconnected.

/// What the client published, in order.
private final class QBRecorder {
    private(set) var events: [BrokerEvent] = []

    /// Every `.quota(...)` payload, nil where the broker sent no block.
    var quotas: [MotherQuota?] {
        var found: [MotherQuota?] = []
        for event in events {
            if case .quota(let quota) = event { found.append(quota) }
        }
        return found
    }

    /// The case names of everything but the handshake's own `hello`.
    var names: [String] {
        var found: [String] = []
        for event in events {
            let name = String(String(describing: event).prefix(while: { $0 != "(" }))
            if name != "hello" { found.append(name) }
        }
        return found
    }

    func record(_ event: BrokerEvent) { events.append(event) }
}

/// Why the last `qbReadLine` returned nil (the test's failure message).
private var qbLastReadFailure = ""

extension MotherBrokerClientTests {

    // MARK: Helpers

    private static let qbClassic = ["state", "activity", "await", "current_activity", "quota"]
    private static let qbWithGate = qbClassic + ["quota-gate"]

    fileprivate func qbHello(_ capabilities: [String]) -> String {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"v":1,"dir":"event","t":"hello","id":"0","ts":"2026-11-02T19:00:00.000Z","data":{"protocol_version":1,"capabilities":[\#(caps)]}}"#
    }

    /// An envelope as one NDJSON line.
    fileprivate func qbLine(dir: String, t: String, id: String, data: [String: Any]) throws -> String {
        let envelope: [String: Any] = ["v": 1, "dir": dir, "t": t, "id": id, "ts": "2026-11-02T19:11:00.000Z", "data": data]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One line from the client, byte by byte like `serverReadLine`, but a signal-interrupted read (EINTR) is
    /// retried instead of reading as "the client wrote nothing". The 5 s receive timeout still ends it. On
    /// failure `qbLastReadFailure` says what the read returned and its errno.
    fileprivate func qbReadLine() -> String? {
        var buf = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(serverFd, &byte, 1)
            let err = errno
            if n < 0 && err == EINTR { continue }
            if n <= 0 {
                qbLastReadFailure = "read returned n=\(n) errno=\(err) (\(String(cString: strerror(err)))) fd=\(serverFd) after \(buf.count) bytes"
                return nil
            }
            if byte == 0x0A { break }
            buf.append(byte)
        }
        return String(data: buf, encoding: .utf8)
    }

    /// The next command the client wrote, as a JSON object (nil-read after 5 s fails instead of hanging).
    fileprivate func qbReadCommand() throws -> [String: Any] {
        let line = try XCTUnwrap(qbReadLine(), "the client wrote nothing: \(qbLastReadFailure)")
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(line)")
    }

    /// Connect, send a hello advertising `capabilities`, consume the subscribe, and wait for the link to be live.
    fileprivate func qbHandshake(capabilities: [String]) throws {
        client.start()
        try waitForServerAccept()
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        serverWrite(qbHello(capabilities))
        let subscribe = try qbReadCommand()
        XCTAssertEqual(subscribe["t"] as? String, "subscribe")
        let live = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in live.fulfill() }.store(in: &cancellables)
        wait(for: [live], timeout: 10)
    }

    fileprivate func qbRecord() -> QBRecorder {
        let recorder = QBRecorder()
        client.events.sink { recorder.record($0) }.store(in: &cancellables)
        return recorder
    }

    /// Run the main run loop until `condition` holds.
    fileprivate func qbWait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath,
                            line: UInt = #line, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    fileprivate func qbFixtureQuota() throws -> MotherQuota {
        try XCTUnwrap(MotherQuota.decode(try QuotaFixture.block()))
    }

    /// Ask for `request`, hand back the command the client wrote and a way to see what completion it gets.
    fileprivate func qbAskGate(_ request: MotherQuotaGateRequest)
        throws -> (command: [String: Any], result: () -> Result<MotherQuota?, BrokerError>?) {
        var result: Result<MotherQuota?, BrokerError>?
        client.setQuotaGate(request) { result = $0 }
        let command = try qbReadCommand()
        return (command, { result })
    }

    // MARK: Snapshot

    func testASnapshotWithAQuotaBlockDeliversItAfterTheJobs() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbWithGate)

        serverWrite(try qbLine(dir: "event", t: "snapshot", id: "2",
                               data: ["sub": "main", "jobs": [], "quota": try QuotaFixture.block()]))

        qbWait("the quota event") { recorder.quotas.count == 1 }
        let quota = try XCTUnwrap(recorder.quotas[0], "the block decoded")
        XCTAssertEqual(quota, try qbFixtureQuota())
        XCTAssertEqual(quota.gate, .offUntilReset)
        XCTAssertEqual(quota.until, Date(timeIntervalSince1970: 1_793_658_600))
        XCTAssertEqual(quota.sevenDay?.usedPct, 100)
        XCTAssertEqual(recorder.names, ["snapshot", "quota", "limiter"], "the jobs first, then the quota, then the limiter")
    }

    func testASnapshotWithNoQuotaBlockDeliversNoQuota() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbClassic)

        serverWrite(try qbLine(dir: "event", t: "snapshot", id: "2", data: ["sub": "main", "jobs": []]))

        qbWait("the quota event") { recorder.quotas.count == 1 }
        XCTAssertNil(recorder.quotas[0], "an older Mother: no quota status, so nothing to show")
        XCTAssertEqual(recorder.names, ["snapshot", "quota", "limiter"])
    }

    func testASnapshotWhoseQuotaIsNullOrNotAnObjectDeliversNoQuota() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbClassic)

        serverWrite(try qbLine(dir: "event", t: "snapshot", id: "2", data: ["sub": "main", "jobs": [], "quota": NSNull()]))
        serverWrite(try qbLine(dir: "event", t: "snapshot", id: "3", data: ["sub": "main", "jobs": [], "quota": "garbage"]))

        qbWait("two quota events") { recorder.quotas.count == 2 }
        XCTAssertNil(recorder.quotas[0])
        XCTAssertNil(recorder.quotas[1])
    }

    func testASnapshotQuotaWithAnUnknownGateIsDeliveredAsUnknown() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbClassic)

        let block = try QuotaFixture.block { $0["gate"] = "mystery_mode" }
        serverWrite(try qbLine(dir: "event", t: "snapshot", id: "2", data: ["sub": "main", "jobs": [], "quota": block]))

        qbWait("the quota event") { recorder.quotas.count == 1 }
        XCTAssertEqual(recorder.quotas[0]?.gate, .unknown("mystery_mode"))
    }

    // MARK: Quota event

    func testATopLevelQuotaEventIsDeliveredEvenThoughItHasNoJob() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbWithGate)

        let off = try QuotaFixture.block { $0["gate"] = "off"; $0["until"] = NSNull() }
        serverWrite(try qbLine(dir: "event", t: "quota", id: "3", data: ["quota": off, "job": "", "category": "quota"]))
        let on = try QuotaFixture.block { $0["gate"] = "on"; $0["until"] = NSNull() }
        serverWrite(try qbLine(dir: "event", t: "quota", id: "4", data: ["quota": on, "job": "", "category": "quota"]))

        qbWait("two quota events") { recorder.quotas.count == 2 }
        XCTAssertEqual(recorder.quotas[0]?.gate, .off)
        XCTAssertEqual(recorder.quotas[1]?.gate, .on)
        XCTAssertEqual(recorder.names, ["quota", "quota"],
                       "a quota event is only a quota event: no job state change is made of it")
    }

    func testAQuotaEventWithNoJobKeyAtAllIsDeliveredToo() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbWithGate)

        serverWrite(try qbLine(dir: "event", t: "quota", id: "3", data: ["quota": try QuotaFixture.block()]))

        qbWait("the quota event") { recorder.quotas.count == 1 }
        XCTAssertEqual(recorder.quotas[0], try qbFixtureQuota())
    }

    func testAQuotaEventTheClientCannotReadChangesNothing() throws {
        let recorder = qbRecord()
        try qbHandshake(capabilities: Self.qbWithGate)

        serverWrite(try qbLine(dir: "event", t: "quota", id: "3", data: ["quota": "garbage", "job": "", "category": "quota"]))
        serverWrite(try qbLine(dir: "event", t: "quota", id: "4", data: ["job": "", "category": "quota"]))
        serverWrite(try qbLine(dir: "event", t: "quota", id: "5", data: ["quota": try QuotaFixture.block(), "job": "", "category": "quota"]))

        qbWait("the readable quota event") { !recorder.quotas.isEmpty }
        XCTAssertEqual(recorder.quotas.count, 1, "the two unreadable ones produced nothing, in particular no `nil`")
        XCTAssertEqual(recorder.quotas[0], try qbFixtureQuota())
    }

    // MARK: Sending the command

    func testEveryRequestIsSentAsAQuotaGateCommandWithItsStateAndOriginAndNoJob() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        XCTAssertTrue(client.supportsQuotaGate)
        let fixtureRequest = try QuotaFixture.envelope("request")
        let fixtureData = try XCTUnwrap(fixtureRequest["data"] as? [String: Any])

        for request in MotherQuotaGateRequest.allCases {
            let (command, _) = try qbAskGate(request)

            XCTAssertEqual(command["v"] as? Int, 1, "\(request)")
            XCTAssertEqual(command["dir"] as? String, "cmd", "\(request)")
            XCTAssertEqual(command["t"] as? String, "quota-gate", "\(request)")
            XCTAssertFalse((command["id"] as? String ?? "").isEmpty, "\(request): an id to match the ack with")
            let data = try XCTUnwrap(command["data"] as? [String: Any], "\(request)")
            XCTAssertEqual(Set(data.keys), Set(fixtureData.keys), "\(request): the fixture's data shape, nothing more")
            XCTAssertNil(data["job"], "\(request): the gate has no job")
            XCTAssertEqual(data["state"] as? String, request.rawValue, "\(request)")
            XCTAssertEqual(data["origin"] as? String, fixtureData["origin"] as? String)
            XCTAssertEqual(data["origin"] as? String, "nostromo")
        }
    }

    func testAnOkAckDeliversTheBlockItCarriesNotAnEchoOfTheRequest() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let fixtureAck = try QuotaFixture.envelope("ok_ack")
        XCTAssertEqual((fixtureAck["data"] as? [String: Any])?["ok"] as? Bool, true, "the fixture's ok ack")

        // The control asked for ON; the ack's block (the broker's read-back) says off until reset.
        let (command, result) = try qbAskGate(.on)
        let id = try XCTUnwrap(command["id"] as? String)
        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id,
                               data: ["ok": true, "state": "off_until_reset", "quota": try QuotaFixture.block()]))

        qbWait("the completion") { result() != nil }
        guard case .success(let quota)? = result() else { return XCTFail("expected success, got \(String(describing: result()))") }
        XCTAssertEqual(quota, try qbFixtureQuota())
        XCTAssertEqual(quota?.gate, .offUntilReset, "what the broker reported, not what was asked for")
    }

    func testAnOkAckWithNoBlockCompletesWithNoQuota() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let (command, result) = try qbAskGate(.off)
        let id = try XCTUnwrap(command["id"] as? String)

        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id, data: ["ok": true, "state": "off"]))

        qbWait("the completion") { result() != nil }
        guard case .success(let quota)? = result() else { return XCTFail("expected success, got \(String(describing: result()))") }
        XCTAssertNil(quota)
    }

    func testARejectedAckCompletesWithTheBrokersMalformedError() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let rejected = try QuotaFixture.envelope("rejected_ack")
        let rejectedData = try XCTUnwrap(rejected["data"] as? [String: Any])
        let (command, result) = try qbAskGate(.off)
        let id = try XCTUnwrap(command["id"] as? String)

        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id, data: rejectedData))

        qbWait("the completion") { result() != nil }
        guard case .failure(let error)? = result() else { return XCTFail("expected failure, got \(String(describing: result()))") }
        guard case .code(let code, let message) = error else { return XCTFail("expected a coded error, got \(error)") }
        XCTAssertEqual(code, .malformed)
        XCTAssertEqual(message, "quota-gate: state must be one of on, off, off_until_reset")
    }

    func testANoResetKnownAckCompletesWithTheNoResetKnownError() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let (command, result) = try qbAskGate(.offUntilReset)
        let id = try XCTUnwrap(command["id"] as? String)

        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id,
                               data: ["ok": false, "error": ["code": "no_reset_known",
                                                              "message": "quota-gate: no reset time is known"]]))

        qbWait("the completion") { result() != nil }
        guard case .failure(let error)? = result() else { return XCTFail("expected failure, got \(String(describing: result()))") }
        guard case .code(let code, let message) = error else { return XCTFail("expected a coded error, got \(error)") }
        XCTAssertEqual(code, .noResetKnown)
        XCTAssertEqual(message, "quota-gate: no reset time is known")
    }

    func testAnAckWithACodeThisBuildDoesNotKnowCompletesWithThatCode() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let (command, result) = try qbAskGate(.off)
        let id = try XCTUnwrap(command["id"] as? String)

        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id,
                               data: ["ok": false, "error": ["code": "weird_code", "message": "something new"]]))

        qbWait("the completion") { result() != nil }
        guard case .failure(let error)? = result() else { return XCTFail("expected failure, got \(String(describing: result()))") }
        guard case .unknownCode(let code) = error else { return XCTFail("expected an unknown code, got \(error)") }
        XCTAssertEqual(code, "weird_code")
        XCTAssertTrue(error.userFacingMessage.contains("weird_code"), error.userFacingMessage)
    }

    func testAnAckWithNoErrorCodeAndAnExplicitInternalCodeAreBothInternalErrors() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let bodies: [[String: Any]] = [
            ["ok": false],
            ["ok": false, "error": ["message": "no code here"]],
            ["ok": false, "error": ["code": "internal", "message": "boom"]],
        ]
        for body in bodies {
            let (command, result) = try qbAskGate(.off)
            let id = try XCTUnwrap(command["id"] as? String)
            serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: id, data: body))

            qbWait("the completion") { result() != nil }
            guard case .failure(let error)? = result() else { return XCTFail("expected failure for \(body)") }
            guard case .code(let code, _) = error else { return XCTFail("\(body): expected a coded error, got \(error)") }
            XCTAssertEqual(code, .internal, "\(body)")
        }
    }

    func testTwoCommandsInARowAreAnsweredEachByItsOwnAck() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let (firstCommand, first) = try qbAskGate(.off)
        let (secondCommand, second) = try qbAskGate(.on)
        let firstId = try XCTUnwrap(firstCommand["id"] as? String)
        let secondId = try XCTUnwrap(secondCommand["id"] as? String)
        XCTAssertNotEqual(firstId, secondId)

        // The acks arrive in the other order.
        let on = try QuotaFixture.block { $0["gate"] = "on"; $0["until"] = NSNull() }
        let off = try QuotaFixture.block { $0["gate"] = "off"; $0["until"] = NSNull() }
        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: secondId, data: ["ok": true, "state": "on", "quota": on]))
        serverWrite(try qbLine(dir: "ack", t: "quota-gate", id: firstId, data: ["ok": true, "state": "off", "quota": off]))

        qbWait("both completions") { first() != nil && second() != nil }
        guard case .success(let firstQuota)? = first(), case .success(let secondQuota)? = second() else {
            return XCTFail("expected two successes")
        }
        XCTAssertEqual(firstQuota?.gate, .off)
        XCTAssertEqual(secondQuota?.gate, .on)
    }

    // MARK: stop()

    /// A listener at `path` (replacing whatever file is there), or nil if one cannot be made.
    fileprivate func qbListen(at path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count <= cap else { Darwin.close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: cap) { destination in
                bytes.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 5) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// Whether a client connects to `listener` within `seconds`.
    fileprivate func qbConnectionArrives(on listener: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var watched = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&watched, 1, Int32(remaining * 1000))
            if ready > 0 { return watched.revents & Int16(POLLIN) != 0 }
            if ready < 0 && errno != EINTR { return false }
        }
    }

    /// The control for the next test: the client reconnects when its broker goes away. Without this, "a stopped
    /// client does not reconnect" would also pass if the harness could never observe a reconnect at all.
    func testAClientWhoseBrokerHangsUpReconnectsToTheListenerAtItsPath() throws {
        try qbHandshake(capabilities: Self.qbClassic)
        listenFd = -1   // the accept thread closed the first listener; keep tearDown off a stale fd number
        let listener = try XCTUnwrap(qbListen(at: sockPath), "a second listener at the broker's path")
        defer { Darwin.close(listener) }

        Darwin.close(serverFd)   // the broker hangs up
        serverFd = -1

        XCTAssertTrue(qbConnectionArrives(on: listener, within: 6), "the client should have come back to the path")
    }

    func testAStoppedClientDoesNotReconnect() throws {
        try qbHandshake(capabilities: Self.qbClassic)
        listenFd = -1   // the accept thread closed the first listener; keep tearDown off a stale fd number
        let listener = try XCTUnwrap(qbListen(at: sockPath), "a second listener at the broker's path")
        defer { Darwin.close(listener) }

        client.stop()

        XCTAssertFalse(qbConnectionArrives(on: listener, within: 2.5), "a stopped client must not dial the broker again")
    }

    func testAStoppedClientDoesNotReconnectAfterTheBrokerHangsUpEither() throws {
        try qbHandshake(capabilities: Self.qbClassic)
        listenFd = -1   // the accept thread closed the first listener; keep tearDown off a stale fd number
        let listener = try XCTUnwrap(qbListen(at: sockPath), "a second listener at the broker's path")
        defer { Darwin.close(listener) }

        client.stop()
        Darwin.close(serverFd)
        serverFd = -1

        XCTAssertFalse(qbConnectionArrives(on: listener, within: 2.5))
    }

    func testStopFailsACommandStillWaitingForItsAckAsDisconnected() throws {
        try qbHandshake(capabilities: Self.qbWithGate)
        let (_, result) = try qbAskGate(.off)

        client.stop()

        qbWait("the completion") { result() != nil }
        guard case .failure(let error)? = result() else { return XCTFail("expected failure, got \(String(describing: result()))") }
        guard case .disconnected = error else { return XCTFail("expected .disconnected, got \(error)") }
    }

    func testStopIsIdempotent() throws {
        try qbHandshake(capabilities: Self.qbClassic)
        client.stop()
        client.stop()   // and tearDown stops it once more
    }

    // MARK: Without the capability

    func testARequestIsRefusedAndNothingIsWrittenWhenTheHelloLacksQuotaGate() throws {
        try qbHandshake(capabilities: Self.qbClassic)   // `quota` (the category) is not `quota-gate`
        XCTAssertFalse(client.supportsQuotaGate)

        for request in MotherQuotaGateRequest.allCases {
            var result: Result<MotherQuota?, BrokerError>?
            client.setQuotaGate(request) { result = $0 }
            qbWait("the refusal") { result != nil }
            guard case .failure(let error)? = result else { return XCTFail("\(request): expected a refusal") }
            guard case .code(let code, _) = error else { return XCTFail("\(request): expected a coded error, got \(error)") }
            XCTAssertEqual(code, .invalidState, "\(request)")
        }

        // Nothing went out: the next thing the broker reads is this follow-up.
        client.cancel(job: "j-follow-up") { _ in }
        let next = try qbReadCommand()
        XCTAssertEqual(next["t"] as? String, "cancel", "something else was written first: \(next)")
    }

    func testARequestBeforeAnyHelloIsRefused() {
        var result: Result<MotherQuota?, BrokerError>?
        client.setQuotaGate(.off) { result = $0 }
        qbWait("the refusal") { result != nil }
        guard case .failure? = result else { return XCTFail("expected a refusal, got \(String(describing: result))") }
        XCTAssertFalse(client.supportsQuotaGate)
    }
}
