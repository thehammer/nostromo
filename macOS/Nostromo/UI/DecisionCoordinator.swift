import Foundation
import os

/// Why a `DecisionSheet` closed. Only the first two ever put anything on the
/// wire; the other two exist precisely so a system-initiated close (this
/// request was resolved elsewhere, or this sheet is being re-targeted to a
/// surviving window) can NEVER be mistaken for an operator dismissal — a
/// spurious `decision_answer` from a close nobody actually chose would read
/// to the calling agent as an explicit Skip, and could cancel something the
/// operator actually approved on another window.
enum DecisionCloseReason {
    /// The operator tapped a choice button.
    case operatorChose(String)
    /// The operator dismissed the modal (Dismiss button or titlebar close).
    case operatorDismissed
    /// This request was already resolved elsewhere (answered on another
    /// window, or the daemon announced it's done) — close silently.
    case supersededElsewhere
    /// The presenting window is going away; the presenter is re-showing this
    /// sheet's request on a surviving window (or, if none survives, leaving
    /// it for the daemon's own timeout to resolve) — close silently either way.
    case retargeting
}

/// A decision sheet, as far as the coordinator is concerned. The only thing it
/// may ever do to one is close it WITHOUT answering.
protocol DecisionSheetControlling: AnyObject {
    func closeWithoutAnswering(reason: DecisionCloseReason)
}

/// A window a decision sheet can be shown on (`NostromoWindow` in the app).
protocol DecisionHostWindow: AnyObject {
    /// On the active Space, not occluded, not miniaturized.
    var isVisibleNow: Bool { get }
    var isKeyNow: Bool { get }
    /// Position in the front-to-back window order; lower == nearer the front.
    var frontOrder: Int { get }
    /// `sessionTag` of the focus this window is displaying right now.
    var activeFocusTag: String? { get }
    /// Begin `sheet` on this window and call `completion` when it ends, however
    /// it ends. Must not activate the app, raise the window, or change focus.
    func showDecisionSheet(_ sheet: DecisionSheetControlling, completion: @escaping () -> Void)
}

/// Where the coordinator publishes "this focus needs the operator".
protocol AttentionSink: AnyObject {
    func raiseAttention(tag: String, key: String)
    func clearAttention(key: String)
}

/// The AppKit-free lifecycle of daemon-driven decision popups.
///
/// A request is presented on exactly ONE window, chosen by
/// `selectDecisionTargets` (the asking focus's visible window, else a visible
/// window on some other focus, else any window). While it is outstanding it is
/// re-targeted — never answered — as windows change (`reevaluate`,
/// `windowWillClose`), and the asking focus is flagged through `AttentionSink`
/// so the operator can find it on their own terms.
///
/// - **Exactly-once answering** is `DecisionStore.claimAnswer`'s job (the real
///   `DecisionSheet` claims before forwarding to `onAnswer`).
/// - **A system close never answers:** retargeting and resolution close sheets
///   with `closeWithoutAnswering`, and the sheet entry is dropped BEFORE the
///   close so the ending sheet's completion is recognised as stale.
/// - **Never stranded:** an outstanding request with no window to show on keeps
///   its attention flag and is presented by a later `reevaluate()`.
///
/// Nothing here activates the app, raises a window or switches a focus.
final class DecisionCoordinator {

    private let store: DecisionStore
    private let attention: AttentionSink
    private let windows: () -> [DecisionHostWindow]
    private let makeSheet: (PendingDecision, @escaping (String?) -> Void) -> DecisionSheetControlling
    private let sendAnswer: (String, String?) -> Void
    private let log = Logger(subsystem: "com.hammer.nostromo", category: "decisions")

    /// One sheet, the window it is on, and a token so a stale completion
    /// (the sheet was retargeted or finished first) is recognisable.
    private struct Presented {
        weak var window: DecisionHostWindow?
        let sheet: DecisionSheetControlling
        let token: UUID
    }

