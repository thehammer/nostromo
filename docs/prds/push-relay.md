# PRD: Tell the operator what needs them, without telling anyone else

**Author:** Ada
**Status:** Signed off by Ada 2026-11-23. Design loop closed (S1–S8 signed, S4 withdrawn, new S7a specified; operator answered Q3–Q6). See "Sign-off and decision log" at the end.
**Answers:** Q2 in `docs/plans/backplane-sequencing.md`
**Unblocks wedge:** W13 `push-relay` (`docs/plans/backplane/W13-push-relay.md`) and W16 `ios-push-enrichment`
**Surface:** iPhone (and iPad, same app) notifications; the operator's own machines; the hosted relay as seen from outside.

> **How to read this PRD after sign-off.** Text marked **(v1)** is a decision for
> this version. Text marked **(later, when opened up)** is deliberately deferred
> and is **not** an acceptance criterion for v1. Sections that sign-off withdrew
> are kept, struck through in words ("Withdrawn"), so the reasoning stays
> visible. The operator called v1 "a conservative first step".

## Problem

When the Nostromo app is open and the VPN is up, the phone is current. On a
commute or in a meeting it is not open, and iOS suspends it. The things that
most need the operator happen exactly then: a Mother job stops to ask a
question, an agent session raises a decision and blocks until someone answers
or it times out, a PR lands in the review queue. Today the operator learns
about these only by opening the app on a hunch, or when they get back to a
laptop. A decision with a five-minute timeout is simply lost.

The only way to reach a suspended iPhone app is Apple Push, which means text
leaving the operator's machines: through a small relay the operator owns, into
Apple's delivery system, and onto a lock screen anyone nearby can read. Some of
the operator's work is Carefeed's (the employer). A worker's question, a PR
title or an agent's prompt can name a customer, a colleague, a mail subject or
a Carefeed repo. So the useful notification and the safe notification pull in
opposite directions, and nothing about notifications can ship until that line
is drawn.

## Audience

