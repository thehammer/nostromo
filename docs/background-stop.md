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

Consequence: **app-control Stop clicks are refused in the real app** (`appControl` refusal), and an
AX press with VoiceOver off is refused. They work only in the isolated QA instance started with
synthetic input allowed (`NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT`, `qa-instance.sh start`). A QA script
must expect the refusal on the real app. Task windows are not reachable by app-control at all.
