# Transcript pane phase 1 — pin Claude session id and ship a minimal text-only TranscriptReader/Widget in Perri

## Context

Nostromo's REPL views (Fred, Perri, Mother, Teri, Claudia/Cody/Kennedy via the
generic agent view) embed a `claude --dangerously-skip-permissions --agent <name>`
process via PTY and render its TUI through a vt100 parser. That faithful-but-flat
view obscures markdown, tables, code blocks, and tool calls.

Claude Code writes a live append-only JSONL session log per conversation under
`~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl`. The cwd is sanitized
by replacing `/` with `-` (e.g. `/Users/hammer/Code/nostromo` →
`-Users-hammer-Code-nostromo`). Each line is one JSON record describing user
messages, assistant content blocks, tool uses, tool results, thinking blocks,
and various meta records. We verified the file is appended to in real time
during a live session.

Claude exposes `--session-id <uuid>` so the spawner can pin the log file name.
This phase establishes the foundation for a rich transcript pane: pin the
session id at spawn, persist it, build a tailing reader that emits a typed
snapshot stream, and ship a minimal **text-only** transcript widget into one
view (Perri) behind an opt-in toggle so we can verify the wiring end-to-end
before investing in markdown/syntax rendering. Phases 2–4 layer on markdown,
tool folding, and rollout to remaining views.

No Jira ticket; tracking via internal `docs/transcript-pane-phase{1..4}.md`.

## Target
- **Repo:** nostromo
- **Branch:** feat/transcript-pane-phase1
- **Base:** origin/main

## Files to change

- `Cargo.toml` — no new deps in phase 1 (notify, uuid, serde_json, tokio
  already present). Confirm `uuid` has the `v4` feature (it does).
- `src/sessions.rs:29-34` — extend `SessionEntry` with
  `pub session_id: Option<String>` (default `None` on deserialize for back-compat
  with existing sessions.toml entries). Bump `CURRENT_VERSION` from 1 to 2 and
  add a v1→v2 migration in `load_inner` that accepts v1 files by treating
  `session_id` as `None`. Update the `record` signature to take
  `session_id: Option<String>` (callers pass `Some(uuid_string)` going forward).
- `src/views/perri.rs:441-460` — when spawning a fresh PTY: generate
  `let sid = uuid::Uuid::new_v4().to_string();`, pass
  `&["--dangerously-skip-permissions", "--agent", "perri", "--session-id", &sid]`,
  and call `store.record(PERRI_PTY_TAG, "claude", &args, cwd, Some(sid.clone()))`.
  Also store the sid on `PerriView` (`current_session_id: Option<String>`) so the
  transcript reader can attach to it.
- `src/views/perri.rs:78-96` — when auto-respawning from `SessionStore`, reuse
  the persisted `entry.session_id` if present; if absent (legacy session), call
  the new `transcript::find_latest_session_id_for_cwd(&cwd)` helper to pick the
  newest jsonl in the project dir as a fallback.
