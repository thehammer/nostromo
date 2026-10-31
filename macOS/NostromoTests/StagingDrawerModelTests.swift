import XCTest
import Foundation

// `StagingDrawerModel`: everything the drawer says and decides, with no views and no clocks of its own.
//
//   * Why a row is disabled: nine fixed strings, checked in a fixed priority order (mirror, daemon,
//     connecting/ended, not local, full-screen program, paste still sending, just changed (under 1.5 s,
//     exactly 1.5 s is allowed, an unknown time counts as just changed), not insertable). Nothing an agent
//     wrote ever appears in one.
//   * The header, the collapsed strip, the age ("10s", "4m", "1h", "2d", amber after 30 minutes), the
//     "inserted 2m ago" line, the note ("Claudia's note (unverified): ..." sanitised), the placeholder
//     warning (computed by the app, never from agent text) and the VoiceOver label.
//   * The exact bytes of an insert.

final class StagingDrawerModelTests: XCTestCase {

    private let now = StagingFixtures.baseDate.addingTimeInterval(1_000)

    private func env(mirror: Bool = false, connected: Bool = true, status: TerminalStatus? = .running,
                     kind: TerminalKind? = .local, alt: Bool = false, sending: Bool = false) -> StagingEnvironment {
        StagingEnvironment(isMirror: mirror, daemonConnected: connected, status: status, kind: kind,
                           isAlternateScreen: alt, isSendingInput: sending)
    }

    private func list(agent: String = "Claudia", state: TerminalStagingState = .active,
                      _ entries: [StagingEntry]) -> TerminalStagingList {
        StagingFixtures.list(state: state, agent: agent, revision: 1, entries: entries)
    }

    private func row(_ entry: StagingEntry, index: Int = 0, of entries: [StagingEntry]? = nil, agent: String = "Claudia",
                     env: StagingEnvironment? = nil, shownSince: TimeInterval? = 0, clock: TimeInterval = 100) -> StagingRowModel {
        StagingDrawerModel.row(entry, index: index, of: list(agent: agent, entries ?? [entry]), env: env ?? self.env(),
                               shownSince: shownSince, now: clock, date: now)
    }

    private func entry(_ command: String = "ls -la", note: String? = nil, changedAgo: TimeInterval = 10,
                       inserted: (count: Int, agoSeconds: TimeInterval)? = nil) -> StagingEntry {
        StagingFixtures.entry("s-1", 1, command, note: note, changedAt: now.addingTimeInterval(-changedAgo),
                              insertedCount: inserted?.count ?? 0,
                              lastInsertedAt: inserted.map { now.addingTimeInterval(-$0.agoSeconds) })
    }

    // MARK: The reasons: fixed strings

    func testEveryDisabledReasonHasItsFixedText() {
        XCTAssertEqual(StagingDisabledReason.mirror.text, "Click the terminal to drive it from this window")
        XCTAssertEqual(StagingDisabledReason.daemonDisconnected.text, "Nostromo's daemon is not connected")
        XCTAssertEqual(StagingDisabledReason.connecting.text, "The shell is still connecting")
        XCTAssertEqual(StagingDisabledReason.ended.text, "The shell has ended")
        XCTAssertEqual(StagingDisabledReason.notLocal.text, "Staging into remote shells is not available yet")
        XCTAssertEqual(StagingDisabledReason.alternateScreen.text, "A full-screen program is running")
        XCTAssertEqual(StagingDisabledReason.sendingPaste.text, "A paste is still being sent")
        XCTAssertEqual(StagingDisabledReason.justChanged.text, "Just changed: read it again")
        XCTAssertEqual(StagingDisabledReason.notInsertable.text, "Nostromo will not insert this text")
    }

    func testOnlyTheTwoPerEntryReasonsAreNotSharedByEveryRow() {
        let shared: [StagingDisabledReason] = [.mirror, .daemonDisconnected, .connecting, .ended, .notLocal, .alternateScreen, .sendingPaste]
        for reason in shared { XCTAssertTrue(reason.appliesToEveryRow, "\(reason)") }
        XCTAssertFalse(StagingDisabledReason.justChanged.appliesToEveryRow)
        XCTAssertFalse(StagingDisabledReason.notInsertable.appliesToEveryRow)
    }

    // MARK: The reasons: priority

    func testNothingIsInTheWayOfAnOrdinaryLocalRunningShell() {
        XCTAssertNil(StagingDrawerModel.sharedReason(env()))
    }

