//! Fred mail / calendar detail (F1): `GraphFredDetail` answers `mail:<id>` and
//! `event:<id>` detail requests from Microsoft Graph, read-only.
//!
//! Every test runs its own wiremock "Microsoft" and temp dir; nothing touches
//! the user's real token cache or network. Cache behaviour is observed through
//! the mock's request log, never through the clock.

use std::time::Duration;

use chrono::{Duration as ChronoDuration, FixedOffset, Utc};
use nostromo::data::fred_detail::{trim_quoted_chain, GraphFredDetail};
use nostromo::data::graph_client::{GraphClient, GraphOptions};
use nostromo::data::work::model::{WorkDetail, WorkError};
use nostromo::data::work::service::FredDetailService;
use serde_json::{json, Value};
use tempfile::TempDir;
use wiremock::matchers::{header, header_regex, method, path, query_param_contains};
use wiremock::{Mock, MockServer, ResponseTemplate};

const ACCESS_TOKEN: &str = "fake-at-detail-secret";
const REFRESH_TOKEN: &str = "fake-rt-detail-secret";
const DEVICE_CODE_SECRET: &str = "dev-code-secret-detail";
const DEVICECODE: &str = "/common/oauth2/v2.0/devicecode";
const TOKEN: &str = "/common/oauth2/v2.0/token";

struct Env {
    server: MockServer,
    _dir: TempDir,
    graph: GraphClient,
}

async fn env(signed_in: bool) -> Env {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let token_cache = dir.path().join("graph-token.json");
    if signed_in {
        let expires_at = (Utc::now() + ChronoDuration::hours(1)).timestamp();
        std::fs::write(
            &token_cache,
            json!({
                "access_token": ACCESS_TOKEN,
                "refresh_token": REFRESH_TOKEN,
                "expires_at": expires_at,
            })
            .to_string(),
        )
        .unwrap();
    }
    let graph = GraphClient::with_options(
        "test-client".into(),
        "common".into(),
        token_cache,
        GraphOptions {
            graph_base: server.uri(),
            login_base: server.uri(),
            use_m365_cli: false,
            min_device_poll: Duration::from_millis(100),
        },
    )
    .await
    .expect("graph client builds");
    Env { server, _dir: dir, graph }
}

fn service(e: &Env) -> GraphFredDetail {
    GraphFredDetail::new(e.graph.clone())
}

fn plus_two() -> FixedOffset {
    FixedOffset::east_opt(2 * 3600).unwrap()
}

fn mail_json(body: &str) -> Value {
    json!({
        "subject": "Quarterly numbers",
        "from": {"emailAddress": {"name": "Alice Smith", "address": "alice@example.com"}},
        "toRecipients": [
            {"emailAddress": {"name": "Bob Jones", "address": "bob@example.com"}},
            {"emailAddress": {"name": "Cy", "address": "cy@example.com"}}
        ],
        "ccRecipients": [],
        "receivedDateTime": "2026-10-10T14:30:00Z",
        "body": {"contentType": "text", "content": body},
        "webLink": "https://outlook.example/mail/abc"
    })
}

fn event_json(body: &str) -> Value {
    json!({
        "subject": "Design review",
        "organizer": {"emailAddress": {"name": "Olive Organiser", "address": "olive@example.com"}},
        "attendees": [
            {"emailAddress": {"name": "Ann", "address": "ann@example.com"}, "status": {"response": "accepted"}},
            {"emailAddress": {"name": "Ben", "address": "ben@example.com"}, "status": {"response": "tentativelyAccepted"}},
            {"emailAddress": {"name": "Cat", "address": "cat@example.com"}, "status": {"response": "none"}}
        ],
        "location": {"displayName": "Room 4"},
        "onlineMeeting": {"joinUrl": "https://teams.example/join/xyz"},
        "start": {"dateTime": "2026-10-10T14:30:00.0000000", "timeZone": "UTC"},
        "end": {"dateTime": "2026-10-10T15:00:00.0000000", "timeZone": "UTC"},
        "body": {"contentType": "text", "content": body},
        "webLink": "https://outlook.example/event/def"
    })
}

