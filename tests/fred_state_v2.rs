//! Fred's mail + calendar sources: explicit source states, a truthful unread
//! count, and no failure that can masquerade as "0 unread" / "nothing today".
//!
//! Every test runs its own wiremock "Microsoft" (Graph + login endpoints) and
//! its own temp dir, and drives the real native sources through
//! `spawn_with(GraphClient, Config, FredTiming)` exactly as the daemon does
//! (ONE shared `GraphClient` clone handed to both sources). Nothing here
//! touches the user's real config, token cache, daemon or app.
//!
//! Determinism: no fixed sleeps and no wall-clock assertions. Tests wait on
//! `watch::Receiver::changed()` / the mock's request log with a generous
//! bound, and only ever assert on what was eventually observed.
//!
//! Contract coverage (see the spec for the numbering):
//!  1-6  mailbox: unread count, ordering, refresh, ttl, empty, failures
//!  7    device-flow sign-in shared by both sources, then recovery
//!  8,10 calendar: window, fields, cancellation, failures
//!  9    `today_window` (fixed offsets and a DST zone)
//!  11   MCP tools / IPC broadcast report exactly what the snapshots say
//!  12   GET-only against Graph

use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::Arc;
use std::time::Duration;

use chrono::{
    DateTime, Duration as ChronoDuration, FixedOffset, LocalResult, NaiveDate, NaiveDateTime,
    Offset, TimeZone, Timelike, Utc,
};
use nostromo::config::Config;
use nostromo::data::fred_calendar::{CalendarEvent, CalendarSnapshot};
use nostromo::data::fred_calendar_native::{today_window, FredCalendarNativeSource};
use nostromo::data::fred_mailbox::{MailboxItem, MailboxSnapshot};
use nostromo::data::fred_mailbox_native::{FredMailboxNativeSource, FredTiming};
use nostromo::data::graph_client::{DeviceFlowPrompt, GraphClient, GraphOptions};
use nostromo::data::work::model::SourceState;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mcp::state::McpSharedState;
use nostromo::mcp::tools::fred as fred_tools;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::watch;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

/// Upper bound for anything we wait on. Generous: the happy path takes
/// milliseconds; this only matters when something is broken.
const WAIT: Duration = Duration::from_secs(20);

const DELTA: &str = "/me/mailFolders/inbox/messages/delta";
const FOLDER: &str = "/me/mailFolders/inbox";
const CALENDAR_VIEW: &str = "/me/calendarView";
const DEVICECODE: &str = "/common/oauth2/v2.0/devicecode";
const TOKEN: &str = "/common/oauth2/v2.0/token";

/// Secrets the mock hands out. None may ever reach a snapshot or tool output.
const ACCESS_TOKEN: &str = "fake-at";
const REFRESH_TOKEN: &str = "fake-rt";
const DEVICE_CODE_SECRET: &str = "dev-code-secret-xyz";

// ═════════════════════════════════════════════════════════════════════════════
// Harness
// ═════════════════════════════════════════════════════════════════════════════

struct Env {
    server: MockServer,
    dir: TempDir,
    graph: GraphClient,
    config: Config,
}

impl Env {
    fn base(&self) -> String {
        self.server.uri()
    }
}

/// A mock Microsoft plus a `GraphClient` pointed at it. `signed_in` pre-seeds
/// a valid cached token (so no device flow is needed); otherwise the client
/// starts with no token at all. The m365 CLI is always disabled.
async fn env(signed_in: bool, vip_senders: &[&str]) -> Env {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let token_cache = dir.path().join("graph-token.json");
    let fred_dir = dir.path().join("fred");
    std::fs::create_dir_all(&fred_dir).unwrap();

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

    let config = Config {
        graph_client_id: Some("test-client".into()),
        graph_token_cache: Some(token_cache.clone()),
        fred_state: Some(fred_dir),
        vip_senders: vip_senders.iter().map(|s| s.to_string()).collect(),
        ..Default::default()
    };
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

    Env {
        server,
        dir,
        graph,
        config,
    }
}

/// An offset at which it is currently 12:00 local time. Pinning "today" to a
/// zone where it is noon keeps every "today" assertion immune to midnight
/// rolling over mid-test, and (not being a whole hour or UTC) proves the
/// source honours `day_offset` rather than guessing a zone.
fn noon_offset() -> FixedOffset {
    let secs_into_utc_day = Utc::now().num_seconds_from_midnight() as i32;
    FixedOffset::east_opt(12 * 3600 - secs_into_utc_day).unwrap()
}

fn timing_at(poll: Duration, unread_count_ttl: Duration, offset: FixedOffset) -> FredTiming {
    FredTiming {
        mailbox_poll: poll,
        calendar_poll: poll,
        unread_count_ttl,
        day_offset: Some(offset),
    }
}

fn timing(poll: Duration, unread_count_ttl: Duration) -> FredTiming {
    timing_at(poll, unread_count_ttl, noon_offset())
}

fn fast() -> Duration {
    Duration::from_millis(100)
}

fn an_hour() -> Duration {
    Duration::from_secs(3600)
}

fn spawn_mailbox(e: &Env, t: FredTiming) -> watch::Receiver<Option<MailboxSnapshot>> {
    FredMailboxNativeSource::spawn_with(e.graph.clone(), e.config.clone(), t)
}

fn spawn_calendar(e: &Env, t: FredTiming) -> watch::Receiver<Option<CalendarSnapshot>> {
    FredCalendarNativeSource::spawn_with(e.graph.clone(), e.config.clone(), t)
}

// ── snapshot access shared by the two snapshot types ─────────────────────────

trait Snap: Clone + std::fmt::Debug + serde::Serialize {
    fn state(&self) -> SourceState;
    fn error(&self) -> Option<&str>;
    fn is_stale(&self) -> bool;
    fn has_auth_prompt(&self) -> bool;
}

impl Snap for MailboxSnapshot {
    fn state(&self) -> SourceState {
        self.state
    }
    fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    fn is_stale(&self) -> bool {
        self.stale
    }
    fn has_auth_prompt(&self) -> bool {
        self.auth_prompt.is_some()
    }
}

impl Snap for CalendarSnapshot {
    fn state(&self) -> SourceState {
        self.state
    }
    fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    fn is_stale(&self) -> bool {
        self.stale
    }
    fn has_auth_prompt(&self) -> bool {
        self.auth_prompt.is_some()
    }
}

fn assert_no_secrets(what: &str, text: &str) {
    for needle in [
        "access_token",
        "refresh_token",
        ACCESS_TOKEN,
        REFRESH_TOKEN,
        DEVICE_CODE_SECRET,
    ] {
        assert!(
            !text.contains(needle),
            "{what} leaks {needle:?}: {text}"
        );
    }
}

/// Invariants that must hold for EVERY snapshot ever published, whatever the
/// scenario: a snapshot never claims health while reporting a failure, each
/// state carries the evidence for it, and no secret is ever serialized.
fn assert_snapshot_is_honest<S: Snap>(s: &S) {
    match s.state() {
        SourceState::Fresh | SourceState::Empty => assert!(
            s.error().is_none() && !s.is_stale() && !s.has_auth_prompt(),
            "snapshot claims {:?} while reporting a failure / stale data / sign-in: {s:?}",
            s.state()
        ),
        SourceState::Stale => assert!(
            s.is_stale() && s.error().is_some(),
            "a Stale snapshot must set `stale` and carry a reason: {s:?}"
        ),
        SourceState::Error => assert!(
            s.error().is_some(),
            "an Error snapshot must carry a reason: {s:?}"
        ),
        SourceState::Unauthenticated => assert!(
            s.has_auth_prompt() && s.error().is_some(),
            "an Unauthenticated snapshot must carry the prompt and a reason: {s:?}"
        ),
        _ => {}
    }
    assert_no_secrets("snapshot", &serde_json::to_string(s).unwrap());
}

