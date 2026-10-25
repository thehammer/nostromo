//! Behavioural tests for the pure text engine behind terminal "agent follow"
//! (slice 3a): `LineAssembler`, `screen_snapshot`, `deliver`,
//! `DeliveryPolicy` and `Redactor`.
//!
//! Traces to PRD `.claude/prds/terminal-pane.md` criteria 31 (plain text, no
//! ANSI, `\r` collapsed, full-screen programs as a screen snapshot), 32 (one
//! delivery per settled command, head/tail cap with an omitted marker), 33
//! (sustained output batched to about one delivery per 10 s, flood pause) and
//! 42 (secrets replaced by `[redacted: <kind>]`), and to plan D12 / D12a.
//!
//! Fixtures live in `tests/fixtures/terminal_text/`. The `.bin` files hold real
//! escape bytes (zsh PROMPT_SP `%` + spaces + `\r \r`, bash OSC titles,
//! `ls --color` SGR, git pager keypad modes, docker/npm style `ESC[2K` and
//! cursor-up redraws, a vim alternate-screen session). The two corpora are
//! realistic ordinary output (must never be redacted) and obviously fake
//! secrets (must always be redacted).

use std::time::{Duration, Instant};

use nostromo::terminal::follow::{
    deliver, screen_snapshot, Decision, Delivery, DeliveryKind, DeliveryPolicy, LineAssembler,
    PauseReason, MAX_LINE_COLUMNS,
};
use nostromo::terminal::redact::{RedactionKind, Redactor};

const PROGRESS_BAR: &[u8] = include_bytes!("fixtures/terminal_text/progress_bar.bin");
const NPM_PROGRESS: &[u8] = include_bytes!("fixtures/terminal_text/npm_multiline_progress.bin");
const COLORED_LS: &[u8] = include_bytes!("fixtures/terminal_text/colored_ls.bin");
const GIT_LOG: &[u8] = include_bytes!("fixtures/terminal_text/git_log_colored.bin");
const PROMPT_ZSH: &[u8] = include_bytes!("fixtures/terminal_text/prompt_zsh.bin");
const PROMPT_BASH: &[u8] = include_bytes!("fixtures/terminal_text/prompt_bash.bin");
const TINKER_PROMPT: &[u8] = include_bytes!("fixtures/terminal_text/tinker_prompt.bin");
const VIM_SESSION: &[u8] = include_bytes!("fixtures/terminal_text/vim_session.bin");
const UTF8_SPLIT: &[u8] = include_bytes!("fixtures/terminal_text/utf8_split.bin");
const NEGATIVE_CORPUS: &str = include_str!("fixtures/terminal_text/negative_corpus.txt");
const POSITIVE_CORPUS: &str = include_str!("fixtures/terminal_text/positive_corpus.txt");

const ALL_FIXTURES: &[(&str, &[u8])] = &[
    ("progress_bar", PROGRESS_BAR),
    ("npm_multiline_progress", NPM_PROGRESS),
    ("colored_ls", COLORED_LS),
    ("git_log_colored", GIT_LOG),
    ("prompt_zsh", PROMPT_ZSH),
    ("prompt_bash", PROMPT_BASH),
    ("tinker_prompt", TINKER_PROMPT),
    ("vim_session", VIM_SESSION),
    ("utf8_split", UTF8_SPLIT),
];

// ───────────────────────────── LineAssembler helpers ─────────────────────────

#[derive(Debug, PartialEq, Eq, Clone)]
struct Assembled {
    lines: Vec<String>,
    partial: Option<String>,
}

fn drain(a: &mut LineAssembler) -> Assembled {
    let lines = a.take_committed();
    let partial = a.current_partial().map(str::to_owned);
    Assembled { lines, partial }
}

fn assemble(bytes: &[u8]) -> Assembled {
    let mut a = LineAssembler::new();
    a.feed(bytes);
    drain(&mut a)
}

fn assemble_bytewise(bytes: &[u8]) -> Assembled {
    let mut a = LineAssembler::new();
    for b in bytes {
        a.feed(std::slice::from_ref(b));
    }
    drain(&mut a)
}

fn assemble_split_at(bytes: &[u8], at: usize) -> Assembled {
    let mut a = LineAssembler::new();
    a.feed(&bytes[..at]);
    a.feed(&bytes[at..]);
    drain(&mut a)
}

/// Asserts the whole-buffer result AND that byte-by-byte feeding gives the
/// identical result (chunk boundaries must never matter).
fn assert_assembled(input: &[u8], lines: &[&str], partial: Option<&str>) {
    let expected = Assembled {
        lines: lines.iter().map(|s| s.to_string()).collect(),
        partial: partial.map(str::to_owned),
    };
    let whole = assemble(input);
    assert_eq!(
        whole,
        expected,
        "whole-buffer feed of {:?}",
        String::from_utf8_lossy(input)
    );
    let bytewise = assemble_bytewise(input);
    assert_eq!(
        bytewise,
        expected,
        "byte-by-byte feed of {:?}",
        String::from_utf8_lossy(input)
    );
}

fn assert_lines(input: &[u8], lines: &[&str]) {
    assert_assembled(input, lines, None);
}

fn assert_no_escape(a: &Assembled, what: &str) {
    for l in a.lines.iter().chain(a.partial.iter()) {
        assert!(!l.contains('\x1b'), "{what}: ESC leaked into {l:?}");
    }
}

// ───────────────────────────── LineAssembler: basics ─────────────────────────

#[test]
fn lines_commit_on_newline_and_crlf() {
    assert_lines(b"a\nb\n", &["a", "b"]);
    assert_lines(b"a\r\nb\r\n", &["a", "b"]);
}

#[test]
fn blank_lines_are_kept() {
    assert_lines(b"a\n\nb\n", &["a", "", "b"]);
    assert_lines(b"\r\n\r\n", &["", ""]);
}

#[test]
fn trailing_spaces_are_trimmed_but_leading_spaces_are_kept() {
    assert_lines(b"a   \n", &["a"]);
    assert_lines(b"  indented  \n", &["  indented"]);
    assert_lines(b"   \n", &[""]);
}

#[test]
fn unfinished_line_is_the_partial_until_it_commits() {
    let mut a = LineAssembler::new();
    assert_eq!(a.current_partial(), None);
    a.feed(b"abc  ");
    assert_eq!(a.current_partial(), Some("abc"), "trailing spaces trimmed");
    assert!(a.take_committed().is_empty());
    a.feed(b"def\n");
    assert_eq!(a.current_partial(), None);
    // The spaces were only trimmed from the partial's view, not from the line.
    assert_eq!(a.take_committed(), vec!["abc  def".to_string()]);
}

#[test]
fn whitespace_only_partial_is_none() {
    let mut a = LineAssembler::new();
    a.feed(b"    ");
    assert_eq!(a.current_partial(), None);
}

#[test]
fn take_committed_returns_each_line_once() {
    let mut a = LineAssembler::new();
    a.feed(b"one\ntwo\n");
    assert_eq!(
        a.take_committed(),
        vec!["one".to_string(), "two".to_string()]
    );
    assert!(a.take_committed().is_empty());
    a.feed(b"three\n");
    assert_eq!(a.take_committed(), vec!["three".to_string()]);
}

#[test]
fn newline_resets_the_column() {
    assert_lines(b"abc\nX\n", &["abc", "X"]);
}

// ───────────────────────────── LineAssembler: cursor motion ──────────────────

#[test]
fn carriage_return_overwrites_from_column_zero() {
    assert_lines(b"hello\rHE\n", &["HEllo"]);
    assert_lines(b"abcdef\rxy\n", &["xycdef"]);
    assert_lines(b"10%\r50%\r100%\n", &["100%"]);
}

#[test]
fn backspace_moves_back_one_column() {
    assert_lines(b"abc\x08\x08X\n", &["aXc"]);
    // classic erase-in-place: "ab", back, space over b, back, then c
    assert_lines(b"ab\x08 \x08c\n", &["ac"]);
}

#[test]
fn backspace_at_column_zero_stays_put() {
    assert_lines(b"\x08X\n", &["X"]);
}

#[test]
fn csi_k_erases_to_end_of_line_by_default_and_with_zero() {
    assert_lines(b"hello\x1b[3D\x1b[K\n", &["he"]);
    assert_lines(b"hello\x1b[3D\x1b[0K\n", &["he"]);
}

#[test]
fn csi_1k_erases_from_start_of_line_through_the_cursor() {
    // cursor sits on the second "l" (index 3); xterm erases 0..=3
    assert_lines(b"hello\x1b[2D\x1b[1K\n", &["    o"]);
}

#[test]
fn csi_2k_erases_the_whole_line_without_moving_the_cursor() {
    assert_lines(b"old text\x1b[2K\rnew\n", &["new"]);
    assert_lines(b"hello\x1b[2Kx\n", &["     x"]);
}

#[test]
fn csi_d_moves_the_cursor_back() {
    assert_lines(b"abcdef\x1b[3DXY\n", &["abcXYf"]);
    assert_lines(b"abc\x1b[DX\n", &["abX"]);
}

