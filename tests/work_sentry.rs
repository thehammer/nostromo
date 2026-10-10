//! Sentry as a Teri work source: what gets fetched, how issues become work
//! items, how the source reports its health, and the issue detail view.
//!
//! Behavioural only: a wiremock server plays Sentry, a temp `.env` plays the
//! credentials file, and everything is observed through the source's `watch`
//! channel and `detail_with`. Nothing here looks inside the source.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Utc};
use nostromo::data::work::hub::SourceUpdate;
use nostromo::data::work::sentry::{detail_with, spawn_with, SentryConfig};
use nostromo::data::work::{SourceState, WorkDetail, WorkItem, WorkSource};
use serde_json::{json, Value};
use tokio::sync::{watch, Notify};
use tracing_subscriber::fmt::MakeWriter;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const WAIT: Duration = Duration::from_secs(5);
const TOKEN: &str = "tok_good";
const SENTINEL: &str = "snt_SENTINEL_TOKEN_DO_NOT_LEAK";
const QUERY_ASSIGNED: &str = "is:unresolved assigned:me";
const QUERY_UNASSIGNED: &str = "is:unresolved is:unassigned level:[error,fatal] lastSeen:-24h";
const NO_TOKEN_REASON: &str = "Sentry: no credentials found. Set SENTRY_API_TOKEN in \
                               ~/.claude/credentials/.env, as the sentry skill uses.";

// ── a fake Sentry ─────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Assigned,
    Unassigned,
}

#[derive(Clone)]
struct RateLimit {
    reset: i64,
    kind: Option<Kind>,
    page: Option<usize>,
}

#[derive(Clone)]
enum Mode {
    Ok,
    /// Fail every list request with this status (and optional Retry-After).
    Fail { status: u16, retry_after: Option<u64>, body: String },
}

struct State {
    base: String,
    assigned: Vec<Value>,
    unassigned: Vec<Value>,
    page_size: usize,
    mode: Mode,
    /// When set, only this bearer token is accepted (others get 401).
    required_token: Option<String>,
    rate_limit: Option<RateLimit>,
}

struct Issues(Arc<Mutex<State>>);

fn kind_of(query: &str) -> Kind {
    if query.contains("is:unassigned") {
        Kind::Unassigned
    } else {
        Kind::Assigned
    }
}

impl Respond for Issues {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let st = self.0.lock().unwrap();
        let param = |name: &str| {
            req.url.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.to_string())
        };
        if let Some(req_token) = &st.required_token {
            let got = req
                .headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            if got != format!("Bearer {req_token}") {
                return ResponseTemplate::new(401).set_body_json(json!({"detail": "bad token"}));
            }
        }
        if let Mode::Fail { status, retry_after, body } = &st.mode {
            let mut t = ResponseTemplate::new(*status).set_body_string(body.clone());
            if let Some(s) = retry_after {
                t = t.insert_header("Retry-After", s.to_string().as_str());
            }
            return t;
        }
        let query = param("query").unwrap_or_default();
        let kind = kind_of(&query);
        let all = if kind == Kind::Assigned { &st.assigned } else { &st.unassigned };
        let page: usize = param("cursor").and_then(|c| c.parse().ok()).unwrap_or(0);
        let start = (page * st.page_size).min(all.len());
        let end = (start + st.page_size).min(all.len());
        let more = end < all.len();

        let mk = |cursor: usize| {
            let mut u = url::Url::parse(&format!("{}/organizations/acme/issues/", st.base)).unwrap();
            u.query_pairs_mut()
                .append_pair("limit", "100")
                .append_pair("project", "-1")
                .append_pair("query", &query)
                .append_pair("statsPeriod", "24h")
                .append_pair("cursor", &cursor.to_string());
            u.to_string()
        };
        let prev = mk(page.saturating_sub(1));
        let next = mk(page + 1);
        let link = format!(
            "<{prev}>; rel=\"previous\"; results=\"{}\"; cursor=\"{}\", \
             <{next}>; rel=\"next\"; results=\"{more}\"; cursor=\"{}\"",
            page > 0,
            page.saturating_sub(1),
            page + 1
        );
        let mut t = ResponseTemplate::new(200)
            .set_body_json(Value::Array(all[start..end].to_vec()))
            .insert_header("Link", link.as_str());
        if let Some(rl) = &st.rate_limit {
            if rl.kind.is_none_or(|k| k == kind) && rl.page.is_none_or(|p| p == page) {
                t = t
                    .insert_header("X-Sentry-Rate-Limit-Remaining", "0")
                    .insert_header("X-Sentry-Rate-Limit-Reset", rl.reset.to_string().as_str());
            }
        }
        t
    }
}

struct Fake {
    server: MockServer,
    state: Arc<Mutex<State>>,
}

