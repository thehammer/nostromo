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

    /// Reads the `origin` remote (else the first remote) of the repo at `path`
    /// and maps it to an org. Returns nil on any error.
    static func org(forProjectPath path: String) -> String? {
        if let url = git(path, ["remote", "get-url", "origin"]),
           let org = org(forRemoteURL: url) {
            return org
        }
        guard let remotes = git(path, ["remote"]),
              let first = remotes.split(whereSeparator: \.isNewline).first.map(String.init),
              first != "origin",
              let url = git(path, ["remote", "get-url", first])
        else { return nil }
        return org(forRemoteURL: url)
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

        guard host.lowercased() == "github.com" else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[0])
    }

    private static func git(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Short timeout: kill a hung git rather than block the UI.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty
        else { return nil }
        return out
    }
}
