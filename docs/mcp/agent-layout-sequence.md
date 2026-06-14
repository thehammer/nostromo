# Nostromo MCP — Built-In Agent Assembly Sequences

Agent prompts for the four built-ins (Mother, Perri, Fred, Teri) are **operator-local** — they live in `~/.claude/agents/` and are not tracked in this repo. This doc is the canonical reference for what each built-in should add to its prompt so it assembles its own pane layout on startup, consistent with the agent-driven layout architecture in `docs/mcp/agent-layout.md`.

When you update a built-in's prompt, paste the appropriate section below into its `## Startup` block, after the `nostromo.get_self()` call.

---

## Tool availability (Phase 1)

Tools shipped in this PR and available to all daemon-hosted sessions:

| Tool | Implemented |
|------|-------------|
| `nostromo.get_self` | ✅ |
| `nostromo.create_pane` | ✅ |
| `nostromo.reset_panes` | ✅ |
| `nostromo.set_pane_content` | ✅ |
| `nostromo.set_pane_layout` | ✅ |
| `nostromo.create_focus` | ✅ |
| `nostromo.set_pane_focus` | ⏳ Phase 2 |
| `nostromo.register_status_segment` | ⏳ Phase 2 |
| `nostromo.notify` | ⏳ Phase 2 |
| `nostromo.switch_active_view` | ⏳ Phase 2 |

Phase 1 assembly sequences use only the ✅ tools. Phase 2 additions (focus, status segments, notifications) are shown as comments so prompts can be augmented without a rewrite.

---

## Canonical preamble (all built-ins)

Add this guard at the top of every built-in's startup block, before any domain calls:

```javascript
// 1. Detect Nostromo context
const self = await nostromo.get_self()
// self.view_id  — this focus's tag  (e.g. "mother", "perri", "fred", "teri")
// self.pane_ids — current panes, starts as ["repl"]

// 2. Idempotent rebuild: reset if a previous session left residual panes,
//    then assemble from scratch. Ensures restart = clean rebuild.
await nostromo.reset_panes({ view_id: self.view_id })
```

`reset_panes` followed by the same `create_pane` sequence is byte-identical to a fresh session — the daemon enforces determinism.

---

## Built-in 1 — Mother

**Layout**: job list left · job detail upper-right · log tail lower-right

```javascript
// ── Pane structure ──────────────────────────────────────────────────────────
await nostromo.create_pane({ view_id: self.view_id, pane_id: "jobs",
    position: "split_left",  relative_to: "repl" })
await nostromo.create_pane({ view_id: self.view_id, pane_id: "detail",
    position: "split_above", relative_to: "repl" })
await nostromo.create_pane({ view_id: self.view_id, pane_id: "log",
    position: "split_below", relative_to: "detail" })

// ── Fetch and fill ──────────────────────────────────────────────────────────
const jobs = await mother.list_jobs()

await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "jobs",
    content: { type: "text", text: renderJobList(jobs) } })

const featured = jobs.find(j => ["running","awaiting"].includes(j.state)) ?? jobs[0]
if (featured) {
    await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "detail",
        content: { type: "json_snapshot", value: featured } })
}

// ── Ratios ──────────────────────────────────────────────────────────────────
await nostromo.set_pane_layout({ view_id: self.view_id,
    ratios: { jobs: 0.35, detail: 0.40, log: 0.25 } })

// ── Phase 2 additions (uncomment when available) ────────────────────────────
// const running = jobs.filter(j => j.state === "running").length
// const awaiting = jobs.filter(j => j.state === "awaiting").length
// await nostromo.register_status_segment({ view_id: self.view_id,
//     segment_id: "fleet",
//     text: `${running} running · ${awaiting} awaiting`,
//     color: awaiting > 0 ? "amber" : "sage" })
```

### iOS degradation

On iOS, `DynamicFocusView` renders: **Repl** tab (primary) + **jobs** tab + **detail** tab + **log** tab. The operator can reach all panes; "detail" is the likely first tap after the repl.

---

## Built-in 2 — Perri

**Layout**: PR queue left · diff right · repl beneath diff

