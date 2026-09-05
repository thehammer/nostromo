//! MCP tool handler for `nostromo.apply_layout` (daemon-hosted).
//!
//! `nostromo.apply_layout({ name })` or `nostromo.apply_layout({ tree, panes })`
//! resolves a declarative [`LayoutSchema`](crate::mcp::layout_schema::LayoutSchema)
//! (named, with on-disk-override precedence, or inline), builds the pane tree
//! through the existing [`PaneRegistry`](crate::ipc::pane_registry::PaneRegistry),
//! runs each pane's data fetch **server-side, with no LLM involvement**, and
//! broadcasts the result in one round trip: a single `ServerMsg::FocusLayout`
//! followed by one `ServerMsg::PaneContent` per non-repl pane.
//!
//! This collapses the imperative `reset_panes` → `create_pane` (×N) →
//! `set_pane_layout` → per-pane `set_pane_content`/read-tool sequence — and all
//! the fetched data along the way — out of the calling agent's context into a
//! single structured tool call. It is purely additive: the imperative tools are
//! unchanged and still work.

use serde_json::{json, Value};

use crate::data::file_source::{self, FileRequest, FileSourceError};
use crate::data::perri_pr::{PrComment, PrThread, PrThreadKind};
use crate::data::tickets::{self, Ticket, TicketError};
use crate::ipc::pane_registry::REPL_PANE_ID;
use crate::ipc::protocol::{
    Anchor, ConversationComment, ConversationThread, ConversationThreadKind, Emphasis,
    PaneAddress, PaneContentWire, PaneFreshness, PrListItem, ServerMsg, TicketComment as WireTicketComment,
    TicketSection as WireTicketSection,
};
use crate::mcp::layout_schema::{self, LayoutSchema};
use crate::mcp::pane_sources::broadcast_pane_content;
use crate::mcp::state::McpSharedState;

/// Stable, machine-readable failure modes for `apply_layout` and the layout
/// schema it resolves. Mirrors `PaneError::code()`'s style: the tool layer
/// surfaces these as `{ "error": "<code>" }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyLayoutError {
    /// A named layout has no on-disk override and no compiled-in default.
    UnknownLayout,
    /// A pane's `source` isn't in the closed fetcher registry.
    UnknownSource,
    /// A pane's `content_kind` isn't a recognised `PaneContentWire` variant.
    InvalidContentKind,
    /// The schema document itself is malformed (bad YAML/JSON, `repl` bound
    /// as a pane, missing required fields).
    InvalidSchema,
    /// A fetcher ran but failed to produce content.
    FetchFailed,
    /// A `tabs` region named `repl` among its tabs (W1 — curated-agent-views).
    /// Distinct from `InvalidSchema`: the document is well-formed, but this
    /// particular placement of `repl` is never valid — the REPL is where the
    /// operator's hands are, and hiding it behind a tab is never what an
    /// agent means.
    ReplInTabs,
    /// A file/diff source's `params` object was absent or malformed (W2).
    FileRefused(FileSourceError),
    /// A `pr_conversation` show named an anchor/emphasis comment id that
    /// isn't present in the fetched conversation (W3 — curated-agent-views).
    UnknownCommentId,
    /// A `ticket` show's provider/key/section-anchor was refused by the
    /// provider registry or the fetched ticket itself (W4 —
    /// curated-agent-views). See `TicketError` for the specific reasons.
    Ticket(TicketError),
}

impl ApplyLayoutError {
    /// The stable snake_case code for the wire.
    pub fn code(&self) -> &'static str {
        match self {
            ApplyLayoutError::UnknownLayout => "unknown_layout",
            ApplyLayoutError::UnknownSource => "unknown_source",
            ApplyLayoutError::InvalidContentKind => "invalid_content_kind",
            ApplyLayoutError::InvalidSchema => "invalid_schema",
            ApplyLayoutError::FetchFailed => "fetch_failed",
            ApplyLayoutError::ReplInTabs => "repl_in_tabs",
            ApplyLayoutError::FileRefused(e) => e.code(),
            ApplyLayoutError::UnknownCommentId => "unknown_comment_id",
            ApplyLayoutError::Ticket(e) => e.code(),
        }
    }

    /// A human-readable, actionable detail beyond `code()` — currently only
    /// populated for `Ticket`, whose refusals must name the deployment's
    /// supported providers / the ticket's actual section names to be
    /// actionable for the calling agent. `None` for every other variant,
    /// which is exactly today's behaviour (a bare code, no detail).
    pub fn detail(&self) -> Option<String> {
        match self {
            ApplyLayoutError::Ticket(e) => Some(e.detail_message()),
            _ => None,
        }
    }

    /// Whether a caller that already has content on this pane must leave it
    /// alone rather than replacing it with an `Error` frame (W2 —
    /// curated-agent-views).
    ///
    /// "A bad show never destroys what Hammer was reading" is a product
    /// criterion, and it is specifically about *refusals*: an agent asking for
    /// line 9000 of a 200-line file made a mistake, and the right answer is to
    /// tell it so while the operator keeps reading whatever was already there.
    /// A `FetchFailed` on a live source is a different thing — the pane's data
    /// really is gone — and stays loud. A `Ticket` refusal follows the same
    /// rule: every `TicketError` is the agent naming something that doesn't
    /// resolve (a provider, a key, a section) *except* `FetchFailed`, which
    /// means the provider's backend itself failed.
    pub fn leaves_content_intact(&self) -> bool {
        match self {
            ApplyLayoutError::FileRefused(_) | ApplyLayoutError::UnknownCommentId => true,
            ApplyLayoutError::Ticket(e) => !matches!(e, TicketError::FetchFailed(_)),
            _ => false,
        }
    }
}

impl From<FileSourceError> for ApplyLayoutError {
    fn from(e: FileSourceError) -> Self {
        ApplyLayoutError::FileRefused(e)
    }
}

/// Default placeholder text for `perri.get_current_pr` when no PR is loaded.
/// Shared with `perri_mutators::clear_current_pr`'s daemon branch so the two
/// can't drift on what "cleared" looks like in the diff pane.
pub(crate) const NO_PR_LOADED_PLACEHOLDER: &str = "No PR loaded.";

/// The PR-queue fetcher source name. The one place this string is spelled —
/// `pane_sources.rs` and everything else references this constant.
pub(crate) const SOURCE_PR_QUEUE: &str = "perri.list_pr_queue";
/// The current-PR fetcher source name. See [`SOURCE_PR_QUEUE`].
pub(crate) const SOURCE_CURRENT_PR: &str = "perri.get_current_pr";
/// The structured-PR-diff fetcher source name (W2 — curated-agent-views).
/// Watch-driven off the same `perri_pr_rx` channel as [`SOURCE_CURRENT_PR`],
/// so a pane bound to it refreshes itself with no tool call.
pub(crate) const SOURCE_PR_DIFF: &str = "perri.get_pr_diff";
/// The file fetcher source name (W2 — curated-agent-views). Deliberately NOT
/// watch-driven: a `file` pane is a snapshot of a revision, and live-updating
/// it under the operator would contradict the revision it says it is showing.
pub(crate) const SOURCE_FILE: &str = "nostromo.get_file";
/// The PR-conversation fetcher source name (W3 — curated-agent-views).
/// Watch-driven off the same `perri_pr_rx` channel as [`SOURCE_CURRENT_PR`]
/// and [`SOURCE_PR_DIFF`] — a pane bound to it refreshes itself with no tool
/// call, and reuses the exact same fetched `PrSnapshot` those two sources
/// already read.
pub(crate) const SOURCE_PR_CONVERSATION: &str = "perri.get_pr_conversation";
/// The ticket fetcher source name (W4 — curated-agent-views). Deliberately
/// NOT watch-driven — a ticket is a one-shot fetch, not a live subscription
/// — and network-only, so (like [`SOURCE_FILE`]'s GitHub-contents fallback)
/// it only ever resolves on the async path ([`fetch_async`]); the sync
/// [`fetch`] path serves a cached ticket if the TTL cache (D5) has one and
/// fails otherwise, same "skip a binding whose fetch fails" rule as every
/// other sync-path caller already applies.
pub(crate) const SOURCE_TICKET: &str = "nostromo.get_ticket";

/// Every source that renders whatever PR the daemon currently has under
/// review, and therefore goes empty exactly when nothing is under review.
/// `pane_sources.rs`'s `pr_rx` arm iterates this to re-push all three on a
/// single watch change; `perri_mutators::resolve_perri_targets` iterates it
/// to classify a pane as holding PR-review content by checking whether it is
/// bound to one of these — independent of which layout template created it.
pub(crate) const PR_BACKED_SOURCES: &[&str] =
    &[SOURCE_CURRENT_PR, SOURCE_PR_DIFF, SOURCE_PR_CONVERSATION];

/// The closed set of `source` names a `PaneSpec` may bind to. Adding a new
/// source is a deliberate code change: add a `match` arm in [`fetch`], a
/// constant above, list it here, and ensure the corresponding receiver is
/// wired into the daemon's `McpSharedState`.
const KNOWN_SOURCES: &[&str] = &[
    SOURCE_PR_QUEUE,
    SOURCE_CURRENT_PR,
    SOURCE_PR_DIFF,
    SOURCE_FILE,
    SOURCE_PR_CONVERSATION,
    SOURCE_TICKET,
];

