//! The context digest (`digest.md`): the privacy boundary of Huey. It may
//! carry only titles, states, ids, counts, profile facts, interests bullets
//! and posture numbers. Every line carries an id the model can cite.
//!
//! Deterministic: identical inputs give byte-identical text (T9). Capped at
//! 16 KiB; whatever does not fit is counted in a final "+N more" line.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, NaiveDate, Utc};

use super::collectors::{safe_id, BoardSummary, PostureFacts, PrRecord, PrState, TitleEntry};
use super::projects::Commit;
use crate::data::work::untrusted::{escape_id, one_line};
use crate::huey::checks::CheckResult;
use crate::huey::interests::Interests;
use crate::mother::MotherJob;

/// Largest digest, in bytes, as [`build_digest`] renders it. The recent-reports
/// section ([`MAX_RECENT_BYTES`]) and "Checks Huey ran" (at most
/// `curate::MAX_CHECKS` lines) are appended after it, each with its own cap.
pub const MAX_DIGEST_BYTES: usize = 16 * 1024;
/// Heading of the section [`append_checks`] adds.
pub const CHECKS_HEADING: &str = "## Checks Huey ran";
/// Heading of the section [`append_recent_reports`] adds.
pub const RECENT_HEADING: &str = "## Recent reports (last 14 days; use these ids for follow_up_of)";
/// Most lines, and most bytes, the recent-reports section lists.
pub const MAX_RECENT_LINES: usize = 40;
pub const MAX_RECENT_BYTES: usize = 8 * 1024;
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
        out.push(line(format!("tracker:{}", safe_id(&board.topic, 64)), text));
    }
    for job in &p.jobs {
        let title = if job.title.trim().is_empty() {
            job.id.as_str()
        } else {
            job.title.as_str()
        };
        out.push(line(
            format!("job:{}", safe_id(&job.id, 40)),
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
            // The id is shown too (`idea:<slug>`), so it is filtered with the text.
            Entry::Line { id, text, .. } => {
                interests.hard_term_in(text).is_none()
                    && interests
                        .hard_term_in(&id.replace(['-', '_', '.'], " "))
                        .is_none()
            }
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

/// One earlier report line for the recent-reports section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecentLine {
    /// The item id as the model must cite it in `follow_up_of`.
    pub item_id: String,
    pub date: NaiveDate,
    /// `pick`, `ain`, `also_noted` or `uncurated`.
    pub section: &'static str,
    /// The headline that report showed, when known.
    pub title: Option<String>,
}

/// Append the recent-reports section (items shown in the last 14 days, so
/// the model can say what is new about a follow-up). The section is part of
/// the digest, so the shown `digest.md` is everything the model is told
/// about the user's context. `lines` must already be in the order to show;
/// as many as fit in [`MAX_RECENT_LINES`] lines and [`MAX_RECENT_BYTES`]
/// bytes are listed, the rest counted in a final "+N more". Returns how
/// many were listed, a prefix of `lines`.
pub fn append_recent_reports(digest: &mut Digest, lines: &[RecentLine]) -> usize {
    digest.text.push_str(RECENT_HEADING);
    digest.text.push('\n');
    let start = digest.text.len();
    let mut listed = 0;
    for line in lines.iter().take(MAX_RECENT_LINES) {
        let Some(id) = escape_id(&line.item_id) else {
            break;
        };
        let title = line
            .title
            .as_deref()
            .map(|t| one_line(t, TITLE_MAX))
            .filter(|t| !t.is_empty())
            .map(|t| format!(": {t}"))
            .unwrap_or_default();
        let rendered = format!("- [{id}] {} {}{title}\n", line.date, line.section);
        if digest.text.len() - start + rendered.len() > MAX_RECENT_BYTES {
            break;
        }
        digest.text.push_str(&rendered);
        listed += 1;
    }
    if lines.is_empty() {
        digest.text.push_str("- (none)\n");
    } else if listed < lines.len() {
        digest
            .text
            .push_str(&format!("- +{} more\n", lines.len() - listed));
    }
    listed
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

#[cfg(test)]
mod recent_tests {
    use super::*;

    fn digest() -> Digest {
        Digest {
            text: "# Context\n".to_string(),
            projects: Vec::new(),
            anchors: BTreeSet::new(),
            project_anchors: BTreeMap::new(),
            interests: Interests::default(),
        }
    }

    fn line(n: usize, title: Option<&str>) -> RecentLine {
        RecentLine {
            item_id: format!("src:item{n}"),
            date: NaiveDate::from_ymd_opt(2026, 10, 20).unwrap(),
            section: "pick",
            title: title.map(str::to_string),
        }
    }

    #[test]
    fn no_recent_reports_says_none() {
        let mut d = digest();
        assert_eq!(append_recent_reports(&mut d, &[]), 0);
        assert_eq!(d.text, format!("# Context\n{RECENT_HEADING}\n- (none)\n"));
    }

    #[test]
    fn a_line_carries_its_id_date_section_and_one_line_headline() {
        let mut d = digest();
        let lines = [
            line(1, Some("A  headline\nwith\u{200B} breaks")),
            line(2, None),
        ];
        assert_eq!(append_recent_reports(&mut d, &lines), 2);
        assert!(d.text.ends_with(
            "- [src:item1] 2026-10-20 pick: A headline with breaks\n- [src:item2] 2026-10-20 pick\n"
        ));
        assert!(d.anchors.is_empty(), "item ids are not anchors");
    }

    #[test]
    fn the_section_is_capped_by_lines_and_by_bytes_and_counts_the_rest() {
        let mut d = digest();
        let lines: Vec<RecentLine> = (0..MAX_RECENT_LINES + 5)
            .map(|n| line(n, Some("t")))
            .collect();
        assert_eq!(append_recent_reports(&mut d, &lines), MAX_RECENT_LINES);
        assert!(d.text.ends_with("- +5 more\n"), "{}", d.text);

        let mut d = digest();
        let long = "w ".repeat(60);
        let lines: Vec<RecentLine> = (0..40)
            .map(|n| RecentLine {
                item_id: format!("src:{}{n}", "k".repeat(250)),
                ..line(n, Some(&long))
            })
            .collect();
        let listed = append_recent_reports(&mut d, &lines);
        assert!(listed < 40);
        assert!(
            d.text.len() <= "# Context\n".len() + RECENT_HEADING.len() + 1 + MAX_RECENT_BYTES + 32
        );
        assert!(d.text.ends_with(&format!("- +{} more\n", 40 - listed)));
    }
}
