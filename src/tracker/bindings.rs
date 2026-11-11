//! Live tracker items (PRD "Live items", contract §1.4, §2, §3): an item bound
//! to a source the daemon keeps fresh, with no agent call.
//!
//! The source set is **closed**: [`Binding::MotherJob`] and [`Binding::PrCi`].
//! A binding is written into the item's marker as `bind:mother.job/<id>` or
//! `bind:pr.ci/<owner>/<repo>#<n>[!green]` and nowhere else; an unknown source
//! is `invalid_args` for an agent and is ignored (not live) when a human wrote
//! it into the file.
//!
//! This module is pure: it parses and prints bindings, maps what a source
//! reports onto what the item should show ([`Desired`]), and fronts the
//! registry for the feeds ([`BindingHub`]). The registry owns the live state
//! (overlay, file-write throttle, staleness), because it owns the board.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use chrono::{DateTime, Utc};
use regex::Regex;

use super::model::{Link, Status};
use super::registry::TrackerRegistry;
use crate::data::perri_pr::CiCheck;
use crate::data::perri_queue::CiState;
use crate::mother::notices::element::{awaiting_reason, clean_pr, failure_class};
use crate::mother::MotherJob;

/// The `Author::Source` name of a Mother-job binding.
pub const SOURCE_MOTHER_JOB: &str = "mother.job";
/// The `Author::Source` name of a PR-CI binding.
pub const SOURCE_PR_CI: &str = "pr.ci";

/// A bound item's file line is rewritten at most once per this long.
pub const FILE_WRITE_INTERVAL: Duration = Duration::from_secs(60);

/// First-line prefixes of the note lines a source owns. A source replaces its
/// own first line (recognised by prefix) and never touches the rest.
pub const MOTHER_NOTE_PREFIX: &str = "Mother job ";
pub const CI_NOTE_PREFIX: &str = "CI ";

/// How long a source may be silent before the item is `badly_stale` (the
/// live-pane rule, `NOSTROMO_BADLY_STALE_SECS` aside).
pub fn badly_stale_after() -> Duration {
    crate::mcp::pane_sources::badly_stale_after()
}

/// What an item is bound to.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Binding {
    MotherJob {
        job_id: String,
    },
    PrCi {
        /// `owner/repo`.
        repo: String,
        number: u64,
        /// `success` marks the item done (`!green`); otherwise the status is
        /// left alone and a `CI green` note line says so.
        done_when_green: bool,
    },
}

impl Binding {
    /// Parses `mother.job/<id>` or `pr.ci/<owner>/<repo>#<n>[!green]` (the
    /// marker flag without `bind:`). The error says what is wrong.
    pub fn parse(text: &str) -> Result<Binding, String> {
        let text = text.trim();
        let Some((source, key)) = text.split_once('/') else {
            return Err(format!(
                "bind {text:?}: expected mother.job/<id> or pr.ci/<owner>/<repo>#<n>[!green]"
            ));
        };
        match source {
            SOURCE_MOTHER_JOB => {
                if job_id_re().is_match(key) {
                    Ok(Binding::MotherJob {
                        job_id: key.to_string(),
                    })
                } else {
                    Err(format!("bind {text:?}: invalid Mother job id"))
                }
            }
            SOURCE_PR_CI => {
                let caps = pr_key_re().captures(key).ok_or_else(|| {
                    format!("bind {text:?}: expected pr.ci/<owner>/<repo>#<n>[!green]")
                })?;
                let number: u64 = caps[3]
                    .parse()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| format!("bind {text:?}: invalid PR number"))?;
                if matches!(&caps[2], "." | "..") {
                    return Err(format!("bind {text:?}: invalid repo name"));
                }
                Ok(Binding::PrCi {
                    repo: format!("{}/{}", &caps[1], &caps[2]),
                    number,
                    done_when_green: caps.get(4).is_some(),
                })
            }
            other => Err(format!(
                "unknown bind source {other:?}; known sources: {SOURCE_MOTHER_JOB}, {SOURCE_PR_CI}"
            )),
        }
    }

    /// The `<source>/<key>` stored on the item and written after `bind:` in
    /// the marker. `parse(b.to_key()) == b`.
    pub fn to_key(&self) -> String {
        match self {
            Binding::MotherJob { job_id } => format!("{SOURCE_MOTHER_JOB}/{job_id}"),
            Binding::PrCi {
                repo,
                number,
                done_when_green,
            } => format!(
                "{SOURCE_PR_CI}/{repo}#{number}{}",
                if *done_when_green { "!green" } else { "" }
            ),
        }
    }

    /// The source's name: the `source <name>` of attributed changes and the
    /// `source` of the view's `bound`.
    pub fn source_name(&self) -> &'static str {
        match self {
            Binding::MotherJob { .. } => SOURCE_MOTHER_JOB,
            Binding::PrCi { .. } => SOURCE_PR_CI,
        }
    }

    /// The prefix of the note first line this source owns.
    pub fn note_prefix(&self) -> &'static str {
        match self {
            Binding::MotherJob { .. } => MOTHER_NOTE_PREFIX,
            Binding::PrCi { .. } => CI_NOTE_PREFIX,
        }
    }
}

