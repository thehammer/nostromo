# App control (QA socket)

`bin/nostromo-app` drives the **real** macOS app — click, type, keys, paste,
drop files, view-tree dump, window screenshots — so UI behaviour can be QA'd by
a script or an agent instead of a human watching the screen.

## Enabling

The socket can click anything in the app, so it is **opt-in**:

    defaults write com.hammer.nostromo AppControlEnabled -bool true   # then relaunch
    # or, for one launch:  open --env NOSTROMO_APP_CONTROL=1 /Applications/Nostromo.app

It listens at `~/.nostromo/app-control.sock` (mode 0600, owner only). Turn it
off with `defaults delete com.hammer.nostromo AppControlEnabled`.

## Why events go through `sendEvent`

Clicks, keys and drops are synthesised and delivered with `NSWindow.sendEvent` /
the destination view's drag methods, so they take the same hit-test and
responder path a real input does. That is deliberate: a sibling overlay
swallowing clicks (the sidebar "+" bug, #185) reproduces here; calling
`button.performClick` directly would have hidden it.

## Commands

See `bin/nostromo-app --help`. Coordinates are window-content points with a
**top-left origin** — what a screenshot shows — so a position read from a
screenshot or the `tree` dump can be passed straight to `click`.

| cmd | what it does |
|---|---|
| `windows` | index, title, frame, fullscreen, key, first responder, `contentOverflow` (`{w, h}`: how far the window's content view pokes past the window, in points; both are `0` when it fits. A QA script asserts both are 0 on every window. The app also logs `content overflow window=… layout=… content=… focus=… widest=<view class>` once per window per minute, category `layout`, content-free). `overflowCapture`: path of the newest `~/.nostromo/logs/layout-overflow-<window index>-<UTC>.json` for that window, or `null`. The app writes that file by itself, once per window per 10 minutes (the newest 5 are kept, mode 0600), about a second after a window's content overflows it, and only if it still overflows then. It holds structure only (no text of any kind): the window and screen frames, `contentOverflow`, the focus kind, and for every view from `MainLayout` down (depth <= 14, nothing below a scroll view's document) its class, frame, `fittingSize`, `intrinsicContentSize`, hugging and compression priorities, and, for each view that pokes past the window or demands more than it has, the active constraints at priority >= 750. **If any window shows a non-zero `contentOverflow`, do not relaunch: send that file's path.** `blankCapture`: path of the newest `~/.nostromo/logs/pane-blank-<tag hash>-<UTC>.json` of a transcript pane in that window (the pane went blank, or stalled, or you captured it by hand), or `null`. Content-free; see `docs/pane-blank-capture.md`. **If a pane blanks, send that path; if it is `null`, run `capture-render-state` straight away.** |
| `capture-render-state` | Debug ▸ Capture render state now, for scripts: writes a `pane-blank-*.json` capture (reason `manual`, no rate limit) for every transcript pane on screen and returns `{files: [paths]}` |
| `tree` | nested view dump: class, frame, text, tooltip, label |
| `find TEXT` | views whose text/tooltip/label/class contains TEXT, with centre points |
| `click` | by `X Y` or `--text`; the reply says which view class was hit |
| `drag` | press at `X Y` (or `--text`), drag in steps to `--to X Y`, release — for selecting text |
| `hittest X Y` | **read-only, sends no event** (may complete a layout pass AppKit already had pending): which view a click at X Y would hit, plus the chain of views from it up to the content view and the focus state (see below) |
| `transcript-anchor [--focus TAG]` | **read-only, sends no event, no focus change**: the transcript's first visible block (`turnKey`, `itemKey`, `offsetPt` from the viewport top), `bottomOffsetPt` (0 at the bottom) and `following`; the scroll-safety gate compares two snapshots (≤ 1 pt) |
| `tracker show [--focus TAG]` | **read-only, sends no event, no focus change, writes nothing**: what the tracker pane shows (from the pane's own state): `title`, `path`, `updated`, `committable`, `sections` (`id`, `title`, `count`, `done` {`count`, `expanded`}, `items`: `id`, `text`, `status`, `owner`, `updated`, `updated_at`, `env`, `note`, `links`, `folded` (inside a collapsed Done group), `held` (`done_in_place`, `kept_in_place`, `moved`, `removed`, `selection`, `moving` or null; also set on the folded Done entry of an item whose row the view still holds elsewhere), `held_reason` (a sentence saying why the view keeps the row, null exactly when `held` is), `model_section` (the section the board itself has the item in), `shown_section` (the section the view actually has the row under: differs from `model_section` exactly when a held row stays under its old heading), `shown_expanded` (true when the item has a collapsible note, longer than 2 lines, and the view shows it expanded; false for a short note, which has nothing to expand), `stub`, `conflict`, `badge`), `strip` (`count`, `title`, `items`), `banners`, `log`, `visible`, `hidden_by_user`, `filter`, and the render probe `render_generation` / `rows_updated_last` (an identical board pushed twice leaves both unchanged). With no tracker pane on screen for `TAG`, what the board would show, `visible: false` |
| `tracker file [--focus TAG]` | **read-only**: the board file's `path`, `exists`, `committable` and `remote` (as the daemon classed it), `size` in bytes, `banner` (`unreadable`, `missing` or null) |
| `tracker-anchor [--focus TAG]` | **read-only, sends no event, no focus change**: the tracker's first visible row (`rowKey`: `section:<id>`, `item:<id>`, `done:<section>`, `prose:<key>`, `log`, `moving:<id>`) and `offsetPt` (viewport top minus the row's top), `scrollY`, `documentHeight`, `viewportHeight`, `deferredPending` and `pending` (`key`, `kind` of every held change); the tracker scroll gate compares two snapshots (≤ 1 pt) |
| `tasks list [--focus TAG] [--all]` | **read-only, sends no event, no focus change, stops nothing**: what the Background activity popover shows for the focus (default: the pane holding the keyboard focus, else the window's only visible pane), built from the same model the popover and the chip use: `tag`, `running` (count), `chip` (as `tasks chip`), `tasks` (`id`, `section` (`running`, `ended`, `housekeeping`), `kind` (`Shell`, `Monitor`, `Agent`, `Workflow`, `Other`), `kind_name` (the CLI's raw kind), `title`, `description`, `status`, `elapsed_ms` (running) or `duration_ms` (ended), `ended_ago_ms`, `sign_of_life`, `parent_id`, `depth`, `housekeeping`, `stop_offered`; unknown values are `null`, never 0). Without `--all` only the running tasks; `--all` adds the Ended list and the housekeeping tasks. **`sign_of_life` for a shell or monitor is `last: ` plus its last output line, so output pasted into logs, PRs or tickets may contain command output (paths, hostnames, tokens a command printed); check it first.** An unknown status the daemon sent is shown cut to 24 characters. A `--focus` that no pane or task store entry has is an error (`not found: no focus tagged …`, listing the known tags), not an empty result |
| `tasks chip [--focus TAG]` | **read-only**: the Background activity chip's `text` (`◷ 2 running`, `✓ 3 done`, `✕ 1 failed`, counts above 99 read `99+`, `null` when hidden) and `state` (`hidden`, `running`, `done`, `failed`) |
| `approvals list [--focus TAG] [-w N]` | **read-only, sends no event, answers nothing**: every permission-approval card on screen, read from the card's own views. Per request: `request_id`, `focus`, `agent`, `tool`, `headline`, `input` (the input as displayed: invisible characters as tokens such as `⟨U+202E RLO⟩`), `lines` (`number`, `text`, `kind`, `separators`), `command_count`, `invisible_count`, `non_ascii_count`, `banner`, `reason_line`, `options` (`id`, `enabled`, `label`; Allow once reads `Scroll to the end to allow` until the input has been scrolled to its last line), `default_to_no_kind`, `seconds_left`, `state`, `display_failed` (true when the input's text could not be laid out or was not drawn (no glyphs, or a render of the text area shows no glyph ink): Allow once stays off and the banner says to deny it), `page` and `of` (`1 of 3`, the first window's), `windows` (indexes of every window showing the request), `window_cards` (`window`, `page`, `of`, `state` per window: a second window shows the outcome here within a second of an answer in the first), and, beside `approvals`, `guard_bars` (`window`, `focus`, `text` of every production-shell guard bar on screen). With `-w N` only that window is read; without it, every window. `click --text "Allow once"` at a card is refused unless the QA-only switch is on (`HumanGesture`); `approvals list` has no side effects |
| `key` / `type` | key event through `NSApp.sendEvent` (menu shortcuts fire) / insert text at the first responder |
| `paste` | put an image or text on the clipboard and send `paste:` |
| `drop` | deliver a file drop to the registered drag destination under a point |
| `screenshot` | PNG of a window (no Screen Recording permission needed). **In the real app every terminal pane is hidden**: see "Screenshots hide terminals" below. The reply carries `terminalsHidden` (true in the real app) |

## Mouse events and the tracking loop

`click` and `drag` queue the mouse-up (and the drag steps) in the app's event
queue *before* sending the mouse-down. That order matters: on a control or on
selectable text (a transcript label, an `NSTextView`), AppKit's `mouseDown`
runs a nested loop that waits for the matching mouse-up, so a down sent alone
parks the main thread there and the app freezes until a real mouse event
arrives. If a `nostromo-app` call times out, that is the likely cause; one real
click in the app window releases it. (`AppControlMouse` in
`AppControlProtocol.swift` is the implementation and is unit-tested.)

Select text with `drag`, e.g. across a paragraph, then `key c --mod cmd` to copy:

    bin/nostromo-app drag 300 400 --to 700 420
    bin/nostromo-app click --text "word" --count 2   # double-click selects a word

## `hittest`: why can't I select this?

    bin/nostromo-app hittest 600 400          # a point inside an agent paragraph

Sends no event and changes no state, so it is safe against the app you are using. (A chat turn that has a layout pass pending completes it when hit-tested — the same pass AppKit would run before the next draw; `needsLayout` in the reply shows whether one was pending.)
The reply has `hit` (the hit view's class), `chain` (the hit view first, then each
superview up to the window's content view) and `window`:

- per view: `class`, `frame` (top-left window-content rect, as in `tree`),
  `isHidden`, `alphaValue`, `acceptsFirstResponder`, `needsLayout`; for an
  `NSTextView` also `isSelectable`, `isEditable`, `isFieldEditor`,
  `selectedRange` and `isFirstResponder`; for an `NSTextField` `isSelectable`,
  `isEditable` and `isEditing`;
- `window`: `isKeyWindow`, `appIsActive` and the `firstResponder` class.

If a paragraph will not select, the first entry of `chain` should be the card's
`NSTextView` with `isSelectable: true` and a non-zero frame. Anything else (a
card, a stack, an overlay) is the view eating the click. `drag` clamps `--steps`
to 1...200.

Only the gesture's own mouse events are delivered: `click`/`drag` forward just the
queued events that carry their window number and event number, and put any other
mouse-up or drag (the operator's, another window's) back in the queue untouched.

## Example: the image-attach path

    bin/nostromo-app click --text "Message"        # focus the input
    bin/nostromo-app drop ~/Desktop/shot.png --text "Message"
    bin/nostromo-app screenshot /tmp/after-drop.png
    bin/nostromo-app key $'\r'                      # send

## SwiftUI content

SwiftUI draws its own text, so there is no `NSTextField` to find. With the
control socket on, the app turns on the accessibility tree
(`AXEnhancedUserInterface`) and `find` / `click --text` / `tree` also search the
accessibility elements inside any `NSHostingView` — e.g. the Mother job list's
titles and group headers. `nostromo-app ax [CLASS]` dumps the raw tree for
debugging.

## Scripted scenarios

`wait TEXT [--gone] [--timeout S]` polls until a view with TEXT appears (or
disappears) and exits non-zero on timeout; `expect TEXT [--absent]` is the
one-shot form. With `layout-issues` these make shell scenarios that assert:
see `scripts/qa/attach-chip.sh`. Scenarios click and drop in the live window,
so run them when nobody is typing in it, and keep them away from anything that
sends a message to an agent unless that is the point.

Read-only smoke scripts for Teri/Fred and window placement, and how to read them, are in
[`scripts/qa/README.md`](../scripts/qa/README.md).

Pair with `bin/fake-mother-broker` (launch the app with `MOTHER_BROKER_SOCK`)
to drive Mother-queue UI with canned jobs.

## Controls that answer agents refuse app-control input

An agent can drive this socket, so app-control must not be able to answer an
agent for the human. Controls that answer an agent (a decision sheet's choices,
its Dismiss button and Esc today; approval controls next) accept only a real
user gesture. A `click`, `key` or `type` aimed at one does nothing: the sheet
stays up and the app logs `synthetic input refused`. That holds whether or not
app-control is enabled.

How the app tells (`macOS/Nostromo/Security/`), two signals, either one enough:

- **Depth gate.** Every request runs inside `SyntheticInputGate.begin()` /
  `end()` on the main thread, so anything a control sees while one runs is
  synthetic. This is what catches `click`, `drag` and `type`.
- **Marker.** Only `key` events carry `SyntheticInputGate.marker` in their
  `CGEvent` source user data, so one delivered after the request returned is
  still recognised. Clicks and drags are **not** stamped: rebuilding a mouse
  event through `NSEvent(cgEvent:)` recomputes its window location from its
  screen location, unreliably (see the `SyntheticInputGate.stamped` doc). They
  are delivered while the request runs, so the depth gate covers them.

`HumanGesture.permit` refuses either. It also refuses an event-less action
(an Accessibility `AXPress` from another process) unless VoiceOver is on, and
**a stale event**: AppKit leaves `NSApp.currentEvent` set to the last event it
dispatched, even in later timer and dispatch callbacks, so a press arriving
more than **1 s** (`HumanGesture.maxEventAge`) after that event is refused
(`staleEvent`). An event stamped in the **future** by more than **0.25 s**
(`HumanGesture.maxFutureSkew`) is refused too (`futureEvent`): a real event is
stamped when it happened, and the age check alone would let any future
timestamp pass.

What the daemon checks on its side (only the pinned, installed app may answer
at all) is in [`operator-app-trust.md`](operator-app-trust.md).

**QA-only switch.** An isolated QA build may accept synthetic input on those
controls when it is launched with `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1` **and**
its bundle id is not `com.hammer.nostromo`. The user's app never honours it.

## Screenshots hide terminals

A terminal's screen is read through `nostromo.read_terminal_screen` only (it needs a follow and
is redacted by the daemon). A picture of the window would bypass that, so `screenshot` does not
show terminal pixels in the real app (`com.hammer.nostromo`, where
`SyntheticInputGate.allowsSynthetic` is false):

- Every terminal pane's body (everything under its header: the terminal, a mirror's clipped
  overflow, the connecting message and the ended overlay) is painted over with one opaque block
  labelled `terminal hidden from app-control`. The header, the red remote frame and the environment
  label stay visible, so layout QA still works. Every window's screenshot hides the terminals in
  that window, mirrors included.
- A pane's **staged-commands drawer** (what an agent staged for the person, see `terminal.md` "Command staging") is
  a terminal pixel area of its own: it is painted over the same way. In the real app `tree`, `find` and `ax` also
  read it as one entry with the fixed text `staged commands hidden from app-control` and no children, so
  neither a staged command nor its note can reach an agent through app-control (`AppControlAX.isWithheld`).
  The QA instance (the synthetic-input gate relaxed) is unchanged and reads the rows, which is what
  `scripts/qa/terminal-staging.sh` relies on. VoiceOver is unaffected: it uses the system accessibility API.
- The capture is made in memory and painted over **before** the PNG is encoded. The unredacted image
  is never written to disk, not even to a temp file (`ScreenshotRedaction.pngData`; the server writes
  only what it returns).
- If a terminal's area cannot be placed in the capture (not in the window, no finite frame, a capture
  that does not match its window), the screenshot is **refused** with `screenshot refused: ...`, and
  nothing is written.
