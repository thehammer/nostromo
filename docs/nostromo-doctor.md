# nostromo-doctor

A one-shot health check for the Nostromo system: the `nostromd` daemon, the
macOS GUI, the IPC channel between them, and the known persistent agent
sessions the daemon hosts. Run it whenever something feels off — an agent
seems slow, a click did nothing, a pane went quiet — before spending time on
a manual `ps`/`lsof`/socket-probe/log-grep diagnosis by hand.

See `.claude/prds/nostromo-doctor.md` (in the primary repo checkout) for the
full requirements and the five incidents that motivated it.

## Running it

```
bin/nostromo-doctor
```

No arguments, no build/install step, no daemon-internal access beyond what's
described below. It works from any directory — it locates its own repo root
relative to its own file path.

## What it checks

Checks run in this foundational-first order, so a dead daemon explains
downstream INCONCLUSIVE results rather than compounding into unrelated-looking
noise:

1. **Daemon liveness** — is `nostromd` running (via `launchctl`, falling back
   to a `ps` match), its PID, and uptime.
2. **GUI liveness & CPU** — is the Nostromo.app GUI running and its sampled
   CPU usage. A closed GUI is a normal, OK state — it's a client, not a
   dependency of the daemon.
3. **IPC channel liveness** — opens the daemon's Unix socket and performs a
   real `hello`/`welcome` handshake (not a `stat` of the socket file).
   Distinguishes "no socket file" from "socket present but not responding"
   from "responding". Reuses the same connection to fetch the daemon's
   session list for checks 8 and 9.
4. **Stuck / piled-up child processes** — walks the transitive descendant
   tree of the daemon and GUI PIDs looking for duplicate-command pile-ups,
   zombies, and helper processes that have run far longer than expected.
5. **Load average vs. core count** — flags an abnormal load/core ratio and
   names the top CPU offenders driving it (which may live in an unrelated
   project — this tool only reports the symptom).
6. **Installed-vs-source staleness** — compares the installed `nostromd`
   binary's mtime against `git log` on `src`/`Cargo.toml`/`Cargo.lock`, and
   the installed `Nostromo.app`'s mtime against `git log` on `macOS`/`Shared`.
   Only committed history counts — an uncommitted working tree never trips a
   false staleness warning, and a missing artifact is INCONCLUSIVE (you might
   be running from a dev build), never FAIL.
7. **Recent daemon errors** — tails the most recently modified
   `~/.cache/nostromd/log/nostromd.log.*` file directly (no shelling out to
   the macOS `log` command — that's what a prior incident's shell had
   silently shadowed with a builtin) and reports ERROR-level entries from the
   last 15 minutes.
8. **Per-known-session progress** — for each tag configured in
   `~/.nostromo/sessions.toml`, reports liveness and last transcript activity.
   Escalates to WARN only on a positive stuck signal (a crashed session, an
   in-flight turn that hasn't advanced, or CPU-pinned with no transcript
   progress) — a long-idle-but-alive agent (e.g. quietly waiting on the
   operator) stays silent. This is the tool's most cry-wolf-sensitive check;
   see `tests/doctor/test_nostromo_doctor.py`'s `ClassifySessionSignalTests`
   for the exact rule table.
9. **Session pane registry sanity** — reports, per known session, whether the
   daemon's `daemon-panes.json` shows an applied pane layout or the collapsed
   default, so a misleading "this session never got a custom layout" reading
   is visible as informational rather than silently trusted. Never FAILs —
   this check only reduced-form covers the richer daemon-internal cross-check
   the PRD flagged as the first thing to defer if it required daemon-internal
   coupling; this implementation reads only the JSON registry file.
10. **Ambient activity hook** — reports whether `~/.claude/settings.json`
    registers the `nostromo-activity-hook` producer (see `docs/activity.md`)
    for all three of `PostToolUse`/`SubagentStart`/`SubagentStop`. WARNs
    (never FAILs) when the file is missing/unparseable or the hook is
    missing for any of the three events, naming the missing event(s).

## Installing the ambient activity hook: `--fix`

```
bin/nostromo-doctor --fix
```

The **only** flag this tool has, and the only thing in it that writes
`~/.claude/settings.json` — a plain `nostromo-doctor` run never touches it.
Registers `nostromo-activity-hook` (preferring an already-installed binary
under `~/.local/bin` or `~/.cargo/bin`) against `PostToolUse`, `SubagentStart`,
and `SubagentStop`. Idempotent: re-running never duplicates an entry that
already names the hook binary, and never disturbs an existing, unrelated
hook entry for the same event. Writes via a sibling temp file + atomic
rename, so a crash mid-write can't corrupt or truncate the operator's
existing settings.

`--fix` skips every other check — it does not run the report, and no other
check in this tool ever writes anything (see "What's intentionally out of
scope" below).

## Output & exit-code contract

One line per check: `STATUS  <name> — <detail>`, with an indented
`→ next step: …` line for anything not OK. A final `Summary: <worst> — N
failure(s), N warning(s), N inconclusive` line states the worst status found.

- Exit code is **non-zero if and only if at least one check is FAIL**.
  WARN and INCONCLUSIVE alone exit 0. This is the one machine-readable
  affordance in v1 (no JSON output mode yet).
- A check that cannot run (missing tool, permission error, unreadable file)
  reports INCONCLUSIVE with a reason — never a silent OK. "I couldn't check"
  is never "OK."
- Every non-OK line names a concrete next step (a command, a PID, a file) —
  never a bare "failed." This is enforced by `validate_check_result()` in the
  runner itself, so no check can skip it.

## Environment variables

- `NOSTROMOD_SOCKET` — override the daemon socket path (defaults to
  `~/.nostromo/nostromd.sock`), same variable the daemon and its other
  clients honor.

## Adding a check

There's no build step — add a function, register it, done:

1. Write a function `check_my_thing(ctx)` in `bin/nostromo-doctor` that
   returns a `CheckResult(name, status, detail, next_step)`. `ctx` is the
   dict built by `build_context()`; it carries resolved absolute tool paths
   (`ctx["tools"]`), the repo root, the socket path, and (once check 3 has
   run) the cached IPC session list.
2. Add it to the `CHECKS` list, in whatever order makes sense relative to the
   other checks' dependencies.
3. If the check has any pure parsing/classification logic, factor it into a
   standalone function and add fixture-driven tests for it in
   `tests/doctor/test_nostromo_doctor.py` (see that file's existing tests for
   the pattern — it loads `bin/nostromo-doctor` via
   `importlib.util.spec_from_file_location` since the filename has no `.py`
   suffix).
4. Every external tool must be invoked via `run_command()` with an absolute,
   pre-resolved path from `resolve_tools()` — never a bare command name that
   would go through a shell or `$PATH`. This is what makes the tool immune to
   shell builtins/aliases/functions shadowing the real binary.
5. Run `/usr/bin/python3 -m unittest discover -s tests/doctor` and then the
   tool itself against a live system before opening a PR.

## What's intentionally out of scope

No JSON output mode, no background/scheduled operation, no auto-remediation
(this tool reports and recommends — it never kills a process, runs
`make install`, or restarts the daemon), no historical trending. See the PRD
for the full list and rationale.

`--fix` is the one deliberate exception: installing the ambient activity
hook is a config write, not a remediation of a running process, and it only
ever happens when the operator explicitly passes `--fix` — never as a side
effect of a plain check run.
