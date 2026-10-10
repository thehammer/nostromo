//! Fred's mail + calendar sources under throttling and half-failed fetches.
//!
//! Invariant (user-approved): a failed, stale, throttled or unauthenticated
//! fetch must NEVER be shown as "0 unread" or "No meetings today".
//!
//! What this file pins down, for BOTH the mailbox and the calendar loop:
//!  * a request that fails after a 401 -> token refresh -> retry is handled
//!    exactly like one that failed first time (stale / rate_limited, data kept);
//!  * a 200 whose body is a Graph error object, or an Inbox folder body with no
//!    `unreadItemCount`, is an error rather than an empty / zero result;
//!  * 429 (and 503 with Retry-After) => `rate_limited` with `retry_at`, previous
//!    data kept, and a quiet period during which NO Graph request of any kind
//!    is sent (the dirty-file signal does not cut it short); `Retry-After`
//!    (seconds or HTTP-date) wins, otherwise exponential backoff 2, 4, 8 ...
//!    with <= 25% jitter, capped at 15 minutes; a success resets everything.
//!
//! Timing technique. Paused tokio time is NOT used: wiremock serves over real
//! sockets, and under a paused clock the runtime auto-advances while a real
//! response is still in flight (the same race documented in
//! `perri_pr_native.rs`), which would race production timers and the tests' own
//! timeouts. Instead the mock stamps every request it serves with a monotonic
//! `Instant` (and a wall-clock time), and the tests only assert
//!   * LOWER bounds on gaps between requests - these cannot flake, the source
//!     can only be slower than its wait, never faster; and
//!   * UPPER bounds that are deliberately generous (>= 1 s of slack).
//!
//! Waits are 2-8 s, so the timing tests cost a few real seconds each.

use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, Timelike, Utc};
use nostromo::config::Config;
use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_calendar_native::FredCalendarNativeSource;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::fred_mailbox_native::{FredMailboxNativeSource, FredTiming};
use nostromo::data::graph_client::{GraphClient, GraphOptions};
use nostromo::data::work::model::SourceState;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::watch;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

/// Generous bound for anything that happens at the speed of loopback HTTP.
const WAIT: Duration = Duration::from_secs(20);
/// Bound for "the source must have reacted to the failure by now".
const REACT: Duration = Duration::from_secs(5);

const DELTA: &str = "/me/mailFolders/inbox/messages/delta";
const FOLDER: &str = "/me/mailFolders/inbox";
const CALENDAR_VIEW: &str = "/me/calendarView";
const TOKEN: &str = "/common/oauth2/v2.0/token";

/// The token the client starts with, and the one the refresh endpoint issues.
const OLD_AT: &str = "fake-at";
const NEW_AT: &str = "refreshed-at";
const REFRESH_TOKEN: &str = "fake-rt";

const UNREAD: u64 = 42;

// ═════════════════════════════════════════════════════════════════════════════
// Mock "Microsoft"
// ═════════════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
enum RetryAfter {
    Seconds(u64),
    /// An HTTP-date this many seconds after the moment the response is built.
    DateIn(i64),
}

#[derive(Clone, Debug)]
struct Failure {
    status: u16,
    retry_after: Option<RetryAfter>,
    body: Value,
}

fn graph_error_body() -> Value {
    json!({ "error": { "code": "SomethingWentWrong", "message": "Please slow down and try later" } })
}

impl Failure {
    fn throttled(retry_after: Option<RetryAfter>) -> Self {
        Self { status: 429, retry_after, body: graph_error_body() }
    }
    fn unavailable(retry_after: Option<RetryAfter>) -> Self {
        Self { status: 503, retry_after, body: graph_error_body() }
    }
    fn forbidden() -> Self {
        Self { status: 403, retry_after: None, body: graph_error_body() }
    }
    /// HTTP 200 carrying a Graph error object instead of a page.
    fn ok_error_object() -> Self {
        Self { status: 200, retry_after: None, body: graph_error_body() }
    }
    /// HTTP 200 with an arbitrary (wrong) body.
    fn ok_body(body: Value) -> Self {
        Self { status: 200, retry_after: None, body }
    }
}

/// One request the mock served on a Graph path.
#[derive(Clone, Debug)]
struct Hit {
    at: Instant,
    utc: DateTime<Utc>,
    path: &'static str,
    /// The status the mock answered with (401 for a rejected old token).
    status: u16,
    /// The HTTP-date it sent in Retry-After, when it sent one.
    sent_date: Option<DateTime<Utc>>,
}

impl Hit {
    fn is_failure(&self) -> bool {
        !matches!(self.status, 200 | 401)
    }
}

