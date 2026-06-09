import AppKit
import Combine
import NostromoKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "mother-view")

// MARK: - Mock data (layout dev aid — replaced by live AppStore data on arrival)

private let mockJobs: [MotherJob] = [
    MotherJob(
        id: "abc123def456", state: "running",
        repo: "carefeed", isolation: "worktree",
        title: "Add authentication middleware to API endpoints",
        createdAt: Date().addingTimeInterval(-680),
        startedAt:  Date().addingTimeInterval(-660),
        finishedAt: nil,
        planPath: "/Users/hammer/.claude/plans/auth-middleware.md",
        question: nil, pausedReason: nil, adherenceStatus: "green", currentTier: "sonnet"
    ),
    MotherJob(
        id: "bcd234efg567", state: "awaiting",
        repo: "carefeed", isolation: "none",
        title: "Refactor Schedule A export for CMS chain awareness",
        createdAt: Date().addingTimeInterval(-120),
        startedAt:  Date().addingTimeInterval(-90),
        finishedAt: nil,
        planPath: nil,
        question: "Should I preserve existing CSV column order?",
        pausedReason: "awaiting user input", adherenceStatus: nil, currentTier: "sonnet"
    ),
    MotherJob(
        id: "cde345fgh678", state: "queued",
        repo: "nostromo", isolation: "none",
        title: "Write unit tests for NostromodClient reconnect logic",
        createdAt: Date().addingTimeInterval(-30),
        startedAt: nil, finishedAt: nil,
        planPath: "/Users/hammer/.claude/plans/ipc-tests.md",
        question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil
    ),
    MotherJob(
        id: "def456ghi789", state: "failed",
        repo: "carefeed", isolation: "worktree",
        title: "Migrate users table to add soft deletes",
        createdAt: Date().addingTimeInterval(-3600),
        startedAt:  Date().addingTimeInterval(-3550),
        finishedAt: Date().addingTimeInterval(-3200),
        planPath: nil, question: nil, pausedReason: nil, adherenceStatus: "red",
        currentTier: "opus"
    ),
    MotherJob(
        id: "efg567hij890", state: "succeeded",
        repo: "carefeed", isolation: "none",
        title: "Fix nil crash in ActivityFeed when events arrive OOO",
        createdAt: Date().addingTimeInterval(-7200),
        startedAt:  Date().addingTimeInterval(-7150),
        finishedAt: Date().addingTimeInterval(-6900),
        planPath: nil, question: nil, pausedReason: nil, adherenceStatus: "green",
        currentTier: "sonnet"
    ),
]

// MARK: - MotherView

/// Mother job queue dashboard.
///
/// Layout:
///   Counts strip  — 36px top bar: running / queued / awaiting / failed
///   Content area  — horizontal split: job list (fixed 280px) | divider | job detail
class MotherView: NSView {

    private let countsStrip = MotherCountsStrip()
    private let jobList     = MotherJobList()
    private let jobDetail   = MotherJobDetail()

    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }


    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // 1px vertical divider between list and detail
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.borderInactive.cgColor

        for v in [countsStrip, jobList, divider, jobDetail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Counts strip — full width, fixed height, anchored to top
            countsStrip.topAnchor.constraint(equalTo: topAnchor),
            countsStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            countsStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            countsStrip.heightAnchor.constraint(equalToConstant: 36),

            // Job list — fixed width left pane
            jobList.topAnchor.constraint(equalTo: countsStrip.bottomAnchor),
            jobList.leadingAnchor.constraint(equalTo: leadingAnchor),
            jobList.widthAnchor.constraint(equalToConstant: 280),
            jobList.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Divider — 1px, full height of content area
            divider.topAnchor.constraint(equalTo: countsStrip.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: jobList.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Job detail — fills remaining width
            jobDetail.topAnchor.constraint(equalTo: countsStrip.bottomAnchor),
            jobDetail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            jobDetail.trailingAnchor.constraint(equalTo: trailingAnchor),
            jobDetail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Wire selection
        jobList.onSelect = { [weak self] job in
            self?.jobDetail.show(job)
        }

        // Live data — empty state ("No jobs") shows until first jobs arrive
        AppStore.shared.$motherJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.jobsDidChange(jobs) }
            .store(in: &cancellables)
    }

    private func jobsDidChange(_ jobs: [MotherJob]) {
        log.debug("live jobs: \(jobs.count, privacy: .public)")
        jobList.update(jobs)
        if let current = jobDetail.currentJobId {
            jobDetail.show(jobs.first { $0.id == current })
        }
    }
}

