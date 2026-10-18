# W10 — Satellite mode: a nostromd that publishes upstream and accepts routed actions

## Refreshed 2026-10-18 against `origin/main` `d61c62d`

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
lists, revokes and re-scopes phones and iPads from the Mac app on Sendai or
Kobe (PRD-AC11–13, AC18, AC23–25, AC35), and both are satellites. W9 put the
device registry and every pairing on the primary, and made the admin verbs
work for local Unix clients there. This wedge lets a satellite forward those
verbs from **its own local clients** up its existing outbound uplink, and
relay the answers back. Nothing ever connects *toward* the satellite, so this
works from Kobe (PRD-AC12, AC24). How much a satellite may do is held on the
**primary**, in the satellite's own registry record (`admin: full |
read_only | off`, from W9). A satellite's local config can narrow it but
never widen it. That keeps the decision about a managed laptop (the PRD's
open question 2) on the operator's own host.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-satellite-uplink`
- **Base:** `origin/main` (W9 merged)
- **Max cost:** $55 (expected ≈ $22; see the memo's Estimate)

## Files to change

- `src/config.rs:51-60, 160-226` — add
  `mode: DaemonMode` (`Primary` default | `Satellite`), `host_name:
  Option<String>` (default: `gethostname()` lower-cased, first label),
  and an `uplink: Option<UplinkConfig>` table: `{ url: String,
  token_path: PathBuf (default ~/.nostromo/uplink-token, mode 0600),
  egress: Egress (`work` default | `personal`), publish_sensitive: bool
  (default **false**; honoured only under `personal`), phi_repos:
  Vec<String> (default `["admin-portal", "referral-monitor"]`; config may
  add, the two defaults cannot be removed), publish_topics:
  Option<Vec<Topic>> (default: all the profile allows), device_admin:
  DeviceAdmin (`full` default, `read_only` or `off`; a local *narrowing* of
  what the primary grants) }`. Env overrides `NOSTROMD_MODE`,
  `NOSTROMD_UPLINK_URL`. Validation: `Satellite` requires `uplink`; a
  `work` satellite requires an explicit `host_name` matching
  `^[a-z][a-z0-9-]{0,15}$` (an MDM may set the OS hostname to a person's
  name or an asset tag).
- `src/ipc/protocol.rs` — add `host: Option<String>` with
  `#[serde(default, skip_serializing_if = "Option::is_none")]` to the
  retained/stateful variants: `ServerMsg::MotherJobs` (`:1623`), the
  `MotherStatus` struct carried by `MotherStatusline` (`:1626`),
  `ActivityEvent` (`src/agent_bus.rs:19`), `SessionListResp` (`:1732`),
  `FocusListResp` (`:1745`), `PerriState` (`:1657`), `DecisionRequest`
  (`:1808`), `DecisionResolved` (`:1828`) and `ApprovalPending` (`:1862`;
  same two fields plus `host`). **Never add `host` to `MotherJob`**
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
  egress_metadata`). Classify the new frames per the memo's wire inventory
  (`Hosts`, `HostUnavailable`: `Open`). Add `"hosts"` and `"uplink"` to
  `Welcome.features` on the primary. W9's admin frames (`DevicePairing`,
  `DevicePairOutcome`, `DeviceRevoked`, `DeviceAdminError`) gain an
  optional `origin: Option<String>` (`#[serde(default,
  skip_serializing_if)]`). A satellite stamps it with the local connection
  key that asked, and the primary echoes it, so the satellite can deliver
  the answer to that one local client. Add `DeviceAdminError` reasons
  `server_unreachable` and `not_permitted_on_this_mac`.
- `src/ipc/peer.rs` — add `PeerTrust::Satellite { admin: DeviceAdmin }`
  (primary side, an uplink connection) and `PeerTrust::Routed` (satellite
  side, frames the primary routes down). Both are `is_network()`. `Routed`
  has exactly `Tcp`'s `network_policy` and `targets_sensitive_session`;
  `Satellite` has the same policy plus the device-admin exception below, and
  receives `ServerClass::Admin` frames when its `admin` is at least
  `read_only`. Add `pub fn redact_for_uplink_metadata(msg: ServerMsg,
  host_key: &[u8; 32]) -> Option<ServerMsg>`: an **exhaustive match over
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
  (1) drop if `classify_server_msg` is `LocalOnly`, or the frame is
  `MotherPeek`, `MotherAwaitDetected`, `Welcome`, `Pong`, `Error`, a
  targeted reply, or not in `publish_topics`; (2) if `egress == work` or
  `is_phi_scoped`, pass it through `redact_for_uplink_metadata`; else
  `peer::outbound(PeerTrust::Tcp, …)`, except that Teri/Fred/work state
  frames pass when `publish_sensitive`; (3) stamp `host`; send. On
  (re)connect, replay the retained cache through the same filter first.
  **Inbound:** a frame from the primary is accepted only if it is a routable
  read verb (`SessionAttach`, `SessionDetach`, `ActivitySnapshotRequest`,
  `SessionModelGet`, `SessionList`, `FocusList`) and the satellite is
  `personal`; it is then injected into the local `handle_client_msg` under
  `PeerTrust::Routed` with a synthetic `conn_key` `uplink:<primary-conn-id>`,
  and targeted replies go back up through the same egress filter. Anything
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
- `src/ipc/server.rs:941` — `handle_client_msg` runs the FND-1 refusal for
  the *requesting* peer first, then consults the router when
  `msg.host().is_some()`; `Remote` forwards and returns, `Unavailable`
  replies `HostUnavailable`. The retained cache key gains the host:
  `retain_broadcasts` (`:1950`) keys `MotherJobs` etc. by `(variant, host)`
  so one host's snapshot never overwrites another's. Frames published by a
  satellite enter the primary's broadcast channel and are filtered again
  per downstream peer by `peer::outbound`, so the primary never widens what
  the satellite sent. **Satellite admin
  authorisation (primary side):** a W9 admin verb arriving on a satellite's
  uplink connection is executed only if that satellite's registry record
  has `admin: full`. With `read_only`, only `DeviceList` is executed and the
  rest get `DeviceAdminError { not_permitted_on_this_mac }`. With `off`,
  everything gets that error. `DevicePairStart { satellite: Some(_) }`
  (satellite enrolment) is always refused over an uplink. Pairings started
  this way are owned by `(uplink connection, origin)` and are cancelled
  when the uplink drops. `Devices` broadcasts go to satellite connections
  whose record allows at least `read_only`.
- `src/ipc/ws.rs` (W9) — recognise `Hello.role == Satellite` on a token
  whose registry record is `kind: satellite` (refuse the role, 4001, for a
  device token), set `PeerTrust::Satellite { admin }` from that record, and
  hand the connection to the router. A satellite's frames are *published*
  into the primary's broadcast channel only if their variant and shape are
  allowed for its declared egress (a `work` satellite may only publish the
  metadata shapes; anything else is dropped and counted), and
  `Hello.role.egress` must match the egress recorded at enrolment (`nostromo
  device pair --satellite <host> --egress work|personal`, default `work`). A
  satellite's token never appears in the phone/iPad device list.
- `src/bin/nostromd.rs:196-260` — in `Satellite` mode: force
  `tcp_listen_addr`/`ws_listen_addr` to loopback (log if the config asked
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
6. **Device-admin relay.** With the two-server harness (primary record for
   `sat` set to `admin: full`): a Unix client on the satellite sends
   `DevicePairStart` and gets `DevicePairing` with the **primary's**
   `server_url`. A WS device redeems the code against the primary, and the
   satellite's Unix client receives `DevicePairOutcome::paired` within 2 s.
   A second Unix client on the satellite does not see that outcome. Then:
   `DeviceRevoke` and `DeviceSetScope` from the satellite take effect on the
   primary; with the record at `read_only`, `DeviceList` works and
   `DeviceRevoke` gets `not_permitted_on_this_mac`; with the uplink down,
   `DevicePairStart` gets `server_unreachable` at once; closing the
   satellite's Unix client cancels its pairing on the primary (a later
   redeem gets `invalid`); and `Devices` updates reach the satellite's Unix
   client.
7. **Egress gates.** `personal` with `publish_sensitive = false`: a
   `TeriState` broadcast never reaches the primary; with `true` it does and
   the primary still withholds it from `Paired { sensitive: false }` and
   `Tcp` peers. `work`: no `TeriState`, `FredState`, transcript, pane,
   activity or approval-content frame ever reaches the primary, whatever
   `publish_sensitive` says; `ApprovalPending` arrives with a pseudonymous
   tag and the count.

## Acceptance criteria

- [ ] **W10-1** CI is green: Rust in the RWX sandbox and the `ubuntu-latest` job,
  `swift-tests-kit` on GitHub Actions (`make ci-remote ONLY=kit` to
  re-run). **No local `cargo` or `swift`** (toolchain guard). No existing
  test is modified except to add fixtures with `host` present;
  `tests/fixtures/mother-contract/*.golden.json` are byte-identical.
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
- [ ] **W10-8** `personal` with `publish_sensitive = false` withholds exactly the frames
  `peer::may_receive(PeerTrust::Tcp, …)` would withhold; `true` adds only
  the Teri/Fred/work state frames, and the primary still withholds them
  from `Paired { sensitive: false }` clients. `work` and PHI-scoped frames
  follow `redact_for_uplink_metadata`.
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
- [ ] **W10-16** A `work` satellite's `MotherJobs` built from a job in Mother's real
  HC-09 shape (`progress.signals.cost` as an object, `stage` one of
  `build|rework|gates|review|present|done`, `eta.n`, `attention_reasons` with
  `acked`) reaches the primary with the metadata keys above and no title,
  question, plan, branch, repo, label or option text. If the daemon's
  `CrewProgress` cannot decode that shape (its `signals.cost` is a scalar today),
  the test records which keys degrade instead of failing the wedge, and the PR
  body says so for MC6.

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`). Assumes the repo's
`.mother/crew.yml` is merged before this job is added (it is read from the job's
base ref, so a worker can neither add nor loosen a gate).

- **Gates that apply:** `rust-clippy` and `rust-test` (`where: sandbox`), `python-test` (always on; sandbox). `swift-ci` is skipped (this wedge touches no Swift paths); the Kit run named in the criteria stays a worker-run check (`make ci-remote ONLY=kit`).
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to three fix attempts, then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `phi-security`. Lenses run
  in parallel with adherence on the gated commit once Mother PR #75 merges
  (open at the time of writing); until then run
  `mother review-lens <id> --lens <name>` on the PR's job, one lens at a time.
- **Review depth:** **Manual Perri pass is still required** (the `perri` entry below at xhigh, then the operator's review). Lens findings are input to it, not a substitute: a lens sees only the diff (patch input is capped at 120 KB, so a large wedge will report `coverage_gap` findings), and Mother's `phi-security` checklist is written for care data, so it does not know this repo's trust tiers (B9, B10). Egress filter on a managed laptop; routed frames into a satellite.
- **Checklist:** the acceptance items above carry ids (`W10-1` to `W10-16`) so
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
