import CoreGraphics
import Foundation

// MARK: - Fingerprint

/// What "the display topology" means for deciding whether anything needs doing:
/// each attached display's key, frame and backing scale, in a canonical order.
///
/// `visibleFrame` is deliberately NOT part of it (a Dock or menu-bar auto-hide
/// toggle changes it and is not a topology change), and neither is the display
/// name or the main flag (a change of main always moves a frame).
struct DisplayTopologyFingerprint: Equatable {
    struct Entry: Equatable {
        let uuid: String
        let frame: CGRect
        let scale: CGFloat
    }

    let entries: [Entry]

    init(displays: [DisplayInfo]) {
        entries = displays
            .map { Entry(uuid: $0.uuid, frame: $0.frame, scale: $0.backingScaleFactor) }
            .sorted { lhs, rhs in
                if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
                let (l, r) = (lhs.frame, rhs.frame)
                return [l.origin.x, l.origin.y, l.width, l.height]
                    .lexicographicallyPrecedes([r.origin.x, r.origin.y, r.width, r.height])
            }
    }
}

// MARK: - Decision (pure)

/// The pure decision layer for `didChangeScreenParameters`: remembers the last
/// handled topology and the windows waiting out their close grace, and turns
/// "here is what is attached and bound now" into one `Decision`.
///
/// macOS posts the notification in bursts and with no change at all (an AirPlay
/// display flapping, wake, Space reconfiguration). Acting on each one re-homes
/// every full-screen window and recreates windows for displays that come right
/// back, which blanks the panes. So:
///   - an unchanged topology does nothing, except re-home a window macOS moved off its display;
///   - a changed one gives each surviving window ONE re-home grant;
///   - a vanished display's window is closed only if the display is still gone
///     after a grace period (the caller schedules `PendingClose`s).
struct DisplayTopologyState {

    /// A close waiting out its grace. `token` makes a stale timer (the display
    /// returned and vanished again) unable to close early or twice.
    struct PendingClose: Equatable {
        let uuid: String
        let token: Int
    }

    struct Pass: Equatable {
        /// Keys of surviving windows that get a re-home grant (sorted): all of them when
        /// the fingerprint changed, only the drifted ones when it did not.
        var rehome: [String]
        /// Attached displays with no window: open one (new, or reappeared after a close).
        var open: [DisplayInfo]
        /// Newly vanished displays: close the window after the grace unless it returns.
        var scheduleClose: [PendingClose]
        /// Displays that returned while waiting out the grace: their window stays.
        var cancelledClose: [String]
    }

    enum Decision: Equatable {
        /// Nothing to do. `shouldLog` is true for the first of a run of unchanged
        /// events and then only occasionally, so a flapping system does not flood the log.
        case unchanged(shouldLog: Bool)
        case pass(Pass)
    }

    /// Log the first unchanged event of a run, then every this-many-th.
    static let unchangedLogInterval = 50

    private(set) var lastHandled: DisplayTopologyFingerprint?
    private var pending: [String: Int] = [:]
    /// Keys whose close was ordered and whose window is not yet unbound: never
    /// scheduled again, so a host that is slow to unbind cannot be told to close twice.
    /// uuid -> token of the `PendingClose` that ordered the close.
    private var closing: [String: Int] = [:]
    private var nextToken = 0
    private var unchangedRun = 0

    /// Seed with the topology the launch windows were opened for, so the first
    /// notification after launch is not mistaken for a change.
    mutating func recordHandled(_ displays: [DisplayInfo]) {
        lastHandled = DisplayTopologyFingerprint(displays: displays)
        unchangedRun = 0
    }

