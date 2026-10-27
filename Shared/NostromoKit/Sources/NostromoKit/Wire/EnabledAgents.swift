import Foundation

/// Which built-in agents the daemon runs, from `welcome.enabled_agents`.
/// Stored as the *disabled* switchable agents so anything unknown --
/// mother, dynamic agents, a future built-in -- is enabled.
public struct EnabledAgents: Equatable, Hashable, Sendable {
    public static let switchable: Set<String> = ["fred", "perri", "teri", "huey"]

    public let disabled: Set<String>

    public static let all = EnabledAgents(disabled: [])

    public init(disabled: Set<String>) {
        self.disabled = disabled.intersection(Self.switchable)
    }

    /// `nil`, NSNull or anything that is not `[String]` -> `.all` (an older daemon).
    /// A list -> every switchable agent not in it is disabled.
    public init(wireValue: Any?) {
        guard let names = wireValue as? [String] else {
            self = .all
            return
        }
        let running = Set(names.map { $0.lowercased() })
        self.init(disabled: Self.switchable.subtracting(running))
    }

    public func isEnabled(_ agentTag: String) -> Bool {
        !disabled.contains(agentTag.lowercased())
    }
}
