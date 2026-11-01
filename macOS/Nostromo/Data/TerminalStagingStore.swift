import Foundation

/// A counted event of the staging UI (`terminal_staging_ui_event`): a fixed set, never any text.
enum StagingUIEvent: String, Equatable {
    case confirmCancelled = "confirm_cancelled"
    case justChanged = "just_changed"
}

/// A placed entry the user archived: shown read-only in the drawer's footer. Memory only.
struct ArchivedStagedEntry: Equatable {
    let entryId: String
    let number: Int
    /// Exactly what was staged.
    let command: String
    /// When it was last placed at the prompt.
    let placedAt: Date
}

/// The commands agents have staged for each terminal, as the daemon last said (`terminal_staging_list`).
/// Memory only, separate from the tracker, never logged or written anywhere.
///
/// - One list per terminal id. A frame whose revision is not newer than the last one seen is ignored
///   (the daemon's revision counts up across every list).
/// - `state: none` removes the list; `terminal_closed`, a frame the app cannot read (the revision floor is
///   kept) and a lost daemon connection remove it too (the daemon forgets its lists when it restarts, so a
///   drawer must not outlive it).
/// - For every entry, the local monotonic time its current `(command, note)` was first received, or
///   the time the list's rows last changed (`shownSince`): the drawer will not insert an entry a person
///   has had under 1.5 s to read, and none whose row may just have moved under the pointer. Any change to
///   any entry's text or note, or to which entries there are, restarts every entry's time. So does a change
///   of the list's `foreground`, and a move of the drawer (`restartReadingDelay`).
/// - `enabled` per terminal is the last value the daemon sent (a `none` frame carries it too), kept until
///   the terminal closes or the connection drops.
/// - The global switch is read **once**, from UserDefaults, when the store is made, and never observed
///   afterwards: a `defaults write` from another process changes nothing while the app runs. While it is off
///   the store has no lists and ignores incoming ones.
/// - Archived entries (placed, then archived) and auto-archive pendings live here too, in memory only.
/// - Observers are tokens: dropping one (or its `deinit`) removes the observation. A frame that changes
///   nothing (same revision) notifies nobody.
///
/// Main thread only (fed from `AppStore.handle`, read by views).
final class TerminalStagingStore {
    static let shared = TerminalStagingStore()

    /// UserDefaults key of the global switch (registered default `true`).
    static let globalEnabledKey = "nostromo.terminal.stagingEnabled"
    /// At most this many archived entries are kept for each terminal (the oldest is dropped).
    static let maxArchived = 12

    /// Archive Commands After I Run Them. **Memory only and off at every launch**: it is never stored in
    /// UserDefaults or a file and nothing but the gated drawer menu item (through `StagingInsertController`)
    /// sets it.
    private(set) static var autoArchiveEnabled = false

    /// Only `StagingInsertController.setAutoArchive`, after the human-gesture gate, calls this.
    static func setAutoArchive(_ on: Bool) {
        autoArchiveEnabled = on
    }

    /// Sends one frame to the daemon (`AppStore` points it at the client; dropped when not connected).
    var transport: (TerminalClientMessage) -> Void

    /// How many times observers were notified (tests: an identical frame must not move it).
    private(set) var notificationCount = 0

    /// Whether agents may stage into any terminal (the global switch). Read once at launch.
    private(set) var globalEnabled: Bool

    /// The seconds on a monotonic clock. Injected by tests.
    private let clock: () -> TimeInterval
    private let defaults: UserDefaults

    private var lists: [String: TerminalStagingList] = [:]
    private var shownSince: [String: [String: (fingerprint: Fingerprint, at: TimeInterval)]] = [:]
    private var lastRevision: [String: Int] = [:]
    private var enabled: [String: Bool] = [:]
    private var archived: [String: [ArchivedStagedEntry]] = [:]
    private var pendingAuto: [String: [PendingAutoArchive]] = [:]
    private var lastJustChanged: [String: TimeInterval] = [:]
    private var observers: [ObjectIdentifier: Observer] = [:]

    private struct Fingerprint: Equatable {
        let command: String
        let note: String?
    }

    private struct PendingAutoArchive {
        let entryId: String
        let command: String
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
         transport: @escaping (TerminalClientMessage) -> Void = { _ in },
         defaults: UserDefaults = .standard) {
        self.clock = clock
        self.transport = transport
        self.defaults = defaults
        defaults.register(defaults: [Self.globalEnabledKey: true])
        self.globalEnabled = defaults.bool(forKey: Self.globalEnabledKey)
    }

    // MARK: - Queries

    /// The list the drawer shows for `terminalId`; nil when there is none (no drawer), and always nil while
    /// the global switch is off. Entries the user archived are not in it.
    func list(for terminalId: String) -> TerminalStagingList? {
        guard globalEnabled, let raw = lists[terminalId] else { return nil }
        let hidden = Set((archived[terminalId] ?? []).map(\.entryId))
        guard !hidden.isEmpty else { return raw }
        var list = raw
        list = TerminalStagingList(terminalId: raw.terminalId, paneId: raw.paneId, state: raw.state, ownerTag: raw.ownerTag,
                                   agentName: raw.agentName, revision: raw.revision,
                                   entries: raw.entries.filter { !hidden.contains($0.id) },
                                   enabled: raw.enabled, foreground: raw.foreground)
        return list
    }

