import Foundation

// MARK: - QuickAction

/// A pre-set action that can be triggered from a pill button in a REPL-backed focus.
struct QuickAction: Codable, Hashable {
    let id: String        // stable identifier e.g. "perri-start-reviewing"
    let label: String     // button text e.g. "Start Reviewing"
    let prompt: String    // message to send; empty string means "clear only"
    let clearFirst: Bool  // if true, call session.newSession() before sending

    /// Generic "wipe the conversation" action shown on every REPL-backed focus.
    static let clearContext = QuickAction(
        id: "clear-context", label: "Clear Context", prompt: "", clearFirst: true
    )
}

// MARK: - Focus

struct Focus: Codable, Hashable, Identifiable {
    var id: String           // "fred"/"mother"/"perri"/"teri" for built-ins; UUID string for dynamic
    var agentTag: String     // claude agent name e.g. "claudia", "cody"
    var projectPath: String? // nil for built-ins; absolute path e.g. "/Users/hammer/Code/admin-portal"
    var isBuiltIn: Bool
    var quickActions: [QuickAction] = []
    /// Org section for sidebar grouping: "Carefeed", "Personal", or nil (legacy; resolved via effectiveOrg).
    var org: String? = nil
    /// Phase 2: auto-generated session summary for disambiguation. Nil until Phase 2 ships.
    var sessionSummary: String? = nil

    /// Repo display name derived from the last path component of `projectPath`,
    /// converting kebab-case to Title Case (e.g. "admin-portal" → "Admin Portal").
    var repoName: String? {
        guard let path = projectPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
            .split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    var displayName: String {
        guard let repo = repoName else { return agentTag.capitalized }
        return "\(agentTag.capitalized) in \(repo)"
    }

    var sessionTag: String {
        isBuiltIn ? agentTag : "\(agentTag)-\(id.prefix(8))"
    }

    /// Resolved org bucket for sidebar grouping. Legacy focuses (saved before the `org`
    /// field existed) have `org == nil`: project sessions fall under "Carefeed", pathless
    /// ones under "Personal".
    var effectiveOrg: String {
        if let org, !org.isEmpty { return org }
        return projectPath == nil ? "Personal" : "Carefeed"
    }

    static let builtIns: [Focus] = [
        Focus(id: "fred",   agentTag: "fred",   projectPath: nil, isBuiltIn: true, org: "Carefeed"),
        Focus(id: "mother", agentTag: "mother", projectPath: nil, isBuiltIn: true, org: "Carefeed"),
        Focus(id: "perri",  agentTag: "perri",  projectPath: nil, isBuiltIn: true, org: "Carefeed",
              quickActions: [QuickAction(
                  id: "perri-start-reviewing",
                  label: "Start Reviewing",
                  prompt: "",        // empty — just clear; Perri auto-starts review on fresh session
                  clearFirst: true
              )]),
        Focus(id: "teri",   agentTag: "teri",   projectPath: nil, isBuiltIn: true, org: "Carefeed"),
    ]
}

// MARK: - Mother — job phase types (Wedge C)

/// State of one agent phase within a Mother job.
/// Unknown strings (from future broker versions) silently decode as `.pending`.
enum JobPhaseState: String, Equatable {
    case pending, running, completed
}

/// One agent step within a Mother job or pipeline cycle.
///
/// All fields are decoded defensively: missing keys / unknown values never throw.
struct JobPhase: Decodable {
    let agent:       String
    let requestType: String?
    let state:       JobPhaseState
    let startedAt:   Date?
    let finishedAt:  Date?
    /// Findings count (review phases only; nil for non-review or zero-findings phases).
    let findings:    Int?

    enum CodingKeys: String, CodingKey {
        case agent
        case requestType = "request_type"
        case state
        case startedAt   = "started_at"
        case finishedAt  = "finished_at"
        case findings
    }

    init(agent: String, requestType: String? = nil, state: JobPhaseState,
         startedAt: Date? = nil, finishedAt: Date? = nil, findings: Int? = nil) {
        self.agent       = agent
        self.requestType = requestType
        self.state       = state
        self.startedAt   = startedAt
        self.finishedAt  = finishedAt
        self.findings    = findings
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        agent       = (try? c.decode(String.self, forKey: .agent))       ?? ""
        requestType = (try? c.decodeIfPresent(String.self, forKey: .requestType)) ?? nil
        let raw  = (try? c.decode(String.self, forKey: .state))          ?? ""
        state       = JobPhaseState(rawValue: raw)                        ?? .pending
        startedAt   = (try? c.decodeIfPresent(Date.self, forKey: .startedAt))  ?? nil
        finishedAt  = (try? c.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? nil
        let rawFindings = (try? c.decodeIfPresent(Int.self, forKey: .findings)) ?? nil
        findings    = (rawFindings ?? 0) > 0 ? rawFindings : nil
    }
}

/// One cycle within a pipeline Mother job.
struct JobCycle: Decodable {
    let cycle:  Int
    let phases: [JobPhase]

