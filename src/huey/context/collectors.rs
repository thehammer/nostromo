//! Context collectors. Each takes explicit paths (so tests inject fixture
//! machines) and keeps only what the digest may carry: titles, states, ids,
//! counts and posture numbers. Bodies, notes, prose and file contents are
//! never kept.

use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDate, Utc};
use serde::Deserialize;

use crate::data::work::untrusted::one_line;
use crate::mother::MotherJob;
use crate::tracker::Status;

/// Longest title kept from any source.
pub const MAX_TITLE_CHARS: usize = 120;
/// Open item titles shown per board.
const BOARD_TITLES: usize = 3;

// ── Tracker boards ───────────────────────────────────────────────────────────

/// One tracker board: its topic, root and open item titles.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoardSummary {
    pub topic: String,
    /// The repository root the board was opened under.
    pub root: Option<PathBuf>,
    /// The board file.
    pub path: PathBuf,
    /// Items not done.
    pub open: usize,
    /// The first open item titles, in board order.
    pub open_titles: Vec<String>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
struct TrackerState {
    #[serde(default)]
    boards: std::collections::BTreeMap<String, TrackerBoard>,
}

#[derive(Deserialize)]
struct TrackerBoard {
    #[serde(default)]
    topic: String,
    #[serde(default)]
    root: Option<String>,
}

/// The boards listed in `<state_root>/trackers/state.json`, each re-read from
/// its own file through the tracker parser. Unreadable boards are skipped.
/// Sorted by topic, then path.
pub fn tracker_boards(state_root: &Path) -> Vec<BoardSummary> {
    let Some(state) = std::fs::read(state_root.join("trackers").join("state.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<TrackerState>(&b).ok())
    else {
        return Vec::new();
    };
    let mut out: Vec<BoardSummary> = state
        .boards
        .into_iter()
        .filter_map(|(path, entry)| {
            let path = PathBuf::from(path);
            let bytes = std::fs::read(&path).ok()?;
            let board = crate::tracker::parse(&bytes).ok()?.board;
            let open: Vec<&crate::tracker::Item> = board
                .items
                .iter()
                .filter(|i| i.status != Status::Done)
                .collect();
            let topic = if entry.topic.is_empty() {
                path.file_stem()?.to_string_lossy().into_owned()
            } else {
                entry.topic
            };
            Some(BoardSummary {
                topic: one_line(&topic, 64),
                root: entry.root.map(PathBuf::from),
                open: open.len(),
                open_titles: open
                    .iter()
                    .take(BOARD_TITLES)
                    .map(|i| one_line(&i.text, 60))
                    .collect(),
                updated_at: board.updated_at(),
                path,
            })
        })
        .collect();
    out.sort_by(|a, b| a.topic.cmp(&b.topic).then_with(|| a.path.cmp(&b.path)));
    out
}

// ── Pull requests ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrState {
    Open,
    Merged,
}

/// One of the user's pull requests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrRecord {
    /// Repository name (lower-cased), e.g. `nostromo`.
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub state: PrState,
    /// Merge time for merged PRs, last update for open ones.
    pub at: DateTime<Utc>,
}

/// PRs as the digest receives them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrsInput {
    /// No token, or the search failed: the digest says "PRs unavailable".
    Unavailable,
    Available(Vec<PrRecord>),
}

#[derive(Deserialize)]
struct SearchPage {
    #[serde(default)]
    items: Vec<SearchItem>,
}

#[derive(Deserialize)]
struct SearchItem {
    number: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    state: String,
    repository_url: String,
    updated_at: DateTime<Utc>,
    #[serde(default)]
    pull_request: Option<SearchPr>,
}

#[derive(Deserialize)]
struct SearchPr {
    #[serde(default)]
    merged_at: Option<DateTime<Utc>>,
}

/// Merged PRs older than this are not kept.
pub const MERGED_DAYS: i64 = 14;
/// The search looks at PRs updated in this many days.
const SEARCH_DAYS: i64 = 30;

