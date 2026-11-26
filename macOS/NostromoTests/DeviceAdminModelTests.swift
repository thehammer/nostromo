import XCTest

// Device administration as the Mac app shows it: the pairing session of the Pair window and the Devices
// list. The model talks to a fake transport that records what would go to the daemon; frames are fed to
// `handle` the way the client delivers them.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 a code shown before the matching `device_pairing`      -> testNoCodeIsShownUntilTheCodeForThisRequestArrives
//   M2 a late code for a cancelled request left open          -> testALateCodeForACancelledRequestIsCancelledAndNeverShown
//   M3 a code for an unknown request shown or cancelled       -> testACodeForAnUnknownRequestIsIgnoredWithoutCancelling
//   M4 the human-gesture check dropped from pairing/revoke    -> testARefusedGestureSendsNothing...
//   M5 the revoke-only level still sends pair start           -> testRevokeOnlyTurnsPairingOffButRevokeStillWorks
//   M6 New Code enabled while disconnected                    -> testLosingTheConnectionWhileAMomentShowsDisablesNewCodeUntilReconnect
final class DeviceAdminModelTests: XCTestCase {

    // MARK: Rig

    private final class FakeTransport: DeviceAdminTransport {
        enum Call: Equatable {
            case pairStart(String)
            case pairCancel(request: String, pairing: String)
            case list(String)
            case revoke(request: String, device: String)
        }
        var calls: [Call] = []
        func devicePairStart(requestId: String) { calls.append(.pairStart(requestId)) }
        func devicePairCancel(requestId: String, pairingId: String) { calls.append(.pairCancel(request: requestId, pairing: pairingId)) }
        func deviceList(requestId: String) { calls.append(.list(requestId)) }
        func deviceRevoke(requestId: String, device: String) { calls.append(.revoke(request: requestId, device: device)) }
    }

    private var transport = FakeTransport()
    private var model: DeviceAdminModel!
    private var counter = 0

    private let human = HumanGestureVerdict.human(sourcePid: nil, sourceState: nil)
    private let refused = HumanGestureVerdict.refused(reason: .appControl)
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() {
        super.setUp()
        transport = FakeTransport()
        counter = 0
        model = makeModel(transport)
    }

    private func makeModel(_ t: DeviceAdminTransport) -> DeviceAdminModel {
        var n = 0
        return DeviceAdminModel(transport: t, makeId: { n += 1; return "r\(n)" })
    }

    private func connect(_ m: DeviceAdminModel? = nil, level: String? = nil, pairFrom: [String] = []) {
        let m = m ?? model!
        m.connectionChanged(connected: true, devicesSupported: true)
        if let level { m.handle(.deviceAdminLevel(DeviceAdminLevelWire(level: level, pairFrom: pairFrom))) }
    }

    private func pairing(_ request: String, _ pairing: String = "p1", code: String = "123456") -> ServerMsg {
        .devicePairing(DevicePairingWire(requestId: request, pairingId: pairing, code: code,
                                         serverUrl: "nostromo://pair?v=1&host=h&port=7&code=\(code)", expiresAt: expiry))
    }

    private func outcome(_ pairingId: String, _ kind: DevicePairOutcomeKind, name: String? = nil) -> ServerMsg {
        .devicePairOutcome(DevicePairOutcomeWire(pairingId: pairingId, outcome: kind, name: name))
    }

    private func adminError(_ request: String, _ reason: String) -> ServerMsg {
        .deviceAdminError(DeviceAdminErrorWire(requestId: request, reason: reason))
    }

    private func showingCode(_ m: DeviceAdminModel? = nil) -> String? {
        if case .showing(let info) = (m ?? model!).pair { return info.code }
        return nil
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func device(_ id: String, _ name: String = "Phone", connected: Bool = false,
                        revokedAt: Date? = nil, revokedBy: String? = nil) -> DeviceSummary {
        DeviceSummary(id: id, name: name, kind: "iphone", pairedAt: t0, connected: connected,
                      revokedAt: revokedAt, revokedBy: revokedBy)
    }

    // MARK: Pairing

    func testAskingForACodeIsIssuingAndSendsOnePairStart() {
        connect()
        model.beginPairing(gesture: human)
        XCTAssertEqual(model.pair, .issuing)
        XCTAssertEqual(transport.calls, [.pairStart("r1")])
    }

    func testNoCodeIsShownUntilTheCodeForThisRequestArrives() {
        connect()
        model.beginPairing(gesture: human)
        XCTAssertNil(showingCode())
        model.handle(pairing("r1", "p1", code: "654321"))
        XCTAssertEqual(showingCode(), "654321")
    }

    func testAShownCodeIsNeverPrintedByTheModelsOwnDescription() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(pairing("r1", code: "654321"))
        guard case .showing(let info) = model.pair else { return XCTFail("showing") }
        XCTAssertFalse("\(info)".contains("654321"))
        XCTAssertFalse(String(reflecting: info).contains("654321"))
    }

