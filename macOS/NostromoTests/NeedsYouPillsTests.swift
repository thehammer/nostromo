import XCTest
import AppKit
import NostromoKit

// The sidebar's two "needs you" pills.
//
// A focus row used to show ONE red count for everything that wanted the operator. It now separates what
// STOPS an agent from what merely WAITS:
//   * BLOCKING (an approval is pending, the agent is stopped until the operator decides): a red pill with
//     a hand glyph, and a red highlight on the whole row;
//   * WAITING (nothing is stalled, something wants the operator: tracker items, Mother holds, flags): a
//     quiet amber pill with a list glyph, and no row highlight;
//   * an open decision is in neither (it keeps the purple attention dot).
// Both pills sit on the row's SECOND line, right-aligned (blocking left of waiting). The title line keeps
// the name, the environment tags and a built-in's own pill, and never moves. Nothing here reads the clock.
//
// Sections: the classification of every `NeedsYouReason` (a table that is the single source for the
// counting tests too), the projection of the counts onto a row's badge, the real row (pills, highlight,
// layout, narrow widths, clicks, accessibility, built-ins) and the contrast of every colour pair.

// MARK: - Shared helpers

private struct RGBA {
    var r: Double, g: Double, b: Double, a: Double
}

private func rgba(_ color: NSColor) throws -> RGBA {
    let c = try XCTUnwrap(color.usingColorSpace(.sRGB), "colour has no sRGB form")
    return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
}

/// `top` (with its own alpha) painted over `bottom`, as an opaque colour.
private func over(_ top: NSColor, _ bottom: NSColor) throws -> NSColor {
    let t = try rgba(top), b = try rgba(bottom)
    func mix(_ x: Double, _ y: Double) -> CGFloat { CGFloat(x * t.a + y * (1 - t.a)) }
    return NSColor(srgbRed: mix(t.r, b.r), green: mix(t.g, b.g), blue: mix(t.b, b.b), alpha: 1)
}

private func luminance(_ color: NSColor) throws -> Double {
    let c = try rgba(color)
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// WCAG contrast ratio of two opaque colours.
private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
    let la = try luminance(a), lb = try luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func assertSameColor(_ actual: NSColor?, _ expected: NSColor, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
    let got = try rgba(try XCTUnwrap(actual, "colour is nil. \(message)", file: file, line: line))
    let want = try rgba(expected)
    XCTAssertEqual(got.r, want.r, accuracy: 0.005, "red. \(message)", file: file, line: line)
    XCTAssertEqual(got.g, want.g, accuracy: 0.005, "green. \(message)", file: file, line: line)
    XCTAssertEqual(got.b, want.b, accuracy: 0.005, "blue. \(message)", file: file, line: line)
    XCTAssertEqual(got.a, want.a, accuracy: 0.005, "alpha. \(message)", file: file, line: line)
}

private func assertSameRect(_ a: NSRect, _ b: NSRect, _ message: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.origin.x, b.origin.x, accuracy: 0.01, "x: \(message())", file: file, line: line)
    XCTAssertEqual(a.origin.y, b.origin.y, accuracy: 0.01, "y: \(message())", file: file, line: line)
    XCTAssertEqual(a.size.width, b.size.width, accuracy: 0.01, "width: \(message())", file: file, line: line)
    XCTAssertEqual(a.size.height, b.size.height, accuracy: 0.01, "height: \(message())", file: file, line: line)
}

/// What a counts struct says once zero entries are ignored (a zero is the same as no entry).
private func nonZero(_ counts: NeedsYouCounts) -> NeedsYouCounts {
    NeedsYouCounts(blocking: counts.blocking.filter { $0.value > 0 }, waiting: counts.waiting.filter { $0.value > 0 })
}

// MARK: - Classification

/// One row per kind of reason: where it must land, and how much it adds to the blocking pill.
private struct ReasonCase {
    let name: String
    let reason: NeedsYouReason
    let expected: NeedsYouClass
    var blockingWeight = 1
}

/// The single source for the classification tests: `needsYouClass(of:)` and `needsYouCounts(from:)` are both
/// checked against it, so a reason that moves class fails in several places at once.
private enum ReasonTable {
    static let rows: [ReasonCase] = [
        ReasonCase(name: "approvalPending(1)", reason: .approvalPending(1), expected: .blocking),
        ReasonCase(name: "approvalPending(3)", reason: .approvalPending(3), expected: .blocking, blockingWeight: 3),
        // A producer never raises a zero, but if it did the request still blocks: at least one.
        ReasonCase(name: "approvalPending(0)", reason: .approvalPending(0), expected: .blocking, blockingWeight: 1),

        ReasonCase(name: "trackerWaiting", reason: .trackerWaiting, expected: .waiting),
        ReasonCase(name: "motherHold(gatesExhausted)", reason: .motherHold(.gatesExhausted), expected: .waiting),
        ReasonCase(name: "motherHold(reviewHold)", reason: .motherHold(.reviewHold), expected: .waiting),
        ReasonCase(name: "motherHold(decision)", reason: .motherHold(.decision), expected: .waiting),
        ReasonCase(name: "motherAwaiting", reason: .motherAwaiting, expected: .waiting),
        ReasonCase(name: "motherAttention(progressStalled)", reason: .motherAttention(.progressStalled), expected: .waiting),
        ReasonCase(name: "motherAttention(burnAhead)", reason: .motherAttention(.burnAhead), expected: .waiting),
        ReasonCase(name: "motherAttention(gatesIncomplete)", reason: .motherAttention(.gatesIncomplete), expected: .waiting),
        ReasonCase(name: "motherAttention(decisionAwaiting)", reason: .motherAttention(.decisionAwaiting), expected: .waiting),
        ReasonCase(name: "motherAttention(unknown)", reason: .motherAttention(.unknown("x")), expected: .waiting),
        ReasonCase(name: "other(x)", reason: .other("x"), expected: .waiting),

        // Open decisions keep the purple attention dot and are in neither pill.
        ReasonCase(name: "decisionOpen", reason: .decisionOpen, expected: .excluded),
    ]

    /// Exhaustive on purpose: adding a `NeedsYouReason` case stops this compiling until the table is revisited.
    static func kind(_ reason: NeedsYouReason) -> String {
        switch reason {
        case .motherHold: return "motherHold"
        case .motherAwaiting: return "motherAwaiting"
        case .motherAttention: return "motherAttention"
        case .decisionOpen: return "decisionOpen"
        case .approvalPending: return "approvalPending"
        case .trackerWaiting: return "trackerWaiting"
        case .other: return "other"
        }
    }

    static let allKinds: Set<String> = [
        "motherHold", "motherAwaiting", "motherAttention", "decisionOpen", "approvalPending", "trackerWaiting", "other",
    ]
}

final class NeedsYouClassificationTests: XCTestCase {

    private func item(_ reason: NeedsYouReason, _ source: NeedsYouSource = .focus("cody-1"), id: String = "t:1") -> NeedsYouItem {
        NeedsYouItem(id: id, source: source, reason: reason)
    }

    private func counts(_ items: [NeedsYouItem]) -> NeedsYouCounts {
        SidebarBadgeModel.needsYouCounts(from: NeedsYouSnapshot(items: items))
    }

    // MARK: The table

    func testTheTableCoversEveryKindOfReason() {
        XCTAssertEqual(Set(ReasonTable.rows.map { ReasonTable.kind($0.reason) }), ReasonTable.allKinds)
        // and every nested kind: all hold kinds and every attention reason
        for name in ["motherHold(gatesExhausted)", "motherHold(reviewHold)", "motherHold(decision)",
                     "motherAttention(progressStalled)", "motherAttention(burnAhead)",
                     "motherAttention(gatesIncomplete)", "motherAttention(decisionAwaiting)",
                     "motherAttention(unknown)"] {
            XCTAssertTrue(ReasonTable.rows.contains { $0.name == name }, "missing \(name)")
        }
    }

    func testEveryReasonLandsInExactlyItsClass() {
        for row in ReasonTable.rows {
            XCTAssertEqual(SidebarBadgeModel.needsYouClass(of: row.reason), row.expected, row.name)
        }
    }

    func testAPendingApprovalIsTheOnlyThingThatBlocks() {
        let blocking = ReasonTable.rows.filter { SidebarBadgeModel.needsYouClass(of: $0.reason) == .blocking }
        XCTAssertFalse(blocking.isEmpty)
        for row in blocking {
            guard case .approvalPending = row.reason else {
                XCTFail("\(row.name) must not block: only a pending approval stops an agent")
                continue
            }
        }
        for row in ReasonTable.rows {
            if case .approvalPending = row.reason {
                XCTAssertEqual(SidebarBadgeModel.needsYouClass(of: row.reason), .blocking, "\(row.name) stops an agent")
            }
        }
    }