#[derive(Default)]
struct Shared {
    hits: Mutex<Vec<Hit>>,
    failure: Mutex<Option<(Failure, Vec<&'static str>)>>,
    reject_old: Mutex<Vec<&'static str>>,
    refreshes: AtomicUsize,
}

impl Shared {
    /// From now on, successful answers on `paths` become `failure`.
    fn fail(&self, failure: Failure, paths: &[&'static str]) {
        *self.failure.lock().unwrap() = Some((failure, paths.to_vec()));
    }
    fn heal(&self) {
        *self.failure.lock().unwrap() = None;
    }
    /// From now on, the ORIGINAL token is rejected with a 401 on `paths`
    /// (so the client must refresh and retry).
    fn reject_old_on(&self, paths: &[&'static str]) {
        *self.reject_old.lock().unwrap() = paths.to_vec();
    }
    fn hits(&self) -> Vec<Hit> {
        self.hits.lock().unwrap().clone()
    }
    fn failure_hits(&self) -> Vec<Hit> {
        self.hits().into_iter().filter(Hit::is_failure).collect()
    }
    fn failure_for(&self, p: &str) -> Option<Failure> {
        self.failure
            .lock()
            .unwrap()
            .as_ref()
            .filter(|(_, paths)| paths.contains(&p))
            .map(|(f, _)| f.clone())
    }
    fn rejects_old(&self, p: &str) -> bool {
        self.reject_old.lock().unwrap().contains(&p)
    }
    fn record(&self, path: &'static str, status: u16, sent_date: Option<DateTime<Utc>>) {
        self.hits.lock().unwrap().push(Hit {
            at: Instant::now(),
            utc: Utc::now(),
            path,
            status,
            sent_date,
        });
    }
}

fn failure_template(f: &Failure) -> (ResponseTemplate, Option<DateTime<Utc>>) {
    let mut t = ResponseTemplate::new(f.status).set_body_json(f.body.clone());
    let mut sent = None;
    match &f.retry_after {
        None => {}
        Some(RetryAfter::Seconds(n)) => t = t.insert_header("Retry-After", n.to_string().as_str()),
        Some(RetryAfter::DateIn(n)) => {
            let at = Utc::now() + ChronoDuration::seconds(*n);
            let date = DateTime::from_timestamp(at.timestamp(), 0).unwrap();
            t = t.insert_header(
                "Retry-After",
                date.format("%a, %d %b %Y %H:%M:%S GMT").to_string().as_str(),
            );
            sent = Some(date);
        }
    }
    (t, sent)
}

type Handler = Box<dyn Fn(&Request) -> ResponseTemplate + Send + Sync>;

async fn mount_graph(server: &MockServer, sh: &Arc<Shared>, p: &'static str, ok: Handler) {
    let sh = sh.clone();
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(move |req: &Request| {
            let bearer = req
                .headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_owned();
            let (template, status, sent) =
                if bearer == format!("Bearer {OLD_AT}") && sh.rejects_old(p) {
                    (
                        ResponseTemplate::new(401).set_body_json(graph_error_body()),
                        401,
                        None,
                    )
                } else if let Some(f) = sh.failure_for(p) {
                    let (t, sent) = failure_template(&f);
                    (t, f.status, sent)
                } else {
                    (ok(req), 200, None)
                };
            sh.record(p, status, sent);
            template
        })
        .mount(server)
        .await;
}

/// The refresh endpoint always works (the failure under test is Graph's, not
/// the sign-in's).
async fn mount_refresh(server: &MockServer, sh: &Arc<Shared>) {
    let sh = sh.clone();
    Mock::given(method("POST"))
        .and(path(TOKEN))
        .respond_with(move |_: &Request| {
            sh.refreshes.fetch_add(1, SeqCst);
            ResponseTemplate::new(200).set_body_json(json!({
                "access_token": NEW_AT,
                "refresh_token": "fake-rt-2",
                "expires_in": 3600,
            }))
        })
        .mount(server)
        .await;
}

// ═════════════════════════════════════════════════════════════════════════════
// Environment
// ═════════════════════════════════════════════════════════════════════════════

struct Env {
    server: MockServer,
    dir: TempDir,
    graph: GraphClient,
    config: Config,
}

async fn env() -> Env {
    let server = MockServer::start().await;
    let dir = TempDir::new().unwrap();
    let token_cache = dir.path().join("graph-token.json");
    let fred_dir = dir.path().join("fred");
    std::fs::create_dir_all(&fred_dir).unwrap();
    std::fs::write(
        &token_cache,
        json!({
            "access_token": OLD_AT,
            "refresh_token": REFRESH_TOKEN,
            "expires_at": (Utc::now() + ChronoDuration::hours(1)).timestamp(),
        })
        .to_string(),
    )
    .unwrap();

    let config = Config {
        graph_client_id: Some("test-client".into()),
        graph_token_cache: Some(token_cache.clone()),
        fred_state: Some(fred_dir),
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
    Env { server, dir, graph, config }
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

// ═════════════════════════════════════════════════════════════════════════════
// Snapshots, subjects (mailbox / calendar) and waiting
// ═════════════════════════════════════════════════════════════════════════════

trait Snap: Clone + std::fmt::Debug + serde::Serialize {
    fn state(&self) -> SourceState;
    fn error(&self) -> Option<&str>;
    fn is_stale(&self) -> bool;
    fn has_auth_prompt(&self) -> bool;
    fn retry_at(&self) -> Option<DateTime<Utc>>;
    fn updated_at(&self) -> Option<DateTime<Utc>>;
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
            fn has_auth_prompt(&self) -> bool {
                self.auth_prompt.is_some()
            }
            fn retry_at(&self) -> Option<DateTime<Utc>> {
                self.retry_at
            }
            fn updated_at(&self) -> Option<DateTime<Utc>> {
                self.updated_at
            }
        }
    };
}
impl_snap!(MailboxSnapshot);
impl_snap!(CalendarSnapshot);

fn assert_honest<S: Snap>(s: &S) {
    match s.state() {
        SourceState::Fresh | SourceState::Empty => assert!(
            s.error().is_none() && !s.is_stale() && !s.has_auth_prompt() && s.retry_at().is_none(),
            "snapshot claims {:?} while reporting a failure / stale data / retry time: {s:?}",
            s.state()
        ),
        SourceState::Stale => assert!(
            s.is_stale() && s.error().is_some() && s.retry_at().is_none(),
            "a Stale snapshot sets `stale`, carries a reason and no retry_at: {s:?}"
        ),
        SourceState::Error => assert!(
            s.error().is_some() && s.retry_at().is_none(),
            "an Error snapshot carries a reason and no retry_at: {s:?}"
        ),
        SourceState::RateLimited => assert!(
            s.error().is_some() && s.retry_at().is_some(),
            "a RateLimited snapshot carries a reason and retry_at: {s:?}"
        ),
        _ => {}
    }
    let json = serde_json::to_string(s).unwrap();
    for secret in [OLD_AT, NEW_AT, REFRESH_TOKEN, "access_token", "refresh_token"] {
        assert!(!json.contains(secret), "snapshot leaks {secret:?}: {json}");
    }
}

trait Subject {
    type S: Snap;
    const NAME: &'static str;
    /// Every Graph path this source reads.
    const ALL: &'static [&'static str];
    /// The path of its main collection (delta page / calendarView).
    const MAIN: &'static [&'static str];
    const DIRTY: &'static str;
    fn timing(poll: Duration) -> FredTiming {
        timing(poll, an_hour())
    }
    fn spawn(e: &Env, t: FredTiming) -> watch::Receiver<Option<Self::S>>;
    fn handlers(base: &str) -> Vec<(&'static str, Handler)>;
    /// What "the previous data" looks like; equal across snapshots that keep it.
    fn fingerprint(s: &Self::S) -> String;
    /// No data at all (no items, count 0).
    fn is_blank(s: &Self::S) -> bool;
}

struct Mailbox;
struct Calendar;

fn mail(id: &str, subject: &str, is_read: bool, received: &str) -> Value {
    json!({
        "id": id,
        "subject": subject,
        "isRead": is_read,
        "receivedDateTime": received,
        "webLink": format!("https://outlook.office.com/mail/{id}"),
        "from": { "emailAddress": { "name": "Alice Smith", "address": "alice@x.com" } },
    })
}

fn standard_window() -> Vec<Value> {
    vec![
        mail("m1", "Quarterly numbers", false, "2026-10-12T14:00:00Z"),
        mail("m2", "FYI notes", true, "2026-10-12T15:00:00Z"),
        mail("m3", "Older unread", false, "2026-10-12T13:00:00Z"),
    ]
}

fn delta_page(base: &str, values: Vec<Value>, token: &str) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({
        "value": values,
        "@odata.deltaLink": format!("{base}{DELTA}?$deltatoken={token}"),
    }))
}