#[test]
fn csi_c_moves_the_cursor_forward_padding_with_spaces() {
    assert_lines(b"ab\x1b[3Cc\n", &["ab   c"]);
    assert_lines(b"ab\x1b[3C\n", &["ab"]);
    assert_lines(b"abcdef\x1b[3D\x1b[2CX\n", &["abcdeX"]);
}

#[test]
fn csi_g_moves_to_a_one_based_absolute_column() {
    assert_lines(b"abcdef\x1b[1GX\n", &["Xbcdef"]);
    assert_lines(b"abcdef\x1b[4GX\n", &["abcXef"]);
    assert_lines(b"abcdef\x1b[GX\n", &["Xbcdef"]);
}

#[test]
fn csi_p_deletes_characters_at_the_cursor() {
    assert_lines(b"abcdef\x1b[3D\x1b[2P\n", &["abcf"]);
}

#[test]
fn tabs_advance_to_the_next_multiple_of_eight() {
    assert_lines(b"a\tb\n", &["a       b"]);
    assert_lines(b"\tx\n", &["        x"]);
    assert_lines(b"abcdefgh\tx\n", &["abcdefgh        x"]);
    assert_lines(b"abcdefg\tx\n", &["abcdefg x"]);
}

#[test]
fn a_tab_with_no_text_after_it_leaves_no_trailing_spaces() {
    assert_lines(b"a\t\n", &["a"]);
}

// ───────────────────────────── LineAssembler: cursor up/down ─────────────────

#[test]
fn cursor_up_rewrites_untaken_rows() {
    assert_lines(b"a\nb\nc\n\x1b[3AA\nB\nC\n", &["A", "B", "C"]);
}

#[test]
fn cursor_up_with_erase_line_replaces_multi_line_progress() {
    let input = b"a\r\nb\r\nc\r\n\x1b[3A\x1b[2KA\r\n\x1b[2KB\r\n\x1b[2KC\r\n";
    assert_lines(input, &["A", "B", "C"]);
}

#[test]
fn single_line_cursor_up_redraw_keeps_only_the_final_state() {
    assert_lines(
        b"Progress 1/3\n\x1b[1A\x1b[2KProgress 2/3\n\x1b[1A\x1b[2KProgress 3/3\n",
        &["Progress 3/3"],
    );
}

#[test]
fn cursor_up_past_the_oldest_untaken_row_clamps_to_it() {
    // After X's newline the cursor sits on b's row, so b is held back (it is
    // still rewritable) and is the cursor line.
    assert_assembled(b"a\nb\n\x1b[9AX\n", &["X"], Some("b"));
}

#[test]
fn cursor_up_cannot_reach_rows_already_taken() {
    let mut a = LineAssembler::new();
    a.feed(b"a\nb\n");
    assert_eq!(a.take_committed(), vec!["a".to_string(), "b".to_string()]);
    a.feed(b"c\n\x1b[5Ad\n");
    // clamps to the oldest untaken row (c's), so a and b are never rewritten
    assert_eq!(drain(&mut a).lines, vec!["d".to_string()]);
}

#[test]
fn cursor_down_moves_among_untaken_rows() {
    assert_lines(b"a\nb\nc\n\x1b[3A\x1b[2BX\n", &["a", "b", "X"]);
}

#[test]
fn rows_at_or_below_the_cursor_row_are_not_returned_until_the_cursor_passes_them() {
    let mut a = LineAssembler::new();
    a.feed(b"a\nb\nc\n\x1b[2A");
    assert_eq!(
        a.take_committed(),
        vec!["a".to_string()],
        "b and c are at/below the cursor"
    );
    a.feed(b"B\n\n");
    assert_eq!(a.take_committed(), vec!["B".to_string(), "c".to_string()]);
    assert_eq!(a.current_partial(), None);
}

// ───────────────────────────── LineAssembler: escapes ────────────────────────

#[test]
fn sgr_colour_codes_are_stripped() {
    assert_lines(
        b"\x1b[31mred\x1b[0m and \x1b[1;32mgreen\x1b[m\n",
        &["red and green"],
    );
    assert_lines(b"\x1b[38;2;255;0;0mtruecolor\x1b[0m\n", &["truecolor"]);
    assert_lines(b"\x1b[38:2::255:0:0mcolon form\x1b[0m\n", &["colon form"]);
}

#[test]
fn private_mode_csi_sequences_are_stripped() {
    assert_lines(b"\x1b[?25lhidden cursor\x1b[?25h\n", &["hidden cursor"]);
    assert_lines(b"\x1b[?2004hx\x1b[?2004l\n", &["x"]);
}

#[test]
fn csi_with_intermediate_bytes_is_stripped() {
    assert_lines(b"\x1b[2 qx\n", &["x"]);
}

#[test]
fn csi_sequences_that_do_not_affect_text_are_stripped() {
    assert_lines(b"\x1b[H\x1b[2Jabc\n", &["abc"]);
}

#[test]
fn osc_is_stripped_whether_bel_or_st_terminated() {
    assert_lines(b"\x1b]0;window title\x07x\n", &["x"]);
    assert_lines(b"\x1b]2;window title\x1b\\x\n", &["x"]);
    assert_lines(
        b"\x1b]8;;http://example.test\x1b\\link\x1b]8;;\x1b\\ text\n",
        &["link text"],
    );
}

#[test]
fn dcs_apc_pm_and_sos_strings_are_stripped() {
    assert_lines(b"\x1bPq#0;2;0;0;0\x1b\\x\n", &["x"]);
    assert_lines(b"\x1b_Gf=24;AAAA\x1b\\x\n", &["x"]);
    assert_lines(b"\x1b^hidden\x1b\\x\n", &["x"]);
    assert_lines(b"\x1bXhidden\x1b\\x\n", &["x"]);
}

#[test]
fn charset_select_escapes_are_stripped() {
    assert_lines(b"\x1b(Bx\x1b)0y\n", &["xy"]);
}

#[test]
fn keypad_mode_escapes_are_stripped() {
    // git's pager and vim send ESC = / ESC > around their output
    assert_lines(b"\x1b=\x1b>x\n", &["x"]);
}

#[test]
fn escape_split_across_chunks_is_still_stripped() {
    let mut a = LineAssembler::new();
    a.feed(b"a\x1b");
    a.feed(b"[3");
    a.feed(b"1mb\x1b]0;ti");
    a.feed(b"tle\x07c\n");
    assert_eq!(drain(&mut a).lines, vec!["abc".to_string()]);
}

#[test]
fn unterminated_osc_is_aborted_by_a_newline() {
    assert_lines(b"before\x1b]0;never ends\nnext\n", &["before", "next"]);
}

#[test]
fn unterminated_dcs_is_aborted_by_a_newline() {
    assert_lines(b"before\x1bPnever ends\nnext\n", &["before", "next"]);
}

#[test]
fn c1_csi_and_osc_act_like_their_escape_forms() {
    assert_lines("\u{9b}31mred\u{9b}0m\n".as_bytes(), &["red"]);
    assert_lines("\u{9d}0;title\x07x\n".as_bytes(), &["x"]);
}

#[test]
fn other_c1_controls_are_dropped() {
    assert_lines("a\u{88}b\u{8e}c\n".as_bytes(), &["abc"]);
}

#[test]
fn other_c0_controls_are_dropped() {
    assert_lines(b"a\x07b\x00c\x01d\x0e\x0fe\n", &["abcde"]);
}

// ───────────────────────────── LineAssembler: unicode ────────────────────────

#[test]
fn bidi_and_tag_spoof_characters_are_dropped() {
    let mut dropped: Vec<char> = Vec::new();
    dropped.extend('\u{202A}'..='\u{202E}');
    dropped.extend('\u{2066}'..='\u{2069}');
    dropped.push('\u{200E}');
    dropped.push('\u{200F}');
    dropped.extend('\u{E0000}'..='\u{E007F}');
    for c in dropped {
        let input = format!("x{c}y\n");
        assert_lines(input.as_bytes(), &["xy"]);
    }
}

#[test]
fn a_filename_spoofed_with_a_right_to_left_override_is_shown_in_logical_order() {
    assert_lines("invoice\u{202E}fdp.exe\n".as_bytes(), &["invoicefdp.exe"]);
}

#[test]
fn ordinary_non_ascii_text_is_kept() {
    assert_lines(
        "caf\u{e9} \u{65e5}\u{672c}\u{8a9e} \u{1F600}\n".as_bytes(),
        &["caf\u{e9} \u{65e5}\u{672c}\u{8a9e} \u{1F600}"],
    );
}

#[test]
fn invalid_utf8_becomes_the_replacement_character() {
    assert_lines(b"a\xffb\n", &["a\u{FFFD}b"]);
    assert_lines(b"a\x80b\n", &["a\u{FFFD}b"]);
}

#[test]
fn a_truncated_utf8_sequence_becomes_a_replacement_and_does_not_eat_what_follows() {
    let got = assemble(b"a\xe2\x82b\n");
    assert_eq!(got.lines.len(), 1);
    let line = &got.lines[0];
    assert!(line.starts_with('a') && line.ends_with('b'), "{line:?}");
    assert!(line.contains('\u{FFFD}'), "{line:?}");
}

