// NotificationEnricherTests.swift
//
// The Notification Service Extension's whole decision with the extension host taken out (W16): given
// a push's `userInfo` and the contract content, what to show. A personal host with a pairing, a token
// and a timely answer is enriched. Every other path returns the contract UNCHANGED, and the paths
// that are decided on the phone (no pairing, no token, work host, switched off, replacement,
// Summary, not ours) never even build a connection.

import XCTest
@testable import NostromoKit

final class NotificationEnricherTests: XCTestCase {

    private let contract = NotificationContent(title: "Mother · sendai", body: "Job 3f9a1c2e asked a question")
    private let address = SharedPushState.Address(host: "100.64.0.1", port: 7777)

    /// One extension run's worth of state: a throwaway App Group, a fake primary, a manual clock.
    private final class Rig: @unchecked Sendable {
        let suiteName = UUID().uuidString
        let defaults: UserDefaults
        let state: SharedPushState
        let clock = ManualClock()
        let transport: FakeDetailTransport
        private let lock = NSLock()
        private var built: [(SharedPushState.Address, String)] = []

        init(_ behaviour: FakeDetailTransport.Behaviour) {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            state = SharedPushState(defaults: defaults)
            transport = FakeDetailTransport(behaviour, clock: clock)
        }

        func cleanUp() {
            clock.drain()
            defaults.removePersistentDomain(forName: suiteName)
        }

        /// The connections the enricher asked for, as (address, token).
        var connections: [(SharedPushState.Address, String)] {
            lock.lock()
            defer { lock.unlock() }
            return built
        }

        func recordConnection(_ address: SharedPushState.Address, _ token: String) {
            lock.lock()
            built.append((address, token))
            lock.unlock()
        }

        func enricher(token tokenValue: String?) -> NotificationEnricher {
            let transport = self.transport
            return NotificationEnricher(
                state: state,
                token: { tokenValue },
                transport: { address, token in
                    self.recordConnection(address, token)
                    return transport
                },
                clock: clock)
        }
    }

    /// A rig for a paired phone with a personal host `sendai`, and the answer the primary will give.
    private func makeRig(_ behaviour: FakeDetailTransport.Behaviour) -> Rig {
        let rig = Rig(behaviour)
        rig.state.address = address
        rig.state.hostClasses = ["sendai": .personal, "kobe": .work]
        addTeardownBlock { rig.cleanUp() }
        return rig
    }

