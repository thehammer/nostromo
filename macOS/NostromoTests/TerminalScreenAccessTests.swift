import XCTest
import AppKit

// A terminal's screen is private to the person at the keyboard. An agent may read it only through
// `nostromo_read_terminal_screen`, which follows the terminal and redacts. App-control's `tree`,
// `find` and `ax` commands read accessibility labels, titles and VALUES (`AppControlAX`), so a
// terminal view whose `accessibilityValue` returned its screen would hand that screen to any agent
// with the app-control socket, bypassing follow and redaction.
//
// `TerminalScreenAccess.accessibilityValue` is the gate: the real app returns nil; a QA build that
// relaxes the synthetic-input gate (`allowsSynthetic`) returns the text so `terminal-local.sh` can
// read it. The real view is SwiftTerm-backed and cannot be built here, so these tests use a stand-in
// view with the same accessibility shape (class name, role, label) that answers `accessibilityValue`
// through the gate exactly as `NostromoTerminalView` does, and read it with the same code app-control
// uses (`AppControlAX.dump`, `AppControlAX.hits`). A source-policy test in TerminalFitnessTests pins
// that the real view goes through the gate.
//
// Every "hidden" check has a "shown" mirror with the gate relaxed, so a hidden screen proves the gate
// is what hides it and not a broken probe.

/// Stands in for `NostromoTerminalView`: a terminal-shaped accessibility element whose value is the
/// screen text, but only as the gate allows.
final class ScreenAccessStandInTerminalView: NSView {
    let canary: String
    var gateAllowsSynthetic: Bool
    /// How many times the screen text was actually produced.
    private(set) var screenTextReads = 0
    /// Where the element is, in screen coordinates (what `accessibilityFrame` reports).
    var screenFrame = NSRect(x: 0, y: 0, width: 100, height: 50)

    init(canary: String, gateAllowsSynthetic: Bool) {
        self.canary = canary
        self.gateAllowsSynthetic = gateAllowsSynthetic
        super.init(frame: NSRect(x: 10, y: 10, width: 100, height: 50))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityFrame() -> NSRect { screenFrame }

    override func accessibilityValue() -> Any? {
        TerminalScreenAccess.accessibilityValue(screenText: {
            self.screenTextReads += 1
            return self.canary
        }, allowsSynthetic: { self.gateAllowsSynthetic })
    }
}

/// A plain view that reports `kids` as its accessibility children, like a hosting view reporting what
/// it draws.
final class ScreenAccessContainerView: NSView {
    var kids: [Any] = []
    override func accessibilityChildren() -> [Any]? { kids }
}

final class TerminalScreenAccessTests: XCTestCase {

    private let canary = "CANARY-SCREEN-7c2e91d4-secret-token"

    private struct Fixture {
        let window: NSWindow
        let container: ScreenAccessContainerView
        let terminal: ScreenAccessStandInTerminalView
    }

