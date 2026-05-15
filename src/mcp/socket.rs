//! MCP socket path resolution.
//!
//! The MCP server binds a Unix domain socket.  By default the socket lives at
//! `~/.nostromo/mcp.sock`; set `NOSTROMO_MCP_SOCKET` to override.

use std::path::PathBuf;

/// Environment variable that overrides the default MCP socket path.
pub const MCP_SOCKET_ENV: &str = "NOSTROMO_MCP_SOCKET";

/// Return the MCP socket path, honouring `NOSTROMO_MCP_SOCKET` if set.
///
/// Mirrors the pattern from `crate::ipc::protocol::default_socket_path`.
pub fn default_socket_path() -> PathBuf {
    if let Ok(v) = std::env::var(MCP_SOCKET_ENV) {
        return PathBuf::from(v);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("mcp.sock")
}
