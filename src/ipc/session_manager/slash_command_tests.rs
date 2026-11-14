//! Slash commands in a live session (Claude Code 2.1.318), seen through real
//! (stub) child processes whose stdout is read as stream-json, as in
//! `injected_tests.rs`.
//!
//! Contract under test (the classification rule is in `stream_json::local_command`):
//!
//! * a LOCAL command the daemon wrote (`/model haiku`, answered by the CLI with
//!   no model turn) is ONE record turn: `user_input` the typed text, origin
//!   `LocalCommand`, complete; the turn before it gains nothing; the session is
//!   Idle after it and a message queued behind it is written; the record is no
//!   prompt (`prompt_count`, the title) and no agent turn (the focus counters,
//!   no `NoText` problem); the written message is its (the user is the author);
//! * a PROMPT-TYPE command (`/hi`) is the user's own turn holding the
//!   assistant's reply, the written message bound to it;
//! * a user line holding `<local-command-stdout>` is a record only while a
//!   typed `/` message the daemon wrote is unanswered; otherwise it is dropped;
//! * the commands a session reports (`system/init`, `system/commands_changed`)
//!   are kept per tag, a described list is never downgraded by a bare name list
//!   and survives a restart of the session; `observe` applies the picker's
//!   limits to what the CLI says.
//!
//! All text is fake.

use super::injected_tests::{
    eventually, spawn_stub, tmp_store, turns_of, wait_turns, ASSISTANT_LINE, RESULT_LINE,
};
use super::slash_commands::{observe, CatalogSource, CommandBook, CommandCatalog};
use super::*;
use crate::ipc::protocol::SlashCommandEntry;
use crate::ipc::stream_json::{Turn, TurnBlock};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;

// ── lines the CLI writes ──────────────────────────────────────────────────────

const FORM_A: &str = r#"{"type":"assistant","parent_tool_use_id":null,"local_command_source":"<local-command-stdout>Set model to `Haiku 5.5` for this session only</local-command-stdout>","local_command_run":{"command":"model","args":"haiku"},"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Set model to `Haiku 5.5` for this session only"}]},"session_id":"s","uuid":"u","timestamp":"2026-11-13T19:20:23.436Z"}"#;
const RESULT_LOCAL: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":0,"duration_api_ms":0,"num_turns":0,"total_cost_usd":0}"#;
const FORM_B: &str = r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"},"isReplay":true}"#;
/// The harness echo of a prompt-type command, with no arguments in its tags.
const HI_ECHO: &str = r#"{"type":"user","isReplay":true,"message":{"role":"user","content":"<command-message>hi</command-message>\n<command-name>/hi</command-name>"}}"#;

fn init_line(names: &[&str]) -> String {
    json!({"type": "system", "subtype": "init", "session_id": "s", "slash_commands": names})
        .to_string()
}

fn changed_line(commands: Value) -> String {
    json!({"type": "system", "subtype": "commands_changed", "commands": commands}).to_string()
}

// ── the stub ──────────────────────────────────────────────────────────────────

/// A stub CLI. `preface` is printed on start; then for each frame read on
/// stdin the first `cases` entry whose pattern the frame contains prints its
/// lines; any other frame is echoed (`isReplay`), answered with an assistant
/// line and a result, after `before_plain` lines when given.
struct Stub {
    dir: tempfile::TempDir,
    preface: Vec<String>,
    cases: Vec<(String, Vec<String>)>,
    before_plain: Vec<String>,
}

impl Stub {
    fn new() -> Self {
        Stub {
            dir: tempfile::tempdir().unwrap(),
            preface: vec![],
            cases: vec![],
            before_plain: vec![],
        }
    }

    fn case(mut self, pattern: &str, lines: &[&str]) -> Self {
        self.cases.push((
            pattern.into(),
            lines.iter().map(|l| l.to_string()).collect(),
        ));
        self
    }

    fn preface(mut self, lines: &[String]) -> Self {
        self.preface = lines.to_vec();
        self
    }

