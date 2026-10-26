import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "watchdog")

/// Notices the app's own runaway growth, tells the operator, and sheds retained
/// content before the OS starts killing applications.
///
/// The incident's damage was not the leak by itself. It was that the leak ran
/// for three hundred minutes with no indication anything was wrong, until macOS
/// put up a Force Quit dialog showing 123.75 GB and the whole machine was in
/// memory pressure. A bound on today's known cause does not protect against
/// tomorrow's unknown one, and this app is left unattended by design.
///
/// Two independent signals, because neither alone is enough:
///
///   - The OS's own `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`, which is
///     authoritative and arrives early, but says nothing about *our* trend.
///   - A poll of our own `phys_footprint`, which catches growth that has not
///     yet made the machine unhappy.
final class MemoryWatchdog {

    /// A non-modal statement of the condition, while there is still time to act.
    static let warningBytes: Int = 1_200 * 1_048_576   // 1.2 GB
    /// Shed retained content. Below the 2 GB ceiling, with headroom.
    static let shedBytes: Int    = 1_600 * 1_048_576   // 1.6 GB
    /// An episode of sustained high memory ends only when the footprint falls below this (90% of
    /// `shedBytes`). A footprint that hovers around the shed line, dipping to 1.59 GB between
    /// polls, is still one episode and keeps its back-off.
    static let episodeEndBytes: Int = shedBytes / 10 * 9
    static let pollInterval: TimeInterval = 30

    /// What a shed may take. A poll-triggered shed is housekeeping and asks for `.offscreenOnly`: it
    /// must never blank a pane the operator is looking at (the 2026-10-25 incident shed the visible
    /// transcript every 30 s, to no effect). Only the OS saying memory is CRITICAL asks for
    /// `.everything`.
    enum ShedScope {
        case offscreenOnly
        case everything
    }

    /// A shed is helpful only if it freed at least this much AND at least a tenth of what the
    /// app held before it. Anything less means the memory is not in the transcript.
    static let helpfulBytes: Int = 100 * 1_048_576
    /// One tenth, as a divisor so the comparison is exact integer arithmetic.
    static let helpfulFractionDivisor = 10
    /// The minimum gap before the next non-critical shed after the 1st, 2nd and 3rd-or-later consecutive
    /// shed that did not help. After one that helped (or the first of an episode) the gap is `pollInterval`.
    static let backoffSchedule: [TimeInterval] = [120, 600, 3_600]

    /// Called when the app should shed, with a completion the receiver must call
    /// once every pane has finished compacting. Wired to every live `ReplView` and
    /// `ChatSession` by `AppStore`.
    ///
    /// The completion is not decoration. Shedding ends in a background LZFSE pass
    /// whose skeletons are applied in a main-queue callback, so a `Void`-returning
    /// `onShed` returned before anything had actually been freed — see `shed`.
    var onShed: ((@escaping () -> Void) -> Void)?
    /// Preferred over `onShed` when set: the same fan-out, told how much it may take.
    var onShedScoped: ((ShedScope, @escaping () -> Void) -> Void)?
    /// Called with (title, detail) when the operator should be told.
    var onWarn: ((String, String) -> Void)?

