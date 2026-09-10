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
  laid out — but doesn't have a usable size. Two distinct verdicts:
  `notDrawable(zeroWidth|zeroHeight)` for a pane with no drawable size at
  all, and `tooSmall(tooNarrow|tooShort)` for one with a perfectly real size
  that is nonetheless below `PaneFirstPaintAudit.minimumUsableExtent`
  (120pt) — see "Too small to use" below.
- `RatioSplitView.layout()` logs at `.error`, **once per split**, when a
  split's requested ratios turn out to be unreachable:
  `split ratios unreachable: requested … achieved … worstDelta=… bounds=… children=…`.
  This is the line that says "the layout settled somewhere other than where
  the daemon asked", and it is the direct signal for the 2026-09-04 /
  2026-09-08 detail-region collapse.

**Every line here is counts, ids, kinds and geometry only. No pane
content — no repo name, PR title, file path or diff text — is ever written
to the log.**

To read the timeline for the most recent launch:

```
log show --predicate 'subsystem == "com.hammer.nostromo" AND category == "panes"' --last 5m --debug
```

Drop `--debug` (or use `--info`) to see only the `.error`-level tripwire
hits and dropped pushes, without the per-frame trace.

## `nostromo.get_render_state` — the non-screenshot way to check a render

Reading `expected=[…] rendered=[…]` out of the `panes` log above (or asking a
human for a screenshot) used to be the only way to answer "did what I asked
for actually show up on screen" — `nostromo.show` and every other
layout-mutating tool only ever report that the **daemon** accepted the call,
not that anything painted. `nostromo.get_render_state` (and the
`render_state` section on `nostromo.get_view_state`) answers that question as
a query instead: it diffs the daemon's expected pane tree against a
per-window report the macOS client sends at the end of every
`DynamicFocusView.reconcile`, and returns `missing`/`extra`/`agrees` per
attached window. See `docs/mcp/tools.md`'s "Render-state visibility (W1)"
section for the full shape, error codes, and the "no report is not the same
as agreement" rule.

## "Too small to use" — the `tooSmall` verdict

`PaneFirstPaintAudit` originally fired only on a pane with **zero** width or
height. On 2026-09-08 the detail region collapsed to **34 points wide** in a
1760pt split whose correct share was 879.5pt, stayed there, and tripped
nothing: 34 is not zero. Every other instrument missed it for the same
reason — `nostromo.get_render_state` saw a hierarchy member, the launch
smoke's `splitsRatiosApplied` read a boolean that was `true` regardless, and
no unit test asserted achieved geometry at all.

So the audit now distinguishes two unhealthy verdicts under the same four
preconditions (has content, not loading, in a window, has laid out at least
once):

| Verdict | Fires when | Catches |
| --- | --- | --- |
| `notDrawable(zeroWidth\|zeroHeight)` | an axis is `<= 0` | a pane with no drawable size at all — unchanged meaning |
| `tooSmall(tooNarrow\|tooShort)` | both axes `> 0`, at least one `< 120pt` | a pane that exists, has real geometry, and still shows the operator nothing — the collapsed-split signature |

The two populations are disjoint: zero wins, so a zero-width pane is never
also reported as `tooSmall`.

**`tooSmall` waits for the offending axis to stop moving.** A healthy pane
legitimately passes through small extents while laying out — measured on the
reproduction bench at `48 x 10` and `639.5 x 36` on panes that ended up
entirely healthy, both of which *overlap* the real 34pt failure. No
threshold can separate them, so the discriminator is whether the axis that
is too small holds the same value across two consecutive layout passes. A
pane still arriving is still changing; a collapsed split axis is pinned.
`PaneFirstPaintAudit.shouldReport` is that rule, and it is why this tripwire
does not fire on every launch. The standing rule this file's audits all
follow: a tripwire that fires on a healthy pane is worse than no tripwire.

## The launch smoke check's fixtures

`bin/nostromo-launch-smoke` serves a committed fixture to a real app launch.
`--fixture` picks which:

| `--fixture` | File | What it is for |
| --- | --- | --- |
| `split` (default) | `tests/fixtures/focus_layout_split.json` | The product shape: a queue pane beside a two-tab `detail` region, above a repl. Every automated caller uses this, and it must PASS. |
| `clamped` | `tests/fixtures/focus_layout_clamped.json` | A split whose requested ratios are genuinely unreachable — a four-child region given 3% of the width, so its panes settle at 44pt. **Expected to FAIL** `no-undersized-laid-out-pane` by construction. |

The default fixture gained the tabs region in
`fix/detail-region-split-collapse`: this check is the repo's only automated
real-AppKit end-to-end coverage, and until then it had never once rendered
the node type the product's primary interaction depends on.

The `clamped` fixture exists to make the `ratios-claimed-honestly` gate
bite. Run against it:

