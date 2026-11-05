import XCTest
import AppKit
import NostromoKit

// The Overview's document is as wide as its clip, and that is a preference, not a law: the document's own
// required constraints (its 16 pt margins, the stacks and labels inside it) must never be the casualty.
//
// What the reader cares about, and what these tests hold the line on:
//   - Building a job detail and laying it out at any width breaks none of its constraints (AppKit logs
//     "Unable to simultaneously satisfy constraints" and silently deactivates one of them when a required
//     constraint cannot be met).
//   - A clip narrower than the content can ever be leaves the content intact (it is not squeezed past its
//     margins) and the detail settles: it does not keep laying itself out forever.
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

    // MARK: - Watching the constraints

    /// Every constraint the detail's subtree holds at some moment, kept so that a later `isActive == false`
    /// (what AppKit does to the one it breaks) can be named. Only plain `NSLayoutConstraint`s: AppKit's own
    /// internal ones (autoresizing, intrinsic size) are not the app's and come and go by themselves.
    private struct Watch {
        private(set) var entries: [(moment: String, constraint: NSLayoutConstraint)] = []
        private var seen = Set<ObjectIdentifier>()

        var count: Int { entries.count }

        mutating func record(_ detail: NSView, moment: String) {
            for view in [detail] + MD.allSubviews(detail) {
                for c in view.constraints where type(of: c) == NSLayoutConstraint.self {
                    if seen.insert(ObjectIdentifier(c)).inserted { entries.append((moment, c)) }
                }
            }
        }

        /// What the app itself switched off between two recordings (it does, on purpose, for a few) is not a
        /// break: forget it.
        mutating func forgetWhatIsNoLongerActive() {
            entries = entries.filter { $0.constraint.isActive }
            seen = Set(entries.map { ObjectIdentifier($0.constraint) })
        }

        /// The recorded constraints that are no longer active although everything they connect is still in the detail.
        func broken(in detail: NSView) -> [(moment: String, constraint: NSLayoutConstraint)] {
            entries.filter { entry in
                guard !entry.constraint.isActive else { return false }
                let views = [entry.constraint.firstItem, entry.constraint.secondItem].compactMap { $0 as? NSView }
                return views.allSatisfy { $0 === detail || $0.isDescendant(of: detail) }
            }
        }
    }

    private func assertNothingBroke(_ watch: Watch, in detail: NSView, _ moment: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let broken = watch.broken(in: detail)
        XCTAssertTrue(broken.isEmpty,
                      "\(moment): AppKit broke \(broken.count) of the \(watch.count) constraints the detail held before any layout:"
                      + broken.map { "\n  (recorded \($0.moment)) \($0.constraint)" }.joined(),
                      file: file, line: line)
    }

    // MARK: - Building and laying out breaks nothing

    // Proves that creating a detail, selecting a job and laying it out at a normal, a very narrow and a normal width again breaks none of its required constraints.
    func testBuildingSelectingAndLayingOutTheDetailAtAnyWidthBreaksNoneOfItsConstraints() throws {
        let s = try makeStandalone()
        var watch = Watch()

        watch.record(s.detail, moment: "right after init")
        s.detail.select(s.job)
        watch.forgetWhatIsNoLongerActive()
        watch.record(s.detail, moment: "after select, before any layout pass")
        XCTAssertGreaterThan(watch.count, 20, "precondition: the detail holds its constraints before it is laid out")
        assertNothingBroke(watch, in: s.detail, "after select, before any layout")

        // The first layout pass: the document's width constraint was built before the clip had a width.
        s.detail.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.container.addSubview(s.detail)
        s.container.layoutSubtreeIfNeeded()
        assertNothingBroke(watch, in: s.detail, "after the first layout pass (600 wide)")

        MD.pump(s.window)
        assertNothingBroke(watch, in: s.detail, "after the run loop has settled (600 wide)")

        s.resize(width: 40)
        assertNothingBroke(watch, in: s.detail, "after the pane is narrowed to 40 pt")

        s.resize(width: 600)
        assertNothingBroke(watch, in: s.detail, "after the pane is widened to 600 pt again")

        s.resize(width: 300)
        assertNothingBroke(watch, in: s.detail, "after the pane is resized to 300 pt")
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
                              "the document's width constraint is required (priority \(c.priority.rawValue)), so a clip narrower than the content breaks one of the content's own constraints: \(c)")
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

    // Proves that when the clip is narrower than the content's required margins the content is left intact, nothing breaks, and layout settles instead of repeating.
    func testAClipNarrowerThanTheContentCanBeLeavesItIntactAndTheDetailSettles() throws {
        let s = try makeStandalone()
        let detail = s.detail
        // A legacy scroller takes its width out of the clip (as on a runner with no trackpad), and a pane this
        // short makes the Overview scroll, so the clip is narrower still than the pane: below the 32 pt the
        // document's two margins alone need.
        detail.contentScrollView.scrollerStyle = .legacy
        var watch = Watch()
        watch.record(detail, moment: "right after init")
        detail.select(s.job)
        watch.forgetWhatIsNoLongerActive()
        watch.record(detail, moment: "after select, before any layout pass")
        let doc = try document(detail)
        let clip = detail.contentScrollView.contentView

        let layoutsBefore = doc.layoutCount
        s.detail.frame = NSRect(x: 0, y: 0, width: 40, height: 260)
        s.container.addSubview(detail)
        s.container.layoutSubtreeIfNeeded()
        MD.pump(s.window, seconds: 0.4)
        MD.drainMainQueue()
        MD.pump(s.window, seconds: 0.4)
        let layoutsAfterSettling = doc.layoutCount

        let state = widthState(detail, doc)
        XCTAssertFalse(detail.contentScrollView.verticalScroller?.isHidden ?? true,
                       "precondition: the legacy vertical scroller is showing, so the clip is narrower than the pane (\(state))")
        XCTAssertGreaterThan(doc.frame.width, clip.bounds.width + 0.5,
                             "precondition: the content cannot be as narrow as the clip (\(state))")
        XCTAssertGreaterThanOrEqual(doc.frame.width, clip.bounds.width - 0.5,
                                    "the document is narrower than its clip (\(state))")
        assertNothingBroke(watch, in: detail, "with a clip narrower than the content (\(state))")
        XCTAssertLessThanOrEqual(layoutsAfterSettling - layoutsBefore, 30,
                                 "settling a narrow clip took \(layoutsAfterSettling - layoutsBefore) layouts of the document (\(state))")

        // Nothing changes from here on: nothing may keep laying the document out.
        MD.pump(s.window, seconds: 0.4)
        let quiet = doc.layoutCount - layoutsAfterSettling
        XCTAssertLessThanOrEqual(quiet, 2,
                                 "with nothing changing, the document was laid out \(quiet) more times in 0.4 s: layout is not settling (\(widthState(detail, doc)))")

        // And the detail is not stuck at that width: given room again, the document is the width of its clip.
        s.resize(width: 600, height: 400, seconds: 0.1)
        let tracked = MD.pumpUntil(s.window, timeout: 5) { abs(doc.frame.width - clip.bounds.width) < 1 }
        XCTAssertTrue(tracked, "after widening the pane the document did not follow its clip (\(widthState(detail, doc)))")
        assertNothingBroke(watch, in: detail, "after the pane is widened again")
    }
}