    /// How long to wait for `onShed`'s completion before measuring anyway.
    var shedCompletionTimeout: TimeInterval = 5
    /// Seams, so the ordering below is assertable in the logic test target
    /// without a running app or a real allocator.
    var footprint: () -> Int = { TranscriptDiagnostics.physicalFootprint() }
    var relievePressure: () -> Void = { malloc_zone_pressure_relief(nil, 0) }
    /// Monotonic: a wall-clock step (NTP, a manual change) must not shorten or stretch a back-off.
    var now: () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }
    /// Where the memory is, for the log line and the toast when a shed did not help. Never `heap`.
    var summarize: () -> MemorySummary = { MemorySummary.capture() }

    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    /// Suppresses repeat warnings for the same episode; cleared when the
    /// footprint falls back below the warning level.
    private var hasWarned = false
    private var lastShed = Date.distantPast
    /// Consecutive sheds in this episode that did not help; sets the gap before the next one.
    private var unhelpfulStreak = 0
    /// The operator has been told, in this episode, that shedding does not help.
    private var toldAboutUnhelpfulShed = false
    /// True from the moment a shed starts until its completion (or its timeout)
    /// has run. A shed is now asynchronous, so the `lastShed` rate limit alone no
    /// longer prevents a second one starting inside the first.
    private var isShedding = false

    func start() {
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            if source.data.contains(.critical) {
                log.error("OS reported critical memory pressure — shedding")
                self.shed(reason: "the system reported critical memory pressure", critical: true)
            } else {
                self.warnAboutSystemPressure()
            }
        }
        pressure.resume()
        pressureSource = pressure

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Polling

    func poll() {
        let bytes = footprint()
        if bytes >= Self.shedBytes {
            // Refused (silently) while backed off: see `shed`.
            shed(reason: "Nostromo is holding \(Self.megabytes(bytes)) MB")
        } else {
            // The episode is over once the footprint is clearly below the line (`episodeEndBytes`). A
            // footprint that stays at or near the line keeps the same episode, and with it the
            // back-off, however many polls go by.
            if bytes < Self.episodeEndBytes {
                unhelpfulStreak = 0
                toldAboutUnhelpfulShed = false
            }
            if bytes >= Self.warningBytes {
                warn(footprint: bytes, detail: "Nostromo is holding \(Self.megabytes(bytes)) MB.")
            } else {
                hasWarned = false
            }
        }
    }

    private func warn(footprint: Int, detail: String) {
        guard !hasWarned else { return }
        hasWarned = true
        log.warning("memory warning at \(Self.megabytes(footprint))MB")
        onWarn?("Memory climbing",
                detail + " Retained transcript content will be shed automatically "
                       + "if it keeps rising.")
    }

    /// The OS said the *machine* is short of memory. That is not evidence Nostromo
    /// is the cause (every warning on 2026-10-07 fired with Nostromo at 92–317 MB,
    /// against a 1.2 GB warning level), so say whose it is: our own footprint and
    /// the biggest memory users by name.
    private func warnAboutSystemPressure() {
        guard !hasWarned else { return }
        hasWarned = true
        let ours = footprint()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let top = MemoryPressureReport.topProcesses(limit: 3)
            let detail = MemoryPressureReport.systemPressureDetail(footprintBytes: ours, topProcesses: top)
            log.warning("system memory pressure; nostromo=\(Self.megabytes(ours))MB; \(detail, privacy: .public)")
            DispatchQueue.main.async { self?.onWarn?("Memory pressure", detail) }
        }
    }

    /// Compact retained transcript content, hand freed pages back to the OS, and re-measure — in that
    /// order, which is the whole point.
    ///
    /// The chain `onShed` starts is asynchronous: `AppStore` fans out to every
    /// pane's `shedMaterializedViews`, which calls `ChatSession.shedRetainedContent`,
    /// which calls `TurnPayloadStore.compactBatch`, which dispatches LZFSE to a
    /// `.utility` queue and applies the skeletons in a main-queue callback. So
    /// `onShed` used to return immediately, and everything after it ran before a
    /// single byte had been freed: pressure relief handed back nothing because the
    /// allocations still existed, and the "after" figure was the "before" figure
    /// with extra steps. That made the log line and the operator's toast
    /// meaningless, and it meant the last-resort safety mechanism for this whole
    /// feature was deciding on stale numbers.
    ///
    /// Two limits keep this from becoming the problem it is meant to solve (2026-10-25: a leak held
    /// the footprint over the line for fourteen hours, so this ran every 30 s and blanked the visible
    /// transcript each time, freeing nothing):
    ///
    ///   - **It measures whether it helped** (`isHelpful`) and backs off when it did not
    ///     (`backoffSchedule`): the transcript is evidently not what holds the memory, and shedding
    ///     it again in half a minute cannot change that. The operator is told once per episode,
    ///     with where the memory is.
    ///   - **A non-critical shed asks only for off-screen content** (`ShedScope.offscreenOnly`).
    ///     Only the OS reporting CRITICAL pressure (`critical`) takes the views the operator is
    ///     looking at, and it ignores the back-off.
    ///
    /// Internal rather than private so `MemoryWatchdogTests` can drive it.
    func shed(reason: String, critical: Bool = false) {
        // Shedding is not free; do not do it in a tight loop if the footprint
        // stays high because something else is holding the memory. `isShedding`
        // is the second half of that guard now that a shed spans several run-loop
        // turns — the clock alone cannot stop a re-entrant start.
        let sinceLast = now().timeIntervalSince(lastShed)
        guard !isShedding, sinceLast > (critical ? Self.pollInterval : requiredGap) else { return }
        isShedding = true
        lastShed = now()

        let before = footprint()
        var finished = false
        let finish: (Bool) -> Void = { [weak self] timedOut in
            guard let self, !finished else { return }
            finished = true
            self.isShedding = false

            // Freed Swift String allocations return to libmalloc's pools, which do
            // not always hand pages straight back to the OS — so the footprint can
            // look sticky after eviction even though the memory is genuinely free.
            // Allocations over 128 KB (the ≥256 KB tool results, the big items) are
            // mmap'd and release cleanly on their own; this covers the rest. It has
            // to run *after* compaction: the pages it hands back are the ones the
            // LZFSE pass just stopped needing.
            self.relievePressure()

            let after = self.footprint()
            if timedOut {
                self.reportInconclusive(reason: reason, before: before, after: after)
            } else {
                self.report(reason: reason, before: before, after: after)
            }
        }
        let complete: () -> Void = { finish(false) }

        let scope: ShedScope = critical ? .everything : .offscreenOnly
        if let onShedScoped {
            onShedScoped(scope, complete)
        } else if let onShed {
            onShed(complete)
        } else {
            complete()
            return
        }

        // A completion that never arrives must not disable the app's last-resort
        // memory defence for the rest of the session. A late shed is a bug; a
        // permanently wedged watchdog is the incident this class exists to
        // prevent. `finish` is idempotent, so the timeout and the real completion
        // racing is harmless.
        let timeout = shedCompletionTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !finished {
                log.error("""
                    shed completion did not arrive within \(timeout, privacy: .public)s \
                    — measuring anyway
                    """)
            }
            finish(true)
        }
    }

    /// The gap a non-critical shed needs since the previous one started.
    private var requiredGap: TimeInterval {
        guard unhelpfulStreak > 0 else { return Self.pollInterval }
        return Self.backoffSchedule[min(unhelpfulStreak, Self.backoffSchedule.count) - 1]
    }

    /// Freed at least `helpfulBytes` and at least a tenth of what was held.
    static func isHelpful(before: Int, after: Int) -> Bool {
        let freed = before - after
        return freed >= helpfulBytes && freed * helpfulFractionDivisor >= before
    }

    /// A shed that finished only because its completion timed out: the "after" reading may predate
    /// the compaction, so it cannot say whether the shed helped. Report the figures, claim nothing,
    /// and leave the back-off exactly where it was.
    private func reportInconclusive(reason: String, before: Int, after: Int) {
        let sentence = reason.prefix(1).uppercased() + reason.dropFirst()
        log.error("""
            shed did not finish in time: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB \
            (\(reason, privacy: .public)); result inconclusive
            """)
        onWarn?("Shed retained content",
                "\(sentence). The shed was still running when it was measured, so its effect is "
                + "not known yet. Footprint \(Self.megabytes(before)) → \(Self.megabytes(after)) MB.")
    }

    /// Log and toast what a finished shed did, and decide the next gap.
    private func report(reason: String, before: Int, after: Int) {
        let figures = "Footprint \(Self.megabytes(before)) → \(Self.megabytes(after)) MB."
        let sentence = reason.prefix(1).uppercased() + reason.dropFirst()

        if Self.isHelpful(before: before, after: after) {
            unhelpfulStreak = 0
            toldAboutUnhelpfulShed = false
            log.error("""
                shed: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB \
                (\(reason, privacy: .public))
                """)
            onWarn?("Shed retained content",
                    "\(sentence), so older transcript content was released. \(figures) "
                    + "Scroll-back will reload it on demand.")
            return
        }

        unhelpfulStreak += 1
        guard !toldAboutUnhelpfulShed else {
            log.info("""
                shed did not help again: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB; \
                next attempt in at least \(Int(self.requiredGap), privacy: .public)s
                """)
            return
        }
        toldAboutUnhelpfulShed = true
        let summary = summarize()
        log.error("""
            shed did not help: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB \
            (\(reason, privacy: .public)); \(summary.oneLine, privacy: .public); \
            backing off to every \(Int(self.requiredGap), privacy: .public)s or longer
            """)
        var detail = "\(sentence), but shedding transcript content did not help: "
            + "memory is held outside the transcript. \(figures)"
        if let largest = summary.categories.first {
            detail += " Largest: \(largest.name) \(Self.megabytes(largest.dirtyBytes)) MB."
        }
        onWarn?("Shed retained content", detail)
    }

    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }
}

