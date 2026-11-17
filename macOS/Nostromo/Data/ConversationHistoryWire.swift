import Foundation

// The conversation-history frames (`conversation_history_v1`). Mirrors `ConversationEntryWire` and
// the `Conversation*` messages in `src/ipc/protocol.rs`. Mac-only: iOS gets none of it.

/// Where a conversation stands, as the daemon computed it at list time.
enum ConversationStatusWire: Equatable, Decodable {
    case running(tag: String, open: Bool)
    case unavailableDeleted
    case unavailableUnreadable
    /// `activeElsewhere`: the transcript was also written to in the last two minutes, so a resume needs
    /// that confirmation too.
    case folderGone(worktree: Bool, activeElsewhere: Bool = false)
    /// Written to in the last two minutes by something that is not a Nostromo session.
    case activeElsewhere
    case available
    /// A kind this app does not know: shown, never resumable.
    case unknown

    /// A gone worktree whose transcript may also be open in another Claude window.
    var isAlsoActiveElsewhere: Bool {
        if case .folderGone(_, let elsewhere) = self { return elsewhere }
        return false
    }

    private enum K: String, CodingKey { case kind, tag, open, worktree, activeElsewhere = "active_elsewhere" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "running":
            self = .running(tag: try c.decode(String.self, forKey: .tag),
                            open: try c.decodeIfPresent(Bool.self, forKey: .open) ?? false)
        case "unavailable_deleted": self = .unavailableDeleted
        case "unavailable_unreadable": self = .unavailableUnreadable
        case "folder_gone":
            self = .folderGone(worktree: try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false,
                               activeElsewhere: try c.decodeIfPresent(Bool.self, forKey: .activeElsewhere) ?? false)
        case "active_elsewhere": self = .activeElsewhere
        case "available": self = .available
        default: self = .unknown
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
    /// For a conversation whose worktree is gone: its main checkout, when it still exists.
    var mainCheckout: String?
    /// The conversation runs in a private no-codebase folder (its project reads "No codebase").
    var noCodebase: Bool
    /// `terminal`: started outside Nostromo (in a terminal), found by the opt-in index.
    var origin: String?

    var isTerminal: Bool { origin == "terminal" }

    var lastActive: Date { Date(timeIntervalSince1970: TimeInterval(lastActiveMs) / 1000) }

    enum CodingKeys: String, CodingKey {
        case id, title, label, agent, branch, model, effort, sensitive, status
        case projectName = "project_name", projectPath = "project_path", prNumbers = "pr_numbers"
        case firstPrompt = "first_prompt", firstPromptWithheld = "first_prompt_withheld"
        case lastActiveMs = "last_active_ms", resumedFromTag = "resumed_from_tag"
        case transcriptPath = "transcript_path", mainCheckout = "main_checkout"
        case noCodebase = "no_codebase", origin
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
        mainCheckout = try c.decodeIfPresent(String.self, forKey: .mainCheckout)
        noCodebase = try c.decodeIfPresent(Bool.self, forKey: .noCodebase) ?? false
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
    }

    /// Memberwise init for tests and the model.
    init(id: String, title: String, agent: String, lastActiveMs: Int64, status: ConversationStatusWire = .available,
         label: String? = nil, projectName: String? = nil, projectPath: String? = nil, branch: String? = nil,
         model: String? = nil, effort: String? = nil, prNumbers: [Int] = [], firstPrompt: String? = nil,
         firstPromptWithheld: String? = nil, sensitive: Bool = false, resumedFromTag: String? = nil,
         transcriptPath: String? = nil, mainCheckout: String? = nil, noCodebase: Bool = false,
         origin: String? = nil) {
        self.id = id; self.title = title; self.label = label; self.agent = agent
        self.projectName = projectName; self.projectPath = projectPath; self.branch = branch
        self.model = model; self.effort = effort; self.prNumbers = prNumbers
        self.firstPrompt = firstPrompt; self.firstPromptWithheld = firstPromptWithheld
        self.sensitive = sensitive; self.lastActiveMs = lastActiveMs; self.status = status
        self.resumedFromTag = resumedFromTag; self.transcriptPath = transcriptPath
        self.mainCheckout = mainCheckout; self.noCodebase = noCodebase; self.origin = origin
    }
}

struct ConversationHistoryWire: Equatable, Decodable {
    var requestId: String
    var entries: [ConversationEntryWire]
    var firstPromptsEnabled: Bool
    /// The "include conversations started outside Nostromo" switch (off from a daemon that does not say).
    var includeOutside: Bool = false
    /// With the switch on: the daemon has built its terminal-conversation index.
    var outsideReady: Bool = false
    var degradedKept: Int?
    var revision: UInt64
    /// The no-codebase folders any entry not yet purged names (visible or hidden). Every other folder under
    /// the spaces root is the clean-up's to trash.
    /// Nil from a daemon that does not say (it predates No codebase): then nothing is trashed.
    var referencedSpaceFolders: [String]?
    /// The spaces root the daemon means (canonical when it exists). The clean-up runs only when it is the
    /// root this app computed. Nil from a daemon that does not say: then nothing is trashed.
    var spacesRoot: String?

