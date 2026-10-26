//! H3: Huey's context (projects in flight, "how it runs", the digest, the
//! probes and the setup scan) against two fixture machines.
//!
//! Fixtures live under `tests/fixtures/huey/context/machine-{a,b}`. Each test
//! copies a machine into its own temp dir and turns the trees into real git
//! repositories (fixed author, fixed dates relative to [`now`]), so nothing
//! here touches the real `$HOME`, `~/.claude`, `~/.nostromo` or the network
//! (PR search goes to a local wiremock server). Fixture directories named
//! `dot-<x>` are copied as `.<x>`.
//!
//! Every fixture file that holds content which must never reach the digest
//! carries a `CANARY-...` token; the privacy tests collect the tokens from the
//! copied tree and assert none of them is shown anywhere.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, Duration, NaiveDate, SecondsFormat, TimeZone, Utc};
use serde_json::json;

use nostromo::huey::checks::{check, CheckRefused, Probe};
use nostromo::huey::context::collectors::{
    self, BoardSummary, PrRecord, PrState, PrsInput, TitleEntry,
};
use nostromo::huey::context::digest::{DigestInputs, ProjectContext, MAX_DIGEST_BYTES};
use nostromo::huey::context::profile;
use nostromo::huey::context::projects::Commit;
use nostromo::huey::context::{
    append_checks, build_digest, gather, ContextEnv, Digest, LiveInputs, SYNCED_NOTE,
};
use nostromo::huey::interests::{self, InterestSection};
use nostromo::huey::paths::HueyPaths;
use nostromo::huey::setup::{self, InterestsStatus};
use nostromo::mother::MotherJob;

// ── Time ─────────────────────────────────────────────────────────────────────

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 25, 12, 0, 0).unwrap()
}

fn days_ago(days: i64) -> DateTime<Utc> {
    now() - Duration::days(days)
}

fn at(y: i32, mo: u32, d: u32, h: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, mo, d, h, 0, 0).unwrap()
}

// ── Git and file helpers ─────────────────────────────────────────────────────

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

/// `git init` + one commit of everything at the first date, then one empty
/// commit per further `(days_ago, subject)` entry. Oldest first.
fn commit_history(dir: &Path, history: &[(i64, &str)]) {
    git(dir, &["-c", "init.defaultBranch=main", "init", "-q"], now());
    for (i, (days, subject)) in history.iter().enumerate() {
        let when = days_ago(*days);
        if i == 0 {
            git(dir, &["add", "-A"], when);
            git(dir, &["commit", "-q", "-m", subject], when);
        } else {
            git(dir, &["commit", "-q", "--allow-empty", "-m", subject], when);
        }
    }
}

fn commit_all(dir: &Path, subject: &str, when: DateTime<Utc>) {
    git(dir, &["add", "-A"], when);
    git(dir, &["commit", "-q", "-m", subject], when);
}

/// A throwaway repository holding `files`, committed 3 days before [`now`].
fn make_repo(dir: &Path, files: &[(&str, &str)]) {
    for (name, body) in files {
        let path = dir.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }
    commit_history(dir, &[(3, "Initial import")]);
}

/// Copy `src` to `dst`; path components named `dot-x` become `.x`.
fn copy_tree(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).unwrap();
    for entry in fs::read_dir(src).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        let name = match name.strip_prefix("dot-") {
            Some(rest) => format!(".{rest}"),
            None => name,
        };
        let target = dst.join(name);
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

fn fixture_dir(machine: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/huey/context")
        .join(machine)
}

/// Every file and directory under `dir` (git internals included) with its
/// bytes, keyed by relative path.
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
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                out.insert(rel, None);
                walk(base, &path, out);
            } else if kind.is_file() {
                out.insert(rel, Some(fs::read(&path).unwrap()));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

fn changes_between(
    before: &BTreeMap<String, Option<Vec<u8>>>,
    after: &BTreeMap<String, Option<Vec<u8>>>,
) -> Vec<String> {
    let mut out = Vec::new();
    for (k, v) in after {
        match before.get(k) {
            None => out.push(format!("added: {k}")),
            Some(old) if old != v => out.push(format!("changed: {k}")),
            _ => {}
        }
    }
    for k in before.keys() {
        if !after.contains_key(k) {
            out.push(format!("removed: {k}"));
        }
    }
    out
}

/// Every `CANARY-...` token in the text files under `dir` (not `.git`).
fn canaries_under(dir: &Path) -> BTreeSet<String> {
    fn walk(dir: &Path, out: &mut BTreeSet<String>) {
        for entry in fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            if entry.file_type().unwrap().is_dir() {
                if entry.file_name() != ".git" {
                    walk(&path, out);
                }
            } else if let Ok(text) = fs::read_to_string(&path) {
                let mut rest = text.as_str();
                while let Some(pos) = rest.find("CANARY-") {
                    let tail = &rest[pos..];
                    let end = tail
                        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
                        .unwrap_or(tail.len());
                    out.insert(tail[..end].to_string());
                    rest = &tail[end..];
                }
            }
        }
    }
    let mut out = BTreeSet::new();
    walk(dir, &mut out);
    out
}

// ── Fixture machines ─────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum Which {
    A,
    B,
}

struct Machine {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    home: PathBuf,
    code_root: PathBuf,
    state_root: PathBuf,
    env: ContextEnv,
    paths: HueyPaths,
    live: LiveInputs,
    baseline_interests: String,
    /// Tokens planted in raw content (and todo bodies) that must stay private.
    canaries: BTreeSet<String>,
}

fn pr(repo: &str, number: u64, title: &str, state: PrState, when: DateTime<Utc>) -> PrRecord {
    PrRecord {
        repo: repo.to_string(),
        number,
        title: title.to_string(),
        state,
        at: when,
    }
}

fn job(
    id: &str,
    state: &str,
    repo: &str,
    title: &str,
    created: DateTime<Utc>,
    finished: Option<DateTime<Utc>>,
) -> MotherJob {
    serde_json::from_value(json!({
        "id": id,
        "state": state,
        "repo": repo,
        "title": title,
        "created_at": created.to_rfc3339_opts(SecondsFormat::Secs, true),
        "finished_at": finished.map(|f| f.to_rfc3339_opts(SecondsFormat::Secs, true)),
    }))
    .unwrap()
}

/// The GitHub account is shared by both machines, so both are handed the
/// same PR search result. Only repositories on a machine may show up there.
fn shared_prs() -> Vec<PrRecord> {
    vec![
        pr(
            "mother",
            12,
            "Add backpressure to the queue",
            PrState::Open,
            at(2026, 10, 24, 10),
        ),
        pr(
            "mother",
            11,
            "Fix retry jitter handling",
            PrState::Merged,
            at(2026, 10, 20, 8),
        ),
        pr(
            "bishop",
            4,
            "Tune pace thresholds",
            PrState::Open,
            at(2026, 10, 23, 15),
        ),
        pr(
            "lodge",
            7,
            "Add invoice export",
            PrState::Open,
            at(2026, 10, 24, 16),
        ),
        pr(
            "elsewhere",
            99,
            "Unrelated work in a repo on no machine",
            PrState::Open,
            at(2026, 10, 24, 9),
        ),
    ]
}

type History = &'static [(&'static str, &'static [(i64, &'static str)])];

const HISTORY_A: History = &[
    (
        "mother",
        &[
            (21, "Initial import of the job queue"),
            (3, "Add queue backpressure"),
            (1, "Fix retry jitter handling"),
        ],
    ),
    (
        "bishop",
        &[
            (30, "Initial import of the advisor"),
            (2, "Tune the pace thresholds"),
        ],
    ),
    (
        "tools/shellbox",
        &[
            (20, "Initial scripts"),
            (5, "Add the nightly backup script"),
        ],
    ),
    (
        "sandpit",
        &[(10, "Scratch experiment"), (2, "Try a second experiment")],
    ),
    (
        "dormant",
        &[(60, "Initial import"), (30, "Last touch before the break")],
    ),
];

const HISTORY_B: History = &[(
    "lodge",
    &[
        (25, "Initial import of the invoicing app"),
        (4, "Add the invoice export"),
    ],
)];

const TODO_DDL: &str = "
CREATE TABLE todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT,
  status TEXT NOT NULL DEFAULT 'open', priority INTEGER NOT NULL DEFAULT 3,
  due_date TEXT, jira_key TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
  snoozed_until TEXT
);";

/// Fixture dir, machine name, git history, boards and todos of one machine.
type MachineSpec = (
    &'static str,
    &'static str,
    History,
    &'static [(&'static str, &'static str, &'static str)],
    &'static [(&'static str, &'static str, &'static str)],
);

impl Machine {
    fn build(which: Which) -> Self {
        let (fixture, name, history, boards, todos): MachineSpec = match which {
            Which::A => (
                "machine-a",
                "Alpha",
                HISTORY_A,
                &[
                    ("mother-roadmap.md", "mother-roadmap", "mother"),
                    ("bishop-tuning.md", "bishop-tuning", "bishop"),
                ],
                &[
                    (
                        "Renew the signing certificate",
                        "CANARY-TODO-BODY-66fa renew before the 30th",
                        "open",
                    ),
                    (
                        "Already finished chore",
                        "CANARY-TODO-BODY-66fa-done body",
                        "done",
                    ),
                ],
            ),
            Which::B => (
                "machine-b",
                "Osaka",
                HISTORY_B,
                &[("lodge-billing.md", "lodge-billing", "lodge")],
                &[(
                    "Send the quarterly VAT summary",
                    "CANARY-TODO-BODY-b-3e19 body",
                    "open",
                )],
            ),
        };
        let fx = fixture_dir(fixture);
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        copy_tree(&fx.join("home"), &root.join("home"));
        copy_tree(&fx.join("code"), &root.join("code"));
        copy_tree(&fx.join("boards"), &root.join("boards"));
        fs::create_dir_all(root.join("state")).unwrap();
        let (home, code_root, state_root) =
            (root.join("home"), root.join("code"), root.join("state"));

        for (repo, commits) in history {
            commit_history(&code_root.join(repo), commits);
        }

        // The tracker's registry, pointing at this machine's board files.
        let mut registry = serde_json::Map::new();
        for (file, topic, repo) in boards {
            registry.insert(
                root.join("boards")
                    .join(file)
                    .to_string_lossy()
                    .into_owned(),
                json!({
                    "topic": topic,
                    "root": code_root.join(repo).to_string_lossy(),
                    "git": true,
                    "log": { "seq": 0, "entries": [] },
                }),
            );
        }
        fs::create_dir_all(state_root.join("trackers")).unwrap();
        fs::write(
            state_root.join("trackers/state.json"),
            serde_json::to_vec_pretty(&json!({ "version": 1, "boards": registry })).unwrap(),
        )
        .unwrap();

        // Teri's todo store.
        fs::create_dir_all(home.join(".teri")).unwrap();
        let conn = rusqlite::Connection::open(home.join(".teri/teri.db")).unwrap();
        conn.execute_batch(TODO_DDL).unwrap();
        for (title, body, status) in todos {
            conn.execute(
                "INSERT INTO todos (title, body, status) VALUES (?1, ?2, ?3)",
                rusqlite::params![title, body, status],
            )
            .unwrap();
        }
        drop(conn);

        let mut canaries = canaries_under(&root);
        canaries.extend(todos.iter().filter_map(|(_, body, _)| {
            body.split_whitespace()
                .find(|w| w.starts_with("CANARY-"))
                .map(str::to_string)
        }));

        let jobs = match which {
            Which::A => vec![
                job(
                    "job-a1",
                    "running",
                    "mother",
                    "Add queue backpressure",
                    at(2026, 10, 24, 9),
                    None,
                ),
                job(
                    "job-a-old",
                    "succeeded",
                    "bishop",
                    "Last month's tuning run",
                    days_ago(31),
                    Some(days_ago(30)),
                ),
            ],
            Which::B => vec![job(
                "job-b1",
                "queued",
                "lodge",
                "Export invoices",
                at(2026, 10, 25, 8),
                None,
            )],
        };

        Machine {
            env: ContextEnv::for_home(
                &home,
                code_root.clone(),
                state_root.clone(),
                name.to_string(),
            ),
            paths: HueyPaths::new(&state_root),
            live: LiveInputs {
                prs: PrsInput::Available(shared_prs()),
                jobs,
            },
            baseline_interests: fs::read_to_string(fx.join("interests.md")).unwrap(),
            canaries,
            _tmp: tmp,
            root,
            home,
            code_root,
            state_root,
        }
    }

