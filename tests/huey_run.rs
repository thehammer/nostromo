//! Behavioural tests for Huey H4: the daily run (schedule, window, ledger,
//! budget mode, curated and uncurated reports, footer, missing-report
//! documents, hard-ignore, retention).
//!
//! Everything is driven from the outside: a `sources.toml` that points at a
//! local wiremock server (Atom feeds generated per test, with controlled
//! dates, ids and titles), a temp directory for the whole machine (home, code
//! root, state root), a `FakeClock` and a scripted curator standing in for
//! the model. Nothing here touches the real `$HOME`, `~/.claude`,
//! `~/.nostromo`, `~/.mother` or any network but the local mock server.
//!
//! Test names start with the acceptance criterion they pin (`h4_3_` ...).
//! Fixtures (interests files) live under `tests/fixtures/huey/runs/` and hold
//! nothing private.
//!
//! H5's validator does not exist yet, so the scripted curator only ever
//! returns publishes that are already valid (ids taken from the input it was
//! handed). Where a test feeds a publish a validator would reject (a drop of
//! a picked item), it pins what H4 itself guarantees about the rendered
//! report.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};
use serde_json::json;
use wiremock::matchers::{any, method, path_regex};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

use nostromo::huey::budget::{self, Mode};
use nostromo::huey::context::ContextEnv;
use nostromo::huey::interests::Interests;
use nostromo::huey::items::{NewsItem, SourceClass};
use nostromo::huey::paths::HueyPaths;
use nostromo::huey::render::{self, Report};
use nostromo::huey::run::{
    self, CurateError, CurateInput, Curator, NoLive, Publish, PublishAin, PublishCheck,
    PublishDrop, PublishNoted, PublishPick, RunEnv,
};
use nostromo::huey::schedule::FixedLocalTime;
use nostromo::huey::setup::{self, SetupRecord};
use nostromo::huey::sources::{
    load_pool, FetchOutcome, HttpClient, HttpLimits, SourceOutcome, SourceStatus,
};
use nostromo::huey::store::{Ledger, LedgerEntry, Section, Store, Verdict, VerdictKind};
use nostromo::huey::{
    FailReason, HueyConfig, HueyDeps, HueyDocument, HueyEngine, HueySources, MissingReason,
    RunOutcome, SetupState, Trigger, TriggerRefused,
};
use nostromo::tracker::clock::{Clock, FakeClock};

// ── Time ─────────────────────────────────────────────────────────────────────

fn ts(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

fn oct(day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, day).unwrap()
}

fn hours(n: i64) -> chrono::Duration {
    chrono::Duration::hours(n)
}

fn days(n: i64) -> chrono::Duration {
    chrono::Duration::days(n)
}

/// The usual "now" of a single-run test: Monday, Oct 26, 2026, a few minutes
/// after the 06:00 start.
const MONDAY: &str = "2026-10-26T06:05:00Z";

// ── Sources ──────────────────────────────────────────────────────────────────

/// `(id, name, class)` of one feed source.
type Src = (&'static str, &'static str, &'static str);

const VN: &str = "vendor-news";
const VENDOR: Src = (VN, "Vendor News", "first_party");
const DOCS: Src = ("vendor-docs", "Vendor Docs", "first_party");
const BLOG: Src = ("blog", "Practical Blog", "curated");
const FORUM: Src = ("forum", "Link Forum", "aggregator");
const BROKEN: Src = ("broken", "Broken Feed", "curated");
const ANTHROPIC: Src = ("anthropic-news", "Anthropic News", "first_party");
const NOTES: Src = (
    "claude-docs-release-notes",
    "Claude Docs Release Notes",
    "first_party",
);
const CHANGELOG: Src = (
    "claude-code-changelog",
    "Claude Code Changelog",
    "first_party",
);

/// An item id as the sources issue it: `<source id>:<native key>`. The tests
/// choose the native keys, so they know the ids in advance.
fn id(source: &str, key: &str) -> String {
    format!("{source}:{key}")
}

#[derive(Clone)]
struct Entry {
    key: String,
    title: String,
    at: DateTime<Utc>,
    body: String,
}

#[derive(Clone)]
enum Feed {
    Entries(Vec<Entry>),
    Status(u16),
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn atom(source: &str, entries: &[Entry]) -> String {
    let mut out = String::from(
        r#"<?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Test feed</title><id>urn:test-feed</id><updated>2026-01-01T00:00:00Z</updated>"#,
    );
    for e in entries {
        out.push_str(&format!(
            r#"<entry><id>{key}</id><title>{title}</title><updated>{at}</updated><link rel="alternate" href="https://{source}.example.test/{key}"/><summary>{body}</summary></entry>"#,
            key = e.key,
            title = xml(&e.title),
            at = e.at.to_rfc3339_opts(SecondsFormat::Secs, true),
            body = xml(&e.body),
        ));
    }
    out.push_str("</feed>");
    out
}

/// The mock server's answers: one feed (or one failure status) per source id.
#[derive(Default)]
struct Site {
    feeds: Mutex<BTreeMap<String, Feed>>,
}

impl Site {
    fn respond(&self, request_path: &str) -> ResponseTemplate {
        let source = request_path.trim_start_matches("/feed/");
        match self.feeds.lock().unwrap().get(source) {
            Some(Feed::Entries(entries)) => ResponseTemplate::new(200)
                .set_body_raw(atom(source, entries), "application/atom+xml"),
            Some(Feed::Status(code)) => ResponseTemplate::new(*code),
            None => ResponseTemplate::new(404),
        }
    }
}

// ── The machine ──────────────────────────────────────────────────────────────

struct World {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    code_root: PathBuf,
    state_root: PathBuf,
    paths: HueyPaths,
    server: MockServer,
    site: Arc<Site>,
    clock: Arc<FakeClock>,
}

/// A machine whose clock reads `start`, with a mock server that answers the
/// feeds registered through [`World::items`].
async fn world(start: &str) -> World {
    let w = bare_world(start).await;
    let site = w.site.clone();
    Mock::given(method("GET"))
        .and(path_regex("^/feed/"))
        .respond_with(move |req: &Request| site.respond(req.url.path()))
        .mount(&w.server)
        .await;
    w
}

/// Like [`world`], but the mock server fails the test if anything at all
/// calls it.
async fn silent_world(start: &str) -> World {
    let w = bare_world(start).await;
    Mock::given(any())
        .respond_with(ResponseTemplate::new(500))
        .expect(0)
        .mount(&w.server)
        .await;
    w
}

async fn bare_world(start: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let home = root.join("home");
    let code_root = root.join("code");
    let state_root = root.join("state");
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(&code_root).unwrap();
    fs::create_dir_all(&state_root).unwrap();
    World {
        paths: HueyPaths::new(&state_root),
        _tmp: tmp,
        home,
        code_root,
        state_root,
        server: MockServer::start().await,
        site: Arc::new(Site::default()),
        clock: Arc::new(FakeClock::new(ts(start))),
    }
}

fn client() -> HttpClient {
    HttpClient::new(
        HttpLimits {
            per_source: Duration::from_secs(5),
            overall: Duration::from_secs(10),
            body_cap: 1024 * 1024,
        },
        None,
    )
}

impl World {
    fn now(&self) -> DateTime<Utc> {
        self.clock.now()
    }

    fn store(&self) -> Store {
        Store::new(self.paths.clone())
    }

    fn context(&self) -> ContextEnv {
        ContextEnv::for_home(
            &self.home,
            self.code_root.clone(),
            self.state_root.clone(),
            "Testbox".into(),
        )
    }

    /// `sources.toml`, pointing every source at the mock server.
    fn sources(&self, defs: &[Src]) {
        let mut text = String::new();
        for (source, name, class) in defs {
            text.push_str(&format!(
                "[[source]]\nid = \"{source}\"\nname = \"{name}\"\nkind = \"feed\"\nclass = \"{class}\"\nurl = \"{}/feed/{source}\"\n\n",
                self.server.uri()
            ));
        }
        fs::create_dir_all(self.paths.root()).unwrap();
        fs::write(self.paths.sources_toml(), text).unwrap();
    }

    /// What pressing "confirm" in the setup pane leaves behind.
    fn confirm(&self) {
        setup::save(
            &self.paths,
            &SetupRecord {
                state: SetupState::Confirmed,
                confirmed_at: Some("2026-10-01T00:00:00Z".into()),
                scanned_at: Some("2026-10-01T00:00:00Z".into()),
            },
        )
        .unwrap();
    }

    /// Add entries to a source's feed (creating it, or recovering it from a
    /// failure).
    fn items(&self, source: &str, entries: &[(&str, &str, DateTime<Utc>)]) {
        for (key, title, at) in entries {
            self.item_with_body(source, key, title, *at, "");
        }
    }

    fn item_with_body(&self, source: &str, key: &str, title: &str, at: DateTime<Utc>, body: &str) {
        let mut feeds = self.site.feeds.lock().unwrap();
        let feed = feeds
            .entry(source.to_string())
            .or_insert_with(|| Feed::Entries(Vec::new()));
        if !matches!(feed, Feed::Entries(_)) {
            *feed = Feed::Entries(Vec::new());
        }
        if let Feed::Entries(list) = feed {
            list.push(Entry {
                key: key.into(),
                title: title.into(),
                at,
                body: body.into(),
            });
        }
    }

    /// A valid feed with nothing in it.
    fn empty_feed(&self, source: &str) {
        self.site
            .feeds
            .lock()
            .unwrap()
            .insert(source.into(), Feed::Entries(Vec::new()));
    }

    fn fail_source(&self, source: &str, status: u16) {
        self.site
            .feeds
            .lock()
            .unwrap()
            .insert(source.into(), Feed::Status(status));
    }

    async fn requests(&self) -> Vec<Request> {
        self.server.received_requests().await.unwrap_or_default()
    }

    /// Bishop's file, written a little before the clock's "now".
    fn posture(&self, word: &str) {
        self.posture_json(json!({"ts": (self.now() - hours(1)).to_rfc3339(), "posture": word}));
    }

    fn posture_json(&self, value: serde_json::Value) {
        fs::write(
            self.home.join(".claude/budget-posture.json"),
            value.to_string(),
        )
        .unwrap();
    }

    fn interests(&self, text: &str) {
        fs::create_dir_all(self.paths.root()).unwrap();
        fs::write(self.paths.interests(), text).unwrap();
    }

    fn run_env(&self, curator: Arc<dyn Curator>) -> RunEnv {
        RunEnv {
            paths: self.paths.clone(),
            config: HueyConfig::default(),
            context: self.context(),
            http: client(),
            curator,
            live: Arc::new(NoLive),
            clock: self.clock.clone(),
            local_time: Arc::new(FixedLocalTime::utc()),
        }
    }

    async fn run(&self, curator: &Arc<Scripted>, trigger: Trigger) -> RunOutcome {
        run::run(&self.run_env(curator.clone()), trigger, None).await
    }

    /// Run one attempt and return the report it produced.
    async fn run_report(&self, curator: &Arc<Scripted>, trigger: Trigger) -> Report {
        let (date, version, _) = produced(&self.run(curator, trigger).await);
        self.report(date, version)
    }

    fn report(&self, date: NaiveDate, version: u32) -> Report {
        self.store()
            .load_report(date, version)
            .unwrap_or_else(|| panic!("no report for {date} v{version}"))
    }

    fn deps(&self, curator: Arc<dyn Curator>, tick: Duration) -> HueyDeps {
        HueyDeps {
            clock: self.clock.clone(),
            tick,
            http: client(),
            curator,
            local_time: Arc::new(FixedLocalTime::utc()),
            ..HueyDeps::new(
                self.state_root.clone(),
                HueyConfig::default(),
                self.context(),
            )
        }
    }
}

/// A project in flight: a git repository under the code root with a commit at `when`.
fn make_project(code_root: &Path, name: &str, files: &[(&str, &str)], when: DateTime<Utc>) {
    let dir = code_root.join(name);
    for (file, body) in files {
        let path = dir.join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }
    git(&dir, &["-c", "init.defaultBranch=main", "init", "-q"], when);
    git(&dir, &["add", "-A"], when);
    git(&dir, &["commit", "-q", "-m", "Initial import"], when);
}

fn git(dir: &Path, args: &[&str], when: DateTime<Utc>) {
    let when = when.to_rfc3339_opts(SecondsFormat::Secs, true);
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "Fixture Author")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "Fixture Author")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .env("GIT_AUTHOR_DATE", &when)
        .env("GIT_COMMITTER_DATE", &when)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git must be installed");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn fixture(name: &str) -> String {
    let p = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/huey")
        .join(name);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("fixture {}: {e}", p.display()))
}

