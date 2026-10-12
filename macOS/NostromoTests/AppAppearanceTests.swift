import XCTest
import AppKit

/// The UI is dark by construction. If the app follows a Light system appearance, every
/// system-drawn label resolves to dark-on-dark and is invisible (the Teri tabs and the
/// list toolbars on the user's Light-mode Mac). These tests render real controls into a
/// bitmap with the app appearance the way the running app now sets it.
final class AppAppearanceTests: XCTestCase {
    override func tearDown() {
        NSApplication.shared.appearance = nil
        super.tearDown()
    }

    /// Luminance of the brightest pixel the control draws on a near-black host.
    private func brightestPixel(of make: () -> NSView) -> (label: Double, background: Double) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor
        window.contentView = host
        let control = make()
        control.frame = NSRect(x: 10, y: 10, width: 200, height: 28)
        host.addSubview(control)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (0, 0) }
        host.cacheDisplay(in: host.bounds, to: rep)
        var brightest = 0.0
        var background = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let l = 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
                brightest = max(brightest, l)
                if x == 2 && y == 2 { background = l }
            }
        }
        return (brightest, background)
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

    private func plainButton() -> NSView {
        let b = NSButton(title: "Send to agent\u{2026}", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }

    func testTheAppIsPinnedToDarkAqua() {
        AppAppearance.apply(to: NSApplication.shared)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
    }

    func testSystemDrawnLabelsAreLegibleOnTheDarkSurfaceWhateverTheSystemAppearanceIs() {
        AppAppearance.apply(to: NSApplication.shared)

        for (name, make) in [("recessed tab button", recessedTabButton), ("toolbar popup", toolbarPopup),
                             ("bezelled button", plainButton)] as [(String, () -> NSView)] {
            let (label, background) = brightestPixel(of: make)
            XCTAssertGreaterThan(label, background + 0.5,
                                 "\(name): its label must be clearly brighter than the dark surface (label \(label), surface \(background))")
        }
    }

    func testWithoutThePinALightSystemMakesTheSameLabelsInvisible() throws {
        // Documents the failure this guards against; only meaningful on a Light-mode Mac.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let (label, background) = brightestPixel(of: recessedTabButton)
        XCTAssertLessThan(label, background + 0.2, "in Aqua the label is dark on the dark surface (label \(label), surface \(background))")
    }
}
