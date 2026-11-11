//! Live tracker items bound to a PR's CI (slice T6, PRD 51 / 52 / 54): the
//! daemon's CI poller keeps a bound item current from GitHub's check runs with
//! no agent call, at most once per 8 s per PR, with conditional GETs, and a
//! GitHub that cannot be asked is **not** an observation.
//!
//! Hermetic: a `wiremock` fake GitHub (every request lands on it through
//! `API_BASE_OVERRIDE`), a `FakeClock` for the registry (the poller is handed
//! `clock.now()` so both agree on "now"), temp dirs for the repo, state root
//! and home. Nothing here sleeps or reads the wall clock.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Utc};
use nostromo::data::github_client::GithubClient;
use nostromo::data::perri_queue_native::API_BASE_OVERRIDE;
use nostromo::tracker::ci_poller::{CiPoller, POLL_PERIOD};
use nostromo::tracker::view::{ViewItem, ViewNode};
use nostromo::tracker::{
    Author, BindingHub, Clock, FakeClock, Op, OpenArgs, ReadOutcome, RegistryParts, Status,
    TrackerBoardView, TrackerRegistry, Upsert,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

const WRITER: &str = "tag-w";
const WRITER_SESSION: &str = "sess-w";
const READER: &str = "tag-r";
const READER_SESSION: &str = "sess-r";

const PULL_PATH: &str = "/repos/acme/web/pulls/7";
const CHECKS_PATH: &str = "/repos/acme/web/commits/abc/check-runs";
const PR_ETAG: &str = "\"pr-1\"";

// ---------------------------------------------------------------------------
// Fake GitHub
// ---------------------------------------------------------------------------

/// What the fake GitHub says about PR 7 right now.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    /// One check run, `build`, in progress.
    Pending,
    /// `build` completed with a failure.
    Failing,
    /// `build` completed successfully.
    Green,
    /// Every request answers 500.
    Down,
}

impl Phase {
    fn checks_etag(self) -> &'static str {
        match self {
            Phase::Pending => "\"cr-pending\"",
            Phase::Failing => "\"cr-failing\"",
            Phase::Green => "\"cr-green\"",
            Phase::Down => "\"cr-down\"",
        }
    }

    fn checks_body(self) -> Value {
        let (status, conclusion) = match self {
            Phase::Pending | Phase::Down => ("in_progress", Value::Null),
            Phase::Failing => ("completed", json!("failure")),
            Phase::Green => ("completed", json!("success")),
        };
        json!({"check_runs": [{"name": "build", "status": status, "conclusion": conclusion}]})
    }
}

/// A GitHub that answers like the real one: `ETag` on every 200, a 304 when
/// the request's `If-None-Match` names the current ETag, 500 while down.
fn github_answer(req: &Request, phase: Phase, etag: &str, body: Value) -> ResponseTemplate {
    if phase == Phase::Down {
        return ResponseTemplate::new(500);
    }
    let matches = req
        .headers
        .get("if-none-match")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v == etag);
    if matches {
        ResponseTemplate::new(304)
    } else {
        ResponseTemplate::new(200)
            .insert_header("ETag", etag)
            .set_body_json(body)
    }
}

struct FakeGithub {
    server: MockServer,
    phase: Arc<Mutex<Phase>>,
}

impl FakeGithub {
    /// Starts the server, mounts PR 7 (head `abc`) and its check runs, and
    /// points this thread's GitHub API base at it.
    async fn start() -> FakeGithub {
        let server = MockServer::start().await;
        API_BASE_OVERRIDE.with(|cell| *cell.borrow_mut() = Some(server.uri()));
        let phase = Arc::new(Mutex::new(Phase::Pending));

        let for_pull = phase.clone();
        Mock::given(method("GET"))
            .and(path(PULL_PATH))
            .respond_with(move |req: &Request| {
                let phase = *for_pull.lock().unwrap();
                github_answer(req, phase, PR_ETAG, json!({"head": {"sha": "abc"}}))
            })
            .mount(&server)
            .await;

        let for_checks = phase.clone();
        Mock::given(method("GET"))
            .and(path(CHECKS_PATH))
            .respond_with(move |req: &Request| {
                let phase = *for_checks.lock().unwrap();
                github_answer(req, phase, phase.checks_etag(), phase.checks_body())
            })
            .mount(&server)
            .await;

        FakeGithub { server, phase }
    }

