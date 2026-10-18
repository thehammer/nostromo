import XCTest
import AppKit
import Combine
import NostromoKit
import SwiftUI
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
/// ## Why the unwraps here are `try XCTUnwrap` and the timeouts are 10 s
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
/// ## Why setup throws rather than asserting, and why never `XCTSkip`
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
    /// idiom the note above condemns. Throwing stops at the cause.
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

    /// ## The negative this test is named for is now actually asserted
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

/// Thrown, not asserted, so a broker socket that cannot be created stops
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

// ══════════════════════════════════════════════════════════════════════════════
// MC2 — the Mother panel shows crew state without layout churn.
//
// Everything below is behavioural: it drives the broker client over the fake
// socket, the job detail through its public surface inside a real (hidden) window,
// and reads results back from the views and the host stub. Nothing asserts how the
// views are built, only what a reader would see keep still or change.
// ══════════════════════════════════════════════════════════════════════════════

// MARK: - Shared MC2 builders

private func mc2Job(id: String = "j1", state: String = "running", repo: String = "Carefeed/payments",
                    title: String = "A job", planPath: String? = nil, question: String? = nil,
                    crew: MotherCrewState = MotherCrewState()) -> MotherJob {
    MotherJob(id: id, state: state, repo: repo, isolation: "worktree", title: title,
              createdAt: nil, startedAt: nil, finishedAt: nil, planPath: planPath, question: question,
              pausedReason: nil, adherenceStatus: nil, currentTier: nil, crew: crew)
}

private func mc2Progress(pct: Int, updatedAt: String? = "2026-10-17T12:00:00.000Z",
                         label: String = "Implementing", etaLabel: String = "5-15 min") -> MotherProgress {
    MotherProgress(v: 1, pct: pct, label: label, stage: "implement",
                   signals: MotherProgressSignals(stage: "implement", elapsedActiveS: 420, cost: 1.12),
                   eta: MotherProgressEta(loS: 300, hiS: 900, label: etaLabel, basis: "fleet"),
                   paused: false, flags: [], updatedAt: updatedAt)
}

private func mc2Decision(id: String = "d-0001", open: Bool = true) -> MotherDecision {
    MotherDecision(
        id: id, kind: "gate_hold",
        options: [
            MotherDecisionOption(id: .resumeWithGuidance, label: "Resume with guidance",
                                 consequence: "Worker resumes in the same session with your note; gates re-run.", takesText: true),
            MotherDecisionOption(id: .escalate, label: "Escalate", consequence: "Re-run one tier up.", takesText: false),
            MotherDecisionOption(id: .overrideOpen, label: "Override and open",
                                 consequence: "Mark the PR ready with red gates recorded as overridden.", takesText: false),
            MotherDecisionOption(id: .cancel, label: "Cancel", consequence: "Stop the job.", takesText: false),
        ],
        openedAt: "2026-10-17T12:00:02.000Z",
        resolvedAt: open ? nil : "2026-10-17T12:05:00.000Z"
    )
}

/// A crew state whose row structure is set by `gateCount`, `decisionId` and `activity`; everything
/// else (percentage, ETA, a gate's result word, the acknowledged flag) is a value that moves in place.
private func mc2Crew(pct: Int = 50, unitResult: MotherGateResult = .unknown("running"), gateCount: Int = 2,
                     acked: Bool = false, etaLabel: String = "5-15 min",
                     decisionId: String? = "d-0001", activity: String? = "gate_hold") -> MotherCrewState {
    var results = [
        MotherGateResultEntry(name: "lint", result: .passed, blocking: true, durationS: 40),
        MotherGateResultEntry(name: "unit", result: unitResult, blocking: true, durationS: 188),
    ]
    if gateCount > 2 {
        for n in 2..<gateCount {
            results.append(MotherGateResultEntry(name: "extra\(n)", result: .passed, blocking: false, durationS: 5))
        }
    }
    return MotherCrewState(
        optedIn: true,
        activity: activity,
        gates: MotherGates(mode: "enforce", status: "running", attempt: 1, maxAttempts: 3, results: results),
        decision: decisionId.map { mc2Decision(id: $0) },
        attention: [MotherAttention(reason: .progressStalled, since: "2026-10-17T12:00:02.000Z", acked: acked)],
        progress: mc2Progress(pct: pct, updatedAt: String(format: "2026-10-17T12:%02d:00.000Z", pct % 60), etaLabel: etaLabel)
    )
}

private func mc2AllSubviews(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + mc2AllSubviews($0) }
}

/// Spin the main run loop for `seconds` (timers and `DispatchQueue.main` work run meanwhile).
private func mc2Spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}

/// Spin until `condition` holds (true) or `timeout` passes (false).
private func mc2WaitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return condition()
}

/// One word per event the MC2 tests care about; nil for the rest (hello, ping, snapshot ...).
private func mc2Describe(_ event: BrokerEvent) -> String? {
    switch event {
    case .progress(let jobId, _):                  return "progress:\(jobId)"
    case .crewChanged(let jobId):                  return "crew:\(jobId)"
    case .stateChange(let jobId, let kind, _, _, _): return "state:\(kind):\(jobId)"
    default:                                       return nil
    }
}

private func mc2StreamLine(_ n: Int) -> String {
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"line \#(n)"}]}}"#
}

private func mc2StreamLog(_ lines: Range<Int>) -> String {
    lines.map(mc2StreamLine).joined(separator: "\n")
}

// MARK: - MC2 host stub

/// Everything `MotherJobDetail` asks of the app, recorded.
private final class MC2StubHost: MotherJobDetailHost {
    let connectedSubject = CurrentValueSubject<Bool, Never>(true)
    let errorSubject     = CurrentValueSubject<String?, Never>(nil)
    let peeksSubject     = CurrentValueSubject<[String: MotherPeekPayload], Never>([:])

    var brokerConnected: Bool { connectedSubject.value }
    var brokerConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var motherActionErrorPublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }
    var motherPeeksPublisher: AnyPublisher<[String: MotherPeekPayload], Never> { peeksSubject.eraseToAnyPublisher() }
    func peek(for jobId: String) -> MotherPeekPayload? { nil }

    var usesDefaultBroker = true
    var binary: URL?
    func motherBinary() -> URL? { binary }

    var answers: [(id: String, text: String)] = []
    var cancelled: [String] = []
    var openedPlans: [String] = []

    func answerJob(_ id: String, text: String) { answers.append((id, text)) }
    func cancelJob(_ id: String) { cancelled.append(id) }
    func retryJob(_ id: String) {}
    func forceStartJob(_ id: String) {}
    func escalateJob(_ id: String) {}
    func archiveJob(_ id: String) {}
    func openPlan(path: String) { openedPlans.append(path) }
    func clearMotherActionError() {}
}

