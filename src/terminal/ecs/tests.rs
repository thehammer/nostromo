//! The remote-shell vocabulary, from the outside: what resolves, what is
//! refused and what the refusal lists, against the fixture files in
//! `tests/fixtures/ecs/` (fake clusters and services). Tests that change the
//! data copy the fixtures into a temp dir first, and nothing reads the real
//! `~/.claude`.

use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::*;
use crate::config::TerminalConfig;

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ecs")
}

fn fixture_paths() -> EcsPaths {
    let dir = fixture_dir();
    EcsPaths::new(
        dir.join("config.json"),
        dir.join("ecs-local.json"),
        dir.join("ecs.sh"),
    )
}

fn vocab() -> EcsVocabulary {
    EcsVocabulary::load(&fixture_paths()).expect("the fixture vocabulary loads")
}

/// The fixtures copied into a temp dir, and paths to the copies.
struct Copy {
    dir: TempDir,
    paths: EcsPaths,
}

impl Copy {
    fn new() -> Copy {
        let dir = TempDir::new().expect("tempdir");
        for name in ["config.json", "ecs-local.json", "ecs.sh"] {
            std::fs::copy(fixture_dir().join(name), dir.path().join(name)).expect("copy fixture");
        }
        let paths = EcsPaths::new(
            dir.path().join("config.json"),
            dir.path().join("ecs-local.json"),
            dir.path().join("ecs.sh"),
        );
        Copy { dir, paths }
    }

    fn file(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn write(&self, name: &str, text: &str) {
        std::fs::write(self.file(name), text).expect("write");
    }

    fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.file(name)).expect("read")
    }

    fn load(&self) -> Result<EcsVocabulary, VocabError> {
        EcsVocabulary::load(&self.paths)
    }
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| s.to_string()).collect()
}

fn invalid(
    v: &EcsVocabulary,
    project: &str,
    env: &str,
    service: &str,
    shell: &str,
) -> InvalidTarget {
    v.resolve(project, env, service, shell)
        .expect_err("expected an invalid target")
}

fn four(t: &EcsTarget) -> (&str, &str, &str, &str) {
    (&t.project, &t.environment, &t.service, &t.shell_type)
}

// ── what resolves ────────────────────────────────────────────────────────────

#[test]
fn canonical_names_resolve_to_the_cluster_service_container_region_and_shell_command() {
    let t = vocab()
        .resolve("admin-portal", "production", "scheduler", "shell")
        .expect("canonical names resolve");

    assert_eq!(four(&t), ("admin-portal", "production", "scheduler", "shell"));
    assert_eq!(t.cluster, "fake-prod-ecs");
    assert_eq!(t.service_name, "production-fake-ap-scheduler");
    assert_eq!(t.container, "main");
    assert_eq!(t.region, "us-east-2");
    assert_eq!(t.shell_command, "/bin/bash");
    let wire = t.terminal_target();
    assert_eq!(
        (
            wire.project.as_str(),
            wire.environment.as_str(),
            wire.service.as_str(),
            wire.shell_type.as_str()
        ),
        ("admin-portal", "production", "scheduler", "shell")
    );
}

#[test]
fn aliases_resolve_to_the_same_target_as_the_canonical_names() {
    let v = vocab();
    let canonical = v
        .resolve("admin-portal", "production", "scheduler", "shell")
        .unwrap();

    for (project, env, service) in [
        ("ap", "prod", "sched"),
        ("admin", "prd", "job"),
        ("portal_dev", "production", "scheduler"),
        ("admin-portal", "prod", "sched"),
    ] {
        let t = v
            .resolve(project, env, service, "shell")
            .unwrap_or_else(|e| panic!("{project}/{env}/{service}: {}", e.detail()));
        assert_eq!(t, canonical, "{project}/{env}/{service}");
    }
}

#[test]
fn words_are_matched_without_regard_to_case() {
    let v = vocab();
    let t = v
        .resolve("AP", "PROD", "Scheduler", "SHELL")
        .expect("mixed case resolves");

    assert_eq!(four(&t), ("admin-portal", "production", "scheduler", "shell"));
    let t = v
        .resolve("Admin-Portal", "Production", "SCHED", "Tinker")
        .expect("mixed case canonical and alias resolve");
    assert_eq!(four(&t), ("admin-portal", "production", "scheduler", "tinker"));
    assert_eq!(t.shell_command, "php artisan tinker");
}

