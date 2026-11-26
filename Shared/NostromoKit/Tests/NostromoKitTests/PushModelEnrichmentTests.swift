// PushModelEnrichmentTests.swift
//
// The W16 changes to the phone's push model, over a fake transport:
//
//   - registration says what this build can do (`capabilities.nse` once the extension is embedded;
//     `nse_withdraw` is never true: the extension cannot hide a notification);
//   - the operator's per-host "Show full details" switch is kept on the phone and handed to the
//     extension through the App Group (`setDetails(_:host:)`);
//   - the host classes in `push_status` are handed to the extension too, but only the primary's own
//     (never one relayed from a satellite), and the App Group never holds a token.

import XCTest
import Combine
@testable import NostromoKit

@MainActor
private final class EnrichmentFakeTransport: DaemonTransport {
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

    /// The first frame sent with this wire `type`, as a JSON object.
    func frame(ofType type: String) -> [String: Any]? {
        for data in sent {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["type"] as? String == type {
                return object
            }
        }
        return nil
    }
}

@MainActor
private func enrichmentLoopTurn() async {
    for _ in 0..<3 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}

@MainActor
final class PushModelEnrichmentTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        try await super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeModel(capabilities: PushCapabilitiesWire? = nil,
                           shared: SharedPushState? = nil) async -> (PushModel, EnrichmentFakeTransport) {
        let transport = EnrichmentFakeTransport()
        let model: PushModel
        if let capabilities {
            model = PushModel(transport: transport, capabilities: capabilities, shared: shared)
        } else {
            model = PushModel(transport: transport, shared: shared)
        }
        await enrichmentLoopTurn()
        return (model, transport)
    }

    private func connect(_ transport: EnrichmentFakeTransport) async {
        transport.connectedSubject.send(true)
        await enrichmentLoopTurn()
    }

    private func deliverStatus(hostClasses: [String: HostClassWire], from host: String? = nil,
                               via transport: EnrichmentFakeTransport) async {
        let status = PushStatusWire(prefs: .default, hostClasses: hostClasses, workOwners: ["Carefeed"],
                                    lastOkAt: nil, failingSince: nil)
        transport.frames.send(HostedServerMsg(host: host, msg: .pushStatus(status)))
        await enrichmentLoopTurn()
    }

    // MARK: - Registration says what this build can do

    func testRegistrationByDefaultSaysNoExtensionAndNoWithdraw() async throws {
        let (model, transport) = await makeModel()
        await connect(transport)
        model.apnsToken = "ab12"

        let frame = try XCTUnwrap(transport.frame(ofType: "register_push"))
        let capabilities = try XCTUnwrap(frame["capabilities"] as? [String: Bool])
        XCTAssertEqual(capabilities, ["nse": false, "nse_withdraw": false])
    }

    func testRegistrationFromABuildWithTheExtensionSaysNseTrueAndNeverWithdraw() async throws {
        let (model, transport) = await makeModel(capabilities: PushCapabilitiesWire(nse: true))
        await connect(transport)
        model.apnsToken = "ab12"

        let frame = try XCTUnwrap(transport.frame(ofType: "register_push"))
        let capabilities = try XCTUnwrap(frame["capabilities"] as? [String: Bool])
        XCTAssertEqual(capabilities, ["nse": true, "nse_withdraw": false])
        XCTAssertEqual(frame["apns_token"] as? String, "ab12")
    }

    func testTheRegistrationSentOnAReconnectCarriesTheSameCapabilities() async throws {
        let (model, transport) = await makeModel(capabilities: PushCapabilitiesWire(nse: true))
        model.apnsToken = "ab12"
        await connect(transport)   // the token was already there: this connect registers it

        let frame = try XCTUnwrap(transport.frame(ofType: "register_push"))
        XCTAssertEqual(frame["capabilities"] as? [String: Bool], ["nse": true, "nse_withdraw": false])
    }

    // MARK: - The per-host switch

    func testDetailsAreOnForEveryHostUntilTheOperatorSwitchesOne() async {
        let (model, _) = await makeModel()
        XCTAssertTrue(model.enrichment.disabledHosts.isEmpty)
        XCTAssertTrue(model.enrichment.isEnabled(host: "sendai"))
    }

    func testSwitchingDetailsOffForAHostIsKeptAndHandedToTheExtension() async {
        let shared = SharedPushState(defaults: defaults)
        let (model, _) = await makeModel(shared: shared)

        model.setDetails(false, host: "sendai")

        XCTAssertFalse(model.enrichment.isEnabled(host: "sendai"))
        XCTAssertTrue(model.enrichment.isEnabled(host: "tokyo"))
        let seenByTheExtension = SharedPushState(defaults: defaults).enrichment
        XCTAssertEqual(seenByTheExtension.disabledHosts, ["sendai"], "persisted in the App Group")
    }

    func testSwitchingDetailsBackOnForgetsTheHostEverywhere() async {
        let shared = SharedPushState(defaults: defaults)
        let (model, _) = await makeModel(shared: shared)
        model.setDetails(false, host: "sendai")
        model.setDetails(false, host: "tokyo")

        model.setDetails(true, host: "sendai")

        XCTAssertEqual(model.enrichment.disabledHosts, ["tokyo"])
        XCTAssertEqual(SharedPushState(defaults: defaults).enrichment.disabledHosts, ["tokyo"])
    }

    func testAModelStartsWithTheSwitchesAlreadyInTheAppGroup() async {
        let shared = SharedPushState(defaults: defaults)
        shared.enrichment = EnrichmentPrefs(disabledHosts: ["kobe"])

        let (model, _) = await makeModel(shared: shared)

        XCTAssertFalse(model.enrichment.isEnabled(host: "kobe"))
    }

    func testTheSwitchWorksWithNoAppGroupAtAll() async {
        let (model, _) = await makeModel(shared: nil)
        model.setDetails(false, host: "sendai")
        XCTAssertFalse(model.enrichment.isEnabled(host: "sendai"))
    }

    func testTheSwitchIsNeverSentToThePrimary() async {
        let (model, transport) = await makeModel(shared: SharedPushState(defaults: defaults))
        await connect(transport)
        let before = transport.sent.count

        model.setDetails(false, host: "sendai")
        await enrichmentLoopTurn()

        XCTAssertEqual(transport.sent.count, before, "the primary never hears of it")
    }

    // MARK: - Host classes for the extension

    func testAPushStatusWritesTheHostClassesIntoTheAppGroup() async {
        let shared = SharedPushState(defaults: defaults)
        let (_, transport) = await makeModel(shared: shared)

        await deliverStatus(hostClasses: ["sendai": .personal, "kobe": .work], via: transport)

        XCTAssertEqual(SharedPushState(defaults: defaults).hostClasses, ["sendai": .personal, "kobe": .work])
    }

    func testALaterPushStatusReplacesTheHostClasses() async {
        let shared = SharedPushState(defaults: defaults)
        let (_, transport) = await makeModel(shared: shared)
        await deliverStatus(hostClasses: ["sendai": .personal, "kobe": .work], via: transport)

        await deliverStatus(hostClasses: ["sendai": .work], via: transport)

        XCTAssertEqual(SharedPushState(defaults: defaults).hostClasses, ["sendai": .work])
    }

    func testAPushStatusRelayedFromASatelliteDoesNotTouchTheAppGroup() async {
        let shared = SharedPushState(defaults: defaults)
        shared.hostClasses = ["sendai": .work]
        let (_, transport) = await makeModel(shared: shared)

        await deliverStatus(hostClasses: ["sendai": .personal], from: "kobe", via: transport)

        XCTAssertEqual(SharedPushState(defaults: defaults).hostClasses, ["sendai": .work],
                       "only the primary classifies hosts")
    }

    func testAPushStatusWithNoAppGroupIsStillShownOnScreen() async {
        let (model, transport) = await makeModel(shared: nil)
        await deliverStatus(hostClasses: ["sendai": .personal], via: transport)
        XCTAssertEqual(model.status?.hostClasses, ["sendai": .personal])
    }

    // MARK: - Never a token in the App Group

    func testTheAppGroupNeverHoldsTheApnsTokenOrAnythingNamedToken() async {
        let shared = SharedPushState(defaults: defaults)
        let (model, transport) = await makeModel(capabilities: PushCapabilitiesWire(nse: true), shared: shared)
        await connect(transport)
        model.apnsToken = "deadbeefcafe0123"
        model.setDetails(false, host: "kobe")
        await deliverStatus(hostClasses: ["sendai": .personal], via: transport)

        let stored = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(stored.isEmpty, "the check must look at something")
        for (key, value) in stored {
            XCTAssertFalse(key.lowercased().contains("token"), "\(key)")
            XCTAssertFalse("\(value)".contains("deadbeefcafe0123"), "the APNs token is not in \(key)")
        }
    }
}
