// NostromoKit — PeerMarkerTextTests.swift
//
// The one muted line a user-role message the CLI injected shows in the transcript's user slot instead
// of a user bubble: a message from another Claude session (`WakeMarkerText.peerMessage`) or injected
// context, a loaded skill, a conversation summary, anything else (`WakeMarkerText.injectedContext`).
//
// Every mark and separator on the line (`↘`, `ⓘ`, ` · `, `:`, the counts) is built by the app. The
// untrusted text (a sender's name, mode and body, a skill's title) is sanitised and bounded, and a
// name or mode can never draw the separators, a badge or a second line of its own.

import XCTest
@testable import NostromoKit

final class PeerMarkerTextTests: XCTestCase {

    // MARK: - Helpers

    private func item(_ name: String? = "PDO Demo", mode: String? = "bypass", body: String = "run the tests",
                      socket: String? = nil, truncated: Bool = false) -> PeerMessageItemWire {
        PeerMessageItemWire(fromName: name, fromMode: mode, fromSocket: socket, body: body, truncated: truncated)
    }

    private func peer(_ items: [PeerMessageItemWire], omitted: Int = 0) -> WakeMarkerContent {
        WakeMarkerText.peerMessage(items, omitted: omitted)
    }

    private func count(of character: Character, in text: String) -> Int {
        text.filter { $0 == character }.count
    }

    private static let lineBreaks: Set<Unicode.Scalar> = ["\u{2028}", "\u{2029}", "\u{85}", "\n", "\r"]

