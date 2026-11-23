//! The Merge verb of the author's PR list, from outside: the real engine feeds
//! the PR list from a fake GitHub (see `support/authored_prs_rig.rs`) on paused
//! time, the verb is called the way the daemon calls it, and what is checked is
//! the answer code and the requests the fake GitHub received.
//!
//! * A PR is squash-merged, now, with the daemon's token, when and only when a
//!   human approved it, its checks pass, GitHub says it is clean, the head is
//!   the one the app showed, and Perri approved that exact head. The merge
//!   request carries the head `sha` and no other parameter.
//! * Every other situation answers with its own code and sends no merge
//!   request. The verb never trusts the cached row: it reads the PR again.
//! * GitHub's answer to the merge maps to a code; nothing GitHub says reaches
//!   the answer or a log.
//! * One request id gets one answer; a second merge of a PR already being
//!   merged is `busy`.
//! * Only the verified operator app reaches the verb; anyone else is refused
//!   and nothing reaches GitHub.
//! * The Welcome advertises the capability only when it is wired.

#[path = "support/authored_prs_rig.rs"]
mod rig;

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Duration as Chrono;
use nostromo::data::authored_prs::ownership::PrKey;
use nostromo::data::authored_prs::snapshot::{Lifecycle, MergeVia, PollState, QueueState};
use nostromo::data::authored_prs::verdicts::{Verdict, VerdictRecord};
use nostromo::ipc::{
    codec::{read_frame, write_frame},
    decisions::DecisionRegistry,
    peer_verify::testing::FakePeerVerifier,
    protocol::{ClientMsg, ServerMsg, PROTOCOL_VERSION},
    server::Server,
    SessionManager,
};
use rig::*;
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};
use wiremock::MockServer;

const REPO: &str = "canary-org/canary-repo";
const N: u64 = 424242;
const TITLE: &str = "CANARY-TITLE-Zq81";

/// A full head commit of `c` repeated.
fn sha(c: char) -> String {
    c.to_string().repeat(40)
}

/// What the app shows of it.
fn short(c: char) -> String {
    c.to_string().repeat(8)
}

/// A PR the merge may take: a human approved, the checks pass, GitHub says it
/// is clean, at head `aaaa…`.
fn ready_pr(number: u64) -> FakePr {
    FakePr::new(REPO, number)
        .title(TITLE)
        .head("feat/x", &sha('a'))
        .passing("build")
        .approved_by("alice")
}

/// Capture this test's log lines (see `capture_logs` for why a process-wide
/// subscriber backs it).
fn logs() -> (Captured, tracing::subscriber::DefaultGuard) {
    capture_logs()
}

fn without_reviews(mut pr: FakePr) -> FakePr {
    pr.reviews.clear();
    pr
}

/// The engine over `fake`, visible and settled.
async fn boot(fake: Fake) -> Rig {
    drop(logs());
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig
}

async fn start(prs: Vec<FakePr>) -> Rig {
    let fake = Fake::new();
    for p in prs {
        fake.put(p);
    }
    boot(fake).await
}

/// Perri's verdict on `head`, recorded the way the MCP tool records it, with
/// the engine given time to publish it.
async fn record(rig: &mut Rig, number: u64, head: &str, verdict: Verdict) {
    if verdict == Verdict::Approved {
        // The tool checks an approval against GitHub's live head (see
        // `authored_prs_verdicts` and `mcp_perri_record_verdict`); the merge's
        // own check is tested against what such a record is: one made while
        // that head was current. So it goes into the store directly, with no
        // extra request in the fake's log, and the engine is told as the tool does.
        let rec = VerdictRecord::new(
            REPO,
            number,
            head,
            verdict,
            chrono::Utc::now(),
            Some("perri"),
            None,
        )
        .expect("a valid record");
        rig.verdicts.record(rec);
        rig.demand.pr_changed(PrKey {
            repo: REPO.to_ascii_lowercase(),
            number,
        });
    } else {
        rig.actions
            .record_verdict(REPO, number, head, verdict, Some("perri"), None)
            .await
            .expect("a valid record");
    }
    rig.run(secs(3), Duration::from_millis(500)).await;
}

fn merge_requests_for(rig: &Rig, number: u64) -> Vec<Req> {
    let path = format!("/repos/{REPO}/pulls/{number}/merge");
    rig.fake
        .merges()
        .into_iter()
        .filter(|r| r.path == path)
        .collect()
}

fn failing_check(pr: &mut FakePr) {
    pr.checks
        .push(("lint".into(), "COMPLETED".into(), Some("FAILURE".into())));
}

