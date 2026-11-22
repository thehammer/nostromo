import Combine
import Foundation

/// Whether a focus handles data the user does not want written to disk by the composer (work items,
/// Teri / Fred / Huey material). The daemon decides this (`SensitiveTags`) and does not put it on the
/// wire per focus, so the Mac works it out from what it can see. Main thread only.
protocol FocusSensitivityProviding: AnyObject {
    func isSensitive(tag: String, agentName: String?) -> Bool
    /// A tag that has just become sensitive (never fires for one that already was).
    var becameSensitive: AnyPublisher<String, Never> { get }
}

final class FocusSensitivity: FocusSensitivityProviding {

    static let shared = FocusSensitivity(
        entries: { ConversationHistoryStore.shared.history?.entries ?? [] },
        entriesChanged: ConversationHistoryStore.shared.changes.eraseToAnyPublisher())

    var becameSensitive: AnyPublisher<String, Never> { events.eraseToAnyPublisher() }

    /// - Parameters:
    ///   - entries: the daemon's conversation entries (a live one says `running { tag }` and `sensitive`).
    ///   - entriesChanged: fires when they changed.
    init(entries: @escaping () -> [ConversationEntryWire], entriesChanged: AnyPublisher<Void, Never>) {
        self.entries = entries
        subscription = entriesChanged.sink { [weak self] in self?.scan() }
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
        if marked.contains(tag) { return true }
        // Re-read the entries: a caller may ask before the change event has been delivered.
        scan()
        return marked.contains(tag)
    }

    /// This app sent a work item into `tag`'s focus.
    func noteWorkSend(tag: String) {
        mark(tag)
    }

    // MARK: Private

    private let entries: () -> [ConversationEntryWire]
    private let events = PassthroughSubject<String, Never>()
    private var subscription: AnyCancellable?
    private var marked: Set<String> = []

    private func scan() {
        for entry in entries() where entry.sensitive {
            if case .running(let tag, _) = entry.status { mark(tag) }
        }
    }

    private func mark(_ tag: String) {
        guard marked.insert(tag).inserted else { return }
        events.send(tag)
    }
}
