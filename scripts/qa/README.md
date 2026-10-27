# QA scripts

Scenario scripts that drive the **real, running** Nostromo through its app-control socket
(`bin/nostromo-app`, see [`docs/app-control.md`](../../docs/app-control.md)). A human or an agent
runs one and reads the PASS/FAIL lines.

| script | what it checks | touches |
|---|---|---|
| `teri-fred-smoke.sh` | Teri tabs, legibility, list → detail, the Send to agent sheet (cancel path), Fred panes, sidebar badges | UI only: tab clicks (never Picks, never Sentry unless asked), row selection, opening and cancelling one sheet; switches to Teri only when told to |
| `window-placement-check.sh` | one fullscreen window per display, none sharing a display, the last launch's placement log | nothing (reads `windows`, the log, and `system_profiler SPDisplaysDataType -json`) |
| `mother-crew.sh` | the Mother panel's crew view: a crew job's progress line, gate rows (with exit code on a failed gate) and lens wave (skipped lens in words, citations found) update live from a replayed fixture, and no ambiguous layout in the pane; reads VoiceOver text, not glyphs | needs the fake broker (`--scenario crew_gates`) and a QA build on it; clicks the Mother entry and two jobs; takes keyboard focus for the run and gives it back; resets and replays the fake broker's jobs (sends the real Mother nothing) |
| `mother-hold.sh` | the PRD's "gate-exhausted hold": a held job shows Mother's four option buttons with their consequence text; with guidance typed, a click on "Resume with guidance" sends exactly one `answer {job, option, source: nostromo_app, text}` and the job leaves AWAITING. `QA_EXPECT_GATE=refused` is the negative run: the app launched WITHOUT `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1` must send nothing for the same click (the live proof that the human-gesture gate is on) | needs the fake broker (`--scenario crew_hold`) and a QA build on it, launched with `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1` for the default run and without it for the `refused` run (the script cannot toggle it on a running app); takes keyboard focus for the run and gives it back; resets the fake broker (sends the real Mother nothing) |
| `approvals-card.sh [--no-synthetic] [FIXTURE ...]` | the approval card (AP2a) in the **isolated QA instance only** (`qa-instance.sh`; never the user's app, daemon or sessions): per fixture (`simple_rm`, `heredoc_300`, `bidi` by default) types `FIXTURE:<name>`, lists the card with `approvals list`, checks `transcript-anchor` before/after (≤ 1 pt, bottom offset 0 while following), and with synthetic input ON clicks "Allow once" and reads the fake CLI's log (`allow`, input unchanged); with `--no-synthetic` checks that click/Return/Space (for a gated card: the exact Deny button and Return/Space) are refused, the card stays and the QA approvals dir has a `refusal` entry (`app_control`). The `ask_user_question` fixture (AP2c, not in the default list: `approvals-card.sh ask_user_question`) is the AskUserQuestion form: with synthetic input ON it clicks Postgres, Caching, Tracing and Submit and the fake CLI's log must show `allow` with `updatedInput.answers` and the questions unchanged; with `--no-synthetic` a synthetic option click must be refused (nothing chosen, `refusal` entry with `app_control`). Exits 3 (INCONCLUSIVE) when the display is locked | the QA clone's own window only: creates one QA agent session in the QA daemon (a focus on the fake CLI), clicks its sidebar row, then a click in its composer, typed text, Return, a click on Allow/Deny; needs a logged-in awake display |
| `tracker-discoverability.sh [--dry-run] [--runs N]` | **user-run only, spends model tokens** (PRD 26/28): per agent (generic, Claudia), N fresh `qa-tracker-<n>` focuses on a cheap model are told "keep a tracker of what we're doing"; each must leave a `.claude/wip/*/index.md` board and have ≤ 1 ToolSearch before the tracker call; prints `n/N` per agent. `--dry-run` prints the plan and starts nothing. See `docs/mcp/tracker.md` | the isolated QA instance only (started with `NOSTROMO_QA_CLAUDE_BIN` = a real `claude`); types into the QA window |
| `terminal-local.sh [--skip-negative]` | the terminal pane (slice 1d) in the **isolated QA instance only**: Cmd-T opens a terminal with the keyboard in it; typing echoes; truecolor; `seq 1 12000`; `vim` and `:q`; latency numbers from the unified log; `exit 3` shows the overlay, Restart brings the shell back, `exit` removes the pane; a terminal an agent opens through the QA daemon's MCP socket does not take the keyboard. Then the `--no-synthetic` negative case: synthesized `type`, shift-cmd-W and the x do nothing and `$QA_ROOT/home/.nostromo/audit/terminal.jsonl` has `refused` with channel `app_control`. Reads the screen through the view's accessibility value (`nostromo-app ax NostromoTerminalView`), which carries text only in this QA build (the real app returns none, and the negative run checks that). Exits 3 (INCONCLUSIVE) on a locked display | the QA clone's own window and the QA daemon's terminals only; takes keyboard focus for the run; needs a logged-in awake display |
| `attach-chip.sh`, `mother-tabs.sh`, `mother-queue.sh` | older scenarios; `mother-*` need the fake Mother broker (see their headers) | UI clicks / drops |

### `approvals-card.sh`: the QA session, evidence and env knobs

Robustness (QSR): cards are denied with the card's own exact "Deny"
button (located in `ctl tree` inside the card and clicked by coordinates, never a `--text "Deny"` substring that could
hit "Deny & stop"); after every Deny the request must be gone and the QA session's sidebar row must survive (if it
vanished the run FAILs loudly).
Each fixture waits for the card whose `input` starts with the fixture's first command line cut at its first non-ASCII
character (from `tests/fixtures/approvals/<name>.json`); a prefix shorter than 4 characters selects by exact full
input instead; two matching cards are "ambiguous card selection" (FAIL), never picked by position. "Allow once" is
clicked only once `enabled:true` (up to 20 s; a timeout FAILs naming the label seen). `heredoc_300` must stay gated
("Scroll to the end to allow") after a synthetic End key; the script first clicks into the card's text view, reads
the first responder with the read-only `hittest` and prints it ("key target: ..."), and sends End only if the card
text view would receive it (otherwise FAIL: "stays gated" would prove nothing).

