//! H8 guards for the Huey eval harness: the eval bin must never be wired into
//! tests or CI (it calls a real model), every listed scenario ships its
//! fixtures, and the fixtures hold no private or work data.
//!
//! Std + toml + serde_json only. No network, no model, no `claude`.

use std::fs;
use std::path::{Path, PathBuf};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");
const EVAL_DIR: &str = "tests/fixtures/huey/eval";

const SCENARIOS: &[&str] = &[
    "sdk-not-used",
    "sdk-used",
    "three-unconfirmable",
    "general-essay",
    "want-less-and-ignore",
    "nothing-relates",
    "api-version-vs-bugfix",
    "breaking-sdk-no-interest",
    "follow-up-release",
    "php-two-machines",
    "typical-day",
    "minor-fixes-only-week",
    "simulation-2026-10-25",
];

fn root() -> PathBuf {
    PathBuf::from(ROOT)
}

fn files_under(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() {
            files_under(&p, out);
        } else {
            out.push(p);
        }
    }
}

fn all_files(dir: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    files_under(dir, &mut v);
    v.sort();
    v
}

#[test]
fn h8_1_the_eval_bin_is_never_referenced_by_tests_or_ci() {
    let needles = [
        concat!("nostromo", "-huey-eval"),
        concat!("nostromo", "_huey_eval"),
    ];
    let this_file = root().join("tests").join("huey_eval_guard.rs");
    let eval_fixtures = root().join(EVAL_DIR);

    let mut offenders = Vec::new();
    for top in ["tests", ".rwx", ".github"] {
        for path in all_files(&root().join(top)) {
            if path == this_file || path.starts_with(&eval_fixtures) {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            for needle in needles {
                if text.contains(needle) {
                    offenders.push(format!("{} contains {needle}", path.display()));
                }
            }
        }
    }
    assert!(offenders.is_empty(), "eval bin referenced: {offenders:#?}");

    let cargo: toml::Value =
        toml::from_str(&fs::read_to_string(root().join("Cargo.toml")).unwrap()).unwrap();
    let declared = cargo["bin"]
        .as_array()
        .expect("Cargo.toml has [[bin]] entries")
        .iter()
        .any(|b| {
            b["name"].as_str() == Some(needles[0])
                && b["path"].as_str() == Some("src/bin/nostromo_huey_eval.rs")
        });
    assert!(
        declared,
        "Cargo.toml must declare the eval [[bin]] with its path"
    );
}

#[test]
fn h8_2_every_listed_scenario_has_its_fixtures() {
    let base = root().join(EVAL_DIR);
    let mut problems = Vec::new();

    let need_file = |p: PathBuf, problems: &mut Vec<String>| {
        if !p.is_file() {
            problems.push(format!("missing file {}", p.display()));
            return None;
        }
        fs::read_to_string(&p).ok().or_else(|| {
            problems.push(format!("unreadable {}", p.display()));
            None
        })
    };
    let check_json = |p: PathBuf, problems: &mut Vec<String>| {
        if let Some(t) = need_file(p.clone(), problems) {
            if serde_json::from_str::<serde_json::Value>(&t).is_err() {
                problems.push(format!("invalid JSON {}", p.display()));
            }
        }
    };

    for name in SCENARIOS {
        let dir = base.join(name);
        if !dir.is_dir() {
            problems.push(format!("missing scenario dir {}", dir.display()));
            continue;
        }
        if let Some(t) = need_file(dir.join("expect.toml"), &mut problems) {
            if toml::from_str::<toml::Value>(&t).is_err() {
                problems.push(format!("invalid TOML {}/expect.toml", name));
            }
        }
        check_json(dir.join("pool.json"), &mut problems);

        let ctx = dir.join("context");
        if !ctx.is_dir() {
            problems.push(format!("missing context dir for {name}"));
        }
        if *name == "php-two-machines" {
            for m in ["machine-a", "machine-b"] {
                need_file(ctx.join(m).join("interests.md"), &mut problems);
                check_json(ctx.join(m).join("posture.json"), &mut problems);
            }
        } else {
            need_file(dir.join("interests.md"), &mut problems);
            check_json(dir.join("posture.json"), &mut problems);
        }
    }
    assert!(
        problems.is_empty(),
        "scenario fixtures incomplete: {problems:#?}"
    );
}

/// Email-looking `x@domain.tld` whose domain is not example.com / example.invalid.
fn foreign_email(text: &str) -> Option<String> {
    let is_dom = |c: char| c.is_ascii_alphanumeric() || c == '.' || c == '-';
    for (i, _) in text.match_indices('@') {
        let local_ok = text[..i]
            .chars()
            .next_back()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-');
        if !local_ok {
            continue;
        }
        let dom: String = text[i + 1..].chars().take_while(|c| is_dom(*c)).collect();
        let dom = dom.trim_end_matches('.').to_ascii_lowercase();
        if !dom.contains('.') {
            continue;
        }
        let ok = ["example.com", "example.invalid"]
            .iter()
            .any(|d| dom == *d || dom.ends_with(&format!(".{d}")));
        if !ok {
            return Some(format!("@{dom}"));
        }
    }
    None
}

#[test]
fn h8_2_fixtures_hold_no_private_or_work_data() {
    let banned = [
        "carefeed",
        "/users/",
        "/home/",
        "hammer",
        "thehammer",
        "sk-ant",
        "ghp_",
        "xox",
        "akia",
        "password",
        "secret",
        "api_key",
        "bearer",
    ];
    let mut hits = Vec::new();
    for path in all_files(&root().join(EVAL_DIR)) {
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let lower = text.to_ascii_lowercase();
        let rel = path.strip_prefix(root()).unwrap().display().to_string();
        for pat in banned {
            if lower.contains(pat) {
                hits.push(format!("{rel}: contains `{pat}`"));
            }
        }
        if let Some(e) = foreign_email(&text) {
            hits.push(format!("{rel}: email-looking `{e}` outside example.*"));
        }
    }
    assert!(
        hits.is_empty(),
        "private or work data in fixtures: {hits:#?}"
    );
}
