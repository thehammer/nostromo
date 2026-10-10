//! The Jira work source: the user's unresolved assigned issues, with honest
//! states, secret hygiene, a detail view, and hub / MCP integration.
//!
//! Everything talks to a wiremock server; the process environment is ignored
//! (`file_credentials_only`) so nothing here can reach a real Jira.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use chrono::{NaiveDate, TimeZone, Utc};
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, SourceUpdate, WorkHub};
use nostromo::data::work::jira::JiraWorkSource;
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::{SourceState, SourceStatus, WorkItem, WorkSource};
use nostromo::mcp::tools::teri::{get_work_item, list_work_items};
use nostromo::mcp::McpSharedState;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, watch, Notify};
use wiremock::matchers::{header, method, path, query_param};
use wiremock::{Match, Mock, MockServer, Request, ResponseTemplate};

const WAIT: Duration = Duration::from_secs(5);
const SITE: &str = "example.atlassian.net";
const EMAIL: &str = "ada@example.com";
const GOOD_TOKEN: &str = "good-token-123";
const SENTINEL: &str = "SENTINEL-tok-9f3a7c1d5e2b4a60";

// ── fixtures ──────────────────────────────────────────────────────────────

fn b64(input: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = input.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

fn basic(email: &str, token: &str) -> String {
    format!("Basic {}", b64(&format!("{email}:{token}")))
}

fn env_text(token: &str) -> String {
    format!("ATLASSIAN_SITE_NAME={SITE}\nATLASSIAN_USER_EMAIL={EMAIL}\nATLASSIAN_API_TOKEN={token}\n")
}

fn write_env(dir: &Path, contents: &str) -> PathBuf {
    let p = dir.join(".env");
    std::fs::write(&p, contents).unwrap();
    p
}

/// Rewrite the file and push its mtime into the future so a change is always seen.
fn rewrite_env(p: &Path, contents: &str) {
    std::fs::write(p, contents).unwrap();
    let later = SystemTime::now() + Duration::from_secs(5);
    std::fs::File::options().write(true).open(p).unwrap().set_modified(later).unwrap();
}

fn issue(key: &str, summary: &str, itype: &str, status: &str, cat: &str, prio: Option<&str>) -> Value {
    let project = key.split('-').next().unwrap();
    let mut fields = json!({
        "summary": summary,
        "status": {"name": status, "statusCategory": {"key": cat}},
        "issuetype": {"name": itype},
        "project": {"key": project},
        "created": "2026-09-20T09:30:00.000+0000",
        "updated": "2026-10-01T08:00:00.000+0000",
        "duedate": "2026-10-15",
    });
    if let Some(p) = prio {
        fields["priority"] = json!({"name": p});
    }
    json!({"key": key, "fields": fields})
}

fn simple(key: &str) -> Value {
    issue(key, &format!("Summary of {key}"), "Task", "In Progress", "indeterminate", Some("Medium"))
}

fn page(issues: Vec<Value>) -> Value {
    json!({"issues": issues, "isLast": true})
}

fn ok(issues: Vec<Value>) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(page(issues))
}

fn adf(text: &str) -> Value {
    json!({"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":text}]}]})
}

fn source(env: &Path, server: &MockServer, poll: Duration) -> Arc<JiraWorkSource> {
    Arc::new(
        JiraWorkSource::new(env)
            .with_base_url(server.uri())
            .file_credentials_only()
            .with_poll_interval(poll)
            .with_backoff_base(Duration::from_millis(50)),
    )
}

const LONG: Duration = Duration::from_secs(3600);

async fn wait_for(
    rx: &mut watch::Receiver<SourceUpdate>,
    what: &str,
    pred: impl Fn(&SourceUpdate) -> bool,
) -> SourceUpdate {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let current = rx.borrow_and_update().clone();
        if pred(&current) {
            return current;
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, rx.changed()).await {
            Ok(Ok(())) => {}
            _ => panic!("timed out waiting for {what}; last status: {:?}", current.0),
        }
    }
}

