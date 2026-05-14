# nostromo Phase 2 — Embedded PTY, syntect diff highlighting, and live AgentBus

## Context

`nostromo` is a Ratatui-based Rust TUI living at `~/Code/nostromo` (single-crate workspace, lib + bin). Phase 1 (scaffold + Fred and Perri views backed by external bash `--json` data sources) is merged on `main`. The repo currently builds clean on macOS Apple Silicon.

Phase 2 turns three placeholder pieces into real implementations:

1. The REPL pane in each view currently calls `launch_agent_repl` which suspends the TUI, leaves the alternate screen, and runs `claude --agent <id>` in the foreground (see `src/app.rs:124-157`). Phase 2 replaces that with an embedded PTY using `portable-pty` + `vt100` rendered as a Ratatui widget inside the REPL pane.
2. The Perri diff pane renders unified diff with naive `+`/`-`/`@@` colouring (see `src/views/perri.rs:122-185`). Phase 2 replaces that with `syntect`-based syntax-highlighted diff using the `base16-ocean.dark` theme.
3. `src/agent_bus.rs` is a 43-line stub. Phase 2 wires it to tail `~/.claude/activity.jsonl` via `notify`, parse `ActivityEvent` lines, and broadcast them to subscribers. The chrome status bar surfaces the most recent event(s).

No external ticket — this work is tracked in repo notes only. Out-of-scope work (Mother queue, native Graph/GitHub clients, nostromod daemon) is explicitly deferred to phases 3–5.

## Target

- **Repo:** `nostromo` (`~/Code/nostromo`)
- **Branch:** `feature/phase2-pty-and-bus`
- **Base:** `origin/main`

## Files to change

### Cargo

- `Cargo.toml` — add to `[dependencies]`:
  - `portable-pty = "0.8"`
  - `vt100 = "0.15"`
  - `syntect = { version = "5", default-features = false, features = ["default-fancy"] }`
  - `bytes = "1"`
  - `tokio` features `io-util` and `sync` are already enabled — leave alone.

### New files

- `src/pty/mod.rs` — module root; re-exports `PtyHost`, `PtyWidget`.
- `src/pty/host.rs` — owns the `portable_pty::MasterPty`, writer, child handle, the `vt100::Parser`, the reader task, and input-encoding helpers.
- `src/pty/widget.rs` — `PtyWidget<'a>` that walks `vt100::Screen` and emits styled cells. Implements `ratatui::widgets::Widget`.
- `src/ui/widgets/syntect_diff.rs` — `SyntectDiff` widget that takes a `&str` diff body and renders highlighted lines.
- `src/ui/widgets/syntect_cache.rs` — `SyntectCache` holding `SyntaxSet` + `Theme`; built once at startup, shared via `Arc`.
- `tests/snapshot_pty.rs` — smoke test: feed a fixed byte stream into a `vt100::Parser`, render via `PtyWidget` to a Ratatui `TestBackend`, snapshot via `insta`.

### Modified files

- `src/lib.rs` — add `pub mod pty;`.
- `src/ui/widgets/mod.rs` — add `pub mod syntect_diff; pub mod syntect_cache;` (currently exposes `relative_time` and `truncate`).
- `src/app.rs:1-157` — remove `launch_agent_repl` (lines 124-157) and the `KeyCode::Enter` drop/respawn dance (lines 86-94). Replace with: dispatch `Enter` to the active view's `on_event`, which now owns its `PtyHost`. Keep the global tab bar (Tab/BackTab/mouse-on-row-0) and quit handling (`q`, `Ctrl-C`) intact. Add `Arc<SyntectCache>` and `Arc<AgentBus>` to the constructor wiring at lines 33-40 so views receive them.
- `src/views/fred.rs:216-244` (`render_repl_placeholder`) — replace with `render_repl_pty`. Add `pty: Option<PtyHost>` field. On first `Enter` while REPL is focused, spawn `PtyHost::spawn("claude", &["--agent", "fred"], (cols, rows))`. Forward keys to `pty.send_key(k)` while REPL has focus. Render with `PtyWidget`.
- `src/views/perri.rs:122-215` — same PTY treatment for the REPL pane. Additionally, replace the `s.diff.lines()` block at `src/views/perri.rs:159-175` with a `SyntectDiff::new(&s.diff, &cache).render(inner, buf)` call. Keep stale-suffix and title logic intact.
- `src/views/agent_generic.rs` — apply the same `PtyHost` integration so Claudia/Cody/Kennedy/Mother tabs also embed PTY REPLs (one shared helper).
- `src/views/mod.rs:27-54` — extend `View` trait with optional default-impl methods:
  - `fn on_resize(&mut self, _area: Rect) {}`
  - `fn pty_focus(&self) -> bool { false }` (so the App knows whether to forward arbitrary keys to the PTY rather than treating them as nav).
