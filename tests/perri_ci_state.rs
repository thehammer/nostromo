//! Unit and integration tests for `CiState` mapping, rollup precedence,
//! and the `ci_state_cached` check-runs integration.
//!
//! Tests mirror the D1 table and rollup spec from the plan, and the D2
//! Actions-vs-non-Actions filter-bool contract.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::json;
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use nostromo::data::perri_queue::CiState;
use nostromo::data::perri_queue_native::ci_state_cached;

// ── D1 table: CiState::from_check ────────────────────────────────────────────

#[test]
fn failure_conclusions_map_to_failure() {
    for conclusion in &["failure", "timed_out", "action_required", "stale"] {
        assert_eq!(
            CiState::from_check(Some("completed"), Some(conclusion)),
            CiState::Failure,
            "conclusion {conclusion} should map to Failure"
        );
    }
}

#[test]
fn success_conclusion_maps_to_success() {
    assert_eq!(
        CiState::from_check(Some("completed"), Some("success")),
        CiState::Success
    );
}

#[test]
fn skipped_cancelled_neutral_map_to_unknown() {
    for conclusion in &["skipped", "cancelled", "neutral"] {
        assert_eq!(
            CiState::from_check(Some("completed"), Some(conclusion)),
            CiState::Unknown,
            "conclusion {conclusion} should map to Unknown"
        );
    }
}

#[test]
fn unknown_conclusion_maps_to_unknown() {
    assert_eq!(
        CiState::from_check(Some("completed"), Some("something_else")),
        CiState::Unknown
    );
}

#[test]
fn pending_statuses_with_null_conclusion_map_to_pending() {
    for status in &["queued", "in_progress", "waiting", "pending", "requested"] {
        assert_eq!(
            CiState::from_check(Some(status), None),
            CiState::Pending,
            "status {status} with null conclusion should map to Pending"
        );
    }
}

#[test]
fn null_status_and_null_conclusion_map_to_unknown() {
    assert_eq!(CiState::from_check(None, None), CiState::Unknown);
}

#[test]
fn unknown_status_with_null_conclusion_maps_to_unknown() {
    assert_eq!(
        CiState::from_check(Some("completed"), None),
        CiState::Unknown
    );
}

// ── CiState::rollup precedence ────────────────────────────────────────────────

#[test]
fn rollup_empty_is_unknown() {
    assert_eq!(CiState::rollup(vec![]), CiState::Unknown);
}

#[test]
fn rollup_failure_beats_all() {
    assert_eq!(
        CiState::rollup(vec![
            CiState::Success,
            CiState::Pending,
            CiState::Failure,
            CiState::Unknown
        ]),
        CiState::Failure
    );
}

#[test]
fn rollup_pending_beats_success_and_unknown() {
    assert_eq!(
        CiState::rollup(vec![CiState::Success, CiState::Pending, CiState::Unknown]),
        CiState::Pending
    );
}

#[test]
fn rollup_success_beats_unknown() {
    assert_eq!(
        CiState::rollup(vec![CiState::Success, CiState::Unknown]),
        CiState::Success
    );
}

#[test]
fn rollup_all_unknown_is_unknown() {
    assert_eq!(
        CiState::rollup(vec![CiState::Unknown, CiState::Unknown]),
        CiState::Unknown
    );
}

