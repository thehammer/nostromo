# Teri Plugin — v0.1.0 Implementation Plan

## Context

Teri is a Claude Code plugin that acts as a personal work secretary for the user (Hammer, Carefeed). It owns morning briefings, todo capture and management, end-of-day wrap-ups, and surfaces context from Jira, calendar, email, and Sentry by delegating to existing global skills.

This plan builds the plugin from scratch as a **public** GitHub repo at `thehammer/teri` (working tree: `/Users/hammer/Code/teri`). All user-specific values (email, Jira tenant URL, project keys) live in `~/.teri/context.env` and are never committed. A pre-commit guard (`scripts/check-public-safe.sh`) enforces that.

The plugin is named for "Teri" — an unflappable executive assistant archetype. The agent description must explicitly note that "Teri" is not a person and should not be matched fuzzily by other agents; routing here is for secretary/work-tracking intents only.

There is no Jira/Linear ticket. This is greenfield work in a new repo.

## Target

- **Repo:** `thehammer/teri` (new public GitHub repo, to be created during Phase 1)
- **Working tree:** `/Users/hammer/Code/teri`
- **Branch:** `main` (initial commits land directly on main; later phases use `feat/phase-N-*` branches with PRs into `main`)
- **Base:** N/A for Phase 1 (initial commit); `origin/main` for Phases 2–6

## Environment assumptions (verified)

