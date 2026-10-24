//! Fred's Google mail + calendar sources: Gmail history sync, Calendar events,
//! and the same truthfulness rules as the Microsoft sources (a failed, stale,
//! throttled or signed-out fetch is never shown as "0 unread" or "nothing
//! today").
//!
//! Every test runs its own wiremock "Google" (Gmail, Calendar and the token
//! endpoint on one server) and its own temp dir, and drives the real sources
//! through `spawn_with_dirty(GoogleClient, label, ..)` exactly as the daemon
//! does: ONE `GoogleClient` clone is handed to both sources of an account.
//!
//! The mock's Gmail is a small stateful fake (`World`): tests change what it
//! answers between cycles instead of re-mounting mocks.
//!
//! Determinism. Most tests set the poll interval to an hour and drive cycles
//! with the dirty channel, so ONE trigger is exactly ONE refresh cycle and the
//! next published snapshot is that cycle's result. Nothing sleeps for a fixed
//! time. The throttle tests use the lower-bound technique of
//! `fred_rate_limit.rs`: the fake stamps every request with a monotonic
//! `Instant`, and the tests only assert LOWER bounds on gaps between requests
//! (the source can only be slower than its wait, never faster) plus a few
//! deliberately generous (>= 1 s of slack) upper bounds.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, NaiveDate, SecondsFormat, Timelike, Utc};
use nostromo::config::Config;
use nostromo::data::fred_calendar::{CalendarEvent, CalendarSnapshot};
use nostromo::data::fred_mailbox::{MailboxItem, MailboxSnapshot};
use nostromo::data::fred_mailbox_native::FredTiming;
use nostromo::data::google_calendar::GoogleCalendarSource;
use nostromo::data::google_client::{GoogleClient, GoogleOAuthClient, GoogleOptions};
use nostromo::data::graph_client::DeviceFlowPrompt;
use nostromo::data::google_mailbox::GoogleMailboxSource;
use nostromo::data::work::model::SourceState;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::{mpsc, watch};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

/// Upper bound for anything we wait on. Generous: the happy path takes
/// milliseconds; this only matters when something is broken.
const WAIT: Duration = Duration::from_secs(30);

const LABEL: &str = "work";
const EMAIL: &str = "me@example.com";
const CLIENT_SECRET: &str = "test-client-secret-s3cr3t";
const SEEDED_ACCESS_TOKEN: &str = "at-seeded-token";
const SEEDED_REFRESH_TOKEN: &str = "rt-seeded-token";

const PROFILE: &str = "/gmail/v1/users/me/profile";
const LIST: &str = "/gmail/v1/users/me/messages";
const HISTORY: &str = "/gmail/v1/users/me/history";
const INBOX_LABEL: &str = "/gmail/v1/users/me/labels/INBOX";
const EVENTS: &str = "/calendar/v3/calendars/primary/events";
const TOKEN: &str = "/token";

// ═════════════════════════════════════════════════════════════════════════════
// The fake Google
// ═════════════════════════════════════════════════════════════════════════════

/// One request the fake served.
#[derive(Clone, Debug)]
struct Hit {
    at: Instant,
    method: String,
    path: String,
    query: Vec<(String, String)>,
    bearer: String,
    /// The fake answered it with the injected failure.
    failed: bool,
}