#[test]
fn rollup_single_success_is_success() {
    assert_eq!(CiState::rollup(vec![CiState::Success]), CiState::Success);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

fn set_api_base(uri: &str) {
    nostromo::data::perri_queue_native::API_BASE_OVERRIDE.with(|cell| {
        *cell.borrow_mut() = Some(uri.to_owned());
    });
}

// ── Integration: ci_state_cached — mixed runs, Actions vs non-Actions filter ─

/// Mounts a check-runs response with:
///   - one passing GitHub Actions run
///   - one failing non-Actions run (should NOT set the filter bool)
///   - one pending Actions run
///
/// Expected: display state = Failure (failing non-Actions → Failure via D1),
///           filter bool = false (only Actions failures trigger filter).
#[tokio::test]
async fn ci_state_cached_non_actions_failure_does_not_set_filter_bool() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/10"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-mixed" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-mixed/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_runs": [
                {
                    "name": "build",
                    "status": "completed",
                    "conclusion": "success",
                    "id": 1,
                    "app": { "slug": "github-actions" },
                    "output": {}
                },
                {
                    "name": "external-check",
                    "status": "completed",
                    "conclusion": "failure",
                    "id": 2,
                    "app": { "slug": "some-other-tool" },
                    "output": {}
                },
                {
                    "name": "lint",
                    "status": "in_progress",
                    "conclusion": null,
                    "id": 3,
                    "app": { "slug": "github-actions" },
                    "output": {}
                }
            ]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let (display_state, filter_bool) = ci_state_cached(
        &client,
        "acme/repo",
        10,
        &head_sha_cache,
        &ci_state_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;

    // Display state: rollup of success + failure(non-Actions) + pending → Failure.
    assert_eq!(
        display_state,
        CiState::Failure,
        "non-Actions failure should still show as Failure in display rollup"
    );

    // Filter bool: no GitHub Actions run failed → must be false.
    assert!(
        !filter_bool,
        "non-Actions failure must NOT set the filter bool"
    );
}

/// A GitHub Actions run with conclusion=failure sets the filter bool AND
/// display state to Failure.
#[tokio::test]
async fn ci_state_cached_actions_failure_sets_filter_bool() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/20"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-actions-fail" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-actions-fail/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_runs": [
                {
                    "name": "build",
                    "status": "completed",
                    "conclusion": "failure",
                    "id": 99,
                    "app": { "slug": "github-actions" },
                    "output": {}
                }
            ]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let (display_state, filter_bool) = ci_state_cached(
        &client,
        "acme/repo",
        20,
        &head_sha_cache,
        &ci_state_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;

    assert_eq!(display_state, CiState::Failure);
    assert!(
        filter_bool,
        "GitHub Actions failure should set the filter bool"
    );
}

/// All runs successful → Success display state, filter bool false.
#[tokio::test]
async fn ci_state_cached_all_success() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/30"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-all-success" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-all-success/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_runs": [
                {
                    "name": "build",
                    "status": "completed",
                    "conclusion": "success",
                    "id": 1,
                    "app": { "slug": "github-actions" },
                    "output": {}
                },
                {
                    "name": "test",
                    "status": "completed",
                    "conclusion": "success",
                    "id": 2,
                    "app": { "slug": "github-actions" },
                    "output": {}
                }
            ]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let (display_state, filter_bool) = ci_state_cached(
        &client,
        "acme/repo",
        30,
        &head_sha_cache,
        &ci_state_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;

    assert_eq!(display_state, CiState::Success);
    assert!(!filter_bool);
}

/// Cache hit: second call with same SHA does not make a second check-runs request.
#[tokio::test]
async fn ci_state_cached_cache_hit_no_second_call() {
    let server = MockServer::start().await;
    set_api_base(&server.uri());

    let client = make_client();

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/40"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "head": { "sha": "sha-cache-test" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/sha-cache-test/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_runs": [{
                "name": "build",
                "status": "completed",
                "conclusion": "success",
                "id": 1,
                "app": { "slug": "github-actions" },
                "output": {}
            }]
        })))
        .mount(&server)
        .await;

    let head_sha_cache: Arc<Mutex<HashMap<(String, u64), String>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let ci_state_cache: Arc<Mutex<HashMap<String, (CiState, bool)>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let endpoint_etags: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let endpoint_body_cache: Arc<Mutex<HashMap<String, String>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // First call.
    let _ = ci_state_cached(
        &client,
        "acme/repo",
        40,
        &head_sha_cache,
        &ci_state_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;

    // Second call — should hit cache.
    let _ = ci_state_cached(
        &client,
        "acme/repo",
        40,
        &head_sha_cache,
        &ci_state_cache,
        &endpoint_etags,
        &endpoint_body_cache,
    )
    .await;

    let reqs = server.received_requests().await.unwrap();
    let check_runs_calls = reqs
        .iter()
        .filter(|r| r.url.path().contains("check-runs"))
        .count();
    assert_eq!(
        check_runs_calls, 1,
        "second call with same SHA must not make another check-runs request"
    );
}
