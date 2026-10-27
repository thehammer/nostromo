//! `nostromo-huey-eval`: the opt-in, real-model eval of Huey's judgement.
//!
//! ```text
//! nostromo-huey-eval --scenarios tests/fixtures/huey/eval [--only NAME] [--model M]
//! ```
//!
//! For each scenario it runs the real pipeline (`SessionCurator` through a
//! real `SessionManager` and the real `claude`, boxed exactly as in the
//! daemon) on the scenario's frozen pool and context, in a throwaway state
//! root and home, and prints PASS or FAIL for each assertion in the
//! scenario's `expect.toml`.
//!
//! **Never run in CI.** Each scenario is one model run on your Claude
//! subscription (two for `php-two-machines`). Nothing here is referenced by
//! the test suite; a guard test keeps it that way. See `docs/huey.md`.
//!
//! It touches nothing of yours: state, home, code root and the scenario's
//! posture file live in a temp directory, and the daemon-side MCP server it
//! starts listens on a socket inside it. (Like `nostromd`, it refreshes
//! `~/.nostromo/mcp-bridge.json`, the file that points sessions at
//! `nostromo-mcp-bridge`; the bridge binary must sit beside this one, so build
//! with `cargo build --bins`.)

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{DateTime, NaiveDate, Utc};
use clap::Parser;
use serde::Deserialize;
use serde_json::{json, Value};

use nostromo::huey::context::ContextEnv;
use nostromo::huey::curate::{CuratorEnv, SessionCurator};
use nostromo::huey::items::canonicalize;
use nostromo::huey::render::{self, PickCheck, Report};
use nostromo::huey::schedule::FixedLocalTime;
use nostromo::huey::store::Store;
use nostromo::huey::{setup, HueyConfig, HueyDeps, HueyEngine, RunOutcome, Trigger};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{
    write_bridge_mcp_config, DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState,
    TicketRegistryState,
};
use nostromo::tracker::clock::FakeClock;

#[derive(Parser)]
#[command(about = "Run Huey's real-model eval scenarios (opt-in; costs model runs)")]
struct Args {
    /// Directory of scenarios (each a directory with an `expect.toml`).
    #[arg(long)]
    scenarios: PathBuf,
    /// Run only this scenario.
    #[arg(long)]
    only: Option<String>,
    /// Model for normal and tight runs (default: the configured default).
    #[arg(long)]
    model: Option<String>,
}

// ── scenario files ───────────────────────────────────────────────────────────

/// `expect.toml`: the scenario's date and one `[[run]]` table per run (more
/// than one when the same pool runs against several contexts).
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Expect {
    /// What the scenario pins (criterion ids).
    #[serde(default)]
    description: String,
    /// The report date, `YYYY-MM-DD`.
    date: String,
    run: Vec<Checks>,
}

/// One run's context and assertions; every assertion is optional. Item ids
/// are the ids in `pool.json`.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Checks {
    /// Subdirectory of `context/` for this run (default: `context/` itself).
    context: Option<String>,
    mode: Option<String>,
    picks_min: Option<usize>,
    picks_max: Option<usize>,
    /// Each of these items is in some pick.
    #[serde(default)]
    pick_items_include: Vec<String>,
    /// None of these items is in any pick.
    #[serde(default)]
    pick_items_exclude: Vec<String>,
    /// Every pick is about one of these projects.
    #[serde(default)]
    pick_projects_only: Vec<String>,
    /// Each of these projects has a pick.
    #[serde(default)]
    pick_projects_include: Vec<String>,
    checked_picks_min: Option<usize>,
    to_check_max: Option<usize>,
    /// Every pick has a headline, a link, anchors and a check.
    #[serde(default)]
    picks_well_formed: bool,
    /// Each of these items is shown somewhere in the report.
    #[serde(default)]
    shown_items_include: Vec<String>,
    /// None of these items is shown anywhere in the report.
    #[serde(default)]
    shown_items_exclude: Vec<String>,
    /// `present` or `absent`.
    ain: Option<String>,
    ain_item: Option<String>,
    also_noted_max: Option<usize>,
    /// A pick follows up this earlier item and says what is new.
    follow_up_of: Option<String>,
    word_total_max: Option<usize>,
    word_body_max: Option<usize>,
    #[serde(default)]
    footer_contains: Vec<String>,
    #[serde(default)]
    markdown_contains: Vec<String>,
    #[serde(default)]
    markdown_excludes: Vec<String>,
    #[serde(default)]
    digest_excludes: Vec<String>,
}

