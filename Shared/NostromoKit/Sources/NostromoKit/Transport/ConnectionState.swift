// NostromoKit — ConnectionState.swift
//
// What the WebSocket client tells the app about its link, and the one function that decides it
// (`ConnectionFailure.state`). PRD-AC22 is the rule this file guards: only the server saying "you
// are not paired" (an `Unauthorized` frame or close code 4001) ever moves the app to
// `notPaired`. A timeout, a refused connection, DNS, TLS, a dropped socket or an HTTP error at the
// upgrade is `unreachable`, however long it lasts, because it tells us nothing about the pairing.

import Foundation
import Network

public enum ConnectionState: Equatable {
    case connecting
    case connected
    /// The server cannot be reached (VPN off, host down, wrong address). Pairing is untouched.
    case unreachable
    /// iOS's Local Network permission blocks reaching the address (D1). Never a pairing problem.
    case localNetworkDenied
    /// The server said this device is not (or no longer) paired. The only way into the
    /// no-longer-paired screen.
    case notPaired(reason: String)
}

/// How one connection attempt or live socket ended, before it is turned into a `ConnectionState`.
public enum ConnectionFailure: Equatable {
    /// An `Unauthorized { reason }` frame.
    case unauthorizedFrame(reason: String)
    /// The server closed the socket with this WebSocket close code.
    case closed(code: Int)
    /// The upgrade request was answered with this HTTP status instead of 101.
    case httpStatus(Int)
    /// The transport failed below HTTP (refused, timed out, DNS, TLS, network down, reset).
    case transport(URLError.Code)
    /// The address has no `ws://` URL (a malformed host). Nothing was sent anywhere.
    case badAddress
    /// The local-network probe says iOS is blocking the address.
    case localNetworkDenied
    /// Anything else.
    case other

    /// The server's close code for "not paired".
    public static let unauthorizedCloseCode = 4001

    /// The only classification rule. Table-tested (`ConnectionClassificationTests`).
    public var state: ConnectionState {
        switch self {
        case .unauthorizedFrame(let reason):
            return .notPaired(reason: reason)
        case .closed(let code) where code == Self.unauthorizedCloseCode:
            return .notPaired(reason: "unauthorized")
        case .localNetworkDenied:
            return .localNetworkDenied
        case .closed, .httpStatus, .transport, .badAddress, .other:
            return .unreachable
        }
    }

    /// Whether the failure happened before the server answered, so iOS's Local Network gate could be
    /// the cause and the probe is worth asking.
    var mayBeLocalNetworkPolicy: Bool {
        switch self {
        case .transport, .other: return true
        case .unauthorizedFrame, .closed, .httpStatus, .badAddress, .localNetworkDenied: return false
        }
    }
}

// MARK: - Local Network probe (D1)

/// Asks whether iOS's Local Network permission is what stops us reaching `host:port`.
public protocol LocalNetworkProbing: Sendable {
    func isDenied(host: String, port: UInt16) async -> Bool
}

extension LocalNetworkProbing {
    /// The failure to record once a connection attempt failed with `failure`: the failure itself,
    /// or `.localNetworkDenied` when it could have been the permission and the probe says it was.
    func refine(_ failure: ConnectionFailure, host: String, port: UInt16) async -> ConnectionFailure {
        guard failure.mayBeLocalNetworkPolicy else { return failure }
        return await isDenied(host: host, port: port) ? .localNetworkDenied : failure
    }
}

/// The real probe: a throwaway `NWConnection`. When the permission is off, Network.framework parks
/// the connection in `.waiting` with a DNS policy-denied error instead of connecting.
public struct NWLocalNetworkProbe: LocalNetworkProbing {
    /// `kDNSServiceErr_PolicyDenied`, what Network.framework reports for a Local Network denial.
    static let policyDeniedCode: Int32 = -65570

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 3) { self.timeout = timeout }

    /// Pure: is `error` the Local Network denial?
    public static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDeniedCode }
        return false
    }

    public func isDenied(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(false, cancelling: connection)
                case .waiting(let error), .failed(let error):
                    once.finish(Self.isPolicyDenied(error), cancelling: connection)
                default:
                    break
                }
            }
            let queue = DispatchQueue(label: "com.hammer.nostromo.localnetprobe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.finish(false, cancelling: connection) }
        }
    }

    /// Resumes the continuation exactly once, from whichever callback fires first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func finish(_ value: Bool, cancelling connection: NWConnection) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            connection.cancel()
            pending.resume(returning: value)
        }
    }
}
