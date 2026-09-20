//! Per-tool-call summary derivation for ambient activity events.
//!
//! `summarize` turns a raw `(tool_name, tool_input)` pair — as carried by a
//! Claude Code `PostToolUse` hook payload — into a short, display-ready,
//! secret-safe string. It never includes the raw `tool_input` JSON verbatim;
//! see `no_raw_tool_input_leaks_into_any_summary` below, a hard PRD
//! requirement.

use crate::activity::redact;

/// Hard cap on a summary's length in `char`s, including any ellipsis marker.
/// Callers may further truncate for display, but `summarize` itself never
/// exceeds this.
pub const MAX_SUMMARY_LEN: usize = 120;

/// Derive a bounded, human-readable, redacted summary for one tool call.
///
/// - `Read`/`Write`/`Edit` → the `file_path` (or `path`) field.
/// - `Grep` → the `pattern` field (plus a short `glob`, if present).
/// - `Glob` → the `pattern` field.
/// - `Bash` → the `command` field, passed through [`redact::scrub`].
/// - `Task` → the `subagent_type` field plus a clipped `description`.
/// - `WebFetch` → the `url` field's host only — path and query are dropped
///   entirely (a query string is a common place for a leaked token).
/// - anything else → the tool name plus a clipped first string field found
///   in `tool_input`.
///
/// Never includes `tool_input` verbatim as raw JSON.
pub fn summarize(tool_name: &str, tool_input: &serde_json::Value) -> String {
    let raw = match tool_name {
        "Read" | "Write" | "Edit" => path_field(tool_input).unwrap_or_default(),
        "Grep" => grep_summary(tool_input),
        "Glob" => str_field(tool_input, "pattern").unwrap_or_default(),
        "Bash" => {
            let command = str_field(tool_input, "command").unwrap_or_default();
            redact::scrub(&command)
        }
        "Task" => task_summary(tool_input),
        "WebFetch" => web_fetch_host(tool_input),
        other => fallback_summary(other, tool_input),
    };
    clip(&raw, MAX_SUMMARY_LEN)
}

/// `file_path`, falling back to `path`.
fn path_field(tool_input: &serde_json::Value) -> Option<String> {
    str_field(tool_input, "file_path").or_else(|| str_field(tool_input, "path"))
}

fn str_field(tool_input: &serde_json::Value, key: &str) -> Option<String> {
    tool_input.get(key).and_then(|v| v.as_str()).map(str::to_string)
}

fn grep_summary(tool_input: &serde_json::Value) -> String {
    let pattern = str_field(tool_input, "pattern").unwrap_or_default();
    match str_field(tool_input, "glob") {
        Some(glob) if glob.len() <= 40 => format!("{pattern} ({glob})"),
        _ => pattern,
    }
}

fn task_summary(tool_input: &serde_json::Value) -> String {
    let subagent_type = str_field(tool_input, "subagent_type").unwrap_or_default();
    let description = str_field(tool_input, "description").unwrap_or_default();
    format!("{subagent_type}: {description}")
}

/// The host only — path and query are dropped entirely (a query string is a
/// common place for a leaked token).
fn web_fetch_host(tool_input: &serde_json::Value) -> String {
    let url = str_field(tool_input, "url").unwrap_or_default();
    match url::Url::parse(&url) {
        Ok(parsed) => parsed.host_str().map(str::to_string).unwrap_or_default(),
        Err(_) => String::new(),
    }
}

/// Unknown tool: the tool name plus a clipped first string field found in
/// `tool_input` — never the raw JSON object.
fn fallback_summary(tool_name: &str, tool_input: &serde_json::Value) -> String {
    let first_string = tool_input.as_object().and_then(|obj| {
        obj.values().find_map(|v| v.as_str().map(str::to_string))
    });
    match first_string {
        Some(s) => format!("{tool_name}: {s}"),
        None => tool_name.to_string(),
    }
}

