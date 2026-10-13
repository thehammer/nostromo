//! Policy: what counts as a cost increase, what an agent may do on its own,
//! and what an agent declares about itself.

use std::path::{Path, PathBuf};

use super::cost::{effort_rank, family_rank};
use super::ModelTarget;

/// An agent asking for a more expensive model or a higher effort always needs
/// the user's approval, whatever Bishop's posture (resolved decision; this is
/// the one place to change it).
pub const AGENT_UPGRADE_NEEDS_APPROVAL_IN_ALL_POSTURES: bool = true;

/// Env var overriding the directory agent definitions are read from.
pub const AGENTS_DIR_ENV: &str = "NOSTROMO_AGENTS_DIR";

/// How a candidate compares with the current model and effort, by cost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CostChange {
    /// The family rank or the effort rank rises.
    Upgrade,
    /// Something falls and nothing rises.
    Downgrade,
    Same,
}

/// Classify a switch from `current` to `candidate`.
pub fn classify(current: &ModelTarget, candidate: &ModelTarget) -> CostChange {
    let family = family_rank(&candidate.model).cmp(&family_rank(&current.model));
    let effort =
        effort_rank(candidate.effort.as_deref()).cmp(&effort_rank(current.effort.as_deref()));
    use std::cmp::Ordering::*;
    match (family, effort) {
        (Greater, _) | (_, Greater) => CostChange::Upgrade,
        (Less, _) | (_, Less) => CostChange::Downgrade,
        (Equal, Equal) => CostChange::Same,
    }
}

/// The one-line posture warning for choosing `candidate` over `current`, if
/// one applies. Always `None` until the posture-warnings slice fills it in.
pub fn posture_warning(_current: &ModelTarget, _candidate: &ModelTarget) -> Option<String> {
    None
}

/// Where agent definitions live: `$NOSTROMO_AGENTS_DIR`, else `~/.claude/agents`.
pub fn agents_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os(AGENTS_DIR_ENV).filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".claude")
        .join("agents")
}

/// The `model:` an agent declares in its definition's YAML front matter
/// (`~/.claude/agents/<agent>.md`). A plugin-qualified name (`teri:teri`) is
/// looked up by its bare name. A missing file or field gives `None`.
pub fn declared_model(agent: &str) -> Option<String> {
    declared_model_in(&agents_dir(), agent)
}

/// [`declared_model`] reading from `dir`.
pub fn declared_model_in(dir: &Path, agent: &str) -> Option<String> {
    let bare = agent.trim().rsplit(':').next()?.trim();
    if bare.is_empty() || bare.contains('/') || bare.starts_with('.') {
        return None;
    }
    let text = std::fs::read_to_string(dir.join(format!("{bare}.md"))).ok()?;
    front_matter_model(&text)
}

/// Every agent in `dir` that declares a model, as `(agent, model)`.
pub fn declared_models_in(dir: &Path) -> Vec<(String, String)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return vec![];
    };
    let mut out: Vec<(String, String)> = entries
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            if path.extension().and_then(|x| x.to_str()) != Some("md") {
                return None;
            }
            let agent = path.file_stem()?.to_str()?.to_owned();
            let model = front_matter_model(&std::fs::read_to_string(&path).ok()?)?;
            Some((agent, model))
        })
        .collect();
    out.sort();
    out
}

/// `model: inherit` says "use the session's model": it is no model name, and
/// passed to `--model` the CLI would reject it.
fn front_matter_model(text: &str) -> Option<String> {
    let rest = text.strip_prefix("---")?;
    let rest = rest
        .strip_prefix('\n')
        .or_else(|| rest.strip_prefix("\r\n"))?;
    let end = rest.find("\n---")?;
    let yaml: serde_yaml::Value = serde_yaml::from_str(&rest[..end]).ok()?;
    let model = yaml.get("model")?.as_str()?.trim();
    (!model.is_empty() && !model.eq_ignore_ascii_case("inherit")).then(|| model.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent_file(dir: &Path, agent: &str, front_matter_model: Option<&str>) {
        let model = front_matter_model.map(|m| format!("model: {m}\n")).unwrap_or_default();
        std::fs::write(
            dir.join(format!("{agent}.md")),
            format!("---\nname: {agent}\ndescription: test agent\n{model}---\nYou are {agent}.\n"),
        )
        .unwrap();
    }

    #[test]
    fn an_agent_declares_the_model_its_front_matter_names() {
        let dir = tempfile::tempdir().unwrap();
        agent_file(dir.path(), "tester", Some("haiku"));
        agent_file(dir.path(), "silent", None);

        assert_eq!(declared_model_in(dir.path(), "tester").as_deref(), Some("haiku"));
        assert_eq!(declared_model_in(dir.path(), "plugin:tester").as_deref(), Some("haiku"), "looked up by its bare name");
        assert_eq!(declared_model_in(dir.path(), "silent"), None);
        assert_eq!(declared_model_in(dir.path(), "missing"), None);
    }

    #[test]
    fn model_inherit_declares_nothing_whatever_its_case() {
        let dir = tempfile::tempdir().unwrap();
        for (agent, value) in [
            ("lower", "inherit"),
            ("title", "Inherit"),
            ("upper", "INHERIT"),
            ("quoted", "\"inherit\""),
            ("padded", "'  inherit '"),
        ] {
            agent_file(dir.path(), agent, Some(value));
            assert_eq!(
                declared_model_in(dir.path(), agent),
                None,
                "`model: {value}` means \"use the parent's model\", which is no model of its own"
            );
        }
    }

    #[test]
    fn the_list_of_declared_models_leaves_out_agents_that_inherit() {
        let dir = tempfile::tempdir().unwrap();
        agent_file(dir.path(), "opinionated", Some("opus"));
        agent_file(dir.path(), "inheriting", Some("inherit"));
        agent_file(dir.path(), "silent", None);

        let declared = declared_models_in(dir.path());

        assert_eq!(declared, [("opinionated".to_owned(), "opus".to_owned())]);
    }
}
