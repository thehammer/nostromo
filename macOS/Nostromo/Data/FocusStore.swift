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

    private static func load(from url: URL) -> [Focus] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Focus].self, from: data)
        else { return [] }
        return decoded.filter { !$0.isBuiltIn }
    }
}
