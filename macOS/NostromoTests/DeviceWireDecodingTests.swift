import XCTest

// The device-administration frames as the daemon writes them, decoded by the real client's `decode`.
// A device is never described by a credential: an extra `token` key must vanish in decoding.
final class DeviceWireDecodingTests: XCTestCase {

    private let client = NostromodClient(socketPath: "/dev/null")

    private func decode(_ json: [String: Any]) -> ServerMsg {
        let raw = try! JSONSerialization.data(withJSONObject: json)
        return client.decode(type_: json["type"] as! String, json: json, raw: raw)
    }

    private let paired = "2026-11-20T10:00:00Z"
    private let seen = "2026-11-24T09:30:00Z"
    private let revoked = "2026-11-25T08:00:00Z"

    func testDevicePairingFrameCarriesTheCodeAndTheUrlOfThePrimary() {
        let url = "nostromo://pair?v=1&host=sendai&port=7&code=123456"
        guard case .devicePairing(let w) = decode([
            "type": "device_pairing", "request_id": "r1", "pairing_id": "p1", "code": "123456",
            "server_url": url, "expires_at": "2026-11-25T12:05:00Z",
        ]) else { return XCTFail("device_pairing must decode") }
        XCTAssertEqual(w.requestId, "r1")
        XCTAssertEqual(w.pairingId, "p1")
        XCTAssertEqual(w.code, "123456")
        XCTAssertEqual(w.serverUrl, url)
        XCTAssertEqual(w.expiresAt, ISO8601DateFormatter().date(from: "2026-11-25T12:05:00Z"))
    }

    func testEveryPairOutcomeDecodes() {
        let expected: [(String, DevicePairOutcomeKind)] = [
            ("paired", .paired), ("expired", .expired), ("cancelled", .cancelled),
            ("locked_out", .lockedOut), ("connection_lost", .connectionLost), ("failed", .failed),
        ]
        for (wire, kind) in expected {
            guard case .devicePairOutcome(let w) = decode(["type": "device_pair_outcome", "pairing_id": "p1", "outcome": wire])
            else { XCTFail("\(wire) must decode"); continue }
            XCTAssertEqual(w.outcome, kind, wire)
            XCTAssertEqual(w.pairingId, "p1")
            XCTAssertNil(w.name, "name is optional")
            XCTAssertFalse(w.replaced, "replaced defaults to false")
        }
    }

    func testPairedOutcomeCarriesTheDeviceNameKindAndReplacedFlag() {
        guard case .devicePairOutcome(let w) = decode([
            "type": "device_pair_outcome", "pairing_id": "p1", "outcome": "paired",
            "name": "Ada's iPhone", "kind": "iphone", "replaced": true,
        ]) else { return XCTFail("must decode") }
        XCTAssertEqual(w.name, "Ada's iPhone")
        XCTAssertEqual(w.kind, "iphone")
        XCTAssertTrue(w.replaced)
    }

    func testDevicesFrameDecodesActiveAndRevokedRows() throws {
        guard case .devices(let w) = decode([
            "type": "devices",
            "devices": [
                ["id": "d1", "name": "Phone", "kind": "iphone", "paired_at": paired, "last_seen_at": seen, "connected": true],
                ["id": "d2", "name": "Old iPad", "kind": "ipad", "paired_at": paired, "connected": false,
                 "revoked_at": revoked, "revoked_by": "operator"],
            ],
        ]) else { return XCTFail("devices must decode") }
        XCTAssertEqual(w.devices.map(\.id), ["d1", "d2"])
        let phone = w.devices[0], ipad = w.devices[1]
        XCTAssertTrue(phone.connected)
        XCTAssertFalse(phone.isRevoked)
        XCTAssertEqual(phone.kind, "iphone")
        XCTAssertNotNil(phone.lastSeenAt)
        XCTAssertTrue(ipad.isRevoked)
        XCTAssertEqual(ipad.revokedBy, "operator")
        XCTAssertNil(ipad.lastSeenAt)
    }

