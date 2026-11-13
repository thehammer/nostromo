// NostromoKit — SlashCommandFilterTests.swift
//
// What the picker lists for what the user typed after the `/`. Case-insensitive, in rank order:
// exact name, name prefix, prefix of the segment after ':', alias prefix, subsequence. Ties sort by
// name; an empty query is everything sorted by name. Also pins the built-in fallback table.

import XCTest
@testable import NostromoKit

final class SlashCommandFilterTests: XCTestCase {

    private func e(_ name: String, aliases: [String] = []) -> SlashCommandEntryWire {
        SlashCommandEntryWire(name: name, aliases: aliases)
    }

    private func names(_ query: String, _ entries: [SlashCommandEntryWire]) -> [String] {
        SlashCommandFilter.rank(query: query, in: entries).map(\.name)
    }

    // MARK: - Rank order

    func testTiersRankExactThenPrefixThenAfterColonThenAliasThenSubsequence() {
        let entries = [e("remodel"), e("zed", aliases: ["modern"]), e("foo:model"), e("model"), e("mod")]

        XCTAssertEqual(names("mod", entries), ["mod", "model", "foo:model", "zed", "remodel"])
    }

    func testTiesWithinATierSortByName() {
        XCTAssertEqual(names("b", [e("bc"), e("ba"), e("bb")]), ["ba", "bb", "bc"])
    }

    func testMatchingIsCaseInsensitiveInBothDirections() {
        XCTAssertEqual(names("REV", [e("review"), e("Review-all")]), ["Review-all", "review"])
        XCTAssertEqual(names("rev", [e("REVIEW")]), ["REVIEW"])
    }

    func testANamePrefixBeatsTheSameTextAfterAColon() {
        XCTAssertEqual(names("li", [e("hookify:list"), e("alien"), e("list"), e("lint")]),
                       ["lint", "list", "hookify:list", "alien"])
    }

    func testASubsequenceMatchesWhenNothingStrongerDoes() {
        XCTAssertEqual(names("mdl", [e("model"), e("clear")]), ["model"])
    }

    func testNoMatchIsAnEmptyList() {
        XCTAssertEqual(names("zzzz", [e("model"), e("clear")]), [])
    }

    func testAnEmptyQueryReturnsEverythingSortedByName() {
        XCTAssertEqual(names("", [e("usage"), e("clear"), e("model"), e("compact")]),
                       ["clear", "compact", "model", "usage"])
    }

    func testRankingNeverInventsOrDropsEntries() {
        let entries = [e("alpha"), e("beta")]

        XCTAssertEqual(SlashCommandFilter.rank(query: "a", in: entries).count, 2, "alpha by prefix, beta by subsequence")
        XCTAssertEqual(SlashCommandFilter.rank(query: "", in: []).count, 0)
    }

    // MARK: - Aliases on the real table

    func testTheCostAliasFindsUsage() {
        XCTAssertEqual(names("cost", BuiltinSlashCommands.fallback).first, "usage")
    }

    func testAnAliasPrefixFindsItsCommandAboveALooserMatch() {
        XCTAssertEqual(names("sta", BuiltinSlashCommands.fallback).first, "usage")
        XCTAssertEqual(names("res", BuiltinSlashCommands.fallback).first, "clear", "`reset` is clear's alias")
    }

    func testSlashConFindsOnlyContextInTheFallbackTable() {
        XCTAssertEqual(names("con", BuiltinSlashCommands.fallback), ["context"])
    }

    // MARK: - Size

    func testFiveHundredEntriesRankCorrectlyAndQuickly() {
        var entries = (0..<500).map { e(String(format: "cmd-%03d", $0)) }
        entries.append(e("hookify:target"))
        entries.shuffle()

        let start = Date()
        var prefixed: [String] = []
        for _ in 0..<20 { prefixed = names("cmd-49", entries) }
        let all = names("", entries)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(prefixed, (490...499).map { "cmd-\($0)" })
        XCTAssertEqual(all.count, 501)
        XCTAssertEqual(all, all.sorted())
        XCTAssertLessThan(elapsed, 5, "ranking 500 entries per keystroke must be cheap")
    }

    // MARK: - The fallback table

    func testTheFallbackTableHoldsExactlyTheElevenKnownCommands() {
        XCTAssertEqual(Set(BuiltinSlashCommands.fallback.map(\.name)),
                       ["clear", "compact", "context", "effort", "init", "mcp", "model", "rename",
                        "reload-skills", "security-review", "usage"])
        XCTAssertEqual(BuiltinSlashCommands.fallback.count, 11, "no duplicates")
    }

    func testEveryFallbackEntryHasADescriptionAndIsBuiltin() {
        for entry in BuiltinSlashCommands.fallback {
            XCTAssertFalse(entry.description?.isEmpty ?? true, entry.name)
            XCTAssertTrue(entry.builtin, entry.name)
        }
    }

    func testUsageCarriesTheCostAndStatsAliases() throws {
        let usage = try XCTUnwrap(BuiltinSlashCommands.fallback.first { $0.name == "usage" })

        XCTAssertEqual(Set(usage.aliases), ["cost", "stats"])
    }

    func testTheTableDescribesByExactNameOnly() {
        XCTAssertNotNil(BuiltinSlashCommands.description(for: "context"))
        XCTAssertNil(BuiltinSlashCommands.description(for: "Context"))
        XCTAssertNil(BuiltinSlashCommands.description(for: "hookify:list"))
        XCTAssertNil(BuiltinSlashCommands.description(for: "cost"), "an alias is not a name")
        XCTAssertNil(BuiltinSlashCommands.description(for: ""))
    }
}
