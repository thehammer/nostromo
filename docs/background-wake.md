# Background wake turns (BA6a, daemon)

When a background task finishes, or a Monitor emits an event, while the agent is idle, Claude Code (the
CLI) writes a `type:"user"` event whose content starts with `<task-notification>` and then answers it.
nostromd used to drop that event, so the answer was appended to the previous, already completed turn.
Now each such wake is a turn of its own, with a `task_wake` origin. The raw notification text is never
kept: not in the turn, a delta, a frame or a log line.

This slice is the daemon only. Until the Kit and Mac draw the origin (BA6b), a client shows a wake as a
plain bubble holding the fallback line.

## Parsing

`parse_user_event` checks, before the harness-tag drop, whether the content (a string, or the joined text
blocks) starts with `<task-notification>` after leading whitespace. If so it yields `ParsedLine::TaskWake`.
Every other harness tag (`<system-reminder>`, `<local-command-*>`, `<command-*>`) is still dropped, and a
sidechain event is still dropped first. A scheduled-trigger prompt (`origin.kind:"task-notification"` with
plain content) is a normal prompt.

`parse_task_wake(text) -> (items, omitted)`:

- One item per `<task-notification>…</task-notification>` element, at most 50; the rest count in `omitted`.
  No readable element still gives one `other`/`event` item, so a wake always opens a turn.
- Only the text before the element's first `<event>`, `<result>`, `<note>` or `<usage>` tag is read:
  `<task-id>` (the first not starting `__`, which skips a resume orphan's placeholder), `<tool-use-id>`,
  `<status>` and `<summary>`. Event, result, note and usage bodies, `<output-file>` and a summary's tail
  (`(exit code N)`) are never read.
- Ids are kept only when they are 1-128 ASCII `[A-Za-z0-9._:-]` characters.
- The summary is XML-unescaped once (`&lt; &gt; &amp; &quot; &apos; &#NN; &#xHH;`), then:

| Summary starts with | `kind` | `outcome` |
|---|---|---|
| `Monitor event: "` | `monitor` | `new_output` |
| `Monitor "` containing `" stream ended` | `monitor` | `ended` |
| `Monitor "` | `monitor` | from status |
| `Background command "` | `shell` | from status |
| `Agent "` or `Background agent "` | `agent` | from status |
| anything else | `other` | from status |

  Status `completed`, `failed`, `killed`/`stopped` (→ `stopped`); missing or unknown → `event`.
- The description is the text between the prefix's opening quote and the last `"`, run through
  `task_output::sanitize` and `untrusted::one_line(_, 200)` (escapes, bidi, zero-width, filler and control
  characters dropped; one line; at most 200 characters). For `other` it is empty.
- The CLI XML-escapes element bodies. An unescaped hostile body cannot change an element's first item; at
  worst it adds plain, sanitised, capped items.

## The turn

`TurnOrigin::TaskWake { items, omitted }` (wire `type: "task_wake"`; `omitted` absent when 0; `task_id`
and `tool_use_id` absent when unknown). `kind` and `outcome` are strings so a newer value never fails a
decode.

```json
{"id":"t3","user_input":"⟲ 2 background events","timestamp":"…","blocks":[…],"is_complete":true,
 "origin":{"type":"task_wake","items":[
   {"task_id":"bmon1","kind":"monitor","outcome":"new_output","description":"CI for PR #251"},
   {"task_id":"bsh2","tool_use_id":"toolu_01ABC","kind":"shell","outcome":"failed","description":"…"}]}}
```

`user_input` is the daemon's fallback line (`task_wake_line`), for clients that do not know the origin:
`⟲ Monitor: new output "CI for PR #251"`, `⟲ Shell: failed "…"`, `⟲ Agent: finished "…"`,
`⟲ 3 background events`, `⟲ Background event`. A wake is not a prompt: `prompt_count` and the session title
(`first_user_input`) never change for it, live or after `transcript_from_jsonl`.

**Merging.** A second notification while the newest turn is an open wake with no reply yet (only notes)
joins that turn: its items are appended (50 cap, then `omitted`), `user_input` and `timestamp` stay the
first's (the Mac identity key stays stable; a merged two-event wake reads `⟲ Monitor: new output "…"`, the first event's line, not `⟲ 2 background events`), and no `TurnDelta` is emitted. The reader instead broadcasts
`SessionEvent::TurnOrigin`, which the forwarder sends as the top-level frame

```json
{"type":"session_turn_origin","tag":"claudia-ABCD1234","turn_id":"t3","origin":{"type":"task_wake","items":[…]}}
```

It is a frame of its own because both Swift decoders throw on an unknown `TurnDelta` kind, while an unknown
frame `type` decodes to `.unknown`. Golden files: `tests/fixtures/background-activity/`
(`turn-task-wake.json`, `session-turn-origin.json`; `UPDATE_GOLDEN=1` rewrites them).

## Authorship, and the reload caveat

A wake turn goes through the reader's normal `TurnStarted` path: the session goes `MidTurn`, a message sent
meanwhile is queued and written after the wake's `result`. Who wrote the turn comes from the daemon's own
queue (`login::on_wake_turn_started`), never from the text: the turn is a user's or injected message only
if the message the daemon last wrote itself starts with `<task-notification>`. Otherwise the CLI began it
(`TurnAuthor::Cli`), the turn binds to nothing, and a message written meanwhile keeps waiting for its own
turn. When the author is not `Cli`, `disown_wake_origin` takes the origin back before the `TurnStarted`
frame leaves the daemon: the turn is a plain bubble holding the fallback line.

A reloaded transcript cannot tell who wrote a turn, so a notification a user pasted and read back from a
stored session draws as a wake marker. That is navigation only, the same caveat as for Mother notices.

## Model-ledger positions

Ledger notes are positioned by prompt number. Wake turns are not prompts, so `merge_ledger_notes` counts
only turns whose origin is not `TaskWake`: a note after prompt N attaches to the last turn of prompt N's
group (the counted turn and the wake turns after it, before the next counted turn). A live `add_note`
puts a note on the newest turn, which is the same turn only when no wake came between the note and the
next prompt. **Known limitation:** a model switch made while idle after prompt N and before the wake that
follows lands live on prompt N's turn, but after a reload `after_prompt` is still N and wakes do not
count, so it moves to the wake turn. The effect is cosmetic (a "switched to X" note drifts past one turn);
a proper fix needs a wake count in the stored note. Notes past the newest group follow the newest turn; notes whose prompt was trimmed are
dropped even if its wake turns survive.

## Network peers

A turn with a `task_wake` origin rides in `SessionTurns` and `SessionTurnDelta` like any turn: withheld for
a sensitive focus, visible otherwise. It carries ids, kind, outcome and a sanitised, capped description,
never an event, result, note, usage, output path or summary tail. `SessionTurnOrigin` is
`ServerClass::Focus(tag)` and passes the redaction unchanged.

## Logging

Nothing in the parse, merge or authorship path logs a description, summary or any part of a notification.
