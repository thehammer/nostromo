//! Teri "Repo docs" source (T1): scans `<root>/<repo>/.claude/` doc-mgr layouts
//! and publishes them as work items. These tests pin the observable contract:
//! what is (and is not) an item, how titles / dates / severity / priority are
//! read, how failures are reported, how fast scans are, how the live watcher
//! reacts, what the detail view returns and how the hub republishes it.
//!
//! Every root is a canonicalised temp dir (macOS temp lives under /var, a
//! symlink to /private/var) so path comparisons are exact.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, TimeZone, Utc};
use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::data::work::hub::{HubDeps, SourceUpdate, WorkHub};
use nostromo::data::work::query::WorkFilter;
use nostromo::data::work::repo_docs::{detail_at, spawn_at, Scanner};
use nostromo::data::work::{SourceState, WorkDetail, WorkItem, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use tempfile::TempDir;
use tokio::sync::{broadcast, watch, Notify};

const LIVE_DEADLINE: Duration = Duration::from_secs(10);

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
    put(&root, "alpha/.claude/bugs/open/2026-10-02-no-heading-here.md", "Nothing states a title, a severity or a priority.\n");
    put(&root, "alpha/.claude/bugs/open/2026-10-07-has space.md", "Spaces in file names must survive.\n");
    put(&root, "alpha/.claude/bugs/open/screenshot.png", "not markdown");
    put(&root, "alpha/.claude/bugs/resolved/2026-09-01-old.md", "# Resolved\n");
    put(&root, "alpha/.claude/features/backlog/dark-mode.md",
        "---\nseverity: medium\npriority: P2\ndate: 2026-09-15\n---\n\n# Dark mode support\n\nUsers want a dark theme.\n");
    put(&root, "alpha/.claude/features/shipped/2026-08-01-shipped.md", "# Shipped\n");
    put(&root, "alpha/.claude/ideas/undated-idea_for_later.md", "Maybe someday.\n");
    put(&root, "alpha/.claude/todos/open/2026-10-04-write-docs.md", "# Write the docs\n\n**Priority:** urgent\n");
    put(&root, "alpha/.claude/todos/done/2026-09-30-done.md", "# Done\n");
    put(&root, "alpha/.claude/wip/my-topic/index.md", "# My topic plan\n\nPlan body.\n");
    put(&root, "alpha/.claude/wip/my-topic/b-notes.md", "notes\n");
    put(&root, "alpha/.claude/wip/my-topic/a-data.csv", "a,b\n");
    put(&root, "alpha/.claude/wip/my-topic/sketches/s.png", "png");
    put(&root, "alpha/.claude/wip/no-index/notes.txt", "just notes\n");
    put(&root, "alpha/.claude/notes/decision.md", "# A decision\n");
    put(&root, "alpha/.claude/bug-reports/legacy.md", "# Legacy bug\n");
    put(&root, "alpha/.claude/feature-requests/legacy.md", "# Legacy feature\n");
    put(&root, "alpha/.claude/TODO.md", "# Legacy todo\n");

    put(&root, "beta/.claude/bugs/open/2026-09-20-beta-bug.md",
        "# Beta bug\n\n**SEVERITY:** critical\n**Priority:** P1\n");
    put(&root, "beta/.claude/todos/open/beta-todo.md", "Just a plain todo.\n");
    put(&root, "gamma/.claude/ideas/2026-08-15-gamma-idea.md", "A gamma idea.\n");

    // Symlinked repo dir whose real location is outside the root: included once.
    let outside = root.parent().unwrap().join("outside/linked-src");
    put(&outside, ".claude/bugs/open/linked-bug.md", "---\nfiled: 2026-07-04\n---\nSomething broke in the linked repo.\n");
    symlink(&outside, root.join("link-repo")).unwrap();

    // Ignored children.
    put(&root, ".hidden/.claude/bugs/open/x.md", "# Hidden\n");
    put(&root, "alpha-wt/.git", "gitdir: /somewhere/else/.git/worktrees/alpha-wt\n"); // worktree: .git is a file
    put(&root, "alpha-wt/.claude/bugs/open/x.md", "# Worktree copy\n");
    put(&root, "nodocs/README.md", "no .claude here\n");
    fs::write(root.join("README.md"), "a plain file in the root\n").unwrap();

    Fx { _tmp: tmp, root }
}

