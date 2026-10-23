//! Which built-in agents this daemon runs (`[agents.<name>]` in config.toml).
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// One `[agents.<name>]` table. Unknown keys are ignored (serde's default),
/// so a later per-agent setting such as Fred's mail provider can be added
/// without breaking older configs or older daemons.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct AgentConfig {
    pub enabled: bool,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self { enabled: true }
    }
}

/// The agents that can be switched off. Mother is not one of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Agent {
    Fred,
    Perri,
    Teri,
}

impl Agent {
    pub const ALL: [Agent; 3] = [Agent::Fred, Agent::Perri, Agent::Teri];

    pub fn name(self) -> &'static str {
        match self {
            Agent::Fred => "fred",
            Agent::Perri => "perri",
            Agent::Teri => "teri",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.name().eq_ignore_ascii_case(s))
    }

    /// The MCP tool-name / pane-source prefix this agent owns ("fred." ...).
    pub fn tool_prefix(self) -> &'static str {
        match self {
            Agent::Fred => "fred.",
            Agent::Perri => "perri.",
            Agent::Teri => "teri.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnabledAgents {
    pub fred: bool,
    pub perri: bool,
    pub teri: bool,
}

impl Default for EnabledAgents {
    fn default() -> Self {
        Self::all()
    }
}

impl EnabledAgents {
    pub const fn all() -> Self {
        Self { fred: true, perri: true, teri: true }
    }

    pub fn is_enabled(&self, a: Agent) -> bool {
        match a {
            Agent::Fred => self.fred,
            Agent::Perri => self.perri,
            Agent::Teri => self.teri,
        }
    }

    /// False only for a tool whose name starts with a disabled agent's prefix.
    pub fn allows_tool(&self, tool: &str) -> bool {
        !Agent::ALL
            .into_iter()
            .any(|a| !self.is_enabled(a) && tool.starts_with(a.tool_prefix()))
    }

    /// Same rule for pane-source names (`perri.list_pr_queue`, ...).
    pub fn allows_source(&self, source: &str) -> bool {
        self.allows_tool(source)
    }

    /// Sorted lowercase names of every running built-in, "mother" always included.
    pub fn wire_names(&self) -> Vec<String> {
        let mut names: Vec<String> = Agent::ALL
            .into_iter()
            .filter(|a| self.is_enabled(*a))
            .map(|a| a.name().to_string())
            .collect();
        names.push("mother".to_string());
        names.sort();
        names
    }

    fn set(&mut self, a: Agent, on: bool) {
        match a {
            Agent::Fred => self.fred = on,
            Agent::Perri => self.perri = on,
            Agent::Teri => self.teri = on,
        }
    }
}

/// Resolve the `[agents]` tables. Returns warnings to log, never an error.
pub fn resolve(tables: &BTreeMap<String, AgentConfig>) -> (EnabledAgents, Vec<String>) {
    let mut enabled = EnabledAgents::all();
    let mut warnings = Vec::new();
    for (name, cfg) in tables {
        if name.eq_ignore_ascii_case("mother") {
            if !cfg.enabled {
                warnings.push("agents.mother cannot be disabled; ignoring enabled = false".to_string());
            }
        } else if let Some(a) = Agent::from_name(name) {
            enabled.set(a, cfg.enabled);
        } else {
            warnings.push(format!(
                "unknown agent `{name}` in [agents]; ignoring (known: fred, perri, teri)"
            ));
        }
    }
    (enabled, warnings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn off() -> AgentConfig {
        AgentConfig { enabled: false }
    }

    #[test]
    fn empty_tables_enable_everything() {
        let (e, w) = resolve(&BTreeMap::new());
        assert_eq!(e, EnabledAgents::all());
        assert!(w.is_empty());
    }

    #[test]
    fn a_disabled_table_disables_only_that_agent() {
        let t = BTreeMap::from([("fred".to_string(), off())]);
        let (e, w) = resolve(&t);
        assert_eq!(e, EnabledAgents { fred: false, perri: true, teri: true });
        assert!(w.is_empty());
    }

    #[test]
    fn mother_cannot_be_disabled_and_warns() {
        let t = BTreeMap::from([("mother".to_string(), off())]);
        let (e, w) = resolve(&t);
        assert_eq!(e, EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("mother"));
    }

    #[test]
    fn mother_enabled_true_is_silent() {
        let t = BTreeMap::from([("mother".to_string(), AgentConfig::default())]);
        assert!(resolve(&t).1.is_empty());
    }

    #[test]
    fn unknown_agents_warn() {
        let t = BTreeMap::from([("bob".to_string(), off())]);
        let (e, w) = resolve(&t);
        assert_eq!(e, EnabledAgents::all());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains("bob"));
    }

    #[test]
    fn allows_tool_denies_only_disabled_prefixes() {
        let e = EnabledAgents { fred: false, perri: true, teri: true };
        assert!(!e.allows_tool("fred.get_state"));
        assert!(e.allows_tool("nostromo.list_views"));
        assert!(e.allows_tool("mother.list_jobs"));
        assert!(e.allows_tool("fredx.foo"));
        assert!(e.allows_tool("perri.list_pr_queue"));
    }

    #[test]
    fn wire_names_always_has_mother_and_is_sorted() {
        let e = EnabledAgents { fred: false, perri: true, teri: false };
        assert_eq!(e.wire_names(), vec!["mother", "perri"]);
        assert_eq!(EnabledAgents::all().wire_names(), vec!["fred", "mother", "perri", "teri"]);
    }

    #[test]
    fn from_name_is_case_insensitive() {
        assert_eq!(Agent::from_name("FrEd"), Some(Agent::Fred));
        assert_eq!(Agent::from_name("nope"), None);
    }
}
