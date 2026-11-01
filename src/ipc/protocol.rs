//! IPC wire protocol shared between the `nostromd` daemon and TUI clients.
//!
//! Frames are length-prefixed: a big-endian u32 byte count followed by a JSON
//! body.  Maximum frame size is 4 MiB.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{
    agent_bus::ActivityEvent,
    data::{
        perri_pr::PrSnapshot,
        perri_queue::{CiState, PrQueueItem},
    },
    ipc::{
        session_manager::StopReason,
        stream_json::{SessionState, Turn, TurnDelta, TurnOrigin},
    },
    mother::{MotherJob, MotherStatus},
};

/// Per-status item counts of a board (`TrackerSummary.counts`): exactly the
/// five status keys.
pub use crate::tracker::Counts as TrackerCounts;

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

/// Return the socket path, honouring `NOSTROMOD_SOCKET` if set (see
/// `SOCKET_PATH_ENV` above — this doc comment previously said `NOSTROMD_SOCKET`,
/// which is a different string the Swift client reads instead; the two
/// spellings coexist today because their defaults agree, so nothing broke
/// until something overrode one and not the other. Consolidating them is a
/// separate cleanup — see `bin/nostromo-launch-smoke`, which sets both).
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
    /// Teri work-item data: `WorkSourceStatus`, `WorkSnapshot`, `TeriPicks`.
    /// Sensitive — never delivered to a network (TCP) peer.
    Work,
    /// Agent-authored pane layout + content broadcasts (`FocusLayout`,
    /// `PaneContent`, `FocusCreated`).
    Layout,
    /// Daemon-driven decision-modal requests (`DecisionRequest`). Naming this
    /// topic explicitly is one of two ways a client claims operator status —
    /// the other is `ClientMsg::Subscribe`'s `renders_decisions: true` flag,
    /// for a client that subscribes to everything (`topics: []`) without
    /// enumerating individual topics. `nostromo.ask_decision` refuses with
    /// `no_operator` when neither is true for any connected client — a
    /// wildcard subscriber that does neither (e.g. a client with no code path
    /// to render a decision) is deliberately NOT counted as an operator, even
    /// though it still receives `DecisionRequest` broadcasts like any other
    /// message.
    Decision,
    /// Model switching: `ModelCatalog`, `ModelDefaults` and every focus's
    /// `SessionModelState`, broadcast on change and replayed on subscribe, and
    /// the `TurnBlock::Note` markers in transcripts. Advertised as the `model`
    /// feature in `Welcome.features`. Delivered only to a client that names
    /// it: the empty "everything" list does not include it (an older client
    /// fails to decode a transcript carrying a note).
    Model,
    /// Terminal pane metadata: `TerminalState` and `TerminalClosed`. Never
    /// terminal bytes: `TerminalOutput`/`TerminalReplay` go only to the
    /// connections attached to a terminal, on their targeted channel. An empty
    /// topic list still includes it for a local peer; FND-1 keeps every
    /// terminal frame off TCP (`ServerClass::LocalOnly`).
    Terminal,
    /// A topic this build does not know (a newer client's). Decoded rather
    /// than rejected so a future topic never makes an older daemon drop the
    /// whole `Subscribe`; it matches no message, and, because it keeps the
    /// list non-empty, it never degrades into the empty-list wildcard.
    #[serde(other)]
    Unknown,
}

/// Decode a `Subscribe` topic list leniently: an element that is not a topic
/// this build knows (an unknown name, or not a string at all) becomes
/// [`Topic::Unknown`] instead of failing the whole frame.
fn lenient_topics<'de, D>(deserializer: D) -> Result<Vec<Topic>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Vec::<serde_json::Value>::deserialize(deserializer)?;
    Ok(raw
        .into_iter()
        .map(|v| serde_json::from_value(v).unwrap_or(Topic::Unknown))
        .collect())
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

/// Severity of a `ServerMsg::Notification` (W5 — current-pr-collision).
/// Mirrors the macOS client's `ToastSeverity` case-for-case so decoding is a
/// direct string match with no translation table to drift.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationLevel {
    Info,
    Warning,
    Alert,
}

/// One choice offered by a `ServerMsg::DecisionRequest` (W6 decision modals).
///
/// Deliberately just `id`/`label`/`detail` — there is no free-form content
/// field anywhere in this type or its parent message, which is what makes a
/// decision modal structurally incapable of being used as a content channel
/// (the PRD's R7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DecisionChoice {
    /// Stable id returned as `choice_id` when this option is picked.
    pub id: String,
    /// Button label the operator reads.
    pub label: String,
    /// Optional short supporting text for this option.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub detail: Option<String>,
    /// This is the choice Return (and Escape) picks: a sheet presents it as
    /// the default button. Absent from the wire when false, so every
    /// payload that predates it is byte-identical.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_default: bool,
}

/// How a `ServerMsg::DecisionRequest` was ultimately resolved, carried on
/// `ServerMsg::DecisionResolved` so every presenting window — not just the
/// one the operator actually used — learns a request is done and can close
/// its own sheet without answering (multi-window decision-sheet fix).
/// Mirrors [`crate::ipc::decisions::DecisionOutcome`] on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionResolution {
    /// The operator picked a choice (see the sibling `choice_id`).
    Answered,
    /// The operator dismissed the modal without choosing.
    Dismissed,
    /// Nobody answered within the caller's timeout.
    Timeout,
    /// The owning session went away while the request was outstanding.
    Cancelled,
}

// ── model switching ───────────────────────────────────────────────────────────

/// An effort choice: the model's default, or an explicit level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffortChoice {
    Default,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl EffortChoice {
    /// The explicit level, or `None` for the model's default.
    pub fn level(self) -> Option<&'static str> {
        match self {
            EffortChoice::Default => None,
            EffortChoice::Low => Some("low"),
            EffortChoice::Medium => Some("medium"),
            EffortChoice::High => Some("high"),
            EffortChoice::Xhigh => Some("xhigh"),
            EffortChoice::Max => Some("max"),
        }
    }
}

/// One model family in `ServerMsg::ModelCatalog`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelFamilyWire {
    /// What to ask for (`"opus"`).
    pub alias: String,
    pub display_name: String,
    /// The full model name the alias currently resolves to.
    #[serde(default)]
    pub resolved: Option<String>,
    /// Effort levels the model accepts (empty: no effort support).
    #[serde(default)]
    pub efforts: Vec<String>,
    /// Cost rank, cheapest lowest.
    pub rank: u32,
}

/// What a focus is recorded to run on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordedModel {
    pub model: String,
    #[serde(default)]
    pub effort: Option<String>,
    pub source: crate::model::store::ModelSource,
}

/// What a running session says it runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportedModel {
    /// Full model name, e.g. `claude-sonnet-5-5`.
    pub model: String,
    /// The family alias it belongs to, when known.
    #[serde(default)]
    pub family: Option<String>,
}

/// A switch not yet applied.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingModel {
    pub model: String,
    #[serde(default)]
    pub effort: Option<String>,
}

/// Where a focus's switch stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SwitchPhase {
    /// No switch in progress.
    #[default]
    Steady,
    /// A switch waits for the running turn to end.
    Waiting,
    /// A switch is being applied.
    Applying,
}

/// A warning attached to a candidate model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelWarning {
    /// The candidate it concerns: a family alias (`"opus"`) for a model row,
    /// or `"effort:<level>"` (`"effort:max"`) for an effort row.
    pub target: String,
    pub text: String,
}

/// How a model request ended (or stands).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelRequestStatus {
    Applied,
    PendingTurnEnd,
    Unchanged,
    Refused,
    Failed,
    AwaitingUser,
    /// An agent's upgrade request the user denied (or dismissed).
    Denied,
    /// An agent's upgrade request nobody answered in time.
    Expired,
}

/// The most recent request to change a focus's model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastModelRequest {
    /// `user`, `script` or `agent:<name>`.
    pub actor: String,
    /// What was asked for, e.g. `opus` or `opus · effort high`.
    pub to: String,
    pub status: ModelRequestStatus,
    pub ts: chrono::DateTime<chrono::Utc>,
    /// The `request_id` of the `SessionModelSet` that made it, so a client
    /// waiting on a switch that applies later can recognise its outcome.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

/// One focus's model state (`ServerMsg::SessionModelState`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionModelState {
    pub tag: String,
    /// What the focus is recorded to run on; `None` when nothing was ever
    /// chosen and the session has not reported yet.
    #[serde(default)]
    pub recorded: Option<RecordedModel>,
    /// What the running session last reported (assistant message model, else
    /// the turn's init model).
    #[serde(default)]
    pub reported: Option<ReportedModel>,
    /// The effort the session last confirmed, else the recorded one.
    #[serde(default)]
    pub effective_effort: Option<String>,
    #[serde(default)]
    pub pending: Option<PendingModel>,
    #[serde(default)]
    pub phase: SwitchPhase,
    pub running: bool,
    #[serde(default)]
    pub warnings: Vec<ModelWarning>,
    #[serde(default)]
    pub last_request: Option<LastModelRequest>,
    /// Bishop's budget posture when this state was built (`None`: unknown).
    #[serde(default)]
    pub posture: Option<String>,
}

/// A per-agent default model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentModelDefault {
    pub model: String,
    #[serde(default)]
    pub effort: Option<String>,
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
    /// Whether this session's `nostromo-mcp-bridge` is connected to the
    /// daemon's MCP socket. Absent when unknown (no bridge has ever
    /// identified as this tag). Additive: older peers ignore it.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub mcp_bridge_connected: Option<bool>,
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
    /// User-facing label for the focus (e.g. a Jira key or doc title), when the
    /// creator supplied one.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub label: Option<String>,
    /// Absolute working directory the focus was created in, so clients can
    /// group it under its repo.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub project_path: Option<String>,
    /// `client_id` whose windows should select this focus when it appears.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub select_for_client: Option<String>,
    /// The model chosen when the focus was created (family alias or full
    /// name). Read by the daemon only when it creates the focus's model
    /// record; absent everywhere else.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub initial_model: Option<String>,
    /// The effort chosen when the focus was created (`None`: the default).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub initial_effort: Option<String>,
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
    /// A region that hosts several panes with exactly one frontmost (W1 —
    /// curated-agent-views). Every tab is a real pane with a real `pane_id`;
    /// content still arrives via the ordinary `ServerMsg::PaneContent`
    /// broadcast for that pane id. `labels` is parallel to `children`,
    /// mirroring `Split`'s `children`/`ratios` shape rather than introducing
    /// a wrapper struct the rest of the tree doesn't use. `active` is the
    /// daemon's authoritative frontmost index; `FocusLayout.focused_pane`, when
    /// it names a child of this node, overrides it for "bring to front now."
    Tabs {
        /// Ordered tabs, left to right. In v1 every child is a `Leaf`.
        children: Vec<PaneTree>,
        /// Per-tab display labels, parallel to `children`.
        labels: Vec<String>,
        /// Index into `children` of the frontmost tab.
        active: usize,
        /// The placement-engine region this node *is* (W5 —
        /// curated-agent-views). `views.yaml` names regions rather than pane
        /// ids, so the engine needs a way to find "the detail region" in a
        /// tree whose tab membership it is itself about to change; a name on
        /// the node is that way, and it survives a daemon restart because the
        /// tree is persisted.
        ///
        /// `None` — the default, and every tabs node written before W5 — means
        /// "not a curated region": the placement engine ignores it entirely
        /// and an agent's hand-built `apply_layout` tabs node keeps behaving
        /// exactly as it does today. Skipped when absent, so the wire and the
        /// on-disk store stay byte-identical for those.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        region: Option<String>,
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
            PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
                for c in children {
                    c.collect_pane_ids(out);
                }
            }
        }
    }

    /// Close the tab `pane_id`: remove it from the tabs node that holds it.
    /// Returns `false` — and changes nothing — when `pane_id` is not a tab (a
    /// plain leaf such as `repl`, or an unknown id), or when it is the ONLY tab
    /// of a tabs node that is the whole tree (there would be nothing left to
    /// show).
    ///
    /// Keeps the node valid: `labels` stay parallel to `children`; `active`
    /// keeps pointing at the same tab when a tab before it closes, moves to the
    /// tab that slides into place (the next one, else the previous) when the
    /// ACTIVE tab closes, and is untouched when a later tab closes. Closing a
    /// tabs node's last tab removes the whole node, and a split left with one
    /// child collapses into it (the registry's `children.len() >= 2` invariant),
    /// with the remaining ratios renormalised.
    pub fn remove_tab(&mut self, pane_id: &str) -> bool {
        matches!(self.remove_tab_inner(pane_id), TabRemoval::Removed)
    }

    fn remove_tab_inner(&mut self, pane_id: &str) -> TabRemoval {
        match self {
            PaneTree::Tabs {
                children,
                labels,
                active,
                ..
            } => {
                let Some(index) = children
                    .iter()
                    .position(|c| matches!(c, PaneTree::Leaf { pane_id: p } if p == pane_id))
                else {
                    return TabRemoval::NotFound;
                };
                if children.len() == 1 {
                    return TabRemoval::NodeEmptied;
                }
                children.remove(index);
                if index < labels.len() {
                    labels.remove(index);
                }
                if index < *active {
                    *active -= 1;
                } else if index == *active {
                    *active = (*active).min(children.len() - 1);
                }
                TabRemoval::Removed
            }
            PaneTree::Split {
                children, ratios, ..
            } => {
                for i in 0..children.len() {
                    match children[i].remove_tab_inner(pane_id) {
                        TabRemoval::NotFound => continue,
                        TabRemoval::Removed => return TabRemoval::Removed,
                        TabRemoval::NodeEmptied => {
                            children.remove(i);
                            if i < ratios.len() {
                                ratios.remove(i);
                            }
                            let sum: f32 = ratios.iter().sum();
                            if sum > 0.0 {
                                ratios.iter_mut().for_each(|r| *r /= sum);
                            }
                            if children.len() == 1 {
                                let only = children.remove(0);
                                *self = only;
                            }
                            return TabRemoval::Removed;
                        }
                    }
                }
                TabRemoval::NotFound
            }
            PaneTree::Leaf { .. } => TabRemoval::NotFound,
        }
    }
}

/// What [`PaneTree::remove_tab_inner`] found.
enum TabRemoval {
    NotFound,
    Removed,
    /// The pane was the last tab of its tabs node: the parent removes the node.
    NodeEmptied,
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
    /// Transient loading state — agent signals "I'm refreshing this pane"
    /// before a slow fetch. The client shows a subtle spinner/indicator.
    Loading,
    /// The agent encountered an error fetching this pane's data.
    Error { message: String },
    /// A terminal pane (pane id `terminal-<8 hex>`): a placeholder for clients
    /// that cannot attach (iOS). Never carries terminal bytes. `environment`
    /// (a remote shell's) is omitted for a local terminal.
    Terminal {
        terminal_id: String,
        label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        environment: Option<String>,
    },
    /// A file's contents at a revision, line-addressable (W2 —
    /// curated-agent-views).
    ///
    /// Carries the text *plus* the line number the first line represents,
    /// rather than an array of per-line objects: the client splits and numbers,
    /// which keeps a whole-file payload the same size as the `Text` variant it
    /// replaces. A `Diff` (below) genuinely needs structure because a line
    /// number has to resolve to a row across hunk boundaries; a file does not.
    Code {
        /// Repo-relative path, exactly as requested.
        path: String,
        /// The revision this content was read at: a git SHA/ref, or
        /// `"working"` for the on-disk working tree.
        revision: String,
        /// The line number `text`'s first line represents. `1` for a whole
        /// file; a future windowed read can start higher without the client
        /// needing to know why.
        first_line: u32,
        /// The file contents. Line separator is `\n`.
        text: String,
    },
    /// A PR's change, structured per file/hunk/line so a line number can
    /// resolve to exactly one row (W2 — curated-agent-views).
    Diff {
        /// Repository in `owner/name` form.
        repo: String,
        /// PR number, when this diff belongs to one.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        number: Option<u64>,
        /// Per-file structure. Empty when `too_large` is set.
        files: Vec<DiffFile>,
        /// True when the underlying fetch hit its own large-diff gate and
        /// blanked the raw diff. `files` is then empty and the client must say
        /// so explicitly rather than render an apparently-complete empty diff
        /// (D4 — a stated limit is not silent truncation).
        #[serde(default)]
        too_large: bool,
        /// How many files the PR changes. The only thing a `too_large` diff
        /// can still say about its own size, which is why it is carried
        /// separately from `files.len()`.
        #[serde(default)]
        changed_files: u64,
    },
    /// A PR's description and comment/review threads, rendered as markdown
    /// blocks (W3 — curated-agent-views). `body`/each comment's `body` are
    /// already converted to [`MdBlock`] server-side (B5) — the client never
    /// parses markdown.
    PrConversation {
        /// Repository in `owner/name` form.
        repo: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        number: Option<u64>,
        title: String,
        author: String,
        url: String,
        /// The PR description, parsed.
        body: Vec<MdBlock>,
        threads: Vec<ConversationThread>,
        /// Set when the PR fetch itself succeeded but fetching the
        /// conversation (issue comments / review comments / reviews) failed —
        /// `threads` then carries whatever was retrieved before the failure,
        /// never presented as if it were the complete conversation.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        conversation_error: Option<String>,
    },
    /// An issue-tracker ticket (W4 — curated-agent-views). `provider` is a
    /// request field, not a view type — the same view serves any provider
    /// registered with `crate::data::tickets::TicketRegistry`; v1 registers
    /// only `jira`. `sections`/comment `blocks` are already converted to
    /// [`MdBlock`] server-side, same as `PrConversation`.
    Ticket {
        provider: String,
        key: String,
        summary: String,
        status: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        assignee: Option<String>,
        url: String,
        /// Blocks before the ticket's first heading form a `"description"`
        /// section; each subsequent heading starts a new, alias-resolved
        /// section (see `crate::data::tickets::derive_sections`).
        sections: Vec<TicketSection>,
        /// Chronological, 1-indexed — each addressable as `Anchor::Section {
        /// name: "comment:<index>" }`.
        comments: Vec<TicketComment>,
    },
    /// A daemon-rendered document (Huey's report, context and setup panes): a
    /// title that always carries its date, an optional banner, markdown blocks
    /// built server-side, and the actions the reader may take. An action is a
    /// button here, or an inline link with the scheme `nostromo-action:<id>`;
    /// either one is sent back as `ClientMsg::PaneAction`. A client opens only
    /// `https:` links and `nostromo-action:` links and ignores the rest.
    ///
    /// Additive: `PROTOCOL_VERSION` stays 4, and an older client decodes the
    /// new `kind` as `unknown`.
    Document {
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        banner: Option<DocBanner>,
        blocks: Vec<MdBlock>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        actions: Vec<DocAction>,
    },
}

/// How loudly a [`DocBanner`] speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DocBannerLevel {
    Info,
    Warning,
}

/// A line above a document's body (for example why today's report is missing).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocBanner {
    pub level: DocBannerLevel,
    pub text: String,
}

/// One button of a `Document`. `id` comes back in `ClientMsg::PaneAction`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocAction {
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub primary: bool,
}

// ── ticket sections/comments (W4 — curated-agent-views) ──────────────────────

/// One section of a `ticket` view's description. Mirrors
/// `crate::data::tickets::TicketSection`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TicketSection {
    /// Canonical, alias-resolved name (e.g. `"description"`,
    /// `"acceptance_criteria"`) — addressable via `Anchor::Section` /
    /// `Emphasis::Section`.
    pub name: String,
    /// The heading's own rendered spans. `None` for the leading
    /// `"description"` section, which has no heading of its own.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub heading: Option<Vec<MdSpan>>,
    pub blocks: Vec<MdBlock>,
}

/// One comment on a ticket. Mirrors `crate::data::tickets::TicketComment`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TicketComment {
    /// 1-based; addressable as `Anchor::Section { name: "comment:<index>" }`.
    pub index: u32,
    pub author: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub blocks: Vec<MdBlock>,
}

// ── markdown block model (W3 — curated-agent-views, bet B5) ─────────────────

/// A block-level markdown element, produced server-side from raw markdown via
/// [`crate::markdown_blocks::markdown_to_blocks`] — the daemon owns CommonMark
/// parsing so no client writes its own parser. Shared by `pr_conversation`
/// (this wedge) and `ticket` (W4).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MdBlock {
    Paragraph {
        spans: Vec<MdSpan>,
    },
    Heading {
        level: u8,
        spans: Vec<MdSpan>,
    },
    /// A fenced or indented code block. `lang` is the fence's info-string
    /// language token (`None` for an unlabelled fence or an indented block).
    /// `text` is the block's content, byte-for-byte apart from the fence
    /// lines themselves.
    CodeBlock {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        lang: Option<String>,
        text: String,
    },
    List {
        ordered: bool,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        start: Option<u64>,
        items: Vec<Vec<MdBlock>>,
    },
    Quote {
        blocks: Vec<MdBlock>,
    },
    Table {
        header: Vec<Vec<MdSpan>>,
        rows: Vec<Vec<Vec<MdSpan>>>,
    },
    Rule,
}

/// Inline markdown content within an [`MdBlock`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MdSpan {
    Text { text: String },
    Code { text: String },
    Emph { spans: Vec<MdSpan> },
    Strong { spans: Vec<MdSpan> },
    Strike { spans: Vec<MdSpan> },
    Link { spans: Vec<MdSpan>, url: String },
    Image { alt: String, url: String },
}

// ── PR conversation threads (W3 — curated-agent-views) ───────────────────────

/// What kind of GitHub thread a [`ConversationThread`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationThreadKind {
    /// A top-level issue comment on the PR's "Conversation" tab.
    Issue,
    /// A whole-PR review (approve/request-changes/comment) with a body.
    Review,
    /// An inline review comment thread anchored to a file/line.
    Inline,
}

/// One comment within a [`ConversationThread`], already markdown-parsed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationComment {
    pub id: String,
    pub author: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub body: Vec<MdBlock>,
}

/// One comment thread within a `pr_conversation` view — a single issue
/// comment, a whole-PR review, or an inline review-comment thread assembled
/// by walking `in_reply_to_id` to its root.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationThread {
    pub id: String,
    pub kind: ConversationThreadKind,
    /// Inline threads only.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub path: Option<String>,
    /// Inline threads only, new-side line number.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub diff_hunk: Option<String>,
    #[serde(default)]
    pub resolved: bool,
    /// Chronological.
    pub comments: Vec<ConversationComment>,
}

// ── structured unified diff (W2 — curated-agent-views) ───────────────────────

/// What happened to a file in a diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiffStatus {
    /// The file did not exist before.
    Added,
    /// The file does not exist after.
    Removed,
    /// The file existed before and after.
    Modified,
    /// The file moved; `DiffFile::old_path` carries where from.
    Renamed,
}

/// What one line of a hunk is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiffLineKind {
    /// Unchanged — present on both sides.
    Context,
    /// Present only on the new side.
    Added,
    /// Present only on the old side.
    Removed,
    /// Not a content line at all — e.g. `\ No newline at end of file`.
    /// Carried rather than dropped so the parser never loses a line.
    Meta,
}

/// One line within a [`DiffHunk`].
///
/// `old_n`/`new_n` are the line's number on each side, absent where the line
/// doesn't exist on that side. They are what makes a diff line-addressable:
/// `Anchor::Line { path, line }` resolves against `new_n` first, falling back
/// to the removal row carrying that `old_n`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub old_n: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub new_n: Option<u32>,
    /// The line's content with the diff marker character stripped. A `Meta`
    /// line carries its raw text (marker included) because the marker *is* the
    /// content there.
    pub text: String,
}

/// One `@@ ... @@` hunk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffHunk {
    /// The verbatim `@@ -a,b +c,d @@ optional function context` line, so a
    /// client can render exactly what git said without reconstructing it.
    pub header: String,
    /// First line number this hunk covers on the old side.
    pub old_start: u32,
    /// First line number this hunk covers on the new side.
    pub new_start: u32,
    pub lines: Vec<DiffLine>,
}

/// One file's change within a diff.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffFile {
    /// The file's path on the new side (or, for a removal, the only path it
    /// has).
    pub path: String,
    /// Where a renamed file came from.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub old_path: Option<String>,
    pub status: DiffStatus,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<DiffHunk>,
}

/// How trustworthy the data in a `PaneContent` push is. Computed daemon-side
/// (see `apply_layout::freshness`) so every client agrees without
/// reimplementing the policy: `stale` is the source's own transient flag and
/// must NOT be rendered (a single missed poll is normal); `badly_stale` is the
/// daemon's verdict that the source hasn't produced good data within
/// `pane_sources::BADLY_STALE_AFTER`, and is the only flag a client renders.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct PaneFreshness {
    /// When the underlying source last produced good data.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub as_of: Option<chrono::DateTime<chrono::Utc>>,
    /// The source's own transient-stale flag. Not rendered by clients.
    #[serde(default)]
    pub stale: bool,
    /// The daemon's badly-stale verdict. The only flag a client renders.
    #[serde(default)]
    pub badly_stale: bool,
}

// ── pane addressing (W1 — curated-agent-views) ──────────────────────────────

/// A point of interest inside a pane's content — the thing a `show` (future
/// wedges) or an agent-authored push wants to draw the operator's eye to.
///
/// `Anchor` is "the one place to land" (e.g. scroll-to); `Emphasis` (below) is
/// "the range(s) to highlight" — a pane can have zero or more of the latter
/// alongside at most one of the former.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Anchor {
    /// A single line, optionally scoped to one file within a multi-file view
    /// (e.g. `pr_diff`). `path: None` means "the pane's one file."
    Line {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        path: Option<String>,
        line: u32,
    },
    /// A specific PR-review comment thread.
    Comment { id: String },
    /// A named section within the pane (e.g. a heading in a rendered doc).
    Section { name: String },
    /// A row in a queue-shaped pane (e.g. `pr_list`), identified the same way
    /// a PR is identified elsewhere on the wire.
    QueueRow { repo: String, number: u64 },
}

/// A range to highlight within a pane's content. See [`Anchor`] for the
/// single-point counterpart.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Emphasis {
    /// A contiguous line range, optionally scoped to one file.
    LineRange {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        path: Option<String>,
        start: u32,
        end: u32,
    },
    /// A specific PR-review comment thread.
    Comment { id: String },
    /// A named section within the pane.
    Section { name: String },
    /// A raw character offset range within plain-text content.
    TextRange { start: usize, end: usize },
    /// A row in a queue-shaped pane.
    QueueRow { repo: String, number: u64 },
}

/// Where to look inside a pane's content, and why. Optional and additive —
/// carried as a sibling of [`PaneFreshness`] on `ServerMsg::PaneContent`
/// rather than folded into [`PaneContentWire`], so it can be re-sent cheaply
/// (e.g. "re-anchor this same content") without re-sending the content itself.
///
/// `None` on the wire means "no addressing concept for this pane" — every
/// push before this field existed, and every push from a caller with nothing
/// to point at. W1 renders only `reason` (as a tab caption); rendering
/// `anchor`/`emphasis` is deliberately deferred to later wedges.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct PaneAddress {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub anchor: Option<Anchor>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub emphasis: Vec<Emphasis>,
    /// One short human-readable phrase explaining why this was shown.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub reason: Option<String>,
}

