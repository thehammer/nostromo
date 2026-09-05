//! MCP tool handler for `nostromo.show` (W5 — curated-agent-views).
//!
//! The curated deliberate surface: one tool, a closed view vocabulary, and a
//! deterministic placement engine behind it. This is where the PRD's central
//! reversal lands — "the interactive agent no longer reaches the raw pane
//! tools; `set_pane_content`, `set_pane_layout`, `create_pane`, `reset_panes`,
//! `apply_layout` and `refresh_pane_content` become implementation details
//! this layer uses internally."
//!
//! ```text
//! nostromo.show({
//!   type:     "review_queue" | "pr_conversation" | "pr_diff" | "file" | "ticket",
//!   target:   {…},          // shape depends on type; omitted for review_queue
//!   anchor:   {…}?,         // an Anchor payload
//!   emphasis: [{…}]?,       // Emphasis payloads
//!   reason:   "unbounded retry loop"?,
//!   view_id:  "perri"?      // defaults to the caller's own focus
//! })
//! ```
//!
//! ## Order of operations, and why
//!
//! Validate → place → **fetch** → mutate → broadcast. The fetch happens before
//! any tree mutation because "a show with a malformed target is refused with a
//! distinct error and leaves the existing layout untouched" is a product
//! criterion: a bad show must never destroy what the operator was reading. A
//! refusal at any step before the mutation leaves the focus byte-identical.
//!
//! ## What this handler is *not* allowed to grow
//!
//! No modal type and no free-text content field (R7 — a modal carries a
//! decision only, and W6 owns that surface); no `activity` type (W7 owns the
//! ambient path, and an agent that could push into it would make the stream
//! untrustworthy as a record); and no placement decision — every one of those
//! lives in [`crate::mcp::views::placement`], as data-driven rules.

use serde_json::{json, Value};

use crate::data::file_source::FileSourceError;
use crate::ipc::pane_registry::SplitPosition;
use crate::ipc::protocol::{Anchor, Emphasis, ServerMsg};
use crate::mcp::pane_sources::broadcast_pane_content_with_address;
use crate::mcp::state::{DaemonMcpBackend, McpSharedState};
use crate::mcp::tools::apply_layout::{
    address, fetch_async, freshness, pin_for_request, target_tag, ApplyLayoutError, FetchArgs,
    SOURCE_FILE, SOURCE_PR_CONVERSATION, SOURCE_PR_DIFF, SOURCE_PR_QUEUE, SOURCE_TICKET,
};
use crate::mcp::views::{
    self, config as views_config, derive, placement, tree as view_tree, PlacementError, ShowRequest,
    ViewIdentity, ViewType,
};

/// Handle `nostromo.show`.
pub async fn show(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({
            "error": "not_supported",
            "detail": "nostromo.show requires the daemon-hosted MCP server",
        });
    };

    // ── validate, before anything at all is touched ─────────────────────────
    let view_type = match args.get("type").and_then(|v| v.as_str()) {
        Some(s) => match ViewType::parse(s) {
            Ok(t) => t,
            Err(e) => return refusal(&e),
        },
        None => {
            return refusal(&PlacementError::UnknownViewType(
                args.get("type")
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "<missing>".to_string()),
            ))
        }
    };

    let identity = match identity_from_target(view_type, args.get("target")) {
        Ok(id) => id,
        Err(e) => return refusal(&e),
    };

    let params = match source_params(view_type, &identity, args) {
        Ok(p) => p,
        Err(e) => return refusal(&e),
    };
    let source = source_for(view_type);

    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    let cfg = match views_config::load() {
        Ok(c) => c,
        Err(e) => return refusal(&e),
    };

    // ── decide ──────────────────────────────────────────────────────────────
    let request = ShowRequest::new(view_type, identity.clone());
    // Captured under the same lock acquisition `placement` is decided under,
    // so the mutate step below can tell whether the tree it's about to write
    // into is still the one `place()` actually reasoned about. Between here
    // and the re-lock after `fetch_async().await`, this handler holds no
    // lock at all (a `std::sync::Mutex` can't be held across an `.await`),
    // so a second `nostromo.show`/`perri.load_pr`/`perri.clear_current_pr`
    // targeting the same tag from a different connection can mutate the
    // registry in between. Without this check, the mutate step below would
    // silently transcribe a stale decision onto whatever the tree looks like
    // *now* — reintroducing panes a concurrent R8 reset just closed (with no
    // binding, since that reset already pruned it), or clobbering a
    // concurrent show's own new tab — instead of refusing cleanly.
    let (placement, tree_at_decide) = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        reg.get_or_init(&tag);
        let view_state = current_view_state(daemon, state, &mut reg, &cfg, &tag);
        let placement = match placement::place(&cfg, &view_state, &request) {
            Ok(p) => p,
            Err(e) => return refusal(&e),
        };
        let tree_at_decide = reg.get(&tag).cloned();
        (placement, tree_at_decide)
    };

    // ── fetch, still before any mutation ────────────────────────────────────
    //
    // A refusal here — a line past EOF, a path that doesn't exist, an unknown
    // ticket section, a comment id that names no comment — must leave the
    // focus exactly as it was. Nothing below this point has run yet, so it
    // does.
    let fetch_args = FetchArgs {
        tag: Some(&tag),
        placeholder: None,
        params: Some(&params),
    };
    let content = match fetch_async(source, state, fetch_args).await {
        Ok(c) => c,
        Err(e) => {
            let mut payload = json!({
                "error": e.code(),
                "detail": e.detail().unwrap_or_else(|| format!(
                    "nostromo.show: {source} fetch failed ({})", e.code()
                )),
            });
            // D1 (W5 — current-pr-collision): a bare refusal on the
            // file/revision-resolution path is confusing specifically when a
            // foreign PR is pinned — the real production bug was an agent
            // hitting `unknown_path` with no idea a second session had
            // repinned the PR out from under it. Scoped strictly to that
            // path (never "every error, whenever a PR happens to be
            // pinned" — noise devalues the signal) and, for most refusals,
            // strictly to an *implicit* revision — an explicit one means the
            // caller already knows exactly what it asked for.
            //
            // `RevisionRepoMismatch` is the one exception to the
            // implicit-only rule, and deliberately so: it is *only ever*
            // produced when the revision was explicit (an implicit revision
            // with a mismatched pin degrades to the working tree and fails
            // as `UnknownPath` instead, never reaching this error at all —
            // see `resolve_via_github_fallback`). If this error stayed
            // gated on "implicit revision only", it could never carry the
            // pin — the one refusal whose entire reason for existing is a
            // pin mismatch would be the one refusal that doesn't name the
            // pin. The caller naming a revision here doesn't mean it knows
            // a *foreign PR pin* is why it was refused, so decorate this
            // variant unconditionally.
            let is_revision_repo_mismatch = matches!(
                e,
                ApplyLayoutError::FileRefused(FileSourceError::RevisionRepoMismatch)
            );
            if source == SOURCE_FILE
                && matches!(e, ApplyLayoutError::FileRefused(_))
                && (is_revision_repo_mismatch
                    || params.get("revision").and_then(Value::as_str).is_none())
            {
                if let Some(pin) = pin_for_request(state, Some(tag.as_str())) {
                    payload["current_pin"] = pin.wire();
                }
            }
            return payload;
        }
    };

    // ── mutate, then broadcast ──────────────────────────────────────────────
    let tree = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        let Some(mut tree) = reg.get(&tag).cloned() else {
            return json!({ "error": "unknown_view" });
        };
        // `placement` was decided against `tree_at_decide`, under a lock this
        // handler released before the `fetch_async().await` above — a
        // concurrent `nostromo.show`/`perri.load_pr`/`perri.clear_current_pr`
        // targeting the same tag could have mutated the registry in that
        // window. Applying `placement` to a tree it was never actually
        // computed against would transcribe a stale decision: silently
        // resurrecting a pane a concurrent R8 reset just closed (and already
        // unbound), or clobbering that other call's own new tab. Refuse
        // instead — the caller can simply retry, exactly as any other
        // refusal here leaves the layout untouched.
        if tree_changed_since_decide(Some(&tree), &tree_at_decide) {
            return json!({
                "error": "concurrent_modification",
                "detail": "the view's layout changed while this show was in flight; retry",
            });
        }
        if let Err(e) = apply_to_tree(&mut tree, &placement) {
            return refusal(&e);
        }
        match reg.set_layout(&tag, &json!({ "tree": tree })) {
            // `set_layout`'s own `prune_to_tree` drops the bindings of every
            // pane the new tree no longer has, which is exactly what an
            // eviction and an R8 reset each need — no separate unbind pass.
            Ok(t) => {
                reg.bind_source_with_params(&tag, &placement.pane_id, source, Some(params.clone()));
                reg.touch_view_focus(&tag, &placement.tab_order, &placement.pane_id);
                t
            }
            Err(e) => return json!({ "error": e.code() }),
        }
    };

    // R5: focus is taken unconditionally, new tab or reused. A settled PRD
    // decision — see `views::placement`'s module doc.
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
        tag: tag.clone(),
        tree,
        focused_pane: Some(placement.pane_id.clone()),
    });

    broadcast_pane_content_with_address(
        daemon,
        &tag,
        &placement.pane_id,
        content,
        Some(freshness(source, state)),
        address(source, Some(&params)),
    );

    json!({
        "ok": true,
        "region": placement.region,
        "pane_id": placement.pane_id,
        "label": placement.labels[placement.tab_index],
        "tab_index": placement.tab_index,
        "reused": placement.reused,
        "frontmost": true,
        "evicted": placement.evicted,
        "closed": placement.reset_closed,
    })
}

