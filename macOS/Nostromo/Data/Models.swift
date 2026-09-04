import Foundation
import NostromoKit

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

    /// `id` of the built-in "Reset Layout" action (see `Focus.builtIns`).
    /// `ReplView.runQuickAction` matches on this to trigger the D5 client-side
    /// side effect (clear saved ratios, rebuild from the daemon's tree) in
    /// addition to sending `prompt`.
    static let resetLayoutActionID = "perri-reset-layout"
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

    // NOTE: `init(from:)` is deliberately in an extension below rather than here —
    // declaring any initializer in the body would suppress the memberwise init
    // that most of the app constructs `Focus` with.

    static let builtIns: [Focus] = [
        Focus(id: "fred",   agentTag: "fred",   projectPath: nil, isBuiltIn: true, org: "Carefeed"),
        Focus(id: "mother", agentTag: "mother", projectPath: nil, isBuiltIn: true, org: "Carefeed"),
        Focus(id: "perri",  agentTag: "perri",  projectPath: nil, isBuiltIn: true,
              quickActions: [
                  QuickAction(
                      id: "perri-start-reviewing",
                      label: "Start Reviewing",
                      prompt: "start reviewing",
                      clearFirst: true
                  ),
                  QuickAction(
                      id: QuickAction.resetLayoutActionID,
                      label: "Reset Layout",
                      prompt: "apply your standard layout",
                      clearFirst: false
                  ),
              ], org: "Carefeed"),
        Focus(id: "teri",   agentTag: "teri",   projectPath: nil, isBuiltIn: true, org: "Carefeed"),
    ]
}

extension Focus {
    /// Hand-written because Swift's synthesized `Decodable` ignores property
    /// default values.
    ///
    /// `quickActions` is non-optional with a default, so the synthesized decoder
    /// demands the key: a `Focus` written to the registry before that property
    /// existed did not fail to decode *that field*, it failed to decode at all,
    /// and took the whole saved focus list with it. The optionals are fine — the
    /// synthesized decoder already treats a missing key as nil — it is only the
    /// non-optional-with-a-default that has to be said out loud.
    ///
    /// (Found by making `make mac-test` able to fail. The test asserting this had
    /// been red for some time behind a target that always exited 0.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        agentTag       = try c.decode(String.self, forKey: .agentTag)
        projectPath    = try c.decodeIfPresent(String.self, forKey: .projectPath)
        isBuiltIn      = try c.decode(Bool.self, forKey: .isBuiltIn)
        quickActions   = try c.decodeIfPresent([QuickAction].self, forKey: .quickActions) ?? []
        org            = try c.decodeIfPresent(String.self, forKey: .org)
        sessionSummary = try c.decodeIfPresent(String.self, forKey: .sessionSummary)
    }
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
    var running:   Int = 0
    var queued:    Int = 0
    var failed:    Int = 0
    var awaiting:  Int = 0
    var succeeded: Int = 0

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
            case "running":   s.running   += 1
            case "queued":    s.queued    += 1
            case "awaiting":  s.awaiting  += 1
            case "failed":    s.failed    += 1
            case "succeeded": s.succeeded += 1
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
enum CiState: String, Codable {
    case unknown, pending, success, failure

    /// Tolerant decode: any unknown or missing string maps to `.unknown`.
    static func from(ciStateString s: String?) -> CiState {
        guard let s else { return .unknown }
        return CiState(rawValue: s.lowercased()) ?? .unknown
    }
}

/// One item from the perri queue cache.
struct PRQueueItem: Identifiable, Encodable {
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

    enum CodingKeys: String, CodingKey {
        case repo, number, title, author, bucket, url
        case newActivity = "new_activity"
        case ciState     = "ci_state"
        case headSha     = "head_sha"
    }
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

// MARK: - Teri todos (macOS-local decode types; separate from NostromoKit wire types)

/// macOS-local mirror of `TeriTodo` in `src/data/teri_todos.rs`.
/// Decoded from the `teri_state` daemon message.  Separate from NostromoKit's
/// wire type so macOS does not depend on NostromoKit for decoding.
struct TeriTodo: Decodable, Identifiable {
    let id:       Int
    let title:    String
    let status:   String          // "open" | "in_progress" | "blocked"
    let priority: Int             // 1...5
    let dueDate:  String?         // ISO date string (yyyy-MM-dd)
    let jiraKey:  String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority
        case dueDate  = "due_date"
        case jiraKey  = "jira_key"
    }
}

/// macOS-local mirror of `TeriTodosSnapshot` in `src/data/teri_todos.rs`.
struct TeriTodosSnapshot: Decodable {
    let generatedAt: String?
    let items:       [TeriTodo]
    let stale:       Bool
    let error:       String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case items, stale, error
    }

    init(from d: Decoder) throws {
        let c    = try d.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self,  forKey: .generatedAt)
        items       = (try? c.decode([TeriTodo].self,      forKey: .items))  ?? []
        stale       = (try? c.decode(Bool.self,            forKey: .stale))  ?? false
        error       = try? c.decodeIfPresent(String.self,  forKey: .error)
    }
}

// MARK: - Activity

