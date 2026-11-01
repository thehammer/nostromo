import XCTest
import NostromoKit

// BA4: what a task window's title and header say, as plain strings (`TaskWindowContent`). Pure: no window,
// no clock (the instant is an argument), no locale or time zone of the machine (both are arguments).
//
// Every string in the content came from the CLI or the model, so every field must come out free of what
// the sanitiser exists for. `HostileContent` lives in NostromoKit's tests and is invisible to this target:
// its strings are copied here, as `WakeMarkerAppearanceTests` does.

final class TaskWindowContentTests: XCTestCase {

    /// ANSI, OSC 8 and OSC 0 (BEL-terminated), bidi controls, tag characters, NUL, DEL, line breaks, C1, and
    /// the invisible fillers.
    private static let hostile = "\u{1B}[31mred\u{1B}[0m \u{1B}]8;;https://x\u{1B}\\label\u{1B}]8;;\u{1B}\\"
        + "\u{1B}]0;evil title\u{07}safe\u{202E}evil\u{2066}iso\u{2069}\u{200E}\u{200F}tail tag\u{E0041}\u{E007F}ged before\u{0}after "
        + "one\ntwo\r\nthree\tfour\u{7F}five \u{2028}\u{2029} a\u{034F}b\u{115F}c\u{1160}d\u{17B4}e\u{17B5}f\u{2800}g\u{3164}h\u{FFA0}i "
        + "\u{85}\u{9B}31mj\u{61C}k"
    private static let hostile10KB = hostile + " " + String(repeating: "W", count: 10_240)

