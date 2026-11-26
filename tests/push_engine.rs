//! W13-8..24, 35, 37 (partly): the push engine, end to end, in process.
//!
//! A real `PushEngine` (the one `nostromd` starts) against a `wiremock` relay.
//! Nothing here touches AWS, Apple or a real token: the relay is a local mock,
//! every APNs token is an obvious fake (`"ab".repeat(32)`), and the clock is
//! fabricated. The engine is driven the way its own loop drives it, minus the
//! wall clock: `ingest(frame, now)` is what the broadcast channel delivers and
//! `step_at(now)` plans AND sends (awaiting each send). A paired phone's verbs
//! go through `dispatch(msg, trust, ws_device, reply)`.
//!
//! Conventions:
//! * a device's first `step_at` is its baseline, and a host's first snapshot is
//!   what was "already waiting", so every scenario seeds each host with an empty
//!   snapshot and takes the baseline step BEFORE the item under test appears;
//! * an item that has no start of its own (a review) starts when it is first seen,
//!   so `step_at` follows every `ingest` at the same instant.

#![allow(clippy::too_many_arguments)]

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Duration, Utc};
use nostromo::config::PushConfig;
use nostromo::data::perri_queue::PrQueueItem;
use nostromo::ipc::devices::{DeviceKind, DeviceRegistry, RevokedBy, SatelliteAdmin};
use nostromo::ipc::peer::{PeerTrust, SensitiveTags};
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, DecisionResolution, ServerMsg};
use nostromo::ipc::uplink_redact::redact_for_uplink_metadata;
use nostromo::mother::MotherJob;
use nostromo::push::vocab::{conforms, VocabContext};
use nostromo::push::wire::{
    AgentClass, HostClass, Presence, PushCapabilities, PushEnvironment, PushKind, PushOutcome,
    PushPrefs, PushSentEntry, PushStatusBody, PushWaitingItem,
};
use nostromo::push::{ConfigSource, Dispatched, PushEngine};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::mpsc;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── time ─────────────────────────────────────────────────────────────────────

/// 10:00 UTC today: outside default quiet hours, before 17:30. (Today, so the
/// real `Utc::now()` that `PushSentLog` and `PushWaiting` read stays near it.)
fn base() -> DateTime<Utc> {
    Utc::now()
        .date_naive()
        .and_hms_opt(10, 0, 0)
        .unwrap()
        .and_utc()
}

fn secs(n: i64) -> Duration {
    Duration::seconds(n)
}

fn token_a() -> String {
    "ab".repeat(32)
}

fn token_b() -> String {
    "cd".repeat(32)
}

// ── the rig ──────────────────────────────────────────────────────────────────

struct Rig {
    relay: MockServer,
    engine: Arc<PushEngine>,
    cfg: Arc<Mutex<PushConfig>>,
    tmp: TempDir,
    tx: mpsc::UnboundedSender<ServerMsg>,
    rx: mpsc::UnboundedReceiver<ServerMsg>,
    tokens: BTreeMap<String, String>,
}

fn ok_response() -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({"apns_status": 200}))
}

fn dead_url() -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    format!("http://127.0.0.1:{port}")
}

impl Rig {
    /// A relay that answers every push with Apple's 200.
    async fn new() -> Self {
        let rig = Self::build(None, None, |_| {}).await;
        rig.mount(ok_response(), None).await;
        rig
    }

    async fn with_hosts(hosts: &[(&str, HostClass)]) -> Self {
        let hosts: Vec<(String, HostClass)> =
            hosts.iter().map(|(h, c)| (h.to_string(), *c)).collect();
        let rig = Self::build(None, None, move |cfg| {
            for (h, c) in hosts {
                cfg.hosts.insert(h, c);
            }
        })
        .await;
        rig.mount(ok_response(), None).await;
        rig
    }

    /// No relay behaviour mounted yet: the caller mounts what it wants, in order.
    async fn build(
        registry: Option<Arc<DeviceRegistry>>,
        relay_url: Option<String>,
        edit: impl FnOnce(&mut PushConfig),
    ) -> Self {
        let relay = MockServer::start().await;
        let tmp = TempDir::new().unwrap();
        let token = tmp.path().join("relay-token");
        std::fs::write(&token, "fake-relay-token\n").unwrap();
        let mut cfg = PushConfig {
            relay_url: Some(relay_url.unwrap_or_else(|| relay.uri())),
            relay_token_path: Some(token),
            state_dir: Some(tmp.path().join("push")),
            ..Default::default()
        };
        edit(&mut cfg);
        let cfg = Arc::new(Mutex::new(cfg));
        let source: ConfigSource = {
            let cfg = Arc::clone(&cfg);
            Arc::new(move || cfg.lock().unwrap().clone())
        };
        let engine = PushEngine::new(source, "tokyo".into(), registry).expect("an engine");
        let (tx, rx) = mpsc::unbounded_channel();
        Rig {
            relay,
            engine,
            cfg,
            tmp,
            tx,
            rx,
            tokens: BTreeMap::new(),
        }
    }

    async fn mount(&self, response: ResponseTemplate, times: Option<u64>) {
        let mut mock = Mock::given(method("POST"))
            .and(path("/push"))
            .respond_with(response);
        if let Some(n) = times {
            mock = mock.up_to_n_times(n);
        }
        mock.mount(&self.relay).await;
    }

    fn state_dir(&self) -> std::path::PathBuf {
        self.tmp.path().join("push")
    }

    // ── a phone's verbs ──────────────────────────────────────────────────────

    fn drain(&mut self) -> Vec<ServerMsg> {
        let mut out = Vec::new();
        while let Ok(m) = self.rx.try_recv() {
            out.push(m);
        }
        out
    }

    fn verb(
        &mut self,
        msg: &ClientMsg,
        trust: PeerTrust,
        device: Option<&str>,
    ) -> (Dispatched, Vec<ServerMsg>) {
        let handled = self.engine.dispatch(msg, trust, device, &self.tx);
        (handled, self.drain())
    }

    /// A verb from the paired phone `device`; it must be handled.
    fn paired(&mut self, device: &str, msg: &ClientMsg) -> Vec<ServerMsg> {
        let (handled, replies) = self.verb(msg, PeerTrust::Paired, Some(device));
        assert_eq!(handled, Dispatched::Handled, "{msg:?}");
        replies
    }

    fn register_with(
        &mut self,
        device: &str,
        token: &str,
        tz: &str,
        caps: PushCapabilities,
    ) -> PushStatusBody {
        self.tokens.insert(device.to_string(), token.to_string());
        let replies = self.paired(
            device,
            &ClientMsg::RegisterPush {
                apns_token: token.to_string(),
                environment: PushEnvironment::Sandbox,
                tz: tz.to_string(),
                capabilities: caps,
            },
        );
        status_of(replies)
    }

    fn register(&mut self, device: &str, token: &str) -> PushStatusBody {
        self.register_with(device, token, "UTC", PushCapabilities::default())
    }

    fn set_prefs(&mut self, device: &str, prefs: PushPrefs) -> PushStatusBody {
        status_of(self.paired(device, &ClientMsg::SetPushPrefs { prefs }))
    }

    /// The device's status, asked through an idempotent re-registration.
    fn status(&mut self, device: &str) -> PushStatusBody {
        let token = self
            .tokens
            .get(device)
            .cloned()
            .expect("a registered device");
        let caps = PushCapabilities::default();
        self.register_with(device, &token, "UTC", caps)
    }

    fn sent_log(&mut self, device: &str) -> Vec<PushSentEntry> {
        match self.paired(device, &ClientMsg::PushSentLog).pop() {
            Some(ServerMsg::PushSentLog { entries }) => entries,
            other => panic!("expected PushSentLog, got {other:?}"),
        }
    }

    fn waiting(&mut self, device: &str) -> (Vec<PushWaitingItem>, u32) {
        match self.paired(device, &ClientMsg::PushWaiting).pop() {
            Some(ServerMsg::PushWaiting { items, badge }) => (items, badge),
            other => panic!("expected PushWaiting, got {other:?}"),
        }
    }

    // ── what reached the relay ───────────────────────────────────────────────

    async fn raw_posts(&self) -> Vec<wiremock::Request> {
        self.relay.received_requests().await.unwrap_or_default()
    }

    async fn posts(&self) -> Vec<Value> {
        self.raw_posts()
            .await
            .iter()
            .map(|r| serde_json::from_slice(&r.body).expect("a JSON body"))
            .collect()
    }

    async fn posts_to(&self, token: &str) -> Vec<Value> {
        self.posts()
            .await
            .into_iter()
            .filter(|p| p["apns_token"] == token)
            .collect()
    }

    // ── a quiet start: every host seeded empty, the device's baseline taken ──

    /// Seed `hosts` (Mother and review snapshots) as empty and take the baseline
    /// step at `t`.
    async fn start(&mut self, hosts: &[&str], t: DateTime<Utc>) {
        for host in hosts {
            self.engine.ingest(jobs_frame(Some(host), vec![]), t);
            self.engine.ingest(queue_frame(Some(host), vec![]), t);
        }
        self.engine.step_at(t).await;
    }
}

fn status_of(mut replies: Vec<ServerMsg>) -> PushStatusBody {
    match replies.pop() {
        Some(ServerMsg::PushStatus(body)) => body,
        other => panic!("expected PushStatus, got {other:?}"),
    }
}

// ── frames ───────────────────────────────────────────────────────────────────

fn job_id(suffix: &str) -> String {
    format!("20261126T100000Z-{suffix}")
}

/// A Mother job with a marker in every free-text field.
fn job(
    suffix: &str,
    state: &str,
    paused_reason: Option<&str>,
    paused_at: Option<DateTime<Utc>>,
    pr_url: Option<&str>,
) -> MotherJob {
    let mut v = json!({
        "id": job_id(suffix), "state": state,
        "title": "MARKER-title", "repo": "MARKER-repo", "plan_path": "/MARKER-plan.md",
        "question": "MARKER-question", "adherence_notes": "MARKER-notes",
        "current_activity": "MARKER-activity-text", "failure_reason": "MARKER-failure",
        "origin": {"label": "MARKER-label", "focus_name": "MARKER-focus", "session": "MARKER-session"},
    });
    let o = v.as_object_mut().unwrap();
    if let Some(r) = paused_reason {
        o.insert("paused_reason".into(), json!(r));
    }
    if let Some(t) = paused_at {
        o.insert("paused_at".into(), json!(t.to_rfc3339()));
    }
    if let Some(u) = pr_url {
        o.insert("pr_url".into(), json!(u));
    }
    serde_json::from_value(v).unwrap()
}

fn awaiting(suffix: &str, paused_at: DateTime<Utc>) -> MotherJob {
    job(suffix, "awaiting", Some("user"), Some(paused_at), None)
}

fn running(suffix: &str) -> MotherJob {
    job(suffix, "running", None, None, None)
}

fn jobs_frame(host: Option<&str>, jobs: Vec<MotherJob>) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs,
        host: host.map(str::to_string),
    }
}

fn pr(repo: &str, number: u64, bucket: &str, changed_lines: Option<u64>) -> PrQueueItem {
    PrQueueItem {
        repo: repo.into(),
        number,
        title: "MARKER-pr-title".into(),
        author: "MARKER-author".into(),
        bucket: bucket.into(),
        url: "https://github.com/MARKER-owner/MARKER-repo/pull/1".into(),
        tickets: vec!["MARKER-ticket".into()],
        changed_lines,
        ..Default::default()
    }
}

fn queue_frame(host: Option<&str>, queue: Vec<PrQueueItem>) -> ServerMsg {
    ServerMsg::PerriState {
        tag: "f-00000000".into(),
        queue,
        current: None,
        jira_site: None,
        host: host.map(str::to_string),
    }
}

fn decision_frame(
    host: Option<&str>,
    id: &str,
    deadline: Option<DateTime<Utc>>,
    agent: Option<AgentClass>,
    presence: Option<Presence>,
) -> ServerMsg {
    decision_frame_for(
        host,
        id,
        deadline,
        agent,
        presence,
        "MARKER-repo",
        "MARKER-owner",
    )
}

