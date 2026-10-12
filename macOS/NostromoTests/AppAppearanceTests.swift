import XCTest
import AppKit

/// The UI is dark by construction. If the app follows a Light system appearance, every
/// system-drawn label resolves to dark-on-dark and is invisible (the Teri tabs and the
/// list toolbars on the user's Light-mode Mac). These tests render real controls into a
/// bitmap with the app appearance the way the running app now sets it.
final class AppAppearanceTests: XCTestCase {
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
    }

    override func tearDown() {
        NSApplication.shared.appearance = previousAppearance
        super.tearDown()
    }

    private struct Measure {
        /// Brightest pixel anywhere in the host.
        var label: Double
        /// The host's background (a pixel outside the control).
        var background: Double
        /// The control's surface: the median luminance of its text area (the bezel, or the
        /// field, that the label is drawn on).
        var surface: Double
        /// The brightest pixel inside the text area.
        var textAreaBrightest: Double
    }

    private static let controlFrame = NSRect(x: 10, y: 10, width: 200, height: 28)

    /// Luminance figures for the control drawn on a near-black host.
    private func measure(_ make: () -> NSView) -> Measure {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor
        window.contentView = host
        let control = make()
        control.frame = Self.controlFrame
        host.addSubview(control)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return Measure(label: 0, background: 0, surface: 0, textAreaBrightest: 0)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        // The control's text area in bitmap rows (the bitmap's origin is top-left, the host's bottom-left).
        let area = Self.controlFrame.insetBy(dx: 8, dy: 5)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width   // 2 on a Retina display
        let rows = Int((host.bounds.height - area.maxY) * scale)..<Int((host.bounds.height - area.minY) * scale)
        let columns = Int(area.minX * scale)..<Int(area.maxX * scale)
        var brightest = 0.0
        var background = 0.0
        var areaLuminances: [Double] = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let l = 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
                brightest = max(brightest, l)
                if x == 2 && y == 2 { background = l }
                if columns.contains(x) && rows.contains(y) { areaLuminances.append(l) }
            }
        }
        let sorted = areaLuminances.sorted()
        return Measure(label: brightest, background: background,
                       surface: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                       textAreaBrightest: sorted.last ?? 0)
    }

    private func recessedTabButton() -> NSView {
        let b = NSButton(title: "Todos 2", target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .recessed
        b.attributedTitle = NSAttributedString(string: "Todos 2", attributes: [.foregroundColor: NSColor.labelColor])
        b.state = .off
        return b
    }

    private func toolbarPopup() -> NSView {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.addItems(withTitles: ["Open in\u{2026}", "Jira"])
        return p
    }

    private func searchField() -> NSView {
        let f = NSSearchField(frame: .zero)
        f.stringValue = "Filter issues"
        return f
    }

    private func plainButton() -> NSView {
        let b = NSButton(title: "Send to agent\u{2026}", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }

    func testTheAppIsPinnedToDarkAqua() {
        AppAppearance.apply(to: NSApplication.shared)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
    }

    private func allControls() -> [(String, () -> NSView)] {
        [("recessed tab button", recessedTabButton), ("toolbar popup", toolbarPopup),
         ("bezelled button", plainButton), ("search field", searchField)]
    }

    func testSystemDrawnLabelsAreLegibleOnTheDarkSurfaceWhateverTheSystemAppearanceIs() {
        AppAppearance.apply(to: NSApplication.shared)

        for (name, make) in allControls() {
            let m = measure(make)
            XCTAssertGreaterThan(m.label, m.background + 0.5,
                                 "\(name): its label must be clearly brighter than the dark surface (label \(m.label), surface \(m.background))")
        }
    }

    /// The check above would also pass for dark text on a bright bezel (the bezel is the brightest
    /// pixel). Inside the control's own text area the label must be lighter than the surface it is
    /// drawn on, and that surface must itself be dark.
    func testTheLabelIsLighterThanItsOwnBezelNotDarkTextOnABrightOne() {
        AppAppearance.apply(to: NSApplication.shared)

        for (name, make) in allControls() {
            let m = measure(make)
            XCTAssertLessThan(m.surface, 0.5,
                              "\(name): the surface under the label must be dark (surface \(m.surface))")
            XCTAssertGreaterThan(m.textAreaBrightest, m.surface + 0.3,
                                 "\(name): the label must be clearly brighter than the surface it sits on (label \(m.textAreaBrightest), surface \(m.surface))")
        }
    }

    func testWithoutThePinALightSystemMakesTheSameLabelsInvisible() throws {
        // Documents the failure this guards against. The test sets Aqua itself, so it does not
        // depend on the Mac's own appearance setting.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let m = measure(recessedTabButton)
        XCTAssertLessThan(m.label, m.background + 0.2, "in Aqua the label is dark on the dark surface (label \(m.label), surface \(m.background))")
    }
}
