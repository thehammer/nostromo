import Foundation

/// One state group in the Mother job list: a state and its jobs, newest first.
struct MotherJobGroup: Identifiable, Equatable {
    let state: String
    var jobs: [MotherJob]
    var id: String { state }
    static func == (a: MotherJobGroup, b: MotherJobGroup) -> Bool {
        a.state == b.state && a.jobs.map(\.id) == b.jobs.map(\.id)
    }
}

/// Groups jobs by state in a fixed display order. Exactly one group per state.
///
/// The old inline version sorted by a *shared* rank (queued = ready, succeeded =
/// cancelled) and then grouped only *consecutive* equal states, so equal-rank
/// states interleaved into READY / QUEUED / READY. Two sections with the same
/// header then collided in SwiftUI's identity and rendered one section's rows
/// for both — a retried job showed another job's title.
enum MotherJobGrouping {
    /// awaiting → running → queued → ready → failed → succeeded → cancelled → others.
    static let stateOrder = ["awaiting", "running", "queued", "ready", "failed", "succeeded", "cancelled"]

    static func groups(from jobs: [MotherJob]) -> [MotherJobGroup] {
        var byState: [String: [MotherJob]] = [:]
        for job in jobs { byState[job.state, default: []].append(job) }
        let known = stateOrder.filter { byState[$0] != nil }
        let unknown = byState.keys.filter { !stateOrder.contains($0) }.sorted()
        return (known + unknown).map { state in
            let sorted = byState[state]!.sorted {
                let a = $0.startedAt ?? $0.createdAt ?? .distantPast
                let b = $1.startedAt ?? $1.createdAt ?? .distantPast
                if a != b { return a > b }
                return $0.id < $1.id          // total order: stable across refreshes
            }
            return MotherJobGroup(state: state, jobs: sorted)
        }
    }
}
