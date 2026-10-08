import Foundation

/// Outstanding "this focus needs the operator" requests, keyed by request and
/// projected to the set of focus tags that have at least one. A tag stays in
/// the set until EVERY request raised for it is cleared. Generic on purpose:
/// pending decisions use it today; notifications or other attention requests
/// can reuse it by choosing their own key namespace.
struct AttentionRegistry {
    private var tagByKey: [String: String] = [:]

    var tags: Set<String> { Set(tagByKey.values) }

    mutating func raise(tag: String, key: String) { tagByKey[key] = tag }
    mutating func clear(key: String) { tagByKey.removeValue(forKey: key) }
}