/// True when `source` is in the closed fetcher registry.
pub(crate) fn source_is_known(source: &str) -> bool {
    KNOWN_SOURCES.contains(&source)
}

/// The full closed set of known source names — used by `PaneRegistry` to drop
/// a persisted binding whose source has been retired in a later daemon
/// version (D3), and by `pane_sources.rs` to drive the automatic broadcaster
/// without a second list of source strings.
pub(crate) fn known_sources() -> &'static [&'static str] {
    KNOWN_SOURCES
}

/// The `PaneContentWire` surface-name a known `source` actually produces, per
/// [`fetch`]. `layout_schema::validate` cross-checks a pane's declared
/// `content_kind` against this so a schema can't declare e.g.
/// `content_kind: text` for `source: perri.list_pr_queue` and have it pass
/// validation while `fetch` silently ignores the declaration and emits
/// `PrList` anyway — this is the single source of truth `fetch` itself
/// dispatches on, kept next to it so the two can't drift apart.
pub(crate) fn source_content_kind(source: &str) -> Option<&'static str> {
    match source {
        SOURCE_PR_QUEUE => Some("pr_list"),
        SOURCE_CURRENT_PR => Some("text"),
        SOURCE_PR_DIFF => Some("diff"),
        SOURCE_FILE => Some("code"),
        SOURCE_PR_CONVERSATION => Some("pr_conversation"),
        SOURCE_TICKET => Some("ticket"),
        _ => None,
    }
}

/// Resolve the focus tag a layout tool targets: an explicit `view_id`, else the
/// caller's own focus (`pty_id` from the Hello frame). Mirrors
/// `create_pane.rs::target_tag`. `pub(crate)` — also used by
/// `refresh_pane::refresh_pane_content`.
pub(crate) fn target_tag<'a>(args: &'a Value, pty_id: Option<&'a str>) -> Option<&'a str> {
    args.get("view_id").and_then(|v| v.as_str()).or(pty_id)
}

/// Build a [`LayoutSchema`] from an inline `{ tree, panes }` payload.
fn schema_from_inline(args: &Value) -> Result<LayoutSchema, ApplyLayoutError> {
    let tree = args
        .get("tree")
        .cloned()
        .ok_or(ApplyLayoutError::InvalidSchema)?;
    let panes = args.get("panes").cloned().unwrap_or_else(|| json!({}));
    let value = json!({ "name": "inline", "tree": tree, "panes": panes });
    let schema: LayoutSchema =
        serde_json::from_value(value).map_err(|_| ApplyLayoutError::InvalidSchema)?;
    layout_schema::validate(&schema)?;
    Ok(schema)
}

/// Per-pane arguments a fetch runs with, beyond the source name itself.
///
/// A struct rather than three positional parameters because the set grew from
/// one (`placeholder`) to three in W2 and will grow again: `params` is what
/// makes a source say *which* file or *which* ticket, and `tag` is what a
/// file read resolves its root against. Callers with nothing to say construct
/// `FetchArgs::default()`, which is exactly the pre-W2 behaviour.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct FetchArgs<'a> {
    /// The focus this pane belongs to. `None` outside a focus context; a
    /// source that needs a root (see [`SOURCE_FILE`]) falls back to the
    /// process working directory.
    pub tag: Option<&'a str>,
    /// Text to show when the source has no data at all yet.
    pub placeholder: Option<&'a str>,
    /// The source's own argument object, passed through verbatim.
    pub params: Option<&'a Value>,
}

impl<'a> FetchArgs<'a> {
    /// The common case: a bound pane being repainted, with whatever params
    /// its binding persisted.
    pub fn bound(tag: &'a str, params: Option<&'a Value>) -> Self {
        FetchArgs {
            tag: Some(tag),
            placeholder: None,
            params,
        }
    }
}

/// Run a pane's bound `source` fetcher, purely server-side (no LLM turn).
///
/// `perri.get_current_pr` renders a plain-text snapshot summary — no agent
/// "highlights" — the agent may overwrite it afterward via `set_pane_content`.
///
/// `pub(crate)` — this is the single dispatch point both `apply_layout` and
/// `refresh_pane::refresh_pane_content` call, which is what guarantees the two
/// tools can never disagree about what a source produces.
///
/// **Synchronous by construction.** `PaneContentProvider::bound_pane_contents`
/// is a sync trait method called from the IPC layer, so this cannot become
/// `async` without splitting that path in two. [`SOURCE_FILE`]'s GitHub
/// contents fallback therefore lives in [`fetch_async`], which every async tool
/// handler calls instead; on the sync repaint paths a revision git doesn't have
/// simply fails the fetch, and the existing "skip a binding whose fetch fails"
/// rule leaves the pane's current content alone.
pub(crate) fn fetch(
    source: &str,
    state: &McpSharedState,
    args: FetchArgs<'_>,
) -> Result<PaneContentWire, ApplyLayoutError> {
    match source {
        SOURCE_PR_QUEUE => {
            let items_json = crate::mcp::tools::perri::list_pr_queue(state);
            let items: Vec<PrListItem> =
                serde_json::from_value(items_json).map_err(|_| ApplyLayoutError::FetchFailed)?;
            Ok(PaneContentWire::PrList { items })
        }
        SOURCE_CURRENT_PR => {
            let snapshot = crate::mcp::tools::perri::get_current_pr(state);
            if snapshot.is_null() {
                return Ok(no_pr_loaded(args.placeholder));
            }
            let pr_number = snapshot.get("pr_number").and_then(|v| v.as_u64());
            let error = snapshot
                .get("error")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            if describes_no_pr(pr_number, &error) {
                return Ok(no_pr_loaded(args.placeholder));
            }
            match render_pr_summary(&snapshot) {
                Some(text) => Ok(PaneContentWire::Text { text }),
                None => Err(ApplyLayoutError::FetchFailed),
            }
        }
        SOURCE_PR_DIFF => {
            let snapshot = state.perri_pr_rx.borrow().clone();
            let Some(snap) = snapshot else {
                return Ok(no_pr_loaded(args.placeholder));
            };
            if describes_no_pr(snap.pr_number, &snap.error) {
                return Ok(no_pr_loaded(args.placeholder));
            }
            // D4: the fetch-level large-diff gate blanks `diff` and sets
            // `diff_too_large`. Say so explicitly, with the file count, rather
            // than broadcasting an empty `files` list that renders as "this PR
            // changes nothing".
            let files = if snap.diff_too_large {
                Vec::new()
            } else {
                crate::data::unified_diff::parse_unified_diff(&snap.diff)
            };
            // Diagnostics job (instrument-code-pane-render-diagnostics): E4
            // shows the daemon can't produce "numbers without text", but
            // "the daemon says it sent N rows / M bytes and the client says
            // it received exactly that" is the assertion that turns that
            // exoneration into proof. Counts and lengths only — never diff
            // content.
            let hunk_count: usize = files.iter().map(|f| f.hunks.len()).sum();
            let line_count: usize = files
                .iter()
                .flat_map(|f| f.hunks.iter())
                .map(|h| h.lines.len())
                .sum();
            tracing::info!(
                repo = %snap.repo,
                pr_number = ?snap.pr_number,
                too_large = snap.diff_too_large,
                changed_files = snap.changed_files,
                file_count = files.len(),
                hunk_count,
                line_count,
                diff_bytes = snap.diff.len(),
                "apply_layout: built Diff pane content"
            );
            Ok(PaneContentWire::Diff {
                repo: snap.repo,
                number: snap.pr_number,
                files,
                too_large: snap.diff_too_large,
                changed_files: snap.changed_files,
            })
        }
        SOURCE_FILE => {
            let ctx = file_request_context(state, args)?;
            let text = file_source::read_at_revision(&ctx.root, &ctx.revision, &ctx.request.path)?;
            file_source::validate_against(&text, &ctx.request)?;
            Ok(code_content(ctx.request, ctx.revision, text))
        }
        SOURCE_PR_CONVERSATION => {
            let snapshot = state.perri_pr_rx.borrow().clone();
            let Some(snap) = snapshot else {
                return Ok(no_pr_loaded(args.placeholder));
            };
            if describes_no_pr(snap.pr_number, &snap.error) {
                return Ok(no_pr_loaded(args.placeholder));
            }
            let threads = conversation_threads_wire(&snap.threads);
            if let Some(params) = args.params {
                validate_comment_ids(params, &threads)?;
            }
            Ok(PaneContentWire::PrConversation {
                repo: snap.repo,
                number: snap.pr_number,
                title: snap.title,
                author: snap.author,
                url: snap.url,
                body: crate::markdown_blocks::markdown_to_blocks(&snap.body),
                threads,
                conversation_error: snap.conversation_error,
            })
        }
        SOURCE_TICKET => {
            // Network-only (D5/D2 of the W4 plan) — this sync path never
            // calls out to a provider. It serves a still-fresh TTL-cached
            // ticket if one exists (so `repaint_bound_panes` on daemon
            // restart doesn't need the network either) and otherwise fails,
            // mirroring `SOURCE_FILE`'s GitHub-contents-fallback precedent:
            // the real fetch only ever happens on `fetch_async`.
            let daemon = state.daemon.as_ref().ok_or(ApplyLayoutError::FetchFailed)?;
            let params = args.params.ok_or(ApplyLayoutError::FetchFailed)?;
            let (provider, key) = ticket_request(params).ok_or(ApplyLayoutError::FetchFailed)?;
            let ticket = daemon
                .tickets
                .cache
                .get(provider, key)
                .ok_or(ApplyLayoutError::FetchFailed)?;
            ticket_content(&ticket, params)
        }
        _ => Err(ApplyLayoutError::UnknownSource),
    }
}

