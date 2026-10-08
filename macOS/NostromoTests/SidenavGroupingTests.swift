import XCTest
import NostromoKit
// Focus, NavRow, and buildNavRows are compiled into this target directly
// (logic test — no host app). No module imports needed for those types;
// `NostromoKit` is imported so the W8 tests below can build their expected
// strings from `FocusPRLabel.label(repo:number:)` rather than hardcoding
// the "#<number> · <repo>" format a second time.

// MARK: - SidenavGroupingTests

/// Unit tests for `buildNavRows(_ focuses: [Focus]) -> [NavRow]`.
///
/// Covers: built-in ordering, single-focus repo labels (Claudia vs non-Claudia),
/// multi-focus repo grouping, disambiguation, org ordering, repo ordering,
/// and Focus Codable round-trip.
final class SidenavGroupingTests: XCTestCase {

    // MARK: - Factory helper

    private func makeFocus(
        id: String,
        agent: String,
        path: String? = nil,
        org: String? = nil,
        summary: String? = nil
    ) -> Focus {
        Focus(id: id, agentTag: agent, projectPath: path, isBuiltIn: false,
              org: org, sessionSummary: summary)
    }

    // MARK: - Test 1: Built-ins in CAREFEED org appear in canonical order

    func testBuiltIns_carefeedOrgHeader_andCanonicalOrder() {
        let rows = buildNavRows(Focus.builtIns)

        XCTAssertEqual(rows.count, 5,
                       "4 built-ins + 1 org header = 5 rows")

        // First row must be the org header
        XCTAssertEqual(rows[0], .orgHeader("CAREFEED"),
                       "first row must be CAREFEED org header")

        // Remaining rows must be fred → mother → perri → teri
        let expectedAgents = ["fred", "mother", "perri", "teri"]
        for (index, expected) in expectedAgents.enumerated() {
            let row = rows[index + 1]
            guard case let .focus(f, label: label, secondary: secondary, indented: indented) = row else {
                XCTFail("row \(index + 1) should be .focus, got \(row)")
                continue
            }
            XCTAssertEqual(f.agentTag, expected,
                           "built-in at position \(index + 1) should be \(expected)")
            XCTAssertEqual(label, expected.capitalized,
                           "built-in label should be agentTag.capitalized")
            XCTAssertEqual(secondary,
                           expected == "perri" ? NostromoKit.FocusPRLabel.noPR : "",
                           "only Perri says 'No PR'; other built-ins have no summary yet, so an empty (but non-nil) second line")
            XCTAssertFalse(indented,
                           "built-in pathless focuses are not indented")
        }
    }

    func testBuiltIns_noRepoHeaders() {
        let rows = buildNavRows(Focus.builtIns)
        let repoHeaders = rows.filter {
            if case .repoHeader = $0 { return true }
            return false
        }
        XCTAssertTrue(repoHeaders.isEmpty,
                      "built-ins have no projectPath so no repo headers should appear")
    }

    // MARK: - Test 2: Single Claudia in a repo uses the repo name as the label

    func testSingleClaudia_labelIsRepoNameOnly() {
        let f = makeFocus(id: "uuid-1", agent: "claudia",
                          path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f])

