import Foundation

// MARK: - Seams

/// What the placement controller needs from a window. `NostromoWindow` conforms;
/// tests use a fake so nothing needs a real display.
protocol PlacementWindowing: AnyObject {
    /// Stable UUID of the display `window.screen` is on now (nil if offscreen).
    var currentDisplayUUID: String? { get }
    var isFullScreen: Bool { get }
    /// Any NostromoWindow (this one or a sibling) is mid enter/exit transition.
    /// The controller never starts a toggle on top of one.
    var isAnyTransitionInFlight: Bool { get }
    /// Frame + screen description for the placement log.
    var placementSnapshot: String { get }
    /// `setFrame(display.placementFrame, display: false)`.
    func place(on display: DisplayInfo)
    /// `toggleFullScreen(nil)` — enter OR exit, depending on current state.
    func toggleFullScreenNow()
    /// A display configuration change is in progress (the guard `NostromoWindow`'s own
    /// re-entry uses). Nothing frame- or toggle-related runs while it is set.
    var isDisplayChangePending: Bool { get }
    /// The controller's phase changed; the window mirrors it (frame-constraint scope).
    func placementPhaseChanged(_ phase: PlacementPhase)
}

extension PlacementWindowing {
    var isDisplayChangePending: Bool { false }
    func placementPhaseChanged(_ phase: PlacementPhase) {}
}

/// Window → controller notifications (forwarded by `NostromoWindow`'s delegate methods).
enum WindowLifecycleEvent: Equatable {
    case didChangeScreen
    case willEnterFullScreen
    case didEnterFullScreen
    case willExitFullScreen
    case didExitFullScreen
    case didFailToEnterFullScreen
    /// Fired right before `NostromoWindow`'s own delayed re-entry toggle: the last
    /// chance to verify the window is on its display.
    case willReenterFullScreen
}

// MARK: - WindowPlacementController

/// Executes `PlacementMachine` actions against one window: place on the bound
/// display, verify via `didChangeScreen` (with a bounded timeout, not blind
/// sleeps), enter full-screen, verify again, one bounded wrong-display retry.
///
/// It never removes or loosens `NostromoWindow`'s own safeguards (delayed
/// re-entry, startup retry, sleep/wake handling): it only decides WHEN the first
/// `toggleFullScreen` fires and whether the Space landed on the right display.
final class WindowPlacementController {

    static let verifyTimeout: TimeInterval = 1.0
    static let rehomeGrace: TimeInterval = 10.0
    static let finalSnapshotDelay: TimeInterval = 1.0
    /// A controller-driven exit never runs inside AppKit's enter/exit callbacks or
    /// a notification handler: it waits this runway (NostromoWindow's header: crash
    /// paths #3/#4 come from toggling while a controller is still cleaning up)…
    static let exitRunway: TimeInterval = 3.0
    /// …and exits for different windows are spread out by this much, one at a time.
    static let exitSpacing: TimeInterval = 1.5
    /// Bounded wait for in-flight transitions before a toggle: poll interval × polls.
    static let gatePollInterval: TimeInterval = 0.5
    static let gateMaxPolls = 10
    /// A screen-parameters change this recent blocks exits and re-placement (re-armed).
    static let screenChangeSettleInterval: TimeInterval = 2.0
    /// The post-exit re-placement runs this long after `didExitFullScreen` (never inside
    /// the callback)…
    static let postExitPlaceDelay: TimeInterval = 1.0
    /// …and re-polls at most this many times, so it always lands before the window's
    /// own re-entry (`NostromoWindow.reentryDelay`).
    static let postExitPlaceMaxPolls = 3
    /// Exits scheduled but not yet fired, app-wide (drives `exitSpacing`).
    private static var pendingExits = 0

    static func resetPendingExitsForTesting() { pendingExits = 0 }

    let targetUUID: String
    private(set) var machine: PlacementMachine
    var phase: PlacementPhase { machine.phase }

    private weak var window: PlacementWindowing?
    private let screens: ScreenProviding
    private let scheduler: PlacementScheduler
    private let emit: (_ message: String, _ warning: Bool) -> Void
    private var rehomeGeneration = 0
    /// True for `screenChangeSettleInterval` after the last screen-parameters change.
    private var settling = false
    private var settleGeneration = 0

    init(window: PlacementWindowing, targetUUID: String, screens: ScreenProviding,
         scheduler: PlacementScheduler = MainQueueScheduler.shared,
         emit: @escaping (_ message: String, _ warning: Bool) -> Void) {
        self.window = window
        self.targetUUID = targetUUID
        self.screens = screens
        self.scheduler = scheduler
        self.emit = emit
        self.machine = PlacementMachine(targetUUID: targetUUID)
    }

    // MARK: Inputs

