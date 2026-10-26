import XCTest
import Combine
import Darwin
import NostromoKit

// Version-skew behaviour of the daemon handshake, over a real AF_UNIX socket
// against scripted fake daemons.
//
// The Rust daemon's `Topic` enum rejects a subscribe naming a topic it has
// never heard of by closing the connection. An OLD daemon (one that predates
// the `work` topic) therefore drops any client that subscribes to `work`, and
// the client then reconnects, subscribes to `work` again, and loops forever.
// The contract this pins:
//
//   * a new daemon advertises what it can do in `welcome.features`;
//   * the client's first `subscribe` names only topics every daemon knows;
//   * only when the Welcome of THIS connection lists "work" does the client
//     send a second `subscribe` that adds it;
//   * all of that is decided per connection, from scratch, on every reconnect.
//
// The fakes below speak the real framing (4-byte big-endian length + JSON).
//
// The daemon also strips transcript `note` blocks from a `session_turns` snapshot for any
// connection whose CURRENT `subscribe` does not name `model` (src/ipc/server.rs
// `without_notes_unless_model`; a later subscribe replaces the list). So the client must have
// subscribed to `model` BEFORE the session attaches, or a restored "Model changed" note is lost,
// and attaching twice on one connection is not safe. The contract these tests pin: a connection
// is not "connected" to the rest of the app until its `welcome` was processed (and any feature
// subscribe sent), so spawn/attach always follow the subscribe, on every reconnect.

// MARK: - Fake daemon

final class FakeDaemon {
    /// What the daemon does on one accepted connection.
    struct Script {
        /// `welcome.features`; `nil` omits the key entirely (an old daemon).
        var features: [String]?
        /// Closes the connection on a `subscribe` naming any of these topics,
        /// like an old daemon facing a topic it cannot deserialize.
        var rejectsTopics: Set<String> = []
        var end: End = .never
        /// A slow daemon: the `welcome` follows the `hello` this much later. The client's other
        /// frames queue up meanwhile, which is exactly the window a too-early "connected" shows in.
        var welcomeDelay: TimeInterval = 0
        /// On `session_attach`, answer a `session_turns` snapshot of one turn that holds this
        /// note, as the daemon does: WITHOUT the note when the connection's latest `subscribe`
        /// does not name `model`.
        var attachNote: String?
        /// `welcome.operator_nonce`, issued when the daemon verified the peer as the operator
        /// app; `nil` omits the key (an unverified peer, or an older daemon).
        var operatorNonce: String? = nil

        enum End {
            case never
            /// Close shortly after a `subscribe` naming this topic arrives.
            case afterSubscribeNaming(String)
            /// Close this long after the first `subscribe` arrives.
            case afterFirstSubscribe(delay: TimeInterval)
            /// Close this long after the first `session_attach` arrives (and was answered).
            case afterFirstAttach(delay: TimeInterval)
            /// Close shortly after the first `decision_answer` arrives.
            case afterFirstDecisionAnswer
        }
    }

    struct Frame {
        let type: String
        let topics: [String]
        /// The frame's `tag`, for session frames.
        var tag: String = ""
        /// The `client_kind` a `hello` carried, if any.
        var clientKind: String? = nil
        /// The whole decoded frame, for assertions on keys (present, absent, null).
        var json: [String: Any] = [:]
    }

    let path: String
    private let scripts: [Script]
    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var stopped = false
    private var perConnection: [[Frame]] = []
    private var rejected = 0