async fn wait_state(rx: &mut watch::Receiver<SourceUpdate>, state: SourceState) -> SourceUpdate {
    wait_for(rx, &format!("{state:?}"), |u| u.0.state == state).await
}

fn flat(update: &SourceUpdate) -> Vec<WorkItem> {
    update.1.iter().flat_map(|(_, items)| items.iter().cloned()).collect()
}

fn ids(items: &[WorkItem]) -> Vec<String> {
    items.iter().map(|i| i.id.clone()).collect()
}

async fn requests(server: &MockServer) -> Vec<Request> {
    server.received_requests().await.unwrap_or_default()
}

fn body_of(r: &Request) -> Value {
    serde_json::from_slice(&r.body).unwrap_or(Value::Null)
}

/// Matches search/jql bodies that carry no `nextPageToken`.
struct NoPageToken;
impl Match for NoPageToken {
    fn matches(&self, r: &Request) -> bool {
        body_of(r).get("nextPageToken").is_none()
    }
}

// ── query and mapping ─────────────────────────────────────────────────────

#[tokio::test]
async fn it_asks_jira_for_my_unresolved_issues_with_basic_auth() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("PROJ-1")])).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    wait_state(&mut rx, SourceState::Fresh).await;

    let reqs = requests(&server).await;
    let first = &reqs[0];
    assert_eq!(first.method.as_str(), "POST");
    assert_eq!(first.url.path(), "/rest/api/3/search/jql");
    assert_eq!(first.headers.get("authorization").unwrap().to_str().unwrap(), basic(EMAIL, GOOD_TOKEN));
    let body = body_of(first);
    assert_eq!(body["jql"], "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC");
    assert_eq!(body["maxResults"], 100);
    let mut fields: Vec<String> =
        body["fields"].as_array().unwrap().iter().map(|f| f.as_str().unwrap().to_string()).collect();
    fields.sort();
    let mut expected: Vec<String> =
        ["summary", "status", "priority", "updated", "created", "project", "issuetype", "duedate"]
            .iter()
            .map(|s| s.to_string())
            .collect();
    expected.sort();
    assert_eq!(fields, expected);
}

#[tokio::test]
async fn it_maps_an_issue_to_a_work_item() {
    let server = MockServer::start().await;
    let page1 = vec![issue("PROJ-42", "Fix the login bug", "Bug", "In Progress", "indeterminate", Some("High"))];
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(page1)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Fresh).await;

    let items = flat(&update);
    assert_eq!(items.len(), 1);
    let it = &items[0];
    assert_eq!(it.id, "jira:PROJ-42");
    assert_eq!(it.source, WorkSource::Jira);
    assert_eq!(it.kind, "bug");
    assert_eq!(it.title, "Fix the login bug");
    assert_eq!(it.project.as_deref(), Some("PROJ"));
    assert_eq!(it.status.as_deref(), Some("In Progress"));
    assert_eq!(it.status_category.as_deref(), Some("in_progress"));
    let p = it.priority.as_ref().expect("priority");
    assert_eq!((p.label.as_str(), p.rank), ("High", 2));
    assert_eq!(it.created_at, Some(Utc.with_ymd_and_hms(2026, 9, 20, 9, 30, 0).unwrap()));
    assert_eq!(it.updated_at, Some(Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap()));
    assert_eq!(it.due, NaiveDate::from_ymd_opt(2026, 10, 15));
    assert_eq!(it.url.as_deref(), Some("https://example.atlassian.net/browse/PROJ-42"));
    assert_eq!(it.search_text, "PROJ-42 Fix the login bug");
    assert_eq!(update.0.count, 1);
    assert!(update.0.updated_at.is_some(), "a fresh status says when it was fetched");
}

