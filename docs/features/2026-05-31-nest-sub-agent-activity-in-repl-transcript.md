# Nest / attribute sub-agent activity in the REPL transcript

**Type:** feature · **Repo:** nostromo (macOS GUI + nostromod parser) · **Status:** backlog

## Problem

When a REPL agent (e.g. Claudia) spawns a sub-agent via the Task/Agent tool
(e.g. Archie to write a plan), the sub-agent's activity is rendered **flat and
un-attributed** in the parent transcript:

- The **prompt handed to the sub-agent** appears as a right-aligned **user
  bubble** — because in the stream-json it's a `"user"`-role message (the input
  to the sub-agent's context). It looks like the operator typed it.
- The sub-agent's **tool calls** (bash, reads, greps, etc.) appear inline in the
  same single column as the main thread, with no marker indicating they belong
  to the sub-agent. It looks like the main session ran them directly.

Net: it's hard to tell what the main session did vs. what a sub-agent did, and
sub-agent prompts masquerade as operator messages. Observed with the
`🤖 Agent Spawn Archie…` flow during the session-host work (2026-05-31).

This is **cosmetic** — the data is all correct and complete; only the
presentation conflates the threads. It is **pre-existing**, not introduced by
the daemon session-host cutover: the daemon's `stream_json` parser is a faithful
port of the old Swift `-p` parser (kept for render parity), and the old path
rendered identically.

## Desired behavior

Visually distinguish sub-agent activity from the main thread. Options to weigh
during design:

- **Nest/indent** a sub-agent's turns under the `Agent` tool-call row that
  spawned it (a visually grouped, indented sub-block).
- **Collapse by default**, expandable — the `Agent` row shows a one-line summary
  ("Archie · planning · N tool calls"); expanding reveals the nested activity.
- **Attribute** the sub-agent prompt as *not* an operator message (don't render
  it as a right-aligned user bubble; style it as "prompt to <agent>").

## Where

Now that the **daemon owns parsing**, this is primarily a `src/ipc/stream_json.rs`
change (detect sub-agent / Task boundaries in the stream and tag turns/blocks
with a parent/sub-agent association), plus a `ReplView` rendering change to
nest/collapse/attribute based on that association. Requires understanding how
Claude Code's stream-json marks sub-agent (Task tool) nested events — a small
research item: capture a real sub-agent stream and inspect the envelope
(parent_tool_use_id / nesting fields) to find the boundary signal.

## Priority

Low / polish. Not urgent — surfaced and parked during Milestone B (persistent
bidirectional session host). Good follow-up once the core cutover + remote
control land.
