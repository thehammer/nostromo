import AppKit
import Combine
import NostromoKit

/// The text view of a task's output: selectable, read-only, with Copy All first in its context menu.
final class TaskOutputTextView: NSTextView {
    static let copyAllTitle = "Copy All"

    var onCopyAll: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: Self.copyAllTitle, action: #selector(copyAllFromMenu(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func copyAllFromMenu(_ sender: Any?) {
        onCopyAll?()
    }
}

/// Display-only soft line breaks. TextKit lays a paragraph out whole, so one multi-megabyte line (minified
/// JSON, base64) would be laid out in full on the main thread at every append. A line break every
/// `lineLimit` characters keeps each paragraph small. Only the text view's storage carries them: Copy All
/// and the model hold the original text.
enum TaskOutputDisplay {
    static let lineLimit = 65_536

    /// `text` with a newline inserted wherever a line would pass `lineLimit` UTF-16 units. `column` is
    /// the length of the line the text continues (0 at a line start) and is updated to where `text` ends.
    static func softBroken(_ text: String, column: inout Int) -> String {
        var col = column
        var breaks: [Int] = []
        var index = 0
        let units = text.utf16
        for unit in units {
            if unit == 0x0A {
                col = 0
            } else if col >= lineLimit && !UTF16.isTrailSurrogate(unit) {
                breaks.append(index)
                col = 1
            } else {
                col += 1
            }
            index += 1
        }
        column = col
        guard !breaks.isEmpty else { return text }
        var out: [UInt16] = []
        out.reserveCapacity(index + breaks.count)
        var next = 0
        var position = 0
        for unit in units {
            if next < breaks.count, breaks[next] == position {
                out.append(0x0A)
                next += 1
            }
            out.append(unit)
            position += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}

/// A shell or monitor task's output: the header, a truncation line when the start is cut, and the
/// text in monospace from the model's first line, following the tail.
///
/// **Append-only.** New output goes in through `textStorage.beginEditing/append/endEditing`; the model's
/// head (the part of a long file read after the tail) is inserted once, in front; only a CLI tail that
/// changed is replaced whole. Counters (`appendOps`, `prependOps`, `replaceOps`) let a test prove a
/// hundred batches cost a hundred appends and no replacement.
///
/// **Following** uses the transcript's rule (`FollowTailPolicy`) on this view's clip view: only the user
/// scrolling away from the bottom stops it, a resize never does, our own scrolling is never taken for the
/// user's. While not following, appends add below the viewport and move nothing (a head being inserted
/// above keeps the distance from the bottom), and `Jump to latest` shows.
///
/// The view never makes itself first responder and never touches another window.
final class TaskOutputView: NSView, TaskWindowBody {
    static let jumpTitle = "Jump to latest"
    static let copyAllTitle = TaskOutputTextView.copyAllTitle
    static let fontSize: CGFloat = 12
    static let toolbarHeight: CGFloat = 28

    /// The focus the task belongs to. (Never `tag`: that is `NSView.tag`, an `Int`.)
    let focusTag: String
    let taskId: String
    let model: TaskOutputModel

    let textView: TaskOutputTextView
    let scrollView = NSScrollView()
    let header = TaskWindowHeaderView()

    private(set) var isFollowing = true
    private(set) var appendOps = 0
    private(set) var prependOps = 0
    private(set) var replaceOps = 0

    private let noticeLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: TaskOutputView.copyAllTitle, target: nil, action: nil)
    private let jumpButton = NSButton(title: TaskOutputView.jumpTitle, target: nil, action: nil)
    private let pasteboard: NSPasteboard
    private let attributes: [NSAttributedString.Key: Any]
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var lastClipBounds: CGRect = .zero
    private var isScrollingOurselves = false
    /// Length of the last line in the text view's storage (for the display's soft breaks).
    private var lastLineLength = 0

    // What is drawn, for tests.
    var shownText: String { textView.string }
    var noticeText: String? { noticeLabel.isHidden ? nil : noticeLabel.stringValue }
    var noticeColor: NSColor? { noticeLabel.textColor }
    var placeholderText: String? { placeholderLabel.isHidden ? nil : placeholderLabel.stringValue }
    var showsJumpToLatest: Bool { !jumpButton.isHidden }
    var jumpToLatestControl: NSButton { jumpButton }
    var copyAllControl: NSButton { copyButton }
    var clipView: NSClipView { scrollView.contentView }
    /// Distance from the bottom of the text to the bottom of the viewport.
    var distanceFromBottom: CGFloat { documentHeight - clipView.bounds.maxY }

    init(focusTag: String, taskId: String, model: TaskOutputModel, pasteboard: NSPasteboard = .general,
         stop: TaskStopWiring = TaskStopWiring()) {
        self.focusTag = focusTag
        self.taskId = taskId
        self.model = model
        self.pasteboard = pasteboard
        self.attributes = [.font: Theme.firaCode(size: Self.fontSize), .foregroundColor: TaskWindowPalette.text]

        // TextKit 1, laid out lazily: a 10 MB output opens without laying all of it out.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = TaskOutputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100), textContainer: container)

        super.init(frame: .zero)
        header.configureStop(stop, tag: focusTag, taskId: taskId)
        wantsLayer = true
        layer?.backgroundColor = TaskWindowPalette.background.cgColor

        configureTextView()
        configureChrome()
        layoutChildren()

        textView.onCopyAll = { [weak self] in self?.copyAll() }
        copyButton.target = self
        copyButton.action = #selector(copyAllClicked(_:))
        jumpButton.target = self
        jumpButton.action = #selector(jumpClicked(_:))

        showModelText()
        refreshChrome()
        subscription = model.changes.sink { [weak self] change in self?.handle(change) }
        observeScrolling()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: TaskWindowBody

    func apply(content: TaskWindowContent) {
        header.apply(content)
    }

    // MARK: Actions

    /// Put everything the model holds on the pasteboard (what is held, not just what is laid out).
    func copyAll() {
        pasteboard.clearContents()
        pasteboard.setString(model.text, forType: .string)
    }

    /// `Jump to latest`: back to the tail, following again.
    func jumpToLatest() {
        setFollowing(true)
        scrollToBottom()
    }

    @objc private func copyAllClicked(_ sender: Any?) { copyAll() }
    @objc private func jumpClicked(_ sender: Any?) { jumpToLatest() }

    // MARK: Model changes

    private func handle(_ change: TaskOutputModel.Change) {
        switch change {
        case .appended(let added): append(added)
        case .prepended(let head): prepend(head)
        case .replaced: replaceAll()
        case .status: break
        }
        refreshChrome()
    }

    private func append(_ added: String) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        let shown = TaskOutputDisplay.softBroken(added, column: &lastLineLength)
        storage.append(NSAttributedString(string: shown, attributes: attributes))
        storage.endEditing()
        appendOps += 1
        if isFollowing { scrollToBottom() }
    }

    private func prepend(_ head: String) {
        guard let storage = textView.textStorage else { return }
        let distance = distanceFromBottom
        var column = 0
        let shown = TaskOutputDisplay.softBroken(head, column: &column)
        storage.beginEditing()
        storage.insert(NSAttributedString(string: shown, attributes: attributes), at: 0)
        storage.endEditing()
        prependOps += 1
        if isFollowing {
            scrollToBottom()
        } else {
            keepDistanceFromBottom(distance)
        }
    }

    private func replaceAll() {
        guard let storage = textView.textStorage else { return }
        let origin = clipView.bounds.origin
        let hadText = storage.length > 0
        storage.beginEditing()
        lastLineLength = 0
        let shown = TaskOutputDisplay.softBroken(model.text, column: &lastLineLength)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: NSAttributedString(string: shown, attributes: attributes))
        storage.endEditing()
        // The first fill of an empty view replaces nothing.
        if hadText { replaceOps += 1 }
        if isFollowing {
            scrollToBottom()
        } else {
            scrollTo(y: origin.y)
        }
    }

