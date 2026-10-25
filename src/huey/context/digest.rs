//! The context digest (`digest.md`): the privacy boundary of Huey. It may
//! carry only titles, states, ids, counts, profile facts, interests bullets
//! and posture numbers. Every line carries an id the model can cite.
//!
//! Deterministic: identical inputs give byte-identical text (T9). Capped at
//! 16 KiB; whatever does not fit is counted in a final "+N more" line.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, NaiveDate, Utc};

use super::collectors::{BoardSummary, PostureFacts, PrRecord, PrState, TitleEntry};
use super::projects::Commit;
use crate::data::work::untrusted::one_line;
use crate::huey::checks::CheckResult;
use crate::huey::interests::Interests;
use crate::mother::MotherJob;

/// Largest digest, in bytes (before "Checks Huey ran" is appended).
pub const MAX_DIGEST_BYTES: usize = 16 * 1024;
/// Heading of the section [`append_checks`] adds.
pub const CHECKS_HEADING: &str = "## Checks Huey ran";
/// Longest title or subject carried into the digest, in characters.
const TITLE_MAX: usize = 120;
/// Shown after a project's own "how it runs" line is replaced by the user's.
pub const CORRECTION_MARK: &str = "(your correction)";

/// One in-flight project and what the collectors found for it.
#[derive(Debug, Clone, PartialEq)]
pub struct ProjectContext {
    /// Lower-cased id, e.g. `nostromo`.
    pub id: String,
    /// As the directory is named, e.g. `nostromo`.
    pub name: String,
    /// The main worktree (where probes look). Never rendered.
    pub root: std::path::PathBuf,
    /// Huey's own "how it runs" line (the profile's render).
    pub how_it_runs: String,
    pub prs: Vec<PrRecord>,
    pub boards: Vec<BoardSummary>,
    pub jobs: Vec<MotherJob>,
    /// Commit subjects of the last 7 days, newest first, at most 5.
    pub commits: Vec<Commit>,
    /// What ranks it among the in-flight projects.
    pub last_activity: DateTime<Utc>,
}

/// Everything [`build_digest`] renders. Built by [`super::gather`].
#[derive(Debug, Clone, PartialEq)]
pub struct DigestInputs {
    /// The machine's short name, e.g. `Sendai`.
    pub machine: String,
    pub date: NaiveDate,
    /// Report version the digest belongs to (`v1`, `v2` after a regenerate).
    pub version: u32,
    /// The run's mode line (`tight (Bishop: …)`), when the caller has one.
    pub mode: Option<String>,
    pub interests: Interests,
    /// The in-flight projects (already capped).
    pub projects: Vec<ProjectContext>,
    /// `false` when the PR search had no token or failed.
    pub prs_available: bool,
    pub posture: Option<PostureFacts>,
    /// Mother's queue summary (`Queue: idle`), when Mother's jobs are known.
    pub mother_queue: Option<String>,
    pub ideas: Vec<TitleEntry>,
    pub todos: Vec<TitleEntry>,
    pub notes: Vec<TitleEntry>,
}

/// The rendered digest and the ids it issued.
#[derive(Debug, Clone, PartialEq)]
pub struct Digest {
    pub text: String,
    /// Project ids in the digest, in digest order.
    pub projects: Vec<String>,
    /// Every line id in the digest (`nostromo:how`, `job:abc`, `i3`, `c1`, …).
    pub anchors: BTreeSet<String>,
    /// The anchors that belong to each project.
    pub project_anchors: BTreeMap<String, BTreeSet<String>>,
    pub interests: Interests,
}

enum Entry {
    Heading(String),
    /// A context line: subject to hard-term filtering.
    Line {
        id: String,
        project: Option<String>,
        text: String,
    },
    /// A line exempt from hard-term filtering (interests, notices).
    Fixed {
        id: Option<String>,
        text: String,
    },
}

fn short_date(at: DateTime<Utc>) -> String {
    at.format("%b %-d").to_string()
}

