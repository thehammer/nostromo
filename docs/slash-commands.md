# Slash commands

Nostromo sessions run the real `claude` CLI in stream-json mode. Typed text, `/cmd` included, goes to
the CLI as an ordinary user message (`SessionManager::send_user_message`); the CLI decides what it is.
This page is how the daemon and the Mac read what the CLI does with a typed command, what the picker
lists, and what is and is not verified.

Verified 2026-11-13 against Claude Code **2.1.318**, run with the daemon's flags
(`--input-format stream-json --output-format stream-json --verbose --replay-user-messages`).

## Classification

Decided by the CLI's own signals. **No hard-coded list of command names decides any of this**; the
built-in table below supplies descriptions only. The rule is also the doc comment of
`src/ipc/stream_json_local_command.rs`, which the code and tests cite.

| Class | The CLI's signal | Becomes |
|---|---|---|
| **LOCAL** (the CLI answered itself, no model turn) | (a) live: an assistant line with a top-level `local_command_run` (or `local_command_source`); (b) live: a user line whose text starts `<local-command-stdout>` / `<local-command-stderr>` while a message the daemon wrote that starts with `/` is still unanswered; (c) stored: a `system` line with `subtype: "local_command"`, or such a user line, that follows a `<command-name>` user line | One **record** turn (`TurnOrigin::LocalCommand`), never a bubble |
| **PROMPT-TYPE** (skill, custom command: a real prompt that runs a model turn) | The CLI echoed a `<command-message>` / `<command-name>` harness line (live: `isReplay: true`; stored: the harness line) and no local output follows | The user's own turn, the normal bubble. `user_input` is the text the daemon wrote (live) or `/<name> <args>` (stored) |
| **Anything else** with a leading slash | Plain text came back | An ordinary prompt. No change |

Shapes, as seen on 2.1.318:

* **Form A, live local command.** No replay of the user's line. One assistant line (carries
  `local_command_source`, `local_command_run: {command, args}`, `message.model: "<synthetic>"`), then a
  `result` with `num_turns: 0`. Seen for `/context`, `/usage`, `/mcp`, `/model`, `/effort`, and a failing
  `/compact`.
* **Form B, live.** A successful `/compact` answers with a replayed user line
  `<local-command-stdout>Compacted </local-command-stdout>`, then a `result` with `num_turns: 0`. Only a
  record while a typed `/…` write is unanswered; with none it makes nothing (an older CLI's model-switch
  lines).
* **Form C, stored JSONL.** `user` (`isMeta`, `<local-command-caveat>`), `user` (`<command-name>/context…`),
  then `system`/`local_command` (or a `user` stdout line for compact). A stored harness line is held as
  `pending_command`: local output claims it (the record takes its name and args); anything else that
  follows (a prompt, an injected skill line, an assistant line, the end of the replay) makes it the
  user's `/<name> <args>` turn first.
* **Tag order differs.** Local commands store `<command-name>` first, prompt-type commands put
  `<command-message>` first. Both tags are parsed whichever comes first.
* `set_model` writes no transcript lines on 2.1.318 (older CLIs wrote caveat, `<command-name>` and
  stdout). A stored older-CLI model-switch triple therefore reloads as one `/model …` record.

### What a record is

* It is a turn of its own, in its own place in the transcript. It is **not** a prompt: never
  `first_user_input`, never counted in `prompt_count` (ledger notes are positioned by it), exactly like
  `InjectedContext`.
* `user_input` is `/<command>` plus ` <args>`; the reader replaces it with the written text when one is
  bound, so the Mac's optimistic echo adopts it by text.
* `output` has the `<local-command-*>` wrapper removed and goes through `sanitize_block`, then the
  terminal `Redactor`, then a cap of `LOCAL_COMMAND_OUTPUT_BYTES` (16 KiB; `/context` runs ~10 KB).
