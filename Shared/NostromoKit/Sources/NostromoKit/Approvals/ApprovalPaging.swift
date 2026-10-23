// NostromoKit — ApprovalPaging.swift
//
// AP2b: `1 of 3`. Parallel requests for one focus page through one card, in arrival order. Each is
// answered on its own; there is no "allow all".

import Foundation

public struct ApprovalPage: Equatable, Sendable {
    /// 1-based.
    public let position: Int
    public let count: Int
    public let previousID: String?
    public let nextID: String?
    public let currentID: String

    public init(position: Int, count: Int, previousID: String?, nextID: String?, currentID: String) {
        self.position = position
        self.count = count
        self.previousID = previousID
        self.nextID = nextID
        self.currentID = currentID
    }

    /// `1 of 3`.
    public var label: String { "\(position) of \(count)" }
}

public enum ApprovalPaging {
    /// The page showing `current` among `ids` (arrival order, oldest first). `current` nil, or no
    /// longer among `ids`, shows the oldest. Nil when `ids` is empty.
    public static func page(ids: [String], current: String?) -> ApprovalPage? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ApprovalPage(position: index + 1, count: ids.count,
                            previousID: index > 0 ? ids[index - 1] : nil,
                            nextID: index + 1 < ids.count ? ids[index + 1] : nil,
                            currentID: ids[index])
    }
}