/// `chmod 000` on a repo's `.claude`, restored on drop so the temp dir can be removed.
struct Locked(PathBuf);

impl Drop for Locked {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
    }
}

/// Adds an unreadable repo. `None` when the permission has no effect (running as root).
fn lock_repo(root: &Path, repo: &str) -> Option<Locked> {
    put(root, &format!("{repo}/.claude/bugs/open/x.md"), "# Unreachable\n");
    let claude = root.join(repo).join(".claude");
    let guard = Locked(claude.clone());
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o000)).unwrap();
    if fs::read_dir(&claude).is_ok() {
        return None;
    }
    Some(guard)
}

fn scan(root: &Path) -> SourceUpdate {
    Scanner::new(root.to_path_buf()).scan_all()
}

fn items_of(update: &SourceUpdate, repo: &str) -> Vec<WorkItem> {
    update.1.iter().filter(|(g, _)| g.as_deref() == Some(repo)).flat_map(|(_, items)| items.clone()).collect()
}

fn all_items(update: &SourceUpdate) -> Vec<&WorkItem> {
    update.1.iter().flat_map(|(_, items)| items.iter()).collect()
}

fn item<'a>(update: &'a SourceUpdate, id: &str) -> &'a WorkItem {
    all_items(update)
        .into_iter()
        .find(|i| i.id == id)
        .unwrap_or_else(|| panic!("no item {id}; have {:?}", all_items(update).iter().map(|i| &i.id).collect::<Vec<_>>()))
}

fn noon(y: i32, m: u32, d: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, m, d, 12, 0, 0).unwrap()
}

fn field<'a>(detail: &'a WorkDetail, label: &str) -> Option<&'a str> {
    detail.fields.iter().find(|(k, _)| k == label).map(|(_, v)| v.as_str())
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
        ALPHA_BUG, ALPHA_NO_HEADING, ALPHA_SPACE, ALPHA_FEATURE, ALPHA_IDEA, ALPHA_TODO, ALPHA_WIP,
        ALPHA_WIP_NO_INDEX, BETA_BUG, BETA_TODO, GAMMA_IDEA, LINKED_BUG,
    ]
    .into_iter()
    .collect();
    assert_eq!(ids, expected, "resolved/shipped/done/notes/legacy/hidden/worktree/non-md are never items");
    assert_eq!(all_items(&update).len(), 12, "no item appears twice (symlinked repo counted once)");
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
        let repo = group.as_deref().expect("repo docs groups are keyed by repo");
        assert!(!["alpha-wt", ".hidden", "nodocs"].contains(&repo), "{repo} must not be a group with items: {}", items.len());
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
    assert_eq!(item(&update, ALPHA_WIP_NO_INDEX).kind, "wip", "a wip folder without index.md is still an item");
}

#[test]
fn item_path_is_the_absolute_file_or_the_wip_directory() {
    let fx = fixture();

    let update = scan(&fx.root);

    let bug = item(&update, ALPHA_BUG);
    assert_eq!(bug.path.as_deref(), Some(fx.root.join("alpha/.claude/bugs/open/2026-10-01-login-fails.md").to_str().unwrap()));
    let wip = item(&update, ALPHA_WIP);
    assert_eq!(wip.path.as_deref(), Some(fx.root.join("alpha/.claude/wip/my-topic").to_str().unwrap()));
    let linked = item(&update, LINKED_BUG);
    assert!(linked.path.as_deref().unwrap().ends_with("/.claude/bugs/open/linked-bug.md"));
}

// ── titles ───────────────────────────────────────────────────────────────────

#[test]
fn title_is_the_first_heading_even_after_front_matter() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(item(&update, ALPHA_BUG).title, "Login button does nothing");
    assert_eq!(item(&update, ALPHA_FEATURE).title, "Dark mode support");
    assert_eq!(item(&update, ALPHA_TODO).title, "Write the docs");
    assert_eq!(item(&update, ALPHA_WIP).title, "My topic plan", "a wip item is titled by its index.md heading");
}

