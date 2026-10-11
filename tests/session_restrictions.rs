//! Restricted daemon sessions: the hidden Teri picks session reads third-party
//! text (Jira tickets, repo docs, Sentry events) with nobody watching, so it must
//! run without the permission bypass the other daemon sessions get, with a closed
//! tool list and a spend cap, and in every spawn of its tag (a restart too).
//!
//! The argument vector is tested as a contract of `build_claude_args_with`; the
//! manager is tested end to end against a fake `claude` that writes down the
//! arguments it was started with. Killing the whole process group on stop is
//! covered next to the implementation.

use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

use nostromo::data::work::picks::{
    picks_restrictions, PICKS_BUILTIN_TOOLS, PICKS_MAX_BUDGET_USD, PICKS_MCP_TOOLS, PICKS_TAG,
};
use nostromo::ipc::session_manager::{
    build_claude_args, build_claude_args_with, SessionManager, SessionRestrictions, CLAUDE_BIN_ENV,
};

fn restrictions() -> SessionRestrictions {
    SessionRestrictions {
        builtin_tools: vec!["ToolSearch".into(), "Read".into()],
        allowed_tools: vec!["mcp__nostromo__a".into(), "mcp__nostromo__b".into(), "ToolSearch".into()],
        max_budget_usd: Some(1.5),
    }
}

/// The value following `flag`, if the flag is present.
fn value_of<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let at = args.iter().position(|a| a == flag)?;
    args.get(at + 1).map(String::as_str)
}

fn has(args: &[String], flag: &str) -> bool {
    args.iter().any(|a| a == flag)
}

// ── the argument vector ───────────────────────────────────────────────────────

#[test]
fn a_restricted_session_runs_without_the_permission_bypass_and_denies_what_is_not_allowed() {
    let r = restrictions();

    let args = build_claude_args_with("teri:teri", "Teri picks", false, "sid-1", false, Some(&r));

    assert!(!has(&args, "--dangerously-skip-permissions"), "{args:?}");
    assert_eq!(value_of(&args, "--permission-mode"), Some("dontAsk"), "{args:?}");
    assert!(has(&args, "--strict-mcp-config"), "only the daemon's own MCP server may load: {args:?}");
}

#[test]
fn a_restricted_session_gets_exactly_the_listed_builtin_and_allowed_tools_and_the_budget() {
    let r = restrictions();

    let args = build_claude_args_with("teri:teri", "Teri picks", false, "sid-1", false, Some(&r));

    assert_eq!(value_of(&args, "--tools"), Some("ToolSearch,Read"), "{args:?}");
    assert_eq!(value_of(&args, "--allowedTools"), Some("mcp__nostromo__a,mcp__nostromo__b,ToolSearch"), "{args:?}");
    let budget: f64 = value_of(&args, "--max-budget-usd").expect("a spend cap").parse().expect("a number");
    assert!((budget - 1.5).abs() < 1e-9, "{budget}");
}

#[test]
fn without_a_budget_there_is_no_spend_flag() {
    let r = SessionRestrictions { max_budget_usd: None, ..restrictions() };

    let args = build_claude_args_with("teri:teri", "Teri picks", false, "sid-1", false, Some(&r));

    assert!(!has(&args, "--max-budget-usd"), "{args:?}");
}

#[test]
fn a_restricted_session_keeps_the_agent_view_and_session_id_arguments() {
    let r = restrictions();

    let fresh = build_claude_args_with("teri:teri", "Teri picks", false, "sid-9", false, Some(&r));
    assert_eq!(value_of(&fresh, "--agent"), Some("teri:teri"));
    assert_eq!(value_of(&fresh, "-n"), Some("Teri picks"));
    assert_eq!(value_of(&fresh, "--session-id"), Some("sid-9"));
    assert!(!has(&fresh, "--resume"));
    assert_eq!(value_of(&fresh, "--input-format"), Some("stream-json"));
    assert_eq!(value_of(&fresh, "--output-format"), Some("stream-json"));

    let resumed = build_claude_args_with("teri:teri", "Teri picks", false, "sid-9", true, Some(&r));
    assert_eq!(value_of(&resumed, "--resume"), Some("sid-9"));
}

#[test]
fn an_unrestricted_session_is_exactly_what_it_was_before() {
    let plain = build_claude_args("cody", "Cody view", true, "sid-2", true);

    assert_eq!(plain, build_claude_args_with("cody", "Cody view", true, "sid-2", true, None));
    assert!(has(&plain, "--dangerously-skip-permissions"), "{plain:?}");
    for flag in ["--permission-mode", "--tools", "--allowedTools", "--strict-mcp-config", "--max-budget-usd"] {
        assert!(!has(&plain, flag), "{flag} must not appear on an ordinary session: {plain:?}");
    }
}

