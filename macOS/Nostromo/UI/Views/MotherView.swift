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
    /// One line under the strip; zero height unless the "staying quiet" note is raised.
    private let notifyNote  = MotherNotifyNoteRow()
    private let jobList     = MotherJobList()
    /// Right-hand side: one closable tab per opened job, plus a fixed
    /// "Overview" tab holding the empty state. See docs/plans/mother-pane.md (P2).
    private var tabRegion: TabRegionView!
    private var jobDetails: [String: MotherJobDetail] = [:]
    static let overviewPaneId = "mother_overview"
    static func tabPaneId(for jobId: String) -> String { "mother_job:\(jobId)" }

    /// Posted after `requestedJobId` is set, to open that job's tab in a Mother view that exists.
    static let openJobNotification = Notification.Name("nostromo.mother.openJob")
    /// A job to open as soon as a Mother view has it in its list (a "queued as Mother job"
    /// marker was clicked). Cleared once opened.
    static var requestedJobId: String?

    /// Posted after `requestedFilterTag` is set ("Show My Jobs"), for the Mother view in the key window.
    static let showJobsNotification = Notification.Name("nostromo.mother.showJobs")
    /// The focus tag whose jobs a Mother view should filter to. Cleared once applied.
    static var requestedFilterTag: String?
    private static var requestGeneration = 0
    /// How long an unconsumed "Show My Jobs" request stays pending.
    static var requestLifetime: TimeInterval = 1.0

    /// "Show My Jobs": record the tag, let the caller switch the window to the Mother focus (so a Mother
    /// view created by the switch finds the tag), then tell the Mother views to look.
    static func requestShowJobs(tag: String, afterRequest switchToMother: () -> Void) {
        requestedFilterTag = tag
        switchToMother()
        NotificationCenter.default.post(name: showJobsNotification, object: nil)
        // Views apply on the main queue (the sinks hop there; a new view applies when it joins a window), so
        // give them a moment, then drop a request nobody consumed: a later view must not apply a filter nobody asked for.
        requestGeneration += 1
        let generation = requestGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + requestLifetime) {
            if generation == requestGeneration { requestedFilterTag = nil }
        }
    }

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

        let overview = MotherOverviewView()
        tabRegion = TabRegionView(
            tabs: [TabRegionView.Tab(paneId: Self.overviewPaneId, label: "Overview", view: overview)],
            activePaneId: Self.overviewPaneId, compactTabs: true)
        tabRegion.onCloseTab = { [weak self] paneId in self?.closeJobTab(paneId) }
        // Mirror the active tab in the list highlight (Overview clears it).
        tabRegion.onSelectTab = { [weak self] paneId in
            guard let self else { return }
            if paneId.hasPrefix("mother_job:") {
                self.jobList.select(jobId: String(paneId.dropFirst("mother_job:".count)))
            } else {
                self.jobList.clearSelection()
            }
        }

        for v in [countsStrip, notifyNote, jobList, divider, tabRegion] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Counts strip — full width, fixed height, anchored to top
            countsStrip.topAnchor.constraint(equalTo: topAnchor),
            countsStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            countsStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            countsStrip.heightAnchor.constraint(equalToConstant: 36),

            // Note row — full width, zero height unless raised
            notifyNote.topAnchor.constraint(equalTo: countsStrip.bottomAnchor),
            notifyNote.leadingAnchor.constraint(equalTo: leadingAnchor),
            notifyNote.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Job list — fixed width left pane
            jobList.topAnchor.constraint(equalTo: notifyNote.bottomAnchor),
            jobList.leadingAnchor.constraint(equalTo: leadingAnchor),
            jobList.widthAnchor.constraint(equalToConstant: 280),
            jobList.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Divider — 1px, full height of content area
            divider.topAnchor.constraint(equalTo: notifyNote.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: jobList.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Job tabs — fill remaining width
            tabRegion.topAnchor.constraint(equalTo: notifyNote.bottomAnchor),
            tabRegion.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tabRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Wire selection
        jobList.onSelect = { [weak self] job in
            guard let job else { return }
            self?.openJobTab(job)
        }

        NotificationCenter.default.publisher(for: Self.openJobNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.openRequestedJob(in: AppStore.shared.motherJobs) }
            .store(in: &cancellables)

        // "Show My Jobs": applied by the Mother view in the key window only, so each window keeps its own filter.
        NotificationCenter.default.publisher(for: Self.showJobsNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRequestedFilter() }
            .store(in: &cancellables)

        AppStore.shared.$motherAnnotations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] annotations in self?.jobList.update(annotations: annotations) }
            .store(in: &cancellables)

        // A rename or removal reaches rows and detail lines in the same run-loop turn as the publish.
        jobList.onOriginsChanged = { [weak self] in self?.refreshDetailOrigins() }

        // Live data — empty state shows until first jobs arrive
        AppStore.shared.$motherJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.jobsDidChange(jobs) }
            .store(in: &cancellables)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRequestedFilter()
    }

    private func applyRequestedFilter() {
        jobList.applyShowJobsRequest(isKeyWindow: window?.isKeyWindow == true)
    }

    private func refreshDetailOrigins() {
        for (id, detail) in jobDetails { applyOrigin(to: detail, jobId: id) }
    }

    private func applyOrigin(to detail: MotherJobDetail, jobId: String) {
        let origin = jobList.originDisplay(forJobId: jobId)
        let tag = origin.isClickable ? origin.focusTag : nil
        detail.setOrigin(origin, onTap: tag.map { tag in { [weak jobList] in jobList?.openFocus(tag: tag) } })
    }

    private func jobsDidChange(_ jobs: [MotherJob]) {
        log.debug("live jobs: \(jobs.count, privacy: .public)")
        jobList.update(jobs)
        openRequestedJob(in: jobs)
        // Keep every open tab current. A job that left the queue (archived,
        // pruned) keeps its tab, showing the empty state, rather than the tab
        // vanishing under the reader.
        // `update` applies only what changed: it never clears the reader's draft or moves their log.
        for (id, detail) in jobDetails {
            detail.update(jobs.first { $0.id == id })
        }
    }

    /// `jobs` is passed in: a `@Published` sink runs before the property holds the new value.
    private func openRequestedJob(in jobs: [MotherJob]) {
        guard let id = Self.requestedJobId, let job = jobs.first(where: { $0.id == id }) else { return }
        Self.requestedJobId = nil
        openJobTab(job)
    }

    private func openJobTab(_ job: MotherJob) {
        let paneId = Self.tabPaneId(for: job.id)
        if tabRegion.hasTab(paneId) {
            tabRegion.selectTab(paneId)
            return
        }
        let detail = MotherJobDetail(host: AppStore.shared)
        detail.select(job)
        applyOrigin(to: detail, jobId: job.id)
        jobDetails[job.id] = detail
        let label = job.title.isEmpty ? job.id : job.title
        tabRegion.addTab(TabRegionView.Tab(paneId: paneId, label: label, view: detail))
    }

    private func closeJobTab(_ paneId: String) {
        guard paneId.hasPrefix("mother_job:") else { return }
        let jobId = String(paneId.dropFirst("mother_job:".count))
        jobDetails.removeValue(forKey: jobId)?.select(nil)   // stop its log timer
        tabRegion.removeTab(paneId)
        jobList.clearSelection()   // so the same row can be clicked to reopen it
    }
}

