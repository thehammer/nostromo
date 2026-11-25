// NostromoKit — PairingFlowModelTests.swift
//
// The pairing flow as a state machine (W11-17/18/19; PRD D1, D4, D6). A scripted fake server and a
// fake set of side effects write into ONE ordered log, so the tests can assert not only what was
// called but in what order (content is wiped before Pair; the old server is told to forget us after).
//
// What is guarded:
//   D4  the code is checked before the confirmation, and a failed check never shows a confirmation
//       and never reaches `Pair`;
//   D6  with a stored credential the second check carries an HMAC proof (never the token or its
//       hash), on the same socket the Pair later uses; "same server" replaces, anything else wipes
//       first and then asks the old server to forget the device;
//   a failed Pair leaves the old credential in place and brings the old client back.

import XCTest
import Combine
import CryptoKit
@testable import NostromoKit

// MARK: - Fakes

@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
    func count(_ prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }
}

@MainActor
private final class FakePairingServer: PairingServer {
    struct CheckCall: Equatable { let code: String; let proof: String? }
    struct PairCall: Equatable { let code: String; let name: String; let kind: DeviceKindWire; let replace: Bool }

    private let log: EventLog
    var isOpen = true
    /// One entry per `check`, consumed in order; the last one repeats.
    var checkScript: [Result<PairOffer, Error>]
    var pairResult: Result<PairedResult, Error>
    private(set) var checkCalls: [CheckCall] = []
    private(set) var pairCalls: [PairCall] = []
    private(set) var closeCount = 0

    init(log: EventLog, checks: [Result<PairOffer, Error>], pair: Result<PairedResult, Error>) {
        self.log = log
        self.checkScript = checks
        self.pairResult = pair
    }

    func check(code: String, proof: String?) async throws -> PairOffer {
        log.add("server.check(proof: \(proof == nil ? "no" : "yes"))")
        checkCalls.append(CheckCall(code: code, proof: proof))
        let index = min(checkCalls.count - 1, checkScript.count - 1)
        return try checkScript[index].get()
    }

    func pair(code: String, name: String, kind: DeviceKindWire, replace: Bool) async throws -> PairedResult {
        log.add("server.pair(replace: \(replace))")
        pairCalls.append(PairCall(code: code, name: name, kind: kind, replace: replace))
        return try pairResult.get()
    }

    func close() {
        closeCount += 1
        log.add("server.close")
    }
}

@MainActor
private final class FakePairingEffects: PairingSideEffects {
    private let log: EventLog
    var currentServer: (address: String, port: UInt16)?
    private(set) var unpaired: [(address: String, port: UInt16, credential: DeviceCredential)] = []
    private(set) var didPairCalls: [(credential: DeviceCredential, address: String, port: UInt16)] = []

    init(log: EventLog, currentServer: (address: String, port: UInt16)? = nil) {
        self.log = log
        self.currentServer = currentServer
    }

    func stopCurrentClient() { log.add("effects.stopCurrentClient") }
    func restartCurrentClient() { log.add("effects.restartCurrentClient") }
    func wipeContent() { log.add("effects.wipeContent") }
    func unpairFromOldServer(address: String, port: UInt16, credential: DeviceCredential) async {
        log.add("effects.unpairFromOldServer(\(address):\(port))")
        unpaired.append((address, port, credential))
    }
    func didPair(_ credential: DeviceCredential, address: String, port: UInt16) {
        log.add("effects.didPair")
        didPairCalls.append((credential, address, port))
    }
}

/// A store whose Keychain refuses to save.
private final class FailingCredentialStore: DeviceCredentialStore {
    private var credential: DeviceCredential?
    init(_ credential: DeviceCredential? = nil) { self.credential = credential }
    func load() -> DeviceCredential? { credential }
    func save(_ credential: DeviceCredential) throws { throw DeviceCredentialError(status: -25299) }
    func clear() throws { credential = nil }
}

// MARK: - Tests

@MainActor
final class PairingFlowModelTests: XCTestCase {

    private let address = "10.0.0.5"
    private let port: UInt16 = 47101
    private let code = "123456"

    private let oldCredential = DeviceCredential(token: "old-token-R2VnZW5kYXJ5LU9sZA", deviceId: "dev-old",
                                                 serverId: "srv-old", name: "Hammer's iPhone")

