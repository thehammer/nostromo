//! Teri "Repo docs" source (T1): scans `<root>/<repo>/.claude/` doc-mgr layouts
//! and publishes them as work items. These tests pin the observable contract:
//! what is (and is not) an item, how titles / dates / severity / priority are
//! read, how failures are reported (every file that could not be read is
//! counted, never silently dropped), how rescans avoid re-reading unchanged
//! files, how the live watcher reacts, what the detail view returns and how
//! the hub republishes it.
//!
//! Every root is a canonicalised temp dir (macOS temp lives under /var, a
//! symlink to /private/var) so path comparisons are exact.
//!
//! Nothing here asserts on wall-clock time and nothing waits a fixed time:
//! failures are injected through `DocFs` (so they behave the same for a root
//! user as for anyone else), work is measured by counting reads, and live
//! changes are polled for with a generous bound.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::io;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, TimeZone, Utc};
use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::data::work::hub::{HubDeps, SourceUpdate, WorkHub};
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::repo_docs::{detail_at, spawn_at, spawn_with_fs, DocFs, RealFs, Scanner};
use nostromo::data::work::{
    SourceState, SourceStatus, WorkDetail, WorkItem, WorkService, WorkSource,
};
use nostromo::ipc::protocol::ServerMsg;
use tempfile::TempDir;
use tokio::sync::{broadcast, watch, Notify};

/// How long a live change may take to show up before a test gives up. Generous on
/// purpose: it only costs time when something is broken.
const LIVE_DEADLINE: Duration = Duration::from_secs(30);

// ── fixture ──────────────────────────────────────────────────────────────────

struct Fx {
    _tmp: TempDir,
    root: PathBuf,
}

fn put(root: &Path, rel: &str, content: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, content).unwrap();
}

fn temp_root() -> (TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(tmp.path()).unwrap().join("code");
    fs::create_dir_all(&root).unwrap();
    (tmp, root)
}

/// Three real repos, a symlinked repo, and everything that must be ignored.
/// 12 items: alpha 8, beta 2, gamma 1, link-repo 1.
fn fixture() -> Fx {
    let (tmp, root) = temp_root();

    // alpha: one of every kind, plus every kind of excluded thing.
    fs::create_dir_all(root.join("alpha/.git")).unwrap(); // a normal repo: .git is a directory
    put(&root, "alpha/.claude/bugs/open/2026-10-01-login-fails.md",
        "# Login button does nothing\n\n**Severity:** high\n\nThe quokkaword only appears in the body.\n");
    put(
        &root,
        "alpha/.claude/bugs/open/2026-10-02-no-heading-here.md",
        "Nothing states a title, a severity or a priority.\n",
    );
    put(
        &root,
        "alpha/.claude/bugs/open/2026-10-07-has space.md",
        "Spaces in file names must survive.\n",
    );
    put(
        &root,
        "alpha/.claude/bugs/open/screenshot.png",
        "not markdown",
    );
    put(
        &root,
        "alpha/.claude/bugs/resolved/2026-09-01-old.md",
        "# Resolved\n",
    );
    put(&root, "alpha/.claude/features/backlog/dark-mode.md",
        "---\nseverity: medium\npriority: P2\ndate: 2026-09-15\n---\n\n# Dark mode support\n\nUsers want a dark theme.\n");
    put(
        &root,
        "alpha/.claude/features/shipped/2026-08-01-shipped.md",
        "# Shipped\n",
    );
    put(
        &root,
        "alpha/.claude/ideas/undated-idea_for_later.md",
        "Maybe someday.\n",
    );
    put(
        &root,
        "alpha/.claude/todos/open/2026-10-04-write-docs.md",
        "# Write the docs\n\n**Priority:** urgent\n",
    );
    put(
        &root,
        "alpha/.claude/todos/done/2026-09-30-done.md",
        "# Done\n",
    );
    put(
        &root,
        "alpha/.claude/wip/my-topic/index.md",
        "# My topic plan\n\nPlan body.\n",
    );
    put(&root, "alpha/.claude/wip/my-topic/b-notes.md", "notes\n");
    put(&root, "alpha/.claude/wip/my-topic/a-data.csv", "a,b\n");
    put(&root, "alpha/.claude/wip/my-topic/sketches/s.png", "png");
    put(
        &root,
        "alpha/.claude/wip/no-index/notes.txt",
        "just notes\n",
    );
    put(&root, "alpha/.claude/notes/decision.md", "# A decision\n");
    put(
        &root,
        "alpha/.claude/bug-reports/legacy.md",
        "# Legacy bug\n",
    );
    put(
        &root,
        "alpha/.claude/feature-requests/legacy.md",
        "# Legacy feature\n",
    );
    put(&root, "alpha/.claude/TODO.md", "# Legacy todo\n");

    put(
        &root,
        "beta/.claude/bugs/open/2026-09-20-beta-bug.md",
        "# Beta bug\n\n**SEVERITY:** critical\n**Priority:** P1\n",
    );
    put(
        &root,
        "beta/.claude/todos/open/beta-todo.md",
        "Just a plain todo.\n",
    );
    put(
        &root,
        "gamma/.claude/ideas/2026-08-15-gamma-idea.md",
        "A gamma idea.\n",
    );

    // Symlinked repo dir whose real location is outside the root: included once.
    let outside = root.parent().unwrap().join("outside/linked-src");
    put(
        &outside,
        ".claude/bugs/open/linked-bug.md",
        "---\nfiled: 2026-07-04\n---\nSomething broke in the linked repo.\n",
    );
    symlink(&outside, root.join("link-repo")).unwrap();

    // Ignored children.
    put(&root, ".hidden/.claude/bugs/open/x.md", "# Hidden\n");
    put(
        &root,
        "alpha-wt/.git",
        "gitdir: /somewhere/else/.git/worktrees/alpha-wt\n",
    ); // worktree: .git is a file
    put(
        &root,
        "alpha-wt/.claude/bugs/open/x.md",
        "# Worktree copy\n",
    );
    put(&root, "nodocs/README.md", "no .claude here\n");
    fs::write(root.join("README.md"), "a plain file in the root\n").unwrap();

    Fx { _tmp: tmp, root }
}

// ── injected file-system faults and counters ─────────────────────────────────

#[derive(Default)]
struct Faults {
    deny_read: Mutex<HashSet<PathBuf>>,
    deny_metadata: Mutex<HashSet<PathBuf>>,
    deny_symlink_metadata: Mutex<HashSet<PathBuf>>,
    panic_on_read: AtomicBool,
    reads: AtomicUsize,
}

/// The real file system, except where a test says otherwise: chosen paths answer
/// `PermissionDenied` (whoever runs the tests), reads are counted, and a read can
/// be made to panic. Clones share their settings.
#[derive(Clone, Default)]
struct TestFs(Arc<Faults>);

fn denied() -> io::Error {
    io::Error::from(io::ErrorKind::PermissionDenied)
}

impl TestFs {
    fn deny_read(&self, path: impl Into<PathBuf>) {
        self.0.deny_read.lock().unwrap().insert(path.into());
    }
    fn allow_read(&self, path: &Path) {
        self.0.deny_read.lock().unwrap().remove(path);
    }
    fn deny_metadata(&self, path: impl Into<PathBuf>) {
        self.0.deny_metadata.lock().unwrap().insert(path.into());
    }
    fn deny_symlink_metadata(&self, path: impl Into<PathBuf>) {
        self.0
            .deny_symlink_metadata
            .lock()
            .unwrap()
            .insert(path.into());
    }
    fn allow_symlink_metadata(&self, path: &Path) {
        self.0.deny_symlink_metadata.lock().unwrap().remove(path);
    }
    fn allow_metadata(&self, path: &Path) {
        self.0.deny_metadata.lock().unwrap().remove(path);
    }
    fn panic_on_read(&self, on: bool) {
        self.0.panic_on_read.store(on, Ordering::SeqCst);
    }
    /// How many times a doc's text was read (attempts included).
    fn reads(&self) -> usize {
        self.0.reads.load(Ordering::SeqCst)
    }
}

impl DocFs for TestFs {
    fn metadata(&self, path: &Path) -> io::Result<fs::Metadata> {
        if self.0.deny_metadata.lock().unwrap().contains(path) {
            return Err(denied());
        }
        RealFs.metadata(path)
    }
    fn symlink_metadata(&self, path: &Path) -> io::Result<fs::Metadata> {
        if self.0.deny_symlink_metadata.lock().unwrap().contains(path) {
            return Err(denied());
        }
        RealFs.symlink_metadata(path)
    }
    fn read_text(&self, path: &Path, limit: u64) -> io::Result<String> {
        self.0.reads.fetch_add(1, Ordering::SeqCst);
        if self.0.panic_on_read.load(Ordering::SeqCst) {
            panic!("injected: reading {} panics", path.display());
        }
        if self.0.deny_read.lock().unwrap().contains(path) {
            return Err(denied());
        }
        RealFs.read_text(path, limit)
    }
}

fn scanner_over(root: &Path, io: &TestFs) -> Scanner {
    Scanner::with_fs(root.to_path_buf(), Arc::new(io.clone()))
}

fn scan(root: &Path) -> SourceUpdate {
    Scanner::new(root.to_path_buf()).scan_all()
}

fn items_of(update: &SourceUpdate, repo: &str) -> Vec<WorkItem> {
    update
        .1
        .iter()
        .filter(|(g, _)| g.as_deref() == Some(repo))
        .flat_map(|(_, items)| items.clone())
        .collect()
}

fn all_items(update: &SourceUpdate) -> Vec<&WorkItem> {
    update
        .1
        .iter()
        .flat_map(|(_, items)| items.iter())
        .collect()
}

fn item<'a>(update: &'a SourceUpdate, id: &str) -> &'a WorkItem {
    all_items(update)
        .into_iter()
        .find(|i| i.id == id)
        .unwrap_or_else(|| {
            panic!(
                "no item {id}; have {:?}",
                all_items(update).iter().map(|i| &i.id).collect::<Vec<_>>()
            )
        })
}

fn noon(y: i32, m: u32, d: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, m, d, 12, 0, 0).unwrap()
}

fn field<'a>(detail: &'a WorkDetail, label: &str) -> Option<&'a str> {
    detail
        .fields
        .iter()
        .find(|(k, _)| k == label)
        .map(|(_, v)| v.as_str())
}

const ALPHA_BUG: &str = "doc:alpha:bugs/open/2026-10-01-login-fails.md";
const ALPHA_NO_HEADING: &str = "doc:alpha:bugs/open/2026-10-02-no-heading-here.md";
const ALPHA_SPACE: &str = "doc:alpha:bugs/open/2026-10-07-has space.md";
const ALPHA_FEATURE: &str = "doc:alpha:features/backlog/dark-mode.md";
const ALPHA_IDEA: &str = "doc:alpha:ideas/undated-idea_for_later.md";
const ALPHA_TODO: &str = "doc:alpha:todos/open/2026-10-04-write-docs.md";
const ALPHA_WIP: &str = "doc:alpha:wip/my-topic";
const ALPHA_WIP_NO_INDEX: &str = "doc:alpha:wip/no-index";
const BETA_BUG: &str = "doc:beta:bugs/open/2026-09-20-beta-bug.md";
const BETA_TODO: &str = "doc:beta:todos/open/beta-todo.md";
const GAMMA_IDEA: &str = "doc:gamma:ideas/2026-08-15-gamma-idea.md";
const LINKED_BUG: &str = "doc:link-repo:bugs/open/linked-bug.md";

// ── what is an item ──────────────────────────────────────────────────────────

#[test]
fn only_open_doc_dirs_of_real_repos_become_items() {
    let fx = fixture();

    let update = scan(&fx.root);

    let ids: BTreeSet<&str> = all_items(&update).iter().map(|i| i.id.as_str()).collect();
    let expected: BTreeSet<&str> = [
        ALPHA_BUG,
        ALPHA_NO_HEADING,
        ALPHA_SPACE,
        ALPHA_FEATURE,
        ALPHA_IDEA,
        ALPHA_TODO,
        ALPHA_WIP,
        ALPHA_WIP_NO_INDEX,
        BETA_BUG,
        BETA_TODO,
        GAMMA_IDEA,
        LINKED_BUG,
    ]
    .into_iter()
    .collect();
    assert_eq!(
        ids, expected,
        "resolved/shipped/done/notes/legacy/hidden/worktree/non-md are never items"
    );
    assert_eq!(
        all_items(&update).len(),
        12,
        "no item appears twice (symlinked repo counted once)"
    );
}

