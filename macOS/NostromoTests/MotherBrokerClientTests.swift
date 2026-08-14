import XCTest
import Combine
// MotherBrokerClient, BrokerEvent, BrokerError, BrokerErrorCode, MotherJob, MotherJobSlim
// are compiled into this test target directly (logic test — no host app).

// MARK: - MotherBrokerClientTests

/// Integration tests for MotherBrokerClient using an in-process Unix-socket fake broker.
///
/// Each test:
///   1. Spins up a listening socket at a temp path.
///   2. Starts the client (connects asynchronously on its internal queue).
///   3. Accepts the connection in a background thread.
///   4. Exchanges pre-canned NDJSON lines with the client.
///   5. Observes published events via Combine.
///
/// ## f9 — why the unwraps here are `try XCTUnwrap` and the timeouts are 10 s
///
/// Three tests below used to read `wait(for:timeout: 3)`, then
/// `XCTAssertNotNil(x)`, then `x!`. `XCTAssertNotNil` does **not** stop
/// execution on failure, so a timed-out wait fell straight through to the force
/// unwrap and trapped — killing the whole xctest process, not the one test.
/// Observed once in three full-suite runs as `Executed 168 tests, with 0
/// failures` followed by `** TEST FAILED **`: 31 of 199 tests silently never
/// ran while the visible line read "0 failures". A suite that can void a sixth
/// of itself and still print a clean number cannot verify anything.
///
/// So: `try XCTUnwrap` (fails the single test cleanly), and every
/// socket-dependent wait raised from 3 s to 10 s. `wait(for:)` returns the
/// instant the expectation fulfils, so the higher ceiling costs a passing run
/// nothing while removing a timeout-under-load flake in the slowest class in
/// the suite. The two `timeout: 1` waits are self-fulfilling main-queue drains
/// and are deliberately short — leave them.
///
/// ## f2 — why setup throws rather than asserting, and why never `XCTSkip`
///
/// The same shape one frame earlier, and worse, because `setUp` runs before
/// every test. It created the listening socket and on failure did
/// `XCTFail(...); return` — which abandons the rest of `setUp`, *including*
/// `client = MotherBrokerClient(socketPath:)` on the last line. `client` is an
/// implicitly unwrapped optional, so the next test method to run reached it
/// through `performHandshake()` and trapped on nil, taking the process down
/// with it: one unlucky `socket()` voids every test that had not run yet, and
/// the visible line still reads "0 failures". `bind` and `listen` were not
/// checked at all — a failed `bind` presented as every test in the class
/// timing out at 10 s with nothing naming the cause.
///
/// Throwing from `setUpWithError` fails that one test cleanly and the test
/// method never runs, so there is no nil `client` left for anything to trap on.
/// Deliberately **not** `XCTSkip`: a skipped test reports a clean result
/// without checking anything, which is the precise defect this class already
/// learned about the hard way. A broker socket we cannot open is a broken
/// test, not an excused one.
final class MotherBrokerClientTests: XCTestCase {

    var client:    MotherBrokerClient!
    var serverFd:  Int32 = -1
    var listenFd:  Int32 = -1
    var sockPath:  String!
    var cancellables = Set<AnyCancellable>()

    // Semaphore signals when the server-side has accepted the client connection.
    let accepted = DispatchSemaphore(value: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        sockPath = NSTemporaryDirectory() + "nostromo-broker-test-\(ProcessInfo.processInfo.processIdentifier).sock"
        unlink(sockPath)

        // Create a listening AF_UNIX socket. Every errno below is read on the
        // line after its call: anything in between — a `guard`, a store, a
        // string interpolation — can make its own syscall and leave the report
        // naming the wrong failure.
        let socketFd     = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let socketErrno  = errno
        listenFd = socketFd                       // assign before throwing so tearDown closes it
        guard socketFd >= 0 else {
            throw SocketSetUpFailure(operation: "socket", errnoValue: socketErrno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        // Was `XCTAssert(pathBytes.count <= cap, ...)`, which records a failure
        // and then runs the copy anyway — a buffer overrun past `sun_path`, so
        // the assert protected nothing it was written to protect.
        guard pathBytes.count <= cap else {
            throw SocketSetUpFailure(
                operation: "sockPath is \(pathBytes.count) bytes, sun_path holds \(cap)",
                errnoValue: 0)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let bound: (result: Int32, errnoValue: Int32) = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let result = Darwin.bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                return (result: result, errnoValue: errno)
            }
        }
        guard bound.result == 0 else {
            throw SocketSetUpFailure(operation: "bind(\(sockPath!))", errnoValue: bound.errnoValue)
        }
        let listenResult = Darwin.listen(socketFd, 5)
        let listenErrno  = errno
        guard listenResult == 0 else {
            throw SocketSetUpFailure(operation: "listen", errnoValue: listenErrno)
        }

        // Accept client connection asynchronously so the test can proceed
        let listenFdCopy = listenFd
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            self.serverFd = Darwin.accept(listenFdCopy, nil, nil)
            Darwin.close(listenFdCopy)
            self.accepted.signal()
        }

        client = MotherBrokerClient(socketPath: sockPath)
    }

