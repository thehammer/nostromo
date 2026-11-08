import Foundation

/// One `<cross-session-message>` of a `peer_message` turn origin (`stream_json::PeerMessageItem`):
/// a message another Claude session sent to this one. Every field is optional on the wire; the
/// daemon has already sanitised and capped the strings, and the marker text sanitises them again.
public struct PeerMessageItemWire: Codable, Equatable {
    public let fromName:   String?
    /// `bypass`, `default`, … any string is kept as text.
    public let fromMode:   String?
    public let fromSocket: String?
    public let body:       String
    public let truncated:  Bool

    public init(fromName: String? = nil, fromMode: String? = nil, fromSocket: String? = nil,
                body: String, truncated: Bool = false) {
        self.fromName = fromName
        self.fromMode = fromMode
        self.fromSocket = fromSocket
        self.body = body
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case fromName = "from_name", fromMode = "from_mode", fromSocket = "from_socket", body, truncated
    }

    /// Tolerant: absent or mistyped fields fall back (nil, `""`, false); unknown fields are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fromName: (try? c.decodeIfPresent(String.self, forKey: .fromName)) ?? nil,
                  fromMode: (try? c.decodeIfPresent(String.self, forKey: .fromMode)) ?? nil,
                  fromSocket: (try? c.decodeIfPresent(String.self, forKey: .fromSocket)) ?? nil,
                  body: (try? c.decodeIfPresent(String.self, forKey: .body)) ?? "",
                  truncated: (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false)
    }
}