#[test]
fn utf8_split_across_chunks_is_reassembled_at_every_offset() {
    let text = "\u{e9}\u{65e5}\u{1F600}\n";
    let bytes = text.as_bytes();
    for at in 0..=bytes.len() {
        let got = assemble_split_at(bytes, at);
        assert_eq!(
            got.lines,
            vec![text.trim_end().to_string()],
            "split at {at}"
        );
    }
}

// ───────────────────────────── LineAssembler: column cap ─────────────────────

#[test]
fn lines_longer_than_the_cap_are_cut_and_end_with_an_ellipsis() {
    let input = format!("{}\n", "a".repeat(5000));
    let got = assemble(input.as_bytes());
    assert_eq!(got.lines.len(), 1);
    let line = &got.lines[0];
    assert_eq!(line.chars().count(), MAX_LINE_COLUMNS);
    assert!(line.ends_with('\u{2026}'));
    assert_eq!(
        line.chars().filter(|c| *c == 'a').count(),
        MAX_LINE_COLUMNS - 1
    );
}

#[test]
fn a_line_of_exactly_the_cap_is_not_cut() {
    let input = format!("{}\n", "a".repeat(MAX_LINE_COLUMNS));
    let got = assemble(input.as_bytes());
    assert_eq!(got.lines, vec!["a".repeat(MAX_LINE_COLUMNS)]);
    let input = format!("{}\n", "a".repeat(MAX_LINE_COLUMNS + 1));
    let got = assemble(input.as_bytes());
    assert!(got.lines[0].ends_with('\u{2026}'));
    assert_eq!(got.lines[0].chars().count(), MAX_LINE_COLUMNS);
}

#[test]
fn the_cap_counts_characters_not_bytes() {
    let input = format!("{}\n", "\u{e9}".repeat(5000));
    let got = assemble(input.as_bytes());
    assert_eq!(got.lines[0].chars().count(), MAX_LINE_COLUMNS);
    assert!(got.lines[0].ends_with('\u{2026}'));
}

#[test]
fn the_unfinished_partial_line_is_capped_too() {
    let got = assemble("b".repeat(10_000).as_bytes());
    let partial = got.partial.expect("partial present");
    assert_eq!(partial.chars().count(), MAX_LINE_COLUMNS);
    assert!(partial.ends_with('\u{2026}'));
}

#[test]
fn the_cap_gives_the_same_result_fed_byte_by_byte() {
    let input = format!("{}\nnext\n", "z".repeat(9000));
    assert_eq!(
        assemble(input.as_bytes()),
        assemble_bytewise(input.as_bytes())
    );
}

// ───────────────────────────── LineAssembler: suspend ────────────────────────

#[test]
fn bytes_fed_while_suspended_are_discarded() {
    let mut a = LineAssembler::new();
    assert!(!a.is_suspended());
    a.feed(b"a\n");
    a.suspend();
    assert!(a.is_suspended());
    a.feed(b"x\ny\n");
    a.resume();
    assert!(!a.is_suspended());
    a.feed(b"b\n");
    assert_eq!(drain(&mut a).lines, vec!["a".to_string(), "b".to_string()]);
}

#[test]
fn rows_assembled_before_suspend_survive_and_can_be_taken_while_suspended() {
    let mut a = LineAssembler::new();
    a.feed(b"a\nb\n");
    a.suspend();
    assert_eq!(a.take_committed(), vec!["a".to_string(), "b".to_string()]);
}

#[test]
fn suspending_mid_escape_does_not_leave_the_parser_stuck_in_it() {
    let mut a = LineAssembler::new();
    a.feed(b"ok\n\x1b[3");
    a.suspend();
    a.resume();
    a.feed(b"1mdef\n");
    assert_eq!(
        drain(&mut a).lines,
        vec!["ok".to_string(), "1mdef".to_string()]
    );
}

#[test]
fn an_unterminated_string_before_suspend_does_not_swallow_text_after_resume() {
    let mut a = LineAssembler::new();
    a.feed(b"\x1b]0;title");
    a.suspend();
    a.resume();
    a.feed(b"text\n");
    assert_eq!(drain(&mut a).lines, vec!["text".to_string()]);
}

#[test]
fn escape_bytes_discarded_while_suspended_do_not_leak_into_the_parser_state() {
    let mut a = LineAssembler::new();
    a.suspend();
    a.feed(b"\x1b[3");
    a.resume();
    a.feed(b"1mx\n");
    assert_eq!(drain(&mut a).lines, vec!["1mx".to_string()]);
}

// ───────────────────────────── Fixtures through LineAssembler ────────────────

#[test]
fn fixture_progress_bar_collapses_to_the_final_state() {
    assert_assembled(PROGRESS_BAR, &["Downloading 100%", "Done"], None);
}

#[test]
fn fixture_npm_multiline_progress_keeps_only_the_final_three_lines() {
    assert_assembled(
        NPM_PROGRESS,
        &[
            "npm install",
            "fetching a 100%",
            "fetching b 100%",
            "fetching c 100%",
            "added 3 packages in 2s",
        ],
        None,
    );
}

#[test]
fn fixture_colored_ls_is_plain_text() {
    assert_assembled(
        COLORED_LS,
        &[
            "total 8",
            "drwxr-xr-x  3 user staff   96 Oct 25 10:00 docs",
            "-rwxr-xr-x  1 user staff  120 Oct 25 10:00 run.sh",
            "-rw-r--r--  1 user staff 2048 Oct 25 10:00 README.md",
            "docs  run.sh  README.md  arch.tar.gz",
        ],
        None,
    );
}

#[test]
fn fixture_git_log_colored_is_plain_text() {
    assert_assembled(
        GIT_LOG,
        &[
            "commit 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d (HEAD -> main, origin/main)",
            "Author: Test User <test@example.com>",
            "Date:   Sat Oct 24 10:00:00 2026 -0500",
            "",
            "    Add the thing",
            "",
            "commit 0f9e8d7c6b5a49382716059483726150f9e8d7c6",
            "Author: Test User <test@example.com>",
            "Date:   Fri Oct 23 09:00:00 2026 -0500",
            "",
            "    Initial commit",
        ],
        None,
    );
}

#[test]
fn fixture_zsh_session_with_prompt_sp_and_bracketed_paste() {
    assert_assembled(
        PROMPT_ZSH,
        &["user@host proj % echo hello", "hello"],
        Some("user@host proj %"),
    );
}

#[test]
fn fixture_bash_session_with_osc_title_and_readline_backspace() {
    assert_assembled(
        PROMPT_BASH,
        &["user@host:~/proj$ echo hi", "hi"],
        Some("user@host:~/proj$"),
    );
}

#[test]
fn fixture_tinker_prompt() {
    assert_assembled(
        TINKER_PROMPT,
        &[
            "Psy Shell v0.12.0 (PHP 8.3.0 \u{2014} cli) by Justin Hileman",
            "> 1+1",
            "= 2",
            "",
        ],
        Some(">"),
    );
}

#[test]
fn fixture_utf8_split_survives_a_split_at_every_byte_offset() {
    let expected = Assembled {
        lines: vec![
            "emoji \u{1F600}\u{1F389} CJK \u{65e5}\u{672c}\u{8a9e} caf\u{e9}".to_string(),
            "\u{d55c}\u{ad6d}\u{c5b4} \u{2014} done".to_string(),
        ],
        partial: None,
    };
    assert_eq!(assemble(UTF8_SPLIT), expected);
    for at in 0..=UTF8_SPLIT.len() {
        assert_eq!(assemble_split_at(UTF8_SPLIT, at), expected, "split at {at}");
    }
    assert_eq!(assemble_bytewise(UTF8_SPLIT), expected);
}

#[test]
fn every_fixture_assembles_without_escape_bytes_and_independent_of_chunking() {
    for (name, bytes) in ALL_FIXTURES {
        let whole = assemble(bytes);
        assert_no_escape(&whole, name);
        assert_eq!(
            assemble_bytewise(bytes),
            whole,
            "{name}: byte-by-byte differs from whole"
        );
        for at in (0..=bytes.len()).step_by(7) {
            assert_eq!(
                assemble_split_at(bytes, at),
                whole,
                "{name}: split at {at} differs"
            );
        }
    }
}

// ───────────────────────────── vim: alternate screen ─────────────────────────

const ALT_ENTER: &[u8] = b"\x1b[?1049h";
const ALT_LEAVE: &[u8] = b"\x1b[?1049l";

fn find(haystack: &[u8], needle: &[u8]) -> usize {
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
        .expect("marker present in fixture")
}

/// Splits the vim fixture at the alternate-screen markers: (everything up to
/// and including ESC[?1049h, the alt-screen body plus ESC[?1049l, the rest).
fn vim_parts() -> (&'static [u8], &'static [u8], &'static [u8]) {
    let enter_end = find(VIM_SESSION, ALT_ENTER) + ALT_ENTER.len();
    let leave_end = find(VIM_SESSION, ALT_LEAVE) + ALT_LEAVE.len();
    (
        &VIM_SESSION[..enter_end],
        &VIM_SESSION[enter_end..leave_end],
        &VIM_SESSION[leave_end..],
    )
}

