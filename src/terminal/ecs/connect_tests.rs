//! The pure parts of connecting an ECS shell, from the outside: the argv that
//! is run, what each AWS CLI failure and each ending means, what the output
//! watch notices, and where the AWS CLI is looked for. Nothing here starts a
//! process or touches AWS; the end-to-end behaviour is in
//! `tests/ecs_connect.rs`.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::aws::{AwsCli, AwsCliSource, AwsRunError};
use super::classify::{
    classify_close, classify_connect_failure, classify_helper_failure, execute_command_argv,
    execute_command_env,
};
use super::vocab::EcsTarget;
use super::watch::{ConnectEvent, RemoteWatch};
use crate::config::TerminalConfig;
use crate::terminal::launcher::ConnectFailure;

const STARTED: &str = "Starting session with SessionId";
const EXITING: &str = "Exiting session with sessionId";

fn target(shell_command: &str) -> EcsTarget {
    EcsTarget {
        project: "admin-portal".into(),
        environment: "production".into(),
        service: "scheduler".into(),
        shell_type: "shell".into(),
        cluster: "fake-prod-ecs".into(),
        service_name: "production-fake-ap-scheduler".into(),
        container: "main".into(),
        region: "us-east-2".into(),
        profile: Some("fake-prod-profile".into()),
        sso_session: "carefeed".into(),
        shell_command: shell_command.into(),
    }
}

fn cli_at(exe: &str) -> AwsCli {
    AwsCli::at(PathBuf::from(exe))
}

fn argv(cli: &AwsCli, shell_command: &str) -> Vec<String> {
    execute_command_argv(
        cli,
        &target(shell_command),
        "fake-prod-profile",
        "arn:task/1",
    )
}

// ═════════════════════════════════════════════════════════════════════════════
// T6: the argv of the shell
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn the_shell_is_started_with_exactly_this_argv_whose_first_element_is_the_resolved_aws() {
    let cli = cli_at("/opt/test-bin/aws");

    let argv = argv(&cli, "/bin/bash");

    assert_eq!(
        argv,
        [
            "/opt/test-bin/aws",
            "ecs",
            "execute-command",
            "--profile",
            "fake-prod-profile",
            "--region",
            "us-east-2",
            "--cluster",
            "fake-prod-ecs",
            "--task",
            "arn:task/1",
            "--container",
            "main",
            "--interactive",
            "--command",
            "/bin/bash"
        ]
    );
}

#[test]
fn a_shell_command_with_spaces_is_one_element_and_nothing_follows_it() {
    let cli = cli_at("/opt/test-bin/aws");

    let argv = argv(&cli, "php artisan tinker");

    let at = argv.iter().position(|a| a == "--command").unwrap();
    assert_eq!(argv[at + 1], "php artisan tinker");
    assert_eq!(at + 2, argv.len(), "{argv:?}");
}

#[test]
fn no_element_is_a_shell_or_a_shell_flag_apart_from_the_command_value() {
    let cli = cli_at("/opt/test-bin/aws");
    for command in ["/bin/bash", "/bin/sh", "php artisan tinker"] {
        let argv = argv(&cli, command);
        let at = argv.iter().position(|a| a == "--command").unwrap();
        for (i, element) in argv.iter().enumerate() {
            if i == at + 1 {
                continue;
            }
            assert!(
                ![
                    "sh",
                    "bash",
                    "-c",
                    "eval",
                    "/bin/sh",
                    "/bin/bash",
                    "zsh",
                    "-lc"
                ]
                .contains(&element.as_str()),
                "{element:?} in {argv:?}"
            );
        }
    }
}

#[test]
fn values_with_spaces_or_shell_syntax_stay_single_arguments() {
    let cli = cli_at("/opt/with space/bin/aws");
    let mut t = target("/bin/bash");
    t.cluster = "cluster; rm -rf /".into();
    t.container = "$(touch /tmp/pwned)".into();

    let argv = execute_command_argv(&cli, &t, "profile with space", "arn:task/`id`");

    assert_eq!(argv.len(), 16, "{argv:?}");
    assert_eq!(argv[0], "/opt/with space/bin/aws");
    assert_eq!(argv[4], "profile with space");
    assert_eq!(argv[8], "cluster; rm -rf /");
    assert_eq!(argv[10], "arn:task/`id`");
    assert_eq!(argv[12], "$(touch /tmp/pwned)");
}

