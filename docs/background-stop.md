# Stopping a Background task

Any running or paused task in the Background activity popover or a task window can be stopped from
Nostromo. Status only ever reflects what the CLI reports: Stop never marks a task `stopped` itself.

## The control

`Stop` → (click) `Stop?` for 3 s → (second click) `Stopping…`. No second click within 3 s puts it
back to `Stop`. `Stopping…` stays until a daemon snapshot shows the task over; if none does within
10 s of the CLI taking the stop, the row shows `Couldn't stop: no confirmation from Claude Code`
beside its real status. `refused` and `timeout` show `Couldn't stop: <reason>` (the CLI's message,
sanitised, cut to 120 characters, one line). When the daemon says `stop_supported == false`, no Stop
is shown for that focus and a task window says `This Claude Code version can't stop tasks from
Nostromo`.

Stop state lives in `BackgroundTaskStore` (per focus, per task), so every popover and window on the
same task agree. It publishes through the store's coalesced `changes` and is cleared by a snapshot
that shows the task over, a new session, a daemon restart and `forget(tag:)`.

## ⌘.

Inside the popover (when it holds the keyboard) and inside a task window, ⌘. is the focused task's
two-step Stop. The popover's key monitor and the task panel consume it, so it never reaches the input
bar's Stop/interrupt.

Arming Stop by click does not hand the popover the keyboard. If the popover does not hold it (the composer
does), ⌘. goes to the composer's interrupt, not to the armed Stop: confirm by clicking the button again.

## Human gesture rule

Stop changes the world, and the daemon verb is local-only but not operator-nonce gated, so the Mac is
the only human check. **Every route runs `HumanGesture.permit` first** (`BackgroundGesture` in
`TaskStopButton.swift`): the first click, the second click, ⌘. (arming and confirming), and the
context-menu Stop (`menuSelection: true`). A refused gesture changes no state and sends nothing. The
3 s revert and the 10 s no-confirmation timers send nothing and need no permit.

### One gesture never arms and confirms

Passing `permit` twice is not enough: the two steps must be two gestures. The arm records its event
(timestamp, and `eventNumber` for a mouse event) and the time (`BackgroundGesture.now`). The confirm
is refused, leaving the armed state and its 3 s revert untouched, when it:

- is the same event as the arm (same timestamp and event number or key code);
- arrives less than 0.3 s after the arm (`BackgroundGesture.minConfirmDelay`), measured on **event time**
  (`event.timestamp` of the confirm minus the arm's) when both exist, so a busy main thread cannot stretch
  two clicks apart; the injected clock measures only presses that have no event;
- is a key repeat (`isARepeat`), such as a held ⌘. or Space;
- is a click after the first of a multi-click (`clickCount > 1`), such as a double-click.

Key repeats and multi-clicks are also refused at the arm, so a held key or a double-click does
nothing at all; the user presses or clicks again, then once more to confirm. Space and Return on a
focused Stop button follow the same rules as a click.

The click or key must also be aimed at **this** button (`TaskStopButton.clicked`): a mouse event lands
inside the button's bounds; a key event reaches it as the first responder and is Space, Return or Enter.
A fresh click on another row or control in the same window is a human event in the right window, but it
neither arms nor confirms. ⌘. and the context menu run their own checks.

The context-menu Stop only arms; a menu item chosen by keyboard or by releasing the right button is
accepted (`menuSelection: true`, `contextMenuPick: true`: never for a control whose single permitted
action changes state).

### The store only accepts a confirmed Stop

`BackgroundTaskStore.requestStop` takes a `StopConfirmation`, whose initializer is `fileprivate` to
`TaskStopButton.swift`; the button mints one only after both gesture steps passed. Code outside that file
cannot compile a call. A fitness test (`TaskStopGateFitnessTests`) backs this with a source scan: no
`requestStop` call outside the popover's and the task window's button closures, no bare
`requestStop(tag:` or function reference, and no `sendTaskStop(` or `session_task_stop` message outside
`TaskRequests` and the sender.

### Limits

- `HumanGesture` accepts an event up to 1 s old (`maxEventAge`). A stale human event that is still
  `NSApp.currentEvent` can pass for an action that has no event of its own; the 0.3 s spacing and
  the same-event rule narrow this, they do not close it.
- Before the targeting check, a fresh event **elsewhere in the window** (another row's click) passed for
  a press that had no event of its own, and could arm or confirm. The button now refuses it. What is left
  is a fresh event that did land on the button being reused within that 1 s window by such a press, at
  least 0.3 s after the arm.
- With VoiceOver on, an action with no current event is accepted (an Accessibility press). It has
  no event to compare, so only the 0.3 s spacing on the handler clock separates its arm from its confirm,
  and a local process with Accessibility permission can do it while VoiceOver is on.
- **A process that can post real CGEvents** (Accessibility permission) can click at the button's
  coordinates. `HumanGesture` records the source pid without judging it. This is the real ceiling of the
  Mac gate: the 0.3 s real-time wait (both the event clock and the handler clock must show it) and the
  two-step are the only barriers.
- **Any local process of the same uid that can reach the client socket can send `SessionTaskStop` to the
  daemon directly** (`src/ipc/peer.rs`: local-only, no operator nonce). The Mac gate protects only the UI
  route. Gating `session_task_stop` with an operator nonce in the daemon is the larger residual and needs
  its own plan.

Consequence: **app-control Stop clicks are refused in the real app** (`appControl` refusal), and an
AX press with VoiceOver off is refused. They work only in the isolated QA instance started with
synthetic input allowed (`NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT`, `qa-instance.sh start`). A QA script
must expect the refusal on the real app. Task windows are not reachable by app-control at all.