#[test]
fn vim_alt_screen_period_yields_no_lines_when_the_driver_suspends_around_it() {
    let (pre, alt, post) = vim_parts();
    let mut a = LineAssembler::new();
    a.feed(pre);
    a.suspend();
    a.feed(alt);
    a.resume();
    a.feed(post);
    let got = drain(&mut a);
    assert_eq!(got.lines, vec!["user@host:~$ vim notes.txt".to_string()]);
    assert_eq!(got.partial.as_deref(), Some("user@host:~$"));
    assert_no_escape(&got, "vim");
}

#[test]
fn vim_alt_screen_period_suspended_one_byte_at_a_time_gives_the_same_result() {
    let (pre, alt, post) = vim_parts();
    let mut a = LineAssembler::new();
    for b in pre {
        a.feed(std::slice::from_ref(b));
    }
    a.suspend();
    for b in alt {
        a.feed(std::slice::from_ref(b));
    }
    a.resume();
    for b in post {
        a.feed(std::slice::from_ref(b));
    }
    let got = drain(&mut a);
    assert_eq!(got.lines, vec!["user@host:~$ vim notes.txt".to_string()]);
    assert_eq!(got.partial.as_deref(), Some("user@host:~$"));
}

fn screen_after(bytes: &[u8]) -> String {
    let mut parser = vt100::Parser::new(24, 80, 0);
    parser.process(bytes);
    screen_snapshot(parser.screen())
}

#[test]
fn vim_screen_snapshot_shows_what_is_visible_in_the_editor() {
    let leave_start = find(VIM_SESSION, ALT_LEAVE);
    let mut parser = vt100::Parser::new(24, 80, 0);
    parser.process(&VIM_SESSION[..leave_start]);
    assert!(
        parser.screen().alternate_screen(),
        "fixture really is in the alt screen"
    );
    let text = screen_snapshot(parser.screen());
    let mut expected = String::from("hello vim\n");
    for _ in 2..=23 {
        expected.push_str("~\n");
    }
    expected.push_str(":q");
    assert_eq!(text, expected);
}

#[test]
fn after_leaving_vim_the_screen_snapshot_is_the_shell_again() {
    assert_eq!(
        screen_after(VIM_SESSION),
        "user@host:~$ vim notes.txt\nuser@host:~$"
    );
}

#[test]
fn vim_session_reports_a_screen_delivery_after_800ms_in_the_alt_screen() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 300, 0);
    assert_eq!(p.on_tick(at(base, 799), None, true), Decision::Wait);
    assert_eq!(
        p.on_tick(at(base, 800), None, true),
        Decision::Deliver {
            kind: DeliveryKind::Screen
        }
    );
}

// ───────────────────────────── screen_snapshot ───────────────────────────────

fn snapshot_of_bytes(rows: u16, cols: u16, bytes: &[u8]) -> String {
    let mut parser = vt100::Parser::new(rows, cols, 0);
    parser.process(bytes);
    screen_snapshot(parser.screen())
}

#[test]
fn snapshot_trims_trailing_spaces_and_drops_trailing_blank_rows() {
    assert_eq!(
        snapshot_of_bytes(5, 20, b"hello   \r\nworld\r\n\r\n"),
        "hello\nworld"
    );
}

#[test]
fn snapshot_keeps_blank_rows_between_text() {
    assert_eq!(snapshot_of_bytes(5, 20, b"a\r\n\r\nb"), "a\n\nb");
    assert_eq!(snapshot_of_bytes(5, 20, b"\r\n\r\nx"), "\n\nx");
}

#[test]
fn snapshot_of_an_empty_screen_is_empty() {
    assert_eq!(snapshot_of_bytes(5, 20, b""), "");
}

#[test]
fn snapshot_has_no_colour_codes_and_keeps_wide_characters() {
    assert_eq!(
        snapshot_of_bytes(3, 20, "\x1b[31mred\x1b[0m \u{65e5}\u{672c}".as_bytes()),
        "red \u{65e5}\u{672c}"
    );
}

#[test]
fn snapshot_keeps_leading_indentation() {
    assert_eq!(snapshot_of_bytes(3, 20, b"  indented"), "  indented");
}

// ───────────────────────────── DeliveryPolicy ────────────────────────────────

fn at(base: Instant, ms: u64) -> Instant {
    base + Duration::from_millis(ms)
}

const LINES: Decision = Decision::Deliver {
    kind: DeliveryKind::Lines,
};
const SCREEN: Decision = Decision::Deliver {
    kind: DeliveryKind::Screen,
};
const PAUSE_OUTPUT: Decision = Decision::Pause {
    reason: PauseReason::TooMuchOutput,
};
const PAUSE_DELIVERIES: Decision = Decision::Pause {
    reason: PauseReason::TooManyDeliveries,
};

/// One command's worth of output at `t` that settles (800 ms quiet): returns
/// the decision of the settle tick and reports the delivery like a caller.
fn settle_once(p: &mut DeliveryPolicy, base: Instant, t: u64, capped: bool) -> Decision {
    p.on_output(at(base, t), 80, 1);
    let d = p.on_tick(at(base, t + 800), None, false);
    if matches!(d, Decision::Deliver { .. }) {
        p.on_delivered(capped);
    }
    d
}

#[test]
fn constants_match_the_spec() {
    assert_eq!(DeliveryPolicy::SETTLE_QUIET, Duration::from_millis(800));
    assert_eq!(
        DeliveryPolicy::PROMPT_SETTLE_QUIET,
        Duration::from_millis(200)
    );
    assert_eq!(
        DeliveryPolicy::MIN_SUSTAINED_INTERVAL,
        Duration::from_secs(10)
    );
    assert_eq!(DeliveryPolicy::CAP_LINES, 200);
    assert_eq!(DeliveryPolicy::CAP_BYTES, 16 * 1024);
    assert_eq!(DeliveryPolicy::HEAD, 50);
    assert_eq!(DeliveryPolicy::TAIL, 100);
    assert_eq!(DeliveryPolicy::FLOOD_LINES_60S, 5000);
    assert_eq!(DeliveryPolicy::FLOOD_BYTES_60S, 1024 * 1024);
    assert_eq!(DeliveryPolicy::FLOOD_CONSECUTIVE_CAPPED, 3);
    assert_eq!(DeliveryPolicy::MAX_DELIVERIES_PER_HOUR, 60);
}

#[test]
fn a_burst_of_30_lines_then_800ms_quiet_is_exactly_one_lines_delivery() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    let mut delivered = Vec::new();
    for t in (0..=3000u64).step_by(10) {
        if t < 300 {
            p.on_output(at(base, t), 80, 1); // 30 lines, last at 290 ms
        }
        if t % 50 == 0 {
            let d = p.on_tick(at(base, t), None, false);
            if d != Decision::Wait {
                delivered.push((t, d));
                p.on_delivered(false);
            }
        }
    }
    assert_eq!(
        delivered,
        vec![(1100, LINES)],
        "first tick at or after 290 + 800 ms"
    );
}

#[test]
fn nothing_is_delivered_without_pending_output() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for t in (0..=20_000u64).step_by(100) {
        assert_eq!(
            p.on_tick(at(base, t), Some("user@host:~$"), false),
            Decision::Wait
        );
    }
    assert_eq!(p.on_tick(at(base, 20_000), None, true), Decision::Wait);
}

#[test]
fn quiet_of_799ms_waits_and_800ms_delivers() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 100, 2);
    assert_eq!(p.on_tick(at(base, 799), None, false), Decision::Wait);
    assert_eq!(p.on_tick(at(base, 800), None, false), LINES);
}

#[test]
fn late_output_restarts_the_quiet_period() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 100, 2);
    p.on_output(at(base, 500), 100, 2);
    assert_eq!(p.on_tick(at(base, 1299), None, false), Decision::Wait);
    assert_eq!(p.on_tick(at(base, 1300), None, false), LINES);
}

#[test]
fn a_prompt_on_the_cursor_line_settles_in_200ms_not_199() {
    for cursor in [
        "user@host:~$",
        "root@abc123:/var/www# ",
        "user@host proj %",
        ">",
        ">>>",
        ">>> ",
        "\u{276F}",
        "~/proj \u{276F} ",
    ] {
        let base = Instant::now();
        let mut p = DeliveryPolicy::new();
        p.on_output(at(base, 0), 40, 1);
        assert_eq!(
            p.on_tick(at(base, 199), Some(cursor), false),
            Decision::Wait,
            "{cursor:?} at 199"
        );
        assert_eq!(
            p.on_tick(at(base, 200), Some(cursor), false),
            LINES,
            "{cursor:?} at 200"
        );
    }
}

#[test]
fn a_cursor_line_that_is_not_a_prompt_still_needs_800ms() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 40, 1);
    assert_eq!(
        p.on_tick(at(base, 200), Some("Compiling foo v0.1.0"), false),
        Decision::Wait
    );
    assert_eq!(
        p.on_tick(at(base, 799), Some("Compiling foo v0.1.0"), false),
        Decision::Wait
    );
    assert_eq!(
        p.on_tick(at(base, 800), Some("Compiling foo v0.1.0"), false),
        LINES
    );
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 40, 1);
    assert_eq!(p.on_tick(at(base, 200), None, false), Decision::Wait);
}

#[test]
fn a_prompt_without_pending_output_does_not_deliver() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    assert_eq!(
        p.on_tick(at(base, 5_000), Some("user@host:~$"), false),
        Decision::Wait
    );
}