/// Truncate to `max_chars` `char`s, appending a `…` marker when truncated so
/// the result never exceeds `max_chars` including the marker.
fn clip(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut truncated: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    truncated.push('\u{2026}');
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── 1. file-path tools ────────────────────────────────────────────────────

    #[test]
    fn read_write_edit_summaries_use_the_file_path_field() {
        for tool in ["Read", "Write", "Edit"] {
            let out = summarize(tool, &json!({"file_path": "/Users/hammer/Code/nostromo/src/main.rs"}));
            assert!(
                out.contains("/Users/hammer/Code/nostromo/src/main.rs"),
                "{tool} summary must include the file_path: {out}"
            );
        }
    }

    #[test]
    fn read_write_edit_summaries_fall_back_to_the_path_field() {
        let out = summarize("Read", &json!({"path": "/tmp/notes.md"}));
        assert!(out.contains("/tmp/notes.md"), "must fall back to `path`: {out}");
    }

    // ── 2. Grep / Glob ─────────────────────────────────────────────────────────

    #[test]
    fn grep_summary_includes_pattern_and_short_glob() {
        let out = summarize("Grep", &json!({"pattern": "TODO", "glob": "*.rs"}));
        assert!(out.contains("TODO"), "must include the pattern: {out}");
        assert!(out.contains("*.rs"), "must include the short glob: {out}");
    }

    #[test]
    fn glob_summary_includes_pattern() {
        let out = summarize("Glob", &json!({"pattern": "**/*.md"}));
        assert!(out.contains("**/*.md"));
    }

    // ── 3. Bash summaries are redacted ────────────────────────────────────────

    #[test]
    fn bash_summary_is_redacted_when_the_command_contains_a_secret() {
        let out = summarize(
            "Bash",
            &json!({"command": "curl -H 'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789' https://api.example.com"}),
        );
        assert!(
            !out.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            "Bash summary must be passed through redact::scrub: {out}"
        );
    }

    // ── 4. Task ────────────────────────────────────────────────────────────────

    #[test]
    fn task_summary_includes_subagent_type_and_a_clipped_description() {
        let out = summarize(
            "Task",
            &json!({"subagent_type": "cody", "description": "Implement the activity store"}),
        );
        assert!(out.contains("cody"));
        assert!(out.contains("Implement the activity store"));
    }

    // ── 5. WebFetch — host only, no query secrets ────────────────────────────

    #[test]
    fn web_fetch_summary_is_host_only_and_never_leaks_query_secrets() {
        let out = summarize(
            "WebFetch",
            &json!({"url": "https://api.example.com/data?token=abcdef1234567890&other=1"}),
        );
        assert!(out.contains("api.example.com"), "must include the host: {out}");
        assert!(!out.contains("token="), "path/query must be dropped entirely: {out}");
        assert!(!out.contains("abcdef1234567890"), "query secret must never leak: {out}");
        assert!(!out.contains("/data"), "path must be dropped entirely: {out}");
    }

    // ── 6. unknown tool fallback ───────────────────────────────────────────────

    #[test]
    fn unknown_tool_summary_falls_back_to_tool_name_and_first_string_field() {
        let out = summarize("SomeFutureTool", &json!({"note": "did a thing"}));
        assert!(out.contains("SomeFutureTool"));
        assert!(out.contains("did a thing"));
    }

    // ── 7. hard length cap ─────────────────────────────────────────────────────

    #[test]
    fn summary_never_exceeds_the_hard_cap_even_for_a_very_long_input() {
        let huge_command = "echo ".to_string() + &"x".repeat(5000);
        let out = summarize("Bash", &json!({"command": huge_command}));
        assert!(
            out.chars().count() <= MAX_SUMMARY_LEN,
            "summary length {} exceeds the {}-char cap",
            out.chars().count(),
            MAX_SUMMARY_LEN
        );
    }

    // ── 8. no raw tool_input JSON ever leaks into a summary ──────────────────

    #[test]
    fn no_raw_tool_input_leaks_into_any_summary() {
        let calls: Vec<(&str, serde_json::Value)> = vec![
            ("Read", json!({"file_path": "/tmp/a.rs", "extra": {"nested": "value"}})),
            ("Grep", json!({"pattern": "TODO", "path": "/tmp"})),
            ("Glob", json!({"pattern": "**/*.rs"})),
            ("Bash", json!({"command": "ls -la", "timeout": 5000})),
            ("Task", json!({"subagent_type": "cody", "description": "do a thing", "prompt": "full prompt text"})),
            ("WebFetch", json!({"url": "https://example.com/x?y=1", "prompt": "summarize"})),
            ("SomethingElse", json!({"note": "n", "detail": {"a": 1}})),
        ];
        for (tool, input) in calls {
            let out = summarize(tool, &input);
            assert!(
                !out.contains("{\""),
                "tool `{tool}` summary looks like it embedded raw JSON: {out}"
            );
            assert!(
                !out.contains("nested"),
                "tool `{tool}` summary must never leak a raw tool_input field it doesn't understand: {out}"
            );
        }
    }
}