/// Wait (bounded) for a published snapshot satisfying `pred`. Every snapshot
/// observed on the way is checked for honesty and against `forbid` (states
/// this scenario must never publish).
async fn wait_for<S: Snap>(
    rx: &mut watch::Receiver<Option<S>>,
    what: &str,
    forbid: &[SourceState],
    pred: impl Fn(&S) -> bool,
) -> S {
    let waited = tokio::time::timeout(WAIT, async {
        loop {
            let hit = {
                let guard = rx.borrow_and_update();
                match guard.as_ref() {
                    Some(s) => {
                        assert_snapshot_is_honest(s);
                        assert!(
                            !forbid.contains(&s.state()),
                            "published a forbidden {:?} snapshot while waiting for {what}: {s:?}",
                            s.state()
                        );
                        pred(s).then(|| s.clone())
                    }
                    None => None,
                }
            };
            if let Some(s) = hit {
                return s;
            }
            if rx.changed().await.is_err() {
                panic!("source stopped publishing while waiting for {what}");
            }
        }
    })
    .await;
    match waited {
        Ok(s) => s,
        Err(_) => panic!(
            "timed out waiting for {what}; last snapshot: {:?}",
            rx.borrow().clone()
        ),
    }
}

// ── request log helpers ──────────────────────────────────────────────────────

async fn reqs(server: &MockServer) -> Vec<Request> {
    server
        .received_requests()
        .await
        .expect("request recording is enabled")
}

fn is_oauth(r: &Request) -> bool {
    r.url.path().contains("/oauth2/v2.0/")
}

fn count(rs: &[Request], http_method: &str, p: &str) -> usize {
    rs.iter()
        .filter(|r| r.method.as_str() == http_method && r.url.path() == p)
        .count()
}

async fn wait_until_requests(server: &MockServer, what: &str, ok: impl Fn(&[Request]) -> bool) {
    let waited = tokio::time::timeout(WAIT, async {
        loop {
            if ok(&reqs(server).await) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await;
    if waited.is_err() {
        let seen: Vec<String> = reqs(server)
            .await
            .iter()
            .map(|r| format!("{} {}", r.method, r.url.path()))
            .collect();
        panic!("timed out waiting for {what}; requests seen: {seen:?}");
    }
}

/// Wait for the mock to have served at least `n` requests on `p` (GET).
async fn wait_for_gets(server: &MockServer, p: &str, n: usize) {
    wait_until_requests(server, &format!("{n} GETs of {p}"), |rs| {
        count(rs, "GET", p) >= n
    })
    .await;
}

// ── mock builders ────────────────────────────────────────────────────────────

fn mail(id: &str, subject: &str, is_read: bool, received: &str, name: &str, addr: &str) -> Value {
    json!({
        "id": id,
        "subject": subject,
        "isRead": is_read,
        "receivedDateTime": received,
        "webLink": format!("https://outlook.office.com/mail/{id}"),
        "from": { "emailAddress": { "name": name, "address": addr } },
    })
}

/// Four messages: two unread (m1 newest-unread, m3 older-unread), two read
/// (m2 newest overall, m4 oldest). Expected order: m1, m3, m2, m4.
fn standard_window() -> Vec<Value> {
    vec![
        mail("m2", "FYI notes", true, "2026-10-12T15:00:00Z", "Bob Jones", "bob@x.com"),
        mail("m3", "Older unread", false, "2026-10-12T13:00:00Z", "Carol Diaz", "carol@x.com"),
        mail("m1", "Quarterly numbers", false, "2026-10-12T14:00:00Z", "Alice Smith", "alice@x.com"),
        mail("m4", "Old read", true, "2026-10-12T09:00:00Z", "Dan Lee", "dan@x.com"),
    ]
}

fn delta_page(base: &str, values: Vec<Value>, token: &str) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({
        "value": values,
        "@odata.deltaLink": format!("{base}{DELTA}?$deltatoken={token}"),
    }))
}

fn folder_count(n: u64) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({ "unreadItemCount": n }))
}

fn server_error() -> ResponseTemplate {
    ResponseTemplate::new(500).set_body_string("internal server error")
}

/// Responder: the first request gets `window`; every later one gets an empty
/// delta (nothing changed).
fn window_then_quiet(
    base: String,
    window: Vec<Value>,
) -> impl Fn(&Request) -> ResponseTemplate + Send + Sync + 'static {
    let served = AtomicBool::new(false);
    move |_: &Request| {
        if served.swap(true, SeqCst) {
            delta_page(&base, vec![], "d2")
        } else {
            delta_page(&base, window.clone(), "d1")
        }
    }
}

async fn mount_get<R: Respond + 'static>(server: &MockServer, p: &str, responder: R) {
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(responder)
        .mount(server)
        .await;
}

/// Delta serves `window` once then goes quiet; the folder reports `unread`.
async fn mount_mail(e: &Env, window: Vec<Value>, unread: u64) {
    mount_get(&e.server, DELTA, window_then_quiet(e.base(), window)).await;
    mount_get(&e.server, FOLDER, move |_: &Request| folder_count(unread)).await;
}

/// Device-code + token endpoints. The token endpoint answers
/// `authorization_pending` until `approve` is set, then issues tokens.
async fn mount_oauth(server: &MockServer, approve: Arc<AtomicBool>) {
    Mock::given(method("POST"))
        .and(path(DEVICECODE))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "device_code": DEVICE_CODE_SECRET,
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://microsoft.com/devicelogin",
            "expires_in": 900,
            "interval": 0,
        })))
        .mount(server)
        .await;
    Mock::given(method("POST"))
        .and(path(TOKEN))
        .respond_with(move |_: &Request| {
            if approve.load(SeqCst) {
                ResponseTemplate::new(200).set_body_json(json!({
                    "access_token": ACCESS_TOKEN,
                    "refresh_token": REFRESH_TOKEN,
                    "expires_in": 3600,
                }))
            } else {
                ResponseTemplate::new(200)
                    .set_body_json(json!({ "error": "authorization_pending" }))
            }
        })
        .mount(server)
        .await;
}

fn graph_dt(t: DateTime<Utc>) -> Value {
    json!({
        "dateTime": t.format("%Y-%m-%dT%H:%M:%S.0000000").to_string(),
        "timeZone": "UTC",
    })
}

/// A plain accepted, not-cancelled, timed event.
fn event(id: &str, subject: &str, start: DateTime<Utc>, end: DateTime<Utc>) -> Value {
    json!({
        "id": id,
        "subject": subject,
        "start": graph_dt(start),
        "end": graph_dt(end),
        "responseStatus": { "response": "accepted" },
        "isCancelled": false,
        "isAllDay": false,
    })
}

fn whole_seconds_now() -> DateTime<Utc> {
    DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap()
}

/// One uncomplicated event an hour from now (inside "today" for the noon offset).
fn one_event_today() -> Vec<Value> {
    let now = whole_seconds_now();
    vec![event(
        "e1",
        "Eng sync",
        now + ChronoDuration::minutes(60),
        now + ChronoDuration::minutes(120),
    )]
}

async fn mount_calendar(server: &MockServer, events: Vec<Value>) {
    mount_get(server, CALENDAR_VIEW, move |_: &Request| {
        ResponseTemplate::new(200).set_body_json(json!({ "value": events }))
    })
    .await;
}

fn ids_of(s: &MailboxSnapshot) -> Vec<&str> {
    s.items.iter().map(|i| i.id.as_str()).collect()
}

