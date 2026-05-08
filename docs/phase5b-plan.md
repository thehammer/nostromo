# Nostromo Phase 5b — PTY detach/attach

## Context

Phase 5b builds on the `nostromd` daemon introduced in 5a. PTY ownership moves from individual TUI views into the daemon so PTYs survive TUI close/reopen. Views become PTY *clients*: they send keystrokes to the daemon and receive output + scrollback from it.

**Branch on `origin/main` after 5a has merged.**

The user ships trunk-based. 5b must land on `main` independently before 5c begins.

## Target

- **Repo:** nostromo (`~/Code/nostromo`)
- **Branch:** `feature/phase5b-pty-detach`
- **Base:** `origin/main` (after 5a merged)

## Files to change

**Protocol extensions (build on 5a):**
- `src/ipc/protocol.rs` — add new variants:
  ```rust
  // ClientMsg additions
  PtySpawn { pty_id: String, cmd: String, args: Vec<String>, cols: u16, rows: u16, cwd: Option<PathBuf>, client_tag: String },
  PtyInput  { pty_id: String, bytes: Vec<u8> },
  PtyResize { pty_id: String, cols: u16, rows: u16 },
  PtyKill   { pty_id: String },
  PtyAttach { pty_id: String },     // request scrollback replay then live stream
  PtyDetach { pty_id: String },     // stop receiving output; leave PTY running
  PtyList,

  // ServerMsg additions
  PtySpawned    { pty_id: String },
  PtyOutput     { pty_id: String, bytes: Vec<u8> },
  PtyExited     { pty_id: String, exit_code: Option<i32> },
  PtyScrollback { pty_id: String, bytes: Vec<u8> },   // dump of ring buffer at attach
  PtyAttached   { pty_id: String, cols: u16, rows: u16 },
  PtyListResp   { ptys: Vec<PtyInfo> },
  ```
  `PtyInfo { pty_id, cmd, args, alive, cols, rows, last_activity, client_tag }`.
- Bump `PROTOCOL_VERSION` to `2`. Daemon rejects clients announcing `< 2`.

**New daemon modules:**
- `src/ipc/pty_manager.rs` — owns PTY processes inside the daemon. Each `ManagedPty` holds a `portable-pty` master, writer, child, scrollback ring, and a `broadcast::Sender<Vec<u8>>` for fan-out to attached clients.
- `src/ipc/scrollback.rs` — ring buffer. Store raw bytes in a `VecDeque<Vec<u8>>` chunked by write, capped at ~2 MiB total OR ~10 000 newline boundaries (whichever first). On attach, concatenate all chunks and emit as a single `PtyScrollback` frame. Add a unit test that pushes 20 000 lines and asserts the buffer is bounded.

**New TUI module:**
- `src/pty/client.rs` (~250 lines) — `DaemonPtyClient` mirroring the public surface of `PtyHost` (`spawn`, `resize`, `send_key`, `parser: Arc<Mutex<vt100::Parser>>`, `size()`). On spawn: sends `PtySpawn`, awaits `PtySpawned`, then `PtyAttach`. Spawns a reader task feeding `PtyScrollback` then `PtyOutput` chunks into the local `vt100::Parser`. `send_key` encodes via shared `key_to_bytes` then sends `PtyInput`. `Drop` sends `PtyDetach` (NOT `PtyKill`). Explicit `kill()` method sends `PtyKill`.
- `src/pty/keys.rs` — extract `key_to_bytes` from `src/pty/host.rs` (the key→bytes encoding). Both `PtyHost` and `DaemonPtyClient` delegate to this. Add unit tests for the common key mappings.
- `src/pty/mod.rs` — add `PtyBackend` enum:
  ```rust
  pub enum PtyBackend {
      InProcess(PtyHost),
      Daemon(DaemonPtyClient),
  }
  ```
  Implement uniform methods (`resize`, `send_key`, `parser()`, `size()`) so views hold a `PtyBackend` without caring which variant.

**View trait and view refactors:**
- `src/views/mod.rs` — extend `ViewCtx` with `pty_factory: Arc<dyn PtyFactory>`:
  ```rust
  pub trait PtyFactory: Send + Sync {
      fn spawn(&self, view_tag: &str, cmd: &str, args: &[&str],
               size: (u16, u16), tx: mpsc::UnboundedSender<AppEvent>) -> Result<PtyBackend>;
      fn list_existing(&self, view_tag: &str) -> Vec<PtyInfo>;
  }
  ```
- `src/views/fred.rs` — change `pty: Option<PtyHost>` → `pty: Option<PtyBackend>`. Spawn via `ViewCtx::pty_factory`. On construction, call `pty_factory.list_existing("fred:repl")`; if a live PTY exists, reattach to it. All `pty.resize/send_key/parser` calls flow through `PtyBackend`.
- `src/views/agent_generic.rs` — same changes.
- `src/views/perri.rs` — audit: if no PTY, no edit needed.

