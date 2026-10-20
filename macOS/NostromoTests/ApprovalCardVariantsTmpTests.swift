import XCTest
import AppKit
import NostromoKit

// TEMPORARY diagnostics (to be deleted): which ingredient stops the approval text from being drawn.
final class ApprovalCardVariantsTmpTests: XCTestCase {

    private static let command = "rm -rf /tmp/x/a"

    /// Bright (non-background) pixels at x >= `minX` (px) in `view`'s rendering.
    private func ink(_ view: NSView, minX: Int = 60, background: Double = 18) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var n = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in minX ..< rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = c.usingColorSpace(.sRGB) ?? c
                let l = 255 * (0.2126 * Double(r.redComponent) + 0.7152 * Double(r.greenComponent) + 0.0722 * Double(r.blueComponent))
                if abs(l - background) > 60 { n += 1 }
            }
        }
        return n
    }

    private func makeInput(_ window: NSWindow) throws -> ApprovalInputView {
        let request = try ApprovalTestRequests.bash(Self.command)
        let view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
        view.isWindowShowing = { true }
        view.frame = NSRect(x: 0, y: 0, width: 1514, height: 30)
        window.contentView!.addSubview(view)
        window.contentView!.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func rebuilt(_ view: ApprovalInputView, attrs: [NSAttributedString.Key: Any]) {
        view.textView.textStorage?.setAttributedString(NSAttributedString(string: Self.command, attributes: attrs))
        view.layoutSubtreeIfNeeded()
    }

    func testVariants() throws {
        var results: [String] = []
        let size = NSSize(width: 1514, height: 30)
        let dark = NSAppearance(named: .darkAqua)
        let font = Theme.codeFont(size: 12)
        let plainAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ApprovalPalette.commandText]

        // A: a stock scrollable text view with the same string (can the CI draw text at all?)
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(origin: .zero, size: size)
            let tv = scroll.documentView as! NSTextView
            tv.textStorage?.setAttributedString(NSAttributedString(string: Self.command, attributes: plainAttrs))
            tv.backgroundColor = ApprovalPalette.inputBackground
            w.contentView!.addSubview(scroll)
            w.contentView!.layoutSubtreeIfNeeded()
            results.append("A_stock=\(ink(scroll, minX: 0))")
        }
        // B: as is. B2: as is, input view only, ink right of the gutter.
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            results.append("B_asis=\(ink(v))")
            v.textView.needsDisplay = true
            v.displayIfNeeded()
            results.append("B_afterNeedsDisplay=\(ink(v))")
            results.append("B_textViewOnly=\(ink(v.textView, minX: 0))")
        }
        // C: no ruler
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            v.rulersVisible = false
            v.hasVerticalRuler = false
            v.layoutSubtreeIfNeeded()
            results.append("C_noRuler=\(ink(v))")
        }
        // E: attributes reduced to font + colour
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            rebuilt(v, attrs: plainAttrs)
            results.append("E_fontColourOnly=\(ink(v))")
        }
        // E2: + paragraph style (char wrap, LTR)
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byCharWrapping
            style.baseWritingDirection = .leftToRight
            rebuilt(v, attrs: plainAttrs.merging([.paragraphStyle: style]) { $1 })
            results.append("E2_paragraph=\(ink(v))")
        }
        // E3: + writingDirection override
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            rebuilt(v, attrs: plainAttrs.merging([.writingDirection: [NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.override.rawValue]]) { $1 })
            results.append("E3_writingDirection=\(ink(v))")
        }
        // F: system mono font instead of codeFont
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            rebuilt(v, attrs: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: ApprovalPalette.commandText])
            results.append("F_systemMono=\(ink(v))")
        }
        // G: no dark appearance on the scroll view / window
        do {
            let w = makeRigWindow(self, size: size, appearance: nil)
            let v = try makeInput(w)
            v.appearance = nil
            results.append("G_noAppearance=\(ink(v))")
        }
        // H: text view not selectable / selectable toggled
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            v.textView.isSelectable = false
            v.textView.needsDisplay = true
            results.append("H_notSelectable=\(ink(v))")
        }
        // I: draw the glyphs by hand into the text view's bitmap
        do {
            let w = makeRigWindow(self, size: size, appearance: dark)
            let v = try makeInput(w)
            let lm = v.textView.layoutManager!
            let range = lm.glyphRange(for: v.textView.textContainer!)
            results.append("I_glyphRange=\(range.length) tcOrigin=\(NSStringFromPoint(v.textView.textContainerOrigin)) nsview_isOpaque=\(v.textView.isOpaque) layoutManagerCount=\(v.textView.textStorage?.layoutManagers.count ?? -1) nonContiguous=\(lm.allowsNonContiguousLayout) fontName=\(font.fontName)")
        }
        XCTFail("ATD-VARIANTS " + results.joined(separator: " "))
    }
}
