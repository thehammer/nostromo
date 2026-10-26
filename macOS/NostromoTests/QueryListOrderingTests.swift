import XCTest
import Combine
import Darwin
import NostromoKit

// MotherBrokerClient and BrokerError are compiled into this test target directly (logic test, no
// host app). The broker is a real AF_UNIX listening socket in this process, as in
// `MotherBrokerClientTests`; this file carries its own minimal copy of it because that one is
// private to its file.

/// The contract of `MotherBrokerClient.queryList` when replies overlap.
///
/// `query.list` replies are decoded off the main thread, so two replies that arrive in order can
/// finish decoding out of order. The consumer (the queue store) replaces its whole job list with
/// each listing it is handed, so a stale listing delivered after a newer one would put an older
/// queue over a newer one. The contract, from the outside:
///
///  1. Replies that do not overlap are each delivered as `.success`, in order.
///  2. When an older reply's decode finishes after a newer reply was already delivered, the older
///     one's completion gets `.failure(.superseded)` and never a `.success`; the newer listing is
///     the last (and only) one applied.
///  3. A drop does not poison later replies.
///
/// The overlap is forced through the `listingDecodeHook` seam, which runs on the decode thread
/// before decoding: the test parks the first reply's decode on a semaphore until the second
/// reply has been delivered. Replies are told apart by a job id in their payload.
final class QueryListOrderingTests: XCTestCase {

    // MARK: - Fake broker

    private var client: MotherBrokerClient!
    private var listenFd: Int32 = -1
    private var serverFd: Int32 = -1
    private var sockPath = ""
    private var cancellables = Set<AnyCancellable>()
    private let accepted = DispatchSemaphore(value: 0)

    private struct SetUpFailure: Error, CustomStringConvertible {
        let description: String
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sockPath = "/tmp/qlo-\(getpid())-\(UUID().uuidString.prefix(6)).sock"
        unlink(sockPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let socketErrno = errno
        listenFd = fd                       // assign before throwing so tearDown closes it
        guard fd >= 0 else { throw SetUpFailure(description: "socket failed, errno \(socketErrno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else { throw SetUpFailure(description: "socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let bound: (result: Int32, errnoValue: Int32) = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let result = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                return (result, errno)
            }
        }
        guard bound.result == 0 else { throw SetUpFailure(description: "bind failed, errno \(bound.errnoValue)") }
        let listenResult = Darwin.listen(fd, 2)
        let listenErrno = errno
        guard listenResult == 0 else { throw SetUpFailure(description: "listen failed, errno \(listenErrno)") }

        let listening = fd
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let conn = Darwin.accept(listening, nil, nil)
            if conn >= 0 {
                // A client that never writes must fail a test, not hang the suite.
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            }
            self.serverFd = conn
            self.accepted.signal()
        }

        client = MotherBrokerClient(socketPath: sockPath)
    }

    override func tearDown() {
        client?.listingDecodeHook = nil
        if serverFd >= 0 { Darwin.close(serverFd); serverFd = -1 }
        if listenFd >= 0 { Darwin.close(listenFd); listenFd = -1 }
        if !sockPath.isEmpty { unlink(sockPath) }
        cancellables.removeAll()
        super.tearDown()
    }

    private func serverWrite(_ json: String) {
        let data = Data((json + "\n").utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(serverFd, base, raw.count)
        }
    }

    private func serverReadLine() -> String? {
        var buf = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(serverFd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { break }
            buf.append(byte)
        }
        return String(data: buf, encoding: .utf8)
    }

    private func readCommand() throws -> [String: Any] {
        let line = try XCTUnwrap(serverReadLine(), "the client wrote nothing")
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(line)")
    }

