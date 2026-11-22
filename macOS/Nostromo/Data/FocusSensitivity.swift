import Combine
import CryptoKit
import Foundation
import os

/// Whether a focus handles data the user does not want written to disk by the composer (work items,
/// Teri / Fred / Huey material). The daemon decides this (`SensitiveTags`) and does not put it on the
/// wire per focus, so the Mac works it out from what it can see. Main thread only.
protocol FocusSensitivityProviding: AnyObject {
    func isSensitive(tag: String, agentName: String?) -> Bool
    /// A tag that has just become sensitive (never fires for one that already was).
    var becameSensitive: AnyPublisher<String, Never> { get }
    /// Whether sensitivity can be trusted yet. Until it is, a focus that is not already sensitive may still
    /// turn out to be one (a work item sent into it before a relaunch), so nothing about it goes to disk.
    var isKnown: Bool { get }
    /// Fires when `isKnown` becomes true.
    var becameKnown: AnyPublisher<Void, Never> { get }
}

final class FocusSensitivity: FocusSensitivityProviding {

    static let shared = FocusSensitivity(
        entries: { ConversationHistoryStore.shared.history?.entries ?? [] },
        entriesChanged: ConversationHistoryStore.shared.changes.eraseToAnyPublisher(),
        known: { ConversationHistoryStore.shared.sensitivityKnown },
        knownChanged: ConversationHistoryStore.shared.knownChanges.eraseToAnyPublisher(),
        marksDirectory: persistsMarks ? ComposerHistoryStore.sharedDirectory : nil)

    /// Not under XCTest: a test that sends a work item through `SendToAgentSheet` would otherwise write marks
    /// into the real `~/.nostromo` (the repo's other on-disk stores gate on the same class lookup).
    private static var persistsMarks: Bool {
        ComposerHistoryStore.persistsAcrossRelaunch && NSClassFromString("XCTestCase") == nil
    }

    static let marksFileName = "sensitive-marks.v1.json"
    /// Temporary names of the marks file's own atomic write; the history store's sweep leaves these alone.
    static let marksTempPrefix = ".marks-"

    var becameSensitive: AnyPublisher<String, Never> { events.eraseToAnyPublisher() }
    var becameKnown: AnyPublisher<Void, Never> { knownEvents.eraseToAnyPublisher() }

    /// Known once the daemon's first conversation list has been answered (or the daemon is known not to
    /// have one) and the persisted marks were read cleanly. Never known if the daemon never answers.
    var isKnown: Bool { marksReadable && !marksWriteFailed && known() }

    /// SHA-256 hex of a focus tag: the name of its history file and the only form of it kept in the marks file.
    static func tagHash(_ tag: String) -> String {
        SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameters:
    ///   - entries: the daemon's conversation entries (a live one says `running { tag }` and `sensitive`).
    ///   - entriesChanged: fires when they changed.
    ///   - known: whether the daemon's list has been answered (or the daemon has none).
    ///   - knownChanged: fires when `known` may have become true.
    ///   - marksDirectory: where the marks of work-item sends survive a relaunch (SHA-256 hex only, mode 0600
    ///     in a 0700 directory); nil keeps them in memory. Read here, before any caller can ask about a tag.
    ///     A marks file that cannot be read leaves sensitivity unknown for the app's life (fail closed).
    init(entries: @escaping () -> [ConversationEntryWire], entriesChanged: AnyPublisher<Void, Never>,
         known: @escaping () -> Bool = { true },
         knownChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
         marksDirectory: URL? = nil) {
        self.entries = entries
        self.known = known
        self.marksDirectory = marksDirectory
        loadMarks()
        subscription = entriesChanged.sink { [weak self] in self?.scan() }
        knownSubscription = knownChanged.sink { [weak self] in
            guard let self, self.isKnown else { return }
            self.knownEvents.send()
        }
    }

    /// The daemon's rule for the agents it always treats as sensitive (`is_teri_or_fred_agent`,
    /// `is_huey_agent`): the bare name after any plugin qualifier, case-insensitive.
    static func isAlwaysSensitive(agentName: String?) -> Bool {
        guard let agentName else { return false }
        let bare = agentName.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            .last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return ["fred", "teri", "huey"].contains(bare)
    }

    func isSensitive(tag: String, agentName: String?) -> Bool {
        if Self.isAlwaysSensitive(agentName: agentName) || Self.isAlwaysSensitive(agentName: tag)
            || tag.trimmingCharacters(in: .whitespaces).lowercased() == "huey-run" { return true }
        if isMarked(tag) { return true }
        // Re-read the entries: a caller may ask before the change event has been delivered.
        scan()
        return isMarked(tag)
    }

    /// This app sent a work item into `tag`'s focus.
    func noteWorkSend(tag: String) {
        mark(tag)
    }

    // MARK: Private

    private let entries: () -> [ConversationEntryWire]
    private let known: () -> Bool
    private let marksDirectory: URL?
    private let events = PassthroughSubject<String, Never>()
    private let knownEvents = PassthroughSubject<Void, Never>()
    private var subscription: AnyCancellable?
    private var knownSubscription: AnyCancellable?
    /// `tagHash` of every marked tag: the tag itself is never kept.
    private var markedHashes: Set<String> = []
    private var marksReadable = true
    /// The last attempt to save the marks failed, so a relaunch would forget them: fail closed until one succeeds.
    private var marksWriteFailed = false

    private struct MarksFile: Codable {
        var version: Int
        var tags: [String]
    }

    private static let log = Logger(subsystem: "com.hammer.nostromo.mac", category: "FocusSensitivity")

    private var marksURL: URL? { marksDirectory?.appendingPathComponent(Self.marksFileName) }

    private func isMarked(_ tag: String) -> Bool { markedHashes.contains(Self.tagHash(tag)) }

    private func loadMarks() {
        guard let directory = marksDirectory, let url = marksURL else { return }
        // A temporary left by a write that did not finish; ours only, and before any write of this run.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.marksTempPrefix) && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(MarksFile.self, from: try Data(contentsOf: url))
            guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            markedHashes = Set(file.tags)
        } catch {
            // Which focuses were work-sent is lost: nothing is known, so nothing is written (class only logged).
            marksReadable = false
            Self.log.error("sensitive marks unreadable (\(String(describing: type(of: error)), privacy: .public)); history stays in memory")
        }
    }

    private func persistMarks() {
        guard let directory = marksDirectory, let url = marksURL, marksReadable else { return }
        do {
            let data = try JSONEncoder().encode(MarksFile(version: 1, tags: markedHashes.sorted()))
            try ComposerHistoryStore.writePrivately(data, to: url, directory: directory,
                                                    tempPrefix: Self.marksTempPrefix)
            marksWriteFailed = false
        } catch {
            marksWriteFailed = true
            Self.log.error("sensitive marks write failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    private func scan() {
        for entry in entries() where entry.sensitive {
            if case .running(let tag, _) = entry.status { mark(tag) }
        }
    }

    private func mark(_ tag: String) {
        guard markedHashes.insert(Self.tagHash(tag)).inserted else { return }
        persistMarks()
        events.send(tag)
    }
}