// ── ambient activity (activity-path wedge) ───────────────────────────────────

/// Wire projection of one `activity::store::ActivityStream` — a focus's main
/// stream (`agent_id: None`) or one subagent's stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityStreamWire {
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub parent_agent_id: Option<String>,
    pub events: Vec<ActivityEvent>,
    /// `true` once this stream has received a `subagent_stop` event (always
    /// `false` for the main stream).
    pub finished: bool,
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

// ── Claude sign-in (CL1) ────────────────────────────────────────────────────────

/// The optional capability advertised in `Welcome.features`: this daemon holds a
/// message whose turn failed because Claude could not authenticate, broadcasts
/// `claude_login_state` and takes `claude_login_action`.
pub const FEATURE_LOGIN: &str = "claude_login_v1";

/// What a session waiting for a Claude sign-in is doing (`ClaudeLoginSession`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeLoginPhase {
    /// The failed message is held, and goes out again once the login changes.
    Waiting,
    /// The held message was written again and its turn has not ended.
    Resending,
    /// The failed turn had already done real work (or was not started by a
    /// message the daemon wrote): the message is held but only a human resends it.
    NotResendable,
    /// Paused, but there is no message to send again.
    PausedNoHold,
}

/// Whether the daemon can see the Claude credential change (`ClaudeLoginState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeLoginWatch {
    Keychain,
    Unavailable,
}

/// One session waiting for a Claude sign-in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClaudeLoginSession {
    pub tag: String,
    /// The hold a `ClaudeLoginAction` names; `None` when nothing is held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold_id: Option<String>,
    pub phase: ClaudeLoginPhase,
    /// Messages sent to the session since, kept in order behind the held one.
    pub queued: u32,
    /// When the turn failed (RFC 3339, UTC, whole seconds).
    pub failed_at: String,
    /// How many more times the daemon may send the message again by itself.
    pub auto_resends_left: u8,
}

/// What a `ClaudeLoginAction` asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeLoginActionKind {
    Retry,
    Discard,
}

/// Messages sent from a TUI client to the daemon.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMsg {
    Hello {
        client_id: String,
        protocol_version: u32,
        /// What the client says it is. The Mac app sends `"mac_app"`; together
        /// with the verified bundle of the connecting process (see
        /// [`crate::ipc::peer_verify::classify_peer`]) that makes the connection
        /// the operator app. A claim alone grants nothing. Absent from older
        /// clients, which connect as ordinary local peers.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client_kind: Option<String>,
    },
    Subscribe {
        #[serde(deserialize_with = "lenient_topics")]
        topics: Vec<Topic>,
        /// Declares that this client can actually present a decision-modal
        /// request to a human and answer it — the fact `nostromo.ask_decision`
        /// needs before it will submit a request rather than fail fast with
        /// `no_operator`. Naming `Topic::Decision` in `topics` makes the same
        /// claim; either is sufficient (see the `Decision` variant's doc
        /// comment above). `#[serde(default)]` so a client that predates this
        /// field (or simply omits it) decodes as `false` — never silently
        /// promoted to an operator by an absent key.
        #[serde(default)]
        renders_decisions: bool,
        /// Declares that this client renders permission-approval requests
        /// (`ApprovalRequest`) and can answer them. Counts only from the
        /// verified Mac app: it makes the connection an approval presenter,
        /// the fact the daemon needs before it holds a request for a human
        /// instead of denying it. `#[serde(default)]`: a client that predates
        /// the field decodes as `false` and is never a presenter.
        #[serde(default)]
        renders_approvals: bool,
        /// Optional client capabilities (`terminal_ui`, later
        /// `remote_shell_confirm`, `terminal_follow_ui`). Recorded only for
        /// the verified Mac app; a capability grants nothing by itself.
        /// `#[serde(default)]`: an older client sends none.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        capabilities: Vec<String>,
        /// The `operator_nonce` from this connection's `Welcome`. A verified
        /// app's terminal verbs are honoured only after a `Subscribe` that
        /// echoes it (and a fresh look at the peer): bytes a process wrote
        /// before `exec`ing the genuine app cannot contain it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
    },
    Ping,

    // ── Retired PTY commands (R2) ─────────────────────────────────────────────
    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: spawn a new PTY in the daemon.
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

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: send raw bytes to a PTY's stdin.
    PtyInput {
        pty_id: String,
        #[serde(with = "base64_bytes")]
        bytes: Vec<u8>,
    },

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: resize a PTY.
    PtyResize {
        pty_id: String,
        cols: u16,
        rows: u16,
    },

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: kill a PTY and its child process.
    PtyKill {
        pty_id: String,
    },

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: attach to an existing PTY.
    PtyAttach {
        pty_id: String,
    },

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: stop receiving output from a PTY without killing it.
    PtyDetach {
        pty_id: String,
    },

    /// Retired (R2, 2026-10): decoded and answered with `pty_host_removed`; kept so FND-1 ordinals stay stable.
    /// Formerly: request a snapshot of all live PTYs owned by this daemon.
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

    /// Close the tab `pane_id` in focus `tag` (the tab's × button). Refused for
    /// the review queue and the REPL, which are never closable; see
    /// `PaneRegistry::close_tab`.
    ClosePane {
        tag: String,
        pane_id: String,
    },

    /// Interrupt the turn the session is running right now (the Stop button),
    /// leaving the session itself alive and ready for the next message. Distinct
    /// from [`ClientMsg::SessionControl`]'s `Stop`, which kills the session. A
    /// no-op when the session is idle. Also drops any messages queued behind
    /// the running turn: Stop means stop, not "stop and immediately start the
    /// next thing".
    SessionInterrupt {
        tag: String,
    },

    /// Lifecycle control (stop / restart / new_session).
    SessionControl {
        tag: String,
        action: SessionAction,
    },

    /// Superseded by `ApprovalAnswer`: every peer is refused with an `Error`
    /// and nothing happens.
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
        /// The focus whose PR under review `load_pr`/`clear` moves (W7).
        ///
        /// The PR under review is a property of the focus, so an affordance in
        /// focus X must move X's pin and nobody else's. Optional and defaulted
        /// so a client built before W7 still round-trips: it addresses the
        /// built-in `perri` focus, which is where its one PR surface lived.
        #[serde(default)]
        tag: Option<String>,
    },

    /// Answer a `ServerMsg::DecisionRequest` (W6 decision modals).
    ///
    /// `choice_id: None` means dismissed without choosing — a distinct,
    /// meaningful outcome, not a default choice — so unlike most optional
    /// fields in this protocol, this one is **not** `skip_serializing_if`:
    /// it is always present on the wire, as a string or as `null`.
    ///
    /// `operator_nonce` echoes the nonce this connection's `Welcome` carried.
    /// The daemon applies an answer only when it matches (AP1b): bytes a
    /// process wrote before the daemon verified it cannot contain it. Additive:
    /// absent from the wire when `None`.
    DecisionAnswer {
        request_id: String,
        #[serde(default)]
        choice_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
    },

    /// The human's answer to a held permission request (`ApprovalRequest`).
    /// Applied only from the verified Mac app: it must echo the connection's
    /// `operator_nonce` and pass the same answer-time peer re-check as a
    /// `DecisionAnswer`. First answer wins; a later one is refused with
    /// `ApprovalAnswerRefused`. Refused for network peers.
    ApprovalAnswer {
        request_id: String,
        decision: crate::approvals::wire::ApprovalDecision,
        /// The Mac window the human answered in (shown in the log).
        window_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
    },

    /// The Mac app reports an input it refused to treat as a human's: a
    /// synthetic click or key aimed at an Allow control. Written to the audit
    /// log; accepted only from the verified app. Refused for network peers.
    ApprovalRefusalReport {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        /// Which control it was aimed at (`allow_once`, …).
        control: String,
        channel: crate::approvals::wire::RefusalChannel,
    },

    /// The human's answer to a held message of a session waiting for a Claude
    /// sign-in (`ClaudeLoginState`): send it again now (`retry`) or drop it
    /// (`discard`). Applied only from the verified Mac app: it must echo the
    /// connection's `operator_nonce` and pass the same answer-time peer re-check
    /// as a `DecisionAnswer`. `hold_id` names the hold the human saw; one that
    /// is no longer current changes nothing. It is absent for a session that is
    /// paused with nothing held (`paused_no_hold`). Refused for network peers.
    ClaudeLoginAction {
        action: ClaudeLoginActionKind,
        tag: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hold_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
    },

    /// The reader acted on a `Document` pane (a button, or a `nostromo-action:`
    /// link): `action_id` is the id the document carried. Applied only from the
    /// verified Mac app, which must echo the connection's `operator_nonce`
    /// (the same check as `ClaudeLoginAction`); anyone else is refused with no
    /// content and nothing changes. Answered with `ServerMsg::PaneActionResult`.
    /// Refused for network peers.
    PaneAction {
        tag: String,
        pane_id: String,
        action_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
    },

    /// Request a full ambient-activity snapshot (all streams) for one focus.
    /// The daemon replies with `ServerMsg::ActivitySnapshot`.
    ActivitySnapshotRequest {
        tag: String,
    },

    /// A client's report of which pane ids one of its windows has actually
    /// materialised for a focus (W1 — render-state-visibility).
    ///
    /// This is the missing half of the daemon's pane-state picture: the
    /// daemon's `PaneRegistry` only ever knows the tree it was told to build
    /// (structure), never what any window actually painted. This message is
    /// how a client (the macOS app) reports that half back, so
    /// `nostromo.get_render_state` / `nostromo.get_view_state`'s
    /// `render_state` section can answer "did what I asked for actually
    /// render" without a human reading a screenshot.
    ///
    /// Sent once per window at the end of `DynamicFocusView.reconcile` —
    /// `pane_ids` is read straight from that view's `renderedTree` (never a
    /// separately recomputed value, so it can't drift from what the
    /// `panes`-category log already reports).
    RenderedShape {
        /// Focus tag this report is about.
        tag: String,
        /// Stable per-window identifier (macOS: the window's screen index,
        /// stable across a `FocusLayout` replay and a reconnect, but not
        /// persisted — a relaunch is free to renumber).
        window_id: String,
        /// Pane ids the reporting window's view hierarchy holds for `tag`.
        pane_ids: Vec<String>,
        /// The client's own wall-clock timestamp when this shape was
        /// reconciled — the basis for the `age_ms` a caller sees back, since
        /// the daemon has no other way to know how stale a report is.
        rendered_at: chrono::DateTime<chrono::Utc>,
    },

    // ── Teri/Fred work views (refused over TCP) ──────────────────────────────
    /// Fetch the detail for one work item (`todo:`/`doc:`/`jira:`/`sentry:`) or
    /// Fred mail/event (`mail:`/`event:`). Answered with `ServerMsg::WorkDetail`.
    WorkDetailRequest {
        request_id: String,
        item_id: String,
    },
    /// Manual refresh (⌘R). `source: None` refreshes every source.
    WorkRefresh {
        #[serde(default)]
        source: Option<crate::data::work::WorkSource>,
        #[serde(default)]
        fred: bool,
    },
    /// Ask the daemon to (re)generate Teri's picks. `reason`: `"first_open"` | `"manual"`.
    PicksRefresh {
        reason: String,
    },
    /// Preview the "send to agent" defaults for an item. Answered with
    /// `ServerMsg::WorkSendPreview`.
    WorkSendPreviewRequest {
        request_id: String,
        item_id: String,
    },
    /// Send a work item to an agent focus or a Mother job. Answered with
    /// `ServerMsg::WorkSendResult`.
    WorkSend {
        request_id: String,
        item_id: String,
        /// `"focus"` or `"mother_job"`.
        destination: String,
        agent: String,
        #[serde(default)]
        working_directory: Option<String>,
        label: String,
        /// The user's own words from the sheet: sent to the agent as the
        /// user's directive, outside the untrusted-data fence. The work
        /// item's text is never part of this request: the daemon rebuilds it
        /// from the hub item by `item_id` at send time. An old client's
        /// `context` field is ignored.
        #[serde(default)]
        instruction: String,
        #[serde(default)]
        allow_duplicate: bool,
    },
    /// Send a confirmed prompt into Fred's own session (tag `fred`). Answered
    /// with `ServerMsg::WorkSendResult`.
    FredSeed {
        request_id: String,
        text: String,
    },

    // ── model switching ───────────────────────────────────────────────────────
    /// Ask for the model catalogue. Answered with `ServerMsg::ModelCatalog`.
    ModelCatalogRequest {},
    /// Re-probe the installed CLI for its models (refused over TCP). The
    /// result is broadcast as `ServerMsg::ModelCatalog`.
    ModelCatalogRefresh {},
    /// Read one focus's model. Answered with `ServerMsg::SessionModelState`.
    SessionModelGet {
        tag: String,
    },
    /// Switch a focus's model and/or effort (refused over TCP). `None` keeps
    /// the current value. Answered with `ServerMsg::ModelRequestResult`.
    SessionModelSet {
        tag: String,
        #[serde(default)]
        model: Option<String>,
        #[serde(default)]
        effort: Option<EffortChoice>,
        /// Also make this the default for new focuses of the focus's agent.
        #[serde(default)]
        set_as_agent_default: bool,
        request_id: String,
        /// Who is asking: `"script"` for the app-control client, otherwise
        /// the user. Honoured from Unix peers only.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        actor: Option<String>,
    },
    /// Read the per-agent defaults. Answered with `ServerMsg::ModelDefaults`.
    ModelDefaultsRequest {},
    /// Set (or, with `clear`, remove) an agent's default model (refused over
    /// TCP). Answered with `ServerMsg::ModelRequestResult`.
    ModelDefaultSet {
        agent: String,
        #[serde(default)]
        model: Option<String>,
        #[serde(default)]
        effort: Option<EffortChoice>,
        #[serde(default)]
        clear: bool,
        request_id: String,
    },
    /// Stop a background task (refused over TCP). Answered with
    /// `ServerMsg::SessionTaskStopResult` to the asking client.
    SessionTaskStop {
        request_id: String,
        tag: String,
        task_id: String,
    },
    /// Read a shell or monitor task's output (refused over TCP). `offset` is a
    /// raw byte offset into the output (`None`: the tail); `max_bytes` is
    /// clamped to `TASK_OUTPUT_MAX_BYTES`. Answered with
    /// `ServerMsg::SessionTaskOutputResult` to the asking client.
    SessionTaskOutput {
        request_id: String,
        tag: String,
        task_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        offset: Option<u64>,
        max_bytes: u32,
    },

    // ── terminal panes (1a; every one refused over TCP) ───────────────────────
    /// Open a local login shell in a new terminal leaf of `tag`'s pane tree
    /// (default: below `repl`). Operator app only.
    TerminalOpenLocal {
        tag: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        relative_to: Option<String>,
        /// `split_left` / `split_right` / `split_above` / `split_below`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        position: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        /// Echoed back as `TerminalInfo.opened_by_request`.
        client_request_id: String,
    },
    /// Start receiving a terminal's bytes: a `TerminalReplay`, then
    /// `TerminalOutput`. Operator app only.
    TerminalAttach {
        terminal_id: String,
    },
    /// Stop receiving a terminal's bytes (this connection only).
    TerminalDetach {
        terminal_id: String,
    },
    /// Keystrokes for a terminal, base64. Operator app only.
    ///
    /// `auto_reply: true` marks bytes the terminal emulator sent by itself
    /// (a cursor-position or device-attributes reply, a focus report), not a
    /// person's typing or paste. They are written to the shell but never count
    /// as activity for the idle rule, so a remote program that provokes them
    /// cannot keep a production shell open. Additive: an older daemon ignores
    /// the field and counts such input as a keystroke, so the 2e idle rule
    /// needs a daemon that knows it.
    TerminalInput {
        terminal_id: String,
        bytes: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        auto_reply: bool,
        /// Where a person's input came from, when not the keyboard: only
        /// `stage_insert` (a staged command placed at the prompt by a click)
        /// is known, and it counts as activity for the idle rule. Anything
        /// else counts as a keystroke. Additive.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        via: Option<String>,
    },
    /// Operator app only.
    TerminalResize {
        terminal_id: String,
        cols: u16,
        rows: u16,
    },
    /// Kill the process and remove the leaf. Operator app only.
    TerminalClose {
        terminal_id: String,
    },
    /// A fresh shell in an `ended` local terminal's pane, with a new
    /// `terminal_id`. Operator app only.
    TerminalRestart {
        terminal_id: String,
    },
    /// Keep an idle remote shell open: resets its idle timer and clears a
    /// pending idle warning. Operator app only.
    TerminalKeepAlive {
        terminal_id: String,
    },
    /// Ask which remote (`ecs`) shells are open: labels, targets and ages
    /// only. Answered with a targeted `TerminalRemoteSummary`. Any local peer
    /// may ask (the controlled-restart guard does); it carries no output and
    /// changes nothing.
    TerminalRemoteSummaryRequest,
    /// The app refused a synthetic/agent attempt on a terminal (for example
    /// through app-control); the daemon audits it. Operator app only.
    TerminalRefusalReport {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        terminal_id: Option<String>,
        op: String,
        channel: String,
    },

    // ── remote shells (2a; every one refused over TCP) ────────────────────────
    /// Ask for the remote-shell vocabulary (projects, environments, services,
    /// shell types). Answered with a targeted `RemoteShellTargets`. Any local
    /// peer may ask; it carries no profile, cluster or account.
    RemoteShellTargetsRequest,
    /// The user asks for a remote shell: the daemon runs the same confirm
    /// flow an agent's request does, with `requested_by: {kind: "user"}`.
    /// Operator app only.
    RemoteShellOpen {
        /// The focus the pane goes in.
        tag: String,
        project: String,
        environment: String,
        service: String,
        shell_type: String,
    },
    /// The user's answer to a `RemoteShellConfirmRequest`: `decision` is
    /// `connect`, `cancel` or `dismiss`. Operator app only.
    RemoteShellAnswer {
        request_id: String,
        decision: String,
        /// The follow box on the confirm sheet: on Connect, an agent's request
        /// has that agent follow the shell once it runs. Ignored for a shell the
        /// user opened themselves and for any decision but `connect`.
        #[serde(default)]
        invite_follow: bool,
    },

    // ── agent follow (3b; every one refused over TCP) ─────────────────────────
    /// Invite the focus `follower_tag` to follow a terminal: output produced
    /// from now on is delivered into its conversation. Moves the invitation
    /// if another focus follows. `include_screen` also delivers what is on
    /// the screen now. Operator app with `terminal_follow_ui` only.
    TerminalFollowInvite {
        terminal_id: String,
        follower_tag: String,
        #[serde(default)]
        include_screen: bool,
    },
    /// Stop following at once; output not yet delivered is discarded.
    /// Operator app only.
    TerminalFollowStop {
        terminal_id: String,
    },
    /// Resume a following that paused itself (too much output). Operator
    /// app only.
    TerminalFollowResume {
        terminal_id: String,
    },

    // ── send selection (3d; refused over TCP) ─────────────────────────────────
    /// Send the text the user selected in a terminal to the focus
    /// `target_tag`, once: the daemon redacts and caps it and writes it into
    /// that focus's conversation as a `kind="selection"` terminal-output
    /// element. It never starts following and works on any terminal.
    /// Operator app only.
    TerminalSendSelection {
        terminal_id: String,
        target_tag: String,
        text: String,
    },

    // ── command staging (S1a; every one refused over TCP) ─────────────────────
    /// The app placed a staged entry's text at the prompt itself (through its
    /// own `terminal_input`) and reports it. Carries no text: the daemon never
    /// writes to the terminal because of it. Operator app only.
    TerminalStagingInserted {
        terminal_id: String,
        entry_id: String,
        /// How many bytes the app inserted.
        bytes: u32,
        /// The user confirmed a warning before inserting (S2; false in S1).
        #[serde(default)]
        confirmed: bool,
    },
    /// The user removed a staged entry. Operator app only.
    TerminalStagingRemove {
        terminal_id: String,
        entry_id: String,
        /// Set when the removal is an archive (the app keeps the entry in its
        /// own footer): `manual` or `auto`. Absent for a plain removal.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        archive: Option<StagingArchive>,
    },
    /// The user cleared the staging list. Operator app only.
    TerminalStagingClear {
        terminal_id: String,
    },
    /// The user turned staging on or off for one terminal. Operator app only.
    TerminalStagingSetEnabled {
        terminal_id: String,
        enabled: bool,
    },
    /// The user turned staging on or off for every terminal, as this
    /// connection sees it. Operator app only.
    TerminalStagingSetGlobal {
        enabled: bool,
    },
    /// Something the user did in the staging UI that is only counted
    /// (`confirm_cancelled`, `just_changed`). Operator app only.
    TerminalStagingUiEvent {
        terminal_id: String,
        event: String,
    },
    /// Change a Mother job notice switch: a focus's mode (`scope: focus`, with
    /// `tag` and `mode`) or the global one (`scope: global`, with `enabled`).
    /// Operator app only; refused for any other local peer and for a network
    /// peer. The new state is broadcast as `MotherNoticeState`.
    MotherNoticeSettingsSet {
        scope: crate::mother::notices::NoticeScope,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mode: Option<crate::mother::origin::NotifyLevel>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        enabled: Option<bool>,
    },
}

// ── background tasks ──────────────────────────────────────────────────────────

/// What a background task is, for the activity panel. Resolved by the daemon
/// from the CLI's `task_type` and the tool that started the task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskKind {
    /// A background `Bash` command.
    Shell,
    /// The Monitor tool, or an MCP/web-socket monitor.
    Monitor,
    Agent,
    Workflow,
    /// Anything else; `TaskMeta::task_type` keeps the CLI's raw label.
    Other,
}

impl TaskKind {
    /// The word for this kind of task in a sentence.
    pub fn label(self) -> &'static str {
        match self {
            TaskKind::Shell => "shell task",
            TaskKind::Monitor => "monitor",
            TaskKind::Agent => "agent task",
            TaskKind::Workflow => "workflow task",
            TaskKind::Other => "background task",
        }
    }

    /// Shell and Monitor tasks write an output stream the daemon can preview.
    pub fn has_output(self) -> bool {
        matches!(self, TaskKind::Shell | TaskKind::Monitor)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Running,
    Paused,
    Completed,
    Failed,
    Stopped,
}

impl TaskStatus {
    /// `true` once the task can no longer change state.
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            TaskStatus::Completed | TaskStatus::Failed | TaskStatus::Stopped
        )
    }
}

/// Why a task ended as `stopped`, when the CLI did not say so itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskEndReason {
    /// A Nostromo stop for this task was accepted, then the task ended stopped.
    UserStop,
    /// The CLI's notification said `worker_restart`.
    Restart,
    /// The CLI process ended while the task ran.
    SessionEnded,
    /// The task left the CLI's live background set and never reported an end.
    Vanished,
}

/// How a stop request ended (`ServerMsg::SessionTaskStopResult`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStopOutcome {
    /// The CLI took the stop. The task's status changes only when the CLI
    /// reports the task ended.
    Accepted,
    /// The CLI (or the daemon, over the network) said no; `message` says why.
    Refused,
    /// The CLI did not answer in time.
    Timeout,
    /// The CLI predates stopping tasks.
    Unsupported,
    /// The task is unknown or already ended: nothing was sent.
    NotRunning,
}

/// How an output read ended (`ServerMsg::SessionTaskOutputResult`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskOutputOutcome {
    Ok,
    /// The task has no readable output (no file, and the CLI has none either).
    Unavailable,
    Refused,
    /// The task is not one this session holds.
    Error,
}

/// Where a read's text came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskOutputSource {
    /// The task's output file: ranged, up to the whole output.
    File,
    /// The CLI's own `get_task_output`: at most the last 8 KiB.
    CliTail,
}

/// The largest read one `SessionTaskOutput` may ask for. A request for more
/// is clamped (the text's JSON form then stays far under `MAX_FRAME_LEN`).
pub const TASK_OUTPUT_MAX_BYTES: u32 = 1024 * 1024;

/// Metadata of one background task (`ServerMsg::SessionTasks`).
///
/// **A closed struct on purpose.** It travels in a frame a network peer may
/// receive for a non-sensitive focus, so it carries no output, preview,
/// summary, prompt or file path: that text lives in `SessionTaskDetail`, which
/// is `LocalOnly`. A new field must be classified in `peer.rs` (its key-set
/// test fails until the allow-list there is updated on purpose).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskMeta {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    /// The CLI's raw `task_type` (`local_bash`, `local_agent`, …), `""` if none.
    pub task_type: String,
    pub kind: TaskKind,
    /// The tool that started the task (`Bash`, `Monitor`, `Agent`, …), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_backgrounded: Option<bool>,
    /// Not activity: an ambient watcher or a `skip_transcript` task.
    pub housekeeping: bool,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_reason: Option<TaskEndReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_uses: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_tool_name: Option<String>,
    /// The daemon can show this task's output (shell and monitor tasks).
    pub has_output: bool,
}

/// One full snapshot of a session's background tasks (REPLACE semantics): the
/// payload of `ServerMsg::SessionTasks`, minus the tag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TasksSnapshot {
    /// The Claude session id the tasks belong to.
    pub session_id: Option<String>,
    /// Random id of this daemon process: tasks never survive a daemon restart.
    pub daemon_epoch: String,
    /// `None` until known.
    pub stop_supported: Option<bool>,
    pub tasks: Vec<TaskMeta>,
}

/// Output- or conversation-derived text of one task: the payload of
/// `ServerMsg::SessionTaskDetail`, minus the tag. `LocalOnly`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TaskDetailMsg {
    pub task_id: String,
    pub preview: Option<String>,
    pub progress_summary: Option<String>,
    pub completion_summary: Option<String>,
    pub prompt: Option<String>,
}

// ── terminal wire types ───────────────────────────────────────────────────────

/// Where a terminal's process runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalKind {
    Local,
    Ecs,
}

/// A terminal's lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalStatus {
    Connecting,
    Running,
    Ended,
}

/// The remote shell a terminal is connected to (`ecs` only; phase 2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalTarget {
    pub project: String,
    pub environment: String,
    pub service: String,
    pub shell_type: String,
}

/// Who asked for a terminal: `kind` is `user` (the operator app) or `focus`
/// (an agent, through 1b's facade), with the focus `tag` for the latter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalRequester {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
}

/// Who asked for a remote shell, as the confirm sheet shows it: `kind` is
/// `user` or `focus`; an agent's request names its focus `tag` and `agent`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteRequester {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

/// One project in `RemoteShellTargets`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteShellProject {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_service: Option<String>,
    pub environments: Vec<RemoteShellEnvironment>,
}

/// One environment of a project and the services it has.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteShellEnvironment {
    pub name: String,
    pub services: Vec<String>,
}

