//! The destructive-pattern list, daemon side: the same 30 names, in the same order, as the Mac app's
//! `StagingDestructivePatterns`, and the same verdicts. The shared fixture `hazards.json` pins the two
//! together row by row (see `s2.rs`); this file pins the Rust port to the Swift tests' cases and each
//! family's contract: wrapped, quoted, sudo'd, piped and absolute-path variants are still seen, and the
//! read-only look-alikes are not.
//!
//! The list is conservative on purpose: when a command is ambiguous it MATCHES (the user is asked to
//! confirm); a missing label never means a command is safe.

use crate::terminal::staging::destructive::{
    asks_in_production, brace_glued_word, contains_non_ascii, destructive_patterns,
    escape_quoted_word, wildcard_command_word, DESTRUCTIVE_NAMES,
};
use crate::terminal::staging::text::{normalise_for_hazard_words, validate_command_in};

const HAZARDS: &str = include_str!("../../../../tests/fixtures/terminal_staging/hazards.json");
const READ_ONLY_CORPUS: &str =
    include_str!("../../../../tests/fixtures/terminal_staging/read_only_corpus.json");

const THE_LIST: [&str; 30] = [
    "rm -rf",
    "DROP",
    "TRUNCATE",
    "DELETE FROM without WHERE",
    "migrate:fresh",
    "db:wipe",
    "queue:flush",
    "cache:clear",
    "--force",
    "kill -9",
    "migrate:refresh",
    "migrate:reset",
    "migrate:rollback",
    "kubectl delete",
    "kubectl drain",
    "helm uninstall",
    "terraform destroy",
    "aws delete/terminate",
    "aws s3 rm/rb",
    "dd of=",
    "mkfs",
    "shred",
    "> file",
    "find -delete",
    "xargs/piped rm",
    "queue:clear",
    "horizon:clear",
    "optimize:clear",
    "FLUSHALL/FLUSHDB",
    "stop/shutdown",
];

/// Every command in `commands` is labelled with `name` (and possibly more).
fn assert_all_match(name: &str, commands: &[&str]) {
    for command in commands {
        let found = destructive_patterns(command);
        assert!(
            found.contains(&name),
            "{command:?} should be labelled {name:?}, got {found:?}"
        );
    }
}

/// Nothing at all matches any of `commands`.
fn assert_none_match(commands: &[&str]) {
    for command in commands {
        assert_eq!(
            destructive_patterns(command),
            Vec::<&str>::new(),
            "{command:?}"
        );
    }
}

/// None of `commands` is labelled `name` (other names are not this family's business).
fn assert_not_labelled(name: &str, commands: &[&str]) {
    for command in commands {
        let found = destructive_patterns(command);
        assert!(
            !found.contains(&name),
            "{command:?} must not be labelled {name:?}, got {found:?}"
        );
    }
}

// ── The list itself ───────────────────────────────────────────────────────────

#[test]
fn the_list_is_exactly_the_fixed_one_in_order() {
    assert_eq!(DESTRUCTIVE_NAMES, THE_LIST);
}

#[test]
fn the_names_are_unique() {
    let mut seen = std::collections::BTreeSet::new();
    for name in DESTRUCTIVE_NAMES {
        assert!(seen.insert(name), "duplicate name {name:?}");
    }
}

#[test]
fn every_label_comes_in_list_order_once() {
    let found = destructive_patterns(
        "ls | xargs rm -rf; find . -delete; echo x > a; kill -9 1; kubectl delete pod x --force; DROP TABLE y",
    );
    let positions: Vec<usize> = found
        .iter()
        .map(|n| {
            THE_LIST
                .iter()
                .position(|l| l == n)
                .expect("a name from the list")
        })
        .collect();
    assert!(
        positions.windows(2).all(|w| w[0] < w[1]),
        "list order, no duplicates: {found:?}"
    );
    assert_eq!(
        found,
        [
            "rm -rf",
            "DROP",
            "--force",
            "kill -9",
            "kubectl delete",
            "> file",
            "find -delete",
            "xargs/piped rm"
        ]
    );
}

#[test]
fn the_shared_fixture_has_a_positive_row_for_every_name_and_negatives_for_the_new_families() {
    let rows: Vec<serde_json::Value> = serde_json::from_str(HAZARDS).expect("hazards.json");
    let with_names: Vec<&serde_json::Value> = rows
        .iter()
        .filter(|r| r.get("destructive").is_some())
        .collect();
    assert!(
        with_names.len() >= 100,
        "the fixture pins the verdicts of at least 100 rows, has {}",
        with_names.len()
    );
    for name in THE_LIST {
        assert!(
            with_names.iter().any(|r| r["destructive"]
                .as_array()
                .unwrap()
                .iter()
                .any(|n| n == name)),
            "no fixture row is labelled {name:?}"
        );
    }
    let negatives = with_names
        .iter()
        .filter(|r| r["destructive"].as_array().unwrap().is_empty())
        .count();
    assert!(
        negatives >= 40,
        "the fixture needs read-only look-alikes too, has {negatives}"
    );
}

#[test]
fn the_fixtures_asks_in_production_field_is_a_destructive_match_an_escape_quoted_word_a_brace_glued_word_non_ascii_or_a_wildcard_command(
) {
    // The Mac app opens the confirm sheet in a production pane for a destructive match, for an escape-quoted
    // word (`$'\x72m'`: no text rule can follow it), for a brace expansion glued to a word (`r{m..m}`), for any
    // non-ASCII scalar (what the shell runs may differ from what the user sees) and for a command word that is
    // a glob (`/bin/r?`): the sheet is the only thing that stops them. The fixture row says what the app must
    // do; the daemon's predicates are held to the same rows.
    let rows: Vec<serde_json::Value> = serde_json::from_str(HAZARDS).expect("hazards.json");
    let asking: Vec<&serde_json::Value> = rows
        .iter()
        .filter(|r| r.get("asks_in_production").is_some())
        .collect();
    assert!(
        asking.len() >= 25,
        "the fixture pins the sheet for the escape-quoted and brace-glued rows, has {}",
        asking.len()
    );
    for row in asking {
        let text = row["text"].as_str().unwrap();
        let destructive = !destructive_patterns(text).is_empty();
        let escape_quoted = row["escape_quoted"].as_bool().unwrap_or(false);
        let brace_glued = row["brace_glued"].as_bool().unwrap_or(false);
        let non_ascii = row["non_ascii"].as_bool().unwrap_or(false);
        let wildcard_command = row["wildcard_command"].as_bool().unwrap_or(false);
        assert_eq!(
            row["asks_in_production"].as_bool().unwrap(),
            destructive || escape_quoted || brace_glued || non_ascii || wildcard_command,
            "{}: {text:?}",
            row["name"]
        );
        assert_eq!(
            asks_in_production(text),
            row["asks_in_production"].as_bool().unwrap(),
            "{} (asks_in_production): {text:?}",
            row["name"]
        );
    }
    assert!(
        rows.iter().any(|r| r["escape_quoted"] == true
            && r["asks_in_production"] == true
            && r["destructive"].as_array().is_some_and(|d| d.is_empty())),
        "an escape-quoted row with no destructive match must still ask in production"
    );
    assert!(
        rows.iter().any(|r| r["brace_glued"] == true
            && r["asks_in_production"] == true
            && r["destructive"].as_array().is_some_and(|d| d.is_empty())),
        "a brace-glued row with no destructive match must still ask in production"
    );
    assert!(
        rows.iter().any(|r| r["non_ascii"] == true
            && r["asks_in_production"] == true
            && r["destructive"].as_array().is_some_and(|d| d.is_empty())),
        "a non-ASCII row with no destructive match must still ask in production"
    );
    assert!(
        rows.iter().any(|r| r["wildcard_command"] == true
            && r["asks_in_production"] == true
            && r["destructive"].as_array().is_some_and(|d| d.is_empty())),
        "a wildcard-command row with no destructive match must still ask in production"
    );
}

