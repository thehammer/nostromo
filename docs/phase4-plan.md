# nostromo Phase 4 — Native data clients (Microsoft Graph + GitHub)

## Delivery model

**Trunk-based. Do NOT open a pull request.**
When work is complete and tests pass, merge the feature branch directly to `main` and push:
```bash
git checkout main && git merge --ff-only feature/phase4-native-data-clients && git push origin main
```
Do not run `gh pr create` or any equivalent.

## Context

`nostromo` is a Ratatui-based Rust TUI at `~/Code/nostromo` that surfaces a unified dashboard for the user's AI agents (Fred, Perri, Mother, etc). Phases 1–3 will be complete before this runs:
- Phase 1: scaffold, Fred/Perri views via bash `--json` data sources
- Phase 2: embedded PTY, syntax-highlighted diffs, AgentBus
- Phase 3: Mother queue panel, inline await-approval, right context panel

Phase 4 replaces the four bash-polling data sources with native Rust clients that call Microsoft Graph and the GitHub API directly. The win: update latency for mailbox/calendar drops from ~60s polling to delta-push (~5s), and the TUI no longer depends on having Fred/Perri's bash tooling installed. There is no external ticket — this is internal phase planning tracked in `/Users/hammer/Code/nostromo/docs/PLAN.md`.

The four bash-backed sources to replace currently live at `/Users/hammer/Code/nostromo/src/data/fred_mailbox.rs`, `/Users/hammer/Code/nostromo/src/data/fred_calendar.rs`, `/Users/hammer/Code/nostromo/src/data/perri_queue.rs`, `/Users/hammer/Code/nostromo/src/data/perri_pr.rs`. Each spawns a tokio task that calls `tokio::process::Command::new(<bin>).arg("--json")` and parses stdout into a `*Snapshot` struct, publishing on a `tokio::sync::watch` channel. The `Snapshot` struct shapes (`MailboxSnapshot`, `CalendarSnapshot`, `PrQueueSnapshot`, `PrSnapshot`) are the public contract to the views and **must be preserved exactly** so phase 1–3 view code keeps compiling.

## Target

- **Repo:** nostromo (`/Users/hammer/Code/nostromo`)
- **Branch:** `feature/phase4-native-data-clients`
- **Base:** `origin/main`

## Files to change

### New files (native clients)
- `/Users/hammer/Code/nostromo/src/data/graph_client.rs` — OAuth2 device-flow auth for Microsoft Graph, token cache at `~/.cache/nostromo/graph-token.json`, `reqwest` HTTP wrapper, auto-refresh on 401, exposes `GraphClient` with `get_json::<T>(url)` and a `delta(initial_path, delta_link_file)` helper that persists `@odata.deltaLink`.
- `/Users/hammer/Code/nostromo/src/data/fred_mailbox_native.rs` — native replacement for `fred_mailbox.rs`. Public surface: `FredMailboxSource::spawn(config) -> watch::Receiver<Option<MailboxSnapshot>>`. Calls Graph `/me/mailFolders/inbox/messages` with `$delta`.
- `/Users/hammer/Code/nostromo/src/data/fred_calendar_native.rs` — native replacement for `fred_calendar.rs`. Calls Graph `/me/calendarView?startDateTime=...&endDateTime=...` with `$delta`. Computes `sweater` color (sage/amber/red) from minutes-to-next-event using thresholds matching `~/.claude/bin/fred-calendar-pane` (read that script first to confirm; if uncertain default to red < 5 min, amber 5–15 min, sage > 15 min, sage if no upcoming).
- `/Users/hammer/Code/nostromo/src/data/github_client.rs` — wraps `octocrab::Octocrab`. Token resolution order: (1) `GITHUB_TOKEN` env var, (2) parse `~/.config/gh/hosts.yml` via `serde_yaml` for `github.com.oauth_token`. Error if neither found, instructing the user to run `gh auth login`.
- `/Users/hammer/Code/nostromo/src/data/perri_queue_native.rs` — native replacement for `perri_queue.rs`. Uses GitHub search: `is:open is:pr review-requested:@me archived:false` and `is:open is:pr assignee:@me archived:false`, dedup, populates `PrQueueSnapshot` (mark `requested = true` for the first set). Stores per-query `ETag` in memory and sends `If-None-Match`.
- `/Users/hammer/Code/nostromo/src/data/perri_pr_native.rs` — native replacement for `perri_pr.rs`. Reads the "current PR" pointer from `~/.claude/state/perri/current-pr.json` (verify exact format by inspecting `~/.claude/bin/perri-diff-pane`). Fetches PR metadata via octocrab and the diff via raw reqwest with `Accept: application/vnd.github.diff` against `https://api.github.com/repos/{owner}/{repo}/pulls/{n}`.