/// One GitHub search for the user's open and recently merged PRs. `api_base`
/// is `https://api.github.com` in production and a mock server in tests. GET
/// only. Closed-unmerged PRs and merges older than 14 days are dropped.
pub async fn fetch_prs(
    http: &reqwest::Client,
    api_base: &str,
    token: &str,
    now: DateTime<Utc>,
) -> anyhow::Result<Vec<PrRecord>> {
    let since = (now - chrono::Duration::days(SEARCH_DAYS)).date_naive();
    let query = format!("is:pr author:@me archived:false updated:>={since}");
    let url = format!("{}/search/issues", api_base.trim_end_matches('/'));
    let resp = http
        .get(url)
        .query(&[("q", query.as_str()), ("per_page", "100")])
        .bearer_auth(token)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .header(reqwest::header::USER_AGENT, "Nostromo-Huey")
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("GitHub search returned HTTP {}", status.as_u16());
    }
    let page: SearchPage = resp.json().await?;
    let merged_after = now - chrono::Duration::days(MERGED_DAYS);
    let mut out: Vec<PrRecord> = page
        .items
        .into_iter()
        .filter_map(|item| {
            let repo = item
                .repository_url
                .trim_end_matches('/')
                .rsplit('/')
                .next()?;
            let merged_at = item.pull_request.as_ref().and_then(|p| p.merged_at);
            let (state, at) = match (item.state.as_str(), merged_at) {
                ("open", _) => (PrState::Open, item.updated_at),
                (_, Some(m)) if m >= merged_after => (PrState::Merged, m),
                _ => return None,
            };
            Some(PrRecord {
                repo: repo.to_lowercase(),
                number: item.number,
                title: one_line(&item.title, MAX_TITLE_CHARS),
                state,
                at,
            })
        })
        .collect();
    out.sort_by(|a, b| a.repo.cmp(&b.repo).then(b.number.cmp(&a.number)));
    Ok(out)
}

// ── Mother ───────────────────────────────────────────────────────────────────

/// Jobs touched in this many days count toward "in flight".
pub const JOB_DAYS: i64 = 7;

/// The job's latest timestamp.
pub fn job_time(job: &MotherJob) -> Option<DateTime<Utc>> {
    [job.finished_at, job.started_at, job.created_at]
        .into_iter()
        .flatten()
        .max()
}

/// Is the job still moving (not in a terminal state)?
pub fn job_is_active(job: &MotherJob) -> bool {
    !matches!(
        job.state.as_str(),
        "succeeded" | "failed" | "cancelled" | "merged" | "closed"
    )
}

/// The jobs that count for the digest: active ones, and any touched in the
/// last 7 days. Sorted newest first, then by id.
pub fn recent_jobs(jobs: &[MotherJob], now: DateTime<Utc>) -> Vec<MotherJob> {
    let after = now - chrono::Duration::days(JOB_DAYS);
    let mut out: Vec<MotherJob> = jobs
        .iter()
        .filter(|j| job_is_active(j) || job_time(j).is_some_and(|t| t >= after))
        .cloned()
        .collect();
    out.sort_by(|a, b| job_time(b).cmp(&job_time(a)).then_with(|| a.id.cmp(&b.id)));
    out
}

/// "Queue: idle" or "Queue: 2 running, 1 awaiting" (counts by state).
pub fn queue_line(jobs: &[MotherJob]) -> String {
    let mut counts: std::collections::BTreeMap<&str, usize> = Default::default();
    for job in jobs.iter().filter(|j| job_is_active(j)) {
        *counts.entry(job.state.as_str()).or_default() += 1;
    }
    if counts.is_empty() {
        return "Queue: idle".to_string();
    }
    let parts: Vec<String> = counts
        .iter()
        .map(|(state, n)| format!("{n} {}", one_line(state, 24)))
        .collect();
    format!("Queue: {}", parts.join(", "))
}

// ── Bishop ───────────────────────────────────────────────────────────────────

/// The numbers from Bishop's posture file that the digest shows.
#[derive(Debug, Clone, PartialEq)]
pub struct PostureFacts {
    /// The posture word as Bishop wrote it.
    pub posture: String,
    pub seven_day_used_pct: Option<f64>,
    pub seven_day_pace: Option<f64>,
    pub five_hour_used_pct: Option<f64>,
    pub billing_mode: Option<String>,
    pub stale_input: bool,
}

impl PostureFacts {
    /// `Bishop: "Pump the brakes"; 7-day 72% used, pace 1.9; billing metered`.
    pub fn line(&self) -> String {
        let mut parts = vec![format!("Bishop: \"{}\"", self.posture)];
        let mut window = Vec::new();
        if let Some(used) = self.seven_day_used_pct {
            window.push(format!("7-day {used:.0}% used"));
        }
        if let Some(pace) = self.seven_day_pace {
            window.push(format!("pace {pace:.1}"));
        }
        if !window.is_empty() {
            parts.push(window.join(", "));
        }
        if let Some(used) = self.five_hour_used_pct {
            parts.push(format!("5-hour {used:.0}% used"));
        }
        if let Some(mode) = &self.billing_mode {
            parts.push(format!("billing {mode}"));
        }
        if self.stale_input {
            parts.push("input stale".to_string());
        }
        one_line(&parts.join("; "), 200)
    }
}

