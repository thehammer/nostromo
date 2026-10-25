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

`~/.nostromo/audit/terminal.jsonl` (directory `0700`, file `0600`), appended only by the daemon. It rotates at 10 MiB to `terminal-<UTC yyyymmddThhmmss>.jsonl` and keeps 12 rotated files. Events: `opened`, `closed`, `ended`, `daemon_stopped`, `restarted`, `refused`, plus `refusal_limit_reached` and `refusals_suppressed`. The next daemon's start writes the stop's ending: `daemon_stopped` for each local terminal that was left `ended`, and `closed` (reason `daemon_stopped`, or `pane_missing`) for each terminal whose pane is gone. A sensitive focus appears by its opaque tag, never by name. `AuditEvent` is a closed enum with no field that can hold keystrokes or output.

Refused lines are capped at 120 a minute per channel (one budget for the whole MCP channel, not one per focus), so a flood over TCP neither fills the log quickly nor silences local refusals. A peer-supplied `terminal_id` is recorded only if it is shaped like an id.

**The audit trail fails closed.** `AuditLog::open` creates the file at once, and each open checks the file can still be appended to. If it cannot (at start `nostromd` logs an error and runs with an unavailable log), `terminal_open_local` is refused with `terminal_audit_unavailable` and no process, pane or record is created. Terminals that already exist keep running.
