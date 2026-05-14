//! Nostromo in-process MCP server.
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
//! ## Tool surface
//!
//! **Phase 1**: `nostromo.get_self` — returns the calling PTY's view identity
//! (`view_id`, `view_title`, `pane_ids`, `session_id`).
//!
//! **Phase 2**: 17 read-only introspection tools across all views:
//! - Global: `nostromo.list_views`, `nostromo.get_view_state`,
//!   `nostromo.get_worktree_info`, `nostromo.get_rate_limits`,
//!   `nostromo.get_budget_posture`
//! - Perri: `perri.list_pr_queue`, `perri.get_current_pr`, `perri.get_state`
//! - Fred: `fred.list_unread_emails`, `fred.list_calendar_events`,
//!   `fred.get_state`
//! - Mother: `mother.list_jobs`, `mother.get_job`, `mother.tail_log`,
//!   `mother.peek`, `mother.get_status`
//! - Teri: `teri.list_todos`
//!
//! Phases 3–4 will add pane mutations and cross-view dispatch.

pub mod command;
pub mod server;
pub mod socket;
pub mod state;
pub mod tools;

pub use command::{McpCommand, PaneContent};
pub use server::McpServer;
pub use socket::default_socket_path;
pub use state::{McpSharedState, PtyIdentity, ViewMeta};
