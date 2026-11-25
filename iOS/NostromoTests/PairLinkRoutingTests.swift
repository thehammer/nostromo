// L5: needs the iOS app process: the `nostromo` URL scheme must be registered in the built app's
// Info.plist (what lets the system Camera hand a QR to Nostromo), and the app's URL handler must
// route a valid pairing link to the confirmation step and refuse a malformed one without sending
// anything.

import XCTest
import NostromoKit
@testable import Nostromo

@MainActor
final class PairLinkRoutingTests: XCTestCase {

    func testTheBuiltAppRegistersTheNostromoURLScheme() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("nostromo"))
    }

    func testTheBuiltAppDeclaresTheCameraAndLocalNetworkReasons() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
                       "Nostromo uses the camera only to scan the pairing code shown on your Mac.")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
    }

    func testAValidLinkIsHandedToTheConfirmationStep() throws {
        let session = AppSession(credentials: InMemoryDeviceCredentialStore())
        session.handle(url: try XCTUnwrap(URL(string: "nostromo://pair?v=1&host=10.0.0.5&port=47101&code=123456")))
        XCTAssertEqual(session.pendingLink, PairLink(host: "10.0.0.5", port: 47101, code: "123456"))
        XCTAssertNil(session.linkError)
    }

    func testAMalformedLinkShowsAnErrorAndSendsNothing() throws {
        let session = AppSession(credentials: InMemoryDeviceCredentialStore())
        session.handle(url: try XCTUnwrap(URL(string: "nostromo://pair?v=1&host=10.0.0.5&port=47101&code=12")))
        XCTAssertNil(session.pendingLink)
        XCTAssertNotNil(session.linkError)
        XCTAssertNil(session.store, "no client was created for a bad link")
    }
}