// ── R8's other trigger ───────────────────────────────────────────────────────

/// Close every curated tab whose review context just went stale, because the
/// PR under review moved (R8).
///
/// Called by `perri.load_pr` and `perri.clear_current_pr`. `new_pr` is `None`
/// when the PR was cleared. A no-op — and no broadcast — for a focus with no
/// curated regions, which is every focus still driving `perri-standard`
/// through the raw tools.
///
/// The surviving `pr_conversation` / `pr_diff` tabs need no retargeting: both
/// sources render whatever the daemon currently has under review, so their
/// content follows the change through the ordinary broadcaster with no tool
/// call. Only the tabs that can *not* follow it — a previous PR's views, and
/// the `file`/`ticket` tabs that belonged to that review — are closed here.
///
/// Returns the pane ids that were closed, empty when this was a no-op (no
/// curated regions for `tag`, or nothing stale) — so a caller like
/// `perri.clear_current_pr` can report truthfully what it tore down.
pub fn reset_for_pr_change(daemon: &DaemonMcpBackend, tag: &str, new_pr: Option<(&str, u64)>) -> Vec<String> {
    let Ok(cfg) = views_config::load() else {
        return Vec::new();
    };
    let (broadcast, closed) = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        let Some(tree) = reg.get(tag).cloned() else {
            return Vec::new();
        };
        let bindings = bindings_for(&reg, tag);
        // `new_pr` is already the PR under review by the time this runs, so it
        // is also the right value to resolve a paramless PR binding against.
        let live: Vec<String> = tree.pane_ids();
        let order = reg.view_focus_order(tag, &live);
        let state = derive::view_state(&cfg, &tree, &bindings, new_pr, &order);
        let closed = placement::reset_for_pr_change(&cfg, &state, new_pr);
        if closed.is_empty() {
            return Vec::new();
        }

        let mut tree = tree;
        for region_name in cfg.regions.keys() {
            let Some(region) = state.region(region_name) else {
                continue;
            };
            let survivors: Vec<(String, String)> = region
                .tabs
                .iter()
                .filter(|t| !closed.contains(&t.pane_id))
                .map(|t| {
                    let label = t
                        .view
                        .as_ref()
                        .map(|v| views::label_for(v.view_type, &v.identity))
                        .unwrap_or_else(|| t.pane_id.clone());
                    (t.pane_id.clone(), label)
                })
                .collect();
            if survivors.len() == region.tabs.len() {
                continue;
            }
            if !cfg.regions[region_name].tabbed {
                // A non-tabbed region holds the queue, which belongs to no
                // review and is never closed by a PR change.
                continue;
            }
            // D5: the region goes away with its last tab rather than lingering
            // as an empty frame.
            if survivors.is_empty() {
                view_tree::remove_tabs_region(&mut tree, region_name);
            } else {
                let active = region
                    .active
                    .and_then(|i| region.tabs.get(i))
                    .and_then(|t| survivors.iter().position(|(id, _)| id == &t.pane_id))
                    .unwrap_or(0);
                view_tree::replace_tabs_region(
                    &mut tree,
                    region_name,
                    view_tree::build_tabs(region_name, &survivors, active),
                );
            }
        }
        (reg.set_layout(tag, &json!({ "tree": tree })).ok(), closed)
    };

    if let Some(tree) = broadcast {
        let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
            tag: tag.to_string(),
            tree,
            focused_pane: None,
        });
    }
    closed
}

// ── argument mapping ─────────────────────────────────────────────────────────

/// The fetcher source a view type is served by. The curated layer adds no new
/// sources: every view here is one W2/W3/W4 already built, reached through the
/// same closed registry `apply_layout` and `refresh_pane_content` use, which is
/// what stops the two surfaces disagreeing about what a source produces.
fn source_for(view_type: ViewType) -> &'static str {
    match view_type {
        ViewType::ReviewQueue => SOURCE_PR_QUEUE,
        ViewType::PrConversation => SOURCE_PR_CONVERSATION,
        ViewType::PrDiff => SOURCE_PR_DIFF,
        ViewType::File => SOURCE_FILE,
        ViewType::Ticket => SOURCE_TICKET,
    }
}

/// The identity a `target` object names, refused with `invalid_target` when it
/// is absent or the wrong shape for this view type.
fn identity_from_target(
    view_type: ViewType,
    target: Option<&Value>,
) -> Result<ViewIdentity, PlacementError> {
    let bad = |what: &str| {
        PlacementError::InvalidTarget(format!(
            "`{}` needs target {what}",
            view_type.as_str()
        ))
    };

    if view_type == ViewType::ReviewQueue {
        // A singleton takes no target. An extra one is ignored rather than
        // refused — there is nothing it could have meant, and refusing would
        // punish a caller for being over-explicit.
        return Ok(ViewIdentity::Singleton);
    }

    let target = target
        .filter(|v| !v.is_null())
        .ok_or_else(|| bad("`{…}`"))?;
    let obj = target.as_object().ok_or_else(|| bad("to be an object"))?;

    match view_type {
        ViewType::ReviewQueue => unreachable!("handled above"),
        ViewType::PrConversation | ViewType::PrDiff => {
            let repo = obj
                .get("repo")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| bad("`{repo, number}`; `repo` is missing or empty"))?;
            if let Err(e) = crate::data::perri_current_pr::validate_repo_slug(repo) {
                return Err(PlacementError::InvalidTarget(e));
            }
            let number = obj
                .get("number")
                .and_then(|v| v.as_u64())
                .filter(|n| *n > 0)
                .ok_or_else(|| bad("`{repo, number}`; `number` is missing or not a positive integer"))?;
            Ok(ViewIdentity::Pr {
                repo: repo.to_string(),
                number,
            })
        }
        ViewType::File => {
            let path = obj
                .get("path")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| bad("`{path, revision?}`; `path` is missing or empty"))?;
            let revision = match obj.get("revision") {
                None | Some(Value::Null) => None,
                Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
                Some(_) => return Err(bad("`revision` to be a non-empty string when present")),
            };
            Ok(ViewIdentity::File {
                path: path.to_string(),
                revision,
            })
        }
        ViewType::Ticket => {
            let provider = obj
                .get("provider")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| bad("`{provider, key}`; `provider` is missing or empty"))?;
            let key = obj
                .get("key")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| bad("`{provider, key}`; `key` is missing or empty"))?;
            Ok(ViewIdentity::Ticket {
                provider: provider.to_string(),
                key: key.to_string(),
            })
        }
    }
}

