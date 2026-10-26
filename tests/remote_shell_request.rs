//! Terminal pane slice 2a: an agent REQUESTS a remote (ECS) shell, and only a
//! human clicking Connect in the verified app opens it (PRD criteria 13, 14,
//! 16, 17, 18), over the real MCP socket, the real IPC socket and a real TCP
//! listener.
//!
//! * AC1 / C13  a request names project, environment, service and shell type
//!   from the vocabulary (aliases accepted); anything else is refused with the
//!   valid values, and no sheet appears. There is no field for a command.
//! * AC2 / C14  one targeted confirm request, to the verified app that declared
//!   `remote_shell_confirm` and to no one else; nothing launches before Connect.
//! * AC3 / C16  cancel, dismiss and timeout are distinct outcomes that open
//!   nothing, reach the app as `remote_shell_resolved` and are audited.
//! * AC4 / C17  with no app that can show the sheet, the request fails at once.
//! * AC5        Connect calls the launcher once; success and failure.
//! * AC6        only the verified app can answer (or open): a script, an
//!   impostor claiming to be the app, and TCP are refused and change nothing.
//! * AC7        one request at a time.
//! * AC8 / C18  the user's own `remote_shell_open` goes through the same sheet.
//! * AC9        `remote_shell_targets_request` returns the vocabulary.
//! * AC10       the audit trail holds exactly the documented fields.
//! * FND-1 (T7) every new frame is refused over TCP and no new server frame
//!   reaches a TCP peer.
//!
//! The timeout runs on a paused clock in `remote_shell_request_timeout.rs`.
//! Everything that would "open" a shell opens the fake launcher's `/bin/cat`.
//! The harness is in `remote_shell_support/`.

mod remote_shell_support;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::data::work::picks::PICKS_TAG;
use nostromo::ipc::protocol::{
    ClientMsg, RemoteRequester, ServerMsg, TerminalKind, TerminalStatus, Topic,
};
use nostromo::mcp::server::TOOL_FORBIDDEN_CODE;
use nostromo::terminal::agent_api::AgentRemoteRequest;
use nostromo::terminal::launcher::ConnectFailure;
use nostromo::terminal::remote_request::RemoteResult;
use nostromo::terminal::{TerminalAgentApi, MAX_REFUSALS_PER_WINDOW};
use remote_shell_support::*;
use serde_json::{json, Value};

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("not an array: {v}"))
        .iter()
        .map(|s| {
            s.as_str()
                .unwrap_or_else(|| panic!("not a string: {s}"))
                .to_string()
        })
        .collect()
}

fn names(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| s.to_string()).collect()
}

/// Wait out a short quiet window on the app, then say nothing remote-shell
/// reached it since `from`.
async fn assert_app_not_asked(app: &mut Unix, from: usize, what: &str) {
    app.assert_no_remote_frames(from, what).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// AC1 (criterion 13): the vocabulary
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn canonical_names_and_aliases_all_resolve_to_the_same_canonical_target() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    let variants = [
        ("admin-portal", "production", "scheduler", "shell"),
        ("ap", "prod", "sched", "shell"),
        ("AP", "PROD", "Scheduler", "SHELL"),
        ("portal_dev", "prd", "job", "Shell"),
        ("Admin", "Production", "SCHED", "shell"),
    ];

    for (project, environment, service, shell_type) in variants {
        let a = json!({
            "project": project, "environment": environment,
            "service": service, "shell_type": shell_type,
        });
        let calls_before = s.d.launcher().calls();
        // Five requests from one focus: keep clear of the ceiling of three in ten minutes.
        clock.advance(Duration::from_secs(600));

        let (call, confirm) = s.ask(a).await;

        assert_eq!(
            confirm.target,
            canonical_target(),
            "{project}/{environment}/{service}/{shell_type}: the sheet names canonical words"
        );
        assert_eq!(
            s.d.launcher().calls(),
            calls_before,
            "nothing connects before Connect"
        );
        s.app.answer(&confirm.request_id, "connect").await;
        let res = s.mcp.finish(call).await;
        assert_eq!(res["ok"], true, "{project}/{environment}/{service}: {res}");
        assert_eq!(res["outcome"], "connected");
        assert_eq!(s.d.launcher().calls(), calls_before + 1);
        let (target, tag) = s.d.launcher().last_call().expect("a connect call");
        assert_eq!(
            (
                target.project.as_str(),
                target.environment.as_str(),
                target.service.as_str(),
                target.shell_type.as_str()
            ),
            ("admin-portal", "production", "scheduler", "shell")
        );
        assert_eq!(tag, TAG, "the shell goes in the agent's own focus");
        assert_eq!(target.cluster, "fake-prod-ecs");
        assert_eq!(target.service_name, "production-fake-ap-scheduler");
        assert_eq!(target.container, "main");
        assert_eq!(target.region, "us-east-2");
        assert_eq!(target.shell_command, "/bin/bash");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_outside_the_vocabulary_is_refused_with_the_valid_values_and_no_sheet_appears() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let cases: [(&str, Value, Vec<String>); 4] = [
        (
            "project",
            args_with("project", json!("billing-zzz")),
            names(&[
                "admin-portal",
                "family-portal",
                "payments",
                "referral-monitor",
            ]),
        ),
        (
            "environment",
            args_with("environment", json!("moon-zzz")),
            names(&["canada", "demo", "production", "staging"]),
        ),
        (
            "service",
            args_with("service", json!("queue-pcc-zzz")),
            names(&["api", "portal", "queue", "referral-intake", "scheduler"]),
        ),
        (
            "shell_type",
            args_with("shell_type", json!("bash-zzz")),
            names(&["console", "shell", "tinker"]),
        ),
    ];

    for (field, a, valid) in cases {
        let bad = a[field].as_str().unwrap().to_string();

        let res = s.mcp.call(REQUEST, a).await;

        assert_eq!(res["error"], "invalid_target", "{field}: {res}");
        assert_eq!(res["valid"]["field"], field, "{res}");
        assert_eq!(strings(&res["valid"]["values"]), valid, "{field}: {res}");
        let detail = res["detail"].as_str().expect("a detail");
        assert!(
            detail.contains(&bad),
            "{field}: the detail names the word: {detail}"
        );
        assert!(
            detail.contains(field),
            "{field}: the detail names the field: {detail}"
        );
    }

    assert_app_not_asked(&mut s.app, from, "an invalid target").await;
    s.d.assert_nothing_opened("invalid targets");
    // An invalid target is not an event: it is not audited, and what the agent
    // typed is not in the trail.
    assert!(s.d.remote_audit().is_empty(), "{:?}", s.d.remote_audit());
    assert!(!s.d.audit_text().contains("zzz"), "{}", s.d.audit_text());
}

// ── an injection corpus, as data ─────────────────────────────────────────────

/// ASCII to fullwidth forms (`prod` to `ｐｒｏｄ`).
fn fullwidth(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '!'..='~' => char::from_u32(c as u32 + 0xFEE0).unwrap(),
            c => c,
        })
        .collect()
}

/// Strings that are no word of the vocabulary whichever field they are put in.
fn injection_corpus() -> Vec<(String, String)> {
    let fixed: &[&str] = &[
        "",
        " ",
        ";",
        "&&",
        "||",
        "|",
        "&",
        ">",
        "<",
        "a; rm -rf /",
        "a && id",
        "a | id",
        "$(id)",
        "${IFS}id",
        "$HOME",
        "`id`",
        "'; id; '",
        "\"; id; \"",
        "../",
        "../../etc/passwd",
        "/etc/passwd",
        "..\\..\\windows",
        "--profile x",
        "--profile=x",
        "-p x",
        "--region us-east-1",
        "--region=us-east-1",
        "-- --profile x",
        "a\nb",
        "a\r\nb",
        "a\rb",
        "\n",
        "\r\n",
        "\n; id",
        "a\0b",
        "\0",
        "\t",
        "a\tb",
        "  ",
        "\u{b}",
        "\u{1b}[31m",
        "\u{7f}",
        "\u{85}",
        // Unicode case folding and normalisation.
        "ſ",
        "ſhell",
        "ſcheduler",
        "ſched",
        "\u{212A}",
        "tin\u{212A}er",
        "\u{130}",
        "\u{131}",
        "productıon",
        "prod\u{131}",
        "PRODUCT\u{130}ON",
        "adm\u{131}n-portal",
        "mon\u{130}tor",
        "ǅ",
        "ß",
        "ﬁ",
        "ﬀ",
        // Fullwidth forms.
        "ｐｒｏｄ",
        "ｐｒｏｄｕｃｔｉｏｎ",
        "ａｄｍｉｎ-ｐｏｒｔａｌ",
        "ｓｈｅｌｌ",
        "ｓｃｈｅｄｕｌｅｒ",
        // Zero-width and bidi characters.
        "\u{200b}",
        "\u{200c}",
        "\u{200d}",
        "\u{feff}",
        "\u{2060}",
        "\u{202e}",
        "\u{202d}",
        "\u{2066}",
        "\u{2067}",
        "\u{2069}",
        "\u{200e}",
        "\u{200f}",
        "\u{ad}",
        "\u{a0}",
        "\u{3000}",
        "\u{2028}",
        "\u{2029}",
        // Homoglyphs of words in the vocabulary (Cyrillic and Greek).
        "рrod",
        "prоd",
        "ѕhell",
        "shеll",
        "sсheduler",
        "ａdmin-portal",
        "αdmin-portal",
        "prοd",
        // Things that look like an argument or a path.
        "production/../staging",
        "production%00",
        "production%0a",
        "production#",
        "production?x=1",
        "{{7*7}}",
        "%s%s%s%n",
        "{}",
        "[]",
        "null",
        "true",
        "0",
        "-1",
        "*",
        "?",
        "~",
        "-",
        "--",
        "_",
    ];
    let mut out: Vec<(String, String)> = fixed
        .iter()
        .map(|s| (format!("{s:?}"), s.to_string()))
        .collect();
    out.push(("10 000 'a'".into(), "a".repeat(10_000)));
    out.push(("10 000 ';'".into(), ";".repeat(10_000)));
    out.push(("10 000 NUL".into(), "\0".repeat(10_000)));
    out.push((
        "10 000 chars, a valid word first".into(),
        format!("production{}", "a".repeat(10_000)),
    ));
    out.push(("1 MiB of 'a'".into(), "a".repeat(1 << 20)));
    out.push((
        "1 MiB of '; id '".into(),
        "; id ".repeat((1 << 20) / 5 + 1)[..1 << 20].to_string(),
    ));
    out.push(("1 MiB of U+200B".into(), "\u{200b}".repeat((1 << 20) / 3)));
    out
}

/// Near misses of one valid word: the word with something added or swapped.
fn near_misses_of(word: &str) -> Vec<(String, String)> {
    let first = word.chars().next().unwrap();
    let rest: String = word.chars().skip(1).collect();
    let swapped_case = |from: char, to: &str| word.replace(from, to);
    let homoglyph_first = match first {
        'a' => Some('\u{430}'),
        'p' => Some('\u{440}'),
        's' => Some('\u{455}'),
        'c' => Some('\u{441}'),
        'e' => Some('\u{435}'),
        'o' => Some('\u{43e}'),
        _ => None,
    };
    let mut cases: Vec<(String, String)> = vec![
        ("trailing ';'".into(), format!("{word};")),
        ("trailing '; id'".into(), format!("{word}; id")),
        ("trailing '$(id)'".into(), format!("{word}$(id)")),
        ("trailing backticks".into(), format!("{word}`id`")),
        (
            "trailing ' --profile x'".into(),
            format!("{word} --profile x"),
        ),
        (
            "trailing ' --region us-east-1'".into(),
            format!("{word} --region us-east-1"),
        ),
        ("leading space".into(), format!(" {word}")),
        ("trailing space".into(), format!("{word} ")),
        ("trailing tab".into(), format!("{word}\t")),
        ("leading tab".into(), format!("\t{word}")),
        ("trailing LF".into(), format!("{word}\n")),
        ("trailing CRLF".into(), format!("{word}\r\n")),
        ("embedded LF".into(), format!("{first}\n{rest}")),
        ("trailing NUL".into(), format!("{word}\0")),
        ("embedded NUL".into(), format!("{first}\0{rest}")),
        ("trailing ZWSP".into(), format!("{word}\u{200b}")),
        ("embedded ZWSP".into(), format!("{first}\u{200b}{rest}")),
        ("embedded ZWJ".into(), format!("{first}\u{200d}{rest}")),
        ("leading BOM".into(), format!("\u{feff}{word}")),
        ("leading RLO".into(), format!("\u{202e}{word}")),
        ("trailing RLO".into(), format!("{word}\u{202e}")),
        ("trailing soft hyphen".into(), format!("{word}\u{ad}")),
        ("trailing nbsp".into(), format!("{word}\u{a0}")),
        ("fullwidth".into(), fullwidth(word)),
        ("long s for s".into(), swapped_case('s', "ſ")),
        ("Kelvin sign for k".into(), swapped_case('k', "\u{212A}")),
        (
            "dotted capital I for i".into(),
            swapped_case('i', "\u{130}"),
        ),
        ("dotless i for i".into(), swapped_case('i', "\u{131}")),
        ("path suffix".into(), format!("{word}/../{word}")),
        ("path prefix".into(), format!("../{word}")),
        ("option prefix".into(), format!("--{word}")),
        ("doubled".into(), format!("{word}{word}")),
        ("doubled with a space".into(), format!("{word} {word}")),
        ("a comma list".into(), format!("{word},{word}")),
        ("a glob".into(), format!("{word}*")),
        ("a trailing dot".into(), format!("{word}.")),
        ("a trailing slash".into(), format!("{word}/")),
        (
            "percent-encoded".into(),
            word.replace(first, &format!("%{:02x}", first as u32)),
        ),
    ];
    if let Some(h) = homoglyph_first {
        cases.push(("homoglyph first letter".into(), format!("{h}{rest}")));
    }
    cases.retain(|(_, v)| v != word);
    cases
}

const FIELDS: [&str; 4] = ["project", "environment", "service", "shell_type"];

/// Every corpus string, in every field, with valid words in the others: the
/// invalid_target error naming that field, and nothing else.
#[tokio::test(flavor = "multi_thread")]
async fn no_string_from_the_injection_corpus_is_accepted_in_any_field_of_the_agents_request() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let audit_before = s.d.audit_text();
    let general = injection_corpus();
    let mut tried = 0usize;

    for field in FIELDS {
        let valid_word = args()[field].as_str().unwrap().to_string();
        let mut corpus = general.clone();
        corpus.extend(near_misses_of(&valid_word));
        for (label, value) in corpus {
            let a = args_with(field, json!(value.clone()));

            // A resolver that accepted it would put a sheet up and wait for the
            // user; that must be reported, not waited out.
            let res = match tokio::time::timeout(Duration::from_secs(10), s.mcp.call(REQUEST, a))
                .await
            {
                Ok(res) => res,
                Err(_) => panic!(
                    "{field} = {label}: ACCEPTED by the resolver (no refusal came; the request is waiting for the user)"
                ),
            };

            assert_eq!(
                res["error"],
                "invalid_target",
                "{field} = {label}: expected invalid_target, got {}",
                res.to_string().chars().take(300).collect::<String>()
            );
            assert_eq!(res["valid"]["field"], field, "{field} = {label}");
            assert!(
                res.to_string().len() < 4096,
                "{field} = {label}: the refusal quoted back {} bytes",
                res.to_string().len()
            );
            tried += 1;
        }
        let sheets = s.app.confirms_since(from).len();
        assert_eq!(sheets, 0, "{field}: a sheet reached the app");
    }
    assert!(tried > 4 * 150, "the corpus shrank: {tried} cases");

    assert_app_not_asked(&mut s.app, from, "the injection corpus").await;
    s.d.assert_nothing_opened("the injection corpus");
    // Not an event: not one line was audited, so none carries what was typed.
    assert_eq!(s.d.audit_text(), audit_before, "the audit trail changed");
    assert!(s.d.remote_audit().is_empty(), "{:?}", s.d.remote_audit());
    // Nothing was registered: a valid request now gets its sheet at once.
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(
        s.mcp.finish(call).await["error"],
        "cancelled",
        "not request_pending"
    );
}