/// One entry in an agent's ambient activity stream, as broadcast by the
/// daemon (`"type":"activity"` messages) — see `NostromodClient.decode(type_:json:raw:)`.
///
/// `agentId`/`agentType`/`parentAgentId` describe subagent attribution:
/// `agentId == nil` means the event belongs to the focus's main agent;
/// otherwise it belongs to the named subagent, and `parentAgentId` names
/// whichever agent spawned it. `seq` is a per-stream, daemon-assigned
/// monotonic counter used to detect gaps in delivery (see
/// `ActivityStreamModel.ingest(_:)`).
struct ActivityEvent: Decodable {
    let ts:             Date
    let agent:          String
    let kind:           String     // "tool_use" | "subagent_start" | "subagent_stop" | "session_start"
    let summary:        String
    let focusTag:       String?
    let sessionId:      String?
    let agentId:        String?    // nil ⇒ the main agent, not a subagent
    let agentType:      String?    // the subagent's name, when agentId is set
    let parentAgentId:  String?
    let toolName:       String?
    let toolUseId:      String?
    let cwd:            String?
    let seq:            UInt64?    // daemon-assigned per-stream sequence number

    enum CodingKeys: String, CodingKey {
        case ts, agent, kind, summary
        case focusTag      = "focus_tag"
        case sessionId     = "session_id"
        case agentId       = "agent_id"
        case agentType     = "agent_type"
        case parentAgentId = "parent_agent_id"
        case toolName      = "tool_name"
        case toolUseId     = "tool_use_id"
        case cwd
        case seq
    }
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
    let usedPct:       Float
    let elapsedPct:    Float
    let pace:          Float
    /// Smoothed pace from bishop's rolling average — more stable than instant pace,
    /// and crucially not capped when used_pct hits 100 (unlike `pace` which is
    /// derived from capped used_pct). Use this to locate the exhaustion boundary
    /// on the bar when usedPct >= 100.
    let paceSmoothed:  Float?
    let resetsAt:      TimeInterval
    let level:         String
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
        let paceSmoothed = (d["pace_smoothed"] as? NSNumber).map { Float($0.doubleValue) }
        return WindowPace(usedPct: used, elapsedPct: elapsed, pace: pace,
                          paceSmoothed: paceSmoothed,
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
                          paceSmoothed: nil,
                          resetsAt: resets, level: s["status"] as? String ?? "normal")
    }
}

// MARK: - Fred wire types (macOS-local; mirrors NostromoKit but not linked here)

/// Mirrors `DeviceFlowPrompt` in `src/data/graph_client.rs`.
struct DeviceFlowPrompt: Decodable {
    let verificationUri: String
    let userCode:        String
    let expiresAt:       Date

    enum CodingKeys: String, CodingKey {
        case verificationUri = "verification_uri"
        case userCode        = "user_code"
        case expiresAt       = "expires_at"
    }
}

/// Mirrors `MailboxItem` in `src/data/fred_mailbox.rs`.
struct MailboxItem: Decodable, Identifiable {
    let from:       String
    let subject:    String
    let receivedAt: Date?
    let vip:        Bool
    let isInvite:   Bool
    let isRead:     Bool

    var id: String { "\(from)|\(subject)|\(receivedAt?.timeIntervalSince1970 ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case from
        case subject
        case receivedAt = "received_at"
        case vip
        case isInvite   = "is_invite"
        case isRead     = "is_read"
    }
}

/// Mirrors `MailboxSnapshot` in `src/data/fred_mailbox.rs`.
struct MailboxSnapshot: Decodable {
    let generatedAt:  Date?
    let unreadCount:  Int
    let items:        [MailboxItem]
    let stale:        Bool
    let error:        String?
    let authPrompt:   DeviceFlowPrompt?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case unreadCount = "unread_count"
        case items
        case stale
        case error
        case authPrompt  = "auth_prompt"
    }

    init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(Date.self,              forKey: .generatedAt)
        unreadCount = try c.decodeIfPresent(Int.self,               forKey: .unreadCount) ?? 0
        items       = try c.decodeIfPresent([MailboxItem].self,     forKey: .items)       ?? []
        stale       = try c.decodeIfPresent(Bool.self,              forKey: .stale)       ?? false
        error       = try c.decodeIfPresent(String.self,            forKey: .error)
        authPrompt  = try c.decodeIfPresent(DeviceFlowPrompt.self,  forKey: .authPrompt)
    }
}

/// Mirrors `CalendarEvent` in `src/data/fred_calendar.rs`.
struct CalendarEvent: Decodable, Identifiable {
    let start:  Date?
    let end:    Date?
    let title:  String
    let status: String
    let isNow:  Bool

    var id: String { "\(title)|\(start?.timeIntervalSince1970 ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case title
        case status
        case isNow = "is_now"
    }
}

/// Mirrors `NextEvent` in `src/data/fred_calendar.rs`.
struct NextEvent: Decodable {
    let title:     String
    let inMinutes: Int

    enum CodingKeys: String, CodingKey {
        case title
        case inMinutes = "in_minutes"
    }
}

/// Mirrors `CalendarSnapshot` in `src/data/fred_calendar.rs`.
struct CalendarSnapshot: Decodable {
    let events:  [CalendarEvent]
    let next:    NextEvent?
    let sweater: String
    let stale:   Bool
    let error:   String?

