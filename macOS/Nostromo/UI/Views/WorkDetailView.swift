import AppKit

// The detail half of every Teri tab: one scrolling text view showing a
// `WorkItemDetail` (title, field rows, markdown body, files, links) and a
// button row with "Open in…" (⌘O) and a "Send to agent…" placeholder that the
// send-to-agent slice enables.

/// Somewhere an item can be opened.
enum WorkOpenTarget: Equatable {
    case url(label: String, url: URL)
    /// A file or directory on disk.
    case path(label: String, path: String)

    var label: String {
        switch self {
        case .url(let label, _), .path(let label, _): return label
        }
    }
}

final class WorkDetailView: NSView {
    enum Content: Equatable {
        case none
        /// The list item's title while the daemon's detail is on its way.
        case loading(title: String)
        case failed(title: String, message: String)
        case detail(WorkItemDetail)
    }

    /// Called when the user chooses "Send to agent…" (enabled by a later slice).
    var onSendToAgent: (() -> Void)?
    /// Performs an open. Replaceable so tests never launch anything.
    var opener: (WorkOpenTarget) -> Void = WorkDetailView.openWithWorkspace

    private(set) var content: Content = .none
    private(set) var openTargets: [WorkOpenTarget] = []

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let openButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sendButton = NSButton(title: "Send to agent…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    // MARK: Public

    /// The title being shown (the item's own while loading), nil when nothing is selected.
    var shownTitle: String? {
        switch content {
        case .none: return nil
        case .loading(let title), .failed(let title, _): return title
        case .detail(let detail): return detail.title
        }
    }

    /// Plain text on screen (tests, accessibility).
    var renderedText: String { textView.string }

    /// Whether the "Send to agent…" button can be used.
    var sendToAgentEnabled: Bool {
        get { sendButton.isEnabled }
        set { sendButton.isEnabled = newValue }
    }

    /// Show `content`. `item` supplies the item's own url/path as extra "Open in…" targets.
    func show(_ content: Content, item: WorkItem? = nil) {
        self.content = content
        openTargets = Self.targets(for: content, item: item)
        rebuildOpenMenu()
        textView.textStorage?.setAttributedString(Self.attributedText(for: content))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// ⌘O: open the first target (a link, else a file). False when there is none.
    @discardableResult
    func openPrimary() -> Bool {
        guard let target = openTargets.first else { return false }
        opener(target)
        return true
    }

    /// Move keyboard focus into the detail text (Return on a list row).
    func focusDetail() {
        window?.makeFirstResponder(textView)
    }

    // MARK: Targets

    static func targets(for content: Content, item: WorkItem?) -> [WorkOpenTarget] {
        var targets: [WorkOpenTarget] = []
        func add(_ target: WorkOpenTarget) {
            if !targets.contains(target) { targets.append(target) }
        }
        if case .detail(let detail) = content {
            for link in detail.links {
                if let url = URL(string: link.url), url.scheme != nil { add(.url(label: link.label, url: url)) }
            }
        }
        if let urlString = item?.url, let url = URL(string: urlString), url.scheme != nil {
            add(.url(label: "Open in browser", url: url))
        }
        if let path = item?.path, !path.isEmpty {
            add(.path(label: "Reveal \((path as NSString).lastPathComponent)", path: path))
        }
        if case .detail(let detail) = content {
            for file in detail.files where !file.isEmpty {
                add(.path(label: (file as NSString).lastPathComponent, path: file))
            }
        }
        return targets
    }

    static func openWithWorkspace(_ target: WorkOpenTarget) {
        switch target {
        case .url(_, let url):
            NSWorkspace.shared.open(url)
        case .path(_, let path):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: Rendering

    private static let bodyFont = NSFont.systemFont(ofSize: 13)

    static func attributedText(for content: Content) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ text: String, font: NSFont, color: NSColor = Theme.fg) {
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        switch content {
        case .none:
            line("Select an item to see its details", font: bodyFont, color: Theme.fgMuted)
        case .loading(let title):
            line(title, font: NSFont.systemFont(ofSize: 17, weight: .semibold))
            line("Loading…", font: bodyFont, color: Theme.fgMuted)
        case .failed(let title, let message):
            line(title, font: NSFont.systemFont(ofSize: 17, weight: .semibold))
            line("Couldn't load the details: \(message)", font: bodyFont, color: Theme.amber)
        case .detail(let detail):
            line(detail.title, font: NSFont.systemFont(ofSize: 17, weight: .semibold))
            out.append(NSAttributedString(string: "\n"))
            if !detail.fields.isEmpty {
                let style = NSMutableParagraphStyle()
                style.tabStops = [NSTextTab(textAlignment: .left, location: 110)]
                style.headIndent = 110
                style.paragraphSpacing = 2
                for field in detail.fields {
                    let row = NSMutableAttributedString(string: "\(field.label)\t", attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.fgMuted,
                        .paragraphStyle: style,
                    ])
                    row.append(NSAttributedString(string: field.value + "\n", attributes: [
                        .font: bodyFont, .foregroundColor: Theme.fg, .paragraphStyle: style,
                    ]))
                    out.append(row)
                }
                out.append(NSAttributedString(string: "\n"))
            }
            if !detail.markdown.isEmpty {
                let blocks = WorkMarkdown.blocks(from: detail.markdown)
                out.append(MarkdownBlockDocument(title: "", body: blocks, threads: []).attributedString)
                out.append(NSAttributedString(string: "\n"))
            }
            if !detail.files.isEmpty {
                line("Files", font: NSFont.systemFont(ofSize: 12, weight: .semibold), color: Theme.fgMuted)
                for file in detail.files { line(file, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)) }
                out.append(NSAttributedString(string: "\n"))
            }
            if !detail.links.isEmpty {
                line("Links", font: NSFont.systemFont(ofSize: 12, weight: .semibold), color: Theme.fgMuted)
                for link in detail.links {
                    var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: Theme.cornflower]
                    if let url = URL(string: link.url) { attrs[.link] = url }
                    out.append(NSAttributedString(string: link.label + "\n", attributes: attrs))
                }
            }
        }
        return out
    }

