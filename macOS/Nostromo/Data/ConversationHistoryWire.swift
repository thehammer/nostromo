import Foundation

// The conversation-history frames (`conversation_history_v1`). Mirrors `ConversationEntryWire` and
// the `Conversation*` messages in `src/ipc/protocol.rs`. Mac-only: iOS gets none of it.

/// Where a conversation stands, as the daemon computed it at list time.
enum ConversationStatusWire: Equatable, Decodable {
    case running(tag: String, open: Bool)
    case unavailableDeleted
    case unavailableUnreadable
    case folderGone(worktree: Bool)
    case available

    private enum K: String, CodingKey { case kind, tag, open, worktree }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "running":
            self = .running(tag: try c.decode(String.self, forKey: .tag),
                            open: try c.decodeIfPresent(Bool.self, forKey: .open) ?? false)
        case "unavailable_deleted": self = .unavailableDeleted
        case "unavailable_unreadable": self = .unavailableUnreadable
        case "folder_gone": self = .folderGone(worktree: try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false)
        default: self = .available
        }
    }
}

struct ConversationEntryWire: Equatable, Decodable, Identifiable {
    var id: String
    var title: String
    var label: String?
    var agent: String
    var projectName: String?
    var projectPath: String?
    var branch: String?
    var model: String?
    var effort: String?
    var prNumbers: [Int]
    var firstPrompt: String?
    /// The fixed reason word when no prompt is shown (`image`, `command:/name`, ...).
    var firstPromptWithheld: String?
    var sensitive: Bool
    var lastActiveMs: Int64
    var status: ConversationStatusWire
    var resumedFromTag: String?
    var transcriptPath: String?

    var lastActive: Date { Date(timeIntervalSince1970: TimeInterval(lastActiveMs) / 1000) }

    enum CodingKeys: String, CodingKey {
        case id, title, label, agent, branch, model, effort, sensitive, status
        case projectName = "project_name", projectPath = "project_path", prNumbers = "pr_numbers"
        case firstPrompt = "first_prompt", firstPromptWithheld = "first_prompt_withheld"
        case lastActiveMs = "last_active_ms", resumedFromTag = "resumed_from_tag"
        case transcriptPath = "transcript_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        agent = try c.decode(String.self, forKey: .agent)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        prNumbers = try c.decodeIfPresent([Int].self, forKey: .prNumbers) ?? []
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        firstPromptWithheld = try c.decodeIfPresent(String.self, forKey: .firstPromptWithheld)
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        lastActiveMs = try c.decode(Int64.self, forKey: .lastActiveMs)
        status = try c.decode(ConversationStatusWire.self, forKey: .status)
        resumedFromTag = try c.decodeIfPresent(String.self, forKey: .resumedFromTag)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
    }

    /// Memberwise init for tests and the model.
    init(id: String, title: String, agent: String, lastActiveMs: Int64, status: ConversationStatusWire = .available,
         label: String? = nil, projectName: String? = nil, projectPath: String? = nil, branch: String? = nil,
         model: String? = nil, effort: String? = nil, prNumbers: [Int] = [], firstPrompt: String? = nil,
         firstPromptWithheld: String? = nil, sensitive: Bool = false, resumedFromTag: String? = nil,
         transcriptPath: String? = nil) {
        self.id = id; self.title = title; self.label = label; self.agent = agent
        self.projectName = projectName; self.projectPath = projectPath; self.branch = branch
        self.model = model; self.effort = effort; self.prNumbers = prNumbers
        self.firstPrompt = firstPrompt; self.firstPromptWithheld = firstPromptWithheld
        self.sensitive = sensitive; self.lastActiveMs = lastActiveMs; self.status = status
        self.resumedFromTag = resumedFromTag; self.transcriptPath = transcriptPath
    }
}

struct ConversationHistoryWire: Equatable, Decodable {
    var requestId: String
    var entries: [ConversationEntryWire]
    var firstPromptsEnabled: Bool
    var degradedKept: Int?
    var revision: UInt64

    enum CodingKeys: String, CodingKey {
        case entries, revision
        case requestId = "request_id", firstPromptsEnabled = "first_prompts_enabled", degradedKept = "degraded_kept"
    }
}

struct ConversationResumeResultWire: Equatable, Decodable {
    enum Outcome: String, Decodable { case `switch`, ready, refused }
    var requestId: String
    var outcome: Outcome
    var tag: String?
    var reason: String?
    var agent: String?
    var projectPath: String?
    var label: String?
    var title: String?

    enum CodingKeys: String, CodingKey {
        case outcome, tag, reason, agent, label, title
        case requestId = "request_id", projectPath = "project_path"
    }
}

// MARK: - Client frames

struct ClientConversationHistoryGet: Encodable {
    let type = "conversation_history_get"
    let requestId: String
    enum CodingKeys: String, CodingKey { case type, requestId = "request_id" }
}

struct ClientConversationResume: Encodable {
    let type = "conversation_resume"
    let requestId: String
    let id: String
    let newTag: String
    enum CodingKeys: String, CodingKey { case type, id, requestId = "request_id", newTag = "new_tag" }
}

/// `conversation_history_remove` / `_restore`, told apart by `type`.
struct ClientConversationHistoryEdit: Encodable {
    let type: String
    let requestId: String
    let id: String
    enum CodingKeys: String, CodingKey { case type, id, requestId = "request_id" }
}

struct ClientConversationHistoryPurgeRemoved: Encodable {
    let type = "conversation_history_purge_removed"
    let requestId: String
    enum CodingKeys: String, CodingKey { case type, requestId = "request_id" }
}

struct ClientConversationHistorySettingsSet: Encodable {
    let type = "conversation_history_settings_set"
    let requestId: String
    let firstPromptsEnabled: Bool
    enum CodingKeys: String, CodingKey { case type, requestId = "request_id", firstPromptsEnabled = "first_prompts_enabled" }
}
