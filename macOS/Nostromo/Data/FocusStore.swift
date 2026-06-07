import Foundation
import Combine

final class FocusStore {
    static let shared = FocusStore()

    @Published private(set) var focuses: [Focus]

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
        focuses.removeAll { $0.id == focus.id }
        save()
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
