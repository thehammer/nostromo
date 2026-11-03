import XCTest
import AppKit
import Combine
import NostromoKit

// MotherQuotaStrip, MotherQuotaGateControl, MotherView and AppStore are compiled into this target directly.
//
// The Mother pane's quota strip, from outside:
//
//   - One compact row: the live windows (`5h 15% / 90 · resets 8:40 pm CT`, `7d 100% / 90 · paused · resets Thu 8 pm CT`;
//     over its cap with the gate off a window says `over cap, gate off`, as Mother is then holding nothing),
//     a gate badge and the three-option gate control. Zero height and hidden while the broker sends no quota
//     block (an older Mother) or the link is down.
//   - The badge is quiet when the gate is on and loud for BOTH off states ("Gate OFF", "Gate off until reset
//     (resets <time>)"). A stale feed, an over-cap window and an invalid cap are said in words; the notes
//     (refusal, stale feed, invalid cap) are in the warning colour. A stale feed with the gate on says Mother
//     is not limiting work.
//   - The strip shows what the broker reported and nothing else: a refused command shows its error and does not
//     change the gate; an ack changes the gate only to what the ack's own block says.
//   - A block that says nothing new moves nothing (no re-render, so no layout churn).
//   - At a narrow width the label gives way; the badge and the control stay on the row.
//
// No wall clock, no broker: the strip is given `now` and a fixed zone, and driven through `apply` (or through
// `AppStore.shared` for the wiring tests). The window is offscreen.

// MARK: - Fixtures

/// 2026-11-02 19:11:00 UTC: 1:11 pm in Chicago, the fixture snapshot's own time.
private let stripNow = Date(timeIntervalSince1970: 1_793_646_660)
private let stripZone = TimeZone(identifier: "America/Chicago")!

