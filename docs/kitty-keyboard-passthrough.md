# Pass kitty keyboard protocol through Nostromo PTYs and fix dim attribute rendering

## Context

Nostromo runs Claude Code (and other terminal apps) inside vt100-parsed PTY views
(Fred, Perri, Claudia, Mother, Teri, agent_generic). Claude Code's inline-suggestion
feature shows a dim ghost of a suggested next message; in a native Ghostty terminal,
pressing Enter on that suggestion accepts and submits it. Inside Nostromo neither
behavior works today: the suggestion is not visually dim, and Enter submits the
buffer rather than accepting the suggestion. The user's current workaround is
Tab-then-Enter, which is annoying.

The cause is already diagnosed. Claude detects `TERM_PROGRAM=ghostty` and pushes
the **kitty keyboard protocol** (`\x1b[>Nu`) onto the terminal at startup, then
expects key events encoded in kitty form (e.g. Enter as `\x1b[13u`). Nostromo's
PTY layer absorbs the push escape but does not propagate kitty encoding to keys
written into the inner PTY — `src/pty/keys.rs` always emits the legacy bytes
(`\r` for Enter), so Claude's "Enter-accepts-suggestion" branch never fires.

Nostromo recently enabled kitty mode on the **outer** terminal in `src/main.rs`
(`PushKeyboardEnhancementFlags`), so crossterm now decodes the rich sequences.
This change extends that into the inner PTYs: track per-PTY kitty state by
parsing PTY output for push/pop/replace escapes, then encode outgoing key events
in kitty form when active.

Secondary: audit `src/pty/widget.rs`'s vt100→ratatui style mapping and add the
`dim()` → `Modifier::DIM` mapping if missing (currently bold/italic/underline/
inverse are mapped but `dim()` is not — see `build_style` at
`src/pty/widget.rs:110-134`).

No Jira ticket.

## Target

- **Repo:** nostromo
- **Branch:** `feat/kitty-keyboard-passthrough`
- **Base:** `origin/main`

## Files to change

- `src/pty/kitty.rs` — **new.** `KittyFlagsTracker` (incremental parser that
  consumes a PTY byte stream and maintains the flag stack) plus
  `key_to_bytes_kitty(&KeyEvent, flags: u32) -> Option<Vec<u8>>`. Model the
  parser closely on `src/pty/altscreen.rs` — same `pending: Vec<u8>` partial-
  sequence handling, but recognize `\x1b[>Nu` (push), `\x1b[<u` (pop, no
  numeric param), `\x1b[=Nu` (replace), and `\x1b[?u` (query — pass through).
  Expose a shared-state handle: `Arc<AtomicU32>` of current top-of-stack flags
  (0 = legacy). The tracker keeps the stack internally; the atomic mirrors
  the top so the writer side can read it lock-free.
- `src/pty/keys.rs` — keep the existing `key_to_bytes` as the legacy encoder
  (unchanged behavior, all existing tests stay green). Add a wrapper
  `key_to_bytes_for(&KeyEvent, kitty_flags: u32) -> Option<Vec<u8>>` that
  dispatches: if `kitty_flags == 0`, call `key_to_bytes`; otherwise call the
  new `kitty::key_to_bytes_kitty`. Update the two call sites
  (`src/pty/host.rs:122` and `src/pty/client.rs:173`) to use the dispatcher.
- `src/pty/mod.rs` — declare `pub mod kitty;`.
- `src/pty/host.rs` — at line ~63, alongside `AltScreenFilter`, instantiate
  `KittyFlagsTracker` and feed each chunk through it **before** (or in
  parallel with) the altscreen filter. Store the tracker's
  `Arc<AtomicU32>` on `PtyHost` and read it in `send_key` (line ~121).
