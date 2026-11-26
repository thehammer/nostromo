//! W16: the one line of text a personal host's notification may gain on the phone.
//!
//! A paired phone's notification extension asks the primary, over the phone's own
//! authenticated socket, for `PushDetail { item_ref }` and gets back whether the
//! item still waits and, in exactly one situation, its first line. The relay and
//! Apple never see that line. The rule is DEFAULT-DENY: text is returned only when
//! ALL of these hold, and every case below differs from an allowed item by exactly
//! one of them (so removing any one guard fails exactly one test):
//!
//! * the item's host is classified `personal` (a host that is absent is `work`);
//! * the item is not PHI-scoped (its repository, plan path, PR URL or origin focus
//!   names a PHI repository: `admin-portal` and `referral-monitor`, plus
//!   `push.phi_repos`);
//! * the item is not on a sensitive tag, not a sensitive Mother job, not a job
//!   queued from a work item;
//! * the repository owner is known and is not a work owner (`Carefeed`, plus
//!   `push.work_owners`, compared ignoring case).
//!
//! The text is the first non-blank line of ONE field per kind (a Mother job's
//! `question`, a PR's `title`, a decision's `prompt`), at most 140 characters,
//! control characters removed. Every other free-text field in these fixtures holds
//! the word `MARKER`, and the whole serialized frame is searched for it.
//!
//! The engine is driven in process the way `tests/push_engine.rs` drives it:
//! `ingest(frame, now)` is what the broadcast channel delivers, a paired phone's
//! verbs go through `dispatch`, every APNs token is a fake and the clock is
//! fabricated. Nothing here sleeps.

#![allow(clippy::too_many_arguments)]

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Duration, Utc};
use nostromo::config::PushConfig;
use nostromo::data::perri_queue::PrQueueItem;
use nostromo::ipc::devices::SatelliteAdmin;
use nostromo::ipc::peer::{
    network_policy, satellite_allowed, NetworkPolicy, PeerTrust, SensitiveTags,
};
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, DecisionResolution, ServerMsg};
use nostromo::mother::{MotherJob, WORK_SEND_JOB_LABEL};
use nostromo::push::wire::{
    HostClass, Presence, PushCapabilities, PushEnvironment, PushWaitingItem,
};
use nostromo::push::{ConfigSource, Dispatched, PushEngine};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::mpsc;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── fixtures: names, texts, time ─────────────────────────────────────────────

const DEV: &str = "dev-1";
/// Classified `personal` by every rig.
const PERSONAL: &str = "sendai";
/// Classified `work` by every rig.
const WORK: &str = "kobe";
/// Not in `[push.hosts]` at all: a work host by default.
const UNLISTED: &str = "osaka";

const MOTHER_Q: &str = "Should I split the uploader module?";
const DECISION_P: &str = "Ship the retry budget tonight?";
const PR_TITLE: &str = "Add a retry budget to the uploader";
const PERSONAL_PR_URL: &str = "https://github.com/thehammer/nostromo/pull/12";

/// Present in every free-text field that must never reach the phone, including
/// the SECOND line of every multi-line source.
const MARKER: &str = "MARKER";

/// 10:00 UTC today, as in `tests/push_engine.rs`.
fn t0() -> DateTime<Utc> {
    Utc::now()
        .date_naive()
        .and_hms_opt(10, 0, 0)
        .unwrap()
        .and_utc()
}

fn secs(n: i64) -> Duration {
    Duration::seconds(n)
}

fn token() -> String {
    "ab".repeat(32)
}

fn ok_response() -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({"apns_status": 200}))
}

// ── the rig ──────────────────────────────────────────────────────────────────

/// What the three kinds of waiting item are called in a failure message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Mother,
    Review,
    Decision,
}

const KINDS: [Kind; 3] = [Kind::Mother, Kind::Review, Kind::Decision];

/// The first line the default item of `kind` carries.
fn first_line_of(kind: Kind) -> &'static str {
    match kind {
        Kind::Mother => MOTHER_Q,
        Kind::Review => PR_TITLE,
        Kind::Decision => DECISION_P,
    }
}

struct Rig {
    relay: MockServer,
    engine: Arc<PushEngine>,
    cfg: Arc<Mutex<PushConfig>>,
    _tmp: TempDir,
    tx: mpsc::UnboundedSender<ServerMsg>,
    rx: mpsc::UnboundedReceiver<ServerMsg>,
}

impl Rig {
    /// `sendai` is personal, `kobe` is work, `osaka` is unlisted; one paired
    /// device, `dev-1`, is registered.
    async fn new() -> Self {
        Self::with_config(|_| {}).await
    }

