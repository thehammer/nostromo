import Foundation

// MARK: - PlacementMachine
//
// Pure decision logic for "put this window on its display, verify, THEN enter
// full-screen, and verify again". No AppKit, no timers: it consumes events and
// returns actions, so it is unit-tested with plain values.
//
// There is no public API to pin a Space to a display. A full-screen Space is
// created on the display the window is on when `toggleFullScreen` fires, so the
// strategy is: place deterministically, verify `window.screen`, only then
// toggle; after the transition verify again; on a wrong display do ONE bounded
// retry (exit, re-place, let `NostromoWindow`'s own re-entry run) and then give
// up rather than loop. Every bound below exists because this app has a history
// of AppKit aborts around full-screen transitions.

enum PlacementPhase: Equatable {
    case idle
    /// Window placed on the target; waiting for `window.screen` to confirm.
    case placing(attempt: Int)
    /// Verified (or placement budget exhausted); full-screen requested / pending.
    case enteringFullScreen
    /// Exiting full-screen because the Space landed on the wrong display.
    case exitingForRetry
    /// Full-screen entered on the target display. Terminal until a drift event.
    case fullScreen
    /// Gave up (bounded). Window stays wherever it is; never loops.
    case gaveUp
}

enum PlacementEvent: Equatable {
    /// Start placement. `currentUUID` is the display UUID of `window.screen` now.
    case begin(currentUUID: String?, targetPresent: Bool)
    /// `NSWindow.didChangeScreenNotification` (or a synchronous re-check after a
    /// placement). `targetPresent`: the bound display is still attached.
    case screenChanged(currentUUID: String?, targetPresent: Bool)
    /// A bounded verification wait elapsed. Carries the attempt it was armed for;
    /// stale timeouts (attempt mismatch / phase moved on) are ignored.
    case verifyTimeout(attempt: Int, currentUUID: String?)
    case didEnterFullScreen(currentUUID: String?)
    case didFailToEnterFullScreen
    /// AppKit began an exit we did not ask for (user, system, wake). Ignored for
    /// drift purposes until the window's own re-entry completes.
    case willExitFullScreen
    case didExitFullScreen
    /// A deferred controller-driven exit could not run (a transition stayed in
    /// flight for the whole bounded wait): give up rather than toggle into it.
    case exitAbandoned
    /// `NSApplication.didChangeScreenParametersNotification`. Grants the window one
    /// re-home retry (the display topology changed, so macOS may have moved it).
    case displaysReconfigured(currentUUID: String?, targetPresent: Bool)
    /// The re-home grant from `displaysReconfigured` timed out: a later,
    /// user-driven move of the window is no longer fought.
    case rehomeWindowExpired
}

enum PlacementAction: Equatable {
    /// `setFrame` the window to the target display's `placementFrame`.
    case place
    /// Arm a bounded wait; deliver `.verifyTimeout(attempt:…)` when it elapses.
    case scheduleVerifyTimeout(attempt: Int)
    /// Request `toggleFullScreen` (the executor must still guard `!isFullScreen`).
    case enterFullScreen
    /// Leave full-screen (`toggleFullScreen`), for the wrong-display retry.
    case exitFullScreen
    /// Arm the re-home expiry; deliver `.rehomeWindowExpired` when it elapses.
    case scheduleRehomeExpiry
    case log(String)
}

struct PlacementMachine {
    static let maxPlacementAttempts = 3
    static let maxFullScreenRetries = 1
    /// Hard cap on wrong-display exits over the window's whole life, however many
    /// screen-parameter notifications re-arm `retryBudget`.
    static let maxLifetimeRetries = 3

    let targetUUID: String
    private(set) var phase: PlacementPhase = .idle
    /// Remaining wrong-display retries (exit → re-place → re-enter).
    private(set) var retryBudget = PlacementMachine.maxFullScreenRetries
    private(set) var retriesUsed = 0

    init(targetUUID: String) { self.targetUUID = targetUUID }

