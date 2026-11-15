import XCTest
import AppKit
import NostromoKit

// The button on a PR row, and Return on a row: the way into the hand-off.
//
// Contract.
//  * A fixable row (open, not a draft, in Needs you, something to fix) has ONE button when the daemon
//    advertised `authored_prs_notify_v1`: "Tell <first word of the owner>", "Choose focus…" (owner ambiguous or
//    unknown) or "Start a session…" (owner closed). With only `authored_prs_v1` the Overview stays read-only:
//    no button and no "Told …" text.
//  * Pressing it, or Return on the selected row, opens a preview, a picker or a sheet. It never sends a
//    message, starts a session or links a PR: only the preview request goes to the daemon.
//  * SP4: a gesture a person did not make (app-control, an Accessibility press with VoiceOver off, a stale
//    event) does nothing at all: nothing is shown and nothing is asked of the daemon.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 the button appears on a draft or a row with nothing to fix -> testNoButtonOnADraftOrAnotherGroupOrAMergedPrOrWithNothingToFix
//   M2 the button appears without `authored_prs_notify_v1`       -> testWithOnlyTheReadOnlyFeatureThereIsNoButtonAndNoToldText
//   M3 the click sends a notify, start or link                    -> testAClickOnTheButtonOpensAPreviewAndAsksTheDaemonOnlyForTheMessage
//   M4 Return notifies, or ignores a selected fixable row         -> testReturnOnAFixableRowOpensItsPreviewAndNeverNotifies
//   M5 `activate` skips `HumanGesture`                            -> testTheButtonDoesNothingForInputThatIsNotAHumanGesture, testReturnDoesNothing...
final class AuthoredPrTellButtonTests: MouseQueueTestCase {

