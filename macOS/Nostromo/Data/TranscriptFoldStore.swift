import Combine
import Foundation
import os

// FV2: replace with NostromoKit.TranscriptViewMode (same raw values, so the file format is identical).
enum TranscriptViewMode: String, Codable {
    case focus
    case allActivity
}

enum FoldOrigin: String, Codable {
    case user
    case auto
}

/// What changed, so every pane on the affected focus can re-resolve.
enum FoldStoreChange: Equatable {
    case folds(tag: String, keys: [String])
    case mode(tags: [String])
    case defaultMode
}

/// Persistent, bounded memory of how the user wants each focus's transcript
/// folded: per-focus fold and result choices, the per-focus Focus / All
/// activity **mode**, and the global default mode.
///
/// ## Lifetime rules (user decision D1/F3)
///
/// State is keyed by the focus's session tag and survives relaunch, daemon
/// restart, Clear Context and new Claude sessions. There is deliberately **no**
/// hook on `.cleared` or `newSession()`; only `removeFocus(tag:)` (the focus
/// itself was deleted) and `prune(tag:keepingTurnKeys:)` (retention splice)
/// ever remove entries, apart from LRU bounds.
///
/// ## Threading
///
/// Main queue only, like `TurnPayloadStore`: every method and `changes` must be
/// used from the main queue. Encoding and the atomic file write happen on a
/// private serial queue; completion is reported back on the main queue.
///
/// ## Bounds
///
/// Fold plus result entries: ≤ 2,000 per tag and ≤ 10,000 overall, LRU by
/// `touched`. Modes: ≤ 1,000 tags, LRU. Bounds are enforced when a write is
/// built (and early if the in-memory count runs well past a cap), so memory
/// between writes is bounded by the 1 s debounce.
final class TranscriptFoldStore {

    static let shared = TranscriptFoldStore(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nostromo/transcript-folds.v1.json"),
        defaults: .standard,
        scheduler: .main)

    static let defaultViewKey = "nostromo.transcript.defaultView"
    static let maxEntriesPerTag = 2_000
    static let maxEntriesTotal = 10_000
    static let maxModeTags = 1_000
    static let debounce: TimeInterval = 1

    let changes = PassthroughSubject<FoldStoreChange, Never>()

    /// Completed file writes (observability for tests).
    private(set) var writeCount = 0
    /// Called on the main queue after each write completes.
    var onWriteCompleted: (() -> Void)?

    var defaultMode: TranscriptViewMode {
        get {
            defaults.string(forKey: Self.defaultViewKey).flatMap(TranscriptViewMode.init(rawValue:)) ?? .focus
        }
        set {
            let old = defaultMode
            guard newValue != old else { return }
            defaults.set(newValue.rawValue, forKey: Self.defaultViewKey)
            // Only tags that follow the default flip; they get a fresh start.
            let following = Set(folds.keys.map(\.tag)).subtracting(modes.keys).sorted()
            for tag in following { dropFolds(tag: tag) }
            if !following.isEmpty { scheduleWrite() }
            if !following.isEmpty { changes.send(.mode(tags: following)) }
            changes.send(.defaultMode)
        }
    }

    // MARK: - Init

    init(fileURL: URL, defaults: UserDefaults, scheduler: WorkScheduler, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.scheduler = scheduler
        self.now = now
        load()
    }

    // MARK: - Mode

    func mode(tag: String) -> TranscriptViewMode {
        guard var entry = modes[tag] else { return defaultMode }
        entry.touched = stamp()   // in memory only; no write
        modes[tag] = entry
        return entry.mode
    }

    func explicitMode(tag: String) -> TranscriptViewMode? { modes[tag]?.mode }

    /// Explicit choice (kept even when equal to the default). Starts the
    /// focus's folds afresh.
    func setMode(tag: String, _ mode: TranscriptViewMode) {
        modes[tag] = ModeEntry(mode: mode, touched: stamp())
        dropFolds(tag: tag)
        trimModesIfFarOver()
        scheduleWrite()
        changes.send(.mode(tags: [tag]))
    }

    /// The focus follows the default again.
    func clearMode(tag: String) {
        guard let old = modes.removeValue(forKey: tag) else { return }
        if old.mode != defaultMode { dropFolds(tag: tag) }
        scheduleWrite()
        changes.send(.mode(tags: [tag]))
    }

    // MARK: - Folds and results

    func foldState(tag: String, key: String) -> (open: Bool, origin: FoldOrigin)? {
        guard let e = folds[EntryKey(tag: tag, key: key)] else { return nil }
        return (e.open, e.origin)
    }

