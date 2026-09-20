//! The targeted relay-update engine: what a single GitHub event costs, and what
//! it changes.
//!
//! The property these tests exist to defend is that **search traffic is a
//! function of elapsed time, not of relay event volume**. The subscription is
//! org-wide, so trigger volume is everyone's PR activity in Carefeed against
//! GitHub's 30-searches-per-minute ceiling; a queue that re-derived itself per
//! event was one busy afternoon away from a 403 mid-review-session.
//!
//! So most assertions here are about *cost* — how many requests reached the
//! fake GitHub, and to which paths — as much as about the resulting snapshot.
//! A test that only checked the snapshot would pass just as happily against the
//! three-searches-per-event implementation this replaced.
//!
//! The second thing under test is that the two code paths that can bucket a PR
//! — the periodic full fetch and the targeted update — **agree**. A queue that
//! puts a PR in `needs_review` or `changes_req` depending on which path last
//! touched it reads to the user as a flickering, untrustworthy list, which is
//! worse than a slow one.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use serde_json::json;
use wiremock::matchers::{body_string_contains, method, path, path_regex, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

use nostromo::config::Config;
use nostromo::data::github_client::GithubClient;
use nostromo::data::perri_queue::{CiState, PrQueueItem, PrQueueSnapshot};
use nostromo::data::perri_queue_native::{
    prefetch_targets, render_with_suppression, wait_for_wake, Candidate, PerriQueueNativeSource,
    PrefetchScope, QueueCaches, Wake, API_BASE_OVERRIDE,
};
use nostromo::data::perri_queue_targeted::{
    apply_relay_event, classify_event, diff_snapshots, normalise_login, Action, Outcome,
    TargetedState,
};
use nostromo::data::perri_suppress::{unix_now_secs, SuppressStore};
use nostromo::data::relay_client::{QueueSignal, RelayEvent};

const ME: &str = "tester";
const REPO: &str = "Carefeed/admin-portal";

// ── Harness ───────────────────────────────────────────────────────────────────

/// A source, a client, a suppression store and a ledger, all pointed at `server`.
struct Harness {
    source: PerriQueueNativeSource,
    client: GithubClient,
    suppress: Arc<Mutex<SuppressStore>>,
    caches: QueueCaches,
    state: TargetedState,
    _dir: tempfile::TempDir,
}

impl Harness {
    fn new(server: &MockServer) -> Self {
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(server.uri()));

        let dir = tempfile::tempdir().unwrap();
        let hosts_path = dir.path().join("hosts.yml");
        std::fs::write(
            &hosts_path,
            "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
        )
        .unwrap();
        std::env::remove_var("GITHUB_TOKEN");

        let config = Config {
            github_token_path: Some(hosts_path.clone()),
            perri_state: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        let client = GithubClient::new(Some(&hosts_path)).unwrap();
        let suppress = Arc::new(Mutex::new(SuppressStore::new(
            dir.path().join("approvals-state.json"),
            Duration::from_secs(900),
        )));

        Harness {
            source: PerriQueueNativeSource::new(config),
            client,
            suppress,
            caches: QueueCaches::default(),
            state: TargetedState::default(),
            _dir: dir,
        }
    }

    async fn apply(&mut self, ev: &RelayEvent) -> Outcome {
        apply_relay_event(
            &self.client,
            ME,
            ev,
            &mut self.caches,
            &self.suppress,
            &mut self.state,
        )
        .await
    }

    async fn fetch(&mut self) -> PrQueueSnapshot {
        self.source
            .fetch(&self.client, ME, &mut self.caches, &self.suppress)
            .await
            .expect("fetch() should succeed")
    }

    /// The snapshot the queue would publish right now, from the ledger alone.
    fn items(&self) -> Vec<PrQueueItem> {
        render_with_suppression(&self.caches, ME, &self.suppress)
    }

    fn candidate(&self, number: u64) -> Option<&Candidate> {
        self.caches.candidates.get(&(REPO.to_owned(), number))
    }
}

/// Counts of requests reaching the fake GitHub, by the axis each test cares about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct Calls {
    total: usize,
    search: usize,
    graphql: usize,
    check_runs: usize,
    pull_detail: usize,
    reviews: usize,
}

async fn calls(server: &MockServer) -> Calls {
    let reqs = server.received_requests().await.unwrap();
    let mut c = Calls {
        total: reqs.len(),
        ..Default::default()
    };
    for r in &reqs {
        let p = r.url.path();
        if p == "/search/issues" {
            c.search += 1;
        } else if p == "/graphql" {
            c.graphql += 1;
        } else if p.ends_with("/check-runs") {
            c.check_runs += 1;
        } else if p.ends_with("/reviews") {
            c.reviews += 1;
        } else if p.contains("/pulls/") {
            c.pull_detail += 1;
        }
    }
    c
}

// ── Event builder ─────────────────────────────────────────────────────────────

/// A relay event with a unique `event_id` and an explicit `delivered_at`, so a
/// test that isn't about dedup/ordering never trips over either.
fn ev(event_type: &str) -> RelayEvent {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    RelayEvent {
        event_type: event_type.to_owned(),
        event_id: Some(format!("evt-{n}")),
        delivered_at: Some(at(2026, 6, 7, 12, 0, 0)),
        repo: Some(REPO.to_owned()),
        ..Default::default()
    }
}

fn at(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, mo, d, h, mi, s).unwrap()
}

trait EvExt {
    fn num(self, n: u64) -> Self;
    fn sha(self, s: &str) -> Self;
    fn reviewer(self, r: &str) -> Self;
    fn review_state(self, s: &str) -> Self;
    fn repo(self, r: &str) -> Self;
    fn id(self, id: Option<&str>) -> Self;
    fn delivered(self, t: DateTime<Utc>) -> Self;
}

impl EvExt for RelayEvent {
    fn num(mut self, n: u64) -> Self {
        self.number = Some(n);
        self
    }
    fn sha(mut self, s: &str) -> Self {
        self.head_sha = Some(s.to_owned());
        self
    }
    fn reviewer(mut self, r: &str) -> Self {
        self.reviewer = Some(r.to_owned());
        self
    }
    fn review_state(mut self, s: &str) -> Self {
        self.review_state = Some(s.to_owned());
        self
    }
    fn repo(mut self, r: &str) -> Self {
        self.repo = Some(r.to_owned());
        self
    }
    fn id(mut self, id: Option<&str>) -> Self {
        self.event_id = id.map(|s| s.to_owned());
        self
    }
    fn delivered(mut self, t: DateTime<Utc>) -> Self {
        self.delivered_at = Some(t);
        self
    }
}

// ── Ledger seeding ────────────────────────────────────────────────────────────

/// A ledger entry, defaulted to "an ordinary human PR in `needs_review` with
/// green CI" so each test only states the fields it is actually about.
fn candidate(number: u64, head_sha: &str) -> Candidate {
    Candidate {
        repo: REPO.to_owned(),
        number,
        seq: number,
        title: format!("PR {number}"),
        url: format!("https://github.com/{REPO}/pull/{number}"),
        author: "alice".to_owned(),
        is_bot: false,
        draft: false,
        updated_at: Some("2026-06-07T12:00:00Z".to_owned()),
        head_sha: head_sha.to_owned(),
        ci_state: CiState::Success,
        actions_failed: false,
        in_requested: false,
        in_needs_review: true,
        my_review: None,
        targeted_seen_at: None,
    }
}

fn seed(caches: &mut QueueCaches, c: Candidate) {
    caches.next_seq = caches.next_seq.max(c.seq + 1);
    caches
        .head_sha_cache
        .lock()
        .unwrap()
        .insert((c.repo.clone(), c.number), c.head_sha.clone());
    caches.candidates.insert((c.repo.clone(), c.number), c);
}

// ── Mock helpers ──────────────────────────────────────────────────────────────

async fn mount_user(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/user"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login": ME})))
        .mount(server)
        .await;
}

fn search_item(number: u64, author: &str, draft: bool, updated_at: &str) -> serde_json::Value {
    json!({
        "number": number,
        "title": format!("PR {number}"),
        "html_url": format!("https://github.com/{REPO}/pull/{number}"),
        "repository_url": format!("https://api.github.com/repos/{REPO}"),
        "user": { "login": author },
        "draft": draft,
        "updated_at": updated_at,
    })
}

/// Mount the three searches. Each argument is that bucket's raw result set.
async fn mount_searches(
    server: &MockServer,
    requested: Vec<serde_json::Value>,
    needs: Vec<serde_json::Value>,
    reviewed: Vec<serde_json::Value>,
) {
    for (q, items) in [
        (
            "is:open is:pr review-requested:@me org:Carefeed archived:false",
            requested,
        ),
        (
            "is:open is:pr review:required org:Carefeed archived:false",
            needs,
        ),
        (
            "is:open is:pr reviewed-by:@me org:Carefeed archived:false",
            reviewed,
        ),
    ] {
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", q))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": items})))
            .mount(server)
            .await;
    }
}

