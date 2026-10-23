# Daemon restart and orphaned child processes

Answers question 1 of `.claude/plans/background-activity-panel.md` ("what happens to a session's
background processes when `nostromd` restarts?"), and records what was changed.

## What used to happen

`nostromd` hosts one `claude` CLI per session. On shutdown it SIGKILLed each CLI. Only
*restricted* sessions led their own process group, so for every other session the kill took the CLI and
nothing it had started: background shells, dev servers an agent launched, tool children, subagents.
Nothing remembered them, so a restarted daemon never reaped them.

(`launchd` also cleans up what is left in a job's process group when the job exits. That covered
children that had stayed in the daemon's own group by accident. Once sessions lead their own groups
that no longer applies, which is why the daemon now does the cleanup itself.)

## What happens now

- **Every session's CLI leads its own process group** (`orphans::SESSIONS_LEAD_OWN_GROUP`, one
  constant; set it to `false` to revert, restricted sessions keep their own group regardless). A group
  signal reaches background servers and subagents.
- **Shutdown is graceful** (`SessionManager::kill_all_on_shutdown`): each CLI's group gets SIGTERM, all
  sessions share one grace (3 s, `orphans::SHUTDOWN_GRACE`), and whatever is still there gets SIGKILL.
  The daemon spends at most about 4.5 s on this in total, including the wait for denied permission
  requests, so `make install-daemon` (which waits about 5 s for the old instance to unload) is not
  outrun. A second call finds no sessions and does nothing.
- **A ledger records every CLI the daemon spawns.** `~/.nostromo/child-processes.json` (beside the
  session store; 0600, atomic write): pid, process-group id, spawn time, a boot-unique marker and the
  program path. It is removed on a clean exit and left in place when the daemon dies or shutdown is cut
  short. Each CLI also gets `NOSTROMO_DAEMON_BOOT=<marker>` in its environment, to tell which boot owns it.
- **Startup sweep** (`orphans::sweep`, called by `nostromd` before it spawns anything). For each ledger
  entry the process is acted on only if all of these hold: the pid is alive, it still leads the recorded
  group, it started within 5 s of the recorded time, and its command line still contains the recorded
  program. It then gets SIGTERM to its group, the grace, and SIGKILL. An entry that fails any check is
  dropped and never signalled (never a kill on pid alone). A missing, corrupt or wrong-version file is
  ignored. If the daemon that wrote the file is still alive, the sweep leaves everything alone. The log
  has pids and group ids only, no command text.

## Limits

- If the CLI itself is already gone when the sweep runs (for example it exited when the dead daemon's
  pipes closed), its entry no longer verifies and its former background children are **not** swept:
  with the leader gone there is nothing to prove who the group belongs to.
- Possible later slice (not built): stamp each CLI's environment with `NOSTROMO_DAEMON_BOOT` (already
  set) and have the sweep verify a group member's environment or command line before signalling a
  leaderless group. Until then a leaderless group is never signalled.
- The ledger file is handed over, not locked: a new daemon's first write replaces a still-running old
  daemon's file, and each ledger only deletes or rewrites the file while it still carries its own pid
  and boot marker (checked just before the write, so a very tight race is theoretically possible).
- Mother's runner and broker, and anything else the daemon did not spawn as a session CLI, are never in
  the ledger and are never touched.

## `kill_on_drop` / `mother` enqueue audit

`kill_on_drop(true)` sends SIGKILL when the child handle is dropped: on a timeout, when the owning
future is cancelled, and when the runtime is torn down at shutdown. It does nothing if the daemon
itself is killed.

| Site | What it runs | Verdict |
|---|---|---|
| `src/mother/mod.rs` `mother_command` | every `mother` CLI call (`add`, `resume`, `cancel`, `list`, ...) | see below |
| `src/mcp/tools/create_focus.rs` `git_output` | read-only `git rev-parse` / `config` probes with a timeout | harmless to kill |
| `src/model/catalog.rs` | the throwaway `claude` model-catalog probe, no tools, temp cwd | harmless to kill |

`mother add` (a shell script) builds the job, then `_atomic_write`s the job file (state `queued`),
then appends the `queued` event, then prints the id. `mother resume` `_atomic_write`s the merged job
(state `ready`), then appends `decision_resolved` / `resumed` events. Writes are atomic, so a killed
call never leaves a torn job file. What a kill *can* leave:

1. `add` killed after the job-file write and before the id reaches the daemon (30 s CLI timeout, or
   daemon shutdown with the call in flight; the window is a few milliseconds). The job exists and
   runs, but the caller got an error or no answer, so `create_focus` does not record it in the sent
   ledger and does not delete the brief. The job still appears in `mother list` and in the daemon's
   jobs feed; a retry by the user queues a second job. If the kill lands between the job write and the
   `queued` event, the job's event log is missing that one line.
2. `resume` killed after the job-file write: the job is already `ready` and proceeds, but the caller
   saw an error. A retry fails with "job is in state ready, expected awaiting", which is accurate.
   The answer temp file is removed by its drop guard either way.

Neither is a defect that can be fixed daemon-side without changing Mother's semantics (a two-phase
add, or an idempotency key), so nothing was changed. A restart does not touch a running Mother job:
the runner and broker are separate processes the daemon did not start, and the daemon holds no
bookkeeping for them beyond what it re-reads from `mother list`.

## What to expect on the next `make install-daemon`

The old daemon gets SIGTERM from `launchctl bootout`. Each session's CLI (and everything it started)
gets SIGTERM, then SIGKILL after at most about 3 s. Conversations resume the way they did after any daemon restart
(`--resume`, same session ids). **Background servers and shells agents started are stopped**, as are
subagent processes; agents that need them must start them again. Shutdown takes up to about 4.5 s
instead of being instant. If the daemon is killed hard instead, the next start finds the ledger and
stops the leftover CLIs it can verify.
