# Activation audit (diagnostic)

Why: a Space switch away from Nostromo can be caused by an app activation or an
`orderFront`/`makeKeyAndOrderFront` on a window on another display. `ActivationAudit`
(`macOS/Nostromo/Data/ActivationAudit.swift`) records every such call so it can be correlated with the
external logger `scripts/debug/space-watch.sh` (`~/.nostromo-debug/space-watch.log`).

## Where the lines go

- `~/.nostromo/logs/window-placement.log`, scope `[activation]`
- unified log, subsystem `com.hammer.nostromo.mac`, category `WindowPlacement`, info level

```
log show --last 1h --predicate 'subsystem == "com.hammer.nostromo.mac"' | grep -i activation
```

## Line format

`reason=<call site/trigger> site=<file:line> [detail=<cmd=...>] caller=<in-app|agent-or-cli(app-control)>
appActive=<bool> keyDisplay=<display UUID|none> windows=[#<n>@<display UUID> visible=.. key=.. occ=<occlusionState raw>; ...]`

Timestamps are ISO-8601 UTC with milliseconds (the file) or the `log show` local time; `space-watch.log`
should be compared after converting to the same zone. Never logged: window titles, text, conversation ids,
app-control arguments (only the command name).

- `reason=` lines with a `site=` are emitted immediately BEFORE an activate / order-front call.
- Event lines (no `site=`): `didBecomeActive`, `didResignActive`, `activeSpaceDidChange`,
  `didChangeScreenParameters`, `window.didChangeScreen`, `window.didChangeOcclusionState` (Nostromo windows only).
- `caller=agent-or-cli(app-control)` means the call ran inside an app-control request (an agent or CLI client),
  not a person using the UI.

Reading it: find the Space switch time in `space-watch.log`; a `reason=` line within a few hundred ms
before it means Nostromo asked for it. A `didResignActive` / `activeSpaceDidChange` / `didBecomeActive`
with no preceding `reason=` line means something outside Nostromo (or AppKit itself) did ONLY if the
triggering call is not in the covered list below; otherwise suspect a call that is missing a note.

## Coverage (every one has a `reason=` line BEFORE the call)

- App activation: `NSApp.activate`, `NSApplication.shared.activate`, `NSRunningApplication.activate`.
- Window ordering: `makeKeyAndOrderFront`, `orderFront`, `orderFrontRegardless`, `makeKey`, `makeMain`,
  `deminiaturize` (task window).
- Full-screen: every `toggleFullScreen` / `toggleFullScreenNow` (`NostromoWindow`, `WindowPlacementController`;
  reasons `full-screen:*` and `placement:*`, which line up with the placement log's own lines).
- Bringing another app forward, which makes Nostromo resign active: `NSWorkspace.shared.open`,
  `activateFileViewerSelecting`, `selectFile(_:inFileViewerRootedAtPath:)` (reasons `open-external-url*`,
  `reveal-in-finder*`, `open-login-terminal`, `open-external:audit-log`).

## Size of the log

The placement log is capped at 256 KiB (`WindowPlacementLog.defaultMaxBytes`); when exceeded the oldest half
is dropped. Occlusion and screen-change events share it with the activation lines, so a long session can
roll the interesting window out. Copy the log soon after a surprise switch.

## Keeping it complete

`ActivationAuditTests` scans the app sources and fails if any call in the coverage list has no
`ActivationAudit.note` before it (same line, or the nearest previous code line). Only the listed lines in the
test's `exemptLines` are skipped. `note`'s `reason` and `detail` are `StaticString`, so window titles or other
content cannot be logged.
