//! Huey's per-machine context: projects in flight, their "how it runs"
//! profiles, the collectors and the digest (A9).
//!
//! [`ContextEnv`] holds every root the context reads from, so a test (or a
//! second machine) passes its own and never sees another's. [`gather`] does
//! the reading; [`digest::build_digest`] is pure.

pub mod collectors;
pub mod digest;
pub mod profile;
pub mod projects;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, Utc};

use crate::huey::interests::Interests;
use crate::huey::paths::HueyPaths;
use crate::mother::MotherJob;
use collectors::{BoardSummary, PrRecord, PrState, PrsInput};
use digest::{project_ignored, DigestInputs, ProjectContext};
use projects::Repo;

pub use digest::{append_checks, build_digest, Digest};

/// The note the setup step shows next to sources that can arrive from other
/// machines through a synced `~/.claude` (D5's v1 mitigation).
pub const SYNCED_NOTE: &str = "may be synced from other machines";

/// Commits within this many days make a project in flight.
pub const COMMIT_IN_FLIGHT_DAYS: i64 = 14;
/// Commit subjects shown per project: this many days back, at most 5.
pub const COMMIT_SUBJECT_DAYS: i64 = 7;
pub const MAX_COMMIT_SUBJECTS: usize = 5;

/// Every root Huey's context reads from on one machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextEnv {
    /// Short machine name for the digest header (`Sendai`).
    pub machine: String,
    /// Where projects are discovered (`Config::code_root_dir()`).
    pub code_root: PathBuf,
    /// The daemon's state root (`trackers/state.json` lives under it).
    pub state_root: PathBuf,
    /// `~/.claude`: ideas, notes and Bishop's posture file are read from it
    /// (titles and numbers only); nothing is ever written there.
    pub claude_dir: PathBuf,
    /// Teri's todo store.
    pub teri_db: PathBuf,
}

/// One context source as the setup step lists it (no reads to build it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextSource {
    pub name: String,
    pub path: String,
    pub note: Option<String>,
}

/// What the daemon already knows and passes in: the PR search result and
/// Mother's job list.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveInputs {
    pub prs: PrsInput,
    pub jobs: Vec<MotherJob>,
}

impl ContextEnv {
    /// The roots under `home`.
    pub fn for_home(home: &Path, code_root: PathBuf, state_root: PathBuf, machine: String) -> Self {
        Self {
            machine,
            code_root,
            state_root,
            claude_dir: home.join(".claude"),
            teri_db: crate::data::teri_todos::db_path_in(home),
        }
    }

    /// Production roots: `$HOME`, and the host name without its domain.
    pub fn production(code_root: PathBuf, state_root: PathBuf) -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        let machine = hostname::get()
            .ok()
            .map(|h| h.to_string_lossy().into_owned())
            .and_then(|h| h.split('.').next().map(str::to_string))
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| "this machine".to_string());
        Self::for_home(&home, code_root, state_root, machine)
    }

    pub fn ideas_dir(&self) -> PathBuf {
        self.claude_dir.join("ideas")
    }

    pub fn notes_dir(&self) -> PathBuf {
        self.claude_dir.join("notes")
    }

    pub fn posture_file(&self) -> PathBuf {
        self.claude_dir.join("budget-posture.json")
    }

    pub fn tracker_state(&self) -> PathBuf {
        self.state_root.join("trackers").join("state.json")
    }

    /// The sources the context would read, with paths. Reads nothing.
    pub fn sources(&self, paths: &HueyPaths) -> Vec<ContextSource> {
        let src = |name: &str, path: String, note: Option<&str>| ContextSource {
            name: name.to_string(),
            path,
            note: note.map(str::to_string),
        };
        let show = |p: &Path| p.display().to_string();
        vec![
            src(
                "Projects (git repositories)",
                show(&self.code_root),
                Some("names, manifests, commit subjects and `git grep` counts, plus a one-line description from each manifest or README, shown in your draft"),
            ),
            src(
                "Tracker boards",
                show(&self.tracker_state()),
                Some("board topics and item titles and states"),
            ),
            src(
                "GitHub pull requests",
                "github.com (your open and recently merged PRs)".into(),
                Some("titles and numbers"),
            ),
            src(
                "Mother jobs",
                "Mother's job list".into(),
                Some("titles and states"),
            ),
            src(
                "Bishop budget posture",
                show(&self.posture_file()),
                Some("posture and usage numbers"),
            ),
            src(
                "Ideas",
                show(&self.ideas_dir()),
                Some(&format!("titles and dates only; {SYNCED_NOTE}")),
            ),
            src(
                "Todos",
                show(&self.teri_db),
                Some(&format!("open todo titles only; {SYNCED_NOTE}")),
            ),
            src(
                "Notes",
                show(&self.notes_dir()),
                Some(&format!("titles of the last 14 days only; {SYNCED_NOTE}")),
            ),
            src("Interests", show(&paths.interests()), None),
        ]
    }
}

fn board_project<'a>(board: &BoardSummary, repos: &'a [Repo]) -> Option<&'a Repo> {
    let anchor = board.root.as_deref().unwrap_or(&board.path);
    repos.iter().find(|r| r.contains(anchor))
}

fn job_project<'a>(job: &MotherJob, repos: &'a [Repo]) -> Option<&'a Repo> {
    let name = job
        .repo
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_lowercase();
    if name.is_empty() {
        return None;
    }
    repos
        .iter()
        .find(|r| r.id == name || r.name.to_lowercase() == name)
}