private func epoch(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// The golden fixture's shape: 5h at 23% (resets 4:30 pm today), 7d at 100% of a 90 cap (resets Thu 8 pm).
func qsQuota(gate: MotherQuotaGate = .on, until: TimeInterval? = nil, stale: Bool = false, feedAge: Int? = 42,
             capInvalid: Bool = false, fiveUsed: Double = 23, sevenUsed: Double = 100,
             windows: Bool = true) -> MotherQuota {
    MotherQuota(
        gate: gate, until: until.map(epoch), changedAt: "2026-11-02T19:10:13.486Z", changedBy: "broker:nostromo",
        source: stale ? .none : .bishop, feedAgeSeconds: feedAge, stale: stale, capInvalid: capInvalid,
        fiveHour: windows ? MotherQuotaWindow(usedPct: fiveUsed, capPct: 90, resetsAt: epoch(1_793_658_600)) : nil,
        sevenDay: windows ? MotherQuotaWindow(usedPct: sevenUsed, capPct: 90, resetsAt: epoch(1_793_930_400)) : nil)
}

/// Mother's golden fixture, read from the repo.
enum QuotaFixture {
    static let url: URL = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/mother-contract/quota_block.json")

    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The fixture's `quota_block`.
    static func block() throws -> [String: Any] {
        try XCTUnwrap(try root()["quota_block"] as? [String: Any])
    }

    /// The fixture's block with `edit` applied.
    static func block(_ edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var object = try block()
        edit(&object)
        return object
    }

    /// A named entry of `command_envelopes`.
    static func envelope(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(try root()["command_envelopes"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], name)
    }
}

// MARK: - Rig

/// One strip in an offscreen window of a given width, its control adopted from a gesture harness (so a test can
/// click it), a fixed clock and zone.
private final class QSRig {
    let h: QGHarness
    let strip: MotherQuotaStrip

    init(_ testCase: XCTestCase, width: CGFloat = 800) {
        h = QGHarness(testCase, hostControl: false)
        strip = MotherQuotaStrip(control: h.control, observeStore: false)
        strip.now = { stripNow }
        strip.timeZone = stripZone
        h.window.setContentSize(NSSize(width: width, height: 120))
        let content = h.window.contentView!
        strip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        layout()
    }

    var control: MotherQuotaGateControl { h.control }

    func layout() { h.window.contentView?.layoutSubtreeIfNeeded() }

    func apply(_ quota: MotherQuota?, inFlight: Bool = false, error: String? = nil) {
        strip.apply(quota: quota, inFlight: inFlight, error: error)
        layout()
    }

    /// `view`'s frame in the strip's own coordinates.
    func frame(of view: NSView) -> NSRect { strip.convert(view.bounds, from: view) }

    var shownHeight: CGFloat { strip.frame.height }
}

// MARK: - The strip

final class MotherQuotaStripTests: MouseQueueTestCase {

    // MARK: Hidden without a quota block

    func testTheStripHasNoHeightBeforeAnyQuotaArrives() {
        let rig = QSRig(self)
        XCTAssertEqual(rig.shownHeight, 0)
    }

    func testTheStripIsHiddenWithZeroHeightWhenMotherSendsNoQuotaBlock() {
        let rig = QSRig(self)
        rig.apply(nil)

        XCTAssertFalse(rig.strip.isShown, "an older Mother: nothing to show")
        XCTAssertEqual(rig.shownHeight, 0)
        XCTAssertTrue(rig.control.isHiddenOrHasHiddenAncestor, "and no control to press")
    }

    func testTheStripAppearsWithItsOneRowHeightAndGoesAgainWhenTheBlockGoes() {
        let rig = QSRig(self)
        rig.apply(qsQuota())
        XCTAssertTrue(rig.strip.isShown)
        XCTAssertEqual(rig.shownHeight, MotherQuotaStrip.visibleHeight)
        XCTAssertFalse(rig.control.isHiddenOrHasHiddenAncestor)

        rig.apply(nil)   // the link dropped, or Mother restarted as an older build
        XCTAssertFalse(rig.strip.isShown)
        XCTAssertEqual(rig.shownHeight, 0)
        XCTAssertTrue(rig.control.isHiddenOrHasHiddenAncestor)

        rig.apply(qsQuota())
        XCTAssertEqual(rig.shownHeight, MotherQuotaStrip.visibleHeight, "and it comes back")
    }

    func testAnArmedControlIsDisarmedWhenTheStripGoesAway() {
        let rig = QSRig(self)
        rig.apply(qsQuota())
        rig.h.click(.off, at: 0)
        XCTAssertEqual(rig.control.armed, .off)

        rig.apply(nil)

        XCTAssertNil(rig.control.armed, "a hidden control must not stay armed")
        XCTAssertTrue(rig.h.sent.isEmpty)
    }

    // MARK: The badge

    func testTheBadgeIsQuietWhenOnAndNamesBothOffStatesLoudly() {
        let rig = QSRig(self)

        rig.apply(qsQuota(gate: .on))
        XCTAssertEqual(rig.strip.badgeText, "Gate on")
        XCTAssertFalse(rig.strip.isOffBadge)
        XCTAssertEqual(rig.strip.badge.layer?.backgroundColor?.alpha ?? 0, 0, "the quiet badge has no fill")

        rig.apply(qsQuota(gate: .off))
        XCTAssertEqual(rig.strip.badgeText, "Gate OFF")
        XCTAssertTrue(rig.strip.isOffBadge)
        XCTAssertGreaterThan(rig.strip.badge.layer?.backgroundColor?.alpha ?? 0, 0, "the loud badge is filled")

        rig.apply(qsQuota(gate: .offUntilReset, until: 1_793_658_600))
        XCTAssertEqual(rig.strip.badgeText, "Gate off until reset (resets 4:30 pm CT)")
        XCTAssertTrue(rig.strip.isOffBadge)
        XCTAssertGreaterThan(rig.strip.badge.layer?.backgroundColor?.alpha ?? 0, 0)

        rig.apply(qsQuota(gate: .on))
        XCTAssertEqual(rig.strip.badgeText, "Gate on", "back to quiet when the gate goes on again")
        XCTAssertEqual(rig.strip.badge.layer?.backgroundColor?.alpha ?? 0, 0)
    }

    func testTheBadgeIsVisibleForEveryGateState() {
        let rig = QSRig(self)
        for quota in [qsQuota(gate: .on), qsQuota(gate: .off), qsQuota(gate: .offUntilReset, until: 1_793_658_600),
                      qsQuota(gate: .unknown("future"))] {
            rig.apply(quota)
            XCTAssertFalse(rig.strip.badge.isHiddenOrHasHiddenAncestor, "\(quota.gate)")
            XCTAssertFalse(rig.strip.badgeText.isEmpty, "\(quota.gate)")
            XCTAssertGreaterThan(rig.frame(of: rig.strip.badge).width, 0, "\(quota.gate)")
        }
    }

    func testAnUnknownGateSaysSoAndDisablesTheControl() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .unknown("paused_for_review")))

        XCTAssertEqual(rig.strip.badgeText, "Gate unknown")
        XCTAssertFalse(rig.strip.isOffBadge, "an unknown state is not claimed to be off")
        for request in [MotherQuotaGateRequest.on, .off, .offUntilReset] {
            XCTAssertFalse(rig.control.button(for: request).isEnabled, "\(request)")
        }
        XCTAssertTrue(rig.strip.isShown, "the windows still show")
    }

    func testTheControlMarksTheGateTheBrokerReports() {
        let rig = QSRig(self)
        let selected: (MotherQuotaGateRequest) -> Bool = {
            (rig.control.button(for: $0).accessibilityValue() as? String) == "selected"
        }
        for (gate, request) in [(MotherQuotaGate.on, MotherQuotaGateRequest.on), (.off, .off),
                                (.offUntilReset, .offUntilReset)] {
            rig.apply(qsQuota(gate: gate, until: gate == .offUntilReset ? 1_793_658_600 : nil))
            for other in [MotherQuotaGateRequest.on, .off, .offUntilReset] {
                XCTAssertEqual(selected(other), other == request, "\(other) while the gate is \(gate)")
            }
        }
    }

    // MARK: The words

    func testTheLabelShowsBothWindowsAsTheFixtureReportsThem() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .offUntilReset, until: 1_793_658_600))

        let text = rig.strip.labelText
        let five = text.range(of: "5h 23% / 90 · resets 4:30 pm CT")
        let seven = text.range(of: "7d 100% / 90 · over cap, gate off · resets Thu 8 pm CT")
        XCTAssertNotNil(five, text)
        XCTAssertNotNil(seven, text)
        if let five, let seven { XCTAssertLessThan(five.lowerBound, seven.lowerBound, "5h first, then 7d") }
    }

    func testAnOverCapWindowSaysPausedWhileTheGateIsOnAndOverCapGateOffWhenItIsOff() {
        let rig = QSRig(self)

        rig.apply(qsQuota(gate: .on))
        XCTAssertTrue(rig.strip.labelText.contains("7d 100% / 90 · paused · resets Thu 8 pm CT"), rig.strip.labelText)
        XCTAssertFalse(rig.strip.labelText.contains("gate off"), "Mother is holding the work: say so")

        for gate in [MotherQuotaGate.off, .offUntilReset] {
            rig.apply(qsQuota(gate: gate, until: gate == .offUntilReset ? 1_793_658_600 : nil))
            XCTAssertTrue(rig.strip.labelText.contains("7d 100% / 90 · over cap, gate off · resets Thu 8 pm CT"),
                          "\(gate): \(rig.strip.labelText)")
            XCTAssertFalse(rig.strip.labelText.contains("paused"), "\(gate): nothing is paused with the gate off")
        }
    }

    func testResetTimesCarryTheirZoneInCentralTimeWhateverTheMachinesZone() {
        let rig = QSRig(self)
        rig.apply(qsQuota())
        XCTAssertTrue(rig.strip.labelText.contains("resets 4:30 pm CT"), rig.strip.labelText)
        XCTAssertTrue(rig.strip.labelText.contains("resets Thu 8 pm CT"), rig.strip.labelText)

        // A strip nobody configured shows Central time, not the machine's.
        let plain = MotherQuotaStrip(control: nil, observeStore: false)
        XCTAssertEqual(plain.timeZone.identifier, "America/Chicago")
    }

    func testOnlyAnOverCapWindowSaysPaused() {
        let rig = QSRig(self)
        rig.apply(qsQuota(fiveUsed: 20, sevenUsed: 40))
        XCTAssertFalse(rig.strip.labelText.contains("paused"))

        rig.apply(qsQuota(fiveUsed: 95, sevenUsed: 40))
        XCTAssertTrue(rig.strip.labelText.contains("5h 95% / 90 · paused"), rig.strip.labelText)
        XCTAssertFalse(rig.strip.labelText.contains("7d 40% / 90 · paused"))

        rig.apply(qsQuota(fiveUsed: 20, sevenUsed: 90))
        XCTAssertTrue(rig.strip.labelText.contains("7d 90% / 90 · paused"), "at the cap counts as over")
    }

    func testAStaleFeedIsSaidInWordsWithItsAge() {
        let rig = QSRig(self)
        rig.apply(qsQuota(stale: true, feedAge: 725))
        XCTAssertTrue(rig.strip.labelText.contains("Quota feed stale (12m)"), rig.strip.labelText)

        rig.apply(qsQuota(stale: true, feedAge: nil))
        XCTAssertTrue(rig.strip.labelText.contains("Quota feed stale"), rig.strip.labelText)

        rig.apply(qsQuota(stale: false, feedAge: 725))
        XCTAssertFalse(rig.strip.labelText.contains("stale"), "a fresh feed says nothing")
    }

    func testAnInvalidCapIsNoted() {
        let rig = QSRig(self)
        rig.apply(qsQuota(capInvalid: true))
        XCTAssertTrue(rig.strip.labelText.contains("cap invalid, using 90"), rig.strip.labelText)

        rig.apply(qsQuota(capInvalid: false))
        XCTAssertFalse(rig.strip.labelText.contains("cap invalid"))
    }

    /// The foreground colour of the first run of the label's attributed text that contains `needle`.
    private func colour(of needle: String, in label: NSTextField, file: StaticString = #filePath,
                        line: UInt = #line) -> NSColor? {
        let text = label.attributedStringValue
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else {
            XCTFail("\"\(needle)\" is not in the label: \(text.string)", file: file, line: line)
            return nil
        }
        return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private func sameColour(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.005 && abs(a.greenComponent - b.greenComponent) < 0.005
            && abs(a.blueComponent - b.blueComponent) < 0.005
    }

    func testAnInvalidCapNoteIsInTheWarningColour() {
        let rig = QSRig(self)
        rig.apply(qsQuota(capInvalid: true))

        XCTAssertTrue(sameColour(colour(of: "cap invalid, using 90", in: rig.strip.label), Theme.amber),
                      "an invalid cap changes what the gate holds: it is a warning, not a footnote")
        XCTAssertFalse(sameColour(colour(of: "5h 23%", in: rig.strip.label), Theme.amber),
                       "an ordinary window is not in the warning colour (so the check above means something)")
    }

    func testTheStaleAndRefusalNotesAreInTheWarningColourToo() {
        let rig = QSRig(self)
        rig.apply(qsQuota(stale: true, feedAge: 725), error: "Couldn't change the gate: Mother failed to apply it.")

        XCTAssertTrue(sameColour(colour(of: "Quota feed stale", in: rig.strip.label), Theme.amber))
        XCTAssertTrue(sameColour(colour(of: "Couldn't change the gate", in: rig.strip.label), Theme.amber))
    }

    func testAStaleFeedWithTheGateOnSaysMotherIsNotLimitingWork() {
        let rig = QSRig(self)

        rig.apply(qsQuota(gate: .on, stale: true, feedAge: 725))
        XCTAssertEqual(rig.strip.badgeText, "Gate on, feed stale: Mother is not limiting work")
        XCTAssertFalse(rig.strip.isOffBadge, "the gate is on; only its feed is not to be trusted")
        XCTAssertTrue(rig.strip.spokenSummary.contains("not limiting work"), rig.strip.spokenSummary)
        XCTAssertFalse(rig.strip.spokenSummary.contains("holds work"), rig.strip.spokenSummary)

        rig.apply(qsQuota(gate: .on, stale: false))
        XCTAssertEqual(rig.strip.badgeText, "Gate on")
        XCTAssertTrue(rig.strip.spokenSummary.contains("holds work"), rig.strip.spokenSummary)

        rig.apply(qsQuota(gate: .off, stale: true, feedAge: 725))
        XCTAssertEqual(rig.strip.badgeText, "Gate OFF", "an off gate says what it is, stale or not")
    }

    func testAHostileQuotaBlockStillRendersAndTheControlStillWorks() throws {
        // Wire numbers a broker should never send: huge, an integer past Int64, negative, a string.
        let json = """
        {"gate":"on","stale":true,"feed_age_s":100000000000000000000000,
         "windows":{"five_hour":{"used_pct":1e30,"cap_pct":90,"resets_at":1e30},
                    "seven_day":{"used_pct":-5,"cap_pct":"Infinity","resets_at":-1}}}
        """
        let quota = try XCTUnwrap(MotherQuota.decode(json: Data(json.utf8)), "the block still decodes")
        XCTAssertNil(quota.fiveHour)
        XCTAssertNil(quota.sevenDay)

        let rig = QSRig(self)
        rig.apply(quota)

        XCTAssertTrue(rig.strip.isShown)
        XCTAssertEqual(rig.shownHeight, MotherQuotaStrip.visibleHeight)
        XCTAssertFalse(rig.strip.labelText.contains("5h"))
        XCTAssertFalse(rig.strip.labelText.contains("7d"))
        XCTAssertTrue(rig.strip.labelText.contains("Quota feed stale"), "with no usable age, just stale")
        XCTAssertEqual(rig.strip.badgeText, "Gate on, feed stale: Mother is not limiting work")
        for request in [MotherQuotaGateRequest.on, .off, .offUntilReset] {
            XCTAssertEqual(rig.control.button(for: request).isEnabled, true, "\(request)")
        }
        rig.h.click(.off, at: 0)
        XCTAssertEqual(rig.control.armed, .off, "the control works")
        rig.h.click(.off, at: 0.6)
        XCTAssertEqual(rig.h.sent, [.off])
    }

    func testAnEnormousButValidPercentageRendersWithoutTrapping() {
        let rig = QSRig(self)
        let quota = MotherQuota(gate: .on, stale: false,
                                fiveHour: MotherQuotaWindow(usedPct: 1e14, capPct: 90, resetsAt: nil),
                                sevenDay: MotherQuotaWindow(usedPct: 1e300, capPct: 90, resetsAt: epoch(1e12)))
        rig.apply(quota)

        XCTAssertTrue(rig.strip.isShown)
        XCTAssertTrue(rig.strip.labelText.contains("5h"), rig.strip.labelText)
        XCTAssertTrue(rig.strip.labelText.contains("7d"), rig.strip.labelText)
        XCTAssertTrue(rig.strip.labelText.contains("paused"), rig.strip.labelText)
    }

    func testABlockWithNoWindowsStillShowsTheGate() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .off, windows: false))

        XCTAssertTrue(rig.strip.isShown)
        XCTAssertEqual(rig.strip.badgeText, "Gate OFF")
        XCTAssertFalse(rig.strip.labelText.contains("5h"))
        XCTAssertFalse(rig.strip.labelText.contains("7d"))
    }

    func testTheSpokenSummaryCarriesTheWindowsAndTheGateInWords() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .off))

        let spoken = rig.strip.spokenSummary
        XCTAssertTrue(spoken.contains("5h 23% / 90"), spoken)
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("quota gate off"), spoken)
        XCTAssertEqual(rig.strip.badge.accessibilityLabel()?.hasPrefix("Warning"), true,
                       "an OFF gate is announced as a warning")
    }

    // MARK: Arming is visible

    func testTheStripAsksForTheConfirmingClickWhileTheControlIsArmedAndDropsTheQuestionWhenItEnds() {
        let rig = QSRig(self)
        rig.apply(qsQuota())

        rig.h.click(.off, at: 0)
        XCTAssertTrue(rig.strip.labelText.contains("Turn gate off? Click again to confirm"), rig.strip.labelText)
        XCTAssertFalse(rig.strip.labelText.contains("5h 23%"), "the question takes the row; the windows give way")

        rig.h.schedule.fireAll()   // the arm expired
        XCTAssertFalse(rig.strip.labelText.contains("Click again"), rig.strip.labelText)
        XCTAssertTrue(rig.strip.labelText.contains("5h 23% / 90"), "the windows are back")
        XCTAssertTrue(rig.h.sent.isEmpty)
    }

    func testTheQuestionGoesWhenTheRequestIsConfirmed() {
        let rig = QSRig(self)
        rig.apply(qsQuota())
        rig.h.click(.offUntilReset, at: 0)
        XCTAssertTrue(rig.strip.labelText.contains("Click again to confirm"))

        rig.h.click(.offUntilReset, at: 0.6)

        XCTAssertEqual(rig.h.sent, [.offUntilReset])
        XCTAssertFalse(rig.strip.labelText.contains("Click again"), rig.strip.labelText)
    }

    // MARK: A refusal changes nothing

    func testABrokerRefusalShowsItsMessageAndLeavesTheDisplayedGateAlone() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on))
        let message = "Couldn't change the gate: Mother is busy, try again."

        rig.apply(qsQuota(gate: .on), inFlight: false, error: message)

        XCTAssertTrue(rig.strip.labelText.contains(message), rig.strip.labelText)
        XCTAssertEqual(rig.strip.badgeText, "Gate on", "the badge still says what the broker said")
        XCTAssertFalse(rig.strip.isOffBadge)
        XCTAssertEqual(rig.control.gate, .on, "and so does the control")
        XCTAssertEqual(rig.control.button(for: .on).accessibilityValue() as? String, "selected")
        XCTAssertEqual(rig.control.button(for: .off).accessibilityValue() as? String, "not selected")
        XCTAssertTrue(rig.strip.labelText.contains("5h 23% / 90"), "the windows are still there")

        rig.apply(qsQuota(gate: .on), inFlight: false, error: nil)
        XCTAssertFalse(rig.strip.labelText.contains("Couldn't change"), "the message goes with the next attempt")
    }

    func testTheControlIsDisabledWhileACommandIsInFlightAndWorksAgainAfter() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on), inFlight: true)
        for request in [MotherQuotaGateRequest.on, .off, .offUntilReset] {
            XCTAssertFalse(rig.control.button(for: request).isEnabled, "\(request)")
        }

        rig.apply(qsQuota(gate: .on), inFlight: false)
        for request in [MotherQuotaGateRequest.on, .off, .offUntilReset] {
            XCTAssertTrue(rig.control.button(for: request).isEnabled, "\(request)")
        }
    }

    // MARK: No churn

    /// Black box: a stand-in value is left in the label's and the badge's tooltips; a render would overwrite them.
    func testABlockThatSaysNothingNewIsNotRenderedAgain() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .off, feedAge: 42))
        rig.strip.label.toolTip = "untouched"
        rig.strip.badge.toolTip = "untouched"

        rig.apply(qsQuota(gate: .off, feedAge: 42))
        XCTAssertEqual(rig.strip.label.toolTip, "untouched", "an identical block re-renders nothing")
        XCTAssertEqual(rig.strip.badge.toolTip, "untouched")

        rig.apply(qsQuota(gate: .off, feedAge: 47))   // the feed got older by seconds: nothing on the row differs
        XCTAssertEqual(rig.strip.label.toolTip, "untouched", "a feed age that is not shown does not re-render")
        XCTAssertEqual(rig.strip.badge.toolTip, "untouched")
    }

    func testAChangeTheStripShowsIsRendered() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on, fiveUsed: 23))
        rig.strip.label.toolTip = "untouched"
        rig.strip.badge.toolTip = "untouched"

        rig.apply(qsQuota(gate: .on, fiveUsed: 24))
        XCTAssertNotEqual(rig.strip.label.toolTip, "untouched", "a window percentage moved")
        XCTAssertTrue(rig.strip.labelText.contains("5h 24%"))

        rig.strip.badge.toolTip = "untouched"
        rig.apply(qsQuota(gate: .off, fiveUsed: 24))
        XCTAssertNotEqual(rig.strip.badge.toolTip, "untouched", "the gate moved")
        XCTAssertEqual(rig.strip.badgeText, "Gate OFF")
    }

    func testAStaleFeedsAgeIsShownSoItsChangeIsRendered() {
        let rig = QSRig(self)
        rig.apply(qsQuota(stale: true, feedAge: 600))
        XCTAssertTrue(rig.strip.labelText.contains("(10m)"))
        rig.apply(qsQuota(stale: true, feedAge: 660))
        XCTAssertTrue(rig.strip.labelText.contains("(11m)"))
    }

    func testAnIdenticalBlockDoesNotEndAnArm() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on))
        rig.h.click(.off, at: 0)

        rig.apply(qsQuota(gate: .on))   // the broker re-sent the same state
        rig.apply(qsQuota(gate: .on, feedAge: 50))

        XCTAssertEqual(rig.control.armed, .off)
        XCTAssertTrue(rig.strip.labelText.contains("Click again to confirm"))
    }

    func testABlockWithADifferentUntilEndsAnArmAndTheNextClickOnlyArmsAgain() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on))
        rig.h.click(.offUntilReset, at: 0)
        XCTAssertEqual(rig.control.armed, .offUntilReset)

        // The reset the arm was for moved: "off until reset" now means a different time.
        rig.apply(qsQuota(gate: .on, until: 1_793_700_000))

        XCTAssertNil(rig.control.armed)
        XCTAssertFalse(rig.strip.labelText.contains("Click again"), rig.strip.labelText)
        rig.h.click(.offUntilReset, at: 0.6)
        XCTAssertTrue(rig.h.sent.isEmpty, "the click after the change does not confirm the old arm")
        XCTAssertEqual(rig.control.armed, .offUntilReset)
    }

    func testABlockWhoseWindowResetTimeDiffersEndsAnArm() {
        for window in ["fiveHour", "sevenDay"] {
            let rig = QSRig(self)
            rig.apply(qsQuota(gate: .on))
            rig.h.click(.off, at: 0)
            XCTAssertEqual(rig.control.armed, .off, window)

            var moved = qsQuota(gate: .on)
            if window == "fiveHour" { moved.fiveHour?.resetsAt = epoch(1_793_700_000) }
            else { moved.sevenDay?.resetsAt = epoch(1_793_900_000) }
            rig.apply(moved)

            XCTAssertNil(rig.control.armed, "\(window): its reset time changed")
            rig.h.click(.off, at: 0.6)
            XCTAssertTrue(rig.h.sent.isEmpty, window)
            XCTAssertEqual(rig.control.armed, .off, window)
        }
    }

    func testABlockWhoseGateChangedEndsAnArmThroughTheStrip() {
        let rig = QSRig(self)
        rig.apply(qsQuota(gate: .on))
        rig.h.click(.off, at: 0)

        rig.apply(qsQuota(gate: .offUntilReset, until: 1_793_658_600))

        XCTAssertNil(rig.control.armed)
        rig.h.click(.off, at: 0.6)
        XCTAssertTrue(rig.h.sent.isEmpty)
    }

    // MARK: Narrow width

    private func assertOnTheRow(_ rig: QSRig, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = rig.strip.bounds
        let badge = rig.frame(of: rig.strip.badge)
        let control = rig.frame(of: rig.control)
        let label = rig.frame(of: rig.strip.label)

        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(badge), "\(what): the badge is on the row: \(badge) in \(bounds)", file: file, line: line)
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(control), "\(what): the control is on the row: \(control) in \(bounds)", file: file, line: line)
        XCTAssertGreaterThan(badge.width, 40, "\(what): the badge is not collapsed", file: file, line: line)
        XCTAssertGreaterThan(control.width, 40, "\(what): the control is not collapsed", file: file, line: line)
        XCTAssertGreaterThan(control.height, 8, "\(what)", file: file, line: line)
        XCTAssertLessThanOrEqual(label.maxX, badge.minX + 0.5, "\(what): the label does not run under the badge", file: file, line: line)
        XCTAssertLessThanOrEqual(badge.maxX, control.minX + 0.5, "\(what): the badge does not run under the control", file: file, line: line)
        XCTAssertEqual(rig.shownHeight, MotherQuotaStrip.visibleHeight, "\(what): one row", file: file, line: line)
    }

    /// A row with a long label: notes first, then both windows; the gate off until reset.
    private func busyQuota(gate: MotherQuotaGate = .offUntilReset) -> MotherQuota {
        qsQuota(gate: gate, until: gate == .offUntilReset ? 1_793_658_600 : nil, stale: true, feedAge: 725,
                capInvalid: true)
    }

    func testAtANarrowWidthTheLabelTruncatesAndTheBadgeAndControlStayOnTheRow() {
        for gate in [MotherQuotaGate.off, .offUntilReset, .on] {
            let rig = QSRig(self, width: 320)
            rig.apply(busyQuota(gate: gate))

            assertOnTheRow(rig, "320 pt, \(gate)")
            let label = rig.frame(of: rig.strip.label)
            XCTAssertLessThan(label.width, rig.strip.label.intrinsicContentSize.width,
                              "320 pt, \(gate): the label gives way, it does not push")
            XCTAssertEqual(rig.strip.label.lineBreakMode, .byTruncatingTail)
        }
    }

    func testAtANarrowWidthTheShortBadgeAndTheControlKeepTheirFullWidth() {
        let rig = QSRig(self, width: 320)
        rig.apply(busyQuota(gate: .off))

        XCTAssertGreaterThanOrEqual(rig.frame(of: rig.strip.badge).width, rig.strip.badge.intrinsicContentSize.width - 1,
                                    "\"Gate OFF\" is read in full")
        XCTAssertGreaterThanOrEqual(rig.frame(of: rig.control).width, rig.control.fittingSize.width - 1,
                                    "the three options are all there")
    }

    func testAtANarrowWidthTheControlKeepsItsFullWidthEvenWithTheLongestBadge() {
        let rig = QSRig(self, width: 320)
        rig.apply(busyQuota(gate: .offUntilReset))

        XCTAssertGreaterThanOrEqual(rig.frame(of: rig.control).width, rig.control.fittingSize.width - 1)
    }

    func testAtAWideWidthNothingIsTruncated() {
        let rig = QSRig(self, width: 1_400)
        rig.apply(busyQuota())

        assertOnTheRow(rig, "1400 pt")
        XCTAssertGreaterThanOrEqual(rig.frame(of: rig.strip.label).width, rig.strip.label.intrinsicContentSize.width - 1)
        XCTAssertGreaterThanOrEqual(rig.frame(of: rig.strip.badge).width, rig.strip.badge.intrinsicContentSize.width - 1)
    }

    func testTheRowStaysOnScreenAsTheWindowIsResizedAcrossWidths() {
        let rig = QSRig(self, width: 900)
        rig.apply(busyQuota())
        for width: CGFloat in [900, 500, 320, 700, 1_200, 320] {
            rig.h.window.setContentSize(NSSize(width: width, height: 120))
            rig.layout()
            assertOnTheRow(rig, "\(width) pt")
        }
    }
}

