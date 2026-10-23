// NostromoKit — ApprovalStatusBook.swift
//
// AP2b: the latest approval status per tool call, kept for the session's lifetime so a row built
// later (scrolled back into view, a second window) still reads it. Bounded: at most
// `capacityPerTag` calls per focus, the least recently updated going first.

import Foundation

public struct ApprovalStatusBook: Equatable, Sendable {

    public static let capacityPerTag = 500

    private struct Entry: Equatable, Sendable {
        var status: ApprovalRowStatus
        var tag: String
        /// Rises with every update: the larger, the more recent.
        var stamp: UInt64
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var ids: [String: Set<String>] = [:]
    private var clock: UInt64 = 0

    public init(capacityPerTag: Int = ApprovalStatusBook.capacityPerTag) {
        self.capacity = max(1, capacityPerTag)
    }

    /// Record `status` for the call `toolUseId` of focus `tag`. `.withdrawn` forgets the call.
    public mutating func set(_ status: ApprovalRowStatus, toolUseId: String, tag: String) {
        if let old = entries[toolUseId], old.tag != tag { forget(toolUseId) }
        guard status != .withdrawn else {
            forget(toolUseId)
            return
        }
        clock += 1
        entries[toolUseId] = Entry(status: status, tag: tag, stamp: clock)
        ids[tag, default: []].insert(toolUseId)
        if ids[tag]!.count > capacity, let oldest = ids[tag]!.min(by: { entries[$0]!.stamp < entries[$1]!.stamp }) {
            forget(oldest)
        }
    }

    /// The status recorded for a call, whichever focus it belongs to.
    public func status(toolUseId: String) -> ApprovalRowStatus? { entries[toolUseId]?.status }

    /// How many calls are recorded for `tag`.
    public func count(tag: String) -> Int { ids[tag]?.count ?? 0 }

    /// What one row says about its calls: `.awaiting` if any is waiting; else a refusal (denied,
    /// timed out, restarted, blocked) outranks an approval, so a row never reads "approved" for a
    /// group that had a call refused; within a tier the most recently updated one. Nil when none of
    /// `toolUseIds` has a status.
    public func headline(toolUseIds: [String]) -> ApprovalRowStatus? {
        var latest: Entry?
        var latestRefusal: Entry?
        for id in toolUseIds {
            guard let entry = entries[id] else { continue }
            if entry.status.isAwaiting { return .awaiting }
            if latest == nil || entry.stamp > latest!.stamp { latest = entry }
            if entry.status.isRefusal, latestRefusal == nil || entry.stamp > latestRefusal!.stamp { latestRefusal = entry }
        }
        return (latestRefusal ?? latest)?.status
    }

    private mutating func forget(_ toolUseId: String) {
        guard let entry = entries.removeValue(forKey: toolUseId) else { return }
        ids[entry.tag]?.remove(toolUseId)
        if ids[entry.tag]?.isEmpty == true { ids.removeValue(forKey: entry.tag) }
    }
}