async fn mount_json(server: &MockServer, p: &str, body: Value) {
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(server)
        .await;
}

fn field<'a>(d: &'a WorkDetail, label: &str) -> Option<&'a str> {
    d.fields.iter().find(|(l, _)| l == label).map(|(_, v)| v.as_str())
}

fn link<'a>(d: &'a WorkDetail, label: &str) -> Option<&'a str> {
    d.links.iter().find(|l| l.label == label).map(|l| l.url.as_str())
}

// ═════════════════════════════════════════════════════════════════════════════
// Mail
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mail_detail_asks_graph_for_the_message_as_text_and_maps_its_fields() {
    let e = env(true).await;
    Mock::given(method("GET"))
        .and(path("/me/messages/abc123"))
        .and(header("Prefer", "outlook.body-content-type=\"text\""))
        .and(query_param_contains("$select", "subject"))
        .and(query_param_contains("$select", "from"))
        .and(query_param_contains("$select", "toRecipients"))
        .and(query_param_contains("$select", "ccRecipients"))
        .and(query_param_contains("$select", "receivedDateTime"))
        .and(query_param_contains("$select", "body"))
        .and(query_param_contains("$select", "webLink"))
        .respond_with(ResponseTemplate::new(200).set_body_json(mail_json("Hello Bob,\nNumbers attached.")))
        .expect(1)
        .mount(&e.server)
        .await;

    let d = GraphFredDetail::with_zone(e.graph.clone(), plus_two())
        .detail("mail:abc123")
        .await
        .expect("detail");

    assert_eq!(d.item_id, "mail:abc123");
    assert_eq!(d.title, "Quarterly numbers");
    assert_eq!(field(&d, "From"), Some("Alice Smith <alice@example.com>"));
    let to = field(&d, "To").expect("To field");
    assert!(to.contains("Bob Jones <bob@example.com>") && to.contains("Cy <cy@example.com>"), "{to}");
    assert!(field(&d, "Received").is_some_and(|r| !r.is_empty()), "Received present");
    assert_eq!(d.markdown, "Hello Bob,\nNumbers attached.");
    assert_eq!(link(&d, "Open in Outlook"), Some("https://outlook.example/mail/abc"));
}

#[tokio::test]
async fn mail_detail_omits_cc_when_there_are_no_cc_recipients_and_shows_it_otherwise() {
    let e = env(true).await;
    mount_json(&e.server, "/me/messages/nocc", mail_json("x")).await;
    let mut with_cc = mail_json("x");
    with_cc["ccRecipients"] = json!([{"emailAddress": {"name": "Dee", "address": "dee@example.com"}}]);
    mount_json(&e.server, "/me/messages/withcc", with_cc).await;

    let svc = service(&e);
    let none = svc.detail("mail:nocc").await.unwrap();
    assert!(field(&none, "Cc").is_none(), "{:?}", none.fields);
    let some = svc.detail("mail:withcc").await.unwrap();
    assert_eq!(field(&some, "Cc"), Some("Dee <dee@example.com>"));
}

#[tokio::test]
async fn mail_body_drops_the_quoted_reply_chain() {
    let e = env(true).await;
    let body = "Sounds good, thanks.\n\nFrom: Bob Jones\nSent: Monday\nTo: Alice\n\nOriginal text";
    mount_json(&e.server, "/me/messages/chain", mail_json(body)).await;
    let d = service(&e).detail("mail:chain").await.unwrap();
    assert_eq!(d.markdown.trim(), "Sounds good, thanks.");
    assert!(!d.markdown.contains("Original text"));
}

#[tokio::test]
async fn mail_body_with_from_on_its_first_line_is_not_trimmed() {
    let e = env(true).await;
    let body = "From: the desk of Alice\nPlease read this.";
    mount_json(&e.server, "/me/messages/first", mail_json(body)).await;
    let d = service(&e).detail("mail:first").await.unwrap();
    assert_eq!(d.markdown, body);
}

