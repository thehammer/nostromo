import XCTest

// `ComposerHistoryNavigator`: the pure key rules of composer history (A38 to A42, human-only rule).
// No AppKit here: a key press is a `ComposerKeyContext`. The real text view is `ReplInputBarHistoryTests`.

final class ComposerHistoryNavigatorTests: XCTestCase {

    private var history: [String] = []   // newest first
    private lazy var nav = ComposerHistoryNavigator(entries: { [unowned self] in self.history })

    override func setUp() {
        super.setUp()
        history = ["c", "b", "a"]
    }

    /// A key press with the caret at `caret` (default: the end of `text`).
    private func key(_ text: String = "", caret: Int? = nil, selection: Int = 0, marked: Bool = false,
                     modifiers: Bool = false, human: Bool = true, images: Bool = false) -> ComposerKeyContext {
        ComposerKeyContext(text: text, caret: caret ?? text.utf16.count, selectionLength: selection,
                           hasMarkedText: marked, hasModifiers: modifiers, isHuman: human, hasDraftImages: images)
    }

    private func shown(_ outcome: ComposerHistoryOutcome, file: StaticString = #filePath, line: UInt = #line) -> String? {
        if case .show(let text, _) = outcome { return text }
        XCTFail("expected a recall, got \(outcome)", file: file, line: line)
        return nil
    }

    // MARK: A38

    func testUpFromAnEmptyComposerWalksNewestToOldestAndDownWalksBackToTheEmptyDraft() {
        XCTAssertEqual(shown(nav.up(key())), "c")
        XCTAssertEqual(shown(nav.up(key("c"))), "b")
        XCTAssertEqual(shown(nav.up(key("b"))), "a")
        XCTAssertEqual(nav.up(key("a")), .passThrough, "past the oldest there is nothing older")
        XCTAssertEqual(shown(nav.down(key("a"))), "b")
        XCTAssertEqual(shown(nav.down(key("b"))), "c")
        XCTAssertEqual(shown(nav.down(key("c"))), "", "the original empty draft")
        XCTAssertFalse(nav.isNavigating)
    }

    func testWithNoHistoryUpDoesNothing() {
        history = []
        XCTAssertEqual(nav.up(key()), .passThrough)
        XCTAssertFalse(nav.isNavigating)
    }

    // MARK: A39 the draft is never lost

    func testDownPastTheNewestRestoresTheDraftExactly() {
        let draft = "  draft text\nwith two lines \t"
        XCTAssertEqual(shown(nav.up(key(draft, caret: 0, images: true))), "c")
        XCTAssertEqual(shown(nav.down(key("c"))), draft)
    }

    func testUpFromADraftWithTheCaretNotAtTheStartDoesNotRecall() {
        XCTAssertEqual(nav.up(key("draft text", caret: 5)), .passThrough)
        XCTAssertFalse(nav.isNavigating)
    }

    // MARK: A40 the caret rule

    func testInAThreeLineDraftUpOnlyActsAtTheVeryStart() {
        let draft = "one\ntwo\nthree"
        // AppKit moves the caret line by line; none of these positions is the start.
        for caret in [draft.utf16.count, 9, 6, 4, 2, 1] {
            XCTAssertEqual(nav.up(key(draft, caret: caret)), .passThrough, "caret \(caret)")
        }
        XCTAssertEqual(shown(nav.up(key(draft, caret: 0))), "c", "only at the start")
    }

    func testDownActsOnlyWhileNavigatingAndWithTheCaretAtTheEnd() {
        XCTAssertEqual(nav.down(key("")), .passThrough, "not navigating")
        XCTAssertEqual(nav.down(key("draft", caret: 5)), .passThrough, "not navigating")
        _ = nav.up(key("", caret: 0))
        XCTAssertEqual(nav.down(key("c", caret: 0)), .passThrough, "navigating, caret not at the end")
        XCTAssertEqual(shown(nav.down(key("c"))), "")
    }

    func testAMultiLineRecalledEntryLetsAppKitMoveTheCaretBeforeUpActs() {
        history = ["first\nsecond", "older"]
        _ = nav.up(key())
        let shownText = "first\nsecond"
        XCTAssertEqual(nav.up(key(shownText)), .passThrough, "caret at the end of a two-line entry: AppKit moves up")
        XCTAssertEqual(nav.up(key(shownText, caret: 3)), .passThrough, "first line, not the start")
        XCTAssertEqual(shown(nav.up(key(shownText, caret: 0))), "older")
    }

    func testASingleLineRecalledEntryWalksOnWithOneUpPerEntryButNotFromTheMiddle() {
        _ = nav.up(key())
        XCTAssertEqual(nav.up(key("c", caret: 0)), .show(text: "b", announcement: "History 2 of 3"))
        history = ["long entry", "b", "a"]
        let n2 = ComposerHistoryNavigator(entries: { self.history })
        _ = n2.up(key())
        XCTAssertEqual(n2.up(key("long entry", caret: 4)), .passThrough, "mid-line: AppKit moves the caret first")
    }

    // MARK: A41 guards

    func testNothingActsWithTextSelected() {
        XCTAssertEqual(nav.up(key("text", caret: 0, selection: 2)), .passThrough)
        _ = nav.up(key())
        XCTAssertEqual(nav.down(key("c", caret: 0, selection: 1)), .passThrough)
        XCTAssertEqual(nav.up(key("c", caret: 0, selection: 1)), .passThrough)
    }

