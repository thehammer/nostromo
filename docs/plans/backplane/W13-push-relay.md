# W13 — Push notifications: daemon push intents → AWS relay → APNs

## Context

With W9–W12 a phone sees the primary daemon's state whenever the app is open
and the VPN is up. It does not learn about a Mother job that is waiting on an
answer, or a decision request, while the app is backgrounded — iOS will not
keep the WebSocket alive. APNs is the only path, and APNs requires a
registered provider with a `.p8` signing key, which cannot live on the
operator's machines in a way a phone can reach. `docs/prds/push-relay.md`
is a stub describing exactly this component; `docs/plans/backplane-sequencing.md`
(B2, D5 in the prior design round) places it in the operator's **personal
AWS account** as a one-shot HTTPS endpoint. Bet B8 keeps the data plane
(WireGuard) separate: the relay carries only a title, a one-line subtitle and
an opaque deep link; detail is fetched over the VPN on tap.

**This wedge is gated on Ada's Q2** — the PRD must state the payload contract
(what text may appear in a notification) and the retention policy before
dispatch. The plan below assumes the conservative contract: the body never
contains a PR title, mail subject or todo text; it names the kind of event,
the host and a job id.

## Target
- **Repo:** nostromo (daemon + iOS) and a new `infra/push-relay/` directory in
  the same repo
- **Branch:** `feat/backplane-push-relay`
- **Base:** `origin/main` (W12 merged)

## Files to change

- `src/push/mod.rs`, `src/push/intent.rs` (new) — `PushIntent { kind:
  PushKind, host: Option<String>, job_id: Option<String>, deep_link: String,
  title: String, subtitle: String }` with `PushKind ∈ { mother_await,
  decision_request, perri_review_requested }`. `PushPublisher::spawn(config,
  rx)` POSTs intents to `relay.url` with `Authorization: Bearer
  <relay.daemon_token>` via `reqwest` (`Cargo.toml:88`, already present);
  5 s timeout; on failure log at WARN and drop (no retry queue — the phone
  catches up on next connect). Rate limit: at most one push per `(kind, job_id)`
  per 10 minutes.
- `src/bin/nostromd.rs` — on the primary only: subscribe to the broadcast
  channel and turn `MotherAwaitDetected` (`protocol.rs:1235`),
  `DecisionRequest`, and Perri review-requested frames into intents.
  Satellite-origin frames carry `host`, so a Kobe job produces "Mother job on
  kobe needs an answer".
- `src/config.rs` — `[push] url, daemon_token_path (default
  ~/.nostromo/push-relay-token), enabled = true`.
- `src/ipc/protocol.rs` — `ClientMsg::RegisterPush { apns_token: String,
  environment: sandbox | production }`; the daemon forwards it to the relay's
  `/devices` endpoint keyed by the connection's device id (W9) so the relay
  never learns anything but `(device_id → apns_token)`.
- `infra/push-relay/` (new) — a small Lambda behind a function URL:
  `POST /push` (daemon bearer; body = `PushIntent` + `device_ids`), `POST
  /devices` (daemon bearer), delivery to APNs with token-based auth (`.p8`
  from Secrets Manager), per-device rate limit (DynamoDB TTL table, 1 push /
  device / 30 s), structured logs with **no payload text** — only kind,
  device id hash, APNs status. Deploy with a ~60-line SAM template or CDK;
  language is the implementer's choice (Rust via `cargo lambda` keeps one
  toolchain). `README.md` in the directory covers: creating the APNs key,
  the two secrets, `sam deploy`, and rotating the daemon token.
- `iOS/Nostromo/NostromoApp.swift` — register for remote notifications;
  on token, send `RegisterPush` over the WS; on notification tap, deep-link
  to the Mother job / decision (`nostromo://job/<host>/<id>`).
- `iOS/Nostromo/Info.plist` + entitlements — `aps-environment`.
- `tests/push_intent.rs` (new) — intent derivation from frames, rate limit,
  the publisher against a local `httpmock`/`wiremock` server (asserts the
  bearer header and that the body contains no field other than the
  contract's); failure → dropped, no retry.
- `infra/push-relay/tests/` — handler unit tests with an APNs stub: auth
  required, rate limit, payload passthrough is the contract fields only.

## Approach

1. Confirm Q2's payload contract; encode it as a Rust type with no free-text
   fields beyond `title`/`subtitle` generated from an enum, so a future
   change must be deliberate.
2. Daemon side: intents, publisher, config, `RegisterPush`.
3. Relay: handler + template + README; deploy to the personal account;
   record the function URL and the daemon token in the operator's
   `~/.nostromo/` (not in the repo).
4. iOS: registration and deep links.
5. End-to-end: `mother await` on a satellite → notification on the phone.

## Acceptance criteria

- `cargo test`, relay tests and `swift test` pass.
- A `MotherAwaitDetected` on any host produces at most one APNs push per
  `(job_id)` per 10 minutes, delivered within 10 s when the relay is up.
- The notification body contains only contract fields: no PR title, mail
  subject or todo text (asserted by test against the intent type and by a
  relay test).
- Relay down → the daemon logs once per minute at most and drops; the phone
  still shows the awaiting job on next connect.
- The relay refuses requests without the daemon bearer; rotates the token
  without redeploy (Secrets Manager).
- Tapping a notification opens the referenced job over the VPN; with the
  VPN off, the app shows the `.unreachable` banner (W11) rather than an
  empty screen.
- `infra/push-relay/README.md` lets the operator deploy from zero.
- PR body references the sequencing memo (W13) and the push-relay PRD.

## Out of scope

- Any payload beyond the contract; rich notifications; actions in the
  notification (answer from the lock screen) — a later wedge once Q2 settles.
- Hosting in the Carefeed AWS account.
- Non-Apple push.
- Hub/relay for the data plane.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Three surfaces (daemon, Lambda, iOS) and a privacy contract that must be enforced in types, not comments."
  redd:
    model: sonnet
    effort: high
    rationale: "Contract tests on both ends plus a mocked APNs; rate limiting and failure-drop behaviour must be deterministic."
  marty:
    model: sonnet
    effort: medium
    rationale: "Intent derivation will start as a match in nostromd.rs and should move into src/push."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First data leaving the operator's machines to a hosted component; review the payload and logging contract adversarially."
```
