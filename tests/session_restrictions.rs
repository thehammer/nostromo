//! Restricted daemon sessions: the hidden Teri picks session reads third-party
//! text (Jira tickets, repo docs, Sentry events) with nobody watching, so it must
//! run without the permission bypass the other daemon sessions get, with a closed
//! tool list and a spend cap, and in every spawn of its tag (a restart too).
//!
//! The argument vector is tested as a contract of `build_claude_args_with`; the
//! manager is tested end to end against a fake `claude` that writes down the
//! arguments it was started with. Killing the whole process group on stop is
//! covered next to the implementation.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use nostromo::approvals::guard::hook_settings_json;
use nostromo::data::work::picks::{
    picks_restrictions, PICKS_BUILTIN_TOOLS, PICKS_MAX_BUDGET_USD, PICKS_MCP_TOOLS, PICKS_TAG,
};
use nostromo::ipc::session_manager::{
    build_claude_args, build_claude_args_with, SessionManager, SessionRestrictions, CLAUDE_BIN_ENV,
};

fn restrictions() -> SessionRestrictions {
    SessionRestrictions {
        builtin_tools: vec!["ToolSearch".into(), "Read".into()],
        allowed_tools: vec![
            "mcp__nostromo__a".into(),
            "mcp__nostromo__b".into(),
            "ToolSearch".into(),
        ],
        max_budget_usd: Some(1.5),
        model: None,
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

/// The production-shell guard's inline `--settings` JSON, for a guard binary at a fixed path.
fn guard_settings() -> String {
    hook_settings_json(Path::new("/opt/x/nostromo-guard"))
}

/// Where the two-element sequence `a, b` starts in `args`.
fn position_of_pair(args: &[String], a: &str, b: &str) -> Option<usize> {
    args.windows(2).position(|w| w[0] == a && w[1] == b)
}

/// `args` with exactly the two elements `--settings, <guard>` removed (and nothing else): what the
/// vector was before the guard existed.
#[track_caller]
fn without_the_guard(args: &[String], guard: &str) -> Vec<String> {
    assert_eq!(
        args.iter().filter(|a| *a == "--settings").count(),
        1,
        "one --settings, ours: {args:?}"
    );
    let at = position_of_pair(args, "--settings", guard)
        .unwrap_or_else(|| panic!("no `--settings <guard>` in {args:?}"));
    let mut rest = args.to_vec();
    rest.drain(at..at + 2);
    rest
}

fn strings(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

/// What the hidden picks session must be started with, whoever built the vector: no agent (the
/// plugin agent's own `tools:` list would override the allow-list and leave the session with no
/// tools at all), only project settings, no slash commands, and the closed tool list.
fn assert_is_the_picks_session_vector(args: &[String]) {
    assert!(!has(args, "--agent"), "no --agent flag at all: {args:?}");
    assert!(
        !args.iter().any(|a| a.contains("teri:teri")),
        "`teri:teri` appears nowhere: {args:?}"
    );
    assert_eq!(
        value_of(args, "--setting-sources"),
        Some("project"),
        "user hooks, CLAUDE.md and plugins must not load: {args:?}"
    );
    assert!(has(args, "--disable-slash-commands"), "{args:?}");
    assert_eq!(value_of(args, "--tools"), Some("ToolSearch"), "{args:?}");
    let allowed: std::collections::BTreeSet<&str> = value_of(args, "--allowedTools")
        .expect("an allow-list")
        .split(',')
        .collect();
    let expected: std::collections::BTreeSet<&str> = PICKS_MCP_TOOLS
        .iter()
        .copied()
        .chain(["ToolSearch"])
        .collect();
    assert_eq!(
        allowed, expected,
        "the three picks tools plus ToolSearch: {args:?}"
    );
    assert_eq!(
        value_of(args, "--permission-mode"),
        Some("dontAsk"),
        "{args:?}"
    );
    assert!(has(args, "--strict-mcp-config"), "{args:?}");
    assert!(!has(args, "--dangerously-skip-permissions"), "{args:?}");
    let budget: f64 = value_of(args, "--max-budget-usd")
        .expect("a spend cap")
        .parse()
        .expect("a number");
    assert!((budget - PICKS_MAX_BUDGET_USD).abs() < 1e-9, "{budget}");
}

// ── the argument vector ───────────────────────────────────────────────────────

#[test]
fn a_restricted_session_runs_without_the_permission_bypass_and_denies_what_is_not_allowed() {
    let r = restrictions();

    let args = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-1",
        false,
        Some(&r),
        &guard_settings(),
    );

    assert!(!has(&args, "--dangerously-skip-permissions"), "{args:?}");
    assert_eq!(
        value_of(&args, "--permission-mode"),
        Some("dontAsk"),
        "{args:?}"
    );
    assert!(
        has(&args, "--strict-mcp-config"),
        "only the daemon's own MCP server may load: {args:?}"
    );
}

#[test]
fn the_picks_session_is_built_with_no_agent_only_project_settings_and_the_closed_tool_list() {
    // Exactly as production builds it: an empty agent name and the picks restrictions.
    let args = build_claude_args_with(
        "",
        "Teri picks",
        false,
        "sid-1",
        false,
        Some(&picks_restrictions()),
        &guard_settings(),
    );

    assert_is_the_picks_session_vector(&args);
    assert_eq!(value_of(&args, "-n"), Some("Teri picks"));
    assert_eq!(value_of(&args, "--session-id"), Some("sid-1"));
    assert_eq!(value_of(&args, "--input-format"), Some("stream-json"));
    assert_eq!(value_of(&args, "--output-format"), Some("stream-json"));
}

#[test]
fn every_restricted_session_loads_only_project_settings_and_no_slash_commands() {
    for agent in ["", "teri:teri", "some-agent"] {
        let args = build_claude_args_with(
            agent,
            "View",
            false,
            "sid-1",
            false,
            Some(&restrictions()),
            &guard_settings(),
        );

        assert_eq!(
            value_of(&args, "--setting-sources"),
            Some("project"),
            "agent {agent:?}: {args:?}"
        );
        assert!(
            has(&args, "--disable-slash-commands"),
            "agent {agent:?}: {args:?}"
        );
    }
}

#[test]
fn an_empty_agent_name_means_no_agent_flag_and_a_real_name_still_gets_one() {
    for restricted in [None, Some(restrictions())] {
        let none = build_claude_args_with(
            "",
            "View",
            false,
            "sid-1",
            false,
            restricted.as_ref(),
            &guard_settings(),
        );
        assert!(
            !has(&none, "--agent"),
            "restricted: {}: {none:?}",
            restricted.is_some()
        );
        assert!(
            !none.iter().any(|a| a.is_empty()),
            "no empty argument is passed either: {none:?}"
        );

        let named = build_claude_args_with(
            "cody",
            "View",
            false,
            "sid-1",
            false,
            restricted.as_ref(),
            &guard_settings(),
        );
        assert_eq!(
            value_of(&named, "--agent"),
            Some("cody"),
            "restricted: {}: {named:?}",
            restricted.is_some()
        );
    }
}

#[test]
fn a_restricted_session_gets_exactly_the_listed_builtin_and_allowed_tools_and_the_budget() {
    let r = restrictions();

    let args = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-1",
        false,
        Some(&r),
        &guard_settings(),
    );

    assert_eq!(
        value_of(&args, "--tools"),
        Some("ToolSearch,Read"),
        "{args:?}"
    );
    assert_eq!(
        value_of(&args, "--allowedTools"),
        Some("mcp__nostromo__a,mcp__nostromo__b,ToolSearch"),
        "{args:?}"
    );
    let budget: f64 = value_of(&args, "--max-budget-usd")
        .expect("a spend cap")
        .parse()
        .expect("a number");
    assert!((budget - 1.5).abs() < 1e-9, "{budget}");
}

#[test]
fn without_a_budget_there_is_no_spend_flag() {
    let r = SessionRestrictions {
        max_budget_usd: None,
        ..restrictions()
    };

    let args = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-1",
        false,
        Some(&r),
        &guard_settings(),
    );

    assert!(!has(&args, "--max-budget-usd"), "{args:?}");
}

