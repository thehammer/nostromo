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
before it means Nostromo asked for it. An `activeSpaceDidChange`/`didBecomeActive` with no preceding
`reason=` means something outside Nostromo (or AppKit itself) did.

## Keeping it complete

`ActivationAuditTests` scans the app sources and fails if an `activate` / `orderFront` / `makeKey*` call has
no `ActivationAudit.note` before it.