// MARK: - The store and the wiring

/// `AppStore.shared` is the app's one store; each test starts and ends with a store that holds no quota.
final class MotherQuotaStoreTests: MouseQueueTestCase {

    private var store: AppStore { AppStore.shared }

    override func setUp() {
        super.setUp()
        store.applyBrokerEventForTesting(.reconnected)
        addTeardownBlock { AppStore.shared.applyBrokerEventForTesting(.reconnected) }
    }

    /// A `QuotaGateConfirmation` the only way a test can get one: from the control, after its gesture steps.
    private func mintConfirmation() throws -> QuotaGateConfirmation {
        let h = QGHarness(self)
        h.click(.off, at: 0)
        h.click(.off, at: 0.5)
        return try XCTUnwrap(h.confirmations.first, "the control did not mint a confirmation")
    }

    // MARK: Events

    func testAQuotaEventSetsTheQuotaTheStoreHolds() {
        XCTAssertNil(store.motherQuota)
        let quota = qsQuota(gate: .off)

        store.applyBrokerEventForTesting(.quota(quota))

        XCTAssertEqual(store.motherQuota, quota)
    }

    func testANewerQuotaEventReplacesAndAnAbsentOneClears() {
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .offUntilReset, until: 1_793_658_600)))
        XCTAssertEqual(store.motherQuota?.gate, .offUntilReset)

        store.applyBrokerEventForTesting(.quota(nil))   // a snapshot from a Mother with no quota block
        XCTAssertNil(store.motherQuota, "an older Mother has no quota status to show")
    }

    func testAReconnectClearsTheQuotaSoNoStaleGateIsShown() {
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .off)))
        store.applyBrokerEventForTesting(.reconnected)
        XCTAssertNil(store.motherQuota)
    }

    func testAJobSnapshotDoesNotTouchTheQuota() {
        let quota = qsQuota(gate: .off)
        store.applyBrokerEventForTesting(.quota(quota))
        store.applyBrokerEventForTesting(.snapshot([]))
        XCTAssertEqual(store.motherQuota, quota, "the quota arrives as its own event")
    }

    func testAnUnchangedBlockDoesNotRepublish() {
        var seen: [MotherQuota?] = []
        let sub = store.$motherQuota.sink { seen.append($0) }
        defer { sub.cancel() }
        XCTAssertEqual(seen.count, 1, "the initial value")

        let quota = qsQuota(gate: .on)
        store.applyBrokerEventForTesting(.quota(quota))
        XCTAssertEqual(seen.count, 2)
        store.applyBrokerEventForTesting(.quota(quota))
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))
        XCTAssertEqual(seen.count, 2, "the same block again is not a change")

        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .off)))
        XCTAssertEqual(seen.count, 3, "a different block is")

        store.applyBrokerEventForTesting(.quota(nil))
        store.applyBrokerEventForTesting(.quota(nil))
        XCTAssertEqual(seen.count, 4, "and no block twice is one change")
    }

    // MARK: Acks

    func testASuccessfulAckChangesTheStateToWhatItsBlockSays() {
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))

        store.applyQuotaGateResult(.success(qsQuota(gate: .off)))

        XCTAssertEqual(store.motherQuota?.gate, .off)
        XCTAssertFalse(store.motherQuotaGateInFlight)
        XCTAssertNil(store.motherQuotaGateError)
    }

    func testTheAckIsTheBrokersReadBackNotAnEchoOfTheRequest() {
        // The control asked for `off until reset`; the broker says the gate is `off` (it cleared the until).
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))
        store.applyQuotaGateResult(.success(qsQuota(gate: .off)))
        XCTAssertEqual(store.motherQuota?.gate, .off, "what the broker reported, whatever was asked")
    }

    func testAnAckWithNoBlockLeavesTheStateAsItWas() {
        let quota = qsQuota(gate: .on)
        store.applyBrokerEventForTesting(.quota(quota))

        store.applyQuotaGateResult(.success(nil))

        XCTAssertEqual(store.motherQuota, quota)
        XCTAssertFalse(store.motherQuotaGateInFlight)
    }

    func testARefusedCommandShowsItsErrorAndLeavesTheStateAlone() {
        let quota = qsQuota(gate: .on)
        store.applyBrokerEventForTesting(.quota(quota))

        store.applyQuotaGateResult(.failure(.code(.malformed, message: "quota-gate: state must be one of on, off, off_until_reset")))

        XCTAssertEqual(store.motherQuota, quota, "a refusal never changes the gate")
        XCTAssertFalse(store.motherQuotaGateInFlight)
        let error = store.motherQuotaGateError ?? ""
        XCTAssertTrue(error.hasPrefix("Couldn't change the gate"), error)
    }

    func testEveryKindOfFailureIsShownAndNoneChangesTheState() {
        let quota = qsQuota(gate: .off)
        store.applyBrokerEventForTesting(.quota(quota))
        let failures: [BrokerError] = [.timeout, .disconnected, .code(.unavailable, message: "busy"),
                                       .code(.unauthorized, message: "no"), .code(.internal, message: "boom")]
        for failure in failures {
            store.applyQuotaGateResult(.failure(failure))
            XCTAssertEqual(store.motherQuota, quota, "\(failure)")
            XCTAssertNotNil(store.motherQuotaGateError, "\(failure)")
        }
    }

    func testNoResetKnownTellsTheOperatorWhatToDoInstead() {
        let quota = qsQuota(gate: .on)
        store.applyBrokerEventForTesting(.quota(quota))

        store.applyQuotaGateResult(.failure(.code(.noResetKnown, message: "no reset known")))

        let error = store.motherQuotaGateError ?? ""
        XCTAssertTrue(error.hasPrefix("Couldn't change the gate"), error)
        XCTAssertTrue(error.contains("No reset time is known yet; use Off, or try again when the feed is live"), error)
        XCTAssertEqual(store.motherQuota, quota, "a refusal never changes the gate")
        XCTAssertFalse(store.motherQuotaGateInFlight)
    }

    func testAnErrorCodeThisBuildDoesNotKnowIsShownAsItsCodeNotAsAnInternalFailure() {
        store.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))

        store.applyQuotaGateResult(.failure(.unknownCode("weird_code")))

        let error = store.motherQuotaGateError ?? ""
        XCTAssertTrue(error.hasPrefix("Couldn't change the gate"), error)
        XCTAssertTrue(error.contains("weird_code"), error)
        XCTAssertFalse(error.contains("failed to apply"), "an unknown code is not an internal error: \(error)")
        XCTAssertEqual(store.motherQuota?.gate, .on)

        // And a genuine internal error still says so.
        store.applyQuotaGateResult(.failure(.code(.internal, message: "boom")))
        XCTAssertTrue((store.motherQuotaGateError ?? "").contains("failed to apply"), store.motherQuotaGateError ?? "")
    }

    func testASuccessClearsEarlierErrorsAndAReconnectClearsThem() {
        store.applyQuotaGateResult(.failure(.timeout))
        XCTAssertNotNil(store.motherQuotaGateError)
        store.applyQuotaGateResult(.success(qsQuota(gate: .on)))
        XCTAssertNil(store.motherQuotaGateError)

        store.applyQuotaGateResult(.failure(.timeout))
        store.applyBrokerEventForTesting(.reconnected)
        XCTAssertNil(store.motherQuotaGateError)
    }

    func testARequestToAMotherWithNoGateSwitchShowsAnErrorAndChangesNothing() throws {
        let quota = qsQuota(gate: .on)
        store.applyBrokerEventForTesting(.quota(quota))
        let confirmation = try mintConfirmation()

        // The shared store's broker is not connected here, so it advertises no `quota-gate`.
        store.requestQuotaGate(.off, confirmation: confirmation)

        XCTAssertEqual(store.motherQuota, quota)
        XCTAssertFalse(store.motherQuotaGateInFlight, "nothing is waiting for an ack that cannot come")
        XCTAssertTrue((store.motherQuotaGateError ?? "").hasPrefix("Couldn't change the gate"),
                      store.motherQuotaGateError ?? "no error shown")
    }
}