    func testTrackerAndMotherReasonsWaitWithoutBlocking() {
        let reasons: [NeedsYouReason] = [.trackerWaiting, .motherAwaiting, .motherHold(.gatesExhausted), .motherHold(.reviewHold),
                                         .motherHold(.decision), .motherAttention(.burnAhead), .other("anything")]
        for reason in reasons {
            XCTAssertEqual(SidebarBadgeModel.needsYouClass(of: reason), .waiting, "\(reason)")
        }
    }

    func testAnOpenDecisionIsInNeitherPill() {
        XCTAssertEqual(SidebarBadgeModel.needsYouClass(of: .decisionOpen), .excluded)
        XCTAssertEqual(nonZero(counts([item(.decisionOpen)])), NeedsYouCounts())
    }

    // MARK: Counting agrees with the table

    func testEachReasonOnItsOwnCountsWhereTheTableSaysAndNowhereElse() {
        for row in ReasonTable.rows {
            let got = nonZero(counts([item(row.reason)]))
            let want: NeedsYouCounts
            switch row.expected {
            case .blocking: want = NeedsYouCounts(blocking: ["cody-1": row.blockingWeight], waiting: [:])
            case .waiting: want = NeedsYouCounts(blocking: [:], waiting: ["cody-1": 1])
            case .excluded: want = NeedsYouCounts()
            }
            XCTAssertEqual(got, want, row.name)
        }
    }

    func testEveryReasonOnOneFocusSumsPerTheTable() {
        let items = ReasonTable.rows.enumerated().map { i, row in item(row.reason, id: "t:\(i)") }
        let got = nonZero(counts(items))
        let blocking = ReasonTable.rows.filter { $0.expected == .blocking }.reduce(0) { $0 + $1.blockingWeight }
        let waiting = ReasonTable.rows.filter { $0.expected == .waiting }.count
        XCTAssertEqual(got.blocking, ["cody-1": blocking])
        XCTAssertEqual(got.waiting, ["cody-1": waiting])
    }

    // MARK: Counting rules

    func testOnlyItemsAboutAFocusCount() {
        let items = [
            item(.approvalPending(2), .motherJob("j1"), id: "t:1"),
            item(.trackerWaiting, .motherJob("j1"), id: "t:2"),
            item(.approvalPending(1), .app, id: "t:3"),
            item(.motherAwaiting, .app, id: "t:4"),
        ]
        XCTAssertEqual(counts(items), NeedsYouCounts())
    }

    func testAPendingApprovalCountsItsWeightAndTwoApprovalsAddUp() {
        XCTAssertEqual(nonZero(counts([item(.approvalPending(3))])).blocking, ["cody-1": 3])
        XCTAssertEqual(nonZero(counts([item(.approvalPending(1), id: "t:1"), item(.approvalPending(1), id: "t:2")])).blocking,
                       ["cody-1": 2])
        XCTAssertEqual(nonZero(counts([item(.approvalPending(3), id: "t:1"), item(.approvalPending(1), id: "t:2")])).blocking,
                       ["cody-1": 4])
    }

    func testAFocusWithBothKindsGetsBothCounts() {
        let got = counts([
            item(.approvalPending(1), id: "t:1"), item(.approvalPending(1), id: "t:2"),
            item(.trackerWaiting, id: "t:3"), item(.motherHold(.reviewHold), id: "t:4"), item(.other("x"), id: "t:5"),
            item(.decisionOpen, id: "t:6"),
        ])
        XCTAssertEqual(nonZero(got), NeedsYouCounts(blocking: ["cody-1": 2], waiting: ["cody-1": 3]))
    }

    func testTwoFocusesAreCountedIndependently() {
        let got = counts([
            item(.approvalPending(1), .focus("cody-1"), id: "t:1"),
            item(.trackerWaiting, .focus("cody-1"), id: "t:2"),
            item(.trackerWaiting, .focus("perri-1"), id: "t:3"),
            item(.trackerWaiting, .focus("perri-1"), id: "t:4"),
            item(.approvalPending(1), .focus("fred"), id: "t:5"),
        ])
        XCTAssertEqual(nonZero(got), NeedsYouCounts(
            blocking: ["cody-1": 1, "fred": 1],
            waiting: ["cody-1": 1, "perri-1": 2]))
    }

    func testAnEmptySnapshotHasNoCounts() {
        let got = SidebarBadgeModel.needsYouCounts(from: .empty)
        XCTAssertTrue(got.blocking.isEmpty)
        XCTAssertTrue(got.waiting.isEmpty)
        XCTAssertEqual(got, NeedsYouCounts())
    }
}

// MARK: - Badge projection

final class NeedsYouBadgeProjectionTests: XCTestCase {

    private func own(_ pill: String? = "12", detail: String? = "Next: Eng sync", level: FocusBadge.Level = .attention,
                     label: String = "Fred, 12 unread") -> FocusBadge {
        FocusBadge(pill: pill, detail: detail, level: level, accessibilityLabel: label)
    }

    // MARK: The phrase

    func testThePhraseReadsBlockingFirstAndIsSingularOrPlural() {
        let cases: [(Int, Int, String?)] = [
            (0, 0, nil),
            (1, 0, "1 approval blocking"),
            (2, 0, "2 approvals blocking"),
            (0, 1, "1 item waiting"),
            (0, 7, "7 items waiting"),
            (1, 1, "1 approval blocking, 1 item waiting"),
            (2, 7, "2 approvals blocking, 7 items waiting"),
        ]
        for (blocking, waiting, phrase) in cases {
            XCTAssertEqual(FocusBadge.needsYouPhrase(blocking: blocking, waiting: waiting), phrase, "\(blocking)/\(waiting)")
        }
    }

    func testANeedsYouBadgeCarriesNoPillOrLineAndReadsAsItsPhrase() {
        let both = FocusBadge.needsYou(blocking: 2, waiting: 7)
        XCTAssertNil(both.pill)
        XCTAssertNil(both.detail)
        XCTAssertEqual(both.blocking, 2)
        XCTAssertEqual(both.waiting, 7)
        XCTAssertEqual(both.level, .needsYouNow)
        XCTAssertEqual(both.accessibilityLabel, "2 approvals blocking, 7 items waiting")

        let waitingOnly = FocusBadge.needsYou(blocking: 0, waiting: 3)
        XCTAssertEqual(waitingOnly.level, .info, "nothing is stalled")
        XCTAssertEqual(waitingOnly.accessibilityLabel, "3 items waiting")
        XCTAssertEqual(waitingOnly.blocking, 0)
        XCTAssertEqual(waitingOnly.waiting, 3)
    }

    func testAnOrdinaryBadgeHasNoNeedsYouCounts() {
        let badge = FocusBadge(pill: "1", accessibilityLabel: "x")
        XCTAssertEqual(badge.blocking, 0)
        XCTAssertEqual(badge.waiting, 0)
    }

    // MARK: The registry's projection

