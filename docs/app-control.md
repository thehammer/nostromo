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
| `key` / `type` | key event through `NSApp.sendEvent` (menu shortcuts fire) / insert text at the first responder |
| `paste` | put an image or text on the clipboard and send `paste:` |
| `drop` | deliver a file drop to the registered drag destination under a point |
| `screenshot` | PNG of a window's content view (no Screen Recording permission needed) |

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

Pair with `bin/fake-mother-broker` (launch the app with `MOTHER_BROKER_SOCK`)
to drive Mother-queue UI with canned jobs.

## Limits

Windows must be on-screen and awake: with displays locked or asleep the
windows stay at alpha 0 and layout/screenshots are unreliable (`windows`
reports `alpha` and `visible`).


Drags are delivered to the destination view directly rather than through the
window server, so cross-app drag mechanics (promised files, drag images) are
not exercised. Screenshots render the view hierarchy, not the compositor.