    private var rigs: [OverviewRig] = []
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        AppStore.shared.resetAuthoredPrsForTesting()
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        AppStore.shared.resetAuthoredPrsForTesting()
        super.tearDown()
    }

    private func makeRig(_ prs: [AuthoredPr], available: Bool = true, allowEverything: Bool = false) -> OverviewRig {
        let rig = OverviewRig(prs, handoffAvailable: available, allowEverything: allowEverything)
        rigs.append(rig)
        return rig
    }

    // MARK: - What the button says

    func testTheButtonSaysWhoItWillTellOrWhatItWillDoPerOwnerKind() throws {
        let cases: [(AuthoredPr, String, String)] = [
            (HF.pr(10, owner: HF.motherOwner()), "Tell Cody", "Tell Cody about PR 10"),
            (HF.pr(11, owner: HF.linkedOwner(tag: "focus-n", name: "Nostromo daemon")), "Tell Nostromo", "Tell Nostromo about PR 11"),
            (HF.pr(12, owner: HF.onBranchOwner()), "Tell Widgets", "Tell Widgets about PR 12"),
            (HF.pr(13, owner: HF.ambiguousOwner()), "Choose focus…", "Choose focus for PR 13"),
            (HF.pr(14, owner: .unknown), "Choose focus…", "Choose focus for PR 14"),
            (HF.pr(15, owner: HF.closedOwner()), "Start a session…", "Start a session for PR 15"),
        ]
        let rig = makeRig(cases.map { $0.0 })
        for (pr, title, label) in cases {
            let row = try rig.rowView(pr)
            XCTAssertFalse(row.tellButton.isHidden, "\(pr.id): the row has its button")
            XCTAssertEqual(row.tellButton.title, title, pr.id)
            XCTAssertEqual(row.tellButton.accessibilityLabel(), label, "\(pr.id): VoiceOver names the button")
        }
    }

    func testNoButtonOnADraftOrAnotherGroupOrAMergedPrOrWithNothingToFix() throws {
        let prs = [
            HF.pr(20, group: .draft, draft: true),
            HF.pr(21, group: .ready),
            HF.pr(22, group: .waiting),
            HF.pr(23, failing: false),
            HF.pr(24, group: .ready, lifecycle: .merged),
        ]
        let rig = makeRig(prs)
        for pr in prs {
            let row = try rig.rowView(pr)
            XCTAssertTrue(row.tellButton.isHidden, "\(pr.id): nothing to hand off, so no button")
            XCTAssertNil(row.model?.tellButton, pr.id)
        }
    }

    func testARowThatHasOneOffersItAsItsOnlyAccessibilityChild() throws {
        let fixable = HF.pr(30), ready = HF.pr(31, group: .ready)
        let rig = makeRig([fixable, ready])
        let withButton = try rig.rowView(fixable)
        let children = withButton.accessibilityChildren() ?? []
        XCTAssertEqual(children.count, 1, "the button is the one thing inside the row VoiceOver can reach")
        XCTAssertTrue((children.first as? NSButton) === withButton.tellButton)
        XCTAssertTrue((try rig.rowView(ready).accessibilityChildren() ?? []).isEmpty, "a row without one stays a single element")
    }

    // MARK: - Told

    func testARowSaysWhoWasToldAndWhenAndTheLabelSaysItToo() throws {
        let told = HF.pr(40, group: .ready, told: HF.told())
        let untold = HF.pr(41, group: .ready)
        let rig = makeRig([told, untold])
        let row = try rig.rowView(told)
        XCTAssertTrue(APT.texts(in: row).contains { $0.contains("Told Cody 1m ago") }, "the row says who was told and how long ago")
        XCTAssertTrue(try XCTUnwrap(row.accessibilityLabel()).hasSuffix("Told Cody 1m ago"), "VoiceOver hears it")
        XCTAssertFalse(APT.texts(in: try rig.rowView(untold)).contains { $0.contains("Told") }, "nobody told: nothing said")
    }

    // MARK: - Only with the notify feature

    func testWithOnlyTheReadOnlyFeatureThereIsNoButtonAndNoToldText() throws {
        let fixable = HF.pr(50, told: HF.told())
        let ready = HF.pr(51, group: .ready, told: HF.told())
        let window = APT.window(size: NSSize(width: 700, height: 600))
        windows.append(window)
        let store = AppStore.shared
        store.daemonConnectedForTesting(authoredPrs: true, notify: false)
        // The owner's focus is open, so "Tell Cody" is offered once the daemon can hand off.
        let ownerTag = try XCTUnwrap(fixable.owner.tag)
        let savedOpenFocuses = store.authoredPrHandoff.openFocuses
        store.authoredPrHandoff.openFocuses = { [AuthoredPrPickerFocus(tag: ownerTag, name: "Cody", repoName: nil)] }
        addTeardownBlock { store.authoredPrHandoff.openFocuses = savedOpenFocuses }
        let overview = AuthoredPrsOverviewView(clock: APT.FakeClock().read, timeZone: APT.utc, store: store)
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        store.applyAuthoredPrsForTesting(APT.snapshot([fixable, ready]))
        overview.layoutSubtreeIfNeeded()

        XCTAssertFalse(overview.handoffAvailable, "precondition: only authored_prs_v1 was advertised")
        for pr in [fixable, ready] {
            let row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
            XCTAssertTrue(row.tellButton.isHidden, "\(pr.id): read-only")
            XCTAssertFalse(APT.texts(in: row).contains { $0.contains("Told") }, "\(pr.id): no told text")
            XCTAssertFalse(try XCTUnwrap(row.accessibilityLabel()).contains("Told"), pr.id)
        }

        // The daemon that hands off arrives (a reconnect): the rows grow their button and told text.
        store.daemonConnectedForTesting(authoredPrs: true, notify: true)
        overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(overview.handoffAvailable)
        XCTAssertFalse(try XCTUnwrap(overview.rowView(forRowId: fixable.id)).tellButton.isHidden)
        XCTAssertTrue(APT.texts(in: try XCTUnwrap(overview.rowView(forRowId: ready.id))).contains { $0.contains("Told Cody 1m ago") || $0.contains("Told Cody") })

        // And goes again when it no longer can.
        store.daemonConnectedForTesting(authoredPrs: true, notify: false)
        overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(overview.rowView(forRowId: fixable.id)).tellButton.isHidden)
    }

    // MARK: - A click

    func testAClickOnTheButtonOpensAPreviewAndAsksTheDaemonOnlyForTheMessage() throws {
        let pr = HF.pr(60)
        let rig = makeRig([pr], allowEverything: true)

        try rig.click(pr)

        let session = try XCTUnwrap(rig.rig.preview, "the click opens a preview, not anything else: \(String(describing: rig.handoff.presented?.kindName))")
        XCTAssertEqual(session.tag, HF.tag)
        XCTAssertEqual(rig.transport.calls, [.preview(repo: HF.repo, number: 60, target: .focus(tag: HF.tag))],
                       "only the preview request goes out")
        XCTAssertTrue(rig.transport.handedOff.isEmpty, "no notify, no start, no link")
    }

    func testEveryFixableRowsClickLeadsToAPreviewAPickerOrASheetAndNeverToASend() throws {
        let expectations: [(AuthoredPr, String)] = [
            (HF.pr(70, owner: HF.motherOwner()), "preview"),
            (HF.pr(71, owner: HF.linkedOwner()), "preview"),
            (HF.pr(72, owner: HF.onBranchOwner()), "preview"),
            (HF.pr(73, owner: HF.ambiguousOwner()), "picker"),
            (HF.pr(74, owner: .unknown), "picker"),
            (HF.pr(75, owner: HF.closedOwner()), "start sheet"),
        ]
        let rig = makeRig(expectations.map { $0.0 }, allowEverything: true)
        for (pr, kind) in expectations {
            try rig.click(pr)
            XCTAssertEqual(rig.handoff.presented?.kindName, kind, "\(pr.id): the click shows a \(kind)")
        }
        XCTAssertTrue(rig.transport.handedOff.isEmpty, "not one of those clicks sent, started or linked anything")
    }

    func testAnAmbiguousRowsClickOpensThePickerWithoutAnyRequest() throws {
        let pr = HF.pr(76, owner: HF.ambiguousOwner())
        let rig = makeRig([pr], allowEverything: true)
        try rig.click(pr)
        XCTAssertNotNil(rig.rig.picker)
        XCTAssertTrue(rig.transport.calls.isEmpty, "choosing a focus is the person's: nothing is asked before they do")
    }

    // MARK: - Return

    func testReturnOnAFixableRowOpensItsPreviewAndNeverNotifies() throws {
        let pr = HF.pr(80), other = HF.pr(81, group: .ready)
        let rig = makeRig([pr, other])
        rig.overview.selectRow(id: pr.id)

        rig.outline.keyDown(with: HF.humanReturn(in: rig.window))

        XCTAssertNotNil(rig.rig.preview, "Return opens the preview for the selected row")
        XCTAssertEqual(rig.transport.calls, [.preview(repo: HF.repo, number: 80, target: .focus(tag: HF.tag))])
        XCTAssertTrue(rig.transport.handedOff.isEmpty, "Return never sends")
    }

    func testReturnOnARowWithNoButtonOrNoRowDoesNothing() throws {
        let fixable = HF.pr(82), ready = HF.pr(83, group: .ready)
        let rig = makeRig([fixable, ready])

        rig.overview.selectRow(id: ready.id)
        rig.outline.keyDown(with: HF.humanReturn(in: rig.window))
        XCTAssertNil(rig.handoff.presented, "a row with nothing to fix has nothing to open")

        rig.overview.clearSelection()
        rig.outline.keyDown(with: HF.humanReturn(in: rig.window))
        XCTAssertNil(rig.handoff.presented, "no selected row")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testReturnOnARowOfAnOverviewThatCannotHandOffDoesNothing() throws {
        let pr = HF.pr(84)
        let rig = makeRig([pr], available: false)
        rig.overview.selectRow(id: pr.id)
        rig.outline.keyDown(with: HF.humanReturn(in: rig.window))
        XCTAssertNil(rig.handoff.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: - SP4: not a person's gesture

    func testTheButtonDoesNothingForInputThatIsNotAHumanGesture() throws {
        let pr = HF.pr(90)
        let rig = makeRig([pr])
        let row = try rig.rowView(pr)
        let model = HF.row(pr)
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: rig.window)
            rig.handoff.activate(model, anchor: row, event: event, control: row.tellButton)
            XCTAssertNil(rig.handoff.presented, "\(kind): nothing opened")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was asked of the daemon")
        }
        // The same call with a person's click does open the preview: the refusals above were the gesture check.
        rig.handoff.activate(model, anchor: row, event: HF.human(in: rig.window), control: row.tellButton)
        XCTAssertNotNil(rig.rig.preview, "a person's click is accepted")
    }

    func testAPressWithNoPersonBehindItDoesNothing() throws {
        try HF.skipIfVoiceOver()
        let pr = HF.pr(91)
        let rig = makeRig([pr])
        try rig.click(pr)   // `performClick`: the action runs with whatever `NSApp.currentEvent` is (none, or not this window's click)
        XCTAssertNil(rig.handoff.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testReturnDoesNothingForInputThatIsNotAHumanGesture() throws {
        let pr = HF.pr(92)
        let rig = makeRig([pr])
        rig.overview.selectRow(id: pr.id)
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: rig.window)
            rig.overview.activateSelected(event: event)
            XCTAssertNil(rig.handoff.presented, "\(kind): nothing opened")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was asked of the daemon")
        }
    }

    func testAReturnTypedLongAgoDoesNothing() {
        let pr = HF.pr(93)
        let rig = makeRig([pr])
        rig.overview.selectRow(id: pr.id)
        // `APT.key` stamps its events with time zero: seconds since boot is long past the age limit.
        rig.outline.keyDown(with: APT.key(APT.keyReturn, "\r", window: rig.window))
        XCTAssertNil(rig.handoff.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }
}
