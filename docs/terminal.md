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

A terminal leaf's pane id is `terminal-<8 hex>`. The daemon also sends `pane_content` with `kind: "terminal"` (`terminal_id, label`, `environment` only for a remote shell) so a client that cannot attach can show a placeholder.

## Remote shells: request, confirm, connect (slice 2a)

An agent can **ask** for a shell on a remote ECS service; only a human click on the verified app **opens** one. The agent can never type into it (see `docs/production-shell-guard.md`: the `ecs_*` shell functions, `aws ecs execute-command` and tmux input into a remote pane stay blocked for agents; the request tool is the one open path, and it opens nothing by itself).

**Vocabulary.** The daemon reads the carefeed layer's ECS data as data, afresh on every request and never cached: `config.json` (clusters, services, regions, shell commands), `~/.claude/ecs-local.json` (the user's profiles) and the three `declare -A ECS_{ENV,SERVICE,PROJECT}_ALIASES` tables of `ecs.sh`, scanned as **text** with a strict regex and never sourced or run (a block that holds anything but `[word]="word"` entries gives no aliases, with a warning). Paths: `[terminal] ecs_config`, `ecs_local`, `ecs_aliases_script` in `~/.config/nostromo/config.toml`; defaults are under `~/.claude/layers/carefeed/lib/services/ecs/` (then `~/.claude/lib/services/ecs/`). Resolution is lowercase, then alias, then validation of each level (project, environment, service, shell type); a word outside the vocabulary is an `invalid_target` that lists what is valid. An environment with no `regions` entry is not offered. A profile that is missing or still `CONFIGURE_ME` resolves to none. No `config.json` means remote shells are not configured.

**Flow** (`src/terminal/remote_request.rs`):