impl Fake {
    async fn start(assigned: Vec<Value>, unassigned: Vec<Value>) -> Fake {
        let server = MockServer::builder().start().await;
        let state = Arc::new(Mutex::new(State {
            base: format!("{}/api/0", server.uri()),
            assigned,
            unassigned,
            page_size: 100,
            mode: Mode::Ok,
            required_token: None,
            rate_limit: None,
        }));
        Mock::given(method("GET"))
            .and(path("/api/0/organizations/acme/issues/"))
            .respond_with(Issues(state.clone()))
            .mount(&server)
            .await;
        Fake { server, state }
    }

    fn set(&self, f: impl FnOnce(&mut State)) {
        f(&mut self.state.lock().unwrap());
    }

    fn fail(&self, status: u16) {
        self.set(|s| s.mode = Mode::Fail { status, retry_after: None, body: "boom".into() });
    }

    fn recover(&self) {
        self.set(|s| s.mode = Mode::Ok);
    }

    async fn list_requests(&self) -> Vec<Request> {
        self.server
            .received_requests()
            .await
            .unwrap_or_default()
            .into_iter()
            .filter(|r| r.url.path().ends_with("/organizations/acme/issues/"))
            .collect()
    }
}

// ── builders & helpers ────────────────────────────────────────────────────────

fn issue(id: u32) -> Value {
    json!({
        "id": id.to_string(),
        "shortId": format!("WEB-{id}"),
        "title": format!("Boom {id}"),
        "culprit": format!("app.mod.func{id}"),
        "level": "error",
        "status": "unresolved",
        "substatus": "ongoing",
        "project": {"slug": "web-app", "name": "Web App"},
        "firstSeen": "2026-10-09T01:02:03.000000Z",
        "lastSeen": "2026-10-10T04:05:06.000000Z",
        "count": "10",
        "userCount": 2,
        "permalink": format!("https://sentry.example/organizations/acme/issues/{id}/"),
        "environments": [],
        "stats": {"24h": [[1760000000, 1], [1760003600, 2]]},
    })
}

fn with(mut v: Value, key: &str, val: Value) -> Value {
    v[key] = val;
    v
}

fn issues(ids: std::ops::RangeInclusive<u32>) -> Vec<Value> {
    ids.map(issue).collect()
}

struct Env {
    dir: tempfile::TempDir,
    bump: AtomicU64,
}

impl Env {
    fn new(token: Option<&str>) -> Env {
        let env = Env { dir: tempfile::tempdir().unwrap(), bump: AtomicU64::new(10) };
        if let Some(t) = token {
            env.write_token(t);
        }
        env
    }

    fn env_path(&self) -> PathBuf {
        self.dir.path().join(".env")
    }

    fn repos_path(&self) -> PathBuf {
        self.dir.path().join("sentry-repos.json")
    }

    /// Write `contents` and push the mtime forward so a change is always seen,
    /// whatever the filesystem's timestamp granularity.
    fn write_bumped(&self, path: &Path, contents: &str) {
        std::fs::write(path, contents).unwrap();
        let n = self.bump.fetch_add(10, Ordering::SeqCst);
        let later = SystemTime::now() + Duration::from_secs(n);
        std::fs::File::options().write(true).open(path).unwrap().set_modified(later).unwrap();
    }

    fn write_token(&self, token: &str) {
        self.write_bumped(&self.env_path(), &format!("SENTRY_API_TOKEN={token}\n"));
    }

    fn write_repos(&self, json: &str) {
        self.write_bumped(&self.repos_path(), json);
    }

    fn config(&self, base: &str) -> SentryConfig {
        let mut c = SentryConfig::new(
            base.to_string(),
            "acme".into(),
            self.env_path(),
            self.repos_path(),
        );
        // Tests drive fetches with `refresh`; the timer only fires when a test
        // shortens it on purpose.
        c.poll_interval = Duration::from_secs(3600);
        c.backoff_base = Duration::from_millis(50);
        c
    }
}

fn base_of(fake: &Fake) -> String {
    format!("{}/api/0", fake.server.uri())
}

fn start(cfg: SentryConfig) -> (watch::Receiver<SourceUpdate>, Arc<Notify>) {
    let refresh = Arc::new(Notify::new());
    (spawn_with(cfg, refresh.clone()), refresh)
}

async fn wait_for(
    rx: &mut watch::Receiver<SourceUpdate>,
    what: &str,
    pred: impl Fn(&SourceUpdate) -> bool,
) -> SourceUpdate {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        {
            let v = rx.borrow_and_update().clone();
            if pred(&v) {
                return v;
            }
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, rx.changed()).await {
            Err(_) => panic!("timed out waiting for {what}; last: {:?}", rx.borrow().0),
            Ok(Err(_)) => panic!("source channel closed while waiting for {what}"),
            Ok(Ok(())) => {}
        }
    }
}

async fn wait_state(rx: &mut watch::Receiver<SourceUpdate>, state: SourceState) -> SourceUpdate {
    wait_for(rx, &format!("state {state:?}"), |u| u.0.state == state).await
}

