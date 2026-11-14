//! The author's PR list shares GitHub with Perri's queue and Mother's PR
//! tracker, and must not change what either of them does: not one more
//! request, not a different one, not a different answer.
//!
//! These run on real time. Perri's fetch does its own network I/O, and on a
//! paused clock a timer could fire while its response is still on the wire.
//! Everything here is finished in well under a second.

#[path = "support/authored_prs_rig.rs"]
mod rig;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;
use wiremock::matchers::{method, path, path_regex, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

use nostromo::config::Config;
use nostromo::data::github_client::GithubClient;
use nostromo::data::perri_queue_native::{PerriQueueNativeSource, QueueCaches, API_BASE_OVERRIDE};
use nostromo::data::perri_suppress::SuppressStore;
use nostromo::data::relay_client::RelayStatus;
use nostromo::mother::audit::MotherAudit;
use nostromo::mother::notices::pr_state::{
    CommandOutput, CommandRunner, GhProbe, PrTracker, ProbeError,
};
use nostromo::mother::notices::{Clock, ManualClock, NoticeConfig, NoticeEngine};
use nostromo::mother::origin::{JobAnnotation, OriginKind, OriginView};
use nostromo::mother::MotherJob;
use rig::*;

const PERRI_REPO: &str = "Carefeed/admin-portal";

// ── Perri's side ──────────────────────────────────────────────────────────────

async fn mount_perri(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/user"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login": ME})))
        .mount(server)
        .await;
    let item = json!({
        "number": 42,
        "title": "PR 42",
        "html_url": format!("https://github.com/{PERRI_REPO}/pull/42"),
        "repository_url": format!("https://api.github.com/repos/{PERRI_REPO}"),
        "user": {"login": "alice"},
        "draft": false,
        "updated_at": "2026-06-07T12:00:00Z",
    });
    for (q, items) in [
        ("is:open is:pr review-requested:@me org:Carefeed archived:false", vec![]),
        ("is:open is:pr review:required org:Carefeed archived:false", vec![item]),
        ("is:open is:pr reviewed-by:@me org:Carefeed archived:false", vec![]),
    ] {
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .and(query_param("q", q))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": items})))
            .mount(server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path(format!("/repos/{PERRI_REPO}/pulls/42")))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"head": {"sha": "sha-42"}, "state": "open", "merged_at": null}),
        ))
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path_regex(r".*/commits/.*/check-runs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "check_runs": [{"name": "build", "status": "completed", "conclusion": "success",
                            "id": 1, "app": {"slug": "github-actions"}, "output": {}}]
        })))
        .mount(server)
        .await;
}

struct Perri {
    source: PerriQueueNativeSource,
    client: GithubClient,
    suppress: Arc<Mutex<SuppressStore>>,
    caches: QueueCaches,
    _dir: tempfile::TempDir,
}

impl Perri {
    fn new(base_uri: &str) -> Perri {
        API_BASE_OVERRIDE.with(|c| *c.borrow_mut() = Some(base_uri.to_owned()));
        let dir = tempfile::tempdir().unwrap();
        let hosts = dir.path().join("hosts.yml");
        std::fs::write(
            &hosts,
            "github.com:\n  oauth_token: test-token\n  user: tester\n  git_protocol: https\n",
        )
        .unwrap();
        std::env::remove_var("GITHUB_TOKEN");
        let config = Config {
            github_token_path: Some(hosts.clone()),
            perri_state: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        Perri {
            source: PerriQueueNativeSource::new(config),
            client: GithubClient::new(Some(&hosts)).unwrap(),
            suppress: Arc::new(Mutex::new(SuppressStore::new(
                dir.path().join("approvals-state.json"),
                Duration::from_secs(900),
            ))),
            caches: QueueCaches::default(),
            _dir: dir,
        }
    }

    /// `(number, bucket)` of every item of one full queue fetch.
    async fn fetch(&mut self) -> Vec<(u64, String)> {
        self.source
            .fetch(&self.client, ME, &mut self.caches, &self.suppress)
            .await
            .expect("Perri's fetch succeeds")
            .items
            .into_iter()
            .map(|i| (i.number, i.bucket))
            .collect()
    }
}

/// `GET /path?query` of every request on `server` whose User-Agent is (or is
/// not) the feature's own.
async fn requests(server: &MockServer, authored: bool) -> Vec<String> {
    let mut out: Vec<String> = server
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|r| {
            let ua = r.headers.get("user-agent").and_then(|v| v.to_str().ok());
            (ua == Some(UA)) == authored
        })
        .map(|r| match r.url.query() {
            Some(q) => format!("{} {}?{q}", r.method, r.url.path()),
            None => format!("{} {}", r.method, r.url.path()),
        })
        .collect();
    out.sort();
    out
}

