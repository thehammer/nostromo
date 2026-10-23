import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "pane-blank")

/// What `PaneRenderWatch` needs to know about a transcript pane. `ReplView` is the only conformer.
protocol PaneRenderSubject: TranscriptDiagnostics.Reporting {
    var renderWindow: NSWindow? { get }
    /// In a window, not hidden, the window not occluded, with a usable size.
    var isRenderVisible: Bool { get }
    /// Materialized turn views whose frame intersects the clip view's bounds.
    var visibleTurnViewCount: Int { get }
    var viewportHeight: Double { get }
    /// A materialization pass is queued or running (so an empty region is about to be filled).
    var isRenderPassPending: Bool { get }
    /// A deliberate shed released every view and the compaction before the rebuild has not landed.
    var isShedInFlight: Bool { get }
    /// (pane alpha, pane hidden, scroll view hidden, scroll view still a subview of the pane).
    var renderPaneState: (alpha: Double, hidden: Bool, scrollViewHidden: Bool, scrollViewAttached: Bool) { get }
    /// Numbers describing the pane's geometry (sizes, offsets): content-free.
    var renderGeometry: [String: Double] { get }
}

/// One transcript pane's flight recorder, blank detector and capture trigger.
///
/// Detection and capture only: nothing here changes what the pane renders, scrolls or measures. The
/// pane tells the watch what it did (`recorder`), the watch looks at the pane at most once per run-loop
/// turn (`requestEvaluation`) and on a timer while the pane is visible (250 ms, backing off to 1 s
/// while the pane is healthy and nothing has asked for a look), and a detector hit
/// writes one content-free file (`PaneBlankCapture`). See `docs/pane-blank-capture.md`.
///
/// Everything runs on the main thread.
final class PaneRenderWatch {

    /// The timer's period while the pane is visible and anything is going on.
    static let evaluationIntervalMs = 250.0
    /// The timer's period once the pane has been healthy, with nothing asking for a look, for
    /// `calmTicksBeforeBackoff` ticks in a row. Any event or suspicion puts it back to `evaluationIntervalMs`.
    static let idleEvaluationIntervalMs = 1_000.0
    static let calmTicksBeforeBackoff = 4
    /// Stall events (a slow measurement, a run-loop stall) coalesce into one ring slot per this long, and
    /// a rule's `detectorHit` event is recorded at most once per this long (the rest are only counted), so
    /// a storm of stalls cannot push the structural events that led up to it out of the ring.
    static let stallRecordIntervalMs = 5_000.0
    static let hitRecordIntervalMs = PaneBlankDetector.zeroRowDrawRefractoryMs
    /// At most one automatic capture per pane per this long, per severity.
    static let minCaptureIntervalMs = 300_000.0

    static func monotonicMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    let recorder = PaneFlightRecorder()
    private(set) var detector = PaneBlankDetector()

    /// Where captures go. nil means `~/.nostromo/logs`, except under XCTest, where nil means no
    /// capture at all (a test must never write into the user's home).
    var captureDirectory: URL?
    /// Test seam: non-nil replaces the "pane is on screen" check.
    var visibilityOverride: Bool?
    /// Test seam: non-nil replaces the sampled document height.
    var documentHeightOverride: Double?
    /// Test seam: non-nil replaces the pane's "a deliberate shed is in flight".
    var shedInFlightOverride: Bool?
    /// An automatic capture is built and written on the next main-queue turn instead of inside the draw
    /// or run-loop callback that detected the blank. Off under XCTest so a test sees its file at once.
    var deferCaptureWrites: Bool = PaneRenderWatch.isRunningTests ? false : true
    /// The timer, the run-loop observer and the draw heartbeat only run when this is true. Under XCTest
    /// it starts false so a slow test machine cannot raise a real stall in the middle of a test that
    /// drives the clock itself; the explicit `evaluate`, `noteDraw`, `noteStall` and `captureNow` work either way.
    var automaticEvaluation: Bool = PaneRenderWatch.isRunningTests ? false : true {
        didSet {
            if automaticEvaluation { RunLoopTurnObserver.installIfNeeded() }
            updateScheduling()
        }
    }

    private(set) var lastCaptureURL: URL?
    private(set) var captureCount = 0

    private weak var subject: PaneRenderSubject?
    private let tagHash: String
    private var lastAutoCaptureMs: [PaneBlankDetector.Severity: Double] = [:]
    private var evaluationRequested = false