- `src/pty/client.rs` — same treatment in `run_output_loop`
  (`src/pty/client.rs:206-242`). Each `DaemonPtyClient` owns its own
  `KittyFlagsTracker` and `Arc<AtomicU32>`; `send_key` (line ~172) reads
  the atomic. Rationale: we encode client-side because `key_to_bytes`
  already runs there, and the client sees the full output stream via
  `PtyOutput`/`PtyScrollback` (the daemon does not need to know about
  kitty mode at all — `PtyInput` carries raw bytes).
- `src/pty/widget.rs` — at `build_style` (line ~110), add:
  ```rust
  if cell.dim() {
      style = style.add_modifier(Modifier::DIM);
  }
  ```
  Verify `vt100::Cell` exposes a `dim()` method before relying on it; if
  the method has a different name (e.g. `faint()`), use that. If vt100
  doesn't expose dim at all, document the gap in a comment and leave the
  primary work intact — do not block the kitty change on this.
- `src/pty/altscreen.rs` — **no changes**; referenced as template only.

## Approach

1. **Read the template.** Open `src/pty/altscreen.rs` end to end. The new
   `KittyFlagsTracker::process` follows the same shape: merge `pending` + new
   chunk, iterate, on ESC try to match a known sequence, on partial match at
   end-of-buffer stash into `pending` and return.
2. **Define the kitty escape sequences to recognize:**
   - `\x1b[>Nu` — push flags. `N` is one or more decimal digits, value
     parsed as `u32`. Empty (`\x1b[>u`) means push 0.
   - `\x1b[<u` — pop one level. No numeric param.
   - `\x1b[=Nu` — replace top-of-stack with `N` (decimal). Empty = 0.
   - `\x1b[?u` — query current flags. Pass through (the inner app didn't
     send it; if it did, the daemon shouldn't answer). Do not consume.
   Notably these all end in lowercase `u`; the differentiator is the byte
   after `\x1b[`: `>`, `<`, `=`, or `?`. Stop scanning a candidate as soon
   as you see a byte that's not a digit and not the terminating `u`.
3. **Stack semantics.** Maintain `stack: Vec<u32>` inside the tracker.
   `push(n)` appends. `pop` removes the last element if any. `replace(n)`
   overwrites the last element (or pushes if empty). After every mutation
   write `*stack.last().unwrap_or(&0)` into the shared `AtomicU32` with
   `Ordering::Relaxed` (a single-writer/multi-reader pattern; `Relaxed` is
   sufficient because the writer side will eventually observe the update).
4. **Pass-through, don't strip.** Unlike `AltScreenFilter`, the kitty
   sequences should be **passed through unchanged** to vt100 — vt100 will
   simply ignore them. Tracker's `process` returns the chunk verbatim (or
   does nothing and exposes `feed(&[u8])`; pick the cleaner API). The vt100
   parser must still see the full stream.