```sh
bin/nostromo-launch-smoke --fixture clamped
```

    origin/main (before the fix)   splitsRatiosApplied 3 of 3 laid out, no error logged
    with the fix                   splitsRatiosApplied 1 of 3 laid out, two `.error` lines

That difference is the whole point of the fix stated as an observation: a
split that did not achieve its ratios must not be counted as having applied
them. Before, `splitsRatiosApplied` certified the exact failure this check
exists to catch as a success.

## Code-pane render audit

`CodeContentView`'s gutter (`LineNumberRulerView.drawHashMarksAndLabels`)
measures itself on every draw pass and judges whether the pass was healthy
(`CodePaneRenderAudit`, in `macOS/Nostromo/UI/CodePaneRenderAudit.swift`). This
exists to catch a bug where the gutter paints correct line numbers over a
completely blank text body; see
`.claude/plans/instrument-code-pane-render-diagnostics.md` for the original
investigation and
`.claude/wip/w3-detail-region-ruler-overdraw-root-cause/index.md` for the one
that finally caught it.

The audit never fires unless the ruler painted at least one label **and** the
text storage is non-empty — absent either, there is no evidence either way and
the verdict is `healthy`. Given both, these terms are checked:

| Term | Fires when | Catches |
| --- | --- | --- |
| `text container used width is <= 0` | `containerUsedWidth <= 0` | a collapsed text container |
| `document view width is <= the gutter's rule thickness` | `documentViewWidth <= ruleThickness` | a document view no wider than its own gutter |
| `clip view width is <= 0` | `clipViewWidth <= 0` | a scroll view with no viewport |
| `the gutter filled a rect wider than its own rule thickness` | `gutterFillWidth > ruleThickness` | a tautological safety net now that the fill is clipped at the source (`rect.intersection(bounds)` plus `clipsToBounds = true`) — `gutterFillWidth` can never exceed `ruleThickness` in the shipped app. The real regression guard for **the confirmed W3 cause** (a gutter painting over the body and the tab strip above it) is `CodeContentViewTests.testDrawHashMarksAndLabelsFillsOnlyItsOwnBoundsNeverTheRawDirtyRect`, a source-scraping test that fails if the unclipped fill ever comes back. |
| `document view height is less than the height of the text it laid out` | `documentViewHeight + 1 < containerUsedHeight` (and `containerUsedHeight > 0`) | a document view too short to paint the text it actually laid out — **not** a document view shorter than its viewport, which is the ordinary case for a short file or diff hunk in a tall pane (an earlier version of this term compared against the clip view and was a confirmed false positive on every healthy short document) |
| `text storage is too short to hold even one character per row` | `rowCount > 1 && textStorageLength <= rowCount - 1` | an all-blank-lines document that reads healthy on every geometry term |

`gutterFillWidth` is the width the ruler *actually filled*
(`rect.intersection(bounds).width`), never the raw dirty rect AppKit supplies —
that rect legitimately spans the whole scroll view, so reporting it would make
this term fire on every healthy pane and catch nothing. The 1pt tolerance on the
height term and the `rowCount > 1` guard on the plausibility term are there for
the same reason: a tripwire that fires on a healthy pane is worse than no
tripwire.

