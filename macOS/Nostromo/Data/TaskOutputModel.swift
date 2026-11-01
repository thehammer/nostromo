import Foundation
import Combine
import NostromoKit

// MARK: - Timers

/// A one-shot timer the model can cancel. Tests pass a scheduler that records them, so "no timer is
/// live after the last holder goes" can be asserted without a clock.
protocol TaskPollTimer: AnyObject {
    func invalidate()
}

/// Runs `work` once after `delay` seconds on the main thread.
typealias TaskPollScheduler = (TimeInterval, @escaping () -> Void) -> TaskPollTimer

/// The real scheduler's timer: on the main run loop in `.common` modes, so output keeps arriving
/// while the user scrolls or drags the window.
final class MainRunLoopPollTimer: TaskPollTimer {
    private var timer: Timer?

    init(delay: TimeInterval, work: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in work() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    static let scheduler: TaskPollScheduler = { delay, work in MainRunLoopPollTimer(delay: delay, work: work) }
}

// MARK: - Sizes

/// How a byte count reads in the truncation line: `8 KB`, `512 KB`, `1.5 MB`, `12 MB` (binary units,
/// one decimal below 10, none at or above it).
enum TaskOutputSize {
    static func text(_ bytes: UInt64) -> String {
        let kib: UInt64 = 1_024, mib: UInt64 = 1_048_576
        if bytes < kib { return "\(bytes) B" }
        if bytes < mib { return "\(bytes / kib) KB" }
        return "\(number(Double(bytes) / Double(mib))) MB"
    }

    private static func number(_ value: Double) -> String {
        if value >= 10 { return String(Int(value.rounded())) }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}

// MARK: - The model

/// One task's output as the viewer and `nostromo-app tasks output` read it: one model per
/// `(tag, taskId)`, shared by both, so they can never disagree.
///
/// **Load ladder.** First the tail (`offset: nil`, 1 MiB). From a file, the window is the last 10 MiB:
/// the model then fetches forward in 1 MiB chunks from the window's start up to where the tail began
/// and inserts that head in front (`.prepended`), so a 2 MB output shows from its first line with no
/// truncation line. From the CLI's own tail (at most 8 KiB) it just holds the tail.
///
/// **Live.** While a holder (a window, an app-control reader) has the model and the task is not over:
/// a file is polled from `end_offset` every 500 ms (appends), the CLI tail every 1 s (replaced in
/// place when it changed). One final read follows the task's end. Polling is a chain of one-shot
/// timers, each scheduled when the last read has finished; the last holder going cancels it.
///
/// **Held text** stays after the task ends and after its file vanishes: only new reads fall back.
///
/// **Publishing.** `changes` carries what changed (`appended`, `prepended`, `replaced`, `status`)
/// and only when something did; deliveries are coalesced to at most four a second, the first at once,
/// later ones folded into one at the window's end (the rule of `BackgroundTaskStore.changes`).
///
/// Main thread only.
final class TaskOutputModel {

    enum State: Equatable {
        case loading
        case ready
        case unavailable
        case error(String)
    }

    /// What a subscriber has to do. `appended` and `prepended` carry the added text; `replaced` means
    /// "read `text` again"; `status` means only the state, size or truncation line changed.
    enum Change: Equatable {
        case appended(String)
        case prepended(String)
        case replaced
        case status
    }

    /// The most one read asks for (the daemon clamps to the same).
    static let readBytes = TaskRequests.maxReadBytes
    /// The most of a file the viewer holds from the end.
    static let windowBytes: UInt64 = 10 * 1_048_576
    /// Past this many held bytes a growing file drops its oldest lines back to `windowBytes`.
    static let ceilingBytes = 20 * 1_048_576
    static let filePollInterval: TimeInterval = 0.5
    static let tailPollInterval: TimeInterval = 1
    static let minimumInterval: TimeInterval = 0.25

    let tag: String
    let taskId: String
    let changes = PassthroughSubject<Change, Never>()

