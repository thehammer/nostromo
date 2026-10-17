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
   hardened runtime, **enforced** by the kernel (`CS_HARD`, `CS_KILL` and
   `CS_ENFORCEMENT`), with no `get-task-allow` and no debugger attached.
   The pin is re-read on every such connection, so a reinstall needs no daemon
   restart.
2. **The installed app.** Code that satisfies the pin must also **be the
   installed app**, decided on what the kernel reports, never on a name the
   peer controls. In the same step as the code check, the daemon reads the
   peer's image once: its raw `proc_pidpath` (the kernel rebuilds it from the
   vnode, so it names no symlink) and the device and inode of the file the
   kernel mapped as that image (its region table, `PROC_PIDREGIONPATHINFO`).
   It opens the installed app itself, `/Applications/Nostromo.app/Contents/MacOS/Nostromo`,
   and reads that one open file's device and inode and the kernel's spelling of
   its path (`F_GETPATH`). The peer is the app only if **both** the raw path
   equals that spelling, compared as bytes, **and** the identities are equal.
   Anything else is `Unverified(WrongPath)`, logged as a warning. The peer's
   path is **never canonicalised or looked up**: a second look at a path the
   peer controls can be beaten without any rights, by re-pointing a directory
   (see "Directory-swap race" below). The installed path is a compile-time
   constant, changeable only through `NOSTROMO_OPERATOR_APP_PATH` in **the
   daemon's own environment** (a dev install, say). It is never read from the
   peer or from a file. This exists because the pin file alone proves nothing
   about *which* binary is meant: it is a user-writable file naming a cdhash,
   so without it a same-uid process could compile any client, sign it
   `-i com.hammer.nostromo -o runtime`, write its cdhash into the pin and be
   "the app". What an `Info.plist` beside the executable says doesn't matter
   either way.
3. **The nonce.** Only a connection verified as the operator app gets an
   `operator_nonce` in its `Welcome` (128+ random bits, per connection, never
   logged). Every `DecisionAnswer` must echo it. Bytes a process wrote before
   it was verified can't contain it.
4. **At answer time.** The daemon inspects the socket's peer again, after the
   frame was read, and requires the same pid **and** pidversion as at `Hello`,
   still running pinned code that is the installed app (step 2 is repeated, so
   it also sees the installed app replaced since). The kernel attributes a
   socket to the last process that used it, and `exec` keeps the pid but
   changes the pidversion. So an answer written by a forked sibling sharing the
   socket, or after an `exec`, is refused.

Any failure gets the targeted error `not_operator_app` and changes nothing: the
decision stays pending and nobody is told it resolved. The daemon log names
the check that failed.

**What the agent sees when an answer is refused.** Nothing: a refusal does not
resolve the decision, so the asking agent keeps waiting until its own
`timeout_secs` (default **300 s**) and then gets the usual timeout result. This
is deliberate: a refusal must never resolve a decision, and a deny sent to the
agent on a refusal would let a failed check answer in the human's place. The
daemon logs a warning, once per decision, saying the decision stays pending and
why (`decision stays pending (the agent waits until its timeout) because its
answer was refused: …`), and the app gets the `not_operator_app` error. Typical
causes: the pin was rewritten, or the app was replaced or exec'd, mid-session.
Reinstall with `make mac-install`, relaunch the app, and ask again.