    /// `drifted`: bound keys whose window is currently on a different display than its
    /// own (macOS moved it). They get a re-home grant even when the topology is unchanged.
    mutating func reconcile(attached: [DisplayInfo], bound: Set<String>,
                            drifted: Set<String> = []) -> Decision {
        let fingerprint = DisplayTopologyFingerprint(displays: attached)
        let changed = fingerprint != lastHandled
        let plan = DisplayReconciler.plan(attached: attached, boundUUIDs: bound)
        let attachedUUIDs = Set(attached.map(\.uuid))

        // A window that is gone by other means must not leave a pending entry that
        // would stop a later vanish of the same key from ever being scheduled.
        for uuid in pending.keys where !bound.contains(uuid) { pending.removeValue(forKey: uuid) }

        closing = closing.filter { bound.contains($0.key) && !attachedUUIDs.contains($0.key) }

        let cancelled = pending.keys.filter { attachedUUIDs.contains($0) }.sorted()
        for uuid in cancelled { pending.removeValue(forKey: uuid) }

        // A key already waiting out its grace is not scheduled again ("removed" twice).
        var scheduled: [PendingClose] = []
        for uuid in plan.toClose where pending[uuid] == nil && closing[uuid] == nil {
            nextToken += 1
            pending[uuid] = nextToken
            scheduled.append(PendingClose(uuid: uuid, token: nextToken))
        }

        // A changed topology re-homes every survivor. An unchanged one re-homes only the
        // windows macOS moved off their display (a display that vanished and returned
        // inside the settle leaves its window on a neighbour with an equal fingerprint).
        let survivors = bound.subtracting(plan.toClose)
        let rehome = (changed ? survivors : survivors.intersection(drifted)).sorted()
        lastHandled = fingerprint

        if !changed, plan.toOpen.isEmpty, scheduled.isEmpty, cancelled.isEmpty, rehome.isEmpty {
            unchangedRun += 1
            return .unchanged(shouldLog: unchangedRun == 1 || unchangedRun % Self.unchangedLogInterval == 0)
        }
        unchangedRun = 0
        return .pass(Pass(rehome: rehome, open: plan.toOpen, scheduleClose: scheduled, cancelledClose: cancelled))
    }

    /// The grace for `close` elapsed. True exactly once, and only if that close is
    /// still the pending one and its display is still gone.
    mutating func graceExpired(_ close: PendingClose, displayStillAttached: Bool) -> Bool {
        guard pending[close.uuid] == close.token else { return false }
        pending.removeValue(forKey: close.uuid)
        guard !displayStillAttached else { return false }
        closing[close.uuid] = close.token
        return true
    }

    /// The host did not close the window after `graceExpired` returned true (the
    /// display came back, the window is already gone). Forgets the close so the next
    /// `reconcile` that still finds the display absent schedules a fresh grace.
    mutating func closeAborted(_ close: PendingClose) {
        guard closing[close.uuid] == close.token else { return }
        closing.removeValue(forKey: close.uuid)
    }

    /// True while `close` is the close that `graceExpired` ordered and nothing superseded it.
    func isCloseCurrent(_ close: PendingClose) -> Bool {
        closing[close.uuid] == close.token
    }

    /// A close for `uuid` is waiting out its grace or has been ordered and not yet unbound.
    func hasOutstandingClose(for uuid: String) -> Bool {
        pending[uuid] != nil || closing[uuid] != nil
    }
}

// MARK: - Coordinator (debounce + grace timing)

/// Drives `DisplayTopologyState` from raw notifications: coalesces a burst into
/// one pass after a settle delay and times the close grace, both through the
/// injected scheduler (no wall clock). The window work itself is the host's.
///
/// Nothing runs inside `displaysChanged()`: every pass starts from the scheduler,
/// never from inside AppKit's notification delivery, so a notification posted
/// while the host is closing a window cannot re-enter the handler.
final class DisplayTopologyCoordinator {