/// Every file under `dir` with its bytes, and every directory, by relative path.
fn snapshot(dir: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeMap<String, Option<Vec<u8>>>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let rel = path
                .strip_prefix(base)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            if entry.file_type().unwrap().is_dir() {
                out.insert(rel, None);
                walk(base, &path, out);
            } else {
                out.insert(rel, Some(fs::read(&path).unwrap()));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

async fn wait_for(what: &str, mut condition: impl FnMut() -> bool) {
    for _ in 0..1000 {
        if condition() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out waiting for {what}");
}

fn produced(outcome: &RunOutcome) -> (NaiveDate, u32, Mode) {
    match outcome {
        RunOutcome::Produced {
            date,
            version,
            mode,
        } => (*date, *version, *mode),
        other => panic!("expected a report, got {other:?}"),
    }
}

// ── The scripted model ───────────────────────────────────────────────────────

type Script = Box<dyn Fn(&CurateInput) -> Result<Publish, CurateError> + Send + Sync>;

/// A curator whose answer is a closure over the input it was handed, which
/// keeps every input for the test to read.
struct Scripted {
    script: Script,
    seen: Mutex<Vec<CurateInput>>,
}

impl Scripted {
    fn new<F>(script: F) -> Arc<Self>
    where
        F: Fn(&CurateInput) -> Result<Publish, CurateError> + Send + Sync + 'static,
    {
        Arc::new(Self {
            script: Box::new(script),
            seen: Mutex::new(Vec::new()),
        })
    }

    /// Picks the `picks` newest candidates, adds an Also-in-the-news line if
    /// `ain`, and otherwise says nothing.
    fn picking(picks: usize, ain: bool) -> Arc<Self> {
        Self::new(move |input| Ok(publish(input, picks, ain)))
    }

    fn failing() -> Arc<Self> {
        Self::new(|_| Err(CurateError::Failed("the model is not answering".into())))
    }

    fn calls(&self) -> usize {
        self.seen.lock().unwrap().len()
    }

    fn inputs(&self) -> Vec<CurateInput> {
        self.seen.lock().unwrap().clone()
    }

    fn last(&self) -> CurateInput {
        self.inputs().pop().expect("the curator was never called")
    }
}

#[async_trait]
impl Curator for Scripted {
    async fn curate(&self, input: &CurateInput) -> Result<Publish, CurateError> {
        self.seen.lock().unwrap().push(input.clone());
        (self.script)(input)
    }
}

fn pick(item_id: &str, n: usize) -> PublishPick {
    PublishPick {
        item_ids: vec![item_id.to_string()],
        headline: format!("Pick {n}"),
        what_happened: "A thing happened.".into(),
        project: "general".into(),
        for_line: "Worth a look.".into(),
        anchors: Vec::new(),
        check: PublishCheck::ToCheck {
            text: "Read the notes.".into(),
        },
        follow_up_of: None,
        whats_new: None,
    }
}

fn ain_line(item_id: &str) -> PublishAin {
    PublishAin {
        item_id: item_id.to_string(),
        headline: "Vendor ships an update".into(),
        what_happened: "A first-party update landed.".into(),
    }
}

fn drop_of(item_id: &str, reason: &str) -> PublishDrop {
    PublishDrop {
        item_id: item_id.to_string(),
        reason: reason.to_string(),
    }
}

/// A valid publish over `input`: the `picks` first candidates, and (if `ain`)
/// the first Also-in-the-news candidate that is not a pick, or the reason
/// there is none.
fn publish(input: &CurateInput, picks: usize, ain: bool) -> Publish {
    let chosen: Vec<PublishPick> = input
        .candidates
        .iter()
        .take(picks)
        .enumerate()
        .map(|(n, c)| pick(&c.primary().id, n + 1))
        .collect();
    let taken: BTreeSet<&str> = chosen
        .iter()
        .flat_map(|p| p.item_ids.iter().map(String::as_str))
        .collect();
    let ain_item = ain
        .then(|| {
            input
                .ain_candidates
                .iter()
                .find(|i| !taken.contains(i.id.as_str()))
        })
        .flatten();
    Publish {
        opener_gist: "A short morning.".into(),
        also_in_the_news: ain_item.map(|i| ain_line(&i.id)),
        ain_skip_reason: (ain && ain_item.is_none())
            .then(|| "nothing new that is not already picked".to_string()),
        picks: chosen,
        ..Publish::default()
    }
}

/// A publish that fills every section the input allows, and then some: the
/// model "disobeys" `also_noted: false` so H4's own handling shows.
fn publish_full(input: &CurateInput) -> Publish {
    let picks: Vec<PublishPick> = input
        .candidates
        .iter()
        .take(input.max_picks)
        .enumerate()
        .map(|(n, c)| pick(&c.primary().id, n + 1))
        .collect();
    let mut taken: BTreeSet<String> = picks.iter().flat_map(|p| p.item_ids.clone()).collect();
    let also_noted: Vec<PublishNoted> = input
        .candidates
        .iter()
        .skip(input.max_picks)
        .take(1)
        .map(|c| PublishNoted {
            item_ids: vec![c.primary().id.clone()],
            line: "A smaller thing worth a glance.".into(),
            interest: "i1".into(),
        })
        .collect();
    taken.extend(also_noted.iter().flat_map(|n| n.item_ids.clone()));
    let ain = input
        .ain_candidates
        .iter()
        .find(|i| !taken.contains(&i.id))
        .map(|i| ain_line(&i.id));
    Publish {
        opener_gist: "A short morning.".into(),
        picks,
        also_in_the_news: ain,
        also_noted,
        ..Publish::default()
    }
}

fn candidate_ids(input: &CurateInput) -> BTreeSet<String> {
    input
        .candidates
        .iter()
        .flat_map(|c| c.items.iter().map(|i| i.id.clone()))
        .collect()
}

fn ain_ids(input: &CurateInput) -> BTreeSet<String> {
    input.ain_candidates.iter().map(|i| i.id.clone()).collect()
}

fn set(ids: &[String]) -> BTreeSet<String> {
    ids.iter().cloned().collect()
}

/// The id of the item the run fetched with this exact title.
fn id_of(input: &CurateInput, title: &str) -> String {
    input
        .frame
        .items
        .values()
        .find(|i| i.title == title)
        .map(|i| i.id.clone())
        .unwrap_or_else(|| panic!("no item titled {title:?}"))
}

/// The ids of the items the day's fetch found inside the window (the frozen
/// daily pool), before the ledger and the ignore terms are applied.
fn fetched_ids(w: &World, date: NaiveDate) -> BTreeSet<String> {
    load_pool(&w.paths.pool_dir(), date)
        .expect("the day's pool")
        .items
        .into_iter()
        .map(|i| i.id)
        .collect()
}

/// What every report must satisfy: no item in two places, and a footer of at
/// most 100 words.
fn assert_sane(report: &Report) {
    let shown = report.shown_ids();
    let unique: BTreeSet<&&str> = shown.iter().collect();
    assert_eq!(
        shown.len(),
        unique.len(),
        "an item appears in two places: {shown:?}"
    );
    let footer = render::footer_text(&report.footer);
    assert!(render::words(&footer) <= 100, "footer too long: {footer}");
    assert!(render::word_counts(report).footer <= 100);
}

fn news(source: &str, key: &str, class: SourceClass, title: &str, at: DateTime<Utc>) -> NewsItem {
    NewsItem {
        id: id(source, key),
        source_id: source.into(),
        class,
        title: title.into(),
        url: format!("https://{source}.example.test/{key}"),
        canonical_url: format!("https://{source}.example.test/{key}"),
        published_at: Some(at),
        first_seen_at: at,
        text: String::new(),
        outbound_links: Vec::new(),
    }
}

fn ledger_entry(item_id: &str, date: NaiveDate, section: Section) -> LedgerEntry {
    LedgerEntry {
        item_id: item_id.into(),
        canonical_url: format!("https://example.test/{item_id}"),
        date,
        version: 1,
        section,
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-1: not set up, nothing happens
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_1_not_set_up_does_nothing_past_run_time() {
    let w = silent_world("2026-10-26T05:00:00Z").await;
    let curator = Scripted::picking(1, false);
    let src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    // Before setup.start was ever pressed: no setup.json at all.
    w.clock.set(ts("2026-10-26T09:00:00Z"));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
    assert_eq!(
        fs::read_dir(&w.state_root).unwrap().count(),
        0,
        "the state root must stay empty"
    );

    // After setup.start: scanned, not confirmed.
    setup::save(
        &w.paths,
        &SetupRecord {
            state: SetupState::NotSetUp,
            confirmed_at: None,
            scanned_at: Some("2026-10-26T08:00:00Z".into()),
        },
    )
    .unwrap();
    w.sources(&[VENDOR]);
    let before = snapshot(w.paths.root());
    w.clock.set(ts("2026-10-27T09:00:00Z"));
    tokio::time::sleep(Duration::from_millis(200)).await;
    w.clock.set(ts("2026-10-28T06:00:00Z"));
    tokio::time::sleep(Duration::from_millis(200)).await;

    assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
    assert_eq!(snapshot(w.paths.root()), before, "nothing written");
    assert_eq!(curator.calls(), 0);
    assert!(w.requests().await.is_empty(), "no HTTP request");
    assert!(w.store().dates().is_empty());
    assert!(w.store().runs().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-2: the schedule
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_2_the_run_starts_at_six_local_and_the_report_is_ready_before_half_past() {
    let w = world("2026-10-26T05:59:30Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T04:00:00Z"),
        )],
    );
    let curator = Scripted::picking(1, false);
    let _src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    // 05:59: not yet.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(curator.calls(), 0);
    assert!(w.requests().await.is_empty(), "no fetch before 06:00");
    assert!(w.store().dates().is_empty());

    // 06:00: the run starts and finishes well before the 06:30 ready-by time.
    w.clock.set(ts("2026-10-26T06:00:00Z"));
    let store = w.store();
    wait_for("the 06:00 run", || store.latest_version(oct(26)).is_some()).await;

    let meta = store.load_meta(oct(26), 1).unwrap();
    assert_eq!(meta.generated_at, ts("2026-10-26T06:00:00Z"));
    assert!(meta.generated_at < ts("2026-10-26T06:30:00Z"));
    assert_eq!(meta.trigger, Trigger::Scheduled);
    assert_eq!(meta.late_reason, None);
    assert_eq!(curator.calls(), 1);

    // One report per day: the scheduler does not run again.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(curator.calls(), 1);
    assert_eq!(store.versions(oct(26)), vec![1]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_2_started_at_nine_with_no_report_it_runs_at_once_and_says_why_it_was_late() {
    let w = world("2026-10-26T09:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T04:00:00Z"),
        )],
    );
    let curator = Scripted::picking(1, false);
    let _src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    let store = w.store();
    wait_for("the catch-up run", || {
        store.latest_version(oct(26)).is_some()
    })
    .await;

    let meta = store.load_meta(oct(26), 1).unwrap();
    assert_eq!(meta.generated_at, ts("2026-10-26T09:00:00Z"));
    assert_eq!(meta.trigger, Trigger::CatchUp);
    assert_eq!(
        meta.late_reason.as_deref(),
        Some("machine asleep or daemon not running at 06:00")
    );
    let raw = fs::read_to_string(store.report_dir(oct(26), 1).join("meta.json")).unwrap();
    assert!(
        raw.contains("machine asleep or daemon not running at 06:00"),
        "meta.json carries the late reason"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_2_a_model_failure_is_retried_once_ten_minutes_later() {
    let w = world("2026-10-26T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T04:00:00Z"),
        )],
    );
    let attempts = Arc::new(AtomicUsize::new(0));
    let counter = attempts.clone();
    let curator = Scripted::new(move |input| {
        if counter.fetch_add(1, Ordering::SeqCst) == 0 {
            Err(CurateError::Failed("first attempt fails".into()))
        } else {
            Ok(publish(input, 1, false))
        }
    });
    let _src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    wait_for("the first attempt", || curator.calls() == 1).await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(w.store().dates().is_empty(), "the first attempt failed");

    // Nine minutes in: too early for the retry.
    w.clock.set(ts("2026-10-26T06:09:00Z"));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(curator.calls(), 1);

    // Ten minutes in: the retry runs and produces the report.
    w.clock.set(ts("2026-10-26T06:10:00Z"));
    let store = w.store();
    wait_for("the retry", || store.latest_version(oct(26)).is_some()).await;
    assert_eq!(curator.calls(), 2);
    assert_eq!(store.load_meta(oct(26), 1).unwrap().trigger, Trigger::Retry);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_2_a_failed_retry_is_not_retried_again() {
    let w = world("2026-10-26T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T04:00:00Z"),
        )],
    );
    let curator = Scripted::failing();
    let _src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    wait_for("the first attempt", || curator.calls() == 1).await;
    w.clock.set(ts("2026-10-26T06:10:00Z"));
    wait_for("the retry", || curator.calls() == 2).await;
    w.clock.set(ts("2026-10-26T08:00:00Z"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(curator.calls(), 2, "one retry, no more");
    assert!(w.store().dates().is_empty());
}

#[tokio::test]
async fn h4_2_a_run_persists_report_files_ledger_and_run_log() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[
            ("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(5)),
            (
                "gizmo-sdk",
                "Gizmo SDK adds retry helpers",
                w.now() - hours(4),
            ),
            ("note-1", "Gizmo release note 1", w.now() - hours(3)),
            ("note-2", "Gizmo release note 2", w.now() - hours(2)),
        ],
    );
    let curator = Scripted::new(publish_full_one_each);
    let (date, version, mode) = produced(&w.run(&curator, Trigger::Scheduled).await);
    assert_eq!((date, version, mode), (oct(26), 1, Mode::Normal));

    let dir = w.store().report_dir(oct(26), 1);
    assert!(dir.ends_with("reports/2026-10-26/v1"), "{dir:?}");
    for file in ["meta.json", "report.json", "report.md", "digest.md"] {
        assert!(dir.join(file).is_file(), "missing {file}");
    }
    assert!(w.paths.state_dir().join("ledger.json").is_file());
    assert!(w.paths.state_dir().join("runs.jsonl").is_file());

    // The digest on disk is the model's input record.
    let input = curator.last();
    assert_eq!(w.store().load_digest(oct(26), 1), Some(input.digest.text));
    // The markdown on disk is the rendered report.
    let report = w.report(oct(26), 1);
    assert_eq!(
        w.store().load_markdown(oct(26), 1),
        Some(render::render_markdown(&report))
    );

    // The ledger records each shown item under its section.
    let ledger = w.store().ledger();
    let section_of = |item: &str| {
        ledger
            .entries
            .iter()
            .find(|e| e.item_id == item)
            .map(|e| (e.section, e.date, e.version))
    };
    assert_eq!(
        section_of(&id(VN, "gizmo-2")),
        Some((Section::Pick, oct(26), 1))
    );
    assert_eq!(
        section_of(&id(VN, "note-2")).map(|(s, _, _)| s),
        Some(Section::Ain)
    );
    assert_eq!(
        section_of(&id(VN, "note-1")).map(|(s, _, _)| s),
        Some(Section::AlsoNoted)
    );

    // The run log has the attempt.
    let runs = w.store().runs();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].date, oct(26));
    assert_eq!(runs[0].trigger, Trigger::Scheduled);
    assert_eq!(runs[0].version, Some(1));
    assert_eq!(runs[0].mode, Some(Mode::Normal));
    assert_sane(&report);
}