    enum CodingKeys: String, CodingKey {
        case events
        case next
        case sweater
        case stale
        case error
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        events  = try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        next    = try c.decodeIfPresent(NextEvent.self,       forKey: .next)
        sweater = try c.decodeIfPresent(String.self,          forKey: .sweater) ?? ""
        stale   = try c.decodeIfPresent(Bool.self,            forKey: .stale)   ?? false
        error   = try c.decodeIfPresent(String.self,          forKey: .error)
    }
}

// MARK: - Agent-authored pane layout (Phase 1: agent-driven-pane-layout)
//
// These types mirror the Rust `PaneTree` / `PaneContentWire` / `FocusLayoutModel`
// defined in `src/ipc/protocol.rs` and `src/ipc/pane_registry.rs`.
// Wire encoding uses `#[serde(tag = "kind", rename_all = "snake_case")]`, so:
//   leaf:  { "kind": "leaf",  "pane_id": "repl" }
//   split: { "kind": "split", "direction": "horizontal", "children": [...], "ratios": [0.5, 0.5] }

/// Direction a split lays its children out in.
enum SplitDirection: String, Decodable, Equatable {
    case horizontal
    case vertical
}

/// A node in an agent-authored pane layout tree.
///
/// The Rust `#[serde(tag = "kind")]` encoding means each node has a `kind` discriminator.
indirect enum PaneTree: Equatable {
    case leaf(paneId: String)
    case split(direction: SplitDirection, children: [PaneTree], ratios: [Double])
    /// A region hosting several panes with exactly one frontmost (W1 —
    /// curated-agent-views). `labels` is parallel to `children`.
    case tabs(children: [PaneTree], labels: [String], active: Int)

    /// A fresh focus: a single REPL leaf.
    static let replLeaf = PaneTree.leaf(paneId: "repl")

    /// All pane ids in left-to-right, depth-first order.
    var paneIds: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let children, _): return children.flatMap(\.paneIds)
        case .tabs(let children, _, _): return children.flatMap(\.paneIds)
        }
    }
}

extension PaneTree: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case paneId    = "pane_id"
        case direction
        case children
        case ratios
        case labels
        case active
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "leaf":
            let id = try c.decode(String.self, forKey: .paneId)
            self = .leaf(paneId: id)
        case "split":
            let dir      = try c.decode(SplitDirection.self, forKey: .direction)
            let children = try c.decode([PaneTree].self,     forKey: .children)
            let ratios   = try c.decode([Double].self,       forKey: .ratios)
            self = .split(direction: dir, children: children, ratios: ratios)
        case "tabs":
            let children = try c.decode([PaneTree].self, forKey: .children)
            let labels   = try c.decode([String].self,   forKey: .labels)
            let active   = try c.decode(Int.self,        forKey: .active)
            self = .tabs(children: children, labels: labels, active: active)
        default:
            // An unrecognised kind (a future node type this client version
            // doesn't know about yet) must never throw — that would make the
            // whole `focus_layout` frame undecodable — and must never
            // fabricate a second `.replLeaf` the way this fallback used to:
            // that silently created a *second* repl pane on the client.
            // Degrade instead: decode the node's first child if it has one
            // (best-effort — something renders), else a harmless non-repl
            // placeholder leaf.
            if let children = try? c.decode([PaneTree].self, forKey: .children), let first = children.first {
                self = first
            } else {
                self = .leaf(paneId: "unknown")
            }
        }
    }
}

// MARK: - Structured diff model (W2 — curated-agent-views)

/// One line within a [DiffHunkModel]. Mirrors `DiffLine` in
/// `src/ipc/protocol.rs`.
///
/// `oldN`/`newN` are the line's number on each side, `nil` where the line
/// doesn't exist on that side. They are what makes a diff line-addressable:
/// resolving `Anchor.line(path:line:)` to a row is a lookup on `newN`, falling
/// back to the removal row carrying that `oldN`.
struct DiffLineModel: Decodable, Equatable {
    enum Kind: String, Decodable, Equatable {
        case context, added, removed, meta
    }
    let kind:  Kind
    let oldN:  Int?
    let newN:  Int?
    /// Content with the diff marker stripped. A `.meta` line keeps its raw
    /// text, because there the marker *is* the content.
    let text:  String

    enum CodingKeys: String, CodingKey {
        case kind, text
        case oldN = "old_n"
        case newN = "new_n"
    }

    init(kind: Kind, oldN: Int?, newN: Int?, text: String) {
        self.kind = kind
        self.oldN = oldN
        self.newN = newN
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .context
        oldN = try c.decodeIfPresent(Int.self, forKey: .oldN)
        newN = try c.decodeIfPresent(Int.self, forKey: .newN)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
    }
}

/// One `@@ ... @@` hunk. Mirrors `DiffHunk` in `src/ipc/protocol.rs`.
struct DiffHunkModel: Decodable, Equatable {
    /// The verbatim `@@ -a,b +c,d @@ context` line, so the client renders what
    /// git actually said rather than reconstructing it.
    let header:   String
    let oldStart: Int
    let newStart: Int
    let lines:    [DiffLineModel]

    enum CodingKeys: String, CodingKey {
        case header, lines
        case oldStart = "old_start"
        case newStart = "new_start"
    }

