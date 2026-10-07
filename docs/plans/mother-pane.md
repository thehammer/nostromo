# Mother focus: queue pane, job detail, controls

**Status:** plan (Claudia), 2026-10-07. Owner-approved direction; build inline in phases.

## Finding that shapes the plan
The Mother focus today is just an agent REPL. But the old native `MotherView`
(`macOS/Nostromo/UI/Views/MotherView.swift`, 1,310 lines, unused since the
dynamic-pane rewrite) already contains everything the owner asked for:

- `MotherCountsStrip` — running / paused / awaiting / failed counts
- `MotherJobList` — SwiftUI list grouped by state (awaiting → running →
  queued/ready → failed → succeeded/cancelled), phase-ribbon rows
- `MotherJobDetail` — meta, phase ribbon, peek todo list, plan checklist, live
  log, and state-appropriate actions: **Answer** + **Cancel job** (awaiting),
  **Cancel job** + **Force-start** (running/queued/ready), **Retry** + archive
  (failed/cancelled), archive + view plan (succeeded)
- Broker commands already wired: `AppStore` → `MotherBrokerClient`
  `answer/cancel/retry/forceStart`, with error codes and a broker-offline banner.

Data already reaches the app (verified live against `bin/fake-mother-broker`:
status line shows `🏭 ▶2 ⏸1 ?2 !1`). What is missing is only *hosting*: the
pane system (`DynamicFocusView.makeLeaf`) builds a `ReplView` for pane id
`repl` and a generic `PaneContentNSView` for everything else, so none of this
UI is reachable.

## Design
1. **Pane kinds.** Teach `makeLeaf` two native kinds, keyed by pane id:
   `mother_queue` (counts strip + job list) and `mother_job:<jobId>` (one
   `MotherJobDetail`). Everything else is unchanged.
2. **Default layout for the Mother focus** (daemon, on `init_focus("mother")`
   / app-side default): `mother_queue` on top, `repl` below, mirroring the
   Perri queue-over-agent arrangement. Split ratio persisted like other splits.
3. **Job detail as tabs, not a fixed side column.** Clicking a row opens (or
   focuses) a `mother_job:<id>` tab in a tab region beside/under the queue,
   exactly like PR tabs in the Perri focus: closable (✕), the queue is not.
   Phase 1 may ship detail inline (list | detail split inside `mother_queue`,
   as `MotherView` does today) and graduate to tabs in phase 2.
4. **Controls** (all four already exist): Answer (inline text field),
   Cancel, Retry, Force-start; plus header actions added in phase 3:
   pause/resume queue and clear-finished *only if the broker supports them*
   (to be confirmed against Mother's broker protocol; do not invent commands).
5. **Selection/refresh:** selection survives job updates (existing
   `jobsDidChange` logic); a vanished job leaves its tab showing "finished /
   gone" rather than closing under the user.

## Phases
- **P0 (done):** failing QA scenario `scripts/qa/mother-queue.sh` against
  the fake broker. It is *expected to fail* until P1.
- **P1 (done):** `mother_queue` hosted in the Mother focus (list + inline
  detail + actions); `scripts/qa/mother-queue.sh` passes against the fake broker
  (cancel and retry clicked in the real UI; broker received them).
- **P2:** per-job tabs, ✕ close, selection ↔ tab sync.
- **P2.1:** tab strip uses compact tabs (200pt, shrink to 70) and the list
  highlight follows the active tab (code in this PR; live check pending).
- **P3 (done):** Escalate on failed jobs (confirm sheet, CLI `mother escalate --yes`) and a
  Mother daemon status chip with Start (CLI `mother daemon status|start`, polled every 30 s;
  skipped for a QA broker). "Archive finished" already exists as the list's Archive All.

## QA (tooling already in place)
`bin/fake-mother-broker --scenario basic` + `bin/nostromo-app` (`click`,
`wait`, `expect`, `layout-issues`, `screenshot`) + `MOTHER_BROKER_SOCK`.
The scenario asserts: group headers and job titles render; clicking a job
shows its detail; Cancel on a running job moves it to CANCELLED; Retry on a
failed job moves it out of FAILED; the broker's `commands` log records exactly
what the UI sent. Needs an awake, visible window (see `docs/app-control.md`).

## Findings from the first live run
- The 30 s `pollMotherList()` reconciles against the real `mother` CLI and deletes
  jobs it doesn't list; with a non-default broker (QA) that wiped the fake jobs.
  Now skipped when `MOTHER_BROKER_SOCK` is set. Archive still shells the real CLI.
- The sidebar's `FlippedView` (TabBarView) reports ambiguous Auto Layout — a
  pre-existing finding from `layout-issues`, not part of Mother.

## What Mother's broker supports (checked 2026-10-07, `plugins/mother/broker/envelope.go`)
Broker commands: `subscribe`, `unsubscribe`, `query_list`, `query_get`, `answer`,
`cancel`, `retry`, `force-start`. **There is no pause-queue or clear-finished
command.** Everything else is CLI-only: `escalate`, `reconcile`,
`adherence-review`, `archive [--older-than DAYS]`, `add`, `plan`, `peek`,
`logs`, `daemon start|stop|status`.

So P3 header controls, honestly scoped:
- **Escalate** on failed jobs (CLI `mother escalate ID --yes`), next to Retry.
- **Archive finished…** with an age choice (CLI `mother archive --older-than N`);
  the app already shells out `mother archive` per job via `archiveJob`.
- **Mother daemon status** chip (CLI `mother daemon status`) with Start when down.
- Not offered: pause/resume queue (no command exists; would need a broker change).

## Open questions
- Pause-queue would need a new broker command in the Mother repo — worth filing there if wanted.
- Should finished jobs older than N hours collapse? (Default: show last 24h.)