#[test]
fn trim_quoted_chain_only_cuts_at_a_from_line_that_follows_a_blank_line() {
    assert_eq!(trim_quoted_chain("Hi\n\nFrom: X\nold"), "Hi");
    assert_eq!(trim_quoted_chain("Hi\nFrom: X\nstill mine"), "Hi\nFrom: X\nstill mine");
    assert_eq!(trim_quoted_chain("From: X\nmine"), "From: X\nmine");
    assert_eq!(trim_quoted_chain("no chain here"), "no chain here");
}

#[tokio::test]
async fn mail_body_is_capped_at_32_kib_without_splitting_a_character() {
    let e = env(true).await;
    // 3-byte chars so a 32 KiB cut (32768 = 3*10922 + 2) lands mid-character.
    let big = "€".repeat(20_000); // 60_000 bytes
    mount_json(&e.server, "/me/messages/big", mail_json(&big)).await;
    let d = service(&e).detail("mail:big").await.unwrap();
    // Valid UTF-8 is guaranteed by String; the cap is on the kept body bytes
    // (a short truncation marker is allowed on top).
    assert!(d.markdown.len() < 60_000, "body was capped, got {} bytes", d.markdown.len());
    assert!(d.markdown.len() <= 32 * 1024 + 64, "got {} bytes", d.markdown.len());
    assert!(d.markdown.starts_with('€'));
    let kept = d.markdown.chars().take_while(|c| *c == '€').count();
    assert!((10_000..=10_922).contains(&kept), "kept {kept} chars");
}

#[tokio::test]
async fn a_short_mail_body_is_returned_whole() {
    let e = env(true).await;
    let body = "é".repeat(1000);
    mount_json(&e.server, "/me/messages/short", mail_json(&body)).await;
    let d = service(&e).detail("mail:short").await.unwrap();
    assert_eq!(d.markdown, body);
}

// ═════════════════════════════════════════════════════════════════════════════
// Events
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn event_detail_maps_organiser_when_location_join_link_and_attendees() {
    let e = env(true).await;
    Mock::given(method("GET"))
        .and(path("/me/events/ev1"))
        // Events may also ask for a timezone; the text body preference must be present.
        .and(header_regex("Prefer", "outlook\\.body-content-type=\"text\""))
        .and(query_param_contains("$select", "subject"))
        .and(query_param_contains("$select", "organizer"))
        .and(query_param_contains("$select", "attendees"))
        .and(query_param_contains("$select", "location"))
        .and(query_param_contains("$select", "onlineMeeting"))
        .and(query_param_contains("$select", "start"))
        .and(query_param_contains("$select", "end"))
        .and(query_param_contains("$select", "body"))
        .and(query_param_contains("$select", "webLink"))
        .respond_with(ResponseTemplate::new(200).set_body_json(event_json("Agenda: roadmap")))
        .expect(1)
        .mount(&e.server)
        .await;

    let d = GraphFredDetail::with_zone(e.graph.clone(), plus_two())
        .detail("event:ev1")
        .await
        .expect("detail");

    assert_eq!(d.item_id, "event:ev1");
    assert_eq!(d.title, "Design review");
    let organiser = field(&d, "Organiser").expect("Organiser");
    assert!(organiser.contains("Olive Organiser"), "{organiser}");
    // 14:30-15:00 UTC shown in +02:00 is 16:30-17:00.
    let when = field(&d, "When").expect("When");
    assert!(when.contains("16:30") && when.contains("17:00"), "{when}");
    assert!(!when.contains("14:30"), "must be shown in the requested zone: {when}");
    assert_eq!(field(&d, "Location"), Some("Room 4"));
    assert_eq!(field(&d, "Join link"), Some("https://teams.example/join/xyz"));
    assert_eq!(
        field(&d, "Attendees"),
        Some("Ann (accepted), Ben (tentatively accepted), Cat (no response)")
    );
    assert_eq!(d.markdown, "Agenda: roadmap");
    assert_eq!(link(&d, "Open in Outlook"), Some("https://outlook.example/event/def"));
}

