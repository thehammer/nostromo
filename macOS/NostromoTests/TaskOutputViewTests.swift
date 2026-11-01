import XCTest
import AppKit
import NostromoKit

// BA4: the task window's output pane, driven through a real `TaskOutputModel` that talks to a fake daemon.
//
//   * The daemon is `FakeTaskDaemon`, a `TaskRequestSending` that answers by `ingest`ing a
//     `SessionTaskOutputResultWire` it decoded from JSON, exactly as `AppStore` hands answers to
//     `TaskRequests.shared`. It answers at once, or holds answers until a test releases them (to catch
//     the model between the tail and the head).
//   * Time is the model's injected clock plus a manual scheduler that records its timers and runs them on
//     demand. No wall clock decides anything (`rigSettle` only lets AppKit deliver its queued notifications).
//   * The pane is in a 600 x 400 window, so it has a clip view with a real height.
//   * The pasteboard is a private one. The general pasteboard is never touched.
//
// A user's scroll is a move of the clip view's origin (`clip.scroll(to:)`), the same bounds change a wheel
// or a scroller drag makes.

// MARK: - Seams

private final class RigClock {
    private(set) var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private final class ManualPollTimer: TaskPollTimer {
    let delay: TimeInterval
    private var work: (() -> Void)?
    private(set) var isLive = true

    init(delay: TimeInterval, work: @escaping () -> Void) {
        self.delay = delay
        self.work = work
    }

    func invalidate() {
        isLive = false
        work = nil
    }

    func fire() {
        guard isLive, let work else { return }
        isLive = false
        self.work = nil
        work()
    }
}

private final class ManualPollScheduler {
    private(set) var timers: [ManualPollTimer] = []
    var live: [ManualPollTimer] { timers.filter(\.isLive) }

    lazy var schedule: TaskPollScheduler = { [unowned self] delay, work in
        let timer = ManualPollTimer(delay: delay, work: work)
        self.timers.append(timer)
        return timer
    }

    /// Run every timer that is live now (timers they create wait for the next call).
    func fireLive() {
        for timer in live { timer.fire() }
    }
}

/// What the daemon would answer for one task's output.
private final class FakeTaskDaemon: TaskRequestSending {
    enum Mode {
        case file
        case cliTail
        case unavailable
        case error(String)
    }

    struct Read {
        let requestId: String
        let tag: String
        let taskId: String
        let offset: UInt64?
        let maxBytes: UInt32
    }

    var bytes: [UInt8] = []
    var mode: Mode = .file
    /// The most one answer carries (the real daemon clamps to 1 MiB; a small cap lets a test cut the output
    /// into a tail and a head without megabytes of text).
    var readCap = 1_048_576
    /// What a tail read reports as the file's size (a 12 MB file without 12 MB of text). Head reads of such a
    /// file are never answered by the tests that use it.
    var virtualTotal: UInt64?
    var autoAnswer = true
    weak var requests: TaskRequests?
    private(set) var held: [Read] = []
    private(set) var reads: [Read] = []

    func append(_ text: String) { bytes += Array(text.utf8) }

    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        let read = Read(requestId: requestId, tag: tag, taskId: taskId, offset: offset, maxBytes: maxBytes)
        reads.append(read)
        if autoAnswer { answer(read) } else { held.append(read) }
    }

    func sendTaskStop(requestId: String, tag: String, taskId: String) {}

    func answerNext() {
        guard !held.isEmpty else { return }
        answer(held.removeFirst())
    }

    func answerAll() {
        while !held.isEmpty { answerNext() }
    }

