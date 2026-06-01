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
final class MotherBrokerClientTests: XCTestCase {

    var client:    MotherBrokerClient!
    var serverFd:  Int32 = -1
    var listenFd:  Int32 = -1
    var sockPath:  String!
    var cancellables = Set<AnyCancellable>()

    // Semaphore signals when the server-side has accepted the client connection.
    let accepted = DispatchSemaphore(value: 0)

    override func setUp() {
        super.setUp()
        sockPath = NSTemporaryDirectory() + "nostromo-broker-test-\(ProcessInfo.processInfo.processIdentifier).sock"
        unlink(sockPath)

        // Create a listening AF_UNIX socket
        listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { XCTFail("socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssert(pathBytes.count <= cap, "sockPath too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.listen(listenFd, 5)

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

    func performHandshake() {
        // Start client, wait for connection, send hello, consume subscribe
        client.start()
        let _ = accepted.wait(timeout: .now() + 5)  // server accepted
        serverWrite(helloJSON)                        // send hello → client sends subscribe
        _ = serverReadLine()                          // discard subscribe command
    }

    // MARK: - Tests

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 1: Date decode — millis-ts snapshot decodes; basic (no-frac) ts too.
    // ──────────────────────────────────────────────────────────────────────────

    func testDateDecoding_millisAndBasicTsDecode() {
        let snapshotExp = XCTestExpectation(description: "snapshot received")
        var receivedJobs: [MotherJob] = []

        client.events.sink { event in
            if case .snapshot(let jobs) = event {
                receivedJobs = jobs
                snapshotExp.fulfill()
            }
        }.store(in: &cancellables)

        performHandshake()

        // Snapshot with two jobs: one millis-ts, one basic (no fractional)
        serverWrite("""
        {"v":1,"dir":"event","t":"snapshot","id":"1","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[{"id":"job-millis","state":"running","repo":"carefeed","isolation":"none","title":"Millis job","created_at":"2026-06-01T12:00:00.000Z","started_at":"2026-06-01T12:00:01.000Z","finished_at":null},{"id":"job-basic","state":"queued","repo":"carefeed","isolation":"none","title":"Basic ts job","created_at":"2026-06-01T12:00:00Z","started_at":null,"finished_at":null}]}}
        """)

        wait(for: [snapshotExp], timeout: 3)
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

    func testEnvelopeDecode_helloAndSnapshot() {
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

        client.start()
        let _ = accepted.wait(timeout: .now() + 5)
        serverWrite(helloJSON)
        _ = serverReadLine()  // discard subscribe

        wait(for: [helloExp], timeout: 3)

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

        wait(for: [snapshotExp], timeout: 3)
        XCTAssertEqual(snapshotJobs.count, 1)
        XCTAssertEqual(snapshotJobs[0].id,    "abc123")
        XCTAssertEqual(snapshotJobs[0].state, "running")
        XCTAssertEqual(snapshotJobs[0].repo,  "carefeed")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 3: Line framing — partial line buffered until \n arrives.
    // ──────────────────────────────────────────────────────────────────────────

    func testLineFraming_partialLineBufferedUntilNewline() {
        let snapshotExp = XCTestExpectation(description: "snapshot from split write")
        var receivedJobs: [MotherJob] = []

        client.events.sink { event in
            if case .snapshot(let jobs) = event {
                receivedJobs = jobs
                snapshotExp.fulfill()
            }
        }.store(in: &cancellables)

        client.start()
        let _ = accepted.wait(timeout: .now() + 5)
        serverWrite(helloJSON)
        _ = serverReadLine()  // discard subscribe

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

        // Give the client a moment — it should NOT have decoded the snapshot yet
        Thread.sleep(forTimeInterval: 0.15)

        // Now complete the line with part 2 + \n
        serverWrite(snapshotPart2)

        wait(for: [snapshotExp], timeout: 3)
        XCTAssertEqual(receivedJobs.count, 1)
        XCTAssertEqual(receivedJobs[0].id, "split-job")
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 4: Command correlation — cancel resolves when matching ack arrives.
    //         Out-of-order: ping arrives before the ack.
    // ──────────────────────────────────────────────────────────────────────────

    func testCommandCorrelation_cancelResolvesOnMatchingAck_withPingInterleave() {
        let cancelExp = XCTestExpectation(description: "cancel completion called")
        var cancelResult: Result<Void, BrokerError>?

        performHandshake()

        // Send snapshot so AppStore-like callers can proceed; also confirms connected
        serverWrite("""
        {"v":1,"dir":"event","t":"snapshot","id":"4","ts":"2026-06-01T00:00:00.000Z","data":{"sub":"queue","jobs":[]}}
        """)

        // Wait for connected
        let connExp = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in connExp.fulfill() }
            .store(in: &cancellables)
        wait(for: [connExp], timeout: 3)

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

        wait(for: [cancelExp], timeout: 3)
        XCTAssertNotNil(cancelResult)
        if case .success = cancelResult! { /* expected */ } else {
            XCTFail("expected .success, got \(String(describing: cancelResult))")
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // TEST 5: Error mapping — failure ack → correct BrokerError case.
    // ──────────────────────────────────────────────────────────────────────────

    func testErrorMapping_noSuchJobAck() {
        let retryExp = XCTestExpectation(description: "retry completion called")
        var retryResult: Result<Void, BrokerError>?

        performHandshake()

        let connExp = XCTestExpectation(description: "connected")
        client.connected.filter { $0 }.first().sink { _ in connExp.fulfill() }
            .store(in: &cancellables)
        wait(for: [connExp], timeout: 3)

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

        wait(for: [retryExp], timeout: 3)
        XCTAssertNotNil(retryResult)
        if case .failure(let err) = retryResult! {
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

    func testStateEventFold_awaitingInputEvent() {
        let stateExp = XCTestExpectation(description: "stateChange received")
        var changedEvent: BrokerEvent?

        client.events.sink { event in
            if case .stateChange = event {
                changedEvent = event
                stateExp.fulfill()
            }
        }.store(in: &cancellables)

        performHandshake()

        serverWrite("""
        {"v":1,"dir":"event","t":"awaiting_input","id":"6","ts":"2026-06-01T00:00:00.000Z","data":{"job":"job-xyz","category":"await","question":"Should I proceed?"}}
        """)

        wait(for: [stateExp], timeout: 3)
        XCTAssertNotNil(changedEvent)
        if case .stateChange(let jobId, let kind, let question, _, _) = changedEvent! {
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

    func testSubscribe_sentAfterHello() {
        client.start()
        let _ = accepted.wait(timeout: .now() + 5)
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

    func testOrphanAck_isIgnored() {
        performHandshake()

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