#[tokio::test]
async fn status_categories_priorities_and_kinds_map_as_specified() {
    let server = MockServer::start().await;
    let issues = vec![
        issue("A-1", "a", "Story", "To Do", "new", Some("Highest")),
        issue("A-2", "b", "Sub-task", "Done-ish", "done", Some("Low")),
        issue("A-3", "c", "Epic", "Doing", "indeterminate", Some("Lowest")),
        issue("A-4", "d", "Task", "Weird", "new", Some("Blocker")),
        issue("A-5", "e", "Task", "Open", "new", Some("Medium")),
        issue("A-6", "f", "Task", "Open", "new", None),
    ];
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(issues)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let items = flat(&wait_state(&mut rx, SourceState::Fresh).await);

    let by = |id: &str| items.iter().find(|i| i.id == id).unwrap().clone();
    assert_eq!(by("jira:A-1").status_category.as_deref(), Some("to_do"));
    assert_eq!(by("jira:A-2").status_category.as_deref(), Some("other"));
    assert_eq!(by("jira:A-3").status_category.as_deref(), Some("in_progress"));
    assert_eq!(by("jira:A-1").priority.unwrap().rank, 1);
    assert_eq!(by("jira:A-2").priority.unwrap().rank, 4);
    assert_eq!(by("jira:A-3").priority.unwrap().rank, 5);
    assert_eq!(by("jira:A-4").priority.unwrap().rank, 9);
    assert_eq!(by("jira:A-5").priority.unwrap().rank, 3);
    assert!(by("jira:A-6").priority.is_none());
    assert_eq!(by("jira:A-1").kind, "story");
    assert_eq!(by("jira:A-2").kind, "sub-task");
    assert_eq!(by("jira:A-3").kind, "epic");
}

#[tokio::test]
async fn it_follows_next_page_token_until_the_last_page() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .and(NoPageToken)
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "issues": [simple("P-1"), simple("P-2")], "nextPageToken": "tok-two", "isLast": false
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .and(wiremock::matchers::body_partial_json(json!({"nextPageToken": "tok-two"})))
        .respond_with(ok(vec![simple("P-3")]))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Fresh).await;

    assert_eq!(ids(&flat(&update)), vec!["jira:P-1", "jira:P-2", "jira:P-3"]);
    assert_eq!(update.0.count, 3);
    assert_eq!(requests(&server).await.len(), 2);
}

#[tokio::test]
async fn it_stops_at_five_hundred_issues() {
    let server = MockServer::start().await;
    let hundred: Vec<Value> = (1..=100).map(|n| simple(&format!("BIG-{n}"))).collect();
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "issues": hundred, "nextPageToken": "more", "isLast": false
        })))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Fresh).await;

    assert_eq!(flat(&update).len(), 500);
    assert_eq!(update.0.count, 500);
    assert_eq!(requests(&server).await.len(), 5, "no sixth page is requested");
}

async fn legacy_fallback_after(status: u16) {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ResponseTemplate::new(status)).mount(&server).await;
    Mock::given(method("GET"))
        .and(path("/rest/api/3/search"))
        .and(query_param("startAt", "0"))
        .and(query_param("maxResults", "100"))
        .and(query_param("jql", "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "startAt": 0, "maxResults": 100, "total": 3, "issues": [simple("OLD-1"), simple("OLD-2")]
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/rest/api/3/search"))
        .and(query_param("startAt", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "startAt": 2, "maxResults": 100, "total": 3, "issues": [simple("OLD-3")]
        })))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Fresh).await;

    assert_eq!(ids(&flat(&update)), vec!["jira:OLD-1", "jira:OLD-2", "jira:OLD-3"], "after a {status}");
}

#[tokio::test]
async fn it_falls_back_to_the_legacy_search_when_search_jql_is_404() {
    legacy_fallback_after(404).await;
}

#[tokio::test]
async fn it_falls_back_to_the_legacy_search_when_search_jql_is_410() {
    legacy_fallback_after(410).await;
}

