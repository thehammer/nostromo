import Foundation
import os

/// Always-on, cheap window-placement diagnostics: every line goes to `os_log`
/// AND to a small rolling file, `~/.nostromo/logs/window-placement.log`, capped
/// at 256 KiB so the user can paste it back after a bad launch.
///
/// Line format (one event per line, no secrets, no user content):
///
///     2026-10-11T14:03:22.418Z [launch] screen#1 uuid=37D8832A-… frame=(0,0 1710x1073) visible=(0,0 1710x1049) scale=2.0 name="Built-in Retina Display" main=true
///     2026-10-11T14:03:22.420Z [win#0 → 37D8832A-…] created: requested=(0,0 1710x1049) frame=(0,0 1710x1049) screen=37D8832A-…
///
/// `[win#N → UUID]` lines belong to window N bound to display UUID. When the
/// cap is exceeded the oldest half is dropped (on a line boundary).
final class WindowPlacementLog {

    static let shared = WindowPlacementLog(fileURL: WindowPlacementLog.defaultFileURL)

    static let defaultMaxBytes = 256 * 1024

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nostromo/logs/window-placement.log")
    }

    private let fileURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.hammer.nostromo.window-placement-log")
    private let osLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "WindowPlacement")
    private let formatter = ISO8601DateFormatter()

    init(fileURL: URL, maxBytes: Int = WindowPlacementLog.defaultMaxBytes) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Log one event under `scope` (e.g. "launch", "win#1 → <uuid>").
    func log(_ scope: String, _ message: String, warning: Bool = false) {
        if warning {
            osLog.warning("[\(scope, privacy: .public)] \(message, privacy: .public)")
        } else {
            osLog.info("[\(scope, privacy: .public)] \(message, privacy: .public)")
        }
        let line = "\(formatter.string(from: Date())) [\(scope)] \(message)\n"
        queue.async { [self] in append(line) }
    }

    /// Block until queued writes have landed (tests, termination).
    func flush() { queue.sync {} }

    // MARK: - File

    private func append(_ line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            if let size = try? handle.offset(), Int(size) > maxBytes { trim() }
        } catch {
            osLog.error("window-placement log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep roughly the newest half, starting at a line boundary.
    private func trim() {
        guard let data = try? Data(contentsOf: fileURL), data.count > maxBytes else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
    }
}
