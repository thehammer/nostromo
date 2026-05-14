# Bishop OAuth polling — proactive per-model quota visibility

## Context

Anthropic's `api.anthropic.com/api/oauth/usage` endpoint returns proactive utilization data per model. It's what Claude Code's `/usage` UI reads. The response shape (confirmed live):

```json
{
  "five_hour":         { "utilization": 12.0, "resets_at": "2026-05-13T21:50:00.989745+00:00" },
  "seven_day":         { "utilization": 71.0, "resets_at": "2026-05-15T02:00:00.989763+00:00" },
  "seven_day_sonnet":  { "utilization": 100.0, "resets_at": "2026-05-15T02:00:00.989770+00:00" },
  "seven_day_opus":    null,
  "seven_day_haiku":   null,
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": null,
    "used_credits": 15650.0,
    "utilization": null,
    "currency": "USD"
  }
}
```

Bishop currently reads aggregate-only data from `~/.mother/rate-limits.json` (Mother's stream capture). That source is reactive and aggregate-only. By polling the OAuth endpoint directly, Bishop gains proactive per-model visibility — including the user's plan-specific `seven_day_sonnet` cap that exhausts independently of the aggregate.

This work supersedes a prior reactive `rate_limit_event` capture design. Drop that approach entirely. The OAuth endpoint gives us strictly more and better data.

No upstream ticket. Touches two files in the Bishop repo plus one dotfile script.

## Target

- **Repo:** `bishop` at `/Users/hammer/Code/bishop`
  - **Branch:** `feature/oauth-usage-polling`
  - **Base:** `origin/main`
- **Dotfile (separate, edit in place):** `/Users/hammer/.claude/bin/tmux-rate-limits`

## Environment notes

- Bishop's launchd agent already refreshes every 60s — matches endpoint's tolerance.
- macOS-only auth: token lives in keychain at service `Claude Code-credentials`. Linux/headless paths are out of scope for v1 (note in README).
- Endpoint rate-limits aggressively. On 429, Bishop must back off and keep using last cached data.

## Files to change

### Bishop: `bin/bishop-fetch-usage` (new)

Standalone bash script. Responsibilities:

1. Pull OAuth token from macOS keychain:
   ```bash
   security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
     | jq -r '.claudeAiOauth.accessToken'
   ```
   If empty → log to stderr, exit 2.
2. `curl -sS --max-time 10` the endpoint with `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
3. On HTTP success + valid JSON: print body to stdout, exit 0.
4. On `rate_limit_error` in response body: exit 3 (distinct so the caller can keep stale data).
5. On any other failure (network, auth, malformed): log to stderr, exit 1.

Keep this script tiny and self-contained. No sourcing of bishop libs. It's a thin shim around `security` + `curl`.

### Bishop: `bin/bishop` modifications

1. **Add env defaults** near other path constants:
   ```bash
   : "${BISHOP_USAGE_FETCH_CMD:=$(dirname "$0")/bishop-fetch-usage}"
   : "${BISHOP_USAGE_CACHE_PATH:=$HOME/.claude/oauth-usage.json}"
   : "${BISHOP_USAGE_CACHE_TTL_SECONDS:=55}"  # one tick under the 60s launchd cadence
   ```

2. **Modify `_bishop_refresh`** — at the top of the function, before reading the existing `BISHOP_SOURCE_PATH`:
   - If `$BISHOP_USAGE_CACHE_PATH` exists AND mtime < `BISHOP_USAGE_CACHE_TTL_SECONDS` ago → skip fetch, reuse cached.
   - Otherwise call `"$BISHOP_USAGE_FETCH_CMD"` (with a 10s timeout via bash backgrounding or `timeout` if available). On exit 0, atomic-write the response to `$BISHOP_USAGE_CACHE_PATH`. On any non-zero, log and continue with whatever cached file already exists.
   - If neither fresh fetch nor cached file is available, fall back to the existing `$BISHOP_SOURCE_PATH` path (the legacy aggregate-only mode). Existing logic remains exactly as-is in that fallback branch.

3. **New jq program `_BISHOP_OAUTH_JQ_PROGRAM`** — translates the OAuth response into Bishop's posture schema. Takes `--argjson now $now`. Output object includes all existing fields plus new ones:
   ```json
   {
     "ts": "...",
     "source": "oauth_usage",
     "posture": "...",
     "five_hour": { "used_pct": <int>, "elapsed_pct": <float>, "pace": <float-or-null>, "resets_at": <epoch>, "level": "..." },
     "seven_day": { ... same shape ... },
     "models": {
       "sonnet": <entry-or-null>,
       "opus":   <entry-or-null>,
       "haiku":  <entry-or-null>
     },
     "exhausted_models": [...],
     "extra_usage": {
       "is_enabled": <bool>,
       "used_credits": <number-or-null>,
       "currency": "USD",
       "monthly_limit": <number-or-null>,
       "utilization": <number-or-null>
     },
     "source_mtime": "...",
     "source_age_seconds": <int>,
     "stale_input": <bool>
   }
   ```

   Per-model entry (`models.<name>`) shape when present:
   ```json
   { "status": "exhausted" | "active",
     "used_pct": <number 0-100>,
     "resets_at": <epoch> }
   ```
   - `models.<name>` is `null` when the OAuth response has `seven_day_<name>: null` (plan doesn't have that bucket).
   - `models.<name>` is `null` if `resets_at` in response is in the past or null.
   - `status` is `"exhausted"` when `utilization >= 100`, otherwise `"active"`.
   - `exhausted_models` array contains names where `status == "exhausted"`.

   ISO `resets_at` strings must be converted to epoch ints. Use jq's `fromdateiso8601` (strip the sub-second suffix first via `sub("\\.[0-9]+(?=[+Z])"; "")` if jq's parser rejects fractional seconds).

4. **Tag the source** in output. New top-level `source` field: `"oauth_usage"` when the OAuth fetch succeeded (fresh or cached), `"mother_aggregate"` when falling back to the legacy `$BISHOP_SOURCE_PATH`. The existing `stale_input` field continues to reflect whether the source data is older than `BISHOP_SOURCE_STALE_SECONDS`.

5. **Existing aggregate posture computation** (`_BISHOP_JQ_PROGRAM`) must still work. Refactor it to accept the OAuth-shaped input by adding a pre-step that normalizes either source into a common shape `{five_hour: {used_percentage, resets_at}, seven_day: {used_percentage, resets_at}}`. Don't duplicate the level/pace logic — keep one source of truth for posture math.

6. **`_bishop_status` (human output)** — append a new line after the existing posture summary:
   ```
   models:  sonnet 100% EXHAUSTED (resets 30h)*  opus none  haiku none
   ```
   - `*` after the model name when `extra_usage.is_enabled == true` AND that model is exhausted (i.e., we're in overage).
   - When a model is `null` in the output, print `none` (means: no plan-specific bucket for that model — only the aggregate applies).
   - When no per-model fields exist (fallback source), print `models: aggregate only (no per-model data — bishop-fetch-usage failed)`.

   Also print extra_usage if present and is_enabled:
   ```
   overage: $156.50 used (allowed)
   ```
   (`used_credits` is in the response's `currency`; format as dollars when `currency == "USD"`. Skip the line entirely when `is_enabled == false`.)

7. **`_bishop_help`** — document the new env vars:
   ```
   BISHOP_USAGE_FETCH_CMD       Path to bishop-fetch-usage helper
                                (default: alongside bishop binary).
   BISHOP_USAGE_CACHE_PATH      Cached OAuth usage response
                                (default: ~/.claude/oauth-usage.json).
   BISHOP_USAGE_CACHE_TTL_SECONDS  Max age before re-fetching (default: 55).
   ```
   Also add a note: "Requires macOS keychain access. On Linux or where the keychain entry is absent, falls back to legacy Mother aggregate source."

### Bishop: `tests/bishop.bats` additions

Use `BISHOP_USAGE_FETCH_CMD=/path/to/mock-script` to inject fixture responses. Cover:

- (a) Fresh OAuth fetch with sonnet at 100% → `source == "oauth_usage"`, `models.sonnet.status == "exhausted"`, `exhausted_models == ["sonnet"]`.
- (b) `seven_day_opus: null` in response → `models.opus == null`, NOT in `exhausted_models`.
- (c) `extra_usage.is_enabled: true` with `used_credits: 15650` → output's `extra_usage` block matches input.
- (d) Stale cache (mtime older than TTL) AND fetch script exits non-zero → cache is still used, but `stale_input: true` and log warning written.
- (e) No fetch script + no cache file → falls back to `BISHOP_SOURCE_PATH` (existing legacy behavior); `source == "mother_aggregate"`; `models == {sonnet: null, opus: null, haiku: null}`; `exhausted_models == []`.
- (f) `resets_at` in the past → `models.<name>` is `null` (stale-bucket-already-reset guard).
- (g) Existing posture tests continue to pass with the OAuth source format (i.e., the jq normalization step handles both shapes).

### Bishop: `README.md` update

Brief section: "Data sources" describes the OAuth endpoint as primary, Mother aggregate as fallback. Note macOS-only auth. Mention the 60s polling rationale.

### Dotfile: `/Users/hammer/.claude/bin/tmux-rate-limits`

After the existing posture chip block, add an "exhausted models" chip:

```bash
_exhausted_seg=""
if [ -f "$_posture_file" ]; then
    _exhausted=$(python3 -c "
import json
try:
    d = json.load(open('$_posture_file'))
    ms = d.get('models') or {}
    eu = d.get('extra_usage') or {}
    overage = bool(eu.get('is_enabled'))
    out = []
    for name in ('sonnet','opus','haiku'):
        m = ms.get(name)
        if m and m.get('status') == 'exhausted':
            out.append(name + ('*' if overage else ''))
    print(' '.join(out))
except Exception:
    pass
" 2>/dev/null)
    if [ -n "$_exhausted" ]; then
        _exhausted_seg="#[fg=colour208]⚠ ${_exhausted}#[fg=colour245]  "
    fi
fi
```

Prepend `$_exhausted_seg` to the final output (before the existing posture chip and rate-limit parts). Degrade silently when the field is missing or the file is unreadable.

## Approach / build order

1. **Phase 1 — `bishop-fetch-usage` helper.** Write the standalone script. Test manually: confirm it returns the expected JSON when invoked, exits 2 with no token, exits 3 on a rate-limit response. Don't touch Bishop yet.

2. **Phase 2 — Bishop refresh + JQ programs.** Refactor `_bishop_refresh` to try OAuth first, fall back to Mother aggregate. Add the new jq program. Wire env vars. Make sure existing behavior (when OAuth fails or is unavailable) is exactly preserved.

3. **Phase 3 — Bishop output schema + status output.** Add `models`, `exhausted_models`, `extra_usage`, `source` to `budget-posture.json`. Update `_bishop_status` human output. Update `_bishop_help`. Update README.

4. **Phase 4 — bats tests.** Cover all seven cases above. Confirm all existing tests still pass.

5. **Phase 5 — tmux statusline chip.** Edit `/Users/hammer/.claude/bin/tmux-rate-limits`. Smoke-test with a hand-written fixture posture file. Note the dotfile edit in the PR summary so the user can commit it separately.

6. Open one PR against `origin/main` for Bishop.

## Acceptance criteria

- `bin/bishop-fetch-usage` returns valid JSON matching the documented OAuth response shape when run on a healthy machine.
- `bishop --refresh` writes `~/.claude/budget-posture.json` with new fields: `source`, `models`, `exhausted_models`, `extra_usage`.
- `bishop status --json | jq '.models.sonnet.status'` returns `"exhausted"` when sonnet utilization is 100%.
- `bishop status --json | jq '.exhausted_models'` returns `["sonnet"]` in that same case.
- `bishop status --json | jq '.models.opus'` returns `null` when the response has `seven_day_opus: null`.
- `bishop status --json | jq '.source'` returns `"oauth_usage"` on a healthy fetch, `"mother_aggregate"` on fallback.
- `bishop status` (human) shows `models:` line and `overage: $X.XX used (allowed)` line when applicable.
- Cache TTL works: two `bishop --refresh` calls within 55s result in only one OAuth fetch.
- 429 from the endpoint does not corrupt the cache file; the previous good response is preserved.
- All existing bats tests still pass; new bats cases cover the seven scenarios listed.
- tmux statusline shows `⚠ sonnet*` chip when sonnet is exhausted AND `extra_usage.is_enabled == true`; degrades silently otherwise.
- PR body explains the design and references the OAuth endpoint by name and beta header.

## Out of scope

- Linux / WSL keychain support (only macOS).
- Tracking per-minute API limits (this endpoint only covers 5h / 7d / plan windows).
- Showing `extra_usage` projections or burn-rate forecasts.
- Removing Mother's `rate_limits.json` capture — keep it as fallback for robustness.
- Garbage-collecting `oauth-usage.json` cache file. It's overwritten on every successful refresh; no growth concern.
- Multi-account support. One user, one token.
- Posture-level logic changes. Existing pace/level computation stays exactly as-is.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "Bishop refactor with new auth path, JQ normalization, atomic caching, 429 handling, statusline integration. Fallback path correctness matters as much as the happy path."
  redd:
    model: opus
    effort: high
    rationale: "Seven new bats cases covering source-fallback, stale-cache, null-buckets, past-reset, and overage flag — each is a real failure mode and each must hold."
  marty:
    model: sonnet
    effort: medium
    rationale: "Normalize the two input shapes through one shared JQ helper rather than duplicating the posture math."
  perri:
    model: opus
    effort: high
    rationale: "Public-ish repo, auth via keychain, atomic writes on hot paths — reviewer must catch every non-atomic IO and every silent-failure footgun."
```