// ── states ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn without_credentials_it_is_not_configured_and_names_the_variables() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let env = dir.path().join("missing.env");
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::NotConfigured).await;

    let reason = update.0.reason.clone().expect("a reason");
    for name in ["ATLASSIAN_SITE_NAME", "ATLASSIAN_USER_EMAIL", "ATLASSIAN_API_TOKEN"] {
        assert!(reason.contains(name), "reason should name {name}: {reason}");
    }
    assert!(flat(&update).is_empty());
    assert!(requests(&server).await.is_empty(), "no request without credentials");
}

#[tokio::test]
async fn a_partial_credential_set_is_not_configured() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &format!("ATLASSIAN_SITE_NAME={SITE}\nATLASSIAN_USER_EMAIL={EMAIL}\n"));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    wait_state(&mut rx, SourceState::NotConfigured).await;

    assert!(requests(&server).await.is_empty());
}

#[tokio::test]
async fn a_rejected_token_is_unauthenticated_naming_the_variable_never_a_value() {
    for code in [401u16, 403] {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/rest/api/3/search/jql"))
            .respond_with(ResponseTemplate::new(code).set_body_string(format!("bad credentials {SENTINEL}")))
            .mount(&server)
            .await;
        let dir = tempfile::tempdir().unwrap();
        let env = write_env(dir.path(), &env_text(SENTINEL));
        let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

        let update = wait_state(&mut rx, SourceState::Unauthenticated).await;

        let reason = update.0.reason.clone().expect("a reason");
        assert!(reason.contains("ATLASSIAN_API_TOKEN"), "{code}: {reason}");
        assert!(!reason.contains(SENTINEL));
        assert!(flat(&update).is_empty());
    }
}

#[tokio::test]
async fn rate_limiting_keeps_the_items_and_reports_retry_at_from_seconds() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("RL-1")])).up_to_n_times(1).mount(&server).await;
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "120"))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let poke = Arc::new(Notify::new());
    let mut rx = source(&env, &server, LONG).spawn(poke.clone());
    wait_state(&mut rx, SourceState::Fresh).await;

    poke.notify_one();
    let update = wait_state(&mut rx, SourceState::RateLimited).await;

    let secs = (update.0.retry_at.expect("retry_at") - Utc::now()).num_seconds();
    assert!((100..=125).contains(&secs), "retry_at should be about 120 s away, was {secs}");
    assert_eq!(ids(&flat(&update)), vec!["jira:RL-1"], "previous items stay");
}

#[tokio::test]
async fn rate_limiting_understands_an_http_date_retry_after() {
    let server = MockServer::start().await;
    let when = (Utc::now() + chrono::Duration::seconds(90)).format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", when.as_str()))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::RateLimited).await;

    let secs = (update.0.retry_at.expect("retry_at") - Utc::now()).num_seconds();
    assert!((60..=95).contains(&secs), "retry_at should be about 90 s away, was {secs}");
}

#[tokio::test]
async fn a_server_error_after_good_data_is_stale_and_keeps_the_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("ST-1"), simple("ST-2")])).up_to_n_times(1).mount(&server).await;
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .respond_with(ResponseTemplate::new(500).set_body_string("<html>boom ".repeat(200)))
        .mount(&server)
        .await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let poke = Arc::new(Notify::new());
    let mut rx = source(&env, &server, LONG).spawn(poke.clone());
    wait_state(&mut rx, SourceState::Fresh).await;

    poke.notify_one();
    let update = wait_state(&mut rx, SourceState::Stale).await;

    assert_eq!(ids(&flat(&update)), vec!["jira:ST-1", "jira:ST-2"]);
    assert_eq!(update.0.count, 2);
    let reason = update.0.reason.clone().expect("a reason");
    assert!(reason.len() < 300, "the reason is short, not an echoed body: {reason}");
    assert!(!reason.contains("boom"));
}

