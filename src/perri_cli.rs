//! Helpers backing the daemon's `PerriAction` IPC handler.
//!
//! `"load_pr"`/`"clear"` write the `current-pr` file contract directly
//! through [`crate::data::perri_current_pr`] — the same module the
//! daemon-hosted `perri.load_pr`/`perri.clear_current_pr` MCP handlers write
//! through — so the two hosts can never drift on the file shape. Only
//! `"approve"` shells out, to the real `gh` CLI.
//!
//! Mirrors the pattern in `src/mother/mod.rs` (`run_mother` + `validate_job_id`).

use std::io::Write as _;
use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::data::perri_current_pr;

/// `GH_BIN` env var overrides the default `gh` binary name (used for approve).
const GH_BIN_ENV: &str = "GH_BIN";

fn gh_bin() -> String {
    std::env::var(GH_BIN_ENV).unwrap_or_else(|_| "gh".to_owned())
}

/// Validate that a repo slug only contains safe characters before passing it
/// to a shell-out.  Accepted: `[A-Za-z0-9._/-]+`.
fn validate_repo(repo: &str) -> Result<()> {
    if repo.is_empty() {
        bail!("repo slug is empty");
    }
    if !repo
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '-'))
    {
        bail!("repo slug contains unsafe characters: {repo:?}");
    }
    Ok(())
}

/// Execute the appropriate write-through or `gh` invocation for the given `action`.
///
/// - `"load_pr"` → writes `current-pr.json` + touches `current-pr.dirty` via
///   `crate::data::perri_current_pr::write_pointer` (no `highlights` — that's
///   the MCP tool's agent-authored-content feature, with no client affordance
///   here).
/// - `"clear"`   → removes `current-pr.json`, touches `current-pr.dirty` via
///   `perri_current_pr::clear_pointer`, then touches `queue.dirty` via
///   `perri_current_pr::touch_queue_dirty` — matching
///   `clear_current_pr_daemon`'s order.
/// - `"approve"` → resolves HEAD sha, posts `gh pr review --approve`, then
///   writes the Phase 1 approval signal to `<perri_state_dir>/approvals.jsonl`
///   and touches `<perri_state_dir>/queue.dirty` for instant queue suppression.
///   Requires a non-zero `pr_number` and a safe `repo` slug.
pub async fn run_perri_action(
    action: &str,
    pr_number: Option<u64>,
    repo: Option<&str>,
    perri_state_dir: &Path,
) -> Result<()> {
    match action {
        "load_pr" => {
            let number = pr_number
                .filter(|&n| n > 0)
                .with_context(|| "load_pr requires a non-zero pr_number")?;
            let repo = repo.with_context(|| "load_pr requires a repo slug")?;

            // `highlights: None` — agent-authored highlights are the MCP
            // tool's feature; `ClientMsg::PerriAction` carries no such field.
            perri_current_pr::write_pointer(perri_state_dir, number, repo, None)
                .map_err(|e| anyhow::anyhow!(e))
                .with_context(|| "load_pr: writing current-pr pointer")?;
        }

        "clear" => {
            perri_current_pr::clear_pointer(perri_state_dir)
                .map_err(|e| anyhow::anyhow!(e))
                .with_context(|| "clear: removing current-pr pointer")?;
            perri_current_pr::touch_queue_dirty(perri_state_dir)
                .map_err(|e| anyhow::anyhow!(e))
                .with_context(|| "clear: touching queue.dirty")?;
        }

        "approve" => {
            let number = pr_number
                .filter(|&n| n > 0)
                .with_context(|| "approve requires a non-zero pr_number")?;
            let repo = repo.with_context(|| "approve requires a repo slug")?;
            validate_repo(repo)?;

            let gh = gh_bin();

            // 1. Resolve the HEAD sha before posting the approval so we can
            //    write the exact commit-scoped suppression entry Phase 1 uses.
            let sha_output = tokio::process::Command::new(&gh)
                .args([
                    "pr", "view",
                    &number.to_string(),
                    "--repo", repo,
                    "--json", "headRefOid",
                    "-q", ".headRefOid",
                ])
                .output()
                .await
                .with_context(|| format!("spawning {gh} pr view (resolve head sha)"))?;

            if !sha_output.status.success() {
                bail!(
                    "{gh} pr view exited with status {} while resolving head sha",
                    sha_output.status
                );
            }

            let head_sha = std::str::from_utf8(&sha_output.stdout)
                .with_context(|| "gh pr view output is not UTF-8")?
                .trim()
                .to_owned();

            if head_sha.is_empty() {
                bail!("gh pr view returned an empty head sha for PR #{number} in {repo}");
            }

            // Guard against unexpected gh output (error messages, malformed data)
            // leaking verbatim into approvals.jsonl.  A valid SHA is hex-only and
            // at least 7 chars; anything else is treated as a gh failure.
            if head_sha.len() < 7 || !head_sha.chars().all(|c| c.is_ascii_hexdigit()) {
                bail!(
                    "gh pr view returned an unexpected head sha for PR #{number}: {head_sha:?}"
                );
            }

            // 2. Post the approval — no comment body (iOS approve is comment-free).
            let approve_status = tokio::process::Command::new(&gh)
                .args([
                    "pr", "review",
                    &number.to_string(),
                    "--repo", repo,
                    "--approve",
                ])
                .status()
                .await
                .with_context(|| format!("spawning {gh} pr review --approve"))?;

            if !approve_status.success() {
                bail!("{gh} pr review --approve exited with status {approve_status}");
            }

            // 3. Write the Phase 1 approval signal for instant queue suppression.
            write_approval_signal(perri_state_dir, repo, number, &head_sha)
                .with_context(|| "writing approval signal after gh pr review")?;
        }

        other => {
            tracing::warn!(action = other, "unknown PerriAction — ignoring");
        }
    }

    Ok(())
}

