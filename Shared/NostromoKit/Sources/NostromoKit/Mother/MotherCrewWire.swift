// NostromoKit — MotherCrewWire.swift
//
// Wire types for Mother's "headless crew" job keys: quality gates, the lens
// review wave, decisions, attention and the progress overlay. They mirror the
// Rust types in `src/mother/crew.rs` field by field; the contract is vendored
// under `tests/fixtures/mother-contract/`.
//
// Decoding is lenient at two levels:
//   - Per key (`MotherCrewState.init(jobDecoder:)`): a malformed new job key
//     decodes to nil / empty for that key only and its NAME (never its value)
//     is recorded in `decodeIssues`. It never costs the job.
//   - Inside a key: a missing value takes its default; an enum-like value this
//     build does not know is kept as `.unknown(raw)`.
//
// Wire payloads carry no free text, so none of these types has a field for gate
// output, finding text, claim quotes or checklist text. Do not add one.

import Foundation

// MARK: - Open enums

// Each keeps a value this build does not know as `.unknown(raw)`, so a value
// Mother adds later never fails a decode. On the wire each is a bare string.

public protocol MotherOpenEnum: Equatable, Codable {
    init(_ raw: String)
    var raw: String { get }
}

extension MotherOpenEnum {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

public enum MotherGateResult: MotherOpenEnum {
    case passed, failed, skipped, unavailable
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "passed": self = .passed
        case "failed": self = .failed
        case "skipped": self = .skipped
        case "unavailable": self = .unavailable
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .unavailable: return "unavailable"
        case .unknown(let s): return s
        }
    }
}

public enum MotherLensState: MotherOpenEnum {
    case pending, running, done, skipped, error
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "pending": self = .pending
        case "running": self = .running
        case "done": self = .done
        case "skipped": self = .skipped
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .pending: return "pending"
        case .running: return "running"
        case .done: return "done"
        case .skipped: return "skipped"
        case .error: return "error"
        case .unknown(let s): return s
        }
    }
}

public enum MotherDecisionOptionID: MotherOpenEnum {
    case resumeWithGuidance, escalate, overrideOpen, cancel
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "resume_with_guidance": self = .resumeWithGuidance
        case "escalate": self = .escalate
        case "override_open": self = .overrideOpen
        case "cancel": self = .cancel
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .resumeWithGuidance: return "resume_with_guidance"
        case .escalate: return "escalate"
        case .overrideOpen: return "override_open"
        case .cancel: return "cancel"
        case .unknown(let s): return s
        }
    }
}

public enum MotherAttentionReason: MotherOpenEnum {
    case progressStalled, burnAhead, gatesIncomplete, decisionAwaiting
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "progress_stalled": self = .progressStalled
        case "burn_ahead": self = .burnAhead
        case "gates_incomplete": self = .gatesIncomplete
        case "decision_awaiting": self = .decisionAwaiting
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .progressStalled: return "progress_stalled"
        case .burnAhead: return "burn_ahead"
        case .gatesIncomplete: return "gates_incomplete"
        case .decisionAwaiting: return "decision_awaiting"
        case .unknown(let s): return s
        }
    }
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {
    /// `decodeIfPresent` with a default for a missing or null key. A value of
    /// the wrong type still throws (the whole top-level key is then dropped).
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }

    /// The key exists and is not null (what Rust's `lenient::present` reads).
    fileprivate func isPresent(_ key: Key) -> Bool {
        contains(key) && ((try? decodeNil(forKey: key)) != true)
    }
}

// MARK: - Gates

public struct MotherGateResultEntry: Equatable, Codable {
    public var name: String
    public var result: MotherGateResult
    public var blocking: Bool
    public var durationS: Int?
    public var exitCode: Int?
    public var unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case name, result, blocking
        case durationS = "duration_s"
        case exitCode = "exit_code"
        case unavailableReason = "unavailable_reason"
    }

    public init(
        name: String = "",
        result: MotherGateResult = .unknown(""),
        blocking: Bool = false,
        durationS: Int? = nil,
        exitCode: Int? = nil,
        unavailableReason: String? = nil
    ) {
        self.name = name
        self.result = result
        self.blocking = blocking
        self.durationS = durationS
        self.exitCode = exitCode
        self.unavailableReason = unavailableReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, "")
        result = try c.value(.result, .unknown(""))
        blocking = try c.value(.blocking, false)
        durationS = try c.decodeIfPresent(Int.self, forKey: .durationS)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
    }
}

