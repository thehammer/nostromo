import Foundation

// What the My open PRs Overview says, as pure functions of a snapshot, a clock and a time zone.
// Grouping and order are the daemon's: nothing here re-derives them, it only words, limits and labels them.

/// The header: the count, each source's freshness in words, and what refresh may do.
public struct AuthoredPrsHeaderModel: Equatable, Sendable {
    /// `My open PRs · 14`, or `My open PRs · 3 of 14` while a filter is on.
    public var countText: String
    /// The number in `countText`: every open PR, whatever the filter shows.
    public var count: Int
    /// `live`, `catching up…`, …
    public var carefeed: String
    /// `checked 40s ago`, `paused: GitHub rate limit low, resumes 3:40 pm`, …
    public var otherRepos: String
    /// `Carefeed: live · Other repos: checked 40s ago`.
    public var freshness: String
    /// `Showing the 100 most recently updated of 134`, only when the daemon capped the list.
    public var showing: String?
    /// `as of 3:12 pm` while the daemon is limited, paused or cannot reach GitHub: the rows are older than they look.
    public var asOf: String?
    /// Why ⟳ and ⌘R are off; nil when a refresh may be asked for.
    public var refreshDisabledReason: String?
    public var refreshEnabled: Bool { refreshDisabledReason == nil }
}

public enum AuthoredPrsBody: Equatable, Sendable {
    /// GitHub is not connected: no list.
    case notConnected(rejected: Bool)
    case empty
    case list
}

public struct AuthoredPrRowModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var number: Int
    public var repo: String
    public var url: String
    /// `✓`, `✗`, `●`, `–` (and `◆` / `○` for merged and closed).
    public var statusGlyph: String
    /// `passing`, `failing`, `pending`, `no checks`, `Merged`, `Closed`.
    public var statusWord: String
    public var statusKind: StatusKind
    public var numberText: String
    public var title: String
    public var repoChip: String
    public var age: String
    public var checksLine: String
    public var checksTooltip: String?
    public var reviewLine: String
    public var base: String?
    public var isDraft: Bool
    public var ownerPrefix: String
    /// The Mother job id the owner text links to (selects that job in the list).
    public var ownerJobId: String?
    public var ownerSuffix: String
    public var detailsUnavailable: Bool
    public var lifecycle: AuthoredPrLifecycle
    public var accessibilityLabel: String
    public var ownerKind: AuthoredPrOwnerKind = .unknown
    public var ownerTag: String?
    public var ownerName: String?
    public var ownerCandidates: [AuthoredPrCandidate] = []
    /// The hand-off button, only on a fixable row and only when the daemon can hand off.
    public var tellButton: AuthoredPrTellButton?
    /// `Told Cody 1m ago`, when someone was told and the daemon can hand off.
    public var toldText: String?
    /// The first 8 hex digits of the PR's head commit, when the daemon sends it. A merge carries this row's own.
    public var headShaShort: String?
    /// Perri's verdict, only when the daemon advertises `authored_prs_perri_v1` and there is one worth showing.
    public var perriBadge: AuthoredPrPerriBadge?
    /// The Merge button, only on an open READY row and only when the daemon can both report Perri's verdict and merge.
    public var mergeButton: AuthoredPrMergeButton?
    /// Why the last attempt to merge this row failed, until dismissed or the row changes.
    public var mergeNotice: String?

    public enum StatusKind: Equatable, Sendable { case passing, failing, pending, none, merged, closed }

    /// The owner text as one string, `Mother job a1b2c3 · Cody`, with `details unavailable` when flagged.
    public var ownerText: String {
        var text = ownerPrefix + (ownerJobId ?? "") + ownerSuffix
        if detailsUnavailable { text += " · details unavailable" }
        return text
    }
}

/// The button on a fixable row: what it says, how VoiceOver names it, and what it leads to.
public struct AuthoredPrTellButton: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Preview the message for the owner focus `tag`.
        case tell(tag: String)
        /// The owner is unknown or ambiguous: pick a focus.
        case choose
        /// The owner is closed: start a session.
        case start
    }
    public var action: Action
    public var title: String
    public var accessibilityLabel: String
}