    fn repo(&self, rel: &str) -> PathBuf {
        self.code_root.join(rel)
    }
}

fn digest_with(m: &Machine, interests_text: &str) -> Digest {
    let parsed = interests::parse(interests_text);
    build_digest(&gather(&m.env, &parsed, &m.live, None, now()))
}

fn baseline_digest(m: &Machine) -> Digest {
    digest_with(m, &m.baseline_interests)
}

/// `- [id] text` → text, for the digest line with this id.
fn line_for<'a>(text: &'a str, id: &str) -> Option<&'a str> {
    let prefix = format!("- [{id}] ");
    text.lines().find(|l| l.starts_with(&prefix))
}

/// The lines under the `### Name [id]` heading, up to the next heading.
fn project_block<'a>(text: &'a str, id: &str) -> Vec<&'a str> {
    let suffix = format!("[{id}]");
    let mut lines = text.lines();
    let found = lines
        .by_ref()
        .any(|l| l.starts_with("### ") && l.ends_with(&suffix));
    if !found {
        return Vec::new();
    }
    lines.take_while(|l| !l.starts_with('#')).collect()
}

fn project_set(d: &Digest) -> BTreeSet<&str> {
    d.projects.iter().map(String::as_str).collect()
}

fn block_has(block: &[&str], id: &str) -> bool {
    let prefix = format!("- [{id}] ");
    block.iter().any(|l| l.starts_with(&prefix))
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-1: the digest for a fixture machine
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn digest_lists_the_in_flight_projects_and_leaves_out_the_stale_one() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);

    assert_eq!(
        project_set(&d),
        BTreeSet::from(["mother", "bishop", "shellbox", "sandpit"]),
        "projects with a commit in the last 14 days, found one level down too (tools/shellbox)"
    );
    assert!(
        !d.text.contains("dormant"),
        "a repo whose last commit is older than 14 days, with nothing else open, is not in flight"
    );
    assert!(project_block(&d.text, "dormant").is_empty());
}

#[test]
fn every_in_flight_project_has_a_how_it_runs_line() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(!d.projects.is_empty());
    for id in &d.projects {
        let block = project_block(&d.text, id);
        let line = block
            .iter()
            .find(|l| l.starts_with(&format!("- [{id}:how] ")))
            .unwrap_or_else(|| panic!("no how-it-runs line for {id}:\n{}", d.text));
        assert!(line.contains("How it runs:"), "{line}");
        assert!(d.anchors.contains(&format!("{id}:how")));
    }
}

#[test]
fn mother_shows_its_open_pr_board_and_job_and_a_queue_line() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    let block = project_block(&d.text, "mother");

    let pr = line_for(&d.text, "mother:pr#12").expect("open PR line");
    assert!(pr.contains("Add backpressure to the queue"), "{pr}");

    let merged = line_for(&d.text, "mother:merged#11").expect("recently merged PR line");
    assert!(merged.contains("Fix retry jitter handling"), "{merged}");

    let board = line_for(&d.text, "tracker:mother-roadmap").expect("board line");
    assert!(board.contains("Add queue backpressure"), "{board}");
    assert!(board.contains("Write the retry runbook"), "{board}");
    assert!(
        !board.contains("Ship the first queue"),
        "finished items are not open: {board}"
    );

    let job = line_for(&d.text, "job:job-a1").expect("job line");
    assert!(
        job.contains("Add queue backpressure") && job.contains("running"),
        "{job}"
    );

    let queue = line_for(&d.text, "mother:posture").expect("mother posture/queue line");
    assert!(queue.contains("Queue"), "{queue}");

    for id in [
        "mother:pr#12",
        "mother:merged#11",
        "tracker:mother-roadmap",
        "job:job-a1",
        "mother:posture",
    ] {
        assert!(
            block_has(&block, id),
            "{id} belongs under mother:\n{}",
            block.join("\n")
        );
        assert!(
            d.project_anchors["mother"].contains(id),
            "{id} is anchored to mother"
        );
    }
}

#[test]
fn bishop_shows_its_pr_board_and_the_posture_numbers() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    let block = project_block(&d.text, "bishop");

    let posture = line_for(&d.text, "bishop:posture").expect("bishop posture line");
    assert!(posture.contains("Pump the brakes"), "{posture}");
    assert!(posture.contains("72%"), "7-day used percentage: {posture}");
    assert!(posture.contains("pace 1.9"), "7-day pace: {posture}");

    assert!(line_for(&d.text, "bishop:pr#4").is_some_and(|l| l.contains("Tune pace thresholds")));
    assert!(line_for(&d.text, "tracker:bishop-tuning")
        .is_some_and(|l| l.contains("Calibrate the pace curve")));
    for id in ["bishop:posture", "bishop:pr#4", "tracker:bishop-tuning"] {
        assert!(block_has(&block, id), "{id} belongs under bishop");
    }
}

#[test]
fn a_finished_job_from_last_month_is_not_shown() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(line_for(&d.text, "job:job-a-old").is_none(), "{}", d.text);
    assert!(!d.text.contains("Last month's tuning run"));
}

#[test]
fn only_mother_and_bishop_get_posture_lines() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    for id in ["shellbox", "sandpit"] {
        assert!(
            !block_has(&project_block(&d.text, id), &format!("{id}:posture")),
            "{id} has no posture line"
        );
    }
}

#[test]
fn recent_commit_subjects_appear_under_their_project_and_old_ones_do_not() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    let block = project_block(&d.text, "mother").join("\n");
    assert!(block.contains("Add queue backpressure"), "{block}");
    assert!(block.contains("Fix retry jitter handling"), "{block}");
    assert!(
        !d.text.contains("Initial import of the job queue"),
        "a commit from three weeks ago is outside the 7-day window"
    );
}

#[test]
fn recent_commit_with_nothing_else_puts_a_project_in_flight() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    // Sandpit has no PR, board or job: its commit alone does it.
    let sandpit = project_block(&d.text, "sandpit").join("\n");
    assert!(sandpit.contains("Try a second experiment"), "{sandpit}");
}

#[test]
fn an_open_pr_puts_a_project_in_flight_even_without_recent_commits() {
    let mut m = Machine::build(Which::A);
    let PrsInput::Available(prs) = &mut m.live.prs else {
        unreachable!()
    };
    prs.push(pr(
        "dormant",
        3,
        "Revive the dormant project",
        PrState::Open,
        at(2026, 10, 24, 12),
    ));
    let d = baseline_digest(&m);
    assert!(project_set(&d).contains("dormant"), "{}", d.text);
    assert!(line_for(&d.text, "dormant:pr#3").is_some());
}

#[test]
fn a_finished_job_from_last_month_does_not_put_a_stale_project_in_flight() {
    let mut m = Machine::build(Which::A);
    m.live.jobs.push(job(
        "job-dormant-old",
        "succeeded",
        "dormant",
        "Old run",
        days_ago(31),
        Some(days_ago(30)),
    ));
    let d = baseline_digest(&m);
    assert!(!project_set(&d).contains("dormant"), "{}", d.text);
}

#[test]
fn prs_for_repositories_that_are_not_on_the_machine_are_left_out() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(!d.text.contains("Unrelated work in a repo on no machine"));
    assert!(!d.text.contains("elsewhere"));
}

#[test]
fn interests_bullets_are_in_the_digest_under_their_ids() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    let interests = interests::parse(&m.baseline_interests);
    assert_eq!(interests.bullets.len(), 5);
    for bullet in &interests.bullets {
        let line = line_for(&d.text, &bullet.id)
            .unwrap_or_else(|| panic!("no line for {}:\n{}", bullet.id, d.text));
        assert!(line.contains(bullet.section.label()), "{line}");
        assert!(d.anchors.contains(&bullet.id));
    }
    assert!(line_for(&d.text, "i1").unwrap().contains("Agent harnesses"));
}

#[test]
fn ideas_todos_and_notes_appear_as_titles_with_ids() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(line_for(&d.text, "idea:agent-swarm-sketch")
        .is_some_and(|l| l.contains("Sketch an agent swarm for nightly triage")));
    assert!(line_for(&d.text, "idea:rate-limit-dashboard")
        .is_some_and(|l| l.contains("A dashboard for rate limit pace")));
    assert!(
        line_for(&d.text, "idea:untitled-scribble").is_some(),
        "an idea without a heading falls back to its file name"
    );
    assert!(line_for(&d.text, "note:queue-retry-decision")
        .is_some_and(|l| l.contains("Decision: retry with jitter")));
    assert!(d.text.contains("Renew the signing certificate"));
    assert!(
        !d.text.contains("Already finished chore"),
        "only open todos"
    );
}

#[test]
fn notes_older_than_two_weeks_are_not_listed() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(!d.text.contains("Superseded rollout plan"), "{}", d.text);
}