impl Subject for Mailbox {
    type S = MailboxSnapshot;
    const NAME: &'static str = "mailbox";
    const ALL: &'static [&'static str] = &[DELTA, FOLDER];
    const MAIN: &'static [&'static str] = &[DELTA];
    const DIRTY: &'static str = "mailbox.dirty";

    fn spawn(e: &Env, t: FredTiming) -> watch::Receiver<Option<MailboxSnapshot>> {
        FredMailboxNativeSource::spawn_with(e.graph.clone(), e.config.clone(), t)
    }

    fn handlers(base: &str) -> Vec<(&'static str, Handler)> {
        let base = base.to_owned();
        let served = std::sync::atomic::AtomicBool::new(false);
        let delta: Handler = Box::new(move |_: &Request| {
            // First good answer: the window. Later ones: nothing changed.
            if served.swap(true, SeqCst) {
                delta_page(&base, vec![], "d2")
            } else {
                delta_page(&base, standard_window(), "d1")
            }
        });
        let folder: Handler = Box::new(|_: &Request| {
            ResponseTemplate::new(200).set_body_json(json!({ "unreadItemCount": UNREAD }))
        });
        vec![(DELTA, delta), (FOLDER, folder)]
    }

    fn fingerprint(s: &MailboxSnapshot) -> String {
        let ids: Vec<&str> = s.items.iter().map(|i| i.id.as_str()).collect();
        format!("unread={} ids={ids:?}", s.unread_count)
    }

    fn is_blank(s: &MailboxSnapshot) -> bool {
        s.items.is_empty() && s.unread_count == 0
    }
}

fn whole_seconds_now() -> DateTime<Utc> {
    DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap()
}

fn graph_dt(t: DateTime<Utc>) -> Value {
    json!({ "dateTime": t.format("%Y-%m-%dT%H:%M:%S.0000000").to_string(), "timeZone": "UTC" })
}

impl Subject for Calendar {
    type S = CalendarSnapshot;
    const NAME: &'static str = "calendar";
    const ALL: &'static [&'static str] = &[CALENDAR_VIEW];
    const MAIN: &'static [&'static str] = &[CALENDAR_VIEW];
    const DIRTY: &'static str = "calendar.dirty";

    fn spawn(e: &Env, t: FredTiming) -> watch::Receiver<Option<CalendarSnapshot>> {
        FredCalendarNativeSource::spawn_with(e.graph.clone(), e.config.clone(), t)
    }

    fn handlers(_base: &str) -> Vec<(&'static str, Handler)> {
        let now = whole_seconds_now();
        let events = vec![json!({
            "id": "e1",
            "subject": "Eng sync",
            "start": graph_dt(now + ChronoDuration::minutes(60)),
            "end": graph_dt(now + ChronoDuration::minutes(120)),
            "responseStatus": { "response": "accepted" },
            "isCancelled": false,
            "isAllDay": false,
        })];
        let view: Handler = Box::new(move |_: &Request| {
            ResponseTemplate::new(200).set_body_json(json!({ "value": events }))
        });
        vec![(CALENDAR_VIEW, view)]
    }

    fn fingerprint(s: &CalendarSnapshot) -> String {
        let titles: Vec<&str> = s.events.iter().map(|e| e.title.as_str()).collect();
        format!("events={titles:?}")
    }

    fn is_blank(s: &CalendarSnapshot) -> bool {
        s.events.is_empty()
    }
}

/// Checked on every snapshot a test observes. With previous good data
/// (`good` = its fingerprint): a snapshot either keeps exactly that data or has
/// none and then must not pass as healthy. Without any good data: never
/// healthy-looking.
fn guard<X: Subject>(good: Option<String>) -> impl Fn(&X::S) {
    move |s| {
        assert_honest(s);
        let healthy = matches!(s.state(), SourceState::Fresh | SourceState::Empty);
        match &good {
            None => assert!(
                !healthy,
                "{} with no data ever fetched must not look healthy: {s:?}",
                X::NAME
            ),
            Some(_) if X::is_blank(s) => assert!(
                !healthy,
                "{}: a failed fetch shows as an empty/zero {:?} snapshot: {s:?}",
                X::NAME,
                s.state()
            ),
            Some(g) => assert_eq!(
                &X::fingerprint(s),
                g,
                "{}: the previous data must be kept intact, never replaced: {s:?}",
                X::NAME
            ),
        }
    }
}