fn titles_of(s: &CalendarSnapshot) -> Vec<&str> {
    s.events.iter().map(|e| e.title.as_str()).collect()
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. Mailbox: the unread count is the folder's, the window is the window
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_unread_count_is_the_inbox_total_not_the_unread_items_in_the_fetched_window() {
    let e = env(true, &["alice@x.com"]).await;
    mount_mail(&e, standard_window(), 42).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;

    assert_eq!(snap.unread_count, 42, "count comes from unreadItemCount: {snap:?}");
    assert_eq!(snap.items.len(), 4, "the window itself still lists its messages");
    assert!(snap.updated_at.is_some(), "a successful fetch stamps updated_at");
    assert!(!snap.stale && snap.error.is_none() && snap.auth_prompt.is_none(), "{snap:?}");
}

#[tokio::test]
async fn mailbox_lists_unread_first_then_newest_first_with_ids_links_and_vip_flag() {
    let e = env(true, &["alice@x.com"]).await;
    mount_mail(&e, standard_window(), 2).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;

    assert_eq!(ids_of(&snap), ["m1", "m3", "m2", "m4"], "unread first, newest first: {snap:?}");
    assert!(!snap.items[0].is_read && !snap.items[1].is_read);
    assert!(snap.items[2].is_read && snap.items[3].is_read);

    let first = &snap.items[0];
    assert_eq!(first.subject, "Quarterly numbers");
    assert!(first.from.contains("Alice Smith"), "from: {}", first.from);
    assert_eq!(first.web_link.as_deref(), Some("https://outlook.office.com/mail/m1"));
    assert_eq!(first.received_at, Some("2026-10-12T14:00:00Z".parse().unwrap()));
    assert!(first.vip, "alice@x.com is on the VIP list");
    assert!(
        snap.items[1..].iter().all(|i| !i.vip),
        "only listed senders are VIPs: {snap:?}"
    );
}

#[tokio::test]
async fn mailbox_asks_graph_for_the_fields_the_snapshot_needs() {
    let e = env(true, &[]).await;
    mount_mail(&e, standard_window(), 2).await;
    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    wait_for(&mut rx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;

    let rs = reqs(&e.server).await;
    let first_delta = rs
        .iter()
        .find(|r| r.url.path() == DELTA)
        .expect("a delta request was made");
    let select = first_delta
        .url
        .query_pairs()
        .find(|(k, _)| k == "$select")
        .map(|(_, v)| v.into_owned())
        .expect("delta request has a $select");
    for field in ["id", "webLink", "from", "subject", "receivedDateTime", "isRead"] {
        assert!(
            select.split(',').any(|f| f == field),
            "$select {select:?} lacks {field}"
        );
    }
    let bearer = first_delta.headers.get("authorization").and_then(|v| v.to_str().ok());
    assert_eq!(bearer, Some(format!("Bearer {ACCESS_TOKEN}").as_str()));
}

#[tokio::test]
async fn mailbox_with_unread_mail_outside_the_window_is_fresh_not_empty() {
    // The window has nothing new, but the inbox still holds 3 unread messages.
    let e = env(true, &[]).await;
    mount_mail(&e, vec![], 3).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "a fresh mailbox", &[SourceState::Empty], |s| {
        s.state == SourceState::Fresh
    })
    .await;
    assert_eq!(snap.unread_count, 3, "{snap:?}");
}

#[tokio::test]
async fn mailbox_follows_pagination_and_then_continues_from_the_delta_link() {
    let e = env(true, &[]).await;
    let base = e.base();
    let w = standard_window();
    let (page1, page2) = (w[..2].to_vec(), w[2..].to_vec());
    mount_get(&e.server, DELTA, move |req: &Request| {
        let q = req.url.query().unwrap_or("");
        if q.contains("skiptoken") {
            delta_page(&base, page2.clone(), "d1")
        } else if q.contains("deltatoken") {
            delta_page(&base, vec![], "d1")
        } else {
            ResponseTemplate::new(200).set_body_json(json!({
                "value": page1,
                "@odata.nextLink": format!("{base}{DELTA}?$skiptoken=p2"),
            }))
        }
    })
    .await;
    mount_get(&e.server, FOLDER, |_: &Request| folder_count(2)).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "all pages merged", &[], |s| s.items.len() == 4).await;
    assert_eq!(snap.state, SourceState::Fresh, "{snap:?}");

    // Later polls are incremental: they use the persisted delta link and do
    // not start another full sync.
    wait_for_gets(&e.server, DELTA, 4).await;
    let rs = reqs(&e.server).await;
    let delta_reqs: Vec<&Request> = rs.iter().filter(|r| r.url.path() == DELTA).collect();
    let full_syncs = delta_reqs
        .iter()
        .filter(|r| {
            let q = r.url.query().unwrap_or("");
            !q.contains("skiptoken") && !q.contains("deltatoken")
        })
        .count();
    assert_eq!(full_syncs, 1, "only one initial sync; the rest follow the delta link");
    assert!(
        delta_reqs
            .iter()
            .any(|r| r.url.query().unwrap_or("").contains("deltatoken=d1")),
        "later polls use the delta link Graph returned"
    );

    // The link is persisted next to the token cache.
    let persisted = std::fs::read_to_string(e.dir.path().join("mailbox.delta"))
        .expect("delta link persisted as mailbox.delta next to the token cache");
    assert!(persisted.contains("deltatoken=d1"), "{persisted}");
}

// ═════════════════════════════════════════════════════════════════════════════
// 2 + 3. Unread count refresh: on read-state changes, and otherwise per ttl
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_unread_count_is_refreshed_right_after_a_read_state_change_despite_a_long_ttl() {
    let e = env(true, &[]).await;
    let base = e.base();

    let first_served = Arc::new(AtomicBool::new(false));
    let flip_requested = Arc::new(AtomicBool::new(false)); // set by the test
    let flip_served = Arc::new(AtomicBool::new(false));

    {
        let (first_served, flip_requested, flip_served) =
            (first_served.clone(), flip_requested.clone(), flip_served.clone());
        mount_get(&e.server, DELTA, move |_: &Request| {
            if !first_served.swap(true, SeqCst) {
                let window = vec![
                    mail("m1", "Quarterly numbers", false, "2026-10-12T14:00:00Z", "Alice Smith", "alice@x.com"),
                    mail("m2", "FYI notes", true, "2026-10-12T15:00:00Z", "Bob Jones", "bob@x.com"),
                ];
                delta_page(&base, window, "d1")
            } else if flip_requested.load(SeqCst) && !flip_served.swap(true, SeqCst) {
                // The user read m1 elsewhere: Graph reports the changed message.
                let changed = vec![mail(
                    "m1", "Quarterly numbers", true, "2026-10-12T14:00:00Z", "Alice Smith", "alice@x.com",
                )];
                delta_page(&base, changed, "d2")
            } else {
                delta_page(&base, vec![], "d3")
            }
        })
        .await;
    }
    // The folder says 5 until the read-state change has been served, 4 after.
    mount_get(&e.server, FOLDER, move |_: &Request| {
        folder_count(if flip_served.load(SeqCst) { 4 } else { 5 })
    })
    .await;

    // The ttl is an hour: only the read-state change can explain a refresh.
    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    wait_for(&mut rx, "the initial count of 5", &[], |s| {
        s.state == SourceState::Fresh && s.unread_count == 5
    })
    .await;

    flip_requested.store(true, SeqCst);
    let snap = wait_for(&mut rx, "the refreshed count of 4", &[], |s| s.unread_count == 4).await;

    assert_eq!(snap.state, SourceState::Fresh, "{snap:?}");
    let m1 = snap.items.iter().find(|i| i.id == "m1").expect("m1 still listed");
    assert!(m1.is_read, "the changed message is shown as read: {snap:?}");
}

