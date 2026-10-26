//! Huey's on-disk record: reports by date and version, the 14-day ledger,
//! the run log, verdicts, and retention.
//!
//! ```text
//! reports/<YYYY-MM-DD>/v<n>/{meta.json, report.json, report.md, digest.md,
//!                           model-input.txt, checks.json}
//! reports/<YYYY-MM-DD>/verdicts.json
//! state/ledger.json
//! state/runs.jsonl
//! ```
//!
//! Every write is atomic (temp file plus rename, owner-only modes) and is
//! refused when the Huey root does not exist: a Huey that was never set up
//! leaves no trace (T6). Reads never fail: a missing or damaged file is
//! "nothing there".

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::huey::budget::Mode;
use crate::huey::paths::HueyPaths;
use crate::huey::render::Report;
use crate::huey::run::{FailReason, Trigger};
use crate::huey::schedule::DayRuns;

/// Reports (and their verdicts) are kept this many days (AC29 needs 30).
pub const REPORT_KEEP_DAYS: i64 = 60;
/// The frozen daily pools are kept this many days.
pub const POOL_KEEP_DAYS: i64 = 30;
/// Ledger entries are kept this many days.
pub const LEDGER_KEEP_DAYS: i64 = 30;
/// Run-log lines are kept this many days.
pub const RUNS_KEEP_DAYS: i64 = 90;
/// An item shown on a date is not shown again for this many days.
pub const LEDGER_BLOCK_DAYS: i64 = 14;

// ── Reports ──────────────────────────────────────────────────────────────────

/// `meta.json`: how one report version came to be.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReportMeta {
    pub date: NaiveDate,
    pub version: u32,
    pub generated_at: DateTime<Utc>,
    pub trigger: Trigger,
    pub mode: Mode,
    /// Bishop's posture line, `None` when unavailable.
    pub posture: Option<String>,
    /// The model that curated it; `None` for an uncurated (critical) report.
    pub model: Option<String>,
    /// Exclusive: the window is `(window_start, window_end]`.
    pub window_start: DateTime<Utc>,
    /// When the report's items were fetched (for a regeneration on the
    /// frozen pool, the original fetch). The next window starts here.
    pub window_end: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub late_reason: Option<String>,
}

impl ReportMeta {
    /// Curated reports (normal and tight) move the window; uncurated ones do
    /// not (D4).
    pub fn curated(&self) -> bool {
        self.mode.is_curated()
    }
}

/// The files one report version is written as.
pub struct ReportFiles<'a> {
    pub meta: &'a ReportMeta,
    pub report: &'a Report,
    pub markdown: &'a str,
    pub digest: &'a str,
}

// ── Ledger ───────────────────────────────────────────────────────────────────

/// Where an item was shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Section {
    Pick,
    Ain,
    AlsoNoted,
    /// In a critical-mode headline list. Blocks the Also-in-the-news line,
    /// not picks or Also noted (D4).
    Uncurated,
}

impl Section {
    /// The name the ledger file and the model's recent-reports list use.
    pub fn as_str(self) -> &'static str {
        match self {
            Section::Pick => "pick",
            Section::Ain => "ain",
            Section::AlsoNoted => "also_noted",
            Section::Uncurated => "uncurated",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub item_id: String,
    pub canonical_url: String,
    pub date: NaiveDate,
    pub version: u32,
    pub section: Section,
    /// The headline the report showed for the item (Huey's own words for a
    /// curated pick or line, the source's title in a headline list). Absent
    /// in entries written before it was stored: readers fall back to the
    /// item's own title when they have it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// Every item shown anywhere in the last [`LEDGER_KEEP_DAYS`] days.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ledger {
    #[serde(default)]
    pub entries: Vec<LedgerEntry>,
}

impl Ledger {
    /// Entries from the 14 days before `date` (never `date` itself: a
    /// regeneration replaces that date's entries).
    pub fn recent(&self, date: NaiveDate) -> impl Iterator<Item = &LedgerEntry> {
        self.entries.iter().filter(move |e| {
            let days = (date - e.date).num_days();
            days > 0 && days < LEDGER_BLOCK_DAYS
        })
    }

    /// Is `item_id` kept out of picks and Also noted on `date`? Shown in a
    /// curated section in the last 14 days. Uncurated listings do not count
    /// (D4).
    pub fn blocks_candidate(&self, item_id: &str, date: NaiveDate) -> bool {
        self.recent(date)
            .any(|e| e.item_id == item_id && e.section != Section::Uncurated)
    }

    /// Is `item_id` kept off the Also-in-the-news line on `date`? Shown
    /// anywhere in the last 14 days, uncurated listings included (AC43).
    pub fn blocks_ain(&self, item_id: &str, date: NaiveDate) -> bool {
        self.recent(date).any(|e| e.item_id == item_id)
    }

