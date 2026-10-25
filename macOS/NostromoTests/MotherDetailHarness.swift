import XCTest
import AppKit
import Combine
import NostromoKit

// Shared rig for the Mother vertical-overflow tests (MotherDetailVerticalOverflowTests,
// MotherDetailScrollTests, FocusSplitOversizedChildTests, MotherOverviewAndCrewOverflowTests).
//
// It is the #300 horizontal harness (MotherDetailLabelWidthTests) made reusable: the REAL
// `MainLayout` on the Mother focus in a fixed 1920 x 1080 offscreen window, with a real
// `MotherJobDetail` (stub host, private log directory) as a tab of the real Mother pane, fed only
// through its public surface: `select`/`update`, a plan file on disk, the host's peek publisher,
// its action-error publisher, `setLogAttributed`.
//
// No test in this family may use a window index outside 900...989.

// MARK: - Fixture vocabulary

/// A piece of job data whose length is not ours to control.
enum MDField: String, CaseIterable {
    case title, planChecklist, todos, question, consequences, meta, actionError, gates, lenses, log
}

enum MDText {
    /// Exactly `chars` characters: `marker`, then words separated by spaces (so it wraps anywhere),
    /// with a line break instead of a space about every `lineBreakEvery` characters when asked.
    static func prose(_ marker: String, chars: Int, lineBreakEvery: Int? = nil) -> String {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        var out = marker + " "
        var total = out.count
        var line = total
        var i = 0
        while total < chars {
            let word = words[i % words.count]
            i += 1
            out += word
            total += word.count
            line += word.count
            if let every = lineBreakEvery, line >= every {
                out += "\n"; line = 0
            } else {
                out += " "; line += 1
            }
            total += 1
        }
        return String(out.prefix(chars))
    }
}

enum MDFixtures {
    static let optionCount = 3
    static let longChars = 2_000

