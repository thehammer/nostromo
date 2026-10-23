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

    /// A rig with an approval host over it. `permit` is a person's by default. `sharing` puts a second window's
    /// pane on the same store (a second rig, a second host, its own window id).
    private func pane(following: Bool, reduceMotion: Bool = true, sharing shared: Pane? = nil,
                      windowID: String = "w-gate") -> Pane {
        let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
        let recorder = shared?.recorder ?? ApprovalRecorder()
        let store = shared?.store ?? recorder.makeStore()
        let host = ApprovalOverlayHost(tag: "cody-1", store: store, agentName: { "Cody" }, windowID: { windowID },
                                       permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true },
                                       reduceMotion: { reduceMotion })
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

    func testScrollingTheInputInsideTheCardMovesNothingAndAllowWaitsForEveryLine() throws {
        let request = try ApprovalTestRequests.heredoc300()
        for following in [true, false] {
            let p = pane(following: following)
            let card = try arrive(request, in: p)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            let view = card.inputView
            XCTAssertEqual(card.allowButton?.isEnabled, false, "precondition: Allow waits for every line")
            let line = NSRange(location: view.displayedLines.prefix(286).reduce(0) { $0 + $1.utf16.count + 1 },
                               length: view.displayedLines[286].utf16.count)

            p.rig.assertNoMove("the input scrolls to line 287 (following: \(following))", following: following) {
                view.textView.scrollRangeToVisible(line)
            }
            XCTAssertTrue(view.visibleLineNumbers.contains(287), "precondition: the scroll happened inside the card")
            XCTAssertEqual(card.allowButton?.isEnabled, false, "line 287 is not the end")

            p.rig.assertNoMove("the input jumps to its end (following: \(following))", following: following) {
                view.scrollToEnd()
            }
            XCTAssertTrue(view.visibleLineNumbers.contains(300), "the end of the input is on screen")
            XCTAssertEqual(card.allowButton?.isEnabled, false, "a jump shows the end and nothing between: Allow still waits")
            XCTAssertEqual(card.allowButton?.title, "Scroll to the end to allow")

            p.rig.assertNoMove("the input is scrolled through, line by line (following: \(following))", following: following) {
                ApprovalTestViews.readThrough(view)
            }

            XCTAssertTrue(view.visibleLineNumbers.contains(300), "the walk ended at the end of the input")
            XCTAssertTrue(view.hasShownEveryLine, "unseen: \(view.linesNotYetShown)")
            XCTAssertEqual(card.allowButton?.isEnabled, true, "Allow becomes enabled once every line has been shown")
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
            XCTAssertEqual(try XCTUnwrap(p.host.card).pageText, "1 of 2")

            p.rig.assertNoMove("the first request ends (following: \(following))", following: following) {
                p.store.handle(.resolved(self.resolved("a", "denied", byWindow: "w-other")))
            }

            p.rig.assertNoMove("the card swaps to the next request (following: \(following))", following: following) {
                p.recorder.runScheduled()
            }
            XCTAssertEqual(p.host.card?.request.id, "b")
            XCTAssertEqual(p.host.subviews.count, 1)
            XCTAssertEqual(try XCTUnwrap(p.host.card).pageText, "")
        }
    }

    // MARK: A row's status changes (AP2b, criterion 36)

    /// Swap the rig's turn views for ones whose tool rows read the pane's store (the rig builds its own with no
    /// store), keeping every frame. Returns the tool groups on screen and counts the height changes any of
    /// them asks its turn for.
    private func installApprovalAwareTurns(in p: Pane, heightChanges: HeightChangeCounter) throws -> [ToolGroupView] {
        let rig = p.rig
        for (id, old) in rig.materialized {
            guard let turn = rig.turns.first(where: { $0.id == id }) else { continue }
            let state = rig.store.state(for: id)
            let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: state,
                                    folds: FoldResolver(state: state, expandedByDefault: rig.expandedByDefault),
                                    heldOrdinals: state.heldOrdinals, approvals: p.store)
            rig.rollInHolds.wire(view, turn: id)
            view.onIntrinsicHeightChange = { heightChanges.count += 1 }
            view.setIslandWidth(rig.contentWidth)
            XCTAssertEqual(view.islandHeight(), old.frame.height, accuracy: 0.5, "precondition: the swapped turn measures as before")
            view.frame = old.frame
            old.removeFromSuperview()
            rig.doc.addSubview(view)
            rig.materialized[id] = view
        }
        settle(p)
        return rigAllSubviews(of: rig.doc).compactMap { $0 as? ToolGroupView }
    }

    final class HeightChangeCounter { var count = 0 }

    private func frames(of groups: [ToolGroupView]) -> [NSRect] {
        groups.flatMap { [$0.frame, $0.row.frame] } + groups.compactMap { $0.superview?.frame }
    }

    func testARowsStatusChangingFromPendingThroughApprovedDeniedAndBlockedToNothingMovesNothing() throws {
        for following in [true, false] {
            let p = pane(following: following)
            let heightChanges = HeightChangeCounter()
            let groups = try installApprovalAwareTurns(in: p, heightChanges: heightChanges)
            let a = try XCTUnwrap(groups.first, "precondition: a tool row is materialised")
            let ids = a.group.calls.compactMap(\.toolUseId)
            XCTAssertGreaterThanOrEqual(ids.count, 4, "precondition: four calls to give four statuses")
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            let before = frames(of: groups)
            XCTAssertEqual(a.row.frame.height, FoldRowView.height, "precondition: a 22 pt row")
            XCTAssertTrue(a.row.approvalField.isHidden, "precondition: no status yet")

            let requestA0 = try ApprovalAP2bFixtures.request(id: "rA0", toolUseId: ids[0])
            let requestA1 = try ApprovalAP2bFixtures.request(id: "rA1", toolUseId: ids[1])
            let requestA3 = try ApprovalAP2bFixtures.request(id: "rA3", toolUseId: ids[3])
            let approvedA0 = try ApprovalAP2bFixtures.resolved(id: "rA0", outcome: "allowed_once", byWindow: "w-gate")
            let deniedA1 = try ApprovalAP2bFixtures.resolved(id: "rA1", outcome: "denied", byWindow: "w-gate")
            let blockedA2 = try ApprovalAP2bFixtures.guardBlocked(toolUseId: ids[2], entryId: "gate-1")
            let at = "(following: \(following))"

            p.rig.assertNoMove("a call awaits approval \(at)", following: following) {
                p.store.handle(.request(requestA3))
            }
            XCTAssertEqual(a.row.approvalField.stringValue, "· awaiting your approval", "precondition: the row says so")

            p.rig.assertNoMove("the daemon no longer holds it and the status goes away \(at)", following: following) {
                p.store.handle(.snapshot([]))
            }
            XCTAssertTrue(a.row.approvalField.isHidden, "the row says nothing again")

            p.rig.assertNoMove("a call awaits approval again \(at)", following: following) {
                p.store.handle(.request(requestA0))
            }
            XCTAssertEqual(a.row.approvalField.stringValue, "· awaiting your approval")

            p.rig.assertNoMove("the call is approved \(at)", following: following) {
                p.store.handle(.resolved(approvedA0))
            }
            XCTAssertTrue(a.row.approvalField.stringValue.hasPrefix("· approved by you"), a.row.approvalField.stringValue)

            p.rig.assertNoMove("another call awaits \(at)", following: following) {
                p.store.handle(.request(requestA1))
            }
            p.rig.assertNoMove("and is denied \(at)", following: following) {
                p.store.handle(.resolved(deniedA1))
            }
            XCTAssertEqual(a.row.approvalField.stringValue, "· denied by you")

            p.rig.assertNoMove("another is blocked by the guard \(at)", following: following) {
                p.store.handle(.guardBlocked(blockedA2))
            }
            XCTAssertEqual(a.row.approvalField.stringValue, "· blocked: production-shell guard")

            XCTAssertEqual(frames(of: groups), before, "no row, group or turn changed its frame \(at)")
            XCTAssertEqual(heightChanges.count, 0, "no row asked its turn to re-measure \(at)")
            XCTAssertEqual(p.rig.scrollView.frame, scrollFrame, "\(at)")
            XCTAssertEqual(p.rig.inputBar.frame, barFrame, "\(at)")
            XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView, "the composer still has focus \(at)")
            XCTAssertEqual(p.rig.textView.string, SafetyRig.typedText)
            XCTAssertEqual(p.rig.textView.selectedRange(), SafetyRig.typedSelection)
        }
    }

    // MARK: The guard bar

    /// The bar, inside the pane, above the card if there is one, with the pane's frames and the composer untouched.
    private func assertBarFloatsInsideThePane(_ pane: Pane, scrollFrame: NSRect, barFrame: NSRect, name: String,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let bar = try XCTUnwrap(pane.host.guardBar, "\(name): there is a bar", file: file, line: line)
        let barRect = bar.convert(bar.bounds, to: nil)
        let scrollRect = pane.rig.scrollView.convert(pane.rig.scrollView.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(barRect.minY, scrollRect.minY + ApprovalOverlayHost.bottomInset - 0.5, "\(name): above the bottom of the transcript", file: file, line: line)
        XCTAssertLessThanOrEqual(barRect.maxY, scrollRect.maxY + 0.5, "\(name): and inside it", file: file, line: line)
        if let card = pane.host.card {
            XCTAssertGreaterThanOrEqual(bar.frame.minY, card.frame.maxY - 0.5, "\(name): the bar is above the card", file: file, line: line)
        }
        XCTAssertEqual(pane.rig.scrollView.frame, scrollFrame, "\(name): the scroll view's frame did not change", file: file, line: line)
        XCTAssertEqual(pane.rig.inputBar.frame, barFrame, "\(name): the input bar's frame did not change", file: file, line: line)
        XCTAssertTrue(pane.rig.window.firstResponder === pane.rig.textView, "\(name): the composer still has focus", file: file, line: line)
        XCTAssertEqual(pane.rig.textView.string, SafetyRig.typedText, "\(name): the typed text is untouched", file: file, line: line)
        XCTAssertEqual(pane.rig.textView.selectedRange(), SafetyRig.typedSelection, "\(name): so is the selection", file: file, line: line)
    }

    func testTheGuardBarAppearingBeingClosedAndHidingItselfMoveNothingWithAndWithoutACard() throws {
        let first = try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_g1", entryId: "gate-1", summary: "Bash tmux")
        let second = try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_g2", entryId: "gate-2", summary: "Bash ecs_connect")
        for following in [true, false] {
            for withCard in [false, true] {
                let p = pane(following: following)
                if withCard { _ = try arrive(try ApprovalTestRequests.compound(), in: p) }
                let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
                let at = "(following: \(following), card: \(withCard))"

                p.rig.assertNoMove("the bar appears \(at)", following: following) {
                    p.store.handle(.guardBlocked(first))
                }
                try assertBarFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "appeared \(at)")
                XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, "Blocked: Cody tried to send input to a production shell")
                XCTAssertEqual(p.host.card != nil, withCard, "the bar made no card and took none away")

                p.rig.assertNoMove("a newer block replaces it \(at)", following: following) {
                    p.store.handle(.guardBlocked(second))
                }
                try assertBarFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "replaced \(at)")
                XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, "Blocked: Cody tried to open a production shell")

                p.rig.assertNoMove("the person closes it \(at)", following: following) {
                    p.host.guardBar?.closeButton.performClick(nil)
                }
                XCTAssertNil(p.host.guardBar)
                XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView)

                p.rig.assertNoMove("it comes back \(at)", following: following) {
                    p.store.handle(.guardBlocked(try! ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_g3", entryId: "gate-3")))
                }
                try assertBarFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "again \(at)")

                p.rig.assertNoMove("a minute passes and it hides itself \(at)", following: following) {
                    p.recorder.scheduled.last { $0.delay == ApprovalStore.guardBarVisibleSeconds }?.work()
                }
                XCTAssertNil(p.host.guardBar)
                XCTAssertEqual(p.rig.scrollView.frame, scrollFrame)
                XCTAssertEqual(p.rig.inputBar.frame, barFrame)
                XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView, "\(at): the composer still has focus")
                XCTAssertEqual(p.rig.textView.string, SafetyRig.typedText)
                XCTAssertEqual(p.rig.textView.selectedRange(), SafetyRig.typedSelection)
            }
        }
    }

    func testACardArrivingAndLeavingUnderAShowingBarMovesNothing() throws {
        let request = try ApprovalTestRequests.compound()
        let block = try ApprovalAP2bFixtures.guardBlocked(entryId: "gate-1")
        for following in [true, false] {
            let p = pane(following: following)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            p.store.handle(.guardBlocked(block))
            settle(p)

            p.rig.assertNoMove("a card arrives under the bar (following: \(following))", following: following) {
                p.store.handle(.request(request))
            }
            try assertBarFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "card under the bar (following: \(following))")

            p.rig.assertNoMove("the card is answered elsewhere and leaves (following: \(following))", following: following) {
                p.store.handle(.resolved(try! ApprovalAP2bFixtures.resolved(id: "req-1", outcome: "denied")))
                p.recorder.scheduled.filter { $0.delay == ApprovalStore.outcomeVisibleSeconds }.forEach { $0.work() }
            }
            XCTAssertNil(p.host.card)
            try assertBarFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "card gone (following: \(following))")
        }
    }

    // MARK: Paging

    func testPagingOneToTwoToThreeAndBackMovesNothing() throws {
        let requests = try ["a", "b", "c"].map { try ApprovalTestRequests.compound(id: $0) }
        for following in [true, false] {
            let p = pane(following: following)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            _ = try arrive(requests[0], in: p)

            p.rig.assertNoMove("two more requests arrive (following: \(following))", following: following) {
                p.store.handle(.request(requests[1]))
                p.store.handle(.request(requests[2]))
            }
            XCTAssertEqual(p.host.card?.pageText, "1 of 3")

            for (name, expectedPage, event) in [
                ("next", 2, { p.host.showNext() }),
                ("next again", 3, { p.host.showNext() }),
                ("previous", 2, { p.host.showPrevious() }),
                ("previous again", 1, { p.host.showPrevious() }),
            ] as [(String, Int, () -> Void)] {
                p.rig.assertNoMove("\(name) (following: \(following))", following: following, event: event)
                XCTAssertEqual(p.host.page?.position, expectedPage, name)
                try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "\(name) (following: \(following))")
            }

            p.rig.assertNoMove("the › button is pressed (following: \(following))", following: following) {
                p.host.card?.pageNextButton?.performClick(nil)
            }
            XCTAssertEqual(p.host.page?.position, 2)
            p.rig.assertNoMove("the ‹ button is pressed (following: \(following))", following: following) {
                p.host.card?.pagePreviousButton?.performClick(nil)
            }
            XCTAssertEqual(p.host.page?.position, 1)
            XCTAssertTrue(p.recorder.sent.isEmpty, "paging answered nothing")
            try assertCardFloatsInsideThePane(p, scrollFrame: scrollFrame, barFrame: barFrame, name: "paged back (following: \(following))")
        }
    }

    // MARK: A second window

    func testASecondWindowsCardResolvingRemotelyMovesNothingInEitherWindow() throws {
        let request = try ApprovalTestRequests.compound()
        let resolvedElsewhere = try ApprovalAP2bFixtures.resolved(id: "req-1", outcome: "allowed_once", byWindow: "w-third")
        let block = try ApprovalAP2bFixtures.guardBlocked(entryId: "gate-1")
        for following in [true, false] {
            let a = pane(following: following)
            let b = pane(following: following, sharing: a, windowID: "w-gate-2")
            let aScroll = a.rig.scrollView.frame, aBar = a.rig.inputBar.frame
            let bScroll = b.rig.scrollView.frame, bBar = b.rig.inputBar.frame
            let at = "(following: \(following))"

            a.rig.assertNoMove("window A: a request arrives \(at)", following: following) {
                b.rig.assertNoMove("window B: a request arrives \(at)", following: following) {
                    a.store.handle(.request(request))
                }
            }
            XCTAssertNotNil(a.host.card)
            XCTAssertNotNil(b.host.card, "both windows show the card")

            a.rig.assertNoMove("window A: the request is resolved elsewhere \(at)", following: following) {
                b.rig.assertNoMove("window B: the request is resolved elsewhere \(at)", following: following) {
                    a.store.handle(.resolved(resolvedElsewhere))
                }
            }
            XCTAssertEqual(a.host.listings.first?.state, "Allowed once")
            XCTAssertEqual(b.host.listings.first?.state, "Allowed once")
            XCTAssertTrue(a.recorder.sent.isEmpty, "neither window sent anything")

            a.rig.assertNoMove("window A: the outcome leaves \(at)", following: following) {
                b.rig.assertNoMove("window B: the outcome leaves \(at)", following: following) {
                    a.recorder.runScheduled()
                }
            }
            XCTAssertNil(a.host.card)
            XCTAssertNil(b.host.card)

            a.rig.assertNoMove("window A: the guard blocks a call \(at)", following: following) {
                b.rig.assertNoMove("window B: the guard blocks a call \(at)", following: following) {
                    a.store.handle(.guardBlocked(block))
                }
            }
            XCTAssertNotNil(a.host.guardBar)
            XCTAssertNotNil(b.host.guardBar)
            a.rig.assertNoMove("window A: the bar is closed in A \(at)", following: following) {
                b.rig.assertNoMove("window B: and goes in B too \(at)", following: following) {
                    a.host.guardBar?.closeButton.performClick(nil)
                }
            }
            XCTAssertNil(a.host.guardBar)
            XCTAssertNil(b.host.guardBar)

            XCTAssertEqual(a.rig.scrollView.frame, aScroll)
            XCTAssertEqual(a.rig.inputBar.frame, aBar)
            XCTAssertEqual(b.rig.scrollView.frame, bScroll)
            XCTAssertEqual(b.rig.inputBar.frame, bBar)
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