/// Wait (bounded) for a snapshot satisfying `pred`; `each` is run on every
/// snapshot seen on the way.
async fn wait_for<S: Snap>(
    rx: &mut watch::Receiver<Option<S>>,
    what: &str,
    limit: Duration,
    each: impl Fn(&S),
    pred: impl Fn(&S) -> bool,
) -> S {
    let waited = tokio::time::timeout(limit, async {
        loop {
            let hit = {
                let guard = rx.borrow_and_update();
                guard.as_ref().and_then(|s| {
                    each(s);
                    pred(s).then(|| s.clone())
                })
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
        Err(_) => panic!("timed out after {limit:?} waiting for {what}; last snapshot: {:?}", rx.borrow().clone()),
    }
}

/// Wait for the first non-healthy snapshot after a throttled response and
/// require it to be `rate_limited` (fails fast with the real state otherwise).
async fn wait_rate_limited<X: Subject>(rx: &mut watch::Receiver<Option<X::S>>, each: impl Fn(&X::S)) -> X::S {
    let s = wait_for(rx, "a non-fresh snapshot after the 429", REACT, each, |s| {
        s.state() != SourceState::Fresh
    })
    .await;
    assert_eq!(s.state(), SourceState::RateLimited, "a 429 must read as rate_limited: {s:?}");
    s
}

async fn wait_hits(sh: &Shared, what: &str, limit: Duration, ok: impl Fn(&[Hit]) -> bool) {
    let waited = tokio::time::timeout(limit, async {
        loop {
            if ok(&sh.hits()) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    if waited.is_err() {
        panic!("timed out after {limit:?} waiting for {what}; hits so far: {:?}", sh.hits());
    }
}

fn gap(a: &Hit, b: &Hit) -> f64 {
    b.at.duration_since(a.at).as_secs_f64()
}

struct Rig<S> {
    e: Env,
    sh: Arc<Shared>,
    rx: watch::Receiver<Option<S>>,
}

/// Start the source against the mock. `pre` runs before the first request.
async fn rig<X: Subject>(t: FredTiming, pre: impl FnOnce(&Shared)) -> Rig<X::S> {
    let e = env().await;
    let sh = Arc::new(Shared::default());
    pre(&sh);
    mount_refresh(&e.server, &sh).await;
    for (p, handler) in X::handlers(&e.server.uri()) {
        mount_graph(&e.server, &sh, p, handler).await;
    }
    let rx = X::spawn(&e, t);
    Rig { e, sh, rx }
}

/// A source that has published one good (Fresh) snapshot.
async fn rig_good<X: Subject>(t: FredTiming) -> (Rig<X::S>, X::S) {
    let mut r = rig::<X>(t, |_| {}).await;
    let good = wait_for(&mut r.rx, "a fresh first snapshot", WAIT, assert_honest, |s| {
        s.state() == SourceState::Fresh
    })
    .await;
    assert!(!X::is_blank(&good), "fixture must start with data: {good:?}");
    (r, good)
}

/// Plain English, no URL, no token, no raw body.
fn assert_plain_reason(reason: &str) {
    assert!(!reason.trim().is_empty(), "the reason must not be blank");
    for bad in ["://", "127.0.0.1", "localhost", "/me/", "Bearer", "SomethingWentWrong", "slow down and try"] {
        assert!(!reason.contains(bad), "reason leaks {bad:?}: {reason}");
    }
}

fn assert_retry_at_about(retry_at: DateTime<Utc>, served: DateTime<Utc>, observed: DateTime<Utc>, wait_secs: i64) {
    let lo = served + ChronoDuration::seconds(wait_secs - 2);
    let hi = observed + ChronoDuration::seconds(wait_secs + 2);
    assert!(
        retry_at >= lo && retry_at <= hi,
        "retry_at {retry_at} should be about {wait_secs}s after the throttled response ({served}); allowed {lo} .. {hi}"
    );
}

macro_rules! both {
    ($mailbox:ident, $calendar:ident, $scenario:ident) => {
        #[tokio::test]
        async fn $mailbox() {
            $scenario::<Mailbox>().await
        }
        #[tokio::test]
        async fn $calendar() {
            $scenario::<Calendar>().await
        }
    };
}

// ═════════════════════════════════════════════════════════════════════════════
// C. 429 / Retry-After: rate_limited, retry_at, data kept
// ═════════════════════════════════════════════════════════════════════════════

async fn rate_limited_keeps_the_data_and_says_when_it_will_retry<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let fp = X::fingerprint(&good);
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), X::ALL);

    let each = guard::<X>(Some(fp.clone()));
    let snap = wait_rate_limited::<X>(&mut r.rx, &each).await;
    let observed = Utc::now();
    let served = r.sh.failure_hits()[0].utc;

    assert!(snap.is_stale(), "kept data is marked stale: {snap:?}");
    assert_eq!(X::fingerprint(&snap), fp, "previous items and unread count are kept: {snap:?}");
    assert!(snap.updated_at().is_some(), "updated_at is the last SUCCESS: {snap:?}");
    assert_plain_reason(snap.error().unwrap());
    assert_retry_at_about(snap.retry_at().unwrap(), served, observed, 3);
}
both!(
    mailbox_429_with_retry_after_is_rate_limited_with_retry_at_and_keeps_the_previous_data,
    calendar_429_with_retry_after_is_rate_limited_with_retry_at_and_keeps_the_previous_data,
    rate_limited_keeps_the_data_and_says_when_it_will_retry
);

async fn stays_quiet_for_the_whole_retry_after_and_ignores_the_dirty_signal<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), X::ALL);
    let each = guard::<X>(Some(X::fingerprint(&good)));
    wait_rate_limited::<X>(&mut r.rx, &each).await;
    let throttled = r.sh.failure_hits()[0].clone();

    // Someone (the Fred agent) signals "refresh now" during the quiet period.
    let dirty = r.e.dir.path().join("fred").join(X::DIRTY);
    std::fs::write(&dirty, "").unwrap();
    let consumed = tokio::time::timeout(Duration::from_secs(3), async {
        while dirty.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    assert!(consumed.is_ok(), "the dirty-file watcher must have taken the signal (harness check)");

    // The very next request of ANY kind may only come after the full wait.
    wait_hits(&r.sh, "a request after the quiet period", WAIT, |hits| {
        hits.iter().any(|h| h.at > throttled.at)
    })
    .await;
    let next = r.sh.hits().into_iter().find(|h| h.at > throttled.at).unwrap();
    assert!(
        gap(&throttled, &next) >= 3.0,
        "a {} request ({}) went out only {:.2}s after a 429 with Retry-After: 3",
        X::NAME,
        next.path,
        gap(&throttled, &next)
    );
}
both!(
    mailbox_sends_nothing_for_the_whole_retry_after_even_when_a_dirty_signal_arrives,
    calendar_sends_nothing_for_the_whole_retry_after_even_when_a_dirty_signal_arrives,
    stays_quiet_for_the_whole_retry_after_and_ignores_the_dirty_signal
);

async fn recovers_to_fresh_after_the_quiet_period_and_clears_retry_at<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let fp = X::fingerprint(&good);
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(2))), X::ALL);
    let each = guard::<X>(Some(fp.clone()));
    wait_rate_limited::<X>(&mut r.rx, &each).await;
    let throttled = r.sh.failure_hits()[0].clone();
    r.sh.heal();

    let back = wait_for(&mut r.rx, "recovery", WAIT, &each, |s| s.state() == SourceState::Fresh).await;
    assert!(
        Instant::now().duration_since(throttled.at) >= Duration::from_secs(2),
        "recovered before the Retry-After had passed"
    );
    assert!(back.retry_at().is_none(), "retry_at is cleared on success: {back:?}");
    assert!(!back.is_stale() && back.error().is_none(), "{back:?}");
    assert_eq!(X::fingerprint(&back), fp);
}
both!(
    mailbox_returns_to_fresh_after_the_quiet_period_and_clears_retry_at,
    calendar_returns_to_fresh_after_the_quiet_period_and_clears_retry_at,
    recovers_to_fresh_after_the_quiet_period_and_clears_retry_at
);

