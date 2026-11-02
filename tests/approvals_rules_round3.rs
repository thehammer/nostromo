//! "Allow for this session" rules, round 3 review holes, pinned through the public matcher
//! (`nostromo::approvals::rules`). Nothing here reads the matcher's internals.
//!
//! - A. An exact rule is offered only for a flag the matcher positively knows to be safe for
//!   that command. Anything else (long options, `--`, a short letter that reads or writes a
//!   file or runs a program, set-the-clock forms) gets no candidate at all.
//! - B. An exact rule for a file-changing command is pinned to where its paths pointed when
//!   the human chose it: a directory swapped for a symlink afterwards is no match, and a
//!   path that already runs through a symlink is never offered.
//! - C. More startup files and credential stores under the home directory are protected.
//!
//! Every test says which hole it pins. All of them use a real temporary directory as the
//! home directory, so symlinks are real.

use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use nostromo::approvals::request::{AskRule, PermissionRequest, SettingsSource};
use nostromo::approvals::rules::{candidates, matches, Candidate, CandidateKind, SessionRule};
use serde_json::json;
use tempfile::TempDir;

// ── helpers ───────────────────────────────────────────────────────────────────

struct NoSettings;
impl SettingsSource for NoSettings {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        Vec::new()
    }
}

fn cmd(command: &str) -> PermissionRequest {
    let v = json!({
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "input": { "command": command, "description": "d" },
        "tool_use_id": "toolu_1",
        "decision_reason_type": "rule",
    });
    PermissionRequest::from_cli(&v).expect("parses")
}

/// A fake home directory (canonical, so a platform whose temp dir is itself behind a
/// symlink does not look like a symlinked home) plus a second directory outside it.
struct World {
    _home_guard: TempDir,
    _elsewhere_guard: TempDir,
    home: PathBuf,
    elsewhere: PathBuf,
}

/// Substrings the matcher refuses anywhere in a command; a random temp name must not
/// happen to contain one.
const UNLUCKY: &[&str] = &[
    "tmux", "ecs", "ssm", "ssh", "aws", "scp", "sudo", "git", "vol", "kube", "mosh",
];

fn fresh_dir() -> (TempDir, PathBuf) {
    loop {
        let guard = tempfile::Builder::new()
            .prefix("r3")
            .tempdir()
            .expect("temp dir");
        let real = fs::canonicalize(guard.path()).expect("canonical temp dir");
        let lower = real.to_string_lossy().to_ascii_lowercase();
        if !UNLUCKY.iter().any(|s| lower.contains(s)) {
            return (guard, real);
        }
    }
}

impl World {
    fn new() -> Self {
        let (home_guard, home) = fresh_dir();
        let (elsewhere_guard, elsewhere) = fresh_dir();
        fs::create_dir_all(home.join("proj")).expect("proj");
        Self {
            _home_guard: home_guard,
            _elsewhere_guard: elsewhere_guard,
            home,
            elsewhere,
        }
    }

    /// `<home>/<rel>` as text, for building commands.
    fn p(&self, rel: &str) -> String {
        self.home.join(rel).to_string_lossy().into_owned()
    }

    fn mkdir(&self, rel: &str) {
        fs::create_dir_all(self.home.join(rel)).expect("mkdir");
    }

    fn touch(&self, rel: &str) {
        fs::write(self.home.join(rel), b"x").expect("touch");
    }

    /// Replace the directory (or file) `<home>/<rel>` by a symlink to `target`.
    fn swap_for_symlink(&self, rel: &str, target: &Path) {
        let at = self.home.join(rel);
        match fs::symlink_metadata(&at) {
            Ok(m) if m.is_dir() => fs::remove_dir_all(&at).expect("remove dir"),
            Ok(_) => fs::remove_file(&at).expect("remove file"),
            Err(_) => {}
        }
        symlink(target, &at).expect("symlink");
    }

    fn offered(&self, command: &str) -> Vec<Candidate> {
        let req = cmd(command);
        let reason = req.reason(Some(&self.home), &NoSettings);
        candidates(&req, &reason, &self.home, Some(&self.home))
    }

    /// The exact rule the human would get by choosing the first candidate.
    fn grant_exact(&self, command: &str) -> SessionRule {
        let cands = self.offered(command);
        let first = cands
            .first()
            .unwrap_or_else(|| panic!("no candidate offered for `{command}`"));
        assert_eq!(first.kind, CandidateKind::Exact, "{command}");
        SessionRule::from_candidate(first, None, 0, "req", "win")
    }

