import AppKit
import Combine
import os

/// The single app-wide owner of decision-modal presentation.
///
/// Nostromo opens one full-screen window per attached display, each on its own
/// Space. An agent's `nostromo.ask_decision` call has to reach the operator
/// wherever their attention is — and that cannot be predicted: the first
/// version of this presenter picked ONE window (the key window, falling back to
/// the main window, then the first visible one) and the operator found the
/// sheet on a screen they weren't looking at, on a different window each time,
/// sometimes on a Space that wasn't displayed at all (live report, 2026-10-06).
///
/// So a decision is presented on **every** Nostromo window, and answering it on
/// any one of them closes it on all the others:
///
/// - **Exactly-once answering** is `DecisionStore.claimAnswer`'s job, not
///   "only one window has a sheet". The sheet that wins the claim sends the
///   answer; a sheet that loses it (a second tap landing before it closed) goes
///   inert and never calls `onAnswer`. That atomic gate is what made the original
///   bug — a sheet on every window answerable twice with contradictory
///   choices — about *missing sibling dismissal*, not about showing on many
///   windows.
/// - **Sibling dismissal:** the answering sheet's `onAnswer` closes every other
///   sheet for the request WITHOUT answering (`closeWithoutAnswering`), and a
///   `DecisionResolved` notice from the daemon (answered on iOS, timed out,
///   its session went away) closes all of them the same way.
/// - **Windows that appear later** (a display plugged in, a new window) get a
///   sheet for any decision still outstanding the moment they become key.
///
/// This type is still the ONLY subscriber to `AppStore.shared.decisionRequests`
/// and the ONLY place a `DecisionSheet` is constructed: `MainLayout` is
/// instantiated once per window and must not know a decision exists
/// (`DecisionSheetWiringTests` pins both).
///
/// Started once from `AppDelegate.applicationDidFinishLaunching`, beside
/// `AppStore.shared.startMemoryWatchdog()`.
final class DecisionPresenter {

