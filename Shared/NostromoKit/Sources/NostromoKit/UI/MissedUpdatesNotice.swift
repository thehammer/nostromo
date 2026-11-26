// NostromoKit — MissedUpdatesNotice.swift
//
// What a list says when the daemon reported a `gap` for its topic (W12): frames were not delivered
// to this connection, so the list may be stale until the subscription is made again.

import Foundation

public enum MissedUpdatesNotice {
    /// The line shown above a list whose topic had a `gap`.
    public static let text = "Updates may have been missed — pull to refresh"

    /// The topics the Mother jobs list follows.
    public static let motherTopics: Set<String> = ["mother_jobs"]
    /// The topics the Perri list follows.
    public static let perriTopics: Set<String> = ["perri"]

    /// Is the notice due for a list that follows `topics`, given the store's `missed` set?
    public static func isDue(for topics: Set<String>, missed: Set<String>) -> Bool {
        !topics.isDisjoint(with: missed)
    }
}