#[test]
fn title_without_a_heading_is_the_humanised_file_name() {
    let fx = fixture();

    let update = scan(&fx.root);

    assert_eq!(item(&update, ALPHA_NO_HEADING).title, "No heading here", "date prefix stripped, dashes to spaces, capitalised");
    assert_eq!(item(&update, ALPHA_SPACE).title, "Has space");
    assert_eq!(item(&update, ALPHA_IDEA).title, "Undated idea for later", "underscores become spaces too");
    assert_eq!(item(&update, BETA_TODO).title, "Beta todo");
    assert_eq!(item(&update, GAMMA_IDEA).title, "Gamma idea");
    assert_eq!(item(&update, LINKED_BUG).title, "Linked bug", "front matter alone is not a title");
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

    assert_eq!(item(&update, ALPHA_BUG).severity.as_deref(), Some("high"), "**Severity:** body line");
    assert_eq!(item(&update, ALPHA_FEATURE).severity.as_deref(), Some("medium"), "front matter");
    assert_eq!(item(&update, BETA_BUG).severity.as_deref(), Some("critical"), "the body line label is case-insensitive");
    assert_eq!(item(&update, ALPHA_NO_HEADING).severity, None, "a doc that states none has none");
    assert_eq!(item(&update, ALPHA_TODO).severity, None);
    assert_eq!(item(&update, ALPHA_WIP).severity, None);
}

#[test]
fn priority_p_levels_map_to_label_and_rank_and_other_words_rank_nine() {
    let fx = fixture();

    let update = scan(&fx.root);

    let p2 = item(&update, ALPHA_FEATURE).priority.clone().expect("front matter priority");
    assert_eq!((p2.label.as_str(), p2.rank), ("P2", 2));
    let p1 = item(&update, BETA_BUG).priority.clone().expect("**Priority:** body line");
    assert_eq!((p1.label.as_str(), p1.rank), ("P1", 1));
    let urgent = item(&update, ALPHA_TODO).priority.clone().expect("a non-P word is kept");
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
    assert_eq!(item(&update, GAMMA_IDEA).created_at, Some(noon(2026, 8, 15)));
}

#[test]
fn created_at_falls_back_to_front_matter_date_or_filed() {
    let fx = fixture();

    let update = scan(&fx.root);

    let dated = item(&update, ALPHA_FEATURE);
    assert_eq!(dated.created_at, Some(noon(2026, 9, 15)), "front matter `date:`");
    assert!(!dated.metrics.contains_key("date_inferred"));
    let filed = item(&update, LINKED_BUG);
    assert_eq!(filed.created_at, Some(noon(2026, 7, 4)), "front matter `filed:`");
    assert!(!filed.metrics.contains_key("date_inferred"));
}

#[test]
fn undated_doc_uses_the_file_time_and_is_flagged_as_inferred() {
    let fx = fixture();

    let update = scan(&fx.root);

    let idea = item(&update, ALPHA_IDEA);
    assert_eq!(idea.metrics.get("date_inferred"), Some(&1));
    let created = idea.created_at.expect("an inferred date is still a date");
    assert!((Utc::now() - created).num_seconds().abs() < 300, "inferred from a file just written: {created}");
}

#[test]
fn updated_at_is_the_file_modification_time() {
    let fx = fixture();

    let update = scan(&fx.root);

    let updated = item(&update, ALPHA_BUG).updated_at.expect("updated_at");
    assert!((Utc::now() - updated).num_seconds().abs() < 300, "just written: {updated}");
}

// ── search text ──────────────────────────────────────────────────────────────

#[test]
fn search_text_is_the_title_then_the_body_so_body_only_words_are_searchable() {
    let fx = fixture();

    let update = scan(&fx.root);

    let text = &item(&update, ALPHA_BUG).search_text;
    assert!(text.starts_with("Login button does nothing\n"), "title, newline, body: {text:?}");
    assert!(text.contains("quokkaword"));
}

#[test]
fn search_text_is_capped_at_64_kib_without_splitting_a_character() {
    let fx = fixture();
    // ~240 KiB of 1-, 2- and 3-byte characters: any byte-offset cut lands mid-character somewhere.
    let body = "x\u{e9}\u{65e5}\u{672c} ".repeat(30_000);
    put(&fx.root, "alpha/.claude/ideas/huge.md", &format!("# Huge doc\n\n{body}"));

    let update = scan(&fx.root);

    let text = &item(&update, "doc:alpha:ideas/huge.md").search_text;
    assert!(text.len() <= 65_536, "search_text is {} bytes", text.len());
    assert!(text.len() >= 65_536 - 8, "the cap should not truncate far below 64 KiB ({} bytes)", text.len());
    assert!(text.starts_with("Huge doc\n"));
}