    enum CodingKeys: String, CodingKey {
        case entries, revision
        case referencedSpaceFolders = "referenced_space_folders", spacesRoot = "spaces_root"
        case requestId = "request_id", firstPromptsEnabled = "first_prompts_enabled", degradedKept = "degraded_kept"
        case includeOutside = "include_outside", outsideReady = "outside_ready"
    }

    init(requestId: String, entries: [ConversationEntryWire], firstPromptsEnabled: Bool,
         degradedKept: Int? = nil, revision: UInt64, referencedSpaceFolders: [String]? = nil,
         spacesRoot: String? = nil) {
        self.requestId = requestId; self.entries = entries; self.firstPromptsEnabled = firstPromptsEnabled
        self.degradedKept = degradedKept; self.revision = revision
        self.referencedSpaceFolders = referencedSpaceFolders; self.spacesRoot = spacesRoot
    }

    /// Entries decode one by one: a bad entry is skipped, never blanks the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        firstPromptsEnabled = try c.decode(Bool.self, forKey: .firstPromptsEnabled)
        includeOutside = try c.decodeIfPresent(Bool.self, forKey: .includeOutside) ?? false
        outsideReady = try c.decodeIfPresent(Bool.self, forKey: .outsideReady) ?? false
        degradedKept = try c.decodeIfPresent(Int.self, forKey: .degradedKept)
        revision = try c.decode(UInt64.self, forKey: .revision)
        referencedSpaceFolders = try c.decodeIfPresent([String].self, forKey: .referencedSpaceFolders)
        spacesRoot = try c.decodeIfPresent(String.self, forKey: .spacesRoot)
        var list = try c.nestedUnkeyedContainer(forKey: .entries)
        var out: [ConversationEntryWire] = []
        while !list.isAtEnd {
            if let e = try? list.decode(ConversationEntryWire.self) { out.append(e) }
            else { _ = try? list.decode(SkippedEntry.self) }   // advance past the bad one
        }
        entries = out
    }

    private struct SkippedEntry: Decodable {
        init(from decoder: Decoder) throws {}
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
    /// Resume in this folder instead of the original (the main checkout of a gone worktree).
    var place: String?
    /// Resume in this new, empty no-codebase folder (a child of the spaces root) instead.
    var noCodebaseFolder: String?
    /// The user chose "Resume anyway" for a conversation that may be open in another Claude window.
    var confirmActiveElsewhere = false
    /// The agent to continue a terminal conversation with (its recorded one is not an agent here).
    var agent: String?
    enum CodingKeys: String, CodingKey {
        case type, id, place, agent, requestId = "request_id", newTag = "new_tag",
             noCodebaseFolder = "no_codebase_folder",
             confirmActiveElsewhere = "confirm_active_elsewhere"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(id, forKey: .id)
        try c.encode(newTag, forKey: .newTag)
        try c.encodeIfPresent(place, forKey: .place)
        try c.encodeIfPresent(noCodebaseFolder, forKey: .noCodebaseFolder)
        if confirmActiveElsewhere { try c.encode(true, forKey: .confirmActiveElsewhere) }
        try c.encodeIfPresent(agent, forKey: .agent)
    }
}

/// `conversation_history_rename`: `title` nil clears the user's title.
struct ClientConversationHistoryRename: Encodable {
    let type = "conversation_history_rename"
    let requestId: String
    let id: String
    let title: String?
    enum CodingKeys: String, CodingKey { case type, id, title, requestId = "request_id" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

struct ClientConversationResumeRelease: Encodable {
    let type = "conversation_resume_release"
    let tag: String
    enum CodingKeys: String, CodingKey { case type, tag }
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
    var firstPromptsEnabled: Bool?
    var includeOutside: Bool?
    enum CodingKeys: String, CodingKey {
        case type, requestId = "request_id", firstPromptsEnabled = "first_prompts_enabled",
             includeOutside = "include_outside"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encodeIfPresent(firstPromptsEnabled, forKey: .firstPromptsEnabled)
        try c.encodeIfPresent(includeOutside, forKey: .includeOutside)
    }
}