    private func answer(_ read: Read) {
        var object: [String: Any] = ["request_id": read.requestId, "tag": read.tag, "task_id": read.taskId]
        switch mode {
        case .unavailable:
            object["outcome"] = "unavailable"
        case .error(let message):
            object["outcome"] = "error"
            object["message"] = message
        case .cliTail:
            let length = min(8_192, bytes.count)
            fill(&object, range: (bytes.count - length) ..< bytes.count, start: UInt64(bytes.count - length),
                 end: UInt64(bytes.count), total: UInt64(bytes.count), source: "cli_tail")
        case .file:
            if let offset = read.offset {
                let low = min(Int(offset), bytes.count)
                let high = min(bytes.count, low + min(Int(read.maxBytes), readCap))
                fill(&object, range: low ..< high, start: UInt64(low), end: UInt64(high),
                     total: UInt64(bytes.count), source: "file")
            } else {
                let length = min(Int(read.maxBytes), readCap, bytes.count)
                let total = virtualTotal ?? UInt64(bytes.count)
                fill(&object, range: (bytes.count - length) ..< bytes.count, start: total - UInt64(length),
                     end: total, total: total, source: "file")
            }
        }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object)
        // swiftlint:disable:next force_try
        let wire = try! JSONDecoder().decode(SessionTaskOutputResultWire.self, from: data)
        requests?.ingest(.sessionTaskOutputResult(wire))
    }

    private func fill(_ object: inout [String: Any], range: Range<Int>, start: UInt64, end: UInt64,
                      total: UInt64, source: String) {
        object["outcome"] = "ok"
        object["text"] = String(decoding: bytes[range], as: UTF8.self)
        object["start_offset"] = start
        object["end_offset"] = end
        object["total_bytes"] = total
        object["source"] = source
    }
}

// MARK: - The rig

/// A model on the fake daemon and a `TaskOutputView` over it, in a 600 x 400 window.
private final class OutputRig {
    let daemon: FakeTaskDaemon
    let scheduler: ManualPollScheduler
    let clock: RigClock
    let requests: TaskRequests
    let model: TaskOutputModel
    let window: RigWindow
    let pasteboard: NSPasteboard
    private(set) var view: TaskOutputView!

    /// `viewBeforeLoad`: the view is made before the model has asked for anything, so it receives the load
    /// (the tail, then the head) as changes. Otherwise the model is loaded first and the view starts from its text.
    init(_ testCase: XCTestCase, initial: String, mode: FakeTaskDaemon.Mode, readCap: Int, autoAnswer: Bool,
         virtualTotal: UInt64?, viewBeforeLoad: Bool, withView: Bool, size: NSSize) {
        let daemon = FakeTaskDaemon()
        daemon.bytes = Array(initial.utf8)
        daemon.mode = mode
        daemon.readCap = readCap
        daemon.autoAnswer = autoAnswer
        daemon.virtualTotal = virtualTotal
        let scheduler = ManualPollScheduler()
        let clock = RigClock()
        var counter = 0
        let requests = TaskRequests(makeRequestId: { counter += 1; return "r\(counter)" }, schedule: { _, _ in })
        requests.sender = daemon
        daemon.requests = requests
        let model = TaskOutputModel(tag: "kate", taskId: "t1", requests: requests,
                                    schedule: scheduler.schedule, now: { clock.date })
        self.daemon = daemon
        self.scheduler = scheduler
        self.clock = clock
        self.requests = requests
        self.model = model
        self.window = makeRigWindow(testCase, size: size, appearance: NSAppearance(named: .darkAqua))
        self.pasteboard = rigPrivatePasteboard(testCase)

        if viewBeforeLoad {
            makeView()
            model.acquire()
        } else {
            model.acquire()
            if withView { makeView() }
        }
        testCase.addTeardownBlock { model.release() }
    }

    func makeView() {
        let view = TaskOutputView(focusTag: "kate", taskId: "t1", model: model, pasteboard: pasteboard)
        window.contentView = view
        self.view = view
        layout()
    }

    /// One poll later: the clock moves on (>= 250 ms, so deliveries are not folded) and the live timers run.
    func poll(_ seconds: TimeInterval = 0.5) {
        clock.advance(seconds)
        scheduler.fireLive()
    }

    func appendLines(_ range: Range<Int>) {
        daemon.append(TaskOutputViewTests.lines(range))
        poll()
    }

    /// Lay everything out (the whole text, so the document height is exact) and let AppKit deliver the
    /// notifications it queued.
    func layout() {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        if let container = view.textView.textContainer {
            view.textView.layoutManager?.ensureLayout(for: container)
        }
        rigSettle(0.05)
        view.layoutSubtreeIfNeeded()
    }

    /// What a wheel or a scroller drag does: move the clip view's origin.
    func userScroll(toY y: CGFloat) {
        let clip = view.clipView
        clip.scroll(to: NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(clip)
        rigSettle(0.05)
    }

    func resize(to size: NSSize) {
        window.setContentSize(size)
        layout()
    }
}

// MARK: - Tests

final class TaskOutputViewTests: XCTestCase {

