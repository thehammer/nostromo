# Brief for Ada — Q2: what a Nostromo push notification may say

**From:** Archie (`docs/plans/backplane-sequencing.md`, question Q2)
**Unblocks:** W13 `push-relay` (`docs/plans/backplane/W13-push-relay.md`)
**Existing stub to replace:** `docs/prds/push-relay.md` (Archie-authored placeholder)

## Why now

With the daemon reachable from the phone, the app is current whenever it is
open. It is not open on a commute; iOS suspends it. The events that matter
most — a Mother job stuck waiting for an answer, a decision modal nobody is
at the keyboard for, a PR review request — are exactly the ones that happen
while the operator is away. The only way to reach a suspended app is Apple
Push, and Apple Push goes through a small hosted relay in the operator's
personal AWS account. That relay is the **first place the operator's data
leaves their own machines**, which makes "what text is in a notification" a
product and trust decision before it is an engineering one.

## Who and when

One operator, on a train or in a meeting, glancing at a lock screen. A
notification earns its interruption only if it tells them whether to act
*now* or *later* without opening the app. Expect a handful a day at most;
more than that and they will be silenced.

## What is already decided (not for re-litigation)

- Delivery is Apple Push via a relay the operator owns; the relay keeps no
  content, only delivery logs.
- Tapping a notification opens the matching item in the app, which fetches
  the detail over the VPN. If the VPN is off the app says so.
- Pushes are rate-limited per item (no repeats inside ten minutes) and per
  device.
- Kinds in the first cut: Mother job awaiting an answer, decision request,
  PR review requested. Each carries which *host* it came from (the laptop
  vs the home Mac).

## What Ada decides

1. **The payload contract.** What may appear in the title and the one-line
   body. The conservative default is *kind + host + id* ("Mother job on kobe
   needs an answer"). The useful version includes a fragment of the question
   or the PR title. Those fragments can contain customer names, mail
   subjects, or repo names, and they are stored by Apple and visible on a
   lock screen. Decide the line, per kind. This is the decision the whole
   wedge waits on.
2. **Lock-screen behaviour.** Preview hidden until unlocked? Grouped by
   host? Does a job that gets answered elsewhere withdraw its notification?
3. **Quiet rules.** Which kinds are allowed at night; whether an `awaiting`
   job re-notifies daily (Mother already reminds on the Mac every 24 h —
   should the phone?).
4. **Retention and visibility.** What the operator can see about what was
   sent (a log in the app? nothing?) and how long the relay keeps delivery
   records. Say it plainly enough to paste into a privacy note.
5. **Actionable notifications.** "Answer from the lock screen" is an
   **ambitious bet** worth deciding on now even if it ships later: does the
   first version need quick actions (Approve / Deny on a decision), or is
   tap-through enough?

## Constraints from the sequencing memo

- Nothing Carefeed-identifying may transit the relay unless you explicitly
  allow it per kind, and the first version is biased toward *no*.
- The notification must still be useful when the detail cannot be fetched
  (VPN off): the operator should know what kind of thing is waiting and on
  which host.

## Out of Ada's lane

APNs mechanics, AWS resources, token rotation, rate-limit implementation,
deep-link scheme — W13 internals.
