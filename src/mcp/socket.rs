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

/// Socket path for the **daemon-hosted** MCP server.
///
/// Distinct from [`default_socket_path`] (the legacy `mcp.sock`) so the two
/// can't collide. Honours `NOSTROMO_MCP_SOCKET`
/// when set in the daemon's own environment, else `~/.nostromo/mcp-daemon.sock`.
pub fn daemon_socket_path() -> PathBuf {
    if let Ok(v) = std::env::var(MCP_SOCKET_ENV) {
        return PathBuf::from(v);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("mcp-daemon.sock")
}

/// The name sessions know the Nostromo MCP server by (tools are
/// `mcp__nostromo__*`). `mcp_reconnect` control requests address it by this name.
pub const MCP_SERVER_NAME: &str = "nostromo";

/// Write the `--mcp-config` file that registers the `nostromo-mcp-bridge` stdio
/// server, and return its path. The bridge binary is resolved as a sibling of
/// the running executable (so a dev build's `target/<profile>/` copy is found),
/// falling back to the bare name on `PATH`.
///
/// Best-effort: returns `None` if the config can't be written.
pub fn write_bridge_mcp_config() -> Option<PathBuf> {
    let command = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("nostromo-mcp-bridge")))
        .filter(|p| p.exists())
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| "nostromo-mcp-bridge".to_string());

    let mut servers = serde_json::Map::new();
    servers.insert(
        MCP_SERVER_NAME.to_owned(),
        serde_json::json!({ "type": "stdio", "command": command }),
    );
    let config = serde_json::json!({ "mcpServers": servers });

    let path = dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("mcp-bridge.json");

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok()?;
    }
    std::fs::write(&path, serde_json::to_vec_pretty(&config).ok()?).ok()?;
    Some(path)
}