    private func offer(hint: String? = "Hammer's Mac", challenge: String = "chal-1",
                       knows: Bool? = nil) -> PairOffer {
        PairOffer(nameHint: hint, serverId: "srv-new", challenge: challenge, knowsDevice: knows)
    }

    private func paired(name: String = "Paired Name") -> PairedResult {
        PairedResult(deviceId: "dev-new", token: SecretToken("new-token-VmVyeU5ldw"), name: name,
                     serverId: "srv-new", replaced: false)
    }

    private struct Harness {
        let log: EventLog
        let server: FakePairingServer
        let effects: FakePairingEffects
        let model: PairingFlowModel
        var makeServerCalls: MakeServerCounter
    }

    private final class MakeServerCounter {
        var calls: [(String, UInt16)] = []
    }

    private func harness(kind: DeviceKindWire = .iphone,
                         store: DeviceCredentialStore = InMemoryDeviceCredentialStore(),
                         checks: [Result<PairOffer, Error>]? = nil,
                         pair: Result<PairedResult, Error>? = nil,
                         currentServer: (address: String, port: UInt16)? = nil) -> Harness {
        let log = EventLog()
        let server = FakePairingServer(log: log, checks: checks ?? [.success(offer())],
                                       pair: pair ?? .success(paired()))
        let effects = FakePairingEffects(log: log, currentServer: currentServer)
        let counter = MakeServerCounter()
        let model = PairingFlowModel(kind: kind, credentials: store, effects: effects) { address, port in
            counter.calls.append((address, port))
            return server
        }
        return Harness(log: log, server: server, effects: effects, model: model, makeServerCalls: counter)
    }

    /// Records every step the model publishes.
    private func recordSteps(_ model: PairingFlowModel) -> StepRecorder { StepRecorder(model) }

    @MainActor
    private final class StepRecorder {
        private(set) var steps: [PairingStep] = []
        private var token: Any?
        init(_ model: PairingFlowModel) {
            token = model.$step.sink { [weak self] in self?.steps.append($0) }
        }
        var confirmingSeen: Bool { steps.contains { if case .confirming = $0 { return true }; return false } }
    }

    private struct NotConfirming: Error {}

    private func confirmation(of model: PairingFlowModel) throws -> PairingConfirmation {
        guard case .confirming(let confirmation) = model.step else {
            XCTFail("expected the confirmation step, got \(model.step)")
            throw NotConfirming()
        }
        return confirmation
    }

    // MARK: - (a) A fresh pairing

    func testAFreshPairingChecksOnceWithoutAProofThenConfirmsWithNoExistingPairing() async throws {
        let h = harness()

        await h.model.begin(address: address, port: port, code: code)

        XCTAssertEqual(h.server.checkCalls, [.init(code: code, proof: nil)], "Exactly one check, and no proof")
        XCTAssertEqual(h.makeServerCalls.calls.count, 1)
        XCTAssertEqual(h.model.step, .confirming(PairingConfirmation(
            address: address, port: port, code: code, offer: offer(), existing: .none)))
    }

    func testTheNameIsPrefilledFromTheOffersHintElseFromTheKind() async throws {
        let hinted = harness(checks: [.success(offer(hint: "Sendai"))])
        await hinted.model.begin(address: address, port: port, code: code)
        XCTAssertEqual(hinted.model.name, "Sendai")

        let phone = harness(checks: [.success(offer(hint: nil))])
        await phone.model.begin(address: address, port: port, code: code)
        XCTAssertEqual(phone.model.name, "iPhone")

        let pad = harness(kind: .ipad, checks: [.success(offer(hint: nil))])
        await pad.model.begin(address: address, port: port, code: code)
        XCTAssertEqual(pad.model.name, "iPad")
    }

    func testConfirmingPairsWithoutReplaceSavesTheCredentialAndSucceedsWithThePairedName() async throws {
        let store = InMemoryDeviceCredentialStore()
        let h = harness(store: store)
        await h.model.begin(address: address, port: port, code: code)
        h.model.name = "My Phone"

        await h.model.confirm()

        XCTAssertEqual(h.server.pairCalls, [.init(code: code, name: "My Phone", kind: .iphone, replace: false)])
        XCTAssertEqual(store.load(), DeviceCredential(token: "new-token-VmVyeU5ldw", deviceId: "dev-new",
                                                      serverId: "srv-new", name: "Paired Name"))
        XCTAssertEqual(h.effects.didPairCalls.count, 1)
        XCTAssertEqual(h.effects.didPairCalls.first?.credential, store.load())
        XCTAssertEqual(h.effects.didPairCalls.first?.address, address)
        XCTAssertEqual(h.effects.didPairCalls.first?.port, port)
        XCTAssertEqual(h.model.step, .succeeded(name: "Paired Name"),
                       "The success screen shows the name the server finally gave")
        XCTAssertEqual(h.log.count("effects.wipeContent"), 0)
        XCTAssertEqual(h.log.count("effects.unpairFromOldServer"), 0)
    }

