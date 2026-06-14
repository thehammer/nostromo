//! Unix socket IPC between the `nostromd` daemon and TUI clients.
//!
//! Protocol: length-prefixed JSON frames (4-byte big-endian u32 length prefix).
//!
//! Modules:
//! - [`codec`]           — frame read/write primitives
//! - [`protocol`]        — message type definitions + socket path resolution
//! - [`scrollback`]      — PTY scrollback ring buffer
//! - [`pty_manager`]     — daemon-side PTY lifecycle management
//! - [`stream_json`]     — stream-json turn model + parser
//! - [`session_manager`] — daemon-side persistent stream-json session lifecycle
//! - [`server`]          — daemon-side accept loop and fan-out broadcaster
//! - [`client`]          — TUI-side connection and subscription

pub mod client;
pub mod codec;
pub mod pane_registry;
pub mod protocol;
pub mod pty_manager;
pub mod scrollback;
pub mod server;
pub mod session_manager;
pub mod stream_json;

pub use client::{ConnectionState, DaemonClient};
pub use protocol::{default_socket_path, ClientMsg, ServerMsg, Topic};
pub use pty_manager::PtyManager;
pub use server::Server;
pub use session_manager::SessionManager;