public struct MotherGates: Equatable, Codable {
    public var mode: String?
    public var posture: String?
    /// `running`, `passed`, `failed`, `incomplete`, `exhausted`, ...
    public var status: String?
    public var attempt: Int?
    public var maxAttempts: Int?
    public var headSha: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var results: [MotherGateResultEntry]
    public var notRun: [String]
    /// True when the wire's `override` is present and non-null.
    public var overridden: Bool

    enum CodingKeys: String, CodingKey {
        case mode, posture, status, attempt, results
        case maxAttempts = "max_attempts"
        case headSha = "head_sha"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case notRun = "not_run"
        case overridden = "override"
    }

    public init(
        mode: String? = nil,
        posture: String? = nil,
        status: String? = nil,
        attempt: Int? = nil,
        maxAttempts: Int? = nil,
        headSha: String? = nil,
        startedAt: String? = nil,
        finishedAt: String? = nil,
        results: [MotherGateResultEntry] = [],
        notRun: [String] = [],
        overridden: Bool = false
    ) {
        self.mode = mode
        self.posture = posture
        self.status = status
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.headSha = headSha
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
        self.notRun = notRun
        self.overridden = overridden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        posture = try c.decodeIfPresent(String.self, forKey: .posture)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts)
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        results = try c.value(.results, [])
        notRun = try c.value(.notRun, [])
        // Only presence matters; a bare bool (our own encoding) is taken as is.
        overridden = c.isPresent(.overridden) && ((try? c.decode(Bool.self, forKey: .overridden)) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(posture, forKey: .posture)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(attempt, forKey: .attempt)
        try c.encodeIfPresent(maxAttempts, forKey: .maxAttempts)
        try c.encodeIfPresent(headSha, forKey: .headSha)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encode(results, forKey: .results)
        try c.encode(notRun, forKey: .notRun)
        if overridden { try c.encode(true, forKey: .overridden) }
    }
}

// MARK: - Review wave

public struct MotherLensFindings: Equatable, Codable {
    public var blocking: Int
    public var advisory: Int

    public init(blocking: Int = 0, advisory: Int = 0) {
        self.blocking = blocking
        self.advisory = advisory
    }

    enum CodingKeys: String, CodingKey { case blocking, advisory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocking = try c.value(.blocking, 0)
        advisory = try c.value(.advisory, 0)
    }
}

public struct MotherLensEntry: Equatable, Codable {
    public var reviewer: String
    public var lens: String
    public var state: MotherLensState
    public var skipReason: String?
    public var findings: MotherLensFindings
    public var costUsd: Double?
    public var examinedFiles: Int?

    enum CodingKeys: String, CodingKey {
        case reviewer, lens, state, findings
        case skipReason = "skip_reason"
        case costUsd = "cost_usd"
        case examinedFiles = "examined_files"
    }

    public init(
        reviewer: String = "",
        lens: String = "",
        state: MotherLensState = .unknown(""),
        skipReason: String? = nil,
        findings: MotherLensFindings = MotherLensFindings(),
        costUsd: Double? = nil,
        examinedFiles: Int? = nil
    ) {
        self.reviewer = reviewer
        self.lens = lens
        self.state = state
        self.skipReason = skipReason
        self.findings = findings
        self.costUsd = costUsd
        self.examinedFiles = examinedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewer = try c.value(.reviewer, "")
        lens = try c.value(.lens, "")
        state = try c.value(.state, .unknown(""))
        skipReason = try c.decodeIfPresent(String.self, forKey: .skipReason)
        findings = try c.value(.findings, MotherLensFindings())
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        examinedFiles = try c.decodeIfPresent(Int.self, forKey: .examinedFiles)
    }
}

public struct MotherAdherence: Equatable, Codable {
    public var state: String?
    public var verdict: String?

    public init(state: String? = nil, verdict: String? = nil) {
        self.state = state
        self.verdict = verdict
    }
}

public struct MotherClaims: Equatable, Codable {
    public var verified: Int
    public var refuted: Int
    public var unverified: Int

    public init(verified: Int = 0, refuted: Int = 0, unverified: Int = 0) {
        self.verified = verified
        self.refuted = refuted
        self.unverified = unverified
    }

    enum CodingKeys: String, CodingKey { case verified, refuted, unverified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = try c.value(.verified, 0)
        refuted = try c.value(.refuted, 0)
        unverified = try c.value(.unverified, 0)
    }
}

