# Team-based "Mine" for the Sentry toggle

Status: idea (not committed to)

The Sentry tab's Mine | Unassigned | All toggle defines "Mine" as issues assigned
directly to the user (Sentry search `assigned:me`). Teams are deliberately not
included.

If other people start using Nostromo, "Mine" will probably want to include issues
assigned to the teams the user belongs to (Sentry's `assigned:#team` /
`assigned_or_suggested:me`-style searches), since many orgs assign to teams rather
than individuals.

## Sketch

- Add a third search in `src/data/work/sentry.rs` (`SEARCHES`) for the user's teams
  and tag its items with a new assignee bucket (e.g. `team`), alongside `me` and
  `unassigned`. The `WorkItem::assignee` field and the Rust/Swift `assignees` filter
  already carry arbitrary bucket values.
- Decide whether "Mine" means `me` only or `me` + `team` (a segment option's `values`
  can list several buckets), or whether Team gets its own segment.
- Needs the user's team list from Sentry (`/api/0/organizations/{org}/teams/?` with
  `member` scoping) or a config entry; today only the token is configured.
- Both query engines (`src/data/work/query.rs`, `macOS/Nostromo/Data/WorkQuery.swift`)
  and `tests/fixtures/work_query_cases.json` need no change for new bucket values.
