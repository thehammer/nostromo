import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "files")

/// Polls the flat files that nostromd and Bishop write on a 5-second timer.
///
/// These files are low-frequency writes (rate limits update every few minutes,
/// posture updates on model runs), so polling beats inotify for simplicity.
class FileWatchers {
    static let shared = FileWatchers()

    let rateLimits   = CurrentValueSubject<RateLimits?,      Never>(nil)
    let posture      = CurrentValueSubject<PostureSnapshot?,  Never>(nil)
    let motherStatus = CurrentValueSubject<MotherStatus,      Never>(MotherStatus())
    /// Items from ~/.claude/state/perri/.queue.cache.json — updated via FSEvents.
    let perriQueue   = CurrentValueSubject<[PRQueueItem],     Never>([])

    private var timer:           Timer?
    private var lastRateLimits:  String?
    private var lastPosture:     String?
    private var lastMotherStatus: String?

    // FSEvent watcher for the perri queue cache file
    private var perriQueueSource: DispatchSourceFileSystemObject?
    private var perriQueueFd:     Int32 = -1

    private init() {}

    func start() {
        log.info("FileWatchers starting (5s poll interval)")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
        startPerriQueueWatcher()
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
