# Diagnostics

Reference for the macOS app's Debug menu items and the environment-variable
flags that gate optional diagnostic capture. All of it is off by default
except the Debug-menu "copy" actions, which only run on demand.

## Debug menu

macOS ▸ Debug menu (⌘⇧-prefixed shortcuts throughout — the app reserves ⌘D and
⌘I for other things, hence the odd-looking letters below):

| Item | Shortcut | What it copies to the pasteboard |
|------|----------|-----------------------------------|
| Copy transcript diagnostics | ⌘⇧D | Retained-turn/materialized-view counts and resident memory per transcript pane (`TranscriptDiagnostics`). |
| Copy daemon diagnostics | ⌘⇧I | Daemon-side health (`DaemonDiagnostics`). |
| Copy code-pane diagnostics | ⌘⇧K | One block per live `code`/`diff` pane: the render-audit report (see below), which document kind is loaded, row/label counts, and a truncated preview of its first three rows. |
| Copy pane diagnostics | ⌘⇧P | A point-in-time snapshot of every live pane: content kind held, which of the three curated-agent-view renderers (`CodeContentView`/`ConversationContentView`/`TicketContentView`) is hidden, the owning focus tag, and the same `PaneFirstPaintAudit` verdict the `panes` log's tripwire uses (see below). Useful for "is this pane's model empty, or is its geometry the problem?" without correlating log lines by hand. |

## The `panes` log category

`DynamicFocusView.swift` and `AppStore.swift` share one `os.Logger` category,
`com.hammer.nostromo` / `panes`, covering the whole path from the daemon's
`FocusLayout`/`PaneContent` broadcasts through to a pane's own layout passes:

- `AppStore` logs every `.focusLayout` frame (tag, live pane ids, how many
  stale content entries got pruned) and every `.paneContent` frame (tag,
  pane id, content kind) — including the two frames that get silently
  swallowed by a guard (`.loading` clobbering existing content; an
  idempotent no-op push), each logged as `SWALLOWED (<guard name>)` so a
  push that never reached the view is visible in the same timeline as one
  that did.
- `DynamicFocusView.reconcile` logs whether an incoming layout update needed
  a full rebuild or an in-place repair.
- `DynamicFocusView.updateContent` logs every successful content push to a
  materialised pane (kind, whether it actually changed anything), and logs
  at `.error` if a push names a pane id with no materialised view — a
  divergence between the daemon's tree and what's actually on screen, which
  used to be silently dropped.
- `PaneContentNSView.update`/`layout()` logs whether a content push changed
  anything and, on every layout pass, judges the pane's drawable size via
  `PaneFirstPaintAudit`. That verdict logs at `.error`, rate-limited to once
  per distinct verdict, if a pane has content, is in a window, and has been
  laid out — but doesn't have a real width and height.

**Every line here is counts, ids, kinds and geometry only. No pane
content — no repo name, PR title, file path or diff text — is ever written
to the log.**

To read the timeline for the most recent launch:

```
log show --predicate 'subsystem == "com.hammer.nostromo" AND category == "panes"' --last 5m --debug
```

Drop `--debug` (or use `--info`) to see only the `.error`-level tripwire
hits and dropped pushes, without the per-frame trace.

## Code-pane render audit

`CodeContentView`'s gutter (`LineNumberRulerView.drawHashMarksAndLabels`)
measures itself on every draw pass — label count, text-storage length, row
count, and the document view/clip view/text-container widths — and judges
whether the pass was healthy (`CodePaneRenderAudit`, in
`macOS/Nostromo/UI/CodePaneRenderAudit.swift`). This exists to catch a rare,
previously-unreproducible bug where the gutter paints correct line numbers
over a completely blank text body; see
`.claude/plans/instrument-code-pane-render-diagnostics.md` for the full
investigation.