- A QA build (`NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1`, bundle id other than `com.hammer.nostromo`)
  gets the unchanged picture, so `terminal-local.sh`-style QA still sees what the terminal drew.

`screenshot` is the only app-control command that returns pixels or image data (`paste --image` and
`drop` read a file you name; they return nothing). The other commands carry no terminal text: `windows`
returns window metadata and the first responder's class name; `tree`, `find` and `hittest` report class,
frame, label and the text of text fields, buttons and text views, and a terminal view is none of those; its
accessibility value (read by `tree`, `find` and `ax`) is empty in the real app (`TerminalScreenAccess`).
The pane header's text (shell, directory, environment) and the ended/connecting messages are chrome, not
screen content.

The window-server picture is a snapshot of what the compositor drew last, the blocks come from the view
tree as it is now: `screenshot` lays the window out, draws it and flushes Core Animation first so the two
agree. A pane that is mid-resize in the same instant is the one case that can leave a sliver of its old
position unpainted; take the screenshot once the layout has settled.

Known limit: the picture can still lag the view tree by one frame (`CATransaction.flush()` does not
guarantee the window server has the new frame). Every block is therefore padded by 2 px on each side
(clamped to the image), which also covers the up-to-2 px vertical mismatch the aspect-ratio check tolerates. A
visible terminal whose area does not intersect the image at all is refused; one that is hidden (itself or an
ancestor) and off the picture is skipped.