fn decision_frame_for(
    host: Option<&str>,
    id: &str,
    deadline: Option<DateTime<Utc>>,
    agent: Option<AgentClass>,
    presence: Option<Presence>,
    repo: &str,
    owner: &str,
) -> ServerMsg {
    ServerMsg::DecisionRequest {
        tag: "claudia-MARKER-session".into(),
        request_id: id.into(),
        prompt: "MARKER-prompt".into(),
        detail: Some("MARKER-detail".into()),
        choices: (0..3)
            .map(|i| DecisionChoice {
                id: format!("c{i}"),
                label: "MARKER-choice-label".into(),
                detail: Some("MARKER-choice-detail".into()),
                is_default: i == 0,
            })
            .collect(),
        context_pane_id: Some("MARKER-pane".into()),
        host: host.map(str::to_string),
        deadline,
        agent_class: agent,
        operator_presence: presence,
        repo: Some(repo.into()),
        repo_owner: Some(owner.into()),
    }
}

fn resolved_frame(host: Option<&str>, id: &str) -> ServerMsg {
    ServerMsg::DecisionResolved {
        tag: "claudia-MARKER-session".into(),
        request_id: id.into(),
        resolution: DecisionResolution::Answered,
        choice_id: Some("c0".into()),
        host: host.map(str::to_string),
    }
}

// ── assertions on what the relay saw ─────────────────────────────────────────

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object().unwrap().keys().cloned().collect()
}

fn set(words: &[&str]) -> BTreeSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The shape every request has, whatever it says: Apple's `alert` push type
/// only (never a background push), exactly the fields the relay accepts, and a
/// `data` object of only the vocabulary's keys.
fn assert_request_shape(p: &Value) {
    assert_eq!(p["push_type"], "alert", "never a background push: {p}");
    let top = keys(p);
    let mut allowed = set(&[
        "push_id",
        "apns_token",
        "environment",
        "push_type",
        "priority",
        "expiration_unix",
        "collapse_id",
        "thread_id",
        "interruption_level",
        "badge",
        "mutable_content",
        "data",
    ]);
    let have_text = top.contains("title");
    assert_eq!(
        top.contains("body"),
        have_text,
        "title and body come together: {p}"
    );
    if have_text {
        allowed.insert("title".into());
        allowed.insert("body".into());
    }
    assert_eq!(top, allowed, "{p}");
    assert!(is_hex(p["push_id"].as_str().unwrap(), 32), "{p}");
    assert_eq!(
        p["mutable_content"], false,
        "W13 never asks for the extension: {p}"
    );
    let data = keys(&p["data"]);
    assert!(
        data.is_subset(&set(&["item", "kind", "host", "ref", "resolved"]))
            && data.is_superset(&set(&["item", "kind", "host"])),
        "data holds only the vocabulary's keys: {p}"
    );
    let text = p.to_string();
    assert!(
        !text.contains("background") && !text.contains("content-available"),
        "{p}"
    );
}

fn data_kind(p: &Value) -> &str {
    p["data"]["kind"].as_str().unwrap()
}

// ── W13-8, W13-10, W13-12: one POST at grace end, with the exact contract ────

#[tokio::test]
async fn a_satellite_mother_job_is_posted_once_at_the_end_of_its_grace_delay_with_the_exact_contract(
) {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;

    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(119)).await;
    assert!(rig.posts().await.is_empty(), "never before 120 s");

    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "exactly one POST at grace end: {posts:#?}");
    let p = &posts[0];
    assert_request_shape(p);
    assert_eq!(p["title"], "Mother · kobe");
    assert_eq!(p["body"], "Job 3f9a1c2e asked a question");
    assert_eq!(p["thread_id"], "kobe");
    assert_eq!(p["interruption_level"], "active");
    assert_eq!(p["priority"], 10);
    assert_eq!(p["badge"], 1);
    assert_eq!(p["environment"], "sandbox");
    assert_eq!(p["apns_token"], token_a());
    assert_eq!(
        p["expiration_unix"],
        (t0 + secs(120) + Duration::hours(4)).timestamp(),
        "send time + 4 h"
    );
    let item = p["collapse_id"].as_str().unwrap();
    assert!(is_hex(item, 16), "an opaque random item ref: {item}");
    assert_eq!(p["data"]["item"], item);
    assert_eq!(p["data"]["kind"], "mother");
    assert_eq!(p["data"]["host"], "kobe");
    assert_eq!(p["data"]["ref"], "Job 3f9a1c2e");
    assert_eq!(keys(&p["data"]), set(&["item", "kind", "host", "ref"]));

    // The request itself: POST /push with the daemon's bearer.
    let raw = rig.raw_posts().await;
    assert_eq!(raw[0].method.as_str(), "POST");
    assert_eq!(raw[0].url.path(), "/push");
    assert_eq!(
        raw[0]
            .headers
            .get("authorization")
            .unwrap()
            .to_str()
            .unwrap(),
        "Bearer fake-relay-token"
    );

    // One notification per item over its lifetime: no reminders, however long it waits.
    for t in [121, 600, 3 * 3600] {
        rig.engine.step_at(t0 + secs(t)).await;
    }
    assert_eq!(rig.posts().await.len(), 1);
}

#[tokio::test]
async fn a_review_is_posted_at_the_end_of_its_grace_delay_with_the_waiting_count() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let queue = vec![
        pr("Carefeed/admin-portal", 4821, "requested", Some(10)),
        pr("Carefeed/admin-portal", 4822, "requested", Some(900)),
        pr("Carefeed/admin-portal", 4823, "requested", Some(120)),
        pr("Carefeed/admin-portal", 4824, "needs_review", Some(5)),
    ];
    rig.engine.ingest(queue_frame(Some("kobe"), queue), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(119)).await;
    assert!(rig.posts().await.is_empty());
    rig.engine.step_at(t0 + secs(120)).await;

    let posts = rig.posts().await;
    assert_eq!(
        posts.len(),
        3,
        "three requested PRs, the fourth is not in the bucket"
    );
    let mut bodies: Vec<String> = posts
        .iter()
        .map(|p| p["body"].as_str().unwrap().to_string())
        .collect();
    bodies.sort();
    assert_eq!(
        bodies,
        vec![
            "PR #4821 · small change · 3 waiting",
            "PR #4822 · large change · 3 waiting",
            "PR #4823 · medium change · 3 waiting",
        ]
    );
    for p in &posts {
        assert_request_shape(p);
        assert_eq!(p["title"], "Review · kobe");
        assert_eq!(p["interruption_level"], "active");
        assert_eq!(p["thread_id"], "kobe");
        assert_eq!(data_kind(p), "review");
        assert_eq!(p["badge"], 3);
    }
}

#[tokio::test]
async fn an_item_resolved_before_its_grace_delay_ends_is_never_posted_and_the_skip_is_logged() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![running("3f9a1c2e")]),
        t0 + secs(119),
    );
    rig.engine.step_at(t0 + secs(119)).await;
    rig.engine.step_at(t0 + secs(120)).await;
    rig.engine.step_at(t0 + secs(600)).await;
    assert!(rig.posts().await.is_empty());
    let log = rig.sent_log("dev-1");
    assert_eq!(log.len(), 1, "{log:?}");
    assert_eq!(log[0].outcome, PushOutcome::SkippedResolvedInGrace);
    assert_eq!(log[0].kind, "mother");
    assert_eq!(log[0].host, "kobe");
    assert_eq!(log[0].title, "Mother · kobe");
    assert_eq!(log[0].body, "Job 3f9a1c2e asked a question");
}

// ── W13-11, W13-35: withdrawal ───────────────────────────────────────────────

#[tokio::test]
async fn a_job_that_stops_needing_the_operator_gets_one_passive_replacement_with_the_same_collapse_id(
) {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert_eq!(rig.posts().await.len(), 1);

    // Answered at the Mac: the job leaves `awaiting`.
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![running("3f9a1c2e")]),
        t0 + secs(150),
    );
    rig.engine.step_at(t0 + secs(150)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2, "exactly one replacement: {posts:#?}");
    let (first, second) = (&posts[0], &posts[1]);
    assert_request_shape(second);
    assert_eq!(
        second["collapse_id"], first["collapse_id"],
        "replaces in place"
    );
    assert_eq!(second["data"]["item"], first["data"]["item"]);
    assert_eq!(second["interruption_level"], "passive");
    assert_eq!(second["priority"], 10);
    assert_eq!(second["title"], "Mother · kobe");
    assert_eq!(second["body"], "Job 3f9a1c2e no longer needs you");
    assert_eq!(second["badge"], 0);
    assert_eq!(second["data"]["resolved"], true);
    assert_eq!(second["thread_id"], "kobe");
    assert_eq!(second["push_type"], "alert", "no background push, ever");
    assert_eq!(
        second["expiration_unix"],
        (t0 + secs(150) + Duration::hours(4)).timestamp()
    );

    // Whatever the phone did with the original (dismissed or not), the
    // replacement is sent once, and never repeated.
    for t in [151, 400, 7200] {
        rig.engine.step_at(t0 + secs(t)).await;
    }
    assert_eq!(rig.posts().await.len(), 2);
    let log = rig.sent_log("dev-1");
    assert_eq!(
        log.iter().map(|e| e.outcome).collect::<Vec<_>>(),
        vec![PushOutcome::DeliveredToApple, PushOutcome::Withdrawn]
    );
    assert_eq!(log[1].body, "Job 3f9a1c2e no longer needs you");
}

#[tokio::test]
async fn a_withdrawal_carries_the_decremented_badge() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![awaiting("aaaa0001", t0), awaiting("aaaa0002", t0)],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2);
    assert!(posts.iter().all(|p| p["badge"] == 2), "{posts:#?}");

    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("aaaa0002", t0)]),
        t0 + secs(130),
    );
    rig.engine.step_at(t0 + secs(130)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 3);
    assert_eq!(posts[2]["badge"], 1);
    assert_eq!(posts[2]["body"], "Job aaaa0001 no longer needs you");

    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![]), t0 + secs(140));
    rig.engine.step_at(t0 + secs(140)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 4);
    assert_eq!(posts[3]["badge"], 0);
}

#[tokio::test]
async fn an_item_that_never_had_a_notification_leaves_as_a_badge_only_push() {
    // A job already waiting when the host first reported: counted, never pushed.
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0 - secs(3600))]),
        t0,
    );
    rig.engine.step_at(t0).await;
    for t in [30, 120, 600, 3600] {
        rig.engine.step_at(t0 + secs(t)).await;
    }
    assert!(
        rig.posts().await.is_empty(),
        "a restart does not re-push what was waiting"
    );
    let (items, badge) = rig.waiting("dev-1");
    assert_eq!((items.len(), badge), (1, 1), "but it is counted");

    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![]), t0 + secs(4000));
    rig.engine.step_at(t0 + secs(4000)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    let p = &posts[0];
    assert_request_shape(p);
    assert!(
        p.get("title").is_none() && p.get("body").is_none(),
        "no text: {p}"
    );
    assert_eq!(p["priority"], 5);
    assert_eq!(p["badge"], 0);
    assert_eq!(p["interruption_level"], "passive");
    assert_eq!(p["data"]["resolved"], true);
    assert_eq!(p["thread_id"], "kobe");
    // A badge correction is not a notification: it is not listed.
    assert!(rig.sent_log("dev-1").is_empty());
}

#[tokio::test]
async fn a_satellite_that_connects_after_the_device_has_its_first_snapshot_counted_not_pushed() {
    // The device is long baselined and nothing is waiting. Kobe then connects, and its first
    // snapshot holds a job paused an hour ago and a review: they were already waiting.
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&[], t0).await;
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0 - secs(3600))]),
        t0 + secs(5),
    );
    rig.engine.ingest(
        queue_frame(
            Some("kobe"),
            vec![pr("Carefeed/admin-portal", 1, "requested", Some(5))],
        ),
        t0 + secs(5),
    );
    rig.engine.step_at(t0 + secs(5)).await;
    rig.engine.step_at(t0 + secs(300)).await;
    assert!(
        rig.posts().await.is_empty(),
        "already waiting when it connected: counted, never pushed"
    );
    assert_eq!(rig.waiting("dev-1").1, 2, "but counted");

    // A job that appears in a later snapshot is a new item, pushed as usual.
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![
                awaiting("aaaa0001", t0 - secs(3600)),
                awaiting("aaaa0002", t0 + secs(400)),
            ],
        ),
        t0 + secs(400),
    );
    rig.engine.step_at(t0 + secs(400)).await;
    rig.engine.step_at(t0 + secs(520)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert_eq!(posts[0]["body"], "Job aaaa0002 asked a question");
}