    /// A terminal stand-in inside a container inside an offscreen window, with a nonzero screen frame.
    private func fixture(gateAllowsSynthetic: Bool) -> Fixture {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let container = ScreenAccessContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView!.addSubview(container)
        let terminal = ScreenAccessStandInTerminalView(canary: canary, gateAllowsSynthetic: gateAllowsSynthetic)
        container.addSubview(terminal)
        terminal.screenFrame = NSRect(x: window.frame.minX + 10, y: window.frame.minY + 10, width: 100, height: 50)
        container.kids = [terminal]
        return Fixture(window: window, container: container, terminal: terminal)
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The gate

    func testWithTheGateOffTheScreenIsNeitherReturnedNorReadAtAll() {
        var read = false

        let value = TerminalScreenAccess.accessibilityValue(screenText: { read = true; return canary },
                                                            allowsSynthetic: { false })

        XCTAssertNil(value)
        XCTAssertFalse(read, "the screen text must not even be produced when it will not be shown")
    }

    func testWithTheGateRelaxedTheScreenIsReturned() {
        XCTAssertEqual(TerminalScreenAccess.accessibilityValue(screenText: { canary }, allowsSynthetic: { true }), canary)
    }

    func testTheGateIsAskedEveryTimeNotRememberedFromTheFirstAnswer() {
        var allowed = false
        XCTAssertNil(TerminalScreenAccess.accessibilityValue(screenText: { canary }, allowsSynthetic: { allowed }))
        allowed = true
        XCTAssertEqual(TerminalScreenAccess.accessibilityValue(screenText: { canary }, allowsSynthetic: { allowed }), canary)
        allowed = false
        XCTAssertNil(TerminalScreenAccess.accessibilityValue(screenText: { canary }, allowsSynthetic: { allowed }))
    }

    func testAnEmptyScreenIsAnEmptyStringNotNilWhenTheGateIsRelaxed() {
        XCTAssertEqual(TerminalScreenAccess.accessibilityValue(screenText: { "" }, allowsSynthetic: { true }), "")
    }

    // MARK: - What `ax` prints

    func testTheAxDumpOfATerminalShowsItsShapeButNoValueAndNoScreenWhenTheGateIsOff() throws {
        let f = fixture(gateAllowsSynthetic: false)

        let dump = AppControlAX.dump(f.terminal, 0)
        let text = try json(dump)

        XCTAssertEqual(dump["label"] as? String, "Terminal", "the dump must see the element: \(text)")
        XCTAssertEqual(dump["role"] as? String, NSAccessibility.Role.textArea.rawValue)
        XCTAssertTrue((dump["type"] as? String)?.contains("TerminalView") == true, text)
        XCTAssertNil(dump["value"], "a terminal has no accessibility value in the real app: \(text)")
        XCTAssertFalse(text.contains(canary), "the screen leaked into the ax dump: \(text)")
        XCTAssertFalse(text.contains("\"value\""), text)
        XCTAssertEqual(f.terminal.screenTextReads, 0, "the screen was read for nothing")
    }

    func testTheAxDumpOfAParentAlsoHidesTheScreenOfItsTerminalChild() throws {
        let f = fixture(gateAllowsSynthetic: false)

        let text = try json(AppControlAX.dump(f.container, 0))

        XCTAssertTrue(text.contains("\"label\":\"Terminal\""), "the child terminal should be in the dump: \(text)")
        XCTAssertFalse(text.contains(canary), "the screen leaked through a parent's dump: \(text)")
        XCTAssertFalse(text.contains("\"value\""), text)
    }

    func testTheAxDumpShowsTheScreenWhenTheBuildRelaxesTheGate() throws {
        let f = fixture(gateAllowsSynthetic: true)

        let dump = AppControlAX.dump(f.terminal, 0)

        XCTAssertEqual(dump["value"] as? String, canary, "the probe must be able to see the screen when the gate allows it")
        XCTAssertTrue(try json(dump).contains(canary))
    }

    // MARK: - What `tree` and `find` see

    func testTheAccessibilityHitsFindTheTerminalButNeverItsScreenWhenTheGateIsOff() {
        let f = fixture(gateAllowsSynthetic: false)

        let hits = AppControlAX.hits(under: f.container, in: f.window)

        let terminalHit = hits.first { $0.text?.contains("Terminal") == true }
        XCTAssertNotNil(terminalHit, "the terminal's label should be findable: \(hits)")
        XCTAssertEqual(terminalHit?.cls, "ax:" + NSAccessibility.Role.textArea.rawValue)
        XCTAssertGreaterThan(terminalHit?.rectInWindow.width ?? 0, 0)
        for hit in hits {
            XCTAssertFalse(hit.text?.contains(canary) ?? false, "the screen leaked into a find/tree hit: \(hit)")
        }
        XCTAssertEqual(f.terminal.screenTextReads, 0)
    }

    func testFindingTheCanaryTextFindsNothingWhenTheGateIsOff() {
        let f = fixture(gateAllowsSynthetic: false)
        let needle = canary.lowercased()

        let found = AppControlAX.hits(under: f.container, in: f.window)
            .filter { $0.text?.lowercased().contains(needle) == true }

        XCTAssertTrue(found.isEmpty, "app-control `find` located terminal screen text: \(found)")
    }

    func testTheAccessibilityHitsShowTheScreenWhenTheBuildRelaxesTheGate() {
        let f = fixture(gateAllowsSynthetic: true)

        let hits = AppControlAX.hits(under: f.container, in: f.window)

        XCTAssertTrue(hits.contains { $0.text?.contains(canary) == true },
                      "the probe must be able to see the screen when the gate allows it: \(hits)")
    }

    // MARK: - AppControlAX.value

    func testValueReadsAPropertyByItsGetterNameAndIsNilForAnUnknownOne() {
        let f = fixture(gateAllowsSynthetic: false)
        XCTAssertEqual(AppControlAX.value(f.terminal, "accessibilityLabel") as? String, "Terminal")
        XCTAssertNil(AppControlAX.value(f.terminal, "accessibilityValue"), "the gate answers nil")
        XCTAssertNil(AppControlAX.value(f.terminal, "noSuchAccessibilityProperty"))
    }
    // MARK: - The staged-commands drawer (what an agent staged for a person is read on screen only)

    // The drawer's rows speak their command and note to VoiceOver, so app-control's accessibility walk
    // (`tree`, `find`, `ax`) would read them as well. In the real app (`allowsSynthetic` false) it reads one
    // fixed entry for the whole drawer and nothing below it, whether it starts above the drawer or inside it.

    private let stagedCanary = "CANARY-STAGED-5a8c13"

    private struct StagedFixture {
        let rig: StagingRig
        let host: StagingDrawerHost
        let container: ScreenAccessContainerView
    }

    private func stagedFixture(reportingRowsAsKids: Bool) -> StagedFixture {
        let rig = StagingRig()
        let host = StagingDrawerHost(rig: rig, width: 400, bodyHeight: 400)
        addTeardownBlock {
            host.tearDown()
            rig.tearDown()
        }
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo \(stagedCanary)", note: "note \(stagedCanary)"),
                    StagingFixtures.entry("s-2", 2, "pwd")])
        rig.settle()
        host.drawer.refresh()
        let container = ScreenAccessContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.window.contentView!.addSubview(container)
        if reportingRowsAsKids {
            container.kids = host.rows
        } else {
            container.kids = [host.drawer]
        }
        return StagedFixture(rig: rig, host: host, container: container)
    }