// MARK: - MotherOverviewView

/// The Mother pane's fixed first tab: shown when no job tab is open.
private class MotherOverviewView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "Select a job")
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.fgMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - MotherCountsStrip

private class MotherCountsStrip: NSView {

    private let chips = MotherCountsChips()
    private let daemonLabel = NSTextField.boundedLabel("", maxLines: 1, truncating: true)
    private let startButton = NSButton()
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

        chips.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            chips.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Daemon status, right-aligned: a dot + label, and a Start button when it is down.
        daemonLabel.font = .systemFont(ofSize: 10)
        daemonLabel.translatesAutoresizingMaskIntoConstraints = false
        startButton.title = "Start"
        startButton.bezelStyle = .inline
        startButton.font = .systemFont(ofSize: 10, weight: .medium)
        startButton.target = self
        startButton.action = #selector(startDaemon)
        startButton.isHidden = true
        startButton.translatesAutoresizingMaskIntoConstraints = false
        let daemonStack = NSStackView(views: [daemonLabel, startButton])
        daemonStack.orientation = .horizontal
        daemonStack.spacing = 10
        daemonStack.alignment = .centerY
        daemonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(daemonStack)   // hidden Start is detached by the stack, so the label sits flush right
        NSLayoutConstraint.activate([
            daemonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            daemonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        renderDaemon(AppStore.shared.motherDaemon)
        AppStore.shared.$motherDaemon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in self?.renderDaemon(d) }
            .store(in: &cancellables)

        // Render immediately with zeros, then live updates. The "needs you" chip reads the
        // app-wide aggregator, so the strip and the Dock badge agree.
        render(AppStore.shared.motherStatus, needsYou: AppStore.shared.needsYou.mother)
        AppStore.shared.$motherStatus
            .combineLatest(AppStore.shared.$needsYou)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s, needsYou in self?.render(s, needsYou: needsYou.mother) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func startDaemon() { AppStore.shared.startMotherDaemon() }

    private func renderDaemon(_ d: MotherDaemonState) {
        let color: NSColor
        switch d {
        case .running:     color = Theme.sage
        case .stopped:     color = Theme.redSweater
        default:           color = Theme.fgMuted
        }
        let dot = NSAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 9)])
        let text = NSAttributedString(string: d.label, attributes: [.foregroundColor: Theme.fgMuted, .font: NSFont.systemFont(ofSize: 10)])
        let all = NSMutableAttributedString(attributedString: dot)
        all.append(text)
        daemonLabel.attributedStringValue = all
        if case .running(let detail) = d, !detail.isEmpty { daemonLabel.toolTip = detail } else { daemonLabel.toolTip = nil }
        startButton.isHidden = !d.isStopped
    }

    private func render(_ s: MotherStatus, needsYou: Int) {
        var shown = s
        shown.needsYou = needsYou
        chips.render(shown)
    }
}