/// Two picks, one Also noted line and the news line, all by title.
fn publish_full_one_each(input: &CurateInput) -> Result<Publish, CurateError> {
    let by_title = |title: &str| id_of(input, title);
    Ok(Publish {
        opener_gist: "A short morning.".into(),
        picks: vec![
            pick(&by_title("Gizmo 2 ships batch mode"), 1),
            pick(&by_title("Gizmo SDK adds retry helpers"), 2),
        ],
        also_in_the_news: Some(ain_line(&by_title("Gizmo release note 2"))),
        also_noted: vec![PublishNoted {
            item_ids: vec![by_title("Gizmo release note 1")],
            line: "A smaller thing worth a glance.".into(),
            interest: "i1".into(),
        }],
        ..Publish::default()
    })
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-3: the window
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_3_window_starts_at_the_last_curated_report() {
    let w = world("2026-10-21T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("before", "Gizmo 1 notes", ts("2026-10-20T12:00:00Z"))],
    );
    let curator = Scripted::picking(5, false);
    produced(&w.run(&curator, Trigger::Scheduled).await);

    // Three days of news pile up while no report is made on the 22nd and 23rd.
    w.items(
        VN,
        &[
            (
                "day-1",
                "Gizmo news from the first day",
                ts("2026-10-21T12:00:00Z"),
            ),
            (
                "day-2",
                "Gizmo news from the second day",
                ts("2026-10-22T12:00:00Z"),
            ),
            (
                "day-3",
                "Gizmo news from the third day",
                ts("2026-10-23T12:00:00Z"),
            ),
        ],
    );
    w.clock.set(ts("2026-10-24T06:00:00Z"));
    produced(&w.run(&curator, Trigger::Scheduled).await);

    let input = curator.last();
    assert_eq!(
        candidate_ids(&input),
        set(&[id(VN, "day-1"), id(VN, "day-2"), id(VN, "day-3")]),
        "all three days are candidates, and nothing from before the last report"
    );
    let meta = w.store().load_meta(oct(24), 1).unwrap();
    assert_eq!(meta.window_start, ts("2026-10-21T06:00:00Z"));
    assert_eq!(w.store().dates(), vec![oct(24), oct(21)]);
}

#[tokio::test]
async fn h4_3_a_critical_report_in_between_does_not_move_the_window() {
    let w = world("2026-10-21T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(VN, &[("seed", "Gizmo 1 notes", ts("2026-10-20T12:00:00Z"))]);
    let curator = Scripted::picking(5, false);

    // Day 1: a normal, curated report.
    w.posture("Cruise");
    let day1 = w.run_report(&curator, Trigger::Scheduled).await;
    assert_eq!(day1.mode, Mode::Normal);

    // Day 2: critical. News from day 1's afternoon is listed without a model.
    w.items(
        VN,
        &[(
            "iota",
            "Gizmo news from the afternoon",
            ts("2026-10-21T12:00:00Z"),
        )],
    );
    w.clock.set(ts("2026-10-22T06:00:00Z"));
    w.posture("critical");
    let day2 = w.run_report(&curator, Trigger::Scheduled).await;
    assert_eq!(day2.mode, Mode::Critical);
    assert_eq!(curator.calls(), 1, "no model ran on the critical day");

    // Day 3: normal again. Its window still starts at day 1's report, so it
    // covers both days of news.
    w.items(
        VN,
        &[(
            "kappa",
            "Gizmo news from day two",
            ts("2026-10-22T12:00:00Z"),
        )],
    );
    w.clock.set(ts("2026-10-23T06:00:00Z"));
    w.posture("Cruise");
    produced(&w.run(&curator, Trigger::Scheduled).await);

    let input = curator.last();
    assert_eq!(
        candidate_ids(&input),
        set(&[id(VN, "iota"), id(VN, "kappa")]),
        "the critical day did not use up day 1's news"
    );
    let meta = w.store().load_meta(oct(23), 1).unwrap();
    assert_eq!(meta.window_start, ts("2026-10-21T06:00:00Z"));
    let critical_meta = w.store().load_meta(oct(22), 1).unwrap();
    assert_eq!(critical_meta.mode, Mode::Critical);
    assert_eq!(critical_meta.window_start, ts("2026-10-21T06:00:00Z"));
    assert_eq!(critical_meta.model, None);
}

#[tokio::test]
async fn h4_3_the_first_run_ever_looks_back_seven_days() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[
            (
                "six-days",
                "Gizmo news from six days ago",
                w.now() - days(6),
            ),
            (
                "eight-days",
                "Gizmo news from eight days ago",
                w.now() - days(8),
            ),
        ],
    );
    let curator = Scripted::picking(5, false);
    produced(&w.run(&curator, Trigger::Scheduled).await);

    assert_eq!(candidate_ids(&curator.last()), set(&[id(VN, "six-days")]));
    let meta = w.store().load_meta(oct(26), 1).unwrap();
    assert_eq!(meta.window_start, w.now() - days(7));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-4: the 14-day ledger
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_4_an_item_shown_on_day_one_is_not_a_candidate_on_day_two() {
    let w = world("2026-10-01T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    // Dated later on day 1, so day 2's window still contains it.
    w.items(
        VN,
        &[("gizmo-3", "Gizmo 3 ships", ts("2026-10-01T20:00:00Z"))],
    );
    let curator = Scripted::picking(5, false);
    produced(&w.run(&curator, Trigger::Scheduled).await);
    assert_eq!(candidate_ids(&curator.last()), set(&[id(VN, "gizmo-3")]));

    w.clock.set(ts("2026-10-02T06:00:00Z"));
    produced(&w.run(&curator, Trigger::Scheduled).await);
    assert!(
        fetched_ids(&w, oct(2)).contains(&id(VN, "gizmo-3")),
        "the item is inside day 2's window, so only the ledger keeps it out"
    );
    assert!(
        candidate_ids(&curator.last()).is_empty(),
        "shown yesterday, so not a candidate again"
    );
}

#[tokio::test]
async fn h4_4_a_new_version_of_the_same_product_is_a_candidate_on_day_two() {
    let w = world("2026-10-01T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-3-0", "Gizmo 3.0 ships", ts("2026-10-01T20:00:00Z"))],
    );
    let curator = Scripted::picking(5, false);
    produced(&w.run(&curator, Trigger::Scheduled).await);

    w.items(
        VN,
        &[("gizmo-3-1", "Gizmo 3.1 ships", ts("2026-10-02T03:00:00Z"))],
    );
    w.clock.set(ts("2026-10-02T06:00:00Z"));
    produced(&w.run(&curator, Trigger::Scheduled).await);
    assert_eq!(
        candidate_ids(&curator.last()),
        set(&[id(VN, "gizmo-3-1")]),
        "the new version has a new item id; the shown one stays out"
    );
}