    func testTheStagedDrawerIsOneFixedEntryInTheRealAppsAccessibilityHits() {
        let f = stagedFixture(reportingRowsAsKids: false)

        let hits = AppControlAX.hits(under: f.container, in: f.host.window, allowsSynthetic: false)

        XCTAssertEqual(hits.count, 1, "\(hits)")
        XCTAssertEqual(hits.first?.text, AppControlAX.stagedHiddenText)
        XCTAssertEqual(hits.first?.cls, "ax:" + NSAccessibility.Role.group.rawValue)
        XCTAssertGreaterThan(hits.first?.rectInWindow.width ?? 0, 0)
        for hit in hits { XCTAssertFalse(hit.text?.contains(stagedCanary) ?? false, "\(hit)") }
        XCTAssertEqual(AppControlAX.stagedHiddenText, "staged commands hidden from app-control")
    }

    func testTheStagedDrawerStaysOneFixedEntryWhenTheWalkStartsInsideIt() throws {
        let f = stagedFixture(reportingRowsAsKids: false)
        let row = try XCTUnwrap(f.host.rows.first)
        let label = try XCTUnwrap(f.host.textFields.first { $0.stringValue.contains(stagedCanary) })

        for start in [row, label, f.host.drawer] as [NSView] {
            let hits = AppControlAX.hits(under: start, in: f.host.window, allowsSynthetic: false)
            XCTAssertEqual(hits.map { $0.text }, [AppControlAX.stagedHiddenText], "from \(type(of: start))")
        }
    }

