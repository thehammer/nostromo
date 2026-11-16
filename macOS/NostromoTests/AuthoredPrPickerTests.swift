import XCTest
import AppKit
import NostromoKit

// "Choose focus…": the picker for a PR the daemon could not give one owner, and Unlink.
//
// Contract.
//  * An ambiguous PR lists its open candidates, each with how it was found (Mother job a1b2c3, On branch,
//    Linked); an unknown one lists every open focus, those named for the PR's repo first. The last entry is
//    always "Start a session…". Nothing is preselected.
//  * A choice (by a person's gesture) links the PR to that focus and, once the daemon says ok, opens the
//    preview for that focus. "Start a session…" opens the sheet. Esc cancels. A failed link keeps the picker
//    open with its words.
//  * Unlink is in the Overview's context menu for a linked owner only, and sends a link with no tag.
//  * SP4: a choice and Unlink do nothing for app-control input, an Accessibility press or a stale event.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 the picker preselects the first entry                         -> testNothingIsPreselected
//   M2 the ambiguous picker offers a closed or not-open candidate     -> testAnAmbiguousPrListsItsOpenCandidatesWithHowEachWasFound
//   M3 the unknown picker keeps the focuses in store order            -> testAnUnknownOwnerListsTheRepoNamedFocusesFirst
//   M4 a choice previews before the link is acknowledged              -> testAChoiceLinksThenOpensThePreviewForThatFocus
//   M5 Unlink offered on a non-linked owner, or sends a tag           -> testUnlinkIsOnlyForLinkedOwnersAndSendsNoTag
//   M6 a choice or Unlink skips `HumanGesture`                        -> testAChoiceDoesNothingForInputThatIsNotAHumanGesture, testUnlinkDoesNothing...
final class AuthoredPrPickerTests: MouseQueueTestCase {

