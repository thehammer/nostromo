# Nostromo for Mac (native app)

## Premise

Nostromo today is a TUI: dense, keyboard-driven, terminal-bound. Its value
comes from a tight coupling between agent panes, live data feeds, and a
single dispatcher (Mother). The TUI is the right surface for *some* of that
work — deep keyboard-led sessions where the operator is fully heads-down.
It is the wrong surface for *the rest*: ambient awareness while doing other
things on the same machine, native selection and search, real notifications,
graphics-heavy data (calendars, gradients, screenshots, diffs), global
hotkey capture, and dragging artefacts in and out of other apps.

The bet: the agentic-orchestration core Nostromo has already built — MCP
server, view registry, daemon-backed PTY persistence, watch-channel data
fabric — is a generic substrate. The TUI is one rendering layer over it.
A native macOS app is a second rendering layer that shares the same
daemon, the same agent ecosystem, the same data feeds. It is not a port;
it is a sibling surface designed for situations the TUI handles poorly.

## Audience and context of use

One operator (the user), at their primary Mac, throughout the day:

- **Heads-up moments between deep work.** Glancing at PR queue, calendar,
  Mother queue while writing in another app. Today this means either
  Cmd-Tab to a terminal or losing the information entirely.
- **Selection, search, and quoting.** Pulling a snippet from a Claude
  conversation into Slack/email/Linear. The TUI renders text but doesn't
  let you select it cleanly across reflow.
- **Cross-app artefact flow.** Drag a screenshot into Claudia. Drop a
  Calendar event onto Fred. Open a PR diff in a real window.
- **Sustained background presence.** Status-bar item that surfaces
  Mother queue state, calendar next event, posture pace — without
  needing a foreground window at all.

The TUI continues to exist in parallel. This app is not a replacement;
it's the right surface for moments when terminal density is not the
constraint.

## Capabilities

- **Native window per view.** Fred, Perri, Mother, Claudia, etc. each
  open as a real macOS window — resizable, minimisable, restorable across
  Spaces, supports Mission Control and Stage Manager. Multiple windows
  can show different views simultaneously.
- **Real text selection and copy.** Claude's responses are selectable
  text widgets, not vt100-rendered cells. Markdown rendered properly —
  not parsed from PTY bytes — with code blocks, tables, links as native
  elements.
- **Persistent status-bar item.** macOS menu-bar icon shows Mother queue
  state (running / awaiting / failed counts), budget posture, calendar
  next event. Click to open a quick-glance popover; click-through
  to focus the relevant view.
- **Global hotkeys.** System-wide shortcut to bring up Claudia (or the
  command palette), with input focus, from anywhere on the system. Same
  for "open Mother queue" or "jump to focused PR."
- **Native notifications.** Mother job completions, PR review requests,
  calendar reminders deliver via macOS notification center. Click-through
  routes to the right pane.
- **Rich media in transcripts.** Inline image rendering, code blocks with
  real syntax highlighting and copy buttons, foldable tool calls with
  smooth animation, hover previews on links.
- **Drag and drop in/out.** Drop a file onto a Claude prompt to attach.
  Drag a PR diff out as a `.diff` file. Drop a screenshot directly into
  Perri for review.
- **System integration.** macOS Calendar/Mail read access for Fred (with
  user consent). Keychain for tokens. Quick Look for previewable
  attachments.
- **Pace bars and gradients as first-class graphics.** Smooth
  hardware-accelerated rendering, not pixel-pushed images shoehorned
  through Kitty graphics protocol.
- **Shared daemon with the TUI.** Open the TUI and the native app
  simultaneously; both see the same Mother queue, same PTY sessions,
  same data feeds. Daemon is the source of truth.

## Constraints

- **Not a port of the TUI.** Do not replicate vt100 panes inside an
  AppKit window. The native app uses native widgets; the TUI continues
  to exist for keyboard-density workflows.
- **Not for headless / SSH / remote work.** macOS-only by definition.
  Operators working over SSH continue to use the TUI.
- **Not a replacement for Claude Code's own UI.** Claude's REPL panes
  may still render as a transcript-like view; the native app is not
  re-implementing Claude's TUI. It's wrapping it with native chrome.
- **No multi-user, no sharing, no permissions model.** Single-user
  application for now. Keep the operating model simple.
- **No mobile-style modal navigation.** This is a desktop app. Side-by-side
  windows and palettes, not full-screen wizards.

## Resolved decisions (2026-05-16)

- **Window model: free-floating (Mail.app-style).** Each view opens as its
  own Mac window. The TUI is already the unified-single-window experience;
  the Mac app is for moments the TUI handles poorly. Free-floating matches
  the operator's existing multi-monitor / Spaces / Stage Manager workflow.
  The status-bar item carries the "always-present" need separately.
- **Repo layout: monorepo.** Mac app lives at `apps/mac/`, sibling to the
  Rust workspace. Shares git history with the daemon so MCP protocol changes
  can land in lockstep with client updates. Split into a sibling repo only
  when CI pipelines or release cadences diverge meaningfully.
- **Embedded `claude` strategy: hybrid.** PTY pane (vt100-in-NSView) hosts
  the real `claude` process so all existing features (slash commands, file
  picker, plan mode, todo display) keep working without re-implementation.
  Alongside it, a transcript pane that renders the conversation natively
  via the same JSONL-tail approach the TUI uses today (Ctrl+T), giving
  native selection, copy, markdown, code highlighting, foldable tool calls.
  If headless `claude -p --output-format stream-json` matures further, the
  transcript pane becomes the upgrade path.

  > **Update (2026-05-31): this upgrade path was taken — and the design
  > diverged from the PTY-pane sketch above.** Sessions are now hosted in
  > `nostromd` as one persistent, bidirectional `--input-format stream-json`
  > process per focus (the daemon owns parsing + the turn model; the GUI is a
  > thin attach-client), not a PTY running the real `claude` TUI. Shipped:
  > survival across daemon restarts, multi-window mirroring via daemon
  > broadcast, optimistic echo. Native phone remote control was found
  > incompatible with stream-json mode (interactive-only) and is parked. Full
  > design + findings: `docs/prds/persistent-bidirectional-session-host.md`.
- **Status-bar item v1 scope: Mother + Posture only.** Mother counts via the
  daemon broadcast (W1). Posture via the existing `~/.claude/budget-posture.json`
  read path. **Calendar deferred** — needs EventKit permission flow and is
  its own wedge, not a v1 add-on.

## Still open

- ~~**Daemon ownership / multi-client IPC.**~~ **RESOLVED (2026-05-31):** the
  protocol-v3 `Session*` IPC handles multiple clients cleanly; multiple GUI
  windows attach to one daemon-hosted session and mirror via broadcast.
- **Distribution**: notarised DMG outside the App Store vs. Mac App Store.
  Default to DMG for the personal-leverage phase; revisit if the product
  pivot happens.
- **Sharing the markdown renderer with the TUI**: the TUI's pulldown-cmark
  → ratatui-spans renderer could be exposed to Swift via FFI/UniFFI, or
  the Mac app could render to native `AttributedString` from scratch.
  Decide at the transcript-pane plan stage (post-W1).

## Related work

- TUI continues to be the canonical surface for terminal-density work;
  most platform-shared functionality lives in the agent + daemon core.
- See `docs/visions/iphone.md` and `docs/visions/ipad.md` for the
  surfaces designed for moments away from the Mac.
- Future PRDs anticipated: native window shell, status-bar item, global
  hotkey, transcript view, Mother queue native renderer.