    fn before_plain(mut self, lines: &[&str]) -> Self {
        self.before_plain = lines.iter().map(|l| l.to_string()).collect();
        self
    }

    fn file(&self, name: &str, lines: &[String]) -> String {
        let path = self.dir.path().join(name);
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
        path.display().to_string()
    }

    fn script(&self) -> String {
        let mut s = String::new();
        if !self.preface.is_empty() {
            s += &format!("cat '{}'\n", self.file("preface.jsonl", &self.preface));
        }
        s += "while IFS= read -r line; do\n  case \"$line\" in\n";
        for (i, (pattern, lines)) in self.cases.iter().enumerate() {
            let f = self.file(&format!("case{i}.jsonl"), lines);
            s += &format!("    *'{pattern}'*) cat '{f}' ;;\n");
        }
        let before = if self.before_plain.is_empty() {
            String::new()
        } else {
            format!(
                "      cat '{}'\n",
                self.file("before.jsonl", &self.before_plain)
            )
        };
        s += &format!(
            "    *'\"type\":\"user\"'*)\n{before}      printf '%s\\n' \"${{line%\\}}}},\\\"isReplay\\\":true}}\"\n      printf '%s\\n' '{ASSISTANT_LINE}'\n      printf '%s\\n' '{RESULT_LINE}'\n      ;;\n  esac\ndone\n"
        );
        s
    }
}

// ── the rig ───────────────────────────────────────────────────────────────────

/// A manager that kills every stub child when dropped, so a failing assertion
/// cannot leave a reader thread blocking the runtime's shutdown.
struct Mgr(SessionManager);

impl Mgr {
    fn new() -> Self {
        Mgr(SessionManager::with_store_path(tmp_store()))
    }
}

impl std::ops::Deref for Mgr {
    type Target = SessionManager;
    fn deref(&self) -> &SessionManager {
        &self.0
    }
}

impl std::ops::DerefMut for Mgr {
    fn deref_mut(&mut self) -> &mut SessionManager {
        &mut self.0
    }
}

impl Drop for Mgr {
    fn drop(&mut self) {
        self.0.kill_all_on_shutdown();
    }
}

type Heard = Arc<Mutex<Vec<TurnEvent>>>;

fn record_turns(mgr: &mut SessionManager) -> Heard {
    let heard: Heard = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&heard);
    mgr.set_turn_hook(Arc::new(move |_tag: &str, event: &TurnEvent| {
        sink.lock().unwrap().push(event.clone());
    }));
    heard
}

async fn events(heard: &Heard, n: usize) -> Vec<TurnEvent> {
    eventually(&format!("{n} turn events"), || {
        let seen = heard.lock().unwrap().clone();
        (seen.len() >= n).then_some(seen)
    })
    .await
}

/// `n` turns, the last complete, and the session Idle.
async fn settled(mgr: &SessionManager, tag: &str, n: usize) -> Vec<Turn> {
    wait_turns(mgr, tag, n).await;
    eventually("the last turn complete and the session idle", || {
        (turns_of(mgr, tag).last().is_some_and(|t| t.is_complete)
            && mgr.session_state(tag) == Some(SessionState::Idle))
        .then_some(())
    })
    .await;
    // Anything a stray later line would add has had time to arrive.
    tokio::time::sleep(Duration::from_millis(150)).await;
    turns_of(mgr, tag)
}

/// (agent turns, agent messages, agent problems) as the sidebar reads them.
fn counts(mgr: &SessionManager, tag: &str) -> (u64, u64, u64) {
    let i = mgr
        .list()
        .into_iter()
        .find(|i| i.tag == tag)
        .expect("the session is listed");
    (
        i.agent_turns.expect("agent_turns is always sent"),
        i.agent_messages.expect("agent_messages is always sent"),
        i.agent_problems.expect("agent_problems is always sent"),
    )
}

