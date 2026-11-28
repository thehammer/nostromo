// NostromoKit — ContentCache.swift
//
// The phone's last-known content, kept on disk so "can't reach Nostromo" still shows something
// across a relaunch (PRD-AC22). It holds the raw JSON of an ALLOW-LISTED handful of frames: the
// Mother queue, the Perri queue and current PRs, the focus registry and the session list. It never
// holds mail, calendar or todos: Fred and Teri frames are not on the list, so they cannot reach disk
// (Q2, W11-8) however the caller is written.
//
// One JSON file in Application Support, written atomically with `FileProtectionType.complete` on
// iOS and excluded from backup. Writes are debounced; `wipe()` deletes the file synchronously and
// cancels any pending write, so a late write can never bring the content back after a revoke.

import Foundation

public final class ContentCache: @unchecked Sendable {

    /// Wire `type`s the cache accepts. Everything else is dropped without being looked at.
    public static let cachedTypes: Set<String> = [
        "mother_jobs", "perri_state", "focus_list_resp", "focus_registry_updated", "session_list_resp", "hosts",
    ]

    /// Wire `type`s the cache accepts ONLY when they name a satellite host: its held decisions and
    /// approval counts, shown read-only as "Answer it on your Mac". The primary's own are never kept
    /// (a decision's question is the operator's own to answer at the Mac). A `decision_resolved` for
    /// a host is not kept either: it removes the decision it resolved.
    public static let hostedOnlyTypes: Set<String> = ["decision_request", "approval_pending"]

    public struct Frame: Codable, Equatable {
        public let type: String
        public let host: String?
        /// `tag` for `perri_state` and `approval_pending` (one per focus), `request_id` for
        /// `decision_request`; `nil` for the single-instance frames.
        public let key: String?
        public let json: String
    }

    public struct Snapshot: Codable, Equatable {
        public var savedAt: Date
        public var frames: [Frame]
    }

    private let url: URL
    private let now: () -> Date
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.hammer.nostromo.contentcache")

    // All three below are touched only on `queue`.
    private var frames: [String: Frame] = [:]
    private var pendingWrite: DispatchWorkItem?
    private var generation = 0

    public init(url: URL, debounce: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.debounce = debounce
        self.now = now
    }

    /// `Application Support/Nostromo/content-cache.json`.
    public static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Nostromo", isDirectory: true)
            .appendingPathComponent("content-cache.json")
    }

    // MARK: - Read

    /// The saved snapshot, or `nil` when there is none (or it is unreadable).
    public func load() -> Snapshot? {
        queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) else { return nil }
            // Take the saved frames as the live set, so a later write extends them.
            frames = Dictionary(snapshot.frames.map { (Self.slot($0), $0) }, uniquingKeysWith: { _, last in last })
            return snapshot
        }
    }

    // MARK: - Write

    /// Remembers `raw` (one frame about `host`) if its type is on the allow-list, and schedules a
    /// write. Anything else is ignored.
    public func record(host: String?, raw: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let type = json["type"] as? String,
              let text = String(data: raw, encoding: .utf8) else { return }
        if host != nil, type == "decision_resolved" {
            forgetDecision(host: host, requestId: json["request_id"] as? String)
            return
        }
        guard Self.cachedTypes.contains(type) || (host != nil && Self.hostedOnlyTypes.contains(type)) else { return }
        // A registry update replaces the list, so they share a slot.
        let canonical = type == "focus_registry_updated" ? "focus_list_resp" : type
        let frame = Frame(type: canonical, host: host, key: Self.key(type: type, json: json), json: text)
        queue.async { [self] in
            frames[Self.slot(frame)] = frame
            scheduleWrite()
        }
    }

    /// Forgets every held satellite `decision_request`, in memory and on disk (waits for it). The
    /// primary does not retain a satellite's decisions, so once the phone is connected again a held
    /// one cannot be vouched for, and one answered at the Mac meanwhile never sends its
    /// `decision_resolved`: without this it would sit in the file (and reappear on a cold launch).
    public func forgetHostedDecisions() {
        queue.sync {
            let held = frames.filter { $0.value.type == "decision_request" && $0.value.host != nil }.keys
            guard !held.isEmpty else { return }
            for slot in held { frames.removeValue(forKey: slot) }
            persistRemoval()
        }
    }

    /// Writes now (waits for it). The app calls this when it goes to the background.
    public func flush() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            write()
        }
    }

    /// Deletes the file, synchronously, and forgets everything held. Nothing written after this
    /// returns can resurrect the content: a pending write is cancelled and the held frames are gone.
    public func wipe() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            generation += 1
            frames = [:]
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    /// A resolved decision is no longer there to answer: drop it from what is held and from disk.
    private func forgetDecision(host: String?, requestId: String?) {
        guard let requestId else { return }
        let probe = Frame(type: "decision_request", host: host, key: requestId, json: "")
        queue.async { [self] in
            guard frames.removeValue(forKey: Self.slot(probe)) != nil else { return }
            persistRemoval()
        }
    }

    /// Called after `frames` lost something: the file must not outlive it, so rewrite it now (or
    /// delete it when nothing remains, since `write()` keeps the file when there is nothing to write).
    /// Must run on `queue`.
    private func persistRemoval() {
        pendingWrite?.cancel()
        pendingWrite = nil
        if frames.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            write()
        }
    }

    private static func key(type: String, json: [String: Any]) -> String? {
        switch type {
        case "perri_state", "approval_pending": return json["tag"] as? String
        case "decision_request":                return json["request_id"] as? String
        default:                                return nil
        }
    }

    private func scheduleWrite() {
        guard pendingWrite == nil else { return }   // one write per debounce window
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWrite = nil
            self.write()
        }
        pendingWrite = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Must run on `queue`.
    private func write() {
        guard !frames.isEmpty else { return }
        let snapshot = Snapshot(savedAt: now(), frames: frames.values.sorted { Self.slot($0) < Self.slot($1) })
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: Self.writeOptions)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(values)
        } catch {
            // A cache that cannot be written is only a missed optimisation; the live data is unaffected.
        }
    }

    /// How the file is written: atomically, and on iOS with the `complete` data-protection class (the
    /// file is unreadable while the phone is locked). Exposed so the iOS-hosted test can check that
    /// the iOS build asks for it, since the Simulator does not report the class back.
    public static var writeOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        return options
    }

    private static func slot(_ frame: Frame) -> String {
        "\(frame.type)|\(frame.host ?? "")|\(frame.key ?? "")"
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
