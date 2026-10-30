import AppKit
import NostromoKit

// The plan, rendered inside the Mother job detail (R12, R13).
//
// Read-only. The text on screen comes from `PlanMarkdown` (sanitised, no image URLs); the file comes
// from `PlanFileLoader` (a regular markdown file of at most 1 MiB, SR7). Nothing here touches the
// network, runs anything, or changes anything: opening, revealing and copying are view actions, the
// way "View Plan" was.
//
// Layout is done by hand, on purpose: a document of unknown width and height, with wide tables and
// code blocks inside it, is the case where Auto Layout lets one child set the pane's width. Every row
// is given the width of the scroll view's clip, and wide rows scroll sideways inside themselves.

// MARK: - Actions (injectable)

/// What the plan view can ask the outside world to do. The live ones are the real thing; tests record.
struct PlanViewActions {
    /// Open the plan in the default app (the host's `openPlan`).
    var openPlan: (String) -> Void = { _ in }
    /// Open an `http`/`https` link in the default browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Show a file in Finder. Never opens it.
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Copy plain text to the pasteboard.
    var copy: (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }
}

// MARK: - Link policy

enum PlanLinkAction: Equatable {
    case open(URL)
    case reveal(URL)
    /// Shown as text, never a link.
    case none
}

enum PlanLinkPolicy {

    /// `http` and `https` open in the browser; `file:` URLs for this machine (no host, or `localhost`) and
    /// relative or absolute paths are revealed in Finder (never opened); every other scheme, a `file:` URL
    /// for another host, and in-page `#` anchors, are inert.
    static func action(for target: String, planDirectory: URL?) -> PlanLinkAction {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("#") else { return .none }

        if let colon = target.firstIndex(of: ":"), isScheme(target[..<colon]) {
            switch target[..<colon].lowercased() {
            case "http", "https":
                guard let url = URL(string: target), url.host?.isEmpty == false else { return .none }
                return .open(url)
            case "file":
                guard let url = URL(string: target), url.isFileURL, isThisMachine(url.host) else { return .none }
                return .reveal(url.standardizedFileURL)
            default:
                return .none
            }
        }

        // A path: drop a query or fragment, undo percent-encoding, resolve against the plan's folder.
        var path = target
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return .none }
        if path.hasPrefix("/") { return .reveal(URL(fileURLWithPath: path).standardizedFileURL) }
        guard let planDirectory else { return .none }
        return .reveal(URL(fileURLWithPath: path, relativeTo: planDirectory).standardizedFileURL)
    }

    /// A `file://host/path` link names a file on `host`; only this machine's own names are ours to reveal.
    private static func isThisMachine(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.lowercased() == "localhost"
    }

    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }
}

// MARK: - Display limits

/// What one plan may cost the main thread. Row heights are worked out for every row at every width and
/// the rows are scanned on every scroll tick, so a 1 MiB file of one-line paragraphs (hundreds of
/// thousands of rows) or of one code block (a million characters in one text layout) would stall the
/// app. Past a limit the plan stops and a "plan truncated for display" row says so; the whole file is
/// still one click away (Open, Finder, Copy path), and the Overview checklist is not affected.
enum PlanDisplayLimits {
    /// Rows of the document, a list item, a heading, a paragraph, a code block, a table or a rule each being one.
    static let maxRows = 2_500
    /// Characters of text over all rows.
    static let maxCharacters = 200_000
    /// Characters in one row.
    static let maxCharactersPerRow = 60_000
    /// Lines of one code block, or rows of one table.
    static let maxLinesPerScrollRow = 1_500
    /// Bytes of markdown handed to the parser. Foundation's parser grows faster than the input on tables
    /// (100,000 rows took 7 s to parse on a quiet Mac, 20 s on a CI runner), so the parse is bounded by
    /// this, not by the 1 MiB file cap; the rest of the file is the "truncated for display" row's.
    static let maxParsedBytes = 262_144

    /// `text` cut to `maxParsedBytes` at a line break (so no character is split) when that keeps at least half
    /// of it (a file of one enormous line is cut mid-line instead), and whether it was cut.
    static func parsedPrefix(of text: String) -> (text: String, wasCut: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxParsedBytes else { return (text, false) }
        let end = utf8.index(utf8.startIndex, offsetBy: maxParsedBytes)
        var prefix = text[..<end]
        if let lineBreak = prefix.unicodeScalars.lastIndex(of: "\n"),
           utf8.distance(from: utf8.startIndex, to: lineBreak) >= maxParsedBytes / 2 {
            prefix = prefix[..<lineBreak]
        }
        return (String(prefix), true)
    }
}

// MARK: - Styles

private enum PlanStyle {
    static let bodySize: CGFloat = 13
    static let codeSize: CGFloat = 12
    static let linkColor = NSColor(red: 0.45, green: 0.65, blue: 1, alpha: 1)
    static let codeBackground = NSColor(white: 0.12, alpha: 1)

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 13.5
        }
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func paragraph(lineSpacing: CGFloat = 2) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

/// `PlanSpan`s as attributed text. Links get a `.link` only when the policy allows them.
private struct PlanSpanRenderer {
    let planDirectory: URL?
    var baseSize: CGFloat = PlanStyle.bodySize
    var bold = false
    var color: NSColor = Theme.fg

    private struct Traits {
        var bold: Bool
        var italic = false
        var strike = false
        var code = false
        var link: URL?
    }

    func render(_ spans: [PlanSpan]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        append(spans, traits: Traits(bold: bold), to: out)
        return out
    }

    private func append(_ spans: [PlanSpan], traits: Traits, to out: NSMutableAttributedString) {
        for span in spans {
            var t = traits
            switch span {
            case .text(let s):
                out.append(run(s, t))
            case .code(let s):
                t.code = true
                out.append(run(s, t))
            case .emph(let inner):
                t.italic = true
                append(inner, traits: t, to: out)
            case .strong(let inner):
                t.bold = true
                append(inner, traits: t, to: out)
            case .strike(let inner):
                t.strike = true
                append(inner, traits: t, to: out)
            case .link(let inner, url: let target):
                switch PlanLinkPolicy.action(for: target, planDirectory: planDirectory) {
                case .open(let url), .reveal(let url): t.link = url
                case .none: break
                }
                append(inner, traits: t, to: out)
            case .image(alt: let alt):
                // Never fetched: the alt text stands in for it.
                var muted = t
                muted.italic = true
                let text = NSMutableAttributedString(attributedString: run("[image: \(alt)]", muted))
                text.addAttribute(.foregroundColor, value: Theme.fgMuted, range: NSRange(location: 0, length: text.length))
                out.append(text)
            }
        }
    }

    private func run(_ text: String, _ t: Traits) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if t.code {
            attrs[.font] = Theme.firaCode(size: baseSize - 1, weight: t.bold ? .semibold : .regular)
            attrs[.backgroundColor] = PlanStyle.codeBackground
        } else {
            attrs[.font] = PlanStyle.font(size: baseSize, bold: t.bold, italic: t.italic)
        }
        if t.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = t.link { attrs[.link] = link }
        return NSAttributedString(string: text, attributes: attrs)
    }
}

// MARK: - Text views

/// A read-only, selectable text view that is sized by hand (TextKit 1, so layout can be measured).
private final class PlanTextView: NSTextView {

