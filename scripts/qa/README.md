# QA scripts

Scenario scripts that drive the **real, running** Nostromo through its app-control socket
(`bin/nostromo-app`, see [`docs/app-control.md`](../../docs/app-control.md)). A human or an agent
runs one and reads the PASS/FAIL lines.

| script | what it checks | touches |
|---|---|---|
| `teri-fred-smoke.sh` | Teri tabs, legibility, list → detail, the Send to agent sheet (cancel path), Fred panes, sidebar badges | UI only: tab clicks (never Picks, never Sentry unless asked), row selection, opening and cancelling one sheet; switches to Teri only when told to |
| `window-placement-check.sh` | one fullscreen window per display, none sharing a display, the last launch's placement log | nothing (reads `windows`, the log, and `system_profiler SPDisplaysDataType -json`) |
| `mother-crew.sh` | the Mother panel's crew view: a crew job's progress line, gate rows (with exit code on a failed gate) and lens wave (skipped lens in words, citations found) update live from a replayed fixture, and no ambiguous layout in the pane; reads VoiceOver text, not glyphs | needs the fake broker (`--scenario crew_gates`) and a QA build on it; clicks the Mother entry and two jobs; takes keyboard focus for the run and gives it back; resets and replays the fake broker's jobs (sends the real Mother nothing) |
| `attach-chip.sh`, `mother-tabs.sh`, `mother-queue.sh` | older scenarios; `mother-*` need the fake Mother broker (see their headers) | UI clicks / drops |

## Running them

The socket is **opt-in** and the scripts never enable it. If it is off they print how to turn it on
yourself and exit 2:

    defaults write com.hammer.nostromo AppControlEnabled -bool true   # then relaunch Nostromo

    scripts/qa/teri-fred-smoke.sh
    QA_SCREEN=Sceptre scripts/qa/teri-fred-smoke.sh     # the window on that display
    scripts/qa/window-placement-check.sh

`teri-fred-smoke.sh` **takes keyboard focus briefly** (`activate`, then `restore` on exit, also on
Ctrl-C, `kill` or a crash of the script: the wrapper `exec`s python, so the signal lands on the process
whose `finally` puts everything back) because AppKit ignores clicks on a non-key window. Run it when
nobody is typing. It activates the window only when it is about to click, never before it has read what
is on screen.

| env | effect |
|---|---|
| `QA_SCREEN` | test the window on the display whose name contains this (default: the window showing Teri, wherever it is) |
| `QA_LOADING_TIMEOUT` | seconds a tab may sit on "Loading" before it FAILs (default 20) |
| `QA_ALLOW_TERI_SWITCH=1` | switch to Teri when it is not the active focus. **Off by default**, see below |
| `QA_INCLUDE_SENTRY=1` | also click the Sentry tab. **Off by default**: leaving it resets the "new since last viewed" markers |
| `QA_PLACEMENT_LOG` | placement log to read (default `~/.nostromo/logs/window-placement.log`) |
| `QA_SYSTEM_PROFILER` | `system_profiler` to count attached displays with (default `system_profiler`; the self-test points it at a fake) |
| `QA_APP` | the app-control CLI to use (the self-test points it at a fake) |

### What it will and will not do to Teri

Selecting the Teri focus opens the tab it was last left on. If that is Picks and today's picks are not
made yet, the app starts a generation (up to $2), and the same can happen when its window becomes key.
Leaving Sentry resets its markers. So:

* **Teri is not the active focus** and `QA_ALLOW_TERI_SWITCH` is not set: it prints
  `SKIP teri-fred: Teri is not the active focus (switching may start a paid Picks generation; ...)`, does not
  click the Teri row, and runs only Fred and the sidebar badges.
* **Teri is the active focus on Todos, Jira or Repo docs** (read from the screenshot: the pressed tab is a filled
  pill): the full run. It clicks only those tabs (and Sentry with `QA_INCLUDE_SENTRY=1`) and puts the tab back.