#[test]
fn prompt_fixtures_settle_quickly_through_the_assembler() {
    for (name, bytes) in [
        ("zsh", PROMPT_ZSH),
        ("bash", PROMPT_BASH),
        ("tinker", TINKER_PROMPT),
    ] {
        let mut a = LineAssembler::new();
        a.feed(bytes);
        let cursor = a
            .current_partial()
            .expect("fixture ends on a prompt")
            .to_owned();
        let base = Instant::now();
        let mut p = DeliveryPolicy::new();
        p.on_output(at(base, 0), bytes.len(), 2);
        assert_eq!(
            p.on_tick(at(base, 199), Some(cursor.as_str()), false),
            Decision::Wait,
            "{name}"
        );
        assert_eq!(
            p.on_tick(at(base, 200), Some(cursor.as_str()), false),
            LINES,
            "{name}"
        );
    }
}

#[test]
fn a_fixture_that_ends_without_a_prompt_waits_the_full_800ms() {
    let mut a = LineAssembler::new();
    a.feed(COLORED_LS);
    assert_eq!(a.current_partial(), None);
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), COLORED_LS.len(), 5);
    assert_eq!(
        p.on_tick(at(base, 200), a.current_partial(), false),
        Decision::Wait
    );
    assert_eq!(p.on_tick(at(base, 800), a.current_partial(), false), LINES);
}

#[test]
fn alt_screen_settles_into_a_screen_delivery() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 2000, 0);
    assert_eq!(p.on_tick(at(base, 799), None, true), Decision::Wait);
    assert_eq!(p.on_tick(at(base, 800), None, true), SCREEN);
}

#[test]
fn new_output_after_a_delivery_produces_another_delivery() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    assert_eq!(settle_once(&mut p, base, 0, false), LINES);
    assert_eq!(p.on_tick(at(base, 2_000), None, false), Decision::Wait);
    assert_eq!(settle_once(&mut p, base, 3_000, false), LINES);
}

#[test]
fn sustained_output_is_delivered_at_most_once_every_10_seconds() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    let mut delivered = Vec::new();
    for t in (0..=60_000u64).step_by(50) {
        p.on_output(at(base, t), 60, 1);
        let d = p.on_tick(at(base, t), None, false);
        match d {
            Decision::Wait => {}
            Decision::Deliver { kind } => {
                assert_eq!(kind, DeliveryKind::Lines);
                delivered.push(t);
                p.on_delivered(false);
            }
            Decision::Pause { reason } => {
                panic!("a line every 50 ms must not pause: {reason:?} at {t}")
            }
        }
    }
    assert!(delivered.len() <= 7, "{delivered:?}");
    assert_eq!(
        delivered,
        vec![10_000, 20_000, 30_000, 40_000, 50_000, 60_000],
        "first at 10 s after the first pending output, then every 10 s after the last delivery"
    );
}

#[test]
fn sustained_output_in_the_alt_screen_delivers_screens() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    let mut kinds = Vec::new();
    for t in (0..=10_000u64).step_by(50) {
        p.on_output(at(base, t), 60, 0);
        if let Decision::Deliver { kind } = p.on_tick(at(base, t), None, true) {
            kinds.push((t, kind));
            p.on_delivered(false);
        }
    }
    assert_eq!(kinds, vec![(10_000, DeliveryKind::Screen)]);
}

#[test]
fn unchanged_screen_is_not_redelivered() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.observe_screen("hello vim\n~\n~");
    p.on_output(at(base, 0), 500, 0);
    assert_eq!(p.on_tick(at(base, 800), None, true), SCREEN);
    p.on_delivered(false);

    // output that leaves the screen unchanged (cursor blink, redraw)
    p.on_output(at(base, 1_000), 12, 0);
    p.observe_screen("hello vim\n~\n~");
    assert_eq!(p.on_tick(at(base, 1_800), None, true), Decision::Wait);

    // the pending flag cleared: a changed screen without new output is still nothing
    p.observe_screen("hello vim, edited\n~\n~");
    assert_eq!(p.on_tick(at(base, 3_000), None, true), Decision::Wait);

    // genuinely new output with a changed screen delivers
    p.on_output(at(base, 5_000), 80, 0);
    p.observe_screen("hello vim, edited again\n~\n~");
    assert_eq!(p.on_tick(at(base, 5_800), None, true), SCREEN);
}

#[test]
fn without_observed_screens_every_pending_output_delivers() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    assert_eq!(
        {
            p.on_output(at(base, 0), 80, 0);
            p.on_tick(at(base, 800), None, true)
        },
        SCREEN
    );
    p.on_delivered(false);
    p.on_output(at(base, 2_000), 80, 0);
    assert_eq!(p.on_tick(at(base, 2_800), None, true), SCREEN);
}

#[test]
fn unchanged_screen_suppression_does_not_apply_to_line_deliveries() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.observe_screen("same");
    assert_eq!(settle_once(&mut p, base, 0, false), LINES);
    p.observe_screen("same");
    assert_eq!(settle_once(&mut p, base, 2_000, false), LINES);
}

// ── flood ──

#[test]
fn a_yes_rate_flood_pauses_once_then_stays_quiet_until_resumed() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    let mut seen = Vec::new();
    for t in (0..30_000u64).step_by(100) {
        p.on_output(at(base, t), 400, 100); // 1000 lines/s
        let d = p.on_tick(at(base, t), Some("y"), false);
        if d != Decision::Wait {
            seen.push((t, d));
        }
    }
    assert_eq!(
        seen,
        vec![(5_000, PAUSE_OUTPUT)],
        "51st call crosses 5000 lines; nothing delivered before"
    );

    // paused: ticks wait, output is ignored
    p.on_output(at(base, 30_000), 100, 1);
    assert_eq!(p.on_tick(at(base, 41_000), None, false), Decision::Wait);

    // resume: fresh windows, and what arrived while paused is not pending
    p.resume(at(base, 50_000));
    assert_eq!(p.on_tick(at(base, 60_000), None, false), Decision::Wait);
    p.on_output(at(base, 60_000), 10, 1);
    assert_eq!(p.on_tick(at(base, 60_799), None, false), Decision::Wait);
    assert_eq!(p.on_tick(at(base, 60_800), None, false), LINES);
}

#[test]
fn resume_gives_fresh_flood_windows() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 100, 6000);
    assert_eq!(p.on_tick(at(base, 0), None, false), PAUSE_OUTPUT);
    p.resume(at(base, 1_000));
    // the old 6000 lines must not count against the new window
    p.on_output(at(base, 1_000), 100, 4000);
    assert_eq!(p.on_tick(at(base, 1_800), None, false), LINES);
}

#[test]
fn flooding_again_after_resume_pauses_again() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 100, 6000);
    assert_eq!(p.on_tick(at(base, 0), None, false), PAUSE_OUTPUT);
    p.resume(at(base, 1_000));
    p.on_output(at(base, 1_000), 100, 6000);
    assert_eq!(p.on_tick(at(base, 1_000), None, false), PAUSE_OUTPUT);
}

#[test]
fn flood_line_threshold_is_strictly_greater_than_5000_in_60s() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 1000, 5000);
    assert_eq!(
        p.on_tick(at(base, 800), None, false),
        LINES,
        "exactly 5000 is allowed"
    );

    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 1000, 5001);
    assert_eq!(p.on_tick(at(base, 0), None, false), PAUSE_OUTPUT);
}

#[test]
fn flood_byte_threshold_is_strictly_greater_than_one_mebibyte_in_60s() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 1024 * 1024, 10);
    assert_eq!(
        p.on_tick(at(base, 800), None, false),
        LINES,
        "exactly 1 MiB is allowed"
    );

    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 1024 * 1024 + 1, 10);
    assert_eq!(p.on_tick(at(base, 0), None, false), PAUSE_OUTPUT);
}

#[test]
fn flood_window_rolls_so_slow_heavy_output_is_not_a_flood() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 1000, 4000);
    assert_eq!(p.on_tick(at(base, 800), None, false), LINES);
    p.on_delivered(false);
    p.on_output(at(base, 61_000), 1000, 4000);
    assert_eq!(p.on_tick(at(base, 61_800), None, false), LINES);
}

#[test]
fn flood_is_checked_before_a_settled_delivery() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    p.on_output(at(base, 0), 100, 6000);
    assert_eq!(
        p.on_tick(at(base, 5_000), Some("user@host:~$"), false),
        PAUSE_OUTPUT
    );
}

#[test]
fn three_capped_deliveries_in_a_row_pause_following() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for i in 0..3u64 {
        assert_eq!(
            settle_once(&mut p, base, i * 1_000, true),
            LINES,
            "delivery {i}"
        );
    }
    assert_eq!(p.on_tick(at(base, 3_000), None, false), PAUSE_OUTPUT);
    assert_eq!(
        p.on_tick(at(base, 3_100), None, false),
        Decision::Wait,
        "Pause is returned once"
    );
}