// ── source status ────────────────────────────────────────────────────────────

#[test]
fn a_healthy_scan_is_fresh_with_the_total_item_count_and_no_errors() {
    let fx = fixture();

    let (status, _) = scan(&fx.root);

    assert_eq!(status.source, WorkSource::RepoDocs);
    assert_eq!(status.state, SourceState::Fresh);
    assert_eq!(status.count, 12);
    assert!(status.group_errors.is_empty());
}

#[test]
fn an_unreadable_repo_is_reported_and_the_other_repos_are_unaffected() {
    let fx = fixture();
    let Some(_guard) = lock_repo(&fx.root, "delta") else { return }; // running as root: chmod can't deny

    let update = scan(&fx.root);

    let (status, _) = &update;
    assert_eq!(status.state, SourceState::Fresh, "only an every-repo failure is an error");
    assert_eq!(status.count, 12);
    assert_eq!(status.group_errors.len(), 1, "{:?}", status.group_errors);
    assert_eq!(status.group_errors[0].group, "delta");
    assert!(!status.group_errors[0].reason.trim().is_empty());
    assert!(items_of(&update, "delta").is_empty());
    assert_eq!(items_of(&update, "alpha").len(), 8);
    assert_eq!(items_of(&update, "beta").len(), 2);
}

#[test]
fn when_every_repo_fails_the_source_is_in_error() {
    let (_tmp, root) = temp_root();
    let Some(_guard) = lock_repo(&root, "delta") else { return };

    let (status, groups) = scan(&root);

    assert_eq!(status.state, SourceState::Error);
    assert_eq!(status.count, 0);
    assert_eq!(status.group_errors.len(), 1);
    assert!(groups.iter().all(|(_, items)| items.is_empty()));
}

