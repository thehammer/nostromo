# Terminal panes (daemon side)

`nostromd` owns every terminal pane's process: a PTY running the user's login shell (`src/terminal/`). The Mac app is an attach client. The shell outlives the app; it does not outlive the daemon.

## The operator-only rule

Only the verified Mac app can type into, read, resize, close or restart a terminal.

- A connection is the operator app when AP1's verifier says so (`PeerTrust::OperatorApp`: the `mac_app` claim plus a verified bundle; see `src/ipc/peer_verify.rs`).
- `src/terminal/access.rs` mints an `OperatorCap` from that trust and nothing else. `src/ipc/server.rs` mints it once per connection, after `Hello`.
- The cap is held back until a `Subscribe` echoes the `operator_nonce` from that connection's `Welcome` and a fresh inspection still sees the verified app. A process can write `Hello` plus terminal verbs and then `exec` the real app, which passes the check at `Hello`. Those bytes cannot contain the nonce, which is issued only after verification. The app sends the nonce in `Subscribe` (or in a later re-`Subscribe`).
- Open, attach, close and restart inspect the peer again. Input and resize do not: the inspection is a code-signing check, too slow for every keystroke.
- Every `TerminalManager` method that writes input, resizes, attaches (reads output), closes or restarts takes `&OperatorCap`. The MCP side has no `PeerTrust` and so can never get one.
- The one cap-less way in is `TerminalManager::open_local_for_agent(tag, cwd)`. It can only start a shell in the agent's focus; the agent never gets its input, output or close.
- Any other local peer's terminal verb is answered with `terminal_refused` and changes nothing.

Codes: `terminal_input_forbidden` (input), `terminal_read_forbidden` (attach), `terminal_close_forbidden` (close), `terminal_control_forbidden` (open, resize, restart). Each refusal is audited with `channel: "ipc"`, the op, the code and the peer's pid and exe.

Terminal output is never broadcast. It goes only to attached operator connections, through each connection's bounded terminal stream.

## Wire messages

Additive; `PROTOCOL_VERSION` is unchanged. Byte fields are base64. `*` means operator app only.