fn project_entries(p: &ProjectContext, inputs: &DigestInputs) -> Vec<Entry> {
    let line = |id: String, text: String| Entry::Line {
        id,
        project: Some(p.id.clone()),
        text,
    };
    let mut out = vec![Entry::Heading(format!(
        "### {} [{}]",
        one_line(&p.name, 64),
        p.id
    ))];
    let how = match inputs.interests.how_it_runs_for(&p.id) {
        Some(own) => format!("How it runs: {} {CORRECTION_MARK}", one_line(own, 300)),
        None => format!("How it runs: {}", one_line(&p.how_it_runs, 300)),
    };
    out.push(line(format!("{}:how", p.id), how));
    if p.id == "bishop" {
        if let Some(posture) = &inputs.posture {
            out.push(line(
                "bishop:posture".into(),
                format!("Budget posture: {}", posture.line()),
            ));
        }
    }
    if p.id == "mother" {
        if let Some(queue) = &inputs.mother_queue {
            out.push(line("mother:posture".into(), queue.clone()));
        }
    }
    let mut open: Vec<&PrRecord> = p.prs.iter().filter(|r| r.state == PrState::Open).collect();
    open.sort_by_key(|r| std::cmp::Reverse(r.number));
    for pr in open {
        out.push(line(
            format!("{}:pr#{}", p.id, pr.number),
            format!("Open PR #{}: {}", pr.number, one_line(&pr.title, TITLE_MAX)),
        ));
    }
    let mut merged: Vec<&PrRecord> = p
        .prs
        .iter()
        .filter(|r| r.state == PrState::Merged)
        .collect();
    merged.sort_by(|a, b| b.at.cmp(&a.at).then(b.number.cmp(&a.number)));
    for pr in merged {
        out.push(line(
            format!("{}:merged#{}", p.id, pr.number),
            format!(
                "Merged {} #{}: {}",
                short_date(pr.at),
                pr.number,
                one_line(&pr.title, TITLE_MAX)
            ),
        ));
    }
    for board in &p.boards {
        let text = if board.open == 0 {
            format!("Board {}: nothing open", board.topic)
        } else {
            let more = if board.open > board.open_titles.len() {
                "; …"
            } else {
                ""
            };
            format!(
                "Board {}: {} open ({}{more})",
                board.topic,
                board.open,
                board.open_titles.join("; ")
            )
        };
        out.push(line(format!("tracker:{}", board.topic), text));
    }
    for job in &p.jobs {
        let title = if job.title.trim().is_empty() {
            job.id.as_str()
        } else {
            job.title.as_str()
        };
        out.push(line(
            format!("job:{}", one_line(&job.id, 40)),
            format!(
                "Job \"{}\": {}",
                one_line(title, TITLE_MAX),
                one_line(&job.state, 24)
            ),
        ));
    }
    for c in &p.commits {
        out.push(line(
            format!("{}:commit#{}", p.id, c.sha),
            format!(
                "Commit {}: {}",
                short_date(c.at),
                one_line(&c.subject, TITLE_MAX)
            ),
        ));
    }
    out
}

fn title_entry_line(e: &TitleEntry) -> Entry {
    let suffix = match (&e.state, e.date) {
        (Some(state), _) => format!(" ({state})"),
        (None, Some(d)) => format!(" ({d})"),
        (None, None) => String::new(),
    };
    Entry::Line {
        id: e.id.clone(),
        project: None,
        text: format!("{}{suffix}", one_line(&e.title, TITLE_MAX)),
    }
}

/// Is a project removed by the interests file (named under "Ignore entirely",
/// or its name is a hard-ignore term)?
pub fn project_ignored(interests: &Interests, id: &str, name: &str) -> bool {
    interests.ignores_project(id)
        || interests.ignores_project(name)
        || interests.hard_term_in(id).is_some()
        || interests.hard_term_in(name).is_some()
}

