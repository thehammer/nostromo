// NostromoKit — PersistedRulesText.swift
//
// The words of "Always allow…" (AP6): the confirmation step on the card and the Rules list.
// Pure functions, so the card and the list only draw what they return and the tests can pin it.

import Foundation

public enum PersistedRulesText {

    /// Where the rules file lives, as the confirmation shows it.
    public static let rulesFilePath = "~/.nostromo/approvals/rules.json"

    // MARK: Confirmation step

    /// `Write this rule to ~/.nostromo/approvals/rules.json`
    public static let destinationLine = "Write this rule to \(rulesFilePath)"

    /// `Your ~/.claude/settings.json is not changed`
    public static let settingsUnchangedLine = "Your ~/.claude/settings.json is not changed"

    /// `Every Nostromo session in ~/Code/x will run this without asking`
    public static func affectsLine(scopeDescription: String) -> String {
        "Every Nostromo session in \(scopeDescription) will run this without asking"
    }

    /// The scope pop-up's items, in order: the preselected one first.
    public static func scopeTitle(_ scope: ApprovalRuleScope, repoRoot: String?, repoIsGit: Bool, home: String) -> String {
        switch scope {
        case .repo:
            let root = repoRoot.map { ApprovalKinds.homeAbbreviated($0, home: home) } ?? "this session's folder"
            return "\(repoIsGit ? "This repository" : "This folder") (\(root))"
        case .allRepos:
            return "All repositories"
        }
    }

    /// What `affectsLine` says for a scope: the path for one repository, `all repositories` otherwise.
    public static func scopeDescription(_ scope: ApprovalRuleScope, repoRoot: String?, home: String) -> String {
        switch scope {
        case .repo: return repoRoot.map { ApprovalKinds.homeAbbreviated($0, home: home) } ?? "this session's folder"
        case .allRepos: return "all repositories"
        }
    }

    /// Whether the card may offer the repository scope: the daemon sent a root.
    public static func offersRepoScope(repoRoot: String?) -> Bool {
        guard let root = repoRoot else { return false }
        return !root.isEmpty
    }

    /// The candidate pop-up's titles keep the exact candidate first, whatever order the daemon sent.
    public static func orderedCandidates(_ candidates: [ApprovalSessionRuleCandidate]) -> [ApprovalSessionRuleCandidate] {
        candidates.filter { $0.kind == .exact } + candidates.filter { $0.kind != .exact }
    }

    /// The text **Copy rule** puts on the pasteboard: the rule as shown, for the user's own settings.
    public static func copyText(for candidate: ApprovalSessionRuleCandidate) -> String { candidate.ruleText }

    /// What the card says under the panel when the daemon refused the rule.
    public static func refusalText(code: ApprovalAnswerRefusalCode, reason: String?) -> String? {
        switch code {
        case .ruleRefused: return reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Nostromo will not keep this rule."
        case .ruleWriteFailed: return "The rules file could not be written. Nothing was allowed."
        case .rulesQuarantined: return "The rules file changed outside Nostromo. Review it in Approval Rules first."
        case .ruleLimit: return "There are 200 rules already. Remove one in Approval Rules first."
        case .invalidRule: return "That rule is not one of this request's choices."
        default: return nil
        }
    }

    // MARK: Rules list

    /// The quarantine banner.
    public static let quarantineBanner =
        "Rules file changed outside Nostromo; rules are off until you review them"

    /// What the banner's reason means, for the review.
    public static func quarantineReasonText(_ reason: String) -> String {
        switch reason {
        case "external_change": return "The file was edited while Nostromo was running."
        case "hash_mismatch": return "The file does not match the hash Nostromo recorded."
        case "parse_error": return "The file is not valid rules JSON."
        case "unsupported_version": return "The file has a version this Nostromo does not know."
        case "bad_mode": return "The file is readable by other users."
        case "symlink": return "The file is a symbolic link."
        case "too_large", "too_many_rules": return "The file is larger than Nostromo allows."
        case "duplicate_ids": return "Two rules in the file share an id."
        default: return "The file failed Nostromo's checks."
        }
    }

    /// `Remove` label for VoiceOver.
    public static func removeAccessibilityLabel(_ rule: PersistedRule) -> String { "Remove rule \(rule.ruleText)" }

    /// `This repository: ~/Code/x` or `All repositories`
    public static func scopeText(_ rule: PersistedRule, home: String) -> String {
        switch rule.scope {
        case .allRepos: return "All repositories"
        case .repo:
            let root = rule.root.map { ApprovalKinds.homeAbbreviated($0, home: home) } ?? "unknown folder"
            return "Repository: \(root)"
        }
    }

    /// `created 2:47 pm`, in `timeZone`, with the day when it is not `now`'s.
    public static func createdText(atMs: UInt64, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return "created \(formatter.string(from: date).lowercased())"
    }

    /// `used 3 times`
    public static func usesText(_ uses: UInt64) -> String { "used \(uses) \(uses == 1 ? "time" : "times")" }

    /// `active`, or `inactive: …` with the reason in words.
    public static func stateText(_ rule: PersistedRule) -> String {
        guard !rule.active else { return "active" }
        return "inactive: " + inactiveReasonText(rule.inactiveReason)
    }

    public static func inactiveReasonText(_ reason: String?) -> String {
        switch reason {
        case "no_longer_offered": return "Nostromo no longer offers this rule"
        case "path_changed": return "a path it covers has changed"
        default: return "it did not pass Nostromo's checks"
        }
    }

    /// The row's detail line: `Repository: ~/Code/x · created 2:47 pm · used 3 times · active`
    public static func detailText(_ rule: PersistedRule, home: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        [scopeText(rule, home: home), createdText(atMs: rule.createdAtMs, now: now, timeZone: timeZone),
         usesText(rule.uses), stateText(rule)].joined(separator: " · ")
    }

    /// How a quarantined rule reads in the review: whether it would stay on after Keep.
    public static func reviewText(_ rule: PersistedRule) -> String {
        rule.active ? "would stay active" : "would stay inactive: " + inactiveReasonText(rule.inactiveReason)
    }
}
