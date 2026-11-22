# Message queue wire (`session_queue_v1`)

Slice S1 of the message queue. The daemon gives every user message a stable id, lets a client watch a session's
queue live, and lets the verified Mac app take a queued message back or remove it. It ships no UI (slice S2 builds
the chips and the Up-arrow take-back on this wire) and it does not merge queued messages into one turn (slice S3,
not implemented: each queued message is still its own frame, written in order, byte for byte as before).

Code: `src/ipc/session_manager/queue.rs`; frames in `src/ipc/protocol.rs`; handlers in `src/ipc/server.rs`;
golden frames in `tests/fixtures/session_queue/` (the Swift decoder tests read the same files).

## What a queued message is

When the user sends a message to a session whose agent is busy, the daemon holds it in a per-session FIFO and
writes it to the `claude` CLI after the running turn ends. Every message sent to a session now has an id from send
time, whether it is written at once or queued. An id is opaque, unique in one daemon run, and carries the daemon
epoch (`q<epoch8>-<n>`).

| Kind | Who made it | In the view | Can be taken back |
|---|---|---|---|
| `typed` | a person typed it into a client (`session_send`) | yes, with the sender's `client_ref` | yes |
| `app` | the app composed it | yes, with an `app_label` | no (`not_allowed`) |
| injected | the daemon (terminal output, Mother notices) | never | no |

