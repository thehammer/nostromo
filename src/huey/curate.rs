//! The curated model pass (A3): one hidden, restricted Claude Code session per
//! normal or tight run.
//!
//! [`SessionCurator`] is the production [`Curator`]. For one run it:
//!
//! 1. makes an empty scratch directory to run the session in;
//! 2. builds the model input ([`build_model_input`]: the instructions, the
//!    mode's limits, the digest verbatim, the fenced candidates, the
//!    Also-in-the-news candidates and the recent reports) and writes it to
//!    `model-input.txt`, fsynced, **before** anything is sent (T8);
//! 3. starts the [`HUEY_RUN_TAG`] session under [`huey_run_restrictions`]
//!    (two Huey tools plus `ToolSearch`, the mode's model and spend cap) and
//!    sends it that text;
//! 4. waits for an accepted `huey.publish_report`, at most
//!    [`MAX_PUBLISH_ATTEMPTS`] publishes, the session dying, or the timeout;
//! 5. always ends the session, then deletes the scratch directory and the
//!    run's transcript directory, as Teri's picks do.
//!
//! The session talks back through the MCP tools, which reach the run through
//! the [`CurateBridge`]. Every check result is appended to `model-input.txt`
//! and to the digest's "Checks Huey ran" section before the model sees it,
//! so the digest shown beside the report is exactly what the model learned
//! (AC22). Every publish result (an acceptance or the refusal reasons) is
//! appended to `model-input.txt` too: the file holds every byte Huey
//! supplied to the model.
//!
//! Nothing here logs digest text, news text or anything the model wrote (T5).

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio::sync::{oneshot, Mutex};
use tokio::time::Instant;
use tracing::{info, warn};

use crate::data::work::picks::{PicksSessionHost, RunTranscripts, ScratchDir};
use crate::data::work::untrusted::{escape_id, one_line, unescape_id, NonceFence};
use crate::huey::budget::Mode;
use crate::huey::checks::{self, CheckResult, Probe};
use crate::huey::config::HueyConfig;
use crate::huey::context::digest::append_checks;
use crate::huey::items::{NewsItem, SourceClass};
use crate::huey::prompts;
use crate::huey::render::date_prefix;
use crate::huey::run::{CurateError, CurateInput, Curator, Publish};
use crate::huey::validate;
use crate::ipc::session_manager::SessionRestrictions;

/// Tag of the hidden curating session.
pub const HUEY_RUN_TAG: &str = "huey-run";
/// The MCP tools the curating session may call, as the daemon names them. The
/// daemon's MCP dispatch refuses every other tool for the [`HUEY_RUN_TAG`] caller.
pub const HUEY_RUN_TOOLS: [&str; 2] = ["huey.check_project", "huey.publish_report"];
/// The same tools as `claude` names them (`mcp__<server>__<tool>`).
pub const HUEY_RUN_MCP_TOOLS: [&str; 2] = [
    "mcp__nostromo__huey_check_project",
    "mcp__nostromo__huey_publish_report",
];
/// Built-in tools the session keeps: only the one that loads deferred MCP tools.
pub const HUEY_RUN_BUILTIN_TOOLS: [&str; 1] = ["ToolSearch"];
/// How long one run may take before it counts as failed (T13).
pub const CURATE_TIMEOUT: Duration = Duration::from_secs(4 * 60);
/// Publishes the model may try before the run fails (T13).
pub const MAX_PUBLISH_ATTEMPTS: usize = 3;
/// Name prefix of a run's scratch directory.
pub const SCRATCH_PREFIX: &str = "nostromo-huey-run-";

/// The digest sits verbatim between these two lines of the model input.
pub const DIGEST_BEGIN: &str = "=== DIGEST: the user's context (cite the ids in brackets) ===\n";
pub const DIGEST_END: &str = "=== END DIGEST ===\n";
/// The mode's caps, as the model input states them (AC6, AC32).
pub const LIMITS_NORMAL: &str = "Limits: max 5 picks, max 5 Also noted.";
pub const LIMITS_TIGHT: &str = "Limits: max 3 picks, no Also noted.";

/// Longest title carried into the model input, in characters.
const TITLE_CHARS: usize = 300;
/// Text kept for an Also-in-the-news candidate that is not also a story.
const AIN_TEXT_CHARS: usize = 2_000;
/// How often the run looks at whether the session is still alive.
const ALIVE_POLL: Duration = Duration::from_millis(500);