    fn set(&self, phase: Phase) {
        *self.phase.lock().unwrap() = phase;
    }

    async fn requests(&self) -> Vec<Request> {
        self.server
            .received_requests()
            .await
            .expect("the mock server records requests")
    }

    async fn request_count(&self) -> usize {
        self.requests().await.len()
    }
}

/// A client built from a temp hosts.yml (no `GITHUB_TOKEN` needed), exactly as
/// `tests/etag_caching.rs` does. The temp dir is returned so it outlives the
/// client's construction.
fn make_client() -> (GithubClient, TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let hosts_path = dir.path().join("hosts.yml");
    std::fs::write(
        &hosts_path,
        "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
    )
    .unwrap();
    std::env::remove_var("GITHUB_TOKEN");
    let client = GithubClient::new(Some(&hosts_path))
        .expect("client should build from the hosts.yml fixture");
    (client, dir)
}

// ---------------------------------------------------------------------------
// Rig: a board with a writer focus, a reader focus and the items to bind
// ---------------------------------------------------------------------------

struct Rig {
    _tmp: TempDir,
    clock: Arc<FakeClock>,
    reg: Arc<TrackerRegistry>,
    poller: CiPoller,
}

fn writer() -> Author {
    Author::Agent {
        focus: WRITER.into(),
        session_id: WRITER_SESSION.into(),
        name: WRITER.into(),
    }
}

fn open_args(repo: &Path) -> OpenArgs {
    OpenArgs {
        topic: Some("ci".into()),
        cwd: repo.to_path_buf(),
        ..Default::default()
    }
}

