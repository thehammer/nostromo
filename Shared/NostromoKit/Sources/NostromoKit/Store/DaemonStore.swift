// NostromoKit — DaemonStore.swift
//
// @MainActor ObservableObject that owns a NetworkClient and routes ServerMsg
// into observable state consumed by SwiftUI views.
//
// DaemonStore is the single source of truth for the iOS app:
//   - sessions: [String: SessionInfo]  keyed by tag
//   - connected: Bool                  forwarded from NetworkClient
//
// When a SessionListResp arrives (reply to the implicit session_list request
// sent after subscribe), the sessions dict is fully replaced.
// SessionState messages update individual entries in place.
// SessionDown/SessionExited mark sessions as not-alive.

import Foundation
import Combine

@MainActor
public final class DaemonStore: ObservableObject {

    // MARK: - Public state

    /// All known sessions, keyed by tag.  Updated by `session_list_resp` and
    /// `session_state` messages.
    @Published public private(set) var sessions: [String: SessionInfo] = [:]

    /// Sorted session list for list views (stable order by tag).
    public var sessionList: [SessionInfo] {
        sessions.values.sorted { $0.tag < $1.tag }
    }

    /// All known Mother jobs. Updated by `mother_jobs` broadcasts.
    @Published public private(set) var motherJobs: [MotherJob] = []

    /// Live peek snapshots keyed by job id.  Updated by `mother_peek` broadcasts.
    /// An entry is cleared when its todos array arrives empty (terminal transition).
    @Published public private(set) var motherPeeks: [String: MotherPeekSnapshot] = [:]

    /// Perri PR review queue. Updated by `perri_state` broadcasts.
    @Published public private(set) var perriQueue: [PrQueueItem] = []

    /// Perri current-PR detail snapshot. Updated by `perri_state` broadcasts.
    @Published public private(set) var perriCurrentPr: PrSnapshot? = nil

    /// Fred mailbox snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredMailbox: MailboxSnapshot? = nil

    /// Fred calendar snapshot. Updated by `fred_state` broadcasts; nil until first broadcast.
    @Published public private(set) var fredCalendar: CalendarSnapshot? = nil

    /// Latest Teri todos snapshot. Updated by `teri_state` broadcasts.
    @Published public private(set) var teriTodos: TeriTodosSnapshot? = nil

    /// Daemon-served focus registry, keyed by tag.
    @Published public private(set) var focuses: [String: FocusMeta] = [:]

    /// Per-focus layout models, keyed by session tag.
    /// Updated by `focus_layout` (structural) and `pane_content` (content-only) broadcasts.
    @Published public private(set) var focusLayouts: [String: FocusLayoutModel] = [:]

    /// Focuses grouped + ordered for list rendering.
    public var focusRows: [FocusRow] { buildFocusRows(Array(focuses.values)) }

    /// Whether the daemon connection is currently alive.
    @Published public private(set) var connected: Bool = false

    // MARK: - Dependencies

    public let client: NetworkClient

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(client: NetworkClient) {
        self.client = client
        bind()
    }

    // MARK: - Lifecycle

    public func start() {
        client.start()
    }

    public func stop() {
        client.stop()
    }

    /// Request a fresh `SessionListResp` from the daemon.  Views can call this
    /// on pull-to-refresh; the response arrives via the normal message stream.
    public func refreshSessions() {
        client.send(ClientSessionList())
    }

    /// Request a fresh `FocusListResp` from the daemon.
    public func refreshFocuses() {
        client.send(ClientFocusList())
    }

    /// Send a Mother job action to the daemon.
    ///
    /// The daemon shells out to `mother <action> <job_id>` and re-broadcasts
    /// a fresh `mother_jobs` snapshot.  Valid action strings: `"cancel"`,
    /// `"retry"`, `"force_start"`.
    public func motherAction(jobId: String, action: String) {
        client.send(ClientMotherAction(jobId: jobId, action: action))
    }

    /// Resume an awaiting Mother job by supplying the operator's answer.
    ///
    /// The daemon shells out to `mother resume <job_id> <answer>` and
    /// re-broadcasts a fresh `mother_jobs` snapshot.
    public func motherResume(jobId: String, answer: String) {
        client.send(ClientMotherResume(jobId: jobId, answer: answer))
    }

    // MARK: - Bindings

    private func bind() {
        // Forward connection state.
        client.$connected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                self?.connected = isConnected
                if isConnected {
                    // Request the current session list immediately after connecting.
                    self?.client.send(ClientSessionList())
                    // Request the focus registry immediately after connecting.
                    self?.client.send(ClientFocusList())
                } else {
                    // Clear stale state on disconnect so the list doesn't show
                    // ghost entries if the daemon is restarted.
                    self?.sessions       = [:]
                    self?.focuses        = [:]
                    self?.focusLayouts   = [:]
                    self?.motherJobs     = []
                    self?.motherPeeks    = [:]
                    self?.perriQueue     = []
                    self?.perriCurrentPr = nil
                    self?.fredMailbox    = nil
                    self?.fredCalendar   = nil
                    self?.teriTodos      = nil
                }
            }
            .store(in: &cancellables)

