import XCTest

// Behavioural spec for `DecisionCoordinator`: the AppKit-free lifecycle of a
// daemon-driven decision popup.
//
// The popup must show on exactly ONE window at a time, chosen by the targeting
// ladder (asking-focus window > visible other-focus window > any window),
// without ever switching focus or stealing foreground, and the asking focus
// must be flagged in the sidebar for as long as the request is outstanding.
// Re-targeting (another window starts showing the asking focus, a window
// closes, a window becomes visible) moves the sheet WITHOUT answering — a
// system-initiated close must never reach the wire as an operator Skip.
//
// Everything below talks to the coordinator through fakes of its three seams
// (windows, sheets, attention sink) plus a real `DecisionStore`.

// MARK: - Fakes

private func reasonName(_ reason: DecisionCloseReason) -> String {
    switch reason {
    case .operatorChose: return "operatorChose"
    case .operatorDismissed: return "operatorDismissed"
    case .supersededElsewhere: return "supersededElsewhere"
    case .retargeting: return "retargeting"
    }
}

/// Mimics the real `DecisionSheet`: an operator answer claims the answer in the
/// store and only the winner forwards it via `onAnswer`; a system close never
/// answers. Like AppKit's `endSheet`, either kind of end fires the hosting
/// window's completion handler (synchronously), unless told not to.
private final class FakeSheet: DecisionSheetControlling {
    let decision: PendingDecision
    private let store: DecisionStore
    private let onAnswer: (String?) -> Void

    private(set) var closeReasons: [String] = []
    private(set) var isClosed = false
    var firesCompletionOnClose = true
    /// Set by the hosting `FakeWindow`.
    var windowCompletion: (() -> Void)?

    init(decision: PendingDecision, store: DecisionStore, onAnswer: @escaping (String?) -> Void) {
        self.decision = decision
        self.store = store
        self.onAnswer = onAnswer
    }

    /// The operator taps a choice (`choiceId`) or dismisses (`nil`).
    func answer(_ choiceId: String?) {
        guard !isClosed else { return }
        isClosed = true
        claimAndForward(choiceId)
        windowCompletion?()
    }

    /// An answer that races past this sheet's own closed state — only the
    /// store's answer-once gate stands between it and the wire.
    func answerRacingTheClose(_ choiceId: String?) {
        claimAndForward(choiceId)
    }

    private func claimAndForward(_ choiceId: String?) {
        let record: DecisionAnswerRecord = choiceId.map { .choice($0) } ?? .dismissed
        if store.claimAnswer(requestId: decision.requestId, record: record) {
            onAnswer(choiceId)
        }
    }

    func closeWithoutAnswering(reason: DecisionCloseReason) {
        closeReasons.append(reasonName(reason))
        guard !isClosed else { return }
        isClosed = true
        if firesCompletionOnClose { windowCompletion?() }
    }
}

private final class FakeWindow: DecisionHostWindow {
    let name: String
    var isVisibleNow: Bool
    var isKeyNow: Bool
    var frontOrder: Int
    var activeFocusTag: String?

    private(set) var shown: [(sheet: FakeSheet, completion: () -> Void)] = []

    init(_ name: String, visible: Bool = true, key: Bool = false, order: Int = 0, focus: String? = nil) {
        self.name = name
        self.isVisibleNow = visible
        self.isKeyNow = key
        self.frontOrder = order
        self.activeFocusTag = focus
    }

    func showDecisionSheet(_ sheet: DecisionSheetControlling, completion: @escaping () -> Void) {
        guard let fake = sheet as? FakeSheet else { return XCTFail("unexpected sheet type") }
        fake.windowCompletion = completion
        shown.append((fake, completion))
    }

    var liveSheets: [FakeSheet] { shown.filter { !$0.sheet.isClosed }.map(\.sheet) }
}

private final class FakeAttention: AttentionSink {
    private(set) var keyToTag: [String: String] = [:]
    var tags: Set<String> { Set(keyToTag.values) }

    func raiseAttention(tag: String, key: String) { keyToTag[key] = tag }
    func clearAttention(key: String) { keyToTag.removeValue(forKey: key) }
}

/// One coordinator wired to fakes and a fresh store.
private final class Harness {
    let store = DecisionStore()
    let attention = FakeAttention()
    var windows: [FakeWindow] = []
    private(set) var sheets: [FakeSheet] = []
    private(set) var answers: [(requestId: String, choiceId: String?)] = []

    private(set) lazy var coordinator = DecisionCoordinator(
        store: store,
        attention: attention,
        windows: { [unowned self] in self.windows.map { $0 as DecisionHostWindow } },
        makeSheet: { [unowned self] decision, onAnswer in
            let sheet = FakeSheet(decision: decision, store: self.store, onAnswer: onAnswer)
            self.sheets.append(sheet)
            return sheet
        },
        sendAnswer: { [unowned self] requestId, choiceId in
            self.answers.append((requestId, choiceId))
        }
    )

