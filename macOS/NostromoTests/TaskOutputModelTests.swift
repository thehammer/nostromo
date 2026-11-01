import XCTest
import AppKit
import Combine
import NostromoKit

// `TaskOutputModel`, `TaskOutputRegistry` and `TaskOutputSize` (BA4): one task's output as the window and
// `nostromo-app tasks output` read it.
//
// Everything runs against a fake daemon that serves ranged reads over an in-memory "file" (it can grow,
// vanish, be larger than the 10 MB window, be CLI-tail-only) by decoding a `SessionTaskOutputResultWire`
// and handing it to `TaskRequests.ingest`, exactly as `AppStore` does with a frame. Time is a clock the
// test moves and a scheduler that records live timers and runs them on demand: no wall clock, no daemon.
//
// The fakes below are internal (not private) so `AppControlTasksTests` builds its models the same way.

private let mib = 1_048_576

// MARK: - Fakes

final class TaskOutputClock {
    private(set) var date = Date(timeIntervalSince1970: 1_760_000_000)

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

/// Records every timer the model asks for and runs them on demand. A poll timer is half a second or more;
/// a delivery (coalescing) timer is at most a quarter second.
final class TaskOutputManualScheduler {
    final class Slot: TaskPollTimer {
        let delay: TimeInterval
        /// When it falls due on the test's clock.
        let dueAt: Date
        fileprivate var work: (() -> Void)?
        private(set) var isLive = true

        init(delay: TimeInterval, dueAt: Date, work: @escaping () -> Void) {
            self.delay = delay
            self.dueAt = dueAt
            self.work = work
        }

        func invalidate() {
            isLive = false
            work = nil
        }

        fileprivate func take() -> (() -> Void)? {
            let taken = work
            work = nil
            isLive = false
            return taken
        }
    }

    private(set) var slots: [Slot] = []
    /// Set by the rig, so a timer knows when it falls due.
    var clock: TaskOutputClock?

    var live: [Slot] { slots.filter { $0.isLive } }
    var pollSlots: [Slot] { live.filter { $0.delay >= 0.5 } }
    var deliverySlots: [Slot] { live.filter { $0.delay < 0.5 } }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> TaskPollTimer {
        let slot = Slot(delay: delay, dueAt: (clock?.date ?? Date()).addingTimeInterval(delay), work: work)
        slots.append(slot)
        return slot
    }

    func fire(_ slot: Slot) {
        slot.take()?()
    }
}

/// The daemon's side of `session_task_output`: answers from an in-memory file (or the CLI's 8 KiB tail),
/// either at once or when the test says (`defersAnswers`).
final class TaskOutputFakeDaemon: TaskRequestSending {
    struct Read: Equatable {
        let requestId: String
        let tag: String
        let taskId: String
        let offset: UInt64?
        let maxBytes: UInt32
    }

    struct Stop: Equatable {
        let requestId: String
        let tag: String
        let taskId: String
    }

    enum Source { case file, cliTail }

    static let cliTailBytes = 8_192
    static let chunkLimit = 1_048_576
    /// Every fixture line is exactly this many bytes, so byte offsets and line numbers convert.
    static let lineBytes = 64

    weak var requests: TaskRequests?
    var source = Source.file
    /// The output file's bytes; nil: the file is gone.
    var content: Data? = Data()
    /// Answer every read with this outcome (and message) instead of text.
    var failure: (outcome: String, message: String?)?
    /// Hold reads until `answerNext()`.
    var defersAnswers = false
    /// Test hook: every ranged file read answers from this many bytes later than the daemon would (a
    /// `start_offset` that is further from the request than a split scalar can explain).
    var rangedStartShift = 0

    private var files: [String: Data] = [:]
    private var queue: [Read] = []
    private(set) var reads: [Read] = []
    private(set) var stops: [Stop] = []

    var queuedCount: Int { queue.count }

    // MARK: Fixtures

    private static func number(_ index: Int) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// One 64-byte line: `L00000007 xxxx…`. Escaped, it carries a colour sequence in front and a reset behind.
    static func line(_ index: Int, escaped: Bool = false) -> String {
        if escaped { return "\u{1B}[31mL\(number(index))\u{1B}[0m " + String(repeating: "x", count: 44) + "\n" }
        return "L\(number(index)) " + String(repeating: "x", count: 53) + "\n"
    }

    /// What a reader should see of that line once the escapes are gone.
    static func visibleLine(_ index: Int, escaped: Bool = false) -> String {
        escaped ? "L\(number(index)) " + String(repeating: "x", count: 44) + "\n" : line(index)
    }

    static func data(_ range: Range<Int>, escaped: Bool = false) -> Data {
        var data = Data()
        data.reserveCapacity(range.count * lineBytes)
        for index in range { data.append(contentsOf: Array(line(index, escaped: escaped).utf8)) }
        return data
    }

    static func visibleText(_ range: Range<Int>, escaped: Bool = false) -> String {
        range.map { visibleLine($0, escaped: escaped) }.joined()
    }

    func setLines(_ count: Int, escaped: Bool = false) {
        content = Self.data(0..<count, escaped: escaped)
    }

    func appendLines(_ count: Int) {
        let have = (content?.count ?? 0) / Self.lineBytes
        content = (content ?? Data()) + Self.data(have..<(have + count))
    }

    func setText(_ text: String) {
        content = Data(text.utf8)
    }

    /// A different file for one task (the default `content` serves the rest).
    func serve(_ data: Data, forTask taskId: String) {
        files[taskId] = data
    }

    // MARK: TaskRequestSending

    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        let read = Read(requestId: requestId, tag: tag, taskId: taskId, offset: offset, maxBytes: maxBytes)
        reads.append(read)
        if defersAnswers { queue.append(read) } else { answer(read) }
    }

    func sendTaskStop(requestId: String, tag: String, taskId: String) {
        stops.append(Stop(requestId: requestId, tag: tag, taskId: taskId))
    }

    // MARK: Answering

    func answerNext() {
        guard !queue.isEmpty else { return }
        answer(queue.removeFirst())
    }

    func dropQueued() {
        queue.removeAll()
    }

    /// How many of the (up to three) bytes at `from` are the continuation bytes of a scalar the read
    /// started inside (`leading_skip` in `src/ipc/task_output.rs`).
    private static func leadingContinuationBytes(_ data: Data, from: Int, limit: Int) -> Int {
        var skip = 0
        while skip < 3, from + skip < limit, data[from + skip] & 0xC0 == 0x80 { skip += 1 }
        return skip
    }

    /// Where a chunk that stopped short of the end of the file ends (`safe_end`): after the last newline in
    /// `[from, to)` when it holds one, else not inside a UTF-8 scalar.
    private static func safeEnd(_ data: Data, from: Int, to: Int) -> Int {
        guard from < to else { return to }
        if let newline = data[from..<to].lastIndex(of: 0x0A) { return newline + 1 }
        var back = 0
        while back < 3, back < to - from {
            let byte = data[to - 1 - back]
            if byte & 0xC0 == 0x80 {
                back += 1
                continue
            }
            let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : (byte >= 0xC0 ? 2 : 1))
            return needed > back + 1 ? to - (back + 1) : to
        }
        return to
    }

    private func answer(_ read: Read) {
        var json: [String: Any] = ["request_id": read.requestId, "tag": read.tag, "task_id": read.taskId]
        let served = files[read.taskId] ?? content
        if let failure {
            json["outcome"] = failure.outcome
            if let message = failure.message { json["message"] = message }
        } else if let served {
            let total = UInt64(served.count)
            let start: UInt64
            let end: UInt64
            switch source {
            case .file:
                // Like the real daemon: a read starts at an arbitrary byte, skips the rest of a scalar it
                // began inside, and (short of the end of the file) stops after the last newline it holds.
                let wanted = Int(min(UInt64(read.maxBytes), UInt64(Self.chunkLimit)))
                let size = served.count
                if let offset = read.offset {
                    var from = Int(min(offset, total))
                    let windowEnd = min(size, from + wanted)
                    if offset > 0 { from += Self.leadingContinuationBytes(served, from: from, limit: windowEnd) }
                    from = min(from + Int(rangedStartShift), size)
                    let to = windowEnd < size ? max(from, Self.safeEnd(served, from: from, to: windowEnd)) : max(from, windowEnd)
                    start = UInt64(from)
                    end = UInt64(to)
                } else {
                    var from = size - min(size, wanted)
                    if from > 0 { from += Self.leadingContinuationBytes(served, from: from, limit: size) }
                    start = UInt64(from)
                    end = total
                }
            case .cliTail:
                start = total - min(total, UInt64(Self.cliTailBytes))
                end = total
            }
            json["outcome"] = "ok"
            json["source"] = source == .file ? "file" : "cli_tail"
            json["start_offset"] = start
            json["end_offset"] = end
            json["total_bytes"] = total
            json["text"] = String(decoding: served.subdata(in: Int(start)..<Int(end)), as: UTF8.self)
        } else {
            json["outcome"] = "unavailable"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let wire = try? JSONDecoder().decode(SessionTaskOutputResultWire.self, from: data)
        else { return XCTFail("the fake daemon built an answer that does not decode") }
        requests?.ingest(.sessionTaskOutputResult(wire))
    }
}

