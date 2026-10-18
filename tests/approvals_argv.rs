//! Which sessions are told to send their permission prompts to the daemon, as
//! the real argument builder (`build_claude_args_with`) says it, for every arm
//! (new, resumed, remote-control, restricted).
//!
//! The rule (AP0a PRD 1): an unrestricted session that is not `--remote-control`
//! gets `--permission-prompt-tool stdio` right after the guard `--settings`,
//! whether it is new or resumed; every other session's arguments never carry it.
//! These assert on the builder's own output, not against a copy of its logic, so
//! a refactor that drops the flag from one arm (the resume arm especially) fails here.

use nostromo::ipc::session_manager::{build_claude_args_with, SessionRestrictions};

const GUARD: &str = "{\"hooks\":\"guard-settings-under-test\"}";

fn restrictions() -> SessionRestrictions {
    SessionRestrictions {
        builtin_tools: vec!["Read".into(), "Grep".into()],
        allowed_tools: vec!["Read".into()],
        max_budget_usd: Some(2.0),
    }
}

fn prompt_flag_positions(argv: &[String]) -> Vec<usize> {
    argv.iter()
        .enumerate()
        .filter(|(_, a)| *a == "--permission-prompt-tool")
        .map(|(i, _)| i)
        .collect()
}

#[track_caller]
fn assert_guard_settings_present(argv: &[String]) {
    let at = argv
        .iter()
        .position(|a| a == "--settings")
        .unwrap_or_else(|| panic!("the guard's --settings is always passed: {argv:?}"));
    assert_eq!(argv[at + 1], GUARD, "{argv:?}");
}

#[test]
fn an_unrestricted_session_gets_the_prompt_flag_right_after_the_guard_settings_new_or_resumed() {
    for resume in [false, true] {
        for agent in ["cody", ""] {
            let argv = build_claude_args_with(agent, "view", false, "sid-1", resume, None, GUARD);

            let flags = prompt_flag_positions(&argv);
            assert_eq!(flags.len(), 1, "resume={resume} agent={agent:?}: {argv:?}");
            let at = argv.iter().position(|a| a == "--settings").unwrap();
            assert_eq!(argv[at + 1], GUARD, "{argv:?}");
            assert_eq!(
                (argv[at + 2].as_str(), argv[at + 3].as_str()),
                ("--permission-prompt-tool", "stdio"),
                "resume={resume}: the flag and its value come right after the guard settings: {argv:?}"
            );
            assert_eq!(flags[0], at + 2, "{argv:?}");
            assert!(
                argv.iter().any(|a| a == "--dangerously-skip-permissions"),
                "the bypass is still there: {argv:?}"
            );
            if resume {
                let r = argv.iter().position(|a| a == "--resume").expect("--resume");
                assert_eq!(argv[r + 1], "sid-1", "{argv:?}");
                assert!(!argv.iter().any(|a| a == "--session-id"), "{argv:?}");
            } else {
                let s = argv
                    .iter()
                    .position(|a| a == "--session-id")
                    .expect("--session-id");
                assert_eq!(argv[s + 1], "sid-1", "{argv:?}");
                assert!(!argv.iter().any(|a| a == "--resume"), "{argv:?}");
            }
        }
    }
}

#[test]
fn the_resume_arm_carries_exactly_what_the_new_session_arm_does_besides_the_session_flag() {
    let fresh = build_claude_args_with("cody", "view", false, "sid-1", false, None, GUARD);
    let resumed = build_claude_args_with("cody", "view", false, "sid-1", true, None, GUARD);

    let without_session_flag = |argv: &[String], flag: &str| -> Vec<String> {
        let at = argv.iter().position(|a| a == flag).unwrap();
        let mut rest = argv.to_vec();
        rest.drain(at..=at + 1);
        rest
    };
    assert_eq!(
        without_session_flag(&fresh, "--session-id"),
        without_session_flag(&resumed, "--resume"),
        "the only difference between a new and a resumed session is how the id is passed"
    );
}

#[test]
fn a_remote_control_session_never_gets_the_prompt_flag_new_or_resumed() {
    for resume in [false, true] {
        let argv = build_claude_args_with("cody", "view", true, "sid-1", resume, None, GUARD);

        assert!(prompt_flag_positions(&argv).is_empty(), "{argv:?}");
        assert!(!argv.iter().any(|a| a == "stdio"), "{argv:?}");
        assert!(argv.iter().any(|a| a == "--remote-control"), "{argv:?}");
        assert_guard_settings_present(&argv);
    }
}

#[test]
fn a_restricted_session_never_gets_the_prompt_flag_in_any_arm() {
    for resume in [false, true] {
        for remote_control in [false, true] {
            for agent in ["teri:teri", ""] {
                for r in [
                    restrictions(),
                    SessionRestrictions {
                        max_budget_usd: None,
                        ..restrictions()
                    },
                ] {
                    let argv = build_claude_args_with(
                        agent,
                        "view",
                        remote_control,
                        "sid-1",
                        resume,
                        Some(&r),
                        GUARD,
                    );
                    let arm = format!("resume={resume} remote={remote_control} agent={agent:?}");

                    assert!(
                        prompt_flag_positions(&argv).is_empty(),
                        "{arm}: a restricted session is never asked to send prompts to the daemon: {argv:?}"
                    );
                    assert!(
                        !argv.iter().any(|a| a == "stdio"),
                        "{arm}: nothing else smuggles it in: {argv:?}"
                    );
                    assert!(
                        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
                        "{arm}: a restricted session has no bypass: {argv:?}"
                    );
                    let mode = argv.iter().position(|a| a == "--permission-mode").expect(&arm);
                    assert_eq!(argv[mode + 1], "dontAsk", "{arm}: {argv:?}");
                    assert_guard_settings_present(&argv);
                }
            }
        }
    }
}