async fn wait_for(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !cond() {
        assert!(std::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn authored_fake() -> Fake {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/proj", 5).pending("build"));
    fake.put(FakePr::new("Carefeed/app", 6).passing("build"));
    fake
}

/// The authored-PR engine, visible, on `server`, with its own PRs.
async fn start_feature(server: MockServer) -> Rig {
    let fake = authored_fake();
    fake.mount_on(&server, Some(UA)).await;
    let rig = Rig::start_real_time(server, fake).await;
    rig.demand.set("operator", "visible");
    rig
}

async fn feature_finished(rig: &Rig) {
    wait_for("the feature's first reconcile", || {
        rig.fake.log_len() >= 3 && rig.snapshot().is_some_and(|s| s.prs.len() == 2)
    })
    .await;
}

// ── Perri ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn perris_queue_fetch_makes_the_same_requests_and_gets_the_same_answer_with_the_feature_off_and_on() {
    // Off: no authored-PR engine at all.
    let off_server = MockServer::start().await;
    mount_perri(&off_server).await;
    let mut perri = Perri::new(&off_server.uri());
    let off_items = perri.fetch().await;
    let off_requests = requests(&off_server, false).await;
    assert!(requests(&off_server, true).await.is_empty());
    assert!(!off_requests.is_empty(), "Perri did fetch: {off_requests:?}");
    assert_eq!(off_items.iter().map(|i| i.0).collect::<Vec<_>>(), vec![42]);

    // On: the engine runs its reconcile on the same server while Perri fetches.
    let on_server = MockServer::start().await;
    mount_perri(&on_server).await;
    let rig = start_feature(on_server).await;
    let mut perri = Perri::new(&rig.server.uri());
    let on_items = perri.fetch().await;
    feature_finished(&rig).await;

    let on_requests = requests(&rig.server, false).await;
    let authored = requests(&rig.server, true).await;
    assert_eq!(
        on_requests, off_requests,
        "Perri's paths and counts are what they were without the feature"
    );
    assert_eq!(on_items, off_items, "and so is its answer");

    // The feature's own traffic is told apart by its User-Agent, and is only
    // its three endpoints.
    assert!(authored.len() >= 3, "{authored:?}");
    for r in &authored {
        assert!(
            r.starts_with("GET /user")
                || r.starts_with("GET /search/issues?q=is:pr+is:open+author:@me")
                || r.starts_with("POST /graphql"),
            "{r}"
        );
    }
    // And none of Perri's requests is one of the feature's.
    assert!(on_requests.iter().all(|r| !r.contains("author:@me")), "{on_requests:?}");
}

#[tokio::test]
async fn perris_etag_caches_are_not_disturbed_by_the_features_conditional_searches() {
    let server = MockServer::start().await;
    mount_perri(&server).await;
    let rig = start_feature(server).await;
    let mut perri = Perri::new(&rig.server.uri());
    let first = perri.fetch().await;
    feature_finished(&rig).await;
    let second = perri.fetch().await;
    assert_eq!(first, second);
    assert_eq!(first.iter().map(|i| i.0).collect::<Vec<_>>(), vec![42]);
}

// ── Mother's PR tracker ───────────────────────────────────────────────────────

#[derive(Default)]
struct RecordingRunner {
    calls: Mutex<Vec<Vec<String>>>,
}

#[async_trait]
impl CommandRunner for RecordingRunner {
    async fn run(
        &self,
        program: &str,
        args: &[String],
        _timeout: Duration,
    ) -> Result<CommandOutput, ProbeError> {
        let mut call = vec![program.to_owned()];
        call.extend(args.iter().cloned());
        self.calls.lock().unwrap().push(call);
        Ok(CommandOutput {
            success: true,
            stdout: json!({"state": "OPEN", "mergedAt": null}).to_string(),
        })
    }
}

fn mother_job() -> MotherJob {
    MotherJob {
        id: "job-1".into(),
        state: "succeeded".into(),
        title: "A job".into(),
        pr_url: Some("https://github.com/thehammer/proj/pull/5".into()),
        nostromo: Some(JobAnnotation {
            origin: OriginView {
                kind: OriginKind::Focus,
                focus_tag: Some("focus-a".into()),
                ..Default::default()
            },
            ..Default::default()
        }),
        ..Default::default()
    }
}

/// Every command the PR tracker ran in one poll cycle.
async fn tracker_commands(with_feature: bool) -> Vec<Vec<String>> {
    let clock = ManualClock::new(1_792_497_600_000);
    let engine = NoticeEngine::new(NoticeConfig {
        store_path: None,
        audit: MotherAudit::disabled(),
        clock: Arc::new(clock.clone()),
    });
    engine.on_jobs(&[mother_job()]);
    let runner = Arc::new(RecordingRunner::default());
    let status = Arc::new(RelayStatus::new());
    status.set_connected(true);
    let clock: Arc<dyn Clock> = Arc::new(clock);
    let tracker = PrTracker::new(
        Arc::clone(&engine),
        Arc::new(GhProbe::new(runner.clone(), "gh".into())),
        status,
        clock,
    );

    let _rig = if with_feature {
        let server = MockServer::start().await;
        let rig = start_feature(server).await;
        feature_finished(&rig).await;
        Some(rig)
    } else {
        None
    };
    tracker.poll_cycle().await;
    let calls = runner.calls.lock().unwrap().clone();
    calls
}

#[tokio::test]
async fn the_pr_tracker_runs_the_same_gh_commands_with_the_feature_off_and_on() {
    let off = tracker_commands(false).await;
    assert_eq!(
        off,
        vec![vec![
            "gh".to_string(),
            "pr".into(),
            "view".into(),
            "https://github.com/thehammer/proj/pull/5".into(),
            "--json".into(),
            "state,mergedAt".into()
        ]],
        "the tracker probes the job's PR once, through gh"
    );
    let on = tracker_commands(true).await;
    assert_eq!(on, off, "the authored-PR list adds no gh call");
}
