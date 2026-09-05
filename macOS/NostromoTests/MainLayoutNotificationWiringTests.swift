import XCTest

// `MainLayout.swift` is AppKit and not compiled into the host-less
// NostromoTests bundle (same reasoning DynamicFocusViewWiringTests.swift's
// header gives for DynamicFocusView.swift). This is a fitness function, not
// a behavioral test: it pins that MainLayout wires the new daemon
// Notification transport (W5) to the existing toast banner surface, the
// same way it already wires AppStore.onMemoryToast.
final class MainLayoutNotificationWiringTests: XCTestCase {

    func testMainLayoutWiresOnNotificationToTheToastBanner() throws {
        let source = try Self.mainLayoutSource()
        XCTAssertTrue(source.contains("AppStore.shared.onNotification ="), """
            MainLayout must wire AppStore.shared.onNotification, mirroring the existing \
            AppStore.shared.onMemoryToast wiring — otherwise a daemon Notification broadcast (W5) has no \
            production surface to render on even once a real trigger (W9) starts sending them.
            """)

        guard let wireRange = source.range(of: "AppStore.shared.onNotification =") else { return }
        let after = source[wireRange.upperBound...]
        guard let closingBrace = after.firstIndex(of: "}") else {
            XCTFail("could not find the end of the onNotification closure")
            return
        }
        let closureBody = after[after.startIndex..<closingBrace]
        XCTAssertTrue(closureBody.contains("toastView.showToast"), """
            The onNotification closure must call toastView.showToast, the same banner surface \
            onMemoryToast already renders through — a separate/new toast surface would fork the two \
            instead of reusing the one that exists.
            """)
    }

    // MARK: - Helpers

    private static func mainLayoutSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/MainLayout.swift"), encoding: .utf8)
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/MainLayoutNotificationWiringTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }
}
