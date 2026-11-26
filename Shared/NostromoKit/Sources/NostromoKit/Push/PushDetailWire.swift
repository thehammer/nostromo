// NostromoKit — PushDetailWire.swift
//
// `push_detail` (W16): what the phone's Notification Service Extension asks the primary, and the
// answer. Mirrors `ClientMsg::PushDetail` and `ServerMsg::PushDetail` in `src/ipc/protocol.rs`.
//
// A paired phone's verb, scoped to its own connection. The reply says whether the item still waits
// and, only for a personal, non-PHI item in a non-work repository, its first line. The decoder is
// the extension's trust boundary for what the daemon sends back: it takes bounded input, ignores
// every field it does not know, and a reply that is not exactly ours is `nil`, never a crash.

import Foundation

/// Asks for one waiting item's detail line. Mirrors `ClientMsg::PushDetail`.
public struct ClientPushDetail: Encodable, Equatable {
    let type_ = "push_detail"
    public let itemRef: String

    public init(itemRef: String) { self.itemRef = itemRef }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case itemRef = "item_ref"
    }
}

/// The answer to `push_detail`.
public struct PushDetailWire: Equatable, Sendable {
    /// A reply larger than this is not ours: the real one is a few hundred bytes.
    public static let maxFrameBytes = 16 * 1024
    /// The daemon cuts the line at 140 characters; a longer one is cut here too.
    public static let maxTextCharacters = 140

    public let itemRef: String
    /// Whether the item still waits on the operator.
    public let waiting: Bool
    /// The first line of the item's question, PR title or decision prompt; `nil` when the daemon
    /// withholds it (a work host, PHI, a work owner, a sensitive tag), which is the common case.
    public let text: String?
    public let host: String?

    public init(itemRef: String, waiting: Bool, text: String?, host: String?) {
        self.itemRef = itemRef
        self.waiting = waiting
        self.text = text
        self.host = host
    }

    /// The `push_detail` frame in `data`, or `nil` if it is oversized, not JSON, not a
    /// `push_detail`, or lacks a string `item_ref` and a boolean `waiting`.
    public static func parse(_ data: Data) -> PushDetailWire? {
        guard data.count <= maxFrameBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["type"] as? String == "push_detail",
              let itemRef = json["item_ref"] as? String,
              let waiting = json["waiting"] as? Bool
        else { return nil }
        let text = (json["text"] as? String).map { String($0.prefix(maxTextCharacters)) }
        return PushDetailWire(itemRef: itemRef, waiting: waiting, text: text, host: json["host"] as? String)
    }
}
