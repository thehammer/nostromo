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
| W9 ws-transport | **Yes**, after this docs PR merges | AP2a (#278/#287), AP3 (#310), MC4 (#299) and CL1/CL2 (#311/#314) are all merged, so the 2026-10-18 exclusion is moot. Only rule left: no other job editing `src/ipc/{protocol,server,peer}.rs` at the same time. Nothing like that is queued today. W9 now also carries B11 (a few lines in `src/ipc/session_manager/mod.rs`). |
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
2. **Crew config follow-up** (`.mother/crew.yml`, config only). PR #519 (open)
   raises the `python-test` (900 → 1800 s) and `swift-ci` (1800 → 2400 s)
   timeouts. Still open after it: raise `gates.budget_minutes` from 45 to about
   **90**, because Mother runs the checks one after another
   (`plugins/mother/lib/gates.sh`, the `while read check` loop, Mother
   `origin/main` `0a38549`) and a Rust + Swift wedge measures about 25 (Rust) +
   20 (python) + 24 (swift) = ~69 min; and narrow `python-test`'s `when` so a
   Rust-only wedge's `tests/*.rs` does not trigger the 20 min Python run
   (`tests/**` matches them today, `.mother/crew.yml:30`). Without this the
   gate rows of every Rust wedge come back `incomplete` (observe mode: data
   lost, nothing held). Cost: an operator edit, or a $5 cap job (≈ $2).
   **Do before W9 is added**; W14 does not need it.
3. **Ada sign-offs** D1–D7 (pairing) and S1–S8 (push): one Ada session over
   both PRDs' design-loop notes. Blocks W11/W15 and W13/W16 respectively;
   needed by the time W10 merges to keep the Swift wedges from idling. Cost: an
   interactive Ada session (≈ $3–8), plus your reading time. Exact asks in
   "Open questions for the operator", item 1.
4. **Apple notification-filtering entitlement** (`com.apple.developer.
   usernotifications.filtering`) for the extension's bundle id. Operator, on
   the Apple Developer site, now: lead time is Apple's. Blocks only the
   filtering half of W16 (S1); W16 ships without it.
5. **cargo-nextest in CI and the RWX sandbox** (recommended, not blocking).
   The Rust tests job measures 14.5–17 min green, 20 min slow, with the test
   binaries running one after another for 12–14 min (`.github/workflows/
   ci.yml:143-155`; step limit 35, job 45 since #517). There are 169 test
   binaries in `tests/` and W9–W13 add about eight more. nextest runs binaries
   in parallel; expect the test step to drop to roughly 5–8 min. Caveats the
   job must handle: nextest does not run doctests (keep a `cargo test --doc`
   step), and each test runs in its own process (no test here uses
   `serial_test`, but any test relying on in-process global state must be
   found). Cap $15, expected ≈ $6, ≈ 55 min. Run it beside W14; it saves about
   10 min per hop on every Rust wedge (6 hops) and shortens the `rust-test`
   gate the same way.
6. **iOS test target and simulator test job** (recommended before W11). See
   "CI prerequisites" below. Cap $20, expected ≈ $8, ≈ 65 min; can run beside
   W9/W10 (it edits `iOS/Nostromo.xcodeproj` and `.github/workflows/ci.yml`,
   which neither touches).

**Decisions only the operator can make** (details and recommendations in
"Open questions for the operator"): the queue view for phones (D7, recommend
local-only in v1); whether to raise the gate budget (recommend 90); whether to
add nextest and the iOS test target first (recommend both, neither blocks W9);
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
7. **CI.** The Rust tests job takes 14.5–20 min (above); W9–W13 add tests, so
   nextest (prerequisite 5) is worth doing first but does not block. Linux
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
    `run_mother_pollers` (`nostromd.rs:864`, 2 s interval `:402`);
    `src/mother/mod.rs` `list_jobs` `:431`, `run_mother` `:606`; the
    macOS-only verifier arms are `src/ipc/peer_verify.rs:344-386`, `:657-677`,
    `:730-740`; `sha2` is already a direct dependency (`Cargo.toml:92`, the ECS
    pin). The calibration is redone with recent job costs ("Estimate").

## Mother features adopted (2026-10-18, Mother `origin/main` `e597389`)

*2026-11-23 updates (Mother `origin/main` `0a38549`):* the lens wave (#75) is
merged; gates run serially; the checklist parser accepts `- **ID-n** text`
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

### Crew config deltas (for MC5 if not yet dispatched, else a one-line follow-up PR)

1. Merge `.mother/crew.yml` before any backplane wedge is added; a job added
   earlier carries no `crew` and is ungated (W14 may start ungated).
2. `python-test` should be `where: sandbox`, not `any`: Python goes through the
   RWX sandbox like Rust. (MC5 chose `any`; its own verification step already
   runs `rwx sandbox exec -- make python-test`.)
3. `gates.budget_minutes: 45`, not 20. A wedge that matches `rust-clippy`,
   `rust-test` (about 5 min with sandbox start) and `swift-ci` (about 7.5 min)
   plus `python-test` is about 14 min before any retry, so 20 is `incomplete`
   waiting to happen.
4. `lenses.scopes.phi-security` gains `src/push/**`, `infra/**`, `template.yaml`,
   `Shared/NostromoKit/Sources/NostromoKit/Transport/**`,
   `Shared/NostromoKit/Sources/NostromoKit/Push/**`,
   `iOS/NostromoNotificationService/**`; `ops-infra` gains `dist/**`, `infra/**`,
   `template.yaml`.
5. After W13 merges: a `relay-test` gate (`cargo test --manifest-path
   infra/push-relay/Cargo.toml`, `where: sandbox`, `when` `infra/push-relay/**`).
   The standalone crate is not covered by `cargo test` at the root.

### Needs a Mother-side change (listed, not requested)

- Run the lens wave automatically (PR #75, open); until it merges the lens
  half of this plan is manual (`mother review-lens`).
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
8. **Wire versioning.** `PROTOCOL_VERSION` is still 4 (`protocol.rs:26`), the
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
  B1–B6 are defined in the platform memo; B7–B10 are new here.

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
`ubuntu-latest` (`ci.yml:33-63`). W14 is packaging only. If W14 hits a blocker,
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

## Wire inventory (FND-1 classification of every new message)

Network trusts after W9/W10: `Tcp` (legacy, unchanged), `Paired { device_id,
sensitive }` (a device over WebSocket), `Satellite { host }` (a satellite's
uplink, seen on the primary). On a satellite, frames the primary routes down
run under `Routed`, which has exactly `Tcp`'s policy. `is_network()` is true
for all four.

| Message (direction) | Wedge | FND-1 class / policy | Notes |
|---|---|---|---|
| `PairCheck`, `Pair` (c→d) | W9 | `Refused` in `network_policy`; accepted only on a token-less pairing socket, enforced in `ws.rs` before dispatch | ordinals 41, 42 |
| `DeviceUnpairSelf` (c→d) | W9 | `Allowed` for `Paired` only; `Refused` for `Tcp`, `Satellite`, `Routed` | ordinal 43 |
| `DevicePairStart`, `DevicePairUpdate`, `DevicePairCancel`, `DeviceList`, `DeviceRevoke`, `DeviceSetScope` (c→d) | W9 | `Refused` for every network trust; on the primary, `Satellite` gets a W10 exception gated by the satellite's registry `admin` level | ordinals 44–49 |
| `PairOffer`, `Paired`, `PairRefused`, `Unauthorized`, `DeviceUnpaired` (d→c) | W9 | `Open`, **targeted only** (never broadcast; `Paired` carries the token) | a test asserts none enters the broadcast channel |
| `DevicePairing`, `DevicePairOutcome`, `Devices`, `DeviceRevoked`, `DeviceAdminError` (d→c) | W9 | new `ServerClass::Admin`: local peers yes; `Satellite` only per its `admin` level (W10); `Paired`, `Tcp` never | |
| `Hosts`, `HostUnavailable` (d→c) | W10 | `Open` | host names and timestamps only |
| `MotherJobs.host`, `MotherStatusline.host`, `MotherAwaitDetected.host`, `Activity.host`, `FocusListResp.host`, `SessionListResp.host`, `ApprovalPending.host`, `PerriState.host`, `DecisionRequest.host`, `DecisionResolved.host` (fields) | W10 | class unchanged | `#[serde(default, skip_serializing_if = "Option::is_none")]` |
| `Hello.role`, `Subscribe.resume` (fields) | W10, W12 | — | additive |
| `Gap` (d→c) | W12 | `Open` | topic, host, seq bounds, reason enum |
| `RegisterPush`, `SetPushPrefs`, `PushSentLog`, `PushWaiting` (c→d) | W13 | `Allowed` for `Paired` only, self-scoped to the connection's own device id; `Refused` for `Tcp`, `Satellite`, `Routed` | ordinals 50–53 |
| `PushSentLog`, `PushWaiting`, `PushStatus` (d→c) | W13 | `Open`, targeted only | closed vocabulary text |
| `PushAvailability` | — | **dropped** (B10; S7) | |
| `PushDetail` (c→d) | W16 | `Allowed` for `Paired`, self-scoped; reply follows B9 and the device's `sensitive` scope | ordinal 54 |
| `PushDetail` (d→c) | W16 | `Open`, targeted only | text present only for `personal`-profile, non-PHI items |
| `DecisionAnswer.host`, `DecisionAnswerResult` | — | **dropped** (B10; S7) | |

Every new `ClientMsg` adds an arm to `network_policy`, `targets_sensitive_session`
and the ordinal table, and bumps `CLIENT_MSG_VARIANTS` (41 → 50 after W9 → 54
after W13 → 55 after W16; if another plan lands a verb first, the next free
ordinal is used and the count re-derived on the wedge's base).

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
| future tracker frames (T0b) | yes (guarded by T0g) | follow their FND-1 class when they land | never |

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

## Dispatch order (fits the existing queue)

The approvals chain (AP2a next, then AP2b, AP3…) and MC3 → MC4 go first.
CL1/CL2 are held. Rule from the operator: **no backplane wedge runs
concurrently with AP2a, AP3 or MC4 if it touches the session wire
(`src/ipc/protocol.rs`, `server.rs`, `peer.rs`) or an Xcode project.** Every
wedge except W14 touches one of those.

| Step | Wedge | Start when | Touches |
|---|---|---|---|
| 0 | this docs PR | merge first | docs |
| 1 | **W14** | now; may run beside AP2a and MC3 (disjoint files). Must merge before MC4 starts, or wait until MC4 merges: both edit `src/mother/mod.rs` | Makefile, `dist/systemd/`, `src/mother/mod.rs`, `nostromd.rs` startup |
| 2 | **W9** | AP2a, AP3 and MC4 are all merged (or not yet started and held behind W9 by the operator). CL1, when released, must also not overlap: it edits `peer.rs`/`protocol.rs` | session wire |
| 3 | **W10** | W9 merged; same exclusion | session wire |
| 4 | **W11** | W9 + W10 merged, Ada D1–D6 signed off, and no Xcode-touching job running (AP*, MC*, terminal 1d/1e, T1) | NostromoKit, `iOS/Nostromo.xcodeproj` |
| 4′ | **W15** | W10 merged, Ada D1–D6 signed off, no Xcode-touching job running; not beside W11 (both may add Kit wire types) | `macOS/`, `macOS/Nostromo.xcodeproj` |
| 5 | **W12** | W10 + W11 merged | session wire, Kit |
| 6 | **W13** | W12 merged, Ada S1–S8 signed off; same exclusions (it touches the session wire and the iOS project) | session wire, `src/push/`, `infra/push-relay/`, iOS |
| 7 | **W16** | W13 merged; operator has requested the filtering entitlement | iOS project (new extension target), daemon |

Gates and lenses: a wedge is gated only if MC5's `.mother/crew.yml` (with the
deltas in "Mother features adopted") is on `origin/main` when `mother add` runs.
Enqueue W9 onward after it; W14 may go ungated. Run `mother gates check` once
after the merge to validate the file before the first job.

```bash
cd ~/Code/nostromo
W14=$(mother add --plan-file docs/plans/backplane/W14-linux-primary.md    --repo nostromo --branch feat/backplane-linux-primary    --max-cost 20)
# after AP2a, AP3, MC4 merge:
W9=$( mother add --plan-file docs/plans/backplane/W9-ws-transport.md      --repo nostromo --branch feat/backplane-ws-transport      --max-cost 60)
W10=$(mother add --plan-file docs/plans/backplane/W10-satellite-uplink.md --repo nostromo --branch feat/backplane-satellite-uplink --max-cost 55 --depends-on "$W9")
# after Ada signs D1-D6:
W11=$(mother add --plan-file docs/plans/backplane/W11-ios-ws-client.md    --repo nostromo --branch feat/backplane-ios-ws-client    --max-cost 60 --depends-on "$W9,$W10")
W15=$(mother add --plan-file docs/plans/backplane/W15-mac-device-admin.md --repo nostromo --branch feat/backplane-mac-device-admin --max-cost 35 --depends-on "$W10,$W11")
W12=$(mother add --plan-file docs/plans/backplane/W12-seq-resume.md       --repo nostromo --branch feat/backplane-seq-resume       --max-cost 50 --depends-on "$W10,$W11")
# after Ada signs S1-S8:
W13=$(mother add --plan-file docs/plans/backplane/W13-push-relay.md       --repo nostromo --branch feat/backplane-push-relay       --max-cost 75 --depends-on "$W12")
W16=$(mother add --plan-file docs/plans/backplane/W16-ios-push-enrichment.md --repo nostromo --branch feat/backplane-ios-push-enrichment --max-cost 50 --depends-on "$W13")
```

(`--depends-on "$W10,$W11"` on W15 serialises the two Swift wedges; drop
`$W11` if the operator prefers W15 first.)

## Estimate (calibration: wall ≈ 43 min + 2.6 min per actual $; expected spend ≈ 40% of cap; ±33 min per job)

**Baseline kept.** The numbers below are the original formula and are still the
plan of record. They predate gates and lenses, so add the gate time per pass
from the third column; they are not re-fitted.

**Per-pass gate time (observe mode, one pass):** Rust ≈ 5 min (clippy ≈ 0.5,
`cargo test` ≈ 3.3 from a fresh sandbox, sandbox start ≈ 1.25), `swift-ci` ≈
7.5 min, `python-test` under 1 min. Enforce adds a pass plus a worker turn per
failed attempt, up to 3. So W9 +5, W10 +5, W11 +8, W12 +13, W13 +13, W14 +5,
W15 +8, W16 +13 min. On the critical path that is about +63 min, so about
**15 h** end to end instead of 14 h. Lens spend is extra and unverified
(see the Mother-side list).

**Use Mother's own figure as the live estimate.** Every running job shows an
approximate `≈NN%` and an ETA band in `mother list`, `mother status`, the
statusline and the Mother panel. The band is calibrated from past jobs: per
repo once 20 jobs exist, else the fleet, else `?`. Nostromo has few jobs, so
expect the fleet basis and wide bands for the first wedges; trust the 43 min +
2.6 min/$ line until a band shows `basis: repo`. The cost signal divides by the
`--max-cost` cap, and our expected spend is about 40% of the cap, so
`burn_ahead` (cost fraction at least 0.5 and twice the progress fraction) can
fire on a normal, slow-starting wedge; ack it rather than raising the cap.

**Record per wedge so `mother retro` calibrates:** job id; cap and actual cost;
active time; the ETA band at about 50% (`progress_half` event) and whether the
job finished inside it; gate time per pass, attempts used and any gate left
`unavailable`; `moved_back` reasons; lens count and spend; whether CI agreed
with the gates (`gates_ci_agreement`). Keep the rows in
`docs/plans/backplane/` notes or the PR body; `mother retro` has the tables
(`stage_calibration`, `progress_accuracy`, `gates`, `gates_ci_agreement`,
`red_at_presentation`, `interruptions`).


| Wedge | Cap | Expected spend | Job time | Starts after |
|---|---|---|---|---|
| W14 linux-primary | $20 | ≈ $8 | ≈ 65 min | queue (now) |
| W9 ws-transport | $60 | ≈ $24 | ≈ 105 min | AP2a, AP3, MC4 merged |
| W10 satellite-uplink | $55 | ≈ $22 | ≈ 100 min | W9 |
| W11 ios-ws-client | $60 | ≈ $24 | ≈ 105 min | W9, W10, Ada D1–D6 |
| W15 mac-device-admin | $35 | ≈ $14 | ≈ 80 min | W10, W11, Ada D1–D6 |
| W12 seq-resume | $50 | ≈ $20 | ≈ 95 min | W10, W11 |
| W13 push-relay | $75 | ≈ $30 | ≈ 120 min | W12, Ada S1–S8 |
| W16 ios-push-enrichment | $50 | ≈ $20 | ≈ 95 min | W13 |

Critical path: W9 → W10 → W11 → W12 → W13 → W16 ≈ 105+100+105+95+120+95 =
620 min of jobs plus 6 hops × 40 min ≈ **14 h end to end** (range 11–17 h),
counted from W9's start. W14 and W15 run off the critical path (W15 beside
W12). Fastest finish with concurrency 3 is the same ≈ 14 h: the chain is
serial, and the AP/MC exclusions remove most parallelism in practice.
**Total cap $405; expected spend ≈ $162** (range $120–$200).
Quota: unknown. Roughly $50 (W14, W9) could land before the next weekly reset
if W9's slot opens this week; the rest spans at least one reset. Ada's
sign-offs, not compute, are the likely long pole for W11/W15/W13/W16.

W13 is the largest job (daemon engine, a Lambda crate and iOS screens). If the
operator wants the iOS/Xcode half off the AP serialisation, split it into
W13a (daemon + relay, Rust only) and W13b (iOS registration and settings);
the split is flagged, not made (open question 8).

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
- **Queue contention.** Every wedge but W14 collides with the approvals and
  crew chains on the session wire or Xcode; the calendar is set by those
  chains and by Ada, not by compute.

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

1. **Ada sign-offs D1–D6 (pairing) and S1–S8 (push).** Gate W11/W15 and
   W13/W16. *Recommend:* run Ada once on both PRDs' design-loop notes
   (turn 1 and turn 2) before W9 merges, so the Swift wedges are not idle.
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
   now for the extension's bundle id (lead time is outside our control); W16
   ships without it.
7. **Tokyo vs Sendai as primary.** *Recommend:* Tokyo. The primary needs no
   Mac app, answers nothing (B10) and hosts no sessions; Sendai stays a
   satellite, with `mode = primary` as the fallback if W14 finds a blocker.
8. **Split W13** into W13a (daemon + relay, Rust) and W13b (iOS)?
   *Recommend:* yes if the approvals chain is still holding the iOS project
   when W12 merges; otherwise keep one job.
9. **PRD open questions (operator):** mail-and-todos default for a new
   device, *recommend* on (it only covers Sendai's under B9); Kobe's device
   admin level, *recommend* `full` (the lost-phone moment can happen at
   work; pairing and widening need a real click in the Mac app).

## Questions for Ada

- **Q1 — Pairing UX — ANSWERED** (`docs/prds/daemon-pairing-flow.md`).
  D1–D6 still pending Ada's sign-off (unchanged by this refresh; see the
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