#[tokio::test]
async fn mailbox_does_not_refetch_the_unread_count_within_its_ttl_when_nothing_changed() {
    let e = env(true, &[]).await;
    mount_mail(&e, standard_window(), 7).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    wait_for(&mut rx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;

    // Let several poll cycles with an unchanged delta go by.
    wait_for_gets(&e.server, DELTA, 6).await;

    let folder_hits = count(&reqs(&e.server).await, "GET", FOLDER);
    assert_eq!(folder_hits, 1, "unread count fetched once, then served from the ttl");
}

// ═════════════════════════════════════════════════════════════════════════════
// 4. Empty inbox
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_with_an_empty_inbox_is_empty_not_fresh() {
    let e = env(true, &[]).await;
    mount_mail(&e, vec![], 0).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "an empty mailbox", &[SourceState::Fresh], |s| {
        s.state == SourceState::Empty
    })
    .await;

    assert_eq!(snap.unread_count, 0);
    assert!(snap.items.is_empty());
    assert!(snap.updated_at.is_some(), "an empty inbox is still a successful fetch");
    assert!(!snap.stale && snap.error.is_none(), "{snap:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// 5. Failures after / without a good snapshot
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_failure_after_a_good_snapshot_is_stale_with_the_old_data_and_recovers() {
    let e = env(true, &[]).await;
    let base = e.base();
    let failing = Arc::new(AtomicBool::new(false));
    {
        let failing = failing.clone();
        let served = AtomicBool::new(false);
        mount_get(&e.server, DELTA, move |_: &Request| {
            if failing.load(SeqCst) {
                server_error()
            } else if served.swap(true, SeqCst) {
                delta_page(&base, vec![], "d2")
            } else {
                delta_page(&base, standard_window(), "d1")
            }
        })
        .await;
    }
    mount_get(&e.server, FOLDER, |_: &Request| folder_count(42)).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let good = wait_for(&mut rx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;
    let good_at = good.updated_at.expect("fresh snapshot has updated_at");

    failing.store(true, SeqCst);
    let stale = wait_for(&mut rx, "a stale mailbox", &[], |s| s.state == SourceState::Stale).await;

    assert!(stale.stale, "{stale:?}");
    assert!(
        stale.error.as_deref().is_some_and(|r| !r.trim().is_empty()),
        "stale carries a short reason: {stale:?}"
    );
    assert_eq!(ids_of(&stale), ids_of(&good), "previous items are retained");
    assert_eq!(stale.unread_count, 42, "previous unread count is retained");
    let stale_at = stale.updated_at.expect("updated_at is the last SUCCESS");
    assert!(stale_at >= good_at, "{stale_at} vs {good_at}");

    // More failed cycles do not advance updated_at: only successes do.
    let delta_gets_so_far = count(&reqs(&e.server).await, "GET", DELTA);
    wait_for_gets(&e.server, DELTA, delta_gets_so_far + 3).await;
    let later = rx.borrow().clone().expect("still published");
    assert_eq!(later.state, SourceState::Stale);
    assert_eq!(later.updated_at, Some(stale_at), "failures must not look like fresh fetches");

    // Graph recovers: the source returns to Fresh by itself.
    failing.store(false, SeqCst);
    let back = wait_for(&mut rx, "recovery", &[], |s| s.state == SourceState::Fresh).await;
    assert!(back.error.is_none() && !back.stale, "{back:?}");
    assert_eq!(back.unread_count, 42);
    assert_eq!(ids_of(&back), ids_of(&good), "the in-memory window survives the outage");
    assert!(back.updated_at.unwrap() > stale_at, "recovery is a new successful fetch");
}

#[tokio::test]
async fn mailbox_failure_with_no_previous_data_is_an_error_never_fresh_or_empty() {
    let e = env(true, &[]).await;
    mount_get(&e.server, DELTA, |_: &Request| server_error()).await;
    mount_get(&e.server, FOLDER, |_: &Request| folder_count(0)).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let forbid = [SourceState::Fresh, SourceState::Empty];
    let snap = wait_for(&mut rx, "an error mailbox", &forbid, |s| {
        s.state == SourceState::Error
    })
    .await;
    assert!(snap.items.is_empty(), "{snap:?}");
    assert!(snap.error.as_deref().is_some_and(|r| !r.trim().is_empty()), "{snap:?}");
    assert!(snap.updated_at.is_none(), "nothing has ever succeeded: {snap:?}");

    // It keeps failing honestly over several more cycles.
    wait_for_gets(&e.server, DELTA, 4).await;
    let later = rx.borrow().clone().expect("published");
    assert_eq!(later.state, SourceState::Error, "{later:?}");
    assert!(later.items.is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// 6. Unread-count (folder) failure
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_when_only_the_unread_count_fetch_fails_it_is_an_error_not_a_confident_zero() {
    let e = env(true, &[]).await;
    mount_get(&e.server, DELTA, window_then_quiet(e.base(), standard_window())).await;
    mount_get(&e.server, FOLDER, |_: &Request| server_error()).await;

    let mut rx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let forbid = [SourceState::Fresh, SourceState::Empty];
    let snap = wait_for(&mut rx, "an error mailbox", &forbid, |s| {
        s.state == SourceState::Error
    })
    .await;
    assert!(snap.error.as_deref().is_some_and(|r| !r.trim().is_empty()), "{snap:?}");

    // Still never healthy after more cycles (the count is retried).
    wait_for_gets(&e.server, FOLDER, 3).await;
    let later = rx.borrow().clone().expect("published");
    assert!(
        !matches!(later.state, SourceState::Fresh | SourceState::Empty),
        "a missing unread count must not be presented as healthy: {later:?}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// 7. Device-flow sign-in, shared by both sources
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn without_a_token_both_sources_show_one_shared_sign_in_prompt_then_recover_without_restart() {
    let e = env(false, &["alice@x.com"]).await;
    let approve = Arc::new(AtomicBool::new(false));
    mount_oauth(&e.server, approve.clone()).await;
    mount_mail(&e, standard_window(), 9).await;
    mount_calendar(&e.server, one_event_today()).await;

    let started = Utc::now();
    let mut mrx = spawn_mailbox(&e, timing(fast(), an_hour()));
    let mut crx = spawn_calendar(&e, timing(fast(), an_hour()));

    // Both sources report the same unauthenticated state with the prompt.
    let forbid = [SourceState::Fresh, SourceState::Empty];
    let m = wait_for(&mut mrx, "unauthenticated mailbox", &forbid, |s| {
        s.state == SourceState::Unauthenticated
    })
    .await;
    let c = wait_for(&mut crx, "unauthenticated calendar", &forbid, |s| {
        s.state == SourceState::Unauthenticated
    })
    .await;

    let prompts = [
        m.auth_prompt.clone().expect("mailbox prompt"),
        c.auth_prompt.clone().expect("calendar prompt"),
    ];
    for p in &prompts {
        assert_eq!(p.verification_uri, "https://microsoft.com/devicelogin");
        assert_eq!(p.user_code, "ABCD-EFGH");
        let lifetime_from = started + ChronoDuration::seconds(899);
        let lifetime_to = Utc::now() + ChronoDuration::seconds(901);
        assert!(
            p.expires_at >= lifetime_from && p.expires_at <= lifetime_to,
            "expires_at {} should be ~900s after the device-code response",
            p.expires_at
        );
    }
    assert!(m.items.is_empty() && m.unread_count == 0, "no data while signed out: {m:?}");
    assert!(c.events.is_empty() && c.next.is_none(), "no data while signed out: {c:?}");
    assert!(m.error.as_deref().is_some_and(|r| !r.trim().is_empty()));
    assert!(c.error.as_deref().is_some_and(|r| !r.trim().is_empty()));
    assert!(m.updated_at.is_none() && c.updated_at.is_none());

    // The client also exposes the pending prompt.
    let pending = e.graph.pending_prompt().await.expect("a device flow is in flight");
    assert_eq!(pending.user_code, "ABCD-EFGH");

    // Let several poll cycles pass while the user has not approved.
    wait_until_requests(&e.server, "5 device-flow token polls", |rs| {
        count(rs, "POST", TOKEN) >= 5
    })
    .await;
    assert_eq!(
        mrx.borrow().as_ref().map(|s| s.state),
        Some(SourceState::Unauthenticated),
        "still waiting for sign-in"
    );
    assert_eq!(
        crx.borrow().as_ref().map(|s| s.state),
        Some(SourceState::Unauthenticated)
    );

    let rs = reqs(&e.server).await;
    assert_eq!(
        count(&rs, "POST", DEVICECODE),
        1,
        "the shared client starts exactly one device flow, however many sources/cycles"
    );
    let graph_calls: Vec<String> = rs
        .iter()
        .filter(|r| !is_oauth(r))
        .map(|r| format!("{} {}", r.method, r.url.path()))
        .collect();
    assert!(
        graph_calls.is_empty(),
        "no Graph data request may be made before sign-in: {graph_calls:?}"
    );

    // The user approves; both sources recover on their own.
    approve.store(true, SeqCst);
    let m = wait_for(&mut mrx, "a fresh mailbox after sign-in", &[], |s| {
        s.state == SourceState::Fresh
    })
    .await;
    let c = wait_for(&mut crx, "a fresh calendar after sign-in", &[], |s| {
        s.state == SourceState::Fresh
    })
    .await;
    assert!(m.auth_prompt.is_none() && c.auth_prompt.is_none());
    assert_eq!(m.unread_count, 9);
    assert_eq!(m.items.len(), 4);
    assert_eq!(titles_of(&c), ["Eng sync"]);
    assert!(m.error.is_none() && c.error.is_none());

    // Data requests carry the token, and no more device flows were started.
    let rs = reqs(&e.server).await;
    assert_eq!(count(&rs, "POST", DEVICECODE), 1);
    let data_reqs: Vec<&Request> = rs.iter().filter(|r| !is_oauth(r)).collect();
    assert!(!data_reqs.is_empty());
    for r in data_reqs {
        let auth = r.headers.get("authorization").and_then(|v| v.to_str().ok());
        assert_eq!(auth, Some(format!("Bearer {ACCESS_TOKEN}").as_str()), "{}", r.url);
    }

    // No tool output carries any token material either.
    let state = mcp_state(mrx.clone(), crx.clone());
    let (st, unread, cal) = tool_outputs(&state);
    for (name, out) in [("get_state", st), ("list_unread_emails", unread), ("list_calendar_events", cal)] {
        assert_no_secrets(name, &out.to_string());
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// 8. Calendar
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn calendar_requests_exactly_todays_local_window_and_the_fields_it_needs() {
    let e = env(true, &[]).await;
    mount_calendar(&e.server, one_event_today()).await;

    let offset = noon_offset();
    let mut rx = spawn_calendar(&e, timing_at(fast(), an_hour(), offset));
    wait_for(&mut rx, "a fresh calendar", &[], |s| s.state == SourceState::Fresh).await;

    let (start, end) = today_window(Utc::now(), &offset);
    let rs = reqs(&e.server).await;
    let req = rs
        .iter()
        .find(|r| r.url.path() == CALENDAR_VIEW)
        .expect("a calendarView request was made");
    let param = |name: &str| {
        req.url
            .query_pairs()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.into_owned())
            .unwrap_or_else(|| panic!("calendarView request lacks {name}: {}", req.url))
    };
    let fmt = "%Y-%m-%dT%H:%M:%SZ";
    assert_eq!(param("startDateTime"), start.format(fmt).to_string());
    assert_eq!(param("endDateTime"), end.format(fmt).to_string());
    let select = param("$select");
    for field in [
        "id", "subject", "start", "end", "responseStatus", "isCancelled", "webLink", "location",
        "onlineMeeting", "organizer", "isAllDay",
    ] {
        assert!(select.split(',').any(|f| f == field), "$select {select:?} lacks {field}");
    }
}

#[tokio::test]
async fn calendar_sorts_by_start_keeps_new_fields_drops_outside_events_and_never_picks_cancelled_as_next() {
    let e = env(true, &[]).await;
    let now = whole_seconds_now();
    let mins = |n: i64| now + ChronoDuration::minutes(n);
    let offset = noon_offset();
    let (win_start, win_end) = today_window(now, &offset);

    // Deliberately not in start order.
    let mut eng_sync = event("e-eng", "Eng sync", mins(90), mins(150));
    eng_sync["webLink"] = json!("https://outlook.office.com/calendar/item/e-eng");
    eng_sync["location"] = json!({ "displayName": "Room 4" });
    eng_sync["onlineMeeting"] = json!({ "joinUrl": "https://teams.microsoft.com/l/meetup-join/abc" });
    eng_sync["organizer"] = json!({ "emailAddress": { "name": "Pat", "address": "pat@x.com" } });

    let mut flagged = event("e-flagged", "Planning", mins(30), mins(60));
    flagged["isCancelled"] = json!(true);

    // Graph sometimes only prefixes the subject.
    let prefixed = event("e-prefixed", "Canceled: Prefix only", mins(45), mins(75));

    let mut declined = event("e-declined", "Declined thing", mins(60), mins(90));
    declined["responseStatus"] = json!({ "response": "declined" });

    let mut earlier = event("e-earlier", "Earlier today", mins(-120), mins(-60));
    earlier["responseStatus"] = json!({ "response": "tentativelyAccepted" });
    earlier["isAllDay"] = json!(true);

    // Overlaps midnight: starts yesterday, ends today -> still part of today.
    let overnight = event(
        "e-overnight",
        "Overnight",
        win_start - ChronoDuration::hours(2),
        win_start + ChronoDuration::hours(1),
    );
    // Entirely outside the window: yesterday, and tomorrow (start == window end).
    let yesterday = event(
        "e-yesterday",
        "Yesterday",
        win_start - ChronoDuration::hours(5),
        win_start - ChronoDuration::hours(4),
    );
    let tomorrow = event(
        "e-tomorrow",
        "Tomorrow",
        win_end,
        win_end + ChronoDuration::hours(1),
    );

    mount_calendar(
        &e.server,
        vec![eng_sync, tomorrow, flagged, declined, yesterday, earlier, prefixed, overnight],
    )
    .await;

    let mut rx = spawn_calendar(&e, timing_at(fast(), an_hour(), offset));
    let snap = wait_for(&mut rx, "a fresh calendar", &[], |s| s.state == SourceState::Fresh).await;

    assert_eq!(
        titles_of(&snap),
        ["Overnight", "Earlier today", "Planning", "Prefix only", "Declined thing", "Eng sync"],
        "sorted by start, outside-the-window events dropped, 'Canceled: ' stripped: {snap:?}"
    );
    assert!(snap.updated_at.is_some());

    fn by_id<'a>(snap: &'a CalendarSnapshot, id: &str) -> &'a CalendarEvent {
        snap.events
            .iter()
            .find(|ev| ev.id == id)
            .unwrap_or_else(|| panic!("no event {id}"))
    }

    // Cancellation, by flag and by subject prefix alone.
    for id in ["e-flagged", "e-prefixed"] {
        let ev = by_id(&snap, id);
        assert_eq!(ev.status, "cancelled", "{id}: {ev:?}");
        assert!(ev.is_cancelled, "{id}: {ev:?}");
    }
    assert!(!by_id(&snap, "e-eng").is_cancelled);
    assert_eq!(by_id(&snap, "e-declined").status, "declined");

    // Earlier items are not "next"; cancelled / declined never are. The first
    // upcoming live event is the 90-minute-away Eng sync.
    let next = snap.next.as_ref().expect("there is an upcoming event");
    assert_eq!(next.title, "Eng sync", "{snap:?}");
    assert!((88..=90).contains(&next.in_minutes), "in_minutes {}", next.in_minutes);
    assert_eq!(snap.sweater, "sage");

    // New fields.
    let eng = by_id(&snap, "e-eng");
    assert_eq!(eng.web_link.as_deref(), Some("https://outlook.office.com/calendar/item/e-eng"));
    assert_eq!(eng.location.as_deref(), Some("Room 4"));
    assert_eq!(
        eng.online_meeting_url.as_deref(),
        Some("https://teams.microsoft.com/l/meetup-join/abc")
    );
    assert_eq!(eng.organizer.as_deref(), Some("Pat"));
    assert_eq!(eng.response_status, "accepted");
    assert_eq!(eng.status, "accepted");
    assert!(!eng.is_all_day);
    assert_eq!(eng.start, Some(mins(90)));
    assert_eq!(eng.end, Some(mins(150)));

    let early = by_id(&snap, "e-earlier");
    assert!(early.is_all_day, "isAllDay is carried through");
    assert_eq!(early.response_status, "tentativelyAccepted");
    assert!(!early.is_now);
}

#[tokio::test]
async fn calendar_with_no_events_today_is_empty_not_fresh() {
    let e = env(true, &[]).await;
    mount_calendar(&e.server, vec![]).await;

    let mut rx = spawn_calendar(&e, timing(fast(), an_hour()));
    let snap = wait_for(&mut rx, "an empty calendar", &[SourceState::Fresh], |s| {
        s.state == SourceState::Empty
    })
    .await;
    assert!(snap.events.is_empty() && snap.next.is_none());
    assert!(snap.updated_at.is_some());
}

// ═════════════════════════════════════════════════════════════════════════════
// 10. Calendar failures
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn calendar_failure_after_a_good_snapshot_is_stale_with_the_old_events_and_recovers() {
    let e = env(true, &[]).await;
    let failing = Arc::new(AtomicBool::new(false));
    let events = one_event_today();
    {
        let failing = failing.clone();
        mount_get(&e.server, CALENDAR_VIEW, move |_: &Request| {
            if failing.load(SeqCst) {
                server_error()
            } else {
                ResponseTemplate::new(200).set_body_json(json!({ "value": events }))
            }
        })
        .await;
    }

    let mut rx = spawn_calendar(&e, timing(fast(), an_hour()));
    let good = wait_for(&mut rx, "a fresh calendar", &[], |s| s.state == SourceState::Fresh).await;
    assert_eq!(good.events.len(), 1);

    failing.store(true, SeqCst);
    let stale = wait_for(&mut rx, "a stale calendar", &[], |s| s.state == SourceState::Stale).await;
    assert!(stale.stale);
    assert!(stale.error.as_deref().is_some_and(|r| !r.trim().is_empty()), "{stale:?}");
    assert_eq!(titles_of(&stale), titles_of(&good), "previous events are retained");
    let stale_at = stale.updated_at.expect("updated_at is the last success");
    assert!(stale_at >= good.updated_at.unwrap());

    failing.store(false, SeqCst);
    let back = wait_for(&mut rx, "recovery", &[], |s| s.state == SourceState::Fresh).await;
    assert!(back.error.is_none() && !back.stale, "{back:?}");
    assert_eq!(titles_of(&back), ["Eng sync"]);
}

#[tokio::test]
async fn calendar_failure_with_no_previous_data_is_an_error_never_empty() {
    let e = env(true, &[]).await;
    mount_get(&e.server, CALENDAR_VIEW, |_: &Request| server_error()).await;

    let mut rx = spawn_calendar(&e, timing(fast(), an_hour()));
    let forbid = [SourceState::Fresh, SourceState::Empty];
    let snap = wait_for(&mut rx, "an error calendar", &forbid, |s| {
        s.state == SourceState::Error
    })
    .await;
    assert!(snap.events.is_empty());
    assert!(snap.error.as_deref().is_some_and(|r| !r.trim().is_empty()), "{snap:?}");
    assert!(snap.updated_at.is_none());

    wait_for_gets(&e.server, CALENDAR_VIEW, 4).await;
    let later = rx.borrow().clone().expect("published");
    assert_eq!(later.state, SourceState::Error, "{later:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// 9. today_window (pure)
// ═════════════════════════════════════════════════════════════════════════════

fn utc(s: &str) -> DateTime<Utc> {
    s.parse().unwrap()
}

fn west(hours: i32) -> FixedOffset {
    FixedOffset::west_opt(hours * 3600).unwrap()
}

#[test]
fn today_window_in_cdt_is_the_local_day_in_utc() {
    // 22:00 on Oct 11 local (CDT, UTC-5): today is Oct 11.
    let (start, end) = today_window(utc("2026-10-12T03:00:00Z"), &west(5));
    assert_eq!(start, utc("2026-10-11T05:00:00Z"));
    assert_eq!(end, utc("2026-10-12T05:00:00Z"));
}

#[test]
fn today_window_in_cst_is_the_local_day_in_utc() {
    // 21:00 on Oct 11 local (CST, UTC-6).
    let (start, end) = today_window(utc("2026-10-12T03:00:00Z"), &west(6));
    assert_eq!(start, utc("2026-10-11T06:00:00Z"));
    assert_eq!(end, utc("2026-10-12T06:00:00Z"));
}

#[test]
fn today_window_flips_to_the_next_day_exactly_at_local_midnight() {
    let cdt = west(5);
    let (before_start, _) = today_window(utc("2026-10-12T04:59:59Z"), &cdt);
    assert_eq!(before_start, utc("2026-10-11T05:00:00Z"), "one second before local midnight");

    let (start, end) = today_window(utc("2026-10-12T05:00:00Z"), &cdt);
    assert_eq!(start, utc("2026-10-12T05:00:00Z"), "midnight itself belongs to the new day");
    assert_eq!(end, utc("2026-10-13T05:00:00Z"));

    let cst = west(6);
    let (start, end) = today_window(utc("2026-10-12T06:00:00Z"), &cst);
    assert_eq!(start, utc("2026-10-12T06:00:00Z"));
    assert_eq!(end, utc("2026-10-13T06:00:00Z"));
}

#[test]
fn today_window_is_a_24_hour_local_day_containing_now_for_any_fixed_offset() {
    let offsets = [
        FixedOffset::east_opt(0).unwrap(),
        west(5),
        west(6),
        FixedOffset::east_opt(5 * 3600 + 1800).unwrap(),
        FixedOffset::east_opt(13 * 3600).unwrap(),
    ];
    let first = utc("2026-10-10T00:00:00Z");
    for offset in offsets {
        for hours in 0..72 {
            let now = first + ChronoDuration::minutes(hours * 37);
            let (start, end) = today_window(now, &offset);
            assert_eq!(end - start, ChronoDuration::hours(24), "{offset} @ {now}");
            assert!(start <= now && now < end, "{offset}: {now} not in [{start}, {end})");
            let local_start = start.with_timezone(&offset);
            assert_eq!(
                (local_start.hour(), local_start.minute(), local_start.second()),
                (0, 0, 0),
                "{offset} @ {now}: window must start at local midnight"
            );
        }
    }
}

/// A US-Central-like zone with the 2026 DST transitions hard-coded, so the
/// "next local midnight" behaviour can be pinned without a tz database:
/// spring forward 2026-03-08 08:00Z (CST -6 -> CDT -5), fall back 2026-11-01
/// 07:00Z (CDT -> CST).
#[derive(Clone, Copy, Debug)]
struct UsCentral2026;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UsCentralOffset(FixedOffset);

impl std::fmt::Display for UsCentralOffset {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&self.0, f)
    }
}

impl Offset for UsCentralOffset {
    fn fix(&self) -> FixedOffset {
        self.0
    }
}

impl UsCentral2026 {
    fn at(month: u32, day: u32, hour: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, month, day)
            .unwrap()
            .and_hms_opt(hour, 0, 0)
            .unwrap()
    }

    fn offset_at_utc(utc: &NaiveDateTime) -> FixedOffset {
        if *utc >= Self::at(3, 8, 8) && *utc < Self::at(11, 1, 7) {
            west(5)
        } else {
            west(6)
        }
    }
}

impl TimeZone for UsCentral2026 {
    type Offset = UsCentralOffset;

    fn from_offset(_: &UsCentralOffset) -> Self {
        UsCentral2026
    }

    fn offset_from_local_date(&self, local: &NaiveDate) -> LocalResult<UsCentralOffset> {
        self.offset_from_local_datetime(&local.and_hms_opt(12, 0, 0).unwrap())
    }

    fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> LocalResult<UsCentralOffset> {
        let valid: Vec<FixedOffset> = [west(5), west(6)]
            .into_iter()
            .filter(|off| {
                let utc = *local - ChronoDuration::seconds(off.local_minus_utc() as i64);
                Self::offset_at_utc(&utc) == *off
            })
            .collect();
        match valid.as_slice() {
            [] => LocalResult::None,
            [one] => LocalResult::Single(UsCentralOffset(*one)),
            [earliest, latest] => {
                LocalResult::Ambiguous(UsCentralOffset(*earliest), UsCentralOffset(*latest))
            }
            _ => unreachable!(),
        }
    }

    fn offset_from_utc_date(&self, utc: &NaiveDate) -> UsCentralOffset {
        self.offset_from_utc_datetime(&utc.and_hms_opt(12, 0, 0).unwrap())
    }

    fn offset_from_utc_datetime(&self, utc: &NaiveDateTime) -> UsCentralOffset {
        UsCentralOffset(Self::offset_at_utc(utc))
    }
}

#[test]
fn today_window_on_the_spring_forward_day_is_23_hours_long() {
    let tz = UsCentral2026;
    // Mid-morning CDT, after the 02:00 -> 03:00 jump.
    let (start, end) = today_window(utc("2026-03-08T15:00:00Z"), &tz);
    assert_eq!(start, utc("2026-03-08T06:00:00Z"), "local midnight is still CST");
    assert_eq!(end, utc("2026-03-09T05:00:00Z"), "next local midnight is CDT");
    assert_eq!(end - start, ChronoDuration::hours(23));

    // Before the jump the same local day gives the same window.
    let (early_start, early_end) = today_window(utc("2026-03-08T07:00:00Z"), &tz);
    assert_eq!((early_start, early_end), (start, end));
}

#[test]
fn today_window_on_the_fall_back_day_is_25_hours_long() {
    let tz = UsCentral2026;
    let (start, end) = today_window(utc("2026-11-01T12:00:00Z"), &tz);
    assert_eq!(start, utc("2026-11-01T05:00:00Z"), "local midnight is still CDT");
    assert_eq!(end, utc("2026-11-02T06:00:00Z"), "next local midnight is CST");
    assert_eq!(end - start, ChronoDuration::hours(25));
}

// ═════════════════════════════════════════════════════════════════════════════
// 11. MCP tools and the IPC broadcast say exactly what the snapshots say
// ═════════════════════════════════════════════════════════════════════════════

fn mcp_state(
    mailbox: watch::Receiver<Option<MailboxSnapshot>>,
    calendar: watch::Receiver<Option<CalendarSnapshot>>,
) -> McpSharedState {
    let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel();
    std::mem::forget(event_rx);
    let mut state = McpSharedState::for_test(event_tx);
    state.fred_mailbox_rx = mailbox;
    state.fred_calendar_rx = calendar;
    state
}

fn tool_outputs(state: &McpSharedState) -> (Value, Value, Value) {
    (
        fred_tools::get_state(state),
        fred_tools::list_unread_emails(state),
        fred_tools::list_calendar_events(state, &fred_tools::CalendarEventsInput::default()),
    )
}

fn json_of<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v).unwrap()
}

fn broadcast_of(mailbox: &MailboxSnapshot, calendar: &CalendarSnapshot) -> Value {
    json_of(&ServerMsg::FredState {
        mailbox: mailbox.clone(),
        calendar: calendar.clone(),
    })
}

fn fixed<S>(snapshot: S) -> watch::Receiver<Option<S>> {
    watch::channel(Some(snapshot)).1
}

#[tokio::test]
async fn mcp_tools_and_the_broadcast_report_exactly_what_the_live_sources_published() {
    let e = env(true, &["alice@x.com"]).await;
    mount_mail(&e, standard_window(), 42).await;
    let now = whole_seconds_now();
    mount_calendar(
        &e.server,
        vec![
            event("e1", "Eng sync", now + ChronoDuration::minutes(60), now + ChronoDuration::minutes(90)),
            event("e2", "Retro", now + ChronoDuration::minutes(120), now + ChronoDuration::minutes(150)),
        ],
    )
    .await;

    // Hour-long polls: after the first cycle the snapshots stop changing, so
    // what we read below is exactly what the tools will read.
    let mut mrx = spawn_mailbox(&e, timing(an_hour(), an_hour()));
    let mut crx = spawn_calendar(&e, timing(an_hour(), an_hour()));
    let m = wait_for(&mut mrx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;
    let c = wait_for(&mut crx, "a fresh calendar", &[], |s| s.state == SourceState::Fresh).await;

    let state = mcp_state(mrx.clone(), crx.clone());
    let (st, unread, cal) = tool_outputs(&state);

    // list_unread_emails
    assert_eq!(unread["state"], "fresh", "{unread}");
    assert_eq!(unread["unread_count"], 42, "{unread}");
    assert_eq!(unread["updated_at"], json_of(&m.updated_at), "{unread}");
    let unread_ids: Vec<&str> = unread["items"]
        .as_array()
        .expect("items array")
        .iter()
        .map(|i| i["id"].as_str().unwrap())
        .collect();
    let snapshot_unread_ids: Vec<&str> =
        m.items.iter().filter(|i| !i.is_read).map(|i| i.id.as_str()).collect();
    assert_eq!(unread_ids, snapshot_unread_ids);

    // list_calendar_events
    assert_eq!(cal["state"], "fresh", "{cal}");
    assert_eq!(cal["updated_at"], json_of(&c.updated_at), "{cal}");
    assert_eq!(cal["events"].as_array().map(Vec::len), Some(c.events.len()), "{cal}");

    // get_state
    assert_eq!(st["state"], "fresh", "{st}");
    assert_eq!(st["mailbox_state"], json_of(&m.state), "{st}");
    assert_eq!(st["calendar_state"], json_of(&c.state), "{st}");
    assert_eq!(st["unread_count"], 42, "{st}");
    assert_eq!(st["today_event_count"], 2, "{st}");
    assert_eq!(st["mailbox"].as_array().map(Vec::len), Some(m.items.len()), "{st}");
    assert_eq!(st["calendar"].as_array().map(Vec::len), Some(c.events.len()), "{st}");
    let stamps = [json_of(&m.updated_at), json_of(&c.updated_at)];
    assert!(stamps.contains(&st["updated_at"]), "{st}");

    // The IPC broadcast agrees with the tools.
    let msg = broadcast_of(&m, &c);
    assert_eq!(msg["mailbox"]["state"], st["mailbox_state"], "{msg}");
    assert_eq!(msg["calendar"]["state"], st["calendar_state"], "{msg}");
    assert_eq!(msg["mailbox"]["unread_count"], st["unread_count"], "{msg}");
    assert_eq!(msg["mailbox"]["updated_at"], unread["updated_at"], "{msg}");
    assert_eq!(msg["calendar"]["updated_at"], cal["updated_at"], "{msg}");
}

fn a_prompt() -> DeviceFlowPrompt {
    DeviceFlowPrompt {
        verification_uri: "https://microsoft.com/devicelogin".into(),
        user_code: "ABCD-EFGH".into(),
        expires_at: utc("2026-10-10T16:00:00Z"),
    }
}

#[tokio::test]
async fn mcp_tools_and_the_broadcast_say_unauthenticated_with_the_prompt_and_never_fresh_or_empty() {
    let reason = "Sign in to Microsoft to see your mail and calendar";
    let mailbox = MailboxSnapshot {
        state: SourceState::Unauthenticated,
        auth_prompt: Some(a_prompt()),
        error: Some(reason.into()),
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        state: SourceState::Unauthenticated,
        auth_prompt: Some(a_prompt()),
        error: Some(reason.into()),
        ..Default::default()
    };
    let state = mcp_state(fixed(mailbox.clone()), fixed(calendar.clone()));
    let (st, unread, cal) = tool_outputs(&state);

    for (name, out) in [("get_state", &st), ("list_unread_emails", &unread), ("list_calendar_events", &cal)] {
        assert_eq!(out["state"], "unauthenticated", "{name}: {out}");
        assert_eq!(out["reason"], reason, "{name}: {out}");
        assert_eq!(out["auth"]["verification_uri"], "https://microsoft.com/devicelogin", "{name}: {out}");
        assert_eq!(out["auth"]["user_code"], "ABCD-EFGH", "{name}: {out}");
        assert!(out["auth"]["expires_at"].is_string(), "{name}: {out}");
        assert_no_secrets(name, &out.to_string());
    }
    assert_eq!(st["mailbox_state"], "unauthenticated", "{st}");
    assert_eq!(st["calendar_state"], "unauthenticated", "{st}");

    let msg = broadcast_of(&mailbox, &calendar);
    assert_eq!(msg["mailbox"]["state"], "unauthenticated", "{msg}");
    assert_eq!(msg["calendar"]["state"], "unauthenticated", "{msg}");
}

#[tokio::test]
async fn mcp_tools_and_the_broadcast_say_stale_with_the_reason_and_the_retained_data() {
    let mailbox_at = utc("2026-10-10T15:00:00Z");
    let unread_item = |id: &str| MailboxItem {
        id: id.into(),
        from: "Alice Smith <alice@x.com>".into(),
        subject: format!("subject {id}"),
        is_read: false,
        ..Default::default()
    };
    let mailbox = MailboxSnapshot {
        state: SourceState::Stale,
        stale: true,
        error: Some("Microsoft Graph is not responding".into()),
        unread_count: 42,
        items: vec![unread_item("m1"), unread_item("m2")],
        updated_at: Some(mailbox_at),
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        state: SourceState::Fresh,
        updated_at: Some(utc("2026-10-10T15:01:00Z")),
        events: vec![CalendarEvent { id: "e1".into(), title: "Eng sync".into(), ..Default::default() }],
        ..Default::default()
    };
    let state = mcp_state(fixed(mailbox.clone()), fixed(calendar.clone()));
    let (st, unread, _cal) = tool_outputs(&state);

    assert_eq!(unread["state"], "stale", "{unread}");
    assert_eq!(unread["reason"], "Microsoft Graph is not responding", "{unread}");
    assert_eq!(unread["unread_count"], 42, "{unread}");
    assert_eq!(unread["items"].as_array().map(Vec::len), Some(2), "{unread}");
    assert_eq!(unread["updated_at"], json_of(&Some(mailbox_at)), "{unread}");

    assert_eq!(st["state"], "stale", "overall is the worse source: {st}");
    assert_eq!(st["mailbox_state"], "stale", "{st}");
    assert_eq!(st["calendar_state"], "fresh", "{st}");
    assert_eq!(st["reason"], "Microsoft Graph is not responding", "{st}");
    assert_eq!(st["unread_count"], 42, "{st}");

    let msg = broadcast_of(&mailbox, &calendar);
    assert_eq!(msg["mailbox"]["state"], "stale", "{msg}");
    assert_eq!(msg["calendar"]["state"], "fresh", "{msg}");
}

#[tokio::test]
async fn mcp_tools_and_the_broadcast_say_error_when_nothing_has_ever_been_fetched() {
    let mailbox = MailboxSnapshot {
        state: SourceState::Error,
        error: Some("Microsoft Graph returned an error".into()),
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        state: SourceState::Error,
        error: Some("Microsoft Graph returned an error".into()),
        ..Default::default()
    };
    let state = mcp_state(fixed(mailbox.clone()), fixed(calendar.clone()));
    let (st, unread, cal) = tool_outputs(&state);

    for (name, out) in [("get_state", &st), ("list_unread_emails", &unread), ("list_calendar_events", &cal)] {
        assert_eq!(out["state"], "error", "{name}: {out}");
        assert_eq!(out["reason"], "Microsoft Graph returned an error", "{name}: {out}");
    }
    let msg = broadcast_of(&mailbox, &calendar);
    assert_eq!(msg["mailbox"]["state"], "error", "{msg}");
    assert_eq!(msg["calendar"]["state"], "error", "{msg}");
}

#[tokio::test]
async fn mcp_today_event_count_does_not_count_cancelled_events() {
    let live = |id: &str| CalendarEvent {
        id: id.into(),
        title: format!("event {id}"),
        status: "accepted".into(),
        ..Default::default()
    };
    let cancelled = CalendarEvent {
        id: "e3".into(),
        title: "event e3".into(),
        status: "cancelled".into(),
        is_cancelled: true,
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        state: SourceState::Fresh,
        updated_at: Some(utc("2026-10-10T15:00:00Z")),
        events: vec![live("e1"), live("e2"), cancelled],
        ..Default::default()
    };
    let mailbox = MailboxSnapshot {
        state: SourceState::Fresh,
        updated_at: Some(utc("2026-10-10T15:00:00Z")),
        unread_count: 1,
        items: vec![MailboxItem { id: "m1".into(), ..Default::default() }],
        ..Default::default()
    };
    let state = mcp_state(fixed(mailbox), fixed(calendar));
    let st = fred_tools::get_state(&state);
    assert_eq!(st["today_event_count"], 2, "{st}");
}

// ═════════════════════════════════════════════════════════════════════════════
// 12. Contract: Graph is only ever read (GET); the only non-GETs are OAuth POSTs
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn across_sign_in_and_polling_every_graph_call_is_a_get_and_only_oauth_endpoints_see_posts() {
    let e = env(false, &["alice@x.com"]).await;
    let approve = Arc::new(AtomicBool::new(true));
    mount_oauth(&e.server, approve).await;
    mount_mail(&e, standard_window(), 5).await;
    mount_calendar(&e.server, one_event_today()).await;

    let ttl = Duration::from_millis(150);
    let mut mrx = spawn_mailbox(&e, timing(fast(), ttl));
    let mut crx = spawn_calendar(&e, timing(fast(), ttl));
    wait_for(&mut mrx, "a fresh mailbox", &[], |s| s.state == SourceState::Fresh).await;
    wait_for(&mut crx, "a fresh calendar", &[], |s| s.state == SourceState::Fresh).await;

    // Several steady-state cycles on every endpoint (the short unread-count
    // ttl makes the folder endpoint get exercised repeatedly too).
    wait_for_gets(&e.server, DELTA, 4).await;
    wait_for_gets(&e.server, CALENDAR_VIEW, 4).await;
    wait_for_gets(&e.server, FOLDER, 2).await;

    let rs = reqs(&e.server).await;
    for r in &rs {
        if is_oauth(r) {
            continue;
        }
        assert_eq!(
            r.method.to_string(),
            "GET",
            "Graph call {} {} must be read-only",
            r.method,
            r.url.path()
        );
    }
    for r in rs.iter().filter(|r| r.method.as_str() != "GET") {
        assert!(
            r.method.as_str() == "POST" && is_oauth(r),
            "the only non-GET requests are POSTs to /oauth2/v2.0/ endpoints, saw {} {}",
            r.method,
            r.url.path()
        );
    }
    // Not vacuous: the run really did sign in and read all three resources.
    assert!(count(&rs, "POST", DEVICECODE) >= 1 && count(&rs, "POST", TOKEN) >= 1);
    for p in [DELTA, FOLDER, CALENDAR_VIEW] {
        assert!(count(&rs, "GET", p) >= 1, "{p} was never read");
    }
}