#[test]
fn a_digest_with_the_pr_search_unavailable_says_so_and_still_lists_projects() {
    let mut m = Machine::build(Which::A);
    m.live.prs = PrsInput::Unavailable;
    let d = baseline_digest(&m);
    assert!(d.text.contains("PRs unavailable"), "{}", d.text);
    assert!(project_set(&d).contains("mother"));
    assert!(
        !d.text.contains(":pr#"),
        "no PR lines when the search is unavailable"
    );

    m.live.prs = PrsInput::Available(Vec::new());
    let d = baseline_digest(&m);
    assert!(
        !d.text.contains("PRs unavailable"),
        "an empty result is not an outage"
    );
}

#[test]
fn a_machine_with_no_bishop_or_mother_project_still_shows_posture_and_queue() {
    let m = Machine::build(Which::B);
    let d = baseline_digest(&m);
    assert!(!project_set(&d).contains("bishop"));
    assert!(
        d.text.contains("On pace"),
        "posture is shown on the machine: {}",
        d.text
    );
    assert!(
        d.text.contains("Queue"),
        "Mother's queue is shown on the machine: {}",
        d.text
    );
}

#[test]
fn the_header_names_the_machine() {
    let a = baseline_digest(&Machine::build(Which::A));
    let b = baseline_digest(&Machine::build(Which::B));
    assert!(
        a.text.starts_with("# Context for Huey: Alpha"),
        "{}",
        a.text
    );
    assert!(
        b.text.starts_with("# Context for Huey: Osaka"),
        "{}",
        b.text
    );
}

#[test]
fn append_checks_adds_one_heading_and_makes_each_check_citable() {
    let m = Machine::build(Which::A);
    let mut d = baseline_digest(&m);
    let c1 = check(
        "c1",
        "bishop",
        &m.repo("bishop"),
        &Probe::Dependency {
            name: "anthropic".into(),
        },
    )
    .unwrap();
    let c2 = check(
        "c2",
        "mother",
        &m.repo("mother"),
        &Probe::Dependency {
            name: "anthropic".into(),
        },
    )
    .unwrap();

    append_checks(&mut d, std::slice::from_ref(&c1));
    append_checks(&mut d, std::slice::from_ref(&c2));

    assert_eq!(d.text.matches("## Checks Huey ran").count(), 1);
    assert!(d.text.contains(&c1.line()) && d.text.contains(&c2.line()));
    assert!(d.anchors.contains("c1") && d.anchors.contains("c2"));
    let before = d.text.clone();
    append_checks(&mut d, &[]);
    assert_eq!(d.text, before, "no checks, no change");
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-2: nothing but titles, states, ids, counts and numbers
// ═════════════════════════════════════════════════════════════════════════════

fn assert_no_canaries(what: &str, text: &str, canaries: &BTreeSet<String>) {
    for canary in canaries {
        assert!(
            !text.contains(canary.as_str()),
            "{canary} leaked into {what}:\n{text}"
        );
    }
}

#[test]
fn machine_a_fixture_plants_a_canary_in_every_kind_of_raw_content() {
    // Guards the privacy test below against a fixture that quietly lost its canaries.
    let m = Machine::build(Which::A);
    for kind in [
        "CANARY-RAW-TRACKER",
        "CANARY-BOARD-PROSE",
        "CANARY-NOTE-BODY",
        "CANARY-IDEA-BODY",
        "CANARY-IDEA-FRONT",
        "CANARY-SOURCE-FILE",
        "CANARY-MANIFEST",
        "CANARY-README",
        "CANARY-SHELL-SCRIPT",
        "CANARY-POSTURE-FREETEXT",
        "CANARY-TODO-BODY",
    ] {
        assert!(
            m.canaries.iter().any(|c| c.starts_with(kind)),
            "no {kind} canary planted"
        );
    }
}

#[test]
fn no_raw_tracker_note_body_source_manifest_or_readme_text_reaches_the_digest() {
    for which in [Which::A, Which::B] {
        let m = Machine::build(which);
        let cache = m.state_root.join("huey/state/profiles");
        let parsed = interests::parse(&m.baseline_interests);
        let d = build_digest(&gather(&m.env, &parsed, &m.live, Some(&cache), now()));

        assert_no_canaries("the digest", &d.text, &m.canaries);

        // The allowed things are really there, so the assertion above is not vacuous.
        assert!(!d.projects.is_empty(), "{}", d.text);
        assert!(
            d.anchors.iter().any(|a| a.starts_with("tracker:")),
            "{}",
            d.text
        );
        assert!(
            d.anchors.iter().any(|a| a.starts_with("idea:")),
            "{}",
            d.text
        );
        assert!(
            d.anchors.iter().any(|a| a.starts_with("note:")),
            "{}",
            d.text
        );
    }
}

#[test]
fn the_profile_cache_holds_no_file_contents_either() {
    let m = Machine::build(Which::A);
    let cache = m.state_root.join("huey/state/profiles");
    let parsed = interests::parse(&m.baseline_interests);
    let _ = gather(&m.env, &parsed, &m.live, Some(&cache), now());
    let cached = snapshot(&cache);
    assert!(
        !cached.is_empty(),
        "gather with a cache dir caches profiles"
    );
    for (name, body) in cached {
        if let Some(body) = body {
            assert_no_canaries(&name, &String::from_utf8_lossy(&body), &m.canaries);
        }
    }
}

#[test]
fn the_digest_never_shows_a_filesystem_path_of_the_machine() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(!d.text.contains(m.root.to_str().unwrap()), "{}", d.text);
    assert!(
        !d.text.contains("/home/") && !d.text.contains("state.json"),
        "{}",
        d.text
    );
}

