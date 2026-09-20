# The `jira` ticket provider

`nostromo.get_ticket` (the `ticket` pane content kind — see `docs/mcp/panes.md`)
is served by a name-keyed registry of `TicketProvider` implementations
(`src/data/tickets/mod.rs`). `jira` is the only provider registered in v1
(`src/data/tickets/jira.rs`). This document is operator-facing: what a
deployment needs to configure for `jira` to work, and how it fails when it
isn't configured.

## What it talks to

Jira Cloud's REST API **v3** issue endpoint:

```
GET https://{site}/rest/api/3/issue/{key}?fields=summary,status,assignee,description,comment
```

authenticated with HTTP basic auth (`email:api_token`). v3 (not v2) is a
deliberate choice: v3 returns `description`/comment bodies as **ADF**
(Atlassian Document Format), a structured JSON document that maps almost
one-to-one onto the same `MdBlock`/`MdSpan` model `pr_conversation` uses,
rather than v2's wiki-markup string — which would need a second, bespoke
parser. Any ADF node type the mapper doesn't recognise is folded into a plain
paragraph carrying its text, never silently dropped.

`ticket` is **read-only**. There is no transition, comment, worklog, or field
edit anywhere in this provider, and none is planned for it — writing to Jira
is out of scope for this view.

## Credentials

`nostromd` normally runs as a launchd user agent (see the `install-daemon`
Makefile target and `dist/launchd/com.hammer.nostromd.plist`), which means it
does **not** inherit the shell environment where `~/.claude/credentials/.env`
is normally sourced. Resolution order, checked once at daemon startup:

1. **Environment variables**, if the daemon process happens to have them:
   `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN`.
2. **The credentials file** — `.env`-style `KEY=VALUE` lines — at the path
   `jira_credentials_path` in `~/.config/nostromo/config.toml` names, or
   `~/.claude/credentials/.env` by default.
3. **`config.toml` overrides** — `jira_site` and `jira_email` in
   `~/.config/nostromo/config.toml` win over either of the first two sources
   for those two fields specifically. There is no `config.toml` override for
   the token itself; it only ever comes from the environment or the
   credentials file.

Credentials are resolved **once**, at daemon startup, and held only on the
constructed provider — never added to `Config` (which derives `Debug` and is
not redacted) and never logged. `nostromd`'s startup log records one line,
`info`-level, noting whether `jira` resolved credentials — never the token
itself.

A changed credentials file or `config.toml` needs a daemon restart
(`launchctl kickstart -k ...`, or however you normally restart `nostromd`) to
take effect.

### Example `~/.claude/credentials/.env`

```
ATLASSIAN_SITE_NAME=carefeed.atlassian.net
ATLASSIAN_USER_EMAIL=you@example.com
ATLASSIAN_API_TOKEN=your-api-token-here
```

Generate an API token at
`https://id.atlassian.com/manage-profile/security/api-tokens`.

## What happens when it isn't configured

`jira` is **always registered** — it is never `unsupported_provider` — but it
may be **unconfigured**. Requesting `nostromo.get_ticket` with
`{"provider": "jira", ...}` against an unconfigured deployment refuses with
`provider_unconfigured`, and the message names the credentials file path and
all three variable names it looked for, so the failure is actionable without
reading this file. It never panics and never blanks a pane that already had
content.

## Section anchoring and the alias table

A Jira description has no structural notion of "the acceptance criteria
section" — that's a heading convention. `ticket` derives sections from the
description's own headings: everything before the first heading is the
`"description"` section, and each subsequent heading starts a new section
named after its own (lowercased, normalized) text — resolved against an alias
table so a heading like `## AC` or `## Definition of Done` still resolves to
the canonical `acceptance_criteria` name Perri asks for.

The alias table is data, not code: a compiled-in default
(`src/mcp/tickets.yaml`), overridable — no daemon rebuild required — at
`~/.nostromo/tickets.yaml`:

```yaml
aliases:
  acceptance_criteria:
    - "Acceptance Criteria"
    - "Acceptance criterion"
    - "AC"
    - "Definition of Done"
```

Add a team's own heading convention by adding a variant to this file. Every
`nostromo.get_ticket` call re-reads the override file — no caching, no
rebuild.

## Caching

Fetched tickets are cached in memory, keyed `(provider, key)`, for 60
seconds — long enough that repeatedly showing the same ticket (including the
daemon's own startup repaint of a bound `ticket` pane) costs at most one HTTP
request per window, short enough that "check the ticket again after someone
edited it" still works within a review session. The cache is **not**
persisted across a daemon restart.

## What this provider is not

- Not a search API — there is no JQL, no sprint/board view, no attachments,
  no subtask tree.
- Not the only provider forever — `provider` is a request field precisely so
  Linear, GitHub Issues, or anything else can register a second
  `TicketProvider` later without a new pane content kind. None is registered
  today.
- Not connected to the macOS PR-title Jira-key regex
  (`AppStore.pushDetailToDiffPane`) — that remains a client-side URL scrape,
  unchanged. Deriving a ticket key from a PR automatically is a different,
  not-yet-built piece of work.