#[test]
fn the_shell_runs_with_the_clis_path_an_empty_pager_and_an_xterm_terminal_type() {
    let cli = cli_at("/opt/test-bin/aws");

    let env: std::collections::HashMap<String, String> =
        execute_command_env(&cli).into_iter().collect();

    assert_eq!(
        env["PATH"],
        "/opt/test-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    );
    assert_eq!(env["AWS_PAGER"], "");
    assert_eq!(env["TERM"], "xterm-256color");
}

// ═════════════════════════════════════════════════════════════════════════════
// Where the AWS CLI is
// ═════════════════════════════════════════════════════════════════════════════

fn executable(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn config_naming(path: &Path) -> TerminalConfig {
    TerminalConfig {
        aws_cli: Some(path.to_path_buf()),
        ..TerminalConfig::default()
    }
}

#[test]
fn an_explicit_cli_resolves_to_itself_with_its_directory_first_on_the_path() {
    let dir = TempDir::new().unwrap();
    let aws = executable(dir.path(), "aws");

    let cli = AwsCliSource::only(&aws).resolve().expect("resolves");

    assert_eq!(cli.exe, aws);
    assert_eq!(
        cli.child_path,
        format!(
            "{}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            dir.path().display()
        )
    );
}

#[test]
fn an_explicit_cli_that_is_not_there_has_no_fallback_and_says_how_to_install_it() {
    let dir = TempDir::new().unwrap();

    let err = AwsCliSource::only(dir.path().join("nowhere").join("aws"))
        .resolve()
        .expect_err("nothing is there");

    assert_eq!(err.reason_code, "aws_cli_missing");
    assert_eq!(
        err.remedy.as_deref(),
        Some("Install the AWS CLI: brew install awscli")
    );
}

#[test]
fn a_file_that_is_not_executable_a_directory_and_a_relative_path_are_not_a_cli() {
    let dir = TempDir::new().unwrap();
    let plain = dir.path().join("aws-plain");
    std::fs::write(&plain, "not a program").unwrap();
    std::fs::set_permissions(&plain, std::fs::Permissions::from_mode(0o644)).unwrap();
    let directory = dir.path().join("aws-dir");
    std::fs::create_dir(&directory).unwrap();

    for candidate in [plain, directory, PathBuf::from("aws")] {
        let err = AwsCliSource::only(&candidate)
            .resolve()
            .expect_err(&format!("{} is not a CLI", candidate.display()));
        assert_eq!(
            err.reason_code,
            "aws_cli_missing",
            "{}",
            candidate.display()
        );
    }
}

/// The environment variable's value is passed in, so nothing here touches the
/// process environment (tests run in parallel).
#[test]
fn the_cli_is_the_configured_one_then_the_one_in_the_environment() {
    let dir = TempDir::new().unwrap();
    let configured = executable(dir.path(), "configured-aws");
    let from_env = executable(dir.path(), "env-aws");
    let missing = dir.path().join("missing-aws");
    let resolve = |cfg: &TerminalConfig, env: &Path| {
        AwsCliSource::from_config_and_env(cfg, Some(env.into())).resolve()
    };

    let both = resolve(&config_naming(&configured), &from_env);
    let only_env = resolve(&TerminalConfig::default(), &from_env);
    let config_missing = resolve(&config_naming(&missing), &from_env);
    let env_missing_config_good = resolve(
        &config_naming(&configured),
        &dir.path().join("also-missing"),
    );

    assert_eq!(both.expect("config and env both exist").exe, configured);
    assert_eq!(only_env.expect("the environment names one").exe, from_env);
    assert_eq!(
        config_missing
            .expect("a config path that is not there falls through")
            .exe,
        from_env
    );
    assert_eq!(
        env_missing_config_good
            .expect("the config path still wins")
            .exe,
        configured
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Why a helper call failed (before any shell starts)
// ═════════════════════════════════════════════════════════════════════════════

fn failed(stderr: &str) -> AwsRunError {
    AwsRunError::Failed {
        stderr: stderr.into(),
    }
}

fn reason_of(failure: &ConnectFailure) -> &str {
    &failure.reason_code
}

#[test]
fn every_expired_session_message_is_sso_expired_with_the_login_command_for_the_users_session() {
    for stderr in [
        "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired",
        "Error loading SSO Token: Token has expired and refresh failed",
        "An error occurred (UnauthorizedSSOToken) when calling the GetRoleCredentials operation",
        "The SSO session associated with this profile has expired or is otherwise invalid.",
    ] {
        let f = classify_helper_failure(&failed(stderr), "my-sso");

        assert_eq!(reason_of(&f), "sso_expired", "{stderr}");
        assert!(
            f.remedy
                .as_deref()
                .is_some_and(|r| r.contains("aws sso login --sso-session my-sso")),
            "{stderr}: {:?}",
            f.remedy
        );
    }
}

#[test]
fn a_profile_the_cli_cannot_find_is_profile_not_configured_with_the_ecs_setup_remedy() {
    for stderr in [
        "The config profile (fake-prod-profile) could not be found",
        "Missing profile fake-prod-profile",
    ] {
        let f = classify_helper_failure(&failed(stderr), "carefeed");

        assert_eq!(reason_of(&f), "profile_not_configured", "{stderr}");
        assert_eq!(
            f.remedy.as_deref(),
            Some(
                "Create ~/.claude/ecs-local.json with your AWS profiles (run ecs_setup in a shell)"
            )
        );
    }
}

#[test]
fn any_other_failure_is_aws_error_quoting_only_the_first_stderr_line() {
    let f = classify_helper_failure(
        &failed(
            "\n  \nAn error occurred (ThrottlingException): Rate exceeded\nsecond-line-of-noise\n",
        ),
        "carefeed",
    );

    assert_eq!(reason_of(&f), "aws_error");
    assert!(f.message.contains("ThrottlingException"), "{}", f.message);
    assert!(!f.message.contains("second-line-of-noise"), "{}", f.message);
}

#[test]
fn a_helper_that_timed_out_could_not_start_or_answered_nonsense_is_aws_error() {
    for error in [
        AwsRunError::Timeout,
        AwsRunError::Spawn("No such file".into()),
        AwsRunError::BadOutput("expected value".into()),
    ] {
        let f = classify_helper_failure(&error, "carefeed");

        assert_eq!(reason_of(&f), "aws_error", "{error:?}");
        assert!(!f.message.is_empty());
    }
}

#[test]
fn an_unreadable_error_line_is_quoted_without_control_characters_or_any_great_length() {
    let noisy = format!("\u{1b}[31mbad\u{1b}[0m\r\u{7}thing {}", "y".repeat(5000));

    let f = classify_helper_failure(&failed(&noisy), "carefeed");

    assert_eq!(reason_of(&f), "aws_error");
    assert!(f.message.contains("badthing"), "{}", f.message);
    assert!(!f.message.chars().any(char::is_control), "{:?}", f.message);
    assert!(
        f.message.chars().count() < 400,
        "{}",
        f.message.chars().count()
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Why a connect failed (the shell started, then ended before a session)
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_missing_session_manager_plugin_is_named_with_the_install_command() {
    let f = classify_connect_failure(
        "\nSessionManagerPlugin is not found. Please refer to SessionManager Documentation here: http://docs.aws.amazon.com/console/systems-manager/session-manager-plugin-not-found\n",
        "carefeed",
    );

    assert_eq!(reason_of(&f), "session_manager_plugin_missing");
    assert!(
        f.remedy
            .as_deref()
            .is_some_and(|r| r.contains("brew install --cask session-manager-plugin")),
        "{:?}",
        f.remedy
    );
}

#[test]
fn an_expired_session_while_connecting_is_sso_expired_naming_the_users_session() {
    let f = classify_connect_failure(
        "An error occurred (ExpiredToken) when calling the ExecuteCommand operation",
        "work-sso",
    );

    assert_eq!(reason_of(&f), "sso_expired");
    assert!(f
        .remedy
        .as_deref()
        .is_some_and(|r| r.contains("aws sso login --sso-session work-sso")));
}

#[test]
fn a_task_that_is_not_ready_for_exec_is_target_not_connected() {
    let f = classify_connect_failure(
        "An error occurred (TargetNotConnectedException) when calling the ExecuteCommand operation: The execute command failed due to an internal error.",
        "carefeed",
    );

    assert_eq!(reason_of(&f), "target_not_connected");
    assert!(!f.message.is_empty());
}

#[test]
fn a_role_that_may_not_exec_is_access_denied() {
    let f = classify_connect_failure(
        "An error occurred (AccessDeniedException) when calling the ExecuteCommand operation: User is not authorized",
        "carefeed",
    );

    assert_eq!(reason_of(&f), "access_denied");
}

#[test]
fn anything_else_is_unknown_and_quotes_only_the_last_three_non_empty_lines() {
    let f = classify_connect_failure(
        "alpha-1\nbravo-2\n\ncharlie-3\n   \ndelta-4\n\n",
        "carefeed",
    );

    assert_eq!(reason_of(&f), "unknown");
    for kept in ["bravo-2", "charlie-3", "delta-4"] {
        assert!(f.message.contains(kept), "{}", f.message);
    }
    assert!(!f.message.contains("alpha-1"), "{}", f.message);
}

#[test]
fn the_quoted_lines_have_no_window_titles_and_no_text_reordering_characters() {
    let tail =
        "\u{1b}]0;pwned title\u{7}shown\nA\u{202E}B\u{200B}C\n\u{1b}]8;;http://x\u{1b}\\link\n";

    let f = classify_connect_failure(tail, "carefeed");

    assert_eq!(reason_of(&f), "unknown");
    assert!(!f.message.contains("pwned"), "{}", f.message);
    assert!(!f.message.contains("http://x"), "{}", f.message);
    for kept in ["shown", "ABC", "link"] {
        assert!(f.message.contains(kept), "{kept}: {}", f.message);
    }
}

#[test]
fn a_session_that_was_never_logged_in_is_an_expired_session() {
    for stderr in [
        "Error loading SSO Token: Token for fake-sso does not exist",
        "InvalidGrantException: refresh failed",
    ] {
        let f = classify_helper_failure(&failed(stderr), "carefeed");
        assert_eq!(reason_of(&f), "sso_expired", "{stderr}");
    }
}

#[test]
fn the_quoted_lines_have_no_escape_sequences_or_control_characters() {
    let tail = "FIRSTLINE\nsecond\n\u{1b}[31mred line\u{1b}[0m\r\nA\u{7}B\u{0}C\n\u{1b}[2K\n";

    let f = classify_connect_failure(tail, "carefeed");

    assert_eq!(reason_of(&f), "unknown");
    for kept in ["second", "red line", "ABC"] {
        assert!(f.message.contains(kept), "{:?}", f.message);
    }
    assert!(!f.message.contains("FIRSTLINE"), "{:?}", f.message);
    assert!(!f.message.contains("[31m"), "{:?}", f.message);
    assert!(!f.message.chars().any(char::is_control), "{:?}", f.message);
}

#[test]
fn a_very_long_line_is_clipped_not_dropped() {
    let f = classify_connect_failure(&format!("x{}", "x".repeat(10_000)), "carefeed");

    assert_eq!(reason_of(&f), "unknown");
    assert!(f.message.contains('x'));
    assert!(
        f.message.chars().count() < 400,
        "{}",
        f.message.chars().count()
    );
}

#[test]
fn a_connect_that_printed_nothing_is_still_unknown_with_a_message() {
    for tail in ["", "\n\n  \n", "\u{1b}[0m"] {
        let f = classify_connect_failure(tail, "carefeed");

        assert_eq!(reason_of(&f), "unknown", "{tail:?}");
        assert!(!f.message.is_empty());
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Why a running session ended
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_session_the_remote_side_ended_is_remote_exit() {
    assert_eq!(
        classify_close(
            &format!("\n\n{EXITING}: ecs-execute-command-0123.\n"),
            false
        ),
        "remote_exit"
    );
    assert_eq!(classify_close("", true), "remote_exit");
}

#[test]
fn the_remote_sides_goodbye_outranks_network_noise_after_it() {
    assert_eq!(
        classify_close(
            &format!("{EXITING}: x.\nread: connection reset by peer"),
            false
        ),
        "remote_exit"
    );
}

#[test]
fn an_expired_session_while_running_is_sso_expired() {
    assert_eq!(
        classify_close(
            "An error occurred (ExpiredToken) when calling the StartSession operation",
            false
        ),
        "sso_expired"
    );
}

#[test]
fn a_dropped_connection_is_network() {
    for tail in [
        "\nCannot perform start session: EOF\n",
        "read tcp 10.0.0.1:5000: connection reset by peer",
        "websocket: close 1006 (abnormal closure)",
    ] {
        assert_eq!(classify_close(tail, false), "network", "{tail}");
    }
}

#[test]
fn an_ending_with_nothing_to_explain_it_is_unknown() {
    assert_eq!(classify_close("", false), "unknown");
    assert_eq!(classify_close("bye\n", false), "unknown");
}

// ═════════════════════════════════════════════════════════════════════════════
// What the output watch notices
// ═════════════════════════════════════════════════════════════════════════════

fn connected_events(rx: &mut tokio::sync::mpsc::UnboundedReceiver<ConnectEvent>) -> usize {
    let mut n = 0;
    while let Ok(event) = rx.try_recv() {
        assert_eq!(event, ConnectEvent::Connected);
        n += 1;
    }
    n
}

#[test]
fn the_start_marker_tells_the_waiting_launcher_the_session_began() {
    let (watch, mut rx) = RemoteWatch::new("carefeed");
    assert!(!watch.connected());

    watch.observe(b"some banner\n");
    assert_eq!(connected_events(&mut rx), 0);
    assert!(!watch.connected());
    watch.observe(format!("\n{STARTED}: ecs-execute-command-0123\n").as_bytes());

    assert!(watch.connected());
    assert_eq!(connected_events(&mut rx), 1);
}

#[test]
fn a_start_marker_split_across_chunks_is_still_noticed_once() {
    let (watch, mut rx) = RemoteWatch::new("carefeed");

    watch.observe(b"Starting sess");
    assert_eq!(connected_events(&mut rx), 0);
    watch.observe(b"ion with SessionId: abc\n");
    watch.observe(format!("{STARTED} again\n").as_bytes());

    assert!(watch.connected());
    assert_eq!(connected_events(&mut rx), 1, "told once");
}

#[test]
fn a_start_marker_arriving_one_byte_at_a_time_is_noticed() {
    let (watch, mut rx) = RemoteWatch::new("carefeed");

    for byte in format!("xx{STARTED}: id\n").bytes() {
        watch.observe(&[byte]);
    }

    assert_eq!(connected_events(&mut rx), 1);
}

#[test]
fn a_start_marker_split_just_after_a_full_tail_of_older_output_is_noticed() {
    let (watch, mut rx) = RemoteWatch::new("carefeed");
    watch.observe(&vec![b'x'; 4090]);

    watch.observe(b"Starting sess");
    watch.observe(b"ion with SessionId: abc\n");

    assert_eq!(connected_events(&mut rx), 1);
}

#[test]
fn a_remote_exit_marker_split_across_chunks_is_remembered_for_the_close_reason() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"Exiting sess");
    watch.observe(b"ion with sessionId: abc.\n");

    assert_eq!(watch.take_close_reason(), "remote_exit");
}

#[test]
fn a_remote_exit_is_still_remembered_when_more_than_the_tail_followed_it() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(format!("{EXITING}: abc.\n").as_bytes());
    for _ in 0..10 {
        watch.observe(&vec![b'z'; 1024]);
    }

    assert_eq!(watch.take_close_reason(), "remote_exit");
}

#[test]
fn the_tail_keeps_what_the_last_four_kib_hold_and_classifies_a_connect_from_it() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"AccessDenied\n");
    watch.observe(&vec![b'x'; 4000]);

    assert_eq!(watch.take_connect_failure().reason_code, "access_denied");
}

#[test]
fn the_tail_is_bounded_so_older_output_than_four_kib_is_forgotten() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"TargetNotConnectedException\n");
    for _ in 0..5 {
        watch.observe(&vec![b'x'; 1000]);
    }

    assert_eq!(watch.take_connect_failure().reason_code, "unknown");
}

#[test]
fn the_tail_is_bounded_for_the_close_reason_too() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"Cannot perform start session: EOF\n");
    for _ in 0..5 {
        watch.observe(&vec![b'x'; 1000]);
    }

    assert_eq!(watch.take_close_reason(), "unknown");
}