    func testAnAbsentRevokedByAndAbsentOptionalFieldsDecodeAsNil() {
        guard case .devices(let w) = decode([
            "type": "devices",
            "devices": [["id": "d1", "name": "Phone", "kind": "iphone", "paired_at": paired]],
        ]) else { return XCTFail("must decode") }
        let d = w.devices[0]
        XCTAssertNil(d.revokedBy)
        XCTAssertNil(d.revokedAt)
        XCTAssertNil(d.lastSeenAt)
        XCTAssertFalse(d.connected)
    }

    func testHostsAreIgnoredAndDevicesStillDecode() {
        guard case .devices(let w) = decode([
            "type": "devices",
            "devices": [["id": "d1", "name": "Phone", "kind": "iphone", "paired_at": paired]],
            "hosts": [["id": "h1", "name": "satellite", "kind": "satellite", "paired_at": paired]],
        ]) else { return XCTFail("must decode") }
        XCTAssertEqual(w.devices.map(\.id), ["d1"], "satellite Macs are not shown")
    }

    func testATokenOnTheWireIsNeverDecodedIntoTheSummary() {
        let secret = "tok_SECRET_9f8e7d"
        guard case .devices(let w) = decode([
            "type": "devices",
            "devices": [["id": "d1", "name": "Phone", "kind": "iphone", "paired_at": paired, "token": secret]],
        ]) else { return XCTFail("must decode") }
        XCTAssertEqual(w.devices.count, 1)
        var dumped = ""
        dump(w, to: &dumped)
        XCTAssertFalse(dumped.contains(secret), "no token anywhere in what was decoded")
        XCTAssertFalse(Mirror(reflecting: w.devices[0]).children.contains { $0.label?.lowercased().contains("token") == true })
    }

    func testDeviceRevokedFrameReportsWhetherTheDeviceWasConnected() {
        guard case .deviceRevoked(let w) = decode([
            "type": "device_revoked", "request_id": "r9", "device_id": "d1", "was_connected": true,
        ]) else { return XCTFail("device_revoked must decode") }
        XCTAssertEqual(w.requestId, "r9")
        XCTAssertEqual(w.deviceId, "d1")
        XCTAssertTrue(w.wasConnected)
    }

    func testDeviceAdminErrorFrameCarriesTheReason() {
        guard case .deviceAdminError(let w) = decode([
            "type": "device_admin_error", "request_id": "r2", "reason": "server_unreachable",
        ]) else { return XCTFail("device_admin_error must decode") }
        XCTAssertEqual(w.requestId, "r2")
        XCTAssertEqual(w.reason, "server_unreachable")
    }

    // A satellite tells its local `devices` followers its uplink dropped with this frame under no request id.
    func testDeviceAdminErrorWithAnEmptyRequestIdDecodes() {
        guard case .deviceAdminError(let w) = decode([
            "type": "device_admin_error", "request_id": "", "reason": "server_unreachable",
        ]) else { return XCTFail("an unsolicited device_admin_error must decode") }
        XCTAssertEqual(w.requestId, "")
        XCTAssertEqual(w.reason, "server_unreachable")
    }

    func testDeviceAdminLevelFrameCarriesTheLevelAndWhereToPairFrom() {
        guard case .deviceAdminLevel(let w) = decode([
            "type": "device_admin_level", "level": "revoke_only", "pair_from": ["sendai", "tokyo"],
        ]) else { return XCTFail("device_admin_level must decode") }
        XCTAssertEqual(w.level, "revoke_only")
        XCTAssertEqual(w.pairFrom, ["sendai", "tokyo"])
    }

    func testDeviceAdminLevelWithoutPairFromDecodesWithNone() {
        guard case .deviceAdminLevel(let w) = decode(["type": "device_admin_level", "level": "full"])
        else { return XCTFail("must decode") }
        XCTAssertEqual(w.level, "full")
        XCTAssertEqual(w.pairFrom, [])
    }
}

// MARK: - The golden frames