    private var window: NSWindow!
    private var control: NSButton!
    private var rigs: [OverviewRig] = []
    private var outcomes: [AuthoredPrPickerSession.Outcome] = []

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 700))
        control = HF.control(in: window)
        outcomes = []
        AppStore.shared.resetAuthoredPrsForTesting()
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        window.contentView = nil
        window.close()
        window = nil
        AppStore.shared.resetAuthoredPrsForTesting()
        super.tearDown()
    }

    private func entries(_ pr: AuthoredPr, focuses: [AuthoredPrPickerFocus] = HF.openFocuses) -> [AuthoredPrPickerEntry] {
        AuthoredPrsPicker.entries(for: pr, openFocuses: focuses)
    }

    /// A picker over its own recording transport (no hand-off), in the window.
    private func openPicker(_ pr: AuthoredPr, transport: RecordingTransport,
                            permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live)
        -> (session: AuthoredPrPickerSession, vc: AuthoredPrPickerViewController) {
        let session = AuthoredPrPickerSession(row: HF.row(pr), entries: entries(pr), transport: transport, permit: permit)
        session.onFinish = { [weak self] in self?.outcomes.append($0) }
        let vc = AuthoredPrPickerViewController(session: session)
        window.contentView?.addSubview(vc.view)
        return (session, vc)
    }

    private func cellTexts(_ vc: AuthoredPrPickerViewController, row: Int) throws -> [String] {
        let cell = try XCTUnwrap(vc.tableView(vc.table, viewFor: nil, row: row))
        return APT.texts(in: cell).filter { !$0.isEmpty }
    }

    private func titles(_ vc: AuthoredPrPickerViewController) throws -> [[String]] {
        try (0..<vc.numberOfRows(in: vc.table)).map { try cellTexts(vc, row: $0) }
    }

    // MARK: - What it lists

    func testAnAmbiguousPrListsItsOpenCandidatesWithHowEachWasFound() throws {
        let pr = HF.pr(owner: HF.ambiguousOwner())
        let transport = RecordingTransport()
        let (_, vc) = openPicker(pr, transport: transport)

        XCTAssertEqual(try titles(vc), [
            ["Alpha", "Mother job a1b2c3"],
            ["Beta", "On branch"],
            ["Gamma", "Linked"],
            ["Start a session…"],
        ], "the closed candidate (Delta) is not offered; Start a session… is last")
    }

    func testAnUnknownOwnerListsTheRepoNamedFocusesFirstThenTheRestThenStart() throws {
        let pr = HF.pr(owner: .unknown)   // thehammer/nostromo
        let transport = RecordingTransport()
        let (_, vc) = openPicker(pr, transport: transport)

        let names = try titles(vc).map { $0[0] }
        XCTAssertEqual(names, ["Mine", "Other", "Alpha", "Beta", "Gamma", "Start a session…"],
                       "the focus in a folder named nostromo comes first; the rest keep their order")
    }

    func testNothingIsPreselected() throws {
        let pr = HF.pr(owner: HF.ambiguousOwner())
        let (_, vc) = openPicker(pr, transport: RecordingTransport())
        XCTAssertEqual(vc.table.selectedRow, -1, "the person chooses")
        XCTAssertTrue(vc.table.selectedRowIndexes.isEmpty)
    }

    func testReturnWithNothingSelectedChoosesNothing() {
        let transport = RecordingTransport()
        let (_, vc) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        vc.table.keyDown(with: HF.humanReturn(in: window))
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - A choice

    func testAChoiceByKeyboardLinksThePrToThatFocusAndNothingElse() {
        let transport = RecordingTransport()
        let (_, vc) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        vc.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        vc.table.keyDown(with: HF.humanReturn(in: window))

        XCTAssertEqual(transport.calls, [.link(repo: HF.repo, number: 458, tag: "focus-beta")])
        XCTAssertTrue(outcomes.isEmpty, "not finished until the daemon says ok")
    }

    func testAChoiceLinksThenOpensThePreviewForThatFocus() throws {
        let rig = HandoffRig(window: window)
        let model = HF.row(HF.pr(owner: HF.ambiguousOwner()))
        rig.handoff.activate(model, anchor: control, event: HF.human(in: window), control: control)
        let picker = try XCTUnwrap(rig.picker, "the button opens the picker")
        XCTAssertTrue(rig.transport.calls.isEmpty, "nothing is asked before a choice")

        picker.choose(0, event: HF.human(in: window), control: control)   // Alpha
        XCTAssertEqual(rig.transport.calls, [.link(repo: HF.repo, number: 458, tag: "focus-alpha")])
        XCTAssertNotNil(rig.picker, "the picker stays until the link is acknowledged")

        rig.transport.answerLink(.ok(AuthoredPrDone()))

        let preview = try XCTUnwrap(rig.preview, "the preview for that focus follows: \(String(describing: rig.handoff.presented?.kindName))")
        XCTAssertEqual(preview.tag, "focus-alpha")
        XCTAssertEqual(rig.transport.calls.last, .preview(repo: HF.repo, number: 458, target: .focus(tag: "focus-alpha")))
        XCTAssertTrue(rig.transport.notifies.isEmpty, "choosing never sends the message: the preview does, on Send")
    }

    func testAFailedLinkKeepsThePickerOpenWithItsWords() throws {
        let transport = RecordingTransport()
        let (session, vc) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        session.choose(1, event: HF.human(in: window), control: control)

        transport.answerLink(.failed(code: "unknown_focus"))

        XCTAssertTrue(outcomes.isEmpty, "still open")
        XCTAssertEqual(session.note, "Couldn't send: that focus isn't open")
        XCTAssertTrue(APT.texts(in: vc.view).contains("Couldn't send: that focus isn't open"), "and it says so")
        // Try again: a new link goes out.
        session.choose(2, event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.links.count, 2)
    }

    func testNoAnswerToTheLinkKeepsThePickerOpenAndSaysSo() {
        let transport = RecordingTransport()
        let (session, _) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        session.choose(0, event: HF.human(in: window), control: control)
        transport.answerLink(.unreachable)
        XCTAssertEqual(session.note, "Couldn't send: Nostromo isn't reachable")
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testChoosingTwiceBeforeTheAnswerLinksOnce() {
        let transport = RecordingTransport()
        let (session, _) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        session.choose(0, event: HF.human(in: window), control: control)
        session.choose(1, event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.links.count, 1)
    }

    // MARK: - Start a session…

    func testTheStartEntryOpensTheStartSheetAndLinksNothing() throws {
        let rig = HandoffRig(window: window)
        let model = HF.row(HF.pr(owner: HF.ambiguousOwner()))
        rig.handoff.activate(model, anchor: control, event: HF.human(in: window), control: control)
        let picker = try XCTUnwrap(rig.picker)
        let last = picker.entries.count - 1
        XCTAssertEqual(picker.entries[last].kind, .startSession)

        picker.choose(last, event: HF.human(in: window), control: control)

        XCTAssertNotNil(rig.startModel, "the sheet opens")
        XCTAssertTrue(rig.transport.links.isEmpty, "no link")
        XCTAssertEqual(rig.transport.previews.last, .preview(repo: HF.repo, number: 458, target: .newSession))
        XCTAssertTrue(rig.transport.starts.isEmpty && rig.transport.notifies.isEmpty, "and nothing is sent or started")
    }

    // MARK: - Esc

    func testEscapeCancelsAndAsksNothing() {
        let transport = RecordingTransport()
        let (_, vc) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        vc.table.keyDown(with: GestureFixtures.key(in: window))   // Esc

        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testCancellingThePickerUnderAHandOffClosesItAndAsksNothing() throws {
        let rig = HandoffRig(window: window)
        rig.handoff.activate(HF.row(HF.pr(owner: .unknown)), anchor: control, event: HF.human(in: window), control: control)
        try XCTUnwrap(rig.picker).cancel()
        XCTAssertNil(rig.handoff.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: - Unlink

    func testUnlinkIsOnlyForLinkedOwnersAndSendsNoTag() throws {
        let linked = HF.pr(100, owner: HF.linkedOwner())
        let motherOwned = HF.pr(101, owner: HF.motherOwner())
        let onBranch = HF.pr(102, owner: HF.onBranchOwner())
        let unknown = HF.pr(103, owner: .unknown)
        let rig = OverviewRig([linked, motherOwned, onBranch, unknown])
        rigs.append(rig)

        func unlinkItem(_ pr: AuthoredPr) throws -> NSMenuItem? {
            let menu = try XCTUnwrap(rig.overview.contextMenu(forRowId: pr.id), pr.id)
            return menu.items.first { $0.title == "Unlink" }
        }
        XCTAssertNotNil(try unlinkItem(linked), "a linked owner can be unlinked")
        for other in [motherOwned, onBranch, unknown] {
            XCTAssertNil(try unlinkItem(other), "\(other.id): its owner was not linked by the person")
        }

        // Chosen from the menu by a person, it sends a link with no tag.
        rig.rig.allowEverything()   // the menu action reads NSApp.currentEvent, which a test cannot set
        let item = try XCTUnwrap(try unlinkItem(linked))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(rig.transport.calls, [.link(repo: HF.repo, number: 100, tag: nil)])
    }

    func testUnlinkIsNotOfferedWhenTheDaemonCannotHandOff() throws {
        let linked = HF.pr(104, owner: HF.linkedOwner())
        let rig = OverviewRig([linked], handoffAvailable: false)
        rigs.append(rig)
        let menu = try XCTUnwrap(rig.overview.contextMenu(forRowId: linked.id))
        XCTAssertNil(menu.items.first { $0.title == "Unlink" })
        XCTAssertNotNil(menu.items.first { $0.title == "Open on GitHub" }, "the rest of the menu is unchanged")
    }

    func testUnlinkWithAHumanMenuEventSendsALinkWithNoTag() {
        let rig = HandoffRig(window: window)
        rig.handoff.unlink(HF.row(HF.pr(owner: HF.linkedOwner())), event: HF.human(in: window), control: control)
        XCTAssertEqual(rig.transport.calls, [.link(repo: HF.repo, number: 458, tag: nil)])
    }

    func testUnlinkOfAnOwnerThatIsNotLinkedSendsNothing() {
        let rig = HandoffRig(window: window)
        rig.handoff.unlink(HF.row(HF.pr(owner: HF.motherOwner())), event: HF.human(in: window), control: control)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: - SP4

    func testAChoiceDoesNothingForInputThatIsNotAHumanGesture() throws {
        let transport = RecordingTransport()
        let (session, _) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        let startIndex = session.entries.count - 1
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: window)
            session.choose(0, event: event, control: control)
            session.choose(startIndex, event: event, control: control)
            XCTAssertTrue(transport.calls.isEmpty, "\(kind): nothing was linked")
            XCTAssertTrue(outcomes.isEmpty, "\(kind): the picker did not advance")
        }
        session.choose(0, event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.links.count, 1, "a person's choice works: it was the gesture that was refused")
    }

    func testAKeyboardChoiceTypedLongAgoDoesNothing() {
        let transport = RecordingTransport()
        let (_, vc) = openPicker(HF.pr(owner: HF.ambiguousOwner()), transport: transport)
        vc.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        vc.table.keyDown(with: APT.key(APT.keyReturn, "\r", window: window))   // stamped at time zero
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testUnlinkDoesNothingForInputThatIsNotAHumanGesture() throws {
        let rig = HandoffRig(window: window)
        let model = HF.row(HF.pr(owner: HF.linkedOwner()))
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: window)
            rig.handoff.unlink(model, event: event, control: control)
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was unlinked")
        }
    }

    func testTheMenuItemWithNoPersonBehindItUnlinksNothing() throws {
        try HF.skipIfVoiceOver()
        let linked = HF.pr(105, owner: HF.linkedOwner())
        let rig = OverviewRig([linked])
        rigs.append(rig)
        let item = try XCTUnwrap(rig.overview.contextMenu(forRowId: linked.id)?.items.first { $0.title == "Unlink" })
        _ = NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)   // `NSApp.currentEvent`: none, or not a click in this window
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }
}
