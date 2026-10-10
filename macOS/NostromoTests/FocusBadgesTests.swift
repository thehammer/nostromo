import XCTest
import AppKit

// Behavioural spec for sidebar focus badges (slice B1): what Fred, Mother, Perri and
// Teri rows show beyond their label (count pill, second line, attention) and how a real
// row presents it. All times are injected; nothing reads the wall clock.

final class FocusBadgesTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-10-10 15:00:00 UTC (10:00 CDT).
    private let now = Date(timeIntervalSince1970: 1_791_644_400)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: Data(json.utf8))
    }

    private func mailbox(unread: Int = 0, stale: Bool = false, error: String? = nil, auth: Bool = false) throws -> MailboxSnapshot {
        var parts = ["\"unread_count\": \(unread)", "\"stale\": \(stale)", "\"items\": []"]
        if let error { parts.append("\"error\": \"\(error)\"") }
        if auth {
            parts.append("\"auth_prompt\": {\"verification_uri\": \"https://example.com/device\", \"user_code\": \"ABCD\", \"expires_at\": \"\(iso.string(from: now.addingTimeInterval(900)))\"}")
        }
        return try decode(MailboxSnapshot.self, "{\(parts.joined(separator: ","))}")
    }

    private struct Ev {
        var title: String
        var startOffset: TimeInterval
        var duration: TimeInterval = 1800
        var status: String = "accepted"
        var allDay: Bool = false
    }

    private func calendar(_ events: [Ev], stale: Bool = false, error: String? = nil) throws -> CalendarSnapshot {
        let evs = events.map { e -> String in
            let s = iso.string(from: now.addingTimeInterval(e.startOffset))
            let en = iso.string(from: now.addingTimeInterval(e.startOffset + e.duration))
            return "{\"start\": \"\(s)\", \"end\": \"\(en)\", \"title\": \"\(e.title)\", \"status\": \"\(e.status)\", \"is_now\": false\(e.allDay ? ", \"is_all_day\": true" : "")}"
        }
        var parts = ["\"events\": [\(evs.joined(separator: ","))]", "\"sweater\": \"\"", "\"stale\": \(stale)"]
        if let error { parts.append("\"error\": \"\(error)\"") }
        return try decode(CalendarSnapshot.self, "{\(parts.joined(separator: ","))}")
    }

    private func todos(_ dues: [String?], stale: Bool = false, error: String? = nil) throws -> TeriTodosSnapshot {
        let items = dues.enumerated().map { i, due -> String in
            let d = due.map { "\"due_date\": \"\($0)\"," } ?? ""
            return "{\"id\": \(i + 1), \(d) \"title\": \"t\(i)\", \"status\": \"open\", \"priority\": 3}"
        }
        var parts = ["\"items\": [\(items.joined(separator: ","))]", "\"stale\": \(stale)"]
        if let error { parts.append("\"error\": \"\(error)\"") }
        return try decode(TeriTodosSnapshot.self, "{\(parts.joined(separator: ","))}")
    }

    private func fred(_ m: MailboxSnapshot?, _ c: CalendarSnapshot?) -> FocusBadge? {
        BadgeProviders.fred(mailbox: m, calendar: c, now: now)
    }

    // MARK: - Fred: mail

    func testFredShowsUnreadCountAsThePill() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 12), nil))
        XCTAssertEqual(badge.pill, "12")
    }

    func testFredWithNothingUnreadAndNoCalendarShowsNothing() throws {
        XCTAssertNil(fred(try mailbox(unread: 0), nil))
        XCTAssertNil(fred(nil, nil))
    }

    func testFredNeedingSignInShowsABangPillAndSignInDetail() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 7, auth: true), nil))
        XCTAssertEqual(badge.pill, "!")
        XCTAssertEqual(badge.detail, "Sign-in needed")
    }

    func testFredStaleMailShowsMailUnavailableAndNeverACount() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 0, stale: true), nil))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Mail unavailable")
        XCTAssertFalse(badge.accessibilityLabel.contains("0"))
    }

    func testFredMailErrorShowsMailUnavailableNotTheStaleCount() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 5, error: "boom"), nil))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Mail unavailable")
    }

    // MARK: - Fred: meeting lines

    func testFredShowsTheNextMeetingWithTimeUntilIt() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 12 * 60)])
        let badge = try XCTUnwrap(fred(try mailbox(unread: 3), cal))
        XCTAssertEqual(badge.detail, "Next: Eng sync in 12 min")
        XCTAssertEqual(badge.level, .info)
    }

    func testFredShowsTheMeetingInProgressAndNeedsAttention() throws {
        let cal = try calendar([Ev(title: "Standup", startOffset: -5 * 60, duration: 1800)])
        let badge = try XCTUnwrap(fred(try mailbox(unread: 1), cal))
        XCTAssertEqual(badge.detail, "Now: Standup")
        XCTAssertEqual(badge.level, .attention)
    }

    func testFredSaysNoMoreMeetingsWhenTheDayIsDone() throws {
        let cal = try calendar([Ev(title: "Earlier", startOffset: -3 * 3600, duration: 1800)])
        let badge = try XCTUnwrap(fred(try mailbox(unread: 1), cal))
        XCTAssertEqual(badge.detail, "No more meetings")
        XCTAssertEqual(badge.level, .info)
    }

    func testFredMeetingExactlyTenMinutesAwayNeedsAttention() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 600)])
        XCTAssertEqual(try XCTUnwrap(fred(nil, cal)).level, .attention)
    }

    func testFredMeetingTenMinutesAndOneSecondAwayDoesNotNeedAttention() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 601)])
        XCTAssertEqual(try XCTUnwrap(fred(nil, cal)).level, .info)
    }

    func testFredIgnoresDeclinedEvents() throws {
        let cal = try calendar([
            Ev(title: "Skipped", startOffset: 3 * 60, status: "declined"),
            Ev(title: "Real", startOffset: 30 * 60),
        ])
        let badge = try XCTUnwrap(fred(nil, cal))
        XCTAssertEqual(badge.detail, "Next: Real in 30 min")
        XCTAssertEqual(badge.level, .info)
    }

    func testFredWithOnlyDeclinedEventsSaysNoMoreMeetings() throws {
        let cal = try calendar([Ev(title: "Skipped", startOffset: -60, status: "declined")])
        XCTAssertEqual(try XCTUnwrap(fred(nil, cal)).detail, "No more meetings")
    }

    // All-day events (holidays, OOO, birthdays) are never "now" and never "next": the badge
    // must agree with the Fred Today pane (FredPresentation), which ignores them.

    /// A holiday spanning the whole day around `now` (started 10 h ago, ends in 14 h).
    private var holiday: Ev { Ev(title: "Columbus Day", startOffset: -10 * 3600, duration: 24 * 3600, allDay: true) }

    func testFredIgnoresAnAllDayEventAndShowsTheNextRealMeeting() throws {
        let cal = try calendar([holiday, Ev(title: "Eng sync", startOffset: 30 * 60)])
        let badge = try XCTUnwrap(fred(nil, cal))
        XCTAssertEqual(badge.detail, "Next: Eng sync in 30 min")
        XCTAssertEqual(badge.level, .info)
    }

    func testFredNeverShowsAnAllDayEventAsNowDuringARealMeeting() throws {
        let cal = try calendar([holiday, Ev(title: "Standup", startOffset: -5 * 60, duration: 1800)])
        let badge = try XCTUnwrap(fred(nil, cal))
        XCTAssertEqual(badge.detail, "Now: Standup")
        XCTAssertEqual(badge.level, .attention)
        XCTAssertFalse(badge.accessibilityLabel.contains("Columbus Day"))
    }

    func testFredWithOnlyAnAllDayEventTodaySaysNoMoreMeetings() throws {
        let badge = try XCTUnwrap(fred(nil, try calendar([holiday])))
        XCTAssertEqual(badge.detail, "No more meetings")
        XCTAssertEqual(badge.level, .info)
        XCTAssertEqual(badge.accessibilityLabel, "Fred, no more meetings")
    }

    func testFredNeverCountsAnAllDayEventThatStartsLaterAsTheNextMeeting() throws {
        let laterAllDay = Ev(title: "Offsite", startOffset: 3 * 3600, duration: 24 * 3600, allDay: true)
        let badge = try XCTUnwrap(fred(nil, try calendar([laterAllDay])))
        XCTAssertEqual(badge.detail, "No more meetings")
        XCTAssertEqual(badge.level, .info)
    }

    func testFredMailTroubleTakesTheSecondLineOverTheMeeting() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 12 * 60)])
        let badge = try XCTUnwrap(fred(try mailbox(stale: true), cal))
        XCTAssertEqual(badge.detail, "Mail unavailable")
    }

    func testFredAccessibilityLabelSpellsOutUnreadAndNextMeeting() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 12 * 60)])
        let badge = try XCTUnwrap(fred(try mailbox(unread: 12), cal))
        XCTAssertEqual(badge.accessibilityLabel, "Fred, 12 unread, next meeting Eng sync in 12 minutes")
    }

    // MARK: - Fred: calendar trouble (a failed/stale source never reads as fresh)

    func testFredCalendarErrorWithMailFineAndNothingUnreadStillShowsCalendarUnavailable() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 0), try calendar([], error: "boom")))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Calendar unavailable")
    }

    func testFredStaleCalendarWithMailFineAndNothingUnreadStillShowsCalendarUnavailable() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 12 * 60)], stale: true)
        let badge = try XCTUnwrap(fred(try mailbox(unread: 0), cal))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Calendar unavailable")
    }

    func testFredUnreadCountSurvivesACalendarErrorAndTheDetailSaysCalendarUnavailable() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 5), try calendar([], error: "boom")))
        XCTAssertEqual(badge.pill, "5")
        XCTAssertEqual(badge.detail, "Calendar unavailable")
    }

    func testFredUnreadCountSurvivesAStaleCalendarAndTheDetailSaysCalendarUnavailable() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 5), try calendar([], stale: true)))
        XCTAssertEqual(badge.pill, "5")
        XCTAssertEqual(badge.detail, "Calendar unavailable")
    }

    func testFredMailUnavailableWinsTheDetailWhenCalendarAlsoFails() throws {
        let badge = try XCTUnwrap(fred(try mailbox(unread: 0, error: "mail boom"), try calendar([], error: "cal boom")))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Mail unavailable")
    }

    func testFredCalendarTroubleNeverShowsAMeetingLine() throws {
        let cal = try calendar([Ev(title: "Eng sync", startOffset: 12 * 60)], error: "boom")
        let badge = try XCTUnwrap(fred(try mailbox(unread: 1), cal))
        XCTAssertFalse((badge.detail ?? "").contains("Eng sync"))
        XCTAssertFalse(badge.accessibilityLabel.contains("Eng sync"))
        XCTAssertEqual(badge.level, .info)
    }

    // MARK: - Mother

    func testMotherPillIsRunningPlusQueuedAndDetailListsNonZeroCounts() throws {
        let badge = try XCTUnwrap(BadgeProviders.mother(MotherStatus(running: 2, queued: 3, failed: 0, awaiting: 1)))
        XCTAssertEqual(badge.pill, "5")
        XCTAssertEqual(badge.detail, "2 running · 3 queued · 1 awaiting")
        XCTAssertEqual(badge.level, .attention)
    }

    func testMotherAwaitingAloneNeedsAttentionWithNoPill() throws {
        let badge = try XCTUnwrap(BadgeProviders.mother(MotherStatus(awaiting: 1)))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.level, .attention)
    }

    func testMotherFailedNeedsAttention() throws {
        let badge = try XCTUnwrap(BadgeProviders.mother(MotherStatus(failed: 2)))
        XCTAssertEqual(badge.level, .attention)
        XCTAssertEqual(badge.detail, "2 failed")
    }

    func testMotherRunningOnlyIsInformational() throws {
        let badge = try XCTUnwrap(BadgeProviders.mother(MotherStatus(running: 1)))
        XCTAssertEqual(badge.pill, "1")
        XCTAssertEqual(badge.level, .info)
    }

    func testMotherWithAllZeroShowsNothing() {
        XCTAssertNil(BadgeProviders.mother(MotherStatus()))
    }

    // MARK: - Perri

    func testPerriShowsTheQueueCountAndNothingWhenEmpty() throws {
        XCTAssertEqual(try XCTUnwrap(BadgeProviders.perri(queueCount: 4)).pill, "4")
        XCTAssertNil(BadgeProviders.perri(queueCount: 0))
    }

    func testPerriFreshQueueShowsTheCountAndZeroShowsNothing() throws {
        XCTAssertEqual(try XCTUnwrap(BadgeProviders.perri(queueCount: 4, stale: false, error: nil, loading: false)).pill, "4")
        XCTAssertNil(BadgeProviders.perri(queueCount: 0, stale: false, error: nil, loading: false))
    }

    /// A non-fresh queue may show nothing or a short word, but never a number.
    private func assertNoCount(_ badge: FocusBadge?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let badge else { return }
        if let pill = badge.pill {
            XCTAssertNil(pill.rangeOfCharacter(from: .decimalDigits), "\(what): pill \"\(pill)\" must not be a count", file: file, line: line)
        }
        XCTAssertNil(badge.accessibilityLabel.rangeOfCharacter(from: .decimalDigits),
                     "\(what): accessibility label \"\(badge.accessibilityLabel)\" must not carry a count", file: file, line: line)
        XCTAssertFalse((badge.detail ?? "").contains(where: \.isNumber), "\(what): detail must not carry a count", file: file, line: line)
    }

    func testPerriStaleQueueNeverShowsACount() {
        assertNoCount(BadgeProviders.perri(queueCount: 37, stale: true, error: nil, loading: false), "stale")
    }

    func testPerriErroredQueueNeverShowsACount() {
        assertNoCount(BadgeProviders.perri(queueCount: 37, stale: false, error: "boom", loading: false), "error")
    }

    func testPerriLoadingQueueNeverShowsACount() {
        assertNoCount(BadgeProviders.perri(queueCount: 37, stale: false, error: nil, loading: true), "loading")
    }

    func testPerriEveryNonFreshCombinationNeverShowsACount() {
        for stale in [false, true] {
            for error in [nil, "boom"] as [String?] {
                for loading in [false, true] where stale || error != nil || loading {
                    assertNoCount(BadgeProviders.perri(queueCount: 37, stale: stale, error: error, loading: loading),
                                  "stale=\(stale) error=\(error ?? "nil") loading=\(loading)")
                }
            }
        }
    }

    // MARK: - Teri (America/Chicago)

    private func teri(_ s: TeriTodosSnapshot?, at date: Date? = nil) -> FocusBadge? {
        BadgeProviders.teri(todos: s, now: date ?? now, calendar: BadgeProviders.chicago)
    }

    func testTeriCountsOverdueAndDueTodayAndNeedsAttentionWhenOverdue() throws {
        let s = try todos(["2026-10-09", "2026-10-10", "2026-10-10", "2026-10-20", nil])
        let badge = try XCTUnwrap(teri(s))
        XCTAssertEqual(badge.pill, "5")
        XCTAssertEqual(badge.detail, "5 todos · 1 overdue · 2 due today")
        XCTAssertEqual(badge.level, .attention)
    }

    func testTeriWithNothingOverdueIsInformational() throws {
        let badge = try XCTUnwrap(teri(try todos(["2026-10-10", nil])))
        XCTAssertEqual(badge.level, .info)
        XCTAssertEqual(badge.pill, "2")
    }

    func testTeriTodayIsDecidedInChicagoNotUTC() throws {
        // 2026-10-11 02:00 UTC is still the evening of Oct 10 in Chicago (CDT).
        let lateEvening = now.addingTimeInterval(11 * 3600)
        XCTAssertEqual(iso.string(from: lateEvening), "2026-10-11T02:00:00Z")
        let badge = try XCTUnwrap(teri(try todos(["2026-10-10", "2026-10-11"]), at: lateEvening))
        XCTAssertEqual(badge.detail, "2 todos · 1 due today")
        XCTAssertEqual(badge.level, .info, "Oct 10 is today in Chicago, so it is not overdue")
    }

    func testTeriErrorShowsTodosUnavailableWithNoPill() throws {
        let badge = try XCTUnwrap(teri(try todos(["2026-10-10"], error: "nope")))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Todos unavailable")
    }

    func testTeriStaleSnapshotShowsTodosUnavailableWithNoPillAndNoOverdueAttention() throws {
        let overdue = try todos(["2026-10-01", "2026-10-09", "2026-10-10"], stale: true)
        let badge = try XCTUnwrap(teri(overdue))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Todos unavailable")
        XCTAssertEqual(badge.level, .info)
        XCTAssertNil(badge.accessibilityLabel.rangeOfCharacter(from: .decimalDigits))
    }

    func testTeriStaleSnapshotWithNoItemsStillSaysTodosUnavailable() throws {
        let badge = try XCTUnwrap(teri(try todos([], stale: true)))
        XCTAssertNil(badge.pill)
        XCTAssertEqual(badge.detail, "Todos unavailable")
    }

    func testTeriWithNoSnapshotOrNoTodosShowsNothing() throws {
        XCTAssertNil(teri(nil))
        XCTAssertNil(teri(try todos([])))
    }

    // MARK: - Registry

    private func badge(_ pill: String?, _ detail: String?, _ level: FocusBadge.Level = .info, ax: String = "ax") -> FocusBadge {
        FocusBadge(pill: pill, detail: detail, level: level, accessibilityLabel: ax)
    }

    func testRegistryPublishesAndClearsPerTag() {
        var reg = FocusBadgeRegistry()
        XCTAssertNil(reg.badge(for: "fred"))
        reg.publish(tag: "fred", sourceKey: "mail", badge: badge("3", nil))
        XCTAssertEqual(reg.badge(for: "fred")?.pill, "3")
        XCTAssertNil(reg.badge(for: "mother"))
        reg.publish(tag: "fred", sourceKey: "mail", badge: nil)
        XCTAssertNil(reg.badge(for: "fred"))
    }

    func testRegistryClearRemovesOnlyThatSource() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "a", badge: badge("1", nil))
        reg.publish(tag: "fred", sourceKey: "b", badge: badge(nil, "detail"))
        reg.clear(tag: "fred", sourceKey: "a")
        XCTAssertNil(reg.badge(for: "fred")?.pill)
        XCTAssertEqual(reg.badge(for: "fred")?.detail, "detail")
    }

    func testRegistryAttentionWinsOverInfoAcrossSources() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "a", badge: badge("1", nil, .info))
        reg.publish(tag: "fred", sourceKey: "b", badge: badge(nil, "meeting", .attention))
        XCTAssertEqual(reg.badge(for: "fred")?.level, .attention)
    }

    func testRegistryTakesPillDetailAndLabelFromOneSource() throws {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "a", badge: badge(nil, "from a", ax: "label a"))
        reg.publish(tag: "fred", sourceKey: "b", badge: badge("9", "from b", ax: "label b"))
        let merged = try XCTUnwrap(reg.badge(for: "fred"))
        XCTAssertEqual(merged.pill, "9")
        XCTAssertEqual(merged.detail, "from b")
        XCTAssertEqual(merged.accessibilityLabel, "label b")
    }

    func testRegistryAttentionTagsListsOnlyTagsAtAttentionLevel() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "a", badge: badge("1", nil, .info))
        reg.publish(tag: "mother", sourceKey: "a", badge: badge("1", nil, .attention))
        XCTAssertEqual(reg.attentionTags, ["mother"])
        reg.clear(tag: "mother", sourceKey: "a")
        XCTAssertTrue(reg.attentionTags.isEmpty)
    }

    // MARK: - buildNavRows badgeDetailFor

    private func secondary(_ rows: [NavRow], tag: String) -> String?? {
        for row in rows {
            if case let .focus(f, _, s, _) = row, f.sessionTag == tag { return .some(s) }
        }
        return nil
    }

    func testBadgeDetailReplacesTheSecondLineOfFredMotherAndTeri() {
        let rows = buildNavRows(Focus.builtIns, badgeDetailFor: { "detail-\($0)" })
        XCTAssertEqual(secondary(rows, tag: "fred"), "detail-fred")
        XCTAssertEqual(secondary(rows, tag: "mother"), "detail-mother")
        XCTAssertEqual(secondary(rows, tag: "teri"), "detail-teri")
    }

    func testPerriKeepsItsPRLineRegardlessOfBadgeDetail() {
        let plain = buildNavRows(Focus.builtIns)
        let badged = buildNavRows(Focus.builtIns, badgeDetailFor: { _ in "ignored" })
        XCTAssertEqual(secondary(badged, tag: "perri"), secondary(plain, tag: "perri"))
        XCTAssertNotEqual(secondary(badged, tag: "perri"), "ignored")
    }

    func testBadgeDetailDoesNotApplyToDynamicFocuses() {
        let dyn = Focus(id: "11111111-aaaa", agentTag: "fred", projectPath: "/Users/hammer/Code/nostromo",
                        isBuiltIn: false, org: "Carefeed")
        let rows = buildNavRows([dyn], badgeDetailFor: { _ in "badge" })
        XCTAssertEqual(secondary(rows, tag: dyn.sessionTag), "")
    }

    func testNilBadgeDetailFallsBackToTheDefaultAndNeverLeavesTheSecondLineNil() {
        let baseline = buildNavRows(Focus.builtIns)
        let nilDetail = buildNavRows(Focus.builtIns, badgeDetailFor: { _ in nil })
        XCTAssertEqual(baseline, nilDetail)
        for row in nilDetail {
            if case let .focus(_, _, s, _) = row { XCTAssertNotNil(s) }
        }
    }

    // MARK: - Real NavTabItem

    private func builtIn(_ tag: String) -> Focus { Focus.builtIns.first { $0.agentTag == tag }! }

    private func makeItem(_ tag: String, base: String? = "base line", width: CGFloat = 180) -> NavTabItem {
        let item = NavTabItem(focus: builtIn(tag), label: tag.capitalized, secondary: base, indented: false)
        item.frame = NSRect(x: 0, y: 0, width: width, height: Theme.navItemSubtitleHeight)
        item.layoutSubtreeIfNeeded()
        return item
    }

    func testSetBadgeShowsPillAndDetailOnABuiltInRow() {
        let item = makeItem("fred")
        item.setBadge(badge("12", "Next: Eng sync in 12 min", ax: "Fred, 12 unread"))
        XCTAssertEqual(item.pillText, "12")
        XCTAssertEqual(item.secondaryText, "Next: Eng sync in 12 min")
    }

    func testSetBadgeAppliesToMotherAndTeriRowsToo() {
        for tag in ["mother", "teri"] {
            let item = makeItem(tag)
            item.setBadge(badge("2", "line for \(tag)"))
            XCTAssertEqual(item.secondaryText, "line for \(tag)")
            XCTAssertEqual(item.pillText, "2")
        }
    }

    func testSetBadgeLeavesPerriSecondLineAlone() {
        let item = makeItem("perri", base: "owner/repo#12")
        item.setBadge(badge("4", "should not appear"))
        XCTAssertEqual(item.secondaryText, "owner/repo#12")
        XCTAssertEqual(item.pillText, "4")
    }

    func testSetBadgeNilRestoresTheBaseLineAndHidesThePill() {
        let item = makeItem("fred", base: "base line")
        item.setBadge(badge("12", "Next: Eng sync in 12 min"))
        item.setBadge(nil)
        XCTAssertNil(item.pillText)
        XCTAssertEqual(item.secondaryText, "base line")
    }

    func testBadgeWithoutPillHidesAPreviouslyShownPill() {
        let item = makeItem("fred")
        item.setBadge(badge("12", nil))
        item.setBadge(badge(nil, "Mail unavailable"))
        XCTAssertNil(item.pillText)
        XCTAssertEqual(item.secondaryText, "Mail unavailable")
    }

    func testBadgeWithoutDetailFallsBackToTheBaseLine() {
        let item = makeItem("teri", base: "base line")
        item.setBadge(badge("3", nil))
        XCTAssertEqual(item.secondaryText, "base line")
    }

    func testRowHeightIsUnchangedByBadgesAfterLayout() {
        for width in [CGFloat(120), 180, 260] {
            let item = makeItem("fred", width: width)
            let before = item.frame.height
            let fittingBefore = item.fittingSize.height
            item.setBadge(badge("128", "Next: A very long meeting title that cannot fit in the row in 12 min", .attention))
            item.layoutSubtreeIfNeeded()
            XCTAssertEqual(item.frame.height, before)
            XCTAssertEqual(item.fittingSize.height, fittingBefore)
            item.setBadge(nil)
            item.layoutSubtreeIfNeeded()
            XCTAssertEqual(item.frame.height, before)
        }
    }

    func testAccessibilityLabelCarriesTheBadgeWords() {
        let item = makeItem("fred")
        item.setBadge(FocusBadge(pill: "12", detail: "x", accessibilityLabel: "Fred, 12 unread, next meeting Eng sync in 12 minutes"))
        let label = item.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("Fred"))
        XCTAssertTrue(label.contains("12 unread"))
        XCTAssertTrue(label.contains("Eng sync"))
        XCTAssertFalse(label.contains("needs your attention"))
    }

    func testAttentionLevelAppendsNeedsYourAttentionToTheLabel() {
        let item = makeItem("mother")
        item.setBadge(FocusBadge(pill: "1", detail: "1 awaiting", level: .attention, accessibilityLabel: "Mother, 1 awaiting"))
        XCTAssertEqual(item.accessibilityLabel(), "Mother, 1 awaiting, needs your attention")
    }

    func testClearingTheBadgeRemovesTheBadgeAccessibilityLabel() {
        let item = makeItem("fred")
        item.setBadge(FocusBadge(pill: "12", accessibilityLabel: "Fred, 12 unread"))
        item.setBadge(nil)
        XCTAssertFalse((item.accessibilityLabel() ?? "").contains("12 unread"))
    }

    // MARK: - Pill / attention-dot geometry (real NavTabItem)

    private let longLabel = "A very long focus name that cannot possibly fit in the sidebar row"

    private func makeLongItem(width: CGFloat = 180) -> NavTabItem {
        let item = NavTabItem(focus: builtIn("fred"), label: longLabel, secondary: "base line", indented: false)
        item.frame = NSRect(x: 0, y: 0, width: width, height: Theme.navItemSubtitleHeight)
        item.layoutSubtreeIfNeeded()
        return item
    }

    private func assertInside(_ inner: NSRect, _ outer: NSRect, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX, "\(what) spills left", file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX, "\(what) spills right", file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minY, outer.minY, "\(what) spills below", file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxY, outer.maxY, "\(what) spills above", file: file, line: line)
    }

    private func assertInsideHorizontally(_ inner: NSRect, _ outer: NSRect, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX, "\(what) spills left", file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX, "\(what) spills right", file: file, line: line)
    }

    /// A too-long title truncates on its one line; it must not wrap upward out of the row.
    func testALongTitleStaysOnOneLineInsideTheRowWithAPillAndAttentionDot() {
        for width in [CGFloat(180), 150] {
            let item = makeLongItem(width: width)
            item.needsAttention = true
            item.setBadge(badge("128", nil))
            item.layoutSubtreeIfNeeded()
            assertInside(item.labelFrame, item.bounds, "label (width \(width))")
        }
    }

    func testPillSitsLeftOfTheAttentionDotAndTheLongLabelStaysLeftOfThePill() throws {
        for width in [CGFloat(180), 150] {
            let item = makeLongItem(width: width)
            item.needsAttention = true
            item.setBadge(badge("128", nil))
            item.layoutSubtreeIfNeeded()
            let pill = try XCTUnwrap(item.pillFrame)
            let dot = try XCTUnwrap(item.attentionDotFrame)
            XCTAssertLessThanOrEqual(pill.maxX, dot.minX, "pill must be left of the attention dot (width \(width))")
            XCTAssertLessThanOrEqual(item.labelFrame.maxX, pill.minX, "label must end before the pill (width \(width))")
            assertInside(pill, item.bounds, "pill")
            assertInside(dot, item.bounds, "attention dot")
            assertInsideHorizontally(item.labelFrame, item.bounds, "label")
        }
    }

    func testPillAndAttentionDotLayoutDoesNotDependOnTheOrderTheyAreApplied() throws {
        let item = makeLongItem()
        item.setBadge(badge("128", nil))
        item.needsAttention = true
        item.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(item.pillFrame)
        let dot = try XCTUnwrap(item.attentionDotFrame)
        XCTAssertLessThanOrEqual(pill.maxX, dot.minX)
        XCTAssertLessThanOrEqual(item.labelFrame.maxX, pill.minX)
    }

    func testPillMovesToTheTrailingEdgeWhenTheAttentionDotGoesAway() throws {
        let item = makeLongItem()
        item.needsAttention = true
        item.setBadge(badge("128", nil))
        item.layoutSubtreeIfNeeded()
        let withDot = try XCTUnwrap(item.pillFrame)
        item.needsAttention = false
        item.layoutSubtreeIfNeeded()
        let without = try XCTUnwrap(item.pillFrame)
        XCTAssertNil(item.attentionDotFrame)
        XCTAssertGreaterThan(without.maxX, withDot.maxX)
        XCTAssertGreaterThanOrEqual(without.maxX, item.bounds.maxX - 12, "pill hugs the trailing edge")
        XCTAssertLessThanOrEqual(without.maxX, item.bounds.maxX)
        XCTAssertLessThanOrEqual(item.labelFrame.maxX, without.minX)
        assertInside(without, item.bounds, "pill")
    }

    func testPillWithoutAttentionDotSitsAtTheTrailingEdgeAndLabelClearsIt() throws {
        let item = makeLongItem()
        item.setBadge(badge("128", nil))
        item.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(item.pillFrame)
        XCTAssertGreaterThanOrEqual(pill.maxX, item.bounds.maxX - 12)
        XCTAssertLessThanOrEqual(pill.maxX, item.bounds.maxX)
        XCTAssertLessThanOrEqual(item.labelFrame.maxX, pill.minX)
        assertInside(pill, item.bounds, "pill")
        assertInsideHorizontally(item.labelFrame, item.bounds, "label")
    }

    // MARK: - Pill click routing (real NavTabItem)

    /// An item placed in a window so event coordinates convert like real clicks.
    private func hostedItem(_ item: NavTabItem) -> NSWindow {
        let window = NSWindow(contentRect: item.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(item)
        item.layoutSubtreeIfNeeded()
        return window
    }

    private func click(at pointInItem: NSPoint, on item: NavTabItem, in window: NSWindow) throws -> NSEvent {
        let inWindow = item.convert(pointInItem, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func center(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    func testRowRecognizerStandsDownForAClickOnThePillButNotElsewhere() throws {
        let item = makeLongItem()
        let window = hostedItem(item)
        item.setBadge(badge("128", nil))
        item.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(item.pillFrame)
        let recognizer = NSClickGestureRecognizer()

        let onPill = try click(at: center(pill), on: item, in: window)
        XCTAssertFalse(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onPill))

        let onLabel = try click(at: NSPoint(x: item.labelFrame.minX + 4, y: item.labelFrame.midY), on: item, in: window)
        XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onLabel))

        let onSecondLine = try click(at: NSPoint(x: 20, y: 6), on: item, in: window)
        XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onSecondLine))
    }

    func testRowRecognizerTakesEveryClickWhenThereIsNoPill() throws {
        let item = makeLongItem()
        let window = hostedItem(item)
        let recognizer = NSClickGestureRecognizer()
        let trailing = try click(at: NSPoint(x: item.bounds.maxX - 14, y: item.bounds.maxY - 13), on: item, in: window)
        XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: trailing))
    }

    func testRowRecognizerTakesEveryClickAfterThePillIsCleared() throws {
        let item = makeLongItem()
        let window = hostedItem(item)
        item.setBadge(badge("128", nil))
        item.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(item.pillFrame)
        item.setBadge(nil)
        let atOldPill = try click(at: center(pill), on: item, in: window)
        XCTAssertTrue(item.gestureRecognizer(NSClickGestureRecognizer(), shouldAttemptToRecognizeWith: atOldPill))
    }

    func testPillClickFiresOnBadgeTapAndNotOnTap() {
        let item = makeItem("fred")
        var taps = 0, badgeTaps = 0
        item.onTap = { taps += 1 }
        item.onBadgeTap = { badgeTaps += 1 }
        item.simulatePillClick()
        XCTAssertEqual(badgeTaps, 1)
        XCTAssertEqual(taps, 0)
    }

    func testRowClickFiresOnTapAndNotOnBadgeTap() {
        let item = makeItem("fred")
        var taps = 0, badgeTaps = 0
        item.onTap = { taps += 1 }
        item.onBadgeTap = { badgeTaps += 1 }
        item.simulateRowClick()
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(badgeTaps, 0)
    }

    func testPillClickFallsBackToOnTapWhenOnBadgeTapIsUnset() {
        let item = makeItem("fred")
        var taps = 0
        item.onTap = { taps += 1 }
        item.simulatePillClick()
        XCTAssertEqual(taps, 1)
    }
}