// MARK: - MotherCountsStrip

private class MotherCountsStrip: NSView {

    private let stack = NSStackView()
    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor  // noticeably lighter than bg

        // Visible bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        stack.orientation = .horizontal
        stack.spacing     = 28
        stack.alignment   = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Render immediately with zeros, then live updates
        render(MotherStatus())
        AppStore.shared.$motherStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.render(s) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func render(_ s: MotherStatus) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let items: [(String, String, Int, NSColor)] = [
            ("▶", "Running",  s.running,  Theme.sage),
            ("⏸", "Queued",   s.queued,   Theme.fgMuted),
            ("?", "Awaiting", s.awaiting, Theme.amber),
            ("!", "Failed",   s.failed,   Theme.redSweater),
        ]
        for (symbol, label, count, color) in items {
            stack.addArrangedSubview(chip(symbol: symbol, label: label, count: count, color: color))
        }
    }

    private func chip(symbol: String, label: String, count: Int, color: NSColor) -> NSView {
        let active = count > 0

        let sym = NSTextField(labelWithString: symbol)
        sym.font      = .systemFont(ofSize: 11)
        sym.textColor = active ? color : Theme.borderInactive

        let num = NSTextField(labelWithString: "\(count)")
        num.font      = .monospacedDigitSystemFont(ofSize: 16, weight: .light)
        num.textColor = active ? color : Theme.fgMuted

        let lbl = NSTextField(labelWithString: label)
        lbl.font      = .systemFont(ofSize: 10)
        lbl.textColor = active ? Theme.fgMuted : Theme.borderInactive

        let row = NSStackView(views: [sym, num, lbl])
        row.orientation = .horizontal
        row.spacing     = 4
        row.alignment   = .centerY
        return row
    }
}

// MARK: - MotherJobListViewModel

private class MotherJobListViewModel: ObservableObject {
    @Published var jobs: [MotherJob] = []
    var onSelect: ((MotherJob?) -> Void)?

    func rowModel(for job: MotherJob) -> MotherJobRowModel {
        MotherJobRowModel(
            id: job.id,
            state: job.state,
            title: job.title.isEmpty ? job.id : job.title,
            repo: job.repo.isEmpty ? nil : job.repo,
            branch: nil,                     // macOS MotherJob has no branch field
            question: job.question,
            relativeTimestamp: formattedTimestamp(for: job)
        )
    }

    private func formattedTimestamp(for job: MotherJob) -> String? {
        // Running jobs: show elapsed time since start.
        if job.state == "running", let started = job.startedAt {
            let secs = Int(Date().timeIntervalSince(started))
            if secs < 60   { return "\(secs)s" }
            if secs < 3600 { return "\(secs / 60)m" }
            return "\(secs / 3600)h\((secs % 3600) / 60)m"
        }
        // Others: relative time from most-recent timestamp.
        if let date = job.finishedAt ?? job.startedAt ?? job.createdAt {
            let secs = Int(Date().timeIntervalSince(date))
            if secs < 60   { return "\(secs)s ago" }
            if secs < 3600 { return "\(secs / 60)m ago" }
            return "\(secs / 3600)h ago"
        }
        return nil
    }
}

// MARK: - MotherJobListSwiftUI