#[test]
fn the_fixtures_escape_quoted_brace_glued_non_ascii_and_wildcard_command_fields_are_what_the_daemon_computes(
) {
    let rows: Vec<serde_json::Value> = serde_json::from_str(HAZARDS).expect("hazards.json");
    let mut glued = 0;
    let mut non_ascii = 0;
    let mut wildcard = 0;
    for row in &rows {
        let text = row["text"].as_str().unwrap();
        if let Some(want) = row["escape_quoted"].as_bool() {
            assert_eq!(
                escape_quoted_word(text),
                want,
                "{} (escape_quoted): {text:?}",
                row["name"]
            );
        }
        if let Some(want) = row["brace_glued"].as_bool() {
            glued += 1;
            assert_eq!(
                brace_glued_word(text),
                want,
                "{} (brace_glued): {text:?}",
                row["name"]
            );
        }
        if let Some(want) = row["non_ascii"].as_bool() {
            non_ascii += 1;
            assert_eq!(
                contains_non_ascii(text),
                want,
                "{} (non_ascii): {text:?}",
                row["name"]
            );
        }
        if let Some(want) = row["wildcard_command"].as_bool() {
            wildcard += 1;
            assert_eq!(
                wildcard_command_word(text),
                want,
                "{} (wildcard_command): {text:?}",
                row["name"]
            );
        }
    }
    assert!(
        glued >= 25,
        "the fixture pins brace_glued for at least 25 rows, has {glued}"
    );
    assert!(
        non_ascii >= 10,
        "the fixture pins non_ascii for at least 10 rows, has {non_ascii}"
    );
    assert!(
        wildcard >= 10,
        "the fixture pins wildcard_command for at least 10 rows, has {wildcard}"
    );
}

// ── The ten patterns the Mac app already had (ported from StagingHazardsTests.swift) ──────────────

#[test]
fn every_original_pattern_matches_its_positive_cases() {
    let positives: &[(&str, &[&str])] = &[
        ("rm -rf /tmp/x", &["rm -rf"]),
        ("rm -fr /tmp/x", &["rm -rf"]),
        ("rm -Rf /tmp/x", &["rm -rf"]),
        ("rm -r -f x", &["rm -rf"]),
        ("rm -f -r x", &["rm -rf"]),
        ("rm --recursive --force x", &["rm -rf", "--force"]),
        ("rm -r --force x", &["rm -rf", "--force"]),
        ("sudo rm -rf x && ls", &["rm -rf"]),
        ("ls; rm -rf x", &["rm -rf"]),
        ("DROP TABLE users", &["DROP"]),
        ("drop table users", &["DROP"]),
        ("psql -c 'drop database x'", &["DROP"]),
        ("TRUNCATE TABLE users", &["TRUNCATE"]),
        ("truncate users", &["TRUNCATE"]),
        ("DELETE FROM users", &["DELETE FROM without WHERE"]),
        ("delete from users;", &["DELETE FROM without WHERE"]),
        ("php artisan migrate:fresh", &["migrate:fresh"]),
        ("php artisan db:wipe", &["db:wipe"]),
        ("php artisan queue:flush", &["queue:flush"]),
        ("php artisan cache:clear", &["cache:clear"]),
        ("PHP ARTISAN MIGRATE:FRESH", &["migrate:fresh"]),
        ("git push --force", &["--force"]),
        ("git push --force-with-lease", &["--force"]),
        ("composer install --force", &["--force"]),
        ("kill -9 123", &["kill -9"]),
        ("pkill -9 x", &["kill -9"]),
        ("killall -KILL x", &["kill -9"]),
        ("kill -SIGKILL 1", &["kill -9"]),
        ("kill -s 9 1", &["kill -9"]),
        ("kill -s KILL 1", &["kill -9"]),
        ("kill -s SIGKILL 1", &["kill -9"]),
        (
            "php artisan queue:flush && php artisan cache:clear",
            &["queue:flush", "cache:clear"],
        ),
        ("rm -rf x; DROP TABLE y", &["rm -rf", "DROP"]),
        ("kill -n 9 123", &["kill -9"]),
        ("git push --forc", &["--force"]),
        ("mysql -e 'DROP/**/TABLE users'", &["DROP"]),
    ];
    for (command, names) in positives {
        assert_eq!(destructive_patterns(command), *names, "{command}");
    }
}

#[test]
fn the_original_negative_cases_match_nothing() {
    assert_none_match(&[
        "ls -la",
        "git push",
        "git status",
        "rm x",
        "rm -r x",
        "rm -f x",
        "rm -v x",
        "echo -rf",
        "rm x | grep -rf y",
        "rm x; echo -rf",
        "DELETE FROM users WHERE id = 1",
        "delete from t where x=1",
        "echo drops",
        "echo truncated",
        "git push --forceful",
        "kill 123",
        "kill -15 1",
        "kill -s 15 1",
        "pkill -f x",
        "cat migrate",
        "php artisan cache:forget x",
        "git log --format=x",
        "php artisan route:list",
    ]);
}

#[test]
fn rm_rf_is_seen_through_wrapping_and_splitting() {
    for command in [
        "bash -c 'rm -rf /srv/app/cache'",
        "sh -c \"rm -rf x\"",
        "echo $(rm -rf x)",
        "echo `rm -rf x`",
        "(rm -rf x)",
        "{ rm -rf x; }",
        "\\rm -rf x",
        "\"rm\" -rf x",
        "r''m -rf x",
        "command rm -rf x",
        "/bin/rm -rf x",
        "env rm -rf x",
        "rm -r --forc x",
        "rm --recurs -f x",
        "rm -rf x",
        "ls & rm -rf x",
        "xargs rm -rf",
        "rm${IFS}-rf /",
        "r$()m -rf /",
        "r$@m -rf x",
    ] {
        assert!(
            destructive_patterns(command).contains(&"rm -rf"),
            "{command:?}"
        );
    }
    assert!(!destructive_patterns("bash -c 'rm x'").contains(&"rm -rf"));
    assert!(!destructive_patterns("echo \"rm\" -r x").contains(&"rm -rf"));
}

#[test]
fn laravel_abbreviations_and_split_words_still_match() {
    for (command, name) in [
        ("php artisan ca:cl", "cache:clear"),
        ("php artisan q:fl", "queue:flush"),
        ("php artisan mi:fr", "migrate:fresh"),
        ("php artisan db:w", "db:wipe"),
        ("php artisan migrate:fre''sh", "migrate:fresh"),
        ("php artisan cache:cle\\ar", "cache:clear"),
        ("php artisan \"queue\":flush", "queue:flush"),
    ] {
        assert!(
            destructive_patterns(command).contains(&name),
            "{command:?} should be {name:?}"
        );
    }
    assert_none_match(&["php artisan cache:forget x", "php artisan route:list"]);
}

#[test]
fn sql_comments_hide_neither_the_statement_nor_a_missing_where() {
    assert!(destructive_patterns("DELETE/**/FROM users").contains(&"DELETE FROM without WHERE"));
    for command in [
        "DELETE FROM users -- WHERE id=1",
        "DELETE FROM users # WHERE id=1",
        "DELETE FROM users --",
    ] {
        assert!(
            destructive_patterns(command).contains(&"DELETE FROM without WHERE"),
            "{command:?}"
        );
    }
    assert_none_match(&["DELETE FROM users WHERE id=1 -- all rows"]);
}

#[test]
fn each_delete_statement_is_checked_on_its_own() {
    for command in [
        "DELETE FROM a WHERE id=1; DELETE FROM b",
        "DELETE FROM a; SELECT * FROM b WHERE x = 1",
        "delete from a where id=1; delete from b; select 1",
    ] {
        assert!(
            destructive_patterns(command).contains(&"DELETE FROM without WHERE"),
            "{command:?}"
        );
    }
    assert_none_match(&["DELETE FROM a WHERE id=1; DELETE FROM b WHERE id=2"]);
}

#[test]
fn empty_expansions_are_seen_through_in_both_forms() {
    assert!(destructive_patterns("rm${IFS}-rf /").contains(&"rm -rf"));
    assert!(destructive_patterns("r$()m -rf /").contains(&"rm -rf"));
    assert!(destructive_patterns("php artisan cache:cl$@ear").contains(&"cache:clear"));
}

// ── migrate:refresh / reset / rollback ────────────────────────────────────────

#[test]
fn migrate_refresh_reset_and_rollback_are_caught_like_migrate_fresh() {
    for (name, plain, upper, abbreviated) in [
        (
            "migrate:refresh",
            "php artisan migrate:refresh --seed",
            "PHP ARTISAN MIGRATE:REFRESH",
            "php artisan mi:ref",
        ),
        (
            "migrate:reset",
            "php artisan migrate:reset",
            "PHP ARTISAN MIGRATE:RESET",
            "php artisan mi:rese",
        ),
        (
            "migrate:rollback",
            "php artisan migrate:rollback --step=1",
            "PHP ARTISAN MIGRATE:ROLLBACK",
            "php artisan migrate:rol",
        ),
    ] {
        assert_all_match(name, &[plain, upper, abbreviated]);
    }
    assert_all_match("migrate:rollback", &["php artisan mi:ro"]);
}