// ══════════════════════════════════════════════════════════════════════════════
// A1: the Mac's job decoder keeps crew data, and never loses a job over it.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2JobSlimCrewDecodingTests: XCTestCase {

    /// A trimmed j-hold1 fixture job carrying every crew key; `gates` is substituted so a test can break it.
    private func jobJSON(gates: String) -> String {
        """
        {"id":"j-hold1","state":"awaiting","repo":"Carefeed/payments","isolation":"worktree","title":"Backfill invoice totals",
        "created_at":"2026-10-17T11:10:00.000Z","started_at":"2026-10-17T11:11:20.000Z","finished_at":null,
        "plan_path":"/tmp/plans/j-hold1.md","current_tier":"tier_0","kind":null,"phases":[],"cycles":[],
        "question":"Gate attempts are exhausted (3 of 3)","paused_reason":"gate_hold","activity":"gate_hold",
        "pr_url":"https://github.com/Carefeed/payments/pull/907","crew":{"mode":"enforce"},
        "gates":\(gates),
        "review_wave":{"mode":"enforce","cycle":1,"cycle_cap":2,"status":"running","lenses":[
          {"reviewer":"perri:ops-infra","lens":"ops-infra","state":"skipped","skip_reason":"path_scope","findings":{"blocking":0,"advisory":0}}],
          "claims":{"verified":0,"refuted":0,"unverified":0}},
        "decision":{"id":"d-0001","kind":"gate_hold","options":[
          {"id":"resume_with_guidance","label":"Resume with guidance","consequence":"Worker resumes.","takes_text":true},
          {"id":"cancel","label":"Cancel","consequence":"Stop the job.","takes_text":false}],
          "opened_at":"2026-10-17T12:00:02.000Z","resolved_at":null,"resolution":null},
        "attention":[{"reason":"decision_awaiting","since":"2026-10-17T12:00:02.000Z"}],
        "progress":{"v":1,"pct":55,"label":"Implementing","stage":"implement",
          "signals":{"stage":"implement","gates":null,"elapsed_active_s":420,"cost":1.12},
          "eta":{"lo_s":300,"hi_s":900,"label":"5-15 min","basis":"fleet"},"paused":false,"flags":[],
          "updated_at":"2026-10-17T12:00:00.000Z"}}
        """
    }

    private let goodGates = """
        {"mode":"enforce","status":"exhausted","attempt":3,"max_attempts":3,"head_sha":"e41b7f0",
         "results":[{"name":"unit","result":"failed","blocking":true,"duration_s":201,"exit_code":1}],"not_run":[],"override":null}
        """

    private func decode(_ json: String) throws -> MotherJob {
        try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8)).toMotherJob()
    }

    func testAJobWithCrewKeysDecodesGatesWaveDecisionAttentionAndProgress() throws {
        let job = try decode(jobJSON(gates: goodGates))

        XCTAssertEqual(job.id, "j-hold1")
        XCTAssertEqual(job.state, "awaiting")
        XCTAssertEqual(job.crew.activity, "gate_hold")
        XCTAssertTrue(job.crew.optedIn)
        XCTAssertEqual(job.crew.gates?.status, "exhausted")
        XCTAssertEqual(job.crew.gates?.results.first?.name, "unit")
        XCTAssertEqual(job.crew.gates?.results.first?.result, .failed)
        XCTAssertEqual(job.crew.reviewWave?.lenses.first?.state, .skipped)
        XCTAssertEqual(job.crew.decision?.id, "d-0001")
        XCTAssertEqual(job.crew.decision?.options.map(\.id), [.resumeWithGuidance, .cancel])
        XCTAssertEqual(job.crew.attention.map(\.reason), [.decisionAwaiting])
        XCTAssertEqual(job.crew.progress?.pct, 55)
        XCTAssertEqual(job.crew.progress?.eta?.label, "5-15 min")
        XCTAssertEqual(job.crew.decodeIssues, [])
    }

    func testAMalformedGatesKeyCostsOnlyThatKey() throws {
        let job = try decode(jobJSON(gates: #""not an object""#))

        // The job and every other crew key survive.
        XCTAssertEqual(job.id, "j-hold1")
        XCTAssertEqual(job.title, "Backfill invoice totals")
        XCTAssertNil(job.crew.gates)
        XCTAssertEqual(job.crew.decision?.id, "d-0001")
        XCTAssertEqual(job.crew.attention.map(\.reason), [.decisionAwaiting])
        XCTAssertEqual(job.crew.progress?.pct, 55)
        XCTAssertEqual(job.crew.reviewWave?.cycle, 1)
        // The key's name is recorded, never its value.
        XCTAssertEqual(job.crew.decodeIssues, ["gates"])
    }

    func testAJobWithNoCrewKeysHasAnEmptyCrew() throws {
        let job = try decode("""
            {"id":"plain","state":"running","repo":"Carefeed/payments","isolation":"worktree","title":"Plain",
             "created_at":"2026-10-17T11:10:00.000Z","started_at":null,"finished_at":null}
            """)
        XCTAssertEqual(job.crew, MotherCrewState())
        XCTAssertNil(job.crew.progress)
        XCTAssertTrue(job.crew.attention.isEmpty)
        XCTAssertNil(job.holdSummary)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// A2–A5: the broker client over the fake socket.
// ══════════════════════════════════════════════════════════════════════════════

extension MotherBrokerClientTests {

    // MARK: Helpers

    fileprivate func helloWith(capabilities: [String]) -> String {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"v":1,"dir":"event","t":"hello","id":"0","ts":"2026-06-01T00:00:00.000Z","data":{"protocol_version":1,"capabilities":[\#(caps)]}}"#
    }

    /// Read the next command the client wrote, as a JSON object.
    fileprivate func readCommandObject() throws -> [String: Any] {
        let line = try XCTUnwrap(serverReadLine(), "the client wrote nothing")
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(line)")
    }

    /// Connect, send `hello`, and return the subscribe command the client answers with.
    fileprivate func subscribeCommand(afterHello hello: String) throws -> [String: Any] {
        client.start()
        try waitForServerAccept()
        serverWrite(hello)
        return try readCommandObject()
    }

    fileprivate func subscribedCategories(afterHello hello: String) throws -> [String] {
        let cmd = try subscribeCommand(afterHello: hello)
        XCTAssertEqual(cmd["t"] as? String, "subscribe")
        let data = try XCTUnwrap(cmd["data"] as? [String: Any], "subscribe has no data")
        return try XCTUnwrap(data["categories"] as? [String], "subscribe has no categories")
    }

    fileprivate func waitUntilConnected() {
        let exp = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in exp.fulfill() }.store(in: &cancellables)
        wait(for: [exp], timeout: 10)
    }

    fileprivate func eventLine(_ kind: String, id: Int, data: String = "\"job\":\"j-1\",\"category\":\"activity\"") -> String {
        #"{"v":1,"dir":"event","t":"\#(kind)","id":"\#(id)","ts":"2026-06-01T00:00:00.000Z","data":{\#(data)}}"#
    }

    private static let classicCapabilities = ["state", "activity", "await", "current_activity", "quota"]

    // MARK: A2 — subscribe and capabilities (a feature is used only when advertised)

    func testSubscribeIncludesProgressWhenTheHelloAdvertisesIt() throws {
        let categories = try subscribedCategories(
            afterHello: helloWith(capabilities: Self.classicCapabilities + ["progress", "answer.option", "ack"]))
        XCTAssertTrue(categories.contains("progress"), "\(categories)")
        for classic in Self.classicCapabilities {
            XCTAssertTrue(categories.contains(classic), "\(classic) missing from \(categories)")
        }
    }

    func testSubscribeLeavesProgressOutWhenTheHelloAdvertisesOnlyTheClassicFive() throws {
        let categories = try subscribedCategories(afterHello: helloWith(capabilities: Self.classicCapabilities))
        XCTAssertFalse(categories.contains("progress"), "\(categories)")
        XCTAssertEqual(Set(categories), Set(Self.classicCapabilities))
    }

    func testSubscribeLeavesProgressOutForAnUnknownBrokerWithNoCapabilities() throws {
        let categories = try subscribedCategories(afterHello: helloWith(capabilities: []))
        XCTAssertFalse(categories.contains("progress"), "\(categories)")
        XCTAssertFalse(categories.isEmpty, "an unknown broker still gets the classic categories")
    }

    func testCapabilityAccessorsReflectTheHello() throws {
        XCTAssertFalse(client.supportsProgress)
        XCTAssertFalse(client.supportsAnswerOption)
        XCTAssertFalse(client.supportsAck)

        _ = try subscribeCommand(afterHello: helloWith(capabilities: Self.classicCapabilities + ["progress", "answer.option", "ack"]))

        XCTAssertTrue(client.supportsProgress)
        XCTAssertTrue(client.supportsAnswerOption)
        XCTAssertTrue(client.supportsAck)
    }

    func testCapabilityAccessorsAreFalseWhenTheHelloAdvertisesOnlyTheClassicFive() throws {
        _ = try subscribeCommand(afterHello: helloWith(capabilities: Self.classicCapabilities))

        XCTAssertFalse(client.supportsProgress)
        XCTAssertFalse(client.supportsAnswerOption)
        XCTAssertFalse(client.supportsAck)
    }

    func testEachCapabilityAccessorFollowsItsOwnCapabilityOnly() throws {
        _ = try subscribeCommand(afterHello: helloWith(capabilities: ["state", "ack"]))

        XCTAssertTrue(client.supportsAck)
        XCTAssertFalse(client.supportsProgress)
        XCTAssertFalse(client.supportsAnswerOption)
    }

    // MARK: A3 — progress_updated on the wire

    func testProgressUpdatedEventArrivesAsAProgressEventForItsJob() throws {
        var seen: [BrokerEvent] = []
        let exp = XCTestExpectation(description: "progress event")
        client.events.sink { event in
            seen.append(event)
            if case .progress = event { exp.fulfill() }
        }.store(in: &cancellables)

        try performHandshake()
        serverWrite(#"""
        {"v":1,"dir":"event","t":"progress_updated","id":"6","ts":"2026-10-17T12:00:00.900Z","data":{"v":1,"pct":70,"label":"Checking","stage":"gates","signals":{"stage":"gates","checklist":null,"gates":{"passed":1,"failed":1,"total":3},"elapsed_active_s":480,"cost":1.4},"eta":{"lo_s":120,"hi_s":480,"label":"2-8 min","basis":"fleet"},"paused":false,"flags":[],"updated_at":"2026-10-17T12:00:00.000Z","job":"j-gates1","category":"progress"}}
        """#)
        wait(for: [exp], timeout: 10)

        let progressEvent = try XCTUnwrap(seen.first { if case .progress = $0 { return true } else { return false } })
        guard case .progress(let jobId, let progress) = progressEvent else { return XCTFail("expected .progress") }
        XCTAssertEqual(jobId, "j-gates1")
        XCTAssertEqual(progress.pct, 70)
        XCTAssertEqual(progress.label, "Checking")
        XCTAssertEqual(progress.stage, "gates")
        XCTAssertEqual(progress.signals?.gates, MotherGateSignal(passed: 1, failed: 1, total: 3))
        XCTAssertEqual(progress.eta?.label, "2-8 min")
        XCTAssertEqual(progress.updatedAt, "2026-10-17T12:00:00.000Z")
        // It is an overlay, not a state or crew change: the one line produced exactly one event.
        XCTAssertEqual(seen.compactMap(mc2Describe), ["progress:j-gates1"])
    }

    // MARK: A4 — crew events versus state events

    func testEveryCrewEventKindArrivesAsCrewChangedAndStateKindsStayStateChanges() throws {
        let crewKinds = [
            "gates_started", "gate_result", "gate_fix_started", "gates_completed", "gates_exhausted",
            "pr_marked_ready", "review_cycle_started", "lens_skipped", "reviewed", "claims_verified",
            "review_wave_completed", "decision_opened", "decision_resolved", "attention_raised",
            "attention_acked", "criterion_checked",
        ]
        let stateKinds = ["running", "awaiting_input", "ready"]
        let total = crewKinds.count + stateKinds.count

        var seen: [String] = []
        let exp = XCTestExpectation(description: "all \(total) events delivered")
        client.events.sink { event in
            guard let word = mc2Describe(event) else { return }
            seen.append(word)
            if seen.count == total { exp.fulfill() }
        }.store(in: &cancellables)

        try performHandshake()
        var id = 100
        for kind in crewKinds {
            id += 1
            serverWrite(eventLine(kind, id: id))
        }
        for kind in stateKinds {
            id += 1
            serverWrite(eventLine(kind, id: id, data: "\"job\":\"j-1\",\"category\":\"state\""))
        }
        wait(for: [exp], timeout: 10)

        XCTAssertEqual(seen, crewKinds.map { _ in "crew:j-1" } + stateKinds.map { "state:\($0):j-1" })
    }

    // MARK: A5 — query.get

    private static let holdJobJSON = """
        {"id":"j-hold1","state":"awaiting","repo":"Carefeed/payments","isolation":"worktree","title":"Backfill invoice totals",
        "created_at":"2026-10-17T11:10:00.000Z","started_at":"2026-10-17T11:11:20.000Z","finished_at":null,
        "question":"Gate attempts are exhausted","paused_reason":"gate_hold","activity":"gate_hold","crew":{"mode":"enforce"},
        "gates":{"status":"exhausted","attempt":3,"max_attempts":3,
          "results":[{"name":"unit","result":"failed","blocking":true,"duration_s":201,"exit_code":1}],"not_run":[]},
        "decision":{"id":"d-0001","kind":"gate_hold","options":[
          {"id":"resume_with_guidance","label":"Resume with guidance","consequence":"Worker resumes.","takes_text":true},
          {"id":"cancel","label":"Cancel","consequence":"Stop the job.","takes_text":false}],
          "opened_at":"2026-10-17T12:00:02.000Z","resolved_at":null},
        "attention":[{"reason":"decision_awaiting","since":"2026-10-17T12:00:02.000Z"}]}
        """

    /// An ack is one NDJSON line: no newline may survive inside the job.
    private static var holdJobOneLine: String { holdJobJSON.replacingOccurrences(of: "\n", with: "") }

    func testQueryGetSendsTheJobAndDecodesTheAcksJobWithItsCrewData() throws {
        try performHandshake()
        waitUntilConnected()

        let exp = XCTestExpectation(description: "query.get completion")
        var result: Result<MotherJob, BrokerError>?
        client.queryGet(job: "j-hold1") { result = $0; exp.fulfill() }

        let cmd = try readCommandObject()
        XCTAssertEqual(cmd["t"] as? String, "query.get")
        XCTAssertEqual(cmd["dir"] as? String, "cmd")
        XCTAssertEqual((cmd["data"] as? [String: Any])?["job"] as? String, "j-hold1")
        let cmdId = try XCTUnwrap(cmd["id"] as? String)

        serverWrite("""
        {"v":1,"dir":"ack","t":"query.get","id":"\(cmdId)","ts":"2026-10-17T12:00:03.000Z","data":{"ok":true,"job":\(Self.holdJobOneLine)}}
        """)
        wait(for: [exp], timeout: 10)

        let outcome = try XCTUnwrap(result, "query.get never completed")
        guard case .success(let job) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(job.id, "j-hold1")
        XCTAssertEqual(job.state, "awaiting")
        XCTAssertEqual(job.crew.activity, "gate_hold")
        XCTAssertEqual(job.crew.gates?.status, "exhausted")
        XCTAssertEqual(job.crew.decision?.options.map(\.label), ["Resume with guidance", "Cancel"])
        XCTAssertEqual(job.crew.attention.map(\.reason), [.decisionAwaiting])
        XCTAssertNotNil(job.holdSummary)
    }

    func testQueryGetFailsWhenTheAckIsAnError() throws {
        try performHandshake()
        waitUntilConnected()

        let exp = XCTestExpectation(description: "query.get completion")
        var result: Result<MotherJob, BrokerError>?
        client.queryGet(job: "gone") { result = $0; exp.fulfill() }

        let cmdId = try XCTUnwrap(try readCommandObject()["id"] as? String)
        serverWrite("""
        {"v":1,"dir":"ack","t":"query.get","id":"\(cmdId)","ts":"2026-10-17T12:00:03.000Z","data":{"ok":false,"error":{"code":"no_such_job","message":"job gone not found"}}}
        """)
        wait(for: [exp], timeout: 10)

        let outcome = try XCTUnwrap(result, "query.get never completed")
        guard case .failure(let error) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        guard case .code(let code, _) = error else { return XCTFail("expected a coded error, got \(error)") }
        XCTAssertEqual(code, .noSuchJob)
    }

    func testQueryGetFailsWhenAnOkAckCarriesNoReadableJob() throws {
        try performHandshake()
        waitUntilConnected()

        let exp = XCTestExpectation(description: "query.get completion")
        var result: Result<MotherJob, BrokerError>?
        client.queryGet(job: "j-1") { result = $0; exp.fulfill() }

        let cmdId = try XCTUnwrap(try readCommandObject()["id"] as? String)
        serverWrite("""
        {"v":1,"dir":"ack","t":"query.get","id":"\(cmdId)","ts":"2026-10-17T12:00:03.000Z","data":{"ok":true}}
        """)
        wait(for: [exp], timeout: 10)

        let outcome = try XCTUnwrap(result, "query.get never completed")
        if case .success = outcome { XCTFail("a job-less ack must not read as a job") }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// A3 (cont.): the progress overlay's ordering rules.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2ProgressOverlayTests: XCTestCase {

    private let noon = "2026-10-17T12:00:00.000Z"
    private let earlier = "2026-10-17T11:59:00.000Z"
    private let later = "2026-10-17T12:01:00.000Z"

    private func job(pct: Int?, at stamp: String?) -> MotherJob {
        var crew = MotherCrewState()
        if let pct { crew.progress = mc2Progress(pct: pct, updatedAt: stamp) }
        return mc2Job(state: "running", crew: crew)
    }

    func testAnOlderOverlayIsIgnored() {
        var j = job(pct: 55, at: noon)
        let changed = j.applyProgress(mc2Progress(pct: 10, updatedAt: earlier))
        XCTAssertFalse(changed)
        XCTAssertEqual(j.crew.progress?.pct, 55)
    }

    func testANewerOverlayIsApplied() {
        var j = job(pct: 55, at: noon)
        let changed = j.applyProgress(mc2Progress(pct: 70, updatedAt: later))
        XCTAssertTrue(changed)
        XCTAssertEqual(j.crew.progress?.pct, 70)
    }

    func testAnOverlayWithTheSameTimestampIsAppliedOnlyWhenItsContentDiffers() {
        var j = job(pct: 55, at: noon)
        XCTAssertFalse(j.applyProgress(mc2Progress(pct: 55, updatedAt: noon)), "identical overlay is not a change")
        XCTAssertTrue(j.applyProgress(mc2Progress(pct: 80, updatedAt: noon)), "same stamp, new content")
        XCTAssertEqual(j.crew.progress?.pct, 80)
    }

    func testTheFirstOverlayIsAppliedToAJobWithNone() {
        var j = job(pct: nil, at: nil)
        XCTAssertTrue(j.applyProgress(mc2Progress(pct: 20, updatedAt: earlier)))
        XCTAssertEqual(j.crew.progress?.pct, 20)
    }

    func testAnOverlayWithNoTimestampDoesNotReplaceAStampedOne() {
        var j = job(pct: 55, at: noon)
        XCTAssertFalse(j.applyProgress(mc2Progress(pct: 90, updatedAt: nil)))
        XCTAssertEqual(j.crew.progress?.pct, 55)
    }

    func testARefreshKeepsTheNewerOverlayAndTakesEverythingElseFromTheRefresh() {
        // An event raced the query.get: the job holds a progress newer than the refreshed one.
        let mine = job(pct: 70, at: later)
        var refreshed = mc2Job(state: "awaiting", crew: mc2Crew(pct: 55, decisionId: "d-0001"))
        refreshed.crew.progress = mc2Progress(pct: 55, updatedAt: noon)

        let merged = mine.replacing(with: refreshed)

        XCTAssertEqual(merged.crew.progress?.pct, 70, "the newer overlay survives the refresh")
        XCTAssertEqual(merged.state, "awaiting")
        XCTAssertEqual(merged.crew.decision?.id, "d-0001")
        XCTAssertEqual(merged.crew.gates?.results.count, 2)
    }

    func testARefreshWithANewerOverlayWins() {
        let mine = job(pct: 55, at: noon)
        let refreshed = job(pct: 90, at: later)
        XCTAssertEqual(mine.replacing(with: refreshed).crew.progress?.pct, 90)
    }

    func testARefreshWithNoOverlayKeepsTheOneTheJobHas() {
        let mine = job(pct: 55, at: noon)
        let refreshed = job(pct: nil, at: nil)
        XCTAssertEqual(mine.replacing(with: refreshed).crew.progress?.pct, 55)
    }

    func testARefreshOfAJobWithNoOverlayIsTheRefresh() {
        let mine = job(pct: nil, at: nil)
        let refreshed = job(pct: 40, at: noon)
        XCTAssertEqual(mine.replacing(with: refreshed), refreshed)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// A6: MotherJobRefresher — a burst of crew events is one query.get.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2JobRefresherTests: XCTestCase {

    private final class Probe {
        var fetched: [String] = []
        var applied: [String] = []
        var held: [(Result<MotherJob, BrokerError>) -> Void] = []
    }

    private enum Reply { case succeed, fail, hold }

    private func makeRefresher(_ probe: Probe, debounce: TimeInterval, reply: Reply) -> MotherJobRefresher {
        MotherJobRefresher(
            debounce: debounce,
            fetch: { job, done in
                probe.fetched.append(job)
                switch reply {
                case .succeed: done(.success(mc2Job(id: job)))
                case .fail:    done(.failure(.timeout))
                case .hold:    probe.held.append(done)
                }
            },
            apply: { probe.applied.append($0.id) }
        )
    }

    private func settle(_ seconds: TimeInterval) {
        let exp = expectation(description: "settle \(seconds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 10)
    }

    func testABurstOfRequestsInsideOneWindowIsOneFetch() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.1, reply: .succeed)

        for _ in 0..<5 { refresher.request(job: "j1") }
        settle(0.5)

        XCTAssertEqual(probe.fetched, ["j1"])
        XCTAssertEqual(probe.applied, ["j1"])
    }

    func testRequestsSpreadAcrossTheWindowAreStillOneFetch() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.3, reply: .succeed)

        for n in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015 * Double(n)) { refresher.request(job: "j1") }
        }
        settle(0.9)

        XCTAssertEqual(probe.fetched, ["j1"])
    }

    func testARequestWhileAFetchIsInFlightCausesExactlyOneMoreFetchAfterIt() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.05, reply: .hold)

        refresher.request(job: "j1")
        settle(0.3)
        XCTAssertEqual(probe.fetched, ["j1"], "the window closed and the fetch started")

        // Three more arrive while it is in flight: nothing new starts, and they collapse to one.
        refresher.request(job: "j1")
        refresher.request(job: "j1")
        refresher.request(job: "j1")
        settle(0.3)
        XCTAssertEqual(probe.fetched, ["j1"], "never two fetches in flight for one job")

        probe.held.removeFirst()(.success(mc2Job(id: "j1")))
        XCTAssertEqual(probe.applied, ["j1"])
        settle(0.4)
        XCTAssertEqual(probe.fetched, ["j1", "j1"], "exactly one follow-up fetch")

        probe.held.removeFirst()(.success(mc2Job(id: "j1")))
        settle(0.4)
        XCTAssertEqual(probe.fetched.count, 2, "nothing was left over to fetch a third time")
        XCTAssertEqual(probe.applied, ["j1", "j1"])
    }

    func testAFailedFetchAppliesNothing() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.05, reply: .fail)

        refresher.request(job: "j1")
        settle(0.4)

        XCTAssertEqual(probe.fetched, ["j1"])
        XCTAssertTrue(probe.applied.isEmpty, "a failed fetch keeps the job as it was")
    }

    func testCancelAllStopsPendingWindows() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.2, reply: .succeed)

        refresher.request(job: "j1")
        refresher.request(job: "j2")
        refresher.cancelAll()
        settle(0.6)

        XCTAssertTrue(probe.fetched.isEmpty)
        XCTAssertTrue(probe.applied.isEmpty)
    }

    func testCancelAllForgetsARequestThatArrivedDuringAFetch() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.05, reply: .hold)

        refresher.request(job: "j1")
        settle(0.3)
        refresher.request(job: "j1")      // remembered while in flight ...
        refresher.cancelAll()             // ... and forgotten: the connection dropped
        probe.held.removeFirst()(.success(mc2Job(id: "j1")))
        settle(0.4)

        XCTAssertEqual(probe.fetched, ["j1"], "no follow-up after cancelAll")
    }

    func testEachJobGetsItsOwnFetch() {
        let probe = Probe()
        let refresher = makeRefresher(probe, debounce: 0.05, reply: .succeed)

        refresher.request(job: "a")
        refresher.request(job: "b")
        refresher.request(job: "a")
        settle(0.4)

        XCTAssertEqual(probe.fetched.sorted(), ["a", "b"])
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// A7: the counts strip's numbers.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2StatusCountsTests: XCTestCase {

    private func attention(_ reason: MotherAttentionReason, acked: Bool = false) -> MotherAttention {
        MotherAttention(reason: reason, since: "2026-10-17T12:00:02.000Z", acked: acked)
    }

    private func heldJob(id: String, attention: [MotherAttention]) -> MotherJob {
        mc2Job(id: id, state: "awaiting", crew: MotherCrewState(
            optedIn: true, activity: "gate_hold", decision: mc2Decision(), attention: attention))
    }

    func testAHeldJobWithAnUnackedDecisionFlagNeedsYouOnceNotTwice() {
        let held = heldJob(id: "held", attention: [attention(.decisionAwaiting)])

        let status = MotherStatus.from(jobs: [held])

        XCTAssertEqual(status.needsYou, 1)
        XCTAssertEqual(status.awaiting, 1)
        XCTAssertEqual(status.stalled, 0)
        XCTAssertEqual(status.burning, 0)
    }

    func testAHeldJobNeedsYouEvenWithoutAnAttentionFlag() {
        XCTAssertEqual(MotherStatus.from(jobs: [heldJob(id: "held", attention: [])]).needsYou, 1)
    }

    func testAnUnackedDecisionFlagAloneNeedsYou() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [attention(.decisionAwaiting)]))
        XCTAssertEqual(MotherStatus.from(jobs: [job]).needsYou, 1)
    }

    func testAnUnackedStalledFlagCountsAsStalledOnly() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [attention(.progressStalled)]))

        let status = MotherStatus.from(jobs: [job])

        XCTAssertEqual(status.stalled, 1)
        XCTAssertEqual(status.burning, 0)
        XCTAssertEqual(status.needsYou, 0)
        XCTAssertEqual(status.running, 1)
    }

    func testAnUnackedBurnAheadFlagCountsAsBurningOnly() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [attention(.burnAhead)]))

        let status = MotherStatus.from(jobs: [job])

        XCTAssertEqual(status.burning, 1)
        XCTAssertEqual(status.stalled, 0)
        XCTAssertEqual(status.needsYou, 0)
    }

    func testAJobWithBothStalledAndBurningCountsInEach() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [attention(.progressStalled), attention(.burnAhead)]))
        let status = MotherStatus.from(jobs: [job])
        XCTAssertEqual(status.stalled, 1)
        XCTAssertEqual(status.burning, 1)
    }

    func testAcknowledgedFlagsCountNothing() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [
            attention(.progressStalled, acked: true),
            attention(.burnAhead, acked: true),
            attention(.decisionAwaiting, acked: true),
            attention(.gatesIncomplete, acked: true),
        ]))

        let status = MotherStatus.from(jobs: [job])

        XCTAssertEqual(status.stalled, 0)
        XCTAssertEqual(status.burning, 0)
        XCTAssertEqual(status.needsYou, 0)
    }

    func testAnUnackedGatesIncompleteFlagNeedsYou() {
        let job = mc2Job(state: "running", crew: MotherCrewState(attention: [attention(.gatesIncomplete)]))
        XCTAssertEqual(MotherStatus.from(jobs: [job]).needsYou, 1)
    }

    func testAJobInATerminalStateCountsNothingWhateverFlagsItStillCarries() {
        let flags = [attention(.decisionAwaiting), attention(.progressStalled), attention(.burnAhead)]
        for state in ["succeeded", "failed", "cancelled"] {
            let job = mc2Job(state: state, crew: MotherCrewState(activity: "gate_hold", decision: mc2Decision(), attention: flags))
            let status = MotherStatus.from(jobs: [job])
            XCTAssertEqual(status.needsYou, 0, state)
            XCTAssertEqual(status.stalled, 0, state)
            XCTAssertEqual(status.burning, 0, state)
        }
        // The plain state counts are unchanged by the new ones.
        let failed = mc2Job(state: "failed", crew: MotherCrewState(attention: flags))
        XCTAssertEqual(MotherStatus.from(jobs: [failed]).failed, 1)
    }

    func testEachJobCountsOnceAcrossAMixedList() {
        let jobs = [
            heldJob(id: "a", attention: [attention(.decisionAwaiting)]),
            heldJob(id: "b", attention: [attention(.decisionAwaiting)]),
            mc2Job(id: "c", state: "running", crew: MotherCrewState(attention: [attention(.progressStalled)])),
            mc2Job(id: "d", state: "running", crew: MotherCrewState(attention: [attention(.burnAhead, acked: true)])),
            mc2Job(id: "e", state: "queued"),
        ]
        let status = MotherStatus.from(jobs: jobs)
        XCTAssertEqual(status.needsYou, 2)
        XCTAssertEqual(status.stalled, 1)
        XCTAssertEqual(status.burning, 0)
        XCTAssertEqual(status.running, 2)
        XCTAssertEqual(status.awaiting, 2)
        XCTAssertEqual(status.queued, 1)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// B, C: MotherJobDetail inside a window — what must keep still, and what must change.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2JobDetailNoChurnTests: XCTestCase {

    private var host: MC2StubHost!
    private var detail: MotherJobDetail!
    private var window: NSWindow!
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc2-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        host = MC2StubHost()
        detail = MotherJobDetail(host: host, logDirectory: tmp, frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = detail
        detail.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        detail?.select(nil)            // stops the log timer
        window?.contentView = nil
        window?.close()
        detail = nil
        window = nil
        host = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    // MARK: Helpers

    private func layout() { detail.layoutSubtreeIfNeeded() }

    private func awaitingJob(pct: Int = 50, unit: MotherGateResult = .unknown("running"), gateCount: Int = 2,
                             acked: Bool = false, eta: String = "5-15 min", decisionId: String? = "d-0001") -> MotherJob {
        mc2Job(id: "j-await", state: "awaiting",
               crew: mc2Crew(pct: pct, unitResult: unit, gateCount: gateCount, acked: acked, etaLabel: eta, decisionId: decisionId))
    }

    private func assertSameViews(_ a: [NSView], _ b: [NSView], _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertTrue(x === y, message, file: file, line: line) }
    }

    /// Type a draft into the reply box with focus and a selection in the middle of it.
    private func typeDraft(_ text: String = "half an answer", selection: NSRange = NSRange(location: 5, length: 3)) {
        XCTAssertTrue(window.makeFirstResponder(detail.replyTextView), "the reply box must be able to take focus")
        detail.replyTextView.string = text
        detail.replyTextView.selectedRange = selection
    }

    private func topEdge(of view: NSView) -> CGFloat { detail.isFlipped ? view.frame.minY : view.frame.maxY }

    // MARK: B1 — a stream of updates leaves the reader's place alone

    func testTwentyUpdatesKeepTheDraftSelectionFocusAndActionStack() throws {
        detail.select(awaitingJob())
        layout()
        typeDraft()
        let stack = try XCTUnwrap(detail.actionStack, "an awaiting job has actions")
        let containerViews = detail.actionsContainer.subviews
        let selection = detail.replyTextView.selectedRange

        let words: [MotherGateResult] = [.unknown("running"), .passed, .failed]
        for i in 1...20 {
            detail.update(awaitingJob(pct: 50 + i, unit: words[i % 3], gateCount: i < 10 ? 2 : 3, acked: i % 2 == 0,
                                      eta: i % 2 == 0 ? "5-15 min" : "2-8 min"))
            layout()
        }

        XCTAssertEqual(detail.replyTextView.string, "half an answer", "an update must not clear the draft")
        XCTAssertEqual(detail.replyTextView.selectedRange, selection, "or move its selection")
        XCTAssertTrue(window.firstResponder === detail.replyTextView, "or take focus away from it")
        XCTAssertTrue(detail.actionStack === stack, "the action stack is not rebuilt by a progress tick")
        assertSameViews(detail.actionsContainer.subviews, containerViews, "the actions container's views are untouched")
    }

    func testAnUpdateWithNothingNewChangesNothing() throws {
        let job = awaitingJob()
        detail.select(job)
        layout()
        typeDraft()
        let stack = try XCTUnwrap(detail.actionStack)

        for _ in 0..<5 { detail.update(job) }

        XCTAssertTrue(detail.actionStack === stack)
        XCTAssertEqual(detail.replyTextView.string, "half an answer")
    }

    // MARK: B2 — what does rebuild the actions

    func testAStateChangeRebuildsTheActionsAndClearsTheDraft() throws {
        detail.select(awaitingJob())
        layout()
        typeDraft()
        let stack = try XCTUnwrap(detail.actionStack)

        detail.update(mc2Job(id: "j-await", state: "running", crew: mc2Crew(decisionId: nil, activity: nil)))
        layout()

        let rebuilt = try XCTUnwrap(detail.actionStack)
        XCTAssertFalse(rebuilt === stack, "awaiting -> running reshapes the actions")
        XCTAssertEqual(detail.replyTextView.string, "", "a draft written for the awaiting state does not outlive it")
    }

    func testANewDecisionRebuildsTheActions() throws {
        detail.select(awaitingJob(decisionId: "d-0001"))
        layout()
        let stack = try XCTUnwrap(detail.actionStack)

        detail.update(awaitingJob(decisionId: "d-0002"))
        layout()

        XCTAssertFalse(try XCTUnwrap(detail.actionStack) === stack)
    }

    func testTheBrokerDroppingAndReturningRebuildsTheActionsEachTime() throws {
        detail.select(awaitingJob())
        layout()
        let first = try XCTUnwrap(detail.actionStack)

        host.connectedSubject.send(false)
        detail.update(awaitingJob(pct: 51))
        layout()
        let offline = try XCTUnwrap(detail.actionStack)
        XCTAssertFalse(offline === first, "offline reshapes the actions (banner, disabled buttons)")

        host.connectedSubject.send(true)
        detail.update(awaitingJob(pct: 52))
        layout()
        XCTAssertFalse(try XCTUnwrap(detail.actionStack) === offline, "coming back reshapes them again")
    }

    func testARebuildWhileTheReplyBoxHasFocusPutsFocusAndTheDraftBack() throws {
        detail.select(awaitingJob())
        layout()
        typeDraft("keep me", selection: NSRange(location: 2, length: 4))
        let stack = try XCTUnwrap(detail.actionStack)

        host.connectedSubject.send(false)
        detail.update(awaitingJob(pct: 51))
        layout()

        XCTAssertFalse(try XCTUnwrap(detail.actionStack) === stack, "precondition: the stack was rebuilt")
        XCTAssertTrue(window.firstResponder === detail.replyTextView, "the reply box has focus again")
        XCTAssertEqual(detail.replyTextView.string, "keep me")

        host.connectedSubject.send(true)
        detail.update(awaitingJob(pct: 52))
        layout()
        XCTAssertTrue(window.firstResponder === detail.replyTextView)
        XCTAssertEqual(detail.replyTextView.string, "keep me")
    }

    // MARK: B3 — the log keeps the reader's place

    /// 200 stream-json lines: exactly the tail the detail loads from `<id>.log`. Loading the file first
    /// (and waiting for it) keeps the detail's own background read from landing in the middle of a test.
    private func loadInitialLog() throws -> String {
        let initial = mc2StreamLog(100..<300)
        try initial.write(to: tmp.appendingPathComponent("j-log.log"), atomically: true, encoding: .utf8)
        detail.select(mc2Job(id: "j-log", state: "succeeded"))
        layout()
        XCTAssertTrue(mc2WaitUntil { self.detail.logTextView.string.contains("line 299") }, "the log never loaded")
        settleLog()
        return initial
    }

    private func logJob(pct: Int) -> MotherJob {
        mc2Job(id: "j-log", state: "succeeded", crew: mc2Crew(pct: pct, decisionId: nil, activity: nil))
    }

    /// Show the crew section before the reader scrolls anywhere, so no later update has to make room for it.
    private func showCrewSection() {
        detail.update(logJob(pct: 1))
        settleLog()
    }

    private func settleLog() {
        layout()
        if let container = detail.logTextView.textContainer { detail.logTextView.layoutManager?.ensureLayout(for: container) }
        layout()
    }

    private var logClip: NSClipView { detail.logScrollView.contentView }
    private var logDocumentHeight: CGFloat { detail.logScrollView.documentView?.frame.height ?? 0 }

    private func scrollLog(toY y: CGFloat) {
        logClip.scroll(to: NSPoint(x: 0, y: y))
        detail.logScrollView.reflectScrolledClipView(logClip)
    }

    func testTheFirstLoadFollowsTheTailOfTheLog() throws {
        _ = try loadInitialLog()

        XCTAssertGreaterThan(logDocumentHeight, logClip.bounds.height, "the log must be long enough to scroll")
        XCTAssertLessThanOrEqual(logDocumentHeight - logClip.bounds.maxY, 4, "a fresh log shows its newest lines")
    }

    func testALogScrolledUpStaysExactlyWhereItWasAsLinesAndUpdatesArrive() throws {
        let initial = try loadInitialLog()
        showCrewSection()
        scrollLog(toY: 600)
        let saved = logClip.bounds.origin
        XCTAssertEqual(saved.y, 600, accuracy: 1, "precondition: the log is scrolled up")
        XCTAssertGreaterThan(logDocumentHeight - logClip.bounds.maxY, 100, "precondition: well away from the bottom")
        XCTAssertTrue(initial.contains("line 299"))

        for i in 1...5 {
            let newest = 300 + 10 * i
            detail.setLogAttributed(mc2StreamLog(100..<newest))     // what the 2 s timer does
            detail.update(logJob(pct: 1 + i))
            settleLog()

            XCTAssertTrue(detail.logTextView.string.contains("line \(newest - 1)"), "precondition: the new lines were shown")
            XCTAssertEqual(logClip.bounds.origin.y, saved.y, accuracy: 1, "round \(i): the visible position moved")
            XCTAssertEqual(logClip.bounds.origin.x, saved.x, accuracy: 1)
        }
    }

    func testALogScrolledToTheBottomKeepsFollowingNewLines() throws {
        _ = try loadInitialLog()
        showCrewSection()
        scrollLog(toY: max(0, logDocumentHeight - logClip.bounds.height))
        XCTAssertLessThanOrEqual(logDocumentHeight - logClip.bounds.maxY, 4, "precondition: at the bottom")
        let heightBefore = logDocumentHeight
        let originBefore = logClip.bounds.origin.y

        detail.setLogAttributed(mc2StreamLog(100..<330))
        settleLog()

        XCTAssertGreaterThan(logDocumentHeight, heightBefore, "precondition: the log grew")
        XCTAssertGreaterThan(logClip.bounds.origin.y, originBefore, "the view followed the new lines down")
        XCTAssertLessThanOrEqual(logDocumentHeight - logClip.bounds.maxY, 4, "and is still at the end")
    }

    func testIdenticalLogTextIsNotRewrittenAndNewTextIs() throws {
        let initial = try loadInitialLog()
        showCrewSection()
        guard let storage = detail.logTextView.textStorage else { return XCTFail("no text storage") }
        var edits = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for _ in 0..<5 {
            detail.setLogAttributed(initial)
            detail.update(logJob(pct: 2))
        }
        XCTAssertEqual(edits, 0, "the same text must leave the text view alone")

        detail.setLogAttributed(initial + "\n" + mc2StreamLine(300))
        XCTAssertGreaterThan(edits, 0, "different text is shown")
    }

    // MARK: B4 — the crew section's frame

    func testAJobWithNoCrewDataHasAHiddenZeroHeightSection() {
        detail.select(mc2Job())
        layout()

        XCTAssertTrue(detail.crewSection.isHidden)
        XCTAssertEqual(detail.crewSection.frame.height, 0)
    }

    func testTheFirstCrewDataChangesTheSectionHeightOnceAndValueChangesNeverMoveIt() throws {
        func runningJob(pct: Int, unit: MotherGateResult, acked: Bool, eta: String) -> MotherJob {
            mc2Job(id: "j-crew", state: "running", crew: mc2Crew(pct: pct, unitResult: unit, acked: acked, etaLabel: eta,
                                                                   decisionId: nil, activity: nil))
        }
        detail.select(mc2Job(id: "j-crew", state: "running"))
        layout()
        var heights = [detail.crewSection.frame.height]
        XCTAssertEqual(heights[0], 0)

        // First crew data.
        let first = runningJob(pct: 50, unit: .unknown("running"), acked: false, eta: "5-15 min")
        detail.update(first)
        layout()
        let expected = MotherCrewPanelModel.make(job: first.kitJob).height(breakdownExpanded: false)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertFalse(detail.crewSection.isHidden)
        XCTAssertEqual(detail.crewSection.expectedHeight, expected)
        XCTAssertEqual(detail.crewSection.frame.height, expected, "the section is exactly the model's height")
        heights.append(detail.crewSection.frame.height)
        let settledFrame = detail.crewSection.frame

        // Twenty value changes inside the same rows.
        let words: [MotherGateResult] = [.unknown("running"), .passed, .failed]
        for i in 1...20 {
            detail.update(runningJob(pct: 50 + i, unit: words[i % 3], acked: i % 2 == 0,
                                     eta: i % 2 == 0 ? "5-15 min" : "under 2 min"))
            layout()
            XCTAssertEqual(detail.crewSection.frame, settledFrame, "update \(i) moved or resized the crew section")
            heights.append(detail.crewSection.frame.height)
        }
        XCTAssertEqual(Set(heights), [0, expected], "the height changed exactly once, from 0 to the model's height")
    }

    func testAnAddedGateRowGrowsTheSectionByExactlyOneRow() {
        func runningJob(gates: Int) -> MotherJob {
            mc2Job(id: "j-crew", state: "running", crew: mc2Crew(gateCount: gates, decisionId: nil, activity: nil))
        }
        detail.select(runningJob(gates: 2))
        layout()
        let before = detail.crewSection.frame
        let topBefore = topEdge(of: detail.crewSection)

        detail.update(runningJob(gates: 3))
        layout()
        let after = detail.crewSection.frame

        XCTAssertEqual(after.height - before.height, MotherCrewPanelMetrics.row, accuracy: 0.01, "one more row, one row taller")
        XCTAssertEqual(after.width, before.width, accuracy: 0.01)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.01)
        XCTAssertEqual(topEdge(of: detail.crewSection), topBefore, accuracy: 0.01, "the section grows from its top edge")
    }

    // MARK: B5 — selecting

    func testSelectingAnotherJobClearsTheDraft() {
        detail.select(awaitingJob())
        layout()
        typeDraft()

        detail.select(mc2Job(id: "other", state: "awaiting"))

        XCTAssertEqual(detail.replyTextView.string, "")
        XCTAssertEqual(detail.currentJobId, "other")
    }

    func testSelectingNothingShowsTheEmptyStateWithAZeroHeightCrewSection() throws {
        detail.select(awaitingJob())
        layout()
        XCTAssertFalse(detail.crewSection.isHidden)

        detail.select(nil)
        layout()

        XCTAssertNil(detail.currentJobId)
        XCTAssertNil(detail.currentJob)
        let hint = try XCTUnwrap(mc2AllSubviews(detail).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Select a job" })
        XCTAssertFalse(hint.isHidden, "the empty hint is showing")
        XCTAssertTrue(detail.crewSection.isHidden)
        XCTAssertEqual(detail.crewSection.frame.height, 0)
        XCTAssertTrue(detail.actionsContainer.isHidden)
        XCTAssertTrue(detail.logScrollView.isHidden)
    }

    func testUpdatingWithNilBehavesAsSelectingNothing() {
        detail.select(awaitingJob())
        layout()
        typeDraft()

        detail.update(nil)
        layout()

        XCTAssertNil(detail.currentJobId)
        XCTAssertEqual(detail.replyTextView.string, "")
        XCTAssertTrue(detail.crewSection.isHidden)
        XCTAssertEqual(detail.crewSection.frame.height, 0)
    }

    func testUpdatingWithADifferentJobBehavesAsSelectingIt() throws {
        detail.select(awaitingJob())
        layout()
        typeDraft()
        let stack = try XCTUnwrap(detail.actionStack)

        detail.update(mc2Job(id: "other", state: "awaiting", title: "Other job"))
        layout()

        XCTAssertEqual(detail.currentJobId, "other")
        XCTAssertEqual(detail.replyTextView.string, "", "a different job starts from a clean slate")
        XCTAssertFalse(try XCTUnwrap(detail.actionStack) === stack)
        XCTAssertTrue(detail.crewSection.isHidden, "the other job has no crew data")
        XCTAssertEqual(detail.crewSection.frame.height, 0)
    }

    // MARK: B6 — the plan checklist reloads only when the plan changes

    private func checklistRows() -> [NSView]? {
        guard let list = mc2AllSubviews(detail).first(where: { NSStringFromClass(type(of: $0)).contains("PlanChecklistView") }),
              let stack = list.subviews.compactMap({ $0 as? NSStackView }).first
        else { return nil }
        return stack.arrangedSubviews
    }

    func testUpdatesLeaveThePlanChecklistAloneUnlessThePlanPathChanged() throws {
        let planA = tmp.appendingPathComponent("a.md")
        let planB = tmp.appendingPathComponent("b.md")
        try "- [ ] first\n- [x] second\n".write(to: planA, atomically: true, encoding: .utf8)
        try "- [ ] only one\n".write(to: planB, atomically: true, encoding: .utf8)

        func job(plan: String, pct: Int) -> MotherJob {
            mc2Job(id: "j-plan", state: "succeeded", planPath: plan, crew: mc2Crew(pct: pct, decisionId: nil, activity: nil))
        }
        detail.select(job(plan: planA.path, pct: 1))
        layout()
        XCTAssertTrue(mc2WaitUntil { self.checklistRows()?.count == 2 }, "the plan's two items never appeared")
        let rows = try XCTUnwrap(checklistRows())

        // The file changes on disk, but the plan path does not: no reason to read it again.
        try "- [ ] first\n- [x] second\n- [ ] third\n".write(to: planA, atomically: true, encoding: .utf8)
        for i in 2...12 { detail.update(job(plan: planA.path, pct: i)) }
        mc2Spin(0.4)
        assertSameViews(try XCTUnwrap(checklistRows()), rows, "the checklist rows are the same views")

        // A new plan path is read.
        detail.update(job(plan: planB.path, pct: 13))
        XCTAssertTrue(mc2WaitUntil { self.checklistRows()?.count == 1 }, "a different plan was not loaded")
    }

    // MARK: C — MC2-5: a gate hold

    func testAGateHoldShowsMothersOptionsInOrderAndKeepsTheFreeTextAnswer() throws {
        let hold = mc2Job(id: "j-hold1", state: "awaiting", question: "Gate attempts are exhausted (3 of 3).",
                          crew: mc2Crew(unitResult: .failed, decisionId: "d-0001", activity: "gate_hold"))
        detail.select(hold)
        layout()

        let summary = try XCTUnwrap(detail.crewSection.model.hold, "a gate hold is shown")
        XCTAssertEqual(summary.kind, "Gates exhausted")
        XCTAssertEqual(summary.options.map(\.label), ["Resume with guidance", "Escalate", "Override and open", "Cancel"])
        XCTAssertEqual(summary.options.map(\.consequence), [
            "Worker resumes in the same session with your note; gates re-run.",
            "Re-run one tier up.",
            "Mark the PR ready with red gates recorded as overridden.",
            "Stop the job.",
        ])

        // The existing free-text Answer still goes to the host, by the job's id.
        let answer = try XCTUnwrap(mc2AllSubviews(detail).compactMap { $0 as? NSButton }.first { $0.title == "Answer" },
                                   "an awaiting job still has an Answer button")
        detail.replyTextView.string = "  Fix the seed, do not touch the totals query.  "
        answer.performClick(nil)

        XCTAssertEqual(host.answers.count, 1)
        XCTAssertEqual(host.answers.first?.id, "j-hold1")
        XCTAssertEqual(host.answers.first?.text, "Fix the seed, do not touch the totals query.")
        XCTAssertEqual(detail.replyTextView.string, "", "a sent answer clears the box")
    }

    func testAnEmptyAnswerIsNotSent() throws {
        detail.select(mc2Job(id: "j-hold1", state: "awaiting", crew: mc2Crew(decisionId: "d-0001", activity: "gate_hold")))
        layout()
        let answer = try XCTUnwrap(mc2AllSubviews(detail).compactMap { $0 as? NSButton }.first { $0.title == "Answer" })

        detail.replyTextView.string = "   \n "
        answer.performClick(nil)

        XCTAssertTrue(host.answers.isEmpty)
    }

    // MARK: F (part) — a broker that is not Mother's own offers no Details

    func testDetailsStayClosedWhenTheBrokerIsNotMothersOwn() {
        host.usesDefaultBroker = false
        detail.select(mc2Job(id: "j-qa", state: "running", crew: mc2Crew(decisionId: nil, activity: nil)))
        layout()
        XCTAssertFalse(detail.crewSection.model.isEmpty, "the panel itself still shows the crew data")

        detail.showDetails()

        XCTAssertNil(window.attachedSheet, "no sheet opens: the mother CLI does not know this broker's jobs")
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// D: the counts strip does not move when a count changes.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2CountsChipsTests: XCTestCase {

    private var chips: MotherCountsChips!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        chips = MotherCountsChips(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = chips
        chips.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        window?.contentView = nil
        window?.close()
        chips = nil
        window = nil
        super.tearDown()
    }

    private func frames(after status: MotherStatus) -> [String: NSRect] {
        chips.render(status)
        chips.layoutSubtreeIfNeeded()
        return chips.chipFrames
    }

    private func label(_ chip: String) -> String? { chips.chipAccessibilityLabels[chip] ?? nil }

    func testNoChipMovesWhenNeedsYouStalledBurningOrRunningChange() {
        let base = MotherStatus(running: 3, queued: 1, failed: 0, awaiting: 1, succeeded: 2)
        let baseline = frames(after: base)
        XCTAssertEqual(baseline.count, 8, "five state chips and three crew chips")

        var needsYou = base; needsYou.needsYou = 1
        XCTAssertEqual(frames(after: needsYou), baseline, "needs you 0 -> 1")

        var stalled = needsYou; stalled.stalled = 1
        XCTAssertEqual(frames(after: stalled), baseline, "stalled 0 -> 1")

        var burning = stalled; burning.burning = 1
        XCTAssertEqual(frames(after: burning), baseline, "burning 0 -> 1")

        var running = burning; running.running = 4
        XCTAssertEqual(frames(after: running), baseline, "running 3 -> 4")

        XCTAssertEqual(frames(after: base), baseline, "and everything back to zero")
    }

    func testChipsKeepTheirPlaceFromAnEmptyStripToAFullOne() {
        let baseline = frames(after: MotherStatus())
        let full = MotherStatus(running: 1, queued: 2, failed: 3, awaiting: 4, succeeded: 5, needsYou: 6, stalled: 7, burning: 8)
        XCTAssertEqual(frames(after: full), baseline)
    }

    func testVisibleChipsReadAsOneCombinedLabelAndHiddenCrewChipsReadAsNothing() {
        chips.render(MotherStatus(running: 3, needsYou: 1))

        XCTAssertEqual(label("Running"), "3 running")
        XCTAssertEqual(label("Needs you"), "1 needs you")
        XCTAssertEqual(label("Queued"), "0 queued", "a state chip stays visible at zero")
        XCTAssertNil(label("Stalled"), "a crew chip at zero says nothing")
        XCTAssertNil(label("Burning"), "a crew chip at zero says nothing")
    }

    func testACrewChipSpeaksOnceItsCountIsAboveZero() {
        chips.render(MotherStatus(stalled: 2, burning: 1))
        XCTAssertEqual(label("Stalled"), "2 stalled")
        XCTAssertEqual(label("Burning"), "1 burning")
        XCTAssertNil(label("Needs you"))
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// E: the panel's colours are legible on the Mother panel's background.
// ══════════════════════════════════════════════════════════════════════════════

final class MC2LegibilityTests: XCTestCase {

    private func luminance(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB), "colour has no sRGB form", file: file, line: line)
        func linear(_ component: CGFloat) -> Double {
            let c = Double(component)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
        let (la, lb) = (try luminance(a), try luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testEveryColourTheCrewPanelUsesMeetsWCAGAAOnTheBackground() throws {
        let colours: [(String, NSColor)] = [
            ("fg", Theme.fg), ("fgMuted", Theme.fgMuted), ("sage", Theme.sage),
            ("amber", Theme.amber), ("redSweater", Theme.redSweater),
        ]
        for (name, colour) in colours {
            let ratio = try contrast(colour, Theme.bg)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Theme.\(name) is \(String(format: "%.2f", ratio)):1 on Theme.bg")
        }
    }

    func testThePanelsColoursAreTheThemeColours() throws {
        let panel = MotherJobDetail.crewColors
        let expected: [(String, Color, NSColor)] = [
            ("text", panel.text, Theme.fg), ("muted", panel.muted, Theme.fgMuted),
            ("good", panel.good, Theme.sage), ("warn", panel.warn, Theme.amber), ("bad", panel.bad, Theme.redSweater),
        ]
        for (name, color, theme) in expected {
            let a = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB), name)
            let b = try XCTUnwrap(theme.usingColorSpace(.sRGB), name)
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.02, "\(name) red")
            XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.02, "\(name) green")
            XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.02, "\(name) blue")
            XCTAssertEqual(a.alphaComponent, 1, accuracy: 0.01, "\(name) is not dimmed")
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// F: the Details sheet (`mother status <id>` on this Mac, never for a PHI repo).
// ══════════════════════════════════════════════════════════════════════════════

final class MC2DetailsSheetTests: XCTestCase {

    private var host: MC2StubHost!
    private var detail: MotherJobDetail!
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc2-details-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        host = MC2StubHost()
        detail = MotherJobDetail(host: host, logDirectory: tmp)
    }

    override func tearDown() {
        detail = nil
        host = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    private var marker: URL { tmp.appendingPathComponent("ran.marker") }

    /// An executable `#!/bin/sh` script in the temp directory.
    private func script(_ name: String, _ body: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The sentinel `mother`: leaves a marker file so a test can tell it ran.
    private func sentinelMother() throws -> URL {
        try script("mother", "touch '\(marker.path)'\n" + ##"printf 'SENTINEL-STATUS-OUTPUT for %s\n' "$2""##)
    }

    private func load(_ job: MotherJob, timeout: TimeInterval = 10) throws -> (content: MotherDetailsContent, seconds: TimeInterval) {
        let exp = expectation(description: "details for \(job.id)")
        var delivered: MotherDetailsContent?
        let start = Date()
        detail.loadDetails(for: job, timeout: timeout) { delivered = $0; exp.fulfill() }
        wait(for: [exp], timeout: 20)
        return (try XCTUnwrap(delivered, "loadDetails never completed"), Date().timeIntervalSince(start))
    }

    // MARK: Text for a non-PHI repo

    func testANonPHIRepoGetsTheStatusOutputOfTheMotherCLI() throws {
        host.binary = try sentinelMother()

        let (content, _) = try load(mc2Job(id: "j-pay1", repo: "Carefeed/payments"))

        guard case .text(let text) = content else { return XCTFail("expected text, got \(content)") }
        XCTAssertTrue(text.contains("SENTINEL-STATUS-OUTPUT for j-pay1"), text)
    }

    // MARK: PHI repos never run the CLI

    func testPHIReposGetOnlyTheCommandAndTheCLIIsNeverRun() throws {
        host.binary = try sentinelMother()

        for repo in ["Carefeed/admin-portal", "Carefeed/referral-monitor"] {
            let (content, _) = try load(mc2Job(id: "j-phi1", repo: repo))
            XCTAssertEqual(content, .commandOnly("mother status j-phi1"), repo)
        }
        mc2Spin(0.3)   // long enough for a wrongly started process to have touched its marker
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "mother was run for a PHI repo")
    }

    func testTheStatusCommandQuotesAnIdThatIsNotPlainlySafe() {
        XCTAssertEqual(MotherJobDetail.statusCommand(forJob: "j-1_a.b"), "mother status j-1_a.b")
        XCTAssertEqual(MotherJobDetail.statusCommand(forJob: "job with space"), "mother status 'job with space'")
        XCTAssertEqual(MotherJobDetail.statusCommand(forJob: "x; rm -rf ~"), "mother status 'x; rm -rf ~'")
        XCTAssertEqual(MotherJobDetail.statusCommand(forJob: "it's"), #"mother status 'it'\''s'"#)
    }

    // MARK: Unavailable

    func testAMissingBinaryIsUnavailable() throws {
        host.binary = tmp.appendingPathComponent("does-not-exist")
        let (content, _) = try load(mc2Job(repo: "Carefeed/payments"))
        guard case .unavailable = content else { return XCTFail("expected unavailable, got \(content)") }
    }

    func testNoMotherCLIInstalledIsUnavailable() throws {
        host.binary = nil
        let (content, _) = try load(mc2Job(repo: "Carefeed/payments"))
        guard case .unavailable = content else { return XCTFail("expected unavailable, got \(content)") }
    }

    func testACLIThatPrintsNothingIsUnavailableNotABlankSheet() throws {
        host.binary = try script("mother", "exit 3")
        let (content, _) = try load(mc2Job(repo: "Carefeed/payments"))
        guard case .unavailable = content else { return XCTFail("expected unavailable, got \(content)") }
    }

    func testACLIThatHangsIsStoppedAtTheTimeoutAndIsUnavailable() throws {
        // `exec` replaces the shell, so killing the process closes the pipe at once.
        host.binary = try script("mother", "exec /bin/sleep 30")

        let (content, seconds) = try load(mc2Job(repo: "Carefeed/payments"), timeout: 0.5)

        guard case .unavailable = content else { return XCTFail("expected unavailable, got \(content)") }
        XCTAssertLessThan(seconds, 5, "the hang was not cut off at the timeout")
    }

    // MARK: The sheet itself

    func testTheSheetShowsTheCommandAndACopyButtonForAPHIRepo() {
        let sheet = MotherDetailsSheet(jobTitle: "Add facility export endpoint")
        XCTAssertFalse(sheet.isCopyButtonVisible)

        sheet.show(.commandOnly("mother status j-1"))

        XCTAssertTrue(sheet.shownText.contains("mother status j-1"), sheet.shownText)
        XCTAssertTrue(sheet.isCopyButtonVisible)
    }

    func testTheSheetShowsStatusTextAsIsWithoutACopyButton() {
        let sheet = MotherDetailsSheet(jobTitle: "Backfill invoice totals")

        sheet.show(.text("gates: unit failed\nreview: pending"))

        XCTAssertEqual(sheet.shownText, "gates: unit failed\nreview: pending")
        XCTAssertFalse(sheet.isCopyButtonVisible)
    }

    func testTheSheetShowsWhyWhenUnavailable() {
        let sheet = MotherDetailsSheet(jobTitle: "T")
        sheet.show(.unavailable("The mother command was not found."))
        XCTAssertEqual(sheet.shownText, "The mother command was not found.")
    }

    func testClosingTheSheetDropsItsText() {
        let sheet = MotherDetailsSheet(jobTitle: "T")
        sheet.show(.text("secret gate output"))
        XCTAssertFalse(sheet.shownText.isEmpty)

        sheet.close()

        XCTAssertEqual(sheet.shownText, "")
    }
}
