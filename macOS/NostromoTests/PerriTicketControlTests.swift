import XCTest
import AppKit
import SwiftUI
import NostromoKit

// Perri side pane, slice 3: the **Ticket <KEY>** control on a queue row.
//
//   * drawn only when the row has detected keys AND a Jira site is configured (criteria 7, 27)
//   * the first key is a button after Diff; further keys sit behind a `+N` menu (criterion 26)
//   * each key opens its own tab at https://<site>/browse/<KEY>, ordered after Diff (criteria 26, 28)
//   * pressing it opens a tab and never loads the PR
//
// The real `PaneContentView` is rendered in a real window and read back pixel by pixel, as in
// `PerriRowControlsHitTests`.

@MainActor
final class PerriTicketControlTests: XCTestCase {

    private let site = "carefeed.atlassian.net"
    private var rigs: [PerriRowsRig] = []

    private func makeRig(width: CGFloat = 480, tickets: [Int: [String]], jiraSite: String?,
                         selected: Int? = 4520, reviewing: ReviewingPR? = nil) -> PerriRowsRig {
        let r = PerriRowsRig(width: width, selected: selected, withActions: true, reviewing: reviewing,
                             tickets: tickets, jiraSite: jiraSite)
        rigs.append(r)
        return r
    }

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [], current: nil, jiraSite: nil))
        super.tearDown()
    }

    private func boxes(_ r: PerriRowsRig) throws -> (boxes: [PerriRowsRig.Box], scale: CGFloat) {
        let (pixels, scale) = try r.render()
        return (r.buttonBoxes(pixels, scale: scale).sorted { $0.x0 < $1.x0 }, scale)
    }

    // MARK: When the control is drawn

    func testARowWithAKeyAndASiteDrawsTicketAfterDiff() throws {
        for width in [200, 320, 480] as [CGFloat] {
            let r = makeRig(width: width, tickets: [4520: ["CORE-2841"]], jiraSite: site)
            let (found, scale) = try boxes(r)
            XCTAssertEqual(found.count, 3, "Conversation, Diff, Ticket at \(Int(width)) pt: \(found)")
            guard found.count == 3 else { continue }

            r.click(px: found[2].centre.x, py: found[2].centre.y, scale: scale)

            XCTAssertEqual(r.recordedTickets, [.init(number: 4520, key: "CORE-2841", order: 0)], "at \(Int(width)) pt")
            XCTAssertEqual(r.recordedLoads, [], "pressing a control never loads the PR")
            XCTAssertEqual(r.recordedConversations, [])
            XCTAssertEqual(r.recordedDiffs, [])
        }
    }

    func testTheWideRowNamesTheTicketAndTheNarrowRowUsesAnIcon() throws {
        func ticketWidth(_ width: CGFloat) throws -> CGFloat {
            let r = makeRig(width: width, tickets: [4520: ["CORE-2841"]], jiraSite: site)
            let (found, scale) = try boxes(r)
            guard found.count == 3 else { return 0 }
            return CGFloat(found[2].x1 - found[2].x0 + 1) / scale
        }
        let narrow = try ticketWidth(200), wide = try ticketWidth(480)
        XCTAssertGreaterThan(narrow, 0)
        XCTAssertGreaterThan(wide, narrow + 40, "480 pt: \"Ticket CORE-2841\" (\(wide) pt); 200 pt: icon (\(narrow) pt)")
    }

    func testNoSiteDrawsNoTicketControl() throws {
        for width in [200, 480] as [CGFloat] {
            let r = makeRig(width: width, tickets: [4520: ["CORE-2841"]], jiraSite: nil)
            XCTAssertEqual(try boxes(r).boxes.count, 2, "criterion 27: only Conversation and Diff at \(Int(width)) pt")
        }
    }

    func testNoKeysDrawsNoTicketControl() throws {
        let r = makeRig(tickets: [:], jiraSite: site)
        XCTAssertEqual(try boxes(r).boxes.count, 2, "criterion 7: nothing offered for a PR with no key")
    }

    func testThreeKeysDrawTheFirstAndAPlusTwoBadge() throws {
        for width in [200, 320, 480] as [CGFloat] {
            let r = makeRig(width: width, tickets: [4520: ["CORE-2841", "PAYM-77", "INT-9"]], jiraSite: site)
            let (found, _) = try boxes(r)
            XCTAssertEqual(found.count, 4, "Conversation, Diff, Ticket, +2 at \(Int(width)) pt: \(found)")
        }
    }

    // MARK: Accessibility

    private func labels(_ r: PerriRowsRig) -> [String] {
        reviewAXNodes(under: r.hosting).compactMap(reviewAXLabel)
    }

    /// SwiftUI builds its accessibility tree only when something is listening; some test processes get none
    /// (see `ReviewPaneAccessibilityTests`). Those skip, and the source test below guards the wording.
    private func swiftUIAccessibilityIsAvailable() -> Bool {
        let host = NSHostingView(rootView: Text("control").accessibilityLabel("accessibility control label"))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        let window = ReviewTestWindow.make(size: NSSize(width: 200, height: 40))
        defer { window.contentView = NSView(); window.close() }
        window.contentView = host
        NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        spin(0.4)
        return reviewAXNodes(under: host).contains { reviewAXLabel($0) == "accessibility control label" }
    }

    /// The wording, read from the source: the button label, the disclosure label and the row action.
    func testTheTicketLabelsAreWrittenAsSpecified() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/ReviewPane/PerriRowControls.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("accessibility: \"Open ticket \\(first)\""), "the button's label")
        XCTAssertTrue(source.contains("Self.moreLabel(rest.count)"), "the disclosure's label")
        XCTAssertTrue(source.contains("\"\\(count) more ticket\\(count == 1 ? \"\" : \"s\")\""), "its wording")
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "Button(\"Open ticket \\(key)\")").count - 1, 3,
                                    "the menu items, and the row actions on queue and reviewing rows")
    }

    func testTheTicketButtonAndTheDisclosureAreLabelled() throws {
        try XCTSkipUnless(swiftUIAccessibilityIsAvailable(), "no SwiftUI accessibility tree in this process")
        let r = makeRig(tickets: [4520: ["CORE-2841", "PAYM-77", "INT-9"]], jiraSite: site)
        let all = labels(r)
        XCTAssertTrue(all.contains("Open ticket CORE-2841"), "labels: \(all)")
        XCTAssertTrue(all.contains("2 more tickets"), "labels: \(all)")
    }

    func testTheDisclosureForOneMoreTicketReadsInTheSingular() {
        XCTAssertEqual(PerriRowControls.moreLabel(1), "1 more ticket")
        XCTAssertEqual(PerriRowControls.moreLabel(2), "2 more tickets")
        XCTAssertEqual(PerriRowControls.ticketLabel("CORE-2841"), "Ticket CORE-2841")
    }

    func testEveryKeyOnEveryRowIsAnAccessibilityAction() throws {
        try XCTSkipUnless(swiftUIAccessibilityIsAvailable(), "no SwiftUI accessibility tree in this process")
        // Whether or not its controls are drawn: rows 1 and 3 here are neither selected nor hovered.
        let r = makeRig(tickets: [4519: ["CORE-1", "CORE-2"], 4521: ["APP-3"]], jiraSite: site)
        let names = reviewAXNodes(under: r.hosting).flatMap { node -> [String] in
            let actions = (AppControlAX.value(node, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
            return actions.map(\.name)
        }
        for expected in ["Open ticket CORE-1", "Open ticket CORE-2", "Open ticket APP-3"] {
            XCTAssertTrue(names.contains(expected), "\(expected) in \(names)")
        }
    }

    // MARK: The "Reviewing #N" row

    func testTheReviewingRowGetsTicketsFromTheMatchingQueueItem() throws {
        let item = PRQueueItem(repo: "acme/web", number: 9001, title: "Pinned", author: "dev", bucket: "needs_review",
                               newActivity: false, url: "https://github.com/acme/web/pull/9001", ciState: .success,
                               headSha: "abc", tickets: ["CORE-9"])
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [item], current: nil, jiraSite: site))
        let reviewing = ReviewingPR(repo: "acme/web", number: 9001, title: "Pinned")
        let with = makeRig(tickets: [:], jiraSite: site, selected: nil, reviewing: reviewing)
        XCTAssertEqual(try boxes(with).boxes.count, 3, "Conversation, Diff, Ticket on the reviewing row")

        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [], current: nil, jiraSite: site))
        let without = makeRig(tickets: [:], jiraSite: site, selected: nil, reviewing: reviewing)
        XCTAssertEqual(try boxes(without).boxes.count, 2, "no matching queue item: no ticket")
    }

    // MARK: Tabs (criteria 26, 28)

    private func pane() -> ReviewPaneModel { ReviewPaneModel(tag: "perri-tickets-\(UUID().uuidString)", store: nil) }
    private let pr = ReviewPR(repo: "acme/web", number: 4520)

    func testEachKeyOpensItsOwnTabAtItsBrowseURLAfterDiffInDetectionOrder() {
        let model = pane()
        let actions = PerriRowActions.opening(in: model, jiraSite: { self.site })
        // Opened out of order on purpose: the tab bar keeps detection order, after Diff.
        actions.openTicket("acme/web", 4520, "PAYM-77", 1)
        actions.openTicket("acme/web", 4520, "INT-9", 2)
        actions.openTicket("acme/web", 4520, "CORE-2841", 0)
        actions.openDiff("acme/web", 4520)
        actions.openConversation("acme/web", 4520)

        XCTAssertEqual(model.tabs.map(\.title), ["#4520 Conversation", "#4520 Diff", "CORE-2841", "PAYM-77", "INT-9"])
        let tickets = model.tabs.filter { if case .ticket = $0.target { return true } else { return false } }
        XCTAssertEqual(tickets.map(\.startURL.absoluteString), [
            "https://carefeed.atlassian.net/browse/CORE-2841",
            "https://carefeed.atlassian.net/browse/PAYM-77",
            "https://carefeed.atlassian.net/browse/INT-9",
        ])
        XCTAssertEqual(tickets.map(\.target), [.ticket("CORE-2841"), .ticket("PAYM-77"), .ticket("INT-9")])
    }

    func testOpeningTheSameKeyAgainFocusesItsTab() {
        let model = pane()
        let actions = PerriRowActions.opening(in: model, jiraSite: { self.site })
        actions.openTicket("acme/web", 4520, "CORE-2841", 0)
        actions.openTicket("acme/web", 4520, "CORE-2841", 0)
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testNoSiteOrAMalformedKeyOpensNothing() {
        let model = pane()
        PerriRowActions.opening(in: model, jiraSite: { nil }).openTicket("acme/web", 4520, "CORE-2841", 0)
        XCTAssertTrue(model.tabs.isEmpty, "no site")
        let actions = PerriRowActions.opening(in: model, jiraSite: { self.site })
        for key in ["core-1", "CORE-0", "A-1", "CORE-1/../x", "CORE-1?x=1", "CORE-1 ", ""] {
            actions.openTicket("acme/web", 4520, key, 0)
        }
        XCTAssertTrue(model.tabs.isEmpty, "malformed keys never reach a URL")
        PerriRowActions.opening(in: model, jiraSite: { "evil.example.com" }).openTicket("acme/web", 4520, "CORE-1", 0)
        XCTAssertTrue(model.tabs.isEmpty, "a site that is not a Jira Cloud host")
    }

    func testAKeyOfMoreThanTenDigitsIsNotAKeyAndNeverReachesAURL() {
        let ten = "CORE-" + String(repeating: "1", count: 10)
        let eleven = "CORE-" + String(repeating: "1", count: 11)
        let huge = "CORE-" + String(repeating: "9", count: 60_000)
        XCTAssertNotNil(ReviewPR.ticketURL(site: site, key: ten))
        XCTAssertNil(ReviewPR.ticketURL(site: site, key: eleven))
        XCTAssertNil(ReviewPR.ticketURL(site: site, key: huge))
        let model = pane()
        PerriRowActions.opening(in: model, jiraSite: { self.site }).openTicket("acme/web", 4520, huge, 0)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testTheMacDropsMalformedKeysAndKeepsAtMostFiveBeforeDrawing() {
        let actions = PerriRowActions(openConversation: { _, _ in }, openDiff: { _, _ in },
                                      jiraSite: { self.site })
        let huge = "CORE-" + String(repeating: "9", count: 60_000)
        let shown = perriTicketKeys(["core-1", huge, "<b>x</b>", "CORE-1", "CORE-1", "CORE-2", "CORE-3",
                                     "CORE-4", "CORE-5", "CORE-6", "CORE-7"], actions: actions)
        XCTAssertEqual(shown, ["CORE-1", "CORE-2", "CORE-3", "CORE-4", "CORE-5"])
    }

    func testAnAgentPushedPrListWithJunkKeysIsCleanedWhenDecoded() throws {
        let huge = "CORE-" + String(repeating: "9", count: 60_000)
        let json = """
        {"repo":"acme/web","number":1,"title":"t","author":"a","bucket":"requested","new_activity":false,
         "url":"https://github.com/acme/web/pull/1","tickets":["x", "\(huge)", "CORE-1", "CORE-2", "CORE-3",
         "CORE-4", "CORE-5", "CORE-6"]}
        """
        let item = try JSONDecoder().decode(PrListItemModel.self, from: Data(json.utf8))
        XCTAssertEqual(item.tickets, ["CORE-1", "CORE-2", "CORE-3", "CORE-4", "CORE-5"])
    }

    func testTicketURLNeedsAValidSiteAndKey() {
        XCTAssertEqual(ReviewPR.ticketURL(site: site, key: "CORE-2841")?.absoluteString,
                       "https://carefeed.atlassian.net/browse/CORE-2841")
        XCTAssertNil(ReviewPR.ticketURL(site: "carefeed.example.com", key: "CORE-1"))
        XCTAssertNil(ReviewPR.ticketURL(site: site, key: "X-1"))
    }

    // MARK: Wiring and wire decode

    func testThePerriFocusActionsCarryTheTicketControl() throws {
        let perri = Focus(id: "1a2b3c4d-3333", agentTag: "perri", projectPath: "/tmp/ticket-wiring", isBuiltIn: false)
        let view = DynamicFocusView(focus: perri, windowId: "ticket-wiring-\(UUID().uuidString.prefix(6))")
        let queue = try XCTUnwrap(view.makeLeafView(paneId: "queue-test", reusing: nil) as? PaneContentNSView)
        XCTAssertNotNil(queue.rowActions)
    }

    func testTheDaemonFramesTicketKeysReachTheQueueItem() throws {
        let json = #"{"type":"perri_state","tag":"perri","queue":[{"repo":"a/b","number":1,"title":"t","author":"x","bucket":"requested","new_activity":false,"url":"u","tickets":["CORE-1","PAYM-2"]},{"repo":"a/b","number":2,"title":"t","author":"x","bucket":"requested","new_activity":false,"url":"u"}],"current":null,"jira_site":"carefeed.atlassian.net"}"#
        let raw = Data(json.utf8)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        guard case .perriState(_, let queue, _, _) = NostromodClient().decode(type_: "perri_state", json: obj, raw: raw)
        else { return XCTFail("not a perri_state") }
        XCTAssertEqual(queue.map(\.tickets), [["CORE-1", "PAYM-2"], []])
    }
}
