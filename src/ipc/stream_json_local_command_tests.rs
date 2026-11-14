//! Slash commands in a session's stream (Claude Code 2.1.318): what the CLI
//! echoes for one and what a local command prints.
//!
//! Contract under test (see the classification rule in `local_command`):
//!
//! * a LOCAL command (the CLI answered itself, no model turn) is read in every
//!   shape the CLI has: live form A (an assistant line naming `local_command_run`),
//!   live form B (a user line holding `<local-command-stdout>`), stored form C
//!   (a `<command-name>` user line, then a `system`/`local_command` line or a
//!   stdout user line). The output is the text without its wrapper, cleaned of
//!   control characters, redacted of secrets and cut at 16 KiB (and flagged);
//! * the harness tags are read in either order (local commands store
//!   `<command-name>` first, prompt-type ones `<command-message>` first);
//! * the caveat, system reminders and any other `<local-command-*>` kind still
//!   make nothing, and a prompt that merely MENTIONS a tag is still a prompt;
//! * in a transcript a local command is ONE record turn: complete, never a
//!   prompt (not counted, never the title), and it never adds a block to a
//!   turn before it;
//! * a prompt-type command (`/hi`) is the user's own `/hi` turn, drawn as a
//!   normal bubble; stored, its skill body is the existing skill marker that
//!   holds the reply; a harness line nothing follows is still the user's turn.
//!
//! All text is fake.

use super::*;
use serde_json::{json, Value};

const STREAM: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/stream_local_commands.jsonl"
));
const STORED: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/local-command-session.jsonl"
));

const CAP: usize = local_command::LOCAL_COMMAND_OUTPUT_BYTES;

// ── builders ──────────────────────────────────────────────────────────────────

/// Form A as the live CLI writes it.
fn form_a(command: &str, args: &str, stdout: &str) -> String {
    json!({
        "type": "assistant",
        "parent_tool_use_id": null,
        "local_command_source": format!("<local-command-stdout>{stdout}</local-command-stdout>"),
        "local_command_run": {"command": command, "args": args},
        "message": {"model": "<synthetic>", "role": "assistant",
            "content": [{"type": "text", "text": stdout}]},
        "session_id": "s",
        "uuid": "u",
        "timestamp": "2026-11-13T19:20:23.436Z"
    })
    .to_string()
}

/// Form B (live) or the stored compact line: a user line holding the stdout tag.
fn user_stdout(text: &str, replay: bool) -> String {
    let mut v = json!({"type": "user", "message": {"role": "user",
        "content": format!("<local-command-stdout>{text}</local-command-stdout>")}});
    if replay {
        v["isReplay"] = json!(true);
    }
    v.to_string()
}

/// Form C's third line.
fn system_local(content: &str) -> String {
    json!({"type": "system", "subtype": "local_command", "content": content}).to_string()
}

fn user_text(content: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}}).to_string()
}

fn reply(text: &str) -> String {
    json!({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "text", "text": text}]}})
    .to_string()
}

struct Local {
    command: Option<String>,
    args: Option<String>,
    output: String,
    stream: String,
    truncated: bool,
    from_user_line: bool,
}

fn local_of(line: &str) -> Local {
    match parse_line(line) {
        Some(ParsedLine::LocalCommandOutput {
            command,
            args,
            output,
            stream,
            truncated,
            from_user_line,
            ..
        }) => Local {
            command,
            args,
            output,
            stream,
            truncated,
            from_user_line,
        },
        other => panic!("expected local command output, got {other:?} for {line}"),
    }
}

fn echo_of(line: &str) -> (String, String, bool) {
    match parse_line(line) {
        Some(ParsedLine::CommandEcho {
            name,
            args,
            is_replay,
            ..
        }) => (name, args, is_replay),
        other => panic!("expected a command echo, got {other:?} for {line}"),
    }
}

fn is_record(t: &Turn) -> bool {
    matches!(t.origin, Some(TurnOrigin::LocalCommand { .. }))
}

