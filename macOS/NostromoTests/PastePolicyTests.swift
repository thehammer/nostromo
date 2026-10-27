import XCTest

final class PastePolicyTests: XCTestCase {

    func testSingleLineGoesStraightThrough() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls -la"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: ""), .send)
    }

    func testOneLineWithATrailingNewlineIsStillOneLine() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls\n"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls\r\n"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "ls\r"), .send)
    }

    func testTwoLinesAsk() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\nb"), .confirm(lines: 2))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\nb\n"), .confirm(lines: 2))
    }

    func testWindowsAndOldMacLineEndingsAreNormalised() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\r\nb\r\nc"), .confirm(lines: 3))
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\rb\rc"), .confirm(lines: 3))
    }

    func testOnlyOneTrailingNewlineIsIgnored() {
        XCTAssertEqual(PastePolicy.decide(kind: .ecs, text: "a\n\n"), .confirm(lines: 2))
    }

    func testLocalTerminalsNeverAsk() {
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "a\nb\nc"), .send)
        XCTAssertEqual(PastePolicy.decide(kind: .unknown, text: "a\nb\nc"), .send)
    }
}