async fn throttled_with_nothing_fetched_yet_is_rate_limited_not_error_and_still_waits<X: Subject>() {
    let mut r = rig::<X>(X::timing(fast()), |sh| {
        sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), X::ALL)
    })
    .await;
    let each = guard::<X>(None);
    let snap = wait_for(&mut r.rx, "a rate-limited snapshot", REACT, &each, |s| {
        !matches!(s.state(), SourceState::Loading)
    })
    .await;
    let observed = Utc::now();

    assert_eq!(snap.state(), SourceState::RateLimited, "throttled is not a generic error: {snap:?}");
    assert!(X::is_blank(&snap), "no fake data: {snap:?}");
    assert!(snap.updated_at().is_none(), "nothing has ever been fetched: {snap:?}");
    assert_plain_reason(snap.error().unwrap());
    assert_retry_at_about(snap.retry_at().unwrap(), r.sh.failure_hits()[0].utc, observed, 3);

    // The 5 s "look again soon while empty" shortcut must not undercut Retry-After.
    let throttled = r.sh.failure_hits()[0].clone();
    wait_hits(&r.sh, "a request after the quiet period", WAIT, |hits| {
        hits.iter().any(|h| h.at > throttled.at)
    })
    .await;
    let next = r.sh.hits().into_iter().find(|h| h.at > throttled.at).unwrap();
    assert!(gap(&throttled, &next) >= 3.0, "retried after {:.2}s", gap(&throttled, &next));
}
both!(
    mailbox_throttled_before_any_data_is_rate_limited_with_no_fake_zero_and_still_waits,
    calendar_throttled_before_any_data_is_rate_limited_with_no_fake_zero_and_still_waits,
    throttled_with_nothing_fetched_yet_is_rate_limited_not_error_and_still_waits
);

async fn a_503_with_retry_after_is_rate_limited<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let fp = X::fingerprint(&good);
    r.sh.fail(Failure::unavailable(Some(RetryAfter::Seconds(3))), X::ALL);
    let each = guard::<X>(Some(fp.clone()));
    let snap = wait_for(&mut r.rx, "a rate-limited snapshot", REACT, &each, |s| {
        s.state() != SourceState::Fresh
    })
    .await;
    let observed = Utc::now();
    assert_eq!(snap.state(), SourceState::RateLimited, "{snap:?}");
    assert!(snap.is_stale());
    assert_eq!(X::fingerprint(&snap), fp);
    assert_retry_at_about(snap.retry_at().unwrap(), r.sh.failure_hits()[0].utc, observed, 3);
}
both!(
    mailbox_503_with_retry_after_is_rate_limited_with_retry_at,
    calendar_503_with_retry_after_is_rate_limited_with_retry_at,
    a_503_with_retry_after_is_rate_limited
);

async fn a_503_without_retry_after_is_a_plain_stale_failure_polled_at_the_normal_pace<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let fp = X::fingerprint(&good);
    r.sh.fail(Failure::unavailable(None), X::ALL);
    let each = guard::<X>(Some(fp.clone()));
    let snap = wait_for(&mut r.rx, "a stale snapshot", REACT, &each, |s| s.state() != SourceState::Fresh).await;
    assert_eq!(snap.state(), SourceState::Stale, "no Retry-After, so not a throttle: {snap:?}");
    assert!(snap.retry_at().is_none());
    assert_eq!(X::fingerprint(&snap), fp);

    // Normal cadence is unchanged: ~every 100 ms, certainly not backed off.
    let before = r.sh.hits().len();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let polled = r.sh.hits().len() - before;
    assert!(polled >= 5, "only {polled} requests in 2s at a 100ms poll after a plain 503");
    let later = r.rx.borrow().clone().unwrap();
    assert_eq!(later.state(), SourceState::Stale, "{later:?}");
}
both!(
    mailbox_503_without_retry_after_stays_a_plain_stale_failure_at_the_normal_poll_pace,
    calendar_503_without_retry_after_stays_a_plain_stale_failure_at_the_normal_poll_pace,
    a_503_without_retry_after_is_a_plain_stale_failure_polled_at_the_normal_pace
);

