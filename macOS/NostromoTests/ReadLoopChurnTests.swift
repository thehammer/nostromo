import XCTest
import Combine
import Darwin

// The two socket read loops (daemon IPC, Mother broker) are `while true` loops inside one GCD
// block that returns only when the connection closes. GCD drains a worker's autorelease pool when
// the block it is running returns, so every Foundation object a frame created (the
// `JSONSerialization` tree and its `_NSJSONReader`, decoder temporaries) was kept for the life of
// the connection: on 2026-10-25 that was 16 million malloc blocks and 1.6 GB after 14.6 hours,
// 67,000 `_NSJSONReader`s among them, and a footprint permanently over the memory watchdog's line.
//
// These tests push thousands of frames through the REAL read loops over a real AF_UNIX socket and
// measure live malloc blocks while the connection is still open, which is exactly what the leak
// is: growth with the number of frames, visible only before the socket closes.

private enum ChurnMeter {
    static func blocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }
}

final class ReadLoopChurnTests: XCTestCase {

    /// Frames in the measured burst. Each carries about 20 small dictionaries, so a loop that keeps
    /// them grows by tens of blocks per frame, thousands of times over the allowance below.
    private static let burst = 3_000
    /// Blocks the burst may leave behind per frame, in total: bookkeeping and timing noise, not frames.
    private static let allowedBlocksPerFrame = 3

    private static func listenSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                path.utf8CString.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private static let padding: [[String: Any]] = (0 ..< 20).map {
        ["a": $0, "b": "value-\($0)", "c": [1, 2, 3], "d": ["nested": "x\($0)"]] as [String: Any]
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func assertBounded(_ growth: Int, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let allowed = Self.burst * Self.allowedBlocksPerFrame
        XCTAssertLessThan(growth, allowed,
                          "\(label): \(Self.burst) frames left \(growth) more live malloc blocks while the connection stayed open "
                          + "(allowed \(allowed)). The read loop keeps what each frame allocated until the socket closes: "
                          + "each frame needs its own autoreleasepool.", file: file, line: line)
    }

    // MARK: - Daemon IPC (NostromodClient.readLoop)

    func testTheDaemonReadLoopDoesNotAccumulateAFramesObjectsForTheLifeOfTheConnection() throws {
        let path = "/tmp/rlc-d-\(getpid())-\(UUID().uuidString.prefix(6)).sock"
        let listenFd = try Self.listenSocket(at: path)

        func frame(_ object: [String: Any]) -> Data {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            var len = UInt32(body.count).bigEndian
            var out = Data(bytes: &len, count: 4)
            out.append(body)
            return out
        }
        let state = frame(["type": "session_state", "tag": "rlc", "state": "idle", "pad": Self.padding])
        let welcome = frame(["type": "welcome", "protocol_version": 4, "daemon_pid": 1])
        let gate = DispatchSemaphore(value: 0)
        let burst = Self.burst
        var connFd: Int32 = -1
        let server = Thread {
            let conn = accept(listenFd, nil, nil)
            connFd = conn
            Self.writeAll(conn, welcome)
            for _ in 0 ..< 200 { Self.writeAll(conn, state) }
            gate.wait()
            for _ in 0 ..< burst { Self.writeAll(conn, state) }
        }
        server.start()

        let client = NostromodClient(socketPath: path)
        var received = 0
        let sub = client.messages.sink { if case .sessionState = $0 { received += 1 } }
        client.start()
        defer {
            sub.cancel()
            if connFd >= 0 { Darwin.close(connFd) }
            Darwin.close(listenFd)
            unlink(path)
        }

        pump(until: { received >= 200 })
        XCTAssertGreaterThanOrEqual(received, 200, "the warm-up frames never arrived")
        for _ in 0 ..< 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let before = ChurnMeter.blocksInUse()

        gate.signal()
        pump(until: { received >= 200 + burst })
        XCTAssertGreaterThanOrEqual(received, 200 + burst, "the burst never fully arrived")
        for _ in 0 ..< 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        assertBounded(ChurnMeter.blocksInUse() - before, label: "NostromodClient")
    }

    // MARK: - Mother broker (MotherBrokerClient.readLoop)

    func testTheBrokerReadLoopDoesNotAccumulateALinesObjectsForTheLifeOfTheConnection() throws {
        let path = "/tmp/rlc-b-\(getpid())-\(UUID().uuidString.prefix(6)).sock"
        let listenFd = try Self.listenSocket(at: path)

        func line(_ object: [String: Any]) -> Data {
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(0x0A)
            return data
        }
        let hello = line(["v": 1, "dir": "event", "t": "hello", "id": "0", "ts": "2026-06-01T00:00:00.000Z",
                          "data": ["protocol_version": 1, "capabilities": ["state"]] as [String: Any]])
        // A `ping` is parsed (the whole envelope becomes a dictionary tree) and then ignored, so what
        // the client keeps afterwards is purely what the read loop failed to release.
        let ping = line(["v": 1, "dir": "event", "t": "ping", "id": "1", "ts": "2026-06-01T00:00:00.000Z",
                         "data": ["pad": Self.padding] as [String: Any]])
        let gate = DispatchSemaphore(value: 0)
        let burst = Self.burst
        var connFd: Int32 = -1
        let server = Thread {
            let conn = accept(listenFd, nil, nil)
            connFd = conn
            Self.writeAll(conn, hello)
            for _ in 0 ..< 200 { Self.writeAll(conn, ping) }
            gate.wait()
            for _ in 0 ..< burst { Self.writeAll(conn, ping) }
            Self.writeAll(conn, line(["v": 1, "dir": "event", "t": "awaiting_notified", "id": "2",
                                      "ts": "2026-06-01T00:00:00.000Z",
                                      "data": ["transport": "marker", "ok": true] as [String: Any]]))
        }
        server.start()

        let client = MotherBrokerClient(socketPath: path)
        var sawMarker = false
        var sawWarmupMarker = false
        let sub = client.events.sink { event in
            if case .awaitingNotified(let transport, _) = event {
                if transport == "marker" { sawMarker = true } else { sawWarmupMarker = true }
            }
        }
        client.start()
        defer {
            sub.cancel()
            if connFd >= 0 { Darwin.close(connFd) }
            Darwin.close(listenFd)
            unlink(path)
        }
        _ = sawWarmupMarker

        // The warm-up pings produce no event, so give the loop a moment to take them in.
        for _ in 0 ..< 40 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let before = ChurnMeter.blocksInUse()

        gate.signal()
        pump(until: { sawMarker })
        XCTAssertTrue(sawMarker, "the burst never fully arrived (the marker frame follows it on the same socket)")
        for _ in 0 ..< 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        assertBounded(ChurnMeter.blocksInUse() - before, label: "MotherBrokerClient")
    }
}