impl Hit {
    fn param(&self, key: &str) -> Option<&str> {
        self.query.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

struct World {
    profile: Value,
    list: Value,
    messages: HashMap<String, Value>,
    labels: Value,
    /// Answers to the next history calls, in order; afterwards "no changes at
    /// `history_head`".
    history_queue: VecDeque<(u16, Value)>,
    history_head: String,
    /// Calendar pages keyed by `pageToken` ("" for the first page).
    calendar_pages: HashMap<String, Value>,
    /// Every Gmail and Calendar request fails like this: (status, Retry-After secs).
    failure: Option<(u16, Option<u64>)>,
    hits: Vec<Hit>,
}

impl World {
    fn new() -> Self {
        Self {
            profile: json!({ "emailAddress": EMAIL, "historyId": "100", "messagesTotal": 3 }),
            list: json!({ "resultSizeEstimate": 0 }),
            messages: HashMap::new(),
            labels: json!({ "id": "INBOX", "name": "INBOX", "threadsUnread": 0 }),
            history_queue: VecDeque::new(),
            history_head: "100".into(),
            calendar_pages: HashMap::from([(String::new(), json!({ "items": [] }))]),
            failure: None,
            hits: Vec::new(),
        }
    }

    fn hits_on(&self, p: &str) -> Vec<Hit> {
        self.hits.iter().filter(|h| h.path == p).cloned().collect()
    }

    fn count(&self, p: &str) -> usize {
        self.hits.iter().filter(|h| h.path == p).count()
    }

    fn message_hits(&self) -> Vec<Hit> {
        self.hits.iter().filter(|h| h.path.starts_with(&format!("{LIST}/"))).cloned().collect()
    }

    /// The inbox as Gmail would list it: these messages, this label count.
    fn set_inbox(&mut self, msgs: &[Value], threads_unread: i64) {
        self.list = if msgs.is_empty() {
            // Gmail omits `messages` entirely for an empty result.
            json!({ "resultSizeEstimate": 0 })
        } else {
            json!({
                "messages": msgs
                    .iter()
                    .map(|m| json!({ "id": m["id"], "threadId": m["threadId"] }))
                    .collect::<Vec<_>>(),
                "resultSizeEstimate": msgs.len(),
            })
        };
        for m in msgs {
            self.messages.insert(m["id"].as_str().unwrap().to_owned(), m.clone());
        }
        self.set_threads_unread(Some(threads_unread));
    }

    fn set_threads_unread(&mut self, n: Option<i64>) {
        self.labels = match n {
            Some(n) => json!({ "id": "INBOX", "name": "INBOX", "threadsUnread": n }),
            None => json!({ "id": "INBOX", "name": "INBOX" }),
        };
    }

    /// The next history call answers with one page and moves the head.
    fn queue_history(&mut self, status: u16, body: Value) {
        self.history_queue.push_back((status, body));
    }

    fn heal(&mut self) {
        self.failure = None;
    }
}

type Shared = Arc<Mutex<World>>;

fn bearer(req: &Request) -> String {
    req.headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
        .to_owned()
}

fn google_not_found() -> ResponseTemplate {
    ResponseTemplate::new(404).set_body_json(json!({
        "error": { "code": 404, "message": "Requested entity was not found.", "status": "NOT_FOUND",
                   "errors": [{ "reason": "notFound", "domain": "global" }] }
    }))
}

fn serve(shared: &Shared, req: &Request) -> ResponseTemplate {
    let mut w = shared.lock().unwrap();
    let p = req.url.path().to_owned();
    let failure = w.failure;
    w.hits.push(Hit {
        at: Instant::now(),
        method: req.method.to_string(),
        path: p.clone(),
        query: req.url.query_pairs().into_owned().collect(),
        bearer: bearer(req),
        failed: failure.is_some(),
    });

    if let Some((status, retry_after)) = failure {
        let mut t = ResponseTemplate::new(status).set_body_json(json!({
            "error": { "code": status, "message": "slow down", "status": "RESOURCE_EXHAUSTED" }
        }));
        if let Some(secs) = retry_after {
            t = t.insert_header("Retry-After", secs.to_string().as_str());
        }
        return t;
    }

    match p.as_str() {
        PROFILE => ResponseTemplate::new(200).set_body_json(w.profile.clone()),
        LIST => ResponseTemplate::new(200).set_body_json(w.list.clone()),
        INBOX_LABEL => ResponseTemplate::new(200).set_body_json(w.labels.clone()),
        HISTORY => match w.history_queue.pop_front() {
            Some((status, body)) => ResponseTemplate::new(status).set_body_json(body),
            None => ResponseTemplate::new(200).set_body_json(json!({ "historyId": w.history_head })),
        },
        EVENTS => {
            let token = req.url.query_pairs().find(|(k, _)| k == "pageToken").map(|(_, v)| v.into_owned());
            match w.calendar_pages.get(token.as_deref().unwrap_or("")) {
                Some(page) => ResponseTemplate::new(200).set_body_json(page.clone()),
                None => google_not_found(),
            }
        }
        other if other.starts_with(&format!("{LIST}/")) => {
            let id = other.rsplit('/').next().unwrap_or("");
            match w.messages.get(id) {
                Some(m) => ResponseTemplate::new(200).set_body_json(m.clone()),
                None => google_not_found(),
            }
        }
        _ => google_not_found(),
    }
}

// ── Gmail message builders ───────────────────────────────────────────────────

fn gmail_msg(id: &str, thread: &str, labels: &[&str], from: &str, subject: &str, at: DateTime<Utc>) -> Value {
    json!({
        "id": id,
        "threadId": thread,
        "labelIds": labels,
        "internalDate": at.timestamp_millis().to_string(),
        "payload": { "headers": [
            { "name": "From", "value": from },
            { "name": "Subject", "value": subject },
            { "name": "Date", "value": "Mon, 1 Jan 2026 00:00:00 +0000" },
        ]},
    })
}

/// Three inbox messages, two unread, in arbitrary list order.
/// Display order must be m3 (unread, newest), m1 (unread, older), m2 (read).
fn standard_inbox() -> Vec<Value> {
    let now = Utc::now();
    vec![
        gmail_msg(
            "m1",
            "t1",
            &["INBOX", "UNREAD", "CATEGORY_PERSONAL"],
            "Boss Person <Boss@Example.COM>",
            "Budget review",
            now - ChronoDuration::minutes(60),
        ),
        gmail_msg(
            "m2",
            "t2",
            &["INBOX"],
            "Calendar <calendar@example.org>",
            "Invitation: Standup @ Mon 9am",
            now - ChronoDuration::minutes(10),
        ),
        gmail_msg("m3", "t3", &["INBOX", "UNREAD"], "Zed <zed@example.net>", "Lunch?", now - ChronoDuration::minutes(5)),
    ]
}

fn history_page(head: &str, records: Vec<Value>) -> Value {
    json!({ "history": records, "historyId": head })
}

fn stub(id: &str, labels: &[&str]) -> Value {
    json!({ "id": id, "threadId": format!("t-{id}"), "labelIds": labels })
}

fn labels_removed(id: &str, labels_of_message: &[&str], removed: &[&str]) -> Value {
    json!({ "id": "h", "labelsRemoved": [{ "message": stub(id, labels_of_message), "labelIds": removed }] })
}

// ═════════════════════════════════════════════════════════════════════════════
// Environment
// ═════════════════════════════════════════════════════════════════════════════

struct Env {
    server: MockServer,
    dir: TempDir,
    world: Shared,
    client: GoogleClient,
    config: Config,
}

impl Env {
    fn world(&self) -> MutexGuard<'_, World> {
        self.world.lock().unwrap()
    }

    fn token_path(&self) -> std::path::PathBuf {
        self.dir.path().join("google").join("token.json")
    }

    /// Wait (bounded) until `ok` holds for the fake's request log.
    async fn wait_until(&self, what: &str, ok: impl Fn(&World) -> bool) {
        let waited = tokio::time::timeout(WAIT, async {
            loop {
                if ok(&self.world()) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await;
        if waited.is_err() {
            let seen: Vec<String> =
                self.world().hits.iter().map(|h| format!("{} {} failed={}", h.method, h.path, h.failed)).collect();
            panic!("timed out waiting for {what}; requests seen: {seen:?}");
        }
    }

    /// Requests the mock server saw that are not Gmail / Calendar (token POSTs).
    async fn other_requests(&self) -> Vec<Request> {
        self.server
            .received_requests()
            .await
            .expect("request recording is enabled")
            .into_iter()
            .filter(|r| !r.url.path().starts_with("/gmail/") && !r.url.path().starts_with("/calendar/"))
            .collect()
    }
}

/// A fake Google plus a `GoogleClient` pointed at it. `signed_in` pre-seeds a
/// valid token file; otherwise the account starts signed out.
async fn env(signed_in: bool, vip_senders: &[&str]) -> Env {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let world: Shared = Arc::new(Mutex::new(World::new()));
    let token_path = dir.path().join("google").join("token.json");

    if signed_in {
        std::fs::create_dir_all(token_path.parent().unwrap()).unwrap();
        std::fs::write(
            &token_path,
            json!({
                "access_token": SEEDED_ACCESS_TOKEN,
                "refresh_token": SEEDED_REFRESH_TOKEN,
                "expires_at": (Utc::now() + ChronoDuration::hours(1)).timestamp(),
                "email": EMAIL,
            })
            .to_string(),
        )
        .unwrap();
    }

    let shared = world.clone();
    Mock::given(method("GET"))
        .and(path_regex(r"^/(gmail|calendar)/"))
        .respond_with(move |req: &Request| serve(&shared, req))
        .mount(&server)
        .await;

    let base = server.uri();
    let client = GoogleClient::with_options(
        LABEL.into(),
        Some(EMAIL.into()),
        GoogleOAuthClient::new("test-client-id", CLIENT_SECRET),
        token_path,
        GoogleOptions {
            auth_url: format!("{base}/auth"),
            token_url: format!("{base}{TOKEN}"),
            gmail_base: format!("{base}/gmail/v1"),
            calendar_base: format!("{base}/calendar/v3"),
            loopback_ttl: Duration::from_secs(120),
            ..GoogleOptions::default()
        },
    )
    .expect("google client builds");

    let config = Config { vip_senders: vip_senders.iter().map(|s| s.to_string()).collect(), ..Default::default() };
    Env { server, dir, world, client, config }
}

/// An offset at which it is currently 12:00 local time, so "today" never rolls
/// over mid-test.
fn noon_offset() -> FixedOffset {
    let secs_into_utc_day = Utc::now().num_seconds_from_midnight() as i32;
    FixedOffset::east_opt(12 * 3600 - secs_into_utc_day).unwrap()
}

fn timing(poll: Duration, unread_count_ttl: Duration) -> FredTiming {
    FredTiming {
        mailbox_poll: poll,
        calendar_poll: poll,
        unread_count_ttl,
        day_offset: Some(noon_offset()),
    }
}

fn fast() -> Duration {
    Duration::from_millis(100)
}

fn an_hour() -> Duration {
    Duration::from_secs(3600)
}

/// Cycles run only when the returned sender is poked (poll = an hour).
fn manual() -> FredTiming {
    timing(an_hour(), an_hour())
}

fn spawn_mailbox(
    e: &Env,
    t: FredTiming,
) -> (watch::Receiver<Option<MailboxSnapshot>>, mpsc::UnboundedSender<()>) {
    let (tx, rx) = mpsc::unbounded_channel();
    (GoogleMailboxSource::spawn_with_dirty(e.client.clone(), LABEL.into(), e.config.clone(), t, rx), tx)
}

fn spawn_calendar(
    e: &Env,
    t: FredTiming,
) -> (watch::Receiver<Option<CalendarSnapshot>>, mpsc::UnboundedSender<()>) {
    let (tx, rx) = mpsc::unbounded_channel();
    (GoogleCalendarSource::spawn_with_dirty(e.client.clone(), LABEL.into(), t, rx), tx)
}

// ═════════════════════════════════════════════════════════════════════════════
// Snapshots and waiting
// ═════════════════════════════════════════════════════════════════════════════

trait Snap: Clone + std::fmt::Debug + serde::Serialize {
    fn state(&self) -> SourceState;
    fn error(&self) -> Option<&str>;
    fn is_stale(&self) -> bool;
    fn prompt(&self) -> Option<&DeviceFlowPrompt>;
    fn retry_at(&self) -> Option<DateTime<Utc>>;
}

macro_rules! impl_snap {
    ($t:ty) => {
        impl Snap for $t {
            fn state(&self) -> SourceState {
                self.state
            }
            fn error(&self) -> Option<&str> {
                self.error.as_deref()
            }
            fn is_stale(&self) -> bool {
                self.stale
            }
            fn prompt(&self) -> Option<&DeviceFlowPrompt> {
                self.auth_prompt.as_ref()
            }
            fn retry_at(&self) -> Option<DateTime<Utc>> {
                self.retry_at
            }
        }
    };
}
impl_snap!(MailboxSnapshot);
impl_snap!(CalendarSnapshot);

/// Invariants for EVERY snapshot ever published: a snapshot never claims
/// health while reporting a failure, each state carries its evidence, and no
/// secret is ever serialised.
fn assert_snapshot_is_honest<S: Snap>(s: &S) {
    match s.state() {
        SourceState::Fresh | SourceState::Empty => assert!(
            s.error().is_none() && !s.is_stale() && s.prompt().is_none(),
            "snapshot claims {:?} while reporting a failure / stale data / sign-in: {s:?}",
            s.state()
        ),
        SourceState::Stale => assert!(s.is_stale() && s.error().is_some(), "a Stale snapshot needs `stale` and a reason: {s:?}"),
        SourceState::Error => assert!(s.error().is_some(), "an Error snapshot needs a reason: {s:?}"),
        SourceState::RateLimited => {
            assert!(s.retry_at().is_some() && s.error().is_some(), "a RateLimited snapshot needs retry_at and a reason: {s:?}")
        }
        SourceState::Unauthenticated => assert!(
            s.prompt().is_some() && s.error().is_some(),
            "an Unauthenticated snapshot needs the prompt and a reason: {s:?}"
        ),
        _ => {}
    }
    let json = serde_json::to_string(s).unwrap();
    for secret in [SEEDED_ACCESS_TOKEN, SEEDED_REFRESH_TOKEN, CLIENT_SECRET, "access_token", "refresh_token"] {
        assert!(!json.contains(secret), "snapshot leaks {secret:?}: {json}");
    }
}

/// Wait (bounded) for a published snapshot satisfying `pred`. Every snapshot
/// seen on the way is checked for honesty and against `forbid`.
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
        Err(_) => panic!("timed out waiting for {what}; last snapshot: {:?}", rx.borrow().clone()),
    }
}

/// Poke the source once and return what the cycle it triggers publishes. The
/// source must be idle (poll is an hour), so exactly one cycle runs.
async fn next_snapshot<S: Snap>(
    rx: &mut watch::Receiver<Option<S>>,
    dirty: &mpsc::UnboundedSender<()>,
    what: &str,
) -> S {
    rx.borrow_and_update();
    dirty.send(()).expect("source is running");
    let waited = tokio::time::timeout(WAIT, async {
        loop {
            if rx.changed().await.is_err() {
                panic!("source stopped publishing while waiting for {what}");
            }
            let snap = rx.borrow_and_update().clone();
            if let Some(s) = snap {
                assert_snapshot_is_honest(&s);
                return s;
            }
        }
    })
    .await;
    waited.unwrap_or_else(|_| panic!("timed out waiting for {what}"))
}

async fn first_fresh_mailbox(rx: &mut watch::Receiver<Option<MailboxSnapshot>>) -> MailboxSnapshot {
    wait_for(rx, "the first fresh mailbox snapshot", &[SourceState::Error, SourceState::Stale], |s| {
        s.state == SourceState::Fresh
    })
    .await
}

fn ids(s: &MailboxSnapshot) -> Vec<&str> {
    s.items.iter().map(|i| i.id.as_str()).collect()
}

fn item<'a>(s: &'a MailboxSnapshot, id: &str) -> &'a MailboxItem {
    s.items.iter().find(|i| i.id == id).unwrap_or_else(|| panic!("no item {id} in {:?}", ids(s)))
}

