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
    static let pollInterval: TimeInterval = 30

    /// Called when the app should shed, with a completion the receiver must call
    /// once every pane has finished compacting. Wired to every live `ReplView` and
    /// `ChatSession` by `AppStore`.
    ///
    /// The completion is not decoration. Shedding ends in a background LZFSE pass
    /// whose skeletons are applied in a main-queue callback, so a `Void`-returning
    /// `onShed` returned before anything had actually been freed — see `shed`.
    var onShed: ((@escaping () -> Void) -> Void)?
    /// Called with (title, detail) when the operator should be told.
    var onWarn: ((String, String) -> Void)?

    /// How long to wait for `onShed`'s completion before measuring anyway.
    var shedCompletionTimeout: TimeInterval = 5
    /// Seams, so the ordering below is assertable in the logic test target
    /// without a running app or a real allocator.
    var footprint: () -> Int = { TranscriptDiagnostics.physicalFootprint() }
    var relievePressure: () -> Void = { malloc_zone_pressure_relief(nil, 0) }

    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    /// Suppresses repeat warnings for the same episode; cleared when the
    /// footprint falls back below the warning level.
    private var hasWarned = false
    private var lastShed = Date.distantPast
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
                self.shed(reason: "the system reported critical memory pressure")
            } else {
                self.warn(footprint: self.footprint(),
                          detail: "The system is under memory pressure.")
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

    private func poll() {
        let bytes = footprint()
        if bytes >= Self.shedBytes {
            shed(reason: "Nostromo is holding \(Self.megabytes(bytes)) MB")
        } else if bytes >= Self.warningBytes {
            warn(footprint: bytes, detail: "Nostromo is holding \(Self.megabytes(bytes)) MB.")
        } else {
            hasWarned = false
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

    /// Collapse every pane to its minimum materialization window, compress every
    /// hot payload, hand freed pages back to the OS, and re-measure — in that
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
    /// Internal rather than private so `MemoryWatchdogTests` can drive it.
    func shed(reason: String) {
        // Shedding is not free; do not do it in a tight loop if the footprint
        // stays high because something else is holding the memory. `isShedding`
        // is the second half of that guard now that a shed spans several run-loop
        // turns — the `lastShed` clock alone cannot stop a re-entrant start.
        guard !isShedding, Date().timeIntervalSince(lastShed) > Self.pollInterval
        else { return }
        isShedding = true
        lastShed = Date()

        let before = footprint()
        var finished = false
        let finish: () -> Void = { [weak self] in
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
            log.error("""
                shed: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB \
                (\(reason, privacy: .public))
                """)
            self.onWarn?("Shed retained content",
                         "\(reason.prefix(1).uppercased() + reason.dropFirst()), so older "
                         + "transcript content was released. Footprint "
                         + "\(Self.megabytes(before)) → \(Self.megabytes(after)) MB. "
                         + "Scroll-back will reload it on demand.")
        }

        guard let onShed else { finish(); return }
        onShed(finish)

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
            finish()
        }
    }

    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }
}
