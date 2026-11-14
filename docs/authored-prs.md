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
  A 401 sets `token: rejected` and stops until demand changes or 30 min pass.
  No token: `token: missing`, no requests.
- Usage counters (`usage` in the snapshot, and an hourly debug log line
  `authored-prs usage: charged=N not_modified=N search=N graphql_points=N relay=N posture=...`)
  count this feature's own requests only. Every request carries
  `User-Agent: nostromd authored-prs`.

## Ownership

A PR's owner is, in order: a Mother job whose PR is this one and whose origin is a
focus the daemon vouches for (`mother_job`); a user-made link (`linked`, reserved
for slice 3); an open focus whose working copy is on the PR's repo and head branch
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
result is always labelled `on_branch`, never stated as fact.

## What is logged

Counts, durations, error classes and posture changes only. Never a title, branch,
check name, login, repo, PR number, URL or token. The relay client's event line is
`github-relay: event {type}`. The head branch and SHA stay in memory.

## Wire

- Feature `authored_prs_v1` in `Welcome.features` (only when enabled).
- `Topic::AuthoredPrs` (`"authored_prs"`): delivered only to a client that names it
  (the empty list does not include it) and replayed (latest snapshot) on subscribe.
- `ServerMsg::AuthoredPrs { snapshot }`: `ServerClass::LocalOnly`; a TCP peer gets nothing.
- `ClientMsg::AuthoredPrsDemand`, `ClientMsg::AuthoredPrsRefresh`: refused for network peers.
- Published on change only, debounced 250 ms.
- Golden frame: `tests/fixtures/authored_prs/frame-authored-prs.json`.