    mutating func handle(_ event: PlacementEvent) -> [PlacementAction] {
        switch event {

        case let .begin(current, targetPresent):
            guard phase == .idle else { return [.log("begin ignored in \(phase)")] }
            guard targetPresent else {
                phase = .gaveUp
                return [.log("target display \(targetUUID) not attached at begin — not placing")]
            }
            if current == targetUUID {
                phase = .enteringFullScreen
                return [.log("window already on target display — entering full-screen"), .enterFullScreen]
            }
            phase = .placing(attempt: 1)
            return [.log("window on \(current ?? "nil"), target \(targetUUID) — placing (attempt 1)"),
                    .place, .scheduleVerifyTimeout(attempt: 1)]

        case let .screenChanged(current, targetPresent):
            switch phase {
            case .placing:
                guard current == targetUUID else {
                    return [.log("didChangeScreen → \(current ?? "nil") (not target yet)")]
                }
                phase = .enteringFullScreen
                return [.log("placement verified on target — entering full-screen"), .enterFullScreen]
            case .fullScreen:
                return rehomeIfDrifted(current: current, targetPresent: targetPresent, cause: "didChangeScreen")
            default:
                return []
            }

        case let .verifyTimeout(attempt, current):
            guard case let .placing(n) = phase, n == attempt else { return [] }
            if current == targetUUID {
                phase = .enteringFullScreen
                return [.log("placement verified on target (timeout re-check) — entering full-screen"), .enterFullScreen]
            }
            if n < Self.maxPlacementAttempts {
                phase = .placing(attempt: n + 1)
                return [.log("still on \(current ?? "nil") after attempt \(n) — re-placing (attempt \(n + 1))"),
                        .place, .scheduleVerifyTimeout(attempt: n + 1)]
            }
            phase = .enteringFullScreen
            return [.log("WARNING: window not on target after \(n) placement attempts — entering full-screen anyway"),
                    .enterFullScreen]

        case let .didEnterFullScreen(current):
            switch phase {
            case .enteringFullScreen, .fullScreen, .placing, .exitingForRetry:
                // `.placing`/`.exitingForRetry` here means AppKit finished a transition we
                // did not drive (the window's own re-entry): judge it the same way.
                if current == targetUUID {
                    phase = .fullScreen
                    return [.log("full-screen entered on target display — OK")]
                }
                return retryOrGiveUp(current: current, cause: "full-screen entered on wrong display")
            case .gaveUp, .idle:
                return []
            }

        case .didFailToEnterFullScreen:
            // NostromoWindow owns the (bounded) retry; stay in `.enteringFullScreen`
            // so the eventual `didEnterFullScreen` is still verified.
            return [.log("didFailToEnterFullScreen — NostromoWindow's bounded retry owns this")]

        case .willExitFullScreen:
            if phase == .fullScreen {
                // Exit already in flight: judge on the window's own re-entry, and
                // never start a second transition on top of it.
                phase = .enteringFullScreen
                return [.log("full-screen exit began — awaiting window's own re-entry")]
            }
            return []

        case .exitAbandoned:
            guard phase == .exitingForRetry else { return [] }
            phase = .gaveUp
            return [.log("exit for re-home could not run (transition stayed in flight) — giving up")]

        case .didExitFullScreen:
            switch phase {
            case .exitingForRetry:
                // Re-place now; NostromoWindow's own 3 s post-exit re-entry then
                // enters full-screen on the right display. We do NOT toggle.
                phase = .enteringFullScreen
                return [.log("exited full-screen for retry — re-placing, window's own re-entry follows"), .place]
            case .fullScreen:
                // User / system exit; the window re-enters on its own. Re-judge on entry.
                phase = .enteringFullScreen
                return [.log("full-screen exited — awaiting window's own re-entry")]
            default:
                return []
            }

        case let .displaysReconfigured(current, targetPresent):
            retryBudget = Self.maxFullScreenRetries
            var actions: [PlacementAction] = [.scheduleRehomeExpiry]
            if phase == .fullScreen {
                actions += rehomeIfDrifted(current: current, targetPresent: targetPresent, cause: "displaysReconfigured")
            }
            return actions

        case .rehomeWindowExpired:
            if phase == .fullScreen || phase == .gaveUp { retryBudget = 0 }
            return []
        }
    }

    // MARK: Private

    private mutating func rehomeIfDrifted(current: String?, targetPresent: Bool, cause: String) -> [PlacementAction] {
        guard let current, current != targetUUID else { return [] }
        guard targetPresent else {
            return [.log("\(cause): on \(current) but target display absent — not re-homing")]
        }
        return retryOrGiveUp(current: current, cause: "\(cause): window drifted to \(current)")
    }

    private mutating func retryOrGiveUp(current: String?, cause: String) -> [PlacementAction] {
        guard retryBudget > 0, retriesUsed < Self.maxLifetimeRetries else {
            phase = .gaveUp
            return [.log("\(cause) — retry budget exhausted, giving up (window stays on \(current ?? "nil"))")]
        }
        retryBudget -= 1
        retriesUsed += 1
        phase = .exitingForRetry
        return [.log("\(cause) — exiting full-screen to re-home (retries left \(retryBudget))"), .exitFullScreen]
    }
}
