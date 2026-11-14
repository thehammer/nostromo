import Foundation

/// Ranks a session's commands for what the user has typed after the `/`.
///
/// Case-insensitive, in this order: an exact name match, a name prefix, a prefix of the segment
/// after `:` (`hookify:list` for `li`), an alias prefix, then a subsequence match. Ties sort by
/// name. An empty query returns everything sorted by name. Pure, and fast enough for 500 entries
/// per keystroke.
public enum SlashCommandFilter {

    public static func rank(query: String, in entries: [SlashCommandEntryWire]) -> [SlashCommandEntryWire] {
        let q = query.lowercased()
        if q.isEmpty { return entries.sorted { $0.name < $1.name } }

        var scored: [(tier: Int, entry: SlashCommandEntryWire)] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            if let tier = tier(of: entry, query: q) { scored.append((tier, entry)) }
        }
        scored.sort { a, b in
            a.tier != b.tier ? a.tier < b.tier : a.entry.name < b.entry.name
        }
        return scored.map(\.entry)
    }

    /// 0 exact, 1 name prefix, 2 prefix after `:`, 3 alias prefix, 4 subsequence; nil: no match.
    static func tier(of entry: SlashCommandEntryWire, query q: String) -> Int? {
        let name = entry.name.lowercased()
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if let colon = name.firstIndex(of: ":"), name[name.index(after: colon)...].hasPrefix(q) { return 2 }
        if entry.aliases.contains(where: { $0.lowercased().hasPrefix(q) }) { return 3 }
        if isSubsequence(q, of: name) { return 4 }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var n = needle.utf8.makeIterator()
        guard var want = n.next() else { return true }
        for byte in haystack.utf8 where byte == want {
            guard let next = n.next() else { return true }
            want = next
        }
        return false
    }
}