### Modified files
- `/Users/hammer/Code/nostromo/Cargo.toml` — add dependencies (see Approach §1).
- `/Users/hammer/Code/nostromo/src/data/mod.rs:7-11` — add `pub mod` entries for the new native modules; keep existing bash modules (no `#[cfg]` gating; runtime flag selects).
- `/Users/hammer/Code/nostromo/src/main.rs` and/or `/Users/hammer/Code/nostromo/src/app.rs` — add CLI flag `--bash-fallback` (clap). Default = native; with flag = old bash sources. Branch on it where the four `*Source::spawn(config.clone())` calls happen.
- `/Users/hammer/Code/nostromo/src/config.rs:13-44` — add optional fields: `graph_client_id: Option<String>`, `graph_tenant: Option<String>` (default `"common"`), `graph_token_cache: Option<PathBuf>` (default `~/.cache/nostromo/graph-token.json`), `github_token_path: Option<PathBuf>` (default `~/.config/gh/hosts.yml`). Add accessor methods mirroring lines 67–101.
- `/Users/hammer/Code/nostromo/src/data/fred_mailbox.rs:47-56` — extend `MailboxSnapshot` with `pub auth_prompt: Option<DeviceFlowPrompt>` (additive only). `DeviceFlowPrompt { verification_uri: String, user_code: String, expires_at: DateTime<Utc> }` lives in `graph_client.rs` and is re-exported. `serde(default)` on the new field keeps existing snapshots and the bash source backwards-compatible.
- `/Users/hammer/Code/nostromo/src/views/fred.rs` — add an "auth needed" rendering path: when the latest `MailboxSnapshot.auth_prompt` is `Some`, render the verification URI, user code, and a live countdown in the mailbox panel.

### New test files
- `/Users/hammer/Code/nostromo/tests/graph_client.rs` — wiremock tests: device-flow happy path, refresh on 401, delta-link persistence.
- `/Users/hammer/Code/nostromo/tests/github_client.rs` — wiremock tests: token parsing from a fixture `hosts.yml`, ETag round-trip, diff-accept-header fetch.
- Update `/Users/hammer/Code/nostromo/tests/snapshot_fred.rs` and `/Users/hammer/Code/nostromo/tests/snapshot_perri.rs` only if the snapshot output drifts. Do **not** auto-accept drift — flag any diff in the PR body for human review.

## Approach

1. **Add dependencies** to `Cargo.toml` under `[dependencies]`:
   - `reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls", "stream"] }`
   - `oauth2 = "4"`
   - `tokio-util = { version = "0.7", features = ["io"] }`
   - `octocrab = "0.41"`
   - `serde_yaml = "0.9"`
   - `url = "2"`
   Under `[dev-dependencies]`:
   - `wiremock = "0.6"`
   Run `cargo build` to confirm clean resolution before writing client code.

2. **Implement `src/data/graph_client.rs`**:
   - `pub struct GraphClient { http: reqwest::Client, token: Arc<Mutex<TokenState>>, cache_path: PathBuf, client_id: String, tenant: String }`.
   - `TokenState { access_token, refresh_token, expires_at }`.
   - `pub async fn ensure_authed(&self) -> Result<Option<DeviceFlowPrompt>>` — load cached token; if absent or refresh fails, kick off device flow against `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/devicecode` with scopes `Mail.Read Calendars.Read offline_access` and return `DeviceFlowPrompt`. Background task polls `/oauth2/v2.0/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code`. On success, persist token to `cache_path` (file mode 0600, parent dir 0700) and signal completion via `tokio::sync::oneshot`.
   - `pub async fn get_json<T: DeserializeOwned>(&self, url: &str) -> Result<T>` — attaches Bearer; on 401, calls `refresh()` once then retries.
   - `pub async fn delta<T>(&self, initial_path: &str, delta_link_file: &Path) -> Result<(Vec<T>, String)>` — uses persisted delta link if present, else `initial_path`; follows `@odata.nextLink` pagination; persists `@odata.deltaLink`.

3. **Implement `src/data/fred_mailbox_native.rs`** mirroring the spawn/loop structure at `src/data/fred_mailbox.rs:66-105`. Keep the dirty-file watcher as a manual "refresh now" signal. On each tick, `graph.delta::<GraphMessage>("/me/mailFolders/inbox/messages?$top=25&$select=from,subject,receivedDateTime,isRead", delta_path)`. Map Graph `Message` → `MailboxItem`: `from = "{name} <{addr}>"`, `received_at = receivedDateTime`, `is_read = isRead`, `vip` = membership in a `vip_senders: Vec<String>` config list (start empty, document in `docs/PLAN.md`), `is_invite` = subject starts with "Invitation:" OR Graph event extension present. Compute `unread_count = items.iter().filter(|m| !m.is_read).count()`. Replace the prior 60s `tokio::time::sleep` with 5s — Graph delta returns empty responses cheaply.

