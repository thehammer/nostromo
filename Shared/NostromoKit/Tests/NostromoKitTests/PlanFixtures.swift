import Foundation

/// Plan markdown fixtures live as plain files under `Fixtures/plans/` (excluded from the
/// target's sources) and are read straight off disk relative to this file.
enum PlanFixtures {

    static func text(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/plans/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every fixture, for the properties that must hold for all of them.
    static let all = ["plan-full.md", "plan-2000-lines.md", "plan-hostile.md", "plan-task-nested.md"]
}