    static func decision(_ requestId: String = "r1", tag: String = "perri") -> PendingDecision {
        PendingDecision(
            tag: tag, requestId: requestId, prompt: "Submit review?", detail: nil,
            choices: [
                DecisionChoiceWire(id: "approve", label: "Approve", detail: nil),
                DecisionChoiceWire(id: "reject", label: "Reject", detail: nil),
            ],
            contextPaneId: nil)
    }

    static func key(_ requestId: String) -> String { "decision:\(requestId)" }

    func liveSheets(for requestId: String = "r1") -> [FakeSheet] {
        sheets.filter { !$0.isClosed && $0.decision.requestId == requestId }
    }

    /// True while the store believes some window is showing `requestId`.
    func isPresentationHeld(_ requestId: String = "r1") -> Bool {
        if store.claimPresentation(requestId: requestId) {
            store.releasePresentation(requestId: requestId)
            return false
        }
        return true
    }

    func isOutstanding(_ requestId: String = "r1") -> Bool {
        attention.keyToTag[Self.key(requestId)] != nil && store.resolution(for: requestId) == nil
    }
}

// MARK: - Tests

final class DecisionCoordinatorTests: XCTestCase {

    private var h: Harness!

    override func setUp() {
        super.setUp()
        h = Harness()
    }

    override func tearDown() {
        h = nil
        super.tearDown()
    }

    // MARK: Crash-proof accessors (a missing sheet must fail the test, not trap the runner)

    private func first(_ sheets: [FakeSheet], file: StaticString = #filePath, line: UInt = #line) -> FakeSheet {
        if let s = sheets.first { return s }
        XCTFail("expected a live sheet but there was none", file: file, line: line)
        return FakeSheet(decision: Harness.decision("missing"), store: DecisionStore(), onAnswer: { _ in })
    }

    private func completion(of window: FakeWindow, file: StaticString = #filePath, line: UInt = #line) -> () -> Void {
        if let c = window.shown.first?.completion { return c }
        XCTFail("expected \(window.name) to have been shown a sheet", file: file, line: line)
        return {}
    }

    // MARK: Placement

    func testPresentShowsExactlyOneSheetOnExactlyOneOfSeveralWindows() {
        let w1 = FakeWindow("w1", key: true, focus: "perri")
        let w2 = FakeWindow("w2", order: 1, focus: "perri")
        let w3 = FakeWindow("w3", order: 2, focus: "teri")
        h.windows = [w1, w2, w3]

        h.coordinator.present(Harness.decision())

        XCTAssertEqual(h.sheets.count, 1, "one request builds one sheet")
        XCTAssertEqual([w1, w2, w3].map { $0.shown.count }.reduce(0, +), 1, "and shows it on exactly one window")
    }

    func testAskingFocusWindowGetsTheSheetEvenWhenAnotherWindowIsKey() {
        let keyOther = FakeWindow("keyOther", key: true, order: 0, focus: "teri")
        let asking = FakeWindow("asking", key: false, order: 3, focus: "perri")
        h.windows = [keyOther, asking]

        h.coordinator.present(Harness.decision(tag: "perri"))

        XCTAssertEqual(asking.liveSheets.count, 1)
        XCTAssertTrue(keyOther.shown.isEmpty, "tier 2/3 windows are left alone when tier 1 exists")
    }

    func testWithNoWindowShowingTheAskingFocusTheKeyVisibleWindowGetsTheSheetAndNothingElseChanges() {
        let key = FakeWindow("key", key: true, order: 1, focus: "teri")
        let other = FakeWindow("other", key: false, order: 0, focus: "fred")
        let hidden = FakeWindow("hidden", visible: false, key: false, order: 2, focus: "perri")
        h.windows = [key, other, hidden]

        h.coordinator.present(Harness.decision(tag: "perri"))

        XCTAssertEqual(key.liveSheets.count, 1)
        XCTAssertTrue(other.shown.isEmpty)
        XCTAssertTrue(hidden.shown.isEmpty)
        // The popup must never switch what any window is showing.
        XCTAssertEqual(key.activeFocusTag, "teri")
        XCTAssertEqual(other.activeFocusTag, "fred")
        XCTAssertEqual(hidden.activeFocusTag, "perri")
    }

    func testInvisibleWindowShowingTheAskingFocusDoesNotBeatAVisibleWindowShowingAnotherFocus() {
        let hiddenAsking = FakeWindow("hiddenAsking", visible: false, key: true, order: 0, focus: "perri")
        let visibleOther = FakeWindow("visibleOther", visible: true, key: false, order: 5, focus: "teri")
        h.windows = [hiddenAsking, visibleOther]

        h.coordinator.present(Harness.decision(tag: "perri"))

        XCTAssertEqual(visibleOther.liveSheets.count, 1)
        XCTAssertTrue(hiddenAsking.shown.isEmpty)
    }

    func testWhenNoWindowIsVisibleTheSheetStillShowsOnTheKeyWindow() {
        let a = FakeWindow("a", visible: false, key: false, order: 0)
        let b = FakeWindow("b", visible: false, key: true, order: 3)
        h.windows = [a, b]

        h.coordinator.present(Harness.decision())

        XCTAssertEqual(b.liveSheets.count, 1)
        XCTAssertTrue(a.shown.isEmpty)
    }