/// `GET /repos/{repo}/pulls/{n}` — what the full fetch reads to resolve a head.
async fn mount_pr_detail(server: &MockServer, number: u64, head_sha: &str, terminal: bool) {
    let body = if terminal {
        json!({"head": {"sha": head_sha}, "state": "closed", "merged_at": "2026-06-07T11:58:00Z"})
    } else {
        json!({"head": {"sha": head_sha}, "state": "open", "merged_at": null})
    };
    Mock::given(method("GET"))
        .and(path(format!("/repos/{REPO}/pulls/{number}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(server)
        .await;
}

fn check_run(conclusion: &str) -> serde_json::Value {
    json!({
        "check_runs": [{
            "name": "build", "status": "completed", "conclusion": conclusion,
            "id": 1, "app": { "slug": "github-actions" }, "output": {}
        }]
    })
}

/// Check-runs for one specific SHA, so tests can give two SHAs different verdicts.
async fn mount_check_runs_for(server: &MockServer, sha: &str, conclusion: &str) {
    Mock::given(method("GET"))
        .and(path(format!("/repos/{REPO}/commits/{sha}/check-runs")))
        .respond_with(ResponseTemplate::new(200).set_body_json(check_run(conclusion)))
        .mount(server)
        .await;
}

/// Check-runs for any SHA — for tests where CI isn't the variable.
async fn mount_check_runs_any(server: &MockServer, conclusion: &str) {
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/.*/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(check_run(conclusion)))
        .mount(server)
        .await;
}

/// `GET /repos/{repo}/pulls/{n}/reviews` — the full fetch's bucket-3 read.
async fn mount_reviews(server: &MockServer, number: u64, reviews: serde_json::Value) {
    Mock::given(method("GET"))
        .and(path(format!("/repos/{REPO}/pulls/{number}/reviews")))
        .respond_with(ResponseTemplate::new(200).set_body_json(reviews))
        .mount(server)
        .await;
}

/// The GraphQL probe's answer for one PR.
#[derive(Clone)]
struct Probe {
    number: u64,
    head_sha: String,
    author: (String, String),
    draft: bool,
    state: String,
    merged: bool,
    updated_at: String,
    review_decision: Option<String>,
    requested_reviewers: Vec<(String, String)>,
    reviews: Vec<(String, String, String)>,
}

impl Probe {
    fn new(number: u64, head_sha: &str) -> Self {
        Probe {
            number,
            head_sha: head_sha.to_owned(),
            author: ("alice".to_owned(), "User".to_owned()),
            draft: false,
            state: "OPEN".to_owned(),
            merged: false,
            updated_at: "2026-06-07T12:00:00Z".to_owned(),
            review_decision: Some("REVIEW_REQUIRED".to_owned()),
            requested_reviewers: Vec::new(),
            reviews: Vec::new(),
        }
    }

    fn body(&self) -> serde_json::Value {
        json!({"data": {"repository": {"pullRequest": {
            "number": self.number,
            "title": format!("PR {}", self.number),
            "url": format!("https://github.com/{REPO}/pull/{}", self.number),
            "isDraft": self.draft,
            "state": self.state,
            "merged": self.merged,
            "updatedAt": self.updated_at,
            "headRefOid": self.head_sha,
            "reviewDecision": self.review_decision,
            "author": {"login": self.author.0, "__typename": self.author.1},
            "reviewRequests": {"nodes": self.requested_reviewers.iter().map(|(login, ty)| json!({
                "requestedReviewer": {"__typename": ty, "login": login, "slug": login}
            })).collect::<Vec<_>>()},
            "reviews": {"nodes": self.reviews.iter().map(|(state, submitted, author)| json!({
                "state": state, "submittedAt": submitted, "author": {"login": author}
            })).collect::<Vec<_>>()},
        }}}})
    }
}

/// Mount the probe response for `probe.number`, matched on the PR number in the
/// GraphQL variables so several PRs can be probed in one test.
async fn mount_probe(server: &MockServer, probe: &Probe) {
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .and(body_string_contains(format!("\"number\":{}", probe.number)))
        .respond_with(ResponseTemplate::new(200).set_body_json(probe.body()))
        .mount(server)
        .await;
}

/// A probe that answers for any PR — for tests where the probe isn't the variable.
async fn mount_probe_raw(server: &MockServer, status: u16, body: serde_json::Value) {
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(ResponseTemplate::new(status).set_body_json(body))
        .mount(server)
        .await;
}

fn numbers(items: &[PrQueueItem]) -> Vec<u64> {
    items.iter().map(|i| i.number).collect()
}

fn bucket_of(items: &[PrQueueItem], number: u64) -> Option<&str> {
    items
        .iter()
        .find(|i| i.number == number)
        .map(|i| i.bucket.as_str())
}

// ═════════════════════════════════════════════════════════════════════════════
// Pure classification
// ═════════════════════════════════════════════════════════════════════════════

/// The whole event→action table, with no network in sight.
///
/// This is the contract the cost guarantees rest on: if an event type silently
/// reclassifies from `Ignore` to `Probe`, nothing breaks and nothing looks
/// wrong — the queue just quietly starts paying for org-wide noise again.
#[test]
fn classify_event_table() {
    let mut caches = QueueCaches::default();
    seed(&mut caches, candidate(42, "sha-known"));

    let known = 42;
    let unknown = 999;

    let known_key = (REPO.to_owned(), known);
    let unknown_key = (REPO.to_owned(), unknown);

    let cases: Vec<(&str, RelayEvent, Action)> = vec![
        // Terminal PR events: free either way.
        (
            "merged, in ledger",
            ev("pr.merged").num(known),
            Action::Remove {
                key: known_key.clone(),
            },
        ),
        (
            "closed, in ledger",
            ev("pr.closed").num(known),
            Action::Remove {
                key: known_key.clone(),
            },
        ),
        (
            "merged, unknown PR",
            ev("pr.merged").num(unknown),
            Action::Ignore,
        ),
        (
            "closed, unknown PR",
            ev("pr.closed").num(unknown),
            Action::Ignore,
        ),
        // Review requests are only about bucket 1, which is only about me.
        (
            "review_requested, someone else",
            ev("pr.review_requested").num(known).reviewer("bob"),
            Action::Ignore,
        ),
        (
            "review_requested, me",
            ev("pr.review_requested").num(unknown).reviewer(ME),
            Action::Probe {
                key: unknown_key.clone(),
            },
        ),
        (
            "review_request_removed, someone else",
            ev("pr.review_request_removed").num(known).reviewer("bob"),
            Action::Ignore,
        ),
        (
            "review_request_removed, me — not a blind removal",
            ev("pr.review_request_removed").num(known).reviewer(ME),
            Action::Probe {
                key: known_key.clone(),
            },
        ),
        // My own reviews.
        (
            "my comment changes no bucket",
            ev("pr.review_submitted")
                .num(known)
                .reviewer(ME)
                .review_state("commented"),
            Action::Ignore,
        ),
        (
            "my changes_requested",
            ev("pr.review_submitted")
                .num(known)
                .reviewer(ME)
                .review_state("changes_requested"),
            Action::LeaveBuckets12 {
                key: known_key.clone(),
            },
        ),
        (
            "my approval may not satisfy the branch requirement",
            ev("pr.review_submitted")
                .num(known)
                .reviewer(ME)
                .review_state("approved"),
            Action::Probe {
                key: known_key.clone(),
            },
        ),
        (
            "bot-suffixed reviewer still matches me",
            ev("pr.review_submitted")
                .num(known)
                .reviewer("TESTER")
                .review_state("commented"),
            Action::Ignore,
        ),
        // Someone else's review can only ever *remove* a PR from my queue.
        (
            "other's review, unknown PR",
            ev("pr.review_submitted")
                .num(unknown)
                .reviewer("bob")
                .review_state("approved"),
            Action::Ignore,
        ),
        (
            "other's review, known PR",
            ev("pr.review_submitted")
                .num(known)
                .reviewer("bob")
                .review_state("approved"),
            Action::Probe {
                key: known_key.clone(),
            },
        ),
        // A push or a new PR always warrants a read.
        (
            "synchronize",
            ev("pr.synchronize").num(known),
            Action::Probe {
                key: known_key.clone(),
            },
        ),
        (
            "opened",
            ev("pr.opened").num(unknown),
            Action::Probe {
                key: unknown_key.clone(),
            },
        ),
        (
            "reopened",
            ev("pr.reopened").num(unknown),
            Action::Probe {
                key: unknown_key.clone(),
            },
        ),
        // CI: matched by SHA, because ci.completed carries no PR number.
        (
            "ci for a candidate head",
            ev("ci.completed").sha("sha-known"),
            Action::CiOnly {
                repo: REPO.to_owned(),
                head_sha: "sha-known".to_owned(),
            },
        ),
        (
            "ci for an unknown SHA — the bulk of org noise",
            ev("ci.completed").sha("sha-nobody-cares"),
            Action::Ignore,
        ),
        ("ci with no SHA", ev("ci.completed"), Action::Ignore),
        (
            "ci for a candidate SHA in another repo",
            ev("ci.completed").sha("sha-known").repo("Carefeed/other"),
            Action::Ignore,
        ),
        // Malformed or unrecognised: ignored, never an error.
        (
            "unknown event type",
            ev("pr.labeled").num(known),
            Action::Ignore,
        ),
        (
            "wholly unknown type",
            ev("issue.commented").num(known),
            Action::Ignore,
        ),
        (
            "pr event with no number",
            ev("pr.synchronize"),
            Action::Ignore,
        ),
        (
            "event with no repo",
            RelayEvent {
                event_type: "pr.merged".to_owned(),
                number: Some(known),
                ..Default::default()
            },
            Action::Ignore,
        ),
    ];

    for (label, event, want) in cases {
        let got = classify_event(&event, ME, &caches);
        assert_eq!(got, want, "{label}: classified as {got:?}, want {want:?}");
    }
}

/// GraphQL's `Bot.login` omits the `[bot]` suffix REST adds.
///
/// Without normalising, the same PR would render a different `author` string
/// depending on which path last touched it — and `is_bot()` keys off that
/// string, so a dependabot PR would land in the wrong bucket.
#[test]
fn normalise_login_matches_rest_shape() {
    assert_eq!(normalise_login("dependabot", "Bot"), "dependabot[bot]");
    assert_eq!(normalise_login("alice", "User"), "alice");
    assert_eq!(
        normalise_login("dependabot[bot]", "Bot"),
        "dependabot[bot]",
        "already-suffixed logins must be left alone"
    );
    assert_eq!(
        normalise_login("some-team", "Team"),
        "some-team",
        "only Bot gets the suffix"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The divergence audit
// ═════════════════════════════════════════════════════════════════════════════

fn item(number: u64, bucket: &str, ci: CiState, sha: &str, new_activity: bool) -> PrQueueItem {
    PrQueueItem {
        repo: REPO.to_owned(),
        number,
        title: format!("PR {number}"),
        author: "alice".to_owned(),
        bucket: bucket.to_owned(),
        new_activity,
        url: format!("https://github.com/{REPO}/pull/{number}"),
        ci_state: ci,
        head_sha: sha.to_owned(),
        is_bot: false,
    }
}

fn audit_set(numbers: &[u64]) -> HashSet<(String, u64)> {
    numbers.iter().map(|n| (REPO.to_owned(), *n)).collect()
}

#[test]
fn diff_snapshots_reports_nothing_when_snapshots_agree() {
    let items = vec![item(1, "needs_review", CiState::Success, "a", false)];
    assert!(diff_snapshots(&items, &items, &audit_set(&[1])).is_empty());
}

/// The whole point of the audit: a systematically wrong targeted path otherwise
/// looks like a queue that is merely "a bit flickery", and nobody finds out.
#[test]
fn diff_snapshots_reports_bucket_change_inside_audit_set() {
    let targeted = vec![item(1, "needs_review", CiState::Success, "a", false)];
    let poll = vec![item(1, "changes_req", CiState::Success, "a", false)];

    let found = diff_snapshots(&targeted, &poll, &audit_set(&[1]));
    assert_eq!(found.len(), 1, "got {found:?}");
    assert_eq!(found[0].field, "bucket");
    assert_eq!(found[0].poll, "changes_req");
    assert_eq!(found[0].targeted, "needs_review");
    assert_eq!(found[0].number, 1);
}

/// A PR no targeted update touched differs because *GitHub* changed, not
/// because the targeted path was wrong. Auditing it would cry wolf every poll.
#[test]
fn diff_snapshots_ignores_differences_outside_audit_set() {
    let targeted = vec![item(1, "needs_review", CiState::Success, "a", false)];
    let poll = vec![item(1, "changes_req", CiState::Failure, "b", true)];
    assert!(diff_snapshots(&targeted, &poll, &audit_set(&[2])).is_empty());
}

#[test]
fn diff_snapshots_reports_presence_both_directions() {
    let present = vec![item(1, "needs_review", CiState::Success, "a", false)];
    let absent: Vec<PrQueueItem> = Vec::new();

    let dropped = diff_snapshots(&present, &absent, &audit_set(&[1]));
    assert_eq!(dropped.len(), 1);
    assert_eq!(dropped[0].field, "presence");
    assert_eq!(
        (dropped[0].targeted.as_str(), dropped[0].poll.as_str()),
        ("present", "absent")
    );

    let added = diff_snapshots(&absent, &present, &audit_set(&[1]));
    assert_eq!(added.len(), 1);
    assert_eq!(added[0].field, "presence");
    assert_eq!(
        (added[0].targeted.as_str(), added[0].poll.as_str()),
        ("absent", "present")
    );
}

/// Every diverging field is reported, not just the first — a wrong verdict
/// usually shows up in several at once and the log has to say which.
#[test]
fn diff_snapshots_reports_every_diverging_field() {
    let targeted = vec![item(1, "needs_review", CiState::Success, "a", false)];
    let poll = vec![item(1, "changes_req", CiState::Failure, "b", true)];

    let found = diff_snapshots(&targeted, &poll, &audit_set(&[1]));
    let fields: HashSet<&str> = found.iter().map(|d| d.field).collect();
    assert_eq!(
        fields,
        HashSet::from(["bucket", "new_activity", "ci_state", "head_sha"]),
        "got {found:?}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Prefetch scope
// ═════════════════════════════════════════════════════════════════════════════

/// A CI glyph flipping is the most frequent targeted change there is. If it
/// re-prefetched the top 3 every time, the "cheap targeted update" would quietly
/// cost three PR-detail fetches.
#[test]
fn prefetch_only_on_top_three_change() {
    let before = vec![
        item(1, "requested", CiState::Pending, "a", false),
        item(2, "needs_review", CiState::Success, "b", false),
        item(3, "needs_review", CiState::Success, "c", false),
    ];
    // Same three PRs, same order — only #1's glyph moved.
    let mut glyph_changed = before.clone();
    glyph_changed[0].ci_state = CiState::Success;

    assert!(
        prefetch_targets(&PrefetchScope::NewlyTopThree(&before), &glyph_changed).is_empty(),
        "a glyph change that doesn't reorder the top 3 must prefetch nothing"
    );

    // A new bucket-1 PR displaces #3 out of the top 3.
    let mut with_new = before.clone();
    with_new.insert(0, item(9, "requested", CiState::Success, "z", false));
    let picked = prefetch_targets(&PrefetchScope::NewlyTopThree(&before), &with_new);
    assert_eq!(
        picked.iter().map(|i| i.number).collect::<Vec<_>>(),
        vec![9],
        "only the PR that newly entered the top 3"
    );

    assert_eq!(
        prefetch_targets(&PrefetchScope::TopThree, &before).len(),
        3,
        "a full refresh still reconsiders the whole top 3"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Zero-traffic events
// ═════════════════════════════════════════════════════════════════════════════

/// A merged PR is never a member of any bucket — all three searches are
/// `is:open` — so removing it needs no confirmation from GitHub.
///
/// The user's expectation is blunt: a PR they just merged leaves the list, and
/// does not flicker back on the next poll while GitHub's search index catches up.
#[tokio::test]
async fn pr_merged_removes_pr_with_no_github_calls() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));
    assert_eq!(numbers(&h.items()), vec![42]);

    let before = calls(&server).await;
    let outcome = h.apply(&ev("pr.merged").num(42)).await;

    assert_eq!(outcome, Outcome::Changed);
    assert!(h.items().is_empty(), "merged PR must leave the snapshot");
    assert!(h.candidate(42).is_none(), "and leave the ledger");
    assert_eq!(
        calls(&server).await,
        before,
        "removing a merged PR must cost nothing at all"
    );

    // The index still lists it — but `/pulls/42` says closed, so the poll agrees.
    mount_searches(
        &server,
        vec![],
        vec![search_item(42, "alice", false, "2026-06-07T12:00:00Z")],
        vec![],
    )
    .await;
    mount_pr_detail(&server, 42, "sha-1", true).await;
    mount_check_runs_any(&server, "success").await;

    let snap = h.fetch().await;
    assert!(
        snap.items.is_empty(),
        "the next poll must not resurrect it; got {:?}",
        numbers(&snap.items)
    );
}

/// News about a PR the queue has never heard of is the common case on an
/// org-wide subscription, and it has to be genuinely free.
#[tokio::test]
async fn pr_closed_for_unknown_pr_is_a_true_noop() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));

    let before_items = h.items();
    let before = calls(&server).await;

    assert_eq!(h.apply(&ev("pr.closed").num(777)).await, Outcome::Unchanged);
    assert_eq!(h.items(), before_items);
    assert_eq!(calls(&server).await, before);
}

/// Bucket 1 is `review-requested:@me`. A request naming somebody else satisfies
/// neither that nor `review:required`, so it changes no bucket — and most review
/// requests in a busy org name somebody else.
#[tokio::test]
async fn review_requested_for_other_reviewer_is_ignored() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));

    let before_items = h.items();
    let before = calls(&server).await;

    for kind in ["pr.review_requested", "pr.review_request_removed"] {
        assert_eq!(
            h.apply(&ev(kind).num(42).reviewer("bob")).await,
            Outcome::Unchanged,
            "{kind} naming another reviewer"
        );
    }
    assert_eq!(h.items(), before_items);
    assert_eq!(calls(&server).await, before);
}

