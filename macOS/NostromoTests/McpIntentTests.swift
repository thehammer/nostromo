import XCTest

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
