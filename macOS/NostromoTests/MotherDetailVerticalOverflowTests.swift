import XCTest
import AppKit
import NostromoKit

// MV-1: a Mother job's content comes from data, and however much of it there is, the job detail
// must not make `MainLayout` taller than a window that cannot grow (a full-screen window).
//
// Measured: in a 1920 x 1080 window with a job showing, `MainLayout.contentOverflow` was
// {w: 0, h: 28} and its frame 1108 tall. The detail's labels wrap with no line cap and have no
// vertical give, and nothing scrolls, so the detail demanded the full height of its content up the
// chain MainLayout > split > MotherView > TabRegionView > MotherJobDetail.
//
// The REAL detail is a tab of the REAL Mother pane inside the real `MainLayout` (Mother focus) in a
// fixed 1920 x 1080 window (MotherDetailHarness). A failure prints the frame and fitting size of every
// level between `MainLayout` and the detail, and of the detail's own children and stacks.
final class MotherDetailVerticalOverflowTests: XCTestCase {

    // MARK: - Control

    func testShortContentFitsTheWindowAndTheDetailIsActuallyLaidOut() throws {
        let rig = try MD.makeRig(self, long: [], index: 900)
        MD.assertFits(rig, "short content")

        XCTAssertEqual(rig.detail.currentJobId, rig.jobId, "control: the detail shows the job")
        XCTAssertGreaterThan(rig.detail.frame.width, 100, "control: the detail is laid out in the pane (width)")
        XCTAssertGreaterThan(rig.detail.frame.height, 300, "control: the detail is laid out in the pane (height)")
        XCTAssertNotNil(rig.detail.actionStack, "control: the held job's options are on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "PLAN-"), 3, "control: the plan checklist is on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 2, "control: the todo list is on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "CONSEQ-"), MDFixtures.optionCount, "control: the option consequences are on screen")
    }

    // MARK: - All at once

    /// A 200-item plan, 60 todos, a decision question and three option consequences of 2,000 characters
    /// each (with spaces), long meta values, a long action error, 40 gates, 25 lens rows and a log tail.
    func testEveryFieldLongAtOnceFitsTheWindow() throws {
        let rig = try MD.makeRig(self, long: Set(MDField.allCases), index: 901)

        XCTAssertEqual(rig.renderedCount(prefix: "PLAN-"), 200, "precondition: the whole plan is on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "precondition: every todo is on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "CONSEQ-"), MDFixtures.optionCount, "precondition: every consequence is on screen")
        XCTAssertGreaterThan(rig.detail.crewSection.expectedHeight, 800, "precondition: the crew panel is tall")
        MD.assertFits(rig, "every field long")
    }

    // MARK: - One field at a time

    func testEachFieldLongOnItsOwnFitsTheWindow() throws {
        var index = 910
        for field in MDField.allCases {
            let rig = try MD.makeRig(self, long: [field], index: index)
            index += 1
            MD.assertFits(rig, "only \(field.rawValue) long")
            rig.close()
        }
    }

    // MARK: - Content that arrives after the first layout

    /// One live window and one live detail, laid out with short content; then each kind of data
    /// arrives long, one after the other, with the window measured after each.
    func testContentThatGrowsAfterTheFirstLayoutKeepsFittingStageByStage() throws {
        let rig = try MD.makeRig(self, long: [], index: 920)
        MD.assertFits(rig, "before anything grows")

        let stages: [(String, Set<MDField>)] = [
            ("plan checklist grows to 200 items", [.planChecklist]),
            ("todos grow to 60 (a new peek payload)", [.todos]),
            ("log tail grows to 200 entries", [.log]),
            ("gates grow to 40 long-named rows", [.gates]),
            ("review wave grows to 25 lens rows", [.lenses]),
            ("decision question grows to 2,000 characters", [.question]),
            ("option consequences grow to 2,000 characters each", [.consequences]),
            ("meta values grow to 2,000 characters", [.meta]),
            ("title grows to 2,000 characters", [.title]),
            ("an action error of 2,000 characters arrives", [.actionError]),
        ]
        for (name, fields) in stages {
            try rig.grow(fields)
            MD.assertFits(rig, "after: \(name)")
        }
        XCTAssertEqual(rig.renderedCount(prefix: "PLAN-"), 200, "the plan is still on screen at the end")
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "the todos are still on screen at the end")
    }

    func testEverythingGrowingAtOnceAfterTheFirstLayoutKeepsFitting() throws {
        let rig = try MD.makeRig(self, long: [], index: 921)
        MD.assertFits(rig, "before anything grows")

        try rig.grow(Set(MDField.allCases))
        MD.assertFits(rig, "after everything grew at once")
        XCTAssertEqual(rig.renderedCount(prefix: "PLAN-"), 200, "the plan is on screen")
        XCTAssertEqual(rig.renderedCount(prefix: "TODO-"), 60, "the todos are on screen")
    }

    /// A state change rebuilds the actions and the todo list while the heavy content is already there.
    func testAJobThatChangesStateWhileHeavyKeepsFitting() throws {
        let rig = try MD.makeRig(self, long: Set(MDField.allCases), index: 922)
        MD.assertFits(rig, "awaiting, every field long")
        for state in ["running", "awaiting", "failed", "succeeded"] {
            rig.setState(state)
            rig.awaitRendered()
            MD.assertFits(rig, "state -> \(state), every field long")
        }
    }
}