#[tokio::test]
async fn a_network_error_after_good_data_is_stale() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("NET-1")]).insert_header("connection", "close")).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let poke = Arc::new(Notify::new());
    let mut rx = source(&env, &server, LONG).spawn(poke.clone());
    wait_state(&mut rx, SourceState::Fresh).await;

    drop(server);
    // The mock server shuts down on a background task: poke until the
    // connection is really refused.
    let stale = async {
        loop {
            tokio::time::sleep(Duration::from_millis(100)).await;
            poke.notify_one();
            if rx.borrow().0.state == SourceState::Stale {
                return;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(10), stale).await.expect("never went stale");
    let update = wait_state(&mut rx, SourceState::Stale).await;

    assert_eq!(ids(&flat(&update)), vec!["jira:NET-1"]);
}

#[tokio::test]
async fn a_server_error_with_no_previous_data_is_an_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ResponseTemplate::new(503)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Error).await;

    assert!(flat(&update).is_empty());
    assert!(update.0.reason.is_some());
}

#[tokio::test]
async fn an_unreachable_jira_with_no_previous_data_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let dead = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://{}", l.local_addr().unwrap())
    };
    let src = Arc::new(
        JiraWorkSource::new(&env)
            .with_base_url(dead)
            .file_credentials_only()
            .with_poll_interval(LONG)
            .with_backoff_base(Duration::from_millis(50)),
    );
    let mut rx = src.spawn(Arc::new(Notify::new()));

    wait_state(&mut rx, SourceState::Error).await;
}

#[tokio::test]
async fn zero_issues_is_empty_not_an_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![])).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let mut rx = source(&env, &server, LONG).spawn(Arc::new(Notify::new()));

    let update = wait_state(&mut rx, SourceState::Empty).await;

    assert_eq!(update.0.count, 0);
    assert!(flat(&update).is_empty());
}

// ── refresh and recovery ──────────────────────────────────────────────────

#[tokio::test]
async fn poking_the_refresh_notify_fetches_immediately() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("R-1")])).up_to_n_times(1).mount(&server).await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("R-1"), simple("R-2")])).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let poke = Arc::new(Notify::new());
    let mut rx = source(&env, &server, LONG).spawn(poke.clone());
    wait_for(&mut rx, "first fetch", |u| u.0.count == 1 && u.0.state == SourceState::Fresh).await;

    poke.notify_one();

    wait_for(&mut rx, "refetch after the poke", |u| u.0.count == 2).await;
}

#[tokio::test]
async fn fixing_the_token_in_the_env_file_recovers_from_unauthenticated() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/rest/api/3/search/jql"))
        .and(header("authorization", basic(EMAIL, GOOD_TOKEN).as_str()))
        .respond_with(ok(vec![simple("FIX-1")]))
        .mount(&server)
        .await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ResponseTemplate::new(401)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text("wrong-token"));
    let mut rx = source(&env, &server, Duration::from_millis(50)).spawn(Arc::new(Notify::new()));
    wait_state(&mut rx, SourceState::Unauthenticated).await;

    rewrite_env(&env, &env_text(GOOD_TOKEN));

    let update = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(ids(&flat(&update)), vec!["jira:FIX-1"]);
}

#[tokio::test]
async fn adding_credentials_to_the_env_file_recovers_from_not_configured() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("NEW-1")])).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), "");
    let mut rx = source(&env, &server, Duration::from_millis(50)).spawn(Arc::new(Notify::new()));
    wait_state(&mut rx, SourceState::NotConfigured).await;

    rewrite_env(&env, &env_text(GOOD_TOKEN));

    let update = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(ids(&flat(&update)), vec!["jira:NEW-1"]);
}

// ── detail ────────────────────────────────────────────────────────────────

async fn mount_detail(server: &MockServer, times: u64) {
    Mock::given(method("GET"))
        .and(path("/rest/api/3/issue/PROJ-1"))
        .and(query_param("expand", "renderedFields"))
        .and(query_param("fields", "summary,status,priority,assignee,description,duedate,updated"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "key": "PROJ-1",
            "fields": {
                "summary": "Fix login",
                "status": {"name": "In Progress"},
                "priority": {"name": "High"},
                "assignee": {"displayName": "Ada Lovelace"},
                "description": adf("The description paragraph."),
                "duedate": "2026-10-15",
                "updated": "2026-10-01T08:00:00.000+0000"
            }
        })))
        .expect(times)
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path("/rest/api/3/issue/PROJ-1/comment"))
        .and(query_param("orderBy", "-created"))
        .and(query_param("maxResults", "5"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "comments": [{
                "author": {"displayName": "Grace Hopper"},
                "created": "2026-10-02T10:00:00.000+0000",
                "body": adf("The newest comment text.")
            }]
        })))
        .expect(times)
        .mount(server)
        .await;
}