/// The same corpus through the user's own `remote_shell_open`: refused to the
/// asker with `invalid_target`, and no sheet.
#[tokio::test(flavor = "multi_thread")]
async fn no_string_from_the_injection_corpus_is_accepted_in_any_field_of_the_users_open() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let from = app.mark();
    let audit_before = d.audit_text();
    let words = ["admin-portal", "production", "scheduler", "shell"];
    let general = injection_corpus();
    let mut tried = 0usize;

    for (i, field) in FIELDS.iter().enumerate() {
        let mut corpus = general.clone();
        corpus.extend(near_misses_of(words[i]));
        for (label, value) in corpus {
            let mut w = words;
            w[i] = &value;
            let before = app.mark();

            app.open_remote(TAG, w).await;
            let (_, refused) = app
                .wait_since(before, &format!("a refusal for {field} = {label}"), |m| {
                    matches!(m, ServerMsg::TerminalRefused { .. })
                        || matches!(m, ServerMsg::RemoteShellConfirmRequest { .. })
                })
                .await;

            assert!(
                matches!(&refused, ServerMsg::TerminalRefused { op, code, .. }
                    if op == "remote_open" && code == "invalid_target"),
                "{field} = {label}: expected terminal_refused invalid_target, got {}",
                msg_type(&refused)
            );
            tried += 1;
        }
    }
    assert!(tried > 4 * 150, "the corpus shrank: {tried} cases");

    app.assert_no_remote_frames(from, "the injection corpus")
        .await;
    d.assert_nothing_opened("the injection corpus");
    assert_eq!(d.audit_text(), audit_before, "the audit trail changed");
}

// ── the confirm sheet shows the agent's name cleaned ─────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_name_on_the_confirm_sheet_is_cleaned_like_the_reason() {
    let long = "a".repeat(300);
    let cases: [(&str, &str, Option<String>); 6] = [
        (
            "a bidi override and a zero-width space are dropped",
            "co\u{202e}dy\u{200b}",
            Some("cody".into()),
        ),
        (
            "control characters become spaces",
            "evil\r\nagent\0x\u{7}",
            Some("evil  agent x".into()),
        ),
        ("it is trimmed", "  padded  ", Some("padded".into())),
        ("it is cut to 200 characters", &long, Some("a".repeat(200))),
        (
            "a name of nothing but invisible characters is no name",
            "\u{202e}\u{200b}\u{feff}",
            None,
        ),
        ("a plain name is untouched", "cody", Some("cody".into())),
    ];

    for (what, name, shown) in cases {
        let mut s = Scene::start().await;
        let mut meta = focus_meta(TAG);
        meta.agent_name = name.to_string();
        s.d.session_mgr
            .lock()
            .unwrap()
            .set_focus_registry(vec![meta]);

        let (call, sheet) = s.ask(args()).await;

        assert_eq!(sheet.requested_by.kind, "focus", "{what}");
        assert_eq!(sheet.requested_by.tag.as_deref(), Some(TAG), "{what}");
        assert_eq!(sheet.requested_by.agent, shown, "{what}");
        s.app.answer(&sheet.request_id, "cancel").await;
        assert_eq!(s.mcp.finish(call).await["error"], "cancelled", "{what}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_environment_without_a_region_and_a_service_the_environment_lacks_are_refused() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    // `qa` is in the project's data but nothing says where it is.
    let res = s
        .mcp
        .call(REQUEST, args_with("environment", json!("qa")))
        .await;
    assert_eq!(res["error"], "invalid_target", "{res}");
    assert_eq!(res["valid"]["field"], "environment");
    assert_eq!(
        strings(&res["valid"]["values"]),
        names(&["canada", "demo", "production", "staging"])
    );

    // An environment the project does not have.
    let a = json!({"project": "payments", "environment": "staging", "service": "api", "shell_type": "shell"});
    let res = s.mcp.call(REQUEST, a).await;
    assert_eq!(res["error"], "invalid_target", "{res}");
    assert_eq!(res["valid"]["field"], "environment");
    assert_eq!(
        strings(&res["valid"]["values"]),
        names(&["demo", "production"])
    );

    // A real service name, not present in that environment.
    let a = json!({"project": "family-portal", "environment": "demo", "service": "scheduler", "shell_type": "shell"});
    let res = s.mcp.call(REQUEST, a).await;
    assert_eq!(res["error"], "invalid_target", "{res}");
    assert_eq!(res["valid"]["field"], "service");
    assert_eq!(strings(&res["valid"]["values"]), names(&["portal"]));

    assert_app_not_asked(&mut s.app, from, "an unavailable environment or service").await;
    s.d.assert_nothing_opened("unavailable targets");
}

#[tokio::test(flavor = "multi_thread")]
async fn any_key_beyond_the_five_is_refused_as_an_unknown_argument_and_nothing_is_asked() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    for key in [
        "command",
        "cmd",
        "script",
        "args",
        "argv",
        "shell",
        "cluster",
        "profile",
        "env",
        "cwd",
        "Command",
        "working_directory",
    ] {
        let a = args_with(key, json!("echo CANARY-1f3a9"));

        let res = s.mcp.call(REQUEST, a).await;

        assert_eq!(res["error"], "unknown_argument", "{key}: {res}");
        assert_eq!(res["detail"], key, "{res}");
    }
    // The extra key is refused whatever else is wrong with the request.
    let a = json!({"project": "nope", "command": "id"});
    let res = s.mcp.call(REQUEST, a).await;
    assert_eq!(res["error"], "unknown_argument", "{res}");

    assert_app_not_asked(&mut s.app, from, "an unknown argument").await;
    s.d.assert_nothing_opened("unknown arguments");
    assert!(s.d.remote_audit().is_empty());
    assert!(!s.d.audit_text().contains("CANARY"), "{}", s.d.audit_text());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reason_of_two_hundred_characters_is_kept_and_two_hundred_and_one_is_refused() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    let res = s
        .mcp
        .call(REQUEST, args_with("reason", json!("x".repeat(201))))
        .await;
    assert_eq!(res["error"], "reason_too_long", "{res}");
    assert_app_not_asked(&mut s.app, from, "a reason one character too long").await;
    s.d.assert_nothing_opened("a long reason");

    // 200 characters, however many bytes they take.
    let reason: String = "é".repeat(200);
    assert!(reason.len() > 200);
    let (call, confirm) = s.ask(args_with("reason", json!(reason.clone()))).await;
    assert_eq!(confirm.reason.as_deref(), Some(reason.as_str()));
    s.app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");

    // The longest reason is audited whole.
    let line =
        s.d.wait_audit("remote_requested", |l| l["event"] == "remote_requested")
            .await;
    assert_eq!(line["reason"], reason.as_str());
}

