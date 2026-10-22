// NostromoKit — MotherDecisionStore.swift
//
// The answered-once state of one job's current decision. A decision is answered at most
// once: after a send starts, nothing else may be sent for that decision id unless the send
// failed. The view reads this state; it never decides on its own whether a send is allowed.
//
// `override_open` (the PR is opened with red gates recorded as overridden) takes a second
// step: its first click only moves the store to `.confirming`, and `request` refuses it
// from any other state.

import Foundation

/// Why a send failed, in terms the store cares about. The Mac maps its broker errors onto these.
public enum BrokerErrorKind: Equatable {
    case noSuchJob, invalidState, unauthorized, unavailable, timeout, disconnected, other
}

public enum MotherDecisionSendState: Equatable {
    case idle
    /// `override_open` only, after its first click.
    case confirming(MotherDecisionOptionID)
    case sending(MotherDecisionOptionID)
    case sent(MotherDecisionOptionID)
    case failed(MotherDecisionOptionID, BrokerErrorKind)
}

/// What to send for one answer. The job id is the caller's.
public struct MotherDecisionCommand: Equatable {
    public let decisionId: String
    public let option: MotherDecisionOptionID
    /// Trimmed; present only when the option takes text.
    public let text: String?
}

/// The send state of one job's current decision. The Mac keeps one per job.
public struct MotherDecisionStore: Equatable {

    /// An operator note, not a document.
    public static let maxTextLength = 4_000

    /// Non-empty once trimmed, and at most `maxTextLength` characters.
    public static func textIsSendable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxTextLength
    }

    public private(set) var decisionId: String?
    public private(set) var state: MotherDecisionSendState = .idle

    public init() {}

    /// Follow the job's decision. None, or a resolved one, clears everything; an open one
    /// with a different id starts over; the same id keeps its state.
    public mutating func sync(decision: MotherDecision?) {
        guard let decision, decision.isOpen else {
            decisionId = nil
            state = .idle
            return
        }
        if decision.id != decisionId {
            decisionId = decision.id
            state = .idle
        }
    }

    /// Whether `request` would return a command.
    public func canSend(option: MotherDecisionOption, text: String) -> Bool {
        guard decisionId != nil else { return false }
        if option.takesText && !Self.textIsSendable(text) { return false }
        switch state {
        case .sending, .sent:
            return false
        case .confirming(let confirming):
            return option.id != .overrideOpen || confirming == .overrideOpen
        case .idle, .failed:
            return option.id != .overrideOpen
        }
    }

    /// The first click of a two-step option. False (and no change) while sending or sent.
    public mutating func beginConfirm(option: MotherDecisionOptionID) -> Bool {
        guard decisionId != nil else { return false }
        switch state {
        case .sending, .sent:
            return false
        case .idle, .failed, .confirming:
            state = .confirming(option)
            return true
        }
    }

    public mutating func cancelConfirm() {
        if case .confirming = state { state = .idle }
    }

    /// The command to send, or nil when this decision must not be sent to now.
    public mutating func request(option: MotherDecisionOption, text: String) -> MotherDecisionCommand? {
        guard canSend(option: option, text: text), let decisionId else { return nil }
        state = .sending(option.id)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return MotherDecisionCommand(decisionId: decisionId, option: option.id,
                                     text: option.takesText ? trimmed : nil)
    }

    /// The broker accepted the answer. A late result for an older decision is ignored.
    public mutating func succeeded(decisionId id: String) {
        guard id == decisionId, case .sending(let option) = state else { return }
        state = .sent(option)
    }

    /// The send failed; `request` is allowed again.
    public mutating func failed(decisionId id: String, kind: BrokerErrorKind) {
        guard id == decisionId, case .sending(let option) = state else { return }
        state = .failed(option, kind)
    }
}