fn prompts(mgr: &SessionManager, tag: &str) -> (u64, Option<String>) {
    let t = lock_recover(&mgr.sessions[tag].shared.transcript);
    (t.prompt_count(), t.first_user_input().map(str::to_owned))
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

fn local_command_stub() -> Stub {
    Stub::new().case("/model haiku", &[FORM_A, RESULT_LOCAL])
}

fn assert_model_record(turn: &Turn) {
    assert_eq!(turn.user_input, "/model haiku");
    assert!(turn.is_complete);
    assert!(
        matches!(
            &turn.origin,
            Some(TurnOrigin::LocalCommand { command, args, output, stream, truncated, .. })
                if command == "model" && args == "haiku"
                    && output == "Set model to `Haiku 5.5` for this session only"
                    && stream == "stdout" && !truncated
        ),
        "{turn:?}"
    );
    assert!(
        texts(turn).is_empty(),
        "the output is in the origin: {turn:?}"
    );
}

// ── a local command (form A) ──────────────────────────────────────────────────

#[tokio::test]
async fn a_local_command_typed_mid_session_is_one_complete_record_and_changes_nothing_before_it() {
    let stub = local_command_stub();
    let mut mgr = Mgr::new();
    let heard = record_turns(&mut mgr);
    spawn_stub(&mut mgr, "lc", &stub.script());
    mgr.send_user_message("lc", "hello", &[]).unwrap();
    let before = settled(&mgr, "lc", 1).await;
    assert_eq!(counts(&mgr, "lc"), (1, 1, 0));
    assert_eq!(texts(&before[0]), vec!["ok"]);

    mgr.send_user_message("lc", "/model haiku", &[]).unwrap();
    let turns = settled(&mgr, "lc", 2).await;

    assert_eq!(turns.len(), 2, "exactly one record turn: {turns:?}");
    assert_eq!(turns[0], before[0], "the previous turn gained a block");
    assert_model_record(&turns[1]);
    assert_eq!(mgr.session_state("lc"), Some(SessionState::Idle));
    // The record is no prompt and no agent turn.
    assert_eq!(prompts(&mgr, "lc"), (1, Some("hello".to_owned())));
    assert_eq!(
        counts(&mgr, "lc"),
        (1, 1, 0),
        "a local command is not an agent turn and never a NoText problem"
    );
    // The user wrote the command: the turn is theirs.
    assert_eq!(
        events(&heard, 4).await,
        vec![
            TurnEvent::Started {
                author: TurnAuthor::User
            },
            TurnEvent::Completed,
            TurnEvent::Started {
                author: TurnAuthor::User
            },
            TurnEvent::Completed,
        ]
    );
    mgr.stop("lc");
}

#[tokio::test]
async fn a_local_command_as_the_sessions_first_message_is_a_record_and_nothing_else() {
    let stub = local_command_stub();
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "first", &stub.script());

    mgr.send_user_message("first", "/model haiku", &[]).unwrap();
    let turns = settled(&mgr, "first", 1).await;

    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_model_record(&turns[0]);
    assert_eq!(prompts(&mgr, "first"), (0, None));
    assert_eq!(counts(&mgr, "first"), (0, 0, 0));
    mgr.stop("first");
}

#[tokio::test]
async fn a_message_queued_behind_a_local_command_is_written_when_the_commands_result_arrives() {
    let stub = local_command_stub();
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "q", &stub.script());

    mgr.send_user_message("q", "/model haiku", &[]).unwrap();
    mgr.send_user_message("q", "after the command", &[])
        .unwrap();
    let turns = settled(&mgr, "q", 2).await;

    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_model_record(&turns[0]);
    assert_eq!(turns[1].user_input, "after the command");
    assert_eq!(turns[1].origin, None);
    assert_eq!(texts(&turns[1]), vec!["ok"]);
    assert_eq!(
        prompts(&mgr, "q"),
        (1, Some("after the command".to_owned())),
        "the record is not the title"
    );
    assert_eq!(counts(&mgr, "q"), (1, 1, 0));
    assert_eq!(mgr.session_state("q"), Some(SessionState::Idle));
    mgr.stop("q");
}

