//! Helpers for shelling out to the `perri` CLI from the daemon's `PerriAction`
//! IPC handler.
//!
//! Mirrors the pattern in `src/mother/mod.rs` (`run_mother` + `validate_job_id`).

use anyhow::{bail, Context, Result};

/// `PERRI_BIN` env var overrides the default `perri` binary name.
const PERRI_BIN_ENV: &str = "PERRI_BIN";

fn perri_bin() -> String {
    std::env::var(PERRI_BIN_ENV).unwrap_or_else(|_| "perri".to_owned())
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

/// Execute the appropriate `perri` CLI invocation for the given `action`.
///
/// - `"load_pr"` → `perri load_pr -- <pr_number> <repo>`
/// - `"clear"`   → `perri clear_current_pr`
pub async fn run_perri_action(
    action: &str,
    pr_number: Option<u64>,
    repo: Option<&str>,
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

        other => {
            tracing::warn!(action = other, "unknown PerriAction — ignoring");
        }
    }

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
}