    convenience init() {
        self.init(usingTextLayoutManager: false)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        linkTextAttributes = [.foregroundColor: PlanStyle.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
    }

    /// Wrap at `width`, or never when nil. Layout happens when the view draws.
    func wrap(at width: CGFloat?) {
        textContainer?.size = NSSize(width: width ?? 1_000_000, height: 1_000_000)
    }

    /// A vertical wheel or trackpad gesture scrolls the page, not the text.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// How tall text is, without a text view: what a row's height is worked out from for every row of a
/// document, while views exist only for the rows near the viewport.
///
/// Short text is measured with `boundingRect`. A long text (a code block or a table of hundreds of lines)
/// is measured by a layout manager instead: `boundingRect` grows faster than its input there (a
/// 1,500-line table took 2 s on a CI runner with plain cells and 16 s with real ones, on the main
/// thread, twice), while the layout manager the row's own text view uses lays the same text out in
/// hundredths of a second. Main thread only (it keeps one text system and reuses it).
private enum PlanTextMetrics {
    /// Characters from which a text goes to the layout manager.
    static let layoutManagerThreshold = 4_000

    static func height(of text: NSAttributedString, wrappingAt width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let size = NSSize(width: max(1, width), height: 1_000_000)
        let height = text.length > layoutManagerThreshold
            ? usedRect(of: text, in: size).height
            : text.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return ceil(height) + 1
    }

    static func width(of text: NSAttributedString) -> CGFloat {
        let size = NSSize(width: 1_000_000, height: 1_000_000)
        let width = text.length > layoutManagerThreshold
            ? usedRect(of: text, in: size).width
            : text.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        return ceil(width) + 1
    }

    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 1, height: 1_000_000))
        container.lineFragmentPadding = 0   // as the plan's text views have it
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return container
    }()

    private static func usedRect(of text: NSAttributedString, in size: NSSize) -> NSRect {
        storage.setAttributedString(text)
        container.size = size
        guard let manager = container.layoutManager else { return .zero }
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        storage.setAttributedString(NSAttributedString())   // do not hold a megabyte between calls
        return rect
    }
}

/// A scroll view that only scrolls sideways. Vertical gestures go on to the page behind it.
final class PlanHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Rows

/// One piece of the document on screen, stacked top to bottom by `PlanFlowView`. Its frame is its spec's.
private class PlanRowView: NSView {
    override var isFlipped: Bool { true }
    /// Every text view the row owns, in reading order.
    var textViews: [NSTextView] { [] }
}

/// Text with an optional marker (a bullet, a number or a checkbox) at its left.
private class PlanTextRow: PlanRowView {
    static let markerWidth: CGFloat = 22

    let textView = PlanTextView()
    private(set) var marker: NSView?
    private let leading: CGFloat
    private let quoteDepth: Int

    init(attributed: NSAttributedString, marker: NSView?, leading: CGFloat, quoteDepth: Int) {
        self.marker = marker
        self.leading = leading
        self.quoteDepth = quoteDepth
        super.init(frame: .zero)
        textView.textStorage?.setAttributedString(attributed)
        addSubview(textView)
        if let marker { addSubview(marker) }
    }
    required init?(coder: NSCoder) { fatalError("PlanTextRow is built in code") }

    override var textViews: [NSTextView] { [textView] }

    private var textX: CGFloat { leading + (marker == nil ? 0 : Self.markerWidth) }

    override func layout() {
        super.layout()
        let width = max(20, bounds.width - textX)
        textView.wrap(at: width)
        textView.frame = NSRect(x: textX, y: 0, width: width, height: bounds.height)
        if let marker {
            marker.frame.origin = NSPoint(x: leading, y: max(0, (18 - marker.frame.height) / 2))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard quoteDepth > 0 else { return }
        Theme.borderInactive.setFill()
        for d in 0..<quoteDepth {
            NSRect(x: CGFloat(d) * 14 + 2, y: 0, width: 3, height: bounds.height).fill()
        }
    }
}

private final class PlanHeadingRow: PlanTextRow {
    init(level: Int, title: String, attributed: NSAttributedString) {
        super.init(attributed: attributed, marker: nil, leading: 0, quoteDepth: 0)
        // VoiceOver moves between headings by role, and reads the level.
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        setAccessibilityLabel(title)
        setAccessibilityValue(level)
        setAccessibilityRoleDescription("heading level \(level)")
    }
    required init?(coder: NSCoder) { fatalError("PlanHeadingRow is built in code") }
}

/// A code block or a table: text that does not wrap, in its own sideways scroll view.
private final class PlanScrollRow: PlanRowView {
    enum Kind { case code, table }

    static let inset: CGFloat = 8
    static let labelHeight: CGFloat = 16
    static var scrollerHeight: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle) }

    let kind: Kind
    let scrollView = PlanHorizontalScrollView()
    let textView = PlanTextView()
    private let languageLabel: NSTextField?
    private let leading: CGFloat
    /// The width the document view has to be to show all of the text.
    private let contentWidth: CGFloat

    init(kind: Kind, attributed: NSAttributedString, language: String?, leading: CGFloat) {
        self.kind = kind
        self.leading = leading
        contentWidth = PlanTextMetrics.width(of: attributed) + 2 * Self.inset
        if let language, !language.isEmpty {
            let label = NSTextField(labelWithString: language)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.fgMuted
            label.lineBreakMode = .byTruncatingTail
            languageLabel = label
        } else {
            languageLabel = nil
        }
        super.init(frame: .zero)
        textView.textStorage?.setAttributedString(attributed)
        textView.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        textView.wrap(at: nil)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = PlanStyle.codeBackground
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 4
        scrollView.documentView = textView
        if let languageLabel { addSubview(languageLabel) }
        addSubview(scrollView)
        // The row itself is the element (a group a screen reader can name); its text view stays inside it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let name = kind == .code ? "Code block" : "Table"
        setAccessibilityLabel(language.map { $0.isEmpty ? name : "\(name), \($0)" } ?? name)
    }
    required init?(coder: NSCoder) { fatalError("PlanScrollRow is built in code") }

    override var textViews: [NSTextView] { [textView] }

    override func layout() {
        super.layout()
        let label = languageLabel == nil ? 0 : Self.labelHeight
        languageLabel?.frame = NSRect(x: leading, y: 0, width: max(0, bounds.width - leading), height: Self.labelHeight)
        scrollView.frame = NSRect(x: leading, y: label, width: max(0, bounds.width - leading), height: max(0, bounds.height - label))
        // At least as wide as the clip (so the background fills it), as wide as the text when that is more.
        let textHeight = max(0, scrollView.frame.height - Self.scrollerHeight)
        textView.frame = NSRect(x: 0, y: 0, width: max(contentWidth, scrollView.contentSize.width), height: textHeight)
    }
}

private final class PlanRuleRow: PlanRowView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.borderInactive.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The last row of a plan that was cut short for display: what happened, and a way to the whole file.
private final class PlanNoticeRow: PlanRowView {
    static let text = "Plan truncated for display. It is too large to show in full here; "
        + "open it in your editor for the rest."
    static let buttonHeight: CGFloat = 24
    static let padding: CGFloat = 8

    let label = NSTextField(wrappingLabelWithString: PlanNoticeRow.text)
    let copyButton = NSButton(title: "Copy path", target: nil, action: nil)
    private let copyPath: () -> Void

    static func height(wrappingAt width: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: Self.text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return PlanTextMetrics.height(of: text, wrappingAt: width) + buttonHeight + 3 * padding
    }

