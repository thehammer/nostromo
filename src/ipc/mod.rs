//! Unix socket IPC between the `nostromd` daemon and its clients.
//!
//! Protocol: length-prefixed JSON frames (4-byte big-endian u32 length prefix).
//!
//! Modules:
//! - [`codec`]           — frame read/write primitives
//! - [`protocol`]        — message type definitions + socket path resolution
//! - [`scrollback`]      — PTY scrollback ring buffer
//! - [`stream_json`]     — stream-json turn model + parser
//! - [`tasks`]           — background-task registry (activity panel)
//! - [`task_output`]     — task output sanitiser, file validator, tail read
//! - [`session_manager`] — daemon-side persistent stream-json session lifecycle
//! - [`server`]          — daemon-side accept loop and fan-out broadcaster
//! - [`client`]          — client-side connection and subscription
//! - [`decisions`]       — daemon-side decision-modal request registry (W6)
//! - [`orphans`]         — child-process ledger, graceful stop and the startup orphan sweep
//! - [`peer`]            — peer trust and what each peer may see or do
//! - [`peer_verify`]     — who is on the other end of a Unix connection (the Mac app?)
//! - [`auth_failure`]    — spotting a turn that failed because Claude could not sign in
//! - [`claude_login`]    — the credential watch and the "sessions waiting for a sign-in" frame

pub mod auth_failure;
pub mod claude_login;
pub mod client;
pub mod codec;
mod control_scan;
pub mod decisions;
pub mod orphans;
pub mod pane_registry;
pub mod peer;
pub mod peer_verify;
pub mod perri_state;
pub mod protocol;
pub mod scrollback;
pub mod server;
pub mod session_manager;
pub mod stream_json;
pub mod task_output;
pub mod tasks;

pub use client::{ConnectionState, DaemonClient};
pub use protocol::{default_socket_path, ClientMsg, ServerMsg, Topic};
pub use server::Server;
pub use session_manager::SessionManager;
