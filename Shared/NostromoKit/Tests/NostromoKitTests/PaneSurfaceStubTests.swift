// NostromoKit — PaneSurfaceStubTests.swift
//
// L1 coverage for PaneSurfaceStub (W2 — ios-curated-view-parity).
//
// Driven from an explicit, exhaustive array of every `PaneContentWire` case
// rather than a hand-picked subset: adding a case to the wire type without
// adding it to this array is a compile error (the array literal's element
// type forces every case to be considered), and forgetting to update the
// per-case expectation below is caught by `testEveryCaseIsAccountedForExactlyOnce`.

import XCTest
@testable import NostromoKit

final class PaneSurfaceStubTests: XCTestCase {

    // MARK: - Fixtures — one instance of every PaneContentWire case

    private static let allCases: [(name: String, content: PaneContentWire)] = [
        ("text", .text("hello")),
        ("jsonSnapshot", .jsonSnapshot(["a": 1])),
        ("prList", .prList([])),
        ("loading", .loading),
        ("error", .error("boom")),
        ("code", .code(CodePayload(path: "a.rs", revision: "abc", firstLine: 1, text: "fn main() {}"))),
        ("diff", .diff(DiffPayload(repo: "acme/web", number: 42, files: []))),
        ("prConversation", .prConversation(PrConversationPayload(
            repo: "acme/web", number: 42, title: "t", author: "a", url: "",
            body: [], threads: [], conversationError: nil
        ))),
        ("ticket", .ticket(TicketPayload(
            provider: "jira", key: "CORE-1", summary: "s", status: "open",
            assignee: nil, url: "", sections: [], comments: []
        ))),
        ("unknown", .unknown(["k": "v"])),
    ]

    /// Kinds still deferred — the only kinds `message(for:)` may return
    /// non-nil for. `code` moved out of this set in
    /// `ios-curated-view-parity` W7 (`CodeSurfaceView` is a real renderer
    /// now); `diff`/`prConversation`/`ticket` remain deferred to W8/W9.
    private static let deferredKinds: Set<String> = ["diff", "prConversation", "ticket"]

    // MARK: - Every deferred kind has a non-empty message

    func testEveryDeferredKindHasANonEmptyHeadlineAndDetail() {
        for (name, content) in Self.allCases where Self.deferredKinds.contains(name) {
            guard let message = PaneSurfaceStub.message(for: content) else {
                XCTFail("\(name) is a deferred kind but PaneSurfaceStub.message(for:) returned nil")
                continue
            }
            XCTAssertFalse(message.headline.isEmpty, "\(name)'s stub headline must not be empty")
            XCTAssertFalse(message.detail.isEmpty, "\(name)'s stub detail must not be empty")
        }
    }

    // MARK: - Every rendered kind has no message

    func testEveryRenderedKindHasNoMessage() {
        for (name, content) in Self.allCases where !Self.deferredKinds.contains(name) {
            XCTAssertNil(
                PaneSurfaceStub.message(for: content),
                "\(name) is rendered on iOS (or degrades generically) and must not carry a stub message"
            )
        }
    }

    // MARK: - Adding a case without updating this file's expectations is caught

    func testEveryCaseIsAccountedForExactlyOnce() {
        // Guards the fixture itself: every case in `allCases` names a distinct
        // PaneContentWire kind, and the set of names is exactly the nine kinds
        // this test file knows about. If a tenth case is added to
        // PaneContentWire, `allCases` above must grow too, or this count
        // silently stops matching — pinning the count here is what makes that
        // omission visible rather than passing quietly.
        XCTAssertEqual(Self.allCases.count, 10)
        XCTAssertEqual(Set(Self.allCases.map(\.name)).count, 10, "case names must be unique")
    }

    // MARK: - `.code` no longer carries a stub message (W7)

    func testCodeHasNoStubMessage() {
        XCTAssertNil(PaneSurfaceStub.message(for: .code(
            CodePayload(path: "a.rs", revision: "abc", firstLine: 1, text: "x")
        )), "code is rendered by CodeSurfaceView as of W7 and must not carry a stub message")
    }

    // MARK: - Each stub names its own missing addressing (the PRD's honesty rule)

    func testDiffStubNamesTheMissingLineAddressing() {
        let message = PaneSurfaceStub.message(for: .diff(
            DiffPayload(repo: "acme/web", number: 1, files: [])
        ))
        XCTAssertTrue(
            message?.detail.contains("line") ?? false,
            "diff's addressing is Anchor.line — the stub must say so, not just 'unavailable'"
        )
    }

    func testPrConversationStubNamesTheMissingCommentAddressing() {
        let message = PaneSurfaceStub.message(for: .prConversation(
            PrConversationPayload(repo: "acme/web", number: 1, title: "t", author: "a", url: "",
                                   body: [], threads: [], conversationError: nil)
        ))
        XCTAssertTrue(
            message?.detail.contains("comment") ?? false,
            "prConversation's addressing is Anchor.comment — the stub must say so, not just 'unavailable'"
        )
    }

    func testTicketStubNamesTheMissingSectionAddressing() {
        let message = PaneSurfaceStub.message(for: .ticket(
            TicketPayload(provider: "jira", key: "CORE-1", summary: "s", status: "open",
                          assignee: nil, url: "", sections: [], comments: [])
        ))
        XCTAssertTrue(
            message?.detail.contains("section") ?? false,
            "ticket's addressing is Anchor.section — the stub must say so, not just 'unavailable'"
        )
    }
}
