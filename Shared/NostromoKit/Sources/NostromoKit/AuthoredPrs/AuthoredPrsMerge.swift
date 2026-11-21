import Foundation

// What the PR Overview says about Perri's verdict and the Merge button, as pure functions of a row, a clock and
// the attempt the person made. The daemon enforces every rule again when it merges: this only decides what to
// offer and how to word it. Nothing here sends anything.

// MARK: - Who recorded a verdict

/// Who the daemon says recorded a verdict. The daemon writes `by` as `<agent>:<tag>` and any registered focus
/// may record one, so the badge and the confirmation say "Perri" only for an agent that is `perri`. The record
/// shows who, it does not prove who: a process on the operator's account can claim another focus's tag.
public enum AuthoredPrVerdictRecorder: Equatable, Sendable {
    case perri
    /// Another agent. `by` is the whole sanitised value, `agent` its agent part.
    case agent(String, by: String)
    /// Absent, not `<agent>:<tag>`, or altered by sanitising: nobody's name.
    case unknown
}

extension AuthoredPrPerri {
    /// The longest agent name read as a name.
    static let agentNameLimit = 40

    public var recorder: AuthoredPrVerdictRecorder {
        guard !byWasAltered, let by, let colon = by.firstIndex(of: ":") else { return .unknown }
        let agent = by[..<colon]
        let tag = by[by.index(after: colon)...]
        let plain = agent.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7a)
                || ($0.value >= 0x41 && $0.value <= 0x5a) || $0 == "-" || $0 == "_" || $0 == "."
        }
        guard plain, !agent.isEmpty, agent.count <= Self.agentNameLimit, !tag.isEmpty else { return .unknown }
        return agent == "perri" ? .perri : .agent(String(agent), by: by)
    }
}

// MARK: - Perri's badge

/// `Perri ✓`, `Perri ✓ older`, `Perri ✗` or `Perri comments`: the verdict on an open PR, never by colour alone.
public struct AuthoredPrPerriBadge: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case approved, olderApproval, changesRequested, comments }
    public var kind: Kind
    /// What the badge says, glyph included.
    public var text: String
    public var tooltip: String
    public var accessibilityLabel: String
    /// True only for an approval of an older version: it is not an approval of this one, so it is quieter.
    public var isMuted: Bool
}

// MARK: - Merge button

/// What one attempt to merge a row has come to. `head` is the head short sha of the row the person saw.
public enum AuthoredPrMergeProgress: Equatable, Sendable {
    case merging
    case merged
    /// The daemon answered `queued` (or `already_queued`): the PR is in the merge queue, not merged. Never moves the
    /// row to another group: only a later snapshot does.
    case queued
    case failed(AuthoredPrMergeCode)
}

public struct AuthoredPrMergeAttempt: Equatable, Sendable {
    public var head: String
    public var progress: AuthoredPrMergeProgress
    /// A snapshot has shown this PR with its queue entry since it was queued. Only then does a row without an entry
    /// mean "dropped": the first snapshot after the answer may not have the entry yet.
    public var sawQueueEntry: Bool
    public init(head: String, progress: AuthoredPrMergeProgress, sawQueueEntry: Bool = false) {
        self.head = head
        self.progress = progress
        self.sawQueueEntry = sawQueueEntry
    }
}

/// The one-step confirmation: what will happen, for the row as the person saw it. The request carries
/// `expectedHeadShaShort`, the head in this very text, never a newer one.
public struct AuthoredPrMergeConfirmation: Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var expectedHeadShaShort: String
    /// The branch the sentence says it merges into (nil: it says "the base branch"). A retarget while the
    /// confirmation is open makes the sentence untrue, though the head has not moved.
    public var base: String?
    public var message: String
    /// How the sentence says the PR goes in. A row that changes it while the confirmation is open makes the sentence
    /// untrue, though the head has not moved.
    public var via: AuthoredPrMergeVia = .direct
    /// Who approved, as the sentence says it ("Perri approved." / "Approval recorded by X, not by Perri."): the same
    /// head can be re-recorded by another focus while the confirmation is open, which makes the sentence untrue.
    public var approval: String = ""
    public var confirmTitle: String { via == .queue ? "Add to merge queue" : "Merge" }
    public var cancelTitle: String { "Cancel" }
}

