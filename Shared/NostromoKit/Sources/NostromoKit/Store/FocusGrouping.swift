// NostromoKit — FocusGrouping.swift
//
// Port of macOS/Nostromo/UI/SidenavGrouping.swift grouping rules over
// `[FocusMeta]` instead of `[Focus]`.  Keeping the rules in NostromoKit means
// iOS and Mac render the same ordering without sharing code.

import Foundation

// MARK: - FocusRow

/// A render row in the grouped iOS focus list.
///
/// `buildFocusRows` converts a flat `[FocusMeta]` array into an ordered list of
/// these rows.  The ordering is deterministic (no dict-order dependency).
public enum FocusRow: Equatable, Identifiable {
    /// A non-interactive org-section header (e.g. "CAREFEED").
    case orgHeader(String)
    /// A non-interactive repo-group header shown when ≥2 focuses share the same repo.
    case repoHeader(String)
    /// A clickable focus item.
    ///
    /// - Parameters:
    ///   - label:     Resolved primary label.
    ///   - secondary: Disambiguation line — the focus's PR under review (W8),
    ///     a session summary, or an id prefix. `buildFocusRows` never actually
    ///     produces `nil` here (see its doc comment, D6); the type stays
    ///     optional only because `FocusRow` predates that guarantee.
    ///   - indented:  True when nested under a `repoHeader`.
    case focus(FocusMeta, label: String, secondary: String?, indented: Bool)

    public var id: String {
        switch self {
        case .orgHeader(let s):      return "org:\(s)"
        case .repoHeader(let s):     return "repo:\(s)"
        case .focus(let f, _, _, _): return "focus:\(f.tag)"
        }
    }
}

// MARK: - buildFocusRows

/// Convert a flat focus list into an ordered list of iOS render rows.
///
/// Grouping rules (mirrors `buildNavRows` in `macOS/Nostromo/UI/SidenavGrouping.swift`):
/// - Focuses are bucketed by `effectiveOrg`.
/// - Org ordering: Carefeed first, Personal second, then any others alphabetically.
/// - Within each org, pathless (built-in) focuses come first in canonical order
///   (`fred → mother → perri → teri`), then remaining pathless focuses alphabetically.
/// - Repo groups follow, sorted alphabetically by `projectName`.
/// - A repo with exactly one focus emits a single `.focus` row (no repo header);
///   a repo with ≥2 focuses emits `.repoHeader` + indented `.focus` rows.
/// - Disambiguation (`secondary`): the PR under review (via `prFor`) always wins
///   when present (W8, D5 — identity beats narration); otherwise use `sessionSummary`
///   when non-nil/non-empty; else use the tag's prefix only when two focuses in the
///   same repo share an `agentName`; otherwise an explicit "no PR" string
///   (`FocusPRLabel.noPR`) — never `nil` (W8, D6: a row's height must not change when
///   a PR loads or clears, so every row always has a secondary line).
///
/// - Parameter prFor: Resolves a focus's tag to its PR under review (`repo`, `number`),
///   both `nil` when it has none. Defaults to "no focus has a PR" so every existing
///   caller keeps compiling unchanged.
public func buildFocusRows(
    _ focuses: [FocusMeta],
    prFor: (String) -> (repo: String?, number: Int?) = { _ in (nil, nil) }
) -> [FocusRow] {
    var rows: [FocusRow] = []

    // The PR under review always wins over any other candidate for the
    // secondary line (D5); the result is never nil (D6).
    func secondary(forTag tag: String, fallback: String?) -> String {
        let (repo, number) = prFor(tag)
        return FocusPRLabel.secondary(repo: repo, number: number, fallback: fallback)
    }

    // 1. Bucket by effectiveOrg
    let byOrg = Dictionary(grouping: focuses) { $0.effectiveOrg }

    // 2. Org ordering: Carefeed → Personal → others (alpha)
    let sortedOrgs = byOrg.keys.sorted { lhs, rhs in
        focusOrgRank(lhs) < focusOrgRank(rhs)
    }

    // 3. Emit rows for each org
    for org in sortedOrgs {
        let orgFocuses = byOrg[org] ?? []
        rows.append(.orgHeader(org.uppercased()))

        // a. Pathless (built-in / org-level) focuses — canonical order, then alpha
        let pathless = orgFocuses.filter { $0.projectName == nil }
        for f in sortedPathlessFocusMetas(pathless) {
            rows.append(.focus(f, label: f.agentName.capitalized,
                               secondary: secondary(forTag: f.tag, fallback: nil), indented: false))
        }

        // b. Repo groups — alphabetical by projectName
        let pathBearing = orgFocuses.filter { $0.projectName != nil }
        let byRepo = Dictionary(grouping: pathBearing) { $0.projectName ?? "" }
        let sortedRepos = byRepo.keys.filter { !$0.isEmpty }.sorted()

        for repoName in sortedRepos {
            let group = (byRepo[repoName] ?? []).sorted {
                $0.agentName == $1.agentName ? $0.tag < $1.tag : $0.agentName < $1.agentName
            }

            if group.count == 1 {
                let f = group[0]
                let label = f.agentName.lowercased() == "claudia"
                    ? repoName
                    : "\(f.agentName.capitalized) in \(repoName)"
                rows.append(.focus(f, label: label,
                                   secondary: secondary(forTag: f.tag, fallback: nil), indented: false))
            } else {
                rows.append(.repoHeader(repoName))

                var agentCount: [String: Int] = [:]
                for f in group { agentCount[f.agentName, default: 0] += 1 }

                for f in group {
                    let fallback: String?
                    if let summary = f.sessionSummary, !summary.isEmpty {
                        fallback = summary
                    } else if (agentCount[f.agentName] ?? 0) > 1 {
                        fallback = String(f.tag.prefix(8))
                    } else {
                        fallback = nil
                    }
                    rows.append(.focus(f, label: f.agentName.capitalized,
                                       secondary: secondary(forTag: f.tag, fallback: fallback), indented: true))
                }
            }
        }
    }

    return rows
}

// MARK: - Helpers

/// Canonical sort rank for org names: Carefeed = 0, Personal = 1, others = 2 + alpha.
private func focusOrgRank(_ org: String) -> (Int, String) {
    switch org {
    case "Carefeed": return (0, org)
    case "Personal":  return (1, org)
    default:          return (2, org)
    }
}

private let focusBuiltInOrder = ["fred", "mother", "perri", "teri"]

/// Sort pathless focuses: canonical built-in order first, then remaining alphabetically.
private func sortedPathlessFocusMetas(_ focuses: [FocusMeta]) -> [FocusMeta] {
    var canonicals: [FocusMeta] = []
    var rest: [FocusMeta] = []
    let byAgent = Dictionary(grouping: focuses) { $0.agentName }

    for agent in focusBuiltInOrder {
        if let f = byAgent[agent]?.first { canonicals.append(f) }
    }
    for f in focuses where !focusBuiltInOrder.contains(f.agentName) {
        rest.append(f)
    }
    rest.sort { $0.agentName < $1.agentName }
    return canonicals + rest
}