/// Leaving a comment doesn't move a PR between buckets, and shouldn't cost a
/// request to establish that.
#[tokio::test]
async fn my_commented_review_changes_nothing() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));

    let before_items = h.items();
    let before = calls(&server).await;

    let outcome = h
        .apply(
            &ev("pr.review_submitted")
                .num(42)
                .reviewer(ME)
                .review_state("commented"),
        )
        .await;

    assert_eq!(outcome, Outcome::Unchanged);
    assert_eq!(h.items(), before_items);
    assert_eq!(calls(&server).await, before);
}

/// Requesting changes takes the PR out of "not yet reviewed by me" — and must
/// *not* immediately put it into `changes_req`, because submitting a review bumps
/// the PR's own `updated_at` and the 30-second grace window exists precisely so
/// that doesn't read as "the author responded".
///
/// The PR comes back only when the author actually moves. That's the behaviour a
/// reviewer relies on to clear their queue after a review pass.
#[tokio::test]
async fn my_changes_requested_leaves_buckets_1_and_2_without_entering_bucket_3() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));

    let before = calls(&server).await;
    let outcome = h
        .apply(
            &ev("pr.review_submitted")
                .num(42)
                .reviewer(ME)
                .review_state("changes_requested")
                .delivered(at(2026, 6, 7, 12, 0, 0)),
        )
        .await;

    assert_eq!(outcome, Outcome::Changed);
    assert!(
        h.items().is_empty(),
        "the PR must leave the snapshot; got {:?}",
        h.items()
    );
    assert!(
        h.candidate(42).is_some(),
        "but stay a candidate — it comes back when the author responds"
    );
    assert_eq!(
        calls(&server).await,
        before,
        "the event says everything needed; no read required"
    );

    // Author pushes 90s later. The probe reports the new `updatedAt`, which is
    // >30s after the review, so the PR re-enters `changes_req`.
    let mut probe = Probe::new(42, "sha-2");
    probe.review_decision = None;
    probe.updated_at = "2026-06-07T12:01:30Z".to_owned();
    probe.reviews = vec![(
        "CHANGES_REQUESTED".to_owned(),
        "2026-06-07T12:00:00Z".to_owned(),
        ME.to_owned(),
    )];
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-2", "success").await;

    let outcome = h
        .apply(
            &ev("pr.synchronize")
                .num(42)
                .delivered(at(2026, 6, 7, 12, 1, 31)),
        )
        .await;
    assert_eq!(outcome, Outcome::Changed);

    let items = h.items();
    assert_eq!(bucket_of(&items, 42), Some("changes_req"), "got {items:?}");
    assert!(
        items[0].new_activity,
        "the author responded more than 30s after the review"
    );
    assert_eq!(
        calls(&server).await.search,
        before.search,
        "still no search"
    );
}

/// Other people's CI is the single highest-volume event class in the org. If it
/// cost anything, the relay would be a rate-limit liability rather than a
/// latency win.
#[tokio::test]
async fn ci_completed_for_unknown_sha_is_ignored() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));

    let before_items = h.items();
    let before = calls(&server).await;

    assert_eq!(
        h.apply(&ev("ci.completed").sha("some-other-sha")).await,
        Outcome::Unchanged
    );
    assert_eq!(h.items(), before_items);
    assert_eq!(calls(&server).await, before);
}