#[test]
fn a_project_shell_override_replaces_that_shell_types_command_for_that_project_only() {
    let v = vocab();

    let monitor = v
        .resolve("referral-monitor", "production", "monitor", "shell")
        .unwrap();
    let monitor_console = v
        .resolve("referral-monitor", "production", "monitor", "console")
        .unwrap();
    let portal = v
        .resolve("admin-portal", "production", "portal", "shell")
        .unwrap();

    assert_eq!(monitor.shell_command, "/bin/sh");
    assert_eq!(monitor_console.shell_command, "/bin/bash");
    assert_eq!(portal.shell_command, "/bin/bash");
}

// ── what is refused, and what the refusal lists ──────────────────────────────

#[test]
fn an_unknown_project_is_refused_listing_every_project() {
    let e = invalid(&vocab(), "billing", "production", "portal", "shell");

    assert_eq!(e.field, TargetField::Project);
    assert_eq!(e.given, "billing");
    assert_eq!(
        e.valid,
        strings(&["admin-portal", "family-portal", "payments", "referral-monitor"])
    );
}

#[test]
fn an_environment_the_project_does_not_have_is_refused_listing_that_projects_environments() {
    let e = invalid(&vocab(), "payments", "staging", "api", "shell");

    assert_eq!(e.field, TargetField::Environment);
    assert_eq!(e.given, "staging");
    assert_eq!(e.valid, strings(&["demo", "production"]));
}

#[test]
fn an_environment_with_no_region_is_not_offered_and_not_accepted() {
    let v = vocab();

    // `qa` is in admin-portal's data but has no entry under `regions`.
    let e = invalid(&v, "admin-portal", "qa", "portal", "shell");

    assert_eq!(e.field, TargetField::Environment);
    assert_eq!(e.valid, strings(&["canada", "demo", "production", "staging"]));
    let offered: Vec<String> = v
        .projects()
        .iter()
        .find(|p| p.name == "admin-portal")
        .expect("admin-portal")
        .environments
        .iter()
        .map(|e| e.name.clone())
        .collect();
    assert_eq!(offered, strings(&["canada", "demo", "production", "staging"]));
}

#[test]
fn a_service_the_environment_does_not_have_is_refused_listing_that_environments_services() {
    let v = vocab();

    let e = invalid(&v, "admin-portal", "demo", "referral-intake", "shell");
    assert_eq!(e.field, TargetField::Service);
    assert_eq!(e.valid, strings(&["portal", "queue", "scheduler"]));

    // The same service word is fine where the environment has it.
    assert!(v
        .resolve("admin-portal", "production", "referral-intake", "shell")
        .is_ok());
    let e = invalid(&v, "family-portal", "demo", "scheduler", "shell");
    assert_eq!(e.field, TargetField::Service);
    assert_eq!(e.valid, strings(&["portal"]));
}

#[test]
fn an_unknown_shell_type_is_refused_listing_the_shell_types() {
    let e = invalid(&vocab(), "admin-portal", "production", "portal", "bash");

    assert_eq!(e.field, TargetField::ShellType);
    assert_eq!(e.given, "bash");
    assert_eq!(e.valid, strings(&["console", "shell", "tinker"]));
}

#[test]
fn the_first_wrong_word_in_project_environment_service_shell_order_is_the_one_reported() {
    let v = vocab();

    assert_eq!(
        invalid(&v, "nope", "nope", "nope", "nope").field,
        TargetField::Project
    );
    assert_eq!(
        invalid(&v, "admin-portal", "nope", "nope", "nope").field,
        TargetField::Environment
    );
    assert_eq!(
        invalid(&v, "admin-portal", "production", "nope", "nope").field,
        TargetField::Service
    );
    assert_eq!(
        invalid(&v, "admin-portal", "production", "portal", "nope").field,
        TargetField::ShellType
    );
}