/// Translate the uniform `(target, anchor, emphasis, reason)` contract into the
/// `params` object this view's source already understands.
///
/// This adapter is the whole reason `show` can present one uniform addressing
/// vocabulary over five sources that were each designed on their own: `file`
/// takes a bare `anchor_line` and `{start, end}` ranges, while the PR and
/// ticket sources take `Anchor`/`Emphasis` payloads verbatim. An anchor of the
/// wrong *kind* for the view is refused rather than dropped, because silently
/// ignoring "line 412" would leave the agent believing it had pointed at
/// something.
fn source_params(
    view_type: ViewType,
    identity: &ViewIdentity,
    args: &Value,
) -> Result<Value, PlacementError> {
    let mut params = serde_json::Map::new();

    match identity {
        ViewIdentity::Singleton => {}
        ViewIdentity::Pr { repo, number } => {
            params.insert("repo".into(), json!(repo));
            params.insert("number".into(), json!(number));
        }
        ViewIdentity::File { path, revision } => {
            params.insert("path".into(), json!(path));
            if let Some(r) = revision {
                params.insert("revision".into(), json!(r));
            }
        }
        ViewIdentity::Ticket { provider, key } => {
            params.insert("provider".into(), json!(provider));
            params.insert("key".into(), json!(key));
        }
    }

    if let Some(reason) = args
        .get("reason")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
    {
        params.insert("reason".into(), json!(reason));
    }

    let anchor = match args.get("anchor").filter(|v| !v.is_null()) {
        Some(v) => Some(
            serde_json::from_value::<Anchor>(v.clone()).map_err(|e| {
                PlacementError::InvalidAnchor(format!("`anchor` is not a valid anchor: {e}"))
            })?,
        ),
        None => None,
    };

    let emphasis: Vec<Emphasis> = match args.get("emphasis").filter(|v| !v.is_null()) {
        Some(Value::Array(items)) => items
            .iter()
            .map(|i| {
                serde_json::from_value::<Emphasis>(i.clone()).map_err(|e| {
                    PlacementError::InvalidEmphasis(format!(
                        "`emphasis` entry is not a valid emphasis: {e}"
                    ))
                })
            })
            .collect::<Result<_, _>>()?,
        Some(_) => {
            return Err(PlacementError::InvalidEmphasis(
                "`emphasis` must be an array".to_string(),
            ))
        }
        None => Vec::new(),
    };

    if view_type == ViewType::File {
        // `nostromo.get_file` predates the uniform contract and speaks in bare
        // line numbers; translate rather than teach it a second dialect.
        if let Some(anchor) = &anchor {
            let Anchor::Line { line, .. } = anchor else {
                return Err(PlacementError::InvalidAnchor(format!(
                    "`file` anchors on a line; got {}",
                    anchor_kind(anchor)
                )));
            };
            params.insert("anchor_line".into(), json!(line));
        }
        if !emphasis.is_empty() {
            let mut ranges = Vec::new();
            for e in &emphasis {
                let Emphasis::LineRange { start, end, .. } = e else {
                    return Err(PlacementError::InvalidEmphasis(format!(
                        "`file` emphasises line ranges; got {}",
                        emphasis_kind(e)
                    )));
                };
                ranges.push(json!({ "start": start, "end": end }));
            }
            params.insert("emphasis".into(), json!(ranges));
        }
    } else {
        if let Some(anchor) = &anchor {
            params.insert("anchor".into(), serde_json::to_value(anchor).unwrap());
        }
        if !emphasis.is_empty() {
            params.insert("emphasis".into(), serde_json::to_value(&emphasis).unwrap());
        }
    }

    Ok(Value::Object(params))
}

fn anchor_kind(a: &Anchor) -> &'static str {
    match a {
        Anchor::Line { .. } => "line",
        Anchor::Comment { .. } => "comment",
        Anchor::Section { .. } => "section",
        Anchor::QueueRow { .. } => "queue_row",
    }
}

fn emphasis_kind(e: &Emphasis) -> &'static str {
    match e {
        Emphasis::LineRange { .. } => "line_range",
        Emphasis::Comment { .. } => "comment",
        Emphasis::Section { .. } => "section",
        Emphasis::TextRange { .. } => "text_range",
        Emphasis::QueueRow { .. } => "queue_row",
    }
}

// ── the decide/fetch/mutate race guard ──────────────────────────────────────

/// Whether the registry's tree for this tag has moved since `placement` was
/// decided against `tree_at_decide` — the only signal `show()` has that a
/// concurrent call (another `nostromo.show`, or `perri.load_pr`/
/// `perri.clear_current_pr`'s own `reset_for_pr_change`) landed in the window
/// between releasing the decide-time lock and re-acquiring it to mutate,
/// since a `std::sync::Mutex` can't be held across the `fetch_async().await`
/// in between. `PaneTree`'s derived `PartialEq` makes this an exact
/// structural comparison — any difference at all, not just an overlapping
/// pane id, counts as drift, because `apply_to_tree` transcribes the whole
/// region's tab order unconditionally rather than merging.
fn tree_changed_since_decide(
    current: Option<&crate::ipc::protocol::PaneTree>,
    tree_at_decide: &Option<crate::ipc::protocol::PaneTree>,
) -> bool {
    current != tree_at_decide.as_ref()
}

// ── applying a placement ─────────────────────────────────────────────────────

/// Turn a [`placement::Placement`] into the tree it describes.
///
/// A transcription, not a second implementation of the rules: the placement
/// already carries the region's whole resulting tab order, labels and frontmost
/// index, so nothing here decides anything. The finished tree then goes through
/// the registry's own `set_layout`, which is what applies the exactly-one-repl,
/// unique-ids and well-formed-node invariants to a curated show for free.
fn apply_to_tree(
    tree: &mut crate::ipc::protocol::PaneTree,
    placement: &placement::Placement,
) -> Result<(), PlacementError> {
    let tabs: Vec<(String, String)> = placement
        .tab_order
        .iter()
        .cloned()
        .zip(placement.labels.iter().cloned())
        .collect();

    match &placement.create_region {
        Some(creation) => {
            let position = SplitPosition::parse(&creation.position).map_err(|_| {
                PlacementError::InvalidConfig(format!(
                    "`{}` is not a split position",
                    creation.position
                ))
            })?;
            let node = if placement.tabbed {
                view_tree::build_tabs(&placement.region, &tabs, placement.tab_index)
            } else {
                crate::ipc::protocol::PaneTree::Leaf {
                    pane_id: placement.pane_id.clone(),
                }
            };
            if !view_tree::insert_beside(
                tree,
                &creation.relative_to,
                position,
                &creation.ratios,
                node,
            ) {
                return Err(PlacementError::RegionNotCreatable(placement.region.clone()));
            }
        }
        None if placement.tabbed
            && !view_tree::replace_tabs_region(
                tree,
                &placement.region,
                view_tree::build_tabs(&placement.region, &tabs, placement.tab_index),
            ) =>
        {
            return Err(PlacementError::RegionNotCreatable(placement.region.clone()));
        }
        // A non-tabbed region that already exists is one leaf holding one
        // view: the tree needs no change at all, only the rebinding the caller
        // does next.
        None => {}
    }
    Ok(())
}