public struct AuthoredPrsGroupModel: Equatable, Sendable, Identifiable {
    public var group: AuthoredPrGroup
    /// `NEEDS YOU`.
    public var title: String
    /// Every row in the group, shown or not (with a filter on, every row that matches it).
    public var count: Int
    /// The group's size before a filter; nil when none is on.
    public var unfilteredCount: Int? = nil
    public var rows: [AuthoredPrRowModel]
    /// Rows past the cap, behind `Show N more`.
    public var hiddenCount: Int
    public var id: AuthoredPrGroup { group }
    public var showMoreTitle: String? { hiddenCount > 0 ? "Show \(hiddenCount) more" : nil }
    /// `3`, or `2 of 3` while a filter is on.
    public var countText: String { unfilteredCount.map { "\(count) of \($0)" } ?? "\(count)" }
    /// `Needs you, 3`, as VoiceOver reads the heading.
    public var accessibilityLabel: String { "\(title.prefix(1))\(title.dropFirst().lowercased()), \(countText)" }
}

public enum AuthoredPrsPresentation {
    /// How long a merged or closed row stays after the daemon says it ended.
    public static let lingerSeconds: TimeInterval = 60
    /// Rows a group shows before `Show N more`.
    public static let groupRowLimit = 25

    // MARK: Times

