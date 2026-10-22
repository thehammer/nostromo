// NostromoKit — NeedsYouNotifierTests.swift
//
// What the person sees when Mother needs them (MC4): one quiet macOS notification per waiting
// item, with fixed wording and never any content from the job. Driven through a fake
// notification center; the notifier is fed snapshots exactly as the app does.

import XCTest
import UserNotifications
import NostromoKit

// MARK: - Fake notification center

final class FakeNotificationCenter: NotificationCenterLike {
    var status: NeedsYouAuthorization
    var grantResult: Bool
    /// When true, completions are held until `drain()`.
    var deferCompletions = false

    private(set) var statusReads = 0
    private(set) var authorizationRequests = 0
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedDelivered: [[String]] = []
    private(set) var removedPending: [[String]] = []

    private var pendingStatus: [(NeedsYouAuthorization) -> Void] = []
    private var pendingRequests: [(Bool) -> Void] = []

    init(status: NeedsYouAuthorization = .authorized, grantResult: Bool = true) {
        self.status = status
        self.grantResult = grantResult
    }

    func authorizationStatus(completion: @escaping (NeedsYouAuthorization) -> Void) {
        statusReads += 1
        if deferCompletions { pendingStatus.append(completion) } else { completion(status) }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        authorizationRequests += 1
        if deferCompletions { pendingRequests.append(completion) } else { resolveRequest(completion) }
    }

    private func resolveRequest(_ completion: @escaping (Bool) -> Void) {
        if status == .notDetermined { status = grantResult ? .authorized : .denied }
        completion(grantResult)
    }

    func add(request: UNNotificationRequest) { added.append(request) }
    func removeDelivered(ids: [String]) { removedDelivered.append(ids) }
    func removePending(ids: [String]) { removedPending.append(ids) }

    /// Complete every held callback (and any a completion starts) until none remain.
    func drain() {
        while !pendingStatus.isEmpty || !pendingRequests.isEmpty {
            let statuses = pendingStatus; pendingStatus = []
            for done in statuses { done(status) }
            let requests = pendingRequests; pendingRequests = []
            for done in requests { resolveRequest(done) }
        }
    }

    var addedIds: [String] { added.map(\.identifier) }
    var allRemovedDeliveredIds: [String] { removedDelivered.flatMap { $0 } }
    var allRemovedPendingIds: [String] { removedPending.flatMap { $0 } }
}

final class NeedsYouNotifierTests: XCTestCase {

    private let sentinels = ["SENTINEL-QUESTION-7f3", "SENTINEL-GATE-NAME", "SENTINEL-REPO", "SENTINEL-EXCERPT",
                             "SENTINEL-BRANCH", "SENTINEL-PLAN", "SENTINEL-PR"]

    // MARK: - Builders

    private func jobTitles(_ titles: [String: String]) -> MotherNeedsYouContentBuilder {
        MotherNeedsYouContentBuilder(jobTitle: { titles[$0] })
    }

    private func makeNotifier(_ center: FakeNotificationCenter, titles: [String: String] = ["j1": "Backfill invoice totals",
                                                                                           "j2": "Second job"]) -> NeedsYouNotifier {
        NeedsYouNotifier(center: center, builders: ["mother": jobTitles(titles)])
    }

    private func awaitingItem(_ job: String = "j1", reason: NeedsYouReason = .motherAwaiting,
                              sensitive: Bool = false) -> NeedsYouItem {
        NeedsYouItem(id: "mother:\(job):await", source: .motherJob(job), reason: reason, since: nil, sensitive: sensitive)
    }

    private func attentionItem(_ job: String = "j1", _ reason: MotherAttentionReason) -> NeedsYouItem {
        NeedsYouItem(id: "mother:\(job):\(reason.raw)", source: .motherJob(job), reason: .motherAttention(reason))
    }

    private func snapshot(_ items: [NeedsYouItem], producer: String = "mother") -> NeedsYouSnapshot {
        var agg = NeedsYouAggregator()
        return agg.set(producer: producer, items: items)
    }

