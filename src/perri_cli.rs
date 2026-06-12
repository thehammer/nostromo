//! Helpers for shelling out to the `perri` CLI and `gh` from the daemon's
//! `PerriAction` IPC handler.
//!
//! Mirrors the pattern in `src/mother/mod.rs` (`run_mother` + `validate_job_id`).

use std::io::Write as _;
use std::path::Path;

use anyhow::{bail, Context, Result};

/// `PERRI_BIN` env var overrides the default `perri` binary name.
const PERRI_BIN_ENV: &str = "PERRI_BIN";

/// `GH_BIN` env var overrides the default `gh` binary name (used for approve).
const GH_BIN_ENV: &str = "GH_BIN";

fn perri_bin() -> String {
    std::env::var(PERRI_BIN_ENV).unwrap_or_else(|_| "perri".to_owned())
}

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

/// Execute the appropriate `perri` CLI or `gh` invocation for the given `action`.
///
/// - `"load_pr"` → `perri load_pr -- <pr_number> <repo>`
/// - `"clear"`   → `perri clear_current_pr`
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
    let bin = perri_bin();

    match action {
        "load_pr" => {
            let number = pr_number
                .filter(|&n| n > 0)
                .with_context(|| "load_pr requires a non-zero pr_number")?;
            let repo = repo.with_context(|| "load_pr requires a repo slug")?;
            validate_repo(repo)?;

            let status = tokio::process::Command::new(&bin)
                .args(["load_pr", "--", &number.to_string(), repo])
                .status()
                .await
                .with_context(|| format!("spawning {bin} load_pr"))?;

            if !status.success() {
                bail!("{bin} load_pr exited with status {status}");
            }
        }

        "clear" => {
            let status = tokio::process::Command::new(&bin)
                .arg("clear_current_pr")
                .status()
                .await
                .with_context(|| format!("spawning {bin} clear_current_pr"))?;

            if !status.success() {
                tracing::warn!(
                    "{bin} clear_current_pr exited with {status} — \
                     the CLI may not support this subcommand yet"
                );
                // Non-fatal: the subcommand may not exist in all perri versions.
            }
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
}