    init(header: String, oldStart: Int, newStart: Int, lines: [DiffLineModel]) {
        self.header   = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines    = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        header   = (try? c.decode(String.self, forKey: .header)) ?? ""
        oldStart = (try? c.decode(Int.self, forKey: .oldStart)) ?? 1
        newStart = (try? c.decode(Int.self, forKey: .newStart)) ?? 1
        lines    = (try? c.decode([DiffLineModel].self, forKey: .lines)) ?? []
    }
}

/// One file's change within a diff. Mirrors `DiffFile` in
/// `src/ipc/protocol.rs`.
struct DiffFileModel: Decodable, Equatable {
    enum Status: String, Decodable, Equatable {
        case added, removed, modified, renamed
    }
    /// The path on the new side (or, for a removal, the only path it has).
    let path:      String
    /// Where a renamed file came from.
    let oldPath:   String?
    let status:    Status
    let additions: Int
    let deletions: Int
    let hunks:     [DiffHunkModel]

    enum CodingKeys: String, CodingKey {
        case path, status, additions, deletions, hunks
        case oldPath = "old_path"
    }

    init(
        path:      String,
        oldPath:   String? = nil,
        status:    Status,
        additions: Int,
        deletions: Int,
        hunks:     [DiffHunkModel]
    ) {
        self.path      = path
        self.oldPath   = oldPath
        self.status    = status
        self.additions = additions
        self.deletions = deletions
        self.hunks     = hunks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path      = (try? c.decode(String.self, forKey: .path)) ?? ""
        oldPath   = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status    = (try? c.decode(Status.self, forKey: .status)) ?? .modified
        additions = (try? c.decode(Int.self, forKey: .additions)) ?? 0
        deletions = (try? c.decode(Int.self, forKey: .deletions)) ?? 0
        hunks     = (try? c.decode([DiffHunkModel].self, forKey: .hunks)) ?? []
    }
}

/// The payload of `PaneContentWire.code`: a file's contents at a revision.
///
/// Carries text plus the line number its first line represents, rather than an
/// array of per-line objects — the client splits and numbers, which keeps a
/// whole-file payload the same size as the `.text` variant it replaces.
struct CodePayload: Decodable, Equatable {
    let path:      String
    /// A git SHA/ref, or `"working"` for the on-disk working tree.
    let revision:  String
    /// The line number `text`'s first line represents.
    let firstLine: Int
    let text:      String

    enum CodingKeys: String, CodingKey {
        case path, revision, text
        case firstLine = "first_line"
    }

    init(path: String, revision: String, firstLine: Int, text: String) {
        self.path      = path
        self.revision  = revision
        self.firstLine = firstLine
        self.text      = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path      = (try? c.decode(String.self, forKey: .path)) ?? ""
        revision  = (try? c.decode(String.self, forKey: .revision)) ?? ""
        firstLine = (try? c.decode(Int.self, forKey: .firstLine)) ?? 1
        text      = (try? c.decode(String.self, forKey: .text)) ?? ""
    }
}

/// The payload of `PaneContentWire.diff`: a PR's change, structured per file.
struct DiffPayload: Decodable, Equatable {
    let repo:   String
    let number: Int?
    /// Per-file structure. Empty when `tooLarge` is set.
    let files:  [DiffFileModel]
    /// True when the daemon's fetch hit its own large-diff gate. The view must
    /// then say so explicitly and name `changedFiles`, rather than render an
    /// empty `files` list as "this PR changes nothing".
    let tooLarge: Bool
    /// How many files the PR changes — the only thing a `tooLarge` diff can
    /// still say about its own size.
    let changedFiles: Int

    enum CodingKeys: String, CodingKey {
        case repo, number, files
        case tooLarge     = "too_large"
        case changedFiles = "changed_files"
    }

    init(
        repo:         String,
        number:       Int?,
        files:        [DiffFileModel],
        tooLarge:     Bool = false,
        changedFiles: Int  = 0
    ) {
        self.repo         = repo
        self.number       = number
        self.files        = files
        self.tooLarge     = tooLarge
        self.changedFiles = changedFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo         = (try? c.decode(String.self, forKey: .repo)) ?? ""
        number       = try c.decodeIfPresent(Int.self, forKey: .number)
        files        = (try? c.decode([DiffFileModel].self, forKey: .files)) ?? []
        tooLarge     = (try? c.decode(Bool.self, forKey: .tooLarge)) ?? false
        changedFiles = (try? c.decode(Int.self, forKey: .changedFiles)) ?? 0
    }
}

// MARK: - Markdown block model (W3 — curated-agent-views, bet B5)

/// Inline markdown content within an `MdBlock`. Mirrors `MdSpan` in
/// `src/ipc/protocol.rs` (macOS-local copy — see `NostromoKit.MdSpan` for the
/// shared one iOS uses).
indirect enum MdSpan: Equatable {
    case text(String)
    case code(String)
    case emph([MdSpan])
    case strong([MdSpan])
    case strike([MdSpan])
    case link(spans: [MdSpan], url: String)
    case image(alt: String, url: String)
}