fn job_id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$").unwrap())
}

fn pr_key_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^([A-Za-z0-9][A-Za-z0-9_.-]{0,99})/([A-Za-z0-9_.-]{1,100})#(\d{1,9})(!green)?$",
        )
        .unwrap()
    })
}

/// What a source says an item should show now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Desired {
    /// The source state this was derived from (`running`, `pending`, …).
    /// A change of it is a **state change**: it is logged as a change
    /// attributed to the source and may reach the file. A different `note`
    /// under the same state (a count) is neither.
    pub state: String,
    /// The status the item takes; `None` leaves it as it is.
    pub status: Option<Status>,
    /// The source-owned first line of the item's note (starts with the
    /// binding's [`Binding::note_prefix`]).
    pub note_line: String,
    /// A link the source adds (`PR #253`); never removed.
    pub link: Option<Link>,
}

/// What a Mother job's record means for a bound item.
///
/// `running` → in-progress; a PR (`pr_url`) adds a `PR #n` link; `succeeded`
/// and `pr_merged` → done; `failed` and `cancelled` → blocked, the failure
/// *class* (never Mother's free text, as a notice) in the note; `awaiting` →
/// needs-you with the question's first line. Any other state (a state Mother
/// adds later, `queued`) → in-progress with the raw state as the note line;
/// never a crash.
pub fn map_mother_job(job: &MotherJob) -> Desired {
    let state = job.state.trim();
    let (status, line) = match state {
        "running" => (Status::InProgress, "running".to_string()),
        "pr_opened" => (Status::InProgress, "PR opened".to_string()),
        "succeeded" => (Status::Done, "succeeded".to_string()),
        "pr_merged" => (Status::Done, "PR merged".to_string()),
        "failed" => (
            Status::Blocked,
            format!("failed ({})", failure_class(job.failure_reason.as_deref())),
        ),
        "cancelled" => (Status::Blocked, "cancelled".to_string()),
        "awaiting" => (
            Status::NeedsYou,
            match job.question.as_deref().and_then(awaiting_reason) {
                Some(reason) => format!("needs you: {reason}"),
                None => "needs you".to_string(),
            },
        ),
        other => (
            Status::InProgress,
            format!("state: {}", clean_state_word(other)),
        ),
    };
    let link = job.pr_url.as_deref().and_then(pr_link);
    let line = match (&link, state) {
        (Some(link), "running") => format!("running, {} open", link.text),
        _ => line,
    };
    Desired {
        state: clean_state_word(state),
        status: Some(status),
        note_line: format!("{MOTHER_NOTE_PREFIX}{line}"),
        link,
    }
}

/// A Mother state word as one short printable token.
fn clean_state_word(state: &str) -> String {
    let word: String = state.chars().filter(|c| !c.is_control()).take(40).collect();
    let word = word.trim();
    if word.is_empty() {
        "unknown".to_string()
    } else {
        word.to_string()
    }
}

/// `PR #n` linking to `url`, for an https GitHub-style `…/pull/<n>` URL.
fn pr_link(url: &str) -> Option<Link> {
    let url = clean_pr(url)?;
    if url.chars().any(|c| c == '(' || c == ')' || c.is_control()) {
        return None;
    }
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"/pull/(\d+)").unwrap());
    let number = re.captures(&url)?.get(1)?.as_str().to_string();
    Some(Link::new(&format!("PR #{number}"), Some(&url)))
}

