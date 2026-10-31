//! Learning that a Mother job's PR was merged (MF2b).
//!
//! Two sources feed [`NoticeEngine::pr_event`], which announces each outcome
//! once per job:
//!
//! * the github-relay (`pr.merged`, `pr.closed`), matched to jobs by
//!   `owner/name#number`;
//! * a low-rate poll of `gh pr view` for jobs the relay does not cover (other
//!   owners) or cannot reach right now (disconnected), and one sweep after a
//!   reconnect, because relay delivery is at-most-once.
//!
//! Nothing here logs a PR URL, a repo, a token or a command's stderr: job ids,
//! counts and error classes only.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use serde::Deserialize;
use tokio::sync::mpsc;

use super::{Clock, NoticeEngine};
use crate::data::relay_client::{QueueSignal, RelayStatus};

/// A job's PR is probed at most this often.
pub const PROBE_GAP_MS: i64 = 5 * 60_000;
/// How often the poll loop runs a cycle.
pub const POLL_CYCLE: Duration = Duration::from_secs(60);
/// Probes started per cycle, at most.
pub const PROBES_PER_CYCLE: usize = 20;
/// The first back-off after a failed probe; it doubles per failure.
pub const BACKOFF_START_MS: i64 = 5 * 60_000;
/// The longest back-off.
pub const BACKOFF_MAX_MS: i64 = 60 * 60_000;
/// A job's PR is no longer tracked this long after the job finished.
pub const TRACK_MAX_MS: i64 = 14 * 24 * 60 * 60_000;
/// Probes in flight at once within a cycle.
const PROBE_CONCURRENCY: usize = 4;
/// One `gh` call is given this long.
pub const GH_TIMEOUT: Duration = Duration::from_secs(20);

/// A PR, by owner, repo and number. Owner and name are compared without
/// regard to case (they are stored lowercased).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PrRef {
    pub owner: String,
    pub name: String,
    pub number: u64,
}

impl PrRef {
    /// `https://github.com/<owner>/<name>/pull/<n>`, tolerant of a trailing
    /// `/files` (or other sub-page), a query string and a fragment. Anything
    /// else is not a PR we track.
    pub fn parse(url: &str) -> Option<PrRef> {
        let rest = url.strip_prefix("https://github.com/")?;
        let path = rest.split(['?', '#']).next()?;
        let mut parts = path.split('/');
        let owner = parts.next().filter(|p| safe_segment(p))?;
        let name = parts.next().filter(|p| safe_segment(p))?;
        if parts.next()? != "pull" {
            return None;
        }
        let number = parts.next()?;
        if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Some(PrRef {
            owner: owner.to_ascii_lowercase(),
            name: name.to_ascii_lowercase(),
            number: number.parse().ok()?,
        })
    }

    /// The canonical URL, as passed to `gh pr view`.
    pub fn url(&self) -> String {
        format!(
            "https://github.com/{}/{}/pull/{}",
            self.owner, self.name, self.number
        )
    }
}

/// An owner or repo name as GitHub allows it.
fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// A job whose PR the engine considers worth asking about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrCandidate {
    pub job_id: String,
    pub pr_url: String,
}

/// What GitHub says about a PR.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrState {
    Open,
    Merged,
    Closed,
}

/// Why a probe failed: a class only, never a message (stderr is not logged).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeError {
    /// The command could not start.
    Spawn,
    /// It ran past [`GH_TIMEOUT`].
    Timeout,
    /// It exited with a failure status.
    Exit,
    /// Its output was not what `gh pr view --json state,mergedAt` prints.
    Parse,
}

/// Asks GitHub what became of a PR.
// `async_trait`'s boxed future is already `must_use`; newer clippy flags the pair.
#[allow(clippy::double_must_use)]
#[async_trait]
pub trait PrStateProbe: Send + Sync {
    async fn state(&self, pr: &PrRef) -> Result<PrState, ProbeError>;
}

/// What a finished command left: stdout, and whether it succeeded. Stderr is
/// dropped on purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
}

