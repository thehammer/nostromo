//! Behavioral tests for the CI failure cache in `perri_queue_native`.
//!
//! These tests verify that `ci_has_failure_cached` skips the check-suites API
//! call when the SHA is already in the cache, and makes exactly one call when
//! the SHA is new.
//!
//! The functions under test call `https://api.github.com/...` by default.
//! We redirect them to a `MockServer` via the `API_BASE_OVERRIDE` thread-local
//! that is compiled in under `#[cfg(test)]`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::json;
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use nostromo::data::perri_queue_native::ci_has_failure_cached;

// ── helpers ───────────────────────────────────────────────────────────────────

/// Build a `GithubClient` from a temp hosts.yml so we don't touch GITHUB_TOKEN
/// (which other parallel test threads may be using).
fn make_client() -> nostromo::data::github_client::GithubClient {
    let dir = tempfile::tempdir().unwrap();
    let hosts_path = dir.path().join("hosts.yml");
    std::fs::write(
        &hosts_path,
        "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
    )
    .unwrap();
    // Make sure GITHUB_TOKEN is not set so the hosts.yml path is used.
    // We use remove_var scoped here; other tests use their own clients.
    std::env::remove_var("GITHUB_TOKEN");
    nostromo::data::github_client::GithubClient::new(Some(&hosts_path))
        .expect("client should build from hosts.yml fixture")
}

/// Set the API base URL override for the duration of this test.
///
/// Each test runs on its own thread (tokio spawns one per `#[tokio::test]`
/// by default), so the thread-local is isolated between test cases.
fn set_api_base(uri: &str) {
    nostromo::data::perri_queue_native::API_BASE_OVERRIDE.with(|cell| {
        *cell.borrow_mut() = Some(uri.to_owned());
    });
}

// ── Test 1: cache hit — check-suites is never called ─────────────────────────

/// When the CI failure cache already contains a result for the PR's HEAD SHA,
/// `ci_has_failure_cached` must return the cached result without making a
/// check-suites API call.
///
/// We prove this by mounting the check-suites mock `up_to_n_times(1)` so that
/// a second HTTP request would fall through to wiremock's default 404 (which
/// would return `false`, masking an incorrect call).  Instead we assert on
/// `received_requests()` — exactly one check-suites call on the first cycle,
/// zero on the second cycle (cache hit).
#[tokio::test]
async fn cache_hit_skips_check_suites_call() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    // PR detail endpoint — returns SHA "sha-abc" on every call.
    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/42"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-abc" }
        })))
        .mount(&server)
        .await;

    // Check-suites endpoint — only allowed once.  A second call would still
    // return 200 (wiremock falls through to the next matching mock), but we
    // count requests below to assert zero additional calls.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-abc/check-suites"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_suites": [
                {
                    "app": { "name": "GitHub Actions" },
                    "conclusion": "success"
                }
            ]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_failure_cache: Arc<Mutex<HashMap<String, bool>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // First call — cache miss, should fetch check-suites once.
    let result1 = ci_has_failure_cached(
        &client,
        "acme/repo",
        42,
        &head_sha_cache,
        &ci_failure_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;
    assert!(!result1, "no failure suite — result should be false");

    let requests_after_first = server.received_requests().await.unwrap();
    let check_suites_count_after_first = requests_after_first
        .iter()
        .filter(|r| r.url.path().contains("check-suites"))
        .count();
    assert_eq!(
        check_suites_count_after_first, 1,
        "first call should hit check-suites exactly once"
    );

    // Second call — SHA unchanged, must be served from ci_failure_cache.
    let result2 = ci_has_failure_cached(
        &client,
        "acme/repo",
        42,
        &head_sha_cache,
        &ci_failure_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;
    assert!(!result2, "cached result should still be false");

    let requests_after_second = server.received_requests().await.unwrap();
    let check_suites_count_after_second = requests_after_second
        .iter()
        .filter(|r| r.url.path().contains("check-suites"))
        .count();
    assert_eq!(
        check_suites_count_after_second, 1,
        "second call with unchanged SHA must not hit check-suites again (cache hit)"
    );
}

// ── Test 2: new SHA — exactly one fresh check-suites call ────────────────────

/// When the PR's HEAD SHA changes between cycles, `ci_has_failure_cached` must
/// call the check-suites API exactly once for the new SHA and cache the result.
///
/// We simulate a SHA rotation: the PR detail endpoint returns "sha-old" on the
/// first call, then "sha-new" on the second call.  The check-suites mock is
/// mounted once per SHA.  After both calls we assert that two total
/// check-suites requests were made (one per distinct SHA), confirming a fresh
/// fetch on SHA change.
#[tokio::test]
async fn new_sha_triggers_exactly_one_check_suites_call() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    // PR detail — returns "sha-old" first, then "sha-new".
    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/7"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-old" }
        })))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/7"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-new" }
        })))
        .mount(&server)
        .await;

    // Check-suites for sha-old — indicates a failure.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-old/check-suites"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_suites": [
                {
                    "app": { "name": "GitHub Actions" },
                    "conclusion": "failure"
                }
            ]
        })))
        .mount(&server)
        .await;

    // Check-suites for sha-new — all passing.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-new/check-suites"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_suites": [
                {
                    "app": { "name": "GitHub Actions" },
                    "conclusion": "success"
                }
            ]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_failure_cache: Arc<Mutex<HashMap<String, bool>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // First call — sha-old, cache miss, should detect failure.
    let result1 = ci_has_failure_cached(
        &client,
        "acme/repo",
        7,
        &head_sha_cache,
        &ci_failure_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;
    assert!(
        result1,
        "sha-old has a failure suite — result should be true"
    );

    // Second call — sha-new (different SHA), cache miss on sha-new, should
    // fetch check-suites for the new SHA.
    let result2 = ci_has_failure_cached(
        &client,
        "acme/repo",
        7,
        &head_sha_cache,
        &ci_failure_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;
    assert!(!result2, "sha-new has no failures — result should be false");

    let all_requests = server.received_requests().await.unwrap();
    let check_suites_calls: Vec<_> = all_requests
        .iter()
        .filter(|r| r.url.path().contains("check-suites"))
        .collect();

    assert_eq!(
        check_suites_calls.len(),
        2,
        "each distinct SHA must trigger exactly one check-suites call (got {})",
        check_suites_calls.len()
    );

    // Verify each SHA was fetched once specifically.
    let old_calls = check_suites_calls
        .iter()
        .filter(|r| r.url.path().contains("sha-old"))
        .count();
    let new_calls = check_suites_calls
        .iter()
        .filter(|r| r.url.path().contains("sha-new"))
        .count();

    assert_eq!(old_calls, 1, "sha-old check-suites should be called once");
    assert_eq!(new_calls, 1, "sha-new check-suites should be called once");
}
