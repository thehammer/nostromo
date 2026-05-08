//! IPC wire protocol shared between the `nostromd` daemon and TUI clients.
//!
//! Frames are length-prefixed: a big-endian u32 byte count followed by a JSON
//! body.  Maximum frame size is 4 MiB.

use std::path::PathBuf;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::{
    agent_bus::ActivityEvent,
    mother::{MotherJob, MotherStatus},
};

/// Environment variable that overrides the default socket path.
pub const SOCKET_PATH_ENV: &str = "NOSTROMOD_SOCKET";

/// Current protocol version — bump when messages change in a breaking way.
/// Phase 5b introduces PTY ownership in the daemon; clients announcing < 2
/// will be rejected.
pub const PROTOCOL_VERSION: u32 = 2;

/// Minimum client version accepted by the daemon.
pub const MIN_CLIENT_VERSION: u32 = 2;

/// Maximum accepted frame body size (4 MiB).
pub const MAX_FRAME_LEN: usize = 4 * 1024 * 1024;

/// Return the socket path, honouring `NOSTROMD_SOCKET` if set.
pub fn default_socket_path() -> PathBuf {
    if let Ok(v) = std::env::var(SOCKET_PATH_ENV) {
        return PathBuf::from(v);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("nostromd.sock")
}

/// Topics a client can subscribe to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Topic {
    Activity,
    MotherJobs,
    MotherStatusline,
}

/// Metadata about a daemon-owned PTY.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PtyInfo {
    pub pty_id: String,
    pub cmd: String,
    pub args: Vec<String>,
    pub alive: bool,
    pub cols: u16,
    pub rows: u16,
    /// Unix timestamp of the last activity (write to PTY output).
    pub last_activity: Option<SystemTime>,
    /// Tag identifying which view/agent owns this PTY (e.g. `"fred"`, `"cody"`).
    pub client_tag: String,
}

// ── base64 byte-array helpers (for compact JSON encoding) ────────────────────

pub(crate) mod base64_bytes {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        STANDARD.encode(bytes).serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        STANDARD.decode(&s).map_err(serde::de::Error::custom)
    }
}

// ── client → daemon messages ──────────────────────────────────────────────────

/// Messages sent from a TUI client to the daemon.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMsg {
    Hello {
        client_id: String,
        protocol_version: u32,
    },
    Subscribe {
        topics: Vec<Topic>,
    },
    Ping,

    // ── PTY commands ──────────────────────────────────────────────────────────
    /// Spawn a new PTY in the daemon.
    PtySpawn {
        pty_id: String,
        cmd: String,
        args: Vec<String>,
        cols: u16,
        rows: u16,
        cwd: Option<PathBuf>,
        /// View/agent tag so the daemon can identify PTYs on reattach.
        client_tag: String,
    },

    /// Send raw bytes to a PTY's stdin.
    PtyInput {
        pty_id: String,
        #[serde(with = "base64_bytes")]
        bytes: Vec<u8>,
    },

    /// Resize a PTY.
    PtyResize {
        pty_id: String,
        cols: u16,
        rows: u16,
    },

    /// Kill a PTY and its child process.
    PtyKill {
        pty_id: String,
    },

    /// Attach to an existing PTY: daemon sends PtyAttached + PtyScrollback,
    /// then starts streaming PtyOutput.  A second attach to an already-attached
    /// PTY succeeds; the prior client receives PtyDetach first.
    PtyAttach {
        pty_id: String,
    },

    /// Stop receiving output from a PTY without killing it.
    PtyDetach {
        pty_id: String,
    },

    /// Request a snapshot of all live PTYs owned by this daemon.
    PtyList,
}

// ── daemon → client messages ──────────────────────────────────────────────────

/// Messages sent from the daemon to a TUI client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMsg {
    Welcome {
        protocol_version: u32,
        daemon_pid: u32,
    },
    Activity(ActivityEvent),
    MotherJobs(Vec<MotherJob>),
    MotherStatusline(MotherStatus),
    /// A job transitioned into `awaiting` — daemon fires this once per
    /// transition (same logic as the in-process `mother_poll`).
    MotherAwaitDetected(MotherJob),
    Pong,
    Error {
        message: String,
    },

    // ── PTY responses ─────────────────────────────────────────────────────────
    /// The requested PTY was successfully spawned.
    PtySpawned {
        pty_id: String,
    },

    /// Live output from an attached PTY.
    PtyOutput {
        pty_id: String,
        #[serde(with = "base64_bytes")]
        bytes: Vec<u8>,
    },

    /// PTY child process exited.
    PtyExited {
        pty_id: String,
        exit_code: Option<i32>,
    },

    /// Scrollback replay sent immediately after PtyAttached.
    /// Contains the entire current ring buffer as a single concatenated chunk.
    PtyScrollback {
        pty_id: String,
        #[serde(with = "base64_bytes")]
        bytes: Vec<u8>,
    },

    /// Attach acknowledgement — sent before PtyScrollback.
    PtyAttached {
        pty_id: String,
        cols: u16,
        rows: u16,
    },

    /// Sent to a previously attached client when a new client steals attach.
    PtyDetach {
        pty_id: String,
    },

    /// Response to PtyList.
    PtyListResp {
        ptys: Vec<PtyInfo>,
    },
}
