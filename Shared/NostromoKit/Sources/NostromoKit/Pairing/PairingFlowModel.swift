// NostromoKit — PairingFlowModel.swift
//
// The pairing flow as a state machine, so the rules the PRD and Ada's sign-offs pin down are tested
// in Kit rather than only seen in views:
//
//   D4  `PairCheck` runs first. Expired, wrong and can't-reach show before the confirmation step, and
//       the check never uses up the code. A refusal on **Pair** after a good check shows the matching
//       failure and keeps the name the operator edited.
//   D6  With a stored credential the phone proves it knows this server (an HMAC over the server's
//       challenge, never the token) on the SAME socket it later pairs on:
//         knows_device == true   -> the replace line; stop the old client; Pair { replace: true }
//         false or no answer     -> the warning line; wipe content; stop the old client;
//                                   Pair { replace: false }; then ask the old server to forget us
//         no credential          -> a fresh pairing, no proof sent
//       If Pair fails, the old credential stays and the old client is restarted.
//   D1  A Local Network refusal is its own failure and never uses up the code.

import Foundation

public enum PairingFailure: Equatable {
    case expired
    case invalid
    case unreachable
    case localNetworkDenied
    /// The server paired us but the Keychain refused the token.
    case notSaved
    /// The address is not one the phone can open a socket to (a malformed host).
    case badAddress
}

/// What pairing will do to the pairing this device already has.
public enum PairingReplacement: Equatable {
    case none
    /// The server proved it knows this device: the new pairing replaces the old one.
    case sameServer
    /// Anything else: the old server is left behind and the device's content is removed.
    case differentServer(oldAddress: String, oldPort: UInt16)
}

public struct PairingConfirmation: Equatable {
    public let address: String
    public let port: UInt16
    public let code: String
    public let offer: PairOffer
    public let existing: PairingReplacement
}

public enum PairingStep: Equatable {
    case idle
    case checking
    case confirming(PairingConfirmation)
    case pairing(PairingConfirmation)
    case succeeded(name: String)
    /// `confirmation` is set when the check had passed (the operator's name is kept for a retry).
    case failed(PairingFailure, address: String, confirmation: PairingConfirmation?)
}

/// The socket the flow talks to; `PairingClient` is the real one.
@MainActor
public protocol PairingServer: AnyObject {
    var isOpen: Bool { get }
    func check(code: String, proof: String?) async throws -> PairOffer
    func pair(code: String, name: String, kind: DeviceKindWire, replace: Bool) async throws -> PairedResult
    func close()
}

extension PairingClient: PairingServer {}

/// What the app does around a pairing: the clients and content it owns.
@MainActor
public protocol PairingSideEffects: AnyObject {
    /// The address the paired client is using now, if any.
    var currentServer: (address: String, port: UInt16)? { get }
    func stopCurrentClient()
    func restartCurrentClient()
    /// `DaemonStore.wipeAll()`.
    func wipeContent()
    /// Opens a short authenticated socket to the old server with the old credential and sends
    /// `DeviceUnpairSelf` (5 s budget). Unreachable is fine: the old entry goes stale.
    func unpairFromOldServer(address: String, port: UInt16, credential: DeviceCredential) async
    /// The new pairing is saved: build the client for it.
    func didPair(_ credential: DeviceCredential, address: String, port: UInt16)
}

@MainActor
public final class PairingFlowModel: ObservableObject {

    @Published public private(set) var step: PairingStep = .idle
    /// The Name field; pre-filled from the offer, then the operator's. Kept across a failure.
    @Published public var name: String = ""

    public let kind: DeviceKindWire
    private let credentials: DeviceCredentialStore
    private let makeServer: (String, UInt16) -> PairingServer
    private let effects: PairingSideEffects

    private var server: PairingServer?
    private var oldCredential: DeviceCredential?

