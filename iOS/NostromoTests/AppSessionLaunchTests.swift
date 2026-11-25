// L5: needs the iOS app process: `AppSession` reads the UserDefaults-backed `ConnectionSettings`
// and decides at launch what to do with a Keychain credential; the Keychain item survives an app
// delete and reinstall while UserDefaults does not, so a credential with no saved address must be
// deleted at launch and a pairing link must never be able to ask for it. The revoke path
// (credential, then content, then screen) and the legacy-transport route off the pairing start
// screen are exercised end to end against an in-process loopback server.

import XCTest
import Combine
import NostromoKit
@testable import Nostromo

@MainActor
final class AppSessionLaunchTests: XCTestCase {

    private static let keys = ["nostromd.host", "nostromd.ws.port", "nostromd.transport"]
    private var savedDefaults: [String: Any?] = [:]
    private var directory: URL!
    private var cacheURL: URL { directory.appendingPathComponent("content-cache.json") }
    private let credential = DeviceCredential(token: "tok-old-l5", deviceId: "dev-old", serverId: "srv-old", name: "iPhone")

    override func setUp() {
        super.setUp()
        for key in Self.keys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("l5-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for key in Self.keys {
            if let value = savedDefaults[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Reinstall: an orphaned credential

    func testACredentialWithNoSavedAddressIsDeletedAtLaunch() {
        let credentials = InMemoryDeviceCredentialStore(credential)
        let session = AppSession(credentials: credentials, cache: ContentCache(url: cacheURL))
        XCTAssertNil(credentials.load(), "the orphaned credential must be wiped at launch")
        XCTAssertEqual(session.phase, .unpaired)
        XCTAssertNil(session.store)
    }

    func testAHostileLinkAfterAReinstallNeverSendsTheOldTokenOrAProof() async throws {
        let offer = #"{"type":"pair_offer","name_hint":"Hostile","server_id":"srv-hostile","challenge":"c1"}"#
        let server = try await LoopbackWebSocketServer.start(reply: { _ in offer })
        defer { server.stop() }

        let credentials = InMemoryDeviceCredentialStore(credential)
        let session = AppSession(credentials: credentials, cache: ContentCache(url: cacheURL))
        session.handle(url: try XCTUnwrap(URL(string:
            "nostromo://pair?v=1&host=127.0.0.1&port=\(server.port)&code=123456")))
        let link = try XCTUnwrap(session.pendingLink)

        let model = session.makePairingModel()
        await model.begin(address: link.host, port: link.port, code: link.code)

        guard case .confirming(let confirmation) = model.step else { return XCTFail("expected the confirmation, got \(model.step)") }
        XCTAssertEqual(confirmation.existing, .none, "no old pairing exists: no replace line, no warning")
        XCTAssertEqual(server.acceptedCount, 1)
        for headers in server.handshakeHeaders {
            XCTAssertNil(headers.first { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame },
                         "the link's server must never be sent a bearer token")
        }
        XCTAssertFalse(server.receivedTexts.isEmpty)
        for text in server.receivedTexts {
            XCTAssertFalse(text.contains("proof"), "no proof derived from the old token goes to a link's server")
            XCTAssertFalse(text.contains(credential.token))
        }
        model.reset()
    }

    // MARK: - Revoke: credential, then content, then screen

    func testRevokedWipesTheCredentialThenTheContentBeforeTheScreenChanges() async throws {
        let server = try await LoopbackWebSocketServer.start(
            greeting: #"{"type":"unauthorized","reason":"revoked"}"#, reply: { _ in nil })
        defer { server.stop() }
        ConnectionSettings.saveAddress(host: "127.0.0.1", webSocketPort: server.port)

        let cache = ContentCache(url: cacheURL, debounce: 60)
        cache.record(host: nil, raw: Data(#"{"type":"mother_jobs","jobs":[{"id":"j1","state":"running","title":"T"}]}"#.utf8))
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "the seed must reach disk")

        let credentials = InMemoryDeviceCredentialStore(credential)
        let session = AppSession(credentials: credentials, cache: cache)
        XCTAssertEqual(session.phase, .paired)
        XCTAssertEqual(session.store?.hasLastKnownContent, true)

        var seenAtScreenChange: (credentialGone: Bool, cacheGone: Bool, storeGone: Bool, memoryEmpty: Bool)?
        let store = session.store
        let watch = session.$phase.sink { phase in
            guard phase == .noLongerPaired, seenAtScreenChange == nil else { return }
            seenAtScreenChange = (credentials.load() == nil,
                                  !FileManager.default.fileExists(atPath: self.cacheURL.path),
                                  session.store == nil,
                                  store?.motherJobs.isEmpty == true)
        }
        defer { watch.cancel() }

        let changed = await waitUntil { seenAtScreenChange != nil }
        XCTAssertTrue(changed, "the revoked server must take the app to the no-longer-paired screen")
        XCTAssertEqual(seenAtScreenChange?.credentialGone, true, "1: the credential is cleared before the screen")
        XCTAssertEqual(seenAtScreenChange?.cacheGone, true, "2: the cache file is deleted before the screen")
        XCTAssertEqual(seenAtScreenChange?.memoryEmpty, true, "2: memory is emptied before the screen")
        XCTAssertEqual(seenAtScreenChange?.storeGone, true)
    }

    // MARK: - Legacy transport off the pairing start screen

    func testTheLegacyTransportIsReachableBeforeAnyPairing() {
        let session = AppSession(credentials: InMemoryDeviceCredentialStore(), cache: ContentCache(url: cacheURL))
        XCTAssertEqual(session.phase, .unpaired)

        session.setTransport(.legacyTCP)      // what the start screen's Advanced control calls
        defer { session.store?.stop(); ConnectionSettings.transport = .webSocket }

        XCTAssertEqual(session.phase, .paired, "the tabs are shown")
        XCTAssertNotNil(session.store?.legacyClient, "over the legacy NetworkClient")
        XCTAssertEqual(session.store?.canMutate, true)
    }
}
