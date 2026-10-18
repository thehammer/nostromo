import AppKit
import Combine
import NostromoKit
import SwiftUI
import os

// The Mother job detail pane and the pieces only it uses. Kept out of MotherView.swift
// so the Mac logic tests (which compile no AppStore) can drive it directly: everything the
// detail needs from the app goes through `MotherJobDetailHost`.

private let log = Logger(subsystem: "com.hammer.nostromo", category: "mother-detail")

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
    func cancelJob(_ id: String)
    func retryJob(_ id: String)
    func forceStartJob(_ id: String)
    func escalateJob(_ id: String)
    func archiveJob(_ id: String)
    func openPlan(path: String)
    func clearMotherActionError()
}

// MARK: - PhaseRibbonView

/// Compact phase-progress ribbon: `redd✓ cody⟳ marty· · cycle 2`
///
/// Hidden (zero height) when the job has no phase data — non-pipeline and
/// pre-Wedge-C jobs are unaffected.
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
            let lbl = NSTextField(labelWithString: token.text)
            lbl.font      = .systemFont(ofSize: 11)
            lbl.textColor = tokenColor(token.state)
            stack.addArrangedSubview(lbl)
        }

        if let cycleLabel = model.cycleLabel {
            let sep = NSTextField(labelWithString: "·")
            sep.font      = .systemFont(ofSize: 11)
            sep.textColor = Theme.fgMuted
            stack.addArrangedSubview(sep)

            let cLbl = NSTextField(labelWithString: cycleLabel)
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

    // Content fields
    private let titleLabel      = NSTextField(labelWithString: "")
    private let stateLabel      = NSTextField(labelWithString: "")
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
    private let logSectionLabel = NSTextField(labelWithString: "LOG TAIL")
    let logScrollView   = NSScrollView()
    let logTextView     = NSTextView()

    // Action widgets (created once, shown/hidden as needed)
    private let brokerBanner     = NSTextField(labelWithString: "⚠ Mother broker offline")
    private let replyScrollView  = NSScrollView()
    let replyTextView            = NSTextView()
    private let answerButton     = NSButton(title: "Answer",      target: nil, action: nil)
    private let cancelButton     = NSButton(title: "Cancel job",  target: nil, action: nil)
    private let retryButton      = NSButton(title: "Retry",       target: nil, action: nil)
    private let forceStartButton = NSButton(title: "Force-start", target: nil, action: nil)
    private let archiveButton    = NSButton(title: "Archive",     target: nil, action: nil)
    private let escalateButton   = NSButton(title: "Escalate",    target: nil, action: nil)
    private let viewPlanButton   = NSButton(title: "View Plan",   target: nil, action: nil)
    private let actionErrorLabel = NSTextField(labelWithString: "")
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
        var hasPlan: Bool

        init(job: MotherJob, brokerConnected: Bool) {
            state = job.state
            self.brokerConnected = brokerConnected
            decisionId = job.crew.decision.flatMap { $0.isOpen ? $0.id : nil }
            holdKind = job.holdSummary?.kind
            hasPlan = !(job.planPath ?? "").isEmpty
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

        stateLabel.font      = .systemFont(ofSize: 10, weight: .semibold)
        stateLabel.textColor = Theme.fgMuted

        metaStack.orientation = .vertical
        metaStack.spacing     = 4
        metaStack.alignment   = .leading

        // Actions container (variable height, rebuilt per job state)
        actionsContainer.translatesAutoresizingMaskIntoConstraints = false

        logSectionLabel.font      = .systemFont(ofSize: 9, weight: .semibold)
        logSectionLabel.textColor = Theme.fgMuted

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

        todoStack.orientation = .vertical
        todoStack.spacing     = 4
        todoStack.alignment   = .leading

        planSectionLabel.font      = .systemFont(ofSize: 9, weight: .semibold)
        planSectionLabel.textColor = Theme.fgMuted

        for v in [titleLabel, stateLabel, phaseRibbonView, crewSection, actionsContainer, todoStack, metaStack,
                  planSectionLabel, planChecklistView, logSectionLabel, logScrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Ribbon height toggles between 0 (hidden) and 22 (visible)
        ribbonHeight = phaseRibbonView.heightAnchor.constraint(equalToConstant: 0)
        ribbonHeight.isActive = true

        // The gap above the crew section is 0 while it is empty, so a job without crew data
        // lays out exactly as it did before the section existed.
        crewTopGap = crewSection.topAnchor.constraint(equalTo: phaseRibbonView.bottomAnchor, constant: 0)
        crewTopGap.isActive = true
        crewSection.onDetails = { [weak self] in self?.showDetails() }

        // Todo stack height: 0 when empty, constrained by content otherwise
        todoHeight = todoStack.heightAnchor.constraint(equalToConstant: 0)
        todoHeight.isActive = true

        // Wire plan checklist visibility: show/hide section label in tandem
        planChecklistView.onItemsChanged = { [weak self] hasItems in
            self?.planSectionLabel.isHidden = !hasItems
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            // Phase ribbon — sits between state label and actions; height is 0 when hidden
            phaseRibbonView.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8),
            phaseRibbonView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            phaseRibbonView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Crew section — between the ribbon and the actions; zero height without crew data
            crewSection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            crewSection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Actions container — below the crew section (which is zero height, so directly
            // below the phase ribbon, when the job has no crew data)
            actionsContainer.topAnchor.constraint(equalTo: crewSection.bottomAnchor, constant: 8),
            actionsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Todo stack — below actions, above meta rows
            todoStack.topAnchor.constraint(equalTo: actionsContainer.bottomAnchor, constant: 8),
            todoStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            todoStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            metaStack.topAnchor.constraint(equalTo: todoStack.bottomAnchor, constant: 8),
            metaStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Plan checklist section — between meta and log
            planSectionLabel.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 12),
            planSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            planChecklistView.topAnchor.constraint(equalTo: planSectionLabel.bottomAnchor, constant: 6),
            planChecklistView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            planChecklistView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            logSectionLabel.topAnchor.constraint(equalTo: planChecklistView.bottomAnchor, constant: 12),
            logSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            logScrollView.topAnchor.constraint(equalTo: logSectionLabel.bottomAnchor, constant: 6),
            logScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            logScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            logScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
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
        replyScrollView.documentView          = replyTextView

        // Buttons
        for btn in [answerButton, cancelButton, retryButton,
                    forceStartButton, archiveButton, viewPlanButton] {
            btn.bezelStyle  = .rounded
            btn.isBordered  = true
            btn.font        = .systemFont(ofSize: 11)
        }
        answerButton.target     = self
        answerButton.action     = #selector(didTapAnswer)
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
        viewPlanButton.target   = self
        viewPlanButton.action   = #selector(didViewPlan)

        // Semantic color coding via contentTintColor
        cancelButton.contentTintColor     = Theme.redSweater
        retryButton.contentTintColor      = Theme.sage
        forceStartButton.contentTintColor = Theme.amber
        archiveButton.contentTintColor    = Theme.fgMuted
        viewPlanButton.contentTintColor   = Theme.fgMuted
        answerButton.contentTintColor     = Theme.sage

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
        logTimer?.invalidate(); logTimer = nil
        currentJob   = job
        currentJobId = job?.id
        replyTextView.string = ""
        lastLogText = nil
        crewSection.collapseBreakdown()

        guard let job else {
            actionIdentity = nil
            actionStack = nil
            showEmpty()
            return
        }

        [titleLabel, stateLabel, todoStack, metaStack, actionsContainer,
         planSectionLabel, planChecklistView, logSectionLabel, logScrollView].forEach { $0.isHidden = false }
        emptyLabel.isHidden = true

        titleLabel.stringValue = job.title.isEmpty ? job.id : job.title
        stateLabel.stringValue = job.state.uppercased()
        stateLabel.textColor   = stateColor(job.state)

        updateRibbon(job)
        updateCrewSection(job)
        updateTodoList(host.peek(for: job.id))
        shownMeta = metaPairs(for: job)
        rebuildMeta(shownMeta)
        rebuildActions(job)
        planChecklistView.load(planPath: job.planPath)
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
        updateCrewSection(job)

        let pairs = metaPairs(for: job)
        if pairs != shownMeta {
            shownMeta = pairs
            rebuildMeta(pairs)
        }

        let identity = ActionIdentity(job: job, brokerConnected: host.brokerConnected)
        if identity != actionIdentity { rebuildActions(job) }

        if job.planPath != previous.planPath { planChecklistView.load(planPath: job.planPath) }

        if job.state != previous.state {
            syncLogTimer(for: job)
            if !Self.isActive(job.state) { loadLog(job) }   // the log's last lines
        }
    }

    // MARK: Private

    private func showEmpty() {
        [titleLabel, stateLabel, phaseRibbonView, crewSection, todoStack, metaStack, actionsContainer,
         planSectionLabel, planChecklistView, logSectionLabel, logScrollView].forEach { $0.isHidden = true }
        emptyLabel.isHidden = false
        planChecklistView.load(planPath: nil)
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
        let model = MotherCrewPanelModel.make(job: job.kitJob)
        crewSection.update(model: model, detailsAvailable: model.hasDetails && host.usesDefaultBroker)
        crewTopGap.constant = model.isEmpty ? 0 : 8
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
            todoStack.addArrangedSubview(todoRow(todo))
        }

        // Let Auto Layout size the stack by its content.
        todoHeight.isActive = false
    }

    private func todoRow(_ todo: MotherPeekItem) -> NSView {
        let icon = NSTextField(labelWithString: todoIcon(todo.status))
        icon.font      = .systemFont(ofSize: 11)
        icon.textColor = todoIconColor(todo.status)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let lbl = NSTextField(labelWithString: todo.content)
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
        actionIdentity = ActionIdentity(job: job, brokerConnected: connected)
        actionStack = nil

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
            replyScrollView.translatesAutoresizingMaskIntoConstraints = false
            widgets.append(replyScrollView)

            let btnRow = NSStackView(views: [answerButton, cancelButton])
            btnRow.orientation = .horizontal
            btnRow.spacing     = 8
            btnRow.translatesAutoresizingMaskIntoConstraints = false
            widgets.append(btnRow)

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

        // View Plan — show whenever planPath is set
        if let planPath = job.planPath, !planPath.isEmpty {
            widgets.append(viewPlanButton)
        }

        widgets.append(actionErrorLabel)

        // Disable action buttons when broker is offline
        for btn in [answerButton, cancelButton, retryButton,
                    forceStartButton, archiveButton, viewPlanButton, escalateButton] {
            btn.isEnabled = connected
        }
        escalateButton.isEnabled = true   // goes through the CLI, not the broker
        // Archive and View Plan don't require broker — always enabled
        archiveButton.isEnabled  = true
        viewPlanButton.isEnabled = true

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

        // Fix the reply scroll view height (~3 lines)
        if job.state == "awaiting" {
            replyScrollView.translatesAutoresizingMaskIntoConstraints = false
            replyScrollView.heightAnchor.constraint(equalToConstant: 60).isActive = true
            replyScrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            replyScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
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

    private func updateBrokerBanner(_ connected: Bool) {
        guard currentJob != nil else { return }
        brokerBanner.isHidden = connected
        for btn in [answerButton, cancelButton, retryButton, forceStartButton] {
            btn.isEnabled = connected
        }
        // Archive and View Plan don't use the broker — always enabled
        archiveButton.isEnabled  = true
        viewPlanButton.isEnabled = true
    }

    private func showActionError(_ message: String) {
        actionErrorLabel.stringValue = message
        actionErrorLabel.isHidden    = false
        actionErrorTimer?.invalidate()
        actionErrorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.actionErrorLabel.isHidden = true
            self?.actionErrorLabel.stringValue = ""
            self?.host.clearMotherActionError()
        }
    }

    // MARK: - Button actions

    @objc private func didTapAnswer() {
        guard let job = currentJob else { return }
        let text = replyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        host.answerJob(job.id, text: text)
        replyTextView.string = ""
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

    @objc private func didViewPlan() {
        guard let path = currentJob?.planPath, !path.isEmpty else { return }
        host.openPlan(path: path)
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
        lastLogText = text
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
        if followsTail {
            logTextView.scrollRangeToVisible(NSRange(location: result.length, length: 0))
        } else {
            // Replacing the text resets the scroll position; put it back (clamped to the new height).
            if let container = logTextView.textContainer { logTextView.layoutManager?.ensureLayout(for: container) }
            let maxY = max(0, (logScrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: savedOrigin.x, y: min(savedOrigin.y, maxY)))
            logScrollView.reflectScrolledClipView(clip)
        }
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
/// Scans the file for `- [ ]` / `- [x]` items and renders them as icon+text rows.
/// Collapses to zero height (via `heightConstraint`) when there are no items.
private class PlanChecklistView: NSView {

    /// Called on the main queue when items load or clear.  Parameter is `true` if items are present.
    var onItemsChanged: ((Bool) -> Void)?

    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint!

    private static let itemRegex: NSRegularExpression = {
        // Matches: optional leading spaces, "- [", space or x/X, "]", space, item text
        try! NSRegularExpression(pattern: #"^\s*- \[([ xX])\]\s+(.+)$"#)
    }()

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

    func load(planPath: String?) {
        guard let path = planPath, !path.isEmpty else {
            collapse()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let items   = Self.parse(content)
            DispatchQueue.main.async { [weak self] in
                self?.apply(items)
            }
        }
    }

    // MARK: Private

    private func collapse() {
        DispatchQueue.main.async { [weak self] in
            self?.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            self?.heightConstraint.isActive = true
            self?.onItemsChanged?(false)
        }
    }

    private func apply(_ items: [(done: Bool, text: String)]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !items.isEmpty else {
            heightConstraint.isActive = true
            onItemsChanged?(false)
            return
        }
        for item in items {
            stack.addArrangedSubview(checklistRow(item))
        }
        heightConstraint.isActive = false
        onItemsChanged?(true)
    }

    private func checklistRow(_ item: (done: Bool, text: String)) -> NSView {
        let icon = NSTextField(labelWithString: item.done ? "✓" : "○")
        icon.font      = .systemFont(ofSize: 11)
        icon.textColor = item.done ? Theme.sage : Theme.fgMuted
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let lbl = NSTextField(labelWithString: item.text)
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

    private static func parse(_ content: String) -> [(done: Bool, text: String)] {
        var result: [(done: Bool, text: String)] = []
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let nsLine = line as NSString
            let range  = NSRange(location: 0, length: nsLine.length)
            guard let match = itemRegex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 3 else { continue }
            let marker = nsLine.substring(with: match.range(at: 1))
            let text   = nsLine.substring(with: match.range(at: 2))
            let done   = marker == "x" || marker == "X"
            result.append((done: done, text: text))
        }
        return result
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
    var onDetails: (() -> Void)?

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

    func update(model newModel: MotherCrewPanelModel, detailsAvailable newDetails: Bool) {
        guard newModel != model || newDetails != detailsAvailable else { return }
        model = newModel
        detailsAvailable = newDetails
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
            onDetails: detailsAvailable ? { [weak self] in self?.onDetails?() } : nil
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
                if let r = ProcessRunner.runCapturingStdout(bin, arguments: ["status", id], timeout: timeout) {
                    let text = String(decoding: r.data, as: UTF8.self)
                    if r.timedOut {
                        content = .unavailable("mother status did not answer within \(Int(timeout)) seconds.")
                    } else if text.isEmpty {
                        content = .unavailable("mother status printed nothing (exit \(r.status)).")
                    } else {
                        content = .text(text)
                    }
                } else {
                    content = .unavailable("mother status could not be started.")
                }
            } else {
                content = .unavailable("The mother command was not found.")
            }
            DispatchQueue.main.async { completion(content) }
        }
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