    func testPresentingNeverAltersWindowStateOtherThanShowingTheSheet() {
        let w1 = FakeWindow("w1", visible: true, key: true, order: 4, focus: "teri")
        let w2 = FakeWindow("w2", visible: false, key: false, order: 2, focus: nil)
        h.windows = [w1, w2]

        h.coordinator.present(Harness.decision())

        XCTAssertTrue(w1.isVisibleNow); XCTAssertTrue(w1.isKeyNow)
        XCTAssertEqual(w1.frontOrder, 4); XCTAssertEqual(w1.activeFocusTag, "teri")
        XCTAssertFalse(w2.isVisibleNow); XCTAssertFalse(w2.isKeyNow)
        XCTAssertEqual(w2.frontOrder, 2); XCTAssertNil(w2.activeFocusTag)
    }

    func testPresentedWindowReportsTheWindowHoldingTheSheet() {
        let w1 = FakeWindow("w1", focus: "teri")
        let w2 = FakeWindow("w2", focus: "perri")
        h.windows = [w1, w2]

        h.coordinator.present(Harness.decision())

        XCTAssertTrue(h.coordinator.presentedWindow(for: "r1") === w2)
        XCTAssertNil(h.coordinator.presentedWindow(for: "unknown"))
    }

    // MARK: Exactly-once presentation