#[test]
fn collectors_keep_titles_and_states_and_drop_bodies() {
    let m = Machine::build(Which::A);
    let boards = collectors::tracker_boards(&m.state_root);
    let ideas = collectors::ideas(&m.home.join(".claude/ideas"));
    let notes = collectors::notes(
        &m.home.join(".claude/notes"),
        NaiveDate::from_ymd_opt(2026, 10, 25).unwrap(),
    );
    let todos = collectors::todos(&m.home.join(".teri/teri.db"));
    let posture = collectors::posture(&m.home.join(".claude/budget-posture.json"));
    assert!(!boards.is_empty() && !ideas.is_empty() && !notes.is_empty() && !todos.is_empty());
    let dump = format!("{boards:?}\n{ideas:?}\n{notes:?}\n{todos:?}\n{posture:?}");
    assert_no_canaries("what the collectors keep", &dump, &m.canaries);
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-3: the user's own "how it runs" line wins
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_how_it_runs_correction_replaces_huey_s_line_and_says_so() {
    let m = Machine::build(Which::A);
    let before = baseline_digest(&m);
    let huey_line = line_for(&before.text, "mother:how").unwrap();
    assert!(
        huey_line.contains("does not use an Anthropic SDK"),
        "{huey_line}"
    );
    assert!(!huey_line.contains("(your correction)"));

    let corrected = format!(
        "{}\n- **mother**: Runs as a long-lived daemon and starts a headless Claude worker per job.\n",
        m.baseline_interests
    );
    let after = digest_with(&m, &corrected);
    let line = line_for(&after.text, "mother:how").unwrap();
    assert!(
        line.contains("Runs as a long-lived daemon and starts a headless Claude worker per job."),
        "{line}"
    );
    assert!(line.contains("(your correction)"), "{line}");
    assert!(
        !line.contains("Anthropic SDK"),
        "Huey's own line is replaced, not appended to: {line}"
    );

    // Other projects keep Huey's own line.
    let bishop = line_for(&after.text, "bishop:how").unwrap();
    assert!(
        bishop.contains("uses an Anthropic SDK") && !bishop.contains("(your correction)"),
        "{bishop}"
    );
}

#[test]
fn a_how_it_runs_correction_matches_the_project_name_in_any_case() {
    let m = Machine::build(Which::A);
    let text = format!(
        "{}\n- **MOTHER**: Shouted correction.\n",
        m.baseline_interests
    );
    let d = digest_with(&m, &text);
    assert!(line_for(&d.text, "mother:how")
        .unwrap()
        .contains("Shouted correction."));
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-4: Ignore entirely
// ═════════════════════════════════════════════════════════════════════════════

fn with_ignore(m: &Machine, bullet: &str) -> String {
    m.baseline_interests.replace(
        "- Cryptocurrency price chatter.",
        &format!("- Cryptocurrency price chatter.\n{bullet}"),
    )
}

#[test]
fn a_project_named_under_ignore_entirely_is_absent_from_the_in_flight_list() {
    let m = Machine::build(Which::A);
    assert!(project_set(&baseline_digest(&m)).contains("sandpit"));

    for bullet in [
        "- sandpit: scratch work I never want to hear about",
        "- The `sandpit` experiments",
        "- SANDPIT, in any case",
    ] {
        let d = digest_with(&m, &with_ignore(&m, bullet));
        assert!(
            !project_set(&d).contains("sandpit"),
            "{bullet}: {:?}",
            d.projects
        );
        assert!(
            project_block(&d.text, "sandpit").is_empty(),
            "{bullet}\n{}",
            d.text
        );
        assert!(
            !d.anchors.iter().any(|a| a.starts_with("sandpit:")),
            "{bullet}: {:?}",
            d.anchors
        );
        assert!(!d.text.contains("Try a second experiment"), "{bullet}");
        assert_eq!(
            project_set(&d),
            BTreeSet::from(["mother", "bishop", "shellbox"]),
            "{bullet}: everything else stays"
        );
    }
}

#[test]
fn naming_a_project_in_care_does_not_ignore_it() {
    let m = Machine::build(Which::A);
    // The baseline already says "Mother's backlog is my daily driver" under Care.
    assert!(project_set(&baseline_digest(&m)).contains("mother"));
}

#[test]
fn a_context_line_with_a_backticked_hard_term_is_absent_from_the_digest() {
    let m = Machine::build(Which::A);
    let before = baseline_digest(&m);
    assert!(before.text.contains("Fix retry jitter handling"));
    assert!(before.text.contains("Decision: retry with jitter"));

    // Capitalised on purpose: the match ignores case.
    let d = digest_with(&m, &with_ignore(&m, "- Anything about `Jitter`"));

    let context_lines: Vec<&str> = d
        .text
        .lines()
        .filter(|l| l.contains("jitter") && !l.contains("(ignore)"))
        .collect();
    assert!(
        context_lines.is_empty(),
        "lines with the hard term survived: {context_lines:?}"
    );
    assert!(line_for(&d.text, "mother:merged#11").is_none());
    assert!(line_for(&d.text, "note:queue-retry-decision").is_none());
    assert!(!d
        .anchors
        .iter()
        .any(|a| a == "mother:merged#11" || a == "note:queue-retry-decision"));

    // Unrelated lines are untouched.
    assert!(line_for(&d.text, "mother:pr#12").is_some());
    assert!(line_for(&d.text, "mother:how").is_some());
    assert!(d.text.contains("Add queue backpressure"));
    assert!(project_set(&d).contains("mother"));
}

#[test]
fn a_hard_term_is_a_whole_word_match() {
    let m = Machine::build(Which::A);
    // "back" is inside "backpressure" but not a word of it.
    let d = digest_with(&m, &with_ignore(&m, "- Noise about `back`"));
    assert!(
        d.text.contains("Add backpressure to the queue"),
        "{}",
        d.text
    );
}

#[test]
fn backticks_outside_ignore_entirely_are_not_filters() {
    let m = Machine::build(Which::A);
    let text = m.baseline_interests.replace(
        "- Practical write-ups with real benchmarks.",
        "- Write-ups about `jitter` and retries.",
    );
    let d = digest_with(&m, &text);
    assert!(d.text.contains("Fix retry jitter handling"), "{}", d.text);
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-5: two machines, no overlap
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn two_machines_produce_digests_with_nothing_from_each_other() {
    let a = Machine::build(Which::A);
    let b = Machine::build(Which::B);
    let da = baseline_digest(&a);
    let db = baseline_digest(&b);

    assert_eq!(
        project_set(&da),
        BTreeSet::from(["mother", "bishop", "shellbox", "sandpit"])
    );
    assert_eq!(project_set(&db), BTreeSet::from(["lodge"]));

    // Projects, repos, PRs, boards, ideas, notes, todos and posture of B are not in A...
    for token in [
        "lodge",
        "Lodge",
        "Add invoice export",
        "Add the invoice export",
        "lodge-billing",
        "Reconcile invoice export",
        "Tenant data export for auditors",
        "Decision: round VAT per line",
        "Send the quarterly VAT summary",
        "On pace",
        "job-b1",
        "Export invoices",
        "Laravel",
        "PHP",
        "Osaka",
    ] {
        assert!(
            !da.text.contains(token),
            "machine-b's {token:?} showed up on machine-a:\n{}",
            da.text
        );
    }
    // ...and the other way round.
    for token in [
        "[mother:",
        "[bishop:",
        "[shellbox:",
        "[sandpit:",
        "Add backpressure to the queue",
        "Tune pace thresholds",
        "mother-roadmap",
        "bishop-tuning",
        "Calibrate the pace curve",
        "Sketch an agent swarm",
        "A dashboard for rate limit pace",
        "Decision: retry with jitter",
        "Renew the signing certificate",
        "Pump the brakes",
        "72%",
        "job-a1",
        "Alpha",
        "Unrelated work in a repo on no machine",
    ] {
        assert!(
            !db.text.contains(token),
            "machine-a's {token:?} showed up on machine-b:\n{}",
            db.text
        );
    }

    // Each does have its own (so the checks above are not vacuous).
    assert!(da.text.contains("mother-roadmap") && da.text.contains("Pump the brakes"));
    assert!(db.text.contains("lodge-billing") && db.text.contains("Reconcile invoice export"));
    assert!(
        db.text.contains("Add invoice export")
            && db.text.contains("Tenant data export for auditors")
    );
}

#[test]
fn the_php_repo_on_machine_b_profiles_as_php_and_machine_a_has_no_php_project() {
    let b = Machine::build(Which::B);
    let prof = profile::profile(&b.repo("lodge"));
    assert_eq!(prof.languages, vec!["PHP".to_string()]);
    assert!(line_for(&baseline_digest(&b).text, "lodge:how")
        .unwrap()
        .contains("PHP"));

    let a = Machine::build(Which::A);
    let da = baseline_digest(&a);
    for id in &da.projects {
        let how = line_for(&da.text, &format!("{id}:how")).unwrap();
        assert!(!how.contains("PHP"), "{id}: {how}");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-6: profile and the dependency probe agree
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_repo_without_an_anthropic_sdk_says_it_does_not_use_one() {
    let m = Machine::build(Which::A);
    let prof = profile::profile(&m.repo("mother"));
    assert!(!prof.uses_anthropic_sdk());
    let line = prof.line();
    assert!(line.contains("does not use an Anthropic SDK"), "{line}");
    assert_eq!(prof.languages, vec!["Rust".to_string()]);
}

#[test]
fn a_repo_with_an_anthropic_sdk_dependency_names_it() {
    let m = Machine::build(Which::A);
    let prof = profile::profile(&m.repo("bishop"));
    assert!(prof.uses_anthropic_sdk());
    let line = prof.line();
    assert!(line.contains("uses an Anthropic SDK"), "{line}");
    assert!(line.contains("(anthropic)"), "the package is named: {line}");
    assert!(!line.contains("does not use"), "{line}");
}

#[test]
fn the_dependency_probe_agrees_with_the_profile() {
    let m = Machine::build(Which::A);
    let probe = Probe::Dependency {
        name: "anthropic".into(),
    };

    let yes = check("c1", "bishop", &m.repo("bishop"), &probe).unwrap();
    assert!(yes.found, "{}", yes.line());
    assert!(
        yes.paths.iter().any(|p| p == "Cargo.toml"),
        "{:?}",
        yes.paths
    );

    let no = check("c2", "mother", &m.repo("mother"), &probe).unwrap();
    assert!(
        !no.found,
        "a commented-out dependency and a source comment are not a dependency: {}",
        no.line()
    );
    assert!(no.paths.is_empty());
}

#[test]
fn sdk_packages_are_recognised_in_javascript_and_python_manifests() {
    let cases: [(&str, &str, &str); 3] = [
        (
            "package.json",
            r#"{"name":"x","dependencies":{"@anthropic-ai/sdk":"^0.30.0"}}"#,
            "@anthropic-ai/sdk",
        ),
        (
            "requirements.txt",
            "requests\nanthropic>=0.30\n",
            "anthropic",
        ),
        (
            "pyproject.toml",
            "[project]\nname = \"x\"\ndependencies = [\"anthropic>=0.30\"]\n",
            "anthropic",
        ),
    ];
    for (file, body, name) in cases {
        let dir = tempfile::tempdir().unwrap();
        make_repo(dir.path(), &[(file, body)]);
        let line = profile::profile(dir.path()).line();
        assert!(
            line.contains("uses an Anthropic SDK") && line.contains(name),
            "{file}: {line}"
        );
        let probe = check(
            "c1",
            "x",
            dir.path(),
            &Probe::Dependency { name: name.into() },
        )
        .unwrap();
        assert!(probe.found, "{file}: {}", probe.line());
    }

    let dir = tempfile::tempdir().unwrap();
    make_repo(
        dir.path(),
        &[("package.json", r#"{"dependencies":{"left-pad":"1.0.0"}}"#)],
    );
    assert!(profile::profile(dir.path())
        .line()
        .contains("does not use an Anthropic SDK"));
}

#[test]
fn profile_lines_cover_shell_and_rust_repos() {
    let m = Machine::build(Which::A);
    assert_eq!(
        profile::profile(&m.repo("tools/shellbox")).languages,
        vec!["Shell".to_string()]
    );
    assert!(profile::profile(&m.repo("bishop")).line().chars().count() <= 300);
}

#[test]
fn the_invocation_and_claude_feature_probes_report_what_the_repo_does() {
    let m = Machine::build(Which::A);
    let inv = check("c1", "bishop", &m.repo("bishop"), &Probe::Invocation).unwrap();
    assert!(
        inv.found && inv.detail.contains("claude -p"),
        "{}",
        inv.line()
    );
    let none = check("c2", "mother", &m.repo("mother"), &Probe::Invocation).unwrap();
    assert!(!none.found, "{}", none.line());

    let hooks = Probe::ClaudeFeature {
        feature: "hooks".into(),
    };
    assert!(
        check("c3", "bishop", &m.repo("bishop"), &hooks)
            .unwrap()
            .found
    );
    assert!(
        !check("c4", "mother", &m.repo("mother"), &hooks)
            .unwrap()
            .found
    );
    assert_eq!(
        check(
            "c5",
            "bishop",
            &m.repo("bishop"),
            &Probe::ClaudeFeature {
                feature: "telepathy".into()
            }
        ),
        Err(CheckRefused::UnknownFeature)
    );
}

#[test]
fn the_dependency_probe_refuses_an_empty_name() {
    let m = Machine::build(Which::A);
    assert!(check(
        "c1",
        "bishop",
        &m.repo("bishop"),
        &Probe::Dependency { name: "  ".into() }
    )
    .is_err());
}

#[test]
fn project_descriptions_come_from_the_manifest_then_the_readme() {
    let a = Machine::build(Which::A);
    assert_eq!(
        profile::description(&a.repo("mother")).as_deref(),
        Some("Background work orchestrator that runs queued jobs one at a time")
    );
    assert_eq!(
        profile::description(&a.repo("tools/shellbox")).as_deref(),
        Some("A drawer of small shell scripts for chores.")
    );
    let b = Machine::build(Which::B);
    assert_eq!(
        profile::description(&b.repo("lodge")).as_deref(),
        Some("Invoicing app for small lodges")
    );
}

#[test]
fn a_cached_profile_is_refreshed_when_the_repo_moves_to_a_new_commit() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("proj");
    fs::create_dir_all(&repo).unwrap();
    make_repo(
        &repo,
        &[(
            "Cargo.toml",
            "[package]\nname = \"proj\"\nversion = \"0.1.0\"\n\n[dependencies]\nserde = \"1\"\n",
        )],
    );
    let cache = dir.path().join("profiles");

    let first = profile::profile_cached(&repo, "proj", Some(&cache));
    assert!(!first.uses_anthropic_sdk());
    assert!(!snapshot(&cache).is_empty(), "the profile is cached");
    assert_eq!(profile::profile_cached(&repo, "proj", Some(&cache)), first);

    fs::write(
        repo.join("Cargo.toml"),
        "[package]\nname = \"proj\"\nversion = \"0.1.0\"\n\n[dependencies]\nserde = \"1\"\nanthropic = \"0.1\"\n",
    )
    .unwrap();
    commit_all(&repo, "Adopt the SDK", days_ago(1));
    let second = profile::profile_cached(&repo, "proj", Some(&cache));
    assert!(
        second.uses_anthropic_sdk(),
        "a new HEAD invalidates the cached profile"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-7: the text probe
// ═════════════════════════════════════════════════════════════════════════════

const LINE_SECRET: &str = "SECRET-LINE-CONTENT-8d3f";

/// Eight tracked files containing `pistachio-ripple` on a line that also
/// carries [`LINE_SECRET`], plus one file for fixed-string checks.
fn text_probe_repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let mut files: Vec<(String, String)> = [
        "amber", "birch", "cedar", "dune", "ember", "fjord", "grove", "heath",
    ]
    .iter()
    .map(|n| {
        (
            format!("src/{n}.rs"),
            format!("let flavor = \"pistachio-ripple\"; // {LINE_SECRET}\n"),
        )
    })
    .collect();
    files.push(("notes.txt".into(), "abcdef\n".into()));
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect();
    make_repo(dir.path(), &refs);
    dir
}

fn text(term: &str) -> Probe {
    Probe::Text {
        term: term.to_string(),
    }
}

#[test]
fn text_probe_reports_found_a_count_and_at_most_five_paths() {
    let repo = text_probe_repo();
    let r = check("c1", "proj", repo.path(), &text("pistachio-ripple")).unwrap();
    assert!(r.found);
    assert!(
        r.detail.contains('8'),
        "the number of matching files is in the detail: {}",
        r.detail
    );
    assert!(!r.paths.is_empty() && r.paths.len() <= 5, "{:?}", r.paths);
    for p in &r.paths {
        assert!(
            p.starts_with("src/") && p.ends_with(".rs"),
            "repo-relative matching paths: {p}"
        );
    }
    assert!(r.line().starts_with("[c1]"), "{}", r.line());
}

#[test]
fn text_probe_not_found_has_no_paths() {
    let repo = text_probe_repo();
    let r = check("c1", "proj", repo.path(), &text("walnut-swirl")).unwrap();
    assert!(!r.found);
    assert!(r.paths.is_empty());
}

#[test]
fn text_probe_never_returns_line_contents() {
    let repo = text_probe_repo();
    let r = check("c1", "proj", repo.path(), &text("pistachio-ripple")).unwrap();
    for shown in [
        r.detail.clone(),
        r.line(),
        r.paths.join("\n"),
        serde_json::to_string(&r).unwrap(),
    ] {
        assert!(!shown.contains(LINE_SECRET), "line content leaked: {shown}");
        assert!(
            !shown.contains("let flavor"),
            "line content leaked: {shown}"
        );
    }
}

#[test]
fn text_probe_refuses_terms_that_are_too_short_too_long_or_not_one_printable_line() {
    let repo = text_probe_repo();
    for term in [
        "".to_string(),
        "ab".to_string(),
        "   ".to_string(),
        "line1\nline2".to_string(),
        "tab\there".to_string(),
        "carriage\rreturn".to_string(),
        "esc\u{1b}[31mape".to_string(),
        "x".repeat(81),
    ] {
        assert_eq!(
            check("c1", "proj", repo.path(), &text(&term)),
            Err(CheckRefused::BadTerm),
            "{term:?} should be refused"
        );
    }
}

#[test]
fn text_probe_accepts_terms_at_the_length_limits() {
    let repo = text_probe_repo();
    assert!(
        check("c1", "proj", repo.path(), &text("amb")).is_ok(),
        "3 characters"
    );
    assert!(
        check("c1", "proj", repo.path(), &text(&"x".repeat(80))).is_ok(),
        "80 characters"
    );
}

#[test]
fn text_probe_matches_a_fixed_string_not_a_pattern() {
    let repo = text_probe_repo();
    assert!(
        !check("c1", "proj", repo.path(), &text("a.c"))
            .unwrap()
            .found,
        "'.' is not a wildcard"
    );
    assert!(
        !check("c2", "proj", repo.path(), &text("a*c"))
            .unwrap()
            .found,
        "'*' is not a wildcard"
    );
    let odd = check("c3", "proj", repo.path(), &text("a(b[")).unwrap();
    assert!(
        !odd.found,
        "a term that is not a valid pattern is just text"
    );
    assert!(
        check("c4", "proj", repo.path(), &text("abcdef"))
            .unwrap()
            .found
    );
}

#[test]
fn text_probe_terms_cannot_run_commands_or_inject_options() {
    let repo = text_probe_repo();
    let marker_dir = tempfile::tempdir().unwrap();
    let marker = marker_dir.path().join("pwned");
    let marker = marker.to_str().unwrap();
    for term in [
        format!("$(touch {marker})"),
        format!("`touch {marker}`"),
        format!("; touch {marker}"),
        format!("&& touch {marker}"),
        format!("| touch {marker}"),
        format!("--open-files-in-pager=touch {marker}"),
        format!("-O touch {marker}"),
    ] {
        let r = check("c1", "proj", repo.path(), &text(&term));
        assert!(matches!(r, Ok(ref r) if !r.found), "{term}: {r:?}");
        assert!(!Path::new(marker).exists(), "{term} ran a command");
    }
    // A term that looks like an option is still just a term.
    assert!(check("c2", "proj", repo.path(), &text("--version")).is_ok_and(|r| !r.found));
}

#[test]
fn text_probe_without_a_git_repository_is_refused_as_unreadable() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), "pistachio-ripple\n").unwrap();
    assert_eq!(
        check("c1", "proj", dir.path(), &text("pistachio-ripple")),
        Err(CheckRefused::Unreadable)
    );
}

#[test]
fn probes_and_profiles_run_git_with_a_fixed_argv_never_a_shell() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let forbidden = [
        "Command::new(\"sh\")",
        "Command::new(\"bash\")",
        "Command::new(\"zsh\")",
        "Command::new(\"/bin/sh\")",
        "Command::new(\"/bin/bash\")",
        "Command::new(\"cmd\")",
        "\"sh\", \"-c\"",
        "\"bash\", \"-c\"",
        "\"/bin/sh\"",
        "\"/bin/bash\"",
        "sh -c",
        "bash -c",
        "var(\"SHELL\")",
    ];
    for file in [
        "src/huey/checks.rs",
        "src/huey/context/projects.rs",
        "src/huey/context/profile.rs",
    ] {
        let source = fs::read_to_string(root.join(file)).unwrap();
        assert!(source.len() > 500, "{file} was not read");
        // Comments may talk about shells ("never through a shell").
        let code: String = source
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");
        for pattern in forbidden {
            assert!(!code.contains(pattern), "{file} invokes a shell: {pattern}");
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-8: the setup scan and the draft interests file
// ═════════════════════════════════════════════════════════════════════════════

fn scanned_ids(scan: &setup::SetupScan) -> BTreeSet<&str> {
    scan.projects.iter().map(|p| p.id.as_str()).collect()
}

#[test]
fn scan_lists_the_context_sources_with_their_paths() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    let shown: BTreeMap<&str, Option<&str>> = scan
        .context_sources
        .iter()
        .map(|s| (s.path.as_str(), s.note.as_deref()))
        .collect();
    let path = |p: PathBuf| p.to_string_lossy().into_owned();

    for expected in [
        path(m.code_root.clone()),
        path(m.state_root.join("trackers/state.json")),
        path(m.home.join(".claude/ideas")),
        path(m.home.join(".claude/notes")),
        path(m.home.join(".claude/budget-posture.json")),
        path(m.home.join(".teri/teri.db")),
        path(m.paths.interests()),
    ] {
        assert!(
            shown.contains_key(expected.as_str()),
            "{expected} not listed in {shown:#?}"
        );
    }
    assert_eq!(scan.machine, "Alpha");
}

#[test]
fn ideas_todos_and_notes_sources_carry_the_synced_from_other_machines_note() {
    assert_eq!(SYNCED_NOTE, "may be synced from other machines");
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    for p in [
        m.home.join(".claude/ideas"),
        m.home.join(".teri/teri.db"),
        m.home.join(".claude/notes"),
    ] {
        let source = scan
            .context_sources
            .iter()
            .find(|s| s.path == p.to_string_lossy())
            .unwrap_or_else(|| panic!("{p:?} not listed"));
        assert!(
            source
                .note
                .as_deref()
                .is_some_and(|n| n.contains(SYNCED_NOTE)),
            "{p:?}: {:?}",
            source.note
        );
    }
}

#[test]
fn scan_lists_in_flight_projects_with_how_it_runs_lines() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert_eq!(
        scanned_ids(&scan),
        BTreeSet::from(["mother", "bishop", "shellbox", "sandpit"])
    );
    for p in &scan.projects {
        assert!(!p.how_it_runs.is_empty(), "{}", p.id);
    }
    let by_id = |id: &str| scan.projects.iter().find(|p| p.id == id).unwrap();
    assert!(by_id("mother")
        .how_it_runs
        .contains("does not use an Anthropic SDK"));
    assert!(by_id("bishop")
        .how_it_runs
        .contains("uses an Anthropic SDK"));
    assert_eq!(by_id("mother").name, "mother");
    assert!(by_id("mother")
        .description
        .as_deref()
        .is_some_and(|d| d.contains("orchestrator")));
}

#[test]
fn scan_reports_the_interests_status() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert_eq!(scan.interests, InterestsStatus::Missing);

    // An older file at ~/.claude/huey/interests.md can be imported once.
    let legacy = m.home.join(".claude/huey/interests.md");
    fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    fs::write(&legacy, m.baseline_interests.as_bytes()).unwrap();
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert_eq!(
        scan.interests,
        InterestsStatus::ImportableFrom(legacy.clone())
    );
    assert!(!m.paths.interests().exists(), "scanning never imports it");

    // Once Huey has its own, that is the one that counts.
    fs::create_dir_all(m.paths.interests().parent().unwrap()).unwrap();
    fs::write(m.paths.interests(), m.baseline_interests.as_bytes()).unwrap();
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert_eq!(scan.interests, InterestsStatus::Existing);
}

#[test]
fn scan_honours_an_existing_interests_file() {
    let m = Machine::build(Which::A);
    fs::create_dir_all(m.paths.interests().parent().unwrap()).unwrap();
    fs::write(
        m.paths.interests(),
        with_ignore(&m, "- sandpit: scratch work"),
    )
    .unwrap();
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert_eq!(
        scanned_ids(&scan),
        BTreeSet::from(["mother", "bishop", "shellbox"])
    );
}

#[test]
fn scan_writes_nothing_anywhere() {
    let m = Machine::build(Which::A);
    let before = snapshot(&m.root);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert!(!scan.projects.is_empty());
    let changes = changes_between(&before, &snapshot(&m.root));
    assert!(changes.is_empty(), "scan wrote: {changes:?}");
    assert!(
        !m.paths.root().exists(),
        "not even the Huey directory is created"
    );
}

#[test]
fn write_draft_creates_the_four_sections_with_one_bullet_per_in_flight_project() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert!(setup::write_draft(&m.paths, &scan).unwrap());

    let text = fs::read_to_string(m.paths.interests()).unwrap();
    for heading in [
        "## What I care about",
        "## Want more of",
        "## Want less of",
        "## Ignore entirely",
    ] {
        assert!(
            text.lines().any(|l| l.starts_with(heading)),
            "{heading} missing:\n{text}"
        );
    }

    let parsed = interests::parse(&text);
    assert!(
        parsed.warnings.is_empty(),
        "a draft has every section: {:?}",
        parsed.warnings
    );
    let care: Vec<_> = parsed
        .bullets
        .iter()
        .filter(|b| b.section == InterestSection::Care)
        .collect();
    assert_eq!(
        care.len(),
        scan.projects.len(),
        "one bullet per in-flight project:\n{text}"
    );
    let leads: BTreeSet<&str> = care.iter().filter_map(|b| b.lead.as_deref()).collect();
    let names: BTreeSet<&str> = scan.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(leads, names);
    assert!(
        parsed
            .bullets
            .iter()
            .all(|b| b.section == InterestSection::Care),
        "the other sections start empty"
    );
    assert!(
        parsed.hard_terms().is_empty(),
        "a fresh draft filters nothing"
    );
}

#[test]
fn the_draft_carries_no_raw_content_and_no_paths() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    let draft = setup::draft_text(&scan);
    assert_no_canaries("the draft interests file", &draft, &m.canaries);
    assert!(!draft.contains(m.root.to_str().unwrap()), "{draft}");
}

#[test]
fn write_draft_never_overwrites_an_existing_file() {
    let m = Machine::build(Which::A);
    fs::create_dir_all(m.paths.interests().parent().unwrap()).unwrap();
    fs::write(
        m.paths.interests(),
        "# mine\n\n## Ignore entirely\n- my own words\n",
    )
    .unwrap();
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());

    assert!(!setup::write_draft(&m.paths, &scan).unwrap());
    assert_eq!(
        fs::read_to_string(m.paths.interests()).unwrap(),
        "# mine\n\n## Ignore entirely\n- my own words\n"
    );
}

