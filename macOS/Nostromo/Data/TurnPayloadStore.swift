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

    private var blobs: [UUID: Data] = [:]
    /// Turns held uncompressed on request (currently materialized views).
    private var pinned: Set<UUID> = []
    /// Turns whose payload was compressed and then dropped — asked for again,
    /// they must report unavailability rather than emptiness.
    private var dropped: Set<UUID> = []
    /// Turns currently being compressed on `queue`. Without this, two `compact`
    /// calls for the same turn before the first returns both compress it and
    /// both fire their completion — the `blobs[id] == nil` guard is evaluated
    /// synchronously but the blob is written asynchronously.
    private var inFlight: Set<UUID> = []
    private let queue = DispatchQueue(label: "com.hammer.nostromo.payload", qos: .utility)

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
    /// A turn's payload is immutable once it completes, which is what makes this
    /// safe to do asynchronously: nothing can append to it while the compressor
    /// is running.
    func compact(_ turn: ChatTurn, completion: @escaping (ChatTurn) -> Void) {
        guard turn.isComplete, turn.marker == nil,
              blobs[turn.id] == nil, !pinned.contains(turn.id), !dropped.contains(turn.id),
              !inFlight.contains(turn.id),
              let payload = Self.encodePayload(turn)
        else { return }

        let id = turn.id
        inFlight.insert(id)
        queue.async { [weak self] in
            let blob = try? (payload as NSData).compressed(using: .lzfse) as Data
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(id)
                guard let blob, !self.dropped.contains(id) else { return }
                self.blobs[id] = blob
                completion(Self.skeleton(of: turn))
            }
        }
    }

    /// Compress many turns in one background hop.
    ///
    /// The shed path compacts an entire hot window at once; doing that as one
    /// `compact` call per turn would queue thousands of dispatches at exactly
    /// the moment the machine is already unhappy.
    func compactBatch(_ turns: [ChatTurn], completion: @escaping ([ChatTurn]) -> Void) {
        let candidates = turns.filter {
            $0.isComplete && $0.marker == nil && blobs[$0.id] == nil
                && !pinned.contains($0.id) && !dropped.contains($0.id)
                && !inFlight.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        let payloads: [(UUID, Data)] = candidates.compactMap { turn in
            Self.encodePayload(turn).map { (turn.id, $0) }
        }
        queue.async { [weak self] in
            let compressed: [(UUID, Data)] = payloads.compactMap { id, payload in
                guard let blob = try? (payload as NSData).compressed(using: .lzfse) as Data
                else { return nil }
                return (id, blob)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var skeletons: [ChatTurn] = []
                let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
                for (id, blob) in compressed {
                    guard !self.dropped.contains(id), !self.pinned.contains(id),
                          let turn = byId[id] else { continue }
                    self.blobs[id] = blob
                    skeletons.append(Self.skeleton(of: turn))
                }
                completion(skeletons)
            }
        }
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
        inFlight.remove(id)
    }

    func clear() {
        blobs.removeAll()
        pinned.removeAll()
        dropped.removeAll()
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
