import AppKit

/// A view that draws a terminal's pixels (or sits over them). `AppControlServer`'s `screenshot` paints
/// over every one of these in the real app: a terminal is read only through `nostromo_read_terminal_screen`
/// (needs a follow, redacts daemon-side), never by a picture of the window.
///
/// Conformers are `TerminalPaneHostView` (the pane) and `NostromoTerminalView` (the SwiftTerm view). Both
/// are SwiftTerm-linked and cannot be built in the test bundle, so the tests use stand-ins.
protocol TerminalPixelSource: NSView {
    /// The view whose whole frame is hidden: it must contain every pixel the terminal can show, including
    /// whatever is scrolled or clipped inside it and whatever is laid over it (the connecting message, the
    /// ended overlay). For a plain terminal view that is the view itself.
    var terminalPixelArea: NSView { get }
}

extension TerminalPixelSource {
    var terminalPixelArea: NSView { self }
}

/// Why a screenshot was refused instead of risking a terminal's pixels.
struct ScreenshotRedactionError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// Hides terminal panes in an app-control screenshot.
///
/// Policy: in the real app (`SyntheticInputGate.allowsSynthetic` false) every terminal's area is painted
/// over with a solid block labelled `label` BEFORE the PNG is encoded, so the unredacted capture exists
/// only in memory. In the QA build the screenshot is unchanged. If any terminal's area cannot be placed
/// in the capture, the screenshot is refused (`ScreenshotRedactionError`) rather than leaked.
enum ScreenshotRedaction {

    static let label = "terminal hidden from app-control"

    /// The block's colour: opaque, so nothing shows through.
    static let fillColor = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)

    /// PNG bytes of `rep`, a capture of `window` whose image covers `captureRect` (window base
    /// coordinates, origin bottom-left: the whole window frame for a window-server capture, the content
    /// view for `cacheDisplay`). Terminal areas are redacted unless `allowsSynthetic`.
    static func pngData(of rep: NSBitmapImageRep, window: NSWindow, captureRect: NSRect,
                        allowsSynthetic: Bool = SyntheticInputGate.allowsSynthetic) throws -> Data {
        let image: NSBitmapImageRep
        if allowsSynthetic {
            image = rep
        } else {
            image = try redacted(rep, areas: try terminalAreas(in: window), captureRect: captureRect)
        }
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw ScreenshotRedactionError(description: "png encode failed")
        }
        return png
    }

    /// Every terminal's area in `window`, in window base coordinates. Hidden panes count (nothing is
    /// assumed about what is on screen). Throws when an area can't be placed: not in this window, or a
    /// frame that is not a finite rectangle.
    static func terminalAreas(in window: NSWindow) throws -> [NSRect] {
        guard let content = window.contentView else {
            throw ScreenshotRedactionError(description: "window has no content view")
        }
        var areas: [NSRect] = []
        func walk(_ view: NSView) throws {
            if let source = view as? TerminalPixelSource {
                areas.append(try area(of: source.terminalPixelArea, in: window))
                return   // everything below it is covered by its area
            }
            for sub in view.subviews { try walk(sub) }
        }
        try walk(content)
        return areas
    }

    // MARK: - Private

    private static func area(of view: NSView, in window: NSWindow) throws -> NSRect {
        guard view.window === window else {
            throw ScreenshotRedactionError(description: "a terminal's area is not in this window, so it can't be hidden")
        }
        let rect = view.convert(view.bounds, to: nil)
        guard isFinite(rect) else {
            throw ScreenshotRedactionError(description: "a terminal's area has no usable frame, so it can't be hidden")
        }
        return rect.standardized
    }

    private static func isFinite(_ r: NSRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.size.width.isFinite && r.size.height.isFinite
    }

    /// A copy of `rep` with `areas` (window base coordinates) painted over. The source is only read.
    private static func redacted(_ rep: NSBitmapImageRep, areas: [NSRect], captureRect: NSRect) throws -> NSBitmapImageRep {
        let pixelsWide = rep.pixelsWide, pixelsHigh = rep.pixelsHigh
        guard isFinite(captureRect), captureRect.width > 0, captureRect.height > 0, pixelsWide > 0, pixelsHigh > 0 else {
            throw ScreenshotRedactionError(description: "the capture's size is unknown, so terminals can't be hidden")
        }
        let scale = CGFloat(pixelsWide) / captureRect.width
        // The image is the capture rounded to whole pixels: more than a couple of pixels off vertically
        // (the scale came from the width) means it is not this rect.
        guard abs(CGFloat(pixelsHigh) - captureRect.height * scale) <= 2 else {
            throw ScreenshotRedactionError(description: "the capture does not match its window, so terminals can't be hidden")
        }
        guard let source = rep.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotRedactionError(description: "the capture can't be copied, so terminals can't be hidden")
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))

        let fill = fillColor.usingColorSpace(.sRGB) ?? fillColor
        for area in areas {
            // Window coordinates run up from the bottom; the image runs down from the top. Round outward.
            // Clamped as numbers first: an area far outside the image must not overflow `Int`.
            func pixel(_ value: CGFloat, upTo limit: Int, _ rule: FloatingPointRoundingRule) -> Int {
                Int(min(max(value.rounded(rule), 0), CGFloat(limit)))
            }
            let left = pixel((area.minX - captureRect.minX) * scale, upTo: pixelsWide, .down)
            let right = pixel((area.maxX - captureRect.minX) * scale, upTo: pixelsWide, .up)
            let top = pixel((captureRect.maxY - area.maxY) * scale, upTo: pixelsHigh, .down)
            let bottom = pixel((captureRect.maxY - area.minY) * scale, upTo: pixelsHigh, .up)
            guard right > left, bottom > top else { continue }
            let block = CGRect(x: left, y: pixelsHigh - bottom, width: right - left, height: bottom - top)
            context.setBlendMode(.copy)
            context.setShouldAntialias(false)
            context.setFillColor(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent, alpha: 1)
            context.fill(block)
            drawLabel(in: block, scale: scale, context: context)
        }
        guard let image = context.makeImage() else {
            throw ScreenshotRedactionError(description: "the redacted capture can't be made")
        }
        return NSBitmapImageRep(cgImage: image)
    }

    /// The label, centred, when it fits; a block too small for it stays plain.
    private static func drawLabel(in block: CGRect, scale: CGFloat, context: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.72, green: 0.72, blue: 0.76, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        let inset = 4 * scale
        guard block.height >= size.height + 2 * inset, block.width >= 40 * scale else { return }
        let line = CGRect(x: block.minX + inset, y: block.midY - size.height / 2,
                          width: block.width - 2 * inset, height: size.height)
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(in: line, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
