//! Per-caller tool withdrawal (W5 — curated-agent-views, B8/D7).
//!
//! The MCP tool surface is flat today: `tool_descriptors()` takes no
//! arguments, `tools/list` takes no caller, and every client sees the identical
//! list. This module is the narrowing the PRD asks for — *scoped to one
//! caller*, because "a global withdrawal would silently break three agents this
//! PRD never examined".
//!
//! ## Keyed on the agent name, not the tag
//!
//! Caller identity is already known: the MCP server reads a pre-RPC `Hello`
//! frame and threads its `pty_id` into every request, and in the daemon that
//! `pty_id` *is* the focus tag. Resolving the tag's **agent name** through the
//! focus registry — exactly as `get_self` already does — is what makes a
//! dispatched focus like `perri-a1b2c3d4` covered by a policy that says
//! `perri`, with no prefix-matching hack.
//!
//! ## Both halves, because listing alone is advisory
//!
//! `tools/list` filters and `tools/call` refuses. Filtering the list alone
//! would only *discourage* a tool — an agent can call a name it never saw, and
//! a drifting prompt will. The call gate is the half that actually holds; the
//! list filter is what stops the tool being suggested in the first place.
//!
//! ## Shipped inert, on purpose
//!
//! **The compiled-in default is empty.** Perri's prompt still drives
//! `apply_layout` and `refresh_pane_content` today, and that prompt lives in
//! another repository (W8). Shipping a non-empty default here would break her
//! review flow for as long as it took W8 to land. So this wedge ships the
//! mechanism and its tests; the operator arms it by writing one file, which
//! also leaves a one-file kill switch.
//!
//! ## Failing open
//!
//! A caller whose agent name can't be resolved — no `Hello` `pty_id`, an
//! unknown tag, a registry that hasn't caught up — gets the **unfiltered**
//! surface, and so does everyone if the policy file is unreadable or
//! malformed. The threat model here is a prompt drifting, not an adversary; the
//! alternative is a daemon-registry hiccup silently disarming every agent at
//! once.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::mcp::state::McpSharedState;

/// The whole policy: agent name → what that agent may not reach.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct ToolPolicy {
    #[serde(default)]
    pub agents: BTreeMap<String, AgentPolicy>,
}

/// One agent's denials.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct AgentPolicy {
    /// Fully-qualified tool names this agent may not list or call.
    #[serde(default)]
    pub deny: Vec<String>,
}

impl ToolPolicy {
    /// True when the policy denies nothing to anyone — the compiled-in
    /// default, and the state every deployment is in until an operator writes
    /// the file. Callers use it to skip agent-name resolution entirely.
    pub fn is_empty(&self) -> bool {
        self.agents.values().all(|a| a.deny.is_empty())
    }

    /// The tools `agent_name` may not reach. Empty for an unresolved caller —
    /// see the module doc on failing open.
    pub fn denied_for(&self, agent_name: Option<&str>) -> &[String] {
        agent_name
            .and_then(|n| self.agents.get(n))
            .map(|a| a.deny.as_slice())
            .unwrap_or(&[])
    }

    /// Whether `agent_name` is denied `tool`.
    pub fn denies(&self, agent_name: Option<&str>, tool: &str) -> bool {
        self.denied_for(agent_name).iter().any(|t| t == tool)
    }
}

/// Parse a `tool-policy.yaml` document. A malformed document yields the empty
/// policy rather than an error: see the module doc on failing open.
pub fn parse(yaml: &str) -> ToolPolicy {
    serde_yaml::from_str(yaml).unwrap_or_default()
}

/// Load the policy from `<dir>/tool-policy.yaml`, or the empty compiled-in
/// default when the file is absent. Read fresh on every call — the same
/// no-caching discipline `~/.nostromo/layouts/<name>.yaml` and
/// `~/.nostromo/views.yaml` already follow, so arming or disarming the policy
/// takes effect on the next call with no restart.
pub fn load_from_dir(dir: &Path) -> ToolPolicy {
    match std::fs::read_to_string(dir.join("tool-policy.yaml")) {
        Ok(text) => parse(&text),
        Err(_) => ToolPolicy::default(),
    }
}

/// Load the policy from `~/.nostromo/tool-policy.yaml`.
pub fn load() -> ToolPolicy {
    load_from_dir(&crate::mcp::views::config::nostromo_dir())
}

/// The caller's Claude agent name, resolved from the `Hello` frame's `pty_id`.
///
/// Daemon-hosted: the `pty_id` is the focus tag, and the focus registry maps it
/// to an `agent_name` — the same two steps `get_self` takes, so a dispatched
/// focus (`perri-a1b2c3d4`) resolves to `perri` without this module knowing
/// anything about tag shapes. TUI-hosted: the PTY registry's `view_id` is the
/// nearest equivalent.
///
/// `None` means "could not resolve", which every caller must read as
/// "unfiltered".
pub async fn resolve_agent_name(state: &McpSharedState, pty_id: Option<&str>) -> Option<String> {
    let pty_id = pty_id.filter(|s| !s.is_empty())?;

    if let Some(daemon) = &state.daemon {
        let mgr = daemon.session_mgr.lock().ok()?;
        return mgr
            .focus_registry()
            .into_iter()
            .find(|f| f.tag == pty_id)
            .map(|f| f.agent_name);
    }

    let ptys = state.ptys.read().await;
    ptys.get(pty_id).map(|p| p.view_id.to_string())
}