**App wiring:**
- `src/app.rs` — construct the `PtyFactory` in `run()`:
  - If daemon connected → `DaemonPtyFactory { client: Arc<DaemonClient> }`
  - Else → `InProcessPtyFactory`
  Pass `Arc<dyn PtyFactory>` into each `ViewCtx`.
- `src/bin/nostromd.rs` — instantiate `PtyManager`, route new `ClientMsg` PTY variants to it. Per-PTY reader task feeds scrollback ring AND `broadcast::Sender`. On child exit: set `alive=false`, send `PtyExited`. Add `kill_all_on_shutdown` to SIGTERM handler.

## Approach

1. Branch off post-5a `origin/main`. Confirm 5a is merged: `git fetch origin && git log -1 origin/main`.
2. Extract `key_to_bytes` from `src/pty/host.rs` into `src/pty/keys.rs`. Update `host.rs` to delegate. Run existing tests.
3. Add new protocol variants in `src/ipc/protocol.rs`. Bump `PROTOCOL_VERSION` to 2. Update `Hello`/`Welcome` handshake to reject mismatched versions with `ServerMsg::Error`.
4. Implement `src/ipc/scrollback.rs`. Unit-test: push 20k lines, assert `< 2 MiB && newline_count <= 10_000`.
5. Implement `src/ipc/pty_manager.rs`. Reader task per PTY uses `tokio::task::spawn_blocking`. Each chunk → scrollback ring AND `output_tx.send(bytes)`. On child exit: `alive=false`, broadcast `PtyExited`. `kill_all_on_shutdown` method.
6. Wire new `ClientMsg` variants in `src/bin/nostromd.rs`. On `PtyAttach`: send `PtyAttached`, then `PtyScrollback` (full ring), then start forwarding live `PtyOutput`. Per-client subscription state: `HashMap<pty_id, broadcast::Receiver>`.
7. Implement `src/pty/client.rs`. Local `vt100::Parser` fed from `PtyOutput` chunks — existing `PtyWidget` rendering unchanged.
8. Add `PtyBackend` enum + uniform methods in `src/pty/mod.rs`.
9. Add `PtyFactory` trait. Construct in `app::run` based on daemon availability.
10. Update `FredView` and `GenericView` to use `PtyBackend`. Confirm `pty_capturing_input()` still returns `true` whenever `self.pty.is_some()`.
11. Implement reattach on view construction: call `pty_factory.list_existing(view_tag)`. If a live PTY exists, attach to it — scrollback replay populates the parser before live output begins.
12. Manual test:
    - Daemon running. Open nostromo → Fred → Enter to spawn Claude REPL. Type a few lines.
    - Quit nostromo (`Ctrl-C`). Daemon still alive; PTY still running.
    - Reopen nostromo. Fred auto-reattaches: prior output appears via scrollback replay, live keystrokes resume.
    - With daemon stopped, nostromo falls back to in-process PTYs with no behaviour change.
13. Update `README.md` daemon section with reattach behaviour.
14. Open PR titled `feat(phase5b): daemon-owned PTYs with detach/attach + scrollback`.

## Acceptance criteria

- New `tests/scrollback.rs` confirms ring is bounded at ≤ 2 MiB and ≤ 10 000 newlines.
- `cargo build --release` succeeds; `cargo test` passes.
- With daemon running: spawn Fred REPL, type, quit nostromo, reopen — prior output appears via scrollback, live keystrokes work.
- With daemon stopped: Fred REPL still spawns via in-process `PtyHost`, no behaviour change.
- `pty_capturing_input()` semantics preserved — tab switching still suppressed while PTY active.
- Killing nostromo with PTYs running does NOT kill child processes when daemon is in use (`ps` shows them alive under `nostromd`).
- Daemon SIGTERM cleanly kills all child processes (no zombies).
- A second `PtyAttach` to an already-attached PTY succeeds; prior client receives `Detach`. Single-attach-at-a-time model only.
- PR body references this plan and includes "Phase 5b of nostromo workspace replacement".

## Out of scope

- Multi-attach (round-robin) to the same PTY.
- Persisting scrollback across daemon restarts (daemon restart loses PTYs).
- Keyboard remapping or paste-bracketing changes.
- Layout changes — those are **5c**.
- Removing the in-process `PtyHost` code path (keep both for graceful degradation).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Ownership refactor across daemon, IPC protocol, and every PTY-bearing view. Reattach + scrollback replay are subtle; vt100 parser feeding order matters."
  marty:
    model: sonnet
    effort: medium
    rationale: "PtyBackend enum is the obvious consolidation point; key_to_bytes extraction must land cleanly. Real but bounded refactor surface."
  perri:
    model: sonnet
    effort: high
    rationale: "Process lifecycle, child-process leak risk, scrollback buffer bounds, and in-process fallback parity all need careful review."
  redd:
    skip: true
    rationale: "No TUI test harness; scrollback unit test added inline. Skipping per user direction."
```
