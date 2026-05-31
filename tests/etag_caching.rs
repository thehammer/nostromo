//! Behavioral integration tests for ETag caching on GitHub per-endpoint calls.
//!
//! These tests verify that `fetch_check_suites_failure` (which delegates to the
//! private `etag_get` helper) correctly:
//!
//!   1. Sends `If-None-Match` on the second request after receiving an ETag
//!      on the first.
//!   2. Returns the cached body on 304 — no redundant re-fetch and correct result.
//!
//! Mocks are provided by `wiremock`.  All HTTP is redirected to the mock server
//! via the `API_BASE_OVERRIDE` thread-local.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::json;
use wiremock::matchers::{header, method, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use nostromo::data::perri_queue_native::{fetch_check_suites_failure, API_BASE_OVERRIDE};

// ── helpers ───────────────────────────────────────────────────────────────────

/// Build a `GithubClient` from a temp hosts.yml so we don't require
/// GITHUB_TOKEN to be set in the environment.
fn make_client() -> nostromo::data::github_client::GithubClient {
    let dir = tempfile::tempdir().unwrap();
    let hosts_path = dir.path().join("hosts.yml");
    std::fs::write(
        &hosts_path,
        "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
    )
    .unwrap();
    std::env::remove_var("GITHUB_TOKEN");
    nostromo::data::github_client::GithubClient::new(Some(&hosts_path))
        .expect("client should build from hosts.yml fixture")
}

/// Point all GitHub API calls at the mock server for the duration of this test.
///
/// Each `#[tokio::test]` runs on its own OS thread, so the thread-local is
/// isolated between test cases.
fn set_api_base(uri: &str) {
    API_BASE_OVERRIDE.with(|cell| {
        *cell.borrow_mut() = Some(uri.to_owned());
    });
}

// ── Test 1 ────────────────────────────────────────────────────────────────────

/// After the server returns a 200 with `ETag: "suite-etag-1"`, the second call
/// must include `If-None-Match: "suite-etag-1"` and the server responds 304.
///
/// We assert:
///   - Both calls return `false` (no failure suites in the body).
///   - Exactly two requests reached the server.
///   - The second request carried the `If-None-Match` header with the value
///     from the first response's ETag.
#[tokio::test]
async fn fetch_check_suites_sends_if_none_match_on_second_call() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    // First call: 200 with ETag + a passing-only suite.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-xyz/check-suites"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("ETag", "\"suite-etag-1\"")
                .set_body_json(json!({
                    "check_suites": [
                        {
                            "app": { "name": "GitHub Actions" },
                            "conclusion": "success"
                        }
                    ]
                })),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;

    // Second call: matched by presence of the correct If-None-Match header → 304.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-xyz/check-suites"))
        .and(header("if-none-match", "\"suite-etag-1\""))
        .respond_with(ResponseTemplate::new(304))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    let etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let body_cache: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));

    // First call — 200, should return false (success suite, not failure).
    let result1 =
        fetch_check_suites_failure(&client, "acme/repo", "sha-xyz", &etags, &body_cache).await;
    assert!(
        !result1,
        "success-only suite must return false on first call"
    );

    // Second call — should trigger 304, serve body from cache, still false.
    let result2 =
        fetch_check_suites_failure(&client, "acme/repo", "sha-xyz", &etags, &body_cache).await;
    assert!(
        !result2,
        "cached body on 304 must still return false (no failures)"
    );

    // Inspect what the server actually received.
    let all_reqs = server.received_requests().await.unwrap();
    let suite_reqs: Vec<_> = all_reqs
        .iter()
        .filter(|r| r.url.path().contains("check-suites"))
        .collect();

    assert_eq!(
        suite_reqs.len(),
        2,
        "expected exactly 2 requests to check-suites (one 200, one 304); got {}",
        suite_reqs.len()
    );

    // The second request must carry If-None-Match.
    let second_req = suite_reqs[1];
    let inm_header = second_req
        .headers
        .get("if-none-match")
        .and_then(|v| v.to_str().ok());

    assert_eq!(
        inm_header,
        Some("\"suite-etag-1\""),
        "second request must send If-None-Match with the ETag from the first response"
    );
}

// ── Test 2 ────────────────────────────────────────────────────────────────────

/// Full round-trip: a 200 stores the ETag and body; a subsequent 304 returns
/// the cached body, preserving the original result.
///
/// This test uses a *failure* body so we can distinguish a correct cache-hit
/// (true) from a misread empty body (false).
///
/// We assert:
///   - First call (200, failure suite) returns `true`.
///   - Second call (304) returns `true` — served from body cache.
///   - The second request sent `If-None-Match: "v1"`.
#[tokio::test]
async fn fresh_etag_on_200_updates_cache_and_304_returns_cached_body() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    // First call: 200 with ETag "v1" + a failure suite.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-fail/check-suites"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("ETag", "\"v1\"")
                .set_body_json(json!({
                    "check_suites": [
                        {
                            "app": { "name": "GitHub Actions" },
                            "conclusion": "failure"
                        }
                    ]
                })),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;

    // Second call: matched by If-None-Match header → 304, no body.
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-fail/check-suites"))
        .and(header("if-none-match", "\"v1\""))
        .respond_with(ResponseTemplate::new(304))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    let etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let body_cache: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));

    // First call — 200 with failure body → true.
    let result1 =
        fetch_check_suites_failure(&client, "acme/repo", "sha-fail", &etags, &body_cache).await;
    assert!(
        result1,
        "failure suite on first 200 response must return true"
    );

    // Second call — 304, body served from cache → still true.
    let result2 =
        fetch_check_suites_failure(&client, "acme/repo", "sha-fail", &etags, &body_cache).await;
    assert!(
        result2,
        "304 must serve cached body — result must still be true (failure suite cached)"
    );

    // Verify the second request carried If-None-Match: "v1".
    let all_reqs = server.received_requests().await.unwrap();
    let suite_reqs: Vec<_> = all_reqs
        .iter()
        .filter(|r| r.url.path().contains("check-suites"))
        .collect();

    assert_eq!(
        suite_reqs.len(),
        2,
        "expected exactly 2 check-suites requests (one 200, one 304); got {}",
        suite_reqs.len()
    );

    let second_req = suite_reqs[1];
    let inm_value = second_req
        .headers
        .get("if-none-match")
        .and_then(|v| v.to_str().ok());

    assert_eq!(
        inm_value,
        Some("\"v1\""),
        "second request must send If-None-Match: \"v1\""
    );
}