// ── W13-29, W13-34: attention items are counted, never pushed ────────────────

fn with_attention(suffix: &str, reasons: Value) -> MotherJob {
    let mut j = running(suffix);
    j = serde_json::from_value({
        let mut v = serde_json::to_value(&j).unwrap();
        v["attention_reasons"] = reasons;
        v
    })
    .unwrap();
    j
}

#[tokio::test]
async fn an_attention_item_is_counted_in_the_badge_never_pushed_and_withdrawn_by_badge_when_acked()
{
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;

    let raised = with_attention(
        "3f9a1c2e",
        json!([
            {"reason": "progress_stalled", "since": "2026-11-26T09:00:00Z", "acked": false},
            {"reason": "burn_ahead", "since": "2026-11-26T09:05:00Z", "acked": false},
            {"reason": "gates_incomplete", "since": "2026-11-26T09:10:00Z", "acked": false},
        ]),
    );
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![raised]), t0 + secs(10));
    rig.engine.step_at(t0 + secs(10)).await;
    for t in [130, 600, 3 * 3600] {
        rig.engine.step_at(t0 + secs(t)).await;
    }
    assert!(
        rig.posts().await.is_empty(),
        "attention never pushes on its own"
    );
    let (items, badge) = rig.waiting("dev-1");
    assert_eq!(badge, 3, "all three count toward the badge");
    assert_eq!(items.len(), 3);

    // Acked on the host: one of them leaves, as a badge correction (no text).
    let acked = with_attention(
        "3f9a1c2e",
        json!([
            {"reason": "progress_stalled", "since": "2026-11-26T09:00:00Z", "acked": true},
            {"reason": "burn_ahead", "since": "2026-11-26T09:05:00Z", "acked": false},
            {"reason": "gates_incomplete", "since": "2026-11-26T09:10:00Z", "acked": false},
        ]),
    );
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![acked]), t0 + secs(4 * 3600));
    rig.engine.step_at(t0 + secs(4 * 3600)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert!(posts[0].get("title").is_none());
    assert_eq!(posts[0]["badge"], 2);
    assert_eq!(posts[0]["priority"], 5);
}

#[tokio::test]
async fn the_evening_summary_counts_attention_items() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![with_attention(
                "3f9a1c2e",
                json!([{"reason": "burn_ahead", "since": "2026-11-26T09:05:00Z", "acked": false}]),
            )],
        ),
        t0 + secs(10),
    );
    rig.engine.step_at(t0 + secs(10)).await;
    let evening = t0 + secs(7 * 3600 + 30 * 60); // 17:30 UTC
    rig.engine.step_at(evening).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert_request_shape(&posts[0]);
    assert_eq!(posts[0]["title"], "Waiting for you");
    assert!(posts[0]["body"]
        .as_str()
        .unwrap()
        .starts_with("1 item · 1 on kobe"));
    assert_eq!(data_kind(&posts[0]), "summary");
}

// ── W13-13: bursts and decisions ─────────────────────────────────────────────

#[tokio::test]
async fn four_items_due_together_are_one_summary_and_no_individual_posts() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let jobs: Vec<MotherJob> = (1..=4)
        .map(|n| awaiting(&format!("aaaa000{n}"), t0))
        .collect();
    rig.engine.ingest(jobs_frame(Some("kobe"), jobs), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(119)).await;
    assert!(rig.posts().await.is_empty());
    rig.engine.step_at(t0 + secs(120)).await;

    let posts = rig.posts().await;
    assert_eq!(
        posts.len(),
        1,
        "one Summary and zero individual POSTs: {posts:#?}"
    );
    let p = &posts[0];
    assert_request_shape(p);
    assert_eq!(p["title"], "Waiting for you");
    assert_eq!(p["body"], "4 items · 4 on kobe · oldest 2 min");
    assert_eq!(p["badge"], 4);
    assert_eq!(p["interruption_level"], "active");
    assert_eq!(data_kind(p), "summary");
    assert!(p["data"].get("ref").is_none());
    assert_eq!(
        p["expiration_unix"],
        (t0 + secs(120) + Duration::hours(4)).timestamp()
    );

    // The four are logged as coalesced, and the Summary as delivered.
    let log = rig.sent_log("dev-1");
    let coalesced = log
        .iter()
        .filter(|e| e.outcome == PushOutcome::Coalesced)
        .count();
    assert_eq!(coalesced, 4, "{log:#?}");
    let summaries: Vec<_> = log.iter().filter(|e| e.kind == "summary").collect();
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].outcome, PushOutcome::DeliveredToApple);
    assert_eq!(summaries[0].title, "Waiting for you");

    // None of the four is pushed on its own later; they leave as badge corrections.
    rig.engine.step_at(t0 + secs(3600)).await;
    assert_eq!(rig.posts().await.len(), 1);
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![]), t0 + secs(3700));
    rig.engine.step_at(t0 + secs(3700)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 5);
    assert!(posts[1..]
        .iter()
        .all(|p| p.get("title").is_none() && p["priority"] == 5));
}

#[tokio::test]
async fn three_items_due_together_are_three_posts() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let jobs: Vec<MotherJob> = (1..=3)
        .map(|n| awaiting(&format!("aaaa000{n}"), t0))
        .collect();
    rig.engine.ingest(jobs_frame(Some("kobe"), jobs), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 3);
    assert!(posts
        .iter()
        .all(|p| p["title"] == "Mother · kobe" && p["badge"] == 3));
}

#[tokio::test]
async fn a_decision_in_the_same_window_as_a_burst_is_still_posted_individually() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let jobs: Vec<MotherJob> = (1..=4)
        .map(|n| awaiting(&format!("aaaa000{n}"), t0))
        .collect();
    rig.engine.ingest(jobs_frame(Some("kobe"), jobs), t0);
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            Some(t0 + secs(600)),
            Some(AgentClass::Claudia),
            Some(Presence::Active),
        ),
        t0 + secs(90),
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    let kinds: Vec<&str> = posts.iter().map(data_kind).collect();
    assert_eq!(posts.len(), 2, "{posts:#?}");
    assert!(
        kinds.contains(&"summary") && kinds.contains(&"decision"),
        "{kinds:?}"
    );
    assert!(
        !kinds.contains(&"mother"),
        "no individual Mother alert in a burst"
    );
    let decision = posts.iter().find(|p| data_kind(p) == "decision").unwrap();
    assert_eq!(decision["interruption_level"], "time-sensitive");
}

// ── W13-10, W13-31: decisions ────────────────────────────────────────────────

#[tokio::test]
async fn a_decision_is_posted_30_seconds_after_it_was_raised_time_sensitive_and_expiring_at_its_deadline(
) {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let deadline = t0 + secs(300);
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            Some(deadline),
            Some(AgentClass::Claudia),
            Some(Presence::Active),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(29)).await;
    assert!(rig.posts().await.is_empty(), "not before 30 s");
    rig.engine.step_at(t0 + secs(30)).await;

    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1);
    let p = &posts[0];
    assert_request_shape(p);
    assert_eq!(p["interruption_level"], "time-sensitive");
    assert_eq!(
        p["expiration_unix"],
        deadline.timestamp(),
        "the decision's deadline"
    );
    assert_eq!(p["title"], "Decision · kobe");
    assert_eq!(
        p["body"], "Claudia is waiting on you · 3 choices · times out in 4 min",
        "270 s left rounds down to 4 min"
    );
    assert_eq!(p["thread_id"], "kobe");
    assert_eq!(p["badge"], 1);
    assert_eq!(p["priority"], 10);
    assert_eq!(data_kind(p), "decision");
    assert_eq!(p["data"]["item"], p["collapse_id"]);
    assert!(
        p["data"].get("ref").is_none(),
        "a decision has no reference"
    );
}

#[tokio::test]
async fn a_decision_whose_mac_is_away_is_posted_at_once() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        decision_frame(Some("kobe"), "req-1", None, None, Some(Presence::Away)),
        t0,
    );
    rig.engine.step_at(t0).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1);
    assert_eq!(posts[0]["body"], "A session is waiting on you · 3 choices");
    assert_eq!(posts[0]["interruption_level"], "time-sensitive");
    assert_eq!(
        posts[0]["expiration_unix"],
        (t0 + Duration::hours(4)).timestamp(),
        "no deadline: send time + 4 h"
    );
}

#[tokio::test]
async fn a_decision_rebroadcast_as_away_is_posted_then_and_only_once() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let active = decision_frame(
        Some("kobe"),
        "req-1",
        None,
        Some(AgentClass::Teri),
        Some(Presence::Active),
    );
    rig.engine.ingest(active, t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(9)).await;
    assert!(rig.posts().await.is_empty());
    // The daemon re-broadcasts the same request with presence `away`.
    let away = decision_frame(
        Some("kobe"),
        "req-1",
        None,
        Some(AgentClass::Teri),
        Some(Presence::Away),
    );
    rig.engine.ingest(away.clone(), t0 + secs(10));
    rig.engine.step_at(t0 + secs(10)).await;
    assert_eq!(rig.posts().await.len(), 1, "at t+10 s");
    // The same frame again, and the 30 s mark: no second notification.
    rig.engine.ingest(away, t0 + secs(11));
    rig.engine.step_at(t0 + secs(11)).await;
    rig.engine.step_at(t0 + secs(30)).await;
    rig.engine.step_at(t0 + secs(300)).await;
    assert_eq!(rig.posts().await.len(), 1);
}

#[tokio::test]
async fn a_decision_answered_within_30_seconds_sends_nothing_and_logs_the_skip() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            None,
            Some(AgentClass::Claudia),
            Some(Presence::Active),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine
        .ingest(resolved_frame(Some("kobe"), "req-1"), t0 + secs(29));
    rig.engine.step_at(t0 + secs(29)).await;
    rig.engine.step_at(t0 + secs(30)).await;
    assert!(rig.posts().await.is_empty());
    let log = rig.sent_log("dev-1");
    assert_eq!(log.len(), 1, "{log:?}");
    assert_eq!(log[0].outcome, PushOutcome::SkippedResolvedInGrace);
    assert_eq!(log[0].kind, "decision");
    assert_eq!(log[0].body, "Claudia is waiting on you · 3 choices");
}

#[tokio::test]
async fn a_notified_decision_that_is_answered_is_replaced_passively() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            None,
            Some(AgentClass::Claudia),
            Some(Presence::Away),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine
        .ingest(resolved_frame(Some("kobe"), "req-1"), t0 + secs(20));
    rig.engine.step_at(t0 + secs(20)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[1]["collapse_id"], posts[0]["collapse_id"]);
    assert_eq!(posts[1]["interruption_level"], "passive");
    assert_eq!(posts[1]["title"], "Decision · kobe");
    assert_eq!(posts[1]["body"], "Claudia no longer needs you");
    assert_eq!(posts[1]["badge"], 0);
    assert_eq!(posts[1]["data"]["resolved"], true);
}

#[tokio::test]
async fn a_notified_decision_whose_deadline_passes_is_replaced_passively() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            Some(t0 + secs(60)),
            Some(AgentClass::Claudia),
            Some(Presence::Away),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    assert_eq!(rig.posts().await.len(), 1);
    rig.engine.step_at(t0 + secs(59)).await;
    assert_eq!(rig.posts().await.len(), 1);
    rig.engine.step_at(t0 + secs(60)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2, "the asker gave up: {posts:#?}");
    assert_eq!(posts[1]["body"], "Claudia no longer needs you");
    assert_eq!(posts[1]["interruption_level"], "passive");
    assert_eq!(posts[1]["badge"], 0);
}