    init(cycle: Int, phases: [JobPhase]) {
        self.cycle  = cycle
        self.phases = phases
    }

    init(from decoder: Decoder) throws {
        let c  = try decoder.container(keyedBy: CodingKeys.self)
        cycle  = (try? c.decode(Int.self,         forKey: .cycle))  ?? 0
        phases = (try? c.decode([JobPhase].self,  forKey: .phases)) ?? []
    }

    enum CodingKeys: String, CodingKey { case cycle, phases }
}

// MARK: - Phase ribbon view model

/// One label+state token in the phase ribbon.
struct PhaseRibbonToken: Equatable {
    /// Display text, e.g. "redd✓", "cody⟳", "perri·", "ada✓(2)".
    let text:  String
    let state: JobPhaseState
}

/// Computed ribbon for a job's phase list, ready for the view to render.
struct PhaseRibbonModel {
    let tokens:     [PhaseRibbonToken]
    /// "cycle N" for pipeline jobs; nil for flat-phase standard jobs.
    let cycleLabel: String?
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

    /// Derive status counts directly from a live job list (broker-sourced).
    static func from(jobs: [MotherJob]) -> MotherStatus {
        var s = MotherStatus()
        for job in jobs {
            switch job.state {
            case "running":  s.running  += 1
            case "queued":   s.queued   += 1
            case "awaiting": s.awaiting += 1
            case "failed":   s.failed   += 1
            default: break
            }
        }
        return s
    }
}

struct MotherJob: Identifiable {
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
    // Wedge C — phase-progress ribbon (broker-fed; absent/empty on pre-Wedge-C jobs)
    var kind:   String?    = nil   // "pipeline" for multi-cycle jobs; nil for standard
    var phases: [JobPhase] = []    // flat phase list (standard jobs)
    var cycles: [JobCycle] = []    // per-cycle phases (pipeline jobs)

    /// Computed ribbon model; nil when the job carries no phase data.
    var phaseRibbonModel: PhaseRibbonModel? {
        if !cycles.isEmpty {
            guard let current = cycles.last else { return nil }
            let tokens = current.phases.map { ribbonToken($0) }
            return PhaseRibbonModel(tokens: tokens, cycleLabel: "cycle \(current.cycle)")
        } else if !phases.isEmpty {
            return PhaseRibbonModel(tokens: phases.map { ribbonToken($0) }, cycleLabel: nil)
        }
        return nil
    }

    private func ribbonToken(_ phase: JobPhase) -> PhaseRibbonToken {
        let mark: String
        switch phase.state {
        case .completed: mark = "✓"
        case .running:   mark = "⟳"
        case .pending:   mark = "·"
        }
        let text: String
        if let f = phase.findings, f > 0 {
            text = "\(phase.agent)\(mark)(\(f))"
        } else {
            text = "\(phase.agent)\(mark)"
        }
        return PhaseRibbonToken(text: text, state: phase.state)
    }
}

/// Slim decoder for `mother list --format json` output. The CLI shape has
/// ISO8601 timestamps with fractional seconds; we parse them manually.
struct MotherJobSlim: Decodable {
    let id:              String
    let state:           String
    let repo:            String
    let isolation:       String
    let title:           String
    let createdAt:       String?
    let startedAt:       String?
    let finishedAt:      String?
    let planPath:        String?
    let question:        String?
    let pausedReason:    String?
    let adherenceStatus: String?
    let currentTier:     String?
    // Wedge C — decoded defensively: nil when absent (pre-Wedge-C jobs)
    let kind:            String?
    let phases:          [JobPhase]?   // nil → empty array in toMotherJob()
    let cycles:          [JobCycle]?   // nil → empty array in toMotherJob()

    enum CodingKeys: String, CodingKey {
        case id, state, repo, isolation, title, question, kind, phases, cycles
        case createdAt       = "created_at"
        case startedAt       = "started_at"
        case finishedAt      = "finished_at"
        case planPath        = "plan_path"
        case pausedReason    = "paused_reason"
        case adherenceStatus = "adherence_status"
        case currentTier     = "current_tier"
    }

    private static let fmtFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fmtBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fmtFrac.date(from: s) ?? fmtBasic.date(from: s)
    }

