import AppKit
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "perri-view")

// MARK: - CiState display extensions (AppKit colours live here, not in Models.swift)

extension CiState {
    var glyph: String {
        switch self {
        case .success: return "✓"
        case .pending: return "⟳"
        case .failure: return "✗"
        case .unknown: return "-"
        }
    }
    var color: NSColor {
        switch self {
        case .success: return Theme.sage
        case .pending: return Theme.amber
        case .failure: return Theme.redSweater
        case .unknown: return Theme.fgMuted
        }
    }
}

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
        split.addSubview(ReplView(tag: "perri", displayName: "Perri"))
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

        prList.onSelect = { [weak self] pr in
            guard let pr else { return }
            // Reset enriched content immediately so the prior PR's detail is never visible.
            self?.prDetail.showStatic(pr)
            // Ask AppStore to populate the enriched detail pane.
            AppStore.shared.selectPR(pr)
        }

        // Subscribe to real queue data
        AppStore.shared.$perriQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.prList.update(items) }
            .store(in: &cancellables)

        AppStore.shared.$perriQueueError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in self?.prList.setError(err) }
            .store(in: &cancellables)

        AppStore.shared.$perriDetail
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detail in self?.prDetail.updateDetail(detail) }
            .store(in: &cancellables)

        AppStore.shared.$perriDetailLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in self?.prDetail.setLoading(loading) }
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

    private let scrollView       = NSScrollView()
    private let stackView        = NSStackView()
    private let headerLabel      = NSTextField(labelWithString: "")
    private let refreshBtn       = NSButton()
    private let startReviewingBtn = NSButton()
    private let spinner          = NSProgressIndicator()
    private var cancellables     = Set<AnyCancellable>()

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

        // "Start Reviewing" pill button — clears Perri's session context
        startReviewingBtn.bezelStyle = .inline
        startReviewingBtn.isBordered = false
        startReviewingBtn.wantsLayer = true
        startReviewingBtn.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.20).cgColor
        startReviewingBtn.layer?.cornerRadius    = 5
        let reviewAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Theme.fg,
        ]
        startReviewingBtn.attributedTitle = NSAttributedString(string: "Start Reviewing", attributes: reviewAttrs)
        startReviewingBtn.target = self
        startReviewingBtn.action = #selector(startReviewing)
        startReviewingBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(startReviewingBtn)

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
            // "Start Reviewing" button — between header label and refresh button
            startReviewingBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            startReviewingBtn.heightAnchor.constraint(equalToConstant: 22),
            startReviewingBtn.leadingAnchor.constraint(greaterThanOrEqualTo: headerLabel.trailingAnchor, constant: 8),
            startReviewingBtn.trailingAnchor.constraint(lessThanOrEqualTo: refreshBtn.leadingAnchor, constant: -8),
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

    @objc private func startReviewing() {
        // Obtain the Perri session (idempotent — returns existing if already created).
        // Clear context so Perri's system prompt auto-starts the review workflow
        // on the fresh session. No prompt needed for the empty-prompt case.
        let session = AppStore.shared.session(for: "perri", displayName: "Perri")
        session.newSession()
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

        // CI state glyph — between bucket dot and PR number.
        let ci = NSTextField(labelWithString: pr.ciState.glyph)
        ci.font      = .systemFont(ofSize: 10, weight: .semibold)
        ci.textColor = pr.ciState.color
        ci.setContentHuggingPriority(.required, for: .horizontal)

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

        let topRow = NSStackView(views: [dot, ci, numLabel, titleLabel])
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

// MARK: - PerriCICheckRow

private class PerriCICheckRow: NSView {

    private let check: CiCheck
    private var popover: NSPopover?

    init(check: CiCheck) {
        self.check = check
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let glyph = NSTextField(labelWithString: check.state.glyph)
        glyph.font      = .systemFont(ofSize: 10, weight: .semibold)
        glyph.textColor = check.state.color
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: check.name)
        name.font          = Theme.monoFont
        name.textColor     = Theme.fg
        name.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [glyph, name])
        row.orientation = .horizontal
        row.spacing     = 6
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])

        if check.state == .failure && !(check.detail ?? "").isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard check.state == .failure, !(check.detail ?? "").isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard check.state == .failure, let log = check.detail, !log.isEmpty else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = makeLogVC(log)
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        popover = pop
    }

    override func mouseExited(with event: NSEvent) {
        popover?.performClose(nil)
        popover = nil
    }

    private func makeLogVC(_ text: String) -> NSViewController {
        let vc = NSViewController()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers    = true
        scroll.drawsBackground       = true
        scroll.backgroundColor       = NSColor(white: 0.08, alpha: 1)
        scroll.borderType            = .noBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable       = false
        tv.isSelectable     = true
        tv.drawsBackground  = true
        tv.backgroundColor  = NSColor(white: 0.08, alpha: 1)
        tv.textColor        = Theme.fg
        tv.font             = Theme.monoFont
        tv.string           = text
        tv.autoresizingMask = [.width, .height]

        scroll.documentView = tv
        vc.view = scroll
        vc.preferredContentSize = NSSize(width: 480, height: 320)
        return vc
    }
}

