//! Unix socket IPC between the `nostromd` daemon and TUI clients.
//!
//! Protocol: length-prefixed JSON frames (4-byte big-endian u32 length prefix).
//!
//! Modules:
//! - [`codec`]        — frame read/write primitives
//! - [`protocol`]     — message type definitions + socket path resolution
//! - [`scrollback`]   — PTY scrollback ring buffer
//! - [`pty_manager`]  — daemon-side PTY lifecycle management
//! - [`server`]       — daemon-side accept loop and fan-out broadcaster
//! - [`client`]       — TUI-side connection and subscription

pub mod client;
pub mod codec;
pub mod protocol;
pub mod pty_manager;
pub mod scrollback;
pub mod server;

pub use client::DaemonClient;
pub use protocol::{default_socket_path, ClientMsg, ServerMsg, Topic};
pub use pty_manager::PtyManager;
pub use server::Server;