    /// Start verified placement (call at the window's stagger time).
    func begin() {
        guard let window else { return }
        emit("beginPlacement: \(window.placementSnapshot)", false)
        window.placementPhaseChanged(machine.phase)
        send(.begin(currentUUID: window.currentDisplayUUID, targetPresent: targetPresent))
    }

    func windowEvent(_ event: WindowLifecycleEvent) {
        guard let window else { return }
        emit("\(event): \(window.placementSnapshot)", false)
        switch event {
        case .didChangeScreen:
            send(.screenChanged(currentUUID: window.currentDisplayUUID, targetPresent: targetPresent))
        case .willEnterFullScreen:
            break
        case .didEnterFullScreen:
            send(.didEnterFullScreen(currentUUID: window.currentDisplayUUID))
        case .willExitFullScreen:
            send(.willExitFullScreen)
        case .didExitFullScreen:
            send(.didExitFullScreen)
        case .didFailToEnterFullScreen:
            send(.didFailToEnterFullScreen)
        case .willReenterFullScreen:
            verifyBeforeReentry()
        }
    }

    /// `NSApplication.didChangeScreenParametersNotification` arrived.
    func displaysReconfigured() {
        guard let window else { return }
        beginSettling()
        send(.displaysReconfigured(currentUUID: window.currentDisplayUUID, targetPresent: targetPresent))
    }

    // MARK: Private

    private var targetPresent: Bool { screens.displays.contains { $0.uuid == targetUUID } }

    private func send(_ event: PlacementEvent) {
        let before = machine.phase
        let actions = machine.handle(event)
        if machine.phase != before {
            emit("phase \(before) → \(machine.phase)", false)
            window?.placementPhaseChanged(machine.phase)
            if machine.phase == .fullScreen { scheduleFinalSnapshot() }
        }
        for action in actions { perform(action) }
    }

    /// First `toggleFullScreen`: waits (bounded) for in-flight transitions to drain.
    /// Past the bound it proceeds — launch always toggled unconditionally before.
    private func attemptEnter(pollsLeft: Int) {
        guard let window, machine.phase == .enteringFullScreen, !window.isFullScreen else { return }
        if window.isAnyTransitionInFlight, pollsLeft > 0 {
            scheduler.schedule(after: Self.gatePollInterval) { [weak self] in
                self?.attemptEnter(pollsLeft: pollsLeft - 1)
            }
            return
        }
        if window.isAnyTransitionInFlight {
            emit("WARNING: transition still in flight after bounded wait — toggling anyway", true)
        }
        emit("before toggleFullScreen: \(window.placementSnapshot)", false)
        window.toggleFullScreenNow()
    }

    /// Wrong-display exit. The decision to exit was made when an event arrived, 3 s or
    /// more ago; the topology may have moved since, so EVERYTHING is re-verified now:
    /// a window already on its display, a vanished target, or a display change still
    /// settling drops the exit (a needless exit/re-enter during a display
    /// reconfiguration is exactly crash paths #2/#3 in NostromoWindow). If in-flight
    /// transitions never drain it abandons — toggling into one crashed AppKit.
    private func attemptExit(pollsLeft: Int) {
        guard let window, machine.phase == .exitingForRetry else { return }
        guard window.isFullScreen else {
            // A real exit may be mid-transition (the style mask can lose `.fullScreen`
            // before `didExitFullScreen` arrives): then AppKit's own callback will drive
            // the machine, and a synthetic one now would run the post-exit work early.
            // Wait (bounded) for the transition to drain; only a window with nothing in
            // flight has nothing to exit, no didExit coming, and needs the machine advanced.
            if window.isAnyTransitionInFlight {
                guard pollsLeft > 0 else {
                    send(.exitAbandoned)
                    return
                }
                scheduler.schedule(after: Self.gatePollInterval) { [weak self] in
                    self?.attemptExit(pollsLeft: pollsLeft - 1)
                }
                return
            }
            send(.didExitFullScreen)
            return
        }
        guard targetPresent else {
            emit("exit dropped: target display \(targetUUID) no longer attached", true)
            send(.exitDropped)
            return
        }
        if window.currentDisplayUUID == targetUUID {
            emit("exit dropped: window is already on its target display", false)
            send(.exitDropped)
            return
        }
        if window.isDisplayChangePending || settling {
            guard pollsLeft > 0 else {
                emit("exit dropped: display change still settling after the bounded wait", true)
                send(.exitDropped)
                return
            }
            scheduler.schedule(after: Self.gatePollInterval) { [weak self] in
                self?.attemptExit(pollsLeft: pollsLeft - 1)
            }
            return
        }
        if window.isAnyTransitionInFlight {
            guard pollsLeft > 0 else {
                send(.exitAbandoned)
                return
            }
            scheduler.schedule(after: Self.gatePollInterval) { [weak self] in
                self?.attemptExit(pollsLeft: pollsLeft - 1)
            }
            return
        }
        emit("exiting full-screen to re-home: \(window.placementSnapshot)", true)
        window.toggleFullScreenNow()
    }