    async fn with_config(edit: impl FnOnce(&mut PushConfig)) -> Self {
        let relay = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/push"))
            .respond_with(ok_response())
            .mount(&relay)
            .await;
        let tmp = TempDir::new().unwrap();
        let token_path = tmp.path().join("relay-token");
        std::fs::write(&token_path, "fake-relay-token\n").unwrap();
        let mut cfg = PushConfig {
            relay_url: Some(relay.uri()),
            relay_token_path: Some(token_path),
            state_dir: Some(tmp.path().join("push")),
            ..Default::default()
        };
        cfg.hosts.insert(PERSONAL.into(), HostClass::Personal);
        cfg.hosts.insert(WORK.into(), HostClass::Work);
        edit(&mut cfg);
        let cfg = Arc::new(Mutex::new(cfg));
        let source: ConfigSource = {
            let cfg = Arc::clone(&cfg);
            Arc::new(move || cfg.lock().unwrap().clone())
        };
        let engine = PushEngine::new(source, "tokyo".into(), None).expect("an engine");
        let (tx, rx) = mpsc::unbounded_channel();
        let mut rig = Rig {
            relay,
            engine,
            cfg,
            _tmp: tmp,
            tx,
            rx,
        };
        rig.paired(&ClientMsg::RegisterPush {
            apns_token: token(),
            environment: PushEnvironment::Sandbox,
            tz: "UTC".into(),
            capabilities: PushCapabilities::default(),
        });
        rig
    }

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

    /// A verb from the paired phone `dev-1`; it must be handled.
    fn paired(&mut self, msg: &ClientMsg) -> Vec<ServerMsg> {
        let (handled, replies) = self.verb(msg, PeerTrust::Paired, Some(DEV));
        assert_eq!(handled, Dispatched::Handled, "{msg:?}");
        replies
    }

    /// What waits, as the phone lists it (this is how a phone learns an `item_ref`).
    fn waiting(&mut self) -> Vec<PushWaitingItem> {
        match self.paired(&ClientMsg::PushWaiting).pop() {
            Some(ServerMsg::PushWaiting { items, .. }) => items,
            other => panic!("expected PushWaiting, got {other:?}"),
        }
    }

    fn refs(&mut self) -> BTreeSet<String> {
        self.waiting().into_iter().map(|i| i.item_ref).collect()
    }

    /// The `item_ref` of the one thing that waits.
    fn only_ref(&mut self) -> String {
        let items = self.waiting();
        assert_eq!(items.len(), 1, "exactly one item waits: {items:#?}");
        items[0].item_ref.clone()
    }

    fn detail(&mut self, item_ref: &str) -> Reply {
        reply_of(self.paired(&ClientMsg::PushDetail {
            item_ref: item_ref.to_string(),
        }))
    }

    fn only_detail(&mut self) -> Reply {
        let item_ref = self.only_ref();
        self.detail(&item_ref)
    }

    // ── sources ──────────────────────────────────────────────────────────────

    fn job(&self, host: &str, job: MotherJob) {
        self.engine.ingest(jobs_frame(Some(host), vec![job]), t0());
    }

    fn review(&self, host: &str, pr: PrQueueItem) {
        self.engine.ingest(queue_frame(Some(host), vec![pr]), t0());
    }

    fn ask(&self, ask: Ask) {
        self.engine.ingest(ask.frame(), t0());
    }

    /// The default (personal-owner, non-PHI, multi-line) item of `kind` on `host`.
    fn put(&self, kind: Kind, host: &str) {
        match kind {
            Kind::Mother => self.job(host, mother_job("3f9a1c2e", json!({}))),
            Kind::Review => self.review(host, pr("thehammer/nostromo", 12, &two_lines(PR_TITLE))),
            Kind::Decision => self.ask(Ask::new(host, "req-1")),
        }
    }

    /// The default item of `kind` on `host` leaves the waiting set.
    fn resolve(&self, kind: Kind, host: &str) {
        let t = t0() + secs(60);
        match kind {
            Kind::Mother => self.engine.ingest(
                jobs_frame(
                    Some(host),
                    vec![mother_job(
                        "3f9a1c2e",
                        json!({"state": "running", "paused_reason": null}),
                    )],
                ),
                t,
            ),
            Kind::Review => self.engine.ingest(
                queue_frame(
                    Some(host),
                    vec![pr_in(
                        "thehammer/nostromo",
                        12,
                        "needs_review",
                        &two_lines(PR_TITLE),
                    )],
                ),
                t,
            ),
            Kind::Decision => self.engine.ingest(resolved_frame(Some(host), "req-1"), t),
        };
    }
}

// ── frames ───────────────────────────────────────────────────────────────────

fn two_lines(first: &str) -> String {
    format!("{first}\nMARKER-second-line")
}

fn job_id(suffix: &str) -> String {
    format!("20261126T100000Z-{suffix}")
}

/// An awaiting Mother job, allowed on a personal host (a personal-owner `pr_url`,
/// no PHI anywhere) with a marker in every free-text field and a second line in
/// its `question`. `overrides` replaces keys of the job's JSON; `null` removes one.
fn mother_job(suffix: &str, overrides: Value) -> MotherJob {
    let mut v = json!({
        "id": job_id(suffix), "state": "awaiting", "paused_reason": "user",
        "paused_at": t0().to_rfc3339(),
        "title": "MARKER-title", "repo": "MARKER-repo", "plan_path": "/MARKER-plan.md",
        "question": two_lines(MOTHER_Q),
        "adherence_notes": "MARKER-notes", "current_activity": "MARKER-activity-text",
        "failure_reason": "MARKER-failure",
        "origin": {"label": "MARKER-label", "focus_name": "MARKER-focus", "session": "MARKER-session"},
        "pr_url": PERSONAL_PR_URL,
    });
    let o = v.as_object_mut().unwrap();
    for (key, value) in overrides.as_object().expect("overrides are an object") {
        if value.is_null() {
            o.remove(key);
        } else {
            o.insert(key.clone(), value.clone());
        }
    }
    serde_json::from_value(v).unwrap()
}

