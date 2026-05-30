import AppKit
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "perri-view")

// MARK: - PerriView

/// Perri agent view — PR dashboard (top) + Perri REPL (bottom), draggable split.
class PerriView: NSView, NSSplitViewDelegate {

    private let split = DarkSplitView()
    private var didSetInitialPosition = false
    private var isReadyToSave        = false
    private static let udKey = "nostromo.perri.hudHeight"

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        split.isVertical   = false      // horizontal divider (top / bottom)
        split.dividerStyle = .thin
        // Manual save/restore below — autosaveName omitted to prevent NSSplitView
        // from overwriting our key with its absolute-rect format on geometry changes.
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addSubview(PerriHUD())
        split.addSubview(ReplView(tag: "perri"))
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
        // Defer one runloop pass so NSSplitView's default layout settles first.
        // isReadyToSave is set AFTER setPosition so that the initial adjustSubviews
        // callback doesn't overwrite the user's saved value.
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
        idx == 0 ? max(pos, 120) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.height - 150) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let h = split.subviews.first?.frame.height, h > 10 else { return }
        UserDefaults.standard.set(h, forKey: Self.udKey)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - PerriHUD (PR list + detail)

private class PerriHUD: NSView, NSSplitViewDelegate {

    private let prList   = PerriPRList()
    private let prDetail = PerriPRDetail()
    private let split    = DarkSplitView()
    private var cancellables = Set<AnyCancellable>()
    private var didSetInitialPosition = false
    private var isReadyToSave        = false
    private static let udKey = "nostromo.perri.listWidth"

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        split.isVertical   = true       // vertical divider (left / right)
        split.dividerStyle = .thin
        // Manual save/restore below — autosaveName omitted to prevent NSSplitView
        // from overwriting our key with its absolute-rect format on geometry changes.
        split.delegate     = self
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addSubview(prList)
        split.addSubview(prDetail)
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        prList.onSelect = { [weak self] pr in self?.prDetail.show(pr) }

        // Subscribe to real queue data
        AppStore.shared.$perriQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.prList.update(items) }
            .store(in: &cancellables)

        AppStore.shared.$perriQueueError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in self?.prList.setError(err) }
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
            let pos   = saved > 10 ? saved : 320
            self.split.setPosition(pos, ofDividerAt: 0)
            self.isReadyToSave = true
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? max(pos, 200) : pos
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        idx == 0 ? min(pos, sv.bounds.width - 240) : pos
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isReadyToSave,
              let w = split.subviews.first?.frame.width, w > 10 else { return }
        UserDefaults.standard.set(w, forKey: Self.udKey)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - FlippedClipView (file-private)

private class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - PerriPRList

private class PerriPRList: NSView {

    var onSelect: ((PRQueueItem?) -> Void)?

    private let scrollView   = NSScrollView()
    private let stackView    = NSStackView()
    private let headerLabel  = NSTextField(labelWithString: "")
    private let refreshBtn   = NSButton()
    private let spinner      = NSProgressIndicator()
    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Toolbar strip
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        headerLabel.font        = .systemFont(ofSize: 9, weight: .semibold)
        headerLabel.textColor   = Theme.fgMuted
        headerLabel.stringValue = "PR QUEUE"
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(headerLabel)

        refreshBtn.isBordered       = false
        refreshBtn.title            = "↺"
        refreshBtn.font             = .systemFont(ofSize: 13)
        refreshBtn.contentTintColor = Theme.fgMuted
        refreshBtn.target           = self
        refreshBtn.action           = #selector(didRefresh)
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(refreshBtn)

