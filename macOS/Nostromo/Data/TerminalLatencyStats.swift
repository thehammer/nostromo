import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "terminal")

/// How long a typed key takes to show up: from the key going down in a terminal view to the first
/// output after it being fed to that view. In-process and on demand, like `IPCLatencyStats`: nothing
/// is persisted and everything resets with the process. Main thread only (both ends run there).
///
/// Each key down is queued (oldest first) and each output fed answers the oldest one, so a burst of
/// typing pairs every key with the echo that follows it. A key with no output in `staleAfter` is
/// dropped without a sample (a key the program ignored). Output with no key waiting (a program's
/// own output) is not a sample.
final class TerminalLatencyStats {
    static let shared = TerminalLatencyStats()

    /// The most recent samples kept; the percentiles are over these.
    static let sampleWindow = 500
    /// A key down older than this was never echoed.
    static let staleAfter: TimeInterval = 2
    /// Key downs waiting for an echo, at most.
    static let maxPending = 64
    /// The target for criterion 3 (p95, seconds).
    static let p95Target: TimeInterval = 0.030

    struct Snapshot: Equatable {
        let count: Int
        let p50: TimeInterval?
        let p95: TimeInterval?
    }

    private let clock: () -> TimeInterval
    private var pending: [TimeInterval] = []
    private var samples: [TimeInterval] = []
    private var total = 0

    /// `clock` reads seconds on a monotonic clock (tests pass their own).
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// A key went down in a terminal view.
    func noteKeyDown() {
        let at = clock()
        pending.removeAll { at - $0 > Self.staleAfter }
        pending.append(at)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    /// Output reached a terminal view's screen.
    func noteOutputFed() {
        let at = clock()
        pending.removeAll { at - $0 > Self.staleAfter }
        guard !pending.isEmpty else { return }
        let started = pending.removeFirst()
        samples.append(max(0, at - started))
        if samples.count > Self.sampleWindow { samples.removeFirst(samples.count - Self.sampleWindow) }
        total += 1
        // Every 100 keys, so a QA run can read the numbers from the unified log (`scripts/qa/terminal-local.sh`).
        if total % 100 == 0 { log.info("\(self.report(), privacy: .public)") }
    }

    /// p50 and p95 (nearest rank) over the retained samples, and how many keys were ever measured.
    var snapshot: Snapshot {
        guard !samples.isEmpty else { return Snapshot(count: total, p50: nil, p95: nil) }
        let sorted = samples.sorted()
        func rank(_ p: Double) -> TimeInterval {
            sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
        }
        return Snapshot(count: total, p50: rank(0.5), p95: rank(0.95))
    }

    func reset() {
        pending.removeAll()
        samples.removeAll()
        total = 0
    }

    /// What Debug > Copy terminal latency stats puts on the pasteboard.
    func report() -> String {
        let s = snapshot
        guard let p50 = s.p50, let p95 = s.p95 else {
            return "terminal latency (key down to echo fed): no samples yet; type in a terminal pane"
        }
        func ms(_ t: TimeInterval) -> String { String(format: "%.1f ms", t * 1000) }
        let verdict = p95 < Self.p95Target ? "within" : "OVER"
        return "terminal latency (key down to echo fed): count=\(s.count) window=\(min(s.count, Self.sampleWindow)) "
            + "p50=\(ms(p50)) p95=\(ms(p95)) (p95 target < \(Int(Self.p95Target * 1000)) ms: \(verdict))"
    }
}
