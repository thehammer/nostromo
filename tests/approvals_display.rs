//! The exact-text display of a permission request (design contract §4.3).
//!
//! What the card shows must be exactly what would run: nothing elided, nothing
//! rewritten, every hidden character made visible. The invariant that carries
//! it (T-INV-2, T-AP0a-3) is the round trip: put every `invisible` segment back
//! as its code point, join the lines, and the original text comes back byte for
//! byte. It is checked here over every recorded fixture and over a thousand
//! seeded random strings built from the characters that make shell text hard to
//! read (separators, quotes, here-doc markers, newlines, invisibles).

use std::path::PathBuf;

use nostromo::approvals::display::{ApprovalDisplay, DisplayLine, LineKind, Segment, SegmentKind};
use nostromo::approvals::request::ToolKind;
use nostromo::data::work::is_invisible;
use serde_json::{json, Value};

// ── fixtures ──────────────────────────────────────────────────────────────────

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approvals")
}

/// The CLI's `request` object of the first request in fixture `name`.
fn request_of(name: &str) -> Value {
    let path = fixture_dir().join(format!("{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture["requests"][0]["request"].clone()
}

fn all_fixture_names() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(fixture_dir())
        .unwrap()
        .filter_map(|e| {
            let name = e.ok()?.file_name().into_string().ok()?;
            Some(name.strip_suffix(".json")?.to_owned())
        })
        .collect();
    names.sort();
    assert!(names.len() >= 25, "the fixture set went missing: {names:?}");
    names
}

fn display_of_fixture(name: &str) -> (Value, ApprovalDisplay) {
    let request = request_of(name);
    let tool = request["tool_name"].as_str().unwrap_or_default();
    let display = ApprovalDisplay::build(ToolKind::of(tool), &request["input"]);
    (request, display)
}

fn bash(command: &str) -> ApprovalDisplay {
    ApprovalDisplay::build(ToolKind::Bash, &json!({ "command": command }))
}

// ── helpers over a display ────────────────────────────────────────────────────

fn line_text(line: &DisplayLine) -> String {
    line.segments.iter().map(|s| s.text.as_str()).collect()
}

fn segments_of(d: &ApprovalDisplay, kind: SegmentKind) -> Vec<&Segment> {
    d.lines
        .iter()
        .flat_map(|l| l.segments.iter())
        .filter(|s| s.kind == kind)
        .collect()
}

fn kinds(d: &ApprovalDisplay) -> Vec<LineKind> {
    d.lines.iter().map(|l| l.kind).collect()
}

fn texts_of_kind(d: &ApprovalDisplay, kind: LineKind) -> Vec<String> {
    d.lines
        .iter()
        .filter(|l| l.kind == kind)
        .map(line_text)
        .collect()
}

/// Lines are numbered 1.. in order, and every segment is typed honestly.
#[track_caller]
fn assert_well_formed(d: &ApprovalDisplay, what: &str) {
    for (i, line) in d.lines.iter().enumerate() {
        assert_eq!(
            line.number as usize,
            i + 1,
            "{what}: line numbers run 1.. in order"
        );
        for s in &line.segments {
            match s.kind {
                SegmentKind::Plain | SegmentKind::Separator => {
                    assert!(
                        s.cp.is_none(),
                        "{what}: a {:?} segment has no code point: {s:?}",
                        s.kind
                    );
                    assert!(!s.text.is_empty(), "{what}: no empty segments: {s:?}");
                    if s.kind == SegmentKind::Plain {
                        assert!(
                            s.text.chars().all(|c| c.is_ascii() && !is_invisible(c)),
                            "{what}: plain text is plain ASCII, never hiding anything: {s:?}"
                        );
                    }
                }
                SegmentKind::Invisible => {
                    let cp = s.cp.unwrap_or_else(|| {
                        panic!("{what}: an invisible segment carries its cp: {s:?}")
                    });
                    let c = char::from_u32(cp).expect("a scalar value");
                    assert!(is_invisible(c), "{what}: {s:?}");
                    assert!(
                        s.text.starts_with('\u{27E8}') && s.text.ends_with('\u{27E9}'),
                        "{what}: an invisible character is shown as a ⟨token⟩: {s:?}"
                    );
                }
                SegmentKind::NonAscii => {
                    let cp = s.cp.unwrap_or_else(|| {
                        panic!("{what}: a non-ASCII segment carries its cp: {s:?}")
                    });
                    let c = char::from_u32(cp).expect("a scalar value");
                    assert!(!c.is_ascii() && !is_invisible(c), "{what}: {s:?}");
                    assert_eq!(
                        s.text,
                        c.to_string(),
                        "{what}: a non-ASCII character is shown as itself"
                    );
                }
            }
        }
    }
}

// ── seeded random text ────────────────────────────────────────────────────────

/// xorshift64*: deterministic, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

const TOKENS: &[&str] = &[
    // ASCII
    "a",
    "b",
    "rm",
    "echo",
    "ls",
    "-rf",
    " ",
    "  ",
    "/tmp/x",
    "~",
    "$HOME",
    "x=1",
    "#c",
    "*",
    "?",
    "{",
    "}",
    "[",
    "]",
    "<",
    ">",
    "2>&1",
    // separators
    "&&",
    "||",
    ";",
    "|",
    "&",
    "|&",
    // newlines and quoting
    "\n",
    "\n",
    "\n\n",
    "'",
    "\"",
    "`",
    "\\",
    "(",
    ")",
    "$(",
    "${",
    "'a b'",
    "\"a b\"",
    "$'x'",
    // here-docs
    "<<EOF",
    "<<'EOF'",
    "<<\"EOF\"",
    "<<-EOF",
    "<<EOF\nbody\nEOF\n",
    "<<'EOF'\nrm -rf x && y\nEOF",
    "EOF",
    "\nEOF\n",
    "<<<",
    // nested shells
    "bash -c '",
    "sh -c \"",
    "eval ",
    "$(rm x)",
    "`rm x`",
    // invisibles
    "\t",
    "\r",
    "\r\n",
    "\u{202A}",
    "\u{202B}",
    "\u{202C}",
    "\u{202D}",
    "\u{202E}",
    "\u{2066}",
    "\u{2067}",
    "\u{2068}",
    "\u{2069}",
    "\u{200B}",
    "\u{200C}",
    "\u{200D}",
    "\u{2060}",
    "\u{FEFF}",
    "\u{E0041}",
    "\u{E0042}",
    "\u{E007F}",
    "\u{00AD}",
    "\u{200E}",
    "\u{200F}",
    "\u{061C}",
    "\u{2028}",
    "\u{0}",
    "\u{7}",
    "\u{1b}",
    // non-ASCII that is visible
    "é",
    "м",
    "日本",
    "😀",
];

fn random_text(rng: &mut Rng) -> String {
    let n = rng.below(40);
    (0..n).map(|_| TOKENS[rng.below(TOKENS.len())]).collect()
}

/// Characters of `s` the display counts as invisible (a newline splits lines; it is not a segment).
fn expected_invisible(s: &str) -> u32 {
    s.chars().filter(|c| *c != '\n' && is_invisible(*c)).count() as u32
}

fn expected_non_ascii(s: &str) -> u32 {
    s.chars()
        .filter(|c| !c.is_ascii() && !is_invisible(*c))
        .count() as u32
}

// ── T-INV-2: the round trip ───────────────────────────────────────────────────

#[test]
fn every_fixture_input_displays_in_full_and_reassembles_to_the_original() {
    for name in all_fixture_names() {
        let (request, display) = display_of_fixture(&name);
        let input = &request["input"];
        assert_well_formed(&display, &name);
        let tool = request["tool_name"].as_str().unwrap_or_default();
        let str_in = |k: &str| input[k].as_str().map(str::to_owned);

        match (ToolKind::of(tool), input) {
            (ToolKind::Bash, Value::Object(_)) => {
                assert_eq!(
                    Some(display.reassemble()),
                    str_in("command"),
                    "{name}: the Bash command comes back byte for byte"
                );
            }
            (ToolKind::Write, _) => {
                assert_eq!(
                    Some(display.reassemble()),
                    str_in("content"),
                    "{name}: the written content"
                );
            }
            (ToolKind::Edit, _) => {
                assert_eq!(
                    Some(display.reassemble()),
                    str_in("new_string"),
                    "{name}: the edit's new text"
                );
                assert_eq!(
                    Some(display.reassemble_old()),
                    str_in("old_string"),
                    "{name}: the edit's old text"
                );
            }
            (ToolKind::NotebookEdit, _) => {
                assert_eq!(
                    Some(display.reassemble()),
                    str_in("new_source"),
                    "{name}: the new cell source"
                );
            }
            _ => {
                assert_eq!(
                    display.reassemble(),
                    serde_json::to_string_pretty(input).unwrap(),
                    "{name}: other tools show their input as pretty JSON, whole"
                );
            }
        }
    }
}

#[test]
fn a_thousand_random_bash_commands_reassemble_byte_for_byte() {
    let mut rng = Rng(0x5EED_0001);
    for i in 0..1000 {
        let text = random_text(&mut rng);
        let d = bash(&text);
        assert_well_formed(&d, &format!("random #{i} {text:?}"));
        assert_eq!(d.reassemble(), text, "random #{i}: {text:?}");
        assert_eq!(
            d.invisible_count,
            expected_invisible(&text),
            "random #{i}: {text:?}"
        );
        assert_eq!(
            d.non_ascii_count,
            expected_non_ascii(&text),
            "random #{i}: {text:?}"
        );
        assert!(
            !d.shown_text().contains('\u{202E}'),
            "random #{i}: a bidi override is never shown raw"
        );
    }
}

#[test]
fn a_thousand_random_written_files_show_every_line_as_added_and_reassemble() {
    let mut rng = Rng(0x5EED_0002);
    for i in 0..1000 {
        let text = random_text(&mut rng);
        let d = ApprovalDisplay::build(
            ToolKind::Write,
            &json!({ "file_path": "/tmp/x/f.txt", "content": text }),
        );
        assert_well_formed(&d, &format!("write #{i}"));
        assert_eq!(d.lines[0].kind, LineKind::FileHeader, "write #{i}");
        assert!(
            d.lines[1..].iter().all(|l| l.kind == LineKind::DiffAdd),
            "write #{i}: {:?}",
            kinds(&d)
        );
        assert_eq!(d.reassemble(), text, "write #{i}: {text:?}");
        assert_eq!(d.invisible_count, expected_invisible(&text), "write #{i}");
    }
}

#[test]
fn a_thousand_random_edits_reassemble_to_both_the_old_and_the_new_text() {
    let mut rng = Rng(0x5EED_0003);
    for i in 0..1000 {
        let old = random_text(&mut rng);
        // Half the time the new text shares lines with the old, so context lines occur.
        let new = if i % 2 == 0 {
            random_text(&mut rng)
        } else {
            format!("{old}\n{}", random_text(&mut rng))
        };
        let d = ApprovalDisplay::build(
            ToolKind::Edit,
            &json!({ "file_path": "/tmp/x/f.txt", "old_string": old, "new_string": new }),
        );
        assert_well_formed(&d, &format!("edit #{i}"));
        assert_eq!(d.reassemble(), new, "edit #{i}: new text of {new:?}");
        assert_eq!(d.reassemble_old(), old, "edit #{i}: old text of {old:?}");
    }
}

#[test]
fn a_thousand_random_other_tool_inputs_reassemble_to_their_pretty_json() {
    let mut rng = Rng(0x5EED_0004);
    for i in 0..1000 {
        let text = random_text(&mut rng);
        let input = json!({ "channel": "#general", "text": text, "n": i });
        let d = ApprovalDisplay::build(ToolKind::Mcp, &input);
        assert_well_formed(&d, &format!("json #{i}"));
        assert!(
            d.lines.iter().all(|l| l.kind == LineKind::Json),
            "json #{i}"
        );
        assert_eq!(
            d.reassemble(),
            serde_json::to_string_pretty(&input).unwrap(),
            "json #{i}: {text:?}"
        );
    }
}

#[test]
fn an_empty_command_is_one_empty_line_not_nothing() {
    let d = bash("");
    assert_eq!(d.lines.len(), 1);
    assert_eq!(d.reassemble(), "");
}

// ── Bash ──────────────────────────────────────────────────────────────────────

#[test]
fn a_300_line_command_shows_all_300_lines_and_the_rm_after_the_heredoc_is_on_line_287() {
    let (request, d) = display_of_fixture("heredoc_300");
    let command = request["input"]["command"].as_str().unwrap();
    assert_eq!(
        command.lines().count(),
        300,
        "the fixture is what it says it is"
    );

    assert_eq!(
        d.lines.len(),
        300,
        "nothing is elided, and no command is cut across lines here"
    );
    let line_287 = &d.lines[286];
    assert_eq!(line_287.number, 287);
    assert_eq!(line_287.kind, LineKind::Command);
    assert_eq!(
        line_text(line_287),
        "rm -rf /tmp/notes.txt",
        "the destructive command is where it says it is"
    );
    assert!(!line_287.cont);

    assert_eq!(
        d.lines[0].kind,
        LineKind::Command,
        "the `cat > file <<'EOF'` line"
    );
    for line in &d.lines[1..285] {
        assert_eq!(line.kind, LineKind::HeredocBody, "line {}", line.number);
    }
    assert_eq!(d.lines[285].number, 286);
    assert_eq!(d.lines[285].kind, LineKind::HeredocEnd);
    assert_eq!(line_text(&d.lines[285]), "EOF");
    assert!(
        d.lines[286..].iter().all(|l| l.kind == LineKind::Command),
        "everything after the terminator is a command"
    );

    assert_eq!(d.command_count, Some(15), "cat, rm and the 13 echoes");
    assert!(!d.unparsed);
    assert_eq!((d.invisible_count, d.non_ascii_count), (0, 0));
    assert_eq!(d.reassemble(), command);
}

#[test]
fn a_heredoc_body_is_shown_as_body_even_when_it_looks_like_commands() {
    let d = bash("cat <<'EOF'\nrm -rf / && echo hi\nEOF\nls");

    assert_eq!(
        kinds(&d),
        [
            LineKind::Command,
            LineKind::HeredocBody,
            LineKind::HeredocEnd,
            LineKind::Command
        ]
    );
    assert_eq!(line_text(&d.lines[1]), "rm -rf / && echo hi");
    assert!(
        d.lines[1]
            .segments
            .iter()
            .all(|s| s.kind != SegmentKind::Separator),
        "a here-doc body is text, its && is not a command separator: {:?}",
        d.lines[1]
    );
    assert_eq!(
        d.command_count,
        Some(2),
        "cat and ls: the body is not a command"
    );
}

#[test]
fn each_command_of_a_compound_line_starts_its_own_numbered_line() {
    let (request, d) = display_of_fixture("compound");
    assert_eq!(
        request["input"]["command"],
        "rm -rf build/ && curl -s https://x | sh"
    );

    assert_eq!(
        d.command_count,
        Some(3),
        "rm, curl and sh (a pipe's parts count separately)"
    );
    assert_eq!(d.lines.len(), 3);
    assert_eq!(
        d.lines.iter().map(|l| l.number).collect::<Vec<_>>(),
        [1, 2, 3]
    );
    assert!(d.lines.iter().all(|l| l.kind == LineKind::Command));
    assert!(
        line_text(&d.lines[0])
            .trim_start()
            .starts_with("rm -rf build/"),
        "{:?}",
        d.lines[0]
    );
    assert!(
        line_text(&d.lines[1])
            .trim_start()
            .starts_with("curl -s https://x"),
        "{:?}",
        d.lines[1]
    );
    assert!(
        line_text(&d.lines[2]).trim_start().starts_with("sh"),
        "{:?}",
        d.lines[2]
    );
    assert_eq!(
        d.lines.iter().map(|l| l.cont).collect::<Vec<_>>(),
        [false, true, true],
        "the cuts after && and | are not newlines in the original: the later lines continue line 1"
    );
    let seps: Vec<String> = segments_of(&d, SegmentKind::Separator)
        .iter()
        .map(|s| s.text.trim().to_owned())
        .collect();
    assert_eq!(seps, ["&&", "|"], "the separators are typed segments");
    assert_eq!(
        d.reassemble(),
        "rm -rf build/ && curl -s https://x | sh",
        "cont lines are re-joined without a newline"
    );
}

#[test]
fn a_newline_in_the_original_is_a_new_line_and_not_a_continuation() {
    let d = bash("echo a && echo b\necho c");

    assert_eq!(d.lines.len(), 3);
    assert_eq!(
        d.lines.iter().map(|l| l.cont).collect::<Vec<_>>(),
        [false, true, false]
    );
    assert_eq!(d.command_count, Some(3));
    assert_eq!(d.reassemble(), "echo a && echo b\necho c");
}

#[test]
fn commands_inside_substitutions_and_dash_c_payloads_are_counted() {
    assert_eq!(
        bash("echo $(rm x; ls)").command_count,
        Some(3),
        "echo, rm and ls"
    );
    assert_eq!(bash("echo `rm x`").command_count, Some(2));
    assert_eq!(
        bash("bash -c 'rm x && ls'").command_count.map(|n| n >= 3),
        Some(true),
        "bash plus the payload's rm and ls"
    );
    assert_eq!(
        bash("(rm x; ls)").command_count,
        Some(2),
        "a subshell's commands"
    );
    assert_eq!(bash("ls").command_count, Some(1));
}

#[test]
fn a_separator_inside_quotes_does_not_cut_the_line() {
    let d = bash("echo 'a && b' \"c | d\"");

    assert_eq!(d.lines.len(), 1);
    assert_eq!(d.command_count, Some(1));
    assert!(segments_of(&d, SegmentKind::Separator).is_empty());
}

#[test]
fn input_the_tokenizer_cannot_read_is_marked_unparsed_and_still_shown_whole() {
    for command in ["echo \"unterminated", "echo $(ls", "echo 'a"] {
        let d = bash(command);
        assert!(d.unparsed, "{command:?} is not readable shell");
        assert_eq!(
            d.reassemble(),
            command,
            "{command:?} is still shown in full"
        );
    }
    assert!(!bash("echo \"fine\" && ls").unparsed);
}

#[test]
fn a_tab_and_a_carriage_return_are_shown_as_tokens() {
    let d = bash("a\tb\rc");

    let inv = segments_of(&d, SegmentKind::Invisible);
    assert_eq!(
        inv.iter()
            .map(|s| (s.text.as_str(), s.cp))
            .collect::<Vec<_>>(),
        [
            ("\u{27E8}tab\u{27E9}", Some(9)),
            ("\u{27E8}CR\u{27E9}", Some(13))
        ]
    );
    assert_eq!(d.invisible_count, 2);
    assert_eq!(d.reassemble(), "a\tb\rc");
}

// ── hidden and look-alike characters ──────────────────────────────────────────

#[test]
fn bidi_controls_are_shown_as_named_tokens_with_their_code_points() {
    let (_, d) = display_of_fixture("bidi");

    let inv: Vec<(u32, String)> = segments_of(&d, SegmentKind::Invisible)
        .iter()
        .map(|s| (s.cp.unwrap(), s.text.clone()))
        .collect();
    assert_eq!(
        inv,
        [
            (0x202E, "\u{27E8}U+202E RLO\u{27E9}".to_owned()),
            (0x2069, "\u{27E8}U+2069 PDI\u{27E9}".to_owned()),
            (0x2066, "\u{27E8}U+2066 LRI\u{27E9}".to_owned()),
            (0x2067, "\u{27E8}U+2067 RLI\u{27E9}".to_owned()),
            (0x2068, "\u{27E8}U+2068 FSI\u{27E9}".to_owned()),
            (0x2069, "\u{27E8}U+2069 PDI\u{27E9}".to_owned()),
        ]
    );
    assert_eq!(d.invisible_count, 6);
    assert_eq!(d.non_ascii_count, 0);
    let shown = d.shown_text();
    assert!(
        !shown.contains('\u{202E}') && !shown.contains('\u{2066}'),
        "no bidi control survives into what is shown: {shown:?}"
    );
    assert!(shown.contains("txt.exe"), "{shown:?}");
}

#[test]
fn zero_width_characters_are_visible_and_split_the_word_they_hide_in() {
    let (_, d) = display_of_fixture("zero_width");

    let inv: Vec<(u32, String)> = segments_of(&d, SegmentKind::Invisible)
        .iter()
        .map(|s| (s.cp.unwrap(), s.text.clone()))
        .collect();
    assert_eq!(
        inv,
        [
            (0x200B, "\u{27E8}U+200B ZWSP\u{27E9}".to_owned()),
            (0x200C, "\u{27E8}U+200C ZWNJ\u{27E9}".to_owned()),
            (0x200D, "\u{27E8}U+200D ZWJ\u{27E9}".to_owned()),
            (0x2060, "\u{27E8}U+2060 WJ\u{27E9}".to_owned()),
            (0xFEFF, "\u{27E8}U+FEFF BOM\u{27E9}".to_owned()),
        ]
    );
    assert_eq!(d.invisible_count, 5);
    assert!(
        segments_of(&d, SegmentKind::Plain)
            .iter()
            .all(|s| !s.text.contains("rm")),
        "`r<ZWSP>m` must not read as a plain `rm`: {:?}",
        d.lines
    );
}

#[test]
fn unicode_tag_characters_are_shown_as_code_points() {
    let (_, d) = display_of_fixture("tags");

    let cps: Vec<u32> = segments_of(&d, SegmentKind::Invisible)
        .iter()
        .map(|s| s.cp.unwrap())
        .collect();
    assert_eq!(cps, [0xE0041, 0xE0042, 0xE0043, 0xE007F]);
    let texts: Vec<String> = segments_of(&d, SegmentKind::Invisible)
        .iter()
        .map(|s| s.text.clone())
        .collect();
    assert_eq!(
        texts[0], "\u{27E8}U+E0041\u{27E9}",
        "a character with no name in the table is shown by code point"
    );
    assert_eq!(d.invisible_count, 4);
    assert!(!d.shown_text().contains('\u{E0041}'));
}

#[test]
fn a_cyrillic_look_alike_is_a_non_ascii_segment_and_never_plain_text() {
    let (_, d) = display_of_fixture("cyrillic");

    let non_ascii = segments_of(&d, SegmentKind::NonAscii);
    assert_eq!(non_ascii.len(), 1);
    assert_eq!(
        (non_ascii[0].text.as_str(), non_ascii[0].cp),
        ("\u{043C}", Some(0x043C))
    );
    assert_eq!(d.non_ascii_count, 1);
    assert_eq!(d.invisible_count, 0);
    assert!(
        segments_of(&d, SegmentKind::Plain)
            .iter()
            .all(|s| !s.text.contains('\u{043C}') && !s.text.contains("rm")),
        "the Cyrillic м is never folded into plain text: {:?}",
        d.lines
    );
}

// ── files ─────────────────────────────────────────────────────────────────────

#[test]
fn an_edit_is_a_line_diff_under_a_header_with_the_absolute_path() {
    let (_, d) = display_of_fixture("edit");

    assert_eq!(d.lines[0].kind, LineKind::FileHeader);
    assert_eq!(d.lines[0].number, 1);
    assert_eq!(line_text(&d.lines[0]), "/tmp/x/src/main.rs");
    assert_eq!(d.header_text().as_deref(), Some("/tmp/x/src/main.rs"));
    assert_well_formed(&d, "edit");

    assert_eq!(
        texts_of_kind(&d, LineKind::DiffCtx),
        ["fn main() {", "    let a = 1;", "}", ""],
        "unchanged lines are context, in order"
    );
    assert_eq!(
        texts_of_kind(&d, LineKind::DiffDel),
        ["    let b = 2;", "    println!(\"{}\", a + b);"]
    );
    assert_eq!(
        texts_of_kind(&d, LineKind::DiffAdd),
        [
            "    let b = 3;",
            "    let c = 4;",
            "    println!(\"{}\", a + b + c);"
        ]
    );
    let diff = &kinds(&d)[1..];
    assert_eq!(
        &diff[..2],
        [LineKind::DiffCtx, LineKind::DiffCtx],
        "the unchanged opening comes first"
    );
    assert_eq!(
        &diff[diff.len() - 2..],
        [LineKind::DiffCtx, LineKind::DiffCtx],
        "and the unchanged closing last"
    );
    assert_eq!(d.lines.len(), 1 + 4 + 2 + 3);
    assert_eq!(d.command_count, None);
}

#[test]
fn an_edit_that_changes_nothing_is_all_context() {
    let d = ApprovalDisplay::build(
        ToolKind::Edit,
        &json!({ "file_path": "/a", "old_string": "x\ny", "new_string": "x\ny" }),
    );

    assert_eq!(
        kinds(&d),
        [LineKind::FileHeader, LineKind::DiffCtx, LineKind::DiffCtx]
    );
}

#[test]
fn a_write_shows_the_path_and_the_whole_content_as_added_lines() {
    let (_, d) = display_of_fixture("write");

    assert_eq!(d.lines[0].kind, LineKind::FileHeader);
    assert_eq!(line_text(&d.lines[0]), "/tmp/x/notes.md");
    assert_eq!(
        texts_of_kind(&d, LineKind::DiffAdd),
        ["# Notes", "", "first line", "second line", "third line", ""]
    );
    assert_eq!(d.lines.len(), 7);
    assert!(d.lines[1..].iter().all(|l| l.kind == LineKind::DiffAdd));
}

#[test]
fn a_large_edit_is_still_shown_whole() {
    let old: String = (0..3000).map(|i| format!("old {i}\n")).collect();
    let new: String = (0..3000).map(|i| format!("new {i}\n")).collect();
    let d = ApprovalDisplay::build(
        ToolKind::Edit,
        &json!({ "file_path": "/a", "old_string": old, "new_string": new }),
    );

    assert_eq!(d.reassemble(), new);
    assert_eq!(d.reassemble_old(), old);
}

#[test]
fn a_notebook_edit_shows_the_notebook_the_new_source_and_the_other_fields() {
    let (_, d) = display_of_fixture("notebook_edit");

    assert_eq!(d.lines[0].kind, LineKind::FileHeader);
    assert_eq!(line_text(&d.lines[0]), "/tmp/x/analysis.ipynb");
    assert_eq!(
        texts_of_kind(&d, LineKind::DiffAdd),
        ["import pandas as pd", "df = pd.read_csv('a.csv')", ""]
    );
    let shown = d.shown_text();
    assert!(
        shown.contains("cell-3") && shown.contains("replace"),
        "nothing the tool was given is hidden: {shown:?}"
    );
}

#[test]
fn a_settings_write_shows_the_settings_path_and_the_content() {
    let (_, d) = display_of_fixture("settings_write");

    assert_eq!(line_text(&d.lines[0]), "/Users/test/.claude/settings.json");
    assert!(d.shown_text().contains("Bash(*)"));
}

// ── everything else ───────────────────────────────────────────────────────────

#[test]
fn an_mcp_tool_is_its_input_pretty_printed_as_json_lines() {
    let (request, d) = display_of_fixture("mcp");

    assert!(
        d.lines.iter().all(|l| l.kind == LineKind::Json),
        "{:?}",
        kinds(&d)
    );
    let text = d.lines.iter().map(line_text).collect::<Vec<_>>().join("\n");
    assert_eq!(
        text,
        serde_json::to_string_pretty(&request["input"]).unwrap()
    );
    assert!(text.contains("\"#general\"") && text.contains("\"hello team\""));
    assert!(
        text.lines().any(|l| l.starts_with("  \"")),
        "two-space indentation: {text}"
    );
    assert_eq!(d.command_count, None);
    assert_well_formed(&d, "mcp");
}

#[test]
fn a_command_that_is_not_a_string_falls_back_to_json_rather_than_hiding_it() {
    let d = ApprovalDisplay::build(ToolKind::Bash, &json!({ "command": ["rm", "-rf", "/"] }));

    assert!(d.lines.iter().all(|l| l.kind == LineKind::Json));
    assert!(d.shown_text().contains("\"rm\""));
}

#[test]
fn a_display_survives_a_json_round_trip() {
    for name in ["compound", "bidi", "edit", "mcp", "cyrillic"] {
        let (_, d) = display_of_fixture(name);
        let back: ApprovalDisplay =
            serde_json::from_value(serde_json::to_value(&d).unwrap()).unwrap();
        assert_eq!(back, d, "{name}");
    }
}

#[test]
fn the_wire_form_uses_the_contract_names() {
    let (_, d) = display_of_fixture("compound");
    let v = serde_json::to_value(&d).unwrap();

    assert_eq!(v["command_count"], 3);
    assert_eq!(v["invisible_count"], 0);
    assert_eq!(v["non_ascii_count"], 0);
    assert_eq!(v["unparsed"], false);
    assert_eq!(v["lines"][0]["number"], 1);
    assert_eq!(v["lines"][0]["kind"], "command");
    assert_eq!(v["lines"][0]["segments"][0]["kind"], "plain");
    assert!(v["lines"][0]["segments"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["kind"] == "separator"));

    let (_, h) = display_of_fixture("heredoc_300");
    let v = serde_json::to_value(&h).unwrap();
    assert_eq!(v["lines"][1]["kind"], "heredoc_body");
    assert_eq!(v["lines"][285]["kind"], "heredoc_end");

    let (_, e) = display_of_fixture("edit");
    let kinds: Vec<String> = serde_json::to_value(&e).unwrap()["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["kind"].as_str().unwrap().to_owned())
        .collect();
    for k in ["file_header", "diff_ctx", "diff_del", "diff_add"] {
        assert!(kinds.iter().any(|x| x == k), "{k} in {kinds:?}");
    }
}