#[tokio::test]
async fn event_detail_leaves_out_fields_graph_did_not_provide() {
    let e = env(true).await;
    mount_json(
        &e.server,
        "/me/events/bare",
        json!({
            "subject": "Hallway chat",
            "start": {"dateTime": "2026-10-10T14:30:00.0000000", "timeZone": "UTC"},
            "end": {"dateTime": "2026-10-10T15:00:00.0000000", "timeZone": "UTC"},
            "body": {"content": ""},
            "webLink": "https://outlook.example/event/bare"
        }),
    )
    .await;
    let d = service(&e).detail("event:bare").await.unwrap();
    assert_eq!(d.title, "Hallway chat");
    for label in ["Location", "Join link", "Attendees"] {
        assert!(field(&d, label).is_none(), "{label} should be absent: {:?}", d.fields);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Cache
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_second_request_for_the_same_item_is_served_from_cache() {
    let e = env(true).await;
    Mock::given(method("GET"))
        .and(path("/me/messages/cached"))
        .respond_with(ResponseTemplate::new(200).set_body_json(mail_json("hi")))
        .expect(1)
        .mount(&e.server)
        .await;
    let svc = service(&e);
    let first = svc.detail("mail:cached").await.unwrap();
    let second = svc.detail("mail:cached").await.unwrap();
    assert_eq!(first, second);
    // `.expect(1)` is verified when the server drops; also check the log now.
    let gets = e.server.received_requests().await.unwrap().iter().filter(|r| r.url.path() == "/me/messages/cached").count();
    assert_eq!(gets, 1);
}

#[tokio::test]
async fn different_items_are_cached_independently() {
    let e = env(true).await;
    mount_json(&e.server, "/me/messages/a", mail_json("a")).await;
    mount_json(&e.server, "/me/messages/b", mail_json("b")).await;
    let svc = service(&e);
    assert_eq!(svc.detail("mail:a").await.unwrap().item_id, "mail:a");
    assert_eq!(svc.detail("mail:b").await.unwrap().item_id, "mail:b");
    let n = e.server.received_requests().await.unwrap().iter().filter(|r| r.url.path().starts_with("/me/messages/")).count();
    assert_eq!(n, 2);
}

// ═════════════════════════════════════════════════════════════════════════════
// Errors
// ═════════════════════════════════════════════════════════════════════════════

fn code(r: Result<WorkDetail, WorkError>) -> String {
    r.expect_err("expected an error").code
}

#[tokio::test]
async fn detail_is_unauthenticated_while_sign_in_is_pending_and_never_calls_graph() {
    let e = env(false).await;
    Mock::given(method("POST"))
        .and(path(DEVICECODE))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "device_code": DEVICE_CODE_SECRET,
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://microsoft.com/devicelogin",
            "expires_in": 900,
            "interval": 0,
        })))
        .mount(&e.server)
        .await;
    Mock::given(method("POST"))
        .and(path(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"error": "authorization_pending"})))
        .mount(&e.server)
        .await;

    let err = service(&e).detail("mail:abc").await.expect_err("must fail");
    assert_eq!(err.code, "unauthenticated");
    assert!(!err.message.contains(DEVICE_CODE_SECRET), "{}", err.message);
    let graph_calls = e
        .server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path().starts_with("/me/"))
        .count();
    assert_eq!(graph_calls, 0);
}

#[tokio::test]
async fn graph_401_is_unauthenticated() {
    let e = env(true).await;
    Mock::given(method("GET"))
        .and(path("/me/messages/x"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({"error": {"code": "InvalidAuthenticationToken"}})))
        .mount(&e.server)
        .await;
    assert_eq!(code(service(&e).detail("mail:x").await), "unauthenticated");
}

#[tokio::test]
async fn graph_404_is_not_found_for_mail_and_events() {
    let e = env(true).await;
    for p in ["/me/messages/gone", "/me/events/gone"] {
        Mock::given(method("GET"))
            .and(path(p))
            .respond_with(ResponseTemplate::new(404).set_body_json(json!({"error": {"code": "ErrorItemNotFound"}})))
            .mount(&e.server)
            .await;
    }
    let svc = service(&e);
    assert_eq!(code(svc.detail("mail:gone").await), "not_found");
    assert_eq!(code(svc.detail("event:gone").await), "not_found");
}

