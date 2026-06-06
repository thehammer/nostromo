import XCTest
// Focus, NavRow, and buildNavRows are compiled into this target directly
// (logic test — no host app). No module imports needed.

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
            XCTAssertNil(secondary,
                         "built-in pathless focuses have no secondary label")
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
        XCTAssertNil(secondary,
                     "single focus in repo has no secondary")
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
        XCTAssertNil(secondary)
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

    // MARK: - Test 6: Disambiguation — same-repo different-agentTag → secondary is nil

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

        XCTAssertNil(sec1,
                     "different agentTags in same repo: no disambiguation needed, secondary must be nil")
        XCTAssertNil(sec2,
                     "different agentTags in same repo: no disambiguation needed, secondary must be nil")
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
}