    func setFold(tag: String, key: String, turnKey: String, open: Bool, origin: FoldOrigin) {
        folds[EntryKey(tag: tag, key: key)] = FoldEntry(turnKey: turnKey, open: open, origin: origin, touched: stamp())
        entryWritten(tag: tag, key: key)
    }

    func resultState(tag: String, key: String) -> Bool? {
        results[EntryKey(tag: tag, key: key)]?.open
    }

    func setResult(tag: String, key: String, turnKey: String, open: Bool) {
        results[EntryKey(tag: tag, key: key)] = FoldEntry(turnKey: turnKey, open: open, origin: .user, touched: stamp())
        entryWritten(tag: tag, key: key)
    }

    /// Writes explicit fold entries (no turn key, so `prune` leaves them to LRU).
    func pinStuck(tag: String, keys: [String], open: Bool) {
        guard !keys.isEmpty else { return }
        let touched = stamp()
        for key in keys {
            folds[EntryKey(tag: tag, key: key)] = FoldEntry(turnKey: "", open: open, origin: .user, touched: touched)
        }
        trimEntriesIfFarOver()
        scheduleWrite()
        changes.send(.folds(tag: tag, keys: keys))
    }

    // MARK: - Removal

    /// Retention splice only: drops entries of turns no longer held.
    func prune(tag: String, keepingTurnKeys keep: Set<String>) {
        func missing(_ k: EntryKey, _ e: FoldEntry) -> Bool {
            k.tag == tag && !e.turnKey.isEmpty && !keep.contains(e.turnKey)
        }
        let foldKeys = folds.filter { missing($0.key, $0.value) }.map(\.key)
        let resultKeys = results.filter { missing($0.key, $0.value) }.map(\.key)
        guard !foldKeys.isEmpty || !resultKeys.isEmpty else { return }
        foldKeys.forEach { folds.removeValue(forKey: $0) }
        resultKeys.forEach { results.removeValue(forKey: $0) }
        scheduleWrite()
        changes.send(.folds(tag: tag, keys: (foldKeys + resultKeys).map(\.key)))
    }

    /// Focus removal only: forgets the tag's folds, results and mode.
    func removeFocus(tag: String) {
        let foldKeys = folds.keys.filter { $0.tag == tag }
        let resultKeys = results.keys.filter { $0.tag == tag }
        let hadMode = modes.removeValue(forKey: tag) != nil
        foldKeys.forEach { folds.removeValue(forKey: $0) }
        resultKeys.forEach { results.removeValue(forKey: $0) }
        guard hadMode || !foldKeys.isEmpty || !resultKeys.isEmpty else { return }
        scheduleWrite()
        if hadMode { changes.send(.mode(tags: [tag])) }
        if !foldKeys.isEmpty || !resultKeys.isEmpty {
            changes.send(.folds(tag: tag, keys: (foldKeys + resultKeys).map(\.key)))
        }
    }

    // MARK: - Private types

    private struct EntryKey: Hashable { let tag: String; let key: String }
    private struct FoldEntry { var turnKey: String; var open: Bool; var origin: FoldOrigin; var touched: Stamp }
    private struct ModeEntry { var mode: TranscriptViewMode; var touched: Stamp }

    /// Orders entries: the clock first, a monotonic counter to break ties.
    private struct Stamp: Comparable {
        var time: Double
        var seq: Int
        static func < (a: Stamp, b: Stamp) -> Bool { (a.time, a.seq) < (b.time, b.seq) }
    }

    private struct FileFormat: Codable {
        struct Fold: Codable { var tag, key, turnKey: String; var open: Bool; var origin: FoldOrigin; var touched: Double }
        struct Result: Codable { var tag, key, turnKey: String; var open: Bool; var touched: Double }
        struct Mode: Codable { var mode: TranscriptViewMode; var touched: Double }
        var version: Int
        var folds: [Fold]
        var results: [Result]
        var modes: [String: Mode]
    }

    // MARK: - Private state

    private static let log = Logger(subsystem: "com.hammer.nostromo.mac", category: "TranscriptFoldStore")

    private let fileURL: URL
    private let defaults: UserDefaults
    private let scheduler: WorkScheduler
    private let now: () -> Date
    private let writeQueue = DispatchQueue(label: "nostromo.transcript-fold-store.write", qos: .utility)

    private var folds: [EntryKey: FoldEntry] = [:]
    private var results: [EntryKey: FoldEntry] = [:]
    private var modes: [String: ModeEntry] = [:]
    private var seq = 0
    private var pendingWrite: (() -> Void)?

    // MARK: - Private helpers

    private func stamp() -> Stamp {
        seq += 1
        return Stamp(time: now().timeIntervalSince1970, seq: seq)
    }

