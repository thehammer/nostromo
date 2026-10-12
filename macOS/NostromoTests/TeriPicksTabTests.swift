import XCTest
import AppKit

// Slice T4: the Picks tab of the Teri surface. Picks are Teri's agent-chosen next
// actions across all four sources. The view is fed by a `WorkStore` we seed
// ourselves and its outgoing daemon frames are captured from `store.sendFrame`.
// Nothing here asserts on pixels or depends on a window server beyond one offscreen
// window. Nothing reads the wall clock or waits a fixed time either: "now" is an
// injected, fixed Date; a change that hops through the main queue is awaited by
// flushing the main queue until the state holds (pass or fail depends on state,
// never on elapsed time); and a "nothing was sent" check flushes the main queue
// (what the view had queued has then run) before looking.
//
// Day arithmetic is pinned to America/Chicago with a fixed clock, so results do
// not depend on the machine running the tests. October 2026 is still CDT (-05:00).

// MARK: - Helpers

/// Run everything already queued on the main queue, and whatever that queues in
/// turn (a few generations). Returns when the queue has been serviced, however
/// long that takes; there is no deadline.
private func flushMain(generations: Int = 3) {
    for _ in 0..<generations {
        var ran = false
        DispatchQueue.main.async { ran = true }
        while !ran { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }
}

/// Flush the main queue until `condition` holds (true), giving up after a generous
/// number of turns (false). The bound counts turns, not seconds.
@discardableResult
private func waitUntil(maxTurns: Int = 500, _ condition: () -> Bool) -> Bool {
    for _ in 0..<maxTurns {
        if condition() { return true }
        flushMain(generations: 1)
    }
    return condition()
}

/// Let anything already queued on the main queue run, so a "nothing happened"
/// assertion is not just a view that has not caught up yet.
private func drain() { flushMain() }

private final class FrameLog {
    var frames: [WorkClientMessage] = []

    var firstOpenCount: Int { frames.filter { $0 == .picksRefresh(reason: "first_open") }.count }
    var manualCount: Int { frames.filter { $0 == .picksRefresh(reason: "manual") }.count }
    var detailRequests: [(requestId: String, itemId: String)] {
        frames.compactMap {
            if case .detailRequest(let r, let i) = $0 { return (r, i) }
            return nil
        }
    }
}

private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// "2026-10-11T08:00:00-05:00" style (or any RFC 3339) to a Date.
private func at(_ rfc3339: String) -> Date { isoParser.date(from: rfc3339)! }

/// Fixed zone and locale: wording and day boundaries must not depend on the machine.
private let chicago: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}()

/// Sunday 11 October 2026, 08:00 in Chicago.
private let morning = at("2026-10-11T08:00:00-05:00")

private let client = NostromodClient(socketPath: "/dev/null")

/// A pick as the daemon sends it.
private func pick(_ itemId: String, _ source: String, _ title: String, _ reason: String,
                  done: Bool = false) -> [String: Any] {
    ["item_id": itemId, "source": source, "title": title, "reason": reason, "done_since": done]
}

/// A snapshot decoded exactly the way the app does: as the payload of a `teri_picks` frame.
private func snapshot(generatedAt: String? = nil, generating: Bool = false, unavailable: [String] = [],
                      items: [[String: Any]] = [], error: String? = nil) -> PicksSnapshot {
    var picks: [String: Any] = ["generating": generating, "unavailable_sources": unavailable, "items": items]
    if let generatedAt { picks["generated_at"] = generatedAt }
    if let error { picks["error"] = error }
    let frame: [String: Any] = ["type": "teri_picks", "picks": picks]
    let raw = try! JSONSerialization.data(withJSONObject: frame)
    let obj = try! JSONSerialization.jsonObject(with: raw) as! [String: Any]
    guard case .teriPicks(let decoded) = client.decode(type_: "teri_picks", json: obj, raw: raw) else {
        fatalError("picks did not decode")
    }
    return decoded
}

/// Five picks across the four sources; the last one was finished since Teri chose it.
private let fiveItems: [[String: Any]] = [
    pick("todo:7", "todos", "Reply to Dana about the budget", "Overdue by two days"),
    pick("doc:alpha:docs/bugs/open/webhook.md", "repo_docs", "Fix webhook retry bug", "Open P1 bug in alpha"),
    pick("jira:RM-12", "jira", "RM-12 Refund flow", "Due tomorrow and in review"),
    pick("sentry:4411", "sentry", "TypeError in checkout", "Fresh fatal in production"),
    pick("jira:RM-3", "jira", "RM-3 Old migration", "Was blocking the release", done: true),
]
private let fiveSources = ["Todos", "Repo docs", "Jira", "Sentry", "Jira"]

/// A live work item as the daemon would send it, optionally with sent markers.
private func liveItem(_ id: String, source: String, title: String, sent: [String] = []) -> WorkItem {
    var f: [String: Any] = ["id": id, "source": source, "kind": "item", "title": title, "search_text": title]
    f["sent"] = sent.map {
        ["kind": "focus", "target_id": "focus-\($0)", "label": $0, "created_at": "2026-10-09T15:00:00Z"]
    }
    return WorkTestSupport.makeItem(f)
}

private func seedItem(_ store: WorkStore, _ item: WorkItem) {
    store.apply(snapshot: item.source, group: nil, items: [item])
}

/// Picks generated an hour before `morning`: made today, so not stale.
private func freshSnapshot(items: [[String: Any]] = fiveItems) -> PicksSnapshot {
    snapshot(generatedAt: isoParser.string(from: morning.addingTimeInterval(-3_600)), items: items)
}

/// Picks from three days before `morning`: stale in any time zone.
private func staleSnapshot(items: [[String: Any]] = fiveItems) -> PicksSnapshot {
    snapshot(generatedAt: isoParser.string(from: morning.addingTimeInterval(-3 * 86_400)), items: items)
}

// MARK: - Colour maths (WCAG 2.x)

private func srgbComponents(_ color: NSColor) -> [CGFloat] {
    guard let c = color.usingColorSpace(.sRGB) else {
        XCTFail("colour \(color) has no sRGB representation")
        return [0, 0, 0, 1]
    }
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}

/// `color` as seen over an opaque `backdrop` (alpha composited), as sRGB r, g, b.
private func composited(_ color: NSColor, over backdrop: NSColor) -> [CGFloat] {
    let f = srgbComponents(color), b = srgbComponents(backdrop)
    return (0..<3).map { f[$0] * f[3] + b[$0] * (1 - f[3]) }
}

