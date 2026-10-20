import XCTest
import AppKit
import NostromoKit

// AP2a: the scroll-safety gate for the approval card (PRD "Scroll and focus safety", criterion 36).
//
// Every event the card can cause runs inside `SafetyRig.assertNoMove`, in a pane that is following the
// tail and in one scrolled up into the middle of the transcript, with a REAL `ReplInputBar` holding
// focus and partly typed text. The gate asserts the transcript's first visible line moved at most 1 pt
// (and a following pane kept its bottom at 0), and that the composer's height, first responder, text
// and selection are untouched.
//
// The card is an `ApprovalOverlayHost` laid over the rig's scroll view the way `ReplView` does it:
// above the jump-to-latest overlay, pinned to the scroll view's four edges. It must never change the
// scroll view's or the input bar's frames.
//
// "The app did not activate" is not testable in a unit test; the first-responder assertions here and the
// source scan in `ApprovalSourceScanTests` stand for it.
//
// `ScrollSafetyGateToleranceTests` at the bottom pins two properties of the gate itself (B27).

final class ApprovalScrollSafetyTests: XCTestCase {

    private struct Pane {
        let rig: SafetyRig
        let recorder: ApprovalRecorder
        let store: ApprovalStore
        let host: ApprovalOverlayHost
    }

    /// A rig with an approval host over it. `permit` is a person's by default.
    private func pane(following: Bool, reduceMotion: Bool = true) -> Pane {
        let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let host = ApprovalOverlayHost(tag: "cody-1", store: store, windowID: { "w-gate" },
                                       permit: ApprovalCardHarness.humanPermit, reduceMotion: { reduceMotion })
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = rig.window.contentView!
        content.addSubview(host, positioned: .above, relativeTo: rig.overlay)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: rig.scrollView.topAnchor),
            host.leadingAnchor.constraint(equalTo: rig.scrollView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: rig.scrollView.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: rig.scrollView.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return Pane(rig: rig, recorder: recorder, store: store, host: host)
    }

    private func settle(_ pane: Pane) {
        pane.rig.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The card, with the transcript pane's frames untouched and the card inside the pane, above its bottom.
    private func assertCardFloatsInsideThePane(_ pane: Pane, scrollFrame: NSRect, barFrame: NSRect, name: String,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let card = try XCTUnwrap(pane.host.card, "\(name): there is a card", file: file, line: line)
        let cardRect = card.convert(card.bounds, to: nil)
        let scrollRect = pane.rig.scrollView.convert(pane.rig.scrollView.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(cardRect.minY, scrollRect.minY + ApprovalOverlayHost.bottomInset - 0.5,
                                    "\(name): the card sits above the bottom of the transcript", file: file, line: line)
        XCTAssertLessThanOrEqual(cardRect.maxY, scrollRect.maxY + 0.5, "\(name): and inside it", file: file, line: line)
        XCTAssertLessThanOrEqual(cardRect.height, scrollRect.height * ApprovalOverlayHost.maxHeightFraction + 0.5,
                                 "\(name): at most 60% of the pane", file: file, line: line)
        XCTAssertEqual(pane.rig.scrollView.frame, scrollFrame, "\(name): the scroll view's frame did not change", file: file, line: line)
        XCTAssertEqual(pane.rig.inputBar.frame, barFrame, "\(name): the input bar's frame did not change", file: file, line: line)
        XCTAssertTrue(pane.rig.window.firstResponder === pane.rig.textView, "\(name): the composer still has focus", file: file, line: line)
        XCTAssertEqual(pane.rig.textView.string, SafetyRig.typedText, "\(name): the typed text is untouched", file: file, line: line)
        XCTAssertEqual(pane.rig.textView.selectedRange(), SafetyRig.typedSelection, "\(name): so is the selection", file: file, line: line)
    }

    /// Put a card on screen outside the gate (setup for the events that follow).
    private func arrive(_ request: ApprovalRequestWire, in pane: Pane) throws -> ApprovalCardView {
        pane.store.handle(.request(request))
        settle(pane)
        return try XCTUnwrap(pane.host.card, "the request produced a card")
    }

    // MARK: A card arrives

    func testACardArrivingMovesNothingAndTakesNoFocus() throws {
        let request = try ApprovalTestRequests.compound(description: "Clean build outputs")
        for following in [true, false] {
            let p = pane(following: following)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            XCTAssertNil(p.host.card, "precondition")

            p.rig.assertNoMove("a card arrives (following: \(following))", following: following) {
                p.store.handle(.request(request))
            }

            try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "arrival (following: \(following))")
            XCTAssertEqual(p.host.listings.first?.requestID, "req-1")
        }
    }

    func testACardForAThreeHundredLineInputArrivesWithoutMovingAnything() throws {
        let request = try ApprovalTestRequests.heredoc300()
        for following in [true, false] {
            let p = pane(following: following)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame

            p.rig.assertNoMove("a tall card arrives (following: \(following))", following: following) {
                p.store.handle(.request(request))
            }

            try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "tall arrival (following: \(following))")
        }
    }

