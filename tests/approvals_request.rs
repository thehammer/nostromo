//! A permission request as the CLI sends it (design contract §1) and the "Why"
//! line the user is shown with it (§6.3).
//!
//! `PermissionRequest::from_cli` takes the CLI's inner `request` object. Three
//! fields are required (`tool_name`, `input`, `tool_use_id`); everything else is
//! optional and parsed when present, because the CLI's schema may differ from
//! version to version. Text the CLI wrote is sanitized: escape sequences are
//! removed and hidden characters are made visible, never dropped.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nostromo::approvals::request::{
    sanitize_text, AskRule, FileSettings, FoundRule, MatchedAskRule, McpTool, PermissionRequest,
    Reason, ReasonKind, SettingsSource, ToolKind,
};
use serde_json::{json, Value};

// ── fixtures and helpers ──────────────────────────────────────────────────────

fn fixture_request(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("tests/fixtures/approvals/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture["requests"][0]["request"].clone()
}

fn parsed(name: &str) -> PermissionRequest {
    PermissionRequest::from_cli(&fixture_request(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// A `can_use_tool` request with only the three required fields.
fn minimal() -> Value {
    json!({
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "input": { "command": "rm -rf /tmp/x/a" },
        "tool_use_id": "toolu_1",
    })
}

fn with(mut base: Value, extra: Value) -> Value {
    for (k, v) in extra.as_object().unwrap() {
        base[k.as_str()] = v.clone();
    }
    base
}

fn without(mut base: Value, key: &str) -> Value {
    base.as_object_mut().unwrap().remove(key);
    base
}

fn req(v: Value) -> PermissionRequest {
    PermissionRequest::from_cli(&v).expect("a readable request")
}

/// Ask rules from a fixed list, remembering the `cwd` it was asked about.
struct FakeSettings {
    rules: Vec<AskRule>,
    asked_cwd: Mutex<Vec<Option<PathBuf>>>,
}

impl FakeSettings {
    fn new(rules: &[(&str, &str)]) -> Self {
        Self {
            rules: rules
                .iter()
                .map(|(r, s)| AskRule {
                    rule: (*r).into(),
                    source_path: (*s).into(),
                })
                .collect(),
            asked_cwd: Mutex::new(Vec::new()),
        }
    }

    fn none() -> Self {
        Self::new(&[])
    }
}

impl SettingsSource for FakeSettings {
    fn ask_rules(&self, cwd: Option<&Path>) -> Vec<AskRule> {
        self.asked_cwd
            .lock()
            .unwrap()
            .push(cwd.map(Path::to_path_buf));
        self.rules.clone()
    }
}

const HOME_SETTINGS: &str = "~/.claude/settings.json";

fn rm_rule_in_home() -> FakeSettings {
    FakeSettings::new(&[("Bash(rm:*)", HOME_SETTINGS)])
}

fn bash_with(command: &str, extra: Value) -> PermissionRequest {
    req(with(
        json!({ "subtype": "can_use_tool", "tool_name": "Bash", "input": { "command": command }, "tool_use_id": "toolu_1" }),
        extra,
    ))
}

fn why(r: &PermissionRequest, settings: &dyn SettingsSource) -> Reason {
    r.reason(Some(Path::new("/work/proj")), settings)
}

// ── parsing: required and optional fields ─────────────────────────────────────

#[test]
fn a_request_with_only_the_required_fields_parses_and_everything_else_is_absent() {
    let r = req(minimal());

    assert_eq!(r.tool_name, "Bash");
    assert_eq!(r.tool_use_id, "toolu_1");
    assert_eq!(r.input, json!({ "command": "rm -rf /tmp/x/a" }));
    assert_eq!(r.tool_kind, ToolKind::Bash);
    assert_eq!(r.mcp, None);
    for (what, absent) in [
        ("display_name", r.display_name.is_none()),
        ("title", r.title.is_none()),
        ("description", r.description.is_none()),
        ("decision_reason_type", r.decision_reason_type.is_none()),
        ("decision_reason", r.decision_reason.is_none()),
        ("matched_ask_rule", r.matched_ask_rule.is_none()),
        ("agent_id", r.agent_id.is_none()),
        ("mcp_server", r.mcp_server.is_none()),
        ("permission_suggestions", r.permission_suggestions.is_none()),
        ("blocked_path", r.blocked_path.is_none()),
        ("classifier_approvable", r.classifier_approvable.is_none()),
        (
            "suppress_always_allow_rule",
            r.suppress_always_allow_rule.is_none(),
        ),
        ("default_to_no", r.default_to_no.is_none()),
        (
            "requires_user_interaction",
            r.requires_user_interaction.is_none(),
        ),
    ] {
        assert!(absent, "{what} was not sent, so it is absent");
    }
}

#[test]
fn a_request_missing_a_required_field_is_an_error_not_a_guess() {
    for key in ["tool_name", "input", "tool_use_id"] {
        let result = PermissionRequest::from_cli(&without(minimal(), key));
        assert!(
            result.is_err(),
            "a request without `{key}` must be refused: {result:?}"
        );
    }
    // Wrong types count as missing.
    assert!(PermissionRequest::from_cli(&with(minimal(), json!({ "tool_use_id": 7 }))).is_err());
    assert!(PermissionRequest::from_cli(&with(minimal(), json!({ "tool_name": null }))).is_err());
    // Not an object at all.
    for v in [json!("oops"), json!(null), json!([1, 2]), json!(5)] {
        assert!(PermissionRequest::from_cli(&v).is_err(), "{v}");
    }
}

#[test]
fn the_malformed_fixture_is_an_error() {
    assert!(PermissionRequest::from_cli(&fixture_request("malformed")).is_err());
}

#[test]
fn an_input_that_is_not_an_object_is_kept_as_it_came() {
    let r = req(with(minimal(), json!({ "input": "oops" })));

    assert_eq!(r.input, json!("oops"));
}

#[test]
fn every_optional_field_the_cli_may_send_is_parsed_when_present() {
    let request = fixture_request("all_fields");
    let r = PermissionRequest::from_cli(&request).unwrap();

    assert_eq!(r.tool_name, "Bash");
    assert_eq!(r.tool_use_id, "toolu_all_fields_0");
    assert_eq!(r.input, request["input"]);
    assert_eq!(r.display_name.as_deref(), Some("Bash"));
    assert_eq!(r.title.as_deref(), Some("Run rm -rf /tmp/x/all?"));
    assert_eq!(r.description.as_deref(), Some("remove all"));
    assert_eq!(r.decision_reason_type.as_deref(), Some("rule"));
    assert_eq!(r.decision_reason.as_deref(), Some("Matched your ask rule"));
    assert_eq!(
        r.matched_ask_rule,
        Some(MatchedAskRule {
            source: "userSettings".into(),
            tool_name: "Bash".into(),
            rule_content: Some("rm:*".into())
        })
    );
    assert_eq!(r.agent_id.as_deref(), Some("agent_abc123"));
    assert_eq!(r.mcp_server.as_deref(), Some("slack"));
    assert_eq!(
        r.permission_suggestions.as_ref(),
        Some(&request["permission_suggestions"])
    );
    assert_eq!(r.blocked_path.as_deref(), Some("/tmp/x/all"));
    assert_eq!(r.classifier_approvable, Some(true));
    assert_eq!(r.suppress_always_allow_rule, Some(true));
    assert_eq!(r.default_to_no, Some(true));
    assert_eq!(r.requires_user_interaction, Some(true));
}

#[test]
fn each_flag_fixture_sets_its_own_flag_and_only_that_one() {
    let flags = |r: &PermissionRequest| {
        (
            r.default_to_no,
            r.suppress_always_allow_rule,
            r.requires_user_interaction,
            r.classifier_approvable,
        )
    };

    assert_eq!(
        flags(&parsed("flag_default_to_no")),
        (Some(true), None, None, None)
    );
    assert_eq!(
        flags(&parsed("flag_suppress_always_allow_rule")),
        (None, Some(true), None, None)
    );
    assert_eq!(
        flags(&parsed("flag_requires_user_interaction")),
        (None, None, Some(true), None)
    );
    assert_eq!(
        flags(&parsed("safety_check")),
        (None, None, None, Some(false))
    );
    assert_eq!(flags(&parsed("simple_rm")), (None, None, None, None));
}

#[test]
fn a_matched_ask_rule_without_content_still_parses() {
    let r = req(with(
        minimal(),
        json!({ "matched_ask_rule": { "source": "projectSettings", "tool_name": "Bash" } }),
    ));

    assert_eq!(
        r.matched_ask_rule,
        Some(MatchedAskRule {
            source: "projectSettings".into(),
            tool_name: "Bash".into(),
            rule_content: None
        })
    );
}

#[test]
fn fields_this_version_does_not_know_are_ignored() {
    let r = req(with(
        minimal(),
        json!({ "some_future_field": { "a": 1 }, "another": [1, 2] }),
    ));

    assert_eq!(r.tool_name, "Bash");
}

#[test]
fn the_input_is_kept_exactly_including_hidden_characters() {
    let request = fixture_request("bidi");
    let r = PermissionRequest::from_cli(&request).unwrap();

    assert_eq!(
        r.input, request["input"],
        "the input is what would run: it is never sanitized"
    );
    assert!(r.input["command"].as_str().unwrap().contains('\u{202E}'));
}

// ── what kind of tool ─────────────────────────────────────────────────────────

#[test]
fn tools_are_classified_by_name() {
    assert_eq!(ToolKind::of("Bash"), ToolKind::Bash);
    assert_eq!(ToolKind::of("Edit"), ToolKind::Edit);
    assert_eq!(ToolKind::of("Write"), ToolKind::Write);
    assert_eq!(ToolKind::of("NotebookEdit"), ToolKind::NotebookEdit);
    assert_eq!(ToolKind::of("mcp__slack__send_message"), ToolKind::Mcp);
    for other in [
        "Read",
        "WebFetch",
        "Agent",
        "Task",
        "Glob",
        "",
        "mcp__slack",
        "mcp",
    ] {
        assert_eq!(ToolKind::of(other), ToolKind::Other, "{other:?}");
    }
}

#[test]
fn tool_kinds_are_snake_case_on_the_wire() {
    for (kind, name) in [
        (ToolKind::Bash, "bash"),
        (ToolKind::Edit, "edit"),
        (ToolKind::Write, "write"),
        (ToolKind::NotebookEdit, "notebook_edit"),
        (ToolKind::Mcp, "mcp"),
        (ToolKind::Other, "other"),
    ] {
        assert_eq!(serde_json::to_value(kind).unwrap(), name);
    }
}

#[test]
fn an_mcp_tool_name_splits_into_server_and_tool() {
    let r = parsed("mcp");

    assert_eq!(r.tool_kind, ToolKind::Mcp);
    assert_eq!(
        r.mcp,
        Some(McpTool {
            server: "slack".into(),
            tool: "send_message".into()
        })
    );
    assert_eq!(
        r.display_name.as_deref(),
        Some("slack - send_message (MCP)")
    );
}

#[test]
fn a_tool_name_that_itself_contains_double_underscores_keeps_the_rest_in_tool() {
    let r = req(with(
        minimal(),
        json!({ "tool_name": "mcp__claude_ai_Slack__slack__send__message" }),
    ));

    assert_eq!(
        r.mcp,
        Some(McpTool {
            server: "claude_ai_Slack".into(),
            tool: "slack__send__message".into()
        })
    );
}

#[test]
fn a_built_in_tool_has_no_mcp_part_even_when_the_cli_names_a_server() {
    let r = parsed("all_fields");

    assert_eq!(r.mcp, None);
    assert_eq!(
        r.mcp_server.as_deref(),
        Some("slack"),
        "the field is kept as the CLI sent it"
    );
}

// ── sanitizing what the CLI wrote ─────────────────────────────────────────────

#[test]
fn ansi_csi_and_osc_sequences_are_stripped_from_the_reason_and_the_description() {
    let r = parsed("ansi_reason");

    assert_eq!(
        r.decision_reason.as_deref(),
        Some("Dangerous command matched your rule")
    );
    assert_eq!(r.description.as_deref(), Some("remove build"));
}

#[test]
fn osc_sequences_end_at_bel_or_string_terminator_and_take_nothing_else_with_them() {
    let r = req(with(
        minimal(),
        json!({ "decision_reason": "a\u{1b}]0;title\u{7}b\u{1b}]8;;http://x\u{1b}\\link\u{1b}]8;;\u{1b}\\c\u{1b}[1;31;4mred\u{1b}[0m" }),
    ));

    assert_eq!(r.decision_reason.as_deref(), Some("ablinkcred"));
}

#[test]
fn hidden_characters_in_the_reason_are_shown_as_tokens_and_newlines_stay() {
    let r = req(with(
        minimal(),
        json!({
            "decision_reason": "line one\nline\u{202E}two\u{200B}\ttab",
            "description": "a\u{FEFF}b\rc",
        }),
    ));

    assert_eq!(
        r.decision_reason.as_deref(),
        Some("line one\nline\u{27E8}U+202E RLO\u{27E9}two\u{27E8}U+200B ZWSP\u{27E9}\u{27E8}tab\u{27E9}tab"),
        "nothing is dropped silently: every hidden character is visible, the newline is kept"
    );
    assert_eq!(
        r.description.as_deref(),
        Some("a\u{27E8}U+FEFF BOM\u{27E9}b\u{27E8}CR\u{27E9}c")
    );
}

#[test]
fn plain_text_in_the_reason_is_unchanged() {
    let r = req(with(
        minimal(),
        json!({ "decision_reason": "Plain: text, with é and 日本 and  spaces" }),
    ));

    assert_eq!(
        r.decision_reason.as_deref(),
        Some("Plain: text, with é and 日本 and  spaces")
    );
}

// ── the Why line ──────────────────────────────────────────────────────────────

#[test]
fn a_rule_ask_without_a_named_rule_finds_the_rule_in_the_named_settings_file() {
    let r = parsed("simple_rm");
    let settings = FakeSettings::new(&[
        ("Bash(git:*)", "/work/proj/.claude/settings.json"),
        ("Bash(rm:*)", HOME_SETTINGS),
    ]);

    let reason = why(&r, &settings);

    assert_eq!(reason.kind, ReasonKind::AskRule);
    assert_eq!(
        reason.text,
        "your rule `Bash(rm:*)` in `~/.claude/settings.json`"
    );
    assert_eq!(
        reason.rule,
        Some(FoundRule {
            rule: "Bash(rm:*)".into(),
            source_path: HOME_SETTINGS.into(),
            found_by: "nostromo".into()
        })
    );
}

#[test]
fn the_session_directory_is_what_project_settings_are_looked_up_in() {
    let settings = rm_rule_in_home();

    parsed("simple_rm").reason(Some(Path::new("/work/proj")), &settings);
    parsed("simple_rm").reason(None, &settings);

    let asked = settings.asked_cwd.lock().unwrap().clone();
    assert_eq!(asked, [Some(PathBuf::from("/work/proj")), None]);
}

#[test]
fn the_first_matching_rule_in_settings_order_is_the_one_named() {
    let r = parsed("simple_rm");
    let settings = FakeSettings::new(&[
        ("Edit", HOME_SETTINGS),
        ("Bash(git push:*)", HOME_SETTINGS),
        ("Bash(rm:*)", "/work/proj/.claude/settings.json"),
        ("Bash(rm -rf:*)", "/work/proj/.claude/settings.local.json"),
        ("Bash", HOME_SETTINGS),
    ]);

    let reason = why(&r, &settings);

    assert_eq!(
        reason.rule.as_ref().map(|f| f.rule.as_str()),
        Some("Bash(rm:*)")
    );
    assert_eq!(
        reason.rule.as_ref().map(|f| f.source_path.as_str()),
        Some("/work/proj/.claude/settings.json")
    );
}

fn rm_rule_matches(command: &str) -> bool {
    let rule = AskRule {
        rule: "Bash(rm:*)".into(),
        source_path: HOME_SETTINGS.into(),
    };
    rule.matches("Bash", &json!({ "command": command }))
}

#[test]
fn bash_rm_prefix_rule_matches_any_simple_command_whose_words_start_with_rm() {
    for command in [
        "rm -rf /tmp/x",
        "rm",
        "  rm   file",
        "cd /tmp && rm -rf build",
        "ls; rm x",
        "ls || rm x",
        "cat f | rm x",
        "bash -c 'rm -rf x'",
        "sh -c \"echo hi && rm x\"",
        "echo $(rm x)",
        "echo `rm x`",
        "(rm x)",
        "echo ok\nrm -rf y",
    ] {
        assert!(
            rm_rule_matches(command),
            "`Bash(rm:*)` must match {command:?}"
        );
    }
}

#[test]
fn bash_rm_prefix_rule_does_not_match_lookalikes_or_arguments() {
    for command in [
        "rmdir x",
        "xrm x",
        "echo rm x",
        "ls rm",
        "git rm x",
        "rmx",
        "arm -rf x",
        "echo 'rm x'",
        "ls -l",
    ] {
        assert!(
            !rm_rule_matches(command),
            "`Bash(rm:*)` must not match {command:?}"
        );
    }
}

#[test]
fn a_multi_word_prefix_and_an_exact_rule_match_by_words() {
    let m = |rule: &str, command: &str| {
        AskRule {
            rule: rule.into(),
            source_path: HOME_SETTINGS.into(),
        }
        .matches("Bash", &json!({ "command": command }))
    };

    assert!(m("Bash(git push:*)", "git push origin main"));
    assert!(m("Bash(git push:*)", "git push"));
    assert!(!m("Bash(git push:*)", "git pull"));
    assert!(!m("Bash(git push:*)", "git"));
    assert!(m("Bash(npm run build)", "npm run build"));
    assert!(
        !m("Bash(npm run build)", "npm run build --watch"),
        "an exact rule is exact"
    );
    assert!(
        m("Bash", "anything at all"),
        "a rule for the whole tool matches every call"
    );
}

#[test]
fn rules_for_other_tools_match_by_tool_and_server() {
    let m = |rule: &str, tool: &str, input: Value| {
        AskRule {
            rule: rule.into(),
            source_path: HOME_SETTINGS.into(),
        }
        .matches(tool, &input)
    };

    assert!(m("Edit", "Edit", json!({ "file_path": "/a/b" })));
    assert!(!m("Edit", "Write", json!({ "file_path": "/a/b" })));
    assert!(!m("Bash(rm:*)", "Edit", json!({ "file_path": "/a/b" })));
    assert!(
        m("mcp__slack", "mcp__slack__send_message", json!({})),
        "a server rule covers its tools"
    );
    assert!(!m("mcp__slack", "mcp__slackish__send_message", json!({})));
    assert!(m(
        "mcp__slack__send_message",
        "mcp__slack__send_message",
        json!({})
    ));
    assert!(!m(
        "mcp__slack__send_message",
        "mcp__slack__read",
        json!({})
    ));
}

#[test]
fn a_rule_ask_with_no_rule_found_says_so_in_exactly_these_words() {
    let r = parsed("simple_rm");

    for settings in [
        FakeSettings::none(),
        FakeSettings::new(&[("Bash(git:*)", HOME_SETTINGS), ("Edit", HOME_SETTINGS)]),
    ] {
        let reason = why(&r, &settings);
        assert_eq!(reason.kind, ReasonKind::AskRule);
        assert_eq!(reason.text, "One of your Claude ask rules matched");
        assert_eq!(reason.rule, None);
    }
}

#[test]
fn a_rule_ask_is_explained_by_the_rule_even_when_the_cli_also_gave_a_reason_text() {
    let r = bash_with(
        "rm -rf x",
        json!({ "decision_reason_type": "rule", "decision_reason": "something else" }),
    );

    let reason = why(&r, &FakeSettings::none());

    assert_eq!(reason.kind, ReasonKind::AskRule);
    assert_eq!(reason.text, "One of your Claude ask rules matched");
}

#[test]
fn a_rule_the_cli_names_is_used_as_given_and_the_settings_files_are_not_consulted() {
    let r = parsed("flag_matched_ask_rule");
    let settings = FakeSettings::new(&[("Bash(rm -rf:*)", "/somewhere/else.json")]);

    let reason = why(&r, &settings);

    assert_eq!(reason.kind, ReasonKind::AskRule);
    let found = reason.rule.expect("the CLI's rule");
    assert_eq!(found.rule, "Bash(rm:*)");
    assert_eq!(found.source_path, "userSettings");
    assert_ne!(
        found.found_by, "nostromo",
        "the CLI named it; Nostromo did not find it"
    );
    assert!(
        reason.text.contains("Bash(rm:*)") && reason.text.contains("userSettings"),
        "{}",
        reason.text
    );
    assert!(
        settings.asked_cwd.lock().unwrap().is_empty(),
        "no need to read settings when the CLI says which rule"
    );
}

#[test]
fn a_matched_ask_rule_for_a_whole_tool_is_just_the_tool_name() {
    let r = req(with(
        minimal(),
        json!({ "matched_ask_rule": { "source": "localSettings", "tool_name": "Bash" } }),
    ));

    let reason = why(&r, &FakeSettings::none());

    assert_eq!(reason.rule.map(|f| f.rule), Some("Bash".to_owned()));
}

#[test]
fn a_matched_ask_rule_wins_over_the_reason_type() {
    let r = bash_with(
        "rm x",
        json!({ "decision_reason_type": "safetyCheck", "decision_reason": "protected", "matched_ask_rule": { "source": "userSettings", "tool_name": "Bash", "rule_content": "rm:*" } }),
    );

    let reason = why(&r, &FakeSettings::none());

    assert_eq!(reason.kind, ReasonKind::AskRule);
}

#[test]
fn a_safety_check_shows_the_cli_s_text() {
    let reason = why(&parsed("safety_check"), &rm_rule_in_home());

    assert_eq!(reason.kind, ReasonKind::SafetyCheck);
    assert_eq!(reason.text, "Command targets a protected path");
    assert_eq!(reason.rule, None);
}

#[test]
fn the_cli_s_reason_text_is_sanitized_before_it_is_shown() {
    let r = bash_with(
        "echo hi",
        json!({ "decision_reason_type": "safetyCheck", "decision_reason": "\u{1b}[31mprotected\u{1b}[0m\u{202E}path" }),
    );

    let reason = why(&r, &FakeSettings::none());

    assert_eq!(reason.kind, ReasonKind::SafetyCheck);
    assert_eq!(reason.text, "protected\u{27E8}U+202E RLO\u{27E9}path");
}

#[test]
fn some_other_reason_text_is_shown_as_it_is_with_the_other_kind() {
    let r = bash_with(
        "echo hi",
        json!({ "decision_reason_type": "hook", "decision_reason": "A hook asked" }),
    );

    let reason = why(&r, &FakeSettings::none());

    assert_eq!(reason.kind, ReasonKind::Other);
    assert_eq!(reason.text, "A hook asked");
}

#[test]
fn a_write_to_a_claude_settings_file_says_it_changes_one() {
    for (tool, input) in [
        (
            "Write",
            json!({ "file_path": "/Users/test/.claude/settings.json", "content": "{}" }),
        ),
        (
            "Write",
            json!({ "file_path": "/work/proj/.claude/settings.local.json", "content": "{}" }),
        ),
        (
            "Edit",
            json!({ "file_path": "/Users/test/.claude/settings.json", "old_string": "a", "new_string": "b" }),
        ),
    ] {
        let r = req(
            json!({ "subtype": "can_use_tool", "tool_name": tool, "input": input, "tool_use_id": "t", "decision_reason_type": "other" }),
        );
        let reason = why(&r, &FakeSettings::none());
        assert_eq!(reason.kind, ReasonKind::SettingsWrite, "{input}");
        assert_eq!(reason.text, "Changes a Claude settings file", "{input}");
    }
}

#[test]
fn the_settings_write_fixture_is_explained_as_a_settings_write() {
    // The fixture says `decision_reason_type: "other"` and names no rule.
    let reason = why(&parsed("settings_write"), &FakeSettings::none());

    assert_eq!(reason.kind, ReasonKind::SettingsWrite);
    assert_eq!(reason.text, "Changes a Claude settings file");
}

#[test]
fn a_write_to_any_other_file_is_not_called_a_settings_write() {
    for path in [
        "/tmp/x/settings.json",
        "/work/.claude/other.json",
        "/work/.claudex/settings.json",
        "/work/proj/settings.json",
    ] {
        let r = req(
            json!({ "subtype": "can_use_tool", "tool_name": "Write", "input": { "file_path": path, "content": "{}" }, "tool_use_id": "t" }),
        );
        let reason = why(&r, &FakeSettings::none());
        assert_eq!(reason.kind, ReasonKind::Other, "{path}");
        assert_eq!(reason.text, "Claude Code asked for approval", "{path}");
    }
}

#[test]
fn with_no_reason_at_all_the_line_says_claude_code_asked() {
    for r in [req(minimal()), parsed("mcp")] {
        let r = PermissionRequest {
            decision_reason_type: None,
            ..r
        };
        let reason = why(&r, &rm_rule_in_home());
        assert_eq!(reason.kind, ReasonKind::Other);
        assert_eq!(reason.text, "Claude Code asked for approval");
        assert_eq!(reason.rule, None);
    }
}

#[test]
fn a_blank_reason_text_is_no_reason() {
    let r = bash_with(
        "echo hi",
        json!({ "decision_reason_type": "other", "decision_reason": "   \n " }),
    );

    assert_eq!(
        why(&r, &FakeSettings::none()).text,
        "Claude Code asked for approval"
    );
}

#[test]
fn reason_kinds_are_snake_case_on_the_wire() {
    for (kind, name) in [
        (ReasonKind::AskRule, "ask_rule"),
        (ReasonKind::SafetyCheck, "safety_check"),
        (ReasonKind::SettingsWrite, "settings_write"),
        (ReasonKind::Other, "other"),
    ] {
        assert_eq!(serde_json::to_value(kind).unwrap(), name);
    }
    let reason = why(&parsed("simple_rm"), &rm_rule_in_home());
    let v = serde_json::to_value(&reason).unwrap();
    assert_eq!(v["kind"], "ask_rule");
    assert_eq!(v["rule"]["rule"], "Bash(rm:*)");
    assert_eq!(v["rule"]["source_path"], HOME_SETTINGS);
    assert_eq!(v["rule"]["found_by"], "nostromo");
}

// ── the real settings files ───────────────────────────────────────────────────

/// `HOME` is process-global: tests that point it somewhere serialize on this.
static ENV: Mutex<()> = Mutex::new(());

struct HomeGuard {
    old: Option<std::ffi::OsString>,
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl HomeGuard {
    fn set(home: &Path) -> Self {
        let lock = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let old = std::env::var_os("HOME");
        std::env::set_var("HOME", home);
        Self { old, _lock: lock }
    }
}

impl Drop for HomeGuard {
    fn drop(&mut self) {
        match &self.old {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
    }
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// Every file under `dir` with its contents, to prove a read left nothing behind.
fn snapshot(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    fn walk(dir: &Path, out: &mut Vec<(PathBuf, Vec<u8>)>) {
        let mut entries: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        entries.sort();
        for p in entries {
            if p.is_dir() {
                walk(&p, out);
            } else {
                out.push((p.clone(), std::fs::read(&p).unwrap()));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, &mut out);
    out
}

struct Dirs {
    _root: tempfile::TempDir,
    home: PathBuf,
    cwd: PathBuf,
}

fn dirs() -> Dirs {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let cwd = root.path().join("proj");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&cwd).unwrap();
    Dirs {
        _root: root,
        home,
        cwd,
    }
}

fn ask(rules: &[&str]) -> String {
    json!({ "permissions": { "ask": rules, "allow": ["Read"] }, "model": "x" }).to_string()
}

#[test]
fn file_settings_reads_the_three_files_in_claude_s_order_and_names_where_each_rule_came_from() {
    let d = dirs();
    write(
        &d.home.join(".claude/settings.json"),
        &ask(&["Bash(rm:*)", "Edit"]),
    );
    write(
        &d.cwd.join(".claude/settings.json"),
        &ask(&["Bash(git push:*)"]),
    );
    write(
        &d.cwd.join(".claude/settings.local.json"),
        &ask(&["Write(/etc/*)"]),
    );
    let _home = HomeGuard::set(&d.home);

    let rules = FileSettings::new().ask_rules(Some(&d.cwd));

    let project = d.cwd.join(".claude/settings.json").display().to_string();
    let local = d
        .cwd
        .join(".claude/settings.local.json")
        .display()
        .to_string();
    assert_eq!(
        rules,
        [
            AskRule {
                rule: "Bash(rm:*)".into(),
                source_path: "~/.claude/settings.json".into()
            },
            AskRule {
                rule: "Edit".into(),
                source_path: "~/.claude/settings.json".into()
            },
            AskRule {
                rule: "Bash(git push:*)".into(),
                source_path: project
            },
            AskRule {
                rule: "Write(/etc/*)".into(),
                source_path: local
            },
        ]
    );
}

#[test]
fn file_settings_without_a_cwd_reads_only_the_home_file() {
    let d = dirs();
    write(&d.home.join(".claude/settings.json"), &ask(&["Bash(rm:*)"]));
    write(&d.cwd.join(".claude/settings.json"), &ask(&["Bash(git:*)"]));
    let _home = HomeGuard::set(&d.home);

    let rules = FileSettings::new().ask_rules(None);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Bash(rm:*)"]
    );
}

#[test]
fn file_settings_with_no_files_has_no_rules() {
    let d = dirs();
    let _home = HomeGuard::set(&d.home);

    assert!(FileSettings::new().ask_rules(Some(&d.cwd)).is_empty());
    assert!(FileSettings::new().ask_rules(None).is_empty());
}

#[test]
fn file_settings_never_writes_anything() {
    let d = dirs();
    write(&d.home.join(".claude/settings.json"), &ask(&["Bash(rm:*)"]));
    write(&d.cwd.join(".claude/settings.local.json"), "{ not json");
    let _home = HomeGuard::set(&d.home);
    let before = (snapshot(&d.home), snapshot(&d.cwd));

    let source = FileSettings::new();
    for _ in 0..3 {
        source.ask_rules(Some(&d.cwd));
    }

    assert_eq!(
        (snapshot(&d.home), snapshot(&d.cwd)),
        before,
        "the settings files are read-only to us"
    );
}

#[test]
fn a_malformed_settings_file_is_skipped_and_the_others_still_count() {
    let d = dirs();
    write(&d.home.join(".claude/settings.json"), &ask(&["Bash(rm:*)"]));
    write(
        &d.cwd.join(".claude/settings.json"),
        "{ \"permissions\": { \"ask\": [ \"Bash(oops\" ",
    );
    write(&d.cwd.join(".claude/settings.local.json"), &ask(&["Edit"]));
    let _home = HomeGuard::set(&d.home);

    let rules = FileSettings::new().ask_rules(Some(&d.cwd));

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Bash(rm:*)", "Edit"]
    );
}

#[test]
fn odd_but_valid_settings_shapes_yield_no_rules_and_no_panic() {
    for text in [
        "",
        "null",
        "[]",
        "42",
        "{}",
        r#"{"permissions":null}"#,
        r#"{"permissions":{"ask":"Bash(rm:*)"}}"#,
        r#"{"permissions":{"ask":{"a":1}}}"#,
        r#"{"permissions":{"allow":["Bash(rm:*)"]}}"#,
    ] {
        let d = dirs();
        write(&d.home.join(".claude/settings.json"), text);
        let _home = HomeGuard::set(&d.home);

        assert!(
            FileSettings::new().ask_rules(Some(&d.cwd)).is_empty(),
            "{text:?}"
        );
    }
}

#[test]
fn non_string_entries_in_an_ask_list_are_ignored() {
    let d = dirs();
    write(
        &d.home.join(".claude/settings.json"),
        r#"{"permissions":{"ask":[1,null,"Bash(rm:*)",{"x":1},["y"]]}}"#,
    );
    let _home = HomeGuard::set(&d.home);

    let rules = FileSettings::new().ask_rules(None);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Bash(rm:*)"]
    );
}

#[test]
fn the_why_line_for_a_rule_ask_comes_from_the_real_files() {
    let d = dirs();
    write(&d.home.join(".claude/settings.json"), &ask(&["Bash(rm:*)"]));
    let _home = HomeGuard::set(&d.home);

    let reason = parsed("simple_rm").reason(Some(&d.cwd), &FileSettings::new());

    assert_eq!(
        reason.text,
        "your rule `Bash(rm:*)` in `~/.claude/settings.json`"
    );
    assert_eq!(reason.rule.map(|r| r.found_by), Some("nostromo".to_owned()));
}

#[test]
fn a_project_ask_rule_is_found_through_the_session_directory() {
    let d = dirs();
    write(
        &d.cwd.join(".claude/settings.local.json"),
        &ask(&["Bash(rm:*)"]),
    );
    let _home = HomeGuard::set(&d.home);

    let found = parsed("simple_rm")
        .reason(Some(&d.cwd), &FileSettings::new())
        .rule
        .expect("found in the project");
    let elsewhere = parsed("simple_rm").reason(Some(&d.home), &FileSettings::new());

    assert_eq!(
        found.source_path,
        d.cwd
            .join(".claude/settings.local.json")
            .display()
            .to_string()
    );
    assert_eq!(
        elsewhere.text, "One of your Claude ask rules matched",
        "a different directory has different project settings"
    );
}

// ── sanitizing: only complete sequences are removed ───────────────────────────

const ESC_TOKEN: &str = "\u{27E8}U+001B\u{27E9}";

#[test]
fn an_unterminated_osc_does_not_swallow_the_text_after_it() {
    let shown = sanitize_text("ok\u{1b}]0;Run: rm -rf ~");

    assert_eq!(
        shown,
        format!("ok{ESC_TOKEN}]0;Run: rm -rf ~"),
        "the ESC is shown and everything after it stays visible"
    );
}

#[test]
fn an_escape_that_starts_no_complete_sequence_is_shown_not_dropped() {
    assert_eq!(
        sanitize_text("abc\u{1b}"),
        format!("abc{ESC_TOKEN}"),
        "a trailing ESC"
    );
    assert_eq!(
        sanitize_text("a\u{1b}[1;3"),
        format!("a{ESC_TOKEN}[1;3"),
        "a CSI that ends before its final byte"
    );
    assert_eq!(
        sanitize_text("a\u{1b}[1\u{1}x"),
        format!("a{ESC_TOKEN}[1\u{27E8}U+0001\u{27E9}x"),
        "a CSI broken by a control character"
    );
    assert_eq!(sanitize_text("\u{1b}"), ESC_TOKEN);
    assert_eq!(
        sanitize_text("a\u{1b}\u{1b}"),
        format!("a{ESC_TOKEN}{ESC_TOKEN}"),
        "ESC followed by ESC starts nothing"
    );
    assert_eq!(
        sanitize_text("a\u{1b}\u{1b}\u{1}b"),
        format!("a{ESC_TOKEN}{ESC_TOKEN}\u{27E8}U+0001\u{27E9}b"),
        "neither ESC starts a sequence here, so both are shown"
    );
    assert_eq!(
        sanitize_text("a\u{1b}\u{202E}b"),
        format!("a{ESC_TOKEN}\u{27E8}U+202E RLO\u{27E9}b"),
        "the ESC and the bidi override are both shown: nothing is silently lost"
    );
}

#[test]
fn a_complete_sequence_after_a_broken_one_is_still_removed() {
    let shown = sanitize_text("\u{1b}]0;unterminated \u{1b}[31mred\u{1b}[0m");

    assert_eq!(shown, format!("{ESC_TOKEN}]0;unterminated red"));
}

#[test]
fn complete_sequences_are_removed() {
    for (raw, expected) in [
        ("\u{1b}[31mred\u{1b}[0m", "red"),
        ("a\u{1b}[2Kb\u{1b}[1;31;4mc", "abc"),
        ("\u{1b}]0;title\u{7}x", "x"),
        ("\u{1b}]8;;http://x\u{1b}\\x", "x"),
        ("\u{1b}(Bx", "x"),
        ("\u{1b}cx", "x"),
        ("\u{1b}=x", "x"),
        ("\u{9b}31mx", "x"),
        ("\u{9d}0;t\u{7}x", "x"),
        ("\u{1b}Pq data\u{1b}\\x", "x"),
    ] {
        assert_eq!(sanitize_text(raw), expected, "{raw:?}");
    }
}

#[test]
fn newlines_and_plain_text_survive_sanitizing_untouched() {
    assert_eq!(sanitize_text("a\nb\u{1b}[0m\n\nc"), "a\nb\n\nc");
    assert_eq!(sanitize_text("plain é 日本"), "plain é 日本");
    assert_eq!(sanitize_text(""), "");
}

#[test]
fn a_reason_with_an_unterminated_escape_keeps_its_text_visible() {
    let r = req(with(
        minimal(),
        json!({ "decision_reason": "ok\u{1b}]0;Run: rm -rf ~", "description": "a\u{1b}" }),
    ));

    assert_eq!(
        r.decision_reason.as_deref(),
        Some(format!("ok{ESC_TOKEN}]0;Run: rm -rf ~").as_str())
    );
    assert_eq!(
        r.description.as_deref(),
        Some(format!("a{ESC_TOKEN}").as_str())
    );
}

// ── settings files that are not ordinary small files ──────────────────────────

fn mkfifo(path: &Path) {
    use std::os::unix::ffi::OsStrExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(
        unsafe { libc::mkfifo(c.as_ptr(), 0o600) },
        0,
        "mkfifo: {}",
        std::io::Error::last_os_error()
    );
}

/// `ask_rules(cwd)`, in a thread, with a real-time cap: a read that blocks fails the test instead of hanging it.
fn ask_rules_capped(source: FileSettings, cwd: &Path) -> Vec<AskRule> {
    let (tx, rx) = std::sync::mpsc::channel();
    let cwd = cwd.to_path_buf();
    std::thread::spawn(move || {
        let _ = tx.send(source.ask_rules(Some(&cwd)));
    });
    rx.recv_timeout(std::time::Duration::from_secs(10))
        .expect("ask_rules must return, whatever is planted at the settings paths")
}

#[test]
fn a_fifo_planted_as_a_settings_file_does_not_hang_and_the_other_files_still_count() {
    let d = dirs();
    write(&d.home.join(".claude/settings.json"), &ask(&["Bash(rm:*)"]));
    write(&d.cwd.join(".claude/settings.json"), &ask(&["Edit"]));
    mkfifo(&d.cwd.join(".claude/settings.local.json"));
    let _home = HomeGuard::set(&d.home);

    let rules = ask_rules_capped(FileSettings::new(), &d.cwd);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Bash(rm:*)", "Edit"]
    );
}

#[test]
fn a_directory_at_a_settings_path_is_ignored() {
    let d = dirs();
    std::fs::create_dir_all(d.cwd.join(".claude/settings.local.json")).unwrap();
    write(&d.cwd.join(".claude/settings.json"), &ask(&["Edit"]));
    let _home = HomeGuard::set(&d.home);

    let rules = ask_rules_capped(FileSettings::new(), &d.cwd);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Edit"]
    );
}

#[test]
fn a_settings_file_over_one_mebibyte_is_ignored() {
    const MIB: usize = 1 << 20;
    // The ask rule is last, past the limit: the file is cut off and cannot be read as settings.
    let d = dirs();
    let huge = format!(
        "{{\"junk\":\"{}\",\"permissions\":{{\"ask\":[\"Bash(rm:*)\"]}}}}",
        "x".repeat(MIB + 10)
    );
    write(&d.home.join(".claude/settings.json"), &huge);
    write(&d.cwd.join(".claude/settings.json"), &ask(&["Edit"]));
    let _home = HomeGuard::set(&d.home);

    let rules = ask_rules_capped(FileSettings::new(), &d.cwd);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Edit"],
        "the oversized file contributes nothing"
    );
}

#[test]
fn a_settings_file_over_one_mebibyte_is_ignored_even_when_its_rules_come_first() {
    const MIB: usize = 1 << 20;
    // Still valid JSON if cut at the limit (only blanks follow): it must not be half-read.
    let d = dirs();
    let padded = format!("{}{}", ask(&["Bash(rm:*)"]), " ".repeat(MIB + 10));
    write(&d.home.join(".claude/settings.json"), &padded);
    let _home = HomeGuard::set(&d.home);

    let rules = ask_rules_capped(FileSettings::new(), &d.cwd);

    assert!(rules.is_empty(), "{rules:?}");
}

#[test]
fn a_settings_file_just_under_the_limit_is_read() {
    const MIB: usize = 1 << 20;
    let d = dirs();
    let json = ask(&["Bash(rm:*)"]);
    let padded = format!("{json}{}", " ".repeat(MIB - json.len()));
    assert_eq!(padded.len(), MIB);
    write(&d.home.join(".claude/settings.json"), &padded);
    let _home = HomeGuard::set(&d.home);

    let rules = ask_rules_capped(FileSettings::new(), &d.cwd);

    assert_eq!(
        rules.iter().map(|r| r.rule.as_str()).collect::<Vec<_>>(),
        ["Bash(rm:*)"]
    );
}

// ── Bash wildcard rules ───────────────────────────────────────────────────────

fn bash_rule(rule: &str, command: &str) -> bool {
    AskRule {
        rule: rule.into(),
        source_path: HOME_SETTINGS.into(),
    }
    .matches("Bash", &json!({ "command": command }))
}

#[test]
fn a_bash_rule_with_a_wildcard_matches_what_the_pattern_covers() {
    assert!(bash_rule("Bash(*)", "ls -la"));
    assert!(bash_rule("Bash(*)", "rm -rf /tmp/x"));
    assert!(bash_rule("Bash(ls*)", "ls -la"));
    assert!(bash_rule("Bash(ls*)", "ls"));
    assert!(!bash_rule("Bash(ls*)", "rm x"));
    assert!(!bash_rule("Bash(ls*)", "echo ls"));
}

#[test]
fn a_bash_wildcard_rule_finds_the_matching_command_inside_a_compound_one() {
    assert!(bash_rule("Bash(ls*)", "cd /tmp && ls -la"));
    assert!(!bash_rule("Bash(ls*)", "cd /tmp && rm x"));
}

#[test]
fn prefix_rules_are_unchanged_by_wildcard_support() {
    assert!(bash_rule("Bash(rm:*)", "rm -rf x"));
    assert!(!bash_rule("Bash(rm:*)", "rmdir x"));
    assert!(bash_rule("Bash(git push:*)", "git push origin main"));
    assert!(!bash_rule("Bash(git push:*)", "git pull"));
    assert!(bash_rule("Bash(npm run build)", "npm run build"));
    assert!(!bash_rule("Bash(npm run build)", "npm run build --watch"));
}

#[test]
fn an_edit_rule_still_does_not_cover_write() {
    let rule = AskRule {
        rule: "Edit".into(),
        source_path: HOME_SETTINGS.into(),
    };

    assert!(!rule.matches("Write", &json!({ "file_path": "/a/b", "content": "x" })));
    assert!(rule.matches("Edit", &json!({ "file_path": "/a/b" })));
}

#[test]
fn a_wildcard_ask_rule_is_named_in_the_why_line() {
    let settings = FakeSettings::new(&[
        ("Bash(ls*)", HOME_SETTINGS),
        ("Bash(*)", "/work/proj/.claude/settings.json"),
    ]);

    let for_ls = why(
        &bash_with("ls -la", json!({ "decision_reason_type": "rule" })),
        &settings,
    );
    let for_rm = why(
        &bash_with("rm x", json!({ "decision_reason_type": "rule" })),
        &settings,
    );

    assert_eq!(for_ls.rule.map(|r| r.rule), Some("Bash(ls*)".to_owned()));
    assert_eq!(
        for_rm.rule.map(|r| r.rule),
        Some("Bash(*)".to_owned()),
        "`Bash(ls*)` does not cover `rm x`; the next rule does"
    );
}

// ── N9: a pathological command cannot pin the worker through an ask rule ──────
//
// `AskRule::matches` tokenizes the FULL command (the display cap does not apply to it), and
// runs on the broker's single worker thread. `shell::parse` is bounded by a step budget, so
// matching is too: each shape below is ~4 MiB. The thread and its generous limit are only
// there so that a regression fails this test instead of hanging the run.

#[test]
fn matching_an_ask_rule_against_a_four_mib_pathological_command_returns() {
    const FOUR_MIB: usize = 4 * 1024 * 1024;
    let shapes: Vec<(&str, String)> = vec![
        ("open braces", "{ ".repeat(FOUR_MIB / 2)),
        ("eval", "eval ".repeat(FOUR_MIB / 5)),
        ("command substitution openers", "$( ".repeat(FOUR_MIB / 3)),
        ("open parentheses", "((((".repeat(FOUR_MIB / 4)),
        ("here-doc openers", "<<A\n".repeat(FOUR_MIB / 4)),
        ("assignments", "a=b ".repeat(FOUR_MIB / 4)),
        ("single quotes", "'".repeat(FOUR_MIB + 1)),
        ("dollar quote pairs", "\"$".repeat(FOUR_MIB / 4 + 1)),
        ("backticks", "`".repeat(FOUR_MIB + 1)),
    ];
    let rules = ["Bash(rm:*)", "Bash(rm -rf /tmp/x)", "Bash(ls *)", "Bash(ls*)", "Bash", "Edit(*.rs)"];

    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for (what, command) in shapes {
            let input = json!({ "command": command });
            for rule in rules {
                let rule = AskRule { rule: rule.into(), source_path: "~/.claude/settings.json".into() };
                let matched = rule.matches("Bash", &input);
                // None of these runs `rm` or `ls`: only a rule with no content covers them.
                let _ = tx.send((what, rule.rule.clone(), matched));
            }
        }
    });
    let mut seen = 0;
    while seen < 9 * rules.len() {
        let (what, rule, matched) = rx
            .recv_timeout(std::time::Duration::from_secs(300))
            .unwrap_or_else(|_| panic!("matching did not finish after {seen} of {} cases", 9 * rules.len()));
        assert_eq!(matched, rule == "Bash", "{what} against {rule}: only the whole-tool rule covers it");
        seen += 1;
    }
}

#[test]
fn an_ordinary_command_still_matches_its_ask_rule() {
    let rm = AskRule { rule: "Bash(rm:*)".into(), source_path: "~/.claude/settings.json".into() };
    assert!(rm.matches("Bash", &json!({ "command": "rm -rf /tmp/x/a" })));
    assert!(rm.matches("Bash", &json!({ "command": "ls && rm -rf /tmp/x/a" })));
    assert!(rm.matches("Bash", &json!({ "command": "bash -c 'echo hi; rm -rf /tmp/x'" })));
    assert!(!rm.matches("Bash", &json!({ "command": "ls -la" })));
}

