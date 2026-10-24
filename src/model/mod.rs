//! Model switching: the daemon owns which Claude model (and effort) each
//! focus's session runs on.
//!
//! - [`catalog`]: the families the installed CLI offers (`initialize` probe).
//! - [`cost`]: static cost order of families and efforts.
//! - [`store`]: per-focus records and per-agent defaults.
//! - [`notes`]: the per-session ledger of transcript notes.
//! - [`policy`]: upgrade classification, posture warning, agent front matter.
//! - [`activity`]: audit lines in `~/.claude/activity.jsonl`.
//!
//! The live switch itself (control requests, queue discipline) runs in
//! `ipc::session_manager`, which owns the session processes.

pub mod activity;
pub mod catalog;
pub mod cost;
pub mod hub;
pub mod notes;
pub mod policy;
pub mod store;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use catalog::{family_display, ModelCatalog};

/// A model and effort to run on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ModelTarget {
    /// A family alias (`"opus"`) or a full model name.
    pub model: String,
    /// Explicit effort; `None` is the model's default.
    #[serde(default)]
    pub effort: Option<String>,
}

/// Who asked for a model change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Actor {
    /// The user, through the app.
    User,
    /// A script driving the app-control socket.
    Script,
    /// An agent asking for its own focus.
    Agent { name: String, reason: String },
}

impl Actor {
    /// The attribution at the end of a note: `by you`, `by script`,
    /// `by Claudia: "<reason>"`.
    pub fn by(&self) -> String {
        match self {
            Actor::User => "by you".to_owned(),
            Actor::Script => "by script".to_owned(),
            Actor::Agent { name, reason } => format!("by {}: \"{reason}\"", family_display(name)),
        }
    }

    /// The `actor` field of activity lines and `last_request`.
    pub fn wire(&self) -> String {
        match self {
            Actor::User => "user".to_owned(),
            Actor::Script => "script".to_owned(),
            Actor::Agent { name, .. } => format!("agent:{name}"),
        }
    }

    /// The agent's stated reason, if any.
    pub fn reason(&self) -> Option<String> {
        match self {
            Actor::Agent { reason, .. } => Some(reason.clone()),
            Actor::User | Actor::Script => None,
        }
    }

    /// The actor a socket peer named: `script` is the app-control client;
    /// anything else (or nothing) is the user.
    pub fn from_wire(actor: Option<&str>) -> Self {
        match actor {
            Some("script") => Actor::Script,
            _ => Actor::User,
        }
    }
}

/// Where the model state of one daemon lives. Everything sits beside the
/// daemon's session-id store, so a test that gives the session manager a
/// private store gets private model files too.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelPaths {
    pub focus_models: PathBuf,
    pub defaults: PathBuf,
    pub notes_dir: PathBuf,
    pub catalog: PathBuf,
}

impl ModelPaths {
    /// The model files in the directory holding `store_path`.
    pub fn beside(store_path: &Path) -> Self {
        let dir = store_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        Self {
            focus_models: dir.join("focus-models.json"),
            defaults: dir.join("model-defaults.json"),
            notes_dir: dir.join("session-notes"),
            catalog: dir.join("model-catalog.json"),
        }
    }
}

/// How a model reads in a note: `"Opus"` for a family (also for a full name
/// of a known family, e.g. `claude-sonnet-4-6` → `"Sonnet"`), else the name.
pub fn display_model(model: &str, catalog: &ModelCatalog) -> String {
    if model == "default" {
        return "Default".to_owned();
    }
    if let Some(entry) = catalog.family(model) {
        return family_display(&entry.value);
    }
    if let Some(entry) = catalog.family_for_resolved(model) {
        return family_display(&entry.value);
    }
    match cost::known_family_of(model) {
        Some(family) => family_display(family),
        None => model.to_owned(),
    }
}

/// Is a session reporting `running` on the model `asked` for? A full name
/// must match exactly; a family alias matches any model of that family (the
/// alias may resolve differently in a CLI updated since the session started).
/// `None` when it can't be told (an unknown name and no catalogue entry).
pub fn runs_as(asked: &str, running: &str, catalog: &ModelCatalog) -> Option<bool> {
    if asked.starts_with("claude-") {
        return Some(asked == running);
    }
    let family = catalog
        .family_for_resolved(running)
        .map(|e| e.value.as_str())
        .or_else(|| cost::known_family_of(running));
    match family {
        Some(family) => Some(family == asked),
        None => catalog.resolved(asked).map(|resolved| resolved == running),
    }
}

