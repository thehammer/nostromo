import AppKit
import Combine

/// Reads the current git branch of a checkout. Foundation-only logic, so it
/// compiles into the logic-test target.
enum GitBranch {

    /// `.failed` (not a repo, timeout, spawn error) is distinct from
    /// `.resolved(nil)` so callers can keep a previously-known value across a
    /// transient failure.
    enum Lookup: Equatable {
        case resolved(String?)
        case failed
    }

    /// Blocking. Never call on the main thread — use `BranchProvider`.
    ///
    /// `symbolic-ref --short -q HEAD` rather than `rev-parse --abbrev-ref HEAD`:
    /// it answers the same question (branch name; exit 1 when detached) but
    /// also works on an unborn branch, where `rev-parse` fails. Linked
    /// worktrees (`.git` is a file) need no special handling — git resolves it.
    /// Detached HEAD falls back to the short sha.
    static func lookup(forProjectPath path: String) -> Lookup {
        switch RepoOrg.runGit(path, ["symbolic-ref", "--short", "-q", "HEAD"]) {
        case .output(let branch):
            return .resolved(branch)
        case .noMatch:
            if case .output(let sha) = RepoOrg.runGit(path, ["rev-parse", "--short", "HEAD"]) {
                return .resolved(sha)
            }
            return .failed
        case .failed:
            return .failed
        }
    }
}

/// Live "current branch" per project path, for the sidebar's second line.
///
/// Lookups run on `queue` (never the main thread) and results are published on
/// main, only when something actually changed. `lookup` is injectable so tests
/// can fake the (blocking) git work.
final class BranchProvider {
    static let shared = BranchProvider()

    /// Project path → current branch. Mutated on the main thread only.
    @Published private(set) var branches: [String: String] = [:]

    private let queue: DispatchQueue
    private let lookup: (String) -> GitBranch.Lookup
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(queue: DispatchQueue = .global(qos: .utility),
         lookup: @escaping (String) -> GitBranch.Lookup = GitBranch.lookup(forProjectPath:)) {
        self.queue = queue
        self.lookup = lookup
    }

    func branch(for path: String) -> String? { branches[path] }

    /// Re-check `paths` off the main thread. A failed lookup keeps the last
    /// known value; `.resolved(nil)` drops the entry. Returns immediately.
    func refresh(_ paths: [String]) {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }

        queue.async { [lookup] in
            let results = unique.map { ($0, lookup($0)) }
            DispatchQueue.main.async { [weak self] in self?.apply(results) }
        }
    }

    /// Keep branches live: re-check on app activation and every `interval`
    /// seconds while the app is active. Idempotent — the first call wins.
    /// `paths` is read on the main thread at each check.
    func startPolling(interval: TimeInterval = 5, paths: @escaping () -> [String]) {
        guard timer == nil else { return }
        refresh(paths())
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard NSApp?.isActive == true else { return }
            self?.refresh(paths())
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(paths()) }
    }

    private func apply(_ results: [(String, GitBranch.Lookup)]) {
        var updated = branches
        for (path, result) in results {
            switch result {
            case .failed: continue
            case .resolved(let branch): updated[path] = branch
            }
        }
        if updated != branches { branches = updated }
    }
}