    public init(kind: DeviceKindWire, credentials: DeviceCredentialStore,
                effects: PairingSideEffects, makeServer: @escaping (String, UInt16) -> PairingServer) {
        self.kind = kind
        self.credentials = credentials
        self.effects = effects
        self.makeServer = makeServer
    }

    /// "iPhone" or "iPad".
    public var kindName: String { kind == .ipad ? "iPad" : "iPhone" }

    // MARK: - Steps

    /// Checks the code with the server, then shows the confirmation (D4). Never uses the code up.
    public func begin(address: String, port: UInt16, code: String) async {
        server?.close()
        step = .checking
        let server = makeServer(address, port)
        self.server = server
        // The old token is only ever used against the address this device was paired at. With no
        // saved address there is no old pairing to replace or to tell: never fall back to the new
        // address (a link's), which could be a hostile server asking for the token.
        let current = effects.currentServer
        oldCredential = current == nil ? nil : credentials.load()
        do {
            var offer = try await server.check(code: code, proof: nil)
            var existing = PairingReplacement.none
            if let old = oldCredential, let current {
                // Prove we know this server, on this socket, without sending the token (D6).
                let proof = PairingClient.proof(token: old.token, challenge: offer.challenge, code: code)
                offer = try await server.check(code: code, proof: proof)
                if offer.knowsDevice == true {
                    existing = .sameServer
                } else {
                    existing = .differentServer(oldAddress: current.address, oldPort: current.port)
                }
            }
            if name.isEmpty { name = offer.nameHint ?? kindName }
            step = .confirming(PairingConfirmation(address: address, port: port, code: code,
                                                   offer: offer, existing: existing))
        } catch {
            server.close()
            self.server = nil
            step = .failed(Self.failure(error), address: address, confirmation: nil)
        }
    }

    /// **Pair**: redeems the code with the operator's name.
    public func confirm() async {
        guard case .confirming(let confirmation) = step, let server else { return }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        step = .pairing(confirmation)

        // A replace needs the proof socket. If its 60 s are up, the proof is gone: start over
        // rather than pair without replacing.
        if confirmation.existing == .sameServer, !server.isOpen {
            step = .failed(.unreachable, address: confirmation.address, confirmation: confirmation)
            return
        }

        switch confirmation.existing {
        case .none: break
        case .sameServer: effects.stopCurrentClient()
        case .differentServer:
            effects.wipeContent()
            effects.stopCurrentClient()
        }

        do {
            let paired = try await server.pair(code: confirmation.code,
                                               name: finalName.isEmpty ? kindName : finalName,
                                               kind: kind,
                                               replace: confirmation.existing == .sameServer)
            if case .differentServer(let oldAddress, let oldPort) = confirmation.existing, let old = oldCredential {
                await effects.unpairFromOldServer(address: oldAddress, port: oldPort, credential: old)
            }
            let credential = DeviceCredential(token: paired.token.value, deviceId: paired.deviceId,
                                              serverId: paired.serverId, name: paired.name)
            do { try credentials.save(credential) } catch {
                step = .failed(.notSaved, address: confirmation.address, confirmation: confirmation)
                return
            }
            self.server = nil
            effects.didPair(credential, address: confirmation.address, port: confirmation.port)
            step = .succeeded(name: paired.name)
        } catch {
            // The old credential is untouched; bring the old client back.
            if confirmation.existing != .none { effects.restartCurrentClient() }
            self.server = nil
            step = .failed(Self.failure(error), address: confirmation.address, confirmation: confirmation)
        }
    }

    /// Leaves a failure for the entry screen (address and code stay where the operator typed them).
    public func reset() {
        server?.close()
        server = nil
        step = .idle
    }

    private static func failure(_ error: Error) -> PairingFailure {
        switch error as? PairingError {
        case .expired: return .expired
        case .invalid: return .invalid
        case .localNetworkDenied: return .localNetworkDenied
        case .badAddress: return .badAddress
        case .unreachable, nil: return .unreachable
        }
    }
}
