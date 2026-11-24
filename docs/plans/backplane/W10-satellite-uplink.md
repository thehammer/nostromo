# W10 — Satellite mode: a nostromd that publishes upstream and accepts routed actions

## Refreshed 2026-11-24 against `origin/main` `4cafd5e8` (W9 as built; PRD open question 4 answered)

**Read this section first; it wins over every older section below.** W9
merged in #526 (`e21f891c`) and #528 (`95f3f6e7`). This section records
where W9's code differs from what this plan assumed, and what W10 must do
about it. Every fact is cited against `origin/main` `4cafd5e8`.

**Ready to queue.** The pairing PRD's open question 4 was answered **yes**
by the operator on 2026-11-24: the employer's policy allows Kobe's job
states, short references and host name (fixed-vocabulary metadata, never
Carefeed text) to leave Kobe for the personal server, the push relay and
Apple, and to show on a personal phone. Nothing gates this wedge's merge or
install any more, and Kobe is enrolled as a `work` satellite as planned.
Queue it once the docs PR carrying this section has merged.

**What W9 shipped that this plan builds on, and the corrections it forces:**

1. **The level type is `SatelliteAdmin`, not `DeviceAdmin`.**
   `src/ipc/devices.rs:46-78`: `enum SatelliteAdmin { Full, RevokeOnly
   (#[default]), ReadOnly, Off }`, serde `snake_case`, `as_str()` and
   `parse()` (accepts `revoke-only` and `revoke_only`). Wherever this plan
   says `DeviceAdmin` (`PeerTrust::Satellite { admin }`, the config key
   `uplink.device_admin`), use `SatelliteAdmin`; do not add a second enum.
   It derives **no `Ord`**, and its declaration order is the reverse of
   "more power first", so do not derive `Ord` to compute "the lower of the
   two": add an explicit `fn rank(self) -> u8` (`Off` 0, `ReadOnly` 1,
   `RevokeOnly` 2, `Full` 3) and `fn min_with(self, other)` beside it.
2. **The registry already stores the level, and an unset level is already
   `revoke_only`.** `DeviceRegistry::redeem` sets `admin:
   admin.unwrap_or(SatelliteAdmin::RevokeOnly)` for a satellite record
   (`devices.rs:372-375`); `set_admin` (`:456-490`) changes it and bumps the
   registry epoch. `nostromo device pair --satellite <host> [--admin …]` and
   `nostromo device admin <host> <level>` exist (`src/bin/nostromo_cli.rs:31-50`).
   W10 tests the unset rule end to end; it does not re-implement it.
3. **The registry has no `egress`.** `DeviceRecord`/`DeviceSummary`
   (`devices.rs:91-107`) carry `admin` only, and `DevicePairStart`
   (`src/ipc/protocol.rs:2615-2623`) has `satellite` and `admin` but no
   egress. This plan's "`Hello.role.egress` must match the egress recorded at
   enrolment" therefore needs W10 to add it: `egress: Option<Egress>` on the
   satellite record (`#[serde(default)]`, absent = `work`), on
   `DevicePairStart` (`#[serde(default, skip_serializing_if =
   "Option::is_none")]`, only with `satellite`), carried through
   `PairingTable::start` (`src/ipc/pairing.rs:152-161`) to `redeem`, shown in
   `DeviceSummary` for hosts, and a `--egress work|personal` flag on `device
   pair` (`requires = "satellite"`, like `--admin`). Listed under Files below.
4. **A satellite token is admitted today as `PeerTrust::Paired`.** `ws.rs`
   `run_paired` (`src/ipc/ws.rs:530-575`) serves every valid token through
   `handle_client` with `PeerOrigin::Ws { device_id }`
   (`src/ipc/server.rs:405-408`), whose trust is fixed by
   `PeerOrigin::resolve` (`:440`, `PeerTrust::from_transport(Transport::Ws)`)
   after the `Hello`. Nothing looks at the record's `kind`. W10 must: carry
   the record's kind, admin and egress on `PeerOrigin::Ws` (looked up in
   `run_paired` from the registry), and in `resolve` map
   - a satellite record with `Hello.role = Satellite { host, egress }` →
     `PeerTrust::Satellite { admin }`, **only if** `host` equals the record's
     name and `egress` equals the recorded egress;
   - a satellite record without that role, or with a mismatched host or
     egress, and a phone/iPad record that claims `role: Satellite` →
     `Unauthorized { reason: "role" }` and close 4001 (`CLOSE_UNAUTHORIZED`,
     `ws.rs:50`).
   The router keys `HostTable` on the **record's name**, never on what the
   `Hello` claims, so one satellite's token cannot publish as another host.
   (Re-enrolling a host while its old record is active yields a de-duplicated
   name such as `kobe 2`, `devices.rs:366`, which then fails the host check:
   revoke the old record first. `redeem` never replaces a satellite record,
   `:358-363`, and `nostromo uplink pair` sends no D6 proof.)
5. **Device-admin verbs never reach the hub from a network peer.**
   `DeviceHub::dispatch` (`src/ipc/device_hub.rs:251-357`) returns
   `NotHandled` for every `trust.is_network()` peer (`:268-270`), and the
   call site in `handle_client` (`src/ipc/server.rs:1379-1395`) then falls
   through to the normal FND-1 refusal. The satellite path is a new arm in
   `dispatch`, **before** that check, matching `PeerTrust::Satellite { admin
   }` and applying the per-level table (below). `DeviceUnpairSelf` stays
   `Paired`-only (`:259-266`); a satellite's `DeviceUnpairSelf` is
   `NotHandled` and refused. Pairings it starts pass the satellite's
   `origin` as `PairingTable::start`'s `origin` argument (W9 left that slot,
   `pairing.rs:155`; `dispatch` passes `None` today, `device_hub.rs:292-300`).