private struct JobGroup: Identifiable {
    let state: String
    var jobs: [MotherJob]
    var id: String { state }
}

private struct MotherJobListSwiftUI: View {
    @ObservedObject var vm: MotherJobListViewModel
    @State private var selectedId: String?

    var body: some View {
        List(selection: $selectedId) {
            ForEach(groupedJobs) { group in
                Section(group.state.uppercased()) {
                    ForEach(group.jobs, id: \.id) { job in
                        NostromoKit.MotherJobRow(
                            model: vm.rowModel(for: job),
                            onArchive:    { AppStore.shared.archiveJob(job.id)     },
                            onCancel:     { AppStore.shared.cancelJob(job.id)      },
                            onRetry:      { AppStore.shared.retryJob(job.id)       },
                            onForceStart: { AppStore.shared.forceStartJob(job.id)  }
                        )
                        .tag(job.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: Theme.bg))
        .overlay {
            if vm.jobs.isEmpty {
                Text("No jobs")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedId) { _, newId in
            vm.onSelect?(vm.jobs.first { $0.id == newId })
        }
    }

    /// Jobs grouped by state, sorted: awaiting → running → queued/ready → failed → succeeded/cancelled.
    private var groupedJobs: [JobGroup] {
        let stateRank: [String: Int] = [
            "awaiting": 0, "running": 1, "queued": 2, "ready": 2,
            "failed": 3, "succeeded": 4, "cancelled": 4,
        ]
        let sorted = vm.jobs.sorted {
            let a = stateRank[$0.state] ?? 5
            let b = stateRank[$1.state] ?? 5
            if a != b { return a < b }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        var groups: [JobGroup] = []
        for job in sorted {
            if groups.last?.state == job.state {
                groups[groups.count - 1].jobs.append(job)
            } else {
                groups.append(JobGroup(state: job.state, jobs: [job]))
            }
        }
        return groups
    }
}

// MARK: - MotherJobList

private class MotherJobList: NSView {

    var onSelect: ((MotherJob?) -> Void)? {
        didSet { viewModel.onSelect = onSelect }
    }

    private let viewModel = MotherJobListViewModel()
    private var hostingView: NSHostingView<MotherJobListSwiftUI>!

    override init(frame: NSRect) {
        super.init(frame: frame)
        let swiftUIView = MotherJobListSwiftUI(vm: viewModel)
        hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ jobs: [MotherJob]) {
        viewModel.jobs = jobs
    }
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

private class MotherJobDetail: NSView {

    private(set) var currentJobId: String?

    // Stored once, toggled via isHidden
    private let emptyLabel = NSTextField(labelWithString: "Select a job")

    // Content fields
    private let titleLabel      = NSTextField(labelWithString: "")
    private let stateLabel      = NSTextField(labelWithString: "")
    private let phaseRibbonView = PhaseRibbonView()
    private var ribbonHeight:   NSLayoutConstraint!
    private let metaStack       = NSStackView()
    private let actionsContainer = NSView()  // rebuilt per job state
    private let logSectionLabel = NSTextField(labelWithString: "LOG TAIL")
    private let logScrollView   = NSScrollView()
    private let logTextView     = NSTextView()

    // Action widgets (created once, shown/hidden as needed)
    private let brokerBanner     = NSTextField(labelWithString: "⚠ Mother broker offline")
    private let replyScrollView  = NSScrollView()
    private let replyTextView    = NSTextView()
    private let answerButton     = NSButton(title: "Answer",      target: nil, action: nil)
    private let cancelButton     = NSButton(title: "Cancel job",  target: nil, action: nil)
    private let retryButton      = NSButton(title: "Retry",       target: nil, action: nil)
    private let forceStartButton = NSButton(title: "Force-start", target: nil, action: nil)
    private let archiveButton    = NSButton(title: "Archive",     target: nil, action: nil)
    private let archiveAllButton = NSButton(title: "Archive All", target: nil, action: nil)
    private let viewPlanButton   = NSButton(title: "View Plan",   target: nil, action: nil)
    private let actionErrorLabel = NSTextField(labelWithString: "")

    private var logTimer:         Timer?
    private var actionErrorTimer: Timer?
    private var currentJob:       MotherJob?
    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

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

        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers  = true
        logScrollView.drawsBackground     = false
        logScrollView.wantsLayer          = true
        logScrollView.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        logScrollView.layer?.cornerRadius    = 4
        logScrollView.documentView = logTextView

        for v in [titleLabel, stateLabel, phaseRibbonView, metaStack, actionsContainer,
                  logSectionLabel, logScrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Ribbon height toggles between 0 (hidden) and 22 (visible)
        ribbonHeight = phaseRibbonView.heightAnchor.constraint(equalToConstant: 0)
        ribbonHeight.isActive = true

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            // Phase ribbon — sits between state label and meta; height is 0 when hidden
            phaseRibbonView.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8),
            phaseRibbonView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            phaseRibbonView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            metaStack.topAnchor.constraint(equalTo: phaseRibbonView.bottomAnchor, constant: 8),
            metaStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // actionsContainer sits between metaStack and logSectionLabel.
            // Its height is determined by its content (zero when no actions).
            actionsContainer.topAnchor.constraint(equalTo: metaStack.bottomAnchor, constant: 12),
            actionsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            logSectionLabel.topAnchor.constraint(equalTo: actionsContainer.bottomAnchor, constant: 12),
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
        AppStore.shared.$brokerConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.updateBrokerBanner(connected) }
            .store(in: &cancellables)

        // Observe action errors from AppStore
        AppStore.shared.$motherActionError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] msg in self?.showActionError(msg) }
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
                    forceStartButton, archiveButton, archiveAllButton, viewPlanButton] {
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
        archiveAllButton.target = self
        archiveAllButton.action = #selector(didArchiveAll)
        viewPlanButton.target   = self
        viewPlanButton.action   = #selector(didViewPlan)

        // Error label (shown inline below buttons, auto-clears)
        actionErrorLabel.font      = .systemFont(ofSize: 10)
        actionErrorLabel.textColor = Theme.redSweater
        actionErrorLabel.lineBreakMode      = .byWordWrapping
        actionErrorLabel.maximumNumberOfLines = 3
        actionErrorLabel.isHidden  = true
    }

    // MARK: Public

    func show(_ job: MotherJob?) {
        logTimer?.invalidate(); logTimer = nil
        currentJob   = job
        currentJobId = job?.id
        replyTextView.string = ""

        guard let job else { showEmpty(); return }

        [titleLabel, stateLabel, metaStack, actionsContainer,
         logSectionLabel, logScrollView].forEach { $0.isHidden = false }
        emptyLabel.isHidden = true

        titleLabel.stringValue = job.title.isEmpty ? job.id : job.title
        stateLabel.stringValue = job.state.uppercased()
        stateLabel.textColor   = stateColor(job.state)

        updateRibbon(job)
        rebuildMeta(job)
        rebuildActions(job)
        loadLog(job)

        if job.state == "running" || job.state == "awaiting" {
            logTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self, let j = self.currentJob else { return }
                self.loadLog(j)
            }
        }
    }

    // MARK: Private

    private func showEmpty() {
        [titleLabel, stateLabel, phaseRibbonView, metaStack, actionsContainer,
         logSectionLabel, logScrollView].forEach { $0.isHidden = true }
        emptyLabel.isHidden = false
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

    private func rebuildActions(_ job: MotherJob) {
        // Remove all existing subviews and constraints from the container
        actionsContainer.subviews.forEach { $0.removeFromSuperview() }

        let connected = AppStore.shared.brokerConnected

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
            let btnRow = NSStackView(views: [retryButton, archiveButton])
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

        // Archive All — always present
        widgets.append(archiveAllButton)

        widgets.append(actionErrorLabel)

        // Disable action buttons when broker is offline
        for btn in [answerButton, cancelButton, retryButton,
                    forceStartButton, archiveButton, archiveAllButton, viewPlanButton] {
            btn.isEnabled = connected
        }
        // Archive and View Plan don't require broker — always enabled
        archiveButton.isEnabled    = true
        archiveAllButton.isEnabled = true
        viewPlanButton.isEnabled   = true

        guard !widgets.filter({ $0 !== actionErrorLabel || !$0.isHidden }).isEmpty else { return }

        // Stack widgets vertically inside actionsContainer
        let stack = NSStackView(views: widgets)
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
        archiveButton.isEnabled    = true
        archiveAllButton.isEnabled = true
        viewPlanButton.isEnabled   = true
    }

    private func showActionError(_ message: String) {
        actionErrorLabel.stringValue = message
        actionErrorLabel.isHidden    = false
        actionErrorTimer?.invalidate()
        actionErrorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.actionErrorLabel.isHidden = true
            self?.actionErrorLabel.stringValue = ""
            AppStore.shared.clearMotherActionError()
        }
    }

    // MARK: - Button actions

    @objc private func didTapAnswer() {
        guard let job = currentJob else { return }
        let text = replyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AppStore.shared.answerJob(job.id, text: text)
        replyTextView.string = ""
    }

    @objc private func didTapCancel() {
        guard let job = currentJob else { return }
        AppStore.shared.cancelJob(job.id)
    }

    @objc private func didTapRetry() {
        guard let job = currentJob else { return }
        AppStore.shared.retryJob(job.id)
    }

    @objc private func didForceStart() {
        guard let job = currentJob else { return }
        let alert = NSAlert()
        alert.messageText = "Force-start \"\(job.title.isEmpty ? job.id : job.title)\"?"
        alert.informativeText = "This runs the job now even if quota is over cap, at full tier (ignoring conservative posture). It consumes headroom shared with other jobs and interactive sessions."
        alert.addButton(withTitle: "Force-start")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            AppStore.shared.forceStartJob(job.id)
        }
    }

