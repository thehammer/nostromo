// NostromoKit — MotherCrewPresentation.swift
//
// Pure presentation models for Mother's crew data: the progress line, gate
// rows, lens rows, attention badges and the hold summary. No UI framework: the
// Mac panel and iOS render these. Every piece of text has an accessibility
// string, and no state is conveyed by a glyph alone (each has a glyph AND a word).

import Foundation

/// One row of a gates or review-wave list.
public struct MotherCrewRow: Identifiable, Equatable {
    public enum Kind: Equatable { case header, item, note }

    public let id: String
    public let kind: Kind
    public let glyph: String
    public let title: String
    public let detail: String
    public let accessibility: String

    public init(id: String, kind: Kind, glyph: String = "", title: String, detail: String = "", accessibility: String) {
        self.id = id
        self.kind = kind
        self.glyph = glyph
        self.title = title
        self.detail = detail
        self.accessibility = accessibility
    }
}

// MARK: - Progress line

public enum MotherProgressLine {
    /// `≈{pct}% · gates {passed}/{total} · ETA {eta}`; Mother's `label` while paused.
    public static func make(progress: MotherProgress?, gates: MotherGates?) -> (text: String, accessibility: String)? {
        guard let progress else { return nil }

        if progress.paused {
            let label = progress.label.flatMap { $0.isEmpty ? nil : $0 }
            return (label ?? "Paused", label.map { "Paused. \($0)" } ?? "Paused")
        }
        guard let pct = progress.pct else { return nil }

        var text = "≈\(pct)%"
        var spoken = "About \(pct) percent."

        if let signal = gateSignal(progress: progress, gates: gates) {
            text += " · gates \(signal.passed)/\(signal.total)"
            spoken += " \(signal.passed) of \(signal.total) gates passed."
        }

        if let label = knownEtaLabel(progress.eta) {
            text += " · ETA \(label.first?.isNumber == true ? "~" : "")\(label)"
            spoken += " Estimated \(spokenBand(label))."
        } else {
            text += " · ETA ?"
            spoken += " Estimated time unknown."
        }
        return (text, spoken)
    }

    private static func gateSignal(progress: MotherProgress, gates: MotherGates?) -> (passed: Int, total: Int)? {
        if let s = progress.signals?.gates, s.total > 0 {
            return (s.passed, s.total)
        }
        if let g = gates, !g.results.isEmpty {
            return (g.results.filter { $0.result == .passed }.count, g.results.count + g.notRun.count)
        }
        return nil
    }

    private static func knownEtaLabel(_ eta: MotherProgressEta?) -> String? {
        guard let eta, eta.basis != "none", let label = eta.label, !label.isEmpty else { return nil }
        return label
    }