/// Pull `params.provider`/`params.key` out of a `nostromo.get_ticket` call —
/// shared by the sync cache-only path above and [`fetch_ticket_async`] so the
/// two can't disagree about where those two fields live.
fn ticket_request(params: &Value) -> Option<(&str, &str)> {
    let provider = params.get("provider")?.as_str()?;
    let key = params.get("key")?.as_str()?;
    Some((provider, key))
}

/// Build the `PaneContentWire::Ticket` a fetched [`Ticket`] produces,
/// refusing with `unknown_section` if `params` names an anchor/emphasis
/// section that doesn't resolve against *this* ticket (D4 — the honesty
/// requirement: never silently render the top of the ticket while claiming
/// to be at a section that doesn't exist).
fn ticket_content(ticket: &Ticket, params: &Value) -> Result<PaneContentWire, ApplyLayoutError> {
    let aliases = tickets::config::load();
    if let Some(obj) = params.as_object() {
        if let Some(anchor) = obj.get("anchor") {
            if let Ok(Anchor::Section { name }) = serde_json::from_value::<Anchor>(anchor.clone())
            {
                tickets::resolve_section(&ticket.sections, &ticket.comments, &name, &aliases)
                    .map_err(ApplyLayoutError::Ticket)?;
            }
        }
        if let Some(items) = obj.get("emphasis").and_then(|v| v.as_array()) {
            for item in items {
                if let Ok(Emphasis::Section { name }) =
                    serde_json::from_value::<Emphasis>(item.clone())
                {
                    tickets::resolve_section(&ticket.sections, &ticket.comments, &name, &aliases)
                        .map_err(ApplyLayoutError::Ticket)?;
                }
            }
        }
    }

    Ok(PaneContentWire::Ticket {
        provider: ticket.provider.clone(),
        key: ticket.key.clone(),
        summary: ticket.summary.clone(),
        status: ticket.status.clone(),
        assignee: ticket.assignee.clone(),
        url: ticket.url.clone(),
        sections: ticket.sections.iter().map(ticket_section_wire).collect(),
        comments: ticket.comments.iter().map(ticket_comment_wire).collect(),
    })
}

fn ticket_section_wire(s: &crate::data::tickets::TicketSection) -> WireTicketSection {
    WireTicketSection { name: s.name.clone(), heading: s.heading.clone(), blocks: s.blocks.clone() }
}

fn ticket_comment_wire(c: &crate::data::tickets::TicketComment) -> WireTicketComment {
    WireTicketComment {
        index: c.index,
        author: c.author.clone(),
        created_at: c.created_at,
        blocks: c.blocks.clone(),
    }
}

/// Convert a fetched `PrSnapshot`'s raw-markdown [`PrThread`]s into the wire
/// [`ConversationThread`]s a `pr_conversation` pane carries — the point where
/// D2's "bodies stay raw markdown on `PrSnapshot`" becomes B5's "the client
/// renders blocks and never parses markdown". Kept as its own function so
/// [`validate_comment_ids`] can be run against the exact threads about to be
/// broadcast, not a second, possibly-diverging computation of the same thing.
fn conversation_threads_wire(threads: &[PrThread]) -> Vec<ConversationThread> {
    threads
        .iter()
        .map(|t| ConversationThread {
            id: t.id.clone(),
            kind: match t.kind {
                PrThreadKind::Issue => ConversationThreadKind::Issue,
                PrThreadKind::Review => ConversationThreadKind::Review,
                PrThreadKind::Inline => ConversationThreadKind::Inline,
            },
            path: t.path.clone(),
            line: t.line,
            diff_hunk: t.diff_hunk.clone(),
            resolved: t.resolved,
            comments: t.comments.iter().map(conversation_comment_wire).collect(),
        })
        .collect()
}

fn conversation_comment_wire(c: &PrComment) -> ConversationComment {
    ConversationComment {
        id: c.id.clone(),
        author: c.author.clone(),
        created_at: c.created_at,
        body: crate::markdown_blocks::markdown_to_blocks(&c.body),
    }
}

/// Refuse a `pr_conversation` show whose `params` names an anchor/emphasis
/// comment id absent from `threads` (D5 — "an id that names no comment in the
/// current payload is a refusal at the source's fetch… not a silent
/// no-scroll"). Any other `anchor`/`emphasis` shape (a line, a section, a
/// queue row — none of which apply to this view) is simply not this source's
/// concern and passes through untouched; only a named `comment` id is ever
/// validated here.
fn validate_comment_ids(
    params: &Value,
    threads: &[ConversationThread],
) -> Result<(), ApplyLayoutError> {
    let Some(obj) = params.as_object() else {
        return Ok(());
    };
    let known: std::collections::HashSet<&str> = threads
        .iter()
        .flat_map(|t| t.comments.iter().map(|c| c.id.as_str()))
        .collect();

    if let Some(anchor) = obj.get("anchor") {
        if let Ok(Anchor::Comment { id }) = serde_json::from_value::<Anchor>(anchor.clone()) {
            if !known.contains(id.as_str()) {
                return Err(ApplyLayoutError::UnknownCommentId);
            }
        }
    }
    if let Some(items) = obj.get("emphasis").and_then(|v| v.as_array()) {
        for item in items {
            if let Ok(Emphasis::Comment { id }) = serde_json::from_value::<Emphasis>(item.clone())
            {
                if !known.contains(id.as_str()) {
                    return Err(ApplyLayoutError::UnknownCommentId);
                }
            }
        }
    }
    Ok(())
}

/// [`fetch`], plus the one resolution step that genuinely needs the network:
/// [`SOURCE_FILE`]'s GitHub-contents fallback for a revision the local clone
/// doesn't have — the common case for a PR head from a fork that was never
/// fetched.
///
/// Every `async` tool handler calls this; the sync repaint paths call
/// [`fetch`] directly. Both dispatch on the same source strings and produce the
/// same variants, so the two can't disagree about what a source *is* — only
/// about how hard they are willing to work to resolve one revision.
pub(crate) async fn fetch_async(
    source: &str,
    state: &McpSharedState,
    args: FetchArgs<'_>,
) -> Result<PaneContentWire, ApplyLayoutError> {
    if source == SOURCE_TICKET {
        return fetch_ticket_async(state, args).await;
    }
    if source != SOURCE_FILE {
        return fetch(source, state, args);
    }

    let ctx = file_request_context(state, args)?;
    let text = match file_source::read_at_revision(&ctx.root, &ctx.revision, &ctx.request.path) {
        Ok(text) => text,
        Err(FileSourceError::UnresolvableRevision) => match &ctx.pin {
            // A pin exists and the caller's own working directory really is
            // that PR's repo — the legitimate case (a PR head from a fork
            // that was never fetched locally). Unchanged from before W5.
            Some(pin) if file_source::github_fallback_trusted(ctx.local_repo.as_deref(), &pin.repo) => {
                file_source::read_from_github(&pin.repo, &ctx.revision, &ctx.request.path).await?
            }
            // A pin exists but names a repo the caller's working directory
            // does not resolve to (or that couldn't be determined at all):
            // refusing here is the whole point of W5 — the alternative is
            // silently serving a foreign repo's content with `ok: true`.
            Some(_) => return Err(FileSourceError::RevisionRepoMismatch.into()),
            // No PR pinned at all — nothing to fall back to; unchanged from
            // before W5 (an empty repo string simply fails to resolve).
            None => file_source::read_from_github("", &ctx.revision, &ctx.request.path).await?,
        },
        Err(e) => return Err(e.into()),
    };
    file_source::validate_against(&text, &ctx.request)?;
    Ok(code_content(ctx.request, ctx.revision, text))
}

/// [`SOURCE_TICKET`]'s real fetch path (D5): serve a still-fresh TTL-cached
/// ticket with no network at all, else resolve the named provider from the
/// registry (`unsupported_provider`/`provider_unconfigured` on refusal),
/// fetch it, cache the result, and build the pane content — refusing with
/// `unknown_section` if `params` names a section the fetched ticket doesn't
/// have.
async fn fetch_ticket_async(
    state: &McpSharedState,
    args: FetchArgs<'_>,
) -> Result<PaneContentWire, ApplyLayoutError> {
    let daemon = state.daemon.as_ref().ok_or(ApplyLayoutError::FetchFailed)?;
    let params = args.params.ok_or_else(|| {
        ApplyLayoutError::Ticket(TicketError::FetchFailed(
            "nostromo.get_ticket requires params.provider and params.key".to_string(),
        ))
    })?;
    let (provider_name, key) = ticket_request(params).ok_or_else(|| {
        ApplyLayoutError::Ticket(TicketError::FetchFailed(
            "nostromo.get_ticket requires params.provider and params.key".to_string(),
        ))
    })?;

    let ticket = match daemon.tickets.cache.get(provider_name, key) {
        Some(cached) => cached,
        None => {
            let provider = daemon
                .tickets
                .registry
                .get(provider_name)
                .map_err(ApplyLayoutError::Ticket)?;
            let fetched = provider.fetch(key).await.map_err(ApplyLayoutError::Ticket)?;
            daemon.tickets.cache.put(provider_name, key, fetched.clone());
            fetched
        }
    };
    ticket_content(&ticket, params)
}

