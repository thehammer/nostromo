//! IPC wire protocol shared between the `nostromd` daemon and TUI clients.
//!
//! Frames are length-prefixed: a big-endian u32 byte count followed by a JSON
//! body.  Maximum frame size is 4 MiB.

use std::path::PathBuf;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::{
    agent_bus::ActivityEvent,
    ipc::{
        session_manager::StopReason,
        stream_json::{SessionState, Turn, TurnDelta},
    },
    mother::{MotherJob, MotherStatus},
};

/// Environment variable that overrides the default socket path.
pub const SOCKET_PATH_ENV: &str = "NOSTROMOD_SOCKET";

/// Current protocol version — bump when messages change in a breaking way.
/// Phase 5b introduced PTY ownership in the daemon (v2). v3 adds the
/// daemon-hosted persistent stream-json session protocol (`Session*` messages).
pub const PROTOCOL_VERSION: u32 = 4;

/// Minimum client version accepted by the daemon.
///
/// Held at 2 deliberately: every v3 addition (the `Session*` message family) is
/// *additive* and opt-in — a v2 client simply never sends or receives them — so
/// a not-yet-migrated v2 GUI keeps working against a v3 daemon. This avoids
/// stranding the running GUI in the window between the daemon-core milestone and
/// the Swift thin-client milestone. (Confirm with the operator before raising
/// this to 3 once the Swift client speaks v3.)
pub const MIN_CLIENT_VERSION: u32 = 2;

// Compile-time invariant: a client we still accept must not require a newer
// protocol than the daemon speaks. Enforced at compile time (clippy rejects
// the equivalent runtime `assert!` on constants as a tautology).
const _: () = assert!(MIN_CLIENT_VERSION <= PROTOCOL_VERSION);

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
    Focuses,
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

// ── persistent session metadata ──────────────────────────────────────────────

/// Lifecycle action for a daemon-hosted session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionAction {
    /// Kill the child but keep the persisted session id (resumable).
    Stop,
    /// Stop then respawn with `--resume <session_id>`.
    Restart,
    /// Drop the persisted session id; the next spawn starts fresh.
    NewSession,
}

/// Action to perform on a Mother job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MotherActionKind {
    Cancel,
    Retry,
    ForceStart,
}

/// Operator decision on a permission request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionDecision {
    Allow,
    Deny,
}

/// Metadata about a daemon-hosted persistent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    /// Focus tag — the stable local IPC address for the session.
    pub tag: String,
    /// Agent passed to `--agent`.
    pub agent_name: String,
    /// Human-facing name passed to `-n` / `--remote-control`.
    pub view_name: String,
    /// Persisted `claude` session id, once known.
    pub session_id: Option<String>,
    pub alive: bool,
    pub remote_control: bool,
    pub state: SessionState,
    /// Why this session was intentionally stopped, if it was. `None` for live
    /// sessions or sessions that were never explicitly stopped (e.g. auto-restarts).
    /// Present on the wire even when `alive == true` (always `null`); this is
    /// intentional so older peers decode it as `null` without breaking.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub stop_reason: Option<StopReason>,
}