#[test]
fn a_restricted_session_keeps_the_agent_view_and_session_id_arguments() {
    let r = restrictions();

    let fresh = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-9",
        false,
        Some(&r),
        &guard_settings(),
    );
    assert_eq!(value_of(&fresh, "--agent"), Some("teri:teri"));
    assert_eq!(value_of(&fresh, "-n"), Some("Teri picks"));
    assert_eq!(value_of(&fresh, "--session-id"), Some("sid-9"));
    assert!(!has(&fresh, "--resume"));
    assert_eq!(value_of(&fresh, "--input-format"), Some("stream-json"));
    assert_eq!(value_of(&fresh, "--output-format"), Some("stream-json"));

    let resumed = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-9",
        true,
        Some(&r),
        &guard_settings(),
    );
    assert_eq!(value_of(&resumed, "--resume"), Some("sid-9"));
}

#[test]
fn an_unrestricted_session_is_exactly_what_it_was_before() {
    let g = guard_settings();
    let plain = build_claude_args("cody", "Cody view", true, "sid-2", true, &g);

    assert_eq!(
        plain,
        build_claude_args_with("cody", "Cody view", true, "sid-2", true, None, &g)
    );
    assert!(has(&plain, "--dangerously-skip-permissions"), "{plain:?}");
    assert_eq!(
        position_of_pair(&plain, "--settings", &g),
        Some(1),
        "the guard hook comes right after the permission bypass: {plain:?}"
    );
    // T-AP0g-6: take the two guard elements away and it is the vector from before the guard.
    assert_eq!(
        without_the_guard(&plain, &g),
        strings(&[
            "--dangerously-skip-permissions",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--replay-user-messages",
            "--agent",
            "cody",
            "-n",
            "Cody view",
            "--remote-control",
            "Cody view",
            "--resume",
            "sid-2",
        ]),
        "nothing but the guard changed for an ordinary session"
    );
    for flag in [
        "--permission-mode",
        "--tools",
        "--allowedTools",
        "--strict-mcp-config",
        "--max-budget-usd",
        "--setting-sources",
        "--disable-slash-commands",
    ] {
        assert!(
            !has(&plain, flag),
            "{flag} must not appear on an ordinary session: {plain:?}"
        );
    }
}

