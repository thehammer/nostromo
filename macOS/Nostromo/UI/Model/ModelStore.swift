import Foundation
import Combine
import NostromoKit

/// The model catalogue as the daemon last sent it: families cheapest first.
struct ModelCatalogState: Equatable {
    var families: [ModelFamilyWire]
    /// The last probe failed; these are the families an earlier one saw.
    var stale: Bool
    var fetchedAt: String?
}

/// Per-agent defaults and what each agent declares.
struct ModelDefaultsState: Equatable {
    var defaults: [String: AgentModelDefaultWire]
    var declared: [String: String]
}

/// The answer to a `session_model_set` / `model_default_set` of this connection.
struct ModelRequestResultWire: Equatable {
    var requestId: String
    var status: ModelRequestStatusWire
    var code: String?
    var message: String?
    var warning: String?
}

/// Something to tell the user about one focus's model: a switch that did not take.
struct ModelSwitchFailure: Equatable {
    /// Increases with every failure the store records, so a view can tell a new one from the
    /// one it already showed.
    let id: Int
    let message: String
}

/// What the store asks of the daemon connection. `NostromodClient` is the real one;
/// tests pass a recorder.
protocol ModelRequestSending: AnyObject {
    func modelCatalogRequest()
    func modelCatalogRefresh()
    func modelDefaultsRequest()
    func sessionModelGet(tag: String)
    func sessionModelSet(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool, requestId: String)
    func modelDefaultSet(agent: String, model: String?, effort: String?, clear: Bool, requestId: String)
}

extension NostromodClient: ModelRequestSending {}