// ── state derivation ─────────────────────────────────────────────────────────

/// Every binding for `tag`, as a `pane_id → binding` map.
fn bindings_for(
    reg: &crate::ipc::pane_registry::PaneRegistry,
    tag: &str,
) -> std::collections::BTreeMap<String, crate::ipc::pane_registry::SourceBinding> {
    reg.all_bindings()
        .into_iter()
        .filter(|(t, _, _)| t == tag)
        .map(|(_, pane_id, binding)| (pane_id, binding))
        .collect()
}

/// Derive the focus's [`views::ViewState`] from the registry, the PR under
/// review, and the in-memory focus order.
fn current_view_state(
    _daemon: &DaemonMcpBackend,
    state: &McpSharedState,
    reg: &mut crate::ipc::pane_registry::PaneRegistry,
    cfg: &views::ViewPlacementConfig,
    tag: &str,
) -> views::ViewState {
    let tree = reg.get(tag).cloned().unwrap_or_else(|| {
        crate::ipc::protocol::PaneTree::repl_leaf()
    });
    let bindings = bindings_for(reg, tag);
    let live = tree.pane_ids();
    let order = reg.view_focus_order(tag, &live);
    let snapshot = state.perri_pr_rx.borrow().clone();
    let current_pr = current_pr_of(snapshot.as_ref());
    derive::view_state(cfg, &tree, &bindings, current_pr, &order)
}

/// The `(repo, number)` the daemon currently has under review, when it has a
/// complete one. A snapshot mid-fetch can carry a repo with no number yet, and
/// half a PR identity is not one — pinning and R8 both key on the whole pair.
pub(crate) fn current_pr_of(
    snapshot: Option<&crate::data::perri_pr::PrSnapshot>,
) -> Option<(&str, u64)> {
    let snap = snapshot?;
    Some((snap.repo.as_str(), snap.pr_number?))
}

// ── refusals ─────────────────────────────────────────────────────────────────

/// A [`PlacementError`] as the tool's JSON refusal. Always carries a `detail`:
/// every refusal here is the agent naming something that doesn't resolve, and
/// a bare code leaves it guessing which part.
fn refusal(e: &PlacementError) -> Value {
    json!({ "error": e.code(), "detail": e.detail() })
}

