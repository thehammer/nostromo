import XCTest
import AppKit
import NostromoKit

// WCO: the real `MainLayout` (sidebar, pace bars, status bar, ticker, and a real
// `DynamicFocusView` with `RatioSplitView`, `ReplView` and `PaneContentNSView`
// hosting the SwiftUI `PaneContentHost`) inside a window that cannot grow, the way a
// full-screen window cannot. Measured live on 2026-10-21: the two 1920-wide
// full-screen windows had a `MainLayout` 2714/2715 pt wide (and up to 70 pt too tall),
// so the right side and the top of the content were cut off, while the 1710-wide
// built-in window was fine.
//
// A full-screen window's frame is fixed by the system. Auto Layout still lets any
// constraint above the window's "stay put" priority (500) grow the content view past
// it, so a window pinned at min == max size is the faithful offscreen model: whatever
// the content demands beyond the window shows up as `MainLayout.frame` exceeding the
// window's content rect.
final class WindowContentOverflowTests: XCTestCase {

    // MARK: - Fixtures

    private struct Scenario {
        let name: String
        let focusId: String
        let tree: PaneTree
        let content: [String: PaneContentWire]
    }

    private static let longLine = String(repeating: "word ", count: 90)   // ~450 chars, no newline
    private static var longLines: String { Array(repeating: longLine, count: 60).joined(separator: "\n") }
    private static var shortLines: String { Array(repeating: "short line of text", count: 20).joined(separator: "\n") }

    private static var scenarios: [Scenario] {
        let replPlusText: PaneTree = .split(direction: .horizontal,
                                            children: [.leaf(paneId: "repl"), .leaf(paneId: "plans")],
                                            ratios: [0.5, 0.5])
        return [
            Scenario(name: "repl-only", focusId: "perri", tree: .replLeaf, content: [:]),
            Scenario(name: "repl+text(short)", focusId: "perri", tree: replPlusText,
                     content: ["plans": .text(shortLines)]),
            Scenario(name: "repl+text(long lines)", focusId: "perri", tree: replPlusText,
                     content: ["plans": .text(longLines)]),
            Scenario(name: "repl+text(one 6000-char line)", focusId: "perri", tree: replPlusText,
                     content: ["plans": .text(String(repeating: "x", count: 6000))]),
            Scenario(name: "mother", focusId: "mother",
                     tree: .split(direction: .vertical,
                                  children: [.leaf(paneId: "mother_queue"), .leaf(paneId: "repl")],
                                  ratios: [0.8, 0.2]),
                     content: [:]),
        ]
    }

    private static let sizes: [NSSize] = [
        NSSize(width: 1920, height: 1080),
        NSSize(width: 1710, height: 1073),
        NSSize(width: 2560, height: 1440),
    ]

    /// A window that never moves or resizes for the content: min == max content size,
    /// and no frame constraining against the (virtual, small) CI screen.
    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Rig {
        let window: NSWindow
        let layout: MainLayout
    }

    private func makeRig(_ scenario: Scenario, size: NSSize, index: Int, pinned: Bool = true) -> Rig {
        let displayUUID = "wco-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == scenario.focusId }!
        UserDefaults.standard.set(scenario.focusId, forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }

        let store = AppStore.shared
        store.applyForTesting(.focusLayout(tag: focus.sessionTag, tree: scenario.tree, focusedPane: nil))
        for (paneId, content) in scenario.content {
            store.applyForTesting(.paneContent(tag: focus.sessionTag, paneId: paneId, content: content,
                                               freshness: nil, address: nil))
        }

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        if pinned {
            window.contentMinSize = size
            window.contentMaxSize = size
        }
        let layout = MainLayout(windowIndex: index, displayUUID: displayUUID)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        settle(window)
        return Rig(window: window, layout: layout)
    }

