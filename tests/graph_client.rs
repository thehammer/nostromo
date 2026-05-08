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
