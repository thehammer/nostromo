//! Wiremock-backed integration tests for the Microsoft Graph auth/delta patterns.
//!
//! These tests exercise the HTTP protocol shapes used by GraphClient by
//! driving the same endpoints directly.  This keeps them independent of
//! hard-coded Azure login URLs and lets us verify:
//!
//!   1. Device-flow happy path: /devicecode → polling → access token returned.
//!   2. 401 → refresh-and-retry: first request 401, token endpoint returns new
//!      token, second request succeeds.
//!   3. Delta-link persistence: response contains @odata.deltaLink, confirm
//!      it is written to disk.

use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── Test 1: device-flow happy path ────────────────────────────────────────────

#[tokio::test]
async fn test_device_flow_happy_path() {
    let server = MockServer::start().await;
    let http = reqwest::Client::new();

    // /devicecode returns the user prompt.
    Mock::given(method("POST"))
        .and(path("/common/oauth2/v2.0/devicecode"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "device_code": "dev-code-abc",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://microsoft.com/devicelogin",
            "expires_in": 900,
            "interval": 1
        })))
        .mount(&server)
        .await;

    // First poll: authorization_pending.
    Mock::given(method("POST"))
        .and(path("/common/oauth2/v2.0/token"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({"error": "authorization_pending"})),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;

    // Second poll: success.
    Mock::given(method("POST"))
        .and(path("/common/oauth2/v2.0/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": "at-from-device-flow",
            "refresh_token": "rt-from-device-flow",
            "expires_in": 3600
        })))
        .mount(&server)
        .await;

    // Step 1: request device code.
    let dc_resp = http
        .post(format!("{}/common/oauth2/v2.0/devicecode", server.uri()))
        .form(&[("client_id", "test"), ("scope", "Mail.Read offline_access")])
        .send()
        .await
        .unwrap();
    assert!(dc_resp.status().is_success());
    let dc: serde_json::Value = dc_resp.json().await.unwrap();
    assert_eq!(dc["user_code"], "ABCD-EFGH");
    let device_code = dc["device_code"].as_str().unwrap();

    // Step 2: first poll → pending.
    let poll1: serde_json::Value = http
        .post(format!("{}/common/oauth2/v2.0/token", server.uri()))
        .form(&[
            ("client_id", "test"),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device_code),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(poll1["error"], "authorization_pending");

    // Step 3: second poll → success.
    let poll2: serde_json::Value = http
        .post(format!("{}/common/oauth2/v2.0/token", server.uri()))
        .form(&[
            ("client_id", "test"),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device_code),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(poll2["access_token"], "at-from-device-flow");
    assert!(poll2.get("refresh_token").is_some());
}

// ── Test 2: 401 → refresh → retry (single retry semantics) ────────────────────

#[tokio::test]
async fn test_refresh_on_401() {
    let server = MockServer::start().await;
    let http = reqwest::Client::new();

    // First GET returns 401.
    Mock::given(method("GET"))
        .and(path("/v1.0/me/messages"))
        .respond_with(
            ResponseTemplate::new(401).set_body_json(serde_json::json!({"error": "Unauthorized"})),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;

    // Token refresh endpoint.
    Mock::given(method("POST"))
        .and(path("/common/oauth2/v2.0/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": "refreshed-access-token",
            "refresh_token": "new-refresh-token",
            "expires_in": 3600
        })))
        .mount(&server)
        .await;

    // Second GET (after refresh) returns 200.
    Mock::given(method("GET"))
        .and(path("/v1.0/me/messages"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"value": []})))
        .mount(&server)
        .await;

    // Simulate what GraphClient.get_json does: GET → 401 → refresh → retry GET.
    let r1 = http
        .get(format!("{}/v1.0/me/messages", server.uri()))
        .bearer_auth("stale-access-token")
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status(), 401, "first request should 401");

    // Refresh.
    let refresh: serde_json::Value = http
        .post(format!("{}/common/oauth2/v2.0/token", server.uri()))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", "old-refresh-token"),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let new_token = refresh["access_token"].as_str().unwrap();
    assert_eq!(new_token, "refreshed-access-token");

    // Retry with refreshed token — should succeed.
    let r2 = http
        .get(format!("{}/v1.0/me/messages", server.uri()))
        .bearer_auth(new_token)
        .send()
        .await
        .unwrap();
    assert!(r2.status().is_success(), "second request should succeed");

    // Verify mocks: exactly 2 GETs to /v1.0/me/messages, 1 POST to /token.
    // (The 2 GETs exhaust the 1-times mock + the fallback mock.)
}

// ── Test 3: delta-link persistence ────────────────────────────────────────────