#[tokio::test]
async fn the_daemons_own_decision_is_labelled_with_the_local_host_name() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&[], t0).await;
    rig.engine.ingest(
        decision_frame(
            None,
            "req-1",
            None,
            Some(AgentClass::Fred),
            Some(Presence::Away),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    let posts = rig.posts().await;
    assert_eq!(posts[0]["title"], "Decision · tokyo");
    assert_eq!(posts[0]["thread_id"], "tokyo");
    assert_eq!(posts[0]["data"]["host"], "tokyo");
    assert_eq!(posts[0]["body"], "Fred is waiting on you · 3 choices");
}

// ── W13-14: quiet hours at the relay ─────────────────────────────────────────

#[tokio::test]
async fn nothing_is_posted_in_quiet_hours_but_withdrawals_and_the_morning_summary_are() {
    use chrono::TimeZone;
    let mut rig = Rig::new().await;
    rig.register_with(
        "dev-1",
        &token_a(),
        "America/Chicago",
        PushCapabilities::default(),
    );
    let t = |h, m| Utc.with_ymd_and_hms(2026, 11, 25, h, m, 0).unwrap();
    // 02:00 UTC is 20:00 CST on the 24th.
    rig.start(&["kobe"], t(2, 0)).await;

    // 22:30 CST: an awaiting job and a decision (away: due at once). Both held.
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t(4, 30))]),
        t(4, 30),
    );
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            None,
            Some(AgentClass::Claudia),
            Some(Presence::Away),
        ),
        t(4, 30),
    );
    rig.engine.step_at(t(4, 30)).await;
    rig.engine.step_at(t(4, 32)).await;
    assert!(
        rig.posts().await.is_empty(),
        "zero alert POSTs in quiet hours"
    );
    let log = rig.sent_log("dev-1");
    assert_eq!(
        log.iter().map(|e| e.outcome).collect::<Vec<_>>(),
        vec![PushOutcome::HeldQuietHours, PushOutcome::HeldQuietHours]
    );

    // The decision is answered at midnight: still a (badge-only) withdrawal in quiet hours.
    rig.engine
        .ingest(resolved_frame(Some("kobe"), "req-1"), t(6, 0));
    rig.engine.step_at(t(6, 0)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert!(posts[0].get("title").is_none());
    assert_eq!(posts[0]["badge"], 1);

    // 07:00 CST: one Summary, since the job is still waiting.
    rig.engine.step_at(t(12, 59)).await;
    assert_eq!(rig.posts().await.len(), 1);
    rig.engine.step_at(t(13, 0)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2, "{posts:#?}");
    assert_eq!(posts[1]["title"], "Waiting for you");
    assert_eq!(posts[1]["body"], "1 item · 1 on kobe · oldest 8 h");
}

// ── W13-16: per-kind switches ────────────────────────────────────────────────

#[tokio::test]
async fn a_kind_turned_off_on_a_device_is_not_posted_to_it_nor_counted_in_its_badge() {
    let mut rig = Rig::with_hosts(&[("sendai", HostClass::Work)]).await;
    let t0 = base();
    rig.register("dev-a", &token_a());
    rig.register("dev-b", &token_b());
    let mut prefs = rig.status("dev-b").prefs;
    prefs.kinds.review = false;
    rig.set_prefs("dev-b", prefs);

    rig.start(&["kobe", "sendai"], t0).await;
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![awaiting("aaaa0001", t0), awaiting("aaaa0002", t0)],
        ),
        t0,
    );
    rig.engine.ingest(
        queue_frame(
            Some("sendai"),
            vec![pr("Carefeed/admin-portal", 7, "requested", Some(5))],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;

    let a = rig.posts_to(&token_a()).await;
    let b = rig.posts_to(&token_b()).await;
    assert_eq!(a.len(), 3, "{a:#?}");
    assert!(
        a.iter().all(|p| p["badge"] == 3),
        "the count spans every host: {a:#?}"
    );
    assert_eq!(b.len(), 2, "no review to dev-b: {b:#?}");
    assert!(
        b.iter()
            .all(|p| data_kind(p) == "mother" && p["badge"] == 2),
        "{b:#?}"
    );

    // Its waiting list and badge agree.
    let (items, badge) = rig.waiting("dev-b");
    assert_eq!(badge, 2);
    assert!(items.iter().all(|i| i.kind == PushKind::Mother));
    let (items, badge) = rig.waiting("dev-a");
    assert_eq!((items.len(), badge), (3, 3));
}

// ── W13-17: revoked devices ──────────────────────────────────────────────────

#[tokio::test]
async fn a_revoked_device_is_sent_nothing_and_its_record_is_deleted() {
    let reg_dir = TempDir::new().unwrap();
    let registry = Arc::new(DeviceRegistry::load(reg_dir.path().join("devices.json")).unwrap());
    let phone = registry
        .redeem("Phone", DeviceKind::Iphone, None, None)
        .unwrap();
    let mut rig = Rig::build(Some(Arc::clone(&registry)), None, |_| {}).await;
    rig.mount(ok_response(), None).await;
    let t0 = base();
    rig.register(&phone.device_id, &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert_eq!(rig.posts().await.len(), 1, "an active device is notified");
    let record = std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap();
    assert!(record.contains(&phone.device_id));

    registry
        .revoke(&phone.device_id, RevokedBy::Operator)
        .unwrap();

    // A new item, and the old one leaving: neither reaches the revoked phone.
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("aaaa0002", t0 + secs(200))]),
        t0 + secs(200),
    );
    rig.engine.step_at(t0 + secs(200)).await;
    rig.engine.step_at(t0 + secs(320)).await;
    rig.engine.step_at(t0 + secs(400)).await;
    assert_eq!(rig.posts().await.len(), 1, "no POST after revocation");
    let record = std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap();
    assert!(
        !record.contains(&phone.device_id),
        "its push record is deleted: {record}"
    );
    assert!(
        !record.contains(&token_a()),
        "and its APNs token with it: {record}"
    );
    assert!(
        rig.sent_log(&phone.device_id).is_empty(),
        "its history goes too"
    );
}

#[tokio::test]
async fn a_device_the_registry_does_not_know_is_dropped_not_notified() {
    let reg_dir = TempDir::new().unwrap();
    let registry = Arc::new(DeviceRegistry::load(reg_dir.path().join("devices.json")).unwrap());
    let mut rig = Rig::build(Some(registry), None, |_| {}).await;
    rig.mount(ok_response(), None).await;
    let t0 = base();
    rig.register("never-paired", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert!(rig.posts().await.is_empty());
}

// ── W13-18: relay failures ───────────────────────────────────────────────────

#[tokio::test]
async fn a_relay_error_is_logged_not_retried_and_sets_failing_since_until_the_next_success() {
    let mut rig = Rig::build(None, None, |_| {}).await;
    rig.mount(ResponseTemplate::new(500), Some(1)).await;
    rig.mount(ok_response(), None).await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    assert_eq!(rig.status("dev-1").failing_since, None);

    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert_eq!(rig.posts().await.len(), 1, "one attempt");
    let log = rig.sent_log("dev-1");
    assert_eq!(log.len(), 1);
    assert_eq!(log[0].outcome, PushOutcome::RelayUnreachable);
    assert_eq!(log[0].title, "Mother · kobe");
    let status = rig.status("dev-1");
    assert_eq!(status.failing_since, Some(t0 + secs(120)));
    assert_eq!(status.last_ok_at, None);

    // No retry and no queue: time passes, nothing is re-sent.
    for t in [121, 180, 600, 3600, 6 * 3600] {
        rig.engine.step_at(t0 + secs(t)).await;
    }
    assert_eq!(rig.posts().await.len(), 1, "no retry, no queue");
    assert_eq!(
        rig.status("dev-1").failing_since,
        Some(t0 + secs(120)),
        "still failing"
    );

    // The next change of state is the next attempt; a success clears the banner.
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![]), t0 + secs(7 * 3600));
    rig.engine.step_at(t0 + secs(7 * 3600)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 2);
    let status = rig.status("dev-1");
    assert_eq!(status.failing_since, None, "cleared by the success");
    assert_eq!(status.last_ok_at, Some(t0 + secs(7 * 3600)));
}

#[tokio::test]
async fn an_unreachable_relay_is_logged_and_not_retried() {
    let mut rig = Rig::build(None, Some(dead_url()), |_| {}).await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    rig.engine.step_at(t0 + secs(240)).await;
    let log = rig.sent_log("dev-1");
    assert_eq!(log.len(), 1, "one attempt, one line: {log:?}");
    assert_eq!(log[0].outcome, PushOutcome::RelayUnreachable);
    assert_eq!(rig.status("dev-1").failing_since, Some(t0 + secs(120)));
}

#[tokio::test]
async fn a_missing_relay_token_is_a_relay_unreachable_not_a_post() {
    let mut rig = Rig::new().await;
    std::fs::remove_file(rig.tmp.path().join("relay-token")).unwrap();
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert!(
        rig.posts().await.is_empty(),
        "no unauthenticated request leaves"
    );
    assert_eq!(
        rig.sent_log("dev-1")[0].outcome,
        PushOutcome::RelayUnreachable
    );
}

#[tokio::test]
async fn an_apple_rejection_is_logged_as_rejected_by_apple_and_counts_as_failing() {
    let mut rig = Rig::build(None, None, |_| {}).await;
    rig.mount(
        ResponseTemplate::new(200)
            .set_body_json(json!({"apns_status": 410, "apns_reason": "Unregistered"})),
        None,
    )
    .await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let log = rig.sent_log("dev-1");
    assert_eq!(log[0].outcome, PushOutcome::RejectedByApple);
    assert_eq!(rig.status("dev-1").failing_since, Some(t0 + secs(120)));
    assert_eq!(rig.posts().await.len(), 1, "and not retried");
}