    private func entryWritten(tag: String, key: String) {
        trimEntriesIfFarOver()
        scheduleWrite()
        changes.send(.folds(tag: tag, keys: [key]))
    }

    private func dropFolds(tag: String) {
        for key in folds.keys where key.tag == tag { folds.removeValue(forKey: key) }
    }

    private func scheduleWrite() {
        guard pendingWrite == nil else { return }   // debounce: one write per window
        pendingWrite = scheduler.schedule(Self.debounce) { [weak self] in self?.write() }
    }

    private func trimEntriesIfFarOver() {
        if folds.count + results.count > Self.maxEntriesTotal + Self.maxEntriesTotal / 10 { enforceEntryBounds() }
    }

    private func trimModesIfFarOver() {
        if modes.count > Self.maxModeTags + Self.maxModeTags / 10 { enforceModeBound() }
    }

    private func enforceModeBound() {
        guard modes.count > Self.maxModeTags else { return }
        let victims = modes.sorted { $0.value.touched < $1.value.touched }.prefix(modes.count - Self.maxModeTags)
        for (tag, _) in victims { modes.removeValue(forKey: tag) }
    }

    /// LRU over folds and results together: per tag first, then overall.
    private func enforceEntryBounds() {
        struct Ref { let isResult: Bool; let key: EntryKey; let touched: Stamp }
        func evict(_ refs: [Ref], count: Int) {
            for ref in refs.sorted(by: { $0.touched < $1.touched }).prefix(count) {
                if ref.isResult { results.removeValue(forKey: ref.key) } else { folds.removeValue(forKey: ref.key) }
            }
        }
        func refs() -> [Ref] {
            folds.map { Ref(isResult: false, key: $0.key, touched: $0.value.touched) }
                + results.map { Ref(isResult: true, key: $0.key, touched: $0.value.touched) }
        }
        for (_, group) in Dictionary(grouping: refs(), by: { $0.key.tag }) where group.count > Self.maxEntriesPerTag {
            evict(group, count: group.count - Self.maxEntriesPerTag)
        }
        let all = refs()
        if all.count > Self.maxEntriesTotal { evict(all, count: all.count - Self.maxEntriesTotal) }
    }

    private func write() {
        pendingWrite = nil
        enforceEntryBounds()
        enforceModeBound()
        let file = snapshot()
        let url = fileURL
        writeQueue.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("write failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.writeCount += 1
                self.onWriteCompleted?()
            }
        }
    }

    /// Oldest first, so a reload reassigns tie-breaking order faithfully.
    private func snapshot() -> FileFormat {
        let foldRows = folds.sorted { $0.value.touched < $1.value.touched }.map { k, e in
            FileFormat.Fold(tag: k.tag, key: k.key, turnKey: e.turnKey, open: e.open, origin: e.origin, touched: e.touched.time)
        }
        let resultRows = results.sorted { $0.value.touched < $1.value.touched }.map { k, e in
            FileFormat.Result(tag: k.tag, key: k.key, turnKey: e.turnKey, open: e.open, touched: e.touched.time)
        }
        let modeRows = modes.mapValues { FileFormat.Mode(mode: $0.mode, touched: $0.touched.time) }
        return FileFormat(version: 1, folds: foldRows, results: resultRows, modes: modeRows)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }   // no file: first launch
        guard let file = try? JSONDecoder().decode(FileFormat.self, from: data), file.version == 1 else {
            quarantineCorruptFile()
            return
        }
        // Rows were written oldest first; the counter keeps that order for equal timestamps.
        func stamp(_ time: Double) -> Stamp { seq += 1; return Stamp(time: time, seq: seq) }
        for f in file.folds {
            folds[EntryKey(tag: f.tag, key: f.key)] = FoldEntry(turnKey: f.turnKey, open: f.open, origin: f.origin, touched: stamp(f.touched))
        }
        for r in file.results {
            results[EntryKey(tag: r.tag, key: r.key)] = FoldEntry(turnKey: r.turnKey, open: r.open, origin: .user, touched: stamp(r.touched))
        }
        for (tag, m) in file.modes.sorted(by: { $0.value.touched < $1.value.touched }) {
            modes[tag] = ModeEntry(mode: m.mode, touched: stamp(m.touched))
        }
    }

    private func quarantineCorruptFile() {
        let aside = fileURL.appendingPathExtension("corrupt-\(Int(now().timeIntervalSince1970))")
        let fm = FileManager.default
        try? fm.removeItem(at: aside)
        do {
            try fm.moveItem(at: fileURL, to: aside)
            Self.log.error("unreadable fold store moved to \(aside.lastPathComponent, privacy: .public); starting empty")
        } catch {
            Self.log.error("unreadable fold store could not be moved aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