    func toMotherJob() -> MotherJob {
        MotherJob(id: id, state: state, repo: repo, isolation: isolation,
                  title: title,
                  createdAt:       Self.parseDate(createdAt),
                  startedAt:       Self.parseDate(startedAt),
                  finishedAt:      Self.parseDate(finishedAt),
                  planPath:        planPath,
                  question:        question,
                  pausedReason:    pausedReason,
                  adherenceStatus: adherenceStatus,
                  currentTier:     currentTier,
                  kind:            kind,
                  phases:          phases ?? [],
                  cycles:          cycles ?? [])
    }
}

// MARK: - Perri PR queue

/// Rolled-up CI state for a PR row or individual check.
/// Raw values match the Rust `CiState` serde encoding (`lowercase`).
enum CiState: String, Decodable {
    case unknown, pending, success, failure

    /// Tolerant decode: any unknown or missing string maps to `.unknown`.
    static func from(ciStateString s: String?) -> CiState {
        guard let s else { return .unknown }
        return CiState(rawValue: s.lowercased()) ?? .unknown
    }
}

/// One item from the perri queue cache.
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
    /// Rolled-up CI state — defaults to `.unknown` when absent from the cache.
    let ciState:     CiState
    /// HEAD commit SHA — used by the GUI to validate its detail cache.
    let headSha:     String
}

/// A single CI check-run result decoded from the PR detail JSON.
struct CiCheck: Decodable, Identifiable {
    var id: String { name }
    let name:   String
    let state:  CiState
    /// Truncated failure log; nil unless the check is failing.
    let detail: String?

    enum CodingKeys: String, CodingKey { case name, state, detail }

    init(from d: Decoder) throws {
        let c  = try d.container(keyedBy: CodingKeys.self)
        name   = (try? c.decode(String.self, forKey: .name)) ?? ""
        let s  = try? c.decode(String.self, forKey: .state)
        state  = CiState.from(ciStateString: s)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Full PR detail decoded from `current-pr-detail.json` or a per-PR cache file.
/// Field names are mapped from Rust's snake_case via `CodingKeys`.
struct PRDetail: Decodable {
    let prNumber:     Int?
    let repo:         String
    let title:        String
    let author:       String
    let url:          String
    let diff:         String
    let diffTooLarge: Bool
    let ciChecks:     [CiCheck]
    let additions:    Int
    let deletions:    Int
    let changedFiles: Int
    let headSha:      String
    let error:        String?

    enum CodingKeys: String, CodingKey {
        case prNumber    = "pr_number"
        case repo, title, author, url, diff
        case diffTooLarge = "diff_too_large"
        case ciChecks     = "ci_checks"
        case additions, deletions
        case changedFiles = "changed_files"
        case headSha      = "head_sha"
        case error
    }

    init(from d: Decoder) throws {
        let c        = try d.container(keyedBy: CodingKeys.self)
        prNumber     = try? c.decodeIfPresent(Int.self,      forKey: .prNumber)
        repo         = (try? c.decode(String.self,           forKey: .repo))         ?? ""
        title        = (try? c.decode(String.self,           forKey: .title))        ?? ""
        author       = (try? c.decode(String.self,           forKey: .author))       ?? ""
        url          = (try? c.decode(String.self,           forKey: .url))          ?? ""
        diff         = (try? c.decode(String.self,           forKey: .diff))         ?? ""
        diffTooLarge = (try? c.decode(Bool.self,             forKey: .diffTooLarge)) ?? false
        ciChecks     = (try? c.decode([CiCheck].self,        forKey: .ciChecks))     ?? []
        additions    = (try? c.decode(Int.self,              forKey: .additions))    ?? 0
        deletions    = (try? c.decode(Int.self,              forKey: .deletions))    ?? 0
        changedFiles = (try? c.decode(Int.self,              forKey: .changedFiles)) ?? 0
        headSha      = (try? c.decode(String.self,           forKey: .headSha))      ?? ""
        error        = try? c.decodeIfPresent(String.self,   forKey: .error)
    }
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
        case .putTheHammerDown:         return "Put the hammer down"
        case .flush:                    return "Flush"
        case .normal, .cruise:          return ""
        case .elevated, .push:          return "Push"
        case .conservative, .easeUp:    return "Ease up"
        case .pumpTheBrakes:            return "Pump the brakes"
        case .critical:                 return "Critical"
        }
    }

    var isHidden: Bool { chipLabel.isEmpty }
}

// MARK: - Agent spend (from budget-posture.json agents map)

/// Raw token counts for one Mother-attributable agent, from the `agents` map in
/// `budget-posture.json`.  All four fields are in raw tokens — NOT percentages.
struct AgentSpend {
    let tokensIn5h:  Int
    let tokensOut5h: Int
    let tokensIn7d:  Int
    let tokensOut7d: Int