/// `"Opus"`, or `"Opus · effort high"` when `with_effort`.
pub fn label(target: &ModelTarget, with_effort: bool, catalog: &ModelCatalog) -> String {
    let model = display_model(&target.model, catalog);
    if with_effort {
        format!(
            "{model} · effort {}",
            target.effort.as_deref().unwrap_or("default")
        )
    } else {
        model
    }
}

/// Note texts, exactly as the PRD words them.
pub mod copy {
    use super::{label, Actor, ModelCatalog, ModelTarget};

    /// The target as named in a note: with its effort when the effort changes.
    fn target_label(from: &ModelTarget, to: &ModelTarget, catalog: &ModelCatalog) -> String {
        label(to, from.effort != to.effort, catalog)
    }

    /// "Model changed to Opus (from Sonnet) by you."
    pub fn changed(
        from: &ModelTarget,
        to: &ModelTarget,
        actor: &Actor,
        catalog: &ModelCatalog,
    ) -> String {
        format!(
            "Model changed to {} (from {}) {}.",
            target_label(from, to, catalog),
            label(from, false, catalog),
            actor.by()
        )
    }

    /// "Switching to Opus after this turn"
    pub fn pending(from: &ModelTarget, to: &ModelTarget, catalog: &ModelCatalog) -> String {
        format!(
            "Switching to {} after this turn",
            target_label(from, to, catalog)
        )
    }

    /// "Couldn't switch to Opus: <reason>. Still on Sonnet."
    pub fn failed(
        from: &ModelTarget,
        to: &ModelTarget,
        reason: &str,
        catalog: &ModelCatalog,
    ) -> String {
        format!(
            "Couldn't switch to {}: {}. Still on {}.",
            target_label(from, to, catalog),
            reason.trim_end_matches('.'),
            label(from, false, catalog)
        )
    }

    /// "Model set to Opus; takes effect when the session starts."
    pub fn stored(from: Option<&ModelTarget>, to: &ModelTarget, catalog: &ModelCatalog) -> String {
        let with_effort = from
            .map(|f| f.effort != to.effort)
            .unwrap_or(to.effort.is_some());
        format!(
            "Model set to {}; takes effect when the session starts.",
            label(to, with_effort, catalog)
        )
    }

    /// "Asked for Opus; the session is running Sonnet (<reason>)."
    pub fn mismatch(
        asked: &str,
        running: &str,
        reason: Option<&str>,
        catalog: &ModelCatalog,
    ) -> String {
        let asked = super::display_model(asked, catalog);
        let running = super::display_model(running, catalog);
        match reason.map(str::trim).filter(|r| !r.is_empty()) {
            Some(r) => format!("Asked for {asked}; the session is running {running} ({r})."),
            None => format!("Asked for {asked}; the session is running {running}."),
        }
    }

    /// "Opus is no longer available; this focus now uses Sonnet."
    pub fn unavailable(gone: &str, now: &str, catalog: &ModelCatalog) -> String {
        format!(
            "{} is no longer available; this focus now uses {}.",
            super::display_model(gone, catalog),
            super::display_model(now, catalog)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use catalog::ModelEntry;

    fn catalog() -> ModelCatalog {
        let row = |value: &str, resolved: &str| ModelEntry {
            value: value.into(),
            resolved_model: Some(resolved.into()),
            ..ModelEntry::default()
        };
        ModelCatalog::from_rows(
            vec![
                row("sonnet", "claude-sonnet-5-5"),
                row("opus", "claude-opus-5-5"),
            ],
            chrono::Utc::now(),
        )
    }

    #[test]
    fn a_family_matches_any_model_of_that_family_even_one_a_newer_cli_no_longer_resolves_to() {
        let c = catalog();
        assert_eq!(runs_as("sonnet", "claude-sonnet-5-5", &c), Some(true));
        // A session started before a CLI update still runs the older Sonnet.
        assert_eq!(runs_as("sonnet", "claude-sonnet-4-6", &c), Some(true));
        assert_eq!(runs_as("opus", "claude-sonnet-5-5", &c), Some(false));
    }

    #[test]
    fn a_full_name_must_match_exactly() {
        let c = catalog();
        assert_eq!(
            runs_as("claude-sonnet-4-6", "claude-sonnet-4-6", &c),
            Some(true)
        );
        assert_eq!(
            runs_as("claude-sonnet-4-6", "claude-sonnet-5-5", &c),
            Some(false)
        );
    }

    #[test]
    fn an_unknown_family_with_no_catalogue_entry_cannot_be_judged() {
        assert_eq!(
            runs_as("zeta", "claude-zeta-1", &ModelCatalog::default()),
            None
        );
    }
}