/// The allow-list, model and cap a curating session runs under (T3).
pub fn huey_run_restrictions(model: &str, max_budget_usd: f64) -> SessionRestrictions {
    SessionRestrictions {
        builtin_tools: HUEY_RUN_BUILTIN_TOOLS
            .iter()
            .map(|t| t.to_string())
            .collect(),
        allowed_tools: HUEY_RUN_MCP_TOOLS
            .iter()
            .chain(HUEY_RUN_BUILTIN_TOOLS.iter())
            .map(|t| t.to_string())
            .collect(),
        max_budget_usd: Some(max_budget_usd),
        model: Some(model.to_string()),
    }
}

/// What the tag is registered with before any run: normal mode's defaults.
/// Each run registers its own mode's model and cap.
pub fn default_huey_run_restrictions() -> SessionRestrictions {
    let config = HueyConfig::default();
    huey_run_restrictions(&config.model, config.max_budget_usd)
}

// ── the model input ──────────────────────────────────────────────────────────

fn when(item: &NewsItem) -> String {
    match item.published_at {
        Some(at) => format!("published {}", at.format("%Y-%m-%d %H:%M UTC")),
        None => format!(
            "first seen {}",
            item.first_seen_at.format("%Y-%m-%d %H:%M UTC")
        ),
    }
}

fn class_label(item: &NewsItem) -> &'static str {
    match item.class {
        SourceClass::FirstParty => "first-party",
        SourceClass::Curated => "curated",
        SourceClass::Aggregator => "aggregator",
    }
}

/// Everything the curating session is sent: the instructions, the mode's
/// limits, the digest verbatim between [`DIGEST_BEGIN`] and [`DIGEST_END`],
/// every candidate story (titles and texts inside one nonce fence), the
/// Also-in-the-news candidates and the recent reports. News text appears
/// only inside the fence (T4); links are never given (the daemon owns them).
pub fn build_model_input(input: &CurateInput) -> String {
    let fence = NonceFence::new();
    let mut out = String::new();
    out.push_str(prompts::CURATE);
    out.push('\n');
    write_run_header(&mut out, input);
    write_digest(&mut out, input);
    let story_ids = write_candidates(&mut out, input, &fence);
    write_ain_candidates(&mut out, input, &fence, &story_ids);
    write_recent_reports(&mut out, input, &fence);
    out
}

fn write_run_header(out: &mut String, input: &CurateInput) {
    let limits = if input.mode == Mode::Tight {
        LIMITS_TIGHT
    } else {
        LIMITS_NORMAL
    };
    let _ = writeln!(out, "## This run");
    let _ = writeln!(
        out,
        "Report date: {} Version {}. Mode: {}.",
        date_prefix(input.date),
        input.version,
        input.mode.as_str()
    );
    let _ = writeln!(out, "{limits}");
    out.push('\n');
}

fn write_digest(out: &mut String, input: &CurateInput) {
    out.push_str(DIGEST_BEGIN);
    out.push_str(&input.digest.text);
    if !input.digest.text.ends_with('\n') {
        out.push('\n');
    }
    out.push_str(DIGEST_END);
    out.push('\n');
}

/// Every candidate story; the ids of the items shown, for the
/// Also-in-the-news section to point back to.
fn write_candidates<'a>(
    out: &mut String,
    input: &'a CurateInput,
    fence: &NonceFence,
) -> BTreeSet<&'a str> {
    let _ = writeln!(
        out,
        "## Candidate news: {} stories, best source first in each",
        input.candidates.len()
    );
    let mut story_ids = BTreeSet::new();
    for (n, story) in input.candidates.iter().enumerate() {
        let _ = writeln!(out, "### Story {}", n + 1);
        for item in &story.items {
            let Some(id) = escape_id(&item.id) else {
                continue;
            };
            story_ids.insert(item.id.as_str());
            let _ = writeln!(
                out,
                "- [{id}] {} · {} · {}",
                class_label(item),
                one_line(&input.frame.source_name(item), 80),
                when(item)
            );
            let _ = writeln!(out, "  Title: {}", fence.line(&item.title, TITLE_CHARS));
            let _ = writeln!(out, "{}", fence.block(&item.text));
        }
    }
    if input.candidates.is_empty() {
        let _ = writeln!(out, "(none)");
    }
    out.push('\n');
    story_ids
}