// ── Retry-After forms ────────────────────────────────────────────────────────

async fn an_http_date_retry_after_sets_retry_at_to_that_moment<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::DateIn(120))), X::ALL);
    let each = guard::<X>(Some(X::fingerprint(&good)));
    let snap = wait_rate_limited::<X>(&mut r.rx, &each).await;
    let sent = r.sh.failure_hits()[0].sent_date.expect("the mock sent an HTTP-date");
    let retry_at = snap.retry_at().unwrap();
    assert!(
        (retry_at - sent).num_seconds().abs() <= 3,
        "retry_at {retry_at} should be the Retry-After date {sent}"
    );

    // ... and nothing goes out in the meantime.
    let n = r.sh.hits().len();
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(r.sh.hits().len(), n, "Graph was asked again during a 2-minute Retry-After");
}
both!(
    mailbox_http_date_retry_after_sets_retry_at_to_that_date_and_sends_nothing_meanwhile,
    calendar_http_date_retry_after_sets_retry_at_to_that_date_and_sends_nothing_meanwhile,
    an_http_date_retry_after_sets_retry_at_to_that_moment
);

async fn an_http_date_retry_after_is_waited_out<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::DateIn(4))), X::ALL);
    let each = guard::<X>(Some(X::fingerprint(&good)));
    wait_rate_limited::<X>(&mut r.rx, &each).await;
    let throttled = r.sh.failure_hits()[0].clone();
    let date = throttled.sent_date.unwrap();

    wait_hits(&r.sh, "a request after the quiet period", WAIT, |hits| {
        hits.iter().any(|h| h.at > throttled.at)
    })
    .await;
    let next = r.sh.hits().into_iter().find(|h| h.at > throttled.at).unwrap();
    // HTTP-dates have 1 s resolution: allow a second of rounding.
    assert!(
        next.utc >= date - ChronoDuration::seconds(1),
        "request at {} went out before the Retry-After date {date}",
        next.utc
    );
}
both!(
    mailbox_waits_out_an_http_date_retry_after_before_asking_again,
    calendar_waits_out_an_http_date_retry_after_before_asking_again,
    an_http_date_retry_after_is_waited_out
);

async fn a_huge_retry_after_is_capped_at_fifteen_minutes<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3600))), X::ALL);
    let each = guard::<X>(Some(X::fingerprint(&good)));
    let snap = wait_rate_limited::<X>(&mut r.rx, &each).await;
    let observed = Utc::now();
    assert_retry_at_about(snap.retry_at().unwrap(), r.sh.failure_hits()[0].utc, observed, 15 * 60);

    let n = r.sh.hits().len();
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(r.sh.hits().len(), n, "quiet while rate limited");
}
both!(
    mailbox_caps_a_huge_retry_after_at_fifteen_minutes,
    calendar_caps_a_huge_retry_after_at_fifteen_minutes,
    a_huge_retry_after_is_capped_at_fifteen_minutes
);

// ── Backoff without Retry-After ──────────────────────────────────────────────

async fn consecutive_429s_without_retry_after_back_off_2_4_seconds_with_bounded_jitter<X: Subject>() {
    let (r, _good) = rig_good::<X>(X::timing(fast())).await;
    r.sh.fail(Failure::throttled(None), X::ALL);
    wait_hits(&r.sh, "three throttled responses", Duration::from_secs(40), |hits| {
        hits.iter().filter(|h| h.is_failure()).count() >= 3
    })
    .await;
    let fh = r.sh.failure_hits();
    let (g1, g2) = (gap(&fh[0], &fh[1]), gap(&fh[1], &fh[2]));
    // Base step 2 s then 4 s; jitter adds at most 25% of the base (+1 s of
    // scheduling slack).
    assert!((2.0..=3.5).contains(&g1), "first wait was {g1:.2}s, expected 2s + <=25% jitter");
    assert!((4.0..=6.0).contains(&g2), "second wait was {g2:.2}s, expected 4s + <=25% jitter");
}
both!(
    mailbox_backs_off_2_then_4_seconds_after_consecutive_429s_without_retry_after,
    calendar_backs_off_2_then_4_seconds_after_consecutive_429s_without_retry_after,
    consecutive_429s_without_retry_after_back_off_2_4_seconds_with_bounded_jitter
);

async fn a_successful_fetch_resets_the_backoff<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let each = guard::<X>(Some(X::fingerprint(&good)));

    // One 429, then the service recovers.
    r.sh.fail(Failure::throttled(None), X::ALL);
    wait_rate_limited::<X>(&mut r.rx, &each).await;
    r.sh.heal();
    wait_for(&mut r.rx, "recovery", WAIT, &each, |s| s.state() == SourceState::Fresh).await;

    // Throttled again: the wait starts from the first step (~2 s), not 4 s.
    let mark = r.sh.hits().len();
    r.sh.fail(Failure::throttled(None), X::ALL);
    wait_hits(&r.sh, "two more throttled responses", WAIT, |hits| {
        hits[mark..].iter().filter(|h| h.is_failure()).count() >= 2
    })
    .await;
    let fh: Vec<Hit> = r.sh.hits()[mark..].iter().filter(|h| h.is_failure()).cloned().collect();
    let g = gap(&fh[0], &fh[1]);
    assert!((2.0..=3.5).contains(&g), "after a success the wait restarts at ~2s, was {g:.2}s");
}
both!(
    mailbox_success_resets_the_backoff_to_the_first_step,
    calendar_success_resets_the_backoff_to_the_first_step,
    a_successful_fetch_resets_the_backoff
);

