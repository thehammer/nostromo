# PRD: Nostromo self-hosting — build and upgrade Nostromo from inside Nostromo

**Author:** Ada
**Captured:** 2026-10-06
**Status:** ready-for-archie
**Surface:** `nostromd` (daemon + MCP bridge), the macOS app, and Claude Code
remote control as seen from another device. iOS app updates are out of scope.

## Problem

Hammer runs his Claude Code sessions from inside Nostromo. That includes the
sessions that develop Nostromo. Today an agent inside Nostromo can edit, build
and test Nostromo, but it cannot ship the result without damaging the
environment it runs in:

- **Installing a new daemon ends every session, including the one that ran
  the install.** Every agent is a child of `nostromd`, so a daemon restart
  kills them all. Sessions come back on reconnect with the same Claude session
  id, but the turn in progress is lost, and the agent that started the install
  never finds out whether it worked.
- **A bad daemon has no safety net.** A daemon that won't start, or one that
  crash-loops (this has already happened once, from a code-signing kill), takes
  every agent down with it. The only agent that could fix it is one of the
  agents that just died. The user has to notice and repair it by hand.
- **Replacing the app is manual and was fragile.** Quit, install, relaunch.
  One relaunch has already crashed at launch because of a full-screen race.
- **The user can't follow along from elsewhere.** Remote control is not on for
  Nostromo-launched sessions. A self-upgrade, which is the riskiest thing an
  agent does to Nostromo, happens when no one can see it.
- **Agents can't see the UI they're changing.** The app control socket can
  dump the view tree, run a layout audit and take screenshots, but agents only
  reach it through Bash, and nothing limits what they do with it.

**Goal, in the user's words:** run Claude Code sessions entirely from inside
Nostromo. **Success:** an agent inside Nostromo can change Nostromo, ship it,
and carry on afterwards without the user babysitting.

## Audience and actors

- **Hammer at the Mac.** Several focuses open across windows, sometimes
  full-screen on several displays. An agent may upgrade Nostromo while he is
  typing in another focus. He wants the upgrade to cost him at most a glance.
- **Hammer away, following remotely.** On his phone or another machine,
  following sessions through Claude Code remote control. He wants to see that
  an upgrade happened, approve it if needed, and steer the agent, all without
  the Mac in front of him.
- **The self-updating agent** (usually Cody or Claudia working in the Nostromo
  repo). It builds a candidate, asks to install it, and needs to know the
  outcome inside the same turn so it can verify the change or react to a
  rollback.
- **Bystander sessions.** Every other live focus (Perri mid-review, Fred, Teri,
  dynamic "Claudia in <project>" focuses) and Mother's job view. They didn't ask
  for the upgrade and must not notice it beyond a brief indicator.

## The experience

**Upgrading the daemon (the keystone).** Cody finishes a daemon change and asks
Nostromo to install it. An approval sheet appears for Hammer, on the Mac and
anywhere he is following remotely. It says what is being installed (commit,
branch, whether the tree is clean), that it will restart the daemon, and which
sessions are live. He approves with one action. Every focus shows a small
"reconnecting" state for a few seconds. Perri, who was halfway through
streaming a review, keeps streaming from where she was: no lost text, no
duplicated text, no "interrupted" turn. Cody's install action comes back
*inside the same turn* with "installed <new version>, healthy", and Cody goes on
to exercise the change. Hammer's half-typed message in another focus is still
in the input box. Anything he sent during the gap is delivered once, in order.
The activity feed records: who upgraded, from what version, to what version,
how long it took, and the outcome.

**When the new daemon is bad.** Same flow, but the candidate crashes on start,
or comes up without answering health checks. Nostromo puts the previous build
back automatically, without asking. Sessions behave exactly as in a successful
upgrade. Cody's install action returns "rolled back: <reason>", with enough
detail to debug. Hammer gets a notification he can't miss, on the Mac and
remotely. Nothing restarts in a loop.

**A crash with no upgrade.** The daemon dies unexpectedly. launchd brings it
back and sessions continue as above. Hammer finds out from the activity feed
and the notification, not from lost work.