    // MARK: Setup

    private func setUp() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.bg
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: Theme.cornflower, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.setAccessibilityLabel("Item details")

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        openButton.setAccessibilityLabel("Open in…")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.isEnabled = false   // enabled by the send-to-agent slice
        let buttons = NSStackView(views: [openButton, sendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(buttons)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: topAnchor),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(.none)
    }

    private func rebuildOpenMenu() {
        openButton.removeAllItems()
        openButton.addItem(withTitle: "Open in…")   // pull-down title slot
        for (index, target) in openTargets.enumerated() {
            let item = NSMenuItem(title: target.label, action: #selector(openChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            openButton.menu?.addItem(item)
        }
        openButton.isEnabled = !openTargets.isEmpty
    }

    @objc private func openChosen(_ sender: NSMenuItem) {
        guard openTargets.indices.contains(sender.tag) else { return }
        opener(openTargets[sender.tag])
    }

    @objc private func sendPressed() { onSendToAgent?() }
}

// MARK: - Markdown

/// A small block-level markdown reader for `WorkDetail.markdown`, producing the
/// `MdBlock`s `MarkdownBlockDocument` renders: headings, fenced code, bullet and
/// numbered lists, quotes, rules and paragraphs, with `code`, **bold**, *italic*
/// and [link](url) inline. Anything fancier (tables) falls through as text.
enum WorkMarkdown {
    static func blocks(from markdown: String) -> [MdBlock] {
        var blocks: [MdBlock] = []
        var paragraph: [String] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(spans(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(next)
                }
                blocks.append(.codeBlock(lang: lang.isEmpty ? nil : lang, text: code.joined(separator: "\n")))
            } else if line.isEmpty {
                flushParagraph()
            } else if let heading = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, spans: spans(heading.text)))
            } else if ["---", "***", "___"].contains(line) {
                flushParagraph()
                blocks.append(.rule)
            } else if line.hasPrefix(">") {
                flushParagraph()
                var quoted = [String(line.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines.removeFirst().trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                blocks.append(.quote(self.blocks(from: quoted.joined(separator: "\n"))))
            } else if let first = listMarker(line) {
                flushParagraph()
                var items: [[MdBlock]] = [[.paragraph(spans(first.text))]]
                while let next = lines.first, let marker = listMarker(next.trimmingCharacters(in: .whitespaces)),
                      marker.ordered == first.ordered {
                    lines.removeFirst()
                    items.append([.paragraph(spans(marker.text))])
                }
                blocks.append(.list(ordered: first.ordered, start: first.ordered ? first.number : nil, items: items))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func listMarker(_ line: String) -> (ordered: Bool, number: Int, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return (false, 0, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, let number = Int(digits) {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, number, String(rest.dropFirst(2))) }
        }
        return nil
    }

    /// Inline spans: `code`, **strong**, *emphasis*, [text](url).
    static func spans(_ text: String) -> [MdSpan] {
        var out: [MdSpan] = []
        var buffer = ""
        var rest = Substring(text)

        func flush() {
            if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
        }
        func take(_ open: String, _ close: String) -> String? {
            guard rest.hasPrefix(open) else { return nil }
            let afterOpen = rest.dropFirst(open.count)
            guard let end = afterOpen.range(of: close), end.lowerBound > afterOpen.startIndex else { return nil }
            let inner = String(afterOpen[afterOpen.startIndex..<end.lowerBound])
            rest = afterOpen[end.upperBound...]
            return inner
        }

        while !rest.isEmpty {
            if let code = take("`", "`") {
                flush(); out.append(.code(code))
            } else if let strong = take("**", "**") {
                flush(); out.append(.strong(spans(strong)))
            } else if let emph = take("*", "*") {
                flush(); out.append(.emph(spans(emph)))
            } else if rest.hasPrefix("["), let close = rest.range(of: "]("), let end = rest[close.upperBound...].firstIndex(of: ")") {
                let label = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                let url = String(rest[close.upperBound..<end])
                flush(); out.append(.link(spans: spans(label), url: url))
                rest = rest[rest.index(after: end)...]
            } else {
                buffer.append(rest.removeFirst())
            }
        }
        flush()
        return out
    }
}
