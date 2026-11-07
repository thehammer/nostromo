//! The repo-resident differential corpus: `tests/fixtures/terminal_staging/differential_corpus.json` holds a few
//! thousand generated commands, each with the Rust matcher's verdict for every field (`destructive`, `brace_glued`,
//! `escape_quoted`, `non_ascii`, `wildcard_command`, `asks_in_production`). Both suites assert every row, so the
//! Swift matcher is held to the Rust one across far more shapes than the hand-written `hazards.json` rows, combining
//! marks included, with no oracle process at test time.
//!
//! The commands are generated from a fixed seed out of the tokens below (verbs, wrappers, quotes, braces, wildcards,
//! substitutions, combining marks); the goldens are whatever the Rust matcher says when
//! `regenerate_the_differential_corpus` runs. A change of matcher behaviour that is on purpose is recorded by
//! running it (`cargo test --lib regenerate_the_differential_corpus -- --ignored`) and reviewing the fixture diff.

use crate::terminal::staging::destructive::{
    asks_in_production, brace_glued_word, contains_non_ascii, destructive_patterns,
    escape_quoted_word, wildcard_command_word,
};

const CORPUS: &str =
    include_str!("../../../../tests/fixtures/terminal_staging/differential_corpus.json");

/// The number of commands in the corpus.
const COUNT: usize = 3000;

const SEED: u64 = 0x5eed_2026_1107;

/// Command words, wrappers and prefix programs.
const HEADS: &[&str] = &[
    "rm",
    "/bin/rm",
    "RM",
    "kubectl",
    "helm",
    "terraform",
    "aws",
    "kill",
    "pkill",
    "systemctl",
    "reboot",
    "shutdown",
    "halt",
    "service",
    "dd",
    "mkfs.ext4",
    "shred",
    "find",
    "xargs",
    "parallel",
    "echo",
    "printf",
    "ls",
    "cat",
    "grep",
    "env",
    "sudo",
    "nice",
    "time",
    "command",
    "nohup",
    "exec",
    "bash",
    "sh",
    "eval",
    "ssh",
    "at",
    "batch",
    "source",
    ".",
    "watch",
    "cp",
    "tee",
    "mysql",
    "psql",
    "redis-cli",
    "docker",
    "git",
    "php",
    "case",
    "function",
    "if",
    "[",
    "/bin/r?",
    "r{m,}",
    "/sbin/reb??t",
    "*",
    "x=1",
    "r",
    "history",
    "true",
    "$SHELL",
    "`which bash`",
    "$(echo rm)",
];

/// Arguments, options, operands and shell punctuation that sits inside a segment.
const ARGS: &[&str] = &[
    "-rf",
    "-r",
    "-f",
    "-fr",
    "--force",
    "--recursive",
    "delete",
    "drain",
    "uninstall",
    "destroy",
    "ns",
    "prod",
    "x",
    "/x",
    "/etc/f",
    "-9",
    "-s",
    "-n",
    "-p",
    "-c",
    "-S",
    "-u",
    "deploy",
    "stop",
    "reboot",
    "nginx",
    "now",
    "h",
    "-i",
    "--split-string=rm",
    "-Sreboot",
    "-exec",
    "-execdir",
    "-delete",
    "-name",
    "{}",
    "\\;",
    ":::",
    "of=/dev/sda",
    "update-service",
    "--desired-count",
    "0",
    "terminate-instances",
    "s3",
    "rm",
    "rb",
    "/dev/null",
    "/dev/stdin",
    "2>&1",
    ">",
    ">>",
    "<",
    "> /etc/f",
    ">/dev/null",
    "'a > b'",
    "\"x > y\"",
    "'echo x > /etc/f'",
    "'rm -rf /x'",
    "'systemctl stop nginx'",
    "'reboot'",
    "\"$(date)\"",
    "'$(date)'",
    "$(date)",
    "`date`",
    "$(rm -rf /x)",
    "$'\\x72m'",
    "${IFS}",
    "$IFS",
    "$@",
    "$()",
    "{a,b}",
    "{1..3}",
    "file{,.bak}",
    "{rm,-rf,/x}",
    "k{i,}ll",
    "d{e,}lete",
    "*",
    "?",
    "[ab]",
    "/tmp/*",
    "*.log",
    "/bin/r?",
    "'*'",
    "a=b",
    "x=`date`",
    "in",
    "a)",
    ";;",
    "esac",
    "{",
    "}",
    "(",
    ")",
    "f",
    "DROP",
    "TRUNCATE",
    "DELETE",
    "FROM",
    "WHERE",
    "TABLE",
    "t",
    "FLUSHALL",
    "migrate:fresh",
    "ca:cl",
    "q:fl",
    "queue:flush",
    "--force-with-lease",
    "-name",
    "'*.log'",
    "--",
    "|",
    "||",
    "&&",
    ";",
    "&",
    "|&",
];