// MARK: - MotherNotifyNoteRow

/// "Mother is staying quiet because Nostromo is open, but Nostromo can't show notifications."
/// One dismissible line below the counts strip. Hidden at zero height unless the store raised it.
private final class MotherNotifyNoteRow: NSView {
    private static let visibleHeight: CGFloat = 24

    private let label = NSTextField(labelWithString: MotherNotifyNote.text)
    private let dismissButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.amber
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = MotherNotifyNote.text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dismissButton.title = "Dismiss"
        dismissButton.bezelStyle = .inline
        dismissButton.font = .systemFont(ofSize: 10, weight: .medium)
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel("Dismiss the notifications note")
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(dismissButton)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dismissButton.leadingAnchor, constant: -10),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(visible: AppStore.shared.motherNotifyNoteVisible)
        AppStore.shared.$motherNotifyNoteVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply(visible: $0) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func apply(visible: Bool) {
        isHidden = !visible
        heightConstraint.constant = visible ? Self.visibleHeight : 0
    }

    @objc private func dismiss() { AppStore.shared.dismissMotherNotifyNote() }
}

// MARK: - MotherJobListViewModel

final class MotherJobListViewModel: ObservableObject {
    /// Written by the owner to move the list's highlight (nil clears it, so a
    /// row whose tab was closed can be clicked — and so reopened — again).
    @Published var requestedSelection: String?
    @Published var jobs: [MotherJob] = []
    /// Who queued each job (the daemon's note), by job id.
    @Published var annotations: [String: MotherJobAnnotation] = [:]
    /// The open focuses, as of the last `FocusStore` publish.
    @Published private(set) var focuses: [Focus]
    /// The `From:` selection. Belongs to this list (one per window); never persisted.
    @Published var filter: MotherOriginSelection = .all
    var onSelect: ((MotherJob?) -> Void)?
    /// Called after a change that can alter an origin line (annotations, a rename, a removal).
    var onOriginsChanged: (() -> Void)?
    /// Jump to the focus with this tag. Default: select it in the key window.
    var openFocus: (String) -> Void = { tag in
        guard let focus = FocusStore.shared.focuses.first(where: { $0.sessionTag == tag }) else { return }
        AppStore.shared.focusSelectionRequests.send(focus)
    }

    private var cancellables = Set<AnyCancellable>()

