//! `nostromo-mcp-bridge` — stdio ↔ Unix socket bridge for the Nostromo MCP server.
//!
//! Claude Code's MCP integration expects a `stdio` server: a child process
//! whose stdin/stdout carry JSON-RPC 2.0 frames.  This binary bridges that
//! expectation to Nostromo's Unix domain socket.
//!
//! ## Identification
//!
//! Before forwarding stdin/stdout the bridge sends a single-line JSON `Hello`
//! frame so the MCP server can associate this connection with the Nostromo PTY
//! that spawned it:
//!
//! ```json
//! {"type":"hello","pty_id":"<NOSTROMO_PTY_ID>"}
//! ```
//!
//! Both env vars are injected by Nostromo when it spawns the agent process.
//! If they are absent the bridge still connects; the server will return
//! `{"error":"unidentified_caller"}` when `get_self` is called.
//!
//! ## Staying connected
//!
//! Claude Code never respawns a dead stdio MCP server, so the bridge outlives
//! the daemon connection: on a drop it answers in-flight requests with a
//! JSON-RPC error, reconnects with backoff, re-sends Hello, replays the MCP
//! handshake and carries on. It exits (code 0) only when stdin closes. See
//! `nostromo::mcp::bridge`. Events are logged, without frame contents, to
//! `~/.nostromo/logs/mcp-bridge-<pid>.log`.
//!
//! ## Usage (in `.claude/settings.json`)
//!
//! ```json
//! {
//!   "mcpServers": {
//!     "nostromo": {
//!       "type": "stdio",
//!       "command": "nostromo-mcp-bridge"
//!     }
//!   }
//! }
//! ```
//!
//! `NOSTROMO_MCP_SOCKET` and `NOSTROMO_PTY_ID` are inherited automatically
//! from the PTY environment.

fn main() {
    let code = nostromo::mcp::bridge::run(nostromo::mcp::bridge::BridgeConfig::from_env());
    std::process::exit(code);
}