    /// "5-15 min" → "5 to 15 minutes"; "under 2 min" → "under 2 minutes".
    private static func spokenBand(_ label: String) -> String {
        var s = label
        if let dash = s.range(of: #"(?<=\d)-(?=\d)"#, options: .regularExpression) {
            s.replaceSubrange(dash, with: " to ")
        }
        return s.replacingOccurrences(of: #"\bmin\b"#, with: "minutes", options: .regularExpression)
            .replacingOccurrences(of: #"\bhr\b"#, with: "hours", options: .regularExpression)
            .replacingOccurrences(of: #"\bs\b"#, with: "seconds", options: .regularExpression)
    }
}

// MARK: - Gates

public enum MotherGateRows {
    public static func make(_ gates: MotherGates?) -> [MotherCrewRow] {
        guard let gates else { return [] }
        var rows: [MotherCrewRow] = []

        var headerTitle = "gates"
        var headerSpoken = "Gates"
        if let n = gates.attempt, let cap = gates.maxAttempts {
            headerTitle += " \(n)/\(cap)"
            headerSpoken += ", attempt \(n) of \(cap)"
        }
        rows.append(MotherCrewRow(
            id: "gates:header", kind: .header, title: headerTitle,
            detail: gates.status ?? "",
            accessibility: gates.status.map { "\(headerSpoken), \($0)" } ?? headerSpoken
        ))

        for entry in gates.results {
            rows.append(row(for: entry, attempt: gates.attempt, maxAttempts: gates.maxAttempts))
        }

        let names = incompleteNames(gates)
        if gates.status == "incomplete" || !names.isEmpty {
            let title = names.isEmpty ? "Gates incomplete" : "Gates incomplete: \(names.joined(separator: ", "))"
            rows.append(MotherCrewRow(
                id: "gates:incomplete", kind: .note, glyph: "?", title: title,
                accessibility: title + ". These gates did not run, so they are not counted as passed."
            ))
        }
        return rows
    }

    private static func row(for entry: MotherGateResultEntry, attempt: Int?, maxAttempts: Int?) -> MotherCrewRow {
        let word = entry.result.raw
        var parts = [word]
        var spoken = ["\(entry.name): \(word)"]
        if let d = entry.durationS {
            parts.append(duration(d))
            spoken.append("took \(spokenDuration(d))")
        }
        if entry.result == .failed, let code = entry.exitCode {
            parts.append("exit \(code)")
            spoken.append("exit code \(code)")
        }
        let role = entry.blocking ? "blocking" : "advisory"
        parts.append(role)
        spoken.append(role)
        if let n = attempt, let cap = maxAttempts {
            parts.append("attempt \(n)/\(cap)")
            spoken.append("attempt \(n) of \(cap)")
        }
        return MotherCrewRow(
            id: "gate:\(entry.name)", kind: .item, glyph: glyph(entry.result), title: entry.name,
            detail: parts.joined(separator: " · "),
            accessibility: spoken.joined(separator: ", ")
        )
    }

    private static func glyph(_ result: MotherGateResult) -> String {
        switch result {
        case .passed: return "✓"
        case .failed: return "✗"
        case .skipped: return "–"
        case .unavailable, .unknown: return "?"
        }
    }

    /// Gates that did not run: `not_run`, then unavailable results, deduped in order.
    private static func incompleteNames(_ gates: MotherGates) -> [String] {
        var seen = Set<String>()
        return (gates.notRun + gates.results.filter { $0.result == .unavailable }.map(\.name))
            .filter { seen.insert($0).inserted }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let rest = seconds % 60
        return "\(seconds / 60)m \(rest < 10 ? "0" : "")\(rest)s"
    }

    static func spokenDuration(_ seconds: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if seconds < 60 { return unit(seconds, "second") }
        let (m, s) = (seconds / 60, seconds % 60)
        return s == 0 ? unit(m, "minute") : "\(unit(m, "minute")) \(unit(s, "second"))"
    }
}

// MARK: - Review wave

public enum MotherLensRows {
    public static func make(_ wave: MotherReviewWave?) -> [MotherCrewRow] {
        guard let wave else { return [] }
        var rows: [MotherCrewRow] = []

        var title = "Review wave"
        var spoken = "Review wave"
        if let cycle = wave.cycle, let cap = wave.cycleCap {
            title += " cycle \(cycle)/\(cap)"
            spoken += ", cycle \(cycle) of \(cap)"
        }
        if let status = wave.status {
            title += " · \(status)"
            spoken += ", \(status)"
        }
        rows.append(MotherCrewRow(id: "lenses:header", kind: .header, title: title, accessibility: spoken))

        for lens in wave.lenses {
            rows.append(row(for: lens))
        }

        if let a = wave.adherence, a.state != nil || a.verdict != nil {
            let text = "Adherence: " + [a.state, a.verdict].compactMap { $0 }.joined(separator: " · ")
            rows.append(MotherCrewRow(
                id: "lenses:adherence", kind: .note, glyph: adherenceGlyph(a.state), title: text, accessibility: text
            ))
        }
        if let c = wave.claims {
            // Citations are checked for existence, not for correctness: never say "correct".
            let text = "citations found \(c.verified) · not found \(c.refuted) · unverified \(c.unverified)"
            rows.append(MotherCrewRow(
                id: "lenses:claims", kind: .note, glyph: "·", title: text,
                accessibility: "Citations found \(c.verified), not found \(c.refuted), unverified \(c.unverified)"
            ))
        }
        if let gaps = wave.coverageGaps, gaps > 0 {
            let text = "Coverage gaps: \(gaps)"
            rows.append(MotherCrewRow(id: "lenses:gaps", kind: .note, glyph: "?", title: text, accessibility: text))
        }
        return rows
    }

    private static func row(for lens: MotherLensEntry) -> MotherCrewRow {
        let word = lens.state.raw
        var parts = [word]
        var spoken = ["\(lens.reviewer): \(word)"]
        if lens.state == .skipped {
            if let reason = lens.skipReason {
                let words = skipReasonWords(reason)
                parts.append(words)
                spoken.append(words)
            }
        } else {
            let counts = "\(lens.findings.blocking) blocking · \(lens.findings.advisory) advisory"
            parts.append(counts)
            spoken.append("\(lens.findings.blocking) blocking, \(lens.findings.advisory) advisory findings")
        }
        if let cost = lens.costUsd, cost > 0 {
            parts.append(String(format: "$%.2f", cost))
            spoken.append(String(format: "cost %.2f dollars", cost))
        }
        return MotherCrewRow(
            id: "lens:\(lens.reviewer)", kind: .item, glyph: glyph(lens.state), title: lens.reviewer,
            detail: parts.joined(separator: " · "), accessibility: spoken.joined(separator: ", ")
        )
    }

    private static func glyph(_ state: MotherLensState) -> String {
        switch state {
        case .pending: return "·"
        case .running: return "…"
        case .done: return "✓"
        case .skipped: return "–"
        case .error: return "✗"
        case .unknown: return "?"
        }
    }

    private static func adherenceGlyph(_ state: String?) -> String {
        switch state {
        case "done", "passed": return "✓"
        case "running": return "…"
        case "pending": return "·"
        case "error", "failed": return "✗"
        default: return "?"
        }
    }

    static func skipReasonWords(_ reason: String) -> String {
        switch reason {
        case "path_scope": return "not in scope"
        case "posture": return "not needed for this repo"
        case "budget": return "over budget"
        case "removed_by_plan": return "removed by the plan"
        default: return reason
        }
    }
}

// MARK: - Attention

public struct MotherAttentionBadge: Equatable {
    public let reason: MotherAttentionReason
    public let label: String
    public let acked: Bool
    public let accessibility: String

    /// The operator can acknowledge this flag. A pending decision is answered, not acknowledged,
    /// and a reason this client does not know is left alone.
    public var canAcknowledge: Bool {
        guard !acked else { return false }
        switch reason {
        case .progressStalled, .burnAhead, .gatesIncomplete: return true
        case .decisionAwaiting, .unknown: return false
        }
    }

    public var acknowledgeAccessibility: String { "Acknowledge \(label)" }
}

public enum MotherAttentionBadges {
    /// Fixed order (decision, gates, stalled, burn), unknown reasons last. Acknowledged
    /// reasons are kept and marked. A reason listed twice collapses to one badge.
    public static func make(_ attention: [MotherAttention]) -> [MotherAttentionBadge] {
        var seen = Set<String>()
        let unique = attention.filter { seen.insert($0.reason.raw).inserted }
        return unique
            .enumerated()
            .sorted { (rank($0.element.reason), $0.offset) < (rank($1.element.reason), $1.offset) }
            .map { badge(for: $0.element) }
    }

    private static func rank(_ reason: MotherAttentionReason) -> Int {
        switch reason {
        case .decisionAwaiting: return 0
        case .gatesIncomplete: return 1
        case .progressStalled: return 2
        case .burnAhead: return 3
        case .unknown: return 4
        }
    }

    private static func label(_ reason: MotherAttentionReason) -> String {
        switch reason {
        case .decisionAwaiting: return "Needs decision"
        case .gatesIncomplete: return "Gates incomplete"
        case .progressStalled: return "Stalled"
        case .burnAhead: return "Burning ahead"
        case .unknown(let raw): return raw
        }
    }

    private static func badge(for entry: MotherAttention) -> MotherAttentionBadge {
        let text = label(entry.reason)
        return MotherAttentionBadge(
            reason: entry.reason, label: text, acked: entry.acked,
            accessibility: entry.acked ? "\(text), acknowledged" : text
        )
    }
}

// MARK: - Hold summary

/// A job held for the operator: what kind of hold, and the options Mother offers.
public struct MotherHoldSummary: Equatable {
    public struct Option: Equatable {
        public let id: MotherDecisionOptionID
        public let label: String
        public let consequence: String
        public let takesText: Bool
        public let accessibility: String
    }

    public let kind: String
    public let question: String?
    public let options: [Option]
    public let accessibility: String

    /// The same hold without its option list, for a host that draws the options itself.
    func withoutOptions() -> MotherHoldSummary {
        MotherHoldSummary(kind: kind, question: question, options: [], accessibility: accessibility)
    }

    /// Nil unless the job is waiting on the operator: awaiting with a gate or review
    /// hold activity, or an open decision.
    public static func make(_ job: MotherJob) -> MotherHoldSummary? {
        let activity = job.crew.activity
        let heldActivity = job.state == "awaiting" && (activity == "gate_hold" || activity == "review_hold")
        let openDecision = job.crew.decision.flatMap { $0.isOpen ? $0 : nil }
        guard heldActivity || openDecision != nil else { return nil }

        let kind: String
        switch activity {
        case "gate_hold": kind = "Gates exhausted"
        case "review_hold": kind = "Review hold"
        default: kind = "Decision needed"
        }
        let options = (openDecision?.options ?? []).map { o in
            Option(
                id: o.id, label: o.label, consequence: o.consequence, takesText: o.takesText,
                accessibility: o.consequence.isEmpty ? o.label : "\(o.label). \(o.consequence)"
            )
        }
        return MotherHoldSummary(
            kind: kind, question: job.question, options: options,
            accessibility: "\(kind). \(options.count) \(options.count == 1 ? "option" : "options")."
        )
    }
}
