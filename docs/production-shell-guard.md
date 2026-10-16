# Production-shell guard

Agents in Nostromo may not open a remote ECS/SSM shell, and may not type into a tmux pane
that runs one. This turns the prose rules in `~/.claude/CLAUDE.md` into an enforced check.
Demo, canada and staging count as production.

## Where it runs

Every session the daemon hosts, both unrestricted (`--dangerously-skip-permissions`) and
restricted (`--permission-mode dontAsk`), gets one extra argument pair:
`--settings '<json>'`. The JSON comes from `approvals::guard::hook_settings_json`. It
installs `nostromo-guard pre-tool-use` as a PreToolUse hook on every tool (`"matcher":"*"`).

- The hook runs before any permission decision, whether or not the call would have
  prompted. A permission mode, an allow rule or the bypass flag can't skip it.
- `"disableAllHooks":false` in the inline settings overrides a `disableAllHooks: true` that
  an agent could write into user settings mid-session.
- There is no config file, env switch or UI that turns a block into an allow. The guard's
  only inputs are the hook payload and what tmux and `ps` report.

Mother jobs, your own terminal `claude` sessions, and `claude` started in a TUI agent view
(through `PtySpawn`) are **not** covered. The TUI gap is tracked in
`.claude/bugs/open/2026-10-16-tui-agent-views-spawn-claude-via-ptyspawn-without-the-production-shell-guard.md`.

## What is blocked

| Rule id | Blocks |
|---|---|
| `tool_name` | A tool named `ecs_connect`, `ecs_shell`, `ecs_open_tmux_pane` or `ecs_run_task`, including MCP tools (`mcp__x__ecs_connect`). |
| `command` | Any `command`, `cmd` or `script` field (Bash, Monitor, …) that contains `ecs_connect`, `ecs_shell`, `ecs_open_tmux_pane`, `ecs_run_task`, `ecs … execute-command`, `ecs … run-task`, `ssm … start-session` (with any global options in between, such as `aws ecs --profile p execute-command`) or `session-manager-plugin`. Running the *output* of `ecs_build_command` is blocked too: inside `$( )`, backticks or `<( )` (so `eval`, `source <( )` and `bash -c "$( )"`), or piped into anything but `pbcopy`, `cat`, `less`, `more`, `head`, `tail`, `grep` or `wc`. The search runs after deleting quotes and backslashes, so `bash -c`, `eval`, here-docs, subshells and `e"c"s_connect` are caught. It also runs on each command's words as the shell would see them, so `$'\x65cs_connect'` is caught too. |
| `tmux_input` | tmux commands that put input into a pane (`send-keys`, `send-prefix`, `paste-buffer`, `pipe-pane`) aimed at a remote pane. `tmux` matches in any case (`TMUX` runs tmux on macOS). Any prefix tmux would accept counts (`pi`, `pa`, `send-k`). An ambiguous prefix counts as the most dangerous command it could name. Commands that fill a buffer (`load-buffer`, `set-buffer`) or run other tmux commands (`if-shell`, `run-shell`, `bind-key`, `source-file`, `set-hook`, `confirm-before`, `command-prompt`, `display-menu`, `display-popup`, `display-panes`, `choose-*`), and a `$VAR` command name, can't be aimed, so they count as "can't tell". A pane is remote if its title starts with `production:`, `prod:`, `demo:`, `canada:`, `can:`, `ca:`, `staging:`, `stg:` or `stage:` (the title `ecs_open_tmux_pane` sets), or if its process tree runs `session-manager-plugin`, `aws ecs execute-command`, `aws ssm start-session` or `ecs_connect`. If the target can't be told (no `-t`, a `$VAR` target, a tmux call inside another program's string, or input the tokenizer can't parse), the call is blocked when **any** pane on that tmux server is remote. If the server can't be told either (`-L "$S"`, `-S "$P"`, a `TMUX=` or `TMUX_TMPDIR=` assignment, or tmux inside another program's string), every server is checked. That means the default one, every socket in `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`, and the directory a literal assignment names. tmux and `ps` run from fixed install paths (`/opt/homebrew/bin/tmux`, …, `/bin/ps`), so a `tmux` an agent plants on `PATH` can't answer for them. |

`ecs_run_task` and `aws ecs run-task` are blocked behind `BLOCK_RUN_TASK` (user question
U-B, default yes).

**Not blocked:** `ecs_build_command`, `ecs_copy_command`, `ecs_info`, read-only
`aws ecs describe-*` and `list-*`, tmux input to a local pane, and files that only *mention*
these commands (a `Write` or `Edit` isn't a command field).

On a block the agent is told:

> Blocked by Nostromo's production-shell guard: agents may not open or type into production
> shells. Give the user the command to run themselves.

Each block appends one `guard_blocked` line to `~/.nostromo/approvals/audit-YYYY-MM-DD.jsonl`.
The line holds the full tool input, the focus tag, the session and tool-use ids, and the rule
id. The directory is mode 0700 and the files are 0600.

## How it fails closed

- **Missing binary.** The hook command is
  `'<guard>' pre-tool-use || { echo "…could not run…" >&2; exit 2; }`. Exit 2 makes the CLI
  block the call. A missing binary would otherwise fail open.
- **Guard error.** Bad or oversized (> 4 MiB) input, a panic, an audit write failure, or a
  probe failure where the answer matters all make `nostromo-guard` exit 2 with the same
  message.
- **Not installed.** If `nostromd` can't find `nostromo-guard` beside itself, it uses the
  path `/nonexistent/nostromo-guard` and logs an `error!` at startup. Every agent tool call
  is then blocked until the guard is installed.
- **Hook timeout.** The session kills a hook after 30 s and lets the call through.
  `nostromo-guard` therefore has its own 20 s watchdog that exits 2 (block) first.
- **Probe timeouts.** `tmux` and `ps` each get 2 s. A timeout on a specific pane falls back
  to the any-remote-pane check. If that check can't run either, the call is blocked. If no
  tmux server answers at all, there is nothing to type into, so the call is allowed.

## Install

`make install-daemon` builds `nostromo-guard` and installs it beside the real `nostromd`
(through the `~/.local/bin/nostromd` symlink). It uses the same remove, copy and re-sign
steps as the daemon. The guard only takes effect for sessions spawned after that.
`install-daemon` restarts the daemon, which ends every daemon session.

`NOSTROMO_GUARD_BIN` overrides the path (tests). `NOSTROMO_APPROVALS_DIR` moves the audit
directory (tests). Neither changes what is blocked.

## Residual risks (known, not solved)

- Same-uid code can delete or replace the guard binary. Deleting it fails closed; replacing
  it doesn't.
- Obfuscation can hide the markers from the text scan, for example `$(printf …)` or base64.
- A script file whose *contents* call `ecs_connect` (`bash ./x.sh`) isn't read.
- A command written to a file and run later (`ecs_build_command … > x.sh; bash x.sh`), or
  pasted from the clipboard (`ecs_copy_command`, then `pbpaste | sh`), isn't followed.
- A tmux server on a socket outside tmux's socket directory, reached through a dynamic
  `-S "$P"`, isn't found by the every-server check.
- OS-level automation (AppleScript, Accessibility) that types into a terminal isn't seen.
  Neither is a fake app bundle that the user (or an agent) gets to run with those
  permissions.
- TUI agent views (`PtySpawn`) don't get the guard yet (see above).
- A `tmux send-keys` without `-t` from inside a tmux pane is treated as "can't tell", even
  though tmux would use `$TMUX_PANE`. This errs toward blocking.
