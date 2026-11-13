import Foundation

/// The commands the picker offers for a session, merged from what the daemon reported.
///
/// * source `cli`: the daemon's entries; a missing description is filled from the fallback table by
///   exact name.
/// * source `init`: names only; descriptions come only from the table.
/// * source `none`, or an old daemon that reports nothing: the table itself, flagged `isFallback`.
public struct SlashCommandCatalog: Equatable {
    public let entries: [SlashCommandEntryWire]
    /// The list is the built-in table, not what the session reported: the picker says that
    /// skills and custom commands appear after the session's first message.
    public let isFallback: Bool

    public init(entries: [SlashCommandEntryWire], isFallback: Bool) {
        self.entries = entries
        self.isFallback = isFallback
    }

    /// What an old daemon, or no answer yet, gives.
    public static let fallback = SlashCommandCatalog(entries: BuiltinSlashCommands.fallback, isFallback: true)

    public static func make(source: String, commands: [SlashCommandEntryWire]) -> SlashCommandCatalog {
        switch source {
        case "cli", "init":
            guard !commands.isEmpty else { return .fallback }
            let filled = commands.map { entry -> SlashCommandEntryWire in
                guard entry.description == nil, let text = BuiltinSlashCommands.description(for: entry.name) else {
                    return entry
                }
                return SlashCommandEntryWire(name: entry.name, description: text,
                                             argumentHint: entry.argumentHint,
                                             aliases: entry.aliases, builtin: entry.builtin)
            }
            return SlashCommandCatalog(entries: filled, isFallback: false)
        default:
            return .fallback
        }
    }

    public static func make(from wire: SessionCommandsWire) -> SlashCommandCatalog {
        make(source: wire.source, commands: wire.commands)
    }
}