// MARK: - PerriPRDetail

private class PerriPRDetail: NSView {

    private let emptyLabel  = NSTextField(labelWithString: "Select a PR")
    private let scrollView  = NSScrollView()
    private let contentView = NSView()

    // Static header (always visible once a PR is selected)
    private let numberLabel  = NSTextField(labelWithString: "")
    private let titleLabel   = NSTextField(labelWithString: "")
    private let bucketLabel  = NSTextField(labelWithString: "")
    private let metaStack    = NSStackView()
    private let openButton   = NSButton()

    // Enriched sections (shown after detail loads)
    private let sizeLabel    = NSTextField(labelWithString: "")
    private let ciSection    = NSStackView()
    private let diffView     = NSTextView()
    private let diffScroll   = NSScrollView()
    private let diffPlaceholder = NSTextField(labelWithString: "")
    private let loadingSpinner  = NSProgressIndicator()
    private let errorBanner     = NSTextField(labelWithString: "")

    // Bottom-of-content anchor constraint — rebuilt when layout changes.
    private var bottomConstraint: NSLayoutConstraint?

    // Currently shown static PR (for stale-fetch guard in updateDetail).
    private var currentPR: PRQueueItem?
    private var currentURL: String?

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

        // Static header fields
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

        openButton.title            = "Open in GitHub  ↗"
        openButton.bezelStyle       = .rounded
        openButton.isBordered       = true
        openButton.target           = self
        openButton.action           = #selector(openInGitHub)
        openButton.font             = .systemFont(ofSize: 11)
        openButton.contentTintColor = Theme.cornflower

        // Size header
        sizeLabel.font      = Theme.monoFont
        sizeLabel.textColor = Theme.fgMuted
        sizeLabel.isHidden  = true

        // CI section (vertical stack of PerriCICheckRow)
        ciSection.orientation = .vertical
        ciSection.spacing     = 0
        ciSection.alignment   = .leading
        ciSection.isHidden    = true

        // Diff view
        diffScroll.hasVerticalScroller   = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.autohidesScrollers    = true
        diffScroll.drawsBackground       = true
        diffScroll.backgroundColor       = NSColor(white: 0.04, alpha: 1)
        diffScroll.borderType            = .noBorder

        diffView.isEditable      = false
        diffView.isSelectable    = true
        diffView.drawsBackground = true
        diffView.backgroundColor = NSColor(white: 0.04, alpha: 1)
        diffView.font            = Theme.monoFont
        diffView.isHidden        = true

        diffScroll.documentView  = diffView
        diffScroll.isHidden      = true

        diffPlaceholder.font      = Theme.monoFont
        diffPlaceholder.textColor = Theme.fgMuted
        diffPlaceholder.stringValue = "Diff too large to display"
        diffPlaceholder.isHidden  = true

        // Loading spinner
        loadingSpinner.style                  = .spinning
        loadingSpinner.controlSize            = .small
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.isHidden               = true

        // Error banner
        errorBanner.font          = Theme.monoFont
        errorBanner.textColor     = Theme.redSweater
        errorBanner.lineBreakMode = .byWordWrapping
        errorBanner.maximumNumberOfLines = 4
        errorBanner.isHidden      = true