/// Every focus's model state, the catalogue and the per-agent defaults, fed by `AppStore`.
/// One instance per app (`shared`), so every window's chip binds to the same values: a
/// switch made in one window, by an agent or by a script reaches them all from the one
/// frame the daemon broadcasts.
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    /// The latest `SessionModelState` per focus tag. A tag the daemon never sent a state for
    /// (a restricted or hidden session) is absent, and its chip stays hidden.
    @Published private(set) var states: [String: SessionModelStateWire] = [:]
    @Published private(set) var catalog: ModelCatalogState?
    @Published private(set) var defaults: ModelDefaultsState?
    @Published private(set) var isConnected = false
    /// The most recent answer to a request of this connection.
    @Published private(set) var lastResult: ModelRequestResultWire?
    /// The latest failed switch per focus, until a view dismisses it.
    @Published private(set) var failures: [String: ModelSwitchFailure] = [:]

    var sender: ModelRequestSending?
    private let makeRequestId: () -> String
    private var nextFailureId = 0
    /// Requests of this connection not yet answered, oldest first, and the focus each was for.
    private var outstanding: [(requestId: String, tag: String)] = []
    /// Request ids whose outcome was already reported, oldest first: the focus's next
    /// `last_request` repeats them and must not be reported twice.
    private var reportedRequestIds: [String] = []
    private static let rememberedRequests = 64

    init(sender: ModelRequestSending? = nil, makeRequestId: @escaping () -> String = { UUID().uuidString }) {
        self.sender = sender
        self.makeRequestId = makeRequestId
    }

    /// Take one decoded daemon frame; frames that are not model frames are ignored.
    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .sessionModelState(let state):
            let previous = states[state.tag]
            states[state.tag] = state
            noteLastRequest(of: state, previous: previous)

        case .modelCatalog(let families, let stale, let fetchedAt):
            catalog = ModelCatalogState(families: families.sorted { $0.rank < $1.rank },
                                        stale: stale, fetchedAt: fetchedAt)

        case .modelDefaults(let defaults, let declared):
            self.defaults = ModelDefaultsState(defaults: defaults, declared: declared)

        case .modelRequestResult(let requestId, let status, let code, let message, let warning):
            lastResult = ModelRequestResultWire(requestId: requestId, status: status, code: code,
                                                message: message, warning: warning)
            reportResult(requestId: requestId, status: status, code: code, message: message)

        default:
            break
        }
    }

    /// The daemon connection came up (or went away). A new connection starts by asking for
    /// the catalogue and the defaults; the per-focus states are replayed by the daemon
    /// when the connection subscribes to the `model` topic.
    func connectionChanged(_ connected: Bool) {
        isConnected = connected
        guard connected else { return }
        sender?.modelCatalogRequest()
        sender?.modelDefaultsRequest()
    }

    func state(for tag: String) -> SessionModelStateWire? {
        states[tag]
    }

    /// Ask the daemon to switch `tag`'s model and/or effort; returns the request id. `nil`
    /// keeps the current value and `"default"` resets the effort. The outcome arrives as the
    /// focus's next `SessionModelState`, and as a `ModelRequestResult` in `lastResult`.
    @discardableResult
    func requestSwitch(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool = false) -> String {
        let requestId = makeRequestId()
        outstanding.append((requestId, tag))
        if outstanding.count > Self.rememberedRequests { outstanding.removeFirst() }
        sender?.sessionModelSet(tag: tag, model: model, effort: effort,
                                setAsAgentDefault: setAsAgentDefault, requestId: requestId)
        return requestId
    }

    /// Set `agent`'s default model (and effort) for new focuses. The daemon answers with a
    /// `ModelDefaults` frame, which updates `defaults`. Existing focuses are not touched.
    @discardableResult
    func setDefault(agent: String, model: String, effort: String?) -> String {
        let requestId = makeRequestId()
        sender?.modelDefaultSet(agent: agent, model: model, effort: effort, clear: false, requestId: requestId)
        return requestId
    }

    /// Remove `agent`'s default: its new focuses fall back to the agent's own `model:`, then
    /// the CLI default.
    @discardableResult
    func clearDefault(agent: String) -> String {
        let requestId = makeRequestId()
        sender?.modelDefaultSet(agent: agent, model: nil, effort: nil, clear: true, requestId: requestId)
        return requestId
    }

    /// What a new focus of `agent` starts on, ignoring any choice made in the create sheet:
    /// the per-agent default, else the agent's declared model. `nil` model: the CLI default.
    func resolvedStart(agent: String) -> (model: String?, effort: String?) {
        if let d = defaults?.defaults[agent] { return (d.model, d.effort) }
        return (defaults?.declared[agent], nil)
    }

    /// Drop everything held for a focus that was closed.
    func forget(tag: String) {
        states.removeValue(forKey: tag)
        failures.removeValue(forKey: tag)
    }

    func failure(for tag: String) -> ModelSwitchFailure? {
        failures[tag]
    }

    /// A view is done with a failure. Only the one it showed goes: a newer failure stays.
    func dismissFailure(tag: String, id: Int) {
        guard failures[tag]?.id == id else { return }
        failures.removeValue(forKey: tag)
    }

    // MARK: - Failures

    /// The answer to one of this store's own requests. A failure is reported for the focus the
    /// request was made for; a request still waiting for its turn to end stays outstanding.
    private func reportResult(requestId: String, status: ModelRequestStatusWire, code: String?, message: String?) {
        guard let index = outstanding.firstIndex(where: { $0.requestId == requestId }) else { return }
        let tag = outstanding[index].tag
        if status == .pendingTurnEnd || status == .awaitingUser { return }
        outstanding.remove(at: index)
        let text = status == .unchanged
            ? ModelPresentation.requestedButNotRunning(state: states[tag])
            : ModelPresentation.failureMessage(status: status, code: code, message: message)
        guard let text else { return }
        reportedRequestIds.append(requestId)
        if reportedRequestIds.count > Self.rememberedRequests { reportedRequestIds.removeFirst() }
        fail(tag: tag, message: text)
    }

    /// A focus's `last_request` that changed to a failure: a script's or an agent's request, or
    /// one of ours the result frame has not reported. The first state of a focus (the replay on
    /// subscribe) is history, not news.
    private func noteLastRequest(of state: SessionModelStateWire, previous: SessionModelStateWire?) {
        guard previous != nil, let last = state.lastRequest, last != previous?.lastRequest,
              let text = ModelPresentation.failureMessage(status: last.status, code: nil, message: nil)
        else { return }
        if let id = last.requestId,
           outstanding.contains(where: { $0.requestId == id }) || reportedRequestIds.contains(id) {
            return
        }
        fail(tag: state.tag, message: text)
    }

    private func fail(tag: String, message: String) {
        nextFailureId += 1
        failures[tag] = ModelSwitchFailure(id: nextFailureId, message: message)
    }
}