#[test]
fn migrate_abbreviations_that_fit_several_commands_label_all_of_them() {
    assert_eq!(
        destructive_patterns("php artisan mi:re"),
        ["migrate:refresh", "migrate:reset"]
    );
    assert_eq!(
        destructive_patterns("php artisan mi:r"),
        ["migrate:refresh", "migrate:reset", "migrate:rollback"]
    );
}

#[test]
fn migrate_resets_are_seen_through_wrapping_quoting_and_sudo() {
    assert_all_match(
        "migrate:refresh",
        &[
            "bash -c 'php artisan migrate:refresh'",
            "php artisan migrate:refre''sh",
            "echo $(php artisan migrate:refresh)",
            "sudo -u www-data php artisan migrate:refresh",
        ],
    );
    assert_all_match(
        "migrate:rollback",
        &[
            "php artisan \"migrate\":rollback",
            "php artisan down && php artisan migrate:rollback; php artisan up",
            "sudo -u www-data php artisan migrate:rollback --force",
        ],
    );
    assert_all_match("migrate:reset", &["php artisan migrate:res\\et"]);
    assert_eq!(
        destructive_patterns("sudo -u www-data php artisan migrate:rollback --force"),
        ["--force", "migrate:rollback"]
    );
}

#[test]
fn migrate_look_alikes_are_not_resets() {
    assert_none_match(&[
        "php artisan migrate:status",
        "php artisan migrate",
        "php artisan migrate --pretend",
        "php artisan migrate:install",
        "php artisan make:request StoreUser",
        "php artisan make:migration add_x_to_users",
        "php artisan route:list",
    ]);
}

// ── kubectl delete / drain ────────────────────────────────────────────────────

#[test]
fn kubectl_delete_is_caught_wherever_the_program_sits() {
    assert_all_match(
        "kubectl delete",
        &[
            "kubectl delete pod web-1",
            "kubectl delete -f deploy.yaml",
            "kubectl -n prod delete pod web-1",
            "kubectl --namespace=prod delete deployment web",
            "KUBECTL delete ns prod",
            "/usr/local/bin/kubectl delete pod web-1",
            "sudo kubectl delete pod web-1",
            "env KUBECONFIG=/x kubectl delete pod web-1",
            "KUBECONFIG=/x kubectl delete pod web-1",
            "command kubectl delete pod web-1",
            "time kubectl delete pod web-1",
            "nohup kubectl delete pod web-1",
            "exec kubectl delete pod web-1",
            "kubectl get pods && kubectl delete pod web-1",
            "echo go; kubectl delete pod web-1",
            "false || kubectl delete pod web-1",
            "echo web-1 | kubectl delete pod web-1",
            "k''ubectl delete pod web-1",
            "\"kubectl\" delete pod web-1",
            "\\kubectl delete pod web-1",
            "kubectl del\\ete pod web-1",
            "kubectl${IFS}delete${IFS}pod${IFS}web-1",
            "bash -c 'kubectl delete pod web-1'",
            "echo $(kubectl delete pod web-1)",
            "echo `kubectl delete pod web-1`",
            "(kubectl delete pod web-1)",
            "{ kubectl delete pod web-1; }",
        ],
    );
}

#[test]
fn kubectl_drain_is_caught_wherever_the_program_sits() {
    assert_all_match(
        "kubectl drain",
        &[
            "kubectl drain node-1 --ignore-daemonsets",
            "kubectl --context prod drain node-1",
            "sudo kubectl drain node-1",
            "/usr/bin/kubectl drain node-1",
            "bash -c \"kubectl drain node-1\"",
            "kubectl dr''ain node-1",
        ],
    );
    assert_eq!(
        destructive_patterns("kubectl drain node-1; kubectl delete node node-1"),
        ["kubectl delete", "kubectl drain"]
    );
}

#[test]
fn kubectl_read_only_look_alikes_match_nothing() {
    assert_none_match(&[
        "kubectl get pods",
        "kubectl describe pod web-1",
        "kubectl logs web-1",
        "kubectl apply -f x.yaml",
        "kubectl get pod delete-me",
        "kubectl get node drain-me",
        "kubectl get pods; echo delete",
    ]);
}

// ── helm uninstall ────────────────────────────────────────────────────────────

#[test]
fn helm_uninstall_and_its_aliases_are_caught() {
    assert_all_match(
        "helm uninstall",
        &[
            "helm uninstall web",
            "helm delete web",
            "helm del web",
            "helm un web",
            "helm -n prod uninstall web",
            "sudo helm uninstall web",
            "/usr/local/bin/helm uninstall web",
            "HELM uninstall web",
            "bash -c 'helm uninstall web'",
            "helm list && helm uninstall web",
            "he''lm uninstall web",
            "helm${IFS}uninstall${IFS}web",
            "echo $(helm uninstall web)",
        ],
    );
}

#[test]
fn helm_read_only_look_alikes_match_nothing() {
    assert_none_match(&[
        "helm list",
        "helm install web ./chart",
        "helm upgrade web ./chart",
        "helm status web",
        "helm list --uninstalling",
        "helm list; echo uninstall",
    ]);
}

// ── terraform destroy ─────────────────────────────────────────────────────────

#[test]
fn terraform_destroy_and_the_ambiguous_destroying_flags_are_caught() {
    assert_all_match(
        "terraform destroy",
        &[
            "terraform destroy",
            "terraform destroy -auto-approve",
            "tofu destroy",
            "terragrunt destroy",
            "terragrunt run-all destroy",
            "terraform apply -destroy",
            "terraform apply --destroy",
            "terraform plan -destroy",
            "terraform apply -replace=aws_instance.web",
            "terraform apply -replace aws_instance.web",
            "tofu apply -replace=aws_instance.web",
            "terraform -chdir=infra destroy",
            "terraform -chdir=infra apply -destroy",
            "sudo terraform destroy",
            "/usr/local/bin/terraform destroy",
            "TF_LOG=debug terraform destroy",
            "env TF_LOG=debug terraform destroy",
            "TERRAFORM destroy",
            "terraform apply -auto-approve && terraform destroy",
            "bash -c 'terraform destroy'",
            "terra''form destroy",
            "terraform \"destroy\"",
            "\\terraform destroy",
            "terraform${IFS}destroy",
        ],
    );
}

#[test]
fn terraform_read_only_and_plain_apply_look_alikes_match_nothing() {
    assert_none_match(&[
        "terraform apply",
        "terraform plan",
        "terraform init",
        "terraform apply -auto-approve",
        "tofu validate",
        "terraform fmt",
        "terraform state list",
        "terraform plan -out=tfplan",
        "terraform plan; echo destroy",
    ]);
}

// ── aws delete / terminate and s3 rm / rb ─────────────────────────────────────

#[test]
fn aws_delete_terminate_remove_deregister_and_purge_verbs_are_caught() {
    assert_all_match(
        "aws delete/terminate",
        &[
            "aws ec2 terminate-instances --instance-ids i-0abc",
            "aws s3api delete-object --bucket b --key k",
            "aws s3api delete-bucket --bucket b",
            "aws iam remove-user-from-group --user-name u --group-name g",
            "aws ecs deregister-task-definition --task-definition web:1",
            "aws sqs purge-queue --queue-url q",
            "aws rds delete-db-instance --db-instance-identifier x --skip-final-snapshot",
            "aws --profile prod ec2 terminate-instances --instance-ids i-0abc",
            "aws --region us-east-1 --profile prod ec2 terminate-instances --instance-ids i-0abc",
            "AWS EC2 TERMINATE-INSTANCES --instance-ids i-0abc",
            "sudo aws ec2 terminate-instances --instance-ids i-0abc",
            "/usr/local/bin/aws ec2 terminate-instances --instance-ids i-0abc",
            "AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc",
            "env AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc",
            "time aws ec2 terminate-instances --instance-ids i-0abc",
            "aws ec2 describe-instances && aws ec2 terminate-instances --instance-ids i-0abc",
            "a''ws ec2 terminate-instances --instance-ids i-0abc",
            "aws ec2 \"terminate-instances\" --instance-ids i-0abc",
            "\\aws ec2 delete-volume --volume-id vol-0abc",
            "aws ec2 termi\\nate-instances --instance-ids i-0abc",
            "bash -c 'aws ec2 terminate-instances --instance-ids i-0abc'",
            "echo $(aws sqs purge-queue --queue-url q)",
            "(aws iam delete-user --user-name u)",
            "aws${IFS}ec2${IFS}terminate-instances${IFS}--instance-ids${IFS}i-0abc",
        ],
    );
}