If a pass looks unhealthy (real content, real gutter, but the text view
wasn't capable of painting it), the app:

1. Logs one line to the `codepane` log category (subsystem
   `com.hammer.nostromo`), rate-limited to once per distinct verdict per
   pane.
2. Attempts a one-shot recovery (re-asserts the text container's width and the
   text view's minimum height from the clip view, forces layout, requests a
   redisplay). Whether the pane recovers is itself diagnostic evidence about
   which geometry hypothesis is in play.

Two lines are emitted **unconditionally**, not only on an unhealthy verdict,
because a field that is only logged when something is already known to be wrong
is useless for telling apart hypotheses about *why*:

- one per document push — `code pane document pushed kind=… rows=…
  textStorageLength=… textKitDowngraded=…`
- one whenever `textKitDowngraded` changes — at most once per pane, when the
  ruler's first `layoutManager` access downgrades the text view to TextKit 1.

Counts, flags and geometry only; never pane content.

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

## The `transcript` log category

`ReplView.swift`'s own category, `com.hammer.nostromo` / `transcript`, for
the cost of laying a turn out.

```sh
log show --predicate 'subsystem == "com.hammer.nostromo" AND category == "transcript"' \
  --last 1h --info
```

Two things live here:

- An `os_signpost` interval named `measure` around **every**
  `ReplView.measure()` call, always on. Open the log in Instruments'
  points-of-interest track to see measurement cost against the rest of the
  timeline.
- One `.error` line per `measure()` call that takes longer than
  `ReplView.measureBudgetSeconds` (250 ms — the same budget
  `makeTurnView`'s hydration comment measures itself against):

  ```
  slow measure: tag=perri turn=4182 blocks=164 subviews=1300 constraints=983
                reason=remeasure elapsed=9964.7ms budget=250ms
  ```

  `reason` distinguishes `materialize` — a turn entering the viewport for
  the first time — from `remeasure`, a turn whose blocks changed while it
  was already materialized. They fail differently: `materialize` is paid
  once per turn, `remeasure` is paid again on *every* streamed block, and
  it was `remeasure` the 2026-09-09 freeze sat in. `subviews` and
  `constraints` are walked only on this already-slow path, never on the
  fast one.

Why it exists: before 2026-09-10 `measure()` carried no instrumentation of
any kind, so a call that took three and a half minutes and a call that took
three milliseconds were indistinguishable from every counter and every log
this app had. Diagnosing the beachball needed a live `sample` of the running
process. See
`.claude/bugs/resolved/2026-09-09-replview-s-auto-layout-measurement-pass-can-peg-the-main-thread-indefinitely-on-a-large-turn.md`.

Counts, ids and durations only. No turn content is ever written.

### The matching counters

`TranscriptDiagnostics` reports the same thing numerically, so a run can be
graded without reading a log. Per pane:

- `slowMeasures` — how many `measure()` calls blew the budget in this pane's
  lifetime.
- `worstMeasureMs` — the worst single call, reported even when nothing was
  slow, so a healthy run says how much headroom it actually had.

And once per report line, `measureBudgetMs`: the budget **the build itself
used**, so `macOS/scripts/transcript-load-report.py`'s `measure-budget` row
grades against that rather than a number copied into the script.

Neither counter is visible from turn or view counts: during the freeze the
pane held a perfectly ordinary number of turns and materialized views the
entire time, so memory, materialization and retention all read green.

## The `wire` log category

A third category on the same subsystem, for the wire decoders in
`macOS/Nostromo/Data/Models.swift` and
`Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift`.

```sh
log show --predicate 'subsystem == "com.hammer.nostromo" AND category == "wire"' \
  --last 1h --info
```

These decoders are deliberately lenient — a `PaneTree` node kind, an `Anchor`
kind or an `Emphasis` kind newer than the running client must not throw out of
a decoder and take the whole `pane_content` message down with it. Leniency that
is also *silent*, though, leaves the operator unable to tell "the daemon sent
nothing" from "this client threw away what it was sent". So whenever a lenient
decoder drops something, it says so here:

```
pane address dropped 1 of 2 emphasis element(s) it could not decode
```

Counts only, never content. Rare by construction — it fires only against a
daemon shipping a vocabulary this client build predates, which in practice
means "you forgot to rebuild the app after changing the wire protocol."

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

## `NOSTROMO_LOAD_BIG_TURN_BLOCKS`

```sh
NOSTROMO_LOAD_BIG_TURN_BLOCKS=160
NOSTROMO_LOAD_BIG_TURN_TABLE_ROWS=60   # default 60
```

Makes `TranscriptLoadHarness` deliver **one deliberately-large turn** — N
alternating tool-call/tool-result blocks, a findings card and a markdown
table — before its ordinary traffic, streamed a block at a time so each
append re-measures the turn.

The rest of the harness drives five thousand *small* turns, which is the axis
that was always fast. Nothing had ever driven one large turn, which is why
`ReplView.measure()`'s superlinear region went untested until it froze the
app. Grade a run with the `measure-budget` row of
`macOS/scripts/transcript-load-report.py`:

```sh
NOSTROMO_LOAD_BIG_TURN_BLOCKS=160 macOS/scripts/transcript-load-test.sh 2000 1
```

Unset (the default), the harness behaves exactly as before.

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

`bin/nostromo-launch-smoke`'s `split-ratios-applied` detector consumes
`splitNodesRendered`/`leavesRendered` together with `splitsLaidOut`/
`splitsRatiosApplied` as a requested-vs-rendered shape check, not just as
independent scalars: it corroborates, per diagnostics row, that the number
of splits and leaves the app actually rendered agrees with some whole
multiple of the fixture's own per-focus shape, and that every rendered
split both laid out and applied its ratios — rather than trusting a single
"at least one split applied" count that a fully-rendered-but-partially-
applied tree (e.g. an outer split whose `setPosition` never returned while
an inner split's did) could satisfy on its own.

## Daemon-side diff/code payload logging

`src/mcp/tools/apply_layout.rs` logs one line (via `tracing::info!`) every
time it builds a `PaneContentWire::Diff` or `PaneContentWire::Code` payload —
file/hunk/line counts and byte lengths, never content. Cross-referencing this
against the client's `codepane` log or a `NOSTROMO_PANE_DUMP` capture is what
turns "the daemon probably didn't send something empty" into "the daemon
logged N rows and the client received exactly N rows."