- `src/agent_bus.rs` — full rewrite (see Approach §3). Keep `AgentBus::subscribe()` as the public surface; rename `AgentEvent` → `ActivityEvent` with fields `ts`, `agent`, `kind`, `summary`.
- `src/ui/chrome.rs:55-99` (`render_status_bar`) — accept an `Option<&[ActivityEvent]>` recent slice. Render the latest event as ` ⚙ {agent}: {summary} ` truncated to fit. When terminal width ≥ 140 cols, also render a right-aligned column with the last 5 events. Update `render_chrome` signature accordingly.
- `src/main.rs:1-116` — at startup, build `SyntectCache::load()?` and `AgentBus::new()`, wrap each in `Arc`, call `bus.clone().start_tail(<home>/.claude/activity.jsonl)`, pass both into `app::run`.

### Snapshot test updates

- `tests/snapshot_fred.rs` — REPL pane now renders a PTY placeholder (empty `vt100::Screen` plus prompt text "Press Enter to start"). Re-record snapshot.
- `tests/snapshot_perri.rs` — diff pane is now syntect-rendered; re-record. Run `cargo insta review` and confirm visually before accepting.

## Approach

### 1. PTY host + widget

1. **Define `PtyHost` in `src/pty/host.rs`:**
   ```rust
   pub struct PtyHost {
       master: Box<dyn portable_pty::MasterPty + Send>,
       writer: Box<dyn std::io::Write + Send>,
       child: Box<dyn portable_pty::Child + Send + Sync>,
       parser: Arc<Mutex<vt100::Parser>>,
       size: (u16, u16),
       _reader_task: tokio::task::JoinHandle<()>,
   }
   ```
2. `PtyHost::spawn(cmd: &str, args: &[&str], (cols, rows): (u16, u16))`:
   - `let pty_system = portable_pty::native_pty_system();`
   - `let pair = pty_system.openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })?;`
   - Build `CommandBuilder::new(cmd)`, `cmd.args(args)`, set `cwd` to the current process's `std::env::current_dir()`, inherit env explicitly.
   - `let child = pair.slave.spawn_command(cmd)?;` then `drop(pair.slave);`.
   - `let mut reader = pair.master.try_clone_reader()?;`
   - `let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 0)));`
   - Spawn `tokio::task::spawn_blocking` reading 4 KiB at a time; on each chunk, `parser.lock().unwrap().process(&buf[..n])`. Use a `tokio::sync::Notify` (or send `AppEvent::AgentUpdate { view_id }` via a sender given at spawn time) to wake the UI.
   - `let writer = pair.master.take_writer()?;`
3. **Resize:** `pub fn resize(&mut self, cols: u16, rows: u16)`:
   - `self.master.resize(PtySize { rows, cols, .. })?`
   - `self.parser.lock().unwrap().set_size(rows, cols)`
4. **Input encoding:** `pub fn send_key(&mut self, key: &KeyEvent)`. Map crossterm `KeyCode`:
   - `Char(c)` → UTF-8 bytes; with `KeyModifiers::CONTROL`, emit `(c as u8) & 0x1f`.
   - `Enter` → `\r`. `Backspace` → `\x7f`. `Tab` → `\t`. `Esc` → `\x1b`.
   - Arrows → `\x1b[A` / `B` / `C` / `D`. `Home`/`End`/`PageUp`/`PageDown` → standard CSI sequences.
   - Write to `self.writer` via `write_all`; ignore EWOULDBLOCK / Interrupted.