async fn browser_get(uri: &str, query: &[(&str, &str)]) -> reqwest::Response {
    tokio::time::timeout(WAIT, reqwest::Client::new().get(uri).query(query).send())
        .await
        .expect("loopback answered in time")
        .expect("loopback reachable")
}

fn prompt_params(p: &DeviceFlowPrompt) -> HashMap<String, String> {
    url::Url::parse(&p.verification_uri).expect("prompt URL").query_pairs().into_owned().collect()
}

// ═════════════════════════════════════════════════════════════════════════════
// Mailbox: full sync
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn full_sync_publishes_the_inbox_unread_first_then_newest_with_the_labels_unread_count() {
    let e = env(true, &["boss@example.com"]).await;
    let inbox = standard_inbox();
    e.world().set_inbox(&inbox, 7);
    let (mut rx, _dirty) = spawn_mailbox(&e, manual());

    let snap = first_fresh_mailbox(&mut rx).await;

    assert_eq!(snap.state, SourceState::Fresh);
    assert!(!snap.stale && snap.error.is_none() && snap.auth_prompt.is_none());
    assert_eq!(snap.unread_count, 7, "the count is the INBOX label's threadsUnread, not the 2 unread rows held");
    assert_eq!(ids(&snap), vec!["m3", "m1", "m2"], "unread first, each group newest first");
    assert!(snap.updated_at.is_some() && snap.generated_at.is_some());

    let m1 = item(&snap, "m1");
    assert_eq!(m1.from, "Boss Person <Boss@Example.COM>");
    assert_eq!(m1.subject, "Budget review");
    assert!(!m1.is_read);
    assert!(m1.vip, "Boss@Example.COM matches the lowercase vip entry");
    assert!(!m1.is_invite);
    assert_eq!(
        m1.received_at.unwrap().timestamp_millis(),
        inbox[0]["internalDate"].as_str().unwrap().parse::<i64>().unwrap(),
        "received_at is Gmail's internalDate"
    );
    let m2 = item(&snap, "m2");
    assert!(m2.is_read, "no UNREAD label means read");
    assert!(m2.is_invite, "an `Invitation:` subject is an invite");
    assert!(!m2.vip);
    let m3 = item(&snap, "m3");
    assert!(!m3.is_read && !m3.vip && !m3.is_invite);
    assert!(m3.received_at > m1.received_at, "m3 is newer than m1");
    assert_eq!(
        m3.received_at.unwrap().timestamp_millis(),
        inbox[2]["internalDate"].as_str().unwrap().parse::<i64>().unwrap(),
        "received_at is Gmail's internalDate"
    );

    // Each row links to its conversation in Gmail's web UI for this account.
    for it in &snap.items {
        let link = url::Url::parse(it.web_link.as_deref().expect("web_link")).expect("web_link is a URL");
        assert_eq!(link.host_str(), Some("mail.google.com"));
        let q: HashMap<String, String> = link.query_pairs().into_owned().collect();
        assert_eq!(q.get("authuser").map(String::as_str), Some(EMAIL), "opens the right signed-in account");
        let thread = format!("t{}", &it.id[1..]);
        assert!(
            link.fragment().is_some_and(|f| f.ends_with(&thread)),
            "link points at the thread {thread}: {link}"
        );
    }
}