One operator, five machines, two of which can raise work: **kobe** (the
Carefeed-managed MacBook, work) and **sendai**/**tokyo** (personal, always on).
They read notifications:

- **On the commuter train, ~60 min each way**, phone in hand, VPN usually up
  but cellular coverage patchy. They will act on the phone if the thing is
  small; otherwise they want to know it can wait until the desk.
- **In a meeting**, phone face-up on the table or glanced at under it. Two
  seconds of attention, colleagues within reading distance of the lock screen.
- **First thing in the morning**, before the commute, deciding what the train
  hour is for.

The volume they will tolerate is a handful a day. Past that the app gets
silenced in iOS settings and the whole feature is dead. Every notification has
to answer one question without being opened: **act now, or later?**

## The experience

### What a notification says

Every notification is built only from a **closed vocabulary**: the kind of
thing, the host it came from, a short reference, and a small set of fixed
phrases and numbers that Nostromo itself generates. **No text written by a
worker, an agent, a person, or a third party (GitHub, mail) ever goes through
the relay, on any host, in this version.** That is the line, and it is the
same for every kind. What differs per kind is which fixed facts are worth the
interruption.

Hosts are classified by the operator, on their own machines (not from the
phone), as **work** or **personal**. A host that has not been classified is
treated as **work**. Kobe is work. The one fact that varies by class is the
repository name: it may appear for items from a personal host, never for
items from a work host. **(v1)** For reviews it is also gated on the
repository's owner: a review shows the repository name only if the host is
personal **and** the owner is not a work organisation (default: Carefeed).
The list of work owners can only be changed on the operator's machines; the
phone shows it read-only, like host class. Today every review in the queue is
a Carefeed PR, so in practice no review shows a repository name.

**(v1) What a work-host notification says** (operator decision, 2026-11-23):
the kind, the host name, the short reference (job ref or PR number) and the
fixed reason or size phrases below. Nothing more, on the relay or on the
phone. Kobe items are never enriched (see "On-phone enrichment").

The host appears as its operator-chosen name (`kobe`, `sendai`). Host names are
the operator's own nicknames and are not Carefeed-identifying.

#### Payload contract, per kind

**Mother job awaiting an answer** — sent when a Mother job enters `awaiting`
for any reason except a quota pause (which resumes on its own). Same trigger
Mother already uses for its Mac notification.

| May appear | Never appears |
|---|---|
| Kind ("Mother") | The worker's question, or any fragment of it |
| Host name | Adherence notes, hold details, failure text |
| Short job reference: the 8-character random suffix of Mother's job id (`3f9a1c2e`), exactly as `mother list` shows it | Plan title, job title, branch name, file paths |
| Reason, from a fixed set: *asked a question* / *blocked after review* / *held after a failure* / *paused at its spend cap* / *pipeline blocked* / *needs you* (any other reason) | Dollar amounts |
| Repository name — **personal hosts only** | Repository name from a work host |

- Work host — **Title:** `Mother · kobe` **Body:** `Job 3f9a1c2e asked a question`
- Personal host — **Title:** `Mother · sendai · nostromo` **Body:** `Job 7c01d4aa is blocked after review`

**Decision request** — **(v1, amended 2026-11-23)** a decision only exists
while the verified Mac app is connected to answer it, so "nobody is
presenting it" can never be the trigger. Instead, a decision is pushed:

- **at once**, if the Mac showing it is locked, asleep, or has had no
  operator input for 2 minutes;
- **otherwise, 30 seconds after it was raised**, if it is still unanswered.

A decision answered at the Mac inside those 30 seconds never buzzes the
phone. If whether the Mac is locked or idle cannot be observed, the
30-second rule alone applies.

| May appear | Never appears |
|---|---|
| Kind ("Decision") | The decision prompt, its detail, or any fragment |
| Host name | Choice labels or choice details |
| Which agent is asking, from a fixed set: *Mother*, *Perri*, *Fred*, *Teri*, *Claudia*; any other session is *A session* | A dynamic session's own name (e.g. "Claudia in <project>") |
| Number of choices | Repository or project name, on any host |
| Time left before it times out, rounded down to the minute ("times out in 4 min"), when the decision has a timeout; **(v1)** with under a minute left, *times out in under 1 min* (never "0 min") | |

- **Title:** `Decision · kobe` **Body:** `Claudia is waiting on you · 3 choices · times out in 4 min`
- No timeout — **Title:** `Decision · sendai` **Body:** `A session is waiting on you · 2 choices`

A decision notification is a signal to go to the Mac. It never carries
answer buttons (see "Lock-screen actions on decisions", withdrawn).

**PR review requested** — sent when a PR enters the operator's review queue.

| May appear | Never appears |
|---|---|
| Kind ("Review") | PR title, description, labels, branch name |
| Host name | Author or any other person's name or handle |
| PR number (`#4821`) | Organisation or owner name |
| Size, from a fixed set: *small change* (under 50 changed lines) / *medium change* / *large change* (over 400) | CI log text, file paths |
| Number of PRs currently waiting on the operator from that host | Repository name from a work host |
| Repository name — **personal hosts only** | |

- Work host — **Title:** `Review · kobe` **Body:** `PR #4821 · small change · 3 waiting`
- Personal host, personal owner (illustrative only; cannot occur while the
  queue holds only Carefeed PRs) — **Title:** `Review · sendai · bishop`
  **Body:** `PR #212 · large change · 1 waiting`
- **(v1)** Size unknown (GitHub never returned the line counts during the
  grace delay): the size phrase is omitted, never guessed — `PR #4821 · 3 waiting`.

**Withdrawn item** — **(v1)** when an item stops needing the operator and its
notification cannot be silently removed (see "Answered elsewhere means
gone"), the notification is replaced in place, passively and without sound,
by `<Kind> · <host>` / `<ref> no longer needs you` (for example
`Mother · kobe` / `Job 3f9a1c2e no longer needs you`). *no longer needs you*
is part of the closed vocabulary.

**Summary** (coalesced burst, or the morning digest — see below).

| May appear | Never appears |
|---|---|
| Count of items, split by host | Anything per-item beyond what its own kind allows |
| Age of the oldest item, rounded ("oldest 14 h") | Repository names, even from personal hosts |

- **Title:** `Waiting for you` **Body:** `3 items · 2 on kobe, 1 on sendai · oldest 14 h`

If the operator later wants more text through the relay for a kind, that is a
new PRD revision, not a setting.

#### On-phone enrichment — **ambitious bet** (personal hosts only in v1)

When the phone can reach the operator's machines at the moment a notification
arrives (VPN up), a notification from a **personal** host is upgraded **on
the phone** with the real content, fetched directly from the operator's
machines and never via the relay: the first line of the worker's question,
or the PR title. This is the "useful" notification the brief describes,
without paying for it in relay or Apple exposure.

- **(v1)** Enrichment is **on** by default for personal hosts, with a
  per-host off switch on each device.
- **(v1) Work hosts are never enriched**, and neither are items from the PHI
  repositories on any host. The server never holds a Kobe question or PR
  title, so there is nothing the phone could fetch. A work host's row in the
  notification settings reads **"Details stay on kobe"**, with no toggle.
  This reverses the operator's 2026-10-10 answer that work-host enrichment
  should be opt-in (see the decision log). *(later, when opened up: a
  possible bet where the phone fetches one item's detail on demand through
  Kobe's own outbound connection, encrypted end to end so the server never
  holds it. Its own PRD and security review.)*
- **(v1) Decisions from a personal host are enriched read-only.** The
  notification shows the first line of the decision's prompt, ending
  `· answer on your Mac`, and offers no choice buttons. Seeing the question
  is what lets the operator decide whether to walk back to the Mac; the app
  already shows the same prompt read-only on tap. Decisions from a work host
  or a PHI repository show only the contract text.
- Enriched text never exceeds what that device is allowed to see in the app.
- If the content cannot be fetched within a few seconds, the notification
  shows the contract text unchanged. The operator never sees a spinner, a
  blank, or an error in a notification.

### On the lock screen

- **Previews are not force-hidden.** Contract text is safe by construction, so
  Nostromo follows the operator's iOS preview setting. The notification setup
  screen recommends "Show Previews: When Unlocked" while personal-host
  enrichment is on, and says why in one sentence (enriched text is real
  content on the lock screen).
- **Grouped by host.** Everything from kobe stacks together; everything from
  sendai stacks together. Work and personal never interleave in one stack.
- **The badge is the truth.** The app icon badge equals the number of items
  currently waiting on the operator across all hosts, and is updated with
  every notification and every time the app opens.
- **Answered elsewhere means gone.** When an item stops needing the operator
  — answered at the Mac, cancelled, timed out, resumed — its notification
  stops claiming it needs an answer, and the badge drops. **Ambitious bet:**
  this happens within 2 minutes while the phone has a network connection,
  without the operator opening the app. **(v1) This is the design:**
  - **Replace in place.** Within 2 minutes, the stale notification is
    **replaced** where it sits (same notification slot), passively and
    without sound, by `<Kind> · <host>` / `<ref> no longer needs you`, and
    the badge is corrected. A notification that honestly says "no longer
    needs you" keeps trust; one that is stale some of the time does not.
  - **Removal when the app opens or comes to the foreground.** Every
    notification whose item is no longer waiting, replaced or not, is
    removed then (the floor, below).
  - **Best-effort silent removal, where iOS allows it.** After the
    replacement has been sent, a silent update may also clear it from the
    lock screen. iOS rations these and never delivers them to an app the
    operator has force-quit, so this is a bonus, never the promise. The order
    is fixed: replace first, then optionally remove. A replacement must never
    arrive after a removal, because that would put back a notification for a
    resolved item.

  **(later, when opened up)** Silent removal with no "no longer needs you"
  line at all needs Apple's notification-filtering entitlement. That is an
  optional enhancement, pursued only if Apple's eligible categories ever
  truthfully fit Nostromo. It was investigated on 2026-11-23 and not
  requested (see the decision log).

  The floor, which is not a bet: the moment the app opens and connects, every
  stale notification, replaced or not, is removed.
- **No late arrivals.** A notification that could not reach the phone in time
  is never delivered late: a decision's notification expires at its timeout;
  all others expire after 4 hours. A dead item never buzzes the phone.
- **Urgency levels.** Decision requests are marked time-sensitive, so they can
  break through an iOS Focus if the operator allows Nostromo to. Mother and
  review notifications are ordinary and respect Focus.

### Tapping

Tapping opens the matching item in the app (already decided). With the VPN
off, the item screen says the operator's machines are unreachable and still
shows the kind, host and reference from the notification, so the operator
knows what they are waiting to see.

**(v1)** Every notification's only action is **Open**. Tapping a decision
shows it read-only with **"Answer it on your Mac"** (a personal-host
decision shows its prompt; a work-host decision shows its metadata). Tapping
a Kobe item shows its metadata and **"Details stay on kobe."** The phone
answers nothing in this version: no decisions, approvals, Mother questions
or PR actions.

### Lock-screen actions on decisions — **Withdrawn at sign-off (2026-11-23)**

*Withdrawn (sign-off S7, operator decision Q4).* Only the verified Mac app,
by a real click, may answer a decision. A stolen phone plus a VPN profile
must never become a way to approve an agent's action on a machine that holds
PHI repositories. The text below is the original bet, kept for the record;
none of it is v1, and none of it is a criterion. *(later, when opened up:
only through a device-trust PRD and its own security review.)*

A decision request is the one kind where acting from the lock screen matters:
it blocks a session and times out, and the operator is often in a meeting.
Long-pressing a decision notification offers its choices as buttons, labelled
with the real choice labels (fetched on the phone, as with enrichment, so the
labels never go through the relay). Choosing one requires the phone to be
unlocked (Face ID / passcode), answers the decision, and the notification is
replaced with a confirmation: `Answered: <choice>`. If the answer cannot be
delivered — VPN off, decision already resolved, timed out — the operator gets
an immediate local notification saying which, and nothing is retried silently.

When the choices cannot be fetched (VPN off), the only action is **Open**.
Mother questions and PR reviews get no lock-screen actions in this version;
tap-through is the experience.

### How often

- **One notification per item.** An item notifies once when it starts needing
  the operator. It does not re-notify on its own. (A Mother job that is
  answered and later asks again is a new item.)
- **Grace delay for things that can wait.** Mother and review notifications
  wait 2 minutes before sending; if the item is resolved in that time (the
  operator was at the desk and saw Mother's Mac notification), the phone never
  buzzes. **(v1)** Decisions follow their own timing (above): at once if the
  Mac is locked, asleep or idle, otherwise after 30 seconds if unanswered.
- **Bursts coalesce.** If more than 3 Mother or review notifications become
  due within 2 minutes, the operator gets one Summary instead, mirroring
  Mother's own coalescing. **(v1)** Decisions are never coalesced and never
  count toward the threshold: a Summary cannot carry a timeout, and a
  decision is the one kind where minutes matter.
- **Quiet hours.** Default 22:00–07:00 in the phone's local time, editable in
  the app. During quiet hours **nothing that alerts is pushed, of any kind.**
  Items that arise and resolve overnight never appear. Silent updates
  (removing or replacing a resolved notification, correcting the badge) make
  no sound, show nothing new, and still happen.
- **The morning digest replaces the daily reminder.** At the end of quiet
  hours, if anything is still waiting, the operator gets one Summary push.
  The phone does **not** mirror Mother's 24-hour and daily Mac reminders; the
  digest is the phone's daily reminder, timed for before the commute. If the
  operator turns quiet hours off, the digest still fires at the configured
  end time.
- **The evening summary** (operator answer, 2026-10-10). A second Summary at
  17:30 phone-local time by default, configurable per device, under the same
  rules as the morning one (count by host, oldest age, never a repository
  name). It is sent only if at least one enabled item is waiting, and is
  skipped if 17:30 falls inside the device's quiet hours.
- **(v1) Count-only signals.** A job whose progress has stalled, a spend pace
  running ahead of budget, and a PR whose checks are incomplete count toward
  the badge and the next Summary, but never push on their own. None of them
  is act-now.
- **(v1) Nothing from the message queue.** Messages waiting in a busy
  session's queue on a Mac never produce a notification.
- **Per-kind switches.** Each kind can be turned off per device. A kind that is
  off produces nothing, including in summaries.

### What the operator can see about what was sent

The app has a **Sent notifications** screen listing every notification
attempted for this device in the last 7 days: time, kind, host, the exact
title and body as sent, and the outcome — *delivered to Apple*, *rejected by
Apple*, *relay unreachable*, *held for quiet hours*, *coalesced into a
summary*, *withdrawn*, *skipped: resolved during grace delay*. This record is
kept on the operator's own machines, not in the relay, and is deleted after 7
days.

If notifications have not been deliverable for more than 15 minutes (relay
unreachable, or Apple rejecting this device), the app shows a banner whenever
it is open: `Notifications haven't been delivered since 2:14 pm`. If
notifications are turned off for Nostromo in iOS, the notification settings
screen says so and links to iOS Settings.

### Privacy note (paste-ready)

> Nostromo sends push notifications through a small relay that runs in a
> cloud account dedicated to it, owned personally by the operator and
> separate from any employer account. A notification contains only the kind
> of event, the name of the machine it came from, a short reference number,
> and fixed phrases such as "asked a question" or "times out in 4 min". It
> never contains questions, prompts, PR titles, people's names, mail
> subjects, or the names of work repositories; repository names appear only
> for machines the operator has marked personal, and never for repositories
> owned by the operator's employer. The relay passes each notification to
> Apple and does not store it. It keeps a delivery record — the time, the
> kind of event, whether Apple accepted it, and an anonymous device
> reference — for 7 days, then deletes it. Apple holds an undelivered
> notification for at most 4 hours (or until a decision's deadline). For
> machines the operator has marked personal, fuller details are fetched by
> the phone directly from the operator's own machines over their private VPN
> and are never sent through the relay. For work machines, no fuller details
> reach the phone at all.

### Where the relay runs (v1)

The relay runs in a **new AWS account used only for it**: either a dedicated
personal account or a member account in the operator's personal AWS
Organization. Never a Carefeed account, and never beside unrelated personal
workloads. The APNs signing key and the 7-day delivery records live there
and nowhere else, so they are easy to account for or delete.

## Acceptance criteria

Criteria amended at sign-off say **(amended 2026-11-23)**; criteria added at
sign-off say **(new 2026-11-23)**; withdrawn criteria are kept, marked
**Withdrawn**, and are not tests.

Payload contract (all observable at the boundary where a notification leaves
the operator's machines, and on the phone):

- For a Mother job on a **work** host whose question, title, plan, branch and
  repository each contain a unique marker string, the notification that leaves
  the operator's machines contains none of the markers, and its title and body
  match `Mother · <host>` / `Job <8-char ref> <reason phrase>` exactly.
- The same job on a **personal** host produces title `Mother · <host> · <repo>`
  and still contains none of the question, title, plan or branch markers.
- A host that has never been classified behaves exactly like a work host.
- Each Mother `awaiting` reason maps to its fixed phrase (*asked a question*,
  *blocked after review*, *held after a failure*, *paused at its spend cap*,
  *pipeline blocked*); an unrecognised reason produces *needs you*. A quota
  pause produces no notification.
- **(amended 2026-11-23)** A decision request whose prompt, detail, choice
  labels, choice details and session name each contain a marker produces a
  notification containing none of them; its body names the agent from the
  fixed set (or *A session*), the choice count, and, when a timeout exists,
  the minutes remaining rounded down, or *times out in under 1 min* when
  less than a minute remains (never "0 min").
- **(amended 2026-11-23)** A PR review request whose title, author, owner,
  branch and labels each contain a marker produces a notification containing
  none of them; it shows `#<number>`, the size phrase for the PR's
  changed-line count (49 → small, 50 → medium, 400 → medium, 401 → large),
  and the current waiting count for that host. The repository name appears
  only for a personal host **and** an owner not on the work-owners list
  (default Carefeed): a Carefeed-owned PR on a personal host shows no
  repository name.
- **(new 2026-11-23)** A review whose line counts are unknown when it comes
  due has the body `PR #<n> · <k> waiting`, with no size phrase.
- A Summary never contains a repository name, even when every item is from a
  personal host.
- **(amended 2026-11-23)** Every notification's title and body consist only
  of host names, repository names (personal hosts and non-work owners only),
  the reference/number/count/duration values, and the fixed phrases listed in
  this document, including *no longer needs you* and *times out in under 1
  min* — checked against the full vocabulary, not a deny-list.
- **(amended 2026-11-23)** Changing a host's classification, or the
  work-owners list, can only be done from the operator's machines; the phone
  shows both but offers no control to change them.

Lock screen and lifecycle:

- Notifications from different hosts appear in separate stacks; notifications
  from the same host stack together.
- After any notification arrives or the app opens, the badge equals the number
  of items currently waiting on the operator across all hosts.
- **(amended 2026-11-23)** When an item is resolved elsewhere, within 2
  minutes while the phone is online and without the app being opened, the
  badge is corrected and the notification stops claiming the item needs an
  answer — **ambitious bet**: a stale "needs an answer" on the lock screen is
  the fastest way to teach the operator to ignore the real ones.
  The notification is replaced in its own slot, with no sound and at the
  passive level, by `<Kind> · <host>` / `<ref> no longer needs you`,
  including when the app has been force-quit. It is never left unchanged.
  If a best-effort silent removal also happens, it happens only after the
  replacement, and no "no longer needs you" replacement ever appears after
  the notification was removed. (Test with the app force-quit as well as
  suspended.)
- **(amended 2026-11-23)** Opening the app, or bringing it to the
  foreground, removes every notification whose item is no longer waiting,
  including "no longer needs you" replacements, once the app reaches the
  operator's machines and before the operator can
  interact with the first screen.
- A phone that is offline for longer than 4 hours (or past a decision's
  timeout) does not receive that notification when it reconnects.
- Decision notifications are delivered at the time-sensitive interruption
  level; Mother and review notifications at the normal level.
- Tapping a notification with the VPN off opens a screen that shows the kind,
  host and reference from the notification and states that the operator's
  machines are unreachable — never an empty screen.
- **(new 2026-11-23)** Every notification offers **Open** as its only
  action. Tapping a decision shows it read-only with "Answer it on your Mac"
  and no control that answers it. Tapping a Kobe item shows its metadata and
  "Details stay on kobe."

Enrichment:

- With the VPN up and a personal-host Mother or review item, the displayed
  notification shows the real question / PR title within 5 seconds of
  arrival, while the notification that left the operator's machines still
  contains none of it — **ambitious bet**: this is what makes the
  notification worth reading without making it worth stealing.
- **(new 2026-11-23)** With the VPN up, a decision from a personal, non-PHI
  host displays the first line of its prompt, ending `· answer on your
  Mac`, within 5 seconds, and the displayed notification offers no choice
  actions.
- **(amended 2026-11-23)** With the VPN up, an item from a work host, or from
  a PHI repository on any host, always displays the contract text exactly.
  The notification settings show the work host as "Details stay on <host>"
  with no toggle.
- **(new 2026-11-23)** Turning enrichment off for a personal host on a device
  makes that host's notifications on that device display the contract text.
- With the VPN down, every notification displays the contract text exactly;
  no notification ever shows a placeholder, spinner text or error.
- **Withdrawn (S7):** long-press decision buttons with real labels and
  `Answered: <label>`; authentication before a lock-screen action; the local
  notification when a lock-screen answer cannot be delivered; "with the VPN
  down a decision offers only Open" (now true of every notification, above).

Frequency:

- **(amended 2026-11-23)** A decision request is delivered to a reachable
  phone within 10 seconds of being raised **when its Mac is locked, asleep,
  or has had no operator input for 2 minutes**, and otherwise between 30 and
  40 seconds after being raised if still unanswered. A decision answered at
  the Mac within 30 seconds produces no notification and a *skipped:
  resolved during grace delay* line in Sent notifications. (If the Mac's
  locked or idle state cannot be observed, only the 30–40 second rule is
  tested.)
- A Mother or review item is delivered between 2 minutes and 2 minutes 10
  seconds after it starts waiting; an item resolved within the first 2 minutes
  produces no notification and a *skipped: resolved during grace delay* line in
  Sent notifications.
- An item produces at most one notification over its whole life (excluding
  summaries and its own "no longer needs you" replacement).
- **(amended 2026-11-23)** Four or more Mother or review notifications
  becoming due within 2 minutes produce exactly one Summary push and no
  individual pushes. Decisions are never folded into a Summary and do not
  count toward the four.
- **(amended 2026-11-23)** No notification that alerts (sound, banner, new
  lock-screen entry) is delivered between the start and end of quiet hours;
  silent removals, replacements and badge corrections still happen. At the
  end of quiet hours exactly one Summary is delivered if, and only if, at
  least one enabled item is still waiting.
- **(new 2026-11-23)** An evening Summary is delivered at the device's
  configured time (default 17:30) if, and only if, at least one enabled item
  is waiting and that time is outside the device's quiet hours.
- No reminder is ever sent for an item 24 hours after it started waiting, other
  than through the morning and evening summaries.
- **(new 2026-11-23)** A stalled job, a spend pace ahead of budget, or a PR
  with incomplete checks never produces a notification of its own; each is
  counted in the badge and the next Summary.
- **(new 2026-11-23)** A message waiting in a busy session's queue on any
  Mac never produces a notification.
- With a kind turned off on a device, that device receives nothing for that
  kind, and summaries on that device do not count it.
- A device that is revoked receives no further notifications from 1 minute
  after revocation.

Visibility and retention:

- Sent notifications in the app lists, for each attempt in the last 7 days, the
  time, kind, host, exact title and body as sent, and one of the outcomes named
  above; entries older than 7 days are gone.
- With the relay unreachable for more than 15 minutes, the open app shows the
  "not delivered since <time>" banner; it clears after the next successful
  delivery.
- Every delivery record the operator can retrieve from the relay contains only
  time, kind, outcome and an anonymous device reference — no title, body, host
  name, job/PR reference or repository — and no record older than 7 days can be
  retrieved.
- With the relay unreachable, nothing is queued for later delivery; the item
  is visible in the app on next open, and Sent notifications records *relay
  unreachable*.

## In scope

- Three kinds: Mother awaiting, decision request, PR review requested; plus the
  Summary (burst coalescing, morning digest, evening summary).
- The closed-vocabulary payload contract above, the work/personal host
  classification and the work-owners list it depends on.
- Lock-screen grouping by host, badge, withdrawal of resolved items
  (replace-in-place, removal on app open or foreground, best-effort silent
  removal), expiry, interruption levels.
- On-phone enrichment for personal hosts (bet), including read-only decision
  prompts.
- Grace delay, decision timing, coalescing, quiet hours, morning and evening
  summaries, per-kind switches.
- Sent notifications screen, delivery-failure banner, the privacy note.
- iPhone and iPad, each as an independently configured device.

## Out of scope

- **Any worker-, agent- or third-party-authored text through the relay**, for
  any kind or host, including as an opt-in setting.
- **(v1) Answering anything from the phone**: decisions and permission
  requests (lock-screen buttons or in the app), Mother questions (including a
  text-reply action), PR approve / request-changes / merge, Mother enqueue.
  *(later, when opened up: only through a device-trust PRD.)*
- **(v1) Enrichment for work hosts or PHI repositories**, including as an
  opt-in. *(later, when opened up: possibly an end-to-end-encrypted
  on-demand fetch through Kobe's own connection, as its own PRD.)*
- **(v1) Any notification about the message queue.** *(later: a count is a
  cheap option in the app first.)*
- **Notifications for other events**: Mother jobs succeeding or failing,
  calendar events, budget posture changes, mail, approvals. Each is a
  candidate later kind with its own row in this contract (a count-only
  "approval needed" kind is the most natural next one).
- **Re-notifying an unanswered item** on a timer, including mirroring Mother's
  24-hour and daily Mac reminders.
- **Changing Mother's Mac notifications.** They keep working as they do today.
- **Live Activities and widgets.**
- **Overriding quiet hours** for urgent decisions.
- **Android or any non-Apple push.**
- **Routing notifications through Carefeed-owned infrastructure**, including
  hosting the relay in any Carefeed AWS account.

## Product risks

- **Too thin to act on, especially for Kobe.** "Job 3f9a1c2e asked a
  question" may not tell the operator enough to choose now-or-later on a
  work host, which is where most jobs run. In v1 Kobe items are never
  enriched, so this risk is accepted, not mitigated: expect to open the app
  more for Kobe items, and the app shows only metadata there too. Watch how
  often a work-host notification is opened within a minute; that is the
  evidence for or against the later on-demand-detail bet.
- **A decision push means "walk back or lose it".** With no answering from
  the phone, a decision raised while the operator is in a meeting is likely
  to time out unless they return to the Mac. The decision timing (at once
  when the Mac is idle) and the personal-host prompt line are there so the
  operator can judge quickly whether to go.
- **Misclassified host.** A personal host that ends up with a Carefeed
  checkout would leak that repository's name through a Mother notification,
  and its prompts and questions would be enriched on the phone (never sent
  through the relay). Defaulting unclassified hosts to work limits this to an
  explicit operator mistake. Keep Carefeed checkouts off Sendai, or classify
  Sendai as work.
- **Lock-screen exposure via enrichment.** Enriched personal-host text is on
  the phone's own screen. The setup screen recommends "When Unlocked"
  previews once; the operator owns the choice.
- **Silent quiet hours cost a decision.** A session that raises a decision at
  23:00 will time out unseen. Acceptable because overnight sessions should not
  be waiting on a human; if they routinely are, that is a signal about the
  session, not about quiet hours.
- **Trust erosion from stale notifications.** If withdrawal lags, the operator
  will answer something already answered, find nothing, and start ignoring
  pushes. This is why withdrawal is fought for rather than deferred, and why
  the design is an honest "no longer needs you", not best-effort removal.

## Open questions

Both answered by the operator on 2026-10-10. Answer 2 was partly reversed on
2026-11-23 (see the decision log).

1. ~~**Is the rhythm right?**~~ **Answered:** quiet hours 22:00–07:00 with
   the 07:00 digest fit the commute; add an evening summary at 17:30 (now in
   "How often").
2. ~~**Is Carefeed content allowed on a personal phone's screen at all?**~~
   **Answered 2026-10-10:** yes, with work-host enrichment opt-in.
   **Reversed 2026-11-23:** work hosts and PHI repositories are never
   enriched, and the phone answers nothing. Carefeed content stays off the
   phone's screen in v1 except as fixed-vocabulary metadata.

---

## Design-loop notes for Ada

**Signed off by Ada 2026-11-23.** Archie's turns below are kept as the record
of the loop. The sections above carry every agreed change; where a turn below
disagrees with them, the sections above win. The sign-off and the operator's
decisions follow the last turn.

**Author:** Archie (Phase 3, 2026-10-10). Ada's sections above were unchanged at the time.
Plans: `docs/plans/backplane/W13-push-relay.md` (daemon engine, relay, app
basics) and `docs/plans/backplane/W16-ios-push-enrichment.md` (Notification
Service Extension, enrichment, lock-screen decision actions, withdrawal on the
phone). Items marked **Sign-off** change or qualify an acceptance criterion and
wait for Ada. Items marked **Clarification** are how the plan reads the PRD;
Ada only needs to object if the reading is wrong.

### Operator answers to the open questions (2026-10-10, via the coordinator)

1. **Rhythm.** Quiet hours 22:00–07:00 with the 07:00 summary fit the commute.
   The operator also wants an **evening summary**, default **17:30** phone-local
   time, configurable per device, with the same fixed-vocabulary rules as the
   morning one (count by host, oldest age, never a repository name). It is sent
   only if at least one enabled item is waiting, and is skipped if 17:30 falls
   inside the device's quiet hours. Planned in W13.
2. **Carefeed content on the personal phone's screen is allowed.** Enrichment
   and lock-screen decision actions stay in scope for work hosts. Host-class
   gating stays as specified: repository names only for hosts marked personal;
   an unmarked host is work; enrichment is on by default for personal hosts and
   **opt-in per host, per device** for work hosts. Planned in W13 (classification)
   and W16 (enrichment and actions).

Ada: please move these into the Open questions section as answered.

### Flagged criteria: what the plan does

| AC | Decision | Where |
|---|---|---|
| Withdrawal within 2 min without opening the app | Planned, with one dependency on Apple (**Sign-off S1**) | W13 sends the withdrawal; W16 removes it on the phone |
| Enrichment within 5 s over the VPN | Planned as written | W16 (Notification Service Extension, 4 s internal budget) |
| Lock-screen decision actions in v1 | Planned as written, with one edge case (**Sign-off S4**) | W16 |
| Grace delay 2:00–2:10 with skip-if-resolved | Planned as written | W13 hold queue on the primary |
| PR size bucket | Planned. The data exists at no extra cost; one edge case (**Sign-off S3**) | W13 |
| Relay records with no host name | Planned, and stricter: the relay stores no device registry at all | W13 `infra/push-relay/` |
| Vocabulary allow-list test | Planned as written: a grammar check over the whole outbound request, not only title and body | W13 `src/push/vocab.rs` |

Evidence behind the table:

- **Withdrawal.** The badge can always be corrected without the app: a
  badge-only APNs alert push (`aps.badge`, no alert or sound) is applied by iOS
  itself. *Removing* a delivered notification needs code on the phone. There
  are two ways. (a) A background push (`content-available`, `apns-push-type:
  background`, priority 5) wakes the app to call
  `removeDeliveredNotifications`. iOS rations these pushes under its
  background-push budget and never delivers them to an app the user has
  force-quit, so this cannot carry a 2-minute promise. (b) A `mutable-content`
  alert push runs the Notification Service Extension. The extension runs even
  when the app has been force-quit and is not subject to that budget. It
  removes the stale notification and then hides itself. Hiding itself needs the
  `com.apple.developer.usernotifications.filtering` entitlement, which Apple
  grants on request. W16 builds (b) and the app tells the daemon per device
  whether it has the entitlement. W13 uses (a) plus the badge-only push until
  then.
- **Enrichment.** A Notification Service Extension gets about 30 s of wall
  time to modify a `mutable-content` push before display, and its network
  traffic uses the WireGuard tunnel when the tunnel is up. W16 caps its own
  fetch at 4 s, so the 5 s criterion holds. When the VPN is down, the contract
  text is shown after at most 4 s. Nothing intermediate is ever shown. The
  extension cannot bring the tunnel up itself; that depends on WireGuard
  on-demand rules.
- **Decision actions.** The extension fetches the choices and registers a
  per-notification `UNNotificationCategory` whose `UNNotificationAction`s carry
  the real labels and `.authenticationRequired` (Face ID or passcode before
  anything runs). It then sets the notification's `categoryIdentifier`. The
  action runs the app in the background, which sends `DecisionAnswer` over the
  WebSocket. W16 starts with a spike on device for the known race between
  registering a category and displaying the notification. The fallback is a
  Notification Content Extension that draws the buttons in the expanded view.
- **Grace delay.** The primary (Tokyo) is always on, polls Mother every 2 s
  (`src/bin/nostromd.rs:492`) and receives satellite frames over the uplink.
  A hold queue keyed on the item's start time plus 120 s, checked every
  second, dispatches between 2:00 and about 2:02. An item resolved during the
  delay is dropped and logged as *skipped: resolved during grace delay*.
- **PR size.** `PrQueueItem` (`src/data/perri_queue.rs:105-131`) and
  `PrListItem` (`src/ipc/protocol.rs:453-476`) have no line counts. However,
  every bucket-1/2 candidate already gets a `GET /repos/{r}/pulls/{n}` on each
  poll (`get_pr_head_sha`, `src/data/perri_queue_native.rs:1911-1929`), and
  GitHub's response carries `additions` and `deletions`. Deserialising those
  two fields (`PrDetail`, `:228-235`) costs no extra request. The targeted
  GraphQL probe (`src/data/perri_queue_targeted.rs:840-880`) can add the same
  two fields.
- **Allow-list.** Every phrase is a constant in one module. A grammar checker
  tokenises title and body on ` · ` and accepts only the PRD's productions
  (fixed phrases, `#<n>`, 8-hex refs, counts, durations, configured host
  names, and repository names for personal hosts). Tests drive marker strings
  through every kind, host class and reason, then check the entire JSON body
  sent to the relay, custom keys included.

### Sign-off needed

**S1. Withdrawal within 2 minutes depends on an Apple entitlement.**
> Withdrawal within 2 minutes without opening the app is met on any device
> running the W16 build with Apple's notification-filtering entitlement
> granted. Until that entitlement is granted (or if Apple declines): the badge
> is corrected within 2 minutes (badge-only push, reliable); removing the
> notification itself is best-effort via a background push (iOS rations these
> and does not deliver them to a force-quit app); and every stale notification
> is removed the moment the app opens and connects (the PRD's floor). If Apple
> declines the entitlement, the proposed fallback is to **replace** the stale
> notification in place (same APNs collapse id, passive interruption level, no
> sound) with `<Kind> · <host>` / `<ref> no longer needs you`. That adds one
> phrase to the vocabulary, *no longer needs you*.

**S2. Decisions are never coalesced into a Summary.**
> "Four or more notifications becoming due within 2 minutes produce exactly one
> Summary" applies to Mother and review items. Because both wait 2 minutes, an
> item's due time is known 2 minutes in advance, so the primary can count
> exactly. When the first item comes due, every other item due within the next
> 2 minutes is already known. Decision requests are always sent individually
> within 10 seconds and are not counted. They cannot be predicted, a Summary
> cannot carry their timeout or lock-screen choices, and the 10-second
> criterion would otherwise conflict with waiting to see whether three more
> arrive.

**S3. A review whose size is unknown omits the size phrase.**
> If GitHub has not returned the PR's line counts by the time the grace delay
> ends (both reads failed for the whole 2 minutes), the body is
> `PR #<n> · <k> waiting`, with the size phrase omitted rather than guessed.

**S4. A decision with more choices than iOS will show offers Open only.**
> iOS shows a limited number of notification actions. The legacy documented
> limit is four, and W16's spike measures it on the current iOS. A decision
> with more choices than can be shown offers only **Open**, never a partial
> set of buttons, because a partial set would silently bias the answer.

**S5. Repository names for reviews are also gated on the repository owner.**
> A review notification shows the repository name only if the host is
> personal **and** the repository's owner is not listed in the primary's
> `[push] work_owners` (default `["Carefeed"]`). The Perri queue searches only
> `org:Carefeed` on every host (`src/data/perri_queue_native.rs:989-990`), so
> a personal host running Perri would otherwise send Carefeed repository names
> through the relay. As a result, the PRD's example `Review · sendai · bishop`
> cannot occur until the queue covers personal orgs.

**S6. One new phrase for decisions about to time out.**
> When less than a minute remains, the body says `times out in under 1 min`
> instead of `times out in 0 min`.

### Clarifications (object only if the reading is wrong)

- **C1. "Starts waiting".** For a Mother job, this is Mother's own `paused_at`
  (falling back to when Nostromo first saw it awaiting). For a review, it is
  when Nostromo's queue first shows the PR in the *review requested* bucket:
  seconds after GitHub with the relay, or up to one poll interval (60 s
  default) without it.
- **C2. Which PRs count as "review requested".** Only the `requested` bucket
  (`review-requested:@me`). The queue's other buckets (`needs_review`, which is
  org-wide `review:required`, and `changes_req`) do not notify; they would
  break the handful-a-day budget. "N waiting" is the count of `requested` PRs
  on that host.
- **C3. "No operator client is presenting it".** A decision is pushed when,
  at the moment it is raised, no client that renders decisions is connected:
  no local Mac app on the originating host and no app connected to the
  primary. There is also a consequence for agents. Today `nostromo.ask_decision`
  fails immediately with `no_operator` when no client is connected
  (`src/mcp/tools/ask_decision.rs:84-89`). After W13, a paired device that can
  receive a decision push right now also counts as an operator for
  non-sensitive sessions (decision kind on, outside quiet hours). So the agent
  blocks until its timeout instead of failing at once. Without this there
  would be nothing to notify about.
- **C4. Quiet hours and withdrawals.** A withdrawal and a badge-only update
  make no sound and show nothing, so they still go out during quiet hours.
  "Nothing is pushed" is read as "nothing alerts".
- **C5. Opening the app removes stale notifications once the app reaches the
  primary.** With the VPN down the phone cannot know what was resolved, so
  nothing is removed until it connects. This matches the PRD's prose ("the
  moment the app opens and connects").
- **C6. Host names.** The name in a notification is the host's configured
  `host_name` (W10). Only names matching `^[a-z][a-z0-9-]{0,15}$` are sent;
  a host whose name does not match is labelled `host` in its notifications
  until renamed. W13's README tells the operator to set `host_name`
  explicitly, because the default comes from the OS hostname, which an MDM may
  have set to an asset tag or a person's name.
- **C7. Lock-screen labels on work hosts.** Per the PRD, decision buttons
  carry real labels on every host whose choices can be fetched. The per-host
  enrichment opt-in governs the notification *text* only. If Ada wants
  work-host button labels to follow the enrichment toggle too (Open only until
  opted in), that is a one-line change in W16.
- **C8. The relay holds no device registry.** The APNs token travels from the
  operator's machine with each push and is not stored. The relay keeps only
  the delivery record the privacy note describes, keyed by a random per-device
  push id, plus AWS Lambda's own platform log lines (request id and duration,
  no payload) with 7-day log retention. The privacy note is accurate as
  written.

### Turn 2 (Archie, 2026-10-18): reconciliation with main

S1–S6 above still await your sign-off. Two new deviations follow from code
merged since turn 1. Both narrow the PRD; neither can be planned around,
because each is a deliberate security rule, not a technical limit.

**S7. No lock-screen decision buttons; a phone is not an operator.**
> Main now enforces that only the verified Mac app, by a real human click,
> may answer a decision or a permission request (AP1/AP1b). A phone is not
> that app, and answering through the backplane would make the network a
> path to approve agent actions. So: a decision notification is still sent
> immediately and is still time-sensitive, but its only action is **Open**,
> which shows the decision read-only with "Answer it on your Mac". The
> "Lock-screen actions on decisions" section and its criteria are withdrawn.
> Clarification C3 is withdrawn too: a phone that can receive a push no
> longer makes an agent's question wait instead of failing at once; agents
> behave as they do today.
> Evidence: `src/ipc/peer.rs` refuses `DecisionAnswer` and `ApprovalAnswer`
> from every network peer; `src/ipc/server.rs` re-inspects the verified app
> at answer time; on the planned Linux server no app can ever be verified.

**S8. No enrichment for work hosts, PHI repositories or decisions.**
> Kobe holds Carefeed work and PHI repositories, so the plans make it a
> "work" host that sends only states, counts and short references to the
> server (bet B9). The server never holds a Kobe question or PR title, so the
> phone cannot fetch one. Items from the PHI repositories (`admin-portal`,
> `referral-monitor`) are reference-only from any host. Decisions are not
> enriched either (their prompt invites answering from the phone; see S7).
> So: enrichment is on by default for personal hosts, with a per-host off
> switch; work hosts always show contract text, and their setting reads
> "Details stay on kobe". This supersedes operator answer 2's work-host
> opt-in. If you want personal-host decision prompts shown read-only on the
> lock screen, it is a one-line change.

Also for information: a count-only "approval needed" notification kind is a
natural follow-up (the server already receives approval counts), but it is
not in this PRD and not planned.

### Turn 3 (Archie, 2026-11-23): status only

S1–S8 still await your sign-off; no new deviation. Two notes:

- **S4 is moot under S7.** With no lock-screen decision buttons there is no
  action limit to work around. Please sign S4 as withdrawn together with S7.
- **Apple's notification-filtering entitlement has not been requested yet.**
  S1's 2-minute withdrawal depends on it; until it is granted, the badge is
  corrected within 2 minutes and removing the notification is best effort.
  The operator step is in `docs/plans/backplane-sequencing.md`, open
  question 6.

Nothing merged on main since turn 2 adds a push source: the new authored-PR
list, Perri's verdicts, merge results, the tracker board and the message queue
all stay on the Mac that owns them and never reach the server.


---

## Sign-off and decision log

**Signed off by Ada 2026-11-23.** S1–S8 are signed below (S4 withdrawn with
S7; S7a is new). The operator answered Q3–Q6 of Ada's sign-off memo on
2026-11-23. He took the recommendation on every question and called v1 "a
conservative first step; things can open up later". All of it is written
into the sections above.

### Operator decisions

| Date | # | Decision (v1) | What it reverses or narrows | Later, when opened up |
|---|---|---|---|---|
| 2026-10-10 | OQ1 | Quiet hours 22:00–07:00, 07:00 digest; add a 17:30 evening summary. | Nothing. | — |
| 2026-10-10 | OQ2 | Carefeed content allowed on the phone's screen; work-host enrichment opt-in. | — | Reversed in part on 2026-11-23 (next row). |
| 2026-11-23 | Q3 | **Work hosts (Kobe) and PHI repositories are never enriched on the phone.** The setting reads "Details stay on kobe", with no toggle. | **Reverses the operator's 2026-10-10 answer 2** (work-host enrichment as a per-device opt-in) and the draft's opt-in criterion. | A possible end-to-end-encrypted on-demand fetch through Kobe's own connection, as its own PRD. |
| 2026-11-23 | Q4 | **The phone answers nothing in this sequence**: no decisions, approvals, Mother questions or PR actions. | Withdraws the "Lock-screen actions on decisions" bet (wanted in v1 by the draft) and narrows `docs/visions/iphone.md` and `docs/visions/ipad.md` (amended in the same change). | A device-trust PRD and security review. |
| 2026-11-23 | Q5 | **A Kobe notification says kind, host, short reference and a fixed reason** (or size and waiting count), exactly as the payload contract says. | Nothing; confirms the contract. | — |
| 2026-11-23 | Q6 | **The relay runs in a new, dedicated personal AWS account, or a member account in the operator's personal AWS Organization.** Never a Carefeed account. | Narrows "the operator's own cloud account" to a dedicated one. | — |
| 2026-11-23 | Q7 | **Nothing from the message queue**, in notifications or in the app. | Nothing (today's behaviour). | A count in the app, "2 messages waiting". |
| 2026-11-23 | S8 amendment | **Personal-host decisions show the first line of the prompt, read-only**, ending "· answer on your Mac". | The operator accepted this reversal of Archie's turn-2 proposal (no decision enrichment). | — |

### Apple's notification-filtering entitlement: investigated 2026-11-23, not requested

The operator opened Apple's request form for the Notification Service
Extension filtering entitlement on 2026-11-23. It requires the App Store URL
and numeric Apple ID of a published app, and a choice between four use cases
only: end-to-end encrypted messaging, earthquake warnings, education or
learning platforms retracting urgent alerts, and healthcare professionals'
patient-care alerts being retracted. Location-sharing apps are named as
ineligible. Nostromo is a personal operations tool, is not on the App Store,
and truthfully fits none of the four. **The request was not made**, and must
not be made by choosing a category that does not apply. So S1's
replace-in-place is the v1 design, not a fallback. The entitlement stays a
"later, when opened up" enhancement only if Apple's categories ever fit.

### Ada's sign-offs

- **S1, withdrawal: accepted, with a change.** Replace in place (same
  notification slot, passive, no sound) with `<ref> no longer needs you` is
  the primary design from day one. Removal on app open or foreground is the
  floor. Best-effort silent removal is allowed only after the replacement,
  never before. *no longer needs you* joins the vocabulary. Archie: if you
  have evidence that replacement is unreliable for a force-quit app, or that
  it lights the screen at the passive level, bring it back to Ada.
- **S2, decisions never coalesced: accepted;** decisions also don't count
  toward the threshold.
- **S3, unknown size omitted: accepted as written.**
- **S4, action limit: withdrawn** with S7.
- **S5, repository names also gated on owner: accepted,** plus: the
  work-owners list changes only on the operator's machines, and the phone
  shows it read-only. `Review · sendai · bishop` is illustrative only.
- **S6, "times out in under 1 min": accepted as written.**
- **S7, no lock-screen answers; a phone is not an operator: accepted**
  (operator Q4). C3 is withdrawn with it; agents behave as today.
- **S7a (new), when a decision is pushed:** at once if its Mac is locked,
  asleep or idle for 2 minutes; otherwise 30 seconds after it was raised if
  still unanswered (delivered by 40 s). Answered within 30 s means no push and
  a *skipped: resolved during grace delay* line. Archie decides whether
  "locked or idle" can be observed on both Macs; if not, the 30-second rule
  stands alone.
- **S8, no enrichment for work hosts and PHI repositories: accepted**
  (operator Q3). **Amended for decisions:** personal-host decisions show the
  prompt's first line read-only (operator accepted).
- **Clarifications:** C1, C2, C4, C5, C6 and C8 are accepted as read. C3 and
  C7 are withdrawn (no decision buttons exist). Plus a sign-off call not in
  S1–S8: progress-stalled, burn-ahead and gates-incomplete signals are
  count-only in v1.

### Code facts checked on `origin/main` (d191dd4d) for this sign-off

- A network peer cannot answer a decision or an approval
  (`src/ipc/peer.rs:1085-1086`), so the phone cannot be an operator.
- An agent's decision fails at once with `no_operator` unless the verified
  Mac app is connected (`src/mcp/tools/ask_decision.rs:89-90`). That is why
  S7a's trigger replaces "no operator client is presenting it".
- The Perri queue searches only `org:Carefeed`
  (`src/data/perri_queue_native.rs:1037-1039`; Archie's S5 note cites
  `:989-990`, which has since moved). That is why no review shows a
  repository name today.
- The message queue never reaches a network peer
  (`src/ipc/peer.rs:798-800`, `:1103-1105`).
