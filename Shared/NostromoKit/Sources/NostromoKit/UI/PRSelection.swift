// NostromoKit — PRSelection.swift
//
// Which PR-queue rows are "marked" (highlighted). Pure, so both clients and the
// tests share one rule instead of each re-deriving it inside a SwiftUI body.

import Foundation

/// A PR, by the identity the queue and the daemon both use.
public struct PRRef: Equatable, Hashable, Sendable {
    public let repo: String
    public let number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }
}

public enum PRSelection {

    /// Whether the queue row for `(repo, number)` is highlighted.
    ///
    /// Two independent reasons, either is enough:
    /// - `addressMarked`: an agent pointed at this row (`show review_queue` with a
    ///   `queue_row` anchor) — the pre-existing mark, unchanged.
    /// - `selected`: this is the PR the focus is reviewing right now (its pin), or
    ///   the one the operator just clicked. This is what lets the operator see,
    ///   at a glance, which PR Perri is on while she works the queue.
    ///
    /// Compared on `repo` + `number` together: the same number in two repos is
    /// two PRs, so `#5100` in admin-portal never highlights `#5100` in payments.
    public static func isMarked(
        repo: String,
        number: Int,
        addressMarked: Bool,
        selected: PRRef?
    ) -> Bool {
        if addressMarked { return true }
        guard let selected else { return false }
        return selected.repo == repo && selected.number == number
    }
}