#[tokio::test]
async fn h4_4_a_shown_item_stays_out_through_day_fourteen_and_is_back_on_day_fifteen() {
    let w = world("2026-10-01T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-3", "Gizmo 3 ships", ts("2026-10-01T20:00:00Z"))],
    );
    let curator = Scripted::picking(5, false);
    produced(&w.run(&curator, Trigger::Scheduled).await);

    // Critical days never move the window, so the item stays inside it all
    // fortnight and only the ledger keeps it out.
    for day in 2..=15u32 {
        w.clock.set(ts(&format!("2026-10-{day:02}T06:00:00Z")));
        w.posture("critical");
        let report = w.run_report(&curator, Trigger::Scheduled).await;
        assert_eq!(report.mode, Mode::Critical);
        assert!(
            fetched_ids(&w, oct(day)).contains(&id(VN, "gizmo-3")),
            "day {day}: the item is inside the window"
        );
        let listed: Vec<&str> = report
            .uncurated
            .as_ref()
            .expect("critical reports list headlines")
            .lines
            .iter()
            .map(|l| l.item_id.as_str())
            .collect();
        if day < 15 {
            assert!(listed.is_empty(), "day {day} listed {listed:?}");
        } else {
            assert_eq!(listed, vec![id(VN, "gizmo-3")], "day 15");
        }
    }
}

#[test]
fn h4_4_the_ledger_blocks_candidates_for_fourteen_days_and_uncurated_entries_only_block_the_ain_line(
) {
    let shown = news(
        VN,
        "gizmo-3",
        SourceClass::FirstParty,
        "Gizmo 3 ships",
        ts("2026-10-01T20:00:00Z"),
    );
    let fetched = FetchOutcome {
        items: vec![shown.clone()],
        recent: vec![shown.clone()],
        statuses: Vec::new(),
    };
    let none = Interests::default();

    let curated = Ledger {
        entries: vec![ledger_entry(&shown.id, oct(1), Section::Pick)],
    };
    for day in 2..=14 {
        let sel = run::select(&fetched, &none, &curated, oct(day));
        assert!(sel.candidates.is_empty(), "day {day} candidates");
        assert!(sel.ain_eligible.is_empty(), "day {day} Also in the news");
    }
    let day15 = run::select(&fetched, &none, &curated, oct(15));
    assert_eq!(day15.candidates.len(), 1, "day 15");
    assert_eq!(day15.ain_eligible.len(), 1, "day 15");

    // An uncurated listing never keeps an item out of picks.
    let uncurated = Ledger {
        entries: vec![ledger_entry(&shown.id, oct(1), Section::Uncurated)],
    };
    for day in 2..=14 {
        let sel = run::select(&fetched, &none, &uncurated, oct(day));
        assert_eq!(sel.candidates.len(), 1, "day {day} candidates");
        assert!(sel.ain_eligible.is_empty(), "day {day} Also in the news");
    }
    let day15 = run::select(&fetched, &none, &uncurated, oct(15));
    assert_eq!(day15.ain_eligible.len(), 1);
}

#[tokio::test]
async fn h4_4_an_uncurated_listing_does_not_block_pick_candidacy_but_does_block_the_ain_line() {
    let w = world("2026-10-01T06:00:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-3", "Gizmo 3 ships", ts("2026-10-01T03:00:00Z"))],
    );
    let curator = Scripted::picking(5, true);

    // Day 1 is critical: the item is listed without a model.
    w.posture("critical");
    let day1 = w.run_report(&curator, Trigger::Scheduled).await;
    assert_eq!(day1.mode, Mode::Critical);
    assert_eq!(
        w.store().ledger().entries.first().map(|e| e.section),
        Some(Section::Uncurated)
    );

    // Day 2 is normal: the item is still a pick candidate, but it cannot be
    // the Also-in-the-news line.
    w.items(
        VN,
        &[("gizmo-3-1", "Gizmo 3.1 ships", ts("2026-10-02T02:00:00Z"))],
    );
    w.clock.set(ts("2026-10-02T06:00:00Z"));
    w.posture("Cruise");
    produced(&w.run(&curator, Trigger::Scheduled).await);
    let input = curator.last();
    assert_eq!(
        candidate_ids(&input),
        set(&[id(VN, "gizmo-3"), id(VN, "gizmo-3-1")])
    );
    assert_eq!(ain_ids(&input), set(&[id(VN, "gizmo-3-1")]));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-5: the footer
// ═════════════════════════════════════════════════════════════════════════════

/// Sources for the footer tests: two first-party (one with news, one quiet),
/// a blog, an aggregator and a source that answers HTTP 500.
fn footer_world_sources(w: &World) {
    w.sources(&[VENDOR, DOCS, BLOG, BROKEN, FORUM]);
    w.confirm();
    make_project(
        &w.code_root,
        "orchard",
        &[("README.md", "# Orchard\n\nA small test project.\n")],
        w.now() - days(2),
    );
    w.interests(&fixture("runs/interests-ignore-php.md"));
    w.empty_feed(DOCS.0);
    w.fail_source(BROKEN.0, 500);
    w.items(
        BLOG.0,
        &[("blog-1", "Practical notes on batching", w.now() - hours(6))],
    );
    w.items(
        FORUM.0,
        &[("forum-1", "Link roundup about gizmos", w.now() - hours(7))],
    );
}

#[tokio::test]
async fn h4_5_the_footer_reports_sources_failures_projects_and_drops() {
    let w = world(MONDAY).await;
    footer_world_sources(&w);
    w.items(
        VN,
        &[
            ("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1)),
            (
                "gizmo-sdk",
                "Gizmo SDK adds retry helpers",
                w.now() - hours(2),
            ),
            (
                "php-9",
                "PHP 9 released with a new engine",
                w.now() - hours(3),
            ),
            ("n1", "Gizmo release note 1", w.now() - hours(4)),
            ("n2", "Gizmo release note 2", w.now() - hours(5)),
            ("n3", "Gizmo release note 3", w.now() - hours(6)),
            ("n4", "Gizmo release note 4", w.now() - hours(7)),
            ("n6", "Gizmo release note 6", w.now() - hours(9)),
        ],
    );
    let curator = Scripted::new(|input| {
        let by_title = |t: &str| id_of(input, t);
        Ok(Publish {
            opener_gist: "Two Gizmo releases to read.".into(),
            picks: vec![
                pick(&by_title("Gizmo 2 ships batch mode"), 1),
                pick(&by_title("Gizmo SDK adds retry helpers"), 2),
            ],
            also_in_the_news: Some(ain_line(&by_title("Gizmo release note 6"))),
            also_noted: vec![
                PublishNoted {
                    item_ids: vec![by_title("Gizmo release note 6")],
                    line: "The same item as the news line.".into(),
                    interest: "i1".into(),
                },
                PublishNoted {
                    item_ids: vec![by_title("Practical notes on batching")],
                    line: "Batching tips from the blog.".into(),
                    interest: "i1".into(),
                },
            ],
            dropped: vec![
                drop_of(&by_title("Gizmo release note 1"), "duplicate coverage"),
                drop_of(&by_title("Gizmo release note 2"), "duplicate coverage"),
                drop_of(&by_title("Gizmo release note 3"), "duplicate coverage"),
                drop_of(&by_title("Gizmo release note 4"), "duplicate coverage"),
                // Shown elsewhere in the report, so they can never be "dropped".
                drop_of(
                    &by_title("Gizmo 2 ships batch mode"),
                    "model dropped a pick",
                ),
                drop_of(
                    &by_title("Gizmo release note 6"),
                    "model dropped the news line",
                ),
            ],
            ..Publish::default()
        })
    });
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let footer = render::footer_text(&report.footer);

    // Counts and sources.
    assert!(
        footer.contains("Looked at 10 items from 4 sources."),
        "{footer}"
    );
    assert!(
        footer.contains("Read in full: Vendor News, Vendor Docs."),
        "{footer}"
    );
    assert!(footer.contains("No new items: Vendor Docs."), "{footer}");
    assert!(
        footer.contains("Failed: Broken Feed (HTTP 500)."),
        "{footer}"
    );
    assert!(footer.contains("In flight: orchard."), "{footer}");

    // Drops: model drops first, then the hard-ignore drop, never a shown item.
    let dropped: Vec<&str> = report
        .footer
        .dropped
        .iter()
        .map(|d| d.item_id.as_str())
        .collect();
    assert_eq!(
        dropped,
        vec![
            id(VN, "n1"),
            id(VN, "n2"),
            id(VN, "n3"),
            id(VN, "n4"),
            id(VN, "php-9"),
        ]
    );
    let first_model = footer.find("duplicate coverage").expect(&footer);
    let ignored = footer.find("ignored: PHP").expect(&footer);
    assert!(first_model < ignored, "model drops come first: {footer}");
    assert!(!footer.contains("Gizmo 2 ships batch mode"), "{footer}");
    assert!(!footer.contains("Gizmo release note 6"), "{footer}");
    let shown = report.shown_ids();
    assert!(report
        .footer
        .dropped
        .iter()
        .all(|d| !shown.contains(&d.item_id.as_str())));

    // The news line moved up out of Also noted; every item is in one place.
    assert_eq!(report.also_noted.len(), 1);
    assert_eq!(
        report.also_in_the_news.as_ref().map(|a| a.item_id.clone()),
        Some(id(VN, "n6"))
    );
    assert_sane(&report);
}

#[tokio::test]
async fn h4_5_the_footer_shows_at_most_five_drops_and_model_drops_come_first() {
    let w = world(MONDAY).await;
    footer_world_sources(&w);
    w.items(
        VN,
        &[
            ("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1)),
            (
                "php-9",
                "PHP 9 released with a new engine",
                w.now() - hours(2),
            ),
        ],
    );
    for n in 1..=8 {
        w.items(
            VN,
            &[(
                &format!("n{n}"),
                &format!("Gizmo release note {n}"),
                w.now() - hours(2 + n),
            )],
        );
    }
    let curator = Scripted::new(|input| {
        let mut p = publish(input, 0, false);
        p.picks = vec![pick(&id_of(input, "Gizmo 2 ships batch mode"), 1)];
        p.dropped = (1..=8)
            .map(|n| {
                drop_of(
                    &id_of(input, &format!("Gizmo release note {n}")),
                    "duplicate coverage",
                )
            })
            .collect();
        Ok(p)
    });
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let footer = render::footer_text(&report.footer);

    assert_eq!(footer.matches("duplicate coverage").count(), 5, "{footer}");
    assert!(
        !footer.contains("ignored: PHP"),
        "the hard-ignore drop comes after the model's five: {footer}"
    );
    assert!(footer.contains("Dropped:"), "{footer}");
    assert_sane(&report);
}

#[tokio::test]
async fn h4_5_a_run_with_no_projects_says_none_in_flight_and_no_failures() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    let curator = Scripted::picking(1, false);
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let footer = render::footer_text(&report.footer);
    assert!(
        footer.contains("Looked at 1 items from 1 sources."),
        "{footer}"
    );
    assert!(footer.contains("Read in full: Vendor News."), "{footer}");
    assert!(footer.contains("Failed: none."), "{footer}");
    assert!(footer.contains("In flight: none."), "{footer}");
    assert!(!footer.contains("Dropped:"), "{footer}");
    assert_sane(&report);
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-6: tight mode
// ═════════════════════════════════════════════════════════════════════════════

async fn tight_or_normal_world(posture: &str) -> World {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.posture(posture);
    for n in 1..=8 {
        w.items(
            VN,
            &[(
                &format!("n{n}"),
                &format!("Gizmo release note {n}"),
                w.now() - hours(n),
            )],
        );
    }
    w
}

#[tokio::test]
async fn h4_6_a_tight_run_asks_for_three_picks_and_no_also_noted_and_says_so() {
    let w = tight_or_normal_world("Pump the brakes").await;
    let curator = Scripted::new(|input| Ok(publish_full(input)));
    let outcome = w.run(&curator, Trigger::Scheduled).await;
    assert_eq!(produced(&outcome).2, Mode::Tight);

    let input = curator.last();
    assert_eq!(input.mode, Mode::Tight);
    assert_eq!(input.max_picks, 3);
    assert!(!input.also_noted);
    assert!(!input.ain_candidates.is_empty());

    let report = w.report(oct(26), 1);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert_eq!(report.mode, Mode::Tight);
    assert!(markdown.contains("Short report: budget is tight today."));
    assert!(markdown.contains(render::TIGHT_LINE));
    assert!(
        !markdown.contains("Also noted"),
        "no Also noted section even if the model sent lines: {markdown}"
    );
    assert!(report.also_noted.is_empty());
    assert!(report.picks.len() <= 3);
    assert!(
        report.also_in_the_news.is_some() && markdown.contains(render::AIN_LABEL),
        "the Also-in-the-news line stays when one is eligible: {markdown}"
    );
    assert_eq!(w.store().load_meta(oct(26), 1).unwrap().mode, Mode::Tight);
    assert_sane(&report);
}

#[tokio::test]
async fn h4_6_a_normal_run_asks_for_five_picks_and_allows_also_noted() {
    let w = tight_or_normal_world("Cruise").await;
    let curator = Scripted::new(|input| Ok(publish_full(input)));
    let outcome = w.run(&curator, Trigger::Scheduled).await;
    assert_eq!(produced(&outcome).2, Mode::Normal);

    let input = curator.last();
    assert_eq!(input.max_picks, 5);
    assert!(input.also_noted);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert!(!markdown.contains("Short report"), "{markdown}");
    assert!(markdown.contains("Also noted"), "{markdown}");
    assert_sane(&w.report(oct(26), 1));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-13: budget posture mapping (D1)
// ═════════════════════════════════════════════════════════════════════════════

fn now_for_posture() -> DateTime<Utc> {
    ts("2026-10-26T06:05:00Z")
}

fn posture_file(word: &str) -> serde_json::Value {
    json!({"ts": "2026-10-26T05:00:00Z", "posture": word})
}

fn mode_of(file: serde_json::Value) -> Mode {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("budget-posture.json");
    fs::write(&path, file.to_string()).unwrap();
    budget::assess(&path, &HueyConfig::default(), now_for_posture()).mode
}

#[test]
fn h4_13_each_bishop_posture_word_maps_to_its_mode() {
    for (word, want) in [
        ("Put the hammer down", Mode::Normal),
        ("Push", Mode::Normal),
        ("Cruise", Mode::Normal),
        ("Ease up", Mode::Normal),
        ("Pump the brakes", Mode::Tight),
        ("flush", Mode::Normal),
        ("normal", Mode::Normal),
        ("elevated", Mode::Tight),
        ("conservative", Mode::Tight),
        ("critical", Mode::Critical),
    ] {
        assert_eq!(mode_of(posture_file(word)), want, "posture {word:?}");
    }
}

#[test]
fn h4_13_seven_day_usage_of_ninety_is_tight_and_ninety_eight_is_critical() {
    for (used, want) in [
        (0.0, Mode::Normal),
        (89.9, Mode::Normal),
        (90.0, Mode::Tight),
        (97.9, Mode::Tight),
        (98.0, Mode::Critical),
        (100.0, Mode::Critical),
    ] {
        let mut file = posture_file("Cruise");
        file["seven_day"] = json!({"used_pct": used});
        assert_eq!(mode_of(file), want, "{used}% used");
    }
}

#[test]
fn h4_13_stale_input_metered_billing_and_old_files_are_tight() {
    let mut stale_input = posture_file("Cruise");
    stale_input["stale_input"] = true.into();
    assert_eq!(mode_of(stale_input), Mode::Tight);

    let mut metered = posture_file("Cruise");
    metered["billing_mode"] = "metered".into();
    assert_eq!(mode_of(metered), Mode::Tight);

    let mut subscription = posture_file("Cruise");
    subscription["billing_mode"] = "subscription".into();
    assert_eq!(mode_of(subscription), Mode::Normal);

    // Older than 24 h by its own timestamp.
    let mut old = posture_file("Cruise");
    old["ts"] = "2026-10-25T06:04:00Z".into();
    assert_eq!(mode_of(old), Mode::Tight);
    let mut recent = posture_file("Cruise");
    recent["ts"] = "2026-10-25T07:00:00Z".into();
    assert_eq!(mode_of(recent), Mode::Normal);
}

#[test]
fn h4_13_a_file_without_a_timestamp_is_judged_by_its_modification_time() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("budget-posture.json");
    fs::write(&path, json!({"posture": "Cruise"}).to_string()).unwrap();
    let now = Utc::now();
    assert_eq!(
        budget::assess(&path, &HueyConfig::default(), now).mode,
        Mode::Normal,
        "just written"
    );
    let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
    file.set_modified(std::time::SystemTime::now() - Duration::from_secs(25 * 3600))
        .unwrap();
    drop(file);
    assert_eq!(
        budget::assess(&path, &HueyConfig::default(), now).mode,
        Mode::Tight,
        "written 25 hours ago"
    );
}

#[test]
fn h4_13_an_exhausted_model_family_is_critical_and_critical_beats_tight() {
    let mut sonnet = posture_file("Cruise");
    sonnet["exhausted_models"] = json!(["sonnet"]);
    assert_eq!(
        mode_of(sonnet),
        Mode::Critical,
        "Huey's default model is sonnet"
    );

    let mut opus = posture_file("Cruise");
    opus["exhausted_models"] = json!(["opus"]);
    assert_eq!(mode_of(opus), Mode::Normal);

    let mut both = posture_file("Pump the brakes");
    both["exhausted_models"] = json!(["sonnet"]);
    assert_eq!(mode_of(both), Mode::Critical);

    let mut metered_critical = posture_file("critical");
    metered_critical["billing_mode"] = "metered".into();
    assert_eq!(mode_of(metered_critical), Mode::Critical);
}

#[test]
fn h4_13_a_missing_file_is_normal_and_has_no_posture_line() {
    let dir = tempfile::tempdir().unwrap();
    let note = budget::assess(
        &dir.path().join("nope.json"),
        &HueyConfig::default(),
        now_for_posture(),
    );
    assert_eq!(note.mode, Mode::Normal);
    assert_eq!(note.posture, None);
}

#[tokio::test]
async fn h4_13_a_missing_posture_file_runs_normal_and_the_footer_says_so() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    let curator = Scripted::picking(1, false);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert_eq!(report.mode, Mode::Normal);
    assert!(render::footer_text(&report.footer).contains("Budget posture unavailable."));
    assert_eq!(w.store().load_meta(oct(26), 1).unwrap().posture, None);
}

#[tokio::test]
async fn h4_13_a_present_posture_file_is_recorded_and_not_reported_as_unavailable() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.posture("Cruise");
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    let curator = Scripted::picking(1, false);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert!(!render::footer_text(&report.footer).contains("unavailable"));
    assert!(w.store().load_meta(oct(26), 1).unwrap().posture.is_some());
}

