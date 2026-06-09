import AppKit
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "fred-view")

// MARK: - FredView

/// Fred agent view — mailbox + calendar HUD (top) + Fred REPL (bottom), draggable split.
/// Mirrors PerriView's structure: outer vertical split, inner horizontal HUD split.
class FredView: NSView, NSSplitViewDelegate {

    private let split              = DarkSplitView()
    private var didSetInitialPosition = false
    private var isReadyToSave        = false
    private static let udKey = "nostromo.agent.fred.hudHeight"

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        split.isVertical   = false      // horizontal divider (top / bottom)
        split.dividerStyle = .thin
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addSubview(FredHUD())
        split.addSubview(ReplView(tag: "fred", agentName: "fred", displayName: "Fred",
                                  quickActions: [QuickAction.clearContext]))
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSetInitialPosition, window != nil else { return }
        didSetInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.height > 0 else { return }
            let saved = UserDefaults.standard.double(forKey: Self.udKey)
            let pos   = saved > 10 ? saved : self.bounds.height * 0.55
            self.split.setPosition(pos, ofDividerAt: 0)
            self.isReadyToSave = true
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? max(pos, 100) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.height - 120) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let h = split.subviews.first?.frame.height, h > 10 else { return }
        UserDefaults.standard.set(h, forKey: Self.udKey)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - FredHUD (mailbox pane + calendar pane)

private class FredHUD: NSView, NSSplitViewDelegate {

    private let mailboxPane  = FredMailboxPane()
    private let calendarPane = FredCalendarPane()
    private let split        = DarkSplitView()
    private var cancellables = Set<AnyCancellable>()
    private var didSetInitialPosition = false
    private var isReadyToSave        = false
    private static let udKey = "nostromo.agent.fred.hudListWidth"

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        split.isVertical   = true       // vertical divider (left / right)
        split.dividerStyle = .thin
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addSubview(mailboxPane)
        split.addSubview(calendarPane)
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Subscribe to Fred state from AppStore.
        AppStore.shared.$fredMailbox
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in self?.mailboxPane.update(snap) }
            .store(in: &cancellables)

        AppStore.shared.$fredCalendar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in self?.calendarPane.update(snap) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSetInitialPosition, window != nil else { return }
        didSetInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.width > 0 else { return }
            let saved = UserDefaults.standard.double(forKey: Self.udKey)
            let pos   = saved > 10 ? saved : self.bounds.width * 0.50
            self.split.setPosition(pos, ofDividerAt: 0)
            self.isReadyToSave = true
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? max(pos, 200) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.width - 200) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let w = split.subviews.first?.frame.width, w > 10 else { return }
        UserDefaults.standard.set(w, forKey: Self.udKey)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - FredMailboxPane

private class FredMailboxPane: NSView {

    private let scrollView   = NSScrollView()
    private let stackView    = NSStackView()
    private let headerLabel  = NSTextField(labelWithString: "MAILBOX")

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Toolbar
        let toolbar = makeToolbar(title: "MAILBOX")
        addSubview(toolbar)

        // Scroll + stack
        let clip = FlippedClipView()
        scrollView.contentView         = clip
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.drawsBackground     = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing     = 0
        stackView.alignment   = .width
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        showEmpty("Loading mailbox…")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ snap: MailboxSnapshot?) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let snap else {
            showEmpty("Loading mailbox…")
            return
        }
        if let err = snap.error {
            showEmpty("Error: \(err)")
            return
        }
        if snap.items.isEmpty {
            showEmpty("Inbox empty")
            return
        }
        for item in snap.items {
            let row = FredMailRow(item: item)
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    private func showEmpty(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font            = .systemFont(ofSize: 11)
        label.textColor       = Theme.fgMuted
        label.lineBreakMode   = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        let w = NSView()
        w.translatesAutoresizingMaskIntoConstraints = false
        w.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: w.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -12),
            w.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 12),
        ])
        stackView.addArrangedSubview(w)
        w.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }
}

// MARK: - FredCalendarPane

private class FredCalendarPane: NSView {

    private let scrollView = NSScrollView()
    private let stackView  = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        let toolbar = makeToolbar(title: "TODAY")
        addSubview(toolbar)