#[test]
fn items_are_grouped_one_group_per_repo_keyed_by_repo_name() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(items_of(&update, "alpha").len(), 8);
    assert_eq!(items_of(&update, "beta").len(), 2);
    assert_eq!(items_of(&update, "gamma").len(), 1);
    assert_eq!(items_of(&update, "link-repo").len(), 1);
    for (group, items) in &update.1 {
        let repo = group
            .as_deref()
            .expect("repo docs groups are keyed by repo");
        assert!(
            !["alpha-wt", ".hidden", "nodocs"].contains(&repo),
            "{repo} must not be a group with items: {}",
            items.len()
        );
        for i in items {
            assert_eq!(i.repo.as_deref(), Some(repo));
            assert_eq!(i.source, WorkSource::RepoDocs);
        }
    }
}

#[test]
fn each_doc_directory_maps_to_its_kind() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(item(&update, ALPHA_BUG).kind, "bug");
    assert_eq!(item(&update, ALPHA_FEATURE).kind, "feature");
    assert_eq!(item(&update, ALPHA_IDEA).kind, "idea");
    assert_eq!(item(&update, ALPHA_TODO).kind, "todo");
    assert_eq!(item(&update, ALPHA_WIP).kind, "wip");
    assert_eq!(
        item(&update, ALPHA_WIP_NO_INDEX).kind,
        "wip",
        "a wip folder without index.md is still an item"
    );
}

#[test]
fn item_path_is_the_absolute_file_or_the_wip_directory() {
    let fx = fixture();

    let update = scan(&fx.root);

    let bug = item(&update, ALPHA_BUG);
    assert_eq!(
        bug.path.as_deref(),
        Some(
            fx.root
                .join("alpha/.claude/bugs/open/2026-10-01-login-fails.md")
                .to_str()
                .unwrap()
        )
    );
    let wip = item(&update, ALPHA_WIP);
    assert_eq!(
        wip.path.as_deref(),
        Some(fx.root.join("alpha/.claude/wip/my-topic").to_str().unwrap())
    );
    let linked = item(&update, LINKED_BUG);
    assert!(linked
        .path
        .as_deref()
        .unwrap()
        .ends_with("/.claude/bugs/open/linked-bug.md"));
}

// ── titles ───────────────────────────────────────────────────────────────────

#[test]
fn title_is_the_first_heading_even_after_front_matter() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(item(&update, ALPHA_BUG).title, "Login button does nothing");
    assert_eq!(item(&update, ALPHA_FEATURE).title, "Dark mode support");
    assert_eq!(item(&update, ALPHA_TODO).title, "Write the docs");
    assert_eq!(
        item(&update, ALPHA_WIP).title,
        "My topic plan",
        "a wip item is titled by its index.md heading"
    );
}

#[test]
fn title_without_a_heading_is_the_humanised_file_name() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(
        item(&update, ALPHA_NO_HEADING).title,
        "No heading here",
        "date prefix stripped, dashes to spaces, capitalised"
    );
    assert_eq!(item(&update, ALPHA_SPACE).title, "Has space");
    assert_eq!(
        item(&update, ALPHA_IDEA).title,
        "Undated idea for later",
        "underscores become spaces too"
    );
    assert_eq!(item(&update, BETA_TODO).title, "Beta todo");
    assert_eq!(item(&update, GAMMA_IDEA).title, "Gamma idea");
    assert_eq!(
        item(&update, LINKED_BUG).title,
        "Linked bug",
        "front matter alone is not a title"
    );
}

#[test]
fn wip_folder_without_index_is_titled_by_the_folder_name_verbatim() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(item(&update, ALPHA_WIP_NO_INDEX).title, "no-index");
}

// ── severity and priority ────────────────────────────────────────────────────

#[test]
fn severity_comes_from_body_line_or_front_matter_and_is_never_inferred() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(
        item(&update, ALPHA_BUG).severity.as_deref(),
        Some("high"),
        "**Severity:** body line"
    );
    assert_eq!(
        item(&update, ALPHA_FEATURE).severity.as_deref(),
        Some("medium"),
        "front matter"
    );
    assert_eq!(
        item(&update, BETA_BUG).severity.as_deref(),
        Some("critical"),
        "the body line label is case-insensitive"
    );
    assert_eq!(
        item(&update, ALPHA_NO_HEADING).severity,
        None,
        "a doc that states none has none"
    );
    assert_eq!(item(&update, ALPHA_TODO).severity, None);
    assert_eq!(item(&update, ALPHA_WIP).severity, None);
}

#[test]
fn priority_p_levels_map_to_label_and_rank_and_other_words_rank_nine() {
    let fx = fixture();

    let update = scan(&fx.root);

    let p2 = item(&update, ALPHA_FEATURE)
        .priority
        .clone()
        .expect("front matter priority");
    assert_eq!((p2.label.as_str(), p2.rank), ("P2", 2));
    let p1 = item(&update, BETA_BUG)
        .priority
        .clone()
        .expect("**Priority:** body line");
    assert_eq!((p1.label.as_str(), p1.rank), ("P1", 1));
    let urgent = item(&update, ALPHA_TODO)
        .priority
        .clone()
        .expect("a non-P word is kept");
    assert_eq!((urgent.label.as_str(), urgent.rank), ("urgent", 9));
    assert_eq!(item(&update, ALPHA_BUG).priority, None);
}

// ── dates ────────────────────────────────────────────────────────────────────

#[test]
fn created_at_comes_from_the_file_name_date_prefix_at_noon_utc() {
    let fx = fixture();

    let update = scan(&fx.root);

    let bug = item(&update, ALPHA_BUG);
    assert_eq!(bug.created_at, Some(noon(2026, 10, 1)));
    assert!(!bug.metrics.contains_key("date_inferred"));
    assert_eq!(
        item(&update, GAMMA_IDEA).created_at,
        Some(noon(2026, 8, 15))
    );
}

#[test]
fn created_at_falls_back_to_front_matter_date_or_filed() {
    let fx = fixture();

    let update = scan(&fx.root);

    let dated = item(&update, ALPHA_FEATURE);
    assert_eq!(
        dated.created_at,
        Some(noon(2026, 9, 15)),
        "front matter `date:`"
    );
    assert!(!dated.metrics.contains_key("date_inferred"));
    let filed = item(&update, LINKED_BUG);
    assert_eq!(
        filed.created_at,
        Some(noon(2026, 7, 4)),
        "front matter `filed:`"
    );
    assert!(!filed.metrics.contains_key("date_inferred"));
}

#[test]
fn undated_doc_uses_the_file_time_and_is_flagged_as_inferred() {
    let fx = fixture();

    let update = scan(&fx.root);

    let idea = item(&update, ALPHA_IDEA);
    assert_eq!(idea.metrics.get("date_inferred"), Some(&1));
    let created = idea.created_at.expect("an inferred date is still a date");
    assert!(
        (Utc::now() - created).num_seconds().abs() < 300,
        "inferred from a file just written: {created}"
    );
}

#[test]
fn updated_at_is_the_file_modification_time() {
    let fx = fixture();

    let update = scan(&fx.root);

    let updated = item(&update, ALPHA_BUG).updated_at.expect("updated_at");
    assert!(
        (Utc::now() - updated).num_seconds().abs() < 300,
        "just written: {updated}"
    );
}

// ── search text ──────────────────────────────────────────────────────────────

#[test]
fn search_text_is_the_title_then_the_body_so_body_only_words_are_searchable() {
    let fx = fixture();

    let update = scan(&fx.root);

    let text = &item(&update, ALPHA_BUG).search_text;
    assert!(
        text.starts_with("Login button does nothing\n"),
        "title, newline, body: {text:?}"
    );
    assert!(text.contains("quokkaword"));
}

#[test]
fn search_text_is_capped_at_64_kib_without_splitting_a_character() {
    let fx = fixture();
    // ~240 KiB of 1-, 2- and 3-byte characters: any byte-offset cut lands mid-character somewhere.
    let body = "x\u{e9}\u{65e5}\u{672c} ".repeat(30_000);
    put(
        &fx.root,
        "alpha/.claude/ideas/huge.md",
        &format!("# Huge doc\n\n{body}"),
    );

    let update = scan(&fx.root);

    let text = &item(&update, "doc:alpha:ideas/huge.md").search_text;
    assert!(text.len() <= 65_536, "search_text is {} bytes", text.len());
    assert!(
        text.len() >= 65_536 - 8,
        "the cap should not truncate far below 64 KiB ({} bytes)",
        text.len()
    );
    assert!(text.starts_with("Huge doc\n"));
}

// ── source status ────────────────────────────────────────────────────────────

#[test]
fn a_healthy_scan_is_fresh_with_the_total_item_count_and_no_errors_and_no_note() {
    let fx = fixture();

    let (status, _) = scan(&fx.root);

    assert_eq!(status.source, WorkSource::RepoDocs);
    assert_eq!(status.state, SourceState::Fresh);
    assert_eq!(status.count, 12);
    assert!(status.group_errors.is_empty());
    assert_eq!(
        status.reason, None,
        "nothing was left out, so there is nothing to say"
    );
}

fn group_error<'a>(status: &'a SourceStatus, repo: &str) -> Option<&'a str> {
    status
        .group_errors
        .iter()
        .find(|e| e.group == repo)
        .map(|e| e.reason.as_str())
}

/// A scan that left something out is readable, but must never look plain "fresh".
fn assert_partial(status: &SourceStatus, failed_repos: usize, of_repos: usize) {
    assert_eq!(
        status.state,
        SourceState::Fresh,
        "only an every-repo failure is an error: {status:?}"
    );
    assert_eq!(
        status.reason.as_deref(),
        Some(
            format!("Partial scan: {failed_repos} of {of_repos} repos could not be fully read")
                .as_str()
        )
    );
    assert_eq!(
        status.group_errors.len(),
        failed_repos,
        "{:?}",
        status.group_errors
    );
}

// ── silent read failures are counted ─────────────────────────────────────────

#[test]
fn a_doc_that_cannot_be_read_is_counted_and_the_scan_is_never_plain_fresh() {
    let fx = fixture();
    let io = TestFs::default();
    let unreadable = fx
        .root
        .join("alpha/.claude/bugs/open/2026-10-01-login-fails.md");
    io.deny_read(&unreadable);
    let mut scanner = scanner_over(&fx.root, &io);

    let update = scanner.scan_all();

    let (status, _) = &update;
    assert_partial(status, 1, 4);
    let reason = group_error(status, "alpha").expect("alpha carries the error");
    assert!(reason.contains("skipped 1 unreadable file"), "{reason}");
    assert!(!reason.contains("files"), "one file is singular: {reason}");
    assert_eq!(status.count, 11);
    assert_eq!(
        items_of(&update, "alpha").len(),
        7,
        "the readable docs of the repo still show"
    );
    assert!(items_of(&update, "alpha").iter().all(|i| i.id != ALPHA_BUG));
    assert_eq!(
        items_of(&update, "beta").len(),
        2,
        "other repos are unaffected"
    );

    // The failure is not remembered: once the file can be read again the repo is clean.
    io.allow_read(&unreadable);
    let update = scanner.rescan_repo("alpha");
    assert_eq!(update.0.reason, None);
    assert!(
        update.0.group_errors.is_empty(),
        "{:?}",
        update.0.group_errors
    );
    assert_eq!(update.0.count, 12);
    assert_eq!(item(&update, ALPHA_BUG).title, "Login button does nothing");
}

