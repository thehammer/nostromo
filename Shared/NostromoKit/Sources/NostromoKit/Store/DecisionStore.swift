// NostromoKit — DecisionStore.swift
//
// The atomic answer-once gate for daemon-driven decision requests
// (`nostromo.ask_decision`), shared by iOS's `DaemonStore` (ios-curated-
// view-parity W3). Ported from the post-multi-window-fix macOS
// `DecisionStore` (`macOS/Nostromo/UI/DecisionStore.swift`), with one
// deliberate difference: iOS presents at most one sheet at a time from a
// single app-wide queue (see `DaemonStore.pendingDecisions`), so there is no
// separate "exactly-once presentation" claim to track here — only the
// answer-once claim.
//
// This exists to close a real, observed bug class: without a store like
// this held OUTSIDE any view, a decision surface rebuilt for a request that
// was already resolved (by this client or another) can re-arm and send a
// second, possibly contradictory answer — the same failure class
// `TurnInteractionStore` exists to prevent for `AskQuestionView`, and the
// exact defect the macOS multi-window fix closed for decisions.

import Foundation

/// How a daemon-driven decision request was ultimately resolved, from this
/// client's point of view.
public enum DecisionResolutionRecord: Equatable {
    /// The operator picked this option's id (locally, or reported by the
    /// daemon as the winning answer from any client).
    case choice(String)
    /// The operator dismissed the modal without choosing (locally, or the
    /// daemon reported it dismissed on another client).
    case dismissed
    /// The daemon reported this request resolved some other way this client
    /// did not itself cause — `"answered"` (defensively, when no choice id
    /// accompanied it), `"timeout"`, or `"cancelled"`. Kept distinct from
    /// `.dismissed` so the UI can say *why* the request is gone rather than
    /// implying the operator dismissed it themselves.
    case resolvedElsewhere(String)
}

/// The app-wide, atomic answer-once gate for daemon-driven decision
/// requests — held **outside** any view, the same discipline
/// `TurnInteractionStore` documents for `AskQuestionView` and macOS's
/// `DecisionStore` documents for its own sheet.
///
/// Bounded on purpose. Resolved answers are tracked in a fixed-size FIFO
/// (cap 64) rather than kept forever — decisions are rare, operator-paced
/// events, not a firehose, so a small bounded cap comfortably covers any
/// plausible late or duplicate frame while staying bounded on purpose.
///
/// All access is expected from the main thread — `DaemonStore` is
/// `@MainActor`, and every SwiftUI action that reaches this runs there too —
/// and the claim semantics (single source of truth for "who got there
/// first") depend on that. Enforced with `assert(Thread.isMainThread)`
/// rather than `@MainActor`/an actor, which would ripple `await` through
/// every SwiftUI action for no benefit here.
public final class DecisionStore {

    public init() {}

    /// Resolved-request tracking is capped at this many entries. Decisions
    /// are rare, operator-paced events (not a firehose), so this comfortably
    /// covers any plausible late or duplicate frame while staying bounded on
    /// purpose.
    private static let maxTrackedResolutions = 64

    /// requestId → its resolution, for every request this store has claimed
    /// the answer for and not yet evicted.
    private var resolutions: [String: DecisionResolutionRecord] = [:]
    /// FIFO eviction order for `resolutions` — oldest first.
    private var resolutionOrder: [String] = []

    /// Record `requestId`'s resolution IF this is the first successful claim
    /// for it. Returns `true` iff this call is the one that recorded it (the
    /// caller is now the answer-of-record and may proceed to forward the
    /// answer over the wire); `false` if `requestId` was already claimed —
    /// the existing record is left completely untouched, and the caller must
    /// NOT forward anything.
    public func claimAnswer(requestId: String, record: DecisionResolutionRecord) -> Bool {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        guard resolutions[requestId] == nil else { return false }
        resolutions[requestId] = record
        resolutionOrder.append(requestId)
        evictIfNeeded()
        return true
    }

    /// `requestId`'s resolution, if any has been claimed. `nil` for an
    /// unresolved (or evicted) request.
    public func resolution(for requestId: String) -> DecisionResolutionRecord? {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        return resolutions[requestId]
    }

    /// Currently-tracked (not yet evicted) resolution count. For tests and
    /// diagnostics.
    public var trackedRequestCount: Int {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        return resolutions.count
    }

    // MARK: - Private

    /// Evict the oldest tracked resolution(s) until back at the cap.
    private func evictIfNeeded() {
        while resolutionOrder.count > Self.maxTrackedResolutions {
            let evictedId = resolutionOrder.removeFirst()
            resolutions.removeValue(forKey: evictedId)
        }
    }
}