    /// The window-side effects. All called on the thread the scheduler fires on.
    struct Host {
        var attachedDisplays: () -> [DisplayInfo]
        /// Keys that currently have a window.
        var boundUUIDs: () -> Set<String>
        /// A changed topology is about to be acted on.
        var topologyChanged: () -> Void
        var rehome: (_ uuid: String) -> Void
        /// Open a window for each display (new or reappeared).
        var openWindows: (_ displays: [DisplayInfo]) -> Void
        /// A vanished display stayed gone for the whole grace: close its window.
        var closeWindow: (_ uuid: String) -> Void
        /// A pass that did something has finished.
        var passFinished: () -> Void
        var log: (_ message: String) -> Void
        /// Keys whose window is on a different display than its own right now.
        var driftedUUIDs: () -> Set<String> = { [] }
        /// The window is (true) or is no longer (false) doomed: a close is waiting out
        /// its grace or has been ordered. A doomed window must start no full-screen
        /// entry, retry or re-entry.
        var setPendingRemoval: (_ uuid: String, _ pending: Bool) -> Void = { _, _ in }
        /// The window bound to this key (and only that one) is mid enter/exit transition.
        var isWindowTransitioning: (_ uuid: String) -> Bool = { _ in false }
    }

    static let defaultSettleDelay: TimeInterval = 0.5
    static let defaultCloseGrace: TimeInterval = 5
    /// A burst that never goes quiet is handled anyway after this long, so a steady
    /// stream of notifications cannot starve the handler.
    static let defaultMaxSettleDelay: TimeInterval = 3
    /// A close that finds its own window mid-transition waits this long, at most
    /// `defaultCloseDeferralLimit` times, then closes anyway.
    static let defaultCloseDeferralInterval: TimeInterval = 0.5
    static let defaultCloseDeferralLimit = 6

    private let scheduler: PlacementScheduler
    private let host: Host
    private let settleDelay: TimeInterval
    private let closeGrace: TimeInterval
    private let maxSettleDelay: TimeInterval
    private let closeDeferralInterval: TimeInterval
    private let closeDeferralLimit: Int
    private var state = DisplayTopologyState()
    private var generation = 0
    private var burstOpen = false
    private var burstToken = 0
    /// Keys the host was told are pending removal and not yet told otherwise.
    private var pendingRemoval: Set<String> = []

    init(scheduler: PlacementScheduler, host: Host,
         settleDelay: TimeInterval = DisplayTopologyCoordinator.defaultSettleDelay,
         closeGrace: TimeInterval = DisplayTopologyCoordinator.defaultCloseGrace,
         maxSettleDelay: TimeInterval = DisplayTopologyCoordinator.defaultMaxSettleDelay,
         closeDeferralInterval: TimeInterval = DisplayTopologyCoordinator.defaultCloseDeferralInterval,
         closeDeferralLimit: Int = DisplayTopologyCoordinator.defaultCloseDeferralLimit) {
        self.scheduler = scheduler
        self.host = host
        self.settleDelay = settleDelay
        self.closeGrace = closeGrace
        self.maxSettleDelay = maxSettleDelay
        self.closeDeferralInterval = closeDeferralInterval
        self.closeDeferralLimit = closeDeferralLimit
    }

    /// The launch opened windows for `displays`: that is the handled topology.
    func recordHandled(_ displays: [DisplayInfo]) {
        state.recordHandled(displays)
    }

    /// `didChangeScreenParameters` (any number of times in a burst).
    func displaysChanged() {
        generation += 1
        let armed = generation
        scheduler.schedule(after: settleDelay) { [weak self] in
            guard let self, self.generation == armed else { return }
            self.handlePass()
        }
        if !burstOpen {
            burstOpen = true
            burstToken += 1
            let burst = burstToken
            scheduler.schedule(after: maxSettleDelay) { [weak self] in
                guard let self, self.burstOpen, self.burstToken == burst else { return }
                self.handlePass()
            }
        }
    }

