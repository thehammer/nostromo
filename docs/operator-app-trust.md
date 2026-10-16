# Who may answer an agent: the operator app

Agents ask the human questions with `nostromo_ask_decision`; the Mac app shows
a decision sheet and sends the answer back. The daemon socket
(`~/.nostromo/nostromd.sock`, mode 0600) is open to every process running as
the user, including an agent's own Bash. So the daemon accepts a
`DecisionAnswer` only from **the operator app**: the installed, pinned
Nostromo.app, acting on a human gesture. AP2a's Approve button builds on this
same check.

## What the daemon verifies

Code: `src/ipc/peer_verify.rs` (identity), `src/ipc/server.rs` (the answer
path).

1. **At `Hello`.** The connection must claim `client_kind: "mac_app"`. Then the
   daemon reads the peer's audit token (`LOCAL_PEERTOKEN`) and asks the
   Security framework for the running code **by that token**, never by pid or
   path. The code must satisfy the requirement built from the pin file,
   `identifier "com.hammer.nostromo" and (cdhash H"<arm64>" or cdhash H"<x86_64>")`,
   and the kernel's status flags for it must show a valid signature under the
   hardened runtime, with no `get-task-allow` and no debugger attached.
   Where the executable lives, and what an `Info.plist` beside it says, don't
   matter. The pin is re-read on every such connection, so a reinstall needs no
   daemon restart.
2. **The nonce.** Only a connection verified as the operator app gets an
   `operator_nonce` in its `Welcome` (128+ random bits, per connection, never
   logged). Every `DecisionAnswer` must echo it. Bytes a process wrote before
   it was verified can't contain it.
3. **At answer time.** The daemon inspects the socket's peer again, after the
   frame was read, and requires the same pid **and** pidversion as at `Hello`,
   still running pinned code. The kernel attributes a socket to the last
   process that used it, and `exec` keeps the pid but changes the pidversion.
   So an answer written by a forked sibling sharing the socket, or after an
   `exec`, is refused.

Any failure gets the targeted error `not_operator_app` and changes nothing: the
decision stays pending and nobody is told it resolved. The daemon log names
the check that failed.

The app side: `HumanGesture.permit` (`macOS/Nostromo/Security/`) refuses
app-control input, an event-less press with VoiceOver off, an event outside the
sheet's window and an event older than 1 s. See
[`app-control.md`](app-control.md#controls-that-answer-agents-refuse-app-control-input).

## Installing

Deploy app **and** daemon together:

```sh
make mac-install      # Release build, sign (ad-hoc + hardened runtime, no entitlements), install, pin
make install-daemon
# then relaunch Nostromo
```

`make mac-install` runs `scripts/sign-operator-app.sh` on the build product
before copying it to `/Applications`, then `scripts/write-operator-pin.sh`,
which writes `~/.nostromo/operator-app.pin` (mode 0600; one `cdhash` line per
architecture). `make mac-pin` re-pins the installed app alone;
`make mac-verify-install` prints its signature, entitlements and pin, and fails
if the pin doesn't match it.

The daemon logs the pin at startup (`operator-app pin parsed`, or a warning
when it is missing or unusable, in which case no app can answer). An app that
connects without the claim (an app older than the daemon) logs
`genuine bundle, no mac_app claim: old app? reinstall app and daemon together`;
a refused claim logs `mac_app claim refused: <reason>; run make mac-install …`.

**Debug builds can't answer.** `make mac` / `mac-run` builds carry
`get-task-allow` (so Xcode can attach) and aren't pinned, so the daemon refuses
their claim. That is intended: answer decisions from the installed app. A QA
daemon (`NOSTROMO_QA_DAEMON=1`) reads the pin next to its own socket and also
accepts `com.hammer.nostromo.qa`.

The installed app must keep needing **no** hardened-runtime exceptions. It
links only system frameworks and `/usr/lib/swift`. An embedded dynamic
framework signed ad-hoc fails library validation under the runtime, so any
future dependency (SwiftTerm, for one) must link statically.

## Residual risks

**What a same-uid attacker can still do.** These are not closable without a
Developer ID Team ID and a root-owned install:

- replace `/Applications/Nostromo.app` (the user is admin) **and** rewrite
  `~/.nostromo/operator-app.pin` to match;
- replace `~/.local/bin/nostromd` or its launchd plist, which owns everything;
- post OS-level events or AX presses if its host process holds Accessibility
  or Input Monitoring permission. These are refused only when there is no
  event and VoiceOver is off, or the event is older than 1 s; a press within
  1 s of a real event in the sheet's window is still accepted;
- edit any other user-writable file.

The pin is not a root of trust: it raises the bar from "run a process" to
"rewrite installed files", and every pin read is logged.

**What is closed.** A process anywhere on disk (a fake bundle, a re-signed
copy, a script) can't answer. Neither can DYLD injection or debugger attach
into the installed app, or exec-after-connect, pre-buffered answers or fd
sharing. A copied, **unmodified** genuine app still passes, because it has the
same cdhash. That is harmless, since it is the genuine code and still needs a
human gesture.

**Behaviour change.** Only the pinned, runtime-signed install answers
decisions. Debug builds and an un-reinstalled app can't. Deploy app **and**
daemon together: run `make mac-install` (which signs and pins),
`make install-daemon`, then relaunch the app.

**Not judged yet: the event's source pid.** `HumanGesture` records each
permitted event's `eventSourceUnixProcessID` and source state (logged at
`.notice` by the decision sheet) but does not refuse on them. A real hardware
event's value can't be produced in a test here, and refusing on a guess could
refuse every real click. Once real values are collected, a follow-up can
refuse a nonzero pid that isn't the app's own.
