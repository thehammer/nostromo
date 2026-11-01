// NostromoKit — WakeMarkerTextTests.swift
//
// MF2c: the one muted line a Mother job notice shows in the transcript's user slot, its tooltip, its
// VoiceOver label and where a click on it goes (`WakeMarkerText.motherNotice`).
//
// Every mark on the line (`⟲`, the quotes, the state words, `PR #n`) is built by the app; the only
// untrusted text is a job's title, which sits inside the quotes after sanitising and a cap. So no
// title (and no unknown state) can draw a second marker, a tick or a line break of its own.

import XCTest
@testable import NostromoKit

final class WakeMarkerTextTests: XCTestCase {

    // MARK: - Helpers

    private func item(_ id: String = "j-1", title: String = "MF4: In-pane plan viewer", state: String = "succeeded",
                      pr: Int? = nil) -> MotherNoticeItemWire {
        MotherNoticeItemWire(jobId: id, title: title, state: state, since: [],
                             prUrl: pr.map { "https://example.test/pull/\($0)" }, prNumber: pr)
    }

    private func items(_ n: Int) -> [MotherNoticeItemWire] {
        (0 ..< n).map { item("j-\($0)", title: "Job \($0)", state: $0 % 2 == 0 ? "succeeded" : "failed") }
    }

    /// The title inside the first pair of quotes of `text` up to the last quote on the line, for
    /// titles without quotes of their own.
    private func quotedTitle(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close else { return nil }
        return String(text[text.index(after: open) ..< close])
    }

    private static let lineSeparators: Set<Unicode.Scalar> = ["\u{2028}", "\u{2029}", "\u{85}", "\n", "\r"]

    /// Every string the marker offers, with a name for failures.
    private func allTexts(_ content: WakeMarkerContent) -> [(name: String, text: String)] {
        [("line", content.line), ("accessibility label", content.accessibilityLabel)]
            + content.tooltipLines.enumerated().map { ("tooltip line \($0.offset)", $0.element) }
    }