        // rows: orgHeader + focus
        XCTAssertEqual(rows.count, 2)
        guard case let .focus(_, label: label, secondary: secondary, indented: indented) = rows[1] else {
            XCTFail("second row should be .focus"); return
        }
        XCTAssertEqual(label, "Admin Portal",
                       "single Claudia in a repo: label is the repo name alone")
        XCTAssertEqual(secondary, "",
                       "a non-Perri focus with no summary gets an empty but non-nil second line (keeps row height, D6)")
        XCTAssertFalse(indented,
                       "single focus in repo is not indented")
    }

    func testSingleClaudia_caseInsensitiveMatch() {
        // agentTag in mixed case — must still match "claudia" check case-insensitively
        let f = makeFocus(id: "uuid-2", agent: "Claudia",
                          path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([f])
        guard case let .focus(_, label: label, secondary: _, indented: _) = rows[1] else {
            XCTFail("second row should be .focus"); return
        }
        XCTAssertEqual(label, "Nostromo",
                       "Claudia (any case) label is the repo name, not 'Claudia in Nostromo'")
    }

    // MARK: - Test 3: Single non-Claudia in a repo uses "<Agent> in <Repo>" label

    func testSingleNonClaudia_labelIsAgentInRepo() {
        let f = makeFocus(id: "uuid-3", agent: "cody",
                          path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f])

        XCTAssertEqual(rows.count, 2)
        guard case let .focus(_, label: label, secondary: secondary, indented: indented) = rows[1] else {
            XCTFail("second row should be .focus"); return
        }
        XCTAssertEqual(label, "Cody in Admin Portal",
                       "single non-Claudia: label is '<Agent> in <RepoName>'")
        XCTAssertEqual(secondary, "",
                       "a non-Perri focus with no summary gets an empty but non-nil second line (keeps row height, D6)")
        XCTAssertFalse(indented)
    }

    func testSingleNonClaudia_variousAgents() {
        let agents = ["redd", "ada", "archie", "marty"]
        for agent in agents {
            let f = makeFocus(id: "id-\(agent)", agent: agent,
                              path: "/Users/hammer/Code/nostromo", org: "Carefeed")
            let rows = buildNavRows([f])
            guard case let .focus(_, label: label, secondary: _, indented: _) = rows[1] else {
                XCTFail("\(agent): second row should be .focus"); continue
            }
            XCTAssertEqual(label, "\(agent.capitalized) in Nostromo",
                           "\(agent) in single-focus repo should produce '<Agent> in <Repo>'")
        }
    }

    // MARK: - Test 4: Two or more focuses in same repo → repoHeader + indented rows

    func testMultiFocusRepo_emitsRepoHeaderThenIndentedRows() {
        let f1 = makeFocus(id: "uuid-a", agent: "cody",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let f2 = makeFocus(id: "uuid-b", agent: "redd",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f1, f2])

        // orgHeader, repoHeader, focus(cody), focus(redd)
        XCTAssertEqual(rows.count, 4,
                       "org header + repo header + 2 focus rows = 4 rows")

        XCTAssertEqual(rows[0], .orgHeader("CAREFEED"))
        XCTAssertEqual(rows[1], .repoHeader("Admin Portal"),
                       "two focuses in same repo must emit a repoHeader")

        guard case let .focus(fa, label: labelA, secondary: _, indented: indentedA) = rows[2],
              case let .focus(fb, label: labelB, secondary: _, indented: indentedB) = rows[3] else {
            XCTFail("rows 2 and 3 should be .focus rows"); return
        }

        // Sorted by agentTag: cody < redd
        XCTAssertEqual(fa.agentTag, "cody")
        XCTAssertEqual(labelA, "Cody",
                       "indented focus label is agentTag.capitalized only")
        XCTAssertTrue(indentedA, "focus under repoHeader must be indented")

        XCTAssertEqual(fb.agentTag, "redd")
        XCTAssertEqual(labelB, "Redd")
        XCTAssertTrue(indentedB, "focus under repoHeader must be indented")
    }

    func testMultiFocusRepo_sortedByAgentTagThenId() {
        // Two focuses with same agentTag: sort falls to id
        let f1 = makeFocus(id: "zzz", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let f2 = makeFocus(id: "aaa", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([f1, f2])

        guard case let .focus(first, label: _, secondary: _, indented: _) = rows[2],
              case let .focus(second, label: _, secondary: _, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }
        XCTAssertEqual(first.id, "aaa",
                       "when agentTags tie, sort by id ascending: 'aaa' < 'zzz'")
        XCTAssertEqual(second.id, "zzz")
    }

    // MARK: - Test 5: Disambiguation — same-repo same-agentTag → id prefix as secondary

    func testDisambiguation_sameAgentTag_usesIdPrefix() {
        let f1 = makeFocus(id: "abcdefgh-1111", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let f2 = makeFocus(id: "xxxxxxxx-2222", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([f1, f2])

        guard case let .focus(_, label: _, secondary: sec1, indented: _) = rows[2],
              case let .focus(_, label: _, secondary: sec2, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }

        XCTAssertEqual(sec1, "abcdefgh",
                       "same agentTag collision: secondary is first 8 chars of id")
        XCTAssertEqual(sec2, "xxxxxxxx",
                       "same agentTag collision: secondary is first 8 chars of id")
    }

    func testDisambiguation_sessionSummaryTakesPrecedenceOverIdPrefix() {
        let f1 = makeFocus(id: "abcdefgh-1111", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed",
                           summary: "Working on login flow")
        let f2 = makeFocus(id: "xxxxxxxx-2222", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed",
                           summary: "Fixing search results")
        let rows = buildNavRows([f1, f2])

        guard case let .focus(_, label: _, secondary: sec1, indented: _) = rows[2],
              case let .focus(_, label: _, secondary: sec2, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }

        XCTAssertEqual(sec1, "Working on login flow",
                       "sessionSummary takes precedence over id-prefix disambiguation")
        XCTAssertEqual(sec2, "Fixing search results",
                       "sessionSummary takes precedence over id-prefix disambiguation")
    }

    // MARK: - Test 6: Disambiguation — same-repo different-agentTag, no PR → explicit no-PR string

    func testDisambiguation_differentAgentTags_noSecondary() {
        let f1 = makeFocus(id: "uuid-a", agent: "cody",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let f2 = makeFocus(id: "uuid-b", agent: "redd",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([f1, f2])

        guard case let .focus(_, label: _, secondary: sec1, indented: _) = rows[2],
              case let .focus(_, label: _, secondary: sec2, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }

        XCTAssertEqual(sec1, "",
                       "different agentTags in same repo: no disambiguation needed and no summary, secondary is empty but non-nil (D6)")
        XCTAssertEqual(sec2, "",
                       "different agentTags in same repo: no disambiguation needed and no summary, secondary is empty but non-nil (D6)")
    }

    func testDisambiguation_emptySessionSummary_treatedAsAbsent() {
        // An empty string summary should NOT be used; falls through to id-prefix logic
        let f1 = makeFocus(id: "abcdefgh-x", agent: "ada",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed",
                           summary: "")
        let f2 = makeFocus(id: "12345678-y", agent: "ada",
                           path: "/Users/hammer/Code/nostromo", org: "Carefeed",
                           summary: "")
        let rows = buildNavRows([f1, f2])

        guard case let .focus(_, label: _, secondary: sec1, indented: _) = rows[2],
              case let .focus(_, label: _, secondary: sec2, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }

        // "12345678-y" < "abcdefgh-x" lexicographically (digits precede letters in ASCII),
        // so f2 sorts to rows[2] and f1 to rows[3].
        XCTAssertEqual(sec1, "12345678",
                       "empty sessionSummary falls through to id-prefix disambiguation")
        XCTAssertEqual(sec2, "abcdefgh",
                       "empty sessionSummary falls through to id-prefix disambiguation")
    }

    // MARK: - Test 7: Org ordering — Carefeed before Personal

    func testOrgOrdering_carefeedBeforePersonal() {
        let personal = makeFocus(id: "p1", agent: "claudia",
                                 path: nil, org: "Personal")
        let carefeed = makeFocus(id: "c1", agent: "cody",
                                 path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([personal, carefeed])

        // Should be: CAREFEED header, Cody row, PERSONAL header, claudia row
        XCTAssertEqual(rows[0], .orgHeader("CAREFEED"),
                       "Carefeed org must appear before Personal")
        guard case .orgHeader(let secondHeader) = rows.first(where: { row in
            if case .orgHeader(let h) = row, h == "PERSONAL" { return true }
            return false
        }) else {
            XCTFail("expected a PERSONAL org header in the rows"); return
        }
        XCTAssertEqual(secondHeader, "PERSONAL")

        // Verify CAREFEED index < PERSONAL index
        let carefeedIdx = rows.firstIndex(of: .orgHeader("CAREFEED"))!
        let personalIdx = rows.firstIndex(of: .orgHeader("PERSONAL"))!
        XCTAssertLessThan(carefeedIdx, personalIdx,
                          "CAREFEED header must appear before PERSONAL header")
    }

    func testOrgOrdering_effectiveOrgFallback_projectPathNil_isPersonal() {
        // Legacy focus with org == nil and projectPath == nil → effectiveOrg == "Personal"
        let f = makeFocus(id: "legacy-1", agent: "custom", path: nil, org: nil)
        let rows = buildNavRows([f])

        XCTAssertEqual(rows[0], .orgHeader("PERSONAL"),
                       "focus with nil org and nil projectPath resolves to Personal")
    }

    func testOrgOrdering_effectiveOrgFallback_projectPathPresent_isCarefeed() {
        // Legacy focus with org == nil and projectPath set → effectiveOrg == "Carefeed"
        let f = makeFocus(id: "legacy-2", agent: "cody",
                          path: "/Users/hammer/Code/admin-portal", org: nil)
        let rows = buildNavRows([f])

        XCTAssertEqual(rows[0], .orgHeader("CAREFEED"),
                       "focus with nil org and non-nil projectPath resolves to Carefeed")
    }

    func testOrgOrdering_carefeedBeforePersonalBeforeOthers() {
        let carefeed = makeFocus(id: "cf", agent: "cody",
                                 path: "/Users/hammer/Code/r", org: "Carefeed")
        let personal = makeFocus(id: "pe", agent: "claudia", path: nil, org: "Personal")
        let other    = makeFocus(id: "ot", agent: "ada",
                                 path: "/Users/hammer/Code/r2", org: "Acme")
        let rows = buildNavRows([other, personal, carefeed])

        let headers = rows.compactMap { row -> String? in
            if case let .orgHeader(h) = row { return h }
            return nil
        }
        XCTAssertEqual(headers, ["CAREFEED", "PERSONAL", "ACME"],
                       "org ordering: Carefeed=0, Personal=1, others alphabetically")
    }

    // MARK: - Test 8: Repo ordering — alphabetical within an org

    func testRepoOrdering_alphabeticalWithinOrg() {
        let nostromo = makeFocus(id: "n1", agent: "cody",
                                 path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let admin    = makeFocus(id: "a1", agent: "cody",
                                 path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([nostromo, admin])

        // rows: CAREFEED, "Cody in Admin Portal", "Cody in Nostromo"
        XCTAssertEqual(rows.count, 3)
        guard case let .focus(_, label: firstLabel, secondary: _, indented: _) = rows[1],
              case let .focus(_, label: secondLabel, secondary: _, indented: _) = rows[2] else {
            XCTFail("expected two .focus rows after the org header"); return
        }
        XCTAssertEqual(firstLabel, "Cody in Admin Portal",
                       "Admin Portal (A) must come before Nostromo (N) alphabetically")
        XCTAssertEqual(secondLabel, "Cody in Nostromo")
    }

    func testRepoOrdering_multipleReposAlphabetical() {
        let paths = [
            ("zebra", "Zebra"),
            ("alpha-beta", "Alpha Beta"),
            ("middle-ground", "Middle Ground"),
        ]
        let focuses = paths.enumerated().map { (i, pair) in
            makeFocus(id: "id-\(i)", agent: "redd",
                      path: "/Users/hammer/Code/\(pair.0)", org: "Carefeed")
        }
        let rows = buildNavRows(focuses)

        let focusLabels = rows.compactMap { row -> String? in
            if case let .focus(_, label: l, secondary: _, indented: _) = row { return l }
            return nil
        }
        XCTAssertEqual(focusLabels, [
            "Redd in Alpha Beta",
            "Redd in Middle Ground",
            "Redd in Zebra",
        ], "repos within an org must be ordered alphabetically by repoName")
    }

    // MARK: - Test 9: Focus Codable round-trip

    func testCodable_roundTrip_preservesAllFields() throws {
        let original: [Focus] = [
            makeFocus(id: "uuid-rt-1", agent: "cody",
                      path: "/Users/hammer/Code/admin-portal",
                      org: "Carefeed",
                      summary: "Working on auth"),
            makeFocus(id: "uuid-rt-2", agent: "claudia",
                      path: nil,
                      org: "Personal",
                      summary: nil),
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode([Focus].self, from: data)

        XCTAssertEqual(decoded.count, original.count)

        let first = decoded[0]
        XCTAssertEqual(first.id,             "uuid-rt-1")
        XCTAssertEqual(first.agentTag,       "cody")
        XCTAssertEqual(first.projectPath,    "/Users/hammer/Code/admin-portal")
        XCTAssertEqual(first.org,            "Carefeed")
        XCTAssertEqual(first.sessionSummary, "Working on auth",
                       "non-nil sessionSummary must survive encode→decode")

        let second = decoded[1]
        XCTAssertEqual(second.id,       "uuid-rt-2")
        XCTAssertEqual(second.agentTag, "claudia")
        XCTAssertNil(second.projectPath)
        XCTAssertEqual(second.org, "Personal")
        XCTAssertNil(second.sessionSummary,
                     "nil sessionSummary must survive encode→decode as nil")
    }

    func testCodable_jsonMissingNewFields_decodesAsNil() throws {
        // JSON that predates `org` and `sessionSummary` fields — must not throw,
        // and both new fields must decode as nil.
        let json = """
        {
          "id": "legacy-uuid",
          "agentTag": "cody",
          "projectPath": "/Users/hammer/Code/admin-portal",
          "isBuiltIn": false
        }
        """
        let data = json.data(using: .utf8)!
        let f = try JSONDecoder().decode(Focus.self, from: data)

        XCTAssertEqual(f.id,        "legacy-uuid")
        XCTAssertEqual(f.agentTag,  "cody")
        XCTAssertNil(f.org,
                     "missing 'org' key in JSON must decode as nil")
        XCTAssertNil(f.sessionSummary,
                     "missing 'sessionSummary' key in JSON must decode as nil")
        XCTAssertEqual(f.effectiveOrg, "Carefeed",
                       "nil org + non-nil projectPath → effectiveOrg is Carefeed")
    }

    func testCodable_jsonMissingQuickActions_decodesAsEmptyArray() throws {
        // JSON that predates the `quickActions` field — must not throw, and
        // `quickActions` (non-optional, defaulted to []) must decode as an
        // empty array rather than crashing the whole saved focus list.
        let json = """
        {
          "id": "legacy-uuid",
          "agentTag": "cody",
          "isBuiltIn": false
        }
        """
        let data = json.data(using: .utf8)!
        let f = try JSONDecoder().decode(Focus.self, from: data)

        XCTAssertEqual(f.id, "legacy-uuid")
        XCTAssertEqual(f.agentTag, "cody")
        XCTAssertEqual(f.quickActions, [],
                       "missing 'quickActions' key in JSON must decode as an empty array, not throw")
    }

    // MARK: - Test: Empty focus list → empty rows

    func testEmptyFocuses_producesNoRows() {
        let rows = buildNavRows([])
        XCTAssertTrue(rows.isEmpty,
                      "empty focus list must produce zero rows")
    }

    // MARK: - Test: Pathless non-built-in focuses — sorted alphabetically after canonicals

    func testPathlessNonBuiltIns_appendedAlphabeticallyAfterBuiltIns() {
        let custom1 = makeFocus(id: "x1", agent: "zara", path: nil, org: "Carefeed")
        let custom2 = makeFocus(id: "x2", agent: "bob",  path: nil, org: "Carefeed")
        let all = Focus.builtIns + [custom1, custom2]
        let rows = buildNavRows(all)

        // Rows: orgHeader, fred, mother, perri, teri, bob, zara
        XCTAssertEqual(rows.count, 7)

        guard case let .focus(fifthFocus, label: _, secondary: _, indented: _) = rows[5],
              case let .focus(sixthFocus, label: _, secondary: _, indented: _) = rows[6] else {
            XCTFail("expected .focus rows at index 5 and 6"); return
        }
        XCTAssertEqual(fifthFocus.agentTag, "bob",
                       "non-built-in pathless focuses sorted alpha: bob < zara")
        XCTAssertEqual(sixthFocus.agentTag, "zara")
    }

    // MARK: - W8 (per-focus-pr-indicator): buildNavRows(_:prFor:) gets a new
    // parameter, defaulting to "no PR anywhere", that lets a focus's PR
    // under review win as its secondary line. Deliberately NEW test methods
    // (not edits to the two `XCTAssertNil(secondary, ...)` assertions above,
    // at `testBuiltIns_carefeedOrgHeader_andCanonicalOrder` and
    // `testSingleClaudia_labelIsRepoNameOnly` — those are being updated
    // separately as a mechanical consequence of D6: every row now gets a
    // non-nil secondary by design, superseding the old "no secondary"
    // behavior those two tests asserted).

    func testBuiltInsWithNoPRsAnywhereStillGetANonNilSecondary() {
        let rows = buildNavRows(Focus.builtIns)

        var sawAFocusRow = false
        for row in rows {
            guard case let .focus(f, label: _, secondary: secondary, indented: _) = row else { continue }
            sawAFocusRow = true
            XCTAssertNotNil(secondary, "built-in '\(f.agentTag)' must get a non-nil secondary now that every row renders one (D6)")
            if f.agentTag == "perri" {
                XCTAssertEqual(secondary, NostromoKit.FocusPRLabel.noPR, "Perri with nothing loaded says so explicitly")
            }
        }
        XCTAssertTrue(sawAFocusRow, "sanity check: Focus.builtIns must actually produce .focus rows")
    }

    func testFocusWithAPrForEntryShowsThePrLabelAsSecondary() {
        let f = makeFocus(id: "uuid-1", agent: "perri",
                          path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f]) { tag in
            tag == f.sessionTag ? (repo: "Carefeed/admin-portal", number: 1234) : (nil, nil)
        }

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[1] else {
            XCTFail("expected a .focus row at index 1"); return
        }
        XCTAssertEqual(secondary, NostromoKit.FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 1234),
                       "a focus with a real PR under review must show that PR's label as its secondary")
    }

    func testFocusWithNoPrForEntryButASessionSummaryStillShowsTheSummary() {
        let f1 = makeFocus(id: "uuid-2", agent: "cody",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed",
                           summary: "Working on login flow")
        let f2 = makeFocus(id: "uuid-3", agent: "redd",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f1, f2]) { _ in (nil, nil) }

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[2] else {
            XCTFail("expected a .focus row at index 2"); return
        }
        XCTAssertEqual(secondary, "Working on login flow",
                       "no-PR precedence must be preserved: an existing sessionSummary still wins when there is no PR")
    }

    func testFocusWithBothASessionSummaryAndAPrForEntryShowsThePrNotTheSummary() {
        let f1 = makeFocus(id: "uuid-4", agent: "perri",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed",
                           summary: "Working on login flow")
        let f2 = makeFocus(id: "uuid-5", agent: "redd",
                           path: "/Users/hammer/Code/admin-portal", org: "Carefeed")
        let rows = buildNavRows([f1, f2]) { tag in
            tag == f1.sessionTag ? (repo: "Carefeed/admin-portal", number: 42) : (nil, nil)
        }

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[2] else {
            XCTFail("expected a .focus row at index 2"); return
        }
        XCTAssertEqual(secondary, NostromoKit.FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 42),
                       "a PR under review must win over an existing sessionSummary (D5), mirrored here from buildNavRows' own independent implementation")
        XCTAssertNotEqual(secondary, "Working on login flow")
    }

    func testTwoFocusesInTheSameRepoGroupWithDifferentPrForPRsGetDifferentSecondaries() {
        let f1 = makeFocus(id: "uuid-6", agent: "perri", path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let f2 = makeFocus(id: "uuid-7", agent: "perri", path: "/Users/hammer/Code/nostromo", org: "Carefeed")
        let rows = buildNavRows([f1, f2]) { tag in
            switch tag {
            case f1.sessionTag: return (repo: "Carefeed/nostromo", number: 10)
            case f2.sessionTag: return (repo: "Carefeed/nostromo", number: 20)
            default: return (nil, nil)
            }
        }

        guard case let .focus(_, label: _, secondary: secA, indented: _) = rows[2],
              case let .focus(_, label: _, secondary: secB, indented: _) = rows[3] else {
            XCTFail("expected .focus rows at index 2 and 3"); return
        }
        XCTAssertNotEqual(secA, secB, "two different focuses' PRs in the same repo group must never collapse to the same secondary")
    }

    // MARK: - Only a Perri focus shows its PR; others show their session summary

    func testNonPerriFocusNeverShowsAPrEvenWhenOneIsPinnedToIt() {
        let f = makeFocus(id: "uuid-8", agent: "cody",
                          path: "/Users/hammer/Code/admin-portal", org: "Carefeed",
                          summary: "Fixing the login flow")
        let rows = buildNavRows([f]) { _ in (repo: "Carefeed/admin-portal", number: 7) }

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[1] else {
            XCTFail("expected a .focus row at index 1"); return
        }
        XCTAssertEqual(secondary, "Fixing the login flow",
                       "a non-Perri focus is about some other activity: it shows its summary, never a PR label")
    }

    func testPerriWithNothingLoadedSaysNoPrEvenWithASessionSummary() {
        let f = makeFocus(id: "uuid-9", agent: "perri",
                          path: "/Users/hammer/Code/admin-portal", org: "Carefeed",
                          summary: "Reviewing the queue")
        let rows = buildNavRows([f]) { _ in (nil, nil) }

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[1] else {
            XCTFail("expected a .focus row at index 1"); return
        }
        XCTAssertEqual(secondary, NostromoKit.FocusPRLabel.noPR,
                       "Perri's second line answers 'which PR am I in', not narration")
    }

    func testPathlessNonPerriFocusShowsItsSessionSummary() {
        var f = makeFocus(id: "fred", agent: "fred", path: nil, org: "Carefeed")
        f.sessionSummary = "Triaging the inbox"
        let rows = buildNavRows([f])

        guard case let .focus(_, label: _, secondary: secondary, indented: _) = rows[1] else {
            XCTFail("expected a .focus row at index 1"); return
        }
        XCTAssertEqual(secondary, "Triaging the inbox")
    }

    // MARK: - Multiple sessions per agent + repo: labels and branches
    //
    // Several sessions of the same agent can now live in the same repo, so a
    // row has to say *which* one it is: the user's label is the name, the git
    // branch is the context, and the 8-char id prefix is the last resort for
    // two sessions that are otherwise indistinguishable.

    private let portal = "/Users/hammer/Code/admin-portal"

    private func makeLabeled(
        id: String,
        agent: String = "claudia",
        path: String? = "/Users/hammer/Code/admin-portal",
        label: String? = nil,
        summary: String? = nil
    ) -> Focus {
        var f = makeFocus(id: id, agent: agent, path: path, org: "Carefeed", summary: summary)
        f.label = label
        return f
    }

    /// Build rows with a branch table keyed by focus id.
    private func rows(_ focuses: [Focus], branches: [String: String] = [:]) -> [NavRow] {
        buildNavRows(focuses, prFor: { _ in (nil, nil) }, branchFor: { branches[$0.id] })
    }

    private struct FocusRow { let label: String; let secondary: String?; let indented: Bool }

    private func focusRow(_ id: String, in rows: [NavRow], file: StaticString = #filePath, line: UInt = #line) -> FocusRow? {
        for row in rows {
            if case let .focus(f, label: label, secondary: secondary, indented: indented) = row, f.id == id {
                return FocusRow(label: label, secondary: secondary, indented: indented)
            }
        }
        XCTFail("no .focus row for id \(id)", file: file, line: line)
        return nil
    }

    // Ids are >= 8 chars so the id-prefix disambiguator is well-defined.
    private let idA = "AAAAAAAA-0000-0000-0000-000000000001"
    private let idB = "BBBBBBBB-0000-0000-0000-000000000002"
    private let idC = "CCCCCCCC-0000-0000-0000-000000000003"
    private var prefixA: String { String(idA.prefix(8)) }
    private var prefixB: String { String(idB.prefix(8)) }

    // MARK: Labels as row names

    func testLoneLabeledFocusUsesItsLabelAsTheRowLabel() {
        let claudia = makeLabeled(id: idA, agent: "claudia", label: "Hotfix")
        let r = rows([claudia])
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Hotfix",
                       "a lone Claudia would otherwise be named after the repo")
        XCTAssertEqual(focusRow(idA, in: r)?.indented, false)
    }

    func testLoneLabeledNonClaudiaFocusUsesItsLabelInsteadOfAgentInRepo() {
        let cody = makeLabeled(id: idA, agent: "cody", label: "Hotfix")
        XCTAssertEqual(focusRow(idA, in: rows([cody]))?.label, "Hotfix")
    }

    func testLoneUnlabeledFocusKeepsItsDefaultRowLabel() {
        let claudia = makeLabeled(id: idA, agent: "claudia")
        let cody = makeLabeled(id: idB, agent: "cody", path: "/Users/hammer/Code/other-repo")
        let r = rows([claudia, cody])
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Admin Portal")
        XCTAssertEqual(focusRow(idB, in: r)?.label, "Cody in Other Repo")
    }

    func testTwoSameAgentSameRepoFocusesWithDifferentLabelsRenderBothLabels() {
        let a = makeLabeled(id: idA, label: "Hotfix")
        let b = makeLabeled(id: idB, label: "Refactor")
        let r = rows([a, b])

        XCTAssertEqual(r.count, 4, "org header + repo header + two rows")
        XCTAssertEqual(r[0], .orgHeader("CAREFEED"))
        XCTAssertEqual(r[1], .repoHeader("Admin Portal"))
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Hotfix")
        XCTAssertEqual(focusRow(idB, in: r)?.label, "Refactor")
        XCTAssertEqual(focusRow(idA, in: r)?.indented, true)
        XCTAssertEqual(focusRow(idB, in: r)?.indented, true)
    }

    func testDifferentLabelsAreEnoughToTellRowsApartSoNoIdPrefixIsShown() {
        let a = makeLabeled(id: idA, label: "Hotfix")
        let b = makeLabeled(id: idB, label: "Refactor")
        let r = rows([a, b])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "")
    }

    func testLabeledAndUnlabeledSameAgentFocusesAreDistinctSoNoIdPrefix() {
        let a = makeLabeled(id: idA, label: "Hotfix")
        let b = makeLabeled(id: idB, label: nil)
        let r = rows([a, b])
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Hotfix")
        XCTAssertEqual(focusRow(idB, in: r)?.label, "Claudia")
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "")
    }

    func testLabeledPerriFocusKeepsItsPrLineInsteadOfBranch() {
        let perri = makeLabeled(id: idA, agent: "perri", label: "Review A")
        let r = buildNavRows([perri], prFor: { _ in (nil, nil) }, branchFor: { _ in "main" })
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Review A")
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, NostromoKit.FocusPRLabel.noPR)
    }

    // MARK: Branch on the secondary line

    func testBranchAloneIsTheSecondaryWhenThereIsNoSummary() {
        let f = makeLabeled(id: idA, agent: "cody")
        XCTAssertEqual(focusRow(idA, in: rows([f], branches: [idA: "feat/login"]))?.secondary, "feat/login")
    }

    func testBranchAndSummaryAreJoinedWithAMiddleDot() {
        let f = makeLabeled(id: idA, agent: "cody", summary: "Fixing the login flow")
        XCTAssertEqual(focusRow(idA, in: rows([f], branches: [idA: "feat/login"]))?.secondary,
                       "feat/login · Fixing the login flow")
    }

    func testSummaryAloneIsTheSecondaryWhenThereIsNoBranch() {
        let f = makeLabeled(id: idA, agent: "cody", summary: "Fixing the login flow")
        XCTAssertEqual(focusRow(idA, in: rows([f]))?.secondary, "Fixing the login flow")
    }

    func testNoBranchAndNoSummaryGivesAnEmptySecondaryNotNil() {
        let f = makeLabeled(id: idA, agent: "cody")
        let secondary = focusRow(idA, in: rows([f]))?.secondary
        XCTAssertNotNil(secondary)
        XCTAssertEqual(secondary, "")
    }

    func testEmptySummaryIsTreatedAsAbsentWhenCombiningWithBranch() {
        let f = makeLabeled(id: idA, agent: "cody", summary: "")
        XCTAssertEqual(focusRow(idA, in: rows([f], branches: [idA: "main"]))?.secondary, "main")
    }

    func testBranchShowsOnRowsInsideARepoGroupToo() {
        let a = makeLabeled(id: idA, agent: "cody", summary: "Fixing login")
        let b = makeLabeled(id: idB, agent: "claudia")
        let r = rows([a, b], branches: [idA: "feat/login", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "feat/login · Fixing login")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main")
    }

    func testPerriRowShowsNoPrEvenWhenItsBranchIsKnown() {
        let perri = makeLabeled(id: idA, agent: "perri")
        let r = buildNavRows([perri], prFor: { _ in (nil, nil) }, branchFor: { _ in "main" })
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, NostromoKit.FocusPRLabel.noPR)
    }

    func testPerriRowShowsItsPrLabelRegardlessOfBranch() {
        let perri = makeLabeled(id: idA, agent: "perri", summary: "Reviewing the queue")
        let r = buildNavRows([perri],
                             prFor: { _ in (repo: "Carefeed/admin-portal", number: 42) },
                             branchFor: { _ in "feat/x" })
        XCTAssertEqual(focusRow(idA, in: r)?.secondary,
                       NostromoKit.FocusPRLabel.label(repo: "Carefeed/admin-portal", number: 42))
    }

    func testPathlessAndBuiltInRowsAreUnchangedByBranch() {
        var fred = Focus.builtIns.first { $0.id == "fred" }!
        fred.sessionSummary = "Triaging the inbox"
        let withBranch = buildNavRows(Focus.builtIns, prFor: { _ in (nil, nil) }, branchFor: { _ in "main" })
        let without = buildNavRows(Focus.builtIns)
        XCTAssertEqual(withBranch, without, "built-ins have no repo, so a branch lookup must change nothing")

        let pathless = buildNavRows([fred], prFor: { _ in (nil, nil) }, branchFor: { _ in "main" })
        XCTAssertEqual(focusRow("fred", in: pathless)?.secondary, "Triaging the inbox")
    }

    func testTwoSameAgentSameRepoFocusesWithNoLabelsButDifferentBranchesShowTheirBranches() {
        let a = makeLabeled(id: idA)
        let b = makeLabeled(id: idB)
        let r = rows([a, b], branches: [idA: "main", idB: "feat/login"])
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Claudia")
        XCTAssertEqual(focusRow(idB, in: r)?.label, "Claudia")
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "feat/login")
    }

    func testBranchLookupIsPerFocusSoTheClosureSeesTheFocusBeingRendered() {
        // Two worktrees of one repo can't share a project path in practice, but
        // the lookup contract is "ask about this focus" — verify it is asked
        // about each path-bearing focus and answers are not mixed up.
        let a = makeLabeled(id: idA, agent: "cody")
        let b = makeLabeled(id: idB, agent: "claudia")
        var asked: [String] = []
        let r = buildNavRows([a, b], prFor: { _ in (nil, nil) }, branchFor: { f in
            asked.append(f.id)
            return f.id == self.idA ? "branch-a" : "branch-b"
        })
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "branch-a")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "branch-b")
        XCTAssertTrue(asked.contains(idA) && asked.contains(idB))
    }

    // MARK: Id-prefix disambiguator: only for otherwise-identical siblings

    func testIdenticalUnlabeledSameAgentSiblingsWithNoBranchGetIdPrefixAsToday() {
        let r = rows([makeLabeled(id: idA), makeLabeled(id: idB)])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, prefixA)
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, prefixB)
    }

    func testIdenticalSiblingsOnTheSameBranchGetBranchThenIdPrefix() {
        let r = rows([makeLabeled(id: idA), makeLabeled(id: idB)], branches: [idA: "main", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main · \(prefixA)")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main · \(prefixB)")
    }

    func testSiblingsWithTheSameLabelAndNoBranchGetIdPrefixOnly() {
        let r = rows([makeLabeled(id: idA, label: "Hotfix"), makeLabeled(id: idB, label: "Hotfix")])
        XCTAssertEqual(focusRow(idA, in: r)?.label, "Hotfix")
        XCTAssertEqual(focusRow(idB, in: r)?.label, "Hotfix")
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, prefixA)
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, prefixB)
    }

    func testSiblingsWithTheSameLabelAndSameBranchGetBranchThenIdPrefix() {
        let r = rows([makeLabeled(id: idA, label: "Hotfix"), makeLabeled(id: idB, label: "Hotfix")],
                     branches: [idA: "fix/x", idB: "fix/x"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "fix/x · \(prefixA)")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "fix/x · \(prefixB)")
    }

    func testSameLabelButDifferentBranchesNeedNoIdPrefix() {
        let r = rows([makeLabeled(id: idA, label: "Hotfix"), makeLabeled(id: idB, label: "Hotfix")],
                     branches: [idA: "fix/a", idB: "fix/b"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "fix/a")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "fix/b")
    }

    func testOneKnownBranchAndOneUnknownBranchAreDistinctSoNoIdPrefix() {
        let r = rows([makeLabeled(id: idA), makeLabeled(id: idB)], branches: [idA: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "")
    }

    func testDifferentLabelsOnTheSameBranchNeedNoIdPrefix() {
        let r = rows([makeLabeled(id: idA, label: "Hotfix"), makeLabeled(id: idB, label: "Refactor")],
                     branches: [idA: "main", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main")
    }

    func testSiblingsThatEachHaveASummaryNeedNoIdPrefix() {
        let r = rows([makeLabeled(id: idA, summary: "Doing A"), makeLabeled(id: idB, summary: "Doing B")],
                     branches: [idA: "main", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main · Doing A")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main · Doing B")
    }

    func testOnlyTheIdenticalPairGetsIdPrefixWhenAThirdSiblingDiffers() {
        let r = rows([makeLabeled(id: idA), makeLabeled(id: idB), makeLabeled(id: idC)],
                     branches: [idA: "main", idB: "main", idC: "feat/other"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main · \(prefixA)")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main · \(prefixB)")
        XCTAssertEqual(focusRow(idC, in: r)?.secondary, "feat/other")
    }

    func testDifferentAgentsInTheSameRepoNeverGetAnIdPrefix() {
        let r = rows([makeLabeled(id: idA, agent: "claudia"), makeLabeled(id: idB, agent: "cody")],
                     branches: [idA: "main", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main")
    }

    func testIdenticalSiblingsInDifferentReposDoNotTriggerAnIdPrefix() {
        let a = makeLabeled(id: idA, path: "/Users/hammer/Code/alpha")
        let b = makeLabeled(id: idB, path: "/Users/hammer/Code/beta")
        let r = rows([a, b], branches: [idA: "main", idB: "main"])
        XCTAssertEqual(focusRow(idA, in: r)?.secondary, "main")
        XCTAssertEqual(focusRow(idB, in: r)?.secondary, "main")
    }

    // MARK: Every focus row always has a second line, and it is one line

    func testEveryFocusRowHasANonNilSecondaryWhateverItCarries() {
        let focuses = Focus.builtIns + [
            makeLabeled(id: idA, label: "Hotfix"),
            makeLabeled(id: idB, agent: "cody", label: "Spike", summary: "Poking at it"),
            makeLabeled(id: idC, agent: "cody", path: "/Users/hammer/Code/other"),
        ]
        let r = rows(focuses, branches: [idA: "main", idB: "feat/spike"])
        var count = 0
        for row in r {
            guard case let .focus(f, label: _, secondary: secondary, indented: _) = row else { continue }
            count += 1
            XCTAssertNotNil(secondary, "\(f.id) must always render a second line (stable row height)")
        }
        XCTAssertEqual(count, focuses.count)
    }

    func testMultiLineSummaryIsCollapsedToOneLine() {
        let f = makeLabeled(id: idA, agent: "cody", summary: "Line one\nLine two\nLine three")
        let secondary = focusRow(idA, in: rows([f]))?.secondary
        XCTAssertEqual(secondary, "Line one Line two Line three")
        XCTAssertFalse(secondary?.contains("\n") ?? true)
    }

    func testMultiLineSummaryIsCollapsedWhenCombinedWithABranch() {
        let f = makeLabeled(id: idA, agent: "cody", summary: "Line one\nLine two")
        XCTAssertEqual(focusRow(idA, in: rows([f], branches: [idA: "main"]))?.secondary,
                       "main · Line one Line two")
    }

    func testMultiLineSummaryIsCollapsedOnPathlessRowsToo() {
        var fred = Focus.builtIns.first { $0.id == "fred" }!
        fred.sessionSummary = "Triaging\ninbox"
        XCTAssertEqual(focusRow("fred", in: rows([fred]))?.secondary, "Triaging inbox")
    }
}
