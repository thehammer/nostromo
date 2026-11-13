import Foundation

/// One slash command a session's CLI reports (`session_commands`). Decoded leniently: unknown
/// fields are ignored and a missing optional field is nil/empty, so a newer daemon's extras never
/// fail the list. Mirrors `SlashCommandEntry` in Rust.
public struct SlashCommandEntryWire: Codable, Equatable {
    public let name: String
    /// One sanitised line; nil when the CLI gave none. Never made up.
    public let description: String?
    public let argumentHint: String?
    public let aliases: [String]
    public let builtin: Bool

    public init(name: String, description: String? = nil, argumentHint: String? = nil,
                aliases: [String] = [], builtin: Bool = false) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey {
        case name, description, aliases, builtin
        case argumentHint = "argument_hint"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        argumentHint = (try? c.decodeIfPresent(String.self, forKey: .argumentHint)) ?? nil
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        builtin = (try? c.decodeIfPresent(Bool.self, forKey: .builtin)) ?? false
    }
}

/// `session_commands`: the answer to `session_commands_get`. `source` is `cli` (the CLI's own
/// described list), `init` (names only) or `none`. Local clients only.
public struct SessionCommandsWire: Decodable, Equatable {
    public let requestId: String
    public let tag: String
    public let source: String
    public let commands: [SlashCommandEntryWire]

    public init(requestId: String, tag: String, source: String, commands: [SlashCommandEntryWire]) {
        self.requestId = requestId
        self.tag = tag
        self.source = source
        self.commands = commands
    }

    enum CodingKeys: String, CodingKey {
        case tag, source, commands
        case requestId = "request_id"
    }

    private struct Lossy: Decodable {
        let value: SlashCommandEntryWire?
        init(from decoder: Decoder) throws { value = try? SlashCommandEntryWire(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        tag = try c.decode(String.self, forKey: .tag)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "none"
        // A bad entry is skipped, never fatal.
        commands = ((try? c.decodeIfPresent([Lossy].self, forKey: .commands)) ?? []).compactMap(\.value)
    }
}