6. **`DeviceSetAdmin` exists (ordinal 105) and this plan never named it.**
   Over an uplink it is refused at **every** level, `full` included, with
   `DeviceAdminError { not_permitted_on_this_mac }` and no side effect:
   levels are changed only on the primary (`nostromo device admin`, a local
   client there; W15 says the same, "that is `nostromo device admin` on the
   primary only"). Otherwise a `full` satellite could widen another
   satellite, or itself.
7. **Every write path runs `may_receive`, and it drops `Admin` for every
   network trust.** Broadcast (`server.rs:1181`), terminal (`:1208`),
   targeted (`:1230`) and every replay (`:1020-1150`) go through
   `peer::outbound` → `may_receive` (`src/ipc/peer.rs:997-1010`), which
   returns `false` for `ServerClass::Admin` and `LocalOnly` whenever
   `trust.is_network()` (`:1008`). `PeerTrust::Satellite` is a network trust,
   so without a change a satellite receives no admin frame at all, not even
   the targeted replies `DeviceHub::dispatch` sends on `reply`
   (`device_hub.rs:355`). **The rule (Perri's #522 item, resolved here):**
   - `ServerClass::Admin` (`DevicePairing`, `DevicePairOutcome`, `Devices`,
     `DeviceRevoked`; `peer.rs:900-905`): `may_receive` passes it for
     `PeerTrust::Satellite { admin }` when `admin` is not `Off` (at least
     `read_only`), and refuses it for `Paired`, `Tcp` and `Routed`.
   - **New `ServerClass::SatelliteControl`** for `DeviceAdminLevel` **and
     `DeviceAdminError`**: `may_receive` passes it for `PeerTrust::Satellite
     { .. }` at **every** level, `off` included, and for local peers (the
     existing `!trust.is_network()` short-circuit, `:998`); it refuses it for
     `Paired`, `Tcp` and `Routed`. `DeviceAdminError` moves here from `Admin`
     because it is the only answer an `off` satellite gets to a refused verb
     (`not_permitted_on_this_mac`); under `Admin` it would be dropped and the
     satellite's local client would wait forever. Both frames are fixed
     vocabulary (`request_id`, a reason string; a level and host names).
     Add the arm to `is_sensitive_server_msg` (`:916-927`, `NotSensitive`).
   - "Never to another satellite" is enforced by delivery, not by class:
     both frames are only ever written targeted (`reply` / the connection's
     own sender), never sent on the broadcast channel. Add a test that
     `Server::broadcast` is never called with either (as W9 did for the
     pairing replies).
8. **`Topic::Devices` is stripped for every network trust.**
   `deliverable_topics` (`src/ipc/server.rs:3946-3955`) removes
   `Topic::Devices` when `trust.is_network()`, so a satellite's upstream
   `Subscribe { topics: [Devices] }` would receive nothing. Keep it for
   `PeerTrust::Satellite { admin }` when `admin` is not `Off`; keep stripping
   it for `Paired`, `Tcp` and `Routed`.
9. **A level change must reach a live uplink.** `PeerTrust` is `Copy` and
   fixed after the `Hello`, so `Satellite { admin }` is a snapshot. W9
   already watches the registry epoch in `run_paired` (`ws.rs`, the
   `epoch.changed()` arm; `set_admin` bumps it, `devices.rs:484`). For a
   satellite connection, when the epoch changes and the record's level
   differs from the snapshot, close the uplink with **1012** ("level
   changed"); the satellite reconnects at once (its first backoff step,
   1 s), is re-admitted with the new trust, and receives `DeviceAdminLevel`
   on admission. Relayed open pairings of that uplink get `connection_lost`
   (as on any uplink drop). This replaces "and whenever that record's level
   changes" with a mechanism that keeps `PeerTrust` `Copy`. A revoke still
   closes with 4001, as built.
10. **The uplink must not echo admin frames back up.** The satellite
    republishes the primary's `Devices` (and relays admin replies) to its
    local clients. Step (1) of the forward filter must also drop every
    `ServerClass::Admin` and `ServerClass::SatelliteControl` frame, and the
    W9 pairing replies (`PairOffer`, `Paired`, `PairRefused`,
    `Unauthorized`, `DeviceUnpaired`), so nothing administrative is ever
    published upstream or loops.
11. **Counts.** `ServerMsg` has **102** variants on this base (the 92 of
    2026-11-23 plus W9's ten: `PairOffer`, `Paired`, `PairRefused`,
    `Unauthorized`, `DeviceUnpaired`, `DevicePairing`, `DevicePairOutcome`,
    `Devices`, `DeviceRevoked`, `DeviceAdminError`; `protocol.rs:3098` to
    the enum's end). `redact_for_uplink_metadata` therefore has 102 arms plus
    W10's three new frames (`Hosts`, `HostUnavailable`, `DeviceAdminLevel`)
    = **105**, all ten W9 frames returning `None`. W10 adds **no**
    `ClientMsg` variant (`Hello.role` is a field), so `CLIENT_MSG_VARIANTS`
    stays **106** (`peer.rs:2582`, asserted `:2738-2739`).
12. **Names and lines that moved** (supersede the 2026-11-23 list):
    `handle_client` `src/ipc/server.rs:704`; `handle_client_msg` `:1556`;
    `retain_broadcasts` `:4652`; `Server` (broadcast sender `tx`) `:138-140`;
    `ServerMsg::MotherJobs` `protocol.rs:3132`, `MotherStatusline` `:3135`,
    `PerriState` `:3166`, `SessionListResp` `:3265`, `FocusListResp`
    `:3278`, `DecisionRequest` `:3341`, `DecisionResolved` `:3361`,
    `ApprovalPending` `:3422`; `ClientMsg::Hello` `:1641-1655`; `Config`
    `src/config.rs:59` (the WebSocket key is **`ws_addr`**, `:70`, resolved
    by `ws_listen_addr()` `:516` with `NOSTROMD_WS_ADDR`, default
    `127.0.0.1:47101` `:22`; `pair_host` `:75`; `tcp_listen_addr()` `:502`;
    `impl Default` `:219`); in `src/bin/nostromd.rs`, the TCP bind `:356`,
    the WebSocket listener `:389`, `mdns::advertise` `:426`, the activity
    tailer `:758-795`, `run_mother_pollers` `:906` (interval `:966`).
    `attach_network` is unchanged (`session_manager/mod.rs:2059`).
13. **What a satellite's pair code says.** `DevicePairing.server_url` is
    built on the primary from the primary's `pair_host` and WebSocket port
    (`device_hub.rs:297-306`), so a relayed `DevicePairStart` already yields
    the primary's URL (step 6's assertion); the satellite's own `pair_host`
    and loopback listener play no part.
14. **D6 proof: nothing open.** The uplink does not use the re-pair proof (a
    satellite enrols with a fresh code; `redeem` never replaces a satellite
    record). The encoding is pinned in code and shared with W11: the W9
    plan's "Pinned wire vector: the re-pair proof (D6)" section and
    `the_proof_encoding_is_pinned_by_a_fixed_vector` in
    `src/ipc/devices.rs:862-882` (`pairing_proof` `:661`, `proof_for_token`
    `:669`).
15. **W9's WebSocket limits apply to the uplink unchanged:** 10 s handshake,
    64 unauthenticated sockets in total and 8 per address (IPv6 per /64),
    8 authenticated sockets per device record (`WsLimits::default`,
    `ws.rs:89-97`), 20 unauthenticated upgrades per address per minute
    (`:56-57`), a 4 KiB pairing-frame cap (`:68`), and `403` for an upgrade
    that carries an `Origin` header (`:354`, `:241-245`). The uplink sends no
    `Origin`; `nostromo uplink pair` dials a pairing-only socket and sends
    one `Pair`, well under 4 KiB. A satellite holds one uplink socket, far
    under the per-device cap of 8.

**Plan text corrected in place below** (so the body no longer contradicts
this section): the `DeviceAdmin` name, the Q4 gate, "re-scopes", "cancel,
turn mail-and-todos off", the variant count in W10-18, the stale line
numbers in Files, and the Files entries for `devices.rs`, `pairing.rs`,
`device_hub.rs` and `server.rs`'s `deliverable_topics`. New criterion
**W10-20** covers items 4, 6, 7, 8 and 9; the next section adds the
primary-side trust boundary (W10-20 extended, new W10-21).

## Trust boundary on the primary (2026-11-24, after Perri's review of #529)

**Read with the section above; this one wins where they differ.** The
primary must treat a satellite as possibly compromised: Kobe is an
employer-managed laptop. Everything below is enforced **on the primary**, not
by trusting the satellite's own filters (which stay as defence in depth). The
point is that a crafted satellite can never act above its tier, impersonate
another host, or read what it is not meant to.

**A0. How the primary reads a satellite's socket (M5a).** `handle_client`
decodes every inbound frame as a `ClientMsg` (`src/ipc/server.rs:1249`) and
W10 adds no `ClientMsg` variant, so a satellite's published `ServerMsg`s and
its own verbs need a wire distinction. **Chosen: a tagged envelope on the
uplink socket only**, `enum UplinkFrame` in a new `src/ipc/uplink_wire.rs`
shared by both sides, serde-tagged `"uplink"`:
- satellite → primary: `client { msg: ClientMsg }` (its own `Hello`,
  `Subscribe`, `Ping`, admin verbs), `publish { msg: ServerMsg }` (a
  broadcast it forwards), `reply { id: String, msg: ServerMsg }` (an answer to
  a routed request);
- primary → satellite: `server { msg: ServerMsg }` (anything its
  `handle_client` writes) and `request { id: String, msg: ClientMsg }` (a
  routed read).

Why an envelope and not "decode `ClientMsg`, fall back to `ServerMsg`": both
enums are internally tagged on `type` in one namespace, so a fallback would
let the satellite choose which decoder runs and would break silently the day
a variant name is shared; it would also need a `ClientMsg` variant (an
ordinal, moving W13's and W16's numbers again) to carry routed replies. The
envelope is transport framing, not a `ClientMsg`, so `CLIENT_MSG_VARIANTS`
stays 106. `run_paired` (`src/ipc/ws.rs:530`) knows the record is a
satellite before the first frame (item 4), so for a satellite record it
expects envelopes from the first frame on (the `Hello` too): it unwraps
`client` into the `handle_client` bridge exactly as today, sends **every**
`publish` through `router::ingest_from_satellite` and every `reply` through
`router::accept_routed_reply` (below), and never lets either reach
`handle_client`. It drops (and counts) a frame that is not valid
`UplinkFrame` or carries a primary → satellite tag. It wraps everything the
handler writes as `server`. The satellite accepts only `server` and
`request`. Phones and iPads never see the envelope.

**A. Ingest: what the primary accepts from a satellite** (new function
`router::ingest_from_satellite(record: &SatelliteRecord, msg: ServerMsg) ->
Option<ServerMsg>` in `src/ipc/router.rs`; every `publish` frame goes
through it, and it is the only path from a satellite to the primary's
broadcast channel; routed replies take the second path in A5):
0. **Rate and size (R3).** Per satellite connection: a `publish` frame over
   **256 KiB** of JSON is dropped (counted); `publish` frames pass a token
   bucket of **50 per second, burst 200**, excess dropped and counted, and a
   satellite over the limit for 30 s in a row is closed with 1008. (The
   library still accepts frames up to `MAX_FRAME_LEN * 2`, `ws.rs:330-336`,
   because the limit is chosen at accept time; the cap is applied on read in
   `run_paired`.) Malformed envelopes and wrong-direction envelopes
   (`server`/`request` sent by a satellite) are dropped **and charged to the
   same bucket** (Q2), so a stream of junk also ends in the 1008 close.
   `reply` frames are capped at `MAX_FRAME_LEN` (`src/ipc/protocol.rs:52`),
   since a transcript snapshot can be large, and have their **own** bucket
   and id caps (A5). A test drives 1,000 frames in a second, 1,000 junk
   envelopes in a second and a 300 KiB frame from a crafted satellite and
   asserts the drops, the 1008 close for sustained junk, and that a phone
   subscriber sees no lag beyond the bucket.
1. **Only host-carrying variants, and host is the record's name, always
   (M1, R5).** The allow-list is exactly the variants that carry `host`:
   `MotherJobs`, `MotherStatusline`, `Activity`, `FocusListResp`,
   `SessionListResp`, `ApprovalPending`, `PerriState`, `DecisionRequest`,
   `DecisionResolved` (the nine in Files), plus `SessionState`,
   `TrackerSummary`, `SessionBridge`, `FocusCreated` and
   `FocusRegistryUpdated`, to which W10 now also adds the same optional
   `host` because the per-topic publish table publishes them. Any other
   variant is dropped (so a host-less open frame such as `Withheld`,
   `DaemonReconnected` or `ModelCatalog` never enters from a satellite).
   Transcript and pane content of a `personal` host (`SessionTurns`,
   `SessionTurnDelta`, `PaneContent` and the rest of the transcript family)
   reaches the primary only as routed replies to a routed `SessionAttach`
   (A5), not as broadcasts (it carries no host and could not be attributed);
   the host-carrying per-focus frames above (`SessionState`, `SessionBridge`,
   `TrackerSummary`, …) are still published. If the frame's `host` is not
   exactly `Some(<record name>)` (absent counts as a mismatch), drop it and
   count it (one WARN per variant per hour). Never trust a satellite's
   `host` to key `retain_broadcasts`: otherwise Kobe could publish
   `MotherJobs { host: Some("sendai") }` or `host: None` (the primary's own
   key) and overwrite Sendai's or Tokyo's retained snapshot on every phone.
   (Drop rather than overwrite, so a buggy honest satellite is visible.)
   The host rule applies to every allowed variant.
2. **Never-from-a-satellite variants, whatever the egress (M2).** Drop every
   frame whose `classify_server_msg` is `LocalOnly`, `Admin` or
   `SatelliteControl`; the five W9 pairing replies (`PairOffer`, `Paired`,
   `PairRefused`, `Unauthorized`, `DeviceUnpaired`); and `Hosts`,
   `HostUnavailable`, `Welcome`, `Pong`, `Error`, `MotherPeek`,
   `MotherAwaitDetected` (by name). Step 1's allow-list already excludes all
   of these; the explicit list stays as a second, named check so a later
   `host` field on one of them cannot open it. Without this, a crafted `Devices`,
   `DeviceAdminLevel { level: full, pair_from: [...] }` or `Hosts` published by
   Kobe would pass the primary's per-downstream `peer::outbound` to its local
   clients and, through `Admin`/`SatelliteControl`, to Sendai's uplink, and
   Sendai's Mac app would show a forged device list, level or pair-from host.
3. **Egress shape (R2).** A `work` satellite's frame must satisfy a pure
   predicate `peer::is_uplink_metadata_shape(&ServerMsg) -> bool` (re-running
   `redact_for_uplink_metadata` on the primary would re-hash the `f-` tags,
   so its output never equals its input). The predicate checks, per allowed
   variant, that every field the metadata function blanks is absent or empty,
   every focus tag matches `^f-[0-9a-f]{8}$`, every job or item ref is 8
   lower-case hex, every enum is in its fixed vocabulary, agent names are in
   the fixed agent set, and counts are within sane bounds. A round-trip test
   asserts `is_uplink_metadata_shape(redact_for_uplink_metadata(m))` for a
   constructor of every allowed variant (an honest `work` frame survives) and
   `false` for each frame with a planted marker string. A `personal`
   satellite's frame must survive `peer::outbound(PeerTrust::Tcp, …)`
   unchanged (drop it otherwise). Both are counted.
4. Only then is the frame broadcast. The per-downstream `peer::outbound`
   still runs for every receiver.
5. **Routed replies (M5b): `router::accept_routed_reply`.** When the router
   forwards one of the six read verbs to a `personal` satellite, it mints an
   opaque random id (16 bytes, base64url) and records `id → (requesting
   connection's targeted sender and conn_key, host routed to, allowed reply
   variants for that verb, expiry)`; the satellite receives `request { id,
   msg }`. The satellite never names a target connection. A `reply { id, msg
   }` is accepted only if: the id is outstanding; it arrived on the uplink of
   **the host the request was routed to** (and that host is `personal`; a
   `work` host is never routed to, so it can never hold an id); `msg`'s
   variant is in the verb's allowed set (derived from what
   `handle_client_msg`'s arms send for that verb; a test pins the table); and
   it passes the **reply checks** below. Then it is written to the
   requester's targeted sender, whose `outbound` still runs. Anything else
   (unknown, expired, foreign host, wrong variant) is dropped and counted.
   **Reply checks (M6), for replies only; publish frames keep steps 1–3
   unchanged:**
   - The verb's allowed-variant table **replaces step 1's host-carrying
     list**: the request id already says which host the reply comes from, so
     a transcript frame without a `host` field can pass. Step 1 is not
     relaxed for `publish` (that would reopen M1).
   - The `host == Some(<record name>)` rule still applies to any reply variant
     that **has** a `host` field (absent is a mismatch), and the satellite
     stamps `host` on replies too.
   - The verb tables never contain a `LocalOnly`, `Admin` or
     `SatelliteControl` variant, the five W9 pairing replies, `Hosts`,
     `HostUnavailable`, `Welcome`, `Pong`, `MotherPeek` or
     `MotherAwaitDetected`; a unit test iterates every table and asserts it.
   - **Refusals are allowed as replies:** `Error` and `Withheld` are in every
     verb's table, so a refused routed read (for example a sensitive tag on
     Sendai) reaches the requester instead of leaving it waiting; they are
     delivered only to the requester, never broadcast or retained.
   - **Defence in depth (step 3 for replies):** a reply must survive
     `peer::outbound(PeerTrust::Tcp, …)` unchanged, which drops whole
     sensitive classes (the primary cannot know Sendai's sensitive focus
     tags, so the per-tag check stays on Sendai).
   **Limits (Q1).** Replies have their own token bucket per satellite
   connection (**200 per second, burst 400**; excess dropped and counted;
   over the limit for 30 s in a row closes the uplink with 1008), separate
   from `publish`. Outstanding ids are capped at **32 per requesting
   connection** and **32 per host**; beyond either cap the router answers
   `HostUnavailable { reason: busy }` and routes nothing. Without the caps a
   requester, including an unauthenticated LAN `Tcp` peer, could open
   unlimited attaches to Sendai, and one live `SessionAttach` id could carry
   unlimited deltas. Single-answer verbs (`SessionList`, `FocusList`,
   `SessionModelGet`, `ActivitySnapshotRequest`, `SessionDetach`) retire the
   id on the first accepted reply or after 10 s. A `SessionAttach` id stays
   live, carrying that attach's snapshot and live deltas, until the requester
   detaches or disconnects (the primary then routes `SessionDetach` with the
   same id) or the uplink drops. On the satellite the injected key is
   `uplink:<id>` (not the primary's connection id), and every frame the
   local handler writes to that key goes back as `reply { id, … }` through
   the egress filter.

**B. What a satellite may send and receive (M3).** "A satellite publishes;
it does not consume" is enforced on the primary:
- **Verbs.** `network_policy` (`src/ipc/peer.rs:1081`) takes no trust, so a
  separate allow-list `peer::satellite_allowed(&ClientMsg) -> bool` is
  checked for `PeerTrust::Satellite` **at the top of `handle_client`'s frame
  loop, right after the `ClientMsg` decode (`src/ipc/server.rs:1249`)**,
  before the `Subscribe` handling, the operator-answer checks, the terminal
  verbs, the `DeviceHub::dispatch` call (`:1379-1395`) and
  `handle_client_msg` (R4). A satellite never reaches the `network_policy`
  path a `Tcp` peer takes; the later gates are not relied on for it. Allowed: `Hello`, `Subscribe`, `Ping`, and
  the admin verbs of the per-level table (C) only. Everything else, in
  particular every routable read verb (`SessionAttach`, `SessionDetach`,
  `ActivitySnapshotRequest`, `SessionModelGet`, `SessionList`, `FocusList`,
  with or without `host`), is refused with the normal network refusal frame,
  no side effect, and **never reaches the router**. Otherwise Kobe could send
  `SessionAttach { host: Some("sendai") }` (allowed for `Tcp`) and be handed
  Sendai's non-sensitive transcripts.
- **Topics.** `deliverable_topics` (`src/ipc/server.rs:3946-3955`) keeps
  **only** `Topic::Devices` for a satellite (and only when its level is not
  `off`); every other topic is removed, so a satellite subscribing to "all"
  gets nothing but `Devices`.
- **What it sees in `Devices` (M4).** A per-connection write step for
  `PeerTrust::Satellite`, applied after `outbound` on the broadcast,
  targeted and replay paths (`server.rs:1181`, `:1230`, `:1020-1150`; the
  pattern of `without_notes_unless_model`, `:1233`, defined `:3988`),
  rewrites `Devices.hosts` to the satellite's **own** record only (matched by
  the connection's device id, `PeerOrigin::ws_device`, `:445`). The phone and
  iPad rows stay (the satellite lists and revokes those). Without it,
  `DeviceRegistry::summaries` (`src/ipc/devices.rs:538-548`) gives Kobe every
  host's id, name, level, `connected` and `last_seen_at`. (`pair_from` in
  `DeviceAdminLevel` still names the `full` hosts: W15 needs it to say where
  to pair from, and it is names only.)

**C. Per-level table, final** (enforced in the new satellite arm of
`DeviceHub::dispatch`; replaces the shorter lists elsewhere in this file):

| Verb from a satellite | `full` | `revoke_only` | `read_only` | `off` |
|---|---|---|---|---|
| `DeviceList` | runs (hosts cut to own record) | runs (same) | runs (same) | refused |
| `DeviceRevoke` of a **phone or iPad** | runs | runs | refused | refused |
| `DeviceRevoke` of a **satellite** record (any, itself included) | refused | refused | refused | refused |
| `DevicePairStart` (device code) | runs | refused | refused | refused |
| `DevicePairStart { satellite: Some(_) }` (enrolment) | refused | refused | refused | refused |
| `DevicePairCancel` | runs, own `(connection, origin)` only | same | refused | refused |
| `DeviceSetAdmin` | refused | refused | refused | refused |
| `DeviceUnpairSelf` | refused (`Paired` only) | refused | refused | refused |

"Refused" is `DeviceAdminError { not_permitted_on_this_mac }` with no side
effect. **Decision (M4):** satellite records are changed only from the
primary's CLI (`device revoke`, `device admin`), like `DeviceSetAdmin`. W15's
"reducing access is safe from any surface" (`W15-mac-device-admin.md:60-62`)
is read as applying to phones and iPads; letting a `revoke_only` Kobe revoke
Sendai's satellite record (`DeviceRegistry::resolve`/`revoke` have no kind
filter, `devices.rs:397-426`, and re-enrolling needs the primary's CLI) is a
denial of service the operator did not ask for. The arm resolves the target
first and checks its kind: add a `kind` to what `resolve` returns (or a
`DeviceRegistry::kind_of(id)`).
**`DevicePairCancel` needs the origin (nit).** `PairingTable::cancel`
(`src/ipc/pairing.rs:199-210`) matches `issuer == caller`, and every
pairing a satellite relays has the same issuer (the uplink's `conn_key`), so
one local client of a `full` satellite could cancel another's pairing.
Match `(issuer, origin)` for relayed pairings: pass the frame's `origin` to
`cancel` (`device_hub.rs:318`).

**D. Downgrade race (S1).** `handle_client` runs in its own task behind a
256 KiB duplex (`src/ipc/ws.rs:553`), so verbs already buffered when the
epoch changes still dispatch with the old `Satellite { admin }` snapshot
before the 1012 close. The satellite arm of `DeviceHub::dispatch` therefore
uses `min(snapshot, current record level)`, reading the record through the
`ws_device` it already receives (`device_hub.rs:251-258`), and refuses if the
record is no longer an active satellite. `run_paired` must read the record's
kind, level and egress **after** `subscribe_epoch()` and
`borrow_and_update()` (`ws.rs:545-546`), next to the existing standing check
(`:547-551`), or a `set_admin` between the read and the subscription is
missed. (`set_admin` saves under the registry lock before bumping the epoch,
`devices.rs:456-484`, so there is no save-versus-reconnect race.)

**E. How `DeviceAdminLevel` is delivered (S2).** Every write path is gated by
class, and `SatelliteControl` passes for every satellite, so a broadcast
would reach all of them. On the **primary** it is never broadcast: it is
written to the connection's targeted sender (a) to a satellite on admission,
with its effective level and the current `pair_from`; (b) to a satellite
again from its own `run_paired` epoch arm when the set of `full` hosts
changes but its own level does not (its own level changing closes 1012
instead); (c) to a local client, `{ level: full, pair_from: [] }`, when it
subscribes to `Topic::Devices`. (b) goes through that satellite
connection's targeted sender (the handler's channel, so it passes the class
gate like every other write), never straight to the socket from
`run_paired`. **It is targeted on both sides (R1).** On a **satellite** too,
the uplink task keeps the set of local connections subscribed to
`Topic::Devices` (it already tracks local connections for `origin`) and
writes the narrowed `DeviceAdminLevel` to each one's targeted sender, on
subscribe and whenever the retained level changes. So one mode-independent
arm, `ServerMsg::DeviceAdminLevel { .. } => false`, goes in
`message_matches_topics` (`src/ipc/server.rs:4785`, beside W9's targeted
admin frames at `:4818-4826`; `deliver_broadcast`, `:4766`, is only its
wrapper), and an accidental broadcast is dropped on every daemon.

**F. Refusing a role (S3).** `PeerOrigin::resolve` returns a bare
`PeerTrust` (`src/ipc/server.rs:416`, called at `:766`). Change it to
`Result<PeerTrust, RoleRefused>`; on `Err`, `handle_client` writes
`Unauthorized { reason: "role" }` targeted and returns, and `run_paired`
closes with 4001 rather than its usual 1000 when the handler ended with a
role refusal (signal it through a flag the handler sets, since today the
`out_rx` close arm decides only from the registry standing, `ws.rs`). A
`role: Satellite` claim on a **Unix or TCP** connection is ignored: those
origins never yield `PeerTrust::Satellite` (test both).

**G. Names and egress at enrolment (S4).** The host check compares the
`Hello`'s host with the stored record name, which is the operator's
`--satellite` hint as stored (`device_hub.rs:197-201`, then de-duplicated,
`devices.rs:366`). `nostromo uplink pair` warns when `Paired.name` differs
from the satellite's `host_name` ("Enrolled as <name>, but host_name is
<host_name>: set host_name to match or re-enrol"). A satellite enrolled
before W10 has no recorded egress, so it reads as `work`, and nothing changes
egress later: a `personal` satellite (Sendai) enrolled before W10 must be
re-enrolled (revoke the old record on Tokyo, then `device pair --satellite
sendai --egress personal --admin full`). The memo's install row says so.

Add `src/ipc/uplink_wire.rs` (the `UplinkFrame` envelope, A0) to the files
this wedge creates.

Tests for A–G are in Approach step 5 and criteria W10-20 and W10-21.

## Refreshed 2026-11-23 against `origin/main` `8f0328b9`

Read the memo's "Readiness", "What changed since 2026-10-18", bet **B11** and
the per-topic publish table first; they win over older text here. Versus the
2026-10-18 version:
- **B11 (merge gate).** Frames the primary routes down are injected under a
  synthetic connection key. Register that key through the session manager's
  `attach_network` (`src/ipc/session_manager/mod.rs:2059-2060`), never
  `attach`, so it lands in `network_clients` and, after W9's B11 change, never
  closes a satellite session's merge gate while a phone watches. The uplink's
  own `Hello { role: Satellite }` declares no `capabilities`: it attaches to
  nothing on the primary (which hosts no sessions), and the primary's gate is
  irrelevant. New criterion W10-17.
- **`Hello` already has two optional fields** (`client_kind`,
  `capabilities`; `src/ipc/protocol.rs:1638-1652`). `role` is a third,
  additive one; do not reuse `client_kind` for it (on Unix that claim feeds
  operator verification; a WebSocket peer is never verified).
- **The metadata function covers 92 `ServerMsg` variants** (was 50). The 39
  new `LocalOnly` frames are dropped before it (step 1 of the forward filter)
  but still need an arm returning `None`, since the match has no `_`. The
  three new `Focus` frames: `TrackerSummary` → `{pseudonymous tag,
  has_tracker, counts}`; `SessionBridge` → `{pseudonymous tag, connected}`;
  `SessionTurnOrigin` → `None` (transcript family). `Topic::Terminal` and
  `Topic::AuthoredPrs` are never in `publish_topics`, on any profile.
- **Line references re-derived:** `handle_client_msg` `src/ipc/server.rs:1430`;
  `retain_broadcasts` `:4483`; `ServerMsg::MotherJobs` `protocol.rs:3077`,
  `MotherStatusline` `:3080` (struct `MotherStatus`, `src/mother/mod.rs:74`),
  `PerriState` `:3111`, `SessionListResp` `:3210`, `FocusListResp` `:3223`,
  `DecisionRequest` `:3286`, `DecisionResolved` `:3306`, `ApprovalPending`
  `:3367`; `ActivityEvent` `src/agent_bus.rs:19`; the activity tailer
  `src/bin/nostromd.rs:720-751`, the Mother poller `run_mother_pollers`
  `:864` (2 s, `:931`); the TCP listener and mDNS `:353-398`; `Config`
  `src/config.rs:51`. The old numbers in the body are superseded by these.
- **Gates.** Rust ≈ 5 min plus `python-test` ≈ 20 today (its `tests/**`
  matches the new Rust test files). This is the one wedge that crew delta 7
  helps: W10 edits no `Makefile` and no Swift path, so once `tests/**` is
  narrowed only the Rust gates fire (≈ 5 min). Kit runs only as the worker-run
  `make ci-remote ONLY=kit` check because `swift-ci`'s `when` excludes this
  wedge's paths.

## Sign-offs folded in (2026-11-23: Ada's memo and the operator's decisions)

Memo, "Decision log 2026-11-23". What changes here:
- **Q1, the `revoke_only` admin level, is enforced here.** W15 defines it
  ("Revoke-only device-admin level (Q1)"); this wedge implements the primary's
  policy and the level signal:
  - `PeerTrust::Satellite { admin }` and the local narrowing `device_admin`
    both take W9's `SatelliteAdmin` (`full | revoke_only | read_only | off`),
    ranked in that sequence by an explicit `rank()` (not a derived `Ord`; see
    the 2026-11-24 section, item 1); the effective level is the lower of the
    two.
  - Per verb on the primary: the final per-level table is in "Trust
    boundary on the primary", C. For `revoke_only` (v1: list and revoke
    only): `DeviceList` (hosts cut to its own record) and `DeviceRevoke` of a
    phone or iPad run, and `DevicePairCancel` of its own pairings;
    `DevicePairStart`, `DeviceSetAdmin` and `DeviceRevoke` of any satellite
    record get `DeviceAdminError { not_permitted_on_this_mac }` with no side
    effect. Admin frames (`Devices`) are delivered as for `read_only`. (There
    is no mail-and-todos verb in v1, Q2.)
  - An unset level is `revoke_only` for every enrolment, whatever its egress
    (Ada's rule). Sendai becomes `full` only when enrolled or set with an
    explicit `--admin full`.
  - New `ServerMsg::DeviceAdminLevel { level, pair_from: Vec<String> }` (no
    ordinal, which only `ClientMsg` has; arms in `classify_server_msg` and
    `redact_for_uplink_metadata`). Delivery is its own class,
    `ServerClass::SatelliteControl` (2026-11-24 section, item 7), not the
    `Admin` class filter: the primary writes it **targeted to that satellite's own
    uplink connection, whatever the level, `off` included** (otherwise an
    `off` satellite would never learn it is off), on uplink admission and
    when the set of `full` hosts changes ("Trust boundary on the primary",
    E; `deliver_broadcast` drops it). It is never broadcast and never sent
    to a `Paired`, `Tcp` or `Routed` peer, or to another satellite. `pair_from`
    lists the hosts whose level is `full`. The satellite lowers `level` by its
    local narrowing, retains it, and sends it to each local (non-network)
    client that subscribes to `devices`. A primary sends `{ level: full,
    pair_from: [] }` to each of its own local clients, targeted, when it
    subscribes to `devices`. W15 uses it to disable
    controls up front and to name the Mac to pair from. A level change
    reaches a live uplink by closing it with 1012 and re-admitting it
    (2026-11-24 section, item 9).
- **Q2: mail, calendar and todos stay home in v1, on every host, with no
  way to turn sharing on** (PRD AC56). This wedge **does not build**
  `uplink.publish_sensitive`: no satellite ever publishes `TeriState`,
  `FredState`, `Work*` or `TeriPicks` upstream, on either profile, so they
  never reach Tokyo's memory or retained cache either. Reason recorded in the
  decision log: Fred can read Microsoft 365 (Graph) and Google mail
  (`src/data/fred_mailbox_native.rs`, `src/data/graph_client.rs`,
  `src/data/fred_accounts.rs`); the operator said Fred on Sendai reads
  Google (2026-11-23), but v1 keeps mail and todos home by decision for
  every host. Opening it up is a later wedge.
- **Q3, Q5 (work-host text)**: unchanged; the metadata function already sends
  only kind-level enums, the host, the 8-hex ref and counts. **Q7**: the queue
  frames are `LocalOnly` and dropped at step 1 of the forward filter; a test
  row asserts `SessionQueue*` never reaches the primary on either profile.
- **PRD open question 4: answered yes on 2026-11-24; it no longer gates
  this wedge.** The employer's policy allows Kobe's job states, short refs
  and host name to leave Kobe (fixed-vocabulary metadata only, never
  Carefeed text), which is exactly what the `work` profile sends. Kobe is
  enrolled as a `work` satellite at install. If the policy ever changes,
  Kobe is simply not enrolled (or its satellite record is revoked): no Kobe
  rows or pushes, and Kobe's revoke-only administration lapses (PRD criteria
  12, 24's "works from Kobe", 50, and the lost-phone-at-work path); revoking
  then happens from Sendai or the server's terminal. The code is the same
  either way.
- **S7a** adds one field later: W13 puts `operator_presence` on
  `DecisionRequest`, and adds it to this wedge's metadata arm for that frame.
  Nothing to build here.
- New criterion W10-19 (revoke-only and the level signal).

## Refreshed 2026-10-18 against `origin/main` `d61c62d` (history)

Read `docs/plans/backplane-sequencing.md` first: "What changed since
2026-10-10", bets **B9** (egress profiles) and **B10** (approvals and
decisions are answered at the Mac only), the "Wire inventory" and the
per-topic publish table are binding on this plan. Versus the 2026-10-10
draft of this file:
- PTYs are gone (R2): no `Pty*` routing, no `host` on `PtyList`/`PtyInfo`,
  nothing about PTY bytes.