    private(set) var text = ""
    /// Output before `text` is not shown (the file was longer than the window, or the CLI tail is a tail).
    private(set) var truncatedHead = false
    private(set) var totalBytes: UInt64 = 0
    private(set) var source: TaskOutputSourceWire?
    private(set) var state: State = .loading
    /// The head of the file is still being fetched in front of the tail.
    private(set) var isFillingHead = false
    /// A reload of the tail is in flight because a holder arrived on a ready model (a repeat ask): what
    /// `text` holds may be older than the file, so `tasks output` says `loading` until it lands.
    private(set) var isRefreshing = false
    private var headFetchFailed = false
    /// UTF-8 bytes of `text` (what the registry's cap counts).
    private(set) var heldBytes = 0
    /// Windows and app-control readers using the model now.
    private(set) var holderCount = 0
    /// The registry's recency stamp (higher: more recent).
    var lastUsed = 0
    /// Told when `heldBytes` changed.
    var onHeldBytesChanged: ((TaskOutputModel) -> Void)?

    private(set) var isTaskEnded: Bool

    /// `failed`: a try that may work next time (no answer, unavailable): polls and `acquire()` try again.
    /// `errored`: the daemon refused or could not read: only a new holder (`acquire()`) tries again.
    private enum Phase { case idle, loadingTail, ready, failed, errored, vanished }

    private var phase = Phase.idle
    private var cursor: UInt64 = 0
    private var readInFlight = false
    /// Bumped by every tail load: a head chunk that answers for an older load is dropped.
    private var loadGeneration = 0
    /// Consecutive polls the daemon answered with an error outcome; a few in a row mean the file is gone.
    private var failedPolls = 0
    private static let failedPollLimit = 3
    private var needsFinalRead = false
    private var pollTimer: TaskPollTimer?
    private var coalesceTimer: TaskPollTimer?
    private var deliveryScheduled = false
    private var lastDelivery: Date?
    private var pendingAppend = ""
    private var pendingPrepend = ""
    private var pendingReplace = false
    private var pendingStatus = false

    private let requests: TaskRequests
    private let schedule: TaskPollScheduler
    private let now: () -> Date

    init(tag: String, taskId: String, isTaskEnded: Bool = false,
         requests: TaskRequests = .shared,
         schedule: @escaping TaskPollScheduler = MainRunLoopPollTimer.scheduler,
         now: @escaping () -> Date = Date.init) {
        self.tag = tag
        self.taskId = taskId
        self.isTaskEnded = isTaskEnded
        self.requests = requests
        self.schedule = schedule
        self.now = now
    }

    deinit {
        pollTimer?.invalidate()
        coalesceTimer?.invalidate()
    }

    // MARK: Reading

    /// `Showing the last 10 MB of 12 MB` or `Showing the last 8 KB of 40 KB`; nil when nothing is cut.
    var truncationNotice: String? {
        guard truncatedHead else { return nil }
        switch source {
        case .file? where !headFetchFailed:
            return "Showing the last \(TaskOutputSize.text(min(Self.windowBytes, totalBytes))) of \(TaskOutputSize.text(totalBytes))"
        case .file?:
            // The head did not come: say what is actually held.
            return "Showing the last \(TaskOutputSize.text(UInt64(heldBytes))) of \(TaskOutputSize.text(totalBytes))"
        default:
            let tailBytes = UInt64(heldBytes)
            return "Showing the last \(tailBytes / 1_024) KB of \(TaskOutputSize.text(totalBytes))"
        }
    }

    /// `loading`, `ready`, `unavailable` or `error` (what `tasks output` reports).
    var stateName: String {
        switch state {
        case .loading: return "loading"
        case .ready: return "ready"
        case .unavailable: return "unavailable"
        case .error: return "error"
        }
    }

    /// A live timer exists (a poll or a coalesced delivery).
    var hasLiveTimer: Bool { pollTimer != nil || coalesceTimer != nil }

    // MARK: Holders

    /// A window or reader starts using the model: the first one starts the load; polling runs while any holds it.
    func acquire() {
        holderCount += 1
        switch phase {
        case .idle:
            loadTail()
        case .failed where !isTaskEnded || text.isEmpty, .errored:
            loadTail()
        case .vanished where !isTaskEnded:
            // The file may be back (a running task): read from where we were; a few more failures
            // in a row make it vanished again.
            phase = .ready
            failedPolls = 0
        default:
            break
        }
        if needsFinalRead { finalRead() }
        // A holder arriving on a model that was last read a while ago (a repeat `tasks output`) must see
        // what the file holds now, not wait out a poll.
        if phase == .ready, !isTaskEnded, !readInFlight, pollTimer == nil {
            isRefreshing = true
            read(final: false)
        }
        startPollingIfNeeded()
    }

