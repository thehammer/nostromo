// NostromoKit — PendingDecision.swift
//
// A daemon-driven decision request awaiting the operator's answer
// (`nostromo.ask_decision`, ios-curated-view-parity W3). Ported from
// `macOS/Nostromo/Data/Models.swift`'s `PendingDecision` — macOS keeps its
// own copy (the two clients decode their own wire types independently), so
// this is a deliberate duplication, not a shared source of truth.
//
// `contextPaneId` is carried through but rendered nowhere in this wedge —
// deferred; see the wedge's plan for why.

import Foundation

public struct PendingDecision: Equatable, Identifiable {
    /// `requestId` doubles as the `Identifiable` id — a decision request's
    /// identity on the wire already IS its request id, so a second id
    /// scheme would just be one more thing that could disagree with it.
    public var id: String { requestId }

    public let tag: String
    public let requestId: String
    public let prompt: String
    public let detail: String?
    public let choices: [DecisionChoice]
    public let contextPaneId: String?

    public init(
        tag: String,
        requestId: String,
        prompt: String,
        detail: String?,
        choices: [DecisionChoice],
        contextPaneId: String?
    ) {
        self.tag = tag
        self.requestId = requestId
        self.prompt = prompt
        self.detail = detail
        self.choices = choices
        self.contextPaneId = contextPaneId
    }
}