#[tokio::test]
async fn the_relay_token_is_read_on_every_send_so_rotating_it_needs_no_restart() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![
                awaiting("aaaa0001", t0),
                awaiting("aaaa0002", t0 + secs(300)),
            ],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    std::fs::write(rig.tmp.path().join("relay-token"), "rotated-token\n").unwrap();
    rig.engine.step_at(t0 + secs(300)).await;
    rig.engine.step_at(t0 + secs(420)).await;
    let raw = rig.raw_posts().await;
    let auth: Vec<String> = raw
        .iter()
        .map(|r| {
            r.headers
                .get("authorization")
                .unwrap()
                .to_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(
        auth,
        vec!["Bearer fake-relay-token", "Bearer rotated-token"]
    );
}

// ── W13-24: the sent log ─────────────────────────────────────────────────────

#[tokio::test]
async fn a_device_reads_only_its_own_sent_log_with_exact_text_and_never_a_reference() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-a", &token_a());
    rig.register("dev-b", &token_b());
    // dev-a sees Mother jobs only; dev-b sees reviews only.
    let mut pa = rig.status("dev-a").prefs;
    pa.kinds.review = false;
    rig.set_prefs("dev-a", pa);
    let mut pb = rig.status("dev-b").prefs;
    pb.kinds.mother = false;
    rig.set_prefs("dev-b", pb);

    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.ingest(
        queue_frame(
            Some("kobe"),
            vec![pr("Carefeed/admin-portal", 4821, "requested", Some(10))],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;

    let a = rig.sent_log("dev-a");
    let b = rig.sent_log("dev-b");
    assert_eq!(a.len(), 1, "{a:#?}");
    assert_eq!(b.len(), 1, "{b:#?}");
    assert_eq!(
        (
            a[0].kind.as_str(),
            a[0].host.as_str(),
            a[0].title.as_str(),
            a[0].body.as_str(),
            a[0].outcome
        ),
        (
            "mother",
            "kobe",
            "Mother · kobe",
            "Job 3f9a1c2e asked a question",
            PushOutcome::DeliveredToApple
        )
    );
    assert_eq!(a[0].ts, t0 + secs(120));
    assert_eq!(
        (b[0].kind.as_str(), b[0].title.as_str(), b[0].body.as_str()),
        (
            "review",
            "Review · kobe",
            "PR #4821 · small change · 1 waiting"
        )
    );

    // The reply never carries the device reference, a token or an item ref.
    let reply = serde_json::to_string(&ServerMsg::PushSentLog { entries: a }).unwrap();
    let (ta, tb) = (token_a(), token_b());
    for secret in [
        "push_id",
        ta.as_str(),
        tb.as_str(),
        "collapse_id",
        "item_ref",
    ] {
        assert!(!reply.contains(secret), "{secret} in {reply}");
    }
}

#[tokio::test]
async fn an_entry_older_than_seven_days_is_gone_after_the_next_append() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    let old = t0 - Duration::days(8);
    rig.start(&["kobe"], old).await;
    rig.engine.ingest(
        jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", old)]),
        old,
    );
    rig.engine.step_at(old).await;
    rig.engine.step_at(old + secs(120)).await;
    assert_eq!(rig.posts().await.len(), 1);
    assert_eq!(
        rig.sent_log("dev-1").len(),
        0,
        "8 days old is not shown even before it is pruned"
    );

    // Eight days later a second job is notified. Appending its line prunes the old one.
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            vec![awaiting("aaaa0001", old), awaiting("aaaa0002", t0)],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    assert_eq!(rig.posts().await.len(), 2);
    let log = rig.sent_log("dev-1");
    assert_eq!(log.len(), 1, "{log:#?}");
    assert_eq!(log[0].ts, t0 + secs(120));
    let on_disk = std::fs::read_to_string(rig.state_dir().join("sent.jsonl")).unwrap();
    assert_eq!(on_disk.lines().count(), 1, "pruned on disk too: {on_disk}");
}

// ── W13-7, W13-32: classification is read-only ───────────────────────────────

fn every_push_verb() -> Vec<ClientMsg> {
    vec![
        ClientMsg::RegisterPush {
            apns_token: token_a(),
            environment: PushEnvironment::Production,
            tz: "America/Chicago".into(),
            capabilities: PushCapabilities { nse_withdraw: true },
        },
        ClientMsg::SetPushPrefs {
            prefs: PushPrefs::default(),
        },
        ClientMsg::PushSentLog,
        ClientMsg::PushWaiting,
    ]
}

fn all_trusts() -> Vec<(PeerTrust, Option<&'static str>)> {
    vec![
        (PeerTrust::Tcp, None),
        (PeerTrust::Tcp, Some("dev-1")),
        (
            PeerTrust::Satellite {
                admin: SatelliteAdmin::Full,
            },
            None,
        ),
        (
            PeerTrust::Satellite {
                admin: SatelliteAdmin::Full,
            },
            Some("dev-1"),
        ),
        (PeerTrust::Routed, None),
        (PeerTrust::Routed, Some("dev-1")),
        (PeerTrust::LocalOther, None),
        (PeerTrust::LocalOther, Some("dev-1")),
        (PeerTrust::OperatorApp, None),
        (PeerTrust::OperatorApp, Some("dev-1")),
        (PeerTrust::Paired, None),
        (PeerTrust::Paired, Some("dev-1")),
    ]
}

#[tokio::test]
async fn no_client_message_changes_host_classes_or_work_owners() {
    let mut rig =
        Rig::with_hosts(&[("kobe", HostClass::Work), ("sendai", HostClass::Personal)]).await;
    rig.register("dev-1", &token_a());
    let before = rig.status("dev-1");
    assert_eq!(
        before.host_classes.get("sendai"),
        Some(&HostClass::Personal)
    );

    // Every push verb, from every kind of peer, in every shape a hostile phone
    // can think of, including decoded from JSON with fields that do not exist.
    let hostile: Vec<ClientMsg> = [
        r#"{"type":"set_push_prefs","prefs":{"host_classes":{"kobe":"personal","sendai":"work"},"work_owners":["evil"]}}"#,
        r#"{"type":"register_push","apns_token":"abab","environment":"sandbox","tz":"UTC","host_classes":{"kobe":"personal"},"work_owners":[]}"#,
        r#"{"type":"set_push_prefs","prefs":{"kinds":{"mother":true},"hosts":{"kobe":"personal"}}}"#,
    ]
    .iter()
    .map(|j| serde_json::from_str(j).unwrap_or_else(|e| panic!("{j}: {e}")))
    .collect();
    for msg in every_push_verb().into_iter().chain(hostile) {
        for (trust, device) in all_trusts() {
            let _ = rig.verb(&msg, trust, device);
        }
    }
    let after = rig.status("dev-1");
    assert_eq!(
        after.host_classes, before.host_classes,
        "[push.hosts] is unchanged"
    );
    assert_eq!(after.work_owners, before.work_owners);
    let cfg = rig.cfg.lock().unwrap().clone();
    assert_eq!(cfg.hosts.get("kobe"), Some(&HostClass::Work));
    assert_eq!(cfg.hosts.get("sendai"), Some(&HostClass::Personal));
    assert!(cfg.work_owners.is_empty());
}

#[tokio::test]
async fn the_status_carries_host_classes_and_work_owners_read_only_and_carefeed_is_always_a_work_owner(
) {
    for configured in [
        vec![],
        vec!["Acme".to_string()],
        vec!["carefeed".to_string(), "Acme".to_string()],
    ] {
        let owners = configured.clone();
        let mut rig = Rig::build(None, None, move |cfg| {
            cfg.work_owners = owners;
            cfg.hosts.insert("kobe".into(), HostClass::Work);
            cfg.hosts.insert("sendai".into(), HostClass::Personal);
        })
        .await;
        let status = rig.register("dev-1", &token_a());
        assert_eq!(
            status.work_owners.first().map(String::as_str),
            Some("Carefeed"),
            "{configured:?}"
        );
        assert_eq!(
            status
                .work_owners
                .iter()
                .filter(|o| o.eq_ignore_ascii_case("carefeed"))
                .count(),
            1,
            "{configured:?}"
        );
        if configured.iter().any(|o| o.as_str() == "Acme") {
            assert!(status.work_owners.contains(&"Acme".to_string()));
        }
        assert_eq!(
            status.host_classes,
            BTreeMap::from([
                ("kobe".to_string(), HostClass::Work),
                ("sendai".to_string(), HostClass::Personal)
            ])
        );
    }
}

#[tokio::test]
async fn host_classes_changed_in_the_config_take_effect_without_a_restart() {
    let mut rig = Rig::with_hosts(&[("sendai", HostClass::Work)]).await;
    let t0 = base();
    let url = "https://github.com/thehammer/bishop/pull/12";
    rig.register("dev-1", &token_a());
    rig.start(&["sendai"], t0).await;

    rig.engine.ingest(
        jobs_frame(
            Some("sendai"),
            vec![job(
                "aaaa0001",
                "awaiting",
                Some("user"),
                Some(t0),
                Some(url),
            )],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    // `nostromo push host sendai personal` edits the config; the engine re-reads it.
    rig.cfg
        .lock()
        .unwrap()
        .hosts
        .insert("sendai".into(), HostClass::Personal);

    rig.engine.ingest(
        jobs_frame(
            Some("sendai"),
            vec![
                job("aaaa0001", "awaiting", Some("user"), Some(t0), Some(url)),
                job(
                    "aaaa0002",
                    "awaiting",
                    Some("user"),
                    Some(t0 + secs(200)),
                    Some(url),
                ),
            ],
        ),
        t0 + secs(200),
    );
    rig.engine.step_at(t0 + secs(200)).await;
    rig.engine.step_at(t0 + secs(320)).await;
    let titles: Vec<String> = rig
        .posts()
        .await
        .iter()
        .map(|p| p["title"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(titles, vec!["Mother · sendai", "Mother · sendai · bishop"]);

    // And back: a work host shows no name again, immediately.
    rig.cfg
        .lock()
        .unwrap()
        .hosts
        .insert("sendai".into(), HostClass::Work);
    rig.engine
        .ingest(jobs_frame(Some("sendai"), vec![]), t0 + secs(400));
    rig.engine.step_at(t0 + secs(400)).await;
    let posts = rig.posts().await;
    let withdrawn: Vec<&str> = posts[2..]
        .iter()
        .filter_map(|p| p["title"].as_str())
        .collect();
    assert_eq!(withdrawn, vec!["Mother · sendai", "Mother · sendai"]);
}

#[tokio::test]
async fn a_work_owner_added_to_the_config_hides_its_repositories_without_a_restart() {
    let mut rig = Rig::with_hosts(&[("sendai", HostClass::Personal)]).await;
    let t0 = base();
    let url = "https://github.com/acme/widgets/pull/3";
    rig.register("dev-1", &token_a());
    rig.start(&["sendai"], t0).await;
    rig.engine.ingest(
        jobs_frame(
            Some("sendai"),
            vec![job(
                "aaaa0001",
                "awaiting",
                Some("user"),
                Some(t0),
                Some(url),
            )],
        ),
        t0,
    );
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    rig.cfg.lock().unwrap().work_owners.push("Acme".into());
    rig.engine.ingest(
        jobs_frame(
            Some("sendai"),
            vec![
                job("aaaa0001", "awaiting", Some("user"), Some(t0), Some(url)),
                job(
                    "aaaa0002",
                    "awaiting",
                    Some("user"),
                    Some(t0 + secs(200)),
                    Some(url),
                ),
            ],
        ),
        t0 + secs(200),
    );
    rig.engine.step_at(t0 + secs(200)).await;
    rig.engine.step_at(t0 + secs(320)).await;
    let titles: Vec<String> = rig
        .posts()
        .await
        .iter()
        .map(|p| p["title"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(titles, vec!["Mother · sendai · widgets", "Mother · sendai"]);
}

// ── dispatch gating (W13-38) ─────────────────────────────────────────────────

#[tokio::test]
async fn the_four_push_verbs_are_handled_only_for_a_paired_peer_with_a_device_id() {
    let mut rig = Rig::new().await;
    for msg in every_push_verb() {
        for (trust, device) in all_trusts() {
            let (handled, replies) = rig.verb(&msg, trust, device);
            let paired_with_id = trust == PeerTrust::Paired && device.is_some();
            let want = if paired_with_id {
                Dispatched::Handled
            } else {
                Dispatched::NotHandled
            };
            assert_eq!(handled, want, "{msg:?} from {trust:?} / {device:?}");
            if paired_with_id {
                assert_eq!(replies.len(), 1, "{msg:?}: one targeted reply");
            } else {
                assert!(
                    replies.is_empty(),
                    "{msg:?} from {trust:?} / {device:?} was answered: {replies:?}"
                );
            }
        }
    }
}

#[tokio::test]
async fn a_peer_that_is_not_served_registers_nothing() {
    let mut rig = Rig::new().await;
    for msg in every_push_verb() {
        for (trust, device) in all_trusts() {
            if trust == PeerTrust::Paired && device.is_some() {
                continue;
            }
            let _ = rig.verb(&msg, trust, device);
        }
    }
    assert!(
        !rig.state_dir().join("devices.json").exists(),
        "no record was ever written for a peer that is not a paired phone"
    );
}

#[tokio::test]
async fn the_engine_does_not_take_other_verbs_even_from_a_paired_peer() {
    let mut rig = Rig::new().await;
    for msg in [
        ClientMsg::Ping,
        ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
        ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    ] {
        let (handled, replies) = rig.verb(&msg, PeerTrust::Paired, Some("dev-1"));
        assert_eq!(handled, Dispatched::NotHandled, "{msg:?}");
        assert!(replies.is_empty());
    }
}

#[tokio::test]
async fn a_device_reads_and_writes_only_its_own_record() {
    let mut rig = Rig::new().await;
    rig.register("dev-a", &token_a());
    rig.register("dev-b", &token_b());
    let b_before = rig.status("dev-b");

    let mut prefs = rig.status("dev-a").prefs;
    prefs.kinds.mother = false;
    prefs.quiet.start = "21:15".into();
    prefs.evening_summary = None;
    let a = rig.set_prefs("dev-a", prefs.clone());
    assert_eq!(a.prefs, prefs);
    assert_eq!(
        rig.status("dev-b").prefs,
        b_before.prefs,
        "dev-b is untouched"
    );

    // dev-a registering a new token does not take dev-b's record over.
    rig.register("dev-a", &"ef".repeat(32));
    let record: Value = serde_json::from_str(
        &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(record["devices"]["dev-a"]["apns_token"], "ef".repeat(32));
    assert_eq!(record["devices"]["dev-b"]["apns_token"], token_b());
    assert_ne!(
        record["devices"]["dev-a"]["push_id"],
        record["devices"]["dev-b"]["push_id"]
    );

    // A device that never registered has nothing to read.
    assert!(rig.sent_log("dev-unknown").is_empty());
    let (items, _) = rig.waiting("dev-unknown");
    assert!(items.is_empty());
}

// ── validation ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn an_invalid_token_is_refused_and_registers_nothing() {
    let mut rig = Rig::new().await;
    let too_long = "ab".repeat(101); // 202 hex characters
    for token in [
        "",
        "not hex at all",
        "zz",
        "ab cd",
        too_long.as_str(),
        "ab\n",
    ] {
        let _ = rig.verb(
            &ClientMsg::RegisterPush {
                apns_token: token.to_string(),
                environment: PushEnvironment::Sandbox,
                tz: "UTC".into(),
                capabilities: PushCapabilities::default(),
            },
            PeerTrust::Paired,
            Some("dev-1"),
        );
        assert!(
            !rig.state_dir().join("devices.json").exists(),
            "{token:?} was registered"
        );
    }
    // The longest token Apple issues (100 bytes, 200 hex characters), either case, is fine.
    for token in ["ab".repeat(100), "AB".repeat(100)] {
        rig.register("dev-1", &token);
        let record: Value = serde_json::from_str(
            &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(record["devices"]["dev-1"]["apns_token"], token);
    }
}

#[tokio::test]
async fn invalid_settings_are_refused_without_changing_state() {
    let mut rig = Rig::new().await;
    rig.register("dev-1", &token_a());
    let before = rig.status("dev-1");
    type Mutation = Box<dyn Fn(&mut PushPrefs)>;
    let bad: Vec<Mutation> = vec![
        Box::new(|p| p.tz = "Mars/Olympus_Mons".into()),
        Box::new(|p| p.tz = String::new()),
        Box::new(|p| p.quiet.start = "25:00".into()),
        Box::new(|p| p.quiet.end = "7am".into()),
        Box::new(|p| p.quiet.start = "".into()),
        Box::new(|p| p.evening_summary = Some("half past five".into())),
        Box::new(|p| p.evening_summary = Some("17:61".into())),
    ];
    for (i, mutate) in bad.iter().enumerate() {
        let mut prefs = before.prefs.clone();
        mutate(&mut prefs);
        let after = rig.set_prefs("dev-1", prefs);
        assert_eq!(after.prefs, before.prefs, "case {i} changed the settings");
    }
    // A valid change still applies.
    let mut good = before.prefs.clone();
    good.quiet.start = "21:30".into();
    good.evening_summary = None;
    good.tz = "Asia/Tokyo".into();
    assert_eq!(rig.set_prefs("dev-1", good.clone()).prefs, good);
}

#[tokio::test]
async fn a_time_zone_the_build_does_not_know_registers_as_utc() {
    let mut rig = Rig::new().await;
    let status = rig.register_with(
        "dev-1",
        &token_a(),
        "Not/AZone",
        PushCapabilities::default(),
    );
    assert_eq!(status.prefs.tz, "UTC");
    let status = rig.register_with(
        "dev-1",
        &token_a(),
        "Asia/Tokyo",
        PushCapabilities::default(),
    );
    assert_eq!(status.prefs.tz, "Asia/Tokyo");
}

#[tokio::test]
async fn registering_again_keeps_the_settings_and_the_relays_device_reference() {
    let mut rig = Rig::new().await;
    rig.register("dev-1", &token_a());
    let mut prefs = rig.status("dev-1").prefs;
    prefs.kinds.review = false;
    prefs.quiet.end = "06:30".into();
    rig.set_prefs("dev-1", prefs.clone());
    let read = |rig: &Rig| -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
        )
        .unwrap()
    };
    let push_id = read(&rig)["devices"]["dev-1"]["push_id"].clone();
    assert!(is_hex(push_id.as_str().unwrap(), 32));

    // The OS hands out a new token.
    let status = rig.register("dev-1", &"ef".repeat(32));
    assert_eq!(status.prefs.kinds, prefs.kinds);
    assert_eq!(status.prefs.quiet.end, "06:30");
    let after = read(&rig);
    assert_eq!(
        after["devices"]["dev-1"]["push_id"], push_id,
        "same anonymous reference"
    );
    assert_eq!(after["devices"]["dev-1"]["apns_token"], "ef".repeat(32));
}

// ── W13-37: capabilities ─────────────────────────────────────────────────────

#[tokio::test]
async fn register_push_stores_the_latest_capabilities() {
    let mut rig = Rig::new().await;
    let read = |rig: &Rig| -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
        )
        .unwrap()
    };
    rig.register_with(
        "dev-1",
        &token_a(),
        "UTC",
        PushCapabilities { nse_withdraw: true },
    );
    assert_eq!(
        read(&rig)["devices"]["dev-1"]["capabilities"]["nse_withdraw"],
        true
    );
    rig.register_with(
        "dev-1",
        &token_a(),
        "UTC",
        PushCapabilities {
            nse_withdraw: false,
        },
    );
    assert_eq!(
        read(&rig)["devices"]["dev-1"]["capabilities"]["nse_withdraw"],
        false,
        "the latest RegisterPush wins, even when only the capabilities changed"
    );
}

#[tokio::test]
async fn a_register_push_without_capabilities_stores_every_flag_false() {
    let mut rig = Rig::new().await;
    let msg: ClientMsg = serde_json::from_str(&format!(
        r#"{{"type":"register_push","apns_token":"{}","environment":"production","tz":"UTC"}}"#,
        token_a()
    ))
    .unwrap();
    let (handled, replies) = rig.verb(&msg, PeerTrust::Paired, Some("dev-1"));
    assert_eq!(handled, Dispatched::Handled);
    assert_eq!(replies.len(), 1);
    let record: Value = serde_json::from_str(
        &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        record["devices"]["dev-1"]["capabilities"]["nse_withdraw"],
        false
    );
    assert_eq!(record["devices"]["dev-1"]["environment"], "production");
}

// ── PushWaiting ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn push_waiting_lists_what_waits_with_the_same_refs_the_notifications_carry() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe", "sendai"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.ingest(
        queue_frame(
            Some("sendai"),
            vec![pr("Carefeed/admin-portal", 4821, "requested", Some(10))],
        ),
        t0,
    );
    rig.engine.ingest(
        decision_frame(
            None,
            "req-1",
            None,
            Some(AgentClass::Claudia),
            Some(Presence::Active),
        ),
        t0,
    );
    rig.engine.step_at(t0).await;

    let (items, badge) = rig.waiting("dev-1");
    assert_eq!(badge, 3);
    let mut summary: Vec<(PushKind, String, Option<String>)> = items
        .iter()
        .map(|i| (i.kind, i.host.clone(), i.ref_.clone()))
        .collect();
    summary.sort_by_key(|(k, ..)| *k);
    assert_eq!(
        summary,
        vec![
            (PushKind::Mother, "kobe".into(), Some("Job 3f9a1c2e".into())),
            (PushKind::Decision, "tokyo".into(), None),
            (PushKind::Review, "sendai".into(), Some("PR #4821".into())),
        ]
    );
    assert!(items.iter().all(|i| is_hex(&i.item_ref, 16)));

    // The item ref a phone resolves is the one the notification carried.
    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    let mother = posts.iter().find(|p| data_kind(p) == "mother").unwrap();
    let listed = items.iter().find(|i| i.kind == PushKind::Mother).unwrap();
    assert_eq!(mother["data"]["item"], listed.item_ref);
    assert_eq!(mother["collapse_id"], listed.item_ref);
}

#[tokio::test]
async fn push_waiting_excludes_a_disabled_kind_from_items_and_badge() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    let mut prefs = rig.status("dev-1").prefs;
    prefs.kinds.decision = false;
    rig.set_prefs("dev-1", prefs);
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.ingest(
        decision_frame(Some("kobe"), "req-1", None, None, Some(Presence::Away)),
        t0,
    );
    rig.engine.step_at(t0).await;
    let (items, badge) = rig.waiting("dev-1");
    assert_eq!(badge, 1);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].kind, PushKind::Mother);
    assert!(
        rig.posts().await.is_empty(),
        "the disabled decision was not pushed either"
    );
}