// MARK: - The strip follows the store

final class MotherQuotaStripWiringTests: MouseQueueTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        AppStore.shared.applyBrokerEventForTesting(.reconnected)
        let offscreen = GestureFixtures.offscreenWindow(size: NSSize(width: 900, height: 200))
        window = offscreen
        addTeardownBlock {
            offscreen.close()
            AppStore.shared.applyBrokerEventForTesting(.reconnected)
        }
    }

    private func makeStrip(width: CGFloat = 900) -> MotherQuotaStrip {
        let strip = MotherQuotaStrip()
        strip.now = { stripNow }
        strip.timeZone = stripZone
        strip.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        return strip
    }

    private func settle() { MD.pump(window, seconds: 0.15) }

    func testTheStripShowsTheStoresQuotaAndHidesWithoutOne() {
        let strip = makeStrip()
        settle()
        XCTAssertEqual(strip.frame.height, 0, "no quota yet")
        XCTAssertFalse(strip.isShown)

        AppStore.shared.applyBrokerEventForTesting(.quota(qsQuota(gate: .off)))
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { strip.isShown && strip.badgeText == "Gate OFF" })
        XCTAssertEqual(strip.frame.height, MotherQuotaStrip.visibleHeight)

        AppStore.shared.applyBrokerEventForTesting(.reconnected)
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { !strip.isShown })
        XCTAssertEqual(strip.frame.height, 0)
    }

    func testAnAckChangesTheStripOnlyToWhatItsBlockSaysAndARefusalOnlyAddsItsError() {
        let strip = makeStrip()
        AppStore.shared.applyBrokerEventForTesting(.quota(qsQuota(gate: .on)))
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { strip.badgeText == "Gate on" })

        AppStore.shared.applyQuotaGateResult(.failure(.code(.malformed, message: "x")))
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { strip.labelText.contains("Couldn't change the gate") })
        XCTAssertEqual(strip.badgeText, "Gate on", "a refusal leaves the displayed gate")
        XCTAssertFalse(strip.isOffBadge)

        AppStore.shared.applyQuotaGateResult(.success(qsQuota(gate: .offUntilReset, until: 1_793_658_600)))
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { strip.badgeText.hasPrefix("Gate off until reset") })
        XCTAssertFalse(strip.labelText.contains("Couldn't change"), "a success clears the refusal")
        XCTAssertTrue(strip.isOffBadge)
    }

    func testTheMotherPaneCarriesTheStrip() throws {
        let suite = UserDefaults(suiteName: "MotherQuotaStripWiringTests.\(UUID().uuidString)")!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        addTeardownBlock { MotherView.widthDefaults = previous }

        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(MD.allSubviews(view).compactMap { $0 as? MotherQuotaStrip }.first,
                                  "the Mother pane has no quota strip")
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { !strip.isShown }, "no quota: the strip is out of the way")

        AppStore.shared.applyBrokerEventForTesting(.quota(qsQuota(gate: .offUntilReset, until: 1_793_658_600)))
        XCTAssertTrue(MD.pumpUntil(window, timeout: 5) { strip.isShown && strip.isOffBadge },
                      "the pane shows the broker's quota")
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.frame.height, MotherQuotaStrip.visibleHeight)
        XCTAssertTrue(strip.frame.width > 0)
    }
}