#[test]
fn aws_read_only_look_alikes_match_nothing() {
    assert_none_match(&[
        "aws ec2 describe-instances",
        "aws s3 ls",
        "aws s3api get-object --bucket b --key k out.bin",
        "aws iam list-users",
        "aws sts get-caller-identity",
        "aws s3 ls s3://delete-me",
        "aws logs filter-log-events --log-group-name g",
        "aws ec2 describe-instances --filters Name=tag:x,Values=delete-me",
        "aws ec2 describe-instances; echo terminate-instances",
    ]);
}

#[test]
fn aws_s3_rm_rb_and_sync_with_delete_are_caught() {
    assert_all_match(
        "aws s3 rm/rb",
        &[
            "aws s3 rm s3://b/k",
            "aws s3 rm s3://b/k --recursive",
            "aws s3 rb s3://b --force",
            "aws s3 rb s3://b",
            "aws --profile prod s3 rm s3://b/k",
            "aws s3 sync ./out s3://b --delete",
            "aws s3 sync s3://a s3://b --delete --exact-timestamps",
            "sudo aws s3 rm s3://b/k",
            "/usr/local/bin/aws s3 rm s3://b/k",
            "AWS_PROFILE=prod aws s3 rb s3://b",
            "bash -c 'aws s3 rm s3://b/k'",
            "\"aws\" s3 \"rm\" s3://b/k",
            "aws s3 r''m s3://b/k",
            "aws${IFS}s3${IFS}rm${IFS}s3://b/k",
            "aws s3 ls && aws s3 rm s3://b/k",
        ],
    );
    assert_eq!(
        destructive_patterns("aws s3 rb s3://b --force"),
        ["--force", "aws s3 rm/rb"]
    );
    assert_eq!(
        destructive_patterns("aws s3 rm s3://b/k --recursive --force"),
        ["rm -rf", "--force", "aws s3 rm/rb"]
    );
    assert_eq!(
        destructive_patterns(
            "aws s3 rm s3://b/k && aws ec2 terminate-instances --instance-ids i-0abc"
        ),
        ["aws delete/terminate", "aws s3 rm/rb"]
    );
}

#[test]
fn aws_s3_copy_list_make_and_plain_sync_look_alikes_are_not_removals() {
    for command in [
        "aws s3 cp a.txt s3://b/a.txt",
        "aws s3 cp s3://b/k ./out --recursive",
        "aws s3 sync ./out s3://b",
        "aws s3 sync ./out s3://b --dryrun",
        "aws s3 mb s3://x",
        "aws s3 ls s3://rm",
        "aws s3 ls",
    ] {
        assert_not_labelled("aws s3 rm/rb", &[command]);
    }
    assert_none_match(&[
        "aws s3 cp a.txt s3://b/a.txt",
        "aws s3 sync ./out s3://b",
        "aws s3 mb s3://x",
    ]);
}

// ── dd of=, mkfs, shred, truncate ─────────────────────────────────────────────

#[test]
fn dd_with_an_output_file_is_caught_and_a_read_only_dd_is_not() {
    assert_all_match(
        "dd of=",
        &[
            "dd if=/dev/zero of=/dev/sda bs=1M",
            "dd of=/dev/sdb if=disk.img",
            "DD IF=disk.img OF=/dev/sdb",
            "sudo dd if=disk.img of=/dev/sdb",
            "/bin/dd if=disk.img of=/dev/sdb",
            "env LC_ALL=C dd if=disk.img of=/dev/sdb",
            "time dd if=disk.img of=/dev/sdb",
            "nohup dd if=disk.img of=/dev/sdb",
            "cat disk.img | dd of=/dev/sdb",
            "sync && dd if=disk.img of=/dev/sdb",
            "bash -c 'dd if=/dev/zero of=/dev/sda'",
            "echo $(dd if=a of=b)",
            "d''d if=disk.img of=/dev/sdb",
            "dd if=disk.img o''f=/dev/sdb",
            "\\dd if=disk.img of=/dev/sdb",
            "dd${IFS}if=disk.img${IFS}of=/dev/sdb",
        ],
    );
    assert_none_match(&[
        "dd if=/dev/zero bs=1M count=1",
        "echo odd of=x",
        "ls of=x",
        "dd if=disk.img bs=1 count=1; echo of=x",
    ]);
}

#[test]
fn mkfs_and_its_variants_are_caught_and_look_alikes_are_not() {
    assert_all_match(
        "mkfs",
        &[
            "mkfs /dev/sdb1",
            "mkfs.ext4 /dev/sdb1",
            "/sbin/mkfs -t xfs /dev/sdb1",
            "sudo mkfs.xfs /dev/sdb1",
            "MKFS.EXT4 /dev/sdb1",
            "mkfs.vfat -F 32 /dev/sdb1",
            "X=1 mkfs.ext4 /dev/sdb1",
            "echo go; mkfs.ext4 /dev/sdb1",
            "bash -c 'mkfs.ext4 /dev/sdb1'",
            "mk''fs.ext4 /dev/sdb1",
            "/usr/sbin/mkfs.btrfs -f /dev/sdb1",
            "mkfsx /dev/sdb1",
            "mkfs.ext4${IFS}/dev/sdb1",
        ],
    );
    assert_none_match(&["mkdir -p /tmp/x", "mk", "mktemp -d", "echo mkf"]);
}

#[test]
fn shred_is_caught_and_look_alikes_are_not() {
    assert_all_match(
        "shred",
        &[
            "shred -u secret.txt",
            "shred -vzn 3 /dev/sdb",
            "SHRED -u secret.txt",
            "sudo shred -u secret.txt",
            "/usr/bin/shred -u secret.txt",
            "ls | xargs shred -u",
            "bash -c 'shred -u secret.txt'",
            "sh''red -u secret.txt",
            "\\shred secret.txt",
            "echo go; shred secret.txt",
        ],
    );
    assert_none_match(&["shredder --help", "echo shreds", "ls shred-notes.txt"]);
}

#[test]
fn truncate_the_command_is_the_truncate_pattern() {
    assert_eq!(destructive_patterns("truncate -s 0 f"), ["TRUNCATE"]);
    assert_eq!(
        destructive_patterns("sudo truncate -s0 /var/log/app.log"),
        ["TRUNCATE"]
    );
}

// ── truncating redirections ───────────────────────────────────────────────────

#[test]
fn a_truncating_redirection_is_caught_in_all_its_spellings() {
    assert_all_match(
        "> file",
        &[
            ": > file",
            ":> file",
            "echo hi > out.txt",
            "cat a >b",
            "ls 2>err.log",
            "cmd >| f",
            "cmd >! f",
            "echo x >& log",
            "a &>log",
            "> /var/log/app.log",
            "echo x >$out",
            "ls > /dev/nullx",
            "ls > /DEV/NULL",
            "ls > /Dev/Null",
            "cmd > /dev/null > out.txt",
            "echo a >(cat)",
            "echo a >",
            "sudo sh -c 'echo x > /etc/conf'",
            "bash -c \"cat a > b\"",
            "echo $(echo x > f)",
            "ls && echo x > f",
        ],
    );
}

#[test]
fn appends_dups_closes_and_redirections_to_the_bit_buckets_are_not_truncations() {
    assert_none_match(&[
        // A `>` inside quotes is a character, not a redirection (round 2: SQL, awk and jq programs).
        "echo \"a > b\"",
        "echo a >> log",
        "cmd 2>&1",
        "cmd >&2",
        "cmd 1>&2",
        "cmd >&-",
        "ls > /dev/null",
        "ls 2>/dev/null",
        "ls &>/dev/null",
        "ls > /dev/stderr",
        "ls 2>/dev/stdout",
        "ls >& /dev/null",
        "ls &>> log",
        "ls 2>> err.log",
        "cmd 2>&1 | grep x",
        "echo > /dev/null; ls",
        "ls > /dev/null 2>&1",
        "ls 2>&1 >/dev/null",
        "exec 3<>/tmp/sock",
        "echo hello",
    ]);
}

#[test]
fn a_redirection_is_listed_after_the_older_names() {
    assert_eq!(
        destructive_patterns("echo x > a; kill -9 1"),
        ["kill -9", "> file"]
    );
    assert_eq!(destructive_patterns("rm -rf x > log"), ["rm -rf", "> file"]);
    assert_eq!(
        destructive_patterns("rm -rf /tmp/x 2>/dev/null"),
        ["rm -rf"]
    );
}

