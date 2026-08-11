import Foundation

/// Splices a daemon attach snapshot into the transcript the client already has,
/// instead of replacing it.
///
/// ## Why this exists
///
/// `ChatSession` used to do `turns = snapshot.map(mapTurn)` on every
/// `.sessionTurns`. That had two consequences, and the second hid the first:
///
///  1. It **discarded** every turn older than the daemon's 30-turn attach
///     window. After a reconnect the model held 30 turns.
///  2. It minted a fresh `UUID` for each of those 30 turns. `ReplView` keys its
///     views by that id and never cleared them, so every reconnect appended 30
///     more turn views on top of the ones already there.
///
/// The leak in (2) is what made (1) invisible: the *displayed* transcript still
/// showed everything, as accumulated garbage views. Fixing the leak alone would
/// therefore regress visible scrollback from "everything since launch" to 30
/// turns. So the snapshot has to be reconciled, not replaced.
///
/// ## The merge
///
/// Both lists are contiguous windows onto the same record, and both end at the
/// newest turn the daemon knows about. So the overlap is "the tail of what we
/// retained" against "the head of the snapshot": if we retained turns 1…500 and
/// the snapshot is 471…500, then our last 30 are its first 30.
///
/// The reverse containment is also possible and also worth handling — we may
/// hold *fewer* turns than the snapshot carries (a client that just launched, or
/// one whose oldest turns were dropped by the retention cap). Then the snapshot
/// strictly contains what we have and adopting it wholesale *gains* history.
enum TurnReconciler {

    /// What the splice did, in enough detail for `ReplView` to update
    /// incrementally and for `ChatSession` to publish a precise `TurnChange`.
    struct Outcome {
        /// The reconciled transcript.
        let turns: [ChatTurn]
        /// Index into the *previous* `turns` array from which content changed.
        /// Everything before this index is byte-identical, same ids, same order —
        /// so `ReplView` need not touch the views for it.
        let replacedFrom: Int
        /// True when no common ground was found and the retained list was
        /// dropped wholesale. The only case in which turn views must be cleared.
        let didReplaceAll: Bool
        /// True when a `.gap` marker was inserted because history is genuinely
        /// missing between the retained turns and the snapshot.
        let insertedGapMarker: Bool
        /// How many retained turns the snapshot was found to overlap. Zero means
        /// no common ground (see `didReplaceAll` / `insertedGapMarker`).
        let overlap: Int
    }

    /// Only search this far back for an anchor when adopting an optimistic echo.
    /// Bounds the cost and, more importantly, stops an identical message sent an
    /// hour ago ("yes", "continue") from swallowing today's daemon turn.
    static let echoAdoptionWindow = 8

    // MARK: - Reconcile

    /// - Parameters:
    ///   - retained: what the client currently holds, oldest first.
    ///   - snapshot: the daemon's attach snapshot, already mapped to `ChatTurn`
    ///     and stamped with the new epoch, oldest first.
    ///   - sessionIdChanged: whether the daemon reported a different session id
    ///     than the one this client last saw. Only consulted when no overlap is
    ///     found, to tell "different conversation" from "we were away too long".
    static func reconcile(retained: [ChatTurn],
                          snapshot: [ChatTurn],
                          sessionIdChanged: Bool) -> Outcome {

        // An empty snapshot carries no information — a daemon that has not read
        // any turns yet must not be allowed to erase what we have.
        guard !snapshot.isEmpty else {
            return Outcome(turns: retained, replacedFrom: retained.count,
                           didReplaceAll: false, insertedGapMarker: false, overlap: 0)
        }

        // Optimistic echoes trailing the list have no record entry yet, so they
        // can never match anything in the snapshot. Held out of the merge and
        // re-appended, they stay pinned to the bottom where the operator put
        // them instead of forcing a spurious "no overlap" verdict.
        let split   = splitTrailingEchoes(retained)
        let body    = split.body
        let echoes  = split.echoes

        guard !body.isEmpty else {
            // Only pending echoes were retained, and they are re-appended with
            // their ids intact — so no history was dropped and no view needs to
            // be released.
            return finish(base: snapshot, echoes: echoes, replacedFrom: 0,
                          didReplaceAll: false, insertedGapMarker: false,
                          overlap: 0)
        }

        // Forward overlap: our tail is the snapshot's head. Prefer the largest
        // k, so a run of identical messages splices at the right place.
        if let k = forwardOverlap(body: body, snapshot: snapshot) {
            var merged = Array(body[0 ..< (body.count - k)])
            merged.reserveCapacity(merged.count + snapshot.count)
            for (i, turn) in snapshot.enumerated() {
                merged.append(i < k ? turn.carryingIdentity(of: body[body.count - k + i]) : turn)
            }
            return finish(base: merged, echoes: echoes,
                          replacedFrom: body.count - k, didReplaceAll: false,
                          insertedGapMarker: false, overlap: k)
        }

        // Reverse containment: the snapshot reaches further back than we do.
        // Adopting it is a strict gain, so long as our whole list is its tail.
        if snapshot.count > body.count, containsAsSuffix(snapshot: snapshot, body: body) {
            let offset = snapshot.count - body.count
            var merged = snapshot
            for i in 0 ..< body.count {
                merged[offset + i] = merged[offset + i].carryingIdentity(of: body[i])
            }
            return finish(base: merged, echoes: echoes, replacedFrom: 0,
                          didReplaceAll: false, insertedGapMarker: false,
                          overlap: body.count)
        }

        // No common ground.
        if sessionIdChanged {
            // A genuinely different conversation. Retained history belongs to
            // the old one and would be a lie if left on screen.
            return finish(base: snapshot, echoes: echoes, replacedFrom: 0,
                          didReplaceAll: true, insertedGapMarker: false, overlap: 0)
        }

        // Same record (or we never learned its id — never silently drop history
        // on the strength of a missing field). We were away for longer than the
        // daemon's attach window, so turns between the two are genuinely gone.
        // Say so, in place, rather than presenting a truncated transcript as
        // continuous.
        var merged = body
        merged.append(.marker(.gap, timestamp: snapshot.first?.timestamp ?? Date()))
        merged.append(contentsOf: snapshot)
        return finish(base: merged, echoes: echoes, replacedFrom: body.count,
                      didReplaceAll: false, insertedGapMarker: true, overlap: 0)
    }

