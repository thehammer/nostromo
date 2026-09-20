import XCTest
import Combine

// NostromodClient, ServerMsg, ChatSession, DaemonTurn, DaemonSessionState are
// compiled into this test target directly (logic test — no host app), same
// idiom as ChatSessionCompactionTests / SessionHealthTests.
//
// RED phase: `ChatSession.attachCount`, `ChatSession.isDetached`, and
// `ChatSession.detach()` do not exist yet. Every test in this file references
// them as real Swift symbols (not just as text), so the WHOLE FILE fails to
// COMPILE until Cody adds them — that is the correct RED-phase result, not a
// bug in these tests (same spirit as ActivityTickerWiringTests' documented
// "fails because the file doesn't exist yet").

/// Regression coverage for RC2: a retained `ChatSession` in `AppStore`'s
/// `sessionRegistry` used to re-issue `session_spawn` on every daemon
/// reconnect (see `spawnAndAttach()`, driven by `client.connected`'s
/// false→true edge) — including for a focus/tab that had already been
/// closed. Closing a tab must permanently stop that resurrection, not just
/// hide the view. `detach()` is the mechanism: it tears down `cancellables`,
/// which unsubscribes from BOTH `client.connected` (no more respawns) and
/// `client.messages` (no more reacting to daemon traffic at all) in one shot.
final class ChatSessionDetachTests: XCTestCase {

    private var client:  NostromodClient!
    private var session: ChatSession!

    override func setUp() {
        super.setUp()
        // Path won't be connected; don't call start(). `client.connected` is a
        // CurrentValueSubject starting at `false`, so ChatSession's init does
        // not spawn anything until a test explicitly sends `true`.
        client  = NostromodClient(socketPath: "/dev/null")
        session = ChatSession(tag: "test", agentName: "cody", displayName: "Cody",
                              workingDirectory: nil, client: client)
    }

    override func tearDown() {
        session = nil
        client  = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// `spawnAndAttach()` runs synchronously inside the `client.connected` sink
    /// (which itself hops via `.receive(on: DispatchQueue.main)`), so nothing
    /// here can be observed synchronously right after a `send`. Poll the main
    /// run loop instead — same idiom as `ChatSessionCompactionTests.waitUntil`.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, pollInterval: TimeInterval = 0.02,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        return true
    }