// ── a prompt-type command ─────────────────────────────────────────────────────

#[tokio::test]
async fn a_prompt_type_command_is_the_users_turn_holding_the_reply_and_the_written_message_is_bound_to_it(
) {
    // The stub's echo carries no arguments in its tags; the turn is the text
    // the daemon wrote, which is what a client's optimistic echo adopts.
    let stub = Stub::new().case("\"/hi there", &[HI_ECHO, ASSISTANT_LINE, RESULT_LINE]);
    let mut mgr = Mgr::new();
    let heard = record_turns(&mut mgr);
    spawn_stub(&mut mgr, "hi", &stub.script());

    mgr.send_user_message("hi", "/hi there", &[]).unwrap();
    let turns = settled(&mgr, "hi", 1).await;

    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "/hi there");
    assert_eq!(turns[0].origin, None, "a normal bubble, not a record");
    assert_eq!(texts(&turns[0]), vec!["ok"]);
    assert!(turns[0].is_complete);
    assert_eq!(prompts(&mgr, "hi"), (1, Some("/hi there".to_owned())));
    assert_eq!(counts(&mgr, "hi"), (1, 1, 0));
    assert_eq!(
        events(&heard, 2).await,
        vec![
            TurnEvent::Started {
                author: TurnAuthor::User
            },
            TurnEvent::Completed
        ],
        "the written message is bound to the turn, not left for a later one"
    );
    mgr.stop("hi");
}

// ── a local command's answer as a user line (form B) ──────────────────────────

#[tokio::test]
async fn a_stdout_user_line_answering_an_unanswered_slash_write_is_a_record() {
    let stub = Stub::new().case("/compact", &[FORM_B, RESULT_LOCAL]);
    let mut mgr = Mgr::new();
    let heard = record_turns(&mut mgr);
    spawn_stub(&mut mgr, "b", &stub.script());

    mgr.send_user_message("b", "/compact", &[]).unwrap();
    let turns = settled(&mgr, "b", 1).await;

    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "/compact");
    assert!(turns[0].is_complete);
    assert!(matches!(
        &turns[0].origin,
        Some(TurnOrigin::LocalCommand { command, output, stream, .. })
            if command == "compact" && output.trim() == "Compacted" && stream == "stdout"
    ));
    assert_eq!(prompts(&mgr, "b"), (0, None));
    assert_eq!(counts(&mgr, "b"), (0, 0, 0));
    assert_eq!(
        events(&heard, 2).await,
        vec![
            TurnEvent::Started {
                author: TurnAuthor::User
            },
            TurnEvent::Completed
        ]
    );
    mgr.stop("b");
}

#[tokio::test]
async fn a_stdout_user_line_beside_a_plain_message_makes_no_record() {
    // The CLI wrote it, but what the daemon wrote is not a slash command.
    let stub = Stub::new().before_plain(&[FORM_B]);
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "plain", &stub.script());

    mgr.send_user_message("plain", "hello", &[]).unwrap();
    let turns = settled(&mgr, "plain", 1).await;

    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(turns[0].user_input, "hello");
    assert_eq!(turns[0].origin, None);
    assert_eq!(texts(&turns[0]), vec!["ok"]);
    assert_eq!(prompts(&mgr, "plain"), (1, Some("hello".to_owned())));
    mgr.stop("plain");
}

#[tokio::test]
async fn a_stdout_user_line_with_nothing_written_makes_no_turn() {
    // Unprompted, then a commands list as a marker that the reader got past it.
    let stub = Stub::new().preface(&[
        FORM_B.to_owned(),
        changed_line(json!([{"name": "compact"}])),
    ]);
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "quiet", &stub.script());

    eventually("the line after it was read", || {
        (mgr.session_commands("quiet").0 == CatalogSource::Cli).then_some(())
    })
    .await;

    assert!(turns_of(&mgr, "quiet").is_empty());
    assert_eq!(prompts(&mgr, "quiet"), (0, None));
    mgr.stop("quiet");
}