#[tokio::test]
async fn full_sync_reads_only_headers_and_only_with_get_and_the_stored_token() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 2);
    let (mut rx, _dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;

    {
        let w = e.world();
        let messages = w.message_hits();
        assert_eq!(messages.len(), 3, "one metadata fetch per listed message");
        for h in &messages {
            assert_eq!(h.param("format"), Some("metadata"), "no message bodies are ever requested");
        }
        let list = &w.hits_on(LIST)[0];
        assert_eq!(list.param("labelIds"), Some("INBOX"), "only the inbox is listed");
        assert_eq!(w.count(INBOX_LABEL), 1, "the unread count comes from the INBOX label");
        for h in &w.hits {
            assert_eq!(h.method, "GET", "Google is only ever read");
            assert_eq!(h.bearer, SEEDED_ACCESS_TOKEN, "every request carries the account's token");
        }
    }
    assert!(e.other_requests().await.is_empty(), "a valid token needs no token-endpoint call");
}

#[tokio::test]
async fn full_sync_drops_messages_that_are_not_in_the_inbox() {
    let e = env(true, &[]).await;
    let now = Utc::now();
    let archived = gmail_msg("old", "t-old", &["UNREAD"], "x <x@example.com>", "Archived already", now);
    let inbox = gmail_msg("keep", "t-keep", &["INBOX"], "y <y@example.com>", "Keep me", now);
    e.world().set_inbox(&[inbox, archived], 0);
    let (mut rx, _dirty) = spawn_mailbox(&e, manual());

    let snap = first_fresh_mailbox(&mut rx).await;

    assert_eq!(ids(&snap), vec!["keep"]);
}

#[tokio::test]
async fn a_genuinely_empty_inbox_is_empty_with_zero_unread() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&[], 0);
    let (mut rx, _dirty) = spawn_mailbox(&e, manual());

    let snap = wait_for(&mut rx, "an empty snapshot", &[SourceState::Error], |s| s.state == SourceState::Empty).await;

    assert_eq!(snap.unread_count, 0);
    assert!(snap.items.is_empty());
    assert!(snap.error.is_none());
}

#[tokio::test]
async fn a_cycle_with_no_read_state_change_does_not_refetch_the_unread_count_within_its_ttl() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    e.world().set_threads_unread(Some(99)); // would show if the label were fetched again

    let snap = next_snapshot(&mut rx, &dirty, "an idle cycle").await;

    assert_eq!(snap.state, SourceState::Fresh);
    assert_eq!(snap.unread_count, 7, "the cached count is still trusted");
    assert_eq!(e.world().count(INBOX_LABEL), 1);
}

// ═════════════════════════════════════════════════════════════════════════════
// Mailbox: history
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn history_marking_a_message_read_updates_the_row_and_refetches_the_unread_count_at_once() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    let before = first_fresh_mailbox(&mut rx).await;
    assert!(!item(&before, "m1").is_read);
    {
        let mut w = e.world();
        w.queue_history(200, history_page("101", vec![labels_removed("m1", &["INBOX", "CATEGORY_PERSONAL"], &["UNREAD"])]));
        w.history_head = "101".into();
        w.set_threads_unread(Some(6));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the read-state cycle").await;

    assert_eq!(snap.state, SourceState::Fresh);
    assert!(item(&snap, "m1").is_read, "m1 lost its UNREAD label");
    assert_eq!(snap.unread_count, 6, "the label was re-read straight away, well inside its one-hour TTL");
    assert_eq!(e.world().count(INBOX_LABEL), 2);
    assert_eq!(snap.items.len(), 3, "nothing else changed");
    assert_eq!(ids(&snap), vec!["m3", "m2", "m1"], "m1 is read now: it sorts after the unread m3, and among the reads by date");
}

#[tokio::test]
async fn history_adding_unread_to_a_held_message_marks_it_unread() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 2);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        let mut w = e.world();
        w.queue_history(
            200,
            history_page(
                "101",
                vec![json!({ "labelsAdded": [{ "message": stub("m2", &["INBOX", "UNREAD"]), "labelIds": ["UNREAD"] }] })],
            ),
        );
        w.set_threads_unread(Some(3));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the unread cycle").await;

    assert!(!item(&snap, "m2").is_read);
    assert_eq!(snap.unread_count, 3);
}

#[tokio::test]
async fn history_removing_the_inbox_label_removes_the_message() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        let mut w = e.world();
        // Archived: INBOX goes away, the message itself still exists.
        w.queue_history(200, history_page("101", vec![labels_removed("m2", &["CATEGORY_UPDATES"], &["INBOX"])]));
        w.set_threads_unread(Some(7));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the archive cycle").await;

    assert_eq!(snap.state, SourceState::Fresh);
    assert_eq!(ids(&snap), vec!["m3", "m1"]);
}

#[tokio::test]
async fn history_adding_a_message_to_the_inbox_fetches_its_metadata_and_adds_it() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 2);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        let mut w = e.world();
        let fresh = gmail_msg("m4", "t4", &["INBOX", "UNREAD"], "Newcomer <new@example.com>", "Hello there", Utc::now());
        w.messages.insert("m4".into(), fresh);
        // A sent message and one that is gone again by the time we look.
        w.queue_history(
            200,
            history_page(
                "101",
                vec![json!({ "messagesAdded": [
                    { "message": stub("m4", &["INBOX", "UNREAD"]) },
                    { "message": stub("sent1", &["SENT"]) },
                    { "message": stub("gone", &["INBOX", "UNREAD"]) },
                ]})],
            ),
        );
        w.set_threads_unread(Some(3));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the new-mail cycle").await;

    assert_eq!(snap.state, SourceState::Fresh, "a message that vanished again is not a failure");
    assert_eq!(ids(&snap), vec!["m4", "m3", "m1", "m2"], "the newcomer is unread and newest");
    assert_eq!(item(&snap, "m4").subject, "Hello there");
    assert_eq!(snap.unread_count, 3, "a new unread message forces a fresh count");
    let fetched: Vec<String> = e.world().message_hits().iter().map(|h| h.path.clone()).collect();
    assert!(
        !fetched.iter().any(|p| p.ends_with("/sent1")),
        "a message that never entered the inbox is not fetched: {fetched:?}"
    );
}

#[tokio::test]
async fn history_deleting_a_message_removes_it() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        let mut w = e.world();
        w.queue_history(
            200,
            history_page("101", vec![json!({ "messagesDeleted": [{ "message": stub("m3", &["INBOX", "UNREAD"]) }] })]),
        );
        w.set_threads_unread(Some(6));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the delete cycle").await;

    assert_eq!(ids(&snap), vec!["m1", "m2"]);
    assert_eq!(snap.unread_count, 6);
}