    /// `scripts[i]` drives the i-th accepted connection (the last one repeats).
    init(scripts: [Script]) {
        precondition(!scripts.isEmpty)
        self.scripts = scripts
        // Short, unique: sun_path holds 104 bytes on Darwin.
        self.path = "/tmp/nsfd-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
    }

    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return perConnection.count }
    /// Connections the daemon closed because of a topic it rejects.
    var rejections: Int { lock.lock(); defer { lock.unlock() }; return rejected }

    func frames(connection i: Int) -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return i < perConnection.count ? perConnection[i] : []
    }

    func subscribes(connection i: Int) -> [Frame] {
        frames(connection: i).filter { $0.type == "subscribe" }
    }

    func frames(connection i: Int, ofType type: String) -> [Frame] {
        frames(connection: i).filter { $0.type == type }
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posix("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = path.utf8CString
        precondition(bytes.count <= cap, "socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                bytes.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0 else { Darwin.close(fd); throw posix("bind") }
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw posix("listen") }
        listenFd = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "fake-nostromd"
        thread.start()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        // The accept loop notices `stopped` within one poll slice and closes the fd.
        unlink(path)
    }

    private func posix(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: what])
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    // MARK: connection handling

    private func acceptLoop() {
        while !isStopped {
            guard pollReadable(listenFd, millis: 100) else { continue }
            let conn = accept(listenFd, nil, nil)
            if conn < 0 { continue }
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            handle(conn)
            Darwin.close(conn)
        }
        Darwin.close(listenFd)
    }

    private func handle(_ conn: Int32) {
        lock.lock()
        let index = perConnection.count
        perConnection.append([])
        lock.unlock()
        let script = scripts[min(index, scripts.count - 1)]
        var closeAt: Date?
        // What this connection is subscribed to now: each `subscribe` replaces the list.
        var subscribedTopics: [String] = []

        while !isStopped {
            if let at = closeAt, Date() >= at { return }
            guard pollReadable(conn, millis: 50) else { continue }
            guard let body = readFrame(conn),
                  let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let type = json["type"] as? String
            else { return }   // the client closed (or sent garbage)

            let topics = (json["topics"] as? [String]) ?? []
            let tag = (json["tag"] as? String) ?? ""
            let frame = Frame(type: type, topics: topics, tag: tag, clientKind: json["client_kind"] as? String,
                              json: json)
            lock.lock(); perConnection[index].append(frame); lock.unlock()

            switch type {
            case "hello":
                var welcome: [String: Any] = ["type": "welcome", "protocol_version": 4, "daemon_pid": 4242]
                if let features = script.features { welcome["features"] = features }
                if let nonce = script.operatorNonce { welcome["operator_nonce"] = nonce }
                if script.welcomeDelay > 0 { Thread.sleep(forTimeInterval: script.welcomeDelay) }
                writeFrame(conn, welcome)
            case "subscribe":
                subscribedTopics = topics
                if !script.rejectsTopics.isDisjoint(with: topics) {
                    lock.lock(); rejected += 1; lock.unlock()
                    return
                }
                switch script.end {
                case .never: break
                case .afterSubscribeNaming(let topic):
                    if topics.contains(topic) { closeAt = Date().addingTimeInterval(0.1) }
                case .afterFirstSubscribe(let delay):
                    if closeAt == nil { closeAt = Date().addingTimeInterval(delay) }
                case .afterFirstAttach, .afterFirstDecisionAnswer:
                    break
                }
            case "session_attach":
                if let noteText = script.attachNote {
                    var blocks: [[String: Any]] = []
                    if subscribedTopics.contains("model") {
                        blocks.append(["kind": "note", "note_kind": "model_changed", "text": noteText,
                                       "ts": "2026-10-12T19:47:03.123456Z"])
                    }
                    blocks.append(["kind": "text", "text": "ok"])
                    let turn: [String: Any] = ["id": "t0", "user_input": "hi", "timestamp": "2026-10-12T19:46:00Z",
                                               "is_complete": true, "blocks": blocks]
                    writeFrame(conn, ["type": "session_turns", "tag": tag, "turns": [turn]])
                }
                if case .afterFirstAttach(let delay) = script.end, closeAt == nil {
                    closeAt = Date().addingTimeInterval(delay)
                }
            case "decision_answer":
                if case .afterFirstDecisionAnswer = script.end, closeAt == nil {
                    closeAt = Date().addingTimeInterval(0.1)
                }
            case "ping":
                writeFrame(conn, ["type": "pong"])
            default:
                break
            }
        }
    }

    private func pollReadable(_ fd: Int32, millis: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, millis) > 0
    }

    private func readN(_ fd: Int32, _ count: Int) -> Data? {
        var buf = Data(count: count)
        let ok = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var got = 0
            while got < count {
                let n = Darwin.read(fd, base.advanced(by: got), count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? buf : nil
    }

    private func readFrame(_ fd: Int32) -> Data? {
        guard let header = readN(fd, 4) else { return nil }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= 4 * 1024 * 1024 else { return nil }
        return readN(fd, Int(length))
    }

    private func writeFrame(_ fd: Int32, _ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}

// MARK: - Tests

final class NostromodClientHandshakeTests: XCTestCase {

    private var daemon: FakeDaemon!
    private var client: NostromodClient?
    private var session: ChatSession?

    override func tearDown() {
        session = nil
        client = nil      // the client reconnects only while it is alive
        daemon?.stop()
        daemon = nil
        super.tearDown()
    }

    private func connectClient(to scripts: [FakeDaemon.Script]) throws -> NostromodClient {
        daemon = FakeDaemon(scripts: scripts)
        try daemon.start()
        let c = NostromodClient(socketPath: daemon.path)
        client = c
        c.start()
        return c
    }

    /// A real client and a real `ChatSession` for `tag`, the way the app wires them: the session
    /// spawns and attaches whenever the client reports itself connected.
    private func connectSession(to scripts: [FakeDaemon.Script], tag: String = "claudia") throws -> (NostromodClient, ChatSession) {
        let c = try connectClient(to: scripts)
        let s = ChatSession(tag: tag, agentName: "claudia", displayName: "Claudia", workingDirectory: nil, client: c)
        session = s
        return (c, s)
    }

    /// Poll (bounded) until `condition` holds, servicing the main run loop meanwhile: the
    /// session's Combine pipeline lives on it. Waiting for a socket thread is the one place a
    /// wall-clock bound is legitimate.
    private func pumpUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private static let noteText = "Model changed to Opus (from Sonnet) by you."

    /// Every model note the session shows, whether inside a turn or standing alone.
    private func notes(in session: ChatSession) -> [String] {
        session.turns.flatMap { turn -> [String] in
            var found = turn.blocks.compactMap { block -> String? in
                if case .note(let text) = block { return text } else { return nil }
            }
            if case .note(let text)? = turn.marker { found.append(text) }
            return found
        }
    }

    /// Frame indices of `connection`: its first subscribe naming `model`, its first spawn, its first attach.
    private func order(of connection: Int) -> (modelSubscribe: Int?, spawn: Int?, attach: Int?) {
        let frames = daemon.frames(connection: connection)
        return (frames.firstIndex { $0.type == "subscribe" && $0.topics.contains("model") },
                frames.firstIndex { $0.type == "session_spawn" },
                frames.firstIndex { $0.type == "session_attach" })
    }

    private func assertModelSubscribedBeforeSpawnAndAttach(connection i: Int, file: StaticString = #filePath, line: UInt = #line) {
        let o = order(of: i)
        guard let subscribe = o.modelSubscribe, let spawn = o.spawn, let attach = o.attach else {
            return XCTFail("connection \(i) frames: \(daemon.frames(connection: i).map { "\($0.type)\($0.topics)" })", file: file, line: line)
        }
        XCTAssertLessThan(subscribe, spawn, "connection \(i): session_spawn went out before the `model` subscribe", file: file, line: line)
        XCTAssertLessThan(subscribe, attach, "connection \(i): session_attach went out before the `model` subscribe, so the daemon strips the restored notes", file: file, line: line)
        XCTAssertEqual(daemon.frames(connection: i, ofType: "session_attach").count, 1,
                       "connection \(i): attaching twice on one connection spawns a duplicate forwarder", file: file, line: line)
    }

    /// Poll (bounded) until `condition` holds.
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // A client that mentions `work` to a daemon that cannot parse it is thrown
    // off, reconnects after a second, and does it again. 1.8 s is long enough
    // to see at least one such cycle (the first reconnect is 1 s after the drop).
    func testClientStaysConnectedToAnOldDaemonThatClosesOnTheWorkTopic() throws {
        let c = try connectClient(to: [.init(features: nil, rejectsTopics: ["work"])])

        XCTAssertTrue(waitUntil(5) { !self.daemon.subscribes(connection: 0).isEmpty },
                      "the client never subscribed")
        Thread.sleep(forTimeInterval: 1.8)

        XCTAssertEqual(daemon.rejections, 0,
                       "the old daemon was sent the unknown `work` topic and dropped the connection")
        XCTAssertEqual(daemon.connectionCount, 1,
                       "the client was thrown off and had to reconnect")
        XCTAssertTrue(c.connected.value, "the client must still be connected")
        let named = daemon.subscribes(connection: 0).flatMap(\.topics)
        XCTAssertFalse(named.contains("work"), "`work` must not be sent to a daemon that did not advertise it: \(named)")
        XCTAssertTrue(named.contains("activity"), "the base topics must still be subscribed: \(named)")
    }

    func testClientFirstSubscribesWithoutWorkThenAddsItWhenTheWelcomeAdvertisesIt() throws {
        _ = try connectClient(to: [.init(features: ["work"])])

        XCTAssertTrue(waitUntil(5) { !self.daemon.subscribes(connection: 0).isEmpty },
                      "the client never subscribed")
        let first = daemon.subscribes(connection: 0)[0]
        XCTAssertFalse(first.topics.contains("work"),
                       "the first subscribe must name only topics every daemon knows: \(first.topics)")

        XCTAssertTrue(waitUntil(5) { self.daemon.subscribes(connection: 0).count >= 2 },
                      "the client never added `work` although the Welcome advertised it")
        let subs = daemon.subscribes(connection: 0)
        guard subs.count >= 2 else { return }
        XCTAssertTrue(subs[1].topics.contains("work"), "the second subscribe must add `work`: \(subs[1].topics)")
        XCTAssertTrue(Set(first.topics).isSubset(of: Set(subs[1].topics)),
                      "the second subscribe replaces the first, so it must keep the base topics: \(subs[1].topics)")
        XCTAssertEqual(subs.count, 2, "exactly one follow-up subscribe is expected")
    }

    // The daemon lets a connection answer an agent's decision only if its hello says it is the
    // Mac app (and the connecting process is the app bundle). An older daemon ignores the key.
    func testTheHelloSaysThisIsTheMacApp() throws {
        _ = try connectClient(to: [.init(features: nil)])

        XCTAssertTrue(waitUntil(5) { !self.daemon.frames(connection: 0, ofType: "hello").isEmpty },
                      "the client never sent a hello")
        XCTAssertEqual(daemon.frames(connection: 0, ofType: "hello").first?.clientKind, "mac_app")
    }

    // The ordering rule (AP0b): the daemon holds a permission request for a human only while a verified
    // app that SAYS it renders approvals is connected. The approval card exists now (AP2a), so this app
    // says so, but only on a connection whose Welcome advertised `approvals_v1`: the first subscribe
    // (sent before any welcome) never makes the claim, and a daemon that does not list the feature
    // never hears it. Every subscribe carries the key explicitly.

    /// Connect a fresh client to a daemon with `script` and return what it subscribed to once it has sent `count`
    /// subscribes and reports itself connected.
    private func subscribes(connectingTo script: FakeDaemon.Script, expecting count: Int,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [FakeDaemon.Frame] {
        client = nil
        daemon?.stop()
        let c = try connectClient(to: [script])
        XCTAssertTrue(pumpUntil(5) { self.daemon.subscribes(connection: 0).count >= count && c.connected.value },
                      "the client never finished its handshake (subscribes: \(daemon.subscribes(connection: 0).map(\.topics)))",
                      file: file, line: line)
        // Let a subscribe that should NOT be sent show up if it is going to (a bounded pump, not a wait on a condition).
        _ = pumpUntil(0.3) { false }
        return daemon.subscribes(connection: 0)
    }

    func testMacClaimsRendersApprovalsOnlyWithFeature() throws {
        let subs = try subscribes(connectingTo: .init(features: ["approvals_v1", "work"]), expecting: 2)
        guard subs.count >= 2 else { return XCTFail("expected a first subscribe and a follow-up, got \(subs.map(\.topics))") }

        let first = subs[0], later = subs[1]
        XCTAssertNotNil(first.json["renders_approvals"], "the key is present on the first subscribe, not omitted: \(first.json)")
        XCTAssertEqual(first.json["renders_approvals"] as? Bool, false,
                       "the first subscribe is sent before any welcome and must not claim approvals: \(first.json)")
        XCTAssertEqual(later.json["renders_approvals"] as? Bool, true,
                       "the welcome advertised approvals_v1, so the follow-up subscribe claims it: \(later.json)")
        XCTAssertTrue(Set(NostromodClient.baseTopics).isSubset(of: Set(later.topics)),
                      "the follow-up replaces the first subscribe, so it keeps the base topics: \(later.topics)")
        XCTAssertTrue(later.topics.contains("work"), "and still adds what else the welcome advertised: \(later.topics)")
        XCTAssertEqual(subs.count, 2, "exactly one follow-up subscribe")
    }

    func testAnApprovalsOnlyWelcomeStillGetsTheClaimWithTheBaseTopics() throws {
        let subs = try subscribes(connectingTo: .init(features: ["approvals_v1"]), expecting: 2)
        guard subs.count >= 2 else { return XCTFail("the claim needs its own subscribe: \(subs.map(\.topics))") }
        XCTAssertEqual(subs[0].json["renders_approvals"] as? Bool, false)
        XCTAssertEqual(subs[1].json["renders_approvals"] as? Bool, true)
        XCTAssertTrue(Set(NostromodClient.baseTopics).isSubset(of: Set(subs[1].topics)), "\(subs[1].topics)")
    }

    func testMacNeverClaimsRendersApprovalsToADaemonThatDoesNotAdvertiseIt() throws {
        let scripts: [(String, FakeDaemon.Script, Int)] = [
            ("no features key (an old daemon)", .init(features: nil), 1),
            ("other features only", .init(features: ["some_future_feature"]), 1),
            ("work but not approvals", .init(features: ["work"]), 2),
            ("an empty list", .init(features: []), 1),
        ]
        for (name, script, count) in scripts {
            let subs = try subscribes(connectingTo: script, expecting: count)
            XCTAssertFalse(subs.isEmpty, "\(name): the client never subscribed")
            for sub in subs {
                XCTAssertEqual(sub.json["renders_approvals"] as? Bool, false,
                               "\(name): every subscribe says, explicitly, that this app does not render approvals: \(sub.json)")
            }
        }
    }

    func testAClientThatNeverConnectedHasNoConnectionToAnswerOn() {
        let c = NostromodClient(socketPath: "/tmp/nsfd-none-\(getpid())-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertFalse(c.hasConnection)
    }

    func testAConnectedClientHasAConnection() throws {
        let c = try connectClient(to: [.init(features: nil)])
        XCTAssertTrue(pumpUntil(5) { c.connected.value && c.hasConnection }, "the client never connected")
    }

    func testTheClaimIsTrueOnlyWhenTheFeatureListContainsApprovalsV1() {
        XCTAssertTrue(NostromodClient.claimsRendersApprovals(features: ["approvals_v1"]))
        XCTAssertTrue(NostromodClient.claimsRendersApprovals(features: ["work", "approvals_v1", "model"]))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: nil))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: []))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: ["work", "model"]))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: ["approvals_v2"]))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: ["approvals"]))
        XCTAssertFalse(NostromodClient.claimsRendersApprovals(features: ["Approvals_V1"]))
    }

    func testAWelcomeThatAdvertisesOtherFeaturesButNotWorkDoesNotGetWork() throws {
        let c = try connectClient(to: [.init(features: ["some_future_feature"], rejectsTopics: ["work"])])

        XCTAssertTrue(waitUntil(5) { !self.daemon.subscribes(connection: 0).isEmpty })
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertEqual(daemon.rejections, 0, "`work` was sent to a daemon that did not list it")
        XCTAssertEqual(daemon.connectionCount, 1)
        XCTAssertTrue(c.connected.value)
    }

    // Connection 0 advertises work; connection 1 is a daemon that does not (and
    // would drop a client that asks); connection 2 advertises it again. Each
    // connection must repeat the whole handshake and decide from its own Welcome.
    func testEveryReconnectRepeatsTheHandshakeAndReEvaluatesFeaturesFromItsOwnWelcome() throws {
        _ = try connectClient(to: [
            .init(features: ["work"], end: .afterSubscribeNaming("work")),
            .init(features: nil, rejectsTopics: ["work"], end: .afterFirstSubscribe(delay: 0.4)),
            .init(features: ["work"]),
        ])

        XCTAssertTrue(waitUntil(15) { self.daemon.subscribes(connection: 2).count >= 2 },
                      "the third connection never completed the handshake (connections: \(daemon.connectionCount))")

        for i in 0...2 {
            XCTAssertEqual(daemon.frames(connection: i).first?.type, "hello",
                           "connection \(i) must begin with a hello")
        }

        let c0 = daemon.subscribes(connection: 0)
        XCTAssertFalse(c0.first?.topics.contains("work") ?? true, "connection 0 first subscribe: \(c0.map(\.topics))")
        XCTAssertTrue(c0.dropFirst().first?.topics.contains("work") ?? false,
                      "connection 0 advertised work, so it must have been added: \(c0.map(\.topics))")

        let c1 = daemon.subscribes(connection: 1)
        XCTAssertFalse(c1.isEmpty, "connection 1 never subscribed")
        XCTAssertFalse(c1.flatMap(\.topics).contains("work"),
                       "connection 1's Welcome did not advertise work: the previous connection's features must not leak: \(c1.map(\.topics))")
        XCTAssertEqual(daemon.rejections, 0, "an old daemon was sent `work`")

        let c2 = daemon.subscribes(connection: 2)
        XCTAssertFalse(c2.first?.topics.contains("work") ?? true, "connection 2 first subscribe: \(c2.map(\.topics))")
        XCTAssertTrue(c2.dropFirst().first?.topics.contains("work") ?? false,
                      "connection 2 advertised work again, so it must have been added: \(c2.map(\.topics))")
    }

    // MARK: - Spawn and attach follow the `model` subscribe

    // The daemon answers a late `session_attach` without the transcript notes when the
    // connection has not yet named `model`. The fake daemon is slow to say `welcome`, which is the
    // window in which a client that calls itself connected too early attaches first.

    func testTheFirstAttachFollowsASubscribeNamingModelAndTheRestoredTranscriptKeepsItsNote() throws {
        let (_, s) = try connectSession(to: [.init(features: ["model"], welcomeDelay: 0.2, attachNote: Self.noteText)])

        XCTAssertTrue(pumpUntil(10) { !self.daemon.frames(connection: 0, ofType: "session_attach").isEmpty },
                      "the session never attached")
        XCTAssertTrue(pumpUntil(10) { !s.turns.isEmpty }, "the attach snapshot never reached the session")

        assertModelSubscribedBeforeSpawnAndAttach(connection: 0)
        XCTAssertEqual(daemon.connectionCount, 1)
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(notes(in: s), [Self.noteText], "the restored 'Model changed' note must be in the transcript")
    }

    func testEveryReconnectAttachesOnlyAfterItsOwnModelSubscribeAndNeverDuplicatesTheNoteOrTheTurn() throws {
        let (_, s) = try connectSession(to: [
            .init(features: ["model"], end: .afterFirstAttach(delay: 0.2), welcomeDelay: 0.2, attachNote: Self.noteText),
            .init(features: ["model"], welcomeDelay: 0.2, attachNote: Self.noteText),
        ])

        XCTAssertTrue(pumpUntil(20) { !self.daemon.frames(connection: 1, ofType: "session_attach").isEmpty },
                      "the session never re-attached after the reconnect (connections: \(daemon.connectionCount))")
        XCTAssertTrue(pumpUntil(10) { s.currentEpoch >= 2 }, "the second snapshot never reached the session")
        XCTAssertTrue(pumpUntil(5) { s.attachCount >= 2 })

        assertModelSubscribedBeforeSpawnAndAttach(connection: 0)
        assertModelSubscribedBeforeSpawnAndAttach(connection: 1)
        XCTAssertEqual(daemon.connectionCount, 2)
        XCTAssertEqual(s.attachCount, 2, "one spawn-and-attach per connection")
        XCTAssertEqual(s.turns.count, 1, "the same turn again is not a second turn")
        XCTAssertEqual(notes(in: s), [Self.noteText], "and the note is there exactly once")
    }

    func testAnOldDaemonIsNeverSentModelAndTheClientStillConnectsAndAttaches() throws {
        let (c, s) = try connectSession(to: [.init(features: nil, rejectsTopics: ["model"], attachNote: Self.noteText)])

        XCTAssertTrue(pumpUntil(10) { !self.daemon.frames(connection: 0, ofType: "session_attach").isEmpty },
                      "an old daemon sends no feature list, and the client must still become connected and attach")
        XCTAssertTrue(pumpUntil(10) { !s.turns.isEmpty })

        XCTAssertFalse(daemon.frames(connection: 0, ofType: "session_spawn").isEmpty, "the session was spawned")
        XCTAssertEqual(daemon.rejections, 0, "`model` was sent to a daemon that did not advertise it")
        XCTAssertEqual(daemon.connectionCount, 1)
        XCTAssertFalse(daemon.subscribes(connection: 0).flatMap(\.topics).contains("model"))
        XCTAssertTrue(c.connected.value)
        let frames = daemon.frames(connection: 0)
        XCTAssertLessThan(frames.firstIndex { $0.type == "subscribe" } ?? Int.max,
                          frames.firstIndex { $0.type == "session_spawn" } ?? -1,
                          "the base subscribe still comes first")
        XCTAssertEqual(notes(in: s), [], "an old daemon's snapshot has no notes, and none are invented")
    }

    func testADaemonAdvertisingWorkAndModelGetsOneFollowUpSubscribeBeforeTheAttach() throws {
        _ = try connectSession(to: [.init(features: ["work", "model"], welcomeDelay: 0.2)])

        XCTAssertTrue(pumpUntil(10) { !self.daemon.frames(connection: 0, ofType: "session_attach").isEmpty },
                      "the session never attached")

        let frames = daemon.frames(connection: 0)
        guard let attach = frames.firstIndex(where: { $0.type == "session_attach" }) else { return XCTFail("no attach") }
        let before = frames[..<attach].filter { $0.type == "subscribe" }
        XCTAssertEqual(before.count, 2, "the base subscribe and ONE follow-up, both before the attach: \(before.map(\.topics))")
        guard before.count == 2 else { return }
        XCTAssertFalse(before[0].topics.contains("model") || before[0].topics.contains("work"),
                       "the first subscribe names only topics every daemon knows: \(before[0].topics)")
        XCTAssertEqual(Set(before[1].topics), Set(NostromodClient.baseTopics + ["work", "model"]),
                       "the follow-up replaces the first, so it keeps the base topics and adds both: \(before[1].topics)")
        XCTAssertEqual(daemon.subscribes(connection: 0).count, 2, "no further subscribe follows")
        assertModelSubscribedBeforeSpawnAndAttach(connection: 0)
    }

    // MARK: - The operator nonce (AP1b)
    //
    // A daemon that verified this app as the operator issues an `operator_nonce` in the
    // `welcome` of that connection. The client echoes it in every `decision_answer` written to
    // THAT connection, and never to another one: a nonce is a per-connection credential, so
    // after a reconnect only the new welcome's nonce (or none) may be sent.

    private func decisionAnswers(connection i: Int) -> [[String: Any]] {
        daemon.frames(connection: i, ofType: "decision_answer").map(\.json)
    }

    /// Wait until connection `i` exists and its welcome was processed.
    private func waitForWelcome(connection i: Int, _ c: NostromodClient, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(10) { self.daemon.connectionCount > i && c.connected.value },
                      "connection \(i) never completed its handshake (connections: \(daemon.connectionCount))",
                      file: file, line: line)
    }

    private func waitForDecisionAnswer(connection i: Int, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(5) { self.decisionAnswers(connection: i).count >= count },
                      "connection \(i) never received decision_answer #\(count)", file: file, line: line)
    }

    func testADecisionAnswerEchoesTheNonceFromTheWelcome() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-A1b2")])
        waitForWelcome(connection: 0, c)

        c.decisionAnswer(requestId: "req-1", choiceId: "approve")
        waitForDecisionAnswer(connection: 0)

        let frame = try XCTUnwrap(decisionAnswers(connection: 0).first)
        XCTAssertEqual(frame["request_id"] as? String, "req-1")
        XCTAssertEqual(frame["choice_id"] as? String, "approve")
        XCTAssertEqual(frame["operator_nonce"] as? String, "nonce-A1b2", "frame: \(frame)")
    }

    func testADismissalCarriesANullChoiceAndTheNonce() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-dismiss")])
        waitForWelcome(connection: 0, c)

        c.decisionAnswer(requestId: "req-2", choiceId: nil)
        waitForDecisionAnswer(connection: 0)

        let frame = try XCTUnwrap(decisionAnswers(connection: 0).first)
        XCTAssertTrue(frame.keys.contains("choice_id"), "a dismissal still names choice_id (as null): \(frame)")
        XCTAssertTrue(frame["choice_id"] is NSNull, "a dismissal's choice_id is null: \(frame)")
        XCTAssertEqual(frame["operator_nonce"] as? String, "nonce-dismiss")
    }

    func testEveryDecisionAnswerOnTheConnectionCarriesItsNonce() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-many")])
        waitForWelcome(connection: 0, c)

        c.decisionAnswer(requestId: "req-a", choiceId: "approve")
        c.decisionAnswer(requestId: "req-b", choiceId: nil)
        waitForDecisionAnswer(connection: 0, count: 2)

        let nonces = decisionAnswers(connection: 0).map { $0["operator_nonce"] as? String }
        XCTAssertEqual(nonces, ["nonce-many", "nonce-many"])
    }

    func testTheNonceKeyIsAbsentWhenTheWelcomeHadNone() throws {
        let c = try connectClient(to: [.init(features: nil)])
        waitForWelcome(connection: 0, c)

        c.decisionAnswer(requestId: "req-3", choiceId: "deny")
        waitForDecisionAnswer(connection: 0)

        let frame = try XCTUnwrap(decisionAnswers(connection: 0).first)
        XCTAssertFalse(frame.keys.contains("operator_nonce"),
                       "with no nonce the key must be omitted, not sent empty or null: \(frame)")
        XCTAssertEqual(frame["request_id"] as? String, "req-3")
        XCTAssertEqual(frame["choice_id"] as? String, "deny")
    }

    func testAfterAReconnectOnlyTheNewWelcomesNonceIsSent() throws {
        let c = try connectClient(to: [
            .init(features: nil, end: .afterFirstDecisionAnswer, operatorNonce: "nonce-old"),
            .init(features: nil, operatorNonce: "nonce-new"),
        ])
        waitForWelcome(connection: 0, c)
        c.decisionAnswer(requestId: "req-before", choiceId: "approve")
        waitForDecisionAnswer(connection: 0)
        XCTAssertEqual(decisionAnswers(connection: 0).first?["operator_nonce"] as? String, "nonce-old")

        waitForWelcome(connection: 1, c)
        c.decisionAnswer(requestId: "req-after", choiceId: "deny")
        waitForDecisionAnswer(connection: 1)

        let after = try XCTUnwrap(decisionAnswers(connection: 1).first)
        XCTAssertEqual(after["request_id"] as? String, "req-after")
        XCTAssertEqual(after["operator_nonce"] as? String, "nonce-new",
                       "the new connection must carry its own welcome's nonce: \(after)")
        XCTAssertEqual(decisionAnswers(connection: 1).count, 1)
    }

    func testAfterAReconnectToADaemonThatIssuedNoNonceTheOldNonceIsNotSent() throws {
        let c = try connectClient(to: [
            .init(features: nil, end: .afterFirstDecisionAnswer, operatorNonce: "nonce-stale"),
            .init(features: nil),
        ])
        waitForWelcome(connection: 0, c)
        c.decisionAnswer(requestId: "req-before", choiceId: "approve")
        waitForDecisionAnswer(connection: 0)
        XCTAssertEqual(decisionAnswers(connection: 0).first?["operator_nonce"] as? String, "nonce-stale")

        waitForWelcome(connection: 1, c)
        c.decisionAnswer(requestId: "req-after", choiceId: nil)
        waitForDecisionAnswer(connection: 1)

        let after = try XCTUnwrap(decisionAnswers(connection: 1).first)
        XCTAssertFalse(after.keys.contains("operator_nonce"),
                       "the previous connection's nonce must not leak to this one: \(after)")
    }

    // MARK: - Background task verbs (BA1)

    private func waitForFrame(connection i: Int, type: String, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(5) { self.daemon.frames(connection: i, ofType: type).count >= count },
                      "connection \(i) never received `\(type)` #\(count)", file: file, line: line)
    }

    func testSendTaskStopWritesTheStopFrameWithExactlyItsKeys() throws {
        let c = try connectClient(to: [.init(features: nil)])
        waitForWelcome(connection: 0, c)

        c.sendTaskStop(requestId: "req-stop-1", tag: "cody-1", taskId: "b7k2m9x1a")
        waitForFrame(connection: 0, type: "session_task_stop")

        let frame = try XCTUnwrap(daemon.frames(connection: 0, ofType: "session_task_stop").first).json
        XCTAssertEqual(Set(frame.keys), ["type", "request_id", "tag", "task_id"], "\(frame)")
        XCTAssertEqual(frame["request_id"] as? String, "req-stop-1")
        XCTAssertEqual(frame["tag"] as? String, "cody-1")
        XCTAssertEqual(frame["task_id"] as? String, "b7k2m9x1a")
    }

    func testSendTaskOutputWithAnOffsetWritesItAndWithoutOneOmitsTheKey() throws {
        let c = try connectClient(to: [.init(features: nil)])
        waitForWelcome(connection: 0, c)

        c.sendTaskOutput(requestId: "req-out-1", tag: "cody-1", taskId: "t1", offset: 5_368_709_127, maxBytes: 65_536)
        c.sendTaskOutput(requestId: "req-out-2", tag: "cody-1", taskId: "t1", offset: nil, maxBytes: 8_192)
        c.sendTaskOutput(requestId: "req-out-3", tag: "cody-1", taskId: "t1", offset: 0, maxBytes: 4)
        waitForFrame(connection: 0, type: "session_task_output", count: 3)

        let frames = daemon.frames(connection: 0, ofType: "session_task_output").map(\.json)
        let byId = Dictionary(uniqueKeysWithValues: frames.compactMap { f in (f["request_id"] as? String).map { ($0, f) } })
        let withOffset = try XCTUnwrap(byId["req-out-1"])
        XCTAssertEqual(Set(withOffset.keys), ["type", "request_id", "tag", "task_id", "offset", "max_bytes"], "\(withOffset)")
        XCTAssertEqual((withOffset["offset"] as? NSNumber)?.uint64Value, 5_368_709_127, "an offset past 4 GiB is exact")
        XCTAssertEqual(withOffset["max_bytes"] as? Int, 65_536)

        let tail = try XCTUnwrap(byId["req-out-2"])
        XCTAssertEqual(Set(tail.keys), ["type", "request_id", "tag", "task_id", "max_bytes"], "the tail has no `offset` key at all (not null): \(tail)")
        XCTAssertEqual(tail["max_bytes"] as? Int, 8_192)

        let zero = try XCTUnwrap(byId["req-out-3"])
        XCTAssertEqual(zero["offset"] as? Int, 0, "offset 0 (the start) is not the same as no offset (the tail): \(zero)")
    }

    // MARK: - Terminal panes (1d)
    //
    // The daemon honours the app's terminal verbs only after a subscribe that names the `terminal`
    // topic, declares the `terminal_ui` capability and echoes the welcome's `operator_nonce`. A
    // connection the daemon did not verify (no nonce) never says any of that, and the first subscribe
    // (sent before any welcome) never does either.

    func testAVerifiedConnectionSubscribesToTheTerminalTopicWithItsCapabilityAndNonce() throws {
        let subs = try subscribes(connectingTo: .init(features: nil, operatorNonce: "nonce-term-1"), expecting: 2)
        guard subs.count >= 2 else { return XCTFail("expected a follow-up subscribe, got \(subs.map(\.json))") }

        let later = subs[1]
        XCTAssertTrue(later.topics.contains("terminal"), "topics: \(later.topics)")
        XCTAssertEqual(later.json["capabilities"] as? [String], ["terminal_ui"], "\(later.json)")
        XCTAssertEqual(later.json["operator_nonce"] as? String, "nonce-term-1", "\(later.json)")
        XCTAssertEqual(subs.count, 2, "exactly one follow-up subscribe")
    }

    func testTheFirstSubscribeNeverNamesTheTerminalTopicOrCarriesCapabilities() throws {
        let subs = try subscribes(connectingTo: .init(features: nil, operatorNonce: "nonce-term-2"), expecting: 2)
        let first = try XCTUnwrap(subs.first)
        XCTAssertFalse(first.topics.contains("terminal"), "topics: \(first.topics)")
        XCTAssertNil(first.json["capabilities"], "\(first.json)")
        XCTAssertNil(first.json["operator_nonce"], "\(first.json)")
    }

    func testALaterSubscribeStillKeepsTheBaseTopicsAndWhatTheWelcomeAdvertised() throws {
        let subs = try subscribes(connectingTo: .init(features: ["work"], operatorNonce: "nonce-term-3"), expecting: 2)
        guard subs.count >= 2 else { return XCTFail("expected a follow-up subscribe, got \(subs.map(\.topics))") }
        let later = subs[1]
        XCTAssertTrue(Set(NostromodClient.baseTopics).isSubset(of: Set(later.topics)), "\(later.topics)")
        XCTAssertTrue(later.topics.contains("work"), "\(later.topics)")
        XCTAssertTrue(later.topics.contains("terminal"), "\(later.topics)")
    }

    func testAConnectionWithoutAnOperatorNonceNeverNamesTheTerminalTopicCapabilitiesOrNonce() throws {
        let subs = try subscribes(connectingTo: .init(features: nil), expecting: 1)
        XCTAssertEqual(subs.count, 1, "no nonce, no features: no follow-up subscribe at all (\(subs.map(\.topics)))")
        for sub in subs {
            XCTAssertFalse(sub.topics.contains("terminal"), "topics: \(sub.topics)")
            XCTAssertNil(sub.json["capabilities"], "\(sub.json)")
            XCTAssertNil(sub.json["operator_nonce"], "\(sub.json)")
        }
    }

    func testAFollowUpSubscribeForOtherFeaturesStillOmitsTerminalThingsWithoutANonce() throws {
        let subs = try subscribes(connectingTo: .init(features: ["work"]), expecting: 2)
        XCTAssertEqual(subs.count, 2, "\(subs.map(\.topics))")
        for sub in subs {
            XCTAssertFalse(sub.topics.contains("terminal"), "topics: \(sub.topics)")
            XCTAssertNil(sub.json["capabilities"], "\(sub.json)")
            XCTAssertNil(sub.json["operator_nonce"], "\(sub.json)")
        }
    }

    func testSendTerminalWritesATerminalAttachFrameNamingTheTerminal() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-term-4")])
        waitForWelcome(connection: 0, c)

        c.sendTerminal(.attach(terminalId: "t1"))
        waitForFrame(connection: 0, type: "terminal_attach")

        let frame = try XCTUnwrap(daemon.frames(connection: 0, ofType: "terminal_attach").first).json
        XCTAssertEqual(frame["terminal_id"] as? String, "t1", "\(frame)")
        XCTAssertEqual(Set(frame.keys), ["type", "terminal_id"], "\(frame)")
    }

    func testSendTerminalInputWritesBase64Bytes() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-term-5")])
        waitForWelcome(connection: 0, c)

        c.sendTerminal(.input(terminalId: "t1", bytes: Array("ls\n".utf8)))
        waitForFrame(connection: 0, type: "terminal_input")

        let frame = try XCTUnwrap(daemon.frames(connection: 0, ofType: "terminal_input").first).json
        XCTAssertEqual(frame["terminal_id"] as? String, "t1")
        XCTAssertEqual(frame["bytes"] as? String, "bHMK")
    }

    func testSendTerminalInputMarksAnAutoReplyOnTheSocketAndLeavesTypingUnmarked() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-term-6")])
        waitForWelcome(connection: 0, c)

        c.sendTerminal(.input(terminalId: "t1", bytes: [0x61]))
        c.sendTerminal(.input(terminalId: "t1", bytes: [0x62], autoReply: true))
        waitForFrame(connection: 0, type: "terminal_input", count: 2)

        let frames = daemon.frames(connection: 0, ofType: "terminal_input").map(\.json)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNil(frames[0]["auto_reply"], "typing carries no auto_reply key: \(frames[0])")
        XCTAssertEqual(frames[1]["auto_reply"] as? Bool, true, "\(frames[1])")
    }

    func testTerminalInputsReachTheDaemonInTheOrderTheyWereSentEvenWhenLargeOnesAreWrittenOffTheCallingThread() throws {
        let c = try connectClient(to: [.init(features: nil, operatorNonce: "nonce-term-7")])
        waitForWelcome(connection: 0, c)
        let large = NostromodClient.terminalInlineInputBytes * 16
        XCTAssertGreaterThan(large, NostromodClient.terminalInlineInputBytes)

        // large, small, large, small, small: a small frame sent while a large write is still pending
        // must not overtake it.
        let sizes = [large, 1, large + 1, 2, 3]
        for (n, size) in sizes.enumerated() {
            c.sendTerminal(.input(terminalId: "t1", bytes: [UInt8](repeating: UInt8(0x41 + n), count: size)))
        }
        waitForFrame(connection: 0, type: "terminal_input", count: sizes.count)

        let frames = daemon.frames(connection: 0, ofType: "terminal_input").map(\.json)
        XCTAssertEqual(frames.count, sizes.count)
        let received: [(count: Int, first: UInt8?)] = frames.map { json -> (count: Int, first: UInt8?) in
            let text = json["bytes"] as? String ?? ""
            let bytes = [UInt8](Data(base64Encoded: text) ?? Data())
            return (bytes.count, bytes.first)
        }
        XCTAssertEqual(received.map { $0.count }, sizes, "the frames arrived in the order they were sent")
        XCTAssertEqual(received.map { $0.first }, (0..<sizes.count).map { UInt8(0x41 + $0) })
    }

    func testSendTerminalBeforeAnyConnectionIsDroppedWithoutCrashing() {
        let c = NostromodClient(socketPath: "/tmp/nsfd-none-\(getpid())-\(UUID().uuidString.prefix(8)).sock")
        c.sendTerminal(.attach(terminalId: "t1"))
        XCTAssertFalse(c.hasConnection)
    }
}


