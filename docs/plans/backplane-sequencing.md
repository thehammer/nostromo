# Backplane Sequencing — universal access to Nostromo state from every device

**Author:** Archie. Drafted 2026-10-10 from an operator brief; revised
2026-10-10 after Ada's pairing PRD answered Q1; refreshed 2026-10-18 against
`origin/main` `d61c62d`; **refreshed 2026-11-23 against `origin/main`
`8f0328b9`** (237 commits later; see "Readiness" and "What changed since
2026-10-18" below; both win over any older text in this file).
**Status:** Draft. W14 and W9 can be dispatched now (the approvals and crew
chains they waited for are merged). W10 follows W9. W11 and W15 wait on Ada's
sign-off of D1–D7 (pairing PRD; D7 is new). W13 and W16 wait on Ada's sign-off
of S1–S8 (push PRD).
**Inputs:** `docs/plans/platform-evolution-sequencing.md` (bets B1–B6),
`docs/visions/iphone.md`, `docs/visions/ipad.md`,
`docs/prds/daemon-pairing-flow.md` (Ada, answers Q1), `docs/prds/push-relay.md`
(Ada, answers Q2). Local, untracked context the refresh read (on the operator's
machine only): `.claude/plans/permission-approval-prompts*.md`,
`.claude/plans/mother-crew-client*.md`, `.claude/plans/terminal-pane-*.md`,
`.claude/plans/remove-rust-tui*.md`, `.claude/plans/offload-tests-index.md`.
The 2026-11-23 refresh also read the operator's local tracker
(`.claude/wip/nostromo-work/index.md`) and `git log c9c9b1f4..8f0328b9`; nothing
from either is needed to execute a wedge.

## Readiness (2026-11-23, `origin/main` `8f0328b9`)

**Plain answer: yes, the plans needed updates, and they are made in this PR.**
None of the 237 merged commits changes the architecture (B7–B10 hold), but the
wire grew from 41 to 98 client verbs, a new handshake capability gates queue
merging, `.mother/crew.yml` now exists, and every dispatch blocker the memo
named has merged. Two new rules come out of it: **B11** (only connections that
can send user messages count against the merge gate) and a product decision on
the **queue view for phones** (Ada D7, recommendation: local-only in v1).

**Can start now**

| Wedge | Ready? | Why |
|---|---|---|
| W14 linux-primary | **Yes** | Independent packaging. Gated in observe mode (crew.yml is on main). |
| W9 ws-transport | **Yes**, after this docs PR merges | AP2a (#278/#287), AP3 (#310), MC4 (#299) and CL1/CL2 (#311/#314) are all merged, so the 2026-10-18 exclusion is moot. Only rule left: no other job editing `src/ipc/{protocol,server,peer}.rs` or `src/ipc/session_manager/` at the same time. Run `mother list` before adding W9: the tracker still shows job 0848d0c0 (tracker title+fold, daemon + Mac; its PR #473 merged) and chore job b7caf0f1 as queued or in progress, and those rows look stale. W9 now also carries B11 (a few lines in `src/ipc/session_manager/mod.rs`). |
| W10 satellite-uplink | After W9 merges | Same wire files as W9. |
| W11 ios-ws-client | Blocked | W9 + W10 merged, **Ada D1–D7**, and (recommended) the iOS test target prerequisite below. |
| W15 mac-device-admin | Blocked | W10 merged, **Ada D1–D7**; not beside another job that edits `macOS/Nostromo.xcodeproj` (PR #518 does today). |
| W12 seq-resume | Blocked | W10 + W11 merged. |
| W13 push-relay | Blocked | W12 merged, **Ada S1–S8**, operator's AWS account ready for the relay. |
| W16 ios-push-enrichment | Blocked | W13 merged. Request **Apple's notification-filtering entitlement** now (W16 ships without it, but withdrawal then stays best effort, S1). |

**Prerequisites outside the plan, in the order to do them** (costs use the
calibration in "Estimate"; none of them is a Mother job you must run before
W14):

1. **Merge this docs PR.** No cost. Every wedge cites it.
2. **Crew config follow-up** (`.mother/crew.yml`, config only). PR #519 (open;
   approved in review, merge pending) raises the `python-test` (900 → 1800 s)
   and `swift-ci` (1800 → 2400 s) timeouts and `gates.budget_minutes` from 45
   to **75**. Keep 75: Mother runs the checks serially, and the measured serial
   sum for a Rust + Python + Swift wedge is ≈ 5 + 20 + 24 ≈ 49 min (sources in
   "Estimate"), so 75 is ≈ 1.5×; at 45 such a wedge's gates end `incomplete`
   (observe mode: data lost, nothing held). Also narrow `python-test`'s `when`
   (crew delta 7): `tests/**` (`.mother/crew.yml:30`) matches every Rust test
   file, so Rust-only wedges pay the ~20 min Python run for nothing. Cost: an
   operator edit, or a $5 cap job (≈ $2). **Do before W9 is added**; W14 does
   not need it.
3. **Ada sign-offs** D1–D7 (pairing) and S1–S8 (push): one Ada session over
   both PRDs' design-loop notes. Blocks W11/W15 and W13/W16 respectively;
   needed by the time W10 merges to keep the Swift wedges from idling. Cost: an
   interactive Ada session (≈ $3–8), plus your reading time. Exact asks in
   "Open questions for the operator", item 1.
4. **Apple notification-filtering entitlement**
   (`com.apple.developer.usernotifications.filtering`) for the iOS app. Operator, on
   the Apple Developer site, now: lead time is Apple's. Blocks only the
   filtering half of W16 (S1); W16 ships without it.
5. **cargo-nextest in GitHub CI** (optional; not before W9). The GitHub Rust
   tests job measures 14.5–17 min green, 20 min slow, with the test binaries
   running one after another for 12–14 min (`.github/workflows/ci.yml:143-150`;
   step limit 35, job 45 since #517). nextest would run binaries in parallel
   (roughly 5–8 min). **Its benefit is GitHub-CI-only and small for this
   plan:** the `rust-test` gate in the RWX sandbox already takes ≈ 3.3 min, and
   every `src/` change also runs the Mac shards (`docs/ci.md`, "Path gate"),
   whose slowest shard (20–25 min, `docs/ci.md:434`) sets a backplane PR's CI
   wall time, not the Rust job. So it does not shorten a backplane hop until
   the Mac shards get faster than the Rust job. Caveats if done: nextest skips
   doctests (keep `cargo test --doc`), and each test runs in its own process.
   Cap $15, expected ≈ $6, ≈ 56 min plus gates.
6. **iOS test target and simulator test job** (recommended before W11; it
   reverses the committed policy in `docs/ios-verification.md:131`,
   `:688-717`). See "CI prerequisites" below. Cap $20, expected ≈ $8, ≈ 106 min
   with gates; can run beside
   W9/W10 (it edits `iOS/Nostromo.xcodeproj` and `.github/workflows/ci.yml`,
   which neither touches).

**Decisions only the operator can make** (details and recommendations in
"Open questions for the operator"): the queue view for phones (D7, recommend
local-only in v1); the gate budget (recommend #519's 75 and the `python-test` path filter); whether to
add the iOS test target first (recommend yes, but it reverses a committed
policy in `docs/ios-verification.md`; see "CI prerequisites"); nextest
(optional, little effect on this plan);
whether to split W13 (recommend no unless the iOS project is contended).

## What changed since 2026-10-18 (refresh of 2026-11-23)

Read against `origin/main` `8f0328b9`. Line numbers below are from that commit.

1. **The wire grew from 41 to 98 client verbs and from 50 to 92 server
   frames, and every one is already classified.** `CLIENT_MSG_VARIANTS = 98`
   (`src/ipc/peer.rs:2491`, asserted `:2639-2640`); the ordinal table is
   `:2494-2595`. The network allow-list is **unchanged at 13 verbs**
   (`network_policy`, `peer.rs:1054-1068`, pinned by `NETWORK_ALLOWED`
   `:2461` and the exactness test `:2644`): all 57 new verbs are `Refused`
   (`:1070-1181`). Of the 42 new server frames, 39 are `ServerClass::LocalOnly`
   and three are `Focus(tag)`: `SessionTurnOrigin`, `SessionBridge` and
   `TrackerSummary` (`classify_server_msg`, `peer.rs:717-888`). The new verbs
   and frames, by family, with what the backplane does about each, are in
   "Wire inventory" below. So the backplane's next free ordinal is **98**, and
   W9's nine verbs make it 107 (W13 → 111, W16 → 112), re-derived on each
   wedge's base.
2. **`.mother/crew.yml` exists** (MC5 #290, then #292): version 1, observe
   mode, `max_attempts: 2`, `budget_minutes: 45`, checks `rust-fmt`,
   `rust-clippy`, `rust-test` (sandbox), `python-test`, `swift-ci`,
   `shellcheck`, `actionlint`, `mother-contract` (host), lens default all four.
   The memo's crew deltas 3 and 4 are applied; 2 is withdrawn (`python-test`
   on the host is correct); 5 is still open. See "Crew config deltas" below.
   PR #519 (open) changes two timeouts.
3. **There is still no `nostromo` CLI binary.** `Cargo.toml:13-39` has seven
   bins (`nostromd`, `nostromo-mcp-bridge`, `nostromo-activity-hook`,
   `nostromo-google-auth`, `nostromo-huey-eval`, `nostromo-guard`,
   `sensitive-text-scan`). W9 still adds `src/bin/nostromo_cli.rs`. **The
   install path changed:** `make install-daemon` (`Makefile:136-193`) builds
   with `make daemon` (`:129-130`, `--bin nostromd --bin nostromo-guard --bin
   nostromo-mcp-bridge`), copies from `$(NOSTROMO_TARGET_DIR)/release` (`:14`,
   honours `CARGO_TARGET_DIR`, #500), stages and ad-hoc signs **three**
   binaries to new inodes, moves bridge, then guard, then `nostromd`, and runs
   the restart guard `bin/nostromo-restart-guard` first (`:123-126`, refuses
   while remote shells are open; `FORCE=1` overrides). W9 and W14 now say how
   the CLI fits that recipe.
4. **New handshake capability and merge gate** (#514, message queue S3).
   `Hello.capabilities` (`src/ipc/protocol.rs:1648-1651`) carries
   `merged_turns_v1` (`FEATURE_MERGED_TURNS`, `protocol.rs:1228-1232`); the
   daemon advertises it in `Welcome.features` (`src/ipc/server.rs:581`) and
   records per connection whether the Hello declared it (`server.rs:643-666`,
   `:831`). The session manager merges queued typed messages into one turn
   only while **every attached connection** declared it:
   `refresh_merge_gate` (`src/ipc/session_manager/mod.rs:3846-3855`) counts
   every attached connection not in `merge_capable` (`:724-726`) as legacy,
   including network peers (`network_clients`, `:720-723`, filled by
   `attach_network` `:2059-2060`). The Rust `DaemonClient` declares nothing
   (`src/ipc/client.rs:196-201`). The iOS app, through NostromoKit, **already
   declares it** (`ClientHello` default, `Shared/NostromoKit/Sources/
   NostromoKit/Wire/ClientMsg.swift:20`, sent at `Transport/NetworkClient.
   swift:232`) and renders `user_parts` (`iOS/Nostromo/Views/TranscriptView.
   swift:224-243`), but iOS builds older than #514 do not. A W10 routed attach
   would join a satellite's sessions as an undeclared network connection and
   close the gate for as long as a phone watches. New bet **B11** fixes the
   rule; W9, W10 and W11 carry it.
5. **The message queue is local-only** (S1 #506, S2 #513, S3 #514;
   `docs/message-queue.md`). `session_queue_watch`, `session_queue_take_back`,
   `session_queue_remove` are `Refused` for network peers (`peer.rs:1103-1105`),
   and `SessionQueue`, `SessionQueueResult`, `SessionQueueReturned` are
   `LocalOnly` (`peer.rs:798-800`). Take-back and remove need the verified Mac
   app with its `operator_nonce`. Stop (`session_interrupt`) empties the queue
   and returns the typed texts only to the operator connection that pressed it
   and watches the tag ("Stop", `docs/message-queue.md`). So a phone sees no
   chips and cannot take back. Recorded as product question **D7** (pairing
   PRD) with a recommendation: keep it local-only in v1.
6. **New content-bearing topics** (tracker T0b–T6 with staged commands; the
   authored-PR daemon with Perri's verdict and the guarded Merge verb, #461,
   #486, #493, #495, #508; composer history #509/#511; conversation history
   #464–#475; `/mcp` panel #515; slash commands #458; Huey H1–H8; Fred's
   Google sources; terminals 1a–3e and remote shells; approvals AP4–AP7; Claude
   sign-in CL1/CL2; Mother notices MF1–MF6). Each is classified in the
   per-topic publish table below. Short version: every one of them is
   `LocalOnly` or `Sensitive` on main and therefore **never leaves its host on
   any uplink**, except `TrackerSummary` (counts), `SessionBridge` (a boolean)
   and `SessionTurnOrigin` (transcript family).
7. **CI.** The GitHub Rust tests job takes 14.5–20 min, but the slowest Mac
   shard (20–25 min, `docs/ci.md:434`) runs on every `src/` change and sets
   the wall time; the sandbox `rust-test` gate is ≈ 3.3 min. So nextest
   (prerequisite 5) is optional for this plan. Linux
   runners are pinned to `ubuntu-24.04` (#474) and the Rust jobs are split
   into `rust-fmt`, `rust-clippy`, `rust-test` behind the aggregate
   `Build & Lint` check (`ci.yml:94-192`). Mac tests run in three shards
   (`ci.yml:298-465`, step 35 / job 45 min). **The iOS app has no test
   target**: `iOS/Nostromo.xcodeproj` has one target (an application,
   `project.pbxproj:174`), and CI only builds it for `generic/platform=iOS
   Simulator` (`ci.yml:510-545`). See "CI prerequisites".
8. **Dispatch blockers merged.** AP2a/AP2b/AP2c/AP3–AP7, MC3–MC6, CL1/CL2,
   terminal panes 1a–3e, tracker T0b–T6/T1w, BA0–BA6d, FV4 and message queue
   S1–S5 are merged. The "Dispatch order" table is rewritten to today.
9. **Mother.** The lens wave (Mother #75) merged, so lenses run automatically
   in parallel with adherence on the gated commit; `mother review-lens` is no
   longer needed by hand. Mother's crew blob carries `phi_sensitive`
   (`plugins/mother/lib/crew_config.py:254-259`), but the daemon still keeps
   only `crew_opt_in` (`src/mother/mod.rs:262-270`), so the PHI override stays
   a repo-name match. `client.surfaces` is still not built.
10. **Smaller drifts fixed in the wedges:** `PeerTrust`/`Transport` are at
    `peer.rs:36-55`; `handle_client` is `server.rs:617`, `handle_client_msg`
    `:1430`, `bind_tcp` `:280`, `welcome_msg` `:568-600`, `retain_broadcasts`
    `:4483`; the TCP listener and mDNS are bound in `src/bin/nostromd.rs:353-398`;
    `PROTOCOL_VERSION` is still 4 (`protocol.rs:34`); `Topic` gained `Terminal`
    and `AuthoredPrs` (`protocol.rs:73-89`); the Mother poller is
    `run_mother_pollers` (`nostromd.rs:864`, 2 s interval `:931`; `:402` is
    the crash-recovery supervisor's);
    `src/mother/mod.rs` `list_jobs` `:431`, `run_mother` `:606`; the
    macOS-only verifier arms are `src/ipc/peer_verify.rs:344-386`, `:657-677`,
    `:730-740`; `sha2` is already a direct dependency (`Cargo.toml:92`, the ECS
    pin). The calibration is redone with recent job costs ("Estimate").

## Mother features adopted (2026-10-18, Mother `origin/main` `e597389`)

*2026-11-23 updates (Mother `origin/main` `0a38549`):* the lens wave (#75) is
merged; Mother's code runs the gates of one job serially (`plugins/mother/lib/gates.sh:246-249`, Mother's git; not stated in Nostromo's docs); the checklist parser accepts `- **ID-n** text`
with or without `[ ]` (`plugins/mother/lib/criteria.sh`); `.mother/crew.yml`
exists on Nostromo's main. Statements below that say otherwise are history.

Mother's headless-crew work landed after the first draft. Read from Mother's
git only (`docs/design.md` "Headless crew contract (Phase 1)", `lib/gates.sh`,
`lib/crew_config.py`, `CHANGELOG.md`). Each wedge file ends its acceptance
section with "Mother crew: gates, lenses, checklist and calibration".

**Gates (`.mother/crew.yml`, HC-05/06/08).** The file is read from the job's
*base ref* at `mother add` and snapshotted into the job, so a wedge cannot add
or loosen its own gate. Nostromo has none on `origin/main` today. MC5
(`.claude/plans/mother-crew-client-mc5-nostromo-crew-optin.md`) already plans
it, in observe mode, so there is no separate W0; the deltas the backplane needs
are listed below. Gate names used by the wedges are MC5's: `rust-clippy`,
`rust-test`, `python-test`, `swift-ci`.
- *Can a gate run RWX or `make ci-remote` commands? Yes, by reading the code;
  not yet run.* `where: sandbox` makes Mother itself run `rwx sandbox reset`,
  `rwx sandbox exec -- bash -c '<run>'`, `rwx sandbox stop` (the `run` string
  must not contain `rwx sandbox exec`). It needs `.rwx/sandbox.yml` at the ref
  (present) and HEAD pushed; any failure to run is `unavailable`, never
  `passed`. `where: any` runs `bash -c` in the job worktree on the host, so
  `make ci-remote ONLY=swift` works there if `gh` is authenticated for the
  runner (with the `workflow` scope) and HEAD is pushed.
- *The toolchain guard does not apply to gates.* It is a PreToolUse hook on the
  worker's Bash tool (`~/.claude/hooks/_carefeed_agent-local-toolchain-guard.sh`,
  keyed on `MOTHER_JOB_ID`); Mother's supervisor exports `MOTHER_JOB_ID` but
  runs gates itself, outside any hook. Workers may also call `mother gates run`
  (it is not a guarded command), but with an unpushed HEAD `make ci-remote`
  refuses ("push first").
- *Mode is observe first:* red gates are recorded, never held. Under `enforce`,
  the PR stays a draft, the same worker session fixes failures (up to 3
  attempts), then the job holds (`gate_hold`) with options. Pipeline jobs are
  observe-only regardless.
- *The whole gate run has one budget* (`gates.budget_minutes`, default 15;
  overrun is `incomplete`, never passed), separate from each check's
  `timeout_s` (max 3600).

**Reviewer lenses (HC-12/13).** `correctness`, `phi-security`, `tests`,
`ops-infra`; a plan adds or removes them in its yaml block
(`lenses: {add, remove}`), validated at `mother add`; a mandatory lens cannot
be removed. The patch each lens reads is capped at 120 KB. **Not yet
automatic:** the parallel adherence-plus-lenses wave on the gated commit is
Mother PR #75 and is still open; today only `mother review-lens <id> --lens X`
and `mother merge-findings` exist. Per wedge: W9, W10, W13 (security and wire)
enable `correctness`, `tests`, `phi-security`, and W13 adds `ops-infra` for the
Lambda; each of them keeps a manual Perri pass (a lens is a diff-only read
whose `phi-security` checklist is written for care data, not for this repo's
trust tiers). W11, W12, W16 add `phi-security` (credentials, replay rings,
extension) with the normal `perri` entry. W14 (`ops-infra`) and W15
(`correctness`, `tests`) rely on lenses plus Mother's adherence review.

**Acceptance checklist and progress (HC-09/10/11).** `mother add` seeds a
checklist only from criteria written `- [ ] **ID-n** text` under a heading
starting "Acceptance criteria". The wedge files now use `W9-1`, `W10-1`, ...
so the progress figure, `mother check` and the Mother panel (MC2) have
something to count.

**Estimates and calibration (HC-09/11).** See "Estimate" below.

**Needs-you, ack and push (HC-03).** `attention_reasons` is
`[{reason, since, acked}]`; reasons are `progress_stalled`, `burn_ahead`,
`gates_incomplete`, `decision_awaiting`. `mother ack <job> <reason>` is
operator-only (refused when `MOTHER_JOB_ID` is set), stored outside job JSON,
and lapses when the condition's `since` changes. W13, W10 and W11 reuse MC4's
Kit `NeedsYouAggregator` rules instead of new heuristics (one item per
awaiting or held job; one per unacked reason except `decision_awaiting`).
Reconciliation, stated once for the sequence: **an ack at the Mac clears the
phone push** (the daemon's 2 s poll sees `acked: true`, W13's withdrawal path
removes the item); **a phone never acks, answers or resumes** (B10); a hold or
plain question has no ack, it is answered at the Mac; an ack is per host (no
mutating verb is routed), so a Kobe job is acked on Kobe. Details in W13
"Acknowledgement and withdrawal".

**Host tagging versus Mother's single-machine design.** Confirmed: *tag on the
message, not inside the job* still holds. Mother's design is single-user,
single-machine (`docs/design.md`), its job ids are unique only per machine, its
contract is additive-only and its fixtures are golden, so `host` stays on the
IPC envelope and `MotherJob` never gains it. Progress, gates, lens, decision
and attention keys pass through the daemon as decoded by `src/mother/crew.rs`
(per key, lenient, re-serialized from known fields). That is not byte-for-byte
passthrough: the daemon's `signals.cost` is a scalar while Mother's HC-09 `cost`
is an object, and keys such as `stage_share`, `eta.n` and `moved_back.from_pct`
are not modelled, so those degrade or drop until MC6 re-vendors recorded
fixtures. W10 now tests this shape and builds the `work` metadata form from
enums only (W10-16).

**Notifications.** Mother's own macOS push is suppressed while an `await`
client is connected only when `MOTHER_NOTIFY_SUPPRESS_WHEN_CLIENT=1` (opt-in
since #72; default off). W13 neither sets nor reads it. The `client.surfaces`
registration capability (so a surface such as notifications can be declared) is
a Mother follow-up that is not built; MC4 uses it on the Mac only when it
exists, and W13 registers no phone with Mother. The phone push and Mother's Mac
notification are different devices and can both fire.

### Crew config deltas (refreshed 2026-11-23: applied vs open)

`.mother/crew.yml` is on main (MC5 #290, `where: any` for Python in #292). Its
current content, by the 2026-10-18 delta numbers:

| # | Delta | State on `8f0328b9` |
|---|---|---|
| 1 | Merge crew.yml before any backplane wedge is added | **Applied.** Every wedge added from now on is gated (observe mode). |
| 2 | `python-test` `where: sandbox` | **Withdrawn; `where: any` is correct** (`.mother/crew.yml:27-32`). The suites need macOS tools (`codesign`/`lipo` in `tests/operator_pin`, the QA harness), which the Linux sandbox lacks. |
| 3 | `gates.budget_minutes: 45` | **Applied** (`:6`), but now too small: see 6 below. |
| 4 | Lens scopes for push, relay, transport, extension, `dist/**` | **Applied** (`:63-65`): `phi-security` lists `src/ipc/**`, `src/push/**`, `infra/**`, `template.yaml`, Kit `Wire/**`, `Transport/**`, `Push/**` and `iOS/NostromoNotificationService/**`; `ops-infra` lists `dist/**`, `infra/**`, `template.yaml` and both Xcode projects. The lens default is all four lenses (`:61`), so a wedge's `lenses.add` is now a no-op and only `remove` changes anything. |
| 5 | `relay-test` gate after W13 | **Open.** Add after W13 merges: `cargo test --manifest-path infra/push-relay/Cargo.toml`, `where: sandbox`, `when: { paths: ["infra/push-relay/**"] }`, `timeout_s: 900`. The standalone crate is not covered by the root `cargo test`. |
| 6 | Timeouts and the total gate budget | **In PR #519** (open; approved in review, merge pending): `python-test` 1800 s, `swift-ci` 2400 s, `budget_minutes` 75. Checks run serially per Mother's code (`gates.sh:246-249` in Mother's git). Measured per pass: Rust ≈ 5, `python-test` ≈ 20, `swift-ci` ≈ 24 min (#519's `docs/mother-crew.md`; #502), so a mixed wedge is ≈ 49 min and 75 is ≈ 1.5×. |
| 7 | `python-test` path filter | **Open.** `when` includes `tests/**` (`:30`), which matches every Rust test file, so a Rust-only wedge pays the Python run (~20 min per #502, as quoted in #519). Replace `tests/**` with the Python suite directories (the `PY_FAST_SUITES`/`PY_SLOW_SUITES` lists, `Makefile:71-72`, name them) plus `tests/**/*.py`. |
| 8 | `phi-security` scope for the new CLI | **Open, small.** Add `src/bin/nostromo_cli.rs` (W10's `nostromo uplink pair` writes the satellite token). |

Also new on main and used by the wedges: `rust-fmt` (non-blocking),
`shellcheck`, `actionlint` (non-blocking) and `mother-contract`
(non-blocking, `src/mother/**`). `max_attempts` is 2 (the plans' "up to three
fix attempts" now reads two). Promotion to `enforce` is blocked by
`python-test` flakiness (tracker row "gates-enforce"), so assume observe mode.

### Needs a Mother-side change (listed, not requested)

- ~~Run the lens wave automatically (PR #75)~~: **merged** (Mother
  `8fd283d`). Lenses run in parallel with adherence on the gated commit.
- A wire-safe `phi_sensitive` boolean on the job. The daemon keeps only
  `crew_opt_in` (the blob is opaque to clients), so W10's PHI override matches
  repo names only.
- The `client.surfaces` registration capability (see above), and a way for a
  phone push to count as a surface without Mother muting itself wrongly.
- A per-repo addendum for lens checklists: `phi-security` talks about care data,
  residents and tenants; this repo's risks are token handling, trust tiers and
  egress. Also no lens covers transcript/scroll safety (MC5 notes the same).
- An ack path for a plain `awaiting` question or hold (only the four typed
  reasons can be acked today), if a Mac-side "snooze" should clear a phone push.
- Confirm whether lens spend (`review_wave.budget_usd`, default $3 per lens,
  2 cycles) counts against a job's `--max-cost`; this memo assumes it is
  separate and adds roughly $2-6 of expected spend per security wedge.
- `progress.signals.cost` shape: the published fixtures are provisional and
  still show a scalar; the daemon decodes a scalar. Re-record (HC-16/MC6).

## What changed since 2026-10-10

*History (2026-10-18 refresh).* Where this section disagrees with "What
changed since 2026-10-18" above (for example `CLIENT_MSG_VARIANTS = 41`, the
`peer.rs` line numbers, `Makefile:69-110`, "MC3–MC6 planned"), the newer
section wins.

Thirty-odd PRs merged between the first draft and this refresh. These are the
ones that change the backplane, and what each wedge does about it.

1. **FND-1 is the network policy now, and it is stricter than the draft
   assumed** (`src/ipc/peer.rs`). `PeerTrust` is `OperatorApp | LocalOther |
   Tcp` (`:44-52`). `classify_server_msg` (`:628-721`) is exhaustive over
   `ServerMsg` with classes `Sensitive | Open | Focus(tag) | Job(id) |
   Activity(tag?) | LocalOnly` (`:568-590`). **`ServerClass::LocalOnly`
   already exists** (BA0 added it for task output; AP0b uses it for approval
   frames), so W9 no longer invents it; W9's device-admin frames get a *new*
   class (`Admin`), because `LocalOnly` must keep meaning "never to any network
   peer", and a satellite link is a network peer. `network_policy`
   (`:818-878`) is default-deny: 13 `ClientMsg` variants are `Allowed` for a
   network peer, everything else `Refused`. `CLIENT_MSG_VARIANTS = 41`
   (`:1547`) is a tripwire test: every new verb needs an ordinal arm and a
   bump. W9/W10/W13/W16 now list every new variant with its class, ordinal and
   policy (see "Wire inventory" below).
2. **Permission approvals (AP0a, AP0b, AP1, AP1b) are merged.** Approval and
   decision answers come **only from the verified local Mac app** (`PeerTrust::
   OperatorApp`, pinned by `~/.nostromo/operator-app.pin`, an `operator_nonce`,
   answer-time re-inspection, a fresh human gesture). The approval frames that
   carry content (`ApprovalRequest`, `ApprovalsSnapshot`, `ApprovalResolved`,
   `ApprovalGuardBlocked`, `ApprovalAnswerRefused`) are `LocalOnly`
   (`peer.rs:671-675`). The only approval frame a network peer may receive is
   `ApprovalPending { tag, count }` for a non-sensitive focus
   (`protocol.rs:1862`, `peer.rs:663`). `ApprovalAnswer`,
   `ApprovalRefusalReport` and `DecisionAnswer` are `Refused` for network
   peers. New bet **B10** below makes this a backplane invariant. Two planned
   push features contradicted it and are withdrawn (Ada sign-off **S7**):
   W16's lock-screen decision buttons, and W13's "a push-capable phone counts
   as an operator" (`ask_decision` gate, PRD clarification C3). Also: the
   verifier is macOS-only (`src/ipc/peer_verify.rs:314-356`, `cfg(not(target_os
   = "macos"))` arms), so **on Tokyo no peer can ever be `OperatorApp`**. The
   primary therefore answers nothing, and v1 does not host agent sessions on
   Tokyo (they would be denied every permission prompt; AP0a denies when no
   app answers).
3. **The Rust TUI and the daemon PTY host are gone** (R1 #265, R2 #267). The
   `Pty*` client messages are tombstones kept for ordinal stability; each is
   answered `pty_host_removed` (`protocol.rs:1114-1149`). There is no `nostromo`
   binary any more (`Cargo.toml:13-31`: `nostromd`, `nostromo-mcp-bridge`,
   `nostromo-activity-hook`, `nostromo-guard`, `sensitive-text-scan`). So:
   every `Pty*` routed action, `host` field on `PtyList`/`PtyInfo`, "binary
   frames reserved for PTY bytes" and "PTYs visible everywhere" is dropped from
   W9, W10, W12 and B8. Terminals are being rebuilt by the terminal-pane plans
   (daemon `TerminalManager`, slice 1a, not merged); every `terminal_*` frame
   is planned `LocalOnly`/`Refused` and iOS gets only a "Terminal: open on Mac"
   placeholder (slice 1e). **The backplane carries no terminal bytes**
   (open question 4). The `nostromo device|uplink|push` CLI moves to a new,
   small `nostromo` binary (`src/bin/nostromo_cli.rs`) that `make
   install-daemon` installs next to `nostromd`; it has no TUI and prints help
   with no subcommand.
4. **Mother crew client (MC1, MC2 merged; MC3–MC6 planned).** The Mac app is
   its *own* client of the local Mother broker (`macOS/Nostromo/Data/
   MotherBrokerClient.swift`) and ignores the daemon's `MotherJobs` frame. The
   daemon polls `mother list --format json` (`src/bin/nostromd.rs`, poller)
   and decodes per job and per key (`src/mother/decode.rs`, the tolerant
   decode, #268), with the vendored contract and golden IPC fixtures in
   `tests/fixtures/mother-contract/` (`ipc_mother_jobs.golden.json`,
   `MANIFEST.json`). Mother's contract has **no host field**, so the host
   stays on the IPC *envelope* (`ServerMsg::MotherJobs.host`), never inside
   `MotherJob`, and the golden fixtures must stay byte-identical when `host`
   is `None`. MC3 refuses `MotherResume` from any non-`OperatorApp` peer when
   the job has an open decision; MC-B5 keeps gate output and finding text off
   every wire. Mother's broker socket (`~/.mother/broker.sock`) is never
   exposed off-host; only the daemon's poller output is published.
5. **New content-bearing topics** (transcript tool folds TF1, focus view FV*,
   background tasks BA0, model switching M1, Teri T0–T5, Fred F0–F1, the
   tracker board engine T0a with its sensitive-text guard T0g in
   `src/sensitive_text.rs`). Bet **B9** below introduces a per-host *egress
   profile* so that a work host (Kobe) publishes metadata only, and anything
   from a PHI repo (`admin-portal`, `referral-monitor`, matched by repo name;
   Mother's `crew.phi_sensitive` is not visible to the daemon, see "Mother
   features adopted") publishes metadata only from any host. This
   withdraws the draft's `publish_sensitive = true` default for Kobe and
   makes work-host enrichment in W16 impossible (Ada sign-off **S8**).
6. **Ops.** `make install-daemon` now installs **two** signed binaries
   (`nostromd` and the production-shell guard `nostromo-guard`, staged and
   swapped in that order, `Makefile:69-110`), and restarting the daemon ends
   every daemon-hosted session. `make mac-install` signs, copies and re-pins
   the app (`Makefile:278-284`); the daemon reads the pin per connection, so
   no daemon restart. Installs on Tokyo and Sendai are separate manual steps
   on those machines. A daemon restart orphans a running Mother job on that
   host (`runner_died`, then tier escalation), so installs go between jobs.
   New section "Install coordination".
7. **CI and offload.** Agents may not run `cargo` or Swift builds locally (the
   toolchain guard hook). Rust and Python tests run in the RWX sandbox
   (`.rwx/sandbox.yml`, `rwx sandbox exec -- cargo test …`); Mac, Kit and iOS
   run on GitHub Actions (`.github/workflows/ci.yml`: `ubuntu-latest` build
   and lint `:33-63`, `swift-tests-mac` `:152`, `swift-tests-kit` `:208`),
   dispatched with `make ci-remote [ONLY=rust|python|swift|mac|kit|ios]`.
   Every wedge's acceptance criteria now say so, and every test is hermetic: no
   real network beyond loopback, no real WireGuard, no real APNs or AWS.
8. **Wire versioning.** `PROTOCOL_VERSION` is still 4 (`protocol.rs:26` then; `:34` on `8f0328b9`), the
   Mac and iOS clients hard-code 4, and other in-flight plans (CL1) also edit
   `protocol.rs`. The refresh drops every `PROTOCOL_VERSION` bump from the
   wedges. Capability is negotiated through `Welcome.features` only (rule in
   "Install coordination").
9. **Mother plan format and calibration.** Every wedge carries a
   `suggested_config` with a rationale for every actor, Sonnet throughout, a
   max cost, and the estimate below (wall ≈ 43 min + 2.6 min per actual
   dollar; ≈ 40 min per hop). Gates, lenses, the acceptance checklist and
   retro calibration are layered on top; see "Mother features adopted".
10. **Fixes to the draft itself.** The 5-line note added to
    `platform-evolution-sequencing.md` said the primary moves to the Mac Mini
    and linked a non-existent `websocket-backplane.md`; it now names Tokyo and
    this memo. W9's WebSocket listener now defaults to **loopback**
    (`127.0.0.1:47101`), like the TCP listener (`src/config.rs:46`), so
    installing W9 on Kobe never opens an inbound port; Tokyo opts in with
    `ws_addr` in its `config.toml`.

## Notation

- **W*N*** — **Wedge.** A shippable unit of work with its own plan in
  `docs/plans/backplane/W<N>-<slug>.md`, enqueued as one Mother job.
  Numbering continues from the platform memo (W1–W8 are taken).
- **Q*N*** — **Question for Ada.** Product question to answer before the
  dependent wedge is dispatched.
- **B*N*** — **Bet.** Architectural decision with cross-cutting consequences.
  B1–B6 are defined in the platform memo; B7–B11 are new here (B11 added
  2026-11-23).

## The brief, restated

The operator has five machines:

| Host | What it is | Role today | Role after this memo |
|---|---|---|---|
| **Kobe** | Carefeed-managed MacBook Pro | runs a `nostromd`, the Mac app, Mother, Bishop, Carefeed repos (incl. PHI repos) | **satellite**, work egress profile: keeps all of that, publishes metadata upstream, dials out only |
| **Sendai** | personal Mac Mini, always on | — | **satellite**, personal egress profile; Mother for personal repos |
| **Tokyo** | personal Linux workstation, always on | — | **primary** (B7): device registry, router, push engine; hosts no agent sessions |
| **iPhone / iPad** | mobile | LAN-only via Bonjour + raw TCP | paired WebSocket clients over WireGuard |

Two facts drive everything:

1. **Kobe is closed when the operator commutes.** No daemon runs. The home
   of shared state must move to an always-on host.
2. **Kobe's MDM broke iOS↔Mac first contact.** The old path is Bonjour
   discovery (`src/mdns.rs`) plus an inbound unauthenticated TCP connection;
   main has since made that listener loopback by default (`src/config.rs:46`,
   `DEFAULT_TCP_ADDR = 127.0.0.1:47100`). Every plausible MDM control is
   defeated the same way: Kobe only ever dials **out**, and nothing discovers
   Kobe.

Reachability already exists: a **WireGuard VPN on the operator's UDM Pro**.
Phone, iPad and Kobe join the home network over it and reach the primary at a
stable private address. No hosted hub. The one cloud component left is the
APNs push relay (W13), a one-shot HTTPS POST, in the operator's personal AWS
account.

## Bets

### B2 (platform memo) — RESOLVED: VPN-to-home over WireGuard
Not Tailscale, not a cloud backplane. The primary exposes a WebSocket endpoint
on the home network; the UDM Pro's WireGuard is the only off-site path.

### B7 — Primary host: Tokyo (Linux)
Unchanged by main, and strengthened: the primary needs no Mac app, no Mother,
no Bishop and (B10) no `OperatorApp`. The Rust workspace builds and tests on
`ubuntu-24.04` (`ci.yml:94-192`; was `ubuntu-latest`, `:33-63`, on 2026-10-18). W14 is packaging only. If W14 hits a blocker,
Sendai takes the role with `mode = primary`; no other wedge changes.

### B8 — Wire protocol: WebSocket carrying the existing JSON
Every network peer speaks `ClientMsg`/`ServerMsg` (`src/ipc/protocol.rs`) as
one JSON text frame per message over WebSocket (`ws://` inside the tunnel).
**Binary frames are not used; a binary frame closes the socket with 1003.**
(The draft reserved them for PTY bytes; the PTY host is gone.) The
length-prefixed codec (`src/ipc/codec.rs`) stays for the Unix socket and the
legacy TCP listener. Device tokens remain even inside WireGuard: a WireGuard
peer is a network identity, a device token is an application identity.

### B9 — Egress profiles: what leaves a host (new)
Every satellite has an `uplink.egress` profile, and the primary applies a
second filter per downstream peer:

- **`personal`** (Sendai): publish what FND-1 lets a network peer see today
  (`peer::outbound` with network trust), plus Teri/Fred/work frames only if
  `uplink.publish_sensitive = true` (default **false**).
- **`work`** (Kobe, and the default for any satellite whose config does not
  say `personal`): publish **metadata only**, through an exhaustive
  per-variant function `peer::redact_for_uplink_metadata` (W10). It sends
  counts, states, enums, opaque ids and numbers; never a title, question,
  prompt, plan path, branch, repository name, transcript, pane content,
  activity text, PR title, task output, mail, todo or ticket text. Focus tags
  are replaced by a per-host keyed pseudonym (`f-<8 hex>`), because a
  work-derived tag is a slug of its title.
- **PHI override.** On any host, a Mother job whose repository is
  `admin-portal` or `referral-monitor` (matched on the repo path's last
  component; the daemon keeps only `crew_opt_in`, so Mother's
  `crew.phi_sensitive` cannot be read today), and a
  focus whose project path is one of those repositories, is published through
  the metadata function even under `personal`. The list is a config value
  (`uplink.phi_repos`, default those two) that can only grow.

The topic table in "Wire inventory" gives the result per topic. Rationale:
Kobe holds Carefeed work and PHI repositories; nothing content-bearing should
reach Tokyo's disk, a phone's cache or a push. The cost is that a phone sees
Kobe's work as counts and states (which is what push needs) and cannot read a
Kobe transcript off-host (Q3, open question 5).

### B10 — Approvals and decisions are answered at the Mac, never over the backplane (new)
- No backplane path (WebSocket device, satellite uplink, primary router) may
  carry `ApprovalAnswer`, `ApprovalRefusalReport`, `DecisionAnswer`, or a
  `MotherResume`/`MotherAction` for a job with an open decision. They stay
  `NetworkPolicy::Refused` for every network trust, including the new
  `Paired` and `Satellite` tiers, and a satellite refuses them from its uplink
  even if a (compromised or buggy) primary routes one down.
- No content-bearing approval frame leaves its host: the five approval frames
  above stay `LocalOnly`, and `LocalOnly` is never published on an uplink.
- **What a paired device may see about approvals:** "needs you" counts only,
  from `ApprovalPending { tag, count }` for non-sensitive focuses (tag
  pseudonymised for a work host), and Mother `awaiting`/attention states as
  enums. No command, reason, working directory, choice label or prompt.
- **What a paired device may do about approvals:** nothing. It may be told
  to go to the Mac (W13 push, "Open" only). Tapping opens a read-only screen.
- **Interaction with the approvals roadmap:** AP2a/AP2b (Mac card) and AP3
  (sidebar pill, Dock badge, Mac notification with no approve action) are
  Mac-local and unaffected. AP5's approvals log stays local. If a later AP
  plan adds an iOS approval surface, it is a count/"needs you" view under this
  bet; answering from a phone needs a new bet (device-level operator trust,
  with its own PRD and Perri review) and is out of this memo. A future
  count-only push kind "Approval needed · <host>" is listed as a follow-up for
  Ada, not planned in W13.
- *2026-11-23:* the same rule covers the newer operator-only verbs: queue
  take-back/remove, `AuthoredPrMerge` and the PR hand-off verbs, `TrackerEdit`,
  `SessionMcp`, conversation resume, terminal and remote-shell verbs. All are
  `Refused` for every network trust today and stay so for `Paired`,
  `Satellite` and `Routed`.

### B11 — The merge gate counts only connections that can send user messages (new, 2026-11-23)

**Problem.** Since #514 the daemon merges a busy session's queued typed
messages into one turn only while every connection attached to that session
declared `merged_turns_v1` in `Hello.capabilities`
(`src/ipc/session_manager/mod.rs:3846-3855`; `docs/message-queue.md`, "Gate").
The gate exists because a client that **echoes what it sent** and does not
understand `Turn.user_parts` would draw a merged turn twice. Today every
attached connection counts, including network peers. On the backplane that
means: a W10 routed attach (the primary forwarding a phone's `SessionAttach`
to a satellite) joins the satellite's session as an undeclared network
connection, so merging silently stops on Sendai for as long as any phone
watches; and a W9 `Paired` device on a single-host setup does the same if its
build predates #514. (Precisely: every attached connection that did **not**
declare the capability counts; current iOS builds declare it, so they do not
close the gate today.)

**Rule.**
1. A connection counts against the merge gate only if it is attached to the
   session **and may send user messages to it**: today, a non-network peer
   (`PeerTrust::OperatorApp` or `LocalOther`). Network peers (`Tcp`, and the
   new `Paired`, `Satellite`, `Routed`) never count, whether or not they
   declared the capability, because `SessionSend` is `Refused` for them
   (`src/ipc/peer.rs:1076`) and they have nothing of their own to echo. A
   legacy renderer still shows a merged turn readably: `user_input` is the
   parts joined by a blank line.
2. The Rust `DaemonClient` (`src/ipc/client.rs:196-201`) and any local test
   client keep counting as legacy unless they declare it (unchanged; the CLI
   W9 adds never attaches to a session, so it never touches the gate).
3. **How each new peer declares capabilities.** The WebSocket handshake is the
   same `Hello` JSON as a text frame (B8), parsed by the same code
   (`src/ipc/server.rs:643-666`), so `capabilities` arrives on every
   transport. W9: a `Paired` device's declared capabilities are recorded like
   any connection's (harmless, since rule 1 ignores network peers for the
   gate). W10: the satellite uplink's `Hello { role: Satellite }` declares
   none (it attaches to nothing on the primary, which hosts no sessions);
   frames routed down to a satellite run under a synthetic connection key that
   W10 registers through `attach_network`, so rule 1 excludes it. W11: iOS
   keeps declaring `merged_turns_v1` (it already does, through
   `ClientHello`'s default, `Shared/NostromoKit/Sources/NostromoKit/Wire/
   ClientMsg.swift:20`) and keeps rendering `user_parts`
   (`iOS/Nostromo/Views/TranscriptView.swift:224-243`).
4. **If a later bet lets a device send messages** (device-level operator
   trust, out of this memo), that bet must make send-capable network peers
   count again unless they declared the capability.

**Where it lands.** W9 (the session-manager change and its tests, because W9
is the first wedge that adds network peers; it is a few lines: subtract
`network_clients` in `refresh_merge_gate` and recount on attach, detach and
drop as today). W10 asserts the routed key is a network client. W11 asserts
the WebSocket `Hello` carries the capability. It also fixes today's case of a
pre-#514 iOS build attached over the legacy TCP listener.

## Wire inventory (FND-1 classification of every new message)

*2026-11-23:* ordinals below are re-derived from `CLIENT_MSG_VARIANTS = 98`
(`src/ipc/peer.rs:2491`). The table of verbs and frames merged on main since
2026-10-18 follows this one.

Network trusts after W9/W10: `Tcp` (legacy, unchanged), `Paired { device_id,
sensitive }` (a device over WebSocket), `Satellite { host }` (a satellite's
uplink, seen on the primary). On a satellite, frames the primary routes down
run under `Routed`, which has exactly `Tcp`'s policy. `is_network()` is true
for all four.

| Message (direction) | Wedge | FND-1 class / policy | Notes |
|---|---|---|---|
| `PairCheck`, `Pair` (c→d) | W9 | `Refused` in `network_policy`; accepted only on a token-less pairing socket, enforced in `ws.rs` before dispatch | ordinals 98, 99 |
| `DeviceUnpairSelf` (c→d) | W9 | `Allowed` for `Paired` only; `Refused` for `Tcp`, `Satellite`, `Routed` | ordinal 100 |
| `DevicePairStart`, `DevicePairUpdate`, `DevicePairCancel`, `DeviceList`, `DeviceRevoke`, `DeviceSetScope` (c→d) | W9 | `Refused` for every network trust; on the primary, `Satellite` gets a W10 exception gated by the satellite's registry `admin` level | ordinals 101–106 |
| `PairOffer`, `Paired`, `PairRefused`, `Unauthorized`, `DeviceUnpaired` (d→c) | W9 | `Open`, **targeted only** (never broadcast; `Paired` carries the token) | a test asserts none enters the broadcast channel |
| `DevicePairing`, `DevicePairOutcome`, `Devices`, `DeviceRevoked`, `DeviceAdminError` (d→c) | W9 | new `ServerClass::Admin`: local peers yes; `Satellite` only per its `admin` level (W10); `Paired`, `Tcp` never | |
| `Hosts`, `HostUnavailable` (d→c) | W10 | `Open` | host names and timestamps only |
| `MotherJobs.host`, `MotherStatusline.host`, `MotherAwaitDetected.host`, `Activity.host`, `FocusListResp.host`, `SessionListResp.host`, `ApprovalPending.host`, `PerriState.host`, `DecisionRequest.host`, `DecisionResolved.host` (fields) | W10 | class unchanged | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| `Hello.role`, `Subscribe.resume` (fields) | W10, W12 | — | additive; `Hello` already has `client_kind` and `capabilities` (`protocol.rs:1638-1652`) |
| `Hello.capabilities` on WebSocket (existing field) | W9, W10, W11 | — | parsed by the shared handshake; B11: network peers never count against the merge gate; iOS declares `merged_turns_v1`, the uplink declares nothing |
| `Gap` (d→c) | W12 | `Open` | topic, host, seq bounds, reason enum |
| `RegisterPush`, `SetPushPrefs`, `PushSentLog`, `PushWaiting` (c→d) | W13 | `Allowed` for `Paired` only, self-scoped to the connection's own device id; `Refused` for `Tcp`, `Satellite`, `Routed` | ordinals 107–110 |
| `PushSentLog`, `PushWaiting`, `PushStatus` (d→c) | W13 | `Open`, targeted only | closed vocabulary text |
| `PushAvailability` | — | **dropped** (B10; S7) | |
| `PushDetail` (c→d) | W16 | `Allowed` for `Paired`, self-scoped; reply follows B9 and the device's `sensitive` scope | ordinal 111 |
| `PushDetail` (d→c) | W16 | `Open`, targeted only | text present only for `personal`-profile, non-PHI items |
| `DecisionAnswer.host`, `DecisionAnswerResult` | — | **dropped** (B10; S7) | |

Every new `ClientMsg` adds an arm to `network_policy`, `targets_sensitive_session`
and the ordinal table, and bumps `CLIENT_MSG_VARIANTS` (98 on `8f0328b9` → 107 after W9 → 111
after W13 → 112 after W16; if another plan lands a verb first, the next free
ordinal is used and the count re-derived on the wedge's base). It also adds the
variant to `every_client_msg()` and, for an allowed verb, to `NETWORK_ALLOWED`
(`peer.rs:2461`); a `Paired`-only verb stays out of that list (it is `Refused`
in `network_policy` and admitted by `paired_extra_allowed`).

### Verbs and frames merged on main since 2026-10-18 (all already classified)

Every row is `Refused` (verbs) or `LocalOnly` (frames) for every network
trust unless the row says otherwise. The backplane changes none of them: the
new trusts inherit `Tcp`'s refusals, and `LocalOnly` is never published on an
uplink (W10 drops it before the egress filter).

| Family (PRs) | Client verbs (ordinals) | Server frames | Backplane note |
|---|---|---|---|
| Claude sign-in (CL1 #311, CL2 #314) | `ClaudeLoginAction` (41) | `ClaudeLoginState` | Mac-local. |
| Background tasks (BA1 #315, BA4 #399) | `SessionTaskStop` (42), `SessionTaskOutput` (43) | `SessionTaskStopResult`, `SessionTaskOutputResult` | `SessionTasks` (metadata) stays `Focus`. |
| Terminal panes, follow, staging (1a–3e, S1a–S3b) | `Terminal*` (44–51, 55–60, 62–64, 66–68, 76) | `TerminalList`, `TerminalState`, `TerminalClosed`, `TerminalReplay`, `TerminalOutput`, `TerminalRemoteSummary`, `TerminalRefused`, `TerminalStagingList` | No terminal frame of any kind, not even metadata (open question 4 stands). |
| Remote shells (2a–2e) | `RemoteShellTargetsRequest` (52), `RemoteShellOpen` (53), `RemoteShellAnswer` (54) | `RemoteShellTargets`, `RemoteShellConfirmRequest`, `RemoteShellResolved` | Production targets: never off-host. |
| Huey document panes (H6) | `PaneAction` (61) | `PaneActionResult`; `PaneContent` with a `Document` body is `LocalOnly` (`peer.rs:731-734`) | Huey's tags are sensitive (`is_huey_tag`, `peer.rs:88`). |
| Mother notices (MF2a–MF6) | `MotherNoticeSettingsSet` (65) | `MotherNoticeState` | Mac-local. |
| Approvals rules and log (AP4–AP7) | `ApprovalRevokeSessionRule` (69), `ApprovalsLogQuery` (70), `ApprovalsLogEntry` (71), `ApprovalRemoveRule` (72), `ApprovalRulesKeep` (73), `ApprovalRulesDiscard` (74) | `ApprovalSessionRules`, `ApprovalRules`, `ApprovalPreview`, `ApprovalsLogPage`, `ApprovalsLogDetail`, `ApprovalsLogRefused` | B10. |
| Tracker (T0b–T6, T3a, T4) | `TrackerOpenLink` (75), `TrackerEdit` (92) | `TrackerBoard`, `TrackerEditResult` (`LocalOnly`); **`TrackerSummary { tag, has_tracker, counts }` is `Focus(tag)`** (`peer.rs:831`, `protocol.rs:3749-3753`) | Board content, notes, links and staged commands (`kind: command`) never leave the host. `TrackerSummary` is published per the topic table. |
| Slash commands (#458) | `SessionCommandsGet` (77) | `SessionCommands` | Mac-local. |
| Authored PRs, Perri verdict, Merge (#461, #486, #493, #495, #508) | `AuthoredPrsDemand` (78), `AuthoredPrsRefresh` (79), `AuthoredPrPreviewRequest` (88), `AuthoredPrNotify` (89), `AuthoredPrStartSession` (90), `AuthoredPrLink` (91), `AuthoredPrMerge` (93) | `AuthoredPrs`, `AuthoredPrPreview`, `AuthoredPrNotifyResult`, `AuthoredPrStartSessionResult`, `AuthoredPrLinkResult`, `AuthoredPrMergeResult` | The daemon holds the operator's GitHub token and a verdict store, and `AuthoredPrMerge` enqueues or merges irreversibly: local-only on every host, never routed. `Topic::AuthoredPrs` is never in a satellite's `publish_topics`. (Perri's verdict is recorded through the MCP tool `perri.record_verdict`, not a client verb.) |
| Conversation history (#464–#475) | `ConversationHistoryGet` (80), `ConversationResume` (81), `…Remove` (82), `…Restore` (83), `…PurgeRemoved` (84), `…SettingsSet` (85), `ConversationResumeRelease` (86), `…Rename` (87) | `ConversationHistory`, `ConversationResumeResult`, `ConversationHistoryChanged`, `ConversationResumeFailed` | Entries carry a `sensitive` flag (`src/conversations/store.rs:50`) but the whole family is `LocalOnly` regardless. |
| Message queue (S1 #506, S3 #514) | `SessionQueueWatch` (94), `SessionQueueTakeBack` (95), `SessionQueueRemove` (96); `SessionSend.client_ref` (field) | `SessionQueue`, `SessionQueueResult`, `SessionQueueReturned`; `Turn.user_parts` and `QueueEntryWire.merge_group` (fields) | Local-only (D7). `user_parts` travels inside `SessionTurns`/`SessionTurnDelta`, so it follows the transcript rule. B11 for the gate. |
| `/mcp` panel (#515) | `SessionMcp` (97) | `SessionMcpResult` | Operator-only. |
| Session lifecycle extras (BA6a, MF2c, #430) | — | **`SessionTurnOrigin` and `SessionBridge` are `Focus(tag)`** (`peer.rs:742-744`) | Topic table: transcript family / boolean. |

Composer history (#509, #511) has **no wire form**: it is a Mac-local store
(`macOS/Nostromo/Data/ComposerHistoryStore.swift`) and never leaves the Mac.

### What a satellite publishes, per topic

| Topic / frames | Content? | `personal` (Sendai) | `work` (Kobe) or PHI repo |
|---|---|---|---|
| `MotherJobs` (crew keys from MC1 included) | titles, questions, plan path, branch | FND-1 as today (`Open`, work-send jobs filtered) | metadata: 8-hex id suffix, state, `paused_reason`/`activity` enums, `paused_at`, progress %, gate/lens counts, attention reason enums, decision present (bool) |
| `MotherStatusline` | counts | yes | yes |
| `MotherAwaitDetected` | job snapshot | `Job` class as today | metadata as `MotherJobs` |
| `MotherPeek` | job output | never (not published on any uplink) | never |
| `Session*`, `FocusLayout`, `PaneContent`, `Notification`, `ActivitySnapshot`, `SessionSummaryUpdate`, `SessionModelState`, `SessionTasks` (transcripts, TF/FV, BA0, M1) | yes | `Focus` class as today (non-sensitive tags only) | never; `SessionState` reduced to `{pseudonymous tag, state}` |
| `SessionTaskDetail`, approval frames, future `terminal_*` | yes | never (`LocalOnly`) | never |
| `Activity` | tool and file names | `Activity` class as today | never |
| `FocusListResp`, `SessionListResp`, `FocusCreated`, `FocusRegistryUpdated` | titles, labels | redacted as today (`redact_for_network`) | pseudonymous tag, agent name from the fixed set, state |
| `ApprovalPending` | count | yes (non-sensitive tags) | yes, pseudonymous tag |
| `DecisionRequest` / `DecisionResolved` | prompt, choices | `Focus` class as today | `{request_id, pseudonymous tag, deadline, choice count, agent from fixed set}` / `{request_id, outcome}` |
| `PerriState` | PR titles, repos | `Focus` class as today | `{requested count, per PR: number, changed_lines}`; no repo, title or author |
| `TeriState`, `FredState`, `Work*`, `TeriPicks` | mail, todos, tickets | only if `publish_sensitive = true` (default false) | never |
| `ModelCatalog`, `ModelDefaults`, `ActivityHealth` | no | yes | yes |
| `TrackerSummary` (2026-11-23) | counts only | `Focus` class as today (non-sensitive tags only) | `{pseudonymous tag, has_tracker, counts}` |
| `TrackerBoard`, `TrackerEditResult` (staged commands, notes, links) | yes | never (`LocalOnly`) | never |
| `SessionTurnOrigin` (2026-11-23) | origin kind and ids of a transcript turn | `Focus` class as today | never (transcript family) |
| `SessionBridge` (2026-11-23) | a boolean | `Focus` class as today | `{pseudonymous tag, connected}` |
| `SessionQueue*` (message queue) | queued text | never (`LocalOnly`; D7) | never |
| `AuthoredPrs*` (PR list, verdicts, merge results) | repos, titles, owner focuses | never (`LocalOnly`) | never |
| `ConversationHistory*`, `SessionCommands`, `SessionMcpResult`, `ClaudeLoginState`, `MotherNoticeState` | titles, prompts, names | never (`LocalOnly`) | never |
| `Terminal*`, `RemoteShell*`, approval rules/log frames | yes | never (`LocalOnly`) | never |
| `PaneContent` with a Huey `Document` body; any frame for a Huey tag | personal notes | never (`LocalOnly` / sensitive tag) | never |

## Dependency graph

```
W14 linux-primary  (independent; Tokyo packaging)

W9 ws-transport ──┬──▶ W10 satellite-uplink ──┬──▶ W15 mac-device-admin
                  │                           │
                  └──▶ W11 ios-ws-client ─────┴──▶ W12 seq-resume ──▶ W13 push-relay ──▶ W16 ios-push-enrichment
```

W11 needs W9 for pairing and W10 for the `host` field; it may start once W9 is
merged and W10 is merged or nearly so (`--depends-on "$W9,$W10"` is the safe
form). W15 touches only `macOS/` and needs W10's relay.

## Dispatch order (rewritten 2026-11-23 to today's queue)

**What the 2026-10-18 rule waited for is merged.** AP2a (#278, #287), AP2b
(#308), AP2c (#301), AP3 (#310), MC3 (#297), MC4 (#299), MC5 (#290), MC6
(#381), CL1 (#311), CL2 (#314), terminal 1a–3e (#319–#373), tracker T1 (#312)
and T0b–T6/T1w, and message queue S1–S5 (#505–#514) are all on main. Open on
2026-11-23: PR #518 (Mac leftovers; edits `macOS/Nostromo.xcodeproj` and
`NostromodClient.swift`) and PR #519 (crew timeouts). Parked or unplanned, so
not in the way: model switching M4–M7, browser pane BP1–BP6, QA fixture mode,
message queue S6 (steer; it will edit the session wire when planned).

**The rule now:** no backplane wedge runs concurrently with **any** other job
that edits `src/ipc/protocol.rs`, `src/ipc/server.rs`, `src/ipc/peer.rs` or
`src/ipc/session_manager/` (the exhaustive matches and the ordinal table make
such merges painful, not just textual), or the same Xcode project. In
practice: hold S6 and M4–M7 until W10 merges, or slot them between wedges.

| Step | Wedge | Start when | Touches |
|---|---|---|---|
| 0 | this docs PR | merge first | docs |
| 0′ | crew follow-up (prerequisite 2) | before W9 is added | `.mother/crew.yml` |
| 1 | **W14** | now; runs beside anything (disjoint files except `src/bin/nostromd.rs` startup and `src/mother/mod.rs`, which no queued job edits) | Makefile, `dist/systemd/`, `src/mother/mod.rs`, `nostromd.rs` startup, `ci.yml` |
| 1′ | nextest (prerequisite 5, optional) | any time; never blocks a wedge | `.github/workflows/ci.yml`, `docs/ci.md` |
| 2 | **W9** | after steps 0 and 0′; no other session-wire job running. Beside W14 is fine, but W14 and W9 both edit `nostromd.rs` startup and the Makefile: merge W14 first or expect a small conflict | session wire, `session_manager/mod.rs` (B11), Makefile, new CLI |
| 2′ | iOS test target (prerequisite 6, recommended) | any time before W11; beside W9/W10 | `iOS/Nostromo.xcodeproj`, `ci.yml`, `Makefile`, `docs/ios-verification.md` |
| 3 | **W10** | W9 merged; same exclusion | session wire |
| 4 | **W11** | W9 + W10 merged, Ada D1–D7 signed off, prerequisite 6 merged (or knowingly skipped), no other job editing `iOS/Nostromo.xcodeproj` | NostromoKit, `iOS/Nostromo.xcodeproj` |
| 4′ | **W15** | W10 merged, Ada D1–D7 signed off, no other job editing `macOS/Nostromo.xcodeproj` (PR #518 today); not beside W11 (both add Kit wire types) | `macOS/`, `macOS/Nostromo.xcodeproj` |
| 5 | **W12** | W10 + W11 merged | session wire, Kit |
| 6 | **W13** | W12 merged, Ada S1–S8 signed off, AWS account ready; same exclusions (session wire and the iOS project) | session wire, `src/push/`, `infra/push-relay/`, iOS |
| 6′ | relay-test gate (crew delta 5) | right after W13 merges | `.mother/crew.yml` |
| 7 | **W16** | W13 merged; entitlement requested (granted is not required) | iOS project (new extension target), daemon |

Gates and lenses: every wedge added after this PR merges is gated in observe
mode by the `.mother/crew.yml` on its base. Run `mother gates check` once after
the crew follow-up merges. Lenses now run automatically (Mother #75), and the
repo's lens default is all four, so the wedges' `lenses` blocks matter only for
`remove`.

```bash
cd ~/Code/nostromo
W14=$(mother add --plan-file docs/plans/backplane/W14-linux-primary.md    --repo nostromo --branch feat/backplane-linux-primary    --max-cost 20)
# after this docs PR and the crew follow-up merge:
W9=$( mother add --plan-file docs/plans/backplane/W9-ws-transport.md      --repo nostromo --branch feat/backplane-ws-transport      --max-cost 60)
W10=$(mother add --plan-file docs/plans/backplane/W10-satellite-uplink.md --repo nostromo --branch feat/backplane-satellite-uplink --max-cost 55 --depends-on "$W9")
# after Ada signs D1-D7 (and the iOS test target merges):
W11=$(mother add --plan-file docs/plans/backplane/W11-ios-ws-client.md    --repo nostromo --branch feat/backplane-ios-ws-client    --max-cost 60 --depends-on "$W9,$W10")
W15=$(mother add --plan-file docs/plans/backplane/W15-mac-device-admin.md --repo nostromo --branch feat/backplane-mac-device-admin --max-cost 45 --depends-on "$W10,$W11")
W12=$(mother add --plan-file docs/plans/backplane/W12-seq-resume.md       --repo nostromo --branch feat/backplane-seq-resume       --max-cost 50 --depends-on "$W10,$W11")
# after Ada signs S1-S8:
W13=$(mother add --plan-file docs/plans/backplane/W13-push-relay.md       --repo nostromo --branch feat/backplane-push-relay       --max-cost 75 --depends-on "$W12")
W16=$(mother add --plan-file docs/plans/backplane/W16-ios-push-enrichment.md --repo nostromo --branch feat/backplane-ios-push-enrichment --max-cost 50 --depends-on "$W13")
```

(`--depends-on "$W10,$W11"` on W15 serialises the two Swift wedges; drop
`$W11` if the operator prefers W15 first. W15's cap is raised from $35 to $45:
the comparable Mac UI slice, message queue S2, spent $39.)

## CI prerequisites (new, 2026-11-23)

**Rust: nextest is optional.** Numbers and caveats are in "Readiness",
prerequisite 5. W9 adds `tests/ipc_ws_transport.rs` and
`tests/device_pairing.rs`, W10 `tests/uplink_roundtrip.rs` and
`tests/uplink_egress.rs`, W12 and W13 more; each is one more binary in the
GitHub job's serial run. That does not lengthen a backplane hop while the Mac
shards (20–25 min) are the slower half of CI, and the sandbox gate (≈ 3.3 min)
is unaffected.

**iOS: add a test target, recommended before W11, which reverses a committed
policy.** Today iOS is verified in layers (`docs/ios-verification.md`): L1
logic in NostromoKit (`swift-tests-kit`, runs on macOS), L2 Python source
scans (`tests/ios_policy`), L3 a compile (now also CI's `ios-simulator-build`,
generic simulator, no tests), and an L4 that is macOS-only ("L4 — does the
thing actually run (macOS)", `:135`). The committed doc says the repo "does
not run iOS unit tests against a simulator, anywhere, ever" (`:131`) and
argues it in "Why no simulator, anywhere" (`:688-717`). Its load-bearing
reason is discipline: once a simulator-bound target exists, "is this actually
going to work" questions get routed through it whether or not they need a
simulator, and L1/L2 stop being the default. Its incidental reason is cost:
four hand-edited `project.pbxproj` sections and a committed shared scheme
(the untracked ios-curated-view-parity W2 plan says the same). **iOS-T
reverses that policy, so it must rewrite that section, not add beside it.**
The backplane changes the balance:
W11 adds a Keychain credential store, a `nostromo://pair` URL handler, an
encrypted content cache and the pairing screens; W13 adds APNs registration;
W16 adds a Notification Service Extension. The wedges already push the logic
into Kit (W11's `WebSocketClientTests`, `PairingClientTests`,
`DeviceCredentialTests`, `ContentCacheTests`; W16's `EnrichmentPolicyTests`,
`PushDetailFetcherTests`), but Keychain access groups, the URL handler, the
cache's file protection class and the extension's App Group wiring only run in
an iOS process, and the operator cannot test on a device until the backplane
exists (tracker: "iOS untestable until backplane"). Proposed wedge
**iOS-T** (W8-style infrastructure, not numbered in this memo):
- add a hosted unit-test target `NostromoTests` to `iOS/Nostromo.xcodeproj`
  and commit a shared `Nostromo` scheme that includes it;
- `make ios-test`: `xcodebuild test -project iOS/Nostromo.xcodeproj -scheme
  Nostromo -destination 'platform=iOS Simulator,name=<a device the macos-26
  image ships>' CODE_SIGNING_ALLOWED=NO`;
- in `ci.yml`, turn `ios-simulator-build` (`:510-545`) into build-and-test on
  the same runner and paths (`ONLY=ios` already exists in `make ci-remote`,
  `scripts/ci_remote.py:31`, so it then runs the tests too);
- one smoke test (the app delegate launches and `NetworkClient` constructs);
- rewrite `docs/ios-verification.md`: replace "Why no simulator, anywhere"
  (`:688-717`) and the "anywhere, ever" sentence (`:131`) with the new rule,
  and add a layer named **"L5 — iOS simulator (backplane runtime only)"** (the
  name L4 is taken by the macOS layer, `:135`). Keep the discipline argument
  as the rule: only what needs an iOS process (Keychain access groups, URL
  handling, file protection, extension wiring) goes in L5; everything else
  stays L1/L2, and a review checks that.
Cost: cap $20, expected ≈ $8, ≈ 65 min, plus ~5–10 min of macOS runner time on
each Swift PR (off the critical path; the Mac shards are longer). If the
operator declines, the committed policy stands, W11 and W16 keep their
Kit-only tests and say so; nothing else changes.

## Estimate (refreshed 2026-11-23; calibration 2026-10-14 checked against recent jobs; ±33 min per job)

**Calibration used.** Wall time ≈ 38 min + 3 min × expected spend; expected
spend ≈ 40% of the cap (fitted 2026-10-14 on 64 Nostromo jobs). Recent
Nostromo jobs agree on the middle and show a wide spread: message queue S1
spent $5.9 of a $40 cap (15%), S2 (Mac UI) $39 of $45 (87%), S3 $9.6 of $60
(16%); most recent jobs carried $20–45 caps. So caps stay sized for the bad
case (Swift UI work runs near its cap), and expected spend stays 40%. **Per
hop ≈ 50 min** (was 40): GitHub CI now takes about 25 min wall for a full
run (slowest Mac shard 20–25 min, Rust tests 15–20 min, `docs/ci.md:434`;
it was 10–15 min when the calibration was fitted), and every `src/` change
also runs the Swift jobs (`docs/ci.md`, "Path gate"), then Perri and the merge, plus the one-in-three
chance of a fix-up.

**Gate time, one pass, measured** (serial: Mother's own code runs the checks
one after another under one watchdog, Mother's git `origin/main` `0a38549`,
`plugins/mother/lib/gates.sh:246-249` and `plugins/mother/bin/mother-run-job:945-956`;
Nostromo's docs do not state it): Rust ≈ 5 min (clippy ≈ 0.5, `cargo test`
≈ 3.3 from a fresh sandbox, sandbox start ≈ 1.25; recorded in this memo on
2026-10-18 and again in #519's `docs/mother-crew.md` table, "measured
2026-11-23"); `python-test` ≈ 20 min serial on a loaded host (#502: the gate
was seen timing out at ~1266 s); `swift-ci` ≈ 24 min (#519; #502 saw a
1421 s gate). The 2026-10-18 figures of `python-test` under 1 min and
`swift-ci` ≈ 7.5 min are superseded by those. Gate results have been
recorded for months (the tracker counts 52 python-test failures in 106
gate failures), so these are real runs, not guesses. A wedge touching Rust,
Python and Swift paths therefore costs ≈ 5 + 20 + 24 ≈ **49 min** of gates
before any retry (#519's own sum), and `budget_minutes: 75` is ≈ 1.5× that.
Which checks fire follows each check's `when` paths (`.mother/crew.yml`):
`python-test` fires for `tests/**`, `Makefile`, `.github/**`, `macOS/**`,
`iOS/**`, `Shared/**` and `src/mother/**`, so today every backplane wedge
pays it; with crew delta 7 the Rust-only wedges drop to ≈ 5 min.

The job times below add one gate pass, with today's `when` paths.

| Wedge | Cap | Expected spend | Job time (base + gates) | Gates that fire (today's `when`) | Starts after |
|---|---|---|---|---|---|
| W14 linux-primary | $20 | ≈ $8 | ≈ 62 + 25 ≈ 87 min | Rust 5, python 20 | now |
| W9 ws-transport | $60 | ≈ $24 | ≈ 110 + 25 ≈ 135 min | Rust 5, python 20 | this PR, crew follow-up |
| W10 satellite-uplink | $55 | ≈ $22 | ≈ 104 + 25 ≈ 129 min | Rust 5, python 20 | W9 |
| W11 ios-ws-client | $60 | ≈ $24 | ≈ 110 + 44 ≈ 154 min | python 20, swift 24 | W9, W10, Ada D1–D7, iOS-T |
| W15 mac-device-admin | $45 | ≈ $18 | ≈ 92 + 44 ≈ 136 min | python 20, swift 24 | W10, W11, Ada D1–D7 |
| W12 seq-resume | $50 | ≈ $20 | ≈ 98 + 49 ≈ 147 min | Rust 5, python 20, swift 24 | W10, W11 |
| W13 push-relay | $75 | ≈ $30 | ≈ 128 + 49 ≈ 177 min | Rust 5, python 20, swift 24 | W12, Ada S1–S8 |
| W16 ios-push-enrichment | $50 | ≈ $20 | ≈ 98 + 49 ≈ 147 min | Rust 5, python 20, swift 24 | W13 |
| *Prereq: crew follow-up* | $5 | ≈ $2 | ≈ 44 min | none (`.mother/**` matches no check) | now |
| *Prereq: iOS-T* | $20 | ≈ $8 | ≈ 62 + 44 ≈ 106 min | python 20, swift 24 | now |
| *Optional: nextest* | $15 | ≈ $6 | ≈ 56 + 25 ≈ 81 min | Rust 5 (`.rwx/**`), python 20 (`.github/**`) | any time |

Critical path: W9 → W10 → W11 → W12 → W13 → W16 ≈ 135 + 129 + 154 + 147 +
177 + 147 = 889 min of jobs plus 6 hops × 50 min ≈ **20 h end to end** (range
16–24 h), counted from W9's start and assuming the Ada sign-offs land before
W10 merges. With crew delta 7 (Rust-only wedges skip `python-test`), W9 and
W10 save ≈ 20 min each (≈ 19 h). W14, W15 and the prerequisites run off the
critical path. Fastest finish with concurrency 3 is the same ≈ 20 h: the
chain is serial.
**Total cap $415; expected spend ≈ $166** (range $120–$250, the high end if
the Swift wedges behave like S2). With the crew follow-up and iOS-T: cap $440,
expected ≈ $176 (nextest, if done, adds $15 / ≈ $6).
Quota: unknown. W14, the prerequisites and W9 (≈ $42 expected) can land in one
week; the rest spans at least one weekly reset. Ada's sign-offs, not compute,
remain the likely long pole for W11/W15/W13/W16.

**Where the 2026-10-18 gate paragraph went.** Its measured Rust pass (≈ 5 min)
is kept above. Its `swift-ci` ≈ 7.5 and `python-test` under 1 min figures were
replaced by the 2026-11-23 measurements (≈ 24 and ≈ 20), its "up to 3"
attempts is now `max_attempts: 2`, and its "+63 min, ≈ 15 h" total is replaced
by the table above.

**Use Mother's own figure as the live estimate.** Every running job shows an
approximate `≈NN%` and an ETA band (`mother list`, `mother status`, the Mother
panel); trust the line above until a band shows `basis: repo`. `burn_ahead`
can fire on a slow-starting wedge because expected spend is ~40% of the cap;
ack it rather than raising the cap.

**Record per wedge so `mother retro` calibrates:** job id; cap and actual cost;
active time; the ETA band at about 50% and whether the job finished inside it;
gate time per pass, attempts used and any gate left `unavailable`;
`moved_back` reasons; lens count and spend; whether CI agreed with the gates
(`gates_ci_agreement`).

W13 is still the largest job (daemon engine, a Lambda crate and iOS screens).
If the iOS project is contended when W12 merges, split it into W13a (daemon +
relay, Rust only) and W13b (iOS registration and settings); the split is
flagged, not made (open question 8).

## Install coordination

**Rules for every wedge.**
- **Additive only.** New fields are `Option`/`#[serde(default)]` and skipped
  when `None`; no field is renamed or removed; `PROTOCOL_VERSION` stays 4.
- **Feature-gated sends.** A daemon advertises capabilities in
  `Welcome.features` (`"ws"`, `"pair"`, `"devices"`, `"hosts"`, `"uplink"`,
  `"seq"`, `"push"`, `"push_detail"`). A client or satellite sends a new verb,
  or a new `Hello.role`, only when the peer advertised the feature. A
  satellite whose primary lacks `"uplink"` logs one WARN and retries every
  10 min; its local behaviour is unchanged.
- **Unknown frames are ignored, not fatal**, on both sides (Rust
  `#[serde(other)]`-style fallbacks where they exist; Swift decoders already
  skip unknown `type`s, which each Swift wedge's tests re-assert).
- **Schedule daemon installs between Mother jobs on that host.** `make
  install-daemon` restarts `nostromd`, which ends every daemon-hosted session
  and orphans a running job (`runner_died`, then tier escalation). Check
  `mother list` on that host first. `make mac-install` does not restart the
  daemon (pin is read per connection); relaunch the app.
- *2026-11-23:* `make install-daemon` (`Makefile:136-193`) now stages and
  signs **three** binaries (`nostromd`, `nostromo-guard`,
  `nostromo-mcp-bridge`) from `$(NOSTROMO_TARGET_DIR)/release`, and refuses to
  restart while a remote (ECS) shell is open (`bin/nostromo-restart-guard`,
  `FORCE=1` overrides). Run it from a plain terminal, not a Nostromo shell.
  After W9 it also installs the `nostromo` CLI (W9 "Files to change"). Running
  sessions keep their old MCP bridge until restarted.
- **Order:** primary (Tokyo) first, then Sendai, then Kobe, then the iOS
  build. A newer primary with older satellites is always safe; a newer
  satellite with an older primary degrades to "not uplinked".
- **Rollback:** on the affected host, `git checkout <previous merge>` and
  reinstall (`make install-daemon` / `make install-daemon-linux` /
  `make mac-install`). New state files (`~/.nostromo/devices.json`,
  `~/.nostromo/uplink-token`, `~/.nostromo/push/`) are ignored by older
  builds and reused on roll-forward. Rolling Tokyo back below W10 makes
  satellites back off; rolling it below W9 makes paired phones show "Can't
  reach" (not "unpaired") until roll-forward.

| Wedge | Tokyo (primary) | Sendai | Kobe | iPhone/iPad | Mixed-version notes |
|---|---|---|---|---|---|
| W14 | first install: `make install-daemon-linux`, then `loginctl enable-linger $USER` once | — | — | — | none (no wire change) |
| W9 | install; set `ws_addr = "0.0.0.0:47101"` (or its WireGuard/LAN address) and `pair_host` in `config.toml`; restart | optional, any time between jobs (listener stays loopback) | optional, between jobs (loopback; never listens off-box) | — (W11) | old Mac/iOS clients ignore the new features; legacy TCP unchanged |
| W10 | install first; restart | install between jobs; set `mode = "satellite"`, `uplink.url`, `uplink.egress = "personal"`, `host_name`; run `nostromo device pair --satellite sendai` on Tokyo and `nostromo uplink pair --url … <code>` on Sendai | same, with `uplink.egress = "work"` (the default); WireGuard split tunnel | — | satellite before primary → satellite stays local-only and retries |
| W11 | — | — | — | install from Xcode (operator); pair | needs Tokyo ≥ W9 (pairing) and ≥ W10 (host badge; absent host renders as one list) |
| W15 | — | `make mac-install` | `make mac-install` | — | needs the local daemon ≥ W10 and Tokyo ≥ W10; against an older daemon the menu items show "Can't reach" |
| W12 | install first | install between jobs | install between jobs | new iOS build | old clients ignore `seq`/`Gap`; a satellite resumes only if the primary advertises `"seq"` |
| W13 | deploy the relay (AWS, operator, README), write `[push]` and the relay token, install | install (new `MotherJob`/`DecisionRequest` fields) | install | new iOS build with push entitlement | an older satellite lacks `deadline`/`paused_at`: push omits the timeout phrase and falls back to first-seen time |
| W16 | install | — | — | new iOS build with the extension (Filtering configuration only after Apple grants it) | a device without `nse_withdraw` keeps W13's withdrawal |

## What this sequence deliberately does not do

- **Carry session conversations or terminals.** Remote Control (Anthropic's
  relay) carries sessions; the terminal-pane plans keep terminals on the Mac
  (`LocalOnly`). The backplane carries state and read-only views.
- **Answer anything off-host** (B10): approvals, decisions, Mother holds,
  Perri actions.
- **Change Mother or Bishop.** They stay host-local; the satellite's poller is
  the bridge. Mother's broker is never exposed off-host.
- **Make coding work from a closed laptop.** Nothing runs on a sleeping Kobe.
- **Host agent sessions on Tokyo** (no `OperatorApp` there; B10).
- **Host a hub or add E2E above WireGuard.**

## Risks

- **Kobe cannot run WireGuard** — retired 2026-10-10. Keep Kobe's profile
  split-tunnel (`AllowedIPs` = the home subnet) and point `uplink.url` at the
  primary's WireGuard/LAN address, not a public name.
- **Metadata leaks through names.** Host names come from the OS by default
  (an MDM may set them); W10 requires `host_name` explicitly for `work`
  satellites and validates `^[a-z][a-z0-9-]{0,15}$`. Focus tags are
  pseudonymised for `work`.
- **Sensitive data on the primary.** With B9 defaults, nothing from Kobe
  beyond metadata reaches Tokyo, and Sendai's Teri/Fred stay home unless
  `publish_sensitive` is turned on.
- **Queue contention.** *2026-11-23:* the approvals and crew chains are
  merged. The remaining risk is new session-wire work started beside a wedge
  (message queue S6, model switching M4–M7) and Mac Xcode-project edits beside
  W15. The calendar is now set by Ada's sign-offs, not by other chains.
- **Merge gate regressions (new).** Without B11, attaching any phone or a
  satellite route silently stops merging on that session; with B11 wrong, a
  local legacy client could see a merged turn drawn twice. W9's tests pin
  both directions.
- **Gate data lost (new).** At `budget_minutes: 45`, a Rust + Python + Swift
  wedge (measured ≈ 49 min of serial gates) overruns and records `incomplete`;
  observe mode loses the data without holding the job. #519's 75 and crew
  delta 7 address it.

## Open technical item — RESOLVED 2026-10-18

The draft's routed-action question is settled by B10 and B9: **no mutating
verb is routed in this sequence.** The W10 router forwards only verbs that are
`Allowed` for network peers (`SessionAttach`, `SessionDetach`,
`ActivitySnapshotRequest`, `SessionModelGet`, `SessionList`, `FocusList`), and
only to `personal` satellites; for a `work` satellite it answers
`HostUnavailable { reason: "egress_metadata" }`. A satellite executes routed
frames under `Routed` trust (= `Tcp` policy) and re-checks the policy itself.
Driving Mother, sessions or Perri from a phone needs a new bet and PRD.

## Open questions for the operator (with recommendations)

1. **Ada sign-offs D1–D7 (pairing) and S1–S8 (push).** *Refreshed
   2026-11-23.* Nothing has been signed since 2026-10-18. What to do: start one
   Ada session (`ada` agent) pointed at `docs/prds/daemon-pairing-flow.md`
   "Design-loop notes for Ada" (turns 1–3) and `docs/prds/push-relay.md`
   "Design-loop notes for Ada" (turns 1–3), and ask her to sign off or
   rewrite each item in place. When: before W10 merges (about a day after W9
   starts), so W11/W15 are not idle. What each blocks:
   - **D1** (Local Network permission on home Wi-Fi; new failure state and its
     copy), **D2** (camera alert not counted), **D3** (pairing dies with its
     window; "lost the connection" copy), **D4** (server check before the
     confirmation step), **D5** (lockout across two open codes), **D6**
     (re-pairing an already-paired phone; copy), **D7** (new: queue view on
     the phone): block **W11** (D1, D2, D4, D6, D7) and **W15** (D3, D5); W9
     and W10 already build the daemon side as proposed.
   - **S1** (withdrawal depends on Apple's entitlement), **S2** (decisions
     never coalesced), **S3** (unknown PR size omitted), **S4** (now moot
     after S7, sign as withdrawn), **S5** (repo names gated on owner),
     **S6** ("under 1 min"), **S7** (no lock-screen decision buttons; a phone
     is not an operator), **S8** (no enrichment for work hosts, PHI repos or
     decisions): block **W13** (S1–S3, S5–S7) and **W16** (S1, S7, S8).
   - The operator's own answers needed in the same pass: open question 9
     below (mail-and-todos default; Kobe's device-admin level).
2. **Routed actions from devices.** *Recommend:* none that mutate in this
   sequence (resolved item above). Revisit only with a device-trust PRD.
3. **Approvals on the phone.** *Recommend:* counts only (B10); a count-only
   "approval needed" push is a later Ada item, not W13.
4. **PTY/terminal on the backplane at all?** *Recommend:* no. Terminals are
   Mac-local by design (`LocalOnly`, production-shell rules); the phone shows
   the terminal-pane 1e placeholder.
5. **Kobe's egress profile, and Teri/Fred from Kobe.** *Recommend:* `work`
   (metadata only), Teri/Fred never leave Kobe; Sendai `personal` with
   `publish_sensitive = false` until you choose otherwise.
6. **Apple's notification-filtering entitlement.** *Recommend:* request it
   now (still not requested as of 2026-11-23, per the tracker). What to do: in
   the Apple Developer account, request
   `com.apple.developer.usernotifications.filtering` (Apple's request form for
   the notification-filtering entitlement) for the iOS app,
   `com.hammer.nostromo.ios` (`iOS/Nostromo.xcodeproj/project.pbxproj:404`),
   whose Notification Service Extension W16 adds (its bundle id is not created
   yet; W16 picks it, conventionally
   `com.hammer.nostromo.ios.NotificationService`), stating that the extension removes notifications
   that are no longer relevant. If the form needs the extension's id, request
   it when W16 creates the target. When: now; lead time is Apple's.
   What it blocks: only W16's silent-withdrawal path (S1). W16 ships without
   it; until it is granted, withdrawal is badge-reliable and
   notification-removal best effort.
7. **Tokyo vs Sendai as primary.** *Recommend:* Tokyo. The primary needs no
   Mac app, answers nothing (B10) and hosts no sessions; Sendai stays a
   satellite, with `mode = primary` as the fallback if W14 finds a blocker.
8. **Split W13** into W13a (daemon + relay, Rust) and W13b (iOS)?
   *Recommend (2026-11-23):* no, keep one job, unless another job is editing
   `iOS/Nostromo.xcodeproj` when W12 merges (the approvals chain this used to
   wait on has merged).
9. **PRD open questions (operator):** mail-and-todos default for a new
   device, *recommend* on (it only covers Sendai's under B9); Kobe's device
   admin level, *recommend* `full` (the lost-phone moment can happen at
   work; pairing and widening need a real click in the Mac app).
10. **Queue view on the phone (new, 2026-11-23; Ada D7).** Message queue S1
    made the queue view, take-back and remove local-only (`peer.rs:798-800`,
    `:1103-1105`), and Stop returns dropped texts only to the Mac that pressed
    it. Options: (a) parity: publish `SessionQueue` to paired devices for
    non-sensitive personal focuses and let a phone take back; (b) local-only
    (today); (c) local-only plus a count. *Recommend (b) for v1, (c) as a
    follow-up.* A phone cannot send (`SessionSend` is refused for every
    network trust), so it has nothing of its own to take back; take-back is a
    session-driving verb behind the operator nonce and stays B10-adjacent; and
    queued text is unsent user input that need not reach Tokyo's disk. A
    count ("2 waiting") would be a new metadata field on `SessionInfo`, safe
    for `work` hosts too, and is cheap to add later. Parity needs the
    device-trust bet.
11. **Gate budget.** *Recommend* merging #519 as is (`budget_minutes: 75`)
    plus the `python-test` path filter (crew delta 7) before W9 is added.
    Gate durations are unknown; raise the budget only if a real run comes
    back `incomplete`.
12. **iOS test target first, and nextest?** *Recommend* iOS-T before W11,
    knowing it reverses the committed "no simulator, anywhere" policy in
    `docs/ios-verification.md` and must rewrite it. nextest is optional (no
    effect on a backplane hop while the Mac shards are slower). Neither blocks
    W9 ("CI prerequisites").

## Questions for Ada

- **Q1 — Pairing UX — ANSWERED** (`docs/prds/daemon-pairing-flow.md`).
  D1–D6 (and, since 2026-11-23, D7) still pending Ada's sign-off (see the
  PRD's "Design-loop notes"). The refresh adds one information note there:
  the CLI is a new `nostromo` binary (the old TUI binary of that name is
  gone), so the PRD's `nostromo device …` copy stands.
- **Q2 — Push — ANSWERED** (`docs/prds/push-relay.md`). S1–S6 pending; the
  refresh adds **S7** (no lock-screen decision buttons and no phone-as-
  operator: answers come only from the verified Mac app) and **S8** (no
  enrichment for work hosts or PHI repos: the primary never holds that
  text), in the PRD's design-loop notes, turn 2.
- **Q3 — Multi-host presentation.** Unchanged: W11 defaults to one merged
  list with a host badge. New wrinkle: Kobe's rows are metadata-only
  (state, ref, reason), so they look different from Sendai's.
- **2026-11-23 (turn 3 in both PRDs).** Pairing PRD: new **D7** (queue view on
  the phone, recommend local-only), and an information note that merged turns
  (several queued messages answered in one turn) show on the phone as the
  Mac shows them. Push PRD: no new sign-off; S4 becomes moot under S7 and the
  entitlement request is still outstanding.