async fn retry_after_wins_over_the_exponential_step<X: Subject>() {
    let (r, _good) = rig_good::<X>(X::timing(fast())).await;
    // First 429 carries no header (wait ~2 s); the second carries Retry-After: 3,
    // where the exponential step would have been 4-5 s.
    r.sh.fail(Failure::throttled(None), X::ALL);
    wait_hits(&r.sh, "the first throttled response", REACT, |hits| hits.iter().any(Hit::is_failure)).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), X::ALL);
    wait_hits(&r.sh, "three throttled responses", Duration::from_secs(40), |hits| {
        hits.iter().filter(|h| h.is_failure()).count() >= 3
    })
    .await;
    let fh = r.sh.failure_hits();
    let g = gap(&fh[1], &fh[2]);
    assert!((3.0..=3.9).contains(&g), "Retry-After: 3 must set the wait (not the 4-5s backoff step); was {g:.2}s");
}
both!(
    mailbox_retry_after_wins_over_the_exponential_step,
    calendar_retry_after_wins_over_the_exponential_step,
    retry_after_wins_over_the_exponential_step
);

async fn the_normal_poll_interval_is_a_floor_for_the_throttle_wait<X: Subject>() {
    let (r, _good) = rig_good::<X>(X::timing(Duration::from_secs(3))).await;
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(1))), X::ALL);
    wait_hits(&r.sh, "two throttled responses", WAIT, |hits| {
        hits.iter().filter(|h| h.is_failure()).count() >= 2
    })
    .await;
    let fh = r.sh.failure_hits();
    assert!(
        gap(&fh[0], &fh[1]) >= 3.0,
        "a 1s Retry-After must not make a 3s poll faster; waited {:.2}s",
        gap(&fh[0], &fh[1])
    );
}
both!(
    mailbox_throttle_wait_is_never_shorter_than_the_normal_poll_interval,
    calendar_throttle_wait_is_never_shorter_than_the_normal_poll_interval,
    the_normal_poll_interval_is_a_floor_for_the_throttle_wait
);

// ═════════════════════════════════════════════════════════════════════════════
// A. A failure on the request retried after 401 -> refresh is a failure
// ═════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Copy, PartialEq)]
enum Expect {
    RateLimited,
    Stale,
}

async fn failure_after_a_401_refresh_keeps_the_data<X: Subject>(
    ttl: Duration,
    paths: &'static [&'static str],
    failure: Failure,
    expect: Expect,
) {
    // A slow poll, so that the cycle which hits 401 -> refresh -> failure is the
    // ONLY one we look at: later cycles use the refreshed token and fail on the
    // first try, which would mask a mishandled retry.
    let (r, good) = rig_good::<X>(timing(Duration::from_secs(2), ttl)).await;
    let fp = X::fingerprint(&good);

    // The server revokes the token we hold for `paths`; the refreshed token is
    // accepted but the request then fails.
    r.sh.reject_old_on(paths);
    r.sh.fail(failure, paths);

    wait_hits(&r.sh, "the refreshed retry to be answered with the failure", WAIT, |hits| {
        hits.iter().any(Hit::is_failure)
    })
    .await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(r.sh.refreshes.load(SeqCst) >= 1, "harness check: the token was refreshed");
    assert!(r.sh.hits().iter().any(|h| h.status == 401), "harness check: a 401 was served");

    let snap = r.rx.borrow().clone().expect("published");
    guard::<X>(Some(fp.clone()))(&snap);
    let want = match expect {
        Expect::RateLimited => SourceState::RateLimited,
        Expect::Stale => SourceState::Stale,
    };
    assert_eq!(snap.state(), want, "the snapshot published after the failed retry: {snap:?}");
    assert!(snap.is_stale(), "{snap:?}");
    assert_eq!(X::fingerprint(&snap), fp, "previous data kept: {snap:?}");
    assert_plain_reason(snap.error().unwrap());
    assert_eq!(snap.retry_at().is_some(), expect == Expect::RateLimited, "{snap:?}");
}

/// Fast polling and the unread count re-read on every cycle.
#[allow(non_snake_case)]
fn NO_TTL() -> FredTiming {
    timing(fast(), Duration::ZERO)
}

#[tokio::test]
async fn mailbox_delta_429_after_a_401_refresh_is_rate_limited_with_the_data_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Mailbox>(
        an_hour(),
        &[DELTA],
        Failure::throttled(Some(RetryAfter::Seconds(30))),
        Expect::RateLimited,
    )
    .await;
}

#[tokio::test]
async fn mailbox_delta_503_after_a_401_refresh_is_stale_with_the_data_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Mailbox>(an_hour(), &[DELTA], Failure::unavailable(None), Expect::Stale).await;
}

#[tokio::test]
async fn mailbox_delta_403_after_a_401_refresh_is_stale_with_the_data_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Mailbox>(an_hour(), &[DELTA], Failure::forbidden(), Expect::Stale).await;
}

#[tokio::test]
async fn mailbox_unread_count_429_after_a_401_refresh_is_rate_limited_with_the_data_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Mailbox>(
        Duration::ZERO,
        &[FOLDER],
        Failure::throttled(Some(RetryAfter::Seconds(30))),
        Expect::RateLimited,
    )
    .await;
}

#[tokio::test]
async fn mailbox_unread_count_403_after_a_401_refresh_is_stale_never_a_zero_count() {
    failure_after_a_401_refresh_keeps_the_data::<Mailbox>(Duration::ZERO, &[FOLDER], Failure::forbidden(), Expect::Stale).await;
}

#[tokio::test]
async fn calendar_429_after_a_401_refresh_is_rate_limited_with_the_events_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Calendar>(
        an_hour(),
        &[CALENDAR_VIEW],
        Failure::throttled(Some(RetryAfter::Seconds(30))),
        Expect::RateLimited,
    )
    .await;
}

#[tokio::test]
async fn calendar_503_after_a_401_refresh_is_stale_with_the_events_kept() {
    failure_after_a_401_refresh_keeps_the_data::<Calendar>(an_hour(), &[CALENDAR_VIEW], Failure::unavailable(None), Expect::Stale).await;
}