```javascript
// ── Pane structure ──────────────────────────────────────────────────────────
await nostromo.create_pane({ view_id: self.view_id, pane_id: "queue",
    position: "split_left",  relative_to: "repl" })
await nostromo.create_pane({ view_id: self.view_id, pane_id: "diff",
    position: "split_above", relative_to: "repl" })

// ── Fetch and fill ──────────────────────────────────────────────────────────
const queue = await perri.list_pr_queue()

await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "queue",
    content: { type: "text", text: renderPrQueue(queue) } })

const current = await perri.get_current_pr()
if (current) {
    await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "diff",
        content: { type: "text", text: renderPrSummary(current) } })
}

// ── Ratios ──────────────────────────────────────────────────────────────────
await nostromo.set_pane_layout({ view_id: self.view_id,
    ratios: { queue: 0.30, diff: 0.55, repl: 0.15 } })

// ── Phase 2 additions ────────────────────────────────────────────────────────
// await nostromo.set_pane_focus({ view_id: self.view_id, pane_id: "diff" })
```

### iOS degradation

On iOS: **Repl** tab (primary) + **queue** tab + **diff** tab. The queue tab is the natural first stop; the operator taps a PR row in the repl/queue and the diff populates.

---

## Built-in 3 — Fred

**Layout**: inbox left · calendar right · repl beneath

```javascript
// ── Pane structure ──────────────────────────────────────────────────────────
await nostromo.create_pane({ view_id: self.view_id, pane_id: "inbox",
    position: "split_above", relative_to: "repl" })
await nostromo.create_pane({ view_id: self.view_id, pane_id: "calendar",
    position: "split_right", relative_to: "inbox" })

// ── Fetch and fill ──────────────────────────────────────────────────────────
// Use the Graph API helpers (see Fred agent prompt for source/auth details)
const [emails, events] = await Promise.all([
    listUnreadEmails(),
    listCalendarEvents({ date: "today" }),
])

await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "inbox",
    content: { type: "text", text: renderInbox(emails) } })
await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "calendar",
    content: { type: "text", text: renderCalendar(events) } })

// ── Ratios ──────────────────────────────────────────────────────────────────
await nostromo.set_pane_layout({ view_id: self.view_id,
    ratios: { inbox: 0.50, calendar: 0.50 } })

// ── Phase 2 additions ────────────────────────────────────────────────────────
// const nextMtg = events.find(e => new Date(e.start) > new Date())
// await nostromo.register_status_segment({ view_id: self.view_id,
//     segment_id: "unread",
//     text: `${emails.length} unread · next ${nextMtg?.title ?? "free"} ${fmtTime(nextMtg?.start)}`,
//     color: "blue" })
```

### iOS degradation

On iOS: **Repl** tab (primary) + **inbox** tab + **calendar** tab. Both non-repl panes are equally useful on mobile; the operator switches tabs to check each.

---

## Built-in 4 — Teri

**Layout**: todo list left · repl right

```javascript
// ── Pane structure ──────────────────────────────────────────────────────────
await nostromo.create_pane({ view_id: self.view_id, pane_id: "todos",
    position: "split_left", relative_to: "repl" })

// ── Fetch and fill ──────────────────────────────────────────────────────────
const todos = await teri.list_todos()

await nostromo.set_pane_content({ view_id: self.view_id, pane_id: "todos",
    content: { type: "text", text: renderTodos(todos) } })

// ── Ratios ──────────────────────────────────────────────────────────────────
await nostromo.set_pane_layout({ view_id: self.view_id,
    ratios: { todos: 0.45, repl: 0.55 } })

// ── Phase 2 additions ────────────────────────────────────────────────────────
// const dueToday = todos.filter(t => t.dueDate === today() && !t.done).length
// await nostromo.register_status_segment({ view_id: self.view_id,
//     segment_id: "open",
//     text: `${todos.filter(t=>!t.done).length} open · ${dueToday} due today`,
//     color: "sage" })
```

### iOS degradation

On iOS: **Repl** tab (primary) + **todos** tab. The todos tab is the glance-and-act surface the operator reaches for first.

---

## Restart / clean rebuild

When a built-in restarts (user taps "Restart" or the session crashes and respawns), the startup block re-runs: `reset_panes` collapses back to a single repl, then the same `create_pane` sequence rebuilds identically. The operator sees a brief flash as panes re-appear and fill — a visible signal that the agent restarted, not a silent state-loss.

## Adding a new built-in

1. Create the agent prompt at `~/.claude/agents/<name>.md`.
2. Add a `## Startup` section with the canonical preamble + your pane sequence (max 3–4 panes for a clean layout).
3. Register the focus in the daemon config so it appears in the focus list at startup.
4. No Swift code, no Xcode project changes — the layout is entirely agent-authored.