    func testABlankNameFallsBackToTheKindAndNamesAreTrimmed() async throws {
        let blank = harness(checks: [.success(offer(hint: nil))])
        await blank.model.begin(address: address, port: port, code: code)
        blank.model.name = "   "
        await blank.model.confirm()
        XCTAssertEqual(blank.server.pairCalls.first?.name, "iPhone")

        let padded = harness(kind: .ipad)
        await padded.model.begin(address: address, port: port, code: code)
        padded.model.name = "  Studio iPad \n"
        await padded.model.confirm()
        XCTAssertEqual(padded.server.pairCalls.first?.name, "Studio iPad")
        XCTAssertEqual(padded.server.pairCalls.first?.kind, .ipad)
    }

    // MARK: - (b) D4: a failed check never reaches the confirmation or Pair

    func testAFailedCheckIsAFailureWithNoConfirmationAndNoPair() async throws {
        let cases: [(PairingError, PairingFailure)] = [
            (.expired, .expired), (.invalid, .invalid),
            (.unreachable, .unreachable), (.localNetworkDenied, .localNetworkDenied),
        ]
        for (error, failure) in cases {
            let h = harness(checks: [.failure(error)])
            let steps = recordSteps(h.model)

            await h.model.begin(address: address, port: port, code: code)

            XCTAssertEqual(h.model.step, .failed(failure, address: address, confirmation: nil), "\(error)")
            XCTAssertFalse(steps.confirmingSeen, "\(error): a confirmation must never be published")
            XCTAssertTrue(h.server.pairCalls.isEmpty, "\(error): the code must not be used up")
            XCTAssertGreaterThanOrEqual(h.server.closeCount, 1, "\(error): the socket is closed")

            await h.model.confirm()
            XCTAssertTrue(h.server.pairCalls.isEmpty, "\(error): confirm after a failure does nothing")
        }
    }

    func testTheModelShowsCheckingWhileTheCheckRuns() async throws {
        let h = harness()
        let steps = recordSteps(h.model)
        await h.model.begin(address: address, port: port, code: code)
        XCTAssertEqual(steps.steps.first, .idle)
        XCTAssertTrue(steps.steps.contains(.checking))
    }

    // MARK: - (c) A refusal on Pair after a good check