4. **Implement `src/data/fred_calendar_native.rs`**: `/me/calendarView?startDateTime=<now>&endDateTime=<now+24h>` with header `Prefer: outlook.timezone="UTC"`, $delta as above. Build `CalendarSnapshot.events` from response, set `next` to the first event with `start > now`, compute `sweater` from the verified thresholds.

5. **Implement GitHub clients**:
   - `GithubClient::new(config)` resolves token, builds `Octocrab`.
   - `perri_queue_native`: run both search queries via `octocrab.search().issues_and_pull_requests(...)`, merge by URL. Cache ETags in memory keyed by query; on 304, reuse the prior snapshot.
   - `perri_pr_native`: read `current-pr.json`; metadata via `octocrab.pulls(owner, repo).get(number)`; diff via raw reqwest GET against `https://api.github.com/repos/{owner}/{repo}/pulls/{number}` with `Accept: application/vnd.github.diff` and the same Bearer token.

6. **Wire it up in `src/main.rs` / `src/app.rs`**: extend the `clap` parser with `#[arg(long)] bash_fallback: bool`. At each `*Source::spawn` call site, branch on the flag — default native, `--bash-fallback` calls the existing bash sources unchanged. The watch-receiver type is identical so downstream code is unchanged.

7. **Device-flow auth UI in `src/views/fred.rs`**: when latest `MailboxSnapshot.auth_prompt` is `Some`, render a centered block in the mailbox panel:
   ```
   Microsoft sign-in required
   Visit: https://microsoft.com/devicelogin
   Code:  ABCD-EFGH
   (expires in 14:32)
   ```
   Tick the countdown each render frame.

8. **Tests**:
   - `tests/graph_client.rs`: stand up `wiremock::MockServer`; assert device-flow happy path (`/devicecode` → token poll → success), refresh on 401 (mock first 401, second 200, assert single retry), delta-link persistence (assert file written).
   - `tests/github_client.rs`: write fixture `hosts.yml`, assert token parsed; mock GitHub search response, assert correct query string; mock diff endpoint with `application/vnd.github.diff`, assert diff captured verbatim.

9. **Final verification**:
   - `cargo build --release` clean, zero warnings.
   - `cargo test` passes.
   - `cargo clippy --all-targets -- -D warnings` passes.

## Acceptance criteria

- All six new files exist and compile (paths in Files to change above).
- `cargo build --release` succeeds with **zero warnings** in the `nostromo` crate.
- `cargo test` passes including new wiremock-backed tests in `tests/graph_client.rs` and `tests/github_client.rs`.
- `cargo clippy --all-targets -- -D warnings` passes.
- Default `cargo run` uses the native clients; `cargo run -- --bash-fallback` uses the original bash sources.
- First-run with no Graph token cache renders a device-flow prompt in the Fred mailbox view (verifiable by deleting `~/.cache/nostromo/graph-token.json` and launching).
- GitHub auth: launching with `GITHUB_TOKEN` unset but valid `~/.config/gh/hosts.yml` succeeds and renders the Perri queue.
- Mailbox/calendar update path uses Graph `$delta` (code persists `@odata.deltaLink` between polls) and polls every 5s rather than 60s.
- Existing `MailboxSnapshot`, `CalendarSnapshot`, `PrQueueSnapshot`, `PrSnapshot` field sets are **preserved** — only additive fields allowed (notably `auth_prompt`). Phase 1–3 view code continues to compile without modification beyond the auth-prompt render path in `src/views/fred.rs`.
- PR opened against `main` titled `feat: phase 4 — native Microsoft Graph and GitHub data clients` with a body listing the new files, dependencies added, and any snapshot-test drift.

## Out of scope

- The `nostromod` daemon (phase 5).
- Migrating the Mother queue panel away from its current data source.
- Removing the bash scripts at `~/.claude/bin/fred-*-pane` and `~/.claude/bin/perri-*-pane`. They stay as a `--bash-fallback`.
- Removing the `--json` flag from those bash scripts.
- GitHub webhook support (ETag conditional requests are sufficient for phase 4).
- New view features beyond the auth-prompt rendering in Fred.
- Refactoring the existing `DataSource` trait in `src/data/mod.rs`.
- Persisting Graph subscriptions / push notifications; $delta polling is enough.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "OAuth2 device flow, Graph delta-link persistence, and 401-refresh retry logic are correctness-sensitive across multiple new modules."
  redd:
    model: sonnet
    effort: medium
    rationale: "Wiremock-driven HTTP fixtures for Graph and GitHub; standard scope, no new harness required."
  marty:
    model: sonnet
    effort: medium
    rationale: "Consolidate shared spawn/poll-loop pattern between native sources; tidy duplication against existing bash sources."
  perri:
    model: sonnet
    effort: high
    rationale: "Auth and HTTP retry paths are easy to get subtly wrong; reviewer should scrutinise token-cache permissions, refresh races, and ETag handling."
```