// ═════════════════════════════════════════════════════════════════════════════
// The happy path
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_human_approved_green_clean_pr_whose_exact_head_perri_approved_is_squash_merged_with_the_head_sha_and_nothing_else(
) {
    let (log, _guard) = logs();
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    assert_eq!(
        rig.row(REPO, N).unwrap().head_sha_short.as_deref(),
        Some(short('a').as_str()),
        "the row shows the head the app will name"
    );

    let mark = rig.fake.log_len();
    let answer = rig.merge("req-1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");

    // Exactly one merge request, to the PR's own endpoint.
    let merges = rig.fake.merges();
    assert_eq!(merges.len(), 1, "{merges:?}");
    let m = &merges[0];
    assert_eq!(m.method, "PUT");
    assert_eq!(m.path, format!("/repos/{REPO}/pulls/{N}/merge"));
    assert_eq!(
        m.auth.as_deref(),
        Some(format!("Bearer {TOKEN}").as_str()),
        "the daemon's own token"
    );
    // The body is the method and the head, and nothing else: no admin or
    // bypass flag, no commit text.
    let body: Value = serde_json::from_str(&m.body).expect("a JSON body");
    let keys: BTreeSet<&str> = body
        .as_object()
        .expect("an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(keys, BTreeSet::from(["merge_method", "sha"]), "{body}");
    assert_eq!(body["merge_method"], "squash");
    assert_eq!(body["sha"], sha('a').as_str(), "the full live head");

    // The PR was read from GitHub right before it was merged.
    let since = rig.since(mark);
    let read_at = since
        .iter()
        .position(|r| r.kind() == Kind::Graphql && r.graphql_query().contains("mergeStateStatus"))
        .expect("a live read that asks for GitHub's merge state");
    let put_at = since.iter().position(|r| r.kind() == Kind::Merge).unwrap();
    assert!(read_at < put_at, "read first, then merge");

    // The row turns merged without waiting for the next poll (a minute away).
    let seen = rig
        .run_until(secs(20), Duration::from_millis(250), |r| {
            r.row(REPO, N)
                .is_some_and(|p| p.lifecycle == Lifecycle::Merged)
        })
        .await;
    assert!(seen.is_some(), "the row never turned merged");
    let fake_log = rig.fake.log();
    let put_idx = fake_log
        .iter()
        .position(|r| r.kind() == Kind::Merge)
        .unwrap();
    assert!(
        fake_log[put_idx + 1..]
            .iter()
            .any(|r| r.kind() == Kind::Graphql),
        "the PR was read again after the merge"
    );

    // The audit line names the repo, the number and the short head; nothing
    // else about the PR, and never the token.
    let text = log.text();
    let line = text
        .lines()
        .find(|l| l.contains("authored-pr merged"))
        .unwrap_or_else(|| panic!("no audit line in:\n{text}"));
    assert!(line.contains(REPO), "{line}");
    assert!(line.contains(&N.to_string()), "{line}");
    assert!(line.contains(&short('a')), "{line}");
    assert!(
        !line.contains(&sha('a')),
        "only the short head is logged: {line}"
    );
    for secret in [TOKEN, TITLE, CANARY_BODY, INJECTION] {
        assert!(!text.contains(secret), "{secret} reached a log");
    }
    assert!(!text.contains(&sha('a')), "the full head reached a log");
}

// ═════════════════════════════════════════════════════════════════════════════
// Every missing precondition has its own code and sends no merge request
// ═════════════════════════════════════════════════════════════════════════════

/// (name, the PR, the verdicts recorded as (head letter, verdict)).
type Scenario = (&'static str, FakePr, Vec<(char, Verdict)>);
type Build = Arc<dyn Fn(FakePr) -> FakePr>;
type Flip = Arc<dyn Fn(&mut FakePr)>;

#[derive(Clone)]
struct Case {
    name: &'static str,
    want: &'static str,
    build: Option<Build>,
    /// Verdicts recorded, in order, as (head letter, verdict).
    verdicts: Vec<(char, Verdict)>,
    /// What the app says the head is.
    expected: String,
    /// Changes made on GitHub after the engine read the PR, so the cached row
    /// is stale when the verb is called.
    flip: Option<Flip>,
}

fn case(name: &'static str, want: &'static str) -> Case {
    Case {
        name,
        want,
        build: None,
        verdicts: vec![('a', Verdict::Approved)],
        expected: short('a'),
        flip: None,
    }
}

impl Case {
    fn pr(mut self, f: impl Fn(FakePr) -> FakePr + 'static) -> Self {
        self.build = Some(Arc::new(f));
        self
    }
    fn verdicts(mut self, v: &[(char, Verdict)]) -> Self {
        self.verdicts = v.to_vec();
        self
    }
    fn expecting(mut self, short: &str) -> Self {
        self.expected = short.to_owned();
        self
    }
    fn then_on_github(mut self, f: impl Fn(&mut FakePr) + 'static) -> Self {
        self.flip = Some(Arc::new(f));
        self
    }
}

/// Each case is its own PR (`1000 + index`) on one rig; run them all and check
/// the code each gets. Every rule must hold on both ways in: a direct merge, and
/// the merge queue (a base branch with a queue, the app having worded the
/// confirmation for it).
async fn run_cases(cases: Vec<Case>) -> Rig {
    // One rig (time can be frozen once per test): direct PRs are `1000 + index`,
    // queue PRs `2000 + index`.
    let fake = Fake::new();
    let ways = [(MergeVia::Direct, 1000u64), (MergeVia::Queue, 2000u64)];
    for (via, first) in ways {
        for (i, c) in cases.iter().enumerate() {
            let base = ready_pr(first + i as u64);
            let base = if via == MergeVia::Queue {
                base.with_merge_queue()
            } else {
                base
            };
            fake.put(match &c.build {
                Some(f) => f(base),
                None => base,
            });
        }
    }
    let mut rig = boot(fake.clone()).await;
    for (_, first) in ways {
        for (i, c) in cases.iter().enumerate() {
            for (head, verdict) in &c.verdicts {
                record(&mut rig, first + i as u64, &sha(*head), *verdict).await;
            }
        }
    }
    for (_, first) in ways {
        for (i, c) in cases.iter().enumerate() {
            if let Some(flip) = &c.flip {
                fake.edit(REPO, first + i as u64, |p| flip(p));
            }
        }
    }
    for (via, first) in ways {
        for (i, c) in cases.iter().enumerate() {
            let n = first + i as u64;
            let answer = rig
                .merge_via(&format!("req-{n}"), REPO, n, &c.expected, via)
                .await;
            assert_eq!(
                code_of(&answer),
                c.want,
                "{} ({via:?}): wanted {}, got {answer:?}",
                c.name,
                c.want
            );
            assert!(
                merge_requests_for(&rig, n).is_empty(),
                "{} ({via:?}): a merge request was sent",
                c.name
            );
        }
    }
    // Every rule holds on both ways in: whatever the code, neither a merge
    // request nor an enqueue mutation reached GitHub.
    assert!(rig.fake.merges().is_empty(), "no merge request, ever");
    assert!(rig.fake.enqueues().is_empty(), "no enqueue, ever");
    rig
}

#[tokio::test]
async fn each_state_of_the_pr_that_forbids_a_merge_answers_its_own_code() {
    run_cases(vec![
        case("a draft", "draft").pr(|p| p.draft()),
        case("conflicting", "not_mergeable").pr(|p| p.mergeable("CONFLICTING")),
        case("mergeability not yet known", "not_mergeable").pr(|p| p.mergeable("UNKNOWN")),
        case("nobody has reviewed", "not_approved").pr(without_reviews),
        case("a review is only requested", "not_approved")
            .pr(|p| without_reviews(p).review_requested_of("bob")),
        case("changes requested and nothing else", "not_approved")
            .pr(|p| without_reviews(p).changes_requested_by("bob")),
        case("approved but a reviewer wants changes", "not_approved")
            .pr(|p| p.changes_requested_by("bob")),
        case("only a bot approved", "not_approved")
            .pr(|p| without_reviews(p).approved_by_bot("dependabot[bot]")),
        case("only a bot account approved", "not_approved")
            .pr(|p| without_reviews(p).approved_by_bot("release-helper")),
        case("a check is failing", "checks_not_green").pr(|p| p.failing("lint")),
        case("a check is pending", "checks_not_green").pr(|p| p.pending("deploy")),
        case("GitHub says behind", "behind").pr(|p| p.merge_state("BEHIND")),
        case("GitHub says blocked", "blocked").pr(|p| p.merge_state("BLOCKED")),
        case("GitHub says unstable", "checks_not_green").pr(|p| p.merge_state("UNSTABLE")),
        case("GitHub says dirty", "not_mergeable").pr(|p| p.merge_state("DIRTY")),
        case("GitHub says unknown", "not_mergeable").pr(|p| p.merge_state("UNKNOWN")),
        case("GitHub says draft", "draft").pr(|p| p.merge_state("DRAFT")),
        case("a state GitHub added later", "not_mergeable").pr(|p| p.merge_state("SOMETHING_NEW")),
        case("a closed PR", "not_open").then_on_github(|p| p.state = "CLOSED".into()),
        case("a merged PR", "not_open").then_on_github(|p| {
            p.state = "MERGED".into();
            p.merged = true;
        }),
    ])
    .await;
}

#[tokio::test]
async fn perri_must_have_approved_the_exact_head_and_a_verdict_for_any_other_head_never_counts() {
    use Verdict::*;
    run_cases(vec![
        case("Perri has said nothing", "perri_not_approved").verdicts(&[]),
        case("Perri asked for changes to this head", "perri_not_approved")
            .verdicts(&[('a', ChangesRequested)]),
        case("Perri only commented on this head", "perri_not_approved").verdicts(&[('a', Comment)]),
        case(
            "Perri approved then asked for changes to this head",
            "perri_not_approved",
        )
        .verdicts(&[('a', Approved), ('a', ChangesRequested)]),
        case(
            "Perri approved an older head and has said nothing of this one",
            "perri_stale",
        )
        .verdicts(&[('b', Approved)]),
        case(
            "Perri asked for changes to an older head only",
            "perri_stale",
        )
        .verdicts(&[('b', ChangesRequested)]),
        case(
            "Perri approved two older heads, neither is this one",
            "perri_stale",
        )
        .verdicts(&[('b', Approved), ('c', Approved)]),
        case(
            "an older approval does not rescue a current request for changes",
            "perri_not_approved",
        )
        .verdicts(&[('b', Approved), ('a', ChangesRequested)]),
    ])
    .await;
}

#[tokio::test]
async fn the_head_the_app_showed_must_be_the_head_merged() {
    use Verdict::*;
    run_cases(vec![
        case("the app showed another head", "head_changed").expecting("deadbeef"),
        case("the app showed the head in capitals", "head_changed").expecting("AAAAAAAA"),
        case("the app showed seven digits", "head_changed").expecting(&short('a')[..7]),
        case("the app showed nine digits", "head_changed").expecting(&format!("{}a", short('a'))),
        case("the app showed nothing", "head_changed").expecting(""),
        case("the app showed the whole head", "head_changed").expecting(&sha('a')),
        case(
            "the head moved on GitHub after the list was read and Perri approved the old one",
            "head_changed",
        )
        .then_on_github(|p| p.head_sha = "d".repeat(40)),
        case(
            "the head moved on GitHub and Perri approved both",
            "head_changed",
        )
        .verdicts(&[('a', Approved), ('d', Approved)])
        .then_on_github(|p| p.head_sha = "d".repeat(40)),
    ])
    .await;
}

#[tokio::test]
async fn a_green_cached_row_is_not_believed_when_github_now_says_otherwise() {
    run_cases(vec![
        case(
            "checks started failing after the list was read",
            "checks_not_green",
        )
        .then_on_github(failing_check),
        case(
            "the approval was dismissed after the list was read",
            "not_approved",
        )
        .then_on_github(|p| p.reviews.clear()),
        case("the PR went back to draft after the list was read", "draft")
            .then_on_github(|p| p.draft = true),
        case(
            "a conflict appeared after the list was read",
            "not_mergeable",
        )
        .then_on_github(|p| p.mergeable = "CONFLICTING".into()),
        case("the branch fell behind after the list was read", "behind")
            .then_on_github(|p| p.merge_state_status = "BEHIND".into()),
        case(
            "the PR became inaccessible after the list was read",
            "not_found",
        )
        .then_on_github(|p| p.accessible = false),
    ])
    .await;
}

#[tokio::test]
async fn when_several_things_are_wrong_the_code_follows_the_documented_order() {
    run_cases(vec![
        case("a draft with a failing check says draft", "draft").pr(|p| p.draft().failing("lint")),
        case("a conflict beats a missing approval", "not_mergeable")
            .pr(|p| without_reviews(p).mergeable("CONFLICTING")),
        case("a missing approval beats a failing check", "not_approved")
            .pr(|p| without_reviews(p).failing("lint")),
        case(
            "a failing check beats GitHub being behind",
            "checks_not_green",
        )
        .pr(|p| p.failing("lint").merge_state("BEHIND")),
        case(
            "the PR's state is judged before the head",
            "checks_not_green",
        )
        .pr(|p| p.failing("lint"))
        .expecting("deadbeef"),
        case("the head is judged before Perri", "head_changed")
            .verdicts(&[])
            .expecting("deadbeef"),
    ])
    .await;
}

#[tokio::test]
async fn a_pr_that_is_not_in_the_list_is_not_found_and_nothing_is_sent_to_github() {
    let fake = Fake::new();
    fake.put(ready_pr(N));
    // On GitHub, but not in the author's list (not found by the search).
    fake.put(ready_pr(N + 1).out_of_search());
    let mut rig = boot(fake).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    record(&mut rig, N + 1, &sha('a'), Verdict::Approved).await;

    let mark = rig.fake.log_len();
    for (what, repo, number) in [
        ("a PR number nobody has", REPO, N + 99),
        ("a PR of GitHub's not in the list", REPO, N + 1),
        ("another repo", "other-org/other-repo", N),
        ("number zero", REPO, 0),
        ("no slash", "canary-repo", N),
        ("an empty repo", "", N),
        ("too many slashes", "canary-org/canary-repo/extra", N),
        ("a traversal", "canary-org/../canary-repo", N),
        ("a space", "canary-org/canary repo", N),
    ] {
        let answer = rig
            .merge(&format!("nf-{what}"), repo, number, &short('a'))
            .await;
        assert_eq!(code_of(&answer), "not_found", "{what}: {answer:?}");
    }
    assert_eq!(
        rig.since(mark).len(),
        0,
        "nothing at all was sent to GitHub"
    );
}

#[tokio::test]
async fn the_repo_may_be_named_in_any_case() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    let answer = rig.merge("r1", &REPO.to_uppercase(), N, &short('a')).await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
    assert_eq!(merge_requests_for(&rig, N).len(), 1);
}

#[tokio::test]
async fn a_pr_the_list_already_shows_as_merged_or_closed_is_not_open() {
    let fake = Fake::new();
    fake.put(ready_pr(1));
    fake.put(ready_pr(2));
    let mut rig = boot(fake.clone()).await;
    record(&mut rig, 1, &sha('a'), Verdict::Approved).await;
    record(&mut rig, 2, &sha('a'), Verdict::Approved).await;

    // GitHub merged one and closed the other; the engine reads that.
    fake.edit(REPO, 1, |p| {
        p.state = "MERGED".into();
        p.merged = true;
        p.in_search = false;
    });
    fake.edit(REPO, 2, |p| {
        p.state = "CLOSED".into();
        p.in_search = false;
    });
    let seen = rig
        .run_until(mins(3), Duration::from_millis(500), |r| {
            let life = |n| r.row(REPO, n).map(|p| p.lifecycle);
            life(1) == Some(Lifecycle::Merged) && life(2) == Some(Lifecycle::Closed)
        })
        .await;
    assert!(seen.is_some(), "the list never showed them as ended");

    for n in [1, 2] {
        let answer = rig.merge(&format!("r{n}"), REPO, n, &short('a')).await;
        assert_eq!(code_of(&answer), "not_open", "#{n}: {answer:?}");
    }
    assert!(rig.fake.merges().is_empty());
}

#[tokio::test]
async fn these_states_are_still_mergeable_has_hooks_no_checks_a_human_and_a_bot_and_a_changed_mind_of_perri(
) {
    use Verdict::*;
    let cases: Vec<Scenario> = vec![
        (
            "GitHub says has hooks",
            ready_pr(2000).merge_state("HAS_HOOKS"),
            vec![('a', Approved)],
        ),
        (
            "a PR with no checks at all",
            {
                let mut p = ready_pr(2001);
                p.checks.clear();
                p
            },
            vec![('a', Approved)],
        ),
        (
            "a human and a bot both approved",
            ready_pr(2002).approved_by_bot("dependabot[bot]"),
            vec![('a', Approved)],
        ),
        (
            "Perri asked for changes, then approved the same head",
            ready_pr(2003),
            vec![('a', ChangesRequested), ('a', Approved)],
        ),
        (
            "Perri approved an older head, then this one",
            ready_pr(2004),
            vec![('b', Approved), ('a', Approved)],
        ),
        (
            "a comment from Perri on an older head does not matter",
            ready_pr(2005),
            vec![('c', Comment), ('a', Approved)],
        ),
    ];
    let fake = Fake::new();
    for (_, pr, _) in &cases {
        fake.put(pr.clone());
    }
    let mut rig = boot(fake).await;
    for (_, pr, verdicts) in &cases {
        for (head, v) in verdicts {
            record(&mut rig, pr.number, &sha(*head), *v).await;
        }
    }
    for (name, pr, _) in &cases {
        let answer = rig
            .merge(&format!("ok-{}", pr.number), REPO, pr.number, &short('a'))
            .await;
        assert_eq!(code_of(&answer), "ok", "{name}: {answer:?}");
        assert_eq!(merge_requests_for(&rig, pr.number).len(), 1, "{name}");
    }
}

#[tokio::test]
async fn the_verb_reads_the_pr_again_so_a_green_cached_row_does_not_get_a_merge_through() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(
        (row.checks.failed, row.review.logins.clone()),
        (0, vec!["alice".to_owned()]),
        "the cached row is green and approved"
    );

    // GitHub changes; the engine has not looked (no time has passed).
    rig.fake.edit(REPO, N, failing_check);
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "checks_not_green", "{answer:?}");
    assert!(rig.fake.merges().is_empty());
    // And the cached row still said green when it answered.
    assert_eq!(rig.row(REPO, N).unwrap().checks.failed, 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// GitHub's own limits and answers
// ═════════════════════════════════════════════════════════════════════════════

/// Put the engine into its hard pause: GitHub refused a search and said to wait.
async fn pause_the_engine(rig: &mut Rig, retry_after: u64) {
    rig.fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: Some(retry_after),
        }),
    );
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("the engine never paused");
}

