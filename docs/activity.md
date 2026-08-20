# Ambient activity

Nostromo's ambient activity feed surfaces what an agent is *doing* — the
files it reads, the greps it runs, the subagents it fans out — without the
agent having to narrate any of it. This is Phase 1 of the "curated agent
views" activity wedge: a hook-driven producer, an attributed per-agent
stream store in the daemon, and an always-on ticker in the macOS GUI. See
`.claude/prds/curated-agent-views.md` (primary repo checkout) for the full
product rationale.

## Ingest contract

```
Claude Code hook event (PostToolUse / SubagentStart / SubagentStop)
  → nostromo-activity-hook (reads stdin, redacts, appends one JSONL line)
  → ~/.claude/activity.jsonl
  → nostromd's directory-watching tailer (src/agent_bus.rs)
  → SessionManager::ingest_activity_event (attribution + seq + defensive re-scrub)
  → ActivityStore (bounded, per-focus, per-agent streams)
  → ServerMsg::Activity / ActivitySnapshot / ActivityHealth broadcasts
  → macOS ActivityStreamModel → ActivityTickerView
```

Nothing in this path reads a tool **result** — only that a tool ran, and a
bounded, redacted summary of its target. `PreToolUse` is not handled at all.

### Installing the hook

The producer is a small Rust binary, `nostromo-activity-hook` (built by
`cargo build --bin nostromo-activity-hook` / installed by `make install`
alongside `nostromd`). It needs to be registered against three Claude Code
hook events in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse":   [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/nostromo-activity-hook" }] }],
    "SubagentStart": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/nostromo-activity-hook" }] }],
    "SubagentStop":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/nostromo-activity-hook" }] }]
  }
}
```

Run `nostromo doctor` to check whether it's installed, and `nostromo doctor
--fix` to install it (idempotent — never duplicates an entry, never disturbs
an existing unrelated hook for the same event). See `docs/nostromo-doctor.md`.

There is no other setup step and no user-facing enable/disable control —
once the hook is installed, the ambient surface is simply on, and no
MCP tool exists to write to, filter, or suppress it.

## Event schema

`ActivityEvent` (`src/agent_bus.rs`) — every field beyond the original four
(`ts`/`agent`/`kind`/`summary`) is `#[serde(default)]`, so a pre-wedge
4-field line still deserializes:

| Field              | Meaning                                                              |
|--------------------|-----------------------------------------------------------------------|
| `ts`               | Event timestamp.                                                      |
| `agent`            | Display name of the agent/subagent type.                              |
| `kind`             | `tool_use` \| `subagent_start` \| `subagent_stop` \| `session_start`.  |
| `summary`          | Bounded (≤120 char), redacted, per-tool summary. Never raw `tool_input`. |
| `focus_tag`        | Focus tag stamped by the producer from `NOSTROMO_FOCUS_TAG`, if set.   |
| `session_id`       | The originating `claude` session id, if the hook payload carried one. |
| `agent_id`         | Subagent id; absent for the main agent's own stream.                  |
| `agent_type`       | The subagent's type, set alongside `agent_id`.                        |
| `parent_agent_id`  | The subagent's parent, when known (absent for a top-level subagent).  |
| `tool_name`        | Tool name, for `tool_use` events.                                     |
| `tool_use_id`      | Claude Code's `tool_use_id`. Retained even though nothing reads it yet (deferred Phase 2). |
| `cwd`              | Working directory reported by the hook payload.                       |
| `seq`              | Daemon-assigned, per-stream monotonic sequence number.                |

## Attribution

Resolved daemon-side, in order (`SessionManager::resolve_attribution`):

1. `focus_tag`, if it names a focus the daemon knows (a live/known session,
   or an entry in the Mac-pushed focus registry).
2. Otherwise, `session_id`, through the daemon's in-memory `claude session_id
   → focus tag` reverse index (seeded from the on-disk `daemon-sessions.json`
   store on startup, so a session spawned by a *previous* daemon process
   still attributes correctly).
3. Otherwise, **unattributed** — retained (bounded), never dropped, and
   never assigned to an arbitrary focus.

Within a focus: one stream per distinct `agent_id` (labelled by `agent_type`,
parented by `parent_agent_id`), plus the main stream for events with no
`agent_id`. Two concurrently running subagents always land in two disjoint
streams; neither ever appears in the other's stream or in the main stream.

## Retention

Each stream retains at least the 200 most recent events
(`activity::store::MAX_EVENTS_PER_STREAM`). Store-wide, once lifetime ingest
volume crosses `activity::store::MAX_TOTAL_EVENTS`, the oldest *finished*
subagent stream (one that's received a `subagent_stop`) has its history
reclaimed first — the main stream and any still-running subagent stream are
never touched by this. Nothing is persisted across a daemon restart; the
surface reports a fresh start rather than presenting stale history as current.

## Redaction guarantees

`activity::redact::scrub` (`src/activity/redact.rs`) is applied **twice** —
once in the producer before a line is ever written to `activity.jsonl`, and
again, defensively, in `ActivityStore::ingest` — so a line written by
anything other than the producer is still scrubbed before it's ever
broadcast or displayed.

Scrubbed, in order: known secret token shapes (GitHub `ghp_`/`gho_`/`ghs_`/
`github_pat_`, OpenAI/Anthropic-style `sk-`, Slack `xox[baprs]-`, AWS
`AKIA...`, JWT-looking `eyJ....eyJ...`), `Authorization`/`Bearer` values,
`--password`/`--token`/`--api-key` CLI flag values, `token=`/`api_key=`/
`access_token=` query parameters, the value of any environment variable
whose name matches `(TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL)` (sourced from the
hook process's own environment), and a long-high-entropy-run fallback. An
ordinary file path or grep pattern is left untouched.

No event ever exposes a tool **result**, and no event ever exposes a raw
`tool_input` payload verbatim — `activity::summary::summarize` derives a
bounded, per-tool summary (the target path/pattern/command/host — never the
full JSON) before redaction runs.

## Gaps and health

The daemon assigns a monotonic per-stream `seq`. A client (`ActivityStreamModel`
on macOS) that observes a non-consecutive `seq` treats its current view of
that stream as potentially incomplete and re-requests a full snapshot
(`ClientMsg::ActivitySnapshotRequest`) rather than silently presenting a hole
in the record.

`ServerMsg::ActivityHealth` reports whether the feed is actually receiving
events, distinguishing "the hook isn't installed" from "the hook is
installed but nothing has arrived yet" — the ticker names the concrete fix
(`nostromo doctor --fix`) rather than silently continuing to show the last
known event during an outage.

## Surface

The macOS ticker (`ActivityTickerView`) is a window-level overlay, not a
pane or a tab — it never competes with content for the detail region, and an
arriving event never changes the frontmost pane, its scroll position, or the
first responder. Clicking it expands a small per-agent panel; there is no
agent selector styled as `PaneTree` tabs, since an activity stream isn't a
view in the placement vocabulary.

The Rust TUI is unchanged — it keeps its existing `AgentBus`-fed status-bar
rendering (`src/ui/chrome.rs`), reading straight from the same tailed
`activity.jsonl`. iOS decodes the new `ServerMsg` cases without throwing but
renders nothing — no iOS UI in this wedge.

## Out of scope (Phase 1)

No transcript-side grouping/collapsing of tool calls, no panes/tabs/content
kinds for activity, no agent-callable control over the stream (no tool to
write, tag, filter, or suppress it), no persistence across a daemon restart,
and no iOS/TUI rendering beyond decode correctness. See the wedge plan for
the full deferred-Phase-2 list.