#[test]
fn write_draft_twice_keeps_the_first_draft() {
    let m = Machine::build(Which::A);
    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    assert!(setup::write_draft(&m.paths, &scan).unwrap());
    let first = fs::read(m.paths.interests()).unwrap();
    assert!(!setup::write_draft(&m.paths, &scan).unwrap());
    assert_eq!(fs::read(m.paths.interests()).unwrap(), first);
}

#[test]
fn neither_scan_nor_write_draft_writes_under_the_claude_directory() {
    let m = Machine::build(Which::A);
    let before_home = snapshot(&m.home);
    let before_code = snapshot(&m.code_root);

    let scan = setup::scan(&m.env, &m.paths, &m.live, now());
    setup::write_draft(&m.paths, &scan).unwrap();

    assert!(
        changes_between(&before_home, &snapshot(&m.home)).is_empty(),
        "{:?}",
        changes_between(&before_home, &snapshot(&m.home))
    );
    assert!(changes_between(&before_code, &snapshot(&m.code_root)).is_empty());

    // The one new file is under the Huey root.
    let after = snapshot(&m.root);
    let added: Vec<_> = after
        .iter()
        .filter(|(k, v)| v.is_some() && k.starts_with("state/huey"))
        .map(|(k, _)| k.clone())
        .collect();
    assert_eq!(added, vec!["state/huey/interests.md".to_string()]);
}

