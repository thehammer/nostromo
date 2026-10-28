import XCTest
import AppKit

// `bin/nostromo-app screenshot` returns a PNG of a whole window, terminal pixels included. A terminal
// may be read by an agent only through `nostromo_read_terminal_screen` (needs a follow, redacts
// daemon-side), so a screenshot must never carry a terminal's pixels:
//
//   - In the real app (`SyntheticInputGate.allowsSynthetic` false) every terminal pane's terminal area is
//     painted over with an opaque solid block BEFORE the PNG is encoded.
//   - In the QA build (`allowsSynthetic` true) the PNG is the unchanged capture.
//   - If any terminal area cannot be placed in the capture, the screenshot is REFUSED (throws).
//
// The real views (`TerminalPaneHostView`, `NostromoTerminalView`) are SwiftTerm-backed and cannot be built
// in this bundle, so these tests use stand-ins conforming to `TerminalPixelSource`, shaped like the real
// pane: a header band, a clipping body holding a terminal view that is larger than the body and offset,
// and a connecting overlay and an ended overlay drawn over the body. The capture is a REAL render of the
// window content (`cacheDisplay`, the server's own fallback path), so coordinate conversion is
// exercised through flipped and non-flipped ancestors and nested containers with non-zero origins.
//
// What the tests read is the DECODED PNG that `pngData` returns, never internal state. The terminal's
// pixels are a loud CANARY (magenta and lime stripes, plus a loud orange / translucent cyan overlay): a
// pixel is "loud" when its channels spread widely, which nothing else in the harness (grey, muted blue
// header) and nothing in the redaction block or its label (grey / white) is. The canary-must-bite control
// test proves the detector sees canary pixels in an unregistered view, and every "hidden" check has a
// "shown" mirror (gate relaxed) proving the canary is really in the unredacted capture.
//
// The server writes only the Data `pngData` returns, and only after it returns (see the source-policy
// test), so "the unredacted image is never written" reduces to `pngData` creating no file itself.
//
// Assumption: the label drawn inside the block is low saturation (grey / white), so the "loud" canary
// detector never mistakes it for terminal pixels.

// MARK: - Palette

private enum SRPalette {
    static let canaryA = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)           // magenta stripes
    static let canaryB = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)           // lime stripes
    static let connecting = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)      // loud orange message
    static let ended = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.5)           // translucent cyan, terminal shows through
    static let header = NSColor(srgbRed: 0.35, green: 0.43, blue: 0.50, alpha: 1)   // muted: not "loud"
    static let window = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)
    static let environmentLabel = NSColor(srgbRed: 0.62, green: 0.55, blue: 0.48, alpha: 1)
    static let stage = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    static let column = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1)
    static let inner = NSColor(srgbRed: 0.84, green: 0.84, blue: 0.84, alpha: 1)
}

// MARK: - Stand-in views

/// Paints its bounds one colour; can be flipped to put a flipped superview in the chain.
private final class SRSolidView: NSView {
    var color: NSColor
    private let flippedCoordinates: Bool

    init(frame: NSRect = .zero, color: NSColor, flipped: Bool = false) {
        self.color = color
        self.flippedCoordinates = flipped
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { flippedCoordinates }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

/// The terminal's pixels: loud alternating stripes, painted only inside the superview's bounds (what a
/// clipping body does), so a terminal bigger than its container shows only the part inside it.
private final class SRTerminalSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        if let parent = superview {
            NSBezierPath(rect: convert(parent.bounds, from: parent)).addClip()
        }
        var x = bounds.minX
        var index = 0
        while x < bounds.maxX {
            (index % 2 == 0 ? SRPalette.canaryA : SRPalette.canaryB).setFill()
            NSBezierPath(rect: NSRect(x: x, y: bounds.minY, width: 8, height: bounds.height)).fill()
            x += 8
            index += 1
        }
    }
}

/// The clipping body that is the pane's `terminalPixelArea`. After the capture a test can make its
/// geometry unusable (NaN / infinite) to prove the screenshot is refused. The poison is applied only
/// after the render, so AppKit never sees it while drawing.
private final class SRBody: NSView {
    enum Poison { case none, nan, infinity }
    var poison = Poison.none

    private var poisoned: NSRect? {
        switch poison {
        case .none: return nil
        case .nan: return NSRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan)
        case .infinity: return NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)
        }
    }

    override var bounds: NSRect {
        get { poisoned ?? super.bounds }
        set { super.bounds = newValue }
    }

    override var frame: NSRect {
        get { poisoned ?? super.frame }
        set { super.frame = newValue }
    }

    override func convert(_ rect: NSRect, to view: NSView?) -> NSRect {
        poisoned ?? super.convert(rect, to: view)
    }
}

/// Stands in for `TerminalPaneHostView`: header band, a clipping body with an oversized offset terminal,
/// and the connecting / ended overlays drawn over the body. Not flipped, like the real host.
private final class SRPaneHost: NSView, TerminalPixelSource {
    static let headerHeight: CGFloat = 20

    let header = SRSolidView(color: SRPalette.header)
    let body = SRBody()
    let terminal = SRTerminalSurface()
    let connectingOverlay = SRSolidView(color: SRPalette.connecting)
    let endedOverlay = SRSolidView(color: SRPalette.ended)

    /// The whole body: the terminal, anything scrolled or clipped inside it, and the overlays over it.
    var terminalPixelArea: NSView { body }

