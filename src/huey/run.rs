//! The daily pipeline (A2): fetch, filter, digest, mode, curate or list,
//! render, persist.
//!
//! [`run`] is one attempt. It reads its inputs, decides, and writes one
//! report version plus the ledger and run log. Nothing runs, reads or
//! writes until setup is confirmed. The model pass sits behind [`Curator`]:
//! H4 ships [`NoCurator`], so every normal or tight run ends "model failed"
//! until the hidden session lands; a critical run needs no model.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::data::work::untrusted::one_line;
use crate::huey::budget::{self, Mode, PostureNote};
use crate::huey::config::HueyConfig;
use crate::huey::context::collectors::PrsInput;
use crate::huey::context::digest::ProjectContext;
use crate::huey::context::{self, build_digest, ContextEnv, Digest, LiveInputs};
use crate::huey::interests::{self, Interests};
use crate::huey::items::{cluster, Cluster, NewsItem, SourceClass};
use crate::huey::paths::HueyPaths;
use crate::huey::render::{
    self, AinLine, FailedSource, Footer, FooterDrop, HeadlineLine, Link, NotedLine, Pick,
    PickCheck, Report, UncuratedList, UNCURATED_CAP,
};
use crate::huey::schedule::{LocalTime, Schedule};
use crate::huey::setup::{self, SetupState};
use crate::huey::sources::config::load_file;
use crate::huey::sources::{
    fetch_all, load_pool, save_pool, FetchOutcome, HttpClient, SourceOutcome, SourceStatus,
};
use crate::huey::store::{
    Ledger, LedgerEntry, ReportFiles, ReportMeta, RunRecord, RunResult, Section, Store,
};
use crate::tracker::clock::Clock;

/// The first run ever looks this many days back.
pub const FIRST_RUN_DAYS: i64 = 7;
/// Picks per report, normal and tight (AC6, AC32).
pub const MAX_PICKS: usize = 5;
pub const TIGHT_MAX_PICKS: usize = 3;
/// In tight mode the model sees every first-party story plus this many others.
pub const TIGHT_OTHER_CLUSTERS: usize = 40;
/// The Also-in-the-news rule under critical mode (AC44): the newest eligible
/// item from the first of these sources that has one.
pub const AIN_RULE_SOURCES: [&str; 3] = [
    "anthropic-news",
    "claude-docs-release-notes",
    "claude-code-changelog",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    Scheduled,
    /// The scheduled run, started late (the machine slept through it).
    CatchUp,
    /// The one retry after a model failure (V5).
    Retry,
    Regenerate,
    RunNow,
}

/// Why an attempt produced no report. Never budget (V6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailReason {
    /// No attempt happened in time (the engine's view; [`run`] never returns it).
    Asleep,
    /// No first-party source answered.
    FetchFailed,
    ModelFailed,
    /// The report could not be saved.
    WriteFailed,
    NotSetUp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunOutcome {
    Produced {
        date: NaiveDate,
        version: u32,
        mode: Mode,
    },
    Failed {
        reason: FailReason,
    },
}

// ── The publish contract (A4) ────────────────────────────────────────────────