// ── find -delete, xargs and piped rm ──────────────────────────────────────────

#[test]
fn find_with_delete_or_an_exec_of_rm_is_caught() {
    assert_all_match(
        "find -delete",
        &[
            "find . -name x -delete",
            "find . -exec rm {} \\;",
            "find . -type f -execdir rm -- {} +",
            "find /tmp -exec sh -c 'rm {}' \\;",
            "find . -ok rm {} \\;",
            "find . -okdir rm {} \\;",
            "find . -exec /bin/rm {} \\;",
            "find . -exec RM {} \\;",
            "find . -name '*.log' -mtime +7 -delete",
            "/usr/bin/find . -delete",
            "sudo find . -DELETE",
            "FIND . -delete",
            "bash -c 'find . -name x -delete'",
            "echo $(find . -delete)",
            "f''ind . -delete",
            "\\find . -delete",
            "ls && find . -delete",
            "find . -delete | cat",
            "find${IFS}.${IFS}-delete",
            "find . -name x -exec grep rm {} \\;",
        ],
    );
    assert_eq!(
        destructive_patterns("find . -exec rm -rf {} \\;"),
        ["rm -rf", "find -delete"]
    );
}

#[test]
fn find_without_delete_or_rm_is_not_caught() {
    assert_none_match(&[
        "find . -name x",
        "find . -exec ls {} \\;",
        "find . -name delete",
        "find . -print",
        "find . -type f -print0 | sort -z",
        "find . -name '*.log' -exec grep -l error {} +",
        "echo -delete",
    ]);
}

#[test]
fn xargs_rm_and_rm_after_a_pipe_are_caught() {
    assert_all_match(
        "xargs/piped rm",
        &[
            "xargs rm",
            "xargs -0 rm -f",
            "xargs -I{} rm {}",
            "xargs 'rm'",
            "ls | xargs rm",
            "ls | sudo rm x",
            "find . | while read f; do rm \"$f\"; done",
            "echo x | sh -c 'rm y'",
            "cat list | xargs -n1 rm",
            "ls | /bin/rm x",
            "ls | RM x",
            "ls|xargs rm",
            "echo x | env rm y",
            "ls | \\rm x",
            "ls | x''args rm",
            "ls | xargs${IFS}rm",
            "bash -c 'ls | xargs rm'",
            "(ls | xargs rm)",
            "echo $(ls | xargs rm)",
            "ls && ls | xargs rm",
            "ls | xargs -P4 -I {} rm {}",
            "ls | rm",
            "find . -name x | xargs rm",
        ],
    );
    assert_eq!(
        destructive_patterns("xargs rm -rf"),
        ["rm -rf", "xargs/piped rm"]
    );
    assert_eq!(
        destructive_patterns("ls | xargs rm -rf"),
        ["rm -rf", "xargs/piped rm"]
    );
    assert_eq!(destructive_patterns("ls | xargs rm -f"), ["xargs/piped rm"]);
}

#[test]
fn rm_before_the_pipe_or_after_or_or_is_not_piped_rm() {
    assert_none_match(&[
        "rm x | grep y",
        "ls || rm x",
        "rm x",
        "ls | grep rm-me",
        "xargs echo",
        "ls | xargs ls",
        "rm x || ls | cat",
        "echo x | tee y",
    ]);
}

// ── force kills ───────────────────────────────────────────────────────────────

#[test]
fn every_spelling_of_a_force_kill_is_caught() {
    assert_all_match(
        "kill -9",
        &[
            "kill -s9 1",
            "kill -s KILL 1",
            "kill -SIGKILL 1",
            "kill -KILL 1",
            "kill -n9 1",
            "kill -n 9 1",
            "kill -sKILL 1",
            "kill -ssigkill 1",
            "kill --signal=KILL 1",
            "kill --signal=sigkill 1",
            "kill --signal=9 1",
            "kill --signal 9 1",
            "kill --signal KILL 1",
            "kill 1 -9",
            "pkill -9 x",
            "pkill -f x -9",
            "pkill -f x -KILL",
            "killall -9 x",
            "killall -s KILL x",
            "/bin/kill -9 1",
            "sudo kill -9 1",
            "env kill -9 1",
            "nohup kill -9 1",
            "time kill -9 1",
            "exec kill -9 1",
            "command kill -9 1",
            "KILL -9 1",
            "bash -c 'kill -9 1'",
            "echo $(kill -9 1)",
            "ls && kill -9 1",
            "ls; kill -9 1",
            "pgrep x | xargs kill -9",
            "k''ill -9 1",
            "\\kill -9 1",
            "kill${IFS}-9${IFS}1",
        ],
    );
}

#[test]
fn gentle_signals_and_listing_signals_are_not_force_kills() {
    assert_none_match(&[
        "kill 123",
        "kill -15 1",
        "kill -s 15 1",
        "kill -s TERM 1",
        "kill -HUP 1",
        "kill -n 15 1",
        "kill --signal=15 1",
        "pkill -f x",
        "pkill -TERM x",
        "kill -l",
        "killall x",
        "kill 1; echo -9",
    ]);
}

// ── redirection glued to a word, and the later families ───────────────────────

#[test]
fn a_redirection_glued_to_a_word_does_not_hide_the_verb() {
    assert_all_match(
        "kubectl delete",
        &[
            "kubectl delete>/dev/null ns x",
            "kubectl delete</dev/null ns x",
            "kubectl>/dev/null delete ns x",
            "bash -c 'kubectl delete>/dev/null ns x'",
            "sudo kubectl delete>/dev/null ns x",
        ],
    );
    assert_all_match(
        "terraform destroy",
        &["terraform destroy>/dev/null", "tofu destroy</dev/null"],
    );
    assert_all_match(
        "helm uninstall",
        &["helm uninstall</dev/null x", "helm uninstall>/dev/null x"],
    );
    assert_all_match(
        "aws delete/terminate",
        &[
            "aws s3api delete-bucket>/dev/null",
            "aws s3api delete-bucket>/dev/null --bucket b",
        ],
    );
    assert_eq!(
        destructive_patterns("kubectl delete>out.log ns x"),
        ["kubectl delete", "> file"]
    );
}

#[test]
fn plain_redirections_to_the_bit_buckets_and_dups_stay_unlabelled() {
    assert_none_match(&[
        "echo hi 2>&1",
        "echo hi >&2",
        "echo hi > /dev/null",
        "ls>/dev/null",
        "ls >/dev/null 2>&1",
        "cat</dev/null",
        "kubectl get pods>/dev/null",
        "terraform plan>/dev/null",
        "helm list</dev/null",
        "aws s3api list-buckets>/dev/null",
    ]);
}

#[test]
fn aws_kms_schedule_key_deletion_is_caught_and_the_other_kms_verbs_are_not() {
    assert_all_match(
        "aws delete/terminate",
        &[
            "aws kms schedule-key-deletion --key-id k",
            "aws --profile prod kms schedule-key-deletion --key-id k",
            "/usr/local/bin/aws kms schedule-key-deletion --key-id k",
            "sudo aws kms schedule-key-deletion --key-id k",
            "bash -c 'aws kms schedule-key-deletion --key-id k'",
            "aws kms schedule-key-d''eletion --key-id k",
            "AWS KMS SCHEDULE-KEY-DELETION --key-id k",
            "aws kms schedule-key-deletion>/dev/null --key-id k",
        ],
    );
    assert_none_match(&[
        "aws kms list-keys",
        "aws kms describe-key --key-id k",
        "aws kms cancel-key-deletion --key-id k",
        "aws kms encrypt --key-id k --plaintext x",
    ]);
}

#[test]
fn parallel_rm_is_caught_like_xargs_rm_and_other_parallel_commands_are_not() {
    assert_all_match(
        "xargs/piped rm",
        &[
            "parallel rm ::: a b",
            "parallel -j4 rm {} ::: a b",
            "parallel 'rm -rf {}' ::: a b",
            "ls | parallel rm",
            "sudo parallel rm ::: a b",
            "/usr/bin/parallel rm ::: a b",
            "parallel /bin/rm ::: a b",
            "bash -c 'parallel rm ::: a b'",
            "p''arallel rm ::: a b",
            "PARALLEL RM ::: a b",
            "parallel rm>/dev/null ::: a b",
        ],
    );
    assert_eq!(
        destructive_patterns("parallel 'rm -rf {}' ::: a b"),
        ["rm -rf", "xargs/piped rm"]
    );
    assert_none_match(&[
        "parallel echo ::: a b",
        "parallel gzip ::: a b",
        "parallel --dry-run echo {} ::: a b",
        "parallel rmdir ::: a b",
    ]);
}