#[test]
fn several_unreadable_docs_are_all_counted() {
    let fx = fixture();
    let io = TestFs::default();
    io.deny_read(
        fx.root
            .join("alpha/.claude/bugs/open/2026-10-01-login-fails.md"),
    );
    io.deny_read(fx.root.join("alpha/.claude/features/backlog/dark-mode.md"));
    io.deny_read(
        fx.root
            .join("alpha/.claude/ideas/undated-idea_for_later.md"),
    );

    let (status, _) = scanner_over(&fx.root, &io).scan_all();

    assert_partial(&status, 1, 4);
    let reason = group_error(&status, "alpha").unwrap();
    assert!(reason.contains("skipped 3 unreadable files"), "{reason}");
}

#[test]
fn a_doc_that_cannot_be_examined_is_counted_too() {
    let fx = fixture();
    let io = TestFs::default();
    let unreadable = fx.root.join("beta/.claude/todos/open/beta-todo.md");
    io.deny_metadata(&unreadable);
    let mut scanner = scanner_over(&fx.root, &io);

    let update = scanner.scan_all();

    assert_partial(&update.0, 1, 4);
    assert!(group_error(&update.0, "beta")
        .unwrap()
        .contains("skipped 1 unreadable file"));
    assert_eq!(
        items_of(&update, "beta").len(),
        1,
        "the other beta doc still shows"
    );
    assert_eq!(items_of(&update, "alpha").len(), 8);

    io.allow_metadata(&unreadable);
    let update = scanner.rescan_repo("beta");
    assert_eq!(update.0.reason, None);
    assert_eq!(items_of(&update, "beta").len(), 2);
}

#[test]
fn a_wip_folder_whose_index_cannot_be_read_is_listed_without_a_body_and_not_remembered() {
    let fx = fixture();
    let io = TestFs::default();
    let index = fx.root.join("alpha/.claude/wip/my-topic/index.md");
    io.deny_read(&index);
    let mut scanner = scanner_over(&fx.root, &io);

    let update = scanner.scan_all();

    assert_partial(&update.0, 1, 4);
    assert!(group_error(&update.0, "alpha")
        .unwrap()
        .contains("skipped 1 unreadable file"));
    assert_eq!(update.0.count, 12, "the folder is still an item");
    let wip = item(&update, ALPHA_WIP);
    assert_eq!(
        wip.title, "my-topic",
        "with no body to read the folder name is the title"
    );
    assert!(
        !wip.search_text.contains("Plan body"),
        "{:?}",
        wip.search_text
    );

    // Retried on the next scan, not served from a cache of the failure.
    io.allow_read(&index);
    let update = scanner.rescan_repo("alpha");
    assert_eq!(update.0.reason, None);
    assert!(update.0.group_errors.is_empty());
    let wip = item(&update, ALPHA_WIP);
    assert_eq!(wip.title, "My topic plan");
    assert!(wip.search_text.contains("Plan body"));
}

#[test]
fn a_wip_index_that_cannot_be_examined_is_listed_without_a_body_and_counted() {
    let fx = fixture();
    let io = TestFs::default();
    let index = fx.root.join("alpha/.claude/wip/my-topic/index.md");
    io.deny_metadata(&index);
    let mut scanner = scanner_over(&fx.root, &io);

    let update = scanner.scan_all();

    assert_partial(&update.0, 1, 4);
    assert_eq!(item(&update, ALPHA_WIP).title, "my-topic");

    io.allow_metadata(&index);
    let update = scanner.rescan_repo("alpha");
    assert_eq!(update.0.reason, None);
    assert_eq!(item(&update, ALPHA_WIP).title, "My topic plan");
}

#[test]
fn a_repo_whose_folder_cannot_be_searched_is_a_group_error_not_a_vanished_repo() {
    let fx = fixture();
    put(&fx.root, "delta/.claude/bugs/open/x.md", "# Delta bug\n");
    let io = TestFs::default();
    let claude = fx.root.join("delta/.claude");
    io.deny_symlink_metadata(&claude); // what a repo directory without search permission does
    let mut scanner = scanner_over(&fx.root, &io);

    let update = scanner.scan_all();

    let (status, _) = &update;
    assert_partial(status, 1, 5);
    assert!(!group_error(status, "delta")
        .expect("delta is reported, not dropped")
        .trim()
        .is_empty());
    assert!(items_of(&update, "delta").is_empty());
    assert_eq!(status.count, 12);
    assert_eq!(items_of(&update, "alpha").len(), 8);

    io.allow_symlink_metadata(&claude);
    let update = scanner.rescan_repo("delta");
    assert_eq!(update.0.state, SourceState::Fresh);
    assert_eq!(update.0.reason, None);
    assert_eq!(items_of(&update, "delta").len(), 1);
}

#[test]
fn a_claude_folder_that_cannot_be_examined_is_a_group_error() {
    let fx = fixture();
    let io = TestFs::default();
    io.deny_metadata(fx.root.join("gamma/.claude"));

    let (status, _) = scanner_over(&fx.root, &io).scan_all();

    assert_partial(&status, 1, 4);
    assert!(!group_error(&status, "gamma").unwrap().trim().is_empty());
}

#[test]
fn when_every_repo_fails_the_source_is_in_error() {
    let (_tmp, root) = temp_root();
    put(&root, "delta/.claude/bugs/open/x.md", "# Unreachable\n");
    let io = TestFs::default();
    io.deny_symlink_metadata(root.join("delta/.claude"));

    let (status, groups) = scanner_over(&root, &io).scan_all();

    assert_eq!(status.state, SourceState::Error);
    assert!(
        status
            .reason
            .as_deref()
            .is_some_and(|r| !r.trim().is_empty()),
        "{status:?}"
    );
    assert_eq!(status.count, 0);
    assert_eq!(status.group_errors.len(), 1);
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

#[test]
fn a_root_with_repos_but_no_docs_is_empty_not_an_error() {
    let (_tmp, root) = temp_root();
    fs::create_dir_all(root.join("alpha/.claude/bugs/open")).unwrap();
    put(
        &root,
        "alpha/.claude/bugs/resolved/2026-01-01-old.md",
        "# Resolved\n",
    );
    fs::create_dir_all(root.join("beta/.claude")).unwrap();

    let (status, groups) = scan(&root);

    assert_eq!(status.state, SourceState::Empty);
    assert_eq!(status.count, 0);
    assert!(status.group_errors.is_empty());
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

#[test]
fn a_missing_root_is_not_configured() {
    let tmp = tempfile::tempdir().unwrap();

    let (status, groups) = Scanner::new(tmp.path().join("no-such-dir")).scan_all();

    assert_eq!(status.state, SourceState::NotConfigured);
    assert_eq!(status.count, 0);
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

// ── incremental rescans (measured in reads, not seconds) ─────────────────────

const PERF_REPOS: usize = 10;
const PERF_DOCS: usize = 100;

fn perf_path(repo: usize, doc: usize) -> String {
    let dir = ["bugs/open", "features/backlog", "ideas", "todos/open"][doc % 4];
    format!(
        "repo-{repo:02}/.claude/{dir}/2026-09-{:02}-doc-{doc:03}.md",
        doc % 28 + 1
    )
}

fn perf_body(repo: usize, doc: usize) -> String {
    let line =
        format!("Synthetic line for repo {repo} doc {doc} describing some behaviour in prose.\n");
    format!("# Title r{repo} d{doc}\n\n{}", line.repeat(13)) // ~1 KiB
}

fn perf_tree() -> (TempDir, PathBuf) {
    let (tmp, root) = temp_root();
    for r in 0..PERF_REPOS {
        for d in 0..PERF_DOCS {
            put(&root, &perf_path(r, d), &perf_body(r, d));
        }
    }
    (tmp, root)
}

#[test]
fn a_cold_scan_reads_each_doc_exactly_once() {
    let (_tmp, root) = perf_tree();
    let io = TestFs::default();
    let mut scanner = scanner_over(&root, &io);

    let (status, _) = scanner.scan_all();

    assert_eq!(status.count, PERF_REPOS * PERF_DOCS);
    assert_eq!(io.reads(), PERF_REPOS * PERF_DOCS);
}

#[test]
fn an_unchanged_tree_rescans_without_reading_a_single_doc() {
    let (_tmp, root) = perf_tree();
    let io = TestFs::default();
    let mut scanner = scanner_over(&root, &io);
    scanner.scan_all();
    let after_cold_scan = io.reads();

    let (status, _) = scanner.scan_all();

    assert_eq!(status.count, PERF_REPOS * PERF_DOCS);
    assert_eq!(
        io.reads() - after_cold_scan,
        0,
        "every parse came from the cache"
    );
}

#[test]
fn rescanning_one_repo_after_editing_one_file_reads_only_that_file_and_reflects_the_edit() {
    let (_tmp, root) = perf_tree();
    let io = TestFs::default();
    let mut scanner = scanner_over(&root, &io);
    scanner.scan_all();
    // Different content and size, so neither mtime nor length can match the cached entry.
    put(
        &root,
        &perf_path(3, 7),
        &format!(
            "# Rewritten heading\n\n{}",
            "A much longer replacement body. ".repeat(80)
        ),
    );
    let before = io.reads();

    let update = scanner.rescan_repo("repo-03");

    assert_eq!(io.reads() - before, 1, "only the edited file is read again");
    let id = format!(
        "doc:repo-03:{}",
        perf_path(3, 7).split_once("/.claude/").unwrap().1
    );
    assert_eq!(item(&update, &id).title, "Rewritten heading");
    assert_eq!(
        update.0.count,
        PERF_REPOS * PERF_DOCS,
        "the update still covers every repo"
    );
}

#[test]
fn rescan_repo_picks_up_added_and_removed_docs_in_that_repo() {
    let fx = fixture();
    let mut scanner = Scanner::new(fx.root.clone());
    scanner.scan_all();
    put(
        &fx.root,
        "gamma/.claude/bugs/open/2026-10-09-new-bug.md",
        "# New bug\n",
    );
    fs::remove_file(fx.root.join("gamma/.claude/ideas/2026-08-15-gamma-idea.md")).unwrap();

    let update = scanner.rescan_repo("gamma");

    let gamma: Vec<String> = items_of(&update, "gamma")
        .into_iter()
        .map(|i| i.id)
        .collect();
    assert_eq!(
        gamma,
        vec!["doc:gamma:bugs/open/2026-10-09-new-bug.md".to_string()]
    );
    assert_eq!(
        items_of(&update, "alpha").len(),
        8,
        "other repos stay in the update"
    );
    assert_eq!(update.0.count, 12);
}

// ── live watching (spawn_at) ─────────────────────────────────────────────────

/// The first update (the current one included) that satisfies `pred`, or `None` after `within`.
async fn try_wait_for(
    rx: &mut watch::Receiver<SourceUpdate>,
    within: Duration,
    pred: impl Fn(&SourceUpdate) -> bool,
) -> Option<SourceUpdate> {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let current = rx.borrow_and_update().clone();
        if pred(&current) {
            return Some(current);
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, rx.changed()).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => panic!("source stopped publishing"),
            Err(_) => return None,
        }
    }
}

async fn wait_for(
    rx: &mut watch::Receiver<SourceUpdate>,
    what: &str,
    pred: impl Fn(&SourceUpdate) -> bool,
) -> SourceUpdate {
    match try_wait_for(rx, LIVE_DEADLINE, pred).await {
        Some(update) => update,
        None => panic!(
            "timed out after {LIVE_DEADLINE:?} waiting for: {what}; last status {:?}",
            rx.borrow().0
        ),
    }
}

// FSEvents delivers nothing for changes made before its stream is running, and
// there is no signal to await. So "armed" is established by evidence: a probe
// doc in a repo of its own is rewritten until its appearance is published, then
// removed again (and its removal awaited). The probe repo stays, with no items.
const PROBE_REPO: &str = "zz-probe";
const PROBE_ID: &str = "doc:zz-probe:ideas/probe.md";
const PROBE_FILE: &str = "zz-probe/.claude/ideas/probe.md";
/// One arming attempt waits this long for the probe to show up; a miss rewrites it.
const ARM_ATTEMPT: Duration = Duration::from_millis(1500);
const ARM_DEADLINE: Duration = Duration::from_secs(30);

fn make_probe_repo(root: &Path) {
    fs::create_dir_all(root.join(PROBE_REPO).join(".claude/ideas")).unwrap();
}

fn write_probe(root: &Path, attempt: u32) {
    put(root, PROBE_FILE, &format!("# Probe {attempt}\n"));
}

fn has_probe(update: &SourceUpdate) -> bool {
    all_items(update).iter().any(|i| i.id == PROBE_ID)
}

/// Starts the live source and returns once file events demonstrably reach it.
async fn start_live(root: &Path) -> (watch::Receiver<SourceUpdate>, Arc<Notify>) {
    make_probe_repo(root);
    let refresh = Arc::new(Notify::new());
    let mut rx = spawn_at(root.to_path_buf(), refresh.clone());
    wait_for(&mut rx, "the first scan result", |u| {
        u.0.state != SourceState::Loading
    })
    .await;

    let deadline = Instant::now() + ARM_DEADLINE;
    let mut attempt = 0;
    loop {
        attempt += 1;
        write_probe(root, attempt);
        if try_wait_for(&mut rx, ARM_ATTEMPT, has_probe)
            .await
            .is_some()
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "file events never reached the live source"
        );
    }
    fs::remove_file(root.join(PROBE_FILE)).unwrap();
    wait_for(&mut rx, "the probe doc to disappear", |u| !has_probe(u)).await;
    (rx, refresh)
}