    // MARK: The countdown ticks

    func testTheCountdownTickingThreeTimesMovesNothing() throws {
        let request = try ApprovalTestRequests.compound()
        for following in [true, false] {
            let p = pane(following: following)
            let card = try arrive(request, in: p)
            let frame = card.frame, scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame

            p.rig.assertNoMove("the countdown ticks (following: \(following))", following: following) {
                for _ in 0 ..< 3 { card.countdown.tick() }
            }

            XCTAssertEqual(card.frame, frame, "ticking changes the label's string, not the card")
            try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "ticks (following: \(following))")
        }
    }

    // MARK: The input scrolls inside the card

    func testScrollingTheInputInsideTheCardToItsEndMovesNothingAndEnablesAllow() throws {
        let request = try ApprovalTestRequests.heredoc300()
        for following in [true, false] {
            let p = pane(following: following)
            let card = try arrive(request, in: p)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            let view = card.inputView
            XCTAssertEqual(card.allowButton?.isEnabled, false, "precondition: Allow waits for the end")
            let line = NSRange(location: view.displayedLines.prefix(286).reduce(0) { $0 + $1.utf16.count + 1 },
                               length: view.displayedLines[286].utf16.count)

            p.rig.assertNoMove("the input scrolls to line 287 (following: \(following))", following: following) {
                view.textView.scrollRangeToVisible(line)
            }
            XCTAssertTrue(view.visibleLineNumbers.contains(287), "precondition: the scroll happened inside the card")
            XCTAssertEqual(card.allowButton?.isEnabled, false, "line 287 is not the end")

            p.rig.assertNoMove("the input scrolls to its end (following: \(following))", following: following) {
                view.scrollToEnd()
            }

            XCTAssertTrue(view.visibleLineNumbers.contains(300), "the end of the input is on screen")
            XCTAssertEqual(card.allowButton?.isEnabled, true, "Allow becomes enabled once the last line has been shown")
            XCTAssertEqual(card.allowButton?.title, "Allow once")
            try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "input scrolled (following: \(following))")
        }
    }

    // MARK: An answer is sent, its outcome shows, the card leaves

    func testAnAnswerItsOutcomeAndTheCardLeavingMoveNothing() throws {
        let request = try ApprovalTestRequests.compound()
        for following in [true, false] {
            let p = pane(following: following)
            let card = try arrive(request, in: p)

            p.rig.assertNoMove("Deny is pressed (following: \(following))", following: following) {
                card.denyButton.performClick(nil)
            }
            XCTAssertEqual(p.recorder.sent.map { $0.decision }, [ApprovalDecisionWire(kind: .deny)], "precondition: the answer went out once")
            XCTAssertFalse(card.denyButton.isEnabled, "the card shows the answer is on its way")

            p.rig.assertNoMove("the outcome appears on the card (following: \(following))", following: following) {
                p.store.handle(.resolved(self.resolved("req-1", "denied", byWindow: "w-gate")))
            }
            XCTAssertTrue(p.host.card === card, "the outcome shows in place")
            XCTAssertEqual(p.host.listings.first?.state, "Denied")

            p.rig.assertNoMove("the outcome has been shown and the card leaves (following: \(following))", following: following) {
                p.recorder.runScheduled()
            }
            XCTAssertNil(p.host.card, "with Reduce Motion the card is removed at once")
            XCTAssertTrue(p.host.subviews.isEmpty)
        }
    }

    func testTheFadeOfAnEndedCardMovesNothingEitherWhenMotionIsAllowed() throws {
        let request = try ApprovalTestRequests.compound()
        for following in [true, false] {
            let p = pane(following: following, reduceMotion: false)
            let card = try arrive(request, in: p)
            card.denyButton.performClick(nil)
            p.store.handle(.resolved(resolved("req-1", "denied", byWindow: "w-gate")))
            settle(p)

            p.rig.assertNoMove("the card fades (following: \(following))", following: following) {
                p.recorder.runScheduled()
            }
        }
    }

    // MARK: Another window answered

    func testARequestResolvedByAnotherWindowMovesNothing() throws {
        let request = try ApprovalTestRequests.compound()
        for following in [true, false] {
            let p = pane(following: following)
            let card = try arrive(request, in: p)

            p.rig.assertNoMove("another window answered (following: \(following))", following: following) {
                p.store.handle(.resolved(self.resolved("req-1", "allowed_once", byWindow: "w-other")))
            }
            XCTAssertTrue(p.recorder.sent.isEmpty, "this window sent nothing")
            XCTAssertTrue(p.host.card === card)
            XCTAssertEqual(p.host.listings.first?.state, "Allowed once")

            p.rig.assertNoMove("the outcome leaves (following: \(following))", following: following) {
                p.recorder.runScheduled()
            }
            XCTAssertNil(p.host.card)
        }
    }

    // MARK: Two pending

    func testASecondRequestArrivingAndTheFirstEndingMoveNothing() throws {
        let first = try ApprovalTestRequests.simpleRm(id: "a")
        let second = try ApprovalTestRequests.compound(id: "b")
        for following in [true, false] {
            let p = pane(following: following)
            _ = try arrive(first, in: p)

            p.rig.assertNoMove("a second request is pending (following: \(following))", following: following) {
                p.store.handle(.request(second))
            }
            XCTAssertEqual(p.host.card?.request.id, "a", "the oldest keeps the card")
            XCTAssertTrue(ApprovalTestViews.labelTexts(in: try XCTUnwrap(p.host.card)).contains("+1 more"))

            p.rig.assertNoMove("the first request ends (following: \(following))", following: following) {
                p.store.handle(.resolved(self.resolved("a", "denied", byWindow: "w-other")))
            }

            p.rig.assertNoMove("the card swaps to the next request (following: \(following))", following: following) {
                p.recorder.runScheduled()
            }
            XCTAssertEqual(p.host.card?.request.id, "b")
            XCTAssertEqual(p.host.subviews.count, 1)
            XCTAssertFalse(ApprovalTestViews.labelTexts(in: try XCTUnwrap(p.host.card)).contains { $0.hasSuffix(" more") })
        }
    }

    // MARK: Helpers

    private func resolved(_ id: String, _ outcome: String, byWindow: String) -> ApprovalResolvedFrame {
        do {
            return try ApprovalTestRequests.resolved(id: id, outcome: outcome, byWindow: byWindow)
        } catch {
            preconditionFailure("could not build a resolved frame: \(error)")
        }
    }
}