// ═════════════════════════════════════════════════════════════════════════════
// H3-9: deterministic, capped
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn identical_inputs_give_a_byte_identical_digest() {
    let m = Machine::build(Which::A);
    let interests = interests::parse(&m.baseline_interests);
    let inputs1 = gather(&m.env, &interests, &m.live, None, now());
    let inputs2 = gather(&m.env, &interests, &m.live, None, now());
    assert_eq!(inputs1, inputs2, "gather is repeatable");

    let d1 = build_digest(&inputs1);
    let d2 = build_digest(&inputs1);
    let d3 = build_digest(&inputs2);
    assert_eq!(d1.text.as_bytes(), d2.text.as_bytes());
    assert_eq!(d1.text.as_bytes(), d3.text.as_bytes());
    assert_eq!(d1, d2);
}

#[test]
fn two_separately_built_copies_of_a_machine_give_the_same_digest() {
    let first = baseline_digest(&Machine::build(Which::A));
    let second = baseline_digest(&Machine::build(Which::A));
    assert_eq!(first.text.as_bytes(), second.text.as_bytes());
    assert_eq!(first.anchors, second.anchors);
}

#[test]
fn the_order_the_daemon_hands_over_prs_and_jobs_does_not_matter() {
    let mut m = Machine::build(Which::A);
    let baseline = baseline_digest(&m).text;
    if let PrsInput::Available(prs) = &mut m.live.prs {
        prs.reverse();
    }
    m.live.jobs.reverse();
    assert_eq!(baseline_digest(&m).text, baseline);
}

#[test]
fn a_fixture_digest_is_well_under_the_cap_and_complete() {
    let m = Machine::build(Which::A);
    let d = baseline_digest(&m);
    assert!(
        d.text.len() < MAX_DIGEST_BYTES / 2,
        "{} bytes",
        d.text.len()
    );
    assert!(
        !d.text
            .lines()
            .any(|l| l.ends_with(" more") && l.starts_with("- +")),
        "{}",
        d.text
    );
}

fn big_inputs() -> (DigestInputs, usize) {
    let projects: Vec<ProjectContext> = (0..30)
        .map(|i| {
            let id = format!("proj{i:02}");
            let prs = vec![
                pr(
                    &id,
                    100 + i as u64,
                    &format!(
                        "Open PR with a deliberately long title number {i} {}",
                        "x".repeat(60)
                    ),
                    PrState::Open,
                    at(2026, 10, 24, 10),
                ),
                pr(
                    &id,
                    200 + i as u64,
                    &format!(
                        "Second open PR with a deliberately long title number {i} {}",
                        "y".repeat(60)
                    ),
                    PrState::Open,
                    at(2026, 10, 24, 9),
                ),
                pr(
                    &id,
                    300 + i as u64,
                    &format!(
                        "Merged PR with a deliberately long title number {i} {}",
                        "z".repeat(60)
                    ),
                    PrState::Merged,
                    at(2026, 10, 22, 9),
                ),
            ];
            let commits = (0..3)
                .map(|k| Commit {
                    sha: format!("{i:02}{k}abcd")[..7].to_string(),
                    at: at(2026, 10, 24, 8 - k),
                    subject: format!("Commit subject {k} of project {i} {}", "w".repeat(70)),
                })
                .collect();
            ProjectContext {
                id: id.clone(),
                name: id.clone(),
                root: PathBuf::from("/nowhere"),
                how_it_runs: "Rust; no claude invocation found; does not use an Anthropic SDK"
                    .into(),
                prs,
                boards: vec![BoardSummary {
                    topic: format!("board-{i}"),
                    root: None,
                    path: PathBuf::from(format!("/boards/{i}.md")),
                    open: 2,
                    open_titles: vec!["First item".into(), "Second item".into()],
                    updated_at: None,
                }],
                jobs: vec![job(
                    &format!("job-{i}"),
                    "running",
                    &id,
                    &format!("Job title {i}"),
                    at(2026, 10, 24, 7),
                    None,
                )],
                commits,
                last_activity: now() - Duration::minutes(i as i64),
            }
        })
        .collect();
    let ideas = (0..3)
        .map(|i| TitleEntry {
            id: format!("idea:idea-{i}"),
            title: format!("Idea number {i}"),
            date: None,
            state: None,
        })
        .collect();
    let interests = interests::parse("## What I care about\n- one thing\n- another thing\n");
    // Lines the digest can show: 2 interests, 9 per project, 3 ideas.
    let total_lines = 2 + 30 * 9 + 3;
    (
        DigestInputs {
            machine: "Test".into(),
            date: NaiveDate::from_ymd_opt(2026, 10, 25).unwrap(),
            version: 1,
            mode: None,
            interests,
            projects,
            prs_available: true,
            posture: None,
            mother_queue: None,
            ideas,
            todos: Vec::new(),
            notes: Vec::new(),
        },
        total_lines,
    )
}

#[test]
fn a_digest_over_the_cap_is_cut_to_a_clean_prefix_with_a_plus_n_more_line() {
    let (inputs, total_lines) = big_inputs();
    let d = build_digest(&inputs);

    assert!(d.text.len() <= MAX_DIGEST_BYTES, "{} bytes", d.text.len());
    assert!(
        d.text.len() > MAX_DIGEST_BYTES / 2,
        "the digest should use most of its room, not stop early"
    );
    assert!(d.text.starts_with("# Context for Huey: Test"));

    let last = d.text.lines().last().unwrap();
    let n: usize = last
        .strip_prefix("- +")
        .and_then(|rest| rest.strip_suffix(" more"))
        .unwrap_or_else(|| panic!("the last line is `- +N more`, got {last:?}"))
        .parse()
        .unwrap();
    assert!(n > 0);

    let shown = d
        .text
        .lines()
        .filter(|l| l.starts_with("- ") && *l != last)
        .count();
    assert_eq!(
        shown + n,
        total_lines,
        "+N counts every line that did not fit"
    );
    assert_eq!(
        d.anchors.len(),
        shown,
        "only lines that are shown can be cited"
    );
    assert!(!d.projects.is_empty() && d.projects.len() < 30);
    // The projects that are shown are the most recently active ones.
    assert_eq!(d.projects[0], "proj00");
}

#[test]
fn the_cap_is_deterministic() {
    let (inputs, _) = big_inputs();
    assert_eq!(build_digest(&inputs).text, build_digest(&inputs).text);
}

// ═════════════════════════════════════════════════════════════════════════════
// Interests parser
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn interest_bullets_get_ids_in_file_order_across_sections() {
    let text = "\
## Want more of
- m1
## What I care about, and why
- c1
- c2
## How it runs
- **mother**: x
## Ignore entirely
- ig1
## Want less of
- l1
";
    let parsed = interests::parse(text);
    let got: Vec<(&str, InterestSection, &str)> = parsed
        .bullets
        .iter()
        .map(|b| (b.id.as_str(), b.section, b.text.as_str()))
        .collect();
    assert_eq!(
        got,
        vec![
            ("i1", InterestSection::WantMore, "m1"),
            ("i2", InterestSection::Care, "c1"),
            ("i3", InterestSection::Care, "c2"),
            ("i4", InterestSection::Ignore, "ig1"),
            ("i5", InterestSection::WantLess, "l1"),
        ],
        "how-it-runs bullets are not interests and take no id"
    );
}