fn count_in(update: &SourceUpdate, repo: &str) -> usize {
    items_of(update, repo).len()
}

#[tokio::test(flavor = "multi_thread")]
async fn live_source_publishes_the_initial_scan_after_a_loading_status() {
    let fx = fixture();
    let (rx, _refresh) = start_live(&fx.root).await;

    let update = rx.borrow().clone();

    assert_eq!(update.0.state, SourceState::Fresh);
    assert_eq!(update.0.count, 12);
    assert_eq!(count_in(&update, "alpha"), 8);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_new_doc_appears() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    put(
        &fx.root,
        "beta/.claude/bugs/open/2026-10-10-fresh-bug.md",
        "# Fresh bug\n",
    );

    let update = wait_for(&mut rx, "the new doc", |u| {
        u.1.iter()
            .flat_map(|g| &g.1)
            .any(|i| i.id == "doc:beta:bugs/open/2026-10-10-fresh-bug.md")
    })
    .await;
    assert_eq!(count_in(&update, "beta"), 3);
    assert_eq!(update.0.count, 13);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_editing_a_heading_updates_the_title() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    put(
        &fx.root,
        "alpha/.claude/bugs/open/2026-10-01-login-fails.md",
        "# Login now fails with a spinner\n\n**Severity:** high\n",
    );

    let update = wait_for(&mut rx, "the new title", |u| {
        u.1.iter()
            .flat_map(|g| &g.1)
            .any(|i| i.id == ALPHA_BUG && i.title == "Login now fails with a spinner")
    })
    .await;
    assert_eq!(count_in(&update, "alpha"), 8, "an edit is not an add");
}

#[tokio::test(flavor = "multi_thread")]
async fn live_resolving_a_bug_by_moving_it_removes_it() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::create_dir_all(fx.root.join("beta/.claude/bugs/resolved")).unwrap();
    fs::rename(
        fx.root
            .join("beta/.claude/bugs/open/2026-09-20-beta-bug.md"),
        fx.root
            .join("beta/.claude/bugs/resolved/2026-09-20-beta-bug.md"),
    )
    .unwrap();

    let update = wait_for(&mut rx, "the moved bug to disappear", |u| {
        !u.1.iter().flat_map(|g| &g.1).any(|i| i.id == BETA_BUG)
    })
    .await;
    assert_eq!(count_in(&update, "beta"), 1);
    assert_eq!(update.0.count, 11);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_deleting_a_doc_removes_it() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::remove_file(
        fx.root
            .join("alpha/.claude/ideas/undated-idea_for_later.md"),
    )
    .unwrap();

    let update = wait_for(&mut rx, "the deleted doc to disappear", |u| {
        !u.1.iter().flat_map(|g| &g.1).any(|i| i.id == ALPHA_IDEA)
    })
    .await;
    assert_eq!(count_in(&update, "alpha"), 7);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_brand_new_repo_appears_as_its_own_group() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    put(
        &fx.root,
        "newrepo/.claude/bugs/open/a.md",
        "# A fresh repo bug\n",
    );

    let update = wait_for(&mut rx, "the new repo's group", |u| {
        count_in(u, "newrepo") == 1
    })
    .await;
    assert_eq!(
        items_of(&update, "newrepo")[0].id,
        "doc:newrepo:bugs/open/a.md"
    );
    assert_eq!(update.0.count, 13);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_removed_repo_disappears() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::remove_dir_all(fx.root.join("gamma")).unwrap();

    let update = wait_for(&mut rx, "the removed repo's group to go", |u| {
        count_in(u, "gamma") == 0
    })
    .await;
    assert_eq!(update.0.count, 11);
    assert_eq!(count_in(&update, "alpha"), 8);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_manual_refresh_picks_up_a_change() {
    let fx = fixture();
    let (mut rx, refresh) = start_live(&fx.root).await;

    put(
        &fx.root,
        "gamma/.claude/todos/open/2026-10-10-after-refresh.md",
        "# After refresh\n",
    );
    refresh.notify_one();

    wait_for(&mut rx, "the doc after a manual refresh", |u| {
        count_in(u, "gamma") == 2
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_claude_folder_created_in_a_repo_that_had_none_is_picked_up_without_a_refresh() {
    let fx = fixture();
    fs::create_dir_all(fx.root.join("bare/.git")).unwrap(); // a repo directory that exists but has no .claude
    let (mut rx, _refresh) = start_live(&fx.root).await;
    assert_eq!(count_in(&rx.borrow(), "bare"), 0);

    put(
        &fx.root,
        "bare/.claude/bugs/open/2026-10-10-first.md",
        "# First doc of a new .claude\n",
    );

    let update = wait_for(&mut rx, "the new .claude's doc", |u| {
        count_in(u, "bare") == 1
    })
    .await;
    assert_eq!(
        items_of(&update, "bare")[0].id,
        "doc:bare:bugs/open/2026-10-10-first.md"
    );
    assert_eq!(update.0.count, 13);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_claude_folder_removed_and_created_again_is_picked_up_without_a_refresh() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;
    fs::remove_dir_all(fx.root.join("beta/.claude")).unwrap();
    wait_for(&mut rx, "beta to disappear with its .claude", |u| {
        count_in(u, "beta") == 0
    })
    .await;

    put(
        &fx.root,
        "beta/.claude/bugs/open/2026-10-10-reborn.md",
        "# Reborn\n",
    );

    let update = wait_for(&mut rx, "beta's re-created .claude", |u| {
        count_in(u, "beta") == 1
    })
    .await;
    assert_eq!(
        items_of(&update, "beta")[0].id,
        "doc:beta:bugs/open/2026-10-10-reborn.md"
    );
}

/// What is never observable cannot be asserted directly, so this pins what an
/// observer sees: a repo whose `.claude` points out of it contributes nothing,
/// however the outside changes, and says why.
#[tokio::test(flavor = "multi_thread")]
async fn live_a_claude_symlink_that_leaves_the_repo_publishes_nothing_from_outside() {
    let fx = fixture();
    let outside = fx.root.parent().unwrap().join("outside-claude");
    put(
        &outside,
        "bugs/open/secret.md",
        "# Secret\n\nescaped-secret-marker\n",
    );
    fs::create_dir_all(fx.root.join("evil")).unwrap();
    symlink(&outside, fx.root.join("evil/.claude")).unwrap();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    let update = rx.borrow().clone();
    assert!(items_of(&update, "evil").is_empty());
    assert!(
        group_error(&update.0, "evil").is_some_and(|r| r.contains("leaves the repo")),
        "{:?}",
        update.0.group_errors
    );
    assert!(
        update.0.reason.is_some(),
        "never plain fresh: {:?}",
        update.0
    );

    // Changes outside, then a change inside the repos as a marker that events are flowing.
    put(
        &outside,
        "bugs/open/later-secret.md",
        "# Later\n\nescaped-secret-marker\n",
    );
    put(
        &fx.root,
        "beta/.claude/bugs/open/2026-10-12-sentinel.md",
        "# Sentinel\n",
    );
    let update = wait_for(&mut rx, "the sentinel doc", |u| count_in(u, "beta") == 3).await;

    assert!(items_of(&update, "evil").is_empty());
    assert!(all_items(&update)
        .iter()
        .all(|i| !i.search_text.contains("escaped-secret-marker")));
    assert!(group_error(&update.0, "evil").is_some());
}

// ── the watcher thread dying is visible ──────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn a_scan_that_panics_at_startup_ends_in_an_error_status_with_a_reason() {
    let fx = fixture();
    let io = TestFs::default();
    io.panic_on_read(true);

    let mut rx = spawn_with_fs(fx.root.clone(), Arc::new(Notify::new()), Arc::new(io));

    let update = wait_for(&mut rx, "an error status", |u| {
        u.0.state == SourceState::Error
    })
    .await;
    assert!(
        update
            .0
            .reason
            .as_deref()
            .is_some_and(|r| !r.trim().is_empty()),
        "{:?}",
        update.0
    );
    assert_eq!(update.0.count, 0);
    assert!(all_items(&update).is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rescan_that_panics_replaces_a_fresh_list_with_an_error_status() {
    let fx = fixture();
    let io = TestFs::default();
    let refresh = Arc::new(Notify::new());
    let mut rx = spawn_with_fs(fx.root.clone(), refresh.clone(), Arc::new(io.clone()));
    wait_for(&mut rx, "the first, healthy scan", |u| {
        u.0.state == SourceState::Fresh
    })
    .await;

    io.panic_on_read(true);
    put(
        &fx.root,
        "gamma/.claude/todos/open/2026-10-10-boom.md",
        "# Triggers a read\n",
    );
    refresh.notify_one();

    let update = wait_for(&mut rx, "an error status", |u| {
        u.0.state == SourceState::Error
    })
    .await;
    assert!(
        update
            .0
            .reason
            .as_deref()
            .is_some_and(|r| !r.trim().is_empty()),
        "{:?}",
        update.0
    );
}

// ── detail ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn detail_of_a_bug_returns_the_file_text_as_is_with_labelled_fields_and_a_file_link() {
    let fx = fixture();
    let on_disk = "---\nseverity: high\nfiled: 2026-10-06\n---\n\n# Detail bug\n\nBody text.\n";
    put(
        &fx.root,
        "alpha/.claude/bugs/open/2026-10-06-detail-bug.md",
        on_disk,
    );

    let detail = detail_at(&fx.root, "doc:alpha:bugs/open/2026-10-06-detail-bug.md")
        .await
        .expect("detail");

    assert_eq!(
        detail.item_id,
        "doc:alpha:bugs/open/2026-10-06-detail-bug.md"
    );
    assert_eq!(detail.title, "Detail bug");
    assert_eq!(
        detail.markdown, on_disk,
        "front matter included, nothing rewritten"
    );
    assert_eq!(field(&detail, "Type"), Some("Bug"));
    assert_eq!(field(&detail, "Repo"), Some("alpha"));
    assert!(
        field(&detail, "Filed").is_some_and(|f| f.contains("2026-10-06")),
        "{:?}",
        detail.fields
    );
    assert_eq!(field(&detail, "Severity"), Some("high"));
    assert_eq!(detail.links.len(), 1);
    let abs = fx
        .root
        .join("alpha/.claude/bugs/open/2026-10-06-detail-bug.md");
    assert!(
        detail.links[0].url.starts_with("file://"),
        "{}",
        detail.links[0].url
    );
    assert!(
        detail.links[0].url.ends_with(abs.to_str().unwrap()),
        "{}",
        detail.links[0].url
    );
}

#[tokio::test]
async fn detail_omits_severity_when_the_doc_states_none() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_NO_HEADING).await.expect("detail");

    assert_eq!(field(&detail, "Severity"), None);
    assert_eq!(field(&detail, "Type"), Some("Bug"));
    assert_eq!(detail.title, "No heading here");
}

#[tokio::test]
async fn detail_type_field_names_each_kind() {
    let fx = fixture();

    for (id, kind) in [
        (ALPHA_FEATURE, "Feature"),
        (ALPHA_IDEA, "Idea"),
        (ALPHA_TODO, "Todo"),
        (ALPHA_WIP, "WIP"),
    ] {
        let detail = detail_at(&fx.root, id)
            .await
            .unwrap_or_else(|e| panic!("{id}: {e:?}"));
        assert_eq!(field(&detail, "Type"), Some(kind), "{id}");
    }
}

#[tokio::test]
async fn detail_file_link_is_percent_encoded_for_paths_with_spaces() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_SPACE).await.expect("detail");

    let abs = fx
        .root
        .join("alpha/.claude/bugs/open/2026-10-07-has space.md");
    let encoded = abs.to_str().unwrap().replace(' ', "%20");
    assert_eq!(detail.links.len(), 1);
    assert!(detail.links[0].url.starts_with("file://"));
    assert!(
        detail.links[0].url.ends_with(&encoded),
        "{}",
        detail.links[0].url
    );
}