    private func userInfo(kind: String = "mother", host: String = "sendai", resolved: Bool? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Mother · sendai", "body": "Job 3f9a1c2e asked a question"], "mutable-content": 1],
            "item": "item-1", "kind": kind, "host": host, "ref": "Job 3f9a1c2e",
        ]
        if let resolved { info["resolved"] = resolved }
        return info
    }

    private var goodAnswer: FakeDetailTransport.Behaviour {
        .reply(detailFrame(itemRef: "item-1", text: "Rename the helper before merging?"), after: 0)
    }

    // MARK: - Enriched

    func testAPersonalHostWithAPairingATokenAndAnAnswerIsEnriched() async {
        let rig = makeRig(goodAnswer)
        let out = await rig.enricher(token: "tok_abc").enrich(userInfo: userInfo(), contract: contract)

        XCTAssertEqual(out.title, "Mother · sendai")
        XCTAssertEqual(out.subtitle, "Job 3f9a1c2e asked a question")
        XCTAssertEqual(out.body, "Rename the helper before merging?")
        XCTAssertEqual(rig.transport.requestedRefs, ["item-1"])
        XCTAssertEqual(rig.connections.count, 1)
        XCTAssertEqual(rig.connections.first?.0, address, "it connects to the address the app saved")
        XCTAssertEqual(rig.connections.first?.1, "tok_abc", "with the token from the Keychain")
    }

    func testAReviewIsEnrichedLikeAMotherJob() async {
        let rig = makeRig(goodAnswer)
        let out = await rig.enricher(token: "tok_abc").enrich(userInfo: userInfo(kind: "review"), contract: contract)
        XCTAssertEqual(out.body, "Rename the helper before merging?")
        XCTAssertEqual(out.subtitle, contract.body)
    }

    func testADecisionIsEnrichedAndSaysToAnswerOnTheMac() async {
        let rig = makeRig(goodAnswer)
        let out = await rig.enricher(token: "tok_abc").enrich(userInfo: userInfo(kind: "decision"), contract: contract)
        XCTAssertEqual(out.body, "Rename the helper before merging? · answer on your Mac")
        XCTAssertEqual(out.subtitle, contract.body)
    }

    // MARK: - Refused on the phone: the contract, and no connection at all

    private func assertRefused(_ label: String, token: String? = "tok_abc",
                               userInfo: [AnyHashable: Any]? = nil,
                               configure: (SharedPushState) -> Void = { _ in },
                               file: StaticString = #filePath, line: UInt = #line) async {
        // The primary would happily answer: only the phone's own gate stands in the way.
        let rig = makeRig(goodAnswer)
        configure(rig.state)
        let out = await rig.enricher(token: token).enrich(userInfo: userInfo ?? self.userInfo(), contract: contract)
        XCTAssertEqual(out, contract, label, file: file, line: line)
        XCTAssertEqual(rig.transport.requestedRefs, [], "\(label): the primary was never asked", file: file, line: line)
        XCTAssertEqual(rig.connections.count, 0, "\(label): no connection was built", file: file, line: line)
    }

    func testWithNoPairingAddressTheContractIsDelivered() async {
        await assertRefused("no address") { $0.address = nil }
    }

    func testWithNoTokenTheContractIsDelivered() async {
        await assertRefused("no token", token: nil)
        await assertRefused("empty token", token: "")
    }

    func testAWorkHostIsNeverAsked() async {
        await assertRefused("work host", userInfo: userInfo(host: "kobe"))
    }

    func testAHostThePhoneHasNotHeardOfIsTreatedAsWork() async {
        await assertRefused("unknown host", userInfo: userInfo(host: "tokyo"))
        await assertRefused("no classes at all") { $0.hostClasses = [:] }
    }

    func testAHostTheOperatorSwitchedDetailsOffForIsNeverAsked() async {
        await assertRefused("switched off") { $0.enrichment = EnrichmentPrefs(disabledHosts: ["sendai"]) }
    }

    func testAReplacementIsNeverAskedAbout() async {
        await assertRefused("replacement", userInfo: userInfo(resolved: true))
    }

    func testASummaryIsNeverAskedAbout() async {
        await assertRefused("summary", userInfo: userInfo(kind: "summary", host: "all"))
    }

    func testAPushThatIsNotOursIsNeverAskedAbout() async {
        await assertRefused("empty userInfo", userInfo: [:])
        await assertRefused("unknown kind", userInfo: userInfo(kind: "calendar"))
        await assertRefused("item is not a string", userInfo: ["item": 7, "kind": "mother", "host": "sendai"])
        await assertRefused("no host", userInfo: ["item": "item-1", "kind": "mother"])
    }

    // MARK: - Asked, and the answer is no use: the contract

    func testARefusedConnectionDeliversTheContract() async {
        let rig = makeRig(.refuse)
        let out = await rig.enricher(token: "tok_abc").enrich(userInfo: userInfo(), contract: contract)
        XCTAssertEqual(out, contract)
        XCTAssertEqual(rig.transport.requestedRefs, ["item-1"], "it did try")
        XCTAssertEqual(rig.clock.now, 0, "and gave up without waiting")
    }

    func testAnAnswerThatNoLongerWaitsOrWithholdsItsTextDeliversTheContract() async {
        let answers: [(String, Data)] = [
            ("waiting false", detailFrame(itemRef: "item-1", waiting: false, text: "A line")),
            ("text withheld", detailFrame(itemRef: "item-1", waiting: true, text: nil)),
            ("blank text", detailFrame(itemRef: "item-1", waiting: true, text: "  \n ")),
            ("another item", detailFrame(itemRef: "item-2", waiting: true, text: "A line")),
            ("garbage", Data("<html>502</html>".utf8)),
            ("wrong type", Data(#"{"type":"welcome","protocol_version":4}"#.utf8)),
        ]
        for (label, data) in answers {
            let rig = makeRig(.reply(data, after: 0))
            let out = await rig.enricher(token: "tok_abc").enrich(userInfo: userInfo(), contract: contract)
            XCTAssertEqual(out, contract, label)
        }
    }

    func testAPrimaryThatStallsPastTheBudgetDeliversTheContractAndIsHungUpOn() async {
        let rig = makeRig(.reply(detailFrame(itemRef: "item-1"), after: 100))
        let enricher = rig.enricher(token: "tok_abc")
        let info = userInfo()
        let finished = Box<NotificationContent>()
        let task = Task { () -> NotificationContent in
            let out = await enricher.enrich(userInfo: info, contract: self.contract)
            finished.set(out)
            return out
        }
        let waiting = await rig.clock.waitForSleepers(2)
        XCTAssertTrue(waiting)

        await rig.clock.advance(by: 3.9)
        await rig.clock.settle()
        XCTAssertFalse(finished.isSet, "it still waits inside the 4 s budget")

        await rig.clock.advance(by: 0.15)
        let out = await task.value
        XCTAssertEqual(out, contract)
        let cancelled = await yieldUntil { rig.transport.wasCancelled }
        XCTAssertTrue(cancelled, "the abandoned request is cancelled")
    }

    func testAnAnswerThatArrivesJustInsideTheBudgetIsUsed() async {
        let rig = makeRig(.reply(detailFrame(itemRef: "item-1", text: "Just in time"), after: 3.9))
        let enricher = rig.enricher(token: "tok_abc")
        let info = userInfo()
        let task = Task { await enricher.enrich(userInfo: info, contract: self.contract) }
        let waiting = await rig.clock.waitForSleepers(2)
        XCTAssertTrue(waiting)

        await rig.clock.advance(by: 3.9)
        let out = await task.value
        XCTAssertEqual(out.body, "Just in time")
        XCTAssertEqual(out.subtitle, contract.body)
    }
}