    private var timer: Timer?
    /// The running timer's period, nil when there is no timer.
    private(set) var timerIntervalMs: Double?
    private var calmTicks = 0
    /// Something asked for a look (or a hit fired) since the last timer tick.
    private var activitySinceTick = false
    private var lastHitRecordedMs: [PaneBlankDetector.Rule: Double] = [:]
    /// Hits not recorded in the ring because the same rule had just been recorded, by rule.
    private var suppressedHits: [PaneBlankDetector.Rule: Int] = [:]
    private var lastRecordedState: (alpha: Double, hidden: Bool, scrollViewHidden: Bool, scrollViewAttached: Bool)?
    private var lastRecordedSize: (w: Double, h: Double)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private weak var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    private static let all = NSHashTable<PaneRenderWatch>.weakObjects()
    /// Set by any watch's `requestEvaluation`, cleared by the run-loop observer: so a turn in which
    /// nothing asked for an evaluation costs two clock reads and no walk over the panes.
    fileprivate static var anyEvaluationRequested = false
    /// When a run-loop stall last wrote a capture, for any pane (see `mainThreadStalled`).
    private static var lastObservedStallCaptureMs = -minCaptureIntervalMs
    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    init(subject: PaneRenderSubject) {
        self.subject = subject
        tagHash = PaneBlankCapture.tagHash(subject.diagnosticsTag)
        Self.all.add(self)
        if automaticEvaluation { RunLoopTurnObserver.installIfNeeded() }
        installAppObservers()
    }