* **Teri is the active focus on Picks, on Sentry (without the opt-in), or on a tab it cannot identify**:
  passive mode. Not one click, no `activate`, no focus switch (so no Fred step: switching away and back could
  start a generation or reset Sentry). It still checks the daemon banner, the tab titles and the badges, and says so.
* **Teri was switched to with `QA_ALLOW_TERI_SWITCH=1` and opened on one of those tabs**: no tab clicks and no
  legibility/row/sheet steps; Fred and the badges still run and the previous focus comes back. (The switch itself
  is the thing you opted into: if that tab was Picks the app may have started its own generation.)
* **The Picks tab is never clicked and no Picks row is ever selected**; its title is checked without a click.

### Reading the output

    PASS c.todos: title 'Todos 12' (count 12)
    FAIL c.jira: title is 'Jira ○ Coming soon': the tab is still a placeholder
    WARN d.legibility[inactive]: tab 'Sentry': contrast 3.8:1 (label #7a7a7a on #1e1e1e); needs 3:1, 4.5:1 preferred
    INFO c.sentry: banner: Sentry: no credentials found...
    SUMMARY: 31 pass, 1 fail, 1 warn, 6 info

* `FAIL` fails the run (exit 1); the script keeps going to report everything.
* `WARN` is worth a look and does not fail. `INFO` is context: a source's own state (no Jira or Sentry
  credentials is the user's business, not a failure; a source stuck on "Loading" is).
* Exit 2: app-control unreachable. Nothing was tested.
* `SKIP` is a step that was deliberately not run (and why). The smoke's `SUMMARY` line ends with
  `| left changed: ...`, naming exactly the UI state it could not put back, or `nothing`.
* Step ids: `a` reachable/daemon, `b` focus, `c` tabs, `d` legibility, `e` list → detail, `f` Send to agent
  sheet, `g` Fred, `h` sidebar badges.

## What is guaranteed read-only

* All traffic goes through `lib/appctl.py`: only `ping`, `windows`, `tree`, `find`, `click`, `key`,
  `hittest`, `screenshot`, `activate`, `restore` are reachable (no `type`, `paste`, `drop`, `drag`), and
  `click` / `key` only through the guarded methods.
* **Clicks are an allow-list, not a deny-list.** Every click names its kind (a sidebar row, one of the
  allowed tabs, a list row, a Fred row, the Send sheet's "What will be shared" toggle or its instruction
  text view). Immediately before it is sent the app is asked what is under the point (`hittest`: it sends
  no event) and the click goes out only if the whole hit chain is what that kind declares: a tab click must
  hit that very tab button (same class and frame), a row click must hit a row with no button anywhere in
  the chain, a sheet click must hit the very toggle or text view it was aimed at. Anything else, including
  Start, Send to agent, Open in…, Ask Fred, Refresh picks, Retry, Copy code, is refused because it is not
  on the list. The sheet's controls are looked up again after the sheet changes layout and hit-tested
  first, so a stale frame cannot land on Start.
* Keys are limited to ⌘⇧S (open the sheet, never sent into a sheet), and Return / ⌘Z / delete / Escape
  (only into the sheet). Return is sent only straight after a fresh `hittest` proves the instruction text
  view has the keyboard: plain Return anywhere else in that sheet would confirm the send. Start is never
  pressed, ⌘Return is never sent.
* If the sheet is still open when the script exits (also after a signal) it sends Escape to it (Cancel).
* Fred: if the sidebar's Fred badge is a sign-in / unavailable text the Fred row is not even selected, and if
  Fred then shows its Microsoft 365 sign-in prompt nothing in it is clicked or read.
* Item titles are cut to 60 characters in the output and never written to a file. Screenshots go in a
  `mktemp -d` directory that is removed on exit (also after a signal). No config or credential file is read.
* `window-placement-check.sh` runs `system_profiler SPDisplaysDataType -json` (read-only) and reads the log;
  it writes nothing.

### UI state it does change

"Read-only" means no external mutation and no lost marker. The app does remember some UI state, and a run
can leave these behind. The `SUMMARY` line says which ones it actually did:

* **A row it selected.** On each tab that already has a row selected, no row is clicked (the selection stays
  as it was and the detail is tested as shown). On a tab with no selection the first row is selected to test
  list → detail and the Send sheet, and app-control cannot deselect it: the summary says
  `Jira: first row selected`. Same for the Fred row it opens (`Fred: Inbox first row open in detail`).
* **The Teri tab** is put back on the tab it was on (only ever Todos, Jira or Repo docs, or Sentry with the opt-in).
  If that fails the summary says so.
* **The active focus** is selected again on exit.
* `activate` makes the tested window key. If Nostromo was already frontmost, `restore` cannot hand the
  key window back, so on a multi-display setup the key window may differ afterwards.
* A sheet that was already open when the run started blocks every click: the script reports that, does
  nothing to it, and stops.

It does **not** reset Sentry's "new since last viewed" markers (the Sentry tab is not visited unless
`QA_INCLUDE_SENTRY=1`, and a run that would have to leave Sentry does not click at all) and does not touch the
Picks tab.

