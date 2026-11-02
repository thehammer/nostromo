import Foundation

/// One background event of a task wake: `TurnOrigin::TaskWake` in the daemon
/// (`{"type":"task_wake","items":[…],"omitted":N}`).
///
/// Display data only, and untrusted: `description` is whatever a command, monitor or agent was called.
/// Nothing here is drawn as markup; `WakeMarkerText` sanitises and caps it.
public struct TaskWakeItemWire: Codable, Equatable {
    public let taskId:    String?
    public let toolUseId: String?
    /// `shell`, `monitor`, `agent`, `other`; any other string is kept as text.
    public let kind:      String
    /// `new_output`, `completed`, `failed`, `stopped`, `ended`, `event`; any other string is kept as text.
    public let outcome:   String
    public let description: String

    public init(taskId: String? = nil, toolUseId: String? = nil, kind: String, outcome: String,
                description: String) {
        self.taskId = taskId
        self.toolUseId = toolUseId
        self.kind = kind
        self.outcome = outcome
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case taskId    = "task_id"
        case toolUseId = "tool_use_id"
        case kind, outcome, description
    }

    /// Tolerant: a missing `kind` is `"other"`, a missing `outcome` `"event"`, a missing
    /// `description` `""`. Anything that is not an object throws, so the origin skips it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let taskId = (try? c.decodeIfPresent(String.self, forKey: .taskId)) ?? nil
        let toolUseId = (try? c.decodeIfPresent(String.self, forKey: .toolUseId)) ?? nil
        self.init(taskId: (taskId?.isEmpty ?? true) ? nil : taskId,
                  toolUseId: toolUseId,
                  kind: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "other",
                  outcome: (try? c.decodeIfPresent(String.self, forKey: .outcome)) ?? "event",
                  description: (try? c.decodeIfPresent(String.self, forKey: .description)) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(taskId, forKey: .taskId)
        try c.encodeIfPresent(toolUseId, forKey: .toolUseId)
        try c.encode(kind, forKey: .kind)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(description, forKey: .description)
    }
}