/// What a test hangs on to: the daemon, the scheduler, the clock and the `TaskRequests` between them.
final class TaskOutputRig {
    private final class Ids {
        var next = 0
        func make() -> String { next += 1; return "req-\(next)" }
    }

    /// The request timeouts `TaskRequests` asked for (the model tests rarely fire them).
    final class Timeouts {
        private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        func add(_ delay: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((delay, work)) }
        func fireAll() {
            let due = scheduled
            scheduled = []
            for item in due { item.work() }
        }
    }

    let daemon = TaskOutputFakeDaemon()
    let scheduler = TaskOutputManualScheduler()
    let clock = TaskOutputClock()
    let timeouts: Timeouts
    let requests: TaskRequests

    init() {
        let timeouts = Timeouts()
        let ids = Ids()
        self.timeouts = timeouts
        requests = TaskRequests(makeRequestId: { ids.make() }, schedule: { delay, work in timeouts.add(delay, work) })
        requests.sender = daemon
        daemon.requests = requests
        scheduler.clock = clock
    }

    func makeModel(tag: String = "kate", taskId: String = "t1", ended: Bool = false) -> TaskOutputModel {
        TaskOutputModel(tag: tag, taskId: taskId, isTaskEnded: ended, requests: requests,
                        schedule: scheduler.schedule, now: { [clock] in clock.date })
    }

    func makeRegistry(store: BackgroundTaskStore, capBytes: Int = TaskOutputRegistry.capBytes) -> TaskOutputRegistry {
        TaskOutputRegistry(store: store, requests: requests, schedule: scheduler.schedule,
                           now: { [clock] in clock.date }, capBytes: capBytes)
    }

    /// Answer everything held, moving the clock between answers so each delivery goes out at once.
    func drainAnswers(advancing step: TimeInterval = 0.3) {
        while daemon.queuedCount > 0 {
            clock.advance(step)
            daemon.answerNext()
        }
    }

    func firePoll() throws {
        let slot = try XCTUnwrap(scheduler.pollSlots.first, "no poll timer is live")
        scheduler.fire(slot)
    }

    /// Let a coalesced delivery go out.
    func flushDeliveries() {
        clock.advance(0.25)
        for slot in scheduler.deliverySlots { scheduler.fire(slot) }
    }
}

/// What a model told its subscribers.
final class TaskOutputChangeLog {
    private(set) var events: [TaskOutputModel.Change] = []
    private var subscription: AnyCancellable?

    init(_ model: TaskOutputModel) {
        subscription = model.changes.sink { [weak self] in self?.events.append($0) }
    }

    /// The events that carry content: everything but the `.status` that rides along with a size change.
    var contentEvents: [TaskOutputModel.Change] { events.filter { $0 != .status } }

    /// The events as short names with payload sizes, for failure messages that must not print megabytes.
    var kinds: [String] {
        events.map { event in
            switch event {
            case .appended(let text): return "appended(\(text.utf8.count))"
            case .prepended(let text): return "prepended(\(text.utf8.count))"
            case .replaced: return "replaced"
            case .status: return "status"
            }
        }
    }

    func drain() -> [TaskOutputModel.Change] {
        defer { events = [] }
        return events
    }
}

/// Equality for texts of megabytes: on a difference it says where, instead of printing both.
func assertSameLargeText(_ actual: String, _ expected: String, _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) {
    guard actual != expected else { return }
    let a = Array(actual.utf8)
    let e = Array(expected.utf8)
    let firstDifference = zip(a, e).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, e.count)
    XCTFail("\(what): \(a.count) bytes, expected \(e.count); the first difference is at byte \(firstDifference)",
            file: file, line: line)
}

// MARK: - Sizes

final class TaskOutputSizeTests: XCTestCase {

    func testSizesReadInBinaryUnitsWithOneDecimalBelowTen() {
        XCTAssertEqual(TaskOutputSize.text(0), "0 B")
        XCTAssertEqual(TaskOutputSize.text(512), "512 B")
        XCTAssertEqual(TaskOutputSize.text(1_023), "1023 B")
        XCTAssertEqual(TaskOutputSize.text(1_024), "1 KB")
        XCTAssertEqual(TaskOutputSize.text(8_192), "8 KB")
        XCTAssertEqual(TaskOutputSize.text(40_000), "39 KB", "a partial kilobyte is dropped, not rounded up")
        XCTAssertEqual(TaskOutputSize.text(524_288), "512 KB")
        XCTAssertEqual(TaskOutputSize.text(UInt64(mib)), "1 MB")
        XCTAssertEqual(TaskOutputSize.text(UInt64(mib * 3 / 2)), "1.5 MB")
        XCTAssertEqual(TaskOutputSize.text(UInt64(10 * mib)), "10 MB")
        XCTAssertEqual(TaskOutputSize.text(UInt64(12 * mib)), "12 MB")
        XCTAssertEqual(TaskOutputSize.text(UInt64(64 * mib)), "64 MB")
    }
}

// MARK: - The model

final class TaskOutputModelTests: XCTestCase {

    // MARK: Fixtures

    /// A model over `count` fixture lines, loaded, and released when the test ends.
    private func open(_ rig: TaskOutputRig, lines count: Int, escaped: Bool = false, ended: Bool = false) -> TaskOutputModel {
        rig.daemon.setLines(count, escaped: escaped)
        let model = rig.makeModel(ended: ended)
        model.acquire()
        rig.drainAnswers()
        addTeardownBlock { model.release() }
        return model
    }

    private func visible(_ range: Range<Int>, escaped: Bool = false) -> String {
        TaskOutputFakeDaemon.visibleText(range, escaped: escaped)
    }

    // MARK: - The load ladder

    func testTheFirstRequestAsksForTheTailOfTheOutput() throws {
        let rig = TaskOutputRig()
        _ = open(rig, lines: 10)

        let first = try XCTUnwrap(rig.daemon.reads.first)
        XCTAssertNil(first.offset, "the first read is the tail")
        XCTAssertEqual(first.maxBytes, UInt32(mib), "at most 1 MiB")
        XCTAssertEqual(first.tag, "kate")
        XCTAssertEqual(first.taskId, "t1")
    }