fn jobs_frame(host: Option<&str>, jobs: Vec<MotherJob>) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs,
        host: host.map(str::to_string),
    }
}

fn pr_in(repo: &str, number: u64, bucket: &str, title: &str) -> PrQueueItem {
    PrQueueItem {
        repo: repo.into(),
        number,
        title: title.into(),
        author: "MARKER-author".into(),
        bucket: bucket.into(),
        url: "https://github.com/MARKER-owner/MARKER-repo/pull/1".into(),
        tickets: vec!["MARKER-ticket".into()],
        changed_lines: Some(10),
        ..Default::default()
    }
}

/// A PR in the `requested` bucket.
fn pr(repo: &str, number: u64, title: &str) -> PrQueueItem {
    pr_in(repo, number, "requested", title)
}

fn queue_frame(host: Option<&str>, queue: Vec<PrQueueItem>) -> ServerMsg {
    ServerMsg::PerriState {
        tag: "f-00000000".into(),
        queue,
        current: None,
        jira_site: None,
        host: host.map(str::to_string),
        queue_unfetched: false,
    }
}

/// An open decision, allowed on a personal host by default: owner `thehammer`,
/// repo `nostromo`, a multi-line prompt, and markers in the `detail`, every
/// choice's label and detail, and the pane.
struct Ask {
    host: String,
    id: String,
    tag: String,
    prompt: String,
    repo: Option<String>,
    owner: Option<String>,
}

impl Ask {
    fn new(host: &str, id: &str) -> Self {
        Ask {
            host: host.into(),
            id: id.into(),
            tag: "claudia-focus".into(),
            prompt: two_lines(DECISION_P),
            repo: Some("nostromo".into()),
            owner: Some("thehammer".into()),
        }
    }

    fn tag(mut self, tag: &str) -> Self {
        self.tag = tag.into();
        self
    }

    fn prompt(mut self, prompt: &str) -> Self {
        self.prompt = prompt.into();
        self
    }

    fn repo(mut self, repo: Option<&str>, owner: Option<&str>) -> Self {
        self.repo = repo.map(str::to_string);
        self.owner = owner.map(str::to_string);
        self
    }

    fn frame(&self) -> ServerMsg {
        ServerMsg::DecisionRequest {
            tag: self.tag.clone(),
            request_id: self.id.clone(),
            prompt: self.prompt.clone(),
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
            host: Some(self.host.clone()),
            deadline: None,
            agent_class: None,
            operator_presence: Some(Presence::Active),
            repo: self.repo.clone(),
            repo_owner: self.owner.clone(),
        }
    }
}

fn resolved_frame(host: Option<&str>, id: &str) -> ServerMsg {
    ServerMsg::DecisionResolved {
        tag: "claudia-focus".into(),
        request_id: id.into(),
        resolution: DecisionResolution::Answered,
        choice_id: Some("c0".into()),
        host: host.map(str::to_string),
    }
}

// ── what a reply says ────────────────────────────────────────────────────────

/// A `ServerMsg::PushDetail`, plus the exact JSON a phone would read.
#[derive(Debug)]
struct Reply {
    item_ref: String,
    waiting: bool,
    text: Option<String>,
    host: Option<String>,
    json: String,
}

fn reply_of(mut replies: Vec<ServerMsg>) -> Reply {
    assert_eq!(replies.len(), 1, "exactly one reply: {replies:?}");
    let msg = replies.pop().unwrap();
    let json = serde_json::to_string(&msg).unwrap();
    match msg {
        ServerMsg::PushDetail {
            item_ref,
            waiting,
            text,
            host,
        } => Reply {
            item_ref,
            waiting,
            text,
            host,
            json,
        },
        other => panic!("expected PushDetail, got {other:?}"),
    }
}

/// The item waits, the phone may show `line`, and the frame holds no other
/// free text (not a second line, a title, a detail, a choice label, a plan).
fn assert_shows(r: &Reply, line: &str) {
    assert!(r.waiting, "{r:?}");
    assert_eq!(r.text.as_deref(), Some(line), "{r:?}");
    assert!(
        !r.json.contains(MARKER),
        "something other than the one line leaked: {}",
        r.json
    );
}

/// The item waits and the frame carries no text: no `text` key at all, none of
/// the default lines, and no marker.
fn assert_no_text(r: &Reply, why: &str) {
    assert!(r.waiting, "{why}: the item still waits: {r:?}");
    assert_eq!(r.text, None, "{why}: {r:?}");
    let v: Value = serde_json::from_str(&r.json).unwrap();
    assert!(v.get("text").is_none(), "{why}: {}", r.json);
    for line in [MOTHER_Q, DECISION_P, PR_TITLE] {
        assert!(!r.json.contains(line), "{why}: {}", r.json);
    }
    assert!(!r.json.contains(MARKER), "{why}: {}", r.json);
}

/// The ref is not a waiting item: nothing but the (bounded) ref comes back.
fn assert_not_waiting(r: &Reply, item_ref: &str, why: &str) {
    assert_eq!(r.item_ref, item_ref, "{why}: {r:?}");
    assert!(!r.waiting, "{why}: {r:?}");
    assert_eq!(r.text, None, "{why}: {r:?}");
    assert_eq!(r.host, None, "{why}: {r:?}");
    let v: Value = serde_json::from_str(&r.json).unwrap();
    assert!(
        v.get("text").is_none() && v.get("host").is_none(),
        "{why}: {}",
        r.json
    );
}

