import XCTest
import Combine

// The real `NostromodClient` against a scripted fake daemon (see `FakeDaemon`), for the device-administration
// verbs: which topic it subscribes to, which frames it writes, and to which daemons.
//
// Contract:
//   * a daemon that advertises `devices` in `welcome.features` is subscribed to the `devices` topic; any other
//     daemon (no `features`, or features without it) never hears the word `devices`;
//   * the four device verbs reach the wire only on such a connection, and each is exactly the frame the Rust
//     daemon's serde types round-trip (`tests/fixtures/device-admin/client-*.json`);
//   * `operator_presence` is written only to a daemon that advertised `presence`, and then it is exactly
//     `{"type":"operator_presence","state":"active"|"away"}`. Advertising `devices` alone is not enough.
//
// The socket is ordered, so a negative assertion ("nothing was sent") sends a `ping` after the call under
// test and looks at the daemon's frames once the `ping` has arrived: anything the call sent came first.
//
// Mutations (to be run by hand), and the tests that fail for each:
//   C1 remove "devices" from NostromodClient.featureTopics    -> testAWelcomeAdvertisingDevicesAddsTheDevicesTopicToASubscribe
//   C2 drop `guard daemonAdvertisesDevices` from one verb      -> test<Verb>IsNotWrittenToADaemonThatDidNotAdvertiseDevices (that verb's)
//   C3 drop `guard daemonAdvertisesPresence`                    -> testOperatorPresenceIsNotWrittenToADaemonThatDidNotAdvertisePresence
//   C4 misspell the "operator_presence" type string             -> testOperatorPresenceIsWrittenExactlyWhenPresenceIsAdvertised,
//                                                                  testTheOperatorPresenceEncoderWritesTheTypeAndState
//   C5 misspell "device_pair_start" in DeviceWire.swift         -> testDevicePairStartIsWrittenAsTheFixtureWhenDevicesIsAdvertised,
//                                                                  testTheDeviceVerbEncodersMatchTheFixtures
final class DeviceAdminClientTests: XCTestCase {

    private var daemon: FakeDaemon!
    private var client: NostromodClient?

    override func tearDown() {
        client = nil      // the client reconnects only while it is alive
        daemon?.stop()
        daemon = nil
        super.tearDown()
    }