// MARK: - Background task frames (BA0)

// `session_tasks` / `session_task_detail` through the Mac client's own decoder
// (`NostromodClient.decode(type_:json:raw:)`), mirroring `TaskWireTests` in NostromoKit: the
// two decoders must agree on every version-skew case. Optional fields are OMITTED on the wire
// when absent (src/ipc/protocol.rs `TaskMeta`); unknown keys and enum values never cost a frame.

final class BackgroundTaskWireDecodeTests: XCTestCase {

    // MARK: - Fixtures

    /// Every `TaskMeta` field present, and every value distinguishable from its default.
    private let fullTask = """
    {"id":"b7k2x9","run_id":"run-0042","task_type":"local_agent","kind":"agent",
     "tool_name":"Agent","description":"Audit the wire types","subagent_type":"general-purpose",
     "workflow_name":"nightly-audit","tool_use_id":"toolu_01ABC","parent_task_id":"a1b2c3",
     "is_backgrounded":true,"housekeeping":true,"status":"stopped","end_reason":"user_stop",
     "started_at_ms":1760000000123,"ended_at_ms":1760000090456,"duration_ms":90333,
     "total_tokens":5000000000,"tool_uses":17,"last_tool_name":"Grep","has_output":true}
    """

    private let minimalTask = """
    {"id":"m1","task_type":"local_bash","kind":"shell","description":"npm run dev",
     "housekeeping":false,"status":"running","has_output":false}
    """

