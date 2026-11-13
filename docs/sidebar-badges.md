# Sidebar badges: blocking, waiting, the attention dot and the activity mark

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

## Activity mark: something happened since you looked

A second, much quieter question: *has anything happened in this focus since I last looked at it?* It is
answered by one small mark at the **leading edge** of the row, left of the focus name, in a slot that is
reserved on every row (the name and the second line sit 10 pt further right than the bars alone would put
them, `NavTabItem.activitySlotWidth`). A mark appearing or going moves nothing: the row's height, the name's
frame and the pills are identical in every state. It never animates, never makes a sound, never notifies.

| Mark | Meaning | Shape and colour |
|---|---|---|
| none | Nothing new since you last looked. | (empty slot) |
| **Activity** | The agent completed turns, but wrote no message and had no problem. | Hollow ring, cornflower-grey (`Theme.focusMark`). |
| **Unread** | The agent wrote messages you have not seen. Hover: `N new messages`. | Filled dot, the same cornflower-grey. |
| **Problem** | Something went wrong: the session crashed or was stopped, a turn ended in an error, a message was held or could not be sent, a turn finished without a reply. Hover says which (from `last_problem`). | Filled quiet-amber dot with a "!" cut out (`Theme.focusMarkProblem`). |

Precedence: **Problem > Unread > Activity > none**. The shapes differ (ring, dot, dot with a mark), so the
state never rests on colour alone. The colours are not the red or amber of the pills, not the cornflower of
the active-focus highlight and not the purple decision dot, and every one is at least 3:1 against the row
fill in dark and light and in the selected and blocked states (pinned in `FocusActivityRowTests`). A focus
that also has a blocking or waiting pill shows its mark as well: they answer different questions.

VoiceOver: the row's label gains a phrase, composed after the badge's own (`2 approvals blocking, 7 items
waiting, 3 unread responses`): `unread response` / `N unread responses`, `activity since you last looked`,
or `problem: <what happened>`. A row with a mark and no badge reads `<name>, <phrase>`. The mark is not a
separate accessibility element. Built-in rows (Fred, Mother, Perri, Teri, Huey) get the same mark beside
their own badge.

### When a focus counts as seen

A focus is **seen** when it is the visible focus of a **key** window that is on screen. A window that is not
key, a minimised window, a window covered by others, and a hidden app do not count; a focus that is not the
one shown does not count. With several windows, a focus is seen while it is key and visible in any of them.

* At the moment a focus becomes seen its marks clear: what it holds is what you are looking at.
* While it stays seen, anything that arrives is absorbed too, so content that arrives while you look never
  flags. The same arrival while the window is not key (or the focus is not the one shown) does flag.
* **Baseline:** the first time the app sees a focus, or when the daemon's `activity_epoch` for it differs
  from the saved one (a daemon restart, a new Claude session id), the counters are taken as the baseline
  silently. Launching the app, restarting the daemon and rebuilding a session never light up every focus.
  A counter that went *down* within an epoch (it never should) is treated the same way.
* A daemon that sends no counters (older than `focus_activity_v1`) shows nothing.

What was last seen is saved per focus tag in `UserDefaults` under `nostromo.focus.activity.seen` (epoch and
the three counters; at most 200 tags, the least recently saved dropped first, which only means a later
silent baseline; a deleted focus's entry goes with it). It is the operator's own bookkeeping: no app-control
verb and no MCP tool reads or sets it, so an agent cannot mark itself seen (`FocusActivityWiringTests` scans
for it).

### How the counters get to the Mac

The daemon sends the counters (`agent_turns`, `agent_messages`, `agent_problems`, `activity_epoch`,
`last_problem` in `SessionInfo`) **only in reply to `session_list`**; it does not push when one changes. What it
does push is `session_state`. So the app asks again (`SessionListRefresher`, `AppStore`):

* when a `session_state` arrives that **changes** a tag's state (a turn started or finished), coalesced in a
  500 ms window, so a burst is one request;
* at once when a focus becomes seen, when the app comes forward and when the connection comes up;
* every 30 s as a backstop **only while at least one window is visible** (it catches what changes no state:
  a message in the middle of a turn, a problem). No timer runs while the app is hidden or every window is
  minimised; there is no tight polling.

Known limits (from the daemon side): assistant text that arrives with no turn open is not counted; counters
are not persisted by the daemon, so a restart is a new epoch (the app re-baselines); a late line from a killed
process could, rarely, add one count to a new epoch. A daemon push of the counters (instead of the request)
would remove the refresh timers; it is a candidate follow-up, not part of this slice.

## Layout

- **Title line:** the focus name, its environment tags (`PRODUCTION`) and the attention dot. No
  "needs you" pill ever sits here. A built-in's own count (Fred's unread, Perri's queue) is the one
  exception: it keeps its place on the title line.
- **Second line:** the branch text (or the built-in's subtitle) on the left, then the blocking and the
  waiting pill right-aligned. The pills take room from the branch text only; the title, the row height
  and the row's other contents never move when a pill appears, changes or goes.
- **Narrow rows give up, in order:** the branch text (to nothing), then the waiting pill's padding and
  outline (glyph and count only). The blocking pill is never squeezed.
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
