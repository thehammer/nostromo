//! Legacy event type for the non-daemon MCP command path.

use crate::mcp::command::McpCommand;

/// Legacy non-daemon MCP command path; retired in R2 (remove-rust-tui).
///
/// Boxed to keep the enum size uniform; `McpCommand` can carry large strings.
#[derive(Debug)]
pub enum AppEvent {
    /// A command from the MCP server.
    McpCommand(Box<McpCommand>),
}
