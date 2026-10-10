# PRD: Tell the operator what needs them, without telling anyone else

**Author:** Ada
**Status:** Draft (Ada, 2026-10-10)
**Answers:** Q2 in `docs/plans/backplane-sequencing.md`
**Unblocks wedge:** W13 `push-relay` (`docs/plans/backplane/W13-push-relay.md`)
**Surface:** iPhone (and iPad, same app) notifications; the operator's own machines; the hosted relay as seen from outside.

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
treated as **work**. The one fact that varies by class is the repository name:
it may appear for items from a personal host, never for items from a work
host.

The host appears as its operator-chosen name (`kobe`, `tokyo`). Host names are
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
- Personal host — **Title:** `Mother · tokyo · nostromo` **Body:** `Job 7c01d4aa is blocked after review`

**Decision request** — sent when an agent session raises a decision and no
operator client is presenting it.

| May appear | Never appears |
|---|---|
| Kind ("Decision") | The decision prompt, its detail, or any fragment |
| Host name | Choice labels or choice details |
| Which agent is asking, from a fixed set: *Mother*, *Perri*, *Fred*, *Teri*, *Claudia*; any other session is *A session* | A dynamic session's own name (e.g. "Claudia in <project>") |
| Number of choices | Repository or project name, on any host |
| Time left before it times out, rounded down to the minute ("times out in 4 min"), when the decision has a timeout | |

- **Title:** `Decision · kobe` **Body:** `Claudia is waiting on you · 3 choices · times out in 4 min`
- No timeout — **Title:** `Decision · tokyo` **Body:** `A session is waiting on you · 2 choices`

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
- Personal host — **Title:** `Review · sendai · bishop` **Body:** `PR #212 · large change · 1 waiting`

**Summary** (coalesced burst, or the morning digest — see below).

| May appear | Never appears |
|---|---|
| Count of items, split by host | Anything per-item beyond what its own kind allows |
| Age of the oldest item, rounded ("oldest 14 h") | Repository names, even from personal hosts |

- **Title:** `Waiting for you` **Body:** `3 items · 2 on kobe, 1 on tokyo · oldest 14 h`

If the operator later wants more text through the relay for a kind, that is a
new PRD revision, not a setting.

#### On-phone enrichment — **ambitious bet**

When the phone can reach the operator's machines at the moment a notification
arrives (VPN up), the notification is upgraded **on the phone** with the real
content, fetched directly from the operator's machines and never via the
relay: the first line of the worker's question, the decision prompt, the PR
title. This is the "useful" notification the brief describes, without paying
for it in relay or Apple exposure.

- Enrichment is **on** by default for personal hosts and **off** for work
  hosts. The operator can turn it on for a work host in the app's notification
  settings; that choice is per device.
- Enriched text never exceeds what that device is allowed to see in the app.
- If the content cannot be fetched within a few seconds, the notification
  shows the contract text unchanged. The operator never sees a spinner, a
  blank, or an error in a notification.

### On the lock screen

- **Previews are not force-hidden.** Contract text is safe by construction, so
  Nostromo follows the operator's iOS preview setting. The notification setup
  screen recommends "Show Previews: When Unlocked" for anyone who enables
  enrichment on a work host, and says why in one sentence.
- **Grouped by host.** Everything from kobe stacks together; everything from
  tokyo stacks together. Work and personal never interleave in one stack.
- **The badge is the truth.** The app icon badge equals the number of items
  currently waiting on the operator across all hosts, and is updated with
  every notification and every time the app opens.
- **Answered elsewhere means gone.** When an item stops needing the operator
  — answered at the Mac, answered on the iPad, cancelled, timed out, resumed —
  its notification disappears from the lock screen and Notification Center,
  and the badge drops. **Ambitious bet:** this happens within 2 minutes while
  the phone has a network connection, without the operator opening the app.
  The floor, which is not a bet: the moment the app opens and connects, every
  stale notification is removed.
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

### Lock-screen actions on decisions — **ambitious bet, wanted in the first version**

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
  buzzes. Decisions are sent immediately.
- **Bursts coalesce.** If more than 3 notifications become due within 2
  minutes, the operator gets one Summary instead, mirroring Mother's own
  coalescing.
