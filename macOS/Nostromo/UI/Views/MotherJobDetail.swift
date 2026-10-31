import AppKit
import Combine
import NostromoKit
import SwiftUI
import os

// The Mother job detail pane and the pieces only it uses. Kept out of MotherView.swift
// so the Mac logic tests (which compile no AppStore) can drive it directly: everything the
// detail needs from the app goes through `MotherJobDetailHost`.

private let log = Logger(subsystem: "com.hammer.nostromo", category: "mother-detail")

// MARK: - JobViewSwitch

/// The Overview · Plan · Log switch, with a say in what a screen reader reads for each segment.
///
/// AppKit builds a segmented control's accessibility children itself, as private proxies it makes again at
/// every query, so a label set on one of them is gone by the next (and they are not `NSAccessibilityElement`s
/// to begin with). The visible label of the Log segment is "Log •", which a screen reader reads as "Log
/// bullet". So the control answers `accessibilityChildren()` itself: one radio-button element per segment,
/// named from `spokenLabels` (the segment's own label while there is none), carrying whether it is the
/// selected one and pressing it as a click would. The elements are kept, so their identity is stable.
final class JobViewSwitch: NSSegmentedControl {

    /// What is read for each segment, by index. Missing entries fall back to the visible label.
    var spokenLabels: [String] = []

    private var elements: [SegmentElement] = []

    /// The segment's name as a screen reader gets it.
    func spokenLabel(forSegment index: Int) -> String? {
        guard index >= 0, index < segmentCount else { return nil }
        if index < spokenLabels.count { return spokenLabels[index] }
        return label(forSegment: index)
    }

    override func accessibilityChildren() -> [Any]? {
        guard !readingAppKitChildren else { return nil }
        while elements.count < segmentCount {
            let element = SegmentElement()
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityParent(self)
            elements.append(element)
        }
        if elements.count > segmentCount { elements.removeLast(elements.count - segmentCount) }
        let frames = segmentFrames()
        for (index, element) in elements.enumerated() {
            element.setAccessibilityLabel(spokenLabel(forSegment: index))
            element.setAccessibilityFrameInParentSpace(frames[index])
            element.isSelectedSegment = selectedSegment == index
            element.press = { [weak self] in self?.pressSegment(index) }
        }
        return elements
    }

    /// Where each segment is, in the control's own coordinates. AppKit lays the segments out and builds its
    /// own accessibility proxy for each, whose frame is the segment's real rectangle whatever the
    /// control's `segmentDistribution`, widths or style (Voice Control and the VoiceOver cursor draw
    /// from these frames). Only when AppKit gives none that fit (the control is not in a window yet, or
    /// it names another number of children) are they worked out from the distribution.
    private func segmentFrames() -> [NSRect] {
        appKitSegmentFrames() ?? estimatedSegmentFrames()
    }

    /// Set while AppKit's own children are being read, so a query that comes back to this control from
    /// inside that read is answered with nothing instead of recursing.
    private var readingAppKitChildren = false

    /// The rectangles of AppKit's own segment proxies, converted from screen coordinates, or nil when
    /// they are missing or do not lie on the control.
    private func appKitSegmentFrames() -> [NSRect]? {
        guard let window, segmentCount > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        readingAppKitChildren = true
        defer { readingAppKitChildren = false }
        guard let proxies = super.accessibilityChildren(), proxies.count == segmentCount else { return nil }
        let frameKey = "accessibilityFrame"
        let slack = bounds.insetBy(dx: -4, dy: -4)
        var frames: [NSRect] = []
        for proxy in proxies {
            guard let object = proxy as? NSObject, object.responds(to: NSSelectorFromString(frameKey)),
                  let value = object.value(forKey: frameKey) as? NSValue else { return nil }
            let frame = convert(window.convertFromScreen(value.rectValue), from: nil)
            guard frame.width > 0, frame.height > 0, slack.contains(frame) else { return nil }
            frames.append(frame)
        }
        return frames
    }

    /// The control's width shared out by its distribution: equally for `.fillEqually`, otherwise by the
    /// width of each label with the same padding each (the segments size themselves to their labels).
    private func estimatedSegmentFrames() -> [NSRect] {
        let count = segmentCount
        guard count > 0, bounds.width > 0 else { return Array(repeating: bounds, count: count) }
        let shares: [CGFloat]
        if segmentDistribution == .fillEqually {
            shares = Array(repeating: bounds.width / CGFloat(count), count: count)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            let widths = (0 ..< count).map { NSAttributedString(string: label(forSegment: $0) ?? "", attributes: attributes).size().width }
            let padding = max(0, (bounds.width - widths.reduce(0, +)) / CGFloat(count))
            shares = widths.map { $0 + padding }
        }
        var x = bounds.minX
        return shares.map { width in
            defer { x += width }
            return NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    private func pressSegment(_ index: Int) {
        guard index >= 0, index < segmentCount else { return }
        selectedSegment = index
        if let action { NSApplication.shared.sendAction(action, to: target, from: self) }
    }

    private final class SegmentElement: NSAccessibilityElement {
        var isSelectedSegment = false
        var press: (() -> Void)?

        override func accessibilityValue() -> Any? { isSelectedSegment ? 1 : 0 }

        override func accessibilityPerformPress() -> Bool {
            guard let press else { return false }
            press()
            return true
        }
    }
}

// MARK: - MotherJobDetailHost

/// What `MotherJobDetail` needs from the app. `AppStore` conforms; tests pass a stub.
protocol MotherJobDetailHost: AnyObject {
    var brokerConnected: Bool { get }
    var brokerConnectedPublisher: AnyPublisher<Bool, Never> { get }
    var motherActionErrorPublisher: AnyPublisher<String?, Never> { get }
    var motherPeeksPublisher: AnyPublisher<[String: MotherPeekPayload], Never> { get }
    func peek(for jobId: String) -> MotherPeekPayload?

    /// False for a broker other than Mother's own (`MOTHER_BROKER_SOCK`, the QA path), whose
    /// jobs the `mother` CLI does not know. Escalate and `mother status` are skipped then.
    var usesDefaultBroker: Bool { get }
    /// The `mother` CLI, or nil when it is not installed.
    func motherBinary() -> URL?

    func answerJob(_ id: String, text: String)

    /// The broker advertised `answer.option` (answers by option id, with a `source`).
    var supportsAnswerOption: Bool { get }
    /// The broker advertised `ack`.
    var supportsAck: Bool { get }
    /// Fires, on the main thread, when a decision's send state or a capability changes.
    var motherDecisionChangesPublisher: AnyPublisher<Void, Never> { get }
    func motherDecisionState(jobId: String, decisionId: String) -> MotherDecisionSendState
    func beginMotherDecisionConfirm(jobId: String, decisionId: String, option: MotherDecisionOptionID)
    func cancelMotherDecisionConfirm(jobId: String, decisionId: String)
    func answerMotherDecision(jobId: String, decisionId: String, option: MotherDecisionOption, text: String)
    func ackMotherAttention(jobId: String, reason: MotherAttentionReason)

    func cancelJob(_ id: String)
    func retryJob(_ id: String)
    func forceStartJob(_ id: String)
    func escalateJob(_ id: String)
    func archiveJob(_ id: String)
    func openPlan(path: String)
    func clearMotherActionError()
}

// MARK: - MotherGestureInputs

/// Where the human-gesture check reads its inputs. The defaults are the real ones; a test
/// replaces them to play a person, a VoiceOver press, app-control or a QA run.
struct MotherGestureInputs {
    var currentEvent: () -> NSEvent? = { NSApp?.currentEvent }
    var voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var allowsSynthetic: () -> Bool = { SyntheticInputGate.allowsSynthetic }
}

// MARK: - GuidanceTextView

/// The reply box, with a placeholder while it is empty (an NSTextView has none of its own).
final class GuidanceTextView: NSTextView {
    var placeholder: String? { didSet { needsDisplay = true } }
    override var string: String { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(at: NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height),
                         withAttributes: [.font: Theme.monoFont, .foregroundColor: Theme.fgMuted])
    }

    override func accessibilityPlaceholderValue() -> String? { placeholder }
}

// MARK: - PhaseRibbonView

/// Compact phase-progress ribbon: `redd✓ cody⟳ marty· · cycle 2`
///
/// Hidden (zero height) when the job has no phase data — non-pipeline and
/// pre-Wedge-C jobs are unaffected.
/// A wrapping label for text that comes from data. Its intrinsic width is capped, so a long
/// line can never set the fitting width of the pane (a plain single-line label reports the
/// text's full width), and it wraps at the width it is actually given.
final class BoundedLabel: NSTextField {
    /// Widest the label asks for by itself; the container may give it more.
    static let intrinsicWidthCap: CGFloat = 200

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if size.width > Self.intrinsicWidthCap { size.width = Self.intrinsicWidthCap }
        return size
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

extension NSTextField {
    static func boundedLabel(_ text: String, maxLines: Int = 3, truncating: Bool = false) -> NSTextField {
        let f = BoundedLabel(wrappingLabelWithString: text)
        f.maximumNumberOfLines = maxLines
        f.lineBreakMode = truncating ? .byTruncatingTail : .byWordWrapping
        f.isSelectable = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }
}

/// A wrapping label that is pinned to both edges of its container: it reports no intrinsic
/// width (so its text can never set the container's fitting width) and wraps at the width
/// it is given.
private final class EdgePinnedLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = NSView.noIntrinsicMetric
        return size
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private class PhaseRibbonView: NSView {

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing     = 6
        stack.alignment   = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild the ribbon from `model`.  Passing nil clears all tokens.
    func update(_ model: PhaseRibbonModel?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let model else { return }

        for token in model.tokens {
            let lbl = NSTextField.boundedLabel(token.text, maxLines: 1, truncating: true)
            lbl.font      = .systemFont(ofSize: 11)
            lbl.textColor = tokenColor(token.state)
            stack.addArrangedSubview(lbl)
        }

        if let cycleLabel = model.cycleLabel {
            let sep = NSTextField(labelWithString: "·")
            sep.font      = .systemFont(ofSize: 11)
            sep.textColor = Theme.fgMuted
            stack.addArrangedSubview(sep)

            let cLbl = NSTextField.boundedLabel(cycleLabel, maxLines: 1, truncating: true)
            cLbl.font      = .systemFont(ofSize: 10)
            cLbl.textColor = Theme.fgMuted
            stack.addArrangedSubview(cLbl)
        }
    }

    private func tokenColor(_ state: JobPhaseState) -> NSColor {
        switch state {
        case .running:   return Theme.amber
        case .completed: return Theme.sage
        case .pending:   return Theme.fgMuted
        }
    }
}

// MARK: - MotherJobDetail

/// The job detail's scroll document: flipped, so its top stays put as its content grows and
/// the scroll position (measured from the top) survives updates.
final class DetailDocumentView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class MotherJobDetail: NSView {