    func testAnOutputThatFitsInOneReadIsShownWholeAfterThatOneRead() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 100)

        XCTAssertEqual(rig.daemon.reads.count, 1)
        XCTAssertEqual(model.text, visible(0..<100))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.totalBytes, 6_400)
        XCTAssertEqual(model.source, .file)
        XCTAssertFalse(model.isFillingHead)
        XCTAssertNil(model.truncationNotice)
    }

    func testAnEmptyFileIsReadyWithNoTextAndNoNotice() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 0)

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.totalBytes, 0)
        XCTAssertNil(model.truncationNotice)
    }

    func testALongerFileIsReadForwardInOneMegabyteChunksUpToWhereTheTailBegan() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(3 * mib / 64)        // 3 MiB
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .loading)
        XCTAssertTrue(model.text.isEmpty)

        rig.daemon.answerNext()      // the tail: the last 1 MiB, from 2 MiB
        XCTAssertEqual(model.text.utf8.count, mib)
        XCTAssertTrue(model.isFillingHead, "the head is still being read")
        XCTAssertEqual(rig.daemon.reads.count, 2)
        XCTAssertEqual(rig.daemon.reads[1].offset, 0, "forward from the start of the window")
        XCTAssertLessThanOrEqual(rig.daemon.reads[1].maxBytes, UInt32(mib))

        rig.daemon.answerNext()      // [0, 1 MiB)
        XCTAssertTrue(model.isFillingHead)
        XCTAssertEqual(rig.daemon.reads[2].offset, UInt64(mib))
        XCTAssertLessThanOrEqual(rig.daemon.reads[2].maxBytes, UInt32(mib))

        rig.daemon.answerNext()      // [1 MiB, 2 MiB): the head is complete
        XCTAssertFalse(model.isFillingHead)
        XCTAssertEqual(rig.daemon.reads.count, 3, "nothing more is asked for")
        assertSameLargeText(model.text, visible(0..<(3 * mib / 64)), "the whole output, in order, from its first line")
        XCTAssertEqual(model.state, .ready)
    }

    func testTheHeadArrivesAsOnePrependAfterTheTailWasShown() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(3 * mib / 64)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        let log = TaskOutputChangeLog(model)
        model.acquire()
        addTeardownBlock { model.release() }

        rig.drainAnswers()

        XCTAssertEqual(log.kinds, ["replaced", "prepended(\(2 * mib))"],
                       "the tail first, then the head in front of it once, however many chunks it took")
        if case .prepended(let head)? = log.events.last {
            assertSameLargeText(head, visible(0..<(2 * mib / 64)), "the prepended head")
        }
    }

    func testAnOutputOfTwoMegabytesWithEscapeSequencesShowsEverythingFromItsFirstLineAndNoTruncationLine() {
        let rig = TaskOutputRig()
        let lineCount = 2 * mib / 64
        let model = open(rig, lines: lineCount, escaped: true)

        XCTAssertNil(model.truncationNotice, "2 MB is under the 10 MB window: no truncation line")
        XCTAssertFalse(model.truncatedHead)
        XCTAssertFalse(model.text.utf8.contains(0x1B), "no escape byte survives")
        XCTAssertTrue(model.text.hasPrefix(TaskOutputFakeDaemon.visibleLine(0, escaped: true)), "it starts at the first line")
        XCTAssertTrue(model.text.hasSuffix(TaskOutputFakeDaemon.visibleLine(lineCount - 1, escaped: true)))
        XCTAssertEqual(model.text.utf8.filter { $0 == 0x0A }.count, lineCount, "every line is there")
        assertSameLargeText(model.text, visible(0..<lineCount, escaped: true), "the 2 MB output")
    }

    func testAnOutputOfTwelveMegabytesShowsTheLastTenAndSaysSo() {
        let rig = TaskOutputRig()
        let lineCount = 12 * mib / 64
        let model = open(rig, lines: lineCount)

        XCTAssertEqual(model.truncationNotice, "Showing the last 10 MB of 12 MB")
        XCTAssertTrue(model.truncatedHead)
        XCTAssertEqual(model.totalBytes, UInt64(12 * mib))
        XCTAssertEqual(model.text.utf8.count, 10 * mib)
        assertSameLargeText(model.text, visible((2 * mib / 64)..<lineCount),
                            "the last 10 MB, contiguous, ending at the last line")
        XCTAssertFalse(model.isFillingHead)
    }

    func testALongOutputIsReadForwardFromTheStartOfTheLastTenMegabytes() {
        let rig = TaskOutputRig()
        _ = open(rig, lines: 12 * mib / 64)

        let reads = rig.daemon.reads
        XCTAssertNil(reads[0].offset)
        let head = Array(reads.dropFirst())
        XCTAssertEqual(head.compactMap(\.offset), (2...10).map { UInt64($0 * mib) },
                       "9 forward chunks from 2 MiB (12 minus 10) up to where the tail began at 11 MiB")
        for read in head { XCTAssertLessThanOrEqual(read.maxBytes, UInt32(mib)) }
    }

    func testAnOutputOfExactlyTenMegabytesIsShownWholeWithNoTruncationLine() {
        let rig = TaskOutputRig()
        let lineCount = 10 * mib / 64
        let model = open(rig, lines: lineCount)

        XCTAssertNil(model.truncationNotice)
        XCTAssertEqual(model.text.utf8.count, 10 * mib)
        XCTAssertTrue(model.text.hasPrefix(TaskOutputFakeDaemon.visibleLine(0)))
    }

    func testTheCliTailOfALongOutputShowsItsEndAndSaysHowMuchThereIs() {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        let model = open(rig, lines: 625)      // 40 000 bytes; the CLI keeps the last 8 KiB

        XCTAssertEqual(model.source, .cliTail)
        XCTAssertEqual(model.truncationNotice, "Showing the last 8 KB of 39 KB")
        XCTAssertTrue(model.truncatedHead)
        XCTAssertEqual(model.text, visible((625 - 128)..<625), "the last 8 KiB, ending at the last line")
        XCTAssertEqual(rig.daemon.reads.count, 1, "a tail has no earlier part to fetch")
        XCTAssertFalse(model.isFillingHead)
        XCTAssertEqual(model.state, .ready)
    }

    func testACliTailShorterThanTheTailWindowIsShownWholeWithNoNotice() {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        let model = open(rig, lines: 20)

        XCTAssertEqual(model.text, visible(0..<20))
        XCTAssertNil(model.truncationNotice)
    }

    func testABinaryNoticeFromTheDaemonIsHeldAsTheText() {
        let rig = TaskOutputRig()
        rig.daemon.setText("[binary output: 4096 bytes not shown]\n")
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.text, "[binary output: 4096 bytes not shown]\n")
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.truncationNotice)
    }

    func testEscapesThatReachTheModelAreStrippedBeforeTheTextIsHeld() {
        let rig = TaskOutputRig()
        rig.daemon.setText("ok \u{1B}[31mred\u{1B}[0m \u{202E}bidi\u{0} end\n")
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.text, "ok red bidi end\n")
    }

    // MARK: - Polling a file

    func testAFileIsPolledEveryHalfSecondFromWhereTheLastReadEnded() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        let log = TaskOutputChangeLog(model)
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [0.5])

        rig.daemon.appendLines(5)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(rig.daemon.reads.last?.offset, 640, "from the end of what was read: 10 lines of 64 bytes")
        XCTAssertEqual(log.contentEvents, [.appended(visible(10..<15))], "only the new text, appended")
        XCTAssertEqual(model.text, visible(0..<15))
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [0.5], "the next poll is waiting")

        rig.daemon.appendLines(2)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(rig.daemon.reads.last?.offset, 960)
        XCTAssertEqual(log.contentEvents.last, .appended(visible(15..<17)))
        XCTAssertEqual(model.text, visible(0..<17))
        XCTAssertEqual(model.totalBytes, 17 * 64)
    }

    func testAPollWithNothingNewPublishesNothing() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        let log = TaskOutputChangeLog(model)

        rig.clock.advance(0.5)
        try rig.firePoll()
        rig.clock.advance(0.5)
        try rig.firePoll()

        XCTAssertEqual(log.events, [], "an unchanged file tells nobody anything")
        XCTAssertTrue(rig.scheduler.deliverySlots.isEmpty, "and schedules no delivery")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "polling goes on")
    }

    func testAnUnchangedCliTailPollPublishesNothing() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        let model = open(rig, lines: 20)
        let log = TaskOutputChangeLog(model)

        rig.clock.advance(1)
        try rig.firePoll()

        XCTAssertEqual(log.events, [])
        XCTAssertTrue(rig.scheduler.deliverySlots.isEmpty)
    }

    func testTheCliTailIsPolledEverySecondAndReplacedInPlaceOnlyWhenItChanged() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        rig.daemon.setText("first\n")
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }
        let log = TaskOutputChangeLog(model)
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [1], "a CLI tail is polled every second")

        rig.clock.advance(1)
        try rig.firePoll()
        XCTAssertNil(rig.daemon.reads.last?.offset, "a tail is asked for again, not read forward")
        XCTAssertEqual(log.events, [], "same text: nothing replaced")
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [1])

        rig.daemon.setText("second\n")
        rig.clock.advance(1)
        try rig.firePoll()
        XCTAssertEqual(log.events, [.replaced], "new text replaces the old in place")
        XCTAssertEqual(model.text, "second\n")
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [1])
    }

    func testAFileRewrittenShorterIsReadAgainFromItsTail() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        let log = TaskOutputChangeLog(model)

        rig.daemon.setText("fresh\n")
        rig.clock.advance(0.5)
        try rig.firePoll()

        XCTAssertEqual(model.text, "fresh\n", "what was held no longer matches the file")
        XCTAssertEqual(log.events, [.replaced])
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1)
    }

    // MARK: - The task ends

    func testTheTaskEndingGetsOneLastReadAndThenNoMore() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        let log = TaskOutputChangeLog(model)
        let readsBefore = rig.daemon.reads.count

        rig.daemon.appendLines(3)
        rig.clock.advance(0.3)
        model.taskEnded()

        XCTAssertEqual(rig.daemon.reads.count, readsBefore + 1, "one final read")
        XCTAssertEqual(rig.daemon.reads.last?.offset, 640)
        XCTAssertEqual(log.contentEvents, [.appended(visible(10..<13))])
        XCTAssertEqual(model.text, visible(0..<13))
        XCTAssertTrue(rig.scheduler.live.isEmpty, "no poll is left")
        XCTAssertFalse(model.hasLiveTimer)
    }

    func testATaskThatEndsWhileAPollIsInFlightStillGetsALastRead() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        rig.daemon.defersAnswers = true
        rig.clock.advance(0.5)
        try rig.firePoll()                      // a poll is out
        rig.daemon.appendLines(2)
        model.taskEnded()                       // the task ends before it is answered
        rig.daemon.answerNext()                 // the poll's answer: the first two new lines
        XCTAssertEqual(rig.daemon.queuedCount, 1, "the last read follows the poll that was out")
        rig.daemon.appendLines(2)               // what the task wrote at the very end
        rig.clock.advance(0.5)
        rig.daemon.answerNext()

        XCTAssertEqual(model.text, visible(0..<14), "everything, including what came last")
        XCTAssertTrue(rig.scheduler.live.isEmpty)
    }

    func testATaskThatEndsDuringTheFirstLoadStillGetsALastRead() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        model.taskEnded()
        rig.daemon.answerNext()                 // the tail
        rig.daemon.appendLines(2)               // written after the tail was read
        rig.clock.advance(0.5)
        rig.drainAnswers()

        XCTAssertEqual(model.text, visible(0..<12))
        XCTAssertTrue(rig.scheduler.live.isEmpty)
    }

    func testATaskThatEndedWithNobodyWatchingGetsItsLastReadWhenSomeoneOpensIt() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        model.release()
        rig.daemon.appendLines(4)
        let readsBefore = rig.daemon.reads.count

        model.taskEnded()
        XCTAssertEqual(rig.daemon.reads.count, readsBefore, "nobody holds the model: nothing is read yet")

        rig.clock.advance(1)
        model.acquire()
        XCTAssertEqual(model.text, visible(0..<14))
        XCTAssertEqual(rig.daemon.reads.count, readsBefore + 1)
        XCTAssertTrue(rig.scheduler.live.isEmpty, "and it does not poll an ended task")
    }

    func testAModelForATaskThatAlreadyEndedLoadsOnceAndNeverPolls() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10, ended: true)

        XCTAssertTrue(model.isTaskEnded)
        XCTAssertEqual(model.text, visible(0..<10))
        XCTAssertEqual(rig.daemon.reads.count, 1)
        XCTAssertTrue(rig.scheduler.live.isEmpty)
    }

    // MARK: - Held text

    func testTheTextStaysReadableAfterTheTaskEndsAndItsFileIsGone() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        model.taskEnded()
        rig.daemon.content = nil

        model.release()
        model.acquire()      // the window is opened again later

        XCTAssertEqual(model.text, visible(0..<20))
        XCTAssertEqual(model.state, .ready, "held text is not turned into an error")
        XCTAssertNil(model.truncationNotice)
    }

    func testAFileThatVanishesWhileTheTaskRunsKeepsItsTextAndStopsPolling() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        let log = TaskOutputChangeLog(model)

        rig.daemon.content = nil
        for _ in 0..<3 {
            rig.clock.advance(0.5)
            try rig.firePoll()
        }

        XCTAssertEqual(model.text, visible(0..<20))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(log.events, [], "the held text is not touched")
        XCTAssertTrue(rig.scheduler.live.isEmpty, "a vanished file is not polled again")
    }

    func testOneErrorAnswerOnAPollDoesNotStopLiveOutput() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)

        rig.daemon.content = nil                // one blip: unavailable
        rig.clock.advance(0.5)
        try rig.firePoll()
        rig.daemon.setLines(12)                 // and it is back
        rig.clock.advance(0.5)
        try rig.firePoll()

        XCTAssertEqual(model.text, visible(0..<12), "the poll after the blip carried on")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "still polling")
    }

    func testAcquiringAReadyRunningModelReadsAtOnceWithoutWaitingForAPoll() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        model.release()
        rig.daemon.appendLines(3)

        model.acquire()

        XCTAssertEqual(model.text, visible(0..<13), "a repeat reader sees what the file holds now")
    }

    func testReleasingDropsQueuedChangesSoAReopenedWindowDoesNotSeeTheTextTwice() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        rig.daemon.appendLines(1)
        try rig.firePoll()                      // inside the quarter second: the append is queued
        XCTAssertEqual(rig.scheduler.deliverySlots.count, 1)
        model.release()

        let shown = model.text                  // a window opens: it reads `text`, then listens
        let log = TaskOutputChangeLog(model)
        model.acquire()
        rig.daemon.appendLines(1)
        rig.clock.advance(1)
        try rig.firePoll()

        XCTAssertEqual(shown, visible(0..<11))
        XCTAssertEqual(model.text, visible(0..<12))
        XCTAssertEqual(log.contentEvents, [.appended(visible(11..<12))],
                       "only text the window has not read: the append queued before the release is gone")
    }

    func testAHeadThatDoesNotLineUpWithItsRequestIsNotInserted() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(40_000)             // past 1 MiB, so there is a head to fetch
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        rig.daemon.answerNext()                 // the tail
        let tail = model.text
        rig.daemon.content = nil                // the head's reads now answer `unavailable`
        rig.daemon.answerNext()

        XCTAssertEqual(model.text, tail, "no head is better than a gapped one")
        XCTAssertFalse(model.isFillingHead)
    }

    func testAnEndedTaskWhoseFileWasNeverThereSaysNoOutputAvailable() {
        let rig = TaskOutputRig()
        rig.daemon.content = nil
        let model = rig.makeModel(ended: true)
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(model.stateName, "unavailable")
        XCTAssertEqual(model.text, "")
    }

    // MARK: - Timers follow the holders

    func testNoTimerIsLiveOnceTheLastHolderReleases() {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        model.acquire()      // a second holder
        XCTAssertEqual(model.holderCount, 2)
        XCTAssertEqual(rig.scheduler.live.count, 1, "two holders still make one poll timer")

        model.release()
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "one holder is left: polling goes on")

        model.release()
        XCTAssertEqual(model.holderCount, 0)
        XCTAssertFalse(model.hasLiveTimer)
        XCTAssertTrue(rig.scheduler.live.isEmpty)
        XCTAssertEqual(model.text, visible(0..<10), "the text stays until the model is evicted")
    }

    func testAPendingCoalescedDeliveryIsCancelledWithTheLastHolder() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        rig.daemon.appendLines(1)
        try rig.firePoll()                     // inside the quarter second after the load: a delivery is waiting
        XCTAssertEqual(rig.scheduler.deliverySlots.count, 1)

        model.release()

        XCTAssertTrue(rig.scheduler.live.isEmpty)
        XCTAssertFalse(model.hasLiveTimer)
    }

    func testAnAnswerThatArrivesAfterTheLastReleaseStartsNoTimer() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        model.release()

        rig.daemon.answerNext()

        XCTAssertTrue(rig.scheduler.live.isEmpty)
        XCTAssertFalse(model.hasLiveTimer)
    }

    func testOpeningAgainAfterTheLastReleaseResumesPollingWithOneTimer() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        model.release()
        rig.daemon.appendLines(2)

        model.acquire()
        model.acquire()

        XCTAssertEqual(rig.scheduler.pollSlots.count, 1)
        rig.clock.advance(1)
        try rig.firePoll()
        XCTAssertEqual(model.text, visible(0..<12), "the file kept growing while nobody watched")
    }

    // MARK: - Coalescing

    func testTheFirstChangeInAQuarterSecondIsDeliveredAtOnce() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 5)
        let log = TaskOutputChangeLog(model)

        rig.clock.advance(0.3)
        rig.daemon.appendLines(1)
        try rig.firePoll()

        XCTAssertEqual(log.contentEvents, [.appended(visible(5..<6))])
        XCTAssertTrue(rig.scheduler.deliverySlots.isEmpty, "nothing was held back")
    }

    func testLaterChangesInsideTheWindowFoldIntoOneDeliveryAtItsEnd() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 5)           // delivered at once: the window opens
        let log = TaskOutputChangeLog(model)

        rig.daemon.appendLines(1)
        try rig.firePoll()                        // 0 ms later
        XCTAssertEqual(log.events, [], "inside the window: held back")
        XCTAssertEqual(rig.scheduler.deliverySlots.count, 1)

        rig.clock.advance(0.1)
        rig.daemon.appendLines(1)
        try rig.firePoll()                        // 100 ms later
        XCTAssertEqual(log.events, [], "still held back")
        XCTAssertEqual(rig.scheduler.deliverySlots.count, 1, "folded into the delivery already due")

        rig.clock.advance(0.15)
        let due = try XCTUnwrap(rig.scheduler.deliverySlots.first)
        rig.scheduler.fire(due)
        XCTAssertEqual(log.contentEvents, [.appended(visible(5..<7))], "one delivery carries both")
        XCTAssertEqual(model.text, visible(0..<7), "and the model itself was never behind")
    }

    func testTheHeldBackDeliveryIsDueWhenTheQuarterSecondWindowEnds() throws {
        let rig = TaskOutputRig()
        _ = open(rig, lines: 5)

        rig.clock.advance(0.1)
        rig.daemon.appendLines(1)
        try rig.firePoll()

        let slot = try XCTUnwrap(rig.scheduler.deliverySlots.first)
        XCTAssertEqual(slot.delay, 0.15, accuracy: 0.001, "250 ms after the last delivery, 100 ms of which have passed")
    }

    func testChangesAreDeliveredAtMostFourTimesASecondAndNothingIsLost() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 5)
        let start = rig.clock.date
        var appendStamps: [TimeInterval] = []
        var appended = ""
        let subscription = model.changes.sink { change in
            if case .appended(let text) = change {
                appendStamps.append(rig.clock.date.timeIntervalSince(start))
                appended += text
            }
        }
        defer { subscription.cancel() }

        // A change every 50 ms for two seconds (faster than the poll cadence on purpose: this is the
        // coalescer under load). A held-back delivery runs when it falls due on the clock.
        for _ in 0..<40 {
            rig.clock.advance(0.05)
            for slot in rig.scheduler.deliverySlots where slot.dueAt <= rig.clock.date { rig.scheduler.fire(slot) }
            rig.daemon.appendLines(1)
            try rig.firePoll()
        }
        rig.clock.advance(0.25)
        for slot in rig.scheduler.deliverySlots { rig.scheduler.fire(slot) }

        XCTAssertEqual(appended, visible(5..<45), "every line arrived once, in order")
        XCTAssertEqual(model.text, visible(0..<45))
        XCTAssertLessThan(appendStamps.count, 20, "forty changes were folded into far fewer deliveries")
        XCTAssertLessThanOrEqual(appendStamps.count, 10, "about four a second over two seconds")
        for index in 4..<max(4, appendStamps.count) {
            XCTAssertGreaterThanOrEqual(appendStamps[index] - appendStamps[index - 4], 1.0 - 0.001,
                                        "five deliveries took less than a second: at \(appendStamps)")
        }
    }

    // MARK: - A file that outgrows its ceiling

    func testAFileGrowingPastTheCeilingDropsItsOldestLinesBackToTheWindow() throws {
        let rig = TaskOutputRig()
        let perMiB = mib / 64
        let model = open(rig, lines: perMiB)                        // 1 MiB held
        let log = TaskOutputChangeLog(model)

        func growByOneMiB() throws {
            rig.daemon.appendLines(perMiB)
            rig.clock.advance(0.5)
            try rig.firePoll()
        }
        for _ in 0..<19 { try growByOneMiB() }                      // 20 MiB held: at the ceiling, not past it
        XCTAssertEqual(model.text.utf8.count, 20 * mib)
        XCTAssertFalse(log.events.contains(.replaced), "nothing is dropped at the ceiling")
        XCTAssertNil(model.truncationNotice)

        try growByOneMiB()                                          // 21 MiB: past it
        rig.flushDeliveries()

        let total = 21 * perMiB
        let held = model.text.utf8.count
        XCTAssertLessThanOrEqual(held, 10 * mib, "back to the 10 MB window")
        XCTAssertGreaterThan(held, 10 * mib - 256, "and only the oldest lines were dropped")
        XCTAssertEqual(held % 64, 0, "whole lines")
        assertSameLargeText(model.text, visible((total - held / 64)..<total),
                            "what is left is the end of the output, contiguous, to the last line")
        XCTAssertTrue(model.truncatedHead)
        XCTAssertEqual(model.truncationNotice, "Showing the last 10 MB of 21 MB")
        XCTAssertTrue(log.contentEvents.last == .replaced, "a subscriber reads the text again: \(log.kinds.suffix(3))")

        rig.daemon.appendLines(1)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertTrue(model.text.hasSuffix(TaskOutputFakeDaemon.visibleLine(total)), "polling carries on after the trim")
    }

    // MARK: - States

    func testWhileTheFirstReadIsOutstandingTheStateIsLoading() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        XCTAssertEqual(model.state, .loading, "a model that has asked for nothing yet is loading")

        model.acquire()
        addTeardownBlock { model.release() }
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.stateName, "loading")
        XCTAssertEqual(model.text, "")

        rig.daemon.answerNext()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.stateName, "ready")
    }

    func testAMissingFileIsUnavailableAndIsTriedAgainAtTheNextPoll() throws {
        let rig = TaskOutputRig()
        rig.daemon.content = nil
        let model = rig.makeModel()
        let log = TaskOutputChangeLog(model)
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(model.stateName, "unavailable")
        XCTAssertTrue(log.events.contains(.status), "the window is told")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "the file may appear later")

        rig.daemon.setLines(5)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, visible(0..<5))
    }

    func testAnUnavailableLoadIsRetriedWhenTheModelIsAcquiredAgain() {
        let rig = TaskOutputRig()
        rig.daemon.content = nil
        let model = rig.makeModel()
        model.acquire()
        model.release()
        XCTAssertEqual(model.state, .unavailable)

        rig.daemon.setLines(5)
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, visible(0..<5))
    }

    func testADaemonErrorIsReportedAsAnErrorStateWithItsMessage() {
        let rig = TaskOutputRig()
        rig.daemon.failure = ("error", "the output file is not readable")
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .error("the output file is not readable"))
        XCTAssertEqual(model.stateName, "error")
        XCTAssertEqual(model.text, "")
    }

    func testARefusalWithNoMessageStillIsAnErrorWithSomethingToSay() {
        let rig = TaskOutputRig()
        rig.daemon.failure = ("refused", nil)
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        guard case .error(let message) = model.state else { return XCTFail("a refusal is an error, not \(model.state)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testAnErrorLoadIsRetriedWhenTheModelIsAcquiredAgain() {
        let rig = TaskOutputRig()
        rig.daemon.failure = ("error", "temporary trouble")
        let model = rig.makeModel()
        model.acquire()
        model.release()
        XCTAssertEqual(model.stateName, "error")

        rig.daemon.failure = nil
        rig.daemon.setLines(5)
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertEqual(model.state, .ready, "opening the window again after a failed load tries again")
        XCTAssertEqual(model.text, visible(0..<5))
    }

    func testNoAnswerInTimeIsAnErrorAndTheNextPollTriesAgain() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(5)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        rig.timeouts.fireAll()                    // the daemon never answered
        guard case .error = model.state else { return XCTFail("a silent daemon is an error, not \(model.state)") }
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "it will try again")

        rig.daemon.dropQueued()
        rig.daemon.defersAnswers = false
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, visible(0..<5))
    }

    func testLosingTheConnectionDuringTheFirstLoadIsAnErrorAndTheNextPollTriesAgain() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(5)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel()
        model.acquire()
        addTeardownBlock { model.release() }

        rig.requests.failPendingRequests(reason: "The connection to the daemon was lost")
        XCTAssertEqual(model.state, .error("The connection to the daemon was lost"))

        rig.daemon.dropQueued()
        rig.daemon.defersAnswers = false
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, visible(0..<5))
    }

    func testLosingTheConnectionDuringAPollKeepsTheTextAndTheNextPollCarriesOn() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 5)
        rig.daemon.defersAnswers = true
        rig.clock.advance(0.5)
        try rig.firePoll()

        rig.requests.failPendingRequests(reason: "gone")
        XCTAssertEqual(model.text, visible(0..<5))
        XCTAssertEqual(model.state, .ready, "held text is not turned into an error")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1)

        rig.daemon.dropQueued()
        rig.daemon.defersAnswers = false
        rig.daemon.appendLines(2)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.text, visible(0..<7), "reading resumed from where it had got to")
    }

    func testWithNoDaemonConnectionTheLoadFailsAtOnceAndTheNextOpenRetries() {
        let rig = TaskOutputRig()
        rig.requests.sender = nil
        let model = rig.makeModel()
        model.acquire()
        model.release()

        guard case .error(let message) = model.state else { return XCTFail("no connection is an error, not \(model.state)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(rig.daemon.reads.isEmpty)

        rig.requests.sender = rig.daemon
        rig.daemon.setLines(3)
        model.acquire()
        addTeardownBlock { model.release() }
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.text, visible(0..<3))
    }

    // MARK: - Memory

    func testAModelDroppedWithARequestInFlightAndATimerLiveIsFreed() {
        let rig = TaskOutputRig()
        rig.daemon.setLines(5)
        weak var probe: TaskOutputModel?
        autoreleasepool {
            rig.daemon.defersAnswers = true
            let model = rig.makeModel()
            probe = model
            model.acquire()                 // a read is out; never released: the owner just lets go
        }
        XCTAssertNil(probe, "neither the request nor a timer keeps a model alive")
        rig.daemon.answerNext()             // the answer for a model that is gone is harmless
    }
}