#[tokio::test]
async fn h4_13_metered_billing_with_a_cruise_posture_runs_a_tight_report() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.posture_json(json!({
        "ts": (w.now() - hours(1)).to_rfc3339(),
        "posture": "Cruise",
        "billing_mode": "metered",
    }));
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    let curator = Scripted::picking(1, false);
    let outcome = w.run(&curator, Trigger::Scheduled).await;
    assert_eq!(produced(&outcome).2, Mode::Tight);
    assert_eq!(curator.last().max_picks, 3);
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-7: critical mode, the uncurated report
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_7_a_critical_run_calls_no_model_and_lists_twenty_first_party_headlines() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR, BLOG, FORUM]);
    w.confirm();
    w.posture("critical");
    for k in 0..35 {
        w.items(
            VN,
            &[(
                &format!("update-{k}"),
                &format!("Gizmo update {k}"),
                w.now() - hours(k + 1),
            )],
        );
    }
    for k in 0..5 {
        w.items(
            BLOG.0,
            &[(
                &format!("post-{k}"),
                &format!("Practical blog post {k}"),
                w.now() - hours(k + 1),
            )],
        );
        w.items(
            FORUM.0,
            &[(
                &format!("link-{k}"),
                &format!("Forum link number {k}"),
                w.now() - hours(k + 1),
            )],
        );
    }
    let curator = Scripted::picking(5, true);
    let outcome = w.run(&curator, Trigger::Scheduled).await;
    assert_eq!(produced(&outcome), (oct(26), 1, Mode::Critical));
    assert_eq!(curator.calls(), 0, "no model on a critical day");

    let report = w.report(oct(26), 1);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    let list = report.uncurated.as_ref().expect("an uncurated list");

    // 35 first-party items: 20 lines, then "and 15 more (first-party)".
    assert_eq!(list.lines.len(), 20);
    assert_eq!(list.more, 15);
    assert!(markdown.contains("and 15 more (first-party)"), "{markdown}");
    assert!(markdown.contains(render::UNCURATED_LINE), "{markdown}");
    assert_eq!(
        render::UNCURATED_LINE,
        "Uncurated: budget is critical, so no model ran today."
    );
    assert_eq!(
        markdown.lines().filter(|l| l.starts_with("- [")).count(),
        20,
        "each line is a headline link"
    );

    // Newest first, links only, first-party only.
    for (i, line) in list.lines.iter().enumerate() {
        assert_eq!(line.link.title, format!("Gizmo update {i}"));
        assert!(line.link.url.starts_with("https://"), "{}", line.link.url);
        assert_eq!(line.item_id, id(VN, &format!("update-{i}")));
    }
    assert!(!markdown.contains("Practical blog post"), "{markdown}");
    assert!(!markdown.contains("Forum link"), "{markdown}");
    assert!(report.picks.is_empty());
    assert!(report.also_noted.is_empty());

    // Recorded as uncurated: no model, ledger section `uncurated`.
    let meta = w.store().load_meta(oct(26), 1).unwrap();
    assert_eq!(meta.mode, Mode::Critical);
    assert_eq!(meta.model, None);
    let ledger = w.store().ledger();
    assert_eq!(ledger.entries.len(), 20);
    assert!(ledger
        .entries
        .iter()
        .all(|e| e.section == Section::Uncurated));
    assert_sane(&report);
}

/// Critical day with news from the three rule sources and `vendor_items`
/// newer first-party items (so none of the rule sources' items reaches the
/// 20-line list when there are enough of them).
async fn critical_ain_world(
    anthropic: bool,
    notes: bool,
    changelog: bool,
    vendor_items: i64,
) -> World {
    let w = world(MONDAY).await;
    w.sources(&[ANTHROPIC, NOTES, CHANGELOG, VENDOR]);
    w.confirm();
    w.posture("critical");
    w.empty_feed(VN);
    for k in 0..vendor_items {
        w.items(
            VN,
            &[(
                &format!("update-{k}"),
                &format!("Gizmo update {k}"),
                w.now() - hours(k + 1),
            )],
        );
    }
    w.empty_feed(ANTHROPIC.0);
    w.empty_feed(NOTES.0);
    w.empty_feed(CHANGELOG.0);
    if anthropic {
        w.items(
            ANTHROPIC.0,
            &[
                ("a1", "Anthropic announces A1", w.now() - days(4)),
                ("a2", "Anthropic announces A2", w.now() - days(5)),
            ],
        );
    }
    if notes {
        w.items(
            NOTES.0,
            &[
                ("d1", "Release notes D1", w.now() - days(3)),
                ("d2", "Release notes D2", w.now() - days(6)),
            ],
        );
    }
    if changelog {
        w.items(CHANGELOG.0, &[("c1", "Changelog C1", w.now() - days(2))]);
    }
    w
}

async fn ain_of_critical_run(w: &World) -> Option<String> {
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    assert_eq!(report.mode, Mode::Critical);
    assert_eq!(curator.calls(), 0);
    assert_sane(&report);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    let ain = report.also_in_the_news.as_ref().map(|a| a.item_id.clone());
    assert_eq!(
        ain.is_some(),
        markdown.contains(render::AIN_LABEL),
        "the section is there exactly when there is a line"
    );
    ain
}

