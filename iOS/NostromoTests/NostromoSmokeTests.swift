// L5: needs a running iOS app process: the app launches under the XCTest host, UIKit's
// application delegate exists, and the app module's launch-time wiring (ConnectionSettings ->
// NetworkClient) runs against real UserDefaults. Nothing here can run under `swift test`.
//
// Smoke test for the hosted target (docs/ios-verification.md, L5). The app is a SwiftUI
// `@main App`, so there is no hand-written app delegate to call; the honest equivalent of "the
// app delegate launches" is that UIKit's own delegate for the SwiftUI app is live in this
// process, and that the same two calls `NostromoApp.store` makes on launch (load the saved
// connection settings, construct `NetworkClient`) succeed.

import XCTest
import UIKit
import NostromoKit
@testable import Nostromo

@MainActor
final class NostromoSmokeTests: XCTestCase {

    func testAppLaunchedAndItsDelegateIsLive() {
        XCTAssertNotNil(UIApplication.shared.delegate,
                        "the SwiftUI app's UIKit delegate must exist once the host app has launched")
    }

    func testLaunchPathConstructsNetworkClientFromSavedSettings() {
        let (host, port) = ConnectionSettings.load()
        XCTAssertFalse(host.isEmpty)
        XCTAssertNotEqual(port, 0)

        // Same call NostromoApp's `store` initialiser makes. It must not open a connection on
        // construction: the app starts it later, from onAppear.
        let client = NetworkClient(host: host, port: port)
        XCTAssertFalse(client.connected)
        XCTAssertEqual(client.host, host)
        XCTAssertEqual(client.port, port)
    }
}