* The `result` that follows completes the record, so the session goes Idle and its queue drains.
* The daemon's activity tally (`ActivityTally`) does not count it: no turn, no message, no `NoText`
  problem.

## Command catalog

The daemon reads the passive events only. **It never sends `initialize` to a live session**: a second
`initialize` answered `success`, but may reset SDK state (hooks, the permission tool), which was not
verified.

| Source | Event | Carries |
|---|---|---|
| `init` | `system/init`, once the first user message arrives | `slash_commands: [names]` |
| `cli` | `system/commands_changed`, unsolicited once the session has started and again when commands change | `{name, description, argumentHint, aliases?, builtin?}` per command |
| `none` | nothing reported yet | the built-in fallback table (Mac side) |

`commands_changed` replaces what was there; `init` never replaces a described list. The catalog is
memory only and kept per tag across restarts of the focus's process.

Entry rules (`session_manager/slash_commands.rs`): `description` is sanitised, first line only, at most 200
characters; `argument_hint` at most 80; at most 8 aliases of at most 32; an entry whose name has
whitespace or ends ` (MCP)` is skipped (MCP prompts use names the picker cannot insert reliably); at
most 500 entries; a malformed entry is skipped, unknown fields are ignored.

Wire: `session_commands_get {request_id, tag}` → targeted `session_commands {request_id, tag, source,
commands}`. Refused over TCP like `session_task_stop`; the reply is local only. Advertised as
`slash_commands_v1` in `Welcome.features`; it promises `session_commands_get`, `local_command` origins
and command-echo turns.

## Mac

* **Picker.** Typing `/` at the start of the input opens a list above the input bar (an overlay, not a
  popover: the text view keeps first responder). Up and Down move (wrapping), Tab and Return complete the
  first token to `/<name> `, Esc closes. While it is open Return never sends; with nothing matching it
  closes the picker, so a command the list does not know (it goes to the model) can still be sent.
  Each row shows the name, the argument hint and a one-line description; a command with no description
  shows none. Labelled for VoiceOver.
* **Echo.** With `slash_commands_v1`, a typed command is first a muted one-line marker
  (`/context · sent`), then the daemon's turn adopts it: a record for a local command, the ordinary
  bubble for a prompt-type one. Without the feature, today's bubble.
* **Record.** Collapsed: one muted line `/<command> <args> · <first output line>` (or `no output`), a
  chevron when the output has more than one line, the word `error` in amber for stderr. Click, Space,
  Return or a VoiceOver press opens it; the state outlives the view like a tool result's fold.

## Fallback table

`BuiltinSlashCommands.fallback` (NostromoKit), the CLI's own **2.1.318** wording verbatim, for these names
only: `clear`, `compact`, `context`, `effort`, `init`, `mcp`, `model`, `rename`, `reload-skills`,
`security-review`, `usage`. It fills a description the CLI did not give, and is the whole list before a
session's first message (the picker then says skills and custom commands appear after it) or against a
daemon without the feature. A command with no description gets none, never a made-up one. Restricted
sessions pass `--disable-slash-commands` and report few or no commands.

## Back-compat

An older Mac never asks for the list and draws a record turn as a plain bubble of `/context` (its
unknown-origin fallback: a Swift decode of an unknown `TurnOrigin` throws and `DaemonTurn` takes a nil
origin; Rust reads one as `TurnOrigin::Unknown`). A newer Mac against an older daemon sees no feature flag,
shows the fallback picker and keeps today's echo.

## Compact

A **Compact** button sits beside Clear Context in the quick-action strip of every REPL focus that has no quick
actions of its own (`QuickAction.replDefaults`). Typed `/compact` does the same thing.

**Path.** There is no compaction control request (Claude Code 2.1.318 answers `Unsupported control request
subtype: compact`), so the button sends the typed text `/compact` through `ChatSession.send`, exactly what a
user typing it does. Plan 1's pending-command echo and record apply: no operator bubble.

