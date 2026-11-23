import Combine
import CryptoKit
import Foundation
import os

/// What changed in the history, so every composer on the focus can react at once.
enum ComposerHistoryChange: Equatable {
    case recorded(tag: String)
    /// `clear(tag:)` or `removeFocus(tag:)`: the focus has no history now.
    case cleared(tag: String)
    case removed(tag: String)
}

/// What the user sent from each focus's composer, newest first, for Up / Down recall (a shell's history).
/// App-wide (`shared`), so two windows on one focus share one history; keyed by the focus's session tag,
/// which is stable across New session and restarts.
///
/// Rules: at most `maxEntries` per focus; text over `maxEntryLength` characters is not recorded; an entry
/// equal to the newest is not recorded again. Text only.
///
/// ## Persistence (open question 3)
///
/// `persistsAcrossRelaunch` is the one switch: with it `false` the store never touches the disk.
/// With it on, each non-sensitive focus has one file, `<directory>/<sha256-hex of tag>.json`
/// (directory 0700, files 0600, the mode set before the atomic rename). The directory is under
/// `NostromoHome.current/.nostromo/`, which is not a synced location.
///
/// ## Sensitive focuses
///
/// A focus that is, or becomes, sensitive (`FocusSensitivityProviding`) has its file deleted at once and
/// keeps history in memory only for the rest of the app's life.
///
/// Nothing is written until sensitivity is *known* (`isKnown`: the daemon's first conversation list has
/// been answered, or the daemon is known not to have one, and the persisted marks were read). Until then
/// history is memory only and is written once the focus is known not to be sensitive. If the daemon never
/// answers, history stays in memory for the whole run: it fails closed, never open.
///
/// ## Privacy
///
/// History is never sent anywhere and entries are never logged: a failure logs the error's class only.
///
/// Main thread only. File work runs on a private serial queue.
final class ComposerHistoryStore {

    /// Open question 3 (should history persist across relaunch): yes, the PRD's recommendation.
    /// Flip this to `false` to keep history in memory only.
    static let persistsAcrossRelaunch = true

    static let maxEntries = 200
    static let maxEntryLength = 20_000
    static let debounce: TimeInterval = 1

    static let sharedDirectory = NostromoHome.current.appendingPathComponent(".nostromo/composer-history.v1", isDirectory: true)

    static let shared = ComposerHistoryStore(
        directory: sharedDirectory,
        persists: persistsAcrossRelaunch,
        sensitivity: FocusSensitivity.shared)

    let changes = PassthroughSubject<ComposerHistoryChange, Never>()

    /// Where a read problem is reported: the error's class, never an entry. Tests capture it.
    var logError: (String) -> Void = { message in
        ComposerHistoryStore.log.error("\(message, privacy: .public)")
    }

    init(directory: URL, persists: Bool, sensitivity: FocusSensitivityProviding,
         scheduler: WorkScheduler = .main) {
        self.directory = directory
        self.persists = persists
        self.sensitivity = sensitivity
        self.scheduler = scheduler
        sensitivitySubscription = sensitivity.becameSensitive.sink { [weak self] tag in
            self?.becameSensitive(tag: tag)
        }
        knownSubscription = sensitivity.becameKnown.sink { [weak self] in
            guard let self, !self.dirty.isEmpty else { return }
            self.scheduleFlushOfDirty()
        }
        if persists { sweepOrphanedTempFiles() }
    }

    // MARK: Reading

    /// `tag`'s history, newest first.
    func entries(tag: String) -> [String] {
        loadIfNeeded(tag)
        return entriesByTag[tag] ?? []
    }

    /// True once `tag` is held in memory only (it is, or became, sensitive).
    func isMemoryOnly(tag: String) -> Bool { memoryOnly.contains(tag) }

    // MARK: Recording

    /// Add what the user sent. `agentName` lets the sensitivity rule see agents that are always sensitive.
    func record(tag: String, text: String, agentName: String? = nil) {
        guard !text.isEmpty, text.count <= Self.maxEntryLength else { return }
        if sensitivity.isSensitive(tag: tag, agentName: agentName) { becameSensitive(tag: tag) }
        loadIfNeeded(tag)
        var list = entriesByTag[tag] ?? []
        guard list.first != text else { return }
        list.insert(text, at: 0)
        if list.count > Self.maxEntries { list.removeLast(list.count - Self.maxEntries) }
        entriesByTag[tag] = list
        scheduleWrite(tag)
        changes.send(.recorded(tag: tag))
    }

    /// Remove only the newest entry equal to `text` (a taken-back message's entry). Returns whether one went.
    @discardableResult
    func removeNewest(tag: String, matching text: String) -> Bool {
        loadIfNeeded(tag)
        guard var list = entriesByTag[tag], let index = list.firstIndex(of: text) else { return false }
        list.remove(at: index)
        entriesByTag[tag] = list
        scheduleWrite(tag)
        changes.send(.removed(tag: tag))
        return true
    }

    // MARK: Removing

    /// Clear History: memory and disk, at once, in every window.
    func clear(tag: String) {
        forget(tag)
        changes.send(.cleared(tag: tag))
    }

