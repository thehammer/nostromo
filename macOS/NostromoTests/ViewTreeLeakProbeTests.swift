import XCTest
import AppKit
import Darwin

// PROBE (temporary): which of our view trees survive being discarded?
// Reports through XCTFail so the numbers come back in CI's failure lines.
final class ViewTreeLeakProbeTests: XCTestCase {

    private final class Weak { weak var view: NSView?; init(_ v: NSView) { view = v } }

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

    private enum Mode: String { case attach, detachedOnly, measureCycle }

    private func makeHost(dark: Bool) -> (NSWindow, NSView) {
        let window = FixedWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        return (window, host)
    }

    private func run(_ name: String, mode: Mode, dark: Bool = true, iterations: Int = 400,
                     build: () -> NSView) {
        let (window, host) = makeHost(dark: dark)
        // warm up so one-time caches do not count
        for _ in 0 ..< 20 {
            autoreleasepool {
                let v = build()
                if mode != .detachedOnly { host.addSubview(v) }
                v.setFrameSize(NSSize(width: 600, height: 100))
                v.layoutSubtreeIfNeeded()
                v.removeFromSuperview()
            }
        }
        settle()
        let before = Self.blocksInUse()
        var weaks: [Weak] = []
        for _ in 0 ..< iterations {
            autoreleasepool {
                let v = build()
                weaks.append(Weak(v))
                switch mode {
                case .detachedOnly:
                    v.setFrameSize(NSSize(width: 600, height: 100))
                    v.layoutSubtreeIfNeeded()
                    _ = v.fittingSize
                case .attach:
                    host.addSubview(v)
                    v.setFrameSize(NSSize(width: 600, height: 100))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    v.removeFromSuperview()
                case .measureCycle:
                    host.addSubview(v)
                    for _ in 0 ..< 3 { _ = ChatTurnView.measureIsland(v, width: 600) }
                    host.layoutSubtreeIfNeeded()
                    v.removeFromSuperview()
                }
            }
        }
        settle(5)
        let alive = weaks.filter { $0.view != nil }.count
        let growth = Self.blocksInUse() - before
        XCTFail("PROBE \(name)/\(mode.rawValue)/\(dark ? "dark" : "default"): \(iterations) iterations, "
                + "\(alive) views still alive, live malloc blocks +\(growth)")
    }

    private func turn(_ blocks: [TurnBlock]) -> ChatTurn {
        ChatTurn(userInput: "question about the thing", timestamp: Date(), blocks: blocks, isComplete: true)
    }

    private static let blocks: [TurnBlock] = [
        .text("A plain paragraph of text that wraps. " + String(repeating: "word ", count: 40)),
        .text("# Heading\n\nSome **markdown** with `code` and a list:\n\n- one\n- two\n\n```\nlet x = 1\n```"),
        .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls -la", inputFull: "{\"command\":\"ls -la\"}")),
        .text("Closing text."),
    ]

    func testProbePlainLabel() {
        for mode in [Mode.attach, .detachedOnly] {
            run("plainLabel", mode: mode) {
                let l = NSTextField(labelWithString: "hello world")
                l.textColor = Theme.fg
                return l
            }
        }
    }

    func testProbeCopyMenuLabel() {
        for mode in [Mode.attach, .detachedOnly] {
            run("copyMenuLabel", mode: mode) {
                let l = CopyMenuTextField(labelWithString: "hello world, selectable and wrapping text here")
                l.isSelectable = true
                l.lineBreakMode = .byWordWrapping
                l.maximumNumberOfLines = 0
                l.textColor = Theme.fg
                return l
            }
        }
    }

    func testProbeCopyMenuLabelDefaultAppearance() {
        run("copyMenuLabel", mode: .attach, dark: false) {
            let l = CopyMenuTextField(labelWithString: "hello world, selectable and wrapping text here")
            l.isSelectable = true
            return l
        }
    }

    func testProbeUserBubble() {
        for mode in [Mode.attach, .detachedOnly, .measureCycle] {
            run("userBubble", mode: mode) { UserBubbleView(text: "a question the user asked, long enough to wrap maybe") }
        }
    }

    func testProbeTextBlock() {
        for mode in [Mode.attach, .detachedOnly, .measureCycle] {
            run("textBlockPlain", mode: mode) { TextBlockView(text: "Plain words " + String(repeating: "more ", count: 30)) }
            run("textBlockMarkdown", mode: mode) { TextBlockView(text: "# Head\n\nSome **bold** and `code`\n\n- a\n- b\n") }
        }
    }

    func testProbeToolCall() {
        for mode in [Mode.attach, .detachedOnly, .measureCycle] {
            run("toolCall", mode: mode) {
                ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: "ls -la /tmp", inputFull: "{}"))
            }
        }
    }

    func testProbeChatTurn() {
        for mode in [Mode.attach, .detachedOnly] {
            run("chatTurn", mode: mode, iterations: 150) {
                let v = ChatTurnView(turn: turn(Self.blocks), contentAvailable: true, interaction: TurnInteractionState())
                v.setIslandWidth(800)
                return v
            }
        }
    }

    func testProbeChatTurnUnavailableBanner() {
        run("chatTurnBanner", mode: .attach, iterations: 150) {
            let v = ChatTurnView(turn: turn(Self.blocks), contentAvailable: false, interaction: TurnInteractionState())
            v.setIslandWidth(800)
            return v
        }
    }
}
