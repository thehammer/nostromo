// NostromoKit — MotherRowLineTwo.swift
//
// Pure composition of line two of a condensed Mother job row (Mother focus v2, R5):
// `origin · repo · state fact`, attention badges and a reserved notified-mark slot at the
// right edge. Which segments survive a width, and what is truncated, is decided here, with an
// injected `measure`, so it is testable at exact widths and the view only draws the result.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct MotherRowLineTwo: Equatable, Sendable {
    /// Always present; truncated (with `…`) after the state fact has been.
    public let origin: String
    /// Dropped below 340 pt when it does not fit, always below 260 pt.
    public let repo: String?
    /// Always present; truncated first.
    public let stateFact: String
    /// A separate segment (`$2.14`); dropped before the repo, always below 340 pt.
    public let cost: String?
    /// Right-edge badges: `⚑ Stalled`, …; just `⚑` each when `badgesCollapsed`.
    public let badges: [String]
    public let badgesCollapsed: Bool
    /// The notified mark: the wide form from 340 pt up when it takes no more than 40% of the line,
    /// otherwise the narrow glyph. Nil when the job's focus is not notified.
    public let notifiedMark: String?

    public static let narrowWidth: CGFloat = 340
    public static let narrowestWidth: CGFloat = 260
    /// Room kept at the right edge for the notified mark: at least this much, even with no mark.
    public static let notifiedSlotWidth: CGFloat = 14
    public static let factCap = 40
    /// Longest title in the spoken label and the tooltip.
    public static let titleCap = 200
    public static let separator = " · "
    public static let badgeSpacing: CGFloat = 6

    // MARK: - Compose

    public static func compose(
        model: MotherJobRowModel,
        availableWidth: CGFloat,
        measure: (String) -> CGFloat
    ) -> MotherRowLineTwo {
        let fullOrigin = model.origin?.text ?? ""
        let fullFact = stateFact(for: model)
        let cleanRepo = MotherOriginDisplay.clean(model.repo, cap: 60)
        let fullRepo: String? = cleanRepo.isEmpty ? nil : cleanRepo
        let fullCost = model.cost

        // Right edge: badges, then the slot.
        let allBadges = model.attentionBadges.map { MotherOriginDisplay.clean($0, cap: 30) }.filter { !$0.isEmpty }
        let labelled = allBadges.map { "⚑ \($0)" }
        let labelledWidth = labelled.map(measure).reduce(0, +) + badgeSpacing * CGFloat(max(0, labelled.count - 1))
        // Collapse to a bare `⚑` below 260 pt, and also when the labelled badges would take more than 40% of
        // the line: that protects the fixed row height (the origin and fact need the room). The words stay
        // in the tooltip and the spoken label.
        let collapsed = !allBadges.isEmpty
            && (availableWidth < narrowestWidth || labelledWidth > availableWidth * 0.4)
        let shownBadges = collapsed ? allBadges.map { _ in "⚑" } : labelled
        let badgesWidth = shownBadges.map(measure).reduce(0, +)
            + badgeSpacing * CGFloat(max(0, shownBadges.count - 1))
        var mark: String?
        if let m = model.noticeMark {
            let wide = measure(m.wide)
            mark = availableWidth >= narrowWidth && wide <= availableWidth * 0.4 ? m.wide : m.narrow
        }
        let slotWidth = max(notifiedSlotWidth, mark.map(measure) ?? 0)
        let rightWidth = slotWidth + (shownBadges.isEmpty ? 0 : badgesWidth + badgeSpacing)
        let budget = max(0, availableWidth - rightWidth)

        let sepWidth = measure(separator)
        func width(origin: String, repo: String?, fact: String, cost: String?) -> CGFloat {
            let parts = [origin, repo, fact, cost].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.map(measure).reduce(0, +) + sepWidth * CGFloat(max(0, parts.count - 1))
        }

        var repo = fullRepo, cost = fullCost
        if availableWidth < narrowestWidth {
            repo = nil; cost = nil
        } else {
            if availableWidth < narrowWidth { cost = nil }
            if width(origin: fullOrigin, repo: repo, fact: fullFact, cost: cost) > budget { cost = nil }
            if width(origin: fullOrigin, repo: repo, fact: fullFact, cost: cost) > budget { repo = nil }
        }

        // Origin and fact stay; the fact gives way first, then the origin.
        var origin = fullOrigin, fact = fullFact
        let others = [repo, cost].compactMap { $0 }.map(measure).reduce(0, +)
            + sepWidth * CGFloat([repo, cost].compactMap { $0 }.count)
        let core = budget - others - sepWidth
        let originWidth = measure(origin), factWidth = measure(fact)
        if originWidth + factWidth > core {
            let floor = min(factWidth, measure(String(fact.prefix(8)) + "…"))
            let factRoom = min(factWidth, max(core - originWidth, floor))
            fact = truncate(fact, to: factRoom, measure: measure)
            origin = truncate(origin, to: core - factRoom, measure: measure)
        }
        return MotherRowLineTwo(origin: origin, repo: repo, stateFact: fact, cost: cost,
                                badges: shownBadges, badgesCollapsed: collapsed,
                                notifiedMark: mark)
    }

    /// The longest prefix of `text` that, with `…`, fits `width`; `…` alone when none does.
    static func truncate(_ text: String, to width: CGFloat, measure: (String) -> CGFloat) -> String {
        if measure(text) <= width { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(chars[..<mid]) + "…") <= width { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[..<lo]) + "…"
    }

    // MARK: - State fact

    /// The one most useful fact for the job's state, sanitised and capped. Never truncated by width.
    public static func stateFact(for model: MotherJobRowModel) -> String {
        switch model.state {
        case "running":
            return progressFact(model.progressLine) ?? "running"
        case "awaiting":
            let q = MotherOriginDisplay.clean(model.question, cap: factCap)
            return q.isEmpty ? "awaiting" : q
        case "succeeded":
            guard let n = model.prNumber else { return "succeeded" }
            return model.prMerged ? "PR #\(n) merged" : "PR #\(n)"
        case "failed":
            let reason = MotherOriginDisplay.clean(model.failureReason, cap: factCap)
            return reason.isEmpty ? "failed" : "failed: \(reason)"
        case "cancelled", "queued", "ready":
            return model.state
        default:
            let s = MotherOriginDisplay.clean(model.state, cap: 20)
            return s.isEmpty ? "unknown" : s
        }
    }

    /// `≈60% · gates 2/3`: the progress line without its ETA.
    private static func progressFact(_ line: String?) -> String? {
        guard let line else { return nil }
        let parts = line.components(separatedBy: separator).filter { !$0.hasPrefix("ETA") }
        let fact = MotherOriginDisplay.clean(parts.joined(separator: separator), cap: factCap)
        return fact.isEmpty ? nil : fact
    }

    // MARK: - VoiceOver

    /// `<state>. <title>. From <origin>. [<repo>, branch <b>.] <state fact>. [<progress>.] [Cost <c>.]` then
    /// every attention badge. It is built from the model alone, so a narrow column or a badge collapsed to
    /// `⚑` never removes words from it.
    public static func accessibilityLabel(model: MotherJobRowModel) -> String {
        let cleanState = MotherOriginDisplay.clean(model.state, cap: 20)
        let rawState = cleanState.isEmpty ? "unknown" : cleanState
        let state = rawState.prefix(1).uppercased() + rawState.dropFirst()
        var parts = ["\(state).", "\(cappedTitle(model))."]
        if let origin = model.origin { parts.append("\(origin.accessibilityText).") }
        let repo = MotherOriginDisplay.clean(model.repo, cap: 60)
        let branch = MotherOriginDisplay.clean(model.branch, cap: 60)
        switch (repo.isEmpty ? nil : repo, branch.isEmpty ? nil : branch) {
        case (let r?, let b?): parts.append("\(r), branch \(b).")
        case (let r?, nil):    parts.append("\(r).")
        case (nil, let b?):    parts.append("Branch \(b).")
        case (nil, nil):       break
        }
        parts.append("\(stateFact(for: model)).")
        if model.reservesProgressLine,
           let progress = model.progressAccessibility ?? model.progressLine {
            let clean = MotherOriginDisplay.clean(progress, cap: 80)
            if !clean.isEmpty { parts.append("\(clean).") }
        }
        if let cost = model.cost, !cost.isEmpty { parts.append("Cost \(MotherOriginDisplay.clean(cost, cap: 20)).") }
        for badge in model.attentionBadges {
            let clean = MotherOriginDisplay.clean(badge, cap: 30)
            if !clean.isEmpty { parts.append("\(clean).") }
        }
        if let sentence = model.noticeMark?.accessibilitySentence { parts.append(sentence) }
        return parts.joined(separator: " ")
    }

    /// The row's title, sanitised and capped at `titleCap` characters (spoken label and tooltip).
    public static func cappedTitle(_ model: MotherJobRowModel) -> String {
        let t = FoldTextSanitizer.sanitizeInline(model.title.isEmpty ? model.id : model.title)
        return t.count > titleCap ? String(t.prefix(titleCap)) + "…" : t
    }
}
