import Foundation
import NostromoKit

// MARK: - NavRow

/// A render row in the grouped sidebar.
///
/// `buildNavRows` converts a flat `[Focus]` array into an ordered list of these rows.
/// The list is deterministic (no dict-order dependency) and AppKit-free, so it is
/// unit-testable without a host app.
enum NavRow: Equatable {
    /// A non-interactive org-section header (e.g. "CAREFEED").
    case orgHeader(String)
    /// A non-interactive repo-group header shown when ≥2 focuses share the same repo.
    case repoHeader(String)
    /// A clickable focus item.
    ///
    /// - Parameters:
    ///   - label:     Resolved primary label (may differ from `focus.displayName`).
    ///   - secondary: Disambiguation line — the focus's PR under review (W8),
    ///     a session summary, or a short focus id. `buildNavRows` never
    ///     actually produces `nil` here (see its doc comment, D6); the type
    ///     stays optional only because `NavRow` predates that guarantee.
    ///   - indented:  True when nested under a `repoHeader`.
    case focus(Focus, label: String, secondary: String?, indented: Bool)
}

// MARK: - Grouping

/// Convert a flat focus list into an ordered list of sidebar render rows.
///
/// Grouping rules:
/// - Focuses are bucketed by `effectiveOrg`.
/// - Org ordering: Carefeed first, Personal second, then any others alphabetically.
/// - Within each org, built-in (pathless) focuses come first in canonical order
///   (`fred → mother → perri → teri`), remaining pathless focuses alphabetically.
/// - Repo groups follow, sorted alphabetically by `repoName`.
/// - A repo with exactly one focus emits a single `.focus` row (no repo header);
///   a repo with ≥2 focuses emits `.repoHeader` + indented `.focus` rows.
/// - Primary label: a focus's `label` (when set) wins over the default
///   (`agentTag.capitalized` / "Agent in Repo" / repo name).
/// - Secondary line: a Perri focus shows its PR under review (via `prFor`), or
///   "No PR" (`FocusPRLabel.noPR`) when it has none — the PR is the context of what
///   Perri is doing. Every other agent's focus shows `branch`, `branch · summary`,
///   or the summary alone (`branchFor` / `sessionSummary`, collapsed to one line),
///   followed — only when two same-agent focuses in the same repo are otherwise
///   indistinguishable (same label, same branch, no summary) — by the first 8
///   chars of `id` as a last resort. Never `nil` (W8, D6: a row's height must not
///   change when a summary, branch or PR loads or clears, so every row always has a
///   second line, empty or not).
///
/// - Parameter prFor: Resolves a focus's `sessionTag` to its PR under review
///   (`repo`, `number`), both `nil` when it has none. Defaults to "no focus has a
///   PR" so every existing caller keeps compiling unchanged.
/// - Parameter branchFor: Resolves a focus to its checkout's current git branch,
///   `nil` when unknown. Defaults to "no branch known".
/// - Parameter badgeDetailFor: Resolves a focus's `sessionTag` to its badge detail
///   line. Used as the second line of the built-in Fred, Mother and Teri rows when
///   non-nil; defaults to "no badge". Still never produces a `nil` second line.
func buildNavRows(
    _ focuses: [Focus],
    prFor: (String) -> (repo: String?, number: Int?) = { _ in (nil, nil) },
    branchFor: (Focus) -> String? = { _ in nil },
    badgeDetailFor: (String) -> String? = { _ in nil }
) -> [NavRow] {
    var rows: [NavRow] = []

    /// One line, never wrapping: newlines in a summary become spaces.
    func summaryOf(_ f: Focus) -> String? {
        guard let summary = f.sessionSummary else { return nil }
        let line = summary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    func branchOf(_ f: Focus) -> String? {
        guard f.projectPath != nil, let branch = branchFor(f), !branch.isEmpty else { return nil }
        return branch
    }

    /// Same-agent focuses that look identical (label, branch, no summary) share a
    /// key; the caller gives those the short id as a last-resort disambiguator.
    func lookAlikeKey(_ f: Focus) -> String? {
        guard summaryOf(f) == nil else { return nil }
        return [f.agentTag, Focus.normalizedLabel(f.label) ?? "", branchOf(f) ?? ""]
            .joined(separator: "\u{1F}")
    }

    // Only a Perri focus shows its PR under review: that is the context of what
    // it is doing. Every other agent's focus is about some other activity, so
    // a PR label would be noise there; it shows `branch · summary` (plus the
    // optional `idSuffix`) instead. A Perri focus with nothing loaded says
    // "No PR" (the PRD's "a focus with none says it has none") rather than a
    // stale session summary. Never nil, so every row keeps the same two-line
    // height (D6) — a row with nothing to say gets "" rather than no second line.
    func secondaryLine(for f: Focus, idSuffix: String?) -> String {
        if f.agentTag.lowercased() == "perri" {
            let (repo, number) = prFor(f.sessionTag)
            return FocusPRLabel.secondary(repo: repo, number: number, fallback: nil)
        }
        if f.isBuiltIn, ["fred", "mother", "teri"].contains(f.agentTag.lowercased()),
           let detail = badgeDetailFor(f.sessionTag) {
            return detail
        }
        return [branchOf(f), summaryOf(f), idSuffix].compactMap { $0 }.joined(separator: " · ")
    }

    /// A focus row: the user's label when set, else `defaultLabel`.
    func focusRow(_ f: Focus, defaultLabel: String, idSuffix: String? = nil, indented: Bool) -> NavRow {
        .focus(f, label: Focus.normalizedLabel(f.label) ?? defaultLabel,
               secondary: secondaryLine(for: f, idSuffix: idSuffix), indented: indented)
    }

    // 1. Bucket by effectiveOrg
    let byOrg = Dictionary(grouping: focuses) { $0.effectiveOrg }

    // 2. Org ordering: Carefeed → Personal → others (alpha)
    let sortedOrgs = byOrg.keys.sorted { lhs, rhs in
        orgRank(lhs) < orgRank(rhs)
    }

    // 3. Emit rows for each org
    var isFirstOrg = true
    for org in sortedOrgs {
        let orgFocuses = byOrg[org] ?? []
        rows.append(.orgHeader(isFirstOrg ? org.uppercased() : org.uppercased()))
        isFirstOrg = false

        // a. Org-level (pathless) focuses — canonical built-in order, then alpha
        let pathless = orgFocuses.filter { $0.projectPath == nil }
        for f in sortedPathlessFocuses(pathless) {
            rows.append(focusRow(f, defaultLabel: f.agentTag.capitalized, indented: false))
        }

        // b. Repo groups — alphabetical by repoName
        let pathBearing = orgFocuses.filter { $0.projectPath != nil }
        let byRepo = Dictionary(grouping: pathBearing) { $0.repoName ?? "" }
        let sortedRepos = byRepo.keys.filter { !$0.isEmpty }.sorted()

        for repoName in sortedRepos {
            let group = (byRepo[repoName] ?? []).sorted {
                $0.agentTag == $1.agentTag ? $0.id < $1.id : $0.agentTag < $1.agentTag
            }

            if group.count == 1 {
                let f = group[0]
                let defaultLabel = f.agentTag.lowercased() == "claudia"
                    ? repoName
                    : "\(f.agentTag.capitalized) in \(repoName)"
                rows.append(focusRow(f, defaultLabel: defaultLabel, indented: false))
            } else {
                rows.append(.repoHeader(repoName))

                var lookAlikes: [String: Int] = [:]
                for f in group { if let key = lookAlikeKey(f) { lookAlikes[key, default: 0] += 1 } }

                for f in group {
                    let isLookAlike = lookAlikeKey(f).map { lookAlikes[$0, default: 0] > 1 } ?? false
                    rows.append(focusRow(f, defaultLabel: f.agentTag.capitalized,
                                         idSuffix: isLookAlike ? String(f.id.prefix(8)) : nil,
                                         indented: true))
                }
            }
        }
    }

    return rows
}

// MARK: - Helpers

/// Canonical sort rank for org names: Carefeed = 0, Personal = 1, others = 2 + alpha.
private func orgRank(_ org: String) -> (Int, String) {
    switch org {
    case "Carefeed": return (0, org)
    case "Personal":  return (1, org)
    default:          return (2, org)
    }
}

private let builtInOrder = ["fred", "mother", "perri", "teri"]

/// Sort pathless focuses: canonical built-in order first, then remaining alphabetically.
private func sortedPathlessFocuses(_ focuses: [Focus]) -> [Focus] {
    var canonicals: [Focus] = []
    var rest: [Focus] = []
    let byTag = Dictionary(grouping: focuses) { $0.agentTag }

    for tag in builtInOrder {
        if let f = byTag[tag]?.first { canonicals.append(f) }
    }
    for f in focuses where !builtInOrder.contains(f.agentTag) {
        rest.append(f)
    }
    rest.sort { $0.agentTag < $1.agentTag }
    return canonicals + rest
}

// MARK: - Attention

extension NavRow {
    /// True for a focus row whose focus has an outstanding attention request
    /// (see `AttentionRegistry`). Headers never do. Deliberately not a
    /// parameter of `buildNavRows`: attention changes far more often than the
    /// row structure, and must never alter row content or height.
    func needsAttention(in tags: Set<String>) -> Bool {
        guard case .focus(let focus, _, _, _) = self else { return false }
        return tags.contains(focus.sessionTag)
    }
}