// ═════════════════════════════════════════════════════════════════════════════
// Scoped reads
// ═════════════════════════════════════════════════════════════════════════════

/// The honest one-call case, and the tightest cost assertion in the file.
///
/// The queue's CI state is a rollup over *all* checks on the SHA and the drop
/// filter is specifically "a GitHub Actions check failed", so one check's result
/// decides neither — the rollup has to be re-read. But one check finishing must
/// not perturb any other PR: no reordering, no field changes, nothing.
#[tokio::test]
async fn ci_completed_for_candidate_head_issues_exactly_one_non_search_request() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));
    let mut other = candidate(7, "sha-7");
    other.in_requested = true;
    other.in_needs_review = false;
    seed(&mut h.caches, other);

    mount_check_runs_for(&server, "sha-42", "failure").await;

    let before = calls(&server).await;
    let untouched_before = serde_json::to_string(
        &h.items()
            .into_iter()
            .filter(|i| i.number != 42)
            .collect::<Vec<_>>(),
    )
    .unwrap();

    let outcome = h.apply(&ev("ci.completed").sha("sha-42")).await;
    assert_eq!(outcome, Outcome::Changed);

    let after = calls(&server).await;
    assert_eq!(after.total - before.total, 1, "exactly one request");
    assert_eq!(
        after.check_runs - before.check_runs,
        1,
        "and it is check-runs"
    );
    assert_eq!(after.search, before.search, "zero search requests");
    assert_eq!(after.graphql, before.graphql, "zero GraphQL requests");

    // #42's Actions failure hides it; #7 must be byte-identical, order included.
    let items = h.items();
    assert_eq!(numbers(&items), vec![7], "got {items:?}");
    assert_eq!(
        serde_json::to_string(&items).unwrap(),
        untouched_before,
        "every other item must be untouched, fields and order"
    );
}

/// A PR excluded only because its CI was red is not in the snapshot but is very
/// much still relevant — one green run brings it back. That's why the ledger
/// records candidates it drops.
#[tokio::test]
async fn ci_completed_restores_candidate_hidden_only_by_red_ci() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    let mut hidden = candidate(42, "sha-42");
    hidden.ci_state = CiState::Failure;
    hidden.actions_failed = true;
    seed(&mut h.caches, hidden);
    assert!(h.items().is_empty(), "starts hidden by the CI filter");

    mount_check_runs_for(&server, "sha-42", "success").await;
    let before = calls(&server).await;

    assert_eq!(
        h.apply(&ev("ci.completed").sha("sha-42")).await,
        Outcome::Changed
    );

    let items = h.items();
    assert_eq!(numbers(&items), vec![42]);
    assert_eq!(items[0].ci_state, CiState::Success);
    assert_eq!(
        calls(&server).await.search,
        before.search,
        "zero search requests"
    );
}

/// The inverse of the test above: a CI read that *fails* — a transient 502/500,
/// a dropped connection, an unparseable body — used to be indistinguishable
/// from "nothing configured on this SHA" and get written into the ledger and
/// the cache as `(CiState::Unknown, false)`, un-hiding a PR that a genuinely red
/// CI was legitimately hiding for up to 60s on a mere transport hiccup. A
/// failed read must defer instead: the red verdict stands, and the cache must
/// not be poisoned with a bogus one.
#[tokio::test]
async fn ci_read_failure_defers_and_does_not_unhide_a_red_ci_pr() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    let mut hidden = candidate(42, "sha-42");
    hidden.ci_state = CiState::Failure;
    hidden.actions_failed = true;
    seed(&mut h.caches, hidden);
    assert!(h.items().is_empty(), "starts hidden by the CI filter");

    Mock::given(method("GET"))
        .and(path(format!("/repos/{REPO}/commits/sha-42/check-runs")))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;

    let outcome = h.apply(&ev("ci.completed").sha("sha-42")).await;

    assert_eq!(
        outcome,
        Outcome::Deferred,
        "a failed CI read must defer to the periodic poll, not write a verdict"
    );
    assert_eq!(
        h.candidate(42).unwrap().ci_state,
        CiState::Failure,
        "the red verdict must stand"
    );
    assert!(
        h.candidate(42).unwrap().actions_failed,
        "the Actions-failure flag must stand"
    );
    assert!(
        h.items().is_empty(),
        "the PR the red CI is hiding must stay hidden; got {:?}",
        h.items()
    );
    assert!(
        h.caches
            .ci_state_cache
            .lock()
            .unwrap()
            .get("sha-42")
            .is_none(),
        "a failed read must not poison the cache with a bogus verdict"
    );
}

/// A PR assigned to me appears immediately, even though GitHub's search index
/// hasn't listed it yet — the direct read is fresher than the index the poll uses.
#[tokio::test]
async fn review_requested_for_me_adds_pr_with_no_search_call() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    assert!(h.items().is_empty());

    let mut probe = Probe::new(42, "sha-42");
    probe.review_decision = None; // not bucket 2 — it's here on the request alone
    probe.requested_reviewers = vec![(ME.to_owned(), "User".to_owned())];
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-42", "success").await;

    let outcome = h
        .apply(&ev("pr.review_requested").num(42).reviewer(ME))
        .await;
    assert_eq!(outcome, Outcome::Changed);

    let items = h.items();
    assert_eq!(bucket_of(&items, 42), Some("requested"), "got {items:?}");
    assert_eq!(items[0].head_sha, "sha-42");
    assert_eq!(items[0].ci_state, CiState::Success);
    assert_eq!(items[0].author, "alice");
    assert!(!items[0].is_bot);

    let c = calls(&server).await;
    assert_eq!(c.search, 0, "no search endpoint may be touched");
    assert_eq!(c.graphql, 1, "one probe");
    assert!(
        c.check_runs <= 1,
        "at most one check-runs read, got {}",
        c.check_runs
    );
}

/// Dependabot PRs get their own bucket rather than being dropped, and the daemon
/// is the single source of truth for `is_bot` — so the targeted path has to
/// produce the REST-shaped login the bot list is keyed on.
#[tokio::test]
async fn review_requested_for_me_routes_a_bot_pr_to_the_dependabot_bucket() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);

    let mut probe = Probe::new(100, "bot-sha");
    probe.author = ("dependabot".to_owned(), "Bot".to_owned());
    probe.requested_reviewers = vec![(ME.to_owned(), "User".to_owned())];
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "bot-sha", "success").await;

    h.apply(&ev("pr.review_requested").num(100).reviewer(ME))
        .await;

    let items = h.items();
    assert_eq!(items.len(), 1, "got {items:?}");
    assert_eq!(items[0].bucket, "dependabot");
    assert!(items[0].is_bot);
    assert_eq!(
        items[0].author, "dependabot[bot]",
        "GraphQL omits the [bot] suffix REST adds; the paths must agree"
    );
    assert_eq!(calls(&server).await.search, 0);
}

/// Drafts and my own PRs are never mine to review. Probing establishes that, but
/// the PR must not end up in the snapshot — nor linger in the ledger, or every
/// later `ci.completed` on its head would start costing a request.
#[tokio::test]
async fn probing_a_pr_that_belongs_in_no_bucket_leaves_no_trace() {
    for (label, mutate) in [
        ("draft", (|p: &mut Probe| p.draft = true) as fn(&mut Probe)),
        ("self-authored", |p: &mut Probe| {
            p.author = (ME.to_owned(), "User".to_owned())
        }),
        (
            "no review requirement, not requested from me",
            |p: &mut Probe| p.review_decision = None,
        ),
    ] {
        let server = MockServer::start().await;
        let mut h = Harness::new(&server);

        let mut probe = Probe::new(42, "sha-42");
        mutate(&mut probe);
        mount_probe(&server, &probe).await;
        mount_check_runs_any(&server, "success").await;

        let outcome = h.apply(&ev("pr.opened").num(42)).await;

        assert_eq!(outcome, Outcome::Unchanged, "{label}");
        assert!(
            h.items().is_empty(),
            "{label}: must not appear in the snapshot"
        );
        assert!(
            h.candidate(42).is_none(),
            "{label}: and must not linger in the ledger"
        );
        assert_eq!(calls(&server).await.search, 0, "{label}");
    }
}

/// Un-requesting my review is *not* a removal: the PR may still qualify for
/// `needs_review` or `changes_req`, and dropping it would silently lose work.
#[tokio::test]
async fn review_request_removed_for_me_does_not_blindly_remove() {
    // Still `review:required` → stays, demoted to bucket 2.
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    let mut c = candidate(42, "sha-42");
    c.in_requested = true;
    c.in_needs_review = false;
    seed(&mut h.caches, c);
    assert_eq!(bucket_of(&h.items(), 42), Some("requested"));

    mount_probe(&server, &Probe::new(42, "sha-42")).await; // REVIEW_REQUIRED, no requests
    mount_check_runs_for(&server, "sha-42", "success").await;

    h.apply(&ev("pr.review_request_removed").num(42).reviewer(ME))
        .await;

    let items = h.items();
    assert_eq!(
        bucket_of(&items, 42),
        Some("needs_review"),
        "it still needs a review from somebody; got {items:?}"
    );
    assert_eq!(calls(&server).await.search, 0);

    // Already approved → it really is done, and leaves.
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    let mut c = candidate(42, "sha-42");
    c.in_requested = true;
    c.in_needs_review = false;
    seed(&mut h.caches, c);

    let mut probe = Probe::new(42, "sha-42");
    probe.review_decision = Some("APPROVED".to_owned());
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-42", "success").await;

    h.apply(&ev("pr.review_request_removed").num(42).reviewer(ME))
        .await;
    assert!(h.items().is_empty(), "got {:?}", h.items());
    assert_eq!(calls(&server).await.search, 0);
}

