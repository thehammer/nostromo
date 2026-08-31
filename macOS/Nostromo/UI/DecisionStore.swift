import Foundation

/// How a daemon-driven decision request was resolved.
enum DecisionAnswerRecord: Equatable {
    /// The operator chose this option's id.
    case choice(String)
    /// The operator dismissed the modal without choosing.
    case dismissed
}

/// The app-wide, atomic answer-once gate and exactly-once-presentation gate
/// for daemon-driven decision requests — held **outside** any sheet, window,
/// or view, the same discipline `TurnInteractionStore` documents for
/// `AskQuestionView`.
///
/// This store exists to fix a real, observed bug: Nostromo opens one
/// full-screen window per attached display, and each window used to
/// independently subscribe to decision requests and present its own sheet —
/// so one `ask_decision` call produced N sheets, and answering one didn't
/// dismiss the others. Two independent claims are tracked here, and they
/// must stay independent:
///
/// - **Answer-once** (`claimAnswer`/`resolution(for:)`): has this request
///   already been resolved, by ANY window, and what was the resolution?
///   First writer wins; every later attempt is told "no" and the original
///   resolution is left untouched. This is what makes a second, contradictory
///   answer structurally impossible on the client — not merely caught
///   downstream by the daemon's own `AlreadyAnswered` guard.
/// - **Exactly-once presentation** (`claimPresentation`/`releasePresentation`):
///   is some window CURRENTLY showing a sheet for this request right now?
///   This is what makes presentation happen on at most one window at a time,
///   independent of whether the request has been answered yet.
///
/// Bounded on purpose. Resolved answers are tracked in a fixed-size FIFO
/// (cap 64) rather than kept forever or `forget()`-ed on sheet close — the
/// latter is exactly the bug class RC3 introduced: forgetting a resolution
/// the instant ONE sheet closes re-arms every OTHER still-open sheet for the
/// same request. Decisions are rare, operator-paced events, not a firehose,
/// so a small bounded cap comfortably covers any plausible late/duplicate
/// frame while staying bounded on purpose — the same discipline the previous
/// (unbounded) version of this store documented, now backed by an actual
/// cap. An id currently claimed for presentation is never evicted, so a sheet
/// that's still on screen can never have its answer-of-record vanish out from
/// under it.
///
/// All access is expected from the main thread — every real caller reaches
/// this via Combine's `.receive(on: .main)` or an AppKit action — and the
/// claim semantics (single source of truth for "who got there first") depend
/// on that. Enforced with `assert(Thread.isMainThread)` rather than
/// `@MainActor`/an actor, which would ripple through every AppKit call site
/// for no benefit here.
final class DecisionStore {

    /// App-wide instance. Decision resolutions and presentation claims must
    /// be visible from whichever window happens to receive the next
    /// broadcast for the same request, so this is a singleton like
    /// `AppStore.shared` and `FocusStore.shared` rather than one instance per
    /// window.
    static let shared = DecisionStore()

    init() {}

    /// Resolved-request tracking is capped at this many entries. Decisions
    /// are rare, operator-paced events (not a firehose), so this comfortably
    /// covers any plausible late or duplicate frame while staying bounded on
    /// purpose.
    private static let maxTrackedResolutions = 64

    /// requestId → its resolution, for every request this store has claimed
    /// the answer for and not yet evicted.
    private var resolutions: [String: DecisionAnswerRecord] = [:]
    /// FIFO eviction order for `resolutions` — oldest first.
    private var resolutionOrder: [String] = []
    /// requestId → currently has a live presentation claim (some window is
    /// showing its sheet right now). Independent of `resolutions`.
    private var presenting: Set<String> = []

    // MARK: - Answer-once

    /// Record `requestId`'s resolution IF this is the first successful claim
    /// for it. Returns `true` iff this call is the one that recorded it (the
    /// caller is now the answer-of-record and may proceed to forward the
    /// answer over the wire); `false` if `requestId` was already claimed —
    /// the existing record is left completely untouched, and the caller must
    /// NOT forward anything.
    func claimAnswer(requestId: String, record: DecisionAnswerRecord) -> Bool {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        guard resolutions[requestId] == nil else { return false }
        resolutions[requestId] = record
        resolutionOrder.append(requestId)
        evictIfNeeded()
        return true
    }

    /// `requestId`'s resolution, if any has been claimed. `nil` for an
    /// unresolved (or evicted) request.
    func resolution(for requestId: String) -> DecisionAnswerRecord? {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        return resolutions[requestId]
    }

    /// Forget a tracked resolution early (for tests/diagnostics). The app
    /// itself no longer calls this in the normal flow — letting a sheet's
    /// close trigger a forget is exactly the RC3 hazard this store exists to
    /// close (the first sheet to close would re-arm every other one still on
    /// screen). Does not affect presentation-claim state.
    func forget(requestId: String) {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        resolutions.removeValue(forKey: requestId)
        resolutionOrder.removeAll { $0 == requestId }
    }

    /// Currently-tracked (not yet evicted) resolution count. For tests and
    /// diagnostics.
    var trackedRequestCount: Int {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        return resolutions.count
    }

    // MARK: - Exactly-once presentation

    /// True iff this call is the first presentation claim for `requestId`
    /// since the last matching `releasePresentation` (or ever, if none).
    /// False while another claim is still outstanding — the caller must not
    /// present a sheet for this id.
    func claimPresentation(requestId: String) -> Bool {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        guard !presenting.contains(requestId) else { return false }
        presenting.insert(requestId)
        return true
    }

    /// Release `requestId`'s presentation claim so a future
    /// `claimPresentation` for the same id can succeed again.
    func releasePresentation(requestId: String) {
        assert(Thread.isMainThread, "DecisionStore must only be touched from the main thread")
        presenting.remove(requestId)
    }

    // MARK: - Private

    /// Evict the oldest tracked resolution(s) until back at the cap —
    /// skipping (never evicting) any id that currently has a live
    /// presentation claim, so a sheet still on screen never has its
    /// answer-of-record vanish out from under it. If every tracked id is
    /// currently presenting, this simply stops (the cap is a best-effort
    /// bound, not a hard guarantee under that pathological case).
    private func evictIfNeeded() {
        while resolutionOrder.count > Self.maxTrackedResolutions {
            guard let evictIndex = resolutionOrder.firstIndex(where: { !presenting.contains($0) }) else {
                break
            }
            let evictedId = resolutionOrder.remove(at: evictIndex)
            resolutions.removeValue(forKey: evictedId)
        }
    }
}
