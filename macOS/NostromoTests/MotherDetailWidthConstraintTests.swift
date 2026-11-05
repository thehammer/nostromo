import XCTest
import AppKit
import NostromoKit

// The Overview's document is as wide as its clip, and that is a preference, not a law: the document's own
// required constraints (its 16 pt margins, the stacks and labels inside it) must never be the casualty.
//
// What the reader cares about, and what these tests hold the line on:
//   - Building a job detail and laying it out at any width conflicts none of its required constraints. AppKit
//     reports a conflict ("Unable to simultaneously satisfy constraints") and recovers by ignoring one of the
//     constraints for that pass; the constraint stays `isActive`, so the only way to see it is the report
//     itself (written to stderr when the process runs under xcodebuild, OS_ACTIVITY_DT_MODE).
//   - A clip narrower than the content can ever be leaves the content intact and the detail settles: it does
//     not keep laying itself out forever.
//
// Not the shared 1920 x 1080 `MDRig`: these tests need to control the width the detail is given, so they
// build a stand-alone `MotherJobDetail` in a plain window, through its public surface only (`select`,
// the scroll view it exposes, its frame).
final class MotherDetailWidthConstraintTests: XCTestCase {

    // MARK: - A detail in a window of our own

    private struct Standalone {
        let window: NSWindow
        let container: NSView
        let detail: MotherJobDetail
        let job: MotherJob

        /// Gives the detail `width` x `height` (adding it to the window the first time) and lets layout run.
        func resize(width: CGFloat, height: CGFloat = 400, seconds: TimeInterval = 0.3) {
            detail.frame = NSRect(x: 0, y: 0, width: width, height: height)
            if detail.superview == nil { container.addSubview(detail) }
            MD.pump(window, seconds: seconds)
        }
    }

