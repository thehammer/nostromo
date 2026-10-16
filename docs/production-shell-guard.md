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
| `tool_name` | A tool whose name contains `ecs_connect`, `ecs_shell`, `ecs_open_tmux_pane` or `ecs_run_task`, anywhere in the name: MCP tools (`mcp__x__ecs_connect`), `ecs_connect_session`, `my_ecs_shell`. |
| `command` | Any `command`, `cmd` or `script` field (Bash, Monitor, …) that contains `ecs_connect`, `ecs_shell`, `ecs_open_tmux_pane`, `ecs_run_task`, `ecs … execute-command`, `ecs … run-task`, `ssm … start-session` (with any global options in between, such as `aws ecs --profile p execute-command`) or `session-manager-plugin`. A name right after a `$` is a variable, not a command (`echo $ECS_CONNECT` is fine). Running the *output* of `ecs_build_command` is blocked too: inside `$( )`, backticks or `<( )` (so `eval`, `source <( )` and `bash -c "$( )"`), or piped into anything but `pbcopy`, `cat`, `less`, `more`, `head`, `tail`, `grep` or `wc`. The search runs on several texts. (1) The command with quotes and backslashes deleted, so `bash -c`, `eval`, here-docs, subshells and `e"c"s_connect` are caught. (2) Each command's words as the shell would see them, so `$'\x65cs_connect'` is caught too. (3) Both of those with the expansions that are empty deleted (`$VAR`, `${VAR}`, `$@`, `$*`, `$1`, `$()`, empty backticks, `${x:+y}`) and `${x:-lit}` replaced by `lit`, so `ecs_${U}connect`, `ecs_$@connect` and `ecs_c${x:-o}nnect` are caught. (4) Both of those with brace alternatives written out, each alternative as a word of its own as bash does, so `ecs_{connect,}`, `aws ecs execute-comman{d,}`, `aws ec{s,} execute-command` and `aws {ecs,execute-command}` are caught. Brace expansion is bounded: a word with more than 4096 alternatives (`{a..z}{a..z}{a..z}`), a brace word over 8 KiB or more than 512 KiB of expanded text is **blocked**, because it can't be scanned. A numeric range (`{1..100000}`) counts as one alternative: a marker has no digits. Finally, a word with an expansion in it that could be one of the marker words is blocked: `"ecs_"$U"connect"`, `ecs_$(echo)connect`, `execute-${U}command`. That means its literal parts fit the marker in order, with at least 4 literal characters (6 when the word starts or ends with an expansion; any `ecs_…` prefix counts). An operation word (`execute-command`, `start-session`, `run-task`) after a word that could be the service (`aws $S execute-command`) is blocked as well. |
| `command` (typed) | Text that tmux `send-keys` or `paste-buffer` would type into a pane, when it spells one of the above. The guard rebuilds the typed text from the arguments: `send-keys` joins its arguments with nothing in between, `Space`, `Enter`, `Tab` and `C-*` are keys, `-l` makes every argument literal, `-H` takes hex bytes, `-N` repeats. So `send-keys -t %0 ecs_c onnect Space ap Enter` types `ecs_connect ap`. A small line editor applies `BSpace`, `C-h`, `Left`, `Right`, `Home`, `End`, `Delete`, `C-a`, `C-e`, `C-u`, `C-k`, `C-w` (text typed out of order and fixed up), and a `Tab` after the first five or more characters of `ecs_connect` (the shell would complete it) is blocked. `set-buffer` (with `-a` and `-b`) fills buffers the same way and `paste-buffer` types them. Everything is joined across **all** tmux calls of one command string (`send-keys -l ecs_; send-keys -l connect`) and then scanned like any command text, so the expansion rules above apply to what the pane's shell would read (`send-keys -l 'ecs_${U}connect'`). This needs no probe and applies whatever the target pane is. Best effort for a call that is split across *separate tool calls*: when a `send-keys` goes to a local pane with a literal target, the guard reads the pane's last non-blank line (`capture-pane -p -J`, the prompt and what is typed after it) and blocks if the pending text plus the new keys spell a marker that neither part spells alone (`ecs_` already on the prompt, then `connect`). |
| `tmux_input` | tmux commands that put input into a pane (`send-keys`, `send-prefix`, `paste-buffer`, `pipe-pane`, and `respawn-pane -k`, which kills what runs in the pane) aimed at a remote pane. `tmux` matches in any case (`TMUX` runs tmux on macOS). Any prefix tmux would accept counts (`pi`, `pa`, `send-k`). An ambiguous prefix counts as the most dangerous command it could name. A **renamed tmux** is still tmux: a word counts as the tmux binary when it is followed by an input command whatever it is called (`/tmp/t send-keys …`, `xargs /tmp/t send-keys …`; the name must be exact, or a prefix of at least four characters, so `uv pip install` is not `pipe-pane`), when its name is a glob, brace expansion or expansion that can be `tmux` (`tm[u]x`, `t?ux`, `tm{u,u}x`, `tmu${U}x`), and when the file it names (symlinks and hard links followed, a relative path against the hook's `cwd` and any literal `cd`, a bare name on `PATH`, a glob expanded against the file system up to 64 matches) is the real tmux binary. A glob that matches too many files counts as tmux. Commands that fill a buffer (`load-buffer`, `set-buffer`) or run other tmux commands (`if-shell`, `run-shell`, `bind-key`, `source-file`, `set-hook`, `confirm-before`, `command-prompt`, `display-menu`, `display-popup`, `display-panes`, `choose-*`), a `$VAR` command name, and a name tmux doesn't define (it may be a `command-alias`) can't be aimed, so they count as "can't tell". So does a relative target (`{next}`, `{previous}`, `{last}`, `{top}`, `!`, `~`, `^`, `:+1`): tmux resolves it from where the agent is, not from where the guard's probe is. A pane is remote if its title starts with `production:`, `prod:`, `demo:`, `canada:`, `can:`, `ca:`, `staging:`, `stg:` or `stage:` (the title `ecs_open_tmux_pane` sets), or if its process tree runs `session-manager-plugin`, `aws ecs execute-command`, `aws ssm start-session` or `ecs_connect`. If the target can't be told (no `-t`, a `$VAR` target, a relative target, a tmux call inside another program's string, or input the tokenizer can't parse), the call is blocked when **any** pane on that tmux server is remote. "Inside another program's string" includes `libtmux` and any text that names an input command (`send-keys`, `paste-buffer`, …) without being a tmux call, such as `os.system("t"+"mux send-keys …")`. If the server can't be told either (`-L "$S"`, `-S "$P"`, any mention of `TMUX`, `TMUX_TMPDIR` or `TMUX_PANE`, `env -i` / `env -u`, or tmux inside another program's string), every server is checked. That means the default one, every socket in `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`, and the directory a literal assignment names. `respawn-pane` / `respawn-window` without `-k` refuse a live pane and are not input; with `-k` on a remote pane (or on a target that can't be told while a remote pane is open) they are blocked. |

`ecs_run_task` and `aws ecs run-task` are blocked behind `BLOCK_RUN_TASK` (user question
U-B, default yes).

**Not blocked:** `ecs_build_command`, `ecs_copy_command`, `ecs_info`, read-only
`aws ecs describe-*` and `list-*`, tmux input to a local pane, and files that only *mention*
these commands (a `Write` or `Edit` isn't a command field).

On a block the agent is told:

> Blocked by Nostromo's production-shell guard: agents may not open or type into production
> shells. Give the user the command to run themselves.

Each block appends one `guard_blocked` line to `~/.nostromo/approvals/audit-YYYY-MM-DD.jsonl`.
The line holds the tool input, the focus tag, the session and tool-use ids, and the rule
id. Every string in the recorded input (and the rule's detail) shows invisible and bidi
characters as `⟨U+202E⟩` (a newline and a tab stay), so a log reader can't be steered by hidden
text, and is cut at 16 KiB (`audit::MAX_RECORDED_STRING_BYTES`) with a `…[truncated]` note. The
directory is mode 0700 and the files are 0600. Files are opened with `O_NOFOLLOW`: a symlink
planted at today's file makes the append fail (the guard then exits 2 and blocks) instead of
writing through the link.

## The environment of the guard's own tmux calls

The guard's tmux and `ps` probes run with a **scrubbed environment**: only `PATH` is passed on. They never inherit `TMUX`, `TMUX_TMPDIR` or `TMUX_PANE`. Which server a probe talks to is always an explicit `-S <socket path>`, so these variables can't redirect or confuse it:

- `TMUX`: read once by the guard (from the hook process's own environment, i.e. the session's) to find the server a plain `tmux` uses: the socket path before the first comma. Otherwise the default socket is `<socket dir>/default`.
- `TMUX_TMPDIR`: read the same way, for the socket directory `${TMUX_TMPDIR:-/tmp}/tmux-<uid>` that `-L <name>` and the every-server check use.
- `TMUX_PANE`: not read. Commands that mention it are "can't tell".

An agent's own `export TMUX_TMPDIR=…` in a Bash call doesn't reach the hook process (the hook runs in the session's environment, not the command's). If the *session* was started with them set, the guard follows the same values as the session's `tmux`. Every pane is looked at in a UTF-8 client (`-u`). A tmux binary an agent plants on `PATH` can't answer for the real one: tmux is run from a fixed install path.

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
(through the `~/.local/bin/nostromd` symlink). Both binaries are copied to new files next to
their destinations and re-signed there first; only when **both** steps worked for both are
they moved over the old ones. If a copy or a codesign fails, the install stops with a clear
message and neither `nostromd` nor `nostromo-guard` is replaced (a new daemon beside a missing
guard would block every agent tool call). The guard only takes effect for sessions spawned
after that.
`install-daemon` restarts the daemon, which ends every daemon session.

`NOSTROMO_GUARD_BIN` overrides the path (tests). `NOSTROMO_APPROVALS_DIR` moves the audit
directory (tests). Neither changes what is blocked.

## Residual risks (known, not solved)

- Same-uid code can delete or replace the guard binary. Deleting it fails closed; replacing
  it doesn't.
- Obfuscation can hide the markers from the text scan, for example `$(printf …)` or base64.
  The scan is a denylist: the cases above (quotes, `$'\x..'`, empty and default expansions,
  brace alternatives, a word that could be a marker) close the cheap ones, not the class.
  A variable holding part of a marker (`U=o; ecs_c${U}nnect`) is caught only because a word
  with an expansion between literal parts that fit a marker is blocked.
- A script file whose *contents* call `ecs_connect` (`bash ./x.sh`) isn't read.
- A command written to a file and run later (`ecs_build_command … > x.sh; bash x.sh`), or
  pasted from the clipboard (`ecs_copy_command`, then `pbpaste | sh`), isn't followed.
- A tmux server on a socket outside tmux's socket directory, reached through a dynamic
  `-S "$P"`, isn't found by the every-server check. (Finding servers from the process table
  would close this; not done.)
- A tmux `command-alias` that shadows a command name (`ls=send-keys`), set before the
  session or kept on the server from an earlier call, isn't resolved. Changing one through
  tmux while a remote pane is open is blocked, but the guard doesn't read the live alias list.
- tmux reached as another user (`sudo tmux`, `su`) talks to that user's server, which the
  every-server check doesn't list.
- OS-level automation (AppleScript, Accessibility) that types into a terminal isn't seen.
  Neither is a fake app bundle that the user (or an agent) gets to run with those
  permissions.
- TUI agent views (`PtySpawn`) don't get the guard yet (see above).
- A `tmux send-keys` without `-t` from inside a tmux pane is treated as "can't tell", even
  though tmux would use `$TMUX_PANE`. This errs toward blocking.
- **Typing a marker in pieces across separate tool calls** (`send-keys -l 'ecs_'` in one call,
  `send-keys -l 'connect'` in the next) can't be caught from the text of either call. The
  only mitigation is the best-effort prompt-line check above: it works when the pane's last
  non-blank line still holds the first piece (a wrapped or scrolled prompt, a line editor
  that redraws, or text typed with other keys in between defeats it), and it needs a literal
  `-t` target. The same goes for a marker written to a file or the clipboard in one call
  and run in another.
- **An unguarded agent can be started from a guarded session.** The guard hooks one `claude`
  session's own tool calls. A guarded session can start another `claude` without it
  (`claude --dangerously-skip-permissions -p "…"`, which the guard doesn't read as a marker)
  or ask Mother to run a job (`mother_enqueue_job`): neither the new session nor the Mother
  worker has the hook.
- Other tmux commands that end or change a production pane (`kill-pane`, `kill-window`,
  `kill-session`, `respawn-window -k` on a window that holds one pane) are not input, and
  only `respawn-pane -k` / `respawn-window -k` are blocked.
- A *copy* of the tmux binary under another name (made in the same command, so it doesn't
  exist when the guard looks) is recognised only when its first argument is an input command
  (`/tmp/t send-keys …`). `cp $(which tmux) /tmp/t; /tmp/t run-shell '…'` isn't. A symlink
  or hard link that already exists is found by file identity; one made in the same command
  string only by its first argument.
- `send-keys` aimed through an alias only (`send` in an interpreter's string, `os.system("t"+
  "mux send -t %1 x")`) is caught only when it has `-t`.
- A `send-keys` key that edits the shell line in a way the small line editor doesn't model
  (history recall with `Up`, readline `M-` keys, vi mode) can still rebuild a marker out of
  order. Unmodelled keys end the text like a space, and the text is also scanned with them
  dropped.