/// A push moves the head SHA, so CI must be re-read — and it supersedes any
/// just-approved suppression keyed to the old SHA. Clearing that entry stops a
/// force-push *back* to the approved SHA from silently re-hiding the PR.
#[tokio::test]
async fn synchronize_updates_head_sha_and_ci_and_clears_stale_suppression() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-old"));
    h.suppress
        .lock()
        .unwrap()
        .record(REPO, 42, "sha-old", unix_now_secs());
    assert!(h.items().is_empty(), "suppressed at the old SHA");

    mount_probe(&server, &Probe::new(42, "sha-new")).await;
    mount_check_runs_for(&server, "sha-new", "success").await;

    h.apply(&ev("pr.synchronize").num(42)).await;

    let items = h.items();
    assert_eq!(numbers(&items), vec![42]);
    assert_eq!(items[0].head_sha, "sha-new");
    assert_eq!(items[0].ci_state, CiState::Success);
    assert_eq!(
        h.suppress.lock().unwrap().recorded_sha(REPO, 42),
        None,
        "the suppression entry was keyed to a superseded SHA and must be gone"
    );
    assert_eq!(calls(&server).await.search, 0);
}

/// A red CI is the one exclusion a push routinely undoes, so this is the path
/// that decides whether "I fixed the build" shows up in the queue promptly.
#[tokio::test]
async fn synchronize_restores_candidate_that_only_red_ci_had_hidden() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    let mut hidden = candidate(42, "sha-old");
    hidden.ci_state = CiState::Failure;
    hidden.actions_failed = true;
    seed(&mut h.caches, hidden);
    assert!(h.items().is_empty());

    mount_probe(&server, &Probe::new(42, "sha-new")).await;
    mount_check_runs_for(&server, "sha-new", "success").await;

    h.apply(&ev("pr.synchronize").num(42)).await;

    assert_eq!(numbers(&h.items()), vec![42]);
    assert_eq!(calls(&server).await.search, 0);
}

/// Somebody else approving can end `review:required` and drop a PR out of bucket
/// 2. It can never *add* one — so this only ever needs to re-read the one PR.
#[tokio::test]
async fn other_users_review_reevaluates_only_that_pr() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));
    let mut other = candidate(7, "sha-7");
    other.seq = 0;
    seed(&mut h.caches, other);

    let untouched_before = serde_json::to_string(
        &h.items()
            .into_iter()
            .filter(|i| i.number != 42)
            .collect::<Vec<_>>(),
    )
    .unwrap();

    let mut probe = Probe::new(42, "sha-42");
    probe.review_decision = Some("APPROVED".to_owned());
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-42", "success").await;

    h.apply(
        &ev("pr.review_submitted")
            .num(42)
            .reviewer("bob")
            .review_state("approved"),
    )
    .await;

    let items = h.items();
    assert_eq!(numbers(&items), vec![7], "only #42 should have moved");
    assert_eq!(
        serde_json::to_string(&items).unwrap(),
        untouched_before,
        "#7 must be untouched"
    );
    assert_eq!(calls(&server).await.search, 0);
}

/// The user's answer to "what if a targeted update can't reach a verdict?" was:
/// do nothing and let the 60-second poll settle it. An immediate full-refresh
/// fallback would re-introduce three search calls for whichever events hit this
/// path — exactly the cost the engine exists to remove.
#[tokio::test]
async fn probe_failure_defers_and_issues_no_search_call() {
    let cases: Vec<(&str, u16, serde_json::Value)> = vec![
        ("HTTP 500", 500, json!({})),
        (
            "GraphQL errors array",
            200,
            json!({"data": null, "errors": [{"message": "rate limited"}]}),
        ),
        (
            "null pullRequest",
            200,
            json!({"data": {"repository": {"pullRequest": null}}}),
        ),
    ];

    for (label, status, body) in cases {
        let server = MockServer::start().await;
        let mut h = Harness::new(&server);
        seed(&mut h.caches, candidate(42, "sha-42"));
        let before_items = h.items();
        let before_sha = h.candidate(42).unwrap().head_sha.clone();

        mount_probe_raw(&server, status, body).await;

        let outcome = h.apply(&ev("pr.synchronize").num(42)).await;

        assert_eq!(outcome, Outcome::Deferred, "{label}");
        assert_eq!(
            h.items(),
            before_items,
            "{label}: snapshot must be untouched"
        );
        assert_eq!(
            h.candidate(42).unwrap().head_sha,
            before_sha,
            "{label}: ledger must be untouched"
        );
        assert_eq!(
            calls(&server).await.search,
            0,
            "{label}: no search fallback"
        );
    }
}

/// A wedged probe path (a token that lost a scope, sustained GitHub 5xx) is
/// invisible today: every failure defers quietly to the poll, so the queue
/// degrades to 60-second-poll-only latency for every event that would have
/// been settled by a probe, and nothing at info-or-above ever says so.
///
/// Three consecutive `Failed` outcomes for the same PR must produce exactly one
/// `warn!`. The first two are silent at WARN (only `debug!`). The warn names
/// the repo, the PR number, the failure kind, and the consecutive count — the
/// first four things you'd want when triaging "why did this take a minute to
/// show up".
///
/// NOTE for Cody: the implementation's `warn!` message must contain the
/// substring `"repeated probe failures"`, and its structured fields must
/// include the repo (bare, e.g. via `%repo`), `number=<n>`, a `kind` field
/// whose `Debug` rendering of the `ProbeFailure` appears verbatim (e.g.
/// `Status(500)`), and a `consecutive_failures=<n>` field. This test's
/// assertions are written against exactly that shape.
#[tokio::test]
async fn probe_failure_warns_after_three_consecutive_failures_then_resets() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));

    mount_probe_raw(&server, 500, json!({})).await;

    let logs = CapturedLogs::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(logs.clone())
        .with_ansi(false)
        .with_max_level(tracing::Level::WARN)
        .finish();
    // `apply` is async, so the subscriber has to stay the thread-local default
    // across `.await` points — `with_default`'s closure can't do that, but a
    // held `set_default` guard can.
    let _guard = tracing::subscriber::set_default(subscriber);

    let outcome1 = h.apply(&ev("pr.synchronize").num(42)).await;
    assert_eq!(outcome1, Outcome::Deferred, "1st failure");
    assert!(
        !logs.text().contains("repeated probe failures"),
        "must stay quiet after 1 consecutive failure; got:\n{}",
        logs.text()
    );

    let outcome2 = h.apply(&ev("pr.synchronize").num(42)).await;
    assert_eq!(outcome2, Outcome::Deferred, "2nd failure");
    assert!(
        !logs.text().contains("repeated probe failures"),
        "must stay quiet after 2 consecutive failures; got:\n{}",
        logs.text()
    );

    let outcome3 = h.apply(&ev("pr.synchronize").num(42)).await;
    assert_eq!(outcome3, Outcome::Deferred, "3rd failure");
    let text = logs.text();
    assert!(
        text.contains("repeated probe failures"),
        "the 3rd consecutive failure must warn; got:\n{text}"
    );
    assert!(
        text.contains(REPO),
        "the warn must name the repo; got:\n{text}"
    );
    assert!(
        text.contains("number=42"),
        "and the PR number; got:\n{text}"
    );
    assert!(
        text.contains("Status(500)"),
        "and the failure kind; got:\n{text}"
    );
    assert!(
        text.contains("consecutive_failures=3"),
        "and the consecutive count; got:\n{text}"
    );
    assert_eq!(calls(&server).await.search, 0, "no search fallback, ever");

    drop(_guard);

    // A successful probe must reset the counter to zero.
    server.reset().await;
    mount_check_runs_for(&server, "sha-42", "success").await;
    mount_probe(&server, &Probe::new(42, "sha-42")).await;

    let outcome4 = h.apply(&ev("pr.synchronize").num(42)).await;
    assert_eq!(outcome4, Outcome::Changed, "a clean probe must succeed");

    server.reset().await;
    mount_probe_raw(&server, 500, json!({})).await;

    let logs2 = CapturedLogs::default();
    let subscriber2 = tracing_subscriber::fmt()
        .with_writer(logs2.clone())
        .with_ansi(false)
        .with_max_level(tracing::Level::WARN)
        .finish();
    let _guard2 = tracing::subscriber::set_default(subscriber2);

    let outcome5 = h.apply(&ev("pr.synchronize").num(42)).await;
    assert_eq!(
        outcome5,
        Outcome::Deferred,
        "the lone failure after the reset"
    );
    assert!(
        !logs2.text().contains("repeated probe failures"),
        "a single failure right after a success must not warn — the counter \
         must have reset to 0; got:\n{}",
        logs2.text()
    );
}

/// The GraphQL response's echoed `pullRequest.number` used to be trusted
/// uncritically: `apply_probe` looks the candidate up by the *requested* key
/// (from the event), but `upsert_from_probe` writes under `probed.number` — the
/// number the response claims. A response naming a different PR (a caching
/// proxy artifact, a batching bug, a misbehaving fake) used to desync those two
/// keys: the ledger entry the caller thinks it just wrote is not the one that
/// changed. `probe_pr` must defer instead of building a `ProbedPr` when the
/// numbers disagree.
#[tokio::test]
async fn probe_number_mismatch_defers_instead_of_desyncing_the_ledger() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));
    let before_items = h.items();
    let before_sha = h.candidate(42).unwrap().head_sha.clone();
    let before_title = h.candidate(42).unwrap().title.clone();

    // Answers the GraphQL request for #42, but the body echoes PR #99.
    mount_probe_raw(&server, 200, Probe::new(99, "sha-x").body()).await;

    let outcome = h.apply(&ev("pr.synchronize").num(42)).await;

    assert_eq!(
        outcome,
        Outcome::Deferred,
        "a mismatched PR number must defer, not write"
    );
    assert_eq!(h.items(), before_items, "the snapshot must be untouched");
    assert_eq!(
        h.candidate(42).unwrap().head_sha,
        before_sha,
        "the ledger entry for #42 must be untouched"
    );
    assert_eq!(
        h.candidate(42).unwrap().title,
        before_title,
        "nothing about #42 changed, not merely head_sha"
    );
    assert!(
        h.candidate(99).is_none(),
        "the echoed number must not create a phantom ledger entry either"
    );
    assert_eq!(calls(&server).await.search, 0, "no search fallback");
}

