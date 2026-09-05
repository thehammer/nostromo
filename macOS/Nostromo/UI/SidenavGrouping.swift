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
/// - Disambiguation (`secondary`): the PR under review (via `prFor`) always wins
///   when present (W8, D5 — identity beats narration); otherwise use `sessionSummary`
///   when non-nil/empty; else use the first 8 chars of `id` only when two focuses in
///   the same repo share an `agentTag` (Phase 1 fallback); otherwise an explicit
///   "no PR" string (`FocusPRLabel.noPR`) — never `nil` (W8, D6: a row's height must
///   not change when a PR loads or clears, so every row always has a secondary line).
///
/// - Parameter prFor: Resolves a focus's `sessionTag` to its PR under review
///   (`repo`, `number`), both `nil` when it has none. Defaults to "no focus has a
///   PR" so every existing caller keeps compiling unchanged.
func buildNavRows(
    _ focuses: [Focus],
    prFor: (String) -> (repo: String?, number: Int?) = { _ in (nil, nil) }
) -> [NavRow] {
    var rows: [NavRow] = []

    // The PR under review always wins over any other candidate for the
    // secondary line (D5); the result is never nil (D6).
    func secondaryLine(forTag tag: String, fallback: String?) -> String {
        let (repo, number) = prFor(tag)
        return FocusPRLabel.secondary(repo: repo, number: number, fallback: fallback)
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
            rows.append(.focus(f, label: f.agentTag.capitalized,
                               secondary: secondaryLine(forTag: f.sessionTag, fallback: nil), indented: false))
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
                let label = f.agentTag.lowercased() == "claudia"
                    ? repoName
                    : "\(f.agentTag.capitalized) in \(repoName)"
                rows.append(.focus(f, label: label,
                                   secondary: secondaryLine(forTag: f.sessionTag, fallback: nil), indented: false))
            } else {
                rows.append(.repoHeader(repoName))

                // Count agentTag occurrences within the group for disambiguation
                var tagCount: [String: Int] = [:]
                for f in group { tagCount[f.agentTag, default: 0] += 1 }

                for f in group {
                    let fallback: String?
                    if let summary = f.sessionSummary, !summary.isEmpty {
                        fallback = summary
                    } else if (tagCount[f.agentTag] ?? 0) > 1 {
                        fallback = String(f.id.prefix(8))
                    } else {
                        fallback = nil
                    }
                    rows.append(.focus(f, label: f.agentTag.capitalized,
                                       secondary: secondaryLine(forTag: f.sessionTag, fallback: fallback), indented: true))
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
