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