impl Rig {
    /// A board with `(id, bind)` items; the reader has caught up with the
    /// seeding.
    fn with_items(items: &[(&str, Option<&str>)]) -> Rig {
        let tmp = TempDir::new().unwrap();
        let base: PathBuf = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let reg = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            base.join("state"),
            home,
            clock.clone(),
        )));
        for (tag, session) in [(WRITER, WRITER_SESSION), (READER, READER_SESSION)] {
            reg.open(tag, session, &open_args(&repo)).expect("open");
        }
        let ops: Vec<Op> = items
            .iter()
            .map(|&(id, bind)| {
                Op::Upsert(Upsert {
                    id: Some(id.into()),
                    section: Some("now".into()),
                    text: Some(format!("Item {id}")),
                    bind: bind.map(str::to_string),
                    ..Default::default()
                })
            })
            .collect();
        reg.apply(WRITER, WRITER_SESSION, &ops, &writer())
            .expect("seed");
        let rig = Rig {
            _tmp: tmp,
            clock,
            poller: CiPoller::new(BindingHub::new(reg.clone())),
            reg,
        };
        rig.reader_changes();
        rig
    }

    fn now(&self) -> DateTime<Utc> {
        self.clock.now()
    }

    fn advance(&self, secs: i64) {
        self.clock.advance(Duration::seconds(secs));
    }

    /// One poller pass at the registry's "now".
    async fn poll(&mut self, client: &GithubClient) -> bool {
        let now = self.now();
        self.poller.poll_due(client, now).await
    }

    fn view(&self) -> TrackerBoardView {
        self.reg.board_view(READER).expect("a board view")
    }

    fn item(&self, id: &str) -> ViewItem {
        self.view()
            .nodes
            .iter()
            .find_map(|n| match n {
                ViewNode::Item(i) if i.id == id => Some(i.clone()),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no item {id} in the view"))
    }

    fn note(&self, id: &str) -> String {
        format!("{:?}", self.item(id).note_blocks)
    }

    /// What a different agent session sees since it last looked.
    fn reader_changes(&self) -> Vec<Value> {
        match self.reg.read(READER, READER_SESSION).expect("read") {
            ReadOutcome::Delta { changes, .. } => changes,
            ReadOutcome::Full { .. } => panic!("the reader has a cursor: expected a delta"),
        }
    }
}

fn header_of(req: &Request, name: &str) -> Option<String> {
    req.headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
}

fn hits(requests: &[Request], request_path: &str) -> usize {
    requests
        .iter()
        .filter(|r| r.url.path() == request_path)
        .count()
}

// ---------------------------------------------------------------------------
// PRD 51: the poller follows a bound PR's CI with no agent call
// ---------------------------------------------------------------------------

#[tokio::test]
async fn with_no_item_bound_to_a_pr_the_poller_makes_no_request() {
    let github = FakeGithub::start().await;
    let (client, _hosts) = make_client();
    // A plain item, and a Mother-bound one: neither is a PR's CI.
    let mut rig = Rig::with_items(&[("plain", None), ("job", Some("mother.job/JOB1"))]);

    for _ in 0..3 {
        assert!(
            !rig.poll(&client).await,
            "nothing to follow, nothing changed"
        );
        rig.advance(POLL_PERIOD.as_secs() as i64);
    }

    assert_eq!(github.request_count().await, 0, "GitHub was never asked");
}

#[tokio::test]
async fn a_bound_pr_item_follows_its_ci_every_eight_seconds_with_conditional_gets() {
    let github = FakeGithub::start().await;
    let (client, _hosts) = make_client();
    let mut rig = Rig::with_items(&[("ci", Some("pr.ci/acme/web#7")), ("plain", None)]);
    assert_eq!(POLL_PERIOD, StdDuration::from_secs(8));
    assert_eq!(rig.item("ci").status, Status::Todo);

    // First poll: asked at once, no agent call; the item is in progress.
    let t0 = rig.now();
    assert!(
        rig.poll(&client).await,
        "the first observation changes the view"
    );
    let item = rig.item("ci");
    assert_eq!(item.status, Status::InProgress);
    assert_eq!(
        item.bound.as_ref().map(|b| b.source.as_str()),
        Some("pr.ci")
    );
    assert_eq!(item.bound.as_ref().and_then(|b| b.as_of), Some(t0));
    assert_eq!(
        rig.item("plain").status,
        Status::Todo,
        "unbound items are left alone"
    );
    let requests = github.requests().await;
    assert_eq!(hits(&requests, PULL_PATH), 1);
    assert_eq!(hits(&requests, CHECKS_PATH), 1);

    // The next agent delta carries that as one entry attributed to the source.
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source pr.ci"));
    assert_eq!(changes[0]["id"], json!("ci"));
    assert_eq!(changes[0]["status"], json!(["todo", "in-progress"]));

    // Inside the period nothing is asked.
    rig.advance(4);
    assert!(!rig.poll(&client).await);
    rig.advance(3);
    assert!(!rig.poll(&client).await);
    assert_eq!(
        github.request_count().await,
        2,
        "no request at +4 s or +7 s (period is 8 s)"
    );

    // At the period it asks again, conditionally; the CI has failed meanwhile.
    github.set(Phase::Failing);
    rig.advance(1);
    let t8 = rig.now();
    assert_eq!(t8 - t0, Duration::seconds(8));
    assert!(rig.poll(&client).await, "a failing check changes the view");

    let requests = github.requests().await;
    assert_eq!(requests.len(), 4, "one more pair of requests");
    let second_pull = requests
        .iter()
        .filter(|r| r.url.path() == PULL_PATH)
        .nth(1)
        .expect("a second PR request");
    let second_checks = requests
        .iter()
        .filter(|r| r.url.path() == CHECKS_PATH)
        .nth(1)
        .expect("a second check-runs request");
    assert_eq!(
        header_of(second_pull, "if-none-match").as_deref(),
        Some(PR_ETAG)
    );
    assert_eq!(
        header_of(second_checks, "if-none-match").as_deref(),
        Some(Phase::Pending.checks_etag()),
        "the ETag the first answer carried is sent back"
    );

    let item = rig.item("ci");
    assert_eq!(item.status, Status::Blocked);
    assert!(
        rig.note("ci").contains("build"),
        "the failing check is named: {}",
        rig.note("ci")
    );
    assert_eq!(item.bound.as_ref().and_then(|b| b.as_of), Some(t8));
    assert!(!item.bound.as_ref().is_some_and(|b| b.badly_stale));

    // Another session's next read: one entry, attributed to the source.
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source pr.ci"));
    assert_eq!(changes[0]["status"], json!(["in-progress", "blocked"]));
}

#[tokio::test]
async fn an_unchanged_ci_answered_304_is_still_a_fresh_observation_and_no_change() {
    let github = FakeGithub::start().await;
    let (client, _hosts) = make_client();
    let mut rig = Rig::with_items(&[("ci", Some("pr.ci/acme/web#7"))]);

    rig.poll(&client).await;
    rig.reader_changes();

    rig.advance(8);
    let t8 = rig.now();
    assert!(
        !rig.poll(&client).await,
        "the same state again is not a visible change"
    );
    assert_eq!(github.request_count().await, 4);
    assert_eq!(
        rig.item("ci").bound.as_ref().and_then(|b| b.as_of),
        Some(t8),
        "but the source did answer, so the item is as of now"
    );
    assert!(rig.reader_changes().is_empty(), "no entry for no change");
}

#[tokio::test]
async fn items_bound_to_one_pr_share_one_poll_and_green_completes_only_the_bang_green_one() {
    let github = FakeGithub::start().await;
    let (client, _hosts) = make_client();
    let mut rig = Rig::with_items(&[
        ("watch", Some("pr.ci/acme/web#7")),
        ("finish", Some("pr.ci/acme/web#7!green")),
    ]);
    github.set(Phase::Green);

    rig.poll(&client).await;

    let requests = github.requests().await;
    assert_eq!(
        (hits(&requests, PULL_PATH), hits(&requests, CHECKS_PATH)),
        (1, 1),
        "one PR is asked once however many items follow it"
    );
    assert_eq!(rig.item("finish").status, Status::Done);
    assert_eq!(
        rig.item("watch").status,
        Status::Todo,
        "plain green leaves the status alone"
    );
    assert!(
        rig.note("watch").contains("CI green"),
        "{}",
        rig.note("watch")
    );
}

// ---------------------------------------------------------------------------
// PRD 52: a GitHub that can't be asked is not an observation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_failing_github_keeps_the_last_value_and_as_of_and_goes_badly_stale_until_it_recovers() {
    let github = FakeGithub::start().await;
    let (client, _hosts) = make_client();
    let mut rig = Rig::with_items(&[("ci", Some("pr.ci/acme/web#7"))]);
    rig.reg.set_badly_stale_after(StdDuration::from_secs(300));

    // Healthy first.
    let t0 = rig.now();
    rig.poll(&client).await;
    rig.reader_changes();
    assert_eq!(rig.item("ci").status, Status::InProgress);

    // GitHub starts answering 500. The poller does ask, but learns nothing.
    github.set(Phase::Down);
    rig.advance(8);
    let before = github.request_count().await;
    assert!(!rig.poll(&client).await, "a failure changes nothing");
    assert!(github.request_count().await > before, "it did try");
    let item = rig.item("ci");
    assert_eq!(item.status, Status::InProgress, "the last value is kept");
    assert_eq!(
        item.bound.as_ref().and_then(|b| b.as_of),
        Some(t0),
        "a failed fetch must not refresh as_of"
    );
    assert!(!item.bound.as_ref().is_some_and(|b| b.badly_stale));
    assert!(
        rig.reader_changes().is_empty(),
        "a failure is no state change"
    );

    // Silent past the limit: still the last value, now flagged.
    rig.advance(293);
    assert!(rig.now() - t0 > Duration::seconds(300));
    rig.poll(&client).await;
    assert!(rig.reg.tick_live(), "the staleness flip is a view change");
    let item = rig.item("ci");
    assert_eq!(item.status, Status::InProgress, "the last value is kept");
    let bound = item.bound.expect("still bound");
    assert!(bound.badly_stale);
    assert_eq!(bound.as_of, Some(t0));

    // GitHub recovers (an unchanged answer is a 304 against the old ETags).
    github.set(Phase::Pending);
    rig.advance(8);
    let t_back = rig.now();
    rig.poll(&client).await;
    let bound = rig.item("ci").bound.expect("still bound");
    assert!(!bound.badly_stale, "a fresh observation clears it");
    assert_eq!(bound.as_of, Some(t_back));
}

#[tokio::test]
async fn a_github_that_is_down_from_the_start_leaves_the_item_untouched_until_it_goes_stale() {
    let github = FakeGithub::start().await;
    github.set(Phase::Down);
    let (client, _hosts) = make_client();
    let mut rig = Rig::with_items(&[("ci", Some("pr.ci/acme/web#7"))]);
    rig.reg.set_badly_stale_after(StdDuration::from_secs(300));

    assert!(!rig.poll(&client).await);
    let item = rig.item("ci");
    assert_eq!(item.status, Status::Todo, "no observation, no status");
    assert_eq!(item.bound.as_ref().and_then(|b| b.as_of), None);

    rig.advance(301);
    assert!(rig.reg.tick_live());
    let bound = rig.item("ci").bound.expect("still bound");
    assert!(bound.badly_stale);
    assert_eq!(bound.as_of, None);
}
