import Foundation

/// In-process, on-demand latency tracking for `NostromodClient`'s IPC traffic.
///
/// Pure, socket-free, lock-protected bookkeeping — no AppKit, no sockets — so
/// it is fully testable from the standalone `NostromoTests` bundle. Every
/// public method is thread-safe: `recordSend` runs on caller threads,
/// `recordReceive` runs on the client's read-loop queue.
///
/// This is **not** a metrics pipeline: nothing is persisted, and everything
/// resets when the process restarts.
///
/// ## Round-trip correlation
///
/// The wire protocol carries no request ids (`ClientMsg` has none; `ServerMsg`
/// frames are a mix of replies and unsolicited broadcasts — see
/// `src/ipc/protocol.rs`). True request/response pairing is therefore only
/// available for message pairs that are unambiguous by type, plus `tag` where
/// the message has one. `IPCLatencyStats` tracks exactly the five pairs in
/// `RoundTripRule.all` and no more; every other outbound type is counted for
/// frames/bytes but produces no round-trip bucket.
///
/// The `session_send->turn_started` bucket is approximate: the daemon fans
/// `session_turn_delta` out to every attached client, so a turn started by
/// another client (or another device) can be matched against a local send.
/// That caveat is surfaced in the snapshot's `note` field, not just here.
final class IPCLatencyStats {

    /// Number of most-recent samples retained per round-trip bucket / decode
    /// counter. Percentiles are computed over this window.
    static let sampleWindow = 128

    /// Cap on unmatched pending sends retained per correlation key. Beyond
    /// this, the oldest pending send is dropped (and never retroactively
    /// matched) so an unmatched key can't grow without bound.
    static let maxPendingPerKey = 32

    // MARK: - Round-trip rules

    /// One outbound→inbound correlation rule.
    private struct RoundTripRule {
        let outboundType: String
        let inboundType: String
        let bucket: String
        /// If set, the inbound frame's `deltaKind` must equal this for the
        /// rule to apply (used only by the `session_send`/`turn_started` pair).
        let deltaKindMustEqual: String?
        let note: String?

        static let all: [RoundTripRule] = [
            RoundTripRule(outboundType: "hello", inboundType: "welcome",
                          bucket: "hello->welcome", deltaKindMustEqual: nil, note: nil),
            RoundTripRule(outboundType: "ping", inboundType: "pong",
                          bucket: "ping->pong", deltaKindMustEqual: nil, note: nil),
            RoundTripRule(outboundType: "session_spawn", inboundType: "session_spawned",
                          bucket: "session_spawn->session_spawned", deltaKindMustEqual: nil, note: nil),
            RoundTripRule(outboundType: "session_attach", inboundType: "session_turns",
                          bucket: "session_attach->session_turns", deltaKindMustEqual: nil, note: nil),
            RoundTripRule(outboundType: "session_send", inboundType: "session_turn_delta",
                          bucket: "session_send->turn_started", deltaKindMustEqual: "turn_started",
                          note: "Approximate: the daemon fans session_turn_delta out to every " +
                                "attached client, so a turn started by another client or device " +
                                "can be matched against this client's send."),
        ]
    }

    // MARK: - Internal counters

    private final class RoundTripBucket {
        var matched: Int = 0
        var maxMs: Double = 0
        var lastMs: Double = 0
        var samples: [Double] = []

        func record(_ ms: Double) {
            matched += 1
            lastMs = ms
            if ms > maxMs { maxMs = ms }
            if samples.count == IPCLatencyStats.sampleWindow { samples.removeFirst() }
            samples.append(ms)
        }
    }

    private final class FrameCounter {
        var frames: Int = 0
        var bytes: Int = 0
    }

    private final class DecodeCounter {
        var frames: Int = 0
        var bytes: Int = 0
        var maxMs: Double = 0
        var samples: [Double] = []

        func record(bytes: Int, decodeMs: Double) {
            frames += 1
            self.bytes += bytes
            if decodeMs > maxMs { maxMs = decodeMs }
            if samples.count == IPCLatencyStats.sampleWindow { samples.removeFirst() }
            samples.append(decodeMs)
        }
    }

    // MARK: - State (protected by `lock`)

    private let lock = NSLock()
    private var pending: [String: [Date]] = [:]
    private var roundTrips: [String: RoundTripBucket] = [:]
    private var outbound: [String: FrameCounter] = [:]
    private var inbound: [String: DecodeCounter] = [:]

    private var isConnected = false
    private var hadDisconnected = false
    private var reconnects = 0
    private var droppedPendingSends = 0
    private var abandonedOnDisconnect = 0

    // MARK: - Recording

    /// Record that a frame of wire `type` (optionally correlated by `tag`)
    /// was fully written to the socket. Must only be called after every byte
    /// of the frame has actually left the process — recording a send that
    /// never left would leave a pending entry that can never match.
    func recordSend(type: String, tag: String?, bytes: Int, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }

        let counter = outbound[type] ?? FrameCounter()
        counter.frames += 1
        counter.bytes += bytes
        outbound[type] = counter

