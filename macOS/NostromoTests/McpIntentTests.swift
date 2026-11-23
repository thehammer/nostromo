import XCTest
import AppKit
import NostromoKit

// Typing exactly `/mcp` opens the native panel (and sends nothing); anything else that starts with `/mcp`
// is the CLI's and is sent as typed. Without `session_mcp_v1` nothing changes.
final class McpIntentTests: XCTestCase {
    private let with: [String]? = ["slash_commands_v1", "session_mcp_v1"]

    func testExactlySlashMcpOpensThePanel() {
        XCTAssertTrue(McpIntent.isPanelRequest(text: "/mcp", features: with))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertTrue(McpIntent.isPanelRequest(text: "  /mcp\n", features: with))
    }

    func testAnythingElseIsSentAsTyped() {
        for text in ["/mcp reconnect x", "/mcpx", "/MCP", "/mcp ", "mcp", "/mc", "/mcp\nhello", "please /mcp", ""] where text.trimmingCharacters(in: .whitespaces) != "/mcp" {
            XCTAssertFalse(McpIntent.isPanelRequest(text: text, features: with), text)
        }
    }

    func testWithoutTheFeatureItIsSentAsTyped() {
        XCTAssertFalse(McpIntent.isPanelRequest(text: "/mcp", features: ["slash_commands_v1"]))
        XCTAssertFalse(McpIntent.isPanelRequest(text: "/mcp", features: []))
        XCTAssertFalse(McpIntent.isPanelRequest(text: "/mcp", features: nil))
    }
}

// The `/mcp` wiring in `ReplView`: the panel opens for exactly `/mcp` (against a daemon with `session_mcp_v1`)
// and the session sends nothing; `/mcp foo` is the CLI's and is sent as typed.
final class McpReplWiringTests: XCTestCase {
    private var tag = ""
    private var repl: ReplView!
    private var session: ChatSession!
    private var window: NSWindow!
    private let fake = McpFakeSender()
    private var savedSender: McpRequestSending?
    private var client: NostromodClient { AppStore.shared.client }

    override func setUp() {
        super.setUp()
        tag = "mcp-wiring-\(UUID().uuidString)"
        client.setAdvertisedFeaturesForTesting(["slash_commands_v1", "session_mcp_v1"])
        savedSender = McpRequests.shared.sender
        McpRequests.shared.sender = fake
        repl = ReplView(tag: tag)
        session = AppStore.shared.session(for: tag)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        repl.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.contentView = repl
        repl.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        McpPanelController.present(on: window, tag: tag, focusName: "x", projectPath: nil)?.close()
        window.orderOut(nil)
        window.contentView = nil
        session.detach()
        client.setAdvertisedFeaturesForTesting([])
        McpRequests.shared.sender = savedSender
        repl = nil
        session = nil
        window = nil
        super.tearDown()
    }

    func testExactlySlashMcpOpensThePanelAndSendsNothingToTheSession() {
        let before = session.turns.count
        repl.sendFromInputBarForTesting("/mcp")
        XCTAssertNotNil(window.attachedSheet, "the panel is a sheet on the pane's window")
        XCTAssertEqual(session.turns.count, before, "no echo, no record, nothing sent to the CLI")
        XCTAssertEqual(fake.sent.map(\.action), ["status"], "the panel only reads the list")
    }

    func testSlashMcpWithArgumentsGoesToTheCliAsTyped() {
        repl.sendFromInputBarForTesting("/mcp foo")
        XCTAssertNil(window.attachedSheet, "no panel")
        XCTAssertEqual(session.turns.filter { $0.userInput == "/mcp foo" }.count, 1, "sent as typed")
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testWithoutTheFeatureSlashMcpIsSentAsTyped() {
        client.setAdvertisedFeaturesForTesting(["slash_commands_v1"])
        repl.sendFromInputBarForTesting("/mcp")
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(session.turns.filter { $0.userInput == "/mcp" }.count, 1)
    }
}