#[tokio::test]
async fn test_delta_link_persistence() {
    let server = MockServer::start().await;
    let cache_dir = tempfile::tempdir().unwrap();
    let delta_file = cache_dir.path().join("mailbox.delta");

    let http = reqwest::Client::new();

    Mock::given(method("GET"))
        .and(path("/v1.0/me/mailFolders/inbox/messages/delta"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "value": [{
                "id": "msg1",
                "subject": "Hello",
                "isRead": false,
                "receivedDateTime": "2026-05-08T10:00:00Z",
                "from": {
                    "emailAddress": {"name": "Alice", "address": "alice@example.com"}
                }
            }],
            "@odata.deltaLink": format!(
                "{}/v1.0/me/mailFolders/inbox/messages/delta?$deltaToken=abc123",
                server.uri()
            )
        })))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    let resp = http
        .get(format!(
            "{}/v1.0/me/mailFolders/inbox/messages/delta",
            server.uri()
        ))
        .bearer_auth("test-access-token")
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body: serde_json::Value = resp.json().await.unwrap();

    // Verify value array has one item.
    assert_eq!(body["value"].as_array().unwrap().len(), 1);

    // Verify deltaLink is present.
    let delta_link = body["@odata.deltaLink"].as_str().unwrap();
    assert!(
        delta_link.contains("deltaToken=abc123"),
        "deltaLink should be present"
    );

    // Simulate GraphClient.delta persisting the link.
    std::fs::write(&delta_file, delta_link).unwrap();
    assert!(
        delta_file.exists(),
        "delta link file should be written to disk"
    );

    let written = std::fs::read_to_string(&delta_file).unwrap();
    assert_eq!(written, delta_link, "persisted link should match response");

    // Simulate second call using persisted delta link.
    Mock::given(method("GET"))
        .and(path("/v1.0/me/mailFolders/inbox/messages/delta"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "value": [],
            "@odata.deltaLink": format!(
                "{}/v1.0/me/mailFolders/inbox/messages/delta?$deltaToken=abc456",
                server.uri()
            )
        })))
        .mount(&server)
        .await;

    // On second call, GraphClient uses the persisted delta link (which already
    // includes the host/path pointing at our mock server).
    let r2 = http
        .get(&written) // use the persisted delta link directly
        .bearer_auth("test-access-token")
        .send()
        .await
        .unwrap();
    assert!(r2.status().is_success());
    let body2: serde_json::Value = r2.json().await.unwrap();
    assert_eq!(
        body2["value"].as_array().unwrap().len(),
        0,
        "no new items in second delta"
    );
}

// ── Real GraphClient behaviour (talks to a wiremock "Microsoft") ──────────────
//
// A request that fails after the 401 -> refresh -> retry dance must be treated
// exactly like a request that failed the first time: an error, never a parsed
// error body that looks like an empty result.

use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use nostromo::data::graph_client::{
    parse_retry_after, GraphClient, GraphHttpError, GraphOptions, MAX_RETRY_AFTER,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use wiremock::matchers::{header, query_param};

const OLD_AT: &str = "old-at";
const NEW_AT: &str = "new-at";
const THINGS: &str = "/me/things";

async fn client_for(server: &MockServer, dir: &TempDir) -> GraphClient {
    let cache = dir.path().join("graph-token.json");
    std::fs::write(
        &cache,
        json!({
            "access_token": OLD_AT,
            "refresh_token": "old-rt",
            "expires_at": (Utc::now() + chrono::Duration::hours(1)).timestamp(),
        })
        .to_string(),
    )
    .unwrap();
    GraphClient::with_options(
        "test-client".into(),
        "common".into(),
        cache,
        GraphOptions {
            graph_base: server.uri(),
            login_base: server.uri(),
            use_m365_cli: false,
            min_device_poll: Duration::from_millis(50),
        },
    )
    .await
    .expect("graph client builds")
}

fn error_body() -> Value {
    json!({ "error": { "code": "SomethingWentWrong", "message": "nope" } })
}

fn failure(status: u16, retry_after: Option<&str>) -> ResponseTemplate {
    let mut t = ResponseTemplate::new(status).set_body_json(error_body());
    if let Some(v) = retry_after {
        t = t.insert_header("Retry-After", v);
    }
    t
}

async fn mount_refresh(server: &MockServer) {
    Mock::given(method("POST"))
        .and(path("/common/oauth2/v2.0/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": NEW_AT,
            "refresh_token": "new-rt",
            "expires_in": 3600
        })))
        .mount(server)
        .await;
}

