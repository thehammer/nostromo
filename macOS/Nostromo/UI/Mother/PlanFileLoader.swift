import Foundation

// Reading a job's plan file for the in-pane plan view (SR7).
//
// A plan path comes from Mother's job record. What is on disk at that path is not ours to trust:
// it may be gone, unreadable, a link to something else, a device or a pipe, huge, or not text. The
// rules live in `PlanFileRules.read` (synchronous, pure, one outcome per call) and `PlanFileLoader`
// runs them off the main thread, drops results that a newer load has overtaken, and watches the file.
// Nothing here logs a path or a byte of the file.

// MARK: - Outcome

/// What reading a plan file produced: exactly one of these.
enum PlanFileResult: Equatable {
    /// `url` is the resolved path (symlinks followed) that was read.
    case loaded(text: String, url: URL, modified: Date?)
    case notFound
    /// Permissions or an I/O error.
    case notReadable
    /// Not a regular `.md`/`.markdown`/`.mdown` file once links are resolved. Never read.
    case notMarkdown
    case tooLarge
    case notUTF8
}

// MARK: - Rules

enum PlanFileRules {

    /// 1 MiB.
    static let maxBytes = 1_048_576
    static let extensions: Set<String> = ["md", "markdown", "mdown"]

    /// Resolve links; the resolved path must be a regular markdown file (else `notMarkdown`, unread);
    /// its size by `stat` must be at most `maxBytes` (else `tooLarge`, unread); then read it and
    /// decode it as UTF-8 (else `notUTF8`). Blocking: call off the main thread.
    static func read(path: String) -> PlanFileResult {
        guard !path.isEmpty else { return .notFound }
        guard let resolved = resolve(path) else {
            return errno == EACCES ? .notReadable : .notFound
        }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return errno == EACCES ? .notReadable : .notFound }
        let ext = (resolved as NSString).pathExtension.lowercased()
        guard (info.st_mode & S_IFMT) == S_IFREG, extensions.contains(ext) else { return .notMarkdown }
        guard info.st_size <= off_t(maxBytes) else { return .tooLarge }

        // O_NONBLOCK so a file swapped for a pipe after the checks above cannot hang the read;
        // the descriptor is checked again, so what is read is what was checked.
        let fd = open(resolved, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return errno == ENOENT ? .notFound : .notReadable }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { return .notReadable }
        guard (opened.st_mode & S_IFMT) == S_IFREG else { return .notMarkdown }
        guard opened.st_size <= off_t(maxBytes) else { return .tooLarge }

        guard let data = readAll(fd, limit: maxBytes) else { return .notReadable }
        guard data.count <= maxBytes else { return .tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { return .notUTF8 }
        return .loaded(text: text, url: URL(fileURLWithPath: resolved), modified: modificationDate(info))
    }

    /// `realpath`: every link followed. Nil when the path does not resolve (`errno` says why).
    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// At most `limit + 1` bytes: one over tells the caller the file grew past the cap while it was read.
    private static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, limit + 1 - data.count)) }
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    private static func modificationDate(_ info: stat) -> Date? {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }
}

// MARK: - Scheduling (injectable)

/// A pending piece of work that can still be called off.
protocol PlanReloadToken: AnyObject {
    func cancel()
}

/// Runs `work` once after `delay`. The real one uses the main queue; a test fires it by hand.
protocol PlanReloadScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> PlanReloadToken
}

final class MainQueuePlanReloadScheduler: PlanReloadScheduler {

    private final class Token: PlanReloadToken {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> PlanReloadToken {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Token(item)
    }
}

// MARK: - Loader

/// Reads a plan file off the main thread and keeps watching it.
///
/// Every load (a new path, or a reload after the file changed) takes a new generation number.
/// A result is delivered, on the main thread, only if its generation is still the current one, so a
/// slow read of an old path can never overwrite a newer one. While the file is not there (`.notFound`:
/// it does not exist yet, or was deleted and has not come back) there is nothing to watch, so the
/// loader asks again on the scheduler, after 0.5 s, then 1 s, 2 s, ... never more than 30 s apart,
/// until the file shows up or the loader is stopped. Not thread-safe: use it from the main thread.
final class PlanFileLoader {

