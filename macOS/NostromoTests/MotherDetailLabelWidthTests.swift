import XCTest
import AppKit
import Combine
import NostromoKit

// ML-1 / ML-4: a Mother job's text comes from data (a plan checklist item, a todo, a log
// line, a gate name, an action error). However long it is, and whether or not it has
// spaces to wrap at, it must not widen the job detail beyond its pane, and so must not
// widen `MainLayout` beyond a window that cannot grow (a full-screen window).
//
// The real `MotherJobDetail` is shown as a tab of the real Mother pane inside the real
// `MainLayout` (Mother focus) in a fixed 1920 x 1080 window, fed through its public
// surface: `select(job)` with a plan file on disk, a peek payload for the todo, a log file
// in the log directory, a gate in the job's crew data, and an action error from the host.
final class MotherDetailLabelWidthTests: XCTestCase {

    // MARK: - Fixtures

    private enum Field: String, CaseIterable {
        case planChecklistItem, todo, logLine, gateName, actionError, title
    }

    private static let windowSize = NSSize(width: 1920, height: 1080)
    private static let noSpaces = String(repeating: "x", count: 5000)
    private static var withSpaces: String {
        String(String(repeating: "word ", count: 1000).prefix(5000))
    }
    private static let short = "short text"

    private final class StubHost: MotherJobDetailHost {
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
        var supportsAnswerOption = false
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

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Rig {
        let window: NSWindow
        let layout: MainLayout
        let pane: TabRegionView
        let detail: MotherJobDetail
        let host: StubHost
    }

    private func allSubviews(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews($0) }
    }

