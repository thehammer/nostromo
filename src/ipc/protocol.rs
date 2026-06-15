//! IPC wire protocol shared between the `nostromd` daemon and TUI clients.
//!
//! Frames are length-prefixed: a big-endian u32 byte count followed by a JSON
//! body.  Maximum frame size is 4 MiB.

use std::path::PathBuf;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::{
    agent_bus::ActivityEvent,
    data::{perri_pr::PrSnapshot, perri_queue::{CiState, PrQueueItem}},
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
    MotherPeek,
    /// Perri PR review queue + current-PR snapshot broadcasts.
    Perri,
    Fred,
    Teri,
    /// Agent-authored pane layout + content broadcasts (`FocusLayout`,
    /// `PaneContent`, `FocusCreated`).
    Layout,
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
    Archive,
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

// ── agent-authored pane layout (Phase 1: agent-driven-pane-layout) ───────────

/// Direction a split node lays its children out in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDirection {
    /// Children laid out left → right (a vertical divider between columns).
    Horizontal,
    /// Children laid out top → bottom (a horizontal divider between rows).
    Vertical,
}

/// A node in a focus's agent-authored pane layout tree.
///
/// The tree is the canonical description of how a focus's workspace is split.
/// Leaves are panes addressable by `pane_id`; interior `Split` nodes carry a
/// direction, ordered children, and per-child ratios (parallel to `children`,
/// conventionally summing to ~1.0).
///
/// Invariants enforced by the daemon's pane registry (not by this type):
/// - exactly one leaf has `pane_id == "repl"` (B2 — the REPL is a pane, not a
///   privileged host),
/// - pane ids are unique within a focus,
/// - every `Split` has `children.len() == ratios.len()` and `children.len() >= 2`.
///
/// `#[serde(tag = "kind")]` gives a self-describing wire shape the Swift/iOS
/// clients decode directly:
/// `{"kind":"leaf","pane_id":"repl"}` /
/// `{"kind":"split","direction":"horizontal","children":[…],"ratios":[0.5,0.5]}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PaneTree {
    /// A leaf pane.
    Leaf { pane_id: String },
    /// An interior split with ordered children and parallel ratios.
    Split {
        direction: SplitDirection,
        children: Vec<PaneTree>,
        ratios: Vec<f32>,
    },
}

impl PaneTree {
    /// A fresh focus: a single REPL leaf.
    pub fn repl_leaf() -> Self {
        PaneTree::Leaf {
            pane_id: "repl".to_string(),
        }
    }

    /// Collect every pane id in left-to-right, depth-first tree order.
    pub fn pane_ids(&self) -> Vec<String> {
        let mut out = Vec::new();
        self.collect_pane_ids(&mut out);
        out
    }

    fn collect_pane_ids(&self, out: &mut Vec<String>) {
        match self {
            PaneTree::Leaf { pane_id } => out.push(pane_id.clone()),
            PaneTree::Split { children, .. } => {
                for c in children {
                    c.collect_pane_ids(out);
                }
            }
        }
    }
}

/// One item in a `pr_list` pane payload.
///
/// Carries the fields `PerriPRRowModel` needs plus the `repo`/`number`
/// identity the action path (`load_pr`, `approve`) keys on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PrListItem {
    /// Repository in `owner/name` form.
    pub repo: String,
    /// PR number.
    pub number: u64,
    /// PR title.
    pub title: String,
    /// PR author login.
    pub author: String,
    /// Review bucket: `"requested"`, `"needs_review"`, `"changes_req"`, `"dependabot"`.
    pub bucket: String,
    /// Rolled-up CI state.
    pub ci_state: CiState,
    /// `true` when the PR has new activity since last review.
    #[serde(default)]
    pub new_activity: bool,
    /// HTML URL for the PR.
    #[serde(default)]
    pub url: String,
    /// HEAD commit SHA.
    #[serde(default)]
    pub head_sha: String,
}