/// Runs a program with arguments, no shell, within `timeout`.
// `async_trait`'s boxed future is already `must_use`; newer clippy flags the pair.
#[allow(clippy::double_must_use)]
#[async_trait]
pub trait CommandRunner: Send + Sync {
    async fn run(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<CommandOutput, ProbeError>;
}

/// The real runner: `tokio::process`, stdin closed, killed on timeout.
pub struct TokioRunner;

#[async_trait]
impl CommandRunner for TokioRunner {
    async fn run(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<CommandOutput, ProbeError> {
        let mut cmd = tokio::process::Command::new(program);
        cmd.args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        // Dropping the future on timeout kills the child.
        match tokio::time::timeout(timeout, cmd.output()).await {
            Err(_) => Err(ProbeError::Timeout),
            Ok(Err(_)) => Err(ProbeError::Spawn),
            Ok(Ok(out)) => Ok(CommandOutput {
                success: out.status.success(),
                stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            }),
        }
    }
}

/// The real probe: `gh pr view <url> --json state,mergedAt` through `runner`.
pub struct GhProbe {
    runner: Arc<dyn CommandRunner>,
    gh: String,
}

impl GhProbe {
    pub fn new(runner: Arc<dyn CommandRunner>, gh: String) -> Self {
        Self { runner, gh }
    }
}

#[async_trait]
impl PrStateProbe for GhProbe {
    async fn state(&self, pr: &PrRef) -> Result<PrState, ProbeError> {
        #[derive(Deserialize)]
        struct View {
            state: String,
        }
        let args = [
            "pr".to_owned(),
            "view".to_owned(),
            pr.url(),
            "--json".to_owned(),
            "state,mergedAt".to_owned(),
        ];
        let out = self.runner.run(&self.gh, &args, GH_TIMEOUT).await?;
        if !out.success {
            return Err(ProbeError::Exit);
        }
        let view: View = serde_json::from_str(&out.stdout).map_err(|_| ProbeError::Parse)?;
        match view.state.as_str() {
            "OPEN" => Ok(PrState::Open),
            "MERGED" => Ok(PrState::Merged),
            "CLOSED" => Ok(PrState::Closed),
            _ => Err(ProbeError::Parse),
        }
    }
}

/// When a job's PR was last probed and when it may be again.
struct Schedule {
    last_checked_ms: i64,
    next_ok_ms: i64,
    failures: u32,
}

#[derive(Default)]
struct Book {
    schedules: HashMap<String, Schedule>,
    /// A relay (re)connect asked for a sweep of the covered jobs.
    sweep_requested: bool,
    /// Jobs a sweep still has to probe (probed whatever their schedule).
    sweep: HashSet<String>,
}

/// Watches relay signals and polls, and tells the engine what became of each
/// job's PR.
pub struct PrTracker {
    engine: Arc<NoticeEngine>,
    probe: Arc<dyn PrStateProbe>,
    status: Arc<RelayStatus>,
    clock: Arc<dyn Clock>,
    book: Mutex<Book>,
}

impl PrTracker {
    pub fn new(
        engine: Arc<NoticeEngine>,
        probe: Arc<dyn PrStateProbe>,
        status: Arc<RelayStatus>,
        clock: Arc<dyn Clock>,
    ) -> Arc<Self> {
        Arc::new(Self {
            engine,
            probe,
            status,
            clock,
            book: Mutex::new(Book::default()),
        })
    }

    /// One relay signal: a `pr.merged` / `pr.closed` event for a tracked PR
    /// goes to the engine; `Reconnected` schedules a one-off sweep (run by the
    /// next [`poll_cycle`](Self::poll_cycle)).
    pub fn on_signal(&self, signal: &QueueSignal) {
        let event = match signal {
            QueueSignal::Reconnected => {
                self.book().sweep_requested = true;
                return;
            }
            QueueSignal::Event(event) => event,
        };
        let merged = match event.event_type.as_str() {
            "pr.merged" => true,
            "pr.closed" => event.merged == Some(true),
            _ => return,
        };
        let (Some(repo), Some(number)) = (event.repo.as_deref(), event.number) else {
            return;
        };
        let Some((owner, name)) = repo.split_once('/') else {
            return;
        };
        let Some(candidates) = self.engine.pr_candidates() else {
            return;
        };
        for candidate in candidates {
            let Some(pr) = PrRef::parse(&candidate.pr_url) else {
                continue;
            };
            if pr.number == number
                && pr.owner.eq_ignore_ascii_case(owner)
                && pr.name.eq_ignore_ascii_case(name)
            {
                self.engine.pr_event(&candidate.job_id, merged);
            }
        }
    }