    /// A holder is done. When the last one goes the timers go with it; the text stays (until evicted).
    func release() {
        holderCount = max(0, holderCount - 1)
        guard holderCount == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        // Nobody is listening, and the next holder reads `text` as it stands: a queued delivery would
        // add the same text a second time.
        dropPending()
    }

    private func dropPending() {
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        deliveryScheduled = false
        pendingAppend = ""
        pendingPrepend = ""
        pendingReplace = false
        pendingStatus = false
    }

    /// The task is over: one last read picks up what it wrote at the end, then polling stops.
    func taskEnded() {
        guard !isTaskEnded else { return }
        isTaskEnded = true
        pollTimer?.invalidate()
        pollTimer = nil
        guard phase == .ready || phase == .loadingTail else { return }
        needsFinalRead = true
        if holderCount > 0 { finalRead() }
    }

    // MARK: Load

    private func loadTail() {
        guard phase != .loadingTail else { return }
        // Only the very first load shows as loading; a retry keeps saying what the last try said.
        if phase == .idle && text.isEmpty { state = .loading }
        phase = .loadingTail
        loadGeneration += 1
        failedPolls = 0
        headFetchFailed = false
        readInFlight = true
        requests.requestOutput(tag: tag, taskId: taskId, offset: nil) { [weak self] reply in
            guard let self else { return }
            self.readInFlight = false
            self.tailArrived(reply)
        }
    }

    private func tailArrived(_ reply: TaskReply<SessionTaskOutputResultWire>) {
        switch reply {
        case .answered(let wire):
            switch wire.outcome {
            case .ok:
                applyTail(wire)
            case .unavailable:
                failLoad(.unavailable, phase: .failed)
            case .refused, .error, .unknown:
                failLoad(.error(wire.message ?? "The daemon could not read this task's output"), phase: .errored)
            }
        case .timedOut:
            failLoad(.error("The daemon did not answer in time"), phase: .failed)
        case .failed(let reason):
            failLoad(.error(reason), phase: .failed)
        }
        if needsFinalRead && phase == .ready { finalRead() }
        scheduleNextPollIfNeeded()
    }

    private func failLoad(_ newState: State, phase failedPhase: Phase) {
        // Held text survives a later failure; the state only speaks while there is none.
        phase = failedPhase
        guard text.isEmpty, state != newState else { return }
        state = newState
        queue(.status)
        flush()
    }

    private func applyTail(_ wire: SessionTaskOutputResultWire) {
        // Everything a subscriber reads is set before the text is, because setting the text can deliver.
        let kind = wire.source ?? .file
        var headStart: UInt64?
        source = kind
        totalBytes = wire.totalBytes
        cursor = wire.endOffset
        phase = .ready
        state = .ready
        let generation = loadGeneration
        if kind == .file {
            let windowStart = totalBytes > Self.windowBytes ? totalBytes - Self.windowBytes : 0
            truncatedHead = windowStart > 0
            if wire.startOffset > windowStart { headStart = windowStart }
        } else {
            truncatedHead = wire.startOffset > 0
        }
        isFillingHead = headStart != nil
        setText(Self.sanitize(wire.text), as: .replaced)
        flush()
        if let headStart { fetchHeadChunk(at: headStart, limit: wire.startOffset, generation: generation, parts: []) }
    }