- **Quiet hours.** Default 22:00–07:00 in the phone's local time, editable in
  the app. During quiet hours **nothing is pushed, of any kind.** Items that
  arise and resolve overnight never appear.
- **The morning digest replaces the daily reminder.** At the end of quiet
  hours, if anything is still waiting, the operator gets one Summary push.
  The phone does **not** mirror Mother's 24-hour and daily Mac reminders; the
  digest is the phone's daily reminder, timed for before the commute. If the
  operator turns quiet hours off, the digest still fires at the configured
  end time.
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

> Nostromo sends push notifications through a small relay that runs in the
> operator's own cloud account. A notification contains only the kind of event,
> the name of the machine it came from, a short reference number, and fixed
> phrases such as "asked a question" or "times out in 4 min". It never contains
> questions, prompts, PR titles, people's names, mail subjects, or the names of
> work repositories; repository names appear only for machines the operator has
> marked personal. The relay passes each notification to Apple and does not
> store it. It keeps a delivery record — the time, the kind of event, whether
> Apple accepted it, and an anonymous device reference — for 7 days, then
> deletes it. Apple holds an undelivered notification for at most 4 hours (or
> until a decision's deadline). Fuller details are fetched by the phone
> directly from the operator's own machines over their private VPN and are
> never sent through the relay.

## Acceptance criteria

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
- A decision request whose prompt, detail, choice labels, choice details and
  session name each contain a marker produces a notification containing none
  of them; its body names the agent from the fixed set (or *A session*), the
  choice count, and, when a timeout exists, the minutes remaining rounded down.
- A PR review request whose title, author, owner, branch and labels each
  contain a marker produces a notification containing none of them; it shows
  `#<number>`, the size phrase for the PR's changed-line count (49 → small,
  50 → medium, 400 → medium, 401 → large), and the current waiting count for
  that host. The repository name appears only for a personal host.
- A Summary never contains a repository name, even when every item is from a
  personal host.
- Every notification's title and body consist only of host names, repository
  names (personal hosts only), the reference/number/count/duration values, and
  the fixed phrases listed in this document — checked against the full
  vocabulary, not a deny-list.
- Changing a host's classification can only be done from the operator's
  machines; the phone shows it but offers no control to change it.

Lock screen and lifecycle:

- Notifications from different hosts appear in separate stacks; notifications
  from the same host stack together.
- After any notification arrives or the app opens, the badge equals the number
  of items currently waiting on the operator across all hosts.
- When an item is resolved elsewhere, its notification is removed and the
  badge decremented within 2 minutes while the phone is online, without the
  app being opened — **ambitious bet**: a stale "needs an answer" on the lock
  screen is the fastest way to teach the operator to ignore the real ones.
- Opening the app removes every notification whose item is no longer waiting,
  before the operator can interact with the first screen.
- A phone that is offline for longer than 4 hours (or past a decision's
  timeout) does not receive that notification when it reconnects.
- Decision notifications are delivered at the time-sensitive interruption
  level; Mother and review notifications at the normal level.
- Tapping a notification with the VPN off opens a screen that shows the kind,
  host and reference from the notification and states that the operator's
  machines are unreachable — never an empty screen.

Enrichment and actions:

- With the VPN up and a personal-host item, the displayed notification shows
  the real question / prompt / PR title within 5 seconds of arrival, while
  the notification that left the operator's machines still contains none of
  it — **ambitious bet**: this is what makes the notification worth reading
  without making it worth stealing.
- With the VPN up and a work-host item, the displayed notification is the
  contract text unless the operator has turned enrichment on for that host on
  that device.
- With the VPN down, every notification displays the contract text exactly;
  no notification ever shows a placeholder, spinner text or error.
- On an unlocked phone with the VPN up, long-pressing a decision notification
  shows one button per choice with the real labels; choosing one resolves the
  decision on the host (observable at the Mac: the modal closes as answered
  with that choice) and the notification changes to `Answered: <label>` —
  **ambitious bet, wanted in v1**: decisions time out while the operator is in
  a meeting, and tap-through-then-VPN-then-find-the-button loses them.
- Choosing a lock-screen action on a locked phone requires authentication
  before anything is sent.