    init(focusStore: FocusStore = .shared) {
        focuses = focusStore.focuses
        // No `receive(on:)`: the new names land in the same run-loop turn as the publish. The sink
        // runs before the store property holds the value, so it uses the value it is handed.
        focusStore.$focuses
            .dropFirst()
            .sink { [weak self] focuses in
                self?.focuses = focuses
                self?.onOriginsChanged?()
            }
            .store(in: &cancellables)
    }

    /// Applies a pending "Show My Jobs" request, only if this list's window is the key window. Another
    /// window's list leaves the request (and its own filter) alone.
    func applyShowJobsRequest(isKeyWindow: Bool) {
        guard isKeyWindow, let tag = MotherView.requestedFilterTag else { return }
        MotherView.requestedFilterTag = nil
        filter = .focus(tag: tag)
    }

    func setAnnotations(_ new: [String: MotherJobAnnotation]) {
        guard new != annotations else { return }
        annotations = new
        onOriginsChanged?()
    }

    /// The app's current name for a focus tag; nil when it is not an open focus.
    func currentName(forTag tag: String) -> String? {
        focuses.first { $0.sessionTag == tag }?.displayName
    }

    func originDisplay(forJobId id: String) -> MotherOriginDisplay {
        MotherOriginDisplay.make(annotation: annotations[id], currentName: { [self] in currentName(forTag: $0) })
    }

    /// The jobs the list shows, grouped, with the pop-up entries and counts.
    var filtered: MotherJobFilterResult {
        MotherJobFilter.apply(jobs: jobs, annotations: annotations, selection: filter,
                              currentName: { [self] in currentName(forTag: $0) })
    }

