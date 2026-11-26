// NostromoKit — PushPayload.swift
//
// What a delivered push carries for routing a tap (W13), parsed from the notification's `userInfo`.
// Every value is from the closed vocabulary the relay is allowed to send: the item's opaque
// reference, its kind, the host label, a short reference (`Job 3f9a1c2e`, `PR #4821`) and whether
// this is the replacement that withdraws the item. Shared with W16's notification service extension.
//
// Tolerant: unknown keys are ignored; a payload missing `item`, `kind` or `host`, or naming a kind
// this build does not know, is `nil` and the app just opens normally.

import Foundation

public struct PushPayload: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case mother, decision, review, summary
    }

    /// The item's opaque `item_ref` (the relay's collapse id).
    public let item: String
    public let kind: Kind
    /// The host label as the operator knows it (`kobe`, `tokyo`).
    public let host: String
    /// `Job 3f9a1c2e`, `PR #4821`; absent for a decision and a summary.
    public let ref: String?
    /// `true` on the passive replacement that says the item no longer needs the operator.
    public let resolved: Bool

    public init(item: String, kind: Kind, host: String, ref: String? = nil, resolved: Bool = false) {
        self.item = item
        self.kind = kind
        self.host = host
        self.ref = ref
        self.resolved = resolved
    }

    /// The payload in a notification's `userInfo`, or `nil` if it is not one of ours.
    public static func parse(userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let item = userInfo["item"] as? String, !item.isEmpty,
              let kindWord = userInfo["kind"] as? String, let kind = Kind(rawValue: kindWord),
              let host = userInfo["host"] as? String, !host.isEmpty
        else { return nil }
        return PushPayload(item: item, kind: kind, host: host,
                           ref: userInfo["ref"] as? String,
                           resolved: userInfo["resolved"] as? Bool ?? false)
    }
}