    // MARK: - Matching

    /// Whether two views of the transcript refer to the same record entry.
    ///
    /// Matching is on `identityKey` — (record timestamp, user text) — and
    /// deliberately *not* on `contentKey`. Block shape is not invariant across
    /// the boundary this has to survive: a turn watched live carries a
    /// `resultSummary` block, and a turn re-read from the session JSONL after a
    /// daemon restart does not, because the stored record has no `result` lines.
    /// A turn interrupted mid-stream differs by however many blocks had arrived.
    ///
    /// The asymmetry of the two failure modes settles it. A false negative
    /// duplicates a turn — the exact bug being fixed, and visible. A false
    /// positive needs two turns sharing both a millisecond-resolution timestamp
    /// and their first 256 characters, which within one record does not happen.
    static func matches(_ a: ChatTurn, _ b: ChatTurn) -> Bool {
        // Markers are synthetic and belong to no record entry.
        guard a.marker == nil, b.marker == nil else { return false }
        // A turn with no timestamp at all carries too little to anchor identity;
        // refusing to match is the safe direction (it costs a gap marker, not a
        // wrong merge).
        guard a.timestampRaw != nil, b.timestampRaw != nil else { return false }
        return a.identityKey == b.identityKey
    }

    /// Largest `k ≥ 1` for which the last `k` of `body` are the first `k` of
    /// `snapshot`, or nil if there is no overlap.
    private static func forwardOverlap(body: [ChatTurn], snapshot: [ChatTurn]) -> Int? {
        var k = min(body.count, snapshot.count)
        while k >= 1 {
            var ok = true
            for i in 0 ..< k where !matches(body[body.count - k + i], snapshot[i]) {
                ok = false
                break
            }
            if ok { return k }
            k -= 1
        }
        return nil
    }

    /// Whether `body` is exactly the tail of `snapshot`.
    private static func containsAsSuffix(snapshot: [ChatTurn], body: [ChatTurn]) -> Bool {
        let offset = snapshot.count - body.count
        for i in 0 ..< body.count where !matches(snapshot[offset + i], body[i]) {
            return false
        }
        return true
    }

    // MARK: - Optimistic echoes

    private struct Split {
        let body:   [ChatTurn]
        let echoes: [ChatTurn]
    }

    /// Peels off the trailing run of locally-created turns the daemon has not
    /// acknowledged yet.
    private static func splitTrailingEchoes(_ turns: [ChatTurn]) -> Split {
        var cut = turns.count
        while cut > 0, turns[cut - 1].daemonId == nil, turns[cut - 1].marker == nil {
            cut -= 1
        }
        return Split(body: Array(turns[0 ..< cut]), echoes: Array(turns[cut...]))
    }

    /// Re-appends pending echoes, dropping any the snapshot turns out to have
    /// already recorded.
    ///
    /// Two things make this narrow rather than a blanket text match, because the
    /// failure direction here is losing a message the operator sent:
    ///
    ///   - Only turns the snapshot *newly* brought in (index ≥ `replacedFrom`)
    ///     can be the daemon's record of a pending echo. A match against history
    ///     we already held is just the operator saying "yes" twice.
    ///   - Matching is multiset, not set. If the record holds one "yes" and two
    ///     are pending, exactly one is absorbed and the other survives.
    private static func finish(base: [ChatTurn], echoes: [ChatTurn],
                               replacedFrom: Int, didReplaceAll: Bool,
                               insertedGapMarker: Bool, overlap: Int) -> Outcome {
        guard !echoes.isEmpty else {
            return Outcome(turns: base, replacedFrom: replacedFrom,
                           didReplaceAll: didReplaceAll,
                           insertedGapMarker: insertedGapMarker, overlap: overlap)
        }

        let floor = max(replacedFrom, base.count - echoAdoptionWindow, 0)
        var available: [String: Int] = [:]
        if floor < base.count {
            for turn in base[floor...] where turn.marker == nil {
                available[turn.userInput, default: 0] += 1
            }
        }

        var surviving: [ChatTurn] = []
        for echo in echoes {
            if let remaining = available[echo.userInput], remaining > 0 {
                available[echo.userInput] = remaining - 1
            } else {
                surviving.append(echo)
            }
        }

        return Outcome(turns: base + surviving,
                       replacedFrom: min(replacedFrom, base.count),
                       didReplaceAll: didReplaceAll,
                       insertedGapMarker: insertedGapMarker, overlap: overlap)
    }
}