        let allViews: [NSView] = [
            numberLabel, titleLabel, bucketLabel, metaStack, openButton,
            sizeLabel, ciSection, diffScroll, diffPlaceholder,
            loadingSpinner, errorBanner,
        ]
        for v in allViews {
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

            openButton.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 16),
            openButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            sizeLabel.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 20),
            sizeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sizeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            ciSection.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 12),
            ciSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            ciSection.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            diffScroll.topAnchor.constraint(equalTo: ciSection.bottomAnchor, constant: 12),
            diffScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            diffPlaceholder.topAnchor.constraint(equalTo: ciSection.bottomAnchor, constant: 12),
            diffPlaceholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            diffPlaceholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            loadingSpinner.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 20),
            loadingSpinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingSpinner.widthAnchor.constraint(equalToConstant: 20),
            loadingSpinner.heightAnchor.constraint(equalToConstant: 20),

            errorBanner.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 20),
            errorBanner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            errorBanner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        rebuildBottomConstraint(anchor: openButton)

        // Empty state overlay
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

    // MARK: - Public API

    /// Show the static PR header immediately; clears enriched sections.
    func showStatic(_ pr: PRQueueItem) {
        currentPR  = pr
        currentURL = pr.url

        scrollView.isHidden = false
        emptyLabel.isHidden = true

        let shortRepo = (pr.repo as NSString).lastPathComponent
        numberLabel.stringValue = "#\(pr.number) · \(shortRepo)"
        titleLabel.stringValue  = pr.title
        bucketLabel.stringValue = bucketDisplay(pr.bucket)
        bucketLabel.textColor   = bucketColor(pr.bucket)

        rebuildMeta(pr)

        // Clear enriched sections until detail arrives.
        sizeLabel.isHidden = true
        ciSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ciSection.isHidden = true
        diffScroll.isHidden = true
        diffPlaceholder.isHidden = true
        errorBanner.isHidden = true
        rebuildBottomConstraint(anchor: openButton)
    }

    /// Apply enriched detail (size, CI, diff) when available.
    func updateDetail(_ detail: PRDetail?) {
        guard let detail,
              let pr = currentPR,
              detail.repo == pr.repo,
              (detail.prNumber.map { Int($0) } ?? -1) == pr.number
        else { return }

        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true

        if let err = detail.error, !err.isEmpty {
            errorBanner.stringValue = "Error: \(err)"
            errorBanner.isHidden    = false
            rebuildBottomConstraint(anchor: errorBanner)
            return
        }

        // Size header
        sizeLabel.stringValue = "+\(detail.additions) / -\(detail.deletions) · \(detail.changedFiles) files changed"
        sizeLabel.isHidden    = false

        // CI checks
        ciSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !detail.ciChecks.isEmpty {
            for check in detail.ciChecks {
                let row = PerriCICheckRow(check: check)
                row.translatesAutoresizingMaskIntoConstraints = false
                ciSection.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: ciSection.widthAnchor).isActive = true
            }
            ciSection.isHidden = false
        }

        // Diff
        var lastAnchor: NSView = ciSection.isHidden ? sizeLabel : ciSection
        if detail.diffTooLarge || detail.diff.isEmpty {
            if detail.diffTooLarge {
                diffPlaceholder.isHidden = false
                lastAnchor = diffPlaceholder
            }
        } else {
            // Build attributed string off-main, then assign.
            let rawDiff = detail.diff
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let attrStr = buildDiffAttributedString(rawDiff)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.diffView.textStorage?.setAttributedString(attrStr)
                    self.diffScroll.isHidden = false
                    self.rebuildBottomConstraint(anchor: self.diffScroll)
                }
            }
            lastAnchor = diffScroll
        }
        rebuildBottomConstraint(anchor: lastAnchor)
    }

    /// Show / hide the loading spinner.
    func setLoading(_ loading: Bool) {
        if loading {
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
        }
    }

    // MARK: - Private helpers

    private func showEmpty() {
        scrollView.isHidden = true
        emptyLabel.isHidden = false
        currentURL = nil
        currentPR  = nil
    }

    private func rebuildMeta(_ pr: PRQueueItem) {
        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shortRepo = (pr.repo as NSString).lastPathComponent
        if pr.newActivity {
            metaStack.addArrangedSubview(metaRow(key: "Activity",
                                                  value: "New activity since your review",
                                                  highlight: true))
        }
        for (k, v) in [("Repo", shortRepo), ("Author", pr.author), ("Bucket", pr.bucket)] {
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

    /// Update the content-view bottom constraint so the scroll view sizes correctly.
    private func rebuildBottomConstraint(anchor: NSView) {
        bottomConstraint?.isActive = false
        let c = contentView.bottomAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 20)
        c.isActive = true
        bottomConstraint = c
    }

    @objc private func openInGitHub() {
        guard let urlString = currentURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func bucketDisplay(_ bucket: String) -> String {
        switch bucket {
        case "requested":    return "REVIEW REQUESTED"
        case "needs_review": return "NEEDS REVIEW"
        case "changes_req":  return "CHANGES REQUESTED"
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

// MARK: - Diff attributed string builder

/// Build a syntax-coloured attributed string from a raw unified diff.
/// Pure function — safe to call off the main thread.
private func buildDiffAttributedString(_ diff: String) -> NSAttributedString {
    let font = Theme.monoFont
    let result = NSMutableAttributedString()
    let lines = diff.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
        let color = diffLineColor(line)
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: color,
        ]
        result.append(NSAttributedString(string: line, attributes: attrs))
        if i < lines.count - 1 {
            result.append(NSAttributedString(string: "\n", attributes: attrs))
        }
    }
    return result
}