    /// Everything the detail needs from the app. `AppStore` is the real host; tests pass a stub.
    let host: MotherJobDetailHost
    private let logDirectory: URL

    private(set) var currentJobId: String?

    /// The crew panel's colors: the Mother panel's own `Theme` palette, every one at least
    /// 4.5:1 against `Theme.bg` (a test computes it), and none of them dimmed when the window is inactive.
    static let crewColors = MotherCrewPanelColors(
        text: Color(nsColor: Theme.fg), muted: Color(nsColor: Theme.fgMuted),
        good: Color(nsColor: Theme.sage), warn: Color(nsColor: Theme.amber),
        bad: Color(nsColor: Theme.redSweater)
    )

    // Stored once, toggled via isHidden
    private let emptyLabel = NSTextField(labelWithString: "Select a job")

    /// Scrolls the Overview: everything but the title, the switch and the log. Its document is `content`,
    /// pinned to the clip's width.
    let contentScrollView = NSScrollView()
    private let content = DetailDocumentView()

    /// The three views of a job, chosen with the switch under the title.
    enum Segment: Int, CaseIterable {
        case overview, plan, log

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .plan:     return "Plan"
            case .log:      return "Log"
            }
        }
    }

    /// Overview · Plan · Log. The Plan segment exists only while the job has a plan path.
    let segmentControl = JobViewSwitch()
    /// The segment on show. Per detail (so per job tab): `select` starts at Overview, `update` never changes it.
    private(set) var selectedSegment: Segment = .overview
    /// New log lines arrived while another segment was showing; cleared by showing the Log.
    private(set) var logHasUnseenLines = false
    /// The plan, rendered in place. Built the first time the Plan segment is chosen.
    private(set) var planView: PlanDocumentView?
    /// Makes the plan view's file loader (tests replace it to drive the watcher by hand).
    var makePlanFileLoader: () -> PlanFileLoader = { PlanFileLoader() }
    /// Makes the Overview checklist's file loader (tests replace it). It watches the plan file while the
    /// Overview is on show, as the plan view's does while the Plan is.
    var makeChecklistFileLoader: () -> PlanFileLoader = { PlanFileLoader() }

    /// Top-down, like the scroll document inside it (an existing test reads `isFlipped` to find a top edge).
    override var isFlipped: Bool { true }

    /// What the reader is looking at: the views from the outermost one at the top of the viewport
    /// down to the innermost, each with the offset of its top edge from the viewport's top edge when
    /// the reader last scrolled. Weak: a view that is rebuilt (a todo row, an action button) simply
    /// stops counting, and the nearest surviving ancestor stands in for it.
    private struct ScrollAnchor {
        struct Entry { weak var view: NSView?; let offset: CGFloat }
        var chain: [Entry] = []
    }
    private var scrollAnchor = ScrollAnchor()
    /// An anchor was taken before a change and layout has not finished restoring it yet.
    private var placeHeld = false
    /// Layout ran at least once since the anchor was taken.
    private var placeLaidOut = false
    private var placeChecks = 0
    private var placeRecheckScheduled = false

    // Content fields
    private let titleLabel      = EdgePinnedLabel(wrappingLabelWithString: "")
    private let stateLabel      = NSTextField.boundedLabel("", maxLines: 1, truncating: true)
    private let phaseRibbonView = PhaseRibbonView()
    private var ribbonHeight:   NSLayoutConstraint!
    /// Gates, lens rows, progress and the hold banner (hidden at zero height without crew data).
    let crewSection = MotherCrewSectionView()
    private var crewTopGap:     NSLayoutConstraint!
    /// Live todo list for running/awaiting jobs — hidden when no peek data.
    private let todoStack       = NSStackView()
    private var todoHeight:     NSLayoutConstraint!
    private let metaStack       = NSStackView()
    let actionsContainer = NSView()  // rebuilt only when `actionIdentity` changes
    /// The stack currently inside `actionsContainer`; a stable object while the identity holds.
    private(set) var actionStack: NSStackView?
    private var actionIdentity: ActionIdentity?
    let logScrollView   = NSScrollView()
    let logTextView     = NSTextView()

    // Action widgets (created once, shown/hidden as needed)
    private let brokerBanner     = NSTextField(labelWithString: "⚠ Mother broker offline")
    private let replyScrollView  = NSScrollView()
    let replyTextView            = GuidanceTextView()
    private let answerButton     = NSButton(title: "Answer",      target: nil, action: nil)
    private let cancelButton     = NSButton(title: "Cancel job",  target: nil, action: nil)
    private let retryButton      = NSButton(title: "Retry",       target: nil, action: nil)
    private let forceStartButton = NSButton(title: "Force-start", target: nil, action: nil)
    private let archiveButton    = NSButton(title: "Archive",     target: nil, action: nil)
    private let escalateButton   = NSButton(title: "Escalate",    target: nil, action: nil)
    private let actionErrorLabel = NSTextField.boundedLabel("", maxLines: 4)
    /// Shown under the guidance box when it is too long to send.
    private let guidanceHintLabel = NSTextField(labelWithString: "Guidance is longer than 4,000 characters.")
    /// The hold's option buttons by Mother's option id, while the detail is in option mode.
    private var optionButtons: [String: NSButton] = [:]
    private var optionConfirmButton: NSButton?
    /// Views in the action stack that must wrap at the stack's width (consequence lines).
    private var widthBoundViews: [NSView] = []
    /// Replace to play a person, a VoiceOver press, app-control or a QA run (tests).
    var gestureInputs = MotherGestureInputs()
    private let planSectionLabel  = NSTextField(labelWithString: "PLAN")
    private let planChecklistView = PlanChecklistView()

    private var logTimer:         Timer?
    private var actionErrorTimer: Timer?
    private var lastLogText:      String?
    private var shownMeta:        [MetaPair] = []
    private(set) var currentJob:  MotherJob?
    private var cancellables = Set<AnyCancellable>()

    /// What decides the shape of the action stack. Anything that changes it rebuilds the
    /// stack; everything else (progress, gates, a lens finishing) leaves it alone.
    struct ActionIdentity: Equatable {
        var state: String
        var brokerConnected: Bool
        var decisionId: String?
        var holdKind: String?
        /// Mother's options are buttons (the broker answers by option id).
        var optionMode: Bool
        /// The open decision's send state: a send, a confirm or a failure changes the buttons.
        var sendState: MotherDecisionSendState

        init(job: MotherJob, brokerConnected: Bool, optionMode: Bool = false, sendState: MotherDecisionSendState = .idle) {
            state = job.state
            self.optionMode = optionMode
            self.sendState = sendState
            self.brokerConnected = brokerConnected
            decisionId = job.crew.decision.flatMap { $0.isOpen ? $0.id : nil }
            holdKind = job.holdSummary?.kind
        }
    }