    /// Fetch `[offset, limit)` forward in chunks and put it in front of what is held.
    /// Only a head that is contiguous from `offset` through `limit`, answered for the load still current,
    /// goes in; anything else would leave a gap or a stale piece in front of the tail.
    private func fetchHeadChunk(at offset: UInt64, limit: UInt64, generation: Int, parts: [String]) {
        let want = UInt32(min(UInt64(Self.readBytes), limit - offset))
        requests.requestOutput(tag: tag, taskId: taskId, offset: offset, maxBytes: want) { [weak self] reply in
            guard let self, self.loadGeneration == generation else { return }
            var parts = parts
            var complete = false
            // The window start is an arbitrary byte: for the first chunk the daemon skips up to three
            // continuation bytes of a split character and answers from there. Later chunks start at
            // a line boundary and must match exactly.
            let skipAllowed: UInt64 = parts.isEmpty ? 3 : 0
            if case .answered(let wire) = reply, wire.outcome == .ok,
               wire.startOffset >= offset, wire.startOffset - offset <= skipAllowed, wire.endOffset > offset {
                parts.append(Self.sanitize(wire.text))
                if wire.endOffset < limit {
                    self.fetchHeadChunk(at: wire.endOffset, limit: limit, generation: generation, parts: parts)
                    return
                }
                complete = true
            }
            self.isFillingHead = false
            let head = parts.joined()
            if complete, !head.isEmpty {
                self.insertHead(head)
            } else {
                // The daemon could not give the whole head: the tail alone stays, and says it is cut.
                self.truncatedHead = true
                self.headFetchFailed = true
                self.queue(.status)
            }
            self.flush()
        }
    }

    // MARK: Polling

    private func startPollingIfNeeded() {
        guard holderCount > 0, !isTaskEnded, pollTimer == nil, !readInFlight, phase != .vanished, phase != .errored else { return }
        scheduleNextPoll()
    }

    private func scheduleNextPollIfNeeded() {
        guard holderCount > 0, !isTaskEnded, pollTimer == nil, phase != .vanished, phase != .errored else { return }
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        let interval = source == .file || source == nil ? Self.filePollInterval : Self.tailPollInterval
        pollTimer = schedule(interval) { [weak self] in
            guard let self else { return }
            self.pollTimer = nil
            self.pollTick()
        }
    }

    private func pollTick() {
        guard holderCount > 0, !isTaskEnded else { return }
        switch phase {
        case .ready:
            read(final: false)
        case .failed:
            loadTail()
        case .idle, .loadingTail, .errored, .vanished:
            scheduleNextPollIfNeeded()
        }
    }

    private func finalRead() {
        guard phase == .ready, !readInFlight else { return }
        needsFinalRead = false
        read(final: true)
    }

    private func read(final: Bool) {
        guard !readInFlight else { return }
        readInFlight = true
        let viaFile = source == .file
        let offset: UInt64? = viaFile ? cursor : nil
        requests.requestOutput(tag: tag, taskId: taskId, offset: offset) { [weak self] reply in
            guard let self else { return }
            self.readInFlight = false
            self.isRefreshing = false
            var more = false
            if viaFile { more = self.fileReadArrived(reply) } else { self.tailReadArrived(reply) }
            if self.needsFinalRead { self.finalRead() }
            // A file that is ahead of what was read is caught up now, not one chunk per poll.
            if more, !final, self.holderCount > 0, !self.isTaskEnded, !self.readInFlight, self.phase == .ready {
                self.read(final: false)
                return
            }
            if !final { self.scheduleNextPollIfNeeded() }
        }
    }

    /// True when the file holds more past what this read returned, and the next read should follow at once.
    private func fileReadArrived(_ reply: TaskReply<SessionTaskOutputResultWire>) -> Bool {
        guard case .answered(let wire) = reply else { return false }   // no answer: try again at the next poll
        switch wire.outcome {
        case .ok:
            if wire.totalBytes < cursor || (wire.totalBytes > wire.endOffset && wire.totalBytes - wire.endOffset > Self.windowBytes) {
                // The file got shorter (rewritten), or is further ahead than the window: reading it
                // chunk by chunk would only be trimmed away; start again from its end.
                phase = .idle
                loadTail()
                return false
            }
            let before = cursor
            let added = Self.sanitize(wire.text)
            if wire.endOffset > cursor { cursor = wire.endOffset }
            let sizeChanged = wire.totalBytes != totalBytes
            totalBytes = wire.totalBytes
            if !added.isEmpty { appendText(added) }
            if sizeChanged { queue(.status) }
            failedPolls = 0
            flush()
            return cursor > before && cursor < totalBytes
        case .unavailable, .refused, .error, .unknown:
            noteFailedPoll()
            return false
        }
    }