    func testEachOutcomeMovesAShownPairingToItsState() {
        let cases: [(DevicePairOutcomeKind, DeviceAdminModel.PairState)] = [
            (.paired, .paired(name: "Ada's iPhone")), (.expired, .expired), (.lockedOut, .lockedOut),
            (.connectionLost, .connectionLost), (.cancelled, .idle), (.failed, .failed),
        ]
        for (kind, state) in cases {
            let t = FakeTransport()
            let m = makeModel(t)
            connect(m)
            m.beginPairing(gesture: human)
            m.handle(pairing("r1", "p1"))
            m.handle(outcome("p1", kind, name: kind == .paired ? "Ada's iPhone" : nil))
            XCTAssertEqual(m.pair, state, "\(kind)")
        }
    }

    func testAnOutcomeForAnotherPairingIsIgnored() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(pairing("r1", "p1"))
        model.handle(outcome("other", .paired, name: "X"))
        XCTAssertEqual(showingCode(), "123456")
    }

    func testServerUnreachableAnswerToPairStartBlocksAndShowsNoCode() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(adminError("r1", "server_unreachable"))
        XCTAssertEqual(model.pair, .blocked)
        XCTAssertNil(showingCode())
        XCTAssertEqual(model.adminAvailability, .serverUnreachable)
        XCTAssertFalse(model.canPair)
        XCTAssertEqual(DeviceAdminCopy.blocked(model.adminAvailability, pairFrom: model.pairFrom), DeviceAdminCopy.unreachable)
    }

    func testAnotherFailureToIssueIsFailedNotBlocked() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(adminError("r1", "not_saved"))
        XCTAssertEqual(model.pair, .failed)
        XCTAssertTrue(model.canPair)
    }

    func testALateCodeForACancelledRequestIsCancelledAndNeverShown() {
        connect()
        model.beginPairing(gesture: human)
        model.cancelPairing()
        transport.calls.removeAll()
        model.handle(pairing("r1", "late"))
        XCTAssertEqual(model.pair, .idle)
        XCTAssertEqual(transport.calls.count, 1)
        guard case .pairCancel(_, let pairingId)? = transport.calls.first else { return XCTFail("must cancel the late pairing") }
        XCTAssertEqual(pairingId, "late")
    }

    func testACodeForAnUnknownRequestIsIgnoredWithoutCancelling() {
        connect()
        model.beginPairing(gesture: human)
        transport.calls.removeAll()
        model.handle(pairing("not-mine", "px"))
        XCTAssertEqual(model.pair, .issuing)
        XCTAssertEqual(transport.calls, [])
    }

    func testACodeWhileIdleIsIgnoredWithoutCancelling() {
        connect()
        model.handle(pairing("whatever", "px"))
        XCTAssertEqual(model.pair, .idle)
        XCTAssertEqual(transport.calls, [])
    }

    func testCancellingWhileShowingCancelsThatPairingAndGoesIdle() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(pairing("r1", "p1"))
        transport.calls.removeAll()
        model.cancelPairing()
        XCTAssertEqual(model.pair, .idle)
        XCTAssertEqual(transport.calls.count, 1)
        guard case .pairCancel(_, let pairingId)? = transport.calls.first else { return XCTFail("must send a cancel") }
        XCTAssertEqual(pairingId, "p1")
    }

    func testCancellingWithNothingOpenSendsNothing() {
        connect()
        model.cancelPairing()
        XCTAssertEqual(transport.calls, [])
    }

    func testAskingForANewCodeWhileShowingClosesTheOldOne() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(pairing("r1", "p1"))
        transport.calls.removeAll()
        model.beginPairing(gesture: human)
        XCTAssertEqual(model.pair, .issuing)
        XCTAssertEqual(transport.calls.count, 2)
        guard case .pairCancel(_, let pairingId)? = transport.calls.first else { return XCTFail("old code cancelled first") }
        XCTAssertEqual(pairingId, "p1")
        guard case .pairStart? = transport.calls.last else { return XCTFail("then a new start") }
    }

    func testARefusedGestureSendsNothingForBeginPairing() {
        connect()
        model.beginPairing(gesture: refused)
        XCTAssertEqual(transport.calls, [])
        XCTAssertNotEqual(model.pair, .issuing)
        XCTAssertNil(showingCode())
    }

    func testARefusedGestureSendsNothingForRevoke() {
        connect()
        model.handle(.devices(DevicesWire(devices: [device("d1")])))
        model.revoke(deviceId: "d1", gesture: refused)
        XCTAssertEqual(transport.calls, [])
        XCTAssertNil(model.revokeStatus["d1"])
    }

    // MARK: Admin level

    func testRevokeOnlyTurnsPairingOffButRevokeStillWorks() {
        connect(level: "revoke_only", pairFrom: ["sendai"])
        XCTAssertFalse(model.canPair)
        XCTAssertTrue(model.canRevoke)
        model.beginPairing(gesture: human)
        XCTAssertEqual(model.pair, .blocked)
        XCTAssertEqual(transport.calls, [], "no DevicePairStart at revoke_only")
        XCTAssertEqual(DeviceAdminCopy.blocked(model.adminAvailability, pairFrom: model.pairFrom),
                       "Pairing new devices is turned off on this Mac. Pair from sendai or run `nostromo device pair` on your server.")
        model.revoke(deviceId: "d1", gesture: human)
        XCTAssertEqual(transport.calls, [.revoke(request: "r1", device: "d1")])
    }

    func testReadOnlyAndOffDisablePairAndRevoke() {
        for level in ["read_only", "off"] {
            let t = FakeTransport()
            let m = makeModel(t)
            connect(m, level: level)
            XCTAssertFalse(m.canPair, level)
            XCTAssertFalse(m.canRevoke, level)
            m.beginPairing(gesture: human)
            m.revoke(deviceId: "d1", gesture: human)
            XCTAssertEqual(m.pair, .blocked, level)
            XCTAssertEqual(t.calls, [], level)
        }
    }

    func testReadOnlyAndOffNameWhyInTheirOwnWords() {
        connect(level: "read_only")
        XCTAssertEqual(DeviceAdminCopy.blocked(model.adminAvailability, pairFrom: []), "Changes are turned off on this Mac.")
        let m2 = makeModel(FakeTransport())
        connect(m2, level: "off")
        XCTAssertEqual(DeviceAdminCopy.blocked(m2.adminAvailability, pairFrom: []), "Device management is turned off on this Mac.")
    }

    func testAPrimaryRefusingPairStartFallsBackToRevokeOnly() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(adminError("r1", "not_permitted_on_this_mac"))
        XCTAssertEqual(model.pair, .blocked)
        XCTAssertEqual(model.adminAvailability, .revokeOnly)
        XCTAssertTrue(model.canRevoke)
        XCTAssertFalse(model.canPair)
    }

    // MARK: Connection

    func testLosingTheConnectionWhileShowingDisablesNewCodeUntilReconnect() {
        connect()
        model.beginPairing(gesture: human)
        model.handle(pairing("r1", "p1"))
        XCTAssertTrue(model.canRequestNewCode)
        model.connectionChanged(connected: false, devicesSupported: false)
        XCTAssertEqual(model.pair, .connectionLost)
        XCTAssertNil(showingCode())
        XCTAssertFalse(model.canRequestNewCode)
        XCTAssertEqual(DeviceAdminCopy.lostConnection, "Lost the connection to your Nostromo server, so this code no longer works.")
        model.connectionChanged(connected: true, devicesSupported: true)
        XCTAssertTrue(model.canRequestNewCode)
        XCTAssertEqual(model.pair, .connectionLost, "the lost code is not resurrected")
    }

    func testLosingTheConnectionWhileIssuingEndsInConnectionLost() {
        connect()
        model.beginPairing(gesture: human)
        model.connectionChanged(connected: false, devicesSupported: false)
        XCTAssertEqual(model.pair, .connectionLost)
    }

    func testADaemonWithoutDevicesSupportIsServerUnreachableAndListsNothing() {
        model.connectionChanged(connected: true, devicesSupported: false)
        XCTAssertEqual(model.adminAvailability, .serverUnreachable)
        model.requestList()
        XCTAssertEqual(transport.calls, [])
        model.beginPairing(gesture: human)
        XCTAssertEqual(model.pair, .blocked)
        XCTAssertEqual(transport.calls, [])
    }

    func testRequestListAsksAConnectedDaemon() {
        connect()
        model.requestList()
        XCTAssertEqual(transport.calls, [.list("r1")])
    }

    func testTwoModelsSharingOneDaemonBothReachLockedOut() {
        final class Daemon: DeviceAdminTransport {
            var onFrame: ((ServerMsg) -> Void)?
            let expiry: Date
            init(expiry: Date) { self.expiry = expiry }
            func devicePairStart(requestId: String) {
                onFrame?(.devicePairing(DevicePairingWire(requestId: requestId, pairingId: "p-\(requestId)", code: "111222",
                                                          serverUrl: "nostromo://pair?v=1&host=h&port=7&code=111222", expiresAt: expiry)))
            }
            func devicePairCancel(requestId: String, pairingId: String) {}
            func deviceList(requestId: String) {}
            func deviceRevoke(requestId: String, device: String) {}
        }
        let daemon = Daemon(expiry: expiry)
        var n = 0
        let a = DeviceAdminModel(transport: daemon, makeId: { n += 1; return "a\(n)" })
        let b = DeviceAdminModel(transport: daemon, makeId: { n += 1; return "b\(n)" })
        daemon.onFrame = { a.handle($0); b.handle($0) }
        connect(a); connect(b)
        a.beginPairing(gesture: human)
        b.beginPairing(gesture: human)
        XCTAssertNotNil(showingCode(a))
        XCTAssertNotNil(showingCode(b))
        for id in ["p-a1", "p-b2"] {
            let frame = outcome(id, .lockedOut)
            a.handle(frame); b.handle(frame)
        }
        XCTAssertEqual(a.pair, .lockedOut)
        XCTAssertEqual(b.pair, .lockedOut)
    }

    // MARK: Devices

    func testADevicesFrameRegroupsActiveAndRevokedRowsNewestRevocationFirst() {
        connect()
        let old = device("d2", "Old", revokedAt: t0.addingTimeInterval(10), revokedBy: "operator")
        let newer = device("d3", "Newer", revokedAt: t0.addingTimeInterval(500), revokedBy: "device")
        model.handle(.devices(DevicesWire(devices: [old, device("d1", "Live", connected: true), newer])))
        XCTAssertTrue(model.hasList)
        XCTAssertEqual(model.activeDevices.map(\.id), ["d1"])
        XCTAssertEqual(model.revokedDevices.map(\.id), ["d3", "d2"])
        model.handle(.devices(DevicesWire(devices: [device("d1"), device("d4")])))
        XCTAssertEqual(model.activeDevices.map(\.id), ["d1", "d4"])
        XCTAssertEqual(model.revokedDevices, [])
    }

    func testAReplacedRowReadsReplacedByRePairing() {
        let replaced = device("d1", revokedAt: t0, revokedBy: "replaced")
        XCTAssertEqual(DeviceAdminCopy.revokedLabel(replaced, now: t0.addingTimeInterval(60)), "Replaced by re-pairing")
        let byOperator = device("d2", revokedAt: t0, revokedBy: "operator")
        XCTAssertNotEqual(DeviceAdminCopy.revokedLabel(byOperator, now: t0.addingTimeInterval(60)), "Replaced by re-pairing")
    }

    func testRevokingAConnectedDeviceSaysItWasDisconnectedJustNow() {
        connect()
        model.revoke(deviceId: "d1", gesture: human)
        XCTAssertEqual(transport.calls, [.revoke(request: "r1", device: "d1")])
        model.handle(.deviceRevoked(DeviceRevokedWire(requestId: "r1", deviceId: "d1", wasConnected: true)))
        XCTAssertEqual(model.revokeStatus["d1"], "Disconnected just now")
    }

    func testRevokingADeviceThatWasNotConnectedSaysItWillBeRefusedNextTime() {
        connect()
        model.revoke(deviceId: "d1", gesture: human)
        model.handle(.deviceRevoked(DeviceRevokedWire(requestId: "r1", deviceId: "d1", wasConnected: false)))
        XCTAssertEqual(model.revokeStatus["d1"], "Wasn't connected. It will be refused the next time it tries.")
    }

    func testARevokeAnswerForARequestThisModelDidNotMakeIsIgnored() {
        connect()
        model.handle(.deviceRevoked(DeviceRevokedWire(requestId: "someone-else", deviceId: "d1", wasConnected: true)))
        XCTAssertNil(model.revokeStatus["d1"])
    }

    func testRevokeConfirmationNamesTheDevice() {
        XCTAssertEqual(DeviceAdminCopy.revokeConfirmation(name: "Ada's iPhone"),
                       "Revoke Ada's iPhone? It will be disconnected immediately and will need to pair again.")
    }

    func testAFailedRevokeTellsThePersonAndAnUnknownDeviceIsAlreadyGone() {
        connect()
        model.revoke(deviceId: "d1", gesture: human)
        model.handle(adminError("r1", "unknown_device"))
        XCTAssertEqual(model.revokeStatus["d1"], "This device is already gone.")
        model.revoke(deviceId: "d2", gesture: human)
        model.handle(adminError("r2", "boom"))
        XCTAssertEqual(model.revokeStatus["d2"], "Couldn't revoke this device. Try again.")
    }

    // MARK: Token never reaches the model or its copy

    func testATokenOnTheWireNeverReachesModelStateOrCopy() throws {
        let secret = "tok_SECRET_9f8e7d"
        let json: [String: Any] = [
            "type": "devices",
            "devices": [["id": "d1", "name": "Phone", "kind": "iphone", "paired_at": "2026-11-20T10:00:00Z",
                         "revoked_at": "2026-11-21T10:00:00Z", "revoked_by": "operator", "token": secret]],
        ]
        let raw = try JSONSerialization.data(withJSONObject: json)
        let msg = NostromodClient(socketPath: "/dev/null").decode(type_: "devices", json: json, raw: raw)
        connect()
        model.handle(msg)
        var state = ""
        dump(model.devices, to: &state)
        dump(model.revokeStatus, to: &state)
        for d in model.devices {
            state += DeviceAdminCopy.lastSeen(d) + DeviceAdminCopy.revokedLabel(d)
        }
        XCTAssertEqual(model.devices.count, 1, "precondition: the row decoded")
        XCTAssertFalse(state.contains(secret))
    }

    // MARK: Formatting

    func testACodeIsGroupedInThrees() {
        XCTAssertEqual(DeviceAdminCopy.groupedCode("123456"), "123 456")
        XCTAssertEqual(DeviceAdminCopy.groupedCode("12345678"), "123 456 78")
        XCTAssertEqual(DeviceAdminCopy.groupedCode(""), "")
    }

    func testTheCountdownReadsMinutesAndZeroPaddedSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(DeviceAdminCopy.countdown(until: now.addingTimeInterval(125), now: now), "Expires in 2:05")
        XCTAssertEqual(DeviceAdminCopy.countdown(until: now.addingTimeInterval(300), now: now), "Expires in 5:00")
        XCTAssertEqual(DeviceAdminCopy.countdown(until: now.addingTimeInterval(9), now: now), "Expires in 0:09")
        XCTAssertEqual(DeviceAdminCopy.countdown(until: now.addingTimeInterval(-30), now: now), "Expires in 0:00")
    }
}