    private func connectAndHandshake() throws {
        client.start()
        guard accepted.wait(timeout: .now() + 5) == .success, serverFd >= 0 else {
            throw SetUpFailure(description: "the fake broker never accepted the client connection")
        }
        serverWrite("""
            {"v":1,"dir":"event","t":"hello","id":"0","ts":"2026-06-01T00:00:00.000Z","data":{"protocol_version":1,"capabilities":["state","activity","await","current_activity","quota"]}}
            """)
        let subscribe = try readCommand()
        XCTAssertEqual(subscribe["t"] as? String, "subscribe")

        let connected = expectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in connected.fulfill() }.store(in: &cancellables)
        wait(for: [connected], timeout: 10)
    }

    /// Reads the next command, which must be a `query.list`, and returns its id.
    private func readQueryListId() throws -> String {
        let cmd = try readCommand()
        XCTAssertEqual(cmd["t"] as? String, "query.list")
        return try XCTUnwrap(cmd["id"] as? String, "query.list carried no id")
    }

    private func job(_ id: String) -> [String: Any] {
        ["id": id, "state": "queued", "repo": "Carefeed/example", "isolation": "worktree", "title": "Job \(id)"]
    }

    private func ackList(id: String, jobIds: [String]) throws {
        let ack: [String: Any] = [
            "v": 1, "dir": "ack", "t": "query.list", "id": id, "ts": "2026-06-01T00:00:00.000Z",
            "data": ["ok": true, "jobs": jobIds.map(job)] as [String: Any],
        ]
        let body = try JSONSerialization.data(withJSONObject: ack)
        serverWrite(String(decoding: body, as: UTF8.self))
    }

    // MARK: - Delivery log (main thread only: every completion asserts it)

    /// What each caller was told, in the order it was told: `<label>:ok:<job ids>` or `<label>:superseded`.
    private var deliveries: [String] = []

    private func ask(_ label: String, done: XCTestExpectation) {
        client.queryList { [weak self] result in
            XCTAssertTrue(Thread.isMainThread, "\(label): completions are delivered on the main thread")
            switch result {
            case .success(let listing):
                self?.deliveries.append("\(label):ok:" + listing.jobs.map(\.id).joined(separator: ","))
            case .failure(.superseded):
                self?.deliveries.append("\(label):superseded")
            case .failure(let error):
                self?.deliveries.append("\(label):error:\(error)")
            }
            done.fulfill()
        }
    }

    /// Parks the decode of any reply that contains `jobId` until `gate` is signalled (or 10 s pass,
    /// so a failing test cannot wedge a worker thread).
    private func parkDecode(ofReplyContaining jobId: String, until gate: DispatchSemaphore) {
        client.listingDecodeHook = { raw in
            if raw.contains(where: { $0["id"] as? String == jobId }) {
                _ = gate.wait(timeout: .now() + 10)
            }
        }
    }

    // MARK: - (1) Replies that do not overlap

    func testRepliesThatDoNotOverlapAreEachDeliveredAsSuccessInOrder() throws {
        try connectAndHandshake()

        let first = expectation(description: "first delivered")
        ask("first", done: first)
        try ackList(id: try readQueryListId(), jobIds: ["qlo-a1", "qlo-a2"])
        wait(for: [first], timeout: 10)

        let second = expectation(description: "second delivered")
        ask("second", done: second)
        try ackList(id: try readQueryListId(), jobIds: ["qlo-b1"])
        wait(for: [second], timeout: 10)

        XCTAssertEqual(deliveries, ["first:ok:qlo-a1,qlo-a2", "second:ok:qlo-b1"],
                       "in-order replies are both applied, oldest first")
    }

    // MARK: - (2) An older reply that finishes decoding last is dropped

    func testAnOlderReplyWhoseDecodeFinishesAfterANewerOneWasDeliveredIsDroppedAsSuperseded() throws {
        try connectAndHandshake()
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        parkDecode(ofReplyContaining: "qlo-old", until: gate)

        let older = expectation(description: "older completed")
        let newer = expectation(description: "newer completed")
        ask("older", done: older)
        ask("newer", done: newer)
        let olderId = try readQueryListId()
        let newerId = try readQueryListId()
        try ackList(id: olderId, jobIds: ["qlo-old"])
        try ackList(id: newerId, jobIds: ["qlo-new"])

        // The newer listing arrives while the older one's decode is still parked.
        wait(for: [newer], timeout: 10)
        XCTAssertEqual(deliveries, ["newer:ok:qlo-new"],
                       "the newer listing is delivered without waiting for the older decode")

        gate.signal()
        wait(for: [older], timeout: 10)

        XCTAssertEqual(deliveries, ["newer:ok:qlo-new", "older:superseded"],
                       "the stale listing must never be applied after the newer one")
        XCTAssertFalse(deliveries.contains { $0.hasPrefix("older:ok") },
                       "a superseded reply gets no .success at all")
    }

    /// The outcome must not depend on the stale reply being the only thing in flight: three replies,
    /// the oldest two parked, the newest delivered, the others dropped.
    func testEveryReplyOlderThanTheOneAlreadyDeliveredIsDropped() throws {
        try connectAndHandshake()
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal(); gate.signal() }
        client.listingDecodeHook = { raw in
            let ids = raw.compactMap { $0["id"] as? String }
            if ids.contains("qlo-1") || ids.contains("qlo-2") { _ = gate.wait(timeout: .now() + 10) }
        }

        let done = (1 ... 3).map { expectation(description: "reply \($0) completed") }
        ask("r1", done: done[0])
        ask("r2", done: done[1])
        ask("r3", done: done[2])
        let ids = [try readQueryListId(), try readQueryListId(), try readQueryListId()]
        try ackList(id: ids[0], jobIds: ["qlo-1"])
        try ackList(id: ids[1], jobIds: ["qlo-2"])
        try ackList(id: ids[2], jobIds: ["qlo-3"])

        wait(for: [done[2]], timeout: 10)
        gate.signal()
        gate.signal()
        wait(for: [done[0], done[1]], timeout: 10)

        XCTAssertEqual(deliveries.first, "r3:ok:qlo-3")
        XCTAssertEqual(Set(deliveries.dropFirst()), ["r1:superseded", "r2:superseded"])
        XCTAssertEqual(deliveries.filter { $0.contains(":ok:") }.count, 1,
                       "exactly one listing is applied, and it is the newest")
    }

    // MARK: - (3) A drop does not poison what follows

    func testAReplyAfterASupersededDropIsDeliveredNormally() throws {
        try connectAndHandshake()
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        parkDecode(ofReplyContaining: "qlo-old", until: gate)

        let older = expectation(description: "older completed")
        let newer = expectation(description: "newer completed")
        ask("older", done: older)
        ask("newer", done: newer)
        let olderId = try readQueryListId()
        let newerId = try readQueryListId()
        try ackList(id: olderId, jobIds: ["qlo-old"])
        try ackList(id: newerId, jobIds: ["qlo-new"])
        wait(for: [newer], timeout: 10)
        gate.signal()
        wait(for: [older], timeout: 10)
        XCTAssertEqual(deliveries.last, "older:superseded", "precondition: a stale reply was dropped")

        let later = expectation(description: "later completed")
        ask("later", done: later)
        try ackList(id: try readQueryListId(), jobIds: ["qlo-later"])
        wait(for: [later], timeout: 10)

        XCTAssertEqual(deliveries.last, "later:ok:qlo-later",
                       "after a drop the next reply is a normal listing, not another .superseded")
    }

    // MARK: - The error itself

    func testSupersededIsClassifiedAsOtherAndHasAMessageToShow() {
        let error = BrokerError.superseded
        XCTAssertEqual(error.kind, .other)
        XCTAssertFalse(error.userFacingMessage.isEmpty)
        XCTAssertFalse(error.userFacingMessage.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
