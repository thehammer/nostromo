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
| `windows` | index, title, frame, fullscreen, key, first responder |
| `tree` | nested view dump: class, frame, text, tooltip, label |
| `find TEXT` | views whose text/tooltip/label/class contains TEXT, with centre points |
| `click` | by `X Y` or `--text`; the reply says which view class was hit |
| `drag` | press at `X Y` (or `--text`), drag in steps to `--to X Y`, release — for selecting text |
| `hittest X Y` | **read-only, sends no event** (may complete a layout pass AppKit already had pending): which view a click at X Y would hit, plus the chain of views from it up to the content view and the focus state (see below) |
| `transcript-anchor [--focus TAG]` | **read-only, sends no event, no focus change**: the transcript's first visible block (`turnKey`, `itemKey`, `offsetPt` from the viewport top), `bottomOffsetPt` (0 at the bottom) and `following`; the scroll-safety gate compares two snapshots (≤ 1 pt) |
| `key` / `type` | key event through `NSApp.sendEvent` (menu shortcuts fire) / insert text at the first responder |
| `paste` | put an image or text on the clipboard and send `paste:` |
| `drop` | deliver a file drop to the registered drag destination under a point |
| `screenshot` | PNG of a window's content view (no Screen Recording permission needed) |

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
(`staleEvent`).

What the daemon checks on its side (only the pinned, installed app may answer
at all) is in [`operator-app-trust.md`](operator-app-trust.md).

**QA-only switch.** An isolated QA build may accept synthetic input on those
controls when it is launched with `NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1` **and**
its bundle id is not `com.hammer.nostromo`. The user's app never honours it.

## Limits

Windows must be on-screen and awake: with displays locked or asleep the
windows stay at alpha 0 and layout/screenshots are unreliable (`windows`
reports `alpha` and `visible`).


Drags are delivered to the destination view directly rather than through the
window server, so cross-app drag mechanics (promised files, drag images) are
not exercised. Screenshots render the view hierarchy, not the compositor.