    /// The pane keeps the end of the text in view with the text container's bottom inset (8 pt) and a little
    /// rounding below it.
    private static let bottomTolerance: CGFloat = 12

    /// 40 bytes a line: `line 00007 ----------------------------` and a newline. Every line is unique.
    static func lines(_ range: Range<Int>) -> String {
        range.map { String(format: "line %05ld ", $0) + String(repeating: "-", count: 28) + "\n" }.joined()
    }

    private static func line(_ number: Int) -> String { lines(number ..< number + 1) }

    private func makeRig(initial: String = "", mode: FakeTaskDaemon.Mode = .file, readCap: Int = 1_048_576,
                         autoAnswer: Bool = true, virtualTotal: UInt64? = nil, viewBeforeLoad: Bool = false,
                         withView: Bool = true, size: NSSize = NSSize(width: 600, height: 400)) -> OutputRig {
        OutputRig(self, initial: initial, mode: mode, readCap: readCap, autoAnswer: autoAnswer,
                  virtualTotal: virtualTotal, viewBeforeLoad: viewBeforeLoad, withView: withView, size: size)
    }

    private func content(kind: TaskKindWire = .shell, status: TaskStatusWire = .running,
                         description: String = "npm run build") -> TaskWindowContent {
        let meta = TaskMetaWire(id: "t1", kind: kind, description: description, status: status, startedAtMs: 1_000)
        return TaskWindowContent.make(tag: "kate", focusName: "kate", meta: meta, row: nil, detail: nil, nowMs: 31_000)
    }

    /// The line at the top of the visible area, as a user reads it.
    private func firstVisibleLine(_ view: TaskOutputView) -> String {
        let textView = view.textView
        let point = NSPoint(x: textView.textContainerInset.width + 2, y: view.clipView.bounds.minY + 1)
        let string = textView.string as NSString
        guard string.length > 0 else { return "" }
        let index = min(textView.characterIndexForInsertion(at: point), string.length - 1)
        return string.substring(with: string.lineRange(for: NSRange(location: index, length: 0)))
    }

    /// The pane is only a test of scrolling if the text is much taller than the viewport.
    private func assertTall(_ rig: OutputRig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(rig.view.textView.frame.height, rig.view.clipView.bounds.height * 3,
                             "the fixture must be several screens tall", file: file, line: line)
    }

    // MARK: Following

    func testNewOutputAppearsWithinOnePollAndTheViewStaysAtTheBottomWhileFollowing() {
        let rig = makeRig(initial: Self.lines(0 ..< 300))
        XCTAssertLessThanOrEqual(rig.scheduler.live.map(\.delay).min() ?? .infinity, 0.5,
                                 "the next read is due within 500 ms")
        XCTAssertFalse(rig.view.shownText.contains("line 00300"))

        rig.appendLines(300 ..< 350)
        rig.layout()

        assertTall(rig)
        XCTAssertTrue(rig.view.shownText.hasSuffix(Self.line(349)), "the new lines are on screen after one poll")
        XCTAssertEqual(rig.view.shownText, rig.model.text)
        XCTAssertTrue(rig.view.isFollowing)
        XCTAssertFalse(rig.view.showsJumpToLatest)
        let atTheBottom = rig.view.distanceFromBottom
        XCTAssertLessThanOrEqual(atTheBottom, Self.bottomTolerance, "the view is at the bottom")

        rig.appendLines(350 ..< 400)
        rig.layout()

        XCTAssertEqual(rig.view.distanceFromBottom, atTheBottom, accuracy: 1, "and it stays there")
        XCTAssertTrue(rig.view.isFollowing)
    }