    /// The focus itself was closed.
    func removeFocus(tag: String) {
        forget(tag)
        changes.send(.cleared(tag: tag))
    }

    // MARK: Writing

    /// Write what is pending now and wait for the file queue (app quit, tests).
    func flush() {
        pendingCancel?()
        pendingCancel = nil
        writePending()
        writeQueue.sync {}
    }

    /// Completed file writes (observability for tests); called on the main queue.
    var onWriteCompleted: (() -> Void)?

    // MARK: Private

    private static let log = Logger(subsystem: "com.hammer.nostromo.mac", category: "ComposerHistoryStore")

    private struct FileFormat: Codable {
        var version: Int
        var entries: [String]
    }

    private let directory: URL
    private let persists: Bool
    private let sensitivity: FocusSensitivityProviding
    private let scheduler: WorkScheduler
    private let writeQueue = DispatchQueue(label: "nostromo.composer-history.write", qos: .utility)
    private var sensitivitySubscription: AnyCancellable?
    private var knownSubscription: AnyCancellable?

    private var entriesByTag: [String: [String]] = [:]
    private var loaded: Set<String> = []
    private var memoryOnly: Set<String> = []
    private var dirty: Set<String> = []
    private var pendingCancel: (() -> Void)?

    private func fileURL(_ tag: String) -> URL {
        directory.appendingPathComponent("\(FocusSensitivity.tagHash(tag)).json")
    }

    private var writesToDisk: Bool { persists }

    private func forget(_ tag: String) {
        entriesByTag[tag] = []
        loaded.insert(tag)
        dirty.remove(tag)
        removeFile(tag)
    }

    /// A focus is, or has just become, sensitive: its file goes now and it is never written again.
    private func becameSensitive(tag: String) {
        guard memoryOnly.insert(tag).inserted else { return }
        dirty.remove(tag)
        removeFile(tag)
    }

    private func removeFile(_ tag: String) {
        guard writesToDisk else { return }
        let url = fileURL(tag)
        writeQueue.async {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Nothing was there.
            } catch {
                Self.log.error("composer history delete failed (\(String(describing: type(of: error)), privacy: .public))")
            }
        }
    }

    /// A temporary file left by a write the app did not finish (a crash between create and rename) would
    /// outlive a delete of its focus's file. Ours are the hidden `.<uuid>.tmp` names.
    private func sweepOrphanedTempFiles() {
        let directory = directory
        writeQueue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp")
                && !name.hasPrefix(FocusSensitivity.marksTempPrefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private func loadIfNeeded(_ tag: String) {
        guard loaded.insert(tag).inserted, writesToDisk, !memoryOnly.contains(tag) else { return }
        // Already sensitive but not yet reported to this store: its file is deleted, not read.
        if sensitivity.isSensitive(tag: tag, agentName: nil) {
            becameSensitive(tag: tag)
            return
        }
        let url = fileURL(tag)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            guard file.version == 1 else {
                logError("composer history file has an unknown version")
                return
            }
            entriesByTag[tag] = Array(file.entries.filter { !$0.isEmpty && $0.count <= Self.maxEntryLength }
                .prefix(Self.maxEntries))
        } catch {
            // The error's class only: a decoding error's description can quote the file's contents.
            logError("composer history file unreadable (\(String(describing: type(of: error)))); starting empty")
        }
    }

    private func scheduleWrite(_ tag: String) {
        guard writesToDisk, !memoryOnly.contains(tag) else { return }
        dirty.insert(tag)
        scheduleFlushOfDirty()
    }

    private func scheduleFlushOfDirty() {
        guard pendingCancel == nil else { return }
        pendingCancel = scheduler.schedule(Self.debounce) { [weak self] in
            self?.pendingCancel = nil
            self?.writePending()
        }
    }

    private func writePending() {
        // Sensitivity not known yet: keep what is pending in memory; `becameKnown` schedules it again.
        guard sensitivity.isKnown else { return }
        let tags = dirty.subtracting(memoryOnly)
        dirty = []
        guard !tags.isEmpty else { return }
        let jobs = tags.map { (url: fileURL($0), entries: entriesByTag[$0] ?? []) }
        let directory = directory
        writeQueue.async { [weak self] in
            for job in jobs {
                do {
                    if job.entries.isEmpty {
                        try? FileManager.default.removeItem(at: job.url)
                    } else {
                        let data = try JSONEncoder().encode(FileFormat(version: 1, entries: job.entries))
                        try Self.writePrivately(data, to: job.url, directory: directory)
                    }
                } catch {
                    Self.log.error("composer history write failed (\(String(describing: type(of: error)), privacy: .public))")
                }
            }
            DispatchQueue.main.async { self?.onWriteCompleted?() }
        }
    }

    /// The directory is 0700 and the file 0600, and the file has its mode from its first byte: it is
    /// created 0600 under a temporary name and renamed over the old one, so no reader ever sees it wider.
    static func writePrivately(_ data: Data, to url: URL, directory: URL, tempPrefix: String = ".") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temp = directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