#[tokio::test]
async fn a_command_echo_with_nothing_written_opens_no_turn() {
    // An older CLI's replayed harness line, unprompted: no turn that no `result`
    // would ever end.
    let stub = Stub::new().preface(&[HI_ECHO.to_owned(), changed_line(json!([{"name": "hi"}]))]);
    let mut mgr = Mgr::new();
    spawn_stub(&mut mgr, "echo-quiet", &stub.script());

    eventually("the line after it was read", || {
        (mgr.session_commands("echo-quiet").0 == CatalogSource::Cli).then_some(())
    })
    .await;

    assert!(turns_of(&mgr, "echo-quiet").is_empty());
    assert_eq!(prompts(&mgr, "echo-quiet"), (0, None));
    mgr.stop("echo-quiet");
}

// ── the catalog's rules (`observe`) ───────────────────────────────────────────

fn observed(commands: Value) -> Vec<SlashCommandEntry> {
    let update = observe(&changed_line(commands)).expect("a commands_changed line");
    assert_eq!(update.source, CatalogSource::Cli);
    update.entries
}

fn entry(v: &Value) -> SlashCommandEntry {
    let mut out = observed(json!([v]));
    assert_eq!(out.len(), 1, "{v}");
    out.remove(0)
}

#[test]
fn commands_changed_describes_each_command_in_order() {
    let entries = observed(json!([
        {"name": "compact", "description": "Free up context by summarizing the conversation so far",
         "argumentHint": "<optional>", "builtin": true},
        {"name": "usage", "description": "Show plan usage", "argumentHint": "",
         "aliases": ["cost", "stats"], "builtin": true},
        {"name": "hookify:list", "description": "(hookify) List all configured hookify rules"},
    ]));

    assert_eq!(
        entries,
        vec![
            SlashCommandEntry {
                name: "compact".into(),
                description: Some("Free up context by summarizing the conversation so far".into()),
                argument_hint: Some("<optional>".into()),
                aliases: vec![],
                builtin: true,
            },
            SlashCommandEntry {
                name: "usage".into(),
                description: Some("Show plan usage".into()),
                argument_hint: None,
                aliases: vec!["cost".into(), "stats".into()],
                builtin: true,
            },
            SlashCommandEntry {
                name: "hookify:list".into(),
                description: Some("(hookify) List all configured hookify rules".into()),
                argument_hint: None,
                aliases: vec![],
                builtin: false,
            },
        ]
    );
}

#[test]
fn init_names_are_a_bare_list_and_commands_changed_names_the_source() {
    let update = observe(&init_line(&["a", "b"])).expect("an init line");

    assert_eq!(update.source, CatalogSource::Init);
    assert_eq!(
        update
            .entries
            .iter()
            .map(|e| e.name.as_str())
            .collect::<Vec<_>>(),
        vec!["a", "b"]
    );
    assert!(update
        .entries
        .iter()
        .all(|e| e.description.is_none() && e.argument_hint.is_none() && e.aliases.is_empty()));
    assert_eq!(CatalogSource::None.as_str(), "none");
    assert_eq!(CatalogSource::Init.as_str(), "init");
    assert_eq!(CatalogSource::Cli.as_str(), "cli");
}

#[test]
fn names_the_picker_cannot_insert_are_skipped() {
    let entries = observed(json!([
        {"name": "ok"},
        {"name": "has space"},
        {"name": "claude.ai HubSpot:list-my-assigned-contacts (MCP)", "description": "x"},
        {"name": "server:prompt (MCP)"},
        {"name": ""},
        {"name": "also-ok"},
    ]));
    assert_eq!(
        entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        vec!["ok", "also-ok"]
    );

    let init = observe(&init_line(&["a", "b c", "x (MCP)", "", "d"])).unwrap();
    assert_eq!(
        init.entries
            .iter()
            .map(|e| e.name.as_str())
            .collect::<Vec<_>>(),
        vec!["a", "d"]
    );
}

