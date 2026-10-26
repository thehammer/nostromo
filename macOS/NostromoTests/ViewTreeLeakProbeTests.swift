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
        autoreleasepool { snapshotInner() }
    }

    private static func snapshotInner() -> Snapshot {
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

    static let interesting = ["NSKeyValueDependency", "NSKeyValueDependencyContext", "__NSMallocBlock__",
                              "__NSExactBlockVariable__", "NSISRestrictedToNonNegativeVariable",
                              "NSMutableDictionary", "NSMutableArray", "CFDictionary", "NSTextFieldCell",
                              "NSTextField", "CopyMenuTextFieldCell", "NSLayoutConstraint"]

    /// Deltas of the classes that matter, then the biggest other movers.
    static func delta(_ a: Snapshot, _ b: Snapshot, per n: Int) -> String {
        if !a.error.isEmpty || !b.error.isEmpty { return "heap error: \(a.error) / \(b.error)" }
        func d(_ k: String) -> Int { (b.classes[k] ?? 0) - (a.classes[k] ?? 0) }
        let key = d("NSKeyValueDependency")
        var parts = interesting.compactMap { name -> String? in
            let v = d(name)
            return abs(v) >= 20 ? "\(name.replacingOccurrences(of: "NSKeyValue", with: "KV")) \(v >= 0 ? "+" : "")\(v)" : nil
        }
        var others: [(String, Int)] = []
        for k in Set(a.classes.keys).union(b.classes.keys) where !interesting.contains(k) {
            let v = d(k)
            if abs(v) >= max(100, n / 2) { others.append((k, v)) }
        }
        others.sort { abs($0.1) > abs($1.1) }
        parts += others.prefix(3).map { "\($0.0) \($0.1 >= 0 ? "+" : "")\($0.1)" }
        return String(format: "KVDependency/iter=%.2f", Double(key) / Double(n)) + " [" + parts.joined(separator: ", ") + "]"
    }
}

final class ViewTreeLeakProbeTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private final class PlainSub: NSTextField {}
    private final class CellSubCell: NSTextFieldCell {}
    private final class CellSub: NSTextField {
        override class var cellClass: AnyClass? { get { CellSubCell.self } set { _ = newValue } }
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

    /// Chain of probes sharing one running snapshot: each reports the delta since the previous one ended.
    private func chain(_ probes: [(name: String, n: Int, inWindow: Bool, cycle: (NSView) -> Void, after: (() -> Void)?)]) {
        let (window, host) = makeWindow()
        let nonWindowHost = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        addTeardownBlock { [weak window] in window?.orderOut(nil); window?.contentView = nil }
        var last = ProbeCensus.snapshot()
        for probe in probes {
            let h = probe.inWindow ? host : nonWindowHost
            for _ in 0 ..< 10 { autoreleasepool { probe.cycle(h) } }
            settle()
            let before = ProbeCensus.snapshot()
            for _ in 0 ..< probe.n { autoreleasepool { probe.cycle(h) } }
            settle(4)
            var after = ProbeCensus.snapshot()
            var tail = ""
            if let cleanup = probe.after {
                cleanup()
                settle(4)
                let post = ProbeCensus.snapshot()
                tail = " | after cleanup: " + ProbeCensus.delta(after, post, per: probe.n)
                after = post
            }
            XCTFail("PROBE5 \(probe.name) n=\(probe.n): " + ProbeCensus.delta(before, after, per: probe.n) + tail)
            host.subviews.forEach { $0.removeFromSuperview() }
            nonWindowHost.subviews.forEach { $0.removeFromSuperview() }
            last = after
        }
        _ = last
    }

    private typealias P = (name: String, n: Int, inWindow: Bool, cycle: (NSView) -> Void, after: (() -> Void)?)

    private func p(_ name: String, n: Int = 300, inWindow: Bool = true, after: (() -> Void)? = nil,
                   _ cycle: @escaping (NSView) -> Void) -> P {
        (name, n, inWindow, cycle, after)
    }

    // MARK: isolation: what event leaks?

    func testIsolation() {
        let reused = label()
        var retained: [NSView] = []
        var accumulated: [NSView] = []
        chain([
            p("iso: control created, never attached") { _ in _ = self.label() },
            p("iso: nsView add/remove (baseline)") { h in let v = NSView(); h.addSubview(v); v.removeFromSuperview() },
            p("iso: new label add+remove, window host") { h in let v = self.label(); h.addSubview(v); v.removeFromSuperview() },
            p("iso: new label add+remove, NON-window host", inWindow: false) { h in
                let v = self.label(); h.addSubview(v); v.removeFromSuperview()
            },
            p("iso: SAME label instance add+remove, window host") { h in h.addSubview(reused); reused.removeFromSuperview() },
            p("iso: new label add only (kept attached), window host", after: { accumulated.forEach { $0.removeFromSuperview() }; accumulated = [] }) { h in
                let v = self.label(); h.addSubview(v); accumulated.append(v)
            },
            p("iso: new label add+remove but instance retained (no dealloc)", after: { retained = [] }) { h in
                let v = self.label(); h.addSubview(v); v.removeFromSuperview(); retained.append(v)
            },
        ])
    }

    // MARK: knobs: what makes a control not leak?

    func testKnobs() {
        func cycle(_ make: @escaping () -> NSView) -> (NSView) -> Void {
            { h in let v = make(); h.addSubview(v); v.removeFromSuperview() }
        }
        chain([
            p("knob: plain NSTextField subclass (no custom cell)", cycle { let l = PlainSub(labelWithString: "hello"); return l }),
            p("knob: NSTextField subclass with custom NSTextFieldCell subclass", cycle { let l = CellSub(labelWithString: "hello"); return l }),
            p("knob: CopyMenuTextField", cycle { CopyMenuTextField(labelWithString: "hello") }),
            p("knob: explicit label.appearance = darkAqua", cycle {
                let l = self.label(); l.appearance = NSAppearance(named: .darkAqua); return l
            }),
            p("knob: wantsLayer", cycle { let l = self.label(); l.wantsLayer = true; return l }),
            p("knob: refusesFirstResponder + focusRingType none", cycle {
                let l = self.label(); l.refusesFirstResponder = true; l.focusRingType = .none; return l
            }),
            p("knob: controlSize small", cycle { let l = self.label(); l.controlSize = .small; return l }),
            p("knob: cell.isScrollable / usesSingleLineMode", cycle {
                let l = self.label(); l.cell?.usesSingleLineMode = true; l.cell?.isScrollable = false; return l
            }),
            p("knob: NSTextView as the label (not a control)", cycle {
                let t = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20)); t.string = "hello"; t.isEditable = false; return t
            }),
        ])
    }

    // MARK: our views

    func testRealViews() {
        chain([
            p("real: UserBubbleView", n: 150, cycleOf { UserBubbleView(text: "a question the user asked") }),
            p("real: TextBlockView plain", n: 150, cycleOf { TextBlockView(text: "Plain words " + String(repeating: "more ", count: 30)) }),
            p("real: ToolCallView", n: 150, cycleOf {
                ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: "ls -la /tmp", inputFull: "{}"))
            }),
            p("real: ChatTurnView (4 blocks + bubble)", n: 100, cycleOf {
                let t = ChatTurn(userInput: "question about the thing", timestamp: Date(), blocks: [
                    .text("A plain paragraph of text that wraps. " + String(repeating: "word ", count: 40)),
                    .text("# Heading\n\nSome **markdown** with `code` and a list:\n\n- one\n- two"),
                    .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls -la", inputFull: "{\"command\":\"ls -la\"}")),
                    .text("Closing text."),
                ], isComplete: true)
                let v = ChatTurnView(turn: t, contentAvailable: true, interaction: TurnInteractionState())
                v.setIslandWidth(800)
                return v
            }),
        ])
    }

    private func cycleOf(_ make: @escaping () -> NSView) -> (NSView) -> Void {
        { h in
            let v = make()
            v.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
            h.addSubview(v)
            h.layoutSubtreeIfNeeded()
            v.removeFromSuperview()
        }
    }
}
