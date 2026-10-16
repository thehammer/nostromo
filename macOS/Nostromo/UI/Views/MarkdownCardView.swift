import AppKit
import NostromoKit

// MARK: - MarkdownRenderer

/// Stateless line-based markdown-to-AttributedString renderer.
/// Handles fenced code blocks (``` and ~~~), headers (H1–H3), bullet lists,
/// numbered lists, blank-line spacing, and inline spans (inline-code, bold,
/// italic). Not a CommonMark implementation.
///
/// The text is split into prose and fenced-code segments first
/// (`MarkdownFences`). Prose keeps the line logic below, with inline spans applied
/// to that segment only. A code block is rendered verbatim: no headings, lists or
/// inline spans, and the fence lines themselves never reach the attributed string.
enum MarkdownRenderer {

    /// `textColor`: every run's text colour, code included (code keeps its block background).
    /// `Theme.fg` is the conversation; a folded message in an activity lane passes
    /// `Theme.foldedProse`. Colour never changes the height, so measuring ignores it.
    static func render(_ markdown: String, baseFont: NSFont, textColor: NSColor = Theme.fg) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Token colours of the code blocks, applied after the tone in `finish`.
        var tokenRuns: [(range: NSRange, kind: SyntaxTokenKind)] = []
        // Attributes of the code block just appended: the "\n" that ends its last
        // line carries them, so the block's box includes that line break.
        var previousCode: [NSAttributedString.Key: Any]?
        var appended = false
        var endsWithEmptyCode = false

        for segment in MarkdownFences.segments(of: markdown) {
            let part: NSAttributedString
            let code: [NSAttributedString.Key: Any]?
            switch segment {
            case .prose(let text):
                part = renderProse(text, baseFont: baseFont)
                code = nil
                // Blank-only prose (e.g. between two blocks) adds nothing.
                if part.length == 0 { continue }
            case .code(let block):
                let attrs = codeAttributes()
                part = NSAttributedString(string: block.code, attributes: attrs)
                code = attrs
            }
            // Newline between segments (not after the last)
            if appended {
                result.append(NSAttributedString(string: "\n", attributes: previousCode))
            }
            let start = result.length
            result.append(part)
            if case .code(let block) = segment {
                for token in SyntaxHighlighter.tokens(in: block.code, language: block.language) {
                    tokenRuns.append((NSRange(location: start + token.utf16Range.lowerBound,
                                              length: token.utf16Range.count), token.kind))
                }
            }
            previousCode = code
            appended = true
            endsWithEmptyCode = code != nil && part.length == 0
        }