    private func frame(tasks: String, extra: String = "") -> String {
        """
        {"type":"session_tasks","tag":"claudia","daemon_epoch":"epoch-1"\(extra),"tasks":[\(tasks)]}
        """
    }

    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    /// The Mac client's decoder, fed the way the socket reader feeds it.
    private func decode(_ json: String) -> ServerMsg {
        let raw = Data(json.utf8)
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let type = obj["type"] as? String else { return .unknown }
        return client.decode(type_: type, json: obj, raw: raw)
    }

    private func snapshot(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTasksWire {
        guard case let .sessionTasks(s) = decode(json) else {
            XCTFail("expected .sessionTasks", file: file, line: line)
            throw XCTSkip("not a session_tasks frame")
        }
        return s
    }

    private func detail(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTaskDetailWire {
        guard case let .sessionTaskDetail(d) = decode(json) else {
            XCTFail("expected .sessionTaskDetail", file: file, line: line)
            throw XCTSkip("not a session_task_detail frame")
        }
        return d
    }

    private func isUnknownFrame(_ msg: ServerMsg) -> Bool {
        if case .unknown = msg { return true }
        return false
    }

    // MARK: - session_tasks: full frame

    func testFullSessionTasksFrameDecodesEveryField() throws {
        let s = try snapshot(frame(tasks: fullTask, extra: #","session_id":"sess-9","stop_supported":true"#))
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.sessionId, "sess-9")
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
        XCTAssertEqual(s.stopSupported, true)
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }

        XCTAssertEqual(t.id, "b7k2x9")
        XCTAssertEqual(t.runId, "run-0042")
        XCTAssertEqual(t.taskType, "local_agent")
        XCTAssertEqual(t.kind, .agent)
        XCTAssertEqual(t.toolName, "Agent")
        XCTAssertEqual(t.description, "Audit the wire types")
        XCTAssertEqual(t.subagentType, "general-purpose")
        XCTAssertEqual(t.workflowName, "nightly-audit")
        XCTAssertEqual(t.toolUseId, "toolu_01ABC")
        XCTAssertEqual(t.parentTaskId, "a1b2c3")
        XCTAssertEqual(t.isBackgrounded, true)
        XCTAssertTrue(t.housekeeping)
        XCTAssertEqual(t.status, .stopped)
        XCTAssertEqual(t.endReason, .userStop)
        XCTAssertEqual(t.startedAtMs, 1_760_000_000_123 as UInt64)
        XCTAssertEqual(t.endedAtMs, 1_760_000_090_456 as UInt64)
        XCTAssertEqual(t.durationMs, 90_333 as UInt64)
        XCTAssertEqual(t.totalTokens, 5_000_000_000 as UInt64, "token counts exceed 32 bits")
        XCTAssertEqual(t.toolUses, 17 as UInt64)
        XCTAssertEqual(t.lastToolName, "Grep")
        XCTAssertTrue(t.hasOutput)
    }

    func testStopSupportedFalseIsDistinctFromUnknown() throws {
        let s = try snapshot(frame(tasks: minimalTask, extra: #","stop_supported":false"#))
        XCTAssertEqual(s.stopSupported, false)
    }

    func testEveryKnownKindStatusAndEndReasonDecodes() throws {
        let kinds = ["shell", "monitor", "agent", "workflow", "other"]
        let statuses = ["pending", "running", "paused", "completed", "failed", "stopped"]
        let reasons = ["user_stop", "restart", "session_ended", "vanished"]
        var tasks: [String] = []
        for (i, k) in kinds.enumerated() {
            tasks.append(#"{"id":"k\#(i)","task_type":"","kind":"\#(k)","description":"","housekeeping":false,"status":"running","has_output":false}"#)
        }
        for (i, st) in statuses.enumerated() {
            tasks.append(#"{"id":"s\#(i)","task_type":"","kind":"shell","description":"","housekeeping":false,"status":"\#(st)","has_output":false}"#)
        }
        for (i, r) in reasons.enumerated() {
            tasks.append(#"{"id":"r\#(i)","task_type":"","kind":"shell","description":"","housekeeping":false,"status":"stopped","end_reason":"\#(r)","has_output":false}"#)
        }
        let s = try snapshot(frame(tasks: tasks.joined(separator: ",")))
        XCTAssertEqual(s.tasks.count, 15)
        guard s.tasks.count == 15 else { return }
        XCTAssertEqual(s.tasks[0..<5].map(\.kind), [.shell, .monitor, .agent, .workflow, .other])
        XCTAssertEqual(s.tasks[5..<11].map(\.status), [.pending, .running, .paused, .completed, .failed, .stopped])
        XCTAssertEqual(s.tasks[11..<15].map(\.endReason), [.userStop, .restart, .sessionEnded, .vanished])
    }

    // MARK: - session_tasks: minimal frame

    func testMinimalSessionTasksFrameDecodesWithAllOptionalsNil() throws {
        let s = try snapshot(frame(tasks: minimalTask))
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
        XCTAssertNil(s.sessionId)
        XCTAssertNil(s.stopSupported, "absent means the daemon does not know yet, not false")
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }

        XCTAssertEqual(t.id, "m1")
        XCTAssertEqual(t.taskType, "local_bash")
        XCTAssertEqual(t.kind, .shell)
        XCTAssertEqual(t.description, "npm run dev")
        XCTAssertFalse(t.housekeeping)
        XCTAssertEqual(t.status, .running)
        XCTAssertFalse(t.hasOutput)

        XCTAssertNil(t.runId)
        XCTAssertNil(t.toolName)
        XCTAssertNil(t.subagentType)
        XCTAssertNil(t.workflowName)
        XCTAssertNil(t.toolUseId)
        XCTAssertNil(t.parentTaskId)
        XCTAssertNil(t.isBackgrounded)
        XCTAssertNil(t.endReason)
        XCTAssertNil(t.startedAtMs)
        XCTAssertNil(t.endedAtMs)
        XCTAssertNil(t.durationMs)
        XCTAssertNil(t.totalTokens)
        XCTAssertNil(t.toolUses)
        XCTAssertNil(t.lastToolName)
    }

    func testEmptyTasksArrayDecodesToAnEmptyList() throws {
        let s = try snapshot(frame(tasks: ""))
        XCTAssertEqual(s.tasks, [])
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
    }

    // MARK: - session_tasks: version skew

    func testUnknownKindStatusAndEndReasonDecodeAsUnknownWithoutCostingTheFrame() throws {
        let odd = """
        {"id":"odd","task_type":"remote_thing","kind":"teleporter","description":"from the future",
         "housekeeping":false,"status":"hibernating","end_reason":"cosmic_ray","has_output":false}
        """
        let s = try snapshot(frame(tasks: "\(minimalTask),\(odd),\(fullTask)"))
        XCTAssertEqual(s.tasks.map(\.id), ["m1", "odd", "b7k2x9"], "the neighbours of an unknown-valued task still decode")
        guard s.tasks.count == 3 else { return }
        let t = s.tasks[1]
        XCTAssertEqual(t.kind, .unknown("teleporter"))
        XCTAssertEqual(t.status, .unknown("hibernating"))
        XCTAssertEqual(t.endReason, .unknown("cosmic_ray"))
        XCTAssertEqual(t.description, "from the future", "the rest of the entry is intact")
    }

    func testAnUnknownStatusIsNotTerminalSoTheTaskStaysVisible() {
        XCTAssertFalse(TaskStatusWire.unknown("hibernating").isTerminal)
        XCTAssertFalse(TaskStatusWire.pending.isTerminal)
        XCTAssertFalse(TaskStatusWire.running.isTerminal)
        XCTAssertFalse(TaskStatusWire.paused.isTerminal)
        XCTAssertTrue(TaskStatusWire.completed.isTerminal)
        XCTAssertTrue(TaskStatusWire.failed.isTerminal)
        XCTAssertTrue(TaskStatusWire.stopped.isTerminal)
    }

    func testUnknownFieldsAtFrameAndTaskLevelAreIgnored() throws {
        let task = """
        {"id":"x1","task_type":"local_bash","kind":"shell","description":"d","housekeeping":false,
         "status":"running","has_output":true,"brand_new_field":{"nested":[1,2,3]},"another":"v"}
        """
        let json = """
        {"type":"session_tasks","tag":"claudia","daemon_epoch":"e","future_top_level":42,
         "tasks":[\(task)],"also_new":["a"]}
        """
        let s = try snapshot(json)
        XCTAssertEqual(s.tasks.map(\.id), ["x1"])
        XCTAssertEqual(s.tasks.first?.hasOutput, true)
        XCTAssertEqual(s.daemonEpoch, "e")
    }

    func testAMalformedTaskEntryIsDroppedAndTheOthersStillDecode() throws {
        let noId = #"{"task_type":"local_bash","kind":"shell","description":"no id","housekeeping":false,"status":"running","has_output":false}"#
        let wrongType = #"{"id":123,"task_type":"local_bash","kind":"shell","description":"id is a number","housekeeping":false,"status":"running","has_output":false}"#
        let tasks = [minimalTask, noId, #""just a string""#, "42", "null", wrongType, "[]", fullTask]
        let s = try snapshot(frame(tasks: tasks.joined(separator: ",")))
        XCTAssertEqual(s.tasks.map(\.id), ["m1", "b7k2x9"], "only the well-formed entries survive, in order")
    }

    func testAFrameWhoseEveryTaskIsMalformedDecodesToAnEmptyList() throws {
        let s = try snapshot(frame(tasks: #"{"description":"no id"},7"#))
        XCTAssertEqual(s.tasks, [])
    }

    func testHousekeepingAndHasOutputDefaultToFalseWhenAbsent() throws {
        let task = #"{"id":"d1","task_type":"local_bash","kind":"shell","description":"d","status":"running"}"#
        let s = try snapshot(frame(tasks: task))
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }
        XCTAssertFalse(t.housekeeping)
        XCTAssertFalse(t.hasOutput)
    }

    func testWireKeysAreSnakeCaseAndCamelCaseKeysDoNotPopulateFields() throws {
        let task = """
        {"id":"c1","taskType":"local_agent","task_type":"local_bash","kind":"shell","description":"d",
         "status":"stopped","housekeeping":false,
         "hasOutput":true,"isBackgrounded":true,"endReason":"restart","startedAtMs":1,"endedAtMs":2,
         "durationMs":3,"totalTokens":4,"toolUses":5,"lastToolName":"Edit","toolName":"Bash",
         "runId":"r","subagentType":"s","workflowName":"w","toolUseId":"u","parentTaskId":"p"}
        """
        let json = """
        {"type":"session_tasks","tag":"claudia","daemonEpoch":"camel","sessionId":"camel",
         "stopSupported":true,"tasks":[\(task)]}
        """
        let s = try snapshot(json)
        XCTAssertNil(s.sessionId)
        XCTAssertNil(s.stopSupported)
        XCTAssertNotEqual(s.daemonEpoch, "camel")
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }
        XCTAssertEqual(t.taskType, "local_bash", "the snake_case key wins; the camelCase one is ignored")
        XCTAssertFalse(t.hasOutput)
        XCTAssertNil(t.isBackgrounded)
        XCTAssertNil(t.endReason)
        XCTAssertNil(t.startedAtMs)
        XCTAssertNil(t.endedAtMs)
        XCTAssertNil(t.durationMs)
        XCTAssertNil(t.totalTokens)
        XCTAssertNil(t.toolUses)
        XCTAssertNil(t.lastToolName)
        XCTAssertNil(t.toolName)
        XCTAssertNil(t.runId)
        XCTAssertNil(t.subagentType)
        XCTAssertNil(t.workflowName)
        XCTAssertNil(t.toolUseId)
        XCTAssertNil(t.parentTaskId)
    }

    // MARK: - session_task_detail

    func testTaskDetailWithAllFourTextFieldsDecodes() throws {
        let d = try detail("""
        {"type":"session_task_detail","tag":"claudia","task_id":"b7k2x9",
         "preview":"Compiling NostromoKit...","progress_summary":"Reading the wire types",
         "completion_summary":"Found two gaps","prompt":"Audit the wire types"}
        """)
        XCTAssertEqual(d.tag, "claudia")
        XCTAssertEqual(d.taskId, "b7k2x9")
        XCTAssertEqual(d.preview, "Compiling NostromoKit...")
        XCTAssertEqual(d.progressSummary, "Reading the wire types")
        XCTAssertEqual(d.completionSummary, "Found two gaps")
        XCTAssertEqual(d.prompt, "Audit the wire types")
    }

    func testTaskDetailWithOnlyAPreviewDecodes() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"claudia","task_id":"m1","preview":"listening on :3000"}"#)
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertEqual(d.preview, "listening on :3000")
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
        XCTAssertNil(d.prompt)
    }

    func testTaskDetailWithNoTextFieldsDecodes() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"claudia","task_id":"m1"}"#)
        XCTAssertEqual(d.tag, "claudia")
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertNil(d.preview)
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
        XCTAssertNil(d.prompt)
    }

    func testTaskDetailIgnoresUnknownKeys() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"t","task_id":"m1","prompt":"p","new_thing":{"a":1},"tokens":9}"#)
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertEqual(d.prompt, "p")
    }

    func testTaskDetailWithCamelCaseKeysDoesNotPopulateFields() throws {
        let json = #"{"type":"session_task_detail","tag":"t","task_id":"m1","progressSummary":"x","completionSummary":"y"}"#
        let d = try detail(json)
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
    }

    func testTaskDetailWithoutASnakeCaseTaskIdIsNotUsable() {
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_task_detail","tag":"t","taskId":"m1","preview":"p"}"#)),
                      "a detail frame that names no task (camelCase `taskId` is not the wire key) cannot be attributed")
    }