fn items(u: &SourceUpdate) -> Vec<WorkItem> {
    assert!(u.1.len() <= 1, "expected a single ungrouped list");
    u.1.iter().flat_map(|(g, items)| {
        assert!(g.is_none(), "Sentry items are in the `None` group");
        items.clone()
    })
    .collect()
}

fn sorted_ids(u: &SourceUpdate) -> Vec<String> {
    let mut ids: Vec<String> = items(u).into_iter().map(|i| i.id).collect();
    ids.sort();
    ids
}

fn ids_of(range: std::ops::RangeInclusive<u32>) -> Vec<String> {
    let mut v: Vec<String> = range.map(|i| format!("sentry:{i}")).collect();
    v.sort();
    v
}

fn item(u: &SourceUpdate, id: &str) -> WorkItem {
    items(u).into_iter().find(|i| i.id == id).unwrap_or_else(|| panic!("no item {id}"))
}

fn ts(s: &str) -> DateTime<Utc> {
    s.parse().unwrap()
}

fn field<'a>(d: &'a WorkDetail, label: &str) -> &'a str {
    d.fields
        .iter()
        .find(|(k, _)| k == label)
        .map(|(_, v)| v.as_str())
        .unwrap_or_else(|| panic!("no field {label:?} in {:?}", d.fields))
}

/// Fresh source over the given issues, with a good token in the .env file.
async fn fresh_source(
    assigned: Vec<Value>,
    unassigned: Vec<Value>,
) -> (Fake, Env, watch::Receiver<SourceUpdate>, Arc<Notify>, SourceUpdate) {
    let fake = Fake::start(assigned, unassigned).await;
    let env = Env::new(Some(TOKEN));
    let (mut rx, refresh) = start(env.config(&base_of(&fake)));
    let first = wait_for(&mut rx, "first fetch", |u| {
        matches!(u.0.state, SourceState::Fresh | SourceState::Empty)
    })
    .await;
    (fake, env, rx, refresh, first)
}

fn process_token_is_set() -> bool {
    let set = std::env::var("SENTRY_API_TOKEN").map(|v| !v.is_empty()).unwrap_or(false);
    if set {
        eprintln!("SENTRY_API_TOKEN is set in the process environment; skipping");
    }
    set
}

// ── what is fetched ───────────────────────────────────────────────────────────

#[tokio::test]
async fn an_issue_in_both_queries_appears_once() {
    if process_token_is_set() {
        return;
    }
    let (_f, _e, _rx, _r, first) =
        fresh_source(issues(1..=2), vec![issue(1), issue(3)]).await;
    assert_eq!(first.0.state, SourceState::Fresh);
    assert_eq!(sorted_ids(&first), ids_of(1..=3));
    assert_eq!(first.0.count, 3);
    assert!(first.0.updated_at.is_some(), "a successful fetch stamps updated_at");
    assert_eq!(first.0.source, WorkSource::Sentry);
}

#[tokio::test]
async fn it_asks_sentry_for_both_queries_with_the_bearer_token() {
    if process_token_is_set() {
        return;
    }
    let (fake, _e, _rx, _r, _first) = fresh_source(issues(1..=1), issues(2..=2)).await;
    let reqs = fake.list_requests().await;
    let queries: Vec<String> = reqs
        .iter()
        .filter(|r| !r.url.query_pairs().any(|(k, _)| k == "cursor"))
        .map(|r| r.url.query_pairs().find(|(k, _)| k == "query").unwrap().1.to_string())
        .collect();
    assert!(queries.contains(&QUERY_ASSIGNED.to_string()), "queries sent: {queries:?}");
    assert!(queries.contains(&QUERY_UNASSIGNED.to_string()), "queries sent: {queries:?}");
    for r in &reqs {
        let q = |k: &str| r.url.query_pairs().find(|(n, _)| n == k).map(|(_, v)| v.to_string());
        assert_eq!(q("project").as_deref(), Some("-1"));
        assert_eq!(q("statsPeriod").as_deref(), Some("24h"));
        assert_eq!(q("limit").as_deref(), Some("100"));
        assert_eq!(
            r.headers.get("authorization").and_then(|v| v.to_str().ok()),
            Some(format!("Bearer {TOKEN}").as_str())
        );
    }
}

#[tokio::test]
async fn it_follows_the_link_header_across_pages() {
    if process_token_is_set() {
        return;
    }
    let (_f, _e, _rx, _r, first) = fresh_source(issues(1..=250), issues(1001..=1003)).await;
    let mut expected = ids_of(1..=250);
    expected.extend(ids_of(1001..=1003));
    expected.sort();
    assert_eq!(sorted_ids(&first), expected);
}

#[tokio::test]
async fn it_stops_at_300_issues_per_query() {
    if process_token_is_set() {
        return;
    }
    let (_f, _e, _rx, _r, first) = fresh_source(issues(1..=400), vec![]).await;
    assert_eq!(items(&first).len(), 300);
    assert_eq!(first.0.count, 300);
}