        // An empty code block at the very end still shows as one empty line. A
        // newline would do it but also adds a trailing extra line fragment outside
        // the block, so a single space stands in for the line.
        if endsWithEmptyCode {
            result.append(NSAttributedString(string: " ", attributes: previousCode))
        }
        finish(result, textColor: textColor, tokenRuns: tokenRuns)
        return result
    }

    // MARK: - Private helpers

    /// The one place text colour is decided, for both tones. Tone first (a folded
    /// message repaints every run, code included), then token colours on top so the
    /// tone doesn't erase them; in a folded message the tokens are dimmed.
    private static func finish(_ result: NSMutableAttributedString, textColor: NSColor,
                               tokenRuns: [(range: NSRange, kind: SyntaxTokenKind)]) {
        let dimmed = textColor != Theme.fg
        if dimmed {
            result.addAttribute(.foregroundColor, value: textColor,
                                range: NSRange(location: 0, length: result.length))
        }
        for run in tokenRuns {
            result.addAttribute(.foregroundColor, value: Theme.syntaxColor(run.kind, dimmed: dimmed),
                                range: run.range)
        }
    }

    /// One code block: every line shares one `NSTextBlock`, which is what draws the
    /// lines as a single box. Each block gets its own instance, or adjacent blocks
    /// would merge.
    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        let block = NSTextBlock()
        block.backgroundColor = Theme.codeBlockBackground
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)

        let style = NSMutableParagraphStyle()
        style.textBlocks       = [block]
        style.paragraphSpacing = 0
        return [
            .font: Theme.codeFont(size: 12),
            .foregroundColor: Theme.fg,
            // `!=`, `->`, `=>` render verbatim (as in `ToolCallView`); `codeFont` also
            // turns off Fira Code's `calt` arrows, which `.ligature` doesn't control.
            .ligature: 0,
            .paragraphStyle: style,
        ]
    }

    private static func renderProse(_ markdown: String, baseFont: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let lines  = markdown.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line → paragraph spacing on previous paragraph rather than empty line
            if trimmed.isEmpty {
                if result.length > 0 {
                    let range = NSRange(location: result.length - 1, length: 1)
                    let style = paragraphStyle(spacing: 8, headIndent: 0, firstLineIndent: 0)
                    result.addAttribute(.paragraphStyle, value: style, range: range)
                }
                i += 1
                continue
            }

            let attrLine: NSAttributedString

            if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                attrLine = attributedLine(
                    text,
                    font: .systemFont(ofSize: 14, weight: .semibold),
                    paragraphSpacing: 2
                )
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                attrLine = attributedLine(
                    text,
                    font: .systemFont(ofSize: 16, weight: .semibold),
                    paragraphSpacing: 4
                )
            } else if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                attrLine = attributedLine(
                    text,
                    font: .systemFont(ofSize: 20, weight: .semibold),
                    paragraphSpacing: 6
                )
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = "•  " + String(trimmed.dropFirst(2))
                attrLine = attributedLine(
                    text,
                    font: baseFont,
                    paragraphSpacing: 2,
                    headIndent: 14,
                    firstLineIndent: 0
                )
            } else if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let text = String(trimmed)
                _ = m
                attrLine = attributedLine(
                    text,
                    font: baseFont,
                    paragraphSpacing: 2,
                    headIndent: 14,
                    firstLineIndent: 0
                )
            } else {
                attrLine = attributedLine(trimmed, font: baseFont, paragraphSpacing: 0)
            }

            // Append newline between lines (not after the last)
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(attrLine)
            i += 1
        }

        // Apply inline span pass after all of this segment's lines are assembled
        applyInlineSpans(to: result, baseFont: baseFont)

        return result
    }

    private static func attributedLine(
        _ text: String,
        font: NSFont,
        paragraphSpacing: CGFloat,
        headIndent: CGFloat = 0,
        firstLineIndent: CGFloat = 0
    ) -> NSAttributedString {
        let style = paragraphStyle(
            spacing: paragraphSpacing,
            headIndent: headIndent,
            firstLineIndent: firstLineIndent
        )
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Theme.fg,
            .paragraphStyle: style,
        ])
    }

    private static func paragraphStyle(
        spacing: CGFloat,
        headIndent: CGFloat,
        firstLineIndent: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing     = spacing
        style.headIndent           = headIndent
        style.firstLineHeadIndent  = firstLineIndent
        return style
    }

    // MARK: - Inline spans

    private static let inlineCodeRegex = try? NSRegularExpression(pattern: #"`(.+?)`"#)
    private static let boldRegex       = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italicRegex     = try? NSRegularExpression(pattern: #"(?<![*])\*([^*]+?)\*(?![*])|_(.+?)_"#)

    private static func applyInlineSpans(to str: NSMutableAttributedString, baseFont: NSFont) {
        let full = NSRange(location: 0, length: str.length)
        let text = str.string

        // Collect all ranges to process, sorted highest-range-first to keep indices valid.
        struct Span {
            let range: NSRange
            let kind: Kind
            enum Kind { case code, bold, italic }
        }

        var spans: [Span] = []

        if let rx = inlineCodeRegex {
            rx.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m = m else { return }
                spans.append(Span(range: m.range, kind: .code))
            }
        }
        if let rx = boldRegex {
            rx.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m = m else { return }
                // Skip if already covered by a code span
                if !spans.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                    spans.append(Span(range: m.range, kind: .bold))
                }
            }
        }
        if let rx = italicRegex {
            rx.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m = m else { return }
                if !spans.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                    spans.append(Span(range: m.range, kind: .italic))
                }
            }
        }

        // Process highest start index first to preserve range validity
        spans.sort { $0.range.location > $1.range.location }

        for span in spans {
            let nsText = text as NSString
            guard span.range.location + span.range.length <= nsText.length else { continue }

            switch span.kind {
            case .code:
                guard let contentRange = inlineCodeRegex?
                    .firstMatch(in: text, range: span.range)?
                    .range(at: 1) else { continue }
                let inner = nsText.substring(with: contentRange)
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: Theme.codeFont(size: 12),
                    .foregroundColor: Theme.fg,
                    .ligature: 0,
                    .backgroundColor: NSColor.white.withAlphaComponent(0.12),
                ]
                str.replaceCharacters(in: span.range, with: NSAttributedString(string: inner, attributes: codeAttrs))

            case .bold:
                guard let contentRange = boldRegex?
                    .firstMatch(in: text, range: span.range)?
                    .range(at: 1) else { continue }
                let inner = nsText.substring(with: contentRange)
                let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: boldFont,
                    .foregroundColor: Theme.fg,
                ]
                str.replaceCharacters(in: span.range, with: NSAttributedString(string: inner, attributes: attrs))

            case .italic:
                let match = italicRegex?.firstMatch(in: text, range: span.range)
                let contentRange = match?.range(at: 1).location != NSNotFound
                    ? match?.range(at: 1)
                    : match?.range(at: 2)
                guard let contentRange = contentRange, contentRange.location != NSNotFound else { continue }
                let inner = nsText.substring(with: contentRange)
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: italicFont,
                    .foregroundColor: Theme.fg,
                ]
                str.replaceCharacters(in: span.range, with: NSAttributedString(string: inner, attributes: attrs))
            }
        }
    }
}