#[tokio::test]
async fn h4_7_the_critical_news_line_is_the_newest_anthropic_news_item_even_if_others_are_newer() {
    let w = critical_ain_world(true, true, true, 22).await;
    let ain = ain_of_critical_run(&w).await;
    assert_eq!(ain, Some(id(ANTHROPIC.0, "a1")));

    let report = w.report(oct(26), 1);
    let list = report.uncurated.as_ref().unwrap();
    assert_eq!(list.lines.len(), 20);
    // 22 vendor + 2 anthropic + 2 docs + 1 changelog first-party items.
    assert_eq!(list.more, 27 - 20);
    assert!(list
        .lines
        .iter()
        .all(|l| l.item_id.starts_with("vendor-news:")));
    // The line is itself recorded, so it is not repeated for two weeks.
    let entry = w
        .store()
        .ledger()
        .entries
        .into_iter()
        .find(|e| e.item_id == id(ANTHROPIC.0, "a1"))
        .expect("the news line is in the ledger");
    assert_eq!(entry.section, Section::Ain);
}

#[tokio::test]
async fn h4_7_without_anthropic_news_the_critical_news_line_is_the_newest_docs_release_note() {
    let w = critical_ain_world(false, true, true, 22).await;
    assert_eq!(
        ain_of_critical_run(&w).await,
        Some(id(NOTES.0, "d1")),
        "docs release notes come before the changelog"
    );
}

#[tokio::test]
async fn h4_7_without_either_the_critical_news_line_is_the_newest_changelog_entry() {
    let w = critical_ain_world(false, false, true, 22).await;
    assert_eq!(ain_of_critical_run(&w).await, Some(id(CHANGELOG.0, "c1")));
}

#[tokio::test]
async fn h4_7_with_none_of_the_three_sources_there_is_no_critical_news_line() {
    let w = critical_ain_world(false, false, false, 22).await;
    assert_eq!(ain_of_critical_run(&w).await, None);
}

#[tokio::test]
async fn h4_7_an_item_shown_in_the_last_fourteen_days_cannot_be_the_critical_news_line() {
    let w = critical_ain_world(true, true, true, 22).await;
    w.store()
        .save_ledger(&Ledger {
            entries: vec![ledger_entry(&id(ANTHROPIC.0, "a1"), oct(23), Section::Ain)],
        })
        .unwrap();
    assert_eq!(
        ain_of_critical_run(&w).await,
        Some(id(ANTHROPIC.0, "a2")),
        "the newest eligible item"
    );
}

#[tokio::test]
async fn h4_7_the_critical_news_line_is_omitted_when_its_item_is_already_in_the_list() {
    // Few items: everything first-party is in the list, anthropic-news's A1 too.
    let w = critical_ain_world(true, true, true, 0).await;
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    let list = report.uncurated.as_ref().unwrap();
    assert!(list
        .lines
        .iter()
        .any(|l| l.item_id == id(ANTHROPIC.0, "a1")));
    assert_eq!(report.also_in_the_news, None);
    assert_sane(&report);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert!(!markdown.contains(render::AIN_LABEL), "{markdown}");
}

#[test]
fn h4_7_the_news_line_rule_prefers_anthropic_news_then_docs_then_changelog() {
    let first = SourceClass::FirstParty;
    let a_old = news(
        "anthropic-news",
        "old",
        first,
        "Older",
        ts("2026-10-21T00:00:00Z"),
    );
    let a_new = news(
        "anthropic-news",
        "new",
        first,
        "Newer",
        ts("2026-10-22T00:00:00Z"),
    );
    let docs = news(
        "claude-docs-release-notes",
        "d",
        first,
        "Docs",
        ts("2026-10-24T00:00:00Z"),
    );
    let log = news(
        "claude-code-changelog",
        "c",
        first,
        "Log",
        ts("2026-10-25T00:00:00Z"),
    );
    let other = news(VN, "x", first, "Other", ts("2026-10-26T00:00:00Z"));

    let pick_id = |items: &[NewsItem]| run::ain_by_rule(items).map(|i| i.id.clone());
    assert_eq!(
        pick_id(&[
            log.clone(),
            docs.clone(),
            a_old.clone(),
            a_new.clone(),
            other.clone()
        ]),
        Some(a_new.id.clone())
    );
    assert_eq!(
        pick_id(&[log.clone(), docs.clone(), other.clone()]),
        Some(docs.id.clone())
    );
    assert_eq!(pick_id(&[log.clone(), other.clone()]), Some(log.id.clone()));
    assert_eq!(pick_id(&[other]), None);
    assert_eq!(pick_id(&[]), None);
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-8: who can be the Also-in-the-news line
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_8_the_eligible_set_excludes_shown_aggregator_curated_and_hard_ignored_items() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR, BLOG, FORUM]);
    w.confirm();
    w.interests(&fixture("runs/interests-ignore-php.md"));
    w.items(
        VN,
        &[
            ("f1", "Gizmo alpha", w.now() - hours(24)),
            ("f2", "Gizmo beta", w.now() - hours(25)),
            ("f3", "Gizmo gamma", w.now() - hours(26)),
            ("f4", "Gizmo delta", w.now() - hours(27)),
            ("f5", "Gizmo epsilon", w.now() - hours(28)),
            (
                "php-9",
                "PHP 9 released with a new engine",
                w.now() - hours(29),
            ),
        ],
    );
    w.items(
        BLOG.0,
        &[("b1", "Practical gizmo notes", w.now() - hours(30))],
    );
    w.items(FORUM.0, &[("a1", "Link about gizmos", w.now() - hours(31))]);
    w.store()
        .save_ledger(&Ledger {
            entries: vec![
                // Shown as a pick three days ago.
                ledger_entry(&id(VN, "f1"), oct(23), Section::Pick),
                // Listed (uncurated) three days ago.
                ledger_entry(&id(VN, "f2"), oct(23), Section::Uncurated),
                // Shown 13 days ago: still inside the 14 days.
                ledger_entry(&id(VN, "f4"), oct(13), Section::AlsoNoted),
                // Shown 14 days ago: out of the 14 days.
                ledger_entry(&id(VN, "f5"), oct(12), Section::Pick),
            ],
        })
        .unwrap();
    let curator = Scripted::picking(1, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let input = curator.last();

    // Eligible for the news line: first-party, not shown in 14 days (any
    // section), not hard-ignored. Never the blog or the aggregator.
    assert_eq!(
        ain_ids(&input),
        set(&[id(VN, "f3"), id(VN, "f5")]),
        "also in the news candidates"
    );
    // Pick candidates: only a curated or pick-shown ledger entry blocks.
    assert_eq!(
        candidate_ids(&input),
        set(&[
            id(VN, "f2"),
            id(VN, "f3"),
            id(VN, "f5"),
            id(BLOG.0, "b1"),
            id(FORUM.0, "a1"),
        ])
    );
    assert_eq!(
        report.also_in_the_news.as_ref().map(|a| a.item_id.clone()),
        Some(id(VN, "f3")),
        "the newest eligible item"
    );
    assert_sane(&report);
}

#[tokio::test]
async fn h4_8_an_item_reported_as_a_pick_is_not_also_the_news_line() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    for n in 1..=4 {
        w.items(
            VN,
            &[(
                &format!("n{n}"),
                &format!("Gizmo release note {n}"),
                w.now() - hours(n),
            )],
        );
    }
    let curator = Scripted::picking(2, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    let ain = report.also_in_the_news.as_ref().expect("a news line");
    assert!(report
        .picks
        .iter()
        .all(|p| !p.item_ids.contains(&ain.item_id)));
    assert_sane(&report);
}

#[tokio::test]
async fn h4_8_a_quiet_week_gives_an_empty_eligible_set_and_no_news_line() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[
            ("old-1", "Gizmo news from ten days ago", w.now() - days(10)),
            (
                "old-2",
                "Gizmo news from twelve days ago",
                w.now() - days(12),
            ),
        ],
    );
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert!(ain_ids(&curator.last()).is_empty());
    assert_eq!(report.also_in_the_news, None);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert!(!markdown.contains("Also in the news"), "{markdown}");
    assert_sane(&report);
}

#[tokio::test]
async fn h4_8_a_quiet_week_on_a_critical_day_has_no_news_line_either() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.posture("critical");
    w.items(
        VN,
        &[("old-1", "Gizmo news from ten days ago", w.now() - days(10))],
    );
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert_eq!(report.mode, Mode::Critical);
    assert_eq!(report.also_in_the_news, None);
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert!(!markdown.contains("Also in the news"), "{markdown}");
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-14: no news line, with a reason
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_14_a_skipped_news_line_is_explained_in_the_footer_which_stays_within_100_words() {
    let w = world(MONDAY).await;
    footer_world_sources(&w);
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    for n in 1..=6 {
        w.items(
            VN,
            &[(
                &format!("n{n}"),
                &format!(
                    "Gizmo release note {n} with a deliberately long headline that goes on and on for many words"
                ),
                w.now() - hours(2 + n),
            )],
        );
    }
    let reason = "everything new from first parties is already covered in the picks or was shown earlier this fortnight";
    let curator = Scripted::new(move |input| {
        let mut p = publish(input, 0, false);
        p.picks = vec![pick(&id_of(input, "Gizmo 2 ships batch mode"), 1)];
        p.also_in_the_news = None;
        p.ain_skip_reason = Some(reason.into());
        p.dropped = (1..=6)
            .map(|n| {
                let title = input
                    .frame
                    .items
                    .values()
                    .find(|i| i.title.starts_with(&format!("Gizmo release note {n} ")))
                    .unwrap();
                drop_of(&title.id, "duplicate coverage")
            })
            .collect();
        Ok(p)
    });
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert_eq!(report.also_in_the_news, None);
    let footer = render::footer_text(&report.footer);
    let sentence = format!("No Also-in-the-news line: {reason}.");
    assert!(footer.contains(&sentence), "{footer}");
    assert!(render::words(&footer) <= 100, "{footer}");
    let markdown = w.store().load_markdown(oct(26), 1).unwrap();
    assert!(markdown.contains(&sentence), "{markdown}");
    assert!(!markdown.contains(render::AIN_LABEL));
    assert_sane(&report);
}

#[tokio::test]
async fn h4_14_a_news_line_that_is_present_has_no_skip_sentence() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    for n in 1..=3 {
        w.items(
            VN,
            &[(
                &format!("n{n}"),
                &format!("Gizmo release note {n}"),
                w.now() - hours(n),
            )],
        );
    }
    let curator = Scripted::new(|input| {
        let mut p = publish(input, 1, true);
        // A leftover reason alongside an actual line must not be shown.
        p.ain_skip_reason = Some("not needed".into());
        Ok(p)
    });
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    assert!(report.also_in_the_news.is_some());
    assert!(!render::footer_text(&report.footer).contains("No Also-in-the-news line"));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-9: the report that is missing
// ═════════════════════════════════════════════════════════════════════════════

/// A machine that made Sunday's report (Oct 25, 06:05) and whose engine is
/// parked: its scheduler took its first look before setup was confirmed and
/// sleeps for an hour, so only the test's own triggers run.
async fn sunday_report_exists() -> (World, HueySources, Arc<Scripted>, Arc<AtomicBool>) {
    let w = world("2026-10-25T05:00:00Z").await;
    w.sources(&[VENDOR, BLOG]);
    // The model works on Sunday and is down on Monday, unless a test brings it up.
    let model_up = Arc::new(AtomicBool::new(false));
    let up = model_up.clone();
    let curator = Scripted::new(move |input| {
        if input.date == oct(25) || up.load(Ordering::SeqCst) {
            Ok(publish(input, 1, false))
        } else {
            Err(CurateError::Failed("the model is not answering".into()))
        }
    });
    let src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_secs(3600)));
    tokio::time::sleep(Duration::from_millis(100)).await;
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-25T01:00:00Z"),
        )],
    );
    w.items(
        BLOG.0,
        &[(
            "blog-1",
            "Practical notes on batching",
            ts("2026-10-25T02:00:00Z"),
        )],
    );
    w.clock.set(ts("2026-10-25T06:05:00Z"));
    let outcome = src.handle.trigger(Trigger::RunNow).await.unwrap();
    assert_eq!(produced(&outcome), (oct(25), 1, Mode::Normal));
    (w, src, curator, model_up)
}