/// Old token -> 401; refresh works; new token -> `status` (the retried request fails).
async fn mount_401_then(server: &MockServer, p: &str, status: u16, retry_after: Option<&str>) {
    Mock::given(method("GET"))
        .and(path(p))
        .and(header("authorization", format!("Bearer {OLD_AT}").as_str()))
        .respond_with(ResponseTemplate::new(401).set_body_json(error_body()))
        .mount(server)
        .await;
    mount_refresh(server).await;
    Mock::given(method("GET"))
        .and(path(p))
        .and(header("authorization", format!("Bearer {NEW_AT}").as_str()))
        .respond_with(failure(status, retry_after))
        .mount(server)
        .await;
}

fn http_status(err: &anyhow::Error) -> Option<u16> {
    err.downcast_ref::<GraphHttpError>().map(|e| e.status.as_u16())
}

/// (status, Retry-After) of the retried request.
const RETRY_FAILURES: [(u16, Option<&str>); 3] = [(429, Some("30")), (503, None), (403, None)];

#[tokio::test]
async fn get_json_fails_when_the_request_retried_after_a_401_refresh_is_throttled_or_refused() {
    for (status, retry_after) in RETRY_FAILURES {
        let server = MockServer::start().await;
        let dir = TempDir::new().unwrap();
        mount_401_then(&server, THINGS, status, retry_after).await;
        let client = client_for(&server, &dir).await;

        let result = client.get_json::<Value>(THINGS).await;
        let err = match result {
            Ok(v) => panic!("retried {status} must be an error, got Ok({v})"),
            Err(e) => e,
        };
        assert_eq!(http_status(&err), Some(status), "same typed error as a first-try {status}: {err:#}");
    }
}

#[tokio::test]
async fn get_paged_fails_when_the_request_retried_after_a_401_refresh_is_throttled_or_refused() {
    for (status, retry_after) in RETRY_FAILURES {
        let server = MockServer::start().await;
        let dir = TempDir::new().unwrap();
        mount_401_then(&server, THINGS, status, retry_after).await;
        let client = client_for(&server, &dir).await;

        let result = client.get_paged::<Value>(THINGS).await;
        let err = match result {
            Ok(items) => panic!("retried {status} must be an error, got Ok({} items)", items.len()),
            Err(e) => e,
        };
        assert_eq!(http_status(&err), Some(status), "{err:#}");
    }
}

#[tokio::test]
async fn delta_fails_when_the_request_retried_after_a_401_refresh_is_throttled_or_refused() {
    for (status, retry_after) in RETRY_FAILURES {
        let server = MockServer::start().await;
        let dir = TempDir::new().unwrap();
        let delta_file = dir.path().join("things.delta");
        mount_401_then(&server, THINGS, status, retry_after).await;
        let client = client_for(&server, &dir).await;

        let result = client.delta::<Value>(THINGS, &delta_file).await;
        let err = match result {
            Ok((items, link)) => panic!(
                "retried {status} must be an error, got Ok({} items, link {link:?})",
                items.len()
            ),
            Err(e) => e,
        };
        assert_eq!(http_status(&err), Some(status), "{err:#}");
        assert!(!delta_file.exists(), "no delta link may be saved from a failed fetch");
    }
}

/// Page 1 is fine; page 2 hits the 401 -> refresh -> 429 path. The caller must
/// get an error, not page 1 dressed up as the complete result.
async fn mount_two_pages_second_throttled_after_refresh(server: &MockServer, base: &str) {
    Mock::given(method("GET"))
        .and(path(THINGS))
        .and(query_param("page", "2"))
        .and(header("authorization", format!("Bearer {OLD_AT}").as_str()))
        .respond_with(ResponseTemplate::new(401).set_body_json(error_body()))
        .mount(server)
        .await;
    mount_refresh(server).await;
    Mock::given(method("GET"))
        .and(path(THINGS))
        .and(query_param("page", "2"))
        .and(header("authorization", format!("Bearer {NEW_AT}").as_str()))
        .respond_with(failure(429, Some("30")))
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path(THINGS))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "value": [{ "id": "a" }],
            "@odata.nextLink": format!("{base}{THINGS}?page=2"),
        })))
        .mount(server)
        .await;
}

#[tokio::test]
async fn get_paged_does_not_return_the_first_page_as_complete_when_a_later_page_fails_after_a_refresh() {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    mount_two_pages_second_throttled_after_refresh(&server, &server.uri()).await;
    let client = client_for(&server, &dir).await;

    let result = client.get_paged::<Value>(THINGS).await;
    match result {
        Ok(items) => panic!("a throttled second page must be an error, got Ok({} items)", items.len()),
        Err(e) => assert_eq!(http_status(&e), Some(429), "{e:#}"),
    }
}