1. Resolve the four words. An unknown word returns at once; no one is asked.
2. Only operator connections that sent `capabilities: ["remote_shell_confirm"]` in their `Subscribe` can be asked. None: `no_operator` at once. A verified app that does not declare the capability, a TCP client that renders decisions and any other local process do not count.
3. At most one request waits at a time (`request_pending`).
4. `remote_shell_confirm_request` goes to those connections and no one else.
5. The daemon waits (300 s by default, clamped to 10-600 s) for `remote_shell_answer {decision: connect|cancel|dismiss}` from the operator app (`OperatorCap`).
6. Only after Connect is the launcher called (`RemoteLauncher`; this daemon's is `UnavailableLauncher`, which fails with `not_available`, until the real launcher lands). Before that no process, pane or terminal exists.
7. `remote_shell_resolved` goes to the same connections: `connected`, `cancelled`, `dismissed`, `timed_out` or `connect_failed` (with `reason` and `remedy`).
8. Every step is audited.

If the agent's MCP connection closes while the request waits, the request is abandoned: the sheet is closed (`remote_shell_resolved` `cancelled`, `reason: "requester_gone"`) and the slot is freed.

| Client → daemon | Fields |
|---|---|
| `remote_shell_targets_request` | none; any local peer |
| `remote_shell_open`* | `tag, project, environment, service, shell_type` (the user's own request; same confirm flow with `requested_by: {kind: "user"}`; failures before the sheet arrive as `terminal_refused {op: "remote_open", code}`) |
| `remote_shell_answer`* | `request_id, decision, invite_follow?` (parsed and audited only; honoured by the follow slice) |

| Daemon → client | Routing | Fields |
|---|---|---|
| `remote_shell_targets` | targeted | `configured, problem?, projects: [{name, default_service?, environments: [{name, services}]}], shell_types` (no profiles, clusters or accounts) |
| `remote_shell_confirm_request` | targeted to operator connections with `remote_shell_confirm` | `request_id, tag?, target, requested_by: {kind, tag?, agent?}, reason?, expires_at` |
| `remote_shell_resolved` | the same connections | `request_id, outcome, reason?, remedy?` |

`remote_shell_open` and `remote_shell_answer` from anyone but the verified app (even a process claiming `client_kind: "mac_app"`) get `terminal_refused {op: "control", code: "terminal_control_forbidden"}` and an audited `refused`; the request stays pending. Over TCP they are refused by FND-1 like every terminal frame. All three server frames are `LocalOnly` and never broadcast.

Audit events (`terminal.jsonl`): `remote_requested {tag, requested_by, target, reason (200 chars at most)}`, `confirm_outcome {tag, target, outcome: connect|cancelled|dismissed|timed_out|abandoned|no_operator|request_pending, invite_follow?}`, `connect_started`, `connected {terminal_id, pane_id, tag, kind, target}`, `connect_failed {reason_code}`. `no_operator` and `request_pending` lines share the per-channel refusal budget. No command, keystroke or output text is ever written.

MCP tools: `nostromo.list_remote_shell_targets` and `nostromo.request_remote_shell` (`docs/mcp/tools.md`).

## Agent follow (slice 3b)

A focus follows a terminal only when the user invites it. Output the terminal produces afterwards is delivered into the follower's conversation without any user action (`src/terminal/follow/manager.rs`).

| Client → daemon | Fields |
|---|---|
| `terminal_follow_invite`* | `terminal_id, follower_tag, include_screen?` (needs the connection's `terminal_follow_ui` capability, else `terminal_follow_ui_required`) |
| `terminal_follow_stop`* | `terminal_id` |
| `terminal_follow_resume`* | `terminal_id` (only a paused follow) |

Refusal codes: `terminal_control_forbidden` (not the operator app; audited), `unknown_terminal`, `follower_not_running`, `not_followed`, `not_paused`. `TerminalInfo.follower` is `{tag, paused, pause_reason?}` while a focus follows; each change is broadcast as `terminal_state`.

- **One follower per terminal.** Inviting another focus moves the invitation: the previous follower is told it stopped (`moved_to <tag>`).
- **Only output after the invite** is delivered, unless `include_screen`: then the visible screen goes first, in the same message as the `started` notice.
- **The pump.** A reader hook queues each chunk for the follow's task, which feeds the line assembler and asks the delivery policy every 100 ms: settled output (800 ms quiet, 200 ms at a prompt) or sustained output (at most every 10 s) is redacted, capped (200 lines / 16 KiB, head and tail) and written as `<nostromo-terminal-output terminal_id pane kind lines omitted redactions>` with a fixed advisory line. A full-screen program is delivered as a screen snapshot (`kind="screen"`). `pane` is `local shell in <dir>` or the remote shell's label. Flooding pauses the follow (`too_much_output`, `too_many_deliveries`) until `terminal_follow_resume`; what arrived while paused is never delivered.
- **Into the conversation** (`SessionManager::inject`): an idle session is written to at once and starts a turn. While a turn runs, deliveries and notices wait in the queue and are combined into one message (48 KiB at most; middle deliveries are dropped with `[… K earlier deliveries omitted …]`). A user's queued message is never combined with anything. The echoed message opens a turn whose `origin` lists each delivery (`Turn.origin`, read from the text, so a reloaded transcript has it too).
- **Notices** (`<nostromo-terminal-follow event reason?/>` plus a sentence): `started`, `paused`, `resumed`, `stopped` with `user_stopped`, `moved_to <tag>`, `pane_closed`, `terminal_restarted`, `app_closed`.
- **Ends** when the user stops it (output not yet delivered, buffered or still queued, is discarded), the pane closes or the terminal is restarted, the follower's session stops, restarts, starts a new session, crash-loops or its focus is removed (no notice), or the last operator-app connection goes. Nothing is persisted: a new daemon follows nothing.

Audit events: `follow_invited {follower, include_screen, via}`, `follow_stopped {follower, reason}`, `follow_paused {follower, reason}`, `follow_resumed {follower}`, `delivery {follower, kind, lines, bytes, redactions, truncated}`. Counts and sizes only.

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

`~/.nostromo/audit/terminal.jsonl` (directory `0700`, file `0600`), appended only by the daemon. It rotates at 10 MiB to `terminal-<UTC yyyymmddThhmmss>.jsonl` and keeps 12 rotated files. Events: `opened`, `closed`, `ended`, `daemon_stopped`, `restarted`, `refused`, the remote-shell and follow events above, plus `refusal_limit_reached` and `refusals_suppressed`. The next daemon's start writes the stop's ending: `daemon_stopped` for each local terminal that was left `ended`, and `closed` (reason `daemon_stopped`, or `pane_missing`) for each terminal whose pane is gone. A sensitive focus appears by its opaque tag, never by name. `AuditEvent` is a closed enum with no field that can hold keystrokes or output.

Refused lines are capped at 120 a minute per channel (one budget for the whole MCP channel, not one per focus), so a flood over TCP neither fills the log quickly nor silences local refusals. A peer-supplied `terminal_id` is recorded only if it is shaped like an id.

**The audit trail fails closed.** `AuditLog::open` creates the file at once, and each open checks the file can still be appended to. If it cannot (at start `nostromd` logs an error and runs with an unavailable log), `terminal_open_local` is refused with `terminal_audit_unavailable` and no process, pane or record is created. Terminals that already exist keep running.
