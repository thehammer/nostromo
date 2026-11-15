import Foundation
import NostromoKit

/// The private folder a "No codebase" focus runs in. One fresh, empty folder per focus under a spaces root
/// that no repo's instructions, settings, hooks or MCP config can reach (Claude Code reads `CLAUDE.md` by
/// walking up from the working directory and project settings from the project root).
///
/// The root is `.nostromo-spaces` (mode 0700) under `NostromoHome.current` (the QA clone's home, never the
/// real one, when it is the QA clone), overridable by `NOSTROMO_SPACES_ROOT` in the QA clone only: the
/// real app ignores a stray variable, as `NostromoHome` does for its own. The daemon resolves it the same
/// way (`conversations::spaces_root`) and says which root it means with every history reply; the clean-up
/// runs only when the two agree. A test on each side pins the default name so the two cannot drift. It is
/// deliberately NOT under `~/.nostromo`, the daemon's private state: an agent must never work next to the
/// approvals and history files.
///
/// Pure helpers plus `create()`. Nothing here logs a path.
enum NoCodebaseFolder {
    static let environmentKey = "NOSTROMO_SPACES_ROOT"
    static let defaultDirectoryName = ".nostromo-spaces"

    /// Why a folder could not be made. `reason` is what the sheet shows under the Project row.
    enum Failure: Error, Equatable {
        case rootIsSymlink
        case rootNotDirectory
        case rootParentMissing
        case rootIsHome
        case rootInsideCodeRoot
        case rootInsideGitRepo
        case ancestorHoldsInstructions(String)
        case couldNotCreate
        case notEmpty

        var reason: String {
            switch self {
            case .rootIsSymlink: return "The no-codebase folder root is a symbolic link."
            case .rootNotDirectory: return "The no-codebase folder root is not a folder."
            case .rootParentMissing: return "The no-codebase folder root can\u{2019}t be created."
            case .rootIsHome: return "The no-codebase folder root is your home folder."
            case .rootInsideCodeRoot: return "The no-codebase folder root is inside your code folder."
            case .rootInsideGitRepo: return "The no-codebase folder root is inside a git repository."
            case .ancestorHoldsInstructions(let name):
                return "A folder above the no-codebase root holds \(name), which Claude would read."
            case .couldNotCreate: return "The no-codebase folder could not be created."
            case .notEmpty: return "The new no-codebase folder was not empty."
            }
        }
    }

    /// Files whose presence in an ancestor of the root would colour a conversation there.
    static let instructionNames = ["CLAUDE.md", "CLAUDE.local.md", ".mcp.json"]
    /// Project settings (read from the project root); the user's own `~/.claude` is the one allowed exception.
    /// `.claude/CLAUDE.md` is project memory; `hooks` and `commands` are project hooks and slash commands.
    static let settingsNames = [".claude/settings.json", ".claude/settings.local.json", ".claude/CLAUDE.md",
                                ".claude/hooks", ".claude/commands"]

    /// The default root under `home`.
    static func defaultRoot(home: URL) -> URL {
        home.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    /// The root in force: `NOSTROMO_SPACES_ROOT` when set and non-empty AND this is the QA clone, else
    /// `.nostromo-spaces` under the process's home (`NostromoHome.current`, not `NSHomeDirectory()`, which
    /// ignores the QA launcher's `HOME`).
    static func root(env: [String: String] = ProcessInfo.processInfo.environment,
                     bundleID: String? = Bundle.main.bundleIdentifier,
                     realHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if NostromoHome.isQAInstance(bundleID: bundleID), let v = env[environmentKey], !v.isEmpty {
            return URL(fileURLWithPath: v, isDirectory: true)
        }
        return defaultRoot(home: NostromoHome.url(env: env, bundleID: bundleID, realHome: realHome))
    }

    /// Make one new, empty folder (mode 0700) under the root, named by a fresh UUID. Every check runs before
    /// anything is created except the root itself (made 0700 when missing); a failure leaves no folder behind.
    static func create(root: URL = NoCodebaseFolder.root(),
                       home: URL = NostromoHome.current,
                       codeRoot: URL = CodeRoot.resolve(),
                       makeID: () -> String = { UUID().uuidString }) -> Result<URL, Failure> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let existing = (try? fm.attributesOfItem(atPath: root.path)) != nil
        if existing {
            guard let type = (try? fm.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType else {
                return .failure(.rootNotDirectory)
            }
            if type == .typeSymbolicLink { return .failure(.rootIsSymlink) }
            guard type == .typeDirectory, fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                return .failure(.rootNotDirectory)
            }
        } else {
            let parent = root.deletingLastPathComponent()
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
                return .failure(.rootParentMissing)
            }
        }

        // Real paths: where the root actually is, so a symlinked ancestor cannot hide a repo.
        let realHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let realCode = codeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let realRoot = existing
            ? root.resolvingSymlinksInPath().standardizedFileURL.path
            : root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent)
                .standardizedFileURL.path
        if realRoot == realHome { return .failure(.rootIsHome) }
        if realRoot == realCode || realRoot.hasPrefix(realCode + "/") { return .failure(.rootInsideCodeRoot) }
        if let failure = checkAncestors(ofRoot: realRoot, realHome: realHome, rootExists: existing) {
            return .failure(failure)
        }

        if !existing {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            } catch { return .failure(.couldNotCreate) }
        }
        // Whatever the root's mode was, it is private now.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let folder = root.appendingPathComponent(makeID(), isDirectory: true)
        do {
            // Not recursive: a name that already exists fails instead of being reused.
            try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return .failure(.couldNotCreate) }
        let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        guard contents.isEmpty else { return .failure(.notEmpty) }
        return .success(folder)
    }

    /// The root and every ancestor up to `/`: a `.git`, an instructions file, or project settings (outside
    /// the user's own `~/.claude`) makes the folder unfit. A root not made yet is checked from its parent.
    private static func checkAncestors(ofRoot realRoot: String, realHome: String, rootExists: Bool) -> Failure? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: realRoot, isDirectory: true)
        if !rootExists { dir = dir.deletingLastPathComponent() }
        while true {
            let path = dir.path
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return .rootInsideGitRepo }
            for name in instructionNames where fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                return .ancestorHoldsInstructions(name)
            }
            // `~/.claude/settings*.json` is the user's own configuration, which still applies.
            if path != realHome {
                for name in settingsNames where fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                    return .ancestorHoldsInstructions(name)
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == path { return nil }
            dir = parent
        }
    }

    // MARK: Names

    /// Is `name` a UUID, the only kind of folder name the clean-up will ever touch?
    static func isUUIDName(_ name: String) -> Bool { UUID(uuidString: name) != nil }
}