#[test]
fn an_uncapped_delivery_resets_the_capped_counter() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for (i, capped) in [true, true, false, true, true].into_iter().enumerate() {
        assert_eq!(
            settle_once(&mut p, base, i as u64 * 1_000, capped),
            LINES,
            "delivery {i}"
        );
    }
    assert_eq!(
        p.on_tick(at(base, 5_000), None, false),
        Decision::Wait,
        "only two capped in a row"
    );
    assert_eq!(settle_once(&mut p, base, 6_000, false), LINES);
}

#[test]
fn resume_clears_the_capped_counter() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for i in 0..3u64 {
        settle_once(&mut p, base, i * 1_000, true);
    }
    assert_eq!(p.on_tick(at(base, 3_000), None, false), PAUSE_OUTPUT);
    p.resume(at(base, 4_000));
    assert_eq!(settle_once(&mut p, base, 4_000, true), LINES);
    assert_eq!(settle_once(&mut p, base, 5_000, true), LINES);
    assert_eq!(
        p.on_tick(at(base, 6_000), None, false),
        Decision::Wait,
        "two capped since resume, not three"
    );
}

// ── deliveries per hour ──

#[test]
fn the_61st_delivery_within_an_hour_pauses_instead() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for i in 0..60u64 {
        assert_eq!(
            settle_once(&mut p, base, i * 30_000, false),
            LINES,
            "delivery {}",
            i + 1
        );
    }
    assert_eq!(
        settle_once(&mut p, base, 60 * 30_000, false),
        PAUSE_DELIVERIES
    );
}

#[test]
fn deliveries_older_than_an_hour_stop_counting() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for i in 0..60u64 {
        assert_eq!(settle_once(&mut p, base, i * 30_000, false), LINES);
    }
    // the first delivery (at ~0.8 s) is more than an hour old now
    assert_eq!(settle_once(&mut p, base, 3_601_000, false), LINES);
}

#[test]
fn resume_clears_the_hourly_delivery_count() {
    let base = Instant::now();
    let mut p = DeliveryPolicy::new();
    for i in 0..60u64 {
        settle_once(&mut p, base, i * 30_000, false);
    }
    assert_eq!(
        settle_once(&mut p, base, 1_800_000, false),
        PAUSE_DELIVERIES
    );
    p.resume(at(base, 1_810_000));
    assert_eq!(
        settle_once(&mut p, base, 1_820_000, false),
        LINES,
        "fresh windows after resume"
    );
}

// ───────────────────────────── Redactor ──────────────────────────────────────

fn redact(text: &str) -> (String, Vec<RedactionKind>) {
    Redactor::new().redact(text)
}

fn assert_redacts(input: &str, expected: &str, kinds: &[RedactionKind]) {
    let (out, got) = redact(input);
    assert_eq!(out, expected, "input {input:?}");
    assert_eq!(got, kinds, "kinds for {input:?}");
}

fn assert_untouched(input: &str) {
    assert_redacts(input, input, &[]);
}

const AWS_KEY: &str = "AKIAFAKEFAKEFAKEFAKE";
const AWS_SECRET: &str = "wJalrFAKEFAKE/K7MDENG/bPxRfiCYFAKEKEY40";
const GH_TOKEN: &str = "ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE";
const FAKE_JWT: &str =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJGQUtFIn0.FAKEFAKEFAKEFAKEFAKE";

#[test]
fn kind_names_are_the_wire_names() {
    assert_eq!(RedactionKind::AwsAccessKey.as_str(), "aws-access-key");
    assert_eq!(RedactionKind::AwsSecretKey.as_str(), "aws-secret-key");
    assert_eq!(RedactionKind::BearerToken.as_str(), "bearer-token");
    assert_eq!(RedactionKind::ApiToken.as_str(), "api-token");
    assert_eq!(
        RedactionKind::SecretAssignment.as_str(),
        "secret-assignment"
    );
    assert_eq!(RedactionKind::UrlPassword.as_str(), "url-password");
    assert_eq!(RedactionKind::PrivateKey.as_str(), "private-key");
}

#[test]
fn aws_access_keys_are_replaced() {
    assert_redacts(
        &format!("key {AWS_KEY} end"),
        "key [redacted: aws-access-key] end",
        &[RedactionKind::AwsAccessKey],
    );
    for prefix in [
        "AKIA", "ASIA", "AGPA", "AIDA", "AROA", "ANPA", "ANVA", "AIPA",
    ] {
        let (out, kinds) = redact(&format!("id={prefix}FAKEFAKEFAKEFAKE;"));
        assert_eq!(kinds, vec![RedactionKind::AwsAccessKey], "{prefix}");
        assert!(
            out.contains("[redacted: aws-access-key]"),
            "{prefix}: {out}"
        );
        assert!(!out.contains("FAKEFAKE"), "{prefix}: {out}");
    }
}

#[test]
fn aws_access_key_lookalikes_are_left_alone() {
    assert_untouched("AKIAFAKE1234");
    assert_untouched("XAKIAFAKEFAKEFAKEFAKE");
}

#[test]
fn only_the_value_of_an_aws_secret_key_is_replaced() {
    assert_redacts(
        &format!("AWS_SECRET_ACCESS_KEY={AWS_SECRET}"),
        "AWS_SECRET_ACCESS_KEY=[redacted: aws-secret-key]",
        &[RedactionKind::AwsSecretKey],
    );
    assert_redacts(
        &format!("aws_secret_access_key = {AWS_SECRET}"),
        "aws_secret_access_key = [redacted: aws-secret-key]",
        &[RedactionKind::AwsSecretKey],
    );
    assert_redacts(
        "aws_session_token: FAKEFAKESESSIONTOKEN/FAKE+FAKE==",
        "aws_session_token: [redacted: aws-secret-key]",
        &[RedactionKind::AwsSecretKey],
    );
}

#[test]
fn aws_access_key_id_assignment_is_an_access_key_only() {
    assert_redacts(
        &format!("AWS_ACCESS_KEY_ID={AWS_KEY}"),
        "AWS_ACCESS_KEY_ID=[redacted: aws-access-key]",
        &[RedactionKind::AwsAccessKey],
    );
}

#[test]
fn bearer_token_value_is_replaced_and_the_scheme_kept() {
    assert_redacts(
        "Authorization: Bearer abcdef1234567890",
        "Authorization: Bearer [redacted: bearer-token]",
        &[RedactionKind::BearerToken],
    );
    assert_redacts(
        "curl -H \"Authorization: Bearer abcdefgh12345678\" https://api.example.test",
        "curl -H \"Authorization: Bearer [redacted: bearer-token]\" https://api.example.test",
        &[RedactionKind::BearerToken],
    );
    assert_redacts(
        "authorization: bearer abcdefgh12345678",
        "authorization: bearer [redacted: bearer-token]",
        &[RedactionKind::BearerToken],
    );
}

#[test]
fn a_short_bearer_value_is_left_alone() {
    assert_untouched("Bearer abc");
}

#[test]
fn a_jwt_after_bearer_is_a_bearer_token_not_an_api_token() {
    assert_redacts(
        &format!("Authorization: Bearer {FAKE_JWT}"),
        "Authorization: Bearer [redacted: bearer-token]",
        &[RedactionKind::BearerToken],
    );
}

#[test]
fn api_token_shapes_are_replaced() {
    let tokens = [
        GH_TOKEN.to_string(),
        "gho_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE".to_string(),
        "ghs_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE".to_string(),
        "github_pat_11FAKEFAKEFAKE_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE".to_string(),
        "xoxb-FAKEFAKEFAKE-FAKEFAKEFAKE-FAKEFAKEFAKEFAKEFAKEFAKE".to_string(),
        "sk_live_FAKEFAKEFAKE".to_string(),
        "sk_test_FAKEFAKEFAKE".to_string(),
        "sk-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE".to_string(),
        FAKE_JWT.to_string(),
    ];
    for tok in tokens {
        assert_redacts(
            &format!("see {tok} here"),
            "see [redacted: api-token] here",
            &[RedactionKind::ApiToken],
        );
    }
}

#[test]
fn short_token_lookalikes_are_left_alone() {
    assert_untouched("ghp_abc");
    assert_untouched("sk-short");
    assert_untouched("eyJ is a prefix");
}

#[test]
fn token_named_assignments_with_a_token_value_are_api_tokens_with_the_name_kept() {
    assert_redacts(
        &format!("GITHUB_TOKEN={GH_TOKEN}"),
        "GITHUB_TOKEN=[redacted: api-token]",
        &[RedactionKind::ApiToken],
    );
    assert_redacts(
        "STRIPE_SECRET=sk_live_FAKEFAKEFAKE",
        "STRIPE_SECRET=[redacted: api-token]",
        &[RedactionKind::ApiToken],
    );
    assert_redacts(
        "OPENAI_API_KEY=sk-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE",
        "OPENAI_API_KEY=[redacted: api-token]",
        &[RedactionKind::ApiToken],
    );
}