/// One run of one scenario: which context directory, and what to assert.
struct Planned<'a> {
    label: String,
    /// Directory holding `code/`, `home/` and optionally `interests.md` and
    /// `posture.json` (else the scenario's own).
    context: PathBuf,
    checks: &'a Checks,
}

fn plan<'a>(dir: &Path, expect: &'a Expect) -> Vec<Planned<'a>> {
    let name = dir.file_name().unwrap_or_default().to_string_lossy();
    expect
        .run
        .iter()
        .map(|r| match &r.context {
            Some(sub) => Planned {
                label: format!("{name}/{sub}"),
                context: dir.join("context").join(sub),
                checks: r,
            },
            None => Planned {
                label: name.to_string(),
                context: dir.join("context"),
                checks: r,
            },
        })
        .collect()
}

fn load_expect(dir: &Path) -> Result<Expect> {
    let text = std::fs::read_to_string(dir.join("expect.toml"))
        .with_context(|| format!("reading {}/expect.toml", dir.display()))?;
    toml::from_str(&text).with_context(|| format!("parsing {}/expect.toml", dir.display()))
}

/// A file from the context directory, else the scenario's.
fn find_file(context: &Path, scenario: &Path, name: &str) -> Result<PathBuf> {
    [context.join(name), scenario.join(name)]
        .into_iter()
        .find(|p| p.is_file())
        .ok_or_else(|| {
            anyhow!(
                "no {name} in {} or {}",
                context.display(),
                scenario.display()
            )
        })
}

// ── the pool ─────────────────────────────────────────────────────────────────

/// Expand the compact `pool.json` (items with `id`, `class`, `title`, `url`,
/// `published`, `text`, optional `links`) into the engine's `FetchOutcome`.
/// Sources of the three default first-party kinds that have no item are
/// reported quiet, so a fetch never looks failed.
fn expand_pool(compact: &Value, now: DateTime<Utc>) -> Result<Value> {
    let mut items = Vec::new();
    for raw in compact["items"].as_array().cloned().unwrap_or_default() {
        let get = |k: &str| {
            raw[k]
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| anyhow!("pool item lacks `{k}`: {raw}"))
        };
        let id = get("id")?;
        let published: DateTime<Utc> = get("published")?.parse()?;
        let url = get("url")?;
        items.push(json!({
            "id": id,
            "source_id": id.split(':').next().unwrap_or_default(),
            "class": get("class")?,
            "title": get("title")?,
            "canonical_url": canonicalize(&url),
            "url": url,
            "published_at": published,
            "first_seen_at": published,
            "text": get("text")?,
            "outbound_links": raw["links"].clone().as_array().cloned().unwrap_or_default(),
        }));
    }
    // Newest first, as the fetch leaves them.
    items.sort_by(|a, b| b["published_at"].as_str().cmp(&a["published_at"].as_str()));

    let mut recent = items.clone();
    for raw in compact["recent_extra"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        let published: DateTime<Utc> = raw["published"]
            .as_str()
            .ok_or_else(|| anyhow!("recent_extra item lacks `published`"))?
            .parse()?;
        let url = raw["url"].as_str().unwrap_or_default();
        let id = raw["id"].as_str().unwrap_or_default();
        recent.push(json!({
            "id": id,
            "source_id": id.split(':').next().unwrap_or_default(),
            "class": raw["class"],
            "title": raw["title"],
            "canonical_url": canonicalize(url),
            "url": url,
            "published_at": published,
            "first_seen_at": published,
            "text": raw["text"],
            "outbound_links": [],
        }));
    }
    recent.sort_by(|a, b| b["published_at"].as_str().cmp(&a["published_at"].as_str()));

    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut statuses = Vec::new();
    for item in &items {
        let source = item["source_id"].as_str().unwrap_or_default().to_string();
        if seen.insert(source.clone()) {
            let n = items
                .iter()
                .filter(|i| i["source_id"] == source.as_str())
                .count();
            statuses.push(json!({
                "id": source, "name": source, "class": item["class"],
                "outcome": {"state": "ok", "new": n},
            }));
        }
    }
    for source in [
        "claude-code-changelog",
        "claude-docs-release-notes",
        "anthropic-news",
    ] {
        if seen.insert(source.to_string()) {
            statuses.push(json!({
                "id": source, "name": source, "class": "first_party",
                "outcome": {"state": "quiet"},
            }));
        }
    }
    Ok(json!({"items": items, "recent": recent, "statuses": statuses, "fetched_at": now}))
}