// MARK: - The registry

final class TaskOutputRegistryTests: XCTestCase {

    // MARK: Fixtures

    private struct World {
        let rig: TaskOutputRig
        let store: BackgroundTaskStore
        let storeClock: TaskOutputClock
        let registry: TaskOutputRegistry
    }

    private func makeWorld(cap: Int = 1_000_000) throws -> World {
        let suite = "TaskOutputRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let rig = TaskOutputRig()
        let storeClock = TaskOutputClock()
        let store = BackgroundTaskStore(now: { storeClock.date }, schedule: { _, _ in }, defaults: defaults)
        return World(rig: rig, store: store, storeClock: storeClock, registry: rig.makeRegistry(store: store, capBytes: cap))
    }

    private func shell(_ id: String, _ status: TaskStatusWire = .running) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: .shell, status: status, hasOutput: true)
    }

    private func snapshot(_ tag: String, _ tasks: [TaskMetaWire]) -> ServerMsg {
        .sessionTasks(SessionTasksWire(tag: tag, sessionId: "s1", daemonEpoch: "e1", tasks: tasks))
    }

    /// A file of exactly `bytes` bytes (one line).
    private func blob(_ bytes: Int) -> Data {
        Data(String(repeating: "a", count: bytes - 1).utf8) + Data([0x0A])
    }

    private func visible(_ range: Range<Int>) -> String {
        TaskOutputFakeDaemon.visibleText(range)
    }

    // MARK: - Sharing

    func testTheSameTaskGetsTheSameModelEverywhere() throws {
        let world = try makeWorld()
        let one = world.registry.model(tag: "kate", taskId: "b1")
        let two = world.registry.model(tag: "kate", taskId: "b1")

        XCTAssertTrue(one === two, "the window and `tasks output` read one model, so they cannot disagree")
        XCTAssertEqual(world.registry.modelCount, 1)
        XCTAssertTrue(world.registry.existingModel(tag: "kate", taskId: "b1") === one)
    }

    func testDifferentTasksAndDifferentFociGetDifferentModels() throws {
        let world = try makeWorld()
        let a = world.registry.model(tag: "kate", taskId: "b1")
        let b = world.registry.model(tag: "kate", taskId: "b2")
        let c = world.registry.model(tag: "cody", taskId: "b1")

        XCTAssertFalse(a === b)
        XCTAssertFalse(a === c, "the same task id under another focus is another task")
        XCTAssertEqual(world.registry.modelCount, 3)
        XCTAssertEqual(c.tag, "cody")
        XCTAssertEqual(b.taskId, "b2")
    }

    func testAskingForAModelReadsNothingUntilSomeoneHoldsIt() throws {
        let world = try makeWorld()
        world.rig.daemon.setLines(5)
        let model = world.registry.model(tag: "kate", taskId: "b1")

        XCTAssertTrue(world.rig.daemon.reads.isEmpty)
        XCTAssertNil(world.registry.existingModel(tag: "kate", taskId: "nobody"))

        model.acquire()
        addTeardownBlock { model.release() }
        XCTAssertEqual(world.rig.daemon.reads.count, 1)
    }

    // MARK: - The cap

    func testPastTheCapTheLeastRecentlyUsedUnheldModelGoesFirst() throws {
        let world = try makeWorld(cap: 2_500)
        world.rig.daemon.content = blob(1_000)
        let registry = world.registry

        let a = registry.model(tag: "kate", taskId: "a"); a.acquire(); a.release()
        let b = registry.model(tag: "kate", taskId: "b"); b.acquire(); b.release()
        _ = registry.model(tag: "kate", taskId: "a")          // a is used again: b is now the oldest
        let c = registry.model(tag: "kate", taskId: "c"); c.acquire()
        addTeardownBlock { c.release() }

        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "b"), "the least recently used went")
        XCTAssertNotNil(registry.existingModel(tag: "kate", taskId: "a"))
        XCTAssertNotNil(registry.existingModel(tag: "kate", taskId: "c"))
        XCTAssertLessThanOrEqual(registry.totalHeldBytes, 2_500)
        XCTAssertEqual(registry.modelCount, 2)
    }

    func testAHeldModelIsNeverEvictedWhateverItsAge() throws {
        let world = try makeWorld(cap: 2_500)
        world.rig.daemon.content = blob(1_000)
        let registry = world.registry

        let oldest = registry.model(tag: "kate", taskId: "a"); oldest.acquire()       // held, and the oldest
        let b = registry.model(tag: "kate", taskId: "b"); b.acquire(); b.release()
        let c = registry.model(tag: "kate", taskId: "c"); c.acquire()
        addTeardownBlock { oldest.release(); c.release() }

        XCTAssertNotNil(registry.existingModel(tag: "kate", taskId: "a"), "a window is showing it")
        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "b"), "the unheld one paid for it")
        XCTAssertNotNil(registry.existingModel(tag: "kate", taskId: "c"))
        XCTAssertEqual(oldest.text.utf8.count, 1_000, "and its text is intact")
    }

    func testWhenEveryModelIsHeldNothingIsEvictedEvenPastTheCap() throws {
        let world = try makeWorld(cap: 2_500)
        world.rig.daemon.content = blob(1_000)
        let registry = world.registry

        let held = ["a", "b", "c", "d"].map { id -> TaskOutputModel in
            let model = registry.model(tag: "kate", taskId: id)
            model.acquire()
            return model
        }
        addTeardownBlock { held.forEach { $0.release() } }

        XCTAssertEqual(registry.modelCount, 4)
        XCTAssertEqual(registry.totalHeldBytes, 4_000, "the cap yields to what is on screen")
        for model in held { XCTAssertEqual(model.text.utf8.count, 1_000) }
    }

    func testAnEvictedModelIsRebuiltFreshAndReadsAgainWhenAskedFor() throws {
        let world = try makeWorld(cap: 1_500)
        world.rig.daemon.content = blob(1_000)
        let registry = world.registry

        let first = registry.model(tag: "kate", taskId: "a"); first.acquire(); first.release()
        let second = registry.model(tag: "kate", taskId: "b"); second.acquire()
        addTeardownBlock { second.release() }
        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "a"))

        let readsBefore = world.rig.daemon.reads.count
        let again = registry.model(tag: "kate", taskId: "a")
        again.acquire()
        addTeardownBlock { again.release() }

        XCTAssertFalse(again === first)
        XCTAssertEqual(again.text.utf8.count, 1_000)
        XCTAssertEqual(world.rig.daemon.reads.count, readsBefore + 1)
    }

    // MARK: - Evicting on demand

    func testEvictUnheldDropsEveryModelNothingHoldsAndKeepsTheHeldOnes() throws {
        let world = try makeWorld()
        world.rig.daemon.content = blob(100)
        let registry = world.registry

        let held = registry.model(tag: "kate", taskId: "held"); held.acquire()
        addTeardownBlock { held.release() }
        let unheld = registry.model(tag: "kate", taskId: "unheld"); unheld.acquire(); unheld.release()
        _ = registry.model(tag: "cody", taskId: "never-held")

        registry.evictUnheld()

        XCTAssertEqual(registry.modelCount, 1)
        XCTAssertTrue(registry.existingModel(tag: "kate", taskId: "held") === held)
        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "unheld"))
        XCTAssertNil(registry.existingModel(tag: "cody", taskId: "never-held"))
    }

    func testForgettingAFocusDropsItsModelsAndLeavesTheOthers() throws {
        let world = try makeWorld()
        world.rig.daemon.content = blob(100)
        let registry = world.registry

        let held = registry.model(tag: "kate", taskId: "b1"); held.acquire()
        addTeardownBlock { held.release() }
        _ = registry.model(tag: "kate", taskId: "b2")
        let other = registry.model(tag: "cody", taskId: "b1")

        registry.forget(tag: "kate")

        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "b1"), "even one a window held: its window closes with the focus")
        XCTAssertNil(registry.existingModel(tag: "kate", taskId: "b2"))
        XCTAssertTrue(registry.existingModel(tag: "cody", taskId: "b1") === other)
        XCTAssertEqual(registry.modelCount, 1)
        XCTAssertFalse(registry.model(tag: "kate", taskId: "b1") === held, "asking again makes a new model")
    }

    // MARK: - Ended tasks

    func testAModelLearnsFromTheStoreThatItsTaskEndedAndReadsOnceMore() throws {
        let world = try makeWorld()
        world.rig.daemon.setLines(10)
        world.store.ingest(snapshot("kate", [shell("b1")]))
        let model = world.registry.model(tag: "kate", taskId: "b1")
        model.acquire()
        addTeardownBlock { model.release() }
        XCTAssertFalse(model.isTaskEnded)
        XCTAssertEqual(world.rig.scheduler.pollSlots.count, 1, "a running task is polled")

        world.rig.daemon.appendLines(3)                      // its last words
        world.rig.clock.advance(1)
        world.storeClock.advance(1)
        world.store.ingest(snapshot("kate", [shell("b1", .completed)]))

        XCTAssertTrue(model.isTaskEnded)
        XCTAssertEqual(model.text, visible(0..<13), "the final read picked up the end")
        XCTAssertTrue(world.rig.scheduler.live.isEmpty, "and polling stopped")
    }

    func testOnlyTheModelOfTheTaskThatEndedIsToldSo() throws {
        let world = try makeWorld()
        world.rig.daemon.setLines(5)
        world.store.ingest(snapshot("kate", [shell("b1"), shell("b2")]))
        let ended = world.registry.model(tag: "kate", taskId: "b1")
        let running = world.registry.model(tag: "kate", taskId: "b2")
        ended.acquire(); running.acquire()
        addTeardownBlock { ended.release(); running.release() }

        world.storeClock.advance(1)
        world.store.ingest(snapshot("kate", [shell("b1", .failed), shell("b2")]))

        XCTAssertTrue(ended.isTaskEnded)
        XCTAssertFalse(running.isTaskEnded)
        XCTAssertEqual(world.rig.scheduler.pollSlots.count, 1, "the running one keeps polling")
    }

    func testAModelMadeForATaskThatAlreadyEndedStartsEnded() throws {
        let world = try makeWorld()
        world.rig.daemon.setLines(5)
        world.store.ingest(snapshot("kate", [shell("b1", .completed)]))

        let model = world.registry.model(tag: "kate", taskId: "b1")
        model.acquire()
        addTeardownBlock { model.release() }

        XCTAssertTrue(model.isTaskEnded)
        XCTAssertEqual(model.text, visible(0..<5))
        XCTAssertTrue(world.rig.scheduler.live.isEmpty, "an ended task is read once and not polled")
    }

    func testATaskTheStoreDoesNotKnowIsTreatedAsRunning() throws {
        let world = try makeWorld()
        let model = world.registry.model(tag: "kate", taskId: "nobody-told-the-store")
        XCTAssertFalse(model.isTaskEnded)
    }

    // MARK: - Memory

    func testModelsAndViewsAreFreedAfterReleaseAndDropAndNoTimerOutlivesTheirHolders() throws {
        let world = try makeWorld()
        world.rig.daemon.setLines(30)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        addTeardownBlock { pasteboard.releaseGlobally() }

        struct Probe {
            weak var model: TaskOutputModel?
            weak var view: TaskOutputView?
        }
        var probes: [Probe] = []
        for index in 0..<50 {
            autoreleasepool {
                let taskId = "b\(index)"
                let model = world.registry.model(tag: "kate", taskId: taskId)
                let view = TaskOutputView(focusTag: "kate", taskId: taskId, model: model, pasteboard: pasteboard)
                model.acquire()
                XCTAssertEqual(view.shownText, visible(0..<30), "the view shows what was read")
                world.rig.daemon.appendLines(1)
                world.rig.clock.advance(0.5)
                if let slot = world.rig.scheduler.pollSlots.first { world.rig.scheduler.fire(slot) }
                probes.append(Probe(model: model, view: view))
                model.release()
                XCTAssertTrue(world.rig.scheduler.live.isEmpty, "no timer once the last holder is gone (round \(index))")
            }
            world.rig.daemon.setLines(30)
        }

        XCTAssertEqual(probes.compactMap { $0.view }.count, 0, "no view outlives its window")
        world.registry.evictUnheld()
        XCTAssertEqual(world.registry.modelCount, 0)
        XCTAssertEqual(probes.compactMap { $0.model }.count, 0, "no model outlives its eviction")
        XCTAssertTrue(world.rig.scheduler.live.isEmpty)
    }

    func testAModelThatWasEvictedIsFreedOnceNobodyHoldsItAnyMore() throws {
        let world = try makeWorld()
        world.rig.daemon.content = blob(100)
        weak var probe: TaskOutputModel?
        autoreleasepool {
            let model = world.registry.model(tag: "kate", taskId: "b1")
            probe = model
            model.acquire()
            model.release()
        }
        XCTAssertNotNil(probe, "the registry keeps an unheld model until it is evicted")

        world.registry.evictUnheld()

        XCTAssertNil(probe)
    }
}