    /// What must never survive onto a drawn field. `\n` and `\t` are allowed only in the document fields
    /// (prompt, summary), which keep their line breaks.
    private static func forbidden(_ scalar: Unicode.Scalar, allowingLineBreaks: Bool) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            return !allowingLineBreaks
        case 0x0000 ... 0x001F, 0x007F, 0x0080 ... 0x009F,
             0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069,
             0xE0000 ... 0xE007F,
             0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// 2026-06-15 14:03:07 UTC, in ms since 1970.
    private static let startMs: UInt64 = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TaskWindowContentTests.utc
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 14, minute: 3, second: 7))!
        return UInt64(date.timeIntervalSince1970 * 1000)
    }()

    private func meta(kind: TaskKindWire = .shell, description: String = "npm run build", toolUseId: String? = nil,
                      status: TaskStatusWire = .running, endReason: TaskEndReasonWire? = nil,
                      startedAtMs: UInt64? = nil, endedAtMs: UInt64? = nil, durationMs: UInt64? = nil,
                      totalTokens: UInt64? = nil, toolUses: UInt64? = nil, lastToolName: String? = nil,
                      hasOutput: Bool = false) -> TaskMetaWire {
        TaskMetaWire(id: "t1", kind: kind, description: description, toolUseId: toolUseId, status: status,
                     endReason: endReason, startedAtMs: startedAtMs, endedAtMs: endedAtMs, durationMs: durationMs,
                     totalTokens: totalTokens, toolUses: toolUses, lastToolName: lastToolName, hasOutput: hasOutput)
    }

    private func make(_ meta: TaskMetaWire, focus: String = "kate", detail: SessionTaskDetailWire? = nil,
                      nowMs: UInt64 = 0) -> TaskWindowContent {
        TaskWindowContent.make(tag: "kate-tag", focusName: focus, meta: meta, row: nil, detail: detail, nowMs: nowMs,
                               timeZone: Self.utc, locale: Self.posix)
    }

    private func detail(progress: String? = nil, completion: String? = nil, prompt: String? = nil) -> SessionTaskDetailWire {
        SessionTaskDetailWire(tag: "kate-tag", taskId: "t1", progressSummary: progress, completionSummary: completion,
                              prompt: prompt)
    }

    // MARK: Title

    func testTheTitleIsTheFocusTheKindAndTheDescription() {
        XCTAssertEqual(make(meta()).windowTitle, "kate \u{00B7} Shell: npm run build")
        XCTAssertEqual(make(meta(kind: .agent, description: "Write failing tests")).windowTitle,
                       "kate \u{00B7} Agent: Write failing tests")
    }

    func testTheTitleLeavesOutWhatItDoesNotHave() {
        XCTAssertEqual(make(meta(description: "")).windowTitle, "kate \u{00B7} Shell")
        XCTAssertEqual(make(meta(), focus: "").windowTitle, "Shell: npm run build")
    }

    func testTheTitleCutsTheDescriptionToEightyCharactersButTheHeaderKeepsAllOfIt() {
        let prefix = "kate \u{00B7} Shell: "
        let long = String(repeating: "abcdefghij", count: 20)

        let content = make(meta(description: long))

        XCTAssertTrue(content.windowTitle.hasPrefix(prefix))
        let shown = String(content.windowTitle.dropFirst(prefix.count))
        XCTAssertEqual(shown.count, 80, "the description is cut to 80 characters")
        XCTAssertTrue(shown.hasSuffix("\u{2026}"), "and says it was cut")
        XCTAssertTrue(long.hasPrefix(String(shown.dropLast())))
        XCTAssertEqual(content.description, long, "the header has the whole description")
    }

    func testADescriptionOfExactlyEightyCharactersIsNotCut() {
        let eighty = String(repeating: "x", count: 80)
        let eightyOne = String(repeating: "x", count: 81)

        XCTAssertEqual(make(meta(description: eighty)).windowTitle, "kate \u{00B7} Shell: " + eighty)
        XCTAssertNotEqual(make(meta(description: eightyOne)).windowTitle, "kate \u{00B7} Shell: " + eightyOne)
    }

    func testATitleForATaskTheStoreNoLongerListsFollowsTheSameShape() {
        XCTAssertEqual(TaskWindowContent.windowTitle(focusName: "kate", kindLabel: "Shell", description: "npm run build"),
                       "kate \u{00B7} Shell: npm run build")
        let cut = TaskWindowContent.windowTitle(focusName: "kate", kindLabel: "Shell", description: String(repeating: "y", count: 300))
        XCTAssertEqual(cut.count, "kate \u{00B7} Shell: ".count + 80)
    }

    func testTheKindIsNamedForEveryKind() {
        let expected: [(TaskKindWire, String)] = [(.shell, "Shell"), (.monitor, "Monitor"), (.agent, "Agent"),
                                                  (.workflow, "Workflow"), (.other, "Other"), (.unknown("new"), "Other")]
        for (kind, label) in expected {
            XCTAssertEqual(make(meta(kind: kind)).kindLabel, label, "\(kind)")
        }
    }

    // MARK: Status

    func testTheStatusTextAndTheFailedFlag() {
        let running = make(meta(status: .running))
        XCTAssertEqual(running.statusText, "running")
        XCTAssertFalse(running.isFailed)
        XCTAssertFalse(running.isEnded)

        let completed = make(meta(status: .completed))
        XCTAssertEqual(completed.statusText, "completed")
        XCTAssertFalse(completed.isFailed)
        XCTAssertTrue(completed.isEnded)

        let failed = make(meta(status: .failed))
        XCTAssertEqual(failed.statusText, "failed")
        XCTAssertTrue(failed.isFailed, "only a failed task is flagged failed")
        XCTAssertTrue(failed.isEnded)
    }

    func testAStoppedTaskSaysWhyWhenItWasARestartOrTheEndOfTheSession() {
        let restart = make(meta(status: .stopped, endReason: .restart))
        XCTAssertEqual(restart.statusText, "stopped \u{00B7} restart")
        XCTAssertFalse(restart.isFailed)

        let sessionEnded = make(meta(status: .stopped, endReason: .sessionEnded))
        XCTAssertEqual(sessionEnded.statusText, "stopped \u{00B7} session ended")
        XCTAssertFalse(sessionEnded.isFailed)

        XCTAssertEqual(make(meta(status: .stopped, endReason: .userStop)).statusText, "stopped")
        XCTAssertEqual(make(meta(status: .stopped)).statusText, "stopped")
        XCTAssertEqual(make(meta(status: .completed, endReason: .restart)).statusText, "completed",
                       "the reason only qualifies a stopped task")
    }

    // MARK: Started, running for, ran for

    func testARunningTaskSaysWhenItStartedAndHowLongItHasRun() throws {
        let content = make(meta(status: .running, startedAtMs: Self.startMs), nowMs: Self.startMs + 63_000)

        let started = try XCTUnwrap(content.startedText)
        XCTAssertTrue(started.hasPrefix("Started "), started)
        XCTAssertTrue(started.contains("2:03:07"), "the start time in the zone given: \(started)")
        let duration = try XCTUnwrap(ToolGroupSummary.durationText(seconds: 63))
        XCTAssertEqual(content.timeText, "Running for " + duration)
    }

    func testAnEndedTaskSaysHowLongItRanAndTheTimeStopsGrowing() throws {
        let ended = meta(status: .completed, startedAtMs: Self.startMs, endedAtMs: Self.startMs + 5_000)
        let five = try XCTUnwrap(ToolGroupSummary.durationText(seconds: 5))

        XCTAssertEqual(make(ended, nowMs: Self.startMs + 5_000).timeText, "Ran for " + five)
        XCTAssertEqual(make(ended, nowMs: Self.startMs + 900_000).timeText, "Ran for " + five, "later does not change what it ran")
    }

    func testTheDaemonsDurationWinsOverTheTimestampsOfAnEndedTask() throws {
        let content = make(meta(status: .failed, startedAtMs: Self.startMs, endedAtMs: Self.startMs + 5_000, durationMs: 9_000))

        let nine = try XCTUnwrap(ToolGroupSummary.durationText(seconds: 9))
        XCTAssertEqual(content.timeText, "Ran for " + nine)
    }

    // MARK: Summaries

    func testAnEndedTaskShowsItsCompletionSummary() {
        let content = make(meta(status: .completed), detail: detail(progress: "halfway", completion: "Built 12 files"))

        XCTAssertEqual(content.summary, "Built 12 files")
    }

    func testAnEndedTaskNeverShowsAProgressSummary() {
        XCTAssertNil(make(meta(status: .completed), detail: detail(progress: "halfway")).summary)
        XCTAssertNil(make(meta(status: .failed), detail: detail(progress: "halfway")).summary)
    }

    func testARunningTaskShowsItsProgressSummary() {
        let content = make(meta(status: .running), detail: detail(progress: "halfway", completion: "Built 12 files"))

        XCTAssertEqual(content.summary, "halfway")
    }

    func testARunningTaskNeverShowsACompletionSummary() {
        XCTAssertNil(make(meta(status: .running), detail: detail(completion: "Built 12 files")).summary,
                     "a completion summary belongs to a task that has ended")
    }

    // MARK: Activity

    func testAnAgentSaysItsTokensToolsAndCurrentTool() {
        let content = make(meta(kind: .agent, totalTokens: 18_200, toolUses: 11, lastToolName: "Edit"))

        XCTAssertEqual(content.activityText, "18.2k tokens \u{00B7} 11 tools \u{00B7} Edit")
    }

    func testAnAgentSaysOnlyWhatItKnowsOfItsActivity() {
        XCTAssertEqual(make(meta(kind: .agent, toolUses: 1)).activityText, "1 tool")
        XCTAssertEqual(make(meta(kind: .agent, totalTokens: 950)).activityText, "950 tokens")
        XCTAssertNil(make(meta(kind: .agent)).activityText)
    }

    func testOnlyAnAgentHasActivity() {
        for kind in [TaskKindWire.shell, .monitor, .workflow, .other] {
            XCTAssertNil(make(meta(kind: kind, totalTokens: 18_200, toolUses: 11, lastToolName: "Edit")).activityText, "\(kind)")
        }
    }

    // MARK: Line breaks

    func testThePromptAndTheSummaryKeepTheirLineBreaks() {
        let prompt = "Write tests for the parser.\n\nCover:\n\t- empty input\n\t- nested lists"
        let summary = "Done.\nTwo files changed."

        let content = make(meta(kind: .agent, status: .completed), detail: detail(completion: summary, prompt: prompt))

        XCTAssertEqual(content.prompt, prompt)
        XCTAssertEqual(content.summary, summary)
    }

    func testALineBreakIsOneLineFeedAndTheDescriptionIsOneLine() {
        let content = make(meta(description: "first\r\nsecond\nthird"), detail: detail(completion: "a\r\nb"))
        let ended = make(meta(description: "first\r\nsecond\nthird", status: .completed), detail: detail(completion: "a\r\nb"))

        XCTAssertFalse(content.description.contains("\n"), "the description is one line in the header")
        XCTAssertFalse(content.description.contains("\r"))
        XCTAssertEqual(ended.summary, "a\nb", "CRLF is one line break")
    }

    // MARK: Hostile content

    private func fields(of content: TaskWindowContent) -> [(name: String, text: String, allowsLineBreaks: Bool)] {
        [("windowTitle", content.windowTitle, false),
         ("kindLabel", content.kindLabel, false),
         ("description", content.description, false),
         ("statusText", content.statusText, false),
         ("startedText", content.startedText ?? "", false),
         ("timeText", content.timeText ?? "", false),
         ("activityText", content.activityText ?? "", false),
         ("accessibilityLabel", content.accessibilityLabel, false),
         ("summary", content.summary ?? "", true),
         ("prompt", content.prompt ?? "", true)]
    }

    private func assertClean(_ content: TaskWindowContent, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for (name, text, allowsLineBreaks) in fields(of: content) {
            for scalar in text.unicodeScalars where Self.forbidden(scalar, allowingLineBreaks: allowsLineBreaks) {
                XCTFail("\(label): \(name) holds U+\(String(scalar.value, radix: 16, uppercase: true))", file: file, line: line)
                break
            }
        }
    }

    func testEveryFieldOfAHostileTaskComesOutFreeOfControlDirectionAndFillerScalars() {
        for (label, text) in [("hostile", Self.hostile), ("hostile + 10 KB", Self.hostile10KB)] {
            for status in [TaskStatusWire.running, .completed, .failed, .stopped] {
                let content = make(meta(kind: .agent, description: text, toolUseId: "toolu_1", status: status,
                                        endReason: .restart, startedAtMs: Self.startMs, endedAtMs: Self.startMs + 5_000,
                                        totalTokens: 18_200, toolUses: 11, lastToolName: text),
                                   focus: text,
                                   detail: detail(progress: text, completion: text, prompt: text), nowMs: Self.startMs + 9_000)

                assertClean(content, "\(label), \(status)")
            }
        }
    }

    func testAHostileUnknownStatusIsCleanToo() {
        let content = make(meta(status: .unknown(Self.hostile)))

        assertClean(content, "unknown status")
        XCTAssertFalse(content.statusText.isEmpty, "a status the client does not know still says something")
    }

    func testTheTitleAndTheAccessibilityLabelOfAHostileTaskAreCleanAndStillReadable() {
        let content = make(meta(description: Self.hostile10KB), focus: Self.hostile)

        for text in [content.windowTitle, content.accessibilityLabel] {
            XCTAssertTrue(text.contains("safe"), "what is readable survives: \(text.prefix(120))")
            XCTAssertTrue(text.contains("label"))
            XCTAssertFalse(text.contains("evil title"), "an OSC title is dropped whole")
        }
        XCTAssertGreaterThanOrEqual(content.description.count, 10_240, "the header keeps the whole description")
    }

    func testTheTitleStaysShortForA10KBDescription() {
        let content = make(meta(description: Self.hostile10KB))

        XCTAssertLessThanOrEqual(content.windowTitle.count, "kate \u{00B7} Shell: ".count + 80)
    }

    func testTheStaticTitleOfAHostileTaskIsClean() {
        let title = TaskWindowContent.windowTitle(focusName: Self.hostile10KB, kindLabel: "Shell", description: Self.hostile10KB)

        for scalar in title.unicodeScalars {
            XCTAssertFalse(Self.forbidden(scalar, allowingLineBreaks: false), "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }

    // MARK: Unknown values

    func testWhatTheDaemonDidNotSayIsNil() {
        let content = make(meta(kind: .agent, status: .running))

        XCTAssertNil(content.startedText)
        XCTAssertNil(content.timeText)
        XCTAssertNil(content.summary)
        XCTAssertNil(content.prompt)
        XCTAssertNil(content.activityText)
        XCTAssertNil(content.toolUseId)
    }

    func testAnEndedTaskWithNoDurationAndNoEndTimeHasNoRanForText() {
        XCTAssertNil(make(meta(status: .completed, startedAtMs: Self.startMs)).timeText)
        XCTAssertNil(make(meta(status: .completed)).timeText)
    }

    func testTheAgentCallsIdIsCarriedForTheSubagentView() {
        XCTAssertEqual(make(meta(kind: .agent, toolUseId: "toolu_77")).toolUseId, "toolu_77")
    }

    func testOnlyShellAndMonitorTasksAndKindsTheDaemonHasOutputForOfferOutput() {
        XCTAssertTrue(make(meta(kind: .shell)).hasOutput)
        XCTAssertTrue(make(meta(kind: .monitor)).hasOutput)
        XCTAssertFalse(make(meta(kind: .agent)).hasOutput)
        XCTAssertFalse(make(meta(kind: .workflow)).hasOutput)
        XCTAssertFalse(make(meta(kind: .other)).hasOutput)
        XCTAssertTrue(make(meta(kind: .other, hasOutput: true)).hasOutput, "the daemon says it can show this one")
    }

    // MARK: Accessibility label

    func testTheAccessibilityLabelReadsKindDescriptionStatusAndTime() throws {
        let content = make(meta(status: .running, startedAtMs: Self.startMs), nowMs: Self.startMs + 63_000)

        let duration = try XCTUnwrap(ToolGroupSummary.durationText(seconds: 63))
        XCTAssertEqual(content.accessibilityLabel, "Shell, npm run build, running, Running for \(duration)")
    }

    func testTheAccessibilityLabelSkipsWhatIsEmpty() {
        let content = make(meta(description: ""))

        XCTAssertEqual(content.accessibilityLabel, "Shell, running")
    }
}
