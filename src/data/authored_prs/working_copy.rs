//! A focus session's working copy (repo and branch), by reading files.
//!
//! The session's live directory comes from the tail of its Claude transcript
//! (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, every entry of
//! which carries `cwd`); the repo and branch come from `.git` files. **No git
//! process is ever run** (no hooks, no fsmonitor, no spawned process): this
//! module reads files and nothing else.
//!
//! Every `.git` file read is bounded (256 KiB), must be a regular file and is
//! not followed through a final symlink, so a FIFO named `HEAD` or a `gitdir:`
//! pointing at a device cannot hang or flood the daemon; the engine also runs the
//! whole read on a blocking thread.
//!
//! Limits, stated plainly because the answer is only ever a hint labelled
//! `on_branch`: a session that works in another checkout with `git -C` or
//! absolute paths and never `cd`s there is not seen, and two focuses on one
//! checkout and branch are ambiguous.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use tokio::time::Instant;

use super::ownership::WorkingCopy;
use super::safe_read::read_small_file;
use super::snapshot::safe_segment;

/// How much of a transcript's end is read.
pub const TAIL_BYTES: u64 = 64 * 1024;
/// A focus's working copy is looked at most this often.
pub const REFRESH_EVERY: Duration = Duration::from_secs(30);
/// At most this many focuses are looked at per round.
pub const MAX_FOCUSES: usize = 64;
const MAX_WALK: usize = 64;
/// Find `<projects_root>/*/<session_id>.jsonl`.
pub fn find_transcript(projects_root: &Path, session_id: &str) -> Option<PathBuf> {
    if session_id.is_empty()
        || !session_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return None;
    }
    let file = format!("{session_id}.jsonl");
    for entry in std::fs::read_dir(projects_root).ok()?.flatten() {
        let candidate = entry.path().join(&file);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// The last line of `transcript`'s final 64 KiB whose JSON has a string `cwd`
/// that is an absolute, existing directory.
pub fn last_cwd(transcript: &Path) -> Option<PathBuf> {
    let mut file = std::fs::File::open(transcript).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::with_capacity((len - start) as usize);
    file.take(TAIL_BYTES).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.lines();
    // A tail that starts mid-file begins inside a line: drop that fragment.
    if start > 0 {
        lines.next();
    }
    let mut found = None;
    for line in lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(cwd) = v.get("cwd").and_then(|c| c.as_str()) {
            let p = PathBuf::from(cwd);
            if p.is_absolute() && p.is_dir() {
                found = Some(p);
            }
        }
    }
    found
}

/// `owner/name` (lowercased) from a GitHub remote URL: `https://github.com/o/n(.git)`,
/// `git@github.com:o/n(.git)` or `ssh://git@github.com/o/n(.git)`. Anything else is `None`.
pub fn parse_remote_url(url: &str) -> Option<String> {
    let url = url.trim();
    let path = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    if name.contains('/') || !safe_segment(owner) || !safe_segment(name) {
        return None;
    }
    Some(format!(
        "{}/{}",
        owner.to_ascii_lowercase(),
        name.to_ascii_lowercase()
    ))
}

/// The `url` of `[remote "origin"]` in a git config's text.
fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_origin = l
                .replace(' ', "")
                .eq_ignore_ascii_case("[remote\"origin\"]");
        } else if in_origin {
            if let Some((k, v)) = l.split_once('=') {
                if k.trim().eq_ignore_ascii_case("url") {
                    return Some(v.trim().to_owned());
                }
            }
        }
    }
    None
}

/// Walk up from `cwd` to a `.git` directory or `.git` file and return
/// `(gitdir, common_dir)`.
fn find_git(cwd: &Path) -> Option<(PathBuf, PathBuf)> {
    let mut dir = cwd.to_path_buf();
    for _ in 0..MAX_WALK {
        let dotgit = dir.join(".git");
        if dotgit.is_dir() {
            return Some((dotgit.clone(), dotgit));
        }
        if dotgit.is_file() {
            let text = read_small_file(&dotgit)?;
            let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
            let gitdir = {
                let p = PathBuf::from(target);
                if p.is_absolute() {
                    p
                } else {
                    dir.join(p)
                }
            };
            let common = match read_small_file(&gitdir.join("commondir")) {
                Some(c) => {
                    let p = PathBuf::from(c.trim());
                    if p.is_absolute() {
                        p
                    } else {
                        gitdir.join(p)
                    }
                }
                None => gitdir.clone(),
            };
            return Some((gitdir, common));
        }
        if !dir.pop() {
            return None;
        }
    }
    None
}