    func testScrolledUpAppendsDoNotMoveTheVisibleTextAndJumpToLatestAppears() {
        let rig = makeRig(initial: Self.lines(0 ..< 400))
        rig.appendLines(400 ..< 420)
        rig.layout()
        assertTall(rig)
        XCTAssertTrue(rig.view.isFollowing, "premise: following the tail")

        rig.userScroll(toY: 1_000)

        XCTAssertFalse(rig.view.isFollowing, "scrolling up stops following")
        XCTAssertTrue(rig.view.showsJumpToLatest)
        let origin = rig.view.clipView.bounds.origin
        let visibleLine = firstVisibleLine(rig.view)
        let appends = rig.view.appendOps

        rig.appendLines(420 ..< 470)
        rig.layout()

        XCTAssertEqual(rig.view.appendOps, appends + 1, "the new lines did arrive")
        XCTAssertTrue(rig.view.shownText.hasSuffix(Self.line(469)))
        XCTAssertEqual(rig.view.clipView.bounds.origin.y, origin.y, accuracy: 0.5, "the viewport did not move")
        XCTAssertEqual(firstVisibleLine(rig.view), visibleLine, "the first visible line is the same line")
        XCTAssertFalse(rig.view.isFollowing)
        XCTAssertTrue(rig.view.showsJumpToLatest)
    }

    func testJumpToLatestReturnsToTheTailResumesFollowingAndHidesTheControl() {
        let rig = makeRig(initial: Self.lines(0 ..< 400))
        rig.appendLines(400 ..< 420)
        rig.layout()
        rig.userScroll(toY: 1_000)
        XCTAssertTrue(rig.view.showsJumpToLatest, "premise: scrolled away from the tail")

        rig.view.jumpToLatest()
        rig.layout()

        XCTAssertTrue(rig.view.isFollowing)
        XCTAssertFalse(rig.view.showsJumpToLatest)
        XCTAssertLessThanOrEqual(rig.view.distanceFromBottom, Self.bottomTolerance)

        rig.appendLines(420 ..< 470)
        rig.layout()

        XCTAssertLessThanOrEqual(rig.view.distanceFromBottom, Self.bottomTolerance, "following resumed: the next output keeps it at the bottom")
    }

    func testPressingTheJumpToLatestControlReturnsToTheTailAndResumesFollowing() {
        let rig = makeRig(initial: Self.lines(0 ..< 400))
        rig.appendLines(400 ..< 420)
        rig.layout()
        rig.userScroll(toY: 1_000)
        XCTAssertTrue(rig.view.showsJumpToLatest, "premise: scrolled away from the tail")
        XCTAssertFalse(rig.view.jumpToLatestControl.isHidden)

        rig.view.jumpToLatestControl.performClick(nil)
        rig.layout()

        XCTAssertTrue(rig.view.isFollowing)
        XCTAssertFalse(rig.view.showsJumpToLatest)
        XCTAssertTrue(rig.view.jumpToLatestControl.isHidden)
        XCTAssertLessThanOrEqual(rig.view.distanceFromBottom, Self.bottomTolerance)
    }

    func testAResizeWhileFollowingNeverStopsFollowing() {
        let rig = makeRig(initial: Self.lines(0 ..< 400))
        rig.appendLines(400 ..< 420)
        rig.layout()
        XCTAssertTrue(rig.view.isFollowing, "premise: following the tail")

        for size in [NSSize(width: 460, height: 300), NSSize(width: 800, height: 600), NSSize(width: 520, height: 260)] {
            rig.resize(to: size)

            XCTAssertTrue(rig.view.isFollowing, "still following after a resize to \(size)")
            XCTAssertFalse(rig.view.showsJumpToLatest, "no Jump to latest after a resize to \(size)")
        }
    }

    // MARK: The head arrives after the tail

    /// 600 lines (24000 bytes) in a daemon that answers at most 8192 bytes: the tail is the last 8192 and the
    /// head is two chunks. The view is made first, so it sees the tail and then the head.
    private func makeHeadRig() -> OutputRig {
        let rig = makeRig(initial: Self.lines(0 ..< 600), readCap: 8_192, autoAnswer: false, viewBeforeLoad: true)
        rig.daemon.answerNext()    // the tail
        rig.layout()
        XCTAssertTrue(rig.model.isFillingHead, "premise: the head is still being read")
        XCTAssertFalse(rig.view.shownText.hasPrefix(Self.line(0)), "premise: the head is not in yet")
        return rig
    }