public struct MotherReviewWave: Equatable, Codable {
    public var mode: String?
    public var status: String?
    public var cycle: Int?
    public var cycleCap: Int?
    public var budgetUsd: Double?
    public var spentUsd: Double?
    public var lenses: [MotherLensEntry]
    public var adherence: MotherAdherence?
    public var coverageGaps: Int?
    public var claims: MotherClaims?

    enum CodingKeys: String, CodingKey {
        case mode, status, cycle, lenses, adherence, claims
        case cycleCap = "cycle_cap"
        case budgetUsd = "budget_usd"
        case spentUsd = "spent_usd"
        case coverageGaps = "coverage_gaps"
    }

    public init(
        mode: String? = nil,
        status: String? = nil,
        cycle: Int? = nil,
        cycleCap: Int? = nil,
        budgetUsd: Double? = nil,
        spentUsd: Double? = nil,
        lenses: [MotherLensEntry] = [],
        adherence: MotherAdherence? = nil,
        coverageGaps: Int? = nil,
        claims: MotherClaims? = nil
    ) {
        self.mode = mode
        self.status = status
        self.cycle = cycle
        self.cycleCap = cycleCap
        self.budgetUsd = budgetUsd
        self.spentUsd = spentUsd
        self.lenses = lenses
        self.adherence = adherence
        self.coverageGaps = coverageGaps
        self.claims = claims
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        cycle = try c.decodeIfPresent(Int.self, forKey: .cycle)
        cycleCap = try c.decodeIfPresent(Int.self, forKey: .cycleCap)
        budgetUsd = try c.decodeIfPresent(Double.self, forKey: .budgetUsd)
        spentUsd = try c.decodeIfPresent(Double.self, forKey: .spentUsd)
        lenses = try c.value(.lenses, [])
        adherence = try c.decodeIfPresent(MotherAdherence.self, forKey: .adherence)
        coverageGaps = try c.decodeIfPresent(Int.self, forKey: .coverageGaps)
        claims = try c.decodeIfPresent(MotherClaims.self, forKey: .claims)
    }
}

// MARK: - Decisions

public struct MotherDecisionOption: Equatable, Codable {
    public var id: MotherDecisionOptionID
    /// Mother-templated option text.
    public var label: String
    public var consequence: String
    public var takesText: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, consequence
        case takesText = "takes_text"
    }

    public init(
        id: MotherDecisionOptionID = .unknown(""),
        label: String = "",
        consequence: String = "",
        takesText: Bool = false
    ) {
        self.id = id
        self.label = label
        self.consequence = consequence
        self.takesText = takesText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, .unknown(""))
        label = try c.value(.label, "")
        consequence = try c.value(.consequence, "")
        takesText = try c.value(.takesText, false)
    }
}

/// How a decision was resolved. Mother has not pinned its shape: a bare option
/// id and an object both decode.
public struct MotherDecisionResolution: Equatable, Codable {
    public var option: String?
    public var source: String?
    public var at: String?

    public init(option: String? = nil, source: String? = nil, at: String? = nil) {
        self.option = option
        self.source = source
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case option, source, at }

    public init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            (option, source, at) = (bare, nil, nil)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        option = try c.decodeIfPresent(String.self, forKey: .option)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        at = try c.decodeIfPresent(String.self, forKey: .at)
    }
}

public struct MotherDecision: Equatable, Codable {
    public var id: String
    public var kind: String
    public var options: [MotherDecisionOption]
    public var openedAt: String?
    public var resolvedAt: String?
    public var resolution: MotherDecisionResolution?

    /// Not yet resolved.
    public var isOpen: Bool { resolvedAt == nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, options, resolution
        case openedAt = "opened_at"
        case resolvedAt = "resolved_at"
    }

    public init(
        id: String = "",
        kind: String = "",
        options: [MotherDecisionOption] = [],
        openedAt: String? = nil,
        resolvedAt: String? = nil,
        resolution: MotherDecisionResolution? = nil
    ) {
        self.id = id
        self.kind = kind
        self.options = options
        self.openedAt = openedAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        kind = try c.value(.kind, "")
        options = try c.value(.options, [])
        openedAt = try c.decodeIfPresent(String.self, forKey: .openedAt)
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt)
        resolution = try c.decodeIfPresent(MotherDecisionResolution.self, forKey: .resolution)
    }
}

// MARK: - Attention and answers

public struct MotherAttention: Equatable, Codable {
    public var reason: MotherAttentionReason
    public var since: String?
    /// Only `attention_reasons` carries it; `attention` entries read as unacknowledged.
    public var acked: Bool