#[test]
fn a_refusal_names_the_field_and_lists_the_valid_values_in_its_detail() {
    let e = invalid(&vocab(), "admin-portal", "prodd", "portal", "shell");

    let detail = e.detail();
    assert!(detail.contains("environment"), "{detail}");
    assert!(detail.contains("prodd"), "{detail}");
    for value in ["production", "demo", "staging", "canada"] {
        assert!(detail.contains(value), "{detail}");
    }
}

#[test]
fn an_oversized_rejected_word_is_quoted_back_only_in_part() {
    let long = "x".repeat(5_000);

    let e = invalid(&vocab(), &long, "production", "portal", "shell");

    assert_eq!(e.field, TargetField::Project);
    assert!(e.given.chars().count() <= 64, "{}", e.given.len());
    assert!(e.detail().len() < 1_000, "the refusal must stay small");
}

#[test]
fn words_with_shell_syntax_are_just_unknown_words() {
    let v = vocab();

    for bad in ["portal; rm -rf /", "$(id)", "`id`", "portal\nscheduler", "", " "] {
        let e = invalid(&v, "admin-portal", "production", bad, "shell");
        assert_eq!(e.field, TargetField::Service, "{bad:?}");
    }
}

// ── what is offered ──────────────────────────────────────────────────────────

#[test]
fn projects_lists_each_project_with_its_default_service_environments_and_services() {
    let v = vocab();

    let projects = v.projects();

    let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(
        names,
        ["admin-portal", "family-portal", "payments", "referral-monitor"]
    );
    let ap = &projects[0];
    assert_eq!(ap.default_service.as_deref(), Some("portal"));
    let env = |name: &str| {
        ap.environments
            .iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("no {name}"))
    };
    assert_eq!(
        env("production").services,
        strings(&["api", "portal", "queue", "referral-intake", "scheduler"])
    );
    assert_eq!(env("staging").services, strings(&["portal", "scheduler"]));
    assert_eq!(projects[2].default_service.as_deref(), Some("api"));
    assert_eq!(projects[3].default_service.as_deref(), Some("monitor"));
    assert_eq!(v.default_service("payments"), Some("api"));
    assert_eq!(v.default_service("no-such-project"), None);
    assert_eq!(v.shell_types(), strings(&["console", "shell", "tinker"]));
}

#[test]
fn what_is_offered_carries_no_cluster_profile_or_account() {
    let v = vocab();
    let text = serde_json::to_string(&(v.projects(), v.shell_types())).unwrap();

    for secret in [
        "fake-prod-ecs",
        "fake-demo-ecs",
        "fake-prod-profile",
        "local-fake-prod-profile",
        "fake-sso-session",
        "production-fake-ap",
        "us-east-2",
        "/bin/bash",
    ] {
        assert!(!text.contains(secret), "{secret} leaked into {text}");
    }
}

#[test]
fn a_default_service_no_environment_has_is_not_offered() {
    let copy = Copy::new();
    let edited = copy.read("config.json").replace(
        "\"default_service\": \"api\"",
        "\"default_service\": \"nonexistent\"",
    );
    copy.write("config.json", &edited);

    let v = copy.load().unwrap();

    assert_eq!(v.default_service("payments"), None);
    let payments = v.projects().into_iter().find(|p| p.name == "payments").unwrap();
    assert_eq!(payments.default_service, None);
}

// ── profiles ─────────────────────────────────────────────────────────────────

#[test]
fn the_local_profile_overrides_the_shared_one_and_configure_me_means_none() {
    let v = vocab();
    let profile = |env: &str| {
        v.resolve("admin-portal", env, "portal", "shell")
            .unwrap()
            .profile
    };

    // production: set in both, the local file wins.
    assert_eq!(profile("production").as_deref(), Some("local-fake-prod-profile"));
    // demo: only in config.json.
    assert_eq!(profile("demo").as_deref(), Some("fake-demo-profile"));
    // staging: CONFIGURE_ME in config.json, a real name in ecs-local.json.
    assert_eq!(profile("staging").as_deref(), Some("local-fake-stg-profile"));
    // canada: CONFIGURE_ME and nothing local.
    assert_eq!(profile("canada"), None);
}