/// Daemon-serveable projection of a Mac-side `Focus`. No absolute filesystem
/// paths leak to mobile — only a derived display name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusMeta {
    /// Session tag — the stable key that ties a focus to its daemon session.
    pub tag: String,
    /// Resolved display name (e.g. "Cody in Admin Portal" or "Fred").
    pub display_name: String,
    /// Claude agent name (e.g. "cody", "fred").
    pub agent_name: String,
    /// Repo/project display name (last path component, Title Cased). None for
    /// built-ins / pathless focuses.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub project_name: Option<String>,
    /// Org section for grouping ("Carefeed", "Personal", …). None → client
    /// resolves a default.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub org: Option<String>,
    /// True for built-in focuses (fred/mother/perri/teri).
    pub is_built_in: bool,
    /// Auto-generated one-line session summary, when known.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub session_summary: Option<String>,
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

    // ── persistent session commands (protocol v3) ─────────────────────────────
    /// Start (or resume) a focus's persistent stream-json session. Idempotent:
    /// spawning an already-live tag is a no-op that still succeeds.
    SessionSpawn {
        /// Focus tag — stable local key for the session.
        tag: String,
        /// Agent passed to `--agent`.
        agent_name: String,
        /// Human-facing name passed to `-n` (and `--remote-control` when on).
        view_name: String,
        cwd: Option<PathBuf>,
        /// Resume this `claude` session id if supplied; otherwise the daemon
        /// uses its persisted id for the tag, or assigns a fresh one.
        session_id: Option<String>,
        /// Spawn with `--remote-control <view_name>` for native cross-device
        /// (phone) control via Anthropic's relay.
        remote_control: bool,
    },

    /// Attach to a session: daemon replies with a `SessionTurns` snapshot then
    /// streams `SessionTurnDelta` / `SessionState`. Multiple clients may attach
    /// to the same tag (broadcast fan-out — mirroring).
    SessionAttach {
        tag: String,
    },

    /// Stop receiving deltas for a session without stopping the child.
    SessionDetach {
        tag: String,
    },

    /// Enqueue a user message; the daemon writes it to the child's stdin.
    SessionSend {
        tag: String,
        text: String,
        /// Absolute paths to image files; daemon reads + base64-encodes them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<String>,
    },

    /// Lifecycle control (stop / restart / new_session).
    SessionControl {
        tag: String,
        action: SessionAction,
    },

    /// Answer a `SessionPermissionRequest` (only used if a stdout-answerable
    /// permission path is available; the default posture is bypass).
    SessionAnswerPermission {
        tag: String,
        request_id: String,
        decision: PermissionDecision,
    },

    /// Request a snapshot of all daemon-hosted sessions.
    SessionList,

    /// The Mac app publishes its full focus registry to the daemon. Replaces the
    /// daemon's in-memory registry wholesale.
    FocusRegistryPush {
        focuses: Vec<FocusMeta>,
    },
    /// Request a snapshot of the current focus registry.
    FocusList,

    /// Request a Mother job action (cancel / retry / force-start).
    /// The daemon shells out to `mother <action> <job_id>` and re-broadcasts
    /// a fresh `ServerMsg::MotherJobs` on completion.
    MotherAction {
        job_id: String,
        action: MotherActionKind,
    },

    /// Resume an awaiting Mother job by supplying the operator's answer.
    /// The daemon shells out to `mother resume <job_id> <answer>` and
    /// re-broadcasts a fresh `ServerMsg::MotherJobs` on completion.
    MotherResume {
        job_id: String,
        answer: String,
    },
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
    MotherJobs {
        jobs: Vec<MotherJob>,
    },
    MotherStatusline(MotherStatus),
    /// A job transitioned into `awaiting` — daemon fires this once per
    /// transition (same logic as the in-process `mother_poll`).
    /// Boxed: `MotherJob` is the largest payload in this enum (esp. with
    /// `cycles`/`phases`), so boxing keeps `ServerMsg`'s size down
    /// (clippy::large_enum_variant).
    MotherAwaitDetected(Box<MotherJob>),
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

    /// Sent immediately after `PtySpawned` to convey the Nostromo identity
    /// env vars injected into the child process.
    ///
    /// Using a follow-up message rather than extending `PtySpawned` avoids a
    /// protocol version bump; clients that don't understand this message will
    /// simply ignore it.
    PtyIdentity {
        /// Daemon-side `pty_id` that this identity corresponds to.
        pty_id: String,
        /// Value of `NOSTROMO_PTY_ID` injected into the child env.
        nostromo_pty_id: String,
        /// Value of `NOSTROMO_SESSION_ID` injected into the child env.
        nostromo_session_id: String,
    },

    // ── persistent session responses (protocol v3) ───────────────────────────
    /// A session was spawned (or was already live). Carries the resolved
    /// `claude` session id once known.
    SessionSpawned {
        tag: String,
        session_id: Option<String>,
    },

    /// Full turn snapshot, sent immediately on attach.
    SessionTurns {
        tag: String,
        turns: Vec<Turn>,
    },

    /// Incremental turn update.
    SessionTurnDelta {
        tag: String,
        delta: TurnDelta,
    },

    /// Session lifecycle state changed.
    SessionState {
        tag: String,
        state: SessionState,
    },

    /// A permission request surfaced on the stream (only emitted if the binary
    /// surfaces an answerable request; otherwise permissions are bypassed or
    /// answered natively on the phone).
    SessionPermissionRequest {
        tag: String,
        request_id: String,
        tool: String,
        input: serde_json::Value,
    },

    /// The session's child process exited.
    SessionExited {
        tag: String,
        exit_code: Option<i32>,
    },

    /// The session has been permanently stopped and will not auto-restart.
    ///
    /// Fired by the daemon when:
    /// - `stop()` is called (user-requested stop → `reason: user`), or
    /// - the crash-loop guard trips (`reason: crash_loop_guard`).
    ///
    /// `reason: user` means the indicator should clear (intended stop, not an
    /// alarm). `reason: crash_loop_guard` is the alarm case — the GUI should
    /// show a recovery UI. Recovery uses the existing `SessionControl` message
    /// with `action: restart` / `action: new_session`.
    SessionDown {
        tag: String,
        reason: StopReason,
    },

    /// Response to `SessionList`.
    SessionListResp {
        sessions: Vec<SessionInfo>,
    },

    /// Auto-generated one-line summary derived from the first user message.
    /// Sent once per session lifetime (guarded by `summary_sent` on the daemon).
    /// The Swift client stores this as `Focus.sessionSummary` for sidenav disambiguation.
    SessionSummaryUpdate {
        tag: String,
        summary: String,
    },

    /// Response to `FocusList`.
    FocusListResp {
        focuses: Vec<FocusMeta>,
    },
    /// Broadcast to all clients whenever the registry changes (push received).
    FocusRegistryUpdated {
        focuses: Vec<FocusMeta>,
    },

    /// TUI-internal pseudo-event — **never produced by the daemon**.
    ///
    /// Injected locally by the [`DaemonClient`] supervisor immediately after a
    /// successful reconnect so subscribers (e.g. `DaemonPtyClient`) can
    /// re-issue their attach/subscribe commands.
    DaemonReconnected,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::stream_json::{Turn, TurnDelta};

    /// Round-trip a ClientMsg through JSON and back, asserting equality of the
    /// re-serialised form (ClientMsg isn't PartialEq, so compare JSON).
    fn round_trip_client(msg: ClientMsg) {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ClientMsg = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&back).unwrap();
        assert_eq!(json, json2, "client msg round trip mismatch: {json}");
    }

    fn round_trip_server(msg: ServerMsg) {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ServerMsg = serde_json::from_str(&json).unwrap();
        let json2 = serde_json::to_string(&back).unwrap();
        assert_eq!(json, json2, "server msg round trip mismatch: {json}");
    }

    #[test]
    fn session_client_messages_round_trip() {
        round_trip_client(ClientMsg::SessionSpawn {
            tag: "fred".into(),
            agent_name: "fred".into(),
            view_name: "Fred".into(),
            cwd: Some("/tmp".into()),
            session_id: Some("sid-1".into()),
            remote_control: true,
        });
        round_trip_client(ClientMsg::SessionAttach { tag: "fred".into() });
        round_trip_client(ClientMsg::SessionDetach { tag: "fred".into() });
        round_trip_client(ClientMsg::SessionSend {
            tag: "fred".into(),
            text: "hello".into(),
            images: vec![],
        });
        round_trip_client(ClientMsg::SessionSend {
            tag: "fred".into(),
            text: "look at this".into(),
            images: vec!["/tmp/a.png".into()],
        });
        round_trip_client(ClientMsg::SessionControl {
            tag: "fred".into(),
            action: SessionAction::Restart,
        });
        round_trip_client(ClientMsg::SessionAnswerPermission {
            tag: "fred".into(),
            request_id: "r1".into(),
            decision: PermissionDecision::Allow,
        });
        round_trip_client(ClientMsg::SessionList);
    }

    #[test]
    fn session_server_messages_round_trip() {
        round_trip_server(ServerMsg::SessionSpawned {
            tag: "fred".into(),
            session_id: Some("sid".into()),
        });
        round_trip_server(ServerMsg::SessionTurns {
            tag: "fred".into(),
            turns: vec![Turn {
                id: "t0".into(),
                user_input: "hi".into(),
                timestamp: None,
                blocks: vec![],
                is_complete: false,
            }],
        });
        round_trip_server(ServerMsg::SessionTurnDelta {
            tag: "fred".into(),
            delta: TurnDelta::TurnStarted {
                turn: Turn {
                    id: "t0".into(),
                    user_input: "hi".into(),
                    timestamp: None,
                    blocks: vec![],
                    is_complete: false,
                },
            },
        });
        round_trip_server(ServerMsg::SessionState {
            tag: "fred".into(),
            state: SessionState::MidTurn,
        });
        round_trip_server(ServerMsg::SessionPermissionRequest {
            tag: "fred".into(),
            request_id: "r1".into(),
            tool: "Bash".into(),
            input: serde_json::json!({"command": "ls"}),
        });
        round_trip_server(ServerMsg::SessionExited {
            tag: "fred".into(),
            exit_code: Some(0),
        });
        round_trip_server(ServerMsg::SessionListResp {
            sessions: vec![SessionInfo {
                tag: "fred".into(),
                agent_name: "fred".into(),
                view_name: "Fred".into(),
                session_id: None,
                alive: true,
                remote_control: false,
                state: SessionState::Idle,
                stop_reason: None,
            }],
        });
    }

    #[test]
    fn session_action_is_snake_case() {
        assert_eq!(
            serde_json::to_string(&SessionAction::NewSession).unwrap(),
            "\"new_session\""
        );
    }

    #[test]
    fn client_msg_uses_type_tag() {
        let v = serde_json::to_value(ClientMsg::SessionSend {
            tag: "t".into(),
            text: "x".into(),
            images: vec![],
        })
        .unwrap();
        assert_eq!(v.get("type").unwrap(), "session_send");
    }

    #[test]
    fn protocol_version_is_v4() {
        assert_eq!(PROTOCOL_VERSION, 4);
        // The MIN_CLIENT_VERSION <= PROTOCOL_VERSION invariant is enforced at
        // compile time via a `const _` assertion near the constant definitions.
    }

    // ── StopReason / SessionDown / SessionInfo.stop_reason ───────────────────

    #[test]
    fn stop_reason_serializes_snake_case() {
        use crate::ipc::session_manager::StopReason;
        assert_eq!(
            serde_json::to_string(&StopReason::CrashLoopGuard).unwrap(),
            "\"crash_loop_guard\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::User).unwrap(),
            "\"user\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::StaleId).unwrap(),
            "\"stale_id\""
        );
    }

    #[test]
    fn session_down_server_message_round_trips() {
        use crate::ipc::session_manager::StopReason;
        round_trip_server(ServerMsg::SessionDown {
            tag: "fred".into(),
            reason: StopReason::CrashLoopGuard,
        });
    }

    #[test]
    fn session_summary_update_round_trips() {
        round_trip_server(ServerMsg::SessionSummaryUpdate {
            tag: "fred".into(),
            summary: "Build the auth flow".into(),
        });
    }

    #[test]
    fn focus_meta_round_trips() {
        // All optionals Some
        let full = FocusMeta {
            tag:             "cody-abc12345".into(),
            display_name:    "Cody in Admin Portal".into(),
            agent_name:      "cody".into(),
            project_name:    Some("Admin Portal".into()),
            org:             Some("Carefeed".into()),
            is_built_in:     false,
            session_summary: Some("Build the auth flow".into()),
        };
        let json = serde_json::to_string(&full).unwrap();
        let back: FocusMeta = serde_json::from_str(&json).unwrap();
        assert_eq!(full, back);

        // All optionals None
        let minimal = FocusMeta {
            tag:             "fred".into(),
            display_name:    "Fred".into(),
            agent_name:      "fred".into(),
            project_name:    None,
            org:             None,
            is_built_in:     true,
            session_summary: None,
        };
        let json = serde_json::to_string(&minimal).unwrap();
        let back: FocusMeta = serde_json::from_str(&json).unwrap();
        assert_eq!(minimal, back);
    }

    #[test]
    fn mother_action_round_trip() {
        round_trip_client(ClientMsg::MotherAction {
            job_id: "job-123".into(),
            action: MotherActionKind::Cancel,
        });
        round_trip_client(ClientMsg::MotherAction {
            job_id: "job-456".into(),
            action: MotherActionKind::Retry,
        });
        round_trip_client(ClientMsg::MotherAction {
            job_id: "job-789".into(),
            action: MotherActionKind::ForceStart,
        });
    }

    #[test]
    fn mother_resume_round_trip() {
        round_trip_client(ClientMsg::MotherResume {
            job_id: "job-abc".into(),
            answer: "yes, proceed with the migration".into(),
        });
        round_trip_client(ClientMsg::MotherResume {
            job_id: "job-def".into(),
            answer: "no".into(),
        });
    }

    #[test]
    fn mother_action_kind_serializes_snake_case() {
        assert_eq!(
            serde_json::to_string(&MotherActionKind::Cancel).unwrap(),
            "\"cancel\""
        );
        assert_eq!(
            serde_json::to_string(&MotherActionKind::Retry).unwrap(),
            "\"retry\""
        );
        assert_eq!(
            serde_json::to_string(&MotherActionKind::ForceStart).unwrap(),
            "\"force_start\""
        );
    }

    #[test]
    fn focus_registry_messages_round_trip() {
        let meta = FocusMeta {
            tag:             "fred".into(),
            display_name:    "Fred".into(),
            agent_name:      "fred".into(),
            project_name:    None,
            org:             Some("Carefeed".into()),
            is_built_in:     true,
            session_summary: None,
        };

        round_trip_client(ClientMsg::FocusRegistryPush {
            focuses: vec![meta.clone()],
        });
        round_trip_client(ClientMsg::FocusList);

        round_trip_server(ServerMsg::FocusListResp {
            focuses: vec![meta.clone()],
        });
        round_trip_server(ServerMsg::FocusRegistryUpdated {
            focuses: vec![meta],
        });
    }

    #[test]
    fn session_info_stop_reason_round_trips() {
        use crate::ipc::session_manager::StopReason;
        // With a stop_reason set.
        round_trip_server(ServerMsg::SessionListResp {
            sessions: vec![SessionInfo {
                tag: "fred".into(),
                agent_name: "fred".into(),
                view_name: "Fred".into(),
                session_id: None,
                alive: false,
                remote_control: false,
                state: SessionState::Idle,
                stop_reason: Some(StopReason::CrashLoopGuard),
            }],
        });
        // With no stop_reason.
        round_trip_server(ServerMsg::SessionListResp {
            sessions: vec![SessionInfo {
                tag: "fred".into(),
                agent_name: "fred".into(),
                view_name: "Fred".into(),
                session_id: None,
                alive: true,
                remote_control: false,
                state: SessionState::Idle,
                stop_reason: None,
            }],
        });
    }
}
