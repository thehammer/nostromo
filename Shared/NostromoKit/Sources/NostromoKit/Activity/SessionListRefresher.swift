// NostromoKit — SessionListRefresher.swift
//
// When to ask the daemon for the session list again.
//
// The daemon puts the activity counters in `SessionInfo`, and sends `SessionInfo` ONLY in reply to a
// `session_list` request: it does not push when a counter changes. The one thing it does push is
// `session_state` (a turn started or ended). So the marks would go stale without a refresh, and the
// refresh has three triggers, none of them a tight poll:
//
//  * a `session_state` message that CHANGES a tag's state (a turn started or finished), coalesced
//    in a fixed window so a burst becomes one request (`requestSoon`);
//  * the operator's focus becoming visible and key, the app coming forward, the connection coming
//    up: now (`requestNow`), so the "seen" baseline uses fresh counters;
//  * a slow backstop timer, only while at least one window is visible, to catch what produces no
//    state change (a message in the middle of a turn, a problem). No timer exists while the app is
//    hidden or every window is minimised (`setWindowsVisible`).
//
// The clock is injected (`Schedule`), so the debounce and the backstop are tested with a manual one.

import Foundation

/// Whatever sends `session_list` to the daemon.
public protocol SessionListRequesting: AnyObject {
    func requestSessionList()
}

public final class SessionListRefresher {
    /// Cancels a scheduled timer.
    public typealias Cancel = () -> Void
    /// Schedules `fire` after `after` seconds (and again every `after` seconds when `repeating`).
    public typealias Schedule = (_ after: TimeInterval, _ repeating: Bool, _ fire: @escaping () -> Void) -> Cancel

    /// A burst of state changes inside this window becomes one request.
    public static let debounceInterval: TimeInterval = 0.5
    /// The slow backstop, while a window is visible.
    public static let backstopInterval: TimeInterval = 30

    private weak var requester: SessionListRequesting?
    private let schedule: Schedule
    private var lastState: [String: String] = [:]
    private var cancelDebounce: Cancel?
    private var cancelBackstop: Cancel?

    public init(requester: SessionListRequesting, schedule: @escaping Schedule) {
        self.requester = requester
        self.schedule = schedule
    }

    /// A `session_state` message arrived. Only a CHANGE of state (or the first one seen for the tag)
    /// asks for a refresh; the same state again changes nothing.
    public func noteSessionState(tag: String, state: String) {
        guard lastState[tag] != state else { return }
        lastState[tag] = state
        requestSoon()
    }

    /// Ask in `debounceInterval`. Calls inside an open window are absorbed: the window's one request
    /// carries them all. The window is fixed (not restarted by each call), so a steady stream of
    /// changes still produces a request every `debounceInterval`.
    public func requestSoon() {
        guard cancelDebounce == nil else { return }
        cancelDebounce = schedule(Self.debounceInterval, false) { [weak self] in
            guard let self else { return }
            self.cancelDebounce = nil
            self.requester?.requestSessionList()
        }
    }

    /// Ask now. A pending window is closed first, so one call is one request.
    public func requestNow() {
        cancelDebounce?()
        cancelDebounce = nil
        requester?.requestSessionList()
    }

    /// Whether at least one window is visible. While one is, a repeating timer asks every
    /// `backstopInterval`; while none is, there is no timer at all.
    public func setWindowsVisible(_ visible: Bool) {
        if visible {
            guard cancelBackstop == nil else { return }
            cancelBackstop = schedule(Self.backstopInterval, true) { [weak self] in
                self?.requester?.requestSessionList()
            }
        } else {
            cancelBackstop?()
            cancelBackstop = nil
        }
    }

    /// The daemon connection came up (ask now) or went away (what it said about states is stale).
    public func connectionChanged(_ connected: Bool) {
        if connected {
            requestNow()
        } else {
            lastState.removeAll()
            cancelDebounce?()
            cancelDebounce = nil
        }
    }
}