    /// Pump the main run loop for a fixed interval without any condition to
    /// wait for — used to prove something did NOT happen, where there is no
    /// positive event to poll for.
    private func pump(_ interval: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    // MARK: - Tests

    /// Documents the bug/current behavior directly: every reconnect spawns a
    /// new agent. This must remain true whether or not the session has been
    /// detached is irrelevant here — this test never detaches. It exists so a
    /// future change that makes `spawnAndAttach()` itself idempotent-across-
    /// reconnects (rather than idempotent-per-connection, which is a daemon-
    /// side property) doesn't silently break the detach tests below by
    /// changing what they're actually proving.
    func testEveryReconnectSpawnsANewAgent() {
        client.connected.send(true)
        waitUntil { self.session.attachCount == 1 }
        XCTAssertEqual(session.attachCount, 1)

        client.connected.send(false)
        client.connected.send(true)
        waitUntil { self.session.attachCount == 2 }
        XCTAssertEqual(session.attachCount, 2)
    }

    /// The regression test for RC2 — a closed focus's agent must not respawn
    /// when the daemon restarts (or the socket merely reconnects).
    func testDetachStopsFurtherSpawnsOnReconnect() {
        client.connected.send(true)
        waitUntil { self.session.attachCount == 1 }

        session.detach()
        let countAtDetach = session.attachCount

        // Any number of further reconnect edges — none may spawn again.
        client.connected.send(false)
        client.connected.send(true)
        client.connected.send(false)
        client.connected.send(true)
        pump()

        XCTAssertEqual(session.attachCount, countAtDetach, """
            attachCount must stay frozen after detach() — a closed focus's agent must not \
            respawn when the daemon reconnects/restarts. This is exactly the resurrection bug \
            (RC2) this fix exists to close.
            """)
    }

    /// `cancellables.removeAll()` inside `detach()` tears down BOTH the
    /// `client.connected` subscription and the `client.messages` subscription
    /// (they're both stored in the same set — see `ChatSession.init`), so a
    /// detached session must also stop reacting to ANY daemon traffic.
    func testDetachIgnoresSubsequentDaemonTraffic() {
        client.connected.send(true)
        waitUntil { self.session.attachCount == 1 }

        session.detach()
        let turnsBefore  = session.turns.count
        let healthBefore = session.health

        let turn = DaemonTurn(id: "t0", userInput: "hello", timestamp: nil, blocks: [], isComplete: true)
        client.messages.send(.sessionTurns(tag: session.tag, turns: [turn]))
        client.messages.send(.sessionState(tag: session.tag, state: .crashed))
        pump()

        XCTAssertEqual(session.turns.count, turnsBefore,
                       "a detached session must not adopt a sessionTurns snapshot — handle(_:) must never run again after detach()")
        XCTAssertEqual(session.health, healthBefore,
                       "a detached session must not react to sessionState — handle(_:) must never run again after detach()")
    }

    func testDetachIsIdempotent() {
        client.connected.send(true)
        waitUntil { self.session.attachCount == 1 }

        session.detach()
        let countAfterFirstDetach = session.attachCount
        XCTAssertTrue(session.isDetached)

        session.detach()   // must not trap, must not change anything

        XCTAssertTrue(session.isDetached)
        XCTAssertEqual(session.attachCount, countAfterFirstDetach,
                       "a second detach() call must be a no-op")
    }

    /// `detach()` must be a purely client-side unsubscribe — no outbound frame
    /// to the daemon. `NostromodClient` exposes no observable outbound-message
    /// log, so this is a source-level fitness check instead: read
    /// `ChatSession.swift` as text (same idiom as
    /// `ActivityTickerWiringTests.tickerViewSource()`) and assert `detach()`'s
    /// body contains no `client.` call. This is a textual heuristic, not a
    /// control-flow proof — it can't see through an intermediate helper that
    /// itself calls `client.*`, but it directly catches the obvious mistake:
    /// reaching for `client.sessionControl`/`client.sessionSpawn`/etc. inside
    /// what should be a local-only teardown.
    func testDetachPutsNothingOnTheWire() throws {
        let source = try Self.chatSessionSource()
        let body = try Self.isolatedFunctionBody(named: "func detach()", in: source)
        XCTAssertFalse(body.contains("client."), """
            detach() must be a client-side-only unsubscribe (cancellables.removeAll()) — any \
            "client." call in its body means it accidentally sends a stop/control frame to the \
            daemon instead of just unsubscribing locally. (Textual heuristic, not a control-flow \
            proof — see the doc comment on this test.)
            """)
    }

    // Skipped intentionally: a test proving that AppStore.session(for:) hands
    // back a fresh ChatSession (attachCount == 0) after eviction would need
    // AppStore.swift compiled into this target. It is not in the
    // NostromoTests `TestSources` build phase (confirmed via
    // Nostromo.xcodeproj/project.pbxproj — AppStore.swift only appears under
    // the app target's `Sources`, never under `TestSources`), and adding it
    // there to force this one test is explicitly out of scope for this job.

    // MARK: - Source helpers

    private static func chatSessionSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/ChatSessionDetachTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/Data/ChatSession.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Isolates a function's body by counting braces from its first `{` after
    /// `signature` to the matching close. A textual heuristic, not a real
    /// parser — good enough to catch a stray `client.*` call in the body, not
    /// to prove anything about control flow.
    private static func isolatedFunctionBody(named signature: String, in source: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let sigRange = source.range(of: signature) else {
            XCTFail("\(signature) not found in ChatSession.swift", file: file, line: line)
            return ""
        }
        guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) has no body", file: file, line: line)
            return ""
        }
        var depth = 0
        var idx = openBrace
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openBrace)..<idx])
                }
            }
            idx = source.index(after: idx)
        }
        XCTFail("could not find a matching closing brace for \(signature)", file: file, line: line)
        return ""
    }
}