        spinner.style                  = .spinning
        spinner.controlSize            = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(spinner)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            headerLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            // Spinner sits where the button is; button hides while spinning
            spinner.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            refreshBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            refreshBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -4),
        ])

        // Observe loading state → toggle spinner ↔ button
        AppStore.shared.$perriQueueLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading {
                    self.refreshBtn.isHidden = true
                    self.spinner.startAnimation(nil)
                } else {
                    self.spinner.stopAnimation(nil)
                    self.refreshBtn.isHidden = false
                }
            }
            .store(in: &cancellables)

        // Don't set drawsBackground on the clip view — per NSClipView docs this sets
        // copiesOnScroll=false which causes scroll trails. Set it on scrollView instead.
        let clipView = FlippedClipView()
        scrollView.contentView           = clipView
        scrollView.hasVerticalScroller   = true
        scrollView.autohidesScrollers    = true
        scrollView.drawsBackground       = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stackView.orientation = .vertical
        stackView.spacing     = 0
        stackView.alignment   = .width
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func didRefresh() {
        AppStore.shared.refreshPerriQueue()
    }

    func setError(_ error: String?) {
        guard let error else { return }
        log.warning("perri queue UI error: \(error, privacy: .public)")
        // Error is shown as an empty state row — update happens via update([])
    }

    func update(_ items: [PRQueueItem]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if items.isEmpty {
            let count = AppStore.shared.perriQueueError != nil ? "Error loading" : "No PRs"
            let msg = AppStore.shared.perriQueueError ?? "Nothing in the queue"
            showEmpty(count: count, detail: msg)
            return
        }

        // Split into buckets
        let bucketOrder   = ["requested", "needs_review", "changes_req"]
        let bucketLabels  = ["requested": "REVIEW REQUESTED",
                             "needs_review": "NEEDS REVIEW",
                             "changes_req": "CHANGES REQUESTED"]

        for bucket in bucketOrder {
            let group = items.filter { $0.bucket == bucket }
            guard !group.isEmpty else { continue }

            let hdr = sectionHeader(bucketLabels[bucket] ?? bucket.uppercased(), count: group.count)
            stackView.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

            for pr in group {
                let row = PerriPRRow(pr: pr)
                row.onClick = { [weak self] p in self?.onSelect?(p) }
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }

        // Anything not in the known buckets
        let known = Set(bucketOrder)
        let other = items.filter { !known.contains($0.bucket) }
        if !other.isEmpty {
            let hdr = sectionHeader("OTHER", count: other.count)
            stackView.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

            for pr in other {
                let row = PerriPRRow(pr: pr)
                row.onClick = { [weak self] p in self?.onSelect?(p) }
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }
    }

    private func showEmpty(count: String, detail: String) {
        let label = NSTextField(labelWithString: detail)
        label.font      = .systemFont(ofSize: 11)
        label.textColor = Theme.fgMuted
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        let w = NSView()
        w.translatesAutoresizingMaskIntoConstraints = false
        w.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: w.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -12),
            w.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 12),
            w.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        stackView.addArrangedSubview(w)
        w.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func sectionHeader(_ text: String, count: Int) -> NSView {
        let label = NSTextField(labelWithString: "\(text)  \(count)")
        label.font      = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = Theme.fgMuted
        label.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.heightAnchor.constraint(equalToConstant: 20),
        ])
        return v
    }
}

// MARK: - PerriPRRow

private class PerriPRRow: NSView {

    let pr: PRQueueItem
    var onClick: ((PRQueueItem) -> Void)?

    private var isHovered: Bool = false {
        didSet { layer?.backgroundColor = isHovered
            ? Theme.cornflower.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor }
    }

    init(pr: PRQueueItem) {
        self.pr = pr
        super.init(frame: .zero)
        wantsLayer = true

        let dot = NSTextField(labelWithString: "●")
        dot.font      = .systemFont(ofSize: 8)
        dot.textColor = bucketColor(pr.bucket)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let numLabel = NSTextField(labelWithString: "#\(pr.number)")
        numLabel.font      = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        numLabel.textColor = Theme.fgMuted
        numLabel.setContentHuggingPriority(.required, for: .horizontal)

        // New-activity indicator
        var titlePrefix = ""
        if pr.newActivity { titlePrefix = "★ " }

        let titleLabel = NSTextField(labelWithString: titlePrefix + pr.title)
        titleLabel.font          = pr.newActivity
            ? .systemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12)
        titleLabel.textColor     = Theme.fg
        titleLabel.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [dot, numLabel, titleLabel])
        topRow.orientation = .horizontal
        topRow.spacing     = 5
        topRow.alignment   = .centerY

        let shortRepo = (pr.repo as NSString).lastPathComponent
        let repoLabel = NSTextField(labelWithString: "\(shortRepo)  ·  \(pr.author)")
        repoLabel.font          = Theme.monoFont
        repoLabel.textColor     = Theme.fgMuted
        repoLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [topRow, repoLabel])
        stack.orientation = .vertical
        stack.spacing     = 2
        stack.alignment   = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClick)))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func didClick() { onClick?(pr) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    private func bucketColor(_ bucket: String) -> NSColor {
        switch bucket {
        case "changes_req":  return Theme.redSweater
        case "needs_review": return Theme.sage
        default:             return Theme.cornflower
        }
    }
}