#[tokio::test]
async fn detail_of_a_wip_folder_shows_index_text_and_lists_the_other_files_sorted() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_WIP).await.expect("detail");

    assert_eq!(detail.title, "My topic plan");
    assert_eq!(detail.markdown, "# My topic plan\n\nPlan body.\n");
    assert_eq!(field(&detail, "Type"), Some("WIP"));
    assert_eq!(field(&detail, "Repo"), Some("alpha"));
    let dir = fx.root.join("alpha/.claude/wip/my-topic");
    assert_eq!(
        detail.files,
        vec![
            dir.join("a-data.csv").to_str().unwrap().to_string(),
            dir.join("b-notes.md").to_str().unwrap().to_string()
        ],
        "index.md is never listed and neither is a sub-directory"
    );
    assert_eq!(detail.links.len(), 1);
    assert!(detail.links[0].url.starts_with("file://"));
    assert!(
        detail.links[0].url.ends_with(dir.to_str().unwrap()),
        "{}",
        detail.links[0].url
    );
}

#[tokio::test]
async fn detail_of_a_wip_folder_without_index_has_empty_markdown_and_lists_its_files() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_WIP_NO_INDEX)
        .await
        .expect("detail");

    assert_eq!(detail.title, "no-index");
    assert_eq!(detail.markdown, "");
    let dir = fx.root.join("alpha/.claude/wip/no-index");
    assert_eq!(
        detail.files,
        vec![dir.join("notes.txt").to_str().unwrap().to_string()]
    );
    assert!(detail.links[0].url.ends_with(dir.to_str().unwrap()));
}

async fn assert_unknown(root: &Path, id: &str) {
    match detail_at(root, id).await {
        Err(e) => assert_eq!(e.code, "unknown_item", "{id}: {e:?}"),
        Ok(d) => panic!("{id} must be refused but returned {:?}", d.item_id),
    }
}

#[tokio::test]
async fn detail_of_a_deleted_doc_is_unknown_item() {
    let fx = fixture();
    assert!(detail_at(&fx.root, GAMMA_IDEA).await.is_ok());
    fs::remove_file(fx.root.join("gamma/.claude/ideas/2026-08-15-gamma-idea.md")).unwrap();

    assert_unknown(&fx.root, GAMMA_IDEA).await;
    assert_unknown(&fx.root, "doc:alpha:bugs/open/never-existed.md").await;
    assert_unknown(&fx.root, "doc:no-such-repo:bugs/open/x.md").await;
}

/// A cloned repo must not be able to list (or serve) another file's text by naming a symlink `*.md`.
#[tokio::test]
async fn symlinks_that_leave_the_claude_folder_are_neither_listed_nor_served() {
    let fx = fixture();
    let secret = fx.root.parent().unwrap().join("outside/secret.md");
    put(
        secret.parent().unwrap(),
        "secret.md",
        "# Stolen\n\nmy-private-key-material\n",
    );
    let wip_target = fx.root.parent().unwrap().join("outside/wip-target");
    put(&wip_target, "index.md", "# Stolen wip\n");
    put(&fx.root, "alpha/.claude/ideas/real.md", "# Real idea\n");
    symlink(&secret, fx.root.join("alpha/.claude/bugs/open/evil.md")).unwrap();
    symlink(
        fx.root.join("alpha/.claude/ideas/real.md"),
        fx.root.join("alpha/.claude/bugs/open/inside-link.md"),
    )
    .unwrap();
    symlink(&wip_target, fx.root.join("alpha/.claude/wip/evil-topic")).unwrap();
    symlink(
        &secret,
        fx.root.join("alpha/.claude/wip/my-topic/index-copy.md"),
    )
    .unwrap();
    // A whole doc directory that is a symlink to somewhere else.
    put(
        &fx.root.parent().unwrap().join("outside/ideas-dir"),
        "sneaky.md",
        "# Sneaky\n",
    );
    fs::remove_dir_all(fx.root.join("beta/.claude/ideas")).ok();
    symlink(
        fx.root.parent().unwrap().join("outside/ideas-dir"),
        fx.root.join("beta/.claude/ideas"),
    )
    .unwrap();

    let update = scan(&fx.root);
    let ids: BTreeSet<String> = items_of(&update, "alpha")
        .into_iter()
        .map(|i| i.id)
        .collect();

    assert!(!ids.contains("doc:alpha:bugs/open/evil.md"), "{ids:?}");
    assert!(!ids.contains("doc:alpha:wip/evil-topic"), "{ids:?}");
    assert!(
        ids.contains("doc:alpha:bugs/open/inside-link.md"),
        "a symlink within .claude is fine: {ids:?}"
    );
    assert!(all_items(&update)
        .iter()
        .all(|i| !i.search_text.contains("my-private-key-material")));
    assert!(
        items_of(&update, "beta").iter().all(|i| i.kind != "idea"),
        "a symlinked doc directory is not followed"
    );

    let served = detail_at(&fx.root, "doc:alpha:bugs/open/evil.md").await;
    assert_eq!(served.unwrap_err().code, "unknown_item");
    let wip = detail_at(&fx.root, "doc:alpha:wip/my-topic").await.unwrap();
    assert!(
        wip.files.iter().all(|f| !f.ends_with("index-copy.md")),
        "{:?}",
        wip.files
    );
}

#[tokio::test]
async fn detail_refuses_ids_that_escape_the_doc_directories() {
    let fx = fixture();
    put(
        &fx.root,
        "alpha/.claude/notes/foo.md",
        "# secret-ish note\n",
    );

    for id in [
        // A real file reached by climbing out of alpha and into beta.
        "doc:alpha:bugs/open/../../../../beta/.claude/bugs/open/2026-09-20-beta-bug.md",
        "doc:alpha:../beta/.claude/bugs/open/x.md",
        "doc:alpha:/etc/passwd",
        "doc:alpha:notes/foo.md",
        "doc:alpha:notes/decision.md",
        "doc:alpha:bugs/resolved/2026-09-01-old.md",
        "doc:alpha:TODO.md",
        "doc:../etc:bugs/open/x.md",
        "doc:alpha",
        "doc:",
    ] {
        assert_unknown(&fx.root, id).await;
    }
}

#[tokio::test]
async fn detail_refuses_ids_of_other_sources() {
    let fx = fixture();

    for id in [
        "todo:1",
        "jira:CORE-1",
        "sentry:99",
        "alpha:bugs/open/2026-10-01-login-fails.md",
        "",
    ] {
        assert_unknown(&fx.root, id).await;
    }
}

// ── truncation is visible ────────────────────────────────────────────────────

#[tokio::test]
async fn a_doc_longer_than_the_searchable_limit_says_so_on_the_item_and_in_its_detail() {
    let fx = fixture();
    let body = "searchable words, many of them. ".repeat(3_000); // ~96 KiB
    let on_disk = format!("# Long doc\n\n{body}");
    put(&fx.root, "alpha/.claude/ideas/long.md", &on_disk);
    let update = scan(&fx.root);

    assert_eq!(
        item(&update, "doc:alpha:ideas/long.md")
            .metrics
            .get("truncated"),
        Some(&1)
    );
    assert!(
        !item(&update, ALPHA_BUG).metrics.contains_key("truncated"),
        "a short doc is not flagged"
    );

    let detail = detail_at(&fx.root, "doc:alpha:ideas/long.md")
        .await
        .expect("detail");
    let search = field(&detail, "Search").expect("a Search field explains the cut");
    assert!(search.starts_with("truncated"), "{search}");
    assert_eq!(
        detail.markdown, on_disk,
        "the detail itself shows the whole doc"
    );

    let short = detail_at(&fx.root, ALPHA_BUG).await.expect("detail");
    assert_eq!(field(&short, "Search"), None);
}

#[tokio::test]
async fn a_wip_folder_with_more_than_500_files_says_it_lists_only_the_first_500() {
    let fx = fixture();
    for n in 0..520 {
        put(
            &fx.root,
            &format!("alpha/.claude/wip/big/file-{n:03}.txt"),
            "x",
        );
    }
    put(&fx.root, "alpha/.claude/wip/big/index.md", "# Big folder\n");

    let detail = detail_at(&fx.root, "doc:alpha:wip/big")
        .await
        .expect("detail");

    assert_eq!(detail.files.len(), 500);
    let notes: Vec<&str> = detail
        .fields
        .iter()
        .filter(|(k, _)| k == "Note")
        .map(|(_, v)| v.as_str())
        .collect();
    assert!(
        notes
            .iter()
            .any(|n| n.contains("showing the first 500 of 520 files")),
        "{notes:?}"
    );

    let small = detail_at(&fx.root, ALPHA_WIP).await.expect("detail");
    assert_eq!(field(&small, "Note"), None, "a short list needs no note");
}

// ── severity and priority inside code fences ─────────────────────────────────

#[test]
fn severity_and_priority_lines_inside_code_fences_are_not_read() {
    let fx = fixture();
    put(
        &fx.root,
        "gamma/.claude/ideas/fenced.md",
        "# Fenced example\n\n```markdown\n**Severity:** critical\n**Priority:** P1\n```\n",
    );
    put(
        &fx.root,
        "gamma/.claude/ideas/tilde-fenced.md",
        "# Tilde example\n\n~~~\n**Severity:** critical\n**Priority:** P1\n~~~\n",
    );
    put(&fx.root, "gamma/.claude/ideas/real-after-fence.md",
        "# Real lines after an example\n\n```\n**Severity:** critical\n**Priority:** P1\n```\n\n**Severity:** low\n**Priority:** P4\n");

    let update = scan(&fx.root);

    for id in [
        "doc:gamma:ideas/fenced.md",
        "doc:gamma:ideas/tilde-fenced.md",
    ] {
        let doc = item(&update, id);
        assert_eq!(doc.severity, None, "{id}");
        assert_eq!(doc.priority, None, "{id}");
    }
    let real = item(&update, "doc:gamma:ideas/real-after-fence.md");
    assert_eq!(real.severity.as_deref(), Some("low"));
    assert_eq!(real.priority.as_ref().map(|p| p.label.as_str()), Some("P4"));
}

// ── names containing a colon ─────────────────────────────────────────────────

#[tokio::test]
async fn ids_of_repos_and_files_with_colons_round_trip_into_detail() {
    let (_tmp, root) = temp_root();
    put(
        &root,
        "a:b/.claude/bugs/open/note:with-colon.md",
        "# Colon in the file name\n",
    );
    put(
        &root,
        "a:b/.claude/wip/topic:x/index.md",
        "# Colon in the folder name\n",
    );
    put(
        &root,
        "x:ideas/.claude/ideas/y.md",
        "# Repo name that looks like a doc directory\n",
    );
    put(
        &root,
        "x:wip/.claude/todos/open/z.md",
        "# Repo name ending in wip\n",
    );
    let update = scan(&root);

    let expected: BTreeSet<&str> = [
        "doc:a:b:bugs/open/note:with-colon.md",
        "doc:a:b:wip/topic:x",
        "doc:x:ideas:ideas/y.md",
        "doc:x:wip:todos/open/z.md",
    ]
    .into_iter()
    .collect();
    let ids: BTreeSet<&str> = all_items(&update).iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, expected);

    for scanned in all_items(&update) {
        let detail = detail_at(&root, &scanned.id)
            .await
            .unwrap_or_else(|e| panic!("{}: {e:?}", scanned.id));
        assert_eq!(detail.item_id, scanned.id);
        assert_eq!(detail.title, scanned.title, "{}", scanned.id);
        assert_eq!(
            field(&detail, "Repo"),
            scanned.repo.as_deref(),
            "{}",
            scanned.id
        );
    }
}

