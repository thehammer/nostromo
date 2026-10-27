# Feature: Sentry tab production-only toggle with counts

## Summary

Add a second single-select toggle to the Teri Sentry tab: **Production | All**,
with counts, in the same style as the Mine | Unassigned | All assignee toggle
(branch `feature/sentry-assignee-toggle`). It composes with the assignee toggle
(for example Mine + Production). Default to be decided; the user wants the
choice remembered like the assignee toggle.

## Motivation

The tab mixes production and non-production (qa-*, test, demo, sandbox) issues.
Today a large share of the unassigned list is QA-environment configuration noise
(for example the Mailgun and payments-host issues), which makes it hard to tell
what is customer-impacting. Production-only is the quickest read on urgency.

## Constraint to design around

Sentry's organization issue list does not carry environments, so list rows have
no environment. See the header comment in `src/data/work/sentry.rs`: the
environment of an issue lives on its latest event's `tags`, and
`WorkItem.environment` is always unset for list rows. Options to evaluate:

- Run the same two searches again with Sentry's `environment=production` query
  parameter (or `environment:production` in the query) and mark the items they
  return; the rest are non-production. Costs two more list calls per refresh,
  so check the rate-limit budget (the source already honours rate-limit holds).
- Fetch each issue's environment tag values (`/issues/{id}/tags/environment/`),
  which is one call per issue and likely too expensive.
- Note an issue can fire in several environments; decide whether "Production"
  means "has fired in production" (the `environment=production` search answers
  this) or "last event was production".

## Rough shape

- Rust: tag items with whether they matched the production search, probably as
  a new field or by populating `WorkItem.environment`; add the matching filter
  and facet to both query engines (Rust `src/data/work/query.rs`, Swift
  `WorkQuery.swift`) and the shared fixture
  `tests/fixtures/work_query_cases.json`, which both are tested against.
- Swift: a second scope control (counts from facet counts, with the other
  filters applied), remembered per tab like the assignee toggle.

## Notes

- Follow-up to the assignee toggle; do after that PR merges.
- Requested by the user on 2026-10-26.

## Resolution

- "Production" means the issue had an event in the `production` environment
  within the last 14 days. It comes from one `is:unresolved` search with
  `environment=production`, sorted by last seen and capped at 300. It only marks
  issues the other searches listed; it adds no rows.
- `WorkItem.environment` is `"production"` for those issues and unset otherwise.
  Unset means "not seen in production in the window", not "non-production".
- The default is All (nothing hidden), and the choice is remembered like the
  assignee toggle.
- It reuses the existing `environments` filter and `environment` facet in both
  query engines; the "All" segment counts every matching item, including those
  with no environment.
- Ships in the follow-up to #343. After merge, move this doc with
  `~/.claude/bin/doc-mgr move <path> shipped` (to `features/shipped/`).
