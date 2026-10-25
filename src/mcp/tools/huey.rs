//! Huey-scoped MCP tool handlers.
//!
//! - `huey.get_state()` — whether Huey is on, its setup state, report time and
//!   the paths it keeps files at (paths only: nothing is read or created).

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

pub fn get_state(state: &McpSharedState) -> Value {
    let Some(handle) = &state.huey else {
        return json!({
            "error": "huey_unavailable",
            "message": "Huey is not running in this process",
        });
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
        let src = HueyEngine::spawn(HueyDeps::production(
            root.path().to_path_buf(),
            HueyConfig::default(),
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