#[tokio::test]
async fn a_pr_cannot_be_merged_while_the_list_is_paused_on_a_rate_limit_and_nothing_is_sent() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;

    pause_the_engine(&mut rig, 900).await;
    let resumes = rig
        .snapshot()
        .unwrap()
        .poll
        .resumes_at
        .expect("a pause says when it ends");
    assert!(resumes > rig.clock.now(), "the pause has not ended");
    assert!(rig.row(REPO, N).is_some(), "the row is still listed");

    let mark = rig.fake.log_len();
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "rate_limited", "{answer:?}");
    assert_eq!(rig.since(mark).len(), 0, "nothing was sent to GitHub");
    assert!(rig.fake.merges().is_empty());
}

/// GitHub limits the merge verb's own read while the list is idle (nobody is
/// looking, so the engine has not noticed): the verb remembers the wait and
/// answers the next merges itself, without spending the allowance.
#[tokio::test]
async fn a_merge_after_github_limited_the_verbs_own_read_waits_out_the_wait_without_a_read() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    rig.set_demand("idle").await;
    rig.fake.force(
        "graphql",
        Some(Forced {
            status: 429,
            retry_after: Some(600),
        }),
    );
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "rate_limited", "{answer:?}");
    rig.fake.force("graphql", None);

    let mark = rig.fake.log_len();
    for i in 0..3 {
        rig.advance(secs(30)).await;
        let answer = rig.merge(&format!("again-{i}"), REPO, N, &short('a')).await;
        assert_eq!(
            code_of(&answer),
            "rate_limited",
            "inside the wait: {answer:?}"
        );
    }
    assert_eq!(rig.since(mark).len(), 0, "GitHub was read inside the wait");
    assert!(rig.fake.merges().is_empty());

    // Once the wait has ended the merge reads and goes through.
    rig.advance(mins(10)).await;
    let answer = rig.merge("last", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
    assert_eq!(merge_requests_for(&rig, N).len(), 1);
}

/// Under 20% of GitHub's allowance the list only polls more slowly
/// (`poll: rate_limited`): that is not a pause, and a merge still goes through.
#[tokio::test]
async fn a_list_that_is_only_polling_slowly_for_want_of_allowance_does_not_stop_a_merge() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    rig.fake.set_rate(Some(Rate {
        remaining: 15,
        limit: 100,
        reset: t0() + Chrono::hours(1),
    }));
    rig.refresh().await;
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::RateLimited)
    })
    .await
    .expect("the list slowed down");
    assert_eq!(rig.snapshot().unwrap().poll.resumes_at, None, "not paused");

    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
    assert_eq!(rig.fake.merges().len(), 1);
}

#[tokio::test]
async fn once_the_pause_has_ended_the_pr_can_be_merged_again() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    pause_the_engine(&mut rig, 120).await;
    rig.fake.force("search", None);
    rig.run(mins(4), secs(5)).await;
    assert_ne!(
        rig.snapshot().unwrap().poll.state,
        PollState::Paused,
        "the engine resumed"
    );
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
}

#[tokio::test]
async fn githubs_answer_to_the_merge_is_a_code_and_none_of_its_words_or_the_pr_reach_the_answer_or_a_log(
) {
    let (log, _guard) = logs();
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;

    // (status, retry-after, GitHub says the limit is used up, code)
    let table: [(u16, Option<u64>, bool, &str); 14] = [
        (405, None, false, "blocked"),
        (409, None, false, "head_changed"),
        (403, None, false, "token_cannot_merge"),
        (403, Some(30), false, "rate_limited"),
        (403, None, true, "rate_limited"),
        (404, None, false, "not_found"),
        (422, None, false, "not_mergeable"),
        (429, None, false, "rate_limited"),
        (429, Some(60), false, "rate_limited"),
        (401, None, false, "token_cannot_merge"),
        (500, None, false, "unreachable"),
        (502, None, false, "unreachable"),
        (503, Some(5), false, "unreachable"),
        (400, None, false, "unreachable"),
    ];
    let mut answers = String::new();
    for (i, (status, retry_after, exhausted, want)) in table.iter().enumerate() {
        rig.fake.force(
            "merge",
            Some(Forced {
                status: *status,
                retry_after: *retry_after,
            }),
        );
        rig.fake.set_rate(exhausted.then(|| Rate {
            remaining: 0,
            limit: 5000,
            reset: t0() + Chrono::hours(1),
        }));
        let before = rig.fake.merges().len();
        let answer = rig.merge(&format!("gh-{i}"), REPO, N, &short('a')).await;
        let what = format!("{status} retry-after {retry_after:?} exhausted {exhausted}");
        assert_eq!(code_of(&answer), *want, "{what}: {answer:?}");
        assert_eq!(rig.fake.merges().len(), before + 1, "{what}: one request");
        answers.push_str(&serde_json::to_string(&answer).unwrap());
    }
    rig.fake.force("merge", None);
    rig.fake.set_rate(None);

    for secret in [
        "CANARY-ERROR-BODY",
        "github.com",
        "canary-org",
        "canary-repo",
        "424242",
        TITLE,
        TOKEN,
    ] {
        assert!(!answers.contains(secret), "{secret} reached an answer");
    }
    let text = log.text();
    // The repo and number are in the refusal's audit line, on purpose; nothing
    // else of the PR or of GitHub's answer is.
    for secret in [
        "CANARY-ERROR-BODY",
        "github.com/canary-org",
        TITLE,
        TOKEN,
        sha('a').as_str(),
    ] {
        assert!(!text.contains(secret), "{secret} reached a log:\n{text}");
    }
    assert!(
        !text.contains("authored-pr merged"),
        "a failed merge is not logged as merged"
    );
    assert_eq!(
        text.lines()
            .filter(|l| l.contains("authored-pr merge refused"))
            .count(),
        table.len(),
        "one audit line per refused attempt:\n{text}"
    );
}

#[tokio::test]
async fn a_refused_merge_leaves_one_audit_line_with_the_code_and_who_asked() {
    let (log, _guard) = logs();
    let mut rig = start(vec![ready_pr(N)]).await;
    // Perri has not approved: refused.
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "perri_not_approved", "{answer:?}");
    // A repeated request id is an echo, not a second attempt.
    let again = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&again), "perri_not_approved");
    // A PR that is not in the list.
    let answer = rig.merge("r2", REPO, N + 5, &short('a')).await;
    assert_eq!(code_of(&answer), "not_found", "{answer:?}");

    let text = log.text();
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| l.contains("authored-pr merge refused"))
        .collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(lines[0].contains("perri_not_approved"), "{}", lines[0]);
    assert!(lines[0].contains(REPO) && lines[0].contains(&N.to_string()));
    assert!(lines[0].contains(&short('a')), "{}", lines[0]);
    assert!(lines[0].contains("test-operator"), "{}", lines[0]);
    assert!(lines[1].contains("not_found"), "{}", lines[1]);
    for secret in [TITLE, TOKEN, sha('a').as_str()] {
        assert!(!text.contains(secret), "{secret} reached a log:\n{text}");
    }
}

