// L5: needs an iOS process: asserts the test bundle is hosted inside the Nostromo iOS app (the
// iOS simulator process, UIApplication.shared, the app's main bundle), the precondition for
// every later L5 test (Keychain access groups, URL handling, file protection, extension wiring).
//
// This file exists so L5 can never go vacuous: if the harness silently stopped hosting tests in
// the app (a lost TEST_HOST, a host-less bundle), the smoke test could still pass in some
// configurations; these cannot.

import XCTest
import UIKit

@MainActor
final class HostedHarnessTests: XCTestCase {

    func testMainBundleIsTheNostromoApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.hammer.nostromo.ios")
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
    }

    func testTestCaseLivesInAnXCTestBundleDistinctFromTheApp() {
        let testBundle = Bundle(for: HostedHarnessTests.self)
        XCTAssertEqual(testBundle.bundleURL.pathExtension, "xctest")
        XCTAssertNotEqual(testBundle.bundleURL, Bundle.main.bundleURL)
    }

    func testUIApplicationExistsInAnIOSProcess() {
        // `UIApplication.shared` is only usable inside an iOS app process; host-less it traps.
        let state = UIApplication.shared.applicationState
        XCTAssertTrue([.active, .inactive, .background].contains(state))
        XCTAssertEqual(UIDevice.current.systemName, "iOS")
    }
}