**Upgrading the app.** An agent installs a new app build and asks for a
relaunch. After approval, the app quits and reopens. Every window comes back on
the same display, with the same frame, the same focus and pane layout, and the
same full-screen state. No empty or orphaned Spaces are left behind. Unsent
drafts are still there. Agents don't notice, because the daemon keeps hosting
them.

**Remote control by default.** Every session Nostromo launches can be reached
through Claude Code remote control under its focus name, without Hammer turning
anything on. Each focus header shows an indicator: on, off (opted out), or
unavailable with a reason. Hammer can opt one focus out, and that choice
persists.

**Agents seeing their own UI.** An agent inside Nostromo can, by default, list
windows, dump and search the view tree, take a window screenshot and run the
layout audit, so it can verify a UI change it just made. Clicking, typing,
dropping files and key events are a separate grant. Hammer gives that grant per
focus, it shows in the UI, and he can take it back. No agent, with or without
the grant and whatever path it uses, can ever answer a decision sheet, approve
a permission, approve its own restart request, or change its own grants.

## Acceptance criteria

### A. Session continuity across daemon restart or crash (keystone)

- A1. After a daemon restart (planned) or a daemon kill (`kill -9`), every
  session that was live before is live afterwards, under the same focus and
  the same Claude session id, with no user action. The doctor reports the same
  session set before and after.
- A2. **Ambitious bet:** a turn that is streaming when the daemon restarts
  finishes normally afterwards. The rendered turn has no lost or duplicated
  text and is not marked interrupted, and any tool call that was running
  (e.g. a 60-second `sleep` in Bash) returns its real result. This is the
  difference between "self-hosting" and "self-hosting with an asterisk". If it
  turns out to be impossible, Archie should show that with evidence in the
  design loop. It should not be designed around quietly.
- A3. If a turn *is* ever lost despite A2, the turn is visibly marked
  interrupted, with a one-action "resume" that continues the same Claude
  session. A lost turn is never silent.
- A4. Messages the user sends (from the Mac or remotely) while the daemon is
  down are each delivered exactly once, in order, after it returns. If one
  can't be delivered, the user sees that on the message itself. It never
  silently disappears.
- A5. Pending decision sheets (permission prompts, questions to the user) that
  were open before the restart are still open and answerable afterwards, and
  answering one acts on the session it came from. If the user answers one
  during the gap, the answer either takes effect after reconnection or is
  clearly refused. It is never silently dropped.
- A6. Transcripts, pane layouts, the selected focus per window and unsent input
  drafts are identical before and after a daemon restart.
- A7. While the daemon is unavailable, each focus shows a reconnecting state.
  When it returns, the indicator clears without the user doing anything. The
  app never shows a false "session ended" state for a session that comes back.
- A8. Mother's job view and the MCP tools (`nostromo.show`, `perri.load_pr`,
  pane tools) work in surviving sessions after the restart with no session
  restart. An MCP call made during the gap fails with a clear,
  retry-worthy error. It does not hang.

### B. Safe self-install with verification and automatic rollback

- B1. An agent inside Nostromo can ask for a daemon install of a named build
  through one Nostromo-provided action. The action's result, returned in the
  same agent turn and not left to the agent to poll, is one of:
  `installed and healthy`, `rolled back (reason)`, `declined by user`, or
  `refused (reason)`.
- B2. Before anything is replaced, a candidate that fails to build or fails
  the project's test suite is refused, and the running daemon is untouched.
- B3. After install, the new daemon must count as healthy within 30 seconds.
  Healthy means: it answers the app, every previously live session is
  reattached, the MCP bridge answers, and `bin/nostromo-doctor` passes. If it
  isn't healthy in time, the previous build is put back automatically and is
  healthy within a further 30 seconds.
- B4. The previous known-good build is always kept, so rollback never depends
  on rebuilding. Nostromo makes at most one rollback attempt per install. If
  the rollback also fails, it stops, does not loop, and alerts the user
  (criterion F4).