/// The focus following a terminal (`TerminalInfo.follower`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalFollower {
    pub tag: String,
    /// Following paused itself; one `terminal_follow_resume` restarts it.
    pub paused: bool,
    /// Why it paused: `too_much_output` or `too_many_deliveries`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pause_reason: Option<String>,
}

/// A terminal's metadata. Never its bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalInfo {
    pub terminal_id: String,
    pub tag: String,
    pub pane_id: String,
    pub kind: TerminalKind,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TerminalTarget>,
    pub status: TerminalStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Why an `ended` terminal ended, when not by its own exit
    /// (`daemon_stopped`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_reason: Option<String>,
    pub cols: u16,
    pub rows: u16,
    pub requested_by: TerminalRequester,
    /// The `client_request_id` of the `TerminalOpenLocal` that opened it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened_by_request: Option<String>,
    /// The focus following this terminal, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follower: Option<TerminalFollower>,
    /// A remote shell with no keystrokes for a while closes at this time;
    /// set from the idle warning until a keystroke or keep-alive.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_closes_at: Option<chrono::DateTime<chrono::Utc>>,
    /// How long without keystrokes (seconds) brought the idle warning; set
    /// together with `idle_closes_at`, so the app's banner names the real
    /// figure (a QA daemon scales it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_warn_after_secs: Option<u64>,
}

/// Why a staged entry was removed by `terminal_staging_remove`'s `archive`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StagingArchive {
    /// The user archived it.
    Manual,
    /// The app archived it after the user ran it (the opt-in setting).
    Auto,
}

/// The state of a staging list in `ServerMsg::TerminalStagingList`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalStagingState {
    /// Its follower can still stage, edit and clear.
    Active,
    /// The follow ended: kept for the user, no agent can change it.
    Frozen,
    /// No list: no drawer.
    #[serde(rename = "none")]
    NoList,
}

/// One staged command in `ServerMsg::TerminalStagingList`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StagedEntryWire {
    pub id: String,
    /// 1-based position, recomputed on every change.
    pub number: u32,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub staged_at: chrono::DateTime<chrono::Utc>,
    pub changed_at: chrono::DateTime<chrono::Utc>,
    pub inserted_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_inserted_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// One open remote shell in `ServerMsg::TerminalRemoteSummary`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteShellSummary {
    pub label: String,
    pub target: TerminalTarget,
    pub opened_at: chrono::DateTime<chrono::Utc>,
}

/// `ServerMsg::TerminalClosed`'s fields. `reason`: `exited`, `user_closed`,
/// `daemon_stopped`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalClosedInfo {
    pub terminal_id: String,
    pub tag: String,
    pub pane_id: String,
    pub label: String,
    pub kind: TerminalKind,
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TerminalTarget>,
}

// ── daemon → client messages ──────────────────────────────────────────────────