#[tokio::test]
async fn it_refetches_on_the_poll_interval_without_being_asked() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=1), vec![]).await;
    let env = Env::new(Some(TOKEN));
    let mut cfg = env.config(&base_of(&fake));
    cfg.poll_interval = Duration::from_millis(100);
    let (mut rx, _refresh) = start(cfg);
    wait_for(&mut rx, "first item", |u| sorted_ids(u) == ids_of(1..=1)).await;
    fake.set(|s| s.assigned = issues(1..=2));
    wait_for(&mut rx, "the second item via polling", |u| sorted_ids(u) == ids_of(1..=2)).await;
}

#[tokio::test]
async fn a_manual_refresh_fetches_immediately() {
    if process_token_is_set() {
        return;
    }
    let (fake, _e, mut rx, refresh, _first) = fresh_source(issues(1..=1), vec![]).await;
    fake.set(|s| s.assigned = issues(1..=2));
    refresh.notify_one();
    wait_for(&mut rx, "the refreshed item", |u| sorted_ids(u) == ids_of(1..=2)).await;
}

// ── item mapping ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn an_issue_maps_to_a_work_item() {
    if process_token_is_set() {
        return;
    }
    let mut i = issue(42);
    i["environments"] = json!(["production", "staging"]);
    i["userCount"] = json!(7);
    i["stats"] = json!({"24h": [[1, 3], [2, 4], [3, 0]]});
    i["culprit"] = json!("billing.invoice.render");
    let (_f, _e, _rx, _r, first) = fresh_source(vec![i], vec![]).await;
    let it = item(&first, "sentry:42");
    assert_eq!(it.source, WorkSource::Sentry);
    assert_eq!(it.kind, "issue");
    assert_eq!(it.title, "Boom 42");
    assert_eq!(it.project.as_deref(), Some("web-app"));
    assert_eq!(it.environment.as_deref(), Some("production"));
    assert_eq!(it.metrics.get("events_24h"), Some(&7));
    assert_eq!(it.metrics.get("users"), Some(&7));
    assert_eq!(it.created_at, Some(ts("2026-10-09T01:02:03Z")));
    assert_eq!(it.updated_at, Some(ts("2026-10-10T04:05:06Z")));
    assert_eq!(it.status.as_deref(), Some("ongoing"));
    assert_eq!(it.url.as_deref(), Some("https://sentry.example/organizations/acme/issues/42/"));
    assert_eq!(it.severity.as_deref(), Some("error"));
    for needle in ["WEB-42", "Boom 42", "billing.invoice.render"] {
        assert!(it.search_text.contains(needle), "search_text lacks {needle:?}: {}", it.search_text);
    }
    assert!(it.linked.contains(&"WEB-42".to_string()));
}

#[tokio::test]
async fn status_falls_back_to_the_issue_status_and_a_missing_environment_is_omitted() {
    if process_token_is_set() {
        return;
    }
    let mut i = issue(5);
    i.as_object_mut().unwrap().remove("substatus");
    i["status"] = json!("regressed");
    let (_f, _e, _rx, _r, first) = fresh_source(vec![i], vec![]).await;
    let it = item(&first, "sentry:5");
    assert_eq!(it.status.as_deref(), Some("regressed"));
    assert_eq!(it.environment, None);
}

#[tokio::test]
async fn level_becomes_priority_and_severity() {
    if process_token_is_set() {
        return;
    }
    let assigned = vec![
        with(issue(1), "level", json!("fatal")),
        with(issue(2), "level", json!("error")),
        with(issue(3), "level", json!("warning")),
        with(issue(4), "level", json!("info")),
    ];
    let (_f, _e, _rx, _r, first) = fresh_source(assigned, vec![]).await;
    let expect = [("sentry:1", "fatal", 1), ("sentry:2", "error", 2), ("sentry:3", "warning", 3), ("sentry:4", "info", 4)];
    for (id, label, rank) in expect {
        let it = item(&first, id);
        let p = it.priority.unwrap_or_else(|| panic!("{id} has no priority"));
        assert_eq!((p.label.as_str(), p.rank), (label, rank), "{id}");
        assert_eq!(it.severity.as_deref(), Some(label), "{id}");
    }
}

// ── repo mapping file ─────────────────────────────────────────────────────────

#[tokio::test]
async fn projects_map_to_repos_through_the_repos_file() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(
        vec![issue(1), with(issue(2), "project", json!({"slug": "other-proj"}))],
        vec![],
    )
    .await;
    let env = Env::new(Some(TOKEN));
    env.write_repos(r#"{"web-app": "portal"}"#);
    let (mut rx, _r) = start(env.config(&base_of(&fake)));
    let first = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(item(&first, "sentry:1").repo.as_deref(), Some("portal"));
    assert_eq!(item(&first, "sentry:2").repo, None, "unmapped project has no repo");
}