// ── files ────────────────────────────────────────────────────────────────────

#[cfg(unix)]
#[tokio::test]
async fn the_device_file_and_the_sent_log_are_private_and_written_without_leftovers() {
    use std::os::unix::fs::PermissionsExt;
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    let mut prefs = rig.status("dev-1").prefs;
    prefs.kinds.review = false;
    rig.set_prefs("dev-1", prefs);
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    for name in ["devices.json", "sent.jsonl"] {
        let meta =
            std::fs::metadata(rig.state_dir().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            meta.permissions().mode() & 0o777,
            0o600,
            "{name}: a token is a credential"
        );
    }
    // Written by rename: the file is whole JSON, and no temporary file is left behind.
    let record: Value = serde_json::from_str(
        &std::fs::read_to_string(rig.state_dir().join("devices.json")).unwrap(),
    )
    .unwrap();
    assert!(record["devices"]["dev-1"].is_object());
    let mut names: Vec<String> = std::fs::read_dir(rig.state_dir())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec!["devices.json", "sent.jsonl"],
        "no .tmp left behind"
    );
}

#[tokio::test]
async fn a_restarted_engine_reloads_devices_and_the_sent_log_from_disk() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("3f9a1c2e", t0)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    // A new engine on the same state directory.
    let state_dir = rig.state_dir();
    let relay_uri = rig.relay.uri();
    let token = rig.tmp.path().join("relay-token");
    let cfg = PushConfig {
        relay_url: Some(relay_uri),
        relay_token_path: Some(token),
        state_dir: Some(state_dir),
        ..Default::default()
    };
    let source: ConfigSource = Arc::new(move || cfg.clone());
    let engine = PushEngine::new(source, "tokyo".into(), None).unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    assert_eq!(
        engine.dispatch(
            &ClientMsg::PushSentLog,
            PeerTrust::Paired,
            Some("dev-1"),
            &tx
        ),
        Dispatched::Handled
    );
    match rx.try_recv().unwrap() {
        ServerMsg::PushSentLog { entries } => {
            assert_eq!(entries.len(), 1);
            assert_eq!(entries[0].body, "Job 3f9a1c2e asked a question");
        }
        other => panic!("{other:?}"),
    }
}

// ── the engine only starts when it should ────────────────────────────────────

#[tokio::test]
async fn the_engine_does_not_start_without_a_relay_or_when_disabled() {
    let make = |cfg: PushConfig| -> Option<Arc<PushEngine>> {
        let source: ConfigSource = Arc::new(move || cfg.clone());
        PushEngine::new(source, "tokyo".into(), None)
    };
    let dir = TempDir::new().unwrap();
    let base_cfg = PushConfig {
        relay_url: Some("https://relay.example".into()),
        state_dir: Some(dir.path().join("push")),
        ..Default::default()
    };
    assert!(make(base_cfg.clone()).is_some());
    assert!(make(PushConfig {
        relay_url: None,
        ..base_cfg.clone()
    })
    .is_none());
    assert!(make(PushConfig {
        relay_url: Some("  ".into()),
        ..base_cfg.clone()
    })
    .is_none());
    assert!(make(PushConfig {
        enabled: false,
        ..base_cfg
    })
    .is_none());
}

// ── caps: one satellite cannot crowd out another host's decisions ────────────

