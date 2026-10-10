import Foundation

/// "Run this later" as a value, so debouncing code can be driven by a fake in
/// tests instead of sleeping. `schedule` returns a closure that cancels the
/// pending work.
struct WorkScheduler {
    var schedule: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void

    /// Runs the work on the main queue after `delay`.
    static let main = WorkScheduler { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
