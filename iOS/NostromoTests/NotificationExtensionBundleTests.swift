// L5: the Notification Service Extension is an app extension of the built app, with its own Info.plist
// (and so its own App Transport Security settings), its own entitlements and a UserDefaults suite shared
// with the app. None of that exists in a SwiftPM test binary, so it is proved here, in the hosted app.
// Measured limit: the Simulator ignores App Group and Keychain access-group entitlements (an ad-hoc
// signed build, as `make ios-test` produces, has no provisioning profile), so what the Simulator can
// show is that the extension is embedded and configured; that the App Group and the shared Keychain
// item work between the two processes on a real device is a manual check (listed in the PR body).

import XCTest
import NostromoKit

final class NotificationExtensionBundleTests: XCTestCase {

    private var extensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("PlugIns/NostromoNotificationService.appex")
    }

    private func extensionInfo() throws -> [String: Any] {
        let data = try Data(contentsOf: extensionURL.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppEmbedsTheNotificationServiceExtension() throws {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path, isDirectory: &isDirectory),
                      "the built app has no PlugIns/NostromoNotificationService.appex")
        XCTAssertTrue(isDirectory.boolValue)
        let info = try extensionInfo()
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.hammer.nostromo.ios.NotificationService")
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.usernotifications.service")
        XCTAssertTrue((ext["NSExtensionPrincipalClass"] as? String ?? "").hasSuffix(".NotificationService"))
    }

    /// Extensions have their own Info.plist and so their own ATS settings: without this key the
    /// extension's plain `ws://` connection to the WireGuard address fails with -1022 and every
    /// notification would show contract text only.
    func testTheExtensionsBuiltInfoPlistAllowsLocalNetworkingAndNeverArbitraryLoads() throws {
        let ats = try XCTUnwrap(try extensionInfo()["NSAppTransportSecurity"] as? [String: Any],
                                "the extension's Info.plist has no NSAppTransportSecurity")
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNil(ats["NSExceptionDomains"])
    }

    func testTheAppGroupDefaultsCarryTheAddressTheExtensionReads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedPushState.defaultAppGroup))
        let state = SharedPushState(defaults: defaults)
        let before = (state.address, state.hostClasses, state.enrichment)
        defer {
            state.address = before.0
            state.hostClasses = before.1
            state.enrichment = before.2
        }
        state.address = SharedPushState.Address(host: "10.0.0.2", port: 47101)
        state.hostClasses = ["sendai": .personal, "kobe": .work]
        XCTAssertEqual(SharedPushState(defaults: defaults).address,
                       SharedPushState.Address(host: "10.0.0.2", port: 47101))
        XCTAssertEqual(SharedPushState(defaults: defaults).hostClasses["sendai"], .personal)
    }
}
