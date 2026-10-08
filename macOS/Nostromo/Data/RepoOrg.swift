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

    /// Blocking: reads the repo's remote and maps it to an org. Never call on
    /// the main thread — use `RepoOrgResolver`.
    ///
    /// - `origin` exists: its URL decides, even if it maps to nil (other
    ///   remotes are never consulted).
    /// - No `origin`: the alphabetically first remote (by name) decides.
    static func org(forProjectPath path: String) -> String? {
        if let url = git(path, ["config", "--get", "remote.origin.url"]) {
            return org(forRemoteURL: url)
        }
        guard let listing = git(path, ["config", "--get-regexp", "^remote\\..+\\.url$"]) else { return nil }
        var urls: [(name: String, url: String)] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]                    // remote.<name>.url
            guard key.hasPrefix("remote."), key.hasSuffix(".url"), key.count > "remote..url".count
            else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            urls.append((name, String(line[line.index(after: space)...])))
        }
        guard let first = urls.min(by: { $0.name < $1.name }) else { return nil }
        return org(forRemoteURL: first.url)
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

    /// Runs git with a hard timeout. Output goes to a temp file rather than a
    /// pipe so a grandchild holding the descriptor can't block the read.
    private static func git(_ path: String, _ args: [String]) -> String? {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoorg-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL) else { return nil }
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
        do { try proc.run() } catch { return nil }

        if done.wait(timeout: .now() + 2) == .timedOut {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + 1)
            return nil
        }

        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: outURL),
              let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty
        else { return nil }
        return out
    }
}

/// Resolves a project's org off the main thread, with a per-path cache.
/// `lookup` is injectable so tests can fake the (blocking) git work.
final class RepoOrgResolver {

    private let lookup: (String) -> String?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    init(queue: DispatchQueue = .global(qos: .userInitiated),
         lookup: @escaping (String) -> String? = RepoOrg.org(forProjectPath:)) {
        self.queue = queue
        self.lookup = lookup
    }

    /// `.some(org)` if resolved before (org may itself be nil); `.none` if unknown.
    func cached(_ path: String) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]
    }

    /// Calls `completion` on the main thread: immediately if cached, otherwise
    /// after the lookup finishes on `queue`.
    func resolve(_ path: String, completion: @escaping (String?) -> Void) {
        if let hit = cached(path) {
            completion(hit)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let org = self.lookup(path)
            self.lock.lock(); self.cache[path] = .some(org); self.lock.unlock()
            DispatchQueue.main.async { completion(org) }
        }
    }
}
