# Authored PRs: the daemon's list of my open pull requests

`nostromd` keeps every open PR the GitHub token's user wrote, across every repo
the token can read, works out which focus owns each one, and publishes it to the
Mac on a local-only, opt-in wire topic. Slice 1 of 3 (the Mac tab is slice 2).
Code: `src/data/authored_prs/`.

Off switch: `authored_prs = false` in `config.toml` (no feature advertised, no
task, no relay interest).

## Sources

- **Carefeed (the relay's org):** live from the github relay. `pr.closed` and
  `pr.merged` of a known PR cost nothing. Other PR events for a known PR (or a
  `pr.opened` whose author hint is me) cost one GraphQL read, coalesced over 2 s.
  A `ci.completed` whose `repo` and `head_sha` match a known PR's in-memory head
  costs one read. The relay never triggers a search or a full reconcile. After a
  reconnect (`Reconnected`) one full reconcile runs; `relay` is `catching_up`
  until it succeeds, then `live`. The relay sends no comment, draft or
  thread-resolution events, so those are only seen by the poll.
- **Everything else:** polled. Discovery is
  `GET /search/issues?q=is:pr+is:open+author:@me+archived:false&sort=updated&order=desc&per_page=100`
  with an ETag (a 304 reuses the list). Detail is one GraphQL request per 20 PRs
  (`AuthoredPrDetail`). The query never asks for a `body`, `bodyText`, `bodyHTML`
  or a check's `output`, `summary` or `text`: the daemon never holds comment or
  check text.
- `GET /user` once per token (charged 1). `X-GitHub-SSO: partial-results` org ids
  are named with `GET /organizations/{id}` (at most 5 a day, once each) and
  published as `hidden_orgs`.

## Demand, postures and cadences

Who is looking comes from the Mac: `authored_prs_demand {level: visible|hidden|idle}`,
honoured only from the verified operator app (refused for TCP peers). The demand
is the highest level over live operator connections; **with none it is idle and
the feature makes no request**. An older Mac never sends the verb. Leaving idle
costs exactly one full reconcile. `authored_prs_refresh {}` asks for one now; it is
refused (and the snapshot says `refresh_blocked`) while one runs or while paused.

| Posture | Search | Pending-CI refresh | Full reconcile | Polling cap (charged/h) | Relay-read cap |
|---|---|---|---|---|---|
| visible | 60 s | 60 s | 10 min, and on entry | 120 | 60 |
| hidden | 5 min | 5 min | 30 min, and on entry | 20 | 20 |
| idle | none | none | none | 0 | 0 |
| paused | none until `resumes_at` | none | one on resume | 0 | 0 |

- Pending-CI refresh covers non-relay PRs with pending checks (and relay-org PRs
  while the relay is down or catching up).
- Caps are rolling one-hour token buckets of **charged** requests: a 304 is not
  charged; every GraphQL call is. Search has its own limit of one per 60 s in every
  posture. When a bucket is empty the work waits, and `checked_at` ages.
- GitHub's headers lower the posture: under 20% remaining on `core`, `search` or
  `graphql`, visible acts as hidden (`poll: rate_limited`); under 5%, or on a
  `Retry-After` (capped at 1 h) or secondary limit, `paused` until the reset.
- Errors: 5xx, timeout and transport errors back off 2, 4, 8 ... 30 min (`retry_at`).
  A 401 sets `token: rejected` and stops for 30 min; a change of demand retries
  sooner, but at most once per 5 min (each retry is an uncharged 401).
  No token: `token: missing`, no requests; while someone watches it is looked for
  again at most every 5 min, so a token that appears later needs no restart.
  The token is found in this order: `GITHUB_TOKEN`, `GH_TOKEN`, `oauth_token` in
  `~/.config/gh/hosts.yml`, then `gh auth token --hostname github.com` (modern
  `gh` keeps the token in the macOS keychain, so `hosts.yml` has none). `gh` is
  found by absolute path only, never `PATH`: `$NOSTROMO_GH_CLI`, then
  `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, `/usr/bin/gh`. It runs with a fixed
  argv, no stdin, stderr discarded, a cleared environment (`HOME`, `USER`,
  `GH_CONFIG_DIR`, `XDG_CONFIG_HOME` only), a 5 s timeout and a capped stdout; its
  answer must be one printable-ASCII word. A token from `gh` is cached 5 min and a
  failure 30 s, so it runs at most about twice a minute. Neither is logged.
- A secondary limit is `paused` too: a 403 or 429 without `Retry-After` and with
  `remaining` above 0 pauses for a minute, as does a GraphQL 200 whose
  `errors[].type` is `RATE_LIMITED`. A pause from a header's reset time is capped at
  1 h from now. Wall time is the real clock, so it stays true across Mac sleep.
- Usage counters (`usage` in the snapshot, and an **info** log line, first about a
  minute after start and then hourly:
  `authored-prs usage: charged=N not_modified=N search=N graphql_points=N relay=N posture=...`;
  counts only)
  count this feature's own requests only. Every request carries
  `User-Agent: nostromd authored-prs`.

## Ownership

A PR's owner is, in order: a Mother job whose PR is this one and whose origin is a
focus the daemon vouches for (`mother_job`); a link the user made from the picker (`linked`); an open focus whose working copy is on the PR's repo and head branch
(`on_branch`). Two plausible owners are `ambiguous`; a vanished owner is `closed`;
no evidence is `unknown`. Unverified, You and Unknown origins are never owners.

A focus's working copy is read from files, never with git (no hook, no fsmonitor,
no process): the last `cwd` in the last 64 KiB of its Claude transcript
(`~/.claude/projects/*/<session-id>.jsonl`), falling back to the spawn cwd and the
registry's project path; then `.git` (a directory, or a `gitdir:` file with
`commondir` for a linked worktree) for `HEAD` and `[remote "origin"] url`.
At most every 30 s per focus, 64 focuses, and only while an open PR lacks a Mother owner.

Limits: a session that works in another checkout with `git -C` or absolute paths
without `cd` is not seen; two focuses on one checkout and branch are ambiguous; the
result is always labelled `on_branch`, never stated as fact. A PR from a fork never
matches `on_branch` (its head branch is in another repo). Every `.git` file is read
bounded (256 KiB), regular files only, a final symlink not followed, on a blocking
thread. Ambiguous candidates say which of them is `closed`.

## Telling a focus about a PR (`authored_prs_notify_v1`)

One explicit click opens a preview of a message the **daemon** composes from structured facts only
(`notice.rs`): the repo, number and rebuilt URL, failing check names (one sanitised line each, at most 10, then
`and N more`), change-requesting logins (validated), the new-comment and unresolved-thread counts and fixed
sentences. The facts type has no title, body, comment or check-output field, so none can be sent. The Mac shows
the text verbatim and echoes its SHA-256 digest; the daemon recomposes at send time and answers `changed` when
the facts moved (the Mac previews again, never sends stale text).

Send writes the text as the operator's own message through the session manager's normal send: it queues behind
a running turn and never interrupts it. A dead session is restarted first (`ensure_session`); a failure answers
`not_running` and records nothing. Start a session creates a focus **without an instruction** (the create path
would wrap one in its own framing) and sends the text through the same send, so the first message is
byte-identical to the preview; the PR is then linked to the new focus.

All four verbs (`authored_pr_preview_request`, `authored_pr_notify`, `authored_pr_start_session`,
`authored_pr_link`) are honoured only from the verified operator app; a plain local client gets
`not_operator_app`, a TCP peer `requires_secure_connection`, and the refusal is logged as verb + code only. The
Mac passes each through `HumanGesture.permit` first.

Persisted: `<state_root>/authored-pr-links.json` (0600; `owner/name#number` → `link {tag, at}`, `told {tag, at,
attention_key}`; at most 500, dropped when the PR ends or after 30 days unseen) and `focus-memory.json`
(`tag → {agent_name, project_path, name, last_seen}`, at most 200, 90 days) so a closed owner's agent can be
offered again. No title, branch, check or comment data is stored or logged. The snapshot gains `told` and `pill`;
`pill` is true when a needs-you, non-draft PR has a known open owner that has not been told its current
`attention_key` (a hash of the failing checks, change requesters, newest new-comment time and unresolved count).

## Perri's verdict and the Merge verb (`authored_prs_perri_v1`, `authored_prs_merge_v1`)

The user's rule: a PR may be merged only when a human reviewer approved it on GitHub, the required checks are
green **and** Perri (the local review agent) approved the PR's **current head commit**. Perri's verdict used to
live only in the conversation; it is now a record.

**The verdict store** (`verdicts.rs`). `<state_root>/perri-verdicts.json`, mode 0600, written atomically
(temp file + rename). One record per `repo + number + head_sha` (the full 40-hex head): `verdict`
(`approved` | `changes_requested` | `comment`), `at`, `by` (the recording agent and focus, at most 80 chars) and
an optional plain-text `note` (at most 200 chars; control and invisible/format characters (Unicode `Cf`: bidi
overrides and isolates, zero-width characters, marks) are dropped from `by` and `note` before the cut; never markup,
never on the board row, never logged). The newest verdict for a head wins; when it replaces a *different* verdict
for the same head, that one's verdict, `by` and `at` are kept one level deep as `replaced` (so the Mac can later say
"approved by X, previously changes requested by Y"; not on the wire yet, the row shows only the newest). The newest
500 records are kept. The file is read
leniently: unknown fields are ignored, a record that does not validate (bad repo, number, SHA or verdict) is
dropped, and a file that does not parse starts the store empty (its bytes are kept as a backup) and is not fatal.

**Recording** is the MCP tool `perri.record_verdict` (see `docs/mcp/tools.md`). It only records. Any session of
a **registered** focus may call it (a tag that matches no focus is `unidentified_caller`); a session a network peer
is steering is refused (the tool is withheld, like the Teri/Fred/Mother/Huey tools). An `approved` is only taken
for the PR's **live** head: the daemon reads the PR from GitHub once, at the time of the call (the same one-shot
read the Merge verb makes, with the same rate-limit pause), and never decides from its list, whose poller sleeps
while no Overview is showing and so can hold a head several pushes old. A head that differs is refused
`head_not_current`, a PR GitHub does not have `pr_unknown`, and an approval that could not be verified (the read
failed, GitHub is rate-limiting, no token) `unreachable` or `rate_limited`, with nothing recorded: an approval that
was not checked is never taken. A PR the daemon has never listed is checked the same way. A `changes_requested` or
`comment` can only block, so it is taken for any head without a read. The result says
`for_current_head: true | false` (for an approval, from that live read; for the others, best-effort from the
daemon's list, which is repaired when the Overview opens and the poller wakes). After recording, the engine is
told so the row shows the verdict when the poller is active.

*Trust model.* The caller's tag is self-declared: the record shows **who** (`by`, `<agent>:<tag>`), it does not prove
who. A local process on the user's account can still claim a registered tag. The real gates of a merge are the
user's own click, GitHub's `CLEAN` state and branch protection; the record is one more input, not a credential.

**Row fields** (additive, absent when empty, so an older Mac decodes the frame unchanged): `head_sha_short` (the
first 8 hex digits of the engine's in-memory head; the full SHA never leaves the daemon) and
`perri { verdict, at, by?, for_current_head }`. A verdict for the current head sets `for_current_head: true`;
when only an older head has a verdict it is reported with `for_current_head: false` (the app says "approved an
older version"): a push makes the old verdict stale, never approved. The note is not on the row.

**The Merge verb** (`authored_pr_merge {request_id, repo, number, expected_head_sha_short}` answered by
`authored_pr_merge_result`, the verified operator app only, like the hand-off verbs; a plain local client gets
`not_permitted`, a TCP peer `requires_secure_connection`, each logged as verb + code only). The Mac sends it
after a human gesture; the daemon cannot see that, so it enforces every rule itself, in this order, and each
failure has its own code:

1. The PR is in the daemon's list (`not_found`), and the engine is not paused on a rate limit (`rate_limited`).
2. The PR is **read from GitHub now** (one GraphQL read, never the cached row): `not_open`, `draft`,
   `not_mergeable` (`mergeable` is not `MERGEABLE`), `not_approved` (the review state is not approved, or no
   *human* approved: a bot's approval does not count), `checks_not_green` (not passing or none), and then GitHub's
   own `mergeStateStatus` has the last word: `CLEAN` or `HAS_HOOKS` pass; `BEHIND` is `behind`, `BLOCKED` is
   `blocked`, `UNSTABLE` is `checks_not_green`, `DIRTY`/`UNKNOWN` are `not_mergeable`.
3. The live head's first 8 hex digits must equal `expected_head_sha_short` (`head_changed`), and a stored Perri
   verdict `approved` must exist for the **full** live head: `perri_not_approved` when there is none, or it is a
   changes-requested or comment verdict; `perri_stale` when verdicts exist only for other heads.
4. `PUT /repos/{repo}/pulls/{number}/merge` with exactly `{"merge_method":"squash","sha":"<full live head>"}`,
   with the engine's own GitHub client and token. `sha` makes GitHub itself refuse if the head moved after the
   checks above. There is never an admin or bypass parameter: branch protection always applies (an admin merge
   is a separate, later feature). 405 is `blocked`, 409 `head_changed`, 403 `token_cannot_merge` (a 403 that
   carries a rate-limit signal is `rate_limited`), 404 `not_found`, 422 `not_mergeable`, 429 `rate_limited`, a
   network failure or any other status `unreachable`.

Nothing GitHub says (a message, a title) is forwarded to the client or logged: the answer is `ok` or a code.
One `request_id` gets one answer for the PR it named (a repeat returns the first, whatever it was, so a transient
`rate_limited` or `unreachable` is remembered too and a new press needs a new id; the same id naming another PR is
a new request), and a request for a PR whose merge is still running is refused `busy`, including a repeat of the
running request's own id (`busy` is not remembered, so retrying after it finishes returns the first answer). On success the daemon logs one line (repo,
number, short head, who asked; no token, title or body), a refused attempt logs one too (the same plus the code), and it asks the engine to read that PR again, so the row
turns merged without waiting for the next poll. The codes: `ok`, `not_found`, `not_open`, `draft`,
`not_approved`, `checks_not_green`, `not_mergeable`, `blocked`, `behind`, `head_changed`, `perri_not_approved`,
`perri_stale`, `token_cannot_merge`, `rate_limited`, `unreachable`, `busy`, `not_permitted`, and for the queue `queued`, `already_queued`, `queue_refused`, `queue_unknown`, `via_changed`.

Not verified by tests, because it needs the real thing: a merge on a real PR, and whether a real token's scope
allows merging.

**In the Mac app** (slice C). Rows show Perri's verdict and, in the READY group, a Merge button. Nothing appears
without the matching feature: the badge needs `authored_prs_perri_v1`, the button needs that and
`authored_prs_merge_v1` (an older daemon gets no half-working control).

- **Badge** on every open row that has a worth-showing verdict: `Perri ✓` (approved, for the current head),
  `Perri ✓ older` (approved an earlier head: muted, and a new push needs a new review), `Perri ✗` (changes
  requested), `Perri comments`. No verdict, an unknown one, or a non-approval of an older head: no badge. The
  tooltip says when, by whom and the head; VoiceOver says "Perri approved this version" and so on. Any registered
  focus can record a verdict, so when the recorder (the agent part of `by`, `<agent>:<tag>`) is not `perri` the
  badge reads `Perri ✓ (by cody)`, VoiceOver says "Approval of this version recorded by cody, not by Perri", and
  an absent or unparseable `by` (or one the decoder had to clean) reads `(recorder unknown)`. The agent name must
  be ASCII `[A-Za-z0-9._-]`, at most 40 characters, so a hidden character inside "perri" cannot pass as Perri.
- **Button** on open READY rows. Enabled only when `mergeReadiness` is `.ready`: a human approved, checks are
  green (or there are none) and Perri approved the head the row shows. Otherwise it is shown off with the first
  reason (`Draft`, `Checks not green`, `Waiting for human approval`, `Needs Perri's review`, `Perri approved an
  older version`, `Perri requested changes`) in its tooltip, its VoiceOver label and at the end of the row's
  review line.
- **Press** is a human gesture (`HumanGesture.permit`, like the hand-off buttons): a synthesised or Accessibility
  press opens nothing and sends nothing, and the row says `Merge was refused: use the button` (VoiceOver can leave
  a stale event behind the Merge action; the gate is not weakened). A refusal never overwrites the daemon's reason
  for the last failure at that head, and a person's press clears the note. A person's press opens a one-step
  confirmation: `Squash and merge #458 <title> into <base>? Head 0123abcd. Perri approved. Human approval: yes.
  Checks: green.` (title cleaned and capped at 80 characters). When the approval was recorded by anyone but Perri
  the sentence says `Approval recorded by cody:focus-x, not by Perri.` (or `Approval recorder unknown, not
  confirmed as Perri.`). Cancel is the default button (Return cancels), Merge has no key equivalent and is
  gesture-checked again, Escape cancels. The confirmation is cancelled when a snapshot changes that row's head,
  base or the approval sentence, or makes it not ready. The merger is shared by every Overview (one per Mother
  window): only the Overview that opened the confirmation may cancel it for a row it no longer shows (another
  filter, "Show more", a window just opened say nothing about it); if that Overview is gone, any window may.
- **Confirm** sends one `authored_pr_merge` carrying the head short sha **of the row the person pressed on**,
  never a newer snapshot's. The row says `Merging…` (a second press opens nothing), then `Merged` or a notice in
  place of its owner line with a dismiss button. The row never regroups on the strength of our own request; only
  the next snapshot moves it. A notice is the words of the daemon's code (an unknown code is a generic `The merge
  failed`, never success) and stays until dismissed, the row's head changes (not for `head_changed`, which is
  about exactly that), a new attempt starts or the PR is no longer open.
- No new key equivalents; the context menu has no Merge item; Return on a row never merges. VoiceOver gets a
  `Merge` custom action only while the button is enabled, and `Dismiss merge message` while a notice shows.
- There is no admin merge and no hidden path to one: the transport has the one verb and the one request shape.

## The merge queue (`authored_prs_merge_queue_v1`)

`Carefeed/admin-portal` requires a merge queue on its base branch, and GitHub refuses a direct merge there (405,
`blocked`). The Merge button therefore enqueues where GitHub says a queue exists, and merges directly where it does
not (`Carefeed/referral-monitor`). The daemon never reads this from a repo list: it comes from GitHub, on every
read.

**Detection.** Whether a queue exists is a property of the PR's **base branch**, so the daemon reads that.
The poll's detail query and the merge's own live read both ask `PullRequest { id isInMergeQueue mergeQueue { id }
mergeQueueEntry { state position } repository { defaultBranchRef { name } mergeQueue { id } } }`, and, for an open
PR whose base is not the default branch, one more request per batch: `repository { mergeQueue(branch: <base>) { id } }`
(the branch goes in as a GraphQL variable, never into the query text). Field names are checked against GitHub's GraphQL
schema; the user's `gh` token can read them. Two reads are kept apart:

- the **base branch's queue** (the authority): `repository.mergeQueue` (the default branch) when the base is the
  default branch, `mergeQueue(branch: <base>)` otherwise;
- the **PR's own `mergeQueue` field**, which is NOT the base branch's queue. Read on `Carefeed/admin-portal` on
  2026-11-21: #6423 (base `merge/f2c-family-session-facility`) and #6420 (base `merge/f2b-family-route-middleware`)
  both answer that field with `main`'s queue, while `mergeQueue(branch:)` for those branches is `null` and
  `GET /rules/branches/<branch>` is `[]` (`main` lists `merge_queue`). A `feature/` base (#6414) is `null` on both.

Each read has three states: a queue, no queue (`null`), and **unreadable** (the key missing from the answer, or
`null` beside a GraphQL error for it, or the second request failing). What each combination does:

| base branch's queue | PR's own field | row `merge_via` | the Merge verb |
|---|---|---|---|
| queue | queue | `queue` | enqueues |
| none | none | `direct` | merges directly |
| none | queue | `direct` | merges directly, never enqueues (a stacked PR on `merge/*`: GitHub's field is `main`'s queue) |
| queue | none | omitted | refuses `queue_unknown`, sends nothing |
| unreadable | any | omitted | refuses `queue_unknown`, sends nothing |
| any | unreadable | omitted | refuses `queue_unknown`, sends nothing |

Unknown is never guessed, and never falls back to a direct merge or to an enqueue. The merge also compares the live
base branch with the row's `base_ref` (the displayed form: absent for the default branch, cut at 100 characters);
if they differ the verb answers `via_changed` and sends nothing. A retarget the displayed form cannot tell apart
(for example `main` to a default branch that is not `main`, with the row showing neither) is not caught by that
comparison; the live queue read and `expected_via` still decide queue versus direct from fresh data.

Known limits: a rate limit on the second (base-branch) request is not passed to the poll's budget (the PR then has
no `merge_via` and the verb says `queue_unknown`), and a GraphQL error with no `path` is not tied to a queue read.
Both fail closed (nothing is enqueued).

**Enqueue.** After every gate of the direct path (human approval, not draft, `mergeable`, checks, GitHub's
`mergeStateStatus` clean, the head the app showed, Perri approved the **full** live head) the daemon sends
`enqueuePullRequest(input: { pullRequestId, expectedHeadOid })` (variables `pr` and `head`) and nothing else. There
is no `jump` (that would skip the queue: a bypass) and no admin input; the REST merge is never called on this path
and the enqueue is never called on the direct path. `expectedHeadOid` keeps the head pin the REST `sha` gave.

**`mergeStateStatus` on a queue repo.** Read on `Carefeed/admin-portal` on 2026-11-21: approved PRs with passing
checks report `CLEAN` (5 of 60 open PRs; 8 more `CLEAN` with no review decision), others `BLOCKED`, `DIRTY` or a
transient `UNKNOWN` (which the verb refuses `not_mergeable`; retry a moment later). `HAS_HOOKS` was not seen;
it stays accepted. No PR was in the queue at the time, so a queued PR's own `mergeStateStatus` is unobserved: a
PR already in the queue answers `already_queued` before that gate.

**The way in must match what the person was told.** The request may carry `expected_via` (`direct` or `queue`;
absent means `direct`, which is what an app that does not know queues says). If GitHub says another way now the
daemon sends nothing and answers `via_changed`. So an older Mac pressing Merge on a queue repo gets `via_changed`,
never a surprise enqueue.

**Answers.** Success `queued` is `{"status":"ok","value":{"code":"queued"}}` (merged now stays `{}`; any other success code is not understood by the app, which shows "Unexpected answer: check GitHub", never "Merged"). New refusal
codes: `already_queued` (the PR is in the queue; nothing sent), `queue_refused` (GitHub declined: not ready,
conflicts), `queue_unknown`, `via_changed`. `head_changed` (an `expectedHeadOid` mismatch), `token_cannot_merge`,
`rate_limited`, `unreachable`, `busy` and `not_permitted` are unchanged. GitHub's text is never forwarded or logged;
a refused enqueue is told apart from a moved head by GraphQL's structured error name first (`type`, or
`extensions.code`: `STALE_HEAD`, `HEAD_OID_MISMATCH`, `EXPECTED_HEAD_OID_MISMATCH`, `HEAD_CHANGED` are head moves).
GitHub's real names for this are unverified, so the one remaining text read is a bounded look for "head ...
modified/expected" as a last resort; anything unrecognised is `queue_refused`, which sends nothing more. Idempotency per `request_id` and the `busy` rule
are the direct path's. The audit lines (`authored-pr queued`, `authored-pr merged`, `authored-pr merge refused`)
carry `via=queue|direct`.

**Wire (additive).** Rows: `merge_via` (`direct`|`queue`, omitted when unknown) and, while queued,
`queue: {state, position?}` (`state` one of `queued`, `awaiting_checks`, `mergeable`, `unmergeable`, `locked`,
`unknown`; position 1..9999). The Welcome advertises `authored_prs_merge_queue_v1` exactly where
`authored_prs_merge_v1` is. Goldens: `frame-authored-prs-merge-queue.json`, `frame-authored-pr-merge-queue.json`,
`frame-authored-pr-merge-result-queued.json`.

**In the Mac app.** A row that says `queue` while the daemon did not advertise the feature is shown off: "Update
Nostromo to merge into a merge queue". With the feature, a row with no `merge_via` is off too ("Waiting for GitHub to
say how this merges"): the sentence could not be worded. Queue rows say `Add #458 <title> to the merge queue for
<base>? Head 0123abcd. Perri approved. Human approval: yes. Checks: green.` (the recorder wording is unchanged), the
button says "Add to merge queue", the confirmation is also cancelled by a changed `merge_via`. After `queued` (or
`already_queued`) the row says "In merge queue" (with the position once a snapshot has it) and never regroups; a
queued PR that was seen in the queue and later is not, while still open, shows the notice "Dropped from the merge
queue" and the button is available again. One button width for every state, so rows do not shift.

Not verified by tests, because it needs the real thing: a real enqueue on a real admin-portal PR, that the token may
enqueue, the real queue states and positions (and a queued PR's `mergeStateStatus`), VoiceOver.

## What is logged

Counts, durations, error classes and posture changes only. Never a title, branch,
check name, login, repo, PR number, URL or token. The relay client's event line is
`github-relay: event {type}`. The head branch and the full SHA stay in memory. The one exception is the audit line
of a merge attempt, `authored-pr merged` or `authored-pr merge refused` (with its code), which names the repo, the number, the first 8 hex of the head and who
asked (no token, title or body). Nothing logs a Perri note, or a verdict's repo, number or SHA.

## Wire

- Feature `authored_prs_v1` in `Welcome.features` (only when enabled).
- `Topic::AuthoredPrs` (`"authored_prs"`): delivered only to the verified Nostromo
  app, and only if it names the topic (the empty list does not include it), and
  replayed (latest snapshot) on subscribe. Another local client naming it receives
  nothing, as it cannot send the verbs; agents do not read this list.
- `ServerMsg::AuthoredPrs { snapshot }`: `ServerClass::LocalOnly`; a TCP peer gets nothing.
- `ClientMsg::AuthoredPrsDemand`, `ClientMsg::AuthoredPrsRefresh`: refused for network peers.
- Published on change only, debounced 250 ms.
- Feature `authored_prs_notify_v1`: the four hand-off verbs and their answers (`authored_pr_preview`,
  `authored_pr_notify_result`, `authored_pr_start_session_result`, `authored_pr_link_result`; each
  `{request_id, result: {status: ok|err, value}}`, `LocalOnly`), and the additive `told` / `pill` row fields.
  The Mac shows buttons, pickers and pills only when it is advertised.
- Feature `authored_prs_perri_v1` (advertised whenever the list is): the additive `head_sha_short` and `perri`
  row fields.
- Feature `authored_prs_merge_v1` (advertised with the hand-off verbs): `authored_pr_merge` and
  `authored_pr_merge_result` (`{request_id, result: {status: ok|err, value}}`, `LocalOnly`; `ok` carries `{}` and
  an error only `{code}`).
- Feature `authored_prs_merge_queue_v1` (advertised with `authored_prs_merge_v1`): row fields `merge_via` and
  `queue`, the request's `expected_via`, the answers `queued` / `already_queued` and the other queue codes (see
  "The merge queue").
- Golden frames: `tests/fixtures/authored_prs/frame-authored-pr*.json`.