fn write_ain_candidates(
    out: &mut String,
    input: &CurateInput,
    fence: &NonceFence,
    story_ids: &BTreeSet<&str>,
) {
    let _ = writeln!(
        out,
        "## Also-in-the-news candidates (first-party, past 7 days)"
    );
    for item in &input.ain_candidates {
        let Some(id) = escape_id(&item.id) else {
            continue;
        };
        let _ = writeln!(
            out,
            "- [{id}] {} · {}",
            one_line(&input.frame.source_name(item), 80),
            when(item)
        );
        let _ = writeln!(out, "  Title: {}", fence.line(&item.title, TITLE_CHARS));
        if story_ids.contains(item.id.as_str()) {
            let _ = writeln!(out, "  (its text is under Candidate news)");
        } else {
            let text: String = item.text.chars().take(AIN_TEXT_CHARS).collect();
            let _ = writeln!(out, "{}", fence.block(&text));
        }
    }
    if input.ain_candidates.is_empty() {
        let _ = writeln!(out, "(none: publish also_in_the_news as null)");
    }
    out.push('\n');
}

fn write_recent_reports(out: &mut String, input: &CurateInput, fence: &NonceFence) {
    let _ = writeln!(
        out,
        "## Recent reports (last 14 days; use these ids for follow_up_of)"
    );
    for entry in &input.recent_shown {
        let Some(id) = escape_id(&entry.item_id) else {
            continue;
        };
        let title = input
            .frame
            .items
            .get(&entry.item_id)
            .map(|i| format!(": {}", fence.line(&i.title, TITLE_CHARS)))
            .unwrap_or_default();
        let _ = writeln!(out, "- [{id}] {} {:?}{title}", entry.date, entry.section);
    }
    if input.recent_shown.is_empty() {
        let _ = writeln!(out, "(none)");
    }
}

// ── the bridge between the run and the MCP tools ─────────────────────────────

/// How a run ended from the model's side.
enum RunEnd {
    Accepted(Box<Publish>),
    Exhausted,
    /// A tool answer could not be recorded: the capture would no longer be
    /// every byte the model was given, so the run is not kept (T8).
    RecordFailed,
}

/// One run in progress.
struct ActiveRun {
    /// The run's input; its digest gains the checks as they run.
    input: CurateInput,
    checks: Vec<CheckResult>,
    attempts: usize,
    model_input: PathBuf,
    digest_file: PathBuf,
    done: Option<oneshot::Sender<RunEnd>>,
}

impl ActiveRun {
    /// Published, exhausted, failed or abandoned (the curator stopped
    /// listening): no tool call acts on it any more.
    fn is_over(&self) -> bool {
        self.done.as_ref().is_none_or(|d| d.is_closed())
    }

    fn finish(&mut self, end: RunEnd) {
        if let Some(done) = self.done.take() {
            let _ = done.send(end);
        }
    }

    /// Append one tool call's answer to `model-input.txt`. On failure the
    /// run ends: an unrecorded answer must not reach the model.
    fn record(&mut self, header: &str, answer: &Value) -> bool {
        let ok = append_synced(&self.model_input, &format!("\n--- {header}\n{answer}\n")).is_ok();
        if !ok {
            warn!("huey: a tool answer could not be recorded");
            self.finish(RunEnd::RecordFailed);
        }
        ok
    }
}

fn finished() -> Value {
    json!({ "ok": false, "error": "finished", "message": "this run is over; stop now" })
}

fn not_recorded() -> Value {
    json!({ "error": "not_recorded", "message": "the answer could not be recorded; stop now" })
}

/// The run in progress, shared by the curator and the `huey.*` MCP tools
/// the curating session calls. Cheap to clone.
#[derive(Clone, Default)]
pub struct CurateBridge {
    active: Arc<Mutex<Option<ActiveRun>>>,
}

impl std::fmt::Debug for CurateBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CurateBridge").finish_non_exhaustive()
    }
}

fn no_run() -> Value {
    json!({ "error": "no_run", "message": "no Huey run is in progress" })
}

/// Append `text` to `path` and flush it to disk.
fn append_synced(path: &Path, text: &str) -> std::io::Result<()> {
    let mut f = std::fs::OpenOptions::new().append(true).open(path)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()
}

/// Write `text` to `path` (replacing it) and flush it to disk.
fn write_synced(path: &Path, text: &str) -> std::io::Result<()> {
    let mut f = std::fs::File::create(path)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()
}