/// Messages sent from the daemon to a TUI client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMsg {
    Welcome {
        protocol_version: u32,
        daemon_pid: u32,
        /// Optional capabilities this daemon serves beyond the base
        /// protocol (currently `"work"`: the `work` topic and its frames).
        /// A client sends a topic only the daemon advertises, because an
        /// older daemon rejects a topic it has never heard of. Additive:
        /// absent on the wire when empty, so a daemon that predates the field
        /// (and a client that ignores it) is unaffected; `PROTOCOL_VERSION`
        /// does not change.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        features: Vec<String>,
        /// A per-connection secret, present only when the daemon verified the
        /// peer as the operator app. Every `DecisionAnswer` on this connection
        /// must echo it. Additive: absent otherwise, so `PROTOCOL_VERSION` does
        /// not change.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operator_nonce: Option<String>,
        /// The built-in agents this daemon runs (`"mother"` always among them).
        /// A switchable agent (fred / perri / teri) that is absent is disabled.
        /// Additive: absent on the wire from an older daemon, which a client must
        /// read as "every agent enabled"; `PROTOCOL_VERSION` does not change.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        enabled_agents: Option<Vec<String>>,
        /// The switchable agents this daemon has turned off (an empty list: none).
        /// Lets a client that knows an agent this daemon predates tell "off" from
        /// "not offered": it hides only what is named here. Additive: absent from
        /// an older daemon, and ignored by a client that predates it;
        /// `PROTOCOL_VERSION` does not change.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        disabled_agents: Option<Vec<String>>,
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

    /// Broadcast snapshot of one focus's PR review state (W7).
    ///
    /// **The two fields have deliberately different scopes, and this is the
    /// asymmetry to remember when reading this variant:**
    ///
    /// - `current` — the PR **`tag`'s focus** has under review, or `None` when
    ///   it has none. Per-focus, because "the PR under review" is a property
    ///   of the focus: two focuses reviewing two PRs is the ordinary case, and
    ///   before W7 the machine had one slot that whichever focus picked up a
    ///   PR most recently silently owned.
    /// - `queue` — the **fleet-wide** review queue, byte-identical in every
    ///   frame regardless of `tag`. There is one set of open PRs and every
    ///   focus sees the same one; splitting it per focus would be a different
    ///   and worse product (PRD: "only the PR under review is scoped").
    ///
    /// One frame per focus rather than one frame carrying a map, matching
    /// every other per-focus broadcast here (`FocusLayout`, `PaneContent`,
    /// `Activity`): a PR change re-sends only the focuses whose PR moved, and
    /// `PrSnapshot` carries a diff of up to 500 KB.
    PerriState {
        /// The focus this frame describes.
        tag: String,
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

    /// A turn's origin changed without the turn changing otherwise: a second
    /// `<task-notification>` merged into the open wake turn. The full new
    /// origin (REPLACE). A top-level frame because a client that does not know
    /// a `TurnDelta` kind fails the whole frame, while an unknown frame type is
    /// ignored.
    SessionTurnOrigin {
        tag: String,
        turn_id: String,
        origin: TurnOrigin,
    },

    /// Session lifecycle state changed.
    SessionState {
        tag: String,
        state: SessionState,
    },

    /// The session's `nostromo-mcp-bridge` connected to (or was lost from) the
    /// daemon's MCP socket. A session whose bridge is gone has lost its
    /// `mcp__nostromo__*` tools until the client reconnects it. Sent on every
    /// transition and on attach; never for a tag that never had a bridge.
    SessionBridge {
        tag: String,
        connected: bool,
    },

    /// Never constructed (superseded by `ApprovalRequest`; a test pins that).
    /// Classified `LocalOnly`, so even a stray one never reaches a network peer.
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
        /// How trustworthy this content is. `None` for content that has no
        /// staleness concept (e.g. agent-authored `set_pane_content`) and for
        /// frames from an older daemon that predates this field.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        freshness: Option<PaneFreshness>,
        /// Where to look inside this pane's content, and why (W1). `None` for
        /// every push before this field existed and every caller with nothing
        /// to point at.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        address: Option<PaneAddress>,
    },

    /// The daemon announces an agent-spawned focus (via `create_focus`) so every
    /// connected client can add the new tab.
    FocusCreated {
        meta: FocusMeta,
    },

    /// A daemon-driven decision modal request (W6). An agent called
    /// `nostromo.ask_decision` and is blocked awaiting the operator's answer.
    /// `detail`/`context_pane_id` are omitted from the wire entirely when
    /// absent (unlike `DecisionAnswer::choice_id`, which is always present).
    DecisionRequest {
        tag: String,
        request_id: String,
        prompt: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        detail: Option<String>,
        choices: Vec<DecisionChoice>,
        /// A *reference* to a pane for context — never content itself (R7).
        #[serde(skip_serializing_if = "Option::is_none", default)]
        context_pane_id: Option<String>,
    },

    /// A `DecisionRequest` has been resolved — answered, dismissed, timed
    /// out, or cancelled (multi-window decision-sheet fix). Broadcast so
    /// EVERY presenting window (not just the one the operator actually used)
    /// can close its own sheet without itself sending an answer — a
    /// system-initiated close must never look like an operator dismissal on
    /// the wire. `choice_id` is present only when `resolution == Answered`;
    /// absent from the wire entirely (not even `null`) otherwise, matching
    /// `DecisionRequest.detail`'s convention.
    DecisionResolved {
        tag: String,
        request_id: String,
        resolution: DecisionResolution,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        choice_id: Option<String>,
    },

    // ── permission approvals (AP0b) ──────────────────────────────────────────
    // Only `ApprovalPending` (a count) may reach a network peer; the rest carry
    // the command, reason and working directory and are `LocalOnly`.
    /// A permission request the daemon is holding for a human. Sent to
    /// connections that render approvals (the verified Mac app).
    ApprovalRequest {
        tag: String,
        request: crate::approvals::wire::ApprovalRequestWire,
    },
    /// Every request still held, sent once to a connection that subscribes
    /// with `renders_approvals` (targeted).
    ApprovalsSnapshot {
        requests: Vec<crate::approvals::wire::ApprovalRequestWire>,
    },
    /// A held request ended: answered, timed out, the app went away, the
    /// session stopped. `outcome` is the audit log's name for it.
    ApprovalResolved {
        tag: String,
        request_id: String,
        outcome: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        by_window: Option<String>,
        at_ms: u64,
    },
    /// How many requests are held for a focus. The count only: the one approval
    /// frame a network peer may receive (for a non-sensitive focus).
    ApprovalPending {
        tag: String,
        count: u32,
    },
    /// The production-shell guard blocked a call. `summary` is the tool name and
    /// the first command word only.
    ApprovalGuardBlocked {
        tag: String,
        tool_use_id: String,
        entry_id: String,
        at_ms: u64,
        summary: String,
    },
    /// An `ApprovalAnswer` was not applied (targeted).
    ApprovalAnswerRefused {
        request_id: String,
        code: crate::approvals::wire::AnswerRefusal,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        outcome: Option<String>,
    },

    /// Which sessions are waiting for a Claude sign-in, as a whole picture
    /// (REPLACE semantics): broadcast on every change and replayed to a local
    /// peer after Subscribe. `needs_login` is false exactly when `sessions` is
    /// empty. Carries no message text and no error text; `LocalOnly` (it names
    /// tags and the absolute path of `claude`).
    ClaudeLoginState {
        needs_login: bool,
        /// The `claude` the daemon runs: the one a sign-in must be done with.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        claude_bin: Option<String>,
        watch: ClaudeLoginWatch,
        sessions: Vec<ClaudeLoginSession>,
    },

    /// The answer to a `ClientMsg::PaneAction` (targeted). `message` is plain
    /// English for the reader (why an action was refused, or what started).
    /// `open_url` is for the Mac to open: only an `https:` URL, or a `file:`
    /// URL inside the daemon's Huey folder. Local only.
    PaneActionResult {
        tag: String,
        pane_id: String,
        action_id: String,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        open_url: Option<String>,
    },

    /// A daemon-originated, tag-addressed, operator-facing notification (W5
    /// — current-pr-collision), modelled directly on `DecisionRequest`:
    /// same broadcast-then-topic-gate shape, same "one daemon-side origin,
    /// every window renders it" contract. Routed under `Topic::Layout`
    /// rather than a new topic, so an older client that hasn't added a
    /// dedicated subscription still receives it (it already subscribes to
    /// `layout` for `FocusLayout`/`PaneContent`) instead of silently
    /// dropping it on a version skew.
    ///
    /// Ships with **no production caller** — this wedge lands the transport
    /// end to end (daemon variant, topic gate, client decode, toast
    /// rendering) and proves it with a broadcast-path test; a later wedge
    /// (the same-PR advisory) wires the first real trigger.
    Notification {
        tag: String,
        level: NotificationLevel,
        message: String,
    },

    // ── ambient activity (activity-path wedge) ───────────────────────────────
    /// Full snapshot of one focus's activity streams — the main stream plus
    /// every (running or finished) subagent stream. Sent in response to
    /// `ClientMsg::ActivitySnapshotRequest`.
    ActivitySnapshot {
        tag: String,
        streams: Vec<ActivityStreamWire>,
    },

    /// Ingestion health verdict for the ambient activity feed — is the
    /// `activity.jsonl` tailer actually producing events, and is the hook
    /// that feeds it installed.
    ActivityHealth {
        ingesting: bool,
        /// Human-readable reason when `ingesting == false` (e.g. "hook not
        /// installed", "tailer not started"). `None` when healthy.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        reason: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        last_event_at: Option<chrono::DateTime<chrono::Utc>>,
        hook_installed: bool,
    },

    // ── Teri/Fred work views (all sensitive: never sent to TCP peers) ────────
    /// Health of one work source. Retained per source.
    WorkSourceStatus {
        status: crate::data::work::SourceStatus,
    },
    /// Full replacement of one group's items. `repo_docs` sends one frame per
    /// repo (`group` = repo); other sources use `group: None`. A group that
    /// disappears is sent once with `items: []`.
    WorkSnapshot {
        source: crate::data::work::WorkSource,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        group: Option<String>,
        items: Vec<crate::data::work::WorkItem>,
    },
    /// Teri's published picks. Retained.
    TeriPicks {
        picks: crate::data::work::PicksSnapshot,
    },
    /// Targeted answer to `WorkDetailRequest`.
    WorkDetail {
        request_id: String,
        result: crate::data::work::WorkResult<crate::data::work::WorkDetail>,
    },
    /// Targeted answer to `WorkSendPreviewRequest`.
    WorkSendPreview {
        request_id: String,
        result: crate::data::work::WorkResult<crate::data::work::SendPreview>,
    },
    /// Targeted answer to `WorkSend` / `FredSeed`.
    WorkSendResult {
        request_id: String,
        result: crate::data::work::WorkResult<crate::data::work::SendOutcome>,
    },
    /// Sent once to a network (TCP) peer after it subscribes: these topics are
    /// deliberately not delivered over this transport.
    Withheld {
        topics: Vec<Topic>,
        reason: String,
    },

    // ── model switching ───────────────────────────────────────────────────────
    /// The model families the installed CLI offers, cheapest first. Sent on
    /// attach, on request and after every probe.
    ModelCatalog {
        families: Vec<ModelFamilyWire>,
        /// The last probe failed; these are the families an earlier one saw.
        stale: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        fetched_at: Option<chrono::DateTime<chrono::Utc>>,
    },
    /// One focus's model: recorded, reported, any switch in progress.
    /// Replayed per tag on attach and broadcast on every change.
    SessionModelState(SessionModelState),
    /// Per-agent defaults, and the model each agent declares.
    ModelDefaults {
        defaults: std::collections::BTreeMap<String, AgentModelDefault>,
        declared: std::collections::BTreeMap<String, String>,
    },
    /// Answer to `SessionModelSet` / `ModelDefaultSet`, sent to the requesting
    /// connection only.
    ModelRequestResult {
        request_id: String,
        status: ModelRequestStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        warning: Option<String>,
    },
    // ── background tasks ──────────────────────────────────────────────────────
    /// Every background task of a session, retained ended ones included. A
    /// full snapshot (REPLACE semantics), sent on attach and on every change
    /// (coalesced). Metadata only: no output, preview, summary, prompt or path.
    SessionTasks {
        tag: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        daemon_epoch: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        stop_supported: Option<bool>,
        tasks: Vec<TaskMeta>,
    },
    /// The text derived from one task's output or from the conversation: the
    /// last output line, the agent's progress and completion summaries, its
    /// prompt. `LocalOnly`: never sent to a network peer, whatever the tag.
    SessionTaskDetail {
        tag: String,
        task_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        preview: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress_summary: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        completion_summary: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prompt: Option<String>,
    },
    /// Answer to `SessionTaskStop`, to the asking client only. `LocalOnly`.
    SessionTaskStopResult {
        request_id: String,
        tag: String,
        task_id: String,
        outcome: TaskStopOutcome,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// Answer to `SessionTaskOutput`, to the asking client only. `text` is
    /// sanitised output (no escape sequences) for the raw byte range
    /// `[start_offset, end_offset)` of an output of `total_bytes`. `LocalOnly`.
    SessionTaskOutputResult {
        request_id: String,
        tag: String,
        task_id: String,
        outcome: TaskOutputOutcome,
        text: String,
        start_offset: u64,
        end_offset: u64,
        total_bytes: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<TaskOutputSource>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // ── agent tracker ─────────────────────────────────────────────────────────
    /// What the tracker pane shows for a focus: the whole board, as a REPLACE
    /// snapshot (`None`: the focus has no tracker). Carries titles, item text,
    /// notes, owners, links, commands and the file path, so it is `LocalOnly`:
    /// never sent to a network peer, whatever the focus.
    TrackerBoard {
        tag: String,
        board: Option<crate::tracker::TrackerBoardView>,
    },
    /// That a focus has a tracker and how many items it holds per status, and
    /// nothing else: the only tracker frame a network peer may receive (for a
    /// non-sensitive focus). The key set is pinned by a test in `peer.rs`.
    TrackerSummary {
        tag: String,
        has_tracker: bool,
        counts: TrackerCounts,
    },

    // ── terminal panes (1a; all `LocalOnly`) ──────────────────────────────────
    /// Every terminal the daemon knows, sent to each local connection after the
    /// layout replay. `closed` lists terminals that ended while the daemon was
    /// stopped and whose panes are gone (remote shells; see `terminal::store`).
    TerminalList {
        terminals: Vec<TerminalInfo>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        closed: Vec<TerminalClosedInfo>,
    },
    /// A terminal's metadata changed (opened, resized, ended, restarted).
    /// Broadcast under `Topic::Terminal`. Never carries terminal bytes.
    TerminalState {
        terminal: TerminalInfo,
    },
    /// A terminal and its pane are gone. Broadcast under `Topic::Terminal`.
    TerminalClosed(TerminalClosedInfo),
    /// The start of an attachment: reset the view to `cols`×`rows` and feed
    /// `bytes` (base64: the replay ring, then a repaint of the screen). A
    /// replay larger than one frame continues in `TerminalOutput` frames.
    /// Targeted to the attaching operator connection only.
    TerminalReplay {
        terminal_id: String,
        cols: u16,
        rows: u16,
        bytes: String,
    },
    /// Terminal bytes (base64). Targeted to attached operator connections only.
    TerminalOutput {
        terminal_id: String,
        bytes: String,
    },
    /// A terminal request was refused or failed; nothing changed.
    TerminalRefused {
        op: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        terminal_id: Option<String>,
        code: String,
    },

    /// The open remote shells (metadata only), answering
    /// `TerminalRemoteSummaryRequest` (targeted).
    TerminalRemoteSummary {
        #[serde(default)]
        shells: Vec<RemoteShellSummary>,
    },

    // ── command staging (S1a; `LocalOnly`, targeted) ──────────────────────────
    /// A terminal's staging list, whole, sent on every change and, for every
    /// list, to a connection that declares `terminal_staging_ui` when it
    /// subscribes. `state` is `active`, `frozen` (the follow ended: the list
    /// is kept, no agent can change it) or `none` (no list: no drawer; then
    /// `entries` is empty). Targeted to operator-app connections that declared
    /// `terminal_staging_ui`, and to no one else.
    TerminalStagingList {
        terminal_id: String,
        pane_id: String,
        state: TerminalStagingState,
        owner_tag: String,
        agent_name: String,
        revision: u64,
        entries: Vec<StagedEntryWire>,
        /// Is staging on for this terminal (the per-terminal switch)? Always
        /// sent; an older daemon's frames read as `true`.
        #[serde(default = "default_true")]
        enabled: bool,
        /// A non-shell program is in the foreground of a local terminal (its
        /// name, or `unknown program`): the app treats the pane as production.
        /// Never told to the agent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        foreground: Option<String>,
    },

    // ── remote shells (2a; all `LocalOnly`) ───────────────────────────────────
    /// The remote-shell vocabulary, answering `RemoteShellTargetsRequest`
    /// (targeted). Read from the layer's data at request time.
    /// `configured: false` carries a `problem`.
    RemoteShellTargets {
        configured: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        problem: Option<String>,
        #[serde(default)]
        projects: Vec<RemoteShellProject>,
        #[serde(default)]
        shell_types: Vec<String>,
        /// Each project's repository directories (`~` kept as written), so the
        /// app can preselect the project a focus's directory belongs to. For
        /// the operator's picker only: the agent-facing list leaves them out.
        /// Additive: absent when there are none.
        #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
        repo_paths: std::collections::BTreeMap<String, Vec<String>>,
    },
    /// An agent (or the user) asks to open a remote shell; the app shows the
    /// confirm sheet. Targeted to operator-app connections that declared
    /// `remote_shell_confirm`, and to no one else.
    RemoteShellConfirmRequest {
        request_id: String,
        /// The focus the pane would open in.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag: Option<String>,
        target: TerminalTarget,
        requested_by: RemoteRequester,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// RFC 3339 UTC: when the daemon gives up waiting.
        expires_at: String,
        /// What will run, resolved from the ECS data and pinned for this
        /// request: the remote command, the AWS profile (absent when none is
        /// configured) and the ECS cluster. Each is checked against a strict
        /// character set before it is sent. Additive: an older app ignores them.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        shell_command: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cluster: Option<String>,
    },
    /// How a confirm request ended (the sheet closes). `outcome` is
    /// `connected`, `cancelled`, `dismissed`, `timed_out` or `connect_failed`
    /// (then `reason` is the failure's code and `remedy` what to do about it).
    /// Targeted to the same connections as the request.
    RemoteShellResolved {
        request_id: String,
        outcome: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        remedy: Option<String>,
        /// On `connect_failed` only, and only for the person at the app: the
        /// first line the AWS CLI printed, stripped of escapes and control
        /// characters and cut short. Never sent to the agent, never audited.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },

    /// TUI-internal pseudo-event — **never produced by the daemon**.
    ///
    /// Injected locally by the [`DaemonClient`] supervisor immediately after a
    /// successful reconnect so subscribers (e.g. `DaemonPtyClient`) can
    /// re-issue their attach/subscribe commands.
    DaemonReconnected,
    /// The Mother notice switches and each focus's notice state (plan index
    /// §W). Local peers only; sent on every change and after Subscribe.
    MotherNoticeState {
        enabled: bool,
        focuses: Vec<crate::mother::notices::FocusNoticeState>,
    },
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
    fn a_session_turn_origin_frame_has_the_pinned_wire_shape_and_decodes_back() {
        let msg = ServerMsg::SessionTurnOrigin {
            tag: "claudia-ABCD1234".into(),
            turn_id: "t0".into(),
            origin: TurnOrigin::TaskWake {
                items: vec![crate::ipc::stream_json::TaskWakeItem {
                    task_id: Some("b1".into()),
                    tool_use_id: None,
                    kind: "shell".into(),
                    outcome: "failed".into(),
                    description: "make".into(),
                }],
                omitted: 0,
            },
        };
        let v = serde_json::to_value(&msg).unwrap();
        assert_eq!(v["type"], "session_turn_origin");
        assert_eq!(v["tag"], "claudia-ABCD1234");
        assert_eq!(v["turn_id"], "t0");
        assert_eq!(v["origin"]["type"], "task_wake");
        assert_eq!(v["origin"]["items"][0]["kind"], "shell");
        assert!(
            v["origin"].get("omitted").is_none(),
            "omitted is absent when 0: {v}"
        );

        let ServerMsg::SessionTurnOrigin {
            tag,
            turn_id,
            origin: TurnOrigin::TaskWake { items, omitted },
        } = serde_json::from_value(v).unwrap()
        else {
            panic!("decodes back to the same frame");
        };
        assert_eq!(
            (tag.as_str(), turn_id.as_str(), omitted),
            ("claudia-ABCD1234", "t0", 0)
        );
        assert_eq!(items.len(), 1);

        let more = serde_json::json!({
            "type": "session_turn_origin", "tag": "x", "turn_id": "t1",
            "origin": {"type": "task_wake", "items": [], "omitted": 7}
        });
        let ServerMsg::SessionTurnOrigin {
            origin: TurnOrigin::TaskWake { omitted, .. },
            ..
        } = serde_json::from_value(more).unwrap()
        else {
            panic!("decodes");
        };
        assert_eq!(omitted, 7);
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
        round_trip_client(ClientMsg::SessionInterrupt { tag: "fred".into() });
        round_trip_client(ClientMsg::ClosePane {
            tag: "perri".into(),
            pane_id: "detail.1".into(),
        });
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
                origin: None,
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
                    origin: None,
                },
            },
        });
        round_trip_server(ServerMsg::SessionTurnOrigin {
            tag: "fred".into(),
            turn_id: "t0".into(),
            origin: TurnOrigin::TaskWake {
                items: vec![crate::ipc::stream_json::TaskWakeItem {
                    task_id: Some("b1".into()),
                    tool_use_id: Some("toolu_1".into()),
                    kind: "monitor".into(),
                    outcome: "new_output".into(),
                    description: "CI".into(),
                }],
                omitted: 2,
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
                mcp_bridge_connected: None,
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
    fn session_interrupt_serialises_as_session_interrupt() {
        let v = serde_json::to_value(ClientMsg::SessionInterrupt {
            tag: "perri".into(),
        })
        .unwrap();
        assert_eq!(v.get("type").unwrap(), "session_interrupt");
        assert_eq!(v.get("tag").unwrap(), "perri");
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

    // ── ClientMsg::Subscribe / renders_decisions (decision-operator-gate fix) ──
    //
    // `renders_decisions` distinguishes "this client can actually render and
    // answer a decision modal" from merely "this client subscribed to
    // everything" (`topics: []`, today's iOS behavior). The operator-gate fix
    // in `server.rs::handle_client` reads this field directly off the wire, so
    // its default-on-absence and exact JSON shape are load-bearing.

    /// A `Subscribe` frame from a peer that predates this field (or a client
    /// that simply omits it) must still decode — and must decode to `false`,
    /// never silently to `true` — since defaulting the other way would let an
    /// old/unaware client be miscounted as an operator.
    #[test]
    fn subscribe_without_a_renders_decisions_key_decodes_as_false() {
        let msg: ClientMsg = serde_json::from_str(r#"{"type":"subscribe","topics":[]}"#).unwrap();
        match msg {
            ClientMsg::Subscribe {
                topics,
                renders_decisions,
                ..
            } => {
                assert_eq!(topics, vec![]);
                assert!(
                    !renders_decisions,
                    "an absent renders_decisions key must decode to false, not true"
                );
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    /// Same as above, but with a non-empty `topics` list alongside the missing
    /// key — proves `#[serde(default)]` is doing the work here, not some
    /// coincidence of an empty-vec/empty-object special case.
    #[test]
    fn subscribe_with_topics_and_no_renders_decisions_key_still_decodes_successfully() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":["decision","layout"]}"#).unwrap();
        match msg {
            ClientMsg::Subscribe {
                topics,
                renders_decisions,
                ..
            } => {
                assert_eq!(topics, vec![Topic::Decision, Topic::Layout]);
                assert!(!renders_decisions);
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn subscribe_with_renders_decisions_true_decodes_true() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":[],"renders_decisions":true}"#)
                .unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_decisions, ..
            } => assert!(renders_decisions),
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn subscribe_with_renders_decisions_false_decodes_false() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":[],"renders_decisions":false}"#)
                .unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_decisions, ..
            } => assert!(!renders_decisions),
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    /// Round-trip plus an exact-shape assertion on the encoded JSON — the same
    /// convention this file already uses for `choice_id` presence on
    /// `DecisionAnswer`/`DecisionResolved` — so the wire key name
    /// (`renders_decisions`, snake_case) and its presence are pinned down, not
    /// just "some boolean survives a round trip."
    #[test]
    fn encoding_subscribe_includes_an_explicit_renders_decisions_false_key() {
        round_trip_client(ClientMsg::Subscribe {
            topics: vec![],
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        });

        let v = serde_json::to_value(ClientMsg::Subscribe {
            topics: vec![],
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        })
        .unwrap();
        assert_eq!(v["type"], "subscribe");
        assert_eq!(v["topics"], serde_json::json!([]));
        assert_eq!(
            v["renders_decisions"], false,
            "renders_decisions must be present and false on the wire, not omitted"
        );
    }

    #[test]
    fn encoding_subscribe_includes_an_explicit_renders_decisions_true_key() {
        round_trip_client(ClientMsg::Subscribe {
            topics: vec![],
            renders_decisions: true,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        });

        let v = serde_json::to_value(ClientMsg::Subscribe {
            topics: vec![],
            renders_decisions: true,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        })
        .unwrap();
        assert_eq!(v["renders_decisions"], true);
    }

    // ── Hello.client_kind (AP1) ──────────────────────────────────────────────

    #[test]
    fn a_hello_from_an_older_client_without_client_kind_still_decodes() {
        let json = r#"{"type":"hello","client_id":"old-app","protocol_version":4}"#;
        let msg: ClientMsg = serde_json::from_str(json).expect("an old Hello must still decode");
        match msg {
            ClientMsg::Hello {
                client_id,
                protocol_version,
                client_kind,
            } => {
                assert_eq!(client_id, "old-app");
                assert_eq!(protocol_version, 4);
                assert_eq!(client_kind, None);
            }
            other => panic!("expected Hello, got {other:?}"),
        }
    }

    #[test]
    fn a_hello_carrying_client_kind_mac_app_decodes_it() {
        let json =
            r#"{"type":"hello","client_id":"app","protocol_version":4,"client_kind":"mac_app"}"#;
        match serde_json::from_str::<ClientMsg>(json).unwrap() {
            ClientMsg::Hello { client_kind, .. } => {
                assert_eq!(client_kind.as_deref(), Some("mac_app"))
            }
            other => panic!("expected Hello, got {other:?}"),
        }
    }

    #[test]
    fn a_hello_without_client_kind_is_encoded_without_the_key() {
        let v = serde_json::to_value(ClientMsg::Hello {
            client_id: "c".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: None,
        })
        .unwrap();
        assert!(
            v.as_object().unwrap().get("client_kind").is_none(),
            "a client that claims nothing must send nothing (older daemons see an identical Hello): {v}"
        );
    }

    #[test]
    fn a_hello_with_client_kind_round_trips() {
        round_trip_client(ClientMsg::Hello {
            client_id: "app".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: Some("mac_app".into()),
        });
        let v = serde_json::to_value(ClientMsg::Hello {
            client_id: "app".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: Some("mac_app".into()),
        })
        .unwrap();
        assert_eq!(v["client_kind"], "mac_app");
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
                body: None,
            }],
            stale: false,
            error: None,
            not_configured: false,
        };
        round_trip_server(ServerMsg::TeriState { todos: snap });
    }

    #[test]
    fn topic_teri_serializes_to_teri() {
        assert_eq!(serde_json::to_string(&Topic::Teri).unwrap(), "\"teri\"");
    }

    #[test]
    fn focus_meta_round_trips() {
        // All optionals Some
        let full = FocusMeta {
            initial_model: None,
            initial_effort: None,
            tag: "cody-abc12345".into(),
            display_name: "Cody in Admin Portal".into(),
            agent_name: "cody".into(),
            project_name: Some("Admin Portal".into()),
            org: Some("Carefeed".into()),
            is_built_in: false,
            session_summary: Some("Build the auth flow".into()),
            label: None,
            project_path: None,
            select_for_client: None,
        };
        let json = serde_json::to_string(&full).unwrap();
        let back: FocusMeta = serde_json::from_str(&json).unwrap();
        assert_eq!(full, back);

        // All optionals None
        let minimal = FocusMeta {
            initial_model: None,
            initial_effort: None,
            tag: "fred".into(),
            display_name: "Fred".into(),
            agent_name: "fred".into(),
            project_name: None,
            org: None,
            is_built_in: true,
            session_summary: None,
            label: None,
            project_path: None,
            select_for_client: None,
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
                PeekTodo {
                    status: "completed".into(),
                    content: "Add Rust protocol variant".into(),
                },
                PeekTodo {
                    status: "in_progress".into(),
                    content: "Add NostromoKit wire types".into(),
                },
                PeekTodo {
                    status: "pending".into(),
                    content: "Add iOS tab".into(),
                },
            ],
            tool_trail: vec![
                PeekToolCall {
                    tool: "Read".into(),
                    brief: "src/ipc/protocol.rs".into(),
                },
                PeekToolCall {
                    tool: "Edit".into(),
                    brief: "add MotherPeek variant".into(),
                },
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
            initial_model: None,
            initial_effort: None,
            tag: "fred".into(),
            display_name: "Fred".into(),
            agent_name: "fred".into(),
            project_name: None,
            org: Some("Carefeed".into()),
            is_built_in: true,
            session_summary: None,
            label: None,
            project_path: None,
            select_for_client: None,
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
            freshness: None,
            address: None,
        });
        round_trip_server(ServerMsg::PaneContent {
            tag: "mother".into(),
            pane_id: "jobs".into(),
            content: PaneContentWire::JsonSnapshot {
                value: serde_json::json!({ "jobs": [1, 2, 3] }),
            },
            freshness: None,
            address: None,
        });
        round_trip_server(ServerMsg::FocusCreated {
            meta: FocusMeta {
                initial_model: None,
                initial_effort: None,
                tag: "cody-core-1234".into(),
                display_name: "CORE-1234".into(),
                agent_name: "cody".into(),
                project_name: None,
                org: None,
                is_built_in: false,
                session_summary: None,
                label: None,
                project_path: None,
                select_for_client: None,
            },
        });
    }

    // ── PaneFreshness ──────────────────────────────────────────────────────────

    #[test]
    fn pane_content_with_badly_stale_freshness_round_trips() {
        use chrono::{TimeZone, Utc};

        let as_of = Utc.with_ymd_and_hms(2026, 7, 30, 12, 0, 0).unwrap();
        round_trip_server(ServerMsg::PaneContent {
            tag: "perri".into(),
            pane_id: "queue".into(),
            content: PaneContentWire::Text {
                text: "stale placeholder".into(),
            },
            freshness: Some(PaneFreshness {
                as_of: Some(as_of),
                stale: true,
                badly_stale: true,
            }),
            address: None,
        });
    }

    #[test]
    fn pane_content_with_no_freshness_round_trips_as_none() {
        round_trip_server(ServerMsg::PaneContent {
            tag: "perri".into(),
            pane_id: "queue".into(),
            content: PaneContentWire::Text {
                text: "fresh".into(),
            },
            freshness: None,
            address: None,
        });
    }

    /// An old daemon build (pre-freshness) never emits a `"freshness"` key at
    /// all. A hand-written JSON literal — not a serialize-then-deserialize
    /// round trip — simulates that exact wire shape and must still parse,
    /// with `freshness` landing as `None`.
    #[test]
    fn pane_content_without_freshness_key_deserializes_with_freshness_none() {
        let raw = r#"{
            "type": "pane_content",
            "tag": "perri",
            "pane_id": "queue",
            "content": { "kind": "text", "text": "from an old daemon" }
        }"#;
        let msg: ServerMsg = serde_json::from_str(raw).expect("old-shaped frame must still parse");
        match msg {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                freshness,
                address,
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(
                    matches!(content, PaneContentWire::Text { text } if text == "from an old daemon")
                );
                assert_eq!(
                    freshness, None,
                    "an absent \"freshness\" key must deserialize to None"
                );
                assert_eq!(
                    address, None,
                    "an absent \"address\" key must deserialize to None"
                );
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }
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

    // ── PaneTree::Tabs (W1 — curated-agent-views) ────────────────────────────

    #[test]
    fn pane_tree_tabs_node_round_trips_and_carries_kind_tabs() {
        let tree = PaneTree::Tabs {
            children: vec![
                PaneTree::Leaf {
                    pane_id: "ticket".into(),
                },
                PaneTree::Leaf {
                    pane_id: "activity".into(),
                },
            ],
            labels: vec!["Ticket".into(), "Activity".into()],
            active: 1,
            region: None,
        };
        round_trip_pane_tree(&tree);

        let json = serde_json::to_value(&tree).unwrap();
        assert_eq!(json["kind"], "tabs");
        assert_eq!(json["labels"], serde_json::json!(["Ticket", "Activity"]));
        assert_eq!(json["active"], 1);
    }

    #[test]
    fn pane_tree_tabs_node_collects_every_child_pane_id_in_tree_order() {
        let tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Tabs {
                    children: vec![
                        PaneTree::Leaf {
                            pane_id: "ticket".into(),
                        },
                        PaneTree::Leaf {
                            pane_id: "activity".into(),
                        },
                    ],
                    labels: vec!["Ticket".into(), "Activity".into()],
                    active: 0,
                    region: None,
                },
            ],
            ratios: vec![0.6, 0.4],
        };
        assert_eq!(tree.pane_ids(), vec!["repl", "ticket", "activity"]);
    }

    /// Round-trip a bare `PaneTree` (not wrapped in a `ServerMsg`) through JSON.
    fn round_trip_pane_tree(tree: &PaneTree) {
        let json = serde_json::to_string(tree).unwrap();
        let back: PaneTree = serde_json::from_str(&json).unwrap();
        assert_eq!(tree, &back, "pane tree round trip mismatch: {json}");
    }

    // ── PaneAddress / Anchor / Emphasis (W1 — curated-agent-views) ───────────

    fn round_trip_pane_address(addr: &PaneAddress) {
        let json = serde_json::to_string(addr).unwrap();
        let back: PaneAddress = serde_json::from_str(&json).unwrap();
        assert_eq!(addr, &back, "PaneAddress round trip mismatch: {json}");
    }

    #[test]
    fn anchor_line_round_trips_with_and_without_path() {
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::Line {
                path: Some("src/main.rs".into()),
                line: 42,
            }),
            emphasis: vec![],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::Line {
                path: None,
                line: 7,
            }),
            emphasis: vec![],
            reason: None,
        });
    }

    #[test]
    fn anchor_comment_section_and_queue_row_round_trip() {
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::Comment { id: "c-1".into() }),
            emphasis: vec![],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::Section {
                name: "Overview".into(),
            }),
            emphasis: vec![],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::QueueRow {
                repo: "acme/web".into(),
                number: 42,
            }),
            emphasis: vec![],
            reason: None,
        });
    }

    #[test]
    fn every_emphasis_variant_round_trips() {
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::LineRange {
                path: Some("src/main.rs".into()),
                start: 10,
                end: 20,
            }],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::LineRange {
                path: None,
                start: 1,
                end: 2,
            }],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::Comment { id: "c-2".into() }],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::Section {
                name: "Risks".into(),
            }],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::TextRange { start: 0, end: 12 }],
            reason: None,
        });
        round_trip_pane_address(&PaneAddress {
            anchor: None,
            emphasis: vec![Emphasis::QueueRow {
                repo: "acme/web".into(),
                number: 7,
            }],
            reason: None,
        });
    }

    #[test]
    fn pane_address_with_multiple_emphasis_entries_round_trips() {
        round_trip_pane_address(&PaneAddress {
            anchor: Some(Anchor::Line {
                path: None,
                line: 5,
            }),
            emphasis: vec![
                Emphasis::TextRange { start: 0, end: 4 },
                Emphasis::TextRange { start: 10, end: 14 },
            ],
            reason: Some("flagged by CI".into()),
        });
    }

    #[test]
    fn pane_address_empty_omits_every_key_and_still_decodes() {
        let addr = PaneAddress::default();
        let json = serde_json::to_value(&addr).unwrap();
        assert_eq!(
            json,
            serde_json::json!({}),
            "an all-default PaneAddress must serialize with no keys at all"
        );
        let back: PaneAddress = serde_json::from_value(json).unwrap();
        assert_eq!(addr, back);
    }

    #[test]
    fn pane_content_with_address_round_trips_and_carries_it_on_the_wire() {
        round_trip_server(ServerMsg::PaneContent {
            tag: "ticket".into(),
            pane_id: "ticket".into(),
            content: PaneContentWire::Text {
                text: "CORE-1234".into(),
            },
            freshness: None,
            address: Some(PaneAddress {
                anchor: None,
                emphasis: vec![],
                reason: Some("opened from the queue".into()),
            }),
        });
    }

    #[test]
    fn pane_content_without_address_key_deserializes_with_address_none() {
        let raw = r#"{
            "type": "pane_content",
            "tag": "perri",
            "pane_id": "queue",
            "content": { "kind": "text", "text": "from a daemon that predates PaneAddress" }
        }"#;
        let msg: ServerMsg = serde_json::from_str(raw).expect("old-shaped frame must still parse");
        match msg {
            ServerMsg::PaneContent { address, .. } => {
                assert_eq!(
                    address, None,
                    "an absent \"address\" key must deserialize to None"
                );
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }
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
                mcp_bridge_connected: None,
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
                mcp_bridge_connected: None,
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
            tag: Some("perri".into()),
        });
        // clear — pr_number and repo are None
        round_trip_client(ClientMsg::PerriAction {
            action: "clear".into(),
            pr_number: None,
            repo: None,
            tag: Some("perri".into()),
        });
        // approve — pr_number and repo required
        round_trip_client(ClientMsg::PerriAction {
            action: "approve".into(),
            pr_number: Some(7),
            repo: Some("acme/web".into()),
            tag: Some("perri".into()),
        });
    }

    #[test]
    fn perri_action_approve_wire_shape() {
        let v = serde_json::to_value(ClientMsg::PerriAction {
            action: "approve".into(),
            pr_number: Some(7),
            repo: Some("acme/web".into()),
            tag: Some("perri".into()),
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
            tag: Some("perri".into()),
        })
        .unwrap();
        assert_eq!(v["type"], "perri_action");
        assert_eq!(v["pr_number"], 1u64);
        assert_eq!(v["repo"], "org/repo");

        let v2 = serde_json::to_value(ClientMsg::PerriAction {
            action: "clear".into(),
            pr_number: None,
            repo: None,
            tag: Some("perri".into()),
        })
        .unwrap();
        assert_eq!(v2["type"], "perri_action");
        assert!(v2["pr_number"].is_null());
        assert!(v2["repo"].is_null());
    }

    #[test]
    fn perri_state_round_trip_empty() {
        round_trip_server(ServerMsg::PerriState {
            tag: "perri".into(),
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
            generated_at: None,
            ..Default::default()
        };

        round_trip_server(ServerMsg::PerriState {
            tag: "perri".into(),
            queue: vec![item],
            current: Some(Box::new(snap)),
        });
    }

    #[test]
    fn perri_state_type_tag_is_perri_state() {
        let v = serde_json::to_value(ServerMsg::PerriState {
            tag: "perri".into(),
            queue: vec![],
            current: None,
        })
        .unwrap();
        assert_eq!(v["type"], "perri_state");
    }

    #[test]
    fn topic_perri_serializes_to_perri() {
        assert_eq!(serde_json::to_string(&Topic::Perri).unwrap(), "\"perri\"");
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
            mailbox: MailboxSnapshot::default(),
            calendar: CalendarSnapshot::default(),
        });

        // (b) Populated: one VIP unread MailboxItem + one is_now CalendarEvent +
        //     NextEvent + auth_prompt.
        let mailbox = MailboxSnapshot {
            generated_at: None,
            unread_count: 1,
            items: vec![MailboxItem {
                from: "Alice <alice@example.com>".into(),
                subject: "Important: Meeting Tomorrow".into(),
                received_at: Some(chrono::Utc::now()),
                vip: true,
                is_invite: false,
                is_read: false,
                ..Default::default()
            }],
            stale: false,
            error: None,
            auth_prompt: Some(DeviceFlowPrompt {
                verification_uri: "https://microsoft.com/devicelogin".into(),
                user_code: "ABCD-1234".into(),
                expires_at: chrono::Utc::now(),
                kind: "device_code".into(),
                account: None,
                provider: None,
            }),
            ..Default::default()
        };
        let calendar = CalendarSnapshot {
            events: vec![CalendarEvent {
                start: Some(chrono::Utc::now()),
                end: Some(chrono::Utc::now()),
                title: "Daily standup".into(),
                status: "accepted".into(),
                is_now: true,
                ..Default::default()
            }],
            next: Some(NextEvent {
                title: "Lunch".into(),
                in_minutes: 45,
            }),
            sweater: "amber".into(),
            stale: false,
            error: None,
            generated_at: Some(chrono::Utc::now()),
            ..Default::default()
        };
        round_trip_server(ServerMsg::FredState { mailbox, calendar });
    }

    #[test]
    fn fred_state_type_tag_is_fred_state() {
        let v = serde_json::to_value(ServerMsg::FredState {
            mailbox: crate::data::fred_mailbox::MailboxSnapshot::default(),
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
                    repo: "acme/web".into(),
                    number: 42,
                    title: "feat: auth".into(),
                    author: "alice".into(),
                    bucket: "requested".into(),
                    ci_state: CiState::Success,
                    new_activity: false,
                    url: "https://github.com/acme/web/pull/42".into(),
                    head_sha: "abc123".into(),
                }],
            },
            freshness: None,
            address: None,
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

    // ── ambient activity (activity-path wedge) ───────────────────────────────

    fn sample_activity_event(summary: &str) -> ActivityEvent {
        ActivityEvent {
            ts: chrono::Utc::now(),
            agent: "cody".into(),
            kind: "tool_use".into(),
            summary: summary.into(),
            focus_tag: Some("cody-1".into()),
            session_id: Some("sess-1".into()),
            agent_id: None,
            agent_type: None,
            parent_agent_id: None,
            tool_name: Some("Edit".into()),
            tool_use_id: Some("tu-1".into()),
            cwd: Some("/tmp".into()),
            seq: Some(0),
        }
    }

    #[test]
    fn activity_snapshot_round_trips_with_main_and_subagent_streams() {
        round_trip_server(ServerMsg::ActivitySnapshot {
            tag: "cody-1".into(),
            streams: vec![
                ActivityStreamWire {
                    agent_id: None,
                    agent_type: None,
                    parent_agent_id: None,
                    events: vec![sample_activity_event("editing src/main.rs")],
                    finished: false,
                },
                ActivityStreamWire {
                    agent_id: Some("agent-1".into()),
                    agent_type: Some("redd".into()),
                    parent_agent_id: Some("agent-0".into()),
                    events: vec![sample_activity_event("writing tests")],
                    finished: true,
                },
            ],
        });
    }

    #[test]
    fn activity_health_round_trips_when_ingesting() {
        round_trip_server(ServerMsg::ActivityHealth {
            ingesting: true,
            reason: None,
            last_event_at: Some(chrono::Utc::now()),
            hook_installed: true,
        });
    }

    #[test]
    fn activity_health_round_trips_when_not_ingesting() {
        round_trip_server(ServerMsg::ActivityHealth {
            ingesting: false,
            reason: Some("hook not installed".into()),
            last_event_at: None,
            hook_installed: false,
        });
    }

    #[test]
    fn activity_snapshot_request_round_trips() {
        round_trip_client(ClientMsg::ActivitySnapshotRequest {
            tag: "cody-1".into(),
        });
    }

    // ── render-state visibility (W1) ──────────────────────────────────────────

    #[test]
    fn rendered_shape_round_trips() {
        round_trip_client(ClientMsg::RenderedShape {
            tag: "perri".into(),
            window_id: "0".into(),
            pane_ids: vec!["queue".into(), "repl".into()],
            rendered_at: chrono::Utc::now(),
        });
    }

    #[test]
    fn rendered_shape_round_trips_with_no_panes() {
        round_trip_client(ClientMsg::RenderedShape {
            tag: "perri".into(),
            window_id: "2".into(),
            pane_ids: vec![],
            rendered_at: chrono::Utc::now(),
        });
    }

    #[test]
    fn rendered_shape_wire_type_is_snake_case() {
        let json: serde_json::Value = serde_json::from_str(
            &serde_json::to_string(&ClientMsg::RenderedShape {
                tag: "perri".into(),
                window_id: "0".into(),
                pane_ids: vec!["repl".into()],
                rendered_at: chrono::Utc::now(),
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(json["type"], "rendered_shape");
    }

    /// An old daemon build (pre-schema-growth) emits the original 4-field
    /// `Activity` shape with none of the new attribution fields present. A
    /// hand-written JSON literal — not a serialize-then-deserialize round
    /// trip — simulates that exact wire shape and must still parse.
    #[test]
    fn old_four_field_activity_message_still_deserializes() {
        let raw = r#"{
            "type": "activity",
            "ts": "2026-08-19T00:00:00Z",
            "agent": "perri",
            "kind": "tool_use",
            "summary": "reading a file"
        }"#;
        let msg: ServerMsg =
            serde_json::from_str(raw).expect("old 4-field Activity shape must still parse");
        match msg {
            ServerMsg::Activity(ev) => {
                assert_eq!(ev.agent, "perri");
                assert_eq!(ev.kind, "tool_use");
                assert_eq!(ev.summary, "reading a file");
                assert_eq!(ev.focus_tag, None);
                assert_eq!(ev.seq, None);
            }
            other => panic!("expected Activity, got {other:?}"),
        }
    }

    // ── decision modals (W6) ──────────────────────────────────────────────────

    #[test]
    fn topic_decision_serializes_to_decision() {
        assert_eq!(
            serde_json::to_string(&Topic::Decision).unwrap(),
            "\"decision\""
        );
        let decoded: Topic = serde_json::from_str("\"decision\"").unwrap();
        assert_eq!(decoded, Topic::Decision);
    }

    fn sample_decision_choices() -> Vec<DecisionChoice> {
        vec![
            DecisionChoice {
                id: "approve".into(),
                label: "Approve".into(),
                detail: Some("Merge and deploy".into()),
                is_default: false,
            },
            DecisionChoice {
                id: "reject".into(),
                label: "Reject".into(),
                detail: Some("Block the merge".into()),
                is_default: false,
            },
        ]
    }

    #[test]
    fn decision_answer_with_a_choice_round_trips_and_uses_the_decision_answer_type_tag() {
        round_trip_client(ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: Some("approve".into()),
            operator_nonce: None,
        });

        let v = serde_json::to_value(ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: Some("approve".into()),
            operator_nonce: None,
        })
        .unwrap();
        assert_eq!(v["type"], "decision_answer");
        assert_eq!(v["request_id"], "req-1");
        assert_eq!(v["choice_id"], "approve");
    }

    /// `choice_id: None` (dismissed) is a required, meaningful field — it must
    /// serialize as an explicit JSON `null`, not be skipped/absent, since an
    /// absent key here would be ambiguous with "field not understood by an old
    /// peer" rather than "operator dismissed without choosing".
    #[test]
    fn decision_answer_with_no_choice_round_trips_with_choice_id_present_as_null() {
        round_trip_client(ClientMsg::DecisionAnswer {
            request_id: "req-2".into(),
            choice_id: None,
            operator_nonce: None,
        });

        let v = serde_json::to_value(ClientMsg::DecisionAnswer {
            request_id: "req-2".into(),
            choice_id: None,
            operator_nonce: None,
        })
        .unwrap();
        assert!(
            v.as_object().unwrap().contains_key("choice_id"),
            "choice_id must be present on the wire even when dismissed"
        );
        assert!(
            v["choice_id"].is_null(),
            "a dismissed answer must serialize choice_id as null"
        );
    }

    /// The operator nonce is additive: absent from the wire when `None` (an
    /// app that predates it decodes the same), echoed verbatim when present.
    #[test]
    fn decision_answer_carries_the_operator_nonce_only_when_present() {
        let v = serde_json::to_value(ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: None,
            operator_nonce: None,
        })
        .unwrap();
        assert!(
            !v.as_object().unwrap().contains_key("operator_nonce"),
            "{v}"
        );

        let with = ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: Some("approve".into()),
            operator_nonce: Some("ab12".into()),
        };
        round_trip_client(with.clone());
        assert_eq!(
            serde_json::to_value(with).unwrap()["operator_nonce"],
            "ab12"
        );

        let old: ClientMsg =
            serde_json::from_str(r#"{"type":"decision_answer","request_id":"r","choice_id":null}"#)
                .unwrap();
        assert!(matches!(
            old,
            ClientMsg::DecisionAnswer {
                operator_nonce: None,
                ..
            }
        ));
    }

    #[test]
    fn welcome_carries_the_operator_nonce_only_when_present() {
        let plain = ServerMsg::Welcome {
            protocol_version: PROTOCOL_VERSION,
            daemon_pid: 1,
            features: vec![],
            operator_nonce: None,
            enabled_agents: None,
            disabled_agents: None,
        };
        let v = serde_json::to_value(&plain).unwrap();
        assert!(
            !v.as_object().unwrap().contains_key("operator_nonce"),
            "{v}"
        );

        let operator = ServerMsg::Welcome {
            protocol_version: PROTOCOL_VERSION,
            daemon_pid: 1,
            features: vec![],
            operator_nonce: Some("cd34".into()),
            enabled_agents: None,
            disabled_agents: None,
        };
        round_trip_server(operator.clone());
        assert_eq!(
            serde_json::to_value(operator).unwrap()["operator_nonce"],
            "cd34"
        );
    }

    #[test]
    fn decision_request_round_trips_with_all_fields_populated() {
        round_trip_server(ServerMsg::DecisionRequest {
            tag: "mother".into(),
            request_id: "req-3".into(),
            prompt: "Ship it?".into(),
            detail: Some("This touches the production migration.".into()),
            choices: sample_decision_choices(),
            context_pane_id: Some("diff".into()),
        });
    }

    #[test]
    fn decision_request_with_absent_optionals_omits_their_keys_entirely() {
        let v = serde_json::to_value(ServerMsg::DecisionRequest {
            tag: "mother".into(),
            request_id: "req-4".into(),
            prompt: "Ship it?".into(),
            detail: None,
            choices: sample_decision_choices(),
            context_pane_id: None,
        })
        .unwrap();
        let obj = v.as_object().unwrap();
        assert!(
            !obj.contains_key("detail"),
            "an absent detail must not appear as a key at all, not even null"
        );
        assert!(
            !obj.contains_key("context_pane_id"),
            "an absent context_pane_id must not appear as a key at all, not even null"
        );

        // And it still round-trips back to None for both.
        round_trip_server(ServerMsg::DecisionRequest {
            tag: "mother".into(),
            request_id: "req-4".into(),
            prompt: "Ship it?".into(),
            detail: None,
            choices: sample_decision_choices(),
            context_pane_id: None,
        });
    }

    #[test]
    fn decision_request_type_tag_is_decision_request() {
        let v = serde_json::to_value(ServerMsg::DecisionRequest {
            tag: "mother".into(),
            request_id: "req-5".into(),
            prompt: "Ship it?".into(),
            detail: None,
            choices: sample_decision_choices(),
            context_pane_id: None,
        })
        .unwrap();
        assert_eq!(v["type"], "decision_request");
    }

    // ── ServerMsg::Notification (W5 — current-pr-collision) ───────────────────
    //
    // Modeled directly on `ServerMsg::DecisionRequest` above: a same-PR
    // advisory two wedges from now (a session learning "the PR you're
    // reviewing was just reloaded by another session") needs a daemon → client
    // transport that carries a tag, a severity, and a message. No production
    // caller exists yet — this round-trips the wire shape so the transport is
    // proven before anything sends through it.

    #[test]
    fn notification_round_trips_with_all_fields() {
        round_trip_server(ServerMsg::Notification {
            tag: "perri".into(),
            level: NotificationLevel::Warning,
            message: "PR #4526 was reloaded by another session.".into(),
        });
    }

    #[test]
    fn notification_type_tag_is_notification() {
        let v = serde_json::to_value(ServerMsg::Notification {
            tag: "perri".into(),
            level: NotificationLevel::Warning,
            message: "test".into(),
        })
        .unwrap();
        assert_eq!(v["type"], "notification");
    }

    #[test]
    fn notification_level_serializes_as_snake_case() {
        assert_eq!(
            serde_json::to_value(NotificationLevel::Info).unwrap(),
            serde_json::json!("info")
        );
        assert_eq!(
            serde_json::to_value(NotificationLevel::Warning).unwrap(),
            serde_json::json!("warning")
        );
        assert_eq!(
            serde_json::to_value(NotificationLevel::Alert).unwrap(),
            serde_json::json!("alert")
        );
    }

    #[test]
    fn decision_choice_round_trips_standalone_with_and_without_detail() {
        let with_detail = DecisionChoice {
            id: "approve".into(),
            label: "Approve".into(),
            detail: Some("Merge and deploy".into()),
            is_default: false,
        };
        let json = serde_json::to_string(&with_detail).unwrap();
        let back: DecisionChoice = serde_json::from_str(&json).unwrap();
        assert_eq!(with_detail, back);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, vec!["detail", "id", "label"]);

        let without_detail = DecisionChoice {
            id: "reject".into(),
            label: "Reject".into(),
            detail: None,
            is_default: false,
        };
        let json = serde_json::to_string(&without_detail).unwrap();
        let back: DecisionChoice = serde_json::from_str(&json).unwrap();
        assert_eq!(without_detail, back);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec!["id", "label"],
            "an absent detail must not appear as a key when constructing a DecisionChoice standalone"
        );
    }

    // ── DecisionResolution / ServerMsg::DecisionResolved (multi-window decision-sheet fix) ──
    //
    // Presenting a decision sheet on every open window (instead of once,
    // app-wide) is the bug this whole job fixes. `DecisionResolved` is the
    // notice that lets every window's sheet — not just the one the operator
    // actually answered in — learn a request is done and close itself,
    // WITHOUT that close itself looking like a fresh "dismissed" answer on
    // the wire (a system-initiated close must never masquerade as an
    // operator action). These tests pin the wire shape only; `DecisionRegistry`
    // firing this notice from every resolution path lives in
    // `src/ipc/decisions.rs`'s tests.

    #[test]
    fn every_decision_resolution_variant_round_trips_and_serializes_to_its_exact_wire_string() {
        let cases = [
            (DecisionResolution::Answered, "\"answered\""),
            (DecisionResolution::Dismissed, "\"dismissed\""),
            (DecisionResolution::Timeout, "\"timeout\""),
            (DecisionResolution::Cancelled, "\"cancelled\""),
        ];
        for (variant, wire) in cases {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(
                json, wire,
                "DecisionResolution::{variant:?} must serialize as {wire}"
            );
            let back: DecisionResolution = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn decision_resolved_round_trips_with_a_choice_id() {
        round_trip_server(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-6".into(),
            resolution: DecisionResolution::Answered,
            choice_id: Some("approve".into()),
        });
    }

    #[test]
    fn decision_resolved_round_trips_with_no_choice_id() {
        round_trip_server(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-7".into(),
            resolution: DecisionResolution::Dismissed,
            choice_id: None,
        });
    }

    /// `choice_id: None` must be indistinguishable on the wire from a message
    /// that never had the field at all — same convention as
    /// `decision_request_with_absent_optionals_omits_their_keys_entirely`.
    #[test]
    fn decision_resolved_with_no_choice_id_omits_the_choice_id_key_entirely() {
        let v = serde_json::to_value(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-8".into(),
            resolution: DecisionResolution::Timeout,
            choice_id: None,
        })
        .unwrap();
        let obj = v.as_object().unwrap();
        assert!(
            !obj.contains_key("choice_id"),
            "an absent choice_id must not appear as a key at all, not even null"
        );

        // And it still round-trips back to None.
        round_trip_server(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-8".into(),
            resolution: DecisionResolution::Timeout,
            choice_id: None,
        });
    }

    #[test]
    fn decision_resolved_with_a_choice_id_present_includes_the_choice_id_key() {
        let v = serde_json::to_value(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-8b".into(),
            resolution: DecisionResolution::Answered,
            choice_id: Some("approve".into()),
        })
        .unwrap();
        assert_eq!(v["choice_id"], "approve");
    }

    #[test]
    fn decision_resolved_type_tag_is_decision_resolved() {
        let v = serde_json::to_value(ServerMsg::DecisionResolved {
            tag: "mother".into(),
            request_id: "req-9".into(),
            resolution: DecisionResolution::Cancelled,
            choice_id: None,
        })
        .unwrap();
        assert_eq!(v["type"], "decision_resolved");
    }

    // ── DiffStatus / DiffLineKind / DiffLine / DiffHunk / DiffFile (W2 — curated-agent-views)

    #[test]
    fn every_diff_status_variant_round_trips_snake_case() {
        let cases = [
            (DiffStatus::Added, "\"added\""),
            (DiffStatus::Removed, "\"removed\""),
            (DiffStatus::Modified, "\"modified\""),
            (DiffStatus::Renamed, "\"renamed\""),
        ];
        for (variant, wire) in cases {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(
                json, wire,
                "DiffStatus::{variant:?} must serialize as {wire}"
            );
            let back: DiffStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn every_diff_line_kind_variant_round_trips_snake_case() {
        let cases = [
            (DiffLineKind::Context, "\"context\""),
            (DiffLineKind::Added, "\"added\""),
            (DiffLineKind::Removed, "\"removed\""),
            (DiffLineKind::Meta, "\"meta\""),
        ];
        for (variant, wire) in cases {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(
                json, wire,
                "DiffLineKind::{variant:?} must serialize as {wire}"
            );
            let back: DiffLineKind = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn diff_file_with_hunks_rename_and_every_line_kind_round_trips_byte_for_byte() {
        let file = DiffFile {
            path: "src/new_name.rs".into(),
            old_path: Some("src/old_name.rs".into()),
            status: DiffStatus::Renamed,
            additions: 2,
            deletions: 1,
            hunks: vec![DiffHunk {
                header: "@@ -1,3 +1,4 @@ fn main".into(),
                old_start: 1,
                new_start: 1,
                lines: vec![
                    DiffLine {
                        kind: DiffLineKind::Context,
                        old_n: Some(1),
                        new_n: Some(1),
                        text: "fn main() {".into(),
                    },
                    DiffLine {
                        kind: DiffLineKind::Removed,
                        old_n: Some(2),
                        new_n: None,
                        text: "    old();".into(),
                    },
                    DiffLine {
                        kind: DiffLineKind::Added,
                        old_n: None,
                        new_n: Some(2),
                        text: "    new();".into(),
                    },
                    DiffLine {
                        kind: DiffLineKind::Added,
                        old_n: None,
                        new_n: Some(3),
                        text: "    also_new();".into(),
                    },
                    DiffLine {
                        kind: DiffLineKind::Meta,
                        old_n: None,
                        new_n: None,
                        text: "\\ No newline at end of file".into(),
                    },
                ],
            }],
        };
        let json = serde_json::to_string(&file).unwrap();
        let back: DiffFile = serde_json::from_str(&json).unwrap();
        assert_eq!(file, back, "DiffFile round trip mismatch: {json}");
        let json2 = serde_json::to_string(&back).unwrap();
        assert_eq!(json, json2, "byte-for-byte round trip mismatch");
    }

    #[test]
    fn pane_content_wire_code_round_trips_and_carries_kind_code() {
        let code = PaneContentWire::Code {
            path: "src/main.rs".into(),
            revision: "working".into(),
            first_line: 1,
            text: "fn main() {}\n".into(),
        };
        let json = serde_json::to_value(&code).unwrap();
        assert_eq!(json["kind"], "code");
        let back: PaneContentWire = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(back, code);
        let json2 = serde_json::to_value(&back).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn pane_content_wire_diff_round_trips_carries_kind_diff_and_omits_number_when_none() {
        let diff_file = DiffFile {
            path: "src/main.rs".into(),
            old_path: None,
            status: DiffStatus::Modified,
            additions: 1,
            deletions: 0,
            hunks: vec![],
        };
        let diff = PaneContentWire::Diff {
            repo: "acme/web".into(),
            number: None,
            files: vec![diff_file.clone()],
            too_large: false,
            changed_files: 1,
        };
        let json = serde_json::to_value(&diff).unwrap();
        assert_eq!(json["kind"], "diff");
        assert!(
            json.get("number").is_none(),
            "number: None must be omitted from the wire entirely"
        );
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, diff);

        // With Some(number), the key IS present, carrying the number.
        let diff_with_number = PaneContentWire::Diff {
            repo: "acme/web".into(),
            number: Some(42),
            files: vec![diff_file],
            too_large: false,
            changed_files: 1,
        };
        let json2 = serde_json::to_value(&diff_with_number).unwrap();
        assert_eq!(json2["number"], 42);
        let back2: PaneContentWire = serde_json::from_value(json2).unwrap();
        assert_eq!(back2, diff_with_number);
    }

    #[test]
    fn server_msg_pane_content_round_trips_with_code_and_diff_variants() {
        round_trip_server(ServerMsg::PaneContent {
            tag: "cody".into(),
            pane_id: "file".into(),
            content: PaneContentWire::Code {
                path: "src/lib.rs".into(),
                revision: "abc123".into(),
                first_line: 1,
                text: "pub fn f() {}".into(),
            },
            freshness: None,
            address: None,
        });

        round_trip_server(ServerMsg::PaneContent {
            tag: "perri".into(),
            pane_id: "diff".into(),
            content: PaneContentWire::Diff {
                repo: "acme/web".into(),
                number: Some(7),
                files: vec![DiffFile {
                    path: "a.rs".into(),
                    old_path: None,
                    status: DiffStatus::Added,
                    additions: 5,
                    deletions: 0,
                    hunks: vec![DiffHunk {
                        header: "@@ -0,0 +1,5 @@".into(),
                        old_start: 0,
                        new_start: 1,
                        lines: vec![DiffLine {
                            kind: DiffLineKind::Added,
                            old_n: None,
                            new_n: Some(1),
                            text: "fn a() {}".into(),
                        }],
                    }],
                }],
                too_large: false,
                changed_files: 1,
            },
            freshness: None,
            address: None,
        });

        // The too_large gate: empty files, changed_files carried separately.
        round_trip_server(ServerMsg::PaneContent {
            tag: "perri".into(),
            pane_id: "diff".into(),
            content: PaneContentWire::Diff {
                repo: "acme/web".into(),
                number: Some(137),
                files: vec![],
                too_large: true,
                changed_files: 137,
            },
            freshness: None,
            address: None,
        });
    }

    // ── MdBlock / MdSpan (W3 — curated-agent-views) ─────────────────────────────

    #[test]
    fn every_md_block_variant_round_trips() {
        let cases = vec![
            MdBlock::Paragraph {
                spans: vec![MdSpan::Text { text: "hi".into() }],
            },
            MdBlock::Heading {
                level: 2,
                spans: vec![MdSpan::Text {
                    text: "title".into(),
                }],
            },
            MdBlock::CodeBlock {
                lang: Some("rust".into()),
                text: "fn f() {}\n".into(),
            },
            MdBlock::CodeBlock {
                lang: None,
                text: "plain\n".into(),
            },
            MdBlock::List {
                ordered: false,
                start: None,
                items: vec![vec![MdBlock::Paragraph {
                    spans: vec![MdSpan::Text {
                        text: "item".into(),
                    }],
                }]],
            },
            MdBlock::List {
                ordered: true,
                start: Some(3),
                items: vec![
                    vec![MdBlock::Paragraph {
                        spans: vec![MdSpan::Text { text: "foo".into() }],
                    }],
                    vec![MdBlock::Paragraph {
                        spans: vec![MdSpan::Text { text: "bar".into() }],
                    }],
                ],
            },
            MdBlock::Quote {
                blocks: vec![MdBlock::Paragraph {
                    spans: vec![MdSpan::Text {
                        text: "quoted".into(),
                    }],
                }],
            },
            MdBlock::Table {
                header: vec![vec![MdSpan::Text { text: "a".into() }]],
                rows: vec![vec![vec![MdSpan::Text { text: "1".into() }]]],
            },
            MdBlock::Rule,
        ];
        for block in cases {
            let json = serde_json::to_string(&block).unwrap();
            let back: MdBlock = serde_json::from_str(&json).unwrap();
            assert_eq!(block, back, "MdBlock round trip mismatch: {json}");
            let json2 = serde_json::to_string(&back).unwrap();
            assert_eq!(json, json2, "byte-for-byte round trip mismatch: {json}");
        }
    }

    #[test]
    fn code_block_omits_lang_key_when_none_and_carries_it_when_some() {
        let none_json = serde_json::to_value(&MdBlock::CodeBlock {
            lang: None,
            text: "x".into(),
        })
        .unwrap();
        assert!(
            none_json.get("lang").is_none(),
            "lang: None must be omitted entirely, got: {none_json}"
        );

        let some_json = serde_json::to_value(&MdBlock::CodeBlock {
            lang: Some("go".into()),
            text: "x".into(),
        })
        .unwrap();
        assert_eq!(some_json["lang"], "go");
    }

    #[test]
    fn every_md_span_variant_round_trips() {
        let cases = vec![
            MdSpan::Text { text: "hi".into() },
            MdSpan::Code {
                text: "x = 1".into(),
            },
            MdSpan::Emph {
                spans: vec![MdSpan::Text { text: "em".into() }],
            },
            MdSpan::Strong {
                spans: vec![MdSpan::Text {
                    text: "strong".into(),
                }],
            },
            MdSpan::Strike {
                spans: vec![MdSpan::Text {
                    text: "struck".into(),
                }],
            },
            MdSpan::Link {
                spans: vec![MdSpan::Text {
                    text: "text".into(),
                }],
                url: "http://example.com".into(),
            },
            MdSpan::Image {
                alt: "alt".into(),
                url: "http://example.com/img.png".into(),
            },
        ];
        for span in cases {
            let json = serde_json::to_string(&span).unwrap();
            let back: MdSpan = serde_json::from_str(&json).unwrap();
            assert_eq!(span, back, "MdSpan round trip mismatch: {json}");
            let json2 = serde_json::to_string(&back).unwrap();
            assert_eq!(json, json2, "byte-for-byte round trip mismatch: {json}");
        }
    }

    // ── ConversationThreadKind / ConversationComment / ConversationThread
    //    (W3 — curated-agent-views) ──────────────────────────────────────────

    #[test]
    fn every_conversation_thread_kind_variant_round_trips_snake_case() {
        let cases = [
            (ConversationThreadKind::Issue, "\"issue\""),
            (ConversationThreadKind::Review, "\"review\""),
            (ConversationThreadKind::Inline, "\"inline\""),
        ];
        for (variant, wire) in cases {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(
                json, wire,
                "ConversationThreadKind::{variant:?} must serialize as {wire}"
            );
            let back: ConversationThreadKind = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn conversation_comment_round_trips() {
        let comment = ConversationComment {
            id: "123".into(),
            author: "alice".into(),
            created_at: chrono::DateTime::parse_from_rfc3339("2024-01-01T00:00:00Z")
                .unwrap()
                .with_timezone(&chrono::Utc),
            body: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text { text: "hi".into() }],
            }],
        };
        let json = serde_json::to_string(&comment).unwrap();
        let back: ConversationComment = serde_json::from_str(&json).unwrap();
        assert_eq!(
            comment, back,
            "ConversationComment round trip mismatch: {json}"
        );
    }

    #[test]
    fn conversation_thread_with_no_inline_fields_round_trips_and_omits_them() {
        // An issue/review thread: path/line/diff_hunk all None.
        let thread = ConversationThread {
            id: "issue-1".into(),
            kind: ConversationThreadKind::Issue,
            path: None,
            line: None,
            diff_hunk: None,
            resolved: false,
            comments: vec![ConversationComment {
                id: "1".into(),
                author: "alice".into(),
                created_at: chrono::Utc::now(),
                body: vec![MdBlock::Paragraph {
                    spans: vec![MdSpan::Text { text: "hi".into() }],
                }],
            }],
        };
        let json = serde_json::to_value(&thread).unwrap();
        assert!(json.get("path").is_none());
        assert!(json.get("line").is_none());
        assert!(json.get("diff_hunk").is_none());
        let back: ConversationThread = serde_json::from_value(json).unwrap();
        assert_eq!(thread, back);
    }

    #[test]
    fn conversation_thread_with_all_inline_fields_round_trips_and_carries_them() {
        // An inline thread: path/line/diff_hunk all Some.
        let thread = ConversationThread {
            id: "inline-1".into(),
            kind: ConversationThreadKind::Inline,
            path: Some("src/main.rs".into()),
            line: Some(42),
            diff_hunk: Some("@@ -1,3 +1,3 @@".into()),
            resolved: false,
            comments: vec![ConversationComment {
                id: "1".into(),
                author: "alice".into(),
                created_at: chrono::Utc::now(),
                body: vec![MdBlock::Paragraph {
                    spans: vec![MdSpan::Text { text: "hi".into() }],
                }],
            }],
        };
        let json = serde_json::to_value(&thread).unwrap();
        assert_eq!(json["path"], "src/main.rs");
        assert_eq!(json["line"], 42);
        assert_eq!(json["diff_hunk"], "@@ -1,3 +1,3 @@");
        let back: ConversationThread = serde_json::from_value(json).unwrap();
        assert_eq!(thread, back);
    }

    // ── PaneContentWire::PrConversation (W3 — curated-agent-views) ──────────────

    fn sample_conversation_thread() -> ConversationThread {
        ConversationThread {
            id: "issue-1".into(),
            kind: ConversationThreadKind::Issue,
            path: None,
            line: None,
            diff_hunk: None,
            resolved: false,
            comments: vec![ConversationComment {
                id: "1".into(),
                author: "alice".into(),
                created_at: chrono::Utc::now(),
                body: vec![MdBlock::Paragraph {
                    spans: vec![MdSpan::Text { text: "hi".into() }],
                }],
            }],
        }
    }

    #[test]
    fn pane_content_wire_pr_conversation_round_trips_and_carries_kind_pr_conversation() {
        let content = PaneContentWire::PrConversation {
            repo: "acme/web".into(),
            number: Some(42),
            title: "Add widget".into(),
            author: "alice".into(),
            url: "https://github.com/acme/web/pull/42".into(),
            body: vec![MdBlock::CodeBlock {
                lang: Some("rust".into()),
                text: "fn f() {}\n".into(),
            }],
            threads: vec![sample_conversation_thread()],
            conversation_error: None,
        };
        let json = serde_json::to_value(&content).unwrap();
        assert_eq!(json["kind"], "pr_conversation");
        let back: PaneContentWire = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(back, content);
        let json2 = serde_json::to_value(&back).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn pane_content_wire_pr_conversation_omits_conversation_error_key_when_none() {
        let content = PaneContentWire::PrConversation {
            repo: "acme/web".into(),
            number: None,
            title: "Add widget".into(),
            author: "alice".into(),
            url: "https://github.com/acme/web/pull/42".into(),
            body: vec![],
            threads: vec![],
            conversation_error: None,
        };
        let json = serde_json::to_value(&content).unwrap();
        assert!(
            json.get("conversation_error").is_none(),
            "conversation_error: None must be omitted from the wire entirely, matching the \
             Diff.number precedent, got: {json}"
        );
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, content);
    }

    #[test]
    fn pane_content_wire_pr_conversation_carries_conversation_error_when_some() {
        let content = PaneContentWire::PrConversation {
            repo: "acme/web".into(),
            number: Some(42),
            title: "Add widget".into(),
            author: "alice".into(),
            url: "https://github.com/acme/web/pull/42".into(),
            body: vec![],
            threads: vec![],
            conversation_error: Some("conversation fetch partially failed: reviews".into()),
        };
        let json = serde_json::to_value(&content).unwrap();
        assert_eq!(
            json["conversation_error"],
            "conversation fetch partially failed: reviews"
        );
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, content);
    }

    // ── TicketSection / TicketComment (W4 — curated-agent-views) ─────────────

    #[test]
    fn ticket_section_round_trips_and_omits_heading_key_when_none() {
        let section = TicketSection {
            name: "description".into(),
            heading: None,
            blocks: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text { text: "hi".into() }],
            }],
        };
        let json = serde_json::to_value(&section).unwrap();
        assert!(
            json.get("heading").is_none(),
            "heading: None must be omitted entirely, got: {json}"
        );
        let back: TicketSection = serde_json::from_value(json).unwrap();
        assert_eq!(back, section);
    }

    #[test]
    fn ticket_section_round_trips_and_carries_heading_when_some() {
        let section = TicketSection {
            name: "acceptance_criteria".into(),
            heading: Some(vec![MdSpan::Text { text: "AC".into() }]),
            blocks: vec![],
        };
        let json = serde_json::to_value(&section).unwrap();
        assert_eq!(
            json["heading"],
            serde_json::json!([{ "kind": "text", "text": "AC" }])
        );
        let back: TicketSection = serde_json::from_value(json).unwrap();
        assert_eq!(back, section);
    }

    #[test]
    fn ticket_comment_round_trips() {
        let comment = TicketComment {
            index: 1,
            author: "alice".into(),
            created_at: chrono::DateTime::parse_from_rfc3339("2024-01-01T00:00:00Z")
                .unwrap()
                .with_timezone(&chrono::Utc),
            blocks: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "a comment".into(),
                }],
            }],
        };
        let json = serde_json::to_string(&comment).unwrap();
        let back: TicketComment = serde_json::from_str(&json).unwrap();
        assert_eq!(comment, back, "TicketComment round trip mismatch: {json}");
    }

    // ── PaneContentWire::Ticket (W4 — curated-agent-views) ───────────────────

    fn sample_ticket_section() -> TicketSection {
        TicketSection {
            name: "acceptance_criteria".into(),
            heading: Some(vec![MdSpan::Text { text: "AC".into() }]),
            blocks: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "Must work.".into(),
                }],
            }],
        }
    }

    fn sample_ticket_comment() -> TicketComment {
        TicketComment {
            index: 1,
            author: "bob".into(),
            created_at: chrono::Utc::now(),
            blocks: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "a comment".into(),
                }],
            }],
        }
    }

    #[test]
    fn pane_content_wire_ticket_round_trips_and_carries_kind_ticket() {
        let content = PaneContentWire::Ticket {
            provider: "jira".into(),
            key: "PROJ-1".into(),
            summary: "Fix the thing".into(),
            status: "In Progress".into(),
            assignee: Some("Alice".into()),
            url: "https://acme.atlassian.net/browse/PROJ-1".into(),
            sections: vec![sample_ticket_section()],
            comments: vec![sample_ticket_comment()],
        };
        let json = serde_json::to_value(&content).unwrap();
        assert_eq!(json["kind"], "ticket");
        let back: PaneContentWire = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(back, content);
        let json2 = serde_json::to_value(&back).unwrap();
        assert_eq!(json, json2);
    }

    #[test]
    fn pane_content_wire_ticket_omits_assignee_key_when_none() {
        let content = PaneContentWire::Ticket {
            provider: "jira".into(),
            key: "PROJ-1".into(),
            summary: "Fix the thing".into(),
            status: "Open".into(),
            assignee: None,
            url: "https://acme.atlassian.net/browse/PROJ-1".into(),
            sections: vec![],
            comments: vec![],
        };
        let json = serde_json::to_value(&content).unwrap();
        assert!(
            json.get("assignee").is_none(),
            "assignee: None must be omitted from the wire entirely, got: {json}"
        );
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, content);
    }

    #[test]
    fn pane_content_wire_ticket_carries_assignee_when_some() {
        let content = PaneContentWire::Ticket {
            provider: "jira".into(),
            key: "PROJ-1".into(),
            summary: "Fix the thing".into(),
            status: "Open".into(),
            assignee: Some("Alice".into()),
            url: "https://acme.atlassian.net/browse/PROJ-1".into(),
            sections: vec![],
            comments: vec![],
        };
        let json = serde_json::to_value(&content).unwrap();
        assert_eq!(json["assignee"], "Alice");
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, content);
    }

    // ── PaneTree::remove_tab (the tab × button) ───────────────────────────────

    fn leaf(id: &str) -> PaneTree {
        PaneTree::Leaf { pane_id: id.into() }
    }

    fn tabs(ids: &[&str], active: usize) -> PaneTree {
        PaneTree::Tabs {
            children: ids.iter().map(|i| leaf(i)).collect(),
            labels: ids.iter().map(|i| i.to_string()).collect(),
            active,
            region: Some("detail".into()),
        }
    }

    /// queue | detail-tabs over repl — the shape a curated Perri focus has.
    fn curated(detail: &[&str], active: usize) -> PaneTree {
        PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![
                PaneTree::Split {
                    direction: SplitDirection::Horizontal,
                    children: vec![leaf("queue"), tabs(detail, active)],
                    ratios: vec![0.5, 0.5],
                },
                leaf("repl"),
            ],
            ratios: vec![0.6, 0.4],
        }
    }

    fn only_tabs(tree: &PaneTree) -> (&Vec<PaneTree>, &Vec<String>, usize) {
        match tree {
            PaneTree::Tabs {
                children,
                labels,
                active,
                ..
            } => (children, labels, *active),
            PaneTree::Split { children, .. } => children
                .iter()
                .find_map(|c| {
                    if let PaneTree::Tabs { .. } | PaneTree::Split { .. } = c {
                        Some(only_tabs(c))
                    } else {
                        None
                    }
                })
                .expect("a tabs node"),
            PaneTree::Leaf { .. } => panic!("no tabs node"),
        }
    }

    #[test]
    fn closing_a_tab_before_the_active_one_keeps_the_same_tab_active() {
        let mut t = curated(&["detail.0", "detail.1", "detail.2"], 2);
        assert!(t.remove_tab("detail.0"));
        let (children, labels, active) = only_tabs(&t);
        assert_eq!(
            labels,
            &vec!["detail.1".to_string(), "detail.2".to_string()]
        );
        assert_eq!(children.len(), 2);
        assert_eq!(
            active, 1,
            "detail.2 is now at index 1 and must still be the active tab"
        );
    }

    #[test]
    fn closing_the_active_tab_activates_the_one_that_slides_into_place() {
        let mut t = curated(&["detail.0", "detail.1", "detail.2"], 1);
        assert!(t.remove_tab("detail.1"));
        let (_, labels, active) = only_tabs(&t);
        assert_eq!(labels[active], "detail.2", "the next tab takes over");
    }

    #[test]
    fn closing_the_active_last_tab_activates_the_previous_one() {
        let mut t = curated(&["detail.0", "detail.1"], 1);
        assert!(t.remove_tab("detail.1"));
        let (_, labels, active) = only_tabs(&t);
        assert_eq!(labels[active], "detail.0");
    }

    #[test]
    fn closing_a_tab_after_the_active_one_leaves_active_alone() {
        let mut t = curated(&["detail.0", "detail.1", "detail.2"], 0);
        assert!(t.remove_tab("detail.2"));
        let (_, labels, active) = only_tabs(&t);
        assert_eq!(labels[active], "detail.0");
    }

    #[test]
    fn closing_the_last_tab_removes_the_region_and_collapses_the_split() {
        let mut t = curated(&["detail.0"], 0);
        assert!(t.remove_tab("detail.0"));
        // queue | (gone) collapses to the bare queue leaf; the outer split keeps repl.
        assert_eq!(t.pane_ids(), vec!["queue".to_string(), "repl".to_string()]);
        match &t {
            PaneTree::Split {
                children, ratios, ..
            } => {
                assert_eq!(children.len(), 2);
                assert_eq!(ratios.len(), 2);
                assert!((ratios.iter().sum::<f32>() - 1.0).abs() < 1e-5);
            }
            other => panic!("expected the outer split to survive, got {other:?}"),
        }
    }

    #[test]
    fn a_pane_that_is_not_a_tab_is_not_removed() {
        let mut t = curated(&["detail.0", "detail.1"], 0);
        let before = t.clone();
        assert!(!t.remove_tab("repl"), "a plain leaf is not a tab");
        assert!(!t.remove_tab("queue"), "a plain leaf is not a tab");
        assert!(!t.remove_tab("nope"), "an unknown id is not a tab");
        assert_eq!(t, before, "a refused removal must change nothing");
    }

    #[test]
    fn the_only_tab_of_a_tabs_node_that_is_the_whole_tree_is_not_removed() {
        let mut t = tabs(&["detail.0"], 0);
        let before = t.clone();
        assert!(!t.remove_tab("detail.0"));
        assert_eq!(t, before);
    }
}