5. **Drop:** kill the child on drop (`self.child.kill().ok();`) so quitting nostromo doesn't leave orphans.
6. **`PtyWidget` in `src/pty/widget.rs`:**
   - Wraps `&'a vt100::Screen`.
   - `impl<'a> Widget for PtyWidget<'a>` — for each `(row, col)` in `area`, fetch `screen.cell(row, col)`. Translate `vt100::Color` (`Default | Idx(u8) | Rgb(r, g, b)`) → `ratatui::style::Color`. Honor bold/italic/underline/inverse/dim modifiers.
   - Render the cursor: if `!screen.hide_cursor()`, mark the cell at `screen.cursor_position()` with reverse-video.
   - Skip drawing rows beyond `area.height` and cols beyond `area.width`.
7. **Wire into views:** Each REPL-bearing view holds `pty: Option<PtyHost>`. On first `Enter` while focused on REPL, spawn the host sized to the REPL inner `Rect`. On every render, if `pty.is_some()`, lock the parser, take a `screen` snapshot, render via `PtyWidget`. On `AppEvent::Resize` or any layout change producing a different inner size, call `pty.resize(cols, rows)`.
8. **Remove foreground-suspend code** from `src/app.rs` entirely — no `disable_raw_mode` / `LeaveAlternateScreen` / `tokio::process::Command::new("claude")`. The view layer owns the PTY now.

### 2. Syntect diff highlighting

1. `SyntectCache` (`src/ui/widgets/syntect_cache.rs`):
   ```rust
   pub struct SyntectCache {
       pub syntaxes: SyntaxSet,
       pub theme: Theme,
   }
   impl SyntectCache {
       pub fn load() -> anyhow::Result<Self> {
           let syntaxes = SyntaxSet::load_defaults_newlines();
           let theme_set = ThemeSet::load_defaults();
           let theme = theme_set.themes["base16-ocean.dark"].clone();
           Ok(Self { syntaxes, theme })
       }
   }
   ```
2. Constructed once in `src/main.rs`, wrapped in `Arc<SyntectCache>`, threaded through `app::run` into `PerriView::new`.
3. `SyntectDiff` widget (`src/ui/widgets/syntect_diff.rs`):
   - Detect filename from diff `+++ b/<path>` headers; pick `SyntaxReference` via `syntaxes.find_syntax_for_file(path)`, falling back to `syntaxes.find_syntax_plain_text()`.
   - Use `syntect::easy::HighlightLines` per hunk body.
   - Convert `syntect::highlighting::Style` → `ratatui::style::Style` (`Color::Rgb(r, g, b)`) via a small helper.
   - For lines starting with `+` / `-` / `@@`, override the foreground with the existing `theme::SAGE` / `theme::RED_SWEATER` / `theme::AMBER` so the accent column survives.
4. Replace `s.diff.lines() ...` block at `src/views/perri.rs:159-175` with a single `SyntectDiff` render.
5. `cargo insta review` to re-record `tests/snapshot_perri.rs`.

### 3. AgentBus → activity.jsonl tailer

1. Define `ActivityEvent`:
   ```rust
   #[derive(Debug, Clone, serde::Deserialize)]
   pub struct ActivityEvent {
       pub ts: chrono::DateTime<chrono::Utc>,
       pub agent: String,
       pub kind: String,
       pub summary: String,
   }
   ```
2. `AgentBus`:
   ```rust
   pub struct AgentBus {
       tx: tokio::sync::broadcast::Sender<ActivityEvent>,
       recent: Arc<Mutex<VecDeque<ActivityEvent>>>, // cap 64
   }
   ```
   API: `new()`, `subscribe()`, `recent_snapshot()`, `start_tail(path: PathBuf)`.