    /// Lets Combine sinks (`receive(on: main)`) and the layout passes they schedule run.
    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    // MARK: - Measuring

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    private func allSubviews(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews($0) }
    }

    /// Views whose on-window rectangle pokes outside the window's content rect. Scrolled
    /// document content (anything inside an `NSScrollView`) legitimately extends past the
    /// visible area and is skipped; the scroll view itself is still checked.
    private func escapingViews(in rig: Rig) -> [(view: NSView, rect: NSRect)] {
        let content = NSRect(origin: .zero, size: contentSize(of: rig.window))
        var out: [(NSView, NSRect)] = []
        for v in allSubviews(rig.layout) {
            if v.isHiddenOrHasHiddenAncestor { continue }
            if v.enclosingScrollView != nil && !(v is NSScrollView) { continue }
            let r = v.convert(v.bounds, to: nil)
            if r.maxX > content.maxX + 3 || r.maxY > content.maxY + 3 || r.minX < -3 || r.minY < -3 {
                out.append((v, r))
            }
        }
        return out
    }

    private func describe(_ v: NSView) -> String {
        let r = v.convert(v.bounds, to: nil)
        let intrinsic = v.intrinsicContentSize
        return "\(type(of: v)) frameInWindow=\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)) "
            + "intrinsic=\(Int(intrinsic.width))x\(Int(intrinsic.height)) fitting=\(Int(v.fittingSize.width))x\(Int(v.fittingSize.height))"
    }

    private func report(_ rig: Rig) -> String {
        var lines: [String] = []
        let content = contentSize(of: rig.window)
        lines.append("window.frame=\(rig.window.frame.size) content=\(content) layout=\(rig.layout.frame.size) "
                     + "layout.fitting=\(rig.layout.fittingSize)")
        for v in allSubviews(rig.layout) where String(describing: type(of: v)).contains("HostingView") {
            lines.append("  hosting: \(describe(v))")
        }
        for (v, _) in escapingViews(in: rig).prefix(12) {
            lines.append("  escapes: \(describe(v))")
        }
        for c in heavyConstraints(in: rig.layout).prefix(12) {
            lines.append("  heavy: \(c)")
        }
        return lines.joined(separator: " ¦ ")
    }

    /// Width-affecting constraints strictly between the window's "stay put" priority (500)
    /// and required: the ones that can push a content view past a window that cannot grow.
    private func heavyConstraints(in root: NSView) -> [String] {
        var out: [String] = []
        for v in [root] + allSubviews(root) {
            for c in v.constraints where c.isActive && c.priority.rawValue > 500 && c.priority.rawValue < 1000 {
                out.append("\(type(of: v)):\(type(of: c)) p=\(Int(c.priority.rawValue)) \(c)")
            }
        }
        return out
    }

    private func assertFits(_ rig: Rig, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let content = contentSize(of: rig.window)
        let layoutSize = rig.layout.frame.size
        let escaping = escapingViews(in: rig)
        if layoutSize != content || !escaping.isEmpty {
            XCTFail("\(label): MainLayout \(layoutSize) vs window content \(content); \(escaping.count) view(s) escape ¦ \(report(rig))",
                    file: file, line: line)
        }
    }

    // MARK: - Tests

    func testMainLayoutFitsItsWindowForEveryFocusShapeAndWindowSize() {
        var index = 0
        for size in Self.sizes {
            for scenario in Self.scenarios {
                let rig = makeRig(scenario, size: size, index: index)
                index += 1
                assertFits(rig, "\(scenario.name) @ \(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    /// The content must follow the window down as well as up. A width latched while the
    /// window was big (a display that changed resolution, a window created on another
    /// display, a full-screen transition) must not keep the content that wide.
    func testMainLayoutFollowsTheWindowThroughResizeSequences() {
        let sequences: [[NSSize]] = [
            [NSSize(width: 2560, height: 1440), NSSize(width: 1920, height: 1080)],
            [NSSize(width: 1920, height: 1080), NSSize(width: 2560, height: 1440), NSSize(width: 1920, height: 1080)],
            [NSSize(width: 1440, height: 900), NSSize(width: 1920, height: 1080)],
            [NSSize(width: 3840, height: 2160), NSSize(width: 1710, height: 1073)],
        ]
        var index = 200
        var failures: [String] = []
        for scenario in Self.scenarios {
            for sequence in sequences {
                let rig = makeRig(scenario, size: sequence[0], index: index, pinned: false)
                index += 1
                for step in sequence.dropFirst() {
                    let frame = rig.window.frameRect(forContentRect: NSRect(origin: rig.window.frame.origin, size: step))
                    rig.window.setFrame(frame, display: true)
                    settle(rig.window)
                    let content = contentSize(of: rig.window)
                    if content != step || rig.layout.frame.size != step || !escapingViews(in: rig).isEmpty {
                        failures.append("[\(scenario.name) \(sequence.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: "→"))] "
                                        + "asked \(step) ¦ \(report(rig))")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) resize failure(s) ¦ " + failures.joined(separator: " ¦¦ "))
    }
}