#[tokio::test(flavor = "multi_thread")]
async fn missing_or_mistyped_arguments_are_invalid_args_and_nothing_is_asked() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    for key in ["project", "environment", "service", "shell_type"] {
        let res = s.mcp.call(REQUEST, args_without(key)).await;
        assert_eq!(res["error"], "invalid_args", "missing {key}: {res}");
        let res = s.mcp.call(REQUEST, args_with(key, json!(5))).await;
        assert_eq!(res["error"], "invalid_args", "{key} not a string: {res}");
        let res = s.mcp.call(REQUEST, args_with(key, Value::Null)).await;
        assert_eq!(res["error"], "invalid_args", "{key} null: {res}");
    }
    let res = s.mcp.call(REQUEST, args_with("reason", json!(["a"]))).await;
    assert_eq!(res["error"], "invalid_args", "reason not a string: {res}");
    for not_an_object in [json!([]), json!("admin-portal"), json!(7)] {
        let res = s.mcp.call(REQUEST, not_an_object.clone()).await;
        assert_eq!(res["error"], "invalid_args", "{not_an_object}: {res}");
    }
    let res = s.mcp.call(REQUEST, json!({})).await;
    assert_eq!(res["error"], "invalid_args", "{res}");

    assert_app_not_asked(&mut s.app, from, "invalid arguments").await;
    s.d.assert_nothing_opened("invalid arguments");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_caller_with_no_focus_or_an_unknown_one_gets_unknown_view_and_nothing_is_asked() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    for (what, tag) in [
        ("no pty_id", None),
        ("an empty pty_id", Some("")),
        ("a pty_id that is no focus", Some("not-a-focus-xyz")),
    ] {
        let mut stranger = s.d.mcp(tag).await;

        let res = stranger.call(REQUEST, args()).await;

        assert_eq!(res["error"], "unknown_view", "{what}: {res}");
    }

    assert_app_not_asked(&mut s.app, from, "a caller with no focus").await;
    s.d.assert_nothing_opened("unknown views");
    assert!(s.d.remote_audit().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// AC2 (criterion 14): who is asked, and what they are told
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_valid_request_sends_exactly_one_confirm_to_the_app_that_can_show_it_and_to_no_one_else()
{
    // Connection order: the app with the sheet, an app without it, three local
    // processes (the last claims to be the app).
    let d = Daemon::start(&[
        Peer::App,
        Peer::App,
        Peer::Script,
        Peer::Script,
        Peer::Script,
    ])
    .await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut old_app = d.app_without_sheet().await;
    let mut script_all = d.script(vec![], &[CONFIRM_CAP]).await;
    let mut script_topics = d
        .script(
            vec![
                Topic::Terminal,
                Topic::Layout,
                Topic::Decision,
                Topic::Focuses,
                Topic::Activity,
            ],
            &[CONFIRM_CAP],
        )
        .await;
    let mut impostor = d.claiming_app().await;
    let mut tcp_all = d.tcp(vec![], true).await;
    let mut tcp_some = d
        .tcp(vec![Topic::Terminal, Topic::Layout, Topic::Decision], true)
        .await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let marks = (
        old_app.mark(),
        script_all.mark(),
        script_topics.mark(),
        impostor.mark(),
        tcp_all.mark(),
        tcp_some.mark(),
    );
    let from = app.mark();

    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;

    // What the sheet is told.
    assert_eq!(confirm.target, canonical_target());
    assert_eq!(confirm.tag.as_deref(), Some(TAG));
    assert_eq!(confirm.requested_by.kind, "focus");
    assert_eq!(confirm.requested_by.tag.as_deref(), Some(TAG));
    assert_eq!(confirm.requested_by.agent.as_deref(), Some(AGENT));
    assert_eq!(
        confirm.reason.as_deref(),
        Some("Check why the nightly job did not run")
    );
    assert!(!confirm.request_id.is_empty());
    // Nothing exists yet: no launch, no terminal, no pane, no connect line.
    d.assert_nothing_opened("while the sheet is up");
    assert!(
        !d.remote_audit_names()
            .iter()
            .any(|n| n == "connect_started"),
        "{:?}",
        d.remote_audit_names()
    );

    // The user says no.
    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(mcp.finish(call).await["error"], "cancelled");
    app.wait_resolved(from, &confirm.request_id).await;
    app.sync().await;
    app.settle(Duration::from_millis(150)).await;

    assert_eq!(
        app.confirms_since(from).len(),
        1,
        "exactly one confirm request"
    );
    assert_eq!(app.resolved_since(from).len(), 1, "exactly one resolution");
    d.assert_nothing_opened("after Cancel");

    // No one else was ever told anything about it.
    old_app
        .assert_no_remote_frames(marks.0, "a verified app without the sheet")
        .await;
    script_all
        .assert_no_remote_frames(marks.1, "a local process on every topic")
        .await;
    script_topics
        .assert_no_remote_frames(marks.2, "a local process on many topics")
        .await;
    impostor
        .assert_no_remote_frames(marks.3, "a process claiming to be the app")
        .await;
    tcp_all
        .assert_no_remote_frames(marks.4, "a TCP peer on every topic")
        .await;
    tcp_some
        .assert_no_remote_frames(marks.5, "a TCP peer on some topics")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_sheet_names_the_command_the_profile_and_the_cluster_that_will_run() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    let sheet = |c: &Confirm| {
        (
            c.shell_command.clone(),
            c.profile.clone(),
            c.cluster.clone(),
        )
    };

    // The usual request: the user's own profile for production wins.
    clock.advance(Duration::from_secs(600));
    let (call, confirm) = s.ask(args()).await;
    assert_eq!(
        sheet(&confirm),
        (
            Some("/bin/bash".into()),
            Some("local-fake-prod-profile".into()),
            Some("fake-prod-ecs".into())
        )
    );
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;

    // Tinker runs its own command.
    clock.advance(Duration::from_secs(600));
    let (call, confirm) = s.ask(args_with("shell_type", json!("tinker"))).await;
    assert_eq!(confirm.shell_command.as_deref(), Some("php artisan tinker"));
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;

    // A project's own override of the shell command.
    clock.advance(Duration::from_secs(600));
    let (call, confirm) = s
        .ask(json!({"project":"referral-monitor","environment":"production","service":"monitor","shell_type":"shell"}))
        .await;
    assert_eq!(confirm.shell_command.as_deref(), Some("/bin/sh"));
    assert_eq!(confirm.cluster.as_deref(), Some("fake-prod-ecs"));
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;

    // Without a personal file the shared profile is shown.
    s.d.remove_ecs("ecs-local.json");
    clock.advance(Duration::from_secs(600));
    let (call, confirm) = s.ask(args()).await;
    assert_eq!(confirm.profile.as_deref(), Some("fake-prod-profile"));
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;

    // An environment with no profile yet: the sheet has none to show.
    clock.advance(Duration::from_secs(600));
    let (call, confirm) = s
        .ask(json!({"project":"ap","environment":"canada","service":"sched","shell_type":"shell"}))
        .await;
    assert_eq!(confirm.profile, None);
    assert_eq!(confirm.cluster.as_deref(), Some("fake-ca-ecs"));
    assert_eq!(confirm.shell_command.as_deref(), Some("/bin/bash"));
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;
}

#[test]
fn the_confirm_frame_leaves_out_what_will_run_when_there_is_nothing_to_say_and_resolved_leaves_out_a_missing_detail(
) {
    let target = canonical_target();
    let requested_by = RemoteRequester {
        kind: "focus".into(),
        tag: Some(TAG.into()),
        agent: None,
    };
    let bare = serde_json::to_value(ServerMsg::RemoteShellConfirmRequest {
        request_id: "r1".into(),
        tag: Some(TAG.into()),
        target: target.clone(),
        requested_by: requested_by.clone(),
        reason: None,
        expires_at: "2026-10-25T12:00:00Z".into(),
        shell_command: None,
        profile: None,
        cluster: None,
    })
    .unwrap();
    let full = serde_json::to_value(ServerMsg::RemoteShellConfirmRequest {
        request_id: "r1".into(),
        tag: Some(TAG.into()),
        target,
        requested_by,
        reason: None,
        expires_at: "2026-10-25T12:00:00Z".into(),
        shell_command: Some("/bin/bash".into()),
        profile: Some("p".into()),
        cluster: Some("c".into()),
    })
    .unwrap();
    let resolved = |detail: Option<&str>| {
        serde_json::to_value(ServerMsg::RemoteShellResolved {
            request_id: "r1".into(),
            outcome: "connect_failed".into(),
            reason: Some("aws_error".into()),
            remedy: None,
            detail: detail.map(String::from),
        })
        .unwrap()
    };

    for key in ["shell_command", "profile", "cluster"] {
        assert!(
            bare.get(key).is_none(),
            "{key} is skipped when None: {bare}"
        );
    }
    assert_eq!(full["shell_command"], "/bin/bash");
    assert_eq!(full["profile"], "p");
    assert_eq!(full["cluster"], "c");
    assert!(resolved(None).get("detail").is_none(), "{}", resolved(None));
    assert_eq!(resolved(Some("line"))["detail"], "line");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_configuration_value_that_is_not_safe_to_run_is_refused_as_not_configured_with_a_fixed_detail_and_nothing_is_asked(
) {
    let mut s = Scene::start().await;
    s.d.edit_ecs("config.json", |c| {
        c.replace(
            "\"shell\": \"/bin/bash\"",
            "\"shell\": \"/bin/bash; touch /tmp/pwned\"",
        )
    });
    let from = s.app.mark();

    let res = s.mcp.call(REQUEST, args()).await;

    assert_eq!(
        res,
        json!({
            "error": "remote_shells_not_configured",
            "detail": "the ECS configuration for this target has an unusable value (unsafe_shell_command)"
        })
    );
    assert_app_not_asked(&mut s.app, from, "an unusable configuration value").await;
    s.d.assert_nothing_opened("an unusable configuration value");
    assert!(
        s.d.remote_audit().is_empty(),
        "{:?}",
        s.d.remote_audit_names()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn two_apps_with_the_sheet_are_both_shown_it_and_the_first_answer_decides() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    d.init_focus(TAG);
    let mut first = d.app().await;
    let mut second = d.app().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let (m1, m2) = (first.mark(), second.mark());

    let call = mcp.start_call(REQUEST, args()).await;
    let c1 = first.wait_confirm(m1).await;
    let c2 = second.wait_confirm(m2).await;
    assert_eq!(c1.request_id, c2.request_id, "the same request on both");

    first.answer(&c1.request_id, "dismiss").await;
    assert_eq!(mcp.finish(call).await["error"], "dismissed");
    // The sheet closes everywhere.
    assert_eq!(
        first.wait_resolved(m1, &c1.request_id).await.outcome,
        "dismissed"
    );
    assert_eq!(
        second.wait_resolved(m2, &c1.request_id).await.outcome,
        "dismissed"
    );

    // The second app's answer comes too late and changes nothing.
    second.answer(&c1.request_id, "connect").await;
    second.sync().await;
    first.sync().await;
    assert_eq!(d.launcher().calls(), 0);
    d.assert_nothing_opened("a late answer from the second app");
    assert_eq!(first.resolved_since(m1).len(), 1);
    assert_eq!(second.resolved_since(m2).len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_confirm_request_says_when_the_daemon_gives_up_waiting() {
    let mut s = Scene::start().await;

    let (call, confirm) = s.ask(args()).await;

    let expires = chrono::DateTime::parse_from_rfc3339(&confirm.expires_at)
        .unwrap_or_else(|e| panic!("expires_at {:?} is not RFC 3339: {e}", confirm.expires_at));
    let left = expires.with_timezone(&chrono::Utc) - chrono::Utc::now();
    assert!(
        left > chrono::Duration::seconds(240) && left <= chrono::Duration::seconds(305),
        "the sheet should last about five minutes, not {left}"
    );
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// AC3 (criterion 16): cancel, dismissal and timeout open nothing
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn cancel_and_dismiss_are_distinct_outcomes_that_open_nothing_and_are_audited() {
    for (decision, error, outcome, audited) in [
        ("cancel", "cancelled", "cancelled", "cancelled"),
        ("dismiss", "dismissed", "dismissed", "dismissed"),
    ] {
        let mut s = Scene::start().await;
        let clock = HandClock::install(&s.d);
        let from = s.app.mark();

        let (call, confirm) = s.ask(args()).await;
        s.app.answer(&confirm.request_id, decision).await;
        let res = s.mcp.finish(call).await;

        assert_eq!(res["error"], error, "{decision}: {res}");
        assert!(res.get("terminal_id").is_none() && res.get("pane_id").is_none());
        let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
        assert_eq!(resolved.outcome, outcome, "{decision}");
        assert_eq!(resolved.reason, None);
        s.d.assert_nothing_opened(decision);
        assert!(
            !s.app.log[from..]
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalState { .. })),
            "{decision}: a terminal was announced"
        );
        s.d.wait_audit("the outcome", |l| l["event"] == "confirm_outcome")
            .await;
        assert_eq!(
            s.d.remote_audit_names(),
            vec![
                "remote_requested".to_string(),
                format!("confirm_outcome:{audited}")
            ],
            "{decision}"
        );
        // Another request can follow once the cooldown a denial starts is over.
        clock.advance(Duration::from_secs(60));
        let (call, confirm) = s.ask(args()).await;
        s.app.answer(&confirm.request_id, "cancel").await;
        assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_requests_wait_is_never_shorter_than_ten_seconds_whatever_the_caller_asks() {
    let s = Scene::start().await;
    let mut app = s.app;
    let api = TerminalAgentApi::new(Arc::clone(&s.d.terminals));
    let from = app.mark();
    let request = |timeout| AgentRemoteRequest {
        tag: TAG.into(),
        agent: Some(AGENT.into()),
        project: "admin-portal".into(),
        environment: "production".into(),
        service: "scheduler".into(),
        shell_type: "shell".into(),
        reason: None,
        timeout,
    };
    let asking = tokio::spawn({
        let api = api.clone();
        async move { api.request_remote(request(Duration::from_millis(50))).await }
    });
    let confirm = app.wait_confirm(from).await;

    // It says ten seconds, not fifty milliseconds ...
    let expires = chrono::DateTime::parse_from_rfc3339(&confirm.expires_at).unwrap();
    let left = expires.with_timezone(&chrono::Utc) - chrono::Utc::now();
    assert!(
        left > chrono::Duration::seconds(5) && left <= chrono::Duration::seconds(11),
        "{left}"
    );
    // ... and the daemon waits that long: well past fifty milliseconds, the
    // request is still open and Connect still works.
    app.settle(Duration::from_millis(1500)).await;
    assert!(app.resolved_since(from).is_empty(), "{}", app.summary());
    assert!(!asking.is_finished());
    app.answer(&confirm.request_id, "connect").await;
    let result = tokio::time::timeout(WAIT, asking)
        .await
        .expect("an answer")
        .expect("no panic");
    assert!(matches!(result, RemoteResult::Connected(_)), "{result:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_requests_wait_is_never_longer_than_ten_minutes_whatever_the_caller_asks() {
    let s = Scene::start().await;
    let mut app = s.app;
    let api = TerminalAgentApi::new(Arc::clone(&s.d.terminals));
    let from = app.mark();
    let asking = tokio::spawn(async move {
        api.request_remote(AgentRemoteRequest {
            tag: TAG.into(),
            agent: None,
            project: "ap".into(),
            environment: "prod".into(),
            service: "sched".into(),
            shell_type: "shell".into(),
            reason: None,
            timeout: Duration::from_secs(100_000),
        })
        .await
    });
    let confirm = app.wait_confirm(from).await;

    let expires = chrono::DateTime::parse_from_rfc3339(&confirm.expires_at).unwrap();
    let left = expires.with_timezone(&chrono::Utc) - chrono::Utc::now();
    assert!(
        left > chrono::Duration::seconds(580) && left <= chrono::Duration::seconds(601),
        "{left}"
    );
    app.answer(&confirm.request_id, "cancel").await;
    let result = tokio::time::timeout(WAIT, asking)
        .await
        .expect("an answer")
        .expect("no panic");
    assert!(matches!(result, RemoteResult::Cancelled), "{result:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// AC4 (criterion 17): no app that can show the sheet
// ═════════════════════════════════════════════════════════════════════════════

/// The request fails at once with `no_operator`, nothing launches, and the
/// refusal is audited (a request and its outcome, with the focus). The caller
/// checks that nothing reached the connections it is watching.
async fn assert_no_operator(d: &Daemon, mcp: &mut Mcp, what: &str) {
    let started = Instant::now();

    let res = mcp.call(REQUEST, args()).await;

    let took = started.elapsed();
    assert_eq!(res["error"], "no_operator", "{what}: {res}");
    assert!(
        took < Duration::from_secs(2),
        "{what}: no_operator must come back at once, not after {took:?}"
    );
    d.assert_nothing_opened(what);
    d.wait_audit(what, |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "no_operator"
    })
    .await;
    assert_eq!(
        d.remote_audit_names(),
        vec![
            "remote_requested".to_string(),
            "confirm_outcome:no_operator".to_string()
        ],
        "{what}"
    );
    let requested = d.remote_audit().remove(0);
    assert_eq!(requested["tag"], TAG, "{requested}");
    assert_eq!(requested["target"]["service"], "scheduler", "{requested}");
}

#[tokio::test(flavor = "multi_thread")]
async fn with_nothing_connected_the_request_fails_at_once_with_no_operator() {
    let d = Daemon::start(&[]).await;
    d.init_focus(TAG);
    let mut mcp = d.mcp(Some(TAG)).await;

    assert_no_operator(&d, &mut mcp, "nothing connected").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_verified_app_that_cannot_show_the_sheet_does_not_count() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut old_app = d.app_without_sheet().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let mark = old_app.mark();

    assert_no_operator(&d, &mut mcp, "an app without the capability").await;

    old_app
        .assert_no_remote_frames(mark, "an app without the capability")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tcp_client_that_renders_decisions_does_not_count() {
    let d = Daemon::start(&[]).await;
    d.init_focus(TAG);
    let mut tcp = d.tcp(vec![Topic::Decision], true).await;
    let mut tcp_all = d.tcp(vec![], true).await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let marks = (tcp.mark(), tcp_all.mark());

    assert_no_operator(&d, &mut mcp, "TCP clients").await;

    tcp.assert_no_remote_frames(marks.0, "a TCP peer on the decision topic")
        .await;
    tcp_all
        .assert_no_remote_frames(marks.1, "a TCP peer on every topic")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_process_does_not_count_even_if_it_claims_to_be_the_app_and_declares_the_capability(
) {
    let d = Daemon::start(&[Peer::Script, Peer::Script]).await;
    d.init_focus(TAG);
    let mut script = d.script(vec![], &[CONFIRM_CAP]).await;
    let mut impostor = d.claiming_app().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let marks = (script.mark(), impostor.mark());

    assert_no_operator(&d, &mut mcp, "local processes").await;

    script
        .assert_no_remote_frames(marks.0, "a local process")
        .await;
    impostor
        .assert_no_remote_frames(marks.1, "a process claiming to be the app")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn once_the_app_with_the_sheet_connects_the_same_request_is_asked() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut mcp = d.mcp(Some(TAG)).await;
    assert_eq!(mcp.call(REQUEST, args()).await["error"], "no_operator");

    let mut app = d.app().await;
    let from = app.mark();
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;

    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_loop_of_requests_that_nobody_can_answer_cannot_flood_the_audit_trail() {
    let d = Daemon::start(&[]).await;
    d.init_focus(TAG);
    let mut mcp = d.mcp(Some(TAG)).await;
    let attempts = MAX_REFUSALS_PER_WINDOW as usize + 40;

    for _ in 0..attempts {
        assert_eq!(mcp.call(REQUEST, args()).await["error"], "no_operator");
    }

    let outcomes = d
        .audit()
        .iter()
        .filter(|l| l["event"] == "confirm_outcome" && l["outcome"] == "no_operator")
        .count();
    assert!(outcomes >= 1, "the first ones are audited");
    assert!(
        outcomes < attempts && outcomes <= MAX_REFUSALS_PER_WINDOW as usize,
        "{outcomes} audit lines for {attempts} attempts"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_request_that_cannot_be_shown_is_refused_before_anything_is_asked_when_remote_shells_are_not_configured(
) {
    let mut s = Scene::start().await;
    s.d.remove_ecs("config.json");
    let from = s.app.mark();

    let res = s.mcp.call(REQUEST, args()).await;

    assert_eq!(res["error"], "remote_shells_not_configured", "{res}");
    assert!(
        !res["detail"].as_str().unwrap_or_default().is_empty(),
        "{res}"
    );
    assert_app_not_asked(&mut s.app, from, "remote shells not configured").await;
    s.d.assert_nothing_opened("not configured");
}

// ═════════════════════════════════════════════════════════════════════════════
// AC5: Connect
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn connect_calls_the_launcher_once_and_the_shell_opens_as_an_ecs_pane_in_the_agents_focus() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    let (call, confirm) = s.ask(args()).await;
    assert_eq!(s.d.launcher().calls(), 0);
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;

    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(res["outcome"], "connected");
    let terminal_id = res["terminal_id"]
        .as_str()
        .expect("terminal_id")
        .to_string();
    let pane_id = res["pane_id"].as_str().expect("pane_id").to_string();
    assert!(
        pane_id.len() == "terminal-".len() + 8
            && pane_id.starts_with("terminal-")
            && pane_id["terminal-".len()..]
                .chars()
                .all(|c| matches!(c, '0'..='9' | 'a'..='f')),
        "{pane_id}"
    );
    assert_eq!(s.d.launcher().calls(), 1, "Connect launches once");

    // The daemon holds an ecs terminal for the target, in the agent's focus.
    let info = s.d.info(&terminal_id).expect("the terminal is registered");
    assert_eq!(info.kind, TerminalKind::Ecs);
    assert_eq!(info.tag, TAG);
    assert_eq!(info.pane_id, pane_id);
    assert_eq!(info.status, TerminalStatus::Running);
    assert_eq!(info.target, Some(canonical_target()));
    assert_eq!(info.requested_by.kind, "focus");
    assert_eq!(info.requested_by.tag.as_deref(), Some(TAG));
    // Its pane is a terminal leaf of the focus's tree.
    assert_eq!(s.d.leaves(TAG), vec![pane_id.clone()]);
    assert!(s.d.pane_ids(TAG).contains(&pane_id));
    assert!(
        s.d.pane_ids(TAG).iter().any(|p| p == "repl"),
        "the rest of the tree stays"
    );
    // The app is told: a terminal_state for it (kind ecs), then the sheet's end.
    let (_, state) = s
        .app
        .wait_since(from, "an ecs terminal_state", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == terminal_id && terminal.kind == TerminalKind::Ecs)
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert_eq!(terminal.target, Some(canonical_target()));
    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "connected");
    assert_eq!(resolved.reason, None);
    assert_eq!(s.app.resolved_since(from).len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connect_is_audited_as_requested_then_connect_then_started_then_connected_in_that_order()
{
    let mut s = Scene::start().await;

    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;

    assert_eq!(res["ok"], true, "{res}");
    s.d.wait_audit("connected", |l| l["event"] == "connected")
        .await;
    assert_eq!(
        s.d.remote_audit_names(),
        [
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connected"
        ]
    );
    let lines = s.d.remote_audit();
    let connected = &lines[3];
    assert_eq!(connected["terminal_id"], res["terminal_id"]);
    assert_eq!(connected["pane_id"], res["pane_id"]);
    assert_eq!(connected["tag"], TAG);
    assert_eq!(connected["kind"], "ecs");
    assert_eq!(
        connected["target"],
        json!({"project":"admin-portal","environment":"production","service":"scheduler","shell_type":"shell"})
    );
    assert!(lines[1].get("invite_follow").is_none(), "{}", lines[1]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connect_that_fails_reports_why_opens_no_pane_and_is_audited() {
    let mut s = Scene::start().await;
    s.d.launcher().set_failure(Some(ConnectFailure {
        reason_code: "sso_expired".into(),
        message: "Your AWS session has expired.".into(),
        remedy: Some("Run `aws sso login --profile fake-prod-profile` and try again.".into()),
        detail: None,
    }));
    let from = s.app.mark();

    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;

    assert_eq!(res["error"], "connect_failed", "{res}");
    assert_eq!(res["reason"], "sso_expired");
    assert_eq!(
        res["remedy"],
        "Run `aws sso login --profile fake-prod-profile` and try again."
    );
    // The agent gets the code and the remedy, not the failure's own sentence.
    assert!(res.get("detail").is_none(), "{res}");
    assert!(res.get("message").is_none(), "{res}");
    assert!(
        !res.to_string().contains("Your AWS session has expired."),
        "{res}"
    );
    assert_eq!(s.d.launcher().calls(), 1);
    assert!(s.d.list().is_empty(), "no terminal exists");
    assert!(s.d.leaves(TAG).is_empty(), "no pane exists");
    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "connect_failed");
    assert_eq!(resolved.reason.as_deref(), Some("sso_expired"));
    assert_eq!(
        resolved.remedy.as_deref(),
        Some("Run `aws sso login --profile fake-prod-profile` and try again.")
    );
    let failed =
        s.d.wait_audit("connect_failed", |l| l["event"] == "connect_failed")
            .await;
    assert_eq!(failed["reason_code"], "sso_expired", "{failed}");
    assert_eq!(failed["tag"], TAG);
    assert_eq!(
        s.d.remote_audit_names(),
        [
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connect_failed"
        ]
    );
    // And the next request is not held up by it.
    s.d.launcher().set_failure(None);
    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    assert_eq!(s.mcp.finish(call).await["ok"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn what_the_cli_printed_goes_to_the_operators_sheet_alone_not_the_agent_and_not_the_audit_trail(
) {
    let mut s = Scene::start().await;
    s.d.launcher().set_failure(Some(ConnectFailure {
        reason_code: "aws_error".into(),
        message: "The AWS CLI reported an error.".into(),
        remedy: None,
        detail: Some("OPERATOR-ONLY-LINE (account 123456789012)".into()),
    }));
    let from = s.app.mark();

    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;

    assert_eq!(
        res,
        json!({"error": "connect_failed", "reason": "aws_error", "remedy": null}),
        "the agent is told the code and the fixed remedy and nothing else"
    );
    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(
        resolved.detail.as_deref(),
        Some("OPERATOR-ONLY-LINE (account 123456789012)")
    );
    s.d.wait_audit("connect_failed", |l| l["event"] == "connect_failed")
        .await;
    assert!(
        !s.d.audit_text().contains("OPERATOR-ONLY-LINE"),
        "{}",
        s.d.audit_text()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn until_a_real_launcher_exists_connect_fails_as_not_available_and_opens_nothing() {
    let mut opts = Options::new(&[Peer::App]);
    opts.fake_launcher = false;
    let mut s = Scene::start_with(opts).await;
    let from = s.app.mark();

    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;

    assert_eq!(res["error"], "connect_failed", "{res}");
    assert_eq!(res["reason"], "not_available");
    assert!(
        res["remedy"].as_str().is_some_and(|r| !r.is_empty()),
        "{res}"
    );
    assert!(s.d.list().is_empty());
    assert!(s.d.leaves(TAG).is_empty());
    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(
        (resolved.outcome.as_str(), resolved.reason.as_deref()),
        ("connect_failed", Some("not_available"))
    );
    let failed =
        s.d.wait_audit("connect_failed", |l| l["event"] == "connect_failed")
            .await;
    assert_eq!(failed["reason_code"], "not_available");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_connect_answer_to_the_same_request_does_not_launch_again() {
    let mut s = Scene::start().await;
    let (call, confirm) = s.ask(args()).await;

    s.app.answer(&confirm.request_id, "connect").await;
    s.app.answer(&confirm.request_id, "connect").await;
    s.app.answer(&confirm.request_id, "cancel").await;
    let res = s.mcp.finish(call).await;
    s.app.sync().await;
    s.app.settle(Duration::from_millis(150)).await;

    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(s.d.launcher().calls(), 1);
    assert_eq!(s.d.list().len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_answer_for_a_request_that_is_not_pending_is_ignored() {
    let mut s = Scene::start().await;
    let from = s.app.mark();

    // Before any request exists.
    s.app.answer("no-such-request", "connect").await;
    s.app.sync().await;

    // A made-up id while a real request waits.
    let (call, confirm) = s.ask(args()).await;
    s.app.answer("no-such-request", "connect").await;
    s.app
        .answer(&format!("{}x", confirm.request_id), "connect")
        .await;
    s.app.sync().await;
    s.app.settle(Duration::from_millis(150)).await;
    assert_eq!(s.d.launcher().calls(), 0);
    assert!(s.app.resolved_since(from).is_empty(), "{}", s.app.summary());
    assert!(
        s.app.refusals_since(from).is_empty(),
        "{:?}",
        s.app.refusals_since(from)
    );

    // The real request is still open.
    s.app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");

    // And once it has ended, its id is dead.
    s.app.answer(&confirm.request_id, "connect").await;
    s.app.sync().await;
    assert_eq!(s.d.launcher().calls(), 0);
    s.d.assert_nothing_opened("a late answer");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unknown_decision_is_refused_and_leaves_the_request_waiting() {
    let mut s = Scene::start().await;
    let (call, confirm) = s.ask(args()).await;

    for decision in ["approve", "Connect", "", "connect ", "yes"] {
        let from = s.app.mark();
        s.app.answer(&confirm.request_id, decision).await;
        s.app.sync().await;
        let refusals = s.app.refusals_since(from);
        assert_eq!(refusals.len(), 1, "{decision:?}: {refusals:?}");
        assert_eq!(refusals[0].2, "invalid_decision", "{decision:?}");
    }
    assert_eq!(s.d.launcher().calls(), 0);

    s.app.answer(&confirm.request_id, "connect").await;
    assert_eq!(s.mcp.finish(call).await["ok"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn invite_follow_is_audited_only_when_the_user_ticked_it() {
    let mut s = Scene::start().await;

    let (call, confirm) = s.ask(args()).await;
    s.app.answer_following(&confirm.request_id, "connect").await;
    assert_eq!(s.mcp.finish(call).await["ok"], true);
    let line =
        s.d.wait_audit("the outcome", |l| l["event"] == "confirm_outcome")
            .await;
    assert_eq!(line["outcome"], "connect");
    assert_eq!(line["invite_follow"], true, "{line}");

    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;
    let outcomes: Vec<Value> =
        s.d.audit()
            .into_iter()
            .filter(|l| l["event"] == "confirm_outcome")
            .collect();
    assert_eq!(outcomes.len(), 2);
    assert!(
        outcomes[1].get("invite_follow").is_none(),
        "{}",
        outcomes[1]
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// AC6: only the verified app answers
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn an_answer_from_a_local_process_is_refused_audited_and_changes_nothing() {
    for (who, claim) in [
        ("an ordinary process", false),
        ("a process claiming to be the app", true),
    ] {
        let d = Daemon::start(&[Peer::App, Peer::Script]).await;
        d.init_focus(TAG);
        let mut app = d.app().await;
        let mut intruder = if claim {
            d.claiming_app().await
        } else {
            d.script(vec![], &[CONFIRM_CAP]).await
        };
        let mut mcp = d.mcp(Some(TAG)).await;
        let from = app.mark();
        let call = mcp.start_call(REQUEST, args()).await;
        let confirm = app.wait_confirm(from).await;
        let (app_mark, intruder_mark) = (app.mark(), intruder.mark());

        for decision in ["connect", "cancel", "dismiss"] {
            let before = intruder.mark();
            intruder.answer(&confirm.request_id, decision).await;
            intruder.sync().await;
            let refusals = intruder.refusals_since(before);
            assert_eq!(
                refusals,
                vec![(
                    "control".to_string(),
                    None,
                    "terminal_control_forbidden".to_string()
                )],
                "{who}: {decision}"
            );
        }

        // Audited as refused on the IPC channel, each time.
        let lines = d.refused_lines("ipc");
        assert_eq!(lines.len(), 3, "{who}: {lines:?}");
        for line in &lines {
            assert_eq!(line["op"], "control", "{who}: {line}");
            assert_eq!(line["code"], "terminal_control_forbidden", "{who}: {line}");
        }
        // The request is untouched: nothing resolved, nothing launched ...
        app.sync().await;
        assert!(
            app.resolved_since(app_mark).is_empty(),
            "{who}: {}",
            app.summary()
        );
        assert!(intruder.resolved_since(intruder_mark).is_empty(), "{who}");
        assert_eq!(d.launcher().calls(), 0, "{who}");
        d.assert_nothing_opened(who);
        // ... and the real app can still answer it.
        app.answer(&confirm.request_id, "connect").await;
        let res = mcp.finish(call).await;
        assert_eq!(res["ok"], true, "{who}: {res}");
        assert_eq!(d.launcher().calls(), 1);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_answer_over_tcp_is_refused_with_requires_secure_connection_and_changes_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut tcp = d.tcp(vec![], true).await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let from = app.mark();
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    let tcp_mark = tcp.mark();

    for decision in ["connect", "cancel", "dismiss"] {
        let before = tcp.mark();
        tcp.answer(&confirm.request_id, decision).await;
        tcp.sync().await;
        let errors = tcp.errors_since(before);
        assert!(
            errors
                .iter()
                .any(|m| m.starts_with("requires_secure_connection")),
            "{decision}: {errors:?}"
        );
    }

    // Audited as a refusal over tcp.
    d.wait_audit("a tcp refusal", |l| {
        l["event"] == "refused" && l["channel"] == "tcp"
    })
    .await;
    let lines = d.refused_lines("tcp");
    assert!(
        !lines.is_empty() && lines.iter().all(|l| l["op"] == "control"),
        "{lines:?}"
    );
    // A TCP peer is told nothing else about terminals or remote shells.
    assert!(
        tcp.refusals_since(tcp_mark).is_empty(),
        "no terminal_refused over tcp"
    );
    assert!(tcp.remote_frames_since(tcp_mark).is_empty());
    // The request is untouched, and the app can still answer it.
    app.sync().await;
    assert_eq!(d.launcher().calls(), 0);
    assert!(app.resolved_since(from).is_empty());
    app.answer(&confirm.request_id, "dismiss").await;
    assert_eq!(mcp.finish(call).await["error"], "dismissed");
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_a_remote_shell_is_refused_to_anyone_but_the_app_and_starts_no_flow() {
    let d = Daemon::start(&[Peer::App, Peer::Script, Peer::Script]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut script = d.script(vec![], &[CONFIRM_CAP]).await;
    let mut impostor = d.claiming_app().await;
    let mut tcp = d.tcp(vec![], true).await;
    let from = app.mark();

    for (who, intruder) in [("a process", &mut script), ("an impostor", &mut impostor)] {
        let before = intruder.mark();
        intruder
            .open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
            .await;
        intruder.sync().await;
        assert_eq!(
            intruder.refusals_since(before),
            vec![(
                "control".to_string(),
                None,
                "terminal_control_forbidden".to_string()
            )],
            "{who}"
        );
    }
    let before = tcp.mark();
    tcp.open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
        .await;
    tcp.sync().await;
    assert!(
        tcp.errors_since(before)
            .iter()
            .any(|m| m.starts_with("requires_secure_connection")),
        "{}",
        tcp.summary()
    );

    // No sheet was shown, nothing launched, and nothing is left pending.
    assert_app_not_asked(&mut app, from, "a refused remote_shell_open").await;
    assert!(
        !d.audit().iter().any(|l| l["event"] == "remote_requested"),
        "a refused open must not start a request"
    );
    d.assert_nothing_opened("a refused open");
    let mut mcp = d.mcp(Some(TAG)).await;
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(
        mcp.finish(call).await["error"],
        "cancelled",
        "not request_pending"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// AC7: one at a time
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_second_request_while_one_waits_is_refused_at_once_and_the_first_is_untouched() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    d.init_focus(TAG2);
    let mut app = d.app().await;
    let mut first = d.mcp(Some(TAG)).await;
    let mut second = d.mcp(Some(TAG2)).await;
    let from = app.mark();
    let first_call = first.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;

    let started = Instant::now();
    let res = second
        .call(
            REQUEST,
            json!({"project":"family-portal","environment":"demo","service":"portal","shell_type":"console"}),
        )
        .await;

    assert_eq!(res["error"], "request_pending", "{res}");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "at once, not after {:?}",
        started.elapsed()
    );
    // The user is not asked a second time, and nothing launched.
    app.sync().await;
    app.settle(Duration::from_millis(100)).await;
    assert_eq!(app.confirms_since(from).len(), 1);
    assert_eq!(d.launcher().calls(), 0);
    // It is audited as refused, for the second focus, and not as the first's.
    let outcome = d
        .wait_audit("request_pending", |l| {
            l["event"] == "confirm_outcome" && l["outcome"] == "request_pending"
        })
        .await;
    assert_eq!(outcome["tag"], TAG2, "{outcome}");
    assert_eq!(outcome["target"]["project"], "family-portal", "{outcome}");

    // The first request is still the one the user is deciding.
    app.answer(&confirm.request_id, "connect").await;
    let res = first.finish(first_call).await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(d.launcher().calls(), 1);
    assert_eq!(
        d.launcher().last_call().unwrap().1,
        TAG,
        "the first request's focus"
    );

    // Once it has ended a new request is accepted.
    let from = app.mark();
    let call = second.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    assert_eq!(confirm.tag.as_deref(), Some(TAG2));
    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(second.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_own_open_while_an_agents_request_waits_takes_the_slot_and_the_agent_is_told_superseded(
) {
    let mut s = Scene::start().await;
    let (call, agent_sheet) = s.ask(args()).await;
    let from = s.app.mark();

    s.app
        .open_remote(TAG, ["family-portal", "demo", "portal", "console"])
        .await;

    // The agent's call ends at once, as superseded, and opened nothing.
    let started = Instant::now();
    let res = s.mcp.finish(call).await;
    assert_eq!(res, json!({"error": "superseded"}), "{res}");
    assert!(started.elapsed() < Duration::from_secs(5));
    s.d.assert_nothing_opened("an agent's request that was superseded");
    // Its sheet is closed, with its own outcome.
    let closed = s.app.wait_resolved(from, &agent_sheet.request_id).await;
    assert_eq!(closed.outcome, "superseded", "{closed:?}");
    assert_eq!(closed.reason, None);
    // The user's own sheet is up, marked as the user's, for what the user asked.
    let user_sheet = s.app.wait_confirm(from).await;
    assert_ne!(user_sheet.request_id, agent_sheet.request_id);
    assert_eq!(user_sheet.requested_by.kind, "user");
    assert_eq!(user_sheet.requested_by.agent, None);
    assert_eq!(user_sheet.tag.as_deref(), Some(TAG));
    assert_eq!(
        (
            user_sheet.target.project.as_str(),
            user_sheet.target.environment.as_str(),
            user_sheet.target.service.as_str(),
            user_sheet.target.shell_type.as_str()
        ),
        ("family-portal", "demo", "portal", "console")
    );
    s.app.sync().await;
    assert!(
        s.app.refusals_since(from).is_empty(),
        "the user is not refused: {:?}",
        s.app.refusals_since(from)
    );
    assert_eq!(
        s.app.confirms_since(from).len(),
        1,
        "one new sheet, the user's"
    );

    // A late Connect for the superseded request changes nothing.
    s.app.answer(&agent_sheet.request_id, "connect").await;
    s.app.sync().await;
    s.app.settle(Duration::from_millis(100)).await;
    assert_eq!(
        s.d.launcher().calls(),
        0,
        "a superseded request cannot connect"
    );

    // The user's own request still connects, as the user's.
    s.app.answer(&user_sheet.request_id, "connect").await;
    assert_eq!(
        s.app
            .wait_resolved(from, &user_sheet.request_id)
            .await
            .outcome,
        "connected"
    );
    assert_eq!(s.d.launcher().calls(), 1);
    let (target, tag) = s.d.launcher().last_call().expect("a connect call");
    assert_eq!(target.project, "family-portal");
    assert_eq!(tag, TAG);

    // Audited: both requests, how each ended, and only the user's connected.
    s.d.wait_audit("connected", |l| l["event"] == "connected")
        .await;
    let mut names = s.d.remote_audit_names();
    names.sort();
    assert_eq!(
        names,
        [
            "confirm_outcome:connect",
            "confirm_outcome:superseded",
            "connect_started",
            "connected",
            "remote_requested",
            "remote_requested",
        ]
    );
    let superseded =
        s.d.remote_audit()
            .into_iter()
            .find(|l| l["outcome"] == "superseded")
            .expect("a superseded confirm_outcome");
    assert_eq!(superseded["event"], "confirm_outcome");
    assert_eq!(superseded["tag"], TAG, "{superseded}");
    assert_eq!(
        superseded["target"]["project"], "admin-portal",
        "{superseded}"
    );

    // Being superseded is not a denial: the agent may ask again at once.
    let (call, again) = s.ask(args()).await;
    s.app.answer(&again.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_request_while_the_users_waits_is_refused_pending_and_the_users_sheet_stays() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    s.app
        .open_remote(TAG, ["family-portal", "demo", "portal", "console"])
        .await;
    let user_sheet = s.app.wait_confirm(from).await;
    let after_sheet = s.app.mark();

    let res = s.mcp.call(REQUEST, args()).await;

    assert_eq!(res, json!({"error": "request_pending"}), "{res}");
    assert_app_not_asked(
        &mut s.app,
        after_sheet,
        "an agent against the user's request",
    )
    .await;
    assert!(
        s.app.resolved_since(from).is_empty(),
        "the user's sheet stays up"
    );
    s.app.answer(&user_sheet.request_id, "cancel").await;
    assert_eq!(
        s.app
            .wait_resolved(from, &user_sheet.request_id)
            .await
            .outcome,
        "cancelled"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_user_open_while_the_users_first_waits_is_refused_request_pending() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    s.app
        .open_remote(TAG, ["family-portal", "demo", "portal", "console"])
        .await;
    let first = s.app.wait_confirm(from).await;
    let after_sheet = s.app.mark();

    s.app
        .open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
        .await;
    s.app
        .wait_since(after_sheet, "request_pending", |m| {
            matches!(m, ServerMsg::TerminalRefused { op, code, .. } if op == "remote_open" && code == "request_pending")
        })
        .await;

    assert_eq!(
        s.app.confirms_since(after_sheet).len(),
        0,
        "no second sheet"
    );
    assert!(s.app.resolved_since(after_sheet).is_empty());
    s.app.answer(&first.request_id, "cancel").await;
    s.app.wait_resolved(from, &first.request_id).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// The cooldown after a denial, and the ceiling (follow-ups to slice 2a)
// ═════════════════════════════════════════════════════════════════════════════

/// The daemon's remote-request clock, moved by hand. The wait for the user
/// still runs on real time; only the cooldown and the ceiling read this.
struct HandClock(Arc<Mutex<Duration>>);

impl HandClock {
    fn install(d: &Daemon) -> HandClock {
        let base = Instant::now();
        let offset = Arc::new(Mutex::new(Duration::ZERO));
        let reader = Arc::clone(&offset);
        d.terminals
            .lock()
            .unwrap()
            .set_remote_clock(Arc::new(move || base + *reader.lock().unwrap()));
        HandClock(offset)
    }

    fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }
}

/// The agent asks, the sheet shows, the user cancels; the sheet has closed.
async fn agent_asks_and_the_user_cancels(s: &mut Scene) {
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
    s.app.wait_resolved(0, &sheet.request_id).await;
}

/// The agent asks and is refused with exactly `{"error": code}`: no sheet.
async fn assert_agent_refused(s: &mut Scene, code: &str, what: &str) {
    let from = s.app.mark();
    let res = s.mcp.call(REQUEST, args()).await;
    assert_eq!(res, json!({"error": code}), "{what}");
    assert_app_not_asked(&mut s.app, from, what).await;
}

const SECOND: Duration = Duration::from_secs(1);

#[tokio::test(flavor = "multi_thread")]
async fn after_the_user_cancels_the_agent_is_refused_request_cooldown_with_no_sheet_until_the_minute_is_up(
) {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    agent_asks_and_the_user_cancels(&mut s).await;

    for _ in 0..3 {
        assert_agent_refused(&mut s, "request_cooldown", "right after the Cancel").await;
    }
    clock.advance(Duration::from_secs(59));
    assert_agent_refused(
        &mut s,
        "request_cooldown",
        "a second before the minute is up",
    )
    .await;
    assert_eq!(s.d.launcher().calls(), 0);
    // Each refusal is audited as a refused request, with nothing else.
    let mut expected = vec!["remote_requested", "confirm_outcome:cancelled"];
    for _ in 0..4 {
        expected.extend(["remote_requested", "confirm_outcome:request_cooldown"]);
    }
    assert_eq!(s.d.remote_audit_names(), expected);
    let refusal = s.d.remote_audit().pop().unwrap();
    assert_eq!(refusal["outcome"], "request_cooldown");
    assert_eq!(refusal["tag"], TAG);

    // The minute is up: the agent is asked about again, and is refused again
    // for twice as long after a second Cancel.
    clock.advance(SECOND);
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(119));
    assert_agent_refused(
        &mut s,
        "request_cooldown",
        "the second denial costs two minutes",
    )
    .await;
    clock.advance(SECOND);
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_dismiss_starts_the_cooldown_too_and_another_focus_is_not_held_by_it() {
    let mut s = Scene::start().await;
    let _clock = HandClock::install(&s.d);
    s.d.init_focus(TAG2);
    let mut other = s.d.mcp(Some(TAG2)).await;
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "dismiss").await;
    assert_eq!(s.mcp.finish(call).await["error"], "dismissed");
    s.app.wait_resolved(0, &sheet.request_id).await;

    assert_agent_refused(&mut s, "request_cooldown", "after a Dismiss").await;

    let from = s.app.mark();
    let call = other.start_call(REQUEST, args()).await;
    let sheet = s.app.wait_confirm(from).await;
    assert_eq!(
        sheet.tag.as_deref(),
        Some(TAG2),
        "the other focus is asked about"
    );
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(other.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connect_clears_the_cooldown_streak() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(60));
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "connect").await;
    assert_eq!(s.mcp.finish(call).await["ok"], true);
    s.app.wait_resolved(0, &sheet.request_id).await;
    // Out of the request window, so only the streak is in play.
    clock.advance(Duration::from_secs(600));

    // No cooldown after a Connect: the agent can ask at once ...
    agent_asks_and_the_user_cancels(&mut s).await;
    // ... and the denial after it costs a minute, not two.
    clock.advance(Duration::from_secs(59));
    assert_agent_refused(&mut s, "request_cooldown", "a second early").await;
    clock.advance(SECOND);
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fourth_request_in_ten_minutes_is_refused_request_limit_until_the_first_ages_out() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    // Three requests, each cancelled and each asked after its cooldown:
    // at 0 s, 60 s and 180 s.
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(60));
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(120));
    agent_asks_and_the_user_cancels(&mut s).await;

    // At 420 s the third denial's 240 s are over, but the ceiling is not.
    clock.advance(Duration::from_secs(240));
    assert_agent_refused(&mut s, "request_limit", "a fourth request in the window").await;
    assert_eq!(s.d.launcher().calls(), 0);
    let last = s.d.remote_audit().pop().unwrap();
    assert_eq!(last["event"], "confirm_outcome");
    assert_eq!(last["outcome"], "request_limit", "{last}");
    assert_eq!(last["tag"], TAG);
    // At 599 s the first request is still inside the window.
    clock.advance(Duration::from_secs(179));
    assert_agent_refused(&mut s, "request_limit", "a second before it ages out").await;

    // At 600 s it has aged out.
    clock.advance(SECOND);
    let (call, sheet) = s.ask(args()).await;
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_ceiling_is_per_focus() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    s.d.init_focus(TAG2);
    let mut other = s.d.mcp(Some(TAG2)).await;
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(60));
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(120));
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(240));
    assert_agent_refused(&mut s, "request_limit", "the first focus is at its ceiling").await;

    let from = s.app.mark();
    let call = other.start_call(REQUEST, args()).await;
    let sheet = s.app.wait_confirm(from).await;
    assert_eq!(sheet.tag.as_deref(), Some(TAG2));
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(other.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_user_can_open_a_shell_during_the_agents_cooldown_and_at_its_ceiling_and_their_no_costs_the_agent_nothing(
) {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    agent_asks_and_the_user_cancels(&mut s).await;
    assert_agent_refused(&mut s, "request_cooldown", "the agent is cooling").await;

    // In the cooldown, the user's own request gets its sheet, and the user may say no.
    let from = s.app.mark();
    s.app
        .open_remote(TAG, ["family-portal", "demo", "portal", "console"])
        .await;
    let sheet = s.app.wait_confirm(from).await;
    assert_eq!(sheet.requested_by.kind, "user");
    assert!(s.app.refusals_since(from).is_empty());
    s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(
        s.app.wait_resolved(from, &sheet.request_id).await.outcome,
        "cancelled"
    );
    // That no did not lengthen the agent's wait: a minute after its own denial it may ask.
    assert_agent_refused(&mut s, "request_cooldown", "still cooling").await;
    clock.advance(Duration::from_secs(60));
    agent_asks_and_the_user_cancels(&mut s).await;

    // At the ceiling (two more asks at 60 s and 180 s make three) the user is still served.
    clock.advance(Duration::from_secs(120));
    agent_asks_and_the_user_cancels(&mut s).await;
    clock.advance(Duration::from_secs(240));
    assert_agent_refused(&mut s, "request_limit", "the agent is at its ceiling").await;
    let from = s.app.mark();
    s.app
        .open_remote(TAG, ["family-portal", "demo", "portal", "console"])
        .await;
    let sheet = s.app.wait_confirm(from).await;
    assert_eq!(sheet.requested_by.kind, "user");
    s.app.answer(&sheet.request_id, "cancel").await;
    s.app.wait_resolved(from, &sheet.request_id).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// AC8 (criterion 18): the user's own request
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn the_users_own_open_goes_through_the_same_sheet_marked_as_the_user_and_connects() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let from = app.mark();

    app.open_remote(TAG, ["ap", "prod", "sched", "shell"]).await;
    let confirm = app.wait_confirm(from).await;

    assert_eq!(confirm.target, canonical_target());
    assert_eq!(confirm.tag.as_deref(), Some(TAG));
    assert_eq!(confirm.requested_by.kind, "user");
    assert_eq!(confirm.requested_by.tag, None);
    assert_eq!(confirm.requested_by.agent, None);
    assert_eq!(confirm.reason, None);
    assert_eq!(
        d.launcher().calls(),
        0,
        "the user's request is also a request"
    );
    d.assert_nothing_opened("while the sheet is up");

    app.answer(&confirm.request_id, "connect").await;
    let (_, state) = app
        .wait_since(from, "the new terminal", |m| {
            matches!(m, ServerMsg::TerminalState { terminal } if terminal.kind == TerminalKind::Ecs)
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert_eq!(terminal.requested_by.kind, "user");
    assert_eq!(terminal.requested_by.tag, None);
    assert_eq!(terminal.tag, TAG);
    assert_eq!(terminal.target, Some(canonical_target()));
    assert_eq!(
        app.wait_resolved(from, &confirm.request_id).await.outcome,
        "connected"
    );
    assert_eq!(d.launcher().calls(), 1);
    assert_eq!(d.leaves(TAG), vec![terminal.pane_id.clone()]);

    // Audited as the user's request (no focus tag in `requested_by`).
    d.wait_audit("connected", |l| l["event"] == "connected")
        .await;
    let requested = d.remote_audit().remove(0);
    assert_eq!(requested["event"], "remote_requested");
    assert_eq!(
        requested["requested_by"],
        json!({"kind": "user"}),
        "{requested}"
    );
    assert_eq!(requested["tag"], TAG);
    assert!(requested.get("reason").is_none(), "{requested}");
    assert_eq!(
        d.remote_audit_names(),
        [
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connected"
        ]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_own_cancel_opens_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let from = app.mark();

    app.open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
        .await;
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "cancel").await;

    assert_eq!(
        app.wait_resolved(from, &confirm.request_id).await.outcome,
        "cancelled"
    );
    d.assert_nothing_opened("the user cancelled");
    d.wait_audit("cancelled", |l| l["event"] == "confirm_outcome")
        .await;
    assert_eq!(
        d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:cancelled"]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_open_that_cannot_proceed_is_refused_to_the_asker_with_a_code_and_no_sheet() {
    // An out-of-vocabulary word.
    {
        let d = Daemon::start(&[Peer::App]).await;
        d.init_focus(TAG);
        let mut app = d.app().await;
        let from = app.mark();
        app.open_remote(TAG, ["billing-zzz", "production", "scheduler", "shell"])
            .await;
        app.wait_since(from, "invalid_target", |m| {
            matches!(m, ServerMsg::TerminalRefused { op, code, .. } if op == "remote_open" && code == "invalid_target")
        })
        .await;
        app.assert_no_remote_frames(from, "an invalid target").await;
        d.assert_nothing_opened("an invalid target");
        assert!(!d.audit_text().contains("zzz"));
    }
    // No vocabulary at all.
    {
        let d = Daemon::start(&[Peer::App]).await;
        d.init_focus(TAG);
        d.remove_ecs("config.json");
        let mut app = d.app().await;
        let from = app.mark();
        app.open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
            .await;
        app.wait_since(from, "remote_shells_not_configured", |m| {
            matches!(m, ServerMsg::TerminalRefused { op, code, .. } if op == "remote_open" && code == "remote_shells_not_configured")
        })
        .await;
        d.assert_nothing_opened("not configured");
    }
    // No app that can show the sheet (the verified app of an older build).
    {
        let d = Daemon::start(&[Peer::App]).await;
        d.init_focus(TAG);
        let mut old_app = d.app_without_sheet().await;
        let from = old_app.mark();
        old_app
            .open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
            .await;
        old_app
            .wait_since(from, "no_operator", |m| {
                matches!(m, ServerMsg::TerminalRefused { op, code, .. } if op == "remote_open" && code == "no_operator")
            })
            .await;
        old_app
            .assert_no_remote_frames(from, "no sheet to show")
            .await;
        d.assert_nothing_opened("no sheet to show");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// AC9: the vocabulary on the wire
// ═════════════════════════════════════════════════════════════════════════════

fn targets_of(c: &Unix, from: usize) -> Option<ServerMsg> {
    c.log[from..]
        .iter()
        .find(|m| matches!(m, ServerMsg::RemoteShellTargets { .. }))
        .cloned()
}

#[tokio::test(flavor = "multi_thread")]
async fn any_local_process_can_ask_for_the_vocabulary_and_only_it_is_answered() {
    let d = Daemon::start(&[Peer::App, Peer::Script, Peer::Script]).await;
    let mut app = d.app().await;
    let mut script = d.script(vec![], &[]).await;
    let mut impostor = d.claiming_app().await;
    let mut bystander = d.script(vec![], &[]).await;
    let by_mark = bystander.mark();

    for (who, client) in [
        ("the app", &mut app),
        ("a process", &mut script),
        ("an impostor", &mut impostor),
    ] {
        let from = client.mark();
        client.send(&ClientMsg::RemoteShellTargetsRequest).await;
        client.sync().await;

        let ServerMsg::RemoteShellTargets {
            configured,
            problem,
            projects,
            shell_types,
        } = targets_of(client, from)
            .unwrap_or_else(|| panic!("{who}: no answer: {}", client.summary()))
        else {
            unreachable!()
        };

        assert!(configured, "{who}");
        assert_eq!(problem, None, "{who}");
        assert_eq!(shell_types, names(&["console", "shell", "tinker"]), "{who}");
        let project_names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            project_names,
            [
                "admin-portal",
                "family-portal",
                "payments",
                "referral-monitor"
            ],
            "{who}"
        );
        let ap = &projects[0];
        assert_eq!(ap.default_service.as_deref(), Some("portal"), "{who}");
        let env_names: Vec<&str> = ap.environments.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            env_names,
            ["canada", "demo", "production", "staging"],
            "{who}: qa has no region"
        );
        let production = ap
            .environments
            .iter()
            .find(|e| e.name == "production")
            .unwrap();
        assert_eq!(
            production.services,
            names(&["api", "portal", "queue", "referral-intake", "scheduler"]),
            "{who}"
        );
        assert_eq!(
            projects[3].default_service.as_deref(),
            Some("monitor"),
            "{who}"
        );
        // No profile, cluster, region, account or command in it.
        let wire = serde_json::to_string(&client.log[from..]).unwrap();
        for secret in [
            "fake-prod-ecs",
            "fake-demo-ecs",
            "profile",
            "sso",
            "us-east-2",
            "ca-central-1",
            "production-fake",
            "/bin/bash",
            "php artisan",
        ] {
            assert!(!wire.contains(secret), "{who}: {secret} in {wire}");
        }
    }
    // It is a reply to the asker, not a broadcast.
    bystander
        .assert_no_remote_frames(by_mark, "a bystander")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_config_json_the_vocabulary_says_it_is_not_configured_and_why() {
    let d = Daemon::start(&[Peer::Script]).await;
    d.remove_ecs("config.json");
    let mut script = d.script(vec![], &[]).await;
    let from = script.mark();

    script.send(&ClientMsg::RemoteShellTargetsRequest).await;
    script.sync().await;

    let ServerMsg::RemoteShellTargets {
        configured,
        problem,
        projects,
        shell_types,
    } = targets_of(&script, from).expect("an answer")
    else {
        unreachable!()
    };
    assert!(!configured);
    assert!(
        problem.is_some_and(|p| p.contains("config.json")),
        "the problem says what is missing"
    );
    assert!(projects.is_empty());
    assert!(shell_types.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_vocabulary_is_read_again_for_every_ask() {
    let d = Daemon::start(&[Peer::Script]).await;
    let mut script = d.script(vec![], &[]).await;

    let from = script.mark();
    script.send(&ClientMsg::RemoteShellTargetsRequest).await;
    script.sync().await;
    let ServerMsg::RemoteShellTargets { projects, .. } = targets_of(&script, from).unwrap() else {
        unreachable!()
    };
    assert!(projects.iter().any(|p| p.name == "payments"));

    d.edit_ecs("config.json", |c| {
        c.replace("\"payments\": {", "\"payments-v2\": {")
    });
    let from = script.mark();
    script.send(&ClientMsg::RemoteShellTargetsRequest).await;
    script.sync().await;
    let ServerMsg::RemoteShellTargets { projects, .. } = targets_of(&script, from).unwrap() else {
        unreachable!()
    };
    assert!(projects.iter().any(|p| p.name == "payments-v2"));
    assert!(!projects.iter().any(|p| p.name == "payments"));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agents_list_tool_returns_the_same_vocabulary_and_no_account_details() {
    let mut s = Scene::start().await;

    let res = s.mcp.call(LIST, json!({})).await;

    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(
        strings(&res["shell_types"]),
        names(&["console", "shell", "tinker"])
    );
    let projects = res["projects"].as_array().expect("projects");
    let project_names: Vec<&str> = projects
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        project_names,
        [
            "admin-portal",
            "family-portal",
            "payments",
            "referral-monitor"
        ]
    );
    let ap = &projects[0];
    assert_eq!(ap["default_service"], "portal");
    assert_eq!(
        ap["environments"][2],
        json!({"name": "production", "services": ["api", "portal", "queue", "referral-intake", "scheduler"]})
    );
    let text = res.to_string();
    for secret in ["fake-prod-ecs", "profile", "us-east-2", "/bin/bash"] {
        assert!(!text.contains(secret), "{secret} in {text}");
    }
    // It takes no arguments.
    let res = s.mcp.call(LIST, json!({"project": "admin-portal"})).await;
    assert_eq!(res["error"], "unknown_argument", "{res}");
    assert_eq!(res["detail"], "project");
    // And says so when there is nothing to list.
    s.d.remove_ecs("config.json");
    let res = s.mcp.call(LIST, json!({})).await;
    assert_eq!(res["error"], "remote_shells_not_configured", "{res}");
    assert!(!res["detail"].as_str().unwrap_or_default().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn editing_the_vocabulary_between_two_requests_changes_the_second_result() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    let args_for = |service: &str| json!({"project":"admin-portal","environment":"demo","service":service,"shell_type":"shell"});

    // `cron` is not a service yet ...
    let res = s.mcp.call(REQUEST, args_for("cron")).await;
    assert_eq!(res["error"], "invalid_target", "{res}");
    assert_eq!(res["valid"]["field"], "service");
    // ... until the data says so (a service, and an alias for it).
    s.d.edit_ecs("config.json", |c| {
        c.replace(
            "\"scheduler\": { \"service\": \"demo-fake-ap-scheduler\", \"container\": \"main\" }",
            "\"cron\": { \"service\": \"demo-fake-ap-scheduler\", \"container\": \"main\" }",
        )
    });
    s.d.edit_ecs("ecs.sh", |c| {
        c.replace("    [job]=\"scheduler\"\n", "    [job]=\"cron\"\n")
    });

    let (call, confirm) = s.ask(args_for("cron")).await;
    assert_eq!(confirm.target.service, "cron");
    s.app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
    clock.advance(Duration::from_secs(60));
    let (call, confirm) = s.ask(args_for("JOB")).await;
    assert_eq!(confirm.target.service, "cron", "the edited alias applies");
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;
    // The old name is gone, and the refusal lists the new set.
    let res = s.mcp.call(REQUEST, args_for("scheduler")).await;
    assert_eq!(res["error"], "invalid_target", "{res}");
    assert_eq!(
        strings(&res["valid"]["values"]),
        names(&["cron", "portal", "queue"])
    );
    // A vocabulary that disappears is not remembered either.
    s.d.remove_ecs("config.json");
    let res = s.mcp.call(REQUEST, args_for("cron")).await;
    assert_eq!(res["error"], "remote_shells_not_configured", "{res}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_profile_for_the_environment_is_not_needed_to_ask_for_a_shell() {
    // canada has CONFIGURE_ME as its profile: the sheet still names it; whether
    // a connection is possible is the launcher's business (slice 2b).
    let mut s = Scene::start().await;

    let (call, confirm) = s
        .ask(json!({"project":"ap","environment":"canada","service":"sched","shell_type":"shell"}))
        .await;

    assert_eq!(confirm.target.environment, "canada");
    s.app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

// ═════════════════════════════════════════════════════════════════════════════
// AC10: the audit trail
// ═════════════════════════════════════════════════════════════════════════════

fn keys(v: &Value) -> Vec<String> {
    let mut k: Vec<String> = v.as_object().expect("an object").keys().cloned().collect();
    k.sort();
    k
}

#[tokio::test(flavor = "multi_thread")]
async fn the_audit_lines_carry_only_the_documented_fields() {
    let mut s = Scene::start().await;
    let a = args_with("reason", json!("Look at the scheduler log"));
    let (call, confirm) = s.ask(a.clone()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;
    assert_eq!(res["ok"], true);
    s.d.wait_audit("connected", |l| l["event"] == "connected")
        .await;
    s.d.launcher().set_failure(Some(ConnectFailure {
        reason_code: "no_running_task".into(),
        message: "no task is running".into(),
        remedy: None,
        detail: None,
    }));
    let (call, confirm) = s.ask(a).await;
    s.app.answer(&confirm.request_id, "connect").await;
    assert_eq!(s.mcp.finish(call).await["error"], "connect_failed");

    let lines = s.d.remote_audit();

    let by_event =
        |event: &str| -> Vec<&Value> { lines.iter().filter(|l| l["event"] == event).collect() };
    for line in by_event("remote_requested") {
        assert_eq!(
            keys(line),
            ["event", "reason", "requested_by", "tag", "target", "ts"],
            "{line}"
        );
        assert_eq!(keys(&line["requested_by"]), ["kind", "tag"], "{line}");
        assert_eq!(line["requested_by"]["kind"], "focus");
        assert_eq!(line["requested_by"]["tag"], TAG);
        assert_eq!(line["reason"], "Look at the scheduler log");
        assert_eq!(
            keys(&line["target"]),
            ["environment", "project", "service", "shell_type"]
        );
    }
    for line in by_event("confirm_outcome") {
        assert_eq!(
            keys(line),
            ["event", "outcome", "tag", "target", "ts"],
            "{line}"
        );
        assert_eq!(line["outcome"], "connect");
    }
    // The connect lines also carry the digests the request was pinned to:
    // flat fields, hex only (the `local_sha256` only when there was a file).
    for line in by_event("connect_started") {
        assert_eq!(
            keys(line),
            [
                "argv_sha256",
                "config_sha256",
                "event",
                "local_sha256",
                "tag",
                "target",
                "ts"
            ],
            "{line}"
        );
    }
    for line in by_event("connected") {
        assert_eq!(
            keys(line),
            [
                "argv_sha256",
                "config_sha256",
                "event",
                "kind",
                "local_sha256",
                "pane_id",
                "tag",
                "target",
                "terminal_id",
                "ts"
            ],
            "{line}"
        );
    }
    for line in by_event("connect_failed") {
        assert_eq!(
            keys(line),
            ["event", "reason_code", "tag", "target", "ts"],
            "{line}"
        );
        assert_eq!(line["reason_code"], "no_running_task");
    }
    assert_eq!(by_event("remote_requested").len(), 2);
    assert_eq!(by_event("connected").len(), 1);
    assert_eq!(by_event("connect_failed").len(), 1);

    // No command, no cluster, no account, no keystroke anywhere in the trail.
    let text = s.d.audit_text();
    for never in [
        "execute-command",
        "/bin/bash",
        "php artisan",
        "fake-prod-ecs",
        "fake-prod-profile",
        "production-fake-ap-scheduler",
        "us-east-2",
        "sso",
        "aws ",
        "keystroke",
    ] {
        assert!(
            !text.contains(never),
            "{never:?} in the audit trail:\n{text}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reason_longer_than_two_hundred_characters_is_cut_to_two_hundred_for_the_sheet_and_the_trail(
) {
    // The MCP tool refuses a longer reason, so go in through the same entry
    // point it uses.
    let s = Scene::start().await;
    let mut app = s.app;
    let api = TerminalAgentApi::new(Arc::clone(&s.d.terminals));
    let long: String = (0..300)
        .map(|i| char::from(b'a' + (i % 26) as u8))
        .collect();
    let from = app.mark();

    let asking = tokio::spawn(async move {
        api.request_remote(AgentRemoteRequest {
            tag: TAG.into(),
            agent: Some(AGENT.into()),
            project: "ap".into(),
            environment: "prod".into(),
            service: "sched".into(),
            shell_type: "shell".into(),
            reason: Some(long.clone()),
            timeout: Duration::from_secs(300),
        })
        .await
    });
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "cancel").await;
    let result = tokio::time::timeout(WAIT, asking).await.unwrap().unwrap();
    assert!(matches!(result, RemoteResult::Cancelled), "{result:?}");

    let expected: String = (0..200)
        .map(|i| char::from(b'a' + (i % 26) as u8))
        .collect();
    assert_eq!(
        confirm.reason.as_deref(),
        Some(expected.as_str()),
        "what the sheet shows"
    );
    let line =
        s.d.wait_audit("remote_requested", |l| l["event"] == "remote_requested")
            .await;
    assert_eq!(line["reason"], expected.as_str(), "what the trail keeps");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_request_without_a_reason_has_no_reason_on_the_sheet_or_in_the_trail() {
    let mut s = Scene::start().await;

    let (call, confirm) = s.ask(args_without("reason")).await;
    s.app.answer(&confirm.request_id, "cancel").await;
    s.mcp.finish(call).await;

    assert_eq!(confirm.reason, None);
    let line =
        s.d.wait_audit("remote_requested", |l| l["event"] == "remote_requested")
            .await;
    assert!(line.get("reason").is_none(), "{line}");
}

// ═════════════════════════════════════════════════════════════════════════════
// The agent goes away
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn when_the_request_is_dropped_while_waiting_the_sheet_is_closed_and_the_slot_freed() {
    // The library entry point the MCP tool uses: abandon it (the task is
    // cancelled) while the user has not answered.
    let s = Scene::start().await;
    let mut app = s.app;
    let api = TerminalAgentApi::new(Arc::clone(&s.d.terminals));
    let from = app.mark();
    let asking = tokio::spawn({
        let api = api.clone();
        async move {
            api.request_remote(AgentRemoteRequest {
                tag: TAG.into(),
                agent: Some(AGENT.into()),
                project: "ap".into(),
                environment: "prod".into(),
                service: "sched".into(),
                shell_type: "shell".into(),
                reason: None,
                timeout: Duration::from_secs(300),
            })
            .await
        }
    });
    let confirm = app.wait_confirm(from).await;

    asking.abort();
    let _ = asking.await;

    let resolved = app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "cancelled");
    assert_eq!(resolved.reason.as_deref(), Some("requester_gone"));
    s.d.wait_audit("abandoned", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "abandoned"
    })
    .await;
    assert_eq!(
        s.d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:abandoned"]
    );
    s.d.assert_nothing_opened("an abandoned request");
    // A late click on the closed sheet does nothing ...
    app.answer(&confirm.request_id, "connect").await;
    app.sync().await;
    assert_eq!(s.d.launcher().calls(), 0);
    // ... and a new request is accepted.
    let from = app.mark();
    let again = tokio::spawn(async move {
        api.request_remote(AgentRemoteRequest {
            tag: TAG.into(),
            agent: None,
            project: "ap".into(),
            environment: "prod".into(),
            service: "sched".into(),
            shell_type: "shell".into(),
            reason: None,
            timeout: Duration::from_secs(300),
        })
        .await
    });
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "cancel").await;
    assert!(matches!(again.await.unwrap(), RemoteResult::Cancelled));
}

#[tokio::test(flavor = "multi_thread")]
async fn when_the_agents_connection_closes_while_waiting_the_sheet_is_closed_and_the_request_is_abandoned(
) {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let (_call, confirm) = s.ask(args()).await;

    // The agent's session ends (its MCP connection closes) with the sheet up.
    drop(s.mcp);

    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(
        resolved.outcome, "cancelled",
        "the sheet must not stay up for a caller that is gone"
    );
    assert_eq!(resolved.reason.as_deref(), Some("requester_gone"));
    s.d.wait_audit("abandoned", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "abandoned"
    })
    .await;
    s.d.assert_nothing_opened("an abandoned request");
    // The slot is free: another agent can ask.
    s.d.init_focus(TAG2);
    let mut other = s.d.mcp(Some(TAG2)).await;
    let from = s.app.mark();
    let call = other.start_call(REQUEST, args()).await;
    let next = s.app.wait_confirm(from).await;
    s.app.answer(&next.request_id, "cancel").await;
    let res = other.finish(call).await;
    assert_eq!(res["error"], "cancelled", "not request_pending: {res}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Who may call the tools at all
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_network_driven_session_is_not_offered_the_remote_shell_tools_and_is_refused_if_it_calls_them(
) {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    d.init_focus(TAG2);
    d.session_mgr
        .lock()
        .unwrap()
        .sensitive_tags()
        .mark_network_driven(TAG);
    let mut app = d.app().await;
    let mut driven = d.mcp(Some(TAG)).await;
    let mut plain = d.mcp(Some(TAG2)).await;
    let from = app.mark();
    let offered = |tools: &[Value], name: &str| tools.iter().any(|t| t["name"] == name);

    let driven_tools = driven.list_tools().await;
    let plain_tools = plain.list_tools().await;

    assert!(!offered(&driven_tools, REQUEST) && !offered(&driven_tools, LIST));
    assert!(offered(&plain_tools, REQUEST) && offered(&plain_tools, LIST));
    let a = args_with("reason", json!("SECRET-REASON-77"));
    let resp = driven.call_raw(REQUEST, a).await;
    assert_eq!(resp["error"]["code"], json!(TOOL_FORBIDDEN_CODE), "{resp}");
    let resp = driven.call_raw(LIST, json!({})).await;
    assert_eq!(resp["error"]["code"], json!(TOOL_FORBIDDEN_CODE), "{resp}");
    // The refusal is audited with the focus and the tool, and nothing else.
    let line = d
        .wait_audit("a refused request", |l| {
            l["event"] == "refused" && l["tool"] == REQUEST
        })
        .await;
    assert_eq!(line["channel"], "mcp", "{line}");
    assert_eq!(line["op"], "remote_request", "{line}");
    assert_eq!(line["code"], "forbidden", "{line}");
    assert_eq!(line["focus"], TAG, "{line}");
    assert!(!d.audit_text().contains("SECRET-REASON-77"));
    assert_app_not_asked(&mut app, from, "a network-driven session").await;
    d.assert_nothing_opened("a network-driven session");
    assert!(d.remote_audit().is_empty());
}

/// A tool policy that denies the two remote shell tools to one agent. Written
/// under the private `$HOME`; the agent has a name no other test uses, so the
/// file changes nothing for tests that run beside this one. Removed on drop.
struct PolicyFile(std::path::PathBuf);

const POLICY_AGENT: &str = "redd-policy-denied-agent";

impl PolicyFile {
    fn deny_remote_shell_tools_to(agent: &str) -> PolicyFile {
        let path = nostromo::mcp::tool_policy::policy_path();
        assert!(
            path.starts_with(
                std::path::Path::new(env!("CARGO_TARGET_TMPDIR"))
                    .join(format!("remote-shell-it-home-{}", std::process::id()))
            ),
            "the policy file must be under the private $HOME, not {}",
            path.display()
        );
        std::fs::create_dir_all(path.parent().unwrap()).expect("create ~/.nostromo");
        let guard = PolicyFile(path.clone());
        let yaml = format!("agents:\n  {agent}:\n    deny:\n      - {REQUEST}\n      - {LIST}\n");
        std::fs::write(&path, yaml).expect("write the policy");
        guard
    }
}

impl Drop for PolicyFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// `caller` (an MCP connection that must be refused both remote shell tools)
/// is not offered them, is refused with -32001 when it calls them by name, and
/// nothing else happens: one `refused` audit line for the request (focus and
/// tool, no arguments), none for anything else, nothing sent to the app, the
/// launcher never called, nothing registered (a plain agent is then asked
/// about at once).
async fn assert_remote_shell_tools_refused_with_no_side_effect(
    d: &Daemon,
    app: &mut Unix,
    caller: &mut Mcp,
    focus: &str,
    who: &str,
) {
    let offered = |tools: &[Value], name: &str| tools.iter().any(|t| t["name"] == name);
    let tools = caller.list_tools().await;
    assert!(!offered(&tools, REQUEST), "{who}: offered {REQUEST}");
    assert!(!offered(&tools, LIST), "{who}: offered {LIST}");
    let audit_before = d.audit();
    let from = app.mark();

    let resp = caller
        .call_raw(REQUEST, args_with("reason", json!("SECRET-REASON-91")))
        .await;
    assert_eq!(
        resp["error"]["code"],
        json!(TOOL_FORBIDDEN_CODE),
        "{who}: {resp}"
    );
    let resp = caller.call_raw(LIST, json!({})).await;
    assert_eq!(
        resp["error"]["code"],
        json!(TOOL_FORBIDDEN_CODE),
        "{who}: {resp}"
    );
    // Naming a target that does not exist is refused the same way: the
    // refusal comes before anything is looked at.
    let resp = caller
        .call_raw(REQUEST, args_with("project", json!("billing-zzz")))
        .await;
    assert_eq!(
        resp["error"]["code"],
        json!(TOOL_FORBIDDEN_CODE),
        "{who}: {resp}"
    );

    // The request is audited as refused, by tool and focus, and nothing else is.
    d.wait_audit("a refused request", |l| {
        l["event"] == "refused" && l["tool"] == REQUEST
    })
    .await;
    assert_app_not_asked(app, from, who).await;
    let new_lines: Vec<Value> = d.audit()[audit_before.len()..].to_vec();
    assert!(
        new_lines
            .iter()
            .all(|l| l["event"] == "refused" && l["tool"] == REQUEST),
        "{who}: only refusals of the request tool are audited: {new_lines:#?}"
    );
    assert!(!new_lines.is_empty(), "{who}: the refusal is audited");
    for line in &new_lines {
        assert_eq!(line["channel"], "mcp", "{who}: {line}");
        assert_eq!(line["op"], "remote_request", "{who}: {line}");
        assert_eq!(line["code"], "forbidden", "{who}: {line}");
        assert_eq!(line["focus"], focus, "{who}: {line}");
        assert!(line.get("reason").is_none() && line.get("arguments").is_none());
    }
    let text = d.audit_text();
    assert!(
        !text.contains("SECRET-REASON-91") && !text.contains("billing-zzz"),
        "{who}: the audit trail holds what the caller passed: {text}"
    );
    assert!(d.remote_audit().is_empty(), "{who}: {:?}", d.remote_audit());
    d.assert_nothing_opened(who);

    // Nothing is left pending: an ordinary agent is asked about at once.
    d.init_focus(TAG2);
    let mut plain = d.mcp(Some(TAG2)).await;
    let from = app.mark();
    let call = plain.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    assert_eq!(confirm.tag.as_deref(), Some(TAG2), "{who}");
    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(
        plain.finish(call).await["error"],
        "cancelled",
        "{who}: not request_pending"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_picks_session_is_not_offered_the_remote_shell_tools_and_is_refused_if_it_calls_them() {
    let d = Daemon::start(&[Peer::App]).await;
    assert!(d.tree(PICKS_TAG).is_none(), "harness: picks has no focus");
    let mut app = d.app().await;
    let mut picks = d.mcp(Some(PICKS_TAG)).await;

    assert_remote_shell_tools_refused_with_no_side_effect(
        &d,
        &mut app,
        &mut picks,
        PICKS_TAG,
        "the picks session",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_the_operators_policy_denies_is_not_offered_the_remote_shell_tools_and_is_refused_if_it_calls_them(
) {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut meta = focus_meta(TAG);
    meta.agent_name = POLICY_AGENT.to_string();
    d.session_mgr.lock().unwrap().set_focus_registry(vec![meta]);
    let _policy = PolicyFile::deny_remote_shell_tools_to(POLICY_AGENT);
    let mut app = d.app().await;
    let mut restricted = d.mcp(Some(TAG)).await;

    assert_remote_shell_tools_refused_with_no_side_effect(
        &d,
        &mut app,
        &mut restricted,
        TAG,
        "an agent the policy denies",
    )
    .await;
}

// ═════════════════════════════════════════════════════════════════════════════
// FND-1 (T7): TCP
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn every_remote_shell_client_frame_over_tcp_is_refused_audited_and_has_no_effect() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut tcp = d.tcp(vec![], true).await;
    let from = app.mark();
    let frames = [
        ClientMsg::RemoteShellTargetsRequest,
        ClientMsg::RemoteShellOpen {
            tag: TAG.into(),
            project: "admin-portal".into(),
            environment: "production".into(),
            service: "scheduler".into(),
            shell_type: "shell".into(),
        },
        ClientMsg::RemoteShellAnswer {
            request_id: "any".into(),
            decision: "connect".into(),
            invite_follow: false,
        },
    ];
    let start = tcp.mark();

    for frame in &frames {
        let before = tcp.mark();
        tcp.send(frame).await;
        tcp.sync().await;
        let errors = tcp.errors_since(before);
        assert!(
            errors
                .iter()
                .any(|m| m.starts_with("requires_secure_connection")),
            "{frame:?}: {errors:?}; [{}]",
            tcp.summary()
        );
    }

    // No answer, no refusal frame: a TCP peer is told nothing about terminals.
    assert!(
        tcp.remote_frames_since(start).is_empty(),
        "[{}]",
        tcp.summary()
    );
    assert!(tcp.refusals_since(start).is_empty());
    // Each is audited as refused on the tcp channel.
    let deadline = Instant::now() + WAIT;
    while d.refused_lines("tcp").len() < frames.len() {
        assert!(Instant::now() < deadline, "audit: {:#?}", d.audit());
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(d.refused_lines("tcp").iter().all(|l| l["op"] == "control"));
    // No effect: no sheet, no request, nothing pending.
    assert_app_not_asked(&mut app, from, "frames over tcp").await;
    d.assert_nothing_opened("frames over tcp");
    assert!(d.remote_audit().is_empty());
    let mut mcp = d.mcp(Some(TAG)).await;
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(
        mcp.finish(call).await["error"],
        "cancelled",
        "not request_pending"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tcp_client_subscribed_to_everything_never_receives_a_remote_shell_frame() {
    let d = Daemon::start(&[Peer::App]).await;
    d.init_focus(TAG);
    let mut tcp_all = d.tcp(vec![], true).await;
    let mut tcp_decisions = d.tcp(vec![Topic::Decision, Topic::Terminal], true).await;
    let mut app = d.app().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let from = app.mark();

    // Every remote-shell frame happens while they are connected: the app asks
    // for the vocabulary, an agent's request is shown and connected (a launch,
    // then the sheet's end) ...
    app.send(&ClientMsg::RemoteShellTargetsRequest).await;
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;
    app.answer(&confirm.request_id, "connect").await;
    assert_eq!(mcp.finish(call).await["ok"], true);
    app.wait_resolved(from, &confirm.request_id).await;
    app.sync().await;
    // ... and the daemon's own broadcast channel is offered one of each too.
    for msg in [
        ServerMsg::RemoteShellTargets {
            configured: true,
            problem: None,
            projects: vec![],
            shell_types: vec![],
        },
        ServerMsg::RemoteShellConfirmRequest {
            request_id: "broadcast-1".into(),
            tag: Some(TAG.into()),
            target: canonical_target(),
            requested_by: nostromo::ipc::protocol::RemoteRequester {
                kind: "focus".into(),
                tag: Some(TAG.into()),
                agent: Some(AGENT.into()),
            },
            reason: Some("SECRET-REASON".into()),
            expires_at: "2026-10-25T12:00:00Z".into(),
            shell_command: Some("SECRET-COMMAND".into()),
            profile: Some("SECRET-PROFILE".into()),
            cluster: Some("SECRET-CLUSTER".into()),
        },
        ServerMsg::RemoteShellResolved {
            request_id: "broadcast-1".into(),
            outcome: "connected".into(),
            reason: None,
            remedy: None,
            detail: None,
        },
    ] {
        d.server.broadcast(msg);
    }
    let mut tcp_late = d.tcp(vec![], true).await;

    for (who, c) in [
        ("a tcp peer on every topic", &mut tcp_all),
        ("a tcp peer that renders decisions", &mut tcp_decisions),
        ("a tcp peer that connected afterwards", &mut tcp_late),
    ] {
        // The ordered broadcast channel: once this control frame is here,
        // everything offered before it has been delivered or dropped.
        let mark = c.mark();
        d.server.broadcast(ServerMsg::Pong);
        c.wait_since(mark, "the control broadcast", |m| {
            matches!(m, ServerMsg::Pong)
        })
        .await;
        c.sync().await;
        assert!(
            c.remote_frames_since(0).is_empty(),
            "{who} received a remote-shell frame: [{}]",
            c.summary()
        );
        assert!(
            !c.log
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalRefused { .. })),
            "{who}"
        );
    }
    // Controls: the app received all three frames the TCP peers must not.
    let kinds = app.remote_frames_since(from);
    for want in [
        "remote_shell_targets",
        "remote_shell_confirm_request",
        "remote_shell_resolved",
    ] {
        assert!(
            kinds.iter().any(|k| k == want),
            "control: the app should have received {want}: {kinds:?}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_general_broadcast_never_carries_a_remote_shell_frame_to_any_local_client() {
    // These three frames are per-connection: the daemon addresses them to the
    // connections concerned and never puts one on the shared broadcast. Were
    // one ever put there (a refactor, a mistaken `broadcast`), a confirm
    // request would hand a production target and the agent's stated reason to
    // every local process, so the broadcast path must drop them whoever listens
    // (as it does for terminal bytes and terminal_refused).
    let d = Daemon::start(&[Peer::App, Peer::App, Peer::Script]).await;
    let mut app = d.app().await;
    let mut old_app = d.app_without_sheet().await;
    let mut script = d.script(vec![], &[CONFIRM_CAP]).await;
    let marks = (app.mark(), old_app.mark(), script.mark());

    for msg in [
        ServerMsg::RemoteShellTargets {
            configured: true,
            problem: None,
            projects: vec![],
            shell_types: vec![],
        },
        ServerMsg::RemoteShellConfirmRequest {
            request_id: "broadcast-1".into(),
            tag: Some(TAG.into()),
            target: canonical_target(),
            requested_by: nostromo::ipc::protocol::RemoteRequester {
                kind: "focus".into(),
                tag: Some(TAG.into()),
                agent: Some(AGENT.into()),
            },
            reason: Some("SECRET-REASON".into()),
            expires_at: "2026-10-25T12:00:00Z".into(),
            shell_command: Some("SECRET-COMMAND".into()),
            profile: Some("SECRET-PROFILE".into()),
            cluster: Some("SECRET-CLUSTER".into()),
        },
        ServerMsg::RemoteShellResolved {
            request_id: "broadcast-1".into(),
            outcome: "connected".into(),
            reason: None,
            remedy: None,
            detail: None,
        },
    ] {
        d.server.broadcast(msg);
    }

    for (who, c, mark) in [
        ("the app with the sheet", &mut app, marks.0),
        ("the app without the sheet", &mut old_app, marks.1),
        ("a local process", &mut script, marks.2),
    ] {
        let from = c.mark();
        d.server.broadcast(ServerMsg::Pong);
        c.wait_since(from, "the control broadcast", |m| {
            matches!(m, ServerMsg::Pong)
        })
        .await;
        assert!(
            c.remote_frames_since(mark).is_empty(),
            "{who} was sent a remote-shell frame by the general broadcast: [{}]",
            c.summary()
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The agent cancels (or hangs up) while the sheet is up
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn cancelling_the_call_closes_the_sheet_abandons_the_request_and_the_connection_carries_on() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let (call, confirm) = s.ask(args()).await;

    s.mcp.cancel(call).await;

    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "cancelled");
    assert_eq!(resolved.reason.as_deref(), Some("requester_gone"));
    s.d.wait_audit("abandoned", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "abandoned"
    })
    .await;
    assert_eq!(
        s.d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:abandoned"]
    );
    s.d.assert_nothing_opened("a cancelled call");
    // A click on the closed sheet does nothing.
    s.app.answer(&confirm.request_id, "connect").await;
    s.app.sync().await;
    assert_eq!(s.d.launcher().calls(), 0);

    // No answer is owed for the cancelled call, and the same connection keeps
    // working: `rpc` insists the next response is for the next request.
    let pong = s.mcp.rpc("ping", json!({})).await;
    assert!(pong.get("error").is_none(), "{pong}");
    assert!(!s.mcp.list_tools().await.is_empty());
    // The slot is free, on that same connection.
    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;
    assert_eq!(res["ok"], true, "not request_pending: {res}");
}

#[tokio::test(flavor = "multi_thread")]
async fn cancelling_some_other_request_id_changes_nothing() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let (call, confirm) = s.ask(args()).await;

    s.mcp.cancel(call + 1000).await;
    s.mcp.cancel(call - 1).await;
    s.mcp
        .notify(
            "notifications/cancelled",
            json!({"requestId": "not-a-number"}),
        )
        .await;
    s.mcp.notify("notifications/cancelled", json!({})).await;
    s.app.sync().await;
    s.app.settle(Duration::from_millis(200)).await;

    assert!(s.app.resolved_since(from).is_empty(), "{}", s.app.summary());
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;
    assert_eq!(res["ok"], true, "the call was still live: {res}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_frame_sent_while_the_call_waits_is_answered_after_the_call_ends_in_order() {
    let mut s = Scene::start().await;
    let (call, confirm) = s.ask(args()).await;

    let ping = s.mcp.start_rpc("ping", json!({})).await;
    let tools = s.mcp.start_rpc("tools/list", json!({})).await;
    s.app.sync().await;
    s.app.settle(Duration::from_millis(150)).await;
    s.app.answer(&confirm.request_id, "dismiss").await;

    // The call's own answer comes first, then the queued ones in the order sent.
    assert_eq!(s.mcp.finish(call).await["error"], "dismissed");
    let pong = s.mcp.finish_raw(ping).await;
    assert!(pong.get("error").is_none(), "{pong}");
    let listed = s.mcp.finish_raw(tools).await;
    assert!(
        listed["result"]["tools"]
            .as_array()
            .is_some_and(|t| !t.is_empty()),
        "{listed}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancel_for_another_tool_call_is_not_taken_for_this_one_and_other_tools_are_not_cancellable(
) {
    // Only the request tool is dropped on cancel; a list call is a quick
    // answer, and a cancel that arrives after it has ended is just ignored.
    let mut s = Scene::start().await;

    let id = s.mcp.start_call(LIST, json!({})).await;
    let res = s.mcp.finish(id).await;
    assert_eq!(res["ok"], true);
    s.mcp.cancel(id).await;

    let pong = s.mcp.rpc("ping", json!({})).await;
    assert!(pong.get("error").is_none(), "{pong}");
}

// ═════════════════════════════════════════════════════════════════════════════
// The last app that could show the sheet goes away
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn when_the_last_app_with_the_sheet_disconnects_the_request_ends_at_once_as_no_operator() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let from = app.mark();
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;

    drop(app);

    let res = mcp.finish(call).await;
    assert_eq!(res["error"], "no_operator", "{res}");
    d.wait_audit("operator_gone", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "operator_gone"
    })
    .await;
    assert_eq!(
        d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:operator_gone"]
    );
    d.assert_nothing_opened("the operator left");
    // With an app back, a new request is asked as usual (and the old id is dead).
    let mut app = d.app().await;
    let from = app.mark();
    let call = mcp.start_call(REQUEST, args()).await;
    let next = app.wait_confirm(from).await;
    assert_ne!(next.request_id, confirm.request_id);
    app.answer(&confirm.request_id, "connect").await;
    app.sync().await;
    assert_eq!(
        d.launcher().calls(),
        0,
        "the old request's id changes nothing"
    );
    app.answer(&next.request_id, "connect").await;
    let res = mcp.finish(call).await;
    assert_eq!(res["ok"], true, "{res}");
}

#[tokio::test(flavor = "multi_thread")]
async fn when_the_app_stops_declaring_the_capability_the_request_ends_at_once_as_no_operator() {
    let mut s = Scene::start().await;
    let from = s.app.mark();
    let (call, confirm) = s.ask(args()).await;

    s.app
        .resubscribe(vec![Topic::Terminal, Topic::Layout], &["terminal_ui"])
        .await;

    let res = s.mcp.finish(call).await;
    assert_eq!(res["error"], "no_operator", "{res}");
    // The sheet that was up is told it is over.
    s.app.wait_resolved(from, &confirm.request_id).await;
    s.d.wait_audit("operator_gone", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "operator_gone"
    })
    .await;
    s.d.assert_nothing_opened("the capability was withdrawn");
    // It no longer counts for new requests either ...
    assert_eq!(s.mcp.call(REQUEST, args()).await["error"], "no_operator");
    // ... until it declares it again.
    s.app
        .resubscribe(
            vec![Topic::Terminal, Topic::Layout],
            &["terminal_ui", CONFIRM_CAP],
        )
        .await;
    s.app.sync().await;
    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "cancel").await;
    assert_eq!(s.mcp.finish(call).await["error"], "cancelled");
}

#[tokio::test(flavor = "multi_thread")]
async fn while_another_app_with_the_sheet_remains_the_request_stays_pending() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    d.init_focus(TAG);
    let mut first = d.app().await;
    let mut second = d.app().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let (m1, m2) = (first.mark(), second.mark());
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = first.wait_confirm(m1).await;
    second.wait_confirm(m2).await;

    drop(first);
    second.sync().await;
    second.settle(Duration::from_millis(300)).await;

    assert!(second.resolved_since(m2).is_empty(), "{}", second.summary());
    assert!(
        !d.audit().iter().any(|l| l["outcome"] == "operator_gone"),
        "{:?}",
        d.remote_audit_names()
    );
    second.answer(&confirm.request_id, "connect").await;
    let res = mcp.finish(call).await;
    assert_eq!(res["ok"], true, "{res}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Only a connection that was asked can answer
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_verified_app_that_was_never_asked_cannot_answer_for_the_one_that_was() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let mut old_app = d.app_without_sheet().await;
    let mut mcp = d.mcp(Some(TAG)).await;
    let from = app.mark();
    let call = mcp.start_call(REQUEST, args()).await;
    let confirm = app.wait_confirm(from).await;

    for decision in ["connect", "cancel", "dismiss"] {
        old_app.answer(&confirm.request_id, decision).await;
    }
    old_app.sync().await;
    app.sync().await;
    app.settle(Duration::from_millis(150)).await;

    assert_eq!(d.launcher().calls(), 0);
    assert!(app.resolved_since(from).is_empty(), "{}", app.summary());
    d.assert_nothing_opened("an answer from an app that was not asked");
    // The request is still pending, and the app that was asked answers it.
    app.answer(&confirm.request_id, "connect").await;
    let res = mcp.finish(call).await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(d.launcher().calls(), 1);
}

// ═════════════════════════════════════════════════════════════════════════════
// What the reason may contain
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn the_reason_is_cleaned_before_the_sheet_and_the_audit_trail_see_it() {
    let mut s = Scene::start().await;
    let clock = HandClock::install(&s.d);
    let cases: Vec<(&str, String, Option<String>)> = vec![
        (
            "a line break",
            "first\nsecond".into(),
            Some("first second".into()),
        ),
        (
            "a tab and a carriage return",
            "a\tb\rc".into(),
            Some("a b c".into()),
        ),
        (
            "a control character",
            "a\u{0007}b\u{001b}c".into(),
            Some("a b c".into()),
        ),
        (
            "bidi overrides and isolates",
            "\u{202E}evil\u{2066}x\u{2067}y\u{2068}z\u{2069}".into(),
            Some("evilxyz".into()),
        ),
        (
            "zero-width characters",
            "a\u{200B}b\u{200C}c\u{200D}d\u{200E}e\u{200F}f\u{FEFF}g".into(),
            Some("abcdefg".into()),
        ),
        (
            "surrounding whitespace",
            "  \n padded \t ".into(),
            Some("padded".into()),
        ),
        (
            "padding that takes the characters but not the text",
            format!("{}{}", "\u{200B}".repeat(100), "x".repeat(100)),
            Some("x".repeat(100)),
        ),
        (
            "nothing but such characters",
            "\u{202E}\u{200B}\n \t\u{FEFF}".into(),
            None,
        ),
        ("only whitespace", "   ".into(), None),
        (
            "an ordinary reason",
            "Check the scheduler log".into(),
            Some("Check the scheduler log".into()),
        ),
    ];

    for (what, reason, expected) in cases {
        let before =
            s.d.audit()
                .iter()
                .filter(|l| l["event"] == "remote_requested")
                .count();

        // Ten cancelled requests from one focus: out of the cooldown and the ceiling each time.
        clock.advance(Duration::from_secs(25 * 60));
        let (call, confirm) = s.ask(args_with("reason", json!(reason))).await;

        assert_eq!(confirm.reason, expected, "{what}: what the sheet shows");
        let line =
            s.d.wait_audit(what, |l| l["event"] == "remote_requested")
                .await;
        let _ = line;
        let lines: Vec<Value> =
            s.d.audit()
                .into_iter()
                .filter(|l| l["event"] == "remote_requested")
                .collect();
        assert_eq!(lines.len(), before + 1, "{what}");
        let line = lines.last().unwrap();
        match &expected {
            Some(text) => assert_eq!(
                line["reason"],
                text.as_str(),
                "{what}: what the trail keeps"
            ),
            None => assert!(
                line.get("reason").is_none(),
                "{what}: no reason in the trail: {line}"
            ),
        }
        s.app.answer(&confirm.request_id, "cancel").await;
        assert_eq!(s.mcp.finish(call).await["error"], "cancelled", "{what}");
    }
    // No hidden character reached the trail at all.
    let text = s.d.audit_text();
    for hidden in ['\u{202E}', '\u{2066}', '\u{200B}', '\u{FEFF}', '\u{200F}'] {
        assert!(
            !text.contains(hidden),
            "U+{:04X} in the audit trail",
            hidden as u32
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// A remote shell does not use up the agent's local-shell quota
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_remote_shell_an_agent_asked_for_does_not_count_against_its_local_shell_quota() {
    let mut s = Scene::start().await;
    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let remote = s.mcp.finish(call).await;
    assert_eq!(remote["ok"], true, "{remote}");

    // The agent may still open its two local shells in the same focus ...
    for n in 1..=2 {
        let res = s.mcp.call("nostromo.open_terminal", json!({})).await;
        assert_eq!(res["ok"], true, "local shell {n}: {res}");
    }
    // ... and the quota is still two: the remote one was not extra.
    let res = s.mcp.call("nostromo.open_terminal", json!({})).await;
    assert_eq!(res, json!({"error": "terminal_agent_quota_reached"}));
    // Three terminals: one remote, two local.
    let kinds: Vec<TerminalKind> = s.d.list().iter().map(|t| t.kind).collect();
    assert_eq!(
        kinds.iter().filter(|k| **k == TerminalKind::Ecs).count(),
        1,
        "{kinds:?}"
    );
    assert_eq!(
        kinds.iter().filter(|k| **k == TerminalKind::Local).count(),
        2,
        "{kinds:?}"
    );
}
