// NostromoKit — MotherNoticeMarkTests.swift
//
// Mother focus v2, MF6: what the Mother list says about whether a job's focus was told.
//
//   row mark      `✓ told <name>` / `⏸ held` (wide), `✓` / `⏸` (narrow); only for a verified focus
//                 origin and only for a `told` or `held` notice
//   tooltip       `<name> was told '<state>' N minutes ago`
//   VoiceOver     `Told <name> N minutes ago.` / `Notice held: <reason>.`
//   Notices       the Overview section: one summary line, muted "Not notified" lines, and one detail
//   section       line per history entry
//   Debug stats   counts, modes, tags: never a title or a focus name
//
// A name is agent-supplied: whatever it holds, a mark string draws at most the one glyph the app put
// there, and the name is capped at 24 characters. Time is injected (`now`), never read.

import XCTest
@testable import NostromoKit

final class MotherNoticeMarkTests: XCTestCase {

    // MARK: - Helpers

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ms(minutesAgo m: Double) -> Int64 {
        Int64((now.timeIntervalSince1970 - m * 60) * 1000)
    }

    private func ms(secondsAgo s: Double) -> Int64 {
        Int64((now.timeIntervalSince1970 - s) * 1000)
    }

    private func told(minutesAgo m: Double = 4, state: String? = "succeeded") -> MotherNoticeAnnotation {
        MotherNoticeAnnotation(status: .told, lastState: state, atMs: ms(minutesAgo: m))
    }

    private func held(_ reason: String?) -> MotherNoticeAnnotation {
        MotherNoticeAnnotation(status: .held, reason: reason, atMs: ms(minutesAgo: 1))
    }

    private func mark(_ n: MotherNoticeAnnotation?, name: String? = "Claudia") -> MotherNoticeMark? {
        MotherNoticeMark.make(notice: n, originName: name, now: now)
    }

    private func focusAnnotation(
        notice: MotherNoticeAnnotation?, tag: String = "claudia-1", name: String = "Claudia",
        snapshot: String? = nil
    ) -> MotherJobAnnotation {
        MotherJobAnnotation(
            origin: MotherOriginView(kind: .focus, focusTag: tag, nameSnapshot: snapshot ?? name,
                                     focusName: name, closed: false, sessionPrefix: "abcd1234"),
            notice: notice)
    }

    private func display(_ a: MotherJobAnnotation?, open: [String: String] = ["claudia-1": "Claudia"])
        -> MotherOriginDisplay {
        MotherOriginDisplay.make(annotation: a, currentName: { open[$0] })
    }

    private func section(_ a: MotherJobAnnotation?, open: [String: String] = ["claudia-1": "Claudia"])
        -> MotherNoticeSectionModel? {
        MotherNoticeSectionModel.make(annotation: a, origin: display(a, open: open), now: now)
    }

    private func count(of glyph: Character, in s: String) -> Int { s.filter { $0 == glyph }.count }

    private func hostileNames() -> [String] {
        [
            "✓ forged",
            "⏸ forged",
            "evil ✔ ⟲ ⚑ name",
            "line\nbreak\tand\u{1B}[31mcolour\u{7}",
            "bidi\u{202E}reversed\u{2066}",
            "nul\u{0}byte",
            String(repeating: "W", count: 500),
            "✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓",
        ]
    }

    // MARK: - Told

    func testToldMarkIsCheckWithNameWideAndCheckNarrow() throws {
        let m = try XCTUnwrap(mark(told()))
        XCTAssertEqual(m.wide, "✓ told Claudia")
        XCTAssertEqual(m.narrow, "✓")
    }

    func testToldTooltipNamesTheFocusTheStateAndHowLongAgo() throws {
        let m = try XCTUnwrap(mark(told(minutesAgo: 4, state: "succeeded")))
        XCTAssertEqual(m.tooltip, "Claudia was told 'succeeded' 4 minutes ago")
    }

    func testToldVoiceOverSentenceSaysToldNameAndWhen() throws {
        let m = try XCTUnwrap(mark(told(minutesAgo: 4)))
        XCTAssertEqual(m.accessibilitySentence, "Told Claudia 4 minutes ago.")
    }

