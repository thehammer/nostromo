import Foundation

/// Pure reconciliation of the app's job map against a full `query.list` result, so a job the
/// app never heard about (a missed `queued` event) shows up, and a job that left the broker
/// without an event goes away.
enum MotherJobReconciler {
    struct Result: Equatable {
        var jobs: [String: MotherJob]
        var missingOnce: Set<String>
        var added: [String]
        var removed: [String]
    }

    /// Whether a discovery `query.get` result may be inserted: unknown and not just archived.
    static func shouldInsertDiscovered(id: String, jobMap: [String: MotherJob],
                                       recentlyArchived: Set<String>) -> Bool {
        jobMap[id] == nil && !recentlyArchived.contains(id)
    }

    /// `listed` must come from a successful reply; never call this for a failed one.
    /// A job absent from `listed` is removed only after two consecutive clean absences.
    /// A `partial` list (some entries unreadable) adds and updates but never removes, and
    /// resets the absence count so removal still needs two consecutive clean lists.
    /// `unreadableIds` are ids the broker listed but the app could not decode: they count as present.
    static func reconcile(current: [String: MotherJob],
                          listed: [MotherJob],
                          missingOnce: Set<String>,
                          recentlyArchived: Set<String>,
                          partial: Bool = false,
                          unreadableIds: Set<String> = []) -> Result {
        var jobs = current
        var added: [String] = []
        var removed: [String] = []
        var listedIds = unreadableIds

        for job in listed {
            listedIds.insert(job.id)
            if let mine = current[job.id] {
                jobs[job.id] = mine.replacing(with: job)
            } else if !recentlyArchived.contains(job.id) {
                jobs[job.id] = job
                added.append(job.id)
            }
        }

        if partial {
            return Result(jobs: jobs, missingOnce: [], added: added.sorted(), removed: [])
        }

        var nextMissing = Set<String>()
        for id in current.keys where !listedIds.contains(id) {
            if missingOnce.contains(id) {
                jobs.removeValue(forKey: id)
                removed.append(id)
            } else {
                nextMissing.insert(id)
            }
        }
        return Result(jobs: jobs, missingOnce: nextMissing, added: added.sorted(), removed: removed.sorted())
    }
}

/// Ids archived or reconciled away recently, so a late discovery result or list cannot
/// resurrect them.
struct MotherRecentlyArchived {
    let ttl: TimeInterval
    private var entries: [String: Date] = [:]

    init(ttl: TimeInterval = 120) { self.ttl = ttl }

    mutating func insert(_ id: String, now: Date = Date()) { entries[id] = now }

    mutating func ids(now: Date = Date()) -> Set<String> {
        entries = entries.filter { now.timeIntervalSince($0.value) < ttl }
        return Set(entries.keys)
    }
}

/// Schedules the periodic resync: a repeating tick while connected and active, plus a one-shot
/// shortly after each snapshot. Nothing is scheduled while disconnected or inactive.
/// `schedule(after, repeating, fire)` returns a cancel closure (a Timer in production).
final class MotherResyncScheduler {
    typealias Schedule = (_ after: TimeInterval, _ repeating: TimeInterval?, _ fire: @escaping () -> Void) -> () -> Void

    private let interval: TimeInterval
    private let afterSnapshot: TimeInterval
    private let schedule: Schedule
    private let tick: () -> Void
    private var connected = false
    private var active = true
    private var cancelRepeating: (() -> Void)?
    private var cancelOneShot: (() -> Void)?

    init(interval: TimeInterval = 60, afterSnapshot: TimeInterval = 2,
         schedule: @escaping Schedule, tick: @escaping () -> Void) {
        self.interval = interval
        self.afterSnapshot = afterSnapshot
        self.schedule = schedule
        self.tick = tick
    }

    var isRunning: Bool { cancelRepeating != nil }

    func setConnected(_ value: Bool) { connected = value; refresh() }
    func setActive(_ value: Bool) { active = value; refresh() }

    /// A (re)connect snapshot arrived: resync once soon.
    func snapshotReceived() {
        cancelOneShot?(); cancelOneShot = nil
        guard connected else { return }
        cancelOneShot = schedule(afterSnapshot, nil) { [weak self] in
            self?.cancelOneShot = nil
            self?.tick()
        }
    }

    private func refresh() {
        let shouldRun = connected && active
        if shouldRun, cancelRepeating == nil {
            cancelRepeating = schedule(interval, interval) { [weak self] in self?.tick() }
        } else if !shouldRun {
            cancelRepeating?(); cancelRepeating = nil
            cancelOneShot?(); cancelOneShot = nil
        }
    }
}
