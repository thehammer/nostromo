import Foundation

/// Bounds what a retained transcript costs in memory by splitting each turn into
/// a small always-resident **skeleton** and a bulky **payload** that is
/// compressed in place once the turn goes cold.
///
/// ## Why turn data has to be bounded at all
///
/// The PRD allows "retain all turn data, virtualize only the views", and that
/// would have been the cheapest shape. Measurement says it does not fit. On a
/// synthetic corpus matching the PRD's load profile exactly (~200-char user
/// message, 3–8 text blocks of 1–4 KB, 2–6 tool calls with results, every 20th
/// turn a ≥256 KB tool result):
///
///     raw   per turn:  36099 bytes (35.3 KB)  → 34.4 MB / 1000 turns
///     lzfse per turn:   7925 bytes ( 7.7 KB)  →  7.6 MB / 1000 turns
///     ratio: 4.55x
///
/// Against a criterion of ≤20 MB per 1,000 turns, retaining raw turn text is
/// 1.7× over budget *before a single view exists*. So view virtualization alone
/// cannot carry the slope.
///
/// ## Why compression rather than paging from the daemon
///
/// The alternative was a protocol addition to fetch old turns back from the
/// record. Rejected: the protocol has no way to ask for turns older than a given
/// point, the daemon's turn ids are not stable across restarts so any cursor
/// would have to be content-based anyway, and — decisively — the daemon's own
/// `SessionTranscript.turns` is itself unbounded. One daemon process hosts every
/// focus, so building client recovery on daemon retention would move the leak
/// from Swift to Rust and let the app pass its own memory criterion while the
/// machine still died. Compression needs no protocol change and costs ~0.06 ms
/// to reverse, against an IPC round trip.
///
/// ## Budget
///
/// Measured by `TurnPayloadStoreTests` over a 5,000-turn corpus, which is the
/// authority for these numbers — an earlier estimate here was optimistic by
/// roughly 4x on the skeleton side and it was the test that caught it:
///
///     raw, uncompressed : 39.1 MB / 1,000 turns
///     skeletons         :  3.7 MB / 1,000 turns
///     compressed payload: 12.6 MB / 1,000 turns
///     retained total    : 16.1 MB / 1,000 turns   (criterion: <= 20)
///
/// That corpus compresses at 3.1x, against 4.6x on a more repetitive one — so
/// treat 16.1 as a conservative upper bound rather than a typical figure. The
/// margin is real but not large; `prefixLength` and `maxRetainedTurns` are the
/// two dials, and the test will say so immediately if either moves the wrong
/// way.
final class TurnPayloadStore {

    /// Turns within this distance of the newest are never compressed, so the
    /// streaming path never pays compression latency and recent scrollback is
    /// instant.
    static let hotWindow = 200

    /// Hard cap on retained skeletons. Past this, history genuinely becomes
    /// unreachable and the transcript says so — see
    /// `ChatTurn.Marker.historyUnavailable`.
    ///
    /// At the measured ~3.7 KB per skeleton this is a ~35 MB ceiling. It was
    /// 20,000 while the skeleton cost was assumed to be 1.5 KB; measurement put
    /// that at 6.2 KB, making the real ceiling ~119 MB — four times the intended
    /// budget, and quietly.
    static let maxRetainedTurns = 10_000

    /// How much of each text payload the skeleton keeps. Enough to hold a
    /// turn's place with real words while its full content is decompressed, and
    /// to serve as the honest fallback if it cannot be.
    ///
    /// This is the dominant term in skeleton size: a turn carries 3–8 text
    /// blocks, so the prefix is paid several times over per turn. At 512 the
    /// skeletons alone were 6.2 KB/turn and ate most of the slope budget.
    ///
    /// Must be **≥ `ChatTurn.identityPrefix`** — see that constant for what
    /// happens otherwise.
    static let prefixLength = 240

    /// The result of asking for a cold turn's full content.
    enum Hydration {
        /// Full content, either because the turn was still hot or because its
        /// payload decompressed successfully.
        case full(ChatTurn)
        /// The turn was dropped past `maxRetainedTurns`. Callers must say so
        /// rather than render an empty turn.
        case unavailable(ChatTurn)
    }