    init(copyPath: @escaping () -> Void) {
        self.copyPath = copyPath
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.fgMuted
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.setAccessibilityLabel("Copy plan path")
        addSubview(label)
        addSubview(copyButton)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("PlanNoticeRow is built in code") }

    override func layout() {
        super.layout()
        let textHeight = PlanTextMetrics.height(of: NSAttributedString(string: Self.text, attributes: [.font: NSFont.systemFont(ofSize: 12)]),
                                                wrappingAt: bounds.width)
        label.frame = NSRect(x: 0, y: Self.padding, width: bounds.width, height: textHeight)
        copyButton.frame = NSRect(x: 0, y: label.frame.maxY + Self.padding, width: 80, height: Self.buttonHeight)
    }

    @objc private func copyTapped() { copyPath() }
}

// MARK: - Specs and the flow

/// A row of the document that may or may not have a view right now. Its height is known (worked out
/// from the text) whether or not it has one; the view is built when it is near the viewport.
private final class PlanRowSpec {
    enum Kind {
        case text
        case heading(level: Int, title: String)
        case code
        case table
        case rule
        /// "Plan truncated for display" (always the last row).
        case notice
    }

    let kind: Kind
    let blockIndex: Int
    var spaceBefore: CGFloat
    /// What find searches: the text of the row's one text view.
    let searchText: String
    /// Height at a row width.
    let height: (CGFloat) -> CGFloat
    let make: () -> PlanRowView
    var frame = NSRect.zero
    var view: PlanRowView?

    init(kind: Kind, blockIndex: Int, spaceBefore: CGFloat, searchText: String,
         height: @escaping (CGFloat) -> CGFloat, make: @escaping () -> PlanRowView) {
        self.kind = kind
        self.blockIndex = blockIndex
        self.spaceBefore = spaceBefore
        self.searchText = searchText
        self.height = height
        self.make = make
    }

    var headingTitle: String? {
        if case .heading(_, let title) = kind { return title }
        return nil
    }
}

/// The scroll document: its rows, one under another, each as wide as the document. Only rows near the
/// viewport (and every heading, so VoiceOver can move between them) have views.
private final class PlanFlowView: NSView {
    override var isFlipped: Bool { true }
    private(set) var specs: [PlanRowSpec] = []
    private(set) var laidOutWidth: CGFloat = -1
    /// Left and right margin around every row.
    static let margin: CGFloat = 2
    /// Builds nothing more than this many headings' views up front; past it headings are windowed like the rest.
    private static let alwaysBuiltHeadingLimit = 300
    /// A row got its view.
    var onRowBuilt: ((PlanRowView) -> Void)?

    private var headingCount = 0

    func setSpecs(_ newSpecs: [PlanRowSpec]) {
        specs.forEach { $0.view?.removeFromSuperview(); $0.view = nil }
        specs = newSpecs
        headingCount = newSpecs.reduce(0) { $0 + ($1.headingTitle == nil ? 0 : 1) }
        laidOutWidth = -1
    }

    var builtRows: [PlanRowView] { specs.compactMap(\.view) }

    /// Stack the rows for a document `width` wide; the view's own frame becomes that wide and as tall as the rows.
    func relayout(width: CGFloat, visible: NSRect) {
        let rowWidth = max(20, width - 2 * Self.margin)
        var y: CGFloat = 4
        for (i, spec) in specs.enumerated() {
            if i > 0 { y += spec.spaceBefore }
            let h = spec.height(rowWidth)
            spec.frame = NSRect(x: Self.margin, y: y, width: rowWidth, height: h)
            if let view = spec.view, view.frame != spec.frame { view.frame = spec.frame; view.needsLayout = true }
            y += h
        }
        laidOutWidth = width
        setFrameSize(NSSize(width: width, height: y + 24))
        updateWindow(visible: visible)
    }

    /// Give a view to every row within a screen or two of `visible`, and take it from rows far from it.
    func updateWindow(visible: NSRect) {
        let margin = max(1_500, visible.height * 2)
        let near = visible.insetBy(dx: -10_000, dy: -margin)
        let far = near.insetBy(dx: 0, dy: -margin)
        let headingsAlwaysBuilt = headingCount <= Self.alwaysBuiltHeadingLimit
        for spec in specs {
            let isHeading = spec.headingTitle != nil
            if spec.view == nil {
                guard spec.frame.intersects(near) || (isHeading && headingsAlwaysBuilt) else { continue }
                build(spec)
            } else if !(isHeading && headingsAlwaysBuilt), !spec.frame.intersects(far) {
                spec.view?.removeFromSuperview()
                spec.view = nil
            }
        }
    }

    /// Make sure `spec` has its view now.
    @discardableResult
    func build(_ spec: PlanRowSpec) -> PlanRowView {
        if let view = spec.view { return view }
        let view = spec.make()
        view.frame = spec.frame
        addSubview(view)
        spec.view = view
        onRowBuilt?(view)
        view.layoutSubtreeIfNeeded()
        return view
    }
}

// MARK: - Header