#[tokio::test]
async fn ids_that_are_neither_mail_nor_event_are_not_found_without_calling_graph() {
    let e = env(true).await;
    let svc = service(&e);
    for id in ["", "mail:", "event:", "jira:ABC-1", "plain-id", "MAIL:abc"] {
        assert_eq!(code(svc.detail(id).await), "not_found", "id {id:?}");
    }
    assert!(e.server.received_requests().await.unwrap().is_empty(), "no request should have been made");
}

// ═════════════════════════════════════════════════════════════════════════════
// Safety
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn only_get_requests_to_message_and_event_paths_are_ever_issued() {
    let e = env(true).await;
    mount_json(&e.server, "/me/messages/m1", mail_json("hi")).await;
    mount_json(&e.server, "/me/events/e1", event_json("hi")).await;
    Mock::given(method("GET"))
        .and(path("/me/messages/missing"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&e.server)
        .await;
    let svc = service(&e);
    let _ = svc.detail("mail:m1").await;
    let _ = svc.detail("event:e1").await;
    let _ = svc.detail("mail:missing").await;
    let _ = svc.detail("bogus").await;

    let reqs = e.server.received_requests().await.unwrap();
    assert!(!reqs.is_empty());
    for r in reqs {
        assert_eq!(r.method.as_str(), "GET", "{} {}", r.method, r.url);
        let p = r.url.path();
        assert!(p.starts_with("/me/messages/") || p.starts_with("/me/events/"), "unexpected path {p}");
    }
}

#[tokio::test]
async fn the_access_token_never_appears_in_errors_or_returned_details() {
    let e = env(true).await;
    mount_json(&e.server, "/me/messages/ok", mail_json("hi")).await;
    Mock::given(method("GET"))
        .and(path("/me/messages/boom"))
        .respond_with(ResponseTemplate::new(500).set_body_string(format!("server said {ACCESS_TOKEN}")))
        .mount(&e.server)
        .await;
    Mock::given(method("GET"))
        .and(path("/me/messages/denied"))
        .respond_with(ResponseTemplate::new(401).set_body_string(format!("bad token {ACCESS_TOKEN}")))
        .mount(&e.server)
        .await;
    let svc = service(&e);

    let ok = svc.detail("mail:ok").await.unwrap();
    let mut shown = format!("{ok:?} {}", serde_json::to_string(&ok).unwrap());
    for id in ["mail:boom", "mail:denied", "mail:nothing", "junk"] {
        let err = svc.detail(id).await.expect_err("error");
        shown.push_str(&format!(" {err:?} {} {}", err.code, err.message));
    }
    assert!(!shown.contains(ACCESS_TOKEN), "token leaked: {shown}");
    assert!(!shown.contains(REFRESH_TOKEN), "refresh token leaked");
}

// ═════════════════════════════════════════════════════════════════════════════
// Id encoding
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn ids_with_reserved_characters_are_percent_encoded_in_the_path() {
    let e = env(true).await;
    // Graph ids are base64-ish: `=`, `+`, `/` all occur.
    let id = "AAMk+ad/Z==";
    Mock::given(method("GET"))
        .and(path("/me/messages/AAMk%2Bad%2FZ%3D%3D"))
        .respond_with(ResponseTemplate::new(200).set_body_json(mail_json("encoded")))
        .mount(&e.server)
        .await;
    let d = service(&e).detail(&format!("mail:{id}")).await.expect("detail");
    assert_eq!(d.markdown, "encoded");
    assert_eq!(d.item_id, format!("mail:{id}"));

    let reqs = e.server.received_requests().await.unwrap();
    let raw = reqs[0].url.as_str();
    assert!(raw.contains("/me/messages/AAMk%2Bad%2FZ%3D%3D"), "raw url {raw}");
}