| Client → daemon | Fields |
|---|---|
| `terminal_open_local`* | `tag, relative_to?` (default `repl`), `position?` (default `split_below`), `cwd?` (default `$HOME`), `client_request_id` |
| `terminal_attach`* | `terminal_id` |
| `terminal_detach` | `terminal_id` (this connection's attachment only) |
| `terminal_input`* | `terminal_id, bytes` |
| `terminal_resize`* | `terminal_id, cols, rows` |
| `terminal_close`* | `terminal_id` |
| `terminal_restart`* | `terminal_id` (a local terminal that has `ended`) |
| `terminal_keep_alive`* | `terminal_id` (a remote shell: restart its idle timer, see Idle timeout) |
| `terminal_remote_summary_request` | none; any local peer (metadata only, changes nothing) |
| `terminal_refusal_report`* | `terminal_id?, op, channel` (audited; ignored from anyone else) |

`Subscribe` also takes `capabilities: [String]` (default empty, recorded only for the operator app) and `operator_nonce?` (the `Welcome`'s; required before any `*` verb is honoured).

Other `terminal_refused` codes: `unknown_terminal`, `terminal_not_ended`, `terminal_not_running`, `terminal_input_busy` (the process is not reading its input and the queue is full, by count or by bytes), `terminal_input_too_large` (one frame over 256 KiB of raw bytes), `terminal_limit_reached` (too many terminals, see Limits), `terminal_audit_unavailable` (see Audit), `invalid_size` (above 1000×500), `invalid_working_directory`, `invalid_bytes`, `terminal_open_failed`, and a pane error code (`unknown_pane`, `invalid_position`). Refusals carry the op, the terminal id and the code, never any input bytes.

| Daemon → client | Routing | Fields |
|---|---|---|
| `terminal_list` | targeted, to each local connection after the layout replay | `terminals: [TerminalInfo]`, `closed?: [TerminalClosed]` |
| `terminal_state` | broadcast, `Topic::Terminal` | `terminal: TerminalInfo` |
| `terminal_closed` | broadcast, `Topic::Terminal` | `terminal_id, tag, pane_id, label, kind, reason, exit_code?, target?` |
| `terminal_replay` | the attaching connection | `terminal_id, cols, rows, bytes` (ring, then a repaint of the screen; a large replay continues in `terminal_output` frames) |
| `terminal_output` | attached connections | `terminal_id, bytes` |
| `terminal_refused` | targeted | `op, terminal_id?, code` |
| `terminal_remote_summary` | targeted, answers `terminal_remote_summary_request` | `shells: [{label, target, opened_at}]` (open `ecs` terminals; no output) |

A terminal leaf's pane id is `terminal-<8 hex>`. The daemon also sends `pane_content` with `kind: "terminal"` (`terminal_id, label`, `environment` only for a remote shell) so a client that cannot attach can show a placeholder.

## Remote shells: request, confirm, connect (slice 2a)

An agent can **ask** for a shell on a remote ECS service; only a human click on the verified app **opens** one. The agent can never type into it (see `docs/production-shell-guard.md`: the `ecs_*` shell functions, `aws ecs execute-command` and tmux input into a remote pane stay blocked for agents; the request tool is the one open path, and it opens nothing by itself).

**Vocabulary.** The daemon reads the carefeed layer's ECS data as data, afresh on every request and never cached: `config.json` (clusters, services, regions, shell commands), `~/.claude/ecs-local.json` (the user's profiles) and the three `declare -A ECS_{ENV,SERVICE,PROJECT}_ALIASES` tables of `ecs.sh`, scanned as **text** with a strict regex and never sourced or run (a block that holds anything but `[word]="word"` entries gives no aliases, with a warning). Paths: `[terminal] ecs_config`, `ecs_local`, `ecs_aliases_script` in `~/.config/nostromo/config.toml`; defaults are under `~/.claude/layers/carefeed/lib/services/ecs/` (then `~/.claude/lib/services/ecs/`). Resolution is lowercase, then alias, then validation of each level (project, environment, service, shell type); a word outside the vocabulary is an `invalid_target` that lists what is valid. An environment with no `regions` entry is not offered. **Every value that reaches the command line is checked** before it is used: the profile, region, cluster, ECS service name and container must be 1 to 32/128/255 characters of letters, digits and `-_./:@=` (no whitespace, no leading `-`); the shell command must be words of those characters separated by single spaces (no `;|&$`, backtick, `<>()`, quotes, backslash, line breaks or non-ASCII). A value that fails is refused as `remote_shells_not_configured` with a fixed code (`unsafe_profile`, `unsafe_region`, `unsafe_cluster`, `unsafe_service_name`, `unsafe_container`, `unsafe_shell_command`) and the value is never echoed. The SHA-256 of the exact bytes read of `config.json` and `ecs-local.json`, and of the resolved argv (with the task left as `<task>`), are pinned in the request; the daemon never reloads between the confirm and the launch. A profile that is missing or still `CONFIGURE_ME` resolves to none. No `config.json` means remote shells are not configured.

**Flow** (`src/terminal/remote_request.rs`):

1. Resolve the four words. An unknown word returns at once; no one is asked.
2. Only operator connections that sent `capabilities: ["remote_shell_confirm"]` in their `Subscribe` can be asked. None: `no_operator` at once. A verified app that does not declare the capability, a TCP client that renders decisions and any other local process do not count.
3. At most one request waits at a time (`request_pending`). Two further rules hold **agent** requests (never the user's own, so they cannot lock the user out), keyed by the agent's focus tag: a *cooldown* after the user's Cancel, Dismiss or a timeout (60 s, doubling per consecutive denial up to 15 minutes, reset by a Connect, forgotten after an hour without a denial) refuses with `request_cooldown`; and at most 3 requests per focus in 10 minutes, then `request_limit`. Both refusals are content-free, send no sheet and are audited like `request_pending`. A request the **user** makes (`remote_shell_open`) while an agent's waits takes the slot: the agent's request ends as `superseded` (audited, the sheet for it is closed, it does not count as a denial).
4. `remote_shell_confirm_request` goes to those connections and no one else.
5. The daemon waits (300 s by default, clamped to 10-600 s) for `remote_shell_answer {decision: connect|cancel|dismiss}` from the operator app (`OperatorCap`).
6. Only after Connect is the launcher called (`RemoteLauncher`; this daemon's is `AwsEcsLauncher`, see "Connecting" below). Before that no process, pane or terminal exists.
7. `remote_shell_resolved` goes to the same connections: `connected`, `cancelled`, `dismissed`, `timed_out` or `connect_failed` (with `reason`, `remedy` and, for the person at the app only, `detail`: the first sanitised line the AWS CLI printed).
8. Every step is audited.

If the agent's MCP connection closes while the request waits, the request is abandoned: the sheet is closed (`remote_shell_resolved` `cancelled`, `reason: "requester_gone"`) and the slot is freed.

| Client → daemon | Fields |
|---|---|
| `remote_shell_targets_request` | none; any local peer |
| `remote_shell_open`* | `tag, project, environment, service, shell_type` (the user's own request; same confirm flow with `requested_by: {kind: "user"}`; failures before the sheet arrive as `terminal_refused {op: "remote_open", code}`) |
| `remote_shell_answer`* | `request_id, decision, invite_follow?` (`connect` with `invite_follow: true` on an agent's request: that agent follows the shell once it is running, `via: "sheet"`; see Agent follow) |

| Daemon → client | Routing | Fields |
|---|---|---|
| `remote_shell_targets` | targeted | `configured, problem?, projects: [{name, default_service?, environments: [{name, services}]}], shell_types` (no profiles, clusters or accounts) |
| `remote_shell_confirm_request` | targeted to operator connections with `remote_shell_confirm` | `request_id, tag?, target, requested_by: {kind, tag?, agent?}, reason?, expires_at, shell_command?, profile?, cluster?` (what will run, from the pinned data; the sheet shows them) |
| `remote_shell_resolved` | the same connections | `request_id, outcome, reason?, remedy?, detail?` (`detail`: operator only, the CLI's first line, sanitised) |

`remote_shell_open` and `remote_shell_answer` from anyone but the verified app (even a process claiming `client_kind: "mac_app"`) get `terminal_refused {op: "control", code: "terminal_control_forbidden"}` and an audited `refused`; the request stays pending. Over TCP they are refused by FND-1 like every terminal frame. All three server frames are `LocalOnly` and never broadcast.

Audit events (`terminal.jsonl`): `remote_requested {tag, requested_by, target, reason (200 chars at most)}`, `confirm_outcome {tag, target, outcome: connect|cancelled|dismissed|timed_out|abandoned|superseded|no_operator|request_pending|request_cooldown|request_limit, invite_follow?}`, `connect_started {tag, target, config_sha256, local_sha256?, argv_sha256}`, `connected {terminal_id, pane_id, tag, kind, target, config_sha256, local_sha256?, argv_sha256}` (the digests the request was pinned to), `connect_failed {reason_code}`. A connect that fails after its pane appeared also writes `closed` with the same code as its reason; the remote-shell `closed` reasons are codes, never output. `no_operator`, `request_pending`, `request_cooldown` and `request_limit` lines share the per-channel refusal budget. No command, keystroke or output text is ever written.

MCP tools: `nostromo.list_remote_shell_targets` and `nostromo.request_remote_shell` (`docs/mcp/tools.md`). The `request_remote_shell` call **blocks until the user decides** (or the request times out) and, on Connect, returns `{ok, outcome: "connected", terminal_id, pane_id}` (plan §D6), not just a request id.

### Why there is no per-answer nonce

`DecisionAnswer` and `ApprovalAnswer` check an operator nonce on every message. `RemoteShellAnswer` and `RemoteShellOpen` do not: they rely on the `OperatorCap` minted at `Subscribe` (only after the `Welcome` nonce was echoed and a fresh inspection still saw the verified app) plus a code-signing re-check of the peer on every message. That is equivalent: the nonce exists to prove the sender is the verified app, the cap already proves that for the connection, and the per-message re-check stops a process that replaced the app after `Subscribe` from reusing it. A per-answer nonce would add nothing an attacker without the app's identity could not also forge, and nothing a verified app does not already prove.

### Where the human gesture is proved

The daemon cannot tell a click from a synthetic event. The proof that a human pressed Connect lives in slice 2c's confirm sheet (the `HumanGesture` check in the Mac app); the daemon only trusts an answer from the verified app on a connection that declared `remote_shell_confirm`.

### 2b must

Slice 2b runs `shell_command`, and `shell_command`, `profile` and `cluster` come from `config.json` under `~/.claude/layers/...`, which an agent may be able to write. So 2b must:

1. pin the resolved command when the request is made (already true: the target is resolved before the sheet is shown, and nothing is re-resolved);
2. show the content hash of the file(s) it was read from, or record it in the audit, at Connect;
3. never reload the file between Connect and launch.

## Agent follow (slice 3b)

A focus follows a terminal only when the user invites it. Output the terminal produces afterwards is delivered into the follower's conversation without any user action (`src/terminal/follow/manager.rs`).

| Client → daemon | Fields |
|---|---|
| `terminal_follow_invite`* | `terminal_id, follower_tag, include_screen?` (needs the connection's `terminal_follow_ui` capability, else `terminal_follow_ui_required`) |
| `terminal_follow_stop`* | `terminal_id` |
| `terminal_follow_resume`* | `terminal_id` (only a paused follow) |
| `terminal_send_selection`* | `terminal_id, target_tag, text` (any terminal; no `terminal_follow_ui` needed) |

Refusal codes: `terminal_control_forbidden` (not the operator app; audited), `unknown_terminal`, `follower_not_running`, `not_followed`, `not_paused`, `empty_selection`. `TerminalInfo.follower` is `{tag, paused, pause_reason?}` while a focus follows; each change is broadcast as `terminal_state`.

- **One follower per terminal.** Inviting another focus moves the invitation: the previous follower is told it stopped (`moved_to <tag>`).
- **Only output after the invite** is delivered, unless `include_screen`: then the visible screen goes first, in the same message as the `started` notice.
- **The pump.** A reader hook queues each chunk for the follow's task, which feeds the line assembler and asks the delivery policy every 100 ms: settled output (800 ms quiet, 200 ms at a prompt) or sustained output (at most every 10 s) is redacted, capped (200 lines / 16 KiB, head and tail) and written as `<nostromo-terminal-output terminal_id pane kind lines omitted redactions>` with a fixed advisory line. A full-screen program is delivered as a screen snapshot (`kind="screen"`). `pane` is `local shell in <dir>` or the remote shell's label. Flooding pauses the follow (`too_much_output`, `too_many_deliveries`) until `terminal_follow_resume`; what arrived while paused is never delivered.
- **Into the conversation** (`SessionManager::inject`): an idle session is written to at once and starts a turn. While a turn runs, deliveries and notices wait in the queue and are combined into one message (48 KiB at most; middle deliveries are dropped with `[… K earlier deliveries omitted …]`). A user's queued message is never combined with anything. The echoed message opens a turn whose `origin` lists each delivery (`Turn.origin`, read from the text, so a reloaded transcript has it too).
- **Notices** (`<nostromo-terminal-follow event reason?/>` plus a sentence): `started`, `paused`, `resumed`, `stopped` with `user_stopped`, `moved_to <tag>`, `pane_closed`, `terminal_restarted`, `app_closed`.
- **Ends** when the user stops it (output not yet delivered, buffered or still queued, is discarded), the pane closes or the terminal is restarted, the follower's session stops, restarts, starts a new session, crash-loops or its focus is removed (no notice), or the last operator-app connection goes. Nothing is persisted: a new daemon follows nothing.

- **Three ways in, and no others.** Following starts only by the pane's Follow control (`terminal_follow_invite`, `via: "control"`), by Connect with the follow box ticked on the remote-shell confirm sheet (`via: "sheet"`), or by Allow on an agent's `nostromo.request_follow` (`via: "request"`). The last two are the verified app's answer (`remote_shell_answer`, `decision_answer`), acted on by the call that waited for it (`FollowGrant`, crate-private; `src/mcp/` cannot name it): a request the agent gave up on, a user-opened shell, a failed connect, or no connected app with `terminal_follow_ui` follows nothing.
- **Agent tools** (`nostromo.list_terminals`, `nostromo.request_follow`, `nostromo.read_terminal_screen`; see `docs/mcp/tools.md`). Reading is only for the current follower (active or paused; reading while a follow is paused for flood is intended); anyone else gets `terminal_read_forbidden`, audited, and no delivery. An agent's follow request is held to the remote-shell request rules (`FocusLimits` in `src/terminal/remote_request.rs`, one history per kind of request): after a Deny, dismissal or timeout `request_cooldown` for 60 s, doubling to 15 minutes, and at most 3 requests per 10 minutes per focus (`request_limit`); neither shows a sheet. Reads are limited per follower to one every 2 s (`read_too_soon`) and 240 an hour (`read_limit`), each refusal audited with its code only, and those lines share the per-channel refusal budget, so a loop of refused reads stops writing after it. A cancelled `request_follow` counts toward the 3-per-10-minutes ceiling but starts no cooldown. Reading an ECS (production shell) screen marks the reader sensitive for good, before the text is returned (it stays in the reader's transcript after the follow ends); a local terminal read does not mark, and a refused read does not mark.
- **Sensitivity.** A follower of an ECS terminal is held sensitive for as long as it follows (so its turns never reach a network peer, and the hold lapses with the follow); that covers `nostromo.read_terminal_screen`, which only the follower can call. A selection sent *from* an ECS terminal marks its recipient sensitive for good (as does one from a sensitive focus's terminal), before it is written, because the text stays in that conversation.
- **Send selection.** `terminal_send_selection` redacts and caps the text (200 lines / 16 KiB, like a delivery; redacted as a fragment, so a selection that starts in the middle of a private key loses everything down to the key's `END`) and writes it once into `target_tag`'s conversation as `<nostromo-terminal-output … kind="selection" …>` with its own advisory line. It never starts following, works on any terminal, leaves another focus's follow alone, and is always a message of its own (never combined with deliveries, and under a key of its own, so stopping a follow never drops it).

Audit events: `selection_sent {terminal_id, tag, target, lines, bytes, redactions}`, `screen_read {terminal_id, focus, lines, bytes}`, `follow_invited {follower, include_screen, via}`, `follow_stopped {follower, reason}`, `follow_paused {follower, reason}`, `follow_resumed {follower}`, `delivery {follower, kind, lines, bytes, redactions, truncated}`. Counts and sizes only.

### Connecting (slice 2b)

`AwsEcsLauncher` (`src/terminal/ecs/connect.rs`) runs after Connect. It does not call the layer's `ecs_build_command` (that contacts AWS, may run `aws sso login`, returns a string for `eval` and needs bash 4); it builds the command itself from the layer's *data*.

1. No profile for the environment: `profile_not_configured`.
2. The AWS CLI is found by absolute path: `[terminal] aws_cli`, then `$NOSTROMO_AWS_CLI`, then `/opt/homebrew/bin/aws`, `/usr/local/bin/aws`, `/usr/bin/aws`; none: `aws_cli_missing`. launchd gives `nostromd` almost no `PATH`, so the child's is `<aws dir>:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` (that is where `session-manager-plugin` is found). The child's environment is an **allowlist**, nothing else of the daemon's: `HOME`, `USER`, `LANG`, `TMPDIR`, `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` (only when the daemon has them set) plus the `PATH`, `TERM=xterm-256color` and `AWS_PAGER=""` the daemon sets. Before the AWS CLI is started for the shell, the app that said Connect must still be connected (`operator_gone`).
3. `aws sts get-caller-identity`, `aws ecs list-tasks` and `aws ecs describe-tasks` (argv arrays, `--output json`, `AWS_PAGER=""`, 10 s each, no shell). The task is the first RUNNING one with ECS Exec enabled, as `ecs_get_task_arn` picks it; a task ARN AWS returns is used only if it is `arn:aws:ecs:` followed by letters, digits and `:/_.-` (at most 300 characters), else `aws_error`. **`aws sso login` is never run**: an expired session is `sso_expired` with the remedy ``Run `aws sso login --sso-session <sso_session>` `` (from `ecs-local.json`, default `carefeed`).
4. The pane and terminal are created in status `connecting`: kind `ecs`, label `<env> · <project> · <service> · <shell_type>`, process `aws ecs execute-command --profile … --region … --cluster … --task … --container … --interactive --command <shell command>`. The shell command is one argv element; nothing here runs a shell.
5. The session-manager plugin's `Starting session with SessionId` makes it `running` (`terminal_state`, and the request returns `connected`). An exit before that is a connect failure: the pane and record are removed and the request returns `{error: "connect_failed", reason, remedy}` with one of `session_manager_plugin_missing`, `sso_expired`, `target_not_connected`, `access_denied`, `unknown`. **The agent gets only the code and the fixed remedy for it**: nothing the CLI printed, in any failure class. The person at the app also gets, on `remote_shell_resolved`, the first sanitised line (`aws_error`) or the last three non-empty lines (`unknown`) as `detail`; it is never audited. No marker within 60 s: the process is killed, `connect_timeout`. The captured output is at most 4 KiB before the session begins and 512 bytes after (it is the remote shell's output by then), never audited, and dropped once classified.

**The connection is the pane.** Any exit after `running` removes the pane and sends `terminal_closed {reason, exit_code, target, label}`: `user_closed` (the operator closed it), `remote_exit` (the session printed `Exiting session with sessionId`), `sso_expired` or `network` (from the output's last lines), else `unknown`. Nothing reconnects; a new shell needs a new request and a new confirm. `terminal_restart` on an `ecs` terminal is refused (`terminal_control_forbidden`). An `ecs` terminal is `connecting`, `running` or gone, never `ended`. A persisted `ecs` record at daemon start loses its pane and is reported closed `daemon_stopped`.

Tests use `tests/fixtures/fake-aws` (Python standard library; modes `ok`, `expired`, `no_tasks`, `exec_disabled`, `plugin_missing`, `drop_after_connect`, `hang`, `spam`; `FAKE_AWS_MODE`, `FAKE_AWS_LOG`). The QA instance passes `NOSTROMO_AWS_CLI` through, so it drives live QA too. Never point a test or a QA run at the real AWS.

### Idle timeout (slice 2e)

A remote shell with no **keystrokes** for 15 minutes closes. From 13 minutes the daemon sets `TerminalInfo.idle_closes_at` (broadcast in `terminal_state`) so the app can show a countdown and a Keep open button. The clock (`src/terminal/idle.rs`, a 1 s tick) is reset **only** by `terminal_input` from the operator app (after a warning: audited `idle_kept_open {via: "keystroke"}`) and by `terminal_keep_alive` (operator app only; anyone else gets `terminal_refused` and an audit line; `via: "button"`). Output (even a flood of it), resize and attach never reset it, so an unattended shell that prints cannot keep itself open. A warning clears `idle_closes_at` again once kept open. At 15 minutes the shell is killed and `terminal_closed {reason: "idle_timeout"}` is sent. Local terminals are exempt. The clock starts when the session begins, not while it connects.

Audit lines: `idle_warning {closes_at}`, `idle_kept_open {via}`, `idle_closed`, then the usual `closed {reason: "idle_timeout"}`. None carry keystrokes or output.

QA: `NOSTROMO_QA_IDLE_SECS=<n>` scales the policy (warn at `n - 2n/15`, close at `n` seconds) **only** when the daemon runs with `NOSTROMO_QA_DAEMON=1`; otherwise it is ignored with a warning.

### Guarded restart (slice 2e)

A daemon restart ends every shell. The *controlled* restart paths therefore refuse while remote shells are open: `make install`, `make install-daemon` and `make uninstall-daemon` run the guard (`bin/nostromo-restart-guard`), which runs `nostromd remote-shells` from the installed daemon (or `target/release/nostromd`) and, if any `ecs` terminal is open, prints it and stops with "Remote shells are open; they will be closed. Re-run with FORCE=1 to proceed." Override with `FORCE=1` or `NOSTROMO_FORCE_DAEMON_RESTART=1`. 

**Fail-open case.** The guard trusts `~/.local/bin/nostromd` or `target/release/nostromd` only if the binary contains `remote-shells`. When no qualifying binary exists it prints "not checking for open remote shells" and proceeds. The reason: a `nostromd` that predates the subcommand ignores its arguments and would start a second daemon instead of answering, so it must never be run. Nothing is checked in that case, so the guard cannot protect that restart.

**First guarded install.** The daemon that is running when this lands predates the summary frame, so it cannot answer. The guard then sees exit 4 (below), fails closed and says so; forcing (`FORCE=1`) is expected exactly once, for that first install. After the new daemon runs, the guard answers normally.

**Ordering.** The guard is not a prerequisite of anything, so build-only targets (`make release`, `make daemon`) are never blocked by it. `install` and `install-daemon` run it as the first recipe line, after their build finishes (also under `make -j`); `uninstall-daemon` builds nothing, so it runs first.

`nostromd remote-shells [--json]` is a plain client of the daemon socket (`terminal_remote_summary_request`; no operator trust, metadata only). It lists each open `ecs` terminal (project, environment, service, age) and exits 0 (none open; local-only shells never count), 3 (some open), 2 (no daemon is running: no socket or connection refused; the guard lets this through) or 4 (a daemon is there but gave no usable answer: timeout after 5 s, a protocol error, a reply that is not a welcome, or an old daemon that does not know the summary frame). The guard fails closed on 4 and on any other code: it needs `FORCE=1` / `NOSTROMO_FORCE_DAEMON_RESTART=1`.

A crash or a raw SIGTERM cannot be guarded: those still end the shells, and the app shows it (`terminal_closed`, `daemon_stopped` on the next start).

## Network peers (FND-1)

Every `terminal_*` client frame is `NetworkPolicy::Refused` (`src/ipc/peer.rs`): over TCP it is answered with `requires_secure_connection` before dispatch and audited with `channel: "tcp"`. Every terminal server frame is `ServerClass::LocalOnly`: a TCP peer receives none of them, not even metadata.

## Lifecycle

- Exit 0 closes a local pane (`terminal_closed`, reason `exited`). A non-zero exit leaves it `ended` with its `exit_code`, ready for `terminal_restart` (same pane, new `terminal_id`).
- `terminal_close` ends the terminal and removes the pane (reason `user_closed`): SIGHUP to the shell and its process group, SIGKILL after 2 s if the shell is still running, and SIGKILL to whatever the shell left in its group once it exits (a `nohup` job). The reader thread is then stopped even if a job that left the group still holds the tty, so the ring, the screen model and the PTY are freed with the pane. Shutdown and restart use the same path.
- **Nothing is signalled once the shell has been reaped.** Its pid may belong to another process by then. The waiter waits for the exit without reaping, then reaps under a lock; every signal takes that lock, checks the reaped flag first and only then probes with a non-reaping `waitid`. A close that lands after the reap signals nothing (a job still holding the tty is then ended only by the reader stop above).
- `~/.nostromo/daemon-terminals.json` records each terminal's identity, place and kind (no bytes). At daemon start a local record becomes `ended` with `ended_reason: "daemon_stopped"` and keeps its pane. A remote (`ecs`) record loses its pane and is reported closed in `terminal_list.closed`.
- The pane tree and that file are written one after the other, so a crash can leave them disagreeing. At start the records are checked against the tree: a record whose leaf is gone is closed with reason `pane_missing` (reported in `terminal_list.closed`, audited), and a `terminal-<8 hex>` leaf that no record claims is removed from the tree.
- The shell's environment drops the variables that would let something inside it act as the focus (`NOSTROMO_PTY_ID`, `NOSTROMO_FOCUS_TAG`, `NOSTROMO_MCP_SOCKET`, `NOSTROMO_GUARD_BIN`, `NOSTROMO_APPROVALS_DIR`, `CLAUDECODE`, …). It sets `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=Nostromo`.

## Limits

| Limit | Value | Refusal |
|---|---|---|
| Raw bytes in one `terminal_input` frame | 256 KiB | `terminal_input_too_large` |
| Input writes queued for a child that is not reading | 256 | `terminal_input_busy` |
| Input bytes queued for such a child | 1 MiB | `terminal_input_busy` |
| Terminals per focus (live or ended) | 8 | `terminal_limit_reached` |
| Terminals in the daemon | 32 | `terminal_limit_reached` |
| Terminals agents opened, per focus (live or ended) | 2 | `terminal_agent_quota_reached` |
| Terminals agents opened, in the daemon | 6 | `terminal_agent_quota_reached` |

The agent limits are lower than the general ones on purpose: an agent in a loop (or a few agents) cannot use up the user's room, and only the user can close an agent's terminal to free its quota.

Each terminal costs four threads, a replay ring of up to 4 MiB and a 10,000-row screen model, so the caps bound what a stuck or runaway client can pin. The input caps bound a stuck terminal's queue to about 1 MiB plus the one frame the writer holds. A client that needs to paste more sends it in frames of at most 256 KiB, waiting out `terminal_input_busy`.

## Output

Each terminal keeps a replay ring (at least 10,000 lines, at most 4 MiB) and a `vt100` screen model (10,000 rows), so a re-attach shows the history and the current screen, alternate screen included.

Output is coalesced. A chunk goes out at once if nothing was sent in the last 8 ms, or if input was written since the last send (keystroke echo). Otherwise it waits up to 8 ms, or until 64 KiB are waiting. When a connection's stream is full, that connection is sent no more output. It gets a fresh `terminal_replay` once the replay fits.

## Audit

`~/.nostromo/audit/terminal.jsonl` (directory `0700`, file `0600`), appended only by the daemon. It rotates at 10 MiB to `terminal-<UTC yyyymmddThhmmss>.jsonl` and keeps 12 rotated files. Events: `opened`, `closed`, `ended`, `daemon_stopped`, `restarted`, `refused`, the remote-shell and follow events above, `idle_warning`, `idle_kept_open`, `idle_closed`, plus `refusal_limit_reached` and `refusals_suppressed`. The next daemon's start writes the stop's ending: `daemon_stopped` for each local terminal that was left `ended`, and `closed` (reason `daemon_stopped`, or `pane_missing`) for each terminal whose pane is gone. A sensitive focus appears by its opaque tag, never by name. `AuditEvent` is a closed enum with no field that can hold keystrokes or output.

Refused lines are capped at 120 a minute per channel (one budget for the whole MCP channel, not one per focus), so a flood over TCP neither fills the log quickly nor silences local refusals. A peer-supplied `terminal_id` is recorded only if it is shaped like an id.

**The audit trail fails closed.** `AuditLog::open` creates the file at once, and each open checks the file can still be appended to. If it cannot (at start `nostromd` logs an error and runs with an unavailable log), `terminal_open_local` is refused with `terminal_audit_unavailable` and no process, pane or record is created. Terminals that already exist keep running.

## The Mac pane (slice 1d)

The app draws a terminal with SwiftTerm 1.18.0 (a remote Swift package pinned exactly; 1.19+ add a build-tool plugin that command-line `xcodebuild` refuses without `-skipPackagePluginValidation`). SwiftTerm is linked into the `Nostromo` app target only: `NostromoTerminalView` and `TerminalPaneHostView` are the only files that import it. `NostromoTests` compiles app sources directly and must never import SwiftTerm (`TerminalFitnessTests` asserts it), so the wire, the store and the guard are plain Swift.

- **Routing.** `DynamicFocusView.makeLeafView` sends pane ids `terminal-*` to `TerminalPaneHostView` (per window, reused across layout rebuilds like the REPL). The daemon's `pane_content` `terminal` is only a placeholder for clients that cannot attach.
- **Data flow.** `NostromodClient` decodes the `terminal_*` frames into `ServerMsg` cases; `AppStore` hands them to `TerminalSessionStore`. The store keeps the latest `TerminalInfo` per terminal, a bounded copy of each attached terminal's bytes (to start a second window's view), and reference-counts `terminal_attach`/`terminal_detach` per terminal. A view's size goes out as `terminal_resize` before its `terminal_attach`, so the replay already has the view's size. After a reconnect every terminal that still has a view is attached again.
- **Handshake.** On a connection whose `Welcome` carried an `operator_nonce`, the app sends a follow-up `Subscribe` naming topic `terminal`, capability `terminal_ui` and the nonce. Without it the daemon never honours a terminal verb from this connection.
- **Opening.** Terminal ▸ New Terminal (⌘T) asks for a shell in the key window's focus, in the focus's project directory, split below the pane that holds the keyboard (the REPL by default). That window's view takes the keyboard when the daemon reports the terminal (`opened_by_request` matches a token the window made). A terminal an agent opened has no token and never takes the keyboard.
- **Ended.** A shell that exits non-zero leaves the pane with a "[process exited with code N]" overlay and **Restart** (same pane, new `terminal_id`) and **Close**. Exit 0 closes the pane.
- **Edit ▸ Find…** (⌘F) and **Find Next** (⌘G) go to the first responder only; SwiftTerm shows its find bar. **Debug ▸ Copy terminal latency stats** copies key down to echo fed, p50 and p95 over the last 500 keys (the log also carries the line every 100 keys). The screen text is the view's accessibility value, which is how the QA script reads it.

### The synthetic-input rule

Nothing that app-control synthesised may reach a shell or change a terminal. `TerminalInputGuard` is the one call site, over approvals AP1's `SyntheticInputGate` and `HumanGesture` (there is no second gate):

- **Keystrokes, `insertText`, paste** (`NostromoTerminalView.send`/`insertText`/`paste`): refused when `SyntheticInputGate.isSynthetic(NSApp.currentEvent)`, unless this is the QA build with `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1`.
- **Controls** (the header ×, Restart and Close on the overlay, Terminal ▸ Close Terminal Pane): `HumanGesture.permit`, so a synthetic or marked event, an Accessibility press and an event from another window all do nothing. A main-menu item passes `menuSelection: true` (AppKit gives a chosen menu item the mouse event that tracked the menu, which is not in the key window); every other check still applies.
- A refused attempt sends nothing and reports `terminal_refusal_report {op, channel: "app_control"}` (at most one a second per terminal and op); the daemon audits it as `refused` in `terminal.jsonl`.
- Opening a terminal (⌘T) is not gated: it types nothing and closes nothing.

`scripts/qa/terminal-local.sh` drives the isolated QA instance through the positive scenario and the `--no-synthetic` negative case. Live QA needs an awake, unlocked display.
