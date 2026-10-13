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

    var sender: ModelRequestSending?
    private let makeRequestId: () -> String

    init(sender: ModelRequestSending? = nil, makeRequestId: @escaping () -> String = { UUID().uuidString }) {
        self.sender = sender
        self.makeRequestId = makeRequestId
    }

    /// Take one decoded daemon frame; frames that are not model frames are ignored.
    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .sessionModelState(let state):
            states[state.tag] = state

        case .modelCatalog(let families, let stale, let fetchedAt):
            catalog = ModelCatalogState(families: families.sorted { $0.rank < $1.rank },
                                        stale: stale, fetchedAt: fetchedAt)

        case .modelDefaults(let defaults, let declared):
            self.defaults = ModelDefaultsState(defaults: defaults, declared: declared)

        case .modelRequestResult(let requestId, let status, let code, let message, let warning):
            lastResult = ModelRequestResultWire(requestId: requestId, status: status, code: code,
                                                message: message, warning: warning)

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
        sender?.sessionModelSet(tag: tag, model: model, effort: effort,
                                setAsAgentDefault: setAsAgentDefault, requestId: requestId)
        return requestId
    }

    /// Drop everything held for a focus that was closed.
    func forget(tag: String) {
        states.removeValue(forKey: tag)
    }
}