public struct AuthoredPrMergeButton: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Every rule holds: pressing it leads to the confirmation.
        case ready
        /// Shown but off; `reason` says why.
        case unavailable
        case merging
        case merged
        /// In the merge queue (from the daemon's row, or the answer `queued`): nothing to press.
        case queued
    }
    public var state: State
    public var title: String
    public var isEnabled: Bool { state == .ready }
    /// Only when `.unavailable`.
    public var reason: String?
    public var tooltip: String
    public var accessibilityLabel: String
    /// Only when `.ready`: nothing that is not ready can lead to a merge.
    public var confirmation: AuthoredPrMergeConfirmation?
}

// MARK: - Rules

extension AuthoredPrsPresentation {

    /// The most of a PR's title the confirmation says.
    static let confirmationTitleLimit = 80

    // MARK: Badge

    /// Perri's verdict on `pr` as a badge; nil when there is none worth showing (no verdict, one this build does not
    /// know, a non-approval of an older version, or a PR that is not open).
    public static func perriBadge(_ pr: AuthoredPr, now: Date) -> AuthoredPrPerriBadge? {
        guard pr.lifecycle == .open, let perri = pr.perri else { return nil }
        let when = perri.at.map { " \(age(from: $0, now: now)) ago" } ?? ""
        let recorder = perri.recorder
        let who = perri.by.map { " by \($0)" } ?? " (recorder unknown)"
        let head = pr.headShaShort.map { " · head \($0)" } ?? ""
        func tip(_ verb: String) -> String { verb + when + who + head }
        /// ` (by cody)` or ` (recorder unknown)` after the words of a badge recorded by anyone but Perri.
        let credit: String
        /// What follows a spoken stem for the same: `Approval of this version` + this.
        let spokenCredit: String
        switch recorder {
        case .perri:
            credit = ""; spokenCredit = ""
        case .agent(let agent, _):
            let shown = agent.count > 16 ? String(agent.prefix(16)) + "…" : agent
            credit = " (by \(shown))"; spokenCredit = " recorded by \(shown), not by Perri"
        case .unknown:
            credit = " (recorder unknown)"; spokenCredit = ", recorder unknown"
        }
        let byPerri = recorder == .perri
        switch (perri.verdict, perri.forCurrentHead) {
        case (.approved, true):
            return AuthoredPrPerriBadge(
                kind: .approved, text: "Perri ✓" + credit, tooltip: tip("Approved"),
                accessibilityLabel: byPerri ? "Perri approved this version" : "Approval of this version" + spokenCredit,
                isMuted: false)
        case (.approved, false):
            return AuthoredPrPerriBadge(
                kind: .olderApproval, text: "Perri ✓ older" + credit,
                tooltip: "Approved" + when + who + " for an older version of this PR. A new push needs a new review.",
                accessibilityLabel: byPerri ? "Perri approved an older version" : "Approval of an older version" + spokenCredit,
                isMuted: true)
        case (.changesRequested, true):
            return AuthoredPrPerriBadge(
                kind: .changesRequested, text: "Perri ✗" + credit, tooltip: tip("Changes requested"),
                accessibilityLabel: byPerri ? "Perri requested changes" : "Changes requested" + spokenCredit,
                isMuted: false)
        case (.comment, true):
            return AuthoredPrPerriBadge(
                kind: .comments, text: "Perri comments" + credit, tooltip: tip("Commented"),
                accessibilityLabel: byPerri ? "Perri left comments" : "Comments" + spokenCredit, isMuted: false)
        default:
            return nil
        }
    }

