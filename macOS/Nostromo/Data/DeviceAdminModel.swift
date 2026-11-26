import Combine
import Foundation

/// What the model needs of the daemon connection. `NostromodClient` is the real one; tests pass a fake.
/// Every verb goes over the existing Unix socket to the local daemon (which relays to the primary).
protocol DeviceAdminTransport: AnyObject {
    func devicePairStart(requestId: String)
    func devicePairCancel(requestId: String, pairingId: String)
    func deviceList(requestId: String)
    func deviceRevoke(requestId: String, device: String)
}

extension NostromodClient: DeviceAdminTransport {}

/// Every sentence the device windows show. One place, so the Q2 rule (nothing mentions mail,
/// calendar or todos except the one Pair-window line) can be checked by a scan.
enum DeviceAdminCopy {
    static let sharingLine = "Mail, calendar and todos aren't shared from your Macs in this version."
    static let unreachable = "Can't reach your Nostromo server, so this Mac can't make a pairing code right now."
    static let unreachableList = "Can't reach your Nostromo server."
    static let lostConnection = "Lost the connection to your Nostromo server, so this code no longer works."
    static let waitingForServer = "Waiting for the server\u{2026}"
    static let expired = "This code expired"
    static let lockedOut = "Too many wrong attempts. This code is no longer valid"
    static let saveFailed = "The device paired but couldn't be saved. Make a new code and try again."
    static let issueFailed = "Couldn't make a pairing code. Try again."
    static let readOnly = "Changes are turned off on this Mac."
    static let off = "Device management is turned off on this Mac."
    static let wasConnected = "Disconnected just now"
    static let wasNotConnected = "Wasn't connected. It will be refused the next time it tries."
    static let replaced = "Replaced by re-pairing"
    static let notAUserAction = "That didn't come from a click or key press in this window, so nothing was sent. Try again."

    static func pairingOff(pairFrom: [String]) -> String {
        let command = "run `nostromo device pair` on your server."
        guard let host = pairFrom.first else { return "Pairing new devices is turned off on this Mac. Pair by running `nostromo device pair` on your server." }
        return "Pairing new devices is turned off on this Mac. Pair from \(host) or \(command)"
    }

    static func revokeConfirmation(name: String) -> String {
        "Revoke \(name)? It will be disconnected immediately and will need to pair again."
    }

    static func paired(name: String) -> String { "Paired: \(name)" }

    /// The unavailable sentence for a state where no code can be made.
    static func blocked(_ availability: DeviceAdminModel.Availability, pairFrom: [String]) -> String {
        switch availability {
        case .available: return ""
        case .serverUnreachable, .daemonNotRunning: return unreachable
        case .revokeOnly: return pairingOff(pairFrom: pairFrom)
        case .readOnly: return readOnly
        case .off: return off
        }
    }

    static func countdown(until expiresAt: Date, now: Date = Date()) -> String {
        let s = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return "Expires in \(s / 60):" + String(format: "%02d", s % 60)
    }

    /// `123456` → `123 456`.
    static func groupedCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 3).map { i -> String in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(3, code.count - i))])
        }.joined(separator: " ")
    }

    static func lastSeen(_ device: DeviceSummary, now: Date = Date()) -> String {
        if device.connected { return "Connected now" }
        guard let seen = device.lastSeenAt else { return "Never connected" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last seen " + f.localizedString(for: seen, relativeTo: now)
    }

    static func revokedLabel(_ device: DeviceSummary, now: Date = Date()) -> String {
        if device.revokedBy == "replaced" { return replaced }
        guard let at = device.revokedAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Revoked " + f.localizedString(for: at, relativeTo: now)
    }
}

/// A pairing the daemon issued to this model. Never printed: `description` hides the code.
struct DevicePairingInfo: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let pairingId: String
    let code: String
    let serverUrl: String
    let expiresAt: Date
    var description: String { "DevicePairingInfo(<redacted>)" }
    var debugDescription: String { description }
}

/// Device administration as the Mac app shows it: the device list, and the one pairing session the Pair
/// window runs. Holds no wire detail; the daemon relays to the primary, and refusals arrive as frames.
final class DeviceAdminModel: ObservableObject {

    enum Availability: Equatable {
        case available, serverUnreachable, daemonNotRunning, revokeOnly, readOnly, off
    }