extension MdSpan: Decodable {
    private enum CodingKeys: String, CodingKey { case kind, text, spans, url, alt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        case "code":
            self = .code((try? c.decode(String.self, forKey: .text)) ?? "")
        case "emph":
            self = .emph((try? c.decode([MdSpan].self, forKey: .spans)) ?? [])
        case "strong":
            self = .strong((try? c.decode([MdSpan].self, forKey: .spans)) ?? [])
        case "strike":
            self = .strike((try? c.decode([MdSpan].self, forKey: .spans)) ?? [])
        case "link":
            self = .link(
                spans: (try? c.decode([MdSpan].self, forKey: .spans)) ?? [],
                url: (try? c.decode(String.self, forKey: .url)) ?? ""
            )
        case "image":
            self = .image(
                alt: (try? c.decode(String.self, forKey: .alt)) ?? "",
                url: (try? c.decode(String.self, forKey: .url)) ?? ""
            )
        default:
            self = .text("")
        }
    }
}

/// A block-level markdown element, produced server-side from raw markdown.
/// Mirrors `MdBlock` in `src/ipc/protocol.rs` (macOS-local copy).
indirect enum MdBlock: Equatable {
    case paragraph([MdSpan])
    case heading(level: Int, spans: [MdSpan])
    case codeBlock(lang: String?, text: String)
    case list(ordered: Bool, start: Int?, items: [[MdBlock]])
    case quote([MdBlock])
    case table(header: [[MdSpan]], rows: [[[MdSpan]]])
    case rule
}

extension MdBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, spans, level, lang, text, ordered, start, items, blocks, header, rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "paragraph":
            self = .paragraph((try? c.decode([MdSpan].self, forKey: .spans)) ?? [])
        case "heading":
            self = .heading(
                level: (try? c.decode(Int.self, forKey: .level)) ?? 1,
                spans: (try? c.decode([MdSpan].self, forKey: .spans)) ?? []
            )
        case "code_block":
            self = .codeBlock(
                lang: try? c.decodeIfPresent(String.self, forKey: .lang),
                text: (try? c.decode(String.self, forKey: .text)) ?? ""
            )
        case "list":
            self = .list(
                ordered: (try? c.decode(Bool.self, forKey: .ordered)) ?? false,
                start: try? c.decodeIfPresent(Int.self, forKey: .start),
                items: (try? c.decode([[MdBlock]].self, forKey: .items)) ?? []
            )
        case "quote":
            self = .quote((try? c.decode([MdBlock].self, forKey: .blocks)) ?? [])
        case "table":
            self = .table(
                header: (try? c.decode([[MdSpan]].self, forKey: .header)) ?? [],
                rows: (try? c.decode([[[MdSpan]]].self, forKey: .rows)) ?? []
            )
        case "rule":
            self = .rule
        default:
            self = .paragraph([])
        }
    }
}

// MARK: - PR conversation threads (W3 — curated-agent-views)

/// Mirrors `ConversationThreadKind` in `src/ipc/protocol.rs` (macOS-local copy).
enum ConversationThreadKind: String, Decodable, Equatable {
    case issue, review, inline
}

/// Mirrors `ConversationComment` in `src/ipc/protocol.rs` (macOS-local copy).
struct ConversationCommentModel: Decodable, Equatable, Identifiable {
    let id: String
    let author: String
    let createdAt: Date
    let body: [MdBlock]

    private enum CodingKeys: String, CodingKey {
        case id, author, body
        case createdAt = "created_at"
    }

    init(id: String, author: String, createdAt: Date, body: [MdBlock]) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(String.self, forKey: .id)) ?? ""
        author    = (try? c.decode(String.self, forKey: .author)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        body      = (try? c.decode([MdBlock].self, forKey: .body)) ?? []
    }
}

/// Mirrors `ConversationThread` in `src/ipc/protocol.rs` (macOS-local copy).
struct ConversationThreadModel: Decodable, Equatable, Identifiable {
    let id: String
    let kind: ConversationThreadKind
    let path: String?
    let line: Int?
    let diffHunk: String?
    let resolved: Bool
    let comments: [ConversationCommentModel]

    private enum CodingKeys: String, CodingKey {
        case id, kind, path, line, resolved, comments
        case diffHunk = "diff_hunk"
    }

    init(
        id: String,
        kind: ConversationThreadKind,
        path: String?,
        line: Int?,
        diffHunk: String?,
        resolved: Bool,
        comments: [ConversationCommentModel]
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.line = line
        self.diffHunk = diffHunk
        self.resolved = resolved
        self.comments = comments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = (try? c.decode(String.self, forKey: .id)) ?? ""
        kind     = (try? c.decode(ConversationThreadKind.self, forKey: .kind)) ?? .issue
        path     = try? c.decodeIfPresent(String.self, forKey: .path)
        line     = try? c.decodeIfPresent(Int.self, forKey: .line)
        diffHunk = try? c.decodeIfPresent(String.self, forKey: .diffHunk)
        resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
        comments = (try? c.decode([ConversationCommentModel].self, forKey: .comments)) ?? []
    }
}

/// Mirrors the `PrConversation` variant of `PaneContentWire` in
/// `src/ipc/protocol.rs` (macOS-local copy).
struct PrConversationPayload: Decodable, Equatable {
    let repo: String
    let number: Int?
    let title: String
    let author: String
    let url: String
    let body: [MdBlock]
    let threads: [ConversationThreadModel]
    let conversationError: String?

    private enum CodingKeys: String, CodingKey {
        case repo, number, title, author, url, body, threads
        case conversationError = "conversation_error"
    }