/// Filter `descriptors` down to what a caller denied `denied` may see.
///
/// A no-op — and returns the vector untouched — when nothing is denied, which
/// is what keeps every other agent's `tools/list` byte-for-byte unchanged by
/// the mere presence of a policy denying someone else.
pub fn filter_descriptors(descriptors: Vec<Value>, denied: &[String]) -> Vec<Value> {
    if denied.is_empty() {
        return descriptors;
    }
    descriptors
        .into_iter()
        .filter(|d| {
            d.get("name")
                .and_then(|v| v.as_str())
                .map(|name| !denied.iter().any(|t| t == name))
                .unwrap_or(true)
        })
        .collect()
}

/// `~/.nostromo/tool-policy.yaml` — where an operator arms the withdrawal.
pub fn policy_path() -> PathBuf {
    crate::mcp::views::config::nostromo_dir().join("tool-policy.yaml")
}

/// The policy W8 installs, documented here so the mechanism and its intended
/// content live together. **Not** the compiled-in default — see the module
/// doc; shipping this armed would break Perri before her prompt is rewritten.
pub const INTENDED_PERRI_POLICY: &str = "\
agents:
  perri:
    deny:
      - nostromo.set_pane_content
      - nostromo.set_pane_layout
      - nostromo.set_pane_focus
      - nostromo.create_pane
      - nostromo.reset_panes
      - nostromo.apply_layout
      - nostromo.refresh_pane_content
";

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn perri_policy() -> ToolPolicy {
        parse(INTENDED_PERRI_POLICY)
    }

    // ── 1. the compiled-in default is inert ───────────────────────────────────

    #[test]
    fn the_compiled_in_default_denies_nothing_to_anyone() {
        let policy = ToolPolicy::default();
        assert!(policy.is_empty());
        assert!(!policy.denies(Some("perri"), "nostromo.apply_layout"));
        assert!(policy.denied_for(Some("perri")).is_empty());
    }

    #[test]
    fn an_absent_policy_file_resolves_to_the_empty_default() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load_from_dir(dir.path()), ToolPolicy::default());
    }

    // ── 2. the intended Perri policy ──────────────────────────────────────────

    #[test]
    fn the_intended_perri_policy_denies_every_raw_pane_tool_and_nothing_else() {
        let policy = perri_policy();
        for tool in [
            "nostromo.set_pane_content",
            "nostromo.set_pane_layout",
            "nostromo.set_pane_focus",
            "nostromo.create_pane",
            "nostromo.reset_panes",
            "nostromo.apply_layout",
            "nostromo.refresh_pane_content",
        ] {
            assert!(policy.denies(Some("perri"), tool), "{tool} must be denied");
        }
        for tool in [
            "nostromo.show",
            "nostromo.get_self",
            "perri.list_pr_queue",
            "perri.load_pr",
        ] {
            assert!(!policy.denies(Some("perri"), tool), "{tool} must stay");
        }
    }

    #[test]
    fn a_policy_denying_perri_denies_nothing_to_mother_fred_or_teri() {
        let policy = perri_policy();
        for agent in ["mother", "fred", "teri", "cody"] {
            assert!(policy.denied_for(Some(agent)).is_empty(), "{agent}");
            assert!(
                !policy.denies(Some(agent), "nostromo.apply_layout"),
                "{agent}"
            );
        }
    }

    // ── 3. failing open ───────────────────────────────────────────────────────

    #[test]
    fn an_unresolved_caller_is_denied_nothing() {
        assert!(perri_policy().denied_for(None).is_empty());
        assert!(!perri_policy().denies(None, "nostromo.apply_layout"));
    }

    #[test]
    fn a_malformed_policy_file_denies_nothing_rather_than_denying_everything() {
        assert_eq!(parse("agents: [not, a, map]"), ToolPolicy::default());
        assert_eq!(parse("!!!"), ToolPolicy::default());
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("tool-policy.yaml"), "agents: 42").unwrap();
        assert_eq!(load_from_dir(dir.path()), ToolPolicy::default());
    }

    // ── 4. loading + no caching ───────────────────────────────────────────────

    #[test]
    fn an_on_disk_policy_is_re_read_on_every_call_so_arming_needs_no_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tool-policy.yaml");
        assert!(load_from_dir(dir.path()).is_empty());

        std::fs::write(&path, INTENDED_PERRI_POLICY).unwrap();
        assert!(load_from_dir(dir.path()).denies(Some("perri"), "nostromo.apply_layout"));

        std::fs::remove_file(&path).unwrap();
        assert!(load_from_dir(dir.path()).is_empty(), "and disarming too");
    }

    // ── 5. descriptor filtering ───────────────────────────────────────────────

    fn descriptors() -> Vec<Value> {
        vec![
            json!({"name": "nostromo.get_self"}),
            json!({"name": "nostromo.apply_layout"}),
            json!({"name": "nostromo.show"}),
        ]
    }

    #[test]
    fn filtering_with_nothing_denied_returns_the_list_untouched() {
        assert_eq!(filter_descriptors(descriptors(), &[]), descriptors());
    }

    #[test]
    fn filtering_removes_exactly_the_denied_tools() {
        let denied = vec!["nostromo.apply_layout".to_string()];
        let filtered = filter_descriptors(descriptors(), &denied);
        let names: Vec<&str> = filtered
            .iter()
            .map(|d| d["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["nostromo.get_self", "nostromo.show"]);
    }

    #[test]
    fn filtering_a_name_no_tool_has_removes_nothing() {
        let denied = vec!["nostromo.nonexistent".to_string()];
        assert_eq!(filter_descriptors(descriptors(), &denied), descriptors());
    }
}