    func testTheOwnPillAndLineSurviveAndTheCountsRideAlongInTheLabel() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "fred", badge: own())
        reg.publish(tag: "fred", sourceKey: "needs-you", badge: .needsYou(blocking: 2, waiting: 7))

        let badge = reg.badge(for: "fred")

        XCTAssertEqual(badge?.pill, "12", "the needs-you pills never replace the row's own pill")
        XCTAssertEqual(badge?.detail, "Next: Eng sync")
        XCTAssertEqual(badge?.blocking, 2)
        XCTAssertEqual(badge?.waiting, 7)
        XCTAssertEqual(badge?.level, .needsYouNow)
        XCTAssertEqual(badge?.accessibilityLabel, "Fred, 12 unread, 2 approvals blocking, 7 items waiting")
    }

    func testCountsAreSummedAcrossSourcesForATag() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "cody-1", sourceKey: "needs-you-a", badge: .needsYou(blocking: 1, waiting: 2))
        reg.publish(tag: "cody-1", sourceKey: "needs-you-b", badge: .needsYou(blocking: 2, waiting: 3))
        reg.publish(tag: "perri-1", sourceKey: "needs-you-a", badge: .needsYou(blocking: 0, waiting: 4))

        XCTAssertEqual(reg.badge(for: "cody-1")?.blocking, 3)
        XCTAssertEqual(reg.badge(for: "cody-1")?.waiting, 5)
        XCTAssertEqual(reg.badge(for: "perri-1")?.blocking, 0)
        XCTAssertEqual(reg.badge(for: "perri-1")?.waiting, 4)
    }

    func testATagWithOnlyNeedsYouCountsHasNoPillNoLineAndTheSpokenCounts() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "cody-1", sourceKey: "needs-you", badge: .needsYou(blocking: 2, waiting: 7))
        let badge = reg.badge(for: "cody-1")
        XCTAssertNil(badge?.pill)
        XCTAssertNil(badge?.detail)
        XCTAssertEqual(badge?.accessibilityLabel, "2 approvals blocking, 7 items waiting")
        XCTAssertEqual(badge?.level, .needsYouNow)
    }

    func testTheLevelRankingBlockingThenAttentionThenInfo() {
        // (own badge level or nil, blocking, waiting) -> projected level
        let cases: [(FocusBadge.Level?, Int, Int, FocusBadge.Level)] = [
            (.info, 0, 5, .info),
            (.attention, 0, 5, .attention),
            (.info, 1, 0, .needsYouNow),
            (.attention, 1, 5, .needsYouNow),
            (nil, 0, 5, .info),
            (nil, 3, 0, .needsYouNow),
            (nil, 3, 5, .needsYouNow),
        ]
        for (ownLevel, blocking, waiting, expected) in cases {
            var reg = FocusBadgeRegistry()
            if let ownLevel { reg.publish(tag: "t", sourceKey: "own", badge: own(level: ownLevel)) }
            reg.publish(tag: "t", sourceKey: "needs-you", badge: .needsYou(blocking: blocking, waiting: waiting))
            XCTAssertEqual(reg.badge(for: "t")?.level, expected,
                           "own \(String(describing: ownLevel)), blocking \(blocking), waiting \(waiting)")
        }
    }

    func testWaitingAloneNeverRaisesTheLevelAboveTheOwnBadges() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "t", sourceKey: "own", badge: own(level: .info))
        reg.publish(tag: "t", sourceKey: "needs-you", badge: .needsYou(blocking: 0, waiting: 9))
        XCTAssertEqual(reg.badge(for: "t")?.level, .info)
    }

    func testAttentionTagsStayTheOwnAttentionLevelOnly() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "blocked", sourceKey: "needs-you", badge: .needsYou(blocking: 2, waiting: 0))
        reg.publish(tag: "waits", sourceKey: "needs-you", badge: .needsYou(blocking: 0, waiting: 2))
        XCTAssertTrue(reg.attentionTags.isEmpty, "the purple dot is not driven by the needs-you pills")

        reg.publish(tag: "fred", sourceKey: "fred", badge: own(level: .attention))
        reg.publish(tag: "fred", sourceKey: "needs-you", badge: .needsYou(blocking: 1, waiting: 1))
        XCTAssertEqual(reg.attentionTags, ["fred"])

        reg.publish(tag: "teri", sourceKey: "teri", badge: own(level: .info))
        reg.publish(tag: "teri", sourceKey: "needs-you", badge: .needsYou(blocking: 1, waiting: 1))
        XCTAssertEqual(reg.attentionTags, ["fred"])
    }

    func testClearingTheNeedsYouSourceRestoresTheOwnBadgeAlone() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "fred", sourceKey: "fred", badge: own())
        reg.publish(tag: "fred", sourceKey: "needs-you", badge: .needsYou(blocking: 2, waiting: 7))
        reg.publish(tag: "fred", sourceKey: "needs-you", badge: nil)
        let badge = reg.badge(for: "fred")
        XCTAssertEqual(badge?.blocking, 0)
        XCTAssertEqual(badge?.waiting, 0)
        XCTAssertEqual(badge?.level, .attention)
        XCTAssertEqual(badge?.accessibilityLabel, "Fred, 12 unread")
    }

    // MARK: The model

    func testTheModelPublishesChangesAndClearsEachTagOnItsOwn() {
        var model = SidebarBadgeModel()
        model.setNeedsYou(NeedsYouCounts(blocking: ["cody-1": 1, "perri-1": 3], waiting: ["cody-1": 4, "teri-1": 2]))
        XCTAssertEqual(model.badge(for: "cody-1")?.blocking, 1)
        XCTAssertEqual(model.badge(for: "cody-1")?.waiting, 4)
        XCTAssertEqual(model.badge(for: "perri-1")?.blocking, 3)
        XCTAssertEqual(model.badge(for: "perri-1")?.waiting, 0)
        XCTAssertEqual(model.badge(for: "perri-1")?.level, .needsYouNow)
        XCTAssertEqual(model.badge(for: "teri-1")?.blocking, 0)
        XCTAssertEqual(model.badge(for: "teri-1")?.waiting, 2)
        XCTAssertEqual(model.badge(for: "teri-1")?.level, .info)

        model.setNeedsYou(NeedsYouCounts(blocking: ["cody-1": 2], waiting: [:]))
        XCTAssertEqual(model.badge(for: "cody-1")?.blocking, 2)
        XCTAssertEqual(model.badge(for: "cody-1")?.waiting, 0, "a tag that lost its waiting count loses that pill")
        XCTAssertNil(model.badge(for: "perri-1"))
        XCTAssertNil(model.badge(for: "teri-1"))

        model.setNeedsYou(NeedsYouCounts())
        XCTAssertNil(model.badge(for: "cody-1"))
    }

    func testAZeroCountIsTheSameAsNoCount() {
        var model = SidebarBadgeModel()
        model.setNeedsYou(NeedsYouCounts(blocking: ["cody-1": 0], waiting: ["cody-1": 0, "perri-1": 2]))
        XCTAssertNil(model.badge(for: "cody-1"))
        XCTAssertEqual(model.badge(for: "perri-1")?.waiting, 2)
    }

    func testTheDecisionDotsTagsAreUntouchedByEitherPill() {
        var model = SidebarBadgeModel()
        model.setNeedsYou(NeedsYouCounts(blocking: ["cody-1": 1], waiting: ["cody-1": 2]))
        XCTAssertEqual(model.combinedAttentionTags(storeTags: ["cody-1"]), ["cody-1"])
        XCTAssertEqual(model.combinedAttentionTags(storeTags: []), [])
        XCTAssertEqual(model.badge(for: "cody-1")?.blocking, 1)
    }

    func testASnapshotGoesThroughTheModelToTheRightPills() {
        let snapshot = NeedsYouSnapshot(items: [
            NeedsYouItem(id: "approvals:a", source: .focus("cody-1"), reason: .approvalPending(1)),
            NeedsYouItem(id: "approvals:b", source: .focus("cody-1"), reason: .approvalPending(1)),
            NeedsYouItem(id: "tracker:a", source: .focus("cody-1"), reason: .trackerWaiting),
            NeedsYouItem(id: "decisions:cody-1", source: .focus("cody-1"), reason: .decisionOpen),
            NeedsYouItem(id: "tracker:b", source: .focus("perri-1"), reason: .trackerWaiting),
        ])
        var model = SidebarBadgeModel()
        model.setNeedsYou(SidebarBadgeModel.needsYouCounts(from: snapshot))
        XCTAssertEqual(model.badge(for: "cody-1")?.blocking, 2)
        XCTAssertEqual(model.badge(for: "cody-1")?.waiting, 1)
        XCTAssertEqual(model.badge(for: "perri-1")?.blocking, 0)
        XCTAssertEqual(model.badge(for: "perri-1")?.waiting, 1)
    }
}

// MARK: - The row

final class NeedsYouPillsRowTests: XCTestCase {