    /// Re-place after a wrong-display exit, a moment AFTER `didExitFullScreen`, with
    /// the same fire-time checks. Never toggles; skipping is safe because the window's
    /// own re-entry re-verifies (`verifyBeforeReentry`).
    private func attemptPostExitPlace(pollsLeft: Int) {
        guard let window, !window.isFullScreen, targetPresent else { return }
        if window.currentDisplayUUID == targetUUID {
            emit("post-exit placement skipped: window already on target", false)
            return
        }
        if window.isAnyTransitionInFlight || window.isDisplayChangePending || settling {
            guard pollsLeft > 0 else {
                emit("post-exit placement skipped: transition / display change still in progress", true)
                return
            }
            scheduler.schedule(after: Self.gatePollInterval) { [weak self] in
                self?.attemptPostExitPlace(pollsLeft: pollsLeft - 1)
            }
            return
        }
        perform(.place)
    }

    /// Last check before `NostromoWindow`'s own re-entry toggle: if the window slipped
    /// off its display, put it back so the Space lands on the right one. Never toggles.
    private func verifyBeforeReentry() {
        guard let window, !window.isFullScreen, targetPresent,
              window.currentDisplayUUID != targetUUID else { return }
        // The same fire-time guards as every other frame change here: a `setFrame` during
        // a transition or a display reconfiguration is what this app's crash paths are made of.
        // Skipping is safe: the window's own re-entry follows either way.
        if window.isAnyTransitionInFlight || window.isDisplayChangePending || settling {
            emit("before re-entry: window not on target but a transition / display change is in progress — not re-placing", true)
            return
        }
        emit("before re-entry: window not on target — re-placing", true)
        perform(.place)
    }

    private func beginSettling() {
        settling = true
        settleGeneration += 1
        let generation = settleGeneration
        scheduler.schedule(after: Self.screenChangeSettleInterval) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            self.settling = false
        }
    }

    /// Settled-state record: the FINAL `window.screen` a moment after entry.
    private func scheduleFinalSnapshot() {
        scheduler.schedule(after: Self.finalSnapshotDelay) { [weak self] in
            guard let self, let window = self.window else { return }
            let ok = window.currentDisplayUUID == self.targetUUID
            self.emit("FINAL (\(ok ? "on target" : "NOT on target")): \(window.placementSnapshot)", !ok)
        }
    }

    private func perform(_ action: PlacementAction) {
        switch action {
        case let .log(message):
            emit(message, message.hasPrefix("WARNING") || message.contains("giving up"))

        case .place:
            guard let window else { return }
            guard let display = screens.displays.first(where: { $0.uuid == targetUUID }) else {
                emit("place: target display \(targetUUID) not attached", true)
                return
            }
            emit("place: requested=\(DisplayInfo.fmt(display.placementFrame)) on \(display.localizedName)", false)
            window.place(on: display)
            emit("placed: \(window.placementSnapshot)", false)
            // Re-check on the next turn: `window.screen` may already be right (no
            // didChangeScreen will fire) or still catching up.
            scheduler.schedule(after: 0) { [weak self] in
                guard let self, let window = self.window else { return }
                self.send(.screenChanged(currentUUID: window.currentDisplayUUID, targetPresent: self.targetPresent))
            }

        case .schedulePlaceAfterExit:
            scheduler.schedule(after: Self.postExitPlaceDelay) { [weak self] in
                self?.attemptPostExitPlace(pollsLeft: Self.postExitPlaceMaxPolls)
            }

        case let .scheduleVerifyTimeout(attempt):
            scheduler.schedule(after: Self.verifyTimeout) { [weak self] in
                guard let self, let window = self.window else { return }
                self.send(.verifyTimeout(attempt: attempt, currentUUID: window.currentDisplayUUID))
            }

        case .enterFullScreen:
            scheduler.schedule(after: 0) { [weak self] in
                self?.attemptEnter(pollsLeft: Self.gateMaxPolls)
            }

        case .exitFullScreen:
            // Deferred and serialized: never from inside a delegate callback or the
            // screen-parameters handler, never two windows in the same turn.
            let delay = Self.exitRunway + Self.exitSpacing * Double(Self.pendingExits)
            Self.pendingExits += 1
            scheduler.schedule(after: delay) { [weak self] in
                Self.pendingExits = max(0, Self.pendingExits - 1)
                self?.attemptExit(pollsLeft: Self.gateMaxPolls)
            }

        case .scheduleRehomeExpiry:
            rehomeGeneration += 1
            let generation = rehomeGeneration
            scheduler.schedule(after: Self.rehomeGrace) { [weak self] in
                guard let self, self.rehomeGeneration == generation else { return }
                self.send(.rehomeWindowExpired)
            }
        }
    }
}
