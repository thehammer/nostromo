import XCTest
@testable import NostromoKit

final class EnabledAgentsTests: XCTestCase {
    func testNilMeansEverythingEnabled() {
        XCTAssertEqual(EnabledAgents(wireValue: nil), .all)
        XCTAssertEqual(EnabledAgents(wireValue: NSNull()), .all)
    }

    func testListDisablesSwitchableAgentsNotInIt() {
        let e = EnabledAgents(wireValue: ["mother", "teri"])
        XCTAssertFalse(e.isEnabled("fred"))
        XCTAssertFalse(e.isEnabled("perri"))
        XCTAssertTrue(e.isEnabled("mother"))
        XCTAssertTrue(e.isEnabled("teri"))
        XCTAssertTrue(e.isEnabled("cody"))
    }

    func testMotherIsNeverDisabled() {
        let e = EnabledAgents(wireValue: ["fred"])
        XCTAssertTrue(e.isEnabled("mother"))
        XCTAssertEqual(e.disabled, ["perri", "teri", "huey"])
    }

    func testMalformedValuesMeanEverythingEnabled() {
        XCTAssertEqual(EnabledAgents(wireValue: [1, 2]), .all)
        XCTAssertEqual(EnabledAgents(wireValue: "x"), .all)
    }

    func testIsEnabledIsCaseInsensitive() {
        let e = EnabledAgents(disabled: ["fred"])
        XCTAssertFalse(e.isEnabled("Fred"))
        XCTAssertFalse(e.isEnabled("FRED"))
    }

    func testWelcomeDecodeWithAndWithoutEnabledAgents() {
        let with = ServerMsg.decode(from: Data(#"{"type":"welcome","protocol_version":4,"daemon_pid":7,"enabled_agents":["mother","teri"]}"#.utf8))
        guard case let .welcome(_, _, enabled) = with else { return XCTFail("expected .welcome") }
        XCTAssertFalse(enabled.isEnabled("fred"))
        XCTAssertTrue(enabled.isEnabled("teri"))

        let without = ServerMsg.decode(from: Data(#"{"type":"welcome","protocol_version":4,"daemon_pid":7}"#.utf8))
        guard case let .welcome(_, _, all) = without else { return XCTFail("expected .welcome") }
        XCTAssertEqual(all, .all)
    }

    // MARK: - Huey

    func testHueyIsASwitchableAgent() {
        XCTAssertTrue(EnabledAgents.switchable.contains("huey"))
    }

    func testAWelcomeListWithoutHueyReadsHueyAsDisabled() {
        let e = EnabledAgents(wireValue: ["mother", "fred", "perri", "teri"])
        XCTAssertFalse(e.isEnabled("huey"))
        XCTAssertTrue(e.disabled.contains("huey"))
        XCTAssertTrue(e.isEnabled("fred"))
    }

    func testAWelcomeListContainingHueyReadsHueyAsEnabled() {
        let e = EnabledAgents(wireValue: ["mother", "huey"])
        XCTAssertTrue(e.isEnabled("huey"))
        XCTAssertFalse(e.disabled.contains("huey"))
        XCTAssertFalse(e.isEnabled("fred"))
    }

    func testNoListMeansHueyIsEnabledToo() {
        XCTAssertTrue(EnabledAgents(wireValue: nil).isEnabled("huey"))
        XCTAssertTrue(EnabledAgents.all.isEnabled("huey"))
    }

    func testHueyMatchesCaseInsensitivelyOnTheWire() {
        XCTAssertTrue(EnabledAgents(wireValue: ["HUEY"]).isEnabled("huey"))
    }
}
