import XCTest
@testable import NostromoKit

// L1 coverage for `RevisionLabel` (ios-curated-view-parity W7, D6). The
// criterion this exists to make testable with no device: "the view names the
// path and the revision it is showing, so `working` and a PR head SHA are
// distinguishable."

final class RevisionLabelTests: XCTestCase {

    func testWorkingRendersAsAPhraseContainingWorkingNotResemblingAHash() {
        let label = RevisionLabel.short("working")
        XCTAssertTrue(label.lowercased().contains("working"))
        XCTAssertFalse(label.allSatisfy(\.isHexDigit), "must not read like a hash")
    }

    func testFortyCharacterSHAAbbreviatesToSevenOrEightCharactersThatIsAPrefix() {
        let sha = "1234567890abcdef1234567890abcdef12345678"
        let label = RevisionLabel.short(sha)
        XCTAssertTrue(label.count == 7 || label.count == 8, "expected a 7–8 character abbreviation, got \(label.count)")
        XCTAssertTrue(sha.hasPrefix(label), "the abbreviation must be a literal prefix of the full SHA")
    }

    func testShortSHARendersAsItself() {
        let short = "abc1234"
        XCTAssertEqual(RevisionLabel.short(short), short)
    }

    func testBranchOrTagRefRendersAsItself() {
        XCTAssertEqual(RevisionLabel.short("feature/ios-parity-w7-file"), "feature/ios-parity-w7-file")
        XCTAssertEqual(RevisionLabel.short("main"), "main")
    }

    func testEmptyRevisionRendersAsAStatedUnknownRatherThanBlank() {
        let label = RevisionLabel.short("")
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(label.lowercased().contains("unknown"))
    }

    func testWorkingAndAPRHeadSHAAreDistinguishable() {
        let workingLabel = RevisionLabel.short("working")
        let shaLabel = RevisionLabel.short("1234567890abcdef1234567890abcdef12345678")
        XCTAssertNotEqual(workingLabel, shaLabel)
    }
}