    private func onlyRequest(_ center: FakeNotificationCenter, file: StaticString = #filePath, line: UInt = #line) throws -> UNNotificationRequest {
        XCTAssertEqual(center.added.count, 1, "expected exactly one notification, got \(center.addedIds)", file: file, line: line)
        return try XCTUnwrap(center.added.first, file: file, line: line)
    }

    // MARK: - Wording

    func testANewAwaitingJobPostsOneNotificationWithTheFixedWording() throws {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1")]))

        let request = try onlyRequest(center)
        XCTAssertEqual(request.identifier, "mother:j1:await")
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.title, "Mother needs you")
        XCTAssertEqual(request.content.body, "Backfill invoice totals · Waiting for your answer")
        XCTAssertEqual(request.content.threadIdentifier, "mother")
        XCTAssertEqual(request.content.userInfo as? [String: String],
                       ["needsYouId": "mother:j1:await", "producer": "mother", "jobId": "j1"])
    }

    func testEachReasonHasItsLabelInTheBody() throws {
        let cases: [(NeedsYouItem, String)] = [
            (awaitingItem(reason: .motherHold(.gatesExhausted)), "Gates exhausted, choose how to proceed"),
            (awaitingItem(reason: .motherHold(.reviewHold)), "Review hold"),
            (awaitingItem(reason: .motherHold(.decision)), "Waiting for your answer"),
            (awaitingItem(reason: .motherAwaiting), "Waiting for your answer"),
            (attentionItem("j1", .progressStalled), "Stalled"),
            (attentionItem("j1", .burnAhead), "Burning ahead of progress"),
            (attentionItem("j1", .gatesIncomplete), "Gates incomplete"),
        ]
        for (item, label) in cases {
            let center = FakeNotificationCenter()
            makeNotifier(center).apply(snapshot([item]))
            let request = try onlyRequest(center)
            XCTAssertEqual(request.content.body, "Backfill invoice totals · \(label)", "\(item.reason)")
        }
    }

    func testReasonLabelsAreExposedForMotherReasons() {
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherHold(.gatesExhausted)), "Gates exhausted, choose how to proceed")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherHold(.reviewHold)), "Review hold")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherHold(.decision)), "Waiting for your answer")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherAwaiting), "Waiting for your answer")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherAttention(.progressStalled)), "Stalled")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherAttention(.burnAhead)), "Burning ahead of progress")
        XCTAssertEqual(MotherNeedsYouContentBuilder.reasonLabel(.motherAttention(.gatesIncomplete)), "Gates incomplete")
    }

    func testAWorkSendJobsBodyIsTheReasonLabelAloneWithoutItsTitle() throws {
        let center = FakeNotificationCenter()
        makeNotifier(center, titles: ["j1": "Send the quarterly letter to Mrs Alvarez"])
            .apply(snapshot([awaitingItem("j1", reason: .motherHold(.reviewHold), sensitive: true)]))

        let request = try onlyRequest(center)
        XCTAssertEqual(request.content.body, "Review hold")
        XCTAssertFalse(request.content.body.contains("Alvarez"))
        XCTAssertEqual(request.content.title, "Mother needs you")
    }

    func testALongJobTitleIsCutToSixtyCharactersWithAnEllipsis() throws {
        let long = String(repeating: "abcdefghij", count: 10)
        let center = FakeNotificationCenter()
        makeNotifier(center, titles: ["j1": long]).apply(snapshot([awaitingItem("j1")]))

        let body = try onlyRequest(center).content.body
        let separator = " · "
        let range = try XCTUnwrap(body.range(of: separator), body)
        let shownTitle = String(body[body.startIndex..<range.lowerBound])
        XCTAssertLessThanOrEqual(shownTitle.count, 60, shownTitle)
        XCTAssertTrue(shownTitle.hasSuffix("…"), shownTitle)
        XCTAssertTrue(shownTitle.hasPrefix(String(long.prefix(55))), shownTitle)
        XCTAssertTrue(body.hasSuffix("Waiting for your answer"), body)
    }

    func testATitleOfExactlySixtyCharactersIsShownWhole() throws {
        let sixty = String(repeating: "x", count: 60)
        let center = FakeNotificationCenter()
        makeNotifier(center, titles: ["j1": sixty]).apply(snapshot([awaitingItem("j1")]))

        XCTAssertEqual(try onlyRequest(center).content.body, "\(sixty) · Waiting for your answer")
    }

    // MARK: - Nothing from the job leaks

    func testNoNotificationContainsQuestionGateRepoOrAnyOtherJobContent() throws {
        let crew = MotherCrewState(
            activity: "gate_hold",
            prUrl: "https://example.test/SENTINEL-PR/1",
            gates: MotherGates(status: "exhausted", attempt: 3, maxAttempts: 3,
                               results: [MotherGateResultEntry(name: "SENTINEL-GATE-NAME", result: .failed, blocking: true,
                                                               unavailableReason: "SENTINEL-EXCERPT")]),
            decision: MotherDecision(id: "d-1", kind: "gate_hold", options: [], openedAt: "2026-10-17T12:00:02.000Z"),
            attention: [MotherAttention(reason: .decisionAwaiting, since: "2026-10-17T12:00:02.000Z"),
                        MotherAttention(reason: .progressStalled, since: "2026-10-17T12:01:00.000Z"),
                        MotherAttention(reason: .burnAhead, since: "2026-10-17T12:02:00.000Z"),
                        MotherAttention(reason: .gatesIncomplete, since: "2026-10-17T12:03:00.000Z")])
        let motherJob = MotherJob(id: "j-hold1", state: "awaiting", title: "Backfill invoice totals",
                                  repo: "SENTINEL-REPO", branch: "SENTINEL-BRANCH", prUrl: "https://example.test/SENTINEL-PR/1",
                                  question: "SENTINEL-QUESTION-7f3 which of the patients", crew: crew)

        var agg = NeedsYouAggregator()
        let snap = agg.set(producer: MotherNeedsYouProducer.name, items: MotherNeedsYouProducer.items(from: [motherJob]))
        XCTAssertEqual(snap.total, 4, "the awaiting hold plus three flags")

        let center = FakeNotificationCenter()
        let notifier = NeedsYouNotifier(center: center, builders: [
            "mother": MotherNeedsYouContentBuilder(jobTitle: { $0 == motherJob.id ? motherJob.title : nil })])
        notifier.apply(snap)

        XCTAssertEqual(center.added.count, 4)
        for request in center.added {
            var haystack = [request.identifier, request.content.title, request.content.body,
                            request.content.subtitle, request.content.threadIdentifier]
            for (key, value) in request.content.userInfo { haystack.append("\(key)"); haystack.append("\(value)") }
            for text in haystack {
                for sentinel in sentinels {
                    XCTAssertFalse(text.contains(sentinel), "\(sentinel) leaked into \(text)")
                }
            }
            XCTAssertEqual(request.content.userInfo["jobId"] as? String, "j-hold1")
        }
    }

    func testNotificationsHaveNoActionsNoCategoryAndNoTimeSensitiveLevel() throws {
        let center = FakeNotificationCenter()
        makeNotifier(center).apply(snapshot([awaitingItem("j1"), attentionItem("j1", .progressStalled)]))

        XCTAssertEqual(center.added.count, 2)
        for request in center.added {
            XCTAssertEqual(request.content.categoryIdentifier, "")
            if #available(macOS 12.0, iOS 15.0, *) {
                XCTAssertEqual(request.content.interruptionLevel, .active)
            }
            XCTAssertNil(request.trigger)
        }
    }

    // MARK: - Attention flags

    func testEachUnackedFlagGivesOneNotificationAndAckingRemovesIt() throws {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        let stalled = attentionItem("j1", .progressStalled)
        let burning = attentionItem("j1", .burnAhead)
        let incomplete = attentionItem("j1", .gatesIncomplete)

        notifier.apply(snapshot([stalled, burning, incomplete]))
        XCTAssertEqual(Set(center.addedIds), [stalled.id, burning.id, incomplete.id])
        XCTAssertEqual(center.added.count, 3)

        notifier.apply(snapshot([burning, incomplete]))   // the stalled flag was acked
        XCTAssertEqual(center.added.count, 3, "nothing new is posted")
        XCTAssertEqual(center.allRemovedDeliveredIds, [stalled.id])
        XCTAssertEqual(center.allRemovedPendingIds, [stalled.id])
    }

    // MARK: - Once only, and removal

    func testTheSameItemIsNeverPostedAgainWhileItStaysPresent() {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        let snap = snapshot([awaitingItem("j1")])

        notifier.apply(snap)
        notifier.apply(snap)
        notifier.apply(snapshot([awaitingItem("j1"), awaitingItem("j2")]))

        XCTAssertEqual(center.addedIds, ["mother:j1:await", "mother:j2:await"])
    }

    func testAResolvedItemIsRemovedFromDeliveredAndPending() {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        notifier.apply(snapshot([awaitingItem("j1"), awaitingItem("j2")]))

        notifier.apply(snapshot([awaitingItem("j2")]))

        XCTAssertEqual(center.allRemovedDeliveredIds, ["mother:j1:await"])
        XCTAssertEqual(center.allRemovedPendingIds, ["mother:j1:await"])
        XCTAssertEqual(center.added.count, 2)
    }

    func testAnItemThatReturnsAfterBeingResolvedIsPostedAgain() {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        notifier.apply(snapshot([awaitingItem("j1")]))
        notifier.apply(NeedsYouSnapshot.empty)
        notifier.apply(snapshot([awaitingItem("j1")]))

        XCTAssertEqual(center.addedIds, ["mother:j1:await", "mother:j1:await"])
    }

    func testNothingIsRemovedWhenNothingWasResolved() {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        notifier.apply(snapshot([awaitingItem("j1")]))
        notifier.apply(snapshot([awaitingItem("j1")]))
        XCTAssertTrue(center.allRemovedDeliveredIds.isEmpty)
        XCTAssertTrue(center.allRemovedPendingIds.isEmpty)
    }

    // MARK: - Authorization

    func testAuthorizationIsNotRequestedAtInitOrForAnEmptySnapshot() {
        let center = FakeNotificationCenter(status: .notDetermined)
        let notifier = makeNotifier(center)
        XCTAssertEqual(center.authorizationRequests, 0)

        notifier.apply(NeedsYouSnapshot.empty)

        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testRefreshAuthorizationReadsTheStatusAndNeverPrompts() {
        let center = FakeNotificationCenter(status: .notDetermined)
        let notifier = makeNotifier(center)
        XCTAssertNil(notifier.authorization)

        notifier.refreshAuthorization()

        XCTAssertEqual(notifier.authorization, .notDetermined)
        XCTAssertFalse(notifier.isSurfaceAvailable)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testTheFirstPostableItemRequestsAuthorizationThenPostsWhenGranted() throws {
        let center = FakeNotificationCenter(status: .notDetermined, grantResult: true)
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1")]))

        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(notifier.isSurfaceAvailable)
        XCTAssertEqual(try onlyRequest(center).identifier, "mother:j1:await")
    }

    func testAnAlreadyAuthorizedCenterIsNeverAskedAgain() {
        let center = FakeNotificationCenter(status: .authorized)
        let notifier = makeNotifier(center)
        notifier.apply(snapshot([awaitingItem("j1")]))
        notifier.apply(snapshot([awaitingItem("j1"), awaitingItem("j2")]))
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(center.added.count, 2)
    }

    func testDeniedNeverPostsAndTheSurfaceIsUnavailable() {
        let center = FakeNotificationCenter(status: .denied)
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1"), attentionItem("j1", .burnAhead)]))

        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0, "a denial is never re-prompted")
        XCTAssertFalse(notifier.isSurfaceAvailable)
        XCTAssertEqual(notifier.authorization, .denied)
    }

    func testARefusedPromptPostsNothingAndTheSurfaceIsUnavailable() {
        let center = FakeNotificationCenter(status: .notDetermined, grantResult: false)
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1")]))

        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertFalse(notifier.isSurfaceAvailable)
    }

    func testWhileAuthorizationIsUndecidedTheSurfaceIsUnavailableAndTheWaitingItemsPostOnceGranted() {
        let center = FakeNotificationCenter(status: .notDetermined, grantResult: true)
        center.deferCompletions = true
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1")]))
        notifier.apply(snapshot([awaitingItem("j1"), awaitingItem("j2")]))

        XCTAssertFalse(notifier.isSurfaceAvailable)
        XCTAssertTrue(center.added.isEmpty, "nothing posts before the answer")
        XCTAssertLessThanOrEqual(center.authorizationRequests, 1)

        center.drain()

        XCTAssertEqual(center.authorizationRequests, 1, "one prompt however many snapshots arrived meanwhile")
        XCTAssertTrue(notifier.isSurfaceAvailable)
        XCTAssertEqual(center.addedIds.sorted(), ["mother:j1:await", "mother:j2:await"])
    }

    func testAnItemResolvedWhileAuthorizationWasPendingIsNotPosted() {
        let center = FakeNotificationCenter(status: .notDetermined, grantResult: true)
        center.deferCompletions = true
        let notifier = makeNotifier(center)

        notifier.apply(snapshot([awaitingItem("j1")]))
        notifier.apply(NeedsYouSnapshot.empty)
        center.drain()

        XCTAssertTrue(center.added.isEmpty, "\(center.addedIds)")
    }

    func testSurfaceAvailabilityChangeIsReportedOnceAndOnlyOnChange() {
        let center = FakeNotificationCenter(status: .authorized)
        let notifier = makeNotifier(center)
        var seen: [Bool] = []
        notifier.onSurfaceAvailabilityChange = { seen.append($0) }

        notifier.refreshAuthorization()
        XCTAssertEqual(seen.last, true)
        let afterFirst = seen.count

        notifier.refreshAuthorization()
        XCTAssertEqual(seen.count, afterFirst, "no change, no callback")

        center.status = .denied
        notifier.refreshAuthorization()
        XCTAssertEqual(seen.count, afterFirst + 1)
        XCTAssertEqual(seen.last, false)
        XCTAssertFalse(notifier.isSurfaceAvailable)
    }

    func testAvailabilityIsReportedWhenAPromptIsGranted() {
        let center = FakeNotificationCenter(status: .notDetermined, grantResult: true)
        let notifier = makeNotifier(center)
        var seen: [Bool] = []
        notifier.onSurfaceAvailabilityChange = { seen.append($0) }

        notifier.apply(snapshot([awaitingItem("j1")]))

        XCTAssertEqual(seen.last, true)
    }

    // MARK: - Producers without a builder

    func testItemsForAProducerWithNoBuilderAreNotPosted() {
        let center = FakeNotificationCenter()
        let notifier = makeNotifier(center)
        let other = NeedsYouItem(id: "decisions:tag", source: .focus("tag"), reason: .decisionOpen)

        var agg = NeedsYouAggregator()
        agg.set(producer: "decisions", items: [other])
        let snap = agg.set(producer: "mother", items: [awaitingItem("j1")])
        XCTAssertEqual(snap.total, 2, "still counted")

        notifier.apply(snap)

        XCTAssertEqual(center.addedIds, ["mother:j1:await"])
    }

    func testASnapshotOfOnlyUnbuiltItemsDoesNotAskForAuthorization() {
        let center = FakeNotificationCenter(status: .notDetermined)
        let notifier = makeNotifier(center)
        notifier.apply(snapshot([NeedsYouItem(id: "decisions:tag", source: .focus("tag"), reason: .decisionOpen)], producer: "decisions"))

        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testTheMotherBuilderMakesNothingForANonMotherItem() {
        let builder = jobTitles(["j1": "t"])
        XCTAssertNil(builder.content(for: NeedsYouItem(id: "decisions:tag", source: .focus("tag"), reason: .decisionOpen)))
        XCTAssertNil(builder.content(for: NeedsYouItem(id: "approvals:1", source: .app, reason: .approvalPending(1))))
    }
}
