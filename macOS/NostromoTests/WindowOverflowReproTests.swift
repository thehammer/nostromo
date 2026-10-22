import XCTest
import AppKit
import NostromoKit

// WO2 (round 2 of the window overflow): 2026-10-22 02:31 CDT the Dell window (key, REPL + text pane,
// a transcript ~13-18k tall, session running) had a `MainLayout` 1123 pt tall in a 1080 pt window:
// DynamicFocusView 1033 (a window with no overflow has 990), the REPL's transcript scroll view 920
// (877), and 43 = the quick-action strip (41) + the context meter (2). Nothing in the REPL's own
// constraints forces that, so something imposes a vertical minimum at runtime.
//
// These tests drive the REAL views (`MainLayout` > `DynamicFocusView` > `RatioSplitView` > `ReplView`
// with an 18k-tall transcript + the SwiftUI pane) through the runtime state the Dell was in, one step
// at a time on ONE live window, and after every step demand
//     MainLayout.frame.size == window content size, the window kept the size it was given, and the
//     minimum the content demands (`fittingSize`) fits the window.
// A failing step prints the `fittingSize` of every level so the demanding view names itself.
final class WindowOverflowReproTests: XCTestCase {

    // MARK: - Rig

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Rig {
        let window: NSWindow
        let layout: MainLayout
        let requested: NSSize
    }

    private static let size = NSSize(width: 1920, height: 1080)
    private let tag = "perri"   // the built-in focus with a quick-action strip, like every REPL

    private static let replPlusText: PaneTree = .split(direction: .horizontal,
                                                       children: [.leaf(paneId: "repl"), .leaf(paneId: "plans")],
                                                       ratios: [0.5, 0.5])

    private func makeRig(index: Int, size: NSSize = WindowOverflowReproTests.size, makeKey: Bool = false) -> Rig {
        let displayUUID = "wo2r-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == tag }!
        UserDefaults.standard.set(tag, forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }

        let store = AppStore.shared
        store.applyForTesting(.focusLayout(tag: focus.sessionTag, tree: Self.replPlusText, focusedPane: nil))
        store.applyForTesting(.paneContent(tag: focus.sessionTag, paneId: "plans",
                                           content: .text(Array(repeating: "a line of text in the plans pane", count: 40).joined(separator: "\n")),
                                           freshness: nil, address: nil))

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = MainLayout(windowIndex: index, displayUUID: displayUUID)
        layout.overflowCaptureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wo2r-captures-\(UUID().uuidString)", isDirectory: true)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        let rig = Rig(window: window, layout: layout, requested: size)
        settle(rig)
        return rig
    }

