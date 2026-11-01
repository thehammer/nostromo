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
- arrives less than 0.3 s after the arm (`BackgroundGesture.minConfirmDelay`);
- is a key repeat (`isARepeat`), such as a held ⌘. or Space;
- is a click after the first of a multi-click (`clickCount > 1`), such as a double-click.

Key repeats and multi-clicks are also refused at the arm, so a held key or a double-click does
nothing at all; the user presses or clicks again, then once more to confirm. Space and Return on a
focused Stop button follow the same rules as a click. The context-menu Stop only arms; a menu item
chosen by keyboard or by releasing the right button is accepted (`menuSelection: true`).

### Limits

- `HumanGesture` accepts an event up to 1 s old (`maxEventAge`). A stale human event that is still
  `NSApp.currentEvent` can pass for an action that has no event of its own; the 0.3 s spacing and
  the same-event rule narrow this, they do not close it.
- With VoiceOver on, an action with no current event is accepted (an Accessibility press). It has
  no event to compare, so only the 0.3 s spacing separates its arm from its confirm.
- `BackgroundTaskStore.requestStop` does not check any gesture. The gate lives in `TaskStopButton`;
  a fitness test allows `requestStop(` only in the two button closures (popover, task window).

Consequence: **app-control Stop clicks are refused in the real app** (`appControl` refusal), and an
AX press with VoiceOver off is refused. They work only in the isolated QA instance started with
synthetic input allowed (`NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT`, `qa-instance.sh start`). A QA script
must expect the refusal on the real app. Task windows are not reachable by app-control at all.

## Transcript rows (BA6c)

Three touches in the transcript itself, all built on the pane's `BackgroundRowBinding` (the store, the
focus tag, and what "open a task" does). A view that is not a pane's transcript (a subagent window, the
scroll-safety rig) passes no binding and gets none of them.

- **`· ◷` after a row's summary** while a member call's task is pending, running or paused. It lives on
  `FoldRowView`, so a tool group's row and a collapsed activity row (the Focus view, where the owning call
  usually sits) both show it. It is a hidden-or-shown field in the row's stack: the row stays 22 pt and
  nothing moves. It hides when the task ends. Clicking it opens that task's window; a click elsewhere on
  the row toggles as before, and a press that starts on the `◷` and ends elsewhere does nothing. VoiceOver
  reads "background task running" in the row's label and offers an "Open background task" action; nothing
  is announced when it appears.
- **Open in Background Activity** in the context menu of a row or a tool call whose call started a known
  task (any status): one item, or a submenu `<Kind>: <description>` for several (sanitized, one line, at most
  60 characters). It targets a retained object, not the responder chain, so it cannot reach another pane in
  a split window.
- **Show in Transcript** in the popover's row menu, offered by `PaneBackgroundActions` only when the task's
  call is in that pane's retained transcript. It closes the popover and calls `ReplView.revealToolCall`,
  which scrolls to the item that shows the call (the call's row, its collapsed group's row, or its collapsed
  activity row), a third of the way down the viewport, and stops following the tail. It expands nothing.

Which are gated: none of these. Opening a window and scrolling are view actions that change nothing in the
world, so there is no human-gesture check (unlike Stop, which is untouched: `PaneBackgroundActions` forwards
Open and Stop to `BackgroundTaskWindowActions.shared` and never calls `requestStop`). Show in Transcript is the
only action of the feature that moves the transcript, and only because the person asked.