    /// The entry with `entryId` in `terminalId`'s list, as it is now (an archived entry is gone).
    func entry(terminalId: String, entryId: String) -> StagingEntry? {
        list(for: terminalId)?.entries.first { $0.id == entryId }
    }

    /// Whether staging is on for `terminalId`: the last `enabled` the daemon sent (true until it says).
    func isEnabled(terminalId: String) -> Bool {
        enabled[terminalId] ?? true
    }

    /// Whether staging is on globally and for `terminalId`.
    func isStagingOn(terminalId: String) -> Bool {
        globalEnabled && isEnabled(terminalId: terminalId)
    }

    /// The terminal's archived entries, newest last.
    func archivedEntries(for terminalId: String) -> [ArchivedStagedEntry] {
        globalEnabled ? (archived[terminalId] ?? []) : []
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
        guard globalEnabled else { return }
        let id = frame.terminalId
        if let last = lastRevision[id], frame.revision <= last { return }
        lastRevision[id] = frame.revision
        let enabledChanged = (enabled[id] ?? true) != frame.enabled
        enabled[id] = frame.enabled
        guard frame.state != .none else {
            archived.removeValue(forKey: id)
            pendingAuto.removeValue(forKey: id)
            guard lists.removeValue(forKey: id) != nil else {
                if enabledChanged { notify(id) }
                return
            }
            shownSince.removeValue(forKey: id)
            notify(id)
            return
        }
        let at = clock()
        if let old = lists[id], old.ownerTag != frame.ownerTag {
            archived.removeValue(forKey: id)
            pendingAuto.removeValue(forKey: id)
        }
        // Any change to what the rows say (an entry added, removed, moved, or its command or note edited)
        // can change a row's height, shift every row below it and grow the drawer: nothing is under the
        // pointer where the person last saw it. So one change restarts the delay for EVERY entry.
        // A change of the list's `foreground` changes the rules every row is read under: the same.
        // (Marking an entry inserted for the first time does not restart it: the row under the pointer is the
        // one just clicked. The drawer is bottom-anchored, so when it grows it grows upward: that row's
        // bottom edge and every row below it stay put, and the pointer stays on the same row.)
        let fingerprints = frame.entries.map { Fingerprint(command: $0.command, note: $0.note) }
        let previous = shownSince[id] ?? [:]
        let unchanged = lists[id]?.entries.map(\.id) == frame.entries.map(\.id)
            && lists[id]?.foreground == frame.foreground
            && zip(frame.entries, fingerprints).allSatisfy { previous[$0.id]?.fingerprint == $1 }
        var next: [String: (fingerprint: Fingerprint, at: TimeInterval)] = [:]
        for (entry, fp) in zip(frame.entries, fingerprints) {
            next[entry.id] = unchanged ? previous[entry.id] : (fp, at)
        }
        shownSince[id] = next
        lists[id] = frame
        // A replace that changed the command (or removed the entry) drops its auto-archive pending.
        if let pending = pendingAuto[id] {
            let kept = pending.filter { item in frame.entries.contains { $0.id == item.entryId && $0.command == item.command } }
            pendingAuto[id] = kept.isEmpty ? nil : kept
        }
        notify(id)
    }

    /// A closed terminal has no staged list.
    func terminalClosed(_ terminalId: String) {
        lastRevision.removeValue(forKey: terminalId)
        enabled.removeValue(forKey: terminalId)
        pendingAuto.removeValue(forKey: terminalId)
        lastJustChanged.removeValue(forKey: terminalId)
        let hadArchive = archived.removeValue(forKey: terminalId) != nil
        guard lists.removeValue(forKey: terminalId) != nil else {
            if hadArchive { notify(terminalId) }
            return
        }
        shownSince.removeValue(forKey: terminalId)
        notify(terminalId)
    }

    /// A frame for `terminalId` could not be read: the list is dropped (the drawer must not show what the
    /// daemon no longer vouches for) but the revision floor stays, so an older replayed frame cannot bring
    /// it back. A closed terminal, by contrast, forgets its revision.
    func listUnreadable(_ terminalId: String) {
        archived.removeValue(forKey: terminalId)
        pendingAuto.removeValue(forKey: terminalId)
        guard lists.removeValue(forKey: terminalId) != nil else { return }
        shownSince.removeValue(forKey: terminalId)
        notify(terminalId)
    }

    /// The daemon connection dropped: its lists are gone with it (and so are its revisions and switches).
    func connectionChanged(_ isConnected: Bool) {
        guard !isConnected else { return }
        lastRevision.removeAll()
        enabled.removeAll()
        pendingAuto.removeAll()
        lastJustChanged.removeAll()
        let ids = Set(lists.keys).union(archived.keys)
        lists.removeAll()
        archived.removeAll()
        shownSince.removeAll()
        ids.forEach(notify)
    }

