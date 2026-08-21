import AppKit
import Combine

/// The single app-wide owner of decision-modal presentation.
///
/// This exists to fix a real, observed bug: Nostromo opens one full-screen
/// window per attached display, and `MainLayout` — instantiated once PER
/// WINDOW — used to independently subscribe to decision requests and present
/// its own sheet. One `nostromo.ask_decision` call produced N sheets, one per
/// open window, and answering one didn't dismiss the others (the daemon's
/// own answer-once guard was the only thing standing between that and a
/// contradictory second answer reaching a live agent session). Centralizing
/// presentation here, as the ONLY subscriber to
/// `AppStore.shared.decisionRequests`, makes N-windows-means-N-sheets
/// structurally impossible: `DecisionStore.claimPresentation` additionally
/// belt-and-braces against even a future second invocation of this type.
///
/// Started once from `AppDelegate.applicationDidFinishLaunching`, beside
/// `AppStore.shared.startMemoryWatchdog()`.
///
/// Every window is full-screen on its own Space, so presenting a decision on
/// a window the operator isn't looking at strands it — the same failure the
/// codebase's anti-`runModal()` convention already guards against (see
/// `DecisionSheet`'s header comment). So presentation always targets
/// `NSApp.keyWindow` (where the operator's attention is right now), falling
/// back to `NSApp.mainWindow` (where they were last, when the app itself
/// isn't frontmost — the common case: an agent asks while the operator is in
/// another app), and finally the first visible window, so a request is never
/// silently dropped purely for want of a "current" window.
final class DecisionPresenter {

    static let shared = DecisionPresenter()

    private var cancellables = Set<AnyCancellable>()

    /// Every decision sheet this presenter currently has a strong reference
    /// to, keyed by request id — not a single slot. The daemon explicitly
    /// allows two DIFFERENT tags to each have an active decision at once
    /// (mirrors the rationale the old per-window dictionary in `MainLayout`
    /// used to document).
    private var presentedSheets: [String: DecisionSheet] = [:]
    /// Which window each currently-presented sheet is anchored to, so a
    /// closing window can retarget (not silently drop) any sheet it hosts.
    private var presentingWindow: [String: NostromoWindow] = [:]
    /// The payload each currently-presented (or about-to-be-retargeted)
    /// sheet was built from, so a retarget can re-present the same content
    /// on a surviving window without needing a second `decision_request`.
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
    }

    // MARK: - Presentation

    /// Present `decision` as a sheet on the target window, unless it's
    /// already being presented (`claimPresentation` fails) or has already
    /// been resolved (a `DecisionResolved` notice, or a prior local answer,
    /// beat this event through the pipe). `excluded`, when set, rules out a
    /// window that is itself in the process of closing (the retarget path
    /// below) so a request never gets re-presented right back onto the
    /// window that's going away.
    private func present(_ decision: PendingDecision, excludingWindow excluded: NostromoWindow? = nil) {
        let requestId = decision.requestId

        guard DecisionStore.shared.claimPresentation(requestId: requestId) else { return }
        guard DecisionStore.shared.resolution(for: requestId) == nil else {
            DecisionStore.shared.releasePresentation(requestId: requestId)
            return
        }
        guard let window = targetWindow(excluding: excluded) else {
            // No window to present on right now (e.g. the last window is
            // mid-close). Release the claim so a future retarget attempt, or
            // a later re-delivery, can still present it. Leaves the request
            // outstanding for the daemon's own timeout to backstop.
            DecisionStore.shared.releasePresentation(requestId: requestId)
            return
        }

        activeDecisions[requestId] = decision
        focusSession(tag: decision.tag, on: window)

        let choices = decision.choices.map { DecisionSheet.Choice(id: $0.id, label: $0.label, detail: $0.detail) }
        let sheet = DecisionSheet(
            requestId: requestId,
            prompt: decision.prompt,
            detail: decision.detail,
            choices: choices,
            store: DecisionStore.shared,
            resolution: DecisionStore.shared.resolution(for: requestId),
            onAnswer: { choiceId in
                AppStore.shared.answerDecision(requestId: requestId, choiceId: choiceId)
            }
        )
        presentedSheets[requestId] = sheet
        presentingWindow[requestId] = window

        // Identity-guarded: if this sheet has already been superseded (its
        // request retargeted to another window, or resolved elsewhere) by
        // the time this completion actually fires, `presentedSheets` will
        // either be empty for this id or hold a DIFFERENT (newer) sheet —
        // either way, this stale completion must not tear down live state.
        window.beginSheet(sheet.window!) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.presentedSheets[requestId] === sheet else { return }
            self.finishPresenting(requestId: requestId)
        }
    }

    /// A `ServerMsg::DecisionResolved` notice arrived — this request is done,
    /// however it happened (answered elsewhere, dismissed elsewhere, timed
    /// out, or its owning session went away). Record the resolution locally
    /// (so a late `decision_request` replay for the same id can never
    /// reconstruct an armed sheet — RC4/D5) and, if this presenter currently
    /// has a live sheet up for it, close it WITHOUT answering — this must
    /// never itself send a `decision_answer`.
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

        guard presentedSheets[requestId] != nil else { return }
        presentedSheets[requestId]?.closeWithoutAnswering(reason: .supersededElsewhere)
        finishPresenting(requestId: requestId)
    }

    /// The presenting window for one or more outstanding requests is about
    /// to close (e.g. its display was disconnected). Each such sheet is
    /// closed WITHOUT answering — a closing window must never be allowed to
    /// answer Dismissed on the operator's behalf — and, if a surviving
    /// window exists, immediately re-presented there so the request stays
    /// live for the operator. If none survives, the request is left
    /// outstanding for the daemon's own timeout.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NostromoWindow else { return }
        let affected = presentingWindow.filter { $0.value === closingWindow }.map(\.key)
        guard !affected.isEmpty else { return }

        for requestId in affected {
            guard presentedSheets[requestId] != nil else { continue }
            let decision = activeDecisions[requestId]
            presentedSheets[requestId]?.closeWithoutAnswering(reason: .retargeting)
            finishPresenting(requestId: requestId)
            if let decision {
                present(decision, excludingWindow: closingWindow)
            }
        }
    }

    // MARK: - Private

    private func finishPresenting(requestId: String) {
        presentedSheets.removeValue(forKey: requestId)
        presentingWindow.removeValue(forKey: requestId)
        activeDecisions.removeValue(forKey: requestId)
        DecisionStore.shared.releasePresentation(requestId: requestId)
    }

    private func focusSession(tag: String, on window: NostromoWindow) {
        (window.contentView as? MainLayout)?.focusSession(tag: tag)
    }

    private func targetWindow(excluding excluded: NostromoWindow? = nil) -> NostromoWindow? {
        if let key = NSApp.keyWindow as? NostromoWindow, key !== excluded { return key }
        if let main = NSApp.mainWindow as? NostromoWindow, main !== excluded { return main }
        return NSApp.windows.compactMap { $0 as? NostromoWindow }.first { $0.isVisible && $0 !== excluded }
    }
}