#[tokio::test]
async fn calendar_403_after_a_401_refresh_is_stale_never_no_meetings_today() {
    failure_after_a_401_refresh_keeps_the_data::<Calendar>(an_hour(), &[CALENDAR_VIEW], Failure::forbidden(), Expect::Stale).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// B. Wrong-shaped 200 answers are errors, never empty / zero
// ═════════════════════════════════════════════════════════════════════════════

async fn a_200_error_object_with_previous_data_is_stale_with_the_data_kept<X: Subject>() {
    let (mut r, good) = rig_good::<X>(X::timing(fast())).await;
    let fp = X::fingerprint(&good);
    r.sh.fail(Failure::ok_error_object(), X::MAIN);
    let each = guard::<X>(Some(fp.clone()));
    let snap = wait_for(&mut r.rx, "a degraded snapshot", REACT, &each, |s| s.state() != SourceState::Fresh).await;
    assert_eq!(snap.state(), SourceState::Stale, "{snap:?}");
    assert!(snap.is_stale() && snap.error().is_some());
    assert_eq!(X::fingerprint(&snap), fp);
}
both!(
    mailbox_delta_page_that_is_a_graph_error_object_is_stale_not_a_quiet_success,
    calendar_page_that_is_a_graph_error_object_is_stale_not_a_quiet_success,
    a_200_error_object_with_previous_data_is_stale_with_the_data_kept
);

async fn a_200_error_object_with_no_previous_data_is_an_error_never_empty<X: Subject>() {
    let mut r = rig::<X>(X::timing(fast()), |sh| sh.fail(Failure::ok_error_object(), X::MAIN)).await;
    let each = guard::<X>(None);
    let snap = wait_for(&mut r.rx, "an error snapshot", REACT, &each, |s| s.state() != SourceState::Loading).await;
    assert_eq!(snap.state(), SourceState::Error, "{snap:?}");
    assert!(snap.updated_at().is_none(), "nothing was ever fetched: {snap:?}");
    assert!(X::is_blank(&snap), "{snap:?}");
}
both!(
    mailbox_delta_page_that_is_a_graph_error_object_with_no_data_is_error_not_empty,
    calendar_page_that_is_a_graph_error_object_with_no_data_is_error_not_empty,
    a_200_error_object_with_no_previous_data_is_an_error_never_empty
);

#[tokio::test]
async fn mailbox_unread_count_body_without_unread_item_count_never_becomes_zero_unread() {
    let (mut r, good) = rig_good::<Mailbox>(NO_TTL()).await;
    let fp = Mailbox::fingerprint(&good);
    r.sh.fail(Failure::ok_body(json!({})), &[FOLDER]);
    let each = guard::<Mailbox>(Some(fp.clone()));
    let snap = wait_for(&mut r.rx, "a degraded snapshot", REACT, &each, |s| s.state() != SourceState::Fresh).await;
    assert_eq!(snap.state(), SourceState::Stale, "{snap:?}");
    assert_eq!(snap.unread_count as u64, UNREAD, "the previous count is kept: {snap:?}");
    assert_eq!(Mailbox::fingerprint(&snap), fp);
    assert!(snap.error().is_some());
}

#[tokio::test]
async fn mailbox_unread_count_body_without_unread_item_count_and_no_data_is_an_error() {
    let mut r = rig::<Mailbox>(NO_TTL(), |sh| sh.fail(Failure::ok_body(json!({})), &[FOLDER])).await;
    let each = guard::<Mailbox>(None);
    let snap = wait_for(&mut r.rx, "an error snapshot", REACT, &each, |s| s.state() != SourceState::Loading).await;
    assert_eq!(snap.state(), SourceState::Error, "{snap:?}");
    assert!(snap.updated_at.is_none(), "{snap:?}");
    assert!(snap.error.is_some());
}

// ═════════════════════════════════════════════════════════════════════════════
// The Inbox unread-count call is throttled (mailbox only)
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn mailbox_429_on_the_unread_count_call_is_rate_limited_keeps_the_count_and_silences_every_call() {
    let (mut r, good) = rig_good::<Mailbox>(NO_TTL()).await;
    let fp = Mailbox::fingerprint(&good);
    r.sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), &[FOLDER]);

    let each = guard::<Mailbox>(Some(fp.clone()));
    let snap = wait_for(&mut r.rx, "a rate-limited snapshot", REACT, &each, |s| s.state() != SourceState::Fresh).await;
    let observed = Utc::now();
    assert_eq!(snap.state(), SourceState::RateLimited, "{snap:?}");
    assert!(snap.stale);
    assert_eq!(snap.unread_count as u64, UNREAD, "never a confident zero: {snap:?}");
    assert_eq!(Mailbox::fingerprint(&snap), fp);
    assert_plain_reason(snap.error.as_deref().unwrap());
    let throttled = r.sh.failure_hits()[0].clone();
    assert_eq!(throttled.path, FOLDER);
    assert_retry_at_about(snap.retry_at.unwrap(), throttled.utc, observed, 3);

    // The delta call is silenced too, not just the one that was throttled.
    wait_hits(&r.sh, "a request after the quiet period", WAIT, |hits| {
        hits.iter().any(|h| h.at > throttled.at)
    })
    .await;
    let next = r.sh.hits().into_iter().find(|h| h.at > throttled.at).unwrap();
    assert!(
        gap(&throttled, &next) >= 3.0,
        "a {} request went out {:.2}s after the unread-count 429",
        next.path,
        gap(&throttled, &next)
    );
}

#[tokio::test]
async fn mailbox_429_on_the_unread_count_call_with_no_prior_data_is_rate_limited_not_zero_unread() {
    let mut r = rig::<Mailbox>(NO_TTL(), |sh| {
        sh.fail(Failure::throttled(Some(RetryAfter::Seconds(3))), &[FOLDER])
    })
    .await;
    let each = guard::<Mailbox>(None);
    let snap = wait_for(&mut r.rx, "a rate-limited snapshot", REACT, &each, |s| {
        s.state() != SourceState::Loading
    })
    .await;
    assert_eq!(snap.state, SourceState::RateLimited, "{snap:?}");
    assert!(snap.updated_at.is_none(), "no count was ever read: {snap:?}");
    assert_eq!(snap.unread_count, 0);
    assert!(snap.retry_at.is_some());
}