// ── the throwaway machine ────────────────────────────────────────────────────

/// Copy `src` into `dst`; path components named `dot-x` become `.x`.
fn copy_tree(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let name = name
            .strip_prefix("dot-")
            .map_or(name.clone(), |rest| format!(".{rest}"));
        let target = dst.join(name);
        if entry.file_type()?.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn git(dir: &Path, args: &[&str], when: DateTime<Utc>) -> Result<()> {
    let stamp = when.to_rfc3339();
    let out = Command::new("git")
        .current_dir(dir)
        .args([
            "-c",
            "user.name=Eval",
            "-c",
            "user.email=eval@example.invalid",
        ])
        .args([
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .env("GIT_AUTHOR_DATE", &stamp)
        .env("GIT_COMMITTER_DATE", &stamp)
        .output()
        .context("running git")?;
    if !out.status.success() {
        bail!(
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

/// Make each project under `code` a git repository: one commit of its files
/// 3 days before `now`, then one empty commit per `<days ago>|<subject>` line
/// of its (removed) `.eval-commits` file.
fn init_repos(code: &Path, now: DateTime<Utc>) -> Result<()> {
    if !code.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(code)? {
        let dir = entry?.path();
        if !dir.is_dir() {
            continue;
        }
        let commits_file = dir.join(".eval-commits");
        let extra = std::fs::read_to_string(&commits_file).unwrap_or_default();
        let _ = std::fs::remove_file(&commits_file);
        git(&dir, &["init", "-q"], now)?;
        git(&dir, &["add", "-A"], now - chrono::Duration::days(3))?;
        git(
            &dir,
            &["commit", "-q", "-m", "Initial import"],
            now - chrono::Duration::days(3),
        )?;
        for line in extra.lines().filter(|l| !l.trim().is_empty()) {
            let (days, subject) = line
                .split_once('|')
                .ok_or_else(|| anyhow!(".eval-commits line lacks `|`"))?;
            let when = now - chrono::Duration::days(days.trim().parse()?);
            git(
                &dir,
                &["commit", "-q", "--allow-empty", "-m", subject.trim()],
                when,
            )?;
        }
    }
    Ok(())
}

/// What one run left behind.
struct Produced {
    report: Report,
    markdown: String,
    digest: String,
    mode: String,
    elapsed: Duration,
}

async fn run_once(
    scenario: &Path,
    context: &Path,
    date: NaiveDate,
    model: Option<&str>,
    work: &Path,
) -> Result<Produced> {
    let now: DateTime<Utc> = date.and_hms_opt(3, 0, 0).expect("03:00").and_utc();
    let home = work.join("home");
    let code = work.join("code");
    let state = work.join("state");
    for dir in [&home, &state] {
        std::fs::create_dir_all(dir)?;
    }
    if context.join("home").is_dir() {
        copy_tree(&context.join("home"), &home)?;
    }
    if context.join("code").is_dir() {
        copy_tree(&context.join("code"), &code)?;
    }
    init_repos(&code, now)?;
    std::fs::create_dir_all(home.join(".claude"))?;
    std::fs::copy(
        find_file(context, scenario, "posture.json")?,
        home.join(".claude").join("budget-posture.json"),
    )?;

    // Huey's own files: the interests file, then the pool, then confirm.
    let ctx = ContextEnv::for_home(&home, code, state.clone(), "Eval".into());
    let paths = nostromo::huey::HueyPaths::new(&state);
    std::fs::create_dir_all(paths.root())?;
    std::fs::copy(
        find_file(context, scenario, "interests.md")?,
        paths.interests(),
    )?;
    let compact: Value =
        serde_json::from_slice(&std::fs::read(find_file(context, scenario, "pool.json")?)?)?;
    std::fs::create_dir_all(paths.pool_dir())?;
    std::fs::write(
        paths.pool_dir().join(format!("{date}.json")),
        serde_json::to_vec_pretty(&expand_pool(&compact, now)?)?,
    )?;
    if let Ok(ledger) = find_file(context, scenario, "ledger.json") {
        std::fs::create_dir_all(paths.state_dir())?;
        std::fs::copy(ledger, Store::new(paths.clone()).ledger_file())?;
    }
    setup::confirm(&paths, now).map_err(|e| anyhow!("setup refused: {}", e.0))?;

    // The daemon's pieces, with the real `claude` behind them.
    let mut config = HueyConfig::default();
    if let Some(m) = model {
        config.model = m.to_string();
        config.tight_model = m.to_string();
    }
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        work.join("sessions.json"),
    )));
    let guard = nostromo::approvals::guard::resolve_guard_path();
    if guard == Path::new(nostromo::approvals::guard::GUARD_SENTINEL_PATH) {
        bail!("nostromo-guard not found beside this binary: run `cargo build --bins`");
    }
    session_mgr.lock().unwrap().set_guard_path(guard);
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        work.join("panes.json"),
    )));
    // A short path: unix socket paths are limited to about 100 bytes.
    let socket = PathBuf::from(format!("/tmp/nhe-{}-{}.sock", std::process::id(), date));
    let mcp_config = write_bridge_mcp_config().ok_or_else(|| anyhow!("no MCP bridge config"))?;
    session_mgr.lock().unwrap().configure_mcp_bridge(
        Arc::clone(&pane_registry),
        socket.clone(),
        mcp_config,
    );

    let mut deps = HueyDeps::new(state.clone(), config, ctx);
    deps.clock = Arc::new(FakeClock::new(now));
    deps.local_time = Arc::new(FixedLocalTime::utc());
    // The scheduler is parked: the one run is the one asked for below.
    deps.tick = Duration::from_secs(365 * 24 * 3600);
    deps.curator = Arc::new(SessionCurator::with_env(
        Arc::new(nostromo::data::work::picks::SessionManagerHost::new(
            Arc::clone(&session_mgr),
        )),
        deps.bridge.clone(),
        CuratorEnv::local(),
    ));
    let sources = HueyEngine::spawn(deps);

    let (broadcast_tx, _rx) = tokio::sync::broadcast::channel(64);
    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(DecisionRegistry::default())),
        tickets: TicketRegistryState::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    };
    let mut mcp_state = McpSharedState::for_daemon(backend);
    mcp_state.huey = Some(sources.handle.clone());
    mcp_state.huey_rx = sources.view_rx.clone();
    let _server = McpServer::bind(socket.clone(), mcp_state)
        .await
        .map_err(|e| anyhow!("MCP server: {e:#}"))?;

    // Regenerate reuses the frozen pool written above: no fetch happens.
    let started = Instant::now();
    let outcome = sources
        .handle
        .trigger(Trigger::Regenerate)
        .await
        .map_err(|e| anyhow!("run refused: {e}"))?;
    let elapsed = started.elapsed();
    let _ = std::fs::remove_file(&socket);
    let RunOutcome::Produced { version, mode, .. } = outcome else {
        bail!(
            "the run produced no report: {outcome:?} (for a model failure: is `claude` \
             installed and logged in, and `nostromo-mcp-bridge` beside this binary?)"
        );
    };
    let store = Store::new(paths);
    Ok(Produced {
        report: store
            .load_report(date, version)
            .ok_or_else(|| anyhow!("report.json missing"))?,
        markdown: store.load_markdown(date, version).unwrap_or_default(),
        digest: store.load_digest(date, version).unwrap_or_default(),
        mode: mode.as_str().to_string(),
        elapsed,
    })
}