    /// Replace `date`'s entries with `entries` (a regeneration's version
    /// replaces the earlier one's).
    pub fn replace_date(&mut self, date: NaiveDate, entries: Vec<LedgerEntry>) {
        self.entries.retain(|e| e.date != date);
        self.entries.extend(entries);
    }

    /// Forget entries more than [`LEDGER_KEEP_DAYS`] before `today`.
    pub fn prune(&mut self, today: NaiveDate) -> usize {
        let before = self.entries.len();
        self.entries
            .retain(|e| (today - e.date).num_days() <= LEDGER_KEEP_DAYS);
        before - self.entries.len()
    }
}

// ── Run log ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunResult {
    Produced,
    Failed,
}

/// One line of `runs.jsonl`: one attempt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunRecord {
    pub at: DateTime<Utc>,
    /// The report date the attempt was for.
    pub date: NaiveDate,
    pub trigger: Trigger,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<Mode>,
    pub outcome: RunResult,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<FailReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    #[serde(default)]
    pub fetch_ms: u64,
    #[serde(default)]
    pub total_ms: u64,
    /// Ids the curator named that the run never issued (dropped from the
    /// report). A count only, never the ids.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub unknown_ids: u32,
    /// Candidate stories and Also-in-the-news candidates left out of the
    /// model input to keep it within its byte budget. A count only.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub trimmed: u32,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

// ── Verdicts ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VerdictKind {
    Useful,
    Interesting,
    Meh,
    Hype,
    WrongProject,
}

/// One entry of `verdicts.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Verdict {
    pub version: u32,
    /// 1-based pick number within the version.
    pub pick: u32,
    pub item_id: String,
    pub verdict: VerdictKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub at: DateTime<Utc>,
}

// ── Store ────────────────────────────────────────────────────────────────────

/// What [`Store::prune`] removed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Pruned {
    pub report_dates: usize,
    pub pools: usize,
    pub ledger_entries: usize,
    pub runs: usize,
}

#[derive(Debug, Clone)]
pub struct Store {
    paths: HueyPaths,
}

impl Store {
    pub fn new(paths: HueyPaths) -> Self {
        Self { paths }
    }

    pub fn paths(&self) -> &HueyPaths {
        &self.paths
    }

    pub fn date_dir(&self, date: NaiveDate) -> PathBuf {
        self.paths.reports_dir().join(date.to_string())
    }

    pub fn report_dir(&self, date: NaiveDate, version: u32) -> PathBuf {
        self.date_dir(date).join(format!("v{version}"))
    }

    pub fn ledger_file(&self) -> PathBuf {
        self.paths.state_dir().join("ledger.json")
    }

    pub fn runs_file(&self) -> PathBuf {
        self.paths.state_dir().join("runs.jsonl")
    }

    pub fn verdicts_file(&self, date: NaiveDate) -> PathBuf {
        self.date_dir(date).join("verdicts.json")
    }

    /// The finished versions of `date` (those with a `report.json`), ascending.
    pub fn versions(&self, date: NaiveDate) -> Vec<u32> {
        let mut out: Vec<u32> = version_dirs(&self.date_dir(date))
            .into_iter()
            .filter(|v| self.report_dir(date, *v).join("report.json").is_file())
            .collect();
        out.sort_unstable();
        out
    }

    pub fn latest_version(&self, date: NaiveDate) -> Option<u32> {
        self.versions(date).last().copied()
    }

    /// The number the next version of `date` gets: one past every version
    /// directory there, finished or not.
    pub fn next_version(&self, date: NaiveDate) -> u32 {
        version_dirs(&self.date_dir(date))
            .into_iter()
            .max()
            .unwrap_or(0)
            + 1
    }

    /// Every date with at least one finished report, newest first.
    pub fn dates(&self) -> Vec<NaiveDate> {
        let mut out: Vec<NaiveDate> = dated_entries(&self.paths.reports_dir())
            .into_keys()
            .filter(|d| !self.versions(*d).is_empty())
            .collect();
        out.sort_unstable_by(|a, b| b.cmp(a));
        out
    }

    /// The newest date before `date` with a finished report.
    pub fn latest_before(&self, date: NaiveDate) -> Option<NaiveDate> {
        self.dates().into_iter().find(|d| *d < date)
    }

    pub fn load_meta(&self, date: NaiveDate, version: u32) -> Option<ReportMeta> {
        read_json(&self.report_dir(date, version).join("meta.json"))
    }

    pub fn load_report(&self, date: NaiveDate, version: u32) -> Option<Report> {
        read_json(&self.report_dir(date, version).join("report.json"))
    }

