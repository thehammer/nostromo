// NostromoKit — TrackerDiff.swift
//
// Old rows × new rows → keyed operations (design contract §9). The pane applies them to its row
// views so an update touches only the rows that changed; a row whose content is identical yields
// no operation at all, so pushing the same board twice changes nothing on screen.

import Foundation

public enum TrackerDiffOp: Equatable {
    /// A new row, at `at` in the new rows.
    case insert(TrackerRow, at: Int)
    /// A row whose key stays but whose content changed.
    case update(TrackerRow)
    case remove(key: String)
    /// A row that changed its order relative to the rows around it; `to` is its index in the
    /// new rows. Rows that only shift because others were inserted or removed are not moves.
    case move(key: String, to: Int)

    public var key: String {
        switch self {
        case .insert(let row, _), .update(let row): return row.key
        case .remove(let key), .move(let key, _): return key
        }
    }
}

public enum TrackerDiff {

    /// Removes (old order), then inserts, moves and updates (new order).
    public static func ops(from old: [TrackerRow], to new: [TrackerRow]) -> [TrackerDiffOp] {
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let newKeys = Set(new.map(\.key))

        var ops: [TrackerDiffOp] = old.filter { !newKeys.contains($0.key) }.map { .remove(key: $0.key) }

        for (index, row) in new.enumerated() where oldByKey[row.key] == nil {
            ops.append(.insert(row, at: index))
        }

        // Common keys in each order; the longest common subsequence stays put, the rest moved.
        let commonOld = old.map(\.key).filter { newKeys.contains($0) }
        let commonNew = new.map(\.key).filter { oldByKey[$0] != nil }
        if commonOld != commonNew {
            let staying = longestCommonSubsequence(commonOld, commonNew)
            for (index, row) in new.enumerated() where oldByKey[row.key] != nil && !staying.contains(row.key) {
                ops.append(.move(key: row.key, to: index))
            }
        }

        for row in new {
            if let previous = oldByKey[row.key], previous != row {
                ops.append(.update(row))
            }
        }
        return ops
    }

    /// The keys of a longest common subsequence of `a` and `b` (both duplicate-free).
    ///
    /// The common prefix and suffix are part of some longest common subsequence, so they are taken
    /// first and the O(n*m) table is built only over what is left; a board with one changed row
    /// (the usual update) costs O(n).
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Set<String> {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        var keys = Set(a[..<prefix])
        keys.formUnion(a[(a.count - suffix)...])
        keys.formUnion(tableLongestCommonSubsequence(Array(a[prefix..<(a.count - suffix)]),
                                                     Array(b[prefix..<(b.count - suffix)])))
        return keys
    }

    private static func tableLongestCommonSubsequence(_ a: [String], _ b: [String]) -> Set<String> {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { table[i * (m + 1) + j] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                let value = a[i] == b[j] ? at(i + 1, j + 1) + 1 : max(at(i + 1, j), at(i, j + 1))
                table[i * (m + 1) + j] = value
            }
        }
        var keys = Set<String>()
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                keys.insert(a[i])
                i += 1
                j += 1
            } else if at(i + 1, j) >= at(i, j + 1) {
                i += 1
            } else {
                j += 1
            }
        }
        return keys
    }
}