#[test]
fn a_connect_failure_names_the_session_the_watch_was_made_for() {
    let (watch, _rx) = RemoteWatch::new("work-sso");
    watch.observe(b"An error occurred (ExpiredToken) when calling the ExecuteCommand operation\n");

    let f = watch.take_connect_failure();

    assert_eq!(f.reason_code, "sso_expired");
    assert!(f
        .remedy
        .as_deref()
        .is_some_and(|r| r.contains("--sso-session work-sso")));
}

#[test]
fn taking_the_connect_failure_drops_the_captured_text() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"AccessDenied: the-secret-bit\n");

    let first = watch.take_connect_failure();
    let second = watch.take_connect_failure();

    assert_eq!(first.reason_code, "access_denied");
    assert_eq!(second.reason_code, "unknown");
    assert!(
        !second.message.contains("the-secret-bit"),
        "{}",
        second.message
    );
}

#[test]
fn taking_the_close_reason_drops_the_captured_text() {
    let (watch, _rx) = RemoteWatch::new("carefeed");
    watch.observe(b"\nCannot perform start session: EOF\n");

    assert_eq!(watch.take_close_reason(), "network");
    assert_eq!(watch.take_close_reason(), "unknown");
}

#[test]
fn failing_the_watch_tells_the_waiting_launcher_why() {
    let (watch, mut rx) = RemoteWatch::new("carefeed");
    let failure = ConnectFailure {
        reason_code: "user_closed".into(),
        message: "closed".into(),
        remedy: None,
    };

    watch.fail(failure.clone());

    assert_eq!(rx.try_recv().unwrap(), ConnectEvent::Failed(failure));
}
