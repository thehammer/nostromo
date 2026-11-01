import XCTest
import AppKit
import Combine
import NostromoKit

// ApprovalOverlayHost, MotherNoticeHeldBar, MainMenu and SafetyRig are compiled into this target directly.
//
// MF6: the held bar. While Mother notices for a focus are held by the loop guard or the wake cap, that
// focus's transcript shows a muted bar with the app's own words (`MotherNoticeText.heldBarText`).
//
//   - It follows the daemon's notice state for this host's focus tag only, and goes when the hold is
//     released.
//   - It stacks above the guard bar, and floats over the transcript: it never moves it, never takes
//     focus from the composer, and never changes its text or selection.
//   - Two windows on the same focus both show it.
//
// Also the Debug menu's "Copy Mother Notice Stats": no key equivalent, and the text it copies is counts,
// modes, held reasons and the verified-origin share, never a title or a focus name.

final class MotherNoticeHeldBarTests: XCTestCase {

    // MARK: Helpers

    private struct Pane {
        let rig: SafetyRig
        let recorder: ApprovalRecorder
        let store: ApprovalStore
        let host: ApprovalOverlayHost
        let states: PassthroughSubject<MotherNoticeStateWire?, Never>
    }

    /// A rig with an approval host over it, fed by `states` (a window's own subscription to the daemon state).
    private func pane(following: Bool, tag: String = "cody-1", sharing shared: Pane? = nil,
                      windowID: String = "w-held") -> Pane {
        let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
        let recorder = shared?.recorder ?? ApprovalRecorder()
        let store = shared?.store ?? recorder.makeStore()
        let states = shared?.states ?? PassthroughSubject<MotherNoticeStateWire?, Never>()
        let host = ApprovalOverlayHost(tag: tag, store: store, agentName: { "Cody" }, windowID: { windowID },
                                       permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true },
                                       noticeStates: states.eraseToAnyPublisher(), reduceMotion: { true })
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
        return Pane(rig: rig, recorder: recorder, store: store, host: host, states: states)
    }

    /// A `mother_notice_state` frame, read the way the app reads it from the daemon.
    private func state(_ focuses: [String], enabled: Bool = true) -> MotherNoticeStateWire {
        let json = #"{"enabled":\#(enabled),"focuses":[\#(focuses.joined(separator: ","))]}"#
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return MotherNoticeStateWire.decode(from: object)!
    }

    private func loopGuard(_ tag: String = "cody-1") -> String {
        #"{"tag":"\#(tag)","mode":"wake","chain_held":true,"wakes_by_day":[]}"#
    }

    private func capHeld(_ tag: String = "cody-1") -> String {
        #"{"tag":"\#(tag)","mode":"wake","held":{"count":2,"reason":"cap"},"chain_held":false,"wakes_by_day":[]}"#
    }

    private func free(_ tag: String = "cody-1") -> String {
        #"{"tag":"\#(tag)","mode":"wake","chain_held":false,"wakes_by_day":[]}"#
    }

    private func assertComposerUntouched(_ p: Pane, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView, "\(name): the composer still has focus",
                      file: file, line: line)
        XCTAssertEqual(p.rig.textView.string, SafetyRig.typedText, "\(name): typed text untouched", file: file, line: line)
        XCTAssertEqual(p.rig.textView.selectedRange(), SafetyRig.typedSelection, "\(name): selection untouched",
                       file: file, line: line)
    }

    // MARK: What it says

    func testALoopGuardHoldShowsTheLoopGuardText() throws {
        let p = pane(following: true)
        XCTAssertNil(p.host.heldBar, "no bar before the daemon reports a hold")
        p.states.send(state([loopGuard()]))
        let bar = try XCTUnwrap(p.host.heldBar)
        XCTAssertEqual(bar.textLabel.stringValue, MotherNoticeText.heldBarText(.loopGuard))
        XCTAssertEqual(bar.accessibilityLabel(), MotherNoticeText.heldBarText(.loopGuard))
    }

    func testACapHoldShowsTheCapText() throws {
        let p = pane(following: true)
        p.states.send(state([capHeld()]))
        XCTAssertEqual(try XCTUnwrap(p.host.heldBar).textLabel.stringValue, MotherNoticeText.heldBarText(.cap))
    }

    func testTheTwoTextsDiffer() {
        XCTAssertNotEqual(MotherNoticeText.heldBarText(.loopGuard), MotherNoticeText.heldBarText(.cap))
    }

    func testAChangeOfReasonUpdatesTheSameBarInPlace() throws {
        let p = pane(following: true)
        p.states.send(state([loopGuard()]))
        let bar = try XCTUnwrap(p.host.heldBar)
        p.states.send(state([capHeld()]))
        XCTAssertTrue(p.host.heldBar === bar, "the bar is kept, not rebuilt")
        XCTAssertEqual(bar.textLabel.stringValue, MotherNoticeText.heldBarText(.cap))
    }

    // MARK: Whose it is

    func testOnlyThisHostsFocusRaisesTheBar() {
        let p = pane(following: true, tag: "cody-1")
        p.states.send(state([loopGuard("claudia-9"), capHeld("ada-3")]))
        XCTAssertNil(p.host.heldBar, "another focus's hold is not this focus's bar")
    }

    func testAnotherFocusBeingReleasedLeavesThisBarAlone() {
        let p = pane(following: true, tag: "cody-1")
        p.states.send(state([loopGuard("cody-1"), loopGuard("ada-3")]))
        XCTAssertNotNil(p.host.heldBar)
        p.states.send(state([loopGuard("cody-1"), free("ada-3")]))
        XCTAssertNotNil(p.host.heldBar)
    }

    func testOtherHeldReasonsAndNoHoldRaiseNoBar() {
        let p = pane(following: true)
        p.states.send(state([#"{"tag":"cody-1","mode":"wake","held":{"count":3,"reason":"batching"},"chain_held":false}"#]))
        XCTAssertNil(p.host.heldBar, "batching is not a held bar")
        p.states.send(state([free()]))
        XCTAssertNil(p.host.heldBar)
        p.states.send(nil)
        XCTAssertNil(p.host.heldBar)
    }

    // MARK: Released

    func testTheBarGoesWhenTheHoldIsReleasedOrTheStateGoesAway() {
        let p = pane(following: true)
        p.states.send(state([loopGuard()]))
        XCTAssertNotNil(p.host.heldBar)
        p.states.send(state([free()]))
        XCTAssertNil(p.host.heldBar)
        XCTAssertFalse(p.rig.window.contentView!.subviews.flatMap(MD.allSubviews).contains { $0 is MotherNoticeHeldBar },
                       "and it is out of the view tree")

        p.states.send(state([capHeld()]))
        XCTAssertNotNil(p.host.heldBar)
        p.states.send(state([]))
        XCTAssertNil(p.host.heldBar, "a focus the daemon no longer lists is not held")
    }

    func testAHostWithoutANoticeFeedNeverShowsABar() {
        let rig = SafetyRig.followingTail(self)
        let recorder = ApprovalRecorder()
        let host = ApprovalOverlayHost(tag: "cody-1", store: recorder.makeStore(), windowID: { "w" },
                                       permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true },
                                       reduceMotion: { true })
        rig.window.contentView!.addSubview(host)
        XCTAssertNil(host.heldBar)
    }

    // MARK: Stacking

    func testTheBarStacksAboveTheGuardBar() throws {
        let block = try ApprovalAP2bFixtures.guardBlocked(entryId: "gate-1")
        for order in [["guard", "held"], ["held", "guard"]] {
            let p = pane(following: true)
            for step in order {
                if step == "guard" { p.store.handle(.guardBlocked(block)) } else { p.states.send(state([loopGuard()])) }
            }
            p.rig.window.contentView?.layoutSubtreeIfNeeded()
            let held = try XCTUnwrap(p.host.heldBar, "\(order)")
            let guardBar = try XCTUnwrap(p.host.guardBar, "\(order)")
            XCTAssertGreaterThanOrEqual(held.frame.minY, guardBar.frame.maxY - 0.5, "held bar above the guard bar \(order)")
            XCTAssertFalse(held.frame.intersects(guardBar.frame.insetBy(dx: 0, dy: 0.5)), "they do not overlap \(order)")
            let scrollRect = p.rig.scrollView.convert(p.rig.scrollView.bounds, to: nil)
            XCTAssertLessThanOrEqual(held.convert(held.bounds, to: nil).maxY, scrollRect.maxY + 0.5, "inside the pane \(order)")
        }
    }

    func testTheBarStacksAboveACard() throws {
        let p = pane(following: true)
        p.store.handle(.request(try ApprovalTestRequests.compound()))
        p.states.send(state([capHeld()]))
        p.rig.window.contentView?.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(p.host.card)
        let held = try XCTUnwrap(p.host.heldBar)
        XCTAssertGreaterThanOrEqual(held.frame.minY, card.frame.maxY - 0.5)
    }

    // MARK: Scroll and focus safety

    func testTheBarAppearingChangingAndGoingMovesNothingAndTakesNoFocus() {
        for following in [true, false] {
            let p = pane(following: following)
            let scrollFrame = p.rig.scrollView.frame, barFrame = p.rig.inputBar.frame
            let at = "(following: \(following))"

            p.rig.assertNoMove("the bar appears \(at)", following: following) {
                p.states.send(state([loopGuard()]))
            }
            XCTAssertNotNil(p.host.heldBar)
            assertComposerUntouched(p, "appeared \(at)")

            p.rig.assertNoMove("the reason changes \(at)", following: following) {
                p.states.send(state([capHeld()]))
            }
            assertComposerUntouched(p, "changed \(at)")

            p.rig.assertNoMove("the hold is released \(at)", following: following) {
                p.states.send(state([free()]))
            }
            XCTAssertNil(p.host.heldBar)
            assertComposerUntouched(p, "released \(at)")

            XCTAssertEqual(p.rig.scrollView.frame, scrollFrame, "the scroll view's frame never changed \(at)")
            XCTAssertEqual(p.rig.inputBar.frame, barFrame, "the input bar's frame never changed \(at)")
        }
    }

    func testTheBarAppearingUnderAShowingGuardBarMovesNothing() throws {
        let block = try ApprovalAP2bFixtures.guardBlocked(entryId: "gate-1")
        for following in [true, false] {
            let p = pane(following: following)
            p.store.handle(.guardBlocked(block))
            p.rig.window.contentView?.layoutSubtreeIfNeeded()
            p.rig.assertNoMove("held bar over the guard bar (following: \(following))", following: following) {
                p.states.send(state([loopGuard()]))
            }
            p.rig.assertNoMove("and gone again (following: \(following))", following: following) {
                p.states.send(state([free()]))
            }
            XCTAssertNotNil(p.host.guardBar, "the guard bar is untouched by the held bar leaving")
        }
    }

    func testTheBarIsNeverAKeyboardTarget() throws {
        let p = pane(following: true)
        p.states.send(state([loopGuard()]))
        let bar = try XCTUnwrap(p.host.heldBar)
        XCTAssertFalse(bar.acceptsFirstResponder)
        XCTAssertFalse(MD.allSubviews(bar).contains { $0 is NSControl && !($0 is NSTextField) }, "it has no buttons")
    }

    // MARK: Two windows

    func testTwoWindowsOnTheSameFocusBothShowItAndBothReleaseIt() {
        for following in [true, false] {
            let a = pane(following: following, windowID: "w-a")
            let b = pane(following: following, sharing: a, windowID: "w-b")
            // Each window subscribes to the one daemon state.
            a.rig.assertNoMove("window A: the hold arrives (following: \(following))", following: following) {
                b.rig.assertNoMove("window B: the hold arrives (following: \(following))", following: following) {
                    a.states.send(state([loopGuard()]))
                }
            }
            XCTAssertNotNil(a.host.heldBar)
            XCTAssertNotNil(b.host.heldBar)
            XCTAssertEqual(a.host.heldBar?.textLabel.stringValue, b.host.heldBar?.textLabel.stringValue)

            a.rig.assertNoMove("window A: released (following: \(following))", following: following) {
                b.rig.assertNoMove("window B: released (following: \(following))", following: following) {
                    a.states.send(state([free()]))
                }
            }
            XCTAssertNil(a.host.heldBar)
            XCTAssertNil(b.host.heldBar)
        }
    }

    func testTwoHostsOnDifferentFocusesEachShowOnlyTheirOwnHold() {
        let a = pane(following: true, tag: "cody-1", windowID: "w-a")
        let b = pane(following: true, tag: "ada-3", sharing: a, windowID: "w-b")
        a.states.send(state([loopGuard("cody-1"), free("ada-3")]))
        XCTAssertNotNil(a.host.heldBar)
        XCTAssertNil(b.host.heldBar)
        a.states.send(state([free("cody-1"), capHeld("ada-3")]))
        XCTAssertNil(a.host.heldBar)
        XCTAssertNotNil(b.host.heldBar)
    }
}

// MARK: - Debug menu: Copy Mother Notice Stats

final class MotherNoticeStatsMenuTests: XCTestCase {

    private func debugMenu() throws -> NSMenu {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        return try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Debug" }, "no Debug menu")
    }

    func testDebugHasCopyMotherNoticeStatsWithNoKeyEquivalent() throws {
        let item = try XCTUnwrap(try debugMenu().items.first { $0.title == "Copy Mother Notice Stats" })
        XCTAssertEqual(item.keyEquivalent, "", "a Debug stats copy must not take a shortcut")
        XCTAssertEqual(item.action, #selector(MainMenuActions.copyMotherNoticeStats))
    }

    func testNoItemWithNoticeInItsTitleHasAKeyEquivalentAnywhereInTheMainMenu() {
        _ = NSApplication.shared
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) }
        }
        let offenders = walk(MainMenu.make(target: nil)).filter {
            $0.title.localizedCaseInsensitiveContains("notice") && !$0.keyEquivalent.isEmpty
        }
        XCTAssertTrue(offenders.isEmpty, "\(offenders.map(\.title))")
    }

    // MARK: The text

    private func stateFrame() -> MotherNoticeStateWire {
        let json = """
        {"enabled":false,"focuses":[
          {"tag":"claudia-AAAA1111","mode":"quiet","held":{"count":3,"reason":"cap"},"chain_held":false,
           "wakes_by_day":[{"day":"2026-10-30","count":4}]},
          {"tag":"ada-BBBB2222","mode":"off","chain_held":true,"wakes_by_day":[]}]}
        """
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return MotherNoticeStateWire.decode(from: object)!
    }

    func testTheCopiedTextHasCountsModesHeldReasonsAndTheVerifiedShareButNoTitleOrName() {
        let verified = MotherJobAnnotation(origin: MotherOriginView(
            kind: .focus, focusTag: "claudia-AAAA1111",
            nameSnapshot: "CANARY-SNAPSHOT-NAME", focusName: "CANARY-FOCUS-NAME", closed: false),
            notice: MotherNoticeAnnotation(status: .told, lastState: "CANARY-STATE", atMs: 1))
        let annotations: [String: MotherJobAnnotation] = [
            "CANARY-TITLE-JOB-1": verified,
            "job-2": MotherJobAnnotation(origin: MotherOriginView(kind: .you)),
            "job-3": MotherJobAnnotation(origin: MotherOriginView(kind: .unverified, focusTag: "x",
                                                                  nameSnapshot: "CANARY-CLAIM")),
            "job-4": MotherJobAnnotation(),
        ]

        let text = MotherNoticeStats.text(state: stateFrame(), annotations: annotations)

        XCTAssertTrue(text.contains("claudia-AAAA1111"), text)
        XCTAssertTrue(text.contains("ada-BBBB2222"), text)
        XCTAssertTrue(text.contains("quiet"), text)
        XCTAssertTrue(text.contains("off"), text)
        XCTAssertTrue(text.contains("cap=3"), text)
        XCTAssertTrue(text.contains("2026-10-30=4"), text)
        XCTAssertTrue(text.contains("1/4"), "one verified origin of four jobs: \(text)")
        XCTAssertTrue(text.contains("25%"), text)
        XCTAssertFalse(text.contains("CANARY"), "counts and tags only: \(text)")
    }
}
