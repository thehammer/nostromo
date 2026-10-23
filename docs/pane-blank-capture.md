# "The Claude pane went blank, then redrew": detection and capture

Detection and capture only; there is no fix here. The pane (a transcript, `ReplView`) blanks rarely and
then redraws, so by the time anyone looks, the state is gone. Each transcript pane now keeps a flight
recorder of what it just did, a detector watches for the blank, and a hit writes one small file you can
send. It is modelled on the window overflow capture (`layout-overflow-*.json`).

## What to do (the workflow)

1. **A pane blanks.** Do not relaunch. Run `bin/nostromo-app windows` and send the path in
   `blankCapture` for that window (`null` means nothing was captured).
2. **`blankCapture` is `null`?** Press **Debug > Capture render state now** (⇧⌘B) right away, or run
   `bin/nostromo-app capture-render-state`. It writes a capture for every transcript pane on screen and
   puts the paths on the pasteboard. The recorder already holds the seconds before, so a capture made
   just after the blank is still useful.
3. Send the file(s). They contain no text (see below).

## What a capture is

`~/.nostromo/logs/pane-blank-<tag hash>-<UTC>.json`: the directory is 0700, each file is exactly 0600,
the newest 8 are kept (over all panes), and the pane is named only by a stable 8-hex hash of its tag.
**Structure only, never content:** numbers, flags and fixed names. No turn text, tool arguments, titles,
paths or tags can reach it (the recorder's events have four numeric slots and no string slot; the
tests grep captures for sentinel strings).

Top level:

| Key | Meaning |
|---|---|
| `trigger` | `auto` (the detector) or `manual` (the menu item or `capture-render-state`) |
| `reason` / `rule` | which rule fired: `empty-viewport`, `height-collapse`, `zero-row-draw`, `main-thread-stall`, or `manual` |
| `severity` | `blank`, `stall` (a lower severity: the main thread stalled but nothing is known to be blank) or `manual` |
| `detail` | the numbers behind the hit (how long the viewport was empty, the heights before, during and after a collapse, the stall in ms...) |
| `diagnostics` | the pane's counters at capture time: `retainedTurns`, `materializedViews`, `visibleTurnViews`, `estimatedDocHeight`, `transcriptClears`, `slowMeasures`, `worstMeasureMs`, `viewportHeight` |
| `pane` | geometry: pane, scroll view and clip sizes, the scroll offset, the document frame height, whether a materialization pass was pending, following the tail |
| `window`, `screens` | the window frame, its screen name, key, occluded, alpha, full screen; every screen's name, frame and scale. `window` is null when the pane is not in a window |
| `app` | uptime in seconds, build (`version (build)`), pid |
| `events` | the flight recorder ring, oldest first, at most 200 |

### Reading `events`

Each event has `seq`, `kind`, `tMs` (monotonic milliseconds), `wall` (UTC), an optional `reason`, the
numbers named for its kind, and `n` when it stands for several coalesced occurrences. The last events
before the hit are the interesting ones. The kinds:

| Kind | Numbers |
|---|---|
| `viewsMaterialized` / `viewsEvicted` | `added`/`removed`, `views` now, `turns` retained; evictions say why (`reason`: `scroll`, `resize`, `clear`, `splice`, `shed`) |
| `windowChange` | the materialization window (`first`, `last` turn) and the viewport top and bottom |
| `docHeight` | document view frame height `oldHeight` → `newHeight`, and the virtualizer's `estimatedHeight` |
| `scroll` | clip offset, document height, viewport height (coalesced to one per 100 ms) |
| `layout` | the pane's size when it changed |
| `transcriptClear` | the session cleared its transcript |
| `measureStall` | a measurement (or a main-thread turn, `turnIndex` -1) over its budget, in ms |
| `windowKey`, `windowScreen`, `windowOcclusion`, `appActive`, `systemSleep`, `systemWake`, `displayReconfig` | window, app and system state changes |
| `paneState` | the pane's alpha, hidden, its scroll view's hidden and whether it is still attached |
| `moveToWindow` | the pane entered or left a window |
| `draw` | the draw heartbeat: visible rect size, turn rows in it, rows painted (coalesced to one per 100 ms) |
| `detectorHit`, `capture` | the detector fired / a file was written |

A blank usually reads as: `viewsEvicted` (everything, with a `reason`), then nothing builds views
(`viewsMaterialized` missing), `draw` events with `rowsInVisibleRect` 0, then a late `viewsMaterialized`
when it redraws. A `docHeight` that collapses points at the geometry; a `measureStall` or
`main-thread-stall` right before points at the main thread; `windowScreen`, `displayReconfig`,
`systemWake` or `windowOcclusion` just before point at the window system.

## The detector

Evaluated at most once per run-loop turn (when something changed) and on a 250 ms timer while the pane
is visible. A pane is "visible" when it is in a window, not hidden, the window not occluded and it has a
usable size. A hit writes one file; at most one automatic capture per pane per 5 minutes (a `stall` and
a `blank` are limited independently, so a stall cannot use up the capture of the blank it caused). The
manual capture bypasses the limit.

- **empty-viewport**: the pane has turns but no turn view overlaps the viewport, on 3 evaluations in a
  row spanning at least 300 ms.
- **height-collapse**: the document height falls by more than half, to less than the viewport height, and
  recovers (to at least half of what it was) within 10 s. Not raised when the session cleared its
  transcript, when the height stays down, or after a resize or a fold toggle (those move the height on purpose).
- **zero-row-draw**: the document view is about to draw, the pane is on screen with turns, no turn row is
  in the visible rect, and nothing is queued to fix it (no materialization pass queued or running, no
  shed waiting for its compaction, and the geometry is in step with the session's turns). Once per
  incident: it does not repeat for 5 s unless a draw painted rows in between. (The heartbeat is the document
  view's `viewWillDraw`, not `draw(_:)`: overriding `draw(_:)` would tell AppKit the view paints and give
  a view as tall as the whole transcript a backing store.)
- **main-thread-stall**: one run-loop turn busy for more than 250 ms while the pane is visible
  (severity `stall`). A stall is the app's, not a pane's: every visible pane records it, one file is
  written for it (by the first visible pane), and not more than one per 5 minutes app-wide.

It does not fire for normal streaming, scrolling, resizing, switching tabs (the pane is not visible) or a
transcript with no turns.

A memory-watchdog shed (`viewsEvicted` with reason `shed`) releases every turn view and rebuilds them
after the compaction lands. If that takes longer than 300 ms the pane really is blank, and rule (a)
reports it with the shed visible in `events`.

## Cost

Observing only: a recorder event is a 4-double struct written into a preallocated ring (no allocation, a
test holds the average append under 5 µs). The run-loop observer costs two clock reads per turn. Nothing
changes what the pane renders, scrolls or measures.