#[cfg(test)]
mod work_wire_tests {
    use super::*;
    use crate::data::work::{
        GroupError, Link, Pick, PicksSnapshot, Priority, SendOutcome, SendPreview, SentMarker,
        SourceState, SourceStatus, WorkDetail, WorkError, WorkItem, WorkResult, WorkSource,
    };

    fn ts() -> chrono::DateTime<chrono::Utc> {
        "2026-10-09T14:30:00Z".parse().unwrap()
    }

    fn item() -> WorkItem {
        WorkItem {
            id: "jira:CORE-1".into(),
            source: WorkSource::Jira,
            kind: "story".into(),
            title: "Fix the thing".into(),
            repo: None,
            project: Some("CORE".into()),
            status: Some("In Progress".into()),
            status_category: Some("in_progress".into()),
            priority: Some(Priority {
                label: "High".into(),
                rank: 2,
            }),
            severity: None,
            environment: None,
            assignee: None,
            created_at: Some(ts()),
            updated_at: Some(ts()),
            due: Some("2026-10-12".parse().unwrap()),
            url: Some("https://example.invalid/CORE-1".into()),
            path: None,
            metrics: [("events".to_string(), 3)].into_iter().collect(),
            linked: vec!["todo:abc".into()],
            search_text: "fix the thing".into(),
            sent: vec![SentMarker {
                kind: "focus".into(),
                target_id: "core-1".into(),
                label: "CORE-1".into(),
                created_at: ts(),
                nonce: None,
            }],
        }
    }