    typealias Reader = (String) -> PlanFileResult

    /// Called on the main thread with the result of the newest load only.
    var onResult: ((PlanFileResult) -> Void)?

    /// Incremented by every load and by `stop`. A result carries the number it was started under.
    private(set) var generation = 0
    private(set) var path: String?
    /// A file-system source is armed on the file.
    var isWatching: Bool { source != nil }
    /// A change was seen and its reload has not run yet.
    var hasPendingReload: Bool { pending != nil }
    /// The file was not found and another look is scheduled.
    var hasPendingRetry: Bool { retry != nil }
    /// How many looks in a row found no file (0 once one did).
    private(set) var retryAttempt = 0

    /// The wait before look number `attempt` (0-based) after a `.notFound`: doubles from 0.5 s, 30 s at most.
    static func retryDelay(afterAttempts attempt: Int) -> TimeInterval {
        min(maxRetryDelay, baseRetryDelay * pow(2, Double(min(attempt, 16))))
    }
    static let baseRetryDelay: TimeInterval = 0.5
    static let maxRetryDelay: TimeInterval = 30

    private let reader: Reader
    private let scheduler: PlanReloadScheduler
    private let readQueue: DispatchQueue
    private let watchQueue = DispatchQueue(label: "com.hammer.nostromo.plan-watch", qos: .utility)
    /// Events are coalesced over this long before a reload.
    let debounce: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var pending: PlanReloadToken?
    private var retry: PlanReloadToken?

    init(reader: @escaping Reader = PlanFileRules.read(path:),
         scheduler: PlanReloadScheduler = MainQueuePlanReloadScheduler(),
         readQueue: DispatchQueue = .global(qos: .utility),
         debounce: TimeInterval = 0.3) {
        self.reader = reader
        self.scheduler = scheduler
        self.readQueue = readQueue
        self.debounce = debounce
    }

    deinit { disarm() }

    /// Start reading `path` and watching it. A nil or empty path stops everything: nothing is read.
    func load(path newPath: String?) {
        disarm()
        retryAttempt = 0
        path = (newPath?.isEmpty ?? true) ? nil : newPath
        generation += 1
        guard let path else { return }
        start(path: path, generation: generation)
    }

    /// Read the current path again now (the view came back, or the user asked). A no-op without a path.
    func reload() {
        guard let path else { return }
        disarm()
        generation += 1
        start(path: path, generation: generation)
    }

    /// Stop watching and drop anything still in flight. The path is kept: `reload()` starts again.
    func stop() {
        disarm()
        retryAttempt = 0
        generation += 1
    }

    // MARK: Private

    private func start(path: String, generation: Int) {
        let reader = self.reader
        readQueue.async { [weak self] in
            let result = reader(path)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.noteResult(result)
                self.onResult?(result)
            }
        }
        arm(path: path)
    }

    /// Watch the file's current inode. An editor that replaces the file leaves this one behind
    /// (a rename or delete event), which is what the reload then re-arms on.
    private func arm(path: String) {
        guard let resolved = PlanFileRules.resolve(path) else { return }
        let fd = open(resolved, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: watchQueue)
        watcher.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.fileChanged() }
        }
        watcher.setCancelHandler { close(fd) }
        source = watcher
        watcher.resume()
    }

    /// No file: look again later. A file (or any other answer): the watcher is the way to hear about it.
    private func noteResult(_ result: PlanFileResult) {
        guard result == .notFound else {
            retryAttempt = 0
            return
        }
        retry?.cancel()
        let delay = Self.retryDelay(afterAttempts: retryAttempt)
        retryAttempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.reload()
        }
    }

    private func fileChanged() {
        guard source != nil else { return }   // stopped since the event fired
        pending?.cancel()
        pending = scheduler.schedule(after: debounce) { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.reload()
        }
    }

    private func disarm() {
        pending?.cancel()
        pending = nil
        retry?.cancel()
        retry = nil
        source?.cancel()
        source = nil
    }
}