    fn allows(&self, rule: &SessionRule, command: &str) -> bool {
        let req = cmd(command);
        let reason = req.reason(Some(&self.home), &NoSettings);
        matches(rule, &req, reason.kind, &self.home, Some(&self.home))
    }
}

/// Commands from `commands` that are offered something, or (`want_offered`) that are not.
fn wrongly_decided(world: &World, commands: &[&str], want_offered: bool) -> Vec<String> {
    commands
        .iter()
        .filter(|c| {
            let offered = world.offered(c);
            if want_offered {
                // An exact rule for exactly this text.
                !offered
                    .iter()
                    .any(|o| o.kind == CandidateKind::Exact && o.rule_text == format!("Bash({c})"))
            } else {
                !offered.is_empty()
            }
        })
        .map(|c| (*c).to_owned())
        .collect()
}

fn assert_never_offered(commands: &[&str]) {
    let world = World::new();
    let wrong = wrongly_decided(&world, commands, false);
    assert!(wrong.is_empty(), "these were offered a rule: {wrong:?}");
}

fn assert_offered_exact(commands: &[&str]) {
    let world = World::new();
    let wrong = wrongly_decided(&world, commands, true);
    assert!(wrong.is_empty(), "these got no exact rule: {wrong:?}");
}

// ── A. strict flag allowlist for exact rules ──────────────────────────────────

// Round 3, ripgrep: `--hostname-bin` and `--pre` run a program; the abbreviations and
// extensions a long-option parser accepts (`--pr`, `--hostname`) reach the same options.
#[test]
fn ripgrep_options_that_run_a_program_get_no_rule_in_any_spelling() {
    assert_never_offered(&[
        "rg --hostname-bin=./hn foo",
        "rg --pr x",
        "rg --pre cat x",
        "rg --hostname x",
    ]);
}

// Round 3, sort: `--files0-from` reads names from a file, `--output` writes one; both
// abbreviate. Absolute operands, so the refusal is about the flag and not a relative path.
#[test]
fn sort_options_that_read_a_file_list_or_write_a_file_get_no_rule() {
    assert_never_offered(&[
        "sort --files0-from=/tmp/f",
        "sort --files0 /tmp/f",
        "sort --output=/tmp/x /tmp/f",
        "sort --out=/tmp/x /tmp/f",
    ]);
}

// Round 3, jq: `-f FILE` loads a program from disk; jq is dropped from the allowlist
// entirely rather than flag-filtered.
#[test]
fn jq_gets_no_rule_whatever_its_arguments() {
    assert_never_offered(&["jq -f f.jq", "jq . /tmp/a", "jq -r .a /tmp/a", "jq -n 1"]);
}

// Round 3, tree: `-R` rewrites listings into files in every directory, `-o` writes one.
#[test]
fn tree_options_that_write_files_get_no_rule() {
    assert_never_offered(&["tree -R /tmp/x", "tree -o /tmp/x"]);
}

// Round 3, date: `-s` and the positional `MMDDhhmm` form set the system clock.
#[test]
fn date_forms_that_set_the_clock_get_no_rule() {
    assert_never_offered(&["date -s 1", "date 1102120026"]);
}

// Round 3, file: `-C` compiles a magic file, writing a `.mgc`.
#[test]
fn file_compile_option_gets_no_rule() {
    assert_never_offered(&["file -C"]);
}

// Round 3, grep: `--include` and its kin are long options, none of which is on the list.
#[test]
fn grep_long_option_gets_no_rule() {
    assert_never_offered(&["grep --include=x foo /tmp/a"]);
}

// Round 3, `--`: ending option parsing changes what every later word means, so the bare
// separator is never accepted.
#[test]
fn the_bare_double_dash_gets_no_rule() {
    assert_never_offered(&["ls -- x", "ls -- /tmp/a", "grep -- foo /tmp/a", "rg -- foo"]);
}

// Round 3, long forms: abbreviated and `=` spellings of any long option are refused, even
// for options that are harmless in full.
#[test]
fn abbreviated_and_equals_long_options_get_no_rule() {
    assert_never_offered(&[
        "grep --ignore-c foo /tmp/a",
        "grep --max-count=1 foo /tmp/a",
        "ls --color=auto /tmp/a",
        "du --max-depth=1 /tmp/a",
    ]);
}

// Round 3, short groups: one refused letter anywhere in a combined group refuses the group.
#[test]
fn a_combined_short_group_with_a_refused_letter_gets_no_rule() {
    assert_never_offered(&["grep -ion foo /tmp/a", "ls -lR /tmp/a"]);
}