#[test]
fn the_picks_session_is_restricted_to_the_three_picks_tools_and_a_small_budget() {
    let r = picks_restrictions();

    assert_eq!(r.builtin_tools, PICKS_BUILTIN_TOOLS.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    let mut expected: Vec<String> = PICKS_MCP_TOOLS.iter().map(|s| s.to_string()).collect();
    expected.extend(PICKS_BUILTIN_TOOLS.iter().map(|s| s.to_string()));
    let mut allowed = r.allowed_tools.clone();
    allowed.sort();
    expected.sort();
    assert_eq!(allowed, expected, "the allow-list is the three picks tools plus the built-in tool search");
    assert_eq!(PICKS_MCP_TOOLS.len(), 3);
    assert!(PICKS_MCP_TOOLS.iter().all(|t| t.starts_with("mcp__nostromo__teri_")), "{PICKS_MCP_TOOLS:?}");
    for forbidden in ["Bash", "Write", "Edit", "Agent", "WebFetch", "WebSearch"] {
        assert!(!r.builtin_tools.iter().any(|t| t == forbidden), "{forbidden} must not be available");
        assert!(!r.allowed_tools.iter().any(|t| t == forbidden), "{forbidden} must not be pre-approved");
    }
    let budget = r.max_budget_usd.expect("the picks session has a spend cap");
    assert!(budget > 0.0 && budget <= 5.0, "{budget}");
    assert_eq!(Some(PICKS_MAX_BUDGET_USD), r.max_budget_usd);
    const { assert!(PICKS_MAX_BUDGET_USD > 0.0 && PICKS_MAX_BUDGET_USD <= 5.0) };
}

// ── the manager, against a fake claude ────────────────────────────────────────

/// Writes every run's argv to `<log dir>/<view name>.argv`, one argument per line, each run
/// closed by `--END--`, then idles until its stdin closes.
const FAKE_CLAUDE: &str = r#"#!/bin/sh
name=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-n" ]; then name="$a"; fi
  prev="$a"
done
out="@LOGDIR@/$name.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$out"; done
printf '%s\n' '--END--' >> "$out"
while IFS= read -r line; do :; done
"#;

static FAKE_DIR: OnceLock<PathBuf> = OnceLock::new();

fn install_fake_claude() -> &'static PathBuf {
    FAKE_DIR.get_or_init(|| {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nostromo-session-restrictions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(&script, FAKE_CLAUDE.replace("@LOGDIR@", dir.to_str().expect("utf8 temp dir"))).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        dir
    })
}

/// Each run of the fake `view`, as its argument list. Waits (bounded) for `runs` of them.
async fn runs_of(view: &str, runs: usize) -> Vec<Vec<String>> {
    let path = install_fake_claude().join(format!("{view}.argv"));
    for _ in 0..400 {
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        let done: Vec<Vec<String>> = text
            .split("--END--\n")
            .filter(|chunk| !chunk.is_empty())
            .map(|chunk| chunk.lines().map(String::from).collect())
            .collect();
        if text.ends_with("--END--\n") && done.len() >= runs {
            return done;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the fake claude `{view}` never recorded {runs} run(s)");
}

fn manager() -> (SessionManager, tempfile::TempDir) {
    install_fake_claude();
    let dir = tempfile::tempdir().unwrap();
    (SessionManager::with_store_path(dir.path().join("daemon-sessions.json")), dir)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tag_can_be_reserved_for_restricted_sessions_and_says_which_restrictions() {
    let (mut mgr, _dir) = manager();
    assert_eq!(mgr.restrictions_for("reserved-tag"), None);

    mgr.restrict_tag("reserved-tag", picks_restrictions());

    assert_eq!(mgr.restrictions_for("reserved-tag"), Some(&picks_restrictions()));
    assert_eq!(mgr.restrictions_for("some-other-tag"), None, "only the named tag is restricted");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_picks_tag_is_restricted_from_the_moment_the_manager_exists() {
    // Not only once the picks host has spawned it: a client or a respawn starting that tag is boxed in too.
    let (mgr, _dir) = manager();
    assert_eq!(mgr.restrictions_for(PICKS_TAG), Some(&picks_restrictions()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restricted_tag_is_started_with_the_restricted_arguments() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let view = "restricted-view-start";

    mgr.spawn_session(PICKS_TAG.into(), "teri:teri".into(), view.into(), Some(dir.path().to_path_buf()), None, false)
        .expect("the session starts");

    let runs = runs_of(view, 1).await;
    let args = &runs[0];
    assert!(!has(args, "--dangerously-skip-permissions"), "{args:?}");
    assert_eq!(value_of(args, "--permission-mode"), Some("dontAsk"), "{args:?}");
    assert!(has(args, "--strict-mcp-config"), "{args:?}");
    let r = picks_restrictions();
    assert_eq!(value_of(args, "--tools"), Some(r.builtin_tools.join(",").as_str()), "{args:?}");
    assert_eq!(value_of(args, "--allowedTools"), Some(r.allowed_tools.join(",").as_str()), "{args:?}");
    assert!(value_of(args, "--max-budget-usd").is_some(), "{args:?}");
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restricted_tag_stays_restricted_when_its_session_is_started_again() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let view = "restricted-view-again";
    let spawn = |mgr: &mut SessionManager| {
        mgr.spawn_session(PICKS_TAG.into(), "teri:teri".into(), view.into(), Some(dir.path().to_path_buf()), None, false)
            .expect("the session starts")
    };

    spawn(&mut mgr);
    runs_of(view, 1).await;
    // What the generator does between runs: end the session and forget it.
    mgr.new_session(PICKS_TAG);
    spawn(&mut mgr);

    let runs = runs_of(view, 2).await;
    assert_eq!(runs.len(), 2);
    for (n, args) in runs.iter().enumerate() {
        assert!(!has(args, "--dangerously-skip-permissions"), "run {n}: {args:?}");
        assert_eq!(value_of(args, "--permission-mode"), Some("dontAsk"), "run {n}: {args:?}");
        assert!(has(args, "--strict-mcp-config"), "run {n}: {args:?}");
    }
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tag_nobody_restricted_keeps_the_permission_bypass() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let view = "unrestricted-view";

    mgr.spawn_session("cody-plain".into(), "cody".into(), view.into(), Some(dir.path().to_path_buf()), None, false)
        .expect("the session starts");

    let runs = runs_of(view, 1).await;
    assert!(has(&runs[0], "--dangerously-skip-permissions"), "{:?}", runs[0]);
    for flag in ["--permission-mode", "--tools", "--allowedTools", "--strict-mcp-config", "--max-budget-usd"] {
        assert!(!has(&runs[0], flag), "{flag}: {:?}", runs[0]);
    }
    mgr.kill_all_on_shutdown();
}