#[tokio::test]
async fn without_a_repos_file_items_have_no_repo() {
    if process_token_is_set() {
        return;
    }
    let (_f, _e, _rx, _r, first) = fresh_source(issues(1..=1), vec![]).await;
    assert_eq!(item(&first, "sentry:1").repo, None);
}

#[tokio::test]
async fn a_changed_repos_file_is_picked_up_without_a_restart() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=1), vec![]).await;
    let env = Env::new(Some(TOKEN));
    env.write_repos(r#"{"web-app": "portal"}"#);
    let (mut rx, refresh) = start(env.config(&base_of(&fake)));
    wait_for(&mut rx, "old mapping", |u| {
        u.1.iter().flat_map(|g| &g.1).any(|i| i.repo.as_deref() == Some("portal"))
    })
    .await;
    env.write_repos(r#"{"web-app": "billing"}"#);
    refresh.notify_one();
    wait_for(&mut rx, "new mapping", |u| {
        u.1.iter().flat_map(|g| &g.1).any(|i| i.repo.as_deref() == Some("billing"))
    })
    .await;
}

// ── status: success shapes ────────────────────────────────────────────────────

#[tokio::test]
async fn no_issues_is_empty_not_fresh() {
    if process_token_is_set() {
        return;
    }
    let (_f, _e, _rx, _r, first) = fresh_source(vec![], vec![]).await;
    assert_eq!(first.0.state, SourceState::Empty);
    assert_eq!(first.0.count, 0);
    assert!(items(&first).is_empty());
}

// ── status: credentials ───────────────────────────────────────────────────────

#[tokio::test]
async fn without_a_token_it_is_not_configured_and_makes_no_requests() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=1), vec![]).await;
    let env = Env::new(None);
    let (mut rx, refresh) = start(env.config(&base_of(&fake)));
    let u = wait_state(&mut rx, SourceState::NotConfigured).await;
    assert_eq!(u.0.reason.as_deref(), Some(NO_TOKEN_REASON));
    assert!(items(&u).is_empty());
    refresh.notify_one();
    // Settle: a refresh must not trigger a request either.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(fake.server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_rejected_token_is_unauthenticated_and_fixing_the_env_file_recovers() {
    if process_token_is_set() {
        return;
    }
    let (fake, env, mut rx, refresh, first) = fresh_source(issues(1..=2), vec![]).await;
    assert_eq!(first.0.state, SourceState::Fresh);
    fake.set(|s| s.required_token = Some("tok_rotated".into()));

    refresh.notify_one();
    let u = wait_state(&mut rx, SourceState::Unauthenticated).await;
    assert!(items(&u).is_empty(), "items are cleared when Sentry rejects the token");
    assert_eq!(u.0.count, 0);

    env.write_token("tok_rotated");
    refresh.notify_one();
    let u = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(sorted_ids(&u), ids_of(1..=2));
}

#[tokio::test]
async fn a_forbidden_token_is_unauthenticated_too() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=1), vec![]).await;
    fake.fail(403);
    let env = Env::new(Some(TOKEN));
    let (mut rx, _r) = start(env.config(&base_of(&fake)));
    let u = wait_state(&mut rx, SourceState::Unauthenticated).await;
    assert!(items(&u).is_empty());
}

// ── status: rate limits ───────────────────────────────────────────────────────

#[tokio::test]
async fn a_429_is_rate_limited_until_retry_after_and_keeps_items() {
    if process_token_is_set() {
        return;
    }
    let (fake, _e, mut rx, refresh, _first) = fresh_source(issues(1..=2), vec![]).await;
    fake.set(|s| {
        s.mode = Mode::Fail { status: 429, retry_after: Some(120), body: "slow down".into() }
    });
    let before = Utc::now();
    refresh.notify_one();
    let u = wait_state(&mut rx, SourceState::RateLimited).await;
    let retry_at = u.0.retry_at.expect("rate limited sources say when they retry");
    let secs = (retry_at - before).num_seconds();
    assert!((115..=125).contains(&secs), "retry_at should be ~120 s out, was {secs} s");
    assert_eq!(sorted_ids(&u), ids_of(1..=2), "items are kept while rate limited");

    // And it really waits: no further list requests inside the window.
    let n = fake.list_requests().await.len();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fake.list_requests().await.len(), n);
}

#[tokio::test]
async fn an_exhausted_rate_limit_header_defers_the_next_fetch_but_stays_fresh() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=2), issues(3..=3)).await;
    let reset = Utc::now().timestamp() + 3600;
    // Only the final request of the fetch carries the header: the fetch
    // completes, so the source is healthy but must hold off until `reset`.
    fake.set(|s| s.rate_limit = Some(RateLimit { reset, kind: Some(Kind::Unassigned), page: None }));
    let env = Env::new(Some(TOKEN));
    let mut cfg = env.config(&base_of(&fake));
    cfg.poll_interval = Duration::from_millis(30);
    let (mut rx, refresh) = start(cfg);
    let u = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(sorted_ids(&u), ids_of(1..=3));

    let n = fake.list_requests().await.len();
    refresh.notify_one();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        fake.list_requests().await.len(),
        n,
        "no list requests before the rate limit resets, despite a 30 ms poll interval"
    );
    assert_eq!(rx.borrow().0.state, SourceState::Fresh);
}

