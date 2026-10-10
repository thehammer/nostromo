import XCTest
import Combine

// Behavioural spec for `SidebarBadgeModel`: the per-tag badges the sidebar shows, which
// tags need the operator, where a pill click lands, and the refresh debounce. All times
// are injected; nothing reads the wall clock and nothing is timing-asserted.

final class SidebarBadgeModelTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-10-10 15:00:00 UTC (10:00 CDT).
    private let now = Date(timeIntervalSince1970: 1_791_644_400)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: Data(json.utf8))
    }

    private func mailbox(unread: Int, stale: Bool = false) throws -> MailboxSnapshot {
        try decode(MailboxSnapshot.self, "{\"unread_count\": \(unread), \"stale\": \(stale), \"items\": []}")
    }

    private func todos(_ dues: [String?], stale: Bool = false) throws -> TeriTodosSnapshot {
        let items = dues.enumerated().map { i, due -> String in
            let d = due.map { "\"due_date\": \"\($0)\"," } ?? ""
            return "{\"id\": \(i + 1), \(d) \"title\": \"t\(i)\", \"status\": \"open\", \"priority\": 3}"
        }
        return try decode(TeriTodosSnapshot.self, "{\"items\": [\(items.joined(separator: ","))], \"stale\": \(stale)}")
    }

    private func inputs(
        mail: MailboxSnapshot? = nil, teri: TeriTodosSnapshot? = nil, mother: MotherStatus = MotherStatus(),
        perri: Int = 0, perriStale: Bool = false, perriError: String? = nil, perriLoading: Bool = false
    ) -> BadgeInputs {
        BadgeInputs(fredMailbox: mail, fredCalendar: nil, teriTodos: teri, motherStatus: mother,
                    perriQueueCount: perri, perriQueueStale: perriStale,
                    perriQueueError: perriError, perriQueueLoading: perriLoading)
    }

    private func updated(_ i: BadgeInputs, from model: SidebarBadgeModel = SidebarBadgeModel()) -> SidebarBadgeModel {
        var m = model
        m.update(i, now: now)
        return m
    }

    private func isCount(_ pill: String?) -> Bool {
        pill?.rangeOfCharacter(from: .decimalDigits) != nil
    }

    // MARK: - Publishing per tag

    func testUpdatePublishesEachBuiltInRowsBadgeUnderItsOwnTag() throws {
        let m = updated(inputs(mail: try mailbox(unread: 12),
                               teri: try todos(["2026-10-10", nil]),
                               mother: MotherStatus(running: 2, queued: 1),
                               perri: 4))
        XCTAssertEqual(m.badge(for: "fred")?.pill, "12")
        XCTAssertEqual(m.badge(for: "teri")?.pill, "2")
        XCTAssertEqual(m.badge(for: "mother")?.pill, "3")
        XCTAssertEqual(m.badge(for: "perri")?.pill, "4")
    }

    func testBadgeIsNilForTagsWithNothingToShowAndForUnknownTags() {
        let m = updated(inputs())
        for tag in ["fred", "teri", "mother", "perri", "no-such-tag"] {
            XCTAssertNil(m.badge(for: tag), tag)
        }
    }

    func testAFreshModelHasNoBadgesAndNoAttention() {
        let m = SidebarBadgeModel()
        XCTAssertNil(m.badge(for: "fred"))
        XCTAssertTrue(m.attentionTags.isEmpty)
    }

    func testUpdateReplacesThePreviousBadgesAndClearsWhatNoLongerApplies() throws {
        var m = updated(inputs(mail: try mailbox(unread: 12), perri: 4))
        m.update(inputs(), now: now)
        XCTAssertNil(m.badge(for: "fred"))
        XCTAssertNil(m.badge(for: "perri"))
    }

    // MARK: - Attention

    func testOverdueTodosPutTeriInTheAttentionTags() throws {
        let m = updated(inputs(teri: try todos(["2026-10-09"])))
        XCTAssertEqual(m.attentionTags, ["teri"])
    }

    func testCombinedAttentionTagsKeepStoreTagsAndAddBadgeTags() throws {
        let m = updated(inputs(teri: try todos(["2026-10-09"])))
        XCTAssertEqual(m.combinedAttentionTags(storeTags: ["fred"]), ["fred", "teri"])
    }

    func testCombinedAttentionTagsWithNoBadgeAttentionAreExactlyTheStoreTags() throws {
        let m = updated(inputs(teri: try todos(["2026-10-20"])))
        XCTAssertEqual(m.combinedAttentionTags(storeTags: ["fred", "perri"]), ["fred", "perri"])
        XCTAssertEqual(SidebarBadgeModel().combinedAttentionTags(storeTags: ["x"]), ["x"])
    }

    func testMotherAwaitingNeedsAttention() {
        let m = updated(inputs(mother: MotherStatus(awaiting: 1)))
        XCTAssertTrue(m.attentionTags.contains("mother"))
    }

    // MARK: - Fresh then stale

    func testTeriGoingStaleDropsItsPillAndItsOverdueAttention() throws {
        var m = updated(inputs(teri: try todos(["2026-10-09"])))
        XCTAssertEqual(m.badge(for: "teri")?.pill, "1")
        XCTAssertTrue(m.attentionTags.contains("teri"))

        m.update(inputs(teri: try todos(["2026-10-09"], stale: true)), now: now)
        XCTAssertFalse(isCount(m.badge(for: "teri")?.pill))
        XCTAssertFalse(m.attentionTags.contains("teri"))
        XCTAssertEqual(m.combinedAttentionTags(storeTags: []), [])
    }

    func testFredMailGoingStaleDropsTheUnreadCount() throws {
        var m = updated(inputs(mail: try mailbox(unread: 12)))
        XCTAssertEqual(m.badge(for: "fred")?.pill, "12")
        m.update(inputs(mail: try mailbox(unread: 12, stale: true)), now: now)
        XCTAssertFalse(isCount(m.badge(for: "fred")?.pill))
    }

    func testPerriQueueGoingStaleErroredOrLoadingDropsTheCount() {
        var m = updated(inputs(perri: 4))
        XCTAssertEqual(m.badge(for: "perri")?.pill, "4")

        m.update(inputs(perri: 4, perriStale: true), now: now)
        XCTAssertFalse(isCount(m.badge(for: "perri")?.pill), "stale")

        m.update(inputs(perri: 4), now: now)
        XCTAssertEqual(m.badge(for: "perri")?.pill, "4", "fresh again")

        m.update(inputs(perri: 4, perriError: "boom"), now: now)
        XCTAssertFalse(isCount(m.badge(for: "perri")?.pill), "error")

        m.update(inputs(perri: 4, perriLoading: true), now: now)
        XCTAssertFalse(isCount(m.badge(for: "perri")?.pill), "loading")
    }

    // MARK: - Deep links

    private func builtIn(_ tag: String) -> Focus { Focus.builtIns.first { $0.agentTag == tag }! }

    func testClickingTerisPillDeepLinksToTheTodosTab() {
        XCTAssertEqual(SidebarBadgeModel.deepLink(for: builtIn("teri")), .teriTab("todos"))
    }

    func testClickingFredsPillDeepLinksToTheInbox() {
        XCTAssertEqual(SidebarBadgeModel.deepLink(for: builtIn("fred")), .fredInbox)
    }

    func testPerriAndMotherPillsHaveNoDeepLink() {
        XCTAssertNil(SidebarBadgeModel.deepLink(for: builtIn("perri")))
        XCTAssertNil(SidebarBadgeModel.deepLink(for: builtIn("mother")))
    }

    func testDynamicFocusesHaveNoDeepLinkEvenWithATeriOrFredAgent() {
        for agent in ["teri", "fred", "cody"] {
            let dyn = Focus(id: "11111111-aaaa", agentTag: agent, projectPath: "/Users/hammer/Code/nostromo",
                            isBuiltIn: false, org: "Carefeed")
            XCTAssertNil(SidebarBadgeModel.deepLink(for: dyn), agent)
        }
    }

    // MARK: - Refresh debounce

    func testABurstOfChangesAcrossSourcesYieldsExactlyOneRefresh() {
        let a = PassthroughSubject<Void, Never>()
        let b = PassthroughSubject<Void, Never>()
        let emissions = expectation(description: "one refresh")
        emissions.assertForOverFulfill = true
        var cancellables = Set<AnyCancellable>()

        SidebarBadgeModel.debouncedRefresh(
            sources: [a.eraseToAnyPublisher(), b.eraseToAnyPublisher()],
            interval: .milliseconds(30), scheduler: DispatchQueue.main
        )
        .sink { emissions.fulfill() }
        .store(in: &cancellables)

        for i in 0..<20 { (i.isMultiple(of: 2) ? a : b).send() }

        wait(for: [emissions], timeout: 5)
        // Give any (incorrect) trailing emission a chance to surface; over-fulfilment fails the test.
        let settle = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
    }
}