    private static let narrowest: CGFloat = 60
    private static let widest: CGFloat = 200
    private static let longBranch = "feature/sidebar-blocking-vs-waiting-badges"
    private static let longLabel = "A very long focus label that cannot possibly fit in a narrow sidebar row"

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private static func dynamicFocus(agent: String = "cody") -> Focus {
        Focus(id: "11111111-aaaa", agentTag: agent, projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
    }

    private func builtIn(_ tag: String) -> Focus { Focus.builtIns.first { $0.agentTag == tag }! }

    /// A row with a second line, hosted pinned as `TabBarView` pins one (required width and height, leading
    /// and top to its container) in an off-screen window, so the layout is the real one at any width.
    private func makeItem(focus: Focus? = nil, label: String = "Cody in Nostromo", branch: String = "main",
                          width: CGFloat = Theme.sidebarWidth, indented: Bool = false) -> NavTabItem {
        let item = NavTabItem(focus: focus ?? Self.dynamicFocus(), label: label, secondary: branch, indented: indented)
        let height = Theme.navItemSubtitleHeight
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        windows.append(window)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 20))
        window.contentView = host
        item.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(item)
        NSLayoutConstraint.activate([
            item.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            item.topAnchor.constraint(equalTo: host.topAnchor),
            item.widthAnchor.constraint(equalToConstant: width),
            item.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return item
    }

    private func relayout(_ item: NavTabItem) {
        (item.superview ?? item).layoutSubtreeIfNeeded()
    }

    private func apply(_ item: NavTabItem, blocking: Int = 0, waiting: Int = 0) {
        if blocking == 0 && waiting == 0 {
            item.setBadge(nil)
        } else {
            item.setBadge(FocusBadge.needsYou(blocking: blocking, waiting: waiting))
        }
        relayout(item)
    }

    private func inBounds(_ rect: NSRect, of item: NavTabItem) -> Bool {
        item.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    }

    // MARK: What each situation shows

    func testApprovalsOnlyShowsTheRedPillAndHighlightsTheRow() throws {
        let item = makeItem()
        apply(item, blocking: 2)

        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertNil(item.waitingPillText)
        XCTAssertNil(item.pillText, "the needs-you pills are never the row's own pill")
        XCTAssertNotNil(item.blockingPillFrame)
        XCTAssertNil(item.waitingPillFrame)
        XCTAssertTrue(item.showsBlockingHighlight)
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: false, isBlocking: true))
    }

    func testTrackerOnlyShowsTheQuietAmberPillAndNoHighlight() throws {
        let item = makeItem()
        apply(item, waiting: 7)

        XCTAssertEqual(item.waitingPillText, "7")
        XCTAssertNil(item.blockingPillText)
        XCTAssertNil(item.pillText)
        XCTAssertNotNil(item.waitingPillFrame)
        XCTAssertNil(item.blockingPillFrame)
        XCTAssertFalse(item.showsBlockingHighlight, "nothing is stalled: the row is not highlighted")
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: false, isBlocking: false))
        XCTAssertNil(item.highlight.fill)
        XCTAssertTrue(item.highlight.bars.isEmpty)
    }

    func testBothShowBothPillsBlockingLeftOfWaitingAndTheRowIsHighlighted() throws {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)

        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertEqual(item.waitingPillText, "7")
        let blocking = try XCTUnwrap(item.blockingPillFrame), waiting = try XCTUnwrap(item.waitingPillFrame)
        XCTAssertLessThan(blocking.maxX, waiting.minX, "blocking sits left of waiting, not overlapping")
        XCTAssertTrue(item.showsBlockingHighlight)
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: false, isBlocking: true))
    }

    func testClearingTheBadgeTakesBothPillsAndTheHighlightAway() {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        apply(item)

        XCTAssertNil(item.blockingPillText)
        XCTAssertNil(item.waitingPillText)
        XCTAssertNil(item.blockingPillFrame)
        XCTAssertNil(item.waitingPillFrame)
        XCTAssertNil(item.blockingPillToolTip)
        XCTAssertNil(item.waitingPillToolTip)
        XCTAssertFalse(item.showsBlockingHighlight)
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: false, isBlocking: false))
    }

    func testEachPillGoesAwayOnItsOwnWhenItsCountDrops() {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        apply(item, blocking: 0, waiting: 7)
        XCTAssertNil(item.blockingPillText)
        XCTAssertEqual(item.waitingPillText, "7")
        XCTAssertFalse(item.showsBlockingHighlight)
        apply(item, blocking: 3, waiting: 0)
        XCTAssertEqual(item.blockingPillText, "3")
        XCTAssertNil(item.waitingPillText)
        XCTAssertTrue(item.showsBlockingHighlight)
    }

    func testPillTextCapsAt99Plus() {
        let cases: [(Int, String)] = [(1, "1"), (9, "9"), (12, "12"), (99, "99"), (100, "99+"), (150, "99+"), (12345, "99+")]
        for (count, text) in cases {
            let blocking = makeItem()
            apply(blocking, blocking: count)
            XCTAssertEqual(blocking.blockingPillText, text, "blocking \(count)")
            let waiting = makeItem()
            apply(waiting, waiting: count)
            XCTAssertEqual(waiting.waitingPillText, text, "waiting \(count)")
        }
    }

    func testTheCountsFlowFromTheModelThroughTheBadgeToTheRow() {
        var model = SidebarBadgeModel()
        model.setNeedsYou(NeedsYouCounts(blocking: ["cody-1": 2], waiting: ["cody-1": 7]))
        let item = makeItem()
        item.setBadge(model.badge(for: "cody-1"))
        relayout(item)
        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertEqual(item.waitingPillText, "7")
        XCTAssertEqual(item.accessibilityLabel(), "2 approvals blocking, 7 items waiting")

        model.setNeedsYou(NeedsYouCounts())
        item.setBadge(model.badge(for: "cody-1"))
        relayout(item)
        XCTAssertNil(item.blockingPillText)
        XCTAssertNil(item.waitingPillText)
    }

    // MARK: Tooltips

    func testTheBlockingTooltipSaysTheAgentIsStopped() {
        let cases: [(Int, String)] = [
            (1, "1 approval blocking: the agent is stopped until you decide"),
            (2, "2 approvals blocking: the agent is stopped until you decide"),
            (12, "12 approvals blocking: the agent is stopped until you decide"),
        ]
        for (count, tip) in cases {
            let item = makeItem()
            apply(item, blocking: count)
            XCTAssertEqual(item.blockingPillToolTip, tip)
            XCTAssertNil(item.waitingPillToolTip)
        }
    }

    func testTheWaitingTooltipSaysNothingIsStalled() {
        let cases: [(Int, String)] = [
            (1, "1 item waiting for you: nothing is stalled"),
            (7, "7 items waiting for you: nothing is stalled"),
        ]
        for (count, tip) in cases {
            let item = makeItem()
            apply(item, waiting: count)
            XCTAssertEqual(item.waitingPillToolTip, tip)
            XCTAssertNil(item.blockingPillToolTip)
        }
    }

    // MARK: Accessibility

    func testTheRowReadsTheCountsAndNeverSaysNeedsYouNow() {
        let cases: [(Int, Int, String)] = [
            (2, 0, "2 approvals blocking"),
            (1, 0, "1 approval blocking"),
            (0, 7, "7 items waiting"),
            (0, 1, "1 item waiting"),
            (2, 7, "2 approvals blocking, 7 items waiting"),
        ]
        for (blocking, waiting, words) in cases {
            let item = makeItem()
            apply(item, blocking: blocking, waiting: waiting)
            XCTAssertEqual(item.accessibilityLabel(), words)
            XCTAssertFalse((item.accessibilityLabel() ?? "").contains("needs you now"))
            XCTAssertTrue(item.isAccessibilityElement())
        }
    }

    func testAnOwnAttentionBadgeStillAppendsNeedsYourAttention() {
        var reg = FocusBadgeRegistry()
        reg.publish(tag: "mother", sourceKey: "mother",
                    badge: FocusBadge(pill: "1", detail: "1 awaiting", level: .attention, accessibilityLabel: "Mother, 1 awaiting"))
        reg.publish(tag: "mother", sourceKey: "needs-you", badge: .needsYou(blocking: 0, waiting: 3))
        let item = makeItem(focus: builtIn("mother"))
        item.setBadge(reg.badge(for: "mother"))
        XCTAssertEqual(item.accessibilityLabel(), "Mother, 1 awaiting, 3 items waiting, needs your attention")
    }

    func testClearingTheBadgeRemovesTheSpokenCounts() {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        apply(item)
        XCTAssertFalse((item.accessibilityLabel() ?? "").contains("blocking"))
        XCTAssertFalse((item.accessibilityLabel() ?? "").contains("waiting"))
    }

    // MARK: Row highlight

    func testTheFourHighlightStatesAreExactlyAsSpecified() throws {
        let none = NavRowHighlight.style(isActive: false, isBlocking: false)
        XCTAssertNil(none.fill)
        XCTAssertTrue(none.bars.isEmpty)

        let active = NavRowHighlight.style(isActive: true, isBlocking: false)
        try assertSameColor(active.fill, Theme.cornflower.withAlphaComponent(0.12), "active fill")
        XCTAssertEqual(active.bars.count, 1)
        try assertSameColor(active.bars.first, Theme.cornflower, "active bar")

        let blocking = NavRowHighlight.style(isActive: false, isBlocking: true)
        try assertSameColor(blocking.fill, Theme.blockingRowFill, "blocking fill")
        XCTAssertEqual(blocking.bars.count, 1)
        try assertSameColor(blocking.bars.first, Theme.needsYouNow, "blocking bar")

        let both = NavRowHighlight.style(isActive: true, isBlocking: true)
        try assertSameColor(both.fill, Theme.blockingRowFill, "red fill wins when active and blocked")
        XCTAssertEqual(both.bars.count, 2, "active keeps its bar and blocking adds a second one")
        try assertSameColor(both.bars.first, Theme.cornflower, "left bar stays the active cornflower")
        try assertSameColor(both.bars.last, Theme.needsYouNow, "second bar is the blocking red")
    }

    func testTheFourHighlightStatesAreDistinguishable() throws {
        func signature(_ h: NavRowHighlight) throws -> String {
            func text(_ c: NSColor) throws -> String {
                let v = try rgba(c)
                return String(format: "%.3f/%.3f/%.3f/%.3f", v.r, v.g, v.b, v.a)
            }
            let fill = try h.fill.map(text) ?? "none"
            let bars = try h.bars.map(text).joined(separator: ",")
            return fill + " | " + bars
        }
        var seen = Set<String>()
        for active in [false, true] {
            for blocking in [false, true] {
                seen.insert(try signature(NavRowHighlight.style(isActive: active, isBlocking: blocking)))
            }
        }
        XCTAssertEqual(seen.count, 4, "no two of selected / blocked / both / neither may look alike")
    }

    func testTheRowsHighlightIsTheStyleOfItsTwoIndependentInputs() {
        for active in [false, true] {
            for blocked in [false, true] {
                let want = NavRowHighlight.style(isActive: active, isBlocking: blocked)

                let activeFirst = makeItem()
                activeFirst.isActive = active
                apply(activeFirst, blocking: blocked ? 2 : 0, waiting: 5)
                XCTAssertEqual(activeFirst.highlight, want, "active \(active), blocked \(blocked), active set first")
                XCTAssertEqual(activeFirst.showsBlockingHighlight, blocked)

                let badgeFirst = makeItem()
                apply(badgeFirst, blocking: blocked ? 2 : 0, waiting: 5)
                badgeFirst.isActive = active
                XCTAssertEqual(badgeFirst.highlight, want, "active \(active), blocked \(blocked), badge set first")
            }
        }
    }

    func testSelectingOrClearingNeverLosesTheOtherHalfOfTheHighlight() {
        let item = makeItem()
        apply(item, blocking: 1)
        item.isActive = true
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: true, isBlocking: true))
        apply(item)
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: true, isBlocking: false), "still selected")
        apply(item, blocking: 1)
        item.isActive = false
        XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: false, isBlocking: true), "still blocked")
    }

    func testWaitingAloneNeverHighlightsASelectedOrUnselectedRow() {
        for active in [false, true] {
            let item = makeItem()
            item.isActive = active
            apply(item, waiting: 7)
            XCTAssertFalse(item.showsBlockingHighlight)
            XCTAssertEqual(item.highlight, NavRowHighlight.style(isActive: active, isBlocking: false))
        }
    }

    // MARK: No layout shift

    private struct Decoration {
        var name: String
        var environments: [String] = []
        var attention = false
    }

    private let decorations: [Decoration] = [
        Decoration(name: "plain"),
        Decoration(name: "environment tag", environments: ["production"]),
        Decoration(name: "attention dot", attention: true),
        Decoration(name: "environment tag and attention dot", environments: ["production"], attention: true),
    ]

    func testTheRowHeightIsTheSameWithAndWithoutEitherPill() {
        for width in [Theme.sidebarWidth, 120] {
            let baseline = makeItem(width: width)
            let fitting = baseline.fittingSize.height
            XCTAssertEqual(baseline.frame.height, Theme.navItemSubtitleHeight)

            let states: [(String, Int, Int)] = [
                ("blocking only", 2, 0), ("waiting only", 0, 7), ("both", 2, 7), ("both, three digits", 150, 150),
            ]
            for (name, blocking, waiting) in states {
                for decoration in decorations {
                    let item = makeItem(width: width)
                    item.environments = decoration.environments
                    item.needsAttention = decoration.attention
                    apply(item, blocking: blocking, waiting: waiting)
                    XCTAssertEqual(item.frame.height, Theme.navItemSubtitleHeight, "\(name), \(decoration.name), \(Int(width)) pt")
                    XCTAssertEqual(item.fittingSize.height, fitting, "\(name), \(decoration.name), \(Int(width)) pt")
                }
            }

            // And the same row going from pills back to none.
            let item = makeItem(width: width)
            apply(item, blocking: 2, waiting: 7)
            apply(item)
            XCTAssertEqual(item.frame.height, Theme.navItemSubtitleHeight)
            XCTAssertEqual(item.fittingSize.height, fitting)
        }
    }

    func testTheTitleNeverMovesWhateverThePillsSay() {
        let states: [(String, Int, Int)] = [
            ("blocking", 2, 0), ("waiting", 0, 7), ("both", 2, 7), ("blocking 12", 12, 0),
            ("blocking 99+", 150, 0), ("both 99+", 150, 150),
        ]
        for width in [Theme.sidebarWidth, 120] {
            for indented in [false, true] {
                for label in ["Cody in Nostromo", Self.longLabel] {
                    for decoration in decorations {
                        let baseline = makeItem(label: label, width: width, indented: indented)
                        baseline.environments = decoration.environments
                        baseline.needsAttention = decoration.attention
                        relayout(baseline)
                        for (name, blocking, waiting) in states {
                            let item = makeItem(label: label, width: width, indented: indented)
                            item.environments = decoration.environments
                            item.needsAttention = decoration.attention
                            apply(item, blocking: blocking, waiting: waiting)
                            assertSameRect(item.labelFrame, baseline.labelFrame,
                                           "title with \(name), \(decoration.name), \(Int(width)) pt, indented \(indented)")
                        }
                    }
                }
            }
        }
    }

    func testChangingTheCountsOnOneRowNeverMovesTheTitle() {
        for label in ["Cody in Nostromo", Self.longLabel] {
            let item = makeItem(label: label)
            apply(item, blocking: 2)
            let title = item.labelFrame
            for count in [12, 99, 150, 2] {
                apply(item, blocking: count)
                assertSameRect(item.labelFrame, title, "blocking \(count)")
            }
            apply(item, blocking: 150, waiting: 150)
            assertSameRect(item.labelFrame, title, "both pills")
            apply(item)
            assertSameRect(item.labelFrame, title, "no pills")
        }
    }

    func testThePillsStayPutWhenTheTitleLinesDecorationsChange() throws {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        let blocking = try XCTUnwrap(item.blockingPillFrame), waiting = try XCTUnwrap(item.waitingPillFrame)

        item.environments = ["production"]
        item.needsAttention = true
        relayout(item)

        assertSameRect(try XCTUnwrap(item.blockingPillFrame), blocking, "blocking pill with an environment tag and the dot")
        assertSameRect(try XCTUnwrap(item.waitingPillFrame), waiting, "waiting pill with an environment tag and the dot")
    }

    // MARK: What is actually drawn

    private func assertDrawn(_ item: NavTabItem, active: Bool, blocking: Bool, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let want = NavRowHighlight.style(isActive: active, isBlocking: blocking)
        let fill = try XCTUnwrap(item.drawnFill, "the row has no layer fill: \(context)", file: file, line: line)
        if let wantFill = want.fill {
            try assertSameColor(NSColor(cgColor: fill), wantFill, "row fill: \(context)", file: file, line: line)
            XCTAssertGreaterThan(fill.alpha, 0.1, "the fill is visible: \(context)", file: file, line: line)
        } else {
            XCTAssertEqual(fill.alpha, 0, accuracy: 0.001, "no fill: \(context)", file: file, line: line)
        }
        let bars = item.drawnBars
        XCTAssertEqual(bars.count, 2, file: file, line: line)
        for (index, bar) in bars.enumerated() {
            if index < want.bars.count {
                XCTAssertFalse(bar.isHidden, "bar \(index) is shown: \(context)", file: file, line: line)
                try assertSameColor(bar.color.flatMap { NSColor(cgColor: $0) }, want.bars[index], "bar \(index): \(context)",
                                    file: file, line: line)
            } else {
                XCTAssertTrue(bar.isHidden, "bar \(index) is hidden: \(context)", file: file, line: line)
            }
        }
    }

    func testTheHighlightIsActuallyDrawnInAllFourStatesInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let item = makeItem()
            item.appearance = try XCTUnwrap(NSAppearance(named: name))
            let context = name.rawValue

            item.isActive = false; apply(item)
            try assertDrawn(item, active: false, blocking: false, "none, \(context)")

            item.isActive = true
            try assertDrawn(item, active: true, blocking: false, "active, \(context)")

            apply(item, blocking: 2)
            try assertDrawn(item, active: true, blocking: true, "active + blocking, \(context)")

            item.isActive = false
            try assertDrawn(item, active: false, blocking: true, "blocking, \(context)")

            apply(item)
            try assertDrawn(item, active: false, blocking: false, "cleared again, \(context)")
        }
    }

    func testWaitingAloneDrawsNoHighlightSelectedOrNot() throws {
        let item = makeItem()
        apply(item, waiting: 7)
        try assertDrawn(item, active: false, blocking: false, "waiting only")
        item.isActive = true
        try assertDrawn(item, active: true, blocking: false, "waiting only, selected")
        XCTAssertEqual(item.drawnBars.filter { !$0.isHidden }.count, 1, "only the active bar")
    }

    func testTheRedFillAndBarAreTheBlockingRedAndTheActiveBarIsTheFirst() throws {
        let item = makeItem()
        item.isActive = true
        apply(item, blocking: 1)
        let bars = item.drawnBars
        try assertSameColor(bars[0].color.flatMap { NSColor(cgColor: $0) }, Theme.cornflower, "first bar")
        try assertSameColor(bars[1].color.flatMap { NSColor(cgColor: $0) }, Theme.needsYouNow, "second bar")
        try assertSameColor(item.drawnFill.flatMap { NSColor(cgColor: $0) }, Theme.blockingRowFill, "fill")
    }

    // MARK: Where the pills sit

    func testThePillsSitOnTheSecondLineRightAlignedAndTheBranchStaysLeftOfThem() throws {
        let item = makeItem(width: Theme.sidebarWidth)
        apply(item, blocking: 2, waiting: 7)
        let blocking = try XCTUnwrap(item.blockingPillFrame), waiting = try XCTUnwrap(item.waitingPillFrame)

        for (name, pill) in [("blocking", blocking), ("waiting", waiting)] {
            XCTAssertTrue(inBounds(pill, of: item), "\(name) pill is inside the row")
            XCTAssertLessThan(pill.midY, item.labelFrame.minY, "\(name) pill is below the title line")
        }
        XCTAssertLessThan(blocking.maxX, waiting.minX)
        XCTAssertLessThanOrEqual(waiting.maxX, item.bounds.width - 8 + 0.5, "right-aligned with the row's trailing inset")
        XCTAssertGreaterThanOrEqual(waiting.maxX, item.bounds.width - 16, "and hugging that edge")

        XCTAssertTrue(item.secondaryVisible, "there is room for the branch at the sidebar's width")
        let line = try XCTUnwrap(item.secondaryFrame)
        XCTAssertLessThanOrEqual(line.maxX, blocking.minX + 0.5, "the branch ends before the first pill")
        XCTAssertEqual(blocking.midY, line.midY, accuracy: 3, "pills share the branch's line")
        XCTAssertEqual(waiting.midY, line.midY, accuracy: 3)
        XCTAssertEqual(item.secondaryText, "main", "the second line keeps its text")
    }

    func testASinglePillIsRightAligned() throws {
        let blockingOnly = makeItem()
        apply(blockingOnly, blocking: 2)
        let blocking = try XCTUnwrap(blockingOnly.blockingPillFrame)
        XCTAssertLessThanOrEqual(blocking.maxX, blockingOnly.bounds.width - 8 + 0.5)
        XCTAssertGreaterThanOrEqual(blocking.maxX, blockingOnly.bounds.width - 16)
        XCTAssertLessThan(blocking.midY, blockingOnly.labelFrame.minY)
        XCTAssertLessThanOrEqual(try XCTUnwrap(blockingOnly.secondaryFrame).maxX, blocking.minX + 0.5)

        let waitingOnly = makeItem()
        apply(waitingOnly, waiting: 7)
        let waiting = try XCTUnwrap(waitingOnly.waitingPillFrame)
        XCTAssertLessThanOrEqual(waiting.maxX, waitingOnly.bounds.width - 8 + 0.5)
        XCTAssertGreaterThanOrEqual(waiting.maxX, waitingOnly.bounds.width - 16)
        XCTAssertLessThan(waiting.midY, waitingOnly.labelFrame.minY)
        XCTAssertLessThanOrEqual(try XCTUnwrap(waitingOnly.secondaryFrame).maxX, waiting.minX + 0.5)
    }

    func testTheSecondLineHasNoPillFramesWhenThereAreNoCounts() {
        let item = makeItem()
        XCTAssertNil(item.blockingPillFrame)
        XCTAssertNil(item.waitingPillFrame)
        XCTAssertTrue(item.secondaryVisible)
        XCTAssertNotNil(item.secondaryFrame)
        XCTAssertFalse(item.waitingPillIsCollapsed)
    }

    func testTheBranchNeverRunsUnderAPillAtTheNormalWidthWithZeroOneOrTwoPills() throws {
        for branch in ["main", Self.longBranch] {
            for indented in [false, true] {
                for (blockingCount, waitingCount) in [(0, 0), (2, 0), (0, 7), (2, 7), (150, 150)] {
                    let item = makeItem(branch: branch, width: Theme.sidebarWidth, indented: indented)
                    apply(item, blocking: blockingCount, waiting: waitingCount)
                    let at = "branch \(branch), indented \(indented), blocking \(blockingCount), waiting \(waitingCount)"
                    guard item.secondaryVisible else { continue }
                    let line = try XCTUnwrap(item.secondaryFrame, at)
                    let leadingPill = [item.blockingPillFrame, item.waitingPillFrame].compactMap { $0 }.map(\.minX).min()
                    if let leadingPill {
                        XCTAssertLessThanOrEqual(line.maxX, leadingPill + 0.5, "branch ends before the slot's leading edge: \(at)")
                    }
                    XCTAssertLessThanOrEqual(line.maxX, item.bounds.width, "inside the row: \(at)")
                }
            }
        }
    }

    func testAPillAppearingOrGoingAwayOnlyTruncatesTheBranchItNeverMovesIt() throws {
        // A short branch has room at the normal width: its frame must not change at all.
        let short = makeItem(branch: "main")
        let shortBefore = try XCTUnwrap(short.secondaryFrame)
        for (blockingCount, waitingCount) in [(2, 0), (0, 7), (2, 7)] {
            apply(short, blocking: blockingCount, waiting: waitingCount)
            assertSameRect(try XCTUnwrap(short.secondaryFrame), shortBefore, "short branch with \(blockingCount)/\(waitingCount)")
        }
        apply(short)
        assertSameRect(try XCTUnwrap(short.secondaryFrame), shortBefore, "short branch after the pills went away")

        // A long branch is truncated: only its trailing edge moves, and it comes back when the pills go.
        let long = makeItem(branch: Self.longBranch)
        let longBefore = try XCTUnwrap(long.secondaryFrame)
        var previousMaxX = longBefore.maxX
        for (blockingCount, waitingCount) in [(2, 0), (2, 7)] {
            apply(long, blocking: blockingCount, waiting: waitingCount)
            let now = try XCTUnwrap(long.secondaryFrame)
            XCTAssertEqual(now.minX, longBefore.minX, accuracy: 0.5, "only the trailing edge moves")
            XCTAssertEqual(now.minY, longBefore.minY, accuracy: 0.5)
            XCTAssertEqual(now.height, longBefore.height, accuracy: 0.5)
            XCTAssertLessThan(now.maxX, previousMaxX + 0.5, "adding a pill never widens the branch")
            XCTAssertLessThan(now.maxX, longBefore.maxX - 10, "the branch gave way to the pills")
            previousMaxX = now.maxX
        }
        apply(long)
        assertSameRect(try XCTUnwrap(long.secondaryFrame), longBefore, "long branch after the pills went away")
    }

    // MARK: Narrow widths

    private struct Sample {
        let width: CGFloat
        let secondaryVisible: Bool
        let secondaryFrame: NSRect?
        let collapsed: Bool
        let blocking: NSRect?
        let waiting: NSRect?
    }

    private func sample(blocking: Int, waiting: Int, width: CGFloat, indented: Bool, branch: String) -> Sample {
        let item = makeItem(branch: branch, width: width, indented: indented)
        defer { item.window?.close() }
        apply(item, blocking: blocking, waiting: waiting)
        return Sample(width: width, secondaryVisible: item.secondaryVisible, secondaryFrame: item.secondaryFrame,
                      collapsed: item.waitingPillIsCollapsed, blocking: item.blockingPillFrame, waiting: item.waitingPillFrame)
    }

    /// Widths from the widest down to the narrowest, in steps of 10.
    private var descendingWidths: [CGFloat] {
        Array(stride(from: Self.widest, through: Self.narrowest, by: -10))
    }

    func testAsTheRowNarrowsTheBranchGoesFirstThenTheWaitingPillCollapsesAndTheBlockingPillNeverChanges() {
        let scenarios: [(String, Int, Int)] = [("blocking only", 2, 0), ("waiting only", 0, 7), ("both", 2, 7), ("both, 99+", 150, 150)]
        for (name, blockingCount, waitingCount) in scenarios {
            for indented in [false, true] {
                for branch in ["main", Self.longBranch] {
                    let context = "\(name), indented \(indented), branch \(branch)"
                    let reference = sample(blocking: blockingCount, waiting: waitingCount, width: Self.widest,
                                           indented: indented, branch: branch)
                    XCTAssertTrue(reference.secondaryVisible, "branch shows at \(Int(Self.widest)) pt: \(context)")
                    XCTAssertFalse(reference.collapsed, "nothing collapsed at \(Int(Self.widest)) pt: \(context)")

                    var branchGone = false, collapsedSeen = false
                    for width in descendingWidths {
                        let s = sample(blocking: blockingCount, waiting: waitingCount, width: width, indented: indented, branch: branch)
                        let at = "\(context), \(Int(width)) pt"

                        // The blocking pill is never given up: same size as at the widest, always inside the row.
                        if blockingCount > 0 {
                            guard let b = s.blocking, let ref = reference.blocking else { XCTFail("no blocking pill: \(at)"); continue }
                            XCTAssertEqual(b.width, ref.width, accuracy: 0.5, "blocking pill kept its size: \(at)")
                            XCTAssertTrue(NSRect(x: -0.5, y: -0.5, width: width + 1, height: Theme.navItemSubtitleHeight + 1).contains(b),
                                          "blocking pill inside the row: \(at)")
                        }
                        if waitingCount > 0 {
                            guard let w = s.waiting, let ref = reference.waiting else { XCTFail("no waiting pill: \(at)"); continue }
                            // Only while both pills physically fit between the row's leading inset and the trailing
                            // 8 pt. In a row too narrow even for the collapsed pills the waiting pill is cut off at the
                            // slot's edge (the blocking pill is never the one that is clipped), so it cannot be right-aligned.
                            let leading: CGFloat = (indented ? 21 : 9) + NavTabItem.activitySlotWidth   // the name starts after the activity mark's slot
                            let needed = (s.blocking.map { $0.width + 3 } ?? 0) + w.width
                            if needed <= width - 8 - leading {
                                XCTAssertLessThanOrEqual(w.maxX, width - 8 + 0.5, "waiting pill right-aligned: \(at)")
                            }
                            if s.collapsed {
                                XCTAssertLessThan(w.width, ref.width, "a collapsed waiting pill is narrower: \(at)")
                            }
                            if let b = s.blocking {
                                XCTAssertLessThan(b.maxX, w.minX, "blocking left of waiting: \(at)")
                            }
                        } else {
                            XCTAssertFalse(s.collapsed, "no waiting pill to collapse: \(at)")
                        }

                        // The order of giving up: the branch first, the waiting pill second.
                        XCTAssertFalse(s.collapsed && s.secondaryVisible, "waiting pill collapsed while the branch still shows: \(at)")
                        if branchGone { XCTAssertFalse(s.secondaryVisible, "the branch came back as the row narrowed: \(at)") }
                        if collapsedSeen { XCTAssertTrue(s.collapsed, "the waiting pill expanded again as the row narrowed: \(at)") }
                        branchGone = branchGone || !s.secondaryVisible
                        collapsedSeen = collapsedSeen || s.collapsed

                        // While the branch shows it does not run under a pill.
                        if s.secondaryVisible, let line = s.secondaryFrame {
                            let firstPill = [s.blocking, s.waiting].compactMap { $0 }.map(\.minX).min()
                            if let firstPill {
                                XCTAssertLessThanOrEqual(line.maxX, firstPill + 0.5, "branch overlaps a pill: \(at)")
                            }
                            XCTAssertGreaterThanOrEqual(line.minX, 0, "branch inside the row: \(at)")
                        }
                    }
                }
            }
        }
    }

    func testAtTheNarrowestWidthWithBothPillsTheBranchIsGivenUpAndTheWaitingPillIsCollapsed() {
        for indented in [false, true] {
            let s = sample(blocking: 2, waiting: 7, width: Self.narrowest, indented: indented, branch: "main")
            XCTAssertFalse(s.secondaryVisible, "indented \(indented)")
            XCTAssertTrue(s.collapsed, "indented \(indented)")
        }
    }

    func testTheWaitingPillCollapsesToItsGlyphAndCountOnly() throws {
        // Find the first width at which it collapses, then check it is a real shrink and the count is intact.
        var collapsedItem: NavTabItem?
        for width in descendingWidths {
            let item = makeItem(width: width)
            apply(item, blocking: 2, waiting: 7)
            if item.waitingPillIsCollapsed { collapsedItem = item; break }
        }
        let item = try XCTUnwrap(collapsedItem, "the waiting pill collapses somewhere between \(Int(Self.widest)) and \(Int(Self.narrowest)) pt")
        let reference = makeItem(width: Self.widest)
        apply(reference, blocking: 2, waiting: 7)
        XCTAssertLessThan(try XCTUnwrap(item.waitingPillFrame).width, try XCTUnwrap(reference.waitingPillFrame).width)
        XCTAssertEqual(item.waitingPillText, "7", "collapsing keeps the count")
        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertEqual(item.waitingPillToolTip, "7 items waiting for you: nothing is stalled", "and the tooltip")
    }

    // MARK: Clicks

    func testEachPillRoutesItsOwnClickAndNeverTheRowsOrTheOthers() {
        let item = makeItem()
        var row = 0, own = 0, blocking = 0, waiting = 0
        item.onTap = { row += 1 }
        item.onBadgeTap = { own += 1 }
        item.onBlockingPillTap = { blocking += 1 }
        item.onWaitingPillTap = { waiting += 1 }

        item.simulateBlockingPillClick()
        XCTAssertEqual([row, own, blocking, waiting], [0, 0, 1, 0])
        item.simulateWaitingPillClick()
        XCTAssertEqual([row, own, blocking, waiting], [0, 0, 1, 1])
        item.simulatePillClick()
        XCTAssertEqual([row, own, blocking, waiting], [0, 1, 1, 1], "the own pill still goes to onBadgeTap")
        item.simulateRowClick()
        XCTAssertEqual([row, own, blocking, waiting], [1, 1, 1, 1])
    }

    func testAPillClickFallsBackToTheRowsTapWhenItHasNoHandlerOfItsOwn() {
        let item = makeItem()
        var row = 0
        item.onTap = { row += 1 }
        item.simulateBlockingPillClick()
        XCTAssertEqual(row, 1)
        item.simulateWaitingPillClick()
        XCTAssertEqual(row, 2)

        var blocking = 0
        item.onBlockingPillTap = { blocking += 1 }
        item.simulateWaitingPillClick()
        XCTAssertEqual(row, 3, "setting one pill's handler does not capture the other's clicks")
        item.simulateBlockingPillClick()
        XCTAssertEqual([row, blocking], [3, 1])
    }

    private func click(at pointInItem: NSPoint, on item: NavTabItem) throws -> NSEvent {
        let window = try XCTUnwrap(item.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: item.convert(pointInItem, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func center(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    func testTheRowRecognizerStandsDownForAClickOnEitherPillButNotElsewhere() throws {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        let blocking = try XCTUnwrap(item.blockingPillFrame), waiting = try XCTUnwrap(item.waitingPillFrame)
        let recognizer = NSClickGestureRecognizer()

        XCTAssertFalse(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: try click(at: center(blocking), on: item)),
                       "a click on the blocking pill is the pill's, not the row's")
        XCTAssertFalse(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: try click(at: center(waiting), on: item)),
                       "a click on the waiting pill is the pill's, not the row's")

        let title = try click(at: NSPoint(x: item.labelFrame.minX + 4, y: item.labelFrame.midY), on: item)
        XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: title))
        let branch = try XCTUnwrap(item.secondaryFrame)
        let onBranch = try click(at: NSPoint(x: branch.minX + 2, y: branch.midY), on: item)
        XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onBranch), "the branch text is the row's")
    }

    func testTheRowRecognizerTakesEveryClickOnceThePillsAreGone() throws {
        let item = makeItem()
        apply(item, blocking: 2, waiting: 7)
        let blocking = try XCTUnwrap(item.blockingPillFrame), waiting = try XCTUnwrap(item.waitingPillFrame)
        apply(item)
        let recognizer = NSClickGestureRecognizer()
        for frame in [blocking, waiting] {
            XCTAssertTrue(item.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: try click(at: center(frame), on: item)))
        }
    }

    // MARK: Built-ins keep their own pill

    func testABuiltInKeepsItsOwnPillOnTheTitleLineAndGainsTheNeedsYouPillOnTheSecondLine() throws {
        let item = makeItem(focus: builtIn("fred"), label: "Fred")
        item.setBadge(FocusBadge(pill: "12", detail: "Next: Eng sync", level: .needsYouNow,
                                 accessibilityLabel: "Fred, 12 unread, 2 approvals blocking", blocking: 2))
        relayout(item)

        XCTAssertEqual(item.pillText, "12")
        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertNil(item.waitingPillText)
        XCTAssertEqual(item.secondaryText, "Next: Eng sync", "the built-in keeps its own second line text")
        let own = try XCTUnwrap(item.pillFrame), blocking = try XCTUnwrap(item.blockingPillFrame)
        XCTAssertGreaterThan(own.midY, item.labelFrame.minY, "the own pill stays on the title line")
        XCTAssertLessThan(blocking.midY, item.labelFrame.minY, "the blocking pill is on the second line")
        XCTAssertFalse(own.intersects(blocking))
        XCTAssertTrue(item.showsBlockingHighlight)
    }

    func testTheOwnPillIsExactlyWhereItWasWithoutTheNeedsYouPills() throws {
        for tag in ["fred", "mother", "teri", "perri"] {
            let plain = makeItem(focus: builtIn(tag), label: tag.capitalized)
            plain.setBadge(FocusBadge(pill: "12", accessibilityLabel: "\(tag), 12"))
            relayout(plain)

            let busy = makeItem(focus: builtIn(tag), label: tag.capitalized)
            busy.setBadge(FocusBadge(pill: "12", level: .needsYouNow, accessibilityLabel: "\(tag), 12, 2 approvals blocking, 7 items waiting",
                                     blocking: 2, waiting: 7))
            relayout(busy)

            XCTAssertEqual(busy.pillText, "12", tag)
            assertSameRect(try XCTUnwrap(busy.pillFrame), try XCTUnwrap(plain.pillFrame), "own pill of \(tag)")
            assertSameRect(busy.labelFrame, plain.labelFrame, "title of \(tag)")
        }
    }

    func testABuiltInWithoutAnOwnBadgeStillGetsThePillsAndKeepsItsBaseLine() {
        let item = makeItem(focus: builtIn("perri"), label: "Perri", branch: "owner/repo#12")
        apply(item, blocking: 1, waiting: 3)
        XCTAssertNil(item.pillText)
        XCTAssertEqual(item.blockingPillText, "1")
        XCTAssertEqual(item.waitingPillText, "3")
        XCTAssertEqual(item.secondaryText, "owner/repo#12")

        apply(item)
        XCTAssertEqual(item.secondaryText, "owner/repo#12")
    }

    func testTheOwnPillOfABuiltInIsNeverTakenOverByTheNeedsYouCounts() {
        let item = makeItem(focus: builtIn("mother"), label: "Mother")
        item.setBadge(FocusBadge(pill: "5", detail: "5 running", accessibilityLabel: "Mother, 5 running"))
        XCTAssertEqual(item.pillText, "5")
        item.setBadge(FocusBadge(pill: "5", detail: "5 running", level: .needsYouNow,
                                 accessibilityLabel: "Mother, 5 running, 3 approvals blocking", blocking: 3))
        XCTAssertEqual(item.pillText, "5")
        XCTAssertEqual(item.blockingPillText, "3")
        item.setBadge(FocusBadge(pill: "5", detail: "5 running", accessibilityLabel: "Mother, 5 running"))
        XCTAssertEqual(item.pillText, "5")
        XCTAssertNil(item.blockingPillText)
    }
}