- If a lock-screen answer cannot be delivered, a local notification within 10
  seconds says which of *unreachable*, *already resolved* or *timed out*
  happened; the decision is not answered later behind the operator's back.
- With the VPN down, a decision notification offers only **Open**.

Frequency:

- A decision request is delivered to a reachable phone within 10 seconds of
  being raised.
- A Mother or review item is delivered between 2 minutes and 2 minutes 10
  seconds after it starts waiting; an item resolved within the first 2 minutes
  produces no notification and a *skipped: resolved during grace delay* line in
  Sent notifications.
- An item produces at most one notification over its whole life (excluding
  summaries).
- Four or more notifications becoming due within 2 minutes produce exactly one
  Summary push and no individual pushes.
- No notification of any kind is delivered between the start and end of quiet
  hours. At the end of quiet hours exactly one Summary is delivered if, and
  only if, at least one enabled item is still waiting.
- No reminder is ever sent for an item 24 hours after it started waiting, other
  than through the morning digest.
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
  Summary (burst coalescing and morning digest).
- The closed-vocabulary payload contract above, and the work/personal host
  classification it depends on.
- Lock-screen grouping by host, badge, withdrawal of resolved items, expiry,
  interruption levels.
- On-phone enrichment (bet) and decision quick actions (bet).
- Grace delay, coalescing, quiet hours, morning digest, per-kind switches.
- Sent notifications screen, delivery-failure banner, the privacy note.
- iPhone and iPad, each as an independently configured device.

## Out of scope

- **Any worker-, agent- or third-party-authored text through the relay**, for
  any kind or host, including as an opt-in setting.
- **Answering a Mother question from the lock screen** (text-reply action).
  Mother answers are consequential free text; they get the app.
- **Approve / request-changes on a PR from the lock screen.**
- **Notifications for other events**: Mother jobs succeeding or failing,
  calendar events, budget posture changes, mail. Each is a candidate later
  kind with its own row in this contract.
- **Re-notifying an unanswered item** on a timer, including mirroring Mother's
  24-hour and daily Mac reminders.
- **Changing Mother's Mac notifications.** They keep working as they do today.
- **Live Activities and widgets.**
- **Overriding quiet hours** for urgent decisions.
- **Android or any non-Apple push.**
- **Routing notifications through Carefeed-owned infrastructure.**

## Product risks

- **Too thin to act on.** "Job 3f9a1c2e asked a question" may not tell the
  operator enough to choose now-or-later on a work host, which is where most
  jobs run. If they open the app for every one, the closed vocabulary has
  failed its purpose and enrichment becomes the product, not the bet. Watch
  how often a work-host notification is opened within a minute.
- **Misclassified host.** A personal host that ends up with a Carefeed
  checkout would leak that repository's name. Defaulting unclassified hosts to
  work limits this to an explicit operator mistake.
- **Lock-screen exposure via enrichment.** Enriched text is on the phone's own
  screen. If the operator turns enrichment on for kobe without "When Unlocked"
  previews, Carefeed content is readable on a table in a meeting. The setup
  screen warns once; the operator owns the choice.
- **Silent quiet hours cost a decision.** A session that raises a decision at
  23:00 will time out unseen. Acceptable because overnight sessions should not
  be waiting on a human; if they routinely are, that is a signal about the
  session, not about quiet hours.
- **Trust erosion from stale notifications.** If withdrawal lags, the operator
  will answer something already answered, find nothing, and start ignoring
  pushes. This is why withdrawal is fought for rather than deferred.
- **Lock-screen action on the wrong choice.** A button press in a pocket or a
  hurried tap answers an agent irrevocably. Requiring an unlocked phone and
  confirming in the notification is the mitigation; there is no undo.

## Open questions

1. **Is the rhythm right?** Quiet hours default to 22:00–07:00 with the digest
   at 07:00. Does that land before the morning train, and would an evening
   digest before the commute home also be wanted?
2. **Is Carefeed content allowed on a personal phone's screen at all?** This
   PRD keeps it out of the relay, but enrichment (off by default for kobe)
   would let it appear on the phone. If employer policy says no, enrichment
   and lock-screen choice labels for work hosts come out of scope, not into a
   setting.