    init(frame: NSRect, terminalFrame: NSRect?) {
        super.init(frame: frame)
        let bodyFrame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - Self.headerHeight)
        header.frame = NSRect(x: 0, y: bodyFrame.height, width: frame.width, height: Self.headerHeight)
        body.frame = bodyFrame
        // Scrolled / mirrored: bigger than the body and offset from it.
        terminal.frame = terminalFrame ?? NSRect(x: -10, y: -8, width: bodyFrame.width + 24, height: bodyFrame.height + 20)
        connectingOverlay.frame = NSRect(x: 20, y: 30, width: 160, height: 50)
        endedOverlay.frame = NSRect(x: 0, y: 0, width: frame.width, height: 30)
        connectingOverlay.isHidden = true
        endedOverlay.isHidden = true
        addSubview(header)
        addSubview(body)
        body.addSubview(terminal)
        addSubview(connectingOverlay)
        addSubview(endedOverlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A conformer whose area is some OTHER view (detached, in another window, or empty).
private final class SRForeignAreaPane: NSView, TerminalPixelSource {
    let area: NSView
    var terminalPixelArea: NSView { area }

    init(frame: NSRect, area: NSView) {
        self.area = area
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Rig

/// An offscreen titled window (never ordered front):
///
///     contentView (not flipped)                     "environment label" stand-in strip along the top
///       stage (FLIPPED, offset from the origin)
///         column (not flipped, offset)
///           inner (FLIPPED, offset)
///             pane host (not flipped, offset)       header | body (clips) > terminal, overlays
private final class SRRig {
    static let contentSize = NSSize(width: 560, height: 440)

    let window: NSWindow
    let cv: SRSolidView
    let stage: SRSolidView
    private(set) var panes: [SRPaneHost] = []
    private var extraWindows: [NSWindow] = []

    init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        cv = SRSolidView(frame: NSRect(origin: .zero, size: Self.contentSize), color: SRPalette.window)
        window.contentView = cv
        cv.addSubview(SRSolidView(frame: NSRect(x: 0, y: 420, width: 560, height: 20), color: SRPalette.environmentLabel))
        stage = SRSolidView(frame: NSRect(x: 24, y: 16, width: 512, height: 392), color: SRPalette.stage, flipped: true)
        cv.addSubview(stage)
    }

    /// A pane nested stage > column > inner > host (two columns fit side by side).
    @discardableResult
    func addPane(column index: Int, terminalFrame: NSRect? = nil,
                 connecting: Bool = false, ended: Bool = false) -> SRPaneHost {
        let column = SRSolidView(frame: NSRect(x: 10 + CGFloat(index) * 252, y: 10, width: 240, height: 372),
                                 color: SRPalette.column)
        stage.addSubview(column)
        let inner = SRSolidView(frame: NSRect(x: 6, y: 40, width: 228, height: 300), color: SRPalette.inner, flipped: true)
        column.addSubview(inner)
        let host = SRPaneHost(frame: NSRect(x: 5, y: 7, width: 200, height: 140), terminalFrame: terminalFrame)
        host.connectingOverlay.isHidden = !connecting
        host.endedOverlay.isHidden = !ended
        inner.addSubview(host)
        panes.append(host)
        return host
    }

    /// A conformer (in the window) whose `terminalPixelArea` is `area`.
    @discardableResult
    func addForeign(area: NSView) -> SRForeignAreaPane {
        let pane = SRForeignAreaPane(frame: NSRect(x: 300, y: 300, width: 60, height: 40), area: area)
        stage.addSubview(pane)
        return pane
    }

    /// A second window with one view in it, for "an area from another window".
    func viewInAnotherWindow() -> NSView {
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let content = SRSolidView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), color: SRPalette.window)
        other.contentView = content
        let area = SRSolidView(frame: NSRect(x: 30, y: 20, width: 150, height: 90), color: SRPalette.stage)
        content.addSubview(area)
        extraWindows.append(other)
        return area
    }

    func teardown() {
        for pane in panes { pane.body.poison = .none }
        window.contentView = nil
        window.close()
        for other in extraWindows { other.contentView = nil; other.close() }
    }

    /// A real render of `view` (the server's `cacheDisplay` path). `pixelScale` forces a rep with that many
    /// pixels per point regardless of the machine's display; `cgImageBacked` rebuilds the rep from its
    /// CGImage, so `rep.size` is in pixels, as for a window-server capture.
    func capture(_ view: NSView, base: NSRect? = nil, pixelScale: Int? = nil, cgImageBacked: Bool = false) throws -> SRCapture {
        view.layoutSubtreeIfNeeded()
        let rect = base ?? view.convert(view.bounds, to: nil)
        var rep: NSBitmapImageRep
        if let scale = pixelScale {
            rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = view.bounds.size
        } else {
            rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if cgImageBacked {
            rep = NSBitmapImageRep(cgImage: try XCTUnwrap(rep.cgImage))
        }
        return SRCapture(rep: rep, rect: rect)
    }
}

/// A capture and where it sits in window base coordinates (bottom-left origin).
private struct SRCapture {
    let rep: NSBitmapImageRep
    let rect: NSRect

    /// Pixels per point.
    var scale: CGFloat { CGFloat(rep.pixelsWide) / rect.width }

    /// `base` (window base coordinates, bottom-left) as a pixel rect in this image (top-down).
    func pixelRect(of base: NSRect) -> SRPixelRect {
        let s = scale
        return SRPixelRect(x0: Int(((base.minX - rect.minX) * s).rounded()),
                           y0: Int(((rect.maxY - base.maxY) * s).rounded()),
                           x1: Int(((base.maxX - rect.minX) * s).rounded()),
                           y1: Int(((rect.maxY - base.minY) * s).rounded()))
    }

    func with(rect newRect: NSRect) -> SRCapture { SRCapture(rep: rep, rect: newRect) }
}

// MARK: - Pixels

private struct SRRGB {
    var r: Int, g: Int, b: Int

    init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = Int((c.redComponent * 255).rounded())
        g = Int((c.greenComponent * 255).rounded())
        b = Int((c.blueComponent * 255).rounded())
    }

    func distance(to other: SRRGB) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }

    /// How saturated: widest spread between channels. The canary is loud; grey, white and the muted header are not.
    var chroma: Int { max(r, g, b) - min(r, g, b) }
}

/// Half-open pixel rect, top-down.
private struct SRPixelRect: Equatable, CustomStringConvertible {
    var x0: Int, y0: Int, x1: Int, y1: Int

    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var description: String { "[x \(x0)..<\(x1), y \(y0)..<\(y1)]" }

    func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }

    func expanded(by n: Int, width w: Int, height h: Int) -> SRPixelRect {
        SRPixelRect(x0: max(0, x0 - n), y0: max(0, y0 - n), x1: min(w, x1 + n), y1: min(h, y1 + n))
    }
}

private struct SRPixels {
    static let loudChroma = 110

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(rep: NSBitmapImageRep) {
        guard let cg = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = data
    }

    init?(png: Data) {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        self.init(rep: rep)
    }

    var fullRect: SRPixelRect { SRPixelRect(x0: 0, y0: 0, x1: width, y1: height) }

    func rgb(_ x: Int, _ y: Int) -> SRRGB {
        let i = (y * width + x) * 4
        return SRRGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    func isLoud(_ x: Int, _ y: Int) -> Bool { rgb(x, y).chroma >= Self.loudChroma }

    func loudCount(in rect: SRPixelRect, excluding: [SRPixelRect] = []) -> Int {
        var n = 0
        for y in max(0, rect.y0)..<min(height, rect.y1) {
            for x in max(0, rect.x0)..<min(width, rect.x1) {
                if excluding.contains(where: { $0.contains(x, y) }) { continue }
                if isLoud(x, y) { n += 1 }
            }
        }
        return n
    }

    /// Bounding box of the loud pixels inside `rect`, if any.
    func loudBounds(in rect: SRPixelRect) -> SRPixelRect? {
        var box: SRPixelRect?
        for y in max(0, rect.y0)..<min(height, rect.y1) {
            for x in max(0, rect.x0)..<min(width, rect.x1) where isLoud(x, y) {
                if var b = box {
                    b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x + 1); b.y1 = max(b.y1, y + 1)
                    box = b
                } else {
                    box = SRPixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)
                }
            }
        }
        return box
    }

    func isFill(_ x: Int, _ y: Int, tolerance: Int = 10) -> Bool {
        rgb(x, y).distance(to: SRRGB(ScreenshotRedaction.fillColor)) <= tolerance
    }

    func fillCount(in rect: SRPixelRect) -> Int {
        var n = 0
        for y in max(0, rect.y0)..<min(height, rect.y1) {
            for x in max(0, rect.x0)..<min(width, rect.x1) where isFill(x, y) { n += 1 }
        }
        return n
    }

    /// How many pixels differ from `other` by more than `tolerance` in any channel, skipping `excluding`.
    func mismatches(against other: SRPixels, excluding: [SRPixelRect], tolerance: Int = 3) -> Int {
        guard width == other.width, height == other.height else { return Int.max }
        var n = 0
        for y in 0..<height {
            for x in 0..<width {
                if excluding.contains(where: { $0.contains(x, y) }) { continue }
                let i = (y * width + x) * 4
                if abs(Int(bytes[i]) - Int(other.bytes[i])) > tolerance
                    || abs(Int(bytes[i + 1]) - Int(other.bytes[i + 1])) > tolerance
                    || abs(Int(bytes[i + 2]) - Int(other.bytes[i + 2])) > tolerance { n += 1 }
            }
        }
        return n
    }
}

/// One run of "capture twice (baseline and the one handed to `pngData`), redact, decode".
private struct SRRender {
    let baseline: SRPixels      // the unredacted capture, decoded
    let output: SRPixels        // the PNG `pngData` returned, decoded
    let capture: SRCapture      // the capture (for scale and rect)
    let regions: [SRPixelRect]  // each terminal area in pixels, from AppKit's own conversion
    let ignoreTopRows: Int      // window chrome rows to leave out of whole-image checks
}

// MARK: - Source helpers (policy checks)

private enum SRSource {
    /// `<repo>`: this file is `<repo>/macOS/NostromoTests/ScreenshotRedactionTests.swift`.
    static func root(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    static var app: URL { root().appendingPathComponent("macOS/Nostromo") }

    static func read(_ relative: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(relative), encoding: .utf8)
    }
}

// MARK: - Tests

final class ScreenshotRedactionTests: XCTestCase {

    private var rigs: [SRRig] = []

