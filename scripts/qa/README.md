# QA scripts

Scenario scripts that drive the **real, running** Nostromo through its app-control socket
(`bin/nostromo-app`, see [`docs/app-control.md`](../../docs/app-control.md)). A human or an agent
runs one and reads the PASS/FAIL lines.

| script | what it checks | touches |
|---|---|---|
| `teri-fred-smoke.sh` | Teri tabs, legibility, list → detail, the Send to agent sheet (cancel path), Fred panes, sidebar badges | UI only: focus switch, tab clicks, row selection, opening and cancelling one sheet |
| `window-placement-check.sh` | one fullscreen window per display, none sharing a display, the last launch's placement log | nothing (reads `windows` and the log) |
| `attach-chip.sh`, `mother-tabs.sh`, `mother-queue.sh` | older scenarios; `mother-*` need the fake Mother broker (see their headers) | UI clicks / drops |

## Running them

The socket is **opt-in** and the scripts never enable it. If it is off they print how to turn it on
yourself and exit 2:

    defaults write com.hammer.nostromo AppControlEnabled -bool true   # then relaunch Nostromo

    scripts/qa/teri-fred-smoke.sh
    QA_SCREEN=Sceptre scripts/qa/teri-fred-smoke.sh     # the window on that display
    scripts/qa/window-placement-check.sh

`teri-fred-smoke.sh` **takes keyboard focus briefly** (`activate`, then `restore` on exit, also on
Ctrl-C or a crash of the script) because AppKit ignores clicks on a non-key window. Run it when nobody
is typing. It also selects the Teri and Fred focuses and puts the previously active focus (and Teri
tab, when it can tell which it was) back on exit.

| env | effect |
|---|---|
| `QA_SCREEN` | test the window on the display whose name contains this (default: the window showing Teri, wherever it is) |
| `QA_LOADING_TIMEOUT` | seconds a tab may sit on "Loading" before it FAILs (default 20) |
| `QA_INCLUDE_PICKS=1` | also click the Picks tab. **Off by default**: the first open of the day starts a paid picks generation (up to $2) |
| `QA_PLACEMENT_LOG` | placement log to read (default `~/.nostromo/logs/window-placement.log`) |
| `QA_APP` | the app-control CLI to use (the self-test points it at a fake) |

Selecting the Teri focus opens the tab it was last left on. If that is Picks and today's picks are not
made yet, the app starts its own first-open generation, exactly as if you had opened Teri by hand. To
avoid it, leave Teri on another tab first.

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
* Step ids: `a` reachable/daemon, `b` focus, `c` tabs, `d` legibility, `e` list → detail, `f` Send to agent
  sheet, `g` Fred, `h` sidebar badges.

## What is guaranteed read-only

* All traffic goes through `lib/appctl.py`: only `ping`, `windows`, `tree`, `find`, `click`, `key`,
  `hittest`, `screenshot`, `activate`, `restore` are reachable (no `type`, `paste`, `drop`, `drag`).
* Clicks refuse any button named Start, Send to agent, Open in…, Open in Outlook, Ask Fred, Prep with
  Fred, Refresh picks, Retry, Go to existing…, Create another and the like.
* Keys are limited to ⌘⇧S (open the sheet), Return / ⌘Z / delete (only after `hittest` proves the
  instruction text view has the keyboard: plain Return anywhere else in that sheet would confirm the
  send) and Escape. Start is never pressed, ⌘Return is never sent.
* If the sheet is still open when the script exits it sends Escape to it (Cancel), nothing else.
* Item titles are cut to 60 characters in the output and never written to a file. Screenshots go in a
  `mktemp -d` directory that is removed on exit. No config or credential file is read.

### UI state it does change

"Read-only" means no external mutation; the app remembers some UI state, and a run leaves these behind:

* **Sentry's "new since last viewed" baseline** is reset when you leave the Sentry tab (the app stores
  the time). Visiting the tab is part of the check; it cannot be put back. Skip it by not running the
  script when you are waiting on that marker.
* **The selected item on each Teri tab** and the selected Fred row (and its open detail) stay selected.
* The previously active focus is selected again on exit, and the Teri tab put back when the screenshot
  made it clear which one it was (never Picks: reopening it can start a generation, so it says so).
* `activate` makes the tested window key. If Nostromo was already frontmost, `restore` cannot hand the
  key window back, so on a multi-display setup the key window may differ afterwards.
* A sheet that was already open when the run started blocks every click: the script reports that, does
  nothing to it, and stops.

## How it decides

* **Legibility (`d`)**: screenshot the window, locate each tab button and list-toolbar control from the
  `tree` frames (never fixed pixels), take the control's most common colour as its surface and the
  label's colour from its pixels, and compute the WCAG contrast ratio: FAIL below 3:1, WARN below
  4.5:1. It runs with the window key and again after `restore` (app inactive), because the Light-mode
  bug only showed in the inactive state. If the app was already frontmost, `restore` cannot make it
  inactive and the inactive pass is skipped with a WARN. The PNG is decoded with `zlib` only.
* **Tab selection (`c`)**: the tree does not expose a button's pressed state, so a click is proven by
  hitting an `NSButton` and the pane switching (Picks view vs list). Which tab was selected before the
  run is read from the screenshot (the pressed tab is a filled pill); when that is ambiguous the tab is
  not restored.
* **Enabled state (`e`)**: the tree has no `enabled` flag yet. "Open in…" is enabled when it has no
  tooltip (the app puts the disabled reason there); "Send to agent…" is judged by its title. The script
  uses an `enabled` field if the app ever reports one.
* **Window placement**: window frames and display names come from `windows`; display geometry and the
  final `window.screen` per window from the last launch in the log. `FINAL (NOT on target)`, "gave up",
  "giving up" and "retry exhausted" lines FAIL.

## Still manual

* Picks first-open generation (costs up to $2) and the Refresh button.
* Send to agent to a real focus or Mother job (the script stops at Cancel).
* Jira and Sentry credential flows, Fred's Microsoft sign-in, Open in Outlook / Ask Fred / Prep with Fred.
* VoiceOver and IME composition in the instruction field.

## Self-test

    make qa-selftest        # also part of `make python-test` and CI

`scripts/qa/tests/` runs both scripts against a fake `nostromo-app` (`fake_nostromo_app.py`) with canned
trees, windows and generated PNGs: a healthy app, a "Coming soon" tab, a tab stuck on "Loading",
dark-on-dark labels (active and inactive), a missing socket, a sheet that ignores Escape, a Return that
would not land in the text view, and the placement-log cases. It never touches a real app. The live
behaviour (real view structure, timing, the screenshot colours) is checked by running the scripts
against a real Nostromo.