#[tokio::test]
async fn when_github_cannot_be_read_the_answer_is_a_code_and_no_merge_is_sent() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    let table: [(u16, Option<u64>, &str); 7] = [
        (500, None, "unreachable"),
        (502, None, "unreachable"),
        (429, None, "rate_limited"),
        (403, Some(30), "rate_limited"),
        // No Retry-After, allowance left, a body that names no limit: access, not a wait.
        (403, None, "token_cannot_merge"),
        (401, None, "token_cannot_merge"),
        (404, None, "unreachable"),
    ];
    for (i, (status, retry_after, want)) in table.iter().enumerate() {
        rig.fake.force(
            "graphql",
            Some(Forced {
                status: *status,
                retry_after: *retry_after,
            }),
        );
        let answer = rig.merge(&format!("rd-{i}"), REPO, N, &short('a')).await;
        assert_eq!(
            code_of(&answer),
            *want,
            "read answered {status}: {answer:?}"
        );
        // A rate limit is remembered for the wait GitHub gave (at most fifteen
        // minutes): let it end, with GitHub well again, so the next row is
        // answered by GitHub and not by that memory.
        rig.fake.force("graphql", None);
        rig.advance(mins(16)).await;
    }
    rig.fake.force("graphql", None);
    assert!(rig.fake.merges().is_empty());
}

#[tokio::test]
async fn a_daemon_with_no_github_client_says_the_token_cannot_merge_and_sends_nothing() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    *rig.api.lock().unwrap() = None;
    let mark = rig.fake.log_len();
    let answer = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&answer), "token_cannot_merge", "{answer:?}");
    assert_eq!(rig.since(mark).len(), 0);
}

#[tokio::test]
async fn a_merge_request_that_gets_no_answer_is_unreachable() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    // GitHub takes the request and never answers within the client's patience.
    rig.fake.delay_merge(Some(Duration::from_secs(5)));
    let task = rig.spawn_merge("r1", REPO, N, &short('a'));
    let mut spins = 0;
    while rig.fake.merges().is_empty() {
        rig.settle().await;
        spins += 1;
        assert!(spins < 5000, "the merge request never went out");
    }
    // The client's timeout runs on the (paused) clock: let a lot of it pass.
    rig.advance(mins(10)).await;
    let answer = rig.drive(task).await;
    assert_eq!(code_of(&answer), "unreachable", "{answer:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// One request id, one answer; one merge of a PR at a time
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_same_request_id_gets_the_first_answer_again_and_merges_once() {
    let mut rig = start(vec![ready_pr(N)]).await;
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    let first = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&first), "ok");

    // GitHub now says it is merged; the same request is still answered ok and
    // asks GitHub nothing.
    let mark = rig.fake.log_len();
    let again = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&again), "ok", "{again:?}");
    assert_eq!(rig.since(mark).len(), 0, "nothing was asked again");
    assert_eq!(rig.fake.merges().len(), 1, "exactly one merge request");
}

#[tokio::test]
async fn a_failure_is_remembered_for_its_request_id_and_a_new_id_asks_afresh() {
    let mut rig = start(vec![ready_pr(N)]).await;
    // No Perri verdict yet.
    let first = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&first), "perri_not_approved");

    // Perri approves; the same request id still gets its first answer, with
    // nothing asked and nothing merged.
    record(&mut rig, N, &sha('a'), Verdict::Approved).await;
    let mark = rig.fake.log_len();
    let again = rig.merge("r1", REPO, N, &short('a')).await;
    assert_eq!(code_of(&again), "perri_not_approved", "{again:?}");
    assert_eq!(rig.since(mark).len(), 0);
    assert!(rig.fake.merges().is_empty());

    // A new request is judged on what is true now.
    let fresh = rig.merge("r2", REPO, N, &short('a')).await;
    assert_eq!(code_of(&fresh), "ok", "{fresh:?}");
    assert_eq!(rig.fake.merges().len(), 1);
}

#[tokio::test]
async fn a_request_id_answers_only_for_the_pr_it_first_named() {
    let mut rig = start(vec![ready_pr(1), ready_pr(2)]).await;
    record(&mut rig, 1, &sha('a'), Verdict::Approved).await;
    let first = rig.merge("r1", REPO, 1, &short('a')).await;
    assert_eq!(code_of(&first), "ok", "{first:?}");

    // The same id for another PR is a new request, judged on its own facts
    // (PR 2 has no Perri verdict): it is not told that the first one merged.
    let other = rig.merge("r1", REPO, 2, &short('a')).await;
    assert_eq!(code_of(&other), "perri_not_approved", "{other:?}");
    assert_eq!(rig.fake.merges().len(), 1);
}

