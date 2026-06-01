import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "files")

/// Polls the flat files that nostromd and Bishop write on a 5-second timer.
///
/// These files are low-frequency writes (rate limits update every few minutes,
/// posture updates on model runs), so polling beats inotify for simplicity.
///
/// In addition, `thresholdEvents` is driven by a live FSEvents watch on
/// `budget-posture.events.jsonl` — no polling, fires within one watch cycle of
/// each append.
class FileWatchers {
    static let shared = FileWatchers()

    let rateLimits   = CurrentValueSubject<RateLimits?,      Never>(nil)
    let posture      = CurrentValueSubject<PostureSnapshot?,  Never>(nil)
    let motherStatus = CurrentValueSubject<MotherStatus,      Never>(MotherStatus())
    /// Items from ~/.claude/state/perri/.queue.cache.json — updated via FSEvents.
    let perriQueue   = CurrentValueSubject<[PRQueueItem],     Never>([])

    /// Fires once per new threshold_crossed line appended to budget-posture.events.jsonl.
    /// History is NOT replayed on startup (seek-to-EOF or last-persisted offset).
    let thresholdEvents = PassthroughSubject<PostureThresholdEvent, Never>()

    private var timer:            Timer?
    private var lastRateLimits:   String?
    private var lastPosture:      String?
    private var lastMotherStatus: String?

    // FSEvent watcher for the perri queue cache file
    private var perriQueueSource: DispatchSourceFileSystemObject?
    private var perriQueueFd:     Int32 = -1

    // FSEvent watcher for budget-posture.events.jsonl
    private var thresholdSource:  DispatchSourceFileSystemObject?
    private var thresholdFd:      Int32 = -1
    private var thresholdOffset:  UInt64 = 0
    private static let thresholdOffsetKey = "nostromo.postureEventsOffset"