#[test]
fn terraform_workspace_delete_state_rm_and_taint_are_caught_and_read_only_forms_are_not() {
    assert_all_match(
        "terraform destroy",
        &[
            "terraform workspace delete staging",
            "terraform workspace delete -force staging",
            "tofu workspace delete staging",
            "terraform -chdir=infra workspace delete staging",
            "sudo terraform workspace delete staging",
            "bash -c 'terraform workspace delete staging'",
            "terraform work''space de\\lete staging",
            "terraform state rm aws_instance.web",
            "terraform -chdir=infra state rm aws_instance.web",
            "tofu state rm aws_instance.web",
            "terraform state remove aws_instance.web",
            "/usr/local/bin/terraform state rm aws_instance.web",
            "env TF_LOG=debug terraform state rm aws_instance.web",
            "TERRAFORM STATE RM aws_instance.web",
            "bash -c 'terraform state rm aws_instance.web'",
            "terraform state list; terraform state rm aws_instance.web",
            "terraform taint aws_instance.web",
            "sudo terraform taint aws_instance.web",
            "tofu taint aws_instance.web",
            "/usr/bin/terraform taint aws_instance.web",
            "bash -c 'terraform taint aws_instance.web'",
            "terraform ta''int aws_instance.web",
            "terraform -chdir=infra taint aws_instance.web",
            "TERRAFORM TAINT aws_instance.web",
        ],
    );
    assert_none_match(&[
        "terraform workspace list",
        "terraform workspace select prod",
        "terraform workspace show",
        "terraform state show aws_instance.web",
        "terraform state pull",
        "terraform untaint aws_instance.web",
        "terraform output",
        "terraform state list; terraform workspace list",
    ]);
}

// ── several families at once ──────────────────────────────────────────────────

#[test]
fn several_families_in_one_command_are_all_listed_in_list_order() {
    assert_eq!(
        destructive_patterns("kubectl delete pod web-1 && terraform destroy"),
        ["kubectl delete", "terraform destroy"]
    );
    assert_eq!(
        destructive_patterns("dd if=a of=b; mkfs.ext4 /dev/sdb; shred x"),
        ["dd of=", "mkfs", "shred"]
    );
    assert_eq!(
        destructive_patterns("ls | xargs rm -rf; find . -delete"),
        ["rm -rf", "find -delete", "xargs/piped rm"]
    );
    assert_eq!(
        destructive_patterns("helm uninstall web; kubectl delete ns web"),
        ["kubectl delete", "helm uninstall"]
    );
    assert_eq!(
        destructive_patterns("kubectl delete pod x --force; php artisan migrate:rollback"),
        ["--force", "migrate:rollback", "kubectl delete"]
    );
}

// ── quoted and escaped substitution openers, and a quote-aware closer ─────────
//
// The words view (`normalise_for_hazard_words`) puts the inner words of `$(…)`, a backtick pair and `<(…)` in
// the segment after a `_` placeholder, with `;`, `|` and `&` inside turned into spaces, and its closer search
// skips a quoted or backslash-escaped `)`, `}` or backtick. So a verb a shell runs after a quoted opener, or
// after a `)` inside a string, is still seen after the program it follows.