#[tokio::test]
async fn a_second_merge_of_a_pr_being_merged_is_busy_another_pr_is_not_blocked_and_busy_is_not_remembered(
) {
    let mut rig = start(vec![ready_pr(1), ready_pr(2)]).await;
    record(&mut rig, 1, &sha('a'), Verdict::Approved).await;
    record(&mut rig, 2, &sha('a'), Verdict::Approved).await;

    // GitHub holds merge requests for a while, so the first is in flight.
    rig.fake.delay_merge(Some(Duration::from_millis(1500)));
    let first = rig.spawn_merge("r1", REPO, 1, &short('a'));
    let mut spins = 0;
    while rig.fake.merges().is_empty() {
        rig.settle().await;
        spins += 1;
        assert!(spins < 5000, "the first merge request never went out");
    }
    assert!(!first.is_finished(), "the first merge is still in flight");

    let second = rig.merge("r2", REPO, 1, &short('a')).await;
    assert_eq!(code_of(&second), "busy", "{second:?}");
    assert_eq!(rig.fake.merges().len(), 1, "the busy one sent nothing");

    // Another PR is not held up by it.
    let other = rig.merge("r3", REPO, 2, &short('a')).await;
    assert_eq!(code_of(&other), "ok", "{other:?}");

    let first = rig.drive(first).await;
    assert_eq!(code_of(&first), "ok", "{first:?}");
    assert_eq!(
        (
            merge_requests_for(&rig, 1).len(),
            merge_requests_for(&rig, 2).len()
        ),
        (1, 1),
        "one merge request per PR"
    );

    // `busy` was not r2's answer: asked again it is judged afresh (the PR is
    // merged by now), not answered busy.
    let later = rig.merge("r2", REPO, 1, &short('a')).await;
    assert_eq!(code_of(&later), "not_open", "{later:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Who may ask: the verified operator app only
// ═════════════════════════════════════════════════════════════════════════════

struct Daemon {
    /// A server whose verifier says every local peer is the genuine app.
    app_socket: PathBuf,
    /// A server whose verifier says every local peer is some other process.
    script_socket: PathBuf,
    tcp_port: u16,
    _servers: Vec<Server>,
    _tmp: TempDir,
}

/// The daemon's sockets over `rig`'s list and verbs: `board` switches the list
/// on, `actions` wires the verbs.
async fn daemon(rig: &Rig, board: bool, actions: bool) -> Daemon {
    let tmp = TempDir::new().expect("tempdir");
    let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    {
        let mut g = mgr.lock().unwrap();
        if board {
            g.configure_authored_prs(Arc::clone(&rig.demand));
        }
        if actions {
            g.configure_authored_pr_actions(Arc::clone(&rig.actions));
        }
    }
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
    let app_socket = tmp.path().join("app.sock");
    let script_socket = tmp.path().join("script.sock");
    let app_server = Server::bind(
        &app_socket,
        Arc::clone(&mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
        Arc::new(FakePeerVerifier::always_app()),
        false,
        nostromo::terminal::TerminalManager::in_memory(),
    )
    .expect("bind");
    let script_server = Server::bind(
        &script_socket,
        Arc::clone(&mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
        Arc::new(FakePeerVerifier::always_script()),
        false,
        nostromo::terminal::TerminalManager::in_memory(),
    )
    .expect("bind");
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let tcp_port = tcp.local_addr().unwrap().port();
    app_server.bind_tcp(tcp, mgr, tmp.path().join("perri-state"), decisions);
    Daemon {
        app_socket,
        script_socket,
        tcp_port,
        _servers: vec![app_server, script_server],
        _tmp: tmp,
    }
}

async fn send<S: AsyncWrite + Unpin>(s: &mut S, msg: &ClientMsg) {
    write_frame(s, &serde_json::to_vec(msg).unwrap())
        .await
        .expect("write");
}

async fn recv<S: AsyncRead + Unpin>(s: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(10), read_frame(s))
        .await
        .expect("timed out waiting for a frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Ping and read to the Pong; everything before it.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> Vec<ServerMsg> {
    send(s, &ClientMsg::Ping).await;
    let mut frames = Vec::new();
    loop {
        match recv(s).await {
            ServerMsg::Pong => return frames,
            other => frames.push(other),
        }
    }
}

async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(
    s: &mut S,
    kind: Option<&str>,
) -> Vec<String> {
    send(
        s,
        &ClientMsg::Hello {
            capabilities: Vec::new(),
            client_id: "merge-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: kind.map(str::to_owned),
        },
    )
    .await;
    let features = match recv(s).await {
        ServerMsg::Welcome { features, .. } => features,
        other => panic!("expected a Welcome, got {other:?}"),
    };
    send(
        s,
        &ClientMsg::Subscribe {
            topics: vec![],
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        },
    )
    .await;
    sync(s).await;
    features
}

async fn unix(path: &PathBuf, kind: Option<&str>) -> (UnixStream, Vec<String>) {
    let mut s = UnixStream::connect(path).await.expect("connect");
    let features = handshake(&mut s, kind).await;
    (s, features)
}

fn merge_msg(id: &str, number: u64, short: &str) -> ClientMsg {
    merge_msg_via(id, number, short, None)
}

fn merge_msg_via(id: &str, number: u64, short: &str, via: Option<MergeVia>) -> ClientMsg {
    ClientMsg::AuthoredPrMerge {
        request_id: id.into(),
        repo: REPO.into(),
        number,
        expected_head_sha_short: short.into(),
        expected_via: via,
    }
}

/// The merge answer for `id` among `frames`, as (code or "ok").
fn merge_answer(frames: &[ServerMsg], id: &str) -> Option<String> {
    frames.iter().find_map(|m| match m {
        ServerMsg::AuthoredPrMergeResult { request_id, result } if request_id == id => {
            Some(code_of(result))
        }
        _ => None,
    })
}

/// Read frames until the merge answer for `id` arrives.
async fn await_merge_answer<S: AsyncRead + Unpin>(s: &mut S, id: &str) -> String {
    loop {
        if let ServerMsg::AuthoredPrMergeResult { request_id, result } = recv(s).await {
            if request_id == id {
                return code_of(&result);
            }
        }
    }
}

/// A real-time engine over a fake GitHub with one mergeable PR in its list.
async fn real_time_rig() -> Rig {
    drop(logs());
    let fake = Fake::new();
    fake.put(ready_pr(N));
    let server = MockServer::start().await;
    fake.mount_on(&server, None).await;
    let rig = Rig::start_real_time(server, fake).await;
    rig.demand.set("operator", "visible");
    wait_for("the PR to be listed", || rig.row(REPO, N).is_some()).await;
    rig.actions
        .record_verdict(REPO, N, &sha('a'), Verdict::Approved, Some("perri"), None)
        .await
        .unwrap();
    wait_for("the verdict to show", || {
        rig.row(REPO, N).is_some_and(|p| p.perri.is_some())
    })
    .await;
    // Let the engine finish what that started.
    tokio::time::sleep(Duration::from_millis(300)).await;
    rig
}

async fn wait_for(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !cond() {
        assert!(
            std::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn a_local_process_that_is_not_the_operator_app_is_refused_not_permitted_and_nothing_reaches_github(
) {
    let rig = real_time_rig().await;
    let d = daemon(&rig, true, true).await;
    let mark = rig.fake.log_len();

    // A plain client, one that claims another kind, and a script that claims
    // to be the app but is not verified as it.
    let mut clients = [
        ("a plain client", unix(&d.app_socket, None).await.0),
        ("a cli", unix(&d.app_socket, Some("cli")).await.0),
        (
            "an unverified process claiming to be the app",
            unix(&d.script_socket, Some("mac_app")).await.0,
        ),
    ];
    for (who, s) in clients.iter_mut() {
        for (i, via) in [None, Some(MergeVia::Queue)].into_iter().enumerate() {
            let id = format!("m{i}");
            send(s, &merge_msg_via(&id, N, &short('a'), via)).await;
            let frames = sync(s).await;
            assert_eq!(
                merge_answer(&frames, &id).as_deref(),
                Some("not_permitted"),
                "{who} ({via:?}): {frames:?}"
            );
        }
    }
    assert_eq!(rig.fake.log_len(), mark, "nothing at all reached GitHub");
    assert!(rig.fake.merges().is_empty());
    assert!(rig.fake.enqueues().is_empty());
}

#[tokio::test]
async fn a_network_peer_is_refused_requires_secure_connection_and_nothing_reaches_github() {
    let rig = real_time_rig().await;
    let d = daemon(&rig, true, true).await;
    let mark = rig.fake.log_len();

    let mut tcp = TcpStream::connect(("127.0.0.1", d.tcp_port))
        .await
        .expect("connect");
    handshake(&mut tcp, None).await;
    for (i, via) in [None, Some(MergeVia::Queue)].into_iter().enumerate() {
        let id = format!("m{i}");
        send(&mut tcp, &merge_msg_via(&id, N, &short('a'), via)).await;
        let frames = sync(&mut tcp).await;
        assert_eq!(
            merge_answer(&frames, &id).as_deref(),
            Some("requires_secure_connection"),
            "({via:?}) {frames:?}"
        );
    }
    assert_eq!(rig.fake.log_len(), mark, "nothing at all reached GitHub");
    assert!(rig.fake.merges().is_empty());
    assert!(rig.fake.enqueues().is_empty());
}

#[tokio::test]
async fn the_verified_operator_app_reaches_the_verb_and_merges() {
    let rig = real_time_rig().await;
    let d = daemon(&rig, true, true).await;
    let (mut app, _) = unix(&d.app_socket, Some("mac_app")).await;

    // The verb judges: a wrong head is refused with the verb's own code.
    send(&mut app, &merge_msg("m1", N, "deadbeef")).await;
    assert_eq!(await_merge_answer(&mut app, "m1").await, "head_changed");
    assert!(rig.fake.merges().is_empty());

    // The right head merges.
    send(&mut app, &merge_msg("m2", N, &short('a'))).await;
    assert_eq!(await_merge_answer(&mut app, "m2").await, "ok");
    let merges = rig.fake.merges();
    assert_eq!(merges.len(), 1, "{merges:?}");
    assert_eq!(merges[0].path, format!("/repos/{REPO}/pulls/{N}/merge"));
}

#[tokio::test]
async fn a_daemon_without_the_verbs_wired_answers_a_merge_with_a_code_and_sends_nothing() {
    let rig = real_time_rig().await;
    let d = daemon(&rig, true, false).await;
    let mark = rig.fake.log_len();
    let (mut app, _) = unix(&d.app_socket, Some("mac_app")).await;
    send(&mut app, &merge_msg("m1", N, &short('a'))).await;
    let code = await_merge_answer(&mut app, "m1").await;
    assert_ne!(code, "ok");
    assert_eq!(rig.fake.log_len(), mark);
    assert!(rig.fake.merges().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// The Welcome
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_welcome_advertises_perri_with_the_list_and_merge_only_with_the_verbs_wired() {
    let rig = real_time_rig().await;

    let full = daemon(&rig, true, true).await;
    let (_s, features) = unix(&full.app_socket, Some("mac_app")).await;
    for f in [
        "authored_prs_v1",
        "authored_prs_perri_v1",
        "authored_prs_notify_v1",
        "authored_prs_merge_v1",
        "authored_prs_merge_queue_v1",
    ] {
        assert!(features.iter().any(|x| x == f), "{f} missing: {features:?}");
    }

    let list_only = daemon(&rig, true, false).await;
    let (_s, features) = unix(&list_only.app_socket, Some("mac_app")).await;
    assert!(features.iter().any(|x| x == "authored_prs_perri_v1"));
    assert!(
        !features.iter().any(|x| x == "authored_prs_merge_v1"),
        "{features:?}"
    );
    assert!(
        !features.iter().any(|x| x == "authored_prs_merge_queue_v1"),
        "the queue feature is advertised only where the merge verb is: {features:?}"
    );

    let off = daemon(&rig, false, false).await;
    let (_s, features) = unix(&off.app_socket, Some("mac_app")).await;
    assert!(
        !features.iter().any(|f| f.contains("authored_prs")),
        "{features:?}"
    );

    // The merge capability is the same over the network's Welcome (the
    // verb itself is refused there).
    let mut tcp = TcpStream::connect(("127.0.0.1", full.tcp_port))
        .await
        .unwrap();
    let features = handshake(&mut tcp, None).await;
    assert!(
        features.iter().any(|f| f == "authored_prs_perri_v1"),
        "{features:?}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The merge queue
// ═════════════════════════════════════════════════════════════════════════════

fn queue_pr(number: u64) -> FakePr {
    ready_pr(number).with_merge_queue()
}

/// A rig over one PR whose base branch has a merge queue, Perri having approved it.
async fn queue_rig(pr: FakePr) -> Rig {
    let n = pr.number;
    let mut rig = start(vec![pr]).await;
    record(&mut rig, n, &sha('a'), Verdict::Approved).await;
    rig
}

/// Every key of a JSON value, however deep, lowercased.
fn all_keys(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::Object(m) => {
            for (k, v) in m {
                out.push(k.to_ascii_lowercase());
                all_keys(v, out);
            }
        }
        Value::Array(a) => a.iter().for_each(|v| all_keys(v, out)),
        _ => {}
    }
}

#[tokio::test]
async fn a_pr_whose_base_has_a_merge_queue_is_enqueued_with_the_live_head_and_never_merged() {
    let (log, _guard) = logs();
    let mut rig = queue_rig(queue_pr(N)).await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(row.merge_via, Some(MergeVia::Queue), "the row says so");

    let answer = rig
        .merge_via("q-1", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "queued", "{answer:?}");
    assert_eq!(
        serde_json::to_value(&answer).unwrap(),
        json!({"status": "ok", "value": {"code": "queued"}})
    );

    // The REST merge is never called on the queue path.
    assert!(rig.fake.merges().is_empty(), "{:?}", rig.fake.merges());
    let enq = rig.fake.enqueues();
    assert_eq!(enq.len(), 1, "{enq:?}");
    let e = &enq[0];
    assert_eq!(e.method, "POST");
    assert_eq!(
        e.auth.as_deref(),
        Some(format!("Bearer {TOKEN}").as_str()),
        "the daemon's own token"
    );
    let body: Value = serde_json::from_str(&e.body).expect("a JSON body");
    let top: BTreeSet<&str> = body
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(top, BTreeSet::from(["query", "variables"]), "{body}");
    let vars: BTreeSet<&str> = body["variables"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(vars, BTreeSet::from(["head", "pr"]), "{body}");
    assert_eq!(
        body["variables"]["head"],
        sha('a').as_str(),
        "the FULL live head"
    );
    assert_eq!(body["variables"]["pr"], format!("PR_node_{N}").as_str());
    let query = body["query"].as_str().unwrap();
    assert!(query.contains("enqueuePullRequest"), "{query}");
    assert!(query.contains("expectedHeadOid: $head"), "{query}");
    // No `jump`, and no admin, bypass or force input, in the text or the variables.
    let mut keys = Vec::new();
    all_keys(&body["variables"], &mut keys);
    let lowered = e.body.to_ascii_lowercase();
    for banned in ["jump", "admin", "bypass", "force", "override"] {
        assert!(
            !lowered.contains(banned),
            "{banned} is in the request: {}",
            e.body
        );
        assert!(!keys.iter().any(|k| k.contains(banned)));
    }

    // The audit line says which way it went, and holds nothing else of the PR.
    let text = log.text();
    let line = text
        .lines()
        .find(|l| l.contains("authored-pr queued"))
        .unwrap_or_else(|| panic!("no audit line in:\n{text}"));
    assert!(line.contains(REPO) && line.contains(&short('a')), "{line}");
    assert!(
        line.contains("via=queue") || line.contains("via=\"queue\""),
        "{line}"
    );
    for secret in [TOKEN, TITLE, CANARY_BODY, INJECTION, sha('a').as_str()] {
        assert!(!text.contains(secret), "{secret} reached a log");
    }

    // The next read shows the entry; the PR is still open, not merged.
    rig.refresh().await;
    rig.run(secs(3), Duration::from_millis(500)).await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(row.lifecycle, Lifecycle::Open);
    let q = row.queue.expect("a queue entry on the row");
    assert_eq!((q.state, q.position), (QueueState::Queued, Some(1)));
}

#[tokio::test]
async fn a_pr_on_a_branch_without_a_queue_is_merged_directly_and_never_enqueued() {
    let (log, _guard) = logs();
    let mut rig = queue_rig(ready_pr(N)).await;
    assert_eq!(rig.row(REPO, N).unwrap().merge_via, Some(MergeVia::Direct));
    let answer = rig
        .merge_via("d-1", REPO, N, &short('a'), MergeVia::Direct)
        .await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
    assert_eq!(rig.fake.merges().len(), 1);
    assert!(rig.fake.enqueues().is_empty());
    let text = log.text();
    let line = text
        .lines()
        .find(|l| l.contains("authored-pr merged"))
        .unwrap();
    assert!(
        line.contains("via=direct") || line.contains("via=\"direct\""),
        "{line}"
    );
}

#[tokio::test]
async fn every_rule_that_stops_a_direct_merge_stops_an_enqueue_the_same_way() {
    use Verdict::*;
    // `run_cases` runs each of these on the direct path and on the queue path:
    // same code, and neither a merge request nor an enqueue reaches GitHub.
    run_cases(vec![
        case("no human approval", "not_approved").pr(without_reviews),
        case("only a bot approved", "not_approved")
            .pr(|p| without_reviews(p).approved_by_bot("dependabot[bot]")),
        case("a draft", "draft").pr(|p| p.draft()),
        case("a failing check", "checks_not_green").pr(|p| p.failing("lint")),
        case("not clean: blocked", "blocked").pr(|p| p.merge_state("BLOCKED")),
        case("not clean: behind", "behind").pr(|p| p.merge_state("BEHIND")),
        case("not clean: unknown", "not_mergeable").pr(|p| p.merge_state("UNKNOWN")),
        case("conflicting", "not_mergeable").pr(|p| p.mergeable("CONFLICTING")),
        case("Perri has said nothing", "perri_not_approved").verdicts(&[]),
        case("Perri asked for changes", "perri_not_approved").verdicts(&[('a', ChangesRequested)]),
        case("Perri approved an older head only", "perri_stale").verdicts(&[('b', Approved)]),
        case("the app showed another head", "head_changed").expecting("deadbeef"),
        case("the head moved after the list was read", "head_changed")
            .verdicts(&[('a', Approved), ('d', Approved)])
            .then_on_github(|p| p.head_sha = "d".repeat(40)),
        case("a closed PR", "not_open").then_on_github(|p| p.state = "CLOSED".into()),
    ])
    .await;
}

#[tokio::test]
async fn a_pr_already_in_the_queue_answers_already_queued_and_nothing_is_sent() {
    let mut rig = queue_rig(queue_pr(N).in_queue("AWAITING_CHECKS", Some(2))).await;
    let row = rig.row(REPO, N).unwrap();
    let q = row.queue.expect("the row shows the queue entry");
    assert_eq!((q.state, q.position), (QueueState::AwaitingChecks, Some(2)));
    let answer = rig
        .merge_via("a-1", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "already_queued", "{answer:?}");
    assert!(rig.fake.enqueues().is_empty());
    assert!(rig.fake.merges().is_empty());
}

#[tokio::test]
async fn githubs_refusals_to_enqueue_map_to_codes_and_none_of_its_words_reach_the_answer() {
    let mut rig = queue_rig(queue_pr(N)).await;
    let leak = "https://github.com/canary-org/canary-repo/pull/9 CANARY-ERROR-BODY";
    let gql = |errors: Value| {
        (
            200u16,
            json!({"data": {"enqueuePullRequest": null}, "errors": errors}),
        )
    };
    let table: Vec<(&str, (u16, Value), &str)> = vec![
        (
            "not ready",
            gql(json!([{"type": "UNPROCESSABLE", "message": leak}])),
            "queue_refused",
        ),
        (
            "no entry and no error",
            (200, json!({"data": {"enqueuePullRequest": null}})),
            "queue_refused",
        ),
        (
            "head moved",
            gql(
                json!([{"type": "UNPROCESSABLE", "message": format!("Head branch was modified {leak}")}]),
            ),
            "head_changed",
        ),
        (
            "forbidden",
            gql(json!([{"type": "FORBIDDEN", "message": leak}])),
            "token_cannot_merge",
        ),
        (
            "scopes",
            gql(json!([{"type": "INSUFFICIENT_SCOPES", "message": leak}])),
            "token_cannot_merge",
        ),
        (
            "gone",
            gql(json!([{"type": "NOT_FOUND", "message": leak}])),
            "not_found",
        ),
        (
            "graphql limit",
            gql(json!([{"type": "RATE_LIMITED", "message": leak}])),
            "rate_limited",
        ),
        (
            "http 401",
            (401, json!({"message": leak})),
            "token_cannot_merge",
        ),
        (
            "http 403",
            (403, json!({"message": leak})),
            "token_cannot_merge",
        ),
        ("http 429", (429, json!({"message": leak})), "rate_limited"),
        ("http 500", (500, json!({"message": leak})), "unreachable"),
        ("a JSON string", (200, json!("a string")), "queue_refused"),
        ("not JSON", (200, Value::Null), "queue_refused"),
    ];
    for (i, (name, reply, want)) in table.into_iter().enumerate() {
        rig.fake.enqueue_responds(Some(reply));
        let answer = rig
            .merge_via(&format!("e-{i}"), REPO, N, &short('a'), MergeVia::Queue)
            .await;
        assert_eq!(code_of(&answer), want, "{name}: {answer:?}");
        let wire = serde_json::to_string(&answer).unwrap();
        assert!(
            !wire.contains("CANARY") && !wire.contains("github.com"),
            "{wire}"
        );
    }
    assert!(rig.fake.merges().is_empty());
    // A refusal is not remembered as a success: a new id asks again.
    rig.fake.enqueue_responds(None);
    let answer = rig
        .merge_via("e-ok", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "queued", "{answer:?}");
}

#[tokio::test]
async fn the_way_the_app_worded_the_confirmation_must_be_the_way_github_says_now() {
    // (a queue on GitHub, what the app said, the code)
    let table: [(bool, Option<MergeVia>, &str); 4] = [
        (true, Some(MergeVia::Direct), "via_changed"),
        // An app that does not know queues says nothing: it said "squash and merge".
        (true, None, "via_changed"),
        (false, Some(MergeVia::Queue), "via_changed"),
        (false, Some(MergeVia::Direct), "ok"),
    ];
    let prs: Vec<FakePr> = table
        .iter()
        .enumerate()
        .map(|(i, (queue, _, _))| {
            let pr = ready_pr(100 + i as u64);
            if *queue {
                pr.with_merge_queue()
            } else {
                pr
            }
        })
        .collect();
    let mut rig = start(prs).await;
    for i in 0..table.len() {
        record(&mut rig, 100 + i as u64, &sha('a'), Verdict::Approved).await;
    }
    for (i, (queue, said, want)) in table.into_iter().enumerate() {
        let n = 100 + i as u64;
        let task = rig.spawn_merge_via(&format!("v-{i}"), REPO, n, &short('a'), said);
        let answer = rig.drive(task).await;
        assert_eq!(
            code_of(&answer),
            want,
            "queue={queue} said={said:?}: {answer:?}"
        );
    }
    assert!(rig.fake.enqueues().is_empty());
    assert_eq!(
        rig.fake.merges().len(),
        1,
        "only the agreeing direct one merged"
    );
}

#[tokio::test]
async fn when_the_queue_cannot_be_read_nothing_is_sent_and_the_answer_is_queue_unknown() {
    let mut rig = queue_rig(queue_pr(N).queue_unreadable()).await;
    assert_eq!(
        rig.row(REPO, N).unwrap().merge_via,
        None,
        "the row does not guess"
    );
    for (i, via) in [Some(MergeVia::Direct), Some(MergeVia::Queue), None]
        .into_iter()
        .enumerate()
    {
        let task = rig.spawn_merge_via(&format!("u-{i}"), REPO, N, &short('a'), via);
        let answer = rig.drive(task).await;
        assert_eq!(code_of(&answer), "queue_unknown", "{via:?}: {answer:?}");
    }
    assert!(rig.fake.enqueues().is_empty() && rig.fake.merges().is_empty());
}

#[tokio::test]
async fn a_queue_field_github_could_not_resolve_is_unknown_not_a_direct_merge() {
    // `mergeQueue: null` beside an error is a failed read, not "no queue".
    let mut rig = queue_rig(queue_pr(N).queue_field_error()).await;
    assert_eq!(
        rig.row(REPO, N).unwrap().merge_via,
        None,
        "the row does not guess"
    );
    for (i, via) in [Some(MergeVia::Direct), Some(MergeVia::Queue), None]
        .into_iter()
        .enumerate()
    {
        let task = rig.spawn_merge_via(&format!("f-{i}"), REPO, N, &short('a'), via);
        let answer = rig.drive(task).await;
        assert_eq!(code_of(&answer), "queue_unknown", "{via:?}: {answer:?}");
    }
    assert!(rig.fake.merges().is_empty() && rig.fake.enqueues().is_empty());
}

#[tokio::test]
async fn one_request_id_enqueues_once_and_a_failure_is_remembered_for_its_id() {
    let mut rig = queue_rig(queue_pr(N)).await;
    let first = rig
        .merge_via("same", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    let again = rig
        .merge_via("same", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&first), "queued");
    assert_eq!(first, again);
    assert_eq!(rig.fake.enqueues().len(), 1);
    // The PR is now queued: a new id is `already_queued`, not a second enqueue.
    rig.refresh().await;
    rig.run(secs(3), Duration::from_millis(500)).await;
    let third = rig
        .merge_via("other", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&third), "already_queued", "{third:?}");
    assert_eq!(rig.fake.enqueues().len(), 1);
}

#[tokio::test]
async fn the_row_says_how_the_pr_will_go_in_and_where_it_is_in_the_queue() {
    let fake = Fake::new();
    fake.put(queue_pr(1));
    fake.put(ready_pr(2));
    fake.put(queue_pr(3).queue_unreadable());
    fake.put(queue_pr(4).in_queue("MERGEABLE", Some(3)));
    // Odd values GitHub might send: a state this build does not know, a position out of range.
    fake.put(queue_pr(5).in_queue("SOMETHING_NEW", Some(4_000_000)));
    fake.put(queue_pr(6).in_queue("QUEUED", None));
    let rig = boot(fake).await;
    let row = |n| rig.row(REPO, n).unwrap();
    assert_eq!(
        (row(1).merge_via, row(1).queue),
        (Some(MergeVia::Queue), None)
    );
    assert_eq!(
        (row(2).merge_via, row(2).queue),
        (Some(MergeVia::Direct), None)
    );
    assert_eq!((row(3).merge_via, row(3).queue), (None, None));
    let q = row(4).queue.unwrap();
    assert_eq!(
        (row(4).merge_via, q.state, q.position),
        (Some(MergeVia::Queue), QueueState::Mergeable, Some(3))
    );
    let q = row(5).queue.unwrap();
    assert_eq!((q.state, q.position), (QueueState::Unknown, Some(9999)));
    let q = row(6).queue.unwrap();
    assert_eq!((q.state, q.position), (QueueState::Queued, None));
    // Absent fields are absent on the wire, so an old app never sees them.
    let wire = serde_json::to_value(row(2)).unwrap();
    assert_eq!(wire["merge_via"], "direct");
    assert!(wire.get("queue").is_none());
    let wire = serde_json::to_value(row(3)).unwrap();
    assert!(wire.get("merge_via").is_none() && wire.get("queue").is_none());
}

#[tokio::test]
async fn a_pr_dropped_from_the_queue_loses_its_entry_on_the_next_read() {
    let mut rig = queue_rig(queue_pr(N).in_queue("QUEUED", Some(1))).await;
    assert!(rig.row(REPO, N).unwrap().queue.is_some());
    rig.fake.edit(REPO, N, |p| {
        p.in_queue = None;
        p.updated_at = t0() + Chrono::minutes(5);
    });
    rig.run_until(mins(3), secs(1), |r| {
        r.row(REPO, N).is_some_and(|p| p.queue.is_none())
    })
    .await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(row.lifecycle, Lifecycle::Open);
    assert!(row.queue.is_none(), "{row:?}");
    assert_eq!(row.merge_via, Some(MergeVia::Queue));
}

#[tokio::test]
async fn the_verified_operator_app_is_enqueued_through_the_wire() {
    let rig = real_time_rig().await;
    rig.fake.edit(REPO, N, |p| p.has_queue = true);
    let d = daemon(&rig, true, true).await;
    let (mut app, _) = unix(&d.app_socket, Some("mac_app")).await;

    // The app said "squash and merge" (no `expected_via`) but GitHub says queue.
    send(&mut app, &merge_msg("m1", N, &short('a'))).await;
    assert_eq!(await_merge_answer(&mut app, "m1").await, "via_changed");
    assert!(rig.fake.enqueues().is_empty() && rig.fake.merges().is_empty());

    send(
        &mut app,
        &merge_msg_via("m2", N, &short('a'), Some(MergeVia::Queue)),
    )
    .await;
    assert_eq!(await_merge_answer(&mut app, "m2").await, "queued");
    assert_eq!(rig.fake.enqueues().len(), 1);
    assert!(rig.fake.merges().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// The merge queue follows the PR's BASE branch
//
// GitHub answers a PR's own `mergeQueue` field with `main`'s queue even when the
// PR is stacked on a branch (`merge/*`) that has none. Only the base branch's
// queue decides how the PR goes in; the PR's own field is a cross-check.
// ═════════════════════════════════════════════════════════════════════════════

/// A branch a PR is stacked on, as on Perri's real data.
const STACKED: &str = "merge/f2c-family-session-facility";

/// Every `POST /graphql` that reads a base branch's queue (the second read).
fn base_queue_reads(rig: &Rig) -> Vec<Req> {
    rig.fake
        .log()
        .into_iter()
        .filter(|r| r.kind() == Kind::Graphql && r.graphql_query().contains("mergeQueue(branch:"))
        .collect()
}

/// One rig over several PRs (time can be frozen once per test), Perri having
/// approved each of them at its head.
async fn rig_over(prs: Vec<FakePr>) -> Rig {
    let numbers: Vec<u64> = prs.iter().map(|p| p.number).collect();
    let mut rig = start(prs).await;
    for n in numbers {
        record(&mut rig, n, &sha('a'), Verdict::Approved).await;
    }
    rig
}

/// The merge verb answers `queue_unknown` for PR `n` however the app worded the
/// confirmation (direct, queue, or not at all).
async fn assert_queue_unknown(rig: &mut Rig, n: u64, what: &str) {
    for (i, via) in [Some(MergeVia::Direct), Some(MergeVia::Queue), None]
        .into_iter()
        .enumerate()
    {
        let task = rig.spawn_merge_via(&format!("qu-{n}-{i}"), REPO, n, &short('a'), via);
        let answer = rig.drive(task).await;
        assert_eq!(
            code_of(&answer),
            "queue_unknown",
            "{what} {via:?}: {answer:?}"
        );
    }
}

#[tokio::test]
async fn a_pr_stacked_on_a_branch_with_no_queue_merges_directly_though_its_own_field_names_a_queue()
{
    // Perri's real data: the PR's `mergeQueue` is main's, the base has none.
    let pr = ready_pr(N)
        .on_base(STACKED)
        .with_merge_queue()
        .base_has_queue(false);
    let mut rig = queue_rig(pr).await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(row.merge_via, Some(MergeVia::Direct), "{row:?}");
    assert_eq!(
        serde_json::to_value(&row).unwrap()["merge_via"],
        "direct",
        "on the wire too"
    );

    let answer = rig
        .merge_via("s-1", REPO, N, &short('a'), MergeVia::Direct)
        .await;
    assert_eq!(code_of(&answer), "ok", "{answer:?}");
    assert_eq!(merge_requests_for(&rig, N).len(), 1, "merged over REST");
    assert!(rig.fake.enqueues().is_empty(), "never enqueued");
}

#[tokio::test]
async fn a_confirmation_worded_for_a_queue_on_a_branch_that_has_none_is_via_changed_and_nothing_is_sent(
) {
    let pr = ready_pr(N)
        .on_base(STACKED)
        .with_merge_queue()
        .base_has_queue(false);
    let mut rig = queue_rig(pr).await;
    let answer = rig
        .merge_via("s-2", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "via_changed", "{answer:?}");
    assert!(rig.fake.merges().is_empty(), "no merge");
    assert!(rig.fake.enqueues().is_empty(), "no enqueue");
}

#[tokio::test]
async fn a_queue_on_the_base_that_the_prs_own_field_does_not_confirm_is_unknown_and_nothing_is_sent(
) {
    let cases = [(1u64, STACKED, "stacked"), (2, "main", "main")];
    let mut rig = rig_over(
        cases
            .iter()
            .map(|(n, base, _)| ready_pr(*n).on_base(base).base_has_queue(true))
            .collect(),
    )
    .await;
    for (n, _, tag) in cases {
        let row = rig.row(REPO, n).unwrap();
        assert_eq!(row.merge_via, None, "{tag}: the row does not guess");
        assert!(
            serde_json::to_value(&row)
                .unwrap()
                .get("merge_via")
                .is_none(),
            "{tag}: absent on the wire"
        );
        assert_queue_unknown(&mut rig, n, tag).await;
    }
    assert!(
        rig.fake.merges().is_empty() && rig.fake.enqueues().is_empty(),
        "something was sent to GitHub"
    );
}

#[tokio::test]
async fn a_pr_stacked_on_a_branch_with_a_queue_that_both_reads_confirm_is_enqueued_once_without_jump_or_bypass(
) {
    let mut rig = queue_rig(ready_pr(N).on_base("merge/x").with_merge_queue()).await;
    assert_eq!(
        rig.row(REPO, N).unwrap().merge_via,
        Some(MergeVia::Queue),
        "the row says queue"
    );
    let answer = rig
        .merge_via("s-3", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "queued", "{answer:?}");
    assert!(rig.fake.merges().is_empty(), "never merged directly");
    let enq = rig.fake.enqueues();
    assert_eq!(enq.len(), 1, "{enq:?}");
    let body: Value = serde_json::from_str(&enq[0].body).expect("a JSON body");
    let vars: BTreeSet<&str> = body["variables"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(vars, BTreeSet::from(["head", "pr"]), "{body}");
    assert_eq!(body["variables"]["head"], sha('a').as_str());
    let lowered = enq[0].body.to_ascii_lowercase();
    for banned in ["jump", "admin", "bypass", "force", "override"] {
        assert!(!lowered.contains(banned), "{banned}: {}", enq[0].body);
    }
}

#[tokio::test]
async fn when_the_base_branchs_queue_cannot_be_read_nothing_is_sent_and_the_answer_is_queue_unknown(
) {
    // The base is the default branch (read with the PR) or another one (read by
    // the second request), with the PR's own field naming a queue or not.
    let mut cases = Vec::new();
    let mut n = 0;
    for base in ["main", STACKED] {
        for pr_has_queue in [true, false] {
            n += 1;
            cases.push((n, base, pr_has_queue));
        }
    }
    let mut rig = rig_over(
        cases
            .iter()
            .map(|(n, base, pr_has_queue)| {
                let pr = ready_pr(*n).on_base(base).base_queue_error();
                if *pr_has_queue {
                    pr.with_merge_queue()
                } else {
                    pr
                }
            })
            .collect(),
    )
    .await;
    for (n, base, pr_has_queue) in cases {
        let tag = format!("{base}/pr-queue={pr_has_queue}");
        let row = rig.row(REPO, n).unwrap();
        assert_eq!(row.merge_via, None, "{tag}: the row does not guess");
        // The rest of the row is still there: the unread queue costs nothing else.
        assert_eq!(row.lifecycle, Lifecycle::Open, "{tag}");
        assert_queue_unknown(&mut rig, n, &tag).await;
    }
    assert!(
        rig.fake.merges().is_empty() && rig.fake.enqueues().is_empty(),
        "something was sent to GitHub"
    );
}

#[tokio::test]
async fn a_failing_second_request_leaves_the_queue_unknown_not_the_poll_failed_and_the_next_read_recovers(
) {
    let mut rig = queue_rig(ready_pr(N).on_base("merge/x").with_merge_queue()).await;
    assert_eq!(rig.row(REPO, N).unwrap().merge_via, Some(MergeVia::Queue));

    // The next read: the PR's detail answers, the base queue read gets a 500.
    rig.fake.script_graphql(&[200, 500]);
    rig.fake.edit(REPO, N, |p| {
        p.updated_at = t0() + Chrono::minutes(5);
    });
    rig.run_until(mins(3), secs(1), |r| {
        r.row(REPO, N).is_some_and(|p| p.merge_via.is_none())
    })
    .await;
    let row = rig.row(REPO, N).unwrap();
    assert_eq!(row.merge_via, None, "unknown, not a guess: {row:?}");
    assert_eq!(row.lifecycle, Lifecycle::Open, "the PR is still shown");
    assert_eq!(row.title, TITLE);
    let poll = rig.snapshot().unwrap().poll;
    assert_ne!(
        poll.state,
        PollState::Error,
        "the poll did not fail: {poll:?}"
    );
    assert!(
        base_queue_reads(&rig).iter().any(|r| r.status == 500),
        "the scripted failure hit the second request"
    );

    // The same failure at the verb: the live read cannot say, so nothing is sent.
    rig.fake.script_graphql(&[200, 500]);
    let task = rig.spawn_merge_via("f-1", REPO, N, &short('a'), Some(MergeVia::Queue));
    let answer = rig.drive(task).await;
    assert_eq!(code_of(&answer), "queue_unknown", "{answer:?}");
    assert!(rig.fake.merges().is_empty() && rig.fake.enqueues().is_empty());

    // GitHub answers again: the next read knows the queue.
    rig.fake.edit(REPO, N, |p| {
        p.updated_at = t0() + Chrono::minutes(10);
    });
    rig.run_until(mins(3), secs(1), |r| {
        r.row(REPO, N)
            .is_some_and(|p| p.merge_via == Some(MergeVia::Queue))
    })
    .await;
    assert_eq!(rig.row(REPO, N).unwrap().merge_via, Some(MergeVia::Queue));
}

#[tokio::test]
async fn a_pr_retargeted_after_the_row_was_shown_is_via_changed_and_nothing_is_sent() {
    // (the base branch's queue, the app's wording) as the row showed it.
    // (Each on its own branch: the fake answers a branch's queue as the PRs on it say.)
    let cases = [(1u64, true, MergeVia::Queue), (2, false, MergeVia::Direct)];
    let mut rig = rig_over(
        cases
            .iter()
            .map(|(n, queue, _)| {
                let pr = ready_pr(*n).on_base(&format!("merge/a{n}"));
                if *queue {
                    pr.with_merge_queue()
                } else {
                    pr
                }
            })
            .collect(),
    )
    .await;
    for (n, _, via) in cases {
        assert_eq!(rig.row(REPO, n).unwrap().merge_via, Some(via));
        // On GitHub it now targets `main` (which answers the same way as its old base
        // did, so how it goes in has not changed, only where): the cached row is stale.
        rig.fake.edit(REPO, n, |p| p.base_ref = "main".into());
    }
    for (n, queue, via) in cases {
        let answer = rig
            .merge_via(&format!("r-{n}"), REPO, n, &short('a'), via)
            .await;
        assert_eq!(code_of(&answer), "via_changed", "queue={queue}: {answer:?}");
    }
    assert!(rig.fake.merges().is_empty(), "merged");
    assert!(rig.fake.enqueues().is_empty(), "enqueued");
}

#[tokio::test]
async fn the_base_branchs_queue_is_asked_for_only_open_prs_on_other_branches_and_the_branch_travels_as_a_variable(
) {
    let tricky = "merge/x\"} { evil: viewer { login } } #";
    let fake = Fake::new();
    fake.put(ready_pr(1).on_base("merge/a").with_merge_queue());
    fake.put(ready_pr(2).on_base(tricky));
    fake.put(ready_pr(3)); // on main
    let mut rig = boot(fake.clone()).await;

    let reads = base_queue_reads(&rig);
    assert!(!reads.is_empty(), "a PR on another branch needs the read");
    for r in &reads {
        let body: Value = serde_json::from_str(&r.body).expect("a JSON body");
        let query = body["query"].as_str().unwrap();
        // The branches are variables: nothing of them is in the query text.
        for branch in ["merge/a", tricky, "evil", "viewer"] {
            assert!(!query.contains(branch), "{branch} is in the query: {query}");
        }
        let vars: BTreeSet<&str> = body["variables"]
            .as_object()
            .expect("variables")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(vars.len(), 2, "one per PR on another branch: {body}");
        let mut branches: Vec<&str> = body["variables"]
            .as_object()
            .unwrap()
            .values()
            .filter_map(Value::as_str)
            .collect();
        branches.sort_unstable();
        assert_eq!(branches, vec!["merge/a", tricky], "not the PR on main");
    }
    // One request for the lot, not one each.
    let detail_reads = rig
        .of_kind(Kind::Graphql)
        .iter()
        .filter(|(_, r)| r.graphql_query().contains("pullRequest(number"))
        .count();
    assert!(
        reads.len() <= detail_reads,
        "{} vs {detail_reads}",
        reads.len()
    );

    // Once a PR has ended it is not asked about again.
    let mark = rig.fake.log_len();
    fake.edit(REPO, 1, |p| {
        p.state = "CLOSED".into();
        p.in_search = false;
    });
    fake.edit(REPO, 2, |p| {
        p.state = "CLOSED".into();
        p.in_search = false;
    });
    let seen = rig
        .run_until(mins(3), Duration::from_millis(500), |r| {
            [1, 2]
                .iter()
                .all(|n| r.row(REPO, *n).map(|p| p.lifecycle) == Some(Lifecycle::Closed))
        })
        .await;
    assert!(seen.is_some(), "the list never showed them as closed");
    assert!(
        rig.since(mark)
            .iter()
            .all(|r| !r.graphql_query().contains("mergeQueue(branch:")),
        "a closed PR was asked about its base queue"
    );
}

#[tokio::test]
async fn a_pr_on_the_default_branch_costs_no_extra_request() {
    let mut rig = queue_rig(queue_pr(N)).await;
    assert!(base_queue_reads(&rig).is_empty());
    for i in 0..3 {
        rig.fake.edit(REPO, N, |p| {
            p.updated_at = t0() + Chrono::minutes(5 * (i + 1));
        });
        rig.refresh().await;
        rig.run(secs(5), Duration::from_millis(500)).await;
    }
    assert!(
        base_queue_reads(&rig).is_empty(),
        "a second request was sent for a PR on main"
    );
    // Every GraphQL request of a poll is a detail read, and nothing else.
    for (_, r) in rig.of_kind(Kind::Graphql) {
        assert!(
            r.graphql_query().contains("pullRequest(number"),
            "{}",
            r.body
        );
    }
    assert_eq!(rig.row(REPO, N).unwrap().merge_via, Some(MergeVia::Queue));
}

#[tokio::test]
async fn a_moved_head_that_github_names_by_a_structured_code_is_head_changed_whatever_it_says() {
    let mut rig = queue_rig(queue_pr(N)).await;
    let refusals = [
        json!({"type": "STALE_HEAD", "message": "Something unrelated"}),
        json!({"extensions": {"code": "STALE_HEAD"}, "message": "Something unrelated"}),
        json!({"type": "UNPROCESSABLE", "message": "Head branch was modified. Review the latest changes and try again."}),
    ];
    for (i, error) in refusals.into_iter().enumerate() {
        rig.fake.enqueue_responds(Some((
            200,
            json!({"data": {"enqueuePullRequest": null}, "errors": [error.clone()]}),
        )));
        let answer = rig
            .merge_via(&format!("h-{i}"), REPO, N, &short('a'), MergeVia::Queue)
            .await;
        assert_eq!(code_of(&answer), "head_changed", "{error}: {answer:?}");
    }
    // A refusal GitHub gives no head wording for is a refusal, not a moved head.
    rig.fake.enqueue_responds(Some((
        200,
        json!({"data": {"enqueuePullRequest": null}, "errors": [
            {"type": "UNPROCESSABLE", "message": "Pull request is not mergeable"}]}),
    )));
    let answer = rig
        .merge_via("h-x", REPO, N, &short('a'), MergeVia::Queue)
        .await;
    assert_eq!(code_of(&answer), "queue_refused", "{answer:?}");
}