    static let shared = DecisionPresenter()

    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: "com.hammer.nostromo", category: "decisions")

    /// One sheet, and the window it is attached to.
    private struct Presented {
        weak var window: NostromoWindow?
        let sheet: DecisionSheet
    }

    /// Every decision sheet currently up, per request, keyed by window
    /// identity — a request has one sheet PER WINDOW.
    private var presented: [String: [ObjectIdentifier: Presented]] = [:]
    /// The payload each outstanding request was built from, so a window that
    /// appears (or a retarget) can present the same content without a second
    /// `decision_request`.
    private var activeDecisions: [String: PendingDecision] = [:]

    private init() {}

    func start() {
        AppStore.shared.decisionRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] decision in self?.present(decision) }
            .store(in: &cancellables)

        AppStore.shared.decisionResolutions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolved in self?.handleResolved(resolved) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        // A window that becomes key after a decision was posed (a display
        // plugged in, a window opened) must show it too.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    // MARK: - Presentation

    /// Present `decision` on every Nostromo window, unless it is already being
    /// presented (`claimPresentation` fails) or has already been resolved (a
    /// `DecisionResolved` notice, or a prior local answer, beat this event
    /// through the pipe). `excluded` rules out a window that is itself closing
    /// (the retarget path) so a request is never re-presented onto it.
    private func present(_ decision: PendingDecision, excludingWindow excluded: NostromoWindow? = nil) {
        let requestId = decision.requestId

        guard DecisionStore.shared.claimPresentation(requestId: requestId) else { return }
        guard DecisionStore.shared.resolution(for: requestId) == nil else {
            DecisionStore.shared.releasePresentation(requestId: requestId)
            return
        }
        let windows = targetWindows(excluding: excluded)
        guard !windows.isEmpty else {
            // No window to present on right now (e.g. the last window is
            // mid-close). Release the claim so a future retarget attempt, or a
            // later re-delivery, can still present it. Leaves the request
            // outstanding for the daemon's own timeout to backstop.
            DecisionStore.shared.releasePresentation(requestId: requestId)
            return
        }

        activeDecisions[requestId] = decision
        // Bring the asking agent's focus forward where the operator is looking
        // (the key window, else the first), not on every display: switching
        // every window's focus just to ask a question would be intrusive.
        if let primary = windows.first(where: { $0 === NSApp.keyWindow }) ?? windows.first {
            focusSession(tag: decision.tag, on: primary)
        }
        log.info("decision \(requestId, privacy: .public) presenting on \(windows.count, privacy: .public) window(s)")
        for window in windows {
            attachSheet(for: decision, to: window)
        }
    }

    /// Build one `DecisionSheet` for `decision` and begin it on `window`.
    /// The sheet is registered under `(request, window)` BEFORE `beginSheet`,
    /// so a close that races the presentation is already accounted for.
    private func attachSheet(for decision: PendingDecision, to window: NostromoWindow) {
        let requestId = decision.requestId
        let windowKey = ObjectIdentifier(window)
        guard presented[requestId]?[windowKey] == nil else { return }

        let choices = decision.choices.map { DecisionSheet.Choice(id: $0.id, label: $0.label, detail: $0.detail) }
        let sheet = DecisionSheet(
            requestId: requestId,
            prompt: decision.prompt,
            detail: decision.detail,
            choices: choices,
            store: DecisionStore.shared,
            resolution: DecisionStore.shared.resolution(for: requestId),
            onAnswer: { [weak self] choiceId in
                AppStore.shared.answerDecision(requestId: requestId, choiceId: choiceId)
                // Answered on this window: every other window's sheet for the
                // same request is now moot — close them WITHOUT answering.
                self?.dismissSiblings(of: requestId, answeredOn: windowKey)
            }
        )
        presented[requestId, default: [:]][windowKey] = Presented(window: window, sheet: sheet)

        // Identity-guarded: a stale completion (this sheet was superseded or
        // retargeted before it fired) must not tear down a newer sheet's state.
        window.beginSheet(sheet.window!) { [weak self, weak sheet] _ in
            guard let self, let sheet,
                  self.presented[requestId]?[windowKey]?.sheet === sheet else { return }
            self.sheetEnded(requestId: requestId, windowKey: windowKey)
        }
    }

    /// Close every sheet for `requestId` except the one on `answeredOn`, without
    /// answering. Each close fires that sheet's own completion handler, which
    /// removes it via `sheetEnded`.
    private func dismissSiblings(of requestId: String, answeredOn: ObjectIdentifier) {
        guard let sheets = presented[requestId] else { return }
        let siblings = sheets.filter { $0.key != answeredOn }
        log.info("decision \(requestId, privacy: .public) answered; closing \(siblings.count, privacy: .public) sibling sheet(s)")
        for entry in siblings.values {
            entry.sheet.closeWithoutAnswering(reason: .supersededElsewhere)
        }
    }

    /// One window's sheet for `requestId` ended (answered, dismissed, or
    /// closed by us). When the last one is gone the request is done here.
    private func sheetEnded(requestId: String, windowKey: ObjectIdentifier) {
        presented[requestId]?.removeValue(forKey: windowKey)
        if presented[requestId]?.isEmpty ?? true {
            finishPresenting(requestId: requestId)
        }
    }

    /// A `ServerMsg::DecisionResolved` notice arrived — this request is done,
    /// however it happened (answered elsewhere, dismissed elsewhere, timed
    /// out, or its owning session went away). Record the resolution locally (so
    /// a late `decision_request` replay for the same id can never reconstruct an
    /// armed sheet — RC4/D5) and close EVERY sheet for it WITHOUT answering —
    /// this must never itself send a `decision_answer`.
    private func handleResolved(_ resolved: ResolvedDecision) {
        let requestId = resolved.requestId

        // "answered" is the only resolution with a chosen id to preserve;
        // dismissed/timeout/cancelled all collapse to `.dismissed` here —
        // there is no chosen option to render in any of those cases, and a
        // request resolved any of those ways must reconstruct inert, not
        // armed, exactly like an explicit operator dismissal.
        let record: DecisionAnswerRecord = {
            if resolved.resolution == "answered", let choiceId = resolved.choiceId {
                return .choice(choiceId)
            }
            return .dismissed
        }()
        _ = DecisionStore.shared.claimAnswer(requestId: requestId, record: record)

        guard let sheets = presented[requestId] else { return }
        for entry in sheets.values {
            entry.sheet.closeWithoutAnswering(reason: .supersededElsewhere)
        }
        finishPresenting(requestId: requestId)
    }

    /// A window is about to close (e.g. its display was disconnected). Its
    /// sheet for each outstanding request is closed WITHOUT answering — a
    /// closing window must never answer Dismissed on the operator's behalf.
    /// Other windows keep their sheets, so nothing else needs doing; if THIS
    /// was the last window showing the request, re-present it on a survivor so
    /// it stays live for the operator (or, with none left, leave it for the
    /// daemon's own timeout).
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NostromoWindow else { return }
        let windowKey = ObjectIdentifier(closingWindow)

        for requestId in Array(presented.keys) {
            guard let entry = presented[requestId]?[windowKey] else { continue }
            entry.sheet.closeWithoutAnswering(reason: .retargeting)
            presented[requestId]?.removeValue(forKey: windowKey)

            if presented[requestId]?.isEmpty ?? true {
                let decision = activeDecisions[requestId]
                finishPresenting(requestId: requestId)
                if let decision {
                    present(decision, excludingWindow: closingWindow)
                }
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NostromoWindow else { return }
        for (requestId, decision) in activeDecisions
        where DecisionStore.shared.resolution(for: requestId) == nil {
            attachSheet(for: decision, to: window)
        }
    }

    // MARK: - Private

    private func finishPresenting(requestId: String) {
        presented.removeValue(forKey: requestId)
        activeDecisions.removeValue(forKey: requestId)
        DecisionStore.shared.releasePresentation(requestId: requestId)
    }

    private func focusSession(tag: String, on window: NostromoWindow) {
        (window.contentView as? MainLayout)?.focusSession(tag: tag)
    }

    /// Every Nostromo window, key window first. Not filtered by visibility or
    /// Space: a window on a Space the operator isn't looking at can't strand the
    /// request any more, because the sheet is on the others too.
    private func targetWindows(excluding excluded: NostromoWindow? = nil) -> [NostromoWindow] {
        let all = NSApp.windows.compactMap { $0 as? NostromoWindow }.filter { $0 !== excluded }
        return all.sorted { lhs, _ in lhs === NSApp.keyWindow }
    }
}
