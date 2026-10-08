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
/// Lookups run serially on `queue` (never the main thread) and results are
/// published on main, only when something actually changed. At most one batch
/// is in flight: a `refresh` requested meanwhile is coalesced into exactly one
/// follow-up batch with the latest path set. `lookup`, the poll timer and the
/// "is the app active" check are injectable so tests can fake them.
///
/// Threading: `refresh`, `startPolling` and `stopPolling` are main-thread only.
final class BranchProvider {
    static let shared = BranchProvider()

    /// Consecutive `.failed` lookups after which a path's last known branch is dropped.
    static let maxConsecutiveFailures = 3

    /// Schedules `tick` every `interval` seconds; the returned closure cancels it.
    typealias TimerFactory = (_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void

    static let systemTimer: TimerFactory = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
        return { timer.invalidate() }
    }

    /// Project path → current branch. Mutated on the main thread only.
    @Published private(set) var branches: [String: String] = [:]

    private let queue: DispatchQueue
    private let lookup: (String) -> GitBranch.Lookup
    private let isAppActive: () -> Bool
    private let makeTimer: TimerFactory
    private let notificationCenter: NotificationCenter

    private var currentPaths = Set<String>()
    private var failureCounts: [String: Int] = [:]
    private var inFlight = false
    private var pending: [String]?

    private var cancelTimer: (() -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var pollPaths: (() -> [String])?

    /// `queue` must be serial: lookups never run concurrently.
    init(queue: DispatchQueue = DispatchQueue(label: "nostromo.branch-provider", qos: .utility),
         lookup: @escaping (String) -> GitBranch.Lookup = GitBranch.lookup(forProjectPath:),
         isAppActive: @escaping () -> Bool = { NSApp?.isActive == true },
         makeTimer: @escaping TimerFactory = BranchProvider.systemTimer,
         notificationCenter: NotificationCenter = .default) {
        self.queue = queue
        self.lookup = lookup
        self.isAppActive = isAppActive
        self.makeTimer = makeTimer
        self.notificationCenter = notificationCenter
    }

    var isPolling: Bool { cancelTimer != nil }

    func branch(for path: String) -> String? { branches[path] }

    /// Re-check `paths`, which must be the FULL set of checkouts currently of
    /// interest: anything not in it is pruned. Returns immediately; lookups run
    /// off the main thread. A transient `.failed` keeps the last known value,
    /// dropped after `maxConsecutiveFailures` in a row; `.resolved(nil)` drops it.
    func refresh(_ paths: [String]) {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        currentPaths = seen
        prune()
        guard !unique.isEmpty else { pending = nil; return }

        if inFlight {
            pending = unique
        } else {
            run(unique)
        }
    }

    /// Keep branches live: re-check on app activation and every `interval`
    /// seconds while the app is active. Idempotent: a second call never creates
    /// a second timer, it only replaces the `paths` provider (read on the main
    /// thread at each check). End it with `stopPolling()`.
    func startPolling(interval: TimeInterval = 5, paths: @escaping () -> [String]) {
        pollPaths = paths
        guard cancelTimer == nil else { return }
        refresh(paths())
        cancelTimer = makeTimer(interval) { [weak self] in
            guard let self, self.isAppActive() else { return }
            self.refresh(self.pollPaths?() ?? [])
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refresh(self.pollPaths?() ?? [])
        }
    }

    func stopPolling() {
        cancelTimer?()
        cancelTimer = nil
        if let observer = activationObserver { notificationCenter.removeObserver(observer) }
        activationObserver = nil
        pollPaths = nil
    }

    private func run(_ paths: [String]) {
        inFlight = true
        queue.async { [lookup] in
            let results = paths.map { ($0, lookup($0)) }
            DispatchQueue.main.async { [weak self] in self?.finish(results) }
        }
    }

    private func finish(_ results: [(String, GitBranch.Lookup)]) {
        inFlight = false
        apply(results)
        if let next = pending {
            pending = nil
            run(next)
        }
    }

    private func prune() {
        failureCounts = failureCounts.filter { currentPaths.contains($0.key) }
        let kept = branches.filter { currentPaths.contains($0.key) }
        if kept != branches { branches = kept }
    }

    private func apply(_ results: [(String, GitBranch.Lookup)]) {
        var updated = branches
        for (path, result) in results where currentPaths.contains(path) {
            switch result {
            case .failed:
                let count = failureCounts[path, default: 0] + 1
                failureCounts[path] = count
                if count >= Self.maxConsecutiveFailures { updated[path] = nil }
            case .resolved(let branch):
                failureCounts[path] = nil
                updated[path] = branch
            }
        }
        if updated != branches { branches = updated }
    }
}