#[test]
fn secret_assignments_keep_the_name_and_replace_the_value() {
    assert_redacts(
        "DB_PASSWORD=hunter2",
        "DB_PASSWORD=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
    assert_redacts(
        "APP_KEY=base64:FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK=",
        "APP_KEY=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
    assert_redacts(
        "client_secret: abc123",
        "client_secret: [redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
    assert_redacts(
        "SENTRY_LARAVEL_DSN=https://FAKEFAKEFAKEFAKE@o0.ingest.sentry.io/0000000",
        "SENTRY_LARAVEL_DSN=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
    assert_redacts(
        "export PUSHER_APP_SECRET=fakepushersecret",
        "export PUSHER_APP_SECRET=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
}

#[test]
fn quoted_secret_values_are_replaced_including_the_quotes() {
    assert_redacts(
        "MAIL_PASSWORD=\"two fake words\"",
        "MAIL_PASSWORD=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
    assert_redacts(
        "JWT_SECRET='fake jwt secret'",
        "JWT_SECRET=[redacted: secret-assignment]",
        &[RedactionKind::SecretAssignment],
    );
}

#[test]
fn a_quoted_value_does_not_span_a_newline() {
    assert_redacts(
        "X_SECRET=\"abc\ndef\"",
        "X_SECRET=[redacted: secret-assignment]\ndef\"",
        &[RedactionKind::SecretAssignment],
    );
}

#[test]
fn an_empty_value_does_not_swallow_the_next_line() {
    assert_untouched("DB_PASSWORD=\nAPP_ENV=production\n");
}

#[test]
fn ordinary_assignments_are_left_alone() {
    for line in [
        "APP_ENV=production",
        "PATH=/usr/local/bin:/usr/bin",
        "MONKEY=banana",
        "KEYBOARD=us",
        "TOKENIZER=whitespace",
        "SSH_AUTH_SOCK=/tmp/ssh-agent.sock",
        "AWS_DEFAULT_REGION=us-east-1",
        "DB_HOST=db.internal",
    ] {
        assert_untouched(line);
    }
}

#[test]
fn only_the_password_in_a_url_is_replaced() {
    assert_redacts(
        "postgres://user:pw@host/db",
        "postgres://user:[redacted: url-password]@host/db",
        &[RedactionKind::UrlPassword],
    );
    assert_redacts(
        "DATABASE_URL=mysql://root:FakeRootPw@127.0.0.1:3306/app",
        "DATABASE_URL=mysql://root:[redacted: url-password]@127.0.0.1:3306/app",
        &[RedactionKind::UrlPassword],
    );
}

#[test]
fn urls_without_a_password_are_left_alone() {
    assert_untouched("postgres://user@host/db");
    assert_untouched("https://example.com:8080/path?x=1");
    assert_untouched("ssh://git@github.com/org/repo.git");
}

#[test]
fn a_url_password_inside_a_secret_named_assignment_is_a_url_password() {
    assert_redacts(
        "DB_PASSWORD=postgres://u:pw@h/d",
        "DB_PASSWORD=postgres://u:[redacted: url-password]@h/d",
        &[RedactionKind::UrlPassword],
    );
}

#[test]
fn kinds_are_listed_in_order_of_appearance_one_per_redaction() {
    let input = format!("a {GH_TOKEN} b {AWS_KEY} c {AWS_KEY} d DB_PASSWORD=x");
    assert_redacts(
        &input,
        "a [redacted: api-token] b [redacted: aws-access-key] c [redacted: aws-access-key] d DB_PASSWORD=[redacted: secret-assignment]",
        &[
            RedactionKind::ApiToken,
            RedactionKind::AwsAccessKey,
            RedactionKind::AwsAccessKey,
            RedactionKind::SecretAssignment,
        ],
    );
}

#[test]
fn text_with_no_secrets_comes_back_identical() {
    assert_untouched("ls -la\ntotal 0\n");
    assert_untouched("");
}

// ── hashes and identifiers are never secrets ──

#[test]
fn hashes_uuids_and_commit_ids_are_never_redacted() {
    for s in [
        "sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        "uuid 3f2504e0-4f89-11d3-9a0c-0305e82c3301",
        "commit 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d",
        "short 1a2b3c4",
        "etag W/\"33a64df551425fcc55e4d42a148795d9f25f89d4\"",
    ] {
        assert_untouched(s);
    }
}

// ── private keys ──

const PEM_BEGIN: &str = "-----BEGIN RSA PRIVATE KEY-----";
const PEM_END: &str = "-----END RSA PRIVATE KEY-----";

fn pem_body() -> String {
    "MIIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\nMIIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n".to_string()
}

#[test]
fn a_whole_private_key_block_becomes_one_marker() {
    let input = format!("before\n{PEM_BEGIN}\n{}{PEM_END}\nafter\n", pem_body());
    let mut r = Redactor::new();
    let (out, kinds) = r.redact(&input);
    assert_eq!(out, "before\n[redacted: private-key]\nafter\n");
    assert_eq!(kinds, vec![RedactionKind::PrivateKey]);
    assert!(!r.inside_private_key());
}

#[test]
fn any_private_key_flavour_is_redacted() {
    for label in [
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "OPENSSH PRIVATE KEY",
        "PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
    ] {
        let input = format!("-----BEGIN {label}-----\nFAKEFAKE\n-----END {label}-----\n");
        assert_redacts(
            &input,
            "[redacted: private-key]\n",
            &[RedactionKind::PrivateKey],
        );
    }
}

#[test]
fn a_public_key_block_is_not_a_private_key() {
    assert_untouched("-----BEGIN PUBLIC KEY-----\nFAKEFAKE\n-----END PUBLIC KEY-----\n");
}

#[test]
fn text_after_a_private_key_block_is_still_redacted_normally() {
    let input = format!("{PEM_BEGIN}\nFAKE\n{PEM_END}\nGITHUB_TOKEN={GH_TOKEN}\n");
    assert_redacts(
        &input,
        "[redacted: private-key]\nGITHUB_TOKEN=[redacted: api-token]\n",
        &[RedactionKind::PrivateKey, RedactionKind::ApiToken],
    );
}

#[test]
fn an_unterminated_private_key_redacts_to_the_end_and_remembers_it() {
    let mut r = Redactor::new();
    let (out, kinds) = r.redact(&format!("x\n{PEM_BEGIN}\nFAKEFAKE\nFAKEFAKE"));
    assert_eq!(out, "x\n[redacted: private-key]");
    assert_eq!(kinds, vec![RedactionKind::PrivateKey]);
    assert!(r.inside_private_key());
}

#[test]
fn a_private_key_split_across_calls_is_swallowed_up_to_the_end_marker() {
    let mut r = Redactor::new();
    let (out1, k1) = r.redact(&format!("{PEM_BEGIN}\nFAKEFAKE\n"));
    assert_eq!(out1, "[redacted: private-key]");
    assert_eq!(k1, vec![RedactionKind::PrivateKey]);
    assert!(r.inside_private_key());

    let (out2, k2) = r.redact(&format!("FAKEFAKE2\n{PEM_END}\nnormal text\n"));
    assert_eq!(out2, "[redacted: private-key]\nnormal text\n");
    assert_eq!(k2, vec![RedactionKind::PrivateKey]);
    assert!(!r.inside_private_key());

    // back to normal afterwards
    let (out3, k3) = r.redact("still normal\n");
    assert_eq!(out3, "still normal\n");
    assert!(k3.is_empty());
}

#[test]
fn a_call_entirely_inside_a_private_key_emits_one_marker_and_stays_inside() {
    let mut r = Redactor::new();
    r.redact(&format!("{PEM_BEGIN}\nFAKE\n"));
    let (out, kinds) = r.redact("FAKEFAKE\nFAKEFAKE\n");
    assert_eq!(out, "[redacted: private-key]");
    assert_eq!(kinds, vec![RedactionKind::PrivateKey]);
    assert!(r.inside_private_key());
    let (out, _) = r.redact(&format!("{PEM_END}\ndone\n"));
    assert_eq!(out, "[redacted: private-key]\ndone\n");
    assert!(!r.inside_private_key());
}

#[test]
fn a_fresh_redactor_is_not_inside_a_private_key() {
    assert!(!Redactor::new().inside_private_key());
}

#[test]
fn private_key_state_belongs_to_one_redactor() {
    let mut a = Redactor::new();
    a.redact(&format!("{PEM_BEGIN}\nFAKE"));
    assert!(a.inside_private_key());
    let (out, kinds) = Redactor::new().redact("ordinary text\n");
    assert_eq!(out, "ordinary text\n");
    assert!(kinds.is_empty());
}

// ── corpora ──

#[test]
fn negative_corpus_has_zero_redactions_and_is_returned_byte_for_byte() {
    assert!(
        NEGATIVE_CORPUS.lines().count() >= 150,
        "corpus must stay substantial"
    );
    let (out, kinds) = redact(NEGATIVE_CORPUS);
    assert!(kinds.is_empty(), "false positives: {kinds:?}");
    assert_eq!(out, NEGATIVE_CORPUS);
}

#[test]
fn negative_corpus_line_by_line_has_zero_redactions_too() {
    let mut r = Redactor::new();
    let mut rebuilt = String::new();
    for line in NEGATIVE_CORPUS.split_inclusive('\n') {
        let (out, kinds) = r.redact(line);
        assert!(kinds.is_empty(), "false positive on {line:?}: {kinds:?}");
        rebuilt.push_str(&out);
    }
    assert_eq!(rebuilt, NEGATIVE_CORPUS);
}

/// Distinctive fragments of every fake secret in the positive corpus.
const FAKE_SECRETS: &[&str] = &[
    "AKIAFAKEFAKEFAKEFAKE",
    "ASIAFAKEFAKEFAKE0001",
    "wJalrFAKEFAKE/K7MDENG/bPxRfiCYFAKEKEY40",
    "wJalrFAKEFAKE/K7MDENG/bPxRfiCYFAKEKEY41",
    "FAKEFAKESESSIONTOKEN",
    "FakePassw0rdNotReal",
    "Fake Quoted Pass",
    "ghp_FAKE",
    "sk-FAKEFAKE",
    "sk_live_FAKE",
    "xoxb-FAKEFAKEFAKE",
    "FAKEFAKEFAKEFAKE@o0.ingest",
    "base64:FAKEFAKE",
    "fakemailpassword",
    "fake-jwt-secret-value",
    "fakepusherkey",
    "fakepushersecret",
    "FakeDbPass123",
    "FakeRootPw",
    "fake-client-secret-value",
    "Bearer FAKEFAKE",
    "eyJhbGciOiJIUzI1NiJ9",
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
    "eyJzdWIiOiJGQUtFIn0",
    "github_pat_",
    "MIIFAKEFAKE",
    "b3BlbnNzaC1rZXktdjEFAKE",
    "BEGIN RSA PRIVATE KEY",
    "BEGIN OPENSSH PRIVATE KEY",
];

fn count(kinds: &[RedactionKind], k: RedactionKind) -> usize {
    kinds.iter().filter(|x| **x == k).count()
}

#[test]
fn positive_corpus_is_fully_redacted_with_exact_per_kind_counts() {
    let (out, kinds) = redact(POSITIVE_CORPUS);

    assert_eq!(count(&kinds, RedactionKind::AwsAccessKey), 2, "{kinds:?}");
    assert_eq!(count(&kinds, RedactionKind::AwsSecretKey), 3, "{kinds:?}");
    assert_eq!(count(&kinds, RedactionKind::BearerToken), 2, "{kinds:?}");
    assert_eq!(count(&kinds, RedactionKind::ApiToken), 6, "{kinds:?}");
    assert_eq!(
        count(&kinds, RedactionKind::SecretAssignment),
        9,
        "{kinds:?}"
    );
    assert_eq!(count(&kinds, RedactionKind::UrlPassword), 2, "{kinds:?}");
    assert_eq!(count(&kinds, RedactionKind::PrivateKey), 2, "{kinds:?}");
    assert_eq!(kinds.len(), 26);

    for secret in FAKE_SECRETS {
        assert!(!out.contains(secret), "leaked {secret:?}");
    }
    for kind in [
        RedactionKind::AwsAccessKey,
        RedactionKind::AwsSecretKey,
        RedactionKind::BearerToken,
        RedactionKind::ApiToken,
        RedactionKind::SecretAssignment,
        RedactionKind::UrlPassword,
        RedactionKind::PrivateKey,
    ] {
        assert_eq!(
            out.matches(&format!("[redacted: {}]", kind.as_str()))
                .count(),
            count(&kinds, kind),
            "one visible marker per {kind:?} entry"
        );
    }
}

#[test]
fn positive_corpus_keeps_names_and_everything_around_the_secrets() {
    let (out, _) = redact(POSITIVE_CORPUS);
    let lines: Vec<&str> = out.lines().collect();
    for expected in [
        "AWS_ACCESS_KEY_ID=[redacted: aws-access-key]",
        "AWS_SECRET_ACCESS_KEY=[redacted: aws-secret-key]",
        "DB_PASSWORD=[redacted: secret-assignment]",
        "GITHUB_TOKEN=[redacted: api-token]",
        "OPENAI_API_KEY=[redacted: api-token]",
        "SENTRY_LARAVEL_DSN=[redacted: secret-assignment]",
        "SLACK_BOT_TOKEN=[redacted: api-token]",
        "STRIPE_SECRET=[redacted: api-token]",
        "APP_KEY=[redacted: secret-assignment]",
        "MAIL_PASSWORD=[redacted: secret-assignment]",
        "JWT_SECRET=[redacted: secret-assignment]",
        "PUSHER_APP_KEY=[redacted: secret-assignment]",
        "PUSHER_APP_SECRET=[redacted: secret-assignment]",
        "DATABASE_URL=postgres://app:[redacted: url-password]@db.internal:5432/app",
        "LEGACY_URL=mysql://root:[redacted: url-password]@127.0.0.1/app",
        "aws_access_key_id = [redacted: aws-access-key]",
        "aws_secret_access_key = [redacted: aws-secret-key]",
        "aws_session_token = [redacted: aws-secret-key]",
        "      client_secret: [redacted: secret-assignment]",
        "  501  curl -s -H \"Authorization: Bearer [redacted: bearer-token]\" https://api.example.test/v1/me",
        "  502  curl -s -H \"Authorization: Bearer [redacted: bearer-token]\" https://api.example.test/v1/me",
        "  503  echo [redacted: api-token] | gh auth login --with-token",
        "Issued JWT [redacted: api-token]",
        // ordinary lines survive untouched
        "APP_ENV=production",
        "AWS_DEFAULT_REGION=us-east-1",
        "DB_HOST=db.internal",
        "HOME=/root",
        "services:",
    ] {
        assert!(lines.contains(&expected), "missing line {expected:?} in:\n{out}");
    }
    assert!(
        out.contains("$ cat id_rsa\n[redacted: private-key]\n$ cat ~/.ssh/id_ed25519\n[redacted: private-key]\n$ \n"),
        "each PEM block collapses to one marker between its commands:\n{out}"
    );
}

#[test]
fn positive_corpus_fed_line_by_line_never_leaks_a_secret() {
    let mut r = Redactor::new();
    let mut out = String::new();
    for line in POSITIVE_CORPUS.split_inclusive('\n') {
        out.push_str(&r.redact(line).0);
    }
    for secret in FAKE_SECRETS {
        assert!(
            !out.contains(secret),
            "leaked {secret:?} when fed line by line"
        );
    }
    assert!(!r.inside_private_key(), "corpus ends outside any key");
}

#[test]
fn positive_corpus_fed_in_arbitrary_chunks_never_leaks_a_secret_inside_a_private_key() {
    // Chunks of about 200 bytes, cut at the next line end: the redactor is
    // fed whole lines (a secret split mid-line across calls is out of
    // contract). Chunk boundaries land inside the PEM blocks, so the state
    // must carry.
    let mut r = Redactor::new();
    let mut out = String::new();
    let bytes = POSITIVE_CORPUS;
    let mut start = 0;
    let mut carried = false;
    while start < bytes.len() {
        let mut end = (start + 200).min(bytes.len());
        while end < bytes.len() && !bytes[..end].ends_with('\n') {
            end += 1;
        }
        out.push_str(&r.redact(&bytes[start..end]).0);
        carried |= r.inside_private_key();
        start = end;
    }
    assert!(
        carried,
        "a chunk boundary must fall inside a private-key block"
    );
    for secret in ["MIIFAKEFAKE", "b3BlbnNzaC1rZXktdjEFAKE"] {
        assert!(
            !out.contains(secret),
            "leaked {secret:?} with 200-byte chunks"
        );
    }
}

// ───────────────────────────── pipeline: bytes -> text -> redaction ──────────

#[test]
fn a_secret_interleaved_with_colour_codes_is_redacted_after_assembly() {
    let raw = format!("\x1b[32mGITHUB_TOKEN\x1b[0m=\x1b[33m{GH_TOKEN}\x1b[0m\r\n");
    let got = assemble(raw.as_bytes());
    assert_eq!(got.lines.len(), 1);
    let (out, kinds) = redact(&got.lines[0]);
    assert_eq!(out, "GITHUB_TOKEN=[redacted: api-token]");
    assert_eq!(kinds, vec![RedactionKind::ApiToken]);
}

#[test]
fn a_secret_split_by_a_carriage_return_redraw_is_judged_on_its_final_text() {
    let got = assemble(b"DB_PASSWORD=wrong\rDB_PASSWORD=hunter2\n");
    assert_eq!(got.lines, vec!["DB_PASSWORD=hunter2".to_string()]);
    let (out, kinds) = redact(&got.lines[0]);
    assert_eq!(out, "DB_PASSWORD=[redacted: secret-assignment]");
    assert_eq!(kinds, vec![RedactionKind::SecretAssignment]);
}

#[test]
fn assembled_lines_then_deliver_end_to_end_for_a_noisy_command() {
    let mut raw = Vec::new();
    for i in 0..1000 {
        raw.extend_from_slice(format!("\x1b[32mrow {i}\x1b[0m\r\n").as_bytes());
    }
    let mut a = LineAssembler::new();
    a.feed(&raw);
    let Delivery::Text {
        text,
        lines_total,
        omitted,
        redactions,
    } = deliver(&mut a, &mut Redactor::new(), &mut DeliveryPolicy::new())
    else {
        panic!("a plain command is never withheld");
    };
    assert_eq!(lines_total, 1000);
    assert_eq!(omitted, 850);
    assert!(redactions.is_empty());
    assert!(text.starts_with("row 0\n"));
    assert!(text.ends_with("row 999"));
    assert!(!text.contains('\x1b'));
}
