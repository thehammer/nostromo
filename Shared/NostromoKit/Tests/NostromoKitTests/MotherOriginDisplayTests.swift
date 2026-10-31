// NostromoKit — MotherOriginDisplayTests.swift
//
// Mother focus v2, MF3: every Mother job row says who queued it. `MotherOriginDisplay.make` turns the
// daemon's annotation, plus the app's current focus names, into what a row, a detail line, a tooltip and
// VoiceOver show.
//
// The contract, by kind:
//
//   focus, tag open     the current name, plain, clickable; the tooltip names the tag, what the job was
//                       queued as when that differs, and the session prefix
//   focus, tag absent   `<name> (closed)`, muted, not clickable; the name falls back focus_name, then
//                       name_snapshot, then the tag
//   unverified          `<snapshot or tag>?` with an "unverified" badge, muted, not clickable
//   you                 "You"
//   unknown, a kind this build does not know, no annotation, no origin: "origin unknown", muted, italic
//
// Names come from agents and shells, so they are untrusted: sanitised, single-line, capped (row 40,
// tooltip 120), and none of the scalars that must never reach a drawn row survive in any string.

import XCTest
@testable import NostromoKit

final class MotherOriginDisplayTests: XCTestCase {

    // MARK: - Helpers

    private func annotation(
        _ kind: MotherOriginKind,
        tag: String? = nil,
        snapshot: String? = nil,
        focusName: String? = nil,
        closed: Bool? = nil,
        prefix: String? = nil
    ) -> MotherJobAnnotation {
        MotherJobAnnotation(origin: MotherOriginView(
            kind: kind, focusTag: tag, nameSnapshot: snapshot, focusName: focusName,
            closed: closed, sessionPrefix: prefix))
    }

    /// The app knows these tags (tag -> current name); everything else is not an open focus.
    private func names(_ open: [String: String]) -> (String) -> String? {
        { open[$0] }
    }

    private let noFocusOpen: (String) -> String? = { _ in nil }

    private let unknownTooltip = "Queued outside Nostromo (or before origins were recorded)."

    /// No scalar that must never survive onto a drawn row. `allowNewlines` for a tooltip, which is
    /// several lines by design.
    private func assertClean(_ s: String, allowNewlines: Bool = false, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for scalar in s.unicodeScalars {
            if allowNewlines && scalar == "\n" { continue }
            XCTAssertFalse(HostileContent.isForbiddenOnARow(scalar),
                           "\(message): U+\(String(scalar.value, radix: 16, uppercase: true)) survived in \(s.prefix(80))",
                           file: file, line: line)
        }
    }

    private func assertAllStringsClean(_ d: MotherOriginDisplay, _ message: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        assertClean(d.text, message + " (text)", file: file, line: line)
        assertClean(d.accessibilityText, message + " (accessibilityText)", file: file, line: line)
        assertClean(d.tooltip, allowNewlines: true, message + " (tooltip)", file: file, line: line)
        if let badge = d.badge { assertClean(badge, message + " (badge)", file: file, line: line) }
        for scalar in d.text.unicodeScalars + d.accessibilityText.unicodeScalars {
            XCTAssertNotEqual(scalar.value, 0x2028, message, file: file, line: line)
            XCTAssertNotEqual(scalar.value, 0x2029, message, file: file, line: line)
        }
    }

    /// Hostile strings that are cheap to run in combinations (the megabyte one is left out), plus
    /// the Unicode line and paragraph separators.
    private var hostile: [String] {
        [HostileContent.longCommand, HostileContent.ansiColour, HostileContent.osc8Hyperlink,
         HostileContent.osc8HyperlinkBEL, HostileContent.bidi, HostileContent.tagCharacters,
         HostileContent.nul, HostileContent.c1Controls, HostileContent.lineBreaksAndC0,
         HostileContent.fillers, HostileContent.kitchenSink,
         "one\u{2028}two\u{2029}three"]
    }

    // MARK: - Focus, tag open

