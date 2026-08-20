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
    /// Daemon-driven decision-modal requests (`DecisionRequest`). Being
    /// subscribed to this topic is also how the daemon knows an operator
    /// exists at all — `nostromo.ask_decision` refuses with `no_operator`
    /// when nobody is.
    Decision,
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

    /// Answer a `ServerMsg::DecisionRequest` (W6 decision modals).
    ///
    /// `choice_id: None` means dismissed without choosing — a distinct,
    /// meaningful outcome, not a default choice — so unlike most optional
    /// fields in this protocol, this one is **not** `skip_serializing_if`:
    /// it is always present on the wire, as a string or as `null`.
    DecisionAnswer {
        request_id: String,
        #[serde(default)]
        choice_id: Option<String>,
    },

    /// Request a full ambient-activity snapshot (all streams) for one focus.
    /// The daemon replies with `ServerMsg::ActivitySnapshot`.
    ActivitySnapshotRequest {
        tag: String,
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
            content: PaneContentWire::Text { text: "fresh".into() },
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
                assert!(matches!(content, PaneContentWire::Text { text } if text == "from an old daemon"));
                assert_eq!(freshness, None, "an absent \"freshness\" key must deserialize to None");
                assert_eq!(address, None, "an absent \"address\" key must deserialize to None");
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
                assert_eq!(address, None, "an absent \"address\" key must deserialize to None");
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
            generated_at: None,
            ..Default::default()
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
        round_trip_client(ClientMsg::ActivitySnapshotRequest { tag: "cody-1".into() });
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
        let msg: ServerMsg = serde_json::from_str(raw).expect("old 4-field Activity shape must still parse");
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
            },
            DecisionChoice {
                id: "reject".into(),
                label: "Reject".into(),
                detail: Some("Block the merge".into()),
            },
        ]
    }

    #[test]
    fn decision_answer_with_a_choice_round_trips_and_uses_the_decision_answer_type_tag() {
        round_trip_client(ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: Some("approve".into()),
        });

        let v = serde_json::to_value(ClientMsg::DecisionAnswer {
            request_id: "req-1".into(),
            choice_id: Some("approve".into()),
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
        });

        let v = serde_json::to_value(ClientMsg::DecisionAnswer {
            request_id: "req-2".into(),
            choice_id: None,
        })
        .unwrap();
        assert!(
            v.as_object().unwrap().contains_key("choice_id"),
            "choice_id must be present on the wire even when dismissed"
        );
        assert!(v["choice_id"].is_null(), "a dismissed answer must serialize choice_id as null");
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

    #[test]
    fn decision_choice_round_trips_standalone_with_and_without_detail() {
        let with_detail = DecisionChoice {
            id: "approve".into(),
            label: "Approve".into(),
            detail: Some("Merge and deploy".into()),
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
            assert_eq!(json, wire, "DiffStatus::{variant:?} must serialize as {wire}");
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
            assert_eq!(json, wire, "DiffLineKind::{variant:?} must serialize as {wire}");
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
                spans: vec![MdSpan::Text { text: "title".into() }],
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
                    spans: vec![MdSpan::Text { text: "item".into() }],
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
                    spans: vec![MdSpan::Text { text: "quoted".into() }],
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
            MdSpan::Code { text: "x = 1".into() },
            MdSpan::Emph {
                spans: vec![MdSpan::Text { text: "em".into() }],
            },
            MdSpan::Strong {
                spans: vec![MdSpan::Text { text: "strong".into() }],
            },
            MdSpan::Strike {
                spans: vec![MdSpan::Text { text: "struck".into() }],
            },
            MdSpan::Link {
                spans: vec![MdSpan::Text { text: "text".into() }],
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
        assert_eq!(comment, back, "ConversationComment round trip mismatch: {json}");
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
        assert_eq!(json["conversation_error"], "conversation fetch partially failed: reviews");
        let back: PaneContentWire = serde_json::from_value(json).unwrap();
        assert_eq!(back, content);
    }

    // ── TicketSection / TicketComment (W4 — curated-agent-views) ─────────────

    #[test]
    fn ticket_section_round_trips_and_omits_heading_key_when_none() {
        let section = TicketSection {
            name: "description".into(),
            heading: None,
            blocks: vec![MdBlock::Paragraph { spans: vec![MdSpan::Text { text: "hi".into() }] }],
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
        assert_eq!(json["heading"], serde_json::json!([{ "kind": "text", "text": "AC" }]));
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
                spans: vec![MdSpan::Text { text: "a comment".into() }],
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
                spans: vec![MdSpan::Text { text: "Must work.".into() }],
            }],
        }
    }

    fn sample_ticket_comment() -> TicketComment {
        TicketComment {
            index: 1,
            author: "bob".into(),
            created_at: chrono::Utc::now(),
            blocks: vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text { text: "a comment".into() }],
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
}
