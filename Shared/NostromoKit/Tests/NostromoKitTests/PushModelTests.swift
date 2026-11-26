// PushModelTests.swift
//
// The phone's push model (W13) over a fake transport: the first screen is held back for the reconcile
// only once (a reconnect never re-arms it), a settings edit made offline stays on screen as pending
// and is sent on the next connect (never silently reverted), an edit the primary did not keep is
// marked failed, and the APNs environment is read from the signing's `aps-environment`.

import XCTest
import Combine
@testable import NostromoKit

@MainActor
private final class FakePushTransport: DaemonTransport {
    let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    let frames = PassthroughSubject<HostedServerMsg, Never>()
    private(set) var sent: [Data] = []

    var connected: Bool { connectedSubject.value }
    var connectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var framePublisher: AnyPublisher<HostedServerMsg, Never> { frames.eraseToAnyPublisher() }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        Just(ConnectionState.connecting).eraseToAnyPublisher()
    }
    func start() {}
    func stop() {}
    func send(_ msg: some Encodable) { sent.append((try? JSONEncoder().encode(msg)) ?? Data()) }

    var sentTypes: [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["type"] as? String }
    }
}

@MainActor
private func letMainLoopTurn() async {
    for _ in 0..<3 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}

@MainActor
final class PushModelTests: XCTestCase {

    private func make(timeout: TimeInterval = 5) async -> (PushModel, FakePushTransport) {
        let transport = FakePushTransport()
        let model = PushModel(transport: transport, reconcileTimeout: timeout)
        await letMainLoopTurn()
        return (model, transport)
    }

    private func connect(_ transport: FakePushTransport) async {
        transport.connectedSubject.send(true)
        await letMainLoopTurn()
    }

    private func disconnect(_ transport: FakePushTransport) async {
        transport.connectedSubject.send(false)
        await letMainLoopTurn()
    }

    private func deliverWaiting(_ transport: FakePushTransport) async {
        transport.frames.send(HostedServerMsg(host: nil, msg: .pushWaiting(items: [], badge: 0)))
        await letMainLoopTurn()
    }

    private func deliverStatus(_ prefs: PushPrefsWire, via transport: FakePushTransport) async {
        let status = PushStatusWire(prefs: prefs, hostClasses: [:], workOwners: ["Carefeed"], lastOkAt: nil, failingSince: nil)
        transport.frames.send(HostedServerMsg(host: nil, msg: .pushStatus(status)))
        await letMainLoopTurn()
    }

    // MARK: - The input gate

    func testTheFirstConnectHoldsTheScreenUntilTheReconcileAnswers() async {
        let (model, transport) = await make()
        await connect(transport)
        XCTAssertFalse(model.reconciled)
        await deliverWaiting(transport)
        XCTAssertTrue(model.reconciled)
    }

    func testWithTheLinkDownNothingHoldsTheFirstScreen() async {
        let (model, transport) = await make()
        await disconnect(transport)
        XCTAssertTrue(model.reconciled)
    }

    func testAReconnectReconcilesAgainButNeverHoldsTheScreenBack() async {
        let (model, transport) = await make()
        await connect(transport)
        await deliverWaiting(transport)
        XCTAssertTrue(model.reconciled)

        await disconnect(transport)
        await connect(transport)

        XCTAssertTrue(model.reconciled, "the 2 s input gate is for the first screen only")
        XCTAssertEqual(transport.sentTypes.filter { $0 == "push_waiting" }.count, 2, "it still asks what waits")
    }

    func testTheGateGivesUpAfterTheTimeoutOnTheFirstConnect() async throws {
        let (model, transport) = await make(timeout: 0.05)
        await connect(transport)
        XCTAssertFalse(model.reconciled)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.reconciled)
    }

    // MARK: - Settings edits

    func testAnEditMadeOfflineStaysOnScreenAsPendingAndIsSentOnTheNextConnect() async {
        let (model, transport) = await make()
        model.update { $0.kinds.review = false }

        XCTAssertFalse(model.prefs.kinds.review)
        XCTAssertEqual(model.prefsSave, .pending)
        XCTAssertFalse(transport.sentTypes.contains("set_push_prefs"), "the link is down: nothing was sent")

        await connect(transport)
        XCTAssertEqual(transport.sentTypes.filter { $0 == "set_push_prefs" }.count, 1, "sent when the link came up")
        // The primary's answer to something else arrives first with the old settings: they must not replace the edit.
        await deliverStatus(.default, via: transport)
        XCTAssertFalse(model.prefs.kinds.review, "the edit is kept until acknowledged")
        XCTAssertNotEqual(model.prefsSave, .saved)

        var kept = PushPrefsWire.default
        kept.kinds.review = false
        await deliverStatus(kept, via: transport)
        XCTAssertEqual(model.prefsSave, .saved)
        XCTAssertFalse(model.prefs.kinds.review)
    }

    func testAnEditThePrimaryDidNotKeepIsMarkedFailedAndKeptOnScreen() async {
        let (model, transport) = await make()
        await connect(transport)
        model.update { $0.quiet.enabled = true }
        XCTAssertEqual(model.prefsSave, .pending)

        await deliverStatus(.default, via: transport)   // the primary kept the old settings

        XCTAssertEqual(model.prefsSave, .failed)
        XCTAssertTrue(model.prefs.quiet.enabled, "the screen keeps what the operator chose")
    }

    func testWithNothingPendingThePrimarysSettingsReplaceTheScreens() async {
        let (model, transport) = await make()
        var other = PushPrefsWire.default
        other.kinds.mother = false
        await deliverStatus(other, via: transport)
        XCTAssertFalse(model.prefs.kinds.mother)
        XCTAssertEqual(model.prefsSave, .saved)
    }

    // MARK: - The APNs environment

    private func profile(aps: String?) -> Data {
        let entitlement = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Name</key>"
            + "<string>x</string><key>Entitlements</key><dict>\(entitlement)</dict></dict></plist>"
        // A provisioning profile is a CMS envelope around the plist: binary junk before and after it.
        var data = Data([0x30, 0x82, 0x0a, 0xff, 0x80, 0x00])
        data.append(Data(plist.utf8))
        data.append(Data([0xde, 0xad, 0xbe, 0xef]))
        return data
    }

    func testTheEnvironmentComesFromTheSigningNotTheBuildConfiguration() {
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: profile(aps: "development"), simulator: false), .sandbox)
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: profile(aps: "production"), simulator: false), .production)
    }

    func testNoProfileOrNoEnvironmentIsProductionAndASimulatorIsSandbox() {
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: nil, simulator: false), .production)
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: profile(aps: nil), simulator: false), .production)
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: Data([1, 2, 3]), simulator: false), .production)
        XCTAssertEqual(PushEnvironmentWire.signed(provisioning: nil, simulator: true), .sandbox)
    }
}