#[test]
fn a_root_with_repos_but_no_docs_is_empty_not_an_error() {
    let (_tmp, root) = temp_root();
    fs::create_dir_all(root.join("alpha/.claude/bugs/open")).unwrap();
    put(&root, "alpha/.claude/bugs/resolved/2026-01-01-old.md", "# Resolved\n");
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

// ── performance and incremental rescans ──────────────────────────────────────

const PERF_REPOS: usize = 10;
const PERF_DOCS: usize = 100;

fn perf_path(repo: usize, doc: usize) -> String {
    let dir = ["bugs/open", "features/backlog", "ideas", "todos/open"][doc % 4];
    format!("repo-{repo:02}/.claude/{dir}/2026-09-{:02}-doc-{doc:03}.md", doc % 28 + 1)
}

fn perf_body(repo: usize, doc: usize) -> String {
    let line = format!("Synthetic line for repo {repo} doc {doc} describing some behaviour in prose.\n");
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
fn a_thousand_doc_tree_scans_cold_in_under_two_seconds() {
    let (_tmp, root) = perf_tree();
    let mut scanner = Scanner::new(root);

    let started = Instant::now();
    let (status, _) = scanner.scan_all();
    let took = started.elapsed();

    assert_eq!(status.count, PERF_REPOS * PERF_DOCS);
    assert!(took < Duration::from_secs(2), "cold scan took {took:?}");
}

#[test]
fn an_unchanged_tree_rescans_quickly_from_the_parse_cache() {
    let (_tmp, root) = perf_tree();
    let mut scanner = Scanner::new(root);
    scanner.scan_all();

    let started = Instant::now();
    let (status, _) = scanner.scan_all();
    let took = started.elapsed();

    assert_eq!(status.count, PERF_REPOS * PERF_DOCS);
    assert!(took < Duration::from_millis(500), "unchanged rescan took {took:?}");
}

#[test]
fn rescanning_one_repo_after_editing_one_file_is_fast_and_reflects_the_edit() {
    let (_tmp, root) = perf_tree();
    let mut scanner = Scanner::new(root.clone());
    scanner.scan_all();
    // Different content and size, so neither mtime nor length can match the cached entry.
    put(&root, &perf_path(3, 7), &format!("# Rewritten heading\n\n{}", "A much longer replacement body. ".repeat(80)));

    let started = Instant::now();
    let update = scanner.rescan_repo("repo-03");
    let took = started.elapsed();

    assert!(took < Duration::from_millis(200), "single-repo rescan took {took:?}");
    let id = format!("doc:repo-03:{}", perf_path(3, 7).split_once("/.claude/").unwrap().1);
    assert_eq!(item(&update, &id).title, "Rewritten heading");
    assert_eq!(update.0.count, PERF_REPOS * PERF_DOCS, "the update still covers every repo");
}

#[test]
fn rescan_repo_picks_up_added_and_removed_docs_in_that_repo() {
    let fx = fixture();
    let mut scanner = Scanner::new(fx.root.clone());
    scanner.scan_all();
    put(&fx.root, "gamma/.claude/bugs/open/2026-10-09-new-bug.md", "# New bug\n");
    fs::remove_file(fx.root.join("gamma/.claude/ideas/2026-08-15-gamma-idea.md")).unwrap();

    let update = scanner.rescan_repo("gamma");

    let gamma: Vec<String> = items_of(&update, "gamma").into_iter().map(|i| i.id).collect();
    assert_eq!(gamma, vec!["doc:gamma:bugs/open/2026-10-09-new-bug.md".to_string()]);
    assert_eq!(items_of(&update, "alpha").len(), 8, "other repos stay in the update");
    assert_eq!(update.0.count, 12);
}

// ── live watching (spawn_at) ─────────────────────────────────────────────────

async fn wait_for(rx: &mut watch::Receiver<SourceUpdate>, what: &str, pred: impl Fn(&SourceUpdate) -> bool) -> SourceUpdate {
    let deadline = tokio::time::Instant::now() + LIVE_DEADLINE;
    loop {
        let current = rx.borrow_and_update().clone();
        if pred(&current) {
            return current;
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, rx.changed()).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => panic!("source stopped publishing while waiting for: {what}"),
            Err(_) => panic!("timed out after {LIVE_DEADLINE:?} waiting for: {what}; last status {:?}", current.0),
        }
    }
}

/// Starts the live source and waits for its first real scan. The short sleep
/// afterwards only gives FSEvents time to arm: events for changes made before
/// the stream is running are not delivered, and there is no signal to await.
async fn start_live(root: &Path) -> (watch::Receiver<SourceUpdate>, Arc<Notify>) {
    let refresh = Arc::new(Notify::new());
    let mut rx = spawn_at(root.to_path_buf(), refresh.clone());
    wait_for(&mut rx, "the first scan result", |u| u.0.state != SourceState::Loading).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
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

    put(&fx.root, "beta/.claude/bugs/open/2026-10-10-fresh-bug.md", "# Fresh bug\n");

    let update = wait_for(&mut rx, "the new doc", |u| u.1.iter().flat_map(|g| &g.1).any(|i| i.id == "doc:beta:bugs/open/2026-10-10-fresh-bug.md")).await;
    assert_eq!(count_in(&update, "beta"), 3);
    assert_eq!(update.0.count, 13);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_editing_a_heading_updates_the_title() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    put(&fx.root, "alpha/.claude/bugs/open/2026-10-01-login-fails.md", "# Login now fails with a spinner\n\n**Severity:** high\n");

    let update = wait_for(&mut rx, "the new title", |u| u.1.iter().flat_map(|g| &g.1).any(|i| i.id == ALPHA_BUG && i.title == "Login now fails with a spinner")).await;
    assert_eq!(count_in(&update, "alpha"), 8, "an edit is not an add");
}

#[tokio::test(flavor = "multi_thread")]
async fn live_resolving_a_bug_by_moving_it_removes_it() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::create_dir_all(fx.root.join("beta/.claude/bugs/resolved")).unwrap();
    fs::rename(
        fx.root.join("beta/.claude/bugs/open/2026-09-20-beta-bug.md"),
        fx.root.join("beta/.claude/bugs/resolved/2026-09-20-beta-bug.md"),
    )
    .unwrap();

    let update = wait_for(&mut rx, "the moved bug to disappear", |u| !u.1.iter().flat_map(|g| &g.1).any(|i| i.id == BETA_BUG)).await;
    assert_eq!(count_in(&update, "beta"), 1);
    assert_eq!(update.0.count, 11);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_deleting_a_doc_removes_it() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::remove_file(fx.root.join("alpha/.claude/ideas/undated-idea_for_later.md")).unwrap();

    let update = wait_for(&mut rx, "the deleted doc to disappear", |u| !u.1.iter().flat_map(|g| &g.1).any(|i| i.id == ALPHA_IDEA)).await;
    assert_eq!(count_in(&update, "alpha"), 7);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_brand_new_repo_appears_as_its_own_group() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    put(&fx.root, "newrepo/.claude/bugs/open/a.md", "# A fresh repo bug\n");

    let update = wait_for(&mut rx, "the new repo's group", |u| count_in(u, "newrepo") == 1).await;
    assert_eq!(items_of(&update, "newrepo")[0].id, "doc:newrepo:bugs/open/a.md");
    assert_eq!(update.0.count, 13);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_a_removed_repo_disappears() {
    let fx = fixture();
    let (mut rx, _refresh) = start_live(&fx.root).await;

    fs::remove_dir_all(fx.root.join("gamma")).unwrap();

    let update = wait_for(&mut rx, "the removed repo's group to go", |u| count_in(u, "gamma") == 0).await;
    assert_eq!(update.0.count, 11);
    assert_eq!(count_in(&update, "alpha"), 8);
}

#[tokio::test(flavor = "multi_thread")]
async fn live_manual_refresh_picks_up_a_change() {
    let fx = fixture();
    let (mut rx, refresh) = start_live(&fx.root).await;

    put(&fx.root, "gamma/.claude/todos/open/2026-10-10-after-refresh.md", "# After refresh\n");
    refresh.notify_one();

    wait_for(&mut rx, "the doc after a manual refresh", |u| count_in(u, "gamma") == 2).await;
}

// ── detail ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn detail_of_a_bug_returns_the_file_text_as_is_with_labelled_fields_and_a_file_link() {
    let fx = fixture();
    let on_disk = "---\nseverity: high\nfiled: 2026-10-06\n---\n\n# Detail bug\n\nBody text.\n";
    put(&fx.root, "alpha/.claude/bugs/open/2026-10-06-detail-bug.md", on_disk);

    let detail = detail_at(&fx.root, "doc:alpha:bugs/open/2026-10-06-detail-bug.md").await.expect("detail");

    assert_eq!(detail.item_id, "doc:alpha:bugs/open/2026-10-06-detail-bug.md");
    assert_eq!(detail.title, "Detail bug");
    assert_eq!(detail.markdown, on_disk, "front matter included, nothing rewritten");
    assert_eq!(field(&detail, "Type"), Some("Bug"));
    assert_eq!(field(&detail, "Repo"), Some("alpha"));
    assert!(field(&detail, "Filed").is_some_and(|f| f.contains("2026-10-06")), "{:?}", detail.fields);
    assert_eq!(field(&detail, "Severity"), Some("high"));
    assert_eq!(detail.links.len(), 1);
    let abs = fx.root.join("alpha/.claude/bugs/open/2026-10-06-detail-bug.md");
    assert!(detail.links[0].url.starts_with("file://"), "{}", detail.links[0].url);
    assert!(detail.links[0].url.ends_with(abs.to_str().unwrap()), "{}", detail.links[0].url);
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

    for (id, kind) in [(ALPHA_FEATURE, "Feature"), (ALPHA_IDEA, "Idea"), (ALPHA_TODO, "Todo"), (ALPHA_WIP, "WIP")] {
        let detail = detail_at(&fx.root, id).await.unwrap_or_else(|e| panic!("{id}: {e:?}"));
        assert_eq!(field(&detail, "Type"), Some(kind), "{id}");
    }
}

