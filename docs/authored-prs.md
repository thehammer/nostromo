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
for the head the daemon holds for the PR: if the PR is unknown or its head differs, the PR is read once more and
the check repeated, and a miss is refused (`pr_unknown`, `head_not_current`), so a commit cannot be approved before
it is pushed. A `changes_requested` or `comment` can only block, so it is taken for any head. The result says
`for_current_head: true | false`.

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
`perri_stale`, `token_cannot_merge`, `rate_limited`, `unreachable`, `busy`, `not_permitted`.

Not verified by tests, because it needs the real thing: a merge on a real PR, and whether a real token's scope
allows merging.

**In the Mac app** (slice C). Rows show Perri's verdict and, in the READY group, a Merge button. Nothing appears
without the matching feature: the badge needs `authored_prs_perri_v1`, the button needs that and
`authored_prs_merge_v1` (an older daemon gets no half-working control).

- **Badge** on every open row that has a worth-showing verdict: `Perri ✓` (approved, for the current head),
  `Perri ✓ older` (approved an earlier head: muted, and a new push needs a new review), `Perri ✗` (changes
  requested), `Perri comments`. No verdict, an unknown one, or a non-approval of an older head: no badge. The
  tooltip says when, by whom and the head; VoiceOver says "Perri approved this version" and so on.
- **Button** on open READY rows. Enabled only when `mergeReadiness` is `.ready`: a human approved, checks are
  green (or there are none) and Perri approved the head the row shows. Otherwise it is shown off with the first
  reason (`Draft`, `Checks not green`, `Waiting for human approval`, `Needs Perri's review`, `Perri approved an
  older version`, `Perri requested changes`) in its tooltip, its VoiceOver label and at the end of the row's
  review line.
- **Press** is a human gesture (`HumanGesture.permit`, like the hand-off buttons): a synthesised or Accessibility
  press does nothing. It opens a one-step confirmation: `Squash and merge #458 <title> into <base>? Head
  0123abcd. Perri approved. Human approval: yes. Checks: green.` (title cleaned and capped at 80 characters).
  Cancel is the default button (Return cancels), Merge has no key equivalent and is gesture-checked again,
  Escape cancels. The confirmation is cancelled when a snapshot changes that row's head or makes it not ready.
- **Confirm** sends one `authored_pr_merge` carrying the head short sha **of the row the person pressed on**,
  never a newer snapshot's. The row says `Merging…` (a second press opens nothing), then `Merged` or a notice in
  place of its owner line with a dismiss button. The row never regroups on the strength of our own request; only
  the next snapshot moves it. A notice is the words of the daemon's code (an unknown code is a generic `The merge
  failed`, never success) and stays until dismissed, the row's head changes (not for `head_changed`, which is
  about exactly that), a new attempt starts or the PR is no longer open.
- No new key equivalents; the context menu has no Merge item; Return on a row never merges. VoiceOver gets a
  `Merge` custom action only while the button is enabled, and `Dismiss merge message` while a notice shows.
- There is no admin merge and no hidden path to one: the transport has the one verb and the one request shape.

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
- Golden frames: `tests/fixtures/authored_prs/frame-authored-pr*.json`.