    pub fn load_markdown(&self, date: NaiveDate, version: u32) -> Option<String> {
        std::fs::read_to_string(self.report_dir(date, version).join("report.md")).ok()
    }

    pub fn load_digest(&self, date: NaiveDate, version: u32) -> Option<String> {
        std::fs::read_to_string(self.report_dir(date, version).join("digest.md")).ok()
    }

    /// The newest curated report dated before `date`: the report window
    /// starts at its `window_end` (D4). Earlier versions and uncurated
    /// reports are skipped.
    pub fn last_curated_before(&self, date: NaiveDate) -> Option<ReportMeta> {
        self.dates()
            .into_iter()
            .filter(|d| *d < date)
            .flat_map(|d| {
                let mut versions = self.versions(d);
                versions.reverse();
                versions.into_iter().map(move |v| (d, v))
            })
            .filter_map(|(d, v)| self.load_meta(d, v))
            .find(ReportMeta::curated)
    }

    /// Write one file into a version's directory (creating it). Refused when
    /// Huey is not set up.
    pub fn write_report_file(
        &self,
        date: NaiveDate,
        version: u32,
        name: &str,
        bytes: &[u8],
    ) -> io::Result<()> {
        self.write(&self.report_dir(date, version).join(name), bytes)
    }

    /// Write a finished report version. `report.json` goes last, so a
    /// version is never listed before its other files exist.
    pub fn write_report(&self, files: &ReportFiles<'_>) -> io::Result<()> {
        let (date, version) = (files.meta.date, files.meta.version);
        self.write_report_file(date, version, "digest.md", files.digest.as_bytes())?;
        self.write_report_file(date, version, "report.md", files.markdown.as_bytes())?;
        self.write_report_file(date, version, "meta.json", &pretty_json(files.meta)?)?;
        self.write_report_file(date, version, "report.json", &pretty_json(files.report)?)
    }

    /// Remove a version directory left by a failed attempt.
    pub fn discard_version(&self, date: NaiveDate, version: u32) {
        let dir = self.report_dir(date, version);
        if !dir.join("report.json").exists() {
            let _ = std::fs::remove_dir_all(&dir);
            // Leave no empty date directory behind.
            let _ = std::fs::remove_dir(self.date_dir(date));
        }
    }

    pub fn ledger(&self) -> Ledger {
        read_json(&self.ledger_file()).unwrap_or_default()
    }

    pub fn save_ledger(&self, ledger: &Ledger) -> io::Result<()> {
        self.write(
            &self.ledger_file(),
            &serde_json::to_vec(ledger).map_err(io::Error::other)?,
        )
    }

    /// Every readable line of `runs.jsonl`, oldest first.
    pub fn runs(&self) -> Vec<RunRecord> {
        std::fs::read_to_string(self.runs_file())
            .map(|text| {
                text.lines()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Append one attempt to `runs.jsonl`.
    pub fn append_run(&self, record: &RunRecord) -> io::Result<()> {
        let mut runs = self.runs();
        runs.push(record.clone());
        self.write_runs(&runs)
    }

    /// What happened for `date` so far.
    pub fn day_runs(&self, date: NaiveDate) -> DayRuns {
        let mut day = DayRuns::default();
        for r in self.runs().into_iter().filter(|r| r.date == date) {
            match (r.outcome, r.reason) {
                (RunResult::Produced, _) => day.produced = true,
                (RunResult::Failed, Some(reason)) => day.failures.push((r.at, reason)),
                (RunResult::Failed, None) => {}
            }
        }
        day.produced |= self.latest_version(date).is_some();
        day
    }

    pub fn verdicts(&self, date: NaiveDate) -> Vec<Verdict> {
        read_json(&self.verdicts_file(date)).unwrap_or_default()
    }

    /// Add a verdict to `date`'s list. The report must exist.
    pub fn record_verdict(&self, date: NaiveDate, verdict: Verdict) -> io::Result<()> {
        if !self.versions(date).contains(&verdict.version) {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no such report"));
        }
        let mut all = self.verdicts(date);
        all.push(verdict);
        self.write(
            &self.verdicts_file(date),
            &serde_json::to_vec(&all).map_err(io::Error::other)?,
        )
    }

    /// Retention: reports (with their verdicts) older than
    /// [`REPORT_KEEP_DAYS`], pools older than [`POOL_KEEP_DAYS`], ledger
    /// entries older than [`LEDGER_KEEP_DAYS`] and run-log lines older than
    /// [`RUNS_KEEP_DAYS`]. Per-source item state prunes itself at fetch time
    /// (90 days).
    pub fn prune(&self, today: NaiveDate) -> Pruned {
        let mut pruned = Pruned::default();
        for (date, path) in dated_entries(&self.paths.reports_dir()) {
            if (today - date).num_days() > REPORT_KEEP_DAYS
                && std::fs::remove_dir_all(&path).is_ok()
            {
                pruned.report_dates += 1;
            }
        }
        pruned.pools =
            crate::huey::sources::prune_pool(&self.paths.pool_dir(), today, POOL_KEEP_DAYS);
        let mut ledger = self.ledger();
        pruned.ledger_entries = ledger.prune(today);
        if pruned.ledger_entries > 0 {
            let _ = self.save_ledger(&ledger);
        }
        let runs = self.runs();
        let kept: Vec<RunRecord> = runs
            .iter()
            .filter(|r| (today - r.date).num_days() <= RUNS_KEEP_DAYS)
            .cloned()
            .collect();
        pruned.runs = runs.len() - kept.len();
        if pruned.runs > 0 {
            let _ = self.write_runs(&kept);
        }
        pruned
    }

    fn write_runs(&self, runs: &[RunRecord]) -> io::Result<()> {
        let mut text = String::new();
        for r in runs {
            text.push_str(&serde_json::to_string(r).map_err(io::Error::other)?);
            text.push('\n');
        }
        self.write(&self.runs_file(), text.as_bytes())
    }

    fn write(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        if !self.paths.root().is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "huey is not set up: no state root",
            ));
        }
        crate::huey::setup::write_atomic(path, bytes)
    }
}