        // Route incoming server messages.
        client.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] msg in
                self?.handle(msg)
            }
            .store(in: &cancellables)
    }

    // MARK: - Message handling

    private func handle(_ msg: ServerMsg) {
        switch msg {

        case .sessionListResp(let list):
            // Replace the full sessions dict with the fresh snapshot.
            sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.tag, $0) })

        case .sessionState(let tag, let state):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         state != .crashed,
                remoteControl: info.remoteControl,
                state:         state,
                stopReason:    info.stopReason
            )
            sessions[tag] = info

        case .sessionDown(let tag, let reason):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         false,
                remoteControl: info.remoteControl,
                state:         .idle,
                stopReason:    reason
            )
            sessions[tag] = info

        case .sessionExited(let tag, _):
            guard var info = sessions[tag] else { return }
            info = SessionInfo(
                tag:           info.tag,
                agentName:     info.agentName,
                viewName:      info.viewName,
                sessionId:     info.sessionId,
                alive:         false,
                remoteControl: info.remoteControl,
                state:         .idle,
                stopReason:    info.stopReason
            )
            sessions[tag] = info

        case .sessionSpawned(let tag, let sessionId):
            if var info = sessions[tag] {
                info = SessionInfo(
                    tag:           info.tag,
                    agentName:     info.agentName,
                    viewName:      info.viewName,
                    sessionId:     sessionId ?? info.sessionId,
                    alive:         true,
                    remoteControl: info.remoteControl,
                    state:         info.state,
                    stopReason:    nil
                )
                sessions[tag] = info
            }
            // Re-request the list to pick up any new sessions.
            client.send(ClientSessionList())

        case .focusListResp(let list), .focusRegistryUpdated(let list):
            focuses = Dictionary(uniqueKeysWithValues: list.map { ($0.tag, $0) })

        case .motherJobs(let jobs):
            motherJobs = jobs

        case .motherPeek(let snap):
            if snap.todos.isEmpty {
                motherPeeks.removeValue(forKey: snap.jobId)
            } else {
                motherPeeks[snap.jobId] = snap
            }

        case .perriState(let queue, let current):
            perriQueue     = queue
            perriCurrentPr = current

        case .fredState(let mailbox, let calendar):
            fredMailbox  = mailbox
            fredCalendar = calendar

        case .teriState(let snap):
            teriTodos = snap

        case .focusLayout(let tag, let tree, let focusedPane):
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            model.tree        = tree
            model.focusedPane = focusedPane
            focusLayouts[tag] = model

        case .paneContent(let tag, let paneId, let content):
            var model = focusLayouts[tag] ?? FocusLayoutModel.initial
            model.paneContent[paneId] = content
            focusLayouts[tag] = model

        case .focusCreated(let meta):
            // Register the new focus in the focus registry.
            focuses[meta.tag] = meta.toFocusMeta()
            // Seed the layout model so the tab appears immediately.
            if focusLayouts[meta.tag] == nil {
                focusLayouts[meta.tag] = FocusLayoutModel.initial
            }

        default:
            break
        }
    }

    // MARK: - Perri actions

    /// Load a specific PR into the Perri current-PR view.
    ///
    /// The daemon shells out to `perri load_pr -- <number> <repo>` and the
    /// native source re-broadcasts a fresh `perri_state` snapshot.
    public func perriLoadPr(number: Int, repo: String) {
        client.send(ClientPerriAction(action: "load_pr", prNumber: number, repo: repo))
    }

    /// Clear the current PR from the Perri view.
    ///
    /// The daemon shells out to `perri clear_current_pr` and the native source
    /// re-broadcasts a fresh `perri_state` snapshot.
    public func perriClear() {
        client.send(ClientPerriAction(action: "clear", prNumber: nil, repo: nil))
    }

    /// Approve a PR from the iOS queue row.
    ///
    /// The daemon resolves the HEAD sha, posts `gh pr review --approve`, then
    /// writes the Phase 1 approval signal (approvals.jsonl + queue.dirty) so
    /// the PR is suppressed on the next broadcast — identical instant-removal
    /// behaviour to the desk `submit-review` flow.
    ///
    /// **Always gate this call behind a `confirmationDialog`** — the user must
    /// explicitly confirm before anything is posted to GitHub.
    public func perriApprove(number: Int, repo: String) {
        client.send(ClientPerriAction(action: "approve", prNumber: number, repo: repo))
    }
}