/// The requesting focus's own pinned PR (W5 — current-pr-collision):
/// `{repo, number, head_sha}`, or `None` when nothing is under review.
///
/// This is the single request-scoped accessor every pin-aware call site
/// routes through — [`file_request_context`]'s repo-scoped revision
/// resolution, `show.rs`'s `current_pin` error decoration, and
/// `perri.get_state`'s `current_pin` field all call this rather than reading
/// `state.perri_pr_rx` directly.
///
/// `tag` is accepted but **deliberately ignored** today: the pin is a single
/// daemon-wide value with no per-focus isolation yet. Threading `tag` through
/// now — rather than adding it later — is what makes a future per-focus pin
/// (each focus reviewing its own PR) a change to this function's *body*
/// alone, with every call site already correct for that world.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RequestPin {
    pub repo: String,
    pub number: u64,
    pub head_sha: String,
}

pub(crate) fn pin_for_request(state: &McpSharedState, _tag: Option<&str>) -> Option<RequestPin> {
    let snap = state.perri_pr_rx.borrow();
    let snap = snap.as_ref()?;
    Some(RequestPin {
        repo: snap.repo.clone(),
        number: snap.pr_number?,
        head_sha: snap.head_sha.clone(),
    })
}

/// The resolved inputs a [`SOURCE_FILE`] fetch runs against, shared by
/// [`fetch`] and [`fetch_async`] so the two can't resolve the same `params`
/// to two different roots, revisions, or repo-mismatch decisions.
struct FileRequestContext {
    request: FileRequest,
    root: std::path::PathBuf,
    revision: String,
    /// The requesting focus's pinned PR, if any — carried alongside
    /// `revision` so [`fetch_async`]'s GitHub-fallback decision doesn't need
    /// to re-read `perri_pr_rx` a second time and risk a different answer.
    pin: Option<RequestPin>,
    /// The `owner/name` the request's root actually resolves to, when
    /// determinable — see [`file_source::local_repo_slug`].
    local_repo: Option<String>,
}

fn file_request_context(
    state: &McpSharedState,
    args: FetchArgs<'_>,
) -> Result<FileRequestContext, ApplyLayoutError> {
    let params = args.params.ok_or(FileSourceError::InvalidParams)?;
    let request = FileRequest::from_params(params)?;
    let root = file_root(state, args.tag);
    let pin = pin_for_request(state, args.tag);
    let local_repo = file_source::local_repo_slug(&root);
    let revision = file_source::resolve_revision(
        &request,
        pin.as_ref().map(|p| (p.repo.as_str(), p.head_sha.as_str())),
        local_repo.as_deref(),
    );
    Ok(FileRequestContext { request, root, revision, pin, local_repo })
}

/// The `PaneContentWire::Code` a resolved file read produces — pulled out
/// because [`fetch`] and [`fetch_async`] both build exactly this, differing
/// only in how hard they worked to get `text`.
fn code_content(request: FileRequest, revision: String, text: String) -> PaneContentWire {
    // Diagnostics job (instrument-code-pane-render-diagnostics): see the
    // matching log in the `SOURCE_PR_DIFF` arm of `fetch` above for why this
    // costs nothing and closes E4 empirically. Counts and lengths only.
    tracing::info!(
        path = %request.path,
        revision = %revision,
        text_len = text.len(),
        line_count = text.lines().count(),
        "apply_layout: built Code pane content"
    );
    PaneContentWire::Code {
        path: request.path,
        revision,
        first_line: 1,
        text,
    }
}

/// The directory a `nostromo.get_file` read is rooted at: the focus's session
/// cwd, falling back to the daemon's own working directory when the focus has
/// none (an unspawned tag, or a unit test).
fn file_root(state: &McpSharedState, tag: Option<&str>) -> std::path::PathBuf {
    let from_session = tag.and_then(|tag| {
        state
            .daemon
            .as_ref()
            .and_then(|d| d.session_mgr.lock().ok()?.cwd_for(tag))
    });
    from_session.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| ".".into()))
}

/// The "no PR loaded" placeholder both PR-backed sources render.
fn no_pr_loaded(placeholder: Option<&str>) -> PaneContentWire {
    PaneContentWire::Text {
        text: placeholder.unwrap_or(NO_PR_LOADED_PLACEHOLDER).to_string(),
    }
}

/// True when a fetched PR snapshot means "nothing is under review" rather
/// than a real PR or a real failure — the single predicate all three
/// PR-backed sources (`SOURCE_CURRENT_PR`, `SOURCE_PR_DIFF`,
/// `SOURCE_PR_CONVERSATION`) apply so they can't drift on what "empty" means
/// (D5). `error.is_none()` is load-bearing: the native PR source publishes a
/// `pr_number: None` snapshot that also carries an `error` when its GitHub
/// client fails to initialise (see `perri_pr_native.rs`), and swallowing
/// *that* as "no PR loaded" would hide a real failure from the operator.
fn describes_no_pr(pr_number: Option<u64>, error: &Option<String>) -> bool {
    pr_number.is_none() && error.is_none()
}

/// The [`PaneAddress`] a source's `params` imply, if any (W2 —
/// curated-agent-views).
///
/// Kept beside [`fetch`] and dispatching on the same source strings, for the
/// same reason [`freshness`] is: an address derived from params is part of what
/// a source produces, and computing it somewhere else would let the two drift.
/// Returns `None` — not an empty address — when there is nothing to point at,
/// so the wire stays byte-identical to a pre-W1 push.
pub(crate) fn address(source: &str, params: Option<&Value>) -> Option<PaneAddress> {
    let params = params?;
    let obj = params.as_object()?;
    let reason = obj
        .get("reason")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let addr = match source {
        SOURCE_FILE => {
            let request = FileRequest::from_params(params).ok()?;
            PaneAddress {
                // `path: None` — "the pane's one file", which is exactly what
                // a `file` pane is.
                anchor: request.anchor_line.map(|line| Anchor::Line { path: None, line }),
                emphasis: request.emphasis_wire(),
                reason,
            }
        }
        // W5: `SOURCE_PR_QUEUE` joins this arm so an `Emphasis::QueueRow`
        // reaches the wire. Before the curated surface existed nothing could
        // address a queue row, so the queue fell through to the reason-only
        // arm below; leaving it there would silently drop the "mark this row"
        // half of a `review_queue` show.
        SOURCE_PR_QUEUE | SOURCE_PR_DIFF | SOURCE_PR_CONVERSATION | SOURCE_TICKET => PaneAddress {
            anchor: obj
                .get("anchor")
                .and_then(|v| serde_json::from_value::<Anchor>(v.clone()).ok()),
            emphasis: obj
                .get("emphasis")
                .and_then(|v| v.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|i| serde_json::from_value(i.clone()).ok())
                        .collect()
                })
                .unwrap_or_default(),
            reason,
        },
        _ => PaneAddress {
            anchor: None,
            emphasis: Vec::new(),
            reason,
        },
    };

    if addr == PaneAddress::default() {
        None
    } else {
        Some(addr)
    }
}

/// Compute how trustworthy `source`'s current data is, independently of what
/// [`fetch`] renders from it — but dispatching on the exact same `source`
/// strings, kept in this same function so the two can never drift about which
/// snapshot backs which source.
///
/// A `None` snapshot (source has no data at all yet — e.g. no PR loaded) is
/// deliberately *not* treated as a staleness condition: `PaneFreshness::default()`.
pub(crate) fn freshness(source: &str, state: &McpSharedState) -> PaneFreshness {
    match source {
        SOURCE_PR_QUEUE => match state.perri_queue_rx.borrow().as_ref() {
            Some(snap) => compute_freshness(snap.generated_at, snap.stale || snap.error.is_some()),
            None => PaneFreshness::default(),
        },
        // All three read the identical perri_pr_rx snapshot (SOURCE_PR_DIFF's
        // and SOURCE_PR_CONVERSATION's fetches above do too) — they must share
        // this arm, not just happen to agree, or these panes' staleness could
        // silently drift apart.
        SOURCE_CURRENT_PR | SOURCE_PR_DIFF | SOURCE_PR_CONVERSATION => match state
            .perri_pr_rx
            .borrow()
            .as_ref()
        {
            Some(snap) => compute_freshness(snap.generated_at, snap.stale || snap.error.is_some()),
            None => PaneFreshness::default(),
        },
        _ => PaneFreshness::default(),
    }
}

/// `badly_stale = stale && (as_of.is_none() || now - as_of > BADLY_STALE_AFTER)`.
/// A source that is merely `stale` with a recent `as_of` is a routine missed
/// cycle and stays quiet; one with no `as_of` at all has never produced good
/// data and is badly stale immediately, not after some delay.
fn compute_freshness(as_of: Option<chrono::DateTime<chrono::Utc>>, stale: bool) -> PaneFreshness {
    let badly_stale = stale
        && match as_of {
            None => true,
            Some(t) => match chrono::Utc::now().signed_duration_since(t).to_std() {
                Ok(elapsed) => elapsed > crate::mcp::pane_sources::badly_stale_after(),
                // `t` is in the future (clock skew) — not stale.
                Err(_) => false,
            },
        };
    PaneFreshness {
        as_of,
        stale,
        badly_stale,
    }
}