// MARK: - The gate's own tolerance (B27)

/// What `assertNoMove` promises, pinned from both sides: a move of exactly 1 pt passes, 1.5 pt fails, and a block
/// appended to the turn at the top of the viewport of a following pane does not fail it (it compares the turn's
/// durable identity, not its content key, which changes with every append).
final class ScrollSafetyGateToleranceTests: XCTestCase {

    /// Put the viewport top 2 pt into the first text block of turn `index`, so the first visible block is that
    /// block and a plain scroll moves its offset by exactly the scroll distance.
    private func scrollIntoFirstBlock(of rig: SafetyRig, turn index: Int) throws {
        let view = try XCTUnwrap(rig.materialized[rig.turns[index].id], "the turn is built")
        let block = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBlockView }.first, "the turn opens with a text block")
        rig.userScroll(to: rig.doc.convert(block.bounds, from: block).minY + 2)
        rig.settle()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the pane is not following")
    }

    func testAMoveOfExactlyOnePointPassesTheGate() throws {
        let rig = SafetyRig.scrolledUp(self)
        try scrollIntoFirstBlock(of: rig, turn: 3)
        rig.assertNoMove("move 1.0 pt", following: false) {
            rig.userScroll(to: rig.clip.bounds.minY + 1.0)
        }
    }

    func testAMoveOfOneAndAHalfPointsFailsTheGate() throws {
        let rig = SafetyRig.scrolledUp(self)
        try scrollIntoFirstBlock(of: rig, turn: 3)
        XCTExpectFailure("1.5 pt is past the 1 pt tolerance") {
            rig.assertNoMove("move 1.5 pt", following: false) {
                rig.userScroll(to: rig.clip.bounds.minY + 1.5)
            }
        }
    }

    func testAppendingToTheTurnAtTheTopOfAFollowingPaneDoesNotFalseFailTheGate() throws {
        // One short, still-running turn: the viewport top is inside it, the transcript is shorter than the
        // viewport, and the pane follows the tail. Appending to it changes the turn's content key.
        let turn = FoldFixtures.turn([.text("A short running turn. \(FoldFixtures.prose)")], complete: false, user: "short")
        let rig = SafetyRig(self, turns: [turn])
        rig.start()
        rig.focusComposer()
        XCTAssertTrue(rig.followTail.isPinned, "precondition: the pane follows the tail")
        XCTAssertEqual(rig.firstVisibleTurnIdentity(), turn.identityKey, "precondition: the viewport top is in the turn we append to")
        XCTAssertLessThan(rig.virtualizer.documentHeight, rig.viewportHeight, "precondition: the transcript fits, so the top does not move on growth")
        let keyBefore = rig.snapshot().firstVisible?.turnKey

        rig.assertNoMove("append to the top-visible turn while following", following: true) {
            rig.append([.text("A streamed paragraph. \(FoldFixtures.prose)"), .text("Another. \(FoldFixtures.prose)")])
        }

        XCTAssertNotEqual(rig.snapshot().firstVisible?.turnKey, keyBefore,
                          "precondition: the append changed the turn's content key (the reason the gate compares its identity)")
    }
}