/// What a PR's check runs add up to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CiObservation {
    pub state: CiState,
    /// The first failing check's name.
    pub failing: Option<String>,
    pub passed: usize,
    pub total: usize,
}

impl CiObservation {
    /// Rolls a PR's checks up (failure beats pending beats success).
    pub fn from_checks(checks: &[CiCheck]) -> CiObservation {
        CiObservation {
            state: CiState::rollup(checks.iter().map(|c| c.state)),
            failing: checks
                .iter()
                .find(|c| c.state == CiState::Failure)
                .map(|c| c.name.clone()),
            passed: checks
                .iter()
                .filter(|c| c.state == CiState::Success)
                .count(),
            total: checks.len(),
        }
    }
}

/// What a PR's CI means for a bound item: `pending` → in-progress; `failure`
/// → blocked with the first failing check's name in the note; `success` →
/// done when `done_when_green`, else the status is left alone and the note
/// says `CI green`. No checks (or only skipped ones) leave the status alone.
pub fn map_pr_ci(obs: &CiObservation, done_when_green: bool) -> Desired {
    let counts = format!("{}/{} checks passed", obs.passed, obs.total);
    let (state, status, line) = match obs.state {
        CiState::Pending => (
            "pending",
            Some(Status::InProgress),
            format!("{CI_NOTE_PREFIX}pending ({counts})"),
        ),
        CiState::Failure => (
            "failure",
            Some(Status::Blocked),
            format!(
                "{CI_NOTE_PREFIX}failing: {}",
                obs.failing
                    .as_deref()
                    .map(clean_check_name)
                    .unwrap_or_default()
            ),
        ),
        CiState::Success => (
            "success",
            done_when_green.then_some(Status::Done),
            format!("{CI_NOTE_PREFIX}green"),
        ),
        CiState::Unknown => ("none", None, format!("{CI_NOTE_PREFIX}no checks reported")),
    };
    Desired {
        state: state.to_string(),
        status,
        note_line: line,
        link: None,
    }
}

/// A check name as a short single-line token.
fn clean_check_name(name: &str) -> String {
    let name: String = name.chars().filter(|c| !c.is_control()).take(120).collect();
    name.trim().to_string()
}

/// `note` with the source-owned first line (`prefix …`) replaced by `line`,
/// or `line` put first when the note has none. The rest of the note is kept.
pub fn with_source_line(note: Option<&str>, prefix: &str, line: &str) -> String {
    match note {
        None | Some("") => line.to_string(),
        Some(note) => {
            let (first, rest) = match note.split_once('\n') {
                Some((first, rest)) => (first, Some(rest)),
                None => (note, None),
            };
            if first.starts_with(prefix) {
                match rest {
                    Some(rest) => format!("{line}\n{rest}"),
                    None => line.to_string(),
                }
            } else {
                format!("{line}\n{note}")
            }
        }
    }
}

/// The feeds' way into the registry: each call applies what a source reports
/// to every item bound to it, on every board.
#[derive(Clone)]
pub struct BindingHub {
    registry: Arc<TrackerRegistry>,
}

impl BindingHub {
    pub fn new(registry: Arc<TrackerRegistry>) -> BindingHub {
        BindingHub { registry }
    }

    /// The Mother job list, as of `observed_at` (the last successful
    /// `mother list`; `None` = never, nothing is applied). Returns `true` if
    /// any bound item's view changed; call [`TrackerRegistry::flush`] after.
    pub fn apply_mother(&self, jobs: &[MotherJob], observed_at: Option<DateTime<Utc>>) -> bool {
        let Some(observed_at) = observed_at else {
            return false;
        };
        let mut changed = false;
        for bound in self.registry.live_bindings() {
            let Binding::MotherJob { job_id } = &bound.binding else {
                continue;
            };
            let Some(job) = jobs.iter().find(|j| &j.id == job_id) else {
                continue;
            };
            changed |= self.registry.apply_source(
                &bound.path,
                &bound.item_id,
                &map_mother_job(job),
                observed_at,
            );
        }
        changed
    }