fn field<'a>(d: &'a nostromo::data::work::WorkDetail, name: &str) -> Option<&'a str> {
    d.fields.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

#[tokio::test]
async fn detail_shows_fields_description_comments_and_a_browse_link() {
    let server = MockServer::start().await;
    mount_detail(&server, 1).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let src = source(&env, &server, LONG);

    let d = src.detail("jira:PROJ-1").await.expect("detail");

    assert_eq!(d.item_id, "jira:PROJ-1");
    assert!(d.title.contains("PROJ-1") && d.title.contains("Fix login"), "{}", d.title);
    assert_eq!(field(&d, "Status"), Some("In Progress"));
    assert_eq!(field(&d, "Priority"), Some("High"));
    assert_eq!(field(&d, "Assignee"), Some("Ada Lovelace"));
    assert!(d.markdown.contains("The description paragraph."), "{}", d.markdown);
    assert!(d.markdown.contains("The newest comment text."), "{}", d.markdown);
    assert!(d.markdown.contains("Grace Hopper"), "comment author is shown: {}", d.markdown);
    assert!(d.links.iter().any(|l| l.url == "https://example.atlassian.net/browse/PROJ-1"), "{:?}", d.links);
    for r in requests(&server).await {
        assert_eq!(r.headers.get("authorization").unwrap().to_str().unwrap(), basic(EMAIL, GOOD_TOKEN));
    }
}

#[tokio::test]
async fn a_second_detail_call_within_a_minute_is_served_from_cache() {
    let server = MockServer::start().await;
    mount_detail(&server, 1).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let src = source(&env, &server, LONG);

    let first = src.detail("jira:PROJ-1").await.expect("first");
    let second = src.detail("jira:PROJ-1").await.expect("second");

    assert_eq!(first, second);
    server.verify().await;
}

#[tokio::test]
async fn invalid_issue_keys_are_refused_without_any_request() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let src = source(&env, &server, LONG);

    for bad in ["jira:../x", "jira:", "jira:PROJ", "jira:PROJ-1/../x", "jira:PROJ-1?x=1", "jira:-1", "jira:PROJ-abc", "PROJ-1", "todo:PROJ-1"] {
        let err = src.detail(bad).await.expect_err(bad);
        assert_eq!(err.code, "unknown_item", "{bad}");
    }
    assert!(requests(&server).await.is_empty(), "no request for an invalid key");
}

#[tokio::test]
async fn detail_with_a_rejected_token_names_the_variable_and_never_a_value() {
    let server = MockServer::start().await;
    Mock::given(method("GET")).respond_with(ResponseTemplate::new(401).set_body_string(SENTINEL)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(SENTINEL));
    let src = source(&env, &server, LONG);

    let err = src.detail("jira:PROJ-1").await.expect_err("rejected");

    assert!(err.message.contains("ATLASSIAN_API_TOKEN"), "{}", err.message);
    assert!(!err.message.contains(SENTINEL));
}

#[tokio::test]
async fn detail_without_credentials_is_an_error_and_sends_nothing() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let env = dir.path().join("missing.env");
    let src = source(&env, &server, LONG);

    assert!(src.detail("jira:PROJ-1").await.is_err());
    assert!(requests(&server).await.is_empty());
}

// ── hub and MCP ───────────────────────────────────────────────────────────

struct Rig {
    hub: Arc<WorkHub>,
    state: McpSharedState,
    _ttx: watch::Sender<Option<TeriTodosSnapshot>>,
}