// ── one-shot scenarios ───────────────────────────────────────────────────────

/// A fresh rig with the default item of `kind` on `host`, and its reply.
async fn reply_on_host(kind: Kind, host: &str) -> Reply {
    let mut rig = Rig::new().await;
    rig.put(kind, host);
    rig.only_detail()
}

/// A fresh rig (config edited first) with an otherwise-allowed item of `kind`
/// on the personal host, in the repository `owner/repo`, and its reply. A
/// Mother job names its repository through its `pr_url`.
async fn reply_in_repo(
    kind: Kind,
    owner: &str,
    repo: &str,
    edit: impl FnOnce(&mut PushConfig),
) -> Reply {
    let mut rig = Rig::with_config(edit).await;
    match kind {
        Kind::Mother => rig.job(
            PERSONAL,
            mother_job(
                "3f9a1c2e",
                json!({"pr_url": format!("https://github.com/{owner}/{repo}/pull/12")}),
            ),
        ),
        Kind::Review => rig.review(
            PERSONAL,
            pr(&format!("{owner}/{repo}"), 12, &two_lines(PR_TITLE)),
        ),
        Kind::Decision => rig.ask(Ask::new(PERSONAL, "req-1").repo(Some(repo), Some(owner))),
    }
    rig.only_detail()
}

/// A fresh rig with an item of `kind` whose source text is `raw`, everything
/// else allowed, and its reply.
async fn reply_with_source_text(kind: Kind, raw: &str) -> Reply {
    let mut rig = Rig::new().await;
    match kind {
        Kind::Mother => rig.job(PERSONAL, mother_job("3f9a1c2e", json!({"question": raw}))),
        Kind::Review => rig.review(PERSONAL, pr("thehammer/nostromo", 12, raw)),
        Kind::Decision => rig.ask(Ask::new(PERSONAL, "req-1").prompt(raw)),
    }
    rig.only_detail()
}

// ── who may ask ──────────────────────────────────────────────────────────────

fn all_trusts() -> Vec<(PeerTrust, Option<&'static str>)> {
    let satellite = PeerTrust::Satellite {
        admin: SatelliteAdmin::Full,
    };
    vec![
        (PeerTrust::Tcp, None),
        (PeerTrust::Tcp, Some(DEV)),
        (satellite, None),
        (satellite, Some(DEV)),
        (PeerTrust::Routed, None),
        (PeerTrust::Routed, Some(DEV)),
        (PeerTrust::LocalOther, None),
        (PeerTrust::LocalOther, Some(DEV)),
        (PeerTrust::OperatorApp, None),
        (PeerTrust::OperatorApp, Some(DEV)),
        (PeerTrust::Paired, None),
        (PeerTrust::Paired, Some(DEV)),
    ]
}

#[tokio::test]
async fn only_a_paired_phone_with_a_device_is_answered_push_detail() {
    let mut rig = Rig::new().await;
    rig.put(Kind::Decision, PERSONAL);
    let item_ref = rig.only_ref();
    let msg = ClientMsg::PushDetail {
        item_ref: item_ref.clone(),
    };

    // Control: the paired phone is answered, with text for this item.
    assert_shows(&rig.detail(&item_ref), DECISION_P);

    for (trust, device) in all_trusts() {
        if trust == PeerTrust::Paired && device.is_some() {
            continue;
        }
        let (handled, replies) = rig.verb(&msg, trust, device);
        assert_eq!(handled, Dispatched::NotHandled, "{trust:?} {device:?}");
        assert!(replies.is_empty(), "{trust:?} {device:?}: {replies:?}");
    }
}

#[test]
fn push_detail_is_neither_a_network_verb_nor_a_satellites() {
    let msg = ClientMsg::PushDetail {
        item_ref: "0123456789abcdef".into(),
    };
    assert_eq!(network_policy(&msg), NetworkPolicy::Refused);
    assert!(!satellite_allowed(&msg));
}

// ── the item still waits, or it does not ─────────────────────────────────────

#[tokio::test]
async fn an_unknown_item_ref_is_not_waiting_and_carries_no_text_or_host() {
    let mut rig = Rig::new().await;
    // Even with something waiting, a ref that is not its ref says nothing.
    rig.put(Kind::Decision, PERSONAL);
    for item_ref in ["0123456789abcdef", "", "not a ref at all"] {
        let r = rig.detail(item_ref);
        assert_not_waiting(&r, item_ref, &format!("ref {item_ref:?}"));
    }
}

#[tokio::test]
async fn an_oversized_item_ref_is_echoed_at_most_64_characters_long() {
    let mut rig = Rig::new().await;
    let long = "a".repeat(200);
    let r = rig.detail(&long);
    assert_eq!(r.item_ref, "a".repeat(64), "{r:?}");
    assert!(!r.waiting && r.text.is_none() && r.host.is_none(), "{r:?}");
    assert!(
        r.json.len() < 400,
        "the reply is not an amplifier of its request: {}",
        r.json.len()
    );

    // Multi-byte characters are cut on a character, never inside one.
    let wide = "é".repeat(200);
    let r = rig.detail(&wide);
    assert_eq!(r.item_ref, "é".repeat(64), "{r:?}");
    assert!(!r.waiting);
}