    enum PairState: Equatable {
        case idle
        case issuing
        case showing(DevicePairingInfo)
        case paired(name: String)
        case expired
        case lockedOut
        case connectionLost
        /// The code was redeemed but the device could not be saved.
        case failed
        /// The primary or the daemon refused to make a code (or the pairing ended in a way this build does
        /// not know): the generic "couldn't make a pairing code" sentence.
        case issueFailed
        /// No code can be made; the window says why, from `adminAvailability`.
        case blocked
    }

    @Published private(set) var devices: [DeviceSummary] = []
    @Published private(set) var hasList = false
    @Published private(set) var level: DeviceAdminLevelWire?
    @Published private(set) var connected = false
    @Published private(set) var devicesSupported = false
    @Published private(set) var lastError: String?
    /// Why the last Pair or Revoke press sent nothing (it was not a person's own input); nil otherwise.
    @Published private(set) var gestureNotice: String?
    @Published private(set) var pair: PairState = .idle
    /// Per-device text after a revoke, keyed by device id.
    @Published private(set) var revokeStatus: [String: String] = [:]

    private weak var transport: DeviceAdminTransport?
    private let makeId: () -> String
    private var pendingPairRequest: String?
    private var cancelledPairRequests = Set<String>()
    private var pendingRevokes: [String: String] = [:]

    init(transport: DeviceAdminTransport?, makeId: @escaping () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.makeId = makeId
    }

    // MARK: State

    var adminAvailability: Availability {
        if !connected { return .daemonNotRunning }
        if !devicesSupported || lastError == "server_unreachable" { return .serverUnreachable }
        switch level?.level {
        case nil: return lastError == "not_permitted_on_this_mac" ? .revokeOnly : .available
        case "full": return .available
        case "revoke_only": return .revokeOnly
        case "off": return .off
        // `read_only`, and any level this build does not know: never open a control for it.
        default: return .readOnly
        }
    }

    var pairFrom: [String] { level?.pairFrom ?? [] }

    var canPair: Bool { adminAvailability == .available }
    var canRevoke: Bool { adminAvailability == .available || adminAvailability == .revokeOnly }
    /// New Code works only while the connection is up and this Mac may pair.
    var canRequestNewCode: Bool { canPair }

    var activeDevices: [DeviceSummary] { devices.filter { !$0.isRevoked } }
    var revokedDevices: [DeviceSummary] {
        devices.filter(\.isRevoked).sorted { ($0.revokedAt ?? .distantPast) > ($1.revokedAt ?? .distantPast) }
    }

    // MARK: Connection

    func connectionChanged(connected: Bool, devicesSupported: Bool) {
        self.connected = connected
        self.devicesSupported = connected && devicesSupported
        lastError = nil
        pendingRevokes.removeAll()
        if !connected {
            level = nil
            switch pair {
            case .issuing, .showing: pair = .connectionLost
            default: break
            }
            pendingPairRequest = nil
        }
    }

    // MARK: Pairing

    /// Ask for a code. `gesture` is the verdict of `HumanGesture.permit`; anything but a person's own
    /// input sends nothing.
    func beginPairing(gesture: HumanGestureVerdict) {
        let availability = adminAvailability
        guard availability == .available else {
            pair = .blocked
            probeIfStale(availability)
            return
        }
        guard case .human = gesture else {
            refuseGesture()
            return
        }
        gestureNotice = nil
        cancelOpenPairing()
        let id = makeId()
        pendingPairRequest = id
        pair = .issuing
        transport?.devicePairStart(requestId: id)
    }

    /// Cancel and forget the open pairing (the window closed, or Cancel). Leaves nothing open.
    func cancelPairing() {
        cancelOpenPairing()
        pair = .idle
    }

    private func cancelOpenPairing() {
        if case .showing(let info) = pair {
            transport?.devicePairCancel(requestId: makeId(), pairingId: info.pairingId)
        }
        if let pending = pendingPairRequest {
            cancelledPairRequests.insert(pending)
            pendingPairRequest = nil
        }
    }

    /// The Pair window came to the front. After a refusal or an unreachable answer, ask again: the answer
    /// tells whether the server is back (or still gone).
    func windowBecameKey() {
        probeIfStale(adminAvailability)
    }

    /// While the Pair window waits for the server, ask again (it calls this every few seconds). Nothing is
    /// asked once the window is closed (`idle`).
    func probeWhileWaiting() {
        guard lastError == "server_unreachable", pair != .idle else { return }
        requestList()
    }

    // MARK: Devices

    func requestList() {
        guard connected, devicesSupported else { return }
        transport?.deviceList(requestId: makeId())
    }

