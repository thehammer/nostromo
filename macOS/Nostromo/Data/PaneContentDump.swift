import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "panedump")

/// Raw `pane_content` frame capture, gated by `NOSTROMO_PANE_DUMP=1`
/// (diagnostics job: `.claude/plans/instrument-code-pane-render-diagnostics.md`).
///
/// E4 in that plan makes it very unlikely the daemon's payload is at fault
/// for a blank-body render — but "the daemon logged N rows / M bytes and the
/// client received exactly that" is the assertion that turns a strong
/// suspicion into proof, and it costs nothing to have on hand. It also closes
/// a real, separate blind spot: a `pane_content` frame that fails to decode
/// (see `NostromodClient.decode`'s `pane_content` case) previously vanished
/// with nothing to inspect. This writes the raw bytes *before* the decode
/// attempt, so a malformed frame is captured, not just a well-formed one.
///
/// Off by default — every write costs a file open — and capped to the newest
/// `maxFiles` dumps so an always-on flag can never fill the disk.
enum PaneContentDump {

    private static let enabled: Bool = {
        ProcessInfo.processInfo.environment["NOSTROMO_PANE_DUMP"] == "1"
    }()

    private static let maxFiles = 200

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nostromo/pane-content")
    }

    /// Write `raw` verbatim if `NOSTROMO_PANE_DUMP=1`; a no-op otherwise, so
    /// callers don't need to guard the call site themselves.
    static func writeIfRequested(raw: Data, paneId: String?) {
        guard enabled else { return }
        let id = paneId ?? "unknown"
        let epochMs = Int(Date().timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("\(id)-\(epochMs).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raw.write(to: url)
            prune()
        } catch {
            log.error("""
                failed to write pane-content dump to \(url.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Keep only the newest `maxFiles` dumps, oldest-first eviction.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        guard files.count > maxFiles else { return }

        let sorted = files.sorted { lhs, rhs in
            modificationDate(of: lhs) < modificationDate(of: rhs)
        }
        for stale in sorted.prefix(sorted.count - maxFiles) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
