// PushCapabilitiesWire tests (W16): what a registration says this build can do.
//
// W13's registration carried only `nse_withdraw`; W16 adds `nse` (the build embeds the Notification
// Service Extension, so the primary marks alert pushes mutable). The wire stays compatible both
// ways: the new field is always sent, and the old shape (no `nse`) still reads as `nse: false`.

import XCTest
@testable import NostromoKit

final class PushCapabilitiesWireTests: XCTestCase {

    private func object(_ value: some Encodable) throws -> [String: Bool] {
        let any = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try XCTUnwrap(any as? [String: Bool])
    }

    func testTheDefaultSaysNoExtensionAndNoWithdraw() throws {
        XCTAssertEqual(try object(PushCapabilitiesWire()), ["nse": false, "nse_withdraw": false])
    }

    func testABuildWithTheExtensionSaysNseTrueAndWithdrawFalse() throws {
        XCTAssertEqual(try object(PushCapabilitiesWire(nse: true)), ["nse": true, "nse_withdraw": false])
    }

    func testTheRegistrationVerbCarriesTheCapabilities() throws {
        let data = try JSONEncoder().encode(
            ClientRegisterPush(apnsToken: "ab12", environment: .sandbox, capabilities: PushCapabilitiesWire(nse: true)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "register_push")
        XCTAssertEqual(json["capabilities"] as? [String: Bool], ["nse": true, "nse_withdraw": false])
    }

    func testTheCapabilitiesRoundTrip() throws {
        for capabilities in [PushCapabilitiesWire(), PushCapabilitiesWire(nse: true),
                             PushCapabilitiesWire(nse: true, nseWithdraw: true)] {
            let back = try JSONDecoder().decode(PushCapabilitiesWire.self, from: JSONEncoder().encode(capabilities))
            XCTAssertEqual(back, capabilities)
        }
    }

    func testTheOlderShapeWithoutNseStillReadsAsNoExtension() throws {
        let old = try JSONDecoder().decode(PushCapabilitiesWire.self, from: Data(#"{"nse_withdraw":false}"#.utf8))
        XCTAssertEqual(old, PushCapabilitiesWire(nse: false, nseWithdraw: false))
    }

    func testAFieldThisBuildDoesNotKnowIsIgnored() throws {
        let newer = try JSONDecoder().decode(PushCapabilitiesWire.self,
                                             from: Data(#"{"nse":true,"nse_withdraw":false,"future":true}"#.utf8))
        XCTAssertEqual(newer, PushCapabilitiesWire(nse: true))
    }
}
