import XCTest
import AppKit

// The queued-message chips above the composer (message queue S2): what a chip and the header say, the
// order and the collapse rule, the height the area may take, VoiceOver, and the rule that Edit and Remove
// act only for a person (`HumanGesture.permit`). Words are `QueuedMessageText` (pure); the rest drives the
// real `QueuedMessagesView` and `QueuedChipView` in a window.
//
// Acceptance criteria exercised: C2-3 (header and chip words), C2-4 (order, collapse, height), C2-7
// (Edit waits for an empty composer), C2-11 (VoiceOver), C2-14 (Edit on a chosen chip), C2-16 (human only),
// C2-18 (no Edit on an app message).

final class QueuedMessagesViewTests: MouseQueueTestCase {

    // MARK: Builders

    private func entry(_ id: String, text: String = "hello", kind: String = "typed", images: Int = 0,
                       command: Bool = false, label: String? = nil, canTakeBack: Bool? = nil) -> QueuedMessage {
        var json: [String: Any] = ["id": id, "kind": kind, "text": text, "image_count": images, "command": command,
                                   "can_take_back": canTakeBack ?? (kind == "typed")]
        if let label { json["app_label"] = label }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return QueuedMessage(try! JSONDecoder().decode(SessionQueueEntryWire.self, from: data))
    }

    private func typed(_ count: Int) -> [QueuedMessage] {
        (0..<count).map { entry("q-\($0 + 1)", text: "message \($0 + 1)") }
    }