    private func assertClean(_ content: WakeMarkerContent, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (name, text) in allTexts(content) {
            for scalar in text.unicodeScalars {
                XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar),
                               "\(context): \(name) holds U+\(String(scalar.value, radix: 16, uppercase: true))", file: file, line: line)
                XCTAssertFalse(Self.lineSeparators.contains(scalar),
                               "\(context): \(name) holds a line break (U+\(String(scalar.value, radix: 16, uppercase: true)))", file: file, line: line)
            }
        }
    }

    // MARK: - One job

    func testOneJobIsOneQuotedTitleItsStateAndItsPullRequest() {
        let content = WakeMarkerText.motherNotice([item(pr: 391)])

        XCTAssertEqual(content.line, "⟲ Mother: succeeded \"MF4: In-pane plan viewer\" · PR #391")
        XCTAssertEqual(content.target, .motherJob(id: "j-1"))
        XCTAssertEqual(content.tooltipLines.count, 1)
        XCTAssertTrue(content.tooltipLines[0].contains("MF4: In-pane plan viewer"))
        XCTAssertTrue(content.tooltipLines[0].contains("succeeded"))
    }

    func testOneJobWithoutAPullRequestNumberHasNoPRPart() {
        let content = WakeMarkerText.motherNotice([item(state: "failed")])

        XCTAssertEqual(content.line, "⟲ Mother: failed \"MF4: In-pane plan viewer\"")
        XCTAssertFalse(content.line.contains("PR"))
    }

    func testEveryKnownStateHasItsWords() {
        let words: [(state: String, words: String)] = [
            ("succeeded", "succeeded"), ("failed", "failed"), ("cancelled", "cancelled"), ("awaiting", "needs you"),
            ("pr_merged", "PR merged"), ("pr_opened", "PR opened"), ("running", "running"), ("queued", "queued"),
        ]
        for (state, expected) in words {
            let content = WakeMarkerText.motherNotice([item(title: "T", state: state)])

            XCTAssertEqual(content.line, "⟲ Mother: \(expected) \"T\"", state)
            XCTAssertEqual(content.accessibilityLabel, "Mother update: \(expected), T.", state)
        }
    }

    func testAnUnknownStateIsShownAsPlainWords() {
        let content = WakeMarkerText.motherNotice([item(title: "T", state: "hovering")])

        XCTAssertEqual(content.line, "⟲ Mother: hovering \"T\"")
    }

    func testOneJobsAccessibilityLabelNamesTheStateAndThePullRequest() {
        XCTAssertEqual(WakeMarkerText.motherNotice([item(pr: 391)]).accessibilityLabel,
                       "Mother update: succeeded, MF4: In-pane plan viewer, pull request 391.")
        XCTAssertEqual(WakeMarkerText.motherNotice([item(state: "awaiting")]).accessibilityLabel,
                       "Mother update: needs you, MF4: In-pane plan viewer.")
    }

    func testTheAccessibilityLabelReadsTheStateBeforeATitleThatNamesAnotherState() {
        let content = WakeMarkerText.motherNotice([item(title: "Deploy failed", state: "succeeded")])

        XCTAssertEqual(content.accessibilityLabel, "Mother update: succeeded, Deploy failed.")
    }

    func testAJobWithNoTitleStillMakesAMarkerWithItsState() {
        let content = WakeMarkerText.motherNotice([item(title: "")])

        XCTAssertTrue(content.line.hasPrefix("⟲ Mother: succeeded \""))
        XCTAssertEqual(content.target, .motherJob(id: "j-1"))
    }

    // MARK: - Several jobs

    func testSeveralJobsAreOneCountedLineWithOneTooltipLineEach() {
        let content = WakeMarkerText.motherNotice(items(3))

        XCTAssertEqual(content.line, "⟲ 3 Mother updates")
        XCTAssertEqual(content.tooltipLines.count, 3)
        for (index, line) in content.tooltipLines.enumerated() {
            XCTAssertTrue(line.contains("Job \(index)"), line)
        }
        XCTAssertTrue(content.tooltipLines[0].contains("succeeded"))
        XCTAssertTrue(content.tooltipLines[1].contains("failed"))
        XCTAssertEqual(content.target, .motherJobs(ids: ["j-0", "j-1", "j-2"]))
    }

    func testSeveralJobsAccessibilityLabelIsTheCountThenTheTooltipLinesJoined() {
        let content = WakeMarkerText.motherNotice(items(3))

        XCTAssertEqual(content.accessibilityLabel, "3 Mother updates. " + content.tooltipLines.joined(separator: "; "))
        XCTAssertFalse(content.accessibilityLabel.contains("\n"))
    }

    func testTheTooltipListsTwentyJobsAndThenCountsTheRest() {
        for (count, more) in [(20, 0), (21, 1), (25, 5)] {
            let content = WakeMarkerText.motherNotice(items(count))

            XCTAssertEqual(content.line, "⟲ \(count) Mother updates")
            if more == 0 {
                XCTAssertEqual(content.tooltipLines.count, 20, "\(count) jobs")
                XCTAssertFalse(content.tooltipLines.contains { $0.hasPrefix("…and") }, "\(count) jobs: nothing is left to count")
            } else {
                XCTAssertEqual(content.tooltipLines.count, 21, "\(count) jobs: twenty and the count of the rest")
                XCTAssertEqual(content.tooltipLines.last, "…and \(more) more", "\(count) jobs")
                XCTAssertTrue(content.tooltipLines[19].contains("Job 19"), "\(count) jobs: the twentieth is the last one listed")
            }
        }
    }

    func testClickingSeveralJobsStillKnowsEveryJobAndOpensTheFirst() {
        let content = WakeMarkerText.motherNotice(items(25))

        guard case .motherJobs(let ids) = content.target else { return XCTFail("target: \(content.target)") }
        XCTAssertEqual(ids.first, "j-0")
        XCTAssertEqual(ids, (0 ..< 25).map { "j-\($0)" })
    }

    // MARK: - Caps

    func testALongTitleIsCutToEightyCharactersInTheLineEndingInAnEllipsis() {
        let content = WakeMarkerText.motherNotice([item(title: String(repeating: "a", count: 200))])

        let title = quotedTitle(in: content.line)
        XCTAssertEqual(title?.count, 80)
        XCTAssertEqual(title?.last, "…")
        XCTAssertTrue(content.line.hasPrefix("⟲ Mother: succeeded \""))
        XCTAssertTrue(content.line.hasSuffix("\""))
    }

    func testTheLineCapBoundaryAtEightyAndEightyOne() {
        let eighty = WakeMarkerText.motherNotice([item(title: String(repeating: "b", count: 80))])
        let eightyOne = WakeMarkerText.motherNotice([item(title: String(repeating: "b", count: 81))])

        XCTAssertEqual(quotedTitle(in: eighty.line), String(repeating: "b", count: 80), "exactly the limit is untouched")
        XCTAssertEqual(quotedTitle(in: eightyOne.line)?.count, 80)
        XCTAssertEqual(quotedTitle(in: eightyOne.line)?.last, "…")
    }

    func testATooltipTitleIsCutToOneHundredAndTwentyCharactersEndingInAnEllipsis() {
        let content = WakeMarkerText.motherNotice([item(title: String(repeating: "c", count: 300))])

        let title = quotedTitle(in: content.tooltipLines[0])
        XCTAssertEqual(title?.count, 120)
        XCTAssertEqual(title?.last, "…")
    }

    func testTheTooltipCapBoundaryAtOneHundredTwentyAndOneHundredTwentyOne() {
        let exact = WakeMarkerText.motherNotice([item(title: String(repeating: "d", count: 120))])
        let over = WakeMarkerText.motherNotice([item(title: String(repeating: "d", count: 121))])

        XCTAssertEqual(quotedTitle(in: exact.tooltipLines[0]), String(repeating: "d", count: 120))
        XCTAssertEqual(quotedTitle(in: over.tooltipLines[0])?.count, 120)
        XCTAssertEqual(quotedTitle(in: over.tooltipLines[0])?.last, "…")
    }

    func testTheAccessibilityLabelTitleIsCappedAtOneHundredAndTwenty() {
        let content = WakeMarkerText.motherNotice([item(title: String(repeating: "e", count: 300), state: "failed")])

        let prefix = "Mother update: failed, "
        let suffix = "."
        XCTAssertTrue(content.accessibilityLabel.hasPrefix(prefix))
        XCTAssertTrue(content.accessibilityLabel.hasSuffix(suffix))
        let title = String(content.accessibilityLabel.dropFirst(prefix.count).dropLast(suffix.count))
        XCTAssertEqual(title.count, 120)
        XCTAssertEqual(title.last, "…")
    }

    func testSeveralJobsTooltipLinesEachCapTheirTitle() {
        let long = (0 ..< 3).map { item("j-\($0)", title: String(repeating: "f", count: 500)) }

        let content = WakeMarkerText.motherNotice(long)

        for line in content.tooltipLines {
            XCTAssertEqual(quotedTitle(in: line)?.count, 120, line)
        }
        XCTAssertLessThan(content.accessibilityLabel.count, 3 * 200 + 40, "the label stays bounded")
    }

    // MARK: - Hostile titles

    private var hostileTitles: [String] {
        HostileContent.all + ["before\u{2028}after\u{2029}tail", String(repeating: "x", count: 10_240)]
    }

    func testNoHostileTitleLeavesAForbiddenScalarOrALineBreakAnywhere() {
        for (index, title) in hostileTitles.enumerated() {
            assertClean(WakeMarkerText.motherNotice([item(title: title, pr: 7)]), "single, hostile title #\(index)")
            assertClean(WakeMarkerText.motherNotice([item("a", title: title), item("b", title: "ok", state: "failed")]),
                        "several, hostile title #\(index)")
        }
    }

    func testAHostileTitleKeepsTheLineOneBoundedLineWithTheAppsOwnStructure() {
        for (index, title) in hostileTitles.enumerated() {
            let content = WakeMarkerText.motherNotice([item(title: title, pr: 7)])

            XCTAssertTrue(content.line.hasPrefix("⟲ Mother: succeeded \""), "hostile title #\(index)")
            XCTAssertTrue(content.line.hasSuffix("\" · PR #7"), "hostile title #\(index): the PR part closes the line")
            XCTAssertFalse(content.line.contains("\n"), "hostile title #\(index)")
            XCTAssertLessThanOrEqual(content.line.count, "⟲ Mother: succeeded \"\" · PR #7".count + 80, "hostile title #\(index)")
        }
    }

    func testATitleThatLooksLikeTheMarkersOwnMarksStaysPlainTextInsideTheQuotes() {
        for title in ["⟲ Mother: \"fake\" succeeded", "✓ told the agent", "He said \"stop\" and left", "⟲"] {
            let content = WakeMarkerText.motherNotice([item(title: title, pr: 7)])
            let chars = Array(content.line)

            XCTAssertEqual(chars.first, "⟲", title)
            XCTAssertEqual(chars[1], " ", "\(title): the character after the one marker is a space, not a second marker")
            XCTAssertTrue(content.line.hasPrefix("⟲ Mother: succeeded \""), title)
            XCTAssertTrue(content.line.hasSuffix("\" · PR #7"), "\(title): the app's PR part is last")
            let shown = title.replacingOccurrences(of: "\"", with: "'").trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(content.line.contains(shown), "\(title): kept as text, double quotes shown as '")
            XCTAssertEqual(content.line.filter { $0 == "\"" }.count, 2, "\(title): only the app's own two quotes")
        }
    }

    func testAForgedStateAndPRSuffixInATitleCannotCloseTheQuotesOrOutrankTheRealState() {
        let titles = ["Deploy\" succeeded · PR #1 \"x", "Deploy\u{201D} succeeded · PR #1 \u{201C}x", "a\u{2033} fake", "x\"\u{301} succeeded \"\u{200D}y"]
        for title in titles {
            let content = WakeMarkerText.motherNotice([item(title: title, state: "failed", pr: 9)])

            XCTAssertTrue(content.line.hasPrefix("⟲ Mother: failed \""), "\(title): the real state leads, before any title text")
            XCTAssertEqual(content.line.unicodeScalars.filter { $0 == "\"" }.count, 2, title)
            XCTAssertFalse(content.line.contains("\u{201C}") || content.line.contains("\u{201D}"), title)
            XCTAssertTrue(content.line.hasSuffix("\" · PR #9"), title)
            XCTAssertTrue(content.tooltipLines[0].hasPrefix("failed \""), title)
        }
    }

    func testAHostileUnknownStateCannotPutAMarkOrATickInTheLine() {
        let states = ["⟲ ✓ told", "\u{202E}evil\u{2066}", "\u{1B}[31mred\u{1B}[0m", "failed\" ⟲ \"x", "✓", "a\nb",
                      String(repeating: "z", count: 5_000)]
        for state in states {
            let content = WakeMarkerText.motherNotice([item(title: "T", state: state)])

            XCTAssertEqual(content.line.unicodeScalars.filter { $0 == "⟲" }.count, 1, "state \(state.debugDescription): only the app's own marker")
            XCTAssertFalse(content.line.contains("✓"), "state \(state.debugDescription)")
            XCTAssertTrue(content.line.hasPrefix("⟲ Mother: "), "state \(state.debugDescription)")
            assertClean(content, "state \(state.debugDescription)")
            XCTAssertFalse(content.accessibilityLabel.contains("⟲") || content.accessibilityLabel.contains("✓"), "state \(state.debugDescription)")
            XCTAssertFalse(content.tooltipLines.contains { $0.contains("⟲") || $0.contains("✓") }, "state \(state.debugDescription)")
            XCTAssertLessThan(content.line.count, 80, "state \(state.debugDescription): a state is never long")
        }
    }

    // MARK: - Background task wakes (BA6b)

    private func wake(_ kind: String = "monitor", _ outcome: String = "new_output",
                      _ description: String = "CI for PR #251", id: String? = "bmon01") -> TaskWakeItemWire {
        TaskWakeItemWire(taskId: id, toolUseId: nil, kind: kind, outcome: outcome, description: description)
    }

    func testOneWakeIsStateFirstWithTheQuotedDescription() {
        let content = WakeMarkerText.taskWake([wake()], omitted: 0)

        XCTAssertEqual(content.line, "⟲ Monitor: new output \"CI for PR #251\"")
        XCTAssertEqual(content.tooltipLines, ["Monitor: new output \"CI for PR #251\""])
        XCTAssertEqual(content.accessibilityLabel, "Background Monitor: new output, CI for PR #251.")
        XCTAssertEqual(content.target, .backgroundTask(id: "bmon01"))
    }

    func testEveryKindAndOutcomeHasItsWords() {
        let cases: [(String, String, String)] = [
            ("shell", "completed", "⟲ Shell: completed \"d\""), ("shell", "failed", "⟲ Shell: failed \"d\""),
            ("shell", "stopped", "⟲ Shell: stopped \"d\""), ("monitor", "ended", "⟲ Monitor: ended \"d\""),
            ("monitor", "new_output", "⟲ Monitor: new output \"d\""), ("agent", "completed", "⟲ Agent: finished \"d\""),
            ("agent", "failed", "⟲ Agent: failed \"d\""), ("other", "event", "⟲ Background task: event \"d\""),
            ("weird", "odd_thing", "⟲ Background task: odd thing \"d\""),
        ]
        for (kind, outcome, expected) in cases {
            XCTAssertEqual(WakeMarkerText.taskWake([wake(kind, outcome, "d")], omitted: 0).line, expected, "\(kind)/\(outcome)")
        }
    }

    func testNoDescriptionDropsTheQuotesAndAnOtherEventReadsBackgroundEvent() {
        XCTAssertEqual(WakeMarkerText.taskWake([wake("shell", "failed", "")], omitted: 0).line, "⟲ Shell: failed")
        XCTAssertEqual(WakeMarkerText.taskWake([wake("shell", "failed", "")], omitted: 0).accessibilityLabel,
                       "Background Shell: failed.")
        XCTAssertEqual(WakeMarkerText.taskWake([wake("other", "event", "", id: nil)], omitted: 0).line, "⟲ Background event")
    }

    func testAWakeWithoutATaskIdHasNoTarget() {
        XCTAssertEqual(WakeMarkerText.taskWake([wake(id: nil)], omitted: 0).target, .none)
    }

    func testSeveralWakesAreOneCountedLineWithOneTooltipLineEach() {
        let content = WakeMarkerText.taskWake([wake(id: "a"), wake("shell", "failed", "npm run build", id: "b"),
                                               wake("agent", "completed", "Find callers", id: nil)], omitted: 0)

        XCTAssertEqual(content.line, "⟲ 3 background events")
        XCTAssertEqual(content.tooltipLines, ["Monitor: new output \"CI for PR #251\"", "Shell: failed \"npm run build\"",
                                              "Agent: finished \"Find callers\""])
        XCTAssertEqual(content.accessibilityLabel, "3 background events. " + content.tooltipLines.joined(separator: "; "))
        XCTAssertEqual(content.target, .backgroundTasks(ids: ["a", "b"]))
    }

    func testTwentyOneWakesListTwentyThenCountTheRestAndOmittedCounts() {
        let many = (0 ..< 21).map { wake("shell", "completed", "c\($0)", id: "t\($0)") }
        let content = WakeMarkerText.taskWake(many, omitted: 4)

        XCTAssertEqual(content.line, "⟲ 25 background events")
        XCTAssertEqual(content.tooltipLines.count, 21)
        XCTAssertEqual(content.tooltipLines.last, "…and 5 more")
    }

    func testOmittedMakesASingleItemACountedLine() {
        XCTAssertEqual(WakeMarkerText.taskWake([wake()], omitted: 2).line, "⟲ 3 background events")
    }

    func testWakeDescriptionCapsAtEightyInTheLineAndOneHundredTwentyInTheTooltip() {
        let content = WakeMarkerText.taskWake([wake("monitor", "new_output", String(repeating: "x", count: 500))], omitted: 0)

        XCTAssertEqual(quotedTitle(in: content.line)?.count, 80)
        XCTAssertTrue(content.line.hasSuffix("…\""))
        XCTAssertEqual(quotedTitle(in: content.tooltipLines[0])?.count, 120)
    }

    func testHostileWakeDescriptionsLeaveNothingForbiddenAndKeepTheAppsStructure() {
        for (index, text) in hostileTitles.enumerated() {
            let single = WakeMarkerText.taskWake([wake("shell", "failed", text)], omitted: 0)
            assertClean(single, "single #\(index)")
            assertClean(WakeMarkerText.taskWake([wake("shell", "failed", text), wake()], omitted: 0), "several #\(index)")
            XCTAssertTrue(single.line.hasPrefix("⟲ Shell: failed") , "#\(index)")
            XCTAssertFalse(single.line.contains("\n"), "#\(index)")
            XCTAssertLessThanOrEqual(single.line.count, "⟲ Shell: failed \"\"".count + 80, "#\(index)")
        }
    }

    func testADescriptionThatLooksLikeTheMarkersOwnMarksStaysInsideTheQuotes() {
        for text in ["⟲ Shell: \"fake\" completed", "✓ done", "x\u{201D} : failed \u{201C}y", "⟲"] {
            let content = WakeMarkerText.taskWake([wake("monitor", "new_output", text)], omitted: 0)

            XCTAssertEqual(content.line.first, "⟲", text)
            XCTAssertTrue(content.line.hasPrefix("⟲ Monitor: new output \""), text)
            XCTAssertEqual(content.line.filter { $0 == "\"" }.count, 2, "\(text): only the app's own two quotes")
            XCTAssertEqual(content.line.filter { $0 == "⟲" }.count, text.contains("⟲") ? 2 : 1,
                           "\(text): the description's mark is plain text inside the quotes")
            XCTAssertEqual(content.accessibilityLabel.filter { $0 == "\"" }.count, 0, "\(text): AX label has no quotes")
        }
    }

    func testAHostileKindOrOutcomeIsPlainWords() {
        let content = WakeMarkerText.taskWake([wake("⟲ \"x\"", "✓ failed \"", "d")], omitted: 0)

        XCTAssertEqual(content.line, "⟲ Background task: failed \"d\"")
    }
}
