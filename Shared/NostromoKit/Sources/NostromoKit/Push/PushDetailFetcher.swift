// NostromoKit — PushDetailFetcher.swift
//
// Fetches one notification's detail line from the primary within a hard budget (W16). The
// Notification Service Extension has about 30 s of wall time and must always hand iOS a
// notification, so the whole fetch (connect, ask, answer, close) gets `budget` seconds and not a
// moment more: when the time is up, or anything at all goes wrong, the answer is `nil` and the
// caller delivers the contract content unchanged. Never an error, never a wait past the budget.
//
// The transport and the clock are injected, so tests drive a fake that stalls past the deadline on
// a fabricated clock, with no sleeping.

import Foundation

/// One round trip to the primary: connect, send `push_detail` for `itemRef`, return the reply's
/// bytes, close. It must honour task cancellation by closing its connection.
public protocol PushDetailTransport: Sendable {
    func request(itemRef: String) async throws -> Data
}

/// Sleeps for the deadline. The system clock in the extension; a manual clock in tests.
public protocol DeadlineClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemDeadlineClock: DeadlineClock {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

public struct PushDetailFetcher: Sendable {
    /// The most the extension waits: well under iOS's 30 s, and under the 5 s the operator is told to expect.
    public static let budget: TimeInterval = 4.0

    private let transport: PushDetailTransport
    private let clock: DeadlineClock

    public init(transport: PushDetailTransport, clock: DeadlineClock = SystemDeadlineClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// The detail for `itemRef`, or `nil` if the primary did not answer within `deadline` seconds
    /// (never more than `budget`), refused, could not be reached, or sent something that is not a
    /// `push_detail` for this item. `waiting: false` is surfaced as an answer, not hidden.
    public func fetch(itemRef: String, deadline: TimeInterval = PushDetailFetcher.budget) async -> PushDetailWire? {
        let seconds = min(max(deadline, 0), Self.budget)
        let transport = self.transport
        let clock = self.clock
        do {
            let data = try await withDeadline(seconds, sleep: { try await clock.sleep(seconds: $0) }) {
                try await transport.request(itemRef: itemRef)
            }
            guard let detail = PushDetailWire.parse(data), detail.itemRef == itemRef else { return nil }
            return detail
        } catch {
            return nil
        }
    }
}