Text-drawn proof (pixels): the card's text viewport (the `NSClipView` inside the card's `ApprovalInputView`, from
`ctl tree --depth 40`, matched to the card by its first line; it excludes the line-number gutter) is cropped out of
`ctl screenshot` (PNG decoded with `zlib`/`struct` only; points scaled to pixels by PNG width / window content
width) and must hold at least 40 pixels whose luminance differs by more than 60/255 from the viewport's modal
background, in the whole viewport and in the first line's band. A blank text area FAILs "text not drawn: the card's
text area is blank (model has N lines)"; an unreadable or corrupt PNG FAILs "could not read screenshot"; a card text
view that cannot be located FAILs "cannot locate the card text area" and prints a tree excerpt. Nothing passes by
fallback. `ctl find` for the first 12 ASCII characters of the card's rendered first line (cut at the first
non-ASCII/invisible character, so the bidi fixture's probe is `echo `) is a secondary "text in view tree" check,
required to hit a view overlapping the card; it matches model text, not glyphs, which is why the pixels decide.
Screenshots, trees and listings go to a private `mktemp -d` directory (mode 0700, printed at the start, removed at
the end unless `KEEP=1`); fixture names must match `[a-z0-9_]+` (exit 2 otherwise). One `SUMMARY` line per fixture.

Round 3 behaviour:

* **Which fake-CLI log.** The daemon starts the fake CLI several times (a catalog probe, then the session), each in
  its own `home/.nostromo/fake-claude/<pid>/`. The allow check scans every `fake-claude/*/stdin.jsonl` under the QA
  root for the fixture's cue (`FIXTURE:<name>`) and reads that directory's `responses.jsonl` (the newest such
  directory; the newest non-empty log if no stdin has the cue), polling up to 5 s. For `simple_rm` it needs
  `behavior: allow` and `updatedInput.command` equal to the card's input. (`card_checks.py fakelog`.)
* **Composer focus.** Before every cue the script waits for no pending card, clicks the "Message…" field and polls
  `hittest` until the first responder is the chat composer (`ChatTextView`): up to 3 clicks in 10 s. If it never is,
  that fixture FAILs and the message names the first responder it saw (e.g. `NostromoWindow`). It never uses `activate`.