    private func showModelText() {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        lastLineLength = 0
        let shown = TaskOutputDisplay.softBroken(model.text, column: &lastLineLength)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: NSAttributedString(string: shown, attributes: attributes))
        storage.endEditing()
    }

    // MARK: Following

    private var documentHeight: CGFloat { scrollView.documentView?.frame.height ?? 0 }

    private func setFollowing(_ following: Bool) {
        guard isFollowing != following else { return }
        isFollowing = following
        jumpButton.isHidden = !FollowTailPolicy.showsJumpToLatest(isPinned: following)
    }

    private func observeScrolling() {
        let clip = clipView
        clip.postsBoundsChangedNotifications = true
        lastClipBounds = clip.bounds
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in self?.clipBoundsChanged() })
        textView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in self?.textFrameChanged() })
    }

    private func clipBoundsChanged() {
        let bounds = clipView.bounds
        let pinned = FollowTailPolicy.pinnedAfterBoundsChange(
            current: isFollowing, previousBounds: lastClipBounds, bounds: bounds,
            isMaterializing: isScrollingOurselves, documentHeight: documentHeight)
        lastClipBounds = bounds
        setFollowing(pinned)
    }

    /// Lazy layout finishes later than the text arrives and the document grows under a viewport that
    /// follows: keep it on the tail.
    private func textFrameChanged() {
        guard isFollowing, !isScrollingOurselves else { return }
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let layoutManager = textView.layoutManager else { return }
        isScrollingOurselves = true
        defer {
            isScrollingOurselves = false
            lastClipBounds = clipView.bounds
        }
        let length = textView.textStorage?.length ?? 0
        if length > 0 {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
        }
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    private func scrollTo(y: CGFloat) {
        isScrollingOurselves = true
        defer {
            isScrollingOurselves = false
            lastClipBounds = clipView.bounds
        }
        let maxY = max(0, documentHeight - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func keepDistanceFromBottom(_ distance: CGFloat) {
        scrollTo(y: documentHeight - clipView.bounds.height - distance)
    }

    // MARK: Chrome

    private func refreshChrome() {
        let notice = model.truncationNotice
        noticeLabel.stringValue = notice ?? ""
        noticeLabel.isHidden = notice == nil
        copyButton.isEnabled = !model.text.isEmpty
        let placeholder = placeholderMessage()
        placeholderLabel.stringValue = placeholder ?? ""
        placeholderLabel.isHidden = placeholder == nil
    }

    /// What the pane says while there is no text: never an empty pane.
    private func placeholderMessage() -> String? {
        guard model.text.isEmpty else { return nil }
        switch model.state {
        case .loading: return "Loading output\u{2026}"
        case .unavailable: return "No output available for this task"
        case .error(let message):
            return FoldTextSanitizer.sanitize("Couldn\u{2019}t read the output: \(message)")
        case .ready: return "No output yet"
        }
    }

    // MARK: Setup

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = TaskWindowPalette.background
        textView.insertionPointColor = TaskWindowPalette.text
        textView.selectedTextAttributes = Theme.selectionAttributes
        textView.font = Theme.firaCode(size: Self.fontSize)
        textView.textColor = TaskWindowPalette.text
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Task output")

        scrollView.drawsBackground = true
        scrollView.backgroundColor = TaskWindowPalette.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
    }

    private func configureChrome() {
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = TaskWindowPalette.muted
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.maximumNumberOfLines = 1
        noticeLabel.isSelectable = false
        noticeLabel.isHidden = true
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = TaskWindowPalette.muted
        placeholderLabel.alignment = .center
        placeholderLabel.isSelectable = false
        placeholderLabel.isHidden = true
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.setAccessibilityLabel(Self.copyAllTitle)
        copyButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .small
        jumpButton.isHidden = true
        jumpButton.setAccessibilityLabel(Self.jumpTitle)
    }

    private func layoutChildren() {
        for view in [header, noticeLabel, copyButton, scrollView, placeholderLabel, jumpButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(scrollView)
        addSubview(header)
        addSubview(noticeLabel)
        addSubview(copyButton)
        addSubview(placeholderLabel)
        addSubview(jumpButton)
        let inset = TaskWindowHeaderView.inset
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            copyButton.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            copyButton.heightAnchor.constraint(equalToConstant: Self.toolbarHeight - 8),
            noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            noticeLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            noticeLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.toolbarHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),

            jumpButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            jumpButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -14),
        ])
    }
}

/// A Workflow, or any kind the daemon has no output for: the header (with the progress or closing
/// summary it has) and one plain sentence, so the pane is never empty.
final class TaskNoOutputView: NSView, TaskWindowBody {
    static let message = "No output available for this kind of task"

    let focusTag: String
    let taskId: String
    let header = TaskWindowHeaderView()
    private let messageLabel = NSTextField(wrappingLabelWithString: TaskNoOutputView.message)

    var messageText: String { messageLabel.stringValue }
    var messageColor: NSColor? { messageLabel.textColor }

    init(focusTag: String, taskId: String, stop: TaskStopWiring = TaskStopWiring()) {
        self.focusTag = focusTag
        self.taskId = taskId
        super.init(frame: .zero)
        header.configureStop(stop, tag: focusTag, taskId: taskId)
        wantsLayer = true
        layer?.backgroundColor = TaskWindowPalette.background.cgColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = TaskWindowPalette.muted
        messageLabel.alignment = .center
        messageLabel.isSelectable = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [header, messageLabel] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(header)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 28),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(content: TaskWindowContent) {
        header.apply(content)
    }
}