#[tokio::test]
async fn the_history_cursor_advances_and_pages_are_followed() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        let mut w = e.world();
        // Two pages: the first archives m1, the second archives m2.
        let mut first = history_page("150", vec![labels_removed("m1", &["CATEGORY_PERSONAL"], &["INBOX"])]);
        first["nextPageToken"] = json!("page-2");
        w.queue_history(200, first);
        w.queue_history(200, history_page("160", vec![labels_removed("m2", &[], &["INBOX"])]));
        w.history_head = "160".into();
        w.set_threads_unread(Some(6));
    }

    let snap = next_snapshot(&mut rx, &dirty, "the two-page cycle").await;
    assert_eq!(ids(&snap), vec!["m3"], "both pages were applied");
    let _ = next_snapshot(&mut rx, &dirty, "the following cycle").await;

    let w = e.world();
    let history = w.hits_on(HISTORY);
    let starts: Vec<&str> = history.iter().map(|h| h.param("startHistoryId").unwrap()).collect();
    assert_eq!(starts, vec!["100", "100", "160"], "starts at the profile's id; the next cycle starts from the last page's id");
    assert_eq!(history[1].param("pageToken"), Some("page-2"), "the second call follows nextPageToken");
}

#[tokio::test]
async fn history_404_resyncs_in_the_same_cycle_and_never_publishes_an_error() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        // Gmail no longer has our history point; the inbox meanwhile changed.
        let mut w = e.world();
        w.queue_history(404, json!({ "error": { "code": 404, "message": "Requested entity was not found.", "status": "NOT_FOUND" } }));
        let mut inbox = standard_inbox();
        inbox.push(gmail_msg("m9", "t9", &["INBOX", "UNREAD"], "Late <late@example.com>", "Catch up", Utc::now()));
        w.set_inbox(&inbox, 8);
        w.profile = json!({ "emailAddress": EMAIL, "historyId": "300" });
        w.history_head = "300".into();
    }

    let snap = next_snapshot(&mut rx, &dirty, "the resync cycle").await;

    assert_eq!(snap.state, SourceState::Fresh, "an expired history point is a resync, not a failure: {snap:?}");
    assert!(snap.error.is_none() && !snap.stale);
    assert_eq!(ids(&snap), vec!["m9", "m3", "m1", "m2"]);
    assert_eq!(snap.unread_count, 8);
    assert_eq!(e.world().count(PROFILE), 2, "a new full sync (profile again) happened in that one cycle");

    // The new history point is the new profile's.
    let _ = next_snapshot(&mut rx, &dirty, "the cycle after the resync").await;
    let w = e.world();
    let starts: Vec<String> = w.hits_on(HISTORY).iter().map(|h| h.param("startHistoryId").unwrap().to_owned()).collect();
    assert_eq!(starts, vec!["100", "300"]);
}

// ═════════════════════════════════════════════════════════════════════════════
// Mailbox: truthfulness
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_history_page_without_a_history_id_is_stale_with_the_old_data_never_fresh_or_zero() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    e.world().queue_history(200, json!({ "history": [] })); // no historyId: not "no changes"

    let snap = next_snapshot(&mut rx, &dirty, "the malformed-history cycle").await;

    assert_eq!(snap.state, SourceState::Stale, "{snap:?}");
    assert!(snap.stale && snap.error.is_some());
    assert_eq!(snap.unread_count, 7, "the last good count, never 0");
    assert_eq!(ids(&snap), vec!["m3", "m1", "m2"], "the last good rows are kept");
    assert!(snap.updated_at.is_some(), "updated_at is the last SUCCESSFUL fetch");

    // It recovers on the next good answer, from the same history point.
    let healed = next_snapshot(&mut rx, &dirty, "the recovery cycle").await;
    assert_eq!(healed.state, SourceState::Fresh);
    let w = e.world();
    let starts: Vec<String> =
        w.hits_on(HISTORY).iter().map(|h| h.param("startHistoryId").unwrap().to_owned()).collect();
    assert_eq!(starts, vec!["100", "100"], "an unusable page does not move the cursor");
}

#[tokio::test]
async fn an_inbox_label_without_threads_unread_is_an_error_without_data_and_never_zero_unread() {
    let e = env(true, &[]).await;
    {
        let mut w = e.world();
        w.set_inbox(&standard_inbox(), 7);
        w.set_threads_unread(None);
    }
    let (mut rx, dirty) = spawn_mailbox(&e, manual());

    let snap = wait_for(&mut rx, "the first snapshot", &[SourceState::Fresh, SourceState::Empty], |_| true).await;

    assert_eq!(snap.state, SourceState::Error, "{snap:?}");
    assert!(snap.items.is_empty(), "nothing is presented as the inbox when the count is unknown");
    assert!(snap.error.is_some());

    // The label heals: the count is real again and the rows appear.
    e.world().set_threads_unread(Some(7));
    let healed = next_snapshot(&mut rx, &dirty, "the recovery cycle").await;
    assert_eq!(healed.state, SourceState::Fresh);
    assert_eq!(healed.unread_count, 7);
    assert_eq!(healed.items.len(), 3);
}

#[tokio::test]
async fn an_inbox_label_without_threads_unread_after_a_good_sync_is_stale_with_the_last_count() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, manual());
    first_fresh_mailbox(&mut rx).await;
    {
        // A read-state change forces a label fetch, and the label comes back broken.
        let mut w = e.world();
        w.queue_history(200, history_page("101", vec![labels_removed("m1", &["INBOX"], &["UNREAD"])]));
        w.history_head = "101".into();
        w.set_threads_unread(None);
    }

    let snap = next_snapshot(&mut rx, &dirty, "the broken-label cycle").await;

    assert_eq!(snap.state, SourceState::Stale, "{snap:?}");
    assert_eq!(snap.unread_count, 7, "the last known count, not 0 and not a recount of rows");
    assert!(snap.error.is_some());

    e.world().set_threads_unread(Some(6));
    let healed = next_snapshot(&mut rx, &dirty, "the recovery cycle").await;
    assert_eq!(healed.state, SourceState::Fresh);
    assert_eq!(healed.unread_count, 6, "the pending count refresh was not forgotten");
}

#[tokio::test]
async fn a_server_error_is_an_error_without_data_and_stale_with_data() {
    let e = env(true, &[]).await;
    e.world().failure = Some((503, None));
    let (mut rx, dirty) = spawn_mailbox(&e, manual());

    let first = wait_for(&mut rx, "the first snapshot", &[SourceState::Fresh, SourceState::Empty], |_| true).await;
    assert_eq!(first.state, SourceState::Error);
    assert!(first.error.as_deref().unwrap().contains("unavailable"), "plain English: {:?}", first.error);

    {
        let mut w = e.world();
        w.heal();
        w.set_inbox(&standard_inbox(), 7);
    }
    let fresh = next_snapshot(&mut rx, &dirty, "the recovery cycle").await;
    assert_eq!(fresh.state, SourceState::Fresh);

    e.world().failure = Some((500, None));
    let stale = next_snapshot(&mut rx, &dirty, "the failing cycle").await;
    assert_eq!(stale.state, SourceState::Stale);
    assert_eq!(stale.unread_count, 7);
    assert_eq!(stale.items.len(), 3);
}

