import Foundation

/// Descriptions for the CLI's own commands, used ONLY for a name the CLI did not describe (before
/// a session's first message, or against a daemon that does not forward the list).
///
/// The wording is Claude Code 2.1.318's own `commands_changed` text, verbatim. Exactly these names
/// and no others: a command with no description gets none, never a made-up one.
public enum BuiltinSlashCommands {

    /// The CLI version the wording below came from.
    public static let cliVersion = "2.1.318"

    public static let fallback: [SlashCommandEntryWire] = [
        SlashCommandEntryWire(name: "clear",
            description: "Start a new session with empty context; previous session stays on disk (resumable with /resume)",
            aliases: ["reset", "new"], builtin: true),
        SlashCommandEntryWire(name: "compact",
            description: "Free up context by summarizing the conversation so far", builtin: true),
        SlashCommandEntryWire(name: "context",
            description: "Show current context usage", builtin: true),
        SlashCommandEntryWire(name: "effort",
            description: "Set effort level for model usage", builtin: true),
        SlashCommandEntryWire(name: "init",
            description: "Initialize a new CLAUDE.md file with codebase documentation", builtin: true),
        SlashCommandEntryWire(name: "mcp",
            description: "Manage MCP servers", builtin: true),
        SlashCommandEntryWire(name: "model",
            description: "Set the AI model for Claude Code", builtin: true),
        SlashCommandEntryWire(name: "rename",
            description: "Rename the current conversation", builtin: true),
        SlashCommandEntryWire(name: "reload-skills",
            description: "Pick up skills added or changed on disk during this session", builtin: true),
        SlashCommandEntryWire(name: "security-review",
            description: "Complete a security review of the pending changes on the current branch", builtin: true),
        SlashCommandEntryWire(name: "usage",
            description: "Show session cost, plan usage, and what's contributing to your limits",
            aliases: ["cost", "stats"], builtin: true),
    ]

    /// The description for `name`, by exact name.
    public static func description(for name: String) -> String? {
        fallback.first { $0.name == name }?.description
    }
}
