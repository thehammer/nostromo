import XCTest

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
}