    private static let fixtures: URL = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/device-admin")

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try fixtureData(name)) as? [String: Any], name)
    }

    /// Poll (bounded) until `condition` holds, servicing the main run loop meanwhile.
    private func pumpUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    /// A real client connected to a fresh fake daemon whose `welcome` advertises `features`, once the client
    /// reports itself connected (its welcome handled and any feature subscribe sent).
    private func connect(features: [String]?, file: StaticString = #filePath, line: UInt = #line) throws -> NostromodClient {
        client = nil
        daemon?.stop()
        daemon = FakeDaemon(scripts: [.init(features: features)])
        try daemon.start()
        let c = NostromodClient(socketPath: daemon.path)
        client = c
        c.start()
        XCTAssertTrue(pumpUntil(5) { c.connected.value },
                      "the client never finished its handshake with a daemon advertising \(String(describing: features))",
                      file: file, line: line)
        return c
    }

    /// Everything the daemon has received once a `ping` sent now has arrived (so everything sent before it has).
    private func framesAfterPingSentinel(_ c: NostromodClient, file: StaticString = #filePath, line: UInt = #line) -> [FakeDaemon.Frame] {
        let before = daemon.frames(connection: 0, ofType: "ping").count
        c.ping()
        XCTAssertTrue(pumpUntil(5) { self.daemon.frames(connection: 0, ofType: "ping").count > before },
                      "the ping sentinel never reached the daemon", file: file, line: line)
        return daemon.frames(connection: 0)
    }

    /// Connect to a daemon advertising `features`, run `act`, and return the frames of `types` the daemon got.
    private func framesSent(of types: Set<String>, advertising features: [String]?,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ act: (NostromodClient) -> Void) throws -> [FakeDaemon.Frame] {
        let c = try connect(features: features, file: file, line: line)
        act(c)
        return framesAfterPingSentinel(c, file: file, line: line).filter { types.contains($0.type) }
    }

    /// Features a daemon may advertise without ever naming `devices`.
    private let withoutDevices: [[String]?] = [nil, [], ["work", "presence"]]

    // MARK: The `devices` topic

    func testAWelcomeAdvertisingDevicesAddsTheDevicesTopicToASubscribe() throws {
        let c = try connect(features: ["devices"])
        let frames = framesAfterPingSentinel(c)
        let named = frames.filter { $0.type == "subscribe" }.flatMap(\.topics)
        XCTAssertTrue(named.contains("devices"), "a daemon that advertised `devices` is subscribed to it: \(named)")
        XCTAssertTrue(named.contains("activity"), "and keeps the base topics: \(named)")
    }

    func testNoSubscribeNamesDevicesToADaemonThatDidNotAdvertiseIt() throws {
        for features in withoutDevices {
            let c = try connect(features: features)
            let frames = framesAfterPingSentinel(c)
            let named = frames.filter { $0.type == "subscribe" }.flatMap(\.topics)
            XCTAssertFalse(named.contains("devices"),
                           "a daemon advertising \(String(describing: features)) must not be sent `devices`: \(named)")
        }
    }

    // MARK: The verbs

    private func assertWritten(type: String, equals fixtureName: String, advertising: [String]? = ["devices"],
                               file: StaticString = #filePath, line: UInt = #line,
                               _ act: (NostromodClient) -> Void) throws {
        let frames = try framesSent(of: [type], advertising: advertising, file: file, line: line, act)
        XCTAssertEqual(frames.count, 1, "exactly one \(type) frame", file: file, line: line)
        guard let frame = frames.first else { return }
        XCTAssertEqual(frame.json as NSDictionary, try fixture(fixtureName) as NSDictionary,
                       "\(type) must be exactly \(fixtureName)", file: file, line: line)
    }

    private func assertNotWritten(type: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ act: (NostromodClient) -> Void) throws {
        for features in withoutDevices {
            let frames = try framesSent(of: [type], advertising: features, file: file, line: line, act)
            XCTAssertEqual(frames.count, 0,
                           "\(type) must not reach a daemon advertising \(String(describing: features))", file: file, line: line)
        }
    }

    func testDevicePairStartIsWrittenAsTheFixtureWhenDevicesIsAdvertised() throws {
        try assertWritten(type: "device_pair_start", equals: "client-device-pair-start.json") {
            $0.devicePairStart(requestId: "r1")
        }
    }

    func testDevicePairCancelIsWrittenAsTheFixtureWhenDevicesIsAdvertised() throws {
        try assertWritten(type: "device_pair_cancel", equals: "client-device-pair-cancel.json") {
            $0.devicePairCancel(requestId: "r2", pairingId: "p1")
        }
    }

    func testDeviceListIsWrittenAsTheFixtureWhenDevicesIsAdvertised() throws {
        try assertWritten(type: "device_list", equals: "client-device-list.json") {
            $0.deviceList(requestId: "r3")
        }
    }

    func testDeviceRevokeIsWrittenAsTheFixtureWhenDevicesIsAdvertised() throws {
        try assertWritten(type: "device_revoke", equals: "client-device-revoke.json") {
            $0.deviceRevoke(requestId: "r4", device: "dev_1")
        }
    }

    func testDevicePairStartIsNotWrittenToADaemonThatDidNotAdvertiseDevices() throws {
        try assertNotWritten(type: "device_pair_start") { $0.devicePairStart(requestId: "r1") }
    }

    func testDevicePairCancelIsNotWrittenToADaemonThatDidNotAdvertiseDevices() throws {
        try assertNotWritten(type: "device_pair_cancel") { $0.devicePairCancel(requestId: "r2", pairingId: "p1") }
    }

    func testDeviceListIsNotWrittenToADaemonThatDidNotAdvertiseDevices() throws {
        try assertNotWritten(type: "device_list") { $0.deviceList(requestId: "r3") }
    }

    func testDeviceRevokeIsNotWrittenToADaemonThatDidNotAdvertiseDevices() throws {
        try assertNotWritten(type: "device_revoke") { $0.deviceRevoke(requestId: "r4", device: "dev_1") }
    }

    func testTheClientFixturesAreExactlyTheFourDeviceVerbs() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasPrefix("client-") && $0.hasSuffix(".json") }
        XCTAssertEqual(Set(names), ["client-device-list.json", "client-device-pair-cancel.json",
                                    "client-device-pair-start.json", "client-device-revoke.json"],
                       "a new client fixture needs a test here that the app sends exactly it")
    }

    // MARK: Operator presence

    func testOperatorPresenceIsWrittenExactlyWhenPresenceIsAdvertised() throws {
        for state in ["active", "away"] {
            let frames = try framesSent(of: ["operator_presence"], advertising: ["presence"]) {
                $0.sendOperatorPresence(state: state)
            }
            XCTAssertEqual(frames.count, 1, state)
            XCTAssertEqual(frames.first?.json as NSDictionary?, ["type": "operator_presence", "state": state] as NSDictionary, state)
        }
    }

    func testOperatorPresenceIsNotWrittenToADaemonThatDidNotAdvertisePresence() throws {
        // `devices` alone does not make a daemon one that takes presence.
        for features in [nil, [], ["work"], ["devices"]] as [[String]?] {
            let frames = try framesSent(of: ["operator_presence"], advertising: features) {
                $0.sendOperatorPresence(state: "active")
                $0.sendOperatorPresence(state: "away")
            }
            XCTAssertEqual(frames.count, 0, "a daemon advertising \(String(describing: features)) must get no presence frame")
        }
    }

    // MARK: The pure encoders

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The fixture, parsed and written back compactly with sorted keys.
    private func compact(_ name: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try fixtureData(name))
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    func testTheDeviceVerbEncodersMatchTheFixtures() throws {
        XCTAssertEqual(try encoded(ClientDevicePairStart(requestId: "r1")), try compact("client-device-pair-start.json"))
        XCTAssertEqual(try encoded(ClientDevicePairCancel(requestId: "r2", pairingId: "p1")), try compact("client-device-pair-cancel.json"))
        XCTAssertEqual(try encoded(ClientDeviceList(requestId: "r3")), try compact("client-device-list.json"))
        XCTAssertEqual(try encoded(ClientDeviceRevoke(requestId: "r4", device: "dev_1")), try compact("client-device-revoke.json"))
    }

    func testTheOperatorPresenceEncoderWritesTheTypeAndState() throws {
        XCTAssertEqual(try encoded(ClientOperatorPresence(state: "active")), #"{"state":"active","type":"operator_presence"}"#)
        XCTAssertEqual(try encoded(ClientOperatorPresence(state: "away")), #"{"state":"away","type":"operator_presence"}"#)
    }
}