fn pretty_json<T: Serialize>(value: &T) -> io::Result<Vec<u8>> {
    serde_json::to_vec_pretty(value).map_err(io::Error::other)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// `v<n>` directory numbers under `dir`.
fn version_dirs(dir: &Path) -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| {
            e.file_name()
                .to_str()
                .and_then(|n| n.strip_prefix('v'))
                .and_then(|n| n.parse().ok())
        })
        .collect()
}

/// `<YYYY-MM-DD>` directories under `dir`.
fn dated_entries(dir: &Path) -> BTreeMap<NaiveDate, PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return BTreeMap::new();
    };
    entries
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| {
            let date = e.file_name().to_str()?.parse::<NaiveDate>().ok()?;
            Some((date, e.path()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, day).unwrap()
    }

    fn entry(id: &str, date: NaiveDate, section: Section) -> LedgerEntry {
        LedgerEntry {
            item_id: id.into(),
            canonical_url: format!("https://x.test/{id}"),
            date,
            version: 1,
            section,
            title: None,
        }
    }

    #[test]
    fn the_ledger_blocks_for_fourteen_days_and_not_on_its_own_date() {
        let ledger = Ledger {
            entries: vec![entry("a", d(1), Section::Pick)],
        };
        assert!(!ledger.blocks_candidate("a", d(1)));
        assert!(ledger.blocks_candidate("a", d(2)));
        assert!(ledger.blocks_candidate("a", d(14)));
        assert!(!ledger.blocks_candidate("a", d(15)));
        assert!(!ledger.blocks_candidate("b", d(2)));
    }

    #[test]
    fn a_ledger_written_before_titles_existed_still_reads_and_a_missing_title_is_not_written() {
        let old = r#"{"entries":[{"item_id":"a","canonical_url":"u","date":"2026-10-01","version":1,"section":"pick"}]}"#;
        let ledger: Ledger = serde_json::from_str(old).unwrap();
        assert_eq!(ledger.entries.len(), 1);
        assert_eq!(ledger.entries[0].title, None);
        assert_eq!(serde_json::to_string(&ledger).unwrap(), old);

        let mut titled = entry("b", d(2), Section::Ain);
        titled.title = Some("A headline".into());
        let back: LedgerEntry =
            serde_json::from_str(&serde_json::to_string(&titled).unwrap()).unwrap();
        assert_eq!(back.title.as_deref(), Some("A headline"));
    }

    #[test]
    fn uncurated_entries_block_only_the_also_in_the_news_line() {
        let ledger = Ledger {
            entries: vec![entry("a", d(1), Section::Uncurated)],
        };
        assert!(!ledger.blocks_candidate("a", d(2)));
        assert!(ledger.blocks_ain("a", d(2)));
    }

    #[test]
    fn nothing_is_written_without_a_root() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(HueyPaths::new(tmp.path()));
        assert!(store.save_ledger(&Ledger::default()).is_err());
        assert!(store
            .append_run(&RunRecord {
                at: Utc::now(),
                date: d(1),
                trigger: Trigger::Scheduled,
                mode: None,
                outcome: RunResult::Failed,
                reason: Some(FailReason::FetchFailed),
                version: None,
                fetch_ms: 0,
                total_ms: 0,
                unknown_ids: 0,
                trimmed: 0,
            })
            .is_err());
        assert_eq!(std::fs::read_dir(tmp.path()).unwrap().count(), 0);
    }
}