    /// A detail that has been built (`init`) but not selected, not in the window, and not laid out. No plan
    /// file and no peek: the app deactivates a few constraints of its own when those arrive (an empty
    /// checklist's height, the todo stack's zero height), and that is not what these tests are about.
    private func makeStandalone() throws -> Standalone {
        let dir = try MD.makeTemp(self)
        let job = MDFixtures.job(id: "wc-1", long: [], planPath: nil)
        try MDFixtures.logText(lines: 1, long: false)
            .write(to: dir.appendingPathComponent("\(job.id).log"), atomically: true, encoding: .utf8)
        let host = MDStubHost()
        let detail = MotherJobDetail(host: host, logDirectory: dir)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = MDFixedWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            detail.select(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        return Standalone(window: window, container: container, detail: detail, job: job)
    }

    private func document(_ detail: MotherJobDetail, file: StaticString = #filePath, line: UInt = #line) throws -> DetailDocumentView {
        try XCTUnwrap(MD.allSubviews(detail).compactMap { $0 as? DetailDocumentView }.first,
                      "the detail holds its Overview document", file: file, line: line)
    }

    // MARK: - Reading AppKit's conflict report

    /// What the process wrote to stderr while `body` ran (AppKit's constraint reports go there under xcodebuild).
    private func captureStandardError(_ body: () throws -> Void) rethrows -> String {
        fflush(stderr)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        let file = open(url.path, O_CREAT | O_RDWR, 0o600)
        let saved = dup(STDERR_FILENO)
        dup2(file, STDERR_FILENO)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try body() } catch { restore(saved, file); throw error }
        restore(saved, file)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func restore(_ saved: Int32, _ file: Int32) {
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        close(file)
    }

    /// The constraint-conflict reports in `captured`, empty when there are none.
    private func conflictReports(_ captured: String) -> [String] {
        captured.components(separatedBy: "\n").filter {
            $0.contains("Unable to simultaneously satisfy constraints") || $0.contains("Conflicting constraints detected")
        }
    }

    /// Runs `body` and fails if AppKit reported a constraint conflict while it ran, naming the constraints.
    private func assertNoConflict(_ moment: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () -> Void) throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] == nil,
                      "AppKit's constraint reports are only written to stderr under xcodebuild (OS_ACTIVITY_DT_MODE)")
        let captured = captureStandardError(body)
        let reports = conflictReports(captured)
        XCTAssertTrue(reports.isEmpty,
                      "\(moment): AppKit reported \(reports.count) constraint conflict(s) and broke a required constraint:\n"
                      + String(captured.prefix(3_000)), file: file, line: line)
    }

    // MARK: - Building and laying out conflicts with nothing

    // Proves that building a detail, selecting a job and laying it out at a normal, a very narrow and a normal width again never makes AppKit break a required constraint.
    func testLayingOutTheDetailAtAnyWidthConflictsNoRequiredConstraint() throws {
        let probe = captureStandardError { fputs("probe\n", stderr) }
        XCTAssertTrue(probe.contains("probe"), "precondition: stderr can be captured")

        // The document's width constraint is built (clip width 0) before any layout; the conflict is reported by the first layout.
        let s = try makeStandalone()
        s.detail.select(s.job)

        try assertNoConflict("the first layout pass") {
            s.detail.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            s.container.addSubview(s.detail)
            s.container.layoutSubtreeIfNeeded()
            MD.pump(s.window)
        }
        try assertNoConflict("narrowing the pane to 60 pt") { s.resize(width: 60) }
        try assertNoConflict("narrowing the pane to 40 pt") { s.resize(width: 40) }
        try assertNoConflict("widening the pane to 600 pt again") { s.resize(width: 600) }
    }

    // Proves that the document's width follows the clip through a constraint the content's own required constraints can override.
    func testTheDocumentsWidthConstraintIsNotRequired() throws {
        let s = try makeStandalone()
        let doc = try document(s.detail)

        func widthConstraints() -> [NSLayoutConstraint] {
            doc.constraints.filter { $0.firstItem === doc && $0.firstAttribute == .width && $0.secondItem == nil }
        }

        let before = widthConstraints()
        XCTAssertFalse(before.isEmpty, "precondition: the document has a constant-width constraint")
        for c in before {
            XCTAssertLessThan(c.priority.rawValue, NSLayoutConstraint.Priority.required.rawValue,
                              "the document's width constraint is required (priority \(c.priority.rawValue)), so a clip narrower than the content makes AppKit break one of the content's own constraints: \(c)")
        }

        s.detail.select(s.job)
        s.resize(width: 600)
        s.resize(width: 40)
        let after = widthConstraints()
        XCTAssertFalse(after.isEmpty, "the document's width constraint is still there after layout at 600 and 40 pt")
        for c in after {
            XCTAssertLessThan(c.priority.rawValue, NSLayoutConstraint.Priority.required.rawValue,
                              "after layout the document's width constraint is required (priority \(c.priority.rawValue)): \(c)")
        }
    }

    // MARK: - A clip narrower than the content's minimum

    private func widthState(_ detail: MotherJobDetail, _ doc: DetailDocumentView) -> String {
        let sv = detail.contentScrollView
        return "document \(doc.frame.width) wide, clip \(sv.contentView.bounds.width) wide, scroll view \(sv.frame.width) wide, "
            + "scroller style \(sv.scrollerStyle == .legacy ? "legacy" : "overlay"), layouts so far \(doc.layoutCount)"
    }

    // Proves that when the content needs more room than the clip has, the content keeps its minimum (a required constraint of its own), nothing conflicts, and layout settles instead of asking for itself again and again.
    func testAClipNarrowerThanTheContentsMinimumLeavesTheContentIntactAndTheDetailSettles() throws {
        let s = try makeStandalone()
        let detail = s.detail
        detail.select(s.job)
        let doc = try document(detail)
        let clip = detail.contentScrollView.contentView

        // The content's minimum width: a required constraint of its own, wider than the clip below.
        let minimum: CGFloat = 500
        doc.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum).isActive = true

        var layoutsBefore = 0
        var layoutsAfterSettling = 0
        try assertNoConflict("laying out a 300 pt pane whose content needs \(Int(minimum)) pt") {
            layoutsBefore = doc.layoutCount
            s.resize(width: 300, height: 400, seconds: 0.4)
            MD.drainMainQueue()
            MD.pump(s.window, seconds: 0.4)
            layoutsAfterSettling = doc.layoutCount
        }

        let state = widthState(detail, doc)
        XCTAssertLessThan(clip.bounds.width, minimum, "precondition: the clip is narrower than the content's minimum (\(state))")
        XCTAssertGreaterThanOrEqual(doc.frame.width, minimum - 0.5, "the content was squeezed below its minimum (\(state))")
        XCTAssertLessThanOrEqual(layoutsAfterSettling - layoutsBefore, 30,
                                 "settling a narrow clip took \(layoutsAfterSettling - layoutsBefore) layouts of the document (\(state))")

        // Nothing changes from here on: nothing may keep laying the document out.
        MD.pump(s.window, seconds: 0.4)
        let quiet = doc.layoutCount - layoutsAfterSettling
        XCTAssertLessThanOrEqual(quiet, 2,
                                 "with nothing changing, the document was laid out \(quiet) more times in 0.4 s: layout is not settling (\(widthState(detail, doc)))")

        // And the detail is not stuck at that width: given room again, the document is the width of its clip.
        s.resize(width: 800, height: 400, seconds: 0.1)
        let tracked = MD.pumpUntil(s.window, timeout: 5) { abs(doc.frame.width - clip.bounds.width) < 1 }
        XCTAssertTrue(tracked, "after widening the pane the document did not follow its clip (\(widthState(detail, doc)))")
    }
}
