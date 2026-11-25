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

    public struct Frame: Codable, Equatable {
        public let type: String
        public let host: String?
        /// `tag` for `perri_state` (one per focus); `nil` for the single-instance frames.
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
            frames = Dictionary(uniqueKeysWithValues: snapshot.frames.map { (Self.slot($0), $0) })
            return snapshot
        }
    }

    // MARK: - Write

    /// Remembers `raw` (one frame about `host`) if its type is on the allow-list, and schedules a
    /// write. Anything else is ignored.
    public func record(host: String?, raw: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let type = json["type"] as? String, Self.cachedTypes.contains(type),
              let text = String(data: raw, encoding: .utf8) else { return }
        // A registry update replaces the list, so they share a slot.
        let canonical = type == "focus_registry_updated" ? "focus_list_resp" : type
        let frame = Frame(type: canonical, host: host,
                          key: type == "perri_state" ? json["tag"] as? String : nil, json: text)
        queue.async { [self] in
            frames[Self.slot(frame)] = frame
            scheduleWrite()
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