// ═════════════════════════════════════════════════════════════════════════════
// Parity between the two paths
// ═════════════════════════════════════════════════════════════════════════════

/// **The most important test in this file.**
///
/// Two code paths that can bucket a PR are two chances to bucket it wrongly, and
/// the symptom — a list that reorders depending on which path last ran — reads as
/// an untrustworthy tool rather than as a bug. So: build one GitHub state, derive
/// the item once through the full fetch and once through a targeted
/// `pr.synchronize`, and demand they are equal field for field.
#[tokio::test]
async fn targeted_and_full_fetch_agree_on_changes_req_item() {
    // GitHub state: I requested changes at 11:00, the author pushed at 12:00.
    // That is bucket 3 with new_activity, via `has_new_activity`'s 30s window.
    const SHA: &str = "sha-b3";
    const REVIEWED_AT: &str = "2026-06-07T11:00:00Z";
    const UPDATED_AT: &str = "2026-06-07T12:00:00Z";

    let reviews_rest = json!([
        {"state": "APPROVED", "submitted_at": "2026-06-01T09:00:00Z", "user": {"login": ME}},
        {"state": "CHANGES_REQUESTED", "submitted_at": REVIEWED_AT, "user": {"login": ME}},
    ]);

    // ── via the full fetch ────────────────────────────────────────────────────
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    mount_user(&server).await;
    mount_searches(
        &server,
        vec![],
        vec![],
        vec![search_item(42, "alice", false, UPDATED_AT)],
    )
    .await;
    mount_reviews(&server, 42, reviews_rest).await;
    mount_pr_detail(&server, 42, SHA, false).await;
    mount_check_runs_for(&server, SHA, "success").await;

    let from_poll = h.fetch().await.items;
    assert_eq!(
        numbers(&from_poll),
        vec![42],
        "fixture should yield bucket 3"
    );
    assert_eq!(from_poll[0].bucket, "changes_req");
    assert!(from_poll[0].new_activity);

    // ── via a targeted pr.synchronize ─────────────────────────────────────────
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    // A ledger that predates the push: still in bucket 2, no review recorded.
    let mut stale = candidate(42, "sha-old");
    stale.updated_at = Some(REVIEWED_AT.to_owned());
    seed(&mut h.caches, stale);

    let mut probe = Probe::new(42, SHA);
    probe.review_decision = None;
    probe.updated_at = UPDATED_AT.to_owned();
    probe.reviews = vec![
        (
            "APPROVED".to_owned(),
            "2026-06-01T09:00:00Z".to_owned(),
            ME.to_owned(),
        ),
        (
            "CHANGES_REQUESTED".to_owned(),
            REVIEWED_AT.to_owned(),
            ME.to_owned(),
        ),
    ];
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, SHA, "success").await;

    h.apply(&ev("pr.synchronize").num(42)).await;
    let from_targeted = h.items();

    assert_eq!(
        from_targeted, from_poll,
        "the two paths must produce an identical item for identical GitHub state"
    );
    assert_eq!(
        calls(&server).await.search,
        0,
        "and the targeted one for free"
    );
}

/// The cache-coherence footgun, pinned.
///
/// `review_from_cache()` serves a cached review state only while
/// `last_seen_updated[k]` still equals the PR's `updated_at`. So a targeted change
/// that learns a review state **without** observing `updated_at` has to break that
/// pairing, or the next poll will serve a review state paired with a stale
/// timestamp and reach the wrong bucket-3 verdict.
#[tokio::test]
async fn last_seen_updated_invariant() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-1"));
    let key = (REPO.to_owned(), 42u64);
    h.caches
        .last_seen_updated
        .insert(key.clone(), "2026-06-07T12:00:00Z".to_owned());

    // The event carries a review state but no `updated_at` — break the pairing.
    h.apply(
        &ev("pr.review_submitted")
            .num(42)
            .reviewer(ME)
            .review_state("changes_requested"),
    )
    .await;

    assert!(
        h.caches.review_state_cache.contains_key(&key),
        "we do know my review state"
    );
    assert!(
        !h.caches.last_seen_updated.contains_key(&key),
        "but not the updated_at it pairs with — the pairing must be invalidated"
    );

    // A probe observes both in one read, so it may write both.
    let mut probe = Probe::new(42, "sha-2");
    probe.updated_at = "2026-06-07T13:00:00Z".to_owned();
    probe.reviews = vec![(
        "CHANGES_REQUESTED".to_owned(),
        "2026-06-07T11:00:00Z".to_owned(),
        ME.to_owned(),
    )];
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-2", "success").await;

    h.apply(&ev("pr.synchronize").num(42)).await;

    assert_eq!(
        h.caches.last_seen_updated.get(&key).map(String::as_str),
        Some("2026-06-07T13:00:00Z")
    );
    assert_eq!(
        h.caches.last_seen_updated.get(&key),
        h.candidate(42).unwrap().updated_at.as_ref(),
        "the cached updated_at must be the one the candidate was built from"
    );
    assert!(h.caches.review_state_cache.contains_key(&key));
}

/// A latent bug the second path exposed: without `per_page=100`, GitHub returns
/// the *oldest 30* reviews. On a PR with more than 30, the full fetch would pick a
/// superseded review while the probe's `reviews(last: 100)` picks the current one
/// — and the full-fetch side is simply wrong.
#[tokio::test]
async fn get_our_last_review_requests_per_page_100() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    mount_user(&server).await;
    mount_searches(
        &server,
        vec![],
        vec![],
        vec![search_item(42, "alice", false, "2026-06-07T12:00:00Z")],
    )
    .await;
    mount_reviews(
        &server,
        42,
        json!([{"state": "CHANGES_REQUESTED", "submitted_at": "2026-06-07T11:00:00Z", "user": {"login": ME}}]),
    )
    .await;
    mount_pr_detail(&server, 42, "sha-1", false).await;
    mount_check_runs_any(&server, "success").await;

    h.fetch().await;

    let reviews_requests: Vec<_> = server
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|r| r.url.path().ends_with("/reviews"))
        .collect();
    assert!(
        !reviews_requests.is_empty(),
        "the fixture must exercise bucket 3"
    );
    for r in &reviews_requests {
        assert_eq!(
            r.url.query(),
            Some("per_page=100"),
            "the reviews read must ask for 100, or it silently sees the oldest 30"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Dedup and ordering
// ═════════════════════════════════════════════════════════════════════════════

/// Relay delivery is at-most-once but not exactly-once. A redelivered event must
/// be free as well as harmless — checking dedup *before* classification is what
/// makes a duplicate `ci.completed` cost nothing rather than one request.
#[tokio::test]
async fn duplicate_event_id_applied_twice_matches_applying_once() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));
    mount_check_runs_for(&server, "sha-42", "failure").await;

    let event = ev("ci.completed").sha("sha-42").id(Some("evt-dup"));

    assert_eq!(h.apply(&event).await, Outcome::Changed);
    let after_once = h.items();
    let calls_once = calls(&server).await;

    assert_eq!(
        h.apply(&event).await,
        Outcome::Unchanged,
        "the redelivery must be dropped"
    );
    assert_eq!(h.items(), after_once, "same snapshot");
    assert_eq!(
        calls(&server).await,
        calls_once,
        "and the same request count"
    );
}

/// The relay does not guarantee ordering. A stale event overwriting a newer
/// verdict would show the user a PR state that has already been superseded, and
/// nothing would correct it until the next poll.
#[tokio::test]
async fn older_delivered_at_does_not_overwrite_newer_verdict() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-old"));

    let mut newer = Probe::new(42, "sha-new");
    newer.updated_at = "2026-06-07T12:05:00Z".to_owned();
    mount_probe(&server, &newer).await;
    mount_check_runs_for(&server, "sha-new", "success").await;

    h.apply(
        &ev("pr.synchronize")
            .num(42)
            .delivered(at(2026, 6, 7, 12, 5, 0)),
    )
    .await;
    assert_eq!(h.candidate(42).unwrap().head_sha, "sha-new");
    let after_newer = h.items();

    // An event from five minutes earlier arrives late. Its verdict is obsolete.
    let outcome = h
        .apply(&ev("pr.merged").num(42).delivered(at(2026, 6, 7, 12, 0, 0)))
        .await;

    assert_eq!(
        outcome,
        Outcome::Unchanged,
        "the older event must be dropped"
    );
    assert_eq!(h.items(), after_newer, "the newer verdict stands");
    assert!(h.candidate(42).is_some());
}

/// Ties are real — two checks can complete in the same second — so an equal
/// timestamp must be allowed through rather than treated as out-of-order.
#[tokio::test]
async fn equal_delivered_at_is_not_treated_as_out_of_order() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));
    let t = at(2026, 6, 7, 12, 0, 0);

    h.apply(&ev("ci.completed").sha("sha-42").delivered(t))
        .await;
    let outcome = h.apply(&ev("pr.merged").num(42).delivered(t)).await;

    assert_eq!(
        outcome,
        Outcome::Changed,
        "a same-instant event must still apply"
    );
    assert!(h.candidate(42).is_none());
}

// ═════════════════════════════════════════════════════════════════════════════
// Publishing
// ═════════════════════════════════════════════════════════════════════════════

/// Both paths publish through the same helper, so no consumer — the Swift UI, the
/// `review-prs` skill, the MCP tools — can tell which one produced a snapshot.
/// The on-disk cache is written before the watch send, so a reader woken by the
/// send always finds a file that already matches.
#[tokio::test]
async fn targeted_publish_writes_queue_cache_and_bumps_generated_at() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));

    let (tx, _rx) = tokio::sync::watch::channel(None::<PrQueueSnapshot>);
    let cache_path = h._dir.path().join(".queue.cache.json");

    let snap = PrQueueSnapshot {
        generated_at: Some(at(2026, 6, 7, 12, 0, 0)),
        items: h.items(),
        stale: false,
        error: None,
    };
    h.source
        .publish_snapshot(&tx, &h.client, snap, PrefetchScope::NewlyTopThree(&[]));

    let written: PrQueueSnapshot =
        serde_json::from_slice(&std::fs::read(&cache_path).expect("cache file must exist"))
            .unwrap();
    assert_eq!(numbers(&written.items), vec![42]);
    assert_eq!(written.generated_at, Some(at(2026, 6, 7, 12, 0, 0)));
    assert!(!written.stale);

    let published = tx.borrow().clone().expect("watch must carry the snapshot");
    assert_eq!(published.items, written.items);
}

