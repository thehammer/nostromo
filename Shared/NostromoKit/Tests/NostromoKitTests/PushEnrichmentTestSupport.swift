// PushEnrichmentTestSupport.swift
//
// Test support for the W16 push-enrichment tests (`PushDetailFetcherTests`, `NotificationEnricherTests`):
// a deterministic clock the test advances by hand, a fake `PushDetailTransport` that answers, fails or
// stalls on that clock, and spin helpers that wait with `Task.yield` only.
//
// Nothing here sleeps on the wall clock. A test says "N sleepers are registered", then moves fake
// time; the budget logic under test cannot be satisfied by luck or slowness. The only real-time
// reading is the safety cap on the spin helpers, which bounds how long a FAILING test spins.

import Foundation
import XCTest
@testable import NostromoKit

// MARK: - Manual clock

/// A `DeadlineClock` whose time only moves when the test calls `advance(by:)`. `sleep(seconds:)`
/// suspends until fake time reaches its wake time; sleepers wake in wake-time order. A cancelled
/// sleeper throws `CancellationError`, like `Task.sleep`.
final class ManualClock: DeadlineClock, @unchecked Sendable {

    private struct Sleeper {
        let id: Int
        let wake: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    /// Fake seconds since the clock was made.
    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How many `sleep` calls are suspended right now.
    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(seconds: TimeInterval) async throws {
        let id = takeID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(id: id, seconds: seconds, continuation: continuation)
            }
        } onCancel: {
            self.cancelSleeper(id: id)
        }
    }

    /// Moves fake time forward, waking each sleeper whose time has come, earliest first. After each
    /// wake the woken task gets a chance to run (and to register its next sleep) before the next
    /// sleeper is woken.
    func advance(by seconds: TimeInterval) async {
        let target = now + seconds
        while let due = popNextSleeper(upTo: target) {
            due.resume()
            await settle()
        }
        setNow(target)
    }

    /// Gives other tasks a chance to run. Not a guarantee that they have; use `yieldUntil` for that.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Spins (yielding, never sleeping) until at least `count` sleepers are registered.
    func waitForSleepers(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await yieldUntil(timeout: timeout) { self.sleeperCount >= count }
    }

    /// Wakes every remaining sleeper with `CancellationError`, so no continuation is left dangling
    /// when a test ends.
    func drain() {
        lock.lock()
        let rest = sleepers
        sleepers = []
        lock.unlock()
        for sleeper in rest { sleeper.continuation.resume(throwing: CancellationError()) }
    }

    // MARK: Locked helpers (synchronous, so no lock is held across a suspension point)

    private func takeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func register(id: Int, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let wake = current + max(0, seconds)
        if wake <= current {
            lock.unlock()
            continuation.resume()
            return
        }
        sleepers.append(Sleeper(id: id, wake: wake, continuation: continuation))
        lock.unlock()
    }

    private func cancelSleeper(id: Int) {
        lock.lock()
        let index = sleepers.firstIndex { $0.id == id }
        let sleeper = index.map { sleepers.remove(at: $0) }
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    private func popNextSleeper(upTo target: TimeInterval) -> WakeToken? {
        lock.lock()
        defer { lock.unlock() }
        let due = sleepers.enumerated()
            .filter { $0.element.wake <= target }
            .min { ($0.element.wake, $0.element.id) < ($1.element.wake, $1.element.id) }
        guard let due else { return nil }
        sleepers.remove(at: due.offset)
        current = max(current, due.element.wake)
        return WakeToken(continuation: due.element.continuation)
    }

    private func setNow(_ time: TimeInterval) {
        lock.lock()
        current = max(current, time)
        lock.unlock()
    }

    private struct WakeToken {
        let continuation: CheckedContinuation<Void, Error>
        func resume() { continuation.resume() }
    }
}

// MARK: - Fake transport

struct FakeTransportError: Error {}

/// A `PushDetailTransport` that answers after some fake seconds on a `ManualClock`, or refuses.
/// It records what it was asked and whether the task running it was cancelled.
final class FakeDetailTransport: PushDetailTransport, @unchecked Sendable {

    enum Behaviour {
        /// Answers `Data` once `after` fake seconds have passed (0 answers at once).
        case reply(Data, after: TimeInterval)
        /// Throws at once, like a refused connection.
        case refuse
    }

    private let behaviour: Behaviour
    private let clock: ManualClock
    private let lock = NSLock()
    private var refs: [String] = []
    private var cancelled = false

    init(_ behaviour: Behaviour, clock: ManualClock) {
        self.behaviour = behaviour
        self.clock = clock
    }

    /// The `itemRef` of every request received, in order.
    var requestedRefs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return refs
    }

    /// Whether a request was cancelled while it waited.
    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func request(itemRef: String) async throws -> Data {
        record(itemRef)
        switch behaviour {
        case .refuse:
            throw FakeTransportError()
        case .reply(let data, let after):
            if after <= 0 { return data }
            let clock = self.clock
            return try await withTaskCancellationHandler {
                try await clock.sleep(seconds: after)
                return data
            } onCancel: {
                self.markCancelled()
            }
        }
    }

    private func record(_ itemRef: String) {
        lock.lock()
        refs.append(itemRef)
        lock.unlock()
    }

    private func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// MARK: - Frames

/// A `push_detail` frame as the primary sends it.
func detailFrame(itemRef: String, waiting: Bool = true,
                 text: String? = "Which database should the migration use?",
                 host: String? = "sendai") -> Data {
    var object: [String: Any] = ["type": "push_detail", "item_ref": itemRef, "waiting": waiting]
    if let text { object["text"] = text }
    if let host { object["host"] = host }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

// MARK: - Spin helpers

/// A value one task sets and another reads.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    var isSet: Bool { value != nil }

    func set(_ newValue: T) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}

/// Spins with `Task.yield` (never a sleep) until `condition` holds; `false` if `timeout` real
/// seconds pass first. The timeout only bounds a failing test.
func yieldUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        await Task.yield()
    }
    return true
}