#[test]
fn hostile_names_and_aliases_never_reach_the_list() {
    let long = "x".repeat(5000);
    let bad = [
        "evil\u{202E}gnp".to_owned(),
        "esc\u{1b}[31mred".to_owned(),
        "zw\u{200B}sp".to_owned(),
        "bom\u{FEFF}x".to_owned(),
        "iso\u{2066}x".to_owned(),
        "tab\tx".to_owned(),
        long.clone(),
    ];
    let mut commands: Vec<Value> = bad.iter().map(|n| json!({"name": n})).collect();
    commands.push(json!({
        "name": "ns:name-with-dash",
        "aliases": ["ok-alias", bad[0], bad[1], bad[2], bad[6]],
    }));
    let entries = observed(json!(commands));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "ns:name-with-dash");
    assert_eq!(entries[0].aliases, vec!["ok-alias"]);

    let init = observe(&init_line(&[
        &bad[0],
        &bad[1],
        &bad[6],
        "ns:name-with-dash",
    ]))
    .unwrap();
    assert_eq!(init.entries.len(), 1);
    assert_eq!(init.entries[0].name, "ns:name-with-dash");

    let at_limit = "y".repeat(64);
    assert_eq!(entry(&json!({"name": at_limit})).name, at_limit);
}

#[test]
fn a_catalog_keeps_at_most_five_hundred_commands_and_the_first_ones() {
    let many: Vec<Value> = (0..600).map(|i| json!({"name": format!("c{i}")})).collect();
    let entries = observed(Value::Array(many));
    assert_eq!(entries.len(), 500);
    assert_eq!(entries[0].name, "c0");
    assert_eq!(entries[499].name, "c499");

    let names: Vec<String> = (0..600).map(|i| format!("n{i}")).collect();
    let refs: Vec<&str> = names.iter().map(String::as_str).collect();
    assert_eq!(observe(&init_line(&refs)).unwrap().entries.len(), 500);
}

#[test]
fn descriptions_hints_and_aliases_are_cut_to_the_pickers_limits() {
    let e = entry(&json!({
        "name": "x",
        "description": format!("first line\nsecond line {}", "z".repeat(10)),
        "argumentHint": "h".repeat(100),
    }));
    assert_eq!(e.description.as_deref(), Some("first line"), "{e:?}");
    assert!(e.argument_hint.unwrap().chars().count() <= 80);

    let long = entry(&json!({"name": "x", "description": "d".repeat(300)}));
    let d = long.description.unwrap();
    assert!(d.chars().count() <= 200, "{}", d.chars().count());
    assert!(d.starts_with("dddddddd"));

    let aliases: Vec<String> = (0..12).map(|i| format!("a{i}")).collect();
    let e = entry(&json!({"name": "x", "aliases": aliases}));
    assert_eq!(e.aliases.len(), 8);
    assert_eq!(e.aliases[0], "a0");

    let e = entry(&json!({"name": "x", "aliases": ["y".repeat(50)]}));
    assert_eq!(e.aliases.len(), 1);
    assert!(e.aliases[0].chars().count() <= 32);
}

#[test]
fn control_characters_in_a_description_are_removed() {
    let e =
        entry(&json!({"name": "x", "description": "plain \u{1b}[31mred\u{1b}[0m \u{202E}text"}));
    let d = e.description.unwrap();
    assert!(
        !d.chars().any(|c| c.is_control() || c == '\u{202E}'),
        "{d:?}"
    );
    assert!(d.starts_with("plain"));
}

#[test]
fn a_malformed_entry_is_skipped_and_never_fatal_and_unknown_fields_are_ignored() {
    let entries = observed(json!([
        {"name": 5},
        {"description": "no name"},
        "a string",
        null,
        7,
        {"name": "odd", "description": ["not", "text"], "aliases": "nope", "builtin": "yes"},
        {"name": "fine", "description": "d", "futureField": {"a": [1, 2]}, "another": true},
    ]));

    assert_eq!(entries.len(), 2, "{entries:?}");
    assert_eq!(
        entries[0],
        SlashCommandEntry {
            name: "odd".into(),
            description: None,
            argument_hint: None,
            aliases: vec![],
            builtin: false,
        }
    );
    assert_eq!(entries[1].name, "fine");
    assert_eq!(entries[1].description.as_deref(), Some("d"));
}