// MARK: - Review fixes: multi-byte windows, one huge line, refresh, reopen, catching up

extension TaskOutputModelTests {

    // MARK: Fixtures

    /// Seven CJK characters (3 bytes each), an emoji (4), four box-drawing characters (3 each) and a newline.
    fileprivate static let multibyteLine = "\u{65E5}\u{672C}\u{8A9E}\u{30C6}\u{30AD}\u{30B9}\u{30C8}\u{1F600}\u{2502}\u{2500}\u{253C}\u{2524}\n"

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Bytes `range` of one endless line with no newline in it (what minified JSON or base64 looks like).
    fileprivate static func oneLine(_ range: Range<Int>) -> Data {
        Data(range.map { base64Alphabet[$0 % 64] })
    }

    private func continuationRun(in bytes: [UInt8], at index: Int) -> Int {
        var run = 0
        while run < 3, index + run < bytes.count, bytes[index + run] & 0xC0 == 0x80 { run += 1 }
        return run
    }

    /// A file of multi-byte lines and a short ASCII closing line, with the closing line's length picked so
    /// that `total - 10 MiB` (the start of the viewer's window) falls inside a character, `skip` continuation
    /// bytes before the next one starts. Nil when no closing line does it.
    private func multibyteFile(skip: Int, lines: Int = 300_000) -> (data: Data, windowStart: Int)? {
        let unit = Array(Self.multibyteLine.utf8)
        guard unit.count == 38 else { return nil }
        for closing in 0..<unit.count {
            let total = unit.count * lines + closing
            let windowStart = total - 10 * mib
            let inLine = windowStart % unit.count
            guard unit[inLine] & 0xC0 == 0x80, continuationRun(in: unit, at: inLine) == skip else { continue }
            var data = Data()
            data.reserveCapacity(total)
            for _ in 0..<lines { data.append(contentsOf: unit) }
            if closing > 0 { data.append(contentsOf: [UInt8](repeating: 0x78, count: closing - 1) + [0x0A]) }
            return (data, windowStart)
        }
        return nil
    }