    func testNothingActsWithAModifierHeld() {
        XCTAssertEqual(nav.up(key(modifiers: true)), .passThrough)
        _ = nav.up(key())
        XCTAssertEqual(nav.down(key("c", modifiers: true)), .passThrough)
        XCTAssertEqual(nav.up(key("c", caret: 0, modifiers: true)), .passThrough)
    }

    func testNothingActsWhileAnIMEHasMarkedText() {
        XCTAssertEqual(nav.up(key("にほん", caret: 0, marked: true)), .passThrough)
        XCTAssertEqual(nav.up(key("", marked: true)), .passThrough)
        _ = nav.up(key())
        XCTAssertEqual(nav.down(key("c", marked: true)), .passThrough)
        XCTAssertEqual(nav.up(key("c", caret: 0, marked: true)), .passThrough)
    }

    func testNothingActsOnANonHumanKey() {
        XCTAssertEqual(nav.up(key(human: false)), .passThrough)
        _ = nav.up(key())
        XCTAssertEqual(nav.down(key("c", human: false)), .passThrough)
        XCTAssertEqual(nav.up(key("c", caret: 0, human: false)), .passThrough)
        XCTAssertTrue(nav.isNavigating, "a refused key changes nothing")
    }

    // MARK: A42 readline edits

    func testAnEditToARecalledEntryIsShownWhenYouComeBackAndTheStoredEntryIsUnchanged() {
        _ = nav.up(key())                                     // c
        XCTAssertEqual(shown(nav.up(key("c edited", caret: 0))), "b")
        XCTAssertEqual(shown(nav.down(key("b"))), "c edited", "Up then Down shows the edit")
        XCTAssertEqual(history, ["c", "b", "a"], "the stored entries never change")
    }

    func testEditingBackToTheOriginalForgetsTheEdit() {
        _ = nav.up(key())
        _ = nav.up(key("changed", caret: 0))
        _ = nav.down(key("b"))                                // c edited -> "changed"
        _ = nav.up(key("c", caret: 0))                        // edited back to the original
        XCTAssertEqual(shown(nav.down(key("b"))), "c")
    }

    func testEndingNavigationForgetsEditsAndTheDraft() {
        _ = nav.up(key("my draft", caret: 0))
        _ = nav.up(key("c edited", caret: 0))
        nav.end()
        XCTAssertFalse(nav.isNavigating)
        XCTAssertEqual(nav.down(key("x")), .passThrough)
        XCTAssertEqual(shown(nav.up(key("", caret: 0))), "c", "a fresh walk shows the stored entry, not the old edit")
        XCTAssertEqual(shown(nav.down(key("c"))), "", "and the new draft, not the old one")
    }

    // MARK: Snapshot

    func testAnEntrySentElsewhereMidWalkDoesNotShiftTheWalk() {
        _ = nav.up(key())                                     // c
        history = ["new"] + history                           // another window sent one
        XCTAssertEqual(shown(nav.up(key("c", caret: 0))), "b")
        XCTAssertEqual(shown(nav.down(key("b"))), "c")
    }

    // MARK: Announcements (A17)

    func testAnnouncementsSayWhereYouAreAndNeverQuoteAnEntry() {
        history = ["secret one", "secret two"]
        var spoken: [String] = []
        if case .show(_, let a) = nav.up(key()) { spoken.append(a) }
        if case .show(_, let a) = nav.up(key("secret one", caret: 0)) { spoken.append(a) }
        if case .show(_, let a) = nav.down(key("secret two")) { spoken.append(a) }
        XCTAssertEqual(Array(spoken.prefix(3)), ["History 1 of 2", "History 2 of 2", "History 1 of 2"])
        XCTAssertTrue(spoken.allSatisfy { !$0.contains("secret") })
        XCTAssertEqual(nav.position?.number, 1)
        XCTAssertEqual(nav.position?.total, 2)
    }

    // MARK: The take-back seam (S2)

    func testTheBeforeHistoryStepRunsFirstOnAnUpThatWouldStartNavigation() {
        var contexts: [ComposerUpContext] = []
        nav.upInterceptor = { contexts.append($0); return true }
        XCTAssertEqual(nav.up(key("", images: true)), .handled)
        XCTAssertEqual(contexts, [ComposerUpContext(text: "", hasDraftImages: true)])
        XCTAssertFalse(nav.isNavigating, "when it acts, history does not")
        nav.upInterceptor = { _ in false }
        XCTAssertEqual(shown(nav.up(key())), "c", "when it declines, Up recalls")
    }

    func testTheBeforeHistoryStepIsNotAskedForAGuardedKeyOrWhileNavigating() {
        var asked = 0
        nav.upInterceptor = { _ in asked += 1; return false }
        _ = nav.up(key(modifiers: true))
        _ = nav.up(key(marked: true))
        _ = nav.up(key(human: false))
        _ = nav.up(key("text", caret: 2))
        XCTAssertEqual(asked, 0)
        _ = nav.up(key())
        XCTAssertEqual(asked, 1)
        _ = nav.up(key("c", caret: 0))
        XCTAssertEqual(asked, 1, "already navigating")
    }
}