    override func tearDown() {
        for rig in rigs { rig.teardown() }
        rigs = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeRig() -> SRRig {
        let rig = SRRig()
        rigs.append(rig)
        return rig
    }

    /// Captures twice (baseline vs the capture handed to `pngData`), runs `pngData`, decodes both, and
    /// checks the harness itself: each terminal's canary fills exactly its region in the baseline and is
    /// nowhere else, so any canary left after redaction is a real leak.
    private func render(_ rig: SRRig, allowsSynthetic: Bool, ignoreTopRows: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line,
                        take: () throws -> SRCapture) throws -> SRRender {
        let baseCapture = try take()
        let baseline = try XCTUnwrap(SRPixels(rep: baseCapture.rep), "harness: cannot read the baseline capture", file: file, line: line)
        let capture = try take()
        let data = try ScreenshotRedaction.pngData(of: capture.rep, window: rig.window,
                                                   captureRect: capture.rect, allowsSynthetic: allowsSynthetic)
        let output = try XCTUnwrap(SRPixels(png: data), "pngData did not return a decodable PNG", file: file, line: line)

        let regions = rig.panes.map { pane -> SRPixelRect in
            let area = pane.terminalPixelArea
            return baseCapture.pixelRect(of: area.convert(area.bounds, to: nil))
        }
        for (i, region) in regions.enumerated() {
            let search = region.expanded(by: 4, width: baseline.width, height: baseline.height)
            XCTAssertEqual(baseline.loudBounds(in: search), region,
                           "harness: pane \(i)'s canary must fill its terminal area exactly in the baseline", file: file, line: line)
        }
        let interior = SRPixelRect(x0: 0, y0: ignoreTopRows, x1: baseline.width, y1: baseline.height)
        XCTAssertEqual(baseline.loudCount(in: interior, excluding: regions), 0,
                       "harness: canary must not appear outside the terminal areas in the baseline", file: file, line: line)
        return SRRender(baseline: baseline, output: output, capture: baseCapture, regions: regions, ignoreTopRows: ignoreTopRows)
    }

    /// The real-app outcome: every terminal region is a solid block with no canary in it, the capture's
    /// dimensions are unchanged, and everything outside the regions is as drawn.
    private func assertRedacted(_ r: SRRender, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.output.width, r.capture.rep.pixelsWide, "PNG width must equal the capture's", file: file, line: line)
        XCTAssertEqual(r.output.height, r.capture.rep.pixelsHigh, "PNG height must equal the capture's", file: file, line: line)
        guard r.output.width == r.baseline.width, r.output.height == r.baseline.height else { return }
        XCTAssertFalse(r.regions.isEmpty, "harness: expected at least one terminal region", file: file, line: line)

        for (i, region) in r.regions.enumerated() {
            let name = "terminal \(i) \(region)"
            XCTAssertGreaterThan(r.baseline.loudCount(in: region), 0, "\(name): canary must be in the capture before redaction", file: file, line: line)
            XCTAssertEqual(r.output.loudCount(in: region), 0, "\(name): terminal pixels survive inside the redacted region", file: file, line: line)

            let corners = [(region.x0, region.y0), (region.x1 - 1, region.y0),
                           (region.x0, region.y1 - 1), (region.x1 - 1, region.y1 - 1)]
            for (x, y) in corners {
                XCTAssertTrue(r.output.isFill(x, y), "\(name): corner (\(x),\(y)) is not the redaction colour: \(r.output.rgb(x, y))", file: file, line: line)
            }
            // Well away from where a centred label would sit.
            let samples = [(region.x0 + region.width / 4, region.y0 + region.height / 4),
                           (region.x0 + 3 * region.width / 4, region.y0 + region.height / 4),
                           (region.x0 + region.width / 4, region.y0 + 3 * region.height / 4),
                           (region.x0 + 3 * region.width / 4, region.y0 + 3 * region.height / 4)]
            for (x, y) in samples {
                XCTAssertTrue(r.output.isFill(x, y), "\(name): sample (\(x),\(y)) is not the redaction colour: \(r.output.rgb(x, y))", file: file, line: line)
            }
            let share = Double(r.output.fillCount(in: region)) / Double(max(1, region.width * region.height))
            XCTAssertGreaterThan(share, 0.8, "\(name): the block must cover the region (a label is small), got \(share)", file: file, line: line)
        }

        // Every block is the region plus `ScreenshotRedaction.padding` px on each side (clamped to the image).
        let pad = ScreenshotRedaction.padding
        for (i, region) in r.regions.enumerated() {
            let block = region.expanded(by: pad, width: r.output.width, height: r.output.height)
            let edges = [(block.x0, block.y0), (block.x1 - 1, block.y0), (block.x0, block.y1 - 1), (block.x1 - 1, block.y1 - 1),
                         (block.x0, (block.y0 + block.y1) / 2), (block.x1 - 1, (block.y0 + block.y1) / 2),
                         ((block.x0 + block.x1) / 2, block.y0), ((block.x0 + block.x1) / 2, block.y1 - 1)]
            for (x, y) in edges {
                XCTAssertTrue(r.output.isFill(x, y), "terminal \(i): padded block \(block) edge (\(x),\(y)) is not the redaction colour", file: file, line: line)
            }
        }
        let ring = r.regions.map { $0.expanded(by: pad + 1, width: r.output.width, height: r.output.height) }
        XCTAssertEqual(r.output.mismatches(against: r.baseline, excluding: ring), 0,
                       "pixels outside the padded terminal regions must be untouched", file: file, line: line)
        let interior = SRPixelRect(x0: 0, y0: r.ignoreTopRows, x1: r.output.width, y1: r.output.height)
        XCTAssertEqual(r.output.loudCount(in: interior), 0, "no canary pixel may remain anywhere in the image", file: file, line: line)
    }

