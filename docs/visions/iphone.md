# Nostromo for iPhone

## Premise

The iPhone is not a smaller Mac. It is a different posture entirely:
operator-in-motion, single-handed, attention split, sessions measured in
seconds not hours. Trying to port the TUI or the Mac-native app to a
phone would produce something that's neither a good Mac experience nor a
good iPhone experience.

The bet: the iPhone surface should focus on **awareness, triage, and
coordination** — *not* deep work. Most agent-orchestration tasks naturally
split into "decide what to do" (quick) and "actually do it" (long). The
iPhone owns the first half. The Mac owns the second.

The operator gets a thin, fast lens into the same agent ecosystem the Mac
sees. They cannot author new MCP tools or write code from the phone.

**Amended 2026-11-23 (backplane sequence).** In this sequence the phone is a
**"what needs me, and is it urgent"** surface. It can read agent output
(personal hosts), see what is waiting and how urgent it is, and react to a
notification by deciding whether to go to the Mac. It **answers nothing**:
no approving or denying decisions or permission requests, no answering or
resuming Mother jobs, no PR approve / request-changes, no Mother enqueue, no
messages to Claudia. Only the verified Mac app, by a real click, answers
anything. The operator accepted this narrowing on 2026-11-23 as a
conservative first step (`docs/prds/push-relay.md` and
`docs/prds/daemon-pairing-flow.md`, decision logs). Answering from the
phone comes back only through a device-trust PRD of its own.

*Original premise, kept for the record (later, when opened up):* the
operator can read agent output, approve/deny pending decisions, ask Claudia
a quick question, queue a Mother job for later, react to a notification.
The phone keeps work moving while the operator is between contexts.

## Audience and context of use

The operator, away from the primary Mac:

- **Commuter train, ~60 min each way.** Predictable daily window.
  **(v1)** Read-only triage: see what needs the operator across Macs, read
  the detail of personal-host items (a Mother job's question, a waiting
  PR's number and size), judge what is urgent, and plan the desk hour.
  Nothing is answered, approved or queued from the phone. *(Original, kept
  for the record; later, when opened up: approve/deny pending PR work,
  glance at calendar, ask Claudia a brief question to stash for later,
  queue a small job for the Mac daemon to pick up.)*
- **Walking between meetings (2–3 min windows).** Glance at Mother queue,
  see whether the long-running job is done, read the result.
- **Notification triggers (5–15 seconds).** "Mother job awaiting input"
  push. Glance at it, decide "now or later", and walk back to the Mac if it
  is now. *(Amended 2026-11-23: the original "tap approve/deny/leave-for-
  later" is deferred; the phone answers nothing in this sequence.)*
- **Couch / weekend ambient awareness.** Not actively working but wants
  to see what's running on the Mac without opening the laptop.
- **Hotel / off-site / no-Mac scenarios.** Backup posture for "I left
  my laptop and need to triage" — limited functionality, not the
  primary use case. In v1 that means seeing what is waiting, not acting
  on it.

The phone is **never** the place for sustained typing-driven work,
reviewing large diffs, or running multi-step interactive sessions with
Claudia. Those map to the Mac surfaces.

## Capabilities

*Amended 2026-11-23.* Each capability is marked **(v1)** where this
sequence delivers it, or **(later, when opened up)** where it is deferred.

- **Mother queue glance (v1).** List of jobs by state across Macs, "needs
  you" first, taps through to detail (Kobe jobs as state and reference
  only: "Details stay on kobe"). **(later, when opened up)** For awaiting
  jobs, tap to approve / deny / leave, with an inline note field for
  adherence-override justifications.
- **Push notifications, routed (v1, narrowed).** Mother jobs awaiting an
  answer, decision requests (as a signal to go to the Mac) and Perri review
  requests, in a closed vocabulary; deep-link into a read-only detail
  screen. A resolved item's notification is replaced with "no longer needs
  you" (Apple's silent-filtering permission does not fit a personal tool;
  investigated 2026-11-23, not requested). Calendar events and other kinds
  are **(later, when opened up)**.
- **Claudia thin chat (later, when opened up).** A bare-bones thread with the operator's
  Claudia agent. Send a short message; receive a response. Threads
  persist across devices — open the same conversation on Mac later.
  Voice-to-text via system dictation. No tool-call rendering, no MCP
  in-line — just text dialogue.
- **Perri PR triage (v1: awareness only).** PR review requests appear as
  notifications and in the "needs you" list (number, size, waiting count).
  **(later, when opened up)** Tap a PR to see title, author, small diff
  summary, and CI state; approve / request-changes / dismiss inline; full
  diff in a Reader-style scroll view, not a code editor.
- **Mother enqueue (later, when opened up; limited).** Send a Mother request as a structured
  short-form: ticket key, repo, one-line intent. The daemon picks it up
  on the Mac, Archie + Cody run there. The phone never spawns workers.