    // MARK: - Neighbouring frame types

    func testAnUnknownFrameTypeStillYieldsUnknown() {
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_tasks_v2","tag":"t","daemon_epoch":"e","tasks":[]}"#)))
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_task_telepathy","tag":"t"}"#)))
    }

    func testTaskFramesDoNotDisturbDecodingOfOtherFrames() {
        guard case let .welcome(version, pid, _) = decode(#"{"type":"welcome","protocol_version":3,"daemon_pid":77}"#) else {
            return XCTFail("expected .welcome")
        }
        XCTAssertEqual(version, 3)
        XCTAssertEqual(pid, 77)
    }

    func testWelcomeWithEnabledAgentsDisablesTheOnesNotListed() {
        guard case let .welcome(_, _, enabled) = decode(#"{"type":"welcome","protocol_version":4,"daemon_pid":7,"enabled_agents":["mother","teri"]}"#) else {
            return XCTFail("expected .welcome")
        }
        XCTAssertFalse(enabled.isEnabled("fred"))
        XCTAssertTrue(enabled.isEnabled("teri"))
    }

    func testWelcomeWithoutEnabledAgentsEnablesEverything() {
        guard case let .welcome(_, _, enabled) = decode(#"{"type":"welcome","protocol_version":4,"daemon_pid":7}"#) else {
            return XCTFail("expected .welcome")
        }
        XCTAssertEqual(enabled, .all)
    }
    // MARK: - session_task_stop_result / session_task_output_result (BA1)
    //
    // The same cases as `TaskWireTests` in NostromoKit, through the Mac client's decoder. The JSON
    // is exactly what the daemon serialises (golden strings in `src/ipc/protocol.rs`): `message`,
    // `source` are OMITTED when absent.