    func testToldWithoutATimeStillMarksAndDoesNotInventOne() throws {
        let m = try XCTUnwrap(mark(MotherNoticeAnnotation(status: .told, lastState: "succeeded", atMs: nil)))
        XCTAssertEqual(m.wide, "✓ told Claudia")
        XCTAssertFalse(m.tooltip.contains("ago"))
        XCTAssertFalse(m.accessibilitySentence.contains("ago"))
    }

    // MARK: - Held

    func testHeldMarkIsPauseHeldWideAndPauseNarrowForEveryReason() throws {
        for reason in ["batching", "busy", "cap", "loop_guard", "session_not_running", "quiet", "something_new", nil] {
            let m = try XCTUnwrap(mark(held(reason)), "reason \(reason ?? "nil")")
            XCTAssertEqual(m.wide, "⏸ held", "reason \(reason ?? "nil")")
            XCTAssertEqual(m.narrow, "⏸", "reason \(reason ?? "nil")")
            XCTAssertFalse(m.tooltip.isEmpty)
        }
    }

    func testHeldVoiceOverSentenceStartsWithNoticeHeldAndNamesTheReason() throws {
        var sentences = Set<String>()
        for reason in ["batching", "busy", "cap", "loop_guard", "session_not_running", "quiet"] {
            let m = try XCTUnwrap(mark(held(reason)))
            XCTAssertTrue(m.accessibilitySentence.hasPrefix("Notice held: "), reason)
            XCTAssertTrue(m.accessibilitySentence.hasSuffix("."), reason)
            XCTAssertFalse(m.accessibilitySentence.lowercased().contains("no reason given"),
                           "\(reason) is a known reason and needs words")
            sentences.insert(m.accessibilitySentence)
        }
        XCTAssertEqual(sentences.count, 6, "each reason reads differently")
    }

    func testHeldForAnUnknownReasonStillSpeaksAnHonestSentence() throws {
        let m = try XCTUnwrap(mark(held("brand_new_reason")))
        XCTAssertTrue(m.accessibilitySentence.hasPrefix("Notice held: "))
    }

    func testLoopGuardAndCapHoldsExplainThemselvesInTheTooltipLikeTheHeldBar() throws {
        XCTAssertEqual(try XCTUnwrap(mark(held("loop_guard"))).tooltip,
                       MotherNoticeText.heldBarText(.loopGuard))
        XCTAssertEqual(try XCTUnwrap(mark(held("cap"))).tooltip,
                       MotherNoticeText.heldBarText(.cap))
    }

    // MARK: - No mark

    func testNoMarkForDroppedNotSentOrNoneStatus() {
        for status in [MotherNoticeStatus.dropped, .notSent, .none] {
            XCTAssertNil(mark(MotherNoticeAnnotation(status: status, reason: "busy", atMs: ms(minutesAgo: 1))),
                         "\(status)")
        }
    }

    func testNoMarkWithoutANoticeOrWithoutANotifiableOrigin() {
        XCTAssertNil(mark(nil))
        XCTAssertNil(mark(told(), name: nil))
        XCTAssertNil(mark(held("busy"), name: nil))
    }

    // MARK: - Hostile names