    func testTheSharedReasonsAreCheckedInTheDocumentedOrder() {
        var e = env(mirror: true, connected: false, status: .connecting, kind: .ecs, alt: true, sending: true)
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .mirror)
        e.isMirror = false
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .daemonDisconnected)
        e.daemonConnected = true
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .connecting)
        e.status = .ended
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .ended)
        e.status = .running
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .notLocal)
        e.kind = .local
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .alternateScreen)
        e.isAlternateScreen = false
        XCTAssertEqual(StagingDrawerModel.sharedReason(e), .sendingPaste)
        e.isSendingInput = false
        XCTAssertNil(StagingDrawerModel.sharedReason(e))
    }

    func testAStatusThatIsNotRunningOrEndedCountsAsConnecting() {
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(status: .connecting)), .connecting)
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(status: .unknown)), .connecting)
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(status: nil)), .connecting)
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(status: .ended)), .ended)
    }

    func testAnythingButALocalKindIsNotLocalIncludingMissingAndUnknown() {
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(kind: .ecs)), .notLocal)
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(kind: .unknown)), .notLocal)
        XCTAssertEqual(StagingDrawerModel.sharedReason(env(kind: nil)), .notLocal)
        XCTAssertNil(StagingDrawerModel.sharedReason(env(kind: .local)))
    }

    func testTheOneAndAHalfSecondReadingDelayBoundary() {
        let e = entry()
        XCTAssertEqual(StagingDrawerModel.readingDelay, 1.5)
        XCTAssertEqual(StagingDrawerModel.reason(for: e, env: env(), shownSince: 100, now: 100), .justChanged)
        XCTAssertEqual(StagingDrawerModel.reason(for: e, env: env(), shownSince: 100, now: 101.49), .justChanged)
        XCTAssertNil(StagingDrawerModel.reason(for: e, env: env(), shownSince: 100, now: 101.5), "exactly 1.5 s is allowed")
        XCTAssertNil(StagingDrawerModel.reason(for: e, env: env(), shownSince: 100, now: 500))
    }

    func testAnEntryWithNoKnownTimeCountsAsJustChanged() {
        XCTAssertEqual(StagingDrawerModel.reason(for: entry(), env: env(), shownSince: nil, now: 10_000), .justChanged)
    }

    func testATextTheAppWillNotInsertIsNotInsertableOnceItHasBeenReadable() {
        let bad = entry("ls\u{09}-la")
        XCTAssertEqual(StagingDrawerModel.reason(for: bad, env: env(), shownSince: 0, now: 100), .notInsertable)
        XCTAssertEqual(StagingDrawerModel.reason(for: entry(""), env: env(), shownSince: 0, now: 100), .notInsertable)
    }

    func testAPerEntryReasonNeverBeatsASharedOneAndJustChangedBeatsNotInsertable() {
        let bad = entry("ls\u{09}-la")
        XCTAssertEqual(StagingDrawerModel.reason(for: bad, env: env(mirror: true), shownSince: nil, now: 100), .mirror)
        XCTAssertEqual(StagingDrawerModel.reason(for: bad, env: env(sending: true), shownSince: nil, now: 100), .sendingPaste)
        XCTAssertEqual(StagingDrawerModel.reason(for: bad, env: env(), shownSince: 100, now: 100), .justChanged)
        XCTAssertEqual(StagingDrawerModel.reason(for: bad, env: env(), shownSince: 0, now: 100), .notInsertable)
    }

    func testASnapshotKeepsTheExactCommandAndTheReasonDecidedAtThatMoment() {
        let e = StagingFixtures.entry("s-7", 7, "echo \u{201C}hi\u{201D}")

        let ready = StagingDrawerModel.snapshot(terminalId: "t", entry: e, env: env(), shownSince: 0, now: 100)
        XCTAssertEqual(ready, StagingSnapshot(terminalId: "t", entryId: "s-7", command: "echo \u{201C}hi\u{201D}", reason: nil))

        let blocked = StagingDrawerModel.snapshot(terminalId: "t", entry: e, env: env(alt: true), shownSince: 0, now: 100)
        XCTAssertEqual(blocked.reason, .alternateScreen)
        XCTAssertEqual(blocked.command, e.command)
    }

    // MARK: Bytes

    func testBytesAreTheExactUTF8WithoutBracketedPaste() throws {
        for command in try StagingFixtures.commands() {
            XCTAssertEqual(StagingDrawerModel.bytes(for: command, bracketedPaste: false), Array(command.utf8), command)
        }
    }

    func testBytesAreWrappedInTheBracketedPasteMarkersWhenAsked() throws {
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC [ 2 0 0 ~
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]     // ESC [ 2 0 1 ~
        for command in try StagingFixtures.commands() {
            XCTAssertEqual(StagingDrawerModel.bytes(for: command, bracketedPaste: true), start + Array(command.utf8) + end, command)
        }
    }

    func testBytesNeverAddALineBreakOrAnyOtherControl() {
        for bracketed in [false, true] {
            let bytes = StagingDrawerModel.bytes(for: "echo hi", bracketedPaste: bracketed)
            XCTAssertFalse(bytes.contains(0x0D), "no CR")
            XCTAssertFalse(bytes.contains(0x0A), "no LF")
            XCTAssertEqual(bytes.filter { $0 < 0x20 }.count, bracketed ? 2 : 0, "only the two ESCs of the paste markers")
        }
    }

    func testMultiByteCharactersAreSentAsTheirUTF8() {
        XCTAssertEqual(StagingDrawerModel.bytes(for: "é日", bracketedPaste: false), [0xC3, 0xA9, 0xE6, 0x97, 0xA5])
    }

    // MARK: Header and strip

    func testTheHeaderNamesTheAgentAndCountsTheEntries() {
        let l = list([entry(), StagingFixtures.entry("s-2", 2, "pwd"), StagingFixtures.entry("s-3", 3, "date")])
        XCTAssertEqual(StagingDrawerModel.headerText(l), "Staged by Claudia (3)")
        let parts = StagingDrawerModel.headerParts(l)
        XCTAssertEqual(parts.lead, "Staged by Claudia")
        XCTAssertEqual(parts.count, "(3)")
    }

    func testTheEmptyHeaderTellsThePersonWhatToDo() {
        let text = StagingDrawerModel.headerText(list([]))
        XCTAssertEqual(text, "Staged by Claudia \u{00B7} nothing yet. Click a staged command to put it at the prompt; you press Enter.")
        XCTAssertNil(StagingDrawerModel.headerParts(list([])).count)
    }

    func testAFrozenListSaysTheAgentStoppedAndItWillNotChange() {
        let withEntries = list(state: .frozen, [entry()])
        XCTAssertEqual(StagingDrawerModel.headerText(withEntries), "Claudia stopped following; this list won't change")
        XCTAssertNil(StagingDrawerModel.headerParts(withEntries).count)
        XCTAssertEqual(StagingDrawerModel.headerText(list(state: .frozen, [])), "Claudia stopped following; this list won't change")
    }

    func testTheAgentNameIsSanitisedAndCappedAtFortyCharacters() {
        XCTAssertEqual(StagingDrawerModel.agentNameLimit, 40)
        let long = String(repeating: "a", count: 60)
        let shown = StagingDrawerModel.agentName(list(agent: long, [entry()]))
        XCTAssertEqual(shown.count, 40)
        XCTAssertTrue(shown.hasSuffix("\u{2026}"))

        XCTAssertEqual(StagingDrawerModel.agentName(list(agent: "Cla\u{202E}u\u{200B}dia\n", [entry()])), "Claudia")
    }

    func testAnAgentNameThatIsEmptyOrInvisibleIsCalledTheAgent() {
        for name in ["", "   ", "\u{200B}\u{3164}", "\u{202E}"] {
            XCTAssertEqual(StagingDrawerModel.agentName(list(agent: name, [entry()])), "The agent", name.debugDescription)
        }
        XCTAssertEqual(StagingDrawerModel.headerText(list(agent: "", [entry()])), "Staged by The agent (1)")
    }

    func testALongAgentNameCutsTheLeadAndKeepsTheCountInItsOwnPart() {
        let l = list(agent: String(repeating: "N", count: 80), [entry(), StagingFixtures.entry("s-2", 2, "pwd")])
        let parts = StagingDrawerModel.headerParts(l)

        XCTAssertEqual(parts.count, "(2)", "the count never truncates: it is not part of the lead")
        XCTAssertFalse(parts.lead.contains("(2)"))
        XCTAssertLessThanOrEqual(parts.lead.count, "Staged by ".count + 40)
    }

    func testTheStripSaysHowManyAreStagedAndByWhom() {
        let three = list([entry(), StagingFixtures.entry("s-2", 2, "pwd"), StagingFixtures.entry("s-3", 3, "date")])
        XCTAssertEqual(StagingDrawerModel.stripText(three), "3 staged by Claudia \u{25B8}")
        XCTAssertEqual(StagingDrawerModel.stripText(list([])), "Nothing staged by Claudia \u{25B8}")
        XCTAssertEqual(StagingDrawerModel.stripText(list(state: .frozen, [entry()])), "1 staged by Claudia (stopped) \u{25B8}")
    }

    // MARK: Age

    func testAgeIsShownInTheLargestWholeUnit() {
        let base = StagingFixtures.baseDate
        func age(_ seconds: TimeInterval) -> String { StagingDrawerModel.ageText(since: base, now: base.addingTimeInterval(seconds)) }
        XCTAssertEqual(age(0), "0s")
        XCTAssertEqual(age(10), "10s")
        XCTAssertEqual(age(59), "59s")
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(4 * 60 + 30), "4m")
        XCTAssertEqual(age(3_599), "59m")
        XCTAssertEqual(age(3_600), "1h")
        XCTAssertEqual(age(5 * 3_600 + 59), "5h")
        XCTAssertEqual(age(86_400), "1d")
        XCTAssertEqual(age(2 * 86_400 + 5), "2d")
        XCTAssertEqual(age(-30), "0s", "a time in the future is not a negative age")
    }

    func testTheRowShowsTheAgeSinceTheEntryLastChanged() {
        XCTAssertEqual(row(entry(changedAgo: 10)).age, "10s")
        XCTAssertEqual(row(entry(changedAgo: 240)).age, "4m")
        XCTAssertEqual(row(entry(changedAgo: 3_600)).age, "1h")
        XCTAssertEqual(row(entry(changedAgo: 2 * 86_400)).age, "2d")
    }

    func testAgeTurnsAmberAfterThirtyMinutes() {
        XCTAssertFalse(row(entry(changedAgo: 60)).ageIsStale)
        XCTAssertFalse(row(entry(changedAgo: 30 * 60)).ageIsStale, "exactly 30 minutes is not yet stale")
        XCTAssertTrue(row(entry(changedAgo: 30 * 60 + 1)).ageIsStale)
        XCTAssertTrue(row(entry(changedAgo: 3 * 3_600)).ageIsStale)
    }

    // MARK: State and the inserted line

    func testAReadyRowIsReadyWithTheArrowGlyph() {
        let r = row(entry())
        XCTAssertEqual(r.state, .ready)
        XCTAssertEqual(r.glyph, "\u{25B8}")
        XCTAssertNil(r.disabledReason)
    }

    func testAnInsertedRowSaysHowLongAgoAndShowsACheck() {
        let r = row(entry(inserted: (count: 2, agoSeconds: 120)))
        XCTAssertEqual(r.state, .inserted(ago: "inserted 2m ago"))
        XCTAssertEqual(r.glyph, "\u{2713}")
    }

    func testAnInsertedCountWithNoTimeIsJustReady() {
        XCTAssertEqual(row(entry(inserted: nil)).state, .ready)
        let noTime = StagingFixtures.entry("s-1", 1, "ls", insertedCount: 3, lastInsertedAt: nil)
        XCTAssertEqual(row(noTime).state, .ready)
    }

    func testADisabledRowShowsTheReasonAndItsGlyphEvenIfItWasInsertedBefore() {
        let r = row(entry(inserted: (count: 1, agoSeconds: 60)), env: env(mirror: true))
        XCTAssertEqual(r.state, .disabled(.mirror))
        XCTAssertEqual(r.glyph, "\u{2298}")
        XCTAssertEqual(r.disabledReason, .mirror)
    }

    func testRowsForAListGetTheirOwnShownSinceFromTheClosure() {
        let entries = [StagingFixtures.entry("a", 1, "ls"), StagingFixtures.entry("b", 2, "pwd")]
        let rows = StagingDrawerModel.rows(for: list(entries), env: env(),
                                           shownSince: { $0 == "a" ? 0.0 : 99.0 }, now: 100, date: now)

        XCTAssertEqual(rows.map(\.entryId), ["a", "b"])
        XCTAssertEqual(rows[0].state, .ready)
        XCTAssertEqual(rows[1].state, .disabled(.justChanged), "b was shown 1 s ago")
    }

    // MARK: The note

    func testTheNoteIsLabelledUnverifiedAndNamesTheAgent() {
        XCTAssertEqual(row(entry(note: "see what changed")).noteText, "Claudia's note (unverified): see what changed")
        XCTAssertNil(row(entry(note: nil)).noteText)
    }

    func testTheNoteIsSanitisedLikeAnyAgentText() {
        let hostile = "ru\u{202E}n\u{200B} it\u{FEFF} now\u{3164}\u{2800}\u{FFA0}\u{034F}\u{2028}and\nthen\tmore"
        XCTAssertEqual(row(entry(note: hostile)).noteText, "Claudia's note (unverified): run it now and then more")
    }

    func testANoteOfNothingVisibleIsNoNote() {
        for note in ["", "   ", "\u{200B}\u{3164}\u{2800}", "\n\n"] {
            XCTAssertNil(row(entry(note: note)).noteText, note.debugDescription)
        }
    }

    func testALongNoteIsCutAtTwoHundredFortyCharacters() throws {
        XCTAssertEqual(StagingDrawerModel.noteLimit, 240)
        let text = try XCTUnwrap(row(entry(note: String(repeating: "n", count: 500))).noteText)
        let prefix = "Claudia's note (unverified): "
        XCTAssertTrue(text.hasPrefix(prefix))
        XCTAssertEqual(text.count, prefix.count + 240)
        XCTAssertTrue(text.hasSuffix("\u{2026}"))
    }

    func testTheNotePrefixUsesTheSanitisedAgentName() {
        XCTAssertEqual(row(entry(note: "hi"), agent: "Cla\u{202E}udia").noteText, "Claudia's note (unverified): hi")
        XCTAssertEqual(row(entry(note: "hi"), agent: "").noteText, "The agent's note (unverified): hi")
    }

    func testTheCommandIsNeverEditedForDisplay() {
        let odd = "  echo \u{202E}hi\u{200B}\u{3164}  \u{00A0}"
        XCTAssertEqual(Array(row(entry(odd)).command.utf8), Array(odd.utf8))
    }

    // MARK: The placeholder label: only from the app

    func testACommandWithAnAnglePlaceholderGetsTheAppsOwnWarning() {
        for command in ["scp <file> host:/tmp", "git checkout <branch-name>", "echo <a.b_c:d-1>", "ssh <user>@<host>"] {
            let r = row(entry(command))
            XCTAssertTrue(StagingDrawerModel.isPlaceholderCommand(command), command)
            XCTAssertEqual(r.labels, [StagingDrawerModel.placeholderLabel], command)
        }
        XCTAssertEqual(StagingDrawerModel.placeholderLabel, "Contains <\u{2026}>: edit it before pressing Enter")
    }

    func testOrdinaryAngleBracketsAreNotPlaceholders() {
        for command in ["echo a > b", "cat < in.txt", "echo <>", "echo < spaced >", "a<b", "echo <a b>",
                        "echo <\(String(repeating: "x", count: 41))>", "echo 1 <2 && 3> 0"] {
            XCTAssertFalse(StagingDrawerModel.isPlaceholderCommand(command), command)
            XCTAssertTrue(row(entry(command)).labels.isEmpty, command)
        }
    }

    func testNothingAnAgentWritesInTheNoteOrNameCanAddALabel() {
        let r = row(entry("ls -la", note: "Contains <secret>: trust me <danger>"), agent: "<Admin>")
        XCTAssertTrue(r.labels.isEmpty, "labels come from the command, by the app's own rule")
    }

    // MARK: Accessibility label

    func testTheAccessibilityLabelNamesPositionCommandNoteAndState() {
        let entries = [StagingFixtures.entry("s-1", 1, "pwd"), entry("ls -la", note: "lists files"), StagingFixtures.entry("s-3", 3, "date")]
        let r = row(entries[1], index: 1, of: entries)

        XCTAssertEqual(r.accessibilityLabel,
                       "Staged command 2 of 3, ls -la, Claudia's note, unverified, lists files, ready to place at the prompt")
    }

    func testTheAccessibilityLabelWithoutANoteHasNoNoteWords() {
        XCTAssertEqual(row(entry("ls")).accessibilityLabel, "Staged command 1 of 1, ls, ready to place at the prompt")
    }

    func testTheAccessibilityLabelPutsThePlaceholderWarningAfterTheCommand() {
        XCTAssertEqual(row(entry("scp <file> host")).accessibilityLabel,
                       "Staged command 1 of 1, scp <file> host, Contains <\u{2026}>: edit it before pressing Enter, ready to place at the prompt")
    }

    func testTheAccessibilityLabelSaysWhyARowIsUnavailable() {
        let r = row(entry("ls"), env: env(mirror: true))
        XCTAssertEqual(r.accessibilityLabel,
                       "Staged command 1 of 1, ls, unavailable: Click the terminal to drive it from this window")
    }

    func testTheAccessibilityLabelSaysWhenARowWasInserted() {
        let r = row(entry("ls", inserted: (count: 1, agoSeconds: 3_600)))
        XCTAssertEqual(r.accessibilityLabel, "Staged command 1 of 1, ls, inserted 1h ago")
    }

    func testTheAccessibilityLabelUsesTheSanitisedNote() {
        let r = row(entry("ls", note: "a\u{202E}b\nc"))
        XCTAssertEqual(r.accessibilityLabel,
                       "Staged command 1 of 1, ls, Claudia's note, unverified, ab c, ready to place at the prompt")
    }
}