/// Render a `PrSnapshot` JSON value as a plain-text summary: title,
/// `owner/repo#number`, author, `+adds/-dels`, changed files.
fn render_pr_summary(snapshot: &Value) -> Option<String> {
    let repo = snapshot.get("repo")?.as_str()?;
    let title = snapshot.get("title")?.as_str()?;
    let author = snapshot.get("author")?.as_str()?;
    let number = snapshot.get("pr_number").and_then(|v| v.as_u64());
    let additions = snapshot
        .get("additions")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let deletions = snapshot
        .get("deletions")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let changed_files = snapshot
        .get("changed_files")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let pr_ref = match number {
        Some(n) => format!("{repo}#{n}"),
        None => repo.to_string(),
    };

    Some(format!(
        "{title}\n{pr_ref} by {author}\n+{additions}/-{deletions} across {changed_files} file(s)"
    ))
}

/// Handle `nostromo.apply_layout`.
pub async fn apply_layout(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "apply_layout requires the daemon-hosted MCP server" });
    };

    // ── resolve the schema (named, with override precedence, or inline) ────
    // `name` and `tree` are documented as mutually exclusive (docs/mcp/panes.md,
    // the tool_descriptors() entry) — enforce that rather than silently
    // preferring `name` and discarding a caller-supplied `tree`/`panes`.
    if args.get("name").is_some() && args.get("tree").is_some() {
        return json!({ "error": "invalid_args", "detail": "provide `name` or `tree`, not both" });
    }
    let schema = if let Some(name) = args.get("name").and_then(|v| v.as_str()) {
        match layout_schema::load(name) {
            Ok(s) => s,
            Err(e) => return json!({ "error": e.code() }),
        }
    } else if args.get("tree").is_some() {
        match schema_from_inline(args) {
            Ok(s) => s,
            Err(e) => return json!({ "error": e.code() }),
        }
    } else {
        return json!({ "error": "invalid_args", "detail": "provide `name` or `tree`" });
    };

    // ── resolve the target focus tag ────────────────────────────────────────
    let explicit_view = args.get("view_id").and_then(|v| v.as_str()).is_some();
    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    // ── build + validate the tree through the existing PaneRegistry path ────
    let tree = schema.tree.to_pane_tree();
    let set_result = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        if !explicit_view {
            reg.get_or_init(&tag);
        }
        reg.set_layout(&tag, &json!({ "tree": tree }))
    };
    let tree = match set_result {
        Ok(t) => t,
        Err(e) => return json!({ "error": e.code() }),
    };

    // ── broadcast structure, then fetch + broadcast each pane's content ─────
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
        tag: tag.clone(),
        tree,
        focused_pane: None,
    });

    let mut warnings = Vec::new();
    for (pane_id, spec) in &schema.panes {
        if pane_id == REPL_PANE_ID {
            continue;
        }
        let Some(source) = &spec.source else {
            continue;
        };
        // D4: a source-backed pane is bound the moment apply_layout declares
        // it, regardless of whether this fetch succeeds — binding records
        // intent, and the automatic broadcaster (or the next refresh) will
        // repaint it once the source recovers.
        //
        // A schema-declared pane carries no per-pane params (W2): the layout
        // DSL describes shape, and "which file" is a runtime question only
        // `refresh_pane_content` can answer.
        {
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.bind_source(&tag, pane_id, source);
        }
        let args = FetchArgs {
            tag: Some(&tag),
            placeholder: spec.placeholder.as_deref(),
            params: None,
        };
        let (content, msg_freshness) = match fetch_async(source, state, args).await {
            Ok(c) => (c, Some(freshness(source, state))),
            Err(e) => {
                warnings.push(json!({ "pane_id": pane_id, "error": e.code(), "detail": e.detail() }));
                let message = match e.detail() {
                    Some(detail) => {
                        format!("apply_layout: {source} fetch failed ({}): {detail}", e.code())
                    }
                    None => format!("apply_layout: {source} fetch failed ({})", e.code()),
                };
                (PaneContentWire::Error { message }, None)
            }
        };
        broadcast_pane_content(daemon, &tag, pane_id, content, msg_freshness);
    }

    if warnings.is_empty() {
        json!({ "ok": true })
    } else {
        json!({ "ok": true, "warnings": warnings })
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::tickets::jira::{JiraCredentials, JiraProvider};
    use crate::data::tickets::{TicketCache, TicketRegistry};
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::SessionManager;
    use crate::mcp::{DaemonMcpBackend, TicketRegistryState};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokio::sync::{broadcast, watch};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn make_state() -> (McpSharedState, broadcast::Receiver<ServerMsg>) {
        make_state_with_tickets(TicketRegistryState::default())
    }

    fn make_state_with_tickets(
        tickets: TicketRegistryState,
    ) -> (McpSharedState, broadcast::Receiver<ServerMsg>) {
        let tmp = tempfile::TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        // Leak the tempdir so it outlives the test (its Drop would otherwise
        // remove the directory while the registry might still write to it).
        std::mem::forget(tmp);
        let (broadcast_tx, rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: crate::mcp::PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
            tickets,
        };
        (McpSharedState::for_daemon(backend), rx)
    }

    /// A `TicketRegistryState` with `jira` registered but unconfigured (no
    /// credentials) — for the `provider_unconfigured` refusal path.
    fn unconfigured_jira_tickets_state() -> TicketRegistryState {
        let mut registry = TicketRegistry::new();
        registry.register(Arc::new(JiraProvider::for_test(None, String::new())));
        TicketRegistryState {
            registry: Arc::new(registry),
            cache: Arc::new(TicketCache::new(Duration::from_secs(60))),
        }
    }

    /// A `TicketRegistryState` with `jira` registered, configured, and
    /// pointed at a `wiremock` server instead of real Atlassian.
    fn jira_tickets_state(base_url: String, ttl: Duration) -> TicketRegistryState {
        let mut registry = TicketRegistry::new();
        let creds = JiraCredentials::for_test("acme.atlassian.net", "hammer@acme.com", "tok");
        registry.register(Arc::new(JiraProvider::for_test(Some(creds), base_url)));
        TicketRegistryState { registry: Arc::new(registry), cache: Arc::new(TicketCache::new(ttl)) }
    }

    /// A minimal happy-path Jira issue-fetch response body.
    fn jira_issue_body(summary: &str) -> serde_json::Value {
        json!({
            "fields": {
                "summary": summary,
                "status": { "name": "Open" },
                "assignee": serde_json::Value::Null,
                "description": {
                    "type": "doc",
                    "content": [
                        { "type": "paragraph", "content": [{ "type": "text", "text": "Body." }] }
                    ]
                },
                "comment": { "comments": [] }
            }
        })
    }

    #[test]
    fn apply_layout_error_code_returns_stable_snake_case_strings() {
        assert_eq!(ApplyLayoutError::UnknownLayout.code(), "unknown_layout");
        assert_eq!(ApplyLayoutError::UnknownSource.code(), "unknown_source");
        assert_eq!(
            ApplyLayoutError::InvalidContentKind.code(),
            "invalid_content_kind"
        );
        assert_eq!(ApplyLayoutError::InvalidSchema.code(), "invalid_schema");
        assert_eq!(ApplyLayoutError::FetchFailed.code(), "fetch_failed");
        assert_eq!(ApplyLayoutError::ReplInTabs.code(), "repl_in_tabs");
    }

    #[tokio::test]
    async fn applying_perri_standard_binds_queue_and_diff_but_never_repl() {
        let (state, _bcast) = make_state();

        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["ok"], true);

        let daemon = state.daemon.as_ref().unwrap();
        let reg = daemon.pane_registry.lock().unwrap();
        assert_eq!(
            reg.source_for("perri", "queue"),
            Some("perri.list_pr_queue"),
            "applying the perri-standard layout must bind \"queue\" to its live source"
        );
        assert_eq!(
            reg.source_for("perri", "diff"),
            Some("perri.get_current_pr"),
            "applying the perri-standard layout must bind \"diff\" to its live source"
        );
        assert_eq!(
            reg.source_for("perri", "repl"),
            None,
            "the repl pane must never get a live-source binding"
        );
    }

    #[tokio::test]
    async fn applying_perri_standard_broadcasts_layout_and_content() {
        let (state, mut bcast) = make_state();

        // Seed live PR-queue and current-PR data so the fetchers have
        // something real to render.
        let queue_items = serde_json::json!([
            { "repo": "acme/web", "number": 42, "title": "Add widget", "author": "alice",
              "bucket": "requested", "ci_state": "success", "url": "https://example.com/42" }
        ]);
        let (_qtx, queue_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_queue::PrQueueSnapshot>(
                serde_json::json!({ "generated_at": null, "items": queue_items, "stale": false, "error": null }),
            )
            .unwrap(),
        ));
        let mut state = state;
        state.perri_queue_rx = queue_rx;

        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": "",
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": 3, "head_sha": "abc123", "diff_too_large": false
            }))
            .unwrap(),
        ));
        state.perri_pr_rx = pr_rx;

        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("warnings").is_none());

        let msg = bcast.recv().await.expect("FocusLayout broadcast");
        match msg {
            ServerMsg::FocusLayout { tag, tree, .. } => {
                assert_eq!(tag, "perri");
                let ids = tree.pane_ids();
                assert_eq!(ids.len(), 3);
                assert!(ids.contains(&"queue".to_string()));
                assert!(ids.contains(&"diff".to_string()));
                assert!(ids.contains(&"repl".to_string()));
            }
            other => panic!("expected FocusLayout, got {other:?}"),
        }

        let mut saw_queue = false;
        let mut saw_diff = false;
        for _ in 0..2 {
            match bcast.recv().await.expect("a PaneContent broadcast") {
                ServerMsg::PaneContent {
                    pane_id, content, ..
                } => {
                    if pane_id == "queue" {
                        saw_queue = true;
                        assert!(matches!(content, PaneContentWire::PrList { .. }));
                    } else if pane_id == "diff" {
                        saw_diff = true;
                        match content {
                            PaneContentWire::Text { text } => {
                                assert!(text.contains("Add widget"));
                                assert!(text.contains("acme/web#42"));
                            }
                            other => panic!("expected Text content for diff, got {other:?}"),
                        }
                    } else {
                        panic!("unexpected pane_id: {pane_id}");
                    }
                }
                other => panic!("expected PaneContent, got {other:?}"),
            }
        }
        assert!(saw_queue && saw_diff);
    }

    #[tokio::test]
    async fn get_current_pr_renders_placeholder_when_no_pr_loaded() {
        let (state, mut bcast) = make_state();
        // perri_pr_rx defaults to None via for_test/for_daemon.

        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.unwrap(); // FocusLayout
        let mut saw_placeholder = false;
        for _ in 0..2 {
            if let ServerMsg::PaneContent {
                pane_id, content, ..
            } = bcast.recv().await.unwrap()
            {
                if pane_id == "diff" {
                    if let PaneContentWire::Text { text } = content {
                        assert!(text.contains("No PR loaded"));
                        saw_placeholder = true;
                    }
                }
            }
        }
        assert!(saw_placeholder);
    }

    // ── describes_no_pr / the three PR-backed fetch arms (D5) ───────────────
    //
    // Before this fix, only a *missing* `perri_pr_rx` snapshot (`None`)
    // triggered the placeholder — a snapshot that exists but describes "no PR
    // under review" (the shape the native source publishes right after a
    // clear) fell through to each source's normal rendering path and produced
    // garbled output (an empty diff claiming to be a real PR, a summary line
    // with no title). `describes_no_pr` is the single predicate all three
    // arms now share, so they can't drift on what "empty" means.

    /// A `PrSnapshot` with just `pr_number`/`error` varied — every other field
    /// carries `#[serde(default)]`, so this is the minimal shape `fetch`'s
    /// three PR-backed arms need to exercise.
    fn snapshot_with(pr_number: Option<u64>, error: Option<&str>) -> crate::data::perri_pr::PrSnapshot {
        serde_json::from_value(json!({
            "pr_number": pr_number, "repo": "acme/web", "title": "Add widget",
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": error
        }))
        .unwrap()
    }

    /// Point both `perri.get_current_pr`'s snapshot source and
    /// `perri.get_pr_diff`/`perri.get_pr_conversation`'s (`perri_pr_rx`) at
    /// the same snapshot — all three sources read the identical channel in
    /// the daemon, so a single injection point exercises all three fetch
    /// arms identically.
    fn state_with_pr_snapshot(snap: crate::data::perri_pr::PrSnapshot) -> McpSharedState {
        let (mut state, _bcast) = make_state();
        let (_tx, rx) = watch::channel(Some(snap));
        state.perri_pr_rx = rx;
        state
    }

    #[test]
    fn every_pr_backed_source_produces_the_placeholder_for_a_no_pr_under_review_snapshot() {
        let state = state_with_pr_snapshot(snapshot_with(None, None));

        for source in [SOURCE_CURRENT_PR, SOURCE_PR_DIFF, SOURCE_PR_CONVERSATION] {
            let content = fetch(source, &state, FetchArgs::default())
                .unwrap_or_else(|e| panic!("{source}: fetch failed: {e:?}"));
            match content {
                PaneContentWire::Text { text } => {
                    assert_eq!(text, NO_PR_LOADED_PLACEHOLDER, "{source}");
                }
                other => panic!("{source}: expected the placeholder Text, got {other:?}"),
            }
        }
    }

    #[test]
    fn every_pr_backed_source_still_surfaces_a_real_error_rather_than_the_placeholder() {
        // D5's regression guard: `pr_number: None` alone must not swallow a
        // real failure — the native source publishes exactly this shape (no
        // number, an error) when its GitHub client fails to initialise.
        let state = state_with_pr_snapshot(snapshot_with(None, Some("client init failed")));

        // get_current_pr: still renders the plain-text summary (repo, no
        // "#N"), not the placeholder — render_pr_summary doesn't itself look
        // at `error`.
        match fetch(SOURCE_CURRENT_PR, &state, FetchArgs::default()).unwrap() {
            PaneContentWire::Text { text } => {
                assert_ne!(text, NO_PR_LOADED_PLACEHOLDER);
                assert!(text.contains("acme/web"), "expected the summary, got {text:?}");
            }
            other => panic!("expected Text, got {other:?}"),
        }

        // pr_diff / pr_conversation: still their own normal content shape,
        // not the placeholder Text.
        match fetch(SOURCE_PR_DIFF, &state, FetchArgs::default()).unwrap() {
            PaneContentWire::Diff { .. } => {}
            other => panic!("expected Diff, not the placeholder: {other:?}"),
        }
        match fetch(SOURCE_PR_CONVERSATION, &state, FetchArgs::default()).unwrap() {
            PaneContentWire::PrConversation { .. } => {}
            other => panic!("expected PrConversation, not the placeholder: {other:?}"),
        }
    }

    #[tokio::test]
    async fn inline_tree_mode_applies_without_a_named_layout() {
        let (state, mut bcast) = make_state();

        let args = json!({
            "tree": {
                "direction": "horizontal",
                "ratios": [0.5, 0.5],
                "children": [
                    { "pane": "notes" },
                    { "pane": "repl" }
                ]
            },
            "panes": {
                "notes": { "content_kind": "text" }
            }
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        let msg = bcast.recv().await.expect("FocusLayout broadcast");
        match msg {
            ServerMsg::FocusLayout { tag, tree, .. } => {
                assert_eq!(tag, "perri");
                assert_eq!(tree.pane_ids(), vec!["notes", "repl"]);
            }
            other => panic!("expected FocusLayout, got {other:?}"),
        }
        // "notes" has no `source`, so no PaneContent broadcast follows.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn unknown_layout_name_returns_stable_error_code() {
        let (state, _bcast) = make_state();
        let result =
            apply_layout(&state, &json!({ "name": "does-not-exist" }), Some("perri")).await;
        assert_eq!(result["error"], "unknown_layout");
    }

    #[tokio::test]
    async fn inline_unknown_source_returns_stable_error_code_and_does_not_mutate_registry() {
        let (state, _bcast) = make_state();

        let args = json!({
            "tree": { "direction": "horizontal", "ratios": [0.5, 0.5],
                      "children": [ { "pane": "notes" }, { "pane": "repl" } ] },
            "panes": { "notes": { "source": "nonexistent.fetcher", "content_kind": "text" } }
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "unknown_source");

        // The registry must not have been mutated: no focus was registered.
        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(!reg.contains("perri"));
        }
    }

    #[tokio::test]
    async fn missing_name_and_tree_returns_invalid_args() {
        let (state, _bcast) = make_state();
        let result = apply_layout(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["error"], "invalid_args");
    }

    #[tokio::test]
    async fn both_name_and_tree_returns_invalid_args_and_does_not_mutate_registry() {
        // `name` and `tree` are documented as mutually exclusive — passing both
        // must be a loud caller error, not a silent "name wins, tree ignored".
        let (state, _bcast) = make_state();
        let args = json!({
            "name": "perri-standard",
            "tree": { "direction": "horizontal", "ratios": [0.5, 0.5],
                      "children": [ { "pane": "notes" }, { "pane": "repl" } ] },
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "invalid_args");

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(!reg.contains("perri"));
        }
    }

    #[tokio::test]
    async fn no_daemon_backend_returns_not_supported() {
        let (event_tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let state = McpSharedState::for_test(event_tx);
        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }

    // ── perri.get_pr_conversation (W3 — curated-agent-views) ─────────────────

    /// Seed `perri_pr_rx` with a snapshot carrying a PR description with a
    /// fenced code block, plus one inline thread with one comment — enough to
    /// prove `fetch` actually converts raw markdown into blocks, not merely
    /// that the field exists.
    fn seeded_conversation_state(state: McpSharedState) -> McpSharedState {
        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": "",
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": 3, "head_sha": "abc123", "diff_too_large": false,
                "body": "See below:\n\n```rust\nfn f() {}\n```\n",
                "threads": [{
                    "id": "inline-1",
                    "kind": "inline",
                    "path": "src/main.rs",
                    "line": 10,
                    "resolved": false,
                    "comments": [{
                        "id": "c1",
                        "author": "bob",
                        "created_at": "2024-01-01T00:00:00Z",
                        "body": "```python\nprint('hi')\n```\n"
                    }]
                }],
                "conversation_error": null
            }))
            .unwrap(),
        ));
        let mut state = state;
        state.perri_pr_rx = pr_rx;
        state
    }

    #[test]
    fn fetch_pr_conversation_with_no_pr_loaded_returns_placeholder_text() {
        let (state, _bcast) = make_state();
        // perri_pr_rx defaults to None.
        let content = fetch(
            SOURCE_PR_CONVERSATION,
            &state,
            FetchArgs {
                tag: Some("perri"),
                placeholder: None,
                params: None,
            },
        )
        .expect("no-PR-loaded must not be a fetch failure");
        match content {
            PaneContentWire::Text { text } => assert!(text.contains("No PR loaded")),
            other => panic!("expected Text placeholder, got {other:?}"),
        }
    }

    #[test]
    fn fetch_pr_conversation_converts_raw_markdown_body_and_comment_bodies_into_blocks() {
        let (state, _bcast) = make_state();
        let state = seeded_conversation_state(state);

        let content = fetch(
            SOURCE_PR_CONVERSATION,
            &state,
            FetchArgs {
                tag: Some("perri"),
                placeholder: None,
                params: None,
            },
        )
        .expect("fetch should succeed");

        match content {
            PaneContentWire::PrConversation {
                repo,
                number,
                body,
                threads,
                conversation_error,
                ..
            } => {
                assert_eq!(repo, "acme/web");
                assert_eq!(number, Some(42));
                assert!(
                    body.iter().any(|b| matches!(b, crate::ipc::protocol::MdBlock::CodeBlock { .. })),
                    "the PR description's fenced code block must survive markdown-to-block \
                     conversion, got: {body:?}"
                );
                assert!(conversation_error.is_none());
                assert_eq!(threads.len(), 1);
                let comment = &threads[0].comments[0];
                assert!(
                    comment
                        .body
                        .iter()
                        .any(|b| matches!(b, crate::ipc::protocol::MdBlock::CodeBlock { .. })),
                    "a comment's raw-markdown body must also be converted to blocks in fetch, \
                     got: {:?}",
                    comment.body
                );
            }
            other => panic!("expected PrConversation, got {other:?}"),
        }
    }

    fn sample_threads_for_validation() -> Vec<ConversationThread> {
        vec![ConversationThread {
            id: "inline-1".into(),
            kind: ConversationThreadKind::Inline,
            path: Some("src/main.rs".into()),
            line: Some(10),
            diff_hunk: None,
            resolved: false,
            comments: vec![ConversationComment {
                id: "known-id".into(),
                author: "bob".into(),
                created_at: chrono::Utc::now(),
                body: vec![],
            }],
        }]
    }

    #[test]
    fn validate_comment_ids_passes_when_anchor_names_a_known_comment_id() {
        let threads = sample_threads_for_validation();
        let params = json!({ "anchor": { "kind": "comment", "id": "known-id" } });
        assert!(validate_comment_ids(&params, &threads).is_ok());
    }

    #[test]
    fn validate_comment_ids_refuses_when_anchor_names_an_unknown_comment_id() {
        let threads = sample_threads_for_validation();
        let params = json!({ "anchor": { "kind": "comment", "id": "does-not-exist" } });
        let err = validate_comment_ids(&params, &threads).unwrap_err();
        assert_eq!(err, ApplyLayoutError::UnknownCommentId);
    }

    #[test]
    fn validate_comment_ids_passes_when_emphasis_names_a_known_comment_id() {
        let threads = sample_threads_for_validation();
        let params = json!({ "emphasis": [{ "kind": "comment", "id": "known-id" }] });
        assert!(validate_comment_ids(&params, &threads).is_ok());
    }

    #[test]
    fn validate_comment_ids_refuses_when_an_emphasis_entry_names_an_unknown_comment_id() {
        let threads = sample_threads_for_validation();
        let params = json!({ "emphasis": [
            { "kind": "comment", "id": "known-id" },
            { "kind": "comment", "id": "does-not-exist" }
        ] });
        let err = validate_comment_ids(&params, &threads).unwrap_err();
        assert_eq!(err, ApplyLayoutError::UnknownCommentId);
    }

    #[test]
    fn validate_comment_ids_ignores_a_non_comment_anchor_or_emphasis_kind() {
        let threads = sample_threads_for_validation();
        // A line-range anchor/emphasis is not this source's concern at all —
        // must never trigger the comment-id refusal, however malformed.
        let anchor_params = json!({ "anchor": { "kind": "line", "line": 9000 } });
        assert!(validate_comment_ids(&anchor_params, &threads).is_ok());

        let emphasis_params = json!({ "emphasis": [{ "kind": "line_range", "start": 1, "end": 2 }] });
        assert!(validate_comment_ids(&emphasis_params, &threads).is_ok());
    }

    #[test]
    fn fetch_pr_conversation_refuses_an_unknown_anchor_comment_id_via_params() {
        let (state, _bcast) = make_state();
        let state = seeded_conversation_state(state);

        let params = json!({ "anchor": { "kind": "comment", "id": "does-not-exist" } });
        let err = fetch(
            SOURCE_PR_CONVERSATION,
            &state,
            FetchArgs {
                tag: Some("perri"),
                placeholder: None,
                params: Some(&params),
            },
        )
        .unwrap_err();
        assert_eq!(err, ApplyLayoutError::UnknownCommentId);
    }

    #[test]
    fn apply_layout_error_unknown_comment_id_has_the_expected_code_and_leaves_content_intact() {
        assert_eq!(ApplyLayoutError::UnknownCommentId.code(), "unknown_comment_id");
        assert!(ApplyLayoutError::UnknownCommentId.leaves_content_intact());
    }

    #[test]
    fn source_content_kind_and_source_is_known_include_perri_get_pr_conversation() {
        assert!(source_is_known(SOURCE_PR_CONVERSATION));
        assert_eq!(source_content_kind(SOURCE_PR_CONVERSATION), Some("pr_conversation"));
    }

    // ── nostromo.get_ticket (W4 — curated-agent-views) ────────────────────────

    #[test]
    fn source_content_kind_and_source_is_known_include_nostromo_get_ticket() {
        assert!(source_is_known(SOURCE_TICKET));
        assert_eq!(source_content_kind(SOURCE_TICKET), Some("ticket"));
    }

    #[tokio::test]
    async fn fetch_ticket_with_an_unregistered_provider_is_unsupported_provider_naming_jira() {
        // A deployment with `jira` registered (production shape) — "linear"
        // was never registered, but "jira" was, so the refusal must name it.
        let (state, _bcast) = make_state_with_tickets(unconfigured_jira_tickets_state());
        let params = json!({ "provider": "linear", "key": "X-1" });
        let err = fetch_async(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "unsupported_provider");
        assert!(
            err.detail().unwrap().contains("jira"),
            "the refusal must name the deployment's actual supported providers"
        );
    }

    #[tokio::test]
    async fn fetch_ticket_with_an_unconfigured_jira_provider_is_provider_unconfigured() {
        let (state, _bcast) = make_state_with_tickets(unconfigured_jira_tickets_state());
        let params = json!({ "provider": "jira", "key": "X-1" });
        let err = fetch_async(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "provider_unconfigured");
    }

    #[tokio::test]
    async fn fetch_ticket_wiremock_404_is_unknown_ticket() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/MISSING-1"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let (state, _bcast) =
            make_state_with_tickets(jira_tickets_state(server.uri(), Duration::from_secs(60)));
        let params = json!({ "provider": "jira", "key": "MISSING-1" });
        let err = fetch_async(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "unknown_ticket");
    }

    #[tokio::test]
    async fn fetch_ticket_happy_path_then_a_bad_anchor_is_unknown_section_and_leaves_content_intact()
    {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/PROJ-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jira_issue_body("Fix the thing")))
            .mount(&server)
            .await;

        let (state, _bcast) =
            make_state_with_tickets(jira_tickets_state(server.uri(), Duration::from_secs(60)));

        // First call establishes content: no anchor, must succeed.
        let good_params = json!({ "provider": "jira", "key": "PROJ-1" });
        let content = fetch_async(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&good_params) },
        )
        .await
        .expect("the happy path must succeed");
        match content {
            PaneContentWire::Ticket { summary, .. } => assert_eq!(summary, "Fix the thing"),
            other => panic!("expected Ticket content, got {other:?}"),
        }

        // Second call: an anchor naming a section that doesn't exist on the
        // fetched ticket must refuse with unknown_section, and that refusal
        // must be one that leaves the pane's prior content untouched.
        let bad_params = json!({
            "provider": "jira", "key": "PROJ-1",
            "anchor": { "kind": "section", "name": "does-not-exist" }
        });
        let err = fetch_async(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&bad_params) },
        )
        .await
        .unwrap_err();
        assert_eq!(err.code(), "unknown_section");
        assert!(
            err.leaves_content_intact(),
            "an unknown_section refusal must leave a pane's existing content untouched"
        );
    }

    #[tokio::test]
    async fn fetch_ticket_two_calls_within_the_ttl_window_hit_the_provider_exactly_once() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/issue/PROJ-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jira_issue_body("Fix the thing")))
            .mount(&server)
            .await;

        let (state, _bcast) =
            make_state_with_tickets(jira_tickets_state(server.uri(), Duration::from_secs(60)));
        let params = json!({ "provider": "jira", "key": "PROJ-1" });

        for _ in 0..2 {
            fetch_async(
                SOURCE_TICKET,
                &state,
                FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
            )
            .await
            .expect("both calls within the TTL window must succeed");
        }

        assert_eq!(
            server.received_requests().await.unwrap().len(),
            1,
            "two shows of the same ticket inside the TTL window must issue exactly one HTTP request"
        );
    }

    #[test]
    fn fetch_sync_ticket_cache_miss_returns_fetch_failed_with_no_network_call() {
        // No wiremock server at all — the sync `fetch` path must never touch
        // the network regardless of whether a provider is registered.
        let (state, _bcast) = make_state();
        let params = json!({ "provider": "jira", "key": "PROJ-1" });
        let err = fetch(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
        )
        .unwrap_err();
        assert_eq!(err, ApplyLayoutError::FetchFailed);
    }

    #[test]
    fn fetch_sync_ticket_cache_hit_returns_ticket_content_with_no_provider_involved() {
        let (state, _bcast) = make_state();
        let daemon = state.daemon.as_ref().unwrap();
        let ticket = Ticket {
            provider: "jira".into(),
            key: "PROJ-1".into(),
            summary: "Cached summary".into(),
            status: "Open".into(),
            assignee: None,
            url: "".into(),
            sections: vec![],
            comments: vec![],
        };
        daemon.tickets.cache.put("jira", "PROJ-1", ticket);

        let params = json!({ "provider": "jira", "key": "PROJ-1" });
        let content = fetch(
            SOURCE_TICKET,
            &state,
            FetchArgs { tag: Some("cody"), placeholder: None, params: Some(&params) },
        )
        .expect("a cache hit must succeed with no registry/provider involved at all");
        match content {
            PaneContentWire::Ticket { summary, .. } => assert_eq!(summary, "Cached summary"),
            other => panic!("expected Ticket content, got {other:?}"),
        }
    }

    #[test]
    fn apply_layout_error_ticket_fetch_failed_stays_loud_but_every_other_ticket_error_leaves_content_intact()
    {
        assert!(
            !ApplyLayoutError::Ticket(TicketError::FetchFailed("x".into())).leaves_content_intact(),
            "a live provider failure must stay loud, mirroring FetchFailed on every other source"
        );
        assert!(ApplyLayoutError::Ticket(TicketError::UnsupportedProvider { supported: vec![] })
            .leaves_content_intact());
        assert!(ApplyLayoutError::Ticket(TicketError::ProviderUnconfigured {
            message: "x".into()
        })
        .leaves_content_intact());
        assert!(ApplyLayoutError::Ticket(TicketError::UnknownTicket).leaves_content_intact());
        assert!(ApplyLayoutError::Ticket(TicketError::UnknownSection { available: vec![] })
            .leaves_content_intact());
    }

    #[test]
    fn apply_layout_error_ticket_code_and_detail_delegate_to_the_wrapped_ticket_error() {
        let err =
            ApplyLayoutError::Ticket(TicketError::UnsupportedProvider { supported: vec!["jira".into()] });
        assert_eq!(err.code(), "unsupported_provider");
        assert!(err.detail().unwrap().contains("jira"));
    }

    // ── RequestPin / pin_for_request (W5 — current-pr-collision) ─────────────
    //
    // `pin_for_request` is the single place that reads "what PR is pinned
    // right now" for a request's purposes — a `RequestPin` names the repo,
    // number, and head sha, or `None` when nothing is under review. `tag` is
    // accepted but intentionally unused today (see the doc comment Cody
    // writes on `pin_for_request`) so a later per-focus-isolation change is a
    // body-only change with no call-site sweep.

    #[test]
    fn pin_for_request_reflects_the_pinned_prs_repo_number_and_head_sha() {
        let mut snap = snapshot_with(Some(42), None);
        snap.head_sha = "abc123".to_string();
        let state = state_with_pr_snapshot(snap);

        let pin = pin_for_request(&state, Some("perri"));
        assert_eq!(
            pin,
            Some(RequestPin {
                repo: "acme/web".into(),
                number: 42,
                head_sha: "abc123".into(),
            })
        );
    }

    #[test]
    fn pin_for_request_is_none_when_the_snapshot_describes_no_pr_under_review() {
        let state = state_with_pr_snapshot(snapshot_with(None, None));
        assert_eq!(pin_for_request(&state, Some("perri")), None);
    }

    #[test]
    fn pin_for_request_is_none_with_no_snapshot_seeded_at_all() {
        let (state, _bcast) = make_state();
        assert_eq!(pin_for_request(&state, Some("perri")), None);
    }

    // ── SOURCE_FILE's async fetch: a pin for a different repo refuses rather
    // than serving that foreign PR's content (W5 — current-pr-collision) ─────
    //
    // The bug this closes: a second session repins the PR (`perri.load_pr`)
    // while this focus is reviewing something rooted in a different repo. An
    // *implicit* revision never reaches this refusal at all — it degrades
    // straight to the working tree (see `file_source.rs`'s own
    // `resolve_revision` tests) and reads local content correctly. What must
    // refuse is an *explicit* revision that only the foreign, mismatched
    // pinned repo could resolve: without this check, the async GitHub
    // fallback would serve it anyway, rendering the wrong repo's content.

    #[tokio::test]
    async fn fetch_async_source_file_refuses_when_the_pinned_repo_does_not_match_the_tags_session_cwd(
    ) {
        // 1. A real temp git repo as the tag's session cwd, with an origin
        // remote this focus actually belongs to.
        let repo = tempfile::TempDir::new().unwrap();
        std::process::Command::new("git")
            .arg("-C").arg(repo.path())
            .args(["init", "-q", "-b", "main"])
            .status()
            .unwrap();
        std::process::Command::new("git")
            .arg("-C").arg(repo.path())
            .args(["remote", "add", "origin", "git@github.com:acme/root-repo.git"])
            .status()
            .unwrap();
        std::fs::write(repo.path().join("src.rs"), b"root repo content\n").unwrap();
        std::process::Command::new("git")
            .arg("-C").arg(repo.path())
            .args(["add", "src.rs"])
            .status()
            .unwrap();
        std::process::Command::new("git")
            .arg("-C").arg(repo.path())
            .args([
                "-c", "user.email=redd@example.com",
                "-c", "user.name=Redd Test",
                "-c", "commit.gpgsign=false",
                "commit", "-q", "-m", "initial",
            ])
            .status()
            .unwrap();

        let (state, _bcast) = make_state();

        // Wire "perri"'s session cwd to this repo. `spawn_session` is the
        // only way `SessionManager` records a tag's cwd; `CLAUDE_BIN_ENV`
        // is pointed at `/bin/sh` so the real spawn never touches the
        // real `claude` binary (mirrors `session_manager.rs`'s own
        // `after_spawn_session_tag_for_session_id_resolves` fixture) — the
        // child's behavior is irrelevant here, only the recorded cwd matters.
        std::env::set_var(crate::ipc::session_manager::CLAUDE_BIN_ENV, "/bin/sh");
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut mgr = daemon.session_mgr.lock().unwrap();
            mgr.spawn_session(
                "perri".into(),
                "perri".into(),
                "Perri".into(),
                Some(repo.path().to_path_buf()),
                None,
                false,
            )
            .expect("spawn stub session");
        }
        std::env::remove_var(crate::ipc::session_manager::CLAUDE_BIN_ENV);

        // 2. Seed perri_pr_rx with a PrSnapshot pinned to a DIFFERENT repo, at
        // a plausible-but-nonexistent head sha (so a local git resolution
        // would fail and fall through to the GitHub-fallback decision this
        // test is actually about).
        let mut state = state;
        let (_tx, rx) = tokio::sync::watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(json!({
                "pr_number": 99, "repo": "acme/other-repo", "title": "Unrelated",
                "author": "bob", "url": "https://example.com", "diff": "",
                "stale": false, "error": null,
                "head_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
            }))
            .unwrap(),
        ));
        state.perri_pr_rx = rx;

        // 3. Deliberately an EXPLICIT, git-unresolvable revision — not an
        // implicit one. `resolve_revision`'s own pinned contract (see
        // `file_source.rs`'s `resolve_revision_absent_with_a_pin_for_a_different_repo_...`
        // test) already degrades an *implicit* mismatch straight to the
        // working tree, which here would just successfully read "src.rs"
        // off disk (it's committed, so it exists there too) — that's
        // correct behavior, not what this test is about. This test is about
        // the *other* refusal: an explicit revision only a foreign
        // (mismatched) pinned repo could possibly serve, once the local
        // clone can't resolve it.
        let params = json!({
            "path": "src.rs",
            "revision": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        });
        let result = fetch_async(
            SOURCE_FILE,
            &state,
            FetchArgs { tag: Some("perri"), placeholder: None, params: Some(&params) },
        )
        .await;

        // 4. Must refuse with RevisionRepoMismatch — never Ok, never a bare
        // UnresolvableRevision (which would mean "we tried GitHub against the
        // mismatched repo and it happened to fail", not "we refused to try").
        assert_eq!(
            result,
            Err(ApplyLayoutError::FileRefused(FileSourceError::RevisionRepoMismatch)),
            "an explicit revision that only a foreign pinned repo could serve must refuse \
             rather than fetch against a repo the caller's own session cwd doesn't match"
        );
    }

    // TODO(cody): the test above drives a real `spawn_session` (with
    // `CLAUDE_BIN_ENV` pointed at `/bin/sh`) to give "perri" a session cwd —
    // this is the confirmed fixture, mirroring `session_manager.rs`'s own
    // `after_spawn_session_tag_for_session_id_resolves`/`after_restart_...`
    // tests. If that spawn path ever proves too heavy/flaky in CI, the same
    // scenario is also provable purely against `file_source::resolve_revision`
    // + `file_source::github_fallback_trusted` composed together (see
    // `file_source.rs`'s `a_path_shared_by_both_repos_always_resolves_to_the_local_repos_own_content`
    // for that pure-function version of the identical scenario).
}