#[tokio::test]
async fn detail_file_link_is_percent_encoded_for_paths_with_spaces() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_SPACE).await.expect("detail");

    let abs = fx.root.join("alpha/.claude/bugs/open/2026-10-07-has space.md");
    let encoded = abs.to_str().unwrap().replace(' ', "%20");
    assert_eq!(detail.links.len(), 1);
    assert!(detail.links[0].url.starts_with("file://"));
    assert!(detail.links[0].url.ends_with(&encoded), "{}", detail.links[0].url);
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
        vec![dir.join("a-data.csv").to_str().unwrap().to_string(), dir.join("b-notes.md").to_str().unwrap().to_string()],
        "index.md is never listed and neither is a sub-directory"
    );
    assert_eq!(detail.links.len(), 1);
    assert!(detail.links[0].url.starts_with("file://"));
    assert!(detail.links[0].url.ends_with(dir.to_str().unwrap()), "{}", detail.links[0].url);
}

#[tokio::test]
async fn detail_of_a_wip_folder_without_index_has_empty_markdown_and_lists_its_files() {
    let fx = fixture();

    let detail = detail_at(&fx.root, ALPHA_WIP_NO_INDEX).await.expect("detail");

    assert_eq!(detail.title, "no-index");
    assert_eq!(detail.markdown, "");
    let dir = fx.root.join("alpha/.claude/wip/no-index");
    assert_eq!(detail.files, vec![dir.join("notes.txt").to_str().unwrap().to_string()]);
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

#[tokio::test]
async fn detail_refuses_ids_that_escape_the_doc_directories() {
    let fx = fixture();
    put(&fx.root, "alpha/.claude/notes/foo.md", "# secret-ish note\n");

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

    for id in ["todo:1", "jira:CORE-1", "sentry:99", "alpha:bugs/open/2026-10-01-login-fails.md", ""] {
        assert_unknown(&fx.root, id).await;
    }
}

// ── hub integration (the only test that touches the environment) ─────────────

async fn recv_until(brx: &mut broadcast::Receiver<ServerMsg>, what: &str, mut done: impl FnMut(&ServerMsg) -> bool) {
    let deadline = tokio::time::Instant::now() + LIVE_DEADLINE;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, brx.recv()).await {
            Err(_) => panic!("timed out after {LIVE_DEADLINE:?} waiting for: {what}"),
            Ok(Ok(msg)) => {
                if done(&msg) {
                    return;
                }
            }
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => {}
            Ok(Err(broadcast::error::RecvError::Closed)) => panic!("broadcast closed waiting for: {what}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hub_publishes_repo_docs_per_repo_and_republishes_a_group_as_empty_when_it_vanishes() {
    let fx = fixture();
    // Safe here only because no other test in this binary reads or sets the variable.
    std::env::set_var("NOSTROMO_CODE_ROOT", &fx.root);
    let (btx, mut brx) = broadcast::channel(1024);
    let (_ttx, trx) = watch::channel(Some(TeriTodosSnapshot { generated_at: Some(Utc::now()), ..Default::default() }));
    let hub = WorkHub::spawn(HubDeps::new(btx, trx));
    let docs = WorkFilter { sources: vec![WorkSource::RepoDocs], ..Default::default() };

    // One WorkSnapshot per repo, each carrying that repo's items.
    let expected: HashMap<&str, usize> = [("alpha", 8), ("beta", 2), ("gamma", 1), ("link-repo", 1)].into_iter().collect();
    let mut latest: HashMap<String, usize> = HashMap::new();
    recv_until(&mut brx, "a snapshot per repo", |msg| {
        if let ServerMsg::WorkSnapshot { source: WorkSource::RepoDocs, group: Some(repo), items } = msg {
            latest.insert(repo.clone(), items.len());
        }
        expected.iter().all(|(repo, n)| latest.get(*repo) == Some(n))
    })
    .await;
    let deadline = Instant::now() + LIVE_DEADLINE;
    while hub.status(WorkSource::RepoDocs).state != SourceState::Fresh {
        assert!(Instant::now() < deadline, "repo docs never became fresh: {:?}", hub.status(WorkSource::RepoDocs));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(hub.status(WorkSource::RepoDocs).count, 12);
    assert_eq!(hub.items(&docs).len(), 12);

    // A repo whose only doc is deleted is published once more with no items.
    tokio::time::sleep(Duration::from_millis(300)).await; // let FSEvents arm
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
        fx.root.join("beta/.claude/bugs/open/2026-09-20-beta-bug.md"),
        fx.root.join("beta/.claude/bugs/resolved/2026-09-20-beta-bug.md"),
    )
    .unwrap();
    recv_until(&mut brx, "a one-item snapshot for beta", |msg| {
        matches!(msg, ServerMsg::WorkSnapshot { source: WorkSource::RepoDocs, group: Some(g), items } if g == "beta" && items.len() == 1)
    })
    .await;
    assert_eq!(hub.items(&docs).len(), 10);
}