    private func settle(_ window: NSWindow, seconds: TimeInterval = 0.4) {
        // Plan and log files are read on a background queue and applied on main.
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        } while Date() < end
    }

    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdlw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func job(id: String, title: String = "A job", planPath: String? = nil, gateName: String = "unit") -> MotherJob {
        let crew = MotherCrewState(
            optedIn: true,
            activity: "gates",
            gates: MotherGates(mode: "enforce", status: "running", attempt: 1, maxAttempts: 3, results: [
                MotherGateResultEntry(name: "lint", result: .passed, blocking: true, durationS: 40),
                MotherGateResultEntry(name: gateName, result: .failed, blocking: true, durationS: 188),
            ]))
        return MotherJob(id: id, state: "running", repo: "Carefeed/payments", isolation: "worktree", title: title,
                         createdAt: nil, startedAt: nil, finishedAt: nil, planPath: planPath, question: nil,
                         pausedReason: nil, adherenceStatus: nil, currentTier: nil, crew: crew)
    }

    /// The real Mother focus in a fixed window, with a real `MotherJobDetail` (stub host,
    /// private log directory) as a tab of the Mother pane, showing `fields` filled with `text`.
    private func makeRig(fields: Set<Field>, text: String, index: Int) throws -> Rig {
        let displayUUID = "mdlw-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == "mother" }!
        UserDefaults.standard.set(focus.id, forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }
        AppStore.shared.applyForTesting(.focusLayout(
            tag: focus.sessionTag,
            tree: .split(direction: .vertical,
                         children: [.leaf(paneId: "mother_queue"), .leaf(paneId: "repl")],
                         ratios: [0.8, 0.2]),
            focusedPane: nil))

        let size = Self.windowSize
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = MainLayout(windowIndex: index, displayUUID: displayUUID)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        settle(window, seconds: 0.1)

        let motherView = try XCTUnwrap(allSubviews(layout).compactMap { $0 as? MotherView }.first,
                                       "the Mother focus shows no MotherView")
        let pane = try XCTUnwrap(allSubviews(motherView).compactMap { $0 as? TabRegionView }.first,
                                 "the Mother view has no tab region")

        let dir = try makeTemp()
        let host = StubHost()
        let jobId = "j-\(index)"
        func pick(_ f: Field, _ normal: String) -> String { fields.contains(f) ? text : normal }

        var planPath: String?
        let planText = pick(.planChecklistItem, "Write the thing")
        let plan = dir.appendingPathComponent("plan.md")
        try "# Plan\n\n- [ ] \(planText)\n- [x] done item\n".write(to: plan, atomically: true, encoding: .utf8)
        planPath = plan.path

        let logLine = pick(.logLine, "log line")
        let logJSON: [String: Any] = ["type": "assistant",
                                      "message": ["content": [["type": "text", "text": logLine]]]]
        let logData = try JSONSerialization.data(withJSONObject: logJSON)
        try (String(decoding: logData, as: UTF8.self) + "\n")
            .write(to: dir.appendingPathComponent("\(jobId).log"), atomically: true, encoding: .utf8)

        host.payload = MotherPeekPayload(jobId: jobId,
                                         todos: [MotherPeekItem(status: "in_progress", content: pick(.todo, "A todo")),
                                                 MotherPeekItem(status: "completed", content: pick(.todo, "A done todo"))],
                                         toolTrail: [], lastText: "")

        let detail = MotherJobDetail(host: host, logDirectory: dir)
        detail.translatesAutoresizingMaskIntoConstraints = false
        pane.addTab(TabRegionView.Tab(paneId: "mother_job:\(jobId)", label: "job", view: detail))
        pane.selectTab("mother_job:\(jobId)")
        addTeardownBlock { detail.select(nil) }

        detail.select(job(id: jobId, title: pick(.title, "A job"), planPath: planPath, gateName: pick(.gateName, "unit")))
        if fields.contains(.actionError) {
            host.errorSubject.send(text)
        }
        settle(window)
        return Rig(window: window, layout: layout, pane: pane, detail: detail, host: host)
    }

    private func assertFits(_ rig: Rig, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let content = rig.window.contentRect(forFrameRect: rig.window.frame).size
        let paneWidth = rig.pane.bounds.width
        XCTAssertEqual(rig.layout.frame.width, content.width, accuracy: 1,
                       "\(label): MainLayout is \(rig.layout.frame.width) wide in a \(content.width) window",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(rig.detail.fittingSize.width, paneWidth + 1,
                                 "\(label): the job detail demands \(rig.detail.fittingSize.width) pt in a \(paneWidth) pt pane",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(rig.detail.frame.width, paneWidth + 1,
                                 "\(label): the job detail is \(rig.detail.frame.width) pt wide in a \(paneWidth) pt pane",
                                 file: file, line: line)
        XCTAssertEqual(rig.layout.contentOverflow, .zero,
                       "\(label): MainLayout overflows its window", file: file, line: line)
        XCTAssertEqual(rig.window.frame.size, rig.window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.windowSize)).size,
                       "\(label): the window changed size", file: file, line: line)
    }

    // MARK: - Tests

    func testShortTextControlFitsTheWindow() throws {
        let rig = try makeRig(fields: Set(Field.allCases), text: Self.short, index: 700)
        assertFits(rig, "short text in every field")
        XCTAssertGreaterThan(rig.detail.frame.width, 100, "control: the detail is actually laid out in the pane")
    }

    func testA5000CharUnbrokenStringInAnyFieldDoesNotWidenTheDetailOrTheWindowContent() throws {
        var index = 710
        for field in Field.allCases {
            let rig = try makeRig(fields: [field], text: Self.noSpaces, index: index)
            index += 1
            assertFits(rig, "\(field.rawValue), 5000 chars without spaces")
        }
    }

    func testA5000CharSentenceInAnyFieldDoesNotWidenTheDetailOrTheWindowContent() throws {
        var index = 730
        for field in Field.allCases {
            let rig = try makeRig(fields: [field], text: Self.withSpaces, index: index)
            index += 1
            assertFits(rig, "\(field.rawValue), 5000 chars with spaces")
        }
    }

    func testEveryFieldAtOnceFitsWithAndWithoutSpaces() throws {
        for (n, text) in [("no spaces", Self.noSpaces), ("spaces", Self.withSpaces)].enumerated() {
            let rig = try makeRig(fields: Set(Field.allCases), text: text.1, index: 750 + n)
            assertFits(rig, "all fields, 5000 chars, \(text.0)")
        }
    }
}
