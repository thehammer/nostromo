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
/// One instance per app (`shared`), so every window's chip binds to the same values.
///
/// (Skeleton: filled in by the implementation step of M2.)
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var states: [String: SessionModelStateWire] = [:]
    @Published private(set) var catalog: ModelCatalogState?
    @Published private(set) var defaults: ModelDefaultsState?
    @Published private(set) var isConnected = false
    @Published private(set) var lastResult: ModelRequestResultWire?

    var sender: ModelRequestSending?
    private let makeRequestId: () -> String

    init(sender: ModelRequestSending? = nil, makeRequestId: @escaping () -> String = { UUID().uuidString }) {
        self.sender = sender
        self.makeRequestId = makeRequestId
    }

    /// Take one decoded daemon frame; frames that are not model frames are ignored.
    func ingest(_ msg: ServerMsg) {}

    /// The daemon connection came up (or went away). On a new connection, ask for the
    /// catalogue and the defaults.
    func connectionChanged(_ connected: Bool) {}

    func state(for tag: String) -> SessionModelStateWire? { nil }

    /// Ask the daemon to switch `tag`'s model and/or effort; returns the request id.
    @discardableResult
    func requestSwitch(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool = false) -> String { "" }

    /// Drop everything held for a focus that was closed.
    func forget(tag: String) {}
}