    func testHostileNameNeverDrawsASecondMarkAndIsCappedAt24() throws {
        for raw in hostileNames() {
            let tolded = try XCTUnwrap(mark(told(), name: raw), raw)
            XCTAssertEqual(count(of: "✓", in: tolded.wide), 1, "wide for \(raw.prefix(30))")
            for glyph in ["⏸", "✔", "⟲", "⚑"] as [Character] {
                XCTAssertEqual(count(of: glyph, in: tolded.wide), 0, "\(glyph) in wide for \(raw.prefix(30))")
                XCTAssertEqual(count(of: glyph, in: tolded.tooltip), 0, "\(glyph) in tooltip")
                XCTAssertEqual(count(of: glyph, in: tolded.accessibilitySentence), 0, "\(glyph) in sentence")
            }
            XCTAssertEqual(count(of: "✓", in: tolded.tooltip), 0)
            XCTAssertEqual(count(of: "✓", in: tolded.accessibilitySentence), 0)

            let name = String(tolded.wide.dropFirst("✓ told".count)).trimmingCharacters(in: .whitespaces)
            XCTAssertLessThanOrEqual(name.count, MotherNoticeText.nameCap, "name for \(raw.prefix(30))")

            for s in [tolded.wide, tolded.narrow, tolded.tooltip, tolded.accessibilitySentence] {
                for scalar in s.unicodeScalars {
                    XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar),
                                   "U+\(String(scalar.value, radix: 16)) survived for \(raw.prefix(30))")
                }
            }
        }
    }

    func testHostileNameDoesNotMakeAHeldMarkDrawAnythingButItsOwnGlyph() throws {
        for raw in hostileNames() {
            let m = try XCTUnwrap(mark(held("busy"), name: raw))
            XCTAssertEqual(count(of: "⏸", in: m.wide), 1)
            XCTAssertEqual(count(of: "✓", in: m.wide), 0)
        }
    }

    func testANameMadeOnlyOfMarkGlyphsFallsBackToAPlainToldMark() throws {
        let m = try XCTUnwrap(mark(told(), name: "✓⏸✔"))
        XCTAssertEqual(m.wide, "✓ told")
        XCTAssertEqual(count(of: "✓", in: m.wide), 1)
    }

    func testCleanNameCapsAt24WithAnEllipsis() {
        let name = MotherNoticeText.cleanName(String(repeating: "N", count: 60))
        XCTAssertEqual(name.count, 24)
        XCTAssertTrue(name.hasSuffix("…"))
        XCTAssertEqual(MotherNoticeText.cleanName("Claudia"), "Claudia")
        XCTAssertEqual(MotherNoticeText.cleanName(nil), "")
    }

    // MARK: - Relative time

    func testAgoRoundsDownAndSingularises() {
        func long(_ secs: Double) -> String { MotherNoticeText.ago(atMs: ms(secondsAgo: secs), now: now, long: true) }
        XCTAssertEqual(long(0), "under a minute ago")
        XCTAssertEqual(long(59), "under a minute ago")
        XCTAssertEqual(long(60), "1 minute ago")
        XCTAssertEqual(long(119), "1 minute ago")
        XCTAssertEqual(long(120), "2 minutes ago")
        XCTAssertEqual(long(59 * 60 + 59), "59 minutes ago")
        XCTAssertEqual(long(3600), "1 hour ago")
        XCTAssertEqual(long(5 * 3600 + 1800), "5 hours ago")
        XCTAssertEqual(long(86_400), "1 day ago")
        XCTAssertEqual(long(3 * 86_400), "3 days ago")
    }

    func testShortAgoForm() {
        func short(_ secs: Double) -> String { MotherNoticeText.ago(atMs: ms(secondsAgo: secs), now: now, long: false) }
        XCTAssertEqual(short(10), "just now")
        XCTAssertEqual(short(4 * 60), "4m ago")
        XCTAssertEqual(short(2 * 3600), "2h ago")
        XCTAssertEqual(short(2 * 86_400), "2d ago")
    }

    func testATimeInTheFutureReadsAsJustNowNotNegative() {
        let future = Int64((now.timeIntervalSince1970 + 600) * 1000)
        XCTAssertEqual(MotherNoticeText.ago(atMs: future, now: now, long: true), "under a minute ago")
        XCTAssertEqual(MotherNoticeText.ago(atMs: future, now: now, long: false), "just now")
    }

    func testToldMarkTextFollowsTheInjectedNow() throws {
        let m = try XCTUnwrap(mark(told(minutesAgo: 4)))
        let later = MotherNoticeMark.make(notice: told(minutesAgo: 4), originName: "Claudia",
                                          now: now.addingTimeInterval(3600))
        XCTAssertTrue(m.tooltip.hasSuffix("4 minutes ago"))
        XCTAssertTrue(try XCTUnwrap(later).tooltip.hasSuffix("1 hour ago"), later?.tooltip ?? "nil")
    }

    // MARK: - State words

    func testStateWordsReadNaturallyAndUnknownStatesAreSanitisedAndCapped() {
        XCTAssertEqual(MotherNoticeText.stateWords("pr_opened"), "PR opened")
        XCTAssertEqual(MotherNoticeText.stateWords("succeeded"), "succeeded")
        let odd = MotherNoticeText.stateWords("weird\u{1B}[31m_state" + String(repeating: "x", count: 100))
        XCTAssertLessThanOrEqual(odd.count, 20)
        XCTAssertFalse(odd.unicodeScalars.contains { HostileContent.isForbiddenOnARow($0) })
    }

    // MARK: - Notices section

    func testSectionForAToldFocusSaysWhoWasToldWhenAndAboutWhat() throws {
        let a = focusAnnotation(notice: MotherNoticeAnnotation(
            status: .told, lastState: "succeeded", atMs: ms(minutesAgo: 4),
            history: [MotherNoticeHistoryEntry(states: ["succeeded"], status: .told, reason: nil,
                                               wake: true, atMs: ms(minutesAgo: 4))]))
        let s = try XCTUnwrap(section(a))
        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(s.summary.contains("Claudia"), s.summary)
        XCTAssertTrue(s.summary.contains("told"), s.summary)
        XCTAssertTrue(s.summary.contains("4m ago"), s.summary)
        XCTAssertTrue(s.summary.contains("succeeded"), s.summary)
    }

    func testSectionDetailsHaveOneLinePerHistoryEntryOldestFirst() throws {
        let a = focusAnnotation(notice: MotherNoticeAnnotation(
            status: .told, lastState: "succeeded", atMs: ms(minutesAgo: 4),
            history: [
                MotherNoticeHistoryEntry(states: ["pr_opened"], status: .told, reason: nil, wake: true, atMs: ms(minutesAgo: 10)),
                MotherNoticeHistoryEntry(states: ["succeeded"], status: .told, reason: nil, wake: false, atMs: ms(minutesAgo: 4)),
            ]))
        let s = try XCTUnwrap(section(a))
        XCTAssertEqual(s.details.count, 2)
        XCTAssertTrue(s.details[0].contains("10m ago"), s.details[0])
        XCTAssertTrue(s.details[0].contains("PR opened"), s.details[0])
        XCTAssertTrue(s.details[1].contains("4m ago"), s.details[1])
        XCTAssertNotEqual(s.details[0], s.details[1])
    }

    func testSectionDetailSaysWhetherAToldNoticeWokeTheSession() throws {
        func detail(wake: Bool) throws -> String {
            let a = focusAnnotation(notice: MotherNoticeAnnotation(
                status: .told, lastState: "succeeded", atMs: ms(minutesAgo: 1),
                history: [MotherNoticeHistoryEntry(states: ["succeeded"], status: .told, reason: nil,
                                                   wake: wake, atMs: ms(minutesAgo: 1))]))
            return try XCTUnwrap(section(a)).details[0]
        }
        XCTAssertNotEqual(try detail(wake: true), try detail(wake: false))
    }

    func testSectionForAHeldNoticeSaysHeldAndWhy() throws {
        let a = focusAnnotation(notice: MotherNoticeAnnotation(
            status: .held, reason: "batching", lastState: "succeeded", atMs: ms(minutesAgo: 1),
            history: [MotherNoticeHistoryEntry(states: ["succeeded"], status: .held, reason: "batching",
                                               wake: false, atMs: ms(minutesAgo: 1))]))
        let s = try XCTUnwrap(section(a))
        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(s.summary.contains("held"), s.summary)
        XCTAssertTrue(s.summary.contains(MotherNoticeText.reasonWords("batching")), s.summary)
        XCTAssertEqual(s.details.count, 1)
        XCTAssertTrue(s.details[0].contains("held"), s.details[0])
    }

    func testSectionForAFocusWithNoNoticeYetIsMutedAndHasNothingToExpand() throws {
        for notice in [nil, MotherNoticeAnnotation(status: .none)] as [MotherNoticeAnnotation?] {
            let s = try XCTUnwrap(section(focusAnnotation(notice: notice)))
            XCTAssertTrue(s.isMuted)
            XCTAssertTrue(s.details.isEmpty)
            XCTAssertTrue(s.summary.contains("Claudia"), s.summary)
        }
    }

    func testSectionForAClosedFocusSaysSoAndIsMuted() throws {
        let a = focusAnnotation(notice: told())
        let s = try XCTUnwrap(section(a, open: [:]))
        XCTAssertEqual(s.summary, "Not notified: the focus that queued this is closed.")
        XCTAssertTrue(s.isMuted)
        XCTAssertTrue(s.details.isEmpty)
    }

    func testSectionForEveryNonFocusOriginIsAMutedNotNotifiedLine() throws {
        let origins: [(String, MotherOriginView)] = [
            ("unverified", MotherOriginView(kind: .unverified, focusTag: "claimed-1", nameSnapshot: "Claimed")),
            ("you", MotherOriginView(kind: .you)),
            ("unknown", MotherOriginView(kind: .unknown)),
            ("future kind", MotherOriginView(kind: .other("robot"))),
        ]
        for (label, origin) in origins {
            let s = try XCTUnwrap(section(MotherJobAnnotation(origin: origin, notice: told())), label)
            XCTAssertTrue(s.summary.hasPrefix("Not notified"), "\(label): \(s.summary)")
            XCTAssertTrue(s.isMuted, label)
            XCTAssertTrue(s.details.isEmpty, label)
        }
        let none = try XCTUnwrap(section(MotherJobAnnotation()), "no origin at all")
        XCTAssertTrue(none.summary.hasPrefix("Not notified"))
        XCTAssertTrue(none.isMuted)
    }

    func testNoSectionWithoutAnAnnotation() {
        XCTAssertNil(MotherNoticeSectionModel.make(annotation: nil, origin: MotherOriginDisplay.unknown, now: now))
    }

    func testSectionWithAHostileNameDrawsNoMarkGlyphOrControlCharacter() throws {
        for raw in hostileNames() {
            let a = focusAnnotation(notice: told(), name: raw)
            let s = try XCTUnwrap(section(a, open: ["claudia-1": raw]))
            for glyph in ["✓", "⏸", "✔", "⟲", "⚑"] as [Character] {
                XCTAssertFalse(s.summary.contains(glyph), "\(glyph) in summary for \(raw.prefix(30))")
            }
            XCTAssertFalse(s.summary.unicodeScalars.contains { HostileContent.isForbiddenOnARow($0) })
        }
    }

    // MARK: - Debug stats

    func testStatsShowCountsModesTagsHeldReasonsAndVerifiedShare() {
        let state = MotherNoticeStateWire(enabled: false, focuses: [
            MotherFocusNoticeState(tag: "claudia-1", mode: .quiet, held: MotherNoticeHeld(count: 3, reason: "cap"),
                                   chainHeld: false,
                                   wakesByDay: [MotherNoticeDayCount(day: "2026-10-30", count: 4)]),
            MotherFocusNoticeState(tag: "ada-2", mode: .wake, held: nil, chainHeld: false, wakesByDay: []),
        ])
        let annotations: [String: MotherJobAnnotation] = [
            "j1": focusAnnotation(notice: told()),
            "j2": MotherJobAnnotation(origin: MotherOriginView(kind: .you)),
            "j3": MotherJobAnnotation(origin: MotherOriginView(kind: .unverified, focusTag: "x")),
        ]
        let text = MotherNoticeStats.text(state: state, annotations: annotations)
        XCTAssertTrue(text.contains("off"), text)
        XCTAssertTrue(text.contains("claudia-1"), text)
        XCTAssertTrue(text.contains("ada-2"), text)
        XCTAssertTrue(text.contains("quiet"), text)
        XCTAssertTrue(text.contains("cap=3"), text)
        XCTAssertTrue(text.contains("2026-10-30=4"), text)
        XCTAssertTrue(text.contains("1/3"), text)
        XCTAssertTrue(text.contains("33%"), text)
    }

    func testStatsNeverContainATitleOrAFocusName() {
        let state = MotherNoticeStateWire(enabled: true, focuses: [
            MotherFocusNoticeState(tag: "claudia-1", mode: .wake, held: nil, chainHeld: false, wakesByDay: []),
        ])
        let a = MotherJobAnnotation(
            origin: MotherOriginView(kind: .focus, focusTag: "claudia-1",
                                     nameSnapshot: "CANARY-SNAPSHOT-NAME", focusName: "CANARY-FOCUS-NAME",
                                     closed: false, sessionPrefix: "abcd1234"),
            notice: told(state: "CANARY-LAST-STATE"))
        let text = MotherNoticeStats.text(state: state, annotations: ["CANARY-JOB-TITLE-ID": a])
        XCTAssertFalse(text.contains("CANARY"), text)
    }

    func testStatsWithoutAStateSaysNothingHasArrivedYetAndNeverCrashesOnNoJobs() {
        let none = MotherNoticeStats.text(state: nil, annotations: [:])
        XCTAssertFalse(none.isEmpty)
        let empty = MotherNoticeStats.text(state: MotherNoticeStateWire(enabled: true, focuses: []), annotations: [:])
        XCTAssertTrue(empty.contains("n/a"), empty)
    }
}
