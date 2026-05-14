//! Nostromo in-process MCP server — Phase 1 scaffolding.
//!
//! ## Architecture
//!
//! Nostromo binds a Unix domain socket at `~/.nostromo/mcp.sock`.  The
//! `nostromo-mcp-bridge` binary connects to that socket; Claude Code's MCP
//! config points to the bridge as a `stdio` server.
//!
//! Each accepted connection runs a lightweight hand-rolled JSON-RPC 2.0 / MCP
//! protocol loop (see [`server`]).  Before MCP framing begins the bridge sends
//! a `Hello { pty_id }` line so the server can correlate the connection with
//! the Nostromo PTY that spawned the agent.
//!
//! ## Socket path
//!
//! `~/.nostromo/mcp.sock` by default; override with `$NOSTROMO_MCP_SOCKET`.
//!
//! ## Phase 1 surface
//!
//! One tool is registered: `nostromo.get_self`.  It returns the calling PTY's
//! view identity (`view_id`, `view_title`, `pane_ids`, `session_id`).
//! Phases 2–4 will add view-state queries, pane mutations, and cross-view
//! dispatch.

pub mod server;
pub mod socket;
pub mod state;
pub mod tools;

pub use server::McpServer;
pub use socket::default_socket_path;
pub use state::{McpSharedState, PtyIdentity, ViewMeta};
