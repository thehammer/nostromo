import AppKit

// MARK: - MarkdownRenderer

/// Stateless line-based markdown-to-AttributedString renderer.
/// Handles headers (H1–H3), bullet lists, numbered lists, blank-line spacing,
/// and inline spans (inline-code, bold, italic). Not a CommonMark implementation.
enum MarkdownRenderer {

    static func render(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
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

        // Apply inline span pass after all lines are assembled
        applyInlineSpans(to: result, baseFont: baseFont)

        return result
    }

    // MARK: - Private helpers

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
            .foregroundColor: NSColor.labelColor,
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
                let codeFont = Theme.firaCode(size: 12)
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.12),
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
                    .foregroundColor: NSColor.labelColor,
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
                    .foregroundColor: NSColor.labelColor,
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
/// Self-sizes to content via `layout()` — no fixed height needed.
final class MarkdownCardView: NSView {

    private let textView = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private let padding: CGFloat = 12

    init(markdown: String) {
        super.init(frame: .zero)
        setupLayer()
        setupTextView()
        let baseFont = NSFont.systemFont(ofSize: 13)
        textView.textStorage?.setAttributedString(
            MarkdownRenderer.render(markdown, baseFont: baseFont)
        )
        heightConstraint = heightAnchor.constraint(equalToConstant: 60)
        heightConstraint.isActive = true
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
        textView.isSelectable               = false
        textView.drawsBackground            = false
        textView.isHorizontallyResizable    = false
        textView.isVerticallyResizable      = true
        textView.textContainerInset         = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let textWidth = max(bounds.width - padding * 2, 1)
        textView.textContainer?.containerSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let layoutManager = textView.layoutManager,
           let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let usedRect = layoutManager.usedRect(for: container)
            let newHeight = usedRect.height + padding * 2
            if abs(newHeight - heightConstraint.constant) > 0.5 {
                heightConstraint.constant = newHeight
            }
        }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor     = NSColor.separatorColor.cgColor
    }
}