#[tokio::test]
async fn an_item_that_is_resolved_answers_not_waiting_and_loses_its_text() {
    for kind in KINDS {
        let mut rig = Rig::new().await;
        rig.put(kind, PERSONAL);
        let item_ref = rig.only_ref();
        assert_shows(&rig.detail(&item_ref), first_line_of(kind));

        rig.resolve(kind, PERSONAL);
        let r = rig.detail(&item_ref);
        assert_not_waiting(&r, &item_ref, &format!("{kind:?} after it was resolved"));
    }
}

#[tokio::test]
async fn a_count_only_attention_item_waits_but_never_has_text() {
    // A running job that raised attention reasons is counted in the badge and has
    // an item ref, but it has no question to show, whatever the job holds.
    let mut rig = Rig::new().await;
    let stalled = mother_job(
        "3f9a1c2e",
        json!({
            "state": "running", "paused_reason": null, "paused_at": null,
            "attention_reasons": [
                {"reason": "progress_stalled", "since": "2026-11-26T09:00:00Z", "acked": false}
            ],
        }),
    );
    rig.job(PERSONAL, stalled);
    let r = rig.only_detail();
    assert_no_text(&r, "an attention item");
    assert!(r.host.is_some(), "{r:?}");
}

// ── an allowed item shows its one line and nothing else ──────────────────────

#[tokio::test]
async fn a_personal_decision_returns_the_first_line_of_its_prompt_and_never_its_detail_or_choices()
{
    let r = reply_on_host(Kind::Decision, PERSONAL).await;
    assert_shows(&r, DECISION_P);
    assert_eq!(r.host.as_deref(), Some(PERSONAL), "{r:?}");
    // The markers cover `detail`, the choice labels and details, and the pane;
    // say so for the two the PRD names.
    assert!(!r.json.contains("MARKER-detail"), "{}", r.json);
    assert!(!r.json.contains("MARKER-choice-label"), "{}", r.json);
    assert!(!r.json.contains("MARKER-prompt-second-line") && !r.json.contains("second-line"));
}

#[tokio::test]
async fn a_personal_mother_job_returns_the_first_line_of_its_question_only() {
    let r = reply_on_host(Kind::Mother, PERSONAL).await;
    assert_shows(&r, MOTHER_Q);
    assert_eq!(r.host.as_deref(), Some(PERSONAL), "{r:?}");
    for leaked in [
        "MARKER-title",
        "MARKER-notes",
        "MARKER-plan",
        "MARKER-activity-text",
        "MARKER-failure",
        "MARKER-label",
        "MARKER-focus",
        "MARKER-session",
        "MARKER-repo",
        "second-line",
    ] {
        assert!(!r.json.contains(leaked), "{leaked}: {}", r.json);
    }
}

#[tokio::test]
async fn a_personal_review_returns_the_first_line_of_the_pr_title_only() {
    let r = reply_on_host(Kind::Review, PERSONAL).await;
    assert_shows(&r, PR_TITLE);
    assert_eq!(r.host.as_deref(), Some(PERSONAL), "{r:?}");
    for leaked in [
        "MARKER-author",
        "MARKER-ticket",
        "MARKER-owner",
        "second-line",
    ] {
        assert!(!r.json.contains(leaked), "{leaked}: {}", r.json);
    }
}

// ── condition 1: the host is personal ────────────────────────────────────────

#[tokio::test]
async fn an_item_on_a_work_host_never_has_text_and_the_same_item_on_a_personal_host_does() {
    for kind in KINDS {
        // Control: identical item, personal host.
        assert_shows(&reply_on_host(kind, PERSONAL).await, first_line_of(kind));

        let on_work = reply_on_host(kind, WORK).await;
        assert_no_text(&on_work, &format!("{kind:?} on a work host"));

        let unlisted = reply_on_host(kind, UNLISTED).await;
        assert_no_text(
            &unlisted,
            &format!("{kind:?} on a host the config does not list (work by default)"),
        );
    }
}

#[tokio::test]
async fn a_host_reclassified_as_work_loses_its_text_on_the_next_request_and_regains_it_when_flipped_back(
) {
    for kind in KINDS {
        let mut rig = Rig::new().await;
        rig.put(kind, PERSONAL);
        let item_ref = rig.only_ref();
        assert_shows(&rig.detail(&item_ref), first_line_of(kind));

        rig.cfg
            .lock()
            .unwrap()
            .hosts
            .insert(PERSONAL.into(), HostClass::Work);
        assert_no_text(
            &rig.detail(&item_ref),
            &format!("{kind:?}: the host was flipped to work"),
        );

        rig.cfg
            .lock()
            .unwrap()
            .hosts
            .insert(PERSONAL.into(), HostClass::Personal);
        assert_shows(&rig.detail(&item_ref), first_line_of(kind));

        rig.cfg.lock().unwrap().hosts.remove(PERSONAL);
        assert_no_text(
            &rig.detail(&item_ref),
            &format!("{kind:?}: the host is no longer listed"),
        );
    }
}

// ── condition 2: not PHI-scoped ──────────────────────────────────────────────