#[test]
fn interest_headings_match_by_prefix_and_ignore_case() {
    let text = "\
## WHAT I CARE ABOUT
- a
## want more of (news)
- b
## Want Less Of
- c
## IGNORE ENTIRELY, really
- d
## HOW IT RUNS on this machine
- **mother**: e
";
    let parsed = interests::parse(text);
    let sections: Vec<InterestSection> = parsed.bullets.iter().map(|b| b.section).collect();
    assert_eq!(
        sections,
        vec![
            InterestSection::Care,
            InterestSection::WantMore,
            InterestSection::WantLess,
            InterestSection::Ignore
        ]
    );
    assert_eq!(parsed.how_it_runs_for("mother"), Some("e"));
    assert!(parsed.warnings.is_empty(), "{:?}", parsed.warnings);
}

#[test]
fn a_missing_section_is_a_warning_not_an_error() {
    let full = "## What I care about\n- a\n## Want more of\n- b\n## Want less of\n- c\n## Ignore entirely\n- d\n";
    assert!(interests::parse(full).warnings.is_empty());

    let without_ignore =
        "## What I care about\n- secret bullet text\n## Want more of\n- b\n## Want less of\n- c\n";
    let parsed = interests::parse(without_ignore);
    assert_eq!(parsed.bullets.len(), 3, "the rest is still read");
    assert!(
        parsed
            .warnings
            .iter()
            .any(|w| w.to_lowercase().contains("ignore")),
        "{:?}",
        parsed.warnings
    );
    assert!(
        parsed
            .warnings
            .iter()
            .all(|w| !w.contains("secret bullet text")),
        "warnings never quote bullet text"
    );

    let empty = interests::parse("");
    assert!(empty.bullets.is_empty());
    assert!(!empty.warnings.is_empty());
    assert!(interests::parse("just some prose, no headings\n")
        .bullets
        .is_empty());
}

#[test]
fn a_digest_can_be_built_from_a_file_missing_sections() {
    let m = Machine::build(Which::A);
    let d = digest_with(&m, "## What I care about\n- only this\n");
    assert!(line_for(&d.text, "i1").is_some());
    assert!(project_set(&d).contains("mother"));
}