    func testThePrependedHeadKeepsTheBottomAnchorWhileFollowing() {
        let rig = makeHeadRig()
        XCTAssertTrue(rig.view.isFollowing)
        XCTAssertLessThanOrEqual(rig.view.distanceFromBottom, Self.bottomTolerance, "premise: at the bottom of the tail")

        rig.clock.advance(0.5)
        rig.daemon.answerAll()
        rig.layout()

        XCTAssertEqual(rig.view.prependOps, 1)
        XCTAssertEqual(rig.view.shownText, Self.lines(0 ..< 600), "the whole output, from its first line")
        XCTAssertTrue(rig.view.isFollowing)
        XCTAssertFalse(rig.view.showsJumpToLatest)
        XCTAssertLessThanOrEqual(rig.view.distanceFromBottom, Self.bottomTolerance, "the head went in above; the bottom stayed")
    }

    func testThePrependedHeadKeepsTheDistanceFromTheBottomWhileScrolledUp() {
        let rig = makeHeadRig()
        rig.userScroll(toY: 800)
        XCTAssertFalse(rig.view.isFollowing, "premise: scrolled up")
        let visibleLine = firstVisibleLine(rig.view)
        let distance = rig.view.distanceFromBottom

        rig.clock.advance(0.5)
        rig.daemon.answerAll()
        rig.layout()

        XCTAssertEqual(rig.view.prependOps, 1)
        XCTAssertEqual(rig.view.shownText, Self.lines(0 ..< 600))
        XCTAssertEqual(rig.view.distanceFromBottom, distance, accuracy: 1, "the same distance from the bottom")
        XCTAssertEqual(firstVisibleLine(rig.view), visibleLine, "the same line is at the top of the viewport")
        XCTAssertFalse(rig.view.isFollowing)
        XCTAssertTrue(rig.view.showsJumpToLatest)
    }

    func testCopyAllCopiesEverythingTheModelHoldsIncludingTheHead() {
        let rig = makeHeadRig()
        rig.clock.advance(0.5)
        rig.daemon.answerAll()
        rig.layout()

        rig.view.copyAll()

        XCTAssertEqual(rig.pasteboard.string(forType: .string), Self.lines(0 ..< 600))
    }

    // MARK: Operation counts

    func testAHundredBatchesOfFiftyLinesCostAHundredAppendsAndNoReplacement() {
        let rig = makeRig(initial: Self.lines(0 ..< 50))
        XCTAssertEqual([rig.view.appendOps, rig.view.replaceOps, rig.view.prependOps], [0, 0, 0], "premise: a quiet start")

        for batch in 0 ..< 100 {
            rig.appendLines((50 + batch * 50) ..< (100 + batch * 50))
        }
        rig.layout()

        XCTAssertEqual(rig.view.appendOps, 100)
        XCTAssertEqual(rig.view.replaceOps, 0, "no full-text replacement")
        XCTAssertEqual(rig.view.prependOps, 0)
        XCTAssertEqual(rig.view.shownText, rig.model.text)
        XCTAssertTrue(rig.view.shownText.hasSuffix(Self.line(5_049)))
    }

    func testACliTailThatChangedIsReplacedInPlaceOnceAndAnUnchangedPollIsNot() {
        let rig = makeRig(initial: Self.lines(0 ..< 100), mode: .cliTail)
        XCTAssertEqual(rig.view.replaceOps, 0, "premise: loaded before the view")

        rig.daemon.bytes = Array(Self.lines(1 ..< 101).utf8)    // the CLI's tail moved on
        rig.poll(1)

        XCTAssertEqual(rig.view.replaceOps, 1, "the changed tail is one replacement")
        XCTAssertEqual(rig.view.appendOps, 0)
        XCTAssertEqual(rig.view.shownText, Self.lines(1 ..< 101))
        XCTAssertEqual(rig.view.shownText, rig.model.text)

        rig.poll(1)    // nothing changed

        XCTAssertEqual(rig.view.replaceOps, 1, "an unchanged tail is not drawn again")
        XCTAssertEqual(rig.view.appendOps, 0)
    }

    // MARK: The truncation line

    func testTheNoticeNamesTheLast10MBOfA12MBFile() {
        let rig = makeRig(initial: Self.lines(0 ..< 100), autoAnswer: false, virtualTotal: 12 * 1_048_576, viewBeforeLoad: true)
        rig.daemon.answerNext()    // the tail; the head of a 12 MB file is still to come
        rig.layout()

        XCTAssertEqual(rig.view.noticeText, "Showing the last 10 MB of 12 MB")
    }