/// The repo and branch of the checkout containing `cwd`, from files only.
pub fn working_copy_at(cwd: &Path) -> WorkingCopy {
    let Some((gitdir, common)) = find_git(cwd) else {
        return WorkingCopy::default();
    };
    let branch = read_small_file(&gitdir.join("HEAD"))
        .and_then(|h| {
            h.trim()
                .strip_prefix("ref: refs/heads/")
                .map(|b| b.trim().to_owned())
        })
        .filter(|b| !b.is_empty());
    let repo = read_small_file(&common.join("config"))
        .and_then(|c| origin_url(&c))
        .and_then(|u| parse_remote_url(&u));
    WorkingCopy { repo, branch }
}

/// What the engine knows about one focus's session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRef {
    pub tag: String,
    pub session_id: Option<String>,
    pub spawn_cwd: Option<PathBuf>,
    pub project_path: Option<PathBuf>,
}

#[derive(Default)]
struct Cached {
    checked: Option<Instant>,
    copy: WorkingCopy,
    transcript: Option<(String, PathBuf)>,
    /// mtime and length of the transcript when `cwd` was last read.
    stamp: Option<(SystemTime, u64)>,
    cwd: Option<PathBuf>,
}

/// Per-tag cache of working copies, refreshed at most every [`REFRESH_EVERY`].
#[derive(Default)]
pub struct WorkingCopies {
    cache: HashMap<String, Cached>,
}

impl WorkingCopies {
    /// Refresh what is due and return every known tag's working copy. Tags no
    /// longer in `sessions` are forgotten.
    pub fn refresh(
        &mut self,
        now: Instant,
        projects_root: &Path,
        sessions: &[SessionRef],
    ) -> HashMap<String, WorkingCopy> {
        let live: std::collections::HashSet<&str> =
            sessions.iter().map(|s| s.tag.as_str()).collect();
        self.cache.retain(|t, _| live.contains(t.as_str()));
        for s in sessions.iter().take(MAX_FOCUSES) {
            let entry = self.cache.entry(s.tag.clone()).or_default();
            if entry
                .checked
                .is_some_and(|c| now.saturating_duration_since(c) < REFRESH_EVERY)
            {
                continue;
            }
            entry.checked = Some(now);
            entry.cwd = Self::live_cwd(entry, projects_root, s);
            entry.copy = entry
                .cwd
                .as_deref()
                .map(working_copy_at)
                .unwrap_or_default();
        }
        self.cache
            .iter()
            .map(|(t, c)| (t.clone(), c.copy.clone()))
            .collect()
    }

    fn live_cwd(entry: &mut Cached, projects_root: &Path, s: &SessionRef) -> Option<PathBuf> {
        if let Some(id) = s.session_id.as_deref() {
            let path = match &entry.transcript {
                Some((cached_id, p)) if cached_id == id && p.is_file() => Some(p.clone()),
                _ => find_transcript(projects_root, id),
            };
            if let Some(path) = path {
                entry.transcript = Some((id.to_owned(), path.clone()));
                let stamp = std::fs::metadata(&path)
                    .and_then(|m| m.modified().map(|t| (t, m.len())))
                    .ok();
                // Read the transcript only when it changed.
                if stamp.is_some() && stamp == entry.stamp && entry.cwd.is_some() {
                    return entry.cwd.clone();
                }
                entry.stamp = stamp;
                if let Some(cwd) = last_cwd(&path) {
                    return Some(cwd);
                }
            }
        }
        [s.spawn_cwd.as_ref(), s.project_path.as_ref()]
            .into_iter()
            .flatten()
            .find(|p| p.is_absolute() && p.is_dir())
            .cloned()
    }
}

#[cfg(test)]
mod tests {
    //! A focus's working copy, read from files in temp directories: the
    //! transcript's last `cwd`, then `.git`. No git process is involved, and a
    //! source scan keeps it that way.

    use super::*;
    use std::fs;
    use std::io::Write;
    use tempfile::TempDir;

    const SID: &str = "11111111-2222-3333-4444-555555555555";

    struct World {
        _tmp: TempDir,
        root: PathBuf,
        projects: PathBuf,
    }