    public static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date).lowercased()
    }

    /// `40s`, `5m`, `2h`, `3d`.
    public static func age(from date: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    private static func interval(_ secs: Int) -> String {
        if secs < 60 { return "\(max(secs, 1))s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    // MARK: Header

    /// `matchedOpen` is the open PRs a filter lets through, nil when none is on. The model's `count` is always the total.
    public static func header(_ snapshot: AuthoredPrsSnapshot, now: Date, timeZone: TimeZone,
                              matchedOpen: Int? = nil) -> AuthoredPrsHeaderModel {
        let count = snapshot.prs.filter { $0.lifecycle == .open }.count
        let carefeed = carefeedWords(snapshot, timeZone: timeZone)
        let others = otherReposWords(snapshot.poll, now: now, timeZone: timeZone)
        var showing: String?
        if snapshot.totalOpen > snapshot.shown, snapshot.shown > 0 {
            showing = "Showing the \(snapshot.shown) most recently updated of \(snapshot.totalOpen)"
        }
        var asOf: String?
        switch snapshot.poll.state {
        case .rateLimited, .paused, .error:
            if let at = snapshot.poll.checkedAt ?? snapshot.generatedAt { asOf = "as of \(clock(at, timeZone: timeZone))" }
        default: break
        }
        var blocked: String?
        switch snapshot.refreshBlocked {
        case .running: blocked = "A refresh is already running"
        case .rateLimited: blocked = "Paused: GitHub rate limit low"
        case .unknown: blocked = "Refresh is not available right now"
        case nil: break
        }
        return AuthoredPrsHeaderModel(
            countText: "My open PRs · \(matchedOpen.map { "\($0) of \(count)" } ?? "\(count)")", count: count, carefeed: carefeed, otherRepos: others,
            freshness: "Carefeed: \(carefeed) · Other repos: \(others)",
            showing: showing, asOf: asOf, refreshDisabledReason: blocked)
    }

    /// `live` only ever for a relay the daemon reports `live`.
    static func carefeedWords(_ s: AuthoredPrsSnapshot, timeZone: TimeZone) -> String {
        let every = interval(s.poll.intervalSecs)
        switch s.relay.state {
        case .live: return "live"
        case .catchingUp: return "catching up…"
        case .offline:
            if let since = s.relay.since { return "relay offline since \(clock(since, timeZone: timeZone)) · polling every \(every)" }
            return "relay offline · polling every \(every)"
        case .notConfigured: return "polling every \(every)"
        case .unknown: return "status unknown"
        }
    }

    /// Ages come from the daemon's `checked_at`, never from when the frame arrived.
    static func otherReposWords(_ poll: AuthoredPrsPoll, now: Date, timeZone: TimeZone) -> String {
        switch poll.state {
        case .checking: return "checking…"
        case .ok, .idle:
            guard let at = poll.checkedAt else { return "not checked yet" }
            return "checked \(age(from: at, now: now)) ago"
        case .rateLimited, .paused:
            if let resumes = poll.resumesAt { return "paused: GitHub rate limit low, resumes \(clock(resumes, timeZone: timeZone))" }
            if poll.state == .paused { return "paused: GitHub rate limit low" }
            return "rate limit low · checking every \(interval(poll.intervalSecs))"
        case .error:
            if let retry = poll.retryAt { return "couldn't reach GitHub, retrying in \(interval(max(0, Int(retry.timeIntervalSince(now)))))" }
            return "couldn't reach GitHub, retrying"
        case .unknown: return "status unknown"
        }
    }

    // MARK: Body states

    public static func body(_ snapshot: AuthoredPrsSnapshot) -> AuthoredPrsBody {
        switch snapshot.token {
        case .missing: return .notConnected(rejected: false)
        case .rejected: return .notConnected(rejected: true)
        case .connected, .unknown: break
        }
        return snapshot.prs.isEmpty ? .empty : .list
    }

    public static let emptyText = "No open PRs authored by you. PRs you open in any repo show up here."
    public static let notConnectedTitle = "Connect GitHub to see your PRs"
    public static let notConnectedDetail = "Run `gh auth login` in a terminal, then wait a minute."
    public static let reconnectingText = "reconnecting to Nostromo…"

    public static func hiddenOrgsNote(_ snapshot: AuthoredPrsSnapshot) -> String? {
        guard !snapshot.hiddenOrgs.isEmpty else { return nil }
        return "Some repos hidden: GitHub denied access to org \(snapshot.hiddenOrgs.joined(separator: ", "))."
    }

    // MARK: Lifecycle

    /// A merged or closed row goes this long after the daemon says it ended.
    public static func isExpired(_ pr: AuthoredPr, now: Date) -> Bool {
        guard pr.lifecycle != .open, let ended = pr.endedAt else { return false }
        return now >= ended.addingTimeInterval(lingerSeconds)
    }

    // MARK: Groups and rows

    /// `unfiltered` is every PR before a filter chose `prs`: it gives each group its size before the filter and
    /// keeps a repo chip's wording from changing when the filter hides the repo it shared a name with.
    public static func groups(_ prs: [AuthoredPr], unfiltered: [AuthoredPr]? = nil, showAll: Set<AuthoredPrGroup> = [],
                              now: Date, timeZone: TimeZone, handoff: Bool = false,
                              tellable: Set<String>? = nil, perri: Bool = false, merge: Bool = false,
                              mergeQueue: Bool = false,
                              mergeAttempts: [String: AuthoredPrMergeAttempt] = [:]) -> [AuthoredPrsGroupModel] {
        let chips = repoChips(unfiltered ?? prs)
        return AuthoredPrGroup.displayOrder.compactMap { group in
            let members = prs.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let limit = showAll.contains(group) ? members.count : groupRowLimit
            let shown = members.prefix(limit)
            return AuthoredPrsGroupModel(
                group: group, title: groupTitle(group), count: members.count,
                unfilteredCount: unfiltered.map { all in all.filter { $0.group == group }.count },
                rows: shown.map {
                    row($0, chip: chips[$0.repo] ?? $0.repo, now: now, handoff: handoff, tellable: tellable,
                        perri: perri, merge: merge, mergeQueue: mergeQueue, mergeAttempt: mergeAttempts[$0.id])
                },
                hiddenCount: members.count - shown.count)
        }
    }

    public static func groupTitle(_ group: AuthoredPrGroup) -> String {
        switch group {
        case .needsYou: return "NEEDS YOU"
        case .ready: return "READY"
        case .waiting: return "WAITING ON OTHERS"
        case .draft: return "DRAFTS"
        case .unknown: return "OTHER"
        }
    }

    /// The repo name without its owner, unless two shown repos share a name: then `owner/name`.
    public static func repoChips(_ prs: [AuthoredPr]) -> [String: String] {
        let repos = Set(prs.map(\.repo))
        func name(_ r: String) -> String { r.split(separator: "/", maxSplits: 1).last.map(String.init) ?? r }
        var counts: [String: Int] = [:]
        for r in repos { counts[name(r), default: 0] += 1 }
        var chips: [String: String] = [:]
        for r in repos { chips[r] = (counts[name(r)] ?? 0) > 1 ? r : name(r) }
        return chips
    }

    /// `tellable` is the tags of the open focuses the daemon would let a notice go to (nil: not restricted). A
    /// row whose owner is not among them gets no Tell button: the daemon would refuse it.
    ///
    /// `perri` and `merge` are the daemon's `authored_prs_perri_v1` and `authored_prs_merge_v1`: the badge needs
    /// the first, the Merge button needs both (without Perri's verdict on rows it could never be enabled).
    /// `mergeAttempt` is the person's last attempt on this row, if any.
    public static func row(_ pr: AuthoredPr, chip: String? = nil, now: Date, handoff: Bool = false,
                           tellable: Set<String>? = nil, perri: Bool = false, merge: Bool = false,
                           mergeQueue: Bool = false,
                           mergeAttempt: AuthoredPrMergeAttempt? = nil) -> AuthoredPrRowModel {
        let chipText = chip ?? repoChips([pr])[pr.repo] ?? pr.repo
        let (kind, glyph, word) = status(pr)
        let checks = checksLine(pr.checks)
        let owner = ownerParts(pr.owner)
        var model = AuthoredPrRowModel(
            id: pr.id, number: pr.number, repo: pr.repo, url: pr.url,
            statusGlyph: glyph, statusWord: word, statusKind: kind,
            numberText: "#\(pr.number)", title: pr.title, repoChip: chipText,
            age: pr.updatedAt.map { age(from: $0, now: now) } ?? "",
            checksLine: checks.line, checksTooltip: checks.tooltip, reviewLine: reviewLine(pr),
            base: shownBase(pr.baseRef), isDraft: pr.draft,
            ownerPrefix: owner.prefix, ownerJobId: owner.jobId, ownerSuffix: owner.suffix,
            detailsUnavailable: pr.detailsUnavailable, lifecycle: pr.lifecycle, accessibilityLabel: "")
        model.accessibilityLabel = accessibilityLabel(pr, chip: chipText)
        model.ownerKind = pr.owner.kind
        model.ownerTag = pr.owner.tag
        model.ownerName = pr.owner.name
        model.ownerCandidates = pr.owner.candidates
        if handoff {
            model.tellButton = tellButton(pr, tellable: tellable)
            model.toldText = toldText(pr.told, now: now)
            if let told = model.toldText { model.accessibilityLabel += ", \(told)" }
        }
        model.headShaShort = pr.headShaShort
        if perri, let badge = perriBadge(pr, now: now) {
            model.perriBadge = badge
            model.accessibilityLabel += ", \(badge.accessibilityLabel)"
        }
        if perri, merge {
            model.mergeButton = mergeButton(pr, attempt: mergeAttempt, queueSupported: mergeQueue)
            if let reason = model.mergeButton?.reason { model.reviewLine += " · \(reason)" }
            model.mergeNotice = mergeNotice(pr, attempt: mergeAttempt)
            if let notice = model.mergeNotice { model.accessibilityLabel += ", merge failed: \(notice)" }
        }
        return model
    }

    // MARK: Merge

    /// Whether the Merge button is enabled for a row, and if not, the first reason it is not.
    /// The cases are in the order the reasons are weighed, apart from `mergedOrClosed`, which is first in
    /// the checks: a PR that is no longer open has nothing else worth saying.
    public enum MergeReadiness: Equatable, Sendable {
        case ready
        case draft
        case checksNotGreen
        /// No human reviewer has approved (none yet, changes requested, or only requested).
        case humanApprovalMissing
        case perriNotApproved(PerriBlock)
        case mergedOrClosed
        /// The row says the PR goes in through a merge queue, and this daemon connection did not advertise
        /// `authored_prs_merge_queue_v1`: pressing Merge would say "squash and merge" about something else.
        case queueNeedsUpdate
        /// The daemon says how the PR goes in with a value this build does not know, or (on a daemon that knows
        /// merge queues) did not say at all: the confirmation could not be worded truthfully.
        case mergeMethodUnknown

        /// How Perri has not approved the PR's current head.
        public enum PerriBlock: Equatable, Sendable {
            /// No verdict, or one that is not an approval (a comment).
            case none
            /// The verdict is for an older version: a push came after it.
            case olderVersion
            case changesRequested
        }

        public var isReady: Bool { self == .ready }
    }

    /// The daemon enforces every one of these again when it merges; this only says whether to offer the button.
    /// Merge needs an open PR that is not a draft, whose checks are passing (or there are none), that a human
    /// approved, and that Perri approved at the head the row shows (`headShaShort`).
    ///
    /// `queueSupported` is whether the daemon advertised `authored_prs_merge_queue_v1`. Without it a row that says
    /// `queue` is never ready ("Update Nostromo to merge into a merge queue"); with it, a row that says nothing
    /// about how it goes in is not ready either, because the confirmation could not be worded.
    public static func mergeReadiness(_ pr: AuthoredPr, queueSupported: Bool = false) -> MergeReadiness {
        if pr.lifecycle != .open { return .mergedOrClosed }
        if pr.draft { return .draft }
        switch pr.checks.state {
        case .passing, .none: break
        case .failing, .pending, .unknown: return .checksNotGreen
        }
        if pr.review.state != .approved { return .humanApprovalMissing }
        guard let perri = pr.perri else { return .perriNotApproved(.none) }
        if !perri.forCurrentHead { return .perriNotApproved(.olderVersion) }
        switch perri.verdict {
        case .approved:
            // Without the head there is nothing to echo, so nothing to merge.
            if pr.headShaShort == nil { return .perriNotApproved(.none) }
            switch pr.mergeVia {
            case .direct?: return .ready
            case .queue?: return queueSupported ? .ready : .queueNeedsUpdate
            case .unknown?: return .mergeMethodUnknown
            case nil: return queueSupported ? .mergeMethodUnknown : .ready
            }
        case .changesRequested: return .perriNotApproved(.changesRequested)
        case .comment, .unknown: return .perriNotApproved(.none)
        }
    }

    // MARK: Hand-off

    /// A PR the user can hand to an agent: open, not a draft, in Needs you, and something to fix.
    public static func isFixable(_ pr: AuthoredPr) -> Bool {
        pr.lifecycle == .open && !pr.draft && pr.group == .needsYou
            && (pr.checks.failed > 0 || pr.review.state == .changesRequested
                || pr.newComments > 0 || pr.unresolvedThreads > 0)
    }

    /// The first word of a focus name: `Cody in Nostromo` is `Cody`.
    public static func firstWord(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? name
    }

    /// The button for a fixable row, worded from its owner; nil when there is nothing to fix.
    public static func tellButton(_ pr: AuthoredPr, tellable: Set<String>? = nil) -> AuthoredPrTellButton? {
        guard isFixable(pr) else { return nil }
        let n = pr.number
        switch pr.owner.kind {
        case .motherJob, .linked, .onBranch:
            if let tag = pr.owner.tag, !tag.isEmpty {
                if let tellable, !tellable.contains(tag) { return nil }
                let first = firstWord(pr.owner.name ?? "")
                let who = first.isEmpty ? "focus" : first
                return AuthoredPrTellButton(action: .tell(tag: tag), title: "Tell \(who)",
                                            accessibilityLabel: "Tell \(who) about PR \(n)")
            }
            return AuthoredPrTellButton(action: .choose, title: "Choose focus…", accessibilityLabel: "Choose focus for PR \(n)")
        case .ambiguous, .unknown:
            return AuthoredPrTellButton(action: .choose, title: "Choose focus…", accessibilityLabel: "Choose focus for PR \(n)")
        case .closed:
            return AuthoredPrTellButton(action: .start, title: "Start a session…", accessibilityLabel: "Start a session for PR \(n)")
        }
    }

    /// `Told Cody 1m ago`; nil when nobody was told.
    public static func toldText(_ told: AuthoredPrTold?, now: Date) -> String? {
        guard let told, let at = told.at else { return nil }
        let first = firstWord(told.name)
        return "Told \(first.isEmpty ? "a focus" : first) \(age(from: at, now: now)) ago"
    }

    /// `1m ago`, `never`: the line in the preview.
    public static func lastToldLine(_ last: AuthoredPrLastTold?, now: Date) -> String {
        guard let last, let at = last.at else { return "Last told: never" }
        let first = firstWord(last.name)
        return "Last told: \(age(from: at, now: now)) ago" + (first.isEmpty ? "" : " (\(first))")
    }

    static func status(_ pr: AuthoredPr) -> (AuthoredPrRowModel.StatusKind, String, String) {
        switch pr.lifecycle {
        case .merged: return (.merged, "◆", "Merged")
        case .closed: return (.closed, "○", "Closed")
        case .open, .unknown: break
        }
        switch pr.checks.state {
        case .passing: return (.passing, "✓", "passing")
        case .failing: return (.failing, "✗", "failing")
        case .pending: return (.pending, "●", "pending")
        case .none, .unknown: return (.none, "–", "no checks")
        }
    }

    /// `Checks: 1 failed (swift-tests) · 9 passed`; up to 3 failing names, then `+2 more`.
    static func checksLine(_ c: AuthoredPrChecks) -> (line: String, tooltip: String?) {
        var parts: [String] = []
        if c.failed > 0 {
            var text = "\(c.failed) failed"
            if !c.failingNames.isEmpty {
                var names = Array(c.failingNames.prefix(3))
                let more = c.failed - names.count
                if more > 0 { names.append("+\(more) more") }
                text += " (\(names.joined(separator: ", ")))"
            }
            parts.append(text)
        }
        if c.pending > 0 { parts.append("\(c.pending) pending") }
        if c.passed > 0 { parts.append("\(c.passed) passed") }
        let line = parts.isEmpty ? "Checks: none" : "Checks: " + parts.joined(separator: " · ")
        let tooltip = c.failingNames.isEmpty ? nil : "Failing checks:\n" + c.failingNames.joined(separator: "\n")
        return (line, tooltip)
    }

    /// Exactly one review state, then the counts when non-zero.
    static func reviewLine(_ pr: AuthoredPr) -> String {
        let who = pr.review.logins.joined(separator: ", ")
        var text: String
        switch pr.review.state {
        case .approved: text = who.isEmpty ? "Approved" : "Approved by \(who)"
        case .changesRequested: text = who.isEmpty ? "Changes requested" : "Changes requested by \(who)"
        case .reviewRequested: text = who.isEmpty ? "Review requested" : "Review requested from \(who)"
        case .none, .unknown: text = "No review yet"
        }
        if pr.newComments > 0 { text += " · \(commentCount(pr.newComments)) new comment\(pr.newComments == 1 ? "" : "s")" }
        if pr.unresolvedThreads > 0 { text += " · \(pr.unresolvedThreads)\(pr.threadsTruncated ? "+" : "") unresolved" }
        return text
    }

    /// The count capped by the daemon at 999 is shown `999+`: there may be more.
    static func commentCount(_ n: Int) -> String {
        n >= Int(AuthoredPrsBounds.newComments) ? "\(n)+" : "\(n)"
    }

    /// The base branch worth a chip: anything but `main` (any case). `main` is the norm and not worth saying.
    static func shownBase(_ base: String?) -> String? {
        guard let base, base.caseInsensitiveCompare("main") != .orderedSame else { return nil }
        return base
    }

    static func ownerParts(_ o: AuthoredPrOwner) -> (prefix: String, jobId: String?, suffix: String) {
        let name = o.name ?? ""
        switch o.kind {
        case .motherJob:
            if let job = o.jobId, !job.isEmpty { return ("Mother job ", job, name.isEmpty ? "" : " · \(name)") }
            return (name.isEmpty ? "Mother job" : "Mother job · \(name)", nil, "")
        case .onBranch: return (name.isEmpty ? "On branch" : "On branch in \(name)", nil, "")
        case .linked: return (name.isEmpty ? "Linked" : "Linked to \(name)", nil, "")
        case .ambiguous: return ("\(o.candidates.count) possible focuses", nil, "")
        case .closed: return (name.isEmpty ? "Closed" : "\(name) · closed", nil, "")
        case .unknown: return ("Owner unknown", nil, "")
        }
    }

    /// One string per row: "PR 458, Slash commands 1, nostromo, checks failing: swift-tests, …".
    static func accessibilityLabel(_ pr: AuthoredPr, chip: String) -> String {
        var parts = ["PR \(pr.number)", pr.title, chip]
        switch pr.lifecycle {
        case .merged: parts.append("merged")
        case .closed: parts.append("closed")
        case .open, .unknown: break
        }
        if pr.draft { parts.append("draft") }
        switch pr.checks.state {
        case .failing:
            let names = pr.checks.failingNames
            var spoken = Array(names.prefix(3))
            if names.count > 3 { spoken.append("and \(names.count - 3) more") }
            parts.append(spoken.isEmpty ? "checks failing" : "checks failing: \(spoken.joined(separator: ", "))")
        case .passing: parts.append("checks passing")
        case .pending: parts.append("checks pending")
        case .none, .unknown: parts.append("no checks")
        }
        let who = pr.review.logins.joined(separator: ", ")
        switch pr.review.state {
        case .approved: parts.append(who.isEmpty ? "approved" : "approved by \(who)")
        case .changesRequested: parts.append(who.isEmpty ? "changes requested" : "changes requested by \(who)")
        case .reviewRequested: parts.append(who.isEmpty ? "review requested" : "review requested from \(who)")
        case .none, .unknown: parts.append("no review yet")
        }
        if pr.newComments > 0 { parts.append("\(commentCount(pr.newComments)) new comment\(pr.newComments == 1 ? "" : "s")") }
        if pr.unresolvedThreads > 0 { parts.append("\(pr.unresolvedThreads) unresolved thread\(pr.unresolvedThreads == 1 ? "" : "s")") }
        if let base = shownBase(pr.baseRef) { parts.append("base \(base)") }
        let name = pr.owner.name ?? ""
        switch pr.owner.kind {
        case .motherJob: parts.append(name.isEmpty ? "owner Mother job" : "owner \(name), Mother job")
        case .onBranch: parts.append(name.isEmpty ? "owner on branch" : "owner \(name), on branch")
        case .linked: parts.append(name.isEmpty ? "owner linked" : "owner \(name), linked")
        case .ambiguous: parts.append("\(pr.owner.candidates.count) possible owners")
        case .closed: parts.append(name.isEmpty ? "owner closed" : "owner \(name), closed")
        case .unknown: parts.append("owner unknown")
        }
        if pr.detailsUnavailable { parts.append("details unavailable") }
        return parts.joined(separator: ", ")
    }

    // MARK: Debug

    /// Counts only: no titles, repos or logins.
    public static func usageReport(_ u: AuthoredPrsUsage) -> String {
        func block(_ c: AuthoredPrsUsageCounts) -> [String] {
            ["charged: \(c.charged)", "not modified: \(c.notModified)", "search: \(c.search)",
             "graphql points: \(c.graphqlPoints)", "relay charged: \(c.relayCharged)",
             "visible charged: \(c.visibleCharged)", "hidden charged: \(c.hiddenCharged)"]
        }
        return (["GitHub usage, last \(max(u.windowSecs / 60, 0)) min"] + block(u.window)
                + ["GitHub usage, since the daemon started"] + block(u.sinceStart)).joined(separator: "\n")
    }
}