    /// Requests that are outstanding, whether or not a sheet is up right now.
    private var activeDecisions: [String: PendingDecision] = [:]
    private var presented: [String: Presented] = [:]

    init(store: DecisionStore,
         attention: AttentionSink,
         windows: @escaping () -> [DecisionHostWindow],
         makeSheet: @escaping (_ decision: PendingDecision,
                               _ onAnswer: @escaping (_ choiceId: String?) -> Void) -> DecisionSheetControlling,
         sendAnswer: @escaping (_ requestId: String, _ choiceId: String?) -> Void) {
        self.store = store
        self.attention = attention
        self.windows = windows
        self.makeSheet = makeSheet
        self.sendAnswer = sendAnswer
    }

    // MARK: - Events

    /// A `decision_request` arrived. Ignored if it is already being presented
    /// (`claimPresentation` fails) or already resolved (a `DecisionResolved`
    /// notice or a prior local answer beat this event through the pipe).
    func present(_ decision: PendingDecision) {
        let requestId = decision.requestId
        guard store.claimPresentation(requestId: requestId) else { return }
        guard store.resolution(for: requestId) == nil else {
            store.releasePresentation(requestId: requestId)
            return
        }
        activeDecisions[requestId] = decision
        attention.raiseAttention(tag: decision.tag, key: Self.attentionKey(requestId))
        attachToBestWindow(decision, excluding: nil)
    }

    /// A `DecisionResolved` notice arrived — this request is done, however it
    /// happened (answered elsewhere, dismissed, timed out, its session went
    /// away). Record the resolution (so a late `decision_request` replay can
    /// never reconstruct an armed sheet) and close the sheet WITHOUT answering.
    func handleResolved(_ resolved: ResolvedDecision) {
        let requestId = resolved.requestId

        // Only "answered" has a chosen id to preserve; every other resolution
        // reconstructs inert, exactly like an explicit dismissal.
        let record: DecisionAnswerRecord = {
            if resolved.resolution == "answered", let choiceId = resolved.choiceId {
                return .choice(choiceId)
            }
            return .dismissed
        }()
        _ = store.claimAnswer(requestId: requestId, record: record)

        let sheet = presented[requestId]?.sheet
        finish(requestId: requestId)
        sheet?.closeWithoutAnswering(reason: .supersededElsewhere)
    }

    /// A window is about to close (e.g. its display was disconnected). Its
    /// sheets are closed WITHOUT answering — a closing window must never answer
    /// Dismissed on the operator's behalf — and each request is re-presented on
    /// the best surviving window, or, with none, left outstanding for a later
    /// `reevaluate()` (and the daemon's own timeout).
    func windowWillClose(_ window: DecisionHostWindow) {
        for requestId in Array(presented.keys) {
            guard let entry = presented[requestId], entry.window === window else { continue }
            // The presentation claim stays held across the close: ending the
            // sheet can post window notifications that call `reevaluate()`
            // re-entrantly, and that must not re-present onto the closing window.
            presented.removeValue(forKey: requestId)
            entry.sheet.closeWithoutAnswering(reason: .retargeting)

            guard let decision = activeDecisions[requestId] else {
                store.releasePresentation(requestId: requestId)
                continue
            }
            attachToBestWindow(decision, excluding: window)
        }
    }

