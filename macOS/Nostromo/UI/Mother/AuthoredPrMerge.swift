import AppKit
import Combine
import NostromoKit
import os

// Merging a PR from the My open PRs Overview: the Merge button's press opens a one-step confirmation, the
// confirm sends ONE request, and the answer becomes the row's notice (or Merged).
//
// Every entry point that acts (the button, the VoiceOver action, Merge in the confirmation) first asks the
// gesture check: input synthesised by the app-control socket, an Accessibility press or a stale event does
// nothing. Nothing here decides whether a PR may be merged: the Kit says whether to offer the button, and the
// daemon enforces every rule again (a human approved, checks are green, Perri approved the exact head the row
// showed). There is exactly one verb, no admin path and no other way to a merge.

private let mergeLog = Logger(subsystem: "com.hammer.nostromo", category: "authored-prs")

// MARK: - Transport

/// What the Merge button needs from the daemon connection. Tests record instead of sending.
protocol AuthoredPrMergeTransport: AnyObject {
    /// The daemon advertised `authored_prs_merge_v1` and is connected.
    var isMergeAvailable: Bool { get }
    /// `expectedVia` is how the confirmation worded it: `.queue` for "add to the merge queue", nil for a squash merge.
    func merge(repo: String, number: Int, expectedHeadShaShort: String, expectedVia: AuthoredPrMergeVia?,
               done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void)
}

// MARK: - Confirmation

/// The confirmation's model: what will happen, and the person's Merge or Cancel.
final class AuthoredPrMergeSession {
    enum Outcome: Equatable {
        case confirmed
        case cancelled
    }

    let confirmation: AuthoredPrMergeConfirmation
    var onFinish: ((Outcome) -> Void)?

    private let permit: AuthoredPrGesture.Permit
    private var finished = false

    init(confirmation: AuthoredPrMergeConfirmation, permit: @escaping AuthoredPrGesture.Permit) {
        self.confirmation = confirmation
        self.permit = permit
    }

    /// Merge, in the confirmation. Does nothing without a person's gesture (the confirmation stays open), and
    /// at most once: a second press, or one after Cancel, does nothing.
    func confirm(event: NSEvent?, control: NSView) {
        guard !finished, permit(event, control, "merge-confirm") else { return }
        finished = true
        onFinish?(.confirmed)
    }

    /// Cancel, Escape, or the popover closing: nothing is sent.
    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish?(.cancelled)
    }
}

// MARK: - Merger

/// Opens the confirmation for a row, sends the merge when it is confirmed and keeps what each row's attempt
/// has come to. Attempts are by row id and live as long as the app: a notice stays until dismissed or the row
/// changes (the Kit decides which).
final class AuthoredPrMerger {
    let transport: AuthoredPrMergeTransport
    var permit: AuthoredPrGesture.Permit
    /// Shows the confirmation anchored at the view; `dismiss` takes it down. The default is the real popover.
    var present: (AuthoredPrMergeSession, NSView) -> Void = { AuthoredPrMergeUI.show($0, from: $1) }
    var dismiss: () -> Void = { AuthoredPrMergeUI.dismiss() }
    /// Fires whenever the attempts or the open confirmation change.
    let changes = PassthroughSubject<Void, Never>()

    private(set) var attempts: [String: AuthoredPrMergeAttempt] = [:]
    private(set) var presented: AuthoredPrMergeSession?
    private var presentedRowId: String?
    /// The Overview that opened the confirmation (weak: a closed window is no owner), see `rowsDidChange`.
    private weak var presentedBy: AnyObject?

    init(transport: AuthoredPrMergeTransport, permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live) {
        self.transport = transport
        self.permit = permit
    }