// ── assertions ───────────────────────────────────────────────────────────────

struct Outcome {
    name: String,
    failure: Option<String>,
}

fn check(name: impl Into<String>, ok: bool, detail: impl FnOnce() -> String) -> Outcome {
    Outcome {
        name: name.into(),
        failure: (!ok).then(detail),
    }
}

fn evaluate(c: &Checks, p: &Produced) -> Vec<Outcome> {
    let r = &p.report;
    let mut out = Vec::new();
    let md = p.markdown.to_lowercase();
    let digest = p.digest.to_lowercase();
    let counts = render::word_counts(r);
    let shown: BTreeSet<&str> = r.shown_ids().into_iter().collect();
    let pick_ids: BTreeSet<&str> = r
        .picks
        .iter()
        .flat_map(|k| k.item_ids.iter().map(String::as_str))
        .collect();
    let n = r.picks.len();

    if let Some(m) = &c.mode {
        out.push(check(format!("mode is {m}"), &p.mode == m, || {
            format!("mode was {}", p.mode)
        }));
    }
    if let Some(min) = c.picks_min {
        out.push(check(format!("at least {min} picks"), n >= min, || {
            format!("{n} picks")
        }));
    }
    if let Some(max) = c.picks_max {
        out.push(check(format!("at most {max} picks"), n <= max, || {
            format!("{n} picks")
        }));
    }
    for id in &c.pick_items_include {
        out.push(check(
            format!("{id} is a pick"),
            pick_ids.contains(id.as_str()),
            || format!("picks cover: {pick_ids:?}"),
        ));
    }
    for id in &c.pick_items_exclude {
        out.push(check(
            format!("{id} is not a pick"),
            !pick_ids.contains(id.as_str()),
            || "it is in a pick".to_string(),
        ));
    }
    if !c.pick_projects_only.is_empty() {
        let stray: Vec<&str> = r
            .picks
            .iter()
            .map(|k| k.project.as_str())
            .filter(|k| !c.pick_projects_only.iter().any(|a| a == k))
            .collect();
        out.push(check(
            format!("picks are only about {:?}", c.pick_projects_only),
            stray.is_empty(),
            || format!("picks about {stray:?}"),
        ));
    }
    for project in &c.pick_projects_include {
        out.push(check(
            format!("a pick is about {project}"),
            r.picks.iter().any(|k| &k.project == project),
            || "no pick".to_string(),
        ));
    }
    let checked = r
        .picks
        .iter()
        .filter(|k| matches!(k.check, PickCheck::Checked { .. }))
        .count();
    if let Some(min) = c.checked_picks_min {
        out.push(check(
            format!("at least {min} Checked: picks"),
            checked >= min,
            || format!("{checked} checked"),
        ));
    }
    if let Some(max) = c.to_check_max {
        out.push(check(
            format!("at most {max} To check: picks"),
            n - checked <= max,
            || format!("{} to-check", n - checked),
        ));
    }
    if c.picks_well_formed {
        let bad: Vec<usize> = r
            .picks
            .iter()
            .enumerate()
            .filter(|(_, k)| {
                k.headline.trim().is_empty()
                    || !k.link.url.starts_with("https://")
                    || k.anchors.is_empty()
                    || k.for_line.trim().is_empty()
            })
            .map(|(i, _)| i + 1)
            .collect();
        out.push(check(
            "every pick has headline, https link, anchors, For line",
            bad.is_empty(),
            || format!("picks {bad:?} are incomplete"),
        ));
    }
    for id in &c.shown_items_include {
        out.push(check(
            format!("{id} is shown"),
            shown.contains(id.as_str()),
            || "not in the report".to_string(),
        ));
    }
    for id in &c.shown_items_exclude {
        out.push(check(
            format!("{id} is not shown"),
            !shown.contains(id.as_str()),
            || "it is in the report".to_string(),
        ));
    }
    if let Some(want) = &c.ain {
        let present = r.also_in_the_news.is_some();
        out.push(check(
            format!("Also-in-the-news line is {want}"),
            present == (want == "present"),
            || format!("line {}", if present { "present" } else { "absent" }),
        ));
    }
    if let Some(id) = &c.ain_item {
        let got = r.also_in_the_news.as_ref().map(|a| a.item_id.as_str());
        out.push(check(
            format!("Also-in-the-news item is {id}"),
            got == Some(id),
            || format!("it was {got:?}"),
        ));
    }
    if let Some(max) = c.also_noted_max {
        out.push(check(
            format!("at most {max} Also noted"),
            r.also_noted.len() <= max,
            || format!("{} lines", r.also_noted.len()),
        ));
    }
    if let Some(id) = &c.follow_up_of {
        let ok = r.picks.iter().any(|k| {
            k.follow_up_of.as_deref() == Some(id)
                && k.whats_new.as_deref().is_some_and(|w| !w.trim().is_empty())
        });
        out.push(check(
            format!("a pick follows up {id} and says what is new"),
            ok,
            || "no such pick".to_string(),
        ));
    }
    if let Some(max) = c.word_total_max {
        out.push(check(
            format!("whole report at most {max} words"),
            counts.total <= max,
            || format!("{} words", counts.total),
        ));
    }
    if let Some(max) = c.word_body_max {
        out.push(check(
            format!("body (footer excluded) at most {max} words"),
            counts.body <= max,
            || format!("{} words", counts.body),
        ));
    }
    let footer = render::footer_text(&r.footer).to_lowercase();
    for s in &c.footer_contains {
        out.push(check(
            format!("footer says {s:?}"),
            footer.contains(&s.to_lowercase()),
            || "not in the footer".to_string(),
        ));
    }
    for s in &c.markdown_contains {
        out.push(check(
            format!("report says {s:?}"),
            md.contains(&s.to_lowercase()),
            || "not in the report".to_string(),
        ));
    }
    for s in &c.markdown_excludes {
        out.push(check(
            format!("report never says {s:?}"),
            !md.contains(&s.to_lowercase()),
            || "it is in the report".to_string(),
        ));
    }
    for s in &c.digest_excludes {
        out.push(check(
            format!("digest never says {s:?}"),
            !digest.contains(&s.to_lowercase()),
            || "it is in the digest".to_string(),
        ));
    }
    out
}