    private func appendedText(_ log: TaskOutputChangeLog) -> String {
        log.events.compactMap { event -> String? in
            if case .appended(let text) = event { return text }
            return nil
        }.joined()
    }

    // MARK: - M1: a window that starts inside a character

    func testAWindowThatStartsInsideACharacterStillHoldsTheWholeTenMegabytesFromTheNextCharacter() throws {
        // The window start (total - 10 MiB) is an arbitrary byte. In the box-drawing, CJK and emoji lines
        // below it lands 1, 2 and 3 continuation bytes before a character begins.
        for skip in 1...3 {
            let (data, windowStart) = try XCTUnwrap(multibyteFile(skip: skip), "a fixture with a skip of \(skip)")
            XCTAssertEqual(data[windowStart] & 0xC0, 0x80, "premise (skip \(skip)): the window starts inside a character")
            XCTAssertNotEqual(data[windowStart + skip] & 0xC0, 0x80, "premise: the character after it starts \(skip) bytes on")
            XCTAssertGreaterThan(data.count, 10 * mib)

            let rig = TaskOutputRig()
            rig.daemon.content = data
            let model = rig.makeModel()
            model.acquire()
            rig.drainAnswers()

            let first = windowStart + skip
            XCTAssertEqual(model.state, .ready, "skip \(skip)")
            XCTAssertFalse(model.isFillingHead, "skip \(skip)")
            XCTAssertEqual(model.text.utf8.count, data.count - first, "skip \(skip): the whole window, from its first whole character")
            XCTAssertTrue(model.text.utf8.elementsEqual(data[first...]), "skip \(skip): the held text is the file from there to its end")
            XCTAssertFalse(model.text.unicodeScalars.contains("\u{FFFD}"), "skip \(skip): no split character")
            XCTAssertTrue(model.truncatedHead, "skip \(skip)")
            XCTAssertEqual(model.truncationNotice, "Showing the last 10 MB of 11 MB", "skip \(skip)")
            model.release()
        }
    }