/// The one-row header, laid out by hand. Two rows when one would not fit, buttons shrinking (their
/// titles truncate) before the file name does. It never has a width of its own to demand.
private final class PlanHeaderView: NSView {
    let nameLabel = PlanNameLabel(labelWithString: "")
    let criteriaLabel = NSTextField(labelWithString: "")
    let outlineButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let openButton = NSButton(title: "Open ↗", target: nil, action: nil)
    let finderButton = NSButton(title: "Finder", target: nil, action: nil)
    let copyButton = NSButton(title: "⧉", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width)) }

    private static let rowHeight: CGFloat = 24
    private static let gap: CGFloat = 6
    private static let minimumButtonWidth: CGFloat = 26
    private static let minimumNameWidth: CGFloat = 80
    /// One row from this width up.
    private static let singleRowWidth: CGFloat = 540

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Theme.fg
        nameLabel.lineBreakMode = .byTruncatingMiddle
        criteriaLabel.font = .systemFont(ofSize: 11)
        criteriaLabel.textColor = Theme.fgMuted
        criteriaLabel.lineBreakMode = .byTruncatingTail
        outlineButton.font = .systemFont(ofSize: 11)
        outlineButton.controlSize = .small
        for button in [openButton, finderButton, copyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.lineBreakMode = .byTruncatingTail
        }
        copyButton.toolTip = "Copy the plan's path"
        copyButton.setAccessibilityLabel("Copy path")
        openButton.toolTip = "Open the plan in its default app"
        openButton.setAccessibilityLabel("Open plan in its default app")
        finderButton.toolTip = "Show the plan in Finder"
        finderButton.setAccessibilityLabel("Show plan in Finder")
        outlineButton.setAccessibilityLabel("Outline")
        [nameLabel, criteriaLabel, outlineButton, openButton, finderButton, copyButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("PlanHeaderView is built in code") }

    private var controls: [NSView] { [outlineButton, openButton, finderButton, copyButton].filter { !$0.isHidden } }

    private func natural(_ view: NSView) -> CGFloat {
        if let button = view as? NSButton { return ceil(button.fittingSize.width) }
        return ceil(view.fittingSize.width)
    }

    func height(for width: CGFloat) -> CGFloat {
        width >= Self.singleRowWidth || controls.isEmpty && criteriaLabel.isHidden
            ? Self.rowHeight : 2 * Self.rowHeight + 4
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let controls = self.controls
        let criteriaWidth = criteriaLabel.isHidden ? 0 : min(natural(criteriaLabel), 130)
        let singleRow = height(for: width) == Self.rowHeight

        func place(_ views: [NSView], in rect: NSRect, trailing: Bool) {
            let naturals = views.map(natural)
            let total = naturals.reduce(0, +) + Self.gap * CGFloat(max(0, views.count - 1))
            let squeeze = total > rect.width ? max(0, rect.width - Self.gap * CGFloat(max(0, views.count - 1))) / max(1, naturals.reduce(0, +)) : 1
            let widths = naturals.map { max(Self.minimumButtonWidth, floor($0 * squeeze)) }
            var x = trailing ? max(rect.minX, rect.maxX - (widths.reduce(0, +) + Self.gap * CGFloat(max(0, views.count - 1)))) : rect.minX
            for (view, w) in zip(views, widths) {
                view.frame = NSRect(x: x, y: rect.minY + 1, width: w, height: Self.rowHeight - 2)
                x += w + Self.gap
            }
        }

        if singleRow {
            let controlsWidth = controls.map(natural).reduce(0, +) + Self.gap * CGFloat(controls.count)
            let fixed = criteriaWidth + (criteriaWidth > 0 ? Self.gap : 0) + controlsWidth
            let nameWidth = max(Self.minimumNameWidth, width - fixed)
            nameLabel.frame = NSRect(x: 0, y: 3, width: min(nameWidth, width), height: Self.rowHeight - 6)
            var x = nameLabel.frame.maxX + Self.gap
            if criteriaWidth > 0 {
                criteriaLabel.frame = NSRect(x: x, y: 3, width: criteriaWidth, height: Self.rowHeight - 6)
                x = criteriaLabel.frame.maxX + Self.gap
            }
            place(controls, in: NSRect(x: x, y: 0, width: max(0, width - x), height: Self.rowHeight), trailing: true)
        } else {
            let nameWidth = max(40, width - criteriaWidth - (criteriaWidth > 0 ? Self.gap : 0))
            nameLabel.frame = NSRect(x: 0, y: 3, width: nameWidth, height: Self.rowHeight - 6)
            if criteriaWidth > 0 {
                criteriaLabel.frame = NSRect(x: nameLabel.frame.maxX + Self.gap, y: 3, width: criteriaWidth, height: Self.rowHeight - 6)
            }
            place(controls, in: NSRect(x: 0, y: Self.rowHeight + 4, width: width, height: Self.rowHeight), trailing: false)
        }
    }
}

/// The file name: truncates, and never asks for the width of the whole name.
private final class PlanNameLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = NSView.noIntrinsicMetric
        return size
    }
}

// MARK: - PlanDocumentView

final class PlanDocumentView: NSView {

    enum State: Equatable {
        /// No plan path.
        case empty
        /// Reading or parsing.
        case loading
        case document
        /// The file was read and has nothing to show (no bytes, only white space, or no blocks at all).
        case emptyPlan
        /// The file could not be shown: `.notFound`, `.notReadable`, `.notMarkdown`, `.tooLarge` or `.notUTF8`.
        case unreadable(PlanFileResult)
    }

    private(set) var state: State = .empty
    private(set) var planPath: String?
    /// Whether the view is the one on screen: only then does it read and watch the file.
    private(set) var isActive = false
    var actions: PlanViewActions

    private let loader: PlanFileLoader
    private let parseQueue: DispatchQueue
    private let header = PlanHeaderView()
    private let findField = NSSearchField()
    private let scrollView = NSScrollView()
    private let flow = PlanFlowView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let messageCopyButton = NSButton(title: "Copy path", target: nil, action: nil)
    private let messageOpenButton = NSButton(title: "Open ↗", target: nil, action: nil)
    private let messageRevealButton = NSButton(title: "Show in Finder", target: nil, action: nil)

    /// The text the shown document was built from: a reload that reads the same text changes nothing.
    private var shownText: String?
    private var document = PlanDocument()
    private var planDirectory: URL?
    private var checklistCounts = (done: 0, total: 0)
    /// The plan was longer than `PlanDisplayLimits` allow and ends in a "truncated for display" row.
    private(set) var isTruncatedForDisplay = false
    /// Characters of text over all rows of the document (at most `PlanDisplayLimits.maxCharacters`).
    private(set) var displayedCharacterCount = 0
    private var needsLoadOnActivate = false
    private var findCursor: (index: Int, end: Int)?
    private(set) var findVisible = false
    /// Parsing (off the main thread) that has not been applied yet.
    private var parseGeneration = 0

    init(frame: NSRect = .zero,
         loader: PlanFileLoader = PlanFileLoader(),
         parseQueue: DispatchQueue = .global(qos: .utility),
         actions: PlanViewActions = PlanViewActions()) {
        self.loader = loader
        self.parseQueue = parseQueue
        self.actions = actions
        super.init(frame: frame)
        build()
        loader.onResult = { [weak self] result in self?.loaderDidDeliver(result) }
        render()
    }
    required init?(coder: NSCoder) { fatalError("PlanDocumentView is built in code") }

    override var isFlipped: Bool { true }

    /// A plan view never asks for a width of its own.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// The plan view that holds `responder` (or whose find field is being edited), if any.
    static func containing(_ responder: NSResponder?) -> PlanDocumentView? {
        var view = responder as? NSView
        while let current = view {
            if let plan = current as? PlanDocumentView { return plan }
            view = current.superview
        }
        return nil
    }

    // MARK: Showing a plan