fn assert_shows_sunday(doc: &HueyDocument, reason: &str) {
    assert_eq!(doc.title, "Huey, Sun Oct 25, 2026");
    assert_eq!(doc.date, Some(oct(25)));
    let banner = doc
        .banner
        .as_ref()
        .expect("a previous day's report always carries a banner");
    assert_eq!(
        banner.text,
        format!(
            "This is the report from Sunday, Oct 25, 2026. Today's report is missing: {reason}."
        )
    );
    assert!(
        doc.markdown.starts_with("Sunday, Oct 25."),
        "{}",
        doc.markdown
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_asleep_shows_the_latest_report_with_its_date_and_the_reason() {
    let (w, src, _curator, _up) = sunday_report_exists().await;
    let h = &src.handle;

    // 06:05 on Monday: the run is not overdue yet.
    w.clock.set(ts("2026-10-26T06:05:00Z"));
    assert_eq!(h.missing_reason(h.today()), MissingReason::Pending);
    assert_shows_sunday(&h.current_document(), "it is not ready yet");

    // 07:00: no attempt happened at all.
    w.clock.set(ts("2026-10-26T07:00:00Z"));
    assert_eq!(h.today(), oct(26));
    assert_eq!(h.missing_reason(oct(26)), MissingReason::Asleep);
    assert_shows_sunday(
        &h.current_document(),
        "the machine was asleep or the daemon was not running at report time",
    );
    assert!(w.store().latest_version(oct(26)).is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_a_failed_fetch_shows_the_latest_report_with_its_date_and_the_reason() {
    let (w, src, _curator, _up) = sunday_report_exists().await;
    let h = &src.handle;

    // The first-party source is down; the blog still answers. That is a
    // failed fetch: no first-party source answered.
    w.fail_source(VN, 500);
    w.clock.set(ts("2026-10-26T06:05:00Z"));
    let outcome = h.trigger(Trigger::Scheduled).await.unwrap();
    assert_eq!(
        outcome,
        RunOutcome::Failed {
            reason: FailReason::FetchFailed
        }
    );
    assert_eq!(h.missing_reason(oct(26)), MissingReason::FetchFailed);
    assert_shows_sunday(&h.current_document(), "fetching the news failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_a_model_failure_shows_the_latest_report_with_its_date_and_the_reason_after_two_failures(
) {
    let (w, src, curator, _up) = sunday_report_exists().await;
    let h = &src.handle;

    // One failure, inside the retry window: not ready yet, not failed.
    w.clock.set(ts("2026-10-26T06:05:00Z"));
    let outcome = h.trigger(Trigger::Scheduled).await.unwrap();
    assert_eq!(
        outcome,
        RunOutcome::Failed {
            reason: FailReason::ModelFailed
        }
    );
    assert_eq!(h.missing_reason(oct(26)), MissingReason::Pending);
    assert_shows_sunday(&h.current_document(), "it is not ready yet");

    // The retry fails too: now it is a model failure.
    w.clock.set(ts("2026-10-26T06:15:00Z"));
    let outcome = h.trigger(Trigger::Retry).await.unwrap();
    assert_eq!(
        outcome,
        RunOutcome::Failed {
            reason: FailReason::ModelFailed
        }
    );
    assert_eq!(h.missing_reason(oct(26)), MissingReason::ModelFailed);
    assert_shows_sunday(&h.current_document(), "the model run failed");
    assert!(
        w.store().latest_version(oct(26)).is_none(),
        "a failed attempt leaves no half-written report"
    );
    assert!(curator.calls() >= 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_one_model_failure_whose_retry_is_ten_minutes_overdue_is_a_model_failure() {
    let (w, src, _curator, _up) = sunday_report_exists().await;
    let h = &src.handle;

    w.clock.set(ts("2026-10-26T06:05:00Z"));
    h.trigger(Trigger::Scheduled).await.unwrap();

    // The retry was due at 06:15 and has not happened.
    w.clock.set(ts("2026-10-26T06:24:00Z"));
    assert_eq!(h.missing_reason(oct(26)), MissingReason::Pending);
    w.clock.set(ts("2026-10-26T06:26:00Z"));
    assert_eq!(h.missing_reason(oct(26)), MissingReason::ModelFailed);
    assert_shows_sunday(&h.current_document(), "the model run failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_a_previous_days_report_is_never_shown_without_its_date() {
    let (w, src, _curator, _up) = sunday_report_exists().await;
    let h = &src.handle;
    w.clock.set(ts("2026-10-26T07:00:00Z"));

    // Through the current document...
    let current = h.current_document();
    assert!(current.title.contains("Oct 25"), "{}", current.title);
    assert!(current.banner.is_some());
    // ... and when asked for the day directly.
    let direct = h.document_for(oct(25), None).unwrap();
    assert_eq!(direct.title, "Huey, Sun Oct 25, 2026");
    let banner = direct.banner.expect("another day's report has a banner");
    assert!(
        banner.text.contains("Sunday, Oct 25, 2026"),
        "{}",
        banner.text
    );
    assert_eq!(
        render::banner_for(oct(25), oct(26), MissingReason::Asleep),
        Some(render::Banner {
            level: render::BannerLevel::Warning,
            text: "This is the report from Sunday, Oct 25, 2026. Today's report is missing: the machine was asleep or the daemon was not running at report time."
                .into(),
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_9_todays_report_replaces_the_old_one_and_a_regeneration_is_titled_v2() {
    let (w, src, _curator, model_up) = sunday_report_exists().await;
    let h = &src.handle;
    model_up.store(true, Ordering::SeqCst);

    w.clock.set(ts("2026-10-26T06:05:00Z"));
    let outcome = h.trigger(Trigger::Scheduled).await.unwrap();
    assert_eq!(produced(&outcome), (oct(26), 1, Mode::Normal));
    let doc = h.current_document();
    assert_eq!(doc.title, "Huey, Mon Oct 26, 2026");
    assert_eq!(doc.banner, None);
    assert_eq!(doc.version, Some(1));

    w.clock.set(ts("2026-10-26T06:20:00Z"));
    let outcome = h.trigger(Trigger::Regenerate).await.unwrap();
    assert_eq!(produced(&outcome), (oct(26), 2, Mode::Normal));
    let doc = h.current_document();
    assert_eq!(doc.title, "Huey, Mon Oct 26, 2026 (v2)");
    assert_eq!(doc.banner, None);
    assert_eq!(w.store().versions(oct(26)), vec![1, 2]);
}

#[test]
fn h4_9_the_fetch_failed_only_when_no_first_party_source_answered() {
    let status = |class: SourceClass, outcome: SourceOutcome| SourceStatus {
        id: "s".into(),
        name: "S".into(),
        class,
        outcome,
    };
    let failed = || SourceOutcome::Failed {
        reason: "HTTP 500".into(),
    };
    let first = SourceClass::FirstParty;

    assert!(run::fetch_failed(&[]));
    assert!(run::fetch_failed(&[status(first, failed())]));
    assert!(
        run::fetch_failed(&[
            status(first, failed()),
            status(SourceClass::Curated, SourceOutcome::Ok { new: 3 }),
            status(SourceClass::Aggregator, SourceOutcome::Quiet),
        ]),
        "only first-party answers count"
    );
    assert!(!run::fetch_failed(&[status(
        first,
        SourceOutcome::Ok { new: 1 }
    )]));
    assert!(!run::fetch_failed(&[status(first, SourceOutcome::Quiet)]));
    assert!(!run::fetch_failed(&[
        status(first, failed()),
        status(first, SourceOutcome::Quiet),
    ]));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-10: hard-ignore terms
// ═════════════════════════════════════════════════════════════════════════════

async fn php_world(interests: &str) -> World {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.interests(interests);
    make_project(
        &w.code_root,
        "lodge",
        &[
            ("composer.json", "{\"name\": \"example/lodge\"}\n"),
            ("src/Invoice.php", "<?php\nclass Invoice {}\n"),
        ],
        w.now() - days(3),
    );
    w.items(
        VN,
        &[
            (
                "php-9",
                "PHP 9 released with a new engine",
                w.now() - hours(1),
            ),
            ("gizmo-4", "Gizmo 4 ships", w.now() - hours(2)),
        ],
    );
    // Mentions the term in its text only: the match is on the title.
    w.item_with_body(
        VN,
        "sdk-notes",
        "Gizmo SDK 4 notes",
        w.now() - hours(3),
        "Includes a PHP binding and a new Python binding.",
    );
    w
}

#[tokio::test]
async fn h4_10_an_item_whose_title_holds_an_ignored_term_never_reaches_the_curator() {
    let w = php_world(&fixture("runs/interests-ignore-php.md")).await;
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let input = curator.last();
    let php = id(VN, "php-9");

    assert!(!candidate_ids(&input).contains(&php));
    assert!(!ain_ids(&input).contains(&php));
    assert!(!input.digest.text.contains("PHP 9 released"));
    assert_eq!(
        candidate_ids(&input),
        set(&[id(VN, "gizmo-4"), id(VN, "sdk-notes")]),
        "the title is what is matched, not the item's text"
    );

    // It is accounted for in the footer, with the reason.
    let drop = report
        .footer
        .dropped
        .iter()
        .find(|d| d.item_id == php)
        .expect("listed among the drops");
    assert_eq!(drop.reason, "ignored: PHP");
    assert!(render::footer_text(&report.footer).contains("ignored: PHP"));
    assert!(report.shown_ids().iter().all(|i| *i != php));
    assert_sane(&report);
}

#[tokio::test]
async fn h4_10_an_ignored_term_also_keeps_the_item_off_a_critical_report() {
    let w = php_world(&fixture("runs/interests-ignore-php.md")).await;
    w.posture("critical");
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;

    assert_eq!(report.mode, Mode::Critical);
    let list = report.uncurated.as_ref().unwrap();
    assert!(list.lines.iter().all(|l| l.item_id != id(VN, "php-9")));
    assert_eq!(list.lines.len(), 2);
    assert!(render::footer_text(&report.footer).contains("ignored: PHP"));
}

#[tokio::test]
async fn h4_10_without_the_term_the_php_item_reaches_the_curator() {
    // The second fixture machine's interests have no PHP term, and its
    // project is a PHP app.
    let w = php_world(&fixture("context/machine-b/interests.md")).await;
    let curator = Scripted::picking(5, true);
    let report = w.run_report(&curator, Trigger::Scheduled).await;
    let input = curator.last();

    assert!(candidate_ids(&input).contains(&id(VN, "php-9")));
    assert!(
        report.footer.dropped.is_empty(),
        "{:?}",
        report.footer.dropped
    );
    assert!(!render::footer_text(&report.footer).contains("ignored"));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-11: retention
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn h4_11_old_reports_pools_and_ledger_entries_are_pruned_on_schedule() {
    let today = ts("2026-10-26T06:05:00Z");
    let w = world("2026-08-25T06:05:00Z").await;
    w.sources(&[VENDOR]);
    w.confirm();
    let curator = Scripted::picking(1, false);

    let store = w.store();
    let mut dates = BTreeMap::new();
    for back in [61, 60, 31, 29, 1, 0] {
        let at = today - days(back);
        w.clock.set(at);
        w.items(
            VN,
            &[(
                &format!("news-{back}"),
                &format!("Gizmo news {back} days back"),
                at - hours(1),
            )],
        );
        let (date, version, _) = produced(&w.run(&curator, Trigger::Scheduled).await);
        assert_eq!(version, 1);
        dates.insert(back, date);
        if back == 61 || back == 31 {
            store
                .record_verdict(
                    date,
                    Verdict {
                        version: 1,
                        pick: 1,
                        item_id: id(VN, &format!("news-{back}")),
                        verdict: VerdictKind::Useful,
                        note: None,
                        at,
                    },
                )
                .unwrap();
            assert_eq!(store.verdicts(date).len(), 1);
        }
    }

    // Reports: 61 days old is gone (with its verdicts); 60, 31 and newer stay.
    let listed = store.dates();
    assert!(!listed.contains(&dates[&61]), "61 days old: {listed:?}");
    for back in [60, 31, 29, 1, 0] {
        assert!(
            listed.contains(&dates[&back]),
            "{back} days old: {listed:?}"
        );
    }
    assert!(!store.verdicts_file(dates[&61]).exists());
    assert!(!store.date_dir(dates[&61]).exists());
    assert!(store.verdicts(dates[&61]).is_empty());
    assert_eq!(
        store.verdicts(dates[&31]).len(),
        1,
        "a 31-day-old report keeps its verdicts"
    );

    // Pools: 30 days.
    let pool = |back: i64| load_pool(&w.paths.pool_dir(), dates[&back]);
    assert!(pool(61).is_none() && pool(60).is_none() && pool(31).is_none());
    assert!(pool(29).is_some() && pool(1).is_some() && pool(0).is_some());

    // Ledger entries: 30 days.
    let ledger = store.ledger();
    let ledger_dates: BTreeSet<NaiveDate> = ledger.entries.iter().map(|e| e.date).collect();
    assert!(!ledger_dates.contains(&dates[&61]));
    assert!(!ledger_dates.contains(&dates[&60]));
    assert!(!ledger_dates.contains(&dates[&31]));
    assert!(ledger_dates.contains(&dates[&29]));
    assert!(ledger_dates.contains(&dates[&1]));
    assert!(ledger_dates.contains(&dates[&0]));
}

// ═════════════════════════════════════════════════════════════════════════════
// H4-12: disabled or not set up means no trace
// ═════════════════════════════════════════════════════════════════════════════
//
// A disabled Huey is never spawned at all (`wire_agents` starts nothing; that
// guard lives in tests/agent_wiring.rs). A spawned engine that is not set up
// must leave the state root exactly as it found it, whatever is asked of it.

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn h4_12_a_not_set_up_engine_never_writes_under_the_state_root() {
    let w = silent_world("2026-10-26T05:00:00Z").await;
    // Other daemons' state is already there and must be left alone.
    fs::create_dir_all(w.state_root.join("trackers")).unwrap();
    fs::write(w.state_root.join("trackers/state.json"), "{}").unwrap();
    let before = snapshot(&w.state_root);
    let curator = Scripted::picking(1, true);
    let src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_millis(5)));

    w.clock.set(ts("2026-10-26T09:00:00Z"));
    tokio::time::sleep(Duration::from_millis(150)).await;

    // Everything a client could ask for.
    let h = &src.handle;
    for trigger in [Trigger::RunNow, Trigger::Scheduled, Trigger::Regenerate] {
        let outcome = h.trigger(trigger).await;
        assert!(
            !matches!(outcome, Ok(RunOutcome::Produced { .. })),
            "{trigger:?} produced a report on a machine that is not set up"
        );
    }
    let doc = h.current_document();
    assert!(doc.date.is_none());
    assert!(h.document_for(oct(26), None).is_none());
    let _ = h.missing_reason(h.today());

    assert_eq!(snapshot(&w.state_root), before);
    assert!(!w.paths.root().exists());
    assert_eq!(curator.calls(), 0);
    assert!(w.requests().await.is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// T7: one run at a time, and a regeneration cooldown
// ═════════════════════════════════════════════════════════════════════════════

/// A model that holds the run open until the test lets it finish.
#[derive(Default)]
struct Gate {
    entered: tokio::sync::Notify,
    release: tokio::sync::Notify,
}

#[async_trait]
impl Curator for Gate {
    async fn curate(&self, input: &CurateInput) -> Result<Publish, CurateError> {
        self.entered.notify_one();
        self.release.notified().await;
        Ok(publish(input, 1, false))
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t7_a_second_trigger_during_a_run_is_refused_and_a_regeneration_waits_two_minutes() {
    let w = world("2026-10-26T05:00:00Z").await;
    w.sources(&[VENDOR]);
    let gate = Arc::new(Gate::default());
    let src = HueyEngine::spawn(w.deps(gate.clone(), Duration::from_secs(3600)));
    tokio::time::sleep(Duration::from_millis(100)).await;
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T01:00:00Z"),
        )],
    );
    w.clock.set(ts("2026-10-26T06:05:00Z"));
    let h = src.handle.clone();

    let first = tokio::spawn({
        let h = h.clone();
        async move { h.trigger(Trigger::RunNow).await }
    });
    tokio::time::timeout(Duration::from_secs(10), gate.entered.notified())
        .await
        .expect("the run reached the model");
    assert!(h.is_running());
    assert_eq!(
        h.trigger(Trigger::RunNow).await,
        Err(TriggerRefused::AlreadyRunning)
    );
    assert_eq!(
        h.trigger(Trigger::Regenerate).await,
        Err(TriggerRefused::AlreadyRunning)
    );
    assert_eq!(
        h.trigger(Trigger::Retry).await,
        Err(TriggerRefused::AlreadyRunning)
    );
    assert_eq!(
        h.missing_reason(oct(26)),
        MissingReason::Pending,
        "reads still work during a run, and say it is not ready yet"
    );
    let _ = h.current_document();

    gate.release.notify_one();
    let outcome = first.await.unwrap().unwrap();
    assert_eq!(produced(&outcome), (oct(26), 1, Mode::Normal));
    assert!(!h.is_running());
    assert_eq!(w.store().versions(oct(26)), vec![1]);

    // Right after a run, a regeneration is refused with the time left.
    match h.trigger(Trigger::Regenerate).await {
        Err(TriggerRefused::Cooldown { seconds }) => {
            assert!((1..=120).contains(&seconds), "{seconds}")
        }
        other => panic!("expected a cooldown, got {other:?}"),
    }
    w.clock.set(ts("2026-10-26T06:06:30Z"));
    assert!(matches!(
        h.trigger(Trigger::Regenerate).await,
        Err(TriggerRefused::Cooldown { .. })
    ));
    assert_eq!(w.store().versions(oct(26)), vec![1], "refused, so no v2");

    // After two minutes it runs and makes version 2.
    w.clock.set(ts("2026-10-26T06:07:10Z"));
    gate.release.notify_one();
    let outcome = h.trigger(Trigger::Regenerate).await.unwrap();
    assert_eq!(produced(&outcome), (oct(26), 2, Mode::Normal));
    assert_eq!(w.store().versions(oct(26)), vec![1, 2]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn t7_a_failed_run_also_starts_the_regeneration_cooldown_but_not_a_plain_run() {
    let w = world("2026-10-26T05:00:00Z").await;
    w.sources(&[VENDOR]);
    let curator = Scripted::failing();
    let src = HueyEngine::spawn(w.deps(curator.clone(), Duration::from_secs(3600)));
    tokio::time::sleep(Duration::from_millis(100)).await;
    w.confirm();
    w.items(
        VN,
        &[(
            "gizmo-2",
            "Gizmo 2 ships batch mode",
            ts("2026-10-26T01:00:00Z"),
        )],
    );
    w.clock.set(ts("2026-10-26T06:05:00Z"));
    let h = &src.handle;

    let outcome = h.trigger(Trigger::RunNow).await.unwrap();
    assert_eq!(
        outcome,
        RunOutcome::Failed {
            reason: FailReason::ModelFailed
        }
    );
    assert!(matches!(
        h.trigger(Trigger::Regenerate).await,
        Err(TriggerRefused::Cooldown { .. })
    ));
    // A plain "run now" is not subject to the cooldown.
    assert!(matches!(
        h.trigger(Trigger::RunNow).await,
        Ok(RunOutcome::Failed { .. })
    ));
    assert_eq!(curator.calls(), 2);
}

// ═════════════════════════════════════════════════════════════════════════════
// Preferences live in interests.md and nowhere else
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn interest_edit_changes_next_model_input() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.items(
        VN,
        &[("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(1))],
    );
    let curator = Scripted::picking(1, false);

    w.interests(&fixture("runs/interests-compilers.md"));
    produced(&w.run(&curator, Trigger::Scheduled).await);

    // The user edits the file; the next run's input follows.
    w.interests(&fixture("runs/interests-sailing.md"));
    w.clock.set(ts("2026-10-27T06:05:00Z"));
    w.items(
        VN,
        &[("gizmo-3", "Gizmo 3 ships", ts("2026-10-27T02:00:00Z"))],
    );
    produced(&w.run(&curator, Trigger::Scheduled).await);

    let inputs = curator.inputs();
    assert_eq!(inputs.len(), 2);
    assert!(inputs[0].digest.text.contains("Compilers"));
    assert!(!inputs[0].digest.text.contains("Sailing"));
    assert!(
        inputs[1].digest.text.contains("Sailing"),
        "{}",
        inputs[1].digest.text
    );
    assert!(!inputs[1].digest.text.contains("Compilers"));
}

#[tokio::test]
async fn no_preference_state_outside_interests() {
    let w = world(MONDAY).await;
    w.sources(&[VENDOR]);
    w.confirm();
    w.interests(&fixture("runs/interests-canary.md"));
    let interests_before = fs::read(w.paths.interests()).unwrap();
    w.items(
        VN,
        &[
            ("gizmo-2", "Gizmo 2 ships batch mode", w.now() - hours(2)),
            ("gizmo-3", "Gizmo 3 ships", w.now() - hours(1)),
        ],
    );
    let curator = Scripted::picking(2, true);

    // A curated day, then a critical one.
    produced(&w.run(&curator, Trigger::Scheduled).await);
    w.clock.set(ts("2026-10-27T06:05:00Z"));
    w.posture("critical");
    w.items(
        VN,
        &[("gizmo-4", "Gizmo 4 ships", ts("2026-10-27T02:00:00Z"))],
    );
    produced(&w.run(&curator, Trigger::Scheduled).await);

    assert_eq!(
        fs::read(w.paths.interests()).unwrap(),
        interests_before,
        "Huey never edits interests.md"
    );
    let mut holders = BTreeSet::new();
    let mut files = 0;
    for (rel, bytes) in snapshot(w.paths.root()) {
        let Some(bytes) = bytes else { continue };
        files += 1;
        if String::from_utf8_lossy(&bytes).contains("CANARY-PREF-4417") {
            holders.insert(rel);
        }
    }
    assert!(files > 5, "the run left its files behind");
    assert!(holders.contains("interests.md"));
    for rel in &holders {
        let allowed = rel == "interests.md"
            || (rel.starts_with("reports/")
                && (rel.ends_with("/digest.md") || rel.ends_with("/model-input.txt")));
        assert!(allowed, "interest text found in {rel}");
    }
    for rel in snapshot(w.paths.root()).keys() {
        if rel.starts_with("state/") || rel.starts_with("pool/") {
            assert!(!holders.contains(rel), "interest text in {rel}");
        }
        if rel.ends_with("meta.json") || rel.ends_with("report.json") || rel.ends_with("report.md")
        {
            assert!(!holders.contains(rel), "interest text in {rel}");
        }
    }
}