- `claude` CLI present at `/Users/hammer/.local/bin/claude` (v2.1.140+)
- `sqlite3` at `/usr/bin/sqlite3`
- `jq` at `/usr/bin/jq`
- `gh` at `/opt/homebrew/bin/gh`
- `bats` at `/opt/homebrew/bin/bats`
- Global skill libs exist at `~/.claude/lib/services/{jira,m365,calendar,sentry,github}.sh` — Teri may source these when present but must degrade gracefully when they are absent (this is a public plugin; other users won't have them)
- Global skills exist for `jira-workflow`, `email`, `calendar`, `sentry`, `m365` — Teri delegates live lookups to these via the `Skill` tool
- Neither `/Users/hammer/Code/teri` nor `~/.teri` exist yet

## Phase order (logical → renumbered)

The original design called for phases 1→2→5-infra→3→4→6-EOD. For this plan they are renumbered 1–6 with the logical origin noted in each header.

1. Scaffold + public-safety guard *(was Phase 1)*
2. SQLite schema + `teri-todo` CLI + `from-jira` import *(was Phase 2)*
3. Cache layer + `teri-cache-refresh` *(was Phase 5 infra only — no agent UX yet)*
4. `teri-briefing` (morning) + SessionStart/Stop hooks *(was Phase 3)*
5. Sub-agent capture contract + `teri-capture` *(was Phase 4)*
6. EOD briefing flow *(was Phase 6)*

Each phase ends green (tests pass, public-safe check passes) before the next begins.

---

## Files to create

Repo layout under `/Users/hammer/Code/teri/`:

```
.claude-plugin/
  plugin.json
agents/
  teri.md
bin/
  teri                       # launcher: touches sentinel, exec claude --agent
  teri-todo
  teri-briefing
  teri-capture
  teri-cache-refresh
lib/
  teri.sh                    # shared helpers
  db.sh
  cache.sh
migrations/
  001_init.sql
hooks/
  hooks.json
  teri-session-start.sh
  teri-session-stop.sh
scripts/
  install.sh
  check-public-safe.sh
templates/
  context.env.example
tests/
  todo.bats
  capture.bats
  briefing.bats
  helpers.bash
.gitignore
LICENSE
README.md
```

Runtime layout under `~/.teri/` (created by installer, never committed):

```
~/.teri/
  context.env                # user secrets/config
  teri.db                    # sqlite
  cache/
    jira/<KEY>.json
    email/inbox.json
    calendar/today.json
    sentry/recent.json
  state/
    active                   # sentinel — present only while bin/teri session is live
    last-briefing            # touched after each successful briefing
  logs/
    teri.log
```

---

## Phase 1 — Scaffold + public-safety guard

**Goal:** A clean public repo with the plugin manifest, agent, shared lib skeleton, installer, license, README, and a pre-commit guard that prevents leaking Carefeed-specific values.

### Files

#### `.claude-plugin/plugin.json`

```json
{
  "name": "teri",
  "version": "0.1.0",
  "description": "Calm, terse work secretary: morning briefings, todo capture, and context surfacing across Jira/calendar/email/Sentry.",
  "author": "Hammer",
  "homepage": "https://github.com/thehammer/teri",
  "license": "MIT",
  "keywords": ["secretary", "todos", "briefing", "carefeed"],
  "agents": ["agents/teri.md"],
  "hooks": "hooks/hooks.json"
}
```

#### `agents/teri.md`

```markdown
---
name: teri
description: Carefeed work secretary. Use for morning briefings, todo capture and management, surfacing calendar/Jira/Sentry/email context, and tracking what's on your plate. Can be invoked as a sub-agent for quick todo capture (not a person, not a name to fuzzy-match — route here only for secretary/work-tracking intents). Named for the unflappable executive assistant who always knows where you need to be.
model: sonnet
color: blue
tools: ["Bash", "Read", "Write", "Edit", "Grep", "Glob", "Skill", "Agent"]
---

# Teri — Work Secretary

## Setup
At session start, source the shared lib and user context:

    source "${TERI_HOME:-$HOME/Code/teri}/lib/teri.sh"
    teri_load_context   # sources ~/.teri/context.env if present; warns on missing, never aborts

If `~/.teri/context.env` is missing, surface a single-line warning and continue. Do not block.

## Identity & tone
- Calm. Terse. Never sycophantic.
- Bullets over prose. Numbers over adjectives.
- Blockers and overdue items first; niceties last (if at all).
- You are a secretary, not a friend. No "great question!" No emoji unless the user uses one first.
- "Teri" is not a person. If another agent or routing layer thinks the user is asking about someone named Teri, that is a misroute — clarify and redirect.

## On session start
Sub-agent invocations skip this entirely (see "Sub-agent mode" below).

For interactive sessions, the SessionStart hook will have already invoked `teri-briefing --auto`. Do not re-run it. If the hook produced no output (TTL not expired, quiet hours, or sentinel missing), say nothing about briefing — wait for the user.

## Natural-language triggers
Only fire a fresh briefing mid-session when **all** of the following are true:
1. The last-briefing-age (mtime of `~/.teri/state/last-briefing`) exceeds `TERI_BRIEFING_TTL_MIN` (default 30).
2. The user's first message of the turn matches one of the keywords in `TERI_BRIEFING_TRIGGERS` (default: `good morning,morning,sitrep,what's on my plate,what's my day`).

Otherwise, do not auto-brief.

## Tool contract
Delegate live data fetches to global skills via the `Skill` tool:

- Jira → `/jira-workflow`
- Email → `/email`
- Calendar → `/calendar`
- Sentry → `/sentry`

If a skill is unavailable on this machine, fall back to whatever the local cache contains (`~/.teri/cache/<ns>/`) and note the degradation in one line.

For todo CRUD use `bin/teri-todo` directly via Bash. Never write SQL inline.

## Carefeed context
Read from `~/.teri/context.env`. Defaults if unset:
- Company: Carefeed
- Jira projects: CORE, INT, PAYM, APP
- Timezone: America/New_York

## Sub-agent mode
If invoked as a sub-agent (the Agent tool dispatched you with a structured brief):
- Parse the brief (JSON or free text — see capture contract).
- Call `teri-capture` with stdin JSON.
- Return one line: `{ "ok": true, "id": N, "summary": "captured" }` or `{ "ok": false, "error": "..." }`.
- Never run a briefing. Never ask clarifying questions. If `title` is missing, return the error and stop.
```

#### `lib/teri.sh`

```bash
#!/usr/bin/env bash
# Shared helpers. Source this from agent body and from bin/* scripts.
# Idempotent: safe to source multiple times.

[[ -n "${TERI_SH_LOADED:-}" ]] && return 0
TERI_SH_LOADED=1

teri_home() { echo "${TERI_DATA_HOME:-$HOME/.teri}"; }
teri_db()   { echo "$(teri_home)/teri.db"; }

teri_load_context() {
  local ctx="$(teri_home)/context.env"
  if [[ -f "$ctx" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ctx"; set +a
  else
    teri_log warn "context.env not found at $ctx — using defaults"
  fi
}

teri_log() {
  local level="${1:-info}"; shift || true
  local msg="$*"
  local ts; ts="$(teri_now_iso)"
  mkdir -p "$(teri_home)/logs"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$(teri_home)/logs/teri.log"
  [[ "$level" == "warn" || "$level" == "error" ]] && printf '%s: %s\n' "$level" "$msg" >&2
  return 0
}

teri_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { teri_log error "missing required command: $1"; return 1; }
}

teri_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
```

#### `templates/context.env.example`

Use `: "${VAR:=default}"` so existing env vars are **not** clobbered.

```bash
# ~/.teri/context.env — sourced by teri_load_context.
# Copy this from templates/context.env.example and edit. NEVER commit your real values.

: "${TERI_USER_EMAIL:=you@example.com}"
: "${TERI_USER_NAME:=You}"
: "${TERI_COMPANY:=Carefeed}"
: "${TERI_JIRA_SITE_URL:=https://your-tenant.example/}"
: "${TERI_JIRA_PROJECTS:=CORE,INT,PAYM,APP}"
: "${TERI_TIMEZONE:=America/New_York}"
: "${TERI_BRIEFING_QUIET_HOURS:=22-06}"
: "${TERI_BRIEFING_TTL_MIN:=30}"
: "${TERI_BRIEFING_TRIGGERS:=good morning,morning,sitrep,what's on my plate,what's my day}"

export TERI_USER_EMAIL TERI_USER_NAME TERI_COMPANY TERI_JIRA_SITE_URL \
       TERI_JIRA_PROJECTS TERI_TIMEZONE TERI_BRIEFING_QUIET_HOURS \
       TERI_BRIEFING_TTL_MIN TERI_BRIEFING_TRIGGERS
```

#### `scripts/install.sh`

Bash, `set -euo pipefail`. Steps:

1. `mkdir -p "$HOME/.teri"/{cache/jira,cache/email,cache/calendar,cache/sentry,state,logs}`
2. For each file in `bin/*`: symlink into `$HOME/.local/bin/`. If a non-symlink target exists, skip with a warning unless `--force` is passed (in which case overwrite). If an existing symlink already points to our file, no-op.
3. If `$HOME/.teri/context.env` does not exist, copy `templates/context.env.example` there and print: `Edit ~/.teri/context.env with your values before first run.`
4. Run `bin/teri-todo init` (idempotent — creates DB, applies migrations).
5. Verify deps: hard-require `sqlite3`, `jq`, `claude`. Soft-require `gh` (warn only).
6. Prompt (only on a TTY; skip if `--no-prompt` or `--force`): "Install pre-commit hook that runs scripts/check-public-safe.sh? [y/N]". On yes, write `.git/hooks/pre-commit` invoking `scripts/check-public-safe.sh` (chmod +x).
7. Print next-steps block: how to launch (`teri`), how to edit context, where logs live.

Flags: `--force`, `--no-prompt`.

#### `scripts/check-public-safe.sh`

Bash, `set -euo pipefail`. Greps **staged** files (or, if no staged files, all tracked files) for a denylist. Exits non-zero on any hit with a clear message naming the file and pattern.

Denylist (case-insensitive `grep -E`):

- `carefeed\.com`
- `@carefeed\b`
- `[a-z0-9._%+-]+\.atlassian\.net`
- `TERI_USER_EMAIL\s*=\s*['"]?[^'"\s]+@[^'"\s]+` (matches `TERI_USER_EMAIL=` with a non-empty value — the template's `:=` default form does NOT match)
- `[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}` (UUID — likely a tenant or account ID)

Exclude from scan: `.git/`, `node_modules/`, `*.png`, `*.jpg`, `*.gif`, `*.pdf`, `tests/fixtures/safe/**`.

Output on hit:

```
public-safety check failed:
  <file>:<line>: <matched pattern>
Refusing to commit. Move tenant-specific values to ~/.teri/context.env.
```

#### `LICENSE`

Standard MIT, copyright holder "Hammer", year 2026.

#### `README.md`

Public-safe. Sections: What Teri is, Install (3 commands), Configure (link to template), Daily use, Sub-agent integration (link to Mother), Roadmap, License. **No** Carefeed-specific values, **no** real email, **no** real tenant URL. The example block must use `you@example.com` and `your-tenant.example`.

#### `.gitignore`

```
.DS_Store
*.swp
*.log
node_modules/
tests/tmp/
```

#### `hooks/hooks.json`, `hooks/teri-session-start.sh`, `hooks/teri-session-stop.sh`

Stub files in Phase 1 (real logic in Phase 4). The hooks.json should be valid; the scripts can be `#!/usr/bin/env bash` `exit 0` for now so the plugin loads cleanly.

#### `bin/teri`

```bash
#!/usr/bin/env bash
set -euo pipefail
TERI_HOME_DIR="${TERI_DATA_HOME:-$HOME/.teri}"
mkdir -p "$TERI_HOME_DIR/state"
touch "$TERI_HOME_DIR/state/active"
trap 'rm -f "$TERI_HOME_DIR/state/active"' EXIT
exec claude --agent teri:teri "$@"
```

### Steps

1. Create `/Users/hammer/Code/teri/`, `git init`, set default branch to `main`.
2. Create the file tree above. All `bin/*` and `scripts/*` and `hooks/*.sh` get `chmod +x`.
3. Run `scripts/check-public-safe.sh` against the tree — must pass.
4. Run `scripts/install.sh` once locally. Confirm `~/.teri/` is created, symlinks land in `~/.local/bin/`, `context.env` is copied.
5. Run `claude plugin install --scope user /Users/hammer/Code/teri`. Confirm it succeeds.
6. Launch `teri` from a fresh terminal — confirm Teri agent loads. Briefing won't fire yet (no hook logic). That's fine.
7. `gh repo create thehammer/teri --public --source . --remote origin --push` (only after public-safe check is green; user can do this manually if `gh` auth is fussy).

### Acceptance criteria (Phase 1)

- `git grep -iE 'carefeed\.com|atlassian\.net|@carefeed'` returns no hits.
- `scripts/check-public-safe.sh` exits 0 on the committed tree.
- `scripts/check-public-safe.sh` exits non-zero when invoked against a temp file containing `someone@carefeed.com` (demonstrate in a one-off manual check, do not commit the fixture).
- `claude plugin install --scope user /Users/hammer/Code/teri` succeeds.
- `teri` command launches and prints the agent greeting.
- `~/.teri/state/active` exists during the session and is removed when the launcher exits.

---

## Phase 2 — SQLite schema + `teri-todo` CLI + `from-jira` import

**Goal:** Persistent todo store with full CRUD, idempotent init, JSON output, and a `from-jira` subcommand that imports a Jira key into a todo using the local cache.

### Files

#### `migrations/001_init.sql`

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS todos (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  title           TEXT NOT NULL,
  body            TEXT,
  status          TEXT NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','in_progress','done','cancelled','blocked')),
  priority        INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  due_date        TEXT,
  jira_key        TEXT,
  parent_id       INTEGER REFERENCES todos(id),
  recurrence      TEXT,
  source          TEXT NOT NULL DEFAULT 'user'
                    CHECK (source IN ('user','sub_agent','briefing','import','jira')),
  source_ref      TEXT,
  idempotency_key TEXT UNIQUE,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  completed_at    TEXT,
  snoozed_until   TEXT
);
CREATE INDEX IF NOT EXISTS idx_todos_status ON todos(status);
CREATE INDEX IF NOT EXISTS idx_todos_due    ON todos(due_date);
CREATE INDEX IF NOT EXISTS idx_todos_jira   ON todos(jira_key);
CREATE INDEX IF NOT EXISTS idx_todos_idem   ON todos(idempotency_key);
CREATE INDEX IF NOT EXISTS idx_todos_parent ON todos(parent_id);

CREATE TABLE IF NOT EXISTS events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id      INTEGER REFERENCES todos(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,
  payload_json TEXT,
  created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_todo ON events(todo_id);

CREATE TABLE IF NOT EXISTS briefings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  kind         TEXT NOT NULL DEFAULT 'morning' CHECK (kind IN ('morning','eod','manual')),
  summary_md   TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at   TEXT NOT NULL
);

PRAGMA user_version = 1;
```

#### `lib/db.sh`

Functions:

- `db_exec <sql>` — `sqlite3 "$(teri_db)"` with `-bail`
- `db_query <sql>` — `-tabs -noheader`
- `db_query_json <sql>` — `-json` (sqlite3 ≥3.33). Returns `[]` when no rows.
- `db_init()` — creates DB file if missing, sets `PRAGMA journal_mode=WAL`
- `db_migrate()` — reads `PRAGMA user_version`, applies any `migrations/NNN_*.sql` with a higher number, in order, in a transaction. Bumps `user_version`.

All functions use `set -e`-safe error returns and log via `teri_log`.

#### `bin/teri-todo`

Bash, `set -euo pipefail`. Sources `lib/teri.sh`, `lib/db.sh`. Dispatch on `$1`.

Subcommands (all output JSON to stdout when `--json` is passed or when called non-interactively; human table by default for `list` and `show`):

- `init` — `db_init && db_migrate`. Idempotent. Exit 0.
- `add` — flags: `--title T` (required), `--body B`, `--priority N` (1-5, default 3), `--due D` (ISO date or natural language — parse "tomorrow", "friday", "monday", "+3d", "next week" via a helper `parse_due()`; on parse failure, exit 2), `--jira KEY`, `--source S` (default `user`), `--source-ref R`, `--idempotency-key K`. On idempotency-key conflict, return the existing row's id with `{"id":N,"existed":true,...}` and exit 0. Emit a `created` event.
- `from-jira <KEY>` — Look up `~/.teri/cache/jira/<KEY>.json` (refresh via `teri-cache-refresh jira <KEY>` if missing or older than 1h). Extract `summary` as title, `description` (first 500 chars) as body, map Jira priority to 1-5, Jira due date if present. Call `add` with `--source jira --jira KEY --idempotency-key "jira:<KEY>"`. Re-import is a no-op (returns existing id). If cache fetch fails and there's no stale copy: exit 3 with `{"ok":false,"error":"cache miss"}`.
- `list` — flags: `--status open,in_progress` (CSV, default `open,in_progress`), `--due-before D`, `--include-snoozed` (default: hide rows with `snoozed_until > now`), `--limit N` (default 50), `--json` (else human table). Order: priority asc, due_date asc nulls last, created_at desc.
- `show <id>` — Full row + last 10 events + if `jira_key` present, summary line from cached Jira JSON.
- `update <id>` — flags: `--title`, `--body`, `--priority`, `--due`. Bumps `updated_at`. Emits `updated` event with diff payload.
- `status <id> <status>` — Validates against CHECK list. On `done`/`cancelled`, sets `completed_at = teri_now_iso()`. Emits `status_changed` event.
- `snooze <id> <until>` — Parses `until` (same parser as `--due`). Sets `snoozed_until`. Emits `snoozed` event.
- `done <id>` — Sugar for `status <id> done`.
- `search <query>` — `WHERE title LIKE '%q%' OR body LIKE '%q%'`. Honor `--status` and `--limit`.
- `purge --older-than 30d --status done` — Explicit only. Requires both flags. Never automatic. Prints count to be purged, requires `--yes` to actually delete.

Exit codes: `0` ok, `2` usage error, `3` not-found.

#### `tests/todo.bats` and `tests/helpers.bash`

Test harness:

- `helpers.bash` sets `TERI_DATA_HOME=$(mktemp -d -t teri-test)`, exports `PATH` to put `bin/` first, runs `teri-todo init` in `setup()`, cleans up in `teardown()`.
- Tests cover: idempotent `init` (run twice, no error, schema unchanged); `add` → `list` round-trip; `add` with all optional flags; due-date parsing for "tomorrow", "friday", "+3d", ISO; `status` transitions including invalid status rejection; `snooze` hides row from default list; `--include-snoozed` reveals it; `search` matches title and body; `from-jira` with a fixture cache file (`tests/fixtures/jira/DEMO-1.json`); `from-jira` re-run returns same id (`existed:true`); `add` with duplicate `--idempotency-key` returns same id.

Use `DEMO-1` as the fixture key (not `CORE-1234`) to keep fixtures clearly fictional.

### Steps

1. Write `migrations/001_init.sql`, `lib/db.sh`, `bin/teri-todo`.
2. Implement `parse_due()` as a helper in `bin/teri-todo` (or `lib/teri.sh`). Use `date -j -f` on macOS; document macOS-only for v0.1.
3. Write `tests/helpers.bash` and `tests/todo.bats`. Add a fixture under `tests/fixtures/jira/DEMO-1.json` (fictional content — Jira-shaped JSON with `summary`, `description`, `priority`, no real company data).
4. Run `bats tests/todo.bats` until green.
5. Run `scripts/check-public-safe.sh` — must still pass.
6. Commit as `feat(phase-2): sqlite schema + teri-todo CLI`.

### Acceptance criteria (Phase 2)

- `teri-todo init` is idempotent (running twice produces no error and no schema drift).
- `teri-todo add --title "foo"` returns valid JSON with an integer id.
- `teri-todo from-jira DEMO-1` with a fixture cache creates a todo; second invocation returns the same id with `existed:true`.
- All `tests/todo.bats` tests pass.
- `teri-todo add --idempotency-key X` twice returns the same id.

---

## Phase 3 — Cache layer + `teri-cache-refresh`

**Goal:** A generic on-disk cache (`lib/cache.sh`) and a refresh CLI that pulls fresh data from global skill service libs when present, degrading gracefully otherwise. No agent UX yet — this is pure infrastructure for Phase 4.

### Files

#### `lib/cache.sh`

Functions:

- `cache_path <ns> <key>` → `$(teri_home)/cache/<ns>/<key>.json`
- `cache_get <ns> <key> [ttl_seconds]` — If file exists and (`ttl_seconds` unset or mtime within ttl), print contents and exit 0. Else exit 1.
- `cache_put <ns> <key> <content>` — Writes atomically (`tmp` + `mv`).
- `cache_invalidate <ns> [<key>]` — Removes one file or whole namespace dir.

`<key>` is sanitized: only `[A-Za-z0-9._-]`, others become `_`.

#### `bin/teri-cache-refresh`

Subcommands: `jira [KEY]`, `email`, `calendar`, `sentry`, `all`. Flags: `--ttl <seconds>` (override default freshness), `--force` (ignore current cache).

For each subcommand:

1. Check whether the corresponding global service lib exists at `$HOME/.claude/lib/services/<name>.sh`. If absent, log a warn and exit 0 (graceful degrade).
2. If present, source it and call the documented entry function. Capture stdout (JSON).
3. `cache_put` the result. On failure, leave any existing stale cache in place and exit 1 with a clear error.

`all`: run the four refreshes in parallel (`&`), with a hard 30s wall timeout per child. `wait`. Exit 0 if at least one succeeded.

**Service lib contract (documented in script header):**

Teri assumes each `~/.claude/lib/services/<name>.sh`, when sourced, exposes:

- `jira.sh`: `jira_fetch_issue <KEY>` and `jira_fetch_my_issues`
- `m365.sh`: `email_fetch_inbox_summary` (JSON: `{count, unread_count, top:[{subject,from,received_at}]}`) and `calendar_fetch_today` (JSON: `{events:[{start,end,subject,location,attendees}]}`)
- `sentry.sh`: `sentry_fetch_recent_unresolved`

If a function is missing inside an otherwise-present lib, warn and skip — do not crash.

For the public README, document this contract so other users can write their own service libs.

#### `tests/cache.bats`

Cover: `cache_put`/`cache_get` round-trip; TTL expiry; sanitization of weird keys; `cache_invalidate`; `teri-cache-refresh` graceful-degrade when service libs are absent (run with `HOME=$(mktemp -d)` to ensure the libs aren't found).

### Steps

1. Write `lib/cache.sh`. Make all path operations safe under concurrent calls (atomic write).
2. Write `bin/teri-cache-refresh`. Implement subcommand dispatch and the service-lib contract.
3. Write `tests/cache.bats`.
4. Test against the real `~/.claude/lib/services/*.sh` manually: `teri-cache-refresh email` should produce `~/.teri/cache/email/inbox.json`.
5. Run all bats suites green. Run `check-public-safe.sh`. Commit as `feat(phase-3): cache layer + teri-cache-refresh`.

### Acceptance criteria (Phase 3)

- `cache_put` followed by `cache_get` returns the same content.
- `cache_get` with an expired TTL exits 1.
- `teri-cache-refresh all` on a machine with no `~/.claude/lib/services/` exits 0 and logs warnings.
- `teri-cache-refresh email` on Hammer's machine populates `~/.teri/cache/email/inbox.json` with a JSON object containing `count` and either `top` (array) or `top:null`.
- `tests/cache.bats` passes.

---

## Phase 4 — `teri-briefing` (morning) + SessionStart/Stop hooks

**Goal:** Render a fixed-shape morning briefing from cached data, gate it behind sentinel + TTL + quiet hours, and wire it into the Claude SessionStart hook so it auto-fires when (and only when) the user runs `teri`.

### Files

#### `bin/teri-briefing`

Flags:

- `--auto` — Respect all guards (sentinel, TTL, quiet hours). Silent (exit 0, no output) when any guard says skip.
- `--force` — Ignore guards.
- `--json` — Emit the structured payload, not the markdown.
- `--kind <morning|eod|manual>` — Default `morning`. (EOD logic is fully wired in Phase 6; this flag is accepted now and dispatches to a stub for `eod` that just exits 0.)

**Guards (`--auto` only):**

1. **Sentinel guard:** if `$(teri_home)/state/active` is missing → exit 0 silently. (Means we're not inside a `bin/teri` launched session.)
2. **TTL guard:** if `$(teri_home)/state/last-briefing` mtime is within `TERI_BRIEFING_TTL_MIN` minutes → exit 0 silently.
3. **Quiet hours guard:** parse `TERI_BRIEFING_QUIET_HOURS` (format `HH-HH`, e.g. `22-06`); if current hour in `TERI_TIMEZONE` falls within → exit 0 silently.

**Render pipeline (morning):**

1. `teri-cache-refresh all` with a 10s timeout. Ignore failures — use whatever cache exists.
2. Load cache files for calendar/jira/email/sentry. For email, read `top` (up to 3 subjects + senders from Phase 3 cache); if absent, render count-only line.
3. Query open todos: top 3 by priority/due + all overdue (`due_date < today AND status IN ('open','in_progress')`).
4. Query last EOD briefing (if any, from `briefings WHERE kind='eod' ORDER BY created_at DESC LIMIT 1`); extract `payload_json.in_progress_titles` if present and render as "Yesterday you said you'd finish …".
5. Render markdown with fixed sections (in order):
   - `### Today` — calendar events with times
   - `### On your plate` — top 3 + overdue todos
   - `### Inbox` — top 3 unread subjects + senders, or `N unread` if cache absent
   - `### Jira` — assigned/in-progress issues
   - `### Sentry` — top unresolved issues (count + 2-3 titles)
   - `### Yesterday` — wins from yesterday's `done` todos + last EOD pickup
6. Write a `briefings` row (`kind='morning'`, `summary_md` = the markdown, `payload_json` = the structured data).
7. `touch "$(teri_home)/state/last-briefing"`.
8. Print the markdown to stdout. Target render time: <2s on warm cache.

#### `hooks/hooks.json`

```json
{
  "SessionStart": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/teri-session-start.sh" }
  ],
  "Stop": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/teri-session-stop.sh" }
  ]
}
```

#### `hooks/teri-session-start.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Guard 1: only run inside a `bin/teri` session.
[[ -f "${HOME}/.teri/state/active" ]] || exit 0

# Guard 2: explicit opt-out.
[[ "${TERI_NO_BRIEFING:-0}" == "1" ]] && exit 0

# Guard 3: never run for sub-agent invocations.
[[ "${CLAUDE_SUBAGENT:-0}" == "1" ]] && exit 0

# All guards passed — run the briefing.
exec "${HOME}/.local/bin/teri-briefing" --auto
```

#### `hooks/teri-session-stop.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
rm -f "${HOME}/.teri/state/active"
exit 0
```

#### `tests/briefing.bats` additions

Cover: TTL guard skips when `last-briefing` is recent; quiet-hours guard skips inside the window; sentinel guard skips when `active` absent; `--force` bypasses all guards; markdown contains all six section headers; `briefings` row is written; `last-briefing` mtime is updated.

### Steps

1. Write `bin/teri-briefing`. Implement the render pipeline with safe fallbacks for every cache miss.
2. Write the two hook scripts. `chmod +x`. Replace Phase 1 stubs.
3. Update `hooks/hooks.json` from the Phase 1 stub.
4. Test the hook by running `teri` from a fresh terminal. Confirm:
   - First launch: briefing renders.
   - Second launch within `TERI_BRIEFING_TTL_MIN`: no briefing.
   - `TERI_NO_BRIEFING=1 teri`: no briefing.
   - `claude` (without the `teri` launcher): no briefing.
5. Write `tests/briefing.bats`. Make it green.
6. Run all bats suites + `check-public-safe.sh`. Commit as `feat(phase-4): morning briefing + session hooks`.

### Acceptance criteria (Phase 4)

- `teri` launches → briefing renders within 2s on warm cache.
- Opening a fresh `claude` session (not via `bin/teri`) → no briefing output.
- `TERI_NO_BRIEFING=1 teri` → no briefing.
- Subsequent `teri` launches within `TERI_BRIEFING_TTL_MIN` → no briefing.
- `briefings` table has rows with `kind='morning'`.
- `state/last-briefing` mtime advances after each run.
- `tests/briefing.bats` passes.

---

## Phase 5 — Sub-agent capture contract + `teri-capture`

**Goal:** Let other Claude agents (Claudia, Mother, etc.) dispatch Teri as a sub-agent to capture a todo without triggering a briefing or asking clarifying questions.

### Files

#### `bin/teri-capture`

Non-interactive entrypoint. Two input modes:

1. **JSON on stdin** (preferred): a single JSON object.
2. **Flags**: `--title T --body B --priority N --due D --jira-key K --source-ref R --idempotency-key K`.

If both present, flags override stdin.

**Capture contract (also reproduced in `agents/teri.md` "Sub-agent mode" section):**

```
Input:
  title           (string, required)
  body            (string, optional)
  priority        (int 1-5, default 3)
  due             (string, optional — ISO date or natural: "friday", "next week", "+3d")
  jira_key        (string, optional)
  source_ref      (string, optional)
  idempotency_key (string, optional but strongly recommended)

Behavior:
  - Parse and normalize the due date.
  - If idempotency_key provided AND row already exists: return existing id with existed:true. No insert.
  - Otherwise insert via teri-todo add with --source sub_agent.
  - Never run a briefing.
  - Never ask clarifying questions.
  - On missing title: return {"ok":false,"error":"title required"} and exit 2.

Output (stdout, single line):
  Success: {"ok":true,"id":N,"title":"...","existed":false,"summary":"captured"}
  Dedup:   {"ok":true,"id":N,"title":"...","existed":true,"summary":"already captured"}
  Error:   {"ok":false,"error":"..."}
```

#### `tests/capture.bats`

Cover: JSON-stdin path; flag path; missing title → exit 2; idempotency dedup; inserted row has `source='sub_agent'`; `source_ref` is preserved.

### Steps

1. Write `bin/teri-capture`. Thin wrapper around `teri-todo add` after parsing input.
2. Write `tests/capture.bats`. Make it green.
3. From a separate Claude session, invoke Teri as a sub-agent with a structured brief and confirm: row appears with `source='sub_agent'`; no briefing fires; second call with same `idempotency_key` returns same id and `existed:true`.
4. Run all bats suites + `check-public-safe.sh`. Commit as `feat(phase-5): sub-agent capture contract`.

### Acceptance criteria (Phase 5)

- `echo '{"title":"foo"}' | teri-capture` writes a `source='sub_agent'` row and prints `{"ok":true,...}`.
- `echo '{}' | teri-capture` exits 2 with `{"ok":false,"error":"title required"}`.
- Repeating the same call with `idempotency_key` returns the same id and `existed:true`.
- Sub-agent invocation from a parallel real Claude session does not trigger a briefing.
- `tests/capture.bats` passes.

---

## Phase 6 — EOD briefing flow

**Goal:** A wrap-up flow at end of day that surfaces in-progress and due-today work, prompts for done/snooze/note, writes a `briefings` row with `kind='eod'`, and feeds the next morning's briefing.

### Files

#### Updates to `bin/teri-briefing` (`--kind eod`)

1. Query `todos WHERE status='in_progress' OR (status='open' AND due_date <= date('now'))`.
2. Render markdown:
   ```
   ### End of day — <date>

   In progress:
   - [N] <title>  (jira: KEY)  due: <date>

   Due today still open:
   - [N] <title>
   ```
3. **Interactive prompt** (only when on a TTY and `--non-interactive` is not set): for each row, prompt `done / snooze <until> / note <text> / skip`. Apply via `teri-todo status` or `teri-todo snooze` or insert a `note` event.
4. Write a `briefings` row with `kind='eod'`. `payload_json` must include `in_progress_titles` (array of strings) so the next morning's briefing can reference it.
5. Touch `state/last-briefing`.

#### Updates to `agents/teri.md`

Add an "EOD triggers" subsection:

```
EOD triggers — if the user's message matches: "eod", "end of day", "wrap up",
"wrapping up", "signing off", or it's between 16:00–22:00 local time and the
user expresses winding down: offer `teri-briefing --kind eod`. Confirm before
running (this one is interactive — don't auto-fire it).
```

#### `tests/briefing.bats` additions

Cover: `--kind eod --non-interactive` writes a `briefings` row with `kind='eod'`; `payload_json` contains `in_progress_titles`; a subsequent morning briefing's markdown contains a "Yesterday" section referencing one of those titles.

### Steps

1. Extend `bin/teri-briefing` with the EOD branch.
2. Extend `tests/briefing.bats` with EOD coverage.
3. Manually run `teri-briefing --kind eod` with a real `in_progress` row; walk through the prompt; next morning, run `teri` and confirm the "Yesterday" section is populated.
4. Run all bats suites + `check-public-safe.sh`. Commit as `feat(phase-6): EOD wrap-up flow`.

### Acceptance criteria (Phase 6)

- `teri-briefing --kind eod --non-interactive` writes a `briefings` row with `kind='eod'` and `payload_json.in_progress_titles` array.
- A morning briefing run after an EOD row exists includes a "Yesterday" section referencing at least one item from the EOD payload.
- `tests/briefing.bats` covers both.

---

## Final acceptance criteria (whole project)

- `git grep -iE 'carefeed\.com|atlassian\.net|@carefeed'` returns no hits in committed files.
- `scripts/check-public-safe.sh` exits 0 on the committed tree and exits non-zero when invoked against a temp file containing `someone@carefeed.com`.
- `claude plugin install --scope user /Users/hammer/Code/teri` succeeds on a clean machine.
- `teri` launches Teri; morning briefing renders in under 2s on warm cache.
- Opening any non-`teri` Claude session does NOT trigger the briefing hook.
- `teri-todo` full CRUD passes the bats suite.
- Sub-agent invocation writes a `source='sub_agent'` row; idempotency key prevents duplicates on retry.
- `teri-todo from-jira DEMO-1` creates a todo (or returns existing if already imported).
- `teri-briefing --kind eod` writes a `briefings` row with `kind='eod'`.
- All bats suites (`tests/todo.bats`, `tests/cache.bats`, `tests/briefing.bats`, `tests/capture.bats`) pass.
- The repo is published as a public GitHub repo at `thehammer/teri`.

## Out of scope (v0.1)

- Slack integration
- Tags table or tagging UX
- TUI / curses interface
- Multi-user support
- SQLite encryption
- Bidirectional Jira sync
- Web UI or mobile companion
- Smart NLP beyond the small keyword trigger list
- Subtask UX or recurrence UX (`parent_id` and `recurrence` columns exist for future use only)
- Automatic purge of completed todos

## Notes for the implementer

- All paths in shell scripts must be absolute or rooted via `$(teri_home)`. Never `cd` then run.
- macOS-only date parsing is acceptable for v0.1. Document in README.
- Every commit must pass `scripts/check-public-safe.sh`. Install the pre-commit hook in Phase 1.
- When in doubt about whether something is public-safe, move it to `~/.teri/context.env`.
- Do not bundle real Jira issue keys or real email addresses in fixtures. Use `DEMO-1`, `you@example.com`.
- Run the full bats suite before every phase commit.

## Suggested config

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Six-phase greenfield plugin spanning shell, SQLite, hook integration, sub-agent contracts; hook gating correctness is load-bearing."
  redd:
    model: sonnet
    effort: high
    rationale: "First bats harness for this repo; four suites covering TTL/quiet-hours/sentinel guards that are easy to miss."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass to consolidate shared shell helpers after phases land."
  perri:
    model: sonnet
    effort: high
    rationale: "Public repo with a public-safety contract; a leaked email or tenant URL in a fixture is a permanent mistake."
```
