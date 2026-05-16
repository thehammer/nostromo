# perri-rl-fix-2: Cache `ci_has_failure` results by HEAD SHA

## Problem

In `src/data/perri_queue_native.rs`, `ci_has_failure(client, repo, pr_number)` is called once per PR per refresh cycle for buckets 1+2 (and again for matched bucket-3 PRs). Each call makes **two** API requests: `get_pr_head_sha` and a `check-suites` fetch.

With 10 PRs in buckets 1+2, that's 20 calls per minute = 1200/hour just for CI status, even though the underlying check results rarely change (only on a new push to the PR).

## Fix

Cache `ci_has_failure` results keyed by the HEAD SHA. SHAs are immutable, so a cached entry remains valid until the PR head moves (new push) — at which point `get_pr_head_sha` returns a new SHA and the cache miss triggers a fresh fetch.

Two layers:
1. Cache `pr_number -> head_sha` per `(repo, pr_number)`. Refresh the SHA every cycle (1 call per PR per cycle, unavoidable — same cost as today).
2. Cache `head_sha -> bool` for the actual check-suites result. **Skipped entirely** when the SHA hasn't changed since the last cycle.

Net: when no PRs have new pushes, the `check-suites` call drops to **zero** per cycle. Only `get_pr_head_sha` remains, halving the bucket-1+2 CI overhead.

Future iteration (separate plan, `perri-rl-fix-3`): replace the SHA fetch with `If-None-Match` to make even that drop to a 304.

## Implementation

In `PerriQueueNativeSource::run`, alongside the other caches:

```rust
let mut head_sha_cache: HashMap<(String, u64), String> = HashMap::new();
let mut ci_failure_cache: HashMap<String, bool> = HashMap::new(); // keyed by SHA
```

Thread both through `fetch` and into a refactored helper:

```rust
async fn ci_has_failure_cached(
    client: &GithubClient,
    repo: &str,
    number: u64,
    head_sha_cache: &mut HashMap<(String, u64), String>,
    ci_failure_cache: &mut HashMap<String, bool>,
) -> bool {
    let sha = match get_pr_head_sha(client, repo, number).await {
        Some(s) => s,
        None => return false,
    };
    head_sha_cache.insert((repo.to_owned(), number), sha.clone());
    if let Some(&cached) = ci_failure_cache.get(&sha) {
        return cached;
    }
    let result = fetch_check_suites_failure(client, repo, &sha).await;
    ci_failure_cache.insert(sha, result);
    result
}
```

Where `fetch_check_suites_failure` is the existing body of `ci_has_failure` (minus the `get_pr_head_sha` call), extracted for reuse.

**Concurrency**: the existing `join_all` over bucket-1+2 futures cannot share `&mut` caches across futures. Two options:
- (a) Wrap caches in `Arc<Mutex<...>>` so async tasks can lock briefly.
- (b) Serialise the CI checks (drop the `join_all`) — fine because we now skip most of them on cache hit.

Pick (a) for minimal behaviour change. The Mutex is held only briefly across `insert`/`get`, no `.await` while holding it.

Cache invalidation: SHAs in `ci_failure_cache` accumulate forever. Add a final pass after `join_all` that prunes entries not in the current `head_sha_cache` value-set. Tiny set, no performance concern.

## Acceptance criteria

- A back-to-back-cycle test with the same PR list and unchanged SHAs issues **zero** `check-suites` calls on the second cycle (verified via test counter).
- A test simulating a new head SHA on one PR triggers exactly one fresh `check-suites` call, all others stay cached.
- Bucket-1+2 inclusion behaviour unchanged.
- `cargo test` and `cargo clippy --all-targets -- -D warnings` green.

## Files

- `src/data/perri_queue_native.rs` — only file to modify.

## Out of scope

- ETag caching on `/check-suites` (separate plan, perri-rl-fix-3).
- Bucket-3 review-state caching (separate plan, perri-rl-fix-1 — already landed first).
- Search-query frequency reduction.

```yaml
no_pr: true
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Concurrent cache access under Mutex with brief locks; correct invalidation logic is the failure mode."
  redd:
    model: sonnet
    effort: medium
    rationale: "Two behavioural tests (no SHA change → 0 calls; SHA change → 1 call) — these tests are the proof the fix works."
  marty:
    model: sonnet
    effort: low
    rationale: "downgrade: extraction of helper functions; small refactor pass after the renderer."
  perri:
    model: sonnet
    effort: medium
    rationale: "Check that Mutex is never held across .await; check that ci_failure_cache pruning doesn't leak old SHAs."
```