5. **Kitty key encoder.** Implement `key_to_bytes_kitty` in `src/pty/kitty.rs`:
   - Map modifiers to the kitty modifier bitmask + 1 baseline:
     `shift=1, alt=2, ctrl=4, super=8`; the protocol expects `mods = (bits) + 1`,
     so unmodified = 1 and is omitted. Compute `mods` from `KeyModifiers`.
   - Functional key codes (kitty "Functional key encoding"):
     - Enter = 13, Tab = 9, Backspace = 127, Escape = 27
     - F1–F12: 57364–57375 (kitty's CSI-u functional codes)
     - Arrows stay as CSI letter form with the modifier param when mods > 1:
       Up `\x1b[A` / `\x1b[1;<mods>A`; same for B/C/D, H (Home), F (End).
     - PageUp/PageDown/Insert/Delete: keep tilde form, insert modifier:
       `\x1b[5;<mods>~` etc.
   - Letter/char keys: `\x1b[<codepoint>;<mods>u` when mods > 1 (i.e. Ctrl/Alt/
     Super present). Plain unmodified printable chars stay as UTF-8 (no escape)
     so typing 'a' still produces `a`, not `\x1b[97u` — Claude works either way
     but UTF-8 is correct per kitty spec for the "disambiguate" flag tier.
     Shift alone on a printable char also stays as the shifted char (not
     `;2u`) — same reason.
   - Output format spec:
     - Final byte is always `u` for functional/letter codes, or `A`/`B`/`C`/`D`/
       `H`/`F` for arrows/home/end, or `~` for tilde-suffixed keys.
     - Param string is `<code>` or `<code>;<mods>`. Omit `;mods` when mods == 1.
   - Specifically required to fix the bug:
     - Enter no mods → `\x1b[13u`
     - Shift+Enter → `\x1b[13;2u`
     - Ctrl+Enter → `\x1b[13;5u`
     - Ctrl+a → `\x1b[97;5u`
     - F1 → `\x1b[57364u`
     - Shift+Up → `\x1b[1;2A`
6. **Thread state through host.** In `PtyHost::spawn`
   (`src/pty/host.rs:29-101`): create `let kitty = KittyFlagsTracker::new();`
   before the reader task, take `let kitty_flags = kitty.flags();` (returns
   `Arc<AtomicU32>`), move the tracker into the reader closure. In the read
   loop, call `kitty.process(&buf[..n])` (or `kitty.feed(&buf[..n])`) on the
   raw chunk before/after the altscreen filter — either is fine since the
   tracker doesn't mutate bytes. Store `kitty_flags` on `PtyHost`. In
   `send_key` (line ~121), read `let flags = self.kitty_flags.load(Relaxed);`
   and call `key_to_bytes_for(key, flags)`.
7. **Thread state through client.** In `DaemonPtyClient::spawn_new`
   (`src/pty/client.rs:51-112`) and `attach_existing`
   (lines 118-156): same pattern. Create the tracker, take the atomic, store
   it on the struct, move the tracker into the `run_output_loop` task.
   Modify `run_output_loop` signature to take the tracker (or its `feed` fn).
   In `send_key` (line ~172), read the atomic and dispatch via
   `key_to_bytes_for`.
8. **Dim mapping.** In `src/pty/widget.rs::build_style` (lines 110-134),
   after the `inverse()` block, check whether `cell` exposes `dim()` or
   equivalent. Search the local `vt100` crate version's `Cell` API
   (`cargo doc --open` is overkill; `rg "pub fn (dim|faint)" ~/.cargo/registry/src` or
   `grep -r "fn dim" target/doc 2>/dev/null` will find it). If found, add the
   modifier; if not, add a `// TODO: vt100 crate exposes no dim accessor`
   comment and proceed.
9. **Unit tests for the flags parser** (in `src/pty/kitty.rs` `#[cfg(test)]`):
   - Push 1, then read flags → 1.
   - Push 1, push 5, read → 5; pop, read → 1; pop, read → 0.
   - Replace empty stack (push 0 then replace 7) → 7.
   - Split sequence across two chunks: `b"\x1b[>"` then `b"1u"` → 1.
   - Non-kitty escape (`\x1b[2J`) passes through and does not corrupt state.
10. **Unit tests for kitty encoder** (in `src/pty/kitty.rs`):
    Enter, Shift+Enter, Ctrl+Enter, Ctrl+a, F1, Shift+Up, Backspace, Tab,
    plain `a` (UTF-8 passthrough), Ctrl+c → byte-exact assertions per step 5.
11. **Legacy regression tests stay green.** Do not modify any existing test
    in `src/pty/keys.rs`. Verify `cargo test -p nostromo --lib pty::keys` is
    unchanged.
12. **Integration test in `src/pty/host.rs`.** Add `#[cfg(test)] mod tests`
    if not present (check first). Spawn `cat` via `PtyHost::spawn`; inject
    `\x1b[>1u` by writing it into the slave side (or, simpler, instantiate
    a `KittyFlagsTracker` directly and feed the bytes — the host's tracker
    is private; expose `#[cfg(test)] pub(crate) fn kitty_flags(&self)` on
    `PtyHost`). Then call `send_key(Enter)`, read what `cat` echoes, and
    assert it contains `\x1b[13u`. Then inject `\x1b[<u`, send Enter again,
    assert it contains `\r`. If running a child process in tests proves
    flaky, fall back to a direct unit test that constructs a `PtyHost`-
    equivalent harness around `key_to_bytes_for`.
13. **Widget dim test.** In `src/pty/widget.rs` `#[cfg(test)] mod tests`,
    build a `vt100::Parser`, feed it `\x1b[2mDIM\x1b[0m` (SGR 2 = dim),
    iterate over the resulting screen cells for "DIM", call `build_style`,
    assert `style.add_modifier` contains `Modifier::DIM`. Skip if vt100
    has no dim accessor (per step 8).
14. **Verify build green.** `cargo check --all-targets`, then
    `cargo test -p nostromo --lib pty::`, then `cargo clippy
    --all-targets -- -D warnings`. Fix anything that lights up.
15. **Manual smoke (optional, document in PR body).** Run nostromo, open
    a Claude pane, type a message, wait for the dim ghost suggestion,
    press Enter, confirm it accepts the suggestion (the buffer fills with
    the ghost text rather than submitting).

## Acceptance criteria

- `KittyFlagsTracker` exists in `src/pty/kitty.rs` and correctly handles
  push/pop/replace sequences including chunks split mid-escape.
- `key_to_bytes` (legacy) is unchanged; all existing tests in
  `src/pty/keys.rs` pass without modification.
- `key_to_bytes_kitty` (or equivalent) emits byte-exact kitty encodings
  for Enter, Shift+Enter, Ctrl+Enter, Ctrl+a, F1, Shift+Up at minimum.
- `PtyHost::send_key` and `DaemonPtyClient::send_key` choose between
  legacy and kitty encoding based on the per-PTY tracker's current top
  flag value.
- The dim cell attribute, if exposed by the local `vt100` crate version,
  is mapped to `Modifier::DIM` in `build_style`. If not exposed, a
  `TODO` comment documents the gap.
- `cargo check --all-targets` and `cargo clippy --all-targets -- -D
  warnings` both pass clean.
- `cargo test -p nostromo --lib pty::` is fully green and includes new
  tests for the flags parser, the kitty encoder, and the dim mapping
  (if feasible).
- Commit message and PR title reference "kitty keyboard passthrough"
  and call out the secondary dim fix.
- PR body links the bug ("Claude inline suggestion can't be accepted via
  Enter inside Nostromo panes") and explains the two-part fix.

## Out of scope

- Do **not** strip the kitty escapes from the vt100 stream — pass them
  through. vt100 ignores them harmlessly and stripping risks edge cases.
- Do **not** implement kitty *encoding* of escape responses (e.g. the
  `\x1b[?u` query reply) — Nostromo doesn't need to answer for the
  inner app, and the inner app isn't asking the outer terminal.
- Do **not** change the outer terminal flags set in `src/main.rs`. The
  outer side is already correct.
- Do **not** refactor `AltScreenFilter` or merge it with the new
  tracker, even if a generic "PTY stream parser" abstraction looks
  tempting. Keep the change surface small and reviewable.
- Do **not** split into phases or multiple PRs. Single coherent change.
- Do **not** add a CLI flag or env var to toggle kitty passthrough.
  It activates automatically when the inner app pushes flags.
- Do **not** touch view-layer code (Fred, Perri, Claudia, Mother, Teri,
  agent_generic) — the PTY layer change is transparent to views.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Fiddly byte-level protocol work across two PTY backends with chunk-boundary edge cases; correctness matters more than speed."
  redd:
    model: sonnet
    effort: high
    rationale: "Byte-exact tests over a state machine plus a PTY integration test; thorough coverage is the whole point of this layer."
  marty:
    model: sonnet
    effort: medium
    rationale: "Small refactor surface — mostly threading a new Arc<AtomicU32> through two existing paths."
  perri:
    model: sonnet
    effort: high
    rationale: "Protocol details (kitty CSI-u modifier math, sequence boundaries) are easy to get subtly wrong; reviewer should verify byte sequences against spec."
```