/// Whole commands (a segment): half the segments are one of these, the rest are built word by word.
const SEGMENTS: &[&str] = &[
    "rm -rf /x",
    "rm -r -f /x",
    "rm --recursive --force /x",
    "rm /x",
    "kubectl delete ns prod",
    "kubectl get pods",
    "kubectl drain node1",
    "kubectl exec p -- reboot",
    "helm uninstall rel",
    "terraform destroy",
    "terraform plan",
    "aws ec2 terminate-instances --instance-ids i-1",
    "aws s3 rm s3://b/k",
    "aws s3 ls",
    "kill -9 1",
    "kill 1",
    "pkill -f x -9",
    "systemctl stop nginx",
    "systemctl status nginx",
    "systemctl reboot",
    "service nginx stop",
    "reboot",
    "shutdown -h now",
    "last reboot",
    "grep -i shutdown /var/log/syslog",
    "dd if=/dev/zero of=/dev/sda",
    "mkfs.ext4 /dev/sda1",
    "shred -u f",
    "find . -delete",
    "find . -name x",
    "find . -exec rm {} \\;",
    "xargs rm",
    "ls | xargs rm",
    "echo hi > /etc/f",
    "echo hi >> /etc/f",
    "cat f > /dev/null",
    "ls 2>&1",
    "psql -c 'DELETE FROM t'",
    "psql -c 'DELETE FROM t WHERE id = 1'",
    "mysql -e 'DROP TABLE t'",
    "mysql -e 'SELECT 1'",
    "redis-cli FLUSHALL",
    "php artisan migrate:fresh",
    "php artisan cache:clear",
    "git push --force",
    "git push --force-with-lease",
    "git status",
    "env -S 'rm -rf /x'",
    "env -Sreboot",
    "sudo -u deploy reboot",
    "nice -n 5 reboot",
    "echo reboot",
    "echo 'a > b'",
    "grep at 'a > b' file",
    "ls /var/log/*",
    "ls -la",
    "cp file{,.bak}",
    "ls file{1,2}.txt",
    "/bin/r? -rf /x",
    "$'\\x72m' -rf /x",
];

/// What joins two segments.
const JOINERS: &[&str] = &[" ; ", " | ", " && ", " || ", " & ", " |& ", "; "];

/// Whole wrapped forms: `{}` is the inner command.
const WRAPS: &[&str] = &[
    "bash -c '{}'",
    "sh -c \"{}\"",
    "ssh h '{}'",
    "eval '{}'",
    "echo '{}' | sh",
    "echo '{}' | bash",
    "echo '{}' | at now",
    "echo '{}' | source /dev/stdin",
    "printf '{}' | ssh h",
    "env -S'{}'",
    "env -S '{}'",
    "env --split-string='{}'",
    "sudo -u deploy {}",
    "`{}`",
    "$({})",
    "echo `{}`",
    "echo \"$({})\"",
    "({})",
    "{ {}; }",
    "case x in x) {};; esac",
    "function f { {}; }",
    "time -p {}",
    "command -p {}",
    "xargs {}",
    "find . -exec {} \\;",
    "ssh h {}",
];

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.below(items.len())]
    }
}