- B5. A crash loop is impossible to miss. If the daemon crashes three times in
  five minutes, whether after an install or not, Nostromo stops restarting the
  failing build, falls back to the last known-good build, and alerts the user.
- B6. The app always shows the running daemon's version (commit, branch,
  clean or dirty) and the app's own version. The doctor reports both.
- B7. If the app and daemon builds differ in a way that breaks them, the app
  says so plainly, naming both versions. Silent misbehaviour is not acceptable.
  Builds that work together keep working.
- B8. There is a recovery path that doesn't need a working daemon or any agent:
  one documented command the user runs in a terminal restores the last
  known-good daemon.

### C. App relaunch

- C1. After an app relaunch (approved or manual), every window that was open
  reopens on the same display, with the same frame, focus and pane layout.
- C2. Windows that were full-screen come back full-screen in their own Space,
  on the same display. After relaunch, Mission Control shows no empty or
  orphaned Spaces from Nostromo, and the number of full-screen Nostromo Spaces
  equals the number of full-screen windows.
- C3. If a display is gone, its windows reopen on a remaining display, fully
  visible. They are not lost or placed off-screen.
- C4. A relaunch does not interrupt any agent session or turn, because sessions
  belong to the daemon. Unsent drafts and pending decision sheets are still
  there after relaunch.
- C5. The app doesn't crash on relaunch in any of these situations: windowed,
  full-screen, several full-screen windows across several displays, a missing
  display.

### D. Remote control on by default