// The Q2 rule: mail, calendar and todos are not shared from satellite Macs, and the one place that says so is
// the single Pair-window line. Checked by reading the sources, since the rule is about what any screen could
// ever say. Comments are not shown to anyone and are ignored.
final class DeviceAdminQ2SourceTests: XCTestCase {

    private static let line = "Mail, calendar and todos aren't shared from your Macs in this version."

    private func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("../Nostromo/\(relative)").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: #"(?<!:)//.*$"#, options: .regularExpression) else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private func mentions(_ text: String) -> [String] {
        ["mail", "calendar", "todo"].filter { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    func testTheSharingLineIsTheOnlyPlaceMailCalendarOrTodosAreMentioned() throws {
        let model = withoutComments(try source("Data/DeviceAdminModel.swift"))
        XCTAssertEqual(model.components(separatedBy: Self.line).count - 1, 1, "the line exists exactly once")
        XCTAssertEqual(mentions(model.replacingOccurrences(of: Self.line, with: "")), [],
                       "no other sentence in the device copy mentions them")
        XCTAssertEqual(DeviceAdminCopy.sharingLine, Self.line)
    }

    func testNoDeviceViewMentionsMailCalendarOrTodosItself() throws {
        for path in ["UI/PairDeviceWindow.swift", "UI/DevicesWindow.swift"] {
            let view = withoutComments(try source(path))
            XCTAssertEqual(mentions(view), [], "\(path) must take its words from the copy, not mention these")
        }
    }

    func testThePairWindowShowsTheSharingLineAndTheDevicesWindowDoesNot() throws {
        XCTAssertTrue(try source("UI/PairDeviceWindow.swift").contains("sharingLine"))
        XCTAssertFalse(try source("UI/DevicesWindow.swift").contains("sharingLine"))
    }

    func testNeitherWindowOffersACheckboxOrToggleForWhatToShare() throws {
        for path in ["UI/PairDeviceWindow.swift", "UI/DevicesWindow.swift", "Data/DeviceAdminModel.swift"] {
            let text = withoutComments(try source(path))
            XCTAssertNil(text.range(of: "checkbox", options: .caseInsensitive), path)
            XCTAssertNil(text.range(of: "Toggle"), path)
        }
    }
}