- No mutating verb is routed (B10). The router forwards only the read verbs
  FND-1 allows for network peers, and only to `personal` satellites.
- A satellite publishes through its **egress profile** (`personal` or
  `work`, default `work`) with a PHI-repo override, not through a single
  `publish_sensitive` switch defaulting to true.
- New trusts: `PeerTrust::Satellite { .. }` on the primary for an uplink
  connection, and `PeerTrust::Routed` on a satellite for frames the primary
  routes down (exactly `Tcp`'s policy).
- The CLI is the `nostromo` binary W9 adds (`src/bin/nostromo_cli.rs`).
- No `PROTOCOL_VERSION` bump; the primary advertises `"uplink"` and
  `"hosts"` in `Welcome.features`, and a satellite uplinks only when it sees
  them.
- Tests run in CI (RWX sandbox for Rust, GitHub Actions for Kit); hermetic.

## Context

After W9 (`docs/plans/backplane/W9-ws-transport.md`) `nostromd` has an
authenticated WebSocket listener and a `PeerTrust::Paired` tier. The
operator's topology (`docs/plans/backplane-sequencing.md`, bet B7) has one
**primary** daemon on an always-on host (Tokyo) and **satellites** on the
Macs that actually own agent sessions, repositories, Mother queues and Bishop posture
— in particular Kobe, a managed laptop that may only ever *dial out* and
must not be discoverable.

Today `nostromd` is a single role: it binds listeners, tails
`~/.claude/activity.jsonl` (`src/bin/nostromd.rs:325-362`), polls
`mother list --format json` every 2 s (`src/bin/nostromd.rs:384-390`,
`src/mother/mod.rs:228-240`), and broadcasts the results to local
subscribers through `Server`'s `broadcast::Sender<ServerMsg>`
(`src/ipc/server.rs:80-115`). The retained-frame cache
(`src/ipc/server.rs:54,107-109,1351`) replays the latest frame per key to a
newly subscribed client.

This wedge adds `mode = "satellite"`: the daemon keeps every local
behaviour, **binds nothing off-loopback and advertises nothing on mDNS**,
dials the primary with a satellite token, forwards its locally broadcast
frames upstream, filtered by its egress profile and tagged with its host
name, and accepts the few read-only `ClientMsg`s the primary routes back to
it. The primary learns to tag, merge and route by `host`. The result is that
Kobe's Mother jobs and "needs you" counts (as metadata) and Sendai's state
(as FND-1 allows) are visible from any device that can reach the primary,
while each Mac app keeps working over its local Unix socket with the VPN
down. Mother and Bishop are not modified, and Mother's broker socket is
never exposed: only the daemon's existing `mother list` poller output
(`src/bin/nostromd.rs:568-640`) is published. Nothing published or routed
can answer an approval, a decision or a Mother hold (B10).

It also carries **device administration upward** for Ada's pairing PRD
(`docs/prds/daemon-pairing-flow.md`, cited as PRD-ACn). The operator pairs,
lists and revokes phones and iPads from the Mac app on Sendai or Kobe
(PRD-AC11–13, AC18, AC23–25, AC50; there is no per-device scope to change in
v1, Q2), and both are satellites. W9 put the
device registry and every pairing on the primary, and made the admin verbs
work for local Unix clients there. This wedge lets a satellite forward those
verbs from **its own local clients** up its existing outbound uplink, and
relay the answers back. Nothing ever connects *toward* the satellite, so this
works from Kobe (PRD-AC12, AC24). How much a satellite may do is held on the
**primary**, in the satellite's own registry record (`admin:
SatelliteAdmin`, `full | revoke_only | read_only | off`, from W9,
`src/ipc/devices.rs:46-78`). A satellite's local config can
narrow it but never widen it. That keeps the decision about a managed laptop
(the PRD's open question 2, answered 2026-11-23: Kobe is `revoke_only`, Q1) on
the operator's own host.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-satellite-uplink`
- **Base:** `origin/main` (W9 merged)
- **Max cost:** $55 (expected ≈ $11 after the 2026-11-24 recalibration on W9's and W14's actuals, was ≈ $22; see the memo's Estimate)

## Files to change

- `src/config.rs:59-76` (struct), `:219` (`impl Default`) — add
  `mode: DaemonMode` (`Primary` default | `Satellite`), `host_name:
  Option<String>` (default: `gethostname()` lower-cased, first label),
  and an `uplink: Option<UplinkConfig>` table: `{ url: String,
  token_path: PathBuf (default ~/.nostromo/uplink-token, mode 0600),
  egress: Egress (`work` default | `personal`), phi_repos:
  Vec<String> (default `["admin-portal", "referral-monitor"]`; config may
  add, the two defaults cannot be removed), publish_topics:
  Option<Vec<Topic>> (default: all the profile allows), device_admin:
  SatelliteAdmin (W9's enum; `full` default here, `revoke_only`, `read_only`
  or `off`; a local *narrowing* of what the primary grants, parsed with
  `SatelliteAdmin::parse`) }`. (No `publish_sensitive`: Q2.)
  Env overrides `NOSTROMD_MODE`,
  `NOSTROMD_UPLINK_URL`. Validation: `Satellite` requires `uplink`; a
  `work` satellite requires an explicit `host_name` matching
  `^[a-z][a-z0-9-]{0,15}$` (an MDM may set the OS hostname to a person's
  name or an asset tag).
- `src/ipc/protocol.rs` — add `host: Option<String>` with
  `#[serde(default, skip_serializing_if = "Option::is_none")]` to the
  retained/stateful variants: `ServerMsg::MotherJobs` (`:3132`), the
  `MotherStatus` struct carried by `MotherStatusline` (`:3135`),
  `ActivityEvent` (`src/agent_bus.rs:19`), `SessionListResp` (`:3265`),
  `FocusListResp` (`:3278`), `PerriState` (`:3166`), `DecisionRequest`
  (`:3341`), `DecisionResolved` (`:3361`) and `ApprovalPending` (`:3422`;
  same two fields plus `host`), and (2026-11-24, for ingest's allow-list) also
  `SessionState` (`:3220`), `SessionBridge` (`:3229`), `FocusRegistryUpdated`
  (`:3282`), `FocusCreated` (`:3333`) and `TrackerSummary` (`:3804`). **Never add `host` to `MotherJob`**
  (`src/mother/mod.rs`): it is Mother's contract type, and
  `tests/fixtures/mother-contract/ipc_mother_jobs*.golden.json` must stay
  byte-identical when `host` is `None`. `MotherAwaitDetected` is not
  published upstream (the primary derives "awaiting" from host-tagged
  `MotherJobs`), so it gains no field. Add `host: Option<String>` only to
  the routable read verbs: `SessionAttach`, `SessionDetach`,
  `ActivitySnapshotRequest`, `SessionModelGet`, and give `SessionList` and
  `FocusList` an optional `host` while keeping their current wire form
  decodable. **Do not** add `host` to `MotherResume`, `MotherAction`,
  `DecisionAnswer`, `ApprovalAnswer`, `SessionSpawn`, `SessionSend`, or any
  tombstoned `Pty*` verb. Add `ClientMsg::Hello.role: Option<HelloRole>`
  (`Client` default | `Satellite { host, egress }`), and `ServerMsg::Hosts {
  hosts: Vec<HostInfo> }` (`{name, egress, connected_since, last_seen}`)
  plus `ServerMsg::HostUnavailable { host, reason }` (`not_connected |
  egress_metadata | busy`; `busy` is the outstanding-id cap, "Trust boundary
  on the primary", A5). Classify the new frames per the memo's wire inventory
  (`Hosts`, `HostUnavailable`: `Open`). Add `"hosts"` and `"uplink"` to
  `Welcome.features` on the primary. W9's admin frames (`DevicePairing`,
  `DevicePairOutcome`, `DeviceRevoked`, `DeviceAdminError`) gain an
  optional `origin: Option<String>` (`#[serde(default,
  skip_serializing_if)]`). A satellite stamps it with the local connection
  key that asked, and the primary echoes it, so the satellite can deliver
  the answer to that one local client. Add `DeviceAdminError` reasons
  `server_unreachable` and `not_permitted_on_this_mac` (today's reasons are
  `unknown_pairing`, `unknown_device`, `ambiguous_name`, `not_saved`,
  `devices_unavailable`; `device_hub.rs:321`, `:376-381`,
  `server.rs:1389`). Add `egress: Option<Egress>` to `DevicePairStart`
  (`:2615-2623`; 2026-11-24 section, item 3).
- `src/ipc/peer.rs` — add `PeerTrust::Satellite { admin: SatelliteAdmin }`
  (primary side, an uplink connection) and `PeerTrust::Routed` (satellite
  side, frames the primary routes down). Both are `is_network()`. `Routed`
  has exactly `Tcp`'s `network_policy` and `targets_sensitive_session`;
  `Satellite` does **not** get `Tcp`'s policy: it gets only
  `peer::satellite_allowed` (`Hello`, `Subscribe`, `Ping` and the per-level
  admin verbs; nothing routable; "Trust boundary on the primary", B). In
  `may_receive` (`:997-1010`) it receives `ServerClass::Admin` frames when
  its `admin` is at least `read_only`, and the new
  `ServerClass::SatelliteControl` (`DeviceAdminLevel`, `DeviceAdminError`)
  at every level including `off`; `Paired`, `Tcp` and `Routed` receive
  neither (2026-11-24 section, item 7). `PeerTrust` stays `Copy`
  (`SatelliteAdmin` is `Copy`). Add `pub fn redact_for_uplink_metadata(msg: ServerMsg,
  host_key: &[u8; 32], tags: &SensitiveTags) -> Option<ServerMsg>`: an **exhaustive match over
  every `ServerMsg` variant** (no `_` arm) implementing the memo's `work`
  column (metadata only; `None` for anything content-bearing), with focus
  tags replaced by `f-` + 8 hex of HMAC-SHA256(host_key, tag). The key is
  random per satellite, stored at `~/.nostromo/uplink-tag-key` (0600). Add
  `pub fn is_phi_scoped(msg, phi_repos) -> bool` for the override (a Mother
  job whose repo path's last component is in `phi_repos`; a focus whose
  project path's last component is in `phi_repos`). Mother's resolved `crew`
  blob (with its `phi_sensitive`) is **not** available to the daemon: `MotherJob`
  deliberately keeps only `crew_opt_in` (`src/mother/mod.rs`), so the name match
  is the whole override until Mother puts a wire-safe `phi_sensitive` boolean on
  the job (memo, "Needs a Mother-side change").
  **Mother overlay keys through the filter.** `host` stays on the envelope, so
  `MotherJob` and its golden fixtures are untouched. On a `personal` host the
  decoded crew keys (`activity`, `gates`, `review_wave`, `decision`,
  `attention_reasons`, `progress`) pass as decoded. In the metadata function
  keep only enums, counts and numbers: `state`, `paused_reason`, `activity`,
  `paused_at`, `progress.{pct,stage,paused,eta.{lo_s,hi_s,basis},moved_back.reason,
  flags[].{reason,since}}`, gate and lens counts, `attention_reasons[]` as
  `{reason,since,acked}`, and `decision` reduced to present/kind. Drop
  `progress.label`, `progress.eta.label` and every option or consequence
  string: Mother templates them, but a client can rebuild them from the enums
  and nothing else needs the text. Overlay fields are decoded per key and
  re-serialized from `src/mother/crew.rs`, so a key that struct does not model
  (for example `progress.signals.stage_share` or `eta.n`) does not reach the
  satellite's consumers; that is the MC1/MC6 type set, not this wedge's to
  widen.
- `src/ipc/uplink.rs` (new, satellite side) — `spawn(config, server:
  &Server)`: reconnect loop with the backoff shape of
  `src/data/relay_client.rs` (1 s → 60 s cap), `Authorization: Bearer` from
  `token_path`, `Hello { role: Satellite { host, egress } }`. If the
  primary's `Welcome.features` lacks `"uplink"`, log one WARN, close, and
  retry every 10 min. `Subscribe` is sent for `Topic::Devices` only (a
  satellite publishes; it does not consume state). **Forward:** subscribe to
  `server.broadcast` and the retained cache; for each frame apply, in order:
  (1) drop if `classify_server_msg` is `LocalOnly`, `Admin` or
  `SatelliteControl`, or the frame is a W9 pairing reply (`PairOffer`,
  `Paired`, `PairRefused`, `Unauthorized`, `DeviceUnpaired`), or the frame is
  `MotherPeek`, `MotherAwaitDetected`, `Welcome`, `Pong`, `Error`, a
  targeted reply, or not in `publish_topics`; (2) if `egress == work` or
  `is_phi_scoped`, pass it through `redact_for_uplink_metadata(msg, host_key,
  &sensitive_tags)`, which **runs the sensitive-tag filter** (the same
  `SensitiveTags` the network redaction uses): a focus-scoped frame for a
  sensitive tag, including every Huey tag, is dropped, and the session,
  focus and Mother-job lists lose their sensitive entries. The pseudonymous
  tag looks the same for a sensitive focus as for any other, so the primary's
  shape check cannot catch this: the forwarder must. W10c wires the daemon's
  `SensitiveTags` into the forwarder; else
  `peer::outbound(PeerTrust::Tcp, …)` (which already withholds
  Teri/Fred/work state frames; there is no exception in v1); (3) stamp `host`; send it as `UplinkFrame::publish` (frames of a variant outside ingest's host-carrying allow-list are not sent at all). On
  (re)connect, replay the retained cache through the same filter first.
  **Inbound:** a frame from the primary is accepted only if it is a routable
  read verb (`SessionAttach`, `SessionDetach`, `ActivitySnapshotRequest`,
  `SessionModelGet`, `SessionList`, `FocusList`) and the satellite is
  `personal`; it is then injected into the local `handle_client_msg` under
  `PeerTrust::Routed` with a synthetic `conn_key` `uplink:<id>`, where `id`
  is the opaque request id from the primary's `request { id, msg }` envelope
  (attached through `attach_network`, so B11 keeps the merge gate open), and
  targeted replies go back up as `reply { id, msg }` through the same egress
  filter ("Trust boundary on the primary", A0 and A5). Anything
  else from the primary (in particular `DecisionAnswer`, `ApprovalAnswer`,
  `ApprovalRefusalReport`, `MotherResume`, `MotherAction`, `PerriAction`,
  `Session{Spawn,Send,Interrupt,Control}`) is dropped with one WARN per
  variant per hour and never dispatched (B10 defence in depth). **Device-admin relay (upward):** a W9 admin
  verb from a *local, non-network* client of the satellite is stamped with
  `origin = <that conn_key>` and sent up the uplink. It is never executed
  locally (the satellite has no `devices.json` authority) and never accepted
  from a network peer or from a primary-injected message, so it cannot loop.
  If the uplink is down, the satellite answers at once with
  `DeviceAdminError { server_unreachable }` (PRD-AC18). If the local
  `device_admin` narrowing forbids the verb, it answers
  `not_permitted_on_this_mac`. Frames that come down with an `origin` go
  only to that local connection. When that local connection closes, the
  satellite sends `DevicePairCancel` for any pairing it started. When the
  uplink drops, every relayed pairing's local client gets
  `DevicePairOutcome::connection_lost`. The satellite subscribes upstream to
  `Topic::Devices` only (it still subscribes to nothing else), retains the
  latest `Devices` frame, and republishes it to its local clients, so the
  Mac's Devices list is live (PRD-AC23, AC25).
- `src/bin/nostromo_cli.rs` (W9) — add `nostromo uplink pair --url
  ws://<primary>:47101 <code>`. It dials the primary without a token and
  sends `Pair { code, name: <host_name>, kind: satellite }` against a code
  issued on the primary by `nostromo device pair --satellite <host>`. It
  writes the returned token to `uplink.token_path` (0600), creating the
  parent directory, and prints only `Enrolled <host> with <primary>`. The
  token is never printed. `nostromo device …` run on a satellite goes
  through the same relay as the Mac app.
- `src/ipc/router.rs` (new, primary side) — `HostTable`: `host → (conn
  sender, HostInfo)`. Registered when a `Hello { role: Satellite }` is
  accepted on the WS listener (W9's `ws.rs`), removed on disconnect; both
  broadcast `Hosts`. `route(msg: ClientMsg) -> Routed { Local | Remote(host) |
  Unavailable(reason) }` by the message's `host` field (`None` = local).
  Only the six routable read verbs carry `host`; a `work` host answers
  `Unavailable(egress_metadata)`.
- `src/ipc/server.rs:1556` — `handle_client_msg` runs the FND-1 refusal for
  the *requesting* peer first, then consults the router when
  `msg.host().is_some()`; `Remote` forwards and returns, `Unavailable`
  replies `HostUnavailable`. The retained cache key gains the host:
  `retain_broadcasts` (`:4652`) keys `MotherJobs` etc. by `(variant, host)`
  so one host's snapshot never overwrites another's; the host on a
  satellite's frame is the record's name, checked at ingest ("Trust boundary
  on the primary", A). Frames published by a satellite enter the primary's
  broadcast channel only through `router::ingest_from_satellite` and are
  filtered again per downstream peer by `peer::outbound`, so the primary
  never widens what the satellite sent. A satellite's own requests pass
  `peer::satellite_allowed` first and never reach the router (B).
  **Satellite admin authorisation (primary side):** the per-level table in
  "Trust boundary on the primary", C, using `min(snapshot, current record
  level)` (D). This is a new arm in `DeviceHub::dispatch`
  (`src/ipc/device_hub.rs:251`), before its `trust.is_network()` early
  return (`:268-270`). `deliverable_topics` (`:3946-3955`) keeps
  `Topic::Devices` for a satellite whose level is not `off`. Pairings started
  this way are owned by `(uplink connection, origin)` and are cancelled
  when the uplink drops. `Devices` broadcasts go to satellite connections
  whose record allows at least `read_only`.
- `src/ipc/ws.rs` (W9) and `PeerOrigin` (`src/ipc/server.rs:393-456`) —
  `run_paired` (`ws.rs:530`) looks up the record's kind, admin and egress
  and carries them on `PeerOrigin::Ws`; `PeerOrigin::resolve` (`:416-441`)
  recognises `Hello.role == Satellite` on a token whose registry record is
  `kind: satellite` with a matching host name and egress (refuse the role,
  4001, for a device token, and refuse a satellite token without the role),
  sets `PeerTrust::Satellite { admin }` from that record, and hands the
  connection to the router keyed by the record's name. In `run_paired`'s
  epoch arm, a satellite whose level changed is closed with 1012 (2026-11-24
  section, items 4 and 9). Read the record **after** `subscribe_epoch()`
  and `borrow_and_update()` (D); `resolve` returns `Result` so a role
  refusal closes 4001 (F). A satellite's frames are *published* into the
  primary's broadcast channel only through `router::ingest_from_satellite`
  (host = record name, the never-from-a-satellite variants dropped whatever
  the egress, the egress shape checked; "Trust boundary on the primary",
  A), and
  `Hello.role.egress` must match the egress recorded at enrolment (`nostromo
  device pair --satellite <host> --egress work|personal`, default `work`;
  an unset `--admin` is `revoke_only` on either egress). A
  satellite's token never appears in the phone/iPad device list.
- `src/ipc/devices.rs`, `src/ipc/pairing.rs`, `src/bin/nostromo_cli.rs` —
  the recorded egress (2026-11-24 section, item 3): `egress` on the satellite
  record and in `DeviceSummary` for hosts (`#[serde(default)]`, absent =
  `work`), carried from `DevicePairStart` through `PairingTable::start`
  (`pairing.rs:152-161`) to `DeviceRegistry::redeem` (`devices.rs:343`), and
  `nostromo device pair --satellite <host> --egress work|personal`.
- `src/bin/nostromd.rs:356` (TCP bind), `:389` (WebSocket listener), `:426`
  (`mdns::advertise`) — in `Satellite` mode: force
  `tcp_listen_addr()`/`ws_listen_addr()` to loopback (log if the config asked
  otherwise), **skip `mdns::advertise`**, and call `uplink::spawn`. In
  `Primary` mode: construct the `HostTable` and pass it to the WS listener.
- `src/mother/` — no change to `MotherJob` or `decode.rs`; the host travels
  on the envelope, not the job.
- `tests/uplink_roundtrip.rs` (new) — two in-process `Server`s in one tokio
  runtime (primary on `127.0.0.1:0` WS + tempdir Unix; satellite with its
  own tempdirs and `mode = satellite`). Drive the satellite's broadcast
  channel directly (no real Mother, no network beyond loopback).
- `tests/uplink_egress.rs` (new) — table-driven over **every** `ServerMsg`
  variant (built from the same constructor list the FND-1 classification
  tests use, so a new variant without a row fails): for `work`, assert the
  output contains none of a set of marker strings planted in every text
  field (titles, questions, plan paths, branches, repo names, prompts,
  choice labels, transcript text, pane content, activity text, PR titles,
  mail and todo text); for `personal`, assert the output equals
  `peer::outbound(PeerTrust::Tcp, …)`; for a PHI-repo job or focus under
  `personal`, assert the `work` behaviour.
- `README.md` §Daemon — primary vs satellite, `config.toml` example for
  Kobe, the "VPN down" behaviour, and the operator note that a satellite on
  a managed laptop should use a **split-tunnel** WireGuard profile
  (`AllowedIPs` = home subnet) with `uplink.url` pointing at the primary's
  WireGuard/LAN address, so corporate traffic stays on its own VPN.

## Approach

1. **Additive wire fields.** Land `host`/`role`/`Hosts` in `protocol.rs` with
   defaults so every existing decoder (Rust tests, `NostromoKit/Wire/*.swift`
   via `MotherWireTests` fixtures) keeps passing. Run the Rust suite (RWX
   sandbox) and `make ci-remote ONLY=kit` before touching behaviour.
2. **Router on the primary.** Implement `router.rs` and the
   `handle_client_msg` hook; unit-test `route()` and the per-host retained
   keys with no sockets.
3. **Uplink on the satellite.** Implement `uplink.rs` as a pure function of
   the `Server`'s channels; it must be startable in a test without the
   pollers.
4. **Mode wiring in `nostromd.rs`.** Satellite: loopback-only listeners, no
   mDNS, uplink task. Primary: host table. A primary with no `uplink` is
   byte-for-byte today's daemon.
5. **Round trip test.** A `personal` satellite broadcasts
   `MotherJobs{jobs:[j1]}` → the primary's Unix-socket subscriber receives
   it with `host: Some("sat")`; a `work` satellite's `MotherJobs` arrives
   trimmed to metadata. A subscriber sends `SessionAttach{host:
   Some("sat"), tag}` for a non-sensitive tag → the satellite answers with
   the transcript snapshot (personal) or the primary answers
   `HostUnavailable{egress_metadata}` (work); `SessionAttach{host:
   Some("nope")}` → `HostUnavailable{not_connected}`. A crafted primary
   that sends `DecisionAnswer`, `ApprovalAnswer` and `MotherResume` down the
   uplink → the satellite dispatches none of them (assert the decision
   registry, approval store and Mother stub saw nothing). Disconnect the
   satellite → the primary broadcasts `Hosts` without it; reconnect →
   retained `MotherJobs` for `sat` reappears.
   **Crafted satellite** (a test client holding a valid satellite token for
   record `kobe`, speaking the uplink protocol by hand): publishing
   `MotherJobs { host: Some("sendai") }`, `{ host: None }` or no host → the
   primary's retained `MotherJobs` for `sendai` and for the primary itself are
   unchanged and no subscriber receives the frame; publishing `Devices`,
   `DeviceAdminLevel { level: full, pair_from: ["kobe"] }`, `Hosts`,
   `HostUnavailable`, a pairing reply, `Welcome`, `Pong`, `Error` or a
   `LocalOnly` frame (on either egress) → neither the primary's Unix
   subscriber nor a second satellite (`sendai`) receives it; sending
   `SessionAttach { host: Some("sendai"), tag }`, `SessionList`,
   `FocusList` → refused, and the `sendai` satellite sees no routed frame;
   `Subscribe { topics: [] }` → receives only `Devices`; `DeviceList` →
   `Devices.hosts` holds only `kobe`'s record; `DeviceRevoke sendai` (by
   name and by id) at `full` and `revoke_only` → `not_permitted_on_this_mac`
   and Sendai's record stays active; `DeviceRevoke <phone>` at
   `revoke_only` → revoked. A `Hello { role: Satellite }` on the primary's
   Unix socket and TCP listener → never `Satellite` trust. With two local
   clients on a `full` satellite, one's `DevicePairCancel` of the other's
   `pairing_id` → `unknown_pairing`, and the pairing stays open. Buffer a
   `DeviceRevoke <phone>` behind a `set_admin kobe read_only` (paused
   handler) → refused (the current record level wins). Publishing a host-less
   open frame (`Withheld`, `DaemonReconnected`, `ModelCatalog`) → dropped. A
   `ServerMsg` sent without the envelope, or a `server`/`request` envelope
   from the satellite → dropped. **Routed replies:** a `reply { id, msg }`
   with an id the primary never issued, an expired id, an id issued for a
   request routed to `sendai` but sent by `kobe`, or a variant outside the
   verb's set → dropped, and no phone's targeted channel receives it; a
   `reply` from a `work` satellite → dropped (it never holds an id); an honest
   `personal` satellite's reply to a routed `SessionList` reaches only the
   requesting connection; an honest routed `SessionAttach` delivers its
   snapshot and then a live delta (neither carries `host`) to the requester
   only; a routed read refused on the satellite (sensitive tag) delivers the
   refusal `Error`/`Withheld` to the requester; a reply variant with a `host`
   field whose host is not the record's name → dropped. **Reply limits:** a
   crafted satellite sending 2,000 deltas in a second on one attach id → the
   excess is dropped and the phone's channel is not flooded; a requester
   opening a 33rd routed attach (per connection), and a 33rd outstanding id
   for one host across requesters → `HostUnavailable { reason: busy }`, and
   the satellite receives no 33rd request. **Shape:** an honest `work` satellite's
   `MotherJobs`, `DecisionRequest` and `SessionState` survive ingest
   (round trip through `redact_for_uplink_metadata` and
   `is_uplink_metadata_shape`). **Flood:** 1,000 `publish` frames in one
   second and one 300 KiB frame → the excess and the large frame are dropped
   and counted.
6. **Device-admin relay.** With the two-server harness (primary record for
   `sat` set to `admin: full`): a Unix client on the satellite sends
   `DevicePairStart` and gets `DevicePairing` with the **primary's**
   `server_url`. A WS device redeems the code against the primary, and the
   satellite's Unix client receives `DevicePairOutcome::paired` within 2 s.
   A second Unix client on the satellite does not see that outcome. Then:
   `DeviceRevoke` from the satellite takes effect on the primary; with the record at `read_only`, `DeviceList` works and
   `DeviceRevoke` gets `not_permitted_on_this_mac`; with the uplink down,
   `DevicePairStart` gets `server_unreachable` at once; closing the
   satellite's Unix client cancels its pairing on the primary (a later
   redeem gets `invalid`); and `Devices` updates reach the satellite's Unix
   client. With the record at `revoke_only` (Q1): `DeviceList` and
   `DeviceRevoke` take effect; `DevicePairStart` gets
   `not_permitted_on_this_mac` and changes nothing; the satellite's Unix
   client receives `DeviceAdminLevel { level: revoke_only, pair_from: [the
   full hosts] }` on subscribe, and again after `nostromo device admin` on the
   primary changes the level; with the record at `off` it still receives
   `DeviceAdminLevel { level: off }`; a local `device_admin = "read_only"`
   narrowing lowers what the client is told and enforced; an enrolment
   without `--admin` on a `personal` satellite is `revoke_only`.
7. **Egress gates.** `personal`: a `TeriState`, `FredState`, `Work*` or
   `TeriPicks` broadcast never reaches the primary (Q2). `work`: no
   `TeriState`, `FredState`, transcript, pane, activity or approval-content
   frame ever reaches the primary; `ApprovalPending` arrives with a
   pseudonymous tag and the count.

## Acceptance criteria

- [ ] **W10-1** CI is green: Rust in the RWX sandbox and the `ubuntu-24.04` Rust jobs,
  `swift-tests-kit` on GitHub Actions (`make ci-remote ONLY=kit` to
  re-run). **No local `cargo` or `swift`** (toolchain guard). No existing
  test is modified except to add fixtures with `host` present;
  `tests/fixtures/mother-contract/*.golden.json` are byte-identical, and so
  are the fixtures the five newly host-carrying frames touch when `host` is
  `None` (`skip_serializing_if`): `tests/fixtures/tracker/frame-tracker-summary.json`,
  the frames asserted in `tests/ipc_session_bridge.rs`, and
  `Shared/NostromoKit/Tests/NostromoKitTests/SessionBridgeWireTests.swift`.
- [ ] **W10-2** `tests/uplink_egress.rs` covers every `ServerMsg` variant and passes; a
  `work` satellite never emits a planted marker string.
- [ ] **W10-3** In `satellite` mode, `lsof -iTCP -sTCP:LISTEN -p <pid>` shows only
  loopback listeners and no `_nostromo._tcp` service is registered
  (`dns-sd -B _nostromo._tcp` returns nothing from this host).
- [ ] **W10-4** A satellite's `MotherJobs`, `MotherStatusline`, `ApprovalPending`,
  `FocusListResp` and (personal only) `Activity` arrive at the primary's
  subscribers with `host` set; the primary's own carry `host: None`.
- [ ] **W10-5** The six routable read verbs with `host: Some(h)` are answered by a
  `personal` satellite `h` within one round-trip; a `work` `h` →
  `HostUnavailable{egress_metadata}`; unknown or disconnected `h` →
  `HostUnavailable{not_connected}`.
- [ ] **W10-6** B10: no approval or decision answer, Mother resume/action, Perri action
  or session-driving verb is routed by the primary or dispatched by a
  satellite from its uplink.
- [ ] **W10-7** Retained frames are keyed per host: two satellites' `MotherJobs` coexist
  and a reconnecting client receives both.
- [ ] **W10-8** `personal` withholds exactly the frames
  `peer::may_receive(PeerTrust::Tcp, …)` would withhold, which includes every
  Teri, Fred and work frame, and no config key changes that (Q2, PRD AC56).
  `work` and PHI-scoped frames follow `redact_for_uplink_metadata`.
- [ ] **W10-9** With the uplink unreachable, the satellite's Unix-socket clients see no
  behaviour change other than a `Hosts`-style status frame indicating
  `uplink: disconnected`; reconnect uses exponential backoff capped at 60 s.
- [ ] **W10-10** A W9 device-admin verb sent by a local client of a satellite is executed
  on the primary and answered to that client alone, with no connection
  initiated toward the satellite. Pair outcomes arrive within 2 s of
  redemption (PRD-AC12, AC13 transport; W15 renders them).
- [ ] **W10-11** The primary enforces the satellite's registry `admin` capability. A
  satellite's local config can only narrow it. Satellite enrolment is never
  accepted over an uplink.
- [ ] **W10-12** Admin verbs from a satellite's network peers, or from primary-injected
  messages, are never forwarded upward.
- [ ] **W10-13** Uplink down → `DeviceAdminError { server_unreachable }` within 100 ms,
  and every relayed open pairing reports `connection_lost` to its client.
- [ ] **W10-14** `nostromo uplink pair` writes the token file with mode 0600 and never
  prints the token.
- [ ] **W10-15** No clippy warnings. PR body references the sequencing memo (W10).
- [ ] **W10-17** B11: a routed `SessionAttach` on a `personal` satellite registers its
  synthetic key as a network client; with a local client that declared
  `merged_turns_v1` attached (no verified app exists in a Linux test) and a
  routed attach present, queued typed messages on that session still merge
  (two-server harness).
- [ ] **W10-18** `redact_for_uplink_metadata` has an explicit arm for every
  `ServerMsg` variant on the wedge's base (no `_`): 102 on `4cafd5e8` plus
  W10's `Hosts`, `HostUnavailable` and `DeviceAdminLevel`, with W9's ten
  pairing and admin frames returning `None`; the egress test's constructor
  list includes `TrackerSummary`, `SessionBridge`, `SessionTurnOrigin`,
  every `LocalOnly` frame added since 2026-10-18, and W9's ten frames.
- [ ] **W10-19** Nothing about a sensitive focus leaves a `work` host:
  `redact_for_uplink_metadata` takes the daemon's `SensitiveTags` and returns
  `None` for `PerriState`, `SessionState`, `SessionBridge`, `ApprovalPending`,
  `DecisionRequest`, `DecisionResolved`, `TrackerSummary` and `FocusCreated`
  whose tag (or agent) is sensitive, and drops sensitive entries from
  `SessionListResp`, `FocusListResp`, `FocusRegistryUpdated` and `MotherJobs`
  (test per variant, with `huey` and a registered tag). The arms that return
  `Some` are exactly the 13 published types (a source-parsed test).
- [ ] **W10-16** A `work` satellite's `MotherJobs` built from a job in Mother's real
  HC-09 shape (`progress.signals.cost` as an object, `stage` one of
  `build|rework|gates|review|present|done`, `eta.n`, `attention_reasons` with
  `acked`) reaches the primary with the metadata keys above and no title,
  question, plan, branch, repo, label or option text. If the daemon's
  `CrewProgress` cannot decode that shape (its `signals.cost` is a scalar today),
  the test records which keys degrade instead of failing the wedge, and the PR
  body says so for MC6.
- [ ] **W10-19** Q1: the primary enforces `revoke_only` as list and revoke only
  (`DevicePairStart` refused with no side effect); an unset level is
  `revoke_only` on either egress; `DeviceAdminLevel` always reaches its own
  satellite, at every level including `off`, and that satellite's local
  `devices` subscribers with the effective (narrowed) level and `pair_from`;
  it is never broadcast or sent to a `Paired`, `Tcp`, `Routed` peer or another
  satellite.
- [ ] **W10-20** W9 as built: a satellite token is admitted as
  `PeerTrust::Satellite` only with `Hello.role = Satellite` whose host equals
  the record's name and whose egress equals the recorded one (otherwise
  `Unauthorized` and 4001), and a phone token claiming the role gets 4001;
  `DeviceSetAdmin` over an uplink is refused at every level with no side
  effect; an `off` satellite's refused verb is answered with
  `DeviceAdminError { not_permitted_on_this_mac }` (class
  `SatelliteControl`), which a `Paired` peer never receives; a satellite at
  `read_only` or above receives `Devices` on `Topic::Devices`, a `Paired`
  peer still does not; after `nostromo device admin <host> <level>` the
  uplink closes with 1012, reconnects, and the satellite's local subscriber
  receives the new `DeviceAdminLevel` within 3 s; no admin frame is ever
  forwarded upstream by a satellite. Satellite verbs and receipt ("Trust
  boundary on the primary", B–G): a satellite's `SessionAttach { host }` (and
  every other routable verb) is refused and never routed; it receives only
  `Topic::Devices`, with `Devices.hosts` cut to its own record; the
  per-level table C holds, including `DeviceRevoke` of any satellite record
  refused at every level and `DevicePairCancel` matching `(connection,
  origin)`; a verb buffered across a level downgrade is judged at the current
  record level; `DeviceAdminLevel` is never broadcast on the primary
  (`deliver_broadcast` returns `false`); a role refusal closes 4001; a
  `role: Satellite` on Unix or TCP never yields `Satellite`; `nostromo uplink
  pair` warns when the enrolled name differs from `host_name`.
- [ ] **W10-21** Ingest from a satellite ("Trust boundary on the primary", A;
  crafted-satellite test in Approach step 5): a frame whose `host` is not
  exactly the record's name (absent included) is dropped and never retained
  or delivered; every `LocalOnly`, `Admin` and `SatelliteControl` frame, the
  five W9 pairing replies, `Hosts`, `HostUnavailable`, `Welcome`, `Pong`,
  `Error`, `MotherPeek` and `MotherAwaitDetected` published by a satellite
  are dropped on either egress and reach no local client and no other
  satellite; only the host-carrying allow-list (A1) is ingested, so a
  host-less open frame (`Withheld`, `DaemonReconnected`, `ModelCatalog`) is
  dropped; a `work` satellite's frame must pass `is_uplink_metadata_shape`,
  and an honest one does; a satellite's socket carries only `UplinkFrame`
  envelopes (A0) and an unwrapped or wrong-direction frame is dropped; a
  routed `reply` is accepted only for an outstanding id issued for a request
  routed to that same `personal` host and with an allowed variant, and goes
  only to the requesting connection (an unsolicited, expired, foreign-host,
  `work`-host or wrong-variant reply is dropped and counted); replies use the
  verb's table instead of the host-carrying list (an honest routed
  `SessionAttach` delivers its snapshot and a delta), any reply variant with
  a `host` field must carry the record's name, no verb table contains a
  `LocalOnly`, `Admin`, `SatelliteControl` or pairing-reply variant (unit
  test), refusal `Error`/`Withheld` replies reach only the requester, and a
  reply must survive `outbound(Tcp)` unchanged; `publish` frames over
  256 KiB or above 50/s (burst 200), and malformed or wrong-direction
  envelopes (same bucket), are dropped and counted, with a 1008 close after
  30 s over the limit; replies have their own 200/s (burst 400) bucket, and
  outstanding ids are capped at 32 per requester and 32 per host
  (`HostUnavailable { busy }` beyond).

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`; rechecked at `0a38549` on
2026-11-23). The repo's `.mother/crew.yml` is on main since MC5 (#290): it is
read from the job's base ref, so a worker can neither add nor loosen a gate.

- **Gates that apply:** `rust-clippy` and `rust-test` (`where: sandbox`), `python-test` (`where: any`, on the host, when its `when` paths match; today `tests/**` matches the new Rust tests; after crew delta 7 it no longer fires here, since this wedge edits no `Makefile` and no Swift path). `swift-ci` is skipped (this wedge touches no Swift paths); the Kit run named in the criteria stays a worker-run check (`make ci-remote ONLY=kit`).
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to two fix attempts (`max_attempts: 2`), then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `phi-security`. Lenses run
  automatically in parallel with adherence on the gated commit (Mother #75,
  merged since this was first written); the repo default is all four lenses
  (`.mother/crew.yml:61`), so only a `remove` entry changes anything.
- **Review depth:** **Manual Perri pass is still required** (the `perri` entry below at xhigh, then the operator's review). Lens findings are input to it, not a substitute: a lens sees only the diff (patch input is capped at 120 KB, so a large wedge will report `coverage_gap` findings), and Mother's `phi-security` checklist is written for care data, so it does not know this repo's trust tiers (B9, B10). Egress filter on a managed laptop; routed frames into a satellite.
- **Checklist:** the acceptance items above carry ids (`W10-1` to `W10-21`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- Any Swift/iOS/Mac-app change — including showing `host` (W11) and the
  Mac Pair/Devices UI (W15).
- Executing device admin on a satellite. The registry exists only on the
  primary.
- `seq`/resume/replay-on-reconnect beyond retained-cache replay (W12).
- Terminals and PTYs of any kind (the PTY host is gone; terminal-pane
  frames are `LocalOnly`).
- Routing any mutating verb (B10 and the memo's resolved technical item).
- Publishing Mother's broker events or exposing its socket.
- Changes to Mother or Bishop; the satellite shells out to `mother` exactly
  as today.
- A public/hub endpoint for a satellite that cannot run WireGuard (the
  sequencing memo's risk section).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Two-daemon routing, per-host retained keys and an injected-command path under network trust; subtle and cross-cutting."
  redd:
    model: sonnet
    effort: high
    rationale: "The round-trip test runs two servers in one runtime and must assert routing, retention and sensitive gating in both directions."
  marty:
    model: sonnet
    effort: medium
    rationale: "Host plumbing will touch many variants; a pass to centralise host()/with_host() accessors is expected."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "Egress filter on a managed laptop with PHI repos, routed frames into a satellite, and device admin relayed up; every boundary must be airtight."
lenses:
  add: [correctness, tests, phi-security]
  remove: []
```

## Carry-forward from W10a (for W10b and W10c)

- A satellite's `Ping` gets no `Pong`: do not build a keepalive on it. Any
  refusal sent to a satellite must be `SatelliteControl` or pass `is_refusal`,
  or `may_receive` drops it.
- The HMAC tag key for `pseudonymous_tag` must be created, persisted
  (`~/.nostromo/uplink-tag-key`, mode 0600) and loaded by the uplink, which
  refuses to publish when it is missing. It never falls back to a default key
  (W10c).
- A `read_only`-or-above satellite receives the full `Devices` list until the
  "own record only" step lands in W10b.
- The forwarder passes the daemon's `SensitiveTags` to
  `redact_for_uplink_metadata` (W10c; step (2) above).