    // MARK: - State

    /// ## Threading contract
    ///
    /// **Every public method, and all state below, is main-queue only.** `queue`
    /// exists for exactly one thing: the LZFSE pass inside `compact` and
    /// `compactBatch`, which reads a `Data` it was handed by value and touches no
    /// stored property. Both dispatches hop back to `.main` before going near
    /// `blobs`, `pinned`, `dropped` or `inFlight`.
    ///
    /// Written down because it was already load-bearing and nowhere stated: the
    /// in-flight stamping below is a plain `Dictionary` mutated from completions,
    /// and it is only sound because those completions are serialised on one
    /// queue. Calling `pin`, `drop` or `compactBatch` from a background thread
    /// would corrupt it silently rather than trap.
    private var blobs: [UUID: Data] = [:]
    /// Turns held uncompressed on request (currently materialized views).
    private var pinned: Set<UUID> = []
    /// Turns whose payload was compressed and then dropped — asked for again,
    /// they must report unavailability rather than emptiness.
    private var dropped: Set<UUID> = []
    /// Turns currently being compressed on `queue`, each stamped with the
    /// dispatch that owns it. Without this, two `compact` calls for the same
    /// turn before the first returns both compress it and both fire their
    /// completion — the `blobs[id] == nil` guard is evaluated synchronously but
    /// the blob is written asynchronously.
    ///
    /// A bare `Set` is not enough. `forget`, `drop` and `clear` remove the
    /// id, but the closure they were racing is already dispatched and would
    /// still write its now-stale blob under a live id — the
    /// stale-content-rendered-as-current failure `forget` exists to prevent. A
    /// completion may only touch `blobs[id]` while its own stamp is still the
    /// one on record, so a forget-then-recompact sequence cannot be won by the
    /// older dispatch.
    private var inFlight: [UUID: Int] = [:]
    private var nextDispatchStamp = 0
    private let queue = DispatchQueue(label: "com.hammer.nostromo.payload", qos: .utility)

    /// Registers `ids` to a new dispatch and returns its stamp.
    private func beginCompaction(of ids: [UUID]) -> Int {
        nextDispatchStamp += 1
        for id in ids { inFlight[id] = nextDispatchStamp }
        return nextDispatchStamp
    }

    /// True while some dispatch owns `id`.
    private func isInFlight(_ id: UUID) -> Bool { inFlight[id] != nil }

    /// De-registers `id` iff `stamp` still owns it. `false` means this dispatch
    /// was superseded — by a `forget`, `drop` or `clear`, or by a newer
    /// compaction of the same turn — and must not write anything.
    private func finishCompaction(of id: UUID, stamp: Int) -> Bool {
        guard inFlight[id] == stamp else { return false }
        inFlight.removeValue(forKey: id)
        return true
    }

    // MARK: - Stats (for TranscriptDiagnostics)

    struct Stats {
        var coldTurns: Int
        var compressedBytes: Int
    }

    var stats: Stats {
        Stats(coldTurns: blobs.count,
              compressedBytes: blobs.values.reduce(0) { $0 + $1.count })
    }

    // MARK: - Compaction

    /// Compress `turn`'s bulk payload off the main thread and call back on main
    /// with the skeleton to retain in its place.
    ///
    /// Deliberately a thin delegation to `compactBatch` and **not** a second
    /// implementation. It was one, and it had drifted: `compactBatch`'s completion
    /// guards `!dropped.contains(id)` *and* `!pinned.contains(id)`, while this one
    /// had only the `dropped` half — so it wrote a compressed blob for a turn that
    /// was pinned between dispatch and completion, "pinned" meaning "held
    /// uncompressed while materialized", which is the entire contract `pin`
    /// exists to enforce. It drifted unnoticed because it has no production
    /// callers left; only the tests call it. Re-syncing the two would leave the
    /// next divergence just as easy, so there is now only one implementation.
    func compact(_ turn: ChatTurn, completion: @escaping (ChatTurn) -> Void) {
        compactBatch([turn]) { skeletons in
            if let skeleton = skeletons.first { completion(skeleton) }
        }
    }