/// What one repository has to show, for the in-flight rule (A9).
struct ActivitySources<'a> {
    commits: &'a [projects::Commit],
    prs: &'a [PrRecord],
    jobs: &'a [MotherJob],
    boards: &'a [BoardSummary],
}

impl ActivitySources<'_> {
    /// The most recent of: the latest commit (if within
    /// [`COMMIT_IN_FLIGHT_DAYS`]), open PRs, jobs and board updates.
    fn latest(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let commit_after = now - chrono::Duration::days(COMMIT_IN_FLIGHT_DAYS);
        let mut times: Vec<DateTime<Utc>> = Vec::new();
        times.extend(
            self.commits
                .first()
                .map(|c| c.at)
                .filter(|t| *t >= commit_after),
        );
        times.extend(
            self.prs
                .iter()
                .filter(|p| p.state == PrState::Open)
                .map(|p| p.at),
        );
        times.extend(
            self.jobs
                .iter()
                .map(|j| collectors::job_time(j).unwrap_or(now)),
        );
        times.extend(
            self.boards
                .iter()
                .map(|b| b.updated_at.unwrap_or(DateTime::<Utc>::MIN_UTC)),
        );
        times.into_iter().max()
    }
}

/// Read every context source in `env` and build the digest inputs (version 1,
/// no mode line, dated today in local time). `profile_cache` is
/// `state/profiles/`; `None` (the setup scan) caches nothing, so nothing is
/// written.
pub fn gather(
    env: &ContextEnv,
    interests: &Interests,
    live: &LiveInputs,
    profile_cache: Option<&Path>,
    now: DateTime<Utc>,
) -> DigestInputs {
    let repos: Vec<Repo> = projects::discover(&env.code_root)
        .into_iter()
        .filter(|r| !project_ignored(interests, &r.id, &r.name))
        .collect();

    let mut boards: BTreeMap<String, Vec<BoardSummary>> = BTreeMap::new();
    for board in collectors::tracker_boards(&env.state_root) {
        if let Some(repo) = board_project(&board, &repos) {
            boards.entry(repo.id.clone()).or_default().push(board);
        }
    }

    let (prs_available, prs) = match &live.prs {
        PrsInput::Available(prs) => (true, prs.as_slice()),
        PrsInput::Unavailable => (false, &[][..]),
    };
    let mut prs_by: BTreeMap<String, Vec<PrRecord>> = BTreeMap::new();
    for pr in prs {
        if let Some(repo) = repos
            .iter()
            .find(|r| r.id == pr.repo || r.name.to_lowercase() == pr.repo)
        {
            prs_by.entry(repo.id.clone()).or_default().push(pr.clone());
        }
    }

    let recent_jobs = collectors::recent_jobs(&live.jobs, now);
    let mut jobs_by: BTreeMap<String, Vec<MotherJob>> = BTreeMap::new();
    for job in &recent_jobs {
        if let Some(repo) = job_project(job, &repos) {
            jobs_by
                .entry(repo.id.clone())
                .or_default()
                .push(job.clone());
        }
    }

    // Activity per repository: the in-flight rule (A9).
    let mut commits_by = BTreeMap::new();
    let mut activity: BTreeMap<String, DateTime<Utc>> = BTreeMap::new();
    for repo in &repos {
        let commits = projects::recent_commits(&repo.root, 20);
        let sources = ActivitySources {
            commits: &commits,
            prs: prs_by.get(&repo.id).map_or(&[][..], Vec::as_slice),
            jobs: jobs_by.get(&repo.id).map_or(&[][..], Vec::as_slice),
            boards: boards.get(&repo.id).map_or(&[][..], Vec::as_slice),
        };
        if let Some(latest) = sources.latest(now) {
            activity.insert(repo.id.clone(), latest);
        }
        commits_by.insert(repo.id.clone(), commits);
    }
    let in_flight: BTreeSet<String> = projects::select_in_flight(&activity).into_iter().collect();

    let subject_after = now - chrono::Duration::days(COMMIT_SUBJECT_DAYS);
    let project_contexts: Vec<ProjectContext> = repos
        .iter()
        .filter(|r| in_flight.contains(&r.id))
        .map(|repo| {
            let prof = profile::profile_cached(&repo.root, &repo.id, profile_cache);
            ProjectContext {
                id: repo.id.clone(),
                name: repo.name.clone(),
                root: repo.root.clone(),
                how_it_runs: prof.line(),
                prs: prs_by.remove(&repo.id).unwrap_or_default(),
                boards: boards.remove(&repo.id).unwrap_or_default(),
                jobs: jobs_by.remove(&repo.id).unwrap_or_default(),
                commits: commits_by
                    .remove(&repo.id)
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|c| c.at >= subject_after)
                    .take(MAX_COMMIT_SUBJECTS)
                    .collect(),
                last_activity: activity[&repo.id],
            }
        })
        .collect();

    let today = now.with_timezone(&Local).date_naive();
    DigestInputs {
        machine: env.machine.clone(),
        date: today,
        version: 1,
        mode: None,
        interests: interests.clone(),
        projects: project_contexts,
        prs_available,
        posture: collectors::posture(&env.posture_file()),
        // Shown on `mother`, or as a machine line when Mother has jobs here.
        mother_queue: (!live.jobs.is_empty() || in_flight.contains("mother"))
            .then(|| collectors::queue_line(&live.jobs)),
        ideas: collectors::ideas(&env.ideas_dir()),
        todos: collectors::todos(&env.teri_db),
        notes: collectors::notes(&env.notes_dir(), today),
    }
}
