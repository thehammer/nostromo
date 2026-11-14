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
        var byGroup: [AuthoredPrGroup: [AuthoredPr]] = [:]
        for pr in incoming where !held.contains(pr.id) { byGroup[pr.group, default: []].append(pr) }

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
    private static let pattern = try! NSRegularExpression(
        pattern: #"^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+\z"#)

    /// `url` as a URL, only if it is exactly `https://github.com/<owner>/<repo>/pull/<number>`.
    public static func pullRequestURL(_ url: String) -> URL? {
        let range = NSRange(url.startIndex..., in: url)
        guard pattern.firstMatch(in: url, range: range) != nil else { return nil }
        return URL(string: url)
    }
}