    func testTheStagedRowsAreNotFoundByTheirTextInTheRealApp() {
        let f = stagedFixture(reportingRowsAsKids: true)
        let needle = stagedCanary.lowercased()

        let hits = AppControlAX.hits(under: f.container, in: f.host.window, allowsSynthetic: false)

        XCTAssertTrue(hits.filter { $0.text?.lowercased().contains(needle) == true }.isEmpty, "app-control `find` located staged text: \(hits)")
        XCTAssertFalse(hits.contains { $0.text?.contains("Staged command") == true }, "\(hits)")
    }

    func testTheAxDumpOfTheStagedDrawerIsOneFixedNodeWithNoChildren() throws {
        let f = stagedFixture(reportingRowsAsKids: false)

        let dump = AppControlAX.dump(f.host.drawer, 0, allowsSynthetic: false)

        XCTAssertEqual(dump["label"] as? String, AppControlAX.stagedHiddenText)
        XCTAssertEqual(dump["type"] as? String, "StagingDrawerView")
        XCTAssertEqual(dump["role"] as? String, NSAccessibility.Role.group.rawValue)
        XCTAssertNil(dump["children"], "nothing below the drawer is read")
        XCTAssertNil(dump["value"])
        XCTAssertFalse(try json(dump).contains(stagedCanary))

        let parent = try json(AppControlAX.dump(f.container, 0, allowsSynthetic: false))
        XCTAssertFalse(parent.contains(stagedCanary), "a parent's dump does not read it either: \(parent)")
        XCTAssertTrue(parent.contains(AppControlAX.stagedHiddenText), parent)
        XCTAssertFalse(try json(AppControlAX.dump(try XCTUnwrap(f.host.rows.first), 0, allowsSynthetic: false)).contains(stagedCanary),
                       "a dump that starts at a row")
    }

    func testTheStagedRowsAreReadableWhenTheBuildRelaxesTheGate() throws {
        let f = stagedFixture(reportingRowsAsKids: true)

        let hits = AppControlAX.hits(under: f.container, in: f.host.window, allowsSynthetic: true)
        XCTAssertTrue(hits.contains { $0.text?.contains(stagedCanary) == true }, "the probe must see the rows when the gate allows it: \(hits)")
        XCTAssertFalse(hits.contains { $0.text == AppControlAX.stagedHiddenText })

        let dump = try json(AppControlAX.dump(f.container, 0, allowsSynthetic: true))
        XCTAssertTrue(dump.contains(stagedCanary), dump)

        let g = stagedFixture(reportingRowsAsKids: false)
        let drawerHits = AppControlAX.hits(under: g.container, in: g.host.window, allowsSynthetic: true)
        XCTAssertFalse(drawerHits.contains { $0.text == AppControlAX.stagedHiddenText }, "\(drawerHits)")
    }

    func testIsWithheldIsTrueForTheDrawerAndEverythingInsideItOnlyInTheRealApp() throws {
        let f = stagedFixture(reportingRowsAsKids: false)
        let inside: [NSView] = [f.host.drawer] + f.host.allViews
        XCTAssertGreaterThan(inside.count, 10)

        for view in inside {
            XCTAssertTrue(AppControlAX.isWithheld(view, allowsSynthetic: false), "\(type(of: view))")
            XCTAssertFalse(AppControlAX.isWithheld(view, allowsSynthetic: true), "\(type(of: view)) in the QA build")
        }
        XCTAssertFalse(AppControlAX.isWithheld(f.container, allowsSynthetic: false), "a view beside the drawer")
        XCTAssertFalse(AppControlAX.isWithheld(f.host.container, allowsSynthetic: false), "the pane around the drawer")
        XCTAssertFalse(AppControlAX.isWithheld(NSView(), allowsSynthetic: false))
    }
}