    /// One PR's CI, as of `observed_at`.
    pub fn apply_ci(
        &self,
        repo: &str,
        number: u64,
        obs: &CiObservation,
        observed_at: DateTime<Utc>,
    ) -> bool {
        let mut changed = false;
        for bound in self.registry.live_bindings() {
            let Binding::PrCi {
                repo: r,
                number: n,
                done_when_green,
            } = &bound.binding
            else {
                continue;
            };
            if r.eq_ignore_ascii_case(repo) && *n == number {
                changed |= self.registry.apply_source(
                    &bound.path,
                    &bound.item_id,
                    &map_pr_ci(obs, *done_when_green),
                    observed_at,
                );
            }
        }
        changed
    }

    /// The distinct PRs some item is bound to (what the CI poller watches).
    pub fn bound_prs(&self) -> Vec<(String, u64)> {
        let mut prs: Vec<(String, u64)> = self
            .registry
            .live_bindings()
            .into_iter()
            .filter_map(|b| match b.binding {
                Binding::PrCi { repo, number, .. } => Some((repo, number)),
                _ => None,
            })
            .collect();
        prs.sort();
        prs.dedup();
        prs
    }

    /// Writes what the throttle has been holding back and re-checks
    /// staleness. Returns `true` if a view changed; call
    /// [`TrackerRegistry::flush`] after.
    pub fn tick(&self) -> bool {
        self.registry.tick_live()
    }
}

/// The Mother feed of bound items: applies the job list whenever it or its
/// source state changes, and every [`MOTHER_FEED_TICK`] (a newly bound item
/// has no change to wait for). Runs for the life of the daemon.
pub async fn run_mother_feed(
    registry: Arc<TrackerRegistry>,
    tx: tokio::sync::broadcast::Sender<crate::ipc::protocol::ServerMsg>,
    feed: crate::mother::JobsFeed,
) {
    let hub = BindingHub::new(Arc::clone(&registry));
    let mut jobs_rx = feed.jobs_rx();
    let mut source_rx = feed.source_rx();
    let mut ticker = tokio::time::interval(MOTHER_FEED_TICK);
    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            changed = jobs_rx.changed() => if changed.is_err() { return },
            changed = source_rx.changed() => if changed.is_err() { return },
        }
        let jobs = jobs_rx.borrow_and_update().clone();
        let observed_at = source_rx.borrow_and_update().updated_at();
        hub.apply_mother(&jobs, observed_at);
        registry.flush(&tx);
    }
}

/// How often the Mother feed re-applies the job list.
pub const MOTHER_FEED_TICK: Duration = Duration::from_secs(2);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bindings_round_trip_through_their_key() {
        for key in [
            "mother.job/20261030T170317Z-a1ae52a1",
            "pr.ci/Carefeed/admin-portal#253",
            "pr.ci/o/r.js#7!green",
        ] {
            assert_eq!(Binding::parse(key).unwrap().to_key(), key);
        }
    }

    #[test]
    fn unknown_sources_and_malformed_keys_are_errors() {
        for bad in [
            "sentry/PORTAL-1F2",
            "cloudwatch/x",
            "mother.job/",
            "mother.job/a b",
            "pr.ci/o/r",
            "pr.ci/o/r#0",
            "pr.ci/o/r#x",
            "pr.ci/o#1",
            "pr.ci/owner/..#1",
            "pr.ci/owner/.#1",
            "pr.ci/./x#1",
            "pr.ci/../x#1",
            "nonsense",
            "",
        ] {
            assert!(Binding::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_source_line_replaces_only_its_own_first_line() {
        assert_eq!(with_source_line(None, "CI ", "CI green"), "CI green");
        assert_eq!(
            with_source_line(Some("CI pending (1/2 checks passed)"), "CI ", "CI green"),
            "CI green"
        );
        assert_eq!(
            with_source_line(Some("CI pending\nmy own note"), "CI ", "CI green"),
            "CI green\nmy own note"
        );
        assert_eq!(
            with_source_line(Some("my own note"), "CI ", "CI green"),
            "CI green\nmy own note"
        );
    }
}
