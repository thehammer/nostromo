import XCTest
@testable import NostromoKit

final class ApprovalsNeedsYouTests: XCTestCase {

    private func builder(_ request: ApprovalRequestWire) -> ApprovalsNeedsYouContentBuilder {
        ApprovalsNeedsYouContentBuilder(request: { $0 == request.requestId ? request : nil })
    }

    private func content(_ request: ApprovalRequestWire) throws -> NeedsYouNotificationContent {
        let item = ApprovalsNeedsYouProducer.items(pending: [request])[0]
        return try XCTUnwrap(builder(request).content(for: item))
    }

    func testItemsAreOnePerRequestOnTheirFocus() throws {
        let a = try Fx.bashRequest("rm -rf build/")
        let items = ApprovalsNeedsYouProducer.items(pending: [a])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "approvals:\(a.requestId)")
        XCTAssertEqual(items[0].source, .focus(a.tag))
        var agg = NeedsYouAggregator()
        XCTAssertEqual(agg.set(producer: "approvals", items: items).perFocus[a.tag], 1)
    }

    func testBodyIsToolAndFirstWordOnlyForEveryBashFixture() throws {
        for fixture in Fx.bashCases where !fixture.command.isEmpty {
            let request = try fixture.request()
            let c = try content(request)
            XCTAssertEqual(c.title, "Cody needs approval", fixture.name)
            // Whatever the fixture, the body is the tool and at most one word.
            XCTAssertTrue(c.body.hasPrefix("Bash"), fixture.name)
            XCTAssertLessThanOrEqual(c.body.split(separator: " ").count, 3, "\(fixture.name): \(c.body)")
            if fixture.name == "simple_rm" || fixture.name == "compound" || fixture.name == "compound_fixture" {
                XCTAssertEqual(c.body, "Bash · rm", fixture.name)
            }
            XCTAssertFalse(c.body.contains("build"), fixture.name)
            XCTAssertFalse(c.body.contains("/"), "\(fixture.name): \(c.body)")
        }
    }

    func testCompoundAndHeredocShowOnlyTheFirstWord() throws {
        XCTAssertEqual(try content(Fx.compoundRm.request()).body, "Bash · rm")
        let heredoc = try content(Fx.heredoc300.request())
        XCTAssertEqual(heredoc.body.split(separator: " ").count, 3)   // "Bash", "·", one word
        XCTAssertLessThanOrEqual(heredoc.body.count, 50)
    }

    func testPathShapedFirstWordIsCutToItsLastComponent() throws {
        XCTAssertEqual(try content(Fx.bashRequest("/usr/bin/rm -rf x")).body, "Bash · rm")
    }

    func testAnAssignmentIsSkippedAndAnOddWordFallsBackToTheToolName() throws {
        XCTAssertEqual(try content(Fx.bashRequest("API_KEY=hunter2 rm -rf x")).body, "Bash · rm")
        XCTAssertEqual(try content(Fx.bashRequest("A=1 B=2")).body, "Bash")
        XCTAssertEqual(try content(Fx.bashRequest("user@host:secret ls")).body, "Bash")
        XCTAssertEqual(try content(Fx.bashRequest("r\u{043C} -rf x")).body, "Bash", "non-ASCII is never shown")
        XCTAssertEqual(try content(Fx.bashRequest("\(String(repeating: "a", count: 60)) x")).body, "Bash")
    }

    func testNonBashShowsTheToolNameOnly() throws {
        let request = try Fx.request(toolKind: "edit", toolName: "Edit", displayName: "Edit",
                                     input: ["file_path": "/etc/secret"], display: Fx.display(lines: [], commandCount: nil))
        let c = try content(request)
        XCTAssertEqual(c.body, "Edit")
        XCTAssertFalse(c.body.contains("secret"))
    }

    func testContentCarriesNoReasonAndIsThreadedByTag() throws {
        let request = try Fx.bashRequest("rm -rf build/")
        let c = try content(request)
        XCTAssertEqual(c.threadIdentifier, request.tag)
        XCTAssertEqual(c.userInfo["requestId"], request.requestId)
        XCTAssertFalse(c.body.contains(request.reason.text))
    }

    func testUnknownRequestOrOtherReasonYieldsNothing() throws {
        let request = try Fx.bashRequest("ls")
        let item = ApprovalsNeedsYouProducer.items(pending: [request])[0]
        XCTAssertNil(ApprovalsNeedsYouContentBuilder(request: { _ in nil }).content(for: item))
        let other = NeedsYouItem(id: "approvals:x", source: .app, reason: .trackerWaiting)
        XCTAssertNil(builder(request).content(for: other))
    }

    // A pasted token must never reach a notification: only a known command name is shown (A3F-4).

    func testATokenShapedFirstWordNeverReachesTheNotification() throws {
        let tokens = [
            "sk-ant-api03-AbCdEf1234567890",
            "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
            "AKIAIOSFODNN7EXAMPLE",
            "d41d8cd98f00b204e9800998ecf8427e",
            "my-secret-script.sh",
            "/tmp/ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
        ]
        for token in tokens {
            for command in ["\(token) --flag", token] {
                let body = try content(Fx.bashRequest(command)).body
                XCTAssertEqual(body, "Bash", "command: \(command)")
                XCTAssertFalse(body.contains(token.split(separator: "/").last.map(String.init) ?? token), command)
            }
        }
    }

    func testKnownCommandNamesAreStillShown() throws {
        XCTAssertEqual(try content(Fx.bashRequest("git status")).body, "Bash · git")
        XCTAssertEqual(try content(Fx.bashRequest("/usr/bin/rm -rf x")).body, "Bash · rm")
        XCTAssertEqual(try content(Fx.bashRequest("curl")).body, "Bash · curl")
        XCTAssertEqual(try content(Fx.bashRequest("TOKEN=sk-ant-api03-AbCdEf1234567890 curl https://x")).body, "Bash · curl")
    }

    func testAKnownCommandNameWithATokenAfterItDoesNotLeakTheToken() throws {
        let body = try content(Fx.bashRequest("curl -H 'Authorization: Bearer sk-ant-api03-AbCdEf1234567890' https://x")).body
        XCTAssertEqual(body, "Bash · curl")
    }
}