The coordinate mapping: the capture covers the whole window frame (window-server path) or the content
view (the `cacheDisplay` fallback, used when the window server returns a flat image); `ScreenshotRedaction` converts each terminal area to window
coordinates and from there to pixels (scale from the image size, y flipped, rounded outward).

## Isolated QA instance

`scripts/qa/qa-instance.sh start [--no-synthetic]` (also `env`, `status`, `stop`) launches a worktree
`nostromd` and a clone of the app (`com.hammer.nostromo.qa`, signed and pinned like the operator app)
under a temp `HOME`, with its own sockets, the fake CLI (`scripts/qa/fake-claude`) and the guard binary.
It never touches the user's app, daemon or `~/.nostromo`. The clone's control socket is
`$QA_ROOT/app-control.sock`: `NOSTROMO_APP_CONTROL_SOCKET` (read by `AppControlServer`) or
`bin/nostromo-app --socket PATH` select it. `start` launches the clone with
`NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1` unless `--no-synthetic`. An isolation guard compares the user's
`~/.nostromo/{focuses,daemon-panes,daemon-sessions,daemon-terminals}.json`, `approvals/` (file list and
sizes), `app-control.sock` inode, `defaults export com.hammer.nostromo` and the user's `nostromd`/Nostromo
pids before `start` and after `stop`, and `stop` exits non-zero if anything changed.
`scripts/qa/approvals-qa-smoke.sh` (also `terminal-qa-smoke.sh`) proves it end to end. It needs a
logged-in, awake display: not headless, not CI.

## Limits

Windows must be on-screen and awake: with displays locked or asleep the
windows stay at alpha 0 and layout/screenshots are unreliable (`windows`
reports `alpha` and `visible`).


Drags are delivered to the destination view directly rather than through the
window server, so cross-app drag mechanics (promised files, drag images) are
not exercised. Screenshots are the window server's last composited frame (or a `cacheDisplay` render as fallback), with terminal panes painted over from the live view tree; see "Screenshots hide terminals" for the one-frame-lag limit and the 2 px padding.