fn a_todo() -> TeriTodo {
    TeriTodo {
        id: 1,
        title: "Write the report".into(),
        status: "open".into(),
        priority: 3,
        due_date: None,
        jira_key: None,
        body: None,
    }
}

fn rig(jira: Arc<JiraWorkSource>) -> Rig {
    let (btx, _brx) = broadcast::channel(1024);
    let (ttx, trx) = watch::channel(Some(TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        items: vec![a_todo()],
        ..Default::default()
    }));
    let hub = WorkHub::spawn(HubDeps { jira: Some(jira), ..HubDeps::new(btx, trx) });
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let mut state = McpSharedState::for_test(event_tx);
    state.work_hub = Some(hub.clone());
    Rig { hub, state, _ttx: ttx }
}

async fn hub_state(hub: &WorkHub, source: WorkSource, want: SourceState) -> SourceStatus {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let s = hub.status(source);
        if s.state == want {
            return s;
        }
        assert!(tokio::time::Instant::now() < deadline, "{source:?} never became {want:?}; is {:?}", s.state);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn jira_filter() -> WorkFilter {
    WorkFilter { sources: vec![WorkSource::Jira], ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn jira_items_reach_the_hub_and_mcp_list_work_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("HUB-1"), simple("HUB-2")])).mount(&server).await;
    mount_detail(&server, 1).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let rig = rig(source(&env, &server, LONG));
    hub_state(&rig.hub, WorkSource::Jira, SourceState::Fresh).await;

    let from_hub = ids(&rig.hub.items(&jira_filter()));
    let result = list_work_items(&rig.state, &json!({"source": "jira"}));

    assert_eq!(from_hub.len(), 2);
    assert!(from_hub.contains(&"jira:HUB-1".to_string()) && from_hub.contains(&"jira:HUB-2".to_string()));
    let from_mcp: Vec<String> =
        result["items"].as_array().unwrap().iter().map(|i| i["id"].as_str().unwrap().to_string()).collect();
    assert_eq!(from_mcp, from_hub);
    assert_eq!(result["total"], 2);
    let status = result["statuses"].as_array().unwrap().iter().find(|s| s["source"] == "jira").unwrap().clone();
    assert_eq!(status["state"], "fresh");

    let d = get_work_item(&rig.state, &json!({"id": "jira:PROJ-1"})).await;
    assert!(d.get("error").is_none(), "{d}");
    assert!(d["markdown"].as_str().unwrap().contains("The description paragraph."), "{d}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_jira_failure_does_not_change_the_todos_source() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ResponseTemplate::new(500)).mount(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(GOOD_TOKEN));
    let rig = rig(source(&env, &server, LONG));

    hub_state(&rig.hub, WorkSource::Jira, SourceState::Error).await;

    let todos = hub_state(&rig.hub, WorkSource::Todos, SourceState::Fresh).await;
    assert_eq!(todos.count, 1);
    assert!(todos.reason.is_none());
    assert_eq!(ids(&rig.hub.items(&WorkFilter { sources: vec![WorkSource::Todos], ..Default::default() })), vec!["todo:1"]);
}

// ── secrets never leak ────────────────────────────────────────────────────

#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl io::Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn status_json(s: &SourceStatus) -> String {
    serde_json::to_string(s).unwrap()
}

