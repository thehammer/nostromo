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

    /// Called when the app should shed. Wired to every live `ReplView` and
    /// `ChatSession` by `AppStore`.
    var onShed: (() -> Void)?
    /// Called with (title, detail) when the operator should be told.
    var onWarn: ((String, String) -> Void)?

    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    /// Suppresses repeat warnings for the same episode; cleared when the
    /// footprint falls back below the warning level.
    private var hasWarned = false
    private var lastShed = Date.distantPast

    func start() {
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            if source.data.contains(.critical) {
                log.error("OS reported critical memory pressure — shedding")
                self.shed(reason: "the system reported critical memory pressure")
            } else {
                self.warn(footprint: TranscriptDiagnostics.physicalFootprint(),
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
        let footprint = TranscriptDiagnostics.physicalFootprint()
        if footprint >= Self.shedBytes {
            shed(reason: "Nostromo is holding \(Self.megabytes(footprint)) MB")
        } else if footprint >= Self.warningBytes {
            warn(footprint: footprint, detail: "Nostromo is holding \(Self.megabytes(footprint)) MB.")
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
    /// hot payload, hand freed pages back to the OS, and re-measure.
    private func shed(reason: String) {
        // Shedding is not free; do not do it in a tight loop if the footprint
        // stays high because something else is holding the memory.
        guard Date().timeIntervalSince(lastShed) > Self.pollInterval else { return }
        lastShed = Date()

        let before = TranscriptDiagnostics.physicalFootprint()
        onShed?()

        // Freed Swift String allocations return to libmalloc's pools, which do
        // not always hand pages straight back to the OS — so the footprint can
        // look sticky after eviction even though the memory is genuinely free.
        // Allocations over 128 KB (the ≥256 KB tool results, the big items) are
        // mmap'd and release cleanly on their own; this covers the rest.
        malloc_zone_pressure_relief(nil, 0)

        let after = TranscriptDiagnostics.physicalFootprint()
        log.error("""
            shed: \(Self.megabytes(before))MB → \(Self.megabytes(after))MB (\(reason, privacy: .public))
            """)
        onWarn?("Shed retained content",
                "\(reason.prefix(1).uppercased() + reason.dropFirst()), so older transcript "
                + "content was released. Footprint \(Self.megabytes(before)) → "
                + "\(Self.megabytes(after)) MB. Scroll-back will reload it on demand.")
    }

    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }
}