    private func settle(_ rig: Rig) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
        }
    }

    // MARK: - Measuring

    private func contentSize(_ rig: Rig) -> NSSize { rig.window.contentRect(forFrameRect: rig.window.frame).size }

    private func requestedFrameSize(_ rig: Rig) -> NSSize {
        rig.window.frameRect(forContentRect: NSRect(origin: .zero, size: rig.requested)).size
    }

    private func allSubviews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + allSubviews($0) } }

    private func views(named name: String, in rig: Rig) -> [NSView] {
        allSubviews(rig.layout).filter { String(describing: type(of: $0)) == name }
    }

    private func fits(_ rig: Rig) -> Bool {
        let content = contentSize(rig)
        let demand = rig.layout.fittingSize
        return rig.layout.frame.size == content
            && rig.window.frame.size == requestedFrameSize(rig)
            && demand.width <= content.width + 1 && demand.height <= content.height + 1
    }

    /// `fittingSize` and frame of each level of the vertical chain, so the demanding view names itself.
    private func levels(_ rig: Rig) -> String {
        func fmt(_ v: NSView) -> String {
            let f = v.frame.size, d = v.fittingSize
            return "\(type(of: v)) \(Int(f.width))x\(Int(f.height)) fits \(Int(d.width))x\(Int(d.height))"
        }
        var out = ["window.frame=\(rig.window.frame.size) content=\(contentSize(rig)) layout=\(fmt(rig.layout))"]
        for name in ["TabBarView", "DynamicFocusView", "RatioSplitView", "ReplView", "QuickActionStripView", "ReplInputBar",
                     "ContextMeterView", "PaneContentNSView", "ApprovalOverlayHost", "JumpToLatestOverlay",
                     "PaceBarsView", "StatusBarView", "ToastBannerView", "ActivityTickerView"] {
            for v in views(named: name, in: rig).prefix(1) { out.append(fmt(v)) }
        }
        for v in allSubviews(rig.layout) where v is NSScrollView && v.enclosingScrollView == nil {
            out.append("scroll " + fmt(v))
        }
        return out.joined(separator: " ¦ ")
    }

    // MARK: - Fixtures

    private func decodeTurns(_ json: String) throws -> [DaemonTurn] {
        try JSONDecoder().decode([DaemonTurn].self, from: Data(json.utf8))
    }

    /// `count` turns of `lines` lines each; the last one is mid-flight (a tool call with no result yet) when `running`.
    private func turnsJSON(count: Int, lines: Int, running: Bool) -> String {
        let body = (0..<lines).map { "line \($0) of a long, ordinary answer about the layout of a window" }.joined(separator: "\\n\\n")
        let turns = (0..<count).map { i -> String in
            let last = i == count - 1
            let complete = !(last && running)
            let tool = last && running
                ? #",{"kind":"tool_call","tool_name":"Bash","input_summary":"date","input_full":"date"}"#
                : #",{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"ls"},{"kind":"tool_result","content":"ok","is_error":false}"#
            let summary = complete ? #",{"kind":"result_summary","duration_ms":1000,"cost_usd":0.1,"is_error":false}"# : ""
            return """
                {"id":"t\(i)","user_input":"question \(i)","timestamp":null,"is_complete":\(complete),"blocks":[
                  {"kind":"text","text":"\(body)"}\(tool)\(summary)]}
                """
        }
        return "[" + turns.joined(separator: ",") + "]"
    }

    private func replInputBar(_ rig: Rig) -> ReplInputBar? { views(named: "ReplInputBar", in: rig).first as? ReplInputBar }

    // MARK: - The runtime-state battery

    func testMainLayoutKeepsFittingAsTheDellsRuntimeStateArrivesStepByStep() throws {
        let rig = makeRig(index: 700, makeKey: true)
        let store = AppStore.shared
        var failures: [String] = []
        var steps = 0
        func step(_ name: String, _ apply: () throws -> Void) rethrows {
            try apply()
            settle(rig)
            steps += 1
            if !fits(rig) { failures.append("after [\(name)]: \(levels(rig))") }
        }

        try step("baseline, empty transcript") {}
        try step("3 short turns (transcript shorter than the viewport)") {
            store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 3, lines: 1, running: false))))
        }
        try step("grows to 400 turns (~18k)") {
            store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 400, lines: 8, running: false))))
        }
        try step("session mid-turn with a tool call in flight") {
            store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 400, lines: 8, running: true))))
            store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        }
        try step("window key, composer focused") {
            rig.window.makeKeyAndOrderFront(nil)
            if let bar = replInputBar(rig) { rig.window.makeFirstResponder(bar.textView) }
        }
        try step("composer grows to five lines") {
            if let bar = replInputBar(rig) {
                bar.textView.string = Array(repeating: "a line the operator is typing", count: 5).joined(separator: "\n")
                bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
            }
        }
        try step("composer grows to forty lines (capped at a third of the pane)") {
            if let bar = replInputBar(rig) {
                bar.textView.string = Array(repeating: "a line the operator is typing", count: 40).joined(separator: "\n")
                bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
            }
        }
        try step("composer cleared after sending") {
            if let bar = replInputBar(rig) {
                bar.textView.string = ""
                bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
            }
        }
        try step("approval card for a 40-line command") {
            let command = Array(repeating: "echo a fairly long line of a heredoc that the card has to lay out", count: 40).joined(separator: "\n")
            ApprovalStore.shared.handle(.request(try ApprovalTestRequests.bash(command, id: "wo2r-1", tag: tag, agentName: "perri")))
        }
        try step("approval card resolved") {
            ApprovalStore.shared.handle(.resolved(try ApprovalTestRequests.resolved(id: "wo2r-1", outcome: "allowed_once", tag: tag)))
        }
        try step("ticker expanded") {
            for ticker in views(named: "ActivityTickerView", in: rig) { _ = ticker.perform(NSSelectorFromString("toggleExpanded")) }
        }
        try step("ticker collapsed") {
            for ticker in views(named: "ActivityTickerView", in: rig) { _ = ticker.perform(NSSelectorFromString("toggleExpanded")) }
        }
        try step("session idle again") {
            store.applyForTesting(.sessionState(tag: tag, state: .idle))
        }
        try step("window resigns key") { rig.window.resignKey() }
        try step("transcript cleared") {
            store.applyForTesting(.sessionTurns(tag: tag, turns: []))
        }

        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(steps) step(s) overflowed ¦ " + failures.joined(separator: " ¦¦ "))
    }

    /// The state in place, then the window moves between displays of different sizes (a full-screen
    /// window on another display, a resolution change), the way the Dell's did across launches.
    func testMainLayoutFollowsTheWindowThroughResizesWithAnOldTranscriptAndARunningSession() throws {
        let rig = makeRig(index: 710, makeKey: true)
        let store = AppStore.shared
        store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 400, lines: 8, running: true))))
        store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        settle(rig)
        var failures: [String] = []
        for size in [NSSize(width: 2560, height: 1440), NSSize(width: 1920, height: 1080), NSSize(width: 1710, height: 1073),
                     NSSize(width: 1920, height: 1080), NSSize(width: 3840, height: 2160), NSSize(width: 1920, height: 1080)] {
            let frame = rig.window.frameRect(forContentRect: NSRect(origin: rig.window.frame.origin, size: size))
            rig.window.setFrame(frame, display: true)
            settle(rig)
            let content = contentSize(rig)
            let demand = rig.layout.fittingSize
            if content != size || rig.layout.frame.size != size || demand.width > size.width + 1 || demand.height > size.height + 1 {
                failures.append("after resize to \(Int(size.width))x\(Int(size.height)): \(levels(rig))")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) resize(s) overflowed ¦ " + failures.joined(separator: " ¦¦ "))
    }

    /// Two windows on the same focus (the Dell and the LG share the session), the second created after the first
    /// has a long transcript; each window then has the other's input state.
    func testTwoWindowsOnOneFocusBothFit() throws {
        let store = AppStore.shared
        let first = makeRig(index: 720, makeKey: true)
        store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 400, lines: 8, running: true))))
        store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        settle(first)
        let second = makeRig(index: 721)
        settle(second)
        if let bar = replInputBar(first) {
            first.window.makeFirstResponder(bar.textView)
            bar.textView.string = Array(repeating: "typing", count: 6).joined(separator: "\n")
            bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
        }
        settle(first); settle(second)
        for (name, rig) in [("first", first), ("second", second)] {
            XCTAssertTrue(fits(rig), "\(name) window: \(levels(rig))")
        }
    }

    /// The operator switches focus (tabs) while a long, running session sits in this window, then comes back:
    /// the cached REPL view is detached and re-attached with new edge constraints each time.
    func testSwitchingFocusAwayAndBackKeepsTheWindowFitting() throws {
        let rig = makeRig(index: 730, makeKey: true)
        let store = AppStore.shared
        store.applyForTesting(.sessionTurns(tag: tag, turns: try decodeTurns(turnsJSON(count: 400, lines: 8, running: true))))
        store.applyForTesting(.sessionState(tag: tag, state: .midTurn))
        settle(rig)
        guard let tabBar = views(named: "TabBarView", in: rig).first as? TabBarView else {
            return XCTFail("no TabBarView in the window")
        }
        var failures: [String] = []
        let order = ["mother", "fred", "teri", "perri", "mother", "perri"]
        for id in order {
            guard let focus = FocusStore.shared.focuses.first(where: { $0.id == id }) else { continue }
            tabBar.onSwitch?(focus)
            settle(rig)
            if !fits(rig) { failures.append("after switching to [\(id)]: \(levels(rig))") }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) switch(es) overflowed ¦ " + failures.joined(separator: " ¦¦ "))
    }
}