#[tokio::test]
async fn running_out_of_quota_mid_fetch_is_rate_limited_until_the_reset_time() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=150), vec![]).await;
    let reset = Utc::now().timestamp() + 3600;
    // The first page says "no quota left" while another page is still to come.
    fake.set(|s| s.rate_limit = Some(RateLimit { reset, kind: Some(Kind::Assigned), page: Some(0) }));
    let env = Env::new(Some(TOKEN));
    let (mut rx, _r) = start(env.config(&base_of(&fake)));
    let u = wait_state(&mut rx, SourceState::RateLimited).await;
    let retry_at = u.0.retry_at.expect("retry_at is the reset time");
    assert!((retry_at.timestamp() - reset).abs() <= 1, "retry_at {retry_at} vs reset {reset}");
}

// ── status: outages ───────────────────────────────────────────────────────────

#[tokio::test]
async fn a_server_error_after_success_is_stale_and_keeps_the_last_items() {
    if process_token_is_set() {
        return;
    }
    let (fake, _e, mut rx, refresh, first) = fresh_source(issues(1..=3), vec![]).await;
    let stamped = first.0.updated_at;
    fake.fail(503);
    refresh.notify_one();
    let u = wait_state(&mut rx, SourceState::Stale).await;
    assert_eq!(sorted_ids(&u), ids_of(1..=3));
    assert!(!u.0.reason.clone().unwrap_or_default().is_empty(), "stale says why");
    assert_eq!(u.0.updated_at, stamped, "updated_at stays at the last good fetch");
}

#[tokio::test]
async fn an_unreachable_sentry_after_success_is_stale() {
    if process_token_is_set() {
        return;
    }
    let (fake, _e, mut rx, refresh, _first) = fresh_source(issues(1..=3), vec![]).await;
    let Fake { server, .. } = fake;
    drop(server);
    // The fake server shuts down asynchronously: ask again until it is really gone.
    let mut u = rx.borrow().clone();
    for _ in 0..100 {
        refresh.notify_one();
        let _ = tokio::time::timeout(Duration::from_millis(100), rx.changed()).await;
        u = rx.borrow_and_update().clone();
        if u.0.state == SourceState::Stale {
            break;
        }
    }
    assert_eq!(u.0.state, SourceState::Stale, "last: {:?}", u.0);
    assert_eq!(sorted_ids(&u), ids_of(1..=3));
    assert!(!u.0.reason.clone().unwrap_or_default().is_empty());
}

#[tokio::test]
async fn a_server_error_with_no_prior_success_is_an_error() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=1), vec![]).await;
    fake.fail(500);
    let env = Env::new(Some(TOKEN));
    let (mut rx, _r) = start(env.config(&base_of(&fake)));
    let u = wait_state(&mut rx, SourceState::Error).await;
    assert!(items(&u).is_empty());
    assert!(!u.0.reason.clone().unwrap_or_default().is_empty());
}

#[tokio::test]
async fn it_retries_on_its_own_after_a_failure_and_recovers() {
    if process_token_is_set() {
        return;
    }
    let fake = Fake::start(issues(1..=2), vec![]).await;
    fake.fail(500);
    let env = Env::new(Some(TOKEN));
    // poll_interval stays at an hour, so only the backoff timer can retry.
    let (mut rx, _r) = start(env.config(&base_of(&fake)));
    wait_state(&mut rx, SourceState::Error).await;
    fake.recover();
    let u = wait_state(&mut rx, SourceState::Fresh).await;
    assert_eq!(sorted_ids(&u), ids_of(1..=2));
}

// ── detail ────────────────────────────────────────────────────────────────────

fn frame(i: usize) -> Value {
    json!({
        "filename": format!("app/f{i}.py"),
        "lineNo": 100 + i,
        "function": format!("fn{i}"),
        "inApp": i.is_multiple_of(2),
    })
}

fn detail_issue(id: u32, assignee: Value) -> Value {
    json!({
        "id": id.to_string(),
        "title": "KeyError: 'x'",
        "culprit": "app.views.checkout",
        "count": "1234",
        "userCount": 17,
        "firstSeen": "2026-10-01T00:00:00.000000Z",
        "lastSeen": "2026-10-10T04:05:06.000000Z",
        "level": "error",
        "assignee": assignee,
        "project": {"slug": "web-app"},
        "environments": ["production"],
        "permalink": format!("https://sentry.example/organizations/acme/issues/{id}/"),
        "stats": {"24h": [[1, 3], [2, 4]]},
    })
}

