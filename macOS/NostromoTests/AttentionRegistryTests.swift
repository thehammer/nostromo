import XCTest

// Behavioural spec for `AttentionRegistry`: outstanding "needs attention"
// requests keyed by request, projected to the set of focus tags that have at
// least one.

final class AttentionRegistryTests: XCTestCase {

    func testFreshRegistryFlagsNothing() {
        XCTAssertTrue(AttentionRegistry().tags.isEmpty)
    }

    func testRaisingAddsTheTag() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        XCTAssertEqual(r.tags, ["perri"])
    }

    func testClearingTheKeyRemovesTheTag() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        r.clear(key: "decision:1")
        XCTAssertTrue(r.tags.isEmpty)
    }

    func testTwoKeysForOneTagKeepTheTagUntilBothAreCleared() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        r.raise(tag: "perri", key: "decision:2")

        r.clear(key: "decision:1")
        XCTAssertEqual(r.tags, ["perri"], "one request is still outstanding for this tag")

        r.clear(key: "decision:2")
        XCTAssertTrue(r.tags.isEmpty)
    }

    func testRaisingTheSameKeyTwiceIsIdempotent() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        r.raise(tag: "perri", key: "decision:1")
        r.clear(key: "decision:1")
        XCTAssertTrue(r.tags.isEmpty, "a single clear removes a doubly-raised key")
    }

    func testClearingAnUnknownKeyIsANoOp() {
        var r = AttentionRegistry()
        r.clear(key: "never-raised")
        XCTAssertTrue(r.tags.isEmpty)

        r.raise(tag: "perri", key: "decision:1")
        r.clear(key: "never-raised")
        XCTAssertEqual(r.tags, ["perri"])
    }

    func testDifferentTagsAreIndependent() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        r.raise(tag: "cody-abc12345", key: "decision:2")
        XCTAssertEqual(r.tags, ["perri", "cody-abc12345"])

        r.clear(key: "decision:1")
        XCTAssertEqual(r.tags, ["cody-abc12345"])

        r.clear(key: "decision:2")
        XCTAssertTrue(r.tags.isEmpty)
    }

    func testClearingAKeyTwiceDoesNotDisturbOtherKeysForTheSameTag() {
        var r = AttentionRegistry()
        r.raise(tag: "perri", key: "decision:1")
        r.raise(tag: "perri", key: "decision:2")
        r.clear(key: "decision:1")
        r.clear(key: "decision:1")
        XCTAssertEqual(r.tags, ["perri"])
    }
}
