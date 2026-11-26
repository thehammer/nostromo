//! Who owns a repository, for the personal-host rule (W13, S5): read from a
//! GitHub URL (a git remote, or a pull request's), never from the network.

use std::path::Path;
use std::time::Duration;

/// A `github.com` repository's owner and bare name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    pub owner: String,
    pub repo: String,
}

const PREFIXES: &[&str] = &[
    "https://github.com/",
    "http://github.com/",
    "ssh://git@github.com/",
    "git://github.com/",
    "git@github.com:",
];

/// `owner/repo` from a `github.com` remote URL (`https`, `ssh`, `git`, or the
/// `git@github.com:` form) or from a pull-request URL
/// (`https://github.com/OWNER/REPO/pull/N`). Another host, or anything that
/// does not parse, is `None`: the owner is unknown.
pub fn parse_github_url(url: &str) -> Option<Remote> {
    let url = url.trim();
    // `https://user@github.com/...` is the same host.
    let url = url
        .strip_prefix("https://")
        .and_then(|rest| rest.split_once('@'))
        .filter(|(user, _)| !user.contains('/'))
        .map(|(_, rest)| format!("https://{rest}"))
        .unwrap_or_else(|| url.to_string());
    let rest = PREFIXES.iter().find_map(|p| url.strip_prefix(p))?;
    let mut parts = rest.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?.trim_end_matches(".git");
    let owner_ok = (1..=39).contains(&owner.len())
        && owner
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-');
    let repo_ok = (1..=100).contains(&repo.len())
        && repo
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-');
    (owner_ok && repo_ok).then(|| Remote {
        owner: owner.to_string(),
        repo: repo.to_string(),
    })
}

/// The `origin` remote of the repository at `path`, read locally with
/// `git remote get-url origin` (no network). No repository, no `origin`, a
/// slow `git`, or another host: `None`.
pub async fn origin_remote(path: &Path) -> Option<Remote> {
    let output = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::process::Command::new("git")
            .arg("-C")
            .arg(path)
            .args(["remote", "get-url", "origin"])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_github_url(std::str::from_utf8(&output.stdout).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote(owner: &str, repo: &str) -> Option<Remote> {
        Some(Remote {
            owner: owner.into(),
            repo: repo.into(),
        })
    }

    #[test]
    fn parses_the_remote_forms_git_uses() {
        for url in [
            "https://github.com/thehammer/nostromo.git",
            "https://github.com/thehammer/nostromo",
            "git@github.com:thehammer/nostromo.git",
            "ssh://git@github.com/thehammer/nostromo.git",
            "https://token@github.com/thehammer/nostromo.git\n",
        ] {
            assert_eq!(parse_github_url(url), remote("thehammer", "nostromo"), "{url}");
        }
    }

    #[test]
    fn parses_a_pull_request_url() {
        assert_eq!(
            parse_github_url("https://github.com/Carefeed/admin-portal/pull/4821"),
            remote("Carefeed", "admin-portal")
        );
    }

    #[test]
    fn another_host_or_a_malformed_url_has_no_owner() {
        for url in [
            "https://gitlab.com/thehammer/nostromo.git",
            "https://github.com.evil.example/thehammer/nostromo",
            "https://github.com/",
            "https://github.com/only-owner",
            "https://github.com/bad owner/repo",
            "https://github.com/owner/re po",
            "",
        ] {
            assert_eq!(parse_github_url(url), None, "{url}");
        }
    }
}