#[tokio::test]
async fn the_token_never_appears_in_statuses_items_details_mcp_output_or_logs() {
    let logs = LogBuf::default();
    let sink = logs.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .with_writer(move || sink.clone())
        .finish();
    let _guard = tracing::subscriber::set_default(subscriber);

    let mut dump = String::new();
    let dir = tempfile::tempdir().unwrap();
    let env = write_env(dir.path(), &env_text(SENTINEL));

    // Happy path, detail, and the same data through the hub and MCP.
    {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("PROJ-1")])).mount(&server).await;
        mount_detail(&server, 2).await;
        let src = source(&env, &server, LONG);
        let mut rx = src.clone().spawn(Arc::new(Notify::new()));
        let update = wait_state(&mut rx, SourceState::Fresh).await;
        dump += &status_json(&update.0);
        dump += &serde_json::to_string(&flat(&update)).unwrap();
        dump += &serde_json::to_string(&src.detail("jira:PROJ-1").await.unwrap()).unwrap();

        let rig = rig(source(&env, &server, LONG));
        hub_state(&rig.hub, WorkSource::Jira, SourceState::Fresh).await;
        dump += &list_work_items(&rig.state, &json!({})).to_string();
        dump += &get_work_item(&rig.state, &json!({"id": "jira:PROJ-1"})).await.to_string();
        dump += &serde_json::to_string(&rig.hub.statuses()).unwrap();
    }

    // 401 and 403 whose bodies echo the token and the auth header; detail rejected.
    for code in [401u16, 403] {
        let server = MockServer::start().await;
        let echo = format!("invalid {SENTINEL} {}", basic(EMAIL, SENTINEL));
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(code).set_body_string(echo.clone())).mount(&server).await;
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(code).set_body_string(echo)).mount(&server).await;
        let src = source(&env, &server, LONG);
        let mut rx = src.clone().spawn(Arc::new(Notify::new()));
        let update = wait_state(&mut rx, SourceState::Unauthenticated).await;
        dump += &status_json(&update.0);
        let err = src.detail("jira:PROJ-1").await.expect_err("rejected");
        dump += &format!("{} {} {:?}", err.code, err.message, err);
    }

    // Good data, then 429, then 500 (stale), all echoing the token in bodies.
    {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path("/rest/api/3/search/jql")).respond_with(ok(vec![simple("PROJ-1")])).up_to_n_times(1).mount(&server).await;
        Mock::given(method("POST"))
            .and(path("/rest/api/3/search/jql"))
            .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "1").set_body_string(SENTINEL))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/rest/api/3/search/jql"))
            .respond_with(ResponseTemplate::new(500).set_body_string(format!("oops {SENTINEL}")))
            .mount(&server)
            .await;
        let poke = Arc::new(Notify::new());
        let mut rx = source(&env, &server, LONG).spawn(poke.clone());
        wait_state(&mut rx, SourceState::Fresh).await;
        poke.notify_one();
        let limited = wait_state(&mut rx, SourceState::RateLimited).await;
        dump += &status_json(&limited.0);
        // The 429 wait is one second; the next fetch hits the 500.
        let stale = wait_state(&mut rx, SourceState::Stale).await;
        dump += &status_json(&stale.0);
        dump += &serde_json::to_string(&flat(&stale)).unwrap();
    }

    // Not configured: the token is present but the site is not.
    {
        let server = MockServer::start().await;
        let partial_dir = tempfile::tempdir().unwrap();
        let partial = write_env(
            partial_dir.path(),
            &format!("ATLASSIAN_USER_EMAIL={EMAIL}\nATLASSIAN_API_TOKEN={SENTINEL}\n"),
        );
        let mut rx = source(&partial, &server, LONG).spawn(Arc::new(Notify::new()));
        let update = wait_state(&mut rx, SourceState::NotConfigured).await;
        dump += &status_json(&update.0);
    }

    let logged = String::from_utf8_lossy(&logs.0.lock().unwrap()).to_string();
    assert!(!logged.is_empty(), "the log capture should have seen something");

    assert!(!dump.contains(SENTINEL), "the token leaked into a status, item, detail or MCP output");
    assert!(!dump.contains(&b64(&format!("{EMAIL}:{SENTINEL}"))), "the auth header leaked into an output");
    assert!(!logged.contains(SENTINEL), "the token was logged");
    assert!(!logged.contains(&b64(&format!("{EMAIL}:{SENTINEL}"))), "the Authorization header value was logged");
    assert!(!logged.contains(&b64(&EMAIL[..12])), "a prefix of the Authorization header was logged");
    assert!(!logged.contains(EMAIL), "the account email was logged");
}