    /// Compress many turns in one background hop.
    ///
    /// The shed path compacts an entire hot window at once; doing that as one
    /// `compact` call per turn would queue thousands of dispatches at exactly
    /// the moment the machine is already unhappy.
    ///
    /// - Returns: `true` when a background compaction was dispatched, and
    ///   therefore `completion` **will** be called (exactly once, on main);
    ///   `false` when nothing was eligible and it will **not** be called.
    ///
    ///   The "no completion for ineligible turns" half is long-standing behaviour
    ///   that `TurnPayloadStoreTests` pins, and it is right — a caller with
    ///   nothing to do should not be handed an empty array to apply. But it makes
    ///   this method unusable for anyone who has to *wait*: `MemoryWatchdog`
    ///   measures the footprint it freed, and a `DispatchGroup` around a
    ///   completion that may never arrive never balances. The return value is the
    ///   exactly-once signal that makes the wait possible without changing the
    ///   completion contract.
    @discardableResult
    func compactBatch(_ turns: [ChatTurn], completion: @escaping ([ChatTurn]) -> Void) -> Bool {
        // De-duplicated by id. The eligibility test reads `isInFlight`,
        // which nothing has written yet — `beginCompaction` runs below — so the
        // same turn appearing twice in `turns` passes it twice, and a reconciler
        // splice is exactly where a repeated id shows up. Two entries for one turn
        // then compress the same payload twice, hand the completion the same
        // skeleton twice, and (before this) trapped in
        // `Dictionary(uniqueKeysWithValues:)` on the low-memory path.
        //
        // An explicit loop rather than a `filter` whose predicate also mutates
        // `seen` — see the de-registration loop below for why a correctness
        // invariant must not ride on a closure's evaluation order.
        var candidates: [ChatTurn] = []
        var seen: Set<UUID> = []
        for turn in turns {
            guard turn.isComplete, turn.marker == nil, blobs[turn.id] == nil,
                  !pinned.contains(turn.id), !dropped.contains(turn.id),
                  !isInFlight(turn.id), !seen.contains(turn.id)
            else { continue }
            seen.insert(turn.id)
            candidates.append(turn)
        }
        let payloads: [(UUID, Data)] = candidates.compactMap { turn in
            Self.encodePayload(turn).map { (turn.id, $0) }
        }
        // This filter once read `inFlight` while nothing ever wrote it, so with
        // `compactColdTurns()` sweeping on every `.turnStarted` each sweep
        // re-offered turns a prior sweep was still compressing — `blobs[id]` is
        // only populated in the completion below. That is a redundant
        // `encodePayload` on the *main thread* plus a redundant LZFSE pass per
        // sweep, scaling with how far compression trails the append rate: the
        // exact main-thread-cost-grows-with-session-length dimension this store
        // exists to bound. Register before dispatching. Guard on `payloads`
        // rather than `candidates` — only turns that actually encoded get
        // dispatched, and registering one that didn't would strand it.
        guard !payloads.isEmpty else { return false }
        let stamp = beginCompaction(of: payloads.map { $0.0 })
        queue.async { [weak self] in
            let compressed: [(UUID, Data)] = payloads.compactMap { id, payload in
                guard let blob = try? (payload as NSData).compressed(using: .lzfse) as Data
                else { return nil }
                return (id, blob)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // De-register every id this dispatch still owns, first and
                // unconditionally: an id whose LZFSE pass failed is absent from
                // `compressed` and would otherwise stay in flight for ever,
                // permanently unbounded. Ids we no longer own were superseded
                // and must not be written.
                //
                // An explicit loop, not `.filter { self.finishCompaction(...) }`.
                // `finishCompaction` mutates `inFlight`, and a de-registration
                // invariant must not ride on the evaluation order of a `filter`
                // predicate — a lazy or reordered `filter` would leave ids in
                // flight for ever, and nothing in the type system says it can't.
                var owned: Set<UUID> = []
                for (id, _) in payloads where self.finishCompaction(of: id, stamp: stamp) {
                    owned.insert(id)
                }
                var skeletons: [ChatTurn] = []
                // NOT `Dictionary(uniqueKeysWithValues:)`, which **traps** on a
                // duplicate id. `candidates` is de-duplicated above, so this
                // cannot fire today — and it is written this way anyway because
                // this runs on the low-memory path, where a trap crashes the app
                // at the exact moment the watchdog is trying to save it. The
                // uniqueness of `candidates` is an invariant twenty lines away;
                // that is not a good enough reason to make it load-bearing here.
                let byId = Dictionary(candidates.map { ($0.id, $0) },
                                      uniquingKeysWith: { _, new in new })
                for (id, blob) in compressed where owned.contains(id) {
                    guard !self.dropped.contains(id), !self.pinned.contains(id),
                          let turn = byId[id] else { continue }
                    self.blobs[id] = blob
                    skeletons.append(Self.skeleton(of: turn))
                }
                completion(skeletons)
            }
        }
        return true
    }