fn latest_event(frames: Vec<Value>) -> Value {
    json!({"entries": [
        {"type": "message", "data": {"formatted": "ignored"}},
        {"type": "exception", "data": {"values": [
            {"type": "KeyError", "value": "'x'", "stacktrace": {"frames": frames}},
            {"type": "Other", "value": "second", "stacktrace": {"frames": [
                {"filename": "other/second.py", "lineNo": 1, "function": "second", "inApp": true}
            ]}},
        ]}},
    ]})
}

async fn mount_detail(server: &MockServer, id: u32, issue: Value, event: Value) {
    let p = format!("/api/0/issues/{id}/");
    Mock::given(method("GET"))
        .and(path(p.clone()))
        .and(header("authorization", format!("Bearer {TOKEN}").as_str()))
        .respond_with(ResponseTemplate::new(200).set_body_json(issue))
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("{p}events/latest/")))
        .and(header("authorization", format!("Bearer {TOKEN}").as_str()))
        .respond_with(ResponseTemplate::new(200).set_body_json(event))
        .mount(server)
        .await;
}

fn detail_cfg(server: &MockServer, env: &Env) -> SentryConfig {
    env.config(&format!("{}/api/0", server.uri()))
}

#[tokio::test]
async fn detail_summarises_the_issue_in_fields_and_links_to_sentry() {
    if process_token_is_set() {
        return;
    }
    let server = MockServer::builder().start().await;
    mount_detail(&server, 42, detail_issue(42, json!({"name": "Hammer"})), latest_event(vec![frame(0)])).await;
    let env = Env::new(Some(TOKEN));
    let d = detail_with(&detail_cfg(&server, &env), "sentry:42").await.expect("detail");
    assert_eq!(d.item_id, "sentry:42");
    assert_eq!(d.title, "KeyError: 'x'");
    assert_eq!(field(&d, "Events"), "1234 total, 7 in 24 h");
    assert_eq!(field(&d, "Users"), "17");
    assert!(field(&d, "First seen").contains("2026-10-01"));
    assert!(field(&d, "Last seen").contains("2026-10-10"));
    assert_eq!(field(&d, "Environment"), "production");
    assert_eq!(field(&d, "Level"), "error");
    assert_eq!(field(&d, "Assignee"), "Hammer");
    assert_eq!(field(&d, "Culprit"), "app.views.checkout");
    assert!(d.links.iter().any(|l| l.label == "Open in Sentry"
        && l.url == "https://sentry.example/organizations/acme/issues/42/"));
}

#[tokio::test]
async fn an_unassigned_issue_says_unassigned() {
    if process_token_is_set() {
        return;
    }
    let server = MockServer::builder().start().await;
    mount_detail(&server, 43, detail_issue(43, Value::Null), latest_event(vec![frame(0)])).await;
    let env = Env::new(Some(TOKEN));
    let d = detail_with(&detail_cfg(&server, &env), "sentry:43").await.expect("detail");
    assert_eq!(field(&d, "Assignee"), "Unassigned");
}

#[tokio::test]
async fn detail_shows_the_top_ten_frames_innermost_first_with_in_app_marked() {
    if process_token_is_set() {
        return;
    }
    let server = MockServer::builder().start().await;
    // Sentry orders frames oldest-first: f14 is the innermost call.
    let frames: Vec<Value> = (0..15).map(frame).collect();
    mount_detail(&server, 44, detail_issue(44, Value::Null), latest_event(frames)).await;
    let env = Env::new(Some(TOKEN));
    let d = detail_with(&detail_cfg(&server, &env), "sentry:44").await.expect("detail");

    let lines: Vec<&str> = d.markdown.lines().filter(|l| l.contains("app/f")).collect();
    let expected: Vec<String> = (5..15)
        .rev()
        .map(|i| {
            let marker = if i % 2 == 0 { "● " } else { "  " };
            format!("{marker}app/f{i}.py:{} in fn{i}", 100 + i)
        })
        .collect();
    assert_eq!(lines, expected.iter().map(String::as_str).collect::<Vec<_>>());
    assert!(!d.markdown.contains("other/second.py"), "only the first exception is shown");
}

#[tokio::test]
async fn an_unknown_issue_is_unknown_item() {
    if process_token_is_set() {
        return;
    }
    let server = MockServer::builder().start().await; // nothing mounted: every path is a 404
    let env = Env::new(Some(TOKEN));
    let e = detail_with(&detail_cfg(&server, &env), "sentry:999").await.unwrap_err();
    assert_eq!(e.code, "unknown_item");
}

#[tokio::test]
async fn a_rejected_token_makes_detail_unauthenticated() {
    if process_token_is_set() {
        return;
    }
    for status in [401u16, 403] {
        let server = MockServer::builder().start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(status))
            .mount(&server)
            .await;
        let env = Env::new(Some(TOKEN));
        let e = detail_with(&detail_cfg(&server, &env), "sentry:1").await.unwrap_err();
        assert_eq!(e.code, "unauthenticated", "status {status}");
    }
}

