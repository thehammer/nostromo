import XCTest
import AppKit

// Behavioural spec for the sidebar attention flag.
//
// `NavRow.needsAttention(in:)` is true only for `.focus` rows whose focus's
// `sessionTag` is in the outstanding-attention set. The flag is purely a
// render-time projection: `buildNavRows` takes no attention parameter, so its
// output (and the D6 "every focus row has a second line" row-height rule) must
// not depend on it.
//
// NOTE: `needsAttention(in:)` is the only symbol here that did not exist before
// this feature. If the stub is ever removed, only the tests in the
// "needsAttention" section fail to compile.

final class SidenavAttentionTests: XCTestCase {

    private func dynamicFocus(id: String, agent: String, path: String = "/Users/hammer/Code/nostromo",
                              daemonTag: String? = nil) -> Focus {
        var f = Focus(id: id, agentTag: agent, projectPath: path, isBuiltIn: false, org: "Carefeed")
        f.daemonTag = daemonTag
        return f
    }

    private func focusRows(_ rows: [NavRow]) -> [(focus: Focus, row: NavRow)] {
        rows.compactMap { row in
            if case let .focus(f, _, _, _) = row { return (f, row) }
            return nil
        }
    }

    // MARK: - needsAttention

    func testFocusRowWhoseSessionTagIsInTheSetNeedsAttention() {
        let rows = buildNavRows(Focus.builtIns)
        let perri = focusRows(rows).first { $0.focus.agentTag == "perri" }!
        XCTAssertTrue(perri.row.needsAttention(in: [perri.focus.sessionTag]))
    }

    func testFocusRowWhoseSessionTagIsNotInTheSetDoesNotNeedAttention() {
        let rows = buildNavRows(Focus.builtIns)
        let teri = focusRows(rows).first { $0.focus.agentTag == "teri" }!
        XCTAssertFalse(teri.row.needsAttention(in: ["perri"]))
    }

    func testNothingNeedsAttentionWhenTheSetIsEmpty() {
        let rows = buildNavRows(Focus.builtIns + [dynamicFocus(id: "11111111-aaaa", agent: "cody")])
        for row in rows {
            XCTAssertFalse(row.needsAttention(in: []))
        }
    }

    func testHeaderRowsNeverNeedAttentionEvenIfTheirTextMatchesATag() {
        XCTAssertFalse(NavRow.orgHeader("perri").needsAttention(in: ["perri", "CAREFEED", "nostromo"]))
        XCTAssertFalse(NavRow.repoHeader("perri").needsAttention(in: ["perri", "Nostromo", "nostromo"]))
    }

    func testMatchIsOnSessionTagNotAgentTag() {
        // A dynamic focus's session tag is "<agent>-<id prefix>", not the bare agent.
        let f = dynamicFocus(id: "abcdef12-0000-0000-0000-000000000000", agent: "cody")
        let row = NavRow.focus(f, label: "Cody in Nostromo", secondary: "", indented: false)
        XCTAssertFalse(row.needsAttention(in: ["cody"]))
        XCTAssertTrue(row.needsAttention(in: [f.sessionTag]))
    }

    func testDaemonCreatedFocusMatchesItsDaemonTag() {
        let f = dynamicFocus(id: "cody-core-1234", agent: "cody", daemonTag: "cody-core-1234")
        let row = NavRow.focus(f, label: "Cody in Nostromo", secondary: "", indented: false)
        XCTAssertTrue(row.needsAttention(in: ["cody-core-1234"]))
    }

    func testMultipleRowsNeedingAttentionAreFlaggedIndependently() {
        let a = dynamicFocus(id: "aaaaaaaa-0000", agent: "cody", path: "/Users/hammer/Code/nostromo")
        let b = dynamicFocus(id: "bbbbbbbb-0000", agent: "cody", path: "/Users/hammer/Code/admin-portal")
        let c = dynamicFocus(id: "cccccccc-0000", agent: "cody", path: "/Users/hammer/Code/callimachus")
        let rows = buildNavRows(Focus.builtIns + [a, b, c])
        let tags: Set<String> = ["perri", a.sessionTag, c.sessionTag]

        let flagged = Set(focusRows(rows).filter { $0.row.needsAttention(in: tags) }.map { $0.focus.sessionTag })
        XCTAssertEqual(flagged, tags)

        let unflagged = focusRows(rows).filter { !$0.row.needsAttention(in: tags) }.map(\.focus.sessionTag)
        XCTAssertTrue(unflagged.contains(b.sessionTag))
        XCTAssertTrue(unflagged.contains("fred"))
    }

    func testFlaggingAFocusLeavesEveryOtherRowUnflagged() {
        let rows = buildNavRows(Focus.builtIns)
        let flaggedCount = rows.filter { $0.needsAttention(in: ["mother"]) }.count
        XCTAssertEqual(flaggedCount, 1)
    }

    // MARK: - buildNavRows is independent of attention

    func testBuildNavRowsOutputIsUnaffectedByWhichRowsNeedAttention() {
        let focuses = Focus.builtIns + [dynamicFocus(id: "11111111-aaaa", agent: "cody")]
        let before = buildNavRows(focuses)
        // Evaluating attention over the rows must not change what a rebuild yields.
        _ = before.map { $0.needsAttention(in: ["perri", "fred"]) }
        let after = buildNavRows(focuses)
        XCTAssertEqual(before, after)
    }

