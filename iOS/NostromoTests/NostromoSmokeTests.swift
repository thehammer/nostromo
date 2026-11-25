// L5: needs a running iOS app process: the test bundle links against the app module
// (`@testable import Nostromo`) and calls app code and UIKit's application delegate inside the
// iOS process the app launched in. Nothing here can run under `swift test`.
//
// Smoke test for the hosted target (docs/ios-verification.md, L5). The app is a SwiftUI
// `@main App`, so there is no hand-written app delegate to call. What this file shows:
//   - UIKit's delegate for the SwiftUI app is live, i.e. the host app really launched;
//   - the test bundle can reach the app module's code (`ConnectionSettings`), and the same
//     `NetworkClient` construction `NostromoApp.store` performs succeeds in the iOS process.
// It does NOT show that `NostromoApp`'s own initialiser ran (the test calls the same functions
// itself). That the bundle is hosted in the app at all is `HostedHarnessTests`' job.

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

    func testNetworkClientConstructsFromTheAppsConnectionSettings() {
        let (host, port) = ConnectionSettings.load()
        XCTAssertFalse(host.isEmpty)

        // The call NostromoApp's `store` initialiser makes. Construction must not open a
        // connection: the app starts it later, from onAppear.
        let client = NetworkClient(host: host, port: port)
        XCTAssertFalse(client.connected)
        XCTAssertEqual(client.host, host)
        XCTAssertEqual(client.port, port)
    }
}