If a pass looks unhealthy (real content, real gutter, but the text view
wasn't capable of painting it), the app:

1. Logs one line to the `codepane` log category (subsystem
   `com.hammer.nostromo`), rate-limited to once per distinct verdict per
   pane.
2. Attempts a one-shot recovery (re-asserts the text container's size, forces
   layout, requests a redisplay) — a mitigation for an unconfirmed cause, not
   a fix. Whether the pane recovers is itself diagnostic evidence.

**Copy code-pane diagnostics** (⌘⇧K) samples the same measurements on demand,
without needing to catch a live failure — useful for confirming a pane is
healthy, or for pulling numbers off one that already looks wrong.

To read the log directly:

```sh
log stream --predicate 'subsystem == "com.hammer.nostromo" AND category == "codepane"'
```

Note this is a **separate** log category from `panes` above — `codepane` is
specific to the code/diff render path's own internal audit; `panes` covers
the broader daemon-to-view pipeline every pane kind goes through.

## `NOSTROMO_PANE_DUMP`

```sh
NOSTROMO_PANE_DUMP=1
```

When set to `1`, every raw `pane_content` IPC frame is written verbatim to:

```
~/Library/Application Support/Nostromo/pane-content/<paneId>-<epoch-ms>.json
```

The dump happens *before* the frame is decoded, so a frame that fails to
decode is still captured — the previous behavior silently dropped it (see
`NostromodClient.decode`'s `pane_content` case, which now also logs a
`log.error` naming the pane id and the decode error instead of swallowing
it). The directory is pruned to the newest 200 files on every write, so
leaving the flag on cannot fill the disk.

Unset (the default), `NOSTROMO_PANE_DUMP` costs nothing — the check happens
once and the write path is skipped entirely.

## `NOSTROMO_DIAG_INTERVAL`

```sh
NOSTROMO_DIAG_INTERVAL=<seconds>
```

Appends one JSON line per interval to
`~/Library/Application Support/Nostromo/diagnostics.jsonl` — the transcript
diagnostics report (`TranscriptDiagnostics`), the same JSON **Copy transcript
diagnostics** puts on the pasteboard. Used by
`macOS/scripts/transcript-load-test.sh`.

## `NOSTROMO_DIAG_PATH`

```sh
NOSTROMO_DIAG_PATH=/absolute/path/to/diagnostics.jsonl
```

Overrides the diagnostics stream's path entirely (default:
`~/Library/Application Support/Nostromo/diagnostics.jsonl`). This is what
lets `bin/nostromo-launch-smoke` (see below) point a launch at its own
per-run temp file instead of appending to the operator's real
`diagnostics.jsonl`. Unset, behaviour is unchanged.

## `NOSTROMO_WINDOW_MODE`

```sh
NOSTROMO_WINDOW_MODE=smoke
```

Unset (the default): unchanged — one full-screen window per attached
display, exactly as today. Set to `smoke`: opens exactly one window, sized
1440×900, on `NSScreen.main` only; never enters full screen; is ordered in
via `orderFront` (never `makeKeyAndOrderFront`), so it never steals focus
from whatever else is running; and its `alphaValue` stays at the `0.0`
`AppDelegate` already sets before ordering any window in, since
`windowWillEnterFullScreen`'s fade to opaque (`NostromoWindow.swift`) is
never reached on this path. The window is genuinely on screen and laid out
— just fully transparent, so nothing is visible to the operator and the
frontmost application does not change. This is the launch-smoke check's own
isolation mechanism; the residual it accepts is that no full-screen
transition is exercised on this path, so a defect specific to that
transition would not be caught here. See `bin/nostromo-launch-smoke` and
`docs/ios-verification.md`'s L4 section.

## The launch smoke check (L4)

```sh
make mac-smoke
```

Builds the Debug app, launches it against an in-process fixture daemon
(speaking just enough of the real IPC handshake to serve a genuine
multi-pane `focus_layout` tree — see `src/mcp/layouts/perri-standard.yaml`),
and asserts it reaches a real, laid-out multi-pane AppKit layout without
crashing, spinning, or laying out a zero-size pane. Reports exactly one of
`PASS`/`FAIL`/`INCONCLUSIVE` (exit 0/1/2). This is the missing layer between
"compiles and passes logic tests" and "a human happens to relaunch the app
and watch CPU" — see
`.claude/bugs/resolved/2026-09-03-ratiosplitview-layout-infinite-recursion-crash-on-launch.md`
in the primary repo checkout for why it exists, and
`macOS/scripts/launch-smoke-validate.sh` (`make mac-smoke-validate`) for the
validation that it actually catches that defect.

New diagnostics-stream fields this check consumes (all `Optional`, so a
plain launch with nothing watching writes exactly the same lines it always
has):

| Field | What it is |
|-------|------------|
| `firstLayoutReconcileAt` | ISO8601 timestamp of the first observed pane with a real window, a completed layout pass, and non-zero bounds. Anchors the check's 15s observation window. |
| `splitNodesRendered` / `leavesRendered` | Split-node / leaf counts from the most recently reconciled tree, summed across every live focus. |
| `splitsLaidOut` | Count of live `RatioSplitView`s that have completed a layout pass with a non-zero size. |
| `splitsRatiosApplied` | Count of live `RatioSplitView`s whose `applyRatios` call has returned `true` — positive proof the app reached `NSSplitView.setPosition` and returned, the exact call that never returned in the 2026-09-03 defect. |
| `panesMeasured` | Verbatim `PaneFirstPaintAudit.Measurements` for every live agent-authored pane. |

## Daemon-side diff/code payload logging

`src/mcp/tools/apply_layout.rs` logs one line (via `tracing::info!`) every
time it builds a `PaneContentWire::Diff` or `PaneContentWire::Code` payload —
file/hunk/line counts and byte lengths, never content. Cross-referencing this
against the client's `codepane` log or a `NOSTROMO_PANE_DUMP` capture is what
turns "the daemon probably didn't send something empty" into "the daemon
logged N rows and the client received exactly N rows."

<!-- scratch: skip-demo touch -->