#[tokio::test]
async fn an_item_in_a_phi_repository_has_no_text_even_on_a_personal_host_with_a_personal_owner() {
    for kind in KINDS {
        // Control: the same shape in a repository that is not PHI.
        let ok = reply_in_repo(kind, "thehammer", "nostromo", |_| {}).await;
        assert_shows(&ok, first_line_of(kind));

        // The owner is `thehammer` (not a work owner) throughout: only the PHI
        // rule can deny these.
        for repo in [
            "admin-portal",
            "referral-monitor",
            "Admin-Portal",
            "admin-portal-feat-x",
        ] {
            let r = reply_in_repo(kind, "thehammer", repo, |_| {}).await;
            assert_no_text(&r, &format!("{kind:?} in the PHI repository {repo}"));
        }
    }
}

#[tokio::test]
async fn a_mother_job_is_phi_scoped_by_its_plan_path_its_origin_focus_or_its_repo_as_well_as_its_pr_url(
) {
    let origin = |focus: &str| json!({"origin": {"label": "MARKER-label", "focus_name": focus, "session": "MARKER-session"}});
    let cases: Vec<(&str, Value)> = vec![
        (
            "plan_path inside referral-monitor",
            json!({"plan_path": "/Users/me/Code/referral-monitor/.claude/plans/p.md"}),
        ),
        (
            "plan_path inside an admin-portal worktree",
            json!({"plan_path": "/Users/me/Code/admin-portal-feat-x/plan.md"}),
        ),
        ("origin focus named admin-portal", origin("admin-portal")),
        (
            "origin focus named after a referral-monitor worktree",
            origin("referral-monitor-feat-x"),
        ),
        (
            "repo path is the admin-portal checkout",
            json!({"repo": "/Users/me/Code/Admin-Portal"}),
        ),
    ];
    for (why, overrides) in cases {
        let mut rig = Rig::new().await;
        // The pr_url is the personal one, so the owner is known and allowed.
        rig.job(PERSONAL, mother_job("3f9a1c2e", overrides));
        assert_no_text(&rig.only_detail(), why);
    }

    // Control: the same job with none of those is shown.
    assert_shows(&reply_on_host(Kind::Mother, PERSONAL).await, MOTHER_Q);
}

#[tokio::test]
async fn repositories_added_through_phi_repos_are_phi_too_and_only_once_configured() {
    for kind in KINDS {
        // Not configured: a repository called `ledger` is an ordinary one.
        assert_shows(
            &reply_in_repo(kind, "thehammer", "ledger", |_| {}).await,
            first_line_of(kind),
        );
        let configured = reply_in_repo(kind, "thehammer", "ledger", |c| {
            c.phi_repos = vec!["Ledger".into()];
        })
        .await;
        assert_no_text(
            &configured,
            &format!("{kind:?} in a configured PHI repository"),
        );

        // The built-in ones are still PHI when more are configured.
        let builtin = reply_in_repo(kind, "thehammer", "admin-portal", |c| {
            c.phi_repos = vec!["ledger".into()];
        })
        .await;
        assert_no_text(&builtin, &format!("{kind:?} in a built-in PHI repository"));
    }
}

// ── condition 3: not sensitive, not a work send ──────────────────────────────

#[tokio::test]
async fn a_decision_on_a_sensitive_tag_has_no_text() {
    let tags = SensitiveTags::in_memory();
    tags.mark_tag("focus-7c1e");

    // Control: an unregistered tag shows its prompt.
    let mut rig = Rig::new().await;
    rig.engine.set_sensitive_tags(tags.clone());
    rig.ask(Ask::new(PERSONAL, "req-ok").tag("focus-other"));
    assert_shows(&rig.only_detail(), DECISION_P);

    // A tag registered as sensitive.
    let mut rig = Rig::new().await;
    rig.engine.set_sensitive_tags(tags.clone());
    rig.ask(Ask::new(PERSONAL, "req-1").tag("focus-7c1e"));
    assert_no_text(&rig.only_detail(), "a registered sensitive tag");

    // A tag that is sensitive by what it is (the Teri agent's), registered or not.
    let mut rig = Rig::new().await;
    rig.engine.set_sensitive_tags(tags);
    rig.ask(Ask::new(PERSONAL, "req-2").tag("teri"));
    assert_no_text(&rig.only_detail(), "the Teri agent's tag");
}

#[tokio::test]
async fn a_mother_job_marked_sensitive_has_no_text() {
    let tags = SensitiveTags::in_memory();
    tags.mark_job(&job_id("5e5e5e5e"));

    // Control: another job, same registry.
    let mut rig = Rig::new().await;
    rig.engine.set_sensitive_tags(tags.clone());
    rig.job(PERSONAL, mother_job("3f9a1c2e", json!({})));
    assert_shows(&rig.only_detail(), MOTHER_Q);

    let mut rig = Rig::new().await;
    rig.engine.set_sensitive_tags(tags);
    rig.job(PERSONAL, mother_job("5e5e5e5e", json!({})));
    assert_no_text(&rig.only_detail(), "a job the registry marked sensitive");
}

#[tokio::test]
async fn a_mother_job_queued_from_a_work_item_has_no_text() {
    let from_work = json!({
        "origin": {"label": WORK_SEND_JOB_LABEL, "focus_name": "MARKER-focus", "session": "MARKER-session"},
    });
    let mut rig = Rig::new().await;
    rig.job(PERSONAL, mother_job("3f9a1c2e", from_work));
    assert_no_text(&rig.only_detail(), "a work-send job on a personal host");
}