    /// Sends the global switch's current value (right after every Subscribe that declares `terminal_staging_ui`).
    func resendGlobal() {
        transport(.stagingSetGlobal(enabled: globalEnabled))
    }

    // MARK: - Commands (a person's act; the caller has asked `TerminalInputGuard` first)

    func reportInserted(terminalId: String, entryId: String, bytes: Int, confirmed: Bool = false) {
        transport(.stagingInserted(terminalId: terminalId, entryId: entryId, bytes: bytes, confirmed: confirmed))
    }

    func remove(terminalId: String, entryId: String) {
        transport(.stagingRemove(terminalId: terminalId, entryId: entryId))
    }

    func clear(terminalId: String) {
        transport(.stagingClear(terminalId: terminalId))
    }

    /// Archive a placed entry: it moves to the drawer's footer (memory only) and the daemon drops it from the
    /// list (so it no longer counts toward the agent's 12). Nothing happens when the entry is gone.
    func archive(terminalId: String, entryId: String, auto: Bool) {
        guard let entry = entry(terminalId: terminalId, entryId: entryId) else { return }
        var items = archived[terminalId] ?? []
        items.append(ArchivedStagedEntry(entryId: entry.id, number: entry.number, command: entry.command,
                                         placedAt: entry.lastInsertedAt ?? entry.changedAt))
        if items.count > Self.maxArchived { items.removeFirst(items.count - Self.maxArchived) }
        archived[terminalId] = items
        transport(.stagingRemove(terminalId: terminalId, entryId: entryId, archive: auto ? "auto" : "manual"))
        notify(terminalId)
    }

    /// The per-terminal switch. The checked state follows the daemon's next frame, not this call.
    func setEnabled(terminalId: String, enabled on: Bool) {
        transport(.stagingSetEnabled(terminalId: terminalId, enabled: on))
    }

    /// The global switch: saved, read again only at the next launch; every drawer hides at once (off) and the
    /// daemon is told.
    func setGlobalEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.globalEnabledKey)
        let changed = on != globalEnabled
        globalEnabled = on
        if changed && !on {
            let ids = Set(lists.keys).union(archived.keys)
            lists.removeAll()
            archived.removeAll()
            pendingAuto.removeAll()
            shownSince.removeAll()
            ids.forEach(notify)
        } else if changed {
            Set(observers.values.map(\.terminalId)).forEach(notify)
        }
        transport(.stagingSetGlobal(enabled: on))
    }

    /// A counted UI event (no text). `just_changed` goes out at most once a second for each terminal.
    func reportUIEvent(_ event: StagingUIEvent, terminalId: String) {
        if event == .justChanged {
            let at = clock()
            if let last = lastJustChanged[terminalId], at - last < 1 { return }
            lastJustChanged[terminalId] = at
        }
        transport(.stagingUIEvent(terminalId: terminalId, event: event.rawValue))
    }

    /// The drawer moved under the pointer (or the pane's foreground changed): every row of `terminalId`
    /// must be read again for the reading delay.
    func restartReadingDelay(terminalId: String) {
        guard let current = shownSince[terminalId], !current.isEmpty else { return }
        let at = clock()
        shownSince[terminalId] = current.mapValues { ($0.fingerprint, at) }
        notify(terminalId)
    }

    // MARK: - Auto-archive (memory only)

    /// An insert succeeded while Archive Commands After I Run Them is on: the entry waits for a person's Enter.
    func notePlaced(terminalId: String, entryId: String, command: String) {
        guard Self.autoArchiveEnabled else { return }
        pendingAuto[terminalId, default: []].append(PendingAutoArchive(entryId: entryId, command: command))
    }

    /// Whether `terminalId` has an entry waiting for a person's Enter (tests).
    func hasPendingAutoArchive(terminalId: String) -> Bool {
        !(pendingAuto[terminalId] ?? []).isEmpty
    }

    /// A person's own input went to `terminalId` (`TerminalSessionStore` calls this for keys, paste and a
    /// staged insert; never for a terminal's auto-replies). The first CR archives each pending entry that is
    /// still there with the identical command; Ctrl-C or Ctrl-U before it drops them.
    func personTyped(terminalId: String, bytes: [UInt8]) {
        guard let pending = pendingAuto[terminalId], !pending.isEmpty else { return }
        for byte in bytes {
            if byte == 0x03 || byte == 0x15 {
                pendingAuto.removeValue(forKey: terminalId)
                return
            }
            if byte == 0x0D {
                pendingAuto.removeValue(forKey: terminalId)
                for item in pending where entry(terminalId: terminalId, entryId: item.entryId)?.command == item.command {
                    archive(terminalId: terminalId, entryId: item.entryId, auto: true)
                }
                return
            }
        }
    }

    // MARK: - Private

    private func notify(_ terminalId: String) {
        notificationCount += 1
        for observer in Array(observers.values) where observer.terminalId == terminalId {
            observer.handler()
        }
    }
}
