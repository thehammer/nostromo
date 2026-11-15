import Foundation
import os

/// Moves no-codebase folders nothing refers to any more to the Trash (recoverable; never deleted outright).
///
/// Runs only on a successful, NOT degraded history reply. A folder is touched only when it is a direct child
/// of the spaces root, a real directory (`lstat`: never a symlink), named by a UUID, not named by any history
/// entry the daemon still keeps, not the working directory of an open focus in any window, and not a folder a
/// resume is about to use. Anything else, and anything outside the root, is left alone. A trash failure leaves
/// the folder for the next run. Logs fixed words and counts only, never a path.
enum NoCodebaseCleanup {
    typealias Trasher = (URL) throws -> Void

    private static let log = Logger(subsystem: "com.nostromo.mac", category: "NoCodebaseCleanup")

    /// A folder younger than this is never trashed: it may be one a Create or a resume has just made, not yet
    /// known to a focus or to the daemon.
    static let minimumAge: TimeInterval = 600

    static let systemTrasher: Trasher = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    }

    /// Returns how many folders went to the Trash.
    @discardableResult
    static func run(reply: ConversationHistoryWire,
                    openWorkingDirectories: Set<String>,
                    protectedFolders: Set<String> = [],
                    root: URL = NoCodebaseFolder.root(),
                    now: Date = Date(),
                    minimumAge: TimeInterval = NoCodebaseCleanup.minimumAge,
                    trash: Trasher = NoCodebaseCleanup.systemTrasher) -> Int {
        // Never on a failed or degraded read: the reply may be missing entries that still name folders.
        guard reply.degradedKept == nil, let referenced = reply.referencedSpaceFolders else { return 0 }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        let keep = Set((referenced + Array(openWorkingDirectories) + Array(protectedFolders))
            .map { standardized($0) })
        var trashed = 0, failed = 0
        for name in names.sorted() where NoCodebaseFolder.isUUIDName(name) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory else { continue }   // not a symlink or file
            if keep.contains(standardized(url.path)) { continue }
            if let made = attrs[.creationDate] as? Date, now.timeIntervalSince(made) < minimumAge { continue }
            do { try trash(url); trashed += 1 } catch { failed += 1 }
        }
        if trashed > 0 || failed > 0 { log.info("no-codebase folders trashed: \(trashed), failed: \(failed)") }
        return trashed
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