// ═════════════════════════════════════════════════════════════════════════════
// Search-index-lag grace
// ═════════════════════════════════════════════════════════════════════════════

/// The bet this protects: a PR appears within ~3s of `pr.opened`, *before*
/// GitHub's search index lists it. Without the grace, the very next poll's
/// searches wouldn't return it and would yank it back out — a 60-second flicker
/// that defeats the whole point of reading the PR directly.
#[tokio::test]
async fn search_index_lag_grace_retains_recently_added_pr() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);

    // A qualifying PR arrives by relay.
    let probe = Probe::new(42, "sha-42");
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-42", "success").await;
    h.apply(&ev("pr.opened").num(42)).await;
    assert_eq!(numbers(&h.items()), vec![42]);

    // The poll's searches don't know about it yet.
    mount_user(&server).await;
    mount_searches(&server, vec![], vec![], vec![]).await;
    let before = calls(&server).await;

    let snap = h.fetch().await;

    assert_eq!(
        numbers(&snap.items),
        vec![42],
        "the PR must survive the poll that couldn't see it"
    );
    assert!(h
        .caches
        .last_grace_retained
        .contains(&(REPO.to_owned(), 42)));

    let after = calls(&server).await;
    assert_eq!(
        after.graphql - before.graphql,
        1,
        "the grace costs one re-probe"
    );
    assert_eq!(
        after.search - before.search,
        3,
        "and not one extra search beyond the poll's own three"
    );
}

/// The poll stays authoritative. The grace buys a recently-probed PR the benefit
/// of the doubt, not immunity: a re-probe saying it no longer qualifies drops it.
#[tokio::test]
async fn search_index_lag_grace_drops_a_pr_that_no_longer_qualifies() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);

    let mut probe = Probe::new(42, "sha-42");
    mount_probe(&server, &probe).await;
    mount_check_runs_for(&server, "sha-42", "success").await;
    h.apply(&ev("pr.opened").num(42)).await;
    assert_eq!(numbers(&h.items()), vec![42]);

    // Same PR, now merged — the re-probe says so.
    server.reset().await;
    mount_user(&server).await;
    mount_searches(&server, vec![], vec![], vec![]).await;
    probe.merged = true;
    probe.state = "MERGED".to_owned();
    mount_probe(&server, &probe).await;

    let snap = h.fetch().await;

    assert!(
        snap.items.is_empty(),
        "a re-probe that says it's gone must drop it; got {:?}",
        numbers(&snap.items)
    );
    assert!(h.caches.last_grace_retained.is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// Wake routing and the kill switch
// ═════════════════════════════════════════════════════════════════════════════

/// The four wake channels, senders kept alive alongside their receivers.
///
/// Holding every sender matters: `wait_for_wake` disables a `select!` branch
/// whose sender has been dropped, so a test that let one go would be measuring
/// the wrong thing.
struct WakeChannels {
    dirty_tx: tokio::sync::mpsc::UnboundedSender<()>,
    dirty_rx: tokio::sync::mpsc::UnboundedReceiver<()>,
    refresh_tx: tokio::sync::mpsc::UnboundedSender<()>,
    refresh_rx: tokio::sync::mpsc::UnboundedReceiver<()>,
    approvals_tx: tokio::sync::mpsc::UnboundedSender<()>,
    approvals_rx: tokio::sync::mpsc::UnboundedReceiver<()>,
    relay_tx: tokio::sync::mpsc::UnboundedSender<QueueSignal>,
    relay_rx: tokio::sync::mpsc::UnboundedReceiver<QueueSignal>,
}

impl WakeChannels {
    fn new() -> Self {
        let (dirty_tx, dirty_rx) = tokio::sync::mpsc::unbounded_channel();
        let (refresh_tx, refresh_rx) = tokio::sync::mpsc::unbounded_channel();
        let (approvals_tx, approvals_rx) = tokio::sync::mpsc::unbounded_channel();
        let (relay_tx, relay_rx) = tokio::sync::mpsc::unbounded_channel();
        WakeChannels {
            dirty_tx,
            dirty_rx,
            refresh_tx,
            refresh_rx,
            approvals_tx,
            approvals_rx,
            relay_tx,
            relay_rx,
        }
    }

    /// A generous interval, so a wake that falls through to the timer instead of
    /// firing on its branch is detectable by elapsed time rather than by hanging.
    async fn wait(&mut self, targeted_enabled: bool) -> Wake {
        wait_for_wake(
            &mut self.dirty_rx,
            &mut self.refresh_rx,
            &mut self.approvals_rx,
            &mut self.relay_rx,
            5,
            targeted_enabled,
        )
        .await
    }

    fn send_event(&self, event: RelayEvent) {
        self.relay_tx.send(QueueSignal::Event(event)).unwrap();
    }
}

/// `perri_targeted_relay = false` must restore the pre-engine behaviour exactly,
/// so the engine can be switched off in the field without a rebuild if its
/// per-PR verdicts ever turn out to disagree with the poll's.
///
/// This inherits the contract of the deleted `relay_signal_still_triggers_a_full_refresh`.
#[tokio::test]
async fn kill_switch_falls_back_to_full_refresh() {
    let mut ch = WakeChannels::new();

    ch.send_event(ev("ci.completed").sha("x"));
    let start = std::time::Instant::now();
    let wake = ch.wait(false).await;
    match wake {
        Wake::Full { reason, deferred } => {
            assert_eq!(reason, "relay_event");
            assert!(
                deferred.is_empty(),
                "with the engine off there is nothing to apply later"
            );
        }
        other => panic!("got {other:?}"),
    }
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "the timer won instead"
    );

    ch.relay_tx.send(QueueSignal::Reconnected).unwrap();
    let wake = ch.wait(false).await;
    assert!(
        matches!(
            wake,
            Wake::Full {
                reason: "relay_reconnect",
                ..
            }
        ),
        "got {wake:?}"
    );
}

/// With the engine on, a batch of events becomes a targeted update — and a
/// reconnect still reconciles, because the relay buffers nothing for an absent
/// subscriber and no event describes the gap. The batch is kept, not dropped:
/// those events may describe changes the reconciling searches are too stale to see.
#[tokio::test]
async fn relay_events_become_a_targeted_wake_and_a_reconnect_still_reconciles() {
    let mut ch = WakeChannels::new();

    ch.send_event(ev("pr.merged").num(1));
    ch.send_event(ev("pr.merged").num(2));
    let wake = ch.wait(true).await;
    match wake {
        Wake::Targeted(events) => {
            assert_eq!(
                events.iter().filter_map(|e| e.number).collect::<Vec<_>>(),
                vec![1, 2],
                "a burst must coalesce into one batch, in order"
            );
        }
        other => panic!("expected a targeted wake, got {other:?}"),
    }

    ch.relay_tx.send(QueueSignal::Reconnected).unwrap();
    ch.send_event(ev("pr.merged").num(3));
    let wake = ch.wait(true).await;
    match wake {
        Wake::Full { reason, deferred } => {
            assert_eq!(reason, "relay_reconnect");
            assert_eq!(
                deferred.iter().filter_map(|e| e.number).collect::<Vec<_>>(),
                vec![3],
                "the batch must be stashed for after the reconciling fetch, not discarded"
            );
        }
        other => panic!("got {other:?}"),
    }
}

/// A relay event describes a change GitHub's search index may not have picked up
/// yet, so discarding it because an unrelated dirty-file refresh happened to fire
/// first would lose news the fetch cannot recover.
#[tokio::test]
async fn relay_wake_does_not_discard_events_on_an_unrelated_full_refresh() {
    let mut ch = WakeChannels::new();

    // `tokio::select!` picks randomly among ready branches, so which one wins is
    // not the contract — what survives the wake is. Drive it until the dirty
    // branch happens to win, then assert.
    for attempt in 0..25 {
        ch.dirty_tx.send(()).unwrap();
        ch.send_event(ev("pr.opened").num(9));

        match ch.wait(true).await {
            // The relay branch won this round; the event was consumed legitimately.
            Wake::Targeted(_) => continue,
            Wake::Full {
                reason: "dirty", ..
            } => match ch.wait(true).await {
                Wake::Targeted(events) => {
                    assert_eq!(
                        events.iter().filter_map(|e| e.number).collect::<Vec<_>>(),
                        vec![9],
                        "the relay event must survive the unrelated refresh"
                    );
                    return;
                }
                other => panic!(
                    "attempt {attempt}: the relay event was dropped by the dirty wake; \
                         next wake was {other:?}"
                ),
            },
            other => panic!("attempt {attempt}: unexpected wake {other:?}"),
        }
    }
    panic!("the dirty branch never won in 25 attempts — select! is not fair");
}

// ═════════════════════════════════════════════════════════════════════════════
// The headline: search traffic vs. event volume
// ═════════════════════════════════════════════════════════════════════════════

/// A realistic ten minutes of Carefeed activity, as the org-wide subscription
/// sees it: mostly other people's CI, some PR churn on PRs that aren't mine, and
/// a handful of events about PRs actually in my queue.
async fn replay_org_activity(h: &mut Harness, server: &MockServer, count: usize) {
    // Anything the ~20 "touching the ledger" events probe must have an answer.
    mount_probe_raw(server, 200, Probe::new(42, "sha-42").body()).await;
    mount_check_runs_any(server, "success").await;

    for i in 0..count {
        let event = match i % 10 {
            // ~150/200: other people's CI, on SHAs no candidate heads.
            0..=6 => ev("ci.completed").sha(&format!("noise-sha-{i}")),
            // ~30/200: PR churn on PRs outside the candidate set.
            7 => ev("pr.merged").num(10_000 + i as u64),
            8 => ev("pr.review_requested")
                .num(20_000 + i as u64)
                .reviewer("bob"),
            // ~20/200: events about a PR that really is in my queue.
            _ => ev("ci.completed").sha("sha-42"),
        };
        h.apply(&event).await;
    }
}

