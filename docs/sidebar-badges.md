# Sidebar badges: blocking, waiting and the attention dot

A focus row in the sidebar can say three different things about the operator. They are different
on purpose: an agent that is **stopped until you act** must not look like a focus with a long to-do
list.

| Mark | Meaning | Where it comes from | Look |
|---|---|---|---|
| **Blocking** pill + row highlight | An agent is stopped until you decide. | A pending approval (`NeedsYouReason.approvalPending`). | Red pill with a hand glyph and the count, on the second line. The row gets a red-tinted fill and a 3 pt red bar on its leading edge. |
| **Waiting** pill | Nothing is stalled, but something wants you. | Tracker items marked needs-you (`trackerWaiting`, which includes un-run staged commands), Mother holds and awaiting jobs (`motherHold`, `motherAwaiting`, `motherAttention`) and anything else (`other`). | Quiet amber outlined pill with a list glyph and the count, on the second line. No row highlight. |
| **Attention dot** | An open decision (AskUserQuestion) is waiting. | `NeedsYouReason.decisionOpen`, via the attention registry. | Purple dot on the title line. Unchanged; open decisions are counted in neither pill. |

A focus with both shows both pills (blocking first), and still gets the highlight. Each kind of mark
is also shaped differently (hand vs list, filled vs outlined), so nothing relies on colour alone.

## Layout

- **Title line:** the focus name, its environment tags (`PRODUCTION`) and the attention dot. No
  "needs you" pill ever sits here. A built-in's own count (Fred's unread, Perri's queue) is the one
  exception: it keeps its place on the title line.
- **Second line:** a regular focus row shows only the blocking and the waiting pill here, right-aligned;
  there is no branch or last-message text. That text lives in the row's tooltip and its accessibility
  help (the visible accessibility label is unchanged). The line keeps its height with no pills
  (`Theme.navItemSubtitleHeight`, 52 pt, same as before), so a row never jumps when a pill appears or
  goes. A built-in's own subtitle (Fred, Mother, Teri, Perri's PR) stays on the left of the pills, and
  the pills take room from it only; the title and the row height never move.
- **Narrow rows give up, in order:** a built-in's subtitle (to nothing), then the waiting pill's padding
  and outline (glyph and count only). The blocking pill is never squeezed.
- **Highlight when the row is also the active focus:** the cornflower active bar stays at the edge and
  the red bar sits beside it, and the red fill replaces the cornflower tint. Active, blocked and both
  are three distinct looks (`NavRowHighlight.style`).

## Counts

`SidebarBadgeModel.needsYouCounts(from:)` splits the app-wide `NeedsYouSnapshot` per focus tag, using
`needsYouClass(of:)`, an exhaustive switch on `NeedsYouReason` (a new reason will not compile until
it is classified). Only items whose source is a focus count. `approvalPending(n)` counts as `n`; the
approvals producer raises one `approvalPending(1)` per request.

The pill shows the count up to 99 (`99+` after). VoiceOver reads `2 approvals blocking`,
`7 items waiting`, or `2 approvals blocking, 7 items waiting`; hovering a pill says what it counts.

## Clicks

- A **blocking** pill, on any focus, selects that focus (where the approval card is).
- A **waiting** pill on a built-in focus keeps the old deep link (Fred: inbox; Teri: todos); on any
  other focus it selects the focus.
- The **notification** for a pending approval, when clicked, brings the app forward, selects the
  focus that needs it and expands its card (`ApprovalNotifier.handleClick`, wired in
  `AppDelegate.userNotificationCenter(_:didReceive:)`). It never answers the request.

`nostromo-app approvals badges` reports `{tag, pill, waiting}` per row with a blocking pill (`pill` is
the blocking count, `waiting` the waiting count or null).

## Tracker (T5)

The tracker's "Waiting on you" items feed the **waiting** pill, never the blocking one: a tracker item
marked needs-you is a to-do, not a stalled agent. Producing or changing those items is not part of
the badges; see `docs/mcp/tracker.md`.