    init(host: MotherJobDetailHost,
         logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".mother/logs", isDirectory: true),
         frame: NSRect = .zero) {
        self.host = host
        self.logDirectory = logDirectory
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("MotherJobDetail is built in code") }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        appearance = NSAppearance(named: .darkAqua)

        titleLabel.font               = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor          = Theme.fg
        titleLabel.lineBreakMode      = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.isSelectable = false

        // Safety net: nothing inside the detail may demand more width than the pane gives it.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [todoStack, metaStack, planChecklistView, actionsContainer, phaseRibbonView, crewSection] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        stateLabel.font      = .systemFont(ofSize: 10, weight: .semibold)
        stateLabel.textColor = Theme.fgMuted

        metaStack.orientation = .vertical
        metaStack.spacing     = 4
        metaStack.alignment   = .leading

        // Actions container (variable height, rebuilt per job state)
        actionsContainer.translatesAutoresizingMaskIntoConstraints = false

        logTextView.isEditable         = false
        logTextView.isSelectable       = true
        logTextView.drawsBackground    = false
        logTextView.backgroundColor    = .clear
        logTextView.textContainerInset = NSSize(width: 6, height: 6)
        logTextView.font               = Theme.monoFont
        logTextView.isVerticallyResizable   = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask        = [.width]
        logTextView.textContainer?.widthTracksTextView = true

        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers  = true
        logScrollView.drawsBackground     = false
        logScrollView.wantsLayer          = true
        logScrollView.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        logScrollView.layer?.cornerRadius    = 4
        logScrollView.documentView = logTextView
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logScrollView)

        segmentControl.segmentStyle = .rounded
        segmentControl.trackingMode = .selectOne
        segmentControl.controlSize = .small
        segmentControl.target = self
        segmentControl.action = #selector(segmentChanged(_:))
        segmentControl.setAccessibilityLabel("Job view")
        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        segmentControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(segmentControl)
        rebuildSegmentControl()

        todoStack.orientation = .vertical
        todoStack.spacing     = 4
        todoStack.alignment   = .leading

        planSectionLabel.font      = .systemFont(ofSize: 9, weight: .semibold)
        planSectionLabel.textColor = Theme.fgMuted

        // Everything below the pane's edge lives in a flipped document view inside a vertical scroll
        // view. The content's height is whatever it is (a 200-item plan, a 2,000-character option
        // consequence); the pane's height is whatever the window gives it. Without the scroll view
        // the content's required vertical chain became the window's demand, and a window that cannot
        // grow (full screen) cut off its top.
        content.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.hasVerticalScroller   = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.autohidesScrollers    = true
        contentScrollView.drawsBackground       = false
        contentScrollView.borderType            = .noBorder
        contentScrollView.documentView          = content
        addSubview(contentScrollView)
        let clip = contentScrollView.contentView
        content.onLayout = { [weak self] in self?.contentDidLayout() }
        // A person scrolling (wheel, trackpad, scroller) is the reader choosing a new place: let go of
        // any anchor still waiting for layout to settle.
        NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification, object: contentScrollView)
            .sink { [weak self] _ in self?.placeHeld = false }
            .store(in: &cancellables)
        NSLayoutConstraint.activate([
            contentScrollView.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 10),
            contentScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The document is as wide as the clip (it never scrolls sideways) and as tall as its content.
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        // The title, the state and the switch stay put above whichever segment is showing.
        for v in [titleLabel, stateLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [phaseRibbonView, crewSection, actionsContainer, todoStack, metaStack,
                  planSectionLabel, planChecklistView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        // Ribbon height toggles between 0 (hidden) and 22 (visible)
        ribbonHeight = phaseRibbonView.heightAnchor.constraint(equalToConstant: 0)
        ribbonHeight.isActive = true

        // The gap above the crew section is 0 while it is empty, so a job without crew data
        // lays out exactly as it did before the section existed.
        crewTopGap = crewSection.topAnchor.constraint(equalTo: phaseRibbonView.bottomAnchor, constant: 0)
        crewTopGap.isActive = true
        crewSection.onDetails = { [weak self] in self?.showDetails() }
        crewSection.onAcknowledge = { [weak self] reason in self?.acknowledge(reason: reason) }

        // Todo stack height: 0 when empty, constrained by content otherwise
        todoHeight = todoStack.heightAnchor.constraint(equalToConstant: 0)
        todoHeight.isActive = true

        // Wire plan checklist visibility: show/hide section label in tandem
        planChecklistView.onItemsChanged = { [weak self] hasItems in
            self?.planSectionLabel.isHidden = !hasItems
        }
        // The plan loads off the main thread: what it changes above the log lands later than `update`.
        planChecklistView.onWillChange = { [weak self] in self?.holdReaderPlace() }
        planChecklistView.makeLoader = { [weak self] in self?.makeChecklistFileLoader() ?? PlanFileLoader() }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // A fitting-size pass would otherwise take the label's full text width for the pane's.
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            stateLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),

            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            // The switch: right under the state line, never wider than the pane.
            segmentControl.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8),
            segmentControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            segmentControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            // The log fills the area under the switch while it is the segment on show.
            logScrollView.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 10),
            logScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            logScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            logScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            // Phase ribbon — the top of the Overview; height is 0 when hidden
            phaseRibbonView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            phaseRibbonView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            phaseRibbonView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Crew section — between the ribbon and the actions; zero height without crew data
            crewSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            crewSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Actions container — below the crew section (which is zero height, so directly
            // below the phase ribbon, when the job has no crew data)
            actionsContainer.topAnchor.constraint(equalTo: crewSection.bottomAnchor, constant: 8),
            actionsContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            actionsContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Todo stack — below actions, above meta rows
            todoStack.topAnchor.constraint(equalTo: actionsContainer.bottomAnchor, constant: 8),
            todoStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            todoStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            metaStack.topAnchor.constraint(equalTo: todoStack.bottomAnchor, constant: 8),
            metaStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            metaStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Plan checklist section — the end of the Overview
            planSectionLabel.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 12),
            planSectionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            planChecklistView.topAnchor.constraint(equalTo: planSectionLabel.bottomAnchor, constant: 6),
            planChecklistView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            planChecklistView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            planChecklistView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        // Configure action widgets
        configureActionWidgets()

        // Empty hint (higher Z-order than logScrollView, shown when no selection)
        emptyLabel.font      = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.fgMuted
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        showEmpty()

        // Observe broker connection state for button enable/disable
        host.brokerConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.updateBrokerBanner(connected) }
            .store(in: &cancellables)

        // A send state or a capability changed (hello after the pane was built, a click, an answer).
        // Delivered on the main thread, so no hop: the buttons follow the change at once.
        host.motherDecisionChangesPublisher
            .sink { [weak self] _ in self?.hostDecisionStateChanged() }
            .store(in: &cancellables)

        // Typing in the guidance box enables or disables the option buttons.
        NotificationCenter.default.publisher(for: NSText.didChangeNotification, object: replyTextView)
            .sink { [weak self] _ in self?.updateOptionButtonStates() }
            .store(in: &cancellables)

        // Observe action errors from AppStore
        host.motherActionErrorPublisher
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] msg in self?.showActionError(msg) }
            .store(in: &cancellables)

        // Observe live peek snapshots to update the todo list
        host.motherPeeksPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peeks in
                guard let self, let jobId = self.currentJobId else { return }
                self.holdReaderPlace()
                self.updateTodoList(peeks[jobId])
            }
            .store(in: &cancellables)
    }

    private func configureActionWidgets() {
        // Broker offline banner
        brokerBanner.font      = .systemFont(ofSize: 10)
        brokerBanner.textColor = Theme.amber
        brokerBanner.isHidden  = true

        // Reply text view (multi-line, ~3 lines tall)
        replyTextView.isEditable         = true
        replyTextView.isSelectable       = true
        replyTextView.drawsBackground    = false
        replyTextView.backgroundColor    = .clear
        replyTextView.textContainerInset = NSSize(width: 4, height: 4)
        replyTextView.font               = Theme.monoFont
        replyTextView.textColor          = Theme.fg

        replyScrollView.hasVerticalScroller   = true
        replyScrollView.autohidesScrollers    = true
        replyScrollView.drawsBackground       = true
        replyScrollView.backgroundColor       = NSColor(white: 0.10, alpha: 1)
        replyScrollView.wantsLayer            = true
        replyScrollView.layer?.cornerRadius   = 4
        replyScrollView.layer?.borderColor    = Theme.borderInactive.cgColor
        replyScrollView.layer?.borderWidth    = 1
        // The standard document-view setup, so the box fills the scroll view (a click anywhere in it
        // lands in the text) and wraps at its width.
        replyTextView.minSize                 = NSSize(width: 0, height: 52)
        replyTextView.isVerticallyResizable   = true
        replyTextView.isHorizontallyResizable = false
        replyTextView.autoresizingMask        = [.width]
        replyTextView.textContainer?.widthTracksTextView = true
        replyScrollView.documentView          = replyTextView

        // Buttons
        for btn in [answerButton, cancelButton, retryButton,
                    forceStartButton, archiveButton] {
            btn.bezelStyle  = .rounded
            btn.isBordered  = true
            btn.font        = .systemFont(ofSize: 11)
        }
        answerButton.target     = self
        answerButton.action     = #selector(didTapAnswer(_:))
        cancelButton.target     = self
        cancelButton.action     = #selector(didTapCancel)
        retryButton.target      = self
        retryButton.action      = #selector(didTapRetry)
        forceStartButton.target = self
        forceStartButton.action = #selector(didForceStart)
        archiveButton.target    = self
        archiveButton.action    = #selector(didArchive)
        escalateButton.target   = self
        escalateButton.action   = #selector(didEscalate)
        escalateButton.toolTip  = "Re-run this failed job on the next model tier (costs more)"

        // Semantic color coding via contentTintColor
        cancelButton.contentTintColor     = Theme.redSweater
        retryButton.contentTintColor      = Theme.sage
        forceStartButton.contentTintColor = Theme.amber
        archiveButton.contentTintColor    = Theme.fgMuted
        answerButton.contentTintColor     = Theme.sage

        guidanceHintLabel.font      = .systemFont(ofSize: 10)
        guidanceHintLabel.textColor = Theme.amber
        guidanceHintLabel.isHidden  = true

        // Error label (shown inline below buttons, auto-clears)
        actionErrorLabel.font      = .systemFont(ofSize: 10)
        actionErrorLabel.textColor = Theme.redSweater
        actionErrorLabel.lineBreakMode      = .byWordWrapping
        actionErrorLabel.maximumNumberOfLines = 3
        actionErrorLabel.isHidden  = true
    }

    // MARK: Public

    /// Show `job` as the pane's subject: a different job than the one shown, or none (nil).
    /// Starts from a clean slate: the reply draft is cleared and everything is rebuilt.
    func select(_ job: MotherJob?) {
        // An override confirmation left armed from an earlier visit does not wait for the next click.
        if let job, let decision = job.crew.decision, decision.isOpen,
           case .confirming = host.motherDecisionState(jobId: job.id, decisionId: decision.id) {
            host.cancelMotherDecisionConfirm(jobId: job.id, decisionId: decision.id)
        }
        logTimer?.invalidate(); logTimer = nil
        currentJob   = job
        currentJobId = job?.id
        scrollContentToTop()
        replyTextView.string = ""
        lastLogText = nil
        logHasUnseenLines = false
        // A new job starts on the Overview, a job that needs you included.
        selectedSegment = .overview
        crewSection.collapseBreakdown()

        guard let job else {
            actionIdentity = nil
            actionStack = nil
            showEmpty()
            return
        }

        [titleLabel, stateLabel, segmentControl, todoStack, metaStack, actionsContainer,
         planSectionLabel, planChecklistView].forEach { $0.isHidden = false }
        emptyLabel.isHidden = true
        planView?.show(planPath: job.planPath)
        planChecklistView.show(planPath: job.planPath)
        rebuildSegmentControl()
        showSelectedSegment()

        titleLabel.stringValue = job.title.isEmpty ? job.id : job.title
        stateLabel.stringValue = job.state.uppercased()
        stateLabel.textColor   = stateColor(job.state)

        updateRibbon(job)
        updateCrewSection(job)
        updateTodoList(host.peek(for: job.id))
        shownMeta = metaPairs(for: job)
        rebuildMeta(shownMeta)
        rebuildActions(job)
        loadLog(job)
        syncLogTimer(for: job)
    }

    /// The same job again, with new data (a progress tick, a gate result, a state change).
    /// Applies only what changed and never disturbs what the reader is doing: the reply
    /// draft, its selection and first responder, the log's scroll position, the log timer.
    /// A different job (or none) is a `select`.
    func update(_ job: MotherJob?) {
        guard let job, let previous = currentJob, previous.id == job.id else {
            select(job)
            return
        }
        holdReaderPlace()
        currentJob = job

        if job.title != previous.title {
            titleLabel.stringValue = job.title.isEmpty ? job.id : job.title
        }
        if job.state != previous.state {
            stateLabel.stringValue = job.state.uppercased()
            stateLabel.textColor   = stateColor(job.state)
            // The answer box goes with the awaiting state; a stale draft must not come back with the next one.
            if previous.state == "awaiting" { replyTextView.string = "" }
            updateTodoList(host.peek(for: job.id))
        }
        if job.phases != previous.phases || job.cycles != previous.cycles {
            updateRibbon(job)
        }
        // Guidance written for one hold must not ride along to the next one.
        if let oldDecision = previous.crew.decision, oldDecision.isOpen, oldDecision.id != job.crew.decision?.id {
            replyTextView.string = ""
        }
        updateCrewSection(job)

        let pairs = metaPairs(for: job)
        if pairs != shownMeta {
            shownMeta = pairs
            rebuildMeta(pairs)
        }

        if makeActionIdentity(for: job) != actionIdentity { rebuildActions(job) }

        if job.planPath != previous.planPath {
            planChecklistView.show(planPath: job.planPath)
            planView?.show(planPath: job.planPath)
            // The Plan segment goes with the path.
            if (job.planPath ?? "").isEmpty, selectedSegment == .plan { selectedSegment = .overview }
            rebuildSegmentControl()
            showSelectedSegment()
        }

        if job.state != previous.state {
            syncLogTimer(for: job)
            if !Self.isActive(job.state) { loadLog(job) }   // the log's last lines
        }
    }

    /// Show `segment`, if the job has it (Plan needs a plan path). A person's choice or the keyboard's:
    /// the switch itself calls this.
    func selectSegment(_ segment: Segment) {
        guard currentJob != nil, visibleSegments.contains(segment) else { return }
        selectedSegment = segment
        if segment == .log { logHasUnseenLines = false }
        rebuildSegmentControl()
        showSelectedSegment()
    }

    /// The segments the job has, in order.
    var visibleSegments: [Segment] {
        hasPlan ? [.overview, .plan, .log] : [.overview, .log]
    }

    /// The text of a segment's label on the switch (the Log carries a dot while it has unseen lines).
    func segmentLabel(_ segment: Segment) -> String? {
        guard let index = visibleSegments.firstIndex(of: segment) else { return nil }
        return segmentControl.label(forSegment: index)
    }

    // MARK: Private

    private var hasPlan: Bool { !(currentJob?.planPath ?? "").isEmpty }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let segments = visibleSegments
        guard sender.selectedSegment >= 0, sender.selectedSegment < segments.count else { return }
        selectSegment(segments[sender.selectedSegment])
    }

    /// Labels and selection of the switch from `visibleSegments`, `selectedSegment` and the log dot.
    private func rebuildSegmentControl() {
        let segments = visibleSegments
        if segmentControl.segmentCount != segments.count { segmentControl.segmentCount = segments.count }
        for (i, segment) in segments.enumerated() {
            let dotted = segment == .log && logHasUnseenLines
            segmentControl.setLabel(dotted ? "Log \u{2022}" : segment.title, forSegment: i)
            segmentControl.setWidth(0, forSegment: i)
            segmentControl.setToolTip(dotted ? "New log lines" : nil, forSegment: i)
        }
        segmentControl.selectedSegment = segments.firstIndex(of: selectedSegment) ?? 0
        applySegmentAccessibility(segments)
    }

    /// What a screen reader says for `segment`: "Log, new lines", not "Log bullet".
    func segmentAccessibilityLabel(_ segment: Segment) -> String? {
        guard visibleSegments.contains(segment) else { return nil }
        return segment == .log && logHasUnseenLines ? "Log, new lines" : segment.title
    }

    private func applySegmentAccessibility(_ segments: [Segment]) {
        segmentControl.spokenLabels = segments.map { segmentAccessibilityLabel($0) ?? $0.title }
    }

    /// Only the selected segment is on show; the others are hidden. The plan view reads and watches
    /// its file only while it is the one on show.
    private func showSelectedSegment() {
        guard currentJob != nil else { return }
        contentScrollView.isHidden = selectedSegment != .overview
        logScrollView.isHidden = selectedSegment != .log
        if selectedSegment == .plan { ensurePlanView().isHidden = false } else { planView?.isHidden = true }
        planView?.setActive(selectedSegment == .plan)
        planChecklistView.setActive(selectedSegment == .overview)
    }

    private func ensurePlanView() -> PlanDocumentView {
        if let planView { return planView }
        let view = PlanDocumentView(loader: makePlanFileLoader(),
                                     actions: PlanViewActions(openPlan: { [weak host] in host?.openPlan(path: $0) }))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 10),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        view.show(planPath: currentJob?.planPath)
        planView = view
        return view
    }

    /// A new subject starts at the top. Updates to the same job never call this: they keep what the
    /// reader is looking at where it is (`holdReaderPlace`).
    private func scrollContentToTop() {
        let clip = contentScrollView.contentView
        if clip.bounds.origin != .zero {
            clip.scroll(to: .zero)
            contentScrollView.reflectScrolledClipView(clip)
        }
        // Nothing of the previous job is a place to hold on to.
        scrollAnchor = ScrollAnchor()
        placeHeld = false
    }

    /// Call right BEFORE anything that can change the height of what is above the reader (a todo
    /// list, the crew panel, the actions, a banner, the plan). Takes the anchor from what is on
    /// screen now; layout then puts it back where it was (`contentDidLayout`), however much the
    /// content above grew or shrank, for as long as it takes layout to settle.
    ///
    /// The anchor is taken here and not on every scroll: while a pass is half done AppKit itself
    /// moves the clip (a document that is briefly too short), and that is not the reader's place.
    private func holdReaderPlace() {
        recordScrollAnchor()
        placeHeld = true
        placeLaidOut = false
        placeChecks = 0
        schedulePlaceRecheck()
    }

    /// After a layout pass: put what the reader was looking at back where it was, and never let the
    /// position leave the document or go sideways.
    private func contentDidLayout() {
        if placeHeld {
            restoreScrollAnchor()
            placeLaidOut = true
        }
        clampContentScroll()
    }

    /// A stack lays its rows out after this view does, so look again once layout is done; let go
    /// of the anchor after that (a later layout, such as a window resize, is not an update).
    private func schedulePlaceRecheck() {
        guard !placeRecheckScheduled else { return }
        placeRecheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placeRecheckScheduled = false
            guard self.placeHeld else { return }
            self.restoreScrollAnchor()
            self.clampContentScroll()
            self.placeChecks += 1
            if self.placeLaidOut || self.placeChecks >= 5 {
                self.placeHeld = false
            } else {
                self.schedulePlaceRecheck()
            }
        }
    }

    /// Top edge of `view` in the document's coordinates, measured from the top of the viewport.
    private func offsetFromViewportTop(_ view: NSView) -> CGFloat {
        content.convert(view.bounds, from: view).minY - contentScrollView.contentView.bounds.minY
    }

    /// Take the anchor: from the document down, the first visible child that reaches the viewport's
    /// top edge, and again inside it, until a leaf (a nested scroll view counts as one).
    private func recordScrollAnchor() {
        let clip = contentScrollView.contentView
        var chain: [ScrollAnchor.Entry] = []
        let top = clip.bounds.minY
        var node: NSView = content
        while clip.bounds.height > 0, !content.isHidden {
            let reaching = node.subviews
                .filter { !$0.isHidden && $0.frame.height > 0 }
                .map { ($0, content.convert($0.bounds, from: $0)) }
                .filter { $0.1.maxY > top }
            guard let first = reaching.min(by: { $0.1.minY < $1.1.minY })?.0 else { break }
            chain.append(.init(view: first, offset: offsetFromViewportTop(first)))
            if first is NSScrollView { break }
            node = first
        }
        scrollAnchor = ScrollAnchor(chain: chain)
    }

    /// Scroll so the innermost anchored view that still exists sits at its recorded offset from the
    /// viewport's top. If none does (the whole section was rebuilt away), the clamp is all that applies.
    private func restoreScrollAnchor() {
        let clip = contentScrollView.contentView
        guard clip.bounds.height > 0,
              let entry = scrollAnchor.chain.last(where: {
                  guard let view = $0.view else { return false }
                  return view.isDescendant(of: content) && !view.isHiddenOrHasHiddenAncestor
              }),
              let view = entry.view
        else { return }
        let delta = offsetFromViewportTop(view) - entry.offset
        guard abs(delta) > 0.5 else { return }
        let maxY = max(0, content.frame.height - clip.bounds.height)
        let y = min(max(clip.bounds.origin.y + delta, 0), maxY)
        guard y != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        contentScrollView.reflectScrolledClipView(clip)
    }

    /// The position stays inside the document (content shrinking under a reader who had scrolled
    /// down), and never sideways.
    private func clampContentScroll() {
        let clip = contentScrollView.contentView
        guard let doc = contentScrollView.documentView else { return }
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let y = min(max(clip.bounds.origin.y, 0), maxY)
        guard y != clip.bounds.origin.y || clip.bounds.origin.x != 0 else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        contentScrollView.reflectScrolledClipView(clip)
    }

    private func showEmpty() {
        [titleLabel, stateLabel, segmentControl, phaseRibbonView, crewSection, todoStack, metaStack, actionsContainer,
         planSectionLabel, planChecklistView, contentScrollView, logScrollView].forEach { $0.isHidden = true }
        planView?.clear()
        planView?.isHidden = true
        emptyLabel.isHidden = false
        planChecklistView.show(planPath: nil)
        crewSection.update(model: MotherCrewPanelModel(), detailsAvailable: false)
        crewTopGap.constant = 0
        shownMeta = []
    }

    private func updateRibbon(_ job: MotherJob) {
        let model = job.phaseRibbonModel
        phaseRibbonView.update(model)
        if model != nil {
            phaseRibbonView.isHidden = false
            ribbonHeight.constant    = 22
        } else {
            phaseRibbonView.isHidden = true
            ribbonHeight.constant    = 0
        }
    }

    /// Active states keep the log live.
    private static func isActive(_ state: String) -> Bool { state == "running" || state == "awaiting" }

    private func syncLogTimer(for job: MotherJob) {
        if Self.isActive(job.state) {
            guard logTimer == nil else { return }
            logTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self, let j = self.currentJob else { return }
                self.loadLog(j)
            }
        } else {
            logTimer?.invalidate(); logTimer = nil
        }
    }

    /// Push the job's crew data into the section. Its height changes only when the row
    /// structure does; a value changing in place keeps its frame.
    private func updateCrewSection(_ job: MotherJob) {
        // In option mode the options are buttons below, so the panel keeps only the hold's header.
        let model = MotherCrewPanelModel.make(job: job.kitJob, showsHoldOptions: optionDecision(for: job) == nil)
        crewSection.update(model: model, detailsAvailable: model.hasDetails && host.usesDefaultBroker,
                           acknowledgeAvailable: host.supportsAck)
        crewTopGap.constant = model.isEmpty ? 0 : 8
    }

    /// The open decision whose options are offered as buttons: the broker answers by option id
    /// and the job is held with options to choose from. Nil otherwise (the text answer stands).
    private func optionDecision(for job: MotherJob) -> MotherDecision? {
        guard host.supportsAnswerOption, job.state == "awaiting",
              let decision = job.crew.decision, decision.isOpen, !decision.options.isEmpty
        else { return nil }
        return decision
    }

    private func makeActionIdentity(for job: MotherJob) -> ActionIdentity {
        let decision = optionDecision(for: job)
        let sendState = decision.map { host.motherDecisionState(jobId: job.id, decisionId: $0.id) } ?? .idle
        return ActionIdentity(job: job, brokerConnected: host.brokerConnected,
                              optionMode: decision != nil, sendState: sendState)
    }

    /// The host's send state or capabilities changed: bring the panel and the buttons along.
    private func hostDecisionStateChanged() {
        guard let job = currentJob else { return }
        holdReaderPlace()
        updateCrewSection(job)
        if makeActionIdentity(for: job) != actionIdentity { rebuildActions(job) }
    }

    /// Rebuild the todo list rows from the latest peek payload.
    /// Passing nil (or a payload with no todos) collapses the stack to zero height.
    private func updateTodoList(_ payload: MotherPeekPayload?) {
        todoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let todos = payload?.todos, !todos.isEmpty,
              let state = currentJob?.state,
              state == "running" || state == "awaiting"
        else {
            // Collapse: re-activate the zero-height constraint.
            todoHeight.isActive = true
            return
        }

        for todo in todos {
            let row = todoRow(todo)
            todoStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: todoStack.widthAnchor).isActive = true
        }

        // Let Auto Layout size the stack by its content.
        todoHeight.isActive = false
    }

    private func todoRow(_ todo: MotherPeekItem) -> NSView {
        let icon = NSTextField(labelWithString: todoIcon(todo.status))
        icon.font      = .systemFont(ofSize: 11)
        icon.textColor = todoIconColor(todo.status)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let lbl = NSTextField.boundedLabel(todo.content)
        lbl.font          = .systemFont(ofSize: 11)
        lbl.lineBreakMode = .byWordWrapping
        lbl.maximumNumberOfLines = 3
        if todo.status == "completed" {
            lbl.textColor = Theme.fgMuted
            // Strikethrough via attributed string
            let attrs: [NSAttributedString.Key: Any] = [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: Theme.fgMuted,
                .font: NSFont.systemFont(ofSize: 11),
            ]
            lbl.attributedStringValue = NSAttributedString(string: todo.content, attributes: attrs)
        } else {
            lbl.textColor = Theme.fg
        }

        let row = NSStackView(views: [icon, lbl])
        row.orientation = .horizontal
        row.spacing     = 5
        row.alignment   = .firstBaseline
        return row
    }

    private func todoIcon(_ status: String) -> String {
        switch status {
        case "completed":   return "✓"
        case "in_progress": return "⟳"
        default:            return "○"
        }
    }

    private func todoIconColor(_ status: String) -> NSColor {
        switch status {
        case "completed":   return Theme.sage
        case "in_progress": return Theme.amber
        default:            return Theme.fgMuted
        }
    }

    private func rebuildActions(_ job: MotherJob) {
        let connected = host.brokerConnected
        actionIdentity = makeActionIdentity(for: job)
        actionStack = nil
        optionButtons = [:]
        optionConfirmButton = nil
        widthBoundViews = []
        replyTextView.placeholder = nil
        replyTextView.setAccessibilityLabel(nil)
        var confirmRow: NSView?

        // The reply box is re-parented by a rebuild; the draft and its selection live in the
        // text view and survive, but focus does not unless it is put back.
        let replyHadFocus = window?.firstResponder === replyTextView

        // Remove all existing subviews and constraints from the container
        actionsContainer.subviews.forEach { $0.removeFromSuperview() }
        defer {
            if replyHadFocus, replyTextView.window != nil { window?.makeFirstResponder(replyTextView) }
        }

        // Build the stack of widgets for this state
        var widgets: [NSView] = []

        if !connected {
            brokerBanner.isHidden = false
            widgets.append(brokerBanner)
        } else {
            brokerBanner.isHidden = true
        }

        switch job.state {
        case "awaiting":
            if let decision = optionDecision(for: job) {
                let built = optionWidgets(job: job, decision: decision)
                widgets.append(contentsOf: built.widgets)
                confirmRow = built.confirmRow
            } else {
                replyScrollView.translatesAutoresizingMaskIntoConstraints = false
                widgets.append(replyScrollView)

                let btnRow = NSStackView(views: [answerButton, cancelButton])
                btnRow.orientation = .horizontal
                btnRow.spacing     = 8
                btnRow.translatesAutoresizingMaskIntoConstraints = false
                widgets.append(btnRow)
            }

        case "running", "queued", "ready":
            let btnRow = NSStackView(views: [cancelButton, forceStartButton])
            btnRow.orientation = .horizontal
            btnRow.spacing     = 8
            btnRow.translatesAutoresizingMaskIntoConstraints = false
            widgets.append(btnRow)

        case "failed", "cancelled":
            // Escalate only makes sense for a failure; a cancelled job was stopped on purpose.
            let btnRow = NSStackView(views: job.state == "failed"
                ? [retryButton, escalateButton, archiveButton]
                : [retryButton, archiveButton])
            btnRow.orientation = .horizontal
            btnRow.spacing     = 8
            btnRow.translatesAutoresizingMaskIntoConstraints = false
            widgets.append(btnRow)

        case "succeeded":
            widgets.append(archiveButton)

        default:
            break
        }

        widgets.append(actionErrorLabel)

        // Disable action buttons when broker is offline
        for btn in [answerButton, cancelButton, retryButton,
                    forceStartButton, archiveButton, escalateButton] {
            btn.isEnabled = connected
        }
        escalateButton.isEnabled = true   // goes through the CLI, not the broker
        // Archive doesn't require the broker — always enabled
        archiveButton.isEnabled  = true

        guard !widgets.filter({ $0 !== actionErrorLabel || !$0.isHidden }).isEmpty else { return }

        // Stack widgets vertically inside actionsContainer
        let stack = NSStackView(views: widgets)
        actionStack = stack
        stack.orientation = .vertical
        stack.spacing     = 8
        stack.alignment   = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: actionsContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: actionsContainer.bottomAnchor),
        ])

        // Fix the reply scroll view height (~3 lines) when it is in the stack
        if replyScrollView.superview === stack {
            replyScrollView.translatesAutoresizingMaskIntoConstraints = false
            replyScrollView.heightAnchor.constraint(equalToConstant: 60).isActive = true
            replyScrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            replyScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        // Data-driven lines (the action error, the "Sent" line) fill the stack and wrap in it.
        for case let label as BoundedLabel in widgets {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Consequence lines wrap at the stack's width instead of growing past it.
        for view in widthBoundViews {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        updateOptionButtonStates()
        if let confirmRow {
            // A screen reader hears the confirm question the moment it appears.
            DispatchQueue.main.async { NSAccessibility.post(element: confirmRow, notification: .layoutChanged) }
        }

        // Separator line above actions (added before stack so it renders behind it)
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Theme.borderInactive.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.addSubview(sep, positioned: .below, relativeTo: stack)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: actionsContainer.topAnchor),
            sep.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: Hold options

    /// The widgets of a held job's decision: the guidance box (when an option takes text), then
    /// one button per option in Mother's order, each with its consequence visible under it.
    /// After a send, one line says what was sent. Nothing here has a key equivalent.
    private func optionWidgets(job: MotherJob, decision: MotherDecision) -> (widgets: [NSView], confirmRow: NSView?) {
        let state = host.motherDecisionState(jobId: job.id, decisionId: decision.id)

        if case .sent(let sent) = state {
            replyTextView.string = ""
            let label = decision.options.first { $0.id == sent }?.label ?? sent.raw
            let line = NSTextField.boundedLabel("Sent: \(label)", maxLines: 2)
            line.font = .systemFont(ofSize: 11, weight: .medium)
            line.textColor = Theme.sage
            return ([line], nil)
        }

        var widgets: [NSView] = []
        var confirmRow: NSView?

        if decision.options.contains(where: \.takesText) {
            replyTextView.placeholder = "Guidance for the worker (required)"
            replyTextView.setAccessibilityLabel("Guidance for the worker")
            replyScrollView.translatesAutoresizingMaskIntoConstraints = false
            widgets.append(replyScrollView)
            widgets.append(guidanceHintLabel)
        }

        for option in decision.options {
            let button = NSButton(title: option.label, target: self, action: #selector(didTapOption(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(Self.optionIdentifierPrefix + option.id.raw)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = Self.tint(for: option.id)
            button.setAccessibilityLabel(option.consequence.isEmpty ? option.label : "\(option.label). \(option.consequence)")
            optionButtons[option.id.raw] = button

            var top: [NSView] = [button]
            if case .sending(let chosen) = state, chosen == option.id {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isIndeterminate = true
                spinner.setAccessibilityLabel("Sending")
                spinner.startAnimation(nil)
                top.append(spinner)
            }
            let buttonRow = NSStackView(views: top)
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 6
            buttonRow.alignment = .centerY

            var rowViews: [NSView] = [buttonRow]
            if !option.consequence.isEmpty {
                let consequence = NSTextField(wrappingLabelWithString: option.consequence)
                consequence.font = .systemFont(ofSize: 10)
                consequence.textColor = Theme.fgMuted
                consequence.lineBreakMode = .byWordWrapping
                consequence.maximumNumberOfLines = 0
                consequence.isSelectable = true
                consequence.setAccessibilityElement(false)   // the button's label already says it
                consequence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                widthBoundViews.append(consequence)
                rowViews.append(consequence)
            }
            let row = NSStackView(views: rowViews)
            row.orientation = .vertical
            row.spacing = 2
            row.alignment = .leading
            widgets.append(row)

            if option.id == .overrideOpen, case .confirming(.overrideOpen) = state {
                let confirm = overrideConfirmRow()
                widgets.append(confirm)
                confirmRow = confirm
            }
        }
        return (widgets, confirmRow)
    }

    /// The second step of "open anyway": a question and two buttons, inline.
    private func overrideConfirmRow() -> NSView {
        let question = NSTextField(wrappingLabelWithString: "Open the PR for review with red gates recorded as overridden?")
        question.font = .systemFont(ofSize: 11, weight: .medium)
        question.textColor = Theme.amber
        question.maximumNumberOfLines = 0
        question.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        widthBoundViews.append(question)

        let confirm = NSButton(title: "Open PR anyway", target: self, action: #selector(didConfirmOverride(_:)))
        confirm.identifier = NSUserInterfaceItemIdentifier(Self.optionIdentifierPrefix + "confirm")
        confirm.bezelStyle = .rounded
        confirm.font = .systemFont(ofSize: 11)
        confirm.contentTintColor = Theme.redSweater
        let back = NSButton(title: "Back", target: self, action: #selector(didBackFromConfirm(_:)))
        back.identifier = NSUserInterfaceItemIdentifier(Self.optionIdentifierPrefix + "back")
        back.bezelStyle = .rounded
        back.font = .systemFont(ofSize: 11)
        optionConfirmButton = confirm

        let buttons = NSStackView(views: [confirm, back])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let row = NSStackView(views: [question, buttons])
        row.orientation = .vertical
        row.spacing = 6
        row.alignment = .leading
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Confirm: open the PR for review with red gates recorded as overridden")
        return row
    }

    private static let optionIdentifierPrefix = "mother.option."

    private static func tint(for option: MotherDecisionOptionID) -> NSColor {
        switch option {
        case .resumeWithGuidance: return Theme.sage
        case .escalate:           return Theme.amber
        case .overrideOpen:       return Theme.redSweater
        case .cancel, .unknown:   return Theme.fgMuted
        }
    }

    /// Enable each option button for what can be sent now: the broker is there, no send is
    /// under way or done, and guidance (for an option that takes it) is present and not too long.
    private func updateOptionButtonStates() {
        guard let job = currentJob, let decision = optionDecision(for: job) else { return }
        let state = host.motherDecisionState(jobId: job.id, decisionId: decision.id)
        let idle: Bool
        switch state {
        case .sending, .sent: idle = false
        default:              idle = true
        }
        let ready = host.brokerConnected && idle
        let text = replyTextView.string
        for option in decision.options {
            guard let button = optionButtons[option.id.raw] else { continue }
            button.isEnabled = ready && (!option.takesText || MotherDecisionStore.textIsSendable(text))
        }
        optionConfirmButton?.isEnabled = ready
        let tooLong = text.trimmingCharacters(in: .whitespacesAndNewlines).count > MotherDecisionStore.maxTextLength
        guidanceHintLabel.isHidden = !tooLong
    }

    private func updateBrokerBanner(_ connected: Bool) {
        guard currentJob != nil else { return }
        holdReaderPlace()
        brokerBanner.isHidden = connected
        for btn in [answerButton, cancelButton, retryButton, forceStartButton] {
            btn.isEnabled = connected
        }
        updateOptionButtonStates()
        // Archive doesn't use the broker — always enabled
        archiveButton.isEnabled  = true
    }

    private func showActionError(_ message: String) {
        holdReaderPlace()
        actionErrorLabel.stringValue = message
        actionErrorLabel.isHidden    = false
        actionErrorTimer?.invalidate()
        actionErrorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.holdReaderPlace()
            self?.actionErrorLabel.isHidden = true
            self?.actionErrorLabel.stringValue = ""
            self?.host.clearMotherActionError()
        }
    }

    // MARK: - Button actions

    // Nothing that answers Mother or acknowledges a flag runs unless a person did it:
    // app-control, synthetic and stale input, and an Accessibility press without VoiceOver,
    // are refused (`HumanGesture.permit`, called first in each action below).

    /// Log a refused gesture by its reason only; the refusal shows nothing to the user.
    private func logRefused(_ verdict: HumanGestureVerdict, _ what: String) {
        if case .refused(let reason) = verdict {
            log.info("\(what, privacy: .public) refused: \(reason.rawValue, privacy: .public)")
        }
    }

    @objc private func didTapAnswer(_ sender: NSButton) {
        let verdict = HumanGesture.permit(gestureInputs.currentEvent(), control: sender,
                                          voiceOverEnabled: gestureInputs.voiceOverEnabled,
                                          allowsSynthetic: gestureInputs.allowsSynthetic)
        guard case .human = verdict else { logRefused(verdict, "answer"); return }
        guard let job = currentJob else { return }
        let text = replyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        host.answerJob(job.id, text: text)
        replyTextView.string = ""
    }

    /// One of Mother's options. `override_open` only asks for its confirmation here.
    @objc private func didTapOption(_ sender: NSButton) {
        let verdict = HumanGesture.permit(gestureInputs.currentEvent(), control: sender,
                                          voiceOverEnabled: gestureInputs.voiceOverEnabled,
                                          allowsSynthetic: gestureInputs.allowsSynthetic)
        guard case .human = verdict else { logRefused(verdict, "option"); return }
        guard let job = currentJob, let decision = optionDecision(for: job),
              let option = decision.options.first(where: { Self.optionIdentifierPrefix + $0.id.raw == sender.identifier?.rawValue })
        else { return }
        if option.id == .overrideOpen {
            host.beginMotherDecisionConfirm(jobId: job.id, decisionId: decision.id, option: option.id)
            return
        }
        host.answerMotherDecision(jobId: job.id, decisionId: decision.id, option: option,
                                  text: option.takesText ? replyTextView.string : "")
    }

    /// The second click of `override_open`.
    @objc private func didConfirmOverride(_ sender: NSButton) {
        let verdict = HumanGesture.permit(gestureInputs.currentEvent(), control: sender,
                                          voiceOverEnabled: gestureInputs.voiceOverEnabled,
                                          allowsSynthetic: gestureInputs.allowsSynthetic)
        guard case .human = verdict else { logRefused(verdict, "override confirm"); return }
        guard let job = currentJob, let decision = optionDecision(for: job),
              let option = decision.options.first(where: { $0.id == .overrideOpen })
        else { return }
        host.answerMotherDecision(jobId: job.id, decisionId: decision.id, option: option, text: "")
    }

    /// Back out of the confirmation. It sends nothing, but it is part of the confirmation a person
    /// is making, so synthetic input does not get to move it either.
    @objc private func didBackFromConfirm(_ sender: NSButton) {
        let verdict = HumanGesture.permit(gestureInputs.currentEvent(), control: sender,
                                          voiceOverEnabled: gestureInputs.voiceOverEnabled,
                                          allowsSynthetic: gestureInputs.allowsSynthetic)
        guard case .human = verdict else { logRefused(verdict, "override back"); return }
        guard let job = currentJob, let decision = optionDecision(for: job) else { return }
        host.cancelMotherDecisionConfirm(jobId: job.id, decisionId: decision.id)
    }

    /// Acknowledge a raised flag. The crew panel's SwiftUI button calls this, so the control
    /// the gesture is checked against is the crew section that hosts it.
    func acknowledge(reason: MotherAttentionReason) {
        let verdict = HumanGesture.permit(gestureInputs.currentEvent(), control: crewSection,
                                          voiceOverEnabled: gestureInputs.voiceOverEnabled,
                                          allowsSynthetic: gestureInputs.allowsSynthetic)
        guard case .human = verdict else { logRefused(verdict, "acknowledge"); return }
        guard let job = currentJob else { return }
        host.ackMotherAttention(jobId: job.id, reason: reason)
    }

    @objc private func didTapCancel() {
        guard let job = currentJob else { return }
        host.cancelJob(job.id)
    }

    @objc private func didTapRetry() {
        guard let job = currentJob else { return }
        host.retryJob(job.id)
    }

    @objc private func didForceStart() {
        guard let job = currentJob else { return }
        let alert = NSAlert()
        alert.messageText = "Force-start \"\(job.title.isEmpty ? job.id : job.title)\"?"
        alert.informativeText = "This runs the job now even if quota is over cap, at full tier (ignoring conservative posture). It consumes headroom shared with other jobs and interactive sessions."
        alert.addButton(withTitle: "Force-start")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Sheet, not alert.runModal() — a free-floating modal has no window
        // association and can strand on another Space with the main thread
        // blocked waiting on it (looks exactly like a hang).
        guard let window else { return }
        let host = self.host
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                host.forceStartJob(job.id)
            }
        }
    }

    @objc private func didEscalate() {
        guard let job = currentJob else { return }
        let alert = NSAlert()
        alert.messageText = "Escalate “\(job.title.isEmpty ? job.id : job.title)”?"
        alert.informativeText = "This re-runs the failed job on the next model tier. A more capable model costs more."
        alert.addButton(withTitle: "Escalate")
        alert.addButton(withTitle: "Cancel")
        // Sheet only (never a free-floating modal — see DecisionSheetWiringTests).
        guard let window else { return }
        let host = self.host
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { host.escalateJob(job.id) } }
    }

    @objc private func didArchive() {
        guard let job = currentJob else { return }
        host.archiveJob(job.id)
    }

    private struct MetaPair: Equatable { let key: String; let value: String }

    private func metaPairs(for job: MotherJob) -> [MetaPair] {
        var pairs: [(String, String)] = [("ID", String(job.id.prefix(16)))]
        if !job.repo.isEmpty      { pairs.append(("Repo",      job.repo)) }
        if !job.isolation.isEmpty { pairs.append(("Isolation", job.isolation)) }
        if let t = job.currentTier    { pairs.append(("Tier",      t)) }
        if let s = job.startedAt {
            pairs.append(("Started", relativeTime(s)))
            if job.state == "running" { pairs.append(("Running for", elapsed(s))) }
        }
        if let f = job.finishedAt   { pairs.append(("Finished",  relativeTime(f))) }
        if let p = job.planPath     { pairs.append(("Plan",      (p as NSString).lastPathComponent)) }
        if let q = job.question     { pairs.append(("Question",  q)) }
        if let a = job.adherenceStatus { pairs.append(("Adherence", a)) }
        return pairs.map { MetaPair(key: $0.0, value: $0.1) }
    }

    private func rebuildMeta(_ pairs: [MetaPair]) {
        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for pair in pairs {
            let (key, value) = (pair.key, pair.value)
            let row = metaRow(key: key, value: value)
            metaStack.addArrangedSubview(row)
            // The stack aligns .leading, which would let a row grow to its text's
            // natural width; pin rows to the stack so long values wrap instead.
            row.widthAnchor.constraint(lessThanOrEqualTo: metaStack.widthAnchor).isActive = true
        }
    }

    private func metaRow(key: String, value: String) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font      = .systemFont(ofSize: 10, weight: .medium)
        k.textColor = Theme.fgMuted
        k.setContentHuggingPriority(.required, for: .horizontal)
        k.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Wrap, never clip: a job's question can be several paragraphs long. The
        // value yields horizontally (low compression resistance) and the row is
        // bounded to the stack's width below, so the label wraps to the pane.
        let v = NSTextField(wrappingLabelWithString: value)
        v.font          = Theme.monoFont
        v.textColor     = Theme.fg
        v.lineBreakMode = .byWordWrapping
        v.maximumNumberOfLines = 0
        v.isSelectable  = true          // copyable
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .firstBaseline
        return row
    }

    private func loadLog(_ job: MotherJob) {
        let path = logDirectory.appendingPathComponent("\(job.id).log").path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let tail    = content.components(separatedBy: "\n").suffix(200).joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentJobId == job.id else { return }
                self.setLogAttributed(tail)
            }
        }
    }

    /// Replace the log's text, keeping the reader's place: a log scrolled to the bottom keeps
    /// following new lines; one scrolled up stays exactly where it was.
    func setLogAttributed(_ text: String) {
        guard text != lastLogText else { return }   // nothing new: leave the view alone
        let hadLog = lastLogText != nil
        lastLogText = text
        // Lines that come in while the Log is not on show are marked on its segment.
        if hadLog, selectedSegment != .log, !text.isEmpty, !logHasUnseenLines {
            logHasUnseenLines = true
            rebuildSegmentControl()
        }
        let result = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard
                let data = trimmed.data(using: .utf8),
                let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }

            switch type {
            case "system":
                continue

            case "assistant":
                guard let msg     = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]] else { continue }
                for block in content {
                    guard let blockType = block["type"] as? String else { continue }
                    switch blockType {
                    case "text":
                        guard let txt = block["text"] as? String else { continue }
                        appendRun(txt + "\n\n", font: Theme.monoFont, color: Theme.fg, to: result)
                    case "tool_use":
                        let name    = (block["name"] as? String) ?? "Tool"
                        let input   = (block["input"] as? [String: Any]) ?? [:]
                        let summary = toolSummary(input)
                        let header  = summary.isEmpty ? "▶ \(name)\n" : "▶ \(name)  \(summary)\n"
                        appendRun(header, font: NSFont.systemFont(ofSize: 11), color: Theme.amber, to: result)
                    default:
                        continue
                    }
                }

            case "user":
                guard let content = obj["content"] as? [[String: Any]] else { continue }
                for block in content {
                    guard (block["type"] as? String) == "tool_result" else { continue }
                    let isError = (block["is_error"] as? Bool) ?? false

                    // Prefer stdout from tool_use_result envelope
                    var body    = ""
                    var hasErr  = false
                    if let tur    = obj["tool_use_result"] as? [String: Any] {
                        let stdout = (tur["stdout"] as? String) ?? ""
                        let stderr = (tur["stderr"] as? String) ?? ""
                        hasErr = !stderr.isEmpty
                        body   = stdout.isEmpty ? stderr : stdout
                    }
                    if body.isEmpty {
                        body = (block["content"] as? String) ?? ""
                    }

                    let truncated: String
                    if body.count > 500 {
                        truncated = String(body.prefix(500)) + "\n  … (truncated)"
                    } else {
                        truncated = body
                    }
                    let indented = truncated.components(separatedBy: "\n")
                        .map { "  \($0)" }
                        .joined(separator: "\n")
                    let color = (isError || hasErr) ? Theme.redSweater : Theme.fgMuted
                    appendRun(indented + "\n\n", font: Theme.monoFont, color: color, to: result)
                }

            default:
                continue
            }
        }
        let clip = logScrollView.contentView
        let followsTail = logIsAtBottom()
        let savedOrigin = clip.bounds.origin
        logTextView.textStorage?.setAttributedString(result)
        // The text view sizes itself to its layout: force that layout before scrolling.
        if let container = logTextView.textContainer { logTextView.layoutManager?.ensureLayout(for: container) }
        let maxY = max(0, (logScrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        // Following the tail goes to the end; otherwise put the old position back (clamped to the new height).
        let targetY = followsTail ? maxY : min(savedOrigin.y, maxY)
        clip.scroll(to: NSPoint(x: savedOrigin.x, y: targetY))
        logScrollView.reflectScrolledClipView(clip)
    }

    /// The log is scrolled to its end (within 4 pt), or too short to scroll.
    private func logIsAtBottom() -> Bool {
        let clip = logScrollView.contentView
        let docHeight = logScrollView.documentView?.frame.height ?? 0
        return docHeight - clip.bounds.maxY <= 4
    }

    private func appendRun(_ s: String, font: NSFont, color: NSColor, to target: NSMutableAttributedString) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        target.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func toolSummary(_ input: [String: Any]) -> String {
        if let desc = input["description"] as? String, !desc.isEmpty {
            return desc
        }
        let candidates = ["command", "file_path"]
        for key in candidates {
            if let val = input[key] as? String, !val.isEmpty {
                return val.count > 80 ? String(val.prefix(80)) + "…" : val
            }
        }
        // Fallback: first string value
        for (_, val) in input {
            if let s = val as? String, !s.isEmpty {
                return s.count > 80 ? String(s.prefix(80)) + "…" : s
            }
        }
        return ""
    }

    private func stateColor(_ state: String) -> NSColor {
        switch state {
        case "running":  return Theme.sage
        case "awaiting": return Theme.amber
        case "failed":   return Theme.redSweater
        default:         return Theme.fgMuted
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60   { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func elapsed(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60   { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}

// MARK: - PlanChecklistView

/// Read-only checklist parsed from a plan markdown file.
///
/// Scans the file for `- [ ]` / `- [x]` items (Kit's `PlanChecklist`, the same parser the Plan view's
/// `n/m criteria` count uses) and renders them as icon+text rows. It reads and watches the file the way
/// the Plan view does (`PlanFileLoader`: a regular markdown file of at most 1 MiB, a result that a newer
/// read has overtaken is dropped, an edit on disk reloads it, a file that is not there yet is looked
/// for again), and only while the Overview is the segment on show, so the two views of one file never
/// disagree for longer than a debounce. Collapses to zero height (via `heightConstraint`) when there are
/// no items.
private class PlanChecklistView: NSView {

    /// Called on the main queue when items load or clear.  Parameter is `true` if items are present.
    var onItemsChanged: ((Bool) -> Void)?
    /// Called on the main queue right before the rows are replaced or cleared.
    var onWillChange: (() -> Void)?
    /// Makes the file loader, the first time one is needed.
    var makeLoader: () -> PlanFileLoader = { PlanFileLoader() }

    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var madeLoader: PlanFileLoader?
    /// Made the first time it is needed, so a test can replace `makeLoader` first.
    private var loader: PlanFileLoader {
        if let madeLoader { return madeLoader }
        let loader = makeLoader()
        loader.onResult = { [weak self] result in self?.loaderDidDeliver(result) }
        madeLoader = loader
        return loader
    }
    private var planPath: String?
    /// The Overview is the segment on show: only then does the view read and watch the file.
    private var isActive = false
    private var needsLoadOnActivate = false
    /// What the rows show now; nil until the plan at `planPath` has answered once.
    private var shownItems: [PlanChecklistItem]?
    /// Every answer and every path change takes the next number; a parse applies only if it still holds the latest.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)

        stack.orientation = .vertical
        stack.spacing     = 4
        stack.alignment   = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Start collapsed
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the plan at `path` (nil or empty: none). Reads it now if the Overview is on show, else when it is.
    func show(planPath path: String?) {
        let newPath = (path?.isEmpty ?? true) ? nil : path
        guard newPath != planPath else {
            onItemsChanged?(!stack.arrangedSubviews.isEmpty)
            return
        }
        planPath = newPath
        generation += 1
        shownItems = nil
        guard newPath != nil else {
            needsLoadOnActivate = false
            madeLoader?.load(path: nil)
            collapse()
            return
        }
        if isActive { loader.load(path: newPath) } else { needsLoadOnActivate = true }
    }

    /// The Overview is on show (true) or another segment is (false). Hidden, the view holds no watcher.
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
            generation += 1
            madeLoader?.stop()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Off screen for good, or until the detail is shown again.
            generation += 1
            madeLoader?.stop()
            if planPath != nil, isActive { needsLoadOnActivate = true }
        } else if isActive, needsLoadOnActivate {
            needsLoadOnActivate = false
            loader.load(path: planPath)
        }
    }

    // MARK: Private

    private func loaderDidDeliver(_ result: PlanFileResult) {
        generation += 1
        let mine = generation
        let loaderGeneration = loader.generation
        guard case .loaded(let text, _, _) = result else {
            apply([])   // no file, or one that cannot be shown: no items
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = PlanChecklist.parse(text)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine, self.loader.generation == loaderGeneration else { return }
                self.apply(items)
            }
        }
    }

    private func collapse() {
        let mine = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == mine else { return }
            self.onWillChange?()
            self.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            self.heightConstraint.isActive = true
            self.shownItems = []
            self.onItemsChanged?(false)
        }
    }

    private func apply(_ items: [PlanChecklistItem]) {
        // The same items again (a save that changed nothing here, a reload on coming back): keep the rows.
        guard items != shownItems else { return }
        shownItems = items
        onWillChange?()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !items.isEmpty else {
            heightConstraint.isActive = true
            onItemsChanged?(false)
            return
        }
        for item in items {
            let row = checklistRow(item)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        heightConstraint.isActive = false
        onItemsChanged?(true)
    }

    private func checklistRow(_ item: PlanChecklistItem) -> NSView {
        let icon = NSTextField(labelWithString: item.done ? "✓" : "○")
        icon.font      = .systemFont(ofSize: 11)
        icon.textColor = item.done ? Theme.sage : Theme.fgMuted
        icon.setContentHuggingPriority(.required, for: .horizontal)

        // A plan's text is untrusted: no bidi override, zero-width or filler character, no escape sequence.
        let lbl = NSTextField.boundedLabel(FoldTextSanitizer.sanitizeInline(item.text))
        lbl.font                 = .systemFont(ofSize: 11)
        lbl.lineBreakMode        = .byWordWrapping
        lbl.maximumNumberOfLines = 3
        lbl.textColor            = item.done ? Theme.fgMuted : Theme.fg

        let row = NSStackView(views: [icon, lbl])
        row.orientation = .horizontal
        row.spacing     = 5
        row.alignment   = .firstBaseline
        return row
    }
}


// MARK: - MotherCrewSectionView

/// Hosts the Kit `MotherCrewPanel` between the phase ribbon and the actions.
///
/// The section's height is `MotherCrewPanelModel.height` and nothing else: zero (and hidden)
/// for a job without crew data, one step up when the first data arrives, and unchanged
/// while values inside the same rows change. SwiftUI is never asked how tall it is.
final class MotherCrewSectionView: NSView {

    private let hosting: NSHostingView<MotherCrewPanel>
    private var heightConstraint: NSLayoutConstraint!
    private(set) var model = MotherCrewPanelModel()
    private(set) var breakdownExpanded = false
    private var detailsAvailable = false
    private var acknowledgeAvailable = false
    var onDetails: (() -> Void)?
    var onAcknowledge: ((MotherAttentionReason) -> Void)?

    override init(frame: NSRect) {
        hosting = NSHostingView(rootView: MotherCrewPanel(model: MotherCrewPanelModel(), colors: MotherJobDetail.crewColors))
        super.init(frame: frame)
        // We size it; SwiftUI's own min/ideal/max would fight a fixed height.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("MotherCrewSectionView is built in code") }

    /// The height the section should have right now.
    var expectedHeight: CGFloat { model.height(breakdownExpanded: breakdownExpanded) }

    func update(model newModel: MotherCrewPanelModel, detailsAvailable newDetails: Bool,
                acknowledgeAvailable newAcknowledge: Bool = false) {
        guard newModel != model || newDetails != detailsAvailable || newAcknowledge != acknowledgeAvailable else { return }
        model = newModel
        detailsAvailable = newDetails
        acknowledgeAvailable = newAcknowledge
        render()
    }

    func collapseBreakdown() {
        guard breakdownExpanded else { return }
        breakdownExpanded = false
        render()
    }

    private func toggleBreakdown() {
        breakdownExpanded.toggle()
        render()
    }

    private func render() {
        hosting.rootView = MotherCrewPanel(
            model: model, colors: MotherJobDetail.crewColors,
            breakdownExpanded: breakdownExpanded,
            onToggleBreakdown: { [weak self] in self?.toggleBreakdown() },
            onDetails: detailsAvailable ? { [weak self] in self?.onDetails?() } : nil,
            onAcknowledge: acknowledgeAvailable ? { [weak self] reason in self?.onAcknowledge?(reason) } : nil
        )
        let height = expectedHeight
        if heightConstraint.constant != height { heightConstraint.constant = height }
        isHidden = model.isEmpty
    }
}

// MARK: - Details sheet
//
// `mother status <id>` text for the job, shown only in a sheet on this Mac. Gate output and
// finding text never leave this code path: nothing below logs, sends or stores the text, and
// the sheet drops it when it closes. For a PHI repo the text is never fetched at all.

/// What the Details sheet shows.
enum MotherDetailsContent: Equatable {
    /// The local `mother status <id>` output.
    case text(String)
    /// A PHI repo: only the command to run in Terminal.
    case commandOnly(String)
    /// It could not be produced (no `mother` binary, a timeout).
    case unavailable(String)
}

extension MotherJobDetail {

    /// Repos whose gate output and findings may hold PHI stay in Terminal.
    static func isPHIRepo(_ repo: String) -> Bool {
        let name = repo.lowercased()
        return name.hasSuffix("admin-portal") || name.hasSuffix("referral-monitor")
    }

    /// `mother status <id>`, with the id quoted when it is not plainly safe.
    static func statusCommand(forJob id: String) -> String {
        let safe = id.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        return "mother status " + (safe ? id : "'" + id.replacingOccurrences(of: "'", with: "'\\''") + "'")
    }

    /// Produce the sheet's content. Off the main thread, with a timeout; `completion` runs on main.
    func loadDetails(for job: MotherJob, timeout: TimeInterval = 10,
                     completion: @escaping (MotherDetailsContent) -> Void) {
        if Self.isPHIRepo(job.repo) {
            completion(.commandOnly(Self.statusCommand(forJob: job.id)))
            return
        }
        let host = self.host
        let id = job.id
        DispatchQueue.global(qos: .userInitiated).async {
            let content: MotherDetailsContent
            if let bin = host.motherBinary() {
                content = Self.statusContent(binary: bin, jobId: id, timeout: timeout)
            } else {
                content = .unavailable("The mother command was not found.")
            }
            DispatchQueue.main.async { completion(content) }
        }
    }

    /// Run `mother status <id>` and classify the outcome. Blocking: call off the main thread.
    private static func statusContent(binary: URL, jobId: String, timeout: TimeInterval) -> MotherDetailsContent {
        guard let r = ProcessRunner.runCapturingStdout(binary, arguments: ["status", jobId], timeout: timeout) else {
            return .unavailable("mother status could not be started.")
        }
        if r.timedOut {
            return .unavailable("mother status did not answer within \(Int(timeout)) seconds.")
        }
        let text = String(decoding: r.data, as: UTF8.self)
        if text.isEmpty {
            return .unavailable("mother status printed nothing (exit \(r.status)).")
        }
        return .text(text)
    }

    /// Open the Details sheet for the current job.
    func showDetails() {
        guard let job = currentJob, let window, host.usesDefaultBroker else { return }
        let sheet = MotherDetailsSheet(jobTitle: job.title.isEmpty ? job.id : job.title)
        sheet.present(over: window)
        loadDetails(for: job) { [weak sheet] content in sheet?.show(content) }
    }
}

/// A sheet with a read-only, selectable, monospaced text view (or, for a PHI repo, the command and a Copy button).
final class MotherDetailsSheet: NSObject {

    private let sheetWindow: NSWindow
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy command", target: nil, action: nil)
    private var command: String?
    private weak var parent: NSWindow?

    init(jobTitle: String) {
        sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        sheetWindow.title = "Gates and review: \(jobTitle)"
        sheetWindow.appearance = NSAppearance(named: .darkAqua)
        sheetWindow.isReleasedWhenClosed = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.09, alpha: 1)
        textView.textColor = Theme.fg
        textView.font = Theme.monoFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = "Running mother status…"

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\u{1b}"   // Escape closes; nothing here is an answer or an acknowledgement
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        copyButton.isHidden = true
        let buttons = NSStackView(views: [copyButton, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        sheetWindow.contentView = content
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func present(over window: NSWindow) {
        parent = window
        window.beginSheet(sheetWindow)
    }

    func show(_ content: MotherDetailsContent) {
        switch content {
        case .text(let text):
            textView.string = text
        case .commandOnly(let command):
            self.command = command
            textView.string = "Gate output and findings stay in Terminal for this repo:\n\n    \(command)"
            copyButton.isHidden = false
        case .unavailable(let reason):
            textView.string = reason
        }
    }

    /// What the sheet is showing (for tests).
    var shownText: String { textView.string }
    var isCopyButtonVisible: Bool { !copyButton.isHidden }

    @objc private func copyCommand() {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc func close() {
        textView.string = ""       // the text lives only as long as the sheet
        command = nil
        parent?.endSheet(sheetWindow)
    }
}

// MARK: - MotherCountsChips

/// The counts strip's chips: Running, Queued, Awaiting, Succeeded, Failed, then "needs you",
/// Stalled and Burning. Built once and updated in place. The last three have a reserved, fixed-width
/// slot and only hide their content at zero, so no chip ever moves when another count changes.
final class MotherCountsChips: NSView {

    private struct Spec {
        let symbol: String
        let label: String
        let color: NSColor
        let count: (MotherStatus) -> Int
        /// A fixed slot, hidden at zero (the crew chips); nil for a chip that is always shown.
        let reservedWidth: CGFloat?
    }

    private static let specs: [Spec] = [
        Spec(symbol: "▶", label: "Running",   color: Theme.sage,        count: { $0.running },   reservedWidth: nil),
        Spec(symbol: "⏸", label: "Queued",    color: Theme.fgMuted,     count: { $0.queued },    reservedWidth: nil),
        Spec(symbol: "?", label: "Awaiting",  color: Theme.amber,       count: { $0.awaiting },  reservedWidth: nil),
        Spec(symbol: "✓", label: "Succeeded", color: Theme.sage,        count: { $0.succeeded }, reservedWidth: nil),
        Spec(symbol: "!", label: "Failed",    color: Theme.redSweater,  count: { $0.failed },    reservedWidth: nil),
        Spec(symbol: "⚑", label: "Needs you", color: Theme.amber,       count: { $0.needsYou },  reservedWidth: 96),
        Spec(symbol: "◔", label: "Stalled",   color: Theme.redSweater,  count: { $0.stalled },   reservedWidth: 84),
        Spec(symbol: "▲", label: "Burning",   color: Theme.redSweater,  count: { $0.burning },   reservedWidth: 84),
    ]

    private final class Chip: NSView {
        let spec: Spec
        let symbol = NSTextField(labelWithString: "")
        let number = NSTextField(labelWithString: "0")
        let label  = NSTextField(labelWithString: "")
        let content = NSStackView()

        init(spec: Spec) {
            self.spec = spec
            super.init(frame: .zero)
            symbol.stringValue = spec.symbol
            label.stringValue = spec.label
            symbol.font = .systemFont(ofSize: 11)
            number.font = .monospacedDigitSystemFont(ofSize: 16, weight: .light)
            label.font  = .systemFont(ofSize: 10)
            [symbol, number, label].forEach { content.addArrangedSubview($0) }
            content.orientation = .horizontal
            content.spacing = 4
            content.alignment = .centerY
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            if let width = spec.reservedWidth {
                // A fixed slot: the content sits inside it and may come and go.
                widthAnchor.constraint(equalToConstant: width).isActive = true
                let fit = content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                fit.priority = .defaultHigh   // never a hard conflict with the slot width
                fit.isActive = true
            } else {
                content.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
            // One VoiceOver element per chip; its pieces are not separate stops.
            [symbol, number, label].forEach { $0.setAccessibilityElement(false) }
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        required init?(coder: NSCoder) { fatalError("Chip is built in code") }

        func render(count: Int) {
            let active = count > 0
            number.stringValue = "\(count)"
            symbol.textColor = active ? spec.color : Theme.borderInactive
            number.textColor = active ? spec.color : Theme.fgMuted
            label.textColor  = active ? Theme.fgMuted : Theme.borderInactive
            let hidden = spec.reservedWidth != nil && !active
            content.isHidden = hidden
            setAccessibilityElement(!hidden)
            setAccessibilityLabel("\(count) \(spec.label.lowercased())")
        }
    }

    private let stack = NSStackView()
    private let chips: [Chip]

    override init(frame: NSRect) {
        chips = Self.specs.map { Chip(spec: $0) }
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 20
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        chips.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview($0) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        render(MotherStatus())
    }

    required init?(coder: NSCoder) { fatalError("MotherCountsChips is built in code") }

    func render(_ status: MotherStatus) {
        for chip in chips { chip.render(count: chip.spec.count(status)) }
    }

    /// Each chip's frame in this view's coordinates, by label (for tests).
    var chipFrames: [String: NSRect] {
        Dictionary(uniqueKeysWithValues: chips.map { ($0.spec.label, convert($0.frame, from: stack)) })
    }

    /// Each chip's VoiceOver label, by label; nil when the chip is hidden at zero (for tests).
    var chipAccessibilityLabels: [String: String?] {
        Dictionary(uniqueKeysWithValues: chips.map {
            ($0.spec.label, $0.isAccessibilityElement() ? $0.accessibilityLabel() : nil)
        })
    }
}