    func testAnOpenFocusShowsItsCurrentNameAsAPlainClickableOrigin() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "claudia-C9D6B773", snapshot: "Fix login",
                                   focusName: "Fix the login flow", closed: false, prefix: "5f3c9a10"),
            currentName: names(["claudia-C9D6B773": "Fix the login flow"]))
        XCTAssertEqual(d.kind, .focus)
        XCTAssertEqual(d.text, "Fix the login flow")
        XCTAssertFalse(d.isMuted)
        XCTAssertFalse(d.isItalic)
        XCTAssertNil(d.badge)
        XCTAssertTrue(d.isClickable)
        XCTAssertEqual(d.focusTag, "claudia-C9D6B773")
        XCTAssertEqual(d.accessibilityText, "From Fix the login flow")
    }

    func testAnOpenFocusUsesTheAppsNameNotTheDaemonsWhenTheyDiffer() {
        // The user renamed the focus in the app; the daemon's `focus_name` has not caught up.
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Old", focusName: "Daemon's name"),
            currentName: names(["t1": "Renamed in the app"]))
        XCTAssertEqual(d.text, "Renamed in the app")
        XCTAssertTrue(d.isClickable)
    }

    func testAnOpenFocusTooltipHasTheTagTheSessionAndWhatItWasQueuedAs() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "claudia-C9D6B773", snapshot: "Fix login", prefix: "5f3c9a10"),
            currentName: names(["claudia-C9D6B773": "Fix the login flow"]))
        XCTAssertTrue(d.tooltip.contains("claudia-C9D6B773"), d.tooltip)
        XCTAssertTrue(d.tooltip.contains("queued as Fix login"), d.tooltip)
        XCTAssertTrue(d.tooltip.contains("session 5f3c9a10"), d.tooltip)
        XCTAssertFalse(d.tooltip.hasPrefix("This focus is closed."), "an open focus is not closed")
    }

    func testTheTooltipOmitsQueuedAsWhenTheSnapshotIsTheNameShown() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Same name"),
            currentName: names(["t1": "Same name"]))
        XCTAssertFalse(d.tooltip.contains("queued as"), d.tooltip)
    }

    func testTheTooltipOmitsTheSessionWhenThereIsNoPrefix() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "S"),
            currentName: names(["t1": "S"]))
        XCTAssertFalse(d.tooltip.contains("session"), d.tooltip)
    }

    func testARenameChangesTheShownNameOnTheNextCall() {
        let note = annotation(.focus, tag: "t1", snapshot: "Before")
        var current = "Before"
        let lookup: (String) -> String? = { $0 == "t1" ? current : nil }
        XCTAssertEqual(MotherOriginDisplay.make(annotation: note, currentName: lookup).text, "Before")
        current = "After"
        let renamed = MotherOriginDisplay.make(annotation: note, currentName: lookup)
        XCTAssertEqual(renamed.text, "After")
        XCTAssertTrue(renamed.tooltip.contains("queued as Before"), renamed.tooltip)
    }

    // MARK: - Focus, tag absent (closed)

    func testAClosedFocusIsMutedAndNotClickableAndSaysClosed() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Fix login", focusName: "Fix the login flow", closed: true),
            currentName: noFocusOpen)
        XCTAssertEqual(d.kind, .focus)
        XCTAssertEqual(d.text, "Fix the login flow (closed)")
        XCTAssertTrue(d.isMuted)
        XCTAssertFalse(d.isClickable)
        XCTAssertTrue(d.tooltip.hasPrefix("This focus is closed."), d.tooltip)
        XCTAssertEqual(d.accessibilityText, "From Fix the login flow (closed)")
    }

    func testAClosedFocusNameFallsBackToTheDaemonsFocusNameFirst() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Snapshot", focusName: "Registry name"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.text, "Registry name (closed)")
    }

    func testAClosedFocusNameFallsBackToTheSnapshotWhenTheDaemonHasNoName() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Snapshot"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.text, "Snapshot (closed)")
    }

    func testAClosedFocusNameFallsBackToTheTagWhenThereAreNoNames() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "claudia-DEADBEEF"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.text, "claudia-DEADBEEF (closed)")
        XCTAssertTrue(d.isMuted)
        XCTAssertFalse(d.isClickable)
    }

    func testAClosedFocusWhoseNameIsAllInvisibleFallsThroughToTheNextName() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Readable", focusName: "\u{202E}\u{2066}\u{200E}"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.text, "Readable (closed)")
    }

    func testAnOpenFocusWhoseCurrentNameIsAllInvisibleStillShowsSomethingReadable() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "claudia-1", snapshot: "Readable"),
            currentName: names(["claudia-1": "\u{202E}\u{2066}\u{200E}"]))
        XCTAssertEqual(d.text, "Readable")
        XCTAssertTrue(d.isClickable)
    }

    func testAFocusRecordedAsClosedByTheDaemonButOpenInTheAppIsOpen() {
        // The app is the authority on what is open right now.
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "S", closed: true),
            currentName: names(["t1": "S"]))
        XCTAssertTrue(d.isClickable)
        XCTAssertFalse(d.isMuted)
        XCTAssertEqual(d.text, "S")
    }

    // MARK: - Unverified

    func testAnUnverifiedClaimShowsTheClaimedNameWithAQuestionMarkAndABadge() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.unverified, tag: "claudia-D00DFEED", snapshot: "Claimed name"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.kind, .unverified)
        XCTAssertEqual(d.text, "Claimed name?")
        XCTAssertEqual(d.badge, "unverified")
        XCTAssertTrue(d.isMuted)
        XCTAssertFalse(d.isClickable)
        XCTAssertEqual(d.tooltip, "Claimed by a shell `mother add`; Nostromo could not verify it. Not notified.")
    }

    func testAnUnverifiedClaimIsNeverClickableEvenWhenItsTagIsAnOpenFocus() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.unverified, tag: "t1", snapshot: "Claimed"),
            currentName: names(["t1": "A real, open focus"]))
        XCTAssertFalse(d.isClickable, "an unverified claim must not link to a focus it cannot vouch for")
        XCTAssertTrue(d.isMuted)
        XCTAssertEqual(d.text, "Claimed?", "the claim shows as claimed, not as the focus it names")
    }

    func testAnUnverifiedClaimWithNoSnapshotShowsTheTag() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.unverified, tag: "claudia-D00DFEED"),
            currentName: noFocusOpen)
        XCTAssertEqual(d.text, "claudia-D00DFEED?")
    }

    func testAnUnverifiedClaimIsReadAsUnverifiedByVoiceOver() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.unverified, tag: "t", snapshot: "Claimed name"),
            currentName: noFocusOpen)
        XCTAssertTrue(d.accessibilityText.hasPrefix("From "), d.accessibilityText)
        XCTAssertTrue(d.accessibilityText.contains("unverified"), d.accessibilityText)
    }

    // MARK: - You

    func testAJobQueuedByYouSaysYouAndIsPlain() {
        let d = MotherOriginDisplay.make(annotation: annotation(.you), currentName: noFocusOpen)
        XCTAssertEqual(d.kind, .you)
        XCTAssertEqual(d.text, "You")
        XCTAssertFalse(d.isMuted)
        XCTAssertFalse(d.isClickable)
        XCTAssertNil(d.badge)
        XCTAssertEqual(d.accessibilityText, "From You")
    }

    // MARK: - Unknown

    private func assertUnknown(_ d: MotherOriginDisplay, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(d.kind, .unknown, message, file: file, line: line)
        XCTAssertEqual(d.text, "origin unknown", message, file: file, line: line)
        XCTAssertTrue(d.isMuted, message, file: file, line: line)
        XCTAssertTrue(d.isItalic, message, file: file, line: line)
        XCTAssertFalse(d.isClickable, message, file: file, line: line)
        XCTAssertNil(d.badge, message, file: file, line: line)
        XCTAssertEqual(d.tooltip, unknownTooltip, message, file: file, line: line)
        XCTAssertEqual(d.accessibilityText, "From origin unknown", message, file: file, line: line)
    }

    func testAnUnknownOriginSaysSoMutedAndItalic() {
        assertUnknown(MotherOriginDisplay.make(annotation: annotation(.unknown), currentName: noFocusOpen), "kind unknown")
    }

    func testAKindThisBuildNeverHeardOfReadsAsUnknownEvenWithAFocusTag() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.other("robot"), tag: "t1", snapshot: "Future focus", focusName: "Future focus"),
            currentName: names(["t1": "Future focus"]))
        assertUnknown(d, "kind robot")
    }

    func testAJobWithNoAnnotationReadsAsUnknown() {
        assertUnknown(MotherOriginDisplay.make(annotation: nil, currentName: noFocusOpen), "no annotation")
    }

    func testAnAnnotationWithNoOriginReadsAsUnknown() {
        let note = MotherJobAnnotation(origin: nil, notify: "quiet")
        assertUnknown(MotherOriginDisplay.make(annotation: note, currentName: noFocusOpen), "no origin")
    }

    func testUnknownIsNotStatedAsFactAboutTheFocusNamedClaudia() {
        // A job whose title is "Claudia" (an agent's name) but whose origin is unknown still says so.
        let d = MotherOriginDisplay.make(annotation: nil, currentName: names(["claudia": "Claudia"]))
        XCTAssertEqual(d.text, "origin unknown")
        let row = MotherJobRowModel(id: "j", state: "queued", title: "Claudia", origin: d)
        XCTAssertEqual(row.origin?.text, "origin unknown")
        XCTAssertEqual(row.accessibilitySummary, "Claudia. From origin unknown.")
    }

    // MARK: - Hostile names

    func testHostileFocusNamesNeverReachAnyStringOfAnOpenFocus() {
        for h in hostile {
            let d = MotherOriginDisplay.make(
                annotation: annotation(.focus, tag: "t1", snapshot: h, focusName: h, prefix: h),
                currentName: names(["t1": h]))
            assertAllStringsClean(d, "open focus name")
        }
    }

    func testHostileNamesNeverReachAnyStringOfAClosedFocus() {
        for h in hostile {
            let d = MotherOriginDisplay.make(
                annotation: annotation(.focus, tag: h, snapshot: h, focusName: h, prefix: h),
                currentName: noFocusOpen)
            assertAllStringsClean(d, "closed focus name")
        }
    }

    func testHostileSnapshotsAndTagsNeverReachAnUnverifiedClaim() {
        for h in hostile {
            assertAllStringsClean(
                MotherOriginDisplay.make(annotation: annotation(.unverified, tag: h, snapshot: h), currentName: noFocusOpen),
                "unverified with hostile snapshot and tag")
            assertAllStringsClean(
                MotherOriginDisplay.make(annotation: annotation(.unverified, tag: h), currentName: noFocusOpen),
                "unverified with hostile tag only")
        }
    }

    func testHostileContentInAnUnknownOrOtherOriginNeverAppears() {
        for h in hostile {
            let d = MotherOriginDisplay.make(
                annotation: annotation(.other(h), tag: h, snapshot: h, focusName: h, prefix: h),
                currentName: names([h: h]))
            assertUnknown(d, "other kind with hostile fields")
        }
    }

    func testAFocusRowNeverCarriesALineBreak() {
        for h in hostile {
            let d = MotherOriginDisplay.make(
                annotation: annotation(.focus, tag: "t1", snapshot: h), currentName: names(["t1": h]))
            XCTAssertFalse(d.text.contains("\n"), "text is one line")
            XCTAssertFalse(d.text.contains("\r"), "text is one line")
            XCTAssertFalse(d.accessibilityText.contains("\n"), "accessibility text is one line")
        }
    }

    // MARK: - Caps

    func testARowNameIsCappedAtFortyCharactersWithAnEllipsis() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1"), currentName: names(["t1": HostileContent.longCommand]))
        XCTAssertLessThanOrEqual(d.text.count, MotherOriginDisplay.rowCap)
        XCTAssertEqual(MotherOriginDisplay.rowCap, 40)
        XCTAssertTrue(d.text.hasSuffix("…"), d.text)
        XCTAssertTrue(d.text.hasPrefix("echo xxx"), d.text)
    }

    func testANameOfExactlyTheCapIsNotTruncated() {
        let name = String(repeating: "n", count: 40)
        let d = MotherOriginDisplay.make(annotation: annotation(.focus, tag: "t1"), currentName: names(["t1": name]))
        XCTAssertEqual(d.text, name)
    }

    func testAClosedFocusNameIsCappedBeforeClosedIsAppended() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", focusName: HostileContent.longCommand),
            currentName: noFocusOpen)
        XCTAssertTrue(d.text.hasSuffix(" (closed)"), "the closed marker is never cut off: \(d.text)")
        XCTAssertLessThanOrEqual(d.text.count, MotherOriginDisplay.rowCap + " (closed)".count)
    }

    func testAnUnverifiedNameIsCappedBeforeTheQuestionMark() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.unverified, tag: "t1", snapshot: HostileContent.longCommand),
            currentName: noFocusOpen)
        XCTAssertTrue(d.text.hasSuffix("?"), d.text)
        XCTAssertLessThanOrEqual(d.text.count, MotherOriginDisplay.rowCap + 1)
    }

    func testEveryTooltipLineIsCappedAndTheWholeTooltipIsBounded() {
        let long = HostileContent.longCommand
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: long, snapshot: long, focusName: "Other name", prefix: long),
            currentName: noFocusOpen)
        XCTAssertEqual(MotherOriginDisplay.tooltipCap, 120)
        for line in d.tooltip.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.count, MotherOriginDisplay.tooltipCap + "queued as ".count, "line is \(line.count) long")
        }
        XCTAssertLessThan(d.tooltip.count, 600, "a 10 KB name does not make a 10 KB tooltip")
        XCTAssertLessThan(d.accessibilityText.count, 100)
    }

    func testTheSessionPrefixIsShortenedToo() {
        let d = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "S", prefix: String(repeating: "f", count: 500)),
            currentName: names(["t1": "S"]))
        XCTAssertLessThan(d.tooltip.count, 200, d.tooltip)
    }

    // MARK: - Row model

    func testARowModelWithNoOriginKeepsTheOldBehaviour() {
        // iOS builds rows without an origin and must see no change.
        let row = MotherJobRowModel(id: "j1", state: "running", title: "Fix login", repo: "nostromo", branch: "main")
        XCTAssertNil(row.origin)
        XCTAssertEqual(row.accessibilitySummary, "Fix login")
        XCTAssertEqual(row, MotherJobRowModel(id: "j1", state: "running", title: "Fix login", repo: "nostromo", branch: "main"))
    }

    func testARowModelWithAnOriginSpeaksTheTitleThenFromTheOrigin() {
        let origin = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Fix login"),
            currentName: names(["t1": "Fix the login flow"]))
        let row = MotherJobRowModel(id: "j1", state: "running", title: "Ship it", origin: origin)
        XCTAssertEqual(row.origin, origin)
        XCTAssertEqual(row.accessibilitySummary, "Ship it. From Fix the login flow.")
    }

    func testARowModelSpeaksEachKindOfOrigin() {
        let cases: [(MotherJobAnnotation?, String)] = [
            (annotation(.you), "Job. From You."),
            (annotation(.unknown), "Job. From origin unknown."),
            (nil, "Job. From origin unknown."),
            (annotation(.unverified, tag: "t", snapshot: "Claimed"), "Job. From Claimed?, unverified."),
        ]
        for (note, expected) in cases {
            let origin = MotherOriginDisplay.make(annotation: note, currentName: noFocusOpen)
            XCTAssertEqual(MotherJobRowModel(id: "j", state: "queued", title: "Job", origin: origin).accessibilitySummary, expected)
        }
    }

    func testARowModelWithADifferentOriginIsNotEqual() {
        let a = MotherJobRowModel(id: "j", state: "queued", title: "t", origin: MotherOriginDisplay.make(annotation: annotation(.you), currentName: noFocusOpen))
        let b = MotherJobRowModel(id: "j", state: "queued", title: "t", origin: .unknown)
        XCTAssertNotEqual(a, b, "a row redraws when its origin changes (a rename)")
    }

    func testAHostileOriginNeverReachesTheRowsSpokenSummary() {
        for h in hostile {
            let origin = MotherOriginDisplay.make(
                annotation: annotation(.focus, tag: "t1", snapshot: h), currentName: names(["t1": h]))
            let summary = MotherJobRowModel(id: "j", state: "queued", title: "Job", origin: origin).accessibilitySummary
            assertClean(summary, "accessibilitySummary")
        }
    }

    // MARK: - VoiceOver decision (MF3-7)

    func testNoOriginMeansNoAccessibilityChange() {
        let row = MotherJobRowModel(id: "j", state: "queued", title: "Ship it")
        XCTAssertNil(OriginAccessibilityDecision.make(model: row, hasOriginTap: false))
        XCTAssertNil(OriginAccessibilityDecision.make(model: row, hasOriginTap: true))
    }

    func testAnOriginRowReadsTitleThenFromOrigin() {
        let origin = MotherOriginDisplay.make(annotation: annotation(.you), currentName: noFocusOpen)
        let row = MotherJobRowModel(id: "j", state: "queued", title: "Ship it", origin: origin)
        let d = OriginAccessibilityDecision.make(model: row, hasOriginTap: false)
        XCTAssertEqual(d?.label, "Ship it. From You.")
        XCTAssertNil(d?.actionName)
    }

    func testAClickableOriginIsANamedAction() {
        let origin = MotherOriginDisplay.make(
            annotation: annotation(.focus, tag: "t1", snapshot: "Fix login"), currentName: names(["t1": "Fix login"]))
        XCTAssertTrue(origin.isClickable)
        let row = MotherJobRowModel(id: "j", state: "queued", title: "Ship it", origin: origin)
        XCTAssertEqual(OriginAccessibilityDecision.make(model: row, hasOriginTap: true)?.actionName, "Show Fix login")
        XCTAssertNil(OriginAccessibilityDecision.make(model: row, hasOriginTap: false)?.actionName,
                     "no tap handler, no action")
    }

    func testANonClickableOriginHasNoAction() {
        let origin = MotherOriginDisplay.make(annotation: annotation(.focus, tag: "gone", snapshot: "Old"), currentName: noFocusOpen)
        XCTAssertFalse(origin.isClickable)
        let row = MotherJobRowModel(id: "j", state: "queued", title: "Ship it", origin: origin)
        XCTAssertNil(OriginAccessibilityDecision.make(model: row, hasOriginTap: true)?.actionName)
    }
}