- D1. **Ambitious bet:** every session Nostromo launches can be reached through
  Claude Code remote control (on the user's phone and in the web app) under its
  focus name within 15 seconds of starting, with no per-session action from
  the user. A message sent remotely appears in the Mac focus as a normal user
  turn, and the reply streams on both sides. This is a bet because it was shown
  to be impossible for stream-json sessions on 2026-05-31 (see Dependencies).
  Archie decides whether that still holds on the current Claude Code version
  and what to do if it does. The experience requirement doesn't change.
- D2. Each focus can be opted out, and the opt-out survives app and daemon
  restarts. New focuses are opted in by default.
- D3. Each focus header shows the remote-control state: on, off (opted out), or
  unavailable (with a reason the user can read on hover). The indicator must be
  truthful: it shows "on" only when the session can actually be reached from
  another device.
- D4. After a daemon restart, a remotely followed session can still be followed
  and steered from the same remote session, with no new link and no
  re-pairing.
- D5. The user can answer decision sheets and restart approvals remotely (see
  F1). Agents can't (see E3).

### E. UI introspection for agents

- E1. Every agent inside Nostromo can, through its Nostromo tools and without
  Bash, list windows, dump the view tree, find views by text, take a window
  screenshot and run the layout-issues audit, with results matching
  `bin/nostromo-app`'s for the same app state. These read-only tools never
  change app state.
- E2. Input actions (click, type, key, paste, drop) are off for an agent until
  the user grants them for that focus. A focus with the grant shows it visibly.
  The user can revoke it, and a revoked grant takes effect on the next call.
  Without the grant, an input call is refused with a clear message.
- E3. **Hard rule:** no input action from an agent can answer a decision sheet,
  approve a permission, approve a restart or install, change remote-control
  opt-outs, or change input grants. This holds by any route: MCP tools,
  `bin/nostromo-app` run from Bash, or a raw socket write. Such an attempt is
  refused, the agent gets an error saying why, and the user sees the attempt
  in the activity feed.
- E4. An agent cannot turn on app control or give itself an input grant. Doing
  that requires a deliberate action by the user, outside the agent's session.

### F. Who can restart, and how the user is told

- F1. A daemon install or restart started by an agent, and an app relaunch
  started by an agent, both need the user's approval. Approval is one action,
  available on the Mac and remotely. The approval sheet shows the build
  (commit, branch, clean or dirty), what will restart, and the live sessions.
  An approval that hasn't been answered after 30 minutes expires, and the
  agent receives `declined by user (expired)`.
- F2. The user can restart or upgrade the daemon and relaunch the app at any
  time without an extra confirmation.
- F3. Crash restarts and automatic rollbacks need no approval. The user is told
  after the fact.
- F4. Every restart, whatever its cause (agent install, user, crash, rollback),
  produces an activity entry with: trigger (who or what), from-version,
  to-version, outcome, downtime, and sessions affected. Failures (a rollback,
  a crash loop, a failed rollback) also produce a notification, both on the Mac
  and wherever the user is following remotely.
- F5. Agents can't approve restarts. This is covered by E3 and listed again
  here because restarts are the most dangerous approval.

## Phasing

1. **Sessions survive the daemon (A).** This is the keystone. Without it,
   everything else is a careful way to lose work. Also start a **spike on D1
   right away**, because its feasibility is unknown and may change the shape of
   phase 4.
2. **Safe self-install (B, F).** Approval, verification, rollback, version
   visibility, crash-loop guard, manual recovery command. After this, an agent
   can ship daemon changes on its own.
3. **App relaunch fidelity (C).**
4. **Remote control by default (D),** as the spike's result allows.
5. **Agent UI introspection (E).** Read-only first (E1), then gated input with
   the hard rule (E2 to E4) in the same release as input. Input must never ship
   without E3.

## Verification with existing tooling

- **Restart survival soak:** with three or more live sessions, one streaming a
  long reply and one running a 60-second Bash tool call, restart the daemon 20
  times in a row (planned and `kill -9`). Pass: 20 out of 20 meet A1 to A6.
  Check transcripts against the session JSONL, and check that the doctor's
  session set doesn't change.
- **Bad-build drill:** install a candidate built to crash on start, and one
  built to come up but not answer health checks. Pass: B3 and B4 are met within
  the time budgets, and the agent's action returns `rolled back`.
- **Crash-loop drill:** install a daemon that crashes every few seconds.
  Pass: B5, and no more than three restarts happen.
- **Relaunch drill (control socket):** record `bin/nostromo-app windows` (frames,
  full-screen, key window) and per-window screenshots, relaunch, and compare.
  Run with one display and with two, windowed and with several full-screen
  windows. Count Spaces before and after to check C2.
- **Mother continuity:** with `bin/fake-mother-broker` serving jobs, restart the
  daemon and confirm the Mother view and Mother MCP reads continue (A8).
- **Guardrail drill:** with a decision sheet open, run `bin/nostromo-app click`
  on its approve button from an agent's Bash, then send the same click through
  the agent MCP tool. Pass: both are refused, and both appear in the activity
  feed (E3).
- **Doctor:** reports daemon and app versions, last restart cause, rollback
  state and remote-control state per session. Each drill above ends with a
  passing doctor.

Ongoing measures: restart-survival rate (target 100%), time from approval to
healthy (target under 10 seconds at p95), rollbacks per week, and agent
self-installs that finished without any user action beyond the approval.

## In scope

- Daemon restart and crash continuity for all daemon-hosted sessions.
- An agent-callable install action with approval, verification, rollback,
  versioning and a crash-loop guard.
- App relaunch fidelity across displays and full-screen Spaces.
- Remote control on by default, with per-focus opt-out and an indicator.
- Agent tools for UI introspection, plus gated input and protected surfaces.
- Restart notifications and activity records, on the Mac and remotely.

## Out of scope

- **iOS/iPadOS app updates** (TestFlight and device installs). A different
  distribution problem.
- **Updating Claude Code itself** or the agents' definitions. Nostromo hosts
  them but does not ship them.
- **An automatic update channel** (pulling releases from GitHub, scheduled
  upgrades). Every install is started by a user or an agent.
- **Agents restarting without approval.** This is deliberately left out of v1
  (see open question 1).
- **Changing the PR flow.** Self-install is for local testing and shipping on
  this Mac. It does not merge, bypass CI or use `--admin`.
- **Remote shells and production systems.** This PRD gives agents no new reach
  beyond this Mac's Nostromo.
- **The Rust TUI.**

## Product risks

- **Mid-turn data loss erodes trust fast.** If an upgrade loses an agent's work
  even once in a while, Hammer goes back to babysitting, and the feature has
  failed even though it technically works. That's why A2 is a bet and not
  "best effort", and why A3 requires that a loss is never silent.
- **Restart loops.** A bad build that keeps getting restarted burns sessions
  and attention. B4 and B5 cap it.
- **An agent bricks its own host.** The agent that breaks the daemon is the one
  agent that can't fix it. Rollback that needs no agent, a kept known-good
  build, and a one-command manual recovery (B8) are the floor.
- **Privilege creep through UI control.** An agent that can click can, in
  principle, approve itself. Bash makes the control socket reachable whatever
  the MCP tools allow. That's why E3 is defined at the app's surface and applies
  to every route, not just the agent tools.
- **Approval fatigue.** If install approvals are frequent and look alike,
  Hammer will approve them without reading. The sheet must show what is
  actually different each time: commit, dirty tree, sessions at risk.
- **Remote-control exposure.** Turning remote control on by default makes every
  agent, many running with bypass permissions, steerable from the user's Claude
  account. That widens the blast radius of an account compromise. The opt-out
  and the truthful indicator (D2, D3) are the mitigation. Hammer should accept
  this default knowingly.
- **Version skew.** An app and daemon from different commits are normal during
  self-hosting. Breakage that comes from skew looks like a random bug unless
  B6 and B7 make it visible.

## Dependencies

- **Persistent bidirectional session host** (`docs/prds/persistent-bidirectional-session-host.md`,
  shipped). It provides daemon-hosted stream-json sessions and resume on
  reconnect. That PRD **verified on 2026-05-31 (Claude Code 2.1.158) that
  `--remote-control` is inert in stream-json/`--print` mode**: sessions never
  registered with the relay. It also found that resuming the same session id
  interactively *does* register remote control, which suggested a handoff
  model. The installed CLI is now 2.1.290, and that finding has not been
  re-checked. D1 depends on it.
- **App control socket and `bin/nostromo-app`** (`docs/app-control.md`), which
  E builds on.
- **`bin/nostromo-doctor`**, used for health checks (B3) and verification.
- **`bin/fake-mother-broker`**, used for Mother-continuity drills.
- **launchd** (`com.hammer.nostromd`), which restarts the daemon after a crash.
- **The existing decision-sheet surface**, which is the user's only approval
  surface and gets the restart and install approvals.

## Assumptions

- The approval rule for daemon restarts stays in place in v1 *even once
  sessions survive restarts*. Survival removes the reason for it, but survival
  should prove itself first.
- Read-only introspection is on by default for every Nostromo-launched agent
  whenever app control is enabled. Screenshots may include other focuses'
  content. That's acceptable on a single-user machine.
- Agents may install builds from unmerged branches and dirty trees for local
  testing, as long as the build is clearly labelled (B6, F1).
- A user answer to an approval also counts when given remotely, as the
  session-host PRD already decided for permission prompts.

## Open questions

For the user (values):

1. **Once A is proven (the 20-restart soak passes), may agents install and
   restart the daemon without approval**, with rollback as the safety net and
   notification after the fact? Or is approval permanent? The PRD assumes
   approval is required in v1 either way.
2. **Should remote control default to on for every agent**, including ones that
   handle sensitive material (Fred: email; Teri: work tracking)? Or should some
   agents default to off? The PRD assumes on for all, with per-focus opt-out.

For engineering (Archie's homework, not the user's):

- **What enables remote control for a launched session, and does it work for a
  stream-json session on the current Claude Code (2.1.290)?** The flag or
  setting has not been verified for this version, and the last verified result
  (2.1.158) was negative. If it is still inert, Archie should bring back
  evidence and options that preserve D1 to D4. Candidates include the handoff
  model from the session-host PRD or Nostromo's own remote surface.
- Whether A2 can be met at all, given that agents are children of the daemon
  today. This is a feasibility question to settle with evidence in the design
  loop.