    func testTheNoticeNamesTheLast8KBOfACliTail() {
        let rig = makeRig(initial: Self.lines(0 ..< 1_024), mode: .cliTail)    // 40 KB, the CLI keeps 8 KB

        XCTAssertEqual(rig.view.noticeText, "Showing the last 8 KB of 40 KB")
    }

    func testThereIsNoNoticeWhenNothingIsCut() {
        let wholeFile = makeRig(initial: Self.lines(0 ..< 100))
        XCTAssertNil(wholeFile.view.noticeText, "a file held from its first byte")

        let shortTail = makeRig(initial: Self.lines(0 ..< 100), mode: .cliTail)    // 4000 bytes: the whole of it
        XCTAssertNil(shortTail.view.noticeText, "a CLI tail that is the whole output")

        let twoMegabytes = makeRig(initial: Self.lines(0 ..< 100), autoAnswer: false, virtualTotal: 2 * 1_048_576,
                                   viewBeforeLoad: true)
        twoMegabytes.daemon.answerNext()    // the tail of a 2 MB file; its head is still to come
        twoMegabytes.layout()
        XCTAssertNil(twoMegabytes.view.noticeText, "a 2 MB file is shown whole, so nothing is cut")
    }

    // MARK: Never an empty pane

    func testEveryStateWithoutTextSaysSomethingDifferent() {
        let loading = makeRig(initial: Self.lines(0 ..< 3), autoAnswer: false, viewBeforeLoad: true)
        let unavailable = makeRig(mode: .unavailable)
        let failed = makeRig(mode: .error("the daemon is busy"))
        let empty = makeRig(initial: "")

        let texts = [("loading", loading), ("unavailable", unavailable), ("error", failed), ("empty", empty)]
            .map { name, rig -> (String, String?) in (name, rig.view.placeholderText) }
        for (name, text) in texts {
            XCTAssertFalse((text ?? "").isEmpty, "\(name): the pane says something")
        }
        for (name, rig) in [("loading", loading), ("unavailable", unavailable), ("error", failed), ("empty", empty)] {
            XCTAssertEqual(rig.view.shownText, "", "\(name): premise, there is no text")
        }
        XCTAssertEqual(Set(texts.compactMap(\.1)).count, 4, "each state has its own words: \(texts)")
        XCTAssertEqual(loading.model.stateName, "loading")
        XCTAssertEqual(unavailable.model.stateName, "unavailable")
        XCTAssertEqual(failed.model.stateName, "error")
        XCTAssertEqual(empty.model.stateName, "ready")
    }

    func testTheErrorPlaceholderCarriesWhatTheDaemonSaid() {
        let rig = makeRig(mode: .error("disk on fire"), viewBeforeLoad: true)

        XCTAssertTrue(rig.view.placeholderText?.contains("disk on fire") ?? false, "\(String(describing: rig.view.placeholderText))")
    }

    func testThePlaceholderGoesAwayWhenOutputArrives() {
        let rig = makeRig(initial: "", viewBeforeLoad: true)
        XCTAssertNotNil(rig.view.placeholderText, "premise: an empty ready output says so")

        rig.appendLines(0 ..< 3)

        XCTAssertNil(rig.view.placeholderText)
        XCTAssertEqual(rig.view.shownText, Self.lines(0 ..< 3))
    }

    func testThePlaceholderGoesAwayWhenTheFirstReadAnswers() {
        let rig = makeRig(initial: Self.lines(0 ..< 3), autoAnswer: false, viewBeforeLoad: true)
        XCTAssertNotNil(rig.view.placeholderText, "premise: loading")

        rig.daemon.answerNext()

        XCTAssertNil(rig.view.placeholderText)
        XCTAssertEqual(rig.view.shownText, Self.lines(0 ..< 3))
    }

    // MARK: Copy

    func testCopyAllCopiesTheModelsWholeText() {
        let rig = makeRig(initial: Self.lines(0 ..< 200))
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("old", forType: .string)

        rig.view.copyAll()

        XCTAssertEqual(rig.pasteboard.string(forType: .string), rig.model.text)
        XCTAssertEqual(rig.pasteboard.string(forType: .string), Self.lines(0 ..< 200))
    }

    func testTheCopyAllButtonCopiesTheModelsWholeText() {
        let rig = makeRig(initial: Self.lines(0 ..< 200))
        rig.pasteboard.clearContents()

        rig.view.copyAllControl.performClick(nil)

        XCTAssertEqual(rig.pasteboard.string(forType: .string), rig.model.text)
        XCTAssertEqual(rig.view.copyAllControl.title, "Copy All")
    }