    deinit {
        timer?.invalidate()
        for entry in observers { entry.center.removeObserver(entry.token) }
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Evaluation

    /// Looks at the pane now: records its visibility state if it changed, runs rules (a) and (b), and
    /// writes a capture (rate-limited) when one fires. Returns the hits that fired, rate limited or not.
    @discardableResult
    func evaluate(nowMs: Double = PaneRenderWatch.monotonicMs(), wall: Date = Date()) -> [PaneBlankDetector.Hit] {
        evaluationRequested = false
        guard let subject else { return [] }
        pollPaneState()
        let sample = PaneBlankDetector.Sample(
            nowMs: nowMs, isVisible: isVisible,
            retainedTurns: subject.retainedTurnCount,
            visibleTurnViews: subject.visibleTurnViewCount,
            documentHeight: documentHeightOverride ?? subject.estimatedDocumentHeight,
            viewportHeight: subject.viewportHeight,
            transcriptClears: subject.transcriptClearCount,
            shedInFlight: shedInFlightOverride ?? subject.isShedInFlight)
        let hits = detector.evaluate(sample)
        for hit in hits { handle(hit, nowMs: nowMs, wall: wall) }
        // A pane that became visible without a notification (it was attached to a window that was
        // already on screen, then laid out) gets its timer here; one that stopped being visible loses it.
        updateScheduling()
        return hits
    }

    /// A draw pass over the pane's document view. `rowsPainted` is how many turn rows intersected it.
    @discardableResult
    func noteDraw(rowsPainted: Int, dirtyRect: NSRect,
                  nowMs: Double = PaneRenderWatch.monotonicMs(), wall: Date = Date()) -> [PaneBlankDetector.Hit] {
        guard let subject else { return [] }
        recorder.recordCoalesced(.draw, minIntervalMs: 100, Double(dirtyRect.width), Double(dirtyRect.height),
                                 Double(rowsPainted), Double(rowsPainted))
        guard let hit = detector.noteDraw(nowMs: nowMs, isVisible: isVisible, retainedTurns: subject.retainedTurnCount,
                                          rowsPainted: rowsPainted, renderPending: subject.isRenderPassPending)
        else { return [] }
        handle(hit, nowMs: nowMs, wall: wall)
        return [hit]
    }

    /// The main thread was busy for `ms` without returning to the run loop.
    @discardableResult
    func noteStall(ms: Double, nowMs: Double = PaneRenderWatch.monotonicMs(), wall: Date = Date(),
                   capture: Bool = true) -> [PaneBlankDetector.Hit] {
        guard let hit = detector.noteStall(ms: ms, isVisible: isVisible) else { return [] }
        handle(hit, nowMs: nowMs, wall: wall, capture: capture)
        return [hit]
    }

    /// The pane changed something an evaluation should look at; it is looked at once, at the end of the
    /// current run-loop turn, however many times this is called in it.
    func requestEvaluation() {
        guard automaticEvaluation else { return }
        noteActivity()
        guard !evaluationRequested else { return }
        evaluationRequested = true
        Self.anyEvaluationRequested = true
    }

    /// A reflow the operator caused (resize, fold toggle): the height may move a lot.
    func noteLegitimateReflow() {
        detector.rebaselineHeight()
    }

    // MARK: - Capture

    /// Debug ▸ Capture render state now (and `nostromo-app capture-render-state`): always writes, for
    /// this pane, whether or not it looks blank, and neither honours nor consumes the rate limit.
    @discardableResult
    func captureNow(nowMs: Double = PaneRenderWatch.monotonicMs(), wall: Date = Date()) -> URL? {
        recorder.record(.capture, reason: .manual, 1)
        let hit = PaneBlankDetector.Hit(rule: .manual, severity: .manual, detail: [:])
        return write(hit, trigger: "manual", wall: wall)
    }

    /// The manual capture for every live transcript pane that is on screen.
    @discardableResult
    static func captureAllVisible(nowMs: Double = PaneRenderWatch.monotonicMs(), wall: Date = Date()) -> [URL] {
        all.allObjects
            .filter { $0.isVisible }
            .compactMap { $0.captureNow(nowMs: nowMs, wall: wall) }
    }

    /// The newest capture of this pane, for `nostromo-app windows` (`blankCapture`).
    var latestCapturePath: String? {
        effectiveDirectory.flatMap { PaneBlankCapture.latestPath(tagHash: tagHash, in: $0) }
    }

    private var effectiveDirectory: URL? {
        captureDirectory ?? (Self.isRunningTests ? nil : PaneBlankCapture.defaultDirectory)
    }

    private func handle(_ hit: PaneBlankDetector.Hit, nowMs: Double, wall: Date, capture: Bool = true) {
        noteActivity()
        if let last = lastHitRecordedMs[hit.rule], nowMs - last < Self.hitRecordIntervalMs {
            suppressedHits[hit.rule, default: 0] += 1
        } else {
            lastHitRecordedMs[hit.rule] = nowMs
            recorder.record(.detectorHit, hit.rule.code, hit.severity.code)
            log.error("pane blank suspected: rule=\(hit.rule.rawValue, privacy: .public) severity=\(hit.severity.rawValue, privacy: .public)")
        }
        guard capture else { return }
        if let last = lastAutoCaptureMs[hit.severity], nowMs - last < Self.minCaptureIntervalMs { return }
        // Stamped before the write: a directory that cannot be written must not be retried on every pass.
        lastAutoCaptureMs[hit.severity] = nowMs
        if deferCaptureWrites {
            DispatchQueue.main.async { [weak self] in self?.write(hit, trigger: "auto", wall: wall) }
        } else {
            write(hit, trigger: "auto", wall: wall)
        }
    }

    @discardableResult
    private func write(_ hit: PaneBlankDetector.Hit, trigger: String, wall: Date) -> URL? {
        guard let directory = effectiveDirectory else { return nil }
        if trigger == "auto" { recorder.record(.capture, 0) }
        let report = report(hit, trigger: trigger, wall: wall)
        guard let url = PaneBlankCapture.write(report, tagHash: tagHash, directory: directory, now: wall,
                                                 manual: trigger == "manual") else {
            log.error("pane blank capture could not be written")
            return nil
        }
        lastCaptureURL = url
        captureCount += 1
        log.error("pane blank capture written: \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// The capture as a JSON object. Structure only: numbers, booleans and fixed names (rule, severity,
    /// event kind and reason, the build string), never any free text, so nothing the OS or the user
    /// named (a screen, a window title) can reach it. A screen is its index, frame and scale.
    private func report(_ hit: PaneBlankDetector.Hit, trigger: String, wall: Date) -> [String: Any] {
        var out: [String: Any] = [
            "schema": 1,
            "capturedAtUTC": Self.utcISO(wall),
            "trigger": trigger,
            "reason": hit.rule.rawValue,
            "rule": hit.rule.rawValue,
            "severity": hit.severity.rawValue,
            "detail": hit.detail,
            "suppressedHits": Dictionary(uniqueKeysWithValues: suppressedHits.map { ($0.key.rawValue, $0.value) }),
            "events": recorder.eventDictionaries(now: wall),
            "app": appInfo(),
            "screens": NSScreen.screens.enumerated().map { index, screen -> [String: Any] in
                ["index": index, "frame": Self.rect(screen.frame), "scale": Double(screen.backingScaleFactor)]
            },
        ]
        if let subject {
            out["diagnostics"] = [
                "retainedTurns": subject.retainedTurnCount,
                "materializedViews": subject.materializedViewCount,
                "visibleTurnViews": subject.visibleTurnViewCount,
                "estimatedDocHeight": Self.finite(subject.estimatedDocumentHeight),
                "transcriptClears": subject.transcriptClearCount,
                "slowMeasures": subject.slowMeasureCount,
                "worstMeasureMs": Self.finite(subject.worstMeasureMs),
                "viewportHeight": Self.finite(subject.viewportHeight),
            ] as [String: Any]
            out["pane"] = subject.renderGeometry.mapValues(Self.finite)
        }
        if let window = subject?.renderWindow {
            out["window"] = [
                "frame": Self.rect(window.frame),
                "screenIndex": window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? -1,
                "isKey": window.isKeyWindow,
                "occluded": !window.occlusionState.contains(.visible),
                "alpha": Double(window.alphaValue),
                "fullscreen": window.styleMask.contains(.fullScreen),
            ] as [String: Any]
        } else {
            out["window"] = NSNull()
        }
        return out
    }

    // MARK: - Visibility, state

    private var isVisible: Bool {
        visibilityOverride ?? subject?.isRenderVisible ?? false
    }

    /// Records the pane's alpha / hidden / attachment state when it differs from the last record.
    func pollPaneState() {
        guard let state = subject?.renderPaneState else { return }
        if let last = lastRecordedState, last == state { return }
        lastRecordedState = state
        recorder.record(.paneState, state.alpha, state.hidden ? 1 : 0,
                        state.scrollViewHidden ? 1 : 0, state.scrollViewAttached ? 1 : 0)
    }

    /// Records the pane's size when it changed (a layout pass that changed nothing is not an event).
    func noteLayout(width: Double, height: Double, scrollViewHeight: Double, contentWidth: Double) {
        if let last = lastRecordedSize, last.w == width, last.h == height { return }
        lastRecordedSize = (width, height)
        recorder.record(.layout, reason: .resize, width, height, scrollViewHeight, contentWidth)
    }

    /// The pane's visibility may have changed: start or stop the timer.
    func updateScheduling() {
        let want = automaticEvaluation && subject != nil && isVisible
        if want, timer == nil {
            startTimer(intervalMs: Self.evaluationIntervalMs)
        } else if !want, let t = timer {
            t.invalidate()
            timer = nil
            timerIntervalMs = nil
        }
    }

    /// One timer tick: look, then back off to the idle period after enough healthy ticks in a row with
    /// nothing asking for a look, or go back to the fast period on anything else.
    func timerTick() {
        let hits = evaluate()
        let calm = hits.isEmpty && !detector.isWatching && !activitySinceTick
        activitySinceTick = false
        guard timer != nil else { return }
        if calm {
            calmTicks += 1
            if calmTicks >= Self.calmTicksBeforeBackoff, timerIntervalMs == Self.evaluationIntervalMs {
                startTimer(intervalMs: Self.idleEvaluationIntervalMs)
            }
        } else {
            calmTicks = 0
            if timerIntervalMs != Self.evaluationIntervalMs { startTimer(intervalMs: Self.evaluationIntervalMs) }
        }
    }

    /// An event or a hit: the next ticks are not calm, and an idle timer goes back to the fast period.
    private func noteActivity() {
        activitySinceTick = true
        calmTicks = 0
        if let current = timerIntervalMs, current != Self.evaluationIntervalMs {
            startTimer(intervalMs: Self.evaluationIntervalMs)
        }
    }

    private func startTimer(intervalMs: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: intervalMs / 1000, repeats: true) { [weak self] _ in
            self?.timerTick()
        }
        t.tolerance = intervalMs / 1000 * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerIntervalMs = intervalMs
        calmTicks = 0
    }

    /// The pane moved to `window` (or out of any window): watch its key, screen and occlusion changes.
    func windowChanged(to window: NSWindow?) {
        recorder.record(.moveToWindow, reason: .none, window == nil ? 0 : 1)
        guard window == nil || window !== observedWindow else { return }
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers.removeAll()
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.recorder.record(.windowKey, 1)
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.recorder.record(.windowKey, 0)
            },
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
                let screen = window?.screen
                self?.recorder.record(.windowScreen, Double(screen?.frame.width ?? 0), Double(screen?.frame.height ?? 0),
                                      Double(screen?.backingScaleFactor ?? 0))
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                self?.recorder.record(.windowOcclusion, window?.occlusionState.contains(.visible) == true ? 1 : 0)
                self?.updateScheduling()
                self?.requestEvaluation()
            },
        ]
    }

    // MARK: - App-level events

    private func installAppObservers() {
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (PaneRenderWatch) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { body(self) }
            }
            observers.append((center, token))
        }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        add(app, NSApplication.didBecomeActiveNotification) { $0.recorder.record(.appActive, 1) }
        add(app, NSApplication.didResignActiveNotification) { $0.recorder.record(.appActive, 0) }
        add(app, NSApplication.didChangeScreenParametersNotification) { $0.recorder.record(.displayReconfig, Double(NSScreen.screens.count)) }
        add(workspace, NSWorkspace.willSleepNotification) { $0.recorder.record(.systemSleep) }
        add(workspace, NSWorkspace.didWakeNotification) { $0.recorder.record(.systemWake) }
    }

    // MARK: - Run-loop hooks (called by `RunLoopTurnObserver`)

    fileprivate func endOfRunLoopTurn() {
        guard automaticEvaluation, evaluationRequested else { return }
        evaluate()
    }

    /// One stall is one capture for the whole app: the first visible pane writes it (and a stall is
    /// captured at most once per `minCaptureIntervalMs` app-wide); every other visible pane only records
    /// it. Returns whether this pane took the capture.
    func mainThreadStalled(ms: Double, mayCapture: Bool) -> Bool {
        guard automaticEvaluation, isVisible else { return false }
        recorder.recordCoalesced(.runLoopStall, minIntervalMs: Self.stallRecordIntervalMs, ms)
        let now = Self.monotonicMs()
        let capture = mayCapture && now - Self.lastObservedStallCaptureMs >= Self.minCaptureIntervalMs
        noteStall(ms: ms, nowMs: now, capture: capture)
        if capture { Self.lastObservedStallCaptureMs = now }
        return capture
    }

    fileprivate static var liveWatches: [PaneRenderWatch] { all.allObjects }

    // MARK: - Encoding helpers

    private func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let uptime = Self.processStart.map { max(0, Date().timeIntervalSince($0)) } ?? -1
        return ["uptimeSeconds": uptime, "build": "\(version) (\(build))",
                "pid": Int(ProcessInfo.processInfo.processIdentifier)]
    }

    /// When this process started, from the kernel (so uptime does not depend on when the first pane appeared).
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    private static func utcISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// JSON has no NaN or infinity.
    private static func finite(_ v: Double) -> Double { v.isFinite ? v : -1 }

    private static func rect(_ r: NSRect) -> [String: Double] {
        ["x": finite(Double(r.minX)), "y": finite(Double(r.minY)), "w": finite(Double(r.width)), "h": finite(Double(r.height))]
    }
}