/// What the model returns through `huey.publish_report`. Every reference is
/// an id the daemon issued; the daemon renders links, labels and the footer.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Publish {
    #[serde(default)]
    pub opener_gist: String,
    #[serde(default)]
    pub picks: Vec<PublishPick>,
    #[serde(default)]
    pub also_in_the_news: Option<PublishAin>,
    #[serde(default)]
    pub ain_skip_reason: Option<String>,
    #[serde(default)]
    pub also_noted: Vec<PublishNoted>,
    #[serde(default)]
    pub dropped: Vec<PublishDrop>,
    #[serde(default)]
    pub ignored: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishPick {
    pub item_ids: Vec<String>,
    pub headline: String,
    pub what_happened: String,
    pub project: String,
    pub for_line: String,
    #[serde(default)]
    pub anchors: Vec<String>,
    pub check: PublishCheck,
    #[serde(default)]
    pub follow_up_of: Option<String>,
    #[serde(default)]
    pub whats_new: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PublishCheck {
    Checked {
        text: String,
        #[serde(default)]
        check_ids: Vec<String>,
        #[serde(default)]
        facts: Vec<String>,
    },
    ToCheck {
        text: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishAin {
    pub item_id: String,
    pub headline: String,
    pub what_happened: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishNoted {
    pub item_ids: Vec<String>,
    pub line: String,
    pub interest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishDrop {
    pub item_id: String,
    pub reason: String,
}

// ── The curator seam ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CurateError {
    #[error("no model is available")]
    Unavailable,
    #[error("the model run failed: {0}")]
    Failed(String),
}

/// Everything the model pass gets for one normal or tight run.
#[derive(Debug, Clone)]
pub struct CurateInput {
    pub date: NaiveDate,
    pub version: u32,
    pub mode: Mode,
    pub model: String,
    pub max_budget_usd: f64,
    /// 5 normally, 3 when tight.
    pub max_picks: usize,
    /// `false` when tight: no Also noted.
    pub also_noted: bool,
    /// The digest as written to `report_dir/digest.md`.
    pub digest: Digest,
    /// Candidate stories (tight: trimmed), best source first in each.
    pub candidates: Vec<Cluster>,
    /// The Also-in-the-news eligible set, before this report's picks and the
    /// model's `ignored` are taken out (A7).
    pub ain_candidates: Vec<NewsItem>,
    /// Items shown in the 14 days before `date` (for `follow_up_of`).
    pub recent_shown: Vec<LedgerEntry>,
    /// Project id → main worktree, for checks.
    pub project_roots: BTreeMap<String, PathBuf>,
    /// This version's directory. `digest.md` is already there; the curator
    /// writes `model-input.txt` and `checks.json` and appends check results
    /// to `digest.md`.
    pub report_dir: PathBuf,
    pub frame: ReportFrame,
}

impl CurateInput {
    /// The report `publish` would render to (for word caps and checks).
    pub fn render(&self, publish: &Publish) -> Report {
        assemble_curated(&self.frame, publish)
    }
}

// `async_trait` marks the boxed future `#[must_use]`; the `Result` already
// is, and newer clippy flags the macro-generated attribute as `double_must_use`.
#[allow(clippy::double_must_use)]
#[async_trait]
pub trait Curator: Send + Sync {
    async fn curate(&self, input: &CurateInput) -> Result<Publish, CurateError>;
}

/// No model wired in (H4): every curated run fails "model failed".
#[derive(Debug, Clone, Copy, Default)]
pub struct NoCurator;

#[async_trait]
impl Curator for NoCurator {
    async fn curate(&self, _input: &CurateInput) -> Result<Publish, CurateError> {
        Err(CurateError::Unavailable)
    }
}

/// What the daemon knows that the context needs: the user's PRs and
/// Mother's jobs.
#[allow(clippy::double_must_use)]
#[async_trait]
pub trait LiveSource: Send + Sync {
    async fn live(&self, now: DateTime<Utc>) -> LiveInputs;
}

/// No PRs and no jobs.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoLive;

#[async_trait]
impl LiveSource for NoLive {
    async fn live(&self, _now: DateTime<Utc>) -> LiveInputs {
        LiveInputs {
            prs: PrsInput::Unavailable,
            jobs: Vec::new(),
        }
    }
}

/// The daemon's live inputs: one GitHub search for the user's PRs (when a
/// token resolves) and the in-daemon Mother job list.
pub struct DaemonLive {
    pub jobs: crate::mother::JobsFeed,
}

#[async_trait]
impl LiveSource for DaemonLive {
    async fn live(&self, now: DateTime<Utc>) -> LiveInputs {
        let prs = match crate::data::github_client::GithubClient::new(None) {
            Ok(gh) => match context::collectors::fetch_prs(
                &reqwest::Client::new(),
                crate::huey::sources::config::DEFAULT_GITHUB_API,
                gh.token(),
                now,
            )
            .await
            {
                Ok(prs) => PrsInput::Available(prs),
                Err(_) => PrsInput::Unavailable,
            },
            Err(_) => PrsInput::Unavailable,
        };
        let jobs = self.jobs.jobs_rx().borrow().clone();
        LiveInputs { prs, jobs }
    }
}

/// Everything a run needs.
pub struct RunEnv {
    pub paths: HueyPaths,
    pub config: HueyConfig,
    pub context: ContextEnv,
    pub http: HttpClient,
    pub curator: Arc<dyn Curator>,
    pub live: Arc<dyn LiveSource>,
    pub clock: Arc<dyn Clock>,
    pub local_time: Arc<dyn LocalTime>,
}

// ── The report frame ─────────────────────────────────────────────────────────

/// Everything about one run a report renders from, besides the publish.
#[derive(Debug, Clone, PartialEq)]
pub struct ReportFrame {
    pub date: NaiveDate,
    pub version: u32,
    pub mode: Mode,
    /// Every candidate story (before any tight trimming).
    pub clusters: Vec<Cluster>,
    /// Every item a report may cite or drop, by id.
    pub items: BTreeMap<String, NewsItem>,
    pub source_names: BTreeMap<String, String>,
    pub project_names: BTreeMap<String, String>,
    /// The footer before the model's drops and skip reason: sources, in
    /// flight, and the hard-ignore drops.
    pub footer: Footer,
}

impl ReportFrame {
    /// The ids of every story `ids` touch, best source first: the story's
    /// whole cluster, so the primary link and "Also covered by" are the
    /// daemon's call.
    fn expand(&self, ids: &[String]) -> Vec<&NewsItem> {
        let mut out: Vec<&NewsItem> = Vec::new();
        for id in ids {
            match self
                .clusters
                .iter()
                .find(|c| c.items.iter().any(|i| &i.id == id))
            {
                Some(c) => out.extend(c.items.iter()),
                None => out.extend(self.items.get(id)),
            }
        }
        let mut seen = BTreeSet::new();
        out.retain(|i| seen.insert(i.id.clone()));
        out.sort_by(|a, b| {
            a.class
                .cmp(&b.class)
                .then(a.published_at.cmp(&b.published_at))
                .then(a.id.cmp(&b.id))
        });
        out
    }

    fn source_name(&self, item: &NewsItem) -> String {
        self.source_names
            .get(&item.source_id)
            .cloned()
            .unwrap_or_else(|| item.source_id.clone())
    }
}

fn item_link(item: &NewsItem) -> Link {
    Link {
        title: item.title.clone(),
        url: item.url.clone(),
    }
}

fn source_link(frame: &ReportFrame, item: &NewsItem) -> Link {
    Link {
        title: frame.source_name(item),
        url: item.url.clone(),
    }
}

/// Text the model wrote, as the report carries it: one line, invisible and
/// control characters gone, capped.
fn model_text(text: &str, max: usize) -> String {
    one_line(text, max)
}

/// The report a (validated) publish renders to.
pub fn assemble_curated(frame: &ReportFrame, publish: &Publish) -> Report {
    let picks: Vec<Pick> = publish
        .picks
        .iter()
        .filter_map(|p| {
            let members = frame.expand(&p.item_ids);
            let (primary, rest) = members.split_first()?;
            Some(Pick {
                item_ids: members.iter().map(|i| i.id.clone()).collect(),
                headline: model_text(&p.headline, 120),
                what_happened: model_text(&p.what_happened, 400),
                project: p.project.clone(),
                project_name: frame
                    .project_names
                    .get(&p.project)
                    .cloned()
                    .unwrap_or_else(|| model_text(&p.project, 64)),
                for_line: model_text(&p.for_line, 400),
                check: match &p.check {
                    PublishCheck::Checked { text, .. } => PickCheck::Checked {
                        text: model_text(text, 300),
                    },
                    PublishCheck::ToCheck { text } => PickCheck::ToCheck {
                        text: model_text(text, 300),
                    },
                },
                link: item_link(primary),
                also_covered_by: rest.iter().map(|i| source_link(frame, i)).collect(),
                follow_up_of: p.follow_up_of.clone(),
                whats_new: p.whats_new.as_deref().map(|t| model_text(t, 300)),
            })
        })
        .collect();

    let also_in_the_news = publish.also_in_the_news.as_ref().and_then(|a| {
        let item = frame.items.get(&a.item_id)?;
        Some(AinLine {
            item_id: item.id.clone(),
            headline: model_text(&a.headline, 120),
            what_happened: model_text(&a.what_happened, 300),
            link: item_link(item),
        })
    });

    let mut also_noted: Vec<NotedLine> = Vec::new();
    if frame.mode != Mode::Tight {
        for n in &publish.also_noted {
            let members = frame.expand(&n.item_ids);
            let Some(primary) = members.first() else {
                continue;
            };
            let ids: Vec<String> = members.iter().map(|i| i.id.clone()).collect();
            // Chosen as the Also-in-the-news line: it moves up (AC43).
            if also_in_the_news
                .as_ref()
                .is_some_and(|a| ids.contains(&a.item_id))
            {
                continue;
            }
            also_noted.push(NotedLine {
                item_ids: ids,
                line: model_text(&n.line, 200),
                interest: n.interest.clone(),
                link: item_link(primary),
            });
        }
    }

    let mut report = Report {
        date: frame.date,
        version: frame.version,
        mode: frame.mode,
        opener_gist: model_text(&publish.opener_gist, 200),
        picks,
        also_in_the_news,
        also_noted,
        uncurated: None,
        footer: frame.footer.clone(),
    };
    let model_drops: Vec<FooterDrop> = publish
        .dropped
        .iter()
        .filter_map(|d| {
            let item = frame.items.get(&d.item_id)?;
            Some(FooterDrop {
                item_id: item.id.clone(),
                title: item.title.clone(),
                reason: model_text(&d.reason, 80),
            })
        })
        .collect();
    report.footer.dropped = footer_drops(&report, model_drops, &frame.footer.dropped);
    if report.also_in_the_news.is_none() {
        report.footer.ain_skip_reason = publish
            .ain_skip_reason
            .as_deref()
            .map(|r| model_text(r, 120))
            .filter(|r| !r.is_empty());
    }
    report
}

/// Model drops first, then hard-ignore drops; nothing shown anywhere, no
/// item twice.
fn footer_drops(report: &Report, model: Vec<FooterDrop>, hard: &[FooterDrop]) -> Vec<FooterDrop> {
    let shown: BTreeSet<&str> = report.shown_ids().into_iter().collect();
    let mut seen = BTreeSet::new();
    model
        .into_iter()
        .chain(hard.iter().cloned())
        .filter(|d| !shown.contains(d.item_id.as_str()) && seen.insert(d.item_id.clone()))
        .collect()
}

/// A critical-mode report: no model. The first-party headlines in the
/// window (at most [`UNCURATED_CAP`] plus "and N more") and the
/// Also-in-the-news line by rule (AC33, AC44).
pub fn assemble_uncurated(
    frame: &ReportFrame,
    candidates: &[NewsItem],
    ain_eligible: &[NewsItem],
) -> Report {
    let mut first_party: Vec<&NewsItem> = candidates
        .iter()
        .filter(|i| i.class == SourceClass::FirstParty)
        .collect();
    newest_first(&mut first_party);
    let lines: Vec<HeadlineLine> = first_party
        .iter()
        .take(UNCURATED_CAP)
        .map(|i| HeadlineLine {
            item_id: i.id.clone(),
            source: frame.source_name(i),
            link: item_link(i),
        })
        .collect();
    let more = first_party.len().saturating_sub(UNCURATED_CAP);
    let also_in_the_news = ain_by_rule(ain_eligible)
        .filter(|i| !lines.iter().any(|l| l.item_id == i.id))
        .map(|i| AinLine {
            item_id: i.id.clone(),
            headline: i.title.clone(),
            what_happened: String::new(),
            link: Link {
                title: frame.source_name(i),
                url: i.url.clone(),
            },
        });
    let mut report = Report {
        date: frame.date,
        version: frame.version,
        mode: frame.mode,
        opener_gist: String::new(),
        picks: Vec::new(),
        also_in_the_news,
        also_noted: Vec::new(),
        uncurated: Some(UncuratedList { lines, more }),
        footer: frame.footer.clone(),
    };
    report.footer.dropped = footer_drops(&report, Vec::new(), &frame.footer.dropped);
    report
}

/// The newest eligible item from the first of [`AIN_RULE_SOURCES`] that
/// has one.
pub fn ain_by_rule(eligible: &[NewsItem]) -> Option<&NewsItem> {
    AIN_RULE_SOURCES.iter().find_map(|source| {
        eligible
            .iter()
            .filter(|i| i.source_id == *source)
            .max_by(|a, b| {
                a.effective_time()
                    .cmp(&b.effective_time())
                    .then_with(|| b.id.cmp(&a.id))
            })
    })
}

fn newest_first(items: &mut [&NewsItem]) {
    items.sort_by(|a, b| {
        b.effective_time()
            .cmp(&a.effective_time())
            .then_with(|| a.id.cmp(&b.id))
    });
}

// ── Eligibility ──────────────────────────────────────────────────────────────

/// What survives the deterministic filters.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Selection {
    /// In the window, not shown in the last 14 days (uncurated listings
    /// aside), no hard-ignore term in the title. Newest first.
    pub candidates: Vec<NewsItem>,
    /// Items removed by a hard-ignore term, as "ignored: <term>".
    pub hard_drops: Vec<FooterDrop>,
    /// The Also-in-the-news eligible set before this report's picks and the
    /// model's `ignored` come out (A7).
    pub ain_eligible: Vec<NewsItem>,
}

/// Apply the ledger and the hard-ignore terms to a fetch.
pub fn select(
    fetched: &FetchOutcome,
    interests: &Interests,
    ledger: &Ledger,
    date: NaiveDate,
) -> Selection {
    let mut out = Selection::default();
    for item in &fetched.items {
        if ledger.blocks_candidate(&item.id, date) {
            continue;
        }
        if let Some(term) = interests.hard_term_in(&item.title) {
            out.hard_drops.push(FooterDrop {
                item_id: item.id.clone(),
                title: item.title.clone(),
                reason: format!("ignored: {term}"),
            });
            continue;
        }
        out.candidates.push(item.clone());
    }
    out.ain_eligible = ain_eligible(&fetched.recent, interests, ledger, date);
    out
}

/// First-party items of the last 7 days (the fetch's `recent` pool), minus
/// anything shown in the last 14 days in any section and anything
/// hard-ignored. Aggregator and blog items are never eligible (AC41).
pub fn ain_eligible(
    recent: &[NewsItem],
    interests: &Interests,
    ledger: &Ledger,
    date: NaiveDate,
) -> Vec<NewsItem> {
    recent
        .iter()
        .filter(|i| i.class == SourceClass::FirstParty)
        .filter(|i| !ledger.blocks_ain(&i.id, date))
        .filter(|i| interests.hard_term_in(&i.title).is_none())
        .cloned()
        .collect()
}

/// Fetch failed: no first-party source answered (ok or quiet).
pub fn fetch_failed(statuses: &[SourceStatus]) -> bool {
    !statuses.iter().any(|s| {
        s.class == SourceClass::FirstParty
            && matches!(s.outcome, SourceOutcome::Ok { .. } | SourceOutcome::Quiet)
    })
}

/// The footer's source lines (A7).
pub fn base_footer(
    fetched: &FetchOutcome,
    in_flight: Vec<String>,
    posture: &PostureNote,
) -> Footer {
    let answered =
        |s: &&SourceStatus| matches!(s.outcome, SourceOutcome::Ok { .. } | SourceOutcome::Quiet);
    Footer {
        looked_at: fetched.items.len(),
        sources_read: fetched.statuses.iter().filter(answered).count(),
        read_in_full: fetched
            .statuses
            .iter()
            .filter(answered)
            .filter(|s| s.class == SourceClass::FirstParty)
            .map(|s| s.name.clone())
            .collect(),
        quiet: fetched
            .statuses
            .iter()
            .filter(|s| s.outcome == SourceOutcome::Quiet)
            .map(|s| s.name.clone())
            .collect(),
        failed: fetched
            .statuses
            .iter()
            .filter_map(|s| match &s.outcome {
                SourceOutcome::Failed { reason } => Some(FailedSource {
                    name: s.name.clone(),
                    reason: reason.clone(),
                }),
                _ => None,
            })
            .collect(),
        in_flight,
        dropped: Vec::new(),
        ain_skip_reason: None,
        posture_unavailable: !posture.available(),
    }
}

/// Every first-party story, plus the newest [`TIGHT_OTHER_CLUSTERS`] others.
fn trim_for_tight(clusters: &[Cluster]) -> Vec<Cluster> {
    let mut others = 0;
    clusters
        .iter()
        .filter(|c| {
            c.primary().class == SourceClass::FirstParty || {
                others += 1;
                others <= TIGHT_OTHER_CLUSTERS
            }
        })
        .cloned()
        .collect()
}

fn ledger_entries(report: &Report, frame: &ReportFrame) -> Vec<LedgerEntry> {
    let entry = |id: &str, section: Section| LedgerEntry {
        item_id: id.to_string(),
        canonical_url: frame
            .items
            .get(id)
            .map(|i| i.canonical_url.clone())
            .unwrap_or_default(),
        date: report.date,
        version: report.version,
        section,
    };
    let mut out = Vec::new();
    for p in &report.picks {
        out.extend(p.item_ids.iter().map(|id| entry(id, Section::Pick)));
    }
    if let Some(a) = &report.also_in_the_news {
        // The rule-chosen line of a critical report was never curated: it
        // blocks only the Also-in-the-news line, like the list (D4).
        let section = if report.is_uncurated() {
            Section::Uncurated
        } else {
            Section::Ain
        };
        out.push(entry(&a.item_id, section));
    }
    for n in &report.also_noted {
        out.extend(n.item_ids.iter().map(|id| entry(id, Section::AlsoNoted)));
    }
    if let Some(list) = &report.uncurated {
        out.extend(
            list.lines
                .iter()
                .map(|l| entry(&l.item_id, Section::Uncurated)),
        );
    }
    out
}

// ── The run ──────────────────────────────────────────────────────────────────

/// One attempt's fixed inputs, with the steps that need them and the run log.
struct Attempt<'a> {
    env: &'a RunEnv,
    trigger: Trigger,
    now: DateTime<Utc>,
    date: NaiveDate,
    started: Instant,
    store: Store,
}

/// The digest, and the in-flight projects it was built from.
struct Gathered {
    digest: Digest,
    projects: Vec<ProjectContext>,
}

impl Gathered {
    fn project_names(&self) -> BTreeMap<String, String> {
        self.projects
            .iter()
            .map(|p| (p.id.clone(), p.name.clone()))
            .collect()
    }
}

impl Attempt<'_> {
    fn log(
        &self,
        mode: Option<Mode>,
        reason: Option<FailReason>,
        version: Option<u32>,
        fetch_ms: u64,
    ) {
        let rec = RunRecord {
            // When the attempt ended: the retry and the scheduler's guard
            // both count from here.
            at: self.env.clock.now(),
            date: self.date,
            trigger: self.trigger,
            mode,
            outcome: if reason.is_some() {
                RunResult::Failed
            } else {
                RunResult::Produced
            },
            reason,
            version,
            fetch_ms,
            total_ms: self.started.elapsed().as_millis() as u64,
        };
        if self.store.append_run(&rec).is_err() {
            warn!("huey: run log could not be written");
        }
    }

    /// Log a failed attempt and say so.
    fn fail(&self, mode: Option<Mode>, reason: FailReason, fetch_ms: u64) -> RunOutcome {
        self.log(mode, Some(reason), None, fetch_ms);
        RunOutcome::Failed { reason }
    }

    /// The window starts where the last curated report's ended (D4).
    fn window_start(&self) -> DateTime<Utc> {
        self.store
            .last_curated_before(self.date)
            .map(|m| m.window_end)
            .unwrap_or(self.now - Duration::days(FIRST_RUN_DAYS))
    }

    /// Fetch, or reuse today's frozen pool when regenerating.
    async fn fetch_or_pool(&self, window_start: DateTime<Utc>) -> FetchOutcome {
        let paths = &self.env.paths;
        let frozen = match self.trigger {
            Trigger::Regenerate => load_pool(&paths.pool_dir(), self.date),
            _ => None,
        };
        if let Some(pool) = frozen {
            return pool;
        }
        let (cfg, warnings) = load_file(&paths.sources_toml());
        if !warnings.is_empty() {
            warn!(count = warnings.len(), "huey: sources.toml warnings");
        }
        // The window is exclusive of its start: an item first seen (or
        // clamped to) the previous run's fetch time was in that window.
        fetch_all(
            &cfg,
            &paths.state_dir(),
            window_start + Duration::nanoseconds(1),
            self.now,
            &self.env.http,
        )
        .await
    }

    /// Gather the context and build the digest for this version.
    async fn gather_digest(
        &self,
        interests: &Interests,
        posture: &PostureNote,
        version: u32,
    ) -> Gathered {
        let live = self.env.live.live(self.now).await;
        let profiles = self.env.paths.state_dir().join("profiles");
        let mut inputs = context::gather(
            &self.env.context,
            interests,
            &live,
            Some(&profiles),
            self.now,
        );
        inputs.date = self.date;
        inputs.version = version;
        inputs.mode = Some(posture.mode_line());
        Gathered {
            digest: build_digest(&inputs),
            projects: inputs.projects,
        }
    }

    /// The model pass. `None` when it failed; the version is discarded.
    async fn curate(
        &self,
        frame: &ReportFrame,
        selection: &Selection,
        gathered: &Gathered,
        ledger: &Ledger,
    ) -> Option<(Report, String)> {
        let (date, version, mode) = (frame.date, frame.version, frame.mode);
        let config = &self.env.config;
        if self
            .store
            .write_report_file(date, version, "digest.md", gathered.digest.text.as_bytes())
            .is_err()
        {
            warn!("huey: digest could not be written");
        }
        let tight = mode == Mode::Tight;
        let (model, max_budget_usd) = if tight {
            (config.tight_model.clone(), config.tight_max_budget_usd)
        } else {
            (config.model.clone(), config.max_budget_usd)
        };
        let input = CurateInput {
            date,
            version,
            mode,
            model: model.clone(),
            max_budget_usd,
            max_picks: if tight { TIGHT_MAX_PICKS } else { MAX_PICKS },
            also_noted: !tight,
            digest: gathered.digest.clone(),
            candidates: if tight {
                trim_for_tight(&frame.clusters)
            } else {
                frame.clusters.clone()
            },
            ain_candidates: selection.ain_eligible.clone(),
            recent_shown: ledger.recent(date).cloned().collect(),
            project_roots: gathered
                .projects
                .iter()
                .map(|p| (p.id.clone(), p.root.clone()))
                .collect(),
            report_dir: self.store.report_dir(date, version),
            frame: frame.clone(),
        };
        match self.env.curator.curate(&input).await {
            Ok(publish) => Some((assemble_curated(frame, &publish), model)),
            Err(e) => {
                info!(
                    unavailable = matches!(e, CurateError::Unavailable),
                    "huey: model failed"
                );
                self.store.discard_version(date, version);
                None
            }
        }
    }

    /// Write the report, then record it in the ledger. `Err` when the report
    /// could not be written; the version is discarded. The digest as shown
    /// includes any checks the curator appended.
    fn persist(
        &self,
        meta: &ReportMeta,
        report: &Report,
        frame: &ReportFrame,
        digest_text: &str,
    ) -> Result<(), ()> {
        let markdown = render::render_markdown(report);
        let files = ReportFiles {
            meta,
            report,
            markdown: &markdown,
            digest: digest_text,
        };
        if self.store.write_report(&files).is_err() {
            warn!("huey: report could not be written");
            self.store.discard_version(self.date, frame.version);
            return Err(());
        }
        let mut ledger = self.store.ledger();
        ledger.replace_date(self.date, ledger_entries(report, frame));
        if self.store.save_ledger(&ledger).is_err() {
            warn!("huey: ledger could not be written");
        }
        Ok(())
    }
}

/// Everything a report renders from, besides the publish.
fn build_frame(
    date: NaiveDate,
    version: u32,
    mode: Mode,
    fetched: &FetchOutcome,
    selection: &Selection,
    gathered: &Gathered,
    posture: &PostureNote,
) -> ReportFrame {
    let project_names = gathered.project_names();
    let in_flight = gathered
        .digest
        .projects
        .iter()
        .map(|id| project_names.get(id).cloned().unwrap_or_else(|| id.clone()))
        .collect();
    let mut footer = base_footer(fetched, in_flight, posture);
    footer.dropped = selection.hard_drops.clone();
    ReportFrame {
        date,
        version,
        mode,
        clusters: cluster(&selection.candidates),
        items: fetched
            .items
            .iter()
            .chain(&selection.ain_eligible)
            .map(|i| (i.id.clone(), i.clone()))
            .collect(),
        source_names: fetched
            .statuses
            .iter()
            .map(|s| (s.id.clone(), s.name.clone()))
            .collect(),
        project_names,
        footer,
    }
}

/// One attempt at today's report: window, fetch, select, digest, curate or
/// list, persist.
pub async fn run(env: &RunEnv, trigger: Trigger, late_reason: Option<String>) -> RunOutcome {
    run_as_of(env, trigger, late_reason, env.clock.now()).await
}

/// One attempt, for the report date `now` belongs to. The scheduler passes
/// the `now` it decided on, so both agree on the date near midnight.
pub async fn run_as_of(
    env: &RunEnv,
    trigger: Trigger,
    late_reason: Option<String>,
    now: DateTime<Utc>,
) -> RunOutcome {
    if setup::load(&env.paths).state != SetupState::Confirmed || !env.paths.root().is_dir() {
        return RunOutcome::Failed {
            reason: FailReason::NotSetUp,
        };
    }
    let date = Schedule::from_config(&env.config).report_date(now, env.local_time.as_ref());
    let attempt = Attempt {
        env,
        trigger,
        now,
        date,
        started: Instant::now(),
        store: Store::new(env.paths.clone()),
    };
    let store = &attempt.store;

    let window_start = attempt.window_start();

    let fetch_started = Instant::now();
    let fetched = attempt.fetch_or_pool(window_start).await;
    let fetch_ms = fetch_started.elapsed().as_millis() as u64;
    if fetch_failed(&fetched.statuses) {
        info!(sources = fetched.statuses.len(), "huey: fetch failed");
        return attempt.fail(None, FailReason::FetchFailed, fetch_ms);
    }
    if save_pool(&env.paths.pool_dir(), date, &fetched).is_err() {
        warn!("huey: pool could not be saved");
    }

    let interests = std::fs::read_to_string(env.paths.interests())
        .map(|t| interests::parse(&t))
        .unwrap_or_default();
    let ledger = store.ledger();
    let selection = select(&fetched, &interests, &ledger, date);

    let posture = budget::assess(&env.context.posture_file(), &env.config, now);
    let mode = posture.mode;
    let version = store.next_version(date);
    let gathered = attempt.gather_digest(&interests, &posture, version).await;
    let frame = build_frame(
        date, version, mode, &fetched, &selection, &gathered, &posture,
    );

    let (report, model) = if mode.is_curated() {
        match attempt.curate(&frame, &selection, &gathered, &ledger).await {
            Some((report, model)) => (report, Some(model)),
            None => return attempt.fail(Some(mode), FailReason::ModelFailed, fetch_ms),
        }
    } else {
        (
            assemble_uncurated(&frame, &selection.candidates, &selection.ain_eligible),
            None,
        )
    };

    let digest_text = store
        .load_digest(date, version)
        .unwrap_or_else(|| gathered.digest.text.clone());
    let meta = ReportMeta {
        date,
        version,
        generated_at: now,
        trigger,
        mode,
        posture: posture.posture.clone(),
        model,
        window_start,
        window_end: fetched.fetched_at.unwrap_or(now),
        late_reason,
    };
    if attempt
        .persist(&meta, &report, &frame, &digest_text)
        .is_err()
    {
        return attempt.fail(Some(mode), FailReason::WriteFailed, fetch_ms);
    }
    attempt.log(Some(mode), None, Some(version), fetch_ms);
    let pruned = store.prune(date);
    info!(
        version,
        mode = mode.as_str(),
        picks = report.picks.len(),
        candidates = selection.candidates.len(),
        pruned_reports = pruned.report_dates,
        "huey: report produced"
    );
    RunOutcome::Produced {
        date,
        version,
        mode,
    }
}