private func relativeLuminance(_ rgb: [CGFloat]) -> Double {
    let lin = rgb.map { v -> Double in
        let c = Double(v)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
}

/// WCAG contrast ratio of text `color` drawn on the opaque `background`, 1...21.
private func contrastRatio(_ color: NSColor, on background: NSColor) -> Double {
    let l1 = relativeLuminance(composited(color, over: background))
    let l2 = relativeLuminance(composited(background, over: background))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

private func sameColour(_ a: NSColor, _ b: NSColor) -> Bool {
    zip(srgbComponents(a), srgbComponents(b)).allSatisfy { abs($0 - $1) < 0.002 }
}

// MARK: - The view

final class TeriPicksTabTests: XCTestCase {
    private final class ViewRig {
        let store = WorkStore()
        let log = FrameLog()
        let clock: TestClock
        let view: TeriPicksView

        /// `window`: host the view in it (for the "window became key" paths).
        init(now: Date = morning, picks: PicksSnapshot? = nil, window: NSWindow? = nil,
             seed: (WorkStore) -> Void = { _ in }) {
            let clock = TestClock(now)
            self.clock = clock
            let log = self.log
            store.sendFrame = { log.frames.append($0) }
            if let picks { store.apply(picks: picks) }
            seed(store)
            view = TeriPicksView(store: store, now: { clock.now }, calendar: chicago)
            if let window, let content = window.contentView {
                view.frame = content.bounds
                content.addSubview(view)
            }
        }

        var titles: [String] { view.visibleRows.map(\.title) }
    }

    private func titles(of items: [[String: Any]]) -> [String] { items.map { $0["title"] as! String } }

    // MARK: Rows

    func testFivePicksRenderInOrderWithSourceTitleAndReason() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))

        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 }, "rows: \(rig.titles)")
        let rows = rig.view.visibleRows
        XCTAssertEqual(rows.map(\.title), titles(of: fiveItems), "snapshot order is kept")
        XCTAssertEqual(rows.map(\.reason), fiveItems.map { $0["reason"] as! String })
        for (row, word) in zip(rows, fiveSources) {
            XCTAssertTrue(row.sourceText.contains(word), "\(row.sourceText) should name the source \(word)")
        }
    }

    func testOnlyADoneSincePickIsMarkedDoneAndStruckThrough() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        let rows = rig.view.visibleRows

        for row in rows.dropLast() {
            XCTAssertNil(row.doneSinceText, row.title)
            XCTAssertFalse(row.isStruck, row.title)
            XCTAssertFalse(row.accessibilityLabel.contains("done since"), row.accessibilityLabel)
        }
        let done = rows[4]
        XCTAssertEqual(done.doneSinceText, "done since")
        XCTAssertTrue(done.isStruck)
        XCTAssertTrue(done.accessibilityLabel.contains("done since"), done.accessibilityLabel)
    }

    func testTheAccessibilityLabelNamesSourceTitleAndReason() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })

        let label = rig.view.visibleRows[3].accessibilityLabel
        XCTAssertTrue(label.contains("Sentry"), label)
        XCTAssertTrue(label.contains("TypeError in checkout"), label)
        XCTAssertTrue(label.contains("Fresh fatal in production"), label)
    }

    func testARowSaysWhereItWasSentWhenTheLiveItemHasASentMarker() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems)) { store in
            seedItem(store, liveItem("jira:RM-12", source: "jira", title: "RM-12 Refund flow", sent: ["Fix webhook"]))
        }

        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        XCTAssertEqual(rig.view.visibleRows[2].sentText, "Sent to Fix webhook")
    }

    func testAPickWithNoLiveItemOrNoSentMarkerHasNoSentText() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems)) { store in
            // todo:7 is live but was never sent anywhere; the other four have no live item at all.
            seedItem(store, liveItem("todo:7", source: "todos", title: "Reply to Dana about the budget"))
        }

        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        XCTAssertEqual(rig.view.visibleRows.map(\.sentText), [String?](repeating: nil, count: 5))
    }

    func testSeveralSentMarkersAreAllNamed() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems)) { store in
            seedItem(store, liveItem("jira:RM-12", source: "jira", title: "RM-12 Refund flow",
                                     sent: ["Fix webhook", "Refund spike"]))
        }

        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        let text = rig.view.visibleRows[2].sentText ?? ""
        XCTAssertTrue(text.hasPrefix("Sent to"), text)
        XCTAssertTrue(text.contains("Fix webhook"), text)
        XCTAssertTrue(text.contains("Refund spike"), text)
    }

    func testASentMarkerThatArrivesLaterShowsOnTheRow() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        XCTAssertNil(rig.view.visibleRows[2].sentText)

        seedItem(rig.store, liveItem("jira:RM-12", source: "jira", title: "RM-12 Refund flow", sent: ["Fix webhook"]))

        XCTAssertTrue(waitUntil { rig.view.visibleRows[2].sentText == "Sent to Fix webhook" },
                      String(describing: rig.view.visibleRows[2].sentText))
    }

    // MARK: Going to where a pick was sent

    private func returnKey(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 36, chars: String = "\r") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// Picks with a sent marker on RM-12 only ("Fix webhook"); the rig records what was opened.
    private func sentRig() -> (rig: ViewRig, opened: () -> [(pick: String, target: String)]) {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems)) { store in
            seedItem(store, liveItem("jira:RM-12", source: "jira", title: "RM-12 Refund flow", sent: ["Fix webhook"]))
        }
        var opened: [(pick: String, target: String)] = []
        rig.view.onOpenSent = { pick, marker in opened.append((pick.itemId, marker.targetId)) }
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 && rig.view.visibleRows[2].sentText != nil })
        return (rig, { opened })
    }

    private func customActions(in view: NSView) -> [NSAccessibilityCustomAction] {
        rigAllSubviews(of: view).flatMap { $0.accessibilityCustomActions() ?? [] }
    }

    func testARowWithASentLineOffersAGoToCustomActionThatOpensTheMarker() throws {
        let (rig, opened) = sentRig()

        let actions = customActions(in: rig.view)

        XCTAssertEqual(actions.count, 1, "only the pick that was sent somewhere has one: \(actions.map(\.name))")
        let action = try XCTUnwrap(actions.first)
        XCTAssertTrue(action.name.hasPrefix("Go to"), action.name)
        XCTAssertTrue(action.name.contains("Sent to Fix webhook"), action.name)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(opened().map(\.pick), ["jira:RM-12"])
        XCTAssertEqual(opened().map(\.target), ["focus-Fix webhook"])
    }

    func testCommandReturnOnTheSelectedPickGoesToWhereItWasSent() {
        let (rig, opened) = sentRig()
        rig.view.select(itemId: "jira:RM-12")

        rig.view.keyDown(with: returnKey(.command))

        XCTAssertEqual(opened().map(\.target), ["focus-Fix webhook"])
    }

    func testCommandKeypadEnterGoesThereToo() {
        let (rig, opened) = sentRig()
        rig.view.select(itemId: "jira:RM-12")

        rig.view.keyDown(with: returnKey([.command, .numericPad], code: 76, chars: "\u{3}"))

        XCTAssertEqual(opened().count, 1)
    }

    func testPlainReturnOnTheSelectedPickDoesNotGoAnywhere() {
        let (rig, opened) = sentRig()
        rig.view.select(itemId: "jira:RM-12")

        rig.view.keyDown(with: returnKey())

        XCTAssertTrue(opened().isEmpty)
    }

    func testCommandReturnOnAPickThatWasNeverSentDoesNothing() {
        let (rig, opened) = sentRig()
        rig.view.select(itemId: "sentry:4411")

        rig.view.keyDown(with: returnKey(.command))

        XCTAssertTrue(opened().isEmpty)
        XCTAssertFalse(rig.view.openSentOfSelection())
    }

    func testCommandReturnWithNoPickSelectedDoesNothing() {
        let (rig, opened) = sentRig()

        rig.view.keyDown(with: returnKey(.command))

        XCTAssertTrue(opened().isEmpty)
        XCTAssertFalse(rig.view.openSentOfSelection())
    }

    // MARK: Header, empty state

    func testBeforeAnySnapshotArrivesTheHeaderSaysThereAreNoPicksYet() {
        let rig = ViewRig()

        XCTAssertNil(rig.store.picks)
        XCTAssertEqual(rig.view.headerText, "No picks yet")
        XCTAssertTrue(rig.view.visibleRows.isEmpty)
    }

    func testASnapshotWithoutAGenerationTimeAlsoSaysNoPicksYet() {
        let rig = ViewRig(picks: snapshot(generatedAt: nil, items: []))

        XCTAssertTrue(waitUntil { rig.view.headerText == "No picks yet" }, rig.view.headerText)
    }

    func testTheHeaderSaysWhenThePicksWereGenerated() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))

        XCTAssertTrue(waitUntil { rig.view.headerText == "Generated 2 h ago" }, rig.view.headerText)
    }

    func testAnEmptySnapshotKeepsItsHeaderAndSaysTeriHasNotPickedAnything() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: []))

        XCTAssertTrue(waitUntil { rig.view.headerText == "Generated 2 h ago" }, rig.view.headerText)
        XCTAssertTrue(rig.view.visibleRows.isEmpty)
        XCTAssertEqual(rig.view.emptyStateText, "Teri has not picked anything yet.")
    }

    func testTheEmptyStateIsNotShownWhileThereAreRowsOrWhileGenerating() {
        let withRows = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { withRows.view.visibleRows.count == 5 })
        XCTAssertNil(withRows.view.emptyStateText)

        let generating = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", generating: true, items: []))
        XCTAssertTrue(waitUntil { generating.view.isRefreshingVisible })
        XCTAssertNil(generating.view.emptyStateText, "an empty list that is being generated is not 'nothing picked'")
    }

    // MARK: Generated-at wording

    func testGeneratedTextReadsJustNowForUnderAMinute() {
        XCTAssertEqual(TeriPicksView.generatedText(morning.addingTimeInterval(-30), now: morning, calendar: chicago),
                       "Generated just now")
        XCTAssertEqual(TeriPicksView.generatedText(morning, now: morning, calendar: chicago), "Generated just now")
    }

    func testGeneratedTextCountsMinutesWithinTheHour() {
        XCTAssertEqual(TeriPicksView.generatedText(morning.addingTimeInterval(-5 * 60), now: morning, calendar: chicago),
                       "Generated 5 min ago")
        XCTAssertEqual(TeriPicksView.generatedText(morning.addingTimeInterval(-59 * 60), now: morning, calendar: chicago),
                       "Generated 59 min ago")
    }

    func testGeneratedTextCountsHoursWithinTheSameCalendarDay() {
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-11T06:00:00-05:00"), now: morning, calendar: chicago),
                       "Generated 2 h ago")
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-11T00:00:00-05:00"), now: morning, calendar: chicago),
                       "Generated 8 h ago")
    }

    func testGeneratedTextSaysYesterdayWithAClockTimeAcrossMidnightEvenWhenUnder24Hours() {
        // 8.5 hours before `morning`, but the day before.
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-10T23:30:00-05:00"), now: morning, calendar: chicago),
                       "Generated yesterday 23:30")
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-10T14:05:00-05:00"), now: morning, calendar: chicago),
                       "Generated yesterday 14:05")
        // More than 24 hours before, still the calendar day before.
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-10T06:00:00-05:00"), now: morning, calendar: chicago),
                       "Generated yesterday 06:00")
    }

    func testGeneratedTextUsesTheCalendarsTimeZoneForTheClockTime() {
        // 19:05 UTC is 14:05 in Chicago.
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-10T19:05:00Z"), now: morning, calendar: chicago),
                       "Generated yesterday 14:05")
    }

    func testGeneratedTextShowsTheDateAndTimeForOlderPicks() {
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-08T14:05:00-05:00"), now: morning, calendar: chicago),
                       "Generated Oct 8 14:05")
        XCTAssertEqual(TeriPicksView.generatedText(at("2026-10-09T14:05:00-05:00"), now: morning, calendar: chicago),
                       "Generated Oct 9 14:05")
    }

    // MARK: Refreshing

    func testWhileGeneratingTheOldPicksStayVisibleWithARefreshingIndicatorAndADisabledButton() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-10T14:05:00-05:00", generating: true, items: fiveItems))

        XCTAssertTrue(waitUntil { rig.view.isRefreshingVisible })
        XCTAssertEqual(rig.view.visibleRows.count, 5, "old picks are not blanked while the new ones are made")
        XCTAssertEqual(rig.titles, titles(of: fiveItems))
        XCTAssertEqual(rig.view.refreshingText, "Refreshing…")
        XCTAssertFalse(rig.view.isRefreshButtonEnabled)
        XCTAssertEqual(rig.view.refreshButtonTitle, "Refresh picks")

        rig.view.pressRefresh()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "a refresh is already running: \(rig.log.frames)")
    }

    func testWhenGenerationFinishesTheNewPicksReplaceTheOldAndTheButtonIsBackAndSendsOneManualRefresh() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", generating: true, items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.isRefreshingVisible && rig.view.visibleRows.count == 5 })

        let fresh = [pick("jira:RM-99", "jira", "RM-99 Brand new pick", "Just appeared")]
        rig.store.apply(picks: snapshot(generatedAt: "2026-10-11T07:59:00-05:00", generating: false, items: fresh))

        XCTAssertTrue(waitUntil { rig.titles == ["RM-99 Brand new pick"] }, "rows: \(rig.titles)")
        XCTAssertFalse(rig.view.isRefreshingVisible)
        XCTAssertNil(rig.view.refreshingText)
        XCTAssertTrue(rig.view.isRefreshButtonEnabled)
        XCTAssertEqual(rig.view.refreshButtonTitle, "Refresh picks")

        rig.view.pressRefresh()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "manual")])
    }

    func testTheRefreshButtonIsDisabledWhileDisconnectedAndDoesNothing() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })

        rig.store.setConnected(false)

        XCTAssertTrue(waitUntil { !rig.view.isRefreshButtonEnabled })
        rig.view.pressRefresh()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "\(rig.log.frames)")

        rig.store.setConnected(true)
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })
    }

    // MARK: Unavailable sources and errors

    private func note(_ unavailable: [String]) -> String? {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", unavailable: unavailable,
                                          items: fiveItems))
        _ = waitUntil { rig.view.visibleRows.count == 5 }
        return rig.view.unavailableNote
    }

    func testNoUnavailableSourcesMeansNoNote() {
        XCTAssertNil(note([]))
    }

    func testOneUnavailableSourceIsNamedAndTheExclusionSaid() {
        XCTAssertEqual(note(["sentry"]), "Sentry unavailable; picks exclude Sentry")
    }

    func testTwoUnavailableSourcesAreJoinedWithAnd() {
        XCTAssertEqual(note(["jira", "sentry"]), "Jira and Sentry unavailable; picks exclude Jira and Sentry")
    }

    func testThreeOrMoreUnavailableSourcesAreCommaSeparatedWithAnAndBeforeTheLast() {
        XCTAssertEqual(note(["todos", "jira", "sentry"]),
                       "Todos, Jira and Sentry unavailable; picks exclude Todos, Jira and Sentry")
        XCTAssertEqual(note(["todos", "repo_docs", "jira", "sentry"]),
                       "Todos, Repo docs, Jira and Sentry unavailable; picks exclude Todos, Repo docs, Jira and Sentry")
    }

    func testUnavailableSourcesAreNamedInSourceOrderWhateverOrderTheDaemonSentThem() {
        XCTAssertEqual(note(["sentry", "todos", "jira"]),
                       "Todos, Jira and Sentry unavailable; picks exclude Todos, Jira and Sentry")
    }

    func testTheNoteStaysAlongsideTheRows() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", unavailable: ["sentry"],
                                          items: fiveItems))

        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        XCTAssertNotNil(rig.view.unavailableNote)
    }

    func testAnErrorIsShownVerbatimAndTheRowsAreKept() {
        let message = "Teri could not reach the model: quota exceeded (429)"
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", items: fiveItems, error: message))

        XCTAssertTrue(waitUntil { rig.view.errorNote == message }, String(describing: rig.view.errorNote))
        XCTAssertEqual(rig.view.visibleRows.count, 5, "a failed refresh keeps the last good picks")
    }

    func testNoErrorMeansNoErrorNoteAndItClearsWhenTheNextSnapshotHasNone() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", items: fiveItems,
                                          error: "model timed out"))
        XCTAssertTrue(waitUntil { rig.view.errorNote == "model timed out" })

        rig.store.apply(picks: snapshot(generatedAt: "2026-10-11T07:30:00-05:00", items: fiveItems))

        XCTAssertTrue(waitUntil { rig.view.errorNote == nil })
        XCTAssertNil(ViewRig(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", items: [])).view.errorNote)
    }

    // MARK: Selection

    func testSelectingARowRecordsItAndReportsThePick() {
        let rig = ViewRig(picks: snapshot(generatedAt: "2026-10-11T06:00:00-05:00", items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 })
        var selected: [Pick?] = []
        rig.view.onSelect = { selected.append($0) }

        rig.view.select(itemId: "jira:RM-12")

        XCTAssertEqual(rig.view.selectedPickId, "jira:RM-12")
        XCTAssertEqual(selected.compactMap { $0?.itemId }, ["jira:RM-12"])
        XCTAssertEqual(selected.last.flatMap { $0 }?.title, "RM-12 Refund flow")
    }

    // MARK: First open of the day

    private let yesterdayLate = "2026-10-10T23:30:00-05:00"   // before the start of `morning`'s day
    private let earlierToday = "2026-10-11T00:30:00-05:00"

    func testAStaleSnapshotCausesExactlyOneFirstOpenRequestHoweverOftenTheTabIsShownOrTheStoreChanges() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
        rig.view.tabDidShow()
        rig.view.tabDidShow()
        rig.store.apply(status: SourceStatus(source: .jira, state: .fresh, count: 1))
        seedItem(rig.store, liveItem("todo:7", source: "todos", title: "Reply to Dana about the budget"))
        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))   // same stale data again
        drain()

        XCTAssertEqual(rig.log.firstOpenCount, 1, "frames: \(rig.log.frames)")
        XCTAssertEqual(rig.log.frames.count, 1, "nothing else is sent: \(rig.log.frames)")
    }

    func testPicksGeneratedEarlierTodayAreNotRegenerated() {
        let rig = ViewRig(picks: snapshot(generatedAt: earlierToday, items: fiveItems))

        rig.view.tabDidShow()
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "\(rig.log.frames)")
    }

    func testNothingIsRequestedWhileTheDaemonIsAlreadyGenerating() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, generating: true, items: fiveItems))

        rig.view.tabDidShow()
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "\(rig.log.frames)")
    }

    func testNothingIsRequestedBeforeAnySnapshotArrivesButAStaleOneArrivingWhileShownFiresOnce() {
        let rig = ViewRig()

        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "the daemon has not told us anything yet: \(rig.log.frames)")

        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")

        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        drain()
        XCTAssertEqual(rig.log.firstOpenCount, 1, "frames: \(rig.log.frames)")
    }

    func testASnapshotWithNoGenerationTimeAndNoItemsCountsAsStale() {
        let rig = ViewRig(picks: snapshot(generatedAt: nil, items: []))

        rig.view.tabDidShow()

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
    }

    func testTheDayBoundaryIsLocalMidnightNotTwentyFourHours() {
        // Two minutes old, but from yesterday in Chicago.
        let justAfterMidnight = at("2026-10-11T00:01:00-05:00")
        let rig = ViewRig(now: justAfterMidnight,
                          picks: snapshot(generatedAt: "2026-10-10T23:59:00-05:00", items: fiveItems))

        rig.view.tabDidShow()

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
    }

    func testPicksFromJustAfterLocalMidnightAreFreshForTheRestOfThatDay() {
        let lateEvening = at("2026-10-11T23:59:00-05:00")
        let rig = ViewRig(now: lateEvening,
                          picks: snapshot(generatedAt: "2026-10-11T00:01:00-05:00", items: fiveItems))

        rig.view.tabDidShow()
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "\(rig.log.frames)")
    }

    func testAViewThatWasNeverShownNeverAsksForFirstOpenPicks() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))

        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "a background tab does not trigger a generation: \(rig.log.frames)")
    }

    func testAFailedGenerationDoesNotMakeTheTabAskAgainTheSameDay() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })

        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, generating: true, items: fiveItems))
        rig.store.apply(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems, error: "model timed out"))
        rig.view.tabDidShow()
        drain()

        XCTAssertEqual(rig.log.firstOpenCount, 1, "no retry loop: \(rig.log.frames)")
    }

    func testAfterTheDayRollsOverShowingTheTabAgainAsksOnceMore() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })

        rig.clock.now = morning.addingTimeInterval(24 * 3_600)
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 2 }, "frames: \(rig.log.frames)")

        rig.view.tabDidShow()
        drain()
        XCTAssertEqual(rig.log.firstOpenCount, 2, "still once per day: \(rig.log.frames)")
    }

    func testPressingRefreshOnStalePicksSendsOnlyAManualRequest() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })

        rig.view.pressRefresh()

        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "manual")])
    }

    func testPressingRefreshAfterTheFirstOpenRequestStillSendsAManualRequest() {
        let rig = ViewRig(picks: snapshot(generatedAt: yesterdayLate, items: fiveItems))
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })
        rig.log.frames.removeAll()

        rig.view.pressRefresh()

        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "manual")])
    }

    // MARK: First open: only on a real activation, only once it was really sent

    private let nextDay = at("2026-10-12T00:05:00-05:00")

    private func jiraStatusChange() -> SourceStatus { SourceStatus(source: .jira, state: .fresh, count: 1) }

    private func postKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    func testShowingTheTabWhileDisconnectedSendsNothingAndAsksExactlyOnceWhenTheConnectionReturns() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.setConnected(false) }

        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "there is no connection to send on: \(rig.log.frames)")

        rig.store.setConnected(true)
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 },
                      "the day was not used up by the attempt that could not send: \(rig.log.frames)")

        rig.store.apply(status: jiraStatusChange())
        rig.store.setConnected(false)
        rig.store.setConnected(true)
        rig.view.tabDidShow()
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")], "still exactly one")
    }

    func testShowingTheTabWithNoWayToSendAsksExactlyOnceWhenOneAppears() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.sendFrame = nil }

        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty)

        let log = rig.log
        rig.store.sendFrame = { log.frames.append($0) }
        // Setting the sender is not itself observable; any store change lets the view look again.
        rig.store.apply(status: jiraStatusChange())
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")

        rig.store.apply(status: jiraStatusChange())
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")])
    }

    func testARequestThatCouldNotBeSentIsNotSentLaterIfTheTabWasLeftInTheMeantime() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.setConnected(false) }
        rig.view.tabDidShow()
        rig.view.tabDidLeave()

        rig.store.setConnected(true)
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "the tab is not showing: \(rig.log.frames)")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "showing it again asks: \(rig.log.frames)")
    }

    // MARK: A pending first open is retried only just after the activation that wanted it
    //
    // A first_open goes out only on a person arriving (the tab shown, the window coming to
    // the front). If it cannot go out at that moment (no connection, no snapshot yet), a store
    // change may carry it out, but only within `TeriPicksTab.pendingRetryWindow` of that
    // activation. A reconnect at 3 a.m. with the tab left open must send nothing.

    private var retryWindow: TimeInterval { TeriPicksTab.pendingRetryWindow }

    func testThePendingRetryWindowIsThirtySeconds() {
        XCTAssertEqual(TeriPicksTab.pendingRetryWindow, 30)
    }

    func testAReconnectLongAfterTheTabWasShownDisconnectedSendsNothingAndShowingItAgainDoes() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.setConnected(false) }
        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "no connection to send on: \(rig.log.frames)")

        rig.clock.now = morning.addingTimeInterval(retryWindow + 1)   // nobody has touched it since
        rig.store.setConnected(true)
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "an unattended reconnect must not start a generation: \(rig.log.frames)")

        rig.store.apply(status: jiraStatusChange())
        rig.store.apply(picks: staleSnapshot())
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "nor may any later store change: \(rig.log.frames)")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "a fresh activation asks: \(rig.log.frames)")
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")])
    }

    func testAReconnectJustInsideTheWindowStillSendsTheFirstOpen() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.setConnected(false) }
        rig.view.tabDidShow()
        drain()

        rig.clock.now = morning.addingTimeInterval(retryWindow - 1)
        rig.store.setConnected(true)

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")])
    }

    func testTheWindowIsMeasuredFromTheActivationNotFromTheLastStoreChange() {
        let rig = ViewRig(picks: staleSnapshot()) { $0.setConnected(false) }
        rig.view.tabDidShow()
        drain()

        // Store changes keep arriving while still disconnected; each is inside the window of the
        // activation, but the one that finally carries the reconnect is not.
        rig.clock.now = morning.addingTimeInterval(retryWindow - 5)
        rig.store.apply(status: jiraStatusChange())
        drain()
        rig.clock.now = morning.addingTimeInterval(retryWindow + 5)
        rig.store.setConnected(true)
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "\(rig.log.frames)")
    }

    func testAPickSnapshotArrivingAfterTheWindowDoesNotStartAGenerationButAnActivationDoes() {
        let rig = ViewRig()
        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "nothing to go on yet: \(rig.log.frames)")

        rig.clock.now = morning.addingTimeInterval(retryWindow + 1)
        rig.store.apply(picks: staleSnapshot())
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "the snapshot came in unattended: \(rig.log.frames)")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
    }

    func testAPickSnapshotArrivingInsideTheWindowStillStartsTheGeneration() {
        let rig = ViewRig()
        rig.view.tabDidShow()
        drain()

        rig.clock.now = morning.addingTimeInterval(retryWindow - 1)
        rig.store.apply(picks: staleSnapshot())

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
    }

    func testTheWindowComingToTheFrontIsAnActivationThatStartsAFreshRetryWindow() {
        let win = makeRigWindow(self)
        let rig = ViewRig(picks: staleSnapshot(), window: win) { $0.setConnected(false) }
        rig.view.tabDidShow()
        drain()

        // Long after the tab was shown, the person comes back to the window: a new activation.
        rig.clock.now = morning.addingTimeInterval(10 * retryWindow)
        postKey(win)
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "still no connection: \(rig.log.frames)")

        rig.clock.now = morning.addingTimeInterval(10 * retryWindow + retryWindow - 1)
        rig.store.setConnected(true)

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 },
                      "inside the window of the key activation: \(rig.log.frames)")
    }

    func testAnActivationThatSentItsFirstOpenLeavesNothingPendingForLaterStoreChanges() {
        let rig = ViewRig(picks: staleSnapshot())
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })

        rig.clock.now = morning.addingTimeInterval(retryWindow + 1)
        rig.store.setConnected(false)
        rig.store.setConnected(true)
        rig.store.apply(picks: staleSnapshot())
        drain()

        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")], "\(rig.log.frames)")
    }

    func testTheHostingWindowBecomingKeyAsksWhenTheTabIsShowingAndANewDayHasStarted() {
        let window = makeRigWindow(self)
        let rig = ViewRig(picks: freshSnapshot(), window: window)
        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "today's picks exist: \(rig.log.frames)")

        rig.clock.now = nextDay   // the tab stayed open across midnight; today's picks are not made yet
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "time passing alone asks nothing: \(rig.log.frames)")

        postKey(window)
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")

        postKey(window)
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")], "once per day, key window or not")
    }

    func testTheWindowBecomingKeyAfterTheDayWasAlreadyRequestedAsksNothingMore() {
        let window = makeRigWindow(self)
        let rig = ViewRig(picks: staleSnapshot(), window: window)
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })

        postKey(window)
        drain()

        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")])
    }

    func testTheWindowBecomingKeyAsksNothingWhileTheTabIsNotShowing() {
        let window = makeRigWindow(self)
        let rig = ViewRig(picks: staleSnapshot(), window: window)

        postKey(window)
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "never shown: \(rig.log.frames)")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })
        rig.view.tabDidLeave()
        rig.clock.now = nextDay
        postKey(window)
        drain()
        XCTAssertEqual(rig.log.firstOpenCount, 1, "left the tab: \(rig.log.frames)")
    }

    func testAnotherWindowBecomingKeyAsksNothing() {
        let window = makeRigWindow(self)
        let other = makeRigWindow(self)
        let rig = ViewRig(picks: freshSnapshot(), window: window)
        rig.view.tabDidShow()
        rig.clock.now = nextDay

        postKey(other)
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty, "not this view's window: \(rig.log.frames)")

        postKey(window)
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })
    }

    func testATabLeftShowingAcrossMidnightNeverAsksFromTheClockOrFromStoreChanges() {
        let rig = ViewRig(picks: freshSnapshot())
        rig.view.tabDidShow()
        drain()
        XCTAssertTrue(rig.log.frames.isEmpty)

        rig.clock.now = nextDay
        rig.view.clockTick()
        rig.view.clockTick()
        rig.store.apply(status: jiraStatusChange())
        drain()

        XCTAssertTrue(rig.log.frames.isEmpty, "the 60 s clock must never request picks: \(rig.log.frames)")
        XCTAssertEqual(rig.view.headerText, "Generated yesterday 07:00", "the clock does keep the header true")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "showing the tab after midnight asks: \(rig.log.frames)")
        drain()
        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "first_open")])
    }

    func testTheClockAcrossMidnightDoesNotAskAgainAfterADayThatWasAlreadyRequestedEither() {
        let rig = ViewRig(picks: staleSnapshot())
        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 })

        rig.clock.now = nextDay
        rig.view.clockTick()
        drain()
        XCTAssertEqual(rig.log.firstOpenCount, 1, "a new day re-arms the request, but only a showing may use it")

        rig.view.tabDidShow()
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 2 }, "frames: \(rig.log.frames)")
    }

    // MARK: Refresh sender contract

    func testRefreshPicksSendsTheFrameAndReportsTrueWhenConnected() {
        let store = WorkStore()
        let log = FrameLog()
        store.sendFrame = { log.frames.append($0) }

        XCTAssertTrue(store.refreshPicks(reason: "manual"))
        XCTAssertEqual(log.frames, [.picksRefresh(reason: "manual")])
    }

    func testRefreshPicksSendsNothingAndReportsFalseWhileDisconnected() {
        let store = WorkStore()
        let log = FrameLog()
        store.sendFrame = { log.frames.append($0) }
        store.setConnected(false)

        XCTAssertFalse(store.refreshPicks(reason: "first_open"))
        XCTAssertTrue(log.frames.isEmpty, "\(log.frames)")
    }

    func testRefreshPicksReportsFalseWhenThereIsNoSender() {
        let store = WorkStore()
        store.sendFrame = nil

        XCTAssertFalse(store.refreshPicks(reason: "manual"))
    }

    // MARK: Row text legibility

    private func rowFixture(window: NSWindow? = nil) -> ViewRig {
        // Row 4 (jira:RM-3) is done since and has been sent somewhere: every marker is drawn on it.
        ViewRig(picks: freshSnapshot(), window: window) { store in
            seedItem(store, liveItem("jira:RM-3", source: "jira", title: "RM-3 Old migration", sent: ["Fix webhook"]))
        }
    }

    private let markerNames = ["source", "title", "reason", "done since", "sent"]

    func testEveryTextColourOnTheSelectedRowIsLegibleAgainstTheSelectionFill() {
        let rig = rowFixture()
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 && rig.view.visibleRows[4].sentText != nil })

        for (index, itemId) in [(4, "jira:RM-3"), (0, "todo:7")] {
            rig.view.select(itemId: itemId)
            let colours = rig.view.textColors(forRow: index)
            XCTAssertEqual(colours.count, index == 4 ? 5 : 3,
                           "source, title, reason, then done since and sent when the row has them")
            for (position, colour) in colours.enumerated() {
                let ratio = contrastRatio(colour, on: Theme.bgBarActive)
                XCTAssertGreaterThanOrEqual(ratio, 4.5,
                    "\(markerNames[position]) text on selected row \(index) is \(String(format: "%.2f", ratio)):1 on the selection fill")
            }
        }
    }

    func testUnselectedRowsKeepTheirMutedAndAccentColoursAndStayLegibleOnTheSurface() {
        let rig = rowFixture()
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 && rig.view.visibleRows[4].sentText != nil })

        let colours = rig.view.textColors(forRow: 4)
        XCTAssertEqual(colours.count, 5)
        let expected = [Theme.fgMuted, Theme.fg, Theme.fgMuted, Theme.sage, Theme.cornflower]
        for (position, colour) in colours.enumerated() {
            XCTAssertTrue(sameColour(colour, expected[position]), "\(markerNames[position]) keeps its palette colour")
            // Measured against today's palette: fgMuted 5.8, fg 14.2, sage 8.5, cornflower 6.5 (all >= 4.5).
            XCTAssertGreaterThanOrEqual(contrastRatio(colour, on: Theme.bg), 4.5, markerNames[position])
        }
    }

    func testDeselectingARowRestoresItsUnselectedColours() {
        let rig = rowFixture()
        XCTAssertTrue(waitUntil { rig.view.visibleRows.count == 5 && rig.view.visibleRows[4].sentText != nil })
        let before = rig.view.textColors(forRow: 4)

        rig.view.select(itemId: "jira:RM-3")
        rig.view.select(itemId: "todo:7")   // moves the selection off row 4

        let after = rig.view.textColors(forRow: 4)
        XCTAssertEqual(after.count, before.count)
        for (position, colour) in after.enumerated() {
            XCTAssertTrue(sameColour(colour, before[position]), "\(markerNames[position]) is back to its unselected colour")
        }
    }

    // MARK: Refresh button legibility

    func testTheRefreshButtonTitleHasAnExplicitLegibleColourAndStillSaysRefreshPicks() {
        let rig = ViewRig(picks: freshSnapshot())
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })

        let colour = rig.view.refreshButtonTitleColor
        XCTAssertNotNil(colour, "an unset title colour is what made PR #229's tab labels vanish on a dark surface")
        if let colour {
            XCTAssertGreaterThanOrEqual(contrastRatio(colour, on: Theme.bg), 4.5)
        }
        XCTAssertEqual(rig.view.refreshButtonTitle, "Refresh picks")
    }

    func testTheRefreshButtonKeepsItsLegibleColourThroughAGenerationCycle() {
        let rig = ViewRig(picks: freshSnapshot())
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })

        rig.store.apply(picks: snapshot(generatedAt: "2026-10-11T07:00:00-05:00", generating: true, items: fiveItems))
        XCTAssertTrue(waitUntil { !rig.view.isRefreshButtonEnabled })
        rig.store.apply(picks: freshSnapshot())
        XCTAssertTrue(waitUntil { rig.view.isRefreshButtonEnabled })

        let colour = rig.view.refreshButtonTitleColor
        XCTAssertNotNil(colour)
        if let colour {
            XCTAssertGreaterThanOrEqual(contrastRatio(colour, on: Theme.bg), 4.5)
        }
        XCTAssertEqual(rig.view.refreshButtonTitle, "Refresh picks")
    }
}

