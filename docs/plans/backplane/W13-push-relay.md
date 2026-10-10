# W13 — Push notifications: closed-vocabulary push engine on the primary, a stateless AWS relay, and iOS registration

## Context

After W9–W12, a phone sees the primary daemon's state whenever the app is
open and the VPN is up. When iOS suspends the app (commute, meeting), the
operator does not learn that a Mother job is waiting on an answer, that an
agent session raised a decision (default timeout 5 min,
`src/mcp/tools/ask_decision.rs:38`), or that a PR entered their review queue.
The only way to reach a suspended app is Apple Push (APNs). APNs needs a
provider holding a `.p8` signing key, so this wedge adds a small relay in the
operator's **personal AWS account**. Bet B2 in
`docs/plans/backplane-sequencing.md` keeps the data plane on WireGuard; the
relay carries only notification text.

The product contract is `docs/prds/push-relay.md` (Ada's PRD). Read the whole
file, including **"Design-loop notes for Ada"** at the end: it records the
operator's answers to the two open questions, sign-offs S1–S6, and
clarifications C1–C8 that this plan implements. In short:

- Every notification is built only from a **closed vocabulary**: kind, host
  name, a short reference, and fixed phrases and numbers that Nostromo
  generates. **No worker-, agent-, person- or GitHub-authored text ever goes
  to the relay.** Repository names appear only for hosts the operator
  classified as **personal**; unclassified means **work**.
- Three kinds (Mother awaiting, decision request, PR review requested) plus a
  **Summary**. Summaries come from burst coalescing, the 07:00 digest at the
  end of quiet hours, and an **evening summary at 17:30** (operator answer to
  open question 1; configurable per device).
- A **2-minute grace delay** for Mother and review items (skipped if
  resolved). Decisions go out immediately. Also: quiet hours
  (default 22:00–07:00, phone-local), per-kind switches per device, and one
  notification per item over its lifetime.
- **Withdrawal** of a resolved item's notification, the badge kept equal to
  the number of waiting items, and expiry (decision deadline, else 4 h).
- A **Sent notifications** log kept on the operator's machines for 7 days, and
  a "not delivered since" banner.
- The relay keeps only `{time, kind, outcome, anonymous device ref}` for
  7 days.

On-phone enrichment, lock-screen decision actions, and the Notification
Service Extension that does withdrawal on the phone are **W16**
(`docs/plans/backplane/W16-ios-push-enrichment.md`), which depends on this
wedge. This wedge delivers working, contract-text notifications end to end.
Withdrawal here uses badge-only and background pushes (see S1 in the PRD
notes).

Where things live:

- **Primary** (Tokyo, `mode = primary`, W10): runs the push engine. It sees
  every host's frames: local ones on its broadcast channel, and satellite
  ones arriving host-tagged over the uplink.
- **Satellites** (Kobe, Sendai): send nothing to the relay. They only stamp
  facts the primary needs onto frames they already publish.

## Target
- **Repo:** nostromo (daemon and iOS) plus a new `infra/push-relay/` crate in
  the same repo
- **Branch:** `feat/backplane-push-relay`
- **Base:** `origin/main` (W12 merged; W9–W11 are therefore merged too)

## Files to change

Daemon wire and data (additive; every new field is `#[serde(default)]` and
skipped when `None`, so W9–W12 fixtures still decode):

- `src/ipc/protocol.rs:1467-1478` (`ServerMsg::DecisionRequest`). Add three
  fields:
  - `deadline: Option<DateTime<Utc>>`.
  - `agent: Option<String>`: the raw `agent_name` of the session owning
    `tag`. It is used only to pick from the fixed set; it is never sent
    through the relay.
  - `local_operator: bool`: whether a client that renders decisions was
    connected to the *originating* daemon when it was broadcast.
  `:1487-1493` (`DecisionResolved`) and `:1256-1260` (`PerriState`) gain
  `host: Option<String>`, stamped by the W10 uplink exactly like
  `MotherJobs`. `ClientMsg::DecisionAnswer` (`:1112-1116`) gains
  `host: Option<String>` so the W10 router (`src/ipc/router.rs`) forwards an
  answer to the satellite that owns the decision.
- `src/ipc/decisions.rs:159-197` (`DecisionRegistry::submit`). Take
  `deadline` and `agent`, put them on the `DecisionRequest`, and set
  `local_operator` from `has_operator_for` at broadcast/promotion time.
  `src/mcp/tools/ask_decision.rs:91-109` computes
  `deadline = now + timeout_secs` before `submit` and looks up the tag's
  `agent_name` through `SessionManager` (`src/ipc/session_manager.rs:154`,
  `list()` at `:1300`).
- `src/ipc/decisions.rs:328-338` and `src/mcp/tools/ask_decision.rs:84-89`.
  Add a `push_available: bool` input to the fail-fast gate: `has_operator_for`
  also returns true for **non-sensitive** tags when the primary reports that
  at least one device would receive a decision push right now (registered,
  decision kind on, outside its quiet hours). How it is computed:
  - The primary computes it and broadcasts `ServerMsg::PushAvailability
    { available: bool }` whenever it changes.
  - A satellite receives it on its uplink (W10 injects primary→satellite
    frames) and stores it in its registry.
  This is PRD clarification C3.
- `src/mother/mod.rs:166-207` (`MotherJob`). Add
  `#[serde(default)] activity: Option<String>` (Mother's sub-state:
  `adherence_blocked`, `operator_hold`, `pipeline_blocked`, …; distinct from
  the broker's `current_activity` at `:190-192`) and
  `#[serde(default)] paused_at: Option<DateTime<Utc>>`. Both fields are
  already in `mother list --format json`.
- `src/data/perri_queue_native.rs:228-235` (`PrDetail`). Deserialise
  `additions` and `deletions` (`#[serde(default)] Option<u64>`). Then:
  - `GetPrHeadResult::Open` (`:243`, built at `:1928`) carries
    `changed_lines: Option<u64>` (additions + deletions).
  - `ci_state_cached` (`:1709-1742`) returns it alongside the SHA, and the
    bucket-1/2 fold at `:1108-1113` and `:1259-1262` stores it on `Candidate`
    (`:357-381`, new `changed_lines: Option<u64>`).
  - `classify`/`render_items` (`:477-563`) copy it to `PrQueueItem`
    (`src/data/perri_queue.rs:105-131`, new
    `#[serde(default, skip_serializing_if = "Option::is_none")]
    changed_lines: Option<u64>`).
  - In `src/data/perri_queue_targeted.rs`, add `additions deletions` to the
    GraphQL probe query (`:840-880`), carry them on `ProbedPr` (`:791`), and
    write them in `upsert_from_probe`.
  - No new GitHub requests. The queue tests that count requests must stay
    unchanged.
- `src/config.rs:51-136` (`Config`). Add a `push: Option<PushConfig>` table,
  read **on the primary only**:
  - `relay_url`.
  - `relay_token_path` (default `~/.nostromo/push-relay-token`).
  - `enabled` (default `true`).
  - `hosts: BTreeMap<String, HostClass>` with `HostClass ∈ { work, personal }`.
    An absent host is `work`.
  - `work_owners: Vec<String>` (default `["Carefeed"]`; PRD S5).
  - `grace_secs` (default 120; tests only).
  The key is `push.relay_url`, not top-level `relay_url`: `Config.relay_url`
  (`:105`) is the GitHub relay.

Daemon push engine (new module):

- `src/push/mod.rs`: `PushEngine::spawn(config, server)`. It is primary-only
  and is a no-op without `[push]`. It subscribes to the broadcast channel,
  and it also reconciles every 30 s against the retained-frame cache
  (`retain_broadcasts`, `src/ipc/server.rs:1351`) so that a lagged receiver or
  a W12 `Gap` cannot strand an item.
- `src/push/items.rs`: the **item model**. `ItemKey` is one of:
  - `Mother{host, job_id}`
  - `Decision{host, request_id}`
  - `Review{host, repo, number}`
  Each item also carries an opaque random `item_ref` (16 hex chars) that is
  the only identifier sent to the relay. Items are derived from snapshots, not
  only from events:
  - **Mother:** `state == "awaiting"` and `paused_reason` not starting with
    `quota_`.
  - **Decision:** active `DecisionRequest` until `DecisionResolved` arrives or
    `deadline` passes.
  - **Review:** present in the PerriState queue with `bucket == "requested"`
    (PRD clarification C2). A PR seen on two hosts is one item, keeping the
    first host.
  The "waiting set" drives the badge, withdrawal and summaries.
- `src/push/vocab.rs`: **every** fixed phrase as a `const`, plus the
  renderers that produce `{title, body}` per kind from typed inputs only.
  Free-text fields (`question`, `prompt`, `title`, `author`, …) are not
  parameters of any renderer.
  - **Mother reasons:** map `paused_reason`/`activity` to the PRD's phrases:
    - `user` → *asked a question*
    - `adherence_blocked` → *blocked after review*
    - `operator_hold` → *held after a failure*
    - `cost_cap` → *paused at its spend cap*
    - `activity == pipeline_blocked` → *pipeline blocked*
    - anything else → *needs you*
  - **Agent set:** map `agent` case-insensitively to *Mother / Perri / Fred /
    Teri / Claudia*, else *A session*.
  - **Decision timeout:** minutes rounded down; *times out in under 1 min*
    when below 60 s (S6).
  - **Review size:** `< 50` → small, `≤ 400` → medium, `> 400` → large. The
    size phrase is omitted when unknown (S3).
  - **Job ref:** the 8-hex suffix of Mother's id
    (`YYYYMMDDTHHMMSSZ-xxxxxxxx`, `~/Code/mother/plugins/mother/bin/mother:74-80`),
    validated `^[0-9a-f]{8}$`. If it does not validate, the body becomes
    `A job <reason>`.
  - **Host label:** must match `^[a-z][a-z0-9-]{0,15}$`, else the literal
    `host` (C6).
  - **Repository name:** only when `hosts[host] == personal` (and for reviews
    also owner ∉ `work_owners`), rendered as the bare repo name without the
    owner, and must match `^[A-Za-z0-9._-]{1,40}$`, else omitted.
  - **`conforms(text, &VocabContext) -> Result<(), Offending>`:** the
    allow-list grammar checker the tests use.
- `src/push/schedule.rs`: a pure state machine driven by an injected clock
  (`now` passed in; no `Instant::now()` inside) so tests run on paused time.
  - **Grace delay:** `due = start + grace_secs`, where `start` is Mother's
    `paused_at` or first-seen time, and a review's first-seen-in-`requested`
    time (C1). Decisions are due at once.
  - **Skip-if-resolved:** logs `skipped_resolved_in_grace`.
  - **Coalescing with exact lookahead (S2):** when a grace-delayed item comes
    due, count pending unresolved grace-delayed items due in `[now, now+120 s)`
    for that device. If the count is ≥ 4, send one Summary covering them and
    mark them `coalesced` (they never push individually). Decisions are
    excluded.
  - **Per-device quiet hours:** IANA tz from the device; use `chrono-tz`, add
    to `Cargo.toml`. During quiet hours items are logged `held_quiet_hours`
    and never pushed individually.
  - **Morning summary** at quiet-hours end, and **evening summary** at
    `evening_summary` (default 17:30; skipped if inside quiet hours; `None`
    disables). Each is sent iff ≥ 1 enabled item is still waiting. The morning
    one fires at the configured end time even when quiet hours are off.
  - **Per-kind switches:** a disabled kind produces nothing and is excluded
    from summaries and from that device's badge.
  - **One notification per item lifetime.** A Mother job that leaves
    `awaiting` and re-enters is a new item.
- `src/push/devices.rs`: per-device push registration, stored on the primary
  in `~/.nostromo/push/devices.json` via atomic write (tmp + rename), keyed by
  the W9 device id. Each record holds:
  - `apns_token` and `environment` (`sandbox|production`).
  - `push_id`: random 128-bit, the relay's *anonymous device reference*.
  - `capabilities { nse_withdraw: bool }`: set by W16 builds; always `false`
    here.
  - `prefs { kinds: {mother, decision, review}: bool, quiet: Option<{start,
    end}>, evening_summary: Option<HH:MM>, tz: String }`.
  Before every send, check the W9 device registry. A revoked or unknown device
  is dropped and its push record deleted, so nothing is sent after revocation.
- `src/push/publisher.rs`: `POST {relay_url}/push` with `Authorization: Bearer
  <token>` via `reqwest` (`Cargo.toml:88`), 5 s timeout, **no retry and no
  queue**. Body (serde, `deny_unknown_fields` mirrored in the relay):
  `{push_id, apns_token, environment, push_type: alert|background,
  priority: 5|10, expiration_unix, collapse_id: item_ref, thread_id: host
  label, interruption_level: active|time-sensitive|passive, title?, body?,
  badge, mutable_content: bool, data: {item, kind, host, ref, withdraw?:
  [item_ref]}}`.
  - `thread_id` = host label groups the lock screen by host.
  - Decisions use `time-sensitive`; Mother and review use `active`.
  - Expiration: the decision deadline, else now + 4 h.
  - Withdrawal when `nse_withdraw == false`: one badge-only alert push
    (`badge`, no title/body/sound, priority 5) plus one background push with
    `data.withdraw`. When `nse_withdraw == true`, W16 changes this.
  The relay's response, `{apns_status, apns_reason}`, determines the outcome
  logged.
- `src/push/sent_log.rs`: an append-only `~/.nostromo/push/sent.jsonl` on the
  primary. Each line: `{ts, push_id, kind, host, title, body, outcome}`, where
  outcome ∈ `delivered_to_apple | rejected_by_apple | relay_unreachable |
  held_quiet_hours | coalesced | withdrawn | skipped_resolved_in_grace`.
  Entries older than 7 days are pruned on every append and hourly. Also
  tracks per-device `last_ok_at` and `failing_since` for the banner.
- `src/ipc/protocol.rs` (new messages; `"push"` added to `Welcome.features`):
  - `ClientMsg::RegisterPush { apns_token, environment, tz }`.
  - `ClientMsg::SetPushPrefs { prefs }`.
  - `ClientMsg::PushSentLog` → `ServerMsg::PushSentLog { entries }`, for this
    device only.
  - `ClientMsg::PushWaiting` → `ServerMsg::PushWaiting { items: [{item_ref,
    kind, host, ref}], badge }`: the reconcile-on-open answer.
  - `ServerMsg::PushStatus { prefs, host_classes, last_ok_at,
    failing_since }`: targeted reply to the device. Host classes are
    **read-only**; there is no `ClientMsg` that changes them.
  - `ServerMsg::PushAvailability { available }`.
  - A network peer may only read or write its *own* device's push record.
- `src/bin/nostromd.rs:117-160`: in `Primary` mode with `[push]`, call
  `PushEngine::spawn`.
- `src/main.rs` (clap command enum at `:35`): add `nostromo push host <name>
  work|personal`, which edits `[push.hosts]` in the primary's `config.toml`
  (the engine re-reads `[push.hosts]` on each render, so no restart and no
  new reload message is needed). Also
  `nostromo push status`: devices with prefs, last delivery, and the relay
  URL, but never tokens. Classification can only be changed from a shell on
  the primary.

Relay (`infra/push-relay/`, new standalone Rust crate, **not** a workspace
member; build with `cargo lambda`):

- `src/main.rs`: an AWS Lambda behind a function URL. It exposes two
  endpoints:
  - `POST /push`: requires the daemon bearer; the body is the schema above
    with `deny_unknown_fields`, `title` ≤ 64 and `body` ≤ 96 UTF-8 chars,
    `data` keys exactly the listed ones. It sends to APNs over HTTP/2 with an
    ES256 provider JWT (`jsonwebtoken`), the `.p8` read from Secrets Manager
    and cached ≤ 50 min. It sets `apns-push-type`, `apns-priority`,
    `apns-expiration`, `apns-collapse-id` and `apns-topic`, and returns
    `{apns_status, apns_reason}`.
  - `GET /records`: requires the daemon bearer; returns that `push_id`'s
    delivery records, filtered to `ts > now − 7 d` on read.
  The relay stores **no** device registry and **no** title, body, host, ref or
  repo. It writes one DynamoDB item per attempt: `{push_id, ts, kind, outcome,
  expires_at = ts + 7 d}`, with TTL on `expires_at`. Because TTL deletion is
  lazy, the read-time filter is what enforces "no record older than 7 days".
  `kind` ∈ `mother|decision|review|summary|withdraw|badge`.
  The handler logs only `kind`, a 6-hex prefix of `push_id`, and the APNs
  status.
- A safety ceiling of 60 pushes per `push_id` per 10 min (a DynamoDB counter
  with TTL). Product-level rate shaping is the daemon's job.
- `template.yaml`: SAM template defining:
  - the function and its URL (auth NONE; bearer checked in code);
  - the DynamoDB table with TTL;
  - the two Secrets Manager secrets (APNs key + key id + team id + topic;
    daemon token);
  - the log group with `RetentionInDays: 7`.
- `README.md`: everything needed to deploy from zero:
  - create the APNs auth key;
  - create the two secrets;
  - `sam build && sam deploy --guided`;
  - write the function URL into `[push] relay_url` and the token into
    `~/.nostromo/push-relay-token` on the primary;
  - rotate the daemon token without redeploy (update the secret; the handler
    re-reads it at most every 5 min).
  It also includes the PRD's privacy note verbatim. A short "host names"
  section says: set `host_name` explicitly in each satellite's `config.toml`,
  because the default comes from the OS hostname, which an MDM may set (C6).
- `tests/handler.rs`: run against an APNs stub (`wiremock`). Cover: bearer
  required; unknown body field → 400; over-long title → 400; record written
  with exactly `{push_id, ts, kind, outcome, expires_at}`; records older than
  7 d are not returned even if present in the table (use an in-memory store
  trait); headers mapped correctly.

iOS app (contract-text notifications, no extension; W16 adds the extension):

- `iOS/Nostromo/NostromoApp.swift`: add an `@UIApplicationDelegateAdaptor`
  `PushAppDelegate`. It does four things:
  - Calls `registerForRemoteNotifications` after the operator enables
    notifications (on the notification settings screen; `UNAuthorizationOptions
    [.alert, .badge, .sound, .timeSensitive]`).
  - On a token, sends `RegisterPush` over the W11 `WebSocketClient` whenever
    connected.
  - In `didReceiveRemoteNotification` (background push), removes delivered
    notifications whose `userInfo["item"]` is in `withdraw`.
  - In the `UNUserNotificationCenterDelegate` tap handler, routes to the item.
- `iOS/Nostromo/Views/PushItemView.swift` (new): the tap target. It resolves
  `item_ref` via `PushWaiting` over the VPN and shows the Mother job, decision
  sheet or Perri PR. When unreachable, it shows kind, host and ref from
  `userInfo` plus "Your machines are unreachable" (W11's `.unreachable`
  state). It is never empty.
- `iOS/Nostromo/Views/NotificationSettingsView.swift` (new). Contents:
  - per-kind toggles;
  - quiet hours start/end with an off switch;
  - evening summary time with an off switch;
  - host classes shown read-only;
  - a link to iOS Settings when authorization is denied;
  - the "Show Previews: When Unlocked" recommendation (one sentence, shown
    when enrichment is on for a work host; the enrichment toggles themselves
    arrive in W16);
  - the "Sent notifications" entry.
- `iOS/Nostromo/Views/SentNotificationsView.swift` (new): lists
  `PushSentLog`.
- A banner in the root view: when `PushStatus.failing_since` is older than
  15 min, show `Notifications haven't been delivered since <h:mm a>`.
- On every foreground connect: request `PushWaiting`, remove delivered
  notifications whose item is not in it, set
  `UNUserNotificationCenter.setBadgeCount(badge)`, and do this before the
  first screen accepts input (gate the root view's hit-testing on the first
  reconcile or a 2 s timeout).
- `Shared/NostromoKit/Sources/NostromoKit/Wire/`: Codable types for the new
  messages. `Shared/NostromoKit/Sources/NostromoKit/Push/PushPayload.swift`
  (new) parses `userInfo` into `{item, kind, host, ref}` and is shared with
  W16's extension.
- `iOS/Nostromo/Nostromo.entitlements` (new; referenced from
  `iOS/Nostromo.xcodeproj/project.pbxproj` target `Nostromo`, `:155-176`):
  `aps-environment` and
  `com.apple.developer.usernotifications.time-sensitive`.
  `iOS/Nostromo/Info.plist`: `UIBackgroundModes = [remote-notification]`.

Tests:

- `tests/push_vocab.rs` (new). For every kind × host class × Mother reason ×
  timeout/no-timeout × size bucket:
  - Feed inputs whose free-text fields (question, title, plan_path, branch,
    repo for work hosts, prompt, detail, choice labels and details, session
    name, PR title, author, owner, labels) each contain a unique marker.
  - Serialise the **entire relay request body**. Assert that no marker
    appears anywhere in it.
  - Assert `vocab::conforms` accepts title and body. Assert `conforms`
    *rejects* each marker when injected, which proves it is an allow-list.
  - Assert the exact title/body strings from the PRD examples.
  - Assert an unclassified host renders like a work host.
  - Assert a quota pause produces no item.
- `tests/push_schedule.rs` (new; pure, injected clock):
  - Grace send at 120 s, never before.
  - Resolved at 119 s → no send and a `skipped_resolved_in_grace` log line.
  - A decision is sent at t+0.
  - 4 grace items due within 120 s → exactly one Summary and no individual
    sends.
  - 3 grace items → 3 sends.
  - A decision during a burst → sent individually.
  - Quiet hours across midnight in `America/Chicago`, including a DST
    transition day: nothing during; one Summary at the end iff something is
    still waiting; none if all resolved overnight.
  - Evening summary at 17:30 iff waiting; skipped when inside quiet hours.
  - A disabled kind is absent from sends, summaries and the badge.
  - An item is never sent twice.
  - A re-entered Mother job is a new item.
  - A decision deadline passing → withdrawal and expiry.
- `tests/push_engine.rs` (new; in-process `Server`, `wiremock` relay). Cover:
  - Satellite-tagged `MotherJobs` with an awaiting job → one relay POST at
    grace end with `thread_id` = host.
  - The job leaving `awaiting` after send → withdrawal POSTs (badge-only +
    background) with the decremented badge.
  - Relay 500 or timeout → a `relay_unreachable` log line, no retry, and
    `failing_since` set.
  - A revoked device → no POST.
  - Each `PushSentLog` request returns only the requesting device's entries,
    and none older than 7 days.
  - `PushAvailability` flips with quiet hours and the decision toggle.
- Additions to `src/data/perri_queue_native.rs`'s existing tests:
  `changed_lines` populated from the mocked `/pulls/{n}` body
  (`mount_pr_mocks`, `:2573-2657`, gains `additions`/`deletions`); the
  request-count assertions are unchanged.
- Additions to `src/ipc/decisions.rs` tests: `deadline`/`agent`/
  `local_operator` on the broadcast; `has_operator_for` with
  `push_available`, sensitive vs not.
- `Shared/NostromoKit/Tests/NostromoKitTests/PushPayloadTests.swift` (new):
  payload parsing; tolerates unknown keys.

## Approach

1. **Wire and data first.** Add the new fields (`DecisionRequest`,
   `DecisionResolved`/`PerriState` host, `DecisionAnswer.host`, `MotherJob`,
   `changed_lines`) with defaults. Run `cargo test` and `cd
   Shared/NostromoKit && swift test` before any behaviour change.
2. **`vocab.rs` and its tests (TDD).** This is the privacy boundary. Write the
   marker/allow-list tests first, then the renderers.
3. **`schedule.rs` as a pure state machine** with an injected clock: grace,
   lookahead coalescing, quiet hours, summaries, per-kind switches, the
   one-per-lifetime rule.
4. **`items.rs` derivation** from snapshots and events, plus the 30 s
   retained-cache reconcile.
5. **Devices, prefs and the publisher.** Add the `ClientMsg`/`ServerMsg`
   handlers, the sent log, and the `PushAvailability` broadcast and its
   satellite-side use in the `ask_decision` gate.
6. **Relay crate:** handler, SAM template and README. Unit tests against the
   APNs stub. Deploying is an operator step listed in the README. **Do not
   deploy from the job.**
7. **iOS:** registration, settings, sent log, banner, tap routing,
   reconcile-on-open, entitlements.
8. **CLI:** `nostromo push host` and `nostromo push status`.
9. Run the full suite: `cargo test`, `cargo clippy --all-targets`, `cargo
   test --manifest-path infra/push-relay/Cargo.toml`, `swift test`.

## Acceptance criteria

Payload contract (tests):

- `tests/push_vocab.rs` passes. For a work-host Mother job with marker strings
  in question, title, plan, branch and repo, the full relay request body
  contains none of them, and title/body are exactly `Mother · <host>` /
  `Job <8-hex> <reason phrase>`. A personal host gives
  `Mother · <host> · <repo>`. An unclassified host is identical to work.
- Each Mother reason maps to its phrase. An unknown reason gives *needs you*.
  A `quota_*` pause produces no item.
- A decision with markers in prompt, detail, choice labels and details, and
  session name produces a body naming the agent from the fixed set (or *A
  session*), the choice count, and the minutes left rounded down (*under 1
  min* below 60 s). There is no timeout phrase when `deadline` is `None`.
- A review renders `PR #<n> · <size> · <k> waiting`, with 49 → small,
  50 → medium, 400 → medium, 401 → large, and the size omitted when
  `changed_lines` is `None`. The repo appears only for a personal host whose
  owner is not in `work_owners`.
- A Summary never contains a repository name.
- `vocab::conforms` accepts every rendered string and rejects any string
  containing a token outside the vocabulary. The test asserts rejection, not
  just acceptance.
- No `ClientMsg` can change host classification. A test sends every push
  `ClientMsg` from a network peer and asserts `[push.hosts]` is unchanged.

Lifecycle and frequency (tests with paused time and a wiremock relay):

- A Mother or review item is POSTed to the relay between 120 s and 122 s
  after its start. An item resolved before 120 s is never POSTed and logs
  `skipped_resolved_in_grace`.
- A decision is POSTed within 1 s of its `DecisionRequest` when
  `local_operator == false` and no app is connected to the primary.
- Every POST carries `thread_id` = host label, the correct
  `interruption_level` (decision `time-sensitive`, others `active`), and
  `expiration_unix` = the decision deadline or send time + 4 h.
- When an item leaves the waiting set, the device receives a withdrawal
  within 2 s of the primary seeing the change: a badge-only push with the
  new count, plus a background push listing the `item_ref`.
- Every alert push's `badge` equals the device's waiting-item count across
  all hosts, excluding disabled kinds.
- 4 grace items due within 120 s → exactly one Summary POST and zero
  individual POSTs. A decision in the same window is still POSTed
  individually.
- Quiet hours: zero alert POSTs between start and end. At the end, exactly
  one Summary iff ≥ 1 enabled item is waiting. The evening summary fires at
  the configured time under the same rule. Withdrawals and badge-only pushes
  are still sent during quiet hours (PRD C4).
- No item is ever POSTed twice as an individual notification. There are no
  24 h or daily reminders.
- A kind turned off on a device → no POSTs of that kind to that device, and
  it is not counted in that device's summaries or badge.
- A device revoked through W9's device registry (whichever CLI W9 ships for
  revocation) receives no POST issued after
  the revocation (checked on the next send, well within 1 min).
- Relay unreachable → no retry, no queue, a `relay_unreachable` log line, and
  `PushStatus.failing_since` set. The next success clears it.
- `ask_decision` on a non-sensitive tag with no connected client and a
  push-available device blocks until answer or timeout instead of returning
  `no_operator`. With no push-available device, behaviour is unchanged.

Relay (relay crate tests):

- Requests without the daemon bearer → 401. Unknown fields or over-long
  strings → 400.
- A stored delivery record has exactly `{push_id, ts, kind, outcome,
  expires_at}`. `GET /records` never returns a record with `ts` older than
  7 days, even when one is still in the table.
- Handler logs contain no title, body, host, ref or repo. A test captures
  log output for a request whose title/body contain markers and asserts none
  appear.
- `template.yaml` sets the log group retention to 7 days and DynamoDB TTL on
  `expires_at`.

Sent log and visibility:

- `PushSentLog` returns, for the requesting device only, every attempt in the
  last 7 days, with time, kind, host, exact title/body and one of the seven
  outcomes. A 7-day-old entry is gone after the next prune.

iOS:

- `swift test` passes, including the payload parser.
- `[device]` (operator-verified on a physical iPhone after the relay is
  deployed; not a Cody gate):
  - `mother await` on Kobe → a `Mother · kobe` notification ~2 min later,
    stacked separately from a `tokyo` one.
  - Tapping it with the VPN off shows kind, host and ref plus the
    unreachable message.
  - Answering at the Mac → the badge drops within 2 min.
  - Opening the app removes stale notifications before the first screen
    accepts input.
  - Decision notifications break through a Focus that allows Nostromo's
    time-sensitive notifications.
- `infra/push-relay/README.md` lets the operator deploy from zero and
  contains the privacy note verbatim.
- PR body references the sequencing memo (W13) and `docs/prds/push-relay.md`,
  including its design-loop notes.

## Out of scope

- The Notification Service Extension, on-phone enrichment, lock-screen
  decision actions, and NSE-based withdrawal. These are **W16**. This wedge
  sets `capabilities.nse_withdraw = false` everywhere.
- Any worker-, agent- or third-party-authored text in a relay request, for
  any kind or host, including as a setting.
- Answering a Mother question or approving a PR from the lock screen.
- Other notification kinds (job succeeded or failed, calendar, posture,
  mail).
- Re-notifying unanswered items, or mirroring Mother's 24 h and daily Mac
  reminders. Mother's Mac notifications are not changed.
- Overriding quiet hours for decisions.
- Live Activities and widgets, Android, and non-Apple push.
- Carefeed-owned infrastructure. Deploying the relay from the job: deployment
  is the operator's README step.
- Making the Perri queue search personal orgs (PRD S5).
- Durable (on-disk) hold queue across daemon restarts. After a restart, items
  already waiting are re-derived from snapshots and treated as already
  notified. They are counted in the badge and summaries but not re-pushed.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "Daemon engine, stateless Lambda and iOS across one privacy boundary; schedule semantics (lookahead coalescing, quiet hours, tz) are subtle."
  redd:
    model: sonnet
    effort: xhigh
    rationale: "Allow-list marker tests over the full outbound body and paused-clock schedule tests are the contract; they must be exhaustive per kind and class."
  marty:
    model: sonnet
    effort: medium
    rationale: "Item derivation and rendering will start tangled with the engine loop; pull them into pure modules."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First data to leave the operator's machines; review payload, logging and retention adversarially."
```