    /// Restore a turn's full payload. Hot turns pass straight through.
    func hydrate(_ turn: ChatTurn) -> Hydration {
        guard let blob = blobs[turn.id] else {
            return dropped.contains(turn.id) ? .unavailable(turn) : .full(turn)
        }
        guard let payload = try? (blob as NSData).decompressed(using: .lzfse) as Data,
              let restored = Self.decodePayload(payload, into: turn)
        else { return .unavailable(turn) }
        return .full(restored)
    }

    /// Keep this turn's payload uncompressed while it is materialized.
    func pin(_ id: UUID)   { pinned.insert(id) }
    func unpin(_ id: UUID) { pinned.remove(id) }

    /// Release a turn's payload permanently. Subsequent `hydrate` calls report
    /// `.unavailable` rather than silently returning a skeleton.
    /// Marks the turn dropped whether or not it had been compacted yet. A turn
    /// dropped while still hot has no blob to remove, and recording nothing
    /// would let a later `hydrate` answer `.full` for content that is gone —
    /// the silently-empty expansion this is supposed to make impossible.
    func drop(_ id: UUID) {
        blobs.removeValue(forKey: id)
        dropped.insert(id)
        pinned.remove(id)
        inFlight.removeValue(forKey: id)
    }

    /// Discard any stored payload for `id` **without** marking it unavailable.
    ///
    /// Distinct from `drop`: the caller is telling us the turn's content has been
    /// replaced with a fresh, complete copy, so there is nothing lost and nothing
    /// to warn about. `drop` means "this content is gone"; this means "this blob
    /// is stale".
    ///
    /// Dropping the in-flight registration is what makes this safe against a
    /// compression dispatched moments ago: that closure is already queued
    /// and cannot be cancelled, but it checks its stamp against `inFlight`
    /// before writing, so it now finds itself superseded and writes nothing.
    /// Without that check it would store a blob of the *old* content under an id
    /// that is still live, and a later `hydrate` would render the previous
    /// version of the turn as current — worse than an outright decode failure,
    /// because nothing says so.
    func forget(_ id: UUID) {
        blobs.removeValue(forKey: id)
        pinned.remove(id)
        inFlight.removeValue(forKey: id)
        dropped.remove(id)
    }

    func clear() {
        blobs.removeAll()
        pinned.removeAll()
        dropped.removeAll()
        // Clearing the registrations is what invalidates any compaction still in
        // flight: the dispatch cannot be cancelled, but it may only write while
        // its own stamp is still on record, so after this it lands and does
        // nothing. Previously this line was believed to have that effect and did
        // not — the closure wrote an orphan blob for a turn that no longer
        // exists, retained for the lifetime of the store.
        inFlight.removeAll()
    }

    // MARK: - Skeleton / payload split

