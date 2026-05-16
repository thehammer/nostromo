# perri-rl-fix-1: Pre-filter bucket 3 by `updated_at` to skip redundant review-state fetches

## Problem

In `src/data/perri_queue_native.rs`, every 60-second refresh fetches `reviewed-by:@me` (up to 100 PRs), then for **each** PR makes a `get_our_last_review` API call to GitHub. This is the dominant rate-limit consumer — with 50 historical reviewed PRs, that's 3000 calls/hour just for review-state.

## Fix

Cache `updated_at` per `(repo, number)` across refresh cycles. Only call `get_our_last_review` when the PR's `updated_at` has changed since the last seen value. The vast majority of historical reviewed PRs won't have moved since the last cycle, so the call is skipped.

Additionally, persist the **last seen review state** (`state: String, submitted_at: Option<String>`) per `(repo, number)`, so when `updated_at` hasn't changed, the previously fetched review can still satisfy the bucket-3 inclusion check.

## Implementation

In `PerriQueueNativeSource::run`:

```rust
let mut last_seen_updated: HashMap<(String, u64), String> = HashMap::new();
let mut review_state_cache: HashMap<(String, u64), (String, Option<String>)> = HashMap::new();
```

Thread both through `fetch(...)` as `&mut`.

In `fetch(...)` bucket-3 logic, before kicking off the futures:
- For each candidate, check whether `last_seen_updated.get((repo, num)) == item.updated_at`.
- If yes and `review_state_cache` has an entry, USE the cached review-state tuple instead of calling `get_our_last_review`.
- Otherwise, fall through to the normal API call and **insert/update** the cache with the fresh tuple.

The simplest threading is to have each bucket-3 future return `(key, Option<PrQueueItem>, Option<(String, Option<String>)>)` so the cache updates can be reduced after `join_all`. Keep the change localised — don't refactor the bucket-1/2 path.

After processing, also update `last_seen_updated` for every PR in `reviewed_items` (so unchanged PRs keep the most-recent timestamp marker).

## Acceptance criteria

- `get_our_last_review` is called at most once per PR per distinct `updated_at` value.
- Across two back-to-back 60s cycles with the same `reviewed-by:@me` results, the second cycle issues **zero** `get_our_last_review` calls (verified by an instrumentation log line or a unit test counting calls).
- `cargo test` and `cargo clippy --all-targets -- -D warnings` are green.
- Existing bucket-3 inclusion behaviour (only PRs with `CHANGES_REQUESTED + new_activity` appear) is unchanged. Add a test asserting this.

## Files

- `src/data/perri_queue_native.rs` — only file to modify.
- Add a small unit test in the same file under `#[cfg(test)]`.

## Out of scope

- ETag caching on `/reviews` endpoint (separate plan: `perri-rl-fix-3`).
- CI check caching (separate plan: `perri-rl-fix-2`).
- Reducing the search-query frequency.

```yaml
no_pr: true
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Focused cache plumbing in a single file. Care needed in the join_all reduction so review-state cache updates flow back correctly."
  redd:
    model: sonnet
    effort: medium
    rationale: "Behavioural test asserting zero get_our_last_review calls on the second back-to-back cycle."
  marty:
    model: sonnet
    effort: low
    rationale: "downgrade: small surface area, mostly additive. Light pass for tightening the closure capture pattern."
  perri:
    model: sonnet
    effort: medium
    rationale: "Reviewer checks closure capture pattern is panic-safe and cache updates aren't dropped on early returns."
```