#[test]
fn a_quoted_or_escaped_opener_does_not_hide_the_words_a_shell_runs_after_it() {
    let cases: &[(&str, &[&str])] = &[
        (r#"rm '$(' '-rf' /x ')'"#, &["rm -rf"]),
        (r#"rm '`' '-rf' /x '`'"#, &["rm -rf"]),
        (r#"rm '<(' '-rf' /x ')'"#, &["rm -rf"]),
        (r#"rm a\` '-rf' /x b\`"#, &["rm -rf"]),
        (
            r#"kubectl -n '$(' 'delete' ns prod ')'"#,
            &["kubectl delete"],
        ),
        (r#"kubectl '`' 'delete' ns prod '`'"#, &["kubectl delete"]),
        (
            r#"kubectl $(echo "(") 'delete' ns prod "x)""#,
            &["kubectl delete"],
        ),
        (
            r#"terraform '$(' 'destroy' -auto-approve ')'"#,
            &["terraform destroy"],
        ),
        (r#"helm '$(' 'uninstall' rel ')'"#, &["helm uninstall"]),
        (
            r#"aws '$(' ec2 'terminate-instances' --instance-ids i-1 ')'"#,
            &["aws delete/terminate"],
        ),
        (
            r#"aws '`' ec2 'terminate-instances' --instance-ids i-1 '`'"#,
            &["aws delete/terminate"],
        ),
        (r#"pkill '$(' '-9' x ')'"#, &["kill -9"]),
        (r#"kill '$(' '-9' 1 ')'"#, &["kill -9"]),
    ];
    for (command, want) in cases {
        assert_eq!(destructive_patterns(command), *want, "{command}");
    }
}

#[test]
fn a_closer_that_skips_a_quoted_or_escaped_paren_or_backtick_keeps_the_verb_after_its_program() {
    // The segment must not be split at the `;` inside the substitution: only a quote-aware closer sees that
    // the `)` in the string does not end it.
    let cases: &[(&str, &[&str])] = &[
        (
            r#"kubectl $(echo ")"; echo x) delete ns prod"#,
            &["kubectl delete"],
        ),
        (
            r#"kubectl $(echo ')'; echo x) delete ns prod"#,
            &["kubectl delete"],
        ),
        (
            r#"kubectl `echo \`;echo x` delete ns prod"#,
            &["kubectl delete"],
        ),
        (
            r#"terraform $(echo ")"; echo x) destroy"#,
            &["terraform destroy"],
        ),
    ];
    for (command, want) in cases {
        assert_eq!(destructive_patterns(command), *want, "{command}");
    }
}

#[test]
fn substitutions_that_hide_nothing_stay_unlabelled() {
    assert_none_match(&[
        r#"echo '$(' hello ')'"#,
        "kubectl get pods -l app=$(cat app.txt)",
        "ls $(echo a; echo b)",
        "echo $(date) && ls ${HOME}/x",
    ]);
}

fn words_of(view: &str) -> Vec<&str> {
    view.split_whitespace().collect()
}

/// The first `;`, `|`, `&` separated segment of `view` that has `program` as one of its words.
fn segment_with<'a>(view: &'a str, program: &str) -> Option<&'a str> {
    view.split([';', '|', '&'])
        .find(|segment| segment.split_whitespace().any(|w| w == program))
}

#[test]
fn the_words_view_emits_the_inner_words_of_a_command_substitution_after_the_placeholder() {
    let view = normalise_for_hazard_words("echo $(rm -rf /x)");
    let words = words_of(&view);
    for want in ["echo", "_", "rm", "-rf", "/x"] {
        assert!(
            words.contains(&want),
            "{want:?} should be a word of {view:?}"
        );
    }
}

#[test]
fn the_words_view_emits_the_inner_words_of_a_backtick_pair() {
    let view = normalise_for_hazard_words("echo `kubectl delete ns x`");
    let words = words_of(&view);
    for want in ["echo", "_", "kubectl", "delete", "ns"] {
        assert!(
            words.contains(&want),
            "{want:?} should be a word of {view:?}"
        );
    }
}

#[test]
fn the_words_view_emits_the_inner_words_of_a_process_substitution() {
    let view = normalise_for_hazard_words("diff <(sort a.txt) <(cat b.txt)");
    let words = words_of(&view);
    for want in ["diff", "_", "sort", "a.txt", "cat", "b.txt"] {
        assert!(
            words.contains(&want),
            "{want:?} should be a word of {view:?}"
        );
    }
}

#[test]
fn the_words_view_still_shows_the_operand_of_a_parameter_expansion() {
    let view = normalise_for_hazard_words("kubectl ${X:-delete} ns prod");
    let words = words_of(&view);
    for want in ["kubectl", "_", "delete", "ns", "prod"] {
        assert!(
            words.contains(&want),
            "{want:?} should be a word of {view:?}"
        );
    }
}

#[test]
fn separators_inside_a_substitution_do_not_split_the_outer_segment() {
    for text in [
        "ls $(echo a; echo b | wc -l && echo c) ; ls",
        "ls `echo a; echo b | wc -l && echo c` ; ls",
        "ls <(echo a; echo b | wc -l && echo c) ; ls",
    ] {
        let view = normalise_for_hazard_words(text);
        assert_eq!(
            view.matches(';').count(),
            1,
            "only the outer `;` is left in {view:?} (from {text:?})"
        );
        assert!(
            !view.contains('|') && !view.contains('&'),
            "no `|` or `&` is left in {view:?} (from {text:?})"
        );
        let words = words_of(&view);
        for want in ["echo", "wc", "a", "b"] {
            assert!(
                words.contains(&want),
                "{want:?} should be a word of {view:?}"
            );
        }
    }
}

#[test]
fn the_words_view_closer_skips_a_quoted_paren() {
    for text in [
        r#"kubectl $(echo ")"; echo x) delete ns prod"#,
        r#"kubectl $(echo ')'; echo x) delete ns prod"#,
        r#"kubectl $(echo \); echo x) delete ns prod"#,
    ] {
        let view = normalise_for_hazard_words(text);
        assert!(
            !view.contains(';'),
            "the `;` inside the substitution must not survive in {view:?} (from {text:?})"
        );
        let segment = segment_with(&view, "kubectl")
            .unwrap_or_else(|| panic!("a segment with kubectl in {view:?}"));
        assert!(
            words_of(segment).contains(&"delete"),
            "`delete` must stay in kubectl's segment: {view:?} (from {text:?})"
        );
    }
}

#[test]
fn the_words_view_closer_skips_a_quoted_brace() {
    let text = r#"kubectl ${X:-"}"; echo y} delete ns prod"#;
    let view = normalise_for_hazard_words(text);
    let segment = segment_with(&view, "kubectl")
        .unwrap_or_else(|| panic!("a segment with kubectl in {view:?}"));
    assert!(
        words_of(segment).contains(&"delete"),
        "`delete` must stay in kubectl's segment: {view:?}"
    );
    assert_eq!(destructive_patterns(text), ["kubectl delete"]);
}

#[test]
fn an_escaped_backtick_does_not_close_a_backtick_pair() {
    let text = r#"kubectl `echo \`;echo x` delete ns prod"#;
    let view = normalise_for_hazard_words(text);
    assert!(
        !view.contains(';'),
        "the `;` between the escaped and the real backtick is inside the pair: {view:?}"
    );
    let segment = segment_with(&view, "kubectl")
        .unwrap_or_else(|| panic!("a segment with kubectl in {view:?}"));
    assert!(
        words_of(segment).contains(&"delete"),
        "`delete` must stay in kubectl's segment: {view:?}"
    );
}

#[test]
fn an_unbalanced_opener_is_dropped_and_what_follows_stays_visible() {
    let view = normalise_for_hazard_words("kubectl --context $(echo x delete ns y");
    let segment = segment_with(&view, "kubectl")
        .unwrap_or_else(|| panic!("a segment with kubectl in {view:?}"));
    assert!(words_of(segment).contains(&"delete"), "{view:?}");
}

// ── brace groups glued to a word ──────────────────────────────────────────────
//
// `r{m..m}` is `rm` to a shell and nothing a text rule can follow: it fails toward the sheet (a production
// pane asks first) instead of expanding. A group alone as a word (`ls {a,b}`), a quoted or escaped one and
// `${…}` are not it. `file{1,2}.txt` and `cp f{,.bak}` ARE glued, so they ask in production too: the documented
// cost of failing toward confirmation.

#[test]
fn a_brace_expansion_glued_to_a_word_is_a_brace_glued_word() {
    for command in [
        "r{m..m} -rf /x",
        "{r..r}m -rf /x",
        "{r,}m -rf /x",
        "r{m,} -rf /x",
        "kubectl d{e..e}lete ns prod",
        "terraform d{e..e}stroy -auto-approve",
        "aws s3 r{m..m} s3://b --recursive",
        "kill -{9..9} 1",
        "{s,}hred -u old.log",
        "redis-cli flush{a..a}ll",
        "rm -{r,f} /x",
        "cp file{,.bak}",
        "ls file{1,2}.txt",
        "echo a{b,c}d",
        "echo x{1..3}",
        // glued after the closing brace by something that is not a separator or a redirection
        "ls {a,b}/c",
        // a quote counts as glue
        r#"echo "x"{a,b}"#,
        "echo 'x'{a,b}",
        // the quoted argument of a command wrapper is analysed as live code
        "bash -c 'ls file{1,2}.txt'",
        "ssh prod-host 'ls file{1,2}.txt'",
        r#"sh -c "cp f{,.bak}""#,
    ] {
        assert!(
            brace_glued_word(command),
            "{command:?} is a brace-glued word"
        );
    }
}

#[test]
fn a_brace_group_that_is_not_glued_or_not_an_expansion_or_not_live_is_not_a_brace_glued_word() {
    for command in [
        // a group alone as a word
        "ls {a,b}",
        "echo {a,b} x",
        "ls {1..3}",
        "{rm,-rf,/x}",
        "kubectl {delete,} ns prod",
        // glued only to a separator, a redirection or a parenthesis
        "ls {a,b};ls",
        "ls {a,b}|wc -l",
        "cat <{a,b}",
        "echo ({a,b})",
        // a parameter expansion
        "echo ${HOME}",
        "echo ${X:-a,b}",
        "echo ${X:-1..3}",
        // not a brace expansion: no comma and no `..` in the body
        "xargs -I{} rm {}",
        r"find . -exec rm {} \;",
        "echo a{b}c",
        "echo x{}y",
        // quoted (a quote that is not a command wrapper's argument) or escaped
        "jq '{a,b}' f.json",
        "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
        "aws ec2 describe-instances --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'",
        r"echo \{a,b\}x",
        "echo 'r{m,}'",
        r#"echo "{a,b}x""#,
        "echo hello",
    ] {
        assert!(
            !brace_glued_word(command),
            "{command:?} is not a brace-glued word"
        );
    }
}

#[test]
fn an_escape_quoted_word_is_an_ansi_c_quote_with_a_backslash() {
    for command in [
        r"echo $'\x72m' -rf /",
        r"$'\x72\x6d' -rf /var/lib/mysql",
        r"kubectl $'\x64elete' ns prod",
        r"echo $'a\tb'",
    ] {
        assert!(escape_quoted_word(command), "{command:?}");
    }
    for command in ["echo $'abc'", "ls -la", "echo hello", r"echo '$\x72'"] {
        assert!(!escape_quoted_word(command), "{command:?}");
    }
}

#[test]
fn a_production_pane_asks_for_a_destructive_match_an_escape_quoted_word_or_a_brace_glued_word() {
    // Each of the three on its own, with no destructive match for the last two.
    assert!(asks_in_production("rm -rf x"));
    assert!(destructive_patterns(r"echo $'\x72m' -rf /").is_empty());
    assert!(asks_in_production(r"echo $'\x72m' -rf /"));
    assert!(destructive_patterns("r{m..m} -rf /x").is_empty());
    assert!(asks_in_production("r{m..m} -rf /x"));
    assert!(destructive_patterns("ls file{1,2}.txt").is_empty());
    assert!(asks_in_production("ls file{1,2}.txt"));
    // and none of them
    for command in [
        "ls -la",
        "echo hello",
        "echo ${HOME}",
        "ls {a,b}",
        "echo 'r{m,}'",
        "jq '{a,b}' f.json",
        "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
        "mysql -e 'SELECT id FROM jobs WHERE created_at > NOW() - INTERVAL 1 DAY'",
        "last reboot | head",
    ] {
        assert!(!asks_in_production(command), "{command:?} does not ask");
    }
}

// ── pulumi and an aws ecs service scaled to a signed zero ─────────────────────

#[test]
fn pulumi_down_stack_rm_and_state_delete_are_terraform_destroys_and_the_read_only_verbs_are_not() {
    for command in [
        "pulumi down",
        "pulumi down --yes",
        "pulumi stack rm",
        "pulumi stack rm --yes",
        "pulumi state delete",
        "pulumi destroy --yes",
    ] {
        assert_eq!(
            destructive_patterns(command),
            ["terraform destroy"],
            "{command}"
        );
    }
    assert_none_match(&[
        "pulumi up",
        "pulumi stack ls",
        "pulumi preview",
        "pulumi stack output",
    ]);
}

#[test]
fn an_ecs_service_scaled_to_a_signed_zero_is_labelled_and_a_positive_count_is_not() {
    for count in [
        "--desired-count +0",
        "--desired-count -0",
        "--desired-count=+0",
        "--desired-count=-0",
    ] {
        let command = format!("aws ecs update-service --cluster c --service s {count}");
        assert_eq!(
            destructive_patterns(&command),
            ["aws delete/terminate"],
            "{command}"
        );
    }
    for count in [
        "--desired-count 2",
        "--desired-count +2",
        "--desired-count=+2",
        "--desired-count 10",
    ] {
        let command = format!("aws ecs update-service --cluster c --service s {count}");
        assert_none_match(&[command.as_str()]);
    }
}

// ── a `>` inside quotes is not a redirection ──────────────────────────────────
//
// Except in the quoted argument of a command wrapper (a shell, `eval`, `ssh`, `mosh`, `parallel`, `watch`, `su`,
// `script`, `flock`, `runuser`): that string runs as code, with its own quotes tracked again. A `>` in a `$(…)`
// or backticks inside a double-quoted string is live too, and an unterminated quote counts as unquoted.

#[test]
fn a_greater_than_inside_quotes_is_not_a_truncating_redirection() {
    assert_none_match(&[
        "mysql -e 'SELECT id FROM jobs WHERE created_at > NOW() - INTERVAL 1 DAY'",
        r#"mysql -e "SELECT id FROM jobs WHERE attempts >= 3""#,
        r#"php artisan tinker --execute='App\Models\Job::where("created_at", ">", now()->subDay())->count()'"#,
        "jq '.[] | select(.requests > 100)' stats.json",
        "awk '$9 >= 500 {print $7}' access.log",
        "echo x '>' y",
        // a quote nested inside a wrapper's argument is a quote again
        r#"bash -c "mysql -e 'select 1 > 0'""#,
        r#"ssh h 'mysql -e "select 1 > 0"'"#,
    ]);
}

#[test]
fn a_greater_than_in_a_command_wrappers_quoted_argument_or_outside_quotes_is_still_a_truncation() {
    assert_all_match(
        "> file",
        &[
            "bash -c 'echo x > f'",
            r#"sh -c "cat y > f""#,
            "ssh h 'echo x > f'",
            "eval 'echo x > f'",
            "awk $3 > 80 f",
            "parallel 'echo {} > f' ::: a b",
            "xargs -I{} sh -c 'echo {} > out.txt'",
            "watch -n 5 'date > f'",
            "su deploy -c 'echo x > f'",
            "echo x > 'f'",
            // `$(…)` and backticks inside a double-quoted string run
            r#"echo "$(date > f)""#,
            r#"echo "`date > f`""#,
            // an unterminated quote counts as unquoted
            "echo 'a > b",
        ],
    );
    assert_eq!(
        destructive_patterns("xargs -I{} sh -c 'echo {} > out.txt'"),
        ["> file"]
    );
}

// ── stop and shutdown only where a command can start ──────────────────────────
//
// `shutdown`, `reboot`, `halt`, `poweroff`, `systemctl … stop|disable|mask` and `service … stop` count in COMMAND
// POSITION of a segment: first, after prefix words (an assignment, `sudo`, `env`, `nice` and its number,
// `timeout` and its duration, `nohup`, `exec`, `command`, `time`, an option and the argument of one that takes
// one), or after a wrapper word earlier in the segment (a shell, `eval`, `ssh`, `xargs`, `parallel`, `watch`,
// `su`, `find -exec`, `kubectl|docker exec|run`, …). Merely naming one (`last reboot`, `grep shutdown`) does not.

#[test]
fn a_shutdown_word_that_is_only_an_argument_does_not_stop_anything() {
    assert_none_match(&[
        "last reboot | head",
        "grep -i shutdown /var/log/syslog",
        "journalctl -b | grep -i poweroff",
        "echo reboot",
        "echo systemctl stop nginx",
        "man shutdown",
        "grep -rn 'service nginx stop' /etc/init.d",
        "systemctl status nginx",
        "service nginx status",
        "systemctl restart nginx",
        "systemctl is-active nginx",
    ]);
}

#[test]
fn a_shutdown_program_in_command_position_is_labelled_wherever_the_prefix_words_put_it() {
    for command in [
        "shutdown -h now",
        "sudo reboot",
        "/sbin/shutdown -h now",
        "FOO=1 reboot",
        "timeout 5 halt",
        "timeout 5s halt",
        "sudo -u root systemctl stop nginx",
        "nice -n 5 poweroff",
        "ssh prod-host reboot",
        "bash -c 'sudo reboot'",
        "xargs -n1 systemctl disable",
        "service nginx stop",
        "sudo service nginx stop",
        "systemctl --user mask foo",
        "sudo systemctl disable --now nginx",
        "ls; reboot",
        "kubectl exec p -- reboot",
        "halt",
        "poweroff",
    ] {
        assert_eq!(
            destructive_patterns(command),
            ["stop/shutdown"],
            "{command}"
        );
    }
}

// ── the read-only corpus ──────────────────────────────────────────────────────
//
// `commands`: sixty-one realistic read-only production commands. None of them may ask in a production pane,
// none may carry a destructive label, and every one must be stageable in a remote pane. A new rule that trips
// one of them is a false positive: fix the rule, not the row. `known_asks`: read-only commands the sheet
// asks about anyway (each row says why). They must keep asking, so a fix that makes one quiet is noticed and
// the row moves to `commands`; the corpus stays an honest account of what the sheet costs.

#[test]
fn the_read_only_corpus_never_asks_in_production_and_never_carries_a_label() {
    let corpus: serde_json::Value =
        serde_json::from_str(READ_ONLY_CORPUS).expect("read_only_corpus.json");
    let rows = corpus["commands"].as_array().expect("commands is an array");
    let known = corpus["known_asks"]
        .as_array()
        .expect("known_asks is an array");
    assert_eq!(rows.len(), 61, "the corpus is exactly 61 commands");

    let mut names = std::collections::BTreeSet::new();
    let mut texts = std::collections::BTreeSet::new();
    for row in rows {
        assert_eq!(
            row["expect"], "ok",
            "{}: a commands row expects ok",
            row["name"]
        );
        assert!(
            names.insert(row["name"].as_str().unwrap()),
            "duplicate name {}",
            row["name"]
        );
        assert!(
            texts.insert(row["text"].as_str().unwrap()),
            "duplicate text {}",
            row["text"]
        );
    }

    let mut false_positives = 0;
    for row in rows {
        let text = row["text"].as_str().unwrap();
        if asks_in_production(text) || !destructive_patterns(text).is_empty() {
            false_positives += 1;
        }
    }
    let ok_rows = rows.len();
    println!(
        "read-only corpus: {ok_rows} ok rows checked, {false_positives} false positives, {} known asks",
        known.len()
    );
    assert_eq!(
        false_positives,
        0,
        "{ok_rows} ok rows checked, {false_positives} false positives (must be 0), {} known asks",
        known.len()
    );
    for row in rows {
        let text = row["text"].as_str().unwrap();
        assert!(
            !asks_in_production(text),
            "{}: {text:?} is read-only and must not ask in production ({ok_rows} ok rows checked, {} known asks)",
            row["name"],
            known.len()
        );
        assert_eq!(
            destructive_patterns(text),
            Vec::<&str>::new(),
            "{}: {text:?} must carry no label ({ok_rows} ok rows checked, {} known asks)",
            row["name"],
            known.len()
        );
        assert_eq!(
            validate_command_in(text, true),
            Ok(()),
            "{}: {text:?} must be stageable in a remote pane",
            row["name"]
        );
    }

    assert!(
        known.len() >= 4,
        "the corpus names at least 4 known asks, has {} ({ok_rows} ok rows checked, {false_positives} false positives)",
        known.len()
    );
    for row in known {
        let text = row["text"].as_str().unwrap();
        assert_eq!(
            row["expect"], "sheet",
            "{}: a known_asks row expects sheet",
            row["name"]
        );
        assert!(
            row["reason"].as_str().is_some_and(|r| !r.is_empty()),
            "{}: a known ask says why",
            row["name"]
        );
        assert!(
            names.insert(row["name"].as_str().unwrap()),
            "duplicate name {}",
            row["name"]
        );
        assert!(texts.insert(text), "duplicate text {}", row["text"]);
        assert!(
            asks_in_production(text),
            "{}: {text:?} is a known ask and must still ask in production; if it no longer does, move it to commands ({ok_rows} ok rows checked, {} known asks)",
            row["name"],
            known.len()
        );
    }
}
