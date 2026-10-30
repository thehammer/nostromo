import Foundation

/// The commands agents have staged for each terminal, as the daemon last said (`terminal_staging_list`).
/// Memory only, separate from the tracker, never logged or written anywhere.
///
/// - One list per terminal id. A frame whose revision is not newer than the last one seen is ignored
///   (the daemon's revision counts up across every list).
/// - `state: none` removes the list; `terminal_closed` and a lost daemon connection remove it too (the
///   daemon forgets its lists when it restarts, so a drawer must not outlive it).
/// - For every entry, the local monotonic time its current `(command, note)` was first received
///   (`shownSince`): the drawer will not insert an entry a person has had under 1.5 s to read.
/// - Observers are tokens: dropping one (or its `deinit`) removes the observation. A frame that changes
///   nothing (same revision) notifies nobody.
///
/// Main thread only (fed from `AppStore.handle`, read by views).
final class TerminalStagingStore {
    static let shared = TerminalStagingStore()

    /// Sends one frame to the daemon (`AppStore` points it at the client; dropped when not connected).
    var transport: (TerminalClientMessage) -> Void

    /// How many times observers were notified (tests: an identical frame must not move it).
    private(set) var notificationCount = 0

    /// The seconds on a monotonic clock. Injected by tests.
    private let clock: () -> TimeInterval

    private var lists: [String: TerminalStagingList] = [:]
    private var shownSince: [String: [String: (fingerprint: Fingerprint, at: TimeInterval)]] = [:]
    private var lastRevision: [String: Int] = [:]
    private var observers: [ObjectIdentifier: Observer] = [:]

    private struct Fingerprint: Equatable {
        let command: String
        let note: String?
    }

    private struct Observer {
        let terminalId: String
        let handler: () -> Void
    }

    /// Removes its observation when released.
    final class Observation {
        private weak var store: TerminalStagingStore?
        fileprivate init(store: TerminalStagingStore) { self.store = store }
        deinit { store?.observers.removeValue(forKey: ObjectIdentifier(self)) }
    }

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         transport: @escaping (TerminalClientMessage) -> Void = { _ in }) {
        self.clock = clock
        self.transport = transport
    }

    // MARK: - Queries

    /// The list the drawer shows for `terminalId`; nil when there is none (no drawer).
    func list(for terminalId: String) -> TerminalStagingList? {
        lists[terminalId]
    }

    /// The entry with `entryId` in `terminalId`'s list, as it is now.
    func entry(terminalId: String, entryId: String) -> StagingEntry? {
        lists[terminalId]?.entries.first { $0.id == entryId }
    }

    /// Seconds on the store's clock at which the entry's current text was first received.
    func shownSince(terminalId: String, entryId: String) -> TimeInterval? {
        shownSince[terminalId]?[entryId]?.at
    }

    /// The store's clock, for deciding "less than 1.5 s ago" on the same scale as `shownSince`.
    var now: TimeInterval { clock() }

    /// Calls `handler` (on the main thread) whenever `terminalId`'s list changes or goes away. Keep the
    /// returned token for as long as the observation should last; the handler must not retain its owner.
    func observe(terminalId: String, handler: @escaping () -> Void) -> Observation {
        let token = Observation(store: self)
        observers[ObjectIdentifier(token)] = Observer(terminalId: terminalId, handler: handler)
        return token
    }

    // MARK: - Daemon frames

    func ingest(_ frame: TerminalStagingList) {
        let id = frame.terminalId
        if let last = lastRevision[id], frame.revision <= last { return }
        lastRevision[id] = frame.revision
        guard frame.state != .none else {
            guard lists.removeValue(forKey: id) != nil else { return }
            shownSince.removeValue(forKey: id)
            notify(id)
            return
        }
        let at = clock()
        let previous = shownSince[id] ?? [:]
        var next: [String: (fingerprint: Fingerprint, at: TimeInterval)] = [:]
        for entry in frame.entries {
            let fp = Fingerprint(command: entry.command, note: entry.note)
            if let before = previous[entry.id], before.fingerprint == fp {
                next[entry.id] = before
            } else {
                next[entry.id] = (fp, at)
            }
        }
        shownSince[id] = next
        lists[id] = frame
        notify(id)
    }

    /// A closed terminal has no staged list.
    func terminalClosed(_ terminalId: String) {
        lastRevision.removeValue(forKey: terminalId)
        guard lists.removeValue(forKey: terminalId) != nil else { return }
        shownSince.removeValue(forKey: terminalId)
        notify(terminalId)
    }

    /// The daemon connection dropped: its lists are gone with it (and so are its revisions).
    func connectionChanged(_ isConnected: Bool) {
        guard !isConnected else { return }
        lastRevision.removeAll()
        let ids = Array(lists.keys)
        lists.removeAll()
        shownSince.removeAll()
        ids.forEach(notify)
    }

    // MARK: - Commands (a person's act; the caller has asked `TerminalInputGuard` first)

    func reportInserted(terminalId: String, entryId: String, bytes: Int) {
        transport(.stagingInserted(terminalId: terminalId, entryId: entryId, bytes: bytes, confirmed: false))
    }

    func remove(terminalId: String, entryId: String) {
        transport(.stagingRemove(terminalId: terminalId, entryId: entryId))
    }

    func clear(terminalId: String) {
        transport(.stagingClear(terminalId: terminalId))
    }

    // MARK: - Private

    private func notify(_ terminalId: String) {
        notificationCount += 1
        for observer in Array(observers.values) where observer.terminalId == terminalId {
            observer.handler()
        }
    }
}