    /// Combined input+output for the given window key ("5h" or "7d").
    func total(for window: String) -> Int {
        switch window {
        case "5h": return tokensIn5h  + tokensOut5h
        case "7d": return tokensIn7d  + tokensOut7d
        default:   return 0
        }
    }
}

// MARK: - Posture threshold events (from budget-posture.events.jsonl)

/// Severity tier for a posture threshold crossing.
/// UI rendering (colors, icons) is in ToastBannerView+Severity.swift.
enum ToastSeverity {
    case info, warning, alert
}

/// One parsed line from `budget-posture.events.jsonl`.
struct PostureThresholdEvent {
    let ts:               Date
    /// "five_hour" | "seven_day" | "account"
    let window:           String
    /// "pace_warning" | "pace_critical" | "pace_recovered" | "overage_started" | "exhaustion_imminent"
    let trigger:          String
    let pace:             Float?
    let minutesRemaining: Int?

    var severity: ToastSeverity {
        switch trigger {
        case "pace_recovered":                                         return .info
        case "pace_warning":                                           return .warning
        case "pace_critical", "overage_started", "exhaustion_imminent": return .alert
        default:                                                       return .warning
        }
    }

    var toastMessage: String {
        let win: String
        switch window {
        case "five_hour": win = "5h"
        case "seven_day": win = "7d"
        case "account":   win = "account"
        default:          win = window
        }
        let paceStr = pace.map { String(format: " (%.1fx)", $0) } ?? ""
        switch trigger {
        case "pace_warning":
            return "Budget pace elevated — \(win) window\(paceStr)"
        case "pace_critical":
            return "Budget pace critical — \(win) window\(paceStr)"
        case "pace_recovered":
            return "Budget pace recovered — \(win) window"
        case "overage_started":
            return "Budget overage started (\(win))"
        case "exhaustion_imminent":
            if let m = minutesRemaining {
                return "Budget exhaustion imminent — \(m)m remaining"
            }
            return "Budget exhaustion imminent"
        default:
            return "Budget alert: \(trigger) (\(win))"
        }
    }
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
    let posture:        BudgetPosture
    let fiveHour:       WindowPace?
    let sevenDay:       WindowPace?
    let sonnetSevenDay: WindowPace?
    /// Mother-attributable agents from the `agents` map.  Empty when absent.
    let agents:         [String: AgentSpend]

    /// Each agent's share of the Mother-attributed token total for the given window
    /// ("5h" or "7d"), sorted largest-first.
    ///
    /// ⚠️  These fractions sum to 1.0 across **attributed** usage only.
    /// Non-Mother (interactive, unattributed) usage is NOT included.
    /// Never display these as "% of the full window budget".
    func attributedShares(for window: String) -> [(name: String, fraction: Float)] {
        let totals = agents.mapValues { $0.total(for: window) }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return [] }
        return totals
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, fraction: Float($0.value) / Float(sum)) }
    }

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
            sonnetSevenDay: parseSonnetWindow(json["models"], elapsedPct: parseWindowPace(json["seven_day"])?.elapsedPct),
            agents:         parseAgents(json["agents"])
        )
    }

    private static func parseWindowPace(_ v: Any?) -> WindowPace? {
        guard let d = v as? [String: Any] else { return nil }
        guard let used    = (d["used_pct"]    as? NSNumber).map({ Float($0.doubleValue) }),
              let elapsed = (d["elapsed_pct"] as? NSNumber).map({ Float($0.doubleValue) }),
              let resets  = (d["resets_at"]   as? NSNumber).map({ TimeInterval($0.doubleValue) })
        else { return nil }
        // bishop omits pace when the window is too new; compute from used/elapsed.
        let pace: Float = (d["pace"] as? NSNumber).map({ Float($0.doubleValue) })
                          ?? (elapsed > 0 ? used / elapsed : 0)
        return WindowPace(usedPct: used, elapsedPct: elapsed, pace: pace,
                          resetsAt: resets, level: d["level"] as? String ?? "normal")
    }

    private static func parseAgents(_ v: Any?) -> [String: AgentSpend] {
        guard let raw = v as? [String: [String: Any]] else { return [:] }
        return raw.compactMapValues { d in
            let ti5h = (d["tokens_in_5h"]  as? NSNumber)?.intValue ?? 0
            let to5h = (d["tokens_out_5h"] as? NSNumber)?.intValue ?? 0
            let ti7d = (d["tokens_in_7d"]  as? NSNumber)?.intValue ?? 0
            let to7d = (d["tokens_out_7d"] as? NSNumber)?.intValue ?? 0
            return AgentSpend(tokensIn5h: ti5h, tokensOut5h: to5h,
                              tokensIn7d: ti7d, tokensOut7d: to7d)
        }
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
