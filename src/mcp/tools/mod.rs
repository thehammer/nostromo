//! MCP tool registry.
//!
//! Phase 1: `nostromo.get_self`
//! Phase 2: 12 new read-only introspection tools across all views.
//! Phase 3: Pane mutation and cross-view dispatch tools.
//! Phase 4: `nostromo.notify`, `nostromo.register_status_segment`,
//!           `nostromo.clear_status_segment`.

pub mod apply_layout;
pub mod ask_decision;
pub mod create_focus;
pub mod create_pane;
pub mod daemon_diagnostics;
pub mod fred;
pub mod get_self;
pub mod get_view_state;
pub mod list_views;
pub mod mother;
pub mod mother_mutators;
pub mod nostromo_meta;
pub mod notify;
pub mod perri;
pub mod perri_mutators;
pub mod refresh_pane;
pub mod set_pane;
pub mod show;
pub mod status_segment;
pub mod switch_view;
pub mod teri;

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

// ── tool descriptors ─────────────────────────────────────────────────────────

/// JSON Schema descriptors for all registered MCP tools.
pub fn tool_descriptors() -> Vec<Value> {
    vec![
        // ── Phase 1 ────────────────────────────────────────────────────────
        json!({
            "name": "nostromo.get_self",
            "description": "Returns identity information about the calling Nostromo PTY session: which view and pane set the agent is running inside.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: global ────────────────────────────────────────────────
        json!({
            "name": "nostromo.list_views",
            "description": "Returns a list of all registered Nostromo views with their pane ids and a view-specific summary (PR counts, unread email, Mother job counts, etc.).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_view_state",
            "description": "Returns the full live state snapshot for a named view.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "View id (e.g. 'perri', 'fred', 'mother', 'teri')" }
                },
                "required": ["view_id"]
            }
        }),
        json!({
            "name": "nostromo.get_worktree_info",
            "description": "Returns git repo / worktree info for the calling PTY's working directory: cwd, branch, parent repo path, and whether this is a linked worktree.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_rate_limits",
            "description": "Returns the latest Claude rate-limit snapshot (5h and 7d window percentages and reset epochs).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "nostromo.get_budget_posture",
            "description": "Returns the current global budget posture (flush/normal/elevated/conservative/critical).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Perri ────────────────────────────────────────────────
        json!({
            "name": "perri.list_pr_queue",
            "description": "Returns Perri's live PR review queue (all three buckets: requested, needs_review, changes_req).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "perri.get_current_pr",
            "description": "Returns the PR currently loaded in Perri's diff pane, or null if none is loaded.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "perri.get_state",
            "description": "Returns a composite Perri state: { queue, current_pr, stale }.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Fred ─────────────────────────────────────────────────
        json!({
            "name": "fred.list_unread_emails",
            "description": "Returns unread emails from Fred's mailbox.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        json!({
            "name": "fred.list_calendar_events",
            "description": "Returns today's calendar events (or events on a specific date).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "date": { "type": "string", "description": "Optional ISO date (YYYY-MM-DD). Omit for today's events." }
                },
                "required": []
            }
        }),
        json!({
            "name": "fred.get_state",
            "description": "Returns Fred's composite state: { unread_count, today_event_count, mailbox, calendar }.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Mother ───────────────────────────────────────────────
        json!({
            "name": "mother.list_jobs",
            "description": "Returns Mother's job list. Optionally filter by status or include archived jobs.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "include_archived": { "type": "boolean", "description": "Include archived jobs (default false)" },
                    "status": { "type": "string", "description": "Filter to jobs with this state (e.g. 'running', 'awaiting', 'succeeded')" }
                },
                "required": []
            }
        }),
        json!({
            "name": "mother.get_job",
            "description": "Returns a single Mother job by id, or null if not found.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.tail_log",
            "description": "Returns the last N lines of a job's log (default 50, max 500).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "lines": { "type": "integer", "description": "Number of lines to return (default 50, max 500)" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.peek",
            "description": "Returns a live snapshot of a running job: todo list, recent tool calls, last assistant text, and any pending await question.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.get_status",
            "description": "Returns the current Mother status summary: running, queued, failed, awaiting counts.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 2: Teri ─────────────────────────────────────────────────
        json!({
            "name": "teri.list_todos",
            "description": "Returns Teri's active todo list (open, in_progress, blocked items).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 3: pane / view mutations ────────────────────────────────
        json!({
            "name": "nostromo.set_pane_content",
            "description": "Set the content of a named pane within a view. Errors: unknown_view, unknown_pane, readonly_pane, not_supported.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "View id (e.g. 'perri', 'fred')" },
                    "pane_id": { "type": "string", "description": "Pane id within the view (e.g. 'diff', 'mailbox')" },
                    "content": {
                        "type": "object",
                        "description": "{ type: 'text', text: '...' } or { type: 'json_snapshot', value: ... }"
                    }
                },
                "required": ["view_id", "pane_id", "content"]
            }
        }),
        json!({
            "name": "nostromo.set_pane_focus",
            "description": "Focus a specific pane within a view (also switches the active view tab).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string" },
                    "pane_id": { "type": "string" }
                },
                "required": ["view_id", "pane_id"]
            }
        }),
        json!({
            "name": "nostromo.set_pane_layout",
            "description": "Update a view's pane-split ratios. Ratios are view-specific JSON (e.g. { top_row: 0.6, queue: 0.4 } for Perri).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string" },
                    "ratios": { "type": "object", "description": "View-specific ratio keys and values (0.1–0.9)" }
                },
                "required": ["view_id", "ratios"]
            }
        }),
        // ── agent-driven pane layout (Phase 1) ─────────────────────────────
        json!({
            "name": "nostromo.create_pane",
            "description": "Add a named pane to the calling focus by splitting an existing pane in a stated direction. The new pane becomes addressable by its agent-chosen pane_id in subsequent content/layout/focus calls. Errors: unknown_view, unknown_pane, duplicate_pane, invalid_position.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id":     { "type": "string", "description": "Focus/view id (e.g. 'mother'); omit to target the caller's own focus" },
                    "pane_id":     { "type": "string", "description": "Agent-chosen id for the new pane (e.g. 'jobs', 'diff')" },
                    "position":    { "type": "string", "enum": ["split_left", "split_right", "split_above", "split_below"], "description": "Direction to split relative_to" },
                    "relative_to": { "type": "string", "description": "Existing pane id to split (e.g. 'repl')" }
                },
                "required": ["pane_id", "position", "relative_to"]
            }
        }),
        json!({
            "name": "nostromo.reset_panes",
            "description": "Tear the calling focus back down to a single REPL pane. Used by a restarting agent before rebuilding its workspace from scratch. Error: unknown_view.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "Focus/view id; omit to target the caller's own focus" }
                },
                "required": []
            }
        }),
        json!({
            "name": "nostromo.apply_layout",
            "description": "Resolve a declarative pane-layout schema — named (with on-disk override precedence at ~/.nostromo/layouts/<name>.yaml, else a compiled-in default) or inline (tree + panes) — build the pane tree, fetch each pane's bound data source server-side (no LLM involvement), and broadcast the result in one round trip: one FocusLayout plus one PaneContent per non-repl pane. Provide either `name` or `tree`+`panes`, not both. Errors: unknown_layout, unknown_source, invalid_content_kind, invalid_schema, invalid_args, unidentified_caller, not_supported, plus PaneRegistry codes (unknown_view, invalid_layout).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Named layout to resolve (e.g. 'perri-standard'). Mutually exclusive with `tree`." },
                    "tree": {
                        "type": "object",
                        "description": "Inline DSL tree: { direction, ratios, children } for a split, or { pane: <id> } for a leaf. Mutually exclusive with `name`."
                    },
                    "panes": {
                        "type": "object",
                        "description": "Inline per-pane bindings: { <pane_id>: { source?, content_kind, placeholder? } }. Used with `tree`."
                    },
                    "view_id": { "type": "string", "description": "Focus/view id to apply the layout to; omit to target the caller's own focus" }
                },
                "required": []
            }
        }),
        json!({
            "name": "nostromo.refresh_pane_content",
            "description": "Refresh one pane's content from a registered server-side data source — the daemon fetches and shapes the data itself, so you never hand-build the payload. Use this to pull a known source (e.g. perri.list_pr_queue) into your own pane; use set_pane_content instead to push content you authored yourself (freeform text, an error, an explicit loading state). Content only: emits one PaneContent broadcast, never re-declares geometry, so an operator's dragged split ratios survive. Shows a transient Loading state then the fetched content in one call. A refusal (a line past EOF, a path that does not exist, an unresolvable revision) leaves a pane that already has content untouched. Errors: unknown_source, fetch_failed, invalid_params, unknown_path, path_escapes_root, not_utf8, anchor_beyond_eof, invalid_emphasis_range, unresolvable_revision, unidentified_caller, invalid_args, not_supported.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "pane_id":     { "type": "string", "description": "Pane to refresh" },
                    "source":      { "type": "string", "description": "Registered fetcher name from the same closed registry apply_layout uses: 'perri.list_pr_queue', 'perri.get_current_pr', 'perri.get_pr_diff', 'nostromo.get_file'" },
                    "params":      { "type": "object", "description": "Source-specific arguments, persisted with the binding so a daemon restart repaints the same thing. nostromo.get_file: { path (required, repo-relative), revision? ('working', a git rev, or omit for the PR-under-review head SHA), anchor_line?, emphasis?: [{start,end}], reason? }. perri.get_pr_diff: { anchor?: {kind:'line', path?, line}, emphasis?: [{kind:'line_range', path?, start, end}], reason? }. The other two sources take none." },
                    "placeholder": { "type": "string", "description": "Shown as text when the source yields empty/null data (e.g. no PR currently loaded)" },
                    "view_id":     { "type": "string", "description": "Focus/view id owning the pane; omit to target the caller's own focus" }
                },
                "required": ["pane_id", "source"]
            }
        }),
        json!({
            "name": "nostromo.create_focus",
            "description": "Programmatically create a new persistent focus running a named agent persona in a working directory, with seeded first-turn context. Returns the new focus_id. Errors: invalid_working_directory, spawn_failed.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "agent":             { "type": "string", "description": "Agent persona name (e.g. 'cody', 'fred')" },
                    "working_directory": { "type": "string", "description": "Absolute path for the session's cwd; omit for a pathless focus" },
                    "title":             { "type": "string", "description": "Tab title (e.g. 'CORE-1234')" },
                    "initial_context":   { "type": "string", "description": "Markdown/text folded into the new session's first turn so it does not start blank" }
                },
                "required": ["agent", "title"]
            }
        }),
        json!({
            "name": "nostromo.switch_active_view",
            "description": "Switch the globally-active Nostromo view tab. Calls blur() on the old view and focus() on the new.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "View id to activate" }
                },
                "required": ["view_id"]
            }
        }),
        // ── Phase 3: Perri mutations ───────────────────────────────────────
        json!({
            "name": "perri.load_pr",
            "description": "Load a pull request into Perri's diff pane. Writes current-pr.json and triggers the native watcher. When hosted in nostromd (daemon): pushes the diff pane's content itself (your `highlights`, if given, become the pane's final content; otherwise a Loading state followed by a server-rendered PR summary once the refetch catches up — bounded by a settle timeout), and moves the agent-scoped selected index to this PR if it's in the current queue. May return `{ \"ok\": true, \"pending\": true }` when the refetch is still in flight after the settle timeout — that is success-with-fetch-pending, not a failure to retry. When hosted in the standalone TUI: writes the file and returns once `PerriView` has applied it, with no pane-push/pending behavior. Errors: invalid_args, not_supported (daemon only, when Perri's state dir isn't configured), io_error, event_loop_closed, event_loop_timeout (TUI only).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "number": { "type": "integer", "description": "PR number (> 0)" },
                    "repo": { "type": "string", "description": "Repository in 'owner/repo' format" },
                    "highlights": { "type": "string", "description": "Optional review notes or highlight context" },
                    "view_id": { "type": "string", "description": "Daemon-hosted only: focus/view id owning the diff pane; omit to target the caller's own focus" }
                },
                "required": ["number", "repo"]
            }
        }),
        json!({
            "name": "perri.clear_current_pr",
            "description": "Clear the currently-loaded PR from Perri's diff pane. When hosted in nostromd (daemon): also re-pushes the PR queue pane. Errors: not_supported (daemon only), io_error, event_loop_closed, event_loop_timeout (TUI only).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id": { "type": "string", "description": "Daemon-hosted only: focus/view id owning the diff/queue panes; omit to target the caller's own focus" }
                },
                "required": []
            }
        }),
        json!({
            "name": "perri.set_selected_index",
            "description": "Set the agent-scoped selected PR index in Perri's queue list, clamped to the current queue length (0 when empty). Daemon-hosted: this index is agent-scoped bookkeeping only — it does not move any GUI highlight (no wire/client concept of selection exists yet). TUI-hosted: moves `PerriView`'s own selection, same as keyboard navigation.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": { "type": "integer", "description": "0-based index into the PR queue" }
                },
                "required": ["index"]
            }
        }),
        json!({
            "name": "perri.get_selected_index",
            "description": "Returns the selected PR index in Perri's queue list (see perri.set_selected_index for what \"selected\" means on each host).",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
        // ── Phase 3: Mother mutations ──────────────────────────────────────
        json!({
            "name": "mother.enqueue_job",
            "description": "Enqueue a plan file as a new Mother job. Returns { id, title, status }.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "plan_path": { "type": "string", "description": "Absolute path to the plan Markdown file" }
                },
                "required": ["plan_path"]
            }
        }),
        json!({
            "name": "mother.cancel_job",
            "description": "Cancel a running, queued, or awaiting Mother job by id.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.archive_job",
            "description": "Archive a terminal-state Mother job by id.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" }
                },
                "required": ["id"]
            }
        }),
        json!({
            "name": "mother.resume_job",
            "description": "Resume an awaiting Mother job by providing the operator's answer.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "answer": { "type": "string", "description": "The operator's answer to the pending question" }
                },
                "required": ["id", "answer"]
            }
        }),
        json!({
            "name": "mother.retry_job",
            "description": "In-place retry a failed or cancelled Mother job by id (broker retry command — preserves dependency chains).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string", "description": "Job id to retry" }
                },
                "required": ["id"]
            }
        }),
        // ── Phase 4: notifications & status segments ───────────────────────
        json!({
            "name": "nostromo.notify",
            "description": "Post a transient toast notification to the Nostromo status bar. The toast auto-expires after 5 s.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "message": { "type": "string", "description": "Notification text" },
                    "level": {
                        "type": "string",
                        "enum": ["info", "warn", "error"],
                        "description": "Severity level (default: info)"
                    },
                    "view_id": { "type": "string", "description": "Optional view id requesting the notification (informational)" }
                },
                "required": ["message"]
            }
        }),
        json!({
            "name": "nostromo.register_status_segment",
            "description": "Add or update a named status-bar segment for a view. Segment is displayed when the view is active.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id":    { "type": "string", "description": "View id (e.g. 'perri', 'fred')" },
                    "segment_id": { "type": "string", "description": "Stable identifier for this segment within the view" },
                    "text":       { "type": "string", "description": "Text to display" },
                    "color": {
                        "type": "string",
                        "description": "Named color (red, amber, sage, blue, muted) or 6-digit hex (#rrggbb)"
                    }
                },
                "required": ["view_id", "segment_id", "text"]
            }
        }),
        json!({
            "name": "nostromo.clear_status_segment",
            "description": "Remove a named status-bar segment for a view.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "view_id":    { "type": "string" },
                    "segment_id": { "type": "string" }
                },
                "required": ["view_id", "segment_id"]
            }
        }),
        // ── decision modals (W6) ────────────────────────────────────────────
        json!({
            "name": "nostromo.ask_decision",
            "description": "Pose a decision as a modal over the window and block until the operator answers, dismisses it, or the call times out. Not a content channel: there is no free-form content field — only a bounded prompt, an optional bounded detail string, and 2+ labelled choices. Returns { ok: true, choice_id } when the operator picks an option, or { ok: true, outcome: \"dismissed\" } when the modal is dismissed without choosing (a distinct outcome, not a default choice). Errors: invalid_args (fewer than two choices, duplicate choice ids, an empty/over-long prompt, detail, or label), no_operator (no client is subscribed to receive it — returned immediately rather than blocking), timeout (nobody answered within timeout_secs), cancelled (the asking session died while this call was outstanding), not_supported (TUI-hosted only — there is no window to attach a sheet to).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "The question, shown at the top of the modal (max 2000 chars)" },
                    "detail": { "type": "string", "description": "Optional short supporting text shown below the prompt (max 2000 chars)" },
                    "choices": {
                        "type": "array",
                        "description": "2 or more labelled choices",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id":     { "type": "string", "description": "Stable id returned as choice_id when this option is picked" },
                                "label":  { "type": "string", "description": "Button label (max 200 chars)" },
                                "detail": { "type": "string", "description": "Optional short supporting text for this option (max 2000 chars)" }
                            },
                            "required": ["id", "label"]
                        }
                    },
                    "context_pane_id": { "type": "string", "description": "Optional reference to a pane already showing relevant context — never content itself" },
                    "view_id": { "type": "string", "description": "Focus/view id to attach the modal to; omit to target the caller's own focus" },
                    "timeout_secs": { "type": "integer", "description": "Seconds to wait for an answer before returning timeout (default 300, capped at 3600)" }
                },
                "required": ["prompt", "choices"]
            }
        }),
        // ── the curated view surface (W5 — curated-agent-views) ──────────────
        show::descriptor(),
        // ── diagnostics ──────────────────────────────────────────────────────
        json!({
            "name": "nostromo.get_daemon_diagnostics",
            "description": "Returns an on-demand latency snapshot for the daemon's MCP tool surface: per-tool call counts and p50/p95/max wall-clock durations in ms, plus process uptime and total call count. In-memory and bounded (last 256 samples per tool); resets on daemon restart. p50/p95 are over the retained window; calls and max are all-time.",
            "inputSchema": { "type": "object", "properties": {}, "required": [] }
        }),
    ]
}