#[test]
fn lines_that_are_not_a_commands_report_are_not_one() {
    for line in [
        // Quotes the words, but is neither a system init nor commands_changed.
        json!({"type": "assistant", "message": {"role": "assistant",
            "content": [{"type": "text", "text": "the \"commands_changed\" event and \"slash_commands\""}]}})
        .to_string(),
        json!({"type": "user", "message": {"role": "user", "content": "commands_changed"}})
            .to_string(),
        // The right shape with no list.
        json!({"type": "system", "subtype": "commands_changed"}).to_string(),
        json!({"type": "system", "subtype": "init", "session_id": "s"}).to_string(),
        r#"{"type":"system","subtype":"commands_changed","commands":"#.to_owned(),
        "not json but says commands_changed".to_owned(),
        // Another system event that happens to carry `commands`.
        json!({"type": "system", "subtype": "other", "commands": [{"name": "x"}]}).to_string(),
        String::new(),
    ] {
        assert_eq!(observe(&line), None, "{line}");
    }
}

#[test]
fn an_enormous_line_is_not_read_for_commands() {
    let big = changed_line(json!([{"name": "x", "description": "d".repeat(5 * 1024 * 1024)}]));
    assert_eq!(observe(&big), None);
}

// ── the catalog and the book ──────────────────────────────────────────────────

fn names(snapshot: &(CatalogSource, Vec<SlashCommandEntry>)) -> Vec<&str> {
    snapshot.1.iter().map(|e| e.name.as_str()).collect()
}

#[test]
fn commands_changed_replaces_the_names_init_gave() {
    let c = CommandCatalog::default();
    assert_eq!(c.snapshot(), (CatalogSource::None, vec![]));

    c.apply(observe(&init_line(&["a", "b"])).unwrap());
    assert_eq!(c.snapshot().0, CatalogSource::Init);
    assert_eq!(names(&c.snapshot()), vec!["a", "b"]);

    c.apply(observe(&changed_line(json!([{"name": "c", "description": "see"}]))).unwrap());
    assert_eq!(c.snapshot().0, CatalogSource::Cli);
    assert_eq!(names(&c.snapshot()), vec!["c"]);
    assert_eq!(c.snapshot().1[0].description.as_deref(), Some("see"));
}

#[test]
fn a_bare_name_list_never_downgrades_a_described_one() {
    let c = CommandCatalog::default();
    c.apply(observe(&changed_line(json!([{"name": "c", "description": "see"}]))).unwrap());

    c.apply(observe(&init_line(&["x", "y", "z"])).unwrap());

    assert_eq!(c.snapshot().0, CatalogSource::Cli);
    assert_eq!(names(&c.snapshot()), vec!["c"]);

    // A later described list still replaces it, even with fewer (or no) entries.
    c.apply(observe(&changed_line(json!([]))).unwrap());
    assert_eq!(c.snapshot(), (CatalogSource::Cli, vec![]));
}

#[test]
fn the_book_keeps_each_tags_commands_apart_and_a_tag_never_seen_is_none() {
    let book = CommandBook::default();
    book.for_tag("a")
        .apply(observe(&changed_line(json!([{"name": "one"}]))).unwrap());
    book.for_tag("b")
        .apply(observe(&init_line(&["two"])).unwrap());

    assert_eq!(names(&book.snapshot("a")), vec!["one"]);
    assert_eq!(book.snapshot("a").0, CatalogSource::Cli);
    assert_eq!(names(&book.snapshot("b")), vec!["two"]);
    assert_eq!(book.snapshot("b").0, CatalogSource::Init);
    assert_eq!(book.snapshot("ghost"), (CatalogSource::None, vec![]));
    assert!(Arc::ptr_eq(&book.for_tag("a"), &book.for_tag("a")));
}

