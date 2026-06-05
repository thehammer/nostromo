import XCTest
import Combine

// NostromodClient, DaemonStopReason, ServerMsg, DaemonSessionState,
// ChatSession, SessionHealth, ChatModels, Models are compiled into this
// test target directly (logic test — no host app).

// MARK: - DaemonStopReasonDecodeTests

/// Verify `DaemonStopReason` JSON decoding, including the safe-fallback for
/// unknown strings (future variants must never cause a false-positive alarm).
final class DaemonStopReasonDecodeTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decode(_ raw: String) throws -> DaemonStopReason {
        let data = "\"\(raw)\"".data(using: .utf8)!
        return try decoder.decode(DaemonStopReason.self, from: data)
    }

    func testKnownValuesDecodeCorrectly() throws {
        XCTAssertEqual(try decode("user"),              .user)
        XCTAssertEqual(try decode("crash_loop_guard"),  .crashLoopGuard)
        XCTAssertEqual(try decode("stale_id"),          .staleId)
    }

    func testUnknownStringFallsBackToUser() throws {
        // Any future `StopReason` variant the Swift client hasn't seen yet
        // must decode as `.user` (benign) to avoid a false-positive alarm.
        XCTAssertEqual(try decode("some_future_variant"), .user)
        XCTAssertEqual(try decode(""),                    .user)
        XCTAssertEqual(try decode("CRASH_LOOP_GUARD"),    .user)   // case-sensitive
    }
}

// MARK: - ChatSessionHealthTests

/// Verify `ChatSession.health` state-machine transitions driven by daemon
/// broadcast messages. We create a real `NostromodClient` without calling
/// `start()` so it never connects, then pump `ServerMsg` values directly
/// through its `messages` subject.
///
/// `ChatSession` uses `receive(on: DispatchQueue.main)` so after each send
/// we wait on an `XCTestExpectation` — `waitForExpectations` spins the
/// main run-loop, which flushes the queued handler.
final class ChatSessionHealthTests: XCTestCase {

    private var client:  NostromodClient!
    private var session: ChatSession!
    private var bag:     Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        // Path won't be connected; don't call start().
        client  = NostromodClient(socketPath: "/dev/null")
        session = ChatSession(tag: "test", agentName: "cody", displayName: "Cody",
                              workingDirectory: nil, client: client)
    }

    override func tearDown() {
        bag.removeAll()
        session = nil
        client  = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Send a message and wait until `session.health` equals `expected`.
    private func sendAndExpect(_ msg: ServerMsg, health expected: SessionHealth,
                               file: StaticString = #file, line: UInt = #line) {
        let exp = expectation(description: "health → \(expected)")
        session.$health
            .dropFirst()                  // skip current value
            .filter { $0 == expected }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &bag)
        client.messages.send(msg)
        waitForExpectations(timeout: 1, handler: nil)
    }

    // MARK: - Tests

    func testCrashedStateBecomesRecovering() {
        sendAndExpect(
            .sessionState(tag: "test", state: .crashed),
            health: .recovering
        )
    }

    func testCrashLoopGuardBecomespermanentlyDown() {
        sendAndExpect(
            .sessionDown(tag: "test", reason: .crashLoopGuard),
            health: .permanentlyDown(.crashLoopGuard)
        )
    }

    func testUserStopBecomesHealthy() {
        // First put the session into a non-healthy state.
        sendAndExpect(
            .sessionState(tag: "test", state: .crashed),
            health: .recovering
        )

        // A user-requested stop clears the indicator.
        sendAndExpect(
            .sessionDown(tag: "test", reason: .user),
            health: .healthy
        )
    }

    func testIdleAfterCrashBecomesHealthy() {
        // Crash the session.
        sendAndExpect(
            .sessionState(tag: "test", state: .crashed),
            health: .recovering
        )

        // Daemon recovers and comes back idle → health clears.
        sendAndExpect(
            .sessionState(tag: "test", state: .idle),
            health: .healthy
        )
    }

    func testDismissSuppressesUntilNextHealthChange() {
        // Put session into permanentlyDown.
        sendAndExpect(
            .sessionDown(tag: "test", reason: .crashLoopGuard),
            health: .permanentlyDown(.crashLoopGuard)
        )
        XCTAssertEqual(session.health, .permanentlyDown(.crashLoopGuard))

        // Dismiss — isDismissed flips, health value itself is unchanged.
        session.dismissHealth()
        XCTAssertTrue(session.isDismissed, "isDismissed should be true after dismiss")
        XCTAssertEqual(session.health, .permanentlyDown(.crashLoopGuard),
                       "health value must not change on dismiss")

        // A new health transition clears isDismissed.
        sendAndExpect(
            .sessionState(tag: "test", state: .idle),
            health: .healthy
        )
        XCTAssertFalse(session.isDismissed, "isDismissed should clear on next health change")
    }

    func testMessagesForOtherTagsAreIgnored() {
        // Events for a different tag must not affect this session.
        client.messages.send(.sessionState(tag: "other", state: .crashed))
        // Give the main queue a tick to process anything that might have slipped through.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(session.health, .healthy,
                       "foreign-tag events must not change health")
    }
}