    private func stopResult(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTaskStopResultWire {
        guard case let .sessionTaskStopResult(r) = decode(json) else {
            XCTFail("expected .sessionTaskStopResult", file: file, line: line)
            throw XCTSkip("not a session_task_stop_result frame")
        }
        return r
    }

    private func outputResult(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTaskOutputResultWire {
        guard case let .sessionTaskOutputResult(r) = decode(json) else {
            XCTFail("expected .sessionTaskOutputResult", file: file, line: line)
            throw XCTSkip("not a session_task_output_result frame")
        }
        return r
    }

    func testAnAcceptedStopResultDecodesWithNoMessage() throws {
        let r = try stopResult(#"{"type":"session_task_stop_result","request_id":"r1","tag":"cody-1","task_id":"t1","outcome":"accepted"}"#)
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.tag, "cody-1")
        XCTAssertEqual(r.taskId, "t1")
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertNil(r.message)
    }

    func testARefusedStopResultCarriesTheClisMessage() throws {
        let r = try stopResult(#"{"type":"session_task_stop_result","request_id":"r2","tag":"cody-1","task_id":"t1","outcome":"refused","message":"StopTask: not stoppable"}"#)
        XCTAssertEqual(r.outcome, .refused)
        XCTAssertEqual(r.message, "StopTask: not stoppable")
    }

    func testEveryStopOutcomeDecodesByItsWireName() throws {
        let expected: [(String, TaskStopOutcomeWire)] = [
            ("accepted", .accepted), ("refused", .refused), ("timeout", .timeout),
            ("unsupported", .unsupported), ("not_running", .notRunning),
        ]
        for (name, outcome) in expected {
            let r = try stopResult(#"{"type":"session_task_stop_result","request_id":"r","tag":"t","task_id":"x","outcome":"\#(name)"}"#)
            XCTAssertEqual(r.outcome, outcome, name)
        }
    }

    func testAnUnknownStopOutcomeDecodesAsUnknownWithoutCostingTheFrame() throws {
        let r = try stopResult(#"{"type":"session_task_stop_result","request_id":"r","tag":"t","task_id":"x","outcome":"exploded","message":"m"}"#)
        XCTAssertEqual(r.outcome, .unknown("exploded"))
        XCTAssertEqual(r.message, "m")
        XCTAssertEqual(r.requestId, "r")
    }

    func testAStopResultThatCannotBeCorrelatedIsNotUsable() {
        for json in [
            #"{"type":"session_task_stop_result","tag":"t","task_id":"x","outcome":"accepted"}"#,
            #"{"type":"session_task_stop_result","request_id":"r","tag":"t","outcome":"accepted"}"#,
            #"{"type":"session_task_stop_result","request_id":"r","tag":"t","task_id":"x"}"#,
            #"{"type":"session_task_stop_result","requestId":"r","tag":"t","taskId":"x","outcome":"accepted"}"#,
        ] {
            XCTAssertTrue(isUnknownFrame(decode(json)), json)
        }
    }

    func testAFullOutputResultDecodesEveryField() throws {
        let r = try outputResult("""
        {"type":"session_task_output_result","request_id":"r1","tag":"cody-1","task_id":"t1","outcome":"ok",
         "text":"line one\\nline two\\n","start_offset":100,"end_offset":118,"total_bytes":4096,
         "source":"cli_tail","message":"a note"}
        """)
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.tag, "cody-1")
        XCTAssertEqual(r.taskId, "t1")
        XCTAssertEqual(r.outcome, .ok)
        XCTAssertEqual(r.text, "line one\nline two\n")
        XCTAssertEqual(r.startOffset, 100)
        XCTAssertEqual(r.endOffset, 118)
        XCTAssertEqual(r.totalBytes, 4096)
        XCTAssertEqual(r.source, .cliTail)
        XCTAssertEqual(r.message, "a note")
    }

    func testAMinimalOutputResultHasNoSourceAndNoMessage() throws {
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r2","tag":"cody-1","task_id":"t1","outcome":"unavailable","text":"","start_offset":0,"end_offset":0,"total_bytes":0}"#)
        XCTAssertEqual(r.outcome, .unavailable)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual([r.startOffset, r.endOffset, r.totalBytes], [0, 0, 0])
        XCTAssertNil(r.source)
        XCTAssertNil(r.message)
    }

    func testEveryOutputOutcomeAndSourceDecodesByItsWireName() throws {
        let outcomes: [(String, TaskOutputOutcomeWire)] = [("ok", .ok), ("unavailable", .unavailable), ("refused", .refused), ("error", .error)]
        for (name, outcome) in outcomes {
            let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"\#(name)","text":"","start_offset":0,"end_offset":0,"total_bytes":0}"#)
            XCTAssertEqual(r.outcome, outcome, name)
        }
        let sources: [(String, TaskOutputSourceWire)] = [("file", .file), ("cli_tail", .cliTail)]
        for (name, source) in sources {
            let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"ok","text":"","start_offset":0,"end_offset":0,"total_bytes":0,"source":"\#(name)"}"#)
            XCTAssertEqual(r.source, source, name)
        }
    }

    func testAnUnknownOutputOutcomeOrSourceDecodesAsUnknownWithoutCostingTheFrame() throws {
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"throttled","text":"partial","start_offset":1,"end_offset":8,"total_bytes":9,"source":"s3"}"#)
        XCTAssertEqual(r.outcome, .unknown("throttled"))
        XCTAssertEqual(r.source, .unknown("s3"))
        XCTAssertEqual(r.text, "partial")
        XCTAssertEqual([r.startOffset, r.endOffset, r.totalBytes], [1, 8, 9])
    }

    func testOutputResultFieldsOmittedByAnOlderOrNewerDaemonDefaultInsteadOfCostingTheFrame() throws {
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"error","message":"the session has no such task"}"#)
        XCTAssertEqual(r.outcome, .error)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual([r.startOffset, r.endOffset, r.totalBytes], [0, 0, 0])
        XCTAssertEqual(r.message, "the session has no such task")
    }