    func testEveryFocusRowStillHasASecondLineSoRowHeightIsStable() {
        let focuses = Focus.builtIns + [
            dynamicFocus(id: "11111111-aaaa", agent: "cody"),
            dynamicFocus(id: "22222222-bbbb", agent: "claudia", path: "/Users/hammer/Code/admin-portal"),
        ]
        let rows = buildNavRows(focuses)
        let focusRowList = focusRows(rows)
        XCTAssertFalse(focusRowList.isEmpty)
        for (_, row) in focusRowList {
            guard case let .focus(_, _, secondary, _) = row else { return XCTFail("not a focus row") }
            XCTAssertNotNil(secondary, "D6: every focus row carries a (possibly empty) second line")
        }
    }

    // MARK: - The attention dot on a real row (NavTabItem)

    private static let longName = "A very long focus label that cannot possibly fit in a narrow sidebar row"

    private func makeItem(label: String = "Cody in Nostromo", secondary: String? = "main",
                          attention: Bool, sweater: NSColor? = nil, width: CGFloat = 180) -> NavTabItem {
        let focus = dynamicFocus(id: "11111111-aaaa", agent: "cody")
        let item = NavTabItem(focus: focus, label: label, secondary: secondary, indented: false)
        item.sweaterColor = sweater
        item.needsAttention = attention
        // The same fixed row height `TabBarView` pins on every focus row.
        let height = secondary != nil ? Theme.navItemSubtitleHeight : Theme.navItemHeight
        item.frame = NSRect(x: 0, y: 0, width: width, height: height)
        item.layoutSubtreeIfNeeded()
        return item
    }

    private func descendants<T>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            (sub as? T).map { [$0] + descendants(of: type, in: sub) } ?? descendants(of: type, in: sub)
        }
    }

    private func primaryLabel(in item: NavTabItem, text: String) -> NSTextField? {
        descendants(of: NSTextField.self, in: item).first { $0.stringValue == text }
    }

    private func attentionDot(in item: NavTabItem) -> NSView? {
        descendants(of: NSView.self, in: item).first { $0.accessibilityLabel() == "needs your attention" }
    }

    func testAttentionDotIsAnAccessibleImageLabelledNeedsYourAttention() throws {
        let item = makeItem(attention: true)
        let dot = try XCTUnwrap(attentionDot(in: item))
        XCTAssertTrue(dot.isAccessibilityElement())
        XCTAssertEqual(dot.accessibilityRole(), .image)
        XCTAssertEqual(dot.accessibilityLabel(), "needs your attention")
    }

    func testAttentionDotIsShownOnlyWhileTheRowNeedsAttention() throws {
        let item = makeItem(attention: false)
        let dot = try XCTUnwrap(attentionDot(in: item))
        XCTAssertTrue(dot.isHidden)
        item.needsAttention = true
        XCTAssertFalse(dot.isHidden)
        item.needsAttention = false
        XCTAssertTrue(dot.isHidden)
    }

    func testRowHeightIsIdenticalWithAndWithoutAttention() throws {
        for secondary in [Optional("main"), nil] {
            let plain = makeItem(secondary: secondary, attention: false)
            let flagged = makeItem(secondary: secondary, attention: true)
            XCTAssertEqual(flagged.frame.height, plain.frame.height, "D6: attention never changes row height")
            XCTAssertEqual(flagged.fittingSize.height, plain.fittingSize.height)

            let plainLabel = try XCTUnwrap(primaryLabel(in: plain, text: "Cody in Nostromo"))
            let flaggedLabel = try XCTUnwrap(primaryLabel(in: flagged, text: "Cody in Nostromo"))
            XCTAssertEqual(flaggedLabel.frame.origin.y, plainLabel.frame.origin.y)
            XCTAssertEqual(flaggedLabel.frame.height, plainLabel.frame.height)
        }
    }

    func testALongLabelDoesNotExtendUnderTheAttentionDot() throws {
        for secondary in [Optional("main"), nil] {
            for sweater in [nil, NSColor.systemOrange] {
                let item = makeItem(label: Self.longName, secondary: secondary, attention: true, sweater: sweater)
                let label = try XCTUnwrap(primaryLabel(in: item, text: Self.longName))
                let dot = try XCTUnwrap(attentionDot(in: item))
                XCTAssertFalse(dot.isHidden)
                // Compare alignment rects: an NSTextField's frame extends ~2pt past its text.
                let labelTextMaxX = label.alignmentRect(forFrame: label.frame).maxX
                XCTAssertLessThanOrEqual(labelTextMaxX, dot.frame.minX - 4,
                                         "label must leave a gap before the dot (secondary: \(String(describing: secondary)), sweater: \(sweater != nil))")
            }
        }
    }

    func testALongLabelKeepsItsWidthWhenThereIsNoAttention() throws {
        let item = makeItem(label: Self.longName, attention: false)
        let label = try XCTUnwrap(primaryLabel(in: item, text: Self.longName))
        // Space is reserved only while the dot is shown.
        let flagged = makeItem(label: Self.longName, attention: true)
        let flaggedLabel = try XCTUnwrap(primaryLabel(in: flagged, text: Self.longName))
        XCTAssertGreaterThanOrEqual(label.frame.width, flaggedLabel.frame.width)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(flaggedLabel.lineBreakMode, .byTruncatingTail)
    }

    func testTogglingAttentionOffRestoresTheLabelWidth() throws {
        let item = makeItem(label: Self.longName, attention: false)
        let before = try XCTUnwrap(primaryLabel(in: item, text: Self.longName)).frame.width
        item.needsAttention = true
        item.layoutSubtreeIfNeeded()
        item.needsAttention = false
        item.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(primaryLabel(in: item, text: Self.longName)).frame.width, before)
    }
}
