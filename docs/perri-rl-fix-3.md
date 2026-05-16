# perri-rl-fix-3: ETag caching on per-endpoint GitHub calls

## Problem

After `perri-rl-fix-1` (review-state cache) and `perri-rl-fix-2` (CI-by-SHA cache), the remaining per-cycle calls are:

- `get_pr_head_sha` for every bucket-1+2 candidate — one call per PR per cycle, every cycle, always re-fetches even if PR hasn't moved.
- The first-time `check-suites` fetch for a new SHA.
- The first-time `get_our_last_review` fetch for a PR with new `updated_at`.

GitHub's REST API honours `If-None-Match` on all three endpoints. A 304 response **does not count against the rate limit**. ETag caching on these individual endpoints drops most cache-miss paths to free 304s.

## Fix

Generalise the ETag pattern already used by `search_issues` into a helper, and apply it to:

- `get_pr_head_sha` (GET `/repos/{repo}/pulls/{number}`)
- `fetch_check_suites_failure` (GET `/repos/{repo}/commits/{sha}/check-suites`)
- `get_our_last_review` (GET `/repos/{repo}/pulls/{number}/reviews`)

Each gets a per-URL ETag map and a per-URL body cache.

## Implementation

New helper at the bottom of `perri_queue_native.rs`:

```rust
/// Conditional GET helper. On 304, returns the cached body; otherwise fetches,
/// stores the new ETag + body, and returns the body. Bodies are stored as
/// strings (the caller deserialises) so this helper isn't generic over T.
async fn etag_get(
    client: &GithubClient,
    url: &str,
    etags: &mut HashMap<String, String>,
    body_cache: &mut HashMap<String, String>,
) -> Option<String> {
    let mut headers = base_headers(client);
    if let Some(etag) = etags.get(url) {
        headers.insert(IF_NONE_MATCH, etag.parse().ok()?);
    }
    let resp = client.http.get(url).headers(headers).send().await.ok()?;
    if let Some(etag) = resp.headers().get("etag").and_then(|v| v.to_str().ok()) {
        etags.insert(url.to_owned(), etag.to_owned());
    }
    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        return body_cache.get(url).cloned();
    }
    if !resp.status().is_success() {
        return None;
    }
    let body = resp.text().await.ok()?;
    body_cache.insert(url.to_owned(), body.clone());
    Some(body)
}
```

Update the three call sites to use it. ETag + body caches owned by `run()` and threaded into `fetch()` like the existing maps. Since this helper deserialises JSON in the caller, each call site does its own `serde_json::from_str(&body)`.

Concurrency: the bucket-1+2 `join_all` already wraps caches in `Arc<Mutex<...>>` per fix-2. Add ETag + body caches to that bundle.

## Acceptance criteria

- A no-change back-to-back-cycle test where Bishop counts upstream calls: second cycle's HTTP traffic is **all 304s** (still 1 round-trip per endpoint, but does not consume rate limit budget). Verified via a mock that asserts every conditional request gets `If-None-Match` and returns 304.
- When the upstream returns 200 with a fresh ETag, the cache is updated and the next 304 hits the cached body correctly.
- All earlier behavioural tests from fix-1 / fix-2 still pass.
- `cargo test` and `cargo clippy --all-targets -- -D warnings` green.

## Files

- `src/data/perri_queue_native.rs` — only file to modify.

## Out of scope

- Search-query frequency reduction (separate concern).
- Right-panel / perri_pr_native.rs (different fetcher, separate fix if needed).

```yaml
no_pr: true
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Generic ETag helper plus 3 call-site migrations. Bodies-as-strings simplifies the cache, but each site needs to handle the body-missing-from-cache fallback correctly."
  redd:
    model: sonnet
    effort: medium
    rationale: "Mock-based test verifying If-None-Match is sent and 304s are honoured. This test is the proof the fix is correct."
  marty:
    model: sonnet
    effort: low
    rationale: "downgrade: helper extraction, minimal restructure."
  perri:
    model: sonnet
    effort: medium
    rationale: "Reviewer checks: ETag values aren't dropped on transient errors, body cache misses on 304 are handled gracefully (re-fetch with no If-None-Match)."
```