    func testAHeadThatStartsFurtherFromTheRequestThanASplitCharacterCanExplainIsRefusedAndTheNoticeSaysWhatIsHeld() {
        // The daemon skips at most three continuation bytes; any other start is a head that does not line up.
        for shift in [4, 5] {
            let rig = TaskOutputRig()
            let lineCount = 12 * mib / 64
            rig.daemon.setLines(lineCount)
            rig.daemon.rangedStartShift = shift
            let model = rig.makeModel()
            model.acquire()
            rig.drainAnswers()

            XCTAssertEqual(model.state, .ready, "shift \(shift)")
            XCTAssertFalse(model.isFillingHead, "shift \(shift)")
            XCTAssertEqual(model.text.utf8.count, mib, "shift \(shift): only the tail is held")
            assertSameLargeText(model.text, visible((11 * mib / 64)..<lineCount), "shift \(shift): the tail, whole, to the last line")
            XCTAssertTrue(model.truncatedHead, "shift \(shift)")
            XCTAssertEqual(model.truncationNotice, "Showing the last 1 MB of 12 MB",
                           "shift \(shift): the notice reports what is held, not the 10 MB it could not fetch")
            model.release()
        }
    }

    // MARK: - S1: one huge line

    func testASingleHugeLineGrowingPastTheCeilingIsTrimmedToTheWindowNotToNothing() throws {
        let rig = TaskOutputRig()
        rig.daemon.content = Self.oneLine(0..<mib)
        let model = rig.makeModel()
        model.acquire()
        rig.drainAnswers()
        addTeardownBlock { model.release() }
        let log = TaskOutputChangeLog(model)

        func growByOneMiB() throws {
            let have = rig.daemon.content?.count ?? 0
            rig.daemon.content = (rig.daemon.content ?? Data()) + Self.oneLine(have..<(have + mib))
            rig.clock.advance(0.5)
            try rig.firePoll()
        }
        for _ in 0..<19 { try growByOneMiB() }                      // 20 MiB: at the ceiling
        XCTAssertEqual(model.text.utf8.count, 20 * mib)
        XCTAssertFalse(log.events.contains(.replaced), "nothing is dropped at the ceiling")

        try growByOneMiB()                                          // 21 MiB: past it, with no newline to cut at
        rig.flushDeliveries()

        let file = try XCTUnwrap(rig.daemon.content)
        let held = model.text.utf8.count
        XCTAssertGreaterThan(held, 0, "a line with no newline is not trimmed to nothing")
        XCTAssertLessThanOrEqual(held, 10 * mib, "back to the 10 MB window")
        XCTAssertGreaterThan(held, 10 * mib - 8, "and not far under it")
        XCTAssertTrue(model.text.utf8.elementsEqual(file.suffix(held)), "what is left is the end of the file, to its last byte")
        XCTAssertTrue(model.truncatedHead)
        XCTAssertEqual(model.truncationNotice, "Showing the last 10 MB of 21 MB")
        XCTAssertTrue(log.contentEvents.last == .replaced, "a subscriber reads the text again: \(log.kinds.suffix(3))")

        try growByOneMiB()
        let grown = try XCTUnwrap(rig.daemon.content)
        XCTAssertTrue(model.text.utf8.elementsEqual(grown.suffix(model.text.utf8.count)), "polling carries on after the trim")
        XCTAssertGreaterThan(model.text.utf8.count, 10 * mib)
    }

    func testLastBytesOfALongTextWithNoNewlineIsTheEndOfItNotNothing() {
        let text = String(decoding: Self.oneLine(0..<(3 * mib)), as: UTF8.self)

        let end = TaskOutputModel.lastBytes(of: text, mib)

        XCTAssertEqual(end.utf8.count, mib)
        XCTAssertTrue(text.hasSuffix(end))
    }