3. `start_tail` behavior:
   - Resolve `~/.claude/activity.jsonl`; create parent dir + empty file if absent.
   - Open, seek to `SeekFrom::End(0)`, remember offset.
   - Spawn `notify::recommended_watcher` watching the file, `RecursiveMode::NonRecursive`. Use a tokio mpsc to bridge notify's std-thread callback into async.
   - On any `Modify` / `Create` event:
     - Re-open file, seek to saved offset, `BufReader::lines()` to EOF.
     - For each line, `serde_json::from_str::<ActivityEvent>(&line)`; on Ok push into `recent` (popping front past 64) and `tx.send(ev)`. On Err, `tracing::debug!("skipping malformed activity line: {e}")`.
     - Update offset to new EOF.
   - If file size shrinks below saved offset (rotation), reset offset to 0.
4. Hook into `src/main.rs` startup. Pass `Arc<AgentBus>` to `app::run`, which stores a subscriber and forwards latest snapshots into `chrome::render_status_bar`.

### 4. Build, test, snapshot

1. `cargo build --release` — must be clean, no warnings.
2. `RUSTFLAGS="-D warnings" cargo build` — passes.
3. `cargo clippy --all-targets -- -D warnings` — passes.
4. `cargo test` — re-record snapshots with `cargo insta review`; commit accepted snapshots.
5. Manual smoke: launch `nostromo`, focus Fred REPL, hit Enter, type a few characters into `claude --agent fred`, resize the terminal, confirm vt100 reflows. Append a JSON line to `~/.claude/activity.jsonl` and confirm it shows up in the status bar within ~250 ms.

## Acceptance criteria

- Pressing Enter while focused on the Fred REPL pane spawns `claude --agent fred` inside an embedded PTY rendered in that pane (no alt-screen leave, no foreground suspend). Same for Perri, Claudia, Cody, Kennedy, Mother tabs.
- Resizing the terminal calls both `master.resize()` and `parser.set_size()`; the child sees the new `WINSZ` (verifiable by running `stty size` inside the embedded shell).
- Quitting nostromo (`q` / `Ctrl-C`) kills child PTY processes — no orphans (verify with `pgrep -fa 'claude --agent'`).
- The Perri diff pane renders syntax-highlighted unified diff. Added/removed/hunk-header line accents (`+` / `-` / `@@`) remain visually distinct.
- Appending `{"ts":"2026-05-07T12:00:00Z","agent":"cody","kind":"job.start","summary":"running phase2"}` to `~/.claude/activity.jsonl` surfaces in the status bar within ~250 ms.
- `cargo build --release` completes with zero warnings.
- `RUSTFLAGS="-D warnings" cargo build` passes.
- `cargo clippy --all-targets -- -D warnings` passes.
- `cargo test` passes; updated `tests/snapshot_fred.rs` and `tests/snapshot_perri.rs` snapshots are committed; new `tests/snapshot_pty.rs` smoke test passes.
- The old `launch_agent_repl` function in `src/app.rs` is removed entirely (no dead code, no `#[allow(dead_code)]` shim).
- The PR description references "phase 2" and lists the three deliverables.

## Out of scope

- Mother job queue integration and the `mother` view's queue UI (phase 3) — `mother` view just gets a PTY like the others.
- Native Microsoft Graph and GitHub clients — keep the bash `--json` scripts in place (phase 4).
- The `nostromod` background daemon (phase 5).
- Changing the colour palette in `src/ui/theme.rs`.
- Mouse selection / clipboard inside the embedded PTY beyond simple key forwarding.
- Scrollback UI for PTY history — vt100's default scrollback is sufficient for phase 2.
- Any work on `src/mother.rs` beyond what's needed to compile.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "PTY embedding + vt100 grid translation + async reader is fiddly; touches app.rs control flow and three views."
  redd:
    model: sonnet
    effort: low
    rationale: "downgrade: re-recording two existing insta snapshots and adding one PTY smoke test against a deterministic byte stream."
  marty:
    model: sonnet
    effort: medium
    rationale: "Three views gain near-identical PTY plumbing; consolidate into shared helpers in src/pty/host.rs and View trait defaults."
  perri:
    model: sonnet
    effort: high
    rationale: "Reviewer must catch async/PTY lifecycle bugs (zombie children, missed resizes, blocking reads on the runtime) before they reach main."
```