/// The tool surface a caller may see, after the operator's policy has been
/// applied (W5 — curated-agent-views, B8/D7).
///
/// [`tool_descriptors`] stays unfiltered and is what tests and docs enumerate;
/// this is what `tools/list` answers with. With no policy armed — the shipped
/// default — the two are the same list, byte for byte, which is what keeps
/// every agent's surface unchanged until an operator says otherwise.
pub async fn tool_descriptors_for(state: &McpSharedState, pty_id: Option<&str>) -> Vec<Value> {
    let policy = crate::mcp::tool_policy::load();
    if policy.is_empty() {
        return tool_descriptors();
    }
    let agent = crate::mcp::tool_policy::resolve_agent_name(state, pty_id).await;
    crate::mcp::tool_policy::filter_descriptors(tool_descriptors(), policy.denied_for(agent.as_deref()))
}

// ── tool dispatch ─────────────────────────────────────────────────────────────

/// Result of a tool dispatch.
pub enum ToolResult {
    /// Successful tool call; content array to embed in the MCP response.
    Ok(Vec<Value>),
    /// Tool name not recognised.
    UnknownTool(String),
    /// The tool exists, but the operator's policy withdraws it from this
    /// caller (W5 — curated-agent-views, B8/D7).
    ///
    /// Deliberately distinct from [`ToolResult::UnknownTool`]: an agent that
    /// gets "no such tool" for a tool that plainly exists will conclude the
    /// daemon is broken and retry, where "not available to you" is a fact it
    /// can act on. The PRD asks for exactly this distinction.
    Forbidden(String),
}