    public init(reason: MotherAttentionReason = .unknown(""), since: String? = nil, acked: Bool = false) {
        self.reason = reason
        self.since = since
        self.acked = acked
    }

    enum CodingKeys: String, CodingKey { case reason, since, acked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.value(.reason, .unknown(""))
        since = try c.decodeIfPresent(String.self, forKey: .since)
        acked = try c.value(.acked, false)
    }
}

public struct MotherLastAnswer: Equatable, Codable {
    public var source: String?
    public var session: String?
    public var agent: String?
    public var option: String?
    public var at: String?

    public init(
        source: String? = nil,
        session: String? = nil,
        agent: String? = nil,
        option: String? = nil,
        at: String? = nil
    ) {
        self.source = source
        self.session = session
        self.agent = agent
        self.option = option
        self.at = at
    }
}

// MARK: - Progress

public struct MotherGateSignal: Equatable, Codable {
    public var passed: Int
    public var failed: Int
    public var total: Int

    public init(passed: Int = 0, failed: Int = 0, total: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case passed, failed, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passed = try c.value(.passed, 0)
        failed = try c.value(.failed, 0)
        total = try c.value(.total, 0)
    }
}

public struct MotherProgressSignals: Equatable, Codable {
    public var stage: String?
    public var gates: MotherGateSignal?
    public var elapsedActiveS: Int?
    public var cost: Double?

    enum CodingKeys: String, CodingKey {
        case stage, gates, cost
        case elapsedActiveS = "elapsed_active_s"
    }

    public init(
        stage: String? = nil,
        gates: MotherGateSignal? = nil,
        elapsedActiveS: Int? = nil,
        cost: Double? = nil
    ) {
        self.stage = stage
        self.gates = gates
        self.elapsedActiveS = elapsedActiveS
        self.cost = cost
    }
}

public struct MotherProgressEta: Equatable, Codable {
    public var loS: Int?
    public var hiS: Int?
    /// Mother-written band, e.g. "5-15 min" or "under 2 min".
    public var label: String?
    /// `repo`, `fleet`, `none`, or a value from the future.
    public var basis: String?

    enum CodingKeys: String, CodingKey {
        case label, basis
        case loS = "lo_s"
        case hiS = "hi_s"
    }

    public init(loS: Int? = nil, hiS: Int? = nil, label: String? = nil, basis: String? = nil) {
        self.loS = loS
        self.hiS = hiS
        self.label = label
        self.basis = basis
    }
}

public struct MotherMovedBack: Equatable, Codable {
    public var reason: String?
    public var at: String?

    public init(reason: String? = nil, at: String? = nil) {
        self.reason = reason
        self.at = at
    }
}

/// A progress flag. Mother's plan writes objects (`{reason, since, detail}`), the
/// fixtures have none, and a bare string must work too. `detail` is not read.
public struct MotherProgressFlag: Equatable, Codable {
    public var reason: String
    public var since: String?

    public init(reason: String = "", since: String? = nil) {
        self.reason = reason
        self.since = since
    }

    enum CodingKeys: String, CodingKey { case reason, since }

    public init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            (reason, since) = (bare, nil)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.value(.reason, "")
        since = try c.decodeIfPresent(String.self, forKey: .since)
    }
}

/// Mother's `.progress` overlay (also the `progress_updated` event detail).
public struct MotherProgress: Equatable, Codable {
    public var v: Int?
    public var pct: Int?
    /// Mother-written display text for the stage (`paused · <reason>` when paused).
    public var label: String?
    public var stage: String?
    public var signals: MotherProgressSignals?
    public var eta: MotherProgressEta?
    public var paused: Bool
    public var movedBack: MotherMovedBack?
    public var flags: [MotherProgressFlag]
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case v, pct, label, stage, signals, eta, paused, flags
        case movedBack = "moved_back"
        case updatedAt = "updated_at"
    }

    public init(
        v: Int? = nil,
        pct: Int? = nil,
        label: String? = nil,
        stage: String? = nil,
        signals: MotherProgressSignals? = nil,
        eta: MotherProgressEta? = nil,
        paused: Bool = false,
        movedBack: MotherMovedBack? = nil,
        flags: [MotherProgressFlag] = [],
        updatedAt: String? = nil
    ) {
        self.v = v
        self.pct = pct
        self.label = label
        self.stage = stage
        self.signals = signals
        self.eta = eta
        self.paused = paused
        self.movedBack = movedBack
        self.flags = flags
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v)
        pct = try c.decodeIfPresent(Int.self, forKey: .pct)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        signals = try c.decodeIfPresent(MotherProgressSignals.self, forKey: .signals)
        eta = try c.decodeIfPresent(MotherProgressEta.self, forKey: .eta)
        paused = try c.value(.paused, false)
        movedBack = try c.decodeIfPresent(MotherMovedBack.self, forKey: .movedBack)
        flags = try c.value(.flags, [])
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