    override func tearDown() {
        if serverFd  >= 0 { Darwin.close(serverFd);  serverFd  = -1 }
        if listenFd  >= 0 { Darwin.close(listenFd);  listenFd  = -1 }
        if let sp = sockPath { unlink(sp) }
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Server helpers

    /// Write a JSON string + newline to the server fd (simulates broker output).
    func serverWrite(_ json: String) {
        let data = (json + "\n").data(using: .utf8)!
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(serverFd, base, raw.count)
        }
    }

    /// Read one \n-terminated line from the server fd (reads client's output).
    func serverReadLine() -> String? {
        var buf  = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let n = Darwin.read(serverFd, &byte, 1)
            if n <= 0 { return nil }
            if byte[0] == 0x0A { break }
            buf.append(byte[0])
        }
        return String(data: buf, encoding: .utf8)
    }

    // MARK: - Fake broker handshake helpers

    let helloJSON = """
        {"v":1,"dir":"event","t":"hello","id":"0","ts":"2026-06-01T00:00:00.000Z","data":{"protocol_version":1,"capabilities":["state","activity","await","current_activity","quota"]}}
        """

    /// Blocks until the background thread in `setUpWithError` has accepted the
    /// client's connection.
    ///
    /// Was `XCTAssertEqual(accepted.wait(...), .success, ...)`. The assert
    /// records a failure and then execution *continues*: the next line writes
    /// the hello to `serverFd`, still -1, which fails silently, and the test
    /// dies 10 s later at a `wait(for:)` timeout naming an expectation rather
    /// than the connection that was never accepted. Same assert-then-continue
    /// idiom the f9 note above condemns. Throwing stops at the cause.
    func waitForServerAccept() throws {
        guard accepted.wait(timeout: .now() + 5) == .success else {
            throw HandshakeFailure.serverNeverAccepted(seconds: 5)
        }
    }

    func performHandshake() throws {
        // Start client, wait for connection, send hello, consume subscribe
        client.start()
        try waitForServerAccept()
        serverWrite(helloJSON)                        // send hello → client sends subscribe
        _ = serverReadLine()                          // discard subscribe command
    }

    // MARK: - Tests

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 1: Date decode — millis-ts snapshot decodes; basic (no-frac) ts too.
    // ──────────────────────────────────────────────────────────────────────────

    func testDateDecoding_millisAndBasicTsDecode() throws {
        let snapshotExp = XCTestExpectation(description: "snapshot received")
        var receivedJobs: [MotherJob] = []

        client.events.sink { event in
            if case .snapshot(let jobs) = event {
                receivedJobs = jobs
                snapshotExp.fulfill()
            }
        }.store(in: &cancellables)

        try performHandshake()

        // Snapshot with two jobs: one millis-ts, one basic (no fractional)
        serverWrite("""
        {"v":1,"dir":"event","t":"snapshot","id":"1","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[{"id":"job-millis","state":"running","repo":"carefeed","isolation":"none","title":"Millis job","created_at":"2026-06-01T12:00:00.000Z","started_at":"2026-06-01T12:00:01.000Z","finished_at":null},{"id":"job-basic","state":"queued","repo":"carefeed","isolation":"none","title":"Basic ts job","created_at":"2026-06-01T12:00:00Z","started_at":null,"finished_at":null}]}}
        """)

        wait(for: [snapshotExp], timeout: 10)
        XCTAssertEqual(receivedJobs.count, 2)
        let millsJob = receivedJobs.first { $0.id == "job-millis" }
        let basicJob = receivedJobs.first { $0.id == "job-basic"  }
        XCTAssertNotNil(millsJob, "job with millis-ts should decode")
        XCTAssertNotNil(basicJob, "job with basic (no-frac) ts should decode")
        XCTAssertNotNil(millsJob?.createdAt,  "millis createdAt should parse")
        XCTAssertNotNil(basicJob?.createdAt,  "basic createdAt should parse")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 2: Envelope decode — hello captured, snapshot jobs decoded.
    // ──────────────────────────────────────────────────────────────────────────

    func testEnvelopeDecode_helloAndSnapshot() throws {
        var helloEvent: BrokerEvent?
        let helloExp    = XCTestExpectation(description: "hello received")
        let snapshotExp = XCTestExpectation(description: "snapshot received")
        var snapshotJobs: [MotherJob] = []

        client.events.sink { event in
            switch event {
            case .hello:
                helloEvent = event
                helloExp.fulfill()
            case .snapshot(let jobs):
                snapshotJobs = jobs
                snapshotExp.fulfill()
            default: break
            }
        }.store(in: &cancellables)

        try performHandshake()

        wait(for: [helloExp], timeout: 10)

        if case .hello(let ver, let caps) = helloEvent {
            XCTAssertEqual(ver, 1)
            XCTAssert(caps.contains("state"),  "capabilities should include 'state'")
            XCTAssert(caps.contains("await"),  "capabilities should include 'await'")
        } else {
            XCTFail("expected .hello event")
        }

        serverWrite("""
        {"v":1,"dir":"event","t":"snapshot","id":"2","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[{"id":"abc123","state":"running","repo":"carefeed","isolation":"worktree","title":"Build feature","created_at":"2026-06-01T00:00:00.000Z","started_at":"2026-06-01T00:00:01.000Z","finished_at":null}]}}
        """)

        wait(for: [snapshotExp], timeout: 10)
        XCTAssertEqual(snapshotJobs.count, 1)
        XCTAssertEqual(snapshotJobs[0].id,    "abc123")
        XCTAssertEqual(snapshotJobs[0].state, "running")
        XCTAssertEqual(snapshotJobs[0].repo,  "carefeed")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 3: Line framing — partial line buffered until \n arrives.
    // ──────────────────────────────────────────────────────────────────────────

    /// ## f12 — the negative this test is named for is now actually asserted
    ///
    /// It wrote half a line, slept 0.15 s under a comment reading "it should NOT
    /// have decoded the snapshot yet", and then never asserted it. The only
    /// thing it checked was that a *complete* line decodes, which TEST 2 already
    /// covers — so it passed identically against a client with no line framing
    /// at all, which is the one thing its name promises.
    ///
    /// The counter is what makes the negative statable: `receivedJobs.isEmpty`
    /// would also hold for a client that decoded the half-line into an empty job
    /// list, so it cannot distinguish "buffered" from "decoded to nothing".
    ///
    /// The main-queue drain before the zero-check is load-bearing, not
    /// ceremony. The client hands events to subscribers with
    /// `DispatchQueue.main.async`, and `Thread.sleep` here parks the main
    /// queue — so a premature decode would sit undelivered and "still zero"
    /// would be measuring the sleep, not the framing. Draining first is the
    /// same idiom TEST 8 uses. The lock keeps the counter honest if delivery
    /// ever stops being main-queue-confined.
    func testLineFraming_partialLineBufferedUntilNewline() throws {
        let snapshotExp = XCTestExpectation(description: "snapshot from split write")
        var receivedJobs: [MotherJob] = []
        let decodeLock  = NSLock()
        var decodeCount = 0

        func decodesSoFar() -> Int {
            decodeLock.lock()
            defer { decodeLock.unlock() }
            return decodeCount
        }

        client.events.sink { event in
            if case .snapshot(let jobs) = event {
                decodeLock.lock()
                decodeCount += 1
                decodeLock.unlock()
                receivedJobs = jobs
                snapshotExp.fulfill()
            }
        }.store(in: &cancellables)

        try performHandshake()

        // Write a snapshot split across two writes (first half without \n)
        let snapshotPart1 = """
        {"v":1,"dir":"event","t":"snapshot","id":"3","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[{"id":"split-job","state":"queued","repo":"r","isolation":"none","title":"Split
        """
        let snapshotPart2 = """
        job","created_at":"2026-06-01T00:00:00.000Z","started_at":null,"finished_at":null}]}}
        """

        // Write part 1 raw (no newline appended)
        let data1 = snapshotPart1.data(using: .utf8)!
        data1.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(serverFd, base, raw.count)
        }

        // Give the client a moment, then flush the queue it would have delivered
        // on: with no newline written, nothing may have been decoded yet.
        Thread.sleep(forTimeInterval: 0.15)
        let preNewlineDrain = XCTestExpectation(description: "pre-newline main queue drain")
        DispatchQueue.main.async { preNewlineDrain.fulfill() }
        wait(for: [preNewlineDrain], timeout: 1)

        XCTAssertEqual(decodesSoFar(), 0,
                       "client decoded a snapshot from a line with no terminating newline")

        // Now complete the line with part 2 + \n
        serverWrite(snapshotPart2)

        wait(for: [snapshotExp], timeout: 10)
        XCTAssertEqual(decodesSoFar(), 1,
                       "completing the line should have delivered exactly one snapshot")
        XCTAssertEqual(receivedJobs.count, 1)
        XCTAssertEqual(receivedJobs[0].id, "split-job")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 4: Command correlation — cancel resolves when matching ack arrives.
    //         Out-of-order: ping arrives before the ack.
    // ──────────────────────────────────────────────────────────────────────────

    func testCommandCorrelation_cancelResolvesOnMatchingAck_withPingInterleave() throws {
        let cancelExp = XCTestExpectation(description: "cancel completion called")
        var cancelResult: Result<Void, BrokerError>?

        try performHandshake()

        // Send snapshot so AppStore-like callers can proceed; also confirms connected
        serverWrite("""
        {"v":1,"dir":"event","t":"snapshot","id":"4","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[]}}
        """)

        // Wait for connected
        let connExp = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in connExp.fulfill() }
            .store(in: &cancellables)
        wait(for: [connExp], timeout: 10)

        // Issue cancel — client sends a cmd with a UUID id
        client.cancel(job: "job-abc") { result in
            cancelResult = result
            cancelExp.fulfill()
        }

        // Read the cancel command the client sent
        guard let cmdLine = serverReadLine(),
              let cmdData = cmdLine.data(using: .utf8),
              let cmdJson = try? JSONSerialization.jsonObject(with: cmdData) as? [String: Any],
              let cmdId   = cmdJson["id"] as? String,
              let cmdType = cmdJson["t"]  as? String
        else {
            XCTFail("failed to read cancel command from client"); return
        }
        XCTAssertEqual(cmdType, "cancel")

        // Interleave a ping BEFORE the ack — client must handle both
        serverWrite("""
        {"v":1,"dir":"event","t":"ping","id":"5","ts":"2026-06-01T00:00:00.000Z","data":{}}
        """)

        // Now send the ack with the matching id
        serverWrite("""
        {"v":1,"dir":"ack","t":"cancel","id":"\(cmdId)","ts":"2026-06-01T00:00:00.000Z","data":{"ok":true,"job":"job-abc"}}
        """)

        wait(for: [cancelExp], timeout: 10)
        let cancel = try XCTUnwrap(cancelResult, "cancel completion never delivered a result")
        if case .success = cancel { /* expected */ } else {
            XCTFail("expected .success, got \(cancel)")
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 5: Error mapping — failure ack → correct BrokerError case.
    // ──────────────────────────────────────────────────────────────────────────

    func testErrorMapping_noSuchJobAck() throws {
        let retryExp = XCTestExpectation(description: "retry completion called")
        var retryResult: Result<Void, BrokerError>?

        try performHandshake()

        let connExp = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in connExp.fulfill() }
            .store(in: &cancellables)
        wait(for: [connExp], timeout: 10)

        client.retry(job: "gone-job") { result in
            retryResult = result
            retryExp.fulfill()
        }

        guard let cmdLine = serverReadLine(),
              let cmdData = cmdLine.data(using: .utf8),
              let cmdJson = try? JSONSerialization.jsonObject(with: cmdData) as? [String: Any],
              let cmdId   = cmdJson["id"] as? String
        else {
            XCTFail("failed to read retry command"); return
        }

        // Send a failure ack with no_such_job
        serverWrite("""
        {"v":1,"dir":"ack","t":"retry","id":"\(cmdId)","ts":"2026-06-01T00:00:00.000Z","data":{"ok":false,"error":{"code":"no_such_job","message":"job gone-job not found"}}}
        """)

        wait(for: [retryExp], timeout: 10)
        let retry = try XCTUnwrap(retryResult, "retry completion never delivered a result")
        if case .failure(let err) = retry {
            if case .code(let code, _) = err {
                XCTAssertEqual(code, .noSuchJob)
            } else {
                XCTFail("expected .code(.noSuchJob), got \(err)")
            }
        } else {
            XCTFail("expected failure, got success")
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 6: State event — stateChange published with correct fold fields.
    // ──────────────────────────────────────────────────────────────────────────

    func testStateEventFold_awaitingInputEvent() throws {
        let stateExp = XCTestExpectation(description: "stateChange received")
        var changedEvent: BrokerEvent?

        client.events.sink { event in
            if case .stateChange = event {
                changedEvent = event
                stateExp.fulfill()
            }
        }.store(in: &cancellables)

        try performHandshake()

        serverWrite("""
        {"v":1,"dir":"event","t":"awaiting_input","id":"6","ts":"2026-06-01T00:00:00.000Z","data":{"job":"job-xyz","category":"await","question":"Should I proceed?"}}
        """)

        wait(for: [stateExp], timeout: 10)
        let changed = try XCTUnwrap(changedEvent, "no stateChange event was published")
        if case .stateChange(let jobId, let kind, let question, _, _) = changed {
            XCTAssertEqual(jobId,    "job-xyz")
            XCTAssertEqual(kind,     "awaiting_input")
            XCTAssertEqual(question, "Should I proceed?")
        } else {
            XCTFail("expected .stateChange")
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 7: Subscribe command — client sends subscribe after hello.
    // ──────────────────────────────────────────────────────────────────────────

    // Cannot use `performHandshake()`: this test asserts on the subscribe line
    // the handshake helper discards.
    func testSubscribe_sentAfterHello() throws {
        client.start()
        try waitForServerAccept()
        serverWrite(helloJSON)

        // Read the subscribe command sent by the client
        guard let cmdLine = serverReadLine(),
              let cmdData = cmdLine.data(using: .utf8),
              let cmdJson = try? JSONSerialization.jsonObject(with: cmdData) as? [String: Any]
        else {
            XCTFail("no subscribe command received"); return
        }

        XCTAssertEqual(cmdJson["t"]   as? String, "subscribe")
        XCTAssertEqual(cmdJson["dir"] as? String, "cmd")
        XCTAssertEqual(cmdJson["v"]   as? Int,    1)

        if let data = cmdJson["data"] as? [String: Any] {
            XCTAssertEqual(data["sub"]  as? String, "queue")
            let jobs = data["jobs"] as? [String]
            XCTAssert(jobs?.contains("all") == true, "jobs should include 'all'")
            let cats = data["categories"] as? [String] ?? []
            XCTAssert(!cats.isEmpty, "categories should not be empty")
            XCTAssert(cats.contains("state"), "categories should include 'state'")
        } else {
            XCTFail("subscribe command missing data field")
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 8: Orphan ack — ack with unknown id is silently ignored (no crash,
    //         no stateChange or snapshot event).
    // ──────────────────────────────────────────────────────────────────────────

    func testOrphanAck_isIgnored() throws {
        try performHandshake()

        // Drain handshake events (hello) from the main queue before subscribing
        let drainExp = XCTestExpectation(description: "main queue drain")
        DispatchQueue.main.async { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 1)

        // Subscribe only to data-bearing events — orphan ack produces none
        var receivedDataEvent = false
        client.events.sink { event in
            switch event {
            case .snapshot, .stateChange:
                receivedDataEvent = true
            default:
                break  // .hello, .ping, .reconnected are not orphan-ack artifacts
            }
        }.store(in: &cancellables)

        // Send an ack for an id the client never sent
        serverWrite("""
        {"v":1,"dir":"ack","t":"cancel","id":"unknown-id-999","ts":"2026-06-01T00:00:00.000Z","data":{"ok":true,"job":"x"}}
        """)

        // Give the read loop time to process the line
        Thread.sleep(forTimeInterval: 0.2)

        // Drain any pending main-queue dispatches
        let drainExp2 = XCTestExpectation(description: "post-ack drain")
        DispatchQueue.main.async { drainExp2.fulfill() }
        wait(for: [drainExp2], timeout: 1)

        XCTAssertFalse(receivedDataEvent, "orphan ack must not publish a data event")
    }
}

// MARK: - Fake broker failures

/// f2 — thrown, not asserted, so a broker socket that cannot be created stops
/// the test at the line that failed instead of falling through to a nil
/// `client` and trapping the process. `CustomStringConvertible` because XCTest
/// prints the description of a thrown error, and `strerror` is the difference
/// between a report that names the cause and one that says "setup failed".
private struct SocketSetUpFailure: Error, CustomStringConvertible {
    let operation:  String
    let errnoValue: Int32

    var description: String {
        guard errnoValue != 0 else {
            return "fake broker setup failed: \(operation)"
        }
        return "fake broker setup failed: \(operation) — errno \(errnoValue) "
             + "(\(String(cString: strerror(errnoValue))))"
    }
}

private enum HandshakeFailure: Error, CustomStringConvertible {
    case serverNeverAccepted(seconds: Int)

    var description: String {
        switch self {
        case .serverNeverAccepted(let seconds):
            return "fake broker never accepted the client connection within \(seconds)s — "
                 + "every serverWrite() after this point would have written to a closed fd"
        }
    }
}