    func testAnotherPresentOfTheSameRequestIsIgnored() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]

        h.coordinator.present(Harness.decision())
        h.coordinator.present(Harness.decision())

        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertEqual(w.shown.count, 1)
    }

    func testPresentHoldsThePresentationClaimWhileTheSheetIsUp() {
        h.windows = [FakeWindow("w", focus: "perri")]
        h.coordinator.present(Harness.decision())
        XCTAssertTrue(h.isPresentationHeld())
    }

    func testPresentIsSkippedForARequestTheStoreAlreadyHasAResolutionFor() {
        h.windows = [FakeWindow("w", focus: "perri")]
        XCTAssertTrue(h.store.claimAnswer(requestId: "r1", record: .choice("approve")))

        h.coordinator.present(Harness.decision())

        XCTAssertTrue(h.sheets.isEmpty)
        XCTAssertTrue(h.windows[0].shown.isEmpty)
        XCTAssertTrue(h.attention.tags.isEmpty, "a request that is already done must not flag anything")
        XCTAssertFalse(h.isPresentationHeld())
    }

    func testTwoDifferentRequestsPresentIndependentlyEachOnOneWindow() {
        let w1 = FakeWindow("w1", key: true, focus: "perri")
        let w2 = FakeWindow("w2", order: 1, focus: "cody-abc12345")
        h.windows = [w1, w2]

        h.coordinator.present(Harness.decision("r1", tag: "perri"))
        h.coordinator.present(Harness.decision("r2", tag: "cody-abc12345"))

        XCTAssertEqual(h.liveSheets(for: "r1").count, 1)
        XCTAssertEqual(h.liveSheets(for: "r2").count, 1)
        XCTAssertEqual(w1.liveSheets.map { $0.decision.requestId }, ["r1"])
        XCTAssertEqual(w2.liveSheets.map { $0.decision.requestId }, ["r2"])

        // Answering one leaves the other untouched.
        first(w1.liveSheets).answer("approve")
        XCTAssertEqual(h.answers.map { $0.requestId }, ["r1"])
        XCTAssertEqual(h.liveSheets(for: "r2").count, 1)
        XCTAssertEqual(h.attention.tags, ["cody-abc12345"])
    }

    // MARK: No window available

    func testWithNoWindowsNothingIsShownButTheRequestIsStillFlaggedAndOutstanding() {
        h.windows = []

        h.coordinator.present(Harness.decision(tag: "perri"))

        XCTAssertTrue(h.sheets.isEmpty)
        XCTAssertEqual(h.attention.keyToTag[Harness.key("r1")], "perri")
        XCTAssertFalse(h.isPresentationHeld(), "claim is released so a later attempt can present")
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertTrue(h.answers.isEmpty)
    }

    func testAWindowThatAppearsLaterPicksUpAnOutstandingRequestOnReevaluate() {
        h.windows = []
        h.coordinator.present(Harness.decision())

        let late = FakeWindow("late", key: true, focus: "teri")
        h.windows = [late]
        h.coordinator.reevaluate()

        XCTAssertEqual(late.liveSheets.count, 1)
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertEqual(h.attention.tags, ["perri"])

        h.coordinator.reevaluate()
        XCTAssertEqual(h.sheets.count, 1, "a second reevaluate does not duplicate the sheet")
    }

    // MARK: Answering

    func testAnsweringSendsExactlyOneAnswerAndCleansUp() {
        let w1 = FakeWindow("w1", key: true, focus: "perri")
        let w2 = FakeWindow("w2", order: 1, focus: "teri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision())

        first(w1.liveSheets).answer("approve")

        XCTAssertEqual(h.answers.count, 1)
        XCTAssertEqual(h.answers.first?.requestId, "r1")
        XCTAssertEqual(h.answers.first?.choiceId, "approve")
        XCTAssertEqual(h.store.resolution(for: "r1"), .choice("approve"))
        XCTAssertTrue(h.attention.tags.isEmpty)
        XCTAssertFalse(h.isPresentationHeld())
        XCTAssertTrue(w2.shown.isEmpty, "no other window ever had a sheet")
    }

    func testASecondAnswerAttemptSendsNothing() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())
        let sheet = first(w.liveSheets)

        sheet.answer("approve")
        sheet.answer("reject")
        sheet.answerRacingTheClose("reject")

        XCTAssertEqual(h.answers.count, 1)
        XCTAssertEqual(h.answers.first?.choiceId, "approve")
        XCTAssertEqual(h.store.resolution(for: "r1"), .choice("approve"))
    }

    func testDismissingSendsOneNilAnswerAndRecordsADismissal() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())

        first(w.liveSheets).answer(nil)

        XCTAssertEqual(h.answers.count, 1)
        XCTAssertEqual(h.answers.first?.requestId, "r1")
        XCTAssertNil(h.answers.first?.choiceId)
        XCTAssertEqual(h.store.resolution(for: "r1"), .dismissed)
        XCTAssertTrue(h.attention.tags.isEmpty)
        XCTAssertFalse(h.isPresentationHeld())
    }

    func testAnAnsweredRequestIsNotPresentedAgainByPresentOrReevaluate() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())
        first(w.liveSheets).answer("approve")

        h.coordinator.present(Harness.decision())
        h.coordinator.reevaluate()

        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(h.attention.tags.isEmpty)
    }

    // MARK: Reevaluate: moving the sheet without answering

    func testReevaluateMovesTheSheetToAWindowThatStartsShowingTheAskingFocus() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "fred")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        XCTAssertEqual(w1.liveSheets.count, 1)
        let oldSheet = first(w1.liveSheets)

        w2.activeFocusTag = "perri"
        h.coordinator.reevaluate()

        XCTAssertEqual(oldSheet.closeReasons, ["retargeting"])
        XCTAssertTrue(w1.liveSheets.isEmpty)
        XCTAssertEqual(w2.liveSheets.count, 1)
        XCTAssertEqual(h.sheets.count, 2, "a fresh sheet was built for the new window")
        XCTAssertEqual(h.liveSheets().count, 1, "exactly one live sheet at any time")
        XCTAssertTrue(h.answers.isEmpty, "moving a sheet must never answer")
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertEqual(h.attention.keyToTag[Harness.key("r1")], "perri")
        XCTAssertTrue(h.isPresentationHeld())
    }

    func testReevaluateMovesAFallbackSheetOnceAnotherWindowBecomesVisible() {
        let w1 = FakeWindow("w1", visible: false, key: true, order: 0, focus: "perri")
        let w2 = FakeWindow("w2", visible: false, key: false, order: 1, focus: "teri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        XCTAssertEqual(w1.liveSheets.count, 1, "tier 3 still presents")
        let oldSheet = first(w1.liveSheets)

        w2.isVisibleNow = true
        h.coordinator.reevaluate()

        XCTAssertEqual(oldSheet.closeReasons, ["retargeting"])
        XCTAssertEqual(w2.liveSheets.count, 1)
        XCTAssertEqual(h.liveSheets().count, 1)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertEqual(h.attention.tags, ["perri"])
    }

    func testReevaluateMovesAFallbackSheetStraightToAnAskingFocusWindowThatBecomesVisible() {
        let w1 = FakeWindow("w1", visible: false, key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", visible: false, key: false, order: 1, focus: "perri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        XCTAssertEqual(w1.liveSheets.count, 1)

        w2.isVisibleNow = true
        h.coordinator.reevaluate()

        XCTAssertEqual(w2.liveSheets.count, 1)
        XCTAssertTrue(w1.liveSheets.isEmpty)
        XCTAssertEqual(h.liveSheets().count, 1)
        XCTAssertTrue(h.answers.isEmpty)
    }

    func testReevaluateMovesTheSheetOffAWindowThatSwitchedAwayWhenAnotherNowShowsTheAskingFocus() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "perri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "teri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        XCTAssertEqual(w1.liveSheets.count, 1)

        w1.activeFocusTag = "fred"
        w2.activeFocusTag = "perri"
        h.coordinator.reevaluate()

        XCTAssertEqual(w2.liveSheets.count, 1)
        XCTAssertTrue(w1.liveSheets.isEmpty)
        XCTAssertTrue(h.answers.isEmpty)
    }

    func testReevaluateDoesNotMoveASheetThatIsAlreadyOnAnAskingFocusWindow() {
        let w1 = FakeWindow("w1", key: false, order: 5, focus: "perri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "teri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let sheet = first(w1.liveSheets)

        // A second, better-ranked asking-focus window appears; tier did not improve.
        w2.activeFocusTag = "perri"
        w2.isKeyNow = true
        w2.frontOrder = 0
        h.coordinator.reevaluate()

        XCTAssertEqual(w1.liveSheets.count, 1)
        XCTAssertTrue(w2.shown.isEmpty)
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(sheet.closeReasons.isEmpty)
    }

    func testReevaluateDoesNotCloseAndReattachWhenTheHoldingWindowItselfMovesUpATier() {
        let holder = FakeWindow("holder", key: true, order: 0, focus: "teri")
        h.windows = [holder]
        h.coordinator.present(Harness.decision(tag: "perri"))   // tier 2 on the only window
        let sheet = first(holder.liveSheets)

        holder.activeFocusTag = "perri"   // the operator switched this same window to the asking focus
        h.coordinator.reevaluate()

        XCTAssertTrue(sheet.closeReasons.isEmpty, "no close while the sheet is already on the best window")
        XCTAssertEqual(holder.shown.count, 1, "no re-attach (no beginSheet while the old sheet is ending)")
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertEqual(holder.liveSheets.count, 1)
        XCTAssertTrue(h.isPresentationHeld())
    }

    func testReevaluateDoesNotChurnWhenOnlyTheKeyWindowChangesAmongEqualTierWindows() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "fred")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let sheet = first(w1.liveSheets)

        w1.isKeyNow = false
        w2.isKeyNow = true
        h.coordinator.reevaluate()

        XCTAssertEqual(w1.liveSheets.count, 1)
        XCTAssertTrue(w2.shown.isEmpty)
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(sheet.closeReasons.isEmpty)
    }

    func testReevaluateDoesNotChurnWhenTheCurrentWindowDropsATierButNothingBetterExists() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "perri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "teri")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let sheet = first(w1.liveSheets)

        w1.activeFocusTag = "fred"   // tier 1 -> tier 2; w2 is tier 2 too, so no improvement
        h.coordinator.reevaluate()

        XCTAssertEqual(w1.liveSheets.count, 1)
        XCTAssertTrue(w2.shown.isEmpty)
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(sheet.closeReasons.isEmpty)
        XCTAssertTrue(h.isPresentationHeld())
    }

    func testReevaluateDoesNotChurnWhenTheCurrentFallbackWindowBecomesVisibleItself() {
        let w1 = FakeWindow("w1", visible: false, key: true, order: 0, focus: "perri")
        h.windows = [w1]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let sheet = first(w1.liveSheets)

        w1.isVisibleNow = true
        h.coordinator.reevaluate()

        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(sheet.closeReasons.isEmpty)
        XCTAssertEqual(w1.liveSheets.count, 1)
    }

    func testReevaluateWithNothingOutstandingDoesNothing() {
        h.windows = [FakeWindow("w", focus: "perri")]
        h.coordinator.reevaluate()
        XCTAssertTrue(h.sheets.isEmpty)
        XCTAssertTrue(h.attention.tags.isEmpty)
        XCTAssertTrue(h.answers.isEmpty)
    }

    // MARK: Window closing

    func testWhenThePresentingWindowClosesTheSheetMovesToTheBestRemainingWindowWithoutAnswering() {
        let closing = FakeWindow("closing", key: true, order: 0, focus: "perri")
        let survivor = FakeWindow("survivor", order: 1, focus: "teri")
        h.windows = [closing, survivor]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let oldSheet = first(closing.liveSheets)

        // The closing window still appears in `windows()` (and is even tier 1):
        // it must still be excluded.
        h.coordinator.windowWillClose(closing)

        XCTAssertEqual(oldSheet.closeReasons, ["retargeting"])
        XCTAssertEqual(survivor.liveSheets.count, 1)
        XCTAssertEqual(closing.shown.count, 1, "never re-presented onto the closing window")
        XCTAssertEqual(h.liveSheets().count, 1)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertEqual(h.attention.tags, ["perri"])
        XCTAssertTrue(h.isPresentationHeld())
    }

    func testTheSheetFromAClosingWindowGoesToTheBestSurvivorByTheTargetingRule() {
        let closing = FakeWindow("closing", key: true, order: 0, focus: "perri")
        let otherFocus = FakeWindow("otherFocus", key: false, order: 1, focus: "teri")
        let asking = FakeWindow("asking", key: false, order: 2, focus: "perri")
        let hidden = FakeWindow("hidden", visible: false, key: false, order: 3, focus: "perri")
        h.windows = [closing, otherFocus, asking, hidden]
        h.coordinator.present(Harness.decision(tag: "perri"))
        XCTAssertEqual(closing.liveSheets.count, 1)

        h.coordinator.windowWillClose(closing)

        XCTAssertEqual(asking.liveSheets.count, 1)
        XCTAssertTrue(otherFocus.shown.isEmpty)
        XCTAssertTrue(hidden.shown.isEmpty)
    }

    func testWhenTheLastWindowClosesTheRequestStaysOutstandingAndFlaggedWithNoSheet() {
        let only = FakeWindow("only", key: true, focus: "perri")
        h.windows = [only]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let oldSheet = first(only.liveSheets)

        h.coordinator.windowWillClose(only)

        XCTAssertEqual(oldSheet.closeReasons, ["retargeting"])
        XCTAssertEqual(h.sheets.count, 1, "no new sheet: nowhere to put it")
        XCTAssertTrue(h.liveSheets().isEmpty)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertEqual(h.attention.keyToTag[Harness.key("r1")], "perri")
        XCTAssertFalse(h.isPresentationHeld(), "claim released so the request can be shown again")
    }

    // The close fires window notifications (occlusion, screen, app-active) that
    // call `reevaluate()` while the closing window is STILL listed in `windows()`.
    // A closing window must be excluded from every later selection, not just from
    // the `windowWillClose` call itself.

    func testReevaluateWhileTheClosingWindowIsStillListedDoesNotMoveTheSheetBackOntoIt() {
        let closing = FakeWindow("closing", key: true, order: 0, focus: "perri")
        let survivor = FakeWindow("survivor", order: 1, focus: "teri")
        h.windows = [closing, survivor]
        h.coordinator.present(Harness.decision(tag: "perri"))
        h.coordinator.windowWillClose(closing)
        XCTAssertEqual(survivor.liveSheets.count, 1)
        let survivorSheet = first(survivor.liveSheets)

        h.coordinator.reevaluate()   // the closing window is tier 1 and still listed
        h.coordinator.reevaluate()

        XCTAssertEqual(closing.shown.count, 1, "never re-presented onto the closing window")
        XCTAssertEqual(survivor.liveSheets.count, 1)
        XCTAssertTrue(survivorSheet.closeReasons.isEmpty, "the survivor's sheet is not churned")
        XCTAssertEqual(h.sheets.count, 2)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertEqual(h.attention.tags, ["perri"])
    }

    func testReevaluateWhileTheLastWindowIsStillListedAndClosingPresentsNothingOntoIt() {
        let only = FakeWindow("only", key: true, focus: "perri")
        h.windows = [only]
        h.coordinator.present(Harness.decision(tag: "perri"))
        h.coordinator.windowWillClose(only)

        h.coordinator.reevaluate()   // still listed: must not claim and attach to it

        XCTAssertEqual(only.shown.count, 1, "nothing new is shown on the closing window")
        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(h.liveSheets().isEmpty)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertEqual(h.attention.keyToTag[Harness.key("r1")], "perri", "still outstanding and flagged")
        XCTAssertFalse(h.isPresentationHeld(), "claim released, not held by a dead sheet")
    }

    func testAWindowThatAppearsWhileTheLastOneIsStillClosingGetsTheRequest() {
        let only = FakeWindow("only", key: true, focus: "perri")
        h.windows = [only]
        h.coordinator.present(Harness.decision(tag: "perri"))
        h.coordinator.windowWillClose(only)
        h.coordinator.reevaluate()

        let fresh = FakeWindow("fresh", key: true, order: 1, focus: "teri")
        h.windows = [only, fresh]   // the closing window is even a better tier than `fresh`
        h.coordinator.reevaluate()

        XCTAssertEqual(fresh.liveSheets.count, 1)
        XCTAssertEqual(only.shown.count, 1)
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertTrue(h.answers.isEmpty)

        first(fresh.liveSheets).answer("approve")
        XCTAssertEqual(h.answers.count, 1)
        XCTAssertTrue(h.attention.tags.isEmpty)
    }

    func testANewRequestIsNeverPresentedOnAWindowThatIsClosing() {
        let closing = FakeWindow("closing", key: true, order: 0, focus: "perri")
        let survivor = FakeWindow("survivor", order: 1, focus: "teri")
        h.windows = [closing, survivor]
        h.coordinator.windowWillClose(closing)

        h.coordinator.present(Harness.decision("r2", tag: "perri"))

        XCTAssertTrue(closing.shown.isEmpty)
        XCTAssertEqual(survivor.liveSheets.count, 1)
    }

    func testARequestLeftWithoutAWindowIsPresentedWhenOneLaterAppears() {
        let only = FakeWindow("only", key: true, focus: "perri")
        h.windows = [only]
        h.coordinator.present(Harness.decision(tag: "perri"))
        h.coordinator.windowWillClose(only)
        h.windows = []   // the window is now actually gone

        let fresh = FakeWindow("fresh", key: true, focus: "teri")
        h.windows = [fresh]
        h.coordinator.reevaluate()

        XCTAssertEqual(fresh.liveSheets.count, 1)
        XCTAssertEqual(h.liveSheets().count, 1)
        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertTrue(h.isPresentationHeld())

        first(fresh.liveSheets).answer("approve")
        XCTAssertEqual(h.answers.count, 1)
    }

    func testClosingAWindowThatHasNoSheetChangesNothing() {
        let presenting = FakeWindow("presenting", key: true, focus: "perri")
        let bystander = FakeWindow("bystander", order: 1, focus: "teri")
        h.windows = [presenting, bystander]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let sheet = first(presenting.liveSheets)

        h.coordinator.windowWillClose(bystander)

        XCTAssertEqual(h.sheets.count, 1)
        XCTAssertTrue(sheet.closeReasons.isEmpty)
        XCTAssertEqual(presenting.liveSheets.count, 1)
        XCTAssertTrue(bystander.shown.isEmpty)
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertEqual(h.attention.tags, ["perri"])
    }

    func testAnswerAfterAWindowCloseRetargetStillSendsExactlyOnce() {
        let closing = FakeWindow("closing", key: true, focus: "perri")
        let survivor = FakeWindow("survivor", order: 1, focus: "teri")
        h.windows = [closing, survivor]
        h.coordinator.present(Harness.decision(tag: "perri"))
        h.coordinator.windowWillClose(closing)

        first(survivor.liveSheets).answer("reject")

        XCTAssertEqual(h.answers.count, 1)
        XCTAssertEqual(h.answers.first?.choiceId, "reject")
        XCTAssertTrue(h.attention.tags.isEmpty)
    }

    // MARK: Stale window callbacks

    func testALateCompletionFromARetargetedSheetDoesNotEndTheLiveRequest() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "fred")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let staleCompletion = completion(of: w1)
        w2.activeFocusTag = "perri"
        h.coordinator.reevaluate()
        XCTAssertEqual(w2.liveSheets.count, 1)

        staleCompletion()   // AppKit delivering the old sheet's end late / again

        XCTAssertEqual(w2.liveSheets.count, 1, "the live sheet is untouched")
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertEqual(h.attention.tags, ["perri"])
        XCTAssertNil(h.store.resolution(for: "r1"))
        XCTAssertTrue(h.answers.isEmpty)

        first(w2.liveSheets).answer("approve")
        XCTAssertEqual(h.answers.count, 1, "the request is still answerable")
    }

    func testALateCompletionFromAClosedWindowsSheetDoesNotEndTheRetargetedRequest() {
        let closing = FakeWindow("closing", key: true, focus: "perri")
        let survivor = FakeWindow("survivor", order: 1, focus: "teri")
        h.windows = [closing, survivor]
        h.coordinator.present(Harness.decision(tag: "perri"))
        let staleCompletion = completion(of: closing)
        h.coordinator.windowWillClose(closing)

        staleCompletion()
        staleCompletion()

        XCTAssertEqual(survivor.liveSheets.count, 1)
        XCTAssertTrue(h.isPresentationHeld())
        XCTAssertEqual(h.attention.tags, ["perri"])
    }

    func testRetargetingStillWorksWhenTheOldSheetDoesNotFireItsCompletionOnClose() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", key: false, order: 1, focus: "fred")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))
        first(w1.liveSheets).firesCompletionOnClose = false

        w2.activeFocusTag = "perri"
        h.coordinator.reevaluate()

        XCTAssertEqual(w2.liveSheets.count, 1)
        XCTAssertEqual(h.liveSheets().count, 1)
        XCTAssertTrue(h.isPresentationHeld())
    }

    // MARK: Resolution announced by the daemon

    func testResolvedRequestsCloseTheSheetSilentlyRecordAndCleanUp() {
        let cases: [(resolution: String, choiceId: String?, expected: DecisionAnswerRecord)] = [
            ("answered", "approve", .choice("approve")),
            ("dismissed", nil, .dismissed),
            ("timeout", nil, .dismissed),
            ("cancelled", nil, .dismissed),
        ]
        for (index, c) in cases.enumerated() {
            let h = Harness()
            let id = "r\(index)"
            let w = FakeWindow("w", key: true, focus: "perri")
            h.windows = [w]
            h.coordinator.present(Harness.decision(id))
            let sheet = first(w.liveSheets)

            h.coordinator.handleResolved(
                ResolvedDecision(tag: "perri", requestId: id, resolution: c.resolution, choiceId: c.choiceId))

            XCTAssertEqual(sheet.closeReasons, ["supersededElsewhere"], c.resolution)
            XCTAssertTrue(h.answers.isEmpty, "\(c.resolution): a resolution notice never answers")
            XCTAssertEqual(h.store.resolution(for: id), c.expected, c.resolution)
            XCTAssertTrue(h.attention.tags.isEmpty, c.resolution)
            XCTAssertFalse(h.isPresentationHeld(id), c.resolution)
            XCTAssertTrue(w.liveSheets.isEmpty, c.resolution)
        }
    }

    func testAnsweredResolutionWithoutAChoiceIdIsRecordedAsDismissed() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())

        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered", choiceId: nil))

        XCTAssertEqual(h.store.resolution(for: "r1"), .dismissed)
    }

    func testResolvedRequestThatHadNoWindowStillRecordsAndClearsTheFlag() {
        h.windows = []
        h.coordinator.present(Harness.decision())
        XCTAssertEqual(h.attention.tags, ["perri"])

        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r1", resolution: "timeout", choiceId: nil))

        XCTAssertTrue(h.attention.tags.isEmpty)
        XCTAssertEqual(h.store.resolution(for: "r1"), .dismissed)

        h.windows = [FakeWindow("late", focus: "perri")]
        h.coordinator.reevaluate()
        XCTAssertTrue(h.sheets.isEmpty, "a resolved request never comes back")
    }

    func testPresentAfterAResolutionForTheSameRequestDoesNothing() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered", choiceId: "approve"))

        h.coordinator.present(Harness.decision())

        XCTAssertTrue(h.sheets.isEmpty)
        XCTAssertTrue(w.shown.isEmpty)
        XCTAssertTrue(h.attention.tags.isEmpty)
        XCTAssertEqual(h.store.resolution(for: "r1"), .choice("approve"))
    }

    func testAnOperatorAnswerRacingAResolutionNoticeNeverReachesTheWire() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())
        let sheet = first(w.liveSheets)

        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered", choiceId: "approve"))
        sheet.answerRacingTheClose("reject")

        XCTAssertTrue(h.answers.isEmpty)
        XCTAssertEqual(h.store.resolution(for: "r1"), .choice("approve"))
    }

    func testResolvingOneRequestLeavesAnotherRequestsSheetAndFlagAlone() {
        let w = FakeWindow("w", key: true, focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision("r1", tag: "perri"))
        h.coordinator.present(Harness.decision("r2", tag: "cody-abc12345"))

        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r1", resolution: "timeout", choiceId: nil))

        XCTAssertEqual(h.liveSheets(for: "r2").count, 1)
        XCTAssertEqual(h.attention.tags, ["cody-abc12345"])
        XCTAssertTrue(h.isPresentationHeld("r2"))
    }

    // MARK: Attention lifecycle

    func testAttentionIsRaisedOnPresentForTheAskingTagUnderADecisionKey() {
        h.windows = [FakeWindow("w", focus: "teri")]

        h.coordinator.present(Harness.decision("r9", tag: "cody-abc12345"))

        XCTAssertEqual(h.attention.keyToTag, [Harness.key("r9"): "cody-abc12345"])
    }

    func testAttentionStaysRaisedWhileTheSheetIsMoved() {
        let w1 = FakeWindow("w1", key: true, order: 0, focus: "teri")
        let w2 = FakeWindow("w2", order: 1, focus: "fred")
        h.windows = [w1, w2]
        h.coordinator.present(Harness.decision(tag: "perri"))

        w2.activeFocusTag = "perri"
        h.coordinator.reevaluate()
        XCTAssertEqual(h.attention.tags, ["perri"])

        h.coordinator.windowWillClose(w2)
        XCTAssertEqual(h.attention.tags, ["perri"])
    }

    func testTwoOutstandingRequestsForOneTagKeepItFlaggedUntilBothAreResolved() {
        let w = FakeWindow("w", key: true, focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision("r1", tag: "perri"))
        h.coordinator.present(Harness.decision("r2", tag: "perri"))
        XCTAssertEqual(h.attention.tags, ["perri"])
        XCTAssertEqual(h.attention.keyToTag.count, 2)

        first(h.liveSheets(for: "r1")).answer("approve")
        XCTAssertEqual(h.attention.tags, ["perri"], "r2 is still outstanding")

        h.coordinator.handleResolved(
            ResolvedDecision(tag: "perri", requestId: "r2", resolution: "cancelled", choiceId: nil))
        XCTAssertTrue(h.attention.tags.isEmpty)
    }

    func testAttentionIsClearedWhenTheOperatorDismisses() {
        let w = FakeWindow("w", focus: "perri")
        h.windows = [w]
        h.coordinator.present(Harness.decision())
        XCTAssertEqual(h.attention.tags, ["perri"])

        first(w.liveSheets).answer(nil)

        XCTAssertTrue(h.attention.tags.isEmpty)
    }

    // MARK: Source guards

    private static let forbiddenForegroundAndFocusCalls = [
        "NSApp.activate",
        ".activate(",
        "makeKeyAndOrderFront",
        "orderFrontRegardless",
        "makeKey()",
        "requestUserAttention",
        "focusSession(",
        "makeMain",
    ]

    func testPresenterAndCoordinatorNeverStealForegroundOrSwitchFocus() throws {
        for file in ["UI/DecisionPresenter.swift", "UI/DecisionCoordinator.swift"] {
            let code = try Self.codeLines(ofSourceAt: file).joined(separator: "\n")
            for needle in Self.forbiddenForegroundAndFocusCalls {
                XCTAssertFalse(code.contains(needle),
                               "\(file) must not call `\(needle)`: a decision popup never steals foreground or switches focus")
            }
        }
    }

    func testPresenterNoLongerFansASheetOutToEveryWindow() throws {
        let code = try Self.codeLines(ofSourceAt: "UI/DecisionPresenter.swift").joined(separator: "\n")
        XCTAssertFalse(code.contains("targetWindows("),
                       "DecisionPresenter must target ONE window through DecisionCoordinator, not enumerate every window")
    }

    /// Source lines of `Nostromo/<relativePath>` with full-line `//` comments dropped.
    private static func codeLines(ofSourceAt relativePath: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/DecisionCoordinatorTests.swift
            .deletingLastPathComponent()              // …/macOS/NostromoTests
            .deletingLastPathComponent()              // …/macOS
            .appendingPathComponent("Nostromo")
        let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return source.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }
}