    init(
        repo: String,
        number: Int?,
        title: String,
        author: String,
        url: String,
        body: [MdBlock],
        threads: [ConversationThreadModel],
        conversationError: String?
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.url = url
        self.body = body
        self.threads = threads
        self.conversationError = conversationError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo              = (try? c.decode(String.self, forKey: .repo)) ?? ""
        number            = try? c.decodeIfPresent(Int.self, forKey: .number)
        title             = (try? c.decode(String.self, forKey: .title)) ?? ""
        author            = (try? c.decode(String.self, forKey: .author)) ?? ""
        url               = (try? c.decode(String.self, forKey: .url)) ?? ""
        body              = (try? c.decode([MdBlock].self, forKey: .body)) ?? []
        threads           = (try? c.decode([ConversationThreadModel].self, forKey: .threads)) ?? []
        conversationError = try? c.decodeIfPresent(String.self, forKey: .conversationError)
    }
}

/// One section of a `ticket` view's description. Mirrors `TicketSection` in
/// `src/ipc/protocol.rs` (macOS-local copy).
struct TicketSectionModel: Decodable, Equatable {
    let name: String
    let heading: [MdSpan]?
    let blocks: [MdBlock]

    private enum CodingKeys: String, CodingKey { case name, heading, blocks }

    init(name: String, heading: [MdSpan]?, blocks: [MdBlock]) {
        self.name = name
        self.heading = heading
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name    = (try? c.decode(String.self, forKey: .name)) ?? ""
        heading = try? c.decodeIfPresent([MdSpan].self, forKey: .heading)
        blocks  = (try? c.decode([MdBlock].self, forKey: .blocks)) ?? []
    }
}

/// One comment on a ticket, 1-indexed. Mirrors `TicketComment` in
/// `src/ipc/protocol.rs` (macOS-local copy).
struct TicketCommentModel: Decodable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    let author: String
    let createdAt: Date
    let blocks: [MdBlock]

    private enum CodingKeys: String, CodingKey {
        case index, author, blocks
        case createdAt = "created_at"
    }

    init(index: Int, author: String, createdAt: Date, blocks: [MdBlock]) {
        self.index = index
        self.author = author
        self.createdAt = createdAt
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index     = (try? c.decode(Int.self, forKey: .index)) ?? 0
        author    = (try? c.decode(String.self, forKey: .author)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        blocks    = (try? c.decode([MdBlock].self, forKey: .blocks)) ?? []
    }
}

/// The payload of `PaneContentWire.ticket`: an issue-tracker ticket (W4).
/// Mirrors the `Ticket` variant of `PaneContentWire` in `src/ipc/protocol.rs`
/// (macOS-local copy).
struct TicketPayload: Decodable, Equatable {
    let provider: String
    let key: String
    let summary: String
    let status: String
    let assignee: String?
    let url: String
    let sections: [TicketSectionModel]
    let comments: [TicketCommentModel]

    private enum CodingKeys: String, CodingKey {
        case provider, key, summary, status, assignee, url, sections, comments
    }

    init(
        provider: String,
        key: String,
        summary: String,
        status: String,
        assignee: String?,
        url: String,
        sections: [TicketSectionModel],
        comments: [TicketCommentModel]
    ) {
        self.provider = provider
        self.key = key
        self.summary = summary
        self.status = status
        self.assignee = assignee
        self.url = url
        self.sections = sections
        self.comments = comments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        key      = (try? c.decode(String.self, forKey: .key)) ?? ""
        summary  = (try? c.decode(String.self, forKey: .summary)) ?? ""
        status   = (try? c.decode(String.self, forKey: .status)) ?? ""
        assignee = try? c.decodeIfPresent(String.self, forKey: .assignee)
        url      = (try? c.decode(String.self, forKey: .url)) ?? ""
        sections = (try? c.decode([TicketSectionModel].self, forKey: .sections)) ?? []
        comments = (try? c.decode([TicketCommentModel].self, forKey: .comments)) ?? []
    }
}

/// Content payload pushed to a single pane, decoupled from layout geometry.
enum PaneContentWire {
    case text(String)
    case jsonSnapshot(JSONValue)
    /// Typed list of PR queue items; rendered by `PerriPRRow`.
    case prList([PrListItemModel])
    /// Transient loading state — agent signals it is refreshing this pane.
    case loading
    /// Agent encountered an error fetching this pane's data.
    case error(String)
    /// A file's contents at a revision, line-addressable (W2).
    case code(CodePayload)
    /// A PR's change, structured per file/hunk/line (W2).
    case diff(DiffPayload)
    /// A PR's description and comment/review threads, markdown-parsed (W3).
    case prConversation(PrConversationPayload)
    /// An issue-tracker ticket (W4).
    case ticket(TicketPayload)
    /// A future content kind not yet recognised by this client version.
    case unknown(JSONValue)
}