// MARK: - PerriPRDetail

private class PerriPRDetail: NSView {

    private let emptyLabel  = NSTextField(labelWithString: "Select a PR")
    private let scrollView  = NSScrollView()
    private let contentView = NSView()

    private let numberLabel  = NSTextField(labelWithString: "")
    private let titleLabel   = NSTextField(labelWithString: "")
    private let bucketLabel  = NSTextField(labelWithString: "")
    private let metaStack    = NSStackView()
    private let openButton   = NSButton()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        let clipView = FlippedClipView()
        scrollView.contentView         = clipView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.drawsBackground     = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        numberLabel.font      = Theme.monoFont
        numberLabel.textColor = Theme.fgMuted

        titleLabel.font               = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor          = Theme.fg
        titleLabel.lineBreakMode      = .byWordWrapping
        titleLabel.maximumNumberOfLines = 4

        bucketLabel.font      = .systemFont(ofSize: 10, weight: .semibold)
        bucketLabel.textColor = Theme.fgMuted

        metaStack.orientation = .vertical
        metaStack.spacing     = 4
        metaStack.alignment   = .leading

        openButton.title       = "Open in GitHub  ↗"
        openButton.bezelStyle  = .rounded
        openButton.isBordered  = true
        openButton.target      = self
        openButton.action      = #selector(openInGitHub)
        openButton.font        = .systemFont(ofSize: 11)
        openButton.contentTintColor = Theme.cornflower

        for v in [numberLabel, titleLabel, bucketLabel, metaStack, openButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            numberLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            numberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            titleLabel.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bucketLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bucketLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            metaStack.topAnchor.constraint(equalTo: bucketLabel.bottomAnchor, constant: 16),
            metaStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            metaStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            openButton.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 20),
            openButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            openButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        emptyLabel.font      = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.fgMuted
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        showEmpty()
    }

    private var currentURL: String?

    func show(_ pr: PRQueueItem?) {
        guard let pr else { showEmpty(); return }

        scrollView.isHidden = false
        emptyLabel.isHidden = true
        currentURL = pr.url

        let shortRepo = (pr.repo as NSString).lastPathComponent
        numberLabel.stringValue = "#\(pr.number) · \(shortRepo)"
        titleLabel.stringValue  = pr.title
        bucketLabel.stringValue = bucketDisplay(pr.bucket)
        bucketLabel.textColor   = bucketColor(pr.bucket)

        rebuildMeta(pr)
    }

    private func showEmpty() {
        scrollView.isHidden = true
        emptyLabel.isHidden = false
        currentURL = nil
    }

    private func rebuildMeta(_ pr: PRQueueItem) {
        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shortRepo = (pr.repo as NSString).lastPathComponent
        let pairs: [(String, String)] = [
            ("Repo",    shortRepo),
            ("Author",  pr.author),
            ("Bucket",  pr.bucket),
        ]
        if pr.newActivity {
            metaStack.addArrangedSubview(metaRow(key: "Activity", value: "New activity since your review", highlight: true))
        }
        for (k, v) in pairs {
            metaStack.addArrangedSubview(metaRow(key: k, value: v, highlight: false))
        }
    }

    private func metaRow(key: String, value: String, highlight: Bool) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font      = .systemFont(ofSize: 10, weight: .medium)
        k.textColor = Theme.fgMuted
        k.setContentHuggingPriority(.required, for: .horizontal)

        let v = NSTextField(labelWithString: value)
        v.font          = Theme.monoFont
        v.textColor     = highlight ? Theme.redSweater : Theme.fg
        v.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .firstBaseline
        return row
    }

    @objc private func openInGitHub() {
        guard let urlString = currentURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func bucketDisplay(_ bucket: String) -> String {
        switch bucket {
        case "requested":   return "REVIEW REQUESTED"
        case "needs_review": return "NEEDS REVIEW"
        case "changes_req": return "CHANGES REQUESTED"
        default:             return bucket.uppercased()
        }
    }

    private func bucketColor(_ bucket: String) -> NSColor {
        switch bucket {
        case "changes_req":  return Theme.redSweater
        case "needs_review": return Theme.sage
        default:             return Theme.cornflower
        }
    }
}