#[tokio::test]
async fn open_decisions_are_capped_per_host_and_one_satellite_cannot_crowd_out_the_local_host() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe", "sendai"], t0).await;

    // The daemon's own decision, raised first.
    rig.engine.ingest(
        decision_frame(
            None,
            "local-1",
            None,
            Some(AgentClass::Claudia),
            Some(Presence::Active),
        ),
        t0,
    );
    // A satellite floods the primary with decisions, one per second.
    for i in 0..100 {
        rig.engine.ingest(
            decision_frame(
                Some("kobe"),
                &format!("k{i:03}"),
                None,
                None,
                Some(Presence::Active),
            ),
            t0 + Duration::milliseconds(10 + 10 * i),
        );
    }
    // Another satellite has one.
    rig.engine.ingest(
        decision_frame(Some("sendai"), "s-1", None, None, Some(Presence::Active)),
        t0 + secs(2),
    );
    rig.engine.step_at(t0 + secs(10)).await;
    assert!(rig.posts().await.is_empty(), "none is due yet");

    let (items, badge) = rig.waiting("dev-1");
    let per_host = |h: &str| {
        items
            .iter()
            .filter(|i| i.kind == PushKind::Decision && i.host == h)
            .count()
    };
    assert_eq!(per_host("kobe"), 64, "a host's decisions are capped");
    assert_eq!(
        per_host("tokyo"),
        1,
        "the daemon's own decision survives the flood"
    );
    assert_eq!(per_host("sendai"), 1, "so does another satellite's");
    assert_eq!(badge, 66);

    // The oldest of the flood were dropped to make room, the newest kept.
    let at = t0 + secs(11);
    assert!(
        !rig.engine.ingest(resolved_frame(Some("kobe"), "k000"), at),
        "oldest evicted"
    );
    assert!(
        !rig.engine.ingest(resolved_frame(Some("kobe"), "k035"), at),
        "k035 evicted"
    );
    assert!(
        rig.engine.ingest(resolved_frame(Some("kobe"), "k036"), at),
        "k036 kept"
    );
    assert!(
        rig.engine.ingest(resolved_frame(Some("kobe"), "k099"), at),
        "newest kept"
    );
    assert!(
        rig.engine.ingest(resolved_frame(None, "local-1"), at),
        "local kept"
    );
}

#[tokio::test]
async fn a_known_decision_sent_again_does_not_count_against_the_cap_or_move_its_start() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    for i in 0..64 {
        rig.engine.ingest(
            decision_frame(
                Some("kobe"),
                &format!("k{i:03}"),
                None,
                None,
                Some(Presence::Active),
            ),
            t0 + Duration::milliseconds(10 * i),
        );
    }
    // The oldest is re-broadcast (presence changed): nothing is evicted for it.
    rig.engine.ingest(
        decision_frame(Some("kobe"), "k000", None, None, Some(Presence::Away)),
        t0 + secs(2),
    );
    rig.engine.step_at(t0 + secs(10)).await;
    assert_eq!(
        rig.posts().await.len(),
        1,
        "only the one that turned away is due"
    );
    let (items, _) = rig.waiting("dev-1");
    assert_eq!(
        items
            .iter()
            .filter(|i| i.kind == PushKind::Decision)
            .count(),
        64
    );
    assert!(rig
        .engine
        .ingest(resolved_frame(Some("kobe"), "k000"), t0 + secs(11)));
    assert!(rig
        .engine
        .ingest(resolved_frame(Some("kobe"), "k063"), t0 + secs(11)));
}

// ── W13-1, B9: nothing a worker or person wrote is in a relay request ────────

#[tokio::test]
async fn no_marker_appears_anywhere_in_any_relay_request_for_any_kind_or_host_class() {
    let mut rig =
        Rig::with_hosts(&[("kobe", HostClass::Work), ("sendai", HostClass::Personal)]).await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    let hosts = ["kobe", "sendai", "osaka"];
    rig.start(&hosts, t0).await;

    // Waves 300 s apart so no wave bursts: Mother + review + decision per host.
    for (i, host) in hosts.iter().enumerate() {
        let start = t0 + secs(300 * i as i64);
        let url = match *host {
            "sendai" => Some("https://github.com/thehammer/bishop/pull/12"),
            _ => Some("https://github.com/MARKER-owner/MARKER-repo/pull/12"),
        };
        let (repo, owner) = if *host == "sendai" {
            ("bishop", "thehammer")
        } else {
            ("MARKER-repo", "MARKER-owner")
        };
        rig.engine.ingest(
            jobs_frame(
                Some(host),
                vec![job("aaaa0001", "awaiting", Some("user"), Some(start), url)],
            ),
            start,
        );
        // The PR's own owner/repo is data, not free text: on a personal host a
        // personally-owned repository name is allowed, so only the hosts that never
        // show a name get the marker for it.
        let pr_repo = if *host == "sendai" {
            "thehammer/bishop"
        } else {
            "MARKER-owner/MARKER-repo"
        };
        rig.engine.ingest(
            queue_frame(
                Some(host),
                vec![pr(pr_repo, 4821 + i as u64, "requested", Some(75))],
            ),
            start,
        );
        rig.engine.ingest(
            decision_frame_for(
                Some(host),
                "req-1",
                Some(start + secs(900)),
                Some(AgentClass::Claudia),
                Some(Presence::Active),
                repo,
                owner,
            ),
            start,
        );
        rig.engine.step_at(start).await;
        rig.engine.step_at(start + secs(30)).await;
        rig.engine.step_at(start + secs(120)).await;
    }
    // A burst on kobe, then everything resolved (withdrawals, badge-only pushes).
    let burst_at = t0 + secs(1200);
    rig.engine.ingest(
        jobs_frame(
            Some("kobe"),
            (1..=4)
                .map(|n| awaiting(&format!("bbbb000{n}"), burst_at))
                .collect(),
        ),
        burst_at,
    );
    rig.engine.step_at(burst_at).await;
    rig.engine.step_at(burst_at + secs(120)).await;
    for host in hosts {
        rig.engine
            .ingest(jobs_frame(Some(host), vec![]), burst_at + secs(200));
        rig.engine
            .ingest(queue_frame(Some(host), vec![]), burst_at + secs(200));
        rig.engine
            .ingest(resolved_frame(Some(host), "req-1"), burst_at + secs(200));
    }
    rig.engine.step_at(burst_at + secs(200)).await;

    let raw = rig.raw_posts().await;
    assert!(raw.len() >= 12, "the scenario sent {} requests", raw.len());
    let ctx = VocabContext {
        hosts: hosts.iter().map(|h| h.to_string()).collect(),
        repos: vec!["bishop".into()],
    };
    for req in &raw {
        let body = String::from_utf8(req.body.clone()).unwrap();
        assert!(
            !body.to_ascii_lowercase().contains("marker"),
            "free text in a relay request: {body}"
        );
        assert!(
            !body.contains("fake-relay-token"),
            "the bearer token is a header, never a body: {body}"
        );
        let p: Value = serde_json::from_str(&body).unwrap();
        assert_request_shape(&p);
        for field in ["title", "body"] {
            if let Some(text) = p.get(field).and_then(Value::as_str) {
                assert!(
                    conforms(text, &ctx).is_ok(),
                    "{field} {text:?} is not in the vocabulary"
                );
            }
        }
    }
    // The personal host's personally-owned repository did show; no other did.
    let titles: Vec<String> = raw
        .iter()
        .filter_map(|r| serde_json::from_slice::<Value>(&r.body).ok())
        .filter_map(|p| p["title"].as_str().map(str::to_string))
        .collect();
    assert!(
        titles.iter().any(|t| t == "Mother · sendai · bishop"),
        "{titles:?}"
    );
    assert!(
        titles.iter().all(|t| !t.contains("admin-portal")),
        "{titles:?}"
    );
}

// ── B9: a work satellite's metadata-only frames notify like the full ones ────

/// What the primary's engine receives from a `work` satellite: the real
/// metadata redaction of the frame the satellite's daemon holds.
fn as_work_satellite_sends(msg: ServerMsg) -> ServerMsg {
    redact_for_uplink_metadata(msg, &[7u8; 32], &SensitiveTags::in_memory())
        .expect("a metadata frame")
}

/// What a request says, without what is random per run.
fn normalised(posts: &[Value]) -> Vec<Value> {
    posts
        .iter()
        .map(|p| {
            let mut p = p.clone();
            let o = p.as_object_mut().unwrap();
            o.remove("push_id");
            o.remove("collapse_id");
            o["data"].as_object_mut().unwrap().remove("item");
            p
        })
        .collect()
}

/// Run one scenario twice, as full frames and as a work satellite's metadata
/// frames, and return what each sent (and each one's waiting badge).
async fn notifications_both_ways(
    initial: Vec<ServerMsg>,
    frames: Vec<ServerMsg>,
    step_after: i64,
) -> ((Vec<Value>, u32), (Vec<Value>, u32)) {
    let mut out = Vec::new();
    for metadata in [false, true] {
        let mut rig = Rig::with_hosts(&[("kobe", HostClass::Work)]).await;
        let t0 = base();
        rig.register("dev-1", &token_a());
        let wrap = |m: ServerMsg| {
            if metadata {
                as_work_satellite_sends(m)
            } else {
                m
            }
        };
        for m in &initial {
            rig.engine.ingest(wrap(m.clone()), t0);
        }
        rig.engine.step_at(t0).await;
        for m in &frames {
            rig.engine.ingest(wrap(m.clone()), t0 + secs(1));
        }
        rig.engine.step_at(t0 + secs(1)).await;
        rig.engine.step_at(t0 + secs(step_after)).await;
        let posts = normalised(&rig.posts().await);
        let (_, badge) = rig.waiting("dev-1");
        out.push((posts, badge));
    }
    let metadata = out.pop().unwrap();
    let full = out.pop().unwrap();
    (full, metadata)
}

#[tokio::test]
async fn a_work_satellites_decision_notifies_exactly_like_the_full_frame() {
    let t0 = base();
    let (full, metadata) = notifications_both_ways(
        vec![],
        vec![decision_frame(
            Some("kobe"),
            "req-1",
            Some(t0 + secs(600)),
            Some(AgentClass::Claudia),
            Some(Presence::Away),
        )],
        10,
    )
    .await;
    assert_eq!(full.0.len(), 1);
    assert_eq!(full.0[0]["title"], "Decision · kobe");
    assert_eq!(
        metadata, full,
        "B9: the metadata arm keeps every fact the notification needs"
    );
}

#[tokio::test]
async fn a_work_satellites_mother_job_notifies_with_the_same_reason_as_the_full_job() {
    // The metadata arm sends `paused_reason` through a vocabulary that has no
    // `user`, `adherence_blocked`, `operator_hold`, `cost_cap` or `pipeline_blocked`,
    // so a Kobe job always reads "needs you" and the PRD's own example
    // (`Mother · kobe` / `Job 3f9a1c2e asked a question`) can never be produced.
    let cases: [(&str, Option<&str>, Option<&str>); 5] = [
        ("user", Some("user"), None),
        ("adherence_blocked", Some("adherence_blocked"), None),
        ("operator_hold", Some("operator_hold"), None),
        ("cost_cap", Some("cost_cap"), None),
        ("pipeline_blocked", None, Some("pipeline_blocked")),
    ];
    let mut differing = Vec::new();
    for (name, reason, activity) in cases {
        let t0 = base();
        let mut j = job("3f9a1c2e", "awaiting", reason, Some(t0 + secs(1)), None);
        if let Some(a) = activity {
            j = serde_json::from_value({
                let mut v = serde_json::to_value(&j).unwrap();
                v["activity"] = json!(a);
                v
            })
            .unwrap();
        }
        let (full, metadata) = notifications_both_ways(
            vec![jobs_frame(Some("kobe"), vec![])],
            vec![jobs_frame(Some("kobe"), vec![j])],
            121,
        )
        .await;
        assert_eq!(full.0.len(), 1, "{name}: the full job is posted");
        if metadata != full {
            differing.push(format!(
                "{name}: full {:?} but metadata {:?}",
                full.0.iter().map(|p| p["body"].clone()).collect::<Vec<_>>(),
                metadata
                    .0
                    .iter()
                    .map(|p| p["body"].clone())
                    .collect::<Vec<_>>()
            ));
        }
    }
    assert!(differing.is_empty(), "{differing:#?}");
}