        let clip = FlippedClipView()
        scrollView.contentView         = clip
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.drawsBackground     = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing     = 0
        stackView.alignment   = .width
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        showEmpty("Loading calendar…")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ snap: CalendarSnapshot?) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let snap else {
            showEmpty("Loading calendar…")
            return
        }
        if let err = snap.error {
            showEmpty("Error: \(err)")
            return
        }
        // Sort by start time ascending
        let events = snap.events.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        if events.isEmpty {
            showEmpty("No events today")
            return
        }
        for event in events {
            let row = FredCalendarRow(event: event)
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    private func showEmpty(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font            = .systemFont(ofSize: 11)
        label.textColor       = Theme.fgMuted
        label.lineBreakMode   = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        let w = NSView()
        w.translatesAutoresizingMaskIntoConstraints = false
        w.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: w.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -12),
            w.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 12),
        ])
        stackView.addArrangedSubview(w)
        w.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }
}

// MARK: - FredMailRow (AppKit)

private class FredMailRow: NSView {

    private let item: MailboxItem

    init(item: MailboxItem) {
        self.item = item
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        // Unread dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = item.isRead
            ? NSColor.clear.cgColor
            : NSColor.controlAccentColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        // Sender
        let fromLabel = NSTextField(labelWithString: item.vip ? "★ \(item.from)" : item.from)
        fromLabel.font          = item.isRead
            ? .systemFont(ofSize: 12)
            : .systemFont(ofSize: 12, weight: .semibold)
        fromLabel.textColor     = Theme.fg
        fromLabel.lineBreakMode = .byTruncatingTail

        // Subject
        let subjectLabel = NSTextField(labelWithString: item.subject)
        subjectLabel.font          = .systemFont(ofSize: 11)
        subjectLabel.textColor     = Theme.fgMuted
        subjectLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [fromLabel, subjectLabel])
        textStack.orientation = .vertical
        textStack.spacing     = 1
        textStack.alignment   = .leading

        // Relative time
        let timeLabel = NSTextField(labelWithString: relativeTime(for: item.receivedAt) ?? "")
        timeLabel.font      = Theme.monoFont
        timeLabel.textColor = Theme.fgMuted
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, textStack, timeLabel])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    private func relativeTime(for date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - FredCalendarRow (AppKit)

private class FredCalendarRow: NSView {

    private let event: CalendarEvent

    init(event: CalendarEvent) {
        self.event = event
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        if event.isNow {
            layer?.backgroundColor = NSColor.orange.withAlphaComponent(0.08).cgColor
        }

        // Status bar
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = statusColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 4).isActive = true

        let isCancelledOrDeclined = event.status == "cancelled" || event.status == "declined"

        // Title
        let titleLabel = NSTextField(labelWithString: event.title)
        titleLabel.font           = .systemFont(ofSize: 12, weight: event.isNow ? .semibold : .regular)
        titleLabel.textColor      = isCancelledOrDeclined ? Theme.fgMuted : Theme.fg
        titleLabel.lineBreakMode  = .byTruncatingTail
        if isCancelledOrDeclined {
            // Strikethrough
            let attrs: [NSAttributedString.Key: Any] = [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: Theme.fgMuted,
                .font: NSFont.systemFont(ofSize: 12),
            ]
            titleLabel.attributedStringValue = NSAttributedString(string: event.title, attributes: attrs)
        }

        // Time range
        let timeLabel = NSTextField(labelWithString: timeRange() ?? "")
        timeLabel.font      = .systemFont(ofSize: 10)
        timeLabel.textColor = Theme.fgMuted

        let textStack = NSStackView(views: [titleLabel, timeLabel])
        textStack.orientation = .vertical
        textStack.spacing     = 1
        textStack.alignment   = .leading

        let row = NSStackView(views: [bar, textStack])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    private var statusColor: NSColor {
        if event.isNow { return .orange }
        if event.status == "cancelled" || event.status == "declined" { return Theme.fgMuted }
        if event.status == "tentativelyAccepted" { return Theme.fgMuted }
        return .controlAccentColor
    }

    private func timeRange() -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        guard let start = event.start else { return nil }
        let startStr = fmt.string(from: start)
        if let end = event.end {
            return "\(startStr)–\(fmt.string(from: end))"
        }
        return startStr
    }
}

// MARK: - FlippedClipView (file-private)

private class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Toolbar helper (file-private)

private func makeToolbar(title: String) -> NSView {
    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: title)
    label.font      = .systemFont(ofSize: 9, weight: .semibold)
    label.textColor = Theme.fgMuted
    label.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(label)

    NSLayoutConstraint.activate([
        label.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        label.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
    ])

    return toolbar
}