// ── main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&args.scenarios)
        .with_context(|| format!("reading {}", args.scenarios.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.join("expect.toml").is_file())
        .collect();
    dirs.sort();
    if let Some(only) = &args.only {
        dirs.retain(|d| d.file_name().is_some_and(|n| n == only.as_str()));
        if dirs.is_empty() {
            bail!(
                "no scenario named {only} under {}",
                args.scenarios.display()
            );
        }
    }

    let (mut passed, mut failed) = (0usize, 0usize);
    for dir in &dirs {
        let expect = load_expect(dir)?;
        let date: NaiveDate = expect.date.parse().context("scenario date")?;
        println!(
            "== {} {}",
            dir.file_name().unwrap().to_string_lossy(),
            expect.description
        );
        for planned in plan(dir, &expect) {
            let work = PathBuf::from(format!("/tmp/nhe-{}-{}", std::process::id(), date));
            let _ = std::fs::remove_dir_all(&work);
            let result = run_once(dir, &planned.context, date, args.model.as_deref(), &work).await;
            let _ = std::fs::remove_dir_all(&work);
            match result {
                Err(e) => {
                    failed += 1;
                    println!("FAIL {}: the run did not finish: {e:#}", planned.label);
                }
                Ok(produced) => {
                    println!(
                        "   {} ran in {} s, mode {}",
                        planned.label,
                        produced.elapsed.as_secs(),
                        produced.mode
                    );
                    for o in evaluate(planned.checks, &produced) {
                        match o.failure {
                            None => {
                                passed += 1;
                                println!("PASS {}: {}", planned.label, o.name);
                            }
                            Some(why) => {
                                failed += 1;
                                println!("FAIL {}: {} ({why})", planned.label, o.name);
                            }
                        }
                    }
                    if std::env::var_os("HUEY_EVAL_SHOW").is_some() {
                        println!("{}", produced.markdown);
                    }
                }
            }
        }
    }
    println!("\n{passed} passed, {failed} failed");
    if failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scenarios() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/huey/eval")
    }

    /// Every scenario parses, and every item id its assertions name is in
    /// its pool (a typo would otherwise make an assertion vacuous).
    #[test]
    fn every_scenario_parses_and_names_real_items() {
        let mut seen = 0;
        for entry in std::fs::read_dir(scenarios()).unwrap() {
            let dir = entry.unwrap().path();
            if !dir.join("expect.toml").is_file() {
                continue;
            }
            seen += 1;
            let expect = load_expect(&dir).unwrap();
            let date: NaiveDate = expect.date.parse().unwrap();
            let now = date.and_hms_opt(3, 0, 0).unwrap().and_utc();
            let pool: Value =
                serde_json::from_slice(&std::fs::read(dir.join("pool.json")).unwrap()).unwrap();
            let expanded = expand_pool(&pool, now).unwrap();
            let ids: BTreeSet<String> = expanded["recent"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| i["id"].as_str().unwrap().to_string())
                .collect();
            for planned in plan(&dir, &expect) {
                assert!(
                    planned.context.is_dir(),
                    "{} lacks its context",
                    planned.label
                );
                let c = planned.checks;
                let named = c
                    .pick_items_include
                    .iter()
                    .chain(&c.pick_items_exclude)
                    .chain(&c.shown_items_include)
                    .chain(&c.shown_items_exclude)
                    .chain(c.ain_item.iter())
                    .chain(c.follow_up_of.iter());
                for id in named {
                    // A follow-up's earlier item lives in the ledger, not the pool.
                    if c.follow_up_of.as_ref() == Some(id) {
                        continue;
                    }
                    assert!(
                        ids.contains(id),
                        "{}: {id} is not in pool.json",
                        planned.label
                    );
                }
            }
        }
        assert!(seen >= 13, "expected the 13 scenarios, found {seen}");
    }
}