**Events** (live, in order): `system/status` `compacting`; `system/status` with `compact_result`; `system/init`;
`system/compact_boundary` (`compact_metadata`: `trigger`, `pre_tokens`, `post_tokens`); the summary user line
(`isSynthetic`, the existing summary marker); the `<local-command-stdout>Compacted </local-command-stdout>` user
line (form B, the record); a `result` with `num_turns: 0`. Stored: the same boundary in camelCase
(`compactMetadata`), the summary (`isCompactSummary`), the caveat, `<command-name>/compact`, the stdout line.
`ParsedLine::Compaction` reads both spellings. A boundary sets the context figure to `post_tokens`, whatever
its trigger, so the context meter drops. A boundary with `trigger: "manual"`, or a failed `compact_result`, is
held as `pending_compact` and is taken by the next `/compact` record as `origin.compact`
(`pre_tokens`, `post_tokens`, `failed`, `error`); any other turn starting clears it. An **auto** boundary makes
no record: it only updates the context figure, and the summary marker stays as it is. A `/compact` in an empty
session gets no compaction status at all: the CLI prints `Error: No messages to compact` (form A, stderr), which is
an ordinary error record.

**The record** reads `/compact · Compacted · 45.1k → 19.7k tokens` (`/compact · Compacted` when a number is
missing) or `/compact · failed: <why>` with "failed" in amber.

**Disabled while busy.** The daemon queues a message sent mid-turn, so a click would do nothing visible for
minutes. Compact is instead dimmed, with its reason in the tooltip and accessibility help, while a turn or a
compaction runs, while the session is not alive, and from the click until the record or the turn's end.

**No confirmation.** It loses nothing the user cannot get back: the on-screen transcript, the stored JSONL and
the session's approval rules (the CLI process lives on) all stay; only the model's working context is
summarized. That matches Clear Context's one-tap model; New Session confirms because it does lose Claude's memory.
Not to be confused with the Mac's memory "compaction" of cold turn payloads (`ChatSession.compactColdTurns`), which
is unrelated.

## Assumptions and what is NOT verified

* **Assumption (decided):** prompt-type commands (skills, custom commands) are real prompts that run a
  model turn, so they keep their normal typed bubble.
* Not verified on a real display: picker placement and readability, the record's look in light and dark.
* Not verified live against the real CLI: the `/context`, `/model` and `/hi` flows end to end (the
  daemon is tested against stub CLIs that emit the 2.1.318 shapes above).
* A typed `/model` or `/effort` changes the model behind the daemon's model state; the chip does not
  refresh until the next turn reports it (known gap).
* A CLI release may change the shapes above; `<local-command-*>` and `<command-*>` tags are matched by
  tag, not wording, and `discard_orphan_prompt` remains the net for an unknown tag.

## Known limitations

* **Skill replies after a reload.** Live, a skill (prompt-type command) is one turn: the `/hi` bubble and
  its reply. After a reload the stored lines split it: the reply sits in a skill marker after an empty
  `/hi` bubble. The "one turn" acceptance (S1-4) holds live only.
* **A typed command that never gets an answer** stays as `/x · sent` forever: there is no error state or
  timeout yet (tracked as a follow-up in `.claude/todos/open/2026-11-10-t5-follow-ups.md`).
* **A stopped session** answers the command-list request with the stored list under its original source
  (`init` or `cli`), rather than `none` as the plan said; the picker is more useful that way.
* **Stored `/model` triple.** The three lines older CLIs wrote for the daemon's own model switch (caveat,
  `<command-name>/model`, `Set model to …` stdout) make no turn and no record on reload, as before this
  feature: the operator never typed them. Every other stored local command becomes a record.
* **Command names** from the CLI that are over 64 characters or contain whitespace, control characters,
  ANSI escapes or bidi/invisible formatting characters are dropped (as are such aliases), not cleaned.
