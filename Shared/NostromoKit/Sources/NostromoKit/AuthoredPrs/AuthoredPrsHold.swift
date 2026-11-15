import Foundation

/// A row the reader is selecting or pointing at must not move or vanish under the pointer.
public enum AuthoredPrsHold {
    /// The rows to display now.
    ///
    /// With nothing held this is `incoming` as it is. A held row that is on screen keeps its group and its
    /// place within the group, and stays even if `incoming` no longer has it; its other fields follow
    /// `incoming`. Once the hold ends, the next call applies every pending move and removal.
    public static func merge(displayed: [AuthoredPr], incoming: [AuthoredPr], held: Set<String>) -> [AuthoredPr] {
        guard !held.isEmpty else { return incoming }
        // Only a held row that is on screen keeps its place; one that is not yet shown is a new row like any other.
        let onScreen = Set(displayed.map(\.id))
        var byGroup: [AuthoredPrGroup: [AuthoredPr]] = [:]
        for pr in incoming where !(held.contains(pr.id) && onScreen.contains(pr.id)) { byGroup[pr.group, default: []].append(pr) }

        // Insert held rows from the top of each group down, so an earlier slot is filled before a later one.
        var holds: [(pr: AuthoredPr, slot: Int)] = []
        for old in displayed where held.contains(old.id) {
            var row: AuthoredPr = incoming.first(where: { $0.id == old.id }) ?? old
            row.group = old.group
            let siblings: [AuthoredPr] = displayed.filter { $0.group == old.group }
            let slot: Int = siblings.firstIndex(where: { $0.id == old.id }) ?? 0
            holds.append((row, slot))
        }
        let ordered = holds.sorted(by: { (a: (pr: AuthoredPr, slot: Int), b: (pr: AuthoredPr, slot: Int)) in a.slot < b.slot })
        for (pr, slot) in ordered {
            var rows: [AuthoredPr] = byGroup[pr.group] ?? []
            rows.insert(pr, at: min(slot, rows.count))
            byGroup[pr.group] = rows
        }
        return AuthoredPrGroup.displayOrder.flatMap { byGroup[$0] ?? [] }
    }
}

/// The only URLs the Overview opens.
public enum AuthoredPrsLinks {
    private static let ident = "[A-Za-z0-9._-]+"

    /// The PR's own URL, `https://github.com/<repo>/pull/<number>`, rebuilt from the row's `repo` and `number`.
    /// `url` (as sent by the daemon) must be exactly that shape and name the same repo (owner and repo compare
    /// case-insensitively, as GitHub does) and the same number; anything else yields nil.
    public static func pullRequestURL(_ url: String, repo: String, number: Int) -> URL? {
        let pattern = "^https://github\\.com/(\(ident))/(\(ident))/pull/(\\d+)\\z"
        guard number > 0, let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges == 4 else { return nil }
        func part(_ i: Int) -> String? { Range(match.range(at: i), in: url).map { String(url[$0]) } }
        guard let owner = part(1), let name = part(2), let n = part(3), Int(n) == number, !n.hasPrefix("0") else { return nil }
        let repoParts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2,
              repoParts[0].caseInsensitiveCompare(owner) == .orderedSame,
              repoParts[1].caseInsensitiveCompare(name) == .orderedSame else { return nil }
        return URL(string: "https://github.com/\(repo)/pull/\(number)")
    }
}
