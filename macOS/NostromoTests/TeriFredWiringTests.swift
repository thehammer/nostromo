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

    func testClientSubscribesToTheWorkTopic() throws {
        let source = try Self.source("Data/NostromodClient.swift")
        XCTAssertTrue(source.contains(#""teri", "work""#), "the subscribe list must include the work topic")
    }

    func testFocusCreatedSelectionIsGatedOnThisClientsId() throws {
        let source = try Self.source("Data/AppStore.swift")
        XCTAssertTrue(source.contains("meta.selectForClient == client.clientId"))
    }

    // MARK: - Helpers

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/TeriFredWiringTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