// ── condition 4: the owner is known and is not a work owner ──────────────────

#[tokio::test]
async fn a_mother_job_with_a_bare_repo_and_no_pr_url_has_no_text() {
    // Without a pr_url nothing says who owns `repo`, so the owner is unknown.
    let mut rig = Rig::new().await;
    rig.job(
        PERSONAL,
        mother_job(
            "3f9a1c2e",
            json!({"repo": "thehammer/nostromo", "pr_url": null}),
        ),
    );
    assert_no_text(&rig.only_detail(), "a bare repo and no pr_url");

    // A pr_url that is not a GitHub URL names no owner either.
    let mut rig = Rig::new().await;
    rig.job(
        PERSONAL,
        mother_job(
            "3f9a1c2e",
            json!({"pr_url": "https://example.com/thehammer/nostromo/pull/12"}),
        ),
    );
    assert_no_text(&rig.only_detail(), "a pr_url that is not GitHub's");
}

#[tokio::test]
async fn a_decision_with_an_unknown_owner_has_no_text() {
    for owner in [None, Some("")] {
        let mut rig = Rig::new().await;
        rig.ask(Ask::new(PERSONAL, "req-1").repo(Some("nostromo"), owner));
        assert_no_text(&rig.only_detail(), &format!("owner {owner:?}"));
    }
}

#[tokio::test]
async fn a_review_whose_repo_names_no_owner_has_no_text() {
    let mut rig = Rig::new().await;
    rig.review(PERSONAL, pr("nostromo", 12, &two_lines(PR_TITLE)));
    assert_no_text(&rig.only_detail(), "a repo with no owner part");
}

#[tokio::test]
async fn an_item_in_a_carefeed_repository_has_no_text_even_on_a_personal_host() {
    for kind in KINDS {
        for owner in ["Carefeed", "carefeed", "CAREFEED"] {
            let r = reply_in_repo(kind, owner, "portal", |_| {}).await;
            assert_no_text(&r, &format!("{kind:?} owned by {owner}"));
        }
    }
}

#[tokio::test]
async fn owners_added_through_work_owners_are_denied_ignoring_case_and_only_once_configured() {
    for kind in KINDS {
        // Not configured: Acme is an ordinary owner.
        assert_shows(
            &reply_in_repo(kind, "Acme", "tool", |_| {}).await,
            first_line_of(kind),
        );
        for owner in ["Acme", "acme", "ACME"] {
            let r = reply_in_repo(kind, owner, "tool", |c| {
                c.work_owners = vec!["Acme".into()];
            })
            .await;
            assert_no_text(
                &r,
                &format!("{kind:?} owned by {owner}, a configured work owner"),
            );
        }
        // Other owners are untouched by the setting.
        let other = reply_in_repo(kind, "thehammer", "nostromo", |c| {
            c.work_owners = vec!["Acme".into()];
        })
        .await;
        assert_shows(&other, first_line_of(kind));
    }
}

#[tokio::test]
async fn an_owner_added_to_work_owners_takes_effect_on_the_next_request() {
    for kind in KINDS {
        let mut rig = Rig::new().await;
        rig.put(kind, PERSONAL);
        let item_ref = rig.only_ref();
        assert_shows(&rig.detail(&item_ref), first_line_of(kind));

        rig.cfg.lock().unwrap().work_owners = vec!["TheHammer".into()];
        assert_no_text(
            &rig.detail(&item_ref),
            &format!("{kind:?}: its owner became a work owner"),
        );

        rig.cfg.lock().unwrap().work_owners = Vec::new();
        assert_shows(&rig.detail(&item_ref), first_line_of(kind));
    }
}

// ── the text itself ──────────────────────────────────────────────────────────

#[tokio::test]
async fn the_text_is_the_first_non_blank_line_of_the_source() {
    let cases: [(&str, &str); 4] = [
        ("Just one line", "Just one line"),
        ("First\nMARKER-second", "First"),
        (
            "\n\n  \t\nFirst after blanks\nMARKER-second",
            "First after blanks",
        ),
        ("First with CRLF\r\nMARKER-second", "First with CRLF"),
    ];
    for kind in KINDS {
        for (raw, expected) in cases {
            let r = reply_with_source_text(kind, raw).await;
            assert_shows(&r, expected);
        }
    }
}

#[tokio::test]
async fn a_source_with_no_non_blank_line_has_no_text() {
    for kind in KINDS {
        for raw in ["", "   ", "\n\t \n  \n"] {
            let r = reply_with_source_text(kind, raw).await;
            assert_no_text(&r, &format!("{kind:?} with source {raw:?}"));
        }
    }
    // A job with no question at all.
    let mut rig = Rig::new().await;
    rig.job(PERSONAL, mother_job("3f9a1c2e", json!({"question": null})));
    assert_no_text(&rig.only_detail(), "a job with no question");
}

#[tokio::test]
async fn a_line_over_140_characters_is_cut_to_139_and_an_ellipsis_and_one_at_140_is_not() {
    for kind in KINDS {
        for len in [1, 139, 140] {
            let raw = "x".repeat(len);
            let r = reply_with_source_text(kind, &raw).await;
            assert_shows(&r, &raw);
        }
        let cut = format!("{}…", "x".repeat(139));
        for len in [141, 300, 5000] {
            let r = reply_with_source_text(kind, &"x".repeat(len)).await;
            assert_shows(&r, &cut);
            assert_eq!(r.text.as_deref().unwrap().chars().count(), 140);
        }
    }
}