fn texts(t: &Turn) -> Vec<&str> {
    t.blocks
        .iter()
        .filter_map(|b| match b {
            TurnBlock::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

fn stored(lines: &[String]) -> SessionTranscript {
    transcript_from_jsonl(&lines.join("\n"), 100)
}

// ── parsing: the three forms ──────────────────────────────────────────────────

#[test]
fn a_live_local_command_assistant_line_names_the_command_and_carries_its_output_without_the_wrapper(
) {
    let l = local_of(&form_a(
        "model",
        "haiku",
        "Set model to `Haiku 5.5` for this session only",
    ));

    assert_eq!(l.command.as_deref(), Some("model"));
    assert_eq!(l.args.as_deref(), Some("haiku"));
    assert_eq!(l.output, "Set model to `Haiku 5.5` for this session only");
    assert_eq!(l.stream, "stdout");
    assert!(!l.truncated);
    assert!(!l.from_user_line);
}

#[test]
fn a_local_command_assistant_line_is_read_from_its_message_text_when_it_has_no_source_field() {
    let line = json!({
        "type": "assistant",
        "local_command_run": {"command": "context", "args": ""},
        "message": {"role": "assistant", "content": [{"type": "text", "text": "12k tokens"}]}
    })
    .to_string();

    let l = local_of(&line);

    assert_eq!(l.command.as_deref(), Some("context"));
    assert_eq!(l.output, "12k tokens");
}

#[test]
fn a_local_command_that_wrote_to_stderr_is_a_stderr_record() {
    let line = json!({
        "type": "assistant",
        "local_command_source": "<local-command-stderr>Unknown command: nope</local-command-stderr>",
        "local_command_run": {"command": "nope", "args": ""},
        "message": {"role": "assistant", "content": []}
    })
    .to_string();

    let l = local_of(&line);

    assert_eq!(l.stream, "stderr");
    assert_eq!(l.output, "Unknown command: nope");
}

#[test]
fn a_live_user_line_holding_stdout_is_local_output_from_a_user_line_with_no_command_of_its_own() {
    for content in [
        json!("<local-command-stdout>Compacted </local-command-stdout>"),
        json!([{"type": "text", "text": "<local-command-stdout>Compacted </local-command-stdout>"}]),
    ] {
        let line = json!({"type": "user", "isReplay": true,
            "message": {"role": "user", "content": content}})
        .to_string();

        let l = local_of(&line);

        assert_eq!(l.output.trim(), "Compacted", "{line}");
        assert_eq!(l.stream, "stdout");
        assert_eq!(l.command, None, "a user line never names its command");
        assert!(l.from_user_line);
    }
}

#[test]
fn a_user_line_holding_stderr_is_a_stderr_record() {
    let line = user_text("<local-command-stderr>boom</local-command-stderr>");
    let l = local_of(&line);
    assert_eq!((l.stream.as_str(), l.output.as_str()), ("stderr", "boom"));
}

#[test]
fn a_stored_system_local_command_line_is_local_output_without_a_command_of_its_own() {
    let l = local_of(&system_local(
        "<local-command-stdout>Context Usage\n12k / 200k</local-command-stdout>",
    ));

    assert_eq!(l.output, "Context Usage\n12k / 200k");
    assert_eq!(l.stream, "stdout");
    assert_eq!(l.command, None);
    assert!(!l.from_user_line);
}

#[test]
fn a_system_local_command_line_without_a_stdout_tag_makes_nothing() {
    assert!(parse_line(&system_local("just some words")).is_none());
}

// ── parsing: the output is cleaned, redacted and capped ───────────────────────

#[test]
fn output_past_the_cap_is_cut_and_flagged_and_output_at_the_cap_is_whole() {
    let at_cap = "a".repeat(CAP);
    let over = format!("{}\n{}", "b".repeat(CAP), "tail that must go");
    let wide = "\u{e9}".repeat(CAP); // two bytes each: the cut must not split one

    for (label, make) in [
        ("form A", form_a as fn(&str, &str, &str) -> String),
        ("form C", |_c, _a, body| {
            system_local(&format!(
                "<local-command-stdout>{body}</local-command-stdout>"
            ))
        }),
    ] {
        let whole = local_of(&make("x", "", &at_cap));
        assert_eq!(whole.output.len(), CAP, "{label}");
        assert!(!whole.truncated, "{label}: exactly at the cap is not cut");

        let cut = local_of(&make("x", "", &over));
        assert!(cut.output.len() <= CAP, "{label}: {}", cut.output.len());
        assert!(cut.truncated, "{label}");
        assert!(!cut.output.contains("tail that must go"), "{label}");

        let cut_wide = local_of(&make("x", "", &wide));
        assert!(cut_wide.output.len() <= CAP, "{label}");
        assert!(
            cut_wide.output.len() > CAP - 4,
            "{label}: kept nearly all of the cap"
        );
        assert!(cut_wide.truncated, "{label}");
    }
}

#[test]
fn control_characters_and_hidden_text_are_removed_from_the_output() {
    let dirty =
        "red \u{1b}[31mtext\u{1b}[0m\u{7} with \u{202E}bidi and\u{200B}zero width\nsecond\tline";
    for line in [
        form_a("x", "", dirty),
        system_local(&format!(
            "<local-command-stdout>{dirty}</local-command-stdout>"
        )),
        user_stdout(dirty, true),
    ] {
        let out = local_of(&line).output;
        for c in out.chars() {
            assert!(
                !c.is_control() || c == '\n' || c == '\t',
                "control character {c:?} survived in {out:?}"
            );
        }
        assert!(
            !out.contains('\u{202E}') && !out.contains('\u{200B}'),
            "{out:?}"
        );
        assert!(
            out.contains("red ") && out.contains("zero width"),
            "{out:?}"
        );
        assert!(
            out.contains("second\tline"),
            "tabs and newlines stay: {out:?}"
        );
    }
}

#[test]
fn secrets_in_a_local_commands_output_are_redacted_and_the_rest_is_kept() {
    let secrets = [
        (
            "an AWS secret assignment",
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "wJalrXUtnFEMI",
        ),
        (
            "an Anthropic key",
            "key is sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWX",
            "ABCDEFGHIJKLMNOPQRSTUVWX",
        ),
        (
            "a private key block",
            "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----",
            "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC",
        ),
        (
            "a password assignment",
            "DB_PASSWORD=hunter2hunter2",
            "hunter2hunter2",
        ),
    ];
    for (label, secret, needle) in secrets {
        let body = format!("model: claude\n{secret}\n12k tokens used");
        for (form, line) in [
            ("form A", form_a("context", "", &body)),
            (
                "form C",
                system_local(&format!(
                    "<local-command-stdout>{body}</local-command-stdout>"
                )),
            ),
            ("form B", user_stdout(&body, true)),
        ] {
            let out = local_of(&line).output;
            assert!(!out.contains(needle), "{label} ({form}) leaked: {out:?}");
            assert!(
                out.contains("redacted"),
                "{label} ({form}) left no marker: {out:?}"
            );
            assert!(out.contains("model: claude"), "{label} ({form}): {out:?}");
            assert!(out.contains("12k tokens used"), "{label} ({form}): {out:?}");
        }
    }
}

// ── parsing: the harness lines ────────────────────────────────────────────────

#[test]
fn harness_tags_are_read_in_either_order() {
    // Local commands store <command-name> first (with the CLI's indentation),
    // prompt-type commands <command-message> first.
    for text in [
        "<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args>all of it</command-args>",
        "<command-message>context</command-message>\n<command-name>/context</command-name>\n<command-args>all of it</command-args>",
        "<command-args>all of it</command-args>\n<command-name>/context</command-name>",
    ] {
        assert_eq!(
            echo_of(&user_text(text)),
            ("context".to_owned(), "all of it".to_owned(), false),
            "{text:?}"
        );
    }
}

#[test]
fn a_harness_line_with_no_args_has_empty_args_and_a_replayed_one_is_marked() {
    let text = "<command-message>hi</command-message>\n<command-name>/hi</command-name>";
    let live = json!({"type": "user", "isReplay": true,
        "message": {"role": "user", "content": text}})
    .to_string();

    assert_eq!(echo_of(&live), ("hi".to_owned(), String::new(), true));
    assert_eq!(
        echo_of(&user_text(text)),
        ("hi".to_owned(), String::new(), false)
    );
}

#[test]
fn a_harness_line_in_a_text_block_array_is_read_too() {
    let line = json!({"type": "user", "isReplay": true, "message": {"role": "user",
        "content": [{"type": "text", "text": "<command-name>/model</command-name>\n<command-args>opus</command-args>"}]}})
    .to_string();

    assert_eq!(
        echo_of(&line),
        ("model".to_owned(), "opus".to_owned(), true)
    );
}

#[test]
fn the_caveat_system_reminders_and_unknown_local_command_kinds_still_make_nothing() {
    for text in [
        "<local-command-caveat>Caveat: the messages below were generated by the user while running local commands.</local-command-caveat>",
        "<system-reminder>\nA reminder.\n</system-reminder>",
        "<local-command-some-future-kind>whatever</local-command-some-future-kind>",
    ] {
        for line in [
            user_text(text),
            json!({"type": "user", "isReplay": true,
                "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
            .to_string(),
        ] {
            assert!(parse_line(&line).is_none(), "{text:?}");
            let mut t = SessionTranscript::new();
            assert!(t.ingest_line(&line).is_empty(), "{text:?}");
            assert_eq!(t.turn_count(), 0, "{text:?}");
        }
    }
}

#[test]
fn a_prompt_that_only_mentions_a_tag_is_still_a_prompt() {
    for text in [
        "what does <local-command-stdout> mean in the transcript?",
        "please explain the <command-name> tag to me",
        "I saw <command-message>hi</command-message> in the log, why?",
        "the text <local-command-stderr>x</local-command-stderr> appears mid-sentence",
    ] {
        match parse_line(&user_text(text)) {
            Some(ParsedLine::UserPrompt { text: t, .. }) => assert_eq!(t, text),
            other => panic!("{text:?} should stay a prompt, got {other:?}"),
        }
    }
}

// ── transcript: stored (replay) ───────────────────────────────────────────────

#[test]
fn a_stored_local_command_triple_is_exactly_one_complete_record_that_is_no_prompt() {
    let t = stored(&[
        user_text("<local-command-caveat>Caveat: generated while running local commands.</local-command-caveat>"),
        user_text("<command-name>/context</command-name>\n            <command-message>context</command-message>\n            <command-args></command-args>"),
        system_local("<local-command-stdout>Context Usage\n12k / 200k</local-command-stdout>"),
    ]);

    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert!(turns[0].is_complete);
    assert_eq!(turns[0].user_input, "/context");
    assert!(matches!(
        &turns[0].origin,
        Some(TurnOrigin::LocalCommand { command, args, output, stream, truncated })
            if command == "context" && args.is_empty()
                && output == "Context Usage\n12k / 200k" && stream == "stdout" && !truncated
    ));
    assert_eq!(t.prompt_count(), 0);
    assert_eq!(t.first_user_input(), None);
}

#[test]
fn the_stored_model_switch_triple_makes_no_turn_and_no_record() {
    let t = stored(&[
        user_text("first question"),
        user_text("<local-command-caveat>Caveat: generated while running local commands.</local-command-caveat>"),
        user_text("<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>"),
        user_stdout("Set model to opus (claude-opus-5-5)", false),
    ]);
    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "first question");
    assert_eq!(t.prompt_count(), 1);

    // Any other stored local command is still a record.
    let t = stored(&[
        user_text("<command-name>/model</command-name>\n<command-args></command-args>"),
        user_stdout("Currently using opus", false),
    ]);
    assert_eq!(t.snapshot().len(), 1);
}

#[test]
fn a_stored_local_command_whose_output_is_a_user_line_is_the_same_record() {
    let t = stored(&[
        user_text("<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args>keep the plan</command-args>"),
        user_stdout("Compacted ", false),
    ]);

    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert!(matches!(
        &turns[0].origin,
        Some(TurnOrigin::LocalCommand { command, args, output, .. })
            if command == "compact" && args == "keep the plan" && output.trim() == "Compacted"
    ));
    assert_eq!(turns[0].user_input, "/compact keep the plan");
    assert_eq!(t.prompt_count(), 0);
}

#[test]
fn stored_local_output_with_no_command_line_before_it_names_nothing_and_makes_no_turn() {
    let t = stored(&[system_local(
        "<local-command-stdout>orphan</local-command-stdout>",
    )]);
    assert_eq!(t.turn_count(), 0);
}

#[test]
fn a_stored_prompt_type_command_is_the_users_slash_turn_then_the_skill_marker_holding_the_reply() {
    let t = stored(&[
        user_text("<command-message>hi</command-message>\n<command-name>/hi</command-name>"),
        json!({"type": "user", "isMeta": true, "message": {"role": "user",
            "content": "Base directory for this skill: /home/user/.claude/skills/hi\n\nSay hello."}})
        .to_string(),
        reply("hello from the skill"),
    ]);

    let turns = t.snapshot();
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_eq!(turns[0].user_input, "/hi");
    assert_eq!(
        turns[0].origin, None,
        "the user's own turn is a normal bubble"
    );
    assert!(texts(&turns[0]).is_empty());
    assert!(matches!(
        &turns[1].origin,
        Some(TurnOrigin::InjectedContext { kind, .. }) if kind == "skill"
    ));
    assert_eq!(texts(&turns[1]), vec!["hello from the skill"]);
    assert_eq!(t.prompt_count(), 1);
    assert_eq!(t.first_user_input(), Some("/hi"));
}

#[test]
fn a_lone_trailing_harness_line_is_the_users_slash_turn() {
    let t = stored(&[
        user_text("<command-message>later</command-message>\n<command-name>/later</command-name>\n<command-args>tomorrow</command-args>"),
    ]);

    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "/later tomorrow");
    assert_eq!(turns[0].origin, None);
    assert!(turns[0].is_complete);
    assert_eq!(t.prompt_count(), 1);
}

#[test]
fn a_stored_harness_line_followed_by_a_prompt_or_a_reply_is_the_users_turn_first() {
    let t = stored(&[
        user_text("<command-message>hi</command-message>\n<command-name>/hi</command-name>"),
        reply("an answer with no skill marker"),
    ]);
    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "/hi");
    assert_eq!(texts(&turns[0]), vec!["an answer with no skill marker"]);

    let t = stored(&[
        user_text("<command-message>hi</command-message>\n<command-name>/hi</command-name>"),
        user_text("a real prompt"),
    ]);
    let inputs: Vec<String> = t.snapshot().into_iter().map(|t| t.user_input).collect();
    assert_eq!(inputs, vec!["/hi", "a real prompt"]);
    assert_eq!(t.prompt_count(), 2);
}

#[test]
fn the_stored_fixture_makes_the_turns_it_describes() {
    let t = transcript_from_jsonl(STORED, 100);
    let turns = t.snapshot();

    let inputs: Vec<&str> = turns.iter().map(|t| t.user_input.as_str()).collect();
    assert_eq!(inputs.len(), 7, "{inputs:?}");
    // Index 5 is the skill marker, whose stand-in line is the marker's own.
    assert_eq!(
        [inputs[0], inputs[1], inputs[2], inputs[3], inputs[4], inputs[6]],
        [
            "first question",
            "/context",
            "second question",
            "/compact",
            "/hi",
            "/later tomorrow"
        ]
    );
    let records: Vec<usize> = turns
        .iter()
        .enumerate()
        .filter(|(_, t)| is_record(t))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(records, vec![1, 3]);
    assert!(matches!(
        &turns[1].origin,
        Some(TurnOrigin::LocalCommand { command, output, .. })
            if command == "context" && output.contains("12.3k / 200k tokens (6%)")
    ));
    assert!(matches!(
        &turns[3].origin,
        Some(TurnOrigin::LocalCommand { command, output, .. })
            if command == "compact" && output.trim() == "Compacted"
    ));
    assert!(matches!(
        &turns[5].origin,
        Some(TurnOrigin::InjectedContext { kind, .. }) if kind == "skill"
    ));
    assert_eq!(texts(&turns[5]), vec!["hello from the skill"]);
    // The earlier turns keep exactly their own reply.
    assert_eq!(texts(&turns[0]), vec!["first answer"]);
    assert_eq!(texts(&turns[2]), vec!["second answer"]);
    // Prompts: the two questions, /hi and /later. The records and the skill
    // marker are not prompts.
    assert_eq!(t.prompt_count(), 4);
    assert_eq!(t.first_user_input(), Some("first question"));
    assert!(turns.iter().all(|t| t.is_complete));
}

#[test]
fn the_title_is_never_a_local_command_even_when_it_is_the_oldest_surviving_turn() {
    let t = stored(&[
        user_text("<command-name>/context</command-name>\n<command-args></command-args>"),
        system_local("<local-command-stdout>12k</local-command-stdout>"),
        user_text("the first real prompt"),
        reply("ok"),
    ]);

    assert_eq!(t.first_user_input(), Some("the first real prompt"));
    assert_eq!(t.prompt_count(), 1);
}

// ── transcript: live ──────────────────────────────────────────────────────────

fn live_transcript(lines: &[&str]) -> SessionTranscript {
    let mut t = SessionTranscript::new();
    t.set_live(true);
    for l in lines {
        let _ = t.ingest_line(l);
    }
    t
}

#[test]
fn a_live_local_command_is_one_record_turn_and_never_touches_the_turn_before_it() {
    let mut t = SessionTranscript::new();
    t.set_live(true);
    let mut lines = STREAM.lines();
    // init, commands_changed, "hello", its reply and result.
    for l in lines.by_ref().take(5) {
        let _ = t.ingest_line(l);
    }
    let before = t.snapshot();
    assert_eq!(before.len(), 1);
    assert!(before[0].is_complete);

    // The local command's assistant line and its result (num_turns 0).
    for l in lines.by_ref().take(2) {
        let _ = t.ingest_line(l);
    }

    let turns = t.snapshot();
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_eq!(turns[0], before[0], "the previous turn gained a block");
    assert_eq!(turns[1].user_input, "/model haiku");
    assert!(turns[1].is_complete);
    assert!(matches!(
        &turns[1].origin,
        Some(TurnOrigin::LocalCommand { command, args, output, stream, truncated })
            if command == "model" && args == "haiku"
                && output == "Set model to `Haiku 5.5` for this session only"
                && stream == "stdout" && !truncated
    ));
    assert!(
        texts(&turns[1]).is_empty(),
        "the output lives in the origin, not a text block"
    );
    assert_eq!(t.prompt_count(), 1, "the record is no prompt");
    assert_eq!(t.first_user_input(), Some("hello"));
}

#[test]
fn the_live_fixture_makes_a_prompt_a_record_and_a_prompt_type_command_turn_in_order() {
    let lines: Vec<&str> = STREAM.lines().collect();
    let t = live_transcript(&lines);

    let turns = t.snapshot();
    let inputs: Vec<&str> = turns.iter().map(|t| t.user_input.as_str()).collect();
    assert_eq!(inputs, vec!["hello", "/model haiku", "/hi"]);
    assert_eq!(turns[0].origin, None);
    assert!(is_record(&turns[1]));
    assert_eq!(
        turns[2].origin, None,
        "a prompt-type command is the user's bubble"
    );
    assert_eq!(texts(&turns[0]), vec!["Hi there."]);
    assert_eq!(texts(&turns[2]), vec!["Hello from the hi command."]);
    assert!(turns.iter().all(|t| t.is_complete));
    assert_eq!(t.prompt_count(), 2);
    assert_eq!(t.first_user_input(), Some("hello"));
}

#[test]
fn a_live_command_echo_that_is_not_a_replay_makes_no_turn() {
    let line = user_text("<command-message>hi</command-message>\n<command-name>/hi</command-name>");
    let t = live_transcript(&[line.as_str()]);
    assert_eq!(t.turn_count(), 0);
}

#[test]
fn the_records_wire_form_is_what_a_client_reads() {
    let t = stored(&[
        user_text("<command-name>/context</command-name>\n<command-args></command-args>"),
        system_local("<local-command-stdout>12k</local-command-stdout>"),
    ]);
    let wire: Value = serde_json::to_value(&t.snapshot()[0]).unwrap();

    assert_eq!(
        wire["origin"],
        json!({"type": "local_command", "command": "context", "args": "",
               "output": "12k", "stream": "stdout"})
    );
}
