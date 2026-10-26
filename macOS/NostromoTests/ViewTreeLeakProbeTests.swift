import XCTest
import AppKit
import Darwin
import ObjectiveC

// PROBE (temporary), round 3: NAME what is left behind when a control is added to / removed from a
// long-lived superview. Walks this process's malloc zones (test-only: it is a heap walk) and builds
// a histogram of live objects by class, plus of non-object blocks by size. Reports through XCTFail.

enum ProbeCensus {
    struct Snapshot {
        var classes: [String: Int] = [:]
        var error = ""
        var total = 0
    }

    /// Runs /usr/bin/heap against this very process (test-only; never in the app) and parses the class table.
    static func snapshot() -> Snapshot {
        var snap = Snapshot()
        let out = NSTemporaryDirectory() + "heap-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: out, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: out) else { snap.error = "no out file"; return snap }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        p.arguments = ["\(getpid())"]
        p.standardOutput = handle
        p.standardError = handle
        do { try p.run() } catch { snap.error = "heap failed to start: \(error)"; return snap }
        let deadline = Date().addingTimeInterval(180)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); snap.error = "heap timed out"; return snap }
        try? handle.close()
        guard let text = try? String(contentsOfFile: out, encoding: .utf8) else { snap.error = "no heap output"; return snap }
        try? FileManager.default.removeItem(atPath: out)
        let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(.*?)\s*(?:\s{2,}(?:ObjC|Swift|C\+\+|C)\b.*)?$"#)
        for line in text.split(separator: "\n") {
            let l = String(line)
            guard let m = regex?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), m.numberOfRanges == 4,
                  let countRange = Range(m.range(at: 1), in: l), let nameRange = Range(m.range(at: 3), in: l),
                  let count = Int(l[countRange]) else { continue }
            snap.classes[String(l[nameRange]), default: 0] += count
            snap.total += count
        }
        if snap.classes.isEmpty { snap.error = "no class table; head: " + String(text.prefix(300)).replacingOccurrences(of: "\n", with: " | ") }
        return snap
    }

    /// The biggest movers between two snapshots.
    static func delta(_ a: Snapshot, _ b: Snapshot, top: Int = 9) -> String {
        if !a.error.isEmpty || !b.error.isEmpty { return "heap error: \(a.error) / \(b.error)" }
        var moves: [(String, Int)] = []
        for key in Set(a.classes.keys).union(b.classes.keys) {
            let d = (b.classes[key] ?? 0) - (a.classes[key] ?? 0)
            if abs(d) >= 50 { moves.append((key, d)) }
        }
        moves.sort { abs($0.1) > abs($1.1) }
        return "heap[" + moves.prefix(top).map { "\($0.0) \($0.1 >= 0 ? "+" : "")\($0.1)" }.joined(separator: ", ")
            + "] (total objects \(b.total))"
    }
}

final class ViewTreeLeakProbeTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static func blocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }

    private func settle(_ n: Int = 3) {
        for _ in 0 ..< n { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func makeWindow() -> (NSWindow, NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = FixedWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        return (window, host)
    }

    private func label() -> NSTextField {
        let l = NSTextField(labelWithString: "hello world")
        l.textColor = Theme.fg
        return l
    }

    /// Runs `cycle` n times against a long-lived windowed host and reports what it left behind.
    private func probe(_ name: String, n: Int = 500, destroyHostAfter: Bool = false,
                       cycle: (_ host: NSView, _ window: NSWindow) -> Void) {
        var window: NSWindow? = nil
        var host: NSView? = nil
        (window, host) = { let p = makeWindow(); return (Optional(p.0), Optional(p.1)) }()
        addTeardownBlock { [weak w = window] in w?.orderOut(nil); w?.contentView = nil }
        for _ in 0 ..< 30 { autoreleasepool { cycle(host!, window!) } }
        settle()
        let s0 = ProbeCensus.snapshot()
        let b0 = Self.blocksInUse()
        for _ in 0 ..< n { autoreleasepool { cycle(host!, window!) } }
        settle(5)
        let s1 = ProbeCensus.snapshot()
        let b1 = Self.blocksInUse()
        var tail = ""
        if destroyHostAfter {
            autoreleasepool {
                host!.subviews.forEach { $0.removeFromSuperview() }
                window!.orderOut(nil)
                window!.contentView = nil
                host = nil
                window = nil
            }
            settle(8)
            let d = Self.blocksInUse() - b1
            tail = "; after destroying the host/window: blocks \(d >= 0 ? "+" : "")\(d)"
        }
        XCTFail("PROBE3 \(name) n=\(n): blocks +\(b1 - b0) (\(String(format: "%.1f", Double(b1 - b0) / Double(n)))/iter); "
                + ProbeCensus.delta(s0, s1) + tail)
    }

    func testProbeNamesTheLeak() {
        probe("plainLabel add/remove") { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("plainLabel add/remove, host+window destroyed afterwards", destroyHostAfter: true) { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("nsView add/remove (control: no leak expected)") { host, _ in
            let v = NSView(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("nsImageView add/remove") { host, _ in
            let v = NSImageView(); host.addSubview(v); v.removeFromSuperview()
        }
    }

    func testProbeMitigations() {
        probe("label created once, text updated in place (no re-parenting)") { host, _ in
            if host.subviews.isEmpty { host.addSubview(self.label()) }
            (host.subviews[0] as? NSTextField)?.stringValue = "tick \(Int.random(in: 0 ..< 1000))"
        }
        probe("label reparented between two long-lived views") { host, _ in
            let a: NSView
            if let existing = host.subviews.first { a = existing } else {
                a = NSView(); host.addSubview(a)
                let b = NSView(); host.addSubview(b)
            }
            let b = host.subviews[1]
            let l = a.subviews.first ?? b.subviews.first ?? self.label()
            (l.superview === a ? b : a).addSubview(l)
        }
        probe("label via removeFromSuperviewWithoutNeedingDisplay") { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperviewWithoutNeedingDisplay()
        }
        probe("label with cell.controlView cleared before removal") { host, _ in
            let v = self.label(); host.addSubview(v); v.cell?.controlView = nil; v.removeFromSuperview()
        }
        probe("label added to a short-lived container that is NOT yet in the window (ChatTurnView build)") { host, _ in
            let c = NSView(); c.addSubview(self.label()); c.addSubview(self.label())
            host.addSubview(c); c.removeFromSuperview()
        }
        probe("label added to a short-lived container ALREADY in the window (streaming append)") { host, _ in
            let c = NSView(); host.addSubview(c); c.addSubview(self.label()); c.addSubview(self.label())
            c.removeFromSuperview()
        }
        probe("label in NSStackView arranged/removed (our render() pattern)") { host, _ in
            let s: NSStackView
            if let existing = host.subviews.first as? NSStackView { s = existing } else { s = NSStackView(); host.addSubview(s) }
            s.arrangedSubviews.forEach { $0.removeFromSuperview() }
            s.addArrangedSubview(self.label()); s.addArrangedSubview(self.label())
        }
        probe("CopyMenuTextField add/remove") { host, _ in
            let v = CopyMenuTextField(labelWithString: "hello world"); host.addSubview(v); v.removeFromSuperview()
        }
    }

    func testProbeRealViews() {
        probe("measureIsland x3 on an ATTACHED TextBlockView (every remeasure of an on-screen column)", n: 300) { host, _ in
            let block: TextBlockView
            if let existing = host.subviews.first as? TextBlockView { block = existing } else {
                block = TextBlockView(text: "Plain words " + String(repeating: "more ", count: 30))
                host.addSubview(block)
            }
            for _ in 0 ..< 3 { _ = ChatTurnView.measureIsland(block, width: 600) }
        }
        probe("measureIsland x3 on an ATTACHED UserBubbleView", n: 300) { host, _ in
            let v: UserBubbleView
            if let existing = host.subviews.first as? UserBubbleView { v = existing } else {
                v = UserBubbleView(text: "a question the user asked")
                host.addSubview(v)
            }
            for _ in 0 ..< 3 { _ = ChatTurnView.measureIsland(v, width: 600) }
        }
        var counter = 0
        var turn = ChatTurn(userInput: "question", timestamp: Date(), blocks: [.text("alpha")], isComplete: false)
        probe("live ChatTurnView: the streaming block's text replaced each delta (same length)", n: 300) { host, _ in
            let view: ChatTurnView
            if let existing = host.subviews.first as? ChatTurnView { view = existing } else {
                view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
                view.setIslandWidth(800)
                host.addSubview(view)
            }
            counter += 1
            turn.blocks = [.text(counter % 2 == 0 ? "alpha beta gamma delta" : "omega sigma theta lambda")]
            view.update(turn: turn)
            host.layoutSubtreeIfNeeded()
        }
    }
}