    // MARK: Button

    /// The Merge button of a READY-group open row, enabled only when `mergeReadiness` says `.ready`; nil elsewhere.
    /// `attempt` overlays the button while a merge is running or done; a failed attempt does not change it (the
    /// failure is a notice, see `mergeNotice`).
    public static func mergeButton(_ pr: AuthoredPr, attempt: AuthoredPrMergeAttempt? = nil,
                                   queueSupported: Bool = false) -> AuthoredPrMergeButton? {
        guard pr.lifecycle == .open, pr.group == .ready else { return nil }
        let n = pr.number
        let queued = pr.mergeVia == .queue
        switch attempt?.progress {
        case .merging?:
            return AuthoredPrMergeButton(
                state: .merging, title: queued ? "Adding…" : "Merging…", reason: nil,
                tooltip: queued ? "Adding this PR to the merge queue" : "Merging this PR",
                accessibilityLabel: queued ? "Add PR \(n) to the merge queue, adding" : "Merge PR \(n), merging",
                confirmation: nil)
        case .merged?:
            return AuthoredPrMergeButton(state: .merged, title: "Merged", reason: nil, tooltip: "Merged",
                                         accessibilityLabel: "Merged", confirmation: nil)
        case .queued?:
            return queuedButton(pr)
        case .failed?, nil:
            break
        }
        // The daemon's own row says it is in the queue (put there from here, or from GitHub): nothing to press.
        if queueSupported, pr.queue != nil { return queuedButton(pr) }
        let title = queued ? "Add to merge queue" : "Merge"
        guard let reason = mergeDisabledReason(pr, queueSupported: queueSupported) else {
            return AuthoredPrMergeButton(
                state: .ready, title: title, reason: nil,
                tooltip: queued
                    ? "Add to the merge queue for \(pr.baseRef ?? "the base branch"): GitHub merges it when its turn comes. You will be asked to confirm."
                    : "Squash and merge into \(pr.baseRef ?? "the base branch"). You will be asked to confirm.",
                accessibilityLabel: queued ? "Add PR \(n) to the merge queue" : "Merge PR \(n)",
                confirmation: mergeConfirmation(pr, queueSupported: queueSupported))
        }
        return AuthoredPrMergeButton(state: .unavailable, title: title, reason: reason, tooltip: reason,
                                     accessibilityLabel: "\(queued ? "Add to merge queue" : "Merge"), unavailable: \(reason)",
                                     confirmation: nil)
    }

    /// "In merge queue" (and the position, when GitHub said): the same width as every other state of the button.
    private static func queuedButton(_ pr: AuthoredPr) -> AuthoredPrMergeButton {
        let position = pr.queue?.position
        let title = position.map { "In merge queue (\($0))" } ?? "In merge queue"
        let spoken = position.map { "In merge queue, position \($0)" } ?? "In merge queue"
        return AuthoredPrMergeButton(
            state: .queued, title: title, reason: nil,
            tooltip: "In the merge queue for \(pr.baseRef ?? "the base branch")"
                + (position.map { ", position \($0)" } ?? "") + ". GitHub merges it when its turn comes.",
            accessibilityLabel: "PR \(pr.number): \(spoken)", confirmation: nil)
    }

    /// The attempt after a snapshot that shows `pr` (nil: the row is not in this snapshot, nothing changes). A queued
    /// attempt that has seen its queue entry and now finds none, on a PR that is still open, was dropped from the
    /// queue: it becomes a failure whose notice says so, and the button is available again. An attempt that has not
    /// seen its entry yet keeps waiting: the snapshot may simply be older than the enqueue. A PR that is merged or
    /// closed ends the attempt's story (the row says so itself).
    public static func reconcile(_ attempt: AuthoredPrMergeAttempt, with pr: AuthoredPr) -> AuthoredPrMergeAttempt {
        guard attempt.progress == .queued else { return attempt }
        var next = attempt
        if pr.queue != nil {
            next.sawQueueEntry = true
        } else if attempt.sawQueueEntry, pr.lifecycle == .open {
            next.progress = .failed(.droppedFromQueue)
        }
        return next
    }