    func rowModel(for job: MotherJob) -> MotherJobRowModel {
        let progress = job.state == "running" || job.state == "awaiting"
            ? MotherProgressLine.make(progress: job.crew.progress, gates: job.crew.gates) : nil
        return MotherJobRowModel(
            id: job.id,
            state: job.state,
            title: job.title.isEmpty ? job.id : job.title,
            repo: job.repo.isEmpty ? nil : job.repo,
            branch: nil,                     // macOS MotherJob has no branch field
            question: job.question,
            relativeTimestamp: formattedTimestamp(for: job),
            progressLine: progress?.text,
            attentionBadges: MotherAttentionBadges.make(job.crew.attention).filter { !$0.acked }.map(\.label),
            progressAccessibility: progress?.accessibility,
            showsProgressLine: true,
            origin: originDisplay(forJobId: job.id)
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

private struct MotherJobListSwiftUI: View {
    @ObservedObject var vm: MotherJobListViewModel
    @State private var selectedId: String?

    var body: some View {
        let result = vm.filtered
        VStack(spacing: 0) {
            MotherFromHeader(vm: vm, result: result)
            list(result)
        }
    }

    private func list(_ result: MotherJobFilterResult) -> some View {
        List(selection: $selectedId) {
            ForEach(result.groups) { group in
                Section(group.state.uppercased()) {
                    ForEach(group.jobs, id: \.id) { job in
                        NostromoKit.MotherJobRow(
                            model: vm.rowModel(for: job),
                            onArchive:    { AppStore.shared.archiveJob(job.id) },
                            onCancel:     { AppStore.shared.cancelJob(job.id) },
                            onRetry:      { AppStore.shared.retryJob(job.id) },
                            onForceStart: { AppStore.shared.forceStartJob(job.id) },
                            onOriginTap: originTapAction(for: job)
                        )
                        .tag(job.id)
                        .contextMenu {
                            let m = vm.rowModel(for: job)
                            if m.isDone {
                                Button("Archive") { AppStore.shared.archiveJob(job.id) }
                            } else {
                                Button("Cancel Job")     { AppStore.shared.cancelJob(job.id) }
                                Button("Force Start")    { AppStore.shared.forceStartJob(job.id) }
                            }
                            if job.state == "failed" || job.state == "cancelled" {
                                Button("Retry") { AppStore.shared.retryJob(job.id) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: Theme.bg))
        .overlay {
            switch result.emptyState {
            case .none:
                EmptyView()
            case .noJobs(let text):
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            case .noMatch(let text):
                VStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Show all") { vm.filter = .all }
                }
                .padding(.horizontal, 16)
            }
        }
        .onChange(of: selectedId) { _, newId in
            vm.onSelect?(vm.jobs.first { $0.id == newId })
        }
        .onChange(of: vm.requestedSelection) { _, id in
            if selectedId != id { selectedId = id }
        }
    }

    /// A clickable origin (an open focus) jumps to that focus; anything else is plain text.
    private func originTapAction(for job: MotherJob) -> (() -> Void)? {
        let origin = vm.originDisplay(forJobId: job.id)
        guard origin.isClickable, let tag = origin.focusTag else { return nil }
        return { vm.openFocus(tag) }
    }
}

/// `From: All ▾`, and once something is picked `· N of M` and a clear button. 24 pt, left-aligned.
struct MotherFromHeader: View {
    @ObservedObject var vm: MotherJobListViewModel
    let result: MotherJobFilterResult

    /// The picker's label truncates past this so `× · N of M` always fits a 280 pt list.
    static let pickerMaxWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 6) {
            Text("From:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("From", selection: $vm.filter) {
                ForEach(result.entries, id: \.selection) { entry in
                    Text(entry.title).tag(entry.selection)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 0, idealWidth: Self.pickerMaxWidth, maxWidth: Self.pickerMaxWidth, alignment: .leading)
            .layoutPriority(-1)
            .accessibilityLabel("From")
            if vm.filter != .all {
                Text("· \(result.matched) of \(result.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                Button { vm.filter = .all } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityLabel("Show all jobs")
                    .help("Show all jobs")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}

// MARK: - MotherJobList

private final class MotherJobList: NSView {

    func select(jobId: String) { viewModel.requestedSelection = jobId }

    /// Clear the highlight. `requestedSelection` is usually already nil, which
    /// SwiftUI would not report as a change, so go via a non-matching value.
    func clearSelection() {
        viewModel.requestedSelection = ""
        DispatchQueue.main.async { [weak self] in self?.viewModel.requestedSelection = nil }
    }

    var onSelect: ((MotherJob?) -> Void)? {
        didSet { viewModel.onSelect = onSelect }
    }

    private let viewModel = MotherJobListViewModel()
    var onOriginsChanged: (() -> Void)? {
        didSet { viewModel.onOriginsChanged = onOriginsChanged }
    }
    func applyShowJobsRequest(isKeyWindow: Bool) { viewModel.applyShowJobsRequest(isKeyWindow: isKeyWindow) }
    func originDisplay(forJobId id: String) -> MotherOriginDisplay { viewModel.originDisplay(forJobId: id) }
    func openFocus(tag: String) { viewModel.openFocus(tag) }
    func update(annotations: [String: MotherJobAnnotation]) { viewModel.setAnnotations(annotations) }
    private var hostingView: NSHostingView<MotherJobListSwiftUI>!

    override init(frame: NSRect) {
        super.init(frame: frame)
        let swiftUIView = MotherJobListSwiftUI(vm: viewModel)
        hostingView = NSHostingView(rootView: swiftUIView)
        // Sized by the four edge pins below, never by the job rows' own ideal/min size (see
        // `PaneContentNSView.init`: a SwiftUI hosting view's default sizing options can make
        // the whole window content larger than a full-screen window).
        hostingView.sizingOptions = []
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        // Archive All — borderless button pinned to the bottom of the list pane
        let btn = NSButton()
        btn.title        = ""
        btn.isBordered   = false
        btn.bezelStyle   = .rounded
        btn.font         = .systemFont(ofSize: 10)
        btn.attributedTitle = NSAttributedString(
            string: "Archive All",
            attributes: [.foregroundColor: Theme.fgMuted, .font: NSFont.systemFont(ofSize: 10)]
        )
        btn.target = self
        btn.action = #selector(didTapArchiveAll)
        btn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(btn)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: btn.topAnchor, constant: -8),

            btn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            btn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            btn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ jobs: [MotherJob]) {
        viewModel.jobs = jobs
    }

    @objc private func didTapArchiveAll() {
        let alert = NSAlert()
        alert.messageText    = "Archive all terminal-state jobs?"
        alert.informativeText = "This archives every succeeded, failed, and cancelled job immediately."
        alert.addButton(withTitle: "Archive All")
        alert.addButton(withTitle: "Cancel")
        // Sheet, not alert.runModal() — a free-floating modal has no window
        // association and can strand on another Space with the main thread
        // blocked waiting on it (looks exactly like a hang).
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                AppStore.shared.archiveAllJobs()
            }
        }
    }
}
