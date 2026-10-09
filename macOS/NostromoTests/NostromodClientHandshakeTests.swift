import XCTest
import Combine
import Darwin

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

        enum End {
            case never
            /// Close shortly after a `subscribe` naming this topic arrives.
            case afterSubscribeNaming(String)
            /// Close this long after the first `subscribe` arrives.
            case afterFirstSubscribe(delay: TimeInterval)
        }
    }

    struct Frame {
        let type: String
        let topics: [String]
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

        while !isStopped {
            if let at = closeAt, Date() >= at { return }
            guard pollReadable(conn, millis: 50) else { continue }
            guard let body = readFrame(conn),
                  let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let type = json["type"] as? String
            else { return }   // the client closed (or sent garbage)

            let topics = (json["topics"] as? [String]) ?? []
            lock.lock(); perConnection[index].append(Frame(type: type, topics: topics)); lock.unlock()

            switch type {
            case "hello":
                var welcome: [String: Any] = ["type": "welcome", "protocol_version": 4, "daemon_pid": 4242]
                if let features = script.features { welcome["features"] = features }
                writeFrame(conn, welcome)
            case "subscribe":
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

    override func tearDown() {
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
}