// Round 3, lsof: `-i` (and the rest of lsof) is dropped from the allowlist.
#[test]
fn lsof_gets_no_rule() {
    assert_never_offered(&["lsof -i", "lsof /tmp/a", "lsof -p 1"]);
}

// Round 3, process listings: `-o` formats and `-w` widens in ways that are not on the
// allowlist; pgrep `-o` is "oldest", not an output file, but still not allowed.
#[test]
fn process_listing_flags_outside_the_allowlist_get_no_rule() {
    assert_never_offered(&["pgrep -o x", "ps -o pid", "ps aux -w"]);
}

// Round 3, xxd: `-r` reverses a dump into a binary file. Absolute operand, so the refusal
// is about the flag.
#[test]
fn xxd_reverse_gets_no_rule() {
    assert_never_offered(&["xxd -r /tmp/a"]);
}

// Round 3, head: `-f` is not a head flag; unknown letters are refused, not passed through.
#[test]
fn head_with_an_unknown_flag_gets_no_rule() {
    assert_never_offered(&["head -f"]);
}

// Round 3, uname: only `-a` is allowed; `-s` and friends are not on the list.
#[test]
fn uname_with_a_flag_other_than_a_gets_no_rule() {
    assert_never_offered(&["uname -s"]);
}

// The positive controls for A: the allowlist is not so strict that ordinary reads vanish.
#[test]
fn search_and_sort_commands_with_allowed_flags_still_get_an_exact_rule() {
    assert_offered_exact(&[
        "grep -inr foo /tmp/a",
        "rg -i foo",
        "sort -n /tmp/a",
        "diff -u /tmp/a /tmp/b",
    ]);
}

#[test]
fn listing_and_counting_commands_with_allowed_flags_still_get_an_exact_rule() {
    assert_offered_exact(&[
        "ls -lah /tmp/a",
        "wc -l /tmp/a",
        "head -n 5 /tmp/a",
        "tail -n 20 /tmp/a",
        "du -sh /tmp/a",
        "du -d 1 /tmp/a",
        "tree -L 2 /tmp/a",
        "tree -a /tmp/a",
    ]);
}

#[test]
fn system_inspection_commands_with_allowed_flags_still_get_an_exact_rule() {
    assert_offered_exact(&[
        "ps aux",
        "ps -ef",
        "df -h",
        "uname -a",
        "pgrep -fl foo",
        "date +x",
        "pwd",
        "whoami",
        "sw_vers",
        "echo hi",
    ]);
}

// ── B. symlink-pinned exact rules ─────────────────────────────────────────────

// Round 3, swap after grant: `rm -rf <home>/proj/fixtures/x` was chosen while `fixtures`
// was a real directory; once `fixtures` points at the home directory the same text deletes
// something else.
#[test]
fn rm_rule_stops_matching_when_the_parent_directory_becomes_a_symlink_to_home() {
    let w = World::new();
    w.mkdir("proj/fixtures");
    let command = format!("rm -rf {}", w.p("proj/fixtures/x"));
    let rule = w.grant_exact(&command);
    assert!(w.allows(&rule, &command), "sanity: matches before the swap");

    w.swap_for_symlink("proj/fixtures", &w.home);

    assert!(!w.allows(&rule, &command));
}

