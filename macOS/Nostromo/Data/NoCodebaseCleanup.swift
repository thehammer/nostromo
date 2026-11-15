import Foundation
import os

/// Moves no-codebase folders nothing refers to any more to the Trash (recoverable; never deleted outright).
///
/// Runs only on a successful, NOT degraded history reply that names the SAME root this app computed: the
/// daemon reports its own spaces root with the reply, and any disagreement (a QA clone against a real home,
/// an older daemon that says nothing) means nothing is touched. The root itself must be a real directory
/// (never a symlink) owned by the current user with mode 0700. A folder is touched only when it is a direct
/// child of that root, a real directory (`lstat`: never a symlink) owned by the current user with mode
/// 0700, named by a UUID, not named by any history
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
                    trash: Trasher = NoCodebaseCleanup.systemTrasher,
                    currentUser: UInt = UInt(getuid())) -> Int {
        // Never on a failed or degraded read: the reply may be missing entries that still name folders.
        guard reply.degradedKept == nil, let referenced = reply.referencedSpaceFolders else { return 0 }
        // Never unless the daemon means the very root this app computed. Fixed words in the log, no path.
        guard let daemonRoot = reply.spacesRoot else {
            log.info("no-codebase clean-up skipped: daemon did not report its root")
            return 0
        }
        guard canonical(daemonRoot) == canonical(root.path) else {
            log.info("no-codebase clean-up skipped: daemon and app disagree on the root")
            return 0
        }
        let fm = FileManager.default
        guard isPrivateDirectory(root, fm: fm, owner: currentUser) else {
            log.info("no-codebase clean-up skipped: root is not a private folder of this user")
            return 0
        }
        let canonicalRoot = canonical(root.path)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        let keep = Set((referenced + Array(openWorkingDirectories) + Array(protectedFolders))
            .map { canonicalChild($0) })
        var trashed = 0, failed = 0
        for name in names.sorted() where NoCodebaseFolder.isUUIDName(name) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory else { continue }   // not a symlink or file
            guard isPrivate(attrs, owner: currentUser) else { continue }   // not ours, or not 0700: leave it
            if keep.contains(canonicalRoot + "/" + name) { continue }
            if let made = attrs[.creationDate] as? Date, now.timeIntervalSince(made) < minimumAge { continue }
            do { try trash(url); trashed += 1 } catch { failed += 1 }
        }
        if trashed > 0 || failed > 0 { log.info("no-codebase folders trashed: \(trashed), failed: \(failed)") }
        return trashed
    }

    /// The real path of an existing folder, or of the closest existing ancestor plus the rest.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A child's real path with only its parent resolved: a symlink in the leaf stays a different path.
    private static func canonicalChild(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return parent == "/" ? "/" + url.lastPathComponent : parent + "/" + url.lastPathComponent
    }

    /// `lstat`: a real directory (not a symlink), owned by `owner`, mode 0700.
    private static func isPrivateDirectory(_ url: URL, fm: FileManager, owner: UInt) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeDirectory else { return false }
        return isPrivate(attrs, owner: owner)
    }

    private static func isPrivate(_ attrs: [FileAttributeKey: Any], owner: UInt) -> Bool {
        guard let uid = (attrs[.ownerAccountID] as? NSNumber)?.uintValue, uid == owner,
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue, mode & 0o777 == 0o700
        else { return false }
        return true
    }
}