#[test]
fn a_restricted_session_is_exactly_what_it_was_before_plus_the_guard_hook() {
    let g = guard_settings();
    let r = restrictions();

    let args = build_claude_args_with(
        "teri:teri",
        "Teri picks",
        false,
        "sid-1",
        false,
        Some(&r),
        &g,
    );

    assert_eq!(
        position_of_pair(&args, "--permission-mode", "dontAsk")
            .map(|at| (args[at + 2].as_str(), args[at + 3].as_str())),
        Some(("--settings", g.as_str())),
        "the guard hook comes right after `--permission-mode dontAsk`: {args:?}"
    );
    // T-AP0g-6: take the two guard elements away and it is the vector from before the guard.
    assert_eq!(
        without_the_guard(&args, &g),
        strings(&[
            "--permission-mode",
            "dontAsk",
            "--tools",
            "ToolSearch,Read",
            "--allowedTools",
            "mcp__nostromo__a,mcp__nostromo__b,ToolSearch",
            "--strict-mcp-config",
            "--setting-sources",
            "project",
            "--disable-slash-commands",
            "--max-budget-usd",
            "1.5",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--replay-user-messages",
            "--agent",
            "teri:teri",
            "-n",
            "Teri picks",
            "--session-id",
            "sid-1",
        ]),
        "nothing but the guard changed for a restricted session"
    );
}

#[test]
fn restricted_and_unrestricted_sessions_carry_the_identical_guard_settings() {
    let g = guard_settings();
    let unrestricted = build_claude_args_with("cody", "V", false, "sid", false, None, &g);
    let restricted =
        build_claude_args_with("cody", "V", false, "sid", false, Some(&restrictions()), &g);

    let guard_of = |args: &[String]| value_of(args, "--settings").map(str::to_owned);
    assert_eq!(guard_of(&unrestricted).as_deref(), Some(g.as_str()));
    assert_eq!(guard_of(&restricted), guard_of(&unrestricted));
}