    private func tailReadArrived(_ reply: TaskReply<SessionTaskOutputResultWire>) {
        guard case .answered(let wire) = reply else { return }
        guard wire.outcome == .ok else {
            noteFailedPoll()
            return
        }
        if wire.source == .file {
            // The output file appeared after the first load: read it as a file from now on.
            phase = .idle
            loadTail()
            return
        }
        failedPolls = 0
        let fresh = Self.sanitize(wire.text)
        let cut = wire.startOffset > 0
        let textChanged = fresh != text
        let statusChanged = wire.totalBytes != totalBytes || cut != truncatedHead
        totalBytes = wire.totalBytes
        truncatedHead = cut
        if textChanged { setText(fresh, as: .replaced) } else if statusChanged { queue(.status) }
        flush()
    }

    /// One error answer may be a blip: the poll after it tries again. A few in a row mean the file is
    /// gone or unreadable; held text stays, nothing more is read for it.
    private func noteFailedPoll() {
        failedPolls += 1
        if failedPolls >= Self.failedPollLimit { phase = .vanished }
    }

    // MARK: Text

    private func setText(_ new: String, as change: Change) {
        text = new
        heldBytes = new.utf8.count
        queue(change)
        onHeldBytesChanged?(self)
    }

    private func appendText(_ added: String) {
        text += added
        heldBytes += added.utf8.count
        queue(.appended(added))
        if heldBytes > Self.ceilingBytes { trimOldest() }
        onHeldBytesChanged?(self)
    }

    private func insertHead(_ head: String) {
        text = head + text
        heldBytes += head.utf8.count
        queue(.prepended(head))
        onHeldBytesChanged?(self)
    }

    /// A file that keeps growing: drop the oldest lines so the model stays near the window.
    private func trimOldest() {
        text = Self.lastBytes(of: text, Int(Self.windowBytes))
        heldBytes = text.utf8.count
        truncatedHead = true
        queue(.replaced)
    }

    /// The last `limit` UTF-8 bytes of `text`, starting at a line start when that keeps at least half of
    /// them; otherwise (one huge line) at the first unicode scalar inside the limit. Never empty for a
    /// non-empty text.
    static func lastBytes(of text: String, _ limit: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        let start = utf8.index(utf8.endIndex, offsetBy: -limit)
        var index = start
        while index < utf8.endIndex, utf8[index] != 0x0A { index = utf8.index(after: index) }
        if index < utf8.endIndex {
            let lineStart = utf8.index(after: index)
            if utf8.distance(from: lineStart, to: utf8.endIndex) >= limit / 2 { return String(text[lineStart...]) }
        }
        index = start
        while index < utf8.endIndex, utf8[index] & 0xC0 == 0x80 { index = utf8.index(after: index) }
        return String(text[index...])
    }

    /// The daemon already strips escapes and controls; this is the second line of defence for text
    /// that is drawn and copied. Plain ASCII (the common case) passes through without a scan of scalars.
    static func sanitize(_ raw: String) -> String {
        for byte in raw.utf8 where byte >= 0x80 || byte == 0x7F || (byte < 0x20 && byte != 0x0A && byte != 0x09) {
            return FoldTextSanitizer.sanitizeMultiline(raw)
        }
        return raw
    }

    // MARK: Publishing

    /// Note a change. Nothing is delivered until `flush()`, so what one read changed (the text and the
    /// size line) goes out as one delivery, not two.
    private func queue(_ change: Change) {
        switch change {
        case .appended(let added): pendingAppend += added
        case .prepended(let head): pendingPrepend = head + pendingPrepend
        case .replaced:
            pendingReplace = true
            pendingAppend = ""
            pendingPrepend = ""
        case .status: pendingStatus = true
        }
    }