/// Append one approval line to `<state_dir>/approvals.jsonl` and touch
/// `<state_dir>/queue.dirty`, triggering instant queue suppression via the
/// Phase 1 `SuppressStore` path.
///
/// This is the **same signal** the `submit-review` skill writes; the daemon's
/// `PerriQueueNativeSource` watches for `approvals.jsonl` and processes it
/// atomically, so the just-approved PR drops from the next broadcast.
pub(crate) fn write_approval_signal(
    state_dir: &Path,
    repo: &str,
    number: u64,
    head_sha: &str,
) -> Result<()> {
    std::fs::create_dir_all(state_dir)
        .with_context(|| format!("creating perri state dir {}", state_dir.display()))?;

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Build the JSON line manually — all three string values are already
    // validated/trusted (repo via validate_repo, head_sha is a hex string
    // from gh, number is u64), so no escaping is required.
    let line = format!(
        "{{\"repo\":\"{repo}\",\"number\":{number},\"head_sha\":\"{head_sha}\",\"ts\":{ts}}}\n"
    );

    let approvals_path = state_dir.join("approvals.jsonl");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&approvals_path)
        .with_context(|| format!("opening {}", approvals_path.display()))?;
    file.write_all(line.as_bytes())
        .with_context(|| format!("writing to {}", approvals_path.display()))?;

    // Touch queue.dirty — the dirty-file watcher removes it and signals a
    // re-fetch, which applies the new suppression entry on the next broadcast.
    let dirty_path = state_dir.join("queue.dirty");
    std::fs::write(&dirty_path, b"")
        .with_context(|| format!("touching {}", dirty_path.display()))?;

    Ok(())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_repo_accepts_normal_slugs() {
        assert!(validate_repo("acme/web-app").is_ok());
        assert!(validate_repo("Carefeed/admin-portal").is_ok());
        assert!(validate_repo("org/repo.git").is_ok());
        assert!(validate_repo("a/b_c-d.e").is_ok());
    }

    #[test]
    fn validate_repo_rejects_unsafe_chars() {
        assert!(validate_repo("org/repo;rm -rf /").is_err());
        assert!(validate_repo("org/repo`whoami`").is_err());
        assert!(validate_repo("").is_err());
        assert!(validate_repo("org/repo\nnewline").is_err());
    }

    // ── approve validation ────────────────────────────────────────────────────
    // These tests exercise input validation for the "approve" action.
    // They should fail before any `gh` shell-out, so no real `gh` binary is
    // needed.  All four tests call the 4-parameter signature that will exist
    // once the "approve" arm is implemented.

    #[tokio::test]
    async fn approve_rejects_empty_repo() {
        let dir = tempfile::tempdir().unwrap();
        let err = run_perri_action("approve", Some(1), Some(""), dir.path())
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("empty") || msg.contains("unsafe"),
            "expected repo-validation error, got: {msg}"
        );
    }

    #[tokio::test]
    async fn approve_rejects_unsafe_repo() {
        let dir = tempfile::tempdir().unwrap();
        let err = run_perri_action("approve", Some(1), Some("org/repo;rm -rf /"), dir.path())
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("unsafe"),
            "expected unsafe-repo error, got: {msg}"
        );
    }

    #[tokio::test]
    async fn approve_requires_nonzero_pr_number() {
        let dir = tempfile::tempdir().unwrap();
        let err = run_perri_action("approve", Some(0), Some("org/repo"), dir.path())
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("pr_number") || msg.contains("non-zero"),
            "expected non-zero pr_number error, got: {msg}"
        );
    }

    #[tokio::test]
    async fn approve_requires_pr_number() {
        let dir = tempfile::tempdir().unwrap();
        let err = run_perri_action("approve", None, Some("org/repo"), dir.path())
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("pr_number") || msg.contains("requires"),
            "expected missing pr_number error, got: {msg}"
        );
    }

    // ── load_pr / clear write-through (fix for shelling out to a nonexistent
    //    `perri` binary) ─────────────────────────────────────────────────────
    // These exercise the post-fix contract: "load_pr"/"clear" must write
    // through `crate::data::perri_current_pr` (the same file contract the
    // daemon's `perri.load_pr`/`perri.clear_current_pr` MCP tools use)
    // instead of shelling out to a `perri` binary that doesn't exist.

    #[tokio::test]
    async fn load_pr_writes_a_current_pr_pointer() {
        let dir = tempfile::tempdir().unwrap();

        let result = run_perri_action("load_pr", Some(42), Some("acme/widget"), dir.path()).await;
        assert!(result.is_ok(), "expected Ok, got {result:?}");

        let content = std::fs::read_to_string(dir.path().join("current-pr.json"))
            .expect("current-pr.json must exist after load_pr");
        let pointer: crate::data::perri_pr_native::CurrentPrPointer =
            serde_json::from_str(&content).expect("must deserialize as CurrentPrPointer");
        assert_eq!(pointer.number, 42);
        assert_eq!(pointer.repo, "acme/widget");

        assert!(
            dir.path().join("current-pr.dirty").exists(),
            "load_pr must touch current-pr.dirty"
        );
    }

    #[tokio::test]
    async fn clear_removes_the_pointer_and_touches_both_sentinels() {
        let dir = tempfile::tempdir().unwrap();

        run_perri_action("load_pr", Some(1), Some("acme/widget"), dir.path())
            .await
            .expect("load_pr must succeed before clear");
        assert!(dir.path().join("current-pr.json").exists());

        let result = run_perri_action("clear", None, None, dir.path()).await;
        assert!(result.is_ok(), "expected Ok, got {result:?}");

        assert!(
            !dir.path().join("current-pr.json").exists(),
            "clear must remove the current-pr pointer"
        );
        assert!(
            dir.path().join("current-pr.dirty").exists(),
            "clear must touch current-pr.dirty"
        );
        assert!(
            dir.path().join("queue.dirty").exists(),
            "clear must touch queue.dirty"
        );
    }

    #[tokio::test]
    async fn clear_on_an_absent_pointer_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        // No prior load_pr — current-pr.json never existed.

        let result = run_perri_action("clear", None, None, dir.path()).await;
        assert!(result.is_ok(), "clearing an absent pointer must not error");

        assert!(dir.path().join("current-pr.dirty").exists());
        assert!(dir.path().join("queue.dirty").exists());
    }

    #[tokio::test]
    async fn load_pr_creates_a_missing_state_dir() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("nested");
        assert!(!nested.exists());

        let result = run_perri_action("load_pr", Some(9), Some("acme/widget"), &nested).await;
        assert!(result.is_ok(), "expected Ok, got {result:?}");

        assert!(
            nested.join("current-pr.json").exists(),
            "load_pr must create the state dir and write into it"
        );
    }

    #[tokio::test]
    async fn load_pr_rejects_a_slugless_repo() {
        let dir = tempfile::tempdir().unwrap();

        let result = run_perri_action("load_pr", Some(1), Some("acmewidget"), dir.path()).await;
        assert!(result.is_err());
        assert!(!dir.path().join("current-pr.json").exists());
    }

    #[tokio::test]
    async fn load_pr_rejects_a_multi_segment_repo() {
        let dir = tempfile::tempdir().unwrap();

        let result =
            run_perri_action("load_pr", Some(1), Some("acme/widget/extra"), dir.path()).await;
        assert!(result.is_err());
        assert!(!dir.path().join("current-pr.json").exists());
    }

    #[tokio::test]
    async fn load_pr_rejects_an_unsafe_repo() {
        let dir = tempfile::tempdir().unwrap();

        let result = run_perri_action(
            "load_pr",
            Some(1),
            Some("org/repo;rm -rf /"),
            dir.path(),
        )
        .await;
        assert!(result.is_err());
        assert!(!dir.path().join("current-pr.json").exists());
    }

    #[tokio::test]
    async fn load_pr_still_requires_a_nonzero_pr_number() {
        let dir = tempfile::tempdir().unwrap();

        let result = run_perri_action("load_pr", Some(0), Some("acme/widget"), dir.path()).await;
        assert!(result.is_err(), "pr_number: Some(0) must be rejected");
        assert!(!dir.path().join("current-pr.json").exists());

        let result = run_perri_action("load_pr", None, Some("acme/widget"), dir.path()).await;
        assert!(result.is_err(), "pr_number: None must be rejected");
        assert!(!dir.path().join("current-pr.json").exists());
    }

    /// Heuristic textual guard, not a control-flow proof — same spirit as the
    /// `include_str!`-based fixture tests in `src/ipc/stream_json.rs`. This
    /// greps this file's own *production* source text (everything before
    /// `#[cfg(test)]`) for evidence that "load_pr"/"clear" still shell out to
    /// a `perri` binary: the `PERRI_BIN` env-var indirection, or a
    /// subcommand string like `"load_pr"`/`"clear_current_pr"` sitting near
    /// a `Command::new` call. It cannot prove the daemon never shells out to
    /// `perri` anywhere in the process — only that this file doesn't
    /// reintroduce the exact shell-out this bug report is about.
    ///
    /// Deliberately excludes the test module itself: this very test's own
    /// guard messages mention "PERRI_BIN" as a string, and `include_str!`
    /// pulls in the whole file, so scanning past `#[cfg(test)]` would make
    /// the assertion trip on itself.
    #[test]
    fn perri_cli_does_not_shell_out_to_the_perri_binary() {
        let full_src = include_str!("perri_cli.rs");
        let src = full_src
            .split_once("#[cfg(test)]")
            .map(|(production, _)| production)
            .unwrap_or(full_src);

        assert!(
            !src.contains("PERRI_BIN"),
            "the PERRI_BIN env var indirection for a `perri` binary should be gone"
        );

        for (idx, _) in src.match_indices("Command::new") {
            let window = src.get(idx..(idx + 200).min(src.len())).unwrap_or("");
            assert!(
                !window.contains("load_pr"),
                "found \"load_pr\" within 200 chars of a Command::new call — \
                 looks like a reintroduced shell-out: {window:?}"
            );
            assert!(
                !window.contains("clear_current_pr"),
                "found \"clear_current_pr\" within 200 chars of a Command::new call — \
                 looks like a reintroduced shell-out: {window:?}"
            );
        }
    }
}