    @objc private func didArchive() {
        guard let job = currentJob else { return }
        AppStore.shared.archiveJob(job.id)
    }

    @objc private func didArchiveAll() {
        let alert = NSAlert()
        alert.messageText = "Archive all terminal-state jobs?"
        alert.informativeText = "This archives every succeeded, failed, and cancelled job immediately."
        alert.addButton(withTitle: "Archive All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppStore.shared.archiveAllJobs()
        }
    }

    @objc private func didViewPlan() {
        guard let path = currentJob?.planPath, !path.isEmpty else { return }
        AppStore.shared.openPlan(path: path)
    }

    private func rebuildMeta(_ job: MotherJob) {
        metaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

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

        for (key, value) in pairs {
            metaStack.addArrangedSubview(metaRow(key: key, value: value))
        }
    }

    private func metaRow(key: String, value: String) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font      = .systemFont(ofSize: 10, weight: .medium)
        k.textColor = Theme.fgMuted
        k.setContentHuggingPriority(.required, for: .horizontal)

        let v = NSTextField(labelWithString: value)
        v.font          = Theme.monoFont
        v.textColor     = Theme.fg
        v.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [k, v])
        row.orientation = .horizontal
        row.spacing     = 8
        row.alignment   = .firstBaseline
        return row
    }

    private func loadLog(_ job: MotherJob) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.mother/logs/\(job.id).log"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let tail    = content.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentJobId == job.id else { return }
                self.setLog(tail)
            }
        }
    }

    private func setLog(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.monoFont, .foregroundColor: Theme.fgMuted,
        ]
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        let end = NSRange(location: logTextView.textStorage?.length ?? 0, length: 0)
        logTextView.scrollRangeToVisible(end)
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
