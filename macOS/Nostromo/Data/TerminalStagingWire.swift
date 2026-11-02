import Foundation

/// `terminal_staging_list`: the commands an agent that follows a terminal has staged for the user
/// (S1a's daemon store). Targeted to this app only because it declares `terminal_staging_ui`.
/// The client frames (`terminal_staging_inserted`, `_remove`, `_clear`) are `TerminalClientMessage` cases.
/// Nothing here is written to disk or logged: it is text an agent chose.

enum TerminalStagingState: String, Equatable {
    /// The follower owns the list and may change it.
    case active
    /// The user stopped the follow; the list stays, nobody can change it.
    case frozen
    /// No list (a frame that clears it). An unknown state decodes as this: no drawer, fail closed.
    case none
}

struct StagingEntry: Equatable {
    let id: String
    let number: Int
    /// Exactly what was staged. Never edited for display.
    let command: String
    let note: String?
    let stagedAt: Date
    let changedAt: Date
    let insertedCount: Int
    let lastInsertedAt: Date?
}

struct TerminalStagingList: Equatable {
    let terminalId: String
    let paneId: String
    let state: TerminalStagingState
    let ownerTag: String
    let agentName: String
    let revision: Int
    let entries: [StagingEntry]
    /// Whether staging is on for this terminal (the daemon sends it with every frame, even a `none` one).
    var enabled: Bool = true
    /// Set while a Local terminal's foreground is a program other than its shell (`ssh`, `kubectl`): the
    /// pane is treated like a remote one. Only for the app's own rules: never sent to the agent.
    var foreground: String? = nil
}

extension TerminalStagingList: Decodable {
    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", paneId = "pane_id", state, ownerTag = "owner_tag"
        case agentName = "agent_name", revision, entries, enabled, foreground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try c.decode(String.self, forKey: .terminalId)
        paneId = try c.decodeIfPresent(String.self, forKey: .paneId) ?? ""
        let rawState = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        state = TerminalStagingState(rawValue: rawState) ?? .none
        ownerTag = try c.decodeIfPresent(String.self, forKey: .ownerTag) ?? ""
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName) ?? ""
        revision = try c.decode(Int.self, forKey: .revision)
        entries = try c.decodeIfPresent([StagingEntry].self, forKey: .entries) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        foreground = try c.decodeIfPresent(String.self, forKey: .foreground)
    }
}

extension StagingEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, number, command, note, stagedAt = "staged_at", changedAt = "changed_at"
        case insertedCount = "inserted_count", lastInsertedAt = "last_inserted_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        command = try c.decode(String.self, forKey: .command)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        stagedAt = try StagingTimestamp.decode(c, .stagedAt)
        changedAt = try StagingTimestamp.decode(c, .changedAt)
        insertedCount = try c.decodeIfPresent(Int.self, forKey: .insertedCount) ?? 0
        lastInsertedAt = try c.decodeIfPresent(String.self, forKey: .lastInsertedAt).flatMap(StagingTimestamp.parse)
    }
}

/// RFC 3339 UTC, with or without milliseconds. Two shared formatters, never one per entry.
enum StagingTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    fileprivate static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
        let text = try c.decode(String.self, forKey: key)
        guard let date = parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not an RFC 3339 time")
        }
        return date
    }
}
