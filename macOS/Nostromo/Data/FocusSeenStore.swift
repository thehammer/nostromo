import Foundation
import NostromoKit

/// What the operator last saw of each focus, kept in `UserDefaults` so a relaunch of the app (the daemon
/// still running) does not forget which focuses had something new.
///
/// One entry per focus tag: the activity epoch and the three counters at the moment the focus was last
/// looked at (`FocusSeenMarks`). Bounded like the background-task seen marks (`BackgroundTaskStore`): at
/// most `capacity` tags, the least recently SAVED dropped first. A tag that was dropped is simply a first
/// sight again: it baselines silently, so dropping never raises a mark. A removed focus's entry goes with
/// it (`forget`).
///
/// This is the operator's own bookkeeping. It is never put on the app-control surface or the MCP surface:
/// an agent can neither read what was seen nor mark something seen (pinned in `FocusActivityWiringTests`).
final class FocusSeenStore {
    static let defaultsKey = "nostromo.focus.activity.seen"
    static let capacity = 200

    private struct Entry {
        var marks: FocusSeenMarks
        var usedAt: TimeInterval
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private var entries: [String: Entry] = [:]

    /// `defaults` holds the marks (tests pass their own suite); `now` orders the entries for the LRU.
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        load()
    }

    var tags: Set<String> { Set(entries.keys) }

    /// What was last seen of `tag`. A read is not a use: it does not protect the entry from the LRU.
    func marks(for tag: String) -> FocusSeenMarks? { entries[tag]?.marks }

    func save(_ marks: FocusSeenMarks, for tag: String) {
        entries[tag] = Entry(marks: marks, usedAt: now().timeIntervalSince1970)
        trim()
        persist()
    }

    func forget(tag: String) {
        guard entries.removeValue(forKey: tag) != nil else { return }
        persist()
    }

    // MARK: - Persistence

    private enum Key {
        static let epoch = "e", turns = "t", messages = "m", problems = "p", usedAt = "u"
    }

    private func load() {
        guard let stored = defaults.dictionary(forKey: Self.defaultsKey) else { return }
        for (tag, value) in stored {
            guard let dict = value as? [String: Any],
                  let epoch = dict[Key.epoch] as? String,
                  let turns = dict[Key.turns] as? NSNumber,
                  let messages = dict[Key.messages] as? NSNumber,
                  let problems = dict[Key.problems] as? NSNumber,
                  let usedAt = dict[Key.usedAt] as? NSNumber
            else { continue }
            entries[tag] = Entry(
                marks: FocusSeenMarks(epoch: epoch, turns: turns.uint64Value, messages: messages.uint64Value,
                                      problems: problems.uint64Value),
                usedAt: usedAt.doubleValue)
        }
        // A store written by a build with a bigger cap, or by hand, is brought back inside the bound.
        trim()
    }

    private func persist() {
        let stored: [String: [String: Any]] = entries.mapValues { entry in
            [Key.epoch: entry.marks.epoch,
             Key.turns: NSNumber(value: entry.marks.turns),
             Key.messages: NSNumber(value: entry.marks.messages),
             Key.problems: NSNumber(value: entry.marks.problems),
             Key.usedAt: NSNumber(value: entry.usedAt)]
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private func trim() {
        guard entries.count > Self.capacity else { return }
        let oldest = entries.sorted { $0.value.usedAt < $1.value.usedAt }.prefix(entries.count - Self.capacity)
        for (tag, _) in oldest { entries.removeValue(forKey: tag) }
    }
}