`app_label` is one of `mother_overview` (Tell notify), `work_item` (a work-item send, Fred's seed) or `agent_seed`
(a seeded first message of a new focus). The Mac maps them to words.

`session_send` gains an optional `client_ref`: opaque, at most 64 printable ASCII characters, echoed on the typed
entry so a client can recognise its own message. Anything else is ignored, never refused. A `session_send` without it
still works.

## Opting in

`welcome.features` contains `session_queue_v1`. A client that sends `session_queue_watch { tag }` gets the current
`session_queue` snapshot at once and one on every change, on that connection only. A connection that never watches
receives no `session_queue*` frame of any kind (the result and returned frames go only to the connection that asked
or pressed Stop). If the connection is not attached to `tag`, the watch attaches it first.

The watch survives a restart or crash recovery of the session exactly as attachment does: the daemon keeps the
watchers per tag and the restarted session's forwarder uses them. A client does not send the watch again. A client
that detaches or disconnects stops watching.

## Frames

All three frames are `LocalOnly`: never sent to a network peer.

### `session_queue` (daemon to client, REPLACE semantics)

```json
{"type":"session_queue","tag":"cody-1","daemon_epoch":"…","rev":7,"entries":[…],"held":{…},"change":{…}}
```

* `entries`: the queued typed and app messages, oldest first. Each is
  `{id, kind: "typed"|"app", text, image_count, command, app_label?, client_ref?, can_take_back}`.
  `text` is exactly what will be written. `command` is true for a typed slash command (the same rule the writer
  uses). `can_take_back` is true only for `typed`.
* `held`: present when a typed message of the session is held for a Claude sign-in: `{id, hold_id, can_take_back}`.
  It carries no text: the sign-in card owns it. It is not in `entries`.
* `rev`: strictly increasing for a session within one `daemon_epoch`. A client ignores a snapshot whose `rev` is not
  above the last it applied for the same epoch; a new epoch (the daemon restarted) replaces everything.
* `change`: why this snapshot was sent, `{reason, ids}`. Reasons: `queued`, `delivered`, `taken_back`, `removed`,
  `stopped` (Stop dropped the queue), `session_stopped` (the user stopped the session or started a new one; the queue
  is gone). A restart carries the queue and sends a snapshot with no `change`. A burst may be seen as several
  snapshots, and the last one always equals the queue. A message `step` takes off the queue to write is `delivered`
  from that moment; one that could not be written goes back to the front (`queued`).
* A change to injected entries alone changes nothing visible and sends no snapshot.

After a gap in the stream (the daemon's per-client buffer overflowed) the daemon sends the current snapshot again.

### Take back and remove

`session_queue_take_back { tag, id, request_id, operator_nonce }` and
`session_queue_remove { tag, id, request_id, operator_nonce }` are answered with

```json
{"type":"session_queue_result","tag":"cody-1","request_id":"r","id":"…","code":"taken_back","text":"…","images":["…"]}
```

| `code` | Meaning |
|---|---|
| `taken_back` | The entry was queued and is gone. `text` and `images` (absolute paths) are its exact text and images. Never delivered. |
| `removed` | The entry was queued and is gone. No text. Never delivered. |
| `already_delivered` | It was written to the CLI (it is in a ring of the last 512 delivered ids), or its write was still in flight after the wait limit. |
| `not_found` | Anything else: a repeat of a request already answered, an id removed by someone else, one dropped by Stop, one from an earlier daemon run, an injected id, an unknown tag. |
| `not_allowed` | An `app` entry (it stays queued), or the caller may not (below). |

`text` and `images` are present only on `taken_back`. The daemon is the single judge: it waits (bounded by the same
5 s `WRITE_WAIT_LIMIT` Stop uses, with the session lock released) for a write `step` has in flight, then decides
under the session's locks. A message is therefore either queued, or written, or gone, never in between: exactly one
of delivered, taken back, removed or dropped by Stop. If the wait limit elapses with the write still in flight, only
the id being written answers `already_delivered`: that message was off the queue and its write path decides the rest.
Any other id that is not queued keeps its own answer (`not_found`, or `already_delivered` if it was delivered).

A message that leaves by take-back, remove or Stop never runs its delivered hook (a Tell notify never shows "Told")
and stops being the conversation's first-prompt candidate: candidacy passes to the oldest message still queued, or is
cleared, and the next delivered message becomes the candidate.

The held message: take-back returns the original typed text and images (never a `<nostromo-note>` or restart note)
and turns the hold into a pause with nothing to resend (`claude_login_state` shows `paused_no_hold`); nothing is ever
written to the CLI for it. Remove discards it like `claude_login_action: discard`. Messages queued behind a hold are
ordinary entries and can be taken back.

### Stop

`session_interrupt` still ends the turn and empties the queue. The dropped messages' ids and texts go back, in a
`session_queue_returned { tag, reason: "stopped", entries: [{id, text, images?}] }`, to the connection that pressed
Stop, and only if it is the verified Mac app and it watches that tag. The entries are the typed ones, the held message
first, then the queue in order. Every watcher also gets a `session_queue` with `change.reason = stopped`. App entries
are dropped like before and are not returned.

### Session stopped

When the user stops a session (`session_control: stop`) or starts a new one, the queue is discarded with the session,
and every watcher gets a final `session_queue` with `change.reason = session_stopped`, empty `entries`, no `held`, and
the typed ids lost in `change.ids`. A restart or crash recovery does not do this: it carries the queue (and a held
message) to the new process with the same ids in the same order.

## Who may call what

| Verb | Allowed |
|---|---|
| `session_send` (with `client_ref`) | local peers (unchanged); refused for network peers |
| `session_queue_watch` | any local peer that may attach to the tag; refused for network peers |
| `session_queue_take_back`, `session_queue_remove` | the verified Mac app (`PeerTrust::OperatorApp`) with this connection's `operator_nonce`, re-checked at answer time like `claude_login_action`. Anyone else (another local process, no nonce, a stale nonce) gets `not_allowed` with no content and changes nothing. A network peer is refused at the door (`requires_secure_connection`). |
| `session_queue_returned` text | the operator connection that pressed Stop and watches the tag |

## Logging

New log lines about the queue carry counts, ids, codes and durations only: never message text, image paths or a
`client_ref`. A refusal logs the code, the connection key, the trust class and the pid.

## What survives what

| Event | The queue |
|---|---|
| Session restart, crash recovery | carried: same ids, same order; watchers keep hearing it |
| Stop (interrupt) | dropped; typed entries handed back as above |
| User stop / new session | discarded; watchers told (`session_stopped`) |
| Daemon restart | lost. The queue lives in memory only and is not persisted. The delivered ring and every id are gone too, and the `daemon_epoch` changes, so a client holding an old id gets `not_found`. S2 shows a notice when it sees the epoch change with entries it was showing. |

## Limits

- **Snapshot size.** Every `session_queue` snapshot carries the full text of every queued typed entry, and
  `write_outbound` (`src/ipc/server.rs`) silently drops a frame over 4 MiB. Two queued pastes of about 2.5 MB each
  therefore make later snapshots, and the Stop `session_queue_returned` frame, vanish. This is a known limit; S2 or a
  later slice should use per-entry previews and one frame per returned entry.
- **Lock hold.** Take-back and remove wait up to `WRITE_WAIT_LIMIT` (5 s) for an in-flight write while holding the
  global `SessionManager` mutex on a tokio worker thread. `interrupt` does the same today.
- **User stop discards the queue.** Before this slice, Stop then Restart delivered the queued messages; now a user
  stop discards them, and nothing lets the user recall that text until S2 ships.

## Not in this slice

Merging queued messages into one turn (S3, waiting on a product decision), mid-turn delivery, reordering, and
persistence.
