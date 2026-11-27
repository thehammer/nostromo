# Spike: a user frame written to `claude` stdin mid-turn (message queue S5)

Investigation only: no Nostromo code changed. Probe: `scripts/probe-midturn-stdin.py` (real `claude`, haiku,
spends tokens, not run by CI). Raw logs were saved by `--out` and are summarised here, not committed.

- **CLI:** `2.1.326 (Claude Code)`, model `claude-haiku-5-5` (`--model haiku`).
- **argv (every scenario):**
  `claude -p --model haiku --input-format stream-json --output-format stream-json --verbose --replay-user-messages --session-id <uuid> --tools Bash --allowedTools "Bash(sleep:*)" --permission-mode dontAsk`
  (Nostromo's own argv is the same stream-json/`--replay-user-messages` shape plus `--dangerously-skip-permissions
  --agent … -n …`; the permission bypass was left out on purpose.)
- **First message:** run `sleep 4` three times, one Bash call at a time, then say "done".
- **Mid-turn frame** is written the moment the first `tool_use` appears on stdout (`t = 0` below, the
  `assistant` frame carrying the first `tool_use`). The frame shape is `write_user_frame`'s
  (`src/ipc/session_manager/mod.rs:4024`): a string, or `[text block, image block]`.
- Times below are seconds relative to that first `tool_use`. Latency on the API side varied a lot between runs
  (the same Bash tool took 6 s to 25 s to report), so compare *order*, not absolute times.

Scenarios: **a** text mid-turn, **b** text + 16x16 red PNG mid-turn, **c** text mid-turn then an interrupt 1 s
later, **d** control (nothing mid-turn), **e** `/context` mid-turn. Each ran **at least twice** (six runs of a, b and c; four of d and e, plus one extra d to check the probe's cleanup)
(the first two batches differed from the last only in probe bookkeeping: the stored-file summary and how long
(c) waits for a follow-on turn); every run is consistent with what is stated below. Every run made tool calls,
so **none is INCONCLUSIVE**. The runs always agreed on behaviour; they differ only in timing.

## Short answers

1. A mid-turn user frame is **accepted and read mid-turn, at the next tool boundary, in the same turn**
   (absorbed). Not rejected, not deferred to a new turn. (Scenarios a and b: absorbed in every run, 6 runs of each; scenario c runs are counted separately below.)
2. The model sees a `<system-reminder>` wrapper (verbatim below) alongside the next tool result. The stream shows
   **no new turn**: no second `system/init`, one `result`. The `isReplay` echo of the frame appears **when it is
   absorbed**, at the tool boundary that ends the running tool call (after the tool result, with a delay of seconds that varied by run, 2-12 s in these runs; the cause was not isolated: hooks or CLI work are guesses), not when it was written.
3. **Images work.** The model named the PNG's colour in all six runs of (b) ("red").
4. The stored session file does **not** hold a `user` record for it. It holds `queue-operation` enqueue/remove
   lines and a `queued_command` **attachment**. Nostromo's reader ignores both, so a reloaded transcript would
   lack the message.
5. With an interrupt 1 s later (c) the frame is **not absorbed**, and it **survives**: after the `result`
   (`error_during_execution`) the CLI starts a **new turn** from it (`system/init`, `isReplay` echo, tool calls).
   `control_response` is still immediate and the process stays alive.
6. A typed `/context` mid-turn is **queued until the turn ends**, then **run as a slash command** (a second
   `system/init` + `result` with `num_turns: 0`), not sent to the model as text, and with no `isReplay` echo.

## 1. What happens to a user frame written mid-turn

**Answer:** it is queued inside the CLI and **absorbed at the next tool boundary** of the running turn. It does
not wait for the turn to end. If the first tool call is still running when the frame arrives, it is picked up
after that tool returns, never in the middle of a tool.

**Evidence** (scenario a, one run; frames trimmed; `uuid`/`session_id` removed):

```
 -0.10  out  {"type":"user","message":{"role":"user","content":"Run the Bash command `sleep 4` three times, ..."},"isReplay":true}
  0.00  out  {"type":"assistant", ... "content":[{"type":"tool_use","name":"Bash", ...}]}        <- first tool_use
  0.01  in   {"type":"user","message":{"role":"user","content":"MIDTURN-PING: also reply with the word banana when you finish."}}
 21.23  out  {"type":"user", ... "content":[{"type":"tool_result", ... "(Bash completed with no output)"}]}   <- tool boundary
 29.84  out  {"type":"user","message":{"role":"user","content":"MIDTURN-PING: also reply with the word banana when you finish."},"timestamp":"2026-11-22T14:01:26.551Z","isReplay":true}
 35.59  out  {"type":"assistant", ... "tool_use" ...}
 ...
 78.39  out  {"type":"assistant", ... "content":[{"type":"text","text":"done\nbanana"}]}
 83.62  out  {"type":"result","subtype":"success","stop_reason":"end_turn","num_turns":4,"result":"done\nbanana", ...}
```

The model acted on the mid-turn text ("done\nbanana" / "done banana") in all six runs of (a), and in the c run whose
follow-on turn finished. The control (d) answers just "done". Stored `queue-operation` for it ends with
`"operation":"remove","reason":"absorbed_mid_turn"`.

**Confidence:** high (a and b: 12 of 12 runs absorbed, 6 per scenario; the control and the other scenarios agree).

## 2. What the model sees, what the stream reports, when the echo appears

**Wrapper (verbatim, from the stored `queued_command` attachment's `rendered`):**

```
<system-reminder>
The user sent a new message while you were working:
MIDTURN-PING: also reply with the word banana when you finish.

This is how Claude Code surfaces messages the user sends mid-turn — within the running turn, often alongside the next tool result, rather than as a separate conversation turn. Address the message above as you continue this turn.
</system-reminder>
```

(`renderedRole: "system"`; `commandMode: "prompt"`.) The CLI wraps the text itself: the daemon writes only the
user's text.

**Stream:** a single turn: one `system/init` (before the first message), **one `result`** (`num_turns: 4`) for
both messages. No second `init`, no second `result`, no `turn` marker. The only signal that something was
absorbed is the `isReplay` user frame.

**Echo timing:** the `isReplay: true` echo is emitted **at absorption**, at the next boundary (after the `tool_result`
user frame in this capture) and before the next `assistant` frame (a: tool_result at +21.2 s, echo at +29.8 s; the echo's own
`timestamp` field is the *write* time, `14:01:26.551Z`). It is **not** emitted when the frame was written, so a
client that renders from stdout only sees the message appear at the tool boundary.

**Confidence:** high for order and wrapper text; the exact gap between tool_result and echo varied from about 2 s to
12 s and is probably CLI work between the two (hooks, attachments), so do not rely on it.

## 3. Images

**Answer:** accepted and seen. Text + image array content (`[{"type":"text"},{"type":"image","source":{"type":"base64",...}}]`)
was absorbed exactly like text, and the model answered with the colour: `"done\n\nRed"`, `"done\n\nColour: red"`,
`"The image is a solid red square, so the colour is red."` (plus three more runs answering "red"). The echo carries the whole array (text and
image block). The stored queue record keeps the image in the `queued_command` attachment's `prompt`.

**Confidence:** high (6/6 runs; one run hit the probe timeout after the model had already answered).

## 4. What the stored session file records, and how Nostromo's reader would classify it

For each absorbed frame the file (`~/.claude/projects/<slug>/<uuid>.jsonl`) gets, in order:

```
{"type":"queue-operation","operation":"enqueue","content":"MIDTURN-PING: ..."}                      <- at write time
{"type":"attachment","attachment":{"type":"queued_command","prompt":"MIDTURN-PING: ...","commandMode":"prompt",
   "source_uuid":"…","delivery_id":"…"},"rendered":[{"content":"<system-reminder>…"}],"renderedRole":"system"}
{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn","content":"MIDTURN-PING: ...", ...}
```

There is **no** `{"type":"user"}` line for it, so no `promptSource`, `turnOrigin` or `isMeta`. (The first
message the host wrote has `promptSource: "sdk", turnOrigin: "sdk"` as expected. The `"promptSource":"queued"`
hint in the task description is **not** what stream-json absorption produces: that value presumably belongs to the
interactive TUI.)

**How Nostromo's reader would classify it:** it would not. `parse_line` has no arm for `queue-operation` or
`attachment`, so they hit `_ => None` (`src/ipc/stream_json.rs:739`). A transcript reloaded from disk (a replay of
the stored file) would **drop** the mid-turn message; only the live `isReplay` echo shows it. If the daemon wants it
in stored history it needs a new arm reading `queued_command` (author: human, text from `attachment.prompt`).

Where a message that was *not* absorbed (c, after an interrupt) does get a `user` record, it is
`promptSource: "sdk", turnOrigin: "sdk"`, which `line_is_host_sent` (`stream_json.rs:1083`) already treats as
host-sent: no change needed there.

**Confidence:** high for the file shape (every run); medium on "interactive `queued` is a different path" (not
probed: interactive mode was out of scope).

## 5. Interrupt (scenario c)

Sequence in both runs: user text at +0.0 s, `interrupt` control request at about +1.0 to +1.5 s (still inside the first
tool call):

```
  0.01  in   {"type":"user","message":{"role":"user","content":"MIDTURN-PING: ..."}}
  1.18  in   {"type":"control_request","request_id":"interrupt-<ms>","request":{"subtype":"interrupt"}}
  2.64  out  {"type":"control_response","response":{"subtype":"success","request_id":"interrupt-<ms>","response":{"still_queued":[]}}}
  4.92  out  {"type":"user", ... "tool_result": "The user doesn't want to proceed with this tool use. The tool use was rejected ..."}
  4.96  out  {"type":"user", ... "text": "[Request interrupted by user for tool use]"}
  5.71  out  {"type":"result","subtype":"error_during_execution","stop_reason":"tool_use","num_turns":3,"is_error":true}
 22.43  out  {"type":"system","subtype":"init", ...}                                   <- second init, 16 s after the result
 22.43  out  {"type":"user","message":{"role":"user","content":"MIDTURN-PING: ..."},"isReplay":true}
 22.70  out  {"type":"assistant", ... "tool_use" ...}                                   <- the follow-on turn runs
```

**Answer:** the interrupt behaves as before (success at once, `result` with `error_during_execution`, process
alive). The mid-turn frame was **not** absorbed (the boundary never came: the tool was rejected) and **is not
dropped**: the CLI keeps it in its own queue (`queue-operation dequeue`), then starts a **new turn** from it (its
stored line is `promptSource: "sdk"`), the model acting on it ("done banana" in c run 2; c run 1's follow-on turn was
still running when the probe stopped watching, so only that its tool calls started is observed). `still_queued`
in the `control_response` is `[]` even though a frame is queued: do not use it as a signal.

The gap between the `result` and the second `init` (about 10-17 s) is large because this CLI has hooks configured; it
is not a protocol delay.

**Confidence:** high for survival (all six c runs show the frame run as a new turn in the stored file; the two in the last batch also in stdout); medium on timing.

## 6. Slash command mid-turn (scenario e)

`/context` written mid-turn is **queued until the turn ends**, then **run as a command**, not sent to the model as
text:

```
  0.01  in   {"type":"user","message":{"role":"user","content":"/context"}}
 47.36  out  {"type":"assistant", ... "text":"done"}
 50.84  out  {"type":"result","subtype":"success","num_turns":4,"result":"done"}          <- turn ends
 55.84  out  {"type":"system","subtype":"init", ...}                                      <- second init
 55.88  out  {"type":"assistant","message":{... "model":"<synthetic>" ... "text":"## Context Usage ..."}}
 56.03  out  {"type":"result","subtype":"success","num_turns":0,"result":"## Context Usage ..."}
```

No `isReplay` echo for it at all. The stored file has `queue-operation enqueue "/context"`, a `dequeue` after the
turn, then the local-command pair (`isMeta: true` `<local-command-caveat>…` and a `<command-name>/context</command-name>`
user record). So a slash command **is not absorbed**; it keeps today's after-the-turn behaviour. (All four runs agree.)

**Confidence:** high (4/4). Only `/context` was tried; other commands (especially prompt-type commands) may differ.

## Where Nostromo's code would mis-handle the observed behaviour

Nothing is wrong today: the daemon never writes mid-turn. These are the places that would be wrong *if S6 started
writing mid-turn*:

- **Turn bookkeeping on a replayed user line** (`src/ipc/stream_json.rs:2360-2420`). A live `isReplay` user frame
  always opens a new `Turn`: it sets the open turn `is_complete = true` (`:2403`, "defensive") and allocates a new
  one. An absorbed message produces that frame *mid-turn* with no `result` in between, so the transcript would
  split one CLI turn into two UI turns, and the single `result` (`:2466`) completes only the last. The reader needs
  to know the echo is an absorption, not a new turn (the daemon knows: it wrote it while `MidTurn`).
- **`MidTurn` state** (`src/ipc/session_manager/mod.rs:1711-1714`, `:3316`, `:3408`, `:3709`). `send` queues anything
  not `Idle` (`:1711`) and `step` writes the next queued message only after a turn ends (`:3704`, via `advance` at
  `:3430`). A steer path has to write while `MidTurn`, and then the state machine has one `result` for two
  user messages: per-message `TurnEvent::Started`/`Finished` accounting breaks (two starts, one finish).
  In the interrupt case it is the reverse: a `result` arrives and the CLI still has a queued message, so the CLI
  starts a turn on its own *without* the daemon going through `step`, while the daemon has just set `Idle`.
- **`login::on_turn_started`** (`src/ipc/session_manager/login.rs:324`). A turn takes the single `cell.written`
  slot (`remember_written`, `:272-275`) for its author and note. Two writes before the first echo overwrite it; an
  absorbed echo binds to whatever `written` holds then. A mid-turn write has to be recorded as a *second* pending
  author, matched to its own echo (by text, or by the `timestamp` the echo carries, which is the write time).
- **`interrupt`** (`src/ipc/session_manager/mod.rs:1782-1839`, queue cleared at `:1813`). It clears the daemon's
  `pending` queue (the user's "Stop" discards what was waiting). A frame already written to the CLI is **not**
  discarded by an interrupt (answer 5), so after a mid-turn write + Stop the CLI still runs it as a new turn: that
  contradicts "Stop discards the queue" unless the daemon stops writing early or tracks written-but-unabsorbed
  frames.
- **Transcript provenance rules** (`src/ipc/stream_json.rs:1083`, `:1098`, `:739`): `promptSource: "sdk"` is host-sent
  (fine). An absorbed frame has no user line, only `queue-operation` and `attachment` lines the reader ignores
  (`:739`): a reload loses it (answer 4).
- **Slash commands** (`stream_json.rs:2304-2323`): `/…` mid-turn has no `isReplay` echo, but a `CommandEcho` live
  frame is only a turn if `is_replay`. A slash command still has to wait for the turn end; a steer feature must keep
  it in the daemon queue.

## Recommendation for S6

**Feasible with changes.** The CLI does what the user wants: a frame written mid-turn reaches the model at the next
tool boundary in the same turn, with text and images, and an interrupt does not lose it. No new flag or
protocol is needed. What stands in the way is Nostromo's own bookkeeping, which assumes one echo = one turn
= one `result`, and one written message at a time:

1. Let `send` write to stdin while `MidTurn` (text and images) for steer; keep slash commands in the daemon queue.
2. Teach the reader that a live `isReplay` echo seen while a turn is open is an **absorbed message**, not a new
   turn (no `is_complete` flip at `stream_json.rs:2403`, render it as a message inside the current turn).
3. Track a *list* of written-but-unechoed messages in `login.rs` (replace the single `written` slot) and match echoes
   in order; the echo's `timestamp` is the write time.
4. Decide what **Stop** means for a message already written: the CLI will run it after the interrupt (new turn),
   the daemon can only prevent that by not writing it. Open product question for the user.
5. Add `queue-operation` / `queued_command` handling to the stored-transcript reader, or accept that absorbed
   messages vanish on reload.
6. The echo comes at the tool boundary, not at write time: the UI should show the message as "sent, waiting for
   the next step" until the echo, as the daemon queue shows it today.

Not covered here (out of scope): `--resume` sessions, other CLI versions (behaviour here is 2.1.326 only: the
`system-reminder` wrapper and `absorbed_mid_turn` are the CLI's own, so a future version may change them), permission
prompts or long single tool calls (a frame written during one long tool call waits for that tool), subagents; and
**the real Nostromo argv** (`--dangerously-skip-permissions --agent … -n …`) was NOT tested, so absorption under it is assumed, not shown. The runs also had the owner's hooks, plugins and MCP servers loaded (the probe does not pass `--strict-mcp-config` or `--setting-sources`), which affects timing. Cost: about $0.40 per haiku run on this setup (one reviewer-observed control run), so a full probe is several dollars. Treat the `src/ipc/stream_json.rs` line numbers above as approximate (checked against main at the time of writing); re-check before planning from them.