    /// Deliver what is queued: at once when the last delivery was a quarter second ago or more, else
    /// (once) when that quarter second is up.
    private func flush() {
        guard pendingReplace || pendingStatus || !pendingAppend.isEmpty || !pendingPrepend.isEmpty else { return }
        // No holder: nobody to tell, and the next one reads `text` as it stands.
        guard holderCount > 0 else { return dropPending() }
        let elapsed = lastDelivery.map { now().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minimumInterval {
            coalesceTimer?.invalidate()
            coalesceTimer = nil
            deliveryScheduled = false
            deliver()
        } else if !deliveryScheduled {
            deliveryScheduled = true
            coalesceTimer = schedule(Self.minimumInterval - elapsed) { [weak self] in
                guard let self else { return }
                self.coalesceTimer = nil
                self.deliveryScheduled = false
                self.deliver()
            }
        }
    }

    private func deliver() {
        lastDelivery = now()
        let append = pendingAppend, prepend = pendingPrepend
        let replace = pendingReplace, status = pendingStatus
        pendingAppend = ""
        pendingPrepend = ""
        pendingReplace = false
        pendingStatus = false
        if replace {
            changes.send(.replaced)
        } else {
            if !prepend.isEmpty { changes.send(.prepended(prepend)) }
            if !append.isEmpty { changes.send(.appended(append)) }
        }
        if status { changes.send(.status) }
    }
}

// MARK: - The registry

/// Every task's output model, app-wide (`shared`): the window and `tasks output` ask for the same
/// one. Holds at most 64 MB of text: past that the least recently used models **no window or reader
/// holds** go first (a held model is never evicted). A memory shed by the watchdog drops every
/// unheld model first (`evictUnheld`).
final class TaskOutputRegistry {
    static let shared = TaskOutputRegistry()
    static let capBytes = 64 * 1_048_576

    private struct Key: Hashable {
        let tag: String
        let taskId: String
    }

    private var models: [Key: TaskOutputModel] = [:]
    private var useCounter = 0
    private var storeSubscription: AnyCancellable?

    private let store: BackgroundTaskStore
    private let requests: TaskRequests
    private let schedule: TaskPollScheduler
    private let now: () -> Date
    private let capBytes: Int

    init(store: BackgroundTaskStore = .shared, requests: TaskRequests = .shared,
         schedule: @escaping TaskPollScheduler = MainRunLoopPollTimer.scheduler,
         now: @escaping () -> Date = Date.init, capBytes: Int = TaskOutputRegistry.capBytes) {
        self.store = store
        self.requests = requests
        self.schedule = schedule
        self.now = now
        self.capBytes = capBytes
        // A task that ended gets its model's final read; the model is told once.
        storeSubscription = store.changes.sink { [weak self] tag in self?.syncEndings(tag: tag) }
    }

    var modelCount: Int { models.count }
    var totalHeldBytes: Int { models.values.reduce(0) { $0 + $1.heldBytes } }

    /// The model for this task, made if there is none. Counts as a use.
    func model(tag: String, taskId: String) -> TaskOutputModel {
        let key = Key(tag: tag, taskId: taskId)
        if let existing = models[key] {
            touch(existing)
            return existing
        }
        let model = TaskOutputModel(tag: tag, taskId: taskId, isTaskEnded: isEnded(tag: tag, taskId: taskId),
                                    requests: requests, schedule: schedule, now: now)
        model.onHeldBytesChanged = { [weak self] changed in self?.heldBytesChanged(changed) }
        touch(model)
        models[key] = model
        return model
    }

    /// The model if one exists (no use counted).
    func existingModel(tag: String, taskId: String) -> TaskOutputModel? {
        models[Key(tag: tag, taskId: taskId)]
    }

    /// The focus is gone: its models go with it (a held one is dropped from the registry too; its
    /// window is closed by the same eviction).
    func forget(tag: String) {
        for key in models.keys where key.tag == tag { models.removeValue(forKey: key) }
    }

    /// Drop every model nothing holds: the watchdog's shed path takes these before anything on screen.
    func evictUnheld() {
        for (key, model) in models where model.holderCount == 0 { models.removeValue(forKey: key) }
    }

    /// Mark `model` the most recently used.
    func touch(_ model: TaskOutputModel) {
        useCounter += 1
        model.lastUsed = useCounter
    }

    // MARK: Private

    private func heldBytesChanged(_ changed: TaskOutputModel) {
        touch(changed)
        var total = totalHeldBytes
        guard total > capBytes else { return }
        let candidates = models.filter { $0.value.holderCount == 0 }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, model) in candidates {
            guard total > capBytes else { break }
            total -= model.heldBytes
            models.removeValue(forKey: key)
        }
    }

    private func syncEndings(tag: String) {
        for (key, model) in models where key.tag == tag && !model.isTaskEnded {
            if isEnded(tag: tag, taskId: key.taskId) { model.taskEnded() }
        }
    }

    private func isEnded(tag: String, taskId: String) -> Bool {
        store.state(for: tag)?.allTasks.first { $0.id == taskId }?.status.isTerminal == true
    }
}
