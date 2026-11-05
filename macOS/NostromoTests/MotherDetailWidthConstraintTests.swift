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
// Which widths are held to "no conflict": the Mother view's real minimum for the detail pane,
// `MotherListWidth.detailMinimum` (320 pt: the divider never leaves the detail narrower), and wider. Below
// it, the detail's OWN required insets (16 + 16 around the log scroll view, whose legacy scroller is 17 pt)
// cannot fit by themselves, with or without the document's width constraint, so AppKit reports a conflict on
// the log scroll view at 40 pt on the original code too (docs/ci.md, .claude/todos). The tests below 320 pt
// therefore check termination and that the width constraint of THIS fix is not the one in the report.
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

    /// AppKit's constraint reports reach stderr only when the process runs under xcodebuild, which sets this.
    private var canReadConstraintReports: Bool { ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] != nil }

    /// CI must never skip the conflict assertions: a skip there is a silent loss of the test.
    private var runsInCI: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
    }

    /// Set when a conflict assertion could not be made; `finishConflictChecks` then skips (outside CI) at the END
    /// of the test, so that the assertions that do not need the report still ran.
    private var conflictCheckUnavailable = false

    /// Runs `body` and returns AppKit's conflict reports from while it ran; `nil` when they cannot be read here
    /// (the body ran regardless). Under CI that is a failure, not a skip.
    private func conflictReportsDuring(_ moment: String, file: StaticString = #filePath, line: UInt = #line,
                                       _ body: () -> Void) -> (reports: [String], captured: String)? {
        guard canReadConstraintReports else {
            body()
            conflictCheckUnavailable = true
            if runsInCI {
                XCTFail("\(moment): AppKit's constraint reports cannot be read here (OS_ACTIVITY_DT_MODE is not set) under CI, "
                        + "so the conflict assertions did not run; they must never be skipped in CI", file: file, line: line)
            }
            return nil
        }
        let captured = captureStandardError(body)
        return (conflictReports(captured), captured)
    }

    /// Runs `body` and fails if AppKit reported a constraint conflict while it ran, naming the constraints.
    private func assertNoConflict(_ moment: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () -> Void) {
        guard let result = conflictReportsDuring(moment, file: file, line: line, body) else { return }
        XCTAssertTrue(result.reports.isEmpty,
                      "\(moment): AppKit reported \(result.reports.count) constraint conflict(s) and broke a required constraint:\n"
                      + String(result.captured.prefix(3_000)), file: file, line: line)
    }

    /// Call at the end of a test that used the conflict assertions: outside CI, skips when they could not be made.
    private func finishConflictChecks() throws {
        try XCTSkipIf(conflictCheckUnavailable && !runsInCI,
                      "AppKit's constraint reports are only written to stderr under xcodebuild (OS_ACTIVITY_DT_MODE); the other assertions ran")
    }

    // Diagnostic on main (scratch, never merged): same two tests as the scratch of the fixed code.
    private func diagnose(_ name: String, _ widths: [CGFloat]) throws {
        let s = try makeStandalone()
        s.detail.select(s.job)
        s.detail.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.container.addSubview(s.detail)
        for w in widths {
            let captured = captureStandardError { s.resize(width: w) }
            let broken = captured.components(separatedBy: "\n").filter { $0.hasPrefix("Will attempt to recover by breaking <") }
            XCTFail("DIAG \(name) width=\(Int(w)) conflicts=\(conflictReports(captured).count) broken=\(broken.map { String($0.prefix(200)) })")
        }
    }

    func testDiagnosticA() throws { try diagnose("A", [600, 320, 60, 40, 0, 600]) }
    func testDiagnosticB() throws { try diagnose("B", [600, 60, 40]) }
}