    /// `- [ ]` / `- [x]` items; `PLAN-<n> v<version>` marks each rendered row, so a row of an older
    /// plan can be told from one of this plan.
    static func planText(items: Int, long: Bool, version: Int) -> String {
        var lines = ["# Plan", ""]
        for n in 0..<items {
            let text = long ? MDText.prose("PLAN-\(n) v\(version)", chars: 600) : "PLAN-\(n) v\(version) short item"
            lines.append("- [\(n % 3 == 0 ? "x" : " ")] \(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Assistant text lines in the shape the log tail parses; `LOG-<n>` marks each.
    static func logText(lines: Int, long: Bool) -> String {
        (0..<lines).map { n -> String in
            let text = long ? MDText.prose("LOG-\(n)", chars: 600, lineBreakEvery: 90) : "LOG-\(n) log line"
            let object: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    /// `TODO-<n> t<version>` marks each rendered row.
    static func peek(jobId: String, todos: Int, long: Bool, version: Int) -> MotherPeekPayload {
        MotherPeekPayload(jobId: jobId,
                          todos: (0..<todos).map { n in
                              MotherPeekItem(status: n % 3 == 0 ? "completed" : "in_progress",
                                             content: long ? MDText.prose("TODO-\(n) t\(version)", chars: 600) : "TODO-\(n) t\(version) short todo")
                          },
                          toolTrail: [], lastText: "")
    }

    static func actionError(long: Bool) -> String {
        long ? MDText.prose("ERR", chars: longChars) : "ERR short"
    }

    /// An awaiting job holding an open decision with `optionCount` options (the first takes text),
    /// gates, a review wave and meta values, each long or short as `long` says.
    static func job(id: String, long: Set<MDField>, state: String = "awaiting", planPath: String?,
                    decisionId: String = "d1", progressPct: Int? = nil,
                    gateCount: Int? = nil, lensCount: Int? = nil, bare: Bool = false) -> MotherJob {
        func longIf(_ f: MDField, _ marker: String, _ short: String, lineBreakEvery: Int? = nil) -> String {
            long.contains(f) ? MDText.prose(marker, chars: longChars, lineBreakEvery: lineBreakEvery) : short
        }
        let gates = gateCount ?? (long.contains(.gates) ? 40 : 2)
        let lenses = lensCount ?? (long.contains(.lenses) ? 25 : 2)
        let gateEntries = (0..<gates).map { n in
            MotherGateResultEntry(name: long.contains(.gates) ? MDText.prose("gate-\(n)", chars: 160) : "gate-\(n)",
                                  result: n % 2 == 0 ? .passed : .failed, blocking: true, durationS: 40 + n)
        }
        let lensEntries = (0..<lenses).map { n in
            MotherLensEntry(reviewer: "reviewer-\(n)", lens: "lens-\(n)", state: .done,
                            findings: MotherLensFindings(blocking: n % 2, advisory: n % 3))
        }
        let optionSpecs: [(MotherDecisionOptionID, String, Bool)] = [
            (.resumeWithGuidance, "Resume with guidance", true),
            (.escalate, "Escalate", false),
            (.cancel, "Cancel the job", false),
        ]
        let options = optionSpecs.enumerated().map { k, spec in
            MotherDecisionOption(id: spec.0, label: spec.1,
                                 consequence: longIf(.consequences, "CONSEQ-\(k)", "CONSEQ-\(k) short consequence", lineBreakEvery: 90),
                                 takesText: spec.2)
        }
        var crew = MotherCrewState(
            optedIn: true,
            activity: "gates",
            gates: MotherGates(mode: "enforce", status: "failed", attempt: 1, maxAttempts: 3, results: gateEntries),
            reviewWave: MotherReviewWave(mode: "enforce", status: "running", cycle: 1, cycleCap: 3, lenses: lensEntries),
            decision: MotherDecision(id: decisionId, kind: "hold", options: options, openedAt: "2026-10-25T00:00:00Z"))
        if let pct = progressPct {
            crew.progress = MotherProgress(v: 1, pct: pct, label: "building", stage: "build",
                                           updatedAt: "2026-10-25T00:\(String(format: "%02d", min(pct, 59))):00Z")
        }
        return MotherJob(id: id, state: state,
                         repo: longIf(.meta, "META-REPO", "Carefeed/payments"),
                         isolation: longIf(.meta, "META-ISO", "worktree"),
                         title: longIf(.title, "TITLE", "A job"),
                         createdAt: nil, startedAt: Date().addingTimeInterval(-7_200), finishedAt: nil,
                         planPath: planPath,
                         question: longIf(.question, "QUESTION", "Should I keep the column order?", lineBreakEvery: 80),
                         pausedReason: nil,
                         adherenceStatus: longIf(.meta, "META-ADH", "green"),
                         currentTier: longIf(.meta, "META-TIER", "sonnet"),
                         crew: bare ? MotherCrewState() : crew)
    }
}

// MARK: - Stub host

final class MDStubHost: MotherJobDetailHost {
    let connectedSubject = CurrentValueSubject<Bool, Never>(true)
    let errorSubject     = CurrentValueSubject<String?, Never>(nil)
    let peeksSubject     = CurrentValueSubject<[String: MotherPeekPayload], Never>([:])
    var payload: MotherPeekPayload?

    var brokerConnected: Bool { connectedSubject.value }
    var brokerConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var motherActionErrorPublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }
    var motherPeeksPublisher: AnyPublisher<[String: MotherPeekPayload], Never> { peeksSubject.eraseToAnyPublisher() }
    func peek(for jobId: String) -> MotherPeekPayload? { payload }

    var usesDefaultBroker = true
    func motherBinary() -> URL? { nil }
    func answerJob(_ id: String, text: String) {}
    /// True so a held job's options render as buttons with their consequences.
    var supportsAnswerOption = true
    var supportsAck = false
    private let decisionChanges = PassthroughSubject<Void, Never>()
    var motherDecisionChangesPublisher: AnyPublisher<Void, Never> { decisionChanges.eraseToAnyPublisher() }
    func motherDecisionState(jobId: String, decisionId: String) -> MotherDecisionSendState { .idle }
    func beginMotherDecisionConfirm(jobId: String, decisionId: String, option: MotherDecisionOptionID) {}
    func cancelMotherDecisionConfirm(jobId: String, decisionId: String) {}
    func answerMotherDecision(jobId: String, decisionId: String, option: MotherDecisionOption, text: String) {}
    func ackMotherAttention(jobId: String, reason: MotherAttentionReason) {}
    func cancelJob(_ id: String) {}
    func retryJob(_ id: String) {}
    func forceStartJob(_ id: String) {}
    func escalateJob(_ id: String) {}
    func archiveJob(_ id: String) {}
    func openPlan(path: String) {}
    func clearMotherActionError() {}
}

// MARK: - Window

/// A window that never moves or resizes for its content, and is not constrained to the (small) CI screen.
final class MDFixedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The real Mother focus in a fixed window.
final class MDWindow {
    let window: NSWindow
    let layout: MainLayout
    let motherView: MotherView
    /// The Mother pane's tab region (Overview, plus a tab per opened job).
    let pane: TabRegionView

    init(window: NSWindow, layout: MainLayout, motherView: MotherView, pane: TabRegionView) {
        self.window = window; self.layout = layout; self.motherView = motherView; self.pane = pane
    }

    static let size = NSSize(width: 1920, height: 1080)

    var contentSize: NSSize { window.contentRect(forFrameRect: window.frame).size }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

// MARK: - Rig (a job detail in the Mother pane)

final class MDRig {
    let w: MDWindow
    let detail: MotherJobDetail
    let host: MDStubHost
    let dir: URL

    var jobId: String
    var long: Set<MDField>
    var state = "awaiting"
    /// A job with no crew data (no gates, no hold): the shortest a job detail gets.
    var bare = false
    var progressPct: Int?
    var planItems: Int
    var planLong: Bool
    var planPath: String
    var todoCount: Int
    var todoLong: Bool
    private var planVersion = 0
    private var todoVersion = 0
    private var decisionVersion = 1
    private var gateCount: Int?
    private var lensCount: Int?
    private var closed = false

    fileprivate init(w: MDWindow, detail: MotherJobDetail, host: MDStubHost, dir: URL, jobId: String,
                     long: Set<MDField>, planPath: String) {
        self.w = w; self.detail = detail; self.host = host; self.dir = dir; self.jobId = jobId
        self.long = long
        self.planPath = planPath
        self.planItems = long.contains(.planChecklist) ? 200 : 3
        self.planLong = long.contains(.planChecklist)
        self.todoCount = long.contains(.todos) ? 60 : 2
        self.todoLong = long.contains(.todos)
    }

    var window: NSWindow { w.window }

    func currentJob() -> MotherJob {
        MDFixtures.job(id: jobId, long: long, state: state, planPath: planPath,
                       decisionId: "d\(decisionVersion)", progressPct: progressPct,
                       gateCount: gateCount, lensCount: lensCount, bare: bare)
    }

    // MARK: Delivering data after the first layout

    /// Replace the plan file and tell the detail about it, the way a job's plan path changing does.
    func setPlan(items: Int, long: Bool = true) throws {
        planVersion += 1
        let url = dir.appendingPathComponent("plan-\(planVersion).md")
        try MDFixtures.planText(items: items, long: long, version: planVersion).write(to: url, atomically: true, encoding: .utf8)
        planPath = url.path
        planItems = items
        planLong = long
        detail.update(currentJob())
    }

    /// Deliver a new peek payload through the host's publisher.
    func sendPeek(todos: Int, long: Bool = true) {
        todoCount = todos
        todoLong = long
        todoVersion += 1
        let payload = MDFixtures.peek(jobId: jobId, todos: todos, long: long, version: todoVersion)
        host.payload = payload
        host.peeksSubject.send([jobId: payload])
    }

    func setGates(_ count: Int) {
        gateCount = count
        detail.update(currentJob())
    }

    /// The same job in another state (an awaiting job resumes), delivered with `update`.
    func setState(_ newState: String) {
        state = newState
        detail.update(currentJob())
    }

    /// The same job with a progress tick.
    func setProgress(_ pct: Int) {
        progressPct = pct
        detail.update(currentJob())
    }

    /// Make `fields` long, after the detail has already laid out with whatever it had.
    func grow(_ fields: Set<MDField>) throws {
        long.formUnion(fields)
        if fields.contains(.consequences) { decisionVersion += 1 }   // a decision's options are fixed by its id
        if fields.contains(.planChecklist) { try setPlan(items: 200, long: true) }
        if fields.contains(.todos) { sendPeek(todos: 60, long: true) }
        if fields.contains(.log) {
            detail.setLogAttributed(MDFixtures.logText(lines: 200, long: true))
        }
        // The job-shaped fields (title, question, consequences, meta, gates, lenses).
        if fields.contains(.gates) { gateCount = nil }
        if fields.contains(.lenses) { lensCount = nil }
        detail.update(currentJob())
        awaitRendered()
        if fields.contains(.actionError) { host.errorSubject.send(MDFixtures.actionError(long: true)) }
        MD.pump(window)
    }

    /// Select a different job than the one shown (a new id, its own plan file).
    func selectOtherJob(planItems items: Int = 200) throws {
        jobId = jobId + "-b"
        try setPlanFileOnly(items: items)
        detail.select(currentJob())
        awaitRendered()
    }

    /// `update` with a job of a different id (which the detail must treat as a selection).
    func updateToOtherJob(planItems items: Int = 200) throws {
        jobId = jobId + "-c"
        try setPlanFileOnly(items: items)
        detail.update(currentJob())
        awaitRendered()
    }

    private func setPlanFileOnly(items: Int) throws {
        planVersion += 1
        let url = dir.appendingPathComponent("plan-\(planVersion).md")
        try MDFixtures.planText(items: items, long: true, version: planVersion).write(to: url, atomically: true, encoding: .utf8)
        planPath = url.path
        planItems = items
        planLong = true
    }

    // MARK: Rendered content

    func renderedCount(prefix: String, containing tag: String = "") -> Int {
        MD.allSubviews(detail).reduce(0) { n, view in
            if let field = view as? NSTextField, field.stringValue.hasPrefix(prefix),
               tag.isEmpty || field.stringValue.contains(tag) { return n + 1 }
            return n
        }
    }

    private var planRows: Int { renderedCount(prefix: "PLAN-", containing: " v\(planVersion) ") }
    private var todoRows: Int { renderedCount(prefix: "TODO-", containing: " t\(todoVersion) ") }

    /// Waits (pumping the run loop, up to a generous bound, never a fixed sleep) until the plan items,
    /// the todo rows and the log text the rig has delivered are on screen, then lets layout settle.
    /// Fails if they never arrive, so a test cannot pass by looking at an empty detail.
    @discardableResult
    func awaitRendered(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let wantsTodos = state == "awaiting" || state == "running"
        let ok = MD.pumpUntil(window) {
            self.planRows == self.planItems && (!wantsTodos || self.todoRows == self.todoCount)
        }
        XCTAssertTrue(ok, "the content never rendered: plan rows \(planRows)/\(planItems), "
                          + "todo rows \(todoRows)/\(todoCount)", file: file, line: line)
        MD.pump(window)
        return ok
    }

    func close() {
        guard !closed else { return }
        closed = true
        detail.select(nil)
        w.close()
    }
}

// MARK: - Namespace of helpers

enum MD {

    static func allSubviews(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews($0) }
    }

    /// Runs the run loop for `seconds`, laying out and displaying as it goes.
    static func pump(_ window: NSWindow, seconds: TimeInterval = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        } while Date() < end
    }

    /// Pumps until `condition` holds (true) or `timeout` passes (false). A bound, not a duration.
    static func pumpUntil(_ window: NSWindow, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return true }
        }
        return condition()
    }

    static func makeTemp(_ tc: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tc.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The real Mother focus in a fixed 1920 x 1080 window (the Overview tab showing).
    static func makeWindow(_ tc: XCTestCase, index: Int) throws -> MDWindow {
        let displayUUID = "mdh-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == "mother" }!
        UserDefaults.standard.set(focus.id, forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        tc.addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }
        AppStore.shared.applyForTesting(.focusLayout(
            tag: focus.sessionTag,
            tree: .split(direction: .vertical,
                         children: [.leaf(paneId: "mother_queue"), .leaf(paneId: "repl")],
                         ratios: [0.8, 0.2]),
            focusedPane: nil))

        let size = MDWindow.size
        let window = MDFixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                   styleMask: [.titled, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = MainLayout(windowIndex: index, displayUUID: displayUUID)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        tc.addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        pump(window, seconds: 0.1)

        let motherView = try XCTUnwrap(allSubviews(layout).compactMap { $0 as? MotherView }.first,
                                       "the Mother focus shows no MotherView")
        let pane = try XCTUnwrap(allSubviews(motherView).compactMap { $0 as? TabRegionView }.first,
                                 "the Mother view has no tab region")
        return MDWindow(window: window, layout: layout, motherView: motherView, pane: pane)
    }

    /// A job detail as a tab of the Mother pane, showing a job whose `long` fields are long.
    /// The rig is closed when the test ends (call `close()` earlier to free a window mid-test).
    static func makeRig(_ tc: XCTestCase, long: Set<MDField>, index: Int, bare: Bool = false) throws -> MDRig {
        let w = try makeWindow(tc, index: index)
        let dir = try makeTemp(tc)
        let host = MDStubHost()
        let jobId = "j-\(index)"

        let planItems = long.contains(.planChecklist) ? 200 : 3
        let plan = dir.appendingPathComponent("plan-0.md")
        try MDFixtures.planText(items: planItems, long: long.contains(.planChecklist), version: 0)
            .write(to: plan, atomically: true, encoding: .utf8)

        let logLines = long.contains(.log) ? 200 : 1
        try MDFixtures.logText(lines: logLines, long: long.contains(.log))
            .write(to: dir.appendingPathComponent("\(jobId).log"), atomically: true, encoding: .utf8)

        host.payload = MDFixtures.peek(jobId: jobId, todos: long.contains(.todos) ? 60 : 2, long: long.contains(.todos), version: 0)

        let detail = MotherJobDetail(host: host, logDirectory: dir)
        detail.translatesAutoresizingMaskIntoConstraints = false
        w.pane.addTab(TabRegionView.Tab(paneId: "mother_job:\(jobId)", label: "job", view: detail))
        w.pane.selectTab("mother_job:\(jobId)")

        let rig = MDRig(w: w, detail: detail, host: host, dir: dir, jobId: jobId, long: long, planPath: plan.path)
        tc.addTeardownBlock { rig.close() }
        rig.bare = bare
        if bare { rig.state = "running" }

        detail.select(rig.currentJob())
        // The detail also listens to the host's peeks publisher, whose first (empty) value is delivered
        // on the main queue after `select`; it would clear the todos the stub's `peek(for:)` returned.
        host.peeksSubject.send([jobId: host.payload!])
        rig.awaitRendered()
        // The log is read on a background queue too.
        let wantedLog = long.contains(.log) ? "LOG-\(logLines - 1) " : "LOG-0 "
        let logged = pumpUntil(w.window) { detail.logTextView.string.contains(wantedLog) }
        XCTAssertTrue(logged, "the log tail never rendered")
        // The error auto-clears after 5 s, so it is sent last, right before the measurement.
        host.errorSubject.send(MDFixtures.actionError(long: long.contains(.actionError)))
        pump(w.window)
        return rig
    }

    // MARK: Diagnostics

    private static func fmt(_ size: NSSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    /// One line per level between `MainLayout` and `detail` (or the Mother pane), then the detail's own
    /// children and stack levels: frame size and fitting size of each, so the level that demands the
    /// extra height can be read from CI output.
    static func diagnostics(_ w: MDWindow, detail: MotherJobDetail? = nil) -> String {
        func describe(_ name: String, _ v: NSView) -> String {
            let fit = v.fittingSize
            return "\(name) [\(type(of: v))] frame=\(fmt(v.frame.size)) fitting=\(fmt(fit))"
        }
        var lines = ["window.frame=\(fmt(w.window.frame.size)) content=\(fmt(w.contentSize)) contentOverflow=\(w.layout.contentOverflow)"]
        var chain: [NSView] = []
        var cursor: NSView? = detail ?? w.pane
        while let v = cursor {
            chain.append(v)
            if v === w.layout { break }
            cursor = v.superview
        }
        for v in chain.reversed() {
            let name: String
            if v === w.layout { name = "MainLayout" }
            else if v === w.motherView { name = "MotherView" }
            else if v === w.pane { name = "TabRegionView" }
            else if let detail, v === detail { name = "detail" }
            else { name = "level" }
            lines.append("  " + describe(name, v))
        }
        if let detail {
            for sub in detail.subviews where !sub.isHidden {
                lines.append("    detail child " + describe("child", sub))
            }
            let stacks = allSubviews(detail).compactMap { $0 as? NSStackView }.filter { !$0.isHidden }
            for stack in stacks.prefix(12) {
                lines.append("    stack " + describe("stack", stack) + " arranged=\(stack.arrangedSubviews.count)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Assertions

    /// The window cannot grow (like a full-screen one): the layout must be exactly the window's content,
    /// not overflowing it, and not demanding more height than it has; the window must keep its size.
    /// `checkFittingSize: false` is for tests that put a child with a demand of its own into the window (a
    /// 5,000 pt tall one): the contract there is that the window and the layout's frame do not change, not
    /// that the layout's *minimum* size ignores the child (a clipped child still has a fitting size).
    static func assertFits(_ w: MDWindow, detail: MotherJobDetail? = nil, _ label: String,
                           checkFittingSize: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) {
        let content = w.contentSize
        XCTAssertEqual(w.layout.frame.height, content.height, accuracy: 1,
                       "\(label): MainLayout is \(w.layout.frame.height) tall in a \(content.height) window\n\(diagnostics(w, detail: detail))",
                       file: file, line: line)
        XCTAssertEqual(w.layout.frame.width, content.width, accuracy: 1,
                       "\(label): MainLayout is \(w.layout.frame.width) wide in a \(content.width) window\n\(diagnostics(w, detail: detail))",
                       file: file, line: line)
        XCTAssertEqual(w.layout.contentOverflow, .zero,
                       "\(label): MainLayout overflows its window\n\(diagnostics(w, detail: detail))",
                       file: file, line: line)
        XCTAssertEqual(w.window.frame.size, w.window.frameRect(forContentRect: NSRect(origin: .zero, size: MDWindow.size)).size,
                       "\(label): the window changed size\n\(diagnostics(w, detail: detail))",
                       file: file, line: line)
        if checkFittingSize {
            XCTAssertLessThanOrEqual(w.layout.fittingSize.height, content.height + 1,
                                     "\(label): MainLayout demands \(w.layout.fittingSize.height) pt of height in a \(content.height) pt window\n\(diagnostics(w, detail: detail))",
                                     file: file, line: line)
        }
        if let detail {
            XCTAssertLessThanOrEqual(detail.frame.height, w.pane.bounds.height + 1,
                                     "\(label): the job detail is \(detail.frame.height) pt tall in a \(w.pane.bounds.height) pt pane\n\(diagnostics(w, detail: detail))",
                                     file: file, line: line)
        }
    }

    static func assertFits(_ rig: MDRig, _ label: String, checkFittingSize: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) {
        assertFits(rig.w, detail: rig.detail, label, checkFittingSize: checkFittingSize, file: file, line: line)
    }
}