// ── Throttling ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_429_is_rate_limited_keeps_the_data_and_the_source_stays_silent_for_retry_after() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, dirty) = spawn_mailbox(&e, timing(fast(), an_hour()));
    first_fresh_mailbox(&mut rx).await;

    let t_set = Utc::now();
    e.world().failure = Some((429, Some(3)));
    let limited = wait_for(&mut rx, "a rate-limited snapshot", &[], |s| s.state == SourceState::RateLimited).await;

    assert!(limited.stale, "the data on show is the previous good data, flagged");
    assert_eq!(limited.unread_count, 7, "never 0 while throttled");
    assert_eq!(limited.items.len(), 3);
    assert!(limited.error.as_deref().unwrap().contains("rate limiting"), "{:?}", limited.error);
    let retry_at = limited.retry_at.expect("retry_at");
    assert!(
        retry_at >= t_set + ChronoDuration::milliseconds(2950),
        "Retry-After (3 s) wins over the 2 s first backoff step: {retry_at} vs {t_set}"
    );
    assert!(retry_at < t_set + ChronoDuration::seconds(15), "retry_at is a few seconds out, not minutes");

    // From here on the server is fine again, but the quiet period must hold
    // even though dirty signals keep arriving.
    let failing_hit = e.world().hits.iter().position(|h| h.failed).expect("one request was throttled");
    e.world().heal();
    for _ in 0..3 {
        dirty.send(()).unwrap();
    }
    e.wait_until("a request after the quiet period", |w| w.hits.len() > failing_hit + 1).await;
    {
        let w = e.world();
        let gap = w.hits[failing_hit + 1].at.duration_since(w.hits[failing_hit].at);
        assert!(gap >= Duration::from_secs(3), "no request reached Google for Retry-After; the next came after {gap:?}");
        assert_eq!(w.hits.iter().filter(|h| h.failed).count(), 1, "the throttled cycle stopped at its first request");
    }

    let healed = wait_for(&mut rx, "fresh again", &[], |s| s.state == SourceState::Fresh).await;
    assert_eq!(healed.unread_count, 7);
}

#[tokio::test]
async fn consecutive_throttles_back_off_exponentially() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, _dirty) = spawn_mailbox(&e, timing(fast(), an_hour()));
    first_fresh_mailbox(&mut rx).await;

    e.world().failure = Some((429, None)); // no Retry-After: the source decides
    e.wait_until("three throttled requests", |w| w.hits.iter().filter(|h| h.failed).count() >= 3).await;

    let w = e.world();
    let failed: Vec<&Hit> = w.hits.iter().filter(|h| h.failed).collect();
    let first_failed = w.hits.iter().position(|h| h.failed).unwrap();
    assert!(
        w.hits[first_failed..].iter().all(|h| h.failed),
        "once throttled the source sends nothing but the retries after each wait"
    );
    let gap1 = failed[1].at.duration_since(failed[0].at);
    let gap2 = failed[2].at.duration_since(failed[1].at);
    assert!(gap1 >= Duration::from_secs(2), "first step is 2 s, was {gap1:?}");
    assert!(gap2 >= Duration::from_secs(4), "second step is 4 s, was {gap2:?}");
    assert!(gap2 > gap1);
}

#[tokio::test]
async fn a_success_resets_the_backoff() {
    let e = env(true, &[]).await;
    e.world().set_inbox(&standard_inbox(), 7);
    let (mut rx, _dirty) = spawn_mailbox(&e, timing(fast(), an_hour()));
    first_fresh_mailbox(&mut rx).await;

    // Throttled once (2 s step) ...
    e.world().failure = Some((429, None));
    wait_for(&mut rx, "first rate-limited snapshot", &[], |s| s.state == SourceState::RateLimited).await;
    // ... then it recovers ...
    e.world().heal();
    wait_for(&mut rx, "recovery", &[], |s| s.state == SourceState::Fresh).await;
    // ... and the next throttle starts again at the first step, not the second.
    let t_set = Utc::now();
    e.world().failure = Some((429, None));
    let again = wait_for(&mut rx, "second rate-limited snapshot", &[], |s| s.state == SourceState::RateLimited).await;

    let wait = again.retry_at.unwrap() - t_set;
    assert!(wait >= ChronoDuration::seconds(2), "at least the first step: {wait}");
    assert!(
        wait < ChronoDuration::milliseconds(3500),
        "after a success the wait is 2 s (+ up to 25% jitter), not the 4 s of a second consecutive throttle: {wait}"
    );
}

// ── Sign-in ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn signed_out_mailbox_and_calendar_of_one_account_show_the_same_sign_in() {
    let e = env(false, &[]).await;
    let (mut mail_rx, _m) = spawn_mailbox(&e, timing(fast(), an_hour()));
    let (mut cal_rx, _c) = spawn_calendar(&e, timing(fast(), an_hour()));

    let mail = wait_for(&mut mail_rx, "mailbox sign-in", &[SourceState::Fresh, SourceState::Empty], |s| {
        s.state == SourceState::Unauthenticated
    })
    .await;
    let cal = wait_for(&mut cal_rx, "calendar sign-in", &[SourceState::Fresh, SourceState::Empty], |s| {
        s.state == SourceState::Unauthenticated
    })
    .await;

    for prompt in [mail.auth_prompt.as_ref().unwrap(), cal.auth_prompt.as_ref().unwrap()] {
        assert_eq!(prompt.kind, "browser");
        assert_eq!(prompt.account.as_deref(), Some(LABEL));
        assert_eq!(prompt.provider.as_deref(), Some("google"));
        assert!(prompt.expires_at > Utc::now());
    }
    let (mp, cp) = (mail.auth_prompt.as_ref().unwrap(), cal.auth_prompt.as_ref().unwrap());
    assert_eq!(mp.verification_uri, cp.verification_uri, "one account, one sign-in link");
    assert_eq!(prompt_params(mp)["state"], prompt_params(cp)["state"]);
    assert!(mail.items.is_empty() && mail.unread_count == 0, "no mail is claimed while signed out");
    assert!(cal.events.is_empty());
    assert!(mail.error.is_some() && cal.error.is_some(), "a plain-English reason is given");
    assert!(
        e.world().hits.is_empty(),
        "nothing is asked of Gmail or Calendar before there is a token"
    );
}

#[tokio::test]
async fn completing_the_browser_sign_in_brings_both_sources_back() {
    let e = env(false, &[]).await;
    Mock::given(method("POST"))
        .and(path(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "at-new", "refresh_token": "rt-new", "expires_in": 3600
        })))
        .mount(&e.server)
        .await;
    {
        let mut w = e.world();
        w.set_inbox(&standard_inbox(), 7);
        let start = Utc::now() + ChronoDuration::minutes(30);
        w.calendar_pages.insert(
            String::new(),
            json!({ "items": [timed_event("e1", "Planning", start, start + ChronoDuration::hours(1))] }),
        );
    }
    let (mut mail_rx, _m) = spawn_mailbox(&e, timing(fast(), an_hour()));
    let (mut cal_rx, _c) = spawn_calendar(&e, timing(fast(), an_hour()));
    let mail = wait_for(&mut mail_rx, "mailbox sign-in", &[], |s| s.state == SourceState::Unauthenticated).await;
    wait_for(&mut cal_rx, "calendar sign-in", &[], |s| s.state == SourceState::Unauthenticated).await;
    let params = prompt_params(mail.auth_prompt.as_ref().unwrap());

    let resp = browser_get(&params["redirect_uri"], &[("code", "abc"), ("state", &params["state"])]).await;
    assert!(resp.status().is_success());

    let mail = wait_for(&mut mail_rx, "mailbox fresh", &[], |s| s.state == SourceState::Fresh).await;
    assert_eq!(mail.unread_count, 7);
    assert!(mail.auth_prompt.is_none());
    let cal = wait_for(&mut cal_rx, "calendar fresh", &[], |s| s.state == SourceState::Fresh).await;
    assert_eq!(cal.events.len(), 1);
    assert!(cal.auth_prompt.is_none());
    assert!(e.token_path().exists(), "the token was stored for next time");
    assert!(
        e.world().hits.iter().any(|h| h.bearer == "at-new"),
        "requests now carry the new token"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Calendar
// ═════════════════════════════════════════════════════════════════════════════

fn rfc(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn timed_event(id: &str, summary: &str, start: DateTime<Utc>, end: DateTime<Utc>) -> Value {
    json!({
        "id": id,
        "summary": summary,
        "status": "confirmed",
        "start": { "dateTime": rfc(start) },
        "end": { "dateTime": rfc(end) },
    })
}

fn with(mut event: Value, key: &str, value: Value) -> Value {
    event[key] = value;
    event
}

fn set_events(e: &Env, events: Vec<Value>) {
    e.world().calendar_pages.insert(String::new(), json!({ "items": events }));
}

fn event<'a>(s: &'a CalendarSnapshot, id: &str) -> &'a CalendarEvent {
    s.events
        .iter()
        .find(|ev| ev.id == id)
        .unwrap_or_else(|| panic!("no event {id} in {:?}", s.events.iter().map(|e| &e.id).collect::<Vec<_>>()))
}