#[test]
fn hard_terms_come_only_from_backticks_in_ignore_entirely() {
    let text = "\
## What I care about
- Watch `PHP` news
## Want more of
- More `Rust`
## Want less of
- Less `Go`
## Ignore entirely
- Anything about `Laravel` or `blade templates`
- Also `laravel` again, and a dangling `Lara
";
    let parsed = interests::parse(text);
    assert_eq!(
        parsed.hard_terms(),
        vec!["Laravel", "blade templates"],
        "deduplicated, in file order"
    );
    for b in parsed
        .bullets
        .iter()
        .filter(|b| b.section != InterestSection::Ignore)
    {
        assert!(b.hard_terms.is_empty(), "{b:?}");
    }
    assert_eq!(parsed.hard_term_in("a LARAVEL release"), Some("Laravel"));
    assert_eq!(
        parsed.hard_term_in("new blade templates land"),
        Some("blade templates")
    );
    assert_eq!(
        parsed.hard_term_in("PHP and Rust and Go"),
        None,
        "Care, Want more and Want less are not filters"
    );
    assert_eq!(
        parsed.hard_term_in("Laravelish things"),
        None,
        "whole words only"
    );
    assert_eq!(parsed.hard_term_in("nothing relevant"), None);
}

#[test]
fn ignore_entirely_names_projects_by_whole_word_ignoring_case() {
    let text = "\
## What I care about
- Sandpit experiments are fun
## Ignore entirely
- Stop showing Mother and bishop
";
    let parsed = interests::parse(text);
    assert!(parsed.ignores_project("mother"));
    assert!(parsed.ignores_project("MOTHER"));
    assert!(parsed.ignores_project("bishop"));
    assert!(!parsed.ignores_project("mothership"), "whole word only");
    assert!(
        !parsed.ignores_project("sandpit"),
        "a Care bullet is not an ignore"
    );
}

#[test]
fn how_it_runs_bullets_are_keyed_by_lower_cased_project() {
    let text = "## How it runs\n- **Mother**: runs as a daemon\n- **bishop**: runs on a timer\n";
    let parsed = interests::parse(text);
    assert_eq!(parsed.how_it_runs_for("mother"), Some("runs as a daemon"));
    assert_eq!(parsed.how_it_runs_for("MOTHER"), Some("runs as a daemon"));
    assert_eq!(parsed.how_it_runs_for("bishop"), Some("runs on a timer"));
    assert_eq!(parsed.how_it_runs_for("sandpit"), None);
    assert!(parsed.bullets.is_empty());
}

#[test]
fn a_bullet_continues_on_indented_lines_and_keeps_its_bold_lead() {
    let text =
        "## What I care about\n- **Agent harnesses**: first line\n  and a second line\n- next\n";
    let parsed = interests::parse(text);
    assert_eq!(parsed.bullets.len(), 2);
    assert_eq!(parsed.bullets[0].lead.as_deref(), Some("Agent harnesses"));
    assert!(
        parsed.bullets[0].text.contains("first line")
            && parsed.bullets[0].text.contains("and a second line")
    );
    assert_eq!(parsed.bullets[1].lead, None);
}

// ═════════════════════════════════════════════════════════════════════════════
// Collectors
// ═════════════════════════════════════════════════════════════════════════════

fn search_item(
    number: u64,
    title: &str,
    state: &str,
    repo_url: &str,
    updated: &str,
    merged_at: Option<&str>,
) -> serde_json::Value {
    json!({
        "number": number,
        "title": title,
        "state": state,
        "repository_url": repo_url,
        "updated_at": updated,
        "html_url": format!("https://github.com/someone/x/pull/{number}"),
        "body": "CANARY-PR-BODY-1f2e never kept",
        "pull_request": { "merged_at": merged_at },
    })
}

#[tokio::test]
async fn fetch_prs_returns_open_and_recently_merged_and_drops_the_rest() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search/issues"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "total_count": 4,
            "items": [
                search_item(12, "Add backpressure to the queue", "open",
                    "https://api.github.com/repos/someone/Mother", "2026-10-24T10:00:00Z", None),
                search_item(11, "Fix retry jitter handling", "closed",
                    "https://api.github.com/repos/someone/Mother", "2026-10-20T08:00:00Z", Some("2026-10-20T08:00:00Z")),
                search_item(9, "Merged a month ago", "closed",
                    "https://api.github.com/repos/someone/Mother", "2026-09-30T08:00:00Z", Some("2026-09-30T08:00:00Z")),
                search_item(8, "Closed without merging", "closed",
                    "https://api.github.com/repos/someone/bishop", "2026-10-22T08:00:00Z", None),
            ]
        })))
        .expect(1)
        .mount(&server)
        .await;

    let mut prs = collectors::fetch_prs(&reqwest::Client::new(), &server.uri(), "tok-123", now())
        .await
        .unwrap();
    prs.sort_by_key(|p| p.number);

    assert_eq!(prs.len(), 2, "{prs:?}");
    assert_eq!(
        (prs[0].number, prs[0].state, prs[0].repo.as_str()),
        (11, PrState::Merged, "mother")
    );
    assert_eq!(prs[0].title, "Fix retry jitter handling");
    assert_eq!(
        prs[0].at,
        at(2026, 10, 20, 8),
        "a merged PR is dated by its merge"
    );
    assert_eq!(
        (prs[1].number, prs[1].state, prs[1].repo.as_str()),
        (12, PrState::Open, "mother")
    );
    assert_eq!(prs[1].title, "Add backpressure to the queue");

    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1, "one search, no per-PR follow-ups");
    let req = &requests[0];
    assert_eq!(req.method.to_string(), "GET");
    assert_eq!(
        req.headers.get("authorization").unwrap().to_str().unwrap(),
        "Bearer tok-123"
    );
    let q = req
        .url
        .query_pairs()
        .find(|(k, _)| k == "q")
        .map(|(_, v)| v.into_owned())
        .expect("a search query");
    assert!(
        q.contains("is:pr") && q.contains("author:@me"),
        "only the user's own PRs: {q}"
    );
}

#[tokio::test]
async fn fetch_prs_fails_on_a_non_success_status_without_echoing_the_token() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    for status in [401u16, 403, 429, 500] {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/search/issues"))
            .respond_with(ResponseTemplate::new(status).set_body_string("nope"))
            .mount(&server)
            .await;
        let err = collectors::fetch_prs(
            &reqwest::Client::new(),
            &server.uri(),
            "tok-secret-456",
            now(),
        )
        .await
        .expect_err(&format!("HTTP {status} is an error"));
        assert!(!format!("{err:#}").contains("tok-secret-456"), "{err:#}");
    }
}

#[tokio::test]
async fn fetched_prs_flow_into_the_digest_by_repository() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search/issues"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "items": [search_item(12, "Add backpressure to the queue", "open",
                "https://api.github.com/repos/someone/mother", "2026-10-24T10:00:00Z", None)]
        })))
        .mount(&server)
        .await;
    let prs = collectors::fetch_prs(&reqwest::Client::new(), &server.uri(), "t", now())
        .await
        .unwrap();

    let mut m = Machine::build(Which::A);
    m.live.prs = PrsInput::Available(prs);
    let d = baseline_digest(&m);
    assert!(line_for(&d.text, "mother:pr#12")
        .is_some_and(|l| l.contains("Add backpressure to the queue")));
    assert_no_canaries(
        "the digest",
        &d.text,
        &BTreeSet::from(["CANARY-PR-BODY-1f2e".to_string()]),
    );
}

#[test]
fn tracker_boards_keep_topics_titles_and_counts_only() {
    let m = Machine::build(Which::A);
    let boards = collectors::tracker_boards(&m.state_root);
    assert_eq!(
        boards.iter().map(|b| b.topic.as_str()).collect::<Vec<_>>(),
        vec!["bishop-tuning", "mother-roadmap"],
        "sorted by topic"
    );

    let mother = &boards[1];
    assert_eq!(
        mother.open, 4,
        "four open items; the done one is not counted"
    );
    assert_eq!(mother.root.as_deref(), Some(m.repo("mother").as_path()));
    assert_eq!(
        mother.open_titles.first().map(String::as_str),
        Some("Add queue backpressure")
    );
    assert!(
        mother.open_titles.len() <= mother.open,
        "{:?}",
        mother.open_titles
    );
    assert!(!mother
        .open_titles
        .iter()
        .any(|t| t.contains("Ship the first queue")));

    let bishop = &boards[0];
    assert_eq!(bishop.open, 2);
    assert_eq!(
        bishop.open_titles,
        vec!["Calibrate the pace curve", "Add a stale-input warning"]
    );

    assert_no_canaries("a board summary", &format!("{boards:?}"), &m.canaries);
}

#[test]
fn tracker_boards_skips_what_it_cannot_read() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path();
    assert!(collectors::tracker_boards(state).is_empty(), "no registry");

    fs::create_dir_all(state.join("trackers")).unwrap();
    fs::write(state.join("trackers/state.json"), "{ not json").unwrap();
    assert!(
        collectors::tracker_boards(state).is_empty(),
        "garbled registry"
    );

    let good = dir.path().join("good.md");
    fs::write(
        &good,
        "# Good board\n\n## Now\n- [ ] One open item <!-- #one-open 1792832400 -->\n",
    )
    .unwrap();
    let missing = dir.path().join("missing.md");
    let broken = dir.path().join("broken.md");
    fs::write(&broken, "## Now\n- [ ] a\n<!-- #a nope -->\n").unwrap();
    let entry = |topic: &str| json!({ "topic": topic, "root": dir.path().to_string_lossy(), "git": false, "log": { "seq": 0, "entries": [] } });
    fs::write(
        state.join("trackers/state.json"),
        serde_json::to_vec(&json!({
            "version": 1,
            "boards": {
                good.to_string_lossy(): entry("good"),
                missing.to_string_lossy(): entry("missing"),
                broken.to_string_lossy(): entry("broken"),
            }
        }))
        .unwrap(),
    )
    .unwrap();
    let boards = collectors::tracker_boards(state);
    assert_eq!(boards.len(), 1, "{boards:?}");
    assert_eq!(boards[0].topic, "good");
    assert_eq!(boards[0].open_titles, vec!["One open item"]);
}

#[test]
fn ideas_are_titles_newest_first_and_notes_stop_at_two_weeks() {
    let m = Machine::build(Which::A);
    let ideas = collectors::ideas(&m.home.join(".claude/ideas"));
    assert_eq!(
        ideas.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
        vec![
            "Sketch an agent swarm for nightly triage",
            "A dashboard for rate limit pace",
            "untitled scribble"
        ]
    );
    assert_eq!(ideas[0].id, "idea:agent-swarm-sketch");
    assert_eq!(ideas[0].date, NaiveDate::from_ymd_opt(2026, 10, 18));

    let notes = collectors::notes(
        &m.home.join(".claude/notes"),
        NaiveDate::from_ymd_opt(2026, 10, 25).unwrap(),
    );
    assert_eq!(
        notes.iter().map(|n| n.title.as_str()).collect::<Vec<_>>(),
        vec!["Decision: retry with jitter"]
    );
    assert_eq!(notes[0].id, "note:queue-retry-decision");

    let later = collectors::notes(
        &m.home.join(".claude/notes"),
        NaiveDate::from_ymd_opt(2026, 11, 20).unwrap(),
    );
    assert!(later.is_empty(), "a month later nothing is recent");
}

#[test]
fn missing_idea_and_note_directories_are_just_empty() {
    let dir = tempfile::tempdir().unwrap();
    assert!(collectors::ideas(&dir.path().join("nope")).is_empty());
    assert!(collectors::notes(
        &dir.path().join("nope"),
        NaiveDate::from_ymd_opt(2026, 10, 25).unwrap()
    )
    .is_empty());
}

#[test]
fn todos_are_open_titles_and_a_missing_store_is_neither_an_error_nor_created() {
    let m = Machine::build(Which::A);
    let todos = collectors::todos(&m.home.join(".teri/teri.db"));
    assert_eq!(todos.len(), 1, "{todos:?}");
    assert_eq!(todos[0].title, "Renew the signing certificate");
    assert_eq!(todos[0].state.as_deref(), Some("open"));
    assert!(todos[0].id.starts_with("todo:"));

    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join(".teri/teri.db");
    assert!(collectors::todos(&missing).is_empty());
    assert!(
        !dir.path().join(".teri").exists(),
        "reading never creates the store"
    );
}

#[test]
fn posture_reads_the_numbers_and_tolerates_a_missing_or_odd_file() {
    let m = Machine::build(Which::A);
    let facts = collectors::posture(&m.home.join(".claude/budget-posture.json")).expect("posture");
    assert_eq!(facts.posture, "Pump the brakes");
    assert_eq!(facts.seven_day_used_pct, Some(72.4));
    assert_eq!(facts.seven_day_pace, Some(1.9));
    assert_eq!(facts.five_hour_used_pct, Some(41.0));
    assert_eq!(facts.billing_mode.as_deref(), Some("metered"));
    assert!(!facts.stale_input);
    let line = facts.line();
    assert!(
        line.contains("72%") && line.contains("pace 1.9") && line.contains("Pump the brakes"),
        "{line}"
    );
    assert!(!line.contains("CANARY"), "{line}");

    let dir = tempfile::tempdir().unwrap();
    assert!(collectors::posture(&dir.path().join("absent.json")).is_none());
    fs::write(dir.path().join("garbled.json"), "{ nope").unwrap();
    assert!(collectors::posture(&dir.path().join("garbled.json")).is_none());
    fs::write(dir.path().join("empty.json"), "{}").unwrap();
    assert!(collectors::posture(&dir.path().join("empty.json")).is_none());
}

#[test]
fn queue_line_counts_active_jobs_by_state_and_says_idle_when_there_are_none() {
    assert!(collectors::queue_line(&[]).contains("idle"));

    let finished = job(
        "j0",
        "succeeded",
        "mother",
        "done",
        days_ago(2),
        Some(days_ago(1)),
    );
    assert!(
        collectors::queue_line(std::slice::from_ref(&finished)).contains("idle"),
        "finished jobs are not queue"
    );

    let jobs = vec![
        job("j1", "running", "mother", "a", days_ago(1), None),
        job("j2", "queued", "mother", "b", days_ago(1), None),
        job("j3", "queued", "mother", "c", days_ago(1), None),
        finished,
    ];
    let line = collectors::queue_line(&jobs);
    assert!(
        line.contains("1 running") && line.contains("2 queued"),
        "{line}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// H3 review fixes: ids, secrets, SDK names, probe confinement
// ═════════════════════════════════════════════════════════════════════════════

fn bare_inputs(interests_text: &str) -> DigestInputs {
    DigestInputs {
        machine: "Test".into(),
        date: NaiveDate::from_ymd_opt(2026, 10, 25).unwrap(),
        version: 1,
        mode: None,
        interests: interests::parse(interests_text),
        projects: Vec::new(),
        prs_available: true,
        posture: None,
        mother_queue: None,
        ideas: Vec::new(),
        todos: Vec::new(),
        notes: Vec::new(),
    }
}

#[test]
fn a_hard_term_that_appears_only_in_a_file_name_does_not_reach_the_digest() {
    let ideas_dir = tempfile::tempdir().unwrap();
    fs::write(
        ideas_dir.path().join("2026-10-20-laravel-upgrade.md"),
        "# Plan the stack move\n",
    )
    .unwrap();
    fs::write(
        ideas_dir.path().join("2026-10-21-harmless-idea.md"),
        "# A harmless idea\n",
    )
    .unwrap();
    let mut inputs = bare_inputs("## Ignore entirely\n- Anything about `Laravel`\n");
    inputs.ideas = collectors::ideas(ideas_dir.path());
    assert_eq!(inputs.ideas.len(), 2);
    let d = build_digest(&inputs);
    // (The ignore bullet itself is shown under Interests; the ideas are not.)
    let ideas_part = d.text.split("(titles only)").nth(1).unwrap();
    assert!(
        !ideas_part.to_lowercase().contains("laravel"),
        "{ideas_part}"
    );
    assert!(!ideas_part.contains("Plan the stack move"), "{ideas_part}");
    assert!(!d.anchors.iter().any(|a| a.contains("laravel")));
    assert!(d.text.contains("A harmless idea"), "{}", d.text);
}

#[test]
fn a_multi_word_hard_term_in_a_slug_is_filtered_too() {
    let ideas_dir = tempfile::tempdir().unwrap();
    fs::write(
        ideas_dir.path().join("blade-templates-rewrite.md"),
        "# Rewrite the views\n",
    )
    .unwrap();
    let mut inputs = bare_inputs("## Ignore entirely\n- `blade templates`\n");
    inputs.ideas = collectors::ideas(ideas_dir.path());
    let d = build_digest(&inputs);
    assert!(!d.text.contains("Rewrite the views"), "{}", d.text);
}

#[test]
fn digest_ids_use_only_safe_characters() {
    let ideas_dir = tempfile::tempdir().unwrap();
    fs::write(
        ideas_dir.path().join("2026-10-20-x] [Evil:Id #1.md"),
        "# Looks fine\n",
    )
    .unwrap();
    let mut inputs = bare_inputs("## What I care about\n- one thing\n");
    inputs.ideas = collectors::ideas(ideas_dir.path());
    inputs.projects = vec![ProjectContext {
        id: "proj".into(),
        name: "proj".into(),
        root: PathBuf::from("/nowhere"),
        how_it_runs: "Rust".into(),
        prs: Vec::new(),
        boards: vec![BoardSummary {
            topic: "a] [b:c d".into(),
            root: None,
            path: PathBuf::from("/boards/x.md"),
            open: 1,
            open_titles: vec!["Item".into()],
            updated_at: None,
        }],
        jobs: vec![job(
            "j] [1",
            "running",
            "proj",
            "t",
            at(2026, 10, 24, 7),
            None,
        )],
        commits: Vec::new(),
        last_activity: now(),
    }];
    let d = build_digest(&inputs);
    assert!(!d.anchors.is_empty());
    for a in &d.anchors {
        assert!(!a.contains(['[', ']', ' ']), "{a}");
    }
    assert!(d.anchors.contains("tracker:a---b-c-d"), "{:?}", d.anchors);
    assert!(d.anchors.contains("job:j---1"), "{:?}", d.anchors);
    assert!(d.anchors.contains("idea:x---evil-id--1"), "{:?}", d.anchors);
    // Every `- [id] ...` line carries exactly one bracketed id.
    for line in d.text.lines().filter(|l| l.starts_with("- [")) {
        let id = line[3..].split(']').next().unwrap();
        assert!(d.anchors.contains(id), "{line}");
    }
}

#[test]
fn collector_ids_keep_only_safe_characters() {
    assert_eq!(collectors::safe_id("A] [b:C d", 64), "a---b-c-d");
    assert_eq!(collectors::safe_id("ok.name_1-x", 64), "ok.name_1-x");
    assert_eq!(collectors::safe_id("abcdef", 3), "abc");
}