    func testLastBytesStartsAtAWholeCharacter() {
        let text = String(repeating: "\u{65E5}", count: 400_000)         // 1.2 MB of three-byte characters

        let end = TaskOutputModel.lastBytes(of: text, mib)

        XCTAssertLessThanOrEqual(end.utf8.count, mib)
        XCTAssertGreaterThan(end.utf8.count, mib - 3)
        XCTAssertEqual(end.utf8.count % 3, 0, "whole characters only")
        XCTAssertFalse(end.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertTrue(text.utf8.suffix(end.utf8.count).elementsEqual(end.utf8), "it is the end of the text")
    }

    func testLastBytesPrefersALineStartWhenThatKeepsMostOfTheLimit() {
        let lines = TaskOutputFakeDaemon.visibleText(0..<(2 * mib / 64))
        let limit = 1_000_010                                          // not a multiple of the 64-byte lines

        let end = TaskOutputModel.lastBytes(of: lines, limit)

        XCTAssertTrue(end.hasPrefix("L"), "cut at a line start")
        XCTAssertEqual(end.utf8.count % 64, 0)
        XCTAssertLessThanOrEqual(end.utf8.count, limit)
        XCTAssertGreaterThan(end.utf8.count, limit - 64)
        XCTAssertTrue(lines.hasSuffix(end))
        XCTAssertEqual(end.utf8.count, 1_000_000, "the 10 bytes of the line the limit fell inside are dropped")
    }

    func testLastBytesOfAHugeLineFollowedByAShortOneKeepsTheWindowNotJustTheShortLine() {
        let text = String(decoding: Self.oneLine(0..<(3 * mib)), as: UTF8.self) + "\nshort\n"

        let end = TaskOutputModel.lastBytes(of: text, mib)

        XCTAssertGreaterThan(end.utf8.count, mib / 2, "a short last line does not stand for the window")
        XCTAssertLessThanOrEqual(end.utf8.count, mib)
        XCTAssertTrue(end.hasSuffix("\nshort\n"))
    }

    func testLastBytesOfATextUnderTheLimitIsTheTextItself() {
        XCTAssertEqual(TaskOutputModel.lastBytes(of: "abc\ndef\n", 100), "abc\ndef\n")
    }

    // MARK: - S4: a file that came back

    private func vanish(_ rig: TaskOutputRig) throws {
        rig.daemon.content = nil
        for _ in 0..<3 {
            rig.clock.advance(0.5)
            try rig.firePoll()
        }
        XCTAssertTrue(rig.scheduler.live.isEmpty, "premise: a vanished file is not polled")
    }

    func testAFileThatCameBackForARunningTaskIsReadAgainWhenSomeoneOpensTheOutputAgain() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        try vanish(rig)
        rig.daemon.setLines(25)

        model.release()
        rig.clock.advance(5)
        model.acquire()

        XCTAssertEqual(model.text, visible(0..<25), "reading resumed from where it had got to")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "and polling is live again")

        rig.daemon.appendLines(2)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.text, visible(0..<27))
    }

    func testAFileThatIsStillGoneWhenTheOutputIsOpenedAgainGoesQuietAfterThreeMoreFailedPolls() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        try vanish(rig)

        model.release()
        model.acquire()

        XCTAssertEqual(model.text, visible(0..<20), "the held text stays")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "a running task's file is tried again")
        for _ in 0..<2 {
            rig.clock.advance(0.5)
            try rig.firePoll()
        }
        XCTAssertTrue(rig.scheduler.live.isEmpty, "a few failures in a row make it vanished again: no endless polling")
        XCTAssertEqual(model.text, visible(0..<20))
    }

    func testAnEndedTaskWhoseFileVanishedIsNotReadAgainWhenTheOutputIsOpenedAgain() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 20)
        try vanish(rig)
        model.taskEnded()
        rig.daemon.setLines(25)
        model.release()
        let readsBefore = rig.daemon.reads.count

        model.acquire()

        XCTAssertEqual(rig.daemon.reads.count, readsBefore, "an ended task is not retried")
        XCTAssertEqual(model.text, visible(0..<20))
        XCTAssertTrue(rig.scheduler.live.isEmpty)
    }

    // MARK: - S5: an answer that lands after the last holder left

    func testAnAnswerThatLandsWithNoHolderLeavesNoTimerAndTheReopenedViewShowsTheTextOnce() throws {
        let rig = TaskOutputRig()
        let model = open(rig, lines: 10)
        rig.daemon.defersAnswers = true
        rig.daemon.appendLines(2)
        try rig.firePoll()                      // a read is out, inside the quarter second of the load's delivery
        model.release()                         // the window closes while it is out

        rig.daemon.answerNext()                 // it lands with nobody holding the model

        XCTAssertEqual(model.text, visible(0..<12), "the model took the text")
        XCTAssertFalse(model.hasLiveTimer, "and started no timer for nobody")
        XCTAssertTrue(rig.scheduler.live.isEmpty)

        // The window opens again: the view reads `text` as it stands, then listens, then the model is acquired.
        let pasteboard = rigPrivatePasteboard(self)
        let view = TaskOutputView(focusTag: "kate", taskId: "t1", model: model, pasteboard: pasteboard)
        let log = TaskOutputChangeLog(model)
        rig.daemon.defersAnswers = false
        model.acquire()
        addTeardownBlock { model.release() }
        rig.flushDeliveries()

        XCTAssertEqual(view.shownText, model.text, "no line is drawn twice")
        XCTAssertEqual(view.shownText, visible(0..<12))
        XCTAssertEqual(log.contentEvents, [], "nothing is delivered that the view already has")
        XCTAssertTrue(rig.scheduler.deliverySlots.isEmpty, "no stale delivery is waiting")
    }

    // MARK: - S6: a file far ahead of the cursor

    func testAFileFourMegabytesAheadIsCaughtUpByOnePollWithoutWaitingForMore() throws {
        let rig = TaskOutputRig()
        let perMiB = mib / 64
        let model = open(rig, lines: perMiB)
        let log = TaskOutputChangeLog(model)
        rig.daemon.appendLines(4 * perMiB)       // the file is 4 MiB past what was read
        rig.clock.advance(0.5)
        let readsBefore = rig.daemon.reads.count

        try rig.firePoll()                       // the one poll
        rig.flushDeliveries()

        assertSameLargeText(model.text, visible(0..<(5 * perMiB)), "all of the file, in order")
        XCTAssertEqual(model.totalBytes, UInt64(5 * mib))
        XCTAssertGreaterThan(rig.daemon.reads.count - readsBefore, 1, "chained reads, not one chunk per poll")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1, "the next poll is the only timer waiting")
        assertSameLargeText(appendedText(log), visible(perMiB..<(5 * perMiB)), "a subscriber got every byte once, appended")
    }

    func testAFileMoreThanTheWindowAheadReloadsTheTailInsteadOfAppendingChunkByChunk() throws {
        let rig = TaskOutputRig()
        let perMiB = mib / 64
        let model = open(rig, lines: perMiB)
        let log = TaskOutputChangeLog(model)
        rig.daemon.appendLines(13 * perMiB)      // 14 MiB in all: 13 MiB past the cursor, more than the window
        rig.clock.advance(0.5)

        try rig.firePoll()
        rig.flushDeliveries()

        assertSameLargeText(model.text, visible((4 * perMiB)..<(14 * perMiB)), "the last 10 MB of the file")
        XCTAssertEqual(model.truncationNotice, "Showing the last 10 MB of 14 MB")
        XCTAssertTrue(model.truncatedHead)
        XCTAssertTrue(log.contentEvents.contains(.replaced), "the tail was loaded again: \(log.kinds)")
        XCTAssertEqual(appendedText(log), "", "no 1 MiB chunk of the old stretch was appended and then thrown away")
        XCTAssertEqual(rig.scheduler.pollSlots.count, 1)
    }

    // MARK: - Nit: a CLI tail that turns into a file

    func testACliTailModelUpgradesToTheFileWhenTheDaemonStartsAnsweringFromIt() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        let model = open(rig, lines: 625)       // 40 000 bytes; the CLI keeps 8 KiB
        XCTAssertEqual(model.source, .cliTail)
        XCTAssertTrue(model.truncatedHead)
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [1])
        let log = TaskOutputChangeLog(model)

        rig.daemon.source = .file               // the output file appeared
        rig.clock.advance(1)
        try rig.firePoll()
        rig.flushDeliveries()

        XCTAssertEqual(model.source, .file, "it reads the file from now on")
        XCTAssertEqual(model.text, visible(0..<625), "the whole file, not an 8 KB tail")
        XCTAssertNil(model.truncationNotice)
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(log.contentEvents.contains(.replaced), "a subscriber reads the text again")
        XCTAssertEqual(rig.scheduler.pollSlots.map { $0.delay }, [0.5], "and polls it as a file")

        rig.daemon.appendLines(2)
        rig.clock.advance(0.5)
        try rig.firePoll()
        XCTAssertEqual(model.text, visible(0..<627))
        XCTAssertEqual(log.contentEvents.last, .appended(visible(625..<627)), "new lines are appended, as for any file")
    }
}