/// A `check_project` call's project and probe. `Err` is the tool's answer.
pub fn parse_check_args(args: &Value) -> Result<(String, Probe), Value> {
    let bad = |message: &str| json!({ "error": "invalid_argument", "message": message });
    let field = |name: &str| args.get(name).and_then(Value::as_str).map(str::to_string);
    let project = field("project")
        .filter(|p| !p.trim().is_empty())
        .ok_or_else(|| bad("`project` (a project id from the digest) is required"))?;
    let probe = match field("kind").as_deref() {
        Some("dependency") => Probe::Dependency {
            name: field("name").ok_or_else(|| bad("a dependency check needs `name`"))?,
        },
        Some("text") => Probe::Text {
            term: field("term").ok_or_else(|| bad("a text check needs `term`"))?,
        },
        Some("claude_feature") => Probe::ClaudeFeature {
            feature: field("feature")
                .ok_or_else(|| bad("a claude_feature check needs `feature`"))?,
        },
        Some("invocation") => Probe::Invocation,
        _ => {
            return Err(bad(
                "`kind` must be dependency, text, claude_feature or invocation",
            ))
        }
    };
    Ok((project, probe))
}

/// A check result as the tool returns it. `line` is exactly the digest line.
pub fn check_answer(result: &CheckResult) -> Value {
    json!({
        "ok": true,
        "id": result.id,
        "found": result.found,
        "detail": result.detail,
        "paths": result.paths,
        "line": result.line(),
    })
}

/// Answer `probe` for the project whose main worktree is `root`, off the
/// async workers (it runs git). `Err` is the tool's refusal.
pub async fn run_check(
    id: String,
    project: String,
    root: PathBuf,
    probe: Probe,
) -> Result<CheckResult, Value> {
    let answer =
        tokio::task::spawn_blocking(move || checks::check(&id, &project, &root, &probe)).await;
    match answer {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(refused)) => Err(json!({ "error": "refused", "message": refused.to_string() })),
        Err(_) => Err(json!({ "error": "check_failed", "message": "the check could not run" })),
    }
}

/// Every item id field of `publish`, unescaped (the input shows ids escaped).
fn unescape_ids(mut publish: Publish) -> Publish {
    let un = |ids: &mut Vec<String>| ids.iter_mut().for_each(|id| *id = unescape_id(id));
    for p in &mut publish.picks {
        un(&mut p.item_ids);
        if let Some(of) = &mut p.follow_up_of {
            *of = unescape_id(of);
        }
    }
    if let Some(a) = &mut publish.also_in_the_news {
        a.item_id = unescape_id(&a.item_id);
    }
    for n in &mut publish.also_noted {
        un(&mut n.item_ids);
    }
    for d in &mut publish.dropped {
        d.item_id = unescape_id(&d.item_id);
    }
    un(&mut publish.ignored);
    publish
}

/// Parse and validate a publish against the run; `Err` is the refusal reasons.
fn judge_publish(run: &ActiveRun, args: &Value) -> Result<Publish, Vec<String>> {
    match serde_json::from_value::<Publish>(args.clone()) {
        Ok(publish) => validate::validate(&run.input, &unescape_ids(publish), &run.checks)
            .map_err(|problems| problems.iter().map(ToString::to_string).collect()),
        Err(e) => Err(vec![one_line(
            &format!("the publish does not match the schema: {e}"),
            300,
        )]),
    }
}

impl CurateBridge {
    pub fn new() -> Self {
        Self::default()
    }

    /// True while a run is in progress.
    pub fn is_active(&self) -> bool {
        self.active.try_lock().map_or(true, |run| run.is_some())
    }

    /// Start a run: `huey.check_project` and `huey.publish_report` act on it
    /// from now on. The receiver hears how it ended.
    async fn begin(
        &self,
        input: CurateInput,
        model_input: PathBuf,
        digest_file: PathBuf,
    ) -> oneshot::Receiver<RunEnd> {
        let (tx, rx) = oneshot::channel();
        *self.active.lock().await = Some(ActiveRun {
            input,
            checks: Vec::new(),
            attempts: 0,
            model_input,
            digest_file,
            done: Some(tx),
        });
        rx
    }

    /// Forget the run without waiting (a cancelled curate). A check still
    /// holding the lock finds the run over: its curator stopped listening.
    fn abandon(&self) {
        if let Ok(mut run) = self.active.try_lock() {
            run.take();
        }
    }

    /// End the run; its check results.
    async fn end(&self) -> Vec<CheckResult> {
        self.active
            .lock()
            .await
            .take()
            .map(|run| run.checks)
            .unwrap_or_default()
    }