extension PaneContentWire: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, value, items, message
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            let t = try c.decode(String.self, forKey: .text)
            self = .text(t)
        case "json_snapshot":
            let raw = (try? c.decode(JSONValue.self, forKey: .value)) ?? .object([:])
            self = .jsonSnapshot(raw)
        case "pr_list":
            let items = (try? c.decode([PrListItemModel].self, forKey: .items)) ?? []
            self = .prList(items)
        case "loading":
            self = .loading
        case "error":
            let msg = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? "An error occurred"
            self = .error(msg)
        case "code":
            // Decoded from the decoder rather than the keyed container: the
            // payload's fields are siblings of `kind`, not nested under it.
            self = .code(try CodePayload(from: decoder))
        case "diff":
            self = .diff(try DiffPayload(from: decoder))
        case "pr_conversation":
            self = .prConversation(try PrConversationPayload(from: decoder))
        case "ticket":
            self = .ticket(try TicketPayload(from: decoder))
        default:
            let raw = (try? JSONValue(from: decoder)) ?? .object([:])
            self = .unknown(raw)
        }
    }
}

extension PaneContentWire: Equatable {
    /// Every case now compares structurally, including `.jsonSnapshot` and
    /// `.unknown`. Those two used to hard-code `false` unconditionally — a
    /// deliberate conservative choice ("report changed rather than risk a
    /// false unchanged") that was defensible only while their payload was an
    /// uncomparable `Any`. Now that it's a real `Equatable` `JSONValue`, that
    /// conservatism just costs a spurious re-render of every pane in every
    /// window on every daemon push (the no-op-write guard at
    /// `AppStore.swift:876-880` could never fire for these two kinds), so the
    /// conservative default is gone.
    static func == (lhs: PaneContentWire, rhs: PaneContentWire) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.loading, .loading):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        case (.prList(let a), .prList(let b)):
            return a == b
        case (.code(let a), .code(let b)):
            return a == b
        case (.diff(let a), .diff(let b)):
            return a == b
        case (.prConversation(let a), .prConversation(let b)):
            return a == b
        case (.ticket(let a), .ticket(let b)):
            return a == b
        case (.jsonSnapshot(let a), .jsonSnapshot(let b)):
            return a == b
        case (.unknown(let a), .unknown(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// How trustworthy the content in a `pane_content` push is. Mirrors
/// `PaneFreshness` in `src/ipc/protocol.rs` (macOS-local copy — see
/// `NostromoKit.PaneFreshness` for the shared one iOS uses). `stale` is the
/// source's own transient flag and must NOT be rendered — a single missed
/// poll is normal. `badlyStale` is the daemon's verdict that the source
/// hasn't produced good data in a while; it is the only flag rendered.
struct PaneFreshness: Decodable, Equatable {
    let asOf: Date?
    let stale: Bool
    let badlyStale: Bool

    private enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case stale
        case badlyStale = "badly_stale"
    }
}

/// A single point of interest inside a pane's content — "the one place to
/// land." Mirrors `Anchor` in `src/ipc/protocol.rs` (macOS-local copy — see
/// `NostromoKit.Anchor` for the shared one iOS uses). W1 transports every
/// variant but renders none of them; only `PaneAddress.reason` is rendered
/// (as a tab caption) in this wedge.
enum Anchor: Equatable {
    case line(path: String?, line: Int)
    case comment(id: String)
    case section(name: String)
    case queueRow(repo: String, number: Int)
}

extension Anchor: Decodable {
    private enum CodingKeys: String, CodingKey { case kind, path, line, id, name, repo, number }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "line":
            self = .line(
                path: try c.decodeIfPresent(String.self, forKey: .path),
                line: try c.decode(Int.self, forKey: .line)
            )
        case "comment":
            self = .comment(id: try c.decode(String.self, forKey: .id))
        case "section":
            self = .section(name: try c.decode(String.self, forKey: .name))
        case "queue_row":
            self = .queueRow(
                repo:   try c.decode(String.self, forKey: .repo),
                number: try c.decode(Int.self,    forKey: .number)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown Anchor kind: \(other)"
            )
        }
    }
}

/// A range to highlight within a pane's content. See `Anchor` for the
/// single-point counterpart. Mirrors `Emphasis` in `src/ipc/protocol.rs`.
enum Emphasis: Equatable {
    case lineRange(path: String?, start: Int, end: Int)
    case comment(id: String)
    case section(name: String)
    case textRange(start: Int, end: Int)
    case queueRow(repo: String, number: Int)
}

extension Emphasis: Decodable {
    private enum CodingKeys: String, CodingKey { case kind, path, start, end, id, name, repo, number }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "line_range":
            self = .lineRange(
                path:  try c.decodeIfPresent(String.self, forKey: .path),
                start: try c.decode(Int.self, forKey: .start),
                end:   try c.decode(Int.self, forKey: .end)
            )
        case "comment":
            self = .comment(id: try c.decode(String.self, forKey: .id))
        case "section":
            self = .section(name: try c.decode(String.self, forKey: .name))
        case "text_range":
            self = .textRange(
                start: try c.decode(Int.self, forKey: .start),
                end:   try c.decode(Int.self, forKey: .end)
            )
        case "queue_row":
            self = .queueRow(
                repo:   try c.decode(String.self, forKey: .repo),
                number: try c.decode(Int.self,    forKey: .number)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown Emphasis kind: \(other)"
            )
        }
    }
}

/// Where to look inside a pane's content, and why. Mirrors `PaneAddress` in
/// `src/ipc/protocol.rs`. A sibling of `PaneFreshness` on `pane_content`, not
/// folded into `PaneContentWire`, so it can be re-sent cheaply without
/// re-sending content.
struct PaneAddress: Decodable, Equatable {
    let anchor:   Anchor?
    let emphasis: [Emphasis]
    /// One short human-readable phrase explaining why this was shown.
    let reason:   String?

