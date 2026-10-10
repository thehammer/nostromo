import XCTest

// `AppStore.swift` is not compiled into the host-less NostromoTests bundle, so
// this is a source-as-text fitness function (same pattern as
// DynamicFocusViewWiringTests): it pins that `AppStore.handle(_:)` forwards the
// Teri/Fred work frames to `WorkStore.shared`. Without the forwarding the
// daemon's data would decode and then go nowhere.
final class TeriFredWiringTests: XCTestCase {

    func testAppStoreForwardsWorkFramesToWorkStore() throws {
        let source = try Self.source("Data/AppStore.swift")
        for (frame, call) in [
            (".workSourceStatus", "WorkStore.shared.apply(status:"),
            (".workSnapshot", "WorkStore.shared.apply(snapshot:"),
            (".teriPicks", "WorkStore.shared.apply(picks:"),
            (".workDetail", "WorkStore.shared.resolve(requestId:"),
            (".workSendPreview", "WorkStore.shared.resolve(requestId:"),
            (".workSendResult", "WorkStore.shared.resolve(requestId:"),
        ] {
            XCTAssertTrue(source.contains("case \(frame)"), "AppStore.handle must handle \(frame)")
            XCTAssertTrue(source.contains(call), "AppStore.handle must call \(call) for \(frame)")
        }
    }

    func testClientAddsTheWorkTopicOnlyForADaemonThatAdvertisesIt() throws {
        let source = try Self.source("Data/NostromodClient.swift")
        XCTAssertTrue(source.contains(#"featureTopics: [String: String] = ["work": "work"]"#),
                      "the work topic must be tied to the `work` Welcome feature")
        XCTAssertFalse(source.contains(#""teri", "work""#),
                       "the first subscribe must not name `work`: an older daemon drops the connection")
    }

    func testAppStoreFailsPendingWorkRequestsOnDisconnectAndResetsTheStoreOnConnect() throws {
        let source = try Self.source("Data/AppStore.swift")
        XCTAssertTrue(source.contains("WorkStore.shared.failPendingRequests(reason:"))
        XCTAssertTrue(source.contains("WorkStore.shared.reset()"))
    }

    func testFocusCreatedSelectionIsGatedOnThisClientsId() throws {
        let source = try Self.source("Data/AppStore.swift")
        XCTAssertTrue(source.contains("meta.selectForClient == client.clientId"))
    }

    func testMakeLeafViewRoutesTheNativeTeriAndFredPanes() throws {
        let source = try Self.source("UI/Views/DynamicFocusView.swift")
        XCTAssertTrue(source.contains(#"paneId == "teri_surface""#))
        XCTAssertTrue(source.contains("TeriBindings.makeSurface(focus: focus)"))
        XCTAssertTrue(source.contains(#"paneId == "fred_hud""#))
        XCTAssertTrue(source.contains("FredBindings.makeSurface(focus: focus)"))
    }

    func testBindingsHostTheExistingTeriPanelAndFredHUD() throws {
        let teri = try Self.source("UI/Views/TeriBindings.swift")
        XCTAssertTrue(teri.contains("NSHostingView(rootView: TeriTodosPanel())"))
        let fred = try Self.source("UI/Views/FredBindings.swift")
        XCTAssertTrue(fred.contains("FredHUD()"))
    }

    // MARK: - Helpers

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/TeriFredWiringTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