    /// The line holds no control, direction or filler scalar and no line break; the other texts hold none
    /// either, except the `\n` and `\t` of a multi-line body they may carry.
    private func assertClean(_ content: WakeMarkerContent, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for scalar in content.line.unicodeScalars {
            XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar) || Self.lineBreaks.contains(scalar),
                           "\(context): the line holds U+\(String(scalar.value, radix: 16, uppercase: true))", file: file, line: line)
        }
        let others = [content.accessibilityLabel] + content.tooltipLines + [content.copyText ?? ""]
        for text in others {
            for scalar in text.unicodeScalars where scalar != "\n" && scalar != "\t" {
                XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar),
                               "\(context): a tooltip, label or copy text holds U+\(String(scalar.value, radix: 16, uppercase: true))",
                               file: file, line: line)
            }
        }
    }

    // MARK: - One peer message

    func testOnePeerMessageIsOneLineWithTheNameTheModeAndTheFirstLineOfTheBody() {
        let content = peer([item()])

        XCTAssertEqual(content.line, "↘ PDO Demo · bypass: run the tests")
        XCTAssertEqual(content.target, .none)
    }

    func testWithoutAModeTheLineHasNoModeSeparator() {
        let content = peer([item(mode: nil)])

        XCTAssertEqual(content.line, "↘ PDO Demo: run the tests")
        XCTAssertNil(content.badge)
    }

    func testAMissingOrEmptyNameReadsAsAnotherSession() {
        XCTAssertEqual(peer([item(nil, mode: nil)]).line, "↘ another session: run the tests")
        XCTAssertEqual(peer([item("", mode: nil)]).line, "↘ another session: run the tests")
    }

    func testOnlyTheFirstLineOfAMultiLineBodyIsOnTheLineAndTheTooltipHasTheRest() {
        let body = "first line\nsecond line\nthird line"
        let content = peer([item(body: body)])

        XCTAssertEqual(content.line, "↘ PDO Demo · bypass: first line")
        XCTAssertFalse(content.line.contains("second"))
        XCTAssertTrue(content.tooltipLines.joined(separator: "\n").contains("second line\nthird line"))
        XCTAssertEqual(content.copyText, body)
    }

    func testALongBodyIsCappedToOneBoundedLineEndingInAnEllipsis() {
        let content = peer([item(mode: nil, body: String(repeating: "b", count: 500))])

        XCTAssertEqual(content.line, "↘ PDO Demo: " + String(repeating: "b", count: 119) + "…")
    }

    func testALongNameIsCappedAndStillLeavesTheBody() {
        let content = peer([item(String(repeating: "N", count: 100), mode: nil)])

        XCTAssertEqual(content.line, "↘ " + String(repeating: "N", count: 39) + "…: run the tests")
    }

    func testALongModeIsCut() {
        let content = peer([item(mode: String(repeating: "a", count: 40))])

        XCTAssertEqual(content.line, "↘ PDO Demo · " + String(repeating: "a", count: 16) + ": run the tests")
    }

    func testATruncatedBodyEndsInAnEllipsisAndAWholeOneDoesNot() {
        XCTAssertEqual(peer([item(mode: nil, body: "hello", truncated: true)]).line, "↘ PDO Demo: hello…")
        XCTAssertEqual(peer([item(mode: nil, body: "hello", truncated: false)]).line, "↘ PDO Demo: hello")
    }

    func testTheTooltipHoldsTheBodyAndTheSendersSocket() {
        let content = peer([item(body: "run the tests", socket: "/tmp/pdo.sock")])

        XCTAssertEqual(content.tooltipLines, ["run the tests", "From /tmp/pdo.sock"])
    }

    func testTheTooltipCapsAHugeBodyButTheCopyTextCarriesAllOfIt() {
        let content = peer([item(body: String(repeating: "x", count: 8_000))])

        XCTAssertEqual(content.tooltipLines.first?.count, 1_500)
        XCTAssertEqual(content.copyText?.count, 8_000)
    }

    // MARK: - Separators cannot be forged

    func testANameWithAColonOrADotCannotDrawTheSeparatorsOrTheBadge() {
        for name in ["PDO:Demo", "PDO · Demo", "x · bypass: y", "x:", ": · :", "bypass · bypass:"] {
            let content = peer([item(name, mode: "default")])

            XCTAssertNil(content.badge, name)
            XCTAssertFalse(content.line.contains(" · bypass:"), "\(name): \(content.line)")
            XCTAssertEqual(count(of: "·", in: content.line), 1, "\(name): only the app's own separator: \(content.line)")
            XCTAssertEqual(count(of: ":", in: content.line), 1, "\(name): only the app's own colon: \(content.line)")
            XCTAssertTrue(content.line.hasSuffix(": run the tests"), name)
            XCTAssertTrue(content.line.contains(" · default: "), name)
        }
    }

    func testANameThatFakesAModeSeparatorOnAModelessMessageDrawsNoSeparatorAtAll() {
        let content = peer([item("evil · bypass", mode: nil)])

        XCTAssertNil(content.badge)
        XCTAssertEqual(count(of: "·", in: content.line), 0)
    }

    func testAModeCannotCarryTheSeparatorsAMarkOrASpace() {
        let content = peer([item(mode: "default: ↘ fake · bypass:")])

        XCTAssertEqual(count(of: ":", in: content.line), 1)
        XCTAssertEqual(count(of: "·", in: content.line), 1)
        XCTAssertEqual(count(of: "↘", in: content.line), 1)
        XCTAssertNil(content.badge)
    }

    func testAModeOfOnlySeparatorsIsNoMode() {
        XCTAssertEqual(peer([item(mode: "·:")]).line, "↘ PDO Demo: run the tests")
    }

    // MARK: - The badge

    func testOnlyTheExactModeBypassDrawsABadgeAndItIsAWordOfTheLine() {
        let content = peer([item(mode: "bypass")])

        XCTAssertEqual(content.badge, "bypass")
        XCTAssertTrue(content.line.contains(" · bypass:"), "the view finds the badge between the app's own separators")
    }

    func testEveryOtherModeHasNoBadge() {
        for mode in [nil, "default", "plan", "acceptEdits", "bypass2", "bypass-all", ""] as [String?] {
            XCTAssertNil(peer([item(mode: mode)]).badge, "mode \(mode ?? "nil")")
        }
    }

    func testTheBypassModeMatchesWhateverItsCase() {
        for mode in ["Bypass", "BYPASS"] {
            let content = peer([item(mode: mode)])
            XCTAssertEqual(content.badge, mode)
            XCTAssertTrue(content.line.contains(" · \(mode):"), mode)
        }
    }

    func testAMergedPeerTurnShowsTheBadgeWhenAnyMessageCameFromABypassSession() {
        let content = peer([item("A", mode: "default"), item("A", mode: "Bypass"), item("A", mode: "default")])

        XCTAssertEqual(content.badge, "Bypass")
        XCTAssertEqual(content.line, "↘ 3 messages from A · Bypass")
        XCTAssertTrue(content.accessibilityLabel.contains("Bypass mode"), content.accessibilityLabel)
    }

    func testAMergedPeerTurnWithNoBypassMessageHasNoBadgeAndKeepsItsLine() {
        let content = peer([item("A", mode: "default"), item("A", mode: nil)])

        XCTAssertNil(content.badge)
        XCTAssertEqual(content.line, "↘ 2 messages from A")
    }

    func testAnotherModeIsPlainTextOnTheLine() {
        XCTAssertEqual(peer([item(mode: "plan")]).line, "↘ PDO Demo · plan: run the tests")
    }

    // MARK: - Spoken label, copy text, tooltip

    func testTheSpokenLabelNamesTheSessionTheModeAndTheText() {
        XCTAssertEqual(peer([item()]).accessibilityLabel, "Message from session PDO Demo, bypass mode: run the tests.")
    }

    func testTheCopyTextIsTheBodyNotTheLine() {
        let content = peer([item(body: "line one\n\nline three")])

        XCTAssertEqual(content.copyText, "line one\n\nline three")
        XCTAssertFalse(content.copyText?.contains("↘") == true)
    }

    // MARK: - Several messages

    func testSeveralMessagesFromOneSenderAreOneCountedLine() {
        let content = peer([item(body: "one"), item(body: "two"), item(body: "three")])

        XCTAssertEqual(content.line, "↘ 3 messages from PDO Demo")
        XCTAssertEqual(content.tooltipLines, ["one", "two", "three"])
        XCTAssertEqual(content.copyText, "one\n\ntwo\n\nthree")
        XCTAssertEqual(content.target, .none)
    }

    func testMessagesFromDifferentSendersAreFromOtherSessionsAndTheTooltipNamesEach() {
        let content = peer([item("A", body: "one"), item("B", body: "two"), item("A", body: "three")])

        XCTAssertEqual(content.line, "↘ 3 messages from other sessions")
        XCTAssertEqual(content.tooltipLines, ["A: one", "B: two", "A: three"])
        XCTAssertTrue(content.accessibilityLabel.hasPrefix("3 messages from other sessions"))
    }

    func testTheTooltipOfABurstShowsOnlyEachFirstLineButTheCopyTextHasEveryWholeBody() {
        let content = peer([item(body: "a1\na2"), item(body: "b1\nb2")])

        XCTAssertEqual(content.tooltipLines, ["a1", "b1"])
        XCTAssertEqual(content.copyText, "a1\na2\n\nb1\nb2")
    }

    func testMessagesTheDaemonDroppedCountTowardTheTotalAndAreCountedInTheTooltip() {
        let one = peer([item(body: "one")], omitted: 2)
        XCTAssertEqual(one.line, "↘ 3 messages from PDO Demo")
        XCTAssertEqual(one.tooltipLines, ["one", "…and 2 more"])

        XCTAssertEqual(peer([item(), item()], omitted: 5).line, "↘ 7 messages from PDO Demo")
        XCTAssertEqual(peer([item()], omitted: -3).line, "↘ PDO Demo · bypass: run the tests", "a negative count is no count")
    }

    func testTheTooltipListsTwentyMessagesAndCountsTheRest() {
        let content = peer((0 ..< 25).map { item(body: "m\($0)") })

        XCTAssertEqual(content.line, "↘ 25 messages from PDO Demo")
        XCTAssertEqual(content.tooltipLines.count, 21)
        XCTAssertEqual(content.tooltipLines[19], "m19")
        XCTAssertEqual(content.tooltipLines.last, "…and 5 more")
    }

    func testNoItemsAtAllIsAGenericMarker() {
        let content = peer([])

        XCTAssertEqual(content.line, "↘ Message from another session")
        XCTAssertEqual(content.target, .none)
    }

    // MARK: - Hostile text

    func testHostileNamesModesAndBodiesLeaveNoControlDirectionOrLineBreakScalarAndStayOneBoundedLine() {
        for (index, hostile) in HostileContent.all.enumerated() {
            for content in [peer([item(hostile, mode: hostile, body: hostile, socket: hostile)]),
                            peer([item(hostile, mode: nil, body: hostile), item(hostile, mode: nil, body: "x")]),
                            peer([item(hostile, mode: hostile, body: hostile), item("other", mode: nil, body: hostile)], omitted: 4)] {
                assertClean(content, "hostile string #\(index)")
                XCTAssertLessThan(content.line.count, 200, "hostile string #\(index) is bounded on the line")
                XCTAssertEqual(content.target, .none)
            }
        }
    }

    func testAHostileNameCannotStartASecondLine() {
        let content = peer([item("evil\n↘ Mother: succeeded \"x\"", mode: nil)])

        XCTAssertFalse(content.line.contains("\n"))
        XCTAssertFalse(content.accessibilityLabel.contains("\n"))
    }

    // MARK: - Injected context

    func testALoadedSkillNamesTheSkill() {
        let content = WakeMarkerText.injectedContext(kind: "skill", title: "commit-helper", text: "# Skill\nDo things", truncated: false)

        XCTAssertEqual(content.line, "ⓘ Skill loaded: commit-helper")
        XCTAssertEqual(content.target, .none)
        XCTAssertNil(content.badge)
        XCTAssertTrue(content.accessibilityLabel.hasPrefix("Skill loaded: commit-helper"))
    }

    func testASkillWithNoTitleIsUnnamed() {
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "skill", title: "", text: "x", truncated: false).line, "ⓘ Skill loaded: unnamed")
    }

    func testASummaryAndAnyOtherKindHaveTheirOwnWords() {
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "summary", title: "ignored", text: "x", truncated: false).line, "ⓘ Conversation summary")
        for kind in ["other", "", "from_the_future", "Skill", "SUMMARY"] {
            XCTAssertEqual(WakeMarkerText.injectedContext(kind: kind, title: "t", text: "x", truncated: false).line, "ⓘ Injected context", kind)
        }
    }

    func testTheInjectedTextIsNeverOnTheLineButIsTheTooltipAndTheCopyText() {
        let text = "<system-reminder>\nsecret body\n</system-reminder>"
        for kind in ["skill", "summary", "other"] {
            let content = WakeMarkerText.injectedContext(kind: kind, title: "t", text: text, truncated: false)

            XCTAssertFalse(content.line.contains("<"), kind)
            XCTAssertFalse(content.line.contains("secret"), kind)
            XCTAssertEqual(content.tooltipLines, [text], kind)
            XCTAssertEqual(content.copyText, text, kind)
        }
    }

    func testALongSkillTitleIsCappedAndAHostileOneIsClean() {
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "skill", title: String(repeating: "T", count: 100), text: "x", truncated: false).line,
                       "ⓘ Skill loaded: " + String(repeating: "T", count: 39) + "…")
        for (index, hostile) in HostileContent.all.enumerated() {
            let content = WakeMarkerText.injectedContext(kind: "skill", title: hostile, text: hostile, truncated: true)

            assertClean(content, "hostile string #\(index)")
            XCTAssertLessThan(content.line.count, 80, "hostile string #\(index)")
        }
    }

    func testATruncatedTextSaysSoInTheTooltipAndAWholeOneDoesNot() {
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "other", title: "", text: "abc", truncated: true).tooltipLines.first?.hasSuffix("…"), true)
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "other", title: "", text: "abc", truncated: false).tooltipLines, ["abc"])
    }

    func testAHugeInjectedTextIsCappedInTheTooltipButCopiedWhole() {
        let content = WakeMarkerText.injectedContext(kind: "other", title: "", text: String(repeating: "x", count: 8_000), truncated: false)

        XCTAssertEqual(content.tooltipLines.first?.count, 1_500)
        XCTAssertEqual(content.copyText?.count, 8_000)
    }

    func testAnInjectedContextWithNoTextHasNoTooltip() {
        XCTAssertEqual(WakeMarkerText.injectedContext(kind: "summary", title: "", text: "", truncated: false).tooltipLines, [])
    }

    // MARK: - The marker an injected turn is drawn as on a client with no marker view of its own

    func testAPeerTurnIsLabelledPeerEvenWhenTheSenderCallsItselfYou() {
        let marker = WakeMarkerText.injectedTurnMarker(for: .peerMessage(items: [item("You")], omitted: 0))

        XCTAssertEqual(marker?.label, "Peer")
        XCTAssertEqual(marker?.content, peer([item("You")]))
        XCTAssertTrue(marker?.content.line.hasPrefix("↘ ") == true)
    }

    func testASkillAndOtherInjectedContextAreLabelledSkillAndInjected() {
        let skill = WakeMarkerText.injectedTurnMarker(for: .injectedContext(kind: "skill", title: "portal-open", text: "x", truncated: false))
        let summary = WakeMarkerText.injectedTurnMarker(for: .injectedContext(kind: "summary", title: "", text: "x", truncated: false))
        let other = WakeMarkerText.injectedTurnMarker(for: .injectedContext(kind: "other", title: "", text: "x", truncated: false))

        XCTAssertEqual(skill?.label, "Skill")
        XCTAssertEqual(summary?.label, "Injected")
        XCTAssertEqual(other?.label, "Injected")
        XCTAssertEqual(other?.content.line, "ⓘ Injected context")
    }

    func testAnyOtherOriginOrNoneHasNoInjectedMarker() {
        XCTAssertNil(WakeMarkerText.injectedTurnMarker(for: nil))
        XCTAssertNil(WakeMarkerText.injectedTurnMarker(for: .taskWake(items: [], omitted: 0)))
        XCTAssertNil(WakeMarkerText.injectedTurnMarker(for: .terminalDelivery(items: [])))
    }
}