/// Content payload pushed to a single pane, decoupled from layout geometry.
///
/// `PaneContent` is a separate wire message from `FocusLayout` precisely so a
/// content refresh never carries split ratios — that is the mechanism by which
/// an operator's manual drag-resize survives content updates (only a structural
/// message re-declares geometry).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PaneContentWire {
    /// Plain/markdown/mono text.
    Text { text: String },
    /// A structured JSON snapshot the client renders generically.
    JsonSnapshot { value: serde_json::Value },
    /// A typed list of PR queue items, rendered by `PerriPRRow`.
    PrList { items: Vec<PrListItem> },
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

    /// Request a Perri action. The daemon shells out to `perri <action> …` or
    /// `gh …` and the native Perri source re-broadcasts a fresh `PerriState`
    /// via the watch channel.
    ///
    /// Recognised actions:
    ///   - `"load_pr"` — requires `pr_number` + `repo`
    ///   - `"clear"`   — clears the current PR; `pr_number`/`repo` are ignored
    ///   - `"approve"` — requires `pr_number` + `repo`; resolves the HEAD sha,
    ///     posts `gh pr review --approve`, then writes the Phase 1 approval
    ///     signal (approvals.jsonl + queue.dirty) for instant queue suppression.
    ///     No comment body — iOS approve is comment-free.
    PerriAction {
        /// Action to perform (`"load_pr"`, `"clear"`, or `"approve"`).
        action: String,
        /// PR number for `load_pr` and `approve`; `None` for `clear`.
        pr_number: Option<u64>,
        /// `owner/name` repo slug for `load_pr` and `approve`; `None` for `clear`.
        repo: Option<String>,
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
    /// Broadcast snapshot of Teri's active todos.
    TeriState {
        todos: crate::data::teri_todos::TeriTodosSnapshot,
    },
    /// A job transitioned into `awaiting` — daemon fires this once per
    /// transition (same logic as the in-process `mother_poll`).
    /// Boxed: `MotherJob` is the largest payload in this enum (esp. with
    /// `cycles`/`phases`), so boxing keeps `ServerMsg`'s size down
    /// (clippy::large_enum_variant).
    MotherAwaitDetected(Box<MotherJob>),

    /// Broadcast snapshot of Perri's PR review state. Re-sent whenever the
    /// native queue or current-PR watch channel changes.
    PerriState {
        queue: Vec<PrQueueItem>,
        current: Option<Box<PrSnapshot>>,
    },

    /// Broadcast snapshot of Fred's mailbox + calendar state. Re-sent whenever
    /// either native source's watch channel changes.
    FredState {
        mailbox: crate::data::fred_mailbox::MailboxSnapshot,
        calendar: crate::data::fred_calendar::CalendarSnapshot,
    },
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

    /// Live peek snapshot for one active job. Polled every ~3 s while the
    /// job is running or awaiting; a final snapshot is sent on terminal
    /// transition (succeeded/failed/cancelled) with an empty todo list so
    /// clients can clear the display.
    MotherPeek {
        job_id: String,
        todos: Vec<crate::mother::PeekTodo>,
        /// Last 3 tool calls (tool name + brief).
        tool_trail: Vec<crate::mother::PeekToolCall>,
        /// Most recent assistant text snippet (first 200 chars).
        last_text: String,
    },

    // ── agent-authored pane layout (Phase 1) ─────────────────────────────────
    /// Broadcast of a focus's current pane tree. Sent whenever an agent mutates
    /// the layout (create_pane / reset_panes / set_pane_layout) and replayed to a
    /// client on `SessionAttach` so a reconnecting client renders the
    /// already-assembled workspace with no re-assembly. This is the *structural*
    /// message — it carries geometry; content pushes do not.
    FocusLayout {
        tag: String,
        tree: PaneTree,
        /// The pane the agent wants foregrounded (the iOS degradation hint).
        #[serde(skip_serializing_if = "Option::is_none", default)]
        focused_pane: Option<String>,
    },

    /// Content push for a single pane, decoupled from layout geometry so a
    /// refresh never moves a split (preserving operator drag-resizes).
    PaneContent {
        tag: String,
        pane_id: String,
        content: PaneContentWire,
    },

    /// The daemon announces an agent-spawned focus (via `create_focus`) so every
    /// connected client can add the new tab.
    FocusCreated {
        meta: FocusMeta,
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
    fn teri_state_round_trips() {
        use crate::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
        let snap = TeriTodosSnapshot {
            generated_at: None,
            items: vec![TeriTodo {
                id: 1,
                title: "Write the Teri broadcast".into(),
                status: "open".into(),
                priority: 1,
                due_date: Some("2026-07-01".into()),
                jira_key: Some("CORE-123".into()),
            }],
            stale: false,
            error: None,
        };
        round_trip_server(ServerMsg::TeriState { todos: snap });
    }

    #[test]
    fn topic_teri_serializes_to_teri() {
        assert_eq!(
            serde_json::to_string(&Topic::Teri).unwrap(),
            "\"teri\""
        );
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
        assert_eq!(
            serde_json::to_string(&MotherActionKind::Archive).unwrap(),
            "\"archive\""
        );
    }

    #[test]
    fn mother_peek_round_trip_with_todos() {
        use crate::mother::{PeekTodo, PeekToolCall};
        round_trip_server(ServerMsg::MotherPeek {
            job_id: "job-abc123".into(),
            todos: vec![
                PeekTodo { status: "completed".into(), content: "Add Rust protocol variant".into() },
                PeekTodo { status: "in_progress".into(), content: "Add NostromoKit wire types".into() },
                PeekTodo { status: "pending".into(), content: "Add iOS tab".into() },
            ],
            tool_trail: vec![
                PeekToolCall { tool: "Read".into(), brief: "src/ipc/protocol.rs".into() },
                PeekToolCall { tool: "Edit".into(), brief: "add MotherPeek variant".into() },
            ],
            last_text: "Implementing the MotherPeek broadcast".into(),
        });
        // Assert the type tag serialises correctly.
        let json = serde_json::to_value(ServerMsg::MotherPeek {
            job_id: "j".into(),
            todos: vec![],
            tool_trail: vec![],
            last_text: "".into(),
        })
        .unwrap();
        assert_eq!(json.get("type").unwrap(), "mother_peek");
    }

    #[test]
    fn mother_peek_round_trip_empty_terminal_clear() {
        round_trip_server(ServerMsg::MotherPeek {
            job_id: "job-xyz".into(),
            todos: vec![],
            tool_trail: vec![],
            last_text: String::new(),
        });
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
    fn layout_messages_round_trip() {
        let tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Split {
                    direction: SplitDirection::Vertical,
                    children: vec![
                        PaneTree::Leaf {
                            pane_id: "jobs".into(),
                        },
                        PaneTree::Leaf {
                            pane_id: "log".into(),
                        },
                    ],
                    ratios: vec![0.6, 0.4],
                },
            ],
            ratios: vec![0.3, 0.7],
        };

        round_trip_server(ServerMsg::FocusLayout {
            tag: "mother".into(),
            tree: tree.clone(),
            focused_pane: Some("log".into()),
        });
        round_trip_server(ServerMsg::PaneContent {
            tag: "mother".into(),
            pane_id: "log".into(),
            content: PaneContentWire::Text {
                text: "hello".into(),
            },
        });
        round_trip_server(ServerMsg::PaneContent {
            tag: "mother".into(),
            pane_id: "jobs".into(),
            content: PaneContentWire::JsonSnapshot {
                value: serde_json::json!({ "jobs": [1, 2, 3] }),
            },
        });
        round_trip_server(ServerMsg::FocusCreated {
            meta: FocusMeta {
                tag: "cody-core-1234".into(),
                display_name: "CORE-1234".into(),
                agent_name: "cody".into(),
                project_name: None,
                org: None,
                is_built_in: false,
                session_summary: None,
            },
        });
    }

    #[test]
    fn pane_tree_collects_ids_in_tree_order() {
        let tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Leaf {
                    pane_id: "jobs".into(),
                },
            ],
            ratios: vec![0.5, 0.5],
        };
        assert_eq!(tree.pane_ids(), vec!["repl", "jobs"]);
        assert_eq!(PaneTree::repl_leaf().pane_ids(), vec!["repl"]);
    }

    #[test]
    fn layout_topic_round_trips() {
        assert_eq!(serde_json::to_string(&Topic::Layout).unwrap(), "\"layout\"");
        let decoded: Topic = serde_json::from_str("\"layout\"").unwrap();
        assert_eq!(decoded, Topic::Layout);
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

    // ── PerriAction / PerriState ─────────────────────────────────────────────

    #[test]
    fn perri_action_round_trip() {
        // load_pr with all fields
        round_trip_client(ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(42),
            repo: Some("acme/web".into()),
        });
        // clear — pr_number and repo are None
        round_trip_client(ClientMsg::PerriAction {
            action: "clear".into(),
            pr_number: None,
            repo: None,
        });
        // approve — pr_number and repo required
        round_trip_client(ClientMsg::PerriAction {
            action: "approve".into(),
            pr_number: Some(7),
            repo: Some("acme/web".into()),
        });
    }

    #[test]
    fn perri_action_approve_wire_shape() {
        let v = serde_json::to_value(ClientMsg::PerriAction {
            action: "approve".into(),
            pr_number: Some(7),
            repo: Some("acme/web".into()),
        })
        .unwrap();
        assert_eq!(v["type"], "perri_action");
        assert_eq!(v["action"], "approve");
        assert_eq!(v["pr_number"], 7u64);
        assert_eq!(v["repo"], "acme/web");
    }

    #[test]
    fn perri_action_type_tag_is_perri_action() {
        let v = serde_json::to_value(ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(1),
            repo: Some("org/repo".into()),
        })
        .unwrap();
        assert_eq!(v["type"], "perri_action");
        assert_eq!(v["pr_number"], 1u64);
        assert_eq!(v["repo"], "org/repo");

        let v2 = serde_json::to_value(ClientMsg::PerriAction {
            action: "clear".into(),
            pr_number: None,
            repo: None,
        })
        .unwrap();
        assert_eq!(v2["type"], "perri_action");
        assert!(v2["pr_number"].is_null());
        assert!(v2["repo"].is_null());
    }

    #[test]
    fn perri_state_round_trip_empty() {
        round_trip_server(ServerMsg::PerriState {
            queue: vec![],
            current: None,
        });
    }

    #[test]
    fn perri_state_round_trip_populated() {
        use crate::data::{
            perri_pr::{CiCheck, PrSnapshot},
            perri_queue::{CiState, PrQueueItem},
        };

        let item = PrQueueItem {
            repo: "acme/web".into(),
            number: 42,
            title: "feat: auth".into(),
            author: "alice".into(),
            bucket: "requested".into(),
            new_activity: false,
            url: "https://github.com/acme/web/pull/42".into(),
            ci_state: CiState::Success,
            head_sha: "abc123".into(),
            is_bot: false,
        };
        let snap = PrSnapshot {
            pr_number: Some(42),
            repo: "acme/web".into(),
            title: "feat: auth".into(),
            author: "alice".into(),
            url: "https://github.com/acme/web/pull/42".into(),
            diff: "--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,1 +1,1 @@\n-old\n+new".into(),
            stale: false,
            error: None,
            ci_checks: vec![CiCheck {
                name: "test".into(),
                state: CiState::Success,
                detail: None,
            }],
            additions: 10,
            deletions: 5,
            changed_files: 2,
            head_sha: "abc123".into(),
            diff_too_large: false,
        };

        round_trip_server(ServerMsg::PerriState {
            queue: vec![item],
            current: Some(Box::new(snap)),
        });
    }

    #[test]
    fn perri_state_type_tag_is_perri_state() {
        let v = serde_json::to_value(ServerMsg::PerriState {
            queue: vec![],
            current: None,
        })
        .unwrap();
        assert_eq!(v["type"], "perri_state");
    }

    #[test]
    fn topic_perri_serializes_to_perri() {
        assert_eq!(
            serde_json::to_string(&Topic::Perri).unwrap(),
            "\"perri\""
        );
        let decoded: Topic = serde_json::from_str("\"perri\"").unwrap();
        assert_eq!(decoded, Topic::Perri);
    }

    // ── FredState round-trip + type-tag ──────────────────────────────────────

    #[test]
    fn fred_state_round_trips() {
        use crate::data::{
            fred_calendar::{CalendarEvent, CalendarSnapshot, NextEvent},
            fred_mailbox::{DeviceFlowPrompt, MailboxItem, MailboxSnapshot},
        };

        // (a) Empty snapshots
        round_trip_server(ServerMsg::FredState {
            mailbox:  MailboxSnapshot::default(),
            calendar: CalendarSnapshot::default(),
        });

        // (b) Populated: one VIP unread MailboxItem + one is_now CalendarEvent +
        //     NextEvent + auth_prompt.
        let mailbox = MailboxSnapshot {
            generated_at: None,
            unread_count: 1,
            items: vec![MailboxItem {
                from:        "Alice <alice@example.com>".into(),
                subject:     "Important: Meeting Tomorrow".into(),
                received_at: Some(chrono::Utc::now()),
                vip:         true,
                is_invite:   false,
                is_read:     false,
            }],
            stale:       false,
            error:       None,
            auth_prompt: Some(DeviceFlowPrompt {
                verification_uri: "https://microsoft.com/devicelogin".into(),
                user_code:        "ABCD-1234".into(),
                expires_at:       chrono::Utc::now(),
            }),
        };
        let calendar = CalendarSnapshot {
            events: vec![CalendarEvent {
                start:  Some(chrono::Utc::now()),
                end:    Some(chrono::Utc::now()),
                title:  "Daily standup".into(),
                status: "accepted".into(),
                is_now: true,
            }],
            next: Some(NextEvent {
                title:      "Lunch".into(),
                in_minutes: 45,
            }),
            sweater: "amber".into(),
            stale:   false,
            error:   None,
        };
        round_trip_server(ServerMsg::FredState { mailbox, calendar });
    }

    #[test]
    fn fred_state_type_tag_is_fred_state() {
        let v = serde_json::to_value(ServerMsg::FredState {
            mailbox:  crate::data::fred_mailbox::MailboxSnapshot::default(),
            calendar: crate::data::fred_calendar::CalendarSnapshot::default(),
        })
        .unwrap();
        assert_eq!(v["type"], "fred_state");
    }

    // ── PaneContentWire::PrList ──────────────────────────────────────────────

    #[test]
    fn pane_content_pr_list_round_trip() {
        use crate::data::perri_queue::CiState;
        round_trip_server(ServerMsg::PaneContent {
            tag: "perri".into(),
            pane_id: "queue".into(),
            content: PaneContentWire::PrList {
                items: vec![PrListItem {
                    repo:         "acme/web".into(),
                    number:       42,
                    title:        "feat: auth".into(),
                    author:       "alice".into(),
                    bucket:       "requested".into(),
                    ci_state:     CiState::Success,
                    new_activity: false,
                    url:          "https://github.com/acme/web/pull/42".into(),
                    head_sha:     "abc123".into(),
                }],
            },
        });
    }

    #[test]
    fn pane_content_pr_list_wire_kind() {
        let json: serde_json::Value = serde_json::from_str(
            &serde_json::to_string(&PaneContentWire::PrList { items: vec![] }).unwrap(),
        )
        .unwrap();
        assert_eq!(json["kind"], "pr_list");
    }
}