/// Read Bishop's posture file. `None` when it is missing or has no posture.
pub fn posture(path: &Path) -> Option<PostureFacts> {
    let text = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let posture = one_line(v.get("posture")?.as_str()?, 40);
    let num = |window: &str, key: &str| v.get(window)?.get(key)?.as_f64();
    Some(PostureFacts {
        posture,
        seven_day_used_pct: num("seven_day", "used_pct"),
        seven_day_pace: num("seven_day", "pace"),
        five_hour_used_pct: num("five_hour", "used_pct"),
        billing_mode: v
            .get("billing_mode")
            .and_then(serde_json::Value::as_str)
            .map(|s| one_line(s, 24)),
        stale_input: v
            .get("stale_input")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
    })
}

// ── Ideas, todos, notes ──────────────────────────────────────────────────────

/// A title-only entry: an idea, a todo or a note.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleEntry {
    /// `idea:<slug>`, `todo:<id>`, `note:<slug>`.
    pub id: String,
    pub title: String,
    pub date: Option<NaiveDate>,
    /// The todo's state (`open`, `in_progress`, `blocked`).
    pub state: Option<String>,
}

/// Most ideas, todos and notes kept (each).
pub const MAX_TITLES: usize = 10;
/// Notes older than this many days are left out.
pub const NOTE_DAYS: i64 = 14;

/// Ideas in `dir` (`*.md`): titles and dates only, newest first.
pub fn ideas(dir: &Path) -> Vec<TitleEntry> {
    let mut out = markdown_titles(dir, "idea");
    out.truncate(MAX_TITLES);
    out
}

/// Notes in `dir` (`*.md`) dated within the last 14 days, newest first.
pub fn notes(dir: &Path, today: NaiveDate) -> Vec<TitleEntry> {
    let after = today - chrono::Duration::days(NOTE_DAYS);
    let mut out: Vec<TitleEntry> = markdown_titles(dir, "note")
        .into_iter()
        .filter(|e| e.date.is_some_and(|d| d >= after))
        .collect();
    out.truncate(MAX_TITLES);
    out
}

/// Open todos from Teri's store at `db` (read-only), titles and states only.
pub fn todos(db: &Path) -> Vec<TitleEntry> {
    let snap = crate::data::teri_todos::read_snapshot(db);
    snap.items
        .iter()
        .take(MAX_TITLES)
        .map(|t| TitleEntry {
            id: format!("todo:{}", t.id),
            title: one_line(&t.title, MAX_TITLE_CHARS),
            date: t
                .due_date
                .as_deref()
                .and_then(|d| NaiveDate::parse_from_str(d.get(..10)?, "%Y-%m-%d").ok()),
            state: Some(one_line(&t.status, 24)),
        })
        .collect()
}

/// `*.md` files in `dir` (not recursive): the first `# ` heading as the title
/// (else the file name), the date from front matter `created:` or a
/// `YYYY-MM-DD-` file-name prefix. Only the front matter and the first
/// heading are looked at. Sorted newest first, then by id.
fn markdown_titles(dir: &Path, kind: &str) -> Vec<TitleEntry> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<TitleEntry> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let stem = name.strip_suffix(".md")?.to_string();
            let file_date = stem
                .get(..10)
                .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok());
            let slug = match file_date {
                Some(_) => stem[10..].trim_start_matches('-').to_string(),
                None => stem.clone(),
            };
            let (heading, created) = head_facts(&e.path());
            let title = heading.unwrap_or_else(|| slug.replace('-', " "));
            Some(TitleEntry {
                id: format!("{kind}:{}", one_line(&slug, 64)),
                title: one_line(&title, MAX_TITLE_CHARS),
                date: created.or(file_date),
                state: None,
            })
        })
        .collect();
    out.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| a.id.cmp(&b.id)));
    out.dedup_by(|a, b| a.id == b.id);
    out
}

/// The first `# ` heading and the front matter's `created:` date. Stops at the
/// first heading; reads at most the first 64 lines.
fn head_facts(path: &Path) -> (Option<String>, Option<NaiveDate>) {
    let Some(text) = super::profile::read_regular_file(path) else {
        return (None, None);
    };
    let mut created = None;
    let mut in_front = false;
    for (i, line) in text.lines().take(64).enumerate() {
        let t = line.trim();
        if i == 0 && t == "---" {
            in_front = true;
            continue;
        }
        if in_front {
            if t == "---" {
                in_front = false;
            } else if let Some(v) = t.strip_prefix("created:") {
                created =
                    NaiveDate::parse_from_str(v.trim().get(..10).unwrap_or(""), "%Y-%m-%d").ok();
            }
            continue;
        }
        if let Some(h) = line.strip_prefix("# ") {
            return (Some(h.trim().to_string()), created);
        }
    }
    (None, created)
}