// MARK: - RunLoopTurnObserver

/// Two observers on the main run loop for the whole app: one marks when a turn starts, the other, last
/// of all (after AppKit's and Core Animation's layout and display, which run in `beforeWaiting` observers
/// of their own), tells every watch to run a requested evaluation and reports a turn that was busy for
/// longer than `PaneBlankDetector.stallThresholdMs`. Two clock reads per turn.
private enum RunLoopTurnObserver {
    private static var observers: [CFRunLoopObserver] = []
    private static var turnStartNs: UInt64 = 0

    static func installIfNeeded() {
        guard observers.isEmpty else { return }
        let start = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue,
                                                       true, Int.min) { _, _ in
            turnStartNs = DispatchTime.now().uptimeNanoseconds
        }
        let end = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                     true, Int.max) { _, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            let busyMs = turnStartNs == 0 ? 0 : Double(now &- turnStartNs) / 1_000_000
            let stalled = busyMs > PaneBlankDetector.stallThresholdMs
            guard stalled || PaneRenderWatch.anyEvaluationRequested else { return }
            PaneRenderWatch.anyEvaluationRequested = false
            var mayCapture = true
            for watch in PaneRenderWatch.liveWatches {
                if stalled, watch.mainThreadStalled(ms: busyMs, mayCapture: mayCapture) { mayCapture = false }
                watch.endOfRunLoopTurn()
            }
        }
        for case let observer? in [start, end] {
            observers.append(observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
}