    private enum CodingKeys: String, CodingKey { case anchor, emphasis, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?`, not `decodeIfPresent`: see the matching NostromoKit
        // PaneAddress decoder for why (a future/unrecognized Anchor kind must
        // drop only the anchor, not the whole PaneContent message).
        anchor   = try? c.decodeIfPresent(Anchor.self, forKey: .anchor) ?? nil
        emphasis = (try? c.decode([Emphasis].self, forKey: .emphasis)) ?? []
        reason   = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    /// Whether this address points at the queue row for `repo`#`number`
    /// (W5 — curated-agent-views).
    ///
    /// Anchor and emphasis both count: an agent that anchored the queue on a
    /// row and one that emphasised it both meant "this one", and a row that
    /// scrolled into view unmarked would be the anchor doing half its job.
    ///
    /// Purely a rendering question — nothing here is selection. It does not
    /// change the daemon's selected index, the current-PR state, or what the
    /// queue's load/approve affordances act on.
    ///
    /// Mirrors `NostromoKit.PaneAddress.marks(repo:number:)`; the two exist
    /// because this app decodes its own copy of the pane wire types.
    func marks(repo: String, number: Int) -> Bool {
        if case .queueRow(let r, let n) = anchor, r == repo, n == number { return true }
        return emphasis.contains { e in
            if case .queueRow(let r, let n) = e { return r == repo && n == number }
            return false
        }
    }
}

/// Live layout state for a single focus (stored in AppStore, keyed by tag).
struct FocusLayoutModel {
    /// The pane tree for this focus.
    var tree: PaneTree
    /// The agent's hint for which pane to foreground (used by iOS degradation).
    var focusedPane: String?
    /// Per-pane text/json content, keyed by pane_id.
    var paneContent: [String: PaneContentWire] = [:]
    /// Per-pane freshness, keyed by pane_id. Absent entry == no freshness
    /// concept for that pane (e.g. agent-authored content via `set_pane_content`).
    var paneFreshness: [String: PaneFreshness] = [:]
    /// Per-pane address, keyed by pane_id (W1 — curated-agent-views). Absent
    /// entry == no addressing concept pushed for that pane yet.
    var paneAddress: [String: PaneAddress] = [:]

    static let initial = FocusLayoutModel(tree: .replLeaf, focusedPane: nil)
}

// MARK: - Decision modal (W6)

/// A daemon-driven decision request awaiting the operator's answer.
/// Mirrors `ServerMsg::DecisionRequest` in `src/ipc/protocol.rs`.
struct PendingDecision: Equatable {
    let tag: String
    let requestId: String
    let prompt: String
    let detail: String?
    let choices: [DecisionChoiceWire]
    let contextPaneId: String?
}

/// How a daemon-driven decision request was ultimately resolved — the
/// multi-window decision-sheet fix's backstop notice. Mirrors
/// `ServerMsg::DecisionResolved` / `DecisionResolution` in
/// `src/ipc/protocol.rs`. `resolution` is one of `"answered"`, `"dismissed"`,
/// `"timeout"`, or `"cancelled"`; `choiceId` is non-nil only when
/// `resolution == "answered"`.
struct ResolvedDecision: Equatable {
    let tag: String
    let requestId: String
    let resolution: String
    let choiceId: String?
}

/// A decoded JSON value that can be compared structurally. Replaces the
/// former `AnyDecodable`, which had no keyed-container branch and therefore
/// decoded every JSON *object* to `""` — silently dropping `json_snapshot`
/// content and making structural equality impossible (which is why
/// `PaneContentWire`'s `Equatable` conformance used to hard-code `false` for
/// `.jsonSnapshot`/`.unknown`). NostromoKit's own copy already decodes
/// objects (see `AnyDecodable.DynamicKey` in
/// `Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift`); this
/// closes that divergence on the macOS side.
///
/// `internal`, not `private` — `Models.swift` is compiled directly into the
/// `NostromoTests` logic-test target (see the header comment atop
/// `PaneContentWireEqualityTests.swift`), and those tests construct
/// `JSONValue` values directly. `Equatable` is auto-synthesized: every
/// associated value (`String`, `Int`, `Double`, `Bool`, `[JSONValue]`,
/// `[String: JSONValue]`) is itself `Equatable`.
indirect enum JSONValue: Decodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }

    init(from decoder: Decoder) throws {
        // Keyed, then unkeyed, then single-value: for any given JSON node
        // exactly one of these three container requests actually succeeds
        // (an object supports only `container(keyedBy:)`, an array only
        // `unkeyedContainer()`), so the order between the first two doesn't
        // matter — what matters is that BOTH are tried before falling back to
        // scalars. The single-value container is checked last because
        // requesting it always succeeds regardless of underlying shape; only
        // the subsequent `decode(_:)` call on it can fail.
        if let c = try? decoder.container(keyedBy: DynamicKey.self) {
            var dict: [String: JSONValue] = [:]
            for key in c.allKeys {
                dict[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            }
            self = .object(dict)
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var arr: [JSONValue] = []
            while !c.isAtEnd {
                arr.append(try c.decode(JSONValue.self))
            }
            self = .array(arr)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .null
    }
}