#[test]
fn the_picks_session_is_restricted_to_the_three_picks_tools_and_a_small_budget() {
    let r = picks_restrictions();

    assert_eq!(
        r.builtin_tools,
        PICKS_BUILTIN_TOOLS
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
    );
    let mut expected: Vec<String> = PICKS_MCP_TOOLS.iter().map(|s| s.to_string()).collect();
    expected.extend(PICKS_BUILTIN_TOOLS.iter().map(|s| s.to_string()));
    let mut allowed = r.allowed_tools.clone();
    allowed.sort();
    expected.sort();
    assert_eq!(
        allowed, expected,
        "the allow-list is the three picks tools plus the built-in tool search"
    );
    assert_eq!(PICKS_MCP_TOOLS.len(), 3);
    assert!(
        PICKS_MCP_TOOLS
            .iter()
            .all(|t| t.starts_with("mcp__nostromo__teri_")),
        "{PICKS_MCP_TOOLS:?}"
    );
    for forbidden in ["Bash", "Write", "Edit", "Agent", "WebFetch", "WebSearch"] {
        assert!(
            !r.builtin_tools.iter().any(|t| t == forbidden),
            "{forbidden} must not be available"
        );
        assert!(
            !r.allowed_tools.iter().any(|t| t == forbidden),
            "{forbidden} must not be pre-approved"
        );
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
        let dir = std::env::temp_dir().join(format!(
            "nostromo-session-restrictions-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(
            &script,
            FAKE_CLAUDE.replace("@LOGDIR@", dir.to_str().expect("utf8 temp dir")),
        )
        .unwrap();
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

/// A manager that stops every fake claude it started when it goes out of scope, a failed
/// assertion included (a fake still holding its stdin open would keep the test run from ending).
struct Mgr(SessionManager);

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

fn manager() -> (Mgr, tempfile::TempDir) {
    install_fake_claude();
    let dir = tempfile::tempdir().unwrap();
    (
        Mgr(SessionManager::with_store_path(
            dir.path().join("daemon-sessions.json"),
        )),
        dir,
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tag_can_be_reserved_for_restricted_sessions_and_says_which_restrictions() {
    let (mut mgr, _dir) = manager();
    assert_eq!(mgr.restrictions_for("reserved-tag"), None);

    mgr.restrict_tag("reserved-tag", picks_restrictions());

    assert_eq!(
        mgr.restrictions_for("reserved-tag"),
        Some(&picks_restrictions())
    );
    assert_eq!(
        mgr.restrictions_for("some-other-tag"),
        None,
        "only the named tag is restricted"
    );
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

    // The way the picks host starts it: no agent name.
    mgr.spawn_session(
        PICKS_TAG.into(),
        String::new(),
        view.into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    let runs = runs_of(view, 1).await;
    let args = &runs[0];
    assert_is_the_picks_session_vector(args);
    assert!(!has(args, "--dangerously-skip-permissions"), "{args:?}");
    assert_eq!(
        value_of(args, "--permission-mode"),
        Some("dontAsk"),
        "{args:?}"
    );
    assert!(has(args, "--strict-mcp-config"), "{args:?}");
    let r = picks_restrictions();
    assert_eq!(
        value_of(args, "--tools"),
        Some(r.builtin_tools.join(",").as_str()),
        "{args:?}"
    );
    assert_eq!(
        value_of(args, "--allowedTools"),
        Some(r.allowed_tools.join(",").as_str()),
        "{args:?}"
    );
    assert!(value_of(args, "--max-budget-usd").is_some(), "{args:?}");
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restricted_tag_stays_restricted_when_its_session_is_started_again() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let view = "restricted-view-again";
    let spawn = |mgr: &mut Mgr| {
        mgr.spawn_session(
            PICKS_TAG.into(),
            String::new(),
            view.into(),
            Some(dir.path().to_path_buf()),
            None,
            false,
        )
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
        assert!(
            !has(args, "--dangerously-skip-permissions"),
            "run {n}: {args:?}"
        );
        assert_eq!(
            value_of(args, "--permission-mode"),
            Some("dontAsk"),
            "run {n}: {args:?}"
        );
        assert!(has(args, "--strict-mcp-config"), "run {n}: {args:?}");
        assert_is_the_picks_session_vector(args);
    }
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tag_nobody_restricted_keeps_the_permission_bypass() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let view = "unrestricted-view";

    mgr.spawn_session(
        "cody-plain".into(),
        "cody".into(),
        view.into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    let runs = runs_of(view, 1).await;
    assert!(
        has(&runs[0], "--dangerously-skip-permissions"),
        "{:?}",
        runs[0]
    );
    assert_eq!(
        value_of(&runs[0], "--agent"),
        Some("cody"),
        "a real agent name is still passed: {:?}",
        runs[0]
    );
    for flag in [
        "--permission-mode",
        "--tools",
        "--allowedTools",
        "--strict-mcp-config",
        "--max-budget-usd",
        "--setting-sources",
        "--disable-slash-commands",
    ] {
        assert!(!has(&runs[0], flag), "{flag}: {:?}", runs[0]);
    }
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restricted_session_with_a_real_agent_name_still_passes_it() {
    let (mut mgr, dir) = manager();
    mgr.restrict_tag("boxed-with-agent", restrictions());
    let view = "restricted-view-named-agent";

    mgr.spawn_session(
        "boxed-with-agent".into(),
        "some-agent".into(),
        view.into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    let runs = runs_of(view, 1).await;
    assert_eq!(
        value_of(&runs[0], "--agent"),
        Some("some-agent"),
        "{:?}",
        runs[0]
    );
    mgr.kill_all_on_shutdown();
}

// ── sensitivity does not depend on the agent name ─────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_restricted_picks_tag_is_sensitive_even_when_it_runs_with_no_agent() {
    // The picks session reads third-party work data, so a network peer must not see or drive it,
    // whatever agent (here none) it is started as.
    let (mut mgr, dir) = manager();
    let tags = mgr.sensitive_tags();

    mgr.spawn_session(
        PICKS_TAG.into(),
        String::new(),
        "sensitive-picks-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    assert!(tags.tag_is_sensitive(PICKS_TAG));
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn any_tag_that_was_restricted_is_sensitive_once_started() {
    let (mut mgr, dir) = manager();
    let tags = mgr.sensitive_tags();
    mgr.restrict_tag("boxed-other", restrictions());

    mgr.spawn_session(
        "boxed-other".into(),
        String::new(),
        "sensitive-other-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    assert!(tags.tag_is_sensitive("boxed-other"));
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unrestricted_tag_is_not_made_sensitive_by_having_an_empty_or_ordinary_agent_name() {
    let (mut mgr, dir) = manager();
    let tags = mgr.sensitive_tags();

    mgr.spawn_session(
        "plain-no-agent".into(),
        String::new(),
        "plain-no-agent-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");
    mgr.spawn_session(
        "plain-cody".into(),
        "cody".into(),
        "plain-cody-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the session starts");

    assert!(!tags.tag_is_sensitive("plain-no-agent"));
    assert!(!tags.tag_is_sensitive("plain-cody"));
    mgr.kill_all_on_shutdown();
}

// ── the production-shell guard (AP0g) ─────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_manager_runs_the_guard_binary_named_by_the_environment_or_one_that_fails_closed() {
    // Never a binary found beside the test executable. (No env is mutated here: either answer is fine.)
    let (mgr, _dir) = manager();
    let from_env = std::env::var_os(nostromo::approvals::guard::GUARD_BIN_ENV)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);

    let expected =
        from_env.unwrap_or_else(|| PathBuf::from(nostromo::approvals::guard::GUARD_SENTINEL_PATH));
    assert_eq!(mgr.guard_path(), expected);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_counts_as_guarded_only_with_this_managers_exact_guard_hook() {
    let (mut mgr, _dir) = manager();
    mgr.set_guard_path(PathBuf::from("/opt/x/nostromo-guard"));
    assert_eq!(mgr.guard_path(), Path::new("/opt/x/nostromo-guard"));
    let g = hook_settings_json(mgr.guard_path());

    let unrestricted = build_claude_args("cody", "V", false, "sid", false, &g);
    let restricted =
        build_claude_args_with("cody", "V", false, "sid", false, Some(&restrictions()), &g);
    assert!(mgr.session_has_guard(&unrestricted), "{unrestricted:?}");
    assert!(mgr.session_has_guard(&restricted), "{restricted:?}");

    // No hook at all.
    assert!(!mgr.session_has_guard(&without_the_guard(&unrestricted, &g)));
    assert!(!mgr.session_has_guard(&[]));
    // A hook for some other binary.
    let other = hook_settings_json(Path::new("/opt/y/nostromo-guard"));
    assert!(!mgr.session_has_guard(&build_claude_args("cody", "V", false, "sid", false, &other)));
    // A tampered hook: hooks switched off, or the JSON merely not byte-identical.
    let off = g.replace(r#""disableAllHooks":false"#, r#""disableAllHooks":true"#);
    assert_ne!(off, g);
    assert!(!mgr.session_has_guard(&build_claude_args("cody", "V", false, "sid", false, &off)));
    assert!(!mgr.session_has_guard(&build_claude_args(
        "cody",
        "V",
        false,
        "sid",
        false,
        &format!("{g} ")
    )));
    // The JSON in some other position does not count: it must be the value of `--settings`.
    assert!(!mgr.session_has_guard(&strings(&["-n", &g, "--session-id", "sid"])));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_session_the_manager_starts_gets_the_guard_hook_right_after_its_permission_flag() {
    let (mut mgr, dir) = manager();
    mgr.set_guard_path(PathBuf::from("/opt/x/nostromo-guard"));
    mgr.restrict_tag(PICKS_TAG, picks_restrictions());
    let g = hook_settings_json(mgr.guard_path());

    mgr.spawn_session(
        PICKS_TAG.into(),
        String::new(),
        "guard-restricted-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the restricted session starts");
    mgr.spawn_session(
        "guard-plain".into(),
        "cody".into(),
        "guard-unrestricted-view".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("the unrestricted session starts");

    let restricted = &runs_of("guard-restricted-view", 1).await[0];
    let at = position_of_pair(restricted, "--permission-mode", "dontAsk").expect("dontAsk");
    assert_eq!(
        &restricted[at + 2..at + 4],
        [String::from("--settings"), g.clone()],
        "{restricted:?}"
    );
    assert!(mgr.session_has_guard(restricted), "{restricted:?}");

    let plain = &runs_of("guard-unrestricted-view", 1).await[0];
    let at = position_of_pair(plain, "--dangerously-skip-permissions", "--settings")
        .expect("--settings follows the bypass");
    assert_eq!(plain[at + 1], "--settings");
    assert_eq!(plain[at + 2], g, "{plain:?}");
    assert!(mgr.session_has_guard(plain), "{plain:?}");
    mgr.kill_all_on_shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_started_after_the_guard_path_changes_runs_the_new_guard() {
    let (mut mgr, dir) = manager();
    mgr.set_guard_path(PathBuf::from("/opt/x/nostromo-guard"));
    mgr.spawn_session(
        "guard-moved-a".into(),
        "cody".into(),
        "guard-moved-view-a".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("starts");

    mgr.set_guard_path(PathBuf::from("/opt/z/nostromo-guard"));
    mgr.spawn_session(
        "guard-moved-b".into(),
        "cody".into(),
        "guard-moved-view-b".into(),
        Some(dir.path().to_path_buf()),
        None,
        false,
    )
    .expect("starts");

    let first = &runs_of("guard-moved-view-a", 1).await[0];
    let second = &runs_of("guard-moved-view-b", 1).await[0];
    assert_eq!(
        value_of(first, "--settings"),
        Some(hook_settings_json(Path::new("/opt/x/nostromo-guard")).as_str())
    );
    assert_eq!(
        value_of(second, "--settings"),
        Some(hook_settings_json(Path::new("/opt/z/nostromo-guard")).as_str())
    );
    mgr.kill_all_on_shutdown();
}