    func revoke(deviceId: String, gesture: HumanGestureVerdict) {
        guard case .human = gesture else {
            refuseGesture()
            return
        }
        guard canRevoke else { return }
        gestureNotice = nil
        let id = makeId()
        pendingRevokes[id] = deviceId
        revokeStatus[deviceId] = "Revoking\u{2026}"
        transport?.deviceRevoke(requestId: id, device: deviceId)
    }

    // MARK: Frames

    func handle(_ msg: ServerMsg) {
        switch msg {
        case .devicePairing(let w): handlePairing(w)
        case .devicePairOutcome(let w): handleOutcome(w)
        case .devices(let w):
            devices = w.devices
            hasList = true
            if lastError == "server_unreachable" { lastError = nil }
            settleBlockedPair()
        case .deviceRevoked(let w):
            guard pendingRevokes.removeValue(forKey: w.requestId) != nil else { return }
            revokeStatus[w.deviceId] = w.wasConnected ? DeviceAdminCopy.wasConnected : DeviceAdminCopy.wasNotConnected
        case .deviceAdminError(let w): handleError(w)
        case .deviceAdminLevel(let w):
            level = w
            if lastError == "not_permitted_on_this_mac" || lastError == "server_unreachable" { lastError = nil }
            settleBlockedPair()
        default: break
        }
    }

    private func handlePairing(_ w: DevicePairingWire) {
        if cancelledPairRequests.remove(w.requestId) != nil {
            // The window closed before the code arrived: it must not stay open on the primary.
            transport?.devicePairCancel(requestId: makeId(), pairingId: w.pairingId)
            return
        }
        guard w.requestId == pendingPairRequest, case .issuing = pair else { return }
        pendingPairRequest = nil
        pair = .showing(DevicePairingInfo(pairingId: w.pairingId, code: w.code, serverUrl: w.serverUrl,
                                          expiresAt: w.expiresAt))
    }

    private func handleOutcome(_ w: DevicePairOutcomeWire) {
        guard case .showing(let info) = pair, info.pairingId == w.pairingId else { return }
        switch w.outcome {
        case .paired: pair = .paired(name: w.name ?? "")
        case .expired: pair = .expired
        case .cancelled: pair = .idle
        case .lockedOut: pair = .lockedOut
        case .connectionLost:
            // On a satellite the local socket stays up while the uplink to the primary is gone: nothing can be
            // asked of the server until an answer comes back (D3).
            pair = .connectionLost
            lastError = "server_unreachable"
            requestList()
        case .failed: pair = .failed
        case .unknown: pair = .issueFailed
        }
    }

    private func handleError(_ w: DeviceAdminErrorWire) {
        if w.requestId == pendingPairRequest {
            pendingPairRequest = nil
            switch w.reason {
            case "server_unreachable", "not_permitted_on_this_mac":
                lastError = w.reason
                pair = .blocked
            default:
                // `too_many_pairings`, `devices_unavailable`, or a reason this build does not know.
                pair = .issueFailed
            }
            return
        }
        cancelledPairRequests.remove(w.requestId)
        if let deviceId = pendingRevokes.removeValue(forKey: w.requestId) {
            switch w.reason {
            case "server_unreachable":
                lastError = w.reason
                revokeStatus[deviceId] = nil
            case "not_permitted_on_this_mac":
                revokeStatus[deviceId] = DeviceAdminCopy.readOnly
            case "unknown_device":
                revokeStatus[deviceId] = "This device is already gone."
            default:
                revokeStatus[deviceId] = "Couldn't revoke this device. Try again."
            }
            return
        }
        if w.reason == "server_unreachable" || w.reason == "connection_lost" { lastError = "server_unreachable" }
    }

    // MARK: Private

    /// Say so when a press was not a person's own input, instead of doing nothing silently.
    private func refuseGesture() {
        gestureNotice = DeviceAdminCopy.notAUserAction
        ActivationAudit.note("devices:gesture-refused")
    }

    /// Below `full` (or after an error) the app cannot tell a Mac that may not pair from a satellite whose
    /// uplink dropped (the satellite forgets its level and tells no local client). A `DeviceList` is allowed
    /// at revoke-only and read-only, and the answer says which it is: `server_unreachable` or the list.
    private func probeIfStale(_ availability: Availability) {
        switch availability {
        case .revokeOnly, .readOnly, .serverUnreachable: requestList()
        case .available, .off, .daemonNotRunning: break
        }
    }

    /// A blocked window whose block lifted (the server answered) goes back to asking for a code.
    private func settleBlockedPair() {
        if pair == .blocked, adminAvailability == .available { pair = .idle }
    }
}