// ── `.claude` itself is a symlink ────────────────────────────────────────────

const SECRET: &str = "escaped-secret-marker";

/// A repo `evil` whose `.claude` points somewhere that is not inside it, and
/// docs at that somewhere which must never be read.
struct Escape {
    how: &'static str,
    /// What the symlink points at, as written.
    target: PathBuf,
    /// The directory the symlink resolves to (it holds `bugs/open/secret.md` and `wip/stolen/index.md`).
    resolves_to: PathBuf,
}

fn escapes(root: &Path) -> Vec<Escape> {
    let tmp = root.parent().unwrap();
    vec![
        Escape {
            how: ".claude -> ..",
            target: "..".into(),
            resolves_to: root.to_path_buf(),
        },
        Escape {
            how: ".claude -> ../..",
            target: "../..".into(),
            resolves_to: tmp.to_path_buf(),
        },
        Escape {
            how: ".claude -> an absolute path outside",
            target: tmp.join("outside-claude"),
            resolves_to: tmp.join("outside-claude"),
        },
        Escape {
            how: ".claude -> .",
            target: ".".into(),
            resolves_to: root.join("evil"),
        },
    ]
}

fn plant_escape(root: &Path, e: &Escape) {
    put(
        &e.resolves_to,
        "bugs/open/secret.md",
        &format!("# Secret\n\n{SECRET}\n"),
    );
    put(
        &e.resolves_to,
        "wip/stolen/index.md",
        &format!("# Stolen\n\n{SECRET}\n"),
    );
    fs::create_dir_all(root.join("evil")).unwrap();
    symlink(&e.target, root.join("evil/.claude")).unwrap();
}

#[tokio::test]
async fn a_claude_symlink_that_leaves_the_repo_contributes_nothing_and_is_reported() {
    for how in 0..4 {
        let fx = fixture();
        let escape = escapes(&fx.root).swap_remove(how);
        plant_escape(&fx.root, &escape);
        let label = escape.how;
        let mut scanner = Scanner::new(fx.root.clone());

        let update = scanner.scan_all();

        let (status, _) = &update;
        assert!(items_of(&update, "evil").is_empty(), "{label}");
        assert!(
            all_items(&update)
                .iter()
                .all(|i| !i.search_text.contains(SECRET) && !i.id.contains("secret")),
            "{label}"
        );
        assert_eq!(status.count, 12, "{label}: the real repos are unaffected");
        let reason = group_error(status, "evil")
            .unwrap_or_else(|| panic!("{label}: no group error {:?}", status.group_errors));
        assert!(reason.contains("leaves the repo"), "{label}: {reason}");
        assert!(
            status.reason.is_some(),
            "{label}: never plain fresh: {status:?}"
        );
        assert_eq!(
            status.state,
            SourceState::Fresh,
            "{label}: the other repos are fine"
        );

        // Rescanning that one repo says the same.
        let again = scanner.rescan_repo("evil");
        assert!(items_of(&again, "evil").is_empty(), "{label}");
        assert!(group_error(&again.0, "evil").is_some(), "{label}");

        for id in ["doc:evil:bugs/open/secret.md", "doc:evil:wip/stolen"] {
            match detail_at(&fx.root, id).await {
                Err(e) => assert_eq!(e.code, "unknown_item", "{label}: {id}"),
                Ok(d) => panic!("{label}: {id} was served: {:?}", d.markdown),
            }
        }
    }
}