async fn first_calendar(rx: &mut watch::Receiver<Option<CalendarSnapshot>>, state: SourceState) -> CalendarSnapshot {
    wait_for(rx, "the first calendar snapshot", &[], |s| s.state == state).await
}

fn secs(t: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp(t.timestamp(), 0).unwrap()
}

#[tokio::test]
async fn calendar_events_map_to_the_snapshot_fields() {
    let e = env(true, &[]).await;
    let base = secs(Utc::now());
    let all_day_date: NaiveDate = base.date_naive();
    let in_minus_four = FixedOffset::west_opt(4 * 3600).unwrap();
    let timed_start = base + ChronoDuration::hours(2);
    let me = json!({ "email": EMAIL, "self": true });
    let boss = json!({ "email": "boss@example.com", "displayName": "Boss" });
    let mk_attendee = |status: &str| {
        let mut mine = me.clone();
        mine["responseStatus"] = json!(status);
        json!([boss.clone(), mine])
    };
    let range = |from_min: i64, to_min: i64| {
        (base + ChronoDuration::minutes(from_min), base + ChronoDuration::minutes(to_min))
    };
    let (s, en) = range(30, 60);
    let events = vec![
        // A timed event written with a UTC offset.
        json!({
            "id": "offset", "summary": "Offset event", "status": "confirmed",
            "start": { "dateTime": timed_start.with_timezone(&in_minus_four).to_rfc3339_opts(SecondsFormat::Secs, false), "timeZone": "America/New_York" },
            "end": { "dateTime": (timed_start + ChronoDuration::hours(1)).with_timezone(&in_minus_four).to_rfc3339_opts(SecondsFormat::Secs, false) },
        }),
        // An all-day event uses `date`, not `dateTime`.
        json!({
            "id": "allday", "summary": "Company holiday", "status": "confirmed",
            "start": { "date": all_day_date.to_string() },
            "end": { "date": all_day_date.succ_opt().unwrap().to_string() },
        }),
        // Working-location markers are not meetings.
        with(timed_event("workloc", "Home", s, en), "eventType", json!("workingLocation")),
        with(timed_event("cancelled", "Called off", s, en), "status", json!("cancelled")),
        {
            let mut ev = timed_event("tentative", "Maybe", s, en);
            ev["organizer"] = boss.clone();
            ev["attendees"] = mk_attendee("tentative");
            ev
        },
        {
            let mut ev = timed_event("accepted", "Yes", s, en);
            ev["attendees"] = mk_attendee("accepted");
            ev
        },
        {
            let mut ev = timed_event("declined", "No", s, en);
            ev["attendees"] = mk_attendee("declined");
            ev
        },
        {
            let mut ev = timed_event("needs", "Unanswered", s, en);
            ev["attendees"] = mk_attendee("needsAction");
            ev
        },
        // No attendees at all: the user's own event.
        timed_event("solo", "Focus time", s, en),
        {
            let mut ev = timed_event("hangout", "Standup", s, en);
            ev["hangoutLink"] = json!("https://meet.google.com/abc-defg-hij");
            ev["htmlLink"] = json!("https://www.google.com/calendar/event?eid=abc");
            ev["location"] = json!("Room 4");
            ev
        },
        {
            let mut ev = timed_event("conference", "Review", s, en);
            ev["conferenceData"] = json!({ "entryPoints": [
                { "entryPointType": "phone", "uri": "tel:+15551234567" },
                { "entryPointType": "video", "uri": "https://zoom.example.com/j/123" },
            ]});
            ev
        },
        {
            let mut ev = timed_event("inprogress", "Already started", base - ChronoDuration::minutes(10), base + ChronoDuration::minutes(20));
            ev["attendees"] = mk_attendee("accepted");
            ev
        },
    ];
    set_events(&e, events);
    let (mut rx, _dirty) = spawn_calendar(&e, manual());

    let snap = first_calendar(&mut rx, SourceState::Fresh).await;

    assert!(snap.updated_at.is_some() && snap.error.is_none() && !snap.stale);
    assert!(snap.events.iter().all(|ev| ev.id != "workloc"), "working-location events are dropped");
    let starts: Vec<_> = snap.events.iter().filter_map(|ev| ev.start).collect();
    assert!(starts.windows(2).all(|w| w[0] <= w[1]), "events are in start order: {starts:?}");

    let offset = event(&snap, "offset");
    assert_eq!(offset.start, Some(timed_start), "an offset time is converted to the same UTC instant");
    assert_eq!(offset.end, Some(timed_start + ChronoDuration::hours(1)));
    assert!(!offset.is_all_day);
    assert_eq!(offset.title, "Offset event");

    let allday = event(&snap, "allday");
    assert!(allday.is_all_day);
    assert_eq!(allday.start, Some(all_day_date.and_hms_opt(0, 0, 0).unwrap().and_utc()), "all-day is midnight UTC of that date");
    assert!(!allday.is_now, "an all-day event is never 'now'");

    let cancelled = event(&snap, "cancelled");
    assert_eq!(cancelled.status, "cancelled");
    assert!(cancelled.is_cancelled);

    let tentative = event(&snap, "tentative");
    assert_eq!(tentative.status, "tentativelyAccepted");
    assert_eq!(tentative.response_status, "tentativelyAccepted");
    assert_eq!(tentative.organizer.as_deref(), Some("Boss"));
    assert_eq!(event(&snap, "accepted").status, "accepted");
    assert_eq!(event(&snap, "declined").status, "declined");
    assert_eq!(event(&snap, "needs").status, "notResponded");
    assert_eq!(event(&snap, "solo").status, "organizer", "no attendees: it is the user's own event");
    assert!(!event(&snap, "solo").is_cancelled);

    let hangout = event(&snap, "hangout");
    assert_eq!(hangout.online_meeting_url.as_deref(), Some("https://meet.google.com/abc-defg-hij"));
    assert_eq!(hangout.web_link.as_deref(), Some("https://www.google.com/calendar/event?eid=abc"));
    assert_eq!(hangout.location.as_deref(), Some("Room 4"));
    assert_eq!(
        event(&snap, "conference").online_meeting_url.as_deref(),
        Some("https://zoom.example.com/j/123"),
        "the video entry point, not the phone one"
    );
    assert!(event(&snap, "solo").online_meeting_url.is_none());

    assert!(event(&snap, "inprogress").is_now);
    assert!(!event(&snap, "solo").is_now, "an event that has not started is not now");
}