    /// The QA-build outcome: the PNG is exactly the capture; canary present, no block.
    private func assertUnchanged(_ r: SRRender, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.output.width, r.baseline.width, file: file, line: line)
        XCTAssertEqual(r.output.height, r.baseline.height, file: file, line: line)
        guard r.output.width == r.baseline.width, r.output.height == r.baseline.height else { return }
        XCTAssertEqual(r.output.mismatches(against: r.baseline, excluding: [], tolerance: 2), 0,
                       "the QA build's screenshot must be the unchanged capture", file: file, line: line)
        for (i, region) in r.regions.enumerated() {
            XCTAssertGreaterThan(r.output.loudCount(in: region), 0, "terminal \(i): canary must be present when the gate allows it", file: file, line: line)
        }
        let interior = SRPixelRect(x0: 0, y0: r.ignoreTopRows, x1: r.output.width, y1: r.output.height)
        XCTAssertEqual(r.output.fillCount(in: interior), 0, "no redaction block may be drawn when the gate allows it", file: file, line: line)
    }

    private func attempt(_ rig: SRRig, _ capture: SRCapture, allowsSynthetic: Bool = false) -> Result<Data, Error> {
        Result { try ScreenshotRedaction.pngData(of: capture.rep, window: rig.window,
                                                 captureRect: capture.rect, allowsSynthetic: allowsSynthetic) }
    }

    private func assertRefused(_ result: Result<Data, Error>, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let data):
            XCTFail("\(message): expected a refusal but \(data.count) bytes of PNG were returned", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is ScreenshotRedactionError, "\(message): refused with the wrong error type: \(error)", file: file, line: line)
        }
    }

    private func tempListing() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
    }

    // MARK: Real app: a terminal pane is hidden

    func test_real_app_screenshot_replaces_the_terminal_body_with_a_solid_block() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        let r = try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) }
        assertRedacted(r)
    }

    func test_real_app_screenshot_leaves_the_pane_header_and_everything_outside_the_body_as_drawn() throws {
        let rig = makeRig()
        let pane = rig.addPane(column: 0)
        let r = try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) }
        // Pane header, the environment-label strip, and the window background, by colour in the decoded PNG.
        let header = r.capture.pixelRect(of: pane.header.convert(pane.header.bounds, to: nil))
        let strip = r.capture.pixelRect(of: NSRect(x: 0, y: 420, width: 560, height: 20))
        let probes: [(String, Int, Int, NSColor)] = [
            ("pane header", header.x0 + header.width / 2, header.y0 + header.height / 2, SRPalette.header),
            ("environment label", strip.x0 + strip.width / 2, strip.y0 + strip.height / 2, SRPalette.environmentLabel),
            ("window background", 2, r.output.height - 2, SRPalette.window),
        ]
        for (name, x, y, color) in probes {
            XCTAssertLessThanOrEqual(r.output.rgb(x, y).distance(to: SRRGB(color)), 6, "\(name) must be left as drawn, got \(r.output.rgb(x, y))")
        }
        XCTAssertFalse(r.output.isFill(header.x0 + header.width / 2, header.y0 + header.height / 2), "the header is not part of the terminal area")
    }

    func test_qa_build_screenshot_is_the_unchanged_capture_with_the_terminal_visible() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        let r = try render(rig, allowsSynthetic: true) { try rig.capture(rig.cv) }
        assertUnchanged(r)
    }

    // MARK: Overlays, mirrors, several panes

    func test_connecting_overlay_over_the_body_is_hidden_too() throws {
        let rig = makeRig()
        rig.addPane(column: 0, connecting: true)
        let shown = try render(rig, allowsSynthetic: true) { try rig.capture(rig.cv) }
        assertUnchanged(shown)
        let connectingColour = SRRGB(SRPalette.connecting)
        let region = shown.regions[0]
        let overlayPixels = (region.y0..<region.y1).reduce(0) { total, y in
            total + (region.x0..<region.x1).filter { shown.output.rgb($0, y).distance(to: connectingColour) <= 12 }.count
        }
        XCTAssertGreaterThan(overlayPixels, 0, "harness: the connecting overlay must be visible in the unredacted capture")

        let hidden = try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) }
        assertRedacted(hidden)
        let leftover = (region.y0..<region.y1).reduce(0) { total, y in
            total + (region.x0..<region.x1).filter { hidden.output.rgb($0, y).distance(to: connectingColour) <= 12 }.count
        }
        XCTAssertEqual(leftover, 0, "the connecting message must not survive in the redacted region")
    }

    func test_ended_overlay_that_lets_the_terminal_show_through_is_hidden_too() throws {
        let rig = makeRig()
        rig.addPane(column: 0, ended: true)
        assertUnchanged(try render(rig, allowsSynthetic: true) { try rig.capture(rig.cv) })
        assertRedacted(try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) })
    }

    func test_mirror_style_terminal_bigger_than_its_clipping_body_is_hidden_everywhere() throws {
        let rig = makeRig()
        // A mirrored terminal view far larger than the pane and offset from it; only the part inside the
        // body is drawn, so the redaction must cover exactly the body.
        rig.addPane(column: 0, terminalFrame: NSRect(x: -40, y: -30, width: 320, height: 220), connecting: true, ended: true)
        assertUnchanged(try render(rig, allowsSynthetic: true) { try rig.capture(rig.cv) })
        assertRedacted(try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) })
    }

    func test_every_terminal_pane_in_the_window_is_hidden_not_just_the_first() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        rig.addPane(column: 1, terminalFrame: NSRect(x: -60, y: -50, width: 400, height: 260), connecting: true)
        let shown = try render(rig, allowsSynthetic: true) { try rig.capture(rig.cv) }
        assertUnchanged(shown)
        XCTAssertEqual(shown.regions.count, 2)
        let hidden = try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) }
        assertRedacted(hidden)
        XCTAssertEqual(hidden.regions.count, 2)
    }

    // MARK: Where the capture sits

    func test_a_capture_of_a_view_that_is_not_at_the_window_origin_is_redacted_at_the_right_pixels() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        rig.addPane(column: 1)
        // The stage is flipped and sits at (24, 16) in the content view: captureRect has a non-zero origin.
        let stageRect = rig.stage.convert(rig.stage.bounds, to: nil)
        XCTAssertNotEqual(stageRect.origin, .zero, "harness: the captured view must be offset from the window origin")
        let r = try render(rig, allowsSynthetic: false) { try rig.capture(rig.stage) }
        XCTAssertEqual(r.capture.rect, stageRect)
        assertRedacted(r)
        assertUnchanged(try render(rig, allowsSynthetic: true) { try rig.capture(rig.stage) })
    }

    func test_a_whole_window_capture_including_the_title_bar_is_redacted_at_the_right_pixels() throws {
        // The window-server capture covers the whole frame (title bar included) with image rows
        // top-down; this renders the frame view the same way and passes `NSRect(origin: .zero, size: frame.size)`.
        let rig = makeRig()
        rig.addPane(column: 0)
        rig.addPane(column: 1, connecting: true)
        let frameView = try XCTUnwrap(rig.window.contentView?.superview, "harness: no frame view")
        XCTAssertEqual(frameView.bounds.size, rig.window.frame.size, "harness: frame view must cover the window frame")
        let whole = NSRect(origin: .zero, size: rig.window.frame.size)
        let titleBar = rig.window.frame.height - rig.cv.frame.height
        XCTAssertGreaterThan(titleBar, 0, "harness: a titled window has a title bar above the content")
        let take = { try rig.capture(frameView, base: whole) }
        let scale = try take().scale
        let chrome = Int((titleBar * scale).rounded(.up))

        let hidden = try render(rig, allowsSynthetic: false, ignoreTopRows: chrome, take: take)
        assertRedacted(hidden)
        assertUnchanged(try render(rig, allowsSynthetic: true, ignoreTopRows: chrome, take: take))
    }

    func test_a_2x_capture_whose_rep_size_is_in_pixels_is_redacted_at_the_right_pixels() throws {
        // Like a window-server capture on a Retina display: pixels are 2x the points and `rep.size` is
        // the pixel size (made from a CGImage), while captureRect is in points.
        let rig = makeRig()
        rig.addPane(column: 0, connecting: true)
        let take = { try rig.capture(rig.cv, pixelScale: 2, cgImageBacked: true) }
        let hidden = try render(rig, allowsSynthetic: false, take: take)
        XCTAssertEqual(hidden.capture.scale, 2, accuracy: 0.001, "harness: expected a 2x capture")
        XCTAssertEqual(hidden.regions[0].width, 400, "harness: the 200pt body is 400 pixels wide at 2x")
        XCTAssertEqual(hidden.regions[0].height, 240)
        assertRedacted(hidden)
        assertUnchanged(try render(rig, allowsSynthetic: true, take: take))
    }

    func test_a_2x_cacheDisplay_capture_whose_rep_size_is_in_points_is_redacted_at_the_right_pixels() throws {
        // Like `cacheDisplay` on a Retina display: pixels are 2x but `rep.size` stays in points. The scale
        // is pixels per point either way.
        let rig = makeRig()
        rig.addPane(column: 0)
        rig.addPane(column: 1)
        let take = { try rig.capture(rig.cv, pixelScale: 2) }
        let hidden = try render(rig, allowsSynthetic: false, take: take)
        XCTAssertEqual(hidden.capture.scale, 2, accuracy: 0.001, "harness: expected a 2x capture")
        assertRedacted(hidden)
        assertUnchanged(try render(rig, allowsSynthetic: true, take: take))
    }

    func test_png_has_the_captures_pixel_dimensions_in_both_modes() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        for allows in [false, true] {
            let cap = try rig.capture(rig.cv)
            let data = try ScreenshotRedaction.pngData(of: cap.rep, window: rig.window, captureRect: cap.rect, allowsSynthetic: allows)
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(decoded.pixelsWide, cap.rep.pixelsWide, "allowsSynthetic \(allows)")
            XCTAssertEqual(decoded.pixelsHigh, cap.rep.pixelsHigh, "allowsSynthetic \(allows)")
        }
    }

    // MARK: Padding, mismatch and visibility

    func test_a_two_pixel_vertical_mismatch_between_picture_and_view_tree_leaves_no_terminal_pixel_at_the_edges() throws {
        // The aspect guard tolerates 2 px of vertical drift; the y-mapping then lands the block up to 2 px
        // off. The padding must still cover every terminal pixel, whichever way the drift goes.
        for drift in [CGFloat(2), CGFloat(-2)] {
            let rig = makeRig()
            let pane = rig.addPane(column: 0)
            let cap = try rig.capture(rig.cv, pixelScale: 1)
            XCTAssertEqual(cap.scale, 1, accuracy: 0.001, "harness: expected a 1x capture")
            let baseline = try XCTUnwrap(SRPixels(rep: cap.rep))
            let area = pane.terminalPixelArea
            let region = cap.pixelRect(of: area.convert(area.bounds, to: nil))
            XCTAssertEqual(baseline.loudBounds(in: region.expanded(by: 4, width: baseline.width, height: baseline.height)), region,
                           "harness: the canary fills the terminal area exactly")
            let drifted = NSRect(origin: cap.rect.origin, size: NSSize(width: cap.rect.width, height: cap.rect.height + drift))
            let data = try ScreenshotRedaction.pngData(of: cap.rep, window: rig.window, captureRect: drifted, allowsSynthetic: false)
            let output = try XCTUnwrap(SRPixels(png: data))
            XCTAssertEqual(output.loudCount(in: output.fullRect), 0, "drift \(drift): terminal pixels survive, e.g. at a block edge")
        }
    }

    func test_a_visible_terminal_that_does_not_intersect_the_image_is_refused() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        let cap = try rig.capture(rig.cv)
        let elsewhere = NSRect(origin: NSPoint(x: cap.rect.origin.x + 5000, y: cap.rect.origin.y), size: cap.rect.size)
        assertRefused(attempt(rig, cap.with(rect: elsewhere)), "visible terminal mapped outside the image")
    }

    func test_a_hidden_terminal_that_does_not_intersect_the_image_is_skipped() throws {
        let rig = makeRig()
        let pane = rig.addPane(column: 0)
        let cap = try rig.capture(rig.cv)
        let elsewhere = NSRect(origin: NSPoint(x: cap.rect.origin.x + 5000, y: cap.rect.origin.y), size: cap.rect.size)
        pane.isHidden = true
        XCTAssertNoThrow(try ScreenshotRedaction.pngData(of: cap.rep, window: rig.window, captureRect: elsewhere, allowsSynthetic: false))
        pane.isHidden = false
        pane.superview?.isHidden = true   // hidden by an ancestor
        XCTAssertNoThrow(try ScreenshotRedaction.pngData(of: cap.rep, window: rig.window, captureRect: elsewhere, allowsSynthetic: false))
    }

    func test_the_real_pane_hides_its_whole_body_container_not_just_the_terminal_view() throws {
        // `TerminalPaneHostView` links SwiftTerm, which cannot be built into this test bundle, so the real
        // class can't be instantiated here. Pin its area choice in source instead: switching it to
        // `terminalView` would hide less than the container (a mirror's clipped overflow, the connecting
        // and ended overlays) and every stand-in test above would still pass.
        let text = try SRSource.read("UI/Terminal/TerminalPaneHostView.swift")
        XCTAssertNotNil(text.range(of: "var terminalPixelArea: NSView \\{ terminalContainer \\}", options: .regularExpression),
                        "TerminalPaneHostView.terminalPixelArea must return terminalContainer")
        XCTAssertNil(text.range(of: "terminalPixelArea: NSView \\{[^}]*terminalView", options: .regularExpression),
                     "TerminalPaneHostView.terminalPixelArea must not return the terminal view")
    }

    // MARK: Refusals: never leak what can't be placed

    func test_refuses_when_a_terminals_area_is_detached_from_any_window() throws {
        let rig = makeRig()
        rig.addForeign(area: SRSolidView(frame: NSRect(x: 0, y: 0, width: 100, height: 60), color: SRPalette.stage))
        let cap = try rig.capture(rig.cv)
        assertRefused(attempt(rig, cap), "detached area")
    }

    func test_refuses_when_a_terminals_area_belongs_to_another_window() throws {
        let rig = makeRig()
        rig.addForeign(area: rig.viewInAnotherWindow())
        let cap = try rig.capture(rig.cv)
        assertRefused(attempt(rig, cap), "area in another window")
    }

    func test_refuses_when_a_terminals_frame_is_not_a_finite_rectangle() throws {
        for poison in [SRBody.Poison.nan, .infinity] {
            let rig = makeRig()
            let pane = rig.addPane(column: 0)
            let cap = try rig.capture(rig.cv)
            pane.body.poison = poison
            assertRefused(attempt(rig, cap), "\(poison) frame")
        }
    }

    func test_refuses_when_one_terminal_resolves_and_another_does_not_in_either_order() throws {
        // Good pane first, unresolvable pane second.
        let goodFirst = makeRig()
        goodFirst.addPane(column: 0)
        goodFirst.addForeign(area: SRSolidView(frame: NSRect(x: 0, y: 0, width: 50, height: 50), color: SRPalette.stage))
        assertRefused(attempt(goodFirst, try goodFirst.capture(goodFirst.cv)), "good pane then detached area")

        // Unresolvable pane first, good pane second.
        let badFirst = makeRig()
        badFirst.addForeign(area: badFirst.viewInAnotherWindow())
        badFirst.addPane(column: 0)
        assertRefused(attempt(badFirst, try badFirst.capture(badFirst.cv)), "foreign area then good pane")

        // A good pane whose neighbour has a NaN frame.
        let nanSecond = makeRig()
        nanSecond.addPane(column: 0)
        let bad = nanSecond.addPane(column: 1)
        let cap = try nanSecond.capture(nanSecond.cv)
        bad.body.poison = .nan
        assertRefused(attempt(nanSecond, cap), "good pane then NaN pane")
    }

    func test_refuses_when_the_capture_cannot_be_mapped_to_window_coordinates() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        let cap = try rig.capture(rig.cv)
        assertRefused(attempt(rig, cap.with(rect: NSRect(origin: cap.rect.origin, size: .zero))), "zero-size capture rect")
        assertRefused(attempt(rig, cap.with(rect: NSRect(origin: cap.rect.origin, size: NSSize(width: 0, height: cap.rect.height)))), "zero-width capture rect")
        // Twice as wide as the image implies but the same height: horizontal and vertical scale disagree.
        let stretched = NSRect(origin: cap.rect.origin, size: NSSize(width: cap.rect.width * 2, height: cap.rect.height))
        assertRefused(attempt(rig, cap.with(rect: stretched)), "inconsistent scale")
    }

    func test_a_zero_sized_terminal_area_is_fine_and_other_terminals_are_still_hidden() throws {
        let rig = makeRig()
        rig.addPane(column: 0)
        let collapsed = SRForeignAreaPane(frame: NSRect(x: 300, y: 300, width: 60, height: 40), area: NSView(frame: NSRect(x: 5, y: 5, width: 0, height: 0)))
        collapsed.addSubview(collapsed.area)
        rig.stage.addSubview(collapsed)
        // A collapsed area has nothing to hide, and is not a reason to refuse. Only the real pane is a region.
        let r = try render(rig, allowsSynthetic: false) { try rig.capture(rig.cv) }
        assertRedacted(r)
    }

    func test_qa_build_resolves_nothing_so_unresolvable_areas_and_odd_rects_do_not_throw() throws {
        let rig = makeRig()
        let pane = rig.addPane(column: 0)
        rig.addForeign(area: SRSolidView(frame: NSRect(x: 0, y: 0, width: 50, height: 50), color: SRPalette.stage))
        rig.addForeign(area: rig.viewInAnotherWindow())
        let baseline = try XCTUnwrap(SRPixels(rep: try rig.capture(rig.cv).rep))
        let cap = try rig.capture(rig.cv)
        pane.body.poison = .nan

        let normal = try attempt(rig, cap, allowsSynthetic: true).get()
        let decoded = try XCTUnwrap(SRPixels(png: normal))
        XCTAssertEqual(decoded.mismatches(against: baseline, excluding: [], tolerance: 2), 0, "unchanged capture")

        let zeroRect = try attempt(rig, cap.with(rect: NSRect(origin: .zero, size: .zero)), allowsSynthetic: true).get()
        XCTAssertNotNil(NSBitmapImageRep(data: zeroRect), "a QA-build screenshot ignores the capture rect")
    }

    // MARK: Never write the unredacted image

    func test_pngData_returns_the_bytes_and_creates_no_file_in_every_outcome() throws {
        // The server writes only the `Data` `pngData` returns, after it returns (see the source-policy
        // test below), so the unredacted image reaches disk only if `pngData` itself writes. Best effort:
        // nothing may appear in the temporary directory across the call (real app, QA build, refusal).
        let hiddenRig = makeRig()
        hiddenRig.addPane(column: 0)
        let shownRig = makeRig()
        shownRig.addPane(column: 0)
        let refusedRig = makeRig()
        refusedRig.addPane(column: 0)
        refusedRig.addForeign(area: SRSolidView(frame: .zero, color: SRPalette.stage))   // unresolvable: detached
        let hiddenCapture = try hiddenRig.capture(hiddenRig.cv)
        let shownCapture = try shownRig.capture(shownRig.cv)
        let refusedCapture = try refusedRig.capture(refusedRig.cv)

        var before = tempListing()
        let hidden = try attempt(hiddenRig, hiddenCapture).get()
        XCTAssertGreaterThan(hidden.count, 0)
        XCTAssertEqual(tempListing().subtracting(before), [], "real app: pngData must not write a file")

        before = tempListing()
        let shown = try attempt(shownRig, shownCapture, allowsSynthetic: true).get()
        XCTAssertGreaterThan(shown.count, 0)
        XCTAssertEqual(tempListing().subtracting(before), [], "QA build: pngData must not write a file")

        before = tempListing()
        assertRefused(attempt(refusedRig, refusedCapture), "unresolvable area")
        XCTAssertEqual(tempListing().subtracting(before), [], "refusal: pngData must not write a file")
    }

    func test_server_writes_only_what_redaction_returned_and_cannot_bypass_the_gate() throws {
        // Policy guard: `screenshot` must get its bytes from `ScreenshotRedaction.pngData` (called with the
        // default gate, never an overridden `allowsSynthetic`) and write them only after it returns; no
        // other app-control code encodes pixels.
        let server = try SRSource.read("AppControl/AppControlServer.swift")
        let start = try XCTUnwrap(server.range(of: "func screenshot("), "screenshot func not found")
        let rest = String(server[start.lowerBound...])
        let call = try XCTUnwrap(rest.range(of: "ScreenshotRedaction.pngData("), "screenshot must encode through ScreenshotRedaction.pngData")
        let write = try XCTUnwrap(rest.range(of: ".write(to:"), "screenshot must write the PNG")
        XCTAssertLessThan(call.lowerBound, write.lowerBound, "the PNG is written only after redaction returned it")
        XCTAssertFalse(rest[..<write.lowerBound].contains("representation(using:"),
                       "screenshot must not encode the capture itself before redaction")
        let callText = String(rest[call.lowerBound...].prefix(while: { $0 != ")" }))
        XCTAssertFalse(callText.contains("allowsSynthetic"), "the server must not override the gate: \(callText)")

        let dir = SRSource.app.appendingPathComponent("AppControl")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ScreenshotRedaction.swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let encoders = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { $0.contains("representation(using:") || $0.contains("tiffRepresentation") }
            XCTAssertEqual(encoders, [], "\(file.lastPathComponent) encodes pixels outside ScreenshotRedaction")
        }
    }

    func test_the_real_terminal_views_register_as_terminal_pixel_sources() throws {
        // The stand-ins above cannot prove the real classes opt in, so pin it in source.
        for (file, type) in [("UI/Terminal/TerminalPaneHostView.swift", "TerminalPaneHostView"),
                             ("UI/Terminal/NostromoTerminalView.swift", "NostromoTerminalView")] {
            let text = try SRSource.read(file)
            let pattern = "class \(type)\\b[^{]*TerminalPixelSource"
            XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(type) must conform to TerminalPixelSource")
        }
    }

    // MARK: Canary must bite

    func test_an_unregistered_view_painting_the_canary_is_left_alone_and_the_detector_sees_it() throws {
        // The control: the same canary pixels in a view that does NOT conform to `TerminalPixelSource`
        // are untouched by redaction (gate off). This proves the "no canary" assertions above can see
        // canary pixels, and that redaction paints only registered terminals, not everything.
        let rig = makeRig()
        let plain = SRTerminalSurface(frame: NSRect(x: 10, y: 10, width: 200, height: 120))
        rig.stage.addSubview(plain)
        let baseCap = try rig.capture(rig.cv)
        let baseline = try XCTUnwrap(SRPixels(rep: baseCap.rep))
        let region = baseCap.pixelRect(of: plain.convert(plain.bounds, to: nil))
        XCTAssertEqual(baseline.loudBounds(in: baseline.fullRect), region, "harness: the detector must find the canary view exactly")

        let cap = try rig.capture(rig.cv)
        let data = try ScreenshotRedaction.pngData(of: cap.rep, window: rig.window, captureRect: cap.rect, allowsSynthetic: false)
        let output = try XCTUnwrap(SRPixels(png: data))
        XCTAssertGreaterThan(output.loudCount(in: region), 0, "an unregistered view's pixels are not redacted")
        XCTAssertEqual(output.mismatches(against: baseline, excluding: [], tolerance: 2), 0, "with no terminals the capture is unchanged")
        XCTAssertEqual(output.fillCount(in: output.fullRect), 0)
    }
}