// MARK: - Contrast

/// The sidebar is always dark: its colours are fixed RGB, so a pair that reads in one appearance reads in
/// the other. Every ratio is pinned at WCAG AA (4.5:1) and compared across `.aqua` and `.darkAqua`.
final class NeedsYouPillsContrastTests: XCTestCase {

    private static let aa = 4.5

    /// Every foreground and backdrop pair the two pills and the row's labels can meet, by name.
    private func ratios() throws -> [String: Double] {
        let bar = Theme.bgBar
        let activeBackdrop = try over(Theme.cornflower.withAlphaComponent(0.12), bar)
        let blockingBackdrop = try over(Theme.blockingRowFill, bar)
        return [
            "white on the blocking pill": try contrast(.white, Theme.needsYouNow),
            "waiting text on the bar": try contrast(Theme.waitingPillText, bar),
            "waiting text on the selected row": try contrast(Theme.waitingPillText, activeBackdrop),
            "waiting text on the blocking row": try contrast(Theme.waitingPillText, blockingBackdrop),
            "selected label (white) on the blocking row": try contrast(.white, blockingBackdrop),
            "repo label on the blocking row": try contrast(Theme.navRepoColor, blockingBackdrop),
            "branch and nested label (muted) on the blocking row": try contrast(Theme.fgMuted, blockingBackdrop),
        ]
    }

