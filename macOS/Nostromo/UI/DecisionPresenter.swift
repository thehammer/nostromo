import AppKit
import Combine

/// The single app-wide AppKit adapter for decision-modal presentation.
///
/// An agent's `nostromo.ask_decision` call (what submit-review uses) must reach
/// the operator WITHOUT taking over their screens. So a request is presented on
/// exactly ONE window — never every window, which brought Nostromo forward on
/// displays the operator was working on and switched their focus — chosen by
/// `selectDecisionTargets`:
///
/// 1. a visible window already showing the asking focus;
/// 2. else a visible window showing some other focus (its focus is NOT
///    switched; the sheet's text names the asking agent, and the sidebar flags
///    the asking focus via `AppStore.shared.attentionTags`);
/// 3. else (Nostromo is hidden / on other Spaces) one window, so the request
///    exists when the operator returns, with today's attention behaviour.
///
/// The old broadcast design exists because a single blindly-picked window once
/// put the sheet on a Space nobody was looking at and the request was lost
/// (live report, 2026-10-06). The guarantee that it can never be stranded is
/// kept by targeting on VISIBILITY, by the sidebar indicator, and by
/// `DecisionCoordinator` re-targeting (never answering) as windows change.
///
/// This type never activates the app, raises a window, makes one key, or
/// switches a focus; source scans in `DecisionCoordinatorTests` pin that.
///
/// The lifecycle (exactly-once answering, retargeting, resolution) lives in the
/// AppKit-free `DecisionCoordinator`; this file only supplies real windows and
/// sheets and forwards events. It is still the ONLY subscriber to
/// `AppStore.shared.decisionRequests` and the ONLY place a `DecisionSheet` is
/// constructed: `MainLayout` is instantiated once per window and must not know
/// a decision exists (`DecisionSheetWiringTests` pins both).
///
/// Started once from `AppDelegate.applicationDidFinishLaunching`, beside
/// `AppStore.shared.startMemoryWatchdog()`.
final class DecisionPresenter {

    static let shared = DecisionPresenter()

    private var cancellables = Set<AnyCancellable>()

    private lazy var coordinator = DecisionCoordinator(
        store: DecisionStore.shared,
        attention: AppStore.shared,
        windows: { NSApp.windows.compactMap { $0 as? NostromoWindow } },
        makeSheet: { decision, onAnswer in
            let choices = decision.choices.map { DecisionSheet.Choice(id: $0.id, label: $0.label, detail: $0.detail) }
            return DecisionSheet(
                requestId: decision.requestId,
                prompt: Self.promptNamingAskingAgent(decision),
                detail: decision.detail,
                choices: choices,
                store: DecisionStore.shared,
                resolution: DecisionStore.shared.resolution(for: decision.requestId),
                onAnswer: onAnswer
            )
        },
        sendAnswer: { AppStore.shared.answerDecision(requestId: $0, choiceId: $1) }
    )

    private init() {}

    func start() {
        AppStore.shared.decisionRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] decision in self?.coordinator.present(decision) }
            .store(in: &cancellables)

        AppStore.shared.decisionResolutions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolved in self?.coordinator.handleResolved(resolved) }
            .store(in: &cancellables)

        // Any window's focus changing can make a better home for an outstanding
        // sheet (the operator switched some window to the asking focus). Deferred
        // one turn so the switch has fully landed.
        AppStore.shared.$activeFocusSessionTag
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.coordinator.reevaluate() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        // Visibility changes: a window became key or visible, was
        // (de)miniaturized or moved to another screen, the app was unhidden or
        // activated, or the active Space changed. All just re-evaluate.
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeScreenNotification,
                     NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(windowStateChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    // MARK: - Private

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NostromoWindow else { return }
        coordinator.windowWillClose(window)
    }

    /// Only the coordinator's own tier rule decides whether anything moves, so
    /// this never needs to look at which window changed.
    @objc private func windowStateChanged(_ notification: Notification) {
        coordinator.reevaluate()
    }

    /// The sheet may land on a window showing some other focus, so its text
    /// always says who is asking.
    private static func promptNamingAskingAgent(_ decision: PendingDecision) -> String {
        let focus = FocusStore.shared.focuses.first { $0.sessionTag == decision.tag }
        let name = focus?.displayName ?? decision.tag.capitalized
        return "From \(name)\n\(decision.prompt)"
    }
}

// MARK: - Real windows and sheets

extension DecisionSheet: DecisionSheetControlling {}

extension NostromoWindow: DecisionHostWindow {

    var isVisibleNow: Bool {
        isOnActiveSpace && occlusionState.contains(.visible) && !isMiniaturized
    }

    var isKeyNow: Bool { isKeyWindow }

    var frontOrder: Int { NSApp.orderedWindows.firstIndex(of: self) ?? Int.max }

    var activeFocusTag: String? { (contentView as? MainLayout)?.activeFocusTag }

    func showDecisionSheet(_ sheet: DecisionSheetControlling, completion: @escaping () -> Void) {
        guard let sheetWindow = (sheet as? DecisionSheet)?.window else {
            completion()
            return
        }
        beginSheet(sheetWindow) { _ in completion() }
    }
}