## How it decides

* **Legibility (`d`)**: screenshot the window, locate each tab button and list-toolbar control from the
  `tree` frames (never fixed pixels), measure only the part that can hold the label (the frame of the
  control's own text field when the tree has one, else the control minus its bezel, a pop-up's chevron and a
  search field's magnifier and cancel button, so a bright arrow cannot stand in for an invisible label),
  take the most common colour there as the surface and the label's colour from its pixels, and compute the
  WCAG contrast ratio: FAIL below 3:1, WARN below 4.5:1. It runs with the window key and again after `restore` (app inactive), because the Light-mode
  bug only showed in the inactive state. If the app was already frontmost, `restore` cannot make it
  inactive and the inactive pass is skipped with a WARN. The PNG is decoded with `zlib` only.
* **Tab selection (`c`)**: the tree does not expose a button's pressed state, so a click is proven by
  hit-testing that very `NSButton` first and the pane switching afterwards. Which tab was selected before
  the run is read from the screenshot (the pressed tab is a filled pill); when that is ambiguous no tab is
  clicked at all (it could be Sentry or Picks).
* **Enabled state (`e`)**: the tree has no `enabled` flag yet. "Open in…" is enabled when it has no
  tooltip (the app puts the disabled reason there); "Send to agent…" is judged by its title. The script
  uses an `enabled` field if the app ever reports one.
* **Window placement**: window frames and display names come from `windows`; display geometry and the
  final `window.screen` per window from the last launch in the log. `FINAL (NOT on target)`, "gave up",
  "giving up" and "retry exhausted" lines FAIL. Without a log the window count is compared with the number
  of attached displays from `system_profiler` (INFO when that is unavailable). A log whose last display
  topology is older than a hot-plug (`[screensDidChange]`) or a window created for a display it does not
  list is reported as INFO, and the live display count decides instead.

## Still manual

* The Picks tab (first-open generation costs up to $2) and the Refresh button; Sentry's "new since last viewed" markers (run with `QA_INCLUDE_SENTRY=1` only when you do not need them).
* Send to agent to a real focus or Mother job (the script stops at Cancel).
* Jira and Sentry credential flows, Fred's Microsoft sign-in, Open in Outlook / Ask Fred / Prep with Fred.
* VoiceOver and IME composition in the instruction field.

## Self-test

    make qa-selftest        # also part of `make python-test` and CI

`scripts/qa/tests/` runs both scripts against a fake `nostromo-app` (`fake_nostromo_app.py`) with canned
trees, windows and generated PNGs: a healthy app, a "Coming soon" tab, a tab stuck on "Loading",
dark-on-dark labels (active and inactive), a bright chevron over an invisible label, a missing socket, a
sheet that ignores Escape, a Return that would not land in the text view, a sheet layout that moves
between the tree and the click, a tab covered by an overlay, rows already selected, Teri on Picks or Sentry,
Teri not active, Fred signed out, SIGINT/SIGTERM/SIGHUP in the middle of a run (the previous focus,
`restore` and the open sheet are put back), and the placement-log cases. It never touches a real app. The live
behaviour (real view structure, timing, the screenshot colours) is checked by running the scripts
against a real Nostromo.
