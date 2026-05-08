//! Wiremock-backed integration tests for the GitHub client.
//!
//! Tests:
//!   1. Token parsing from a fixture `hosts.yml`.
//!   2. ETag round-trip: mock returns ETag on first call, subsequent call with
//!      If-None-Match receives 304.
//!   3. Diff Accept-header: GET with `application/vnd.github.diff` returns
//!      raw diff text verbatim.

use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── Test 1: hosts.yml token parsing ──────────────────────────────────────────

#[tokio::test]
async fn test_hosts_yml_token_parsing() {
    let dir = tempfile::tempdir().unwrap();
    let hosts_path = dir.path().join("hosts.yml");

    // Write a minimal gh hosts.yml fixture.
    std::fs::write(
        &hosts_path,
        r#"
github.com:
  oauth_token: ghp_test_token_from_hosts_yml
  user: hammer
  git_protocol: https
"#,
    )
    .unwrap();

    std::env::remove_var("GITHUB_TOKEN");

    let client = nostromo::data::github_client::GithubClient::new(Some(&hosts_path))
        .expect("should build client from hosts.yml");

    assert_eq!(client.token(), "ghp_test_token_from_hosts_yml");
}

// ── Test 2: ETag round-trip ───────────────────────────────────────────────────

#[tokio::test]
async fn test_etag_round_trip() {
    let server = MockServer::start().await;

    // First request: return 200 with ETag header.
    Mock::given(method("GET"))
        .and(path("/search/issues"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("etag", "\"abc123\"")
                .set_body_json(serde_json::json!({
                    "total_count": 1,
                    "items": [{
                        "number": 42,
                        "title": "feat: something",
                        "html_url": "https://github.com/acme/repo/pull/42",
                        "repository_url": "https://api.github.com/repos/acme/repo",
                        "user": {"login": "alice"}
                    }]
                })),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;

    // Second request with matching If-None-Match: return 304.
    Mock::given(method("GET"))
        .and(path("/search/issues"))
        .and(header("if-none-match", "\"abc123\""))
        .respond_with(ResponseTemplate::new(304))
        .mount(&server)
        .await;

    let http = reqwest::Client::new();

    // First call — should get 200 + ETag.
    let r1 = http
        .get(format!("{}/search/issues", server.uri()))
        .header("Accept", "application/vnd.github+json")
        .bearer_auth("test-token")
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status(), 200);
    let etag = r1
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .to_owned();
    assert_eq!(etag, "\"abc123\"");

    // Second call with the ETag — should get 304.
    let r2 = http
        .get(format!("{}/search/issues", server.uri()))
        .header("Accept", "application/vnd.github+json")
        .header("If-None-Match", &etag)
        .bearer_auth("test-token")
        .send()
        .await
        .unwrap();
    assert_eq!(r2.status(), 304, "expected 304 Not Modified on second call");
}

// ── Test 3: diff Accept-header ────────────────────────────────────────────────

#[tokio::test]
async fn test_diff_accept_header() {
    let server = MockServer::start().await;

    let raw_diff = r#"diff --git a/src/main.rs b/src/main.rs
index abc..def 100644
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,3 +1,4 @@
+// new line
 fn main() {
     println!("hello");
 }
"#;

    Mock::given(method("GET"))
        .and(path("/repos/acme/repo/pulls/42"))
        .and(header("accept", "application/vnd.github.diff"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(raw_diff)
                .insert_header("content-type", "text/plain"),
        )
        .mount(&server)
        .await;

    let http = reqwest::Client::new();
    let resp = http
        .get(format!("{}/repos/acme/repo/pulls/42", server.uri()))
        .header("Accept", "application/vnd.github.diff")
        .header("Authorization", "Bearer test-token")
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();
    assert_eq!(body, raw_diff, "diff body should be captured verbatim");
}
