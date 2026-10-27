//! Huey-scoped MCP tool handlers.
//!
//! - `huey.get_state()` — whether Huey is on, its setup state, report time and
//!   the paths it keeps files at (paths only: nothing is read or created).
//! - `huey.check_project({project, kind, name|term|feature})` — one read-only
//!   probe of a project (A5). For the curating session (`huey-run`) it acts
//!   on the run in progress and is recorded in that run's digest; for anyone
//!   else it answers against the code root and records nothing.
//! - `huey.publish_report(<publish>)` — the curating session's report (A4).
//!   Only the `huey-run` caller reaches it (the dispatch refuses everyone else).

use serde_json::{json, Value};

use crate::huey::curate::HUEY_RUN_TAG;
use crate::mcp::state::McpSharedState;

fn unavailable() -> Value {
    json!({
        "error": "huey_unavailable",
        "message": "Huey is not running in this process",
    })
}

pub async fn check_project(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(handle) = &state.huey else {
        return unavailable();
    };
    if pty_id == Some(HUEY_RUN_TAG) {
        handle.curate_bridge().check_project(args).await
    } else {
        handle.check_project(args).await
    }
}

pub async fn publish_report(state: &McpSharedState, args: &Value) -> Value {
    match &state.huey {
        Some(handle) => handle.curate_bridge().publish(args).await,
        None => unavailable(),
    }
}

pub fn get_state(state: &McpSharedState) -> Value {
    let Some(handle) = &state.huey else {
        return unavailable();
    };
    let paths = handle.paths();
    json!({
        "enabled": state.enabled_agents.huey,
        "setup_state": handle.setup_state().as_str(),
        "report_time": handle.config().report_time.format("%H:%M").to_string(),
        "paths": {
            "interests": paths.interests().display().to_string(),
            "sources": paths.sources_toml().display().to_string(),
            "reports": paths.reports_dir().display().to_string(),
        },
        "last_run": null,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::huey::{HueyConfig, HueyDeps, HueyEngine};

    #[tokio::test]
    async fn get_state_reports_an_unset_up_machine_without_creating_anything() {
        let root = tempfile::tempdir().unwrap();
        let mut state = McpSharedState::for_test();
        let context = crate::huey::context::ContextEnv::for_home(
            root.path(),
            root.path().join("code"),
            root.path().to_path_buf(),
            "test".into(),
        );
        let src = HueyEngine::spawn(HueyDeps::new(
            root.path().to_path_buf(),
            HueyConfig::default(),
            context,
        ));
        state.huey = Some(src.handle);
        let v = get_state(&state);
        assert_eq!(v["enabled"], true);
        assert_eq!(v["setup_state"], "not_set_up");
        assert_eq!(v["report_time"], "06:30");
        assert!(v["paths"]["interests"]
            .as_str()
            .unwrap()
            .ends_with("huey/interests.md"));
        assert!(v["last_run"].is_null());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