// MARK: - The surface

private final class PicksFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private func picksKeyEvent(_ chars: String, code: UInt16, window: NSWindow?) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                     windowNumber: window?.windowNumber ?? 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: code)!
}

final class TeriPicksSurfaceTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let store: WorkStore
        let window: RigWindow
        let surface: TeriSurfaceView
        let log: FrameLog
    }

    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriPicks.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// A real surface in an offscreen window; `seed` runs before it exists. Its clock is
    /// the fixed `morning` in Chicago and its scheduler never fires by itself.
    private func makeRig(defaults: UserDefaults? = nil, seed: (WorkStore) -> Void = { _ in }) -> Rig {
        let store = WorkStore()
        let log = FrameLog()
        store.sendFrame = { log.frames.append($0) }
        seed(store)
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 700))
        let surface = TeriSurfaceView(store: store, defaults: defaults ?? makeDefaults(), center: NotificationCenter(),
                                      scheduler: ManualScheduler().scheduler, now: { morning }, calendar: chicago)
        surface.frame = window.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        return Rig(store: store, window: window, surface: surface, log: log)
    }

    /// Picks generated an hour before the injected clock: made today, so nothing here is "stale".
    private func freshPicks(items: [[String: Any]] = fiveItems) -> PicksSnapshot { freshSnapshot(items: items) }

    /// Picks from three days before the injected clock: before today, in any time zone.
    private func stalePicks(items: [[String: Any]] = fiveItems) -> PicksSnapshot { staleSnapshot(items: items) }

    private func focusInside(_ rig: Rig) {
        let child = PicksFocusableView()
        rig.surface.addSubview(child)
        XCTAssertTrue(rig.window.makeFirstResponder(child), "precondition: focus is inside the surface")
    }

    // MARK: Initial tab

    func testTheSurfaceOpensOnPicksWhenPicksExistAndNothingWasSaved() {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })

        XCTAssertEqual(rig.surface.selectedTab, .picks)
    }

    func testTheSurfaceOpensOnTodosWhenThereAreNoPicks() {
        let rig = makeRig()

        XCTAssertEqual(rig.surface.selectedTab, .todos)
    }

    // MARK: The Picks tab

    func testThePicksTabShowsTheStorePicksAndCountsThemInItsButton() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })

        let picksView = try XCTUnwrap(rig.surface.picksView)
        XCTAssertTrue(waitUntil { picksView.visibleRows.count == 5 }, "rows: \(picksView.visibleRows.map(\.title))")
        XCTAssertEqual(picksView.visibleRows.map(\.title), titlesOf(fiveItems))
        XCTAssertEqual(rig.surface.tabButtonTitle(.picks), "Picks 5")
    }

    func testThePicksTabNoLongerSaysComingSoon() {
        let withPicks = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        XCTAssertEqual(withPicks.surface.selectedTab, .picks)
        XCTAssertFalse(withPicks.surface.visibleBannerMessage?.contains("Coming soon") ?? false,
                       String(describing: withPicks.surface.visibleBannerMessage))

        let withoutPicks = makeRig()
        withoutPicks.surface.select(.picks)
        XCTAssertFalse(withoutPicks.surface.visibleBannerMessage?.contains("Coming soon") ?? false,
                       String(describing: withoutPicks.surface.visibleBannerMessage))
    }

    func testPicksArrivingAfterTheSurfaceExistsAreShown() {
        let rig = makeRig()
        rig.surface.select(.picks)
        XCTAssertTrue(rig.surface.picksView?.visibleRows.isEmpty ?? false)

        rig.store.apply(picks: freshPicks())

        XCTAssertTrue(waitUntil { rig.surface.picksView?.visibleRows.count == 5 })
        XCTAssertTrue(waitUntil { rig.surface.tabButtonTitle(.picks) == "Picks 5" })
    }

    private func titlesOf(_ items: [[String: Any]]) -> [String] { items.map { $0["title"] as! String } }

    func testTheSurfaceHandsItsInjectedClockToThePicksView() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })

        let picksView = try XCTUnwrap(rig.surface.picksView)
        // An hour before the injected "morning"; against the wall clock this would read as days ago.
        XCTAssertTrue(waitUntil { picksView.headerText == "Generated 1 h ago" }, picksView.headerText)
    }

    // MARK: First open through the surface

    func testOpeningOnPicksWithStalePicksAsksTheDaemonToGenerateOnce() {
        let rig = makeRig(seed: { $0.apply(picks: self.stalePicks()) })

        XCTAssertEqual(rig.surface.selectedTab, .picks)
        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")

        rig.surface.select(.todos)
        rig.surface.select(.picks)
        drain()
        XCTAssertEqual(rig.log.firstOpenCount, 1, "leaving and returning the same day does not ask again: \(rig.log.frames)")
    }

    func testStalePicksAreOnlyRequestedWhenThePicksTabBecomesVisible() {
        let defaults = makeDefaults()
        var saved = TeriViewState()
        saved.selectedTab = .todos
        saved.save(to: defaults)
        let rig = makeRig(defaults: defaults, seed: { $0.apply(picks: self.stalePicks()) })
        drain()
        XCTAssertEqual(rig.surface.selectedTab, .todos)
        XCTAssertEqual(rig.log.firstOpenCount, 0, "Picks is not showing: \(rig.log.frames)")

        rig.surface.select(.picks)

        XCTAssertTrue(waitUntil { rig.log.firstOpenCount == 1 }, "frames: \(rig.log.frames)")
    }

    // MARK: Detail

    func testSelectingAPickAsksForThatItemsDetailAndShowsTheAnswerInTheDetailPane() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        let picksView = try XCTUnwrap(rig.surface.picksView)
        XCTAssertTrue(waitUntil { picksView.visibleRows.count == 5 })
        rig.log.frames.removeAll()

        picksView.select(itemId: "jira:RM-12")

        let requests = rig.log.detailRequests
        XCTAssertEqual(requests.map(\.itemId), ["jira:RM-12"])
        XCTAssertNotEqual(rig.surface.detailTitle, "RM-12 Refund flow (detail)", "not shown before the daemon answers")

        rig.store.resolve(requestId: requests[0].requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "jira:RM-12",
                                                                       title: "RM-12 Refund flow (detail)",
                                                                       markdown: "Customers are double refunded."))))

        XCTAssertTrue(waitUntil { rig.surface.detailTitle == "RM-12 Refund flow (detail)" },
                      "detailTitle: \(String(describing: rig.surface.detailTitle))")
    }

    func testAFailedDetailLookupShowsTheFailureInTheDetailPaneInsteadOfCrashing() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        let picksView = try XCTUnwrap(rig.surface.picksView)
        XCTAssertTrue(waitUntil { picksView.visibleRows.count == 5 })
        rig.log.frames.removeAll()

        picksView.select(itemId: "sentry:4411")
        let request = try XCTUnwrap(rig.log.detailRequests.first)
        XCTAssertEqual(request.itemId, "sentry:4411")

        rig.store.resolve(requestId: request.requestId,
                          with: .detail(.err(WorkError(code: "not_found", message: "That issue no longer exists"))))
        drain()

        XCTAssertEqual(picksView.selectedPickId, "sentry:4411", "the selection survives the failure")
        XCTAssertEqual(rig.surface.detailTitle, "TypeError in checkout",
                       "the pane stays on the pick it failed to load: \(String(describing: rig.surface.detailTitle))")
    }

    func testAConnectionLostAnswerIsHandledTheSameWay() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        let picksView = try XCTUnwrap(rig.surface.picksView)
        XCTAssertTrue(waitUntil { picksView.visibleRows.count == 5 })
        rig.log.frames.removeAll()

        picksView.select(itemId: "todo:7")
        rig.store.failPendingRequests(reason: "connection closed")
        drain()

        XCTAssertEqual(rig.surface.detailTitle, "Reply to Dana about the budget")
        XCTAssertEqual(picksView.selectedPickId, "todo:7")
    }

    func testALateAnswerForAPickYouMovedAwayFromDoesNotReplaceTheCurrentDetail() throws {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        let picksView = try XCTUnwrap(rig.surface.picksView)
        XCTAssertTrue(waitUntil { picksView.visibleRows.count == 5 })
        rig.log.frames.removeAll()

        picksView.select(itemId: "todo:7")
        picksView.select(itemId: "jira:RM-12")
        let first = try XCTUnwrap(rig.log.detailRequests.first { $0.itemId == "todo:7" })
        let second = try XCTUnwrap(rig.log.detailRequests.last { $0.itemId == "jira:RM-12" })

        rig.store.resolve(requestId: first.requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "todo:7", title: "Detail of the todo"))))
        drain()
        XCTAssertNotEqual(rig.surface.detailTitle, "Detail of the todo", "the user has moved on")

        rig.store.resolve(requestId: second.requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "jira:RM-12", title: "Detail of the issue"))))
        XCTAssertTrue(waitUntil { rig.surface.detailTitle == "Detail of the issue" })
        XCTAssertEqual(picksView.selectedPickId, "jira:RM-12")
    }

    // MARK: Keyboard

    func testCommandROnThePicksTabAsksForNewPicks() {
        let rig = makeRig(seed: { $0.apply(picks: self.freshPicks()) })
        focusInside(rig)
        XCTAssertEqual(rig.surface.selectedTab, .picks)
        rig.log.frames.removeAll()

        XCTAssertTrue(rig.surface.performKeyEquivalent(with: picksKeyEvent("r", code: 15, window: rig.window)))

        XCTAssertEqual(rig.log.frames, [.picksRefresh(reason: "manual")])
    }
}