    /// Why the Merge button is off, in words; nil when `mergeReadiness` is `.ready`.
    static func mergeDisabledReason(_ pr: AuthoredPr, queueSupported: Bool = false) -> String? {
        switch mergeReadiness(pr, queueSupported: queueSupported) {
        case .ready: return nil
        case .draft: return "Draft"
        case .checksNotGreen: return "Checks not green"
        case .humanApprovalMissing: return "Waiting for human approval"
        case .perriNotApproved(.none): return "Needs Perri's review"
        case .perriNotApproved(.olderVersion):
            // An older approval is the only verdict worth calling "approved": any other one says nothing now.
            return pr.perri?.verdict == .approved ? "Perri approved an older version" : "Needs Perri's review"
        case .perriNotApproved(.changesRequested): return "Perri requested changes"
        case .mergedOrClosed: return "No longer open"
        case .queueNeedsUpdate: return "Update Nostromo to merge into a merge queue"
        case .mergeMethodUnknown: return "Waiting for GitHub to say how this merges"
        }
    }

    /// The confirmation for a row that may be merged now; nil otherwise or without a head to carry.
    static func mergeConfirmation(_ pr: AuthoredPr, queueSupported: Bool = false) -> AuthoredPrMergeConfirmation? {
        guard mergeReadiness(pr, queueSupported: queueSupported) == .ready, let head = pr.headShaShort else { return nil }
        var title = AuthoredPrsText.clean(pr.title, max: Int.max)
        if title.count > confirmationTitleLimit { title = String(title.prefix(confirmationTitleLimit)) + "…" }
        let checks = pr.checks.state == .passing ? "green" : "none"
        let base = pr.baseRef ?? "the base branch"
        let via: AuthoredPrMergeVia = pr.mergeVia == .queue ? .queue : .direct
        let action = via == .queue ? "Add #\(pr.number) \(title) to the merge queue for \(base)?"
            : "Squash and merge #\(pr.number) \(title) into \(base)?"
        let message = "\(action) "
            + "Head \(head). \(approvalSentence(pr.perri)) Human approval: yes. Checks: \(checks)."
        var confirmation = AuthoredPrMergeConfirmation(repo: pr.repo, number: pr.number, expectedHeadShaShort: head,
                                                       base: pr.baseRef, message: message,
                                                       approval: approvalSentence(pr.perri))
        confirmation.via = via
        return confirmation
    }

    /// The most of a recorder's name the confirmation says.
    static let confirmationRecorderLimit = 60

    /// Who approved, in the confirmation. Perri's own is the short form; anyone else's says who, plainly.
    private static func approvalSentence(_ perri: AuthoredPrPerri?) -> String {
        switch perri?.recorder ?? .unknown {
        case .perri:
            return "Perri approved."
        case .agent(_, let by):
            let shown = by.count > confirmationRecorderLimit ? String(by.prefix(confirmationRecorderLimit)) + "…" : by
            return "Approval recorded by \(shown), not by Perri."
        case .unknown:
            return "Approval recorder unknown, not confirmed as Perri."
        }
    }

    // MARK: Notice

    /// The words of a failed attempt, while they are about this row: the PR is open and still at the head the
    /// attempt was made at. `head_changed` is the exception: it is about the head having changed, so it stays
    /// through the change (until the person dismisses it or tries again).
    public static func mergeNotice(_ pr: AuthoredPr, attempt: AuthoredPrMergeAttempt?) -> String? {
        guard pr.lifecycle == .open, case .failed(let code)? = attempt?.progress, let attempt else { return nil }
        guard code == .headChanged || attempt.head == pr.headShaShort else { return nil }
        return AuthoredPrsMergeWords.failure(code)
    }
}