    /// One poll cycle at the clock's time: probe what is due (see the module
    /// docs and the constants), apply each answer to the engine.
    ///
    /// A job is due when the relay does not cover it (another owner, or the
    /// relay is disconnected) and its schedule allows, or a sweep names it;
    /// the oldest-checked go first, [`PROBES_PER_CYCLE`] at most.
    pub async fn poll_cycle(&self) {
        let now = self.clock.now_ms();
        // Before the first look at the feed nothing is known, and a pending
        // sweep keeps waiting.
        let Some(candidates) = self.engine.pr_candidates() else {
            return;
        };
        let due = self.due(candidates, now);
        if due.is_empty() {
            return;
        }
        let results: Vec<(String, Result<PrState, ProbeError>)> = futures::stream::iter(due)
            .map(|(id, pr)| async move {
                let state = self.probe.state(&pr).await;
                (id, state)
            })
            .buffered(PROBE_CONCURRENCY)
            .collect()
            .await;
        let (mut merged, mut closed, mut errors) = (0usize, 0usize, 0usize);
        for (id, result) in &results {
            match result {
                Ok(PrState::Merged) => {
                    merged += 1;
                    self.engine.pr_event(id, true);
                }
                Ok(PrState::Closed) => {
                    closed += 1;
                    self.engine.pr_event(id, false);
                }
                Ok(PrState::Open) => {}
                Err(class) => {
                    errors += 1;
                    tracing::debug!(job = %id, class = ?class, "mother PR probe failed");
                }
            }
            self.settle(id, result, now);
        }
        tracing::debug!(
            probed = results.len(),
            merged,
            closed,
            errors,
            "mother PR poll cycle"
        );
    }

    /// Feed `signals` to [`on_signal`](Self::on_signal) and run a cycle every
    /// [`POLL_CYCLE`] and right after a `Reconnected`. When `signals` closes
    /// (no relay was started) the polling goes on alone.
    pub fn spawn(
        self: Arc<Self>,
        mut signals: mpsc::UnboundedReceiver<QueueSignal>,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            let mut cycle = tokio::time::interval(POLL_CYCLE);
            cycle.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut open = true;
            loop {
                tokio::select! {
                    signal = signals.recv(), if open => match signal {
                        None => open = false,
                        Some(signal) => {
                            self.on_signal(&signal);
                            if matches!(signal, QueueSignal::Reconnected) {
                                self.poll_cycle().await;
                            }
                        }
                    },
                    _ = cycle.tick() => self.poll_cycle().await,
                }
            }
        })
    }

    fn book(&self) -> std::sync::MutexGuard<'_, Book> {
        self.book.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The jobs to probe now, oldest-checked first.
    fn due(&self, candidates: Vec<PrCandidate>, now: i64) -> Vec<(String, PrRef)> {
        let org = self.status.org();
        let connected = self.status.connected();
        let tracked: Vec<(String, PrRef)> = candidates
            .into_iter()
            .filter_map(|c| Some((c.job_id, PrRef::parse(&c.pr_url)?)))
            .collect();
        let mut book = self.book();
        // Jobs that are no longer tracked are forgotten.
        let ids: HashSet<&str> = tracked.iter().map(|(id, _)| id.as_str()).collect();
        book.schedules.retain(|id, _| ids.contains(id.as_str()));
        book.sweep.retain(|id| ids.contains(id.as_str()));
        if std::mem::take(&mut book.sweep_requested) {
            for (id, pr) in &tracked {
                if pr.owner.eq_ignore_ascii_case(&org) {
                    book.sweep.insert(id.clone());
                }
            }
        }
        let mut due: Vec<(Option<i64>, String, PrRef)> = Vec::new();
        for (id, pr) in tracked {
            let swept = book.sweep.contains(&id);
            let covered = pr.owner.eq_ignore_ascii_case(&org) && connected;
            if covered && !swept {
                continue;
            }
            let schedule = book.schedules.get(&id);
            if !swept && schedule.is_some_and(|s| now < s.next_ok_ms) {
                continue;
            }
            due.push((schedule.map(|s| s.last_checked_ms), id, pr));
        }
        due.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
        due.truncate(PROBES_PER_CYCLE);
        due.into_iter().map(|(_, id, pr)| (id, pr)).collect()
    }

    /// Record a probe's outcome in the job's schedule (a job whose PR ended
    /// is forgotten).
    fn settle(&self, id: &str, result: &Result<PrState, ProbeError>, now: i64) {
        let mut book = self.book();
        book.sweep.remove(id);
        let failures = match result {
            Ok(PrState::Merged | PrState::Closed) => {
                book.schedules.remove(id);
                return;
            }
            Ok(PrState::Open) => 0,
            Err(_) => book.schedules.get(id).map_or(0, |s| s.failures) + 1,
        };
        let gap = if failures == 0 {
            PROBE_GAP_MS
        } else {
            BACKOFF_START_MS
                .saturating_mul(1 << (failures - 1).min(16))
                .min(BACKOFF_MAX_MS)
        };
        book.schedules.insert(
            id.to_owned(),
            Schedule {
                last_checked_ms: now,
                next_ok_ms: now + gap,
                failures,
            },
        );
    }
}