    /// Something about the windows changed (a window became key or visible, the
    /// operator switched a window's focus, a Space changed). Presents any
    /// outstanding request that has no sheet, and moves a sheet only to a
    /// window in a STRICTLY better tier than the one it is on, so equal-tier
    /// churn (the key window flipping between two other-focus windows) never
    /// moves it. Never answers anything.
    func reevaluate() {
        for requestId in Array(activeDecisions.keys) {
            guard let decision = activeDecisions[requestId], store.resolution(for: requestId) == nil else { continue }

            guard let entry = presented[requestId] else {
                if store.claimPresentation(requestId: requestId) {
                    attachToBestWindow(decision, excluding: nil)
                }
                continue
            }

            let infos = windowInfos(excluding: nil)
            guard let best = selectDecisionTargets(windows: infos, requestTag: decision.tag).first else { continue }
            let currentId = entry.window.map(ObjectIdentifier.init)
            // A holder that is gone from the list always moves; a live one
            // only for a strictly better tier.
            if let currentId, let current = infos.first(where: { $0.id == currentId }) {
                guard best.tier < decisionTier(of: current, requestTag: decision.tag) else { continue }
            }
            guard let target = window(for: best.id) else { continue }

            // Drop the entry BEFORE closing: the old sheet's completion then
            // finds no matching token and does nothing.
            presented.removeValue(forKey: requestId)
            entry.sheet.closeWithoutAnswering(reason: .retargeting)
            log.info("decision \(requestId, privacy: .public) retargeted to tier \(best.tier.rawValue, privacy: .public)")
            attach(decision, to: target)
        }
    }

    /// The window currently holding the sheet for `requestId`, if any.
    func presentedWindow(for requestId: String) -> DecisionHostWindow? {
        presented[requestId]?.window
    }

    // MARK: - Private

    private static func attentionKey(_ requestId: String) -> String { "decision:\(requestId)" }

    private func windowInfos(excluding excluded: DecisionHostWindow?) -> [DecisionWindowInfo<ObjectIdentifier>] {
        windows().filter { $0 !== excluded }.map {
            DecisionWindowInfo(id: ObjectIdentifier($0), isVisible: $0.isVisibleNow, isKey: $0.isKeyNow,
                               order: $0.frontOrder, activeFocusTag: $0.activeFocusTag)
        }
    }

    private func window(for id: ObjectIdentifier) -> DecisionHostWindow? {
        windows().first { ObjectIdentifier($0) == id }
    }

    /// Show `decision` on the best window. The caller holds the presentation
    /// claim; with no window to show on it is released, leaving the request
    /// outstanding (attention stays raised) for a later `reevaluate()`.
    private func attachToBestWindow(_ decision: PendingDecision, excluding excluded: DecisionHostWindow?) {
        let infos = windowInfos(excluding: excluded)
        guard let best = selectDecisionTargets(windows: infos, requestTag: decision.tag).first,
              let target = windows().first(where: { ObjectIdentifier($0) == best.id && $0 !== excluded }) else {
            store.releasePresentation(requestId: decision.requestId)
            log.info("decision \(decision.requestId, privacy: .public) has no window yet; left outstanding")
            return
        }
        log.info("decision \(decision.requestId, privacy: .public) presenting on one window (tier \(best.tier.rawValue, privacy: .public))")
        attach(decision, to: target)
    }

    private func attach(_ decision: PendingDecision, to window: DecisionHostWindow) {
        let requestId = decision.requestId
        let token = UUID()
        let sheet = makeSheet(decision) { [weak self] choiceId in
            // The sheet won the answer claim: put the answer on the wire once.
            self?.sendAnswer(requestId, choiceId)
            self?.finish(requestId: requestId)
        }
        // Registered BEFORE the sheet begins, so a close that races the
        // presentation is already accounted for.
        presented[requestId] = Presented(window: window, sheet: sheet, token: token)
        window.showDecisionSheet(sheet) { [weak self] in
            // Token-guarded: a stale completion (this sheet was retargeted or
            // finished before it fired) must not tear down a newer sheet's state.
            guard let self, self.presented[requestId]?.token == token else { return }
            self.finish(requestId: requestId)
        }
    }

    /// The request is done: nothing is outstanding, so nothing is flagged.
    private func finish(requestId: String) {
        presented.removeValue(forKey: requestId)
        activeDecisions.removeValue(forKey: requestId)
        attention.clearAttention(key: Self.attentionKey(requestId))
        store.releasePresentation(requestId: requestId)
    }
}
