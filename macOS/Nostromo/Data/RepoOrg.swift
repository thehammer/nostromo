import Foundation

/// Infers a Focus's org ("Carefeed" / "Personal") from a repo's GitHub remote.
///
/// Foundation-only so it compiles into both the app and the logic-test target.
enum RepoOrg {

    // MARK: Pure parsing

    /// Maps a git remote URL to an org name. Returns nil for non-GitHub hosts,
    /// unknown owners, or unparseable input.
    static func org(forRemoteURL url: String) -> String? {
        guard let owner = githubOwner(fromRemoteURL: url) else { return nil }
        switch owner.lowercased() {
        case "carefeed": return "Carefeed"
        case "thehammer": return "Personal"
        default: return nil
        }
    }

    // MARK: Process-backed

    /// Outcome of a blocking lookup. `.failed` (timeout, spawn error, unexpected
    /// exit) is distinct from `.resolved(nil)` (no remote / unknown owner) so
    /// callers can retry failures but cache real answers.
    enum Lookup: Equatable {
        case resolved(String?)
        case failed

        var org: String? {
            if case .resolved(let org) = self { return org }
            return nil
        }
    }

    /// Blocking: reads all remotes in one git call and maps the winner to an org.
    /// Never call on the main thread — use `RepoOrgResolver`.
    static func lookup(forProjectPath path: String) -> Lookup {
        switch runGit(path, ["config", "--get-regexp", "^remote\\..*\\.url$"]) {
        case .failed: return .failed
        case .noMatch: return .resolved(nil)
        case .output(let listing): return .resolved(org(forRemoteListing: listing))
        }
    }

    static func org(forProjectPath path: String) -> String? {
        lookup(forProjectPath: path).org
    }

    /// Parses `git config --get-regexp` output (`remote.<name>.url <url>` lines)
    /// and picks the deciding remote: `origin` if present (final, even if its
    /// owner is unknown); otherwise the first remote sorted by name.
    static func org(forRemoteListing listing: String) -> String? {
        var remotes: [(name: String, url: String)] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]                    // remote.<name>.url (name may contain dots)
            guard key.hasPrefix("remote."), key.hasSuffix(".url"), key.count > "remote..url".count
            else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            remotes.append((name, String(line[line.index(after: space)...])))
        }
        let chosen = remotes.first { $0.name == "origin" } ?? remotes.min { $0.name < $1.name }
        return chosen.flatMap { org(forRemoteURL: $0.url) }
    }

    // MARK: Private

    private static func githubOwner(fromRemoteURL raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        let host: String
        let path: String
        if let schemeRange = url.range(of: "://") {
            // ssh://git@github.com/OWNER/repo, https://user:pw@github.com/OWNER/repo
            let rest = url[schemeRange.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            if let colon = authority.firstIndex(of: ":") {   // strip port
                authority = String(authority[..<colon])
            }
            host = authority
            path = String(rest[rest.index(after: slash)...])
        } else {
            // scp-like: git@github.com:OWNER/repo
            guard let colon = url.firstIndex(of: ":") else { return nil }
            var h = String(url[..<colon])
            if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            host = h
            path = String(url[url.index(after: colon)...])
        }

        guard isGitHubHost(host.lowercased()) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[0])
    }

    /// github.com, www./ssh. variants, and per-identity SSH aliases such as
    /// `github.com-work` or `github-personal`.
    private static func isGitHubHost(_ host: String) -> Bool {
        if ["github.com", "www.github.com", "ssh.github.com"].contains(host) { return true }
        for prefix in ["github.com-", "github-"] where host.hasPrefix(prefix) {
            let suffix = host.dropFirst(prefix.count)
            if !suffix.isEmpty, !suffix.contains(".") { return true }
        }
        return false
    }

    enum GitResult {
        case output(String)   // exit 0 with output
        case noMatch          // exit 1 (or exit 0, empty): ran fine, nothing matched
        case failed           // spawn error, timeout, other exit code
    }

    /// Runs git with a hard timeout. Output goes to a temp file rather than a
    /// pipe so a grandchild holding the descriptor can't block the read.
    static func runGit(_ path: String, _ args: [String]) -> GitResult {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoorg-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL) else { return .failed }
        defer {
            try? outHandle.close()
            try? FileManager.default.removeItem(at: outURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        proc.standardOutput = outHandle
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return .failed }

        if done.wait(timeout: .now() + 2) == .timedOut {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + 1)
            return .failed
        }

        switch proc.terminationStatus {
        case 0:
            guard let data = try? Data(contentsOf: outURL),
                  let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else { return .failed }
            return out.isEmpty ? .noMatch : .output(out)
        case 1: return .noMatch
        default: return .failed   // e.g. 128: not a repo / git error
        }
    }
}

/// Resolves a project's org off the main thread, with a per-path cache.
/// Only resolved results are cached (including a legitimate nil); failed
/// lookups are retried next time. Concurrent requests for one path share one
/// lookup. `lookup` is injectable so tests can fake the (blocking) git work.
final class RepoOrgResolver {

    private let lookup: (String) -> RepoOrg.Lookup
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private var pending: [String: [(String?) -> Void]] = [:]

    init(queue: DispatchQueue = .global(qos: .userInitiated),
         lookup: @escaping (String) -> RepoOrg.Lookup = RepoOrg.lookup(forProjectPath:)) {
        self.queue = queue
        self.lookup = lookup
    }

    /// `.some(org)` if resolved before (org may itself be nil); `.none` if unknown.
    func cached(_ path: String) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]
    }

    /// Calls `completion`: immediately (caller's thread) if cached, otherwise on
    /// the main thread after the lookup finishes on `queue`. A failed lookup
    /// completes with nil and is not cached.
    func resolve(_ path: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        if let hit = cache[path] {
            lock.unlock()
            completion(hit)
            return
        }
        if pending[path] != nil {
            pending[path]!.append(completion)
            lock.unlock()
            return
        }
        pending[path] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.lookup(path)
            self.lock.lock()
            if case .resolved(let org) = result { self.cache[path] = .some(org) }
            let waiters = self.pending.removeValue(forKey: path) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { waiters.forEach { $0(result.org) } }
        }
    }
}