    private static var eventsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/budget-posture.events.jsonl")
    }()

    private init() {}

    func start() {
        log.info("FileWatchers starting (5s poll interval)")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
        startPerriQueueWatcher()
        startThresholdWatcher()
    }

    // MARK: - Polling

    private func poll() {
        pollRateLimits()
        pollPosture()
        pollMotherStatus()
    }

    private func pollRateLimits() {
        let content = try? String(contentsOfFile: "/tmp/.claude-rate-limits", encoding: .utf8)
        guard content != lastRateLimits else { return }
        lastRateLimits = content
        let parsed = content.flatMap { RateLimits.parse($0) }
        log.debug("rate-limits changed: \(parsed == nil ? "nil" : "5h=\(parsed!.pct5h)% 7d=\(parsed!.pct7d)%", privacy: .public)")
        rateLimits.send(parsed)
    }

    private func pollPosture() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/budget-posture.json"
        let content = try? String(contentsOfFile: path, encoding: .utf8)
        guard content != lastPosture else { return }
        lastPosture = content
        let snap = PostureSnapshot.load()
        log.debug("budget-posture changed: \(snap?.posture.rawValue ?? "nil", privacy: .public)")
        posture.send(snap)
    }

    private func pollMotherStatus() {
        let content = try? String(contentsOfFile: "/tmp/.mother-statusline", encoding: .utf8)
        guard content != lastMotherStatus else { return }
        lastMotherStatus = content
        let status = content.map { MotherStatus.parse($0) } ?? MotherStatus()
        log.debug("mother-statusline changed: ▶\(status.running, privacy: .public) ⏸\(status.queued, privacy: .public) ?\(status.awaiting, privacy: .public) !\(status.failed, privacy: .public)")
        motherStatus.send(status)
    }

    // MARK: - Perri queue cache watcher

    private static var cacheURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/state/perri/.queue.cache.json")
    }()

    private func startPerriQueueWatcher() {
        // Read immediately so the pane has data before AppStore fires a slow refresh.
        readPerriQueueCache()

        let path = Self.cacheURL.path
        let fd   = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log.warning("perri queue cache not found at \(path, privacy: .public) — watcher skipped")
            return
        }
        perriQueueFd = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask:      [.write, .rename, .delete],
            queue:          .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // After a write/rename, allow the file to flush before reading.
            Thread.sleep(forTimeInterval: 0.05)
            let items = Self.parseCache()
            DispatchQueue.main.async { [weak self] in
                self?.perriQueue.send(items)
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.perriQueueFd, fd >= 0 { close(fd) }
        }
        src.resume()
        perriQueueSource = src
        log.info("perri queue cache watcher active: \(path, privacy: .public)")
    }

    private func readPerriQueueCache() {
        let items = Self.parseCache()
        DispatchQueue.main.async { [weak self] in
            self?.perriQueue.send(items)
        }
    }

    // MARK: - Threshold events watcher (FSEvents, append-only)

    private func startThresholdWatcher() {
        let path = Self.eventsURL.path

        // Create the file if Bishop hasn't written it yet (no-op if it exists).
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log.warning("threshold events: could not open \(path, privacy: .public) — watcher skipped")
            return
        }
        thresholdFd = fd

        // Determine start offset: resume from last-persisted offset if valid,
        // otherwise seek to EOF so we never replay history.
        if let handle = FileHandle(forReadingAtPath: path) {
            let fileSize = handle.seekToEndOfFile()
            handle.closeFile()
            let saved = UInt64(bitPattern: Int64(UserDefaults.standard.integer(forKey: Self.thresholdOffsetKey)))
            if saved > 0 && saved <= fileSize {
                thresholdOffset = saved
                log.info("threshold events: resuming from byte offset \(saved, privacy: .public)")
            } else {
                thresholdOffset = fileSize
                UserDefaults.standard.set(Int(fileSize), forKey: Self.thresholdOffsetKey)
                log.info("threshold events: starting at EOF (\(fileSize, privacy: .public) bytes)")
            }
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask:      [.write, .extend],
            queue:          .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.readThresholdEvents()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.thresholdFd, fd >= 0 { close(fd) }
        }
        src.resume()
        thresholdSource = src
        log.info("threshold events watcher active: \(path, privacy: .public)")
    }

    private func readThresholdEvents() {
        let path = Self.eventsURL.path
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: thresholdOffset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        let text = String(data: data, encoding: .utf8) ?? ""

        // Tolerate partial trailing line: only consume bytes up to the last newline.
        let hasTrailingNewline = text.hasSuffix("\n")
        let allLines = text.components(separatedBy: "\n")
        let completeLines: [String]
        let consumedBytes: UInt64

        if hasTrailingNewline {
            completeLines = allLines.filter { !$0.isEmpty }
            consumedBytes = UInt64(data.count)
        } else {
            // Drop the last incomplete chunk; wait for the next append.
            completeLines = allLines.dropLast().filter { !$0.isEmpty }
            if let lastNL = data.lastIndex(of: 0x0A) {
                consumedBytes = UInt64(data.distance(from: data.startIndex, to: lastNL)) + 1
            } else {
                consumedBytes = 0
            }
        }

        if consumedBytes > 0 {
            thresholdOffset += consumedBytes
            UserDefaults.standard.set(Int(thresholdOffset), forKey: Self.thresholdOffsetKey)
        }

        let events = completeLines.compactMap { parseThresholdLine($0) }
        guard !events.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                self.thresholdEvents.send(event)
            }
        }
    }

    private static let isoFmtFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFmtBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseThresholdLine(_ line: String) -> PostureThresholdEvent? {
        guard let data  = line.data(using: .utf8),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "threshold_crossed",
              let tsStr   = json["ts"]      as? String,
              let window  = json["window"]  as? String,
              let trigger = json["trigger"] as? String
        else { return nil }

        let ts = Self.isoFmtFrac.date(from: tsStr) ?? Self.isoFmtBasic.date(from: tsStr)
        guard let ts else { return nil }

        return PostureThresholdEvent(
            ts:               ts,
            window:           window,
            trigger:          trigger,
            pace:             (json["pace"]             as? NSNumber).map { Float($0.doubleValue) },
            minutesRemaining: json["minutes_remaining"] as? Int
        )
    }

    static func parseCache() -> [PRQueueItem] {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let raw  = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        // Cache may be a bare array (TUI writes) or a wrapped object (perri-queue-pane --json writes)
        let rawItems: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            rawItems = arr
        } else if let obj = raw as? [String: Any], let arr = obj["items"] as? [[String: Any]] {
            rawItems = arr
        } else {
            return []
        }

        return rawItems.compactMap { d in
            guard
                let repo   = d["repo"]   as? String,
                let number = d["number"] as? Int,
                let title  = d["title"]  as? String,
                let author = d["author"] as? String,
                let bucket = d["bucket"] as? String,
                let url    = d["url"]    as? String
            else { return nil }
            return PRQueueItem(repo: repo, number: number, title: title,
                               author: author, bucket: bucket,
                               newActivity: d["new_activity"] as? Bool ?? false,
                               url: url)
        }
    }
}