#[tokio::test]
async fn an_event_starting_in_ten_minutes_is_next_and_turns_the_sweater_amber() {
    let e = env(true, &[]).await;
    let start = Utc::now() + ChronoDuration::minutes(10);
    set_events(
        &e,
        vec![
            timed_event("later", "Later meeting", start + ChronoDuration::hours(3), start + ChronoDuration::hours(4)),
            timed_event("soon", "Soon meeting", start, start + ChronoDuration::minutes(30)),
        ],
    );
    let (mut rx, _dirty) = spawn_calendar(&e, manual());

    let snap = first_calendar(&mut rx, SourceState::Fresh).await;

    let next = snap.next.as_ref().expect("a next event");
    assert_eq!(next.title, "Soon meeting");
    assert!((8..=10).contains(&next.in_minutes), "about ten minutes away: {}", next.in_minutes);
    assert_eq!(snap.sweater, "amber");
}

#[tokio::test]
async fn next_skips_cancelled_declined_and_all_day_events() {
    let e = env(true, &[]).await;
    let now = Utc::now();
    let me_declined = json!([{ "email": EMAIL, "self": true, "responseStatus": "declined" }, { "email": "o@example.com" }]);
    let soon = |id: &str, mins: i64| {
        timed_event(id, id, now + ChronoDuration::minutes(mins), now + ChronoDuration::minutes(mins + 30))
    };
    set_events(
        &e,
        vec![
            with(soon("cancelled", 5), "status", json!("cancelled")),
            with(soon("declined", 6), "attendees", me_declined),
            json!({ "id": "allday", "summary": "allday", "start": { "date": now.date_naive().to_string() },
                    "end": { "date": now.date_naive().succ_opt().unwrap().to_string() } }),
            soon("real", 40),
        ],
    );
    let (mut rx, _dirty) = spawn_calendar(&e, manual());

    let snap = first_calendar(&mut rx, SourceState::Fresh).await;

    assert_eq!(snap.next.as_ref().expect("next").title, "real");
    assert_eq!(snap.sweater, "sage", "40 minutes out is calm");
}

#[tokio::test]
async fn a_day_with_no_events_is_empty_with_a_calm_sweater() {
    let e = env(true, &[]).await;
    set_events(&e, vec![]);
    let (mut rx, _dirty) = spawn_calendar(&e, manual());

    let snap = first_calendar(&mut rx, SourceState::Empty).await;

    assert!(snap.events.is_empty() && snap.next.is_none());
    assert_eq!(snap.sweater, "sage");
    assert!(snap.error.is_none());
}

#[tokio::test]
async fn the_calendar_asks_for_todays_window_in_the_configured_zone_with_recurrences_expanded() {
    let e = env(true, &[]).await;
    set_events(&e, vec![]);
    let t0 = Utc::now();
    let (mut rx, _dirty) = spawn_calendar(&e, manual());
    first_calendar(&mut rx, SourceState::Empty).await;

    let w = e.world();
    let hits = w.hits_on(EVENTS);
    assert_eq!(hits.len(), 1);
    let h = &hits[0];
    assert_eq!(h.method, "GET");
    assert_eq!(h.bearer, SEEDED_ACCESS_TOKEN);
    assert_eq!(h.param("singleEvents"), Some("true"), "recurring events are expanded into instances");
    let min = DateTime::parse_from_rfc3339(h.param("timeMin").expect("timeMin")).unwrap().with_timezone(&Utc);
    let max = DateTime::parse_from_rfc3339(h.param("timeMax").expect("timeMax")).unwrap().with_timezone(&Utc);
    assert_eq!(max - min, ChronoDuration::hours(24), "one calendar day");
    // The pinned zone is at 12:00 right now, so its midnight was 12 hours ago.
    let expected_min = t0 - ChronoDuration::hours(12);
    assert!(
        (min - expected_min).num_seconds().abs() <= 3,
        "the window starts at local midnight of the configured offset: {min} vs {expected_min}"
    );
}

#[tokio::test]
async fn calendar_pages_are_followed_until_the_last() {
    let e = env(true, &[]).await;
    let start = Utc::now() + ChronoDuration::hours(1);
    {
        let mut w = e.world();
        w.calendar_pages.insert(
            String::new(),
            json!({
                "items": [timed_event("p1", "On page one", start, start + ChronoDuration::minutes(30))],
                "nextPageToken": "next-page",
            }),
        );
        w.calendar_pages.insert(
            "next-page".into(),
            json!({ "items": [timed_event("p2", "On page two", start + ChronoDuration::hours(1), start + ChronoDuration::hours(2))] }),
        );
    }
    let (mut rx, _dirty) = spawn_calendar(&e, manual());

    let snap = first_calendar(&mut rx, SourceState::Fresh).await;

    let got: Vec<&str> = snap.events.iter().map(|ev| ev.id.as_str()).collect();
    assert_eq!(got, vec!["p1", "p2"]);
}

#[tokio::test]
async fn a_calendar_page_without_items_is_an_error_not_an_empty_day() {
    let e = env(true, &[]).await;
    e.world().calendar_pages.insert(String::new(), json!({ "kind": "calendar#events", "summary": "me@example.com" }));
    let (mut rx, dirty) = spawn_calendar(&e, manual());

    let snap = wait_for(&mut rx, "the first snapshot", &[SourceState::Fresh, SourceState::Empty], |_| true).await;

    assert_eq!(snap.state, SourceState::Error, "{snap:?}");
    assert!(snap.events.is_empty() && snap.error.is_some());

    // A real, empty day is a different answer.
    set_events(&e, vec![]);
    let empty = next_snapshot(&mut rx, &dirty, "the recovery cycle").await;
    assert_eq!(empty.state, SourceState::Empty);
}

#[tokio::test]
async fn a_calendar_page_without_items_after_a_good_fetch_is_stale_with_the_last_events() {
    let e = env(true, &[]).await;
    let start = Utc::now() + ChronoDuration::minutes(45);
    set_events(&e, vec![timed_event("keep", "Keep showing me", start, start + ChronoDuration::hours(1))]);
    let (mut rx, dirty) = spawn_calendar(&e, manual());
    first_calendar(&mut rx, SourceState::Fresh).await;
    e.world().calendar_pages.insert(String::new(), json!({ "kind": "calendar#events" }));

    let snap = next_snapshot(&mut rx, &dirty, "the malformed cycle").await;

    assert_eq!(snap.state, SourceState::Stale, "{snap:?}");
    assert_eq!(snap.events.len(), 1, "the last good events stay on screen");
    assert_eq!(snap.events[0].id, "keep");
    assert!(snap.stale && snap.error.is_some());
    assert!(snap.next.is_some(), "and so does the next meeting");
}

#[tokio::test]
async fn a_calendar_429_is_rate_limited_and_keeps_the_events() {
    let e = env(true, &[]).await;
    let start = Utc::now() + ChronoDuration::minutes(45);
    set_events(&e, vec![timed_event("keep", "Keep showing me", start, start + ChronoDuration::hours(1))]);
    let (mut rx, dirty) = spawn_calendar(&e, manual());
    first_calendar(&mut rx, SourceState::Fresh).await;
    let t_set = Utc::now();
    e.world().failure = Some((429, Some(1)));

    let snap = next_snapshot(&mut rx, &dirty, "the throttled cycle").await;

    assert_eq!(snap.state, SourceState::RateLimited, "{snap:?}");
    assert_eq!(snap.events.len(), 1);
    assert!(snap.retry_at.unwrap() >= t_set + ChronoDuration::milliseconds(950));
    assert!(snap.error.as_deref().unwrap().contains("rate limiting"));
}