    /// Show the plan at `path` (nil or empty: none). Reads it now if the view is active, else when it becomes so.
    func show(planPath path: String?) {
        let newPath = (path?.isEmpty ?? true) ? nil : path
        guard newPath != planPath else { return }
        planPath = newPath
        planDirectory = newPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent, isDirectory: true) }
        resetDocument()
        guard newPath != nil else {
            loader.load(path: nil)
            state = .empty
            render()
            return
        }
        state = .loading
        render()
        if isActive { loader.load(path: newPath) } else { needsLoadOnActivate = true }
    }

    /// The view is on screen (true) or hidden behind another segment (false). Hidden, it holds no watcher.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            guard planPath != nil else { return }
            if needsLoadOnActivate {
                needsLoadOnActivate = false
                loader.load(path: planPath)
            } else {
                loader.reload()
            }
        } else {
            loader.stop()
        }
    }

    /// Stop everything and forget the plan (the job changed or the detail was cleared).
    func clear() {
        parseGeneration += 1
        needsLoadOnActivate = false
        planPath = nil
        planDirectory = nil
        loader.load(path: nil)
        resetDocument()
        state = .empty
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Off screen for good, or until the detail is shown again.
            parseGeneration += 1
            loader.stop()
            if planPath != nil, isActive { needsLoadOnActivate = true }
        } else if isActive, needsLoadOnActivate {
            needsLoadOnActivate = false
            loader.load(path: planPath)
        }
    }

    // MARK: Tests and the detail read these

    /// `✓ n/m criteria`, or nil when the plan has no task items (the label is hidden then).
    var criteriaText: String? { header.criteriaLabel.isHidden ? nil : header.criteriaLabel.stringValue }
    var fileNameText: String { header.nameLabel.stringValue }
    /// The words of whatever message the pane shows instead of a document (nil while it shows one).
    var shownMessage: String? { state.showsMessage && !messageLabel.isHidden ? messageLabel.stringValue : nil }
    var messageRevealButtonView: NSButton { messageRevealButton }
    var outlineButton: NSPopUpButton { header.outlineButton }
    var openButton: NSButton { header.openButton }
    var finderButton: NSButton { header.finderButton }
    var copyPathButton: NSButton { header.copyButton }
    var findSearchField: NSSearchField { findField }
    var unreadableMessage: String? { state.isUnreadable ? messageLabel.stringValue : nil }
    var messageCopyPathButton: NSButton { messageCopyButton }
    var messageOpenPlanButton: NSButton { messageOpenButton }
    var documentScrollView: NSScrollView { scrollView }
    var documentContentView: NSView { flow }
    /// The clip's current top, for tests and anchors.
    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Every heading, top to bottom: its level, title and its frame in the document's coordinates.
    var headings: [(level: Int, title: String, frame: NSRect, blockIndex: Int)] {
        flow.specs.compactMap { spec in
            guard case .heading(let level, let title) = spec.kind else { return nil }
            return (level, title, spec.frame, spec.blockIndex)
        }
    }
    /// The views a screen reader sees as headings (every heading has one, up to 300 of them).
    var headingViews: [NSView] { flow.specs.filter { $0.headingTitle != nil }.compactMap(\.view) }

    // Only the rows near the viewport have views (see `PlanFlowView`): these are those, in reading order.
    var checkboxes: [NSButton] { flow.builtRows.compactMap { ($0 as? PlanTextRow)?.marker as? NSButton } }
    var codeScrollViews: [NSScrollView] { scrollRows(.code).map(\.scrollView) }
    var tableScrollViews: [NSScrollView] { scrollRows(.table).map(\.scrollView) }
    /// The text views of the rows that have views, in reading order.
    var textViews: [NSTextView] { flow.builtRows.flatMap(\.textViews) }
    /// A file watcher is armed (the view is active and has a plan).
    var isWatchingFile: Bool { loader.isWatching }
    /// How many rows the document has, built or not.
    var rowCount: Int { flow.specs.count }

    /// Give every row its view now (tests, and anything that has to see the whole document).
    func buildAllRows() {
        flow.specs.forEach { flow.build($0) }
    }
    /// Everything the document shows as text, joined (for tests that look for text that must not be there).
    var shownPlainText: String { textViews.map(\.string).joined(separator: "\n") }

    // MARK: Header actions

    @objc private func openExternally() {
        guard let planPath else { return }
        actions.openPlan(planPath)
    }

    @objc private func revealInFinder() {
        guard let planPath else { return }
        actions.reveal(URL(fileURLWithPath: planPath))
    }

    @objc private func copyThePath() {
        guard let planPath else { return }
        actions.copy(planPath)
    }

    @objc private func outlineChosen(_ sender: NSMenuItem) {
        guard let blockIndex = sender.representedObject as? Int else { return }
        scrollToHeading(blockIndex: blockIndex)
    }

    /// Scroll so the heading of block `blockIndex` is at the top of the viewport.
    func scrollToHeading(blockIndex: Int) {
        guard let spec = flow.specs.first(where: { $0.blockIndex == blockIndex && $0.headingTitle != nil }) else { return }
        scroll(toY: spec.frame.minY)
    }

    // MARK: Links

    /// A click on a link. The policy decides what, if anything, happens; the text view is told it was handled.
    @discardableResult
    func handleLink(_ link: Any) -> Bool {
        let target: String?
        if let url = link as? URL { target = url.absoluteString } else { target = link as? String }
        guard let target else { return true }
        switch PlanLinkPolicy.action(for: target, planDirectory: planDirectory) {
        case .open(let url): actions.openURL(url)
        case .reveal(let url): actions.reveal(url)
        case .none: break
        }
        return true
    }

    // MARK: Find

    /// ⌘F and ⌘G, forwarded by the app delegate: Find… opens the field, Find Next finds the next match.
    func performFind(_ sender: Any?) {
        let action = (sender as? NSMenuItem).flatMap { NSTextFinder.Action(rawValue: $0.tag) } ?? .showFindInterface
        switch action {
        case .nextMatch:
            if findField.stringValue.isEmpty { showFind() } else { findNext() }
        default:
            showFind()
        }
    }

    func showFind() {
        findVisible = true
        findField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(findField)
    }

    func closeFind() {
        guard findVisible else { return }
        findVisible = false
        findField.isHidden = true
        findField.stringValue = ""
        findCursor = nil
        textViews.forEach { $0.setSelectedRange(NSRange(location: 0, length: 0)) }
        needsLayout = true
        // The keyboard goes back to the text, not nowhere.
        if let first = textViews.first { window?.makeFirstResponder(first) }
    }

    /// Select the next match of the find field's text (case-insensitive) after the last one, across every
    /// row of the document (built or not), wrapping at the end, and bring it into view.
    @discardableResult
    func findNext() -> Bool {
        let query = findField.stringValue
        let specs = flow.specs
        guard !query.isEmpty, !specs.isEmpty else { return false }
        let startIndex = min(findCursor?.index ?? 0, specs.count - 1)
        let startLocation = findCursor?.end ?? 0
        for step in 0...specs.count {
            let index = (startIndex + step) % specs.count
            let text = specs[index].searchText as NSString
            let from = step == 0 ? min(startLocation, text.length) : 0
            let to = step == specs.count ? min(startLocation, text.length) : text.length
            guard to > from else { continue }
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: from, length: to - from))
            guard range.location != NSNotFound else { continue }
            select(range, inRowAt: index)
            return true
        }
        NSSound.beep()
        return false
    }

    private func select(_ range: NSRange, inRowAt index: Int) {
        let spec = flow.specs[index]
        if let previous = findCursor?.index, previous != index, previous < flow.specs.count {
            (flow.specs[previous].view?.textViews.first)?.setSelectedRange(NSRange(location: 0, length: 0))
        }
        findCursor = (index, range.location + range.length)
        // Bring the row into view first: that is also what gives it a view to select in.
        let visible = scrollView.documentVisibleRect
        if spec.frame.minY < visible.minY || spec.frame.maxY > visible.maxY {
            scroll(toY: spec.frame.midY - visible.height / 2)
        }
        let row = flow.build(spec)
        guard let view = row.textViews.first else { return }
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        if let manager = view.layoutManager, let container = view.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            let inFlow = flow.convert(rect, from: view)
            let now = scrollView.documentVisibleRect
            if inFlow.minY < now.minY || inFlow.maxY > now.maxY {
                scroll(toY: inFlow.midY - now.height / 2)
            }
        }
        view.showFindIndicator(for: range)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        let headerShown = !header.isHidden
        if headerShown {
            let h = header.height(for: width)
            header.frame = NSRect(x: 0, y: 0, width: width, height: h)
            y = h + 4
        }
        if findVisible {
            findField.frame = NSRect(x: 0, y: y, width: width, height: 24)
            y += 28
        }
        let rest = NSRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        if state.showsMessage {
            let textWidth = max(40, width)
            let textHeight = ceil(messageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 20)
            messageLabel.frame = NSRect(x: 0, y: rest.minY + 8, width: textWidth, height: textHeight)
            var buttonX: CGFloat = 0
            for button in [messageCopyButton, messageRevealButton, messageOpenButton] where !button.isHidden {
                let w = min(max(ceil(button.fittingSize.width), 60), max(60, width - buttonX))
                button.frame = NSRect(x: buttonX, y: messageLabel.frame.maxY + 8, width: w, height: 24)
                buttonX += w + 8
            }
        }
        scrollView.frame = rest
        let clipWidth = scrollView.contentSize.width
        if flow.laidOutWidth != clipWidth || flow.frame.width != clipWidth {
            relayoutFlow(width: clipWidth)
        }
    }

    // MARK: Private: building

    private func build() {
        setAccessibilityElement(false)

        header.openButton.target = self
        header.openButton.action = #selector(openExternally)
        header.finderButton.target = self
        header.finderButton.action = #selector(revealInFinder)
        header.copyButton.target = self
        header.copyButton.action = #selector(copyThePath)
        addSubview(header)

        findField.placeholderString = "Find in plan"
        findField.sendsSearchStringImmediately = false
        findField.target = self
        findField.action = #selector(findFieldEntered)
        findField.delegate = self
        findField.isHidden = true
        findField.setAccessibilityLabel("Find in plan")
        addSubview(findField)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = flow
        scrollView.setAccessibilityLabel("Plan")
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        flow.onRowBuilt = { [weak self] row in row.textViews.forEach { $0.delegate = self } }

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Theme.fg
        messageLabel.isSelectable = true
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
        addSubview(messageLabel)
        for button in [messageCopyButton, messageRevealButton, messageOpenButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.isHidden = true
            addSubview(button)
        }
        messageCopyButton.target = self
        messageCopyButton.action = #selector(copyThePath)
        messageOpenButton.target = self
        messageOpenButton.action = #selector(openExternally)
        messageRevealButton.target = self
        messageRevealButton.action = #selector(revealInFinder)
        messageCopyButton.setAccessibilityLabel("Copy plan path")
        messageOpenButton.setAccessibilityLabel("Open plan in its default app")
        messageRevealButton.setAccessibilityLabel("Show plan in Finder")
    }

    /// Show what `state` says: the header and document, or one calm message with its buttons.
    private func render() {
        let showsDocument = state == .document
        header.isHidden = state == .empty
        // A file name is as untrusted as the file: no bidi override or zero-width character in it.
        header.nameLabel.stringValue = planPath.map { FoldTextSanitizer.sanitize(($0 as NSString).lastPathComponent) } ?? ""
        header.criteriaLabel.isHidden = !showsDocument || checklistCounts.total == 0
        if !header.criteriaLabel.isHidden {
            header.criteriaLabel.stringValue = "✓ \(checklistCounts.done)/\(checklistCounts.total) criteria"
            header.criteriaLabel.setAccessibilityLabel("\(checklistCounts.done) of \(checklistCounts.total) criteria done")
        }
        header.outlineButton.isHidden = !showsDocument || document.outline.isEmpty
        header.openButton.isHidden = !showsDocument
        header.finderButton.isHidden = !showsDocument
        header.copyButton.isHidden = !showsDocument
        scrollView.isHidden = !showsDocument
        if !showsDocument, findVisible { closeFind() }

        switch state {
        case .empty, .document:
            messageLabel.isHidden = true
            messageCopyButton.isHidden = true
            messageRevealButton.isHidden = true
            messageOpenButton.isHidden = true
        case .loading:
            messageLabel.stringValue = "Loading the plan…"
            messageLabel.textColor = Theme.fgMuted
            messageLabel.isHidden = false
            messageCopyButton.isHidden = true
            messageRevealButton.isHidden = true
            messageOpenButton.isHidden = true
        case .emptyPlan:
            messageLabel.stringValue = "Empty plan. The file has nothing in it to show."
            messageLabel.textColor = Theme.fgMuted
            messageLabel.isHidden = false
            messageCopyButton.isHidden = false
            messageRevealButton.isHidden = true
            messageOpenButton.isHidden = true
        case .unreadable(let result):
            messageLabel.stringValue = Self.message(for: result)
            messageLabel.textColor = Theme.fg
            messageLabel.isHidden = false
            messageCopyButton.isHidden = false
            // A file that is not markdown is never handed to the system to open: show it in Finder instead.
            messageRevealButton.isHidden = result != .notMarkdown
            messageOpenButton.isHidden = result != .tooLarge
        }
        rebuildOutlineMenu()
        needsLayout = true
    }

    private static func message(for result: PlanFileResult) -> String {
        switch result {
        case .notFound:
            return "Plan file not found. Mother may have archived or cleaned up this job's copy. "
                + "The job keeps running from its own copy if it is still running."
        case .notReadable:
            return "Can't read this file (permissions)."
        case .notMarkdown:
            return "This plan isn't a markdown file, so it isn't shown or opened from here. "
                + "Show it in Finder or copy its path."
        case .tooLarge:
            return "This plan can't be shown here. Open it in your editor."
        case .notUTF8:
            return "This plan isn't UTF-8 text."
        case .loaded:
            return ""
        }
    }

    private func rebuildOutlineMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Outline", action: nil, keyEquivalent: "")   // a pull-down's own title
        // Only headings that have a row: a plan cut short for display lists what it shows.
        let shown = Set(flow.specs.lazy.filter { $0.headingTitle != nil }.map(\.blockIndex))
        for entry in document.outline where shown.contains(entry.blockIndex) {
            let indent = String(repeating: "  ", count: max(0, entry.level - 1))
            let title = indent + (entry.title.count > 60 ? String(entry.title.prefix(59)) + "…" : entry.title)
            let item = NSMenuItem(title: title, action: #selector(outlineChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.blockIndex
            menu.addItem(item)
        }
        header.outlineButton.menu = menu
    }

    // MARK: Private: loading

    private func loaderDidDeliver(_ result: PlanFileResult) {
        switch result {
        case .loaded(let text, _, _):
            guard text != shownText || !state.showsFile else {
                return   // the same text again (a touch, a save with no change): nothing to rebuild
            }
            parseGeneration += 1
            let generation = parseGeneration
            let loaderGeneration = loader.generation
            parseQueue.async { [weak self] in
                // The parse is bounded; the checklist (cheap, one pass) counts the whole file.
                let shown = PlanDisplayLimits.parsedPrefix(of: text)
                let parsed = PlanMarkdown.parse(shown.text)
                let checklist = PlanChecklist.parse(text)
                DispatchQueue.main.async {
                    guard let self, self.parseGeneration == generation, self.loader.generation == loaderGeneration else { return }
                    self.apply(text: text, document: parsed, checklist: checklist, cutInput: shown.wasCut)
                }
            }
        default:
            // The same answer again (the loader keeps asking for a file that is not there): nothing changes.
            guard state != .unreadable(result) else { return }
            parseGeneration += 1
            resetDocument()
            state = .unreadable(result)
            render()
        }
    }

    private func apply(text: String, document newDocument: PlanDocument, checklist: [PlanChecklistItem], cutInput: Bool) {
        let anchor = state == .document ? captureAnchor() : nil
        let hadDocument = state == .document
        shownText = text
        document = newDocument
        checklistCounts = (checklist.filter(\.done).count, checklist.count)
        findCursor = nil
        var builder = PlanSpecBuilder(renderer: PlanSpanRenderer(planDirectory: planDirectory))
        builder.add(newDocument.blocks, leading: 0, quoteDepth: 0)
        if cutInput { builder.noteInputWasCut() }
        builder.finish(copyPath: { [weak self] in self?.copyThePath() })
        flow.setSpecs(builder.specs)
        isTruncatedForDisplay = builder.isTruncated
        displayedCharacterCount = builder.characters
        state = builder.specs.isEmpty ? .emptyPlan : .document
        render()
        layoutSubtreeIfNeeded()
        relayoutFlow(width: scrollView.contentSize.width)
        if hadDocument, state == .document { restore(anchor) } else { scroll(toY: 0) }
    }

    private func resetDocument() {
        shownText = nil
        document = PlanDocument()
        checklistCounts = (0, 0)
        isTruncatedForDisplay = false
        displayedCharacterCount = 0
        findCursor = nil
        flow.setSpecs([])
        flow.setFrameSize(NSSize(width: flow.frame.width, height: 0))
    }

    // MARK: Private: reading position

    private struct HeadingKey: Equatable {
        let title: String
        let occurrence: Int
    }

    /// The topmost heading in view (or, with none in view, the last one above it) and how far its top is from
    /// the viewport's top; with the headings before it, to fall back on if it is gone after a reload.
    private struct Anchor {
        let key: HeadingKey
        let offset: CGFloat
        let earlier: [HeadingKey]
        let absoluteOffset: CGFloat
    }

    private var headingSpecs: [PlanRowSpec] { flow.specs.filter { $0.headingTitle != nil } }
    private func scrollRows(_ kind: PlanScrollRow.Kind) -> [PlanScrollRow] {
        flow.builtRows.compactMap { ($0 as? PlanScrollRow).flatMap { $0.kind == kind ? $0 : nil } }
    }

    private func keys(of headings: [PlanRowSpec]) -> [HeadingKey] {
        var seen: [String: Int] = [:]
        return headings.map { heading in
            let title = heading.headingTitle ?? ""
            let n = seen[title, default: 0]
            seen[title] = n + 1
            return HeadingKey(title: title, occurrence: n)
        }
    }

    private func captureAnchor() -> Anchor? {
        let clip = scrollView.contentView.bounds
        let headings = headingSpecs
        guard !headings.isEmpty else { return nil }
        let keys = keys(of: headings)
        let index = headings.firstIndex { $0.frame.maxY > clip.minY && $0.frame.minY < clip.maxY }
            ?? headings.lastIndex { $0.frame.minY <= clip.minY }
            ?? 0
        return Anchor(key: keys[index], offset: headings[index].frame.minY - clip.minY,
                      earlier: Array(keys[..<index].reversed()), absoluteOffset: clip.minY)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor else { scroll(toY: scrollOffset); return }
        let headings = headingSpecs
        let keys = keys(of: headings)
        if let index = keys.firstIndex(of: anchor.key) {
            scroll(toY: headings[index].frame.minY - anchor.offset)
        } else if let earlier = anchor.earlier.lazy.compactMap({ key in keys.firstIndex(of: key) }).first {
            // The heading is gone: the nearest one before it, at the top.
            scroll(toY: headings[earlier].frame.minY)
        } else {
            scroll(toY: anchor.absoluteOffset)
        }
    }

    /// Scroll the clip's top to `y`, inside the document.
    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, flow.frame.height - clip.bounds.height)
        let target = min(max(0, y), maxY)
        guard clip.bounds.origin != NSPoint(x: 0, y: target) else { return }
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func relayoutFlow(width: CGFloat) {
        guard width > 0 else { return }
        flow.relayout(width: width, visible: scrollView.documentVisibleRect)
    }

    /// The reader scrolled: build the rows that came near, drop the ones that left.
    @objc private func clipBoundsChanged(_ note: Notification) {
        flow.updateWindow(visible: scrollView.documentVisibleRect)
    }

    @objc private func findFieldEntered() { findNext() }
}