The app side: `HumanGesture.permit` (`macOS/Nostromo/Security/`) refuses
app-control input, an event-less press with VoiceOver off, an event outside the
sheet's window, an event older than 1 s, and an event stamped in the future by
more than 0.25 s. `windowWillClose` can run without any gesture check
(`window.close()` skips `windowShouldClose`), so it can only ever dismiss the
sheet, never approve or choose. See
[`app-control.md`](app-control.md#controls-that-answer-agents-refuse-app-control-input).

## Installing

Deploy app **and** daemon together:

```sh
make mac-install      # Release build, sign (ad-hoc + hardened runtime, no entitlements), install, pin
make install-daemon
# then relaunch Nostromo
```

`make mac-install` fails if the Release build fails (the old product is deleted
before building, so a stale one is never signed). It runs
`scripts/sign-operator-app.sh` on the build product, then
`scripts/install-operator-app.sh`, which copies it to a temp directory beside
`/Applications`, verifies the copy's signature and cdhash, and only then swaps
it in by rename, so a failed copy leaves the old app in place. Last,
`scripts/write-operator-pin.sh` writes `~/.nostromo/operator-app.pin` (mode
0600; one `cdhash` line per architecture). `make mac-pin` re-pins the installed
app alone; `make mac-verify-install` prints its signature, entitlements and
pin, and fails if the pin doesn't match it.

The daemon logs the pin and the path the app must run from at startup
(`operator-app pin parsed`, `operator app must run from`; or a warning when the
pin is missing or unusable, in which case no app can answer). An app that
connects without the claim (an app older than the daemon) logs
`genuine bundle, no mac_app claim: old app? reinstall app and daemon together`;
a refused claim logs `mac_app claim refused: <reason>; run make mac-install …`
(for `WrongPath`, it names the path the app ran from and the path it must run
from). On a Mac where the kernel does not enforce the hardened runtime (System
Integrity Protection disabled) the claim is always refused, and reinstalling
can't help: the log reads `mac_app claim refused: RuntimeNotEnforced; SIP
disabled or runtime not enforced: operator app cannot answer`.

**Debug builds can't answer.** `make mac` / `mac-run` builds carry
`get-task-allow` (so Xcode can attach), aren't pinned and don't run from the
installed path, so the daemon refuses their claim. That is intended: answer
decisions from the installed app. A QA daemon (`NOSTROMO_QA_DAEMON=1`) reads
the pin next to its own socket and also accepts `com.hammer.nostromo.qa`; since
the QA app does not live at `/Applications/Nostromo.app`, start that daemon with
`NOSTROMO_OPERATOR_APP_PATH=<path to the QA app's executable>`.

The installed app must keep needing **no** hardened-runtime exceptions. It
links only system frameworks and `/usr/lib/swift`. An embedded dynamic
framework signed ad-hoc fails library validation under the runtime, so any
future dependency (SwiftTerm, for one) must link statically.

## Residual risks

**What a same-uid attacker can still do.** These are not closable without a
Developer ID Team ID and a root-owned install:

- **Replace `/Applications/Nostromo.app` with a re-signed binary of their own
  and rewrite `~/.nostromo/operator-app.pin` to match.** Both steps are needed:
  rewriting the pin alone no longer makes a binary elsewhere "the app" (it is
  refused as `WrongPath`, and a directory swap does not change that), and
  replacing the app alone fails the cdhash. But
  neither is out of reach: the user is an admin, so `/Applications` is
  writable by their own agent, and the pin is a file they own. The attack is
  noisy (the user's app is replaced and stops being the app they built) but it
  is possible. The pin and the path are **not** a root of trust: together they
  raise the bar from "run a process" to "replace the user's installed app and
  rewrite the pin".
- Change the path the daemon expects, by editing the daemon's launchd plist (or
  the environment it is started from) to set `NOSTROMO_OPERATOR_APP_PATH`. The
  plist is user-writable, but whoever controls it already controls the daemon.
- Replace `~/.local/bin/nostromd` or its launchd plist, which owns everything.
- Post OS-level events or AX presses if its host process holds Accessibility
  or Input Monitoring permission. These are refused only when there is no
  event and VoiceOver is off, or the event is older than 1 s or stamped in the
  future; a press within 1 s of a real event in the sheet's window is still
  accepted.
- Edit any other user-writable file.

**SIP disabled ⇒ the operator app cannot answer.** With System Integrity
Protection disabled the kernel sets `CS_RUNTIME` but enforces nothing, so a
library inserted with `DYLD_INSERT_LIBRARIES` runs inside the signed app. The
daemon therefore requires the enforcement bits and refuses every claim
(`RuntimeNotEnforced`) on such a host. This fails closed: decisions can't be
answered there at all.

**What is closed.** A process anywhere on disk (a fake bundle, a re-signed
copy, a script) can't answer, **even if its cdhash is written into the pin**:
it must also *be* the installed app's file, at the installed app's path.
Neither can DYLD injection or debugger attach into the installed app, or
exec-after-connect, pre-buffered answers or fd sharing. A copied, **unmodified**
genuine app elsewhere is refused too (wrong path), though it would otherwise
pass on its cdhash.

**Directory-swap race (closed).** The first version of the path binding read
the peer's path, ran the code check, then canonicalised the stored path string
against the live filesystem. An attacker with no admin rights could sign a
client `-i com.hammer.nostromo -o runtime`, pin its cdhash, run it from
`~/x/Nostromo` and keep `renamex_np(RENAME_SWAP)`-ing `~/x` with a symlink to
`/Applications/Nostromo.app/Contents/MacOS`; whenever the canonicalisation
landed while the symlink was in place, the client was "the installed app"
(42 of 200 inspections in a reproduction). Now nothing derived from the peer
is resolved: the raw path is compared as bytes and the file identity must match
too, and the answer-time re-check repeats both. This is covered by the
automated test
`swapping_the_attackers_directory_with_a_symlink_to_the_installed_app_never_makes_it_the_app`
(`tests/peer_code_identity_macos.rs`: a swap loop runs alongside 300
inspections and re-checks, expecting zero `Pinned`).

**What the binding does not stop.** It does not stop anyone who can change the
installed app itself: replacing `/Applications/Nostromo.app` as an admin user
(with the pin rewritten to match), or editing the daemon's launchd plist or
environment (`NOSTROMO_OPERATOR_APP_PATH`). It proves "this is the file at the
installed path now", not "this is the file the user built".

**Behaviour change.** Only the pinned, runtime-signed install, running from the
installed path, answers decisions. Debug builds and an un-reinstalled app
can't. Deploy app **and** daemon together: run `make mac-install` (which signs
and pins), `make install-daemon`, then relaunch the app.

