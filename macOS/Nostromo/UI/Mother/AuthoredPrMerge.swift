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
    func merge(repo: String, number: Int, expectedHeadShaShort: String,
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

    init(transport: AuthoredPrMergeTransport, permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live) {
        self.transport = transport
        self.permit = permit
    }

    /// The row's Merge button, or its VoiceOver action. Opens the confirmation for the row as the person saw it;
    /// it never sends. Does nothing for a refused gesture, an older daemon, a button that is not ready, or a row
    /// whose merge is already running or done.
    func activate(_ model: AuthoredPrRowModel, anchor: NSView, event: NSEvent?, control: NSView) {
        guard transport.isMergeAvailable, let button = model.mergeButton, button.state == .ready,
              let confirmation = button.confirmation else { return }
        switch attempts[model.id]?.progress {
        case .merging?, .merged?: return
        case .failed?, nil: break
        }
        guard permit(event, control, "merge") else { return }

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
        present(session, anchor)
        changes.send()
    }

    /// Remove a failure's notice. A merge that is running or done is not something to dismiss.
    func dismissNotice(rowId: String) {
        guard case .failed? = attempts[rowId]?.progress else { return }
        attempts[rowId] = nil
        changes.send()
    }

    /// The rows the Overview now shows. A confirmation whose row is gone, no longer ready or at another head is
    /// cancelled: what the person read is not what the row says now.
    func rowsDidChange(_ rows: [AuthoredPrRowModel]) {
        guard let session = presented, let id = presentedRowId else { return }
        let row = rows.first { $0.id == id }
        let head = row?.mergeButton?.state == .ready ? row?.mergeButton?.confirmation?.expectedHeadShaShort : nil
        guard head != session.confirmation.expectedHeadShaShort else { return }
        session.cancel()
    }

    // MARK: Private

    private func closePresented(notify: Bool) {
        guard let old = presented else { return }
        old.onFinish = nil
        old.cancel()
        presented = nil
        presentedRowId = nil
        dismiss()
        if notify { changes.send() }
    }

    private func send(_ confirmation: AuthoredPrMergeConfirmation, rowId: String) {
        guard transport.isMergeAvailable else {
            mergeLog.notice("authored-pr merge not sent: unavailable")
            return
        }
        let head = confirmation.expectedHeadShaShort
        attempts[rowId] = AuthoredPrMergeAttempt(head: head, progress: .merging)
        changes.send()
        transport.merge(repo: confirmation.repo, number: confirmation.number, expectedHeadShaShort: head) { [weak self] answer in
            guard let self else { return }
            let progress: AuthoredPrMergeProgress = answer.mergeFailure.map { .failed($0) } ?? .merged
            self.attempts[rowId] = AuthoredPrMergeAttempt(head: head, progress: progress)
            self.changes.send()
        }
    }
}