// MARK: - MarkdownCardView

/// A styled card view that renders markdown content using `MarkdownRenderer`.
/// Appears as a rounded rectangle with `controlBackgroundColor` fill, a 1px
/// `separatorColor` border, and 12pt inner padding on all sides.
///
/// Self-sizes to content through `intrinsicContentSize`, measured off to the
/// side by a single shared text-layout stack.
///
/// ## Why not `layout()`
///
/// This view used to compute its height inside `layout()` and write it into an
/// active height constraint. Mutating a constraint constant *during* a layout
/// pass re-dirties the constraint engine and schedules another pass. Every
/// card's height feeds its turn, which feeds the document view, so each of N
/// cards re-invalidated a system whose variable count was O(N). That is the
/// mechanism behind the incident's `sample`: 100 % CPU sustained for a full
/// five-second window, effectively all of it in `CoreAutoLayout` /
/// `NSISEngine` (`expression_merge`, `NSISLinExpIncrementConstant`) — a solver
/// that never reached a fixed point rather than a transient spike.
///
/// Frame-positioned turn views also need a height that is knowable *before*
/// insertion, which a height discovered during layout cannot provide.
///
/// So: measurement happens in `measuredHeight(markdown:width:)` against one
/// shared `NSTextStorage`/`NSLayoutManager`/`NSTextContainer` (one per app, not
/// one per card), memoised in an `NSCache`. `layout()` now only sizes the text
/// container; it touches no constraint.
final class MarkdownCardView: NSView {

    // TextKit 1 on purpose: the card is measured by an `NSLayoutManager` stack and
    // `NSTextBlock` (code block background) is TextKit 1 only; render and measure
    // must use the same engine.
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let markdown: String
    private let padding: CGFloat = 12
    /// Width the current `intrinsicContentSize` was computed for.
    private var measuredWidth: CGFloat = -1

    /// `textColor`: see `MarkdownRenderer.render`.
    init(markdown: String, textColor: NSColor = Theme.fg) {
        self.markdown = markdown
        super.init(frame: .zero)
        setupLayer()
        setupTextView()
        let baseFont = NSFont.systemFont(ofSize: 13)
        textView.textStorage?.setAttributedString(
            MarkdownRenderer.render(markdown, baseFont: baseFont, textColor: textColor)
        )
    }

    // MARK: - Measurement

    /// One measuring stack for the whole app. Main-thread only.
    private static let measurer: (storage: NSTextStorage,
                                  layout: NSLayoutManager,
                                  container: NSTextContainer) = {
        let storage   = NSTextStorage()
        let layout    = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return (storage, layout, container)
    }()

