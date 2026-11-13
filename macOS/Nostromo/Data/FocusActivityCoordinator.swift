import Combine
import Foundation
import NostromoKit

/// What one window reports about the focus it shows.
struct FocusWindowSighting: Equatable {
    /// The `sessionTag` of the focus the window is showing.
    var tag: String?
    var isKey: Bool
    var isVisible: Bool
}

/// Decides, per focus, which quiet mark the sidebar shows (`FocusActivityState`), from two inputs: the
/// counters the daemon sent (`ingest`, one per `session_list_resp`) and where the operator is looking
/// (`reportWindow`, one report per window).
///
/// A focus is SEEN while it is the focus of a window that is key and visible. At that moment, and again
/// whenever counters advance while it stays seen, what was seen is set to the current counters, so a
/// focus being looked at never flags. The first sight of a focus, and a new activity epoch (a daemon
/// restart, a session rebuilt), baseline silently (`FocusActivityModel`).
///
/// Main thread only. Nothing here polls: `AppStore` asks the daemon for a fresh list on its own schedule
/// (`SessionListRefresher`) and calls back in.
final class FocusActivityCoordinator {

    /// Fires after any change to what `state(for:)` returns. Does not fire when nothing changed.
    let changes = PassthroughSubject<Void, Never>()
    /// A tag newly became seen: the focus of a key, visible window. `AppStore` asks for fresh counters.
    var onFocusBecameSeen: ((String) -> Void)?
    /// "At least one window is visible" flipped. `AppStore` starts or stops the backstop timer.
    var onAnyWindowVisibleChanged: ((Bool) -> Void)?

    private let store: FocusSeenStore
    private var counters: [String: FocusActivityCounters] = [:]
    private var states: [String: FocusActivityState] = [:]
    private var windows: [Int: FocusWindowSighting] = [:]

    init(store: FocusSeenStore) {
        self.store = store
    }

    /// The tags shown by a window that is key AND visible.
    var seenTags: Set<String> {
        Set(windows.values.compactMap { $0.isKey && $0.isVisible ? $0.tag : nil })
    }

    var anyWindowVisible: Bool { windows.values.contains { $0.isVisible } }

    func state(for tag: String) -> FocusActivityState { states[tag] ?? .none }

    /// Whether a window counts as on screen: not hidden with the app, not minimised, not fully covered.
    static func isVisible(windowVisible: Bool, miniaturized: Bool, occluded: Bool, appHidden: Bool) -> Bool {
        windowVisible && !miniaturized && !occluded && !appHidden
    }

    // MARK: - Inputs

    /// A `session_list_resp`: the counters of every session the daemon holds. A tag missing from it
    /// loses its current counters and state but keeps what was saved as seen.
    func ingest(_ entries: [SessionActivityEntry]) {
        let seen = seenTags
        let before = states
        var newCounters: [String: FocusActivityCounters] = [:]
        var newStates: [String: FocusActivityState] = [:]
        for entry in entries {
            if let activity = entry.activity { newCounters[entry.tag] = activity }
            let state = evaluate(tag: entry.tag, current: entry.activity, isSeen: seen.contains(entry.tag))
            if state != .none { newStates[entry.tag] = state }
        }
        counters = newCounters
        states = newStates
        if states != before { changes.send() }
    }

    /// One window's report; `nil` means the window closed.
    func reportWindow(id: Int, sighting: FocusWindowSighting?) {
        let seenBefore = seenTags
        let visibleBefore = anyWindowVisible
        if let sighting { windows[id] = sighting } else { windows.removeValue(forKey: id) }
        let seenNow = seenTags

        // A focus that just became seen is looked at now: what it holds is seen (its marks clear).
        let newlySeen = seenNow.subtracting(seenBefore).sorted()
        var changed = false
        for tag in newlySeen {
            let before = states[tag] ?? .none
            let state = evaluate(tag: tag, current: counters[tag], isSeen: true)
            if state == .none { states.removeValue(forKey: tag) } else { states[tag] = state }
            if state != before { changed = true }
        }
        if changed { changes.send() }
        for tag in newlySeen { onFocusBecameSeen?(tag) }
        if anyWindowVisible != visibleBefore { onAnyWindowVisibleChanged?(anyWindowVisible) }
    }

    /// The focus was deleted: nothing about it is kept.
    func forget(tag: String) {
        let had = states.removeValue(forKey: tag) != nil
        counters.removeValue(forKey: tag)
        store.forget(tag: tag)
        if had { changes.send() }
    }

    // MARK: - Evaluation

    /// Runs the model for `tag` and keeps what it says to keep.
    private func evaluate(tag: String, current: FocusActivityCounters?, isSeen: Bool) -> FocusActivityState {
        let saved = store.marks(for: tag)
        let result = FocusActivityModel.evaluate(current: current, saved: saved, isSeen: isSeen)
        if let marks = result.saved, marks != saved { store.save(marks, for: tag) }
        return result.state
    }
}