- **Calendar quick-view (later, when opened up).** Today/tomorrow agenda.
  Tap for details, join link, mark as done. Read-only. Deferred because
  the calendar comes from the same Microsoft 365 source as Fred's mail,
  which stays on the Macs in v1. Whether calendar stays home is an open
  operator question in `docs/prds/daemon-pairing-flow.md`; the v1 default
  is yes.
- **Budget posture awareness (later, when opened up).** Tiny pace bars in a
  glance widget. Surfaces if posture flips to conservative / critical. (In
  v1, a spend pace running ahead of budget only counts toward the badge and
  the summaries; see `docs/prds/push-relay.md`.)
- **Home-screen widget (later, when opened up).** Mother queue counts,
  calendar next event, posture chip. Visible without opening the app.
  Widgets are out of scope for the push PRD.
- **Lock-screen Live Activity (later, when opened up).** When a Mother job
  is running, show a Dynamic Island / Live Activity with state and ETA. Tap
  to open detail. Live Activities are out of scope for the push PRD.

## Constraints

- **(Added 2026-11-23) The phone answers nothing in the backplane
  sequence.** No decision, approval, Mother question, PR action, enqueue or
  message is sent from the phone. Mail, todos and (by default, pending the
  operator) calendar stay on the Macs in v1, and work-host (Kobe) items are
  metadata only.

- **No diff editing, no code authoring, no terminal.** The phone
  doesn't expose a PTY, doesn't render claude code's TUI, doesn't
  let the operator write or modify source code. If a workflow needs
  those, the answer is "do it on the Mac when you're back."
- **No agent spawning.** The phone does not run claude or any other
  worker locally. All inference + tool calls happen on the Mac daemon
  (or the cloud backplane, depending on the architecture decision).
- **No multi-account, no team features.** Single-operator client over
  their own daemon. Sharing/team support is out of scope.
- **Limited file management.** Cannot browse the operator's filesystem,
  edit documents, or upload arbitrary files. *(later, when opened up, with
  Claudia thin chat: attach photos / screenshots to a Claudia message.)*
- **Read-mostly for transcript views.** Operator can read agent output
  but should not be expected to comment on every paragraph. If they want
  to give detailed feedback, they wait for the Mac.
- **Latency-tolerant.** Network round-trip to the daemon (or cloud
  backplane) is acceptable as long as the user-visible response feels
  reactive (<500ms for thin UI; agent latency is whatever it is).
- **Offline-aware.** Reading recent state works offline from the last
  sync, marked stale, and the phone never mistakes "can't reach the
  server" for "not paired". (There are no phone actions to hold for later
  in v1. *Later, when opened up:* actions taken offline are held on the
  phone and sent when connectivity returns.)

## Resolved decisions (2026-05-16)

- **Codebase: shared SwiftUI with iPad, single Xcode project, dual
  targets.** Same view-models and MCP client; conditional layout based
  on size class + keyboard attachment. Don't fork until evidence forks
  help.
- **Ship order: iPhone target first.** The commute use case is concrete
  and iPhone-specific (one hour, hands on phone, no laptop). Phone
  constraints also force the cleanest minimal UI, which iPad inherits.
- **v1 scope: Mother triage + push notifications + Perri PR triage
  + calendar quick-view.** *(Narrowed 2026-11-23: "triage" here means
  seeing and judging urgency, not acting; calendar quick-view is deferred
  by default with mail; see the amended premise.)* Claudia thin-chat
  **deferred** out of v1 — it
  needs cross-device session state, daemon-side conversation routing,
  and message ordering done right. Ship v1, watch how the commute use
  case actually plays, then design Claudia thin-chat with real signal.

## Resolved since (2026-10 to 2026-11)

- **Daemon transport.** Resolved in `docs/plans/backplane-sequencing.md`
  (B2): VPN to home over WireGuard, not Tailscale and not a cloud
  backplane. The phone talks to an always-on home server, not to a Mac.
- **Auth model.** Signed off 2026-11-23 in
  `docs/prds/daemon-pairing-flow.md`: pair once by QR or typed code; the
  operator never sees a credential.
- **Push notifications.** Signed off 2026-11-23 in
  `docs/prds/push-relay.md`: a closed-vocabulary relay in a dedicated
  personal AWS account.

## Still open
- **Claudia state** (deferred to post-v1): where the phone-side Claudia
  conversation lives. Probably on the Mac daemon with phone as thin
  renderer. Will be addressed when Claudia thin-chat is brought back
  into scope.
- **PR diff renderer**: phone-shaped diff reader — its own PRD when
  Perri PR triage is being designed.
- **Voice input**: lean on system dictation in v1; explicit voice mode
  only if v1 evidence demands it.

## Related work

- `docs/prds/daemon-pairing-flow.md` and `docs/prds/push-relay.md` (both
  signed off 2026-11-23) define what this sequence's phone does; their
  decision logs record the narrowing above.

- See `docs/visions/mac-native.md` for the primary surface this
  coordinates with.
- See `docs/visions/ipad.md` for the middle posture between phone
  and Mac.
- Future PRDs anticipated: mobile-shaped PR diff reader, Mother triage
  screen, Claudia thin chat, and a device-trust PRD before the phone may
  answer anything.
