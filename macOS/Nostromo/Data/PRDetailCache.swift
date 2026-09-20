import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "prDetailCache")

/// Bounds `AppStore.prDetailCache`'s retention of `PRDetail` (which carries
/// the full unified diff text) with an LRU eviction policy.
///
/// Budgeted primarily in **bytes**, not entry count: diff size varies wildly
/// per PR (the daemon's own large-diff gate exists precisely because some
/// diffs are huge), so an entry-count cap alone cannot bound this store — N
/// entries times unbounded bytes is still unbounded. The entry cap stays as a
/// free, cheap secondary bound on the non-diff fields (title, author, url,
/// `ciChecks`) that the byte budget doesn't measure.
///
/// Eviction is LRU by last **use** — a cache read counts as a use, not just a
/// write — because the operator's real access pattern is "cycle forward
/// through the queue, then come back to the two PRs actually under review."
///
/// The `protecting` key (the caller's current `pendingSelection`) is exempt
/// from eviction. This is a wasted-work optimisation, **not** a display-safety
/// property: `AppStore.perriDetail` holds its own independent strong
/// reference to whatever's on screen, so evicting a cache entry can never
/// blank or corrupt the display. The exemption exists only so that clicking
/// back to the PR you're actively reviewing doesn't force a needless
/// re-fetch. A miss elsewhere is cheap for the same reason it's safe to evict:
/// the daemon holds its own on-disk `pr-cache/`, so a miss costs latency, not
/// data loss.
struct PRDetailCache {
    static let maxRetainedDiffBytes = 8 << 20   // 8 MiB
    static let maxRetainedEntries   = 64

    private struct Entry {
        let detail: PRDetail
        let diffBytes: Int
        var lastUsed: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    var count: Int { entries.count }

    private(set) var retainedDiffBytes: Int = 0

    /// Cache key for a PR, from either side of the wire. One formula, one
    /// keyspace — every touch point must call this rather than building its
    /// own key string.
    ///
    /// Known, accepted collision: a repo name that already contains a dash
    /// (e.g. "acme-web") produces the same key as the slash-separated repo it
    /// collides with (e.g. "acme/web"). This keyspace is inherited from the
    /// original single-formula design, not designed here — fixing it would
    /// require a wire-format change to the daemon's `pr-cache/<key>.json`
    /// naming, which is out of scope for this cache's eviction policy.
    static func key(repo: String, number: Int) -> String {
        "\(repo.replacingOccurrences(of: "/", with: "-"))-\(number)"
    }

    /// Record a detail, touching its LRU recency. Evicts other entries (never
    /// `protecting`) until both budgets are satisfied.
    ///
    /// A detail whose diff alone exceeds `maxRetainedDiffBytes` is refused —
    /// uniformly, protected or not, no special case. Admitting an oversized
    /// entry for the protected key would still push `retainedDiffBytes` over
    /// budget, and because the protected key is the one entry eviction can
    /// never touch, `evictUntilWithinBudget` would then evict *everything
    /// else* trying to close a gap the protected entry alone caused — exactly
    /// the "worse than the re-fetch" outcome this refusal exists to prevent.
    /// The on-screen `perriDetail` still holds whatever's displayed
    /// regardless (RC3), so refusing to cache it costs nothing visible.
    mutating func store(_ detail: PRDetail, forKey key: String, protecting: String?) {
        let diffBytes = detail.diff.utf8.count
        guard diffBytes <= Self.maxRetainedDiffBytes else { return }

        if let existing = entries[key] {
            retainedDiffBytes -= existing.diffBytes
        }
        clock += 1
        entries[key] = Entry(detail: detail, diffBytes: diffBytes, lastUsed: clock)
        retainedDiffBytes += diffBytes

        evictUntilWithinBudget(protecting: protecting)
    }

    /// Read a cached detail, touching its LRU recency (a read is a use).
    mutating func detail(forKey key: String) -> PRDetail? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUsed = clock
        entries[key] = entry
        return entry.detail
    }

    /// Drop a known-stale entry outright (e.g. a SHA-mismatched hit).
    mutating func remove(forKey key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        retainedDiffBytes -= entry.diffBytes
    }

    /// Evict least-recently-used entries (never `protecting`) until both the
    /// byte budget and the entry-count cap are satisfied, or until nothing
    /// evictable remains. Terminates even if the budget stays exceeded — the
    /// only way that happens is when the sole remaining entry is protected,
    /// in which case the overage is simply reported via `retainedDiffBytes`
    /// rather than hidden.
    private mutating func evictUntilWithinBudget(protecting: String?) {
        while retainedDiffBytes > Self.maxRetainedDiffBytes || entries.count > Self.maxRetainedEntries {
            let victim = entries
                .filter { $0.key != protecting }
                .min { $0.value.lastUsed < $1.value.lastUsed }?
                .key
            guard let victim else {
                log.debug("PRDetailCache: eviction budget exceeded with nothing left to evict (protected entry remains)")
                break
            }
            if let entry = entries.removeValue(forKey: victim) {
                retainedDiffBytes -= entry.diffBytes
            }
        }
    }
}