/// Dispatch a `tools/call` request.
///
/// This is the single timing point for the whole tool surface: it wraps
/// [`dispatch_inner`] and, on success, records the elapsed wall-clock time in
/// `state.tool_stats` keyed by `name`. Unknown tool names are deliberately
/// excluded — recording them would let a misbehaving caller grow the stats
/// map without bound, since `name` is caller-supplied and unvalidated.
pub async fn dispatch(
    name: &str,
    arguments: Option<&Value>,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> ToolResult {
    let started = std::time::Instant::now();
    let result = dispatch_inner(name, arguments, state, pty_id).await;
    if matches!(result, ToolResult::Ok(_)) {
        state.tool_stats.record(name, started.elapsed());
    }
    result
}

/// Perform the actual `tools/call` dispatch.
async fn dispatch_inner(
    name: &str,
    arguments: Option<&Value>,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> ToolResult {
    // ── per-caller withdrawal (W5 — curated-agent-views, B8/D7) ─────────────
    //
    // Checked here rather than only in `tools/list`, because filtering the
    // list alone is advisory: an agent can call a name it never saw, and a
    // drifting prompt will. This is the half of the criterion that actually
    // holds. Skipped entirely when nothing is denied — the shipped default —
    // so an unarmed deployment pays one failed file read per call and no
    // agent-name resolution at all.
    {
        let policy = crate::mcp::tool_policy::load();
        if !policy.is_empty() {
            let agent = crate::mcp::tool_policy::resolve_agent_name(state, pty_id).await;
            if policy.denies(agent.as_deref(), name) {
                return ToolResult::Forbidden(name.to_string());
            }
        }
    }

    let content = match name {
        // ── Phase 1 ────────────────────────────────────────────────────────
        "nostromo.get_self" => get_self::handle(state, pty_id).await,

        // ── Phase 2: global ────────────────────────────────────────────────
        "nostromo.list_views" => list_views::handle(state).await,
        "nostromo.get_view_state" => {
            let input = parse_args::<get_view_state::GetViewStateInput>(arguments);
            match input {
                Ok(inp) => get_view_state::handle(state, &inp).await,
                Err(e) => e,
            }
        }
        "nostromo.get_worktree_info" => {
            // Use the caller's cwd if we can look it up from their PTY identity.
            // For now, pass None (uses current process cwd) — Phase 3 can wire
            // up per-PTY cwd tracking.
            nostromo_meta::get_worktree_info(None).await
        }
        "nostromo.get_rate_limits" => nostromo_meta::get_rate_limits(state),
        "nostromo.get_budget_posture" => nostromo_meta::get_budget_posture(state),

        // ── Phase 2: Perri ────────────────────────────────────────────────
        "perri.list_pr_queue" => perri::list_pr_queue(state),
        "perri.get_current_pr" => perri::get_current_pr(state),
        "perri.get_state" => perri::get_state(state),

        // ── Phase 2: Fred ─────────────────────────────────────────────────
        "fred.list_unread_emails" => fred::list_unread_emails(state),
        "fred.list_calendar_events" => {
            let input = parse_args::<fred::CalendarEventsInput>(arguments)
                .unwrap_or_else(|_| fred::CalendarEventsInput::default());
            fred::list_calendar_events(state, &input)
        }
        "fred.get_state" => fred::get_state(state),

        // ── Phase 2: Mother ───────────────────────────────────────────────
        "mother.list_jobs" => {
            let input = parse_args::<mother::ListJobsInput>(arguments)
                .unwrap_or_else(|_| mother::ListJobsInput::default());
            mother::list_jobs(state, &input).await
        }
        "mother.get_job" => match parse_args::<mother::GetJobInput>(arguments) {
            Ok(inp) => mother::get_job(state, &inp),
            Err(e) => e,
        },
        "mother.tail_log" => match parse_args::<mother::TailLogInput>(arguments) {
            Ok(inp) => mother::tail_log(state, &inp).await,
            Err(e) => e,
        },
        "mother.peek" => match parse_args::<mother::PeekInput>(arguments) {
            Ok(inp) => mother::peek(state, &inp).await,
            Err(e) => e,
        },
        "mother.get_status" => mother::get_status(state),

        // ── Phase 2: Teri ─────────────────────────────────────────────────
        "teri.list_todos" => teri::list_todos(state),

        // ── Phase 3: pane / view mutations ────────────────────────────────
        "nostromo.set_pane_content" => {
            let args = arguments.cloned().unwrap_or_default();
            set_pane::set_pane_content(state, &args).await
        }
        "nostromo.set_pane_focus" => {
            let args = arguments.cloned().unwrap_or_default();
            set_pane::set_pane_focus(state, &args).await
        }
        "nostromo.set_pane_layout" => {
            let args = arguments.cloned().unwrap_or_default();
            set_pane::set_pane_layout(state, &args).await
        }
        "nostromo.switch_active_view" => {
            let args = arguments.cloned().unwrap_or_default();
            switch_view::switch_active_view(state, &args).await
        }

        // ── agent-driven pane layout (Phase 1) ────────────────────────────
        "nostromo.create_pane" => {
            let args = arguments.cloned().unwrap_or_default();
            create_pane::create_pane(state, &args, pty_id).await
        }
        "nostromo.reset_panes" => {
            let args = arguments.cloned().unwrap_or_default();
            create_pane::reset_panes(state, &args, pty_id).await
        }
        "nostromo.create_focus" => {
            let args = arguments.cloned().unwrap_or_default();
            create_focus::create_focus(state, &args, pty_id).await
        }
        "nostromo.apply_layout" => {
            let args = arguments.cloned().unwrap_or_default();
            apply_layout::apply_layout(state, &args, pty_id).await
        }
        "nostromo.refresh_pane_content" => {
            let args = arguments.cloned().unwrap_or_default();
            refresh_pane::refresh_pane_content(state, &args, pty_id).await
        }

        // ── Phase 3: Perri mutations ───────────────────────────────────────
        "perri.load_pr" => {
            let args = arguments.cloned().unwrap_or_default();
            perri_mutators::load_pr(state, &args, pty_id).await
        }
        "perri.clear_current_pr" => {
            let args = arguments.cloned().unwrap_or_default();
            perri_mutators::clear_current_pr(state, &args, pty_id).await
        }
        "perri.set_selected_index" => {
            let args = arguments.cloned().unwrap_or_default();
            perri_mutators::set_selected_index(state, &args, pty_id).await
        }
        "perri.get_selected_index" => perri_mutators::get_selected_index(state, pty_id).await,

        // ── Phase 3: Mother mutations ──────────────────────────────────────
        "mother.enqueue_job" => {
            let args = arguments.cloned().unwrap_or_default();
            mother_mutators::enqueue_job(state, &args).await
        }
        "mother.cancel_job" => {
            let args = arguments.cloned().unwrap_or_default();
            mother_mutators::cancel_job(state, &args).await
        }
        "mother.archive_job" => {
            let args = arguments.cloned().unwrap_or_default();
            mother_mutators::archive_job(state, &args).await
        }
        "mother.resume_job" => {
            let args = arguments.cloned().unwrap_or_default();
            mother_mutators::resume_job(state, &args).await
        }
        "mother.retry_job" => {
            let args = arguments.cloned().unwrap_or_default();
            mother_mutators::retry_job(state, &args).await
        }

        // ── Phase 4: notifications & status segments ────────────────────────
        "nostromo.notify" => {
            let args = arguments.cloned().unwrap_or_default();
            notify::handle(state, &args).await
        }
        "nostromo.register_status_segment" => {
            let args = arguments.cloned().unwrap_or_default();
            status_segment::register(state, &args).await
        }
        "nostromo.clear_status_segment" => {
            let args = arguments.cloned().unwrap_or_default();
            status_segment::clear(state, &args).await
        }

        // ── decision modals (W6) ───────────────────────────────────────────
        "nostromo.ask_decision" => {
            let args = arguments.cloned().unwrap_or_default();
            ask_decision::handle(state, &args, pty_id).await
        }

        // ── the curated view surface (W5 — curated-agent-views) ──────────────
        "nostromo.show" => {
            let args = arguments.cloned().unwrap_or_default();
            show::show(state, &args, pty_id).await
        }

        // ── diagnostics ──────────────────────────────────────────────────────
        "nostromo.get_daemon_diagnostics" => daemon_diagnostics::handle(state),

        other => return ToolResult::UnknownTool(other.to_string()),
    };

    ToolResult::Ok(vec![json!({"type": "text", "text": content.to_string()})])
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Deserialize tool arguments, returning `{"error":"invalid_args"}` on failure.
fn parse_args<T: serde::de::DeserializeOwned>(arguments: Option<&Value>) -> Result<T, Value> {
    let v = arguments
        .cloned()
        .unwrap_or(Value::Object(Default::default()));
    serde_json::from_value(v)
        .map_err(|e| json!({ "error": "invalid_args", "detail": e.to_string() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── activity-path wedge: no agent-callable control over the stream ───────

    /// The PRD names this the constraint most likely to get quietly violated
    /// by a well-meaning convenience: no MCP tool may write to, filter, tag,
    /// or suppress an ambient activity stream. Asserted here by enumerating
    /// the actual registered tool surface, not by inspection — this fails
    /// the moment anyone adds a `nostromo.*activity*` tool, wherever in this
    /// module it's registered.
    #[test]
    fn no_registered_tool_name_mentions_activity() {
        let names: Vec<String> = tool_descriptors()
            .iter()
            .filter_map(|d| d.get("name").and_then(|n| n.as_str()).map(str::to_string))
            .collect();
        assert!(!names.is_empty(), "sanity: the tool registry must not be empty");
        for name in &names {
            assert!(
                !name.to_lowercase().contains("activity"),
                "found an activity-related MCP tool ({name}) — no agent-callable \
                 control over the ambient activity stream is permitted"
            );
        }
    }
}
