import Foundation

/// One line of the Overview's DEPENDS ON section.
struct MotherDependencyRow: Equatable {
    let id: String
    let shortId: String
    let title: String?
    let state: String?
    let inQueue: Bool
    let reasonLine: String?
    let isBlocked: Bool
    let accessibilityLabel: String
    /// `job <short> · <title>`, or `job <short> · <why it is not in the queue>`: the row's one visible line.
    let lineText: String
}

/// Pure presentation of a job's dependencies. Shows only what Mother wrote: it never
/// evaluates whether a dependency is satisfied (Mother counts one done only once its PR merged).
enum MotherDependencyPresentation {
    static let titleLimit = 120

    static func rows(for job: MotherJob, lookup: (String) -> MotherJob?) -> [MotherDependencyRow] {
        var ids = job.dependsOn
        let wait = job.state == "queued" ? job.depWait : nil
        if let wait, !ids.contains(wait.depId) { ids.append(wait.depId) }
        return ids.map { id in
            let named = (wait?.depId == id) ? wait : nil
            return row(id: id, wait: named, dep: lookup(id))
        }
    }

    static func shortId(_ id: String) -> String {
        if let dash = id.lastIndex(of: "-") {
            let tail = id[id.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy({ $0.isHexDigit }) { return String(tail) }
        }
        return String(id.prefix(16))
    }

    /// Plain single line: newlines and tabs become spaces, bounded with an ellipsis.
    static func boundedTitle(_ raw: String) -> String {
        let flat = String(raw.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })
        return flat.count > titleLimit ? String(flat.prefix(titleLimit)) + "…" : flat
    }

    /// The phrase after "on job <short>" in the list row's line two.
    static func phrase(for wait: MotherDepWait) -> String {
        switch wait.reason {
        case "pr_open": return "PR open, not merged"
        case "dep_not_finished": return "not finished"
        case "pr_state_unknown": return "PR state unknown"
        case "dep_failed": return "failed"
        case "dep_cancelled": return "cancelled"
        case "dep_missing": return "not found"
        case "dep_no_pr_url": return "no PR link"
        case "pr_closed_unmerged": return "PR closed unmerged"
        default: return sanitizedReason(wait.reason) ?? "an unknown reason"
        }
    }

    /// "Waiting: on job <short> (<phrase>)" or "Blocked: …".
    static func listLine(for wait: MotherDepWait) -> String {
        "\(wait.blocked ? "Blocked" : "Waiting"): on job \(shortId(wait.depId)) (\(phrase(for: wait)))"
    }

    private static func row(id: String, wait: MotherDepWait?, dep: MotherJob?) -> MotherDependencyRow {
        let short = shortId(id)
        let title = dep.map { boundedTitle($0.title.isEmpty ? $0.id : $0.title) }
        let missing = wait?.reason == "dep_missing"
        let state = dep?.state
        let reason = wait.map { reasonLine(for: $0) }
        var label = "Depends on job \(short)"
        let detail: String
        if let title, let state {
            detail = title
            label += ", \(title), \(state)."
        } else {
            detail = missing ? "Mother cannot find this job" : "not in the queue (archived or unknown)"
            label += ", \(detail)."
        }
        if let reason { label += " \(reason)" }
        return MotherDependencyRow(id: id, shortId: short, title: title, state: state,
                                   inQueue: dep != nil, reasonLine: reason,
                                   isBlocked: wait?.blocked ?? false,
                                   accessibilityLabel: label,
                                   lineText: "job \(short) · \(detail)")
    }

    static func reasonLine(for wait: MotherDepWait) -> String {
        switch wait.reason {
        case "pr_open": return "Waiting: its PR\(prSuffix(wait)) is open. Mother starts this job only after that PR merges."
        case "dep_not_finished": return "Waiting: it has not finished yet."
        case "pr_state_unknown": return "Waiting: Mother could not read its PR\(prSuffix(wait)) state yet and will check again."
        case "dep_failed": return "Blocked: it failed. Retry it, or force-start this job with --ignore-deps, or cancel this job."
        case "dep_cancelled": return "Blocked: it was cancelled. Force-start this job with --ignore-deps, or cancel it."
        case "dep_missing": return "Blocked: Mother cannot find it."
        case "dep_no_pr_url": return "Blocked: it succeeded without a PR link, so Mother cannot tell when it merges."
        case "pr_closed_unmerged": return "Blocked: its PR\(prSuffix(wait)) was closed without merging."
        default:
            return "\(wait.blocked ? "Blocked" : "Waiting"): Mother reports \(sanitizedReason(wait.reason) ?? "an unknown reason")"
        }
    }

    private static func prSuffix(_ wait: MotherDepWait) -> String {
        MotherJobListViewModel.prNumber(fromURL: wait.prURL).map { " (PR #\($0))" } ?? ""
    }

    private static func sanitizedReason(_ r: String) -> String? {
        guard !r.isEmpty, r.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" }) else { return nil }
        return r
    }
}
