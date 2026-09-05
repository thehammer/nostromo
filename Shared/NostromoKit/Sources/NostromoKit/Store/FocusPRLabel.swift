// NostromoKit — FocusPRLabel.swift
//
// The one shared derivation behind the PRD's operator-visibility requirement
// (pr-review-concurrency-model.md): "a focus that has a PR under review says
// so, on screen, without anyone calling a tool. Repo and number, plainly, in
// that focus. A focus with none says it has none."
//
// Every surface that shows this — the macOS sidebar row's secondary line
// (SidenavGrouping.swift), the iOS focus list row and focus view's top bar
// (FocusGrouping.swift, PRLabelBar.swift) — calls into this one function
// rather than inlining `payload.repo`/`payload.number` itself, so the
// pre-W7/post-W7 source swap (see the W8 plan's D2) touches no view: only
// what feeds `repo`/`number` into `label`/`secondary` changes.
public enum FocusPRLabel {

    /// The explicit string a focus with no PR under review renders. Never
    /// empty, never nil — `secondary(repo:number:fallback:)` never returns
    /// anything else when there's nothing to say, which is what keeps every
    /// sidebar row's height stable whether or not it has a PR loaded (D6).
    public static let noPR: String = "No PR"

    /// The last path segment of `repo` — `"Carefeed/admin-portal"` becomes
    /// `"admin-portal"`. Returns `repo` unchanged when there's no `"/"`.
    public static func shortRepo(_ repo: String) -> String {
        guard let slash = repo.lastIndex(of: "/") else { return repo }
        return String(repo[repo.index(after: slash)...])
    }

    /// `"#1234 · admin-portal"` when both `repo` and `number` are present;
    /// `noPR` otherwise.
    ///
    /// The number comes FIRST, deliberately (D4): a sidebar row truncates
    /// with `.byTruncatingTail`, which eats characters from the END of the
    /// string. The number is the identifying part and must never be the
    /// thing that gets ellipsised — putting it at the front, ahead of the
    /// (possibly long) repo name, puts it where truncation cannot reach it.
    public static func label(repo: String?, number: Int?) -> String {
        guard let repo, let number else { return noPR }
        return "#\(number) · \(shortRepo(repo))"
    }

    /// The sidebar/row's ONE secondary-line string (D1, D5, D6).
    ///
    /// Precedence, in order: the PR under review (identity) beats
    /// `fallback` (narration — a session summary, or a same-agent-name
    /// disambiguation string), which beats `noPR`. The PR winning over the
    /// fallback is D5's explicit, deliberate choice, not an accident of
    /// argument order: a focus reviewing a PR is answering the PRD's "which
    /// PR am I in" risk, and that identity question outranks a session
    /// summary's narration.
    ///
    /// NEVER returns nil and NEVER returns `""` — every row always has
    /// something to show, which is what keeps a row's height from changing
    /// when a PR loads or clears (D6).
    public static func secondary(repo: String?, number: Int?, fallback: String?) -> String {
        if repo != nil, number != nil {
            return label(repo: repo, number: number)
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return noPR
    }
}