/// The `nostromo.show` tool descriptor, kept beside the handler so the schema
/// and what the handler actually accepts can't drift.
pub fn descriptor() -> Value {
    json!({
        "name": "nostromo.show",
        "description": "\
Show one curated view in the operator's window and bring it to front. This is the \
deliberate attention-directing surface: name a view type from the closed vocabulary, \
say which one, optionally say where to look and why, and the placement engine decides \
where it lands. Returns where it landed so you can refer to it in conversation \
(\"the File tab\") rather than guessing.\n\n\
Types and their targets:\n\
  review_queue    — the PR review queue. No target. anchor/emphasis: a queue row.\n\
  pr_conversation — a PR's description and comment threads. target {repo, number}.\n\
  pr_diff         — a PR's change, line-addressable. target {repo, number}.\n\
  file            — a file at a revision, line-addressable. target {path, revision?}.\n\
  ticket          — an issue-tracker ticket. target {provider, key}.\n\n\
Showing the same (type, target) twice reuses one tab and re-anchors it — showing the \
same file at a different line is the same view, not a second tab. `activity` is not \
showable: the ambient activity stream is populated only by what actually happened.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "enum": ["review_queue", "pr_conversation", "pr_diff", "file", "ticket"],
                    "description": "Which view, from the closed vocabulary."
                },
                "target": {
                    "type": "object",
                    "description": "Which one. Omitted for review_queue (a singleton); {repo, number} for pr_conversation/pr_diff; {path, revision?} for file; {provider, key} for ticket.",
                    "properties": {
                        "repo":     { "type": "string", "description": "owner/name — pr_conversation, pr_diff." },
                        "number":   { "type": "integer", "minimum": 1, "description": "PR number — pr_conversation, pr_diff." },
                        "path":     { "type": "string", "description": "Repo-relative path — file." },
                        "revision": { "type": "string", "description": "Optional git revision — file. Defaults to the PR under review's head, else the working tree." },
                        "provider": { "type": "string", "description": "Issue-tracker provider, e.g. \"jira\" — ticket." },
                        "key":      { "type": "string", "description": "Ticket key, e.g. \"CORE-2841\" — ticket." }
                    },
                    "additionalProperties": false
                },
                "anchor": {
                    "type": "object",
                    "description": "Where to scroll on arrival. One of: {kind:\"line\", line, path?} (file, pr_diff); {kind:\"comment\", id} (pr_conversation); {kind:\"section\", name} (ticket); {kind:\"queue_row\", repo, number} (review_queue). An anchor of the wrong kind for the view is refused rather than ignored.",
                    "properties": {
                        "kind":   { "type": "string", "enum": ["line", "comment", "section", "queue_row"] },
                        "path":   { "type": "string" },
                        "line":   { "type": "integer", "minimum": 1 },
                        "id":     { "type": "string" },
                        "name":   { "type": "string" },
                        "repo":   { "type": "string" },
                        "number": { "type": "integer", "minimum": 1 }
                    },
                    "required": ["kind"],
                    "additionalProperties": false
                },
                "emphasis": {
                    "type": "array",
                    "description": "What to mark as significant. Entries: {kind:\"line_range\", start, end, path?}; {kind:\"comment\", id}; {kind:\"section\", name}; {kind:\"text_range\", start, end}; {kind:\"queue_row\", repo, number}.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "kind":   { "type": "string", "enum": ["line_range", "comment", "section", "text_range", "queue_row"] },
                            "path":   { "type": "string" },
                            "start":  { "type": "integer" },
                            "end":    { "type": "integer" },
                            "id":     { "type": "string" },
                            "name":   { "type": "string" },
                            "repo":   { "type": "string" },
                            "number": { "type": "integer", "minimum": 1 }
                        },
                        "required": ["kind"],
                        "additionalProperties": false
                    }
                },
                "reason": {
                    "type": "string",
                    "description": "One short human-readable phrase saying why, shown with the view — e.g. \"unbounded retry loop\"."
                },
                "view_id": {
                    "type": "string",
                    "description": "Target focus tag. Defaults to the caller's own focus."
                }
            },
            "required": ["type"]
        }
    })
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::protocol::{PaneTree, SplitDirection};
    use crate::ipc::SessionManager;
    use crate::mcp::state::{PerriDaemonState, TicketRegistryState};
    use std::sync::{Arc, Mutex};
    use tokio::sync::broadcast;

    /// The established daemon-backed handler harness (see
    /// `refresh_pane.rs`'s `make_state`): a real registry, a real broadcast
    /// channel, and a receiver to assert the exact message sequence on.
    fn make_state() -> (McpSharedState, broadcast::Receiver<ServerMsg>) {
        let tmp = tempfile::tempdir().unwrap();
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        std::mem::forget(tmp);
        let (broadcast_tx, rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
            session_mgr,
            broadcast_tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
            tickets: TicketRegistryState::default(),
        };
        (McpSharedState::for_daemon(backend), rx)
    }

    fn registry(state: &McpSharedState) -> Arc<Mutex<PaneRegistry>> {
        state.daemon.as_ref().unwrap().pane_registry.clone()
    }

    fn tree_of(state: &McpSharedState, tag: &str) -> Option<PaneTree> {
        registry(state).lock().unwrap().get(tag).cloned()
    }

    /// Seed `tag` with `perri-curated`'s starting tree: a bound queue, a repl.
    fn seed_curated(state: &McpSharedState, tag: &str) {
        let reg = registry(state);
        let mut reg = reg.lock().unwrap();
        reg.get_or_init(tag);
        reg.set_layout(
            tag,
            &json!({ "tree": PaneTree::Split {
                direction: SplitDirection::Vertical,
                children: vec![
                    PaneTree::Leaf { pane_id: "queue".into() },
                    PaneTree::Leaf { pane_id: "repl".into() },
                ],
                ratios: vec![0.6, 0.4],
            }}),
        )
        .unwrap();
        reg.bind_source(tag, "queue", SOURCE_PR_QUEUE);
    }

    // ── 1. the closed vocabulary ──────────────────────────────────────────────

    #[tokio::test]
    async fn a_type_outside_the_vocabulary_is_refused_and_names_the_valid_types() {
        let (state, mut rx) = make_state();
        seed_curated(&state, "perri");
        let before = tree_of(&state, "perri");

        let out = show(&state, &json!({ "type": "terminal" }), Some("perri")).await;
        assert_eq!(out["error"], "unknown_view_type");
        for t in ViewType::ALL {
            assert!(out["detail"].as_str().unwrap().contains(t.as_str()));
        }
        assert_eq!(tree_of(&state, "perri"), before, "layout untouched");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "a refusal broadcasts nothing"
        );
    }

    #[tokio::test]
    async fn an_activity_show_is_refused_with_its_own_distinct_error() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        let out = show(&state, &json!({ "type": "activity" }), Some("perri")).await;
        assert_eq!(out["error"], "activity_not_pushable");
        assert_ne!(out["error"], "unknown_view_type");
    }

    #[tokio::test]
    async fn a_missing_type_is_refused_rather_than_defaulted() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        assert_eq!(
            show(&state, &json!({}), Some("perri")).await["error"],
            "unknown_view_type"
        );
    }

    // ── 2. malformed targets never touch the layout ───────────────────────────

    #[tokio::test]
    async fn a_malformed_target_is_refused_and_leaves_the_layout_untouched() {
        let (state, mut rx) = make_state();
        seed_curated(&state, "perri");
        let before = tree_of(&state, "perri");

        for args in [
            json!({ "type": "pr_diff" }),
            json!({ "type": "pr_diff", "target": {} }),
            json!({ "type": "pr_diff", "target": { "repo": "o/r" } }),
            json!({ "type": "pr_diff", "target": { "repo": "o/r", "number": 0 } }),
            json!({ "type": "file", "target": { "path": "" } }),
            json!({ "type": "ticket", "target": { "provider": "jira" } }),
        ] {
            let out = show(&state, &args, Some("perri")).await;
            assert_eq!(out["error"], "invalid_target", "for {args}");
            assert!(!out["detail"].as_str().unwrap().is_empty());
        }
        assert_eq!(tree_of(&state, "perri"), before);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn an_anchor_of_the_wrong_kind_for_the_view_is_refused_rather_than_dropped() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        let out = show(
            &state,
            &json!({
                "type": "file",
                "target": { "path": "a.rs" },
                "anchor": { "kind": "comment", "id": "c1" }
            }),
            Some("perri"),
        )
        .await;
        assert_eq!(out["error"], "invalid_anchor");
    }

    #[tokio::test]
    async fn an_emphasis_of_the_wrong_kind_for_the_view_is_refused() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        let out = show(
            &state,
            &json!({
                "type": "file",
                "target": { "path": "a.rs" },
                "emphasis": [{ "kind": "section", "name": "x" }]
            }),
            Some("perri"),
        )
        .await;
        assert_eq!(out["error"], "invalid_emphasis");
    }

    #[tokio::test]
    async fn an_unidentified_caller_targeting_no_view_is_refused() {
        let (state, _rx) = make_state();
        assert_eq!(
            show(&state, &json!({ "type": "review_queue" }), None).await["error"],
            "unidentified_caller"
        );
    }

    // ── 3. a successful show ──────────────────────────────────────────────────

    #[tokio::test]
    async fn showing_the_review_queue_reports_where_it_landed_and_broadcasts_layout_then_content() {
        let (state, mut rx) = make_state();
        seed_curated(&state, "perri");

        let out = show(&state, &json!({ "type": "review_queue" }), Some("perri")).await;
        assert_eq!(out["ok"], true);
        assert_eq!(out["region"], "queue");
        assert_eq!(out["pane_id"], "queue");
        assert_eq!(out["label"], "Queue");
        assert_eq!(out["tab_index"], 0);
        assert_eq!(out["reused"], true, "the queue pane was already the queue view");
        assert_eq!(out["frontmost"], true);
        assert_eq!(out["evicted"], Value::Null);

        // Exactly FocusLayout then PaneContent, in that order.
        let first = rx.recv().await.unwrap();
        let ServerMsg::FocusLayout { focused_pane, .. } = &first else {
            panic!("expected FocusLayout, got {first:?}")
        };
        assert_eq!(focused_pane.as_deref(), Some("queue"), "R5: focus is taken");

        let second = rx.recv().await.unwrap();
        let ServerMsg::PaneContent { pane_id, .. } = &second else {
            panic!("expected PaneContent, got {second:?}")
        };
        assert_eq!(pane_id, "queue");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "and nothing else"
        );
    }

    #[tokio::test]
    async fn a_review_queue_row_anchor_reaches_the_wire_as_the_panes_address() {
        let (state, mut rx) = make_state();
        seed_curated(&state, "perri");

        show(
            &state,
            &json!({
                "type": "review_queue",
                "anchor": { "kind": "queue_row", "repo": "o/r", "number": 94 },
                "emphasis": [{ "kind": "queue_row", "repo": "o/r", "number": 94 }],
                "reason": "this one next"
            }),
            Some("perri"),
        )
        .await;

        let _layout = rx.recv().await.unwrap();
        let ServerMsg::PaneContent { address, .. } = rx.recv().await.unwrap() else {
            panic!("expected PaneContent")
        };
        let address = address.expect("a queue-row show addresses the pane");
        assert_eq!(
            address.anchor,
            Some(Anchor::QueueRow {
                repo: "o/r".into(),
                number: 94
            })
        );
        assert_eq!(
            address.emphasis,
            vec![Emphasis::QueueRow {
                repo: "o/r".into(),
                number: 94
            }]
        );
        assert_eq!(address.reason.as_deref(), Some("this one next"));
    }

    #[tokio::test]
    async fn every_view_type_accepts_a_reason_and_carries_it_to_the_wire() {
        // `review_queue` is the one type whose fetch always succeeds with no
        // external dependency, so it is the one this can assert end to end;
        // `source_params` is where the other four's `reason` is built, and it
        // is exercised directly below.
        let (state, mut rx) = make_state();
        seed_curated(&state, "perri");
        show(
            &state,
            &json!({ "type": "review_queue", "reason": "unbounded retry loop" }),
            Some("perri"),
        )
        .await;
        let _ = rx.recv().await.unwrap();
        let ServerMsg::PaneContent { address, .. } = rx.recv().await.unwrap() else {
            panic!()
        };
        assert_eq!(
            address.unwrap().reason.as_deref(),
            Some("unbounded retry loop")
        );

        for (view_type, identity) in [
            (ViewType::PrDiff, ViewIdentity::Pr { repo: "o/r".into(), number: 1 }),
            (ViewType::PrConversation, ViewIdentity::Pr { repo: "o/r".into(), number: 1 }),
            (ViewType::File, ViewIdentity::File { path: "a.rs".into(), revision: None }),
            (ViewType::Ticket, ViewIdentity::Ticket { provider: "jira".into(), key: "C-1".into() }),
        ] {
            let params =
                source_params(view_type, &identity, &json!({ "reason": "because" })).unwrap();
            assert_eq!(params["reason"], "because", "{view_type:?}");
        }
    }

    // ── 4. the params adapter ─────────────────────────────────────────────────

    #[test]
    fn a_file_show_translates_the_uniform_anchor_into_the_sources_own_line_dialect() {
        let params = source_params(
            ViewType::File,
            &ViewIdentity::File {
                path: "src/a.rs".into(),
                revision: None,
            },
            &json!({
                "anchor": { "kind": "line", "line": 412 },
                "emphasis": [{ "kind": "line_range", "start": 409, "end": 415 }]
            }),
        )
        .unwrap();
        assert_eq!(params["path"], "src/a.rs");
        assert_eq!(params["anchor_line"], 412);
        assert_eq!(params["emphasis"], json!([{ "start": 409, "end": 415 }]));
        assert!(params.get("anchor").is_none(), "not the object form");
    }

    #[test]
    fn a_pr_show_passes_the_uniform_anchor_through_verbatim() {
        let params = source_params(
            ViewType::PrConversation,
            &ViewIdentity::Pr {
                repo: "o/r".into(),
                number: 94,
            },
            &json!({ "anchor": { "kind": "comment", "id": "c1" } }),
        )
        .unwrap();
        assert_eq!(params["repo"], "o/r");
        assert_eq!(params["number"], 94);
        assert_eq!(params["anchor"], json!({ "kind": "comment", "id": "c1" }));
    }

    #[test]
    fn a_show_with_no_addressing_produces_params_with_only_the_identity() {
        let params = source_params(
            ViewType::Ticket,
            &ViewIdentity::Ticket {
                provider: "jira".into(),
                key: "CORE-1".into(),
            },
            &json!({}),
        )
        .unwrap();
        assert_eq!(params, json!({ "provider": "jira", "key": "CORE-1" }));
    }

    #[test]
    fn a_blank_reason_is_dropped_rather_than_shown_as_an_empty_caption() {
        let params = source_params(
            ViewType::ReviewQueue,
            &ViewIdentity::Singleton,
            &json!({ "reason": "   " }),
        )
        .unwrap();
        assert!(params.get("reason").is_none());
    }

    // ── 5. target parsing ─────────────────────────────────────────────────────

    #[test]
    fn the_review_queue_takes_no_target_and_tolerates_a_stray_one() {
        assert_eq!(
            identity_from_target(ViewType::ReviewQueue, None).unwrap(),
            ViewIdentity::Singleton
        );
        assert_eq!(
            identity_from_target(ViewType::ReviewQueue, Some(&json!({ "repo": "o/r" }))).unwrap(),
            ViewIdentity::Singleton
        );
    }

    #[test]
    fn a_file_target_keeps_the_requested_revision_as_part_of_the_identity() {
        assert_eq!(
            identity_from_target(
                ViewType::File,
                Some(&json!({ "path": "a.rs", "revision": "abc" }))
            )
            .unwrap(),
            ViewIdentity::File {
                path: "a.rs".into(),
                revision: Some("abc".into())
            }
        );
        assert_eq!(
            identity_from_target(ViewType::File, Some(&json!({ "path": "a.rs" }))).unwrap(),
            ViewIdentity::File {
                path: "a.rs".into(),
                revision: None
            }
        );
    }

    #[test]
    fn a_pr_target_with_a_malformed_repo_slug_is_refused() {
        // Reuses `perri.load_pr`'s own slug validation rather than a second,
        // possibly laxer one — a repo name is a repo name whichever tool
        // received it.
        for repo in ["evil", "o/r/x", "o/r$", "o/"] {
            let err = identity_from_target(
                ViewType::PrDiff,
                Some(&json!({ "repo": repo, "number": 1 })),
            )
            .unwrap_err();
            assert_eq!(err.code(), "invalid_target", "for {repo:?}");
        }
    }

    // ── 6. region creation and removal (D5) ───────────────────────────────────

    /// Both PR sources render "no PR loaded" rather than failing when nothing
    /// is under review, so they exercise the whole place→apply→broadcast path
    /// without a network or a fixture.
    async fn show_ok(state: &McpSharedState, args: Value) -> Value {
        let out = show(state, &args, Some("perri")).await;
        assert_eq!(out["ok"], true, "expected a successful show, got {out}");
        out
    }

    fn pr_target(number: u64) -> Value {
        json!({ "repo": "thehammer/nostromo", "number": number })
    }

    #[tokio::test]
    async fn a_bare_focus_bootstraps_both_regions_through_show_alone() {
        // The criterion: every view type opens "without calling any of
        // set_pane_content, set_pane_layout, set_pane_focus, create_pane,
        // reset_panes, apply_layout, or refresh_pane_content". This test calls
        // none of them — the focus starts as a bare repl leaf.
        let (state, _rx) = make_state();
        registry(&state).lock().unwrap().get_or_init("perri");
        assert_eq!(tree_of(&state, "perri"), Some(PaneTree::repl_leaf()));

        let queue = show_ok(&state, json!({ "type": "review_queue" })).await;
        assert_eq!(queue["region"], "queue");
        assert_eq!(queue["pane_id"], "queue");

        let diff = show_ok(
            &state,
            json!({ "type": "pr_diff", "target": pr_target(94) }),
        )
        .await;
        assert_eq!(diff["region"], "detail");

        let tree = tree_of(&state, "perri").unwrap();
        let ids = tree.pane_ids();
        assert!(ids.contains(&"queue".to_string()));
        assert!(ids.contains(&"repl".to_string()));
        assert_eq!(
            ids.iter().filter(|id| *id == "repl").count(),
            1,
            "exactly one repl survives both region creations"
        );
        assert!(view_tree::tabs_region(&tree, "detail").is_some());
    }

    #[tokio::test]
    async fn the_detail_region_is_created_on_the_first_show_that_needs_one() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        assert!(view_tree::tabs_region(&tree_of(&state, "perri").unwrap(), "detail").is_none());

        show_ok(&state, json!({ "type": "pr_diff", "target": pr_target(94) })).await;
        assert!(view_tree::tabs_region(&tree_of(&state, "perri").unwrap(), "detail").is_some());
    }

    #[tokio::test]
    async fn the_detail_region_is_removed_when_its_last_tab_closes() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        let before = tree_of(&state, "perri").unwrap();

        show_ok(&state, json!({ "type": "pr_diff", "target": pr_target(94) })).await;
        show_ok(
            &state,
            json!({ "type": "pr_conversation", "target": pr_target(94) }),
        )
        .await;
        assert!(view_tree::tabs_region(&tree_of(&state, "perri").unwrap(), "detail").is_some());

        // Clearing the PR under review closes every review tab (R8), which
        // takes the region's last tab with it.
        let daemon = state.daemon.as_ref().unwrap();
        reset_for_pr_change(daemon, "perri", None);

        let after = tree_of(&state, "perri").unwrap();
        assert!(view_tree::tabs_region(&after, "detail").is_none());
        assert_eq!(after, before, "back to exactly the pre-show tree");
        assert_eq!(after.pane_ids().iter().filter(|id| *id == "repl").count(), 1);
    }

    #[tokio::test]
    async fn changing_the_pr_under_review_closes_the_previous_prs_tabs() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        show_ok(&state, json!({ "type": "pr_diff", "target": pr_target(94) })).await;
        show_ok(
            &state,
            json!({ "type": "pr_conversation", "target": pr_target(94) }),
        )
        .await;
        let old_ids: Vec<String> = tree_of(&state, "perri").unwrap().pane_ids();

        let daemon = state.daemon.as_ref().unwrap();
        reset_for_pr_change(daemon, "perri", Some(("thehammer/nostromo", 95)));

        let after = tree_of(&state, "perri").unwrap();
        for gone in old_ids.iter().filter(|id| id.starts_with("detail.")) {
            assert!(
                !after.pane_ids().contains(gone),
                "{gone} belonged to the previous review and must be closed"
            );
        }
        // And their bindings went with them — otherwise a restart would
        // repaint tabs that no longer exist.
        let reg = registry(&state);
        let reg = reg.lock().unwrap();
        for gone in old_ids.iter().filter(|id| id.starts_with("detail.")) {
            assert!(reg.binding_for("perri", gone).is_none(), "{gone} still bound");
        }
    }

    #[tokio::test]
    async fn a_pr_change_leaves_a_perri_standard_focus_completely_alone() {
        // Non-regression: `perri-standard` has no curated regions, so R8 must
        // be a no-op for it — no tree change and no broadcast.
        let (state, mut rx) = make_state();
        {
            let reg = registry(&state);
            let mut reg = reg.lock().unwrap();
            reg.get_or_init("perri");
            reg.set_layout(
                "perri",
                &json!({ "tree": PaneTree::Split {
                    direction: SplitDirection::Vertical,
                    children: vec![
                        PaneTree::Split {
                            direction: SplitDirection::Horizontal,
                            children: vec![
                                PaneTree::Leaf { pane_id: "queue".into() },
                                PaneTree::Leaf { pane_id: "diff".into() },
                            ],
                            ratios: vec![0.5, 0.5],
                        },
                        PaneTree::Leaf { pane_id: "repl".into() },
                    ],
                    ratios: vec![0.6, 0.4],
                }}),
            )
            .unwrap();
            reg.bind_source("perri", "queue", SOURCE_PR_QUEUE);
            reg.bind_source("perri", "diff", "perri.get_current_pr");
        }
        let before = tree_of(&state, "perri");

        let daemon = state.daemon.as_ref().unwrap();
        reset_for_pr_change(daemon, "perri", Some(("thehammer/nostromo", 95)));
        reset_for_pr_change(daemon, "perri", None);

        assert_eq!(tree_of(&state, "perri"), before);
        {
            let reg = registry(&state);
            let reg = reg.lock().unwrap();
            assert!(reg.binding_for("perri", "diff").is_some(), "the diff pane keeps its binding");
            assert!(reg.binding_for("perri", "queue").is_some());
        }
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv())
                .await
                .is_err(),
            "a no-op reset broadcasts nothing"
        );
    }

    #[tokio::test]
    async fn showing_the_same_view_twice_reuses_one_tab_and_re_addresses_it() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        let first = show_ok(&state, json!({ "type": "pr_diff", "target": pr_target(94) })).await;
        let second = show_ok(
            &state,
            json!({
                "type": "pr_diff",
                "target": pr_target(94),
                "anchor": { "kind": "line", "path": "a.rs", "line": 12 },
                "reason": "second look"
            }),
        )
        .await;
        assert_eq!(second["pane_id"], first["pane_id"]);
        assert_eq!(second["reused"], true);
        assert_eq!(
            tree_of(&state, "perri").unwrap().pane_ids().iter()
                .filter(|id| id.starts_with("detail.")).count(),
            1,
            "one tab, not two"
        );
    }

    #[tokio::test]
    async fn a_reused_show_re_binds_the_pane_with_the_new_address_params() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        show_ok(&state, json!({ "type": "pr_diff", "target": pr_target(94) })).await;
        let out = show_ok(
            &state,
            json!({
                "type": "pr_diff",
                "target": pr_target(94),
                "reason": "unbounded retry loop"
            }),
        )
        .await;
        let pane_id = out["pane_id"].as_str().unwrap().to_string();
        let reg = registry(&state);
        let reg = reg.lock().unwrap();
        let binding = reg.binding_for("perri", &pane_id).unwrap();
        assert_eq!(binding.source, SOURCE_PR_DIFF);
        assert_eq!(
            binding.params.as_ref().unwrap()["reason"],
            "unbounded retry loop"
        );
    }

    // ── 6b. the decide/mutate race guard ──────────────────────────────────────
    //
    // `show()` cannot hold the registry's lock across its `fetch_async().await`
    // (a `std::sync::Mutex` guard isn't `Send` across that boundary), so the
    // placement it decides under one lock acquisition and the tree it mutates
    // under a second, later one can only ever be proven consistent by an
    // explicit check — `tree_changed_since_decide` — not by construction. None
    // of `nostromo.show`'s existing fetch sources (`perri.list_pr_queue`,
    // `perri.get_current_pr`, `perri.get_pr_diff`) ever actually suspend at
    // that `.await` (they're synchronous reads dressed as `async fn`), so
    // driving a *genuine* concurrent registry mutation into that exact window
    // isn't reachable from a test without adding a seam solely for that
    // purpose. What's tested instead: the guard's own logic, directly and
    // exhaustively (including the exact "additive scenario" from the review
    // that motivated it — a concurrent close shrinking the tree between decide
    // and mutate), plus every passing test above already proving the guard
    // introduces no false positive on the ordinary, non-racing path (every one
    // of them calls `show()` start-to-finish with nothing else touching the
    // registry in between, and none of them has ever hit `concurrent_modification`).

    #[test]
    fn tree_changed_since_decide_is_false_for_two_equal_trees_including_none_and_none() {
        assert!(!tree_changed_since_decide(None, &None));
        let t = PaneTree::Leaf { pane_id: "repl".into() };
        assert!(!tree_changed_since_decide(Some(&t), &Some(t.clone())));
    }

    #[test]
    fn tree_changed_since_decide_is_true_when_a_tab_closed_underneath_the_decision() {
        // Exactly the failure mode the review named: `place()` decided against
        // a tree with three detail tabs; a concurrent R8 reset closed one of
        // them before this call's mutate step re-locked. Applying the stale
        // three-tab `tab_order` on top of the now-two-tab tree would splice
        // the closed (and already-unbound) pane id straight back into the
        // layout with no rebind and no fetch behind it — a silent orphan.
        let three_tabs = PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![PaneTree::Tabs {
                children: vec![
                    PaneTree::Leaf { pane_id: "detail.0".into() },
                    PaneTree::Leaf { pane_id: "detail.1".into() },
                    PaneTree::Leaf { pane_id: "detail.2".into() },
                ],
                labels: vec!["A".into(), "B".into(), "C".into()],
                active: 0,
                region: Some("detail".into()),
            }],
            ratios: vec![1.0],
        };
        let two_tabs = PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![PaneTree::Tabs {
                children: vec![
                    PaneTree::Leaf { pane_id: "detail.0".into() },
                    PaneTree::Leaf { pane_id: "detail.2".into() },
                ],
                labels: vec!["A".into(), "C".into()],
                active: 0,
                region: Some("detail".into()),
            }],
            ratios: vec![1.0],
        };
        assert!(tree_changed_since_decide(Some(&two_tabs), &Some(three_tabs)));
    }

    #[test]
    fn tree_changed_since_decide_is_true_when_the_tag_was_removed_entirely() {
        let t = PaneTree::repl_leaf();
        assert!(tree_changed_since_decide(None, &Some(t)));
    }

    // ── 7. the descriptor ─────────────────────────────────────────────────────

    #[test]
    fn the_descriptor_enumerates_exactly_the_closed_vocabulary() {
        let d = descriptor();
        assert_eq!(d["name"], "nostromo.show");
        let types: Vec<&str> = d["inputSchema"]["properties"]["type"]["enum"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        let expected: Vec<&str> = ViewType::ALL.iter().map(|t| t.as_str()).collect();
        assert_eq!(types, expected);
        assert!(!types.contains(&"activity"), "activity is not showable");
    }

    #[test]
    fn the_descriptor_offers_no_free_text_content_field_and_no_modal_type() {
        // R7: a modal carries a decision only, and W6 owns that surface. If a
        // content-shaped field ever appears here, `show` has become a content
        // channel and the vocabulary has stopped being closed.
        let props = descriptor()["inputSchema"]["properties"].clone();
        for forbidden in ["content", "text", "html", "body", "modal", "payload"] {
            assert!(props.get(forbidden).is_none(), "`{forbidden}` must not exist");
        }
        assert!(!descriptor().to_string().contains("\"modal\""));
    }

    // ── 8. `current_pin` decoration on a failing file/revision-resolution
    // show (W5 — current-pr-collision) ────────────────────────────────────────
    //
    // A file fetch failure while a PR is pinned should tell the agent what's
    // currently pinned — the real production bug this closes is an agent
    // getting an "unresolvable"/wrong-content refusal with no idea a second
    // session repinned the PR out from under it. Scoped strictly to the
    // implicit-revision file path: an explicit revision means the caller
    // already knows exactly what it's asking for, and every other view type
    // has nothing to do with revision resolution at all.

    /// A minimal `PrSnapshot` seeded the same way `apply_layout.rs`'s tests
    /// do (`snapshot_with`/`state_with_pr_snapshot`) — `perri_pr_rx` is a
    /// crate-visible field on `McpSharedState`, so any tool module's tests
    /// can seed it directly.
    fn seed_pin(state: &mut McpSharedState, repo: &str, number: u64) {
        let snap: crate::data::perri_pr::PrSnapshot = serde_json::from_value(json!({
            "pr_number": number, "repo": repo, "title": "Some PR",
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": null, "head_sha": "abc123"
        }))
        .unwrap();
        let (_tx, rx) = tokio::sync::watch::channel(Some(snap));
        state.perri_pr_rx = rx;
    }

    #[tokio::test]
    async fn a_failing_file_show_with_an_implicit_revision_carries_the_current_pin_when_one_exists() {
        let (mut state, _rx) = make_state();
        seed_curated(&state, "perri");
        seed_pin(&mut state, "acme/web", 42);

        let out = show(
            &state,
            &json!({ "type": "file", "target": { "path": "does/not/exist.rs" } }),
            Some("perri"),
        )
        .await;

        assert!(out.get("error").is_some(), "expected a refusal, got {out}");
        assert_eq!(
            out.get("current_pin"),
            Some(&json!({ "repo": "acme/web", "number": 42 })),
            "a failing implicit-revision file show must name the currently pinned PR: {out}"
        );
    }

    #[tokio::test]
    async fn a_failing_file_show_with_no_pr_pinned_carries_no_current_pin_key_at_all() {
        let (state, _rx) = make_state();
        seed_curated(&state, "perri");
        // Default state: perri_pr_rx is None — no PR pinned.

        let out = show(
            &state,
            &json!({ "type": "file", "target": { "path": "does/not/exist.rs" } }),
            Some("perri"),
        )
        .await;

        assert!(out.get("error").is_some(), "expected a refusal, got {out}");
        assert!(
            out.get("current_pin").is_none(),
            "current_pin must be absent, not present-and-null, when nothing is pinned: {out}"
        );
    }

    #[tokio::test]
    async fn a_failing_file_show_with_an_explicit_revision_carries_no_current_pin_even_when_one_is_pinned(
    ) {
        let (mut state, _rx) = make_state();
        seed_curated(&state, "perri");
        seed_pin(&mut state, "acme/web", 42);

        // "HEAD" resolves locally (this test runs inside a real git checkout),
        // so the missing path fails with a plain `UnknownPath` — never
        // reaching `resolve_via_github_fallback`/`RevisionRepoMismatch` at
        // all. That keeps this test on the "ordinary explicit-revision
        // refusal" case the "caller already knows what it asked for" rule is
        // actually about, distinct from `revision_repo_mismatch` below.
        let out = show(
            &state,
            &json!({
                "type": "file",
                "target": { "path": "does/not/exist.rs", "revision": "HEAD" }
            }),
            Some("perri"),
        )
        .await;

        assert!(out.get("error").is_some(), "expected a refusal, got {out}");
        assert_eq!(
            out.get("error"),
            Some(&json!("unknown_path")),
            "expected this scenario to hit the plain not-found case, not a repo \
             mismatch, so it actually exercises the rule under test: {out}"
        );
        assert!(
            out.get("current_pin").is_none(),
            "an explicit revision means the caller already knows what it asked for; \
             current_pin must not be attached: {out}"
        );
    }

    #[tokio::test]
    async fn a_revision_repo_mismatch_refusal_carries_the_current_pin_even_with_an_explicit_revision(
    ) {
        let (mut state, _rx) = make_state();
        seed_curated(&state, "perri");
        // Pinned repo can't possibly match this checkout's own remote, and
        // "deadbeef" isn't a resolvable revision here — so the local read
        // fails as `UnresolvableRevision`, `resolve_via_github_fallback` sees
        // a pin whose repo doesn't match this checkout, and refuses with
        // `RevisionRepoMismatch` instead of fetching foreign content.
        seed_pin(&mut state, "acme/web", 42);

        let out = show(
            &state,
            &json!({
                "type": "file",
                "target": { "path": "does/not/exist.rs", "revision": "deadbeef" }
            }),
            Some("perri"),
        )
        .await;

        assert_eq!(
            out.get("error"),
            Some(&json!("revision_repo_mismatch")),
            "expected the repo-mismatch refusal, got {out}"
        );
        assert_eq!(
            out.get("current_pin"),
            Some(&json!({ "repo": "acme/web", "number": 42 })),
            "revision_repo_mismatch's entire reason for existing is a pin \
             mismatch, so — unlike other explicit-revision refusals — it must \
             carry the pin: {out}"
        );
    }

    #[tokio::test]
    async fn a_failing_non_file_show_never_carries_current_pin_even_when_a_pr_is_pinned() {
        let (mut state, _rx) = make_state();
        seed_curated(&state, "perri");
        seed_pin(&mut state, "acme/web", 42);

        // `TicketRegistryState::default()` registers no providers, so this
        // fetch fails with `unsupported_provider` — a real, non-file fetch
        // failure with a PR pinned at the same time.
        let out = show(
            &state,
            &json!({ "type": "ticket", "target": { "provider": "jira", "key": "X-1" } }),
            Some("perri"),
        )
        .await;

        assert!(out.get("error").is_some(), "expected a refusal, got {out}");
        assert!(
            out.get("current_pin").is_none(),
            "current_pin decoration is scoped to the file/revision-resolution path only: {out}"
        );
    }
}