    fn world() -> World {
        let tmp = tempfile::tempdir().expect("tempdir");
        // Canonical, so a `cwd` we write is the path the reader sees.
        let root = tmp.path().canonicalize().unwrap();
        let projects = root.join("projects");
        fs::create_dir_all(projects.join("-encoded-cwd")).unwrap();
        World {
            _tmp: tmp,
            root,
            projects,
        }
    }

    impl World {
        /// A checkout with a `.git` directory on `head`, origin `url`.
        fn checkout(&self, name: &str, head: &str, url: Option<&str>) -> PathBuf {
            let dir = self.root.join(name);
            let git = dir.join(".git");
            fs::create_dir_all(&git).unwrap();
            fs::write(git.join("HEAD"), head).unwrap();
            let mut config = String::from("[core]\n\trepositoryformatversion = 0\n");
            if let Some(url) = url {
                config.push_str(&format!(
                    "[remote \"origin\"]\n\turl = {url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                ));
            }
            fs::write(git.join("config"), config).unwrap();
            dir
        }

        /// A linked worktree of `main` (a checkout from [`checkout`]).
        fn linked_worktree(&self, main: &Path, name: &str, head: &str) -> PathBuf {
            let admin = main.join(".git").join("worktrees").join(name);
            fs::create_dir_all(&admin).unwrap();
            fs::write(admin.join("HEAD"), head).unwrap();
            fs::write(admin.join("commondir"), "../..\n").unwrap();
            let wt = self.root.join(format!("wt-{name}"));
            fs::create_dir_all(&wt).unwrap();
            fs::write(wt.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
            wt
        }

        fn transcript_path(&self) -> PathBuf {
            self.projects
                .join("-encoded-cwd")
                .join(format!("{SID}.jsonl"))
        }

        fn write_transcript(&self, lines: &[String]) {
            let mut text = lines.join("\n");
            text.push('\n');
            fs::write(self.transcript_path(), text).unwrap();
        }

        fn session(&self, spawn_cwd: Option<&Path>, project: Option<&Path>) -> SessionRef {
            SessionRef {
                tag: "alpha".into(),
                session_id: Some(SID.into()),
                spawn_cwd: spawn_cwd.map(Path::to_path_buf),
                project_path: project.map(Path::to_path_buf),
            }
        }

        fn copy_of(&self, session: SessionRef) -> WorkingCopy {
            let mut copies = WorkingCopies::default();
            copies
                .refresh(Instant::now(), &self.projects, &[session])
                .remove("alpha")
                .expect("the focus has an entry")
        }
    }

    fn entry(cwd: &Path) -> String {
        serde_json::json!({"type": "user", "cwd": cwd, "message": "hi"}).to_string()
    }

    fn entry_without_cwd() -> String {
        serde_json::json!({"type": "summary", "summary": "no directory here"}).to_string()
    }

    // ── from the transcript to the checkout ───────────────────────────────

    #[test]
    fn a_git_directory_on_a_branch_with_an_https_origin_gives_repo_and_branch() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat-x\n",
            Some("https://github.com/Carefeed/App.git"),
        );
        w.write_transcript(&[entry(&co)]);
        let copy = w.copy_of(w.session(None, None));
        assert_eq!(copy.branch.as_deref(), Some("feat-x"));
        assert_eq!(
            copy.repo.as_deref(),
            Some("carefeed/app"),
            "lowercased, no .git"
        );
    }

