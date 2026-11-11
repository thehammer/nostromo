//! Opening a tracker item's link (`ClientMsg::TrackerOpenLink`, T6).
//!
//! A PR link opens that PR's conversation, a Jira key its ticket and a
//! repo-relative file path (`index.md:42`) the file at its line: each through
//! the same handler as the `nostromo.show` tool, so placement, frames and the
//! detail-region focus are exactly a show's. Nothing here names the
//! transcript, and nothing here can reach a shell: the link comes from the
//! daemon's own copy of the board, and its kind decides which of three views
//! is requested. Every other link (Sentry, run, URL) is the client's to open.

use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;
use crate::mcp::tools::show;
use crate::tracker::{Binding, Link, LinkKind};

/// Opens link `link_index` of item `item_id` of the board bound to `tag`.
/// `Err` says why nothing opened (a short code, never item text).
pub async fn open_link(
    state: &McpSharedState,
    tag: &str,
    item_id: &str,
    link_index: usize,
) -> Result<(), String> {
    let Some(daemon) = &state.daemon else {
        return Err("not_supported".to_string());
    };
    let (link, binding) = daemon
        .tracker
        .link_of(tag, item_id, link_index)
        .ok_or_else(|| "unknown_link".to_string())?;
    let args = show_args(&link, binding.as_ref())?;
    let reply = show::show(state, &args, Some(tag)).await;
    match reply.get("error").and_then(Value::as_str) {
        Some(error) => Err(error.to_string()),
        None => Ok(()),
    }
}

/// The `nostromo.show` arguments a link opens; `Err` when the link is one the
/// client opens itself, or names nothing the daemon can show.
pub fn show_args(link: &Link, binding: Option<&Binding>) -> Result<Value, String> {
    match link.kind {
        LinkKind::Pr => {
            let (repo, number) = pr_of(link, binding).ok_or_else(|| "unknown_pr".to_string())?;
            Ok(json!({
                "type": "pr_conversation",
                "target": { "repo": repo, "number": number },
            }))
        }
        LinkKind::Jira => {
            let key = jira_key_of(link).ok_or_else(|| "unknown_ticket".to_string())?;
            Ok(json!({
                "type": "ticket",
                "target": { "provider": "jira", "key": key },
            }))
        }
        LinkKind::File => {
            let (path, line) = file_of(&link.text).ok_or_else(|| "unknown_path".to_string())?;
            let mut args = json!({ "type": "file", "target": { "path": path } });
            if let Some(line) = line {
                args["anchor"] = json!({ "kind": "line", "line": line });
            }
            Ok(args)
        }
        LinkKind::Sentry | LinkKind::Run | LinkKind::Url => Err("opened_by_client".to_string()),
    }
}

/// `owner/repo` and number of a PR link: from its GitHub URL, else (`PR #n`
/// with no URL) from the PR the item's CI binding names.
fn pr_of(link: &Link, binding: Option<&Binding>) -> Option<(String, u64)> {
    static URL: OnceLock<Regex> = OnceLock::new();
    static TEXT: OnceLock<Regex> = OnceLock::new();
    let url = URL.get_or_init(|| {
        Regex::new(
            r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)(?:[/?#].*)?$",
        )
        .unwrap()
    });
    if let Some(caps) = link.url.as_deref().and_then(|u| url.captures(u)) {
        return Some((
            caps[1].to_string(),
            caps[2].parse().ok().filter(|n| *n > 0)?,
        ));
    }
    let text = TEXT.get_or_init(|| Regex::new(r"(?i)^PR\s*#?(\d+)$").unwrap());
    let number: u64 = text.captures(&link.text)?[1]
        .parse()
        .ok()
        .filter(|n| *n > 0)?;
    match binding {
        Some(Binding::PrCi { repo, .. }) => Some((repo.clone(), number)),
        _ => None,
    }
}

fn jira_key_of(link: &Link) -> Option<String> {
    static KEY: OnceLock<Regex> = OnceLock::new();
    let key = KEY.get_or_init(|| Regex::new(r"[A-Z][A-Z0-9]+-\d+").unwrap());
    let from_text = key
        .find(&link.text)
        .filter(|m| m.as_str() == link.text.trim());
    from_text
        .or_else(|| link.url.as_deref().and_then(|u| key.find(u)))
        .map(|m| m.as_str().to_string())
}

/// A repo-relative path and the first line of `path[:line[-line]]`. An
/// absolute path, `~`, or a `..` component is refused.
fn file_of(text: &str) -> Option<(String, Option<u32>)> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"^(.+?)(?::(\d+)(?:-\d+)?)?$").unwrap());
    let caps = re.captures(text.trim())?;
    let path = caps[1].to_string();
    if path.starts_with('/')
        || path.starts_with('~')
        || path.split('/').any(|part| part == "..")
        || path.contains('\\')
    {
        return None;
    }
    let line = caps.get(2).and_then(|l| l.as_str().parse().ok());
    Some((path, line))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link(text: &str, url: Option<&str>) -> Link {
        Link::new(text, url)
    }

    #[test]
    fn a_pr_link_opens_the_conversation_of_the_pr_its_url_names() {
        let args = show_args(
            &link(
                "PR #253",
                Some("https://github.com/Carefeed/admin-portal/pull/253"),
            ),
            None,
        )
        .unwrap();
        assert_eq!(
            args,
            json!({"type":"pr_conversation","target":{"repo":"Carefeed/admin-portal","number":253}})
        );
    }

    #[test]
    fn a_pr_link_without_a_url_needs_the_binding_to_name_the_repo() {
        let bare = link("PR #9", None);
        assert_eq!(show_args(&bare, None), Err("unknown_pr".to_string()));
        let binding = Binding::parse("pr.ci/acme/web#9").unwrap();
        assert_eq!(
            show_args(&bare, Some(&binding)).unwrap()["target"],
            json!({"repo":"acme/web","number":9})
        );
    }

    #[test]
    fn a_jira_key_opens_the_ticket_and_a_file_path_opens_the_file_at_its_line() {
        assert_eq!(
            show_args(&link("CORE-2841", None), None).unwrap(),
            json!({"type":"ticket","target":{"provider":"jira","key":"CORE-2841"}})
        );
        assert_eq!(
            show_args(&link("index.md:42", None), None).unwrap(),
            json!({"type":"file","target":{"path":"index.md"},"anchor":{"kind":"line","line":42}})
        );
        assert_eq!(
            show_args(&link("src/lib.rs", None), None).unwrap(),
            json!({"type":"file","target":{"path":"src/lib.rs"}})
        );
    }

    #[test]
    fn other_links_are_the_clients_and_paths_cannot_escape_the_repo() {
        for l in [
            link("Sentry PORTAL-1F2", None),
            link("run 9912", None),
            link("https://example.com/x", None),
        ] {
            assert_eq!(show_args(&l, None), Err("opened_by_client".to_string()));
        }
        for path in ["../secrets.md", "/etc/hosts.md", "~/x.md", "a/../../b.md"] {
            assert!(
                show_args(&link(path, None), None).is_err(),
                "{path} must not open"
            );
        }
    }
}
