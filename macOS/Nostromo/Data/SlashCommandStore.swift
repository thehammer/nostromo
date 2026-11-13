import Combine
import Foundation
import NostromoKit

/// What the store asks the daemon through; `NostromodClient` is the real one, tests pass a recorder.
protocol SlashCommandSending: AnyObject {
    /// Whether the connected daemon advertised `slash_commands_v1`.
    var daemonAdvertisesSlashCommands: Bool { get }
    func sessionCommandsGet(tag: String, requestId: String)
}

/// Every session's slash commands, as the daemon last reported them, keyed by focus tag. App-wide
/// (`shared`), so every window's picker binds to the same lists.
///
/// The daemon answers `session_commands_get` from what the CLI's own passive events told it; the store
/// asks when a picker opens, at most once per `refreshInterval` per tag, and never of a daemon that
/// does not advertise the feature (an older daemon: the picker shows the built-in table). Main thread.
final class SlashCommandStore {
    static let shared = SlashCommandStore()
    static let refreshInterval: TimeInterval = 5

    var sender: SlashCommandSending?
    /// A list arrived for this tag.
    let changes = PassthroughSubject<String, Never>()

    private var catalogs: [String: SlashCommandCatalog] = [:]
    private var lastAsked: [String: Date] = [:]
    private let now: () -> Date
    private let makeRequestId: () -> String

    init(sender: SlashCommandSending? = nil, now: @escaping () -> Date = Date.init,
         makeRequestId: @escaping () -> String = { UUID().uuidString }) {
        self.sender = sender
        self.now = now
        self.makeRequestId = makeRequestId
    }

    /// What the picker lists for `tag`: the last list, else the built-in table.
    func catalog(for tag: String) -> SlashCommandCatalog { catalogs[tag] ?? .fallback }

    /// Ask the daemon for `tag`'s commands, unless it was asked less than `refreshInterval` ago or the
    /// daemon lacks the feature.
    func refresh(tag: String) {
        guard let sender, sender.daemonAdvertisesSlashCommands else { return }
        let t = now()
        if let last = lastAsked[tag], t.timeIntervalSince(last) < Self.refreshInterval { return }
        lastAsked[tag] = t
        sender.sessionCommandsGet(tag: tag, requestId: makeRequestId())
    }

    /// Take one decoded daemon frame; frames that are not command lists are ignored.
    func ingest(_ msg: ServerMsg) {
        guard case .sessionCommands(let wire) = msg else { return }
        catalogs[wire.tag] = SlashCommandCatalog.make(from: wire)
        changes.send(wire.tag)
    }
}
extension NostromodClient: SlashCommandSending {}