        guard RoundTripRule.all.contains(where: { $0.outboundType == type }) else { return }
        let key = pendingKey(type: type, tag: tag)
        var arr = pending[key] ?? []
        if arr.count >= IPCLatencyStats.maxPendingPerKey {
            arr.removeFirst()
            droppedPendingSends += 1
        }
        arr.append(at)
        pending[key] = arr
    }

    /// Record an inbound frame of wire `type`, decoded in `decodeSeconds`.
    /// `deltaKind` is the inner `delta.delta` discriminator for
    /// `session_turn_delta` frames (nil for every other type).
    func recordReceive(type: String, tag: String?, deltaKind: String?, bytes: Int,
                        decodeSeconds: Double, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }

        let counter = inbound[type] ?? DecodeCounter()
        counter.record(bytes: bytes, decodeMs: decodeSeconds * 1000)
        inbound[type] = counter

        guard let rule = RoundTripRule.all.first(where: {
            $0.inboundType == type && ($0.deltaKindMustEqual == nil || $0.deltaKindMustEqual == deltaKind)
        }) else { return }

        let key = pendingKey(type: rule.outboundType, tag: tag)
        guard var arr = pending[key], !arr.isEmpty else { return }
        let sentAt = arr.removeFirst()
        pending[key] = arr

        let bucket = roundTrips[rule.bucket] ?? RoundTripBucket()
        bucket.record(at.timeIntervalSince(sentAt) * 1000)
        roundTrips[rule.bucket] = bucket
    }

    /// Mark the connection as established. The very first connect of the
    /// client's lifetime does not count as a reconnect; every connect that
    /// follows a `noteDisconnect()` does.
    func noteConnect() {
        lock.lock(); defer { lock.unlock() }
        isConnected = true
        if hadDisconnected {
            reconnects += 1
            hadDisconnected = false
        }
    }

    /// Mark the connection as dropped. Clears all pending (unmatched) sends
    /// into `abandonedOnDisconnect` — they can never be matched against a
    /// reply on the new connection. Accumulated round-trip/frame history is
    /// kept across reconnects.
    func noteDisconnect() {
        lock.lock(); defer { lock.unlock() }
        let discarded = pending.values.reduce(0) { $0 + $1.count }
        abandonedOnDisconnect += discarded
        pending.removeAll()
        isConnected = false
        hadDisconnected = true
    }

    // MARK: - Snapshot

    struct RoundTripRow: Encodable {
        let bucket: String
        let matched: Int
        let window: Int
        let p50Ms: Double
        let p95Ms: Double
        let maxMs: Double
        let lastMs: Double
        let note: String?
    }

    struct FrameRow: Encodable {
        let type: String
        let frames: Int
        let bytes: Int
    }

    struct InboundRow: Encodable {
        let type: String
        let frames: Int
        let bytes: Int
        let decodeP50Ms: Double
        let decodeP95Ms: Double
        let decodeMaxMs: Double
    }

    struct Snapshot: Encodable {
        let sampleWindow: Int
        let connected: Bool
        let reconnects: Int
        let unmatchedPending: Int
        let droppedPendingSends: Int
        let abandonedOnDisconnect: Int
        let roundTrips: [RoundTripRow]
        let outbound: [FrameRow]
        let inbound: [InboundRow]
    }

    /// Snapshot current stats. Arrays are sorted by bucket/type name
    /// ascending — deterministic output, easy diffing between two copies of
    /// the report.
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        let noteByBucket = Dictionary(uniqueKeysWithValues: RoundTripRule.all.map { ($0.bucket, $0.note) })

        let roundTripRows = roundTrips.map { bucket, samples -> RoundTripRow in
            let (p50, p95) = Self.percentiles(samples.samples)
            return RoundTripRow(
                bucket: bucket,
                matched: samples.matched,
                window: samples.samples.count,
                p50Ms: p50,
                p95Ms: p95,
                maxMs: Self.round3(samples.maxMs),
                lastMs: Self.round3(samples.lastMs),
                note: noteByBucket[bucket] ?? nil
            )
        }.sorted { $0.bucket < $1.bucket }

        let outboundRows = outbound.map { type, counter in
            FrameRow(type: type, frames: counter.frames, bytes: counter.bytes)
        }.sorted { $0.type < $1.type }

        let inboundRows = inbound.map { type, counter -> InboundRow in
            let (p50, p95) = Self.percentiles(counter.samples)
            return InboundRow(
                type: type,
                frames: counter.frames,
                bytes: counter.bytes,
                decodeP50Ms: p50,
                decodeP95Ms: p95,
                decodeMaxMs: Self.round3(counter.maxMs)
            )
        }.sorted { $0.type < $1.type }

        let unmatchedPending = pending.values.reduce(0) { $0 + $1.count }

        return Snapshot(
            sampleWindow: Self.sampleWindow,
            connected: isConnected,
            reconnects: reconnects,
            unmatchedPending: unmatchedPending,
            droppedPendingSends: droppedPendingSends,
            abandonedOnDisconnect: abandonedOnDisconnect,
            roundTrips: roundTripRows,
            outbound: outboundRows,
            inbound: inboundRows
        )
    }

    // MARK: - Helpers

    private func pendingKey(type: String, tag: String?) -> String {
        "\(type)|\(tag ?? "")"
    }

    /// Round a millisecond figure to 3 decimal places.
    private static func round3(_ x: Double) -> Double {
        (x * 1000).rounded() / 1000
    }

    /// Nearest-rank p50/p95 over `samples`.
    ///
    /// `index = min(n - 1, max(0, ceil(p * n) - 1))`; empty window yields
    /// `(0.0, 0.0)`. This exact rule mirrors the Rust side
    /// (`src/mcp/tool_stats.rs::percentiles`) so the two implementations
    /// cannot silently drift — pinned by the shared 1...100 ms fixture
    /// asserted identically on both sides.
    private static func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        guard !samples.isEmpty else { return (0.0, 0.0) }
        let sorted = samples.sorted()
        let n = sorted.count
        func rank(_ p: Double) -> Double {
            let idx = min(n - 1, max(0, Int((p * Double(n)).rounded(.up)) - 1))
            return round3(sorted[idx])
        }
        return (rank(0.5), rank(0.95))
    }
}