    /// `huey.check_project` for the curating session: run the probe against
    /// one of the run's projects, record the answer in `model-input.txt` and
    /// (for a check that ran, id `c<n>`) the digest, then answer. The run
    /// takes the check only once both are on disk (T8). Held for the whole
    /// check, so checks run one at a time and ids follow the recorded order.
    pub async fn check_project(&self, args: &Value) -> Value {
        let mut guard = self.active.lock().await;
        let Some(run) = guard.as_mut() else {
            return no_run();
        };
        if run.is_over() {
            return finished();
        }
        let header = format!("huey_check_project {}", one_line(&args.to_string(), 600));
        let ran = match parse_check_args(args) {
            Err(answer) => Err(answer),
            Ok((project, probe)) => match run.input.project_roots.get(&project).cloned() {
                None => Err(json!({
                    "error": "unknown_project",
                    "message": "not a project in the digest; use a project id from \"Projects in flight\"",
                })),
                Some(root) => {
                    let id = format!("c{}", run.checks.len() + 1);
                    run_check(id, project, root, probe).await
                }
            },
        };
        let result = match ran {
            Ok(result) => result,
            // Refused: nothing ran and nothing was learned, so no id; the
            // answer is still recorded as given.
            Err(answer) => {
                return if run.record(&header, &answer) {
                    answer
                } else {
                    not_recorded()
                };
            }
        };
        let answer = check_answer(&result);
        let mut digest = run.input.digest.clone();
        append_checks(&mut digest, std::slice::from_ref(&result));
        if write_synced(&run.digest_file, &digest.text).is_err() {
            warn!("huey: a check could not be recorded");
            run.finish(RunEnd::RecordFailed);
            return not_recorded();
        }
        if !run.record(&header, &answer) {
            return not_recorded();
        }
        info!(
            kind = result.probe.kind(),
            checks = run.checks.len() + 1,
            "huey: check ran"
        );
        run.input.digest = digest;
        run.checks.push(result);
        answer
    }

    /// `huey.publish_report`: validate the publish (A4). Accepted, the run
    /// ends with it; refused, the answer names every problem, and the run
    /// ends after the last attempt.
    pub async fn publish(&self, args: &Value) -> Value {
        let mut guard = self.active.lock().await;
        let Some(run) = guard.as_mut() else {
            return no_run();
        };
        if run.is_over() {
            return finished();
        }
        run.attempts += 1;
        let verdict = judge_publish(run, args);
        let left = MAX_PUBLISH_ATTEMPTS.saturating_sub(run.attempts);
        let (answer, end) = match verdict {
            Ok(publish) => (
                json!({ "ok": true, "message": "Published. Your work is done: stop now." }),
                Some(RunEnd::Accepted(Box::new(publish))),
            ),
            Err(problems) => {
                let message = if left == 0 {
                    "refused, and no attempts are left: stop now".to_string()
                } else {
                    format!("refused: fix every problem and publish again ({left} attempts left)")
                };
                (
                    json!({
                        "ok": false,
                        "error": "refused",
                        "message": message,
                        "problems": problems,
                        "attempts_left": left,
                    }),
                    (left == 0).then_some(RunEnd::Exhausted),
                )
            }
        };
        info!(
            attempt = run.attempts,
            accepted = answer["ok"] == true,
            problems = answer["problems"].as_array().map_or(0, Vec::len),
            "huey: publish"
        );
        let header = format!("huey_publish_report (attempt {})", run.attempts);
        if !run.record(&header, &answer) {
            return not_recorded();
        }
        if let Some(end) = end {
            run.finish(end);
        }
        answer
    }
}

// ── the curator ──────────────────────────────────────────────────────────────

/// What a curator needs from the machine it runs on; tests supply their own.
#[derive(Debug, Clone)]
pub struct CuratorEnv {
    /// Where `claude` keeps per-directory transcripts (`~/.claude/projects`);
    /// `None` leaves them alone.
    pub projects_dir: Option<PathBuf>,
    /// Where each run's scratch directory is made; `None` is `$TMPDIR`.
    pub scratch_root: Option<PathBuf>,
    pub timeout: Duration,
}

impl CuratorEnv {
    /// The real `~/.claude/projects`, the system temp directory and
    /// [`CURATE_TIMEOUT`].
    pub fn local() -> Self {
        Self {
            projects_dir: dirs_next::home_dir().map(|h| h.join(".claude").join("projects")),
            scratch_root: None,
            timeout: CURATE_TIMEOUT,
        }
    }
}

/// The production [`Curator`]: a hidden restricted session per run.
pub struct SessionCurator {
    host: Arc<dyn PicksSessionHost>,
    bridge: CurateBridge,
    env: CuratorEnv,
}