    private func handlePass() {
        burstOpen = false
        generation += 1  // any settle timer still queued for this burst is now stale
        let attached = host.attachedDisplays()
        let decision = state.reconcile(attached: attached, bound: host.boundUUIDs(), drifted: host.driftedUUIDs())
        // Before any grant below: a window whose display returned must be live again.
        syncPendingRemoval()
        switch decision {
        case .unchanged(let shouldLog):
            if shouldLog { host.log("display topology unchanged (\(attached.count) display(s)) — nothing to do") }

        case .pass(let pass):
            host.topologyChanged()
            for uuid in pass.cancelledClose {
                host.log("display \(uuid) returned within the grace — keeping its window")
            }
            pass.rehome.forEach(host.rehome)
            if !pass.open.isEmpty { host.openWindows(pass.open) }
            for close in pass.scheduleClose {
                host.log("display \(close.uuid) gone — closing its window in \(Int(closeGrace)) s unless it returns")
                pendingRemoval.insert(close.uuid)
                host.setPendingRemoval(close.uuid, true)
                scheduler.schedule(after: closeGrace) { [weak self] in self?.graceExpired(close) }
            }
            host.passFinished()
        }
    }

    private func graceExpired(_ close: DisplayTopologyState.PendingClose) {
        let stillAttached = host.attachedDisplays().contains { $0.uuid == close.uuid }
        if state.graceExpired(close, displayStillAttached: stillAttached) {
            attemptClose(close, deferralsLeft: closeDeferralLimit)
        } else {
            syncPendingRemoval()
        }
    }

    /// Close the window of a display that stayed gone for the whole grace, unless that
    /// is no longer right. Every path that does not close tells the state
    /// (`closeAborted`), or the key would stay "being closed" and never be scheduled again.
    private func attemptClose(_ close: DisplayTopologyState.PendingClose, deferralsLeft: Int) {
        guard state.isCloseCurrent(close) else { return }   // superseded by a newer close
        let uuid = close.uuid
        guard host.boundUUIDs().contains(uuid) else {
            abortClose(close, reason: "its window is already gone")
            return
        }
        guard !host.attachedDisplays().contains(where: { $0.uuid == uuid }) else {
            abortClose(close, reason: "the display returned")
            return
        }
        // Closing mid-transition is the `_NSExitFullScreenTransitionController` crash path:
        // wait (bounded) for THIS window's transition. A sibling's does not matter here.
        if host.isWindowTransitioning(uuid), deferralsLeft > 0 {
            scheduler.schedule(after: closeDeferralInterval) { [weak self] in
                self?.attemptClose(close, deferralsLeft: deferralsLeft - 1)
            }
            return
        }
        host.closeWindow(uuid)
    }

    private func abortClose(_ close: DisplayTopologyState.PendingClose, reason: String) {
        state.closeAborted(close)
        host.log("not closing the window of display \(close.uuid): \(reason)")
        syncPendingRemoval()
    }

    /// Tells the host a window is no longer doomed once no close is outstanding for it.
    private func syncPendingRemoval() {
        for uuid in pendingRemoval.sorted() where !state.hasOutstandingClose(for: uuid) {
            pendingRemoval.remove(uuid)
            host.setPendingRemoval(uuid, false)
        }
    }
}

// MARK: - Teardown order

/// What `AppDelegate` does to a window whose display stayed gone, as ordered steps.
/// The ORDER is the contract: the key is unbound BEFORE any AppKit call, because
/// `close()` can synchronously post didChangeScreenParameters, and a handler that
/// still saw the key bound would act on the window a second time.
///
/// There is deliberately no step that clears `.fullScreen` from the window's style
/// mask: AppKit (macOS 27) throws when that happens outside a full-screen transition.
/// The window is closed as-is, after its own transition has ended (the coordinator's
/// `attemptClose` waits for that), which is what keeps the
/// `_NSExitFullScreenTransitionController` crash path closed.
enum VanishedWindowTeardown {
    struct Steps {
        var unbindKey: () -> Void
        var dropController: () -> Void
        var removeFromWindows: () -> Void
        /// App state that depends on the unbind (e.g. "was that the last window") and logging.
        var afterUnbind: () -> Void
        /// Orphan flag, no animation, no lifecycle handler.
        var prepareWindow: () -> Void
        var close: () -> Void
    }

    static func run(_ steps: Steps) {
        steps.unbindKey()
        steps.dropController()
        steps.removeFromWindows()
        steps.afterUnbind()
        steps.prepareWindow()
        steps.close()
    }
}
