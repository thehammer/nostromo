import Foundation

// MARK: - Focus

struct Focus: Codable, Hashable, Identifiable {
    var id: String           // "fred"/"mother"/"perri"/"teri" for built-ins; UUID string for dynamic
    var agentTag: String     // claude agent name e.g. "claudia", "cody"
    var projectPath: String? // nil for built-ins; absolute path e.g. "/Users/hammer/Code/admin-portal"
    var isBuiltIn: Bool

    var displayName: String {
        guard let path = projectPath else {
            return agentTag.capitalized
        }
        let project = URL(fileURLWithPath: path).lastPathComponent
            .split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        return "\(agentTag.capitalized) in \(project)"
    }

    var sessionTag: String {
        isBuiltIn ? agentTag : "\(agentTag)-\(id.prefix(8))"
    }

    static let builtIns: [Focus] = [
        Focus(id: "fred",   agentTag: "fred",   projectPath: nil, isBuiltIn: true),
        Focus(id: "mother", agentTag: "mother", projectPath: nil, isBuiltIn: true),
        Focus(id: "perri",  agentTag: "perri",  projectPath: nil, isBuiltIn: true),
        Focus(id: "teri",   agentTag: "teri",   projectPath: nil, isBuiltIn: true),
    ]
}

// MARK: - Mother

struct MotherStatus {
    var running:  Int = 0
    var queued:   Int = 0
    var failed:   Int = 0
    var awaiting: Int = 0

    var isEmpty: Bool { running == 0 && queued == 0 && failed == 0 && awaiting == 0 }

    /// Parse the colon-delimited statusline cache: `"running:queued:failed:awaiting"`.
    static func parse(_ s: String) -> MotherStatus {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        func get(_ i: Int) -> Int { Int(parts.indices.contains(i) ? String(parts[i]) : "0") ?? 0 }
        return MotherStatus(running: get(0), queued: get(1), failed: get(2), awaiting: get(3))
    }
}

struct MotherJob: Decodable, Identifiable {
    let id:              String
    let state:           String
    let repo:            String
    let isolation:       String
    let title:           String
    let createdAt:       Date?
    let startedAt:       Date?
    let finishedAt:      Date?
    let planPath:        String?
    let question:        String?
    let pausedReason:    String?
    let adherenceStatus: String?
    let currentTier:     String?

    enum CodingKeys: String, CodingKey {
        case id, state, repo, isolation, title
        case createdAt       = "created_at"
        case startedAt       = "started_at"
        case finishedAt      = "finished_at"
        case planPath        = "plan_path"
        case question
        case pausedReason    = "paused_reason"
        case adherenceStatus = "adherence_status"
        case currentTier     = "current_tier"
    }
}

// MARK: - Perri PR queue

/// One item from `perri-queue-pane --json` output.
struct PRQueueItem: Identifiable {
    var id: String { "\(repo)#\(number)" }
    let repo:        String
    let number:      Int
    let title:       String
    let author:      String
    /// "requested" | "needs_review" | "changes_req"
    let bucket:      String
    let newActivity: Bool
    let url:         String
}

// MARK: - Activity

struct ActivityEvent: Decodable {
    let ts:      Date
    let agent:   String
    let kind:    String
    let summary: String
}

// MARK: - Rate limits

struct RateLimits {
    let pct5h:   Int
    let reset5h: TimeInterval
    let pct7d:   Int
    let reset7d: TimeInterval

    static func parse(_ s: String) -> RateLimits? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .compactMap { Int($0) }
        guard parts.count >= 4 else { return nil }
        return RateLimits(pct5h: parts[0], reset5h: TimeInterval(parts[1]),
                          pct7d: parts[2], reset7d: TimeInterval(parts[3]))
    }
}

// MARK: - Budget posture

enum BudgetPosture: String {
    // Legacy vocabulary
    case flush, normal, elevated, conservative, critical
    // Current Bishop vocabulary
    case pumpTheBrakes     = "pump the brakes"
    case easeUp            = "ease up"
    case cruise
    case push
    case putTheHammerDown  = "put the hammer down"

    static func from(string s: String) -> BudgetPosture? {
        BudgetPosture(rawValue: s.lowercased())
    }

    /// Display chip label — empty string means hidden (Normal/Cruise).
    var chipLabel: String {
        switch self {
        case .flush, .putTheHammerDown: return "FLUSH"
        case .normal, .cruise:          return ""
        case .elevated, .push:          return "ELEVATED"
        case .conservative, .easeUp:    return "CONSERVATIVE"
        case .critical, .pumpTheBrakes: return "CRITICAL"
        }
    }

    var isHidden: Bool { chipLabel.isEmpty }
}

// MARK: - Window pace (from budget-posture.json)

struct WindowPace {
    let usedPct:   Float
    let elapsedPct: Float
    let pace:      Float
    let resetsAt:  TimeInterval
    let level:     String
}

struct PostureSnapshot {
    let posture:       BudgetPosture
    let fiveHour:      WindowPace?
    let sevenDay:      WindowPace?
    let sonnetSevenDay: WindowPace?

    static func load() -> PostureSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url  = home.appendingPathComponent(".claude/budget-posture.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let ps = json["posture"] as? String,
              let posture = BudgetPosture.from(string: ps)
        else { return nil }

        return PostureSnapshot(
            posture:        posture,
            fiveHour:       parseWindowPace(json["five_hour"]),
            sevenDay:       parseWindowPace(json["seven_day"]),
            sonnetSevenDay: parseSonnetWindow(json["models"], elapsedPct: parseWindowPace(json["seven_day"])?.elapsedPct)
        )
    }

    private static func parseWindowPace(_ v: Any?) -> WindowPace? {
        guard let d = v as? [String: Any] else { return nil }
        guard let used    = (d["used_pct"]    as? NSNumber).map({ Float($0.doubleValue) }),
              let elapsed = (d["elapsed_pct"] as? NSNumber).map({ Float($0.doubleValue) }),
              let pace    = (d["pace"]        as? NSNumber).map({ Float($0.doubleValue) }),
              let resets  = (d["resets_at"]   as? NSNumber).map({ TimeInterval($0.doubleValue) })
        else { return nil }
        return WindowPace(usedPct: used, elapsedPct: elapsed, pace: pace,
                          resetsAt: resets, level: d["level"] as? String ?? "normal")
    }

    private static func parseSonnetWindow(_ models: Any?, elapsedPct: Float?) -> WindowPace? {
        guard let m = models as? [String: Any],
              let s = m["sonnet"] as? [String: Any],
              let used   = (s["used_pct"]  as? NSNumber).map({ Float($0.doubleValue) }),
              let resets = (s["resets_at"] as? NSNumber).map({ TimeInterval($0.doubleValue) }),
              let elapsed = elapsedPct
        else { return nil }
        let pace: Float = elapsed > 0 ? used / elapsed : 0
        return WindowPace(usedPct: used, elapsedPct: elapsed, pace: pace,
                          resetsAt: resets, level: s["status"] as? String ?? "normal")
    }
}
