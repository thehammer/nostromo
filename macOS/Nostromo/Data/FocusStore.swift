import Foundation
import Combine

final class FocusStore {
    static let shared = FocusStore()

    @Published private(set) var focuses: [Focus]

    /// Fires once per focus actually removed — never on a no-op double-remove
    /// or a built-in (`remove(_:)` guards both). A `PassthroughSubject`, NOT
    /// `@Published`: eviction (see `AppStore.evictPerFocusState`) must run
    /// once per removal EVENT, not once per new subscriber replaying the
    /// current value — same precedent as `AppStore.decisionRequests` /
    /// `FileWatchers.shared.thresholdEvents`.
    let focusRemovals = PassthroughSubject<Focus, Never>()

    private let storageURL: URL

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nostromo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("focuses.json")
        let dynamic = Self.load(from: storageURL)
        focuses = Focus.builtIns + dynamic
    }

    func add(_ focus: Focus) {
        guard !focuses.contains(where: { $0.id == focus.id }) else { return }
        focuses.append(focus)
        save()
    }

    /// Returns an existing dynamic focus matching this project + agent, if any.
    func existing(projectPath: String?, agentTag: String) -> Focus? {
        focuses.first {
            !$0.isBuiltIn && $0.projectPath == projectPath && $0.agentTag == agentTag
        }
    }

    /// Apply an auto-generated session summary to the focus whose `sessionTag`
    /// matches `tag`.  Idempotent: no-ops when the summary is already equal.
    func updateSummary(tag: String, summary: String) {
        guard let idx = focuses.firstIndex(where: { $0.sessionTag == tag }) else { return }
        guard focuses[idx].sessionSummary != summary else { return }
        focuses[idx].sessionSummary = summary
        save()
    }

    func remove(_ focus: Focus) {
        guard !focus.isBuiltIn else { return }
        // Guard on membership so a double-remove (e.g. two windows racing a
        // close on the same tab) never sends `focusRemovals` twice for one
        // focus — `AppStore.evictPerFocusState` must run exactly once per
        // actual removal.
        guard focuses.contains(where: { $0.id == focus.id }) else { return }
        focuses.removeAll { $0.id == focus.id }
        save()
        // `focusRemovals` fires AFTER `focuses` is mutated and saved — never
        // before. `@Published` notifies `$focuses` subscribers (via
        // `willSet`) synchronously at the point of mutation, but every real
        // subscriber (MainLayout, AppStore's registry push) uses
        // `.receive(on: DispatchQueue.main)`, which defers the actual sink
        // invocation to an enqueued `DispatchQueue.main.async` block rather
        // than running it inline. Because `DispatchQueue.main` is FIFO, that
        // block is enqueued strictly before the one this `send` enqueues on
        // `AppStore`'s `focusRemovals` subscriber — so every `$focuses`
        // observer (in particular `MainLayout`, which releases its cached
        // view for this focus) has already run by the time eviction does.
        // That ordering is what stops `AppStore.session(for:)` — a lazy
        // creator — from recreating the very session eviction just removed.
        // Reversing these two lines (or collapsing them into one signal)
        // silently reintroduces that resurrection with no test failing
        // anywhere else; see `PerFocusEvictionWiringTests`.
        focusRemovals.send(focus)
    }

    func save() {
        let dynamic = focuses.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(dynamic) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    /// Project the live focus list into the daemon wire shape (Phase 1: registry push).
    func wireProjection() -> [NostromodClient.FocusMetaWire] {
        focuses.map { f in
            NostromodClient.FocusMetaWire(
                tag:             f.sessionTag,
                display_name:    f.displayName,
                agent_name:      f.agentTag,
                project_name:    f.repoName,
                org:             f.effectiveOrg,
                is_built_in:     f.isBuiltIn,
                session_summary: f.sessionSummary
            )
        }
    }

    private static func load(from url: URL) -> [Focus] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Focus].self, from: data)
        else { return [] }
        return decoded.filter { !$0.isBuiltIn }
    }
}