    func testCopyAllIsTheFirstItemOfTheTextViewsContextMenuAndCopiesTheWholeText() throws {
        let rig = makeRig(initial: Self.lines(0 ..< 200))
        rig.pasteboard.clearContents()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
                                                     timestamp: 0, windowNumber: rig.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))

        let menu = try XCTUnwrap(rig.view.textView.menu(for: event))

        XCTAssertEqual(menu.items.first?.title, "Copy All")
        XCTAssertTrue(menu.items.count > 1 && menu.items[1].isSeparatorItem, "a separator sets it apart from the text view's own items")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(rig.pasteboard.string(forType: .string), rig.model.text)
    }

    func testSelectAllSelectsEverythingAndCopyIsAvailableWhileCopyAllStillTakesTheWholeText() {
        let rig = makeRig(initial: Self.lines(0 ..< 200))
        let textView = rig.view.textView
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable, "read-only: the output is never edited")

        textView.selectAll(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: (textView.string as NSString).length))
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(textView.validateMenuItem(copyItem), "Cmd-C is available with a selection")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        rig.view.copyAll()
        XCTAssertEqual(rig.pasteboard.string(forType: .string), rig.model.text, "Copy All does not depend on the selection")
    }

    // MARK: Header and the kinds without output

    func testTheHeaderOfTheOutputPaneShowsTheTask() {
        let rig = makeRig(initial: Self.lines(0 ..< 5))

        rig.view.apply(content: content(description: "npm run build"))
        rig.layout()

        XCTAssertEqual(rig.view.header.kindText, "Shell")
        XCTAssertEqual(rig.view.header.descriptionText, "npm run build")
        XCTAssertEqual(rig.view.header.statusText, "running")
    }

    func testTheNoOutputViewShowsTheMessageAndTheHeaderNeverAnEmptyPane() {
        for kind in [TaskKindWire.workflow, .other, .unknown("something-new")] {
            let window = makeRigWindow(self, size: NSSize(width: 600, height: 400), appearance: NSAppearance(named: .darkAqua))
            let view = TaskNoOutputView(focusTag: "kate", taskId: "w1")
            window.contentView = view
            XCTAssertEqual(view.messageText, "No output available for this kind of task", "\(kind)")

            view.apply(content: content(kind: kind, description: "nightly import"))
            view.layoutSubtreeIfNeeded()

            XCTAssertEqual(view.messageText, "No output available for this kind of task", "\(kind)")
            XCTAssertFalse(view.header.kindText.isEmpty, "\(kind): the header names the kind")
            XCTAssertFalse(view.header.statusText.isEmpty, "\(kind): and the status")
            XCTAssertEqual(view.header.descriptionText, "nightly import")
            let labels = rigAllSubviews(of: view).compactMap { $0 as? NSTextField }
            let message = labels.first { $0.stringValue == view.messageText }
            XCTAssertNotNil(message, "\(kind): the message is a label in the pane")
            XCTAssertFalse(message?.isHiddenOrHasHiddenAncestor ?? true, "\(kind): and it is shown")
            if let message {
                XCTAssertLessThanOrEqual(message.frame.maxY, view.header.frame.minY + 0.5, "\(kind): under the header, not on it")
                XCTAssertGreaterThan(message.frame.minY, 0, "\(kind): inside the pane")
            }
        }
    }

    // MARK: Lifetime

    func testTheViewSubscribesToTheModelOnlyWeakly() {
        let rig = makeRig(initial: Self.lines(0 ..< 10), withView: false)
        weak var probe: TaskOutputView?

        autoreleasepool {
            let view = TaskOutputView(focusTag: "kate", taskId: "t1", model: rig.model, pasteboard: rig.pasteboard)
            probe = view
            rig.appendLines(10 ..< 12)
            XCTAssertEqual(view.appendOps, 1, "premise: the live view receives what the model publishes")
        }

        XCTAssertNil(probe, "the model's subscription must not keep a released view alive")
        rig.appendLines(12 ..< 14)
        XCTAssertTrue(rig.model.text.hasSuffix(Self.line(13)), "the model goes on without the view")
    }
}