    func testEveryPairMeetsAA() throws {
        for (name, ratio) in try ratios() {
            XCTAssertGreaterThanOrEqual(ratio, Self.aa, "\(name): \(ratio)")
        }
    }

    func testTheRatiosAreTheSameInLightAndDarkAppearances() throws {
        var perAppearance: [NSAppearance.Name: [String: Double]] = [:]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var computed: [String: Double] = [:]
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do { computed = try ratios() } catch { failure = error }
            }
            if let failure { throw failure }
            for (pair, ratio) in computed {
                XCTAssertGreaterThanOrEqual(ratio, Self.aa, "\(pair) under \(name.rawValue): \(ratio)")
            }
            perAppearance[name] = computed
        }
        let light = try XCTUnwrap(perAppearance[.aqua]), dark = try XCTUnwrap(perAppearance[.darkAqua])
        XCTAssertEqual(Set(light.keys), Set(dark.keys))
        for (pair, ratio) in light {
            XCTAssertEqual(ratio, try XCTUnwrap(dark[pair]), accuracy: 1e-9, "\(pair) differs between appearances")
        }
    }

    // Non-text contrast (WCAG 1.4.11) is 3:1, measured as drawn: the translucent colour blended over the bar.
    private static let nonText = 3.0

    private func nonTextRatios() throws -> [String: Double] {
        let bar = Theme.bgBar
        let outline = Theme.waitingPillText.withAlphaComponent(0.6)
        let activeBackdrop = try over(Theme.cornflower.withAlphaComponent(0.12), bar)
        let blockingBackdrop = try over(Theme.blockingRowFill, bar)
        return [
            "waiting outline on the bar": try contrast(try over(outline, bar), bar),
            "waiting outline on the selected row": try contrast(try over(outline, activeBackdrop), activeBackdrop),
            "waiting outline on the blocking row": try contrast(try over(outline, blockingBackdrop), blockingBackdrop),
            "red leading bar on the bar": try contrast(Theme.needsYouNow, bar),
            "red leading bar on the row's own red fill": try contrast(Theme.needsYouNow, blockingBackdrop),
        ]
    }

    func testNonTextElementsMeetThreeToOneInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var computed: [String: Double] = [:]
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do { computed = try nonTextRatios() } catch { failure = error }
            }
            if let failure { throw failure }
            XCTAssertEqual(computed.count, 5)
            for (pair, ratio) in computed {
                XCTAssertGreaterThanOrEqual(ratio, Self.nonText, "\(pair) under \(name.rawValue): \(ratio)")
            }
        }
    }

    func testTheOutlineIsTheAmberAtSixtyPercentAsDrawn() throws {
        let item = NavTabItem(focus: Focus(id: "x", agentTag: "cody", projectPath: "/p", isBuiltIn: false, org: "o"),
                              label: "L", secondary: "main", indented: false)
        item.setBadge(FocusBadge.needsYou(blocking: 0, waiting: 3))
        item.frame = NSRect(x: 0, y: 0, width: Theme.sidebarWidth, height: Theme.navItemSubtitleHeight)
        item.layoutSubtreeIfNeeded()
        try assertSameColor(item.waitingPillOutline.flatMap { NSColor(cgColor: $0) },
                            Theme.waitingPillText.withAlphaComponent(0.6), "the outline the pill draws")
    }

    func testTheBlockingFillIsTheRedAtAboutSixteenPercent() throws {
        let fill = try rgba(Theme.blockingRowFill), red = try rgba(Theme.needsYouNow)
        XCTAssertEqual(fill.a, 0.16, accuracy: 0.04)
        XCTAssertEqual(fill.r, red.r, accuracy: 0.01)
        XCTAssertEqual(fill.g, red.g, accuracy: 0.01)
        XCTAssertEqual(fill.b, red.b, accuracy: 0.01)
    }

    func testTheWaitingTextIsNotTheBlockingRed() throws {
        let waiting = try rgba(Theme.waitingPillText), red = try rgba(Theme.needsYouNow)
        let distance = abs(waiting.r - red.r) + abs(waiting.g - red.g) + abs(waiting.b - red.b)
        XCTAssertGreaterThan(distance, 0.5, "the two pills must not read as the same class")
    }
}