    private struct Rig {
        let window: NSWindow
        let view: QueuedMessagesView
        var edited: Box<[String]>
        var removed: Box<[String]>
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// A view in an offscreen window, `permit` answering `.human` unless told otherwise.
    private func makeRig(entries: [QueuedMessage], width: CGFloat = 420, displayName: String = "Cody",
                         waitingForSignIn: Bool = false,
                         permit: ((NSView) -> HumanGestureVerdict)? = nil) -> Rig {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: width, height: 600))
        addTeardownBlock { window.close() }
        let view = QueuedMessagesView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        window.contentView!.addSubview(view)
        view.permit = permit ?? { _ in .human(sourcePid: nil, sourceState: nil) }
        let edited = Box<[String]>([]), removed = Box<[String]>([])
        view.onEdit = { edited.value.append($0.id) }
        view.onRemove = { removed.value.append($0.id) }
        view.setContent(entries: entries, displayName: displayName, waitingForSignIn: waitingForSignIn)
        layout(view)
        return Rig(window: window, view: view, edited: edited, removed: removed)
    }

    private func layout(_ view: QueuedMessagesView) {
        view.frame.size.height = max(view.preferredHeight, 1)
        view.layoutSubtreeIfNeeded()
    }

    private func key(_ code: UInt16, in window: NSWindow) -> NSEvent {
        GestureFixtures.key(in: window, characters: "x", keyCode: code)
    }

    // MARK: C2-3 the words

    func testTheHeaderNamesTheAgentAndTheCount() {
        XCTAssertEqual(QueuedMessageText.header(displayName: "Cody", count: 1, waitingForSignIn: false),
                       "Waiting for Cody to finish · 1 queued")
        XCTAssertEqual(QueuedMessageText.header(displayName: "Claudia", count: 12, waitingForSignIn: false),
                       "Waiting for Claudia to finish · 12 queued")
    }

    func testTheHeaderSaysSignInWhileTheSessionWaitsForOne() {
        XCTAssertEqual(QueuedMessageText.header(displayName: "Cody", count: 3, waitingForSignIn: true),
                       "Waiting for sign-in · 3 queued")
    }

    func testNoHeaderEverPromisesTheMessagesWillBeSentTogether() {
        for signIn in [false, true] {
            for count in [1, 2, 9] {
                let header = QueuedMessageText.header(displayName: "Cody", count: count, waitingForSignIn: signIn)
                XCTAssertFalse(header.lowercased().contains("sent together"), header)
                XCTAssertFalse(header.lowercased().contains("together"), header)
            }
        }
    }

    func testTheViewShowsTheHeaderForItsContent() {
        let rig = makeRig(entries: typed(2), displayName: "Archie")
        XCTAssertEqual(rig.view.headerText, "Waiting for Archie to finish · 2 queued")
        XCTAssertEqual(rig.view.headerLabel.stringValue, rig.view.headerText)

        rig.view.setContent(entries: typed(2), displayName: "Archie", waitingForSignIn: true)
        XCTAssertEqual(rig.view.headerText, "Waiting for sign-in · 2 queued")
    }

    func testAChipShowsATypedMessagesFirstLineAsIs() {
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "fix the picker")), "fix the picker")
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "   padded   ")), "padded")
    }

    func testALongFirstLineIsCutAtEightyCharactersWithAnEllipsis() {
        let exactly = String(repeating: "x", count: 80)
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: exactly)), exactly, "80 fits")
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: exactly + "y")), exactly + "…")
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: String(repeating: "z", count: 500))),
                       String(repeating: "z", count: 80) + "…")
    }

    func testExtraLinesAreCountedNotShown() {
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "first\nsecond")), "first (+1 line)")
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "first\nsecond\nthird\nfourth")), "first (+3 lines)")
    }

    func testImagesAreCounted() {
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "look", images: 1)), "look +1 image")
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "look", images: 3)), "look +3 images")
    }

    func testASlashCommandSaysItGetsItsOwnTurn() {
        XCTAssertEqual(QueuedMessageText.summary(entry("q", text: "/compact", command: true)), "/compact · own turn")
    }

    func testLinesImagesAndOwnTurnCombineInThatOrder() {
        let summary = QueuedMessageText.summary(entry("q", text: "/model haiku\nplease", images: 2, command: true))
        XCTAssertEqual(summary, "/model haiku (+1 line) +2 images · own turn")
    }

    func testAnAppMessageReadsAsItsOriginAndNotAsSomethingThePersonTyped() {
        XCTAssertTrue(QueuedMessageText.summary(entry("q", text: "Mother overview: PR 12", kind: "app", label: "mother_overview"))
            .hasPrefix("From Mother overview"))
        XCTAssertTrue(QueuedMessageText.summary(entry("q", text: "do the thing", kind: "app", label: "work_item"))
            .hasPrefix("From work item"))
        XCTAssertTrue(QueuedMessageText.summary(entry("q", text: "seed", kind: "app", label: "agent_seed"))
            .hasPrefix("From an agent"))
        XCTAssertTrue(QueuedMessageText.summary(entry("q", text: "x", kind: "app", label: "a_label_from_the_future"))
            .hasPrefix("From the app"), "an origin this build has no word for still says it is the app's")
        XCTAssertTrue(QueuedMessageText.summary(entry("q", text: "x", kind: "app", label: nil)).hasPrefix("From the app"))
    }

    func testATypedMessageHasNoOriginLabel() {
        XCTAssertNil(QueuedMessageText.originLabel(entry("q")))
        XCTAssertEqual(QueuedMessageText.originLabel(entry("q", kind: "app", label: "work_item")), "From work item")
    }

    func testTheChipLabelShowsTheSummaryAndHoverShowsTheWholeMessage() {
        let long = String(repeating: "word ", count: 60)
        let rig = makeRig(entries: [entry("q-1", text: long)])
        let chip = rig.view.chips[0]
        XCTAssertEqual(chip.label.stringValue, QueuedMessageText.summary(entry("q-1", text: long)))
        XCTAssertEqual(chip.label.toolTip, long)
    }

    // MARK: C2-4 order, collapse, height

    func testTheOldestChipIsAtTheTopAndTheNewestIsNextToTheComposer() {
        let rig = makeRig(entries: typed(3))

        XCTAssertEqual(rig.view.chips.map(\.entry.id), ["q-1", "q-2", "q-3"])
        let tops = rig.view.chips.map { rig.view.convert($0.bounds, from: $0).minY }
        XCTAssertEqual(tops, tops.sorted(), "the view is flipped: a smaller y is higher up")
        XCTAssertLessThan(tops[0], tops[1])
        XCTAssertLessThan(tops[1], tops[2])
    }

    func testUpToThreeChipsAreAllShownWithNoShowMoreButton() {
        for count in 1...3 {
            let rig = makeRig(entries: typed(count))
            XCTAssertEqual(rig.view.chips.count, count)
            XCTAssertTrue(rig.view.showMoreButton.isHidden, "\(count) chips")
            XCTAssertEqual(rig.view.hiddenCount, 0)
        }
    }

    func testMoreThanThreeShowTheNewestThreeAndShowNMore() {
        let rig = makeRig(entries: typed(5))

        XCTAssertEqual(rig.view.chips.map(\.entry.id), ["q-3", "q-4", "q-5"], "the newest three, oldest of them first")
        XCTAssertFalse(rig.view.showMoreButton.isHidden)
        XCTAssertEqual(rig.view.showMoreButton.title, "Show 2 more")
        XCTAssertEqual(rig.view.hiddenCount, 2)
        XCTAssertEqual(rig.view.headerText, "Waiting for Cody to finish · 5 queued", "the header counts every message")
    }

    func testShowMoreExpandsToEveryChipAndShowFewerCollapsesAgain() {
        let rig = makeRig(entries: typed(5))

        rig.view.showMoreButton.performClick(nil)
        XCTAssertTrue(rig.view.isExpanded)
        XCTAssertEqual(rig.view.chips.map(\.entry.id), ["q-1", "q-2", "q-3", "q-4", "q-5"])
        XCTAssertEqual(rig.view.showMoreButton.title, "Show fewer")

        rig.view.showMoreButton.performClick(nil)
        XCTAssertFalse(rig.view.isExpanded)
        XCTAssertEqual(rig.view.chips.map(\.entry.id), ["q-3", "q-4", "q-5"])
        XCTAssertEqual(rig.view.showMoreButton.title, "Show 2 more")
    }

    func testTheQueueShrinkingToThreeOrFewerCollapsesAnExpandedList() {
        let rig = makeRig(entries: typed(6))
        rig.view.toggleExpanded()
        XCTAssertEqual(rig.view.chips.count, 6)

        rig.view.setContent(entries: typed(3), displayName: "Cody", waitingForSignIn: false)

        XCTAssertFalse(rig.view.isExpanded)
        XCTAssertEqual(rig.view.chips.count, 3)
        XCTAssertTrue(rig.view.showMoreButton.isHidden)
    }

    func testTheChipsNumbersContinueFromTheHiddenOnes() {
        let rig = makeRig(entries: typed(5))
        XCTAssertEqual(rig.view.chips.map(\.index), [3, 4, 5])
        XCTAssertEqual(rig.view.chips.map(\.total), [5, 5, 5])
    }

    func testTheAreaIsZeroHeightAndHiddenWithNothingQueued() {
        let rig = makeRig(entries: [])
        XCTAssertEqual(rig.view.preferredHeight, 0)
        XCTAssertTrue(rig.view.isHidden)
        XCTAssertTrue(rig.view.chips.isEmpty)

        rig.view.setContent(entries: typed(1), displayName: "Cody", waitingForSignIn: false)
        XCTAssertGreaterThan(rig.view.preferredHeight, 0)
        XCTAssertFalse(rig.view.isHidden)

        rig.view.setContent(entries: [], displayName: "Cody", waitingForSignIn: false)
        XCTAssertEqual(rig.view.preferredHeight, 0)
        XCTAssertTrue(rig.view.isHidden)
    }

    func testThePreferredHeightNeverExceedsTheMaximumHoweverManyChipsAreShown() {
        let rig = makeRig(entries: typed(1))
        for maxHeight in [60, 90, 140, 200, 333] as [CGFloat] {
            for count in [1, 3, 4, 10, 50] {
                for expanded in [false, true] {
                    rig.view.setContent(entries: typed(count), displayName: "Cody", waitingForSignIn: false)
                    rig.view.maxHeight = maxHeight
                    if rig.view.isExpanded != expanded, count > QueuedMessagesView.collapsedLimit { rig.view.toggleExpanded() }
                    XCTAssertLessThanOrEqual(rig.view.preferredHeight, maxHeight,
                                             "max \(maxHeight), \(count) chips, expanded \(rig.view.isExpanded)")
                    XCTAssertGreaterThan(rig.view.preferredHeight, 0)
                }
            }
        }
    }

    func testAnExpandedListGrowsWithItsChipsUntilTheMaximumAndNoFurther() {
        let rig = makeRig(entries: typed(4))
        rig.view.maxHeight = 400
        rig.view.toggleExpanded()
        let four = rig.view.preferredHeight
        rig.view.setContent(entries: typed(8), displayName: "Cody", waitingForSignIn: false)
        XCTAssertTrue(rig.view.isExpanded, "growing the queue keeps the list open")
        let eight = rig.view.preferredHeight
        XCTAssertGreaterThan(eight, four, "more chips want more room")

        rig.view.maxHeight = eight - 50
        XCTAssertEqual(rig.view.preferredHeight, eight - 50, "capped: the list scrolls instead")
        rig.view.setContent(entries: typed(60), displayName: "Cody", waitingForSignIn: false)
        XCTAssertLessThanOrEqual(rig.view.preferredHeight, eight - 50)
    }

    func testTheHostIsToldWhenTheHeightItShouldGiveTheAreaChanges() {
        let rig = makeRig(entries: [])
        var calls = 0
        rig.view.onHeightChange = { calls += 1 }

        rig.view.setContent(entries: typed(1), displayName: "Cody", waitingForSignIn: false)
        XCTAssertGreaterThan(calls, 0, "from nothing to one chip")
        let afterOne = calls

        rig.view.setContent(entries: typed(2), displayName: "Cody", waitingForSignIn: false)
        XCTAssertGreaterThan(calls, afterOne, "a second chip")

        let afterTwo = calls
        rig.view.setContent(entries: [], displayName: "Cody", waitingForSignIn: false)
        XCTAssertGreaterThan(calls, afterTwo, "back to nothing")
    }

    func testRaisingTheMaximumShowsAViewThatWasHiddenForWantOfRoom() {
        let rig = makeRig(entries: [])
        rig.view.maxHeight = 0

        rig.view.setContent(entries: typed(2), displayName: "Cody", waitingForSignIn: false)
        XCTAssertEqual(rig.view.preferredHeight, 0, "no room at all")
        XCTAssertTrue(rig.view.isHidden)

        rig.view.maxHeight = 200

        XCTAssertGreaterThan(rig.view.preferredHeight, 0)
        XCTAssertFalse(rig.view.isHidden, "the chips must show as soon as there is room for them")
    }

    func testLoweringTheMaximumToNothingHidesTheViewAndRaisingItAgainShowsIt() {
        let rig = makeRig(entries: typed(2))
        XCTAssertFalse(rig.view.isHidden)

        rig.view.maxHeight = 0
        XCTAssertTrue(rig.view.isHidden)
        XCTAssertEqual(rig.view.preferredHeight, 0)

        rig.view.maxHeight = 150
        XCTAssertFalse(rig.view.isHidden)
        XCTAssertGreaterThan(rig.view.preferredHeight, 0)
    }

    func testRaisingTheMaximumShowsAStatusLineThatWasHiddenForWantOfRoom() {
        let rig = makeRig(entries: [])
        rig.view.maxHeight = 0
        rig.view.setStatus("Already sent")
        XCTAssertTrue(rig.view.isHidden)

        rig.view.maxHeight = 100

        XCTAssertFalse(rig.view.isHidden)
        XCTAssertGreaterThan(rig.view.preferredHeight, 0)
    }

    func testChangingTheMaximumWithNothingToShowKeepsTheViewHidden() {
        let rig = makeRig(entries: [])
        rig.view.maxHeight = 50
        rig.view.maxHeight = 300
        XCTAssertTrue(rig.view.isHidden)
        XCTAssertEqual(rig.view.preferredHeight, 0)
    }

    func testChangingTheMaximumKeepsTheViewVisibleWhileThereIsRoom() {
        let rig = makeRig(entries: typed(2))
        for max in [400, 120, 90, 500] as [CGFloat] {
            rig.view.maxHeight = max
            XCTAssertFalse(rig.view.isHidden, "max \(max)")
            XCTAssertLessThanOrEqual(rig.view.preferredHeight, max)
        }
    }

    func testAStatusLineTakesRoomAndGoesAwayAgain() {
        let rig = makeRig(entries: typed(1))
        let without = rig.view.preferredHeight

        rig.view.setStatus("Already sent")

        XCTAssertEqual(rig.view.statusText, "Already sent")
        XCTAssertFalse(rig.view.statusLabel.isHidden)
        XCTAssertEqual(rig.view.statusLabel.stringValue, "Already sent")
        XCTAssertGreaterThan(rig.view.preferredHeight, without)

        rig.view.setStatus(nil)
        XCTAssertNil(rig.view.statusText)
        XCTAssertTrue(rig.view.statusLabel.isHidden)
        XCTAssertEqual(rig.view.preferredHeight, without)
    }

    func testAStatusLineShowsEvenWhenNothingIsQueuedAndTheHeightStillRespectsTheMaximum() {
        let rig = makeRig(entries: [])
        rig.view.maxHeight = 40

        rig.view.setStatus("Couldn't reach Nostromo")

        XCTAssertGreaterThan(rig.view.preferredHeight, 0, "the person must see why nothing happened")
        XCTAssertLessThanOrEqual(rig.view.preferredHeight, 40)
        XCTAssertFalse(rig.view.isHidden)

        rig.view.setStatus(nil)
        XCTAssertEqual(rig.view.preferredHeight, 0)
    }

    // MARK: C2-7 Edit waits for an empty composer

    func testEditIsDisabledWhileTheComposerHasADraftAndSaysWhy() {
        let rig = makeRig(entries: typed(2))
        rig.view.composerHasDraft = true

        for chip in rig.view.chips {
            XCTAssertFalse(chip.editButton.isEnabled)
            XCTAssertEqual(chip.editButton.toolTip, "Send or clear what you're typing first")
            XCTAssertEqual(chip.editButton.accessibilityHelp(), "Send or clear what you're typing first")
            XCTAssertFalse(chip.edit(), "a refused Edit reports that it did nothing")
        }
        XCTAssertTrue(rig.edited.value.isEmpty)
    }

    func testEditComesBackWhenTheDraftIsGone() {
        let rig = makeRig(entries: typed(1))
        rig.view.composerHasDraft = true
        rig.view.composerHasDraft = false

        let chip = rig.view.chips[0]
        XCTAssertTrue(chip.editButton.isEnabled)
        XCTAssertEqual(chip.editButton.toolTip, "Edit")
        XCTAssertTrue(chip.edit())
        XCTAssertEqual(rig.edited.value, ["q-1"])
    }

    func testChipsBuiltWhileTheComposerHasADraftStartDisabled() {
        let rig = makeRig(entries: typed(1))
        rig.view.composerHasDraft = true

        rig.view.setContent(entries: typed(3), displayName: "Cody", waitingForSignIn: false)

        XCTAssertTrue(rig.view.chips.allSatisfy { !$0.editButton.isEnabled })
    }

    func testRemoveStillWorksWhileTheComposerHasADraft() {
        let rig = makeRig(entries: typed(2))
        rig.view.composerHasDraft = true

        XCTAssertTrue(rig.view.chips[0].remove())

        XCTAssertEqual(rig.removed.value, ["q-1"])
    }

    func testTheDraftExplanationIsExactlyTheDocumentedWords() {
        XCTAssertEqual(QueuedMessageText.editDisabledReason, "Send or clear what you're typing first")
    }

    // MARK: C2-18 an app message cannot be edited

    func testAnAppChipHasNoEditButtonAndEditDoesNothing() {
        let rig = makeRig(entries: [entry("q-1", text: "Mother overview: PR 12", kind: "app", label: "mother_overview")])
        let chip = rig.view.chips[0]

        XCTAssertTrue(chip.editButton.isHidden)
        XCTAssertFalse(chip.edit())
        XCTAssertTrue(rig.edited.value.isEmpty)
        // Deliberate behaviour change (was: "it can still be removed"): the daemon answers `not_allowed` to a
        // remove of an app message and a remove has no answer to show, so the control is not offered.
        XCTAssertTrue(chip.removeButton.isHidden)
        XCTAssertFalse(chip.remove())
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAChipThePersonCannotRemoveOffersNoRemoveAnyWayAndNeverFiresOnRemove() {
        let rig = makeRig(entries: [entry("q-1", text: "Mother overview", kind: "app", label: "mother_overview"),
                                    entry("q-2", canTakeBack: false)])
        for chip in rig.view.chips {
            XCTAssertTrue(chip.removeButton.isHidden)
            XCTAssertNil(action("Remove", of: chip))
            XCTAssertFalse(chip.remove())
            chip.removeButton.performClick(nil)
            chip.keyDown(with: key(51, in: rig.window))
        }
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAKeyboardFocusedChipReportsAFocusRingAroundItsBody() throws {
        let rig = makeRig(entries: typed(1))
        let chip = rig.view.chips[0]
        XCTAssertTrue(chip.acceptsFirstResponder)
        XCTAssertEqual(chip.focusRingMaskBounds, chip.bounds)
        XCTAssertFalse(chip.bounds.isEmpty)

        let image = NSImage(size: chip.bounds.size)
        image.lockFocus()
        chip.drawFocusRingMask()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        XCTAssertGreaterThan(center.alphaComponent, 0.5, "the mask must cover the chip")
    }

    func testATypedChipTheDaemonSaysCannotBeTakenBackHasNoEdit() {
        let rig = makeRig(entries: [entry("q-1", canTakeBack: false)])
        XCTAssertTrue(rig.view.chips[0].editButton.isHidden)
        XCTAssertFalse(rig.view.chips[0].edit())
    }

    func testATypedChipHasEditAndRemove() {
        let rig = makeRig(entries: typed(1))
        let chip = rig.view.chips[0]
        XCTAssertFalse(chip.editButton.isHidden)
        XCTAssertFalse(chip.removeButton.isHidden)
        chip.editButton.performClick(nil)
        chip.removeButton.performClick(nil)
        XCTAssertEqual(rig.edited.value, ["q-1"])
        XCTAssertEqual(rig.removed.value, ["q-1"])
    }

    // MARK: Keyboard

    func testReturnEnterAndSpaceEditTheFocusedChip() {
        for code: UInt16 in [36, 76, 49] {
            let rig = makeRig(entries: typed(2))
            rig.view.chips[1].keyDown(with: key(code, in: rig.window))
            XCTAssertEqual(rig.edited.value, ["q-2"], "key code \(code)")
            XCTAssertTrue(rig.removed.value.isEmpty, "key code \(code)")
        }
    }

    func testDeleteAndForwardDeleteRemoveTheFocusedChip() {
        for code: UInt16 in [51, 117] {
            let rig = makeRig(entries: typed(2))
            rig.view.chips[0].keyDown(with: key(code, in: rig.window))
            XCTAssertEqual(rig.removed.value, ["q-1"], "key code \(code)")
            XCTAssertTrue(rig.edited.value.isEmpty, "key code \(code)")
        }
    }

    func testReturnOnAnAppChipDoesNothingAndNeitherDoesDelete() {
        // Deliberate behaviour change (was: Delete removes it): the daemon refuses to remove an app message.
        let rig = makeRig(entries: [entry("q-1", kind: "app", label: "work_item")])
        rig.view.chips[0].keyDown(with: key(36, in: rig.window))
        XCTAssertTrue(rig.edited.value.isEmpty)
        rig.view.chips[0].keyDown(with: key(51, in: rig.window))
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testReturnOnAChipWhileTheComposerHasADraftDoesNothing() {
        let rig = makeRig(entries: typed(1))
        rig.view.composerHasDraft = true
        rig.view.chips[0].keyDown(with: key(36, in: rig.window))
        XCTAssertTrue(rig.edited.value.isEmpty)
    }

    func testAClickOnTheChipBodyEdits() {
        let rig = makeRig(entries: typed(1))
        rig.view.chips[0].mouseDown(with: GestureFixtures.mouse(.leftMouseDown, in: rig.window))
        XCTAssertEqual(rig.edited.value, ["q-1"])
    }

    func testAChipTakesKeyboardFocus() {
        let rig = makeRig(entries: typed(1))
        XCTAssertTrue(rig.view.chips[0].acceptsFirstResponder)
    }

    // MARK: C2-11 VoiceOver

    func testTheGroupIsLabelledWithTheNumberOfQueuedMessages() throws {
        let rig = makeRig(entries: typed(3))
        XCTAssertEqual(rig.view.accessibilityLabel(), "Queued messages, 3")
        let group = try XCTUnwrap(allSubviews(of: rig.view).first { $0.accessibilityLabel() == "Queued messages, 3" && $0 !== rig.view })
        XCTAssertTrue(group.isAccessibilityElement())
        XCTAssertEqual(group.accessibilityRole(), .group)

        rig.view.setContent(entries: typed(1), displayName: "Cody", waitingForSignIn: false)
        XCTAssertEqual(rig.view.accessibilityLabel(), "Queued messages, 1")
    }

    func testTheGroupCountsHiddenChipsToo() {
        let rig = makeRig(entries: typed(7))
        XCTAssertEqual(rig.view.accessibilityLabel(), "Queued messages, 7")
    }

    func testEachChipIsOneElementWithItsPositionAndTheFullText() {
        let long = String(repeating: "detail ", count: 40)
        let rig = makeRig(entries: [entry("q-1", text: "first"), entry("q-2", text: long, images: 1), entry("q-3", text: "third")])

        let chip = rig.view.chips[1]
        XCTAssertTrue(chip.isAccessibilityElement())
        XCTAssertEqual(chip.accessibilityRole(), .group)
        XCTAssertEqual(chip.accessibilityLabel(), "Queued message 2 of 3: \(long), 1 image")
        XCTAssertEqual(rig.view.chips[0].accessibilityLabel(), "Queued message 1 of 3: first")
        XCTAssertEqual(rig.view.chips[2].accessibilityLabel(), "Queued message 3 of 3: third")
    }

    func testTheChipLabelPluralisesImagesAndMentionsAnOwnTurnCommand() {
        XCTAssertEqual(QueuedMessageText.accessibilityLabel(entry("q", text: "look", images: 2), index: 1, total: 1),
                       "Queued message 1 of 1: look, 2 images")
        XCTAssertEqual(QueuedMessageText.accessibilityLabel(entry("q", text: "/compact", command: true), index: 1, total: 2),
                       "Queued message 1 of 2: /compact, own turn")
    }

    func testAnAppChipIsLabelledWithItsOriginAndFullText() {
        let label = QueuedMessageText.accessibilityLabel(
            entry("q", text: "Mother overview: PR 12 is ready", kind: "app", label: "mother_overview"), index: 1, total: 1)
        XCTAssertTrue(label.hasPrefix("Queued message 1 of 1: "))
        XCTAssertTrue(label.contains("From Mother overview"))
        XCTAssertTrue(label.contains("Mother overview: PR 12 is ready"))
    }

    func testNumbersInTheChipLabelsContinueFromTheHiddenOnes() {
        let rig = makeRig(entries: typed(5))
        XCTAssertEqual(rig.view.chips.map { $0.accessibilityLabel() ?? "" },
                       ["Queued message 3 of 5: message 3", "Queued message 4 of 5: message 4",
                        "Queued message 5 of 5: message 5"])
    }

    func testTheShowMoreButtonSaysWhatItDoes() {
        let rig = makeRig(entries: typed(5))
        XCTAssertEqual(rig.view.showMoreButton.accessibilityLabel(), "Show 2 more queued messages")
        rig.view.toggleExpanded()
        XCTAssertEqual(rig.view.showMoreButton.accessibilityLabel(), "Show fewer queued messages")
    }

    private func actions(of chip: QueuedChipView) -> [String] {
        (chip.accessibilityCustomActions() ?? []).map(\.name)
    }

    private func action(_ name: String, of chip: QueuedChipView) -> NSAccessibilityCustomAction? {
        (chip.accessibilityCustomActions() ?? []).first { $0.name == name }
    }

    func testATypedChipOffersEditAndRemoveAsAccessibilityActions() {
        let rig = makeRig(entries: typed(1))
        XCTAssertEqual(Set(actions(of: rig.view.chips[0])), ["Edit", "Remove"])
    }

    func testAnAppChipOffersNoAccessibilityActions() {
        // Deliberate behaviour change (was: only "Remove"): the daemon refuses to remove an app message.
        let rig = makeRig(entries: [entry("q-1", kind: "app", label: "agent_seed")])
        XCTAssertEqual(actions(of: rig.view.chips[0]), [])
    }

    func testThePerformedAccessibilityActionsEditAndRemoveForAPerson() {
        let rig = makeRig(entries: typed(2))
        let chip = rig.view.chips[1]

        XCTAssertEqual(action("Edit", of: chip)?.handler?(), true)
        XCTAssertEqual(action("Remove", of: chip)?.handler?(), true)

        XCTAssertEqual(rig.edited.value, ["q-2"])
        XCTAssertEqual(rig.removed.value, ["q-2"])
    }

    func testAnAccessibilityEditDoesNothingWhileTheComposerHasADraft() {
        let rig = makeRig(entries: typed(1))
        rig.view.composerHasDraft = true
        let chip = rig.view.chips[0]

        if let edit = action("Edit", of: chip) {
            XCTAssertNotEqual(edit.handler?(), true)
        }
        XCTAssertFalse(chip.accessibilityPerformPress())
        XCTAssertTrue(rig.edited.value.isEmpty)
        XCTAssertEqual(chip.accessibilityHelp(), "Send or clear what you're typing first")
    }

    func testPressingAChipThroughAccessibilityEditsIt() {
        let rig = makeRig(entries: typed(1))
        XCTAssertTrue(rig.view.chips[0].accessibilityPerformPress())
        XCTAssertEqual(rig.edited.value, ["q-1"])
    }

    // MARK: C2-16 the human gate

    private static let refusals: [HumanGestureRefusal] = [.appControl, .accessibilityPress, .notAUserEvent, .staleEvent, .futureEvent]

    /// Every way a chip can be acted on.
    private func actEveryWay(_ rig: Rig) {
        let chip = rig.view.chips[0]
        _ = chip.edit()
        _ = chip.remove()
        chip.editButton.performClick(nil)
        chip.removeButton.performClick(nil)
        chip.keyDown(with: key(36, in: rig.window))
        chip.keyDown(with: key(51, in: rig.window))
        chip.mouseDown(with: GestureFixtures.mouse(.leftMouseDown, in: rig.window))
        _ = chip.accessibilityPerformPress()
        _ = action("Edit", of: chip)?.handler?()
        _ = action("Remove", of: chip)?.handler?()
    }

    func testARefusedGestureEditsAndRemovesNothingNoMatterHowItArrives() {
        for reason in Self.refusals {
            let rig = makeRig(entries: typed(2), permit: { _ in .refused(reason: reason) })

            XCTAssertFalse(rig.view.chips[0].edit(), "\(reason)")
            XCTAssertFalse(rig.view.chips[0].remove(), "\(reason)")
            actEveryWay(rig)

            XCTAssertTrue(rig.edited.value.isEmpty, "\(reason): onEdit must never fire")
            XCTAssertTrue(rig.removed.value.isEmpty, "\(reason): onRemove must never fire")
        }
    }

    func testAnAppChipsRemoveIsAlsoHumanOnly() {
        for reason in Self.refusals {
            let rig = makeRig(entries: [entry("q-1", kind: "app", label: "work_item")], permit: { _ in .refused(reason: reason) })
            XCTAssertFalse(rig.view.chips[0].remove(), "\(reason)")
            XCTAssertTrue(rig.removed.value.isEmpty, "\(reason)")
        }
    }

    func testAHumanGestureEditsAndRemoves() {
        let rig = makeRig(entries: typed(2), permit: { _ in .human(sourcePid: 1, sourceState: 2) })

        XCTAssertTrue(rig.view.chips[0].edit())
        XCTAssertTrue(rig.view.chips[1].remove())

        XCTAssertEqual(rig.edited.value, ["q-1"])
        XCTAssertEqual(rig.removed.value, ["q-2"])
    }

    func testTheGateIsAskedAboutTheChipThatWasActedOn() {
        var asked: [NSView] = []
        let rig = makeRig(entries: typed(2), permit: { asked.append($0); return .human(sourcePid: nil, sourceState: nil) })

        _ = rig.view.chips[1].edit()

        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first === rig.view.chips[1])
    }

    // The same rule through the real `HumanGesture.permit`, with real, synthesised, stale and
    // future-stamped events, and with no event at all (an Accessibility press).

    private func realGate(_ event: @escaping () -> NSEvent?) -> (NSView) -> HumanGestureVerdict {
        { HumanGesture.permit(event(), control: $0, voiceOverEnabled: { false }) }
    }

    func testARealFreshKeyPressInTheChipsWindowEdits() {
        var window: NSWindow!
        let rig = makeRig(entries: typed(1), permit: realGate { GestureFixtures.key(in: window, characters: "\r", keyCode: 36) })
        window = rig.window

        XCTAssertTrue(rig.view.chips[0].edit())
        XCTAssertEqual(rig.edited.value, ["q-1"])
    }

    func testAnEventStampedByAppControlNeverEditsOrRemoves() throws {
        var window: NSWindow!
        var event: NSEvent?
        let rig = makeRig(entries: typed(1), permit: realGate { event })
        window = rig.window
        event = try GestureFixtures.marked(GestureFixtures.key(in: window, characters: "\r", keyCode: 36))

        XCTAssertFalse(rig.view.chips[0].edit())
        XCTAssertFalse(rig.view.chips[0].remove())
        XCTAssertTrue(rig.edited.value.isEmpty)
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAnEventWhileAppControlRunsARequestNeverEditsOrRemoves() {
        var window: NSWindow!
        let rig = makeRig(entries: typed(1), permit: realGate { GestureFixtures.key(in: window, characters: "\r", keyCode: 36) })
        window = rig.window

        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }

        XCTAssertFalse(rig.view.chips[0].edit())
        XCTAssertFalse(rig.view.chips[0].remove())
        XCTAssertTrue(rig.edited.value.isEmpty)
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAStaleOrFutureStampedEventNeverEditsOrRemoves() {
        let now = ProcessInfo.processInfo.systemUptime
        for (label, stamp) in [("stale", now - 10), ("future", now + 10)] {
            var window: NSWindow!
            let rig = makeRig(entries: typed(1), permit: realGate {
                GestureFixtures.key(in: window, characters: "\r", keyCode: 36, timestamp: stamp)
            })
            window = rig.window

            XCTAssertFalse(rig.view.chips[0].edit(), label)
            XCTAssertFalse(rig.view.chips[0].remove(), label)
            XCTAssertTrue(rig.edited.value.isEmpty, label)
            XCTAssertTrue(rig.removed.value.isEmpty, label)
        }
    }

    func testNoEventAtAllIsAnAccessibilityPressFromAnotherProcessAndDoesNothing() {
        let rig = makeRig(entries: typed(1), permit: realGate { nil })

        XCTAssertFalse(rig.view.chips[0].edit())
        XCTAssertFalse(rig.view.chips[0].remove())
        XCTAssertFalse(rig.view.chips[0].accessibilityPerformPress())
        XCTAssertTrue(rig.edited.value.isEmpty)
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAKeyEventOfAnotherWindowNeverEditsOrRemoves() {
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let rig = makeRig(entries: typed(1), permit: realGate { GestureFixtures.key(in: other, characters: "\r", keyCode: 36) })

        XCTAssertFalse(rig.view.chips[0].edit())
        XCTAssertFalse(rig.view.chips[0].remove())
        XCTAssertTrue(rig.edited.value.isEmpty)
        XCTAssertTrue(rig.removed.value.isEmpty)
    }

    func testAMouseEventNotMadeByAPersonsClickOrKeyNeverEditsOrRemoves() {
        var window: NSWindow!
        let rig = makeRig(entries: typed(1), permit: realGate { GestureFixtures.other(in: window) })
        window = rig.window

        XCTAssertFalse(rig.view.chips[0].edit())
        XCTAssertFalse(rig.view.chips[0].remove())
    }

    // MARK: Helpers

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}

// MARK: M3-15 "sent together" (merged turns)

extension QueuedMessagesViewTests {

    private func mergedEntry(_ id: String, group: Int?) -> QueuedMessage {
        var json: [String: Any] = ["id": id, "kind": "typed", "text": "text \(id)", "image_count": 0,
                                   "command": false, "can_take_back": true]
        if let group { json["merge_group"] = group }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return QueuedMessage(try! JSONDecoder().decode(SessionQueueEntryWire.self, from: data))
    }

    private func headerOf(_ entries: [QueuedMessage], signIn: Bool = false) -> (text: String, label: String?) {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 420, height: 600))
        addTeardownBlock { window.close() }
        let view = QueuedMessagesView(frame: NSRect(x: 0, y: 0, width: 420, height: 10))
        window.contentView!.addSubview(view)
        view.setContent(entries: entries, displayName: "Cody", waitingForSignIn: signIn)
        return (view.headerText, view.headerLabel.accessibilityLabel())
    }

    func testTheHeaderSaysSentTogetherExactlyWhenAnEntryHasAMergeGroup() {
        let merging = headerOf([mergedEntry("a", group: 1), mergedEntry("b", group: 1)])
        XCTAssertEqual(merging.text, "Waiting for Cody to finish · 2 queued · sent together")
        XCTAssertEqual(merging.label, merging.text, "VoiceOver reads the suffix too")
    }

    func testASingleMessageAndAGateClosedQueueHaveNoSuffix() {
        XCTAssertEqual(headerOf([mergedEntry("a", group: nil)]).text, "Waiting for Cody to finish · 1 queued")
        XCTAssertEqual(headerOf([mergedEntry("a", group: nil), mergedEntry("b", group: nil)]).text,
                       "Waiting for Cody to finish · 2 queued")
    }

    func testDuringASignInHoldTheSuffixComesOnlyFromEntriesBehindIt() {
        XCTAssertEqual(headerOf([mergedEntry("a", group: nil), mergedEntry("b", group: nil)], signIn: true).text,
                       "Waiting for sign-in · 2 queued")
        XCTAssertEqual(headerOf([mergedEntry("a", group: 1), mergedEntry("b", group: 1)], signIn: true).text,
                       "Waiting for sign-in · 2 queued · sent together")
    }

    func testTheMergeGroupDecodesAndAnOldFrameWithoutItDoesToo() throws {
        let with = try JSONDecoder().decode(SessionQueueEntryWire.self, from: Data(
            #"{"id":"q1","kind":"typed","text":"x","image_count":0,"command":false,"can_take_back":true,"merge_group":2}"#.utf8))
        XCTAssertEqual(with.mergeGroup, 2)
        let without = try JSONDecoder().decode(SessionQueueEntryWire.self, from: Data(
            #"{"id":"q1","kind":"typed","text":"x","image_count":0,"command":false,"can_take_back":true}"#.utf8))
        XCTAssertNil(without.mergeGroup)
    }
}