    fn status() -> SourceStatus {
        SourceStatus {
            source: WorkSource::Jira,
            state: SourceState::RateLimited,
            updated_at: Some(ts()),
            reason: Some("slow down".into()),
            retry_at: Some(ts()),
            count: 4,
            group_errors: vec![GroupError {
                group: "repo".into(),
                reason: "boom".into(),
            }],
            complete: true,
        }
    }

    fn round_trip_server(msg: ServerMsg) -> String {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ServerMsg = serde_json::from_str(&json).unwrap();
        assert_eq!(
            json,
            serde_json::to_string(&back).unwrap(),
            "mismatch: {json}"
        );
        json
    }

    fn round_trip_client(msg: ClientMsg) -> String {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ClientMsg = serde_json::from_str(&json).unwrap();
        assert_eq!(
            json,
            serde_json::to_string(&back).unwrap(),
            "mismatch: {json}"
        );
        json
    }

    #[test]
    fn a_status_without_complete_from_an_older_sender_decodes_as_not_complete() {
        // "Completeness unknown" must never read as "complete".
        let minimal: SourceStatus =
            serde_json::from_str(r#"{"source":"jira","state":"fresh"}"#).unwrap();
        assert!(!minimal.complete);
        assert_eq!(minimal.state, SourceState::Fresh);
        assert_eq!(minimal.count, 0);

        // The same through a whole frame: drop `complete` from what this build sends.
        let mut frame =
            serde_json::to_value(ServerMsg::WorkSourceStatus { status: status() }).unwrap();
        let sent = frame
            .pointer_mut("/status")
            .and_then(|s| s.as_object_mut())
            .expect("a status object");
        assert_eq!(
            sent.remove("complete"),
            Some(serde_json::json!(true)),
            "this build always sends it"
        );
        let ServerMsg::WorkSourceStatus { status: decoded } =
            serde_json::from_value(frame).unwrap()
        else {
            panic!("not a WorkSourceStatus frame");
        };
        assert!(!decoded.complete, "absent decodes as false, deliberately");
        assert_eq!(decoded.count, 4, "everything else is read as sent");
    }

    #[test]
    fn complete_is_always_sent_and_survives_a_round_trip_either_way() {
        for complete in [true, false] {
            let sent = SourceStatus {
                complete,
                ..status()
            };
            let json = serde_json::to_string(&ServerMsg::WorkSourceStatus {
                status: sent.clone(),
            })
            .unwrap();
            assert!(
                json.contains(&format!("\"complete\":{complete}")),
                "always on the wire, even when false: {json}"
            );
            let ServerMsg::WorkSourceStatus { status: back } = serde_json::from_str(&json).unwrap()
            else {
                panic!("not a WorkSourceStatus frame");
            };
            assert_eq!(back, sent);
            assert_eq!(back.complete, complete);
        }
    }

    #[test]
    fn work_topic_serializes_to_work() {
        assert_eq!(serde_json::to_string(&Topic::Work).unwrap(), "\"work\"");
    }

    #[test]
    fn work_server_frames_round_trip() {
        round_trip_server(ServerMsg::WorkSourceStatus { status: status() });
        round_trip_server(ServerMsg::WorkSnapshot {
            source: WorkSource::RepoDocs,
            group: Some("nostromo".into()),
            items: vec![item()],
        });
        round_trip_server(ServerMsg::WorkSnapshot {
            source: WorkSource::Todos,
            group: None,
            items: vec![],
        });
        round_trip_server(ServerMsg::TeriPicks {
            picks: PicksSnapshot {
                generated_at: Some(ts()),
                generating: false,
                unavailable_sources: vec![WorkSource::Sentry],
                items: vec![Pick {
                    item_id: "jira:CORE-1".into(),
                    source: WorkSource::Jira,
                    title: "Fix the thing".into(),
                    reason: "due soon".into(),
                    done_since: false,
                }],
                error: None,
            },
        });
        round_trip_server(ServerMsg::WorkDetail {
            request_id: "r1".into(),
            result: WorkResult::Ok(WorkDetail {
                item_id: "jira:CORE-1".into(),
                title: "Fix the thing".into(),
                fields: vec![("Status".into(), "In Progress".into())],
                markdown: "# hi".into(),
                files: vec!["a.md".into()],
                links: vec![Link {
                    label: "Open".into(),
                    url: "https://example.invalid".into(),
                }],
            }),
        });
        round_trip_server(ServerMsg::WorkDetail {
            request_id: "r1".into(),
            result: WorkResult::Err(WorkError::not_available()),
        });
        round_trip_server(ServerMsg::WorkSendPreview {
            request_id: "r2".into(),
            result: WorkResult::Ok(SendPreview {
                item_id: "jira:CORE-1".into(),
                agent: "claude".into(),
                working_directory: Some("/tmp/repo".into()),
                label: "CORE-1".into(),
                instruction: "Propose an approach".into(),
                context: "do it".into(),
                existing: vec![],
            }),
        });
        round_trip_server(ServerMsg::WorkSendResult {
            request_id: "r3".into(),
            result: WorkResult::Ok(SendOutcome {
                kind: "seeded".into(),
                focus_tag: Some("fred".into()),
                job_id: None,
            }),
        });
        round_trip_server(ServerMsg::WorkSendResult {
            request_id: "r3".into(),
            result: WorkResult::Err(WorkError::requires_secure_connection()),
        });
        round_trip_server(ServerMsg::Withheld {
            topics: vec![Topic::Fred, Topic::Teri, Topic::Work],
            reason: "requires_secure_connection".into(),
        });
    }

    #[test]
    fn work_client_frames_round_trip() {
        round_trip_client(ClientMsg::WorkDetailRequest {
            request_id: "r1".into(),
            item_id: "mail:abc".into(),
        });
        round_trip_client(ClientMsg::WorkRefresh {
            source: Some(WorkSource::Jira),
            fred: false,
        });
        round_trip_client(ClientMsg::WorkRefresh {
            source: None,
            fred: true,
        });
        round_trip_client(ClientMsg::PicksRefresh {
            reason: "manual".into(),
        });
        round_trip_client(ClientMsg::WorkSendPreviewRequest {
            request_id: "r2".into(),
            item_id: "todo:1".into(),
        });
        round_trip_client(ClientMsg::WorkSend {
            request_id: "r3".into(),
            item_id: "todo:1".into(),
            destination: "focus".into(),
            agent: "claude".into(),
            working_directory: Some("/tmp/repo".into()),
            label: "a".into(),
            instruction: "b".into(),
            allow_duplicate: true,
        });
        round_trip_client(ClientMsg::FredSeed {
            request_id: "r4".into(),
            text: "hi".into(),
        });
    }

    #[test]
    fn work_client_frames_tolerate_missing_optional_fields() {
        let m: ClientMsg = serde_json::from_str(r#"{"type":"work_refresh"}"#).unwrap();
        assert!(matches!(
            m,
            ClientMsg::WorkRefresh {
                source: None,
                fred: false
            }
        ));
        let m: ClientMsg = serde_json::from_str(
            r#"{"type":"work_send","request_id":"r","item_id":"i","destination":"focus","agent":"a","label":"l","context":"c"}"#,
        )
        .unwrap();
        // An old client's frame (`context`, no `instruction`) still decodes; the
        // item's text is never taken from the client, so `context` is dropped.
        assert!(matches!(
            m,
            ClientMsg::WorkSend { working_directory: None, allow_duplicate: false, ref instruction, .. }
                if instruction.is_empty()
        ));
    }

    #[test]
    fn focus_meta_new_fields_round_trip_and_old_json_decodes() {
        let json = r#"{"tag":"t","display_name":"T","agent_name":"cody","is_built_in":false}"#;
        let old: FocusMeta = serde_json::from_str(json).unwrap();
        assert_eq!(old.label, None);
        assert_eq!(old.project_path, None);
        assert_eq!(old.select_for_client, None);
        let out = serde_json::to_string(&old).unwrap();
        assert!(
            !out.contains("label")
                && !out.contains("project_path")
                && !out.contains("select_for_client")
        );

        let mut full = old;
        full.label = Some("CORE-1".into());
        full.project_path = Some("/tmp/repo".into());
        full.select_for_client = Some("client-1".into());
        let back: FocusMeta = serde_json::from_str(&serde_json::to_string(&full).unwrap()).unwrap();
        assert_eq!(back, full);
    }

    // ── background tasks ────────────────────────────────────────────────────

    fn bare_task_meta() -> TaskMeta {
        TaskMeta {
            id: "t1".into(),
            run_id: None,
            task_type: "local_bash".into(),
            kind: TaskKind::Shell,
            tool_name: None,
            description: "Run it".into(),
            subagent_type: None,
            workflow_name: None,
            tool_use_id: None,
            parent_task_id: None,
            is_backgrounded: None,
            housekeeping: false,
            status: TaskStatus::Running,
            end_reason: None,
            started_at_ms: None,
            ended_at_ms: None,
            duration_ms: None,
            total_tokens: None,
            tool_uses: None,
            last_tool_name: None,
            has_output: true,
        }
    }

    #[test]
    fn a_bare_task_meta_serialises_only_its_required_keys() {
        let value = serde_json::to_value(bare_task_meta()).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "description",
                "has_output",
                "housekeeping",
                "id",
                "kind",
                "status",
                "task_type"
            ]
        );
    }

    #[test]
    fn session_tasks_round_trips_with_and_without_its_optional_fields() {
        let bare = ServerMsg::SessionTasks {
            tag: "cody-x".into(),
            session_id: None,
            daemon_epoch: "epoch-1".into(),
            stop_supported: None,
            tasks: vec![bare_task_meta()],
        };
        let json = serde_json::to_string(&bare).unwrap();
        assert!(
            !json.contains("session_id") && !json.contains("stop_supported"),
            "{json}"
        );
        round_trip_server(bare);

        let mut full = bare_task_meta();
        full.run_id = Some("run-1".into());
        full.tool_name = Some("Bash".into());
        full.end_reason = Some(TaskEndReason::Vanished);
        full.status = TaskStatus::Stopped;
        full.total_tokens = Some(0);
        round_trip_server(ServerMsg::SessionTasks {
            tag: "cody-x".into(),
            session_id: Some("sess".into()),
            daemon_epoch: "epoch-1".into(),
            stop_supported: Some(false),
            tasks: vec![full, bare_task_meta()],
        });
    }