// `tests/fixtures/device-admin/frame-*.json` is what the Rust daemon's serde types write (the Rust test
// `device_admin_wire_golden` generates and checks them), decoded here by the real client. Every frame file
// has an entry in `expectations` below, and a file with no entry fails: a new frame cannot go unchecked.
final class DeviceWireFixtureTests: XCTestCase {

    private static let directory: URL = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/device-admin")

    private let client = NostromodClient(socketPath: "/dev/null")

    private static func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func decodeFixture(_ name: String) throws -> ServerMsg {
        let raw = try Data(contentsOf: Self.directory.appendingPathComponent(name))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any], name)
        return client.decode(type_: try XCTUnwrap(json["type"] as? String, name), json: json, raw: raw)
    }

    private func frameFixturesOnDisk() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
        return Set(names.filter { $0.hasPrefix("frame-") && $0.hasSuffix(".json") })
    }

    // MARK: Expected fields, by file

    private func outcome(_ expected: DevicePairOutcomeKind) -> (ServerMsg) -> Void {
        return { msg in
            guard case .devicePairOutcome(let w) = msg else { return XCTFail("device_pair_outcome must decode") }
            XCTAssertEqual(w.pairingId, "p1")
            XCTAssertEqual(w.outcome, expected)
            XCTAssertNil(w.name)
            XCTAssertNil(w.kind)
            XCTAssertFalse(w.replaced)
        }
    }

    private func adminError(_ request: String, _ reason: String) -> (ServerMsg) -> Void {
        return { msg in
            guard case .deviceAdminError(let w) = msg else { return XCTFail("device_admin_error must decode") }
            XCTAssertEqual(w.requestId, request)
            XCTAssertEqual(w.reason, reason)
        }
    }

    private func level(_ expected: String, pairFrom: [String]) -> (ServerMsg) -> Void {
        return { msg in
            guard case .deviceAdminLevel(let w) = msg else { return XCTFail("device_admin_level must decode") }
            XCTAssertEqual(w.level, expected)
            XCTAssertEqual(w.pairFrom, pairFrom)
        }
    }

    private var expectations: [String: (ServerMsg) -> Void] {
        let iso = Self.iso
        return [
            "frame-device-pairing.json": { msg in
                guard case .devicePairing(let w) = msg else { return XCTFail("device_pairing must decode") }
                XCTAssertEqual(w.requestId, "r1")
                XCTAssertEqual(w.pairingId, "p1")
                XCTAssertEqual(w.code, "123456")
                XCTAssertEqual(w.serverUrl, "nostromo://pair?v=1&host=kobe&port=7777&code=123456")
                XCTAssertEqual(w.expiresAt, iso("2026-11-25T12:05:00Z"))
            },
            "frame-device-pair-outcome-cancelled.json": outcome(.cancelled),
            "frame-device-pair-outcome-connection-lost.json": outcome(.connectionLost),
            "frame-device-pair-outcome-expired.json": outcome(.expired),
            "frame-device-pair-outcome-failed.json": outcome(.failed),
            "frame-device-pair-outcome-locked-out.json": outcome(.lockedOut),
            "frame-device-pair-outcome-paired.json": { msg in
                guard case .devicePairOutcome(let w) = msg else { return XCTFail("device_pair_outcome must decode") }
                XCTAssertEqual(w.pairingId, "p1")
                XCTAssertEqual(w.outcome, .paired)
                XCTAssertEqual(w.name, "Ada's iPhone")
                XCTAssertEqual(w.kind, "iphone")
                XCTAssertTrue(w.replaced)
            },
            "frame-devices.json": { msg in
                guard case .devices(let w) = msg else { return XCTFail("devices must decode") }
                XCTAssertEqual(w.devices.map(\.id), ["dev_1", "dev_2", "dev_3", "dev_4"], "four rows, in the daemon's order")
                XCTAssertEqual(w.devices.map(\.name), ["Ada's iPad", "Ada's iPhone", "Old iPhone", "Ada's iPhone"])
                XCTAssertEqual(w.devices.map(\.kind), ["ipad", "iphone", "iphone", "iphone"])
                XCTAssertEqual(w.devices.map(\.pairedAt), Array(repeating: iso("2026-11-20T10:00:00Z"), count: 4))
                XCTAssertEqual(w.devices.map(\.connected), [true, false, false, false])
                XCTAssertEqual(w.devices.map(\.lastSeenAt),
                               [iso("2026-11-25T09:30:00Z"), nil, iso("2026-11-21T08:00:00Z"), nil])
                XCTAssertEqual(w.devices.map(\.revokedAt), [nil, nil, iso("2026-11-22T08:00:00Z"), iso("2026-11-23T08:00:00Z")])
                XCTAssertEqual(w.devices.map(\.revokedBy), [nil, nil, "operator", "replaced"])
                XCTAssertEqual(w.devices.map(\.isRevoked), [false, false, true, true])
                XCTAssertFalse(w.devices.contains { $0.id == "host_1" || $0.name == "sendai" }, "satellite Macs (`hosts`) are not shown")
            },
            "frame-device-revoked.json": { msg in
                guard case .deviceRevoked(let w) = msg else { return XCTFail("device_revoked must decode") }
                XCTAssertEqual(w.requestId, "r4")
                XCTAssertEqual(w.deviceId, "dev_1")
                XCTAssertTrue(w.wasConnected)
            },
            "frame-device-admin-error-devices-unavailable.json": adminError("r1", "devices_unavailable"),
            "frame-device-admin-error-not-permitted.json": adminError("r1", "not_permitted_on_this_mac"),
            "frame-device-admin-error-server-unreachable.json": adminError("r1", "server_unreachable"),
            "frame-device-admin-error-too-many-pairings.json": adminError("r1", "too_many_pairings"),
            "frame-device-admin-error-unknown-device.json": adminError("r4", "unknown_device"),
            "frame-device-admin-level-full.json": level("full", pairFrom: []),
            "frame-device-admin-level-off.json": level("off", pairFrom: []),
            "frame-device-admin-level-read-only.json": level("read_only", pairFrom: []),
            "frame-device-admin-level-revoke-only.json": level("revoke_only", pairFrom: ["sendai"]),
        ]
    }

    // MARK: Tests

    func testEveryFrameTheDaemonWritesDecodesToItsFields() throws {
        for (name, check) in expectations.sorted(by: { $0.key < $1.key }) {
            check(try decodeFixture(name))
        }
    }

    func testEveryFrameFixtureOnDiskHasExpectedFieldsAndNoneIsMissing() throws {
        XCTAssertEqual(Set(expectations.keys), try frameFixturesOnDisk(),
                       "a frame fixture with no expectations here (or an expectation with no file) is unvalidated")
    }

    func testAnUnknownOutcomeStringDecodesAsUnknownAndDoesNotFailTheFrame() throws {
        let json: [String: Any] = ["type": "device_pair_outcome", "pairing_id": "p1", "outcome": "frozen"]
        let msg = client.decode(type_: "device_pair_outcome", json: json, raw: try JSONSerialization.data(withJSONObject: json))
        guard case .devicePairOutcome(let w) = msg else { return XCTFail("an unknown outcome must still decode the frame, got \(msg)") }
        XCTAssertEqual(w.outcome, .unknown("frozen"))
        XCTAssertEqual(w.pairingId, "p1")
    }

    func testAnUnknownLevelStringDecodes() throws {
        let json: [String: Any] = ["type": "device_admin_level", "level": "frozen_solid", "pair_from": ["sendai"]]
        let msg = client.decode(type_: "device_admin_level", json: json, raw: try JSONSerialization.data(withJSONObject: json))
        guard case .deviceAdminLevel(let w) = msg else { return XCTFail("an unknown level must still decode the frame, got \(msg)") }
        XCTAssertEqual(w.level, "frozen_solid")
        XCTAssertEqual(w.pairFrom, ["sendai"])
    }
}
