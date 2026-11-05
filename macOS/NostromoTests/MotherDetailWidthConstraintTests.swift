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


    // Diagnostic on main (scratch, never merged): lays the detail out at several widths and writes a marker to
    // stderr before each, so the loop log shows which widths make AppKit break a constraint on the ORIGINAL code.
    func testDiagnosticNarrowWidthsOnMain() throws {
        let s = try makeStandalone()
        s.detail.select(s.job)
        s.detail.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.container.addSubview(s.detail)
        for w: CGFloat in [600, 600, 320, 60, 40, 0, 600] {
            fputs("DIAG-BEGIN width=\(Int(w))\n", stderr)
            s.resize(width: w)
            fputs("DIAG-END width=\(Int(w))\n", stderr)
        }
    }
}
