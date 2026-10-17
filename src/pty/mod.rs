//! PTY helpers used by the daemon's `PtyManager` (`src/ipc/pty_manager.rs`).

pub mod kitty;

/// Env var keys injected into every spawned PTY subprocess.
pub const ENV_VIEW_ID: &str = "NOSTROMO_VIEW_ID";
pub const ENV_PTY_ID: &str = "NOSTROMO_PTY_ID";
pub const ENV_SESSION_ID: &str = "NOSTROMO_SESSION_ID";
pub const ENV_MCP_SOCKET: &str = "NOSTROMO_MCP_SOCKET";
/// Set to `"1"` in every Nostromo-spawned PTY so inner processes can detect
/// they are running inside Nostromo rather than a bare terminal.
pub const ENV_NOSTROMO_PTY: &str = "NOSTROMO_PTY";