fn segment(rng: &mut Lcg) -> String {
    if rng.below(2) == 0 {
        return rng.pick(SEGMENTS).to_string();
    }
    let mut words = vec![rng.pick(HEADS)];
    for _ in 0..rng.below(5) {
        words.push(rng.pick(ARGS));
    }
    words.join(" ")
}

fn command(rng: &mut Lcg) -> String {
    let mut text = segment(rng);
    for _ in 0..rng.below(3) {
        text.push_str(rng.pick(JOINERS));
        text.push_str(&segment(rng));
    }
    if rng.below(3) == 0 {
        text = rng.pick(WRAPS).replace("{}", &text);
    }
    // A combining acute accent (U+0301) after a random character: it glues to the scalar before it.
    if rng.below(6) == 0 {
        let chars: Vec<char> = text.chars().collect();
        let at = rng.below(chars.len() + 1);
        let mut with_mark: String = chars[..at].iter().collect();
        with_mark.push('\u{0301}');
        with_mark.extend(&chars[at..]);
        text = with_mark;
    }
    text
}

/// The commands, in a fixed order, no duplicates.
fn generate() -> Vec<String> {
    let mut rng = Lcg(SEED);
    let mut seen = std::collections::BTreeSet::new();
    let mut commands = Vec::with_capacity(COUNT);
    while commands.len() < COUNT {
        let text = command(&mut rng);
        if !text.trim().is_empty() && seen.insert(text.clone()) {
            commands.push(text);
        }
    }
    commands
}

fn verdict(text: &str) -> serde_json::Value {
    serde_json::json!({
        "text": text,
        "destructive": destructive_patterns(text),
        "brace_glued": brace_glued_word(text),
        "escape_quoted": escape_quoted_word(text),
        "non_ascii": contains_non_ascii(text),
        "wildcard_command": wildcard_command_word(text),
        "asks_in_production": asks_in_production(text),
    })
}

/// Writes the fixture: one row per line. Run on purpose, then review the diff.
#[test]
#[ignore = "regenerates tests/fixtures/terminal_staging/differential_corpus.json from the Rust matcher"]
fn regenerate_the_differential_corpus() {
    let rows: Vec<String> = generate()
        .iter()
        .map(|text| format!(" {}", verdict(text)))
        .collect();
    let body = format!("[\n{}\n]\n", rows.join(",\n"));
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/terminal_staging/differential_corpus.json"
    );
    std::fs::write(path, body).expect("write differential_corpus.json");
}

#[test]
fn the_differential_corpus_is_the_generated_commands_and_the_rust_matcher_agrees_with_every_golden()
{
    let rows: Vec<serde_json::Value> =
        serde_json::from_str(CORPUS).expect("differential_corpus.json");
    assert_eq!(
        rows.len(),
        COUNT,
        "the corpus is exactly {COUNT} commands; regenerate it if the generator changed"
    );
    let generated = generate();
    let mut wrong = Vec::new();
    for (row, text) in rows.iter().zip(&generated) {
        assert_eq!(
            row["text"].as_str(),
            Some(text.as_str()),
            "the corpus is stale: the generator no longer produces row {row}"
        );
        if *row != verdict(text) {
            wrong.push(format!("{text:?}: golden {row}, now {}", verdict(text)));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} corpus rows disagree with the matcher (regenerate on purpose, or fix the matcher):\n{}",
        wrong.len(),
        wrong.join("\n")
    );
    assert!(
        rows.iter()
            .any(|r| r["text"].as_str().is_some_and(|t| t.contains('\u{0301}'))),
        "the corpus must carry real U+0301 scalars"
    );
    assert!(
        rows.iter().any(|r| r["asks_in_production"] == true)
            && rows.iter().any(|r| r["asks_in_production"] == false),
        "the corpus must hold both asking and quiet commands"
    );
}
