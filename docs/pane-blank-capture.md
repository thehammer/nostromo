# "The Claude pane went blank, then redrew": detection and capture

Detection and capture only; there is no fix here. The pane (a transcript, `ReplView`) blanks rarely and
then redraws, so by the time anyone looks, the state is gone. Each transcript pane now keeps a flight
recorder of what it just did, a detector watches for the blank, and a hit writes one small file you can
send. It is modelled on the window overflow capture (`layout-overflow-*.json`).

## What to do (the workflow)

1. **A pane blanks.** Do not relaunch. Run `bin/nostromo-app windows` and send the path in
   `blankCapture` for that window (`null` means nothing was captured).
2. **`blankCapture` is `null`?** Press **Debug > Capture render state now** (⌥⇧⌘B) right away, or run
   `bin/nostromo-app capture-render-state`. It writes a capture for every transcript pane on screen and
   puts the paths on the pasteboard. The recorder already holds the seconds before, so a capture made
   just after the blank is still useful.
3. Send the file(s). They contain no text (see below).

## What a capture is

`~/.nostromo/logs/pane-blank-<tag hash>-<UTC>.json` (`...-<UTC>-manual.json` for a manual capture): the
directory is 0700, each file is exactly 0600, and the pane is named only by a stable 8-hex hash of its
tag. The newest 8 automatic captures and, separately, the newest 8 manual ones are kept (over all
panes), so pressing the menu item cannot evict what a detector hit wrote.
**Structure only, never content:** numbers, booleans and fixed names (rule, severity, event kind and
reason, the build string). No turn text, tool arguments, titles, paths, tags or OS-supplied names (a
screen is its index, frame and scale, never its name) can reach it. The recorder's events have four
numeric slots and no string slot; the tests grep captures for sentinel strings and check every key and
every string value in a capture against a whitelist, so a free-text field cannot be added silently.

Top level:

| Key | Meaning |
|---|---|
| `trigger` | `auto` (the detector) or `manual` (the menu item or `capture-render-state`) |
| `reason` / `rule` | which rule fired: `empty-viewport`, `height-collapse`, `zero-row-draw`, `main-thread-stall`, or `manual` |
| `severity` | `blank`, `stall` (a lower severity: the main thread stalled but nothing is known to be blank) or `manual` |
| `detail` | the numbers behind the hit (how long the viewport was empty, the heights before, during and after a collapse, the stall in ms...) |
| `diagnostics` | the pane's counters at capture time: `retainedTurns`, `materializedViews`, `visibleTurnViews`, `estimatedDocHeight`, `transcriptClears`, `slowMeasures`, `worstMeasureMs`, `viewportHeight` |
| `pane` | geometry: pane, scroll view and clip sizes, the scroll offset, the document frame height, whether a materialization pass was pending, following the tail |
| `memory` | where the process's memory is, so a leak is diagnosable without attaching `footprint` or `heap` (`MemorySummary`): `physicalFootprintBytes`, `mallocBlocksInUse`, `mallocBytesInUse`, and `categories`, the largest dirty VM categories (`Malloc Small`, `Malloc Large`, ...) as `name` + `dirtyBytes`. Numbers and fixed category names only; a VM-region walk and `malloc_zone_statistics` (cost not measured at a 1.8 GB footprint, so do not call it on a hot path), never `heap` |
| `suppressedHits` | per rule, how many hits were not recorded in `events` because the same rule had just been recorded (see below); a stall storm shows up here as a number |
| `window`, `screens` | the window frame, `screenIndex` (its index in `screens`, -1 for none), key, occluded, alpha, full screen; every screen's `index`, frame and scale. `window` is null when the pane is not in a window |
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
| `measureStall` | a measurement over its budget, in ms, and its `turnIndex` (coalesced to one slot per 5 s) |
| `runLoopStall` | a main-thread turn that was busy for `ms` (coalesced to one slot per 5 s; `n` says how many) |
| `windowKey`, `windowScreen`, `windowOcclusion`, `appActive`, `systemSleep`, `systemWake`, `displayReconfig` | window, app and system state changes |
| `paneState` | the pane's alpha, hidden, its scroll view's hidden and whether it is still attached |
| `moveToWindow` | the pane entered or left a window |
| `draw` | the draw heartbeat: visible rect size, turn rows in it, rows painted (coalesced to one per 100 ms) |
| `detectorHit`, `capture` | the detector fired (`rule`, `severity` as numbers; at most one per rule per 5 s, the rest counted in `suppressedHits`) / a file was written |