/// **The acceptance criterion that defines this feature.**
///
/// Over any window, requests to the search endpoint must be a function of
/// elapsed time only. 200 relay events must cost exactly as many search calls as
/// zero — because a search-per-event queue on an org-wide subscription is one
/// busy afternoon away from a 403 in the middle of a review session, and a queue
/// that has stopped telling the truth is worse than a slow one.
#[tokio::test]
async fn search_calls_do_not_scale_with_relay_event_volume() {
    // Control: one poll, no events.
    let control = MockServer::start().await;
    let mut hc = Harness::new(&control);
    mount_user(&control).await;
    mount_searches(
        &control,
        vec![],
        vec![search_item(42, "alice", false, "2026-06-07T12:00:00Z")],
        vec![],
    )
    .await;
    mount_pr_detail(&control, 42, "sha-42", false).await;
    mount_check_runs_any(&control, "success").await;
    hc.fetch().await;
    let control_searches = calls(&control).await.search;
    assert_eq!(control_searches, 3, "a poll is three searches");

    // Same poll, then 200 events.
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    mount_user(&server).await;
    mount_searches(
        &server,
        vec![],
        vec![search_item(42, "alice", false, "2026-06-07T12:00:00Z")],
        vec![],
    )
    .await;
    mount_pr_detail(&server, 42, "sha-42", false).await;
    h.fetch().await;
    let after_poll = calls(&server).await;
    assert_eq!(after_poll.search, 3);

    replay_org_activity(&mut h, &server, 200).await;

    let after_events = calls(&server).await;
    assert_eq!(
        after_events.search, after_poll.search,
        "200 relay events must not add a single search request"
    );
    assert_eq!(
        after_events.search, control_searches,
        "and the total must match a run that replayed zero events"
    );
}

/// The zero-cost floor. Most of what an org-wide subscription delivers concerns
/// PRs the user will never review; if that traffic cost anything at all, the
/// relay would be a rate-limit liability rather than a latency win.
#[tokio::test]
async fn unrelated_event_burst_issues_no_github_requests() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);
    seed(&mut h.caches, candidate(42, "sha-42"));

    let before_items = h.items();
    let before = calls(&server).await;

    for i in 0..50u64 {
        // Every one of these is decidable from the event alone: a terminal PR is
        // never a queue member, a request naming someone else changes no bucket,
        // someone else's review can't add a PR I've never seen, and CI on a SHA
        // no candidate heads is not my business.
        let event = match i % 4 {
            0 => ev("pr.merged").num(30_000 + i),
            1 => ev("pr.review_requested").num(30_000 + i).reviewer("bob"),
            2 => ev("pr.review_submitted")
                .num(30_000 + i)
                .reviewer("carol")
                .review_state("approved"),
            _ => ev("ci.completed").sha(&format!("unrelated-{i}")),
        };
        assert_eq!(h.apply(&event).await, Outcome::Unchanged);
    }

    assert_eq!(h.items(), before_items, "the snapshot must not move");
    assert_eq!(
        calls(&server).await.total,
        before.total,
        "zero GitHub requests of any kind"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The divergence warn
// ═════════════════════════════════════════════════════════════════════════════

/// A `tracing` writer that keeps everything in memory.
#[derive(Clone, Default)]
struct CapturedLogs(Arc<Mutex<Vec<u8>>>);

impl CapturedLogs {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl std::io::Write for CapturedLogs {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for CapturedLogs {
    type Writer = CapturedLogs;
    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

/// Self-healing alone is not enough. Without this log, a systematically wrong
/// targeted path looks like a queue that is merely "a bit flickery" and nobody
/// ever finds out — so the disagreement has to be *audible*, naming the PR, the
/// field, and both verdicts.
///
/// The pure `diff_snapshots` tests above are the real contract; this one test
/// carries the brittle log assertion so the others don't have to.
#[tokio::test]
async fn divergence_warn_fires_on_disagreement() {
    let server = MockServer::start().await;
    let mut h = Harness::new(&server);

    // The targeted path says bucket 2; the poll says bucket 3.
    let targeted = PrQueueSnapshot {
        generated_at: Some(at(2026, 6, 7, 12, 0, 0)),
        items: vec![item(42, "needs_review", CiState::Success, "sha-42", false)],
        stale: false,
        error: None,
    };
    let poll = PrQueueSnapshot {
        items: vec![item(42, "changes_req", CiState::Success, "sha-42", true)],
        ..targeted.clone()
    };

    // Give the state a real applied event, so the log can quote what the
    // targeted path last acted on — the first thing you'd want when triaging.
    seed(&mut h.caches, candidate(42, "sha-42"));
    mount_probe(&server, &Probe::new(42, "sha-42")).await;
    mount_check_runs_for(&server, "sha-42", "success").await;
    h.apply(&ev("pr.synchronize").num(42).id(Some("evt-diverge")))
        .await;
    assert!(
        h.state.touched_since_poll.contains(&(REPO.to_owned(), 42)),
        "the probe should have put #42 in the audit set"
    );

    let logs = CapturedLogs::default();
    {
        let subscriber = tracing_subscriber::fmt()
            .with_writer(logs.clone())
            .with_ansi(false)
            .with_max_level(tracing::Level::WARN)
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            h.source
                .audit_divergence(&Some(targeted), &poll, &audit_set(&[42]), &h.state);
        });
    }

    let text = logs.text();
    assert!(
        text.contains("targeted update diverged from periodic poll"),
        "no divergence warn was emitted; captured:\n{text}"
    );
    assert!(
        text.contains(REPO),
        "the warn must name the repo; got:\n{text}"
    );
    assert!(
        text.contains("number=42"),
        "and the PR number; got:\n{text}"
    );
    assert!(
        text.contains("bucket"),
        "and the diverging field; got:\n{text}"
    );
    assert!(
        text.contains("poll_verdict=changes_req") && text.contains("targeted_verdict=needs_review"),
        "and both verdicts, labelled; got:\n{text}"
    );
    assert!(
        text.contains("evt-diverge") && text.contains("pr.synchronize"),
        "and what the targeted path last acted on; got:\n{text}"
    );
}

/// The audit is a diff of two lists the daemon already holds. If it ever started
/// re-reading GitHub to check itself, it would reintroduce the per-event cost the
/// engine exists to remove.
#[tokio::test]
async fn divergence_audit_issues_no_github_request() {
    let server = MockServer::start().await;
    let h = Harness::new(&server);

    let targeted = PrQueueSnapshot {
        generated_at: Some(at(2026, 6, 7, 12, 0, 0)),
        items: vec![item(42, "needs_review", CiState::Success, "sha-42", false)],
        stale: false,
        error: None,
    };
    let poll = PrQueueSnapshot {
        items: vec![item(42, "changes_req", CiState::Failure, "other", true)],
        ..targeted.clone()
    };

    let before = calls(&server).await;
    h.source
        .audit_divergence(&Some(targeted), &poll, &audit_set(&[42]), &h.state);
    assert_eq!(calls(&server).await, before);
}

/// Nothing to compare against is not a divergence. Warning on the first poll
/// after startup, or after a failed fetch left the snapshot stale, would train
/// the reader to ignore the log.
#[tokio::test]
async fn divergence_audit_stays_quiet_without_a_trustworthy_baseline() {
    let server = MockServer::start().await;
    let h = Harness::new(&server);

    let poll = PrQueueSnapshot {
        generated_at: Some(at(2026, 6, 7, 12, 0, 0)),
        items: vec![item(42, "changes_req", CiState::Success, "sha-42", true)],
        stale: false,
        error: None,
    };
    let stale_prev = PrQueueSnapshot {
        items: vec![item(42, "needs_review", CiState::Success, "sha-42", false)],
        stale: true,
        ..poll.clone()
    };
    let errored_prev = PrQueueSnapshot {
        stale: false,
        error: Some("boom".to_owned()),
        ..stale_prev.clone()
    };
    let healthy_prev = PrQueueSnapshot {
        stale: false,
        error: None,
        ..stale_prev.clone()
    };

    for (label, prev, set) in [
        ("no prior snapshot", None, audit_set(&[42])),
        ("stale prior snapshot", Some(stale_prev), audit_set(&[42])),
        (
            "errored prior snapshot",
            Some(errored_prev),
            audit_set(&[42]),
        ),
        ("nothing was touched", Some(healthy_prev), HashSet::new()),
    ] {
        let logs = CapturedLogs::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer(logs.clone())
            .with_ansi(false)
            .with_max_level(tracing::Level::WARN)
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            h.source.audit_divergence(&prev, &poll, &set, &h.state);
        });
        assert!(
            logs.text().is_empty(),
            "{label}: expected silence, got:\n{}",
            logs.text()
        );
    }
}

/// One logical change can touch several non-relay signals — `perri.clear_current_pr`
/// writes the dirty sentinel *and* pushes on the MCP refresh channel. Without the
/// post-select drain that is two wakes and two full fetches, i.e. six search
/// calls, for one change.
///
/// The inline regression tests in `perri_queue_native` pin the `select!` shape;
/// this one pins the real `wait_for_wake` that the run loop actually calls.
#[tokio::test]
async fn non_relay_signals_coalesce_into_one_full_wake() {
    let mut ch = WakeChannels::new();

    ch.dirty_tx.send(()).unwrap();
    ch.refresh_tx.send(()).unwrap();
    ch.approvals_tx.send(()).unwrap();

    let start = std::time::Instant::now();
    let wake = ch.wait(true).await;
    assert!(matches!(wake, Wake::Full { .. }), "got {wake:?}");
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "a pending signal must wake immediately, not wait out the interval"
    );

    // Nothing left over: a second wait has to fall through to the timer.
    let start = std::time::Instant::now();
    let wake = tokio::time::timeout(Duration::from_millis(600), ch.wait(true)).await;
    assert!(
        wake.is_err(),
        "a leftover signal produced a second wake ({:?} after {:?}) — the three \
         signals were not coalesced",
        wake,
        start.elapsed()
    );
}