// MARK: - Delegates

extension PlanDocumentView: NSSearchFieldDelegate, NSTextViewDelegate {

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeFind()
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        handleLink(link)
    }
}

private extension PlanDocumentView.State {
    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
    /// The pane shows one calm message instead of a document.
    var showsMessage: Bool {
        switch self {
        case .loading, .emptyPlan, .unreadable: return true
        case .empty, .document: return false
        }
    }
    /// A file was read and is what the pane is about (a document, or the fact that it is empty).
    var showsFile: Bool { self == .document || self == .emptyPlan }
}

// MARK: - Building rows from blocks

/// The document's blocks as row specs: what each row says and how tall it is, with its view made later.
///
/// It stops at `PlanDisplayLimits`: past the row or character budget nothing more is added, and
/// `finish` puts a "plan truncated for display" row at the end. The work is bounded by the limits, not
/// by the file.
private struct PlanSpecBuilder {
    let renderer: PlanSpanRenderer
    private(set) var specs: [PlanRowSpec] = []
    /// Something was left out.
    private(set) var isTruncated = false
    /// Characters of text over the rows so far.
    private(set) var characters = 0

    init(renderer: PlanSpanRenderer) {
        self.renderer = renderer
    }

    private var isFull: Bool {
        specs.count >= PlanDisplayLimits.maxRows || characters >= PlanDisplayLimits.maxCharacters
    }