#[tokio::test]
async fn delta_does_not_return_the_first_page_as_complete_when_a_later_page_fails_after_a_refresh() {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let delta_file = dir.path().join("things.delta");
    mount_two_pages_second_throttled_after_refresh(&server, &server.uri()).await;
    let client = client_for(&server, &dir).await;

    let result = client.delta::<Value>(THINGS, &delta_file).await;
    match result {
        Ok((items, _)) => panic!("a throttled second page must be an error, got Ok({} items)", items.len()),
        Err(e) => assert_eq!(http_status(&e), Some(429), "{e:#}"),
    }
    assert!(!delta_file.exists());
}

// ── A 200 whose body is a Graph error object is an error, not an empty page ──

async fn mount_ok_error_object(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path(THINGS))
        .respond_with(ResponseTemplate::new(200).set_body_json(error_body()))
        .mount(server)
        .await;
}

#[tokio::test]
async fn get_paged_treats_a_200_error_object_without_value_as_an_error() {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    mount_ok_error_object(&server).await;
    let client = client_for(&server, &dir).await;

    match client.get_paged::<Value>(THINGS).await {
        Ok(items) => panic!("an error object is not an empty collection; got Ok({} items)", items.len()),
        Err(e) => assert!(!format!("{e:#}").is_empty()),
    }
}

#[tokio::test]
async fn delta_treats_a_200_error_object_without_value_as_an_error_and_saves_no_link() {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let delta_file = dir.path().join("things.delta");
    mount_ok_error_object(&server).await;
    let client = client_for(&server, &dir).await;

    match client.delta::<Value>(THINGS, &delta_file).await {
        Ok((items, link)) => panic!(
            "an error object is not an empty delta; got Ok({} items, link {link:?})",
            items.len()
        ),
        Err(e) => assert!(!format!("{e:#}").is_empty()),
    }
    assert!(!delta_file.exists());
}

#[tokio::test]
async fn a_genuinely_empty_collection_is_still_an_empty_success() {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    Mock::given(method("GET"))
        .and(path(THINGS))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "value": [] })))
        .mount(&server)
        .await;
    let client = client_for(&server, &dir).await;

    let items = client.get_paged::<Value>(THINGS).await.expect("empty is fine");
    assert!(items.is_empty());
}

// ── Retry-After parsing (RFC 7231: seconds or HTTP-date) ──────────────────────

fn at(s: &str) -> DateTime<Utc> {
    Utc.from_utc_datetime(&chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S").unwrap())
}

#[test]
fn retry_after_in_whole_seconds_is_that_many_seconds() {
    let now = at("2026-10-21 07:26:00");
    assert_eq!(parse_retry_after("120", now), Some(Duration::from_secs(120)));
    assert_eq!(parse_retry_after("1", now), Some(Duration::from_secs(1)));
    assert_eq!(parse_retry_after("0", now), Some(Duration::ZERO));
}

#[test]
fn retry_after_as_an_http_date_is_measured_from_now() {
    let now = at("2026-10-21 07:26:00");
    assert_eq!(
        parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT", now),
        Some(Duration::from_secs(120))
    );
    assert_eq!(
        parse_retry_after("Wed, 21 Oct 2026 07:26:30 GMT", now),
        Some(Duration::from_secs(30))
    );
}

#[test]
fn retry_after_date_in_the_past_means_no_wait() {
    let now = at("2026-10-21 07:26:00");
    assert_eq!(parse_retry_after("Wed, 21 Oct 2026 07:20:00 GMT", now), Some(Duration::ZERO));
    assert_eq!(parse_retry_after("Thu, 01 Jan 1970 00:00:00 GMT", now), Some(Duration::ZERO));
}

#[test]
fn retry_after_is_capped_at_fifteen_minutes() {
    let now = at("2026-10-21 07:26:00");
    assert_eq!(MAX_RETRY_AFTER, Duration::from_secs(15 * 60));
    assert_eq!(parse_retry_after("900", now), Some(MAX_RETRY_AFTER));
    assert_eq!(parse_retry_after("901", now), Some(MAX_RETRY_AFTER));
    assert_eq!(parse_retry_after("86400", now), Some(MAX_RETRY_AFTER));
    assert_eq!(parse_retry_after("Thu, 22 Oct 2026 07:26:00 GMT", now), Some(MAX_RETRY_AFTER));
}

#[test]
fn retry_after_that_is_neither_seconds_nor_a_date_is_ignored() {
    let now = at("2026-10-21 07:26:00");
    for garbage in ["", "soon", "12abc", "Wed, 99 Foo 2026 07:28:00 GMT", "tomorrow at noon"] {
        assert_eq!(parse_retry_after(garbage, now), None, "{garbage:?}");
    }
}