    func testOutputOffsetsBeyondFourGibibytesDecodeExactly() throws {
        let big: UInt64 = 5 * 1024 * 1024 * 1024 + 7
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"ok","text":"x","start_offset":\#(big),"end_offset":\#(big + 1),"total_bytes":\#(big + 1),"source":"file"}"#)
        XCTAssertEqual(r.startOffset, big)
        XCTAssertEqual(r.endOffset, big + 1)
        XCTAssertEqual(r.totalBytes, big + 1)
    }

    func testOutputTextKeepsUnicodeQuotesAndLineBreaksExactly() throws {
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","outcome":"ok","text":"café ✓ 😀 \"quoted\" back\\slash\ttab\nnext\r\n","start_offset":0,"end_offset":40,"total_bytes":40,"source":"file"}"#)
        XCTAssertEqual(r.text, "caf\u{e9} \u{2713} \u{1F600} \"quoted\" back\\slash\ttab\nnext\r\n")
    }

    func testTheTypedRefusalOfAnOutputReadDecodesWithNoText() throws {
        let r = try outputResult(#"{"type":"session_task_output_result","request_id":"net-1","tag":"cody-1","task_id":"t1","outcome":"refused","text":"","start_offset":0,"end_offset":0,"total_bytes":0,"message":"requires_secure_connection: this needs a secure connection"}"#)
        XCTAssertEqual(r.outcome, .refused)
        XCTAssertEqual(r.text, "")
        XCTAssertTrue(r.message?.hasPrefix("requires_secure_connection") == true)
        XCTAssertNil(r.source)
    }

    func testAnOutputResultThatCannotBeCorrelatedIsNotUsable() {
        for json in [
            #"{"type":"session_task_output_result","tag":"t","task_id":"x","outcome":"ok","text":""}"#,
            #"{"type":"session_task_output_result","request_id":"r","tag":"t","outcome":"ok","text":""}"#,
            #"{"type":"session_task_output_result","request_id":"r","tag":"t","task_id":"x","text":""}"#,
            #"{"type":"session_task_output_result","requestId":"r","tag":"t","taskId":"x","outcome":"ok","startOffset":1}"#,
        ] {
            XCTAssertTrue(isUnknownFrame(decode(json)), json)
        }
    }
}