    mutating func add(_ blocks: [PlanBlock], leading: CGFloat, quoteDepth: Int) {
        for block in blocks {
            if isFull { isTruncated = true; return }
            add(block, leading: leading, quoteDepth: quoteDepth)
        }
    }

    /// The file had more than was parsed.
    mutating func noteInputWasCut() { isTruncated = true }

    /// The last row, when something was left out.
    mutating func finish(copyPath: @escaping () -> Void) {
        guard isTruncated else { return }
        specs.append(PlanRowSpec(kind: .notice, blockIndex: -1, spaceBefore: 16, searchText: "",
                                 height: { PlanNoticeRow.height(wrappingAt: $0) },
                                 make: { PlanNoticeRow(copyPath: copyPath) }))
    }

    private mutating func append(_ spec: PlanRowSpec) {
        if specs.isEmpty { spec.spaceBefore = 0 }
        characters += spec.searchText.utf16.count
        specs.append(spec)
    }

    /// `text`, cut (with an ellipsis) to what one row and the rest of the budget allow.
    private mutating func fit(_ text: NSAttributedString) -> NSAttributedString {
        let room = max(0, PlanDisplayLimits.maxCharacters - characters)
        let limit = min(PlanDisplayLimits.maxCharactersPerRow, room)
        guard text.length > limit else { return text }
        isTruncated = true
        // The ellipsis counts: the row is `limit` characters, not one more.
        let kept = max(0, limit - 1)
        let cut = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: kept)))
        cut.append(NSAttributedString(string: "…"))
        return cut
    }

    /// The first `maxLinesPerScrollRow` lines of `text`.
    private mutating func firstLines(of text: String) -> String {
        var lines = 0
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                lines += 1
                if lines == PlanDisplayLimits.maxLinesPerScrollRow {
                    isTruncated = true
                    return String(text[..<i])
                }
            }
            i = utf8.index(after: i)
        }
        return text
    }

    private let quoteStep: CGFloat = 14

    private mutating func add(_ block: PlanBlock, leading: CGFloat, quoteDepth: Int) {
        let indent = leading + CGFloat(quoteDepth) * quoteStep
        switch block.kind {
        case .heading(level: let level, spans: let spans):
            var r = renderer
            r.baseSize = PlanStyle.headingSize(level)
            r.bold = true
            let rendered = r.render(spans)
            let text = fit(rendered)
            let title = text.length == rendered.length ? spans.plainText : text.string
            append(PlanRowSpec(kind: .heading(level: level, title: title), blockIndex: block.index,
                               spaceBefore: level == 1 ? 22 : 16, searchText: text.string,
                               height: { PlanTextMetrics.height(of: text, wrappingAt: $0) },
                               make: { PlanHeadingRow(level: level, title: title, attributed: text) }))

        case .paragraph(let spans):
            let text = NSMutableAttributedString(attributedString: fit(renderer.render(spans)))
            applyParagraphStyle(to: text)
            append(textSpec(text, block: block, marker: nil, leading: indent, quoteDepth: quoteDepth, spaceBefore: 8))

        case .list(ordered: let ordered, start: let start, items: let items):
            for (i, item) in items.enumerated() {
                if isFull { isTruncated = true; return }
                addListItem(item, number: ordered ? start + i : nil, parent: block, leading: indent, quoteDepth: quoteDepth)
            }

        case .codeBlock(lang: let lang, text: let code):
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            let attributed = fit(NSAttributedString(string: firstLines(of: code), attributes: [
                .font: Theme.firaCode(size: PlanStyle.codeSize), .foregroundColor: Theme.fg, .paragraphStyle: style,
            ]))
            append(scrollSpec(.code, attributed, language: lang, block: block, leading: indent))

        case .table(header: let header, rows: let tableRows):
            // Rows are cut first (so a million cells are never measured), then the whole table to a row's size
            // (a header cell can be as long as the file).
            append(scrollSpec(.table, fit(tableText(header: header, rows: limited(tableRows))), language: nil, block: block, leading: indent))

        case .quote(let inner):
            add(inner, leading: leading, quoteDepth: quoteDepth + 1)

        case .rule:
            append(PlanRowSpec(kind: .rule, blockIndex: block.index, spaceBefore: 14, searchText: "",
                               height: { _ in 1 }, make: { PlanRuleRow() }))
        }
    }

    /// The rows of a table that fit one row's limits (lines and characters).
    private mutating func limited(_ rows: [[[PlanSpan]]]) -> [[[PlanSpan]]] {
        var kept: [[[PlanSpan]]] = []
        var characters = 0
        for row in rows {
            let size = row.reduce(0) { $0 + $1.plainText.utf16.count }
            if kept.count >= PlanDisplayLimits.maxLinesPerScrollRow || characters + size > PlanDisplayLimits.maxCharactersPerRow {
                isTruncated = true
                break
            }
            characters += size
            kept.append(row)
        }
        return kept
    }

    private func textSpec(_ text: NSAttributedString, block: PlanBlock, marker: (() -> NSView)?, leading: CGFloat,
                          quoteDepth: Int, spaceBefore: CGFloat) -> PlanRowSpec {
        let textX = leading + (marker == nil ? 0 : PlanTextRow.markerWidth)
        return PlanRowSpec(kind: .text, blockIndex: block.index, spaceBefore: spaceBefore, searchText: text.string,
                           height: { max(PlanTextMetrics.height(of: text, wrappingAt: max(20, $0 - textX)), marker == nil ? 0 : 18) },
                           make: { PlanTextRow(attributed: text, marker: marker?(), leading: leading, quoteDepth: quoteDepth) })
    }

    private func scrollSpec(_ kind: PlanScrollRow.Kind, _ text: NSAttributedString, language: String?,
                            block: PlanBlock, leading: CGFloat) -> PlanRowSpec {
        let hasLabel = !(language?.isEmpty ?? true)
        let height = PlanTextMetrics.height(of: text, wrappingAt: 1_000_000) + 2 * PlanScrollRow.inset
            + (hasLabel ? PlanScrollRow.labelHeight : 0) + PlanScrollRow.scrollerHeight
        return PlanRowSpec(kind: kind == .code ? .code : .table, blockIndex: block.index, spaceBefore: 10,
                           searchText: text.string, height: { _ in height },
                           make: { PlanScrollRow(kind: kind, attributed: text, language: language, leading: leading) })
    }

    private mutating func addListItem(_ item: PlanListItem, number: Int?, parent: PlanBlock, leading: CGFloat, quoteDepth: Int) {
        var content = item.blocks
        var spans: [PlanSpan] = []
        var anchorBlock = parent
        if let first = content.first, case .paragraph(let paragraphSpans) = first.kind {
            spans = paragraphSpans
            anchorBlock = first
            content.removeFirst()
        }
        let text = NSMutableAttributedString(attributedString: fit(renderer.render(spans)))
        applyParagraphStyle(to: text)
        let label = String(spans.plainText.prefix(500))   // what a screen reader says: a name, not the item's whole text
        let task = item.task
        let makeMarker: () -> NSView = {
            if let done = task {
                let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                box.state = done ? .on : .off
                box.isEnabled = false   // read-only: a plan's boxes are the job's, not ours to tick
                box.controlSize = .small
                box.frame.size = NSSize(width: 18, height: 18)
                box.setAccessibilityRole(.checkBox)
                box.setAccessibilityLabel(label)
                box.setAccessibilityValue(done ? 1 : 0)
                return box
            }
            let bullet = NSTextField(labelWithString: number.map { "\($0)." } ?? "•")
            bullet.font = .systemFont(ofSize: PlanStyle.bodySize)
            bullet.textColor = Theme.fgMuted
            bullet.sizeToFit()
            bullet.setAccessibilityElement(false)
            return bullet
        }
        append(textSpec(text, block: anchorBlock, marker: makeMarker, leading: leading, quoteDepth: quoteDepth, spaceBefore: 4))
        add(content, leading: leading + PlanTextRow.markerWidth, quoteDepth: quoteDepth)
    }

    private func applyParagraphStyle(to text: NSMutableAttributedString) {
        text.addAttribute(.paragraphStyle, value: PlanStyle.paragraph(), range: NSRange(location: 0, length: text.length))
    }

    /// A table as one block of text: cells separated by tabs, with tab stops where the widest cell of each
    /// column ends, so the columns line up, and the whole thing selects and copies as rows.
    private func tableText(header: [[PlanSpan]], rows tableRows: [[[PlanSpan]]]) -> NSAttributedString {
        var headerRenderer = renderer
        headerRenderer.bold = true
        headerRenderer.baseSize = 12
        var bodyRenderer = renderer
        bodyRenderer.baseSize = 12
        let headerCells = header.map { headerRenderer.render($0) }
        let bodyCells = tableRows.map { row in row.map { bodyRenderer.render($0) } }
        let columns = max(headerCells.count, bodyCells.map(\.count).max() ?? 0)
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in [headerCells] + bodyCells {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], ceil(cell.size().width)) }
        }
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for width in widths.dropLast() {
            x += width + 36
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        let style = NSMutableParagraphStyle()
        style.tabStops = stops
        style.defaultTabInterval = 36
        style.lineBreakMode = .byClipping
        style.paragraphSpacing = 3

        let out = NSMutableAttributedString()
        func append(_ cells: [NSAttributedString], separator: String) {
            for (i, cell) in cells.enumerated() {
                out.append(cell)
                if i < cells.count - 1 { out.append(NSAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: 12)])) }
            }
            out.append(NSAttributedString(string: separator, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        if !headerCells.isEmpty { append(headerCells, separator: bodyCells.isEmpty ? "" : "\n") }
        for (i, row) in bodyCells.enumerated() { append(row, separator: i == bodyCells.count - 1 ? "" : "\n") }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
}