- `src/views/perri.rs:125-142` — extend `try_reattach` to additionally look up
  the session id from `SessionStore` (the daemon doesn't know it) and store it
  on the view.
- `src/transcript/mod.rs` — **new module**, declared from `src/lib.rs`. Holds the
  reader, types, and path helpers.
- `src/transcript/path.rs` — **new**. `pub fn jsonl_path(cwd: &Path, session_id: &str) -> PathBuf`
  and `pub fn project_dir(cwd: &Path) -> PathBuf`. Implements the cwd-sanitization
  rule (`/` → `-`, prepended with `-`, joined under `~/.claude/projects/`).
  Also `pub fn find_latest_session_id_for_cwd(cwd: &Path) -> Option<String>` that
  scans the project dir, returns the stem of the most-recently-modified `*.jsonl`.
- `src/transcript/record.rs` — **new**. Serde types for the JSONL records we
  care about. Use `#[serde(tag = "type")]` on an enum `Record` with variants
  `User`, `Assistant`, and a catch-all `Other(serde_json::Value)` for meta
  records (`file-history-snapshot`, `agent-setting`, `permission-mode`,
  `attachment`, `last-prompt`, etc. — filter these out). Inside `Assistant`,
  parse `message.content` as `Vec<ContentBlock>` where `ContentBlock` is an
  internally tagged enum over `Text { text }`, `Thinking { thinking, signature }`,
  `ToolUse { id, name, input }`, `ToolResult { tool_use_id, content }`.
- `src/transcript/reader.rs` — **new**. `pub struct TranscriptReader` with:
  - `pub fn spawn(cwd: PathBuf, session_id: String) -> (Self, watch::Receiver<TranscriptSnapshot>)`
  - Internally spawns a tokio task that:
    1. Computes the path via `path::jsonl_path`.
    2. Opens the file (create-watching with `notify` if missing; once it exists,
       open it read-only and seek to start).
    3. Reads complete lines, parses each via `serde_json::from_str::<Record>`
       (skip lines that fail to parse with a `tracing::trace!`).
    4. Appends decoded `TranscriptEntry` values to an internal `Vec`, publishes
       a fresh `TranscriptSnapshot { entries: Arc<Vec<TranscriptEntry>>, path,
       session_id }` on the watch channel.
    5. Uses `notify::RecommendedWatcher` (already a dep) for fs events; falls
       back to a 500ms tokio polling loop if the watcher fails to install
       (`tracing::warn!` and continue — never panic the task).
    6. On EOF, parks until notify fires `Modify` for the file, then resumes.
       Tracks byte offset across reads to avoid re-parsing.
    7. Exposes `shutdown()` via a `tokio::sync::oneshot` stored on the struct.
- `src/transcript/snapshot.rs` — **new**. `pub enum TranscriptEntry { UserMessage(String),
  AssistantText(String), Thinking(String), ToolUse { name: String, input:
  serde_json::Value }, ToolResult { tool_use_id: String, content: String },
  TurnEnd }`. `pub struct TranscriptSnapshot { pub entries: Arc<Vec<TranscriptEntry>>,
  pub path: PathBuf, pub session_id: String }`.
- `src/ui/widgets/transcript.rs` — **new**. `pub struct TranscriptWidget<'a> {
  snapshot: &'a TranscriptSnapshot, scroll: u16 }` with `Widget` impl that
  renders each entry as plain lines with a colour-coded prefix
  (`> ` user / `« ` assistant / `· ` thinking / `⚙ tool:<name>` / `↳ result`).
  No markdown parsing yet. Wrap long lines. Bottom-stick by default; scrollable
  with PageUp/PageDown/`g`/`G` when the host view forwards them.
  Export from `src/ui/widgets/mod.rs`.
- `src/views/perri.rs` — add:
  - `transcript: Option<TranscriptReader>` and
    `transcript_rx: Option<watch::Receiver<TranscriptSnapshot>>` fields.
  - `transcript_visible: bool` (default `false` — opt-in flag).
  - Toggle key: `Ctrl+T` when the PTY is **not capturing** (i.e. in nav mode),
    flips `transcript_visible`. While visible, render the transcript widget
    in place of the diff pane (top-right column). The diff pane returns when
    toggled off.
  - When the PTY is spawned (or reattached) with a known sid, lazily start the
    `TranscriptReader` on first `Ctrl+T`. Tear it down (drop the reader) when
    the PTY exits.
- `src/lib.rs` — `pub mod transcript;` registration.
- `tests/transcript_parse.rs` — **new** integration test file. Fixture-based
  parsing tests (see below).
- `tests/fixtures/transcript/*.jsonl` — **new** scrubbed fixtures (3-5 lines
  each): one with a user+assistant turn containing text and a tool_use, one
  with thinking, one with meta records that should be filtered.

## Approach

1. **Add the transcript module skeleton.**
   - Create `src/transcript/{mod.rs,path.rs,record.rs,reader.rs,snapshot.rs}`.
   - Wire `pub mod transcript;` in `src/lib.rs`.
   - Implement `path::project_dir` and `path::jsonl_path` exactly: take
     `cwd.to_string_lossy()`, replace `/` with `-`, prepend nothing extra
     (the leading `/` becomes a leading `-` automatically). Join under
     `dirs_next::home_dir() / ".claude" / "projects" / <sanitized> /
     "<session_id>.jsonl"`.
   - Implement `find_latest_session_id_for_cwd` using `std::fs::read_dir`,
     filtering `.jsonl`, sorted by `modified()` descending.
   - Unit tests inline in `path.rs`: known cwd → known sanitized dir name.

2. **Define record types in `record.rs`.**
   - `Record` enum tagged on `"type"`. Use `#[serde(other)]` on a catch-all
     `Other` variant. Variants:
     - `User { message: UserMessage, uuid: String, timestamp: String }`
     - `Assistant { message: AssistantMessage, uuid: String, timestamp: String }`
     - `Other` (untagged catch-all so unknown record types do not error).
   - `AssistantMessage` deserializes `content` as `Vec<ContentBlock>`.
   - `UserMessage.content` is either a string or a `Vec<ContentBlock>` — model
     it as `#[serde(untagged)] enum UserContent { Text(String), Blocks(Vec<ContentBlock>) }`.
   - `ContentBlock` internally tagged on `"type"` over `Text`, `Thinking`,
     `ToolUse`, `ToolResult`. Use `#[serde(deny_unknown_fields = false)]` so
     forward-compat with new fields doesn't break parsing.
   - Unit tests: parse the fixtures and assert the decoded shape.

3. **Build the reader in `reader.rs`.**
   - `TranscriptReader::spawn(cwd, session_id)` returns `(Self, watch::Receiver<TranscriptSnapshot>)`.
   - Use `tokio::fs::File` + `tokio::io::AsyncBufReadExt::lines()`. Track a
     byte cursor; on `Modify` events, reopen if needed and continue from cursor.
   - Use `notify::recommended_watcher` on the file's parent directory (the
     file may not yet exist when we start). Filter events for our target path.
   - Translate each `Record` into 0..N `TranscriptEntry` values:
     - `User.message` → one `UserMessage(text)` (concatenate text blocks).
     - `Assistant.message.content` → one entry per block: `AssistantText`,
       `Thinking`, `ToolUse`, `ToolResult` as appropriate. Emit `TurnEnd` after
       each assistant record whose `stop_reason` is non-null (best-effort —
       used by the widget to draw a separator).
     - `Other` → skip.
   - Wrap the accumulator in `Arc<Vec<...>>` and clone-on-push? Simpler: keep
     `Vec` private to the task, publish `Arc::new(vec.clone())` snapshots on
     each batch. Snapshots are cheap because entries are small (strings/values).
     If size becomes a concern in phase 3, switch to `im::Vector` — out of scope
     for phase 1.
   - On task error (file vanished, parent dir unreadable), log and continue
     polling at 1s; do not propagate panics.

