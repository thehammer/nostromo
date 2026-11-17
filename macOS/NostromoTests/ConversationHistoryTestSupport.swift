import Foundation

/// Records what the history store sends; `advertises` stands in for the welcome feature.
final class RecordingHistorySender: ConversationHistorySending {
    var daemonAdvertisesConversationHistory = true
    private(set) var gets = 0
    private(set) var resumes: [(requestId: String, id: String, newTag: String)] = []
    private(set) var resumePlaces: [String?] = []
    private(set) var resumeConfirms: [Bool] = []
    private(set) var resumeNoCodebaseFolders: [String?] = []
    private(set) var renames: [(id: String, title: String?)] = []
    private(set) var releases: [String] = []
    private(set) var removes: [String] = []
    private(set) var restores: [String] = []
    private(set) var purges = 0
    private(set) var settings: [Bool] = []
    private(set) var includeOutsideSettings: [Bool] = []
    private(set) var resumeAgents: [String?] = []

    func conversationHistoryGet(requestId: String) { gets += 1 }
    func conversationResume(requestId: String, id: String, newTag: String, place: String?,
                            noCodebaseFolder: String?, confirmActiveElsewhere: Bool, agent: String?) {
        resumeAgents.append(agent)
        resumes.append((requestId, id, newTag)); resumePlaces.append(place); resumeConfirms.append(confirmActiveElsewhere)
        resumeNoCodebaseFolders.append(noCodebaseFolder)
    }
    func conversationHistoryRename(requestId: String, id: String, title: String?) { renames.append((id, title)) }
    func conversationResumeRelease(tag: String) { releases.append(tag) }
    func conversationHistoryRemove(requestId: String, id: String) { removes.append(id) }
    func conversationHistoryRestore(requestId: String, id: String) { restores.append(id) }
    func conversationHistoryPurgeRemoved(requestId: String) { purges += 1 }
    func conversationHistorySettingsSet(requestId: String, firstPromptsEnabled: Bool) { settings.append(firstPromptsEnabled) }
    func conversationHistoryIncludeOutsideSet(requestId: String, includeOutside: Bool) { includeOutsideSettings.append(includeOutside) }
}

enum HistoryFixtures {
    static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Saturday 2026-11-14 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_668_400)

    static func ms(daysAgo: Double, from base: Date = now) -> Int64 {
        Int64((base.timeIntervalSince1970 - daysAgo * 86_400) * 1000)
    }

    static func entry(_ id: String, title: String = "Title", agent: String = "cody", daysAgo: Double = 0,
                      project: String? = "nostromo", branch: String? = nil, prs: [Int] = [],
                      prompt: String? = nil, status: ConversationStatusWire = .available,
                      sensitive: Bool = false, mainCheckout: String? = nil,
                      noCodebase: Bool = false, origin: String? = nil) -> ConversationEntryWire {
        ConversationEntryWire(id: id, title: title, agent: agent, lastActiveMs: ms(daysAgo: daysAgo), status: status,
                              projectName: project, projectPath: project.map { "/tmp/\($0)" }, branch: branch,
                              prNumbers: prs, firstPrompt: prompt, sensitive: sensitive,
                              transcriptPath: "/tmp/\(id).jsonl", mainCheckout: mainCheckout, noCodebase: noCodebase,
                              origin: origin)
    }

    /// `referenced` is the daemon's `referenced_space_folders` (nil: a daemon that does not say).
    static func history(_ entries: [ConversationEntryWire], prompts: Bool = true, degraded: Int? = nil,
                        referenced: [String]? = nil, spacesRoot: String? = nil,
                        includeOutside: Bool = false, outsideReady: Bool = false) -> ConversationHistoryWire {
        let json: [String: Any] = ["request_id": "r", "entries": [], "first_prompts_enabled": prompts, "revision": 1]
        var wire = try! JSONDecoder().decode(ConversationHistoryWire.self, from: JSONSerialization.data(withJSONObject: json))
        wire.entries = entries
        wire.degradedKept = degraded
        wire.referencedSpaceFolders = referenced
        wire.spacesRoot = spacesRoot
        wire.includeOutside = includeOutside
        wire.outsideReady = outsideReady
        return wire
    }
}