    /// The turn stripped to what the collapsed UI and the height estimator need:
    /// block kinds, byte lengths, tool names, input summaries, result line
    /// counts, and a bounded prefix of every text body.
    static func skeleton(of turn: ChatTurn) -> ChatTurn {
        var out = turn
        // Record the pre-truncation lengths first: height estimation reads them,
        // and a skeleton that forgot how big it used to be would collapse the
        // scroll document.
        out.truncatedLengths = ChatTurn.TruncatedLengths(
            userInput: turn.userInput.count,
            blocks: turn.blocks.map { $0.contentCharCount })
        out.userInput = String(turn.userInput.prefix(prefixLength))
        out.blocks = turn.blocks.map { block in
            switch block {
            case .text(let s):
                return .text(String(s.prefix(prefixLength)))
            case .toolCall(let d):
                // `inputSummary` is the collapsed row's whole content and is
                // already one line; only `inputFull` is bulky.
                return .toolCall(ToolCallData(toolName: d.toolName,
                                              inputSummary: String(d.inputSummary.prefix(120)),
                                              inputFull: ""))
            case .toolResult(let d):
                // The collapsed row shows a line count, which survives the
                // truncation because `ToolResultView` recomputes it from the
                // retained prefix — so keep enough to be honest and let
                // `hydrate` supply the rest on expand.
                return .toolResult(ToolResultData(content: String(d.content.prefix(prefixLength)),
                                                  isError: d.isError))
            case .resultSummary, .errorMessage, .askQuestion:
                return block
            }
        }
        return out
    }

    /// Serialise the parts of a turn that the skeleton throws away.
    ///
    /// Deliberately a hand-rolled length-prefixed encoding rather than JSON:
    /// this runs once per turn on a background queue over payloads that reach
    /// 256 KB, and JSON would spend most of that time escaping text it is about
    /// to hand straight to the compressor.
    static func encodePayload(_ turn: ChatTurn) -> Data? {
        var out = Data()
        append(&out, turn.userInput)
        for block in turn.blocks {
            switch block {
            case .text(let s):        append(&out, s)
            case .toolCall(let d):    append(&out, d.inputFull)
            case .toolResult(let d):  append(&out, d.content)
            default:                  break
            }
        }
        return out
    }

    /// Reverse of `encodePayload`, rebuilding `turn`'s full text in place.
    /// Returns nil if the blob does not line up with the skeleton's block shape.
    static func decodePayload(_ data: Data, into turn: ChatTurn) -> ChatTurn? {
        var cursor = data.startIndex
        guard let userInput = next(data, &cursor) else { return nil }
        var out = turn
        out.userInput = userInput
        var blocks: [TurnBlock] = []
        blocks.reserveCapacity(turn.blocks.count)
        for block in turn.blocks {
            switch block {
            case .text:
                guard let s = next(data, &cursor) else { return nil }
                blocks.append(.text(s))
            case .toolCall(let d):
                guard let full = next(data, &cursor) else { return nil }
                blocks.append(.toolCall(ToolCallData(toolName: d.toolName,
                                                     inputSummary: d.inputSummary,
                                                     inputFull: full)))
            case .toolResult(let d):
                guard let content = next(data, &cursor) else { return nil }
                blocks.append(.toolResult(ToolResultData(content: content, isError: d.isError)))
            default:
                blocks.append(block)
            }
        }
        guard cursor == data.endIndex else { return nil }
        out.blocks = blocks
        out.truncatedLengths = nil   // full payload restored — lengths are live again
        return out
    }

    private static func append(_ data: inout Data, _ string: String) {
        let bytes = Array(string.utf8)
        var len = UInt32(bytes.count).littleEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }

    private static func next(_ data: Data, _ cursor: inout Data.Index) -> String? {
        guard data.distance(from: cursor, to: data.endIndex) >= 4 else { return nil }
        var len: UInt32 = 0
        withUnsafeMutableBytes(of: &len) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self),
                           from: cursor ..< data.index(cursor, offsetBy: 4))
        }
        let count = Int(UInt32(littleEndian: len))
        cursor = data.index(cursor, offsetBy: 4)
        guard data.distance(from: cursor, to: data.endIndex) >= count else { return nil }
        let end = data.index(cursor, offsetBy: count)
        let string = String(decoding: data[cursor ..< end], as: UTF8.self)
        cursor = end
        return string
    }
}