**Not judged yet: the event's source pid.** `HumanGesture` records each
permitted event's `eventSourceUnixProcessID` and source state (logged at
`.notice` by the decision sheet) but does not refuse on them. A real hardware
event's value can't be produced in a test here, and refusing on a guess could
refuse every real click. Once real values are collected, a follow-up can
refuse a nonzero pid that isn't the app's own.

## Manual checklist

None of this can run in CI. Use a small client **you compile and sign
yourself** and delete right after. Never copy a system binary into an `.app`
bundle (macOS shows a "damaged" dialog). Prefer a scratch daemon with its own
socket and pin directory over your real `~/.nostromo`; if you do touch the real
pin, restore it afterwards with `make mac-pin`.

1. **The real install.** After `make mac-install`, `make install-daemon` and a
   relaunch: `make mac-verify-install` prints `OK`; the app launches under the
   hardened runtime; the daemon log shows the app's connection as the operator
   app (not `mac_app claim refused`); and answering a real decision works. The
   automated tests only exercise fixture binaries and a fixture-daemon smoke,
   never the hardened-runtime launch of the real installed app.
2. **The sharp test: an unpinned binary under the right identifier, and a pinned
   binary at the wrong path, each with and without a rewritten pin.** Make the
   client (any small program that connects to the daemon socket and sends
   `Hello` with `client_kind: "mac_app"`; call it `client.c`), then:

   ```sh
   work=$(mktemp -d)
   cc -o "$work/client" client.c
   codesign --force -s - -o runtime -i com.hammer.nostromo "$work/client"
   codesign -dvvv "$work/client" 2>&1 | sed -n 's/^CDHash=//p'   # its cdhash
   ```

   Run `"$work/client"` against the daemon and read the log (`log`/the daemon
   log file), for each of:

   - **(a) unpinned binary, original pin:** `mac_app claim refused:
     RequirementFailed`.
   - **(b) the same binary, pin rewritten with its cdhash** (a copy of the pin
     plus a `cdhash <hash>` line, mode 0600): `mac_app claim refused:
     WrongPath … it ran from <work>/client`, and no `operator_nonce` in the
     `Welcome`.
   - **(c) the real, pinned app copied elsewhere** (`cp -R` of
     `/Applications/Nostromo.app` into `$work`, run its executable against the
     original pin): `WrongPath`.
   - **(d) that copy with a rewritten pin:** `WrongPath` too: the path decides,
     not the pin.

   Then remove the client and the work directory, and restore the pin:

   ```sh
   rm -rf "$work"
   make mac-pin
   ```

   The directory-swap variant of (b) (swap the client's directory with a
   symlink to the installed app's directory while it runs) is covered by the
   automated test `swapping_the_attackers_directory_with_a_symlink_to_the_installed_app_never_makes_it_the_app`;
   there is no need to repeat it by hand.

   To see the documented residual, start a **scratch** daemon with
   `NOSTROMO_OPERATOR_APP_PATH="$work/client"` and the rewritten pin: the
   client is then accepted (it is the "replaced app" case).
3. **A refused answer.** With a decision pending, rewrite the pin or relaunch
   the app between `Hello` and the answer: the daemon logs the `decision stays
   pending` warning once and the agent waits out its timeout.
