import XCTest
import Foundation

// `StagingDestructivePatterns` and `StagingHazards`: what the app says about a command's text, with no views.
//
//   * The fixed destructive-pattern list (PRD SR6): a table of positive and negative cases for every pattern.
//     A match only labels the row (and, in a production-treated pane, asks first). Every label ends with
//     "No label does not mean safe."; no code path produces a safe, green or check-mark label.
//   * History expansion: the same rule the daemon applies (the cases here are the ones in
//     `tests/fixtures/terminal_staging/hazards.json`).
//   * The look-alike non-ASCII label: code points and names, at most three, then "and N more".

final class StagingHazardsTests: XCTestCase {

    // MARK: Destructive patterns

    func testEveryPatternMatchesItsPositiveCases() {
        let positives: [(command: String, names: [String])] = [
            ("rm -rf /tmp/x", ["rm -rf"]), ("rm -fr /tmp/x", ["rm -rf"]), ("rm -Rf /tmp/x", ["rm -rf"]),
            ("rm -r -f x", ["rm -rf"]), ("rm -f -r x", ["rm -rf"]),
            ("rm --recursive --force x", ["rm -rf", "--force"]), ("rm -r --force x", ["rm -rf", "--force"]), ("sudo rm -rf x && ls", ["rm -rf"]),
            ("ls; rm -rf x", ["rm -rf"]),
            ("DROP TABLE users", ["DROP"]), ("drop table users", ["DROP"]), ("psql -c 'drop database x'", ["DROP"]),
            ("TRUNCATE TABLE users", ["TRUNCATE"]), ("truncate users", ["TRUNCATE"]),
            ("DELETE FROM users", ["DELETE FROM without WHERE"]), ("delete from users;", ["DELETE FROM without WHERE"]),
            ("php artisan migrate:fresh", ["migrate:fresh"]), ("php artisan db:wipe", ["db:wipe"]),
            ("php artisan queue:flush", ["queue:flush"]), ("php artisan cache:clear", ["cache:clear"]),
            ("PHP ARTISAN MIGRATE:FRESH", ["migrate:fresh"]),
            ("git push --force", ["--force"]), ("git push --force-with-lease", ["--force"]), ("composer install --force", ["--force"]),
            ("kill -9 123", ["kill -9"]), ("pkill -9 x", ["kill -9"]), ("killall -KILL x", ["kill -9"]),
            ("kill -SIGKILL 1", ["kill -9"]), ("kill -s 9 1", ["kill -9"]), ("kill -s KILL 1", ["kill -9"]),
            ("kill -s SIGKILL 1", ["kill -9"]),
            ("php artisan queue:flush && php artisan cache:clear", ["queue:flush", "cache:clear"]),
            ("rm -rf x; DROP TABLE y", ["rm -rf", "DROP"]),
        ]
        for (command, names) in positives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), names, command)
        }
    }

    func testTheNegativeCasesMatchNothing() {
        let negatives = [
            "ls -la", "git push", "git status", "rm x", "rm -r x", "rm -f x", "rm -v x", "echo -rf",
            "rm x | grep -rf y", "rm x; echo -rf", "DELETE FROM users WHERE id = 1", "delete from t where x=1",
            "echo drops", "echo truncated", "git push --forceful", "kill 123", "kill -15 1", "kill -s 15 1",
            "pkill -f x", "cat migrate", "php artisan cache:forget x",
        ]
        for command in negatives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testTheListIsExactlyTheFixedOneInOrder() {
        XCTAssertEqual(StagingDestructivePatterns.names, ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh",
                                                          "db:wipe", "queue:flush", "cache:clear", "--force", "kill -9"])
    }

    func testEveryPatternLabelSaysNoLabelDoesNotMeanSafeAndNothingSaysSafe() {
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: true),
                       "\u{26A0} Matches a destructive pattern (queue:flush). Insert asks first. No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: false),
                       "\u{26A0} Matches a destructive pattern (queue:flush). No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["rm -rf", "DROP"], production: true),
                       "\u{26A0} Matches a destructive pattern (rm -rf, DROP). Insert asks first. No label does not mean safe.")
        XCTAssertNil(StagingHazards.destructiveLabel([], production: true), "no match, no label")
        for production in [true, false] {
            for name in StagingDestructivePatterns.names {
                let label = StagingHazards.destructiveLabel([name], production: production) ?? ""
                XCTAssertTrue(label.contains("No label does not mean safe."), label)
                XCTAssertFalse(label.replacingOccurrences(of: "No label does not mean safe.", with: "").lowercased().contains("safe"), label)
                XCTAssertFalse(label.contains("\u{2713}") || label.contains("\u{2705}"), label)
            }
        }
    }

    // MARK: Wrapped, split and abbreviated forms (M2, S4, P4)

    func testRmRfIsSeenThroughWrapping() {
        let wrapped = [
            "bash -c 'rm -rf /srv/app/cache'", "sh -c \"rm -rf x\"", "echo $(rm -rf x)", "echo `rm -rf x`", "(rm -rf x)",
            "{ rm -rf x; }", "\\rm -rf x", "\"rm\" -rf x", "r''m -rf x", "command rm -rf x", "/bin/rm -rf x", "env rm -rf x",
            "rm -r --forc x", "rm --recurs -f x", "rm -rf x", "ls & rm -rf x", "xargs rm -rf",
        ]
        for command in wrapped {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("rm -rf"), command)
        }
        XCTAssertFalse(StagingDestructivePatterns.matches("bash -c 'rm x'").contains("rm -rf"))
        XCTAssertFalse(StagingDestructivePatterns.matches("echo \"rm\" -r x").contains("rm -rf"))
    }

    func testLaravelAbbreviationsAndSplitWordsMatch() {
        let cases: [(String, String)] = [
            ("php artisan ca:cl", "cache:clear"), ("php artisan q:fl", "queue:flush"), ("php artisan mi:fr", "migrate:fresh"),
            ("php artisan db:w", "db:wipe"), ("php artisan migrate:fre''sh", "migrate:fresh"),
            ("php artisan cache:cle\\ar", "cache:clear"), ("php artisan \"queue\":flush", "queue:flush"),
        ]
        for (command, name) in cases {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains(name), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan cache:forget x"), [])
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan route:list"), [])
    }

    func testSqlCommentsAndShortKillAndForceForms() {
        XCTAssertTrue(StagingDestructivePatterns.matches("mysql -e 'DROP/**/TABLE users'").contains("DROP"))
        XCTAssertTrue(StagingDestructivePatterns.matches("DELETE/**/FROM users").contains("DELETE FROM without WHERE"))
        XCTAssertTrue(StagingDestructivePatterns.matches("kill -n 9 123").contains("kill -9"))
        XCTAssertTrue(StagingDestructivePatterns.matches("git push --forc").contains("--force"))
        XCTAssertEqual(StagingDestructivePatterns.matches("git log --format=x"), [])
    }

    func testEachDeleteStatementIsCheckedOnItsOwn() {
        for command in ["DELETE FROM a WHERE id=1; DELETE FROM b", "DELETE FROM a; SELECT * FROM b WHERE x = 1",
                        "delete from a where id=1; delete from b; select 1"] {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("DELETE FROM without WHERE"), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("DELETE FROM a WHERE id=1; DELETE FROM b WHERE id=2"), [])
    }

    func testEveryNonASCIIScalarIsIsolatedFromTheTextBesideIt() {
        let label = StagingHazards.nonASCIILabel("\u{05D0}") ?? ""
        XCTAssertTrue(label.contains("\u{2068}\u{05D0}\u{2069} U+05D0"), label)
    }

    // MARK: History expansion (the cases of tests/fixtures/terminal_staging/hazards.json)

    func testHistoryExpansionRule() {
        let positives = ["!!", "!ssh", "!$", "!-2", "!#", "!ls -la", "echo hi !!", "^a^b", "^foo", "r", "fc -l", "history",
                         "history | grep x", "ls; r", "ls && fc", "ls || history", "ls | r 2",
                         // `fc` and `history` count as a word anywhere (S2 review): asking is the cheap side.
                         "grep history x", "rg fc"]
        for command in positives { XCTAssertTrue(StagingHazards.usesHistoryExpansion(command), command) }
        let negatives = ["[ a != b ]", "echo hi!", "echo ! x", "git status", "ls -r", "echo r", "echo !(x)",
                         "echo ^caret", "ls -la", "echo a!=b", "ls r"]
        for command in negatives { XCTAssertFalse(StagingHazards.usesHistoryExpansion(command), command) }
    }

    /// Every case in the file the daemon's tests read too: both sides must say the same.
    func testTheSharedFixtureGivesTheSameAnswerAsTheDaemon() throws {
        let cases = try StagingFixtures.hazards()
        XCTAssertGreaterThan(cases.count, 60, "hazards.json should be found")
        for entry in cases {
            let text = try XCTUnwrap(entry["text"] as? String)
            let expected = try XCTUnwrap(entry["history"] as? Bool)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(entry["name"] ?? "?"): \(text)")
        }
    }

    // MARK: Non-ASCII

    func testALookAlikeLetterIsNamedWithItsCodePoint() {
        XCTAssertEqual(StagingHazards.nonASCIILabel("echo \u{0430}"),
                       "\u{26A0} Contains non-ASCII: \u{2068}\u{0430}\u{2069} U+0430 CYRILLIC SMALL LETTER A")
        XCTAssertNil(StagingHazards.nonASCIILabel("echo hello"))
    }

    func testAtMostThreeDistinctScalarsAreNamedThenAndNMore() {
        let label = StagingHazards.nonASCIILabel("\u{0430}\u{0430}\u{0431}\u{0432}\u{0433}\u{0434}") ?? ""
        XCTAssertTrue(label.contains("U+0430"), label)
        XCTAssertTrue(label.contains("U+0431"), label)
        XCTAssertTrue(label.contains("U+0432"), label)
        XCTAssertFalse(label.contains("U+0433"), label)
        XCTAssertTrue(label.hasSuffix("and 2 more"), label)
        XCTAssertEqual(label.components(separatedBy: "U+0430").count - 1, 1, "a repeated scalar is named once")
    }

    /// The shared fixture the daemon's tests read too: every case's `history` flag is what the app computes.
    func testTheSharedHazardsFixtureAgreesWithTheAppsHistoryRule() throws {
        let data = try StagingFixtures.fixtureData("hazards.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 25, "hazards.json should be found")
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let text = try XCTUnwrap(entry["text"] as? String, name)
            let expected = try XCTUnwrap(entry["history"] as? Bool, name)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(name): \(text)")
        }
    }
}