    #[test]
    fn a_subdirectory_of_the_checkout_finds_the_checkout() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat-x\n",
            Some("https://github.com/o/n"),
        );
        let sub = co.join("src").join("deep");
        fs::create_dir_all(&sub).unwrap();
        w.write_transcript(&[entry(&sub)]);
        let copy = w.copy_of(w.session(None, None));
        assert_eq!(copy.branch.as_deref(), Some("feat-x"));
        assert_eq!(copy.repo.as_deref(), Some("o/n"));
    }

    #[test]
    fn a_linked_worktree_reads_its_own_head_and_the_main_repos_origin() {
        let w = world();
        let main = w.checkout(
            "main-repo",
            "ref: refs/heads/main\n",
            Some("git@github.com:thehammer/nostromo.git"),
        );
        let wt = w.linked_worktree(&main, "feature", "ref: refs/heads/feat-y\n");
        w.write_transcript(&[entry(&wt)]);
        let copy = w.copy_of(w.session(None, None));
        assert_eq!(
            copy.branch.as_deref(),
            Some("feat-y"),
            "the worktree's own branch, not main"
        );
        assert_eq!(
            copy.repo.as_deref(),
            Some("thehammer/nostromo"),
            "ssh origin from the common dir"
        );
    }

    #[test]
    fn a_detached_head_has_no_branch_but_still_has_a_repo() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "0123456789abcdef0123456789abcdef01234567\n",
            Some("https://github.com/o/n.git"),
        );
        w.write_transcript(&[entry(&co)]);
        let copy = w.copy_of(w.session(None, None));
        assert_eq!(copy.branch, None);
        assert_eq!(copy.repo.as_deref(), Some("o/n"));
    }

    #[test]
    fn a_remote_that_is_not_github_gives_no_repo() {
        for url in [
            "https://gitlab.com/o/n.git",
            "git@bitbucket.org:o/n.git",
            "https://github.com.evil.example/o/n.git",
            "https://example.com/github.com/o/n",
            "/local/path/to/repo.git",
            "https://github.com/onlyowner",
            "https://github.com/o/n/extra",
        ] {
            let w = world();
            let co = w.checkout("checkout", "ref: refs/heads/feat\n", Some(url));
            w.write_transcript(&[entry(&co)]);
            let copy = w.copy_of(w.session(None, None));
            assert_eq!(copy.repo, None, "{url}");
            assert_eq!(
                copy.branch.as_deref(),
                Some("feat"),
                "{url}: the branch is still read"
            );
        }
    }

    #[test]
    fn a_checkout_with_no_origin_gives_no_repo() {
        let w = world();
        let co = w.checkout("checkout", "ref: refs/heads/feat\n", None);
        w.write_transcript(&[entry(&co)]);
        assert_eq!(w.copy_of(w.session(None, None)).repo, None);
    }

    #[test]
    fn remote_urls_parse_from_every_github_form_and_nothing_else() {
        for (url, want) in [
            ("https://github.com/Carefeed/App", Some("carefeed/app")),
            ("https://github.com/Carefeed/App.git", Some("carefeed/app")),
            ("https://github.com/Carefeed/App/", Some("carefeed/app")),
            ("git@github.com:Carefeed/App.git", Some("carefeed/app")),
            (
                "ssh://git@github.com/Carefeed/App.git",
                Some("carefeed/app"),
            ),
            ("  https://github.com/o/n.git  ", Some("o/n")),
            ("http://github.com/o/n", None),
            ("git@gitlab.com:o/n.git", None),
            ("https://github.com/o/n n", None),
            ("https://github.com/../n", None),
            ("", None),
        ] {
            assert_eq!(parse_remote_url(url).as_deref(), want, "{url:?}");
        }
    }

    // ── where the session is ──────────────────────────────────────────────

    #[test]
    fn the_last_cwd_in_the_transcript_wins() {
        let w = world();
        let first = w.checkout(
            "first",
            "ref: refs/heads/one\n",
            Some("https://github.com/o/first"),
        );
        let second = w.checkout(
            "second",
            "ref: refs/heads/two\n",
            Some("https://github.com/o/second"),
        );
        w.write_transcript(&[entry(&first), entry(&second), entry_without_cwd()]);
        let copy = w.copy_of(w.session(Some(&first), None));
        assert_eq!(copy.branch.as_deref(), Some("two"));
        assert_eq!(copy.repo.as_deref(), Some("o/second"));
    }

    #[test]
    fn a_transcript_without_a_cwd_falls_back_to_the_spawn_cwd() {
        let w = world();
        let spawn = w.checkout(
            "spawned",
            "ref: refs/heads/spawned-branch\n",
            Some("https://github.com/o/spawned"),
        );
        w.write_transcript(&[entry_without_cwd(), entry_without_cwd()]);
        let copy = w.copy_of(w.session(Some(&spawn), None));
        assert_eq!(copy.branch.as_deref(), Some("spawned-branch"));
        assert_eq!(copy.repo.as_deref(), Some("o/spawned"));
    }

    #[test]
    fn no_transcript_at_all_falls_back_to_the_spawn_cwd_and_then_the_project_path() {
        let w = world();
        let spawn = w.checkout(
            "spawned",
            "ref: refs/heads/from-spawn\n",
            Some("https://github.com/o/spawned"),
        );
        let project = w.checkout(
            "project",
            "ref: refs/heads/from-project\n",
            Some("https://github.com/o/project"),
        );
        // No transcript file was written.
        assert_eq!(
            w.copy_of(w.session(Some(&spawn), Some(&project)))
                .branch
                .as_deref(),
            Some("from-spawn")
        );
        let missing = w.root.join("does-not-exist");
        assert_eq!(
            w.copy_of(w.session(Some(&missing), Some(&project)))
                .branch
                .as_deref(),
            Some("from-project"),
            "a spawn cwd that is gone is skipped"
        );
        assert_eq!(w.copy_of(w.session(None, None)), WorkingCopy::default());
    }

    #[test]
    fn a_cwd_that_no_longer_exists_is_skipped_for_the_one_before_it() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        let gone = w.root.join("deleted-worktree");
        w.write_transcript(&[entry(&co), entry(&gone)]);
        assert_eq!(
            w.copy_of(w.session(None, None)).branch.as_deref(),
            Some("feat")
        );
    }

    #[test]
    fn a_relative_cwd_is_not_trusted() {
        let w = world();
        w.write_transcript(&[serde_json::json!({"cwd": "relative/dir"}).to_string()]);
        assert_eq!(last_cwd(&w.transcript_path()), None);
    }

    #[test]
    fn a_directory_that_is_not_a_checkout_has_no_repo_and_no_branch() {
        let w = world();
        if w.root.ancestors().any(|a| a.join(".git").exists()) {
            // The temp directory sits inside a checkout here; nothing to learn.
            return;
        }
        let plain = w.root.join("plain");
        fs::create_dir_all(&plain).unwrap();
        w.write_transcript(&[entry(&plain)]);
        // `plain` sits under the temp root, which has no `.git` above it.
        assert_eq!(w.copy_of(w.session(None, None)), WorkingCopy::default());
    }

    // ── how much of the transcript is read ────────────────────────────────

    #[test]
    fn a_ten_megabyte_transcript_is_read_only_at_its_tail() {
        let w = world();
        let head_only = w.checkout(
            "head-only",
            "ref: refs/heads/old\n",
            Some("https://github.com/o/old"),
        );
        let tail = w.checkout(
            "tail",
            "ref: refs/heads/new\n",
            Some("https://github.com/o/new"),
        );

        // The only `cwd` before the tail is in the first line; then ten
        // megabytes of lines without one; then the tail's own `cwd`.
        let filler = serde_json::json!({"type": "assistant", "text": "x".repeat(1000)}).to_string();
        let mut f = fs::File::create(w.transcript_path()).unwrap();
        writeln!(f, "{}", entry(&head_only)).unwrap();
        for _ in 0..(10 * 1024 * 1024 / (filler.len() + 1)) {
            writeln!(f, "{filler}").unwrap();
        }
        // No cwd anywhere in the final 64 KiB yet: the head's `cwd` is out of reach.
        drop(f);
        assert!(fs::metadata(w.transcript_path()).unwrap().len() > 10 * 1024 * 1024 - 2048);
        assert_eq!(
            last_cwd(&w.transcript_path()),
            None,
            "only the last 64 KiB is read, and it holds no cwd"
        );
        assert_eq!(
            w.copy_of(w.session(None, None)),
            WorkingCopy::default(),
            "so the head's checkout is not found"
        );

        let mut f = fs::OpenOptions::new()
            .append(true)
            .open(w.transcript_path())
            .unwrap();
        writeln!(f, "{}", entry(&tail)).unwrap();
        drop(f);
        assert_eq!(last_cwd(&w.transcript_path()), Some(tail));
    }

    #[test]
    fn a_cwd_inside_the_final_64_kib_is_found_even_in_a_huge_file() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        let filler = serde_json::json!({"type": "assistant", "text": "y".repeat(2000)}).to_string();
        let mut f = fs::File::create(w.transcript_path()).unwrap();
        for _ in 0..(3 * 1024 * 1024 / (filler.len() + 1)) {
            writeln!(f, "{filler}").unwrap();
        }
        writeln!(f, "{}", entry(&co)).unwrap();
        for _ in 0..10 {
            writeln!(f, "{filler}").unwrap();
        }
        drop(f);
        assert_eq!(
            w.copy_of(w.session(None, None)).branch.as_deref(),
            Some("feat")
        );
    }

    #[test]
    fn a_truncated_first_line_in_the_tail_is_ignored_not_misread() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        // One line that straddles the 64 KiB boundary and is itself valid JSON
        // once cut (a bare number), then a real entry.
        let pad = "z".repeat(TAIL_BYTES as usize + 100);
        let straddler = format!("{{\"text\":\"{pad}\",\"n\":1}}");
        w.write_transcript(&[straddler, entry(&co)]);
        assert_eq!(last_cwd(&w.transcript_path()), Some(co));
    }

    // ── the cache ─────────────────────────────────────────────────────────

    #[test]
    fn a_focus_is_looked_at_most_every_thirty_seconds() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/before\n",
            Some("https://github.com/o/n"),
        );
        w.write_transcript(&[entry(&co)]);
        let session = w.session(None, None);
        let mut copies = WorkingCopies::default();
        let t0 = Instant::now();
        let first = copies.refresh(t0, &w.projects, std::slice::from_ref(&session));
        assert_eq!(first["alpha"].branch.as_deref(), Some("before"));

        fs::write(co.join(".git").join("HEAD"), "ref: refs/heads/after\n").unwrap();
        let soon = copies.refresh(
            t0 + Duration::from_secs(29),
            &w.projects,
            std::slice::from_ref(&session),
        );
        assert_eq!(
            soon["alpha"].branch.as_deref(),
            Some("before"),
            "not looked at again yet"
        );
        let later = copies.refresh(t0 + Duration::from_secs(30), &w.projects, &[session]);
        assert_eq!(later["alpha"].branch.as_deref(), Some("after"));
    }

    #[test]
    fn a_focus_that_is_no_longer_open_is_forgotten() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        w.write_transcript(&[entry(&co)]);
        let mut copies = WorkingCopies::default();
        let t0 = Instant::now();
        assert!(copies
            .refresh(t0, &w.projects, &[w.session(None, None)])
            .contains_key("alpha"));
        assert!(copies.refresh(t0, &w.projects, &[]).is_empty());
    }

    #[test]
    fn at_most_sixty_four_focuses_are_looked_at() {
        let w = world();
        let sessions: Vec<SessionRef> = (0..80)
            .map(|i| SessionRef {
                tag: format!("focus-{i:02}"),
                session_id: None,
                spawn_cwd: None,
                project_path: None,
            })
            .collect();
        let mut copies = WorkingCopies::default();
        let out = copies.refresh(Instant::now(), &w.projects, &sessions);
        assert_eq!(out.len(), MAX_FOCUSES);
    }

    // ── session ids ───────────────────────────────────────────────────────

    #[test]
    fn a_session_id_that_could_name_another_path_finds_nothing() {
        let w = world();
        for id in ["", "../escape", "a/b", "a b", "ok\0no"] {
            assert_eq!(find_transcript(&w.projects, id), None, "{id:?}");
        }
        let co = w.checkout("checkout", "ref: refs/heads/feat\n", None);
        w.write_transcript(&[entry(&co)]);
        assert_eq!(find_transcript(&w.projects, SID), Some(w.transcript_path()));
    }

    // ── no process, ever ──────────────────────────────────────────────────

    #[test]
    fn the_module_never_starts_a_process() {
        // Everything before the tests module is the production code.
        let source = include_str!("working_copy.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("the file has a production part");
        for forbidden in [
            "Command",
            "std::process",
            "tokio::process",
            ".spawn(",
            ".output(",
            ".status(",
            "libc::",
            "fork(",
            "exec(",
        ] {
            assert!(
                !production.contains(forbidden),
                "working_copy.rs must read files only; it mentions `{forbidden}`"
            );
        }
    }

    // ── files that something else controls ────────────────────────────────

    /// A FIFO (named pipe) at `path`: opening it for reading blocks until a
    /// writer opens it. Tests only; the production code never calls libc.
    fn mkfifo(path: &Path) {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: `c` is a valid NUL-terminated path for the whole call.
        let rc = unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
        assert_eq!(rc, 0, "mkfifo: {}", std::io::Error::last_os_error());
    }

    /// `working_copy_at(cwd)` on its own thread, so a read that blocks forever
    /// fails this test instead of hanging the run.
    fn working_copy_within_a_few_seconds(cwd: &Path) -> WorkingCopy {
        let (tx, rx) = std::sync::mpsc::channel();
        let cwd = cwd.to_path_buf();
        std::thread::spawn(move || {
            let _ = tx.send(working_copy_at(&cwd));
        });
        rx.recv_timeout(Duration::from_secs(10))
            .expect("the read returned: a FIFO or other odd file must not block it")
    }

    #[test]
    fn a_fifo_named_head_reads_as_no_branch_and_returns_promptly() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        fs::remove_file(co.join(".git").join("HEAD")).unwrap();
        mkfifo(&co.join(".git").join("HEAD"));
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.branch, None);
        assert_eq!(
            copy.repo.as_deref(),
            Some("o/n"),
            "the rest of the checkout is still read"
        );
    }

    #[test]
    fn a_fifo_named_config_reads_as_no_repo_and_returns_promptly() {
        let w = world();
        let co = w.checkout("checkout", "ref: refs/heads/feat\n", None);
        fs::remove_file(co.join(".git").join("config")).unwrap();
        mkfifo(&co.join(".git").join("config"));
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.repo, None);
        assert_eq!(copy.branch.as_deref(), Some("feat"));
    }

    #[test]
    fn a_git_file_pointing_at_a_directory_whose_head_is_a_fifo_returns_promptly_with_no_branch() {
        let w = world();
        let main = w.checkout(
            "main-repo",
            "ref: refs/heads/main\n",
            Some("https://github.com/o/n"),
        );
        let wt = w.linked_worktree(&main, "feature", "ref: refs/heads/feat-y\n");
        let admin = main.join(".git").join("worktrees").join("feature");
        fs::remove_file(admin.join("HEAD")).unwrap();
        mkfifo(&admin.join("HEAD"));
        // The worktree's `commondir` is a pipe too.
        fs::remove_file(admin.join("commondir")).unwrap();
        mkfifo(&admin.join("commondir"));
        let copy = working_copy_within_a_few_seconds(&wt);
        assert_eq!(copy.branch, None);
        assert_eq!(
            copy.repo, None,
            "no commondir, so no config was found either"
        );
    }

    #[test]
    fn a_head_or_config_over_256_kib_is_not_read() {
        let padding = " ".repeat(300 * 1024);

        let w = world();
        let co = w.checkout(
            "big-head",
            &format!("ref: refs/heads/feat\n{padding}"),
            Some("https://github.com/o/n"),
        );
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.branch, None, "an oversized HEAD is not read");
        assert_eq!(copy.repo.as_deref(), Some("o/n"));

        let co = w.checkout("big-config", "ref: refs/heads/feat\n", None);
        let mut config = String::from("[remote \"origin\"]\n\turl = https://github.com/o/n\n");
        config.push_str(&format!("# {padding}\n"));
        fs::write(co.join(".git").join("config"), config).unwrap();
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.repo, None, "an oversized config is not read");
        assert_eq!(copy.branch.as_deref(), Some("feat"));

        // Control: just under the limit is still read.
        let co = w.checkout(
            "ok-head",
            &format!("ref: refs/heads/feat\n{}", " ".repeat(200 * 1024)),
            Some("https://github.com/o/n"),
        );
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.branch.as_deref(), Some("feat"));
    }

    #[test]
    fn a_head_that_is_a_symlink_is_not_followed() {
        let w = world();
        let co = w.checkout(
            "checkout",
            "ref: refs/heads/feat\n",
            Some("https://github.com/o/n"),
        );
        let elsewhere = w.root.join("elsewhere");
        fs::write(&elsewhere, "ref: refs/heads/from-the-symlink\n").unwrap();
        let head = co.join(".git").join("HEAD");
        fs::remove_file(&head).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &head).unwrap();
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.branch, None, "{copy:?}");

        // Nor is a symlinked config.
        let co = w.checkout("checkout2", "ref: refs/heads/feat\n", None);
        let real = w.root.join("real-config");
        fs::write(
            &real,
            "[remote \"origin\"]\n\turl = https://github.com/o/n\n",
        )
        .unwrap();
        let config = co.join(".git").join("config");
        fs::remove_file(&config).unwrap();
        std::os::unix::fs::symlink(&real, &config).unwrap();
        let copy = working_copy_within_a_few_seconds(&co);
        assert_eq!(copy.repo, None, "{copy:?}");
        assert_eq!(copy.branch.as_deref(), Some("feat"));
    }
}