// MARK: - Per-job state

/// Everything the crew contract adds to a job, read leniently from the job's
/// top-level keys. The broker's JSON and the daemon's `MotherJobs` JSON use the
/// same keys, except that the daemon replaces the opaque `crew` blob with
/// `crew_opt_in: true`.
public struct MotherCrewState: Equatable, Codable {
    /// The repo opted in (`crew` present, or the daemon's `crew_opt_in`).
    public var optedIn: Bool
    public var activity: String?
    public var prUrl: String?
    public var gates: MotherGates?
    public var reviewWave: MotherReviewWave?
    public var decision: MotherDecision?
    /// `attention_reasons` (carries `acked`) when present and non-empty, else `attention`.
    public var attention: [MotherAttention]
    public var lastAnswer: MotherLastAnswer?
    public var progress: MotherProgress?
    public var criteriaSource: String?
    /// Key names (never values) of the keys that could not be read.
    public var decodeIssues: [String]

    enum Keys: String, CodingKey {
        case crew
        case crewOptIn = "crew_opt_in"
        case activity, gates, decision, attention, progress
        case prUrl = "pr_url"
        case reviewWave = "review_wave"
        case attentionReasons = "attention_reasons"
        case lastAnswer = "last_answer"
        case criteriaSource = "criteria_source"
    }

    public init(
        optedIn: Bool = false,
        activity: String? = nil,
        prUrl: String? = nil,
        gates: MotherGates? = nil,
        reviewWave: MotherReviewWave? = nil,
        decision: MotherDecision? = nil,
        attention: [MotherAttention] = [],
        lastAnswer: MotherLastAnswer? = nil,
        progress: MotherProgress? = nil,
        criteriaSource: String? = nil,
        decodeIssues: [String] = []
    ) {
        self.optedIn = optedIn
        self.activity = activity
        self.prUrl = prUrl
        self.gates = gates
        self.reviewWave = reviewWave
        self.decision = decision
        self.attention = attention
        self.lastAnswer = lastAnswer
        self.progress = progress
        self.criteriaSource = criteriaSource
        self.decodeIssues = decodeIssues
    }

    /// Read each key from the job's top-level container on its own: one bad key
    /// yields nil (or empty) for that key only.
    public init(jobDecoder decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var issues: [String] = []

        func read<T: Decodable>(_ type: T.Type, _ key: Keys) -> T? {
            do {
                return try c.decodeIfPresent(type, forKey: key)
            } catch {
                issues.append(key.rawValue)
                return nil
            }
        }

        let flagged = (try? c.decodeIfPresent(Bool.self, forKey: .crewOptIn)) ?? false
        optedIn = c.isPresent(.crew) || flagged
        activity = read(String.self, .activity)
        prUrl = read(String.self, .prUrl)
        gates = read(MotherGates.self, .gates)
        reviewWave = read(MotherReviewWave.self, .reviewWave)
        decision = read(MotherDecision.self, .decision)
        let derived = read([MotherAttention].self, .attentionReasons) ?? []
        let plain = read([MotherAttention].self, .attention) ?? []
        attention = derived.isEmpty ? plain : derived
        lastAnswer = read(MotherLastAnswer.self, .lastAnswer)
        progress = read(MotherProgress.self, .progress)
        criteriaSource = read(String.self, .criteriaSource)
        decodeIssues = issues
    }

    public init(from decoder: Decoder) throws {
        try self.init(jobDecoder: decoder)
    }

    /// Flat, in the daemon's form: `crew_opt_in`, then each key that has a value.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if optedIn { try c.encode(true, forKey: .crewOptIn) }
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(prUrl, forKey: .prUrl)
        try c.encodeIfPresent(gates, forKey: .gates)
        try c.encodeIfPresent(reviewWave, forKey: .reviewWave)
        try c.encodeIfPresent(decision, forKey: .decision)
        if !attention.isEmpty { try c.encode(attention, forKey: .attention) }
        try c.encodeIfPresent(lastAnswer, forKey: .lastAnswer)
        try c.encodeIfPresent(progress, forKey: .progress)
        try c.encodeIfPresent(criteriaSource, forKey: .criteriaSource)
    }
}