// ── a live session reports its commands ───────────────────────────────────────

#[tokio::test]
async fn a_session_that_prints_init_then_commands_changed_reports_each_through_session_commands() {
    let dir = tempfile::tempdir().unwrap();
    let go = dir.path().join("go");
    let init = dir.path().join("init.jsonl");
    let changed = dir.path().join("changed.jsonl");
    std::fs::write(&init, init_line(&["compact", "hi"]) + "\n").unwrap();
    std::fs::write(
        &changed,
        changed_line(json!([
            {"name": "compact", "description": "Free up context", "argumentHint": "<optional>", "builtin": true},
            {"name": "hi", "description": "(project) Say hello"},
            {"name": "server:prompt (MCP)"},
        ])) + "\n",
    )
    .unwrap();
    let mut mgr = Mgr::new();
    assert_eq!(
        mgr.session_commands("cmds"),
        (CatalogSource::None, vec![]),
        "nothing reported yet"
    );
    spawn_stub(
        &mut mgr,
        "cmds",
        &format!(
            "cat '{}'; while [ ! -e '{}' ]; do sleep 0.05; done; cat '{}'; sleep 30",
            init.display(),
            go.display(),
            changed.display()
        ),
    );

    let first = eventually("the init names", || {
        let s = mgr.session_commands("cmds");
        (s.0 == CatalogSource::Init).then_some(s)
    })
    .await;
    assert_eq!(names(&first), vec!["compact", "hi"]);
    assert!(first.1.iter().all(|e| e.description.is_none()));

    std::fs::write(&go, b"go").unwrap();
    let second = eventually("the described list", || {
        let s = mgr.session_commands("cmds");
        (s.0 == CatalogSource::Cli).then_some(s)
    })
    .await;
    assert_eq!(names(&second), vec!["compact", "hi"]);
    assert_eq!(second.1[0].description.as_deref(), Some("Free up context"));
    assert_eq!(second.1[0].argument_hint.as_deref(), Some("<optional>"));
    assert!(second.1[0].builtin);
    mgr.stop("cmds");
}

#[tokio::test]
async fn a_restarted_session_keeps_the_last_list_and_its_bare_init_does_not_replace_it() {
    let mut mgr = Mgr::new();
    let described = Stub::new().preface(&[
        init_line(&["old"]),
        changed_line(json!([{"name": "old", "description": "the described one"}])),
    ]);
    spawn_stub(&mut mgr, "again", &described.script());
    eventually("the described list", || {
        (mgr.session_commands("again").0 == CatalogSource::Cli).then_some(())
    })
    .await;
    mgr.stop("again");

    // The same focus starts again: its CLI names other commands first.
    let restarted = Stub::new().preface(&[init_line(&["new1", "new2"])]);
    spawn_stub(&mut mgr, "again", &restarted.script());
    mgr.send_user_message("again", "ping", &[]).unwrap();
    // A turn is a marker that the reader got past the new init line.
    settled(&mgr, "again", 1).await;

    let kept = mgr.session_commands("again");
    assert_eq!(kept.0, CatalogSource::Cli);
    assert_eq!(names(&kept), vec!["old"]);
    assert_eq!(kept.1[0].description.as_deref(), Some("the described one"));
    mgr.stop("again");
}

#[tokio::test]
async fn one_tags_commands_are_not_another_tags() {
    let mut mgr = Mgr::new();
    let s = Stub::new().preface(&[changed_line(json!([{"name": "mine"}]))]);
    spawn_stub(&mut mgr, "mine", &s.script());
    eventually("the list", || {
        (mgr.session_commands("mine").0 == CatalogSource::Cli).then_some(())
    })
    .await;

    assert_eq!(mgr.session_commands("other"), (CatalogSource::None, vec![]));
    mgr.stop("mine");
}