#[test]
fn a_root_whose_only_repo_escapes_through_its_claude_symlink_is_in_error() {
    let (_tmp, root) = temp_root();
    let escape = escapes(&root).swap_remove(0);
    plant_escape(&root, &escape);

    let (status, groups) = scan(&root);

    assert_eq!(status.state, SourceState::Error);
    assert_eq!(status.count, 0);
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

#[tokio::test]
async fn a_claude_symlink_that_stays_inside_the_repo_works_like_a_folder() {
    let (_tmp, root) = temp_root();
    put(
        &root,
        "dot/config/claude-docs/bugs/open/real.md",
        "# Real bug\n",
    );
    symlink("config/claude-docs", root.join("dot/.claude")).unwrap();

    let update = scan(&root);

    assert_eq!(update.0.state, SourceState::Fresh);
    assert_eq!(update.0.reason, None);
    assert!(
        update.0.group_errors.is_empty(),
        "{:?}",
        update.0.group_errors
    );
    assert_eq!(items_of(&update, "dot").len(), 1);
    let detail = detail_at(&root, "doc:dot:bugs/open/real.md")
        .await
        .expect("detail");
    assert_eq!(detail.title, "Real bug");
}

// ── `complete`: true only when the list is known to be whole ─────────────────

#[test]
fn a_healthy_scan_is_complete_and_so_is_one_with_no_docs() {
    let fx = fixture();
    let (status, _) = scan(&fx.root);
    assert_eq!(status.state, SourceState::Fresh);
    assert!(status.complete, "{status:?}");

    let (_tmp, root) = temp_root();
    fs::create_dir_all(root.join("alpha/.claude/bugs/open")).unwrap();
    let (status, _) = scan(&root);
    assert_eq!(status.state, SourceState::Empty);
    assert!(status.complete, "{status:?}");
}

#[test]
fn a_partial_scan_is_still_fresh_but_not_complete() {
    // An unreadable doc, an unexaminable doc, an unsearchable repo folder and a repo whose
    // `.claude` leaves the repo: each leaves something out, so absence from the list means nothing.
    for what in [
        "unreadable doc",
        "unexaminable doc",
        "unsearchable repo",
        "escaping .claude",
    ] {
        let fx = fixture();
        let io = TestFs::default();
        match what {
            "unreadable doc" => io.deny_read(
                fx.root
                    .join("alpha/.claude/bugs/open/2026-10-01-login-fails.md"),
            ),
            "unexaminable doc" => {
                io.deny_metadata(fx.root.join("beta/.claude/todos/open/beta-todo.md"))
            }
            "unsearchable repo" => {
                put(&fx.root, "delta/.claude/bugs/open/x.md", "# Delta bug\n");
                io.deny_symlink_metadata(fx.root.join("delta/.claude"));
            }
            _ => plant_escape(&fx.root, &escapes(&fx.root).swap_remove(0)),
        }

        let (status, _) = scanner_over(&fx.root, &io).scan_all();

        assert_eq!(
            status.state,
            SourceState::Fresh,
            "{what}: the readable repos keep the list fresh: {status:?}"
        );
        assert!(
            status.reason.is_some() && !status.group_errors.is_empty(),
            "{what}: {status:?}"
        );
        assert!(!status.complete, "{what}: {status:?}");
    }
}

#[test]
fn a_scan_that_becomes_clean_is_complete_again() {
    let fx = fixture();
    let io = TestFs::default();
    let unreadable = fx
        .root
        .join("alpha/.claude/bugs/open/2026-10-01-login-fails.md");
    io.deny_read(&unreadable);
    let mut scanner = scanner_over(&fx.root, &io);
    assert!(!scanner.scan_all().0.complete);

    io.allow_read(&unreadable);
    let (status, _) = scanner.rescan_repo("alpha");

    assert!(status.complete, "{status:?}");
    assert_eq!(status.reason, None);
}

#[test]
fn an_errored_or_missing_root_is_not_complete() {
    let (_tmp, root) = temp_root();
    put(&root, "delta/.claude/bugs/open/x.md", "# Unreachable\n");
    let io = TestFs::default();
    io.deny_symlink_metadata(root.join("delta/.claude"));
    let (status, _) = scanner_over(&root, &io).scan_all();
    assert_eq!(status.state, SourceState::Error);
    assert!(!status.complete);

    let tmp = tempfile::tempdir().unwrap();
    let (status, _) = Scanner::new(tmp.path().join("no-such-dir")).scan_all();
    assert_eq!(status.state, SourceState::NotConfigured);
    assert!(!status.complete);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_live_source_loading_status_is_not_complete() {
    let (_tmp, root) = temp_root();
    let rx = spawn_at(root, Arc::new(Notify::new()));
    let first = rx.borrow().clone();
    // The channel starts at `loading`: until a scan has finished nothing is known.
    if first.0.state == SourceState::Loading {
        assert!(!first.0.complete);
    }
}

// ── the live-updates note ────────────────────────────────────────────────────

/// Reads through the real file system, and the first time `trigger` is read runs `hook`.
struct HookFs {
    trigger: PathBuf,
    hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

impl DocFs for HookFs {
    fn read_text(&self, path: &Path, limit: u64) -> io::Result<String> {
        if path == self.trigger {
            if let Some(hook) = self.hook.lock().unwrap().take() {
                hook();
            }
        }
        RealFs.read_text(path, limit)
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn live_updates_unavailable_is_published_without_a_doc_changing_and_is_withdrawn_when_the_watch_recovers(
) {
    let (_tmp, root) = temp_root();
    put(&root, "alpha/.claude/ideas/2026-10-01-one.md", "# One\n");
    put(&root, "beta/.claude/ideas/two.md", "# Two\n");
    let one_mtime = fs::metadata(root.join("alpha/.claude/ideas/2026-10-01-one.md"))
        .unwrap()
        .modified()
        .unwrap();
    // While the scan reads beta (after alpha), alpha's `.claude` disappears: the watcher is then
    // asked to watch a folder that is not there and cannot keep the list live. The list scanned
    // before that (both docs) is what is published.
    let alpha_claude = root.join("alpha/.claude");
    let io = Arc::new(HookFs {
        trigger: root.join("beta/.claude/ideas/two.md"),
        hook: Mutex::new(Some(Box::new(move || {
            fs::remove_dir_all(alpha_claude).unwrap()
        }))),
    });
    let mut rx = spawn_with_fs(root.clone(), Arc::new(Notify::new()), io);

    let first = wait_for(&mut rx, "the first scan result", |u| {
        u.0.state != SourceState::Loading
    })
    .await;

    assert_eq!(first.0.state, SourceState::Fresh, "{:?}", first.0);
    assert_eq!(first.0.count, 2, "{:?}", first.0);
    let reason = first.0.reason.clone().unwrap_or_default();
    assert!(
        reason.contains("Live updates unavailable"),
        "the note is on the very first status: {reason:?}"
    );
    assert!(
        first.0.group_errors.is_empty(),
        "{:?}",
        first.0.group_errors
    );
    assert!(
        first.0.complete,
        "the list was read whole; the note is about freshness, not completeness: {:?}",
        first.0
    );

    // The folder comes back with the very same doc (same text, same modification time), so nothing
    // about the list changes: only the watch can be re-established. Events for alpha (rewritten
    // until one is seen: file events can lag behind the watcher's start) make the source look
    // again, retry the watch and withdraw the note.
    put(&root, "alpha/.claude/ideas/2026-10-01-one.md", "# One\n");
    fs::File::options()
        .write(true)
        .open(root.join("alpha/.claude/ideas/2026-10-01-one.md"))
        .unwrap()
        .set_modified(one_mtime)
        .unwrap();
    let deadline = Instant::now() + ARM_DEADLINE;
    let mut attempt = 0;
    let recovered = loop {
        attempt += 1;
        put(&root, &format!("alpha/touch-{attempt}.txt"), "x");
        let seen = try_wait_for(&mut rx, ARM_ATTEMPT, |u| {
            u.0.count == 2
                && !u
                    .0
                    .reason
                    .clone()
                    .unwrap_or_default()
                    .contains("Live updates unavailable")
        })
        .await;
        if let Some(update) = seen {
            break update;
        }
        assert!(
            Instant::now() < deadline,
            "the note was never withdrawn: {:?}",
            rx.borrow().0
        );
    };
    assert_eq!(recovered.0.state, SourceState::Fresh);
    assert_eq!(recovered.0.reason, None);
    assert!(recovered.0.complete);
}

// ── hub integration ──────────────────────────────────────────────────────────

/// The hub reads (and prunes) the process-wide sent ledger, which defaults to
/// `~/.nostromo/teri/sent.json`: install a ledger in a temp dir once per test
/// process so these tests never touch the real one. (No env var is set: that is
/// process-wide and racy with parallel tests; nothing here writes elsewhere in
/// the teri dir.)
fn isolate_sent_ledger() {
    static DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        let dir =
            std::env::temp_dir().join(format!("nostromo-repo-docs-teri-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("temp teri dir");
        nostromo::data::work::sent::install_ledger(Arc::new(
            nostromo::data::work::sent::SentLedger::new(dir.join("sent.json")),
        ));
        dir
    });
}

/// The first message (already queued or arriving within `within`) that satisfies `done`.
async fn recv_within(
    brx: &mut broadcast::Receiver<ServerMsg>,
    within: Duration,
    mut done: impl FnMut(&ServerMsg) -> bool,
) -> bool {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, brx.recv()).await {
            Err(_) => return false,
            Ok(Ok(msg)) => {
                if done(&msg) {
                    return true;
                }
            }
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => {}
            Ok(Err(broadcast::error::RecvError::Closed)) => panic!("broadcast closed"),
        }
    }
}

async fn recv_until(
    brx: &mut broadcast::Receiver<ServerMsg>,
    what: &str,
    done: impl FnMut(&ServerMsg) -> bool,
) {
    assert!(
        recv_within(brx, LIVE_DEADLINE, done).await,
        "timed out after {LIVE_DEADLINE:?} waiting for: {what}"
    );
}

fn is_probe_snapshot(msg: &ServerMsg, items: usize) -> bool {
    matches!(msg, ServerMsg::WorkSnapshot { source: WorkSource::RepoDocs, group: Some(g), items: i } if g == PROBE_REPO && i.len() == items)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_publishes_repo_docs_per_repo_and_republishes_a_group_as_empty_when_it_vanishes() {
    let fx = fixture();
    make_probe_repo(&fx.root);
    let (btx, mut brx) = broadcast::channel(1024);
    let (_ttx, trx) = watch::channel(Some(TeriTodosSnapshot {
        generated_at: Some(Utc::now()),
        ..Default::default()
    }));
    isolate_sent_ledger();
    let hub = WorkHub::spawn(HubDeps {
        repo_docs_root: Some(fx.root.clone()),
        ..HubDeps::new(btx, trx)
    });
    let docs = WorkFilter {
        sources: vec![WorkSource::RepoDocs],
        ..Default::default()
    };

    // One WorkSnapshot per repo, each carrying that repo's items.
    let expected: HashMap<&str, usize> =
        [("alpha", 8), ("beta", 2), ("gamma", 1), ("link-repo", 1)]
            .into_iter()
            .collect();
    let mut latest: HashMap<String, usize> = HashMap::new();
    recv_until(&mut brx, "a snapshot per repo", |msg| {
        if let ServerMsg::WorkSnapshot {
            source: WorkSource::RepoDocs,
            group: Some(repo),
            items,
        } = msg
        {
            latest.insert(repo.clone(), items.len());
        }
        expected
            .iter()
            .all(|(repo, n)| latest.get(*repo) == Some(n))
    })
    .await;
    let deadline = Instant::now() + LIVE_DEADLINE;
    while hub.status(WorkSource::RepoDocs).state != SourceState::Fresh {
        assert!(
            Instant::now() < deadline,
            "repo docs never became fresh: {:?}",
            hub.status(WorkSource::RepoDocs)
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(hub.status(WorkSource::RepoDocs).count, 12);
    assert_eq!(hub.items(&docs).len(), 12);

    // The hub reads details under the same root it was given.
    let detail = hub
        .detail(ALPHA_BUG)
        .await
        .expect("detail under the injected root");
    assert_eq!(detail.title, "Login button does nothing");

    // File events reach the hub: rewrite a probe doc until its snapshot arrives, then remove it.
    let deadline = Instant::now() + ARM_DEADLINE;
    let mut attempt = 0;
    loop {
        attempt += 1;
        write_probe(&fx.root, attempt);
        if recv_within(&mut brx, ARM_ATTEMPT, |msg| is_probe_snapshot(msg, 1)).await {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "file events never reached the hub"
        );
    }
    fs::remove_file(fx.root.join(PROBE_FILE)).unwrap();
    recv_until(&mut brx, "the probe's group to empty", |msg| {
        is_probe_snapshot(msg, 0)
    })
    .await;
    assert_eq!(hub.items(&docs).len(), 12);

    // A repo whose only doc is deleted is published once more with no items.
    fs::remove_file(fx.root.join("gamma/.claude/ideas/2026-08-15-gamma-idea.md")).unwrap();
    recv_until(&mut brx, "an empty snapshot for gamma", |msg| {
        matches!(msg, ServerMsg::WorkSnapshot { source: WorkSource::RepoDocs, group: Some(g), items } if g == "gamma" && items.is_empty())
    })
    .await;
    assert_eq!(hub.items(&docs).len(), 11);
    assert_eq!(hub.status(WorkSource::RepoDocs).count, 11);

    // Moving a repo's docs away shrinks its group and the hub's totals.
    fs::create_dir_all(fx.root.join("beta/.claude/bugs/resolved")).unwrap();
    fs::rename(
        fx.root
            .join("beta/.claude/bugs/open/2026-09-20-beta-bug.md"),
        fx.root
            .join("beta/.claude/bugs/resolved/2026-09-20-beta-bug.md"),
    )
    .unwrap();
    recv_until(&mut brx, "a one-item snapshot for beta", |msg| {
        matches!(msg, ServerMsg::WorkSnapshot { source: WorkSource::RepoDocs, group: Some(g), items } if g == "beta" && items.len() == 1)
    })
    .await;
    assert_eq!(hub.items(&docs).len(), 10);
}

// ── a partial scan that still has items is fresh, with a note ────────────────

const PARTIAL_1_OF_1: &str = "Partial scan: 1 of 1 repos could not be fully read";

#[test]
fn one_readable_and_one_unreadable_doc_in_the_only_repo_is_fresh_with_a_partial_scan_note() {
    let (_tmp, root) = temp_root();
    put(
        &root,
        "alpha/.claude/bugs/open/2026-10-01-readable.md",
        "# Readable\n",
    );
    put(
        &root,
        "alpha/.claude/bugs/open/2026-10-02-unreadable.md",
        "# Unreadable\n",
    );
    let io = TestFs::default();
    io.deny_read(root.join("alpha/.claude/bugs/open/2026-10-02-unreadable.md"));

    let update = scanner_over(&root, &io).scan_all();

    let (status, _) = &update;
    assert_eq!(
        status.state,
        SourceState::Fresh,
        "the readable doc is shown, so this is not an error: {status:?}"
    );
    assert_eq!(status.reason.as_deref(), Some(PARTIAL_1_OF_1));
    assert_eq!(status.count, 1);
    assert!(
        group_error(status, "alpha").is_some_and(|r| r.contains("skipped 1 unreadable file")),
        "{:?}",
        status.group_errors
    );
    assert_eq!(items_of(&update, "alpha").len(), 1);
}

#[test]
fn a_repo_whose_only_doc_is_unreadable_is_still_an_error_with_nothing_to_show() {
    let (_tmp, root) = temp_root();
    put(
        &root,
        "alpha/.claude/bugs/open/2026-10-02-unreadable.md",
        "# Unreadable\n",
    );
    let io = TestFs::default();
    io.deny_read(root.join("alpha/.claude/bugs/open/2026-10-02-unreadable.md"));

    let (status, groups) = scanner_over(&root, &io).scan_all();

    assert_eq!(status.state, SourceState::Error, "{status:?}");
    assert_eq!(
        status.reason.as_deref(),
        Some("Couldn't read any repo's .claude folder")
    );
    assert_eq!(status.count, 0);
    assert_eq!(status.group_errors.len(), 1);
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

#[test]
fn every_repo_partly_unreadable_but_with_items_is_fresh_and_lists_every_group_error() {
    let (_tmp, root) = temp_root();
    let io = TestFs::default();
    for repo in ["alpha", "beta"] {
        put(
            &root,
            &format!("{repo}/.claude/bugs/open/2026-10-01-readable.md"),
            "# Readable\n",
        );
        put(
            &root,
            &format!("{repo}/.claude/bugs/open/2026-10-02-unreadable.md"),
            "# Unreadable\n",
        );
        io.deny_read(root.join(format!("{repo}/.claude/bugs/open/2026-10-02-unreadable.md")));
    }

    let (status, _) = scanner_over(&root, &io).scan_all();

    assert_eq!(status.state, SourceState::Fresh, "{status:?}");
    assert_eq!(
        status.reason.as_deref(),
        Some("Partial scan: 2 of 2 repos could not be fully read")
    );
    assert_eq!(status.count, 2);
    assert_eq!(status.group_errors.len(), 2, "{:?}", status.group_errors);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_live_source_reports_a_partly_unreadable_only_repo_as_fresh_too() {
    let (_tmp, root) = temp_root();
    put(&root, "alpha/.claude/ideas/readable.md", "# Readable\n");
    put(&root, "alpha/.claude/ideas/unreadable.md", "# Unreadable\n");
    let io = TestFs::default();
    io.deny_read(root.join("alpha/.claude/ideas/unreadable.md"));

    let mut rx = spawn_with_fs(root, Arc::new(Notify::new()), Arc::new(io));

    let update = wait_for(&mut rx, "the first scan", |u| {
        u.0.state != SourceState::Loading
    })
    .await;
    assert_eq!(update.0.state, SourceState::Fresh, "{:?}", update.0);
    assert!(
        update
            .0
            .reason
            .as_deref()
            .is_some_and(|r| r.starts_with(PARTIAL_1_OF_1)),
        "{:?}",
        update.0.reason
    );
    assert_eq!(update.0.count, 1);
}

// ── titles are one short line, however the doc writes them ───────────────────

fn assert_one_short_line(title: &str) {
    assert!(
        title.chars().count() <= 200,
        "a title is at most 200 characters, this has {}",
        title.chars().count()
    );
    assert!(
        !title.contains(['\n', '\r']),
        "a title is a single line: {title:?}"
    );
}

#[test]
fn a_multi_megabyte_heading_becomes_a_title_of_at_most_200_characters() {
    let (_tmp, root) = temp_root();
    // ~3 MiB on one line: under the 4 MiB read cap, so the whole line is read.
    put(
        &root,
        "alpha/.claude/bugs/open/huge-heading.md",
        &format!("# {}\n\nBody.\n", "A".repeat(3 * 1024 * 1024)),
    );

    let update = scan(&root);

    let title = &item(&update, "doc:alpha:bugs/open/huge-heading.md").title;
    assert_one_short_line(title);
    assert!(
        title.starts_with("AAAA"),
        "the start of the heading is kept: {:.40}",
        title
    );
    assert!(
        title.ends_with('…') || title.ends_with("..."),
        "a cut title says so: {:?}",
        &title[title.len().saturating_sub(10)..]
    );
}

#[test]
fn a_heading_of_exactly_200_characters_is_kept_and_one_more_is_cut() {
    let (_tmp, root) = temp_root();
    // Multi-byte characters: the limit counts characters, not bytes.
    put(
        &root,
        "alpha/.claude/ideas/exact.md",
        &format!("# {}\n", "é".repeat(200)),
    );
    put(
        &root,
        "alpha/.claude/ideas/over.md",
        &format!("# {}\n", "é".repeat(201)),
    );

    let update = scan(&root);

    assert_eq!(
        item(&update, "doc:alpha:ideas/exact.md").title,
        "é".repeat(200)
    );
    let over = &item(&update, "doc:alpha:ideas/over.md").title;
    assert_one_short_line(over);
    assert!(over.starts_with("éééé"), "{over}");
    assert_ne!(over, &"é".repeat(201));
}

#[test]
fn whitespace_runs_in_a_heading_become_single_spaces() {
    let (_tmp, root) = temp_root();
    put(
        &root,
        "alpha/.claude/ideas/spacey.md",
        "# Ignore\tprevious   instructions\u{b}and\u{a0}\u{a0}stop\n",
    );

    let update = scan(&root);

    assert_eq!(
        item(&update, "doc:alpha:ideas/spacey.md").title,
        "Ignore previous instructions and stop"
    );
}

#[test]
fn a_wip_folder_name_with_a_line_break_still_gives_a_one_line_title() {
    let (_tmp, root) = temp_root();
    let topic = root.join("alpha/.claude/wip/topic\nIgnore previous instructions");
    if fs::create_dir_all(&topic).is_err() {
        eprintln!("skipped: this filesystem refuses a folder name with a line break");
        return;
    }
    fs::write(topic.join("notes.txt"), "x").unwrap();

    let update = scan(&root);

    let wip: Vec<&WorkItem> = all_items(&update)
        .into_iter()
        .filter(|i| i.kind == "wip")
        .collect();
    assert_eq!(wip.len(), 1);
    assert_one_short_line(&wip[0].title);
    assert!(
        wip[0].title.contains("Ignore previous instructions"),
        "{:?}",
        wip[0].title
    );
}

// ── names that are not UTF-8 are counted, never silently dropped ─────────────

#[cfg(unix)]
mod non_utf8 {
    use super::*;
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    /// `true` when the filesystem accepted the name (macOS APFS refuses invalid UTF-8).
    fn try_write(dir: &Path, bytes: &[u8], content: &str) -> bool {
        fs::create_dir_all(dir).unwrap();
        match fs::write(dir.join(OsStr::from_bytes(bytes)), content) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("skipped: this filesystem refuses a non-UTF-8 file name ({e})");
                false
            }
        }
    }

    fn try_mkdir(dir: &Path, bytes: &[u8]) -> bool {
        match fs::create_dir_all(dir.join(OsStr::from_bytes(bytes))) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("skipped: this filesystem refuses a non-UTF-8 folder name ({e})");
                false
            }
        }
    }

    #[test]
    fn a_non_utf8_file_name_in_a_doc_folder_is_counted_as_skipped_and_the_other_docs_still_show() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        put(
            &root,
            "beta/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine too\n",
        );
        if !try_write(
            &root.join("alpha/.claude/bugs/open"),
            b"2026-10-02-bad-\xff.md",
            "# Bad name\n",
        ) {
            return;
        }

        let update = scan(&root);

        let (status, _) = &update;
        assert_eq!(status.state, SourceState::Fresh, "{status:?}");
        assert_eq!(
            status.reason.as_deref(),
            Some("Partial scan: 1 of 2 repos could not be fully read")
        );
        assert!(
            group_error(status, "alpha").is_some_and(|r| r.contains("skipped 1 unreadable file")),
            "{:?}",
            status.group_errors
        );
        assert_eq!(
            items_of(&update, "alpha").len(),
            1,
            "the readable doc still shows"
        );
        assert_eq!(items_of(&update, "beta").len(), 1);
        assert_eq!(status.count, 2);
    }

    #[test]
    fn a_non_utf8_wip_folder_name_is_counted_as_skipped() {
        let (_tmp, root) = temp_root();
        put(&root, "alpha/.claude/ideas/fine.md", "# Fine\n");
        put(&root, "beta/.claude/ideas/fine.md", "# Fine too\n");
        if !try_mkdir(&root.join("alpha/.claude/wip"), b"topic-\xff") {
            return;
        }

        let (status, _) = scan(&root);

        assert_eq!(status.state, SourceState::Fresh, "{status:?}");
        assert!(
            group_error(&status, "alpha").is_some_and(|r| r.contains("skipped 1 unreadable file")),
            "{:?}",
            status.group_errors
        );
    }

    #[test]
    fn one_non_utf8_folder_in_the_code_root_is_not_a_repo_and_is_said_so_in_the_status() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        if !try_mkdir(&root, b"not-utf8-\xff") {
            return;
        }

        let (status, groups) = scan(&root);

        assert_eq!(
            status.state,
            SourceState::Fresh,
            "the readable repo is still shown: {status:?}"
        );
        assert_eq!(status.count, 1);
        assert!(
            groups.iter().all(|(g, _)| g.as_deref() == Some("alpha")),
            "the odd folder is not a repo"
        );
        let reason = status.reason.as_deref().unwrap_or_default();
        assert!(
            reason.contains("1 folder in the code root has a non-UTF-8 name and was skipped"),
            "{reason:?}"
        );
        assert!(
            status.group_errors.is_empty(),
            "it is not a repo, so not a group error: {:?}",
            status.group_errors
        );
    }

    #[test]
    fn several_non_utf8_folders_in_the_code_root_are_counted_in_the_plural() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        if !try_mkdir(&root, b"not-utf8-\xff") || !try_mkdir(&root, b"also-\xfe-bad") {
            return;
        }

        let (status, _) = scan(&root);

        let reason = status.reason.as_deref().unwrap_or_default();
        assert!(
            reason.contains("2 folders in the code root have non-UTF-8 names and were skipped"),
            "{reason:?}"
        );
    }

    #[test]
    fn a_non_utf8_plain_file_in_the_code_root_is_no_folder_and_is_not_counted() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        if !try_write(&root, b"stray-\xff.txt", "not a repo") {
            return;
        }

        let (status, _) = scan(&root);

        assert_eq!(status.state, SourceState::Fresh, "{status:?}");
        assert_eq!(
            status.reason, None,
            "a file is not a skipped folder: {:?}",
            status.reason
        );
        assert!(status.complete, "{status:?}");
    }

    #[test]
    fn a_non_utf8_folder_in_the_code_root_makes_the_list_incomplete() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        if !try_mkdir(&root, b"not-utf8-\xff") {
            return;
        }

        let (status, _) = scan(&root);

        assert_eq!(status.state, SourceState::Fresh);
        assert!(status.reason.is_some(), "{status:?}");
        assert!(
            !status.complete,
            "a repo that could not be named may be the one missing: {status:?}"
        );
    }

    #[test]
    fn a_non_utf8_file_that_was_never_a_doc_is_not_an_unreadable_file_but_a_non_utf8_markdown_file_is(
    ) {
        // `.txt`, no extension, a hidden name: never docs, so never counted.
        for (name, counted) in [
            (&b"notes-\xff.txt"[..], false),
            (&b"notes-\xff"[..], false),
            (&b".hidden-\xff"[..], false),
            (&b"notes-\xff.md"[..], true),
            (&b"NOTES-\xff.MD"[..], true),
        ] {
            let (_tmp, root) = temp_root();
            put(
                &root,
                "alpha/.claude/bugs/open/2026-10-01-fine.md",
                "# Fine\n",
            );
            if !try_write(&root.join("alpha/.claude/bugs/open"), name, "x") {
                return;
            }

            let (status, _) = scan(&root);

            let label = String::from_utf8_lossy(name).into_owned();
            assert_eq!(status.state, SourceState::Fresh, "{label}: {status:?}");
            if counted {
                assert!(
                    group_error(&status, "alpha")
                        .is_some_and(|r| r.contains("skipped 1 unreadable file")),
                    "{label}: {:?}",
                    status.group_errors
                );
                assert!(!status.complete, "{label}");
            } else {
                assert!(
                    status.group_errors.is_empty(),
                    "{label}: it was never a doc: {:?}",
                    status.group_errors
                );
                assert_eq!(status.reason, None, "{label}");
                assert!(status.complete, "{label}");
            }
        }
    }

    #[test]
    fn a_non_utf8_plain_file_in_the_claude_folder_itself_is_not_counted() {
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        if !try_write(&root.join("alpha/.claude"), b"scratch-\xff.txt", "x") {
            return;
        }

        let (status, _) = scan(&root);

        assert!(status.group_errors.is_empty(), "{:?}", status.group_errors);
        assert!(status.complete, "{status:?}");
    }

    #[test]
    fn a_count_of_skipped_root_folders_is_forgotten_when_the_root_cannot_be_read_and_recovery_does_not_bring_it_back(
    ) {
        use std::os::unix::fs::PermissionsExt;
        let (_tmp, root) = temp_root();
        put(
            &root,
            "alpha/.claude/bugs/open/2026-10-01-fine.md",
            "# Fine\n",
        );
        let odd = root.join(OsStr::from_bytes(b"not-utf8-\xff"));
        if !try_mkdir(&root, b"not-utf8-\xff") {
            return;
        }
        let mut scanner = Scanner::new(root.clone());
        let (status, _) = scanner.scan_all();
        assert!(
            status
                .reason
                .as_deref()
                .unwrap_or_default()
                .contains("non-UTF-8"),
            "{status:?}"
        );

        // The root cannot be read now.
        fs::set_permissions(&root, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&root).is_ok() {
            fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
            eprintln!("skipped: this user can read a folder without permission (running as root?)");
            return;
        }
        let (status, _) = scanner.scan_all();
        assert_eq!(status.state, SourceState::Error, "{status:?}");
        assert!(!status.complete);

        // It can be read again, and the odd folder is gone: nothing of the old count may remain.
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        fs::remove_dir(&odd).unwrap();
        let (status, _) = scanner.scan_all();

        assert_eq!(status.state, SourceState::Fresh, "{status:?}");
        assert_eq!(
            status.reason, None,
            "no resurrected note: {:?}",
            status.reason
        );
        assert!(status.complete, "{status:?}");
    }

    #[test]
    fn a_root_with_only_a_non_utf8_folder_is_empty_and_says_why() {
        let (_tmp, root) = temp_root();
        if !try_mkdir(&root, b"not-utf8-\xff") {
            return;
        }

        let (status, _) = scan(&root);

        assert_eq!(status.state, SourceState::Empty, "{status:?}");
        assert!(
            status
                .reason
                .as_deref()
                .unwrap_or_default()
                .contains("non-UTF-8"),
            "{:?}",
            status.reason
        );
    }
}

