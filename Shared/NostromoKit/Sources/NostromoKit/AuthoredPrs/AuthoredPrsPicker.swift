import Foundation

// "Choose focus…": which focuses the picker offers for a PR the daemon could not give one owner.

/// An open focus the picker may offer. `repoName` is the last component of its project folder.
public struct AuthoredPrPickerFocus: Equatable, Sendable {
    public var tag: String
    public var name: String
    public var repoName: String?
    public init(tag: String, name: String, repoName: String? = nil) {
        self.tag = tag; self.name = name; self.repoName = repoName
    }
}

public struct AuthoredPrPickerEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case focus(tag: String)
        case startSession
    }
    public var kind: Kind
    public var title: String
    /// How it was found (`Mother job a1b2c3`, `On branch`, `Linked`), or its project for an unknown owner.
    public var detail: String?
}

public enum AuthoredPrsPicker {
    public static let startTitle = "Start a session…"

    /// May a PR notice go to this focus? The daemon's rule (`is_tellable_focus` in `authored_prs/mod.rs`): never a
    /// built-in focus and never one running a Fred, Teri or Huey agent, with or without a plugin qualifier.
    /// Checked against the same table as the daemon's (`tests/fixtures/authored_prs/tellable_focuses.json`).
    public static func isTellable(builtIn: Bool, agentName: String) -> Bool {
        if builtIn { return false }
        let bare = agentName.split(separator: ":", omittingEmptySubsequences: false).last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return !["fred", "teri", "huey"].contains(bare.lowercased())
    }

    /// The entries, in order; the last is always Start a session…. Nothing is preselected by the caller.
    ///
    /// - ambiguous: the open candidates, each with how it was found.
    /// - anything else (unknown): every open focus, those whose project's repo name matches the PR's repo first.
    public static func entries(for pr: AuthoredPr, openFocuses: [AuthoredPrPickerFocus]) -> [AuthoredPrPickerEntry] {
        var out: [AuthoredPrPickerEntry] = []
        if pr.owner.kind == .ambiguous {
            let open = Set(openFocuses.map(\.tag))
            for c in pr.owner.candidates where !c.closed && open.contains(c.tag) {
                out.append(AuthoredPrPickerEntry(kind: .focus(tag: c.tag), title: c.name.isEmpty ? c.tag : c.name,
                                                 detail: how(c)))
            }
        } else {
            let repo = pr.repo.split(separator: "/", maxSplits: 1).last.map(String.init)?.lowercased() ?? ""
            let matches: (AuthoredPrPickerFocus) -> Bool = { $0.repoName?.lowercased() == repo && !repo.isEmpty }
            let ordered = openFocuses.filter(matches) + openFocuses.filter { !matches($0) }
            for f in ordered {
                out.append(AuthoredPrPickerEntry(kind: .focus(tag: f.tag), title: f.name.isEmpty ? f.tag : f.name,
                                                 detail: f.repoName))
            }
        }
        out.append(AuthoredPrPickerEntry(kind: .startSession, title: startTitle, detail: nil))
        return out
    }

    static func how(_ c: AuthoredPrCandidate) -> String? {
        switch c.via {
        case .motherJob: return c.jobId.map { "Mother job \($0)" } ?? "Mother job"
        case .onBranch: return "On branch"
        case .linked: return "Linked"
        case .unknown: return nil
        }
    }
}