#[tokio::test]
async fn a_quota_pause_on_a_work_satellite_makes_no_notification() {
    let t0 = base();
    for reason in ["quota_5h", "quota_weekly"] {
        let j = job(
            "3f9a1c2e",
            "awaiting",
            Some(reason),
            Some(t0 + secs(1)),
            None,
        );
        let (full, metadata) = notifications_both_ways(
            vec![jobs_frame(Some("kobe"), vec![])],
            vec![jobs_frame(Some("kobe"), vec![j])],
            121,
        )
        .await;
        assert!(
            full.0.is_empty() && full.1 == 0,
            "{reason}: a quota pause is no item"
        );
        assert_eq!(
            metadata, full,
            "{reason}: on a work satellite a quota pause is still no item"
        );
    }
}

#[tokio::test]
async fn a_work_satellites_attention_reasons_still_count_toward_the_badge() {
    let attention = with_attention(
        "3f9a1c2e",
        json!([
            {"reason": "progress_stalled", "since": "2026-11-26T09:00:00Z", "acked": false},
            {"reason": "burn_ahead", "since": "2026-11-26T09:05:00Z", "acked": false},
            {"reason": "gates_incomplete", "since": "2026-11-26T09:10:00Z", "acked": false},
        ]),
    );
    let (full, metadata) = notifications_both_ways(
        vec![jobs_frame(Some("kobe"), vec![])],
        vec![jobs_frame(Some("kobe"), vec![attention])],
        121,
    )
    .await;
    assert_eq!(full.1, 3);
    assert_eq!(
        metadata.1, 3,
        "the metadata arm turns each reason into `other`, so none counts"
    );
}

#[tokio::test]
async fn a_work_satellites_review_keeps_its_size() {
    // The metadata arm for PerriState keeps only `number` and `bucket`, so the size
    // phrase is never available for Kobe even though the PRD's own work-host
    // example is `Review · kobe` / `PR #4821 · small change · 3 waiting`.
    let queue = vec![
        pr("Carefeed/admin-portal", 4821, "requested", Some(10)),
        pr("Carefeed/admin-portal", 4822, "requested", Some(900)),
        pr("Carefeed/admin-portal", 4823, "requested", Some(120)),
    ];
    let (full, metadata) = notifications_both_ways(
        vec![queue_frame(Some("kobe"), vec![])],
        vec![queue_frame(Some("kobe"), queue)],
        121,
    )
    .await;
    assert_eq!(full.0.len(), 3);
    assert_eq!(metadata, full);
}

#[tokio::test]
async fn a_work_satellites_review_without_sizes_still_notifies_and_omits_the_size() {
    // Whatever the arm keeps, a review frame with no repository name and no line counts
    // is still a review item: `PR #n · k waiting`.
    let mut rig = Rig::with_hosts(&[("kobe", HostClass::Work)]).await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    let bare = |n| PrQueueItem {
        number: n,
        bucket: "requested".into(),
        ..Default::default()
    };
    rig.engine
        .ingest(queue_frame(Some("kobe"), vec![bare(4821), bare(4822)]), t0);
    rig.engine.step_at(t0).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let mut bodies: Vec<String> = rig
        .posts()
        .await
        .iter()
        .map(|p| p["body"].as_str().unwrap().to_string())
        .collect();
    bodies.sort();
    assert_eq!(bodies, vec!["PR #4821 · 2 waiting", "PR #4822 · 2 waiting"]);
}

// ── a PR seen on two hosts is one item ───────────────────────────────────────

#[tokio::test]
async fn a_pr_seen_on_two_hosts_is_one_item_keeping_the_first_host_to_report() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe", "sendai"], t0).await;
    // `sendai` reports first, `kobe` (which sorts earlier) five seconds later.
    let same = vec![pr("Carefeed/admin-portal", 4821, "requested", Some(10))];
    rig.engine
        .ingest(queue_frame(Some("sendai"), same.clone()), t0);
    rig.engine.step_at(t0).await;
    rig.engine
        .ingest(queue_frame(Some("kobe"), same), t0 + secs(5));
    rig.engine.step_at(t0 + secs(5)).await;
    rig.engine.step_at(t0 + secs(120)).await;
    let posts = rig.posts().await;
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert_eq!(
        posts[0]["title"], "Review · sendai",
        "the first host to report keeps it"
    );
    assert_eq!(posts[0]["badge"], 1);
}

// ── housekeeping: forgetting satellites, reconciling, expiring decisions ─────

fn hosts_frame(names: &[&str], t: DateTime<Utc>) -> ServerMsg {
    ServerMsg::Hosts {
        hosts: names
            .iter()
            .map(|n| nostromo::ipc::protocol::HostInfo {
                name: n.to_string(),
                egress: nostromo::ipc::devices::Egress::Personal,
                connected_since: t,
                last_seen: t,
            })
            .collect(),
    }
}

#[tokio::test]
async fn a_satellite_that_is_gone_and_silent_is_forgotten_and_its_items_stop_counting() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe", "sendai"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.ingest(
        jobs_frame(Some("sendai"), vec![awaiting("bbbb0001", t0)]),
        t0,
    );
    rig.engine.ingest(
        decision_frame(None, "local-1", None, None, Some(Presence::Active)),
        t0,
    );
    // sendai is connected (the primary's host list says so); kobe is not.
    rig.engine.ingest(hosts_frame(&["sendai"], t0), t0);
    rig.engine.step_at(t0).await;
    assert_eq!(rig.waiting("dev-1").1, 3);

    // Ten minutes of silence is not yet "gone"; more than ten is.
    rig.engine.housekeeping(None, t0 + secs(600));
    rig.engine.step_at(t0 + secs(600)).await;
    assert_eq!(rig.waiting("dev-1").1, 3, "10 min exactly: still counted");
    rig.engine.housekeeping(None, t0 + secs(601));
    rig.engine.step_at(t0 + secs(601)).await;
    let (items, badge) = rig.waiting("dev-1");
    assert_eq!(badge, 2, "kobe's job is no longer counted: {items:?}");
    assert!(items.iter().all(|i| i.host != "kobe"));
    assert!(
        items.iter().any(|i| i.host == "sendai"),
        "a connected satellite is kept however quiet"
    );
    assert!(
        items.iter().any(|i| i.host == "tokyo"),
        "and the daemon's own host is never forgotten"
    );
}

#[tokio::test]
async fn the_retained_frames_fill_in_a_host_the_engine_has_not_heard_from_but_do_not_overwrite_what_it_has(
) {
    let mut rig = Rig::new().await;
    // The reconcile is due 30 s after the engine's own (real) start, so this test keeps
    // every instant on the real clock rather than on the fabricated 10:00.
    let t0 = Utc::now();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine
        .ingest(jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", t0)]), t0);
    rig.engine.step_at(t0).await;

    // What the server's retained cache holds: an older kobe snapshot with another job,
    // and a snapshot of a host the engine has never heard from.
    let retained: nostromo::push::RetainedSource = Arc::new(|| {
        vec![
            jobs_frame(Some("kobe"), vec![awaiting("aaaa0002", base())]),
            jobs_frame(Some("osaka"), vec![awaiting("cccc0001", base())]),
            // The daemon's own frames carry no host and are not retained.
            jobs_frame(None, vec![awaiting("dddd0001", base())]),
        ]
    });
    // Every 30 s: due now.
    let later = t0 + secs(31);
    rig.engine.housekeeping(Some(&retained), later);
    rig.engine.step_at(later).await;
    let (items, badge) = rig.waiting("dev-1");
    let mut refs: Vec<(String, Option<String>)> = items
        .iter()
        .map(|i| (i.host.clone(), i.ref_.clone()))
        .collect();
    refs.sort();
    assert_eq!(
        refs,
        vec![
            ("kobe".to_string(), Some("Job aaaa0001".to_string())),
            ("osaka".to_string(), Some("Job cccc0001".to_string())),
        ],
        "kobe keeps what it said; osaka is filled in"
    );
    assert_eq!(badge, 2);
    assert!(
        rig.posts().await.is_empty(),
        "a host found this way was already waiting: counted, not pushed"
    );
}

#[tokio::test]
async fn a_decision_past_its_deadline_is_dropped_by_housekeeping() {
    let mut rig = Rig::new().await;
    let t0 = base();
    rig.register("dev-1", &token_a());
    rig.start(&["kobe"], t0).await;
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            Some(t0 + secs(60)),
            None,
            Some(Presence::Active),
        ),
        t0,
    );
    rig.engine.ingest(
        decision_frame(Some("kobe"), "req-2", None, None, Some(Presence::Active)),
        t0,
    );
    rig.engine.housekeeping(None, t0 + secs(59));
    // Still tracked at 59 s: resolving it finds it.
    assert!(rig
        .engine
        .ingest(resolved_frame(Some("kobe"), "req-1"), t0 + secs(59)));
    rig.engine.ingest(
        decision_frame(
            Some("kobe"),
            "req-1",
            Some(t0 + secs(60)),
            None,
            Some(Presence::Active),
        ),
        t0 + secs(59),
    );
    rig.engine.housekeeping(None, t0 + secs(60));
    assert!(
        !rig.engine
            .ingest(resolved_frame(Some("kobe"), "req-1"), t0 + secs(61)),
        "dropped at its deadline"
    );
    assert!(
        rig.engine
            .ingest(resolved_frame(Some("kobe"), "req-2"), t0 + secs(61)),
        "one with no deadline stays"
    );
}

/// A receiver that lagged the broadcast channel cannot have missed something for
/// good: the engine repairs from the retained frames (the lag is what a W12 `Gap` is).
#[tokio::test(start_paused = true)]
async fn a_lagged_receiver_is_repaired_from_the_retained_frames_at_the_next_tick() {
    let relay = MockServer::start().await;
    let tmp = TempDir::new().unwrap();
    let token = tmp.path().join("relay-token");
    std::fs::write(&token, "fake-relay-token\n").unwrap();
    let cfg = PushConfig {
        relay_url: Some(relay.uri()),
        relay_token_path: Some(token),
        state_dir: Some(tmp.path().join("push")),
        ..Default::default()
    };
    let source: ConfigSource = Arc::new(move || cfg.clone());
    let engine = PushEngine::new(source, "tokyo".into(), None).unwrap();
    let (tx, mut reply_rx) = mpsc::unbounded_channel();
    let registration = ClientMsg::RegisterPush {
        apns_token: token_a(),
        environment: PushEnvironment::Sandbox,
        tz: "UTC".into(),
        capabilities: PushCapabilities::default(),
    };
    assert_eq!(
        engine.dispatch(&registration, PeerTrust::Paired, Some("dev-1"), &tx),
        Dispatched::Handled
    );
    let _ = reply_rx.try_recv();

    // A channel too small for what is sent before the engine task first runs.
    let (frames_tx, frames_rx) = tokio::sync::broadcast::channel::<ServerMsg>(4);
    let retained: nostromo::push::RetainedSource =
        Arc::new(|| vec![jobs_frame(Some("kobe"), vec![awaiting("aaaa0001", base())])]);
    let handle = engine.spawn(frames_rx, Some(retained));
    for _ in 0..16 {
        let _ = frames_tx.send(ServerMsg::Pong);
    }
    // Let the engine's loop run: it sees the lag, and at its next tick reconciles.
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let replies = {
        let msg = ClientMsg::PushWaiting;
        assert_eq!(
            engine.dispatch(&msg, PeerTrust::Paired, Some("dev-1"), &tx),
            Dispatched::Handled
        );
        let mut v = Vec::new();
        while let Ok(m) = reply_rx.try_recv() {
            v.push(m);
        }
        v
    };
    match replies.last() {
        Some(ServerMsg::PushWaiting { items, badge }) => {
            assert_eq!(*badge, 1, "{items:?}");
            assert_eq!(items[0].host, "kobe");
        }
        other => panic!("{other:?}"),
    }
    handle.abort();
}
