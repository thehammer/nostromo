//! The refused-character set is ONE list (`tests/fixtures/tracker/invisible-chars.txt`): this test makes
//! the daemon's `is_invisible` agree with it for every code point, and the Mac's tests read the same file,
//! so the two sides cannot drift apart. Also: a command written straight into the board FILE (no MCP
//! validation) never reaches the pane as clean, copyable text.

use nostromo::data::work::is_invisible;
use nostromo::tracker::format::parse;
use nostromo::tracker::view::{build, ViewFacts, ViewNode};

const RANGES: &str = include_str!("fixtures/tracker/invisible-chars.txt");

fn listed(c: char) -> bool {
    RANGES
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .any(|l| {
            let (lo, hi) = l.split_once('-').unwrap_or((l, l));
            let lo = u32::from_str_radix(lo, 16).unwrap();
            let hi = u32::from_str_radix(hi, 16).unwrap();
            (lo..=hi).contains(&(c as u32))
        })
}

#[test]
fn the_daemons_invisible_set_is_exactly_the_shared_fixture() {
    for cp in 0..=0x10FFFFu32 {
        let Some(c) = char::from_u32(cp) else {
            continue;
        };
        assert_eq!(
            is_invisible(c),
            listed(c),
            "U+{cp:04X}: is_invisible and invisible-chars.txt disagree"
        );
    }
}

fn board_with_command(command: &str) -> String {
    format!(
        "# Board\n\n## now\n- [ ] Stage it <!-- #stage 1760540000 cmd -->\n  ```\n  {command}\n  ```\n"
    )
}

fn staged(command: &str) -> nostromo::tracker::view::ViewItem {
    let parsed = parse(board_with_command(command).as_bytes()).expect("parses");
    let view = build(&parsed, &ViewFacts::default());
    view.nodes
        .iter()
        .find_map(|n| match n {
            ViewNode::Item(i) if i.id == "stage" => Some(i.clone()),
            _ => None,
        })
        .expect("the item")
}

#[test]
fn a_clean_command_read_from_the_file_is_shown() {
    let item = staged("php artisan queue:retry 8812");
    assert_eq!(
        item.command.as_deref(),
        Some("php artisan queue:retry 8812")
    );
    assert!(!item.command_withheld);
}

#[test]
fn a_command_written_into_the_file_with_a_refused_character_is_withheld_not_shown() {
    // Every listed code point except the line breaks and tab the file format itself uses.
    let mut checked = 0;
    for cp in 0..=0x10FFFFu32 {
        let Some(c) = char::from_u32(cp) else {
            continue;
        };
        if !listed(c) || matches!(c, '\n' | '\r' | '\t' | '\u{2028}' | '\u{2029}' | '\u{85}') {
            continue;
        }
        let item = staged(&format!("echo a{c}b"));
        assert_eq!(item.command, None, "U+{cp:04X} must not be shown");
        assert!(item.command_withheld, "U+{cp:04X} must be flagged");
        checked += 1;
    }
    assert!(checked > 4000, "the sweep covered the set ({checked})");
}

#[test]
fn a_file_written_command_with_an_escape_sequence_or_over_the_length_limit_is_withheld() {
    assert!(staged("echo \u{1b}[31mred").command_withheld);
    let long = "x".repeat(4_001);
    let item = staged(&long);
    assert!(item.command_withheld && item.command.is_none());
    let at_limit = staged(&"x".repeat(4_000));
    assert!(!at_limit.command_withheld && at_limit.command.is_some());
}