/// Render the digest. Pure: no I/O.
pub fn build_digest(inputs: &DigestInputs) -> Digest {
    let interests = &inputs.interests;
    let mut entries: Vec<Entry> = vec![Entry::Heading(format!(
        "# Context for Huey: {}, {} (v{})",
        one_line(&inputs.machine, 40),
        inputs.date,
        inputs.version
    ))];
    if let Some(mode) = &inputs.mode {
        entries.push(Entry::Heading(format!("Mode: {}", one_line(mode, 200))));
    }

    entries.push(Entry::Heading("## Interests".into()));
    for b in &interests.bullets {
        entries.push(Entry::Fixed {
            id: Some(b.id.clone()),
            text: format!("({}) {}", b.section.label(), one_line(&b.text, 300)),
        });
    }

    let mut projects: Vec<&ProjectContext> = inputs
        .projects
        .iter()
        .filter(|p| !project_ignored(interests, &p.id, &p.name))
        .collect();
    projects.sort_by(|a, b| {
        b.last_activity
            .cmp(&a.last_activity)
            .then_with(|| a.id.cmp(&b.id))
    });
    entries.push(Entry::Heading("## Projects in flight".into()));
    if !inputs.prs_available {
        entries.push(Entry::Fixed {
            id: None,
            text: "PRs unavailable (no GitHub token, or the search failed)".into(),
        });
    }
    if projects.is_empty() {
        entries.push(Entry::Fixed {
            id: None,
            text: "No projects in flight".into(),
        });
    }
    for p in &projects {
        entries.extend(project_entries(p, inputs));
    }

    let ids: BTreeSet<&str> = projects.iter().map(|p| p.id.as_str()).collect();
    let mut machine = Vec::new();
    if !ids.contains("bishop") {
        if let Some(posture) = &inputs.posture {
            machine.push(Entry::Line {
                id: "machine:posture".into(),
                project: None,
                text: format!("Budget posture: {}", posture.line()),
            });
        }
    }
    if !ids.contains("mother") {
        if let Some(queue) = &inputs.mother_queue {
            machine.push(Entry::Line {
                id: "machine:mother".into(),
                project: None,
                text: format!("Mother {queue}"),
            });
        }
    }
    if !machine.is_empty() {
        entries.push(Entry::Heading("## Machine".into()));
        entries.extend(machine);
    }

    let titles: Vec<Entry> = inputs
        .ideas
        .iter()
        .chain(&inputs.todos)
        .chain(&inputs.notes)
        .map(title_entry_line)
        .collect();
    if !titles.is_empty() {
        entries.push(Entry::Heading(
            "## Ideas, todos, notes (titles only)".into(),
        ));
        entries.extend(titles);
    }

    render(entries, inputs.interests.clone())
}

fn render(entries: Vec<Entry>, interests: Interests) -> Digest {
    // Hard-term filtering first, so the cap counts only what could be shown.
    let entries: Vec<Entry> = entries
        .into_iter()
        .filter(|e| match e {
            Entry::Line { text, .. } => interests.hard_term_in(text).is_none(),
            _ => true,
        })
        .collect();
    // Room for the "+N more" line.
    const RESERVE: usize = 32;
    let mut text = String::new();
    let mut anchors = BTreeSet::new();
    let mut project_anchors: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut projects = Vec::new();
    let mut seen_ids = BTreeSet::new();
    let mut dropped = 0usize;
    let mut truncated = false;
    for entry in entries {
        let (rendered, id, project) = match &entry {
            Entry::Heading(h) => (h.clone(), None, None),
            Entry::Line { id, project, text } => (
                format!("- [{id}] {text}"),
                Some(id.clone()),
                project.clone(),
            ),
            Entry::Fixed { id: Some(id), text } => {
                (format!("- [{id}] {text}"), Some(id.clone()), None)
            }
            Entry::Fixed { id: None, text } => (format!("- {text}"), None, None),
        };
        // A repeated id (two boards with one topic) keeps only the first line.
        if let Some(id) = &id {
            if !seen_ids.insert(id.clone()) {
                continue;
            }
        }
        // Once anything is cut, everything after it is too: the digest is a
        // clean prefix plus the count of lines left out.
        truncated |= text.len() + rendered.len() + 1 > MAX_DIGEST_BYTES - RESERVE;
        if truncated {
            if !matches!(entry, Entry::Heading(_)) {
                dropped += 1;
            }
            continue;
        }
        if let Entry::Heading(h) = &entry {
            if let Some(id) = project_heading_id(h) {
                projects.push(id);
            }
        }
        text.push_str(&rendered);
        text.push('\n');
        if let Some(id) = id {
            if let Some(project) = project {
                project_anchors
                    .entry(project)
                    .or_default()
                    .insert(id.clone());
            }
            anchors.insert(id);
        }
    }
    if dropped > 0 {
        text.push_str(&format!("- +{dropped} more\n"));
    }
    Digest {
        text,
        projects,
        anchors,
        project_anchors,
        interests,
    }
}

/// `### Name [id]` → `id`.
fn project_heading_id(heading: &str) -> Option<String> {
    let rest = heading.strip_prefix("### ")?;
    let start = rest.rfind('[')?;
    let id = rest[start + 1..].strip_suffix(']')?;
    Some(id.to_string())
}

/// Append each check's one-line result under "Checks Huey ran" (adding the
/// heading the first time). The anchors gain the check ids.
pub fn append_checks(digest: &mut Digest, checks: &[CheckResult]) {
    if checks.is_empty() {
        return;
    }
    if !digest.text.lines().any(|l| l == CHECKS_HEADING) {
        digest.text.push_str(CHECKS_HEADING);
        digest.text.push('\n');
    }
    for check in checks {
        digest.text.push_str(&format!("- {}\n", check.line()));
        digest.anchors.insert(check.id.clone());
    }
}