    /// The row's Merge button, or its VoiceOver action. Opens the confirmation for the row as the person saw it;
    /// it never sends. Does nothing for an older daemon, a button that is not ready, or a row whose merge is
    /// already running or done. A refused gesture opens nothing and says so on the row ("Merge was refused: use
    /// the button"), rather than nothing at all: VoiceOver can leave a stale event behind the Merge action.
    /// `owner` is the Overview whose press it was.
    func activate(_ model: AuthoredPrRowModel, anchor: NSView, event: NSEvent?, control: NSView,
                  owner: AnyObject? = nil) {
        guard transport.isMergeAvailable, let button = model.mergeButton, button.state == .ready,
              let confirmation = button.confirmation else { return }
        switch attempts[model.id]?.progress {
        case .merging?, .merged?, .queued?: return
        case .failed?, nil: break
        }
        guard permit(event, control, "merge") else {
            // A refusal never wipes the daemon's own reason for the last failure at this head (an app-control client
            // could otherwise erase "your token cannot merge").
            if case .failed(let code)? = attempts[model.id]?.progress, code != .gestureRefused,
               attempts[model.id]?.head == confirmation.expectedHeadShaShort { return }
            attempts[model.id] = AuthoredPrMergeAttempt(head: confirmation.expectedHeadShaShort,
                                                        progress: .failed(.gestureRefused))
            changes.send()
            return
        }

        // Starting a new attempt: whatever the last one said is old news (a `head_changed` notice would otherwise
        // outlive every later head).
        if case .failed? = attempts[model.id]?.progress { attempts[model.id] = nil }
        closePresented(notify: false)
        let session = AuthoredPrMergeSession(confirmation: confirmation, permit: { [weak self] event, control, action in
            self?.permit(event, control, action) ?? false
        })
        let rowId = model.id
        session.onFinish = { [weak self, weak session] outcome in
            guard let self, let session, self.presented === session else { return }
            self.closePresented(notify: true)
            if outcome == .confirmed { self.send(confirmation, rowId: rowId) }
        }
        presented = session
        presentedRowId = rowId
        presentedBy = owner
        present(session, anchor)
        changes.send()
    }

    /// Remove a failure's notice. A merge that is running or done is not something to dismiss.
    func dismissNotice(rowId: String) {
        guard case .failed? = attempts[rowId]?.progress else { return }
        attempts[rowId] = nil
        changes.send()
    }

    /// The rows `reporter` (an Overview) now shows. A confirmation whose row is no longer ready, at another head or
    /// aimed at another base is cancelled: what the person read is not what the row says now. (A retitle or a new
    /// comment is not: nothing the sentence says has changed.) The merger is shared by every Overview, and one
    /// that does not show the row (another filter, the row behind "Show more", a window just opened) says nothing
    /// about it: only the Overview that opened the confirmation may cancel it for a row it no longer has.
    func rowsDidChange(_ rows: [AuthoredPrRowModel], from reporter: AnyObject? = nil) {
        guard let session = presented, let id = presentedRowId else { return }
        let row = rows.first { $0.id == id }
        if row == nil, presentedBy != nil, reporter !== presentedBy { return }   // a gone opener cannot cancel: then any window may
        let now = row.flatMap { $0.mergeButton?.state == .ready ? $0.mergeButton?.confirmation : nil }
        let read = session.confirmation
        guard now?.expectedHeadShaShort != read.expectedHeadShaShort || now?.base != read.base
                || now?.approval != read.approval || now?.via != read.via else { return }
        session.cancel()
    }

    /// The PRs a snapshot now shows (an Overview's `displayed`). A queued attempt whose PR has been seen in the merge
    /// queue and is no longer in it, while still open, was dropped from the queue (the Kit words it and the button is
    /// available again). Rows the snapshot does not hold, and every other kind of attempt, are left alone.
    func reconcile(prs: [AuthoredPr]) {
        var changed = false
        for pr in prs {
            guard let attempt = attempts[pr.id] else { continue }
            let next = AuthoredPrsPresentation.reconcile(attempt, with: pr)
            if next != attempt { attempts[pr.id] = next; changed = true }
        }
        if changed { changes.send() }
    }

    // MARK: Private

    private func closePresented(notify: Bool) {
        guard let old = presented else { return }
        old.onFinish = nil
        old.cancel()
        presented = nil
        presentedRowId = nil
        presentedBy = nil
        dismiss()
        if notify { changes.send() }
    }

    private func send(_ confirmation: AuthoredPrMergeConfirmation, rowId: String) {
        let head = confirmation.expectedHeadShaShort
        guard transport.isMergeAvailable else {
            // The link dropped (or the daemon went) while the person was reading: say so rather than close in silence.
            mergeLog.notice("authored-pr merge not sent: unavailable")
            attempts[rowId] = AuthoredPrMergeAttempt(head: head, progress: .failed(.unreachable))
            changes.send()
            return
        }
        attempts[rowId] = AuthoredPrMergeAttempt(head: head, progress: .merging)
        changes.send()
        let via: AuthoredPrMergeVia? = confirmation.via == .queue ? .queue : nil
        transport.merge(repo: confirmation.repo, number: confirmation.number, expectedHeadShaShort: head,
                        expectedVia: via) { [weak self] answer in
            guard let self else { return }
            // `queued` and `already_queued` both leave the PR in the merge queue: never read as merged, and never a
            // reason to move the row (only a later snapshot does).
            let progress: AuthoredPrMergeProgress
            switch answer.mergeFailure {
            case nil: progress = answer.mergeQueued ? .queued : .merged
            case .alreadyQueued?: progress = .queued
            case let code?: progress = .failed(code)
            }
            self.attempts[rowId] = AuthoredPrMergeAttempt(head: head, progress: progress)
            self.changes.send()
        }
    }
}
