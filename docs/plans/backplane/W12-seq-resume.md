# W12 — Per-topic sequence numbers, replay on resume, heartbeats and bounded client queues

## Context

The daemon's IPC is broadcast-and-hope. `Server` fans every `ServerMsg` out
through a `tokio::sync::broadcast` channel (`src/ipc/server.rs:80-115`);
a slow subscriber hits `RecvError::Lagged` and is merely logged
(`src/ipc/server.rs:529-531`). A reconnecting client gets the
retained-frame cache (`retain_broadcasts`, `src/ipc/server.rs:1351`) — the
latest snapshot per key — but no events in between, and no way to tell what
it missed. `ActivityEvent` carries a `seq` (`src/ipc/protocol.rs:2708,2817`)
but nothing else does. That was fine for a Unix socket; it is not fine for a
phone on cellular behind WireGuard (`docs/plans/backplane-sequencing.md`),
nor for a satellite (W10) whose uplink blips while its Mother queue changes.

This wedge gives every topic a monotonic `seq`, a bounded replay ring on the
daemon, a `resume` map in `Subscribe` so a client (or satellite) picks up
where it left off, WebSocket heartbeats, and a bounded per-client outbound
queue that drops and marks a `Gap` instead of stalling the broadcast
channel — the behaviour Mother's broker already has
(`~/Code/mother/plugins/mother/broker/envelope.go`, `OutputSubtypeGap`).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-seq-resume`
- **Base:** `origin/main` (W10 and W11 merged)

## Files to change

- `src/ipc/protocol.rs` — add `seq: Option<u64>` (`#[serde(default,
  skip_serializing_if = "Option::is_none")]`) to every `ServerMsg` variant
  that matches a `Topic` (`:66-99`); a helper `ServerMsg::topic(&self) ->
  Option<Topic>` already exists in spirit in `peer::classify_server_msg`
  (`src/ipc/peer.rs:613`) — add an explicit one. `ClientMsg::Subscribe`
  (`:917-930`) gains `resume: BTreeMap<Topic, u64>` (`#[serde(default)]`).
  New `ServerMsg::Gap { topic: Topic, host: Option<String>, from: u64, to:
  u64, reason: GapReason }` (`replay_window_exceeded | client_slow |
  uplink_reconnect`). `PROTOCOL_VERSION` → 6.
- `src/ipc/seq.rs` (new) — `SeqStamper` (per `(Topic, host)` counter) and
  `ReplayRing` (per `(Topic, host)` `VecDeque<ServerMsg>` bounded by
  `MAX_RING_MSGS = 1000` and `MAX_RING_BYTES = 8 MiB` per topic, whichever
  first; byte size from the serialized frame). `replay(topic, host, after:
  u64) -> Replay { Messages(Vec<ServerMsg>) | Exceeded { oldest } }`.
- `src/ipc/server.rs:107-115` — stamp `seq` in the single place frames enter
  the broadcast channel (`Server::broadcast` and the retained/uplink
  publish paths) and push into the ring. On `Subscribe` with `resume`, for
  each topic: if the ring covers `after`, send the replay; else send the
  retained snapshot followed by `Gap { reason: replay_window_exceeded }`.
  Replace the per-connection direct `broadcast_rx` loop (`:520-540`) with a
  bounded `mpsc` (capacity 256) fed by a forwarder task: on full, drop
  non-retained frames for that client, remember `(topic, host, first_dropped,
  last_dropped)`, and emit one `Gap { reason: client_slow }` when the queue
  drains below half. `Lagged` on the broadcast receiver is handled the same
  way instead of being logged.
- `src/ipc/ws.rs` (W9) — WS ping every 20 s; close with 1001 after 60 s
  without a pong. Unix/TCP paths unchanged (local).
- `src/ipc/uplink.rs` (W10) — the satellite remembers the last `seq` it sent
  per topic and, on reconnect, sends `Hello` with `resume_from` so the
  primary can emit a `Gap { reason: uplink_reconnect }` to its subscribers
  only if the satellite's ring could not cover the outage; otherwise the
  satellite replays its own ring upstream.
- `src/ipc/router.rs` (W10) — rings are per host; a host disconnecting does
  not clear its ring (bounded anyway).
- `Shared/NostromoKit/Sources/NostromoKit/Transport/WebSocketClient.swift`
  (W11) — track last `seq` per `(topic, host)`; send `resume` on every
  `Subscribe` (reconnect and foreground). Surface `Gap` to the store so the
  UI can show "updates may have been missed — pull to refresh" on the
  affected list.
- `tests/seq_resume.rs` (new) — in-process server: subscribe, receive N
  frames, disconnect, publish M more, resubscribe with `resume` → exactly
  the M frames; publish > ring capacity → snapshot + `Gap`; a client that
  stops reading → `Gap { client_slow }` on resume and the broadcast
  channel's lag counter stays 0 for other clients.
- `tests/uplink_roundtrip.rs` (W10) — add the uplink-reconnect case.
- `Shared/NostromoKit/Tests/NostromoKitTests/WebSocketClientTests.swift` —
  resume map sent on reconnect; `Gap` decoded.

## Approach

1. Land `seq`/`resume`/`Gap` wire types with defaults; verify all existing
   Rust and Swift fixtures still decode.
2. `seq.rs` with pure unit tests (stamping monotonicity per key, ring bounds
   by count and bytes, replay boundaries off-by-one).
3. Route every publish through the stamper; add the bounded per-client queue
   and `Gap` emission; make `Lagged` impossible to see in logs under the
   slow-client test.
4. Heartbeats in `ws.rs`.
5. Satellite resume in `uplink.rs`; Swift resume + `Gap` handling.
6. Tests as listed; run the full suite and `swift test`.

## Acceptance criteria

- `cargo test` and `swift test` pass; no existing fixture modified.
- Every topic-bearing `ServerMsg` on the wire has a `seq` that is strictly
  increasing per `(topic, host)` for the daemon's lifetime.
- Disconnect for up to the ring window and resubscribe with `resume` →
  exactly the missed frames, in order, no duplicates (asserted by `seq`).
- Exceeding the ring window → retained snapshot then one `Gap` naming the
  topic and the `from`/`to` bounds.
- A client that stops reading for 10 s does not raise the broadcast
  channel's lag for any other client and receives exactly one `Gap {
  client_slow }` once it drains.
- A WS peer that stops answering pings is closed within 60 s (observed in
  test with a client that swallows pings).
- A satellite uplink blip shorter than its ring window produces no `Gap`
  downstream; a longer one produces one `Gap { uplink_reconnect }` per
  affected topic.
- The iOS client resumes on reconnect and on foreground and shows the
  missed-updates affordance on `Gap`.
- Memory: ring usage is bounded by `topics × hosts × 8 MiB` and reported in
  the daemon's health frame.
- PR body references the sequencing memo (W12).

## Out of scope

- Durable (on-disk) replay across daemon restarts.
- Compressing frames.
- PTY output in the ring (it keeps its own scrollback mechanism,
  `src/ipc/scrollback.rs`).
- Push notifications (W13).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Touches the single fan-out path every client depends on; backpressure and replay boundaries are easy to get subtly wrong."
  redd:
    model: sonnet
    effort: xhigh
    rationale: "Ordering, duplicates, off-by-one at ring edges and slow-client isolation need deterministic multi-connection tests."
  marty:
    model: sonnet
    effort: medium
    rationale: "Stamping and ring insertion will want a single publish() choke point once the behaviour is green."
  perri:
    model: sonnet
    effort: high
    rationale: "Regression risk for every existing client; review for lost or duplicated frames."
```