    private static let heightCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 2_000
        return cache
    }()

    /// Rendered height of `markdown` laid out to `width` points of card width.
    static func measuredHeight(markdown: String, width: CGFloat) -> CGFloat {
        let padding: CGFloat = 12
        let textWidth = max(width - padding * 2, 1)
        // Exact width, not rounded: text wraps differently at 279.2 and 279.7, so a
        // height cached for one must not answer for the other.
        let key = "\(markdown.hashValue)|\(textWidth)" as NSString
        if let cached = heightCache.object(forKey: key) { return CGFloat(cached.doubleValue) }

        let m = measurer
        m.container.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        m.storage.setAttributedString(
            MarkdownRenderer.render(markdown, baseFont: NSFont.systemFont(ofSize: 13)))
        m.layout.ensureLayout(for: m.container)
        let height = m.layout.usedRect(for: m.container).height + padding * 2

        heightCache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }

    /// The width this card will be laid out at, when the caller already knows
    /// it. See `WidthPresettable`.
    ///
    /// Without it the first `intrinsicContentSize` falls back to 400 pt,
    /// `layout()` then notices the real `bounds.width` and invalidates, and the
    /// correct height only arrives on a *second* solve — so every measurement
    /// of every markdown block paid for two. The width was never actually
    /// unknown: it is the block width `ChatTurnView` computes arithmetically
    /// before anything is built.
    var presetWidth: CGFloat? {
        didSet {
            guard presetWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let width = presetWidth ?? (bounds.width > 0 ? bounds.width : 400)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: Self.measuredHeight(markdown: markdown, width: width))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupLayer() {
        wantsLayer = true
        updateLayerColors()
        layer?.cornerRadius = 8
        layer?.borderWidth  = 1
    }

    private func setupTextView() {
        textView.isEditable                 = false
        textView.isSelectable               = true  // copyable
        textView.applyTranscriptSelectionTheme()
        // Always-dark theme: keeps the unemphasised (inactive) selection grey dark too.
        textView.appearance                 = NSAppearance(named: .darkAqua)
        textView.drawsBackground            = false
        textView.isHorizontallyResizable    = false
        // The card sizes the text view by frame (see `layout()`), so the text view
        // must not resize itself to its text as well.
        textView.isVerticallyResizable      = false
        textView.textContainerInset         = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(textView)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let textWidth = max(bounds.width - padding * 2, 1)
        // Fill the card's interior. The text view used to be pinned only at its
        // top and sides and left to find its own height, but an `NSTextView`
        // reports no intrinsic height, so until AppKit happened to resize it
        // it was a zero-height sliver: a mouse-down over the paragraph hit the
        // card instead of the text view and nothing could be selected.
        textView.frame = NSRect(x: padding, y: padding, width: textWidth,
                                height: max(bounds.height - padding * 2, 0))
        // Wrap at the width the card's height was measured at when the two agree
        // to within the re-measure tolerance below. Wrapping at the exact bounds
        // width instead let a half-point difference re-wrap onto one more line
        // than the height allowed for, and the text view (not vertically
        // resizable) clipped it.
        let measuredAt = presetWidth ?? (measuredWidth > 0 ? measuredWidth : bounds.width)
        let wrapWidth = abs(measuredAt - bounds.width) <= 0.5 ? measuredAt : bounds.width
        textView.textContainer?.containerSize = NSSize(
            width: max(wrapWidth - padding * 2, 1),
            height: CGFloat.greatestFiniteMagnitude
        )

        // Height follows width, and width is only known once laid out. Invalidating
        // the *intrinsic* size is the sanctioned way to say so — unlike writing a
        // constraint constant, it converges: the next pass sees an unchanged width
        // and invalidates nothing.
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Window attachment

    /// Forces a fresh layout ensure + redraw the moment this view has a real window.
    ///
    /// `ReplView.measure()` measures a brand-new turn's whole island — including
    /// every `MarkdownCardView` nested inside it — while it is completely
    /// detached: no superview, no window, ever (see that function's own doc
    /// comment). That's deliberate and necessary for the virtualizer, which
    /// needs each turn's exact height *before* it can be positioned. But it
    /// means this card's `textView` computes its glyph layout for the very
    /// first time while windowless, and a card carrying a large, real turn
    /// (the kind big enough to actually notice) has been observed rendering
    /// as an empty box at the right size once finally attached — correct
    /// geometry, nothing painted. `invalidateLayout` + `ensureLayout` here,
    /// at the one moment `window` actually becomes non-nil, forces AppKit to
    /// redo (not just reuse) the glyph generation with a real window/screen
    /// behind it, regardless of the precise reason the windowless pass left
    /// it unpainted.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let storage = textView.textStorage
        else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                        actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)
        textView.needsDisplay = true
        needsDisplay = true
    }

    // MARK: - Appearance

    /// Fixed dark-theme colors, not `NSColor.controlBackgroundColor`/`.separatorColor`.
    ///
    /// This card used to use those system-adaptive colors, which resolve against
    /// the Mac's actual System Settings ▸ Appearance — light or dark — rather
    /// than Nostromo's own always-dark theme (every sibling view in this file's
    /// pane, `ToolResultView`, `ToolCallChipView`, etc., hardcodes a literal
    /// `Theme`/`NSColor(white:...)` value for exactly this reason: these surfaces
    /// are drawn dark by construction. `AppAppearance` now pins `NSApp.appearance`
    /// to Dark Aqua, which is what makes system-drawn labels readable on them, but
    /// the fixed colours stay so a card never depends on that pin). Under a Light
    /// appearance, `.controlBackgroundColor` resolves to near-white with
    /// near-black text — a card that looks blank at a glance sitting incongruously
    /// in Nostromo's otherwise-dark UI. There is no longer an appearance-change
    /// override here because these colors no longer depend on it.
    private func updateLayerColors() {
        layer?.backgroundColor = Theme.bgBar.cgColor
        layer?.borderColor     = Theme.borderInactive.withAlphaComponent(0.6).cgColor
    }
}