* **Every fixture runs in its own QA instance (one QA instance per fixture), in both modes.** Composer state and pending cards never leak
  across fixtures (after `heredoc_300` was Denied the composer once never regained focus for `bidi`): each fixture
  starts a fresh instance and stops it (isolation guard run) before the next; the verdict is aggregated. With
  `--no-synthetic` it checks per fixture: the card appears, its text is drawn (pixel proof), and synthetic answers
  are refused with a `refusal` audit entry (channel `app_control`). For an enabled Allow once those are a click on
  "Allow once", Return and Space. A GATED card (Allow once disabled, "Scroll to the end to allow", e.g. `heredoc_300`,
  which also reports "Allow label gated") makes no answer attempt on those presses, so the refusal evidence comes
  from the card's exact **Deny** button (`click_card_button`) plus Return/Space with the card text view focused; the
  card must still be pending afterwards.
* **Allow check details.** The cue matches as a whole word (`FIXTURE:simple_rm` never matches `FIXTURE:simple_rm2`);
  the LAST `behavior` must be `allow` (an allow followed by a deny FAILs); if no `stdin.jsonl` holds the cue the
  newest non-empty log is used, "fallback log used" is printed and the allow check FAILs.
* **Output.** Every exit path (a failed fixture, an aborted instance, an inconclusive display, an unexpected script
  error) prints one `SUMMARY <fixture>: ...` per fixture (`FAILED` for a fixture that ran and failed, `ABORTED: <reason>` for those that did not run) and a final
  `RESULT: PASS|FAIL|INCONCLUSIVE (synthetic input on|OFF)`, then the DEBUG EVIDENCE collected along the way. Exit
  codes: 0 PASS, 1 FAIL, 2 usage, 3 INCONCLUSIVE.

Pure checks live in `lib/card_checks.py` (tests: `tests/qa_instance/test_card_checks.py`).

The QA app has only the built-in foci (Fred, Mother, Perri, Teri); the composer exists only inside an agent
session. After `start` (and once the windows are visible) the script runs `qa-instance.sh focus`: it asks the QA
daemon, over `<QA_ROOT>/mcp.sock`, to `nostromo.create_focus` a session titled "QA approvals" whose CLI is
the fake claude (`NOSTROMO_CLAUDE_BIN`). The daemon announces the focus to the app, the script waits for the
sidebar row, clicks it and waits for the composer (`Message…`) before the first cue. The helper
(`qa_instance.py`, `guard_socket_path`) refuses any socket that does not resolve to a path inside the
QA root (also through `..` or a symlink), so it cannot reach the user's daemon.

| env | effect |
|---|---|
| `KEEP=1` | keep the QA root after the run (`stop` deletes it otherwise), so the logs under it survive. An isolation failure keeps it too: delete it by hand afterwards |

On any FAIL (and on an INCONCLUSIVE) the script prints, after the RESULT line: `ctl windows`, `ctl tree --depth 3` (first 120 lines),
the last 40 lines of `nostromd.log` and of `home/.nostromo/logs/window-placement.log`, and a listing of the QA
approvals dir. If only the isolation guard failed, the app is already gone, so you get the logs and the listing.

**The isolation guard and the user's audit log.** The user's real daemon appends to its own
`~/.nostromo/approvals/audit-YYYY-MM-DD.jsonl` whenever real agent traffic asks for an approval during a run.
Append-only growth of such a file (and a new dated `audit-*.jsonl`) does not fail the guard. Any other change in
`~/.nostromo/approvals/` does (a changed prefix, a shrink, a deleted audit file, any other new or changed file), and so
does an appended line that mentions the QA root path, `FIXTURE:` or the bundle id `com.hammer.nostromo.qa`.
The snapshot keeps only each file's length and a SHA-256 of its bytes, never its content, and a failure names the
file and the kind of marker, never the line.

**The app's home.** The clone resolves `~/.nostromo` through `NostromoHome` (`macOS/Nostromo/Data/NostromoHome.swift`),
not `FileManager.homeDirectoryForCurrentUser`, which ignores `HOME` (the system user database decides) and once let
the clone write its focus and placement log into the user's real `~/.nostromo`. The script sets
`NOSTROMO_QA_HOME=<qa_root>/home`; the helper honours it only for the bundle id `com.hammer.nostromo.qa` and only for
an existing absolute directory, so the real app can never be redirected by its environment.
The guard also scans the other top-level `~/.nostromo/*.json` and `~/.nostromo/logs/*.log` files that changed during
the run: a change fails only if the new bytes mention the QA root path, `FIXTURE:`, the QA bundle id, `cody-qa-` or
`qa-approvals` (the real app legitimately writes those files); `focuses.json` fails on any change.
`approvals-card.sh` refuses to start (exit 2) when the real `~/.nostromo/focuses.json` already carries such a marker.

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