// MARK: - MemoryPressureReport

/// Words for an OS memory-pressure warning: who is using the memory.
enum MemoryPressureReport {

    struct Usage: Equatable {
        let name: String
        let bytes: Int
    }

    /// Largest memory users, grouped by executable name (fourteen `claude`
    /// processes are one line, not fourteen), from `ps -axo rss=,comm=`.
    static func topProcesses(limit: Int,
                             run: () -> String? = {
        ProcessRunner.runCapturingStdout(URL(fileURLWithPath: "/bin/ps"),
                                         arguments: ["-axo", "rss=,comm="])
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }) -> [Usage] {
        guard let output = run() else { return [] }
        return aggregate(psOutput: output, limit: limit)
    }

    /// Pure parser: `   123456 /path/to/comm` lines (RSS in KiB) → top usages by name.
    static func aggregate(psOutput: String, limit: Int) -> [Usage] {
        var byName: [String: Int] = [:]
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let kib = Int(trimmed[..<space]) else { continue }
            let path = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            byName[name, default: 0] += kib * 1024
        }
        return byName.map { Usage(name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }

    static func systemPressureDetail(footprintBytes: Int, topProcesses: [Usage]) -> String {
        let mine = footprintBytes / 1_048_576
        var s = "macOS reports memory pressure. Nostromo is using \(mine) MB"
        s += mine < 1_000 ? " (not the cause)." : "."
        if !topProcesses.isEmpty {
            let list = topProcesses.map { "\($0.name) \($0.bytes / 1_048_576) MB" }.joined(separator: ", ")
            s += " Largest: \(list)."
        }
        return s
    }
}