#[test]
fn without_a_local_file_profiles_come_from_the_shared_config() {
    let copy = Copy::new();
    std::fs::remove_file(copy.file("ecs-local.json")).unwrap();
    let v = copy.load().expect("ecs-local.json is optional");
    let profile = |env: &str| {
        v.resolve("admin-portal", env, "portal", "shell")
            .unwrap()
            .profile
    };

    assert_eq!(profile("production").as_deref(), Some("fake-prod-profile"));
    assert_eq!(profile("staging"), None);
    assert_eq!(profile("canada"), None);
}

#[test]
fn an_unreadable_local_file_is_ignored_and_the_shared_profiles_apply() {
    let copy = Copy::new();
    copy.write("ecs-local.json", "{ this is not json");

    let v = copy.load().expect("a broken ecs-local.json does not fail the load");

    let t = v
        .resolve("admin-portal", "production", "portal", "shell")
        .unwrap();
    assert_eq!(t.profile.as_deref(), Some("fake-prod-profile"));
}

#[test]
fn an_empty_profile_name_is_no_profile() {
    let copy = Copy::new();
    copy.write("ecs-local.json", r#"{"profiles": {"production": ""}}"#);
    let edited = copy
        .read("config.json")
        .replace("\"production\": \"fake-prod-profile\"", "\"production\": \"\"");
    copy.write("config.json", &edited);

    let v = copy.load().unwrap();

    let t = v
        .resolve("admin-portal", "production", "portal", "shell")
        .unwrap();
    assert_eq!(t.profile, None);
}

// ── aliases come from ecs.sh as text ─────────────────────────────────────────

#[test]
fn without_ecs_sh_canonical_names_still_resolve_and_aliases_do_not() {
    let copy = Copy::new();
    std::fs::remove_file(copy.file("ecs.sh")).unwrap();

    let v = copy.load().expect("ecs.sh is optional");

    assert!(v
        .resolve("admin-portal", "production", "scheduler", "shell")
        .is_ok());
    assert_eq!(
        invalid(&v, "admin-portal", "prod", "scheduler", "shell").field,
        TargetField::Environment
    );
    assert_eq!(
        invalid(&v, "ap", "production", "scheduler", "shell").field,
        TargetField::Project
    );
    assert_eq!(
        invalid(&v, "admin-portal", "production", "sched", "shell").field,
        TargetField::Service
    );
}

#[test]
fn an_ecs_sh_that_is_not_what_we_expect_gives_no_aliases_but_does_not_fail_the_load() {
    for text in [
        "this is not a script at all",
        "",
        "declare -A SOMETHING_ELSE=(\n    [prod]=\"production\"\n)\n",
    ] {
        let copy = Copy::new();
        copy.write("ecs.sh", text);

        let v = copy.load().unwrap_or_else(|e| panic!("{text:?}: {e}"));

        assert!(v
            .resolve("admin-portal", "production", "portal", "shell")
            .is_ok());
        assert_eq!(
            invalid(&v, "admin-portal", "prod", "portal", "shell").field,
            TargetField::Environment,
            "{text:?}"
        );
    }
}

#[test]
fn an_ecs_sh_that_is_not_text_gives_no_aliases() {
    let copy = Copy::new();
    std::fs::write(copy.file("ecs.sh"), [0xff, 0xfe, 0x00, 0x9f, 0x92, 0xff]).unwrap();

    let v = copy.load().expect("binary junk does not fail the load");

    assert_eq!(
        invalid(&v, "admin-portal", "prod", "portal", "shell").field,
        TargetField::Environment
    );
    assert!(v
        .resolve("admin-portal", "production", "portal", "shell")
        .is_ok());
}

#[test]
fn an_alias_block_with_a_line_that_is_not_a_plain_entry_gives_no_aliases_for_that_block_only() {
    let copy = Copy::new();
    let edited = copy.read("ecs.sh").replace(
        "    [prd]=\"production\"\n",
        "    [prd]=\"production\"\n    [sneaky]=production-and-more\n",
    );
    assert!(edited.contains("sneaky"), "harness: the edit applied");
    copy.write("ecs.sh", &edited);

    let v = copy.load().unwrap();

    // The environment block is rejected as a whole ...
    assert_eq!(
        invalid(&v, "admin-portal", "prod", "scheduler", "shell").field,
        TargetField::Environment
    );
    assert_eq!(
        invalid(&v, "admin-portal", "prd", "scheduler", "shell").field,
        TargetField::Environment
    );
    // ... and the other two blocks still work.
    let t = v.resolve("ap", "production", "sched", "shell").unwrap();
    assert_eq!(four(&t), ("admin-portal", "production", "scheduler", "shell"));
}

#[test]
fn alias_entries_that_are_not_plain_words_are_never_taken() {
    for entry in [
        "[evil]=\"$(touch /tmp/never)\"",
        "[evil]=\"`id`\"",
        "[evil]=\"a b\"",
        "[evil]=\"production;ls\"",
        "[Evil]=\"production\"",
        "[evil]='production'",
    ] {
        let copy = Copy::new();
        let edited = copy.read("ecs.sh").replace(
            "    [prd]=\"production\"\n",
            &format!("    [prd]=\"production\"\n    {entry}\n"),
        );
        copy.write("ecs.sh", &edited);

        let v = copy.load().unwrap();

        assert!(
            v.resolve("admin-portal", "evil", "portal", "shell").is_err(),
            "{entry}"
        );
        assert!(
            v.resolve("admin-portal", "Evil", "portal", "shell").is_err(),
            "{entry}"
        );
    }
}

#[test]
fn comments_and_blank_lines_inside_an_alias_block_are_fine() {
    let copy = Copy::new();
    let edited = copy.read("ecs.sh").replace(
        "    [prd]=\"production\"\n",
        "\n    # the short form\n    [prd]=\"production\"\n\n",
    );
    copy.write("ecs.sh", &edited);

    let v = copy.load().unwrap();

    assert!(v.resolve("admin-portal", "prd", "portal", "shell").is_ok());
    assert!(v.resolve("admin-portal", "prod", "portal", "shell").is_ok());
}

#[test]
fn loading_never_runs_anything_in_ecs_sh() {
    let copy = Copy::new();
    let canary_a = copy.file("ran-outside-the-blocks");
    let canary_b = copy.file("ran-inside-a-value");
    let canary_c = copy.file("ran-from-a-function");
    let hostile = format!(
        "#!/bin/bash\ntouch '{a}'\nfunction setup() {{ touch '{c}'; }}\nsetup\n{blocks}\nsource /dev/null\n\
         declare -A ECS_EXTRA_ALIASES=(\n    [x]=\"$(touch '{b}')\"\n)\n",
        a = canary_a.display(),
        b = canary_b.display(),
        c = canary_c.display(),
        blocks = copy.read("ecs.sh"),
    );
    copy.write("ecs.sh", &hostile);

    let v = copy.load().expect("the loader reads the script as text");

    // The aliases in the blocks are still found, in among everything else.
    assert!(v.resolve("ap", "prod", "sched", "shell").is_ok());
    for canary in [canary_a, canary_b, canary_c] {
        assert!(
            !canary.exists(),
            "{} exists: the loader ran part of ecs.sh",
            canary.display()
        );
    }
}

// ── the files are required, or not ───────────────────────────────────────────

#[test]
fn a_missing_config_json_is_a_vocab_error_that_says_where_it_looked() {
    let copy = Copy::new();
    std::fs::remove_file(copy.file("config.json")).unwrap();

    let e = copy.load().expect_err("no config.json");

    assert!(!e.problem.is_empty());
    assert!(e.problem.contains("config.json"), "{}", e.problem);
}

#[test]
fn a_config_json_that_is_not_valid_json_is_a_vocab_error() {
    let copy = Copy::new();
    for text in ["{ \"projects\": ", "not json", "[1, 2, 3]", "\"just a string\""] {
        copy.write("config.json", text);

        let e = copy.load().expect_err(text);

        assert!(!e.problem.is_empty(), "{text}");
    }
}

#[test]
fn a_config_json_with_no_projects_or_no_shell_types_is_a_vocab_error() {
    let copy = Copy::new();
    for text in [
        "{}",
        r#"{"projects": {}, "shell_types": {"shell": "/bin/bash"}}"#,
        r#"{"projects": {"p": {"environments": {}}}, "shell_types": {}}"#,
        r#"{"projects": {"p": {"environments": {}}}}"#,
    ] {
        copy.write("config.json", text);

        assert!(copy.load().is_err(), "{text}");
    }
}

#[test]
fn an_absurdly_large_config_json_is_refused_rather_than_read() {
    let copy = Copy::new();
    assert!(copy.load().is_ok(), "harness: the unpadded file is fine");
    // Otherwise valid, but padded past any real file's size.
    let mut text = copy.read("config.json");
    let end = text.rfind('}').expect("closing brace");
    text.insert_str(end, &format!(", \"pad\": \"{}\"", "x".repeat(5 * 1024 * 1024)));
    copy.write("config.json", &text);

    assert!(copy.load().is_err());
}

#[test]
fn the_first_existing_file_of_each_list_is_the_one_used() {
    let copy = Copy::new();
    let missing = copy.file("not-there/config.json");
    let paths = EcsPaths {
        config: vec![missing.clone(), copy.file("config.json")],
        local: vec![copy.file("no-local.json"), copy.file("ecs-local.json")],
        aliases_script: vec![copy.file("no-aliases.sh"), copy.file("ecs.sh")],
    };

    let v = EcsVocabulary::load(&paths).expect("falls through to the files that exist");

    let t = v.resolve("ap", "prod", "sched", "shell").unwrap();
    assert_eq!(t.profile.as_deref(), Some("local-fake-prod-profile"));
}

#[test]
fn explicit_terminal_config_paths_are_used_exactly() {
    let dir = fixture_dir();
    let cfg = TerminalConfig {
        ecs_config: Some(dir.join("config.json")),
        ecs_local: Some(dir.join("ecs-local.json")),
        ecs_aliases_script: Some(dir.join("ecs.sh")),
    };

    let paths = EcsPaths::from_config(&cfg);

    assert_eq!(paths, fixture_paths());
    assert!(EcsVocabulary::load(&paths)
        .unwrap()
        .resolve("ap", "prod", "sched", "shell")
        .is_ok());
}

// ── T-2a-2: the data is read afresh every time ───────────────────────────────

#[test]
fn editing_the_data_between_two_loads_changes_the_second_result_and_not_the_first() {
    let copy = Copy::new();
    let before = copy.load().unwrap();
    let target_before = before
        .resolve("admin-portal", "demo", "scheduler", "shell")
        .expect("demo has a scheduler");
    assert_eq!(target_before.cluster, "fake-demo-ecs");

    // Rename the cluster, drop a service, add an alias.
    let edited = copy
        .read("config.json")
        .replace("fake-demo-ecs", "fake-demo-ecs-v2")
        .replace("\"scheduler\": { \"service\": \"demo-fake-ap-scheduler\", \"container\": \"main\" }", "\"cron\": { \"service\": \"demo-fake-ap-scheduler\", \"container\": \"main\" }");
    assert_ne!(edited, copy.read("config.json"), "harness: the edit applied");
    copy.write("config.json", &edited);
    let aliases = copy
        .read("ecs.sh")
        .replace("    [prd]=\"production\"\n", "    [prd]=\"production\"\n    [live]=\"production\"\n");
    copy.write("ecs.sh", &aliases);
    let after = copy.load().unwrap();

    // The vocabulary already loaded does not move ...
    assert_eq!(
        before
            .resolve("admin-portal", "demo", "scheduler", "shell")
            .unwrap(),
        target_before
    );
    assert!(before.resolve("ap", "live", "portal", "shell").is_err());
    // ... the next load sees the edit.
    let e = invalid(&after, "admin-portal", "demo", "scheduler", "shell");
    assert_eq!(e.field, TargetField::Service);
    assert!(e.valid.contains(&"cron".to_string()), "{:?}", e.valid);
    let cron = after
        .resolve("admin-portal", "demo", "cron", "shell")
        .unwrap();
    assert_eq!(cron.cluster, "fake-demo-ecs-v2");
    assert!(after.resolve("ap", "live", "portal", "shell").is_ok());
}

#[test]
fn a_file_that_goes_missing_between_loads_turns_the_second_load_into_an_error() {
    let copy = Copy::new();
    assert!(copy.load().is_ok());

    std::fs::remove_file(copy.file("config.json")).unwrap();

    assert!(copy.load().is_err());
}