// Round 3, swap after grant, elsewhere: the same swap, to a directory outside the home.
#[test]
fn rm_rule_stops_matching_when_the_parent_directory_becomes_a_symlink_elsewhere() {
    let w = World::new();
    w.mkdir("proj/fixtures");
    let command = format!("rm -rf {}", w.p("proj/fixtures/x"));
    let rule = w.grant_exact(&command);

    w.swap_for_symlink("proj/fixtures", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

// Round 3, swap after grant, higher up: any ancestor below the home counts, not only the
// immediate parent.
#[test]
fn rm_rule_stops_matching_when_a_higher_ancestor_becomes_a_symlink() {
    let w = World::new();
    w.mkdir("proj/fixtures");
    let command = format!("rm -rf {}", w.p("proj/fixtures/x"));
    let rule = w.grant_exact(&command);

    w.swap_for_symlink("proj", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

#[test]
fn cp_rule_stops_matching_when_the_destination_directory_becomes_a_symlink() {
    let w = World::new();
    w.touch("proj/src");
    w.mkdir("proj/dst");
    let command = format!("cp {} {}", w.p("proj/src"), w.p("proj/dst/out"));
    let rule = w.grant_exact(&command);
    assert!(w.allows(&rule, &command), "sanity: matches before the swap");

    w.swap_for_symlink("proj/dst", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

// Round 3, swap after grant: the source side of a copy is pinned as well.
#[test]
fn cp_rule_stops_matching_when_the_source_directory_becomes_a_symlink() {
    let w = World::new();
    w.mkdir("proj/srcdir");
    w.touch("proj/srcdir/s");
    w.mkdir("proj/dst");
    let command = format!("cp {} {}", w.p("proj/srcdir/s"), w.p("proj/dst/out"));
    let rule = w.grant_exact(&command);

    w.swap_for_symlink("proj/srcdir", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

#[test]
fn mv_rule_stops_matching_when_the_destination_directory_becomes_a_symlink() {
    let w = World::new();
    w.touch("proj/a");
    w.mkdir("proj/dst");
    let command = format!("mv {} {}", w.p("proj/a"), w.p("proj/dst/b"));
    let rule = w.grant_exact(&command);
    assert!(w.allows(&rule, &command), "sanity: matches before the swap");

    w.swap_for_symlink("proj/dst", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

#[test]
fn mkdir_rule_stops_matching_when_the_parent_directory_becomes_a_symlink() {
    let w = World::new();
    w.mkdir("proj/dst");
    let command = format!("mkdir {}", w.p("proj/dst/new"));
    let rule = w.grant_exact(&command);
    assert!(w.allows(&rule, &command), "sanity: matches before the swap");

    w.swap_for_symlink("proj/dst", &w.elsewhere);

    assert!(!w.allows(&rule, &command));
}

// Round 3, symlink already in the chain at grant time: nothing is offered, because the
// rule could not say where the path really points.
#[test]
fn rm_of_a_path_through_an_existing_symlinked_directory_gets_no_exact_rule() {
    let w = World::new();
    w.swap_for_symlink("proj/link", &w.elsewhere);

    let offered = w.offered(&format!("rm -rf {}", w.p("proj/link/x")));

    assert!(offered.is_empty(), "{offered:?}");
}

#[test]
fn cp_destination_through_an_existing_symlinked_directory_gets_no_exact_rule() {
    let w = World::new();
    w.touch("proj/src");
    w.swap_for_symlink("proj/link", &w.elsewhere);

    let offered = w.offered(&format!("cp {} {}", w.p("proj/src"), w.p("proj/link/out")));

    assert!(offered.is_empty(), "{offered:?}");
}

#[test]
fn cp_source_through_an_existing_symlinked_directory_gets_no_exact_rule() {
    let w = World::new();
    w.mkdir("proj/dst");
    w.swap_for_symlink("proj/link", &w.elsewhere);

    let offered = w.offered(&format!(
        "cp {} {}",
        w.p("proj/link/s"),
        w.p("proj/dst/out")
    ));

    assert!(offered.is_empty(), "{offered:?}");
}

// Round 3, final component: `cp SRC DST` follows a symlink at DST, so a destination that
// already is one writes through it.
#[test]
fn cp_to_a_destination_that_is_already_a_symlink_gets_no_exact_rule() {
    let w = World::new();
    w.touch("proj/src");
    w.mkdir("proj/dst");
    fs::write(w.elsewhere.join("target"), b"t").expect("target");
    w.swap_for_symlink("proj/dst/out", &w.elsewhere.join("target"));

    let offered = w.offered(&format!("cp {} {}", w.p("proj/src"), w.p("proj/dst/out")));

    assert!(offered.is_empty(), "{offered:?}");
}

// Round 3, final component swapped after grant (the destination did not exist yet).
#[test]
fn cp_rule_stops_matching_when_a_missing_destination_becomes_a_symlink() {
    let w = World::new();
    w.touch("proj/src");
    w.mkdir("proj/dst");
    let command = format!("cp {} {}", w.p("proj/src"), w.p("proj/dst/out"));
    let rule = w.grant_exact(&command);
    fs::write(w.elsewhere.join("target"), b"t").expect("target");

    w.swap_for_symlink("proj/dst/out", &w.elsewhere.join("target"));

    assert!(!w.allows(&rule, &command));
}

// Round 3, final component swapped after grant (the destination was a regular file).
#[test]
fn cp_rule_stops_matching_when_an_existing_destination_file_becomes_a_symlink() {
    let w = World::new();
    w.touch("proj/src");
    w.mkdir("proj/dst");
    w.touch("proj/dst/out");
    let command = format!("cp {} {}", w.p("proj/src"), w.p("proj/dst/out"));
    let rule = w.grant_exact(&command);
    fs::write(w.elsewhere.join("target"), b"t").expect("target");

    w.swap_for_symlink("proj/dst/out", &w.elsewhere.join("target"));

    assert!(!w.allows(&rule, &command));
}

// The pin must not make a rule useless: nothing changed, so the same request matches.
#[test]
fn an_unchanged_rm_cp_mv_and_mkdir_each_still_match_their_rule() {
    let w = World::new();
    w.mkdir("proj/fixtures");
    w.mkdir("proj/dst");
    w.touch("proj/src");
    w.touch("proj/a");
    let commands = [
        format!("rm -rf {}", w.p("proj/fixtures/x")),
        format!("cp {} {}", w.p("proj/src"), w.p("proj/dst/out")),
        format!("mv {} {}", w.p("proj/a"), w.p("proj/dst/b")),
        format!("mkdir {}", w.p("proj/dst/new")),
    ];

    let refused: Vec<&String> = commands
        .iter()
        .filter(|c| {
            let rule = w.grant_exact(c);
            !w.allows(&rule, c)
        })
        .collect();

    assert!(refused.is_empty(), "{refused:?}");
}

// A path that does not exist yet (the leaf of an rm in a real directory) is still offered
// and still matches.
#[test]
fn rm_of_a_file_that_does_not_exist_yet_is_offered_and_matches() {
    let w = World::new();
    w.mkdir("proj/fixtures");
    let command = format!("rm -rf {}", w.p("proj/fixtures/not-yet"));

    let rule = w.grant_exact(&command);

    assert!(w.allows(&rule, &command));
}

// Legit /tmp (a symlink to /private/tmp on macOS, a real directory elsewhere): the symlink
// check must not turn this into no candidate, and the rule must keep matching.
#[test]
fn rm_in_tmp_gets_an_exact_rule_and_no_prefix_rule() {
    let w = World::new();
    let offered = w.offered("rm -rf /tmp/nostromo-r3-x");

    let kinds: Vec<CandidateKind> = offered.iter().map(|c| c.kind).collect();

    assert_eq!(kinds, [CandidateKind::Exact], "{offered:?}");
}

#[test]
fn rm_in_tmp_rule_still_matches_after_the_grant() {
    let w = World::new();
    let command = "rm -rf /tmp/nostromo-r3-x";
    let rule = w.grant_exact(command);

    assert!(w.allows(&rule, command));
}

// ── C. protected places under the home directory ──────────────────────────────

const PROTECTED_TARGETS: &[&str] = &[
    ".zshenv",
    ".zlogin",
    ".zprofile",
    ".bash_profile",
    ".bashrc",
    ".profile",
    ".local/bin/x",
    ".cargo/x",
    ".git-credentials",
    ".pypirc",
    ".netrc",
    ".npmrc",
    ".config/x",
    ".docker/x",
    ".kube/x",
    "Library/LaunchAgents/x",
    "Library/Keychains/x",
];

fn protected_commands(w: &World, form: impl Fn(&World, &str) -> String) -> Vec<String> {
    PROTECTED_TARGETS
        .iter()
        .map(|t| format!("cp {} {}", form(w, "proj/x"), form(w, t)))
        .collect()
}

fn offered_anyway(w: &World, commands: &[String]) -> Vec<String> {
    commands
        .iter()
        .filter(|c| !w.offered(c).is_empty())
        .cloned()
        .collect()
}

// Round 3, protected home: shell startup files, credential stores and auto-run
// directories written through `cp` with absolute paths.
#[test]
fn cp_onto_a_startup_or_credential_file_by_absolute_path_gets_no_rule() {
    let w = World::new();
    let commands = protected_commands(&w, |w, rel| w.p(rel));

    let offered = offered_anyway(&w, &commands);

    assert!(offered.is_empty(), "offered: {offered:?}");
}

// The same targets spelled with `~/`.
#[test]
fn cp_onto_a_startup_or_credential_file_by_tilde_path_gets_no_rule() {
    let w = World::new();
    let commands = protected_commands(&w, |_, rel| format!("~/{rel}"));

    let offered = offered_anyway(&w, &commands);

    assert!(offered.is_empty(), "offered: {offered:?}");
}

// A neighbour that is not protected keeps working, in both spellings.
#[test]
fn cp_between_ordinary_project_paths_still_gets_an_exact_rule() {
    let w = World::new();
    w.touch("proj/x");
    w.mkdir("proj/dst");
    let absolute = format!("cp {} {}", w.p("proj/x"), w.p("proj/dst/y"));
    let tilde = "cp ~/proj/x ~/proj/dst/y".to_owned();

    let offered = offered_anyway(&w, &[absolute.clone(), tilde.clone()]);

    // `offered_anyway` lists those that DO get something; both should.
    assert_eq!(offered, [absolute, tilde]);
}