4. **Pin session id at spawn.**
   - In `src/views/perri.rs` `KeyCode::Enter` handler, generate a UUID v4,
     build the args slice including `--session-id <sid>`, spawn, and persist
     via `store.record(...)` with the sid.
   - In `PerriView::new` auto-respawn, prefer `entry.session_id`; if `None`,
     use `find_latest_session_id_for_cwd(&cwd).unwrap_or_else(generate_new)` so
     legacy sessions still attach somewhere reasonable. Log which path was taken.
   - In `try_reattach`, look up the session id from `SessionStore` after a
     successful attach; store on the view for later transcript bring-up.

5. **Migrate the session store.**
   - Bump `CURRENT_VERSION` to 2.
   - In `load_inner`, if `file.version == 1`, accept it and treat all entries as
     having `session_id: None`. If `file.version > CURRENT_VERSION`, bail as today.
   - `SessionEntry::session_id` is `#[serde(default)] pub session_id: Option<String>`.
   - Update the existing tests in `src/sessions.rs:140-220` to construct entries
     with `session_id: None` (or `Some("...")` where it matters), and add one new
     test that round-trips a v1 file (write a literal v1 toml string, load,
     verify entries appear with `session_id: None`).

6. **Build the minimal widget.**
   - `TranscriptWidget` renders entries top-to-bottom; bottom-sticks unless the
     host view's `transcript_scroll > 0`. Use ratatui `Paragraph` with manual
     line splitting and `Wrap { trim: false }`. Colour-code prefixes via
     `theme::*` consts.
   - For phase 1, `AssistantText` is rendered as raw text (markdown shows
     through as `**bold**` etc. — that's expected; phase 2 fixes it).
   - `ToolUse` renders one line: `⚙ <name> ` plus the first 60 chars of
     `serde_json::to_string(&input)`. No expansion yet.
   - `Thinking` is rendered dimmed but not hidden in phase 1 (toggle lands in
     phase 3).

7. **Wire into Perri.**
   - Add the fields described above.
   - Layout: when `transcript_visible`, replace the top-right diff column with
     the transcript widget (do not disturb the queue or REPL panes). When
     hidden (default), the existing layout is unchanged.
   - Forward PageUp/PageDown/`g`/`G`/`Home`/`End` to the transcript when
     visible **and** the PTY is not capturing. While capturing, those keys
     still go to the PTY (current behaviour).
   - On PTY exit (the existing PTY-exit path that clears `self.pty`), drop the
     reader and the receiver.

8. **Tests.**
   - `tests/transcript_parse.rs`:
     - Load `tests/fixtures/transcript/basic.jsonl`, decode each line via
       `Record`, run through the reader's record-to-entries translation,
       assert exact `Vec<TranscriptEntry>` shape.
     - Load `tests/fixtures/transcript/meta-only.jsonl` (file-history-snapshot,
       agent-setting, permission-mode) — assert zero `TranscriptEntry`.
     - Load `tests/fixtures/transcript/thinking.jsonl` — assert `Thinking`
       entry decoded and ordered correctly relative to surrounding text.
   - Inline unit test in `path.rs`: `jsonl_path(Path::new("/Users/hammer/Code/nostromo"), "abcd")`
     → ends with `.claude/projects/-Users-hammer-Code-nostromo/abcd.jsonl`.
   - Integration test in `tests/transcript_tail.rs`:
     1. `tempdir()` for `HOME`, override via env or by writing directly to the
        path the reader computes (path helper takes cwd, so just point cwd at
        the tempdir).
     2. Spawn `TranscriptReader::spawn(tempdir, "test-sid")`.
     3. Write three JSONL records to the target path with a 50ms delay between.
     4. Assert the watch receiver fires and the final snapshot contains the
        decoded entries in order. Use `tokio::time::timeout(Duration::from_secs(5), ...)`
        on each `changed().await`.
   - Run `cargo test --all` and `cargo clippy --all-targets -- -D warnings`.

## Acceptance criteria

- `cargo test --all` passes, including the new parsing and tailing tests.
- `cargo clippy --all-targets -- -D warnings` passes.
- Manually: open Perri, press Enter to spawn a fresh REPL, send a message,
  press `Ctrl+T` (in nav mode) — a transcript pane appears showing the live
  user+assistant exchange. Press `Ctrl+T` again to hide.
- Manually: kill Nostromo, restart, reattach is honoured, `Ctrl+T` still works
  against the previously-pinned session id (read from `sessions.toml`).
- `~/.nostromo/sessions.toml` shows `version = 2` and the Perri entry has a
  `session_id` field.
- Existing v1 `sessions.toml` files load cleanly (legacy entries get
  `session_id = None` and fall back to newest-jsonl on reattach).
- Branch is `feat/transcript-pane-phase1`. PR body mentions this plan file
  (`docs/transcript-pane-phase1.md`) and explicitly states "phase 1 of 4 —
  text-only transcript, Perri only, opt-in via Ctrl+T."

## Out of scope

- Markdown parsing, syntax highlighting in code blocks, table rendering
  (phase 2).
- Tool-call folding, thinking-block toggle, selectable text (phase 3).
- Rollout to Fred / Mother / Teri / Claudia / Cody / Kennedy (phase 4).
- Replacing the PTY view — transcript is strictly additive and read-only.
- Daemon-mode awareness: the daemon doesn't need to know about the session id
  beyond passing the args through; the view persists/reads the sid via
  `SessionStore`.
- Backfilling session ids onto already-running daemon PTYs that were spawned
  before this change — they keep working without a transcript pane until the
  user restarts the REPL.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Cross-cutting changes (session store schema bump, new module tree, view integration, async file-tail). Correctness of the watcher and migration matters."
  redd:
    model: sonnet
    effort: high
    rationale: "First tests of the tail loop and JSONL parser; fixtures-based suite must be solid since later phases build on it."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor sweep over new module boundaries; nothing exotic."
  perri:
    model: sonnet
    effort: high
    rationale: "Foundational phase — bugs here cascade into phases 2-4. Reviewer should scrutinize the watcher, migration, and snapshot publishing."
```