#[tokio::test]
async fn detail_without_a_token_is_not_configured_and_makes_no_requests() {
    if process_token_is_set() {
        return;
    }
    let server = MockServer::builder().start().await;
    let env = Env::new(None);
    let e = detail_with(&detail_cfg(&server, &env), "sentry:1").await.unwrap_err();
    assert_eq!(e.code, "not_configured");
    assert!(server.received_requests().await.unwrap().is_empty());
}

// ── the token never leaks ─────────────────────────────────────────────────────

#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl io::Write for LogBuf {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for LogBuf {
    type Writer = LogBuf;
    fn make_writer(&'a self) -> LogBuf {
        self.clone()
    }
}

fn dump(u: &SourceUpdate) -> String {
    serde_json::to_string(&(&u.0, &u.1)).unwrap()
}

/// Current-thread runtime (the `#[tokio::test]` default) so the source's
/// tasks run on this thread and the thread-local subscriber sees them.
#[tokio::test]
async fn the_token_never_appears_in_status_items_details_or_logs() {
    if process_token_is_set() {
        return;
    }
    let log = LogBuf::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(log.clone())
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .finish();
    let _guard = tracing::subscriber::set_default(subscriber);

    let mut outputs: Vec<String> = Vec::new();
    let echo = format!("{{\"detail\": \"invalid token {SENTINEL}\"}}");

    // Failure shapes whose bodies echo the token back.
    let cases: [(u16, Option<u64>, SourceState); 4] = [
        (401, None, SourceState::Unauthenticated),
        (403, None, SourceState::Unauthenticated),
        (500, None, SourceState::Error),
        (429, Some(60), SourceState::RateLimited),
    ];
    for (status, retry_after, state) in cases {
        let fake = Fake::start(issues(1..=1), vec![]).await;
        fake.set(|s| s.mode = Mode::Fail { status, retry_after, body: echo.clone() });
        let env = Env::new(Some(SENTINEL));
        let (mut rx, _r) = start(env.config(&base_of(&fake)));
        let u = wait_state(&mut rx, state).await;
        outputs.push(dump(&u));
        let sent = fake.list_requests().await;
        assert!(
            sent.iter().any(|r| r
                .headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| v.contains(SENTINEL))),
            "the token must actually be sent for this test to mean anything"
        );
    }

    // A healthy fetch carrying real items.
    let (_f, _e, _rx, _r, first) = fresh_source_with_token(SENTINEL, issues(1..=3), vec![]).await;
    outputs.push(dump(&first));

    // Detail: success and each failure, with the token echoed in error bodies.
    let server = MockServer::builder().start().await;
    let env = Env::new(Some(SENTINEL));
    Mock::given(method("GET"))
        .and(path("/api/0/issues/1/"))
        .respond_with(ResponseTemplate::new(200).set_body_json(detail_issue(1, Value::Null)))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/api/0/issues/1/events/latest/"))
        .respond_with(ResponseTemplate::new(200).set_body_json(latest_event(vec![frame(0)])))
        .mount(&server)
        .await;
    for (id, status) in [(2u32, 401u16), (3, 403), (4, 404), (5, 500)] {
        Mock::given(method("GET"))
            .and(path(format!("/api/0/issues/{id}/")))
            .respond_with(ResponseTemplate::new(status).set_body_string(echo.clone()))
            .mount(&server)
            .await;
    }
    let cfg = detail_cfg(&server, &env);
    match detail_with(&cfg, "sentry:1").await {
        Ok(d) => outputs.push(serde_json::to_string(&d).unwrap()),
        Err(e) => panic!("detail should succeed: {e:?}"),
    }
    for id in 2..=5 {
        match detail_with(&cfg, &format!("sentry:{id}")).await {
            Ok(d) => outputs.push(serde_json::to_string(&d).unwrap()),
            Err(e) => outputs.push(serde_json::to_string(&e).unwrap()),
        }
    }

    for (n, out) in outputs.iter().enumerate() {
        assert!(!out.contains(SENTINEL), "output #{n} leaked the token: {out}");
    }
    let logs = String::from_utf8_lossy(&log.0.lock().unwrap()).to_string();
    assert!(!logs.contains(SENTINEL), "tracing output leaked the token:\n{logs}");
}

async fn fresh_source_with_token(
    token: &str,
    assigned: Vec<Value>,
    unassigned: Vec<Value>,
) -> (Fake, Env, watch::Receiver<SourceUpdate>, Arc<Notify>, SourceUpdate) {
    let fake = Fake::start(assigned, unassigned).await;
    let env = Env::new(Some(token));
    let (mut rx, refresh) = start(env.config(&base_of(&fake)));
    let first = wait_state(&mut rx, SourceState::Fresh).await;
    (fake, env, rx, refresh, first)
}