// ── the live watcher recovers from a root that did not exist at start ────────

#[tokio::test(flavor = "multi_thread")]
async fn live_a_code_root_created_after_start_is_watched_after_a_refresh_without_a_live_updates_note(
) {
    let tmp = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(tmp.path()).unwrap().join("code"); // not created yet
    let refresh = Arc::new(Notify::new());
    let mut rx = spawn_at(root.clone(), refresh.clone());
    let first = wait_for(&mut rx, "the first status", |u| {
        u.0.state != SourceState::Loading
    })
    .await;
    assert_eq!(first.0.state, SourceState::NotConfigured, "{:?}", first.0);

    put(&root, "alpha/.claude/ideas/one.md", "# One\n");
    refresh.notify_one();

    let update = wait_for(&mut rx, "the doc after a refresh", |u| u.0.count == 1).await;
    assert_eq!(update.0.state, SourceState::Fresh, "{:?}", update.0);
    let reason = update.0.reason.clone().unwrap_or_default();
    assert!(
        !reason.contains("Live updates unavailable"),
        "the root exists now, so the failed watch on it must have been retried: {reason:?}"
    );

    // Changes now arrive without another refresh. FSEvents may take a moment to be
    // running, so (as in `start_live`) the change is rewritten until it is seen.
    let deadline = Instant::now() + ARM_DEADLINE;
    let mut attempt = 0;
    let update = loop {
        attempt += 1;
        put(
            &root,
            "alpha/.claude/ideas/two.md",
            &format!("# Two {attempt}\n"),
        );
        if let Some(update) = try_wait_for(&mut rx, ARM_ATTEMPT, |u| u.0.count == 2).await {
            break update;
        }
        assert!(
            Instant::now() < deadline,
            "file events never reached the source after its root appeared"
        );
    };
    assert!(
        !update
            .0
            .reason
            .clone()
            .unwrap_or_default()
            .contains("Live updates unavailable"),
        "{:?}",
        update.0.reason
    );
}