Stalls cannot flood the ring: `measureStall` and `runLoopStall` coalesce, and a rule's `detectorHit` is
recorded at most once per 5 s, so 300 stalls take a handful of slots and the `viewsEvicted`,
`windowChange` and `docHeight` events from before them stay in the capture.

A blank usually reads as: `viewsEvicted` (everything, with a `reason`), then nothing builds views
(`viewsMaterialized` missing), `draw` events with `rowsInVisibleRect` 0, then a late `viewsMaterialized`
when it redraws. A `docHeight` that collapses points at the geometry; a `measureStall` or
`runLoopStall` / `main-thread-stall` right before points at the main thread; `windowScreen`, `displayReconfig`,
`systemWake` or `windowOcclusion` just before point at the window system.

## The detector

Evaluated at most once per run-loop turn (when something changed) and on a timer while the pane is
visible: 250 ms, backing off to 1 s after 4 healthy ticks in a row in which nothing asked for a look
(no event, no rule watching something); any event, suspicion or hit returns it to 250 ms. A pane is "visible" when it is in a window, not hidden, the window not occluded and it has a
usable size. A hit writes one file (the report is built at the hit, so it shows the pane as it was; only the file
write waits for the next main-queue turn, so no file I/O happens inside the draw or run-loop callback
that detected it); at most one automatic capture per pane per 5 minutes (a `stall` and
a `blank` are limited independently, so a stall cannot use up the capture of the blank it caused). The
manual capture bypasses the limit.

- **empty-viewport**: the pane has turns but no turn view overlaps the viewport, on 3 evaluations in a
  row spanning at least 300 ms. While a deliberate shed is in flight (the views were released and the
  compaction that precedes the rebuild has not landed) an empty viewport is expected, so the span must
  be at least 2 s instead (the whole empty run that began during a shed, up to the rebuild filling it); a blank that outlasts that is reported with the shed visible in `events`.
- **height-collapse**: the document height falls by more than half, to less than the viewport height, and
  recovers (to at least half of what it was) within 10 s. Not raised when the session cleared its
  transcript, when the height stays down, or after a resize or a fold toggle (those move the height on purpose).
- **zero-row-draw**: the document view is about to draw, the pane is on screen with turns, no turn row is
  in the visible rect, and nothing is queued to fix it (no materialization pass queued or running, no
  shed waiting for its compaction, and the geometry is in step with the session's turns). Once per
  incident: it does not repeat for 5 s unless a draw painted rows in between. (The heartbeat is the document
  view's `viewWillDraw`, not `draw(_:)`: overriding `draw(_:)` would tell AppKit the view paints and give
  a view as tall as the whole transcript a backing store. A test lets AppKit draw the real document view in an ordered-in, layer-backed window and checks that `viewWillDraw` fires and a `draw` event is recorded.)
- **main-thread-stall**: one run-loop turn busy for more than 250 ms while the pane is visible
  (severity `stall`). A stall is the app's, not a pane's: every visible pane records it, one file is
  written for it (by the first visible pane), and not more than one per 5 minutes app-wide.

It does not fire for normal streaming, scrolling, resizing, switching tabs (the pane is not visible) or a
transcript with no turns.

A memory-watchdog shed (`viewsEvicted` with reason `shed`) releases every turn view and rebuilds them
after the compaction lands. If that takes longer than 2 s the pane really is blank, and rule (a)
reports it with the shed visible in `events`.

## Cost

Observing only: a recorder event is a 4-double struct written into a preallocated ring (no allocation, a
test holds the average append under 5 µs). The run-loop observer costs two clock reads per turn. Nothing
changes what the pane renders, scrolls or measures.