#[tokio::test]
async fn the_limit_counts_characters_and_a_cut_never_lands_inside_one() {
    for kind in KINDS {
        for unit in ["é", "日", "😀"] {
            // 140 characters is 280 to 560 bytes: not cut.
            let exact = unit.repeat(140);
            assert_shows(&reply_with_source_text(kind, &exact).await, &exact);

            let r = reply_with_source_text(kind, &unit.repeat(141)).await;
            assert_shows(&r, &format!("{}…", unit.repeat(139)));
        }
    }
}

#[tokio::test]
async fn control_characters_are_removed_from_the_text() {
    for kind in KINDS {
        let r = reply_with_source_text(kind, "Deploy\u{1b}[31m now\u{0}!\u{7}").await;
        assert_shows(&r, "Deploy[31m now!");
        let text = r.text.unwrap();
        assert!(!text.chars().any(char::is_control), "{text:?}");
    }
}

// ── bounds: a flood of decisions ─────────────────────────────────────────────

#[tokio::test]
async fn the_65th_decision_on_a_host_evicts_the_oldest_and_its_text_with_it() {
    // The engine keeps at most 64 open decisions per host; past that the oldest
    // goes. An evicted decision is not waiting, so its ref answers with nothing.
    let mut rig = Rig::new().await;
    for i in 0..64 {
        rig.engine.ingest(
            Ask::new(PERSONAL, &format!("req-{i:02}")).frame(),
            t0() + secs(i),
        );
    }
    let before = rig.refs();
    assert_eq!(before.len(), 64);
    for item_ref in &before {
        assert_shows(&rig.detail(item_ref), DECISION_P);
    }

    rig.engine
        .ingest(Ask::new(PERSONAL, "req-64").frame(), t0() + secs(100));
    let after = rig.refs();
    assert_eq!(after.len(), 64, "the cap holds");

    let evicted: Vec<&String> = before.difference(&after).collect();
    assert_eq!(evicted.len(), 1, "exactly one decision was evicted");
    let r = rig.detail(evicted[0]);
    assert_not_waiting(&r, evicted[0], "the evicted decision");

    let added: Vec<&String> = after.difference(&before).collect();
    assert_eq!(added.len(), 1);
    assert_shows(&rig.detail(added[0]), DECISION_P);
    for item_ref in before.intersection(&after) {
        assert_shows(&rig.detail(item_ref), DECISION_P);
    }
}

#[tokio::test]
async fn decisions_on_one_host_are_not_evicted_by_a_flood_on_another() {
    let mut rig = Rig::new().await;
    rig.put(Kind::Decision, PERSONAL);
    let item_ref = rig.only_ref();
    for i in 0..70 {
        rig.engine.ingest(
            Ask::new(UNLISTED, &format!("flood-{i:02}")).frame(),
            t0() + secs(i),
        );
    }
    assert_shows(&rig.detail(&item_ref), DECISION_P);
}

// ── the relay never carries the text ─────────────────────────────────────────

#[tokio::test]
async fn the_text_never_travels_through_the_relay_and_asking_for_it_sends_nothing() {
    let mut rig = Rig::new().await;
    let t = t0();
    // A quiet start: the host seeded empty, the device's baseline taken.
    rig.engine.ingest(jobs_frame(Some(PERSONAL), vec![]), t);
    rig.engine.ingest(queue_frame(Some(PERSONAL), vec![]), t);
    rig.engine.step_at(t).await;

    rig.put(Kind::Decision, PERSONAL);
    rig.put(Kind::Mother, PERSONAL);
    rig.put(Kind::Review, PERSONAL);
    rig.engine.step_at(t).await;

    let wanted: BTreeSet<&str> = [MOTHER_Q, DECISION_P, PR_TITLE].into();
    let shown = |rig: &mut Rig| -> BTreeSet<String> {
        rig.refs()
            .iter()
            .map(|r| rig.detail(r).text.expect("text for a personal item"))
            .collect()
    };
    assert_eq!(
        shown(&mut rig)
            .iter()
            .map(String::as_str)
            .collect::<BTreeSet<_>>(),
        wanted,
        "the phone can read all three lines"
    );

    let before = rig
        .relay
        .received_requests()
        .await
        .unwrap_or_default()
        .len();
    let _ = shown(&mut rig);
    let after = rig
        .relay
        .received_requests()
        .await
        .unwrap_or_default()
        .len();
    assert_eq!(before, after, "asking for detail makes no relay request");

    // Let everything that is due be pushed.
    rig.engine.step_at(t + secs(30)).await;
    rig.engine.step_at(t + secs(120)).await;
    let bodies: Vec<String> = rig
        .relay
        .received_requests()
        .await
        .unwrap_or_default()
        .iter()
        .map(|r| String::from_utf8_lossy(&r.body).into_owned())
        .collect();
    assert!(!bodies.is_empty(), "something was pushed");
    for body in &bodies {
        for line in &wanted {
            assert!(!body.contains(line), "{line} reached the relay: {body}");
        }
        assert!(!body.contains(MARKER), "{body}");
    }
}