    #[test]
    fn an_empty_task_list_is_a_real_frame() {
        let msg = ServerMsg::SessionTasks {
            tag: "t".into(),
            session_id: None,
            daemon_epoch: "e".into(),
            stop_supported: None,
            tasks: vec![],
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""tasks":[]"#), "{json}");
        round_trip_server(msg);
    }

    #[test]
    fn session_task_detail_round_trips_and_omits_what_is_unset() {
        let only_preview = ServerMsg::SessionTaskDetail {
            tag: "cody-x".into(),
            task_id: "t1".into(),
            preview: Some("building 3/9".into()),
            progress_summary: None,
            completion_summary: None,
            prompt: None,
        };
        let json = serde_json::to_string(&only_preview).unwrap();
        assert!(
            !json.contains("progress_summary")
                && !json.contains("completion_summary")
                && !json.contains("prompt"),
            "{json}"
        );
        assert!(json.contains(r#""preview":"building 3/9""#));
        round_trip_server(only_preview);

        round_trip_server(ServerMsg::SessionTaskDetail {
            tag: "cody-x".into(),
            task_id: "t1".into(),
            preview: Some("p".into()),
            progress_summary: Some("a".into()),
            completion_summary: Some("b".into()),
            prompt: Some("c".into()),
        });
        let nothing = ServerMsg::SessionTaskDetail {
            tag: "t".into(),
            task_id: "t1".into(),
            preview: None,
            progress_summary: None,
            completion_summary: None,
            prompt: None,
        };
        assert_eq!(
            serde_json::to_string(&nothing).unwrap(),
            r#"{"type":"session_task_detail","tag":"t","task_id":"t1"}"#
        );
    }

    #[test]
    fn the_task_frames_use_the_type_names_the_clients_decode() {
        let tasks = ServerMsg::SessionTasks {
            tag: "t".into(),
            session_id: None,
            daemon_epoch: "e".into(),
            stop_supported: None,
            tasks: vec![],
        };
        assert_eq!(
            serde_json::to_value(&tasks).unwrap()["type"],
            "session_tasks"
        );
        let detail = ServerMsg::SessionTaskDetail {
            tag: "t".into(),
            task_id: "x".into(),
            preview: None,
            progress_summary: None,
            completion_summary: None,
            prompt: None,
        };
        assert_eq!(
            serde_json::to_value(&detail).unwrap()["type"],
            "session_task_detail"
        );
    }

    // ── agent tracker frames (T0b) ────────────────────────────────────────────

    fn tracker_view() -> crate::tracker::TrackerBoardView {
        let source = "# Sentry triage\n\n## Now\n- [ ] Check the thing — in progress · cody · 10:42 <!-- #check-1 1760540000 -->\n";
        let parsed = crate::tracker::parse(source.as_bytes()).expect("a readable board");
        crate::tracker::view::build(
            &parsed,
            &crate::tracker::ViewFacts {
                path: "/repo/.claude/wip/sentry-triage/index.md".into(),
                topic: "sentry-triage".into(),
                version: 7,
                ..Default::default()
            },
        )
    }

    #[test]
    fn tracker_board_round_trips_with_a_board_and_with_none() {
        let json = round_trip_server(ServerMsg::TrackerBoard {
            tag: "cody-x".into(),
            board: Some(tracker_view()),
        });
        assert!(
            json.contains("Sentry triage") && json.contains("check-1"),
            "{json}"
        );

        let none = ServerMsg::TrackerBoard {
            tag: "cody-x".into(),
            board: None,
        };
        let json = round_trip_server(none.clone());
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(
            value.as_object().unwrap().contains_key("board") && value["board"].is_null(),
            "a focus with no tracker sends an explicit `board: null`: {json}"
        );
        assert!(matches!(
            serde_json::from_str::<ServerMsg>(&json).unwrap(),
            ServerMsg::TrackerBoard { board: None, .. }
        ));
    }

    #[test]
    fn tracker_summary_round_trips_and_carries_exactly_its_five_counts() {
        let counts = TrackerCounts {
            todo: 1,
            in_progress: 2,
            blocked: 3,
            needs_you: 4,
            done: 5,
        };
        let json = round_trip_server(ServerMsg::TrackerSummary {
            tag: "cody-x".into(),
            has_tracker: true,
            counts,
        });
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            value["counts"],
            serde_json::json!({"todo": 1, "in_progress": 2, "blocked": 3, "needs_you": 4, "done": 5})
        );
        assert_eq!(value["has_tracker"], true);
        match serde_json::from_str::<ServerMsg>(&json).unwrap() {
            ServerMsg::TrackerSummary {
                tag,
                has_tracker,
                counts: back,
            } => {
                assert_eq!((tag.as_str(), has_tracker, back), ("cody-x", true, counts));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_tracker_frames_use_the_type_names_the_clients_decode() {
        let board = ServerMsg::TrackerBoard {
            tag: "t".into(),
            board: None,
        };
        assert_eq!(
            serde_json::to_value(&board).unwrap()["type"],
            "tracker_board"
        );
        let summary = ServerMsg::TrackerSummary {
            tag: "t".into(),
            has_tracker: false,
            counts: TrackerCounts::default(),
        };
        assert_eq!(
            serde_json::to_value(&summary).unwrap()["type"],
            "tracker_summary"
        );
    }

    #[test]
    fn the_tracker_frames_decode_from_the_documented_wire_shape() {
        let board: ServerMsg =
            serde_json::from_str(r#"{"type":"tracker_board","tag":"t","board":null}"#).unwrap();
        assert!(matches!(board, ServerMsg::TrackerBoard { ref tag, board: None } if tag == "t"));

        let summary: ServerMsg = serde_json::from_str(
            r#"{"type":"tracker_summary","tag":"t","has_tracker":true,
                "counts":{"todo":0,"in_progress":1,"blocked":0,"needs_you":2,"done":3}}"#,
        )
        .unwrap();
        match summary {
            ServerMsg::TrackerSummary {
                tag,
                has_tracker,
                counts,
            } => {
                assert_eq!(tag, "t");
                assert!(has_tracker);
                assert_eq!(
                    (counts.in_progress, counts.needs_you, counts.done),
                    (1, 2, 3)
                );
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_task_enums_use_their_documented_wire_names() {
        fn name<T: serde::Serialize>(v: &T) -> String {
            match serde_json::to_value(v).unwrap() {
                serde_json::Value::String(s) => s,
                other => panic!("not a string: {other}"),
            }
        }
        for (kind, expected) in [
            (TaskKind::Shell, "shell"),
            (TaskKind::Monitor, "monitor"),
            (TaskKind::Agent, "agent"),
            (TaskKind::Workflow, "workflow"),
            (TaskKind::Other, "other"),
        ] {
            assert_eq!(name(&kind), expected);
        }
        for (status, expected) in [
            (TaskStatus::Pending, "pending"),
            (TaskStatus::Running, "running"),
            (TaskStatus::Paused, "paused"),
            (TaskStatus::Completed, "completed"),
            (TaskStatus::Failed, "failed"),
            (TaskStatus::Stopped, "stopped"),
        ] {
            assert_eq!(name(&status), expected);
        }
        for (reason, expected) in [
            (TaskEndReason::UserStop, "user_stop"),
            (TaskEndReason::Restart, "restart"),
            (TaskEndReason::SessionEnded, "session_ended"),
            (TaskEndReason::Vanished, "vanished"),
        ] {
            assert_eq!(name(&reason), expected);
        }
    }

    #[test]
    fn a_task_list_that_names_only_the_required_fields_decodes() {
        let json = r#"{"type":"session_tasks","tag":"t","daemon_epoch":"e","tasks":[
            {"id":"t1","task_type":"","kind":"other","description":"","housekeeping":false,"status":"running","has_output":false}]}"#;
        let msg: ServerMsg = serde_json::from_str(json).unwrap();
        let ServerMsg::SessionTasks {
            session_id,
            stop_supported,
            tasks,
            ..
        } = msg
        else {
            panic!()
        };
        assert_eq!((session_id, stop_supported), (None, None));
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].run_id, None);
        assert_eq!(
            tasks[0].total_tokens, None,
            "an absent count stays absent, not zero"
        );
    }

    #[test]
    fn a_task_detail_that_names_only_its_task_decodes() {
        let msg: ServerMsg =
            serde_json::from_str(r#"{"type":"session_task_detail","tag":"t","task_id":"x"}"#)
                .unwrap();
        assert!(matches!(
            msg,
            ServerMsg::SessionTaskDetail {
                preview: None,
                progress_summary: None,
                completion_summary: None,
                prompt: None,
                ..
            }
        ));
    }

    // ── AP0b: the approval frames (golden JSON) ───────────────────────────────
    //
    // The strings below are the wire contract (design contract section 4). The Swift
    // side (`Shared/NostromoKit/.../Approvals/ApprovalWire.swift`) must decode exactly these;
    // the NostromoKit test target has no `Fixtures/` directory, so the same strings are
    // embedded here rather than shared as a file. Each is compared as a JSON value (key
    // order is not part of the contract), and decoded and re-encoded.

    use crate::approvals::display::{ApprovalDisplay, DisplayLine, LineKind, Segment, SegmentKind};
    use crate::approvals::request::{FoundRule, McpTool, Reason, ReasonKind, ToolKind};
    use crate::approvals::wire::{
        AgentWire, AnswerRefusal, ApprovalDecision, ApprovalFlags, ApprovalOption,
        ApprovalRequestWire, DecisionKind, RefusalChannel, SubagentWire,
    };

    /// An `ApprovalRequestWire` with every optional field set.
    fn full_approval_wire() -> ApprovalRequestWire {
        ApprovalRequestWire {
            request_id: "11111111-2222-3333-4444-555555555555".into(),
            tag: "cody-1".into(),
            tool_use_id: "toolu_1".into(),
            agent: AgentWire {
                name: "cody".into(),
                subagent: Some(SubagentWire {
                    agent_id: "agent_abc".into(),
                    agent_type: Some("general-purpose".into()),
                }),
            },
            tool_name: "mcp__slack__post_message".into(),
            display_name: "Post message".into(),
            tool_kind: ToolKind::Mcp,
            mcp: Some(McpTool {
                server: "slack".into(),
                tool: "post_message".into(),
            }),
            input: serde_json::json!({ "channel": "#eng", "text": "hi", "nested": { "a": [1, 2, { "b": null }] } }),
            display: ApprovalDisplay {
                lines: vec![
                    DisplayLine {
                        number: 1,
                        kind: LineKind::Json,
                        cont: false,
                        segments: vec![
                            Segment {
                                text: "{".into(),
                                kind: SegmentKind::Plain,
                                cp: None,
                            },
                            Segment {
                                text: "\u{27E8}U+202E RLO\u{27E9}".into(),
                                kind: SegmentKind::Invisible,
                                cp: Some(0x202E),
                            },
                            Segment {
                                text: "\u{e9}".into(),
                                kind: SegmentKind::NonAscii,
                                cp: Some(0xE9),
                            },
                        ],
                    },
                    DisplayLine {
                        number: 2,
                        kind: LineKind::Command,
                        cont: true,
                        segments: vec![Segment {
                            text: "&&".into(),
                            kind: SegmentKind::Separator,
                            cp: None,
                        }],
                    },
                ],
                command_count: Some(2),
                invisible_count: 1,
                non_ascii_count: 1,
                unparsed: false,
            },
            cwd: Some("/work/proj".into()),
            reason: Reason {
                kind: ReasonKind::AskRule,
                text: "your rule Bash(rm:*) in ~/.claude/settings.json".into(),
                rule: Some(FoundRule {
                    rule: "Bash(rm:*)".into(),
                    source_path: "~/.claude/settings.json".into(),
                    found_by: "nostromo".into(),
                }),
            },
            flags: ApprovalFlags {
                default_to_no: true,
                suppress_always_allow_rule: false,
                requires_user_interaction: true,
                classifier_approvable: false,
            },
            description: Some("post a message".into()),
            options: ApprovalOption::ALL.to_vec(),
            session_rule_candidates: vec![],
            created_at_ms: 1_760_000_000_000,
            deadline_at_ms: 1_760_000_900_000,
        }
    }

    /// `full_approval_wire()` as it goes over the wire.
    const FULL_APPROVAL_WIRE_JSON: &str = r##"{
        "request_id": "11111111-2222-3333-4444-555555555555",
        "tag": "cody-1",
        "tool_use_id": "toolu_1",
        "agent": { "name": "cody", "subagent": { "agent_id": "agent_abc", "agent_type": "general-purpose" } },
        "tool_name": "mcp__slack__post_message",
        "display_name": "Post message",
        "tool_kind": "mcp",
        "mcp": { "server": "slack", "tool": "post_message" },
        "input": { "channel": "#eng", "text": "hi", "nested": { "a": [1, 2, { "b": null }] } },
        "display": {
            "lines": [
                { "number": 1, "kind": "json", "segments": [
                    { "text": "{", "kind": "plain" },
                    { "text": "⟨U+202E RLO⟩", "kind": "invisible", "cp": 8238 },
                    { "text": "é", "kind": "non_ascii", "cp": 233 }
                ] },
                { "number": 2, "kind": "command", "cont": true, "segments": [ { "text": "&&", "kind": "separator" } ] }
            ],
            "command_count": 2,
            "invisible_count": 1,
            "non_ascii_count": 1,
            "unparsed": false
        },
        "cwd": "/work/proj",
        "reason": {
            "kind": "ask_rule",
            "text": "your rule Bash(rm:*) in ~/.claude/settings.json",
            "rule": { "rule": "Bash(rm:*)", "source_path": "~/.claude/settings.json", "found_by": "nostromo" }
        },
        "flags": {
            "default_to_no": true,
            "suppress_always_allow_rule": false,
            "requires_user_interaction": true,
            "classifier_approvable": false
        },
        "description": "post a message",
        "options": ["allow_once", "deny", "deny_and_stop", "deny_with_note"],
        "session_rule_candidates": [],
        "created_at_ms": 1760000000000,
        "deadline_at_ms": 1760000900000
    }"##;

    /// An `ApprovalRequestWire` with only what is required.
    fn minimal_approval_wire() -> ApprovalRequestWire {
        ApprovalRequestWire {
            request_id: "r-min".into(),
            tag: "t".into(),
            tool_use_id: "toolu_2".into(),
            agent: AgentWire {
                name: "cody".into(),
                subagent: None,
            },
            tool_name: "Bash".into(),
            display_name: "Bash".into(),
            tool_kind: ToolKind::Bash,
            mcp: None,
            input: serde_json::json!({ "command": "ls" }),
            display: ApprovalDisplay {
                lines: vec![],
                command_count: None,
                invisible_count: 0,
                non_ascii_count: 0,
                unparsed: false,
            },
            cwd: None,
            reason: Reason {
                kind: ReasonKind::Other,
                text: "Claude Code asked for approval".into(),
                rule: None,
            },
            flags: ApprovalFlags::default(),
            description: None,
            options: vec![ApprovalOption::AllowOnce, ApprovalOption::Deny],
            session_rule_candidates: vec![],
            created_at_ms: 1,
            deadline_at_ms: 2,
        }
    }

    const MINIMAL_APPROVAL_WIRE_JSON: &str = r##"{
        "request_id": "r-min",
        "tag": "t",
        "tool_use_id": "toolu_2",
        "agent": { "name": "cody" },
        "tool_name": "Bash",
        "display_name": "Bash",
        "tool_kind": "bash",
        "input": { "command": "ls" },
        "display": { "lines": [], "invisible_count": 0, "non_ascii_count": 0, "unparsed": false },
        "reason": { "kind": "other", "text": "Claude Code asked for approval" },
        "flags": {
            "default_to_no": false,
            "suppress_always_allow_rule": false,
            "requires_user_interaction": false,
            "classifier_approvable": false
        },
        "options": ["allow_once", "deny"],
        "session_rule_candidates": [],
        "created_at_ms": 1,
        "deadline_at_ms": 2
    }"##;

    fn json(text: &str) -> serde_json::Value {
        serde_json::from_str(text).unwrap_or_else(|e| panic!("bad golden JSON ({e}): {text}"))
    }

    /// `msg` encodes to exactly `golden`, and `golden` decodes to a message that encodes the same.
    #[track_caller]
    fn assert_server_golden(msg: ServerMsg, golden: &str) {
        let encoded = serde_json::to_value(&msg).unwrap();
        assert_eq!(encoded, json(golden), "encoding changed: {encoded}");
        let decoded: ServerMsg = serde_json::from_str(golden)
            .unwrap_or_else(|e| panic!("golden does not decode ({e}): {golden}"));
        assert_eq!(
            serde_json::to_value(&decoded).unwrap(),
            json(golden),
            "decode then encode is not the identity"
        );
    }

    #[track_caller]
    fn assert_client_golden(msg: ClientMsg, golden: &str) {
        let encoded = serde_json::to_value(&msg).unwrap();
        assert_eq!(encoded, json(golden), "encoding changed: {encoded}");
        let decoded: ClientMsg = serde_json::from_str(golden)
            .unwrap_or_else(|e| panic!("golden does not decode ({e}): {golden}"));
        assert_eq!(
            serde_json::to_value(&decoded).unwrap(),
            json(golden),
            "decode then encode is not the identity"
        );
    }

    #[test]
    fn approval_request_with_every_field_populated_has_this_exact_wire_form() {
        let golden = format!(
            r#"{{"type":"approval_request","tag":"cody-1","request":{FULL_APPROVAL_WIRE_JSON}}}"#
        );
        assert_server_golden(
            ServerMsg::ApprovalRequest {
                tag: "cody-1".into(),
                request: full_approval_wire(),
            },
            &golden,
        );
        round_trip_server(ServerMsg::ApprovalRequest {
            tag: "cody-1".into(),
            request: full_approval_wire(),
        });
    }

    #[test]
    fn approval_request_with_only_the_required_fields_omits_the_optional_keys() {
        let golden = format!(
            r#"{{"type":"approval_request","tag":"t","request":{MINIMAL_APPROVAL_WIRE_JSON}}}"#
        );
        assert_server_golden(
            ServerMsg::ApprovalRequest {
                tag: "t".into(),
                request: minimal_approval_wire(),
            },
            &golden,
        );
        let v = serde_json::to_value(minimal_approval_wire()).unwrap();
        for key in ["mcp", "cwd", "description"] {
            assert!(
                v.get(key).is_none(),
                "an absent {key} is omitted, not null: {v}"
            );
        }
    }

    #[test]
    fn the_wire_input_is_the_clis_input_untouched_whatever_shape_it_has() {
        for input in [
            serde_json::json!("a bare string"),
            serde_json::json!(null),
            serde_json::json!([1, "two", { "three": [] }]),
            serde_json::json!({ "zeta": 1, "alpha": { "b": [true, null, 1.5e300, "\u{202E}x"] } }),
        ] {
            let mut wire = minimal_approval_wire();
            wire.input = input.clone();
            let v = serde_json::to_value(ServerMsg::ApprovalRequest {
                tag: "t".into(),
                request: wire,
            })
            .unwrap();
            assert_eq!(v["request"]["input"], input);
        }
    }

    #[test]
    fn approvals_snapshot_has_this_exact_wire_form_empty_and_full() {
        assert_server_golden(
            ServerMsg::ApprovalsSnapshot { requests: vec![] },
            r#"{"type":"approvals_snapshot","requests":[]}"#,
        );
        let golden = format!(
            r#"{{"type":"approvals_snapshot","requests":[{FULL_APPROVAL_WIRE_JSON},{MINIMAL_APPROVAL_WIRE_JSON}]}}"#
        );
        assert_server_golden(
            ServerMsg::ApprovalsSnapshot {
                requests: vec![full_approval_wire(), minimal_approval_wire()],
            },
            &golden,
        );
    }

    #[test]
    fn approval_resolved_has_this_exact_wire_form_with_and_without_by_window() {
        assert_server_golden(
            ServerMsg::ApprovalResolved {
                tag: "cody-1".into(),
                request_id: "r1".into(),
                outcome: "allowed_once".into(),
                by_window: Some("win-1".into()),
                at_ms: 1_760_000_000_123,
            },
            r#"{"type":"approval_resolved","tag":"cody-1","request_id":"r1","outcome":"allowed_once","by_window":"win-1","at_ms":1760000000123}"#,
        );
        assert_server_golden(
            ServerMsg::ApprovalResolved {
                tag: "cody-1".into(),
                request_id: "r1".into(),
                outcome: "timed_out".into(),
                by_window: None,
                at_ms: 7,
            },
            r#"{"type":"approval_resolved","tag":"cody-1","request_id":"r1","outcome":"timed_out","at_ms":7}"#,
        );
    }

    #[test]
    fn approval_pending_has_this_exact_wire_form_and_carries_nothing_but_a_tag_and_a_count() {
        assert_server_golden(
            ServerMsg::ApprovalPending {
                tag: "cody-1".into(),
                count: 2,
            },
            r#"{"type":"approval_pending","tag":"cody-1","count":2}"#,
        );
        let v = serde_json::to_value(ServerMsg::ApprovalPending {
            tag: "cody-1".into(),
            count: 0,
        })
        .unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            ["count", "tag", "type"],
            "the only approval frame a LAN peer may see has no room for content"
        );
    }

    #[test]
    fn approval_guard_blocked_has_this_exact_wire_form() {
        assert_server_golden(
            ServerMsg::ApprovalGuardBlocked {
                tag: "cody-1".into(),
                tool_use_id: "toolu_9".into(),
                entry_id: "entry-1".into(),
                at_ms: 5,
                summary: "Bash ecs_connect".into(),
            },
            r#"{"type":"approval_guard_blocked","tag":"cody-1","tool_use_id":"toolu_9","entry_id":"entry-1","at_ms":5,"summary":"Bash ecs_connect"}"#,
        );
    }

    #[test]
    fn approval_answer_refused_has_this_exact_wire_form_with_and_without_an_outcome() {
        assert_server_golden(
            ServerMsg::ApprovalAnswerRefused {
                request_id: "r1".into(),
                code: AnswerRefusal::AlreadyResolved,
                outcome: Some("allowed_once".into()),
            },
            r#"{"type":"approval_answer_refused","request_id":"r1","code":"already_resolved","outcome":"allowed_once"}"#,
        );
        for (code, name) in [
            (
                AnswerRefusal::RequiresSecureConnection,
                "requires_secure_connection",
            ),
            (AnswerRefusal::NotOperatorApp, "not_operator_app"),
            (AnswerRefusal::UnknownRequest, "unknown_request"),
        ] {
            assert_server_golden(
                ServerMsg::ApprovalAnswerRefused {
                    request_id: "r1".into(),
                    code,
                    outcome: None,
                },
                &format!(
                    r#"{{"type":"approval_answer_refused","request_id":"r1","code":"{name}"}}"#
                ),
            );
            assert_eq!(
                code.as_str(),
                name,
                "the audit log writes the same code the wire carries"
            );
        }
    }

    #[test]
    fn approval_answer_has_this_exact_wire_form_for_every_decision_kind() {
        assert_client_golden(
            ClientMsg::ApprovalAnswer {
                request_id: "r1".into(),
                decision: ApprovalDecision {
                    kind: DecisionKind::AllowOnce,
                    note: None,
                    answers: None,
                },
                window_id: "win-1".into(),
                operator_nonce: Some("ab12".into()),
            },
            r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"allow_once"},"window_id":"win-1","operator_nonce":"ab12"}"#,
        );
        assert_client_golden(
            ClientMsg::ApprovalAnswer {
                request_id: "r1".into(),
                decision: ApprovalDecision {
                    kind: DecisionKind::Deny,
                    note: Some("use /tmp/y".into()),
                    answers: None,
                },
                window_id: "win-1".into(),
                operator_nonce: Some("ab12".into()),
            },
            r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"deny","note":"use /tmp/y"},"window_id":"win-1","operator_nonce":"ab12"}"#,
        );
        assert_client_golden(
            ClientMsg::ApprovalAnswer {
                request_id: "r1".into(),
                decision: ApprovalDecision {
                    kind: DecisionKind::DenyAndStop,
                    note: None,
                    answers: None,
                },
                window_id: "win-2".into(),
                operator_nonce: None,
            },
            r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"deny_and_stop"},"window_id":"win-2"}"#,
        );
    }

    #[test]
    fn an_approval_answer_without_a_nonce_still_decodes_and_the_daemon_refuses_it_later() {
        // A Mac older than the nonce sends none: the frame must decode (so it can be refused
        // by name and logged), never be dropped as malformed.
        let msg: ClientMsg = serde_json::from_str(
            r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"allow_once"},"window_id":"w"}"#,
        )
        .unwrap();
        assert!(
            matches!(
                msg,
                ClientMsg::ApprovalAnswer {
                    operator_nonce: None,
                    ..
                }
            ),
            "{msg:?}"
        );
    }

    #[test]
    fn an_unknown_decision_kind_does_not_decode_so_it_can_never_be_read_as_an_allow() {
        for kind in ["allow", "allow_session", "approve", "", "ALLOW_ONCE"] {
            let text = format!(
                r#"{{"type":"approval_answer","request_id":"r1","decision":{{"kind":"{kind}"}},"window_id":"w"}}"#
            );
            assert!(
                serde_json::from_str::<ClientMsg>(&text).is_err(),
                "{kind:?} must not decode"
            );
        }
    }

    #[test]
    fn claude_login_state_has_this_exact_wire_form() {
        assert_server_golden(
            ServerMsg::ClaudeLoginState {
                needs_login: true,
                claude_bin: Some("/opt/homebrew/bin/claude".into()),
                watch: ClaudeLoginWatch::Keychain,
                sessions: vec![ClaudeLoginSession {
                    tag: "cody-1".into(),
                    hold_id: Some("7d0a1c2e-0000-4000-8000-000000000001".into()),
                    phase: ClaudeLoginPhase::Waiting,
                    queued: 3,
                    failed_at: "2026-10-18T20:04:09Z".into(),
                    auto_resends_left: 3,
                }],
            },
            r#"{"type":"claude_login_state","needs_login":true,"claude_bin":"/opt/homebrew/bin/claude","watch":"keychain","sessions":[{"tag":"cody-1","hold_id":"7d0a1c2e-0000-4000-8000-000000000001","phase":"waiting","queued":3,"failed_at":"2026-10-18T20:04:09Z","auto_resends_left":3}]}"#,
        );
        assert_server_golden(
            ServerMsg::ClaudeLoginState {
                needs_login: false,
                claude_bin: None,
                watch: ClaudeLoginWatch::Unavailable,
                sessions: vec![],
            },
            r#"{"type":"claude_login_state","needs_login":false,"watch":"unavailable","sessions":[]}"#,
        );
    }

    #[test]
    fn claude_login_phases_have_these_wire_names_and_a_paused_entry_has_no_hold_id() {
        for (phase, name) in [
            (ClaudeLoginPhase::Waiting, "waiting"),
            (ClaudeLoginPhase::Resending, "resending"),
            (ClaudeLoginPhase::NotResendable, "not_resendable"),
            (ClaudeLoginPhase::PausedNoHold, "paused_no_hold"),
        ] {
            let entry = ClaudeLoginSession {
                tag: "t".into(),
                hold_id: None,
                phase,
                queued: 0,
                failed_at: "2026-10-18T20:04:09Z".into(),
                auto_resends_left: 0,
            };
            let v = serde_json::to_value(&entry).unwrap();
            assert_eq!(v["phase"], name);
            assert!(v.get("hold_id").is_none(), "{v}");
            assert_eq!(
                serde_json::from_value::<ClaudeLoginSession>(v).unwrap(),
                entry
            );
        }
    }

    #[test]
    fn claude_login_action_has_this_exact_wire_form() {
        assert_client_golden(
            ClientMsg::ClaudeLoginAction {
                action: ClaudeLoginActionKind::Retry,
                tag: "cody-1".into(),
                hold_id: Some("7d0a1c2e-0000-4000-8000-000000000001".into()),
                operator_nonce: Some("ab12".into()),
            },
            r#"{"type":"claude_login_action","action":"retry","tag":"cody-1","hold_id":"7d0a1c2e-0000-4000-8000-000000000001","operator_nonce":"ab12"}"#,
        );
        assert_client_golden(
            ClientMsg::ClaudeLoginAction {
                action: ClaudeLoginActionKind::Discard,
                tag: "cody-1".into(),
                hold_id: None,
                operator_nonce: None,
            },
            r#"{"type":"claude_login_action","action":"discard","tag":"cody-1"}"#,
        );
    }

    #[test]
    fn a_claude_login_action_without_a_nonce_still_decodes_and_the_daemon_refuses_it_later() {
        let msg: ClientMsg = serde_json::from_str(
            r#"{"type":"claude_login_action","action":"retry","tag":"t","hold_id":"h"}"#,
        )
        .unwrap();
        assert!(
            matches!(
                msg,
                ClientMsg::ClaudeLoginAction {
                    operator_nonce: None,
                    ..
                }
            ),
            "{msg:?}"
        );
        assert!(serde_json::from_str::<ClientMsg>(
            r#"{"type":"claude_login_action","action":"resend","tag":"t"}"#
        )
        .is_err());
    }

    #[test]
    fn the_protocol_version_is_unchanged_by_the_claude_login_frames() {
        assert_eq!(PROTOCOL_VERSION, 4);
        assert_eq!(FEATURE_LOGIN, "claude_login_v1");
    }

    #[test]
    fn approval_refusal_report_has_this_exact_wire_form_for_every_channel() {
        for (channel, name) in [
            (RefusalChannel::AppControl, "app_control"),
            (RefusalChannel::Accessibility, "accessibility"),
            (RefusalChannel::Unknown, "unknown"),
        ] {
            assert_client_golden(
                ClientMsg::ApprovalRefusalReport {
                    request_id: Some("r1".into()),
                    control: "allow_once".into(),
                    channel,
                },
                &format!(
                    r#"{{"type":"approval_refusal_report","request_id":"r1","control":"allow_once","channel":"{name}"}}"#
                ),
            );
            assert_eq!(channel.as_str(), name);
        }
        assert_client_golden(
            ClientMsg::ApprovalRefusalReport {
                request_id: None,
                control: "deny".into(),
                channel: RefusalChannel::Accessibility,
            },
            r#"{"type":"approval_refusal_report","control":"deny","channel":"accessibility"}"#,
        );
    }

    #[test]
    fn welcome_with_the_approvals_feature_has_this_exact_wire_form() {
        assert_server_golden(
            ServerMsg::Welcome {
                protocol_version: PROTOCOL_VERSION,
                daemon_pid: 9,
                features: vec!["work".into(), "approvals_v1".into()],
                operator_nonce: Some("cd34".into()),
                enabled_agents: None,
                disabled_agents: None,
            },
            r#"{"type":"welcome","protocol_version":4,"daemon_pid":9,"features":["work","approvals_v1"],"operator_nonce":"cd34"}"#,
        );
    }

    #[test]
    fn welcome_with_enabled_agents_has_this_exact_wire_form() {
        assert_server_golden(
            ServerMsg::Welcome {
                protocol_version: PROTOCOL_VERSION,
                daemon_pid: 9,
                features: vec![],
                operator_nonce: None,
                enabled_agents: Some(vec!["mother".into(), "teri".into()]),
                disabled_agents: Some(vec!["fred".into(), "perri".into()]),
            },
            r#"{"type":"welcome","protocol_version":4,"daemon_pid":9,"enabled_agents":["mother","teri"],"disabled_agents":["fred","perri"]}"#,
        );
    }

    #[test]
    fn welcome_with_nothing_disabled_says_so_with_an_empty_list() {
        assert_server_golden(
            ServerMsg::Welcome {
                protocol_version: PROTOCOL_VERSION,
                daemon_pid: 9,
                features: vec![],
                operator_nonce: None,
                enabled_agents: None,
                disabled_agents: Some(vec![]),
            },
            r#"{"type":"welcome","protocol_version":4,"daemon_pid":9,"disabled_agents":[]}"#,
        );
    }

    #[test]
    fn welcome_without_disabled_agents_decodes_as_none_and_an_unknown_field_is_ignored() {
        let msg: ServerMsg = serde_json::from_str(
            r#"{"type":"welcome","protocol_version":4,"daemon_pid":9,"enabled_agents":["mother"]}"#,
        )
        .unwrap();
        match msg {
            ServerMsg::Welcome {
                disabled_agents,
                enabled_agents,
                ..
            } => {
                assert_eq!(
                    disabled_agents, None,
                    "an older daemon says nothing about what is off"
                );
                assert_eq!(enabled_agents, Some(vec!["mother".to_string()]));
            }
            other => panic!("{other:?}"),
        }
        let msg: ServerMsg = serde_json::from_str(
            r#"{"type":"welcome","protocol_version":4,"daemon_pid":9,"disabled_agents":["fred"],"someday":1}"#,
        )
        .unwrap();
        match msg {
            ServerMsg::Welcome {
                disabled_agents, ..
            } => assert_eq!(disabled_agents, Some(vec!["fred".to_string()])),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn welcome_without_enabled_agents_decodes_as_none() {
        let msg: ServerMsg =
            serde_json::from_str(r#"{"type":"welcome","protocol_version":4,"daemon_pid":9}"#)
                .unwrap();
        match msg {
            ServerMsg::Welcome { enabled_agents, .. } => assert_eq!(enabled_agents, None),
            other => panic!("{other:?}"),
        }
    }

    // ── Subscribe.renders_approvals (mirrors renders_decisions) ──────────────────

    #[test]
    fn subscribe_without_a_renders_approvals_key_decodes_as_false() {
        let msg: ClientMsg = serde_json::from_str(r#"{"type":"subscribe","topics":[]}"#).unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_approvals, ..
            } => {
                assert!(
                    !renders_approvals,
                    "an absent renders_approvals key must decode to false, never to true"
                );
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn subscribe_with_renders_decisions_but_no_renders_approvals_key_is_not_a_presenter_claim() {
        let msg: ClientMsg = serde_json::from_str(
            r#"{"type":"subscribe","topics":["decision"],"renders_decisions":true}"#,
        )
        .unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_decisions,
                renders_approvals,
                ..
            } => {
                assert!(renders_decisions);
                assert!(
                    !renders_approvals,
                    "claiming to render decisions says nothing about approvals"
                );
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn subscribe_with_renders_approvals_true_decodes_true() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":[],"renders_approvals":true}"#)
                .unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_approvals,
                renders_decisions,
                ..
            } => {
                assert!(renders_approvals);
                assert!(!renders_decisions, "the two claims are independent");
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn subscribe_with_renders_approvals_false_decodes_false() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":[],"renders_approvals":false}"#)
                .unwrap();
        match msg {
            ClientMsg::Subscribe {
                renders_approvals, ..
            } => assert!(!renders_approvals),
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    #[test]
    fn encoding_subscribe_includes_an_explicit_renders_approvals_key_either_way() {
        for value in [false, true] {
            let msg = ClientMsg::Subscribe {
                topics: vec![],
                renders_decisions: false,
                renders_approvals: value,
                capabilities: vec![],
                operator_nonce: None,
            };
            round_trip_client(msg.clone());
            assert_client_golden(
                msg,
                &format!(
                    r#"{{"type":"subscribe","topics":[],"renders_decisions":false,"renders_approvals":{value}}}"#
                ),
            );
        }
    }

    // ── BA1: the task verbs and their results (golden JSON) ───────────────────
    //
    // The Swift decoders and encoders (`TaskWire.swift`, `ClientMsg.swift`, and the Mac app's
    // `NostromodClient`) are tested against these exact strings.

    #[test]
    fn the_stop_verb_has_this_exact_wire_form() {
        assert_client_golden(
            ClientMsg::SessionTaskStop {
                request_id: "r1".into(),
                tag: "cody-1".into(),
                task_id: "b7k2m9x1a".into(),
            },
            r#"{"type":"session_task_stop","request_id":"r1","tag":"cody-1","task_id":"b7k2m9x1a"}"#,
        );
    }

    #[test]
    fn the_output_verb_names_an_offset_only_when_it_has_one() {
        assert_client_golden(
            ClientMsg::SessionTaskOutput {
                request_id: "r2".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                offset: Some(4096),
                max_bytes: 65536,
            },
            r#"{"type":"session_task_output","request_id":"r2","tag":"cody-1","task_id":"t1","offset":4096,"max_bytes":65536}"#,
        );
        // The tail: the key is absent (never `null`), and a client that omits it decodes the same.
        assert_client_golden(
            ClientMsg::SessionTaskOutput {
                request_id: "r3".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                offset: None,
                max_bytes: 8192,
            },
            r#"{"type":"session_task_output","request_id":"r3","tag":"cody-1","task_id":"t1","max_bytes":8192}"#,
        );
    }

    #[test]
    fn an_output_verb_with_a_null_offset_decodes_as_the_tail() {
        let msg: ClientMsg = serde_json::from_str(
            r#"{"type":"session_task_output","request_id":"r","tag":"t","task_id":"x","offset":null,"max_bytes":10}"#,
        )
        .unwrap();
        assert!(
            matches!(
                msg,
                ClientMsg::SessionTaskOutput {
                    offset: None,
                    max_bytes: 10,
                    ..
                }
            ),
            "{msg:?}"
        );
    }

    #[test]
    fn an_output_verb_without_a_max_is_not_a_request() {
        assert!(serde_json::from_str::<ClientMsg>(
            r#"{"type":"session_task_output","request_id":"r","tag":"t","task_id":"x"}"#
        )
        .is_err());
    }

    #[test]
    fn a_stop_result_has_this_exact_wire_form_with_and_without_a_message() {
        assert_server_golden(
            ServerMsg::SessionTaskStopResult {
                request_id: "r1".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                outcome: TaskStopOutcome::Accepted,
                message: None,
            },
            r#"{"type":"session_task_stop_result","request_id":"r1","tag":"cody-1","task_id":"t1","outcome":"accepted"}"#,
        );
        assert_server_golden(
            ServerMsg::SessionTaskStopResult {
                request_id: "r2".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                outcome: TaskStopOutcome::Refused,
                message: Some("StopTask: not stoppable".into()),
            },
            r#"{"type":"session_task_stop_result","request_id":"r2","tag":"cody-1","task_id":"t1","outcome":"refused","message":"StopTask: not stoppable"}"#,
        );
    }

    #[test]
    fn every_stop_outcome_has_its_documented_wire_name() {
        for (outcome, name) in [
            (TaskStopOutcome::Accepted, "accepted"),
            (TaskStopOutcome::Refused, "refused"),
            (TaskStopOutcome::Timeout, "timeout"),
            (TaskStopOutcome::Unsupported, "unsupported"),
            (TaskStopOutcome::NotRunning, "not_running"),
        ] {
            assert_eq!(serde_json::to_value(outcome).unwrap(), name);
            assert_eq!(
                serde_json::from_value::<TaskStopOutcome>(serde_json::json!(name)).unwrap(),
                outcome
            );
        }
    }

    #[test]
    fn every_output_outcome_and_source_has_its_documented_wire_name() {
        for (outcome, name) in [
            (TaskOutputOutcome::Ok, "ok"),
            (TaskOutputOutcome::Unavailable, "unavailable"),
            (TaskOutputOutcome::Refused, "refused"),
            (TaskOutputOutcome::Error, "error"),
        ] {
            assert_eq!(serde_json::to_value(outcome).unwrap(), name);
            assert_eq!(
                serde_json::from_value::<TaskOutputOutcome>(serde_json::json!(name)).unwrap(),
                outcome
            );
        }
        for (source, name) in [
            (TaskOutputSource::File, "file"),
            (TaskOutputSource::CliTail, "cli_tail"),
        ] {
            assert_eq!(serde_json::to_value(source).unwrap(), name);
            assert_eq!(
                serde_json::from_value::<TaskOutputSource>(serde_json::json!(name)).unwrap(),
                source
            );
        }
    }

    #[test]
    fn an_output_result_has_this_exact_wire_form_with_every_field() {
        assert_server_golden(
            ServerMsg::SessionTaskOutputResult {
                request_id: "r1".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                outcome: TaskOutputOutcome::Ok,
                text: "line one\nline two\n".into(),
                start_offset: 100,
                end_offset: 118,
                total_bytes: 4096,
                source: Some(TaskOutputSource::CliTail),
                message: Some("a note".into()),
            },
            r#"{"type":"session_task_output_result","request_id":"r1","tag":"cody-1","task_id":"t1","outcome":"ok","text":"line one\nline two\n","start_offset":100,"end_offset":118,"total_bytes":4096,"source":"cli_tail","message":"a note"}"#,
        );
    }

    #[test]
    fn an_output_result_without_a_source_or_message_omits_both_keys() {
        assert_server_golden(
            ServerMsg::SessionTaskOutputResult {
                request_id: "r2".into(),
                tag: "cody-1".into(),
                task_id: "t1".into(),
                outcome: TaskOutputOutcome::Unavailable,
                text: String::new(),
                start_offset: 0,
                end_offset: 0,
                total_bytes: 0,
                source: None,
                message: None,
            },
            r#"{"type":"session_task_output_result","request_id":"r2","tag":"cody-1","task_id":"t1","outcome":"unavailable","text":"","start_offset":0,"end_offset":0,"total_bytes":0}"#,
        );
    }

    #[test]
    fn an_output_result_keeps_large_offsets_exact() {
        let big = 5u64 * 1024 * 1024 * 1024 + 7;
        let msg = ServerMsg::SessionTaskOutputResult {
            request_id: "r".into(),
            tag: "t".into(),
            task_id: "x".into(),
            outcome: TaskOutputOutcome::Ok,
            text: "x".into(),
            start_offset: big,
            end_offset: big + 1,
            total_bytes: big + 1,
            source: Some(TaskOutputSource::File),
            message: None,
        };
        let back: ServerMsg = serde_json::from_str(&serde_json::to_string(&msg).unwrap()).unwrap();
        let ServerMsg::SessionTaskOutputResult {
            start_offset,
            end_offset,
            total_bytes,
            ..
        } = back
        else {
            panic!()
        };
        assert_eq!(
            (start_offset, end_offset, total_bytes),
            (big, big + 1, big + 1)
        );
    }

    #[test]
    fn the_output_cap_is_one_mebibyte() {
        assert_eq!(TASK_OUTPUT_MAX_BYTES, 1_048_576);
    }
}

#[cfg(test)]
mod terminal_wire_tests {
    use super::*;

    fn round_trip_client(msg: ClientMsg) -> serde_json::Value {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ClientMsg = serde_json::from_str(&json).unwrap();
        assert_eq!(
            json,
            serde_json::to_string(&back).unwrap(),
            "mismatch: {json}"
        );
        serde_json::from_str(&json).unwrap()
    }

    fn round_trip_server(msg: ServerMsg) -> serde_json::Value {
        let json = serde_json::to_string(&msg).unwrap();
        let back: ServerMsg = serde_json::from_str(&json).unwrap();
        assert_eq!(
            json,
            serde_json::to_string(&back).unwrap(),
            "mismatch: {json}"
        );
        serde_json::from_str(&json).unwrap()
    }

    fn info() -> TerminalInfo {
        TerminalInfo {
            terminal_id: "t1".into(),
            tag: "core-1".into(),
            pane_id: "terminal-0a1b2c3d".into(),
            kind: TerminalKind::Local,
            label: "Terminal".into(),
            cwd: Some("/tmp".into()),
            target: None,
            status: TerminalStatus::Running,
            exit_code: None,
            ended_reason: None,
            cols: 80,
            rows: 24,
            requested_by: TerminalRequester {
                kind: "user".into(),
                tag: None,
            },
            opened_by_request: Some("req-1".into()),
            follower: None,
            idle_closes_at: None,
            idle_warn_after_secs: None,
        }
    }

    #[test]
    fn terminal_client_messages_round_trip_with_their_wire_names() {
        let cases = [
            (
                ClientMsg::TerminalOpenLocal {
                    tag: "core-1".into(),
                    relative_to: Some("repl".into()),
                    position: Some("split_below".into()),
                    cwd: Some("/tmp".into()),
                    client_request_id: "req-1".into(),
                },
                "terminal_open_local",
            ),
            (
                ClientMsg::TerminalAttach {
                    terminal_id: "t1".into(),
                },
                "terminal_attach",
            ),
            (
                ClientMsg::TerminalDetach {
                    terminal_id: "t1".into(),
                },
                "terminal_detach",
            ),
            (
                ClientMsg::TerminalInput {
                    terminal_id: "t1".into(),
                    bytes: "bHMK".into(),
                    auto_reply: false,
                    via: None,
                },
                "terminal_input",
            ),
            (
                ClientMsg::TerminalResize {
                    terminal_id: "t1".into(),
                    cols: 120,
                    rows: 40,
                },
                "terminal_resize",
            ),
            (
                ClientMsg::TerminalClose {
                    terminal_id: "t1".into(),
                },
                "terminal_close",
            ),
            (
                ClientMsg::TerminalRestart {
                    terminal_id: "t1".into(),
                },
                "terminal_restart",
            ),
            (
                ClientMsg::TerminalRefusalReport {
                    terminal_id: None,
                    op: "input".into(),
                    channel: "app_control".into(),
                },
                "terminal_refusal_report",
            ),
        ];
        for (msg, name) in cases {
            assert_eq!(round_trip_client(msg)["type"], name);
        }
    }

    #[test]
    fn a_minimal_open_local_omits_its_optional_fields() {
        let v = round_trip_client(ClientMsg::TerminalOpenLocal {
            tag: "core-1".into(),
            relative_to: None,
            position: None,
            cwd: None,
            client_request_id: "req-1".into(),
        });
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys.len(), 3, "{v}");
    }

    #[test]
    fn terminal_server_messages_round_trip_with_their_wire_names() {
        let closed = TerminalClosedInfo {
            terminal_id: "t1".into(),
            tag: "core-1".into(),
            pane_id: "terminal-0a1b2c3d".into(),
            label: "Terminal".into(),
            kind: TerminalKind::Ecs,
            reason: "daemon_stopped".into(),
            exit_code: None,
            target: Some(TerminalTarget {
                project: "admin-portal".into(),
                environment: "production".into(),
                service: "web".into(),
                shell_type: "shell".into(),
            }),
        };
        let cases = [
            (
                ServerMsg::TerminalList {
                    terminals: vec![info()],
                    closed: vec![closed.clone()],
                },
                "terminal_list",
            ),
            (
                ServerMsg::TerminalState { terminal: info() },
                "terminal_state",
            ),
            (ServerMsg::TerminalClosed(closed), "terminal_closed"),
            (
                ServerMsg::TerminalReplay {
                    terminal_id: "t1".into(),
                    cols: 80,
                    rows: 24,
                    bytes: "aGk=".into(),
                },
                "terminal_replay",
            ),
            (
                ServerMsg::TerminalOutput {
                    terminal_id: "t1".into(),
                    bytes: "aGk=".into(),
                },
                "terminal_output",
            ),
            (
                ServerMsg::TerminalRefused {
                    op: "input".into(),
                    terminal_id: Some("t1".into()),
                    code: "terminal_input_forbidden".into(),
                },
                "terminal_refused",
            ),
        ];
        for (msg, name) in cases {
            assert_eq!(round_trip_server(msg)["type"], name);
        }
    }

    #[test]
    fn terminal_input_auto_reply_is_additive_on_the_wire() {
        // A keystroke has no `auto_reply` key at all (what an older app sends).
        let key = serde_json::to_value(ClientMsg::TerminalInput {
            terminal_id: "t1".into(),
            bytes: "bHMK".into(),
            auto_reply: false,
            via: None,
        })
        .unwrap();
        assert!(key.get("auto_reply").is_none(), "{key}");
        // A frame without the field decodes as a keystroke.
        let old: ClientMsg =
            serde_json::from_str(r#"{"type":"terminal_input","terminal_id":"t1","bytes":"bHMK"}"#)
                .unwrap();
        assert!(matches!(
            old,
            ClientMsg::TerminalInput {
                auto_reply: false,
                ..
            }
        ));
        // A reply carries it, and it round-trips.
        let reply = ClientMsg::TerminalInput {
            terminal_id: "t1".into(),
            bytes: "G1syNDs4MFI=".into(),
            auto_reply: true,
            via: None,
        };
        let v = serde_json::to_value(&reply).unwrap();
        assert_eq!(v["auto_reply"], true, "{v}");
        let back: ClientMsg = serde_json::from_value(v).unwrap();
        assert!(matches!(
            back,
            ClientMsg::TerminalInput {
                auto_reply: true,
                ..
            }
        ));
    }

    #[test]
    fn terminal_closed_is_flat_on_the_wire() {
        let v = round_trip_server(ServerMsg::TerminalClosed(TerminalClosedInfo {
            terminal_id: "t1".into(),
            tag: "core-1".into(),
            pane_id: "terminal-0a1b2c3d".into(),
            label: "Terminal".into(),
            kind: TerminalKind::Local,
            reason: "exited".into(),
            exit_code: Some(0),
            target: None,
        }));
        assert_eq!(v["reason"], "exited");
        assert_eq!(v["exit_code"], 0);
        assert_eq!(v["kind"], "local");
        assert!(v.get("target").is_none(), "{v}");
    }

    #[test]
    fn a_local_terminal_pane_content_has_no_environment_key() {
        let v = round_trip_server(ServerMsg::PaneContent {
            tag: "core-1".into(),
            pane_id: "terminal-0a1b2c3d".into(),
            content: PaneContentWire::Terminal {
                terminal_id: "t1".into(),
                label: "Terminal".into(),
                environment: None,
            },
            freshness: None,
            address: None,
        });
        assert_eq!(v["content"]["kind"], "terminal");
        assert!(v["content"].get("environment").is_none(), "{v}");
    }

    #[test]
    fn a_subscribe_without_capabilities_still_decodes() {
        let sub: ClientMsg =
            serde_json::from_str(r#"{"type":"subscribe","topics":["layout","terminal"]}"#).unwrap();
        match sub {
            ClientMsg::Subscribe {
                topics,
                capabilities,
                ..
            } => {
                assert_eq!(topics, vec![Topic::Layout, Topic::Terminal]);
                assert!(capabilities.is_empty());
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }

    // ── 2a: remote shell frames ───────────────────────────────────────────────

    fn wire_target() -> TerminalTarget {
        TerminalTarget {
            project: "admin-portal".into(),
            environment: "production".into(),
            service: "scheduler".into(),
            shell_type: "shell".into(),
        }
    }

    #[test]
    fn remote_shell_client_messages_round_trip_with_their_wire_names() {
        let v = round_trip_client(ClientMsg::RemoteShellTargetsRequest);
        assert_eq!(v["type"], "remote_shell_targets_request");

        let v = round_trip_client(ClientMsg::RemoteShellOpen {
            tag: "core-1".into(),
            project: "admin-portal".into(),
            environment: "production".into(),
            service: "scheduler".into(),
            shell_type: "shell".into(),
        });
        assert_eq!(v["type"], "remote_shell_open");
        assert_eq!(v["tag"], "core-1");
        assert_eq!(v["project"], "admin-portal");
        assert_eq!(v["environment"], "production");
        assert_eq!(v["service"], "scheduler");
        assert_eq!(v["shell_type"], "shell");

        let v = round_trip_client(ClientMsg::RemoteShellAnswer {
            request_id: "r1".into(),
            decision: "connect".into(),
            invite_follow: true,
        });
        assert_eq!(v["type"], "remote_shell_answer");
        assert_eq!(v["request_id"], "r1");
        assert_eq!(v["decision"], "connect");
        assert_eq!(v["invite_follow"], true);
    }

    #[test]
    fn a_remote_shell_answer_without_invite_follow_decodes_as_not_following() {
        let msg: ClientMsg = serde_json::from_str(
            r#"{"type":"remote_shell_answer","request_id":"r1","decision":"cancel"}"#,
        )
        .unwrap();

        match msg {
            ClientMsg::RemoteShellAnswer {
                request_id,
                decision,
                invite_follow,
            } => {
                assert_eq!(request_id, "r1");
                assert_eq!(decision, "cancel");
                assert!(!invite_follow, "invite_follow defaults to false");
            }
            other => panic!("expected RemoteShellAnswer, got {other:?}"),
        }
    }

    #[test]
    fn a_remote_shell_targets_request_is_just_its_type() {
        let msg: ClientMsg =
            serde_json::from_str(r#"{"type":"remote_shell_targets_request"}"#).unwrap();

        assert!(matches!(msg, ClientMsg::RemoteShellTargetsRequest));
    }

    #[test]
    fn remote_shell_targets_round_trips_and_leaves_out_what_is_absent() {
        let v = round_trip_server(ServerMsg::RemoteShellTargets {
            configured: true,
            problem: None,
            projects: vec![RemoteShellProject {
                name: "admin-portal".into(),
                default_service: Some("portal".into()),
                environments: vec![
                    RemoteShellEnvironment {
                        name: "production".into(),
                        services: vec!["portal".into(), "scheduler".into()],
                    },
                    RemoteShellEnvironment {
                        name: "demo".into(),
                        services: vec![],
                    },
                ],
            }],
            shell_types: vec!["shell".into(), "console".into(), "tinker".into()],
            repo_paths: [(
                "admin-portal".to_string(),
                vec!["~/Code/admin-portal".to_string()],
            )]
            .into_iter()
            .collect(),
        });
        assert_eq!(v["type"], "remote_shell_targets");
        assert_eq!(v["configured"], true);
        assert!(v.get("problem").is_none(), "{v}");
        assert_eq!(v["projects"][0]["name"], "admin-portal");
        assert_eq!(v["projects"][0]["default_service"], "portal");
        assert_eq!(v["projects"][0]["environments"][0]["name"], "production");
        assert_eq!(
            v["projects"][0]["environments"][0]["services"],
            serde_json::json!(["portal", "scheduler"])
        );
        assert_eq!(
            v["shell_types"],
            serde_json::json!(["shell", "console", "tinker"])
        );
        assert_eq!(
            v["repo_paths"],
            serde_json::json!({"admin-portal": ["~/Code/admin-portal"]})
        );

        let v = round_trip_server(ServerMsg::RemoteShellTargets {
            configured: false,
            problem: Some("no ECS config.json found".into()),
            projects: vec![],
            shell_types: vec![],
            repo_paths: Default::default(),
        });
        assert_eq!(v["configured"], false);
        assert_eq!(v["problem"], "no ECS config.json found");
        assert_eq!(v["projects"], serde_json::json!([]));
        assert!(
            v.get("repo_paths").is_none(),
            "absent when there are none: {v}"
        );

        let v = round_trip_server(ServerMsg::RemoteShellTargets {
            configured: true,
            problem: None,
            projects: vec![RemoteShellProject {
                name: "p".into(),
                default_service: None,
                environments: vec![],
            }],
            shell_types: vec![],
            repo_paths: Default::default(),
        });
        assert!(v["projects"][0].get("default_service").is_none(), "{v}");
    }

    #[test]
    fn remote_shell_targets_without_its_lists_still_decodes() {
        let msg: ServerMsg =
            serde_json::from_str(r#"{"type":"remote_shell_targets","configured":false}"#).unwrap();

        match msg {
            ServerMsg::RemoteShellTargets {
                configured,
                problem,
                projects,
                shell_types,
                repo_paths,
            } => {
                assert!(!configured);
                assert_eq!(problem, None);
                assert!(projects.is_empty() && shell_types.is_empty() && repo_paths.is_empty());
            }
            other => panic!("expected RemoteShellTargets, got {other:?}"),
        }
    }

    #[test]
    fn remote_shell_confirm_request_round_trips_for_an_agent_and_for_the_user() {
        let v = round_trip_server(ServerMsg::RemoteShellConfirmRequest {
            request_id: "r1".into(),
            tag: Some("core-1".into()),
            target: wire_target(),
            requested_by: RemoteRequester {
                kind: "focus".into(),
                tag: Some("core-1".into()),
                agent: Some("cody".into()),
            },
            reason: Some("look at the scheduler".into()),
            expires_at: "2026-10-25T12:00:00Z".into(),
            shell_command: Some("/bin/bash".into()),
            profile: Some("prod-profile".into()),
            cluster: Some("prod-ecs".into()),
        });
        assert_eq!(v["type"], "remote_shell_confirm_request");
        assert_eq!(v["request_id"], "r1");
        assert_eq!(v["tag"], "core-1");
        assert_eq!(v["target"]["project"], "admin-portal");
        assert_eq!(v["target"]["environment"], "production");
        assert_eq!(v["target"]["service"], "scheduler");
        assert_eq!(v["target"]["shell_type"], "shell");
        assert_eq!(v["requested_by"]["kind"], "focus");
        assert_eq!(v["requested_by"]["tag"], "core-1");
        assert_eq!(v["requested_by"]["agent"], "cody");
        assert_eq!(v["reason"], "look at the scheduler");
        assert_eq!(v["expires_at"], "2026-10-25T12:00:00Z");
        assert_eq!(v["shell_command"], "/bin/bash");
        assert_eq!(v["profile"], "prod-profile");
        assert_eq!(v["cluster"], "prod-ecs");

        let v = round_trip_server(ServerMsg::RemoteShellConfirmRequest {
            request_id: "r2".into(),
            tag: None,
            target: wire_target(),
            requested_by: RemoteRequester {
                kind: "user".into(),
                tag: None,
                agent: None,
            },
            reason: None,
            expires_at: "2026-10-25T12:00:00Z".into(),
            shell_command: None,
            profile: None,
            cluster: None,
        });
        assert_eq!(v["requested_by"], serde_json::json!({"kind": "user"}));
        assert!(v.get("reason").is_none(), "{v}");
        for key in ["shell_command", "profile", "cluster"] {
            assert!(v.get(key).is_none(), "{key} is additive: {v}");
        }
        assert!(v.get("tag").is_none(), "{v}");
    }

    #[test]
    fn remote_shell_resolved_round_trips_with_and_without_a_reason() {
        let v = round_trip_server(ServerMsg::RemoteShellResolved {
            request_id: "r1".into(),
            outcome: "connected".into(),
            reason: None,
            remedy: None,
            detail: None,
        });
        assert_eq!(v["type"], "remote_shell_resolved");
        assert_eq!(v["outcome"], "connected");
        assert!(
            v.get("reason").is_none() && v.get("remedy").is_none() && v.get("detail").is_none(),
            "{v}"
        );

        let v = round_trip_server(ServerMsg::RemoteShellResolved {
            request_id: "r1".into(),
            outcome: "connect_failed".into(),
            reason: Some("not_available".into()),
            remedy: Some("Update Nostromo".into()),
            detail: Some("first line".into()),
        });
        assert_eq!(v["reason"], "not_available");
        assert_eq!(v["remedy"], "Update Nostromo");
        assert_eq!(v["detail"], "first line");
    }
}
// ── H6-12: the Document pane content and the PaneAction messages ─────────────

#[cfg(test)]
mod huey_document_wire_tests {
    use super::*;
    use serde_json::json;

    fn paragraph(text: &str) -> MdBlock {
        MdBlock::Paragraph {
            spans: vec![MdSpan::Text { text: text.into() }],
        }
    }

    fn full_document() -> PaneContentWire {
        PaneContentWire::Document {
            title: "Huey, Mon Oct 26, 2026".into(),
            banner: Some(DocBanner {
                level: DocBannerLevel::Info,
                text: "This is the report from Sunday.".into(),
            }),
            blocks: vec![paragraph("Hello")],
            actions: vec![DocAction {
                id: "report.today".into(),
                label: "Today".into(),
                primary: true,
            }],
        }
    }

    fn bare_document() -> PaneContentWire {
        PaneContentWire::Document {
            title: "Huey".into(),
            banner: None,
            blocks: vec![paragraph("Hello")],
            actions: Vec::new(),
        }
    }

    #[test]
    fn h6_12_the_protocol_version_stays_four() {
        assert_eq!(PROTOCOL_VERSION, 4);
    }

    #[test]
    fn h6_12_a_document_with_a_banner_and_an_action_has_exactly_this_json() {
        let json = serde_json::to_string(&full_document()).unwrap();
        assert_eq!(
            json,
            r#"{"kind":"document","title":"Huey, Mon Oct 26, 2026","banner":{"level":"info","text":"This is the report from Sunday."},"blocks":[{"kind":"paragraph","spans":[{"kind":"text","text":"Hello"}]}],"actions":[{"id":"report.today","label":"Today","primary":true}]}"#
        );
    }

    #[test]
    fn h6_12_a_document_with_nothing_optional_omits_banner_and_actions() {
        let json = serde_json::to_string(&bare_document()).unwrap();
        assert_eq!(
            json,
            r#"{"kind":"document","title":"Huey","blocks":[{"kind":"paragraph","spans":[{"kind":"text","text":"Hello"}]}]}"#
        );
    }

    #[test]
    fn h6_12_a_warning_banner_is_spelled_warning() {
        let doc = PaneContentWire::Document {
            title: "t".into(),
            banner: Some(DocBanner {
                level: DocBannerLevel::Warning,
                text: "w".into(),
            }),
            blocks: vec![],
            actions: vec![],
        };
        let v = serde_json::to_value(&doc).unwrap();
        assert_eq!(v["banner"], json!({"level": "warning", "text": "w"}));
    }

    #[test]
    fn h6_12_documents_round_trip() {
        for doc in [full_document(), bare_document()] {
            let json = serde_json::to_string(&doc).unwrap();
            let back: PaneContentWire = serde_json::from_str(&json).unwrap();
            assert_eq!(back, doc);
        }
    }

    #[test]
    fn h6_12_json_without_the_optional_fields_still_decodes() {
        let old = r#"{"kind":"document","title":"Huey","blocks":[]}"#;
        let doc: PaneContentWire = serde_json::from_str(old).unwrap();
        assert_eq!(
            doc,
            PaneContentWire::Document {
                title: "Huey".into(),
                banner: None,
                blocks: vec![],
                actions: vec![],
            }
        );
    }

    #[test]
    fn h6_12_an_action_without_primary_is_not_primary() {
        let json =
            r#"{"kind":"document","title":"t","blocks":[],"actions":[{"id":"a","label":"A"}]}"#;
        let doc: PaneContentWire = serde_json::from_str(json).unwrap();
        let PaneContentWire::Document { actions, .. } = doc else {
            panic!("expected a document");
        };
        assert_eq!(
            actions,
            vec![DocAction {
                id: "a".into(),
                label: "A".into(),
                primary: false
            }]
        );
    }

    #[test]
    fn h6_12_a_pane_content_frame_carries_the_document_and_round_trips() {
        let msg = ServerMsg::PaneContent {
            tag: "huey".into(),
            pane_id: "report".into(),
            content: full_document(),
            freshness: None,
            address: None,
        };
        let v = serde_json::to_value(&msg).unwrap();
        assert_eq!(v["type"], "pane_content");
        assert_eq!(v["content"]["kind"], "document");
        let back: ServerMsg = serde_json::from_value(v).unwrap();
        match back {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } => {
                assert_eq!((tag.as_str(), pane_id.as_str()), ("huey", "report"));
                assert_eq!(content, full_document());
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[test]
    fn h6_12_pane_action_has_exactly_this_json_and_omits_an_absent_nonce() {
        let bare = ClientMsg::PaneAction {
            tag: "huey".into(),
            pane_id: "report".into(),
            action_id: "report.prev".into(),
            operator_nonce: None,
        };
        assert_eq!(
            serde_json::to_string(&bare).unwrap(),
            r#"{"type":"pane_action","tag":"huey","pane_id":"report","action_id":"report.prev"}"#
        );
        let with_nonce = ClientMsg::PaneAction {
            tag: "huey".into(),
            pane_id: "report".into(),
            action_id: "report.prev".into(),
            operator_nonce: Some("abc".into()),
        };
        assert_eq!(
            serde_json::to_string(&with_nonce).unwrap(),
            r#"{"type":"pane_action","tag":"huey","pane_id":"report","action_id":"report.prev","operator_nonce":"abc"}"#
        );
    }

    #[test]
    fn h6_12_pane_action_decodes_with_and_without_a_nonce() {
        let without =
            r#"{"type":"pane_action","tag":"huey","pane_id":"report","action_id":"setup.start"}"#;
        match serde_json::from_str::<ClientMsg>(without).unwrap() {
            ClientMsg::PaneAction {
                tag,
                pane_id,
                action_id,
                operator_nonce,
            } => {
                assert_eq!(
                    (tag.as_str(), pane_id.as_str(), action_id.as_str()),
                    ("huey", "report", "setup.start")
                );
                assert_eq!(operator_nonce, None);
            }
            other => panic!("expected PaneAction, got {other:?}"),
        }
        let with = r#"{"type":"pane_action","tag":"huey","pane_id":"report","action_id":"setup.start","operator_nonce":"n"}"#;
        match serde_json::from_str::<ClientMsg>(with).unwrap() {
            ClientMsg::PaneAction { operator_nonce, .. } => {
                assert_eq!(operator_nonce.as_deref(), Some("n"))
            }
            other => panic!("expected PaneAction, got {other:?}"),
        }
    }

    #[test]
    fn h6_12_pane_action_result_has_exactly_this_json_and_omits_absent_fields() {
        let refused = ServerMsg::PaneActionResult {
            tag: "huey".into(),
            pane_id: "report".into(),
            action_id: "report.prev".into(),
            ok: false,
            message: Some("unknown_action".into()),
            open_url: None,
        };
        assert_eq!(
            serde_json::to_string(&refused).unwrap(),
            r#"{"type":"pane_action_result","tag":"huey","pane_id":"report","action_id":"report.prev","ok":false,"message":"unknown_action"}"#
        );
        let opened = ServerMsg::PaneActionResult {
            tag: "huey".into(),
            pane_id: "report".into(),
            action_id: "setup.open_interests".into(),
            ok: true,
            message: None,
            open_url: Some("file:///tmp/huey/interests.md".into()),
        };
        assert_eq!(
            serde_json::to_string(&opened).unwrap(),
            r#"{"type":"pane_action_result","tag":"huey","pane_id":"report","action_id":"setup.open_interests","ok":true,"open_url":"file:///tmp/huey/interests.md"}"#
        );
        let back: ServerMsg =
            serde_json::from_str(&serde_json::to_string(&opened).unwrap()).unwrap();
        match back {
            ServerMsg::PaneActionResult {
                ok,
                message,
                open_url,
                ..
            } => {
                assert!(ok);
                assert_eq!(message, None);
                assert_eq!(open_url.as_deref(), Some("file:///tmp/huey/interests.md"));
            }
            other => panic!("expected PaneActionResult, got {other:?}"),
        }
    }
}

fn default_true() -> bool {
    true
}