impl SessionCurator {
    pub fn new(host: Arc<dyn PicksSessionHost>, bridge: CurateBridge) -> Self {
        Self::with_env(host, bridge, CuratorEnv::local())
    }

    pub fn with_env(
        host: Arc<dyn PicksSessionHost>,
        bridge: CurateBridge,
        env: CuratorEnv,
    ) -> Self {
        Self { host, bridge, env }
    }

    /// Capture the input, start the session, send it and wait for the end.
    async fn drive(&self, input: &CurateInput, cwd: &Path) -> Result<Publish, CurateError> {
        let failed = |why: &str| CurateError::Failed(why.to_string());
        let model_input = input.report_dir.join("model-input.txt");
        let text = build_model_input(input);
        std::fs::create_dir_all(&input.report_dir)
            .and_then(|()| write_synced(&model_input, &text))
            .map_err(|_| failed("the model input could not be recorded"))?;
        let mut ended = self
            .bridge
            .begin(
                input.clone(),
                model_input,
                input.report_dir.join("digest.md"),
            )
            .await;

        self.host
            .spawn(
                HUEY_RUN_TAG,
                cwd,
                &huey_run_restrictions(&input.model, input.max_budget_usd),
            )
            .map_err(|_| failed("could not start the session"))?;
        self.host
            .send(HUEY_RUN_TAG, &text)
            .map_err(|_| failed("could not send the model input"))?;

        let deadline = Instant::now() + self.env.timeout;
        loop {
            let wake = deadline.min(Instant::now() + ALIVE_POLL);
            tokio::select! {
                end = &mut ended => {
                    return match end {
                        Ok(RunEnd::Accepted(publish)) => Ok(*publish),
                        Ok(RunEnd::Exhausted) => Err(failed("every publish was refused")),
                        Ok(RunEnd::RecordFailed) => Err(failed("a tool answer could not be recorded")),
                        Err(_) => Err(failed("the run ended without a publish")),
                    };
                }
                _ = tokio::time::sleep_until(wake) => {}
            }
            if Instant::now() >= deadline {
                return Err(failed("timed out"));
            }
            if !self.host.is_alive(HUEY_RUN_TAG) {
                return Err(failed("the session ended before it published"));
            }
        }
    }
}

/// Ends a run's session and removes its scratch directory and transcripts
/// when dropped: after a finished run, and equally when the curate future is
/// cancelled (the run's outer deadline), so no session or transcript of
/// third-party text outlives its run.
struct RunCleanup<'a> {
    host: &'a dyn PicksSessionHost,
    bridge: &'a CurateBridge,
    scratch: Option<ScratchDir>,
    transcripts: Option<RunTranscripts>,
}

impl Drop for RunCleanup<'_> {
    fn drop(&mut self) {
        self.bridge.abandon();
        self.host.stop(HUEY_RUN_TAG);
        drop(self.scratch.take());
        if let Some(transcripts) = self.transcripts.take() {
            transcripts.remove();
        }
    }
}

#[allow(clippy::double_must_use)]
#[async_trait]
impl Curator for SessionCurator {
    async fn curate(&self, input: &CurateInput) -> Result<Publish, CurateError> {
        let started = SystemTime::now();
        let scratch = ScratchDir::create(self.env.scratch_root.as_deref(), SCRATCH_PREFIX)
            .map_err(|_| CurateError::Failed("could not make a working directory".into()))?;
        let cwd = scratch.path().to_path_buf();
        // Worked out while the directory exists: `claude` files transcripts
        // under its real path.
        let transcripts = self
            .env
            .projects_dir
            .as_deref()
            .map(|p| RunTranscripts::new(p, &cwd, SCRATCH_PREFIX, started));
        let cleanup = RunCleanup {
            host: self.host.as_ref(),
            bridge: &self.bridge,
            scratch: Some(scratch),
            transcripts,
        };
        let outcome = self.drive(input, &cwd).await;
        // No tool call acts on the run after this; then the session ends and
        // its files go, on every path.
        let checks = self.bridge.end().await;
        drop(cleanup);
        let checks_json = serde_json::to_vec_pretty(&checks).unwrap_or_default();
        if std::fs::write(input.report_dir.join("checks.json"), checks_json).is_err() {
            warn!("huey: checks.json could not be written");
        }
        info!(
            ok = outcome.is_ok(),
            checks = checks.len(),
            "huey: curating session ended"
        );
        outcome
    }
}