    func testARefusalOnPairKeepsTheConfirmationTheEditedNameAndTheOldCredential() async throws {
        for (error, failure) in [(PairingError.expired, PairingFailure.expired), (.invalid, .invalid)] {
            let store = InMemoryDeviceCredentialStore(oldCredential)
            let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: nil))],
                            pair: .failure(error), currentServer: ("192.168.1.9", 47101))
            await h.model.begin(address: address, port: port, code: code)
            let shown = try confirmation(of: h.model)
            h.model.name = "Edited name"

            await h.model.confirm()

            XCTAssertEqual(h.model.step, .failed(failure, address: address, confirmation: shown), "\(error)")
            XCTAssertEqual(h.model.name, "Edited name", "\(error): the operator's name is kept")
            XCTAssertEqual(store.load(), oldCredential, "\(error): the old credential is untouched")
            XCTAssertEqual(h.effects.didPairCalls.count, 0)
        }
    }

    func testARefusalOnAFreshPairKeepsTheConfirmationAndTheEditedName() async throws {
        let h = harness(pair: .failure(PairingError.expired))
        await h.model.begin(address: address, port: port, code: code)
        let shown = try confirmation(of: h.model)
        h.model.name = "Edited name"

        await h.model.confirm()

        XCTAssertEqual(h.model.step, .failed(.expired, address: address, confirmation: shown))
        XCTAssertEqual(h.model.name, "Edited name")
        XCTAssertEqual(h.log.count("effects.restartCurrentClient"), 0, "Nothing was stopped, so nothing is restarted")
    }

    // MARK: - (d) D6 with a stored credential

    func testWithAStoredCredentialTheSecondCheckCarriesAProofAndNeverTheTokenOrItsHash() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store,
                        checks: [.success(offer(challenge: "chal-1")), .success(offer(challenge: "chal-2", knows: true))],
                        currentServer: ("10.0.0.5", 47101))   // a pairing exists only with a saved address

        await h.model.begin(address: address, port: port, code: code)

        XCTAssertEqual(h.server.checkCalls.count, 2)
        XCTAssertNil(h.server.checkCalls[0].proof, "The first check asks for the challenge")
        let expectedProof = PairingClient.proof(token: oldCredential.token, challenge: "chal-1", code: code)
        XCTAssertEqual(h.server.checkCalls[1].proof, expectedProof,
                       "The proof is over the FIRST offer's challenge")
        XCTAssertEqual(h.makeServerCalls.calls.count, 1, "Both checks use the one socket")

        // Nothing the fake server was handed may be the token or anything derived from it by hashing.
        let digest = SHA256.hash(data: Data(oldCredential.token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let base64 = Data(digest).base64EncodedString()
        let base64URL = base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let forbidden = [oldCredential.token, hex, base64, base64URL]
        let handedOver = h.server.checkCalls.flatMap { [$0.code, $0.proof ?? ""] }
        for secret in forbidden {
            XCTAssertFalse(handedOver.contains { $0.contains(secret) }, "The server was handed \(secret)")
        }
    }

    func testWhenTheServerKnowsTheDeviceConfirmReplacesOnTheSameSocket() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: true))],
                        currentServer: ("10.0.0.5", 47101))
        await h.model.begin(address: address, port: port, code: code)
        XCTAssertEqual(try confirmation(of: h.model).existing, .sameServer)
        let beforeConfirm = h.log.events.count

        await h.model.confirm()

        XCTAssertEqual(Array(h.log.events.dropFirst(beforeConfirm)),
                       ["effects.stopCurrentClient", "server.pair(replace: true)", "effects.didPair"],
                       "Stop the old client, Pair with replace on the proof socket, then build the new client")
        XCTAssertEqual(h.makeServerCalls.calls.count, 1, "Replace needs the very socket the proof was sent on")
        XCTAssertEqual(h.log.count("effects.wipeContent"), 0, "The same server's content is kept")
        XCTAssertEqual(h.log.count("effects.unpairFromOldServer"), 0, "The pair itself replaced the old record")
        XCTAssertEqual(h.model.step, .succeeded(name: "Paired Name"))
    }

    func testWhenTheServerDoesNotKnowTheDeviceTheOldContentIsWipedBeforePairAndTheOldServerIsToldAfter() async throws {
        for knows in [false, nil] as [Bool?] {
            let store = InMemoryDeviceCredentialStore(oldCredential)
            let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: knows))],
                            currentServer: ("192.168.1.9", 47100))
            await h.model.begin(address: address, port: port, code: code)
            XCTAssertEqual(try confirmation(of: h.model).existing,
                           .differentServer(oldAddress: "192.168.1.9", oldPort: 47100),
                           "knowsDevice == \(String(describing: knows))")
            let beforeConfirm = h.log.events.count

            await h.model.confirm()

            XCTAssertEqual(Array(h.log.events.dropFirst(beforeConfirm)), [
                "effects.wipeContent",
                "effects.stopCurrentClient",
                "server.pair(replace: false)",
                "effects.unpairFromOldServer(192.168.1.9:47100)",
                "effects.didPair",
            ], "knowsDevice == \(String(describing: knows))")
            XCTAssertEqual(h.effects.unpaired.first?.credential, oldCredential,
                           "The old server is asked to forget us with the OLD credential")
            XCTAssertEqual(store.load()?.deviceId, "dev-new", "The new credential replaced the old one")
            XCTAssertEqual(h.model.step, .succeeded(name: "Paired Name"))
        }
    }

    func testTheOldServerIsToldAboutWhicheverAddressTheOldClientWasUsing() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: false))],
                        currentServer: ("old.example", 9000))
        await h.model.begin(address: address, port: port, code: code)
        await h.model.confirm()
        XCTAssertEqual(h.effects.unpaired.first?.address, "old.example")
        XCTAssertEqual(h.effects.unpaired.first?.port, 9000)
    }

    // MARK: - (e) A failed Pair on a D6 path

    func testAFailedPairOnTheSameServerRestartsTheOldClientAndKeepsTheOldCredential() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: true))],
                        pair: .failure(PairingError.unreachable), currentServer: ("10.0.0.5", 47101))
        await h.model.begin(address: address, port: port, code: code)
        let shown = try confirmation(of: h.model)

        await h.model.confirm()

        XCTAssertGreaterThanOrEqual(h.log.count("effects.restartCurrentClient"), 1)
        XCTAssertEqual(store.load(), oldCredential)
        XCTAssertEqual(h.effects.didPairCalls.count, 0)
        XCTAssertEqual(h.model.step, .failed(.unreachable, address: address, confirmation: shown))
    }

    func testAFailedPairOnADifferentServerRestartsTheOldClientAndDoesNotTouchTheOldServer() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: false))],
                        pair: .failure(PairingError.invalid), currentServer: ("192.168.1.9", 47100))
        await h.model.begin(address: address, port: port, code: code)
        let shown = try confirmation(of: h.model)

        await h.model.confirm()

        XCTAssertGreaterThanOrEqual(h.log.count("effects.restartCurrentClient"), 1)
        XCTAssertEqual(h.log.count("effects.unpairFromOldServer"), 0, "The old pairing was not given up")
        XCTAssertEqual(store.load(), oldCredential)
        XCTAssertEqual(h.effects.didPairCalls.count, 0)
        XCTAssertEqual(h.model.step, .failed(.invalid, address: address, confirmation: shown))
    }

    // MARK: - (f) The proof socket went away

    func testASameServerConfirmOnADeadSocketFailsAsUnreachableWithoutPairing() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: true))],
                        currentServer: ("10.0.0.5", 47101))
        await h.model.begin(address: address, port: port, code: code)
        let shown = try confirmation(of: h.model)
        h.server.isOpen = false

        await h.model.confirm()

        XCTAssertTrue(h.server.pairCalls.isEmpty, "A replace without its proof socket must not be sent")
        XCTAssertEqual(h.model.step, .failed(.unreachable, address: address, confirmation: shown))
        XCTAssertEqual(h.log.count("effects.stopCurrentClient"), 0, "The working pairing is left running")
        XCTAssertEqual(h.log.count("effects.wipeContent"), 0)
        XCTAssertEqual(store.load(), oldCredential)
    }

    // MARK: - (g) The Keychain refuses

    func testAnUnsavableCredentialIsNotSavedAndDoesNotBuildAClient() async throws {
        let h = harness(store: FailingCredentialStore())
        await h.model.begin(address: address, port: port, code: code)
        let shown = try confirmation(of: h.model)

        await h.model.confirm()

        XCTAssertEqual(h.model.step, .failed(.notSaved, address: address, confirmation: shown))
        XCTAssertEqual(h.effects.didPairCalls.count, 0)
    }

    // MARK: - (h) reset

    func testResetClosesTheServerAndReturnsToIdle() async throws {
        let h = harness()
        await h.model.begin(address: address, port: port, code: code)
        let closesBefore = h.server.closeCount

        h.model.reset()

        XCTAssertEqual(h.model.step, .idle)
        XCTAssertEqual(h.server.closeCount, closesBefore + 1)
    }

    func testResetAfterAFailureReturnsToIdle() async throws {
        let h = harness(checks: [.failure(PairingError.invalid)])
        await h.model.begin(address: address, port: port, code: code)
        h.model.reset()
        XCTAssertEqual(h.model.step, .idle)
    }

    // MARK: - (i) The old token never goes to an address it was not issued for

    /// The reinstall case: the Keychain outlived the app, the saved address did not, and a pairing link
    /// (anyone can send one) names a server. With no saved address there is no old pairing, so the
    /// link's server must not be handed a proof over the old token, told "you are replaced", or asked
    /// to forget the device.
    func testALinkedAddressWithNoSavedServerNeverGetsAProofOrTheOldCredential() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store,
                        checks: [.success(offer(challenge: "hostile-challenge")), .success(offer(knows: true))],
                        currentServer: nil)

        await h.model.begin(address: "hostile.local", port: 4444, code: code)

        XCTAssertEqual(h.server.checkCalls, [.init(code: code, proof: nil)],
                       "Only the proof-less check: a proof over the old token must never be computed for a link")
        XCTAssertEqual(h.makeServerCalls.calls.count, 1)
        XCTAssertEqual(h.makeServerCalls.calls.first?.0, "hostile.local")
        let shown = try confirmation(of: h.model)
        XCTAssertEqual(shown.existing, .none, "No saved address means no existing pairing to replace or warn about")
        XCTAssertEqual(shown.address, "hostile.local")

        let beforeConfirm = h.log.events.count
        await h.model.confirm()

        XCTAssertEqual(Array(h.log.events.dropFirst(beforeConfirm)), ["server.pair(replace: false)", "effects.didPair"],
                       "Nothing is stopped, wiped or sent to an old server")
        XCTAssertEqual(h.server.pairCalls.map(\.replace), [false])
        XCTAssertTrue(h.effects.unpaired.isEmpty, "No unpair call to any address, least of all the link's")
        XCTAssertEqual(h.log.count("effects.unpairFromOldServer"), 0)
        XCTAssertEqual(h.log.count("effects.wipeContent"), 0)
        XCTAssertEqual(h.log.count("effects.stopCurrentClient"), 0)
        XCTAssertEqual(h.model.step, .succeeded(name: "Paired Name"))
    }

    func testWithNoSavedServerNoCallCarriesTheOldTokenOrAnythingDerivedFromIt() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, currentServer: nil)

        await h.model.begin(address: "hostile.local", port: 4444, code: code)
        await h.model.confirm()

        let handedOver = h.server.checkCalls.flatMap { [$0.code, $0.proof ?? ""] }
            + h.server.pairCalls.flatMap { [$0.code, $0.name] }
        XCTAssertFalse(handedOver.contains { $0.contains(oldCredential.token) })
        XCTAssertTrue(h.server.checkCalls.allSatisfy { $0.proof == nil })
    }

    func testWithASavedServerALinkToAnotherAddressStillProvesAndWarnsAboutTheSavedServerNotTheLink() async throws {
        let store = InMemoryDeviceCredentialStore(oldCredential)
        let h = harness(store: store, checks: [.success(offer()), .success(offer(knows: false))],
                        currentServer: ("192.168.1.9", 47100))

        await h.model.begin(address: "link.local", port: 4444, code: code)

        XCTAssertEqual(h.server.checkCalls.count, 2)
        XCTAssertNil(h.server.checkCalls[0].proof)
        XCTAssertNotNil(h.server.checkCalls[1].proof, "The saved pairing exists, so the proof is still asked for (D6)")
        XCTAssertEqual(try confirmation(of: h.model).existing,
                       .differentServer(oldAddress: "192.168.1.9", oldPort: 47100),
                       "The old pairing is the saved address, never the link's")

        await h.model.confirm()

        XCTAssertEqual(h.effects.unpaired.count, 1)
        XCTAssertEqual(h.effects.unpaired.first?.address, "192.168.1.9")
        XCTAssertEqual(h.effects.unpaired.first?.port, 47100)
        XCTAssertEqual(h.effects.unpaired.first?.credential, oldCredential)
        XCTAssertEqual(h.effects.didPairCalls.first?.address, "link.local", "The new pairing is the link's")
    }

    func testASavedServerWithNoStoredCredentialIsAFreshPairingWithNoProof() async throws {
        let h = harness(store: InMemoryDeviceCredentialStore(), currentServer: ("192.168.1.9", 47100))

        await h.model.begin(address: address, port: port, code: code)

        XCTAssertEqual(h.server.checkCalls, [.init(code: code, proof: nil)])
        XCTAssertEqual(try confirmation(of: h.model).existing, .none)
    }

    // MARK: - (j) A malformed address

    func testABadAddressFailsTheCheckAsBadAddressWithNoConfirmationAndNoPair() async throws {
        let h = harness(checks: [.failure(PairingError.badAddress)])
        let steps = recordSteps(h.model)

        await h.model.begin(address: "bad host", port: port, code: code)

        XCTAssertEqual(h.model.step, .failed(.badAddress, address: "bad host", confirmation: nil))
        XCTAssertFalse(steps.confirmingSeen)
        XCTAssertTrue(h.server.pairCalls.isEmpty)
        XCTAssertGreaterThanOrEqual(h.server.closeCount, 1)
    }
}
