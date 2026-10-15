//! The shell tokenizer behind the production-shell guard. It reads a command line the way a shell
//! would just far enough to answer "which commands would this run, with which words?", including the
//! commands hidden in `$( )`, backticks, subshells, here-docs fed to a shell, and `bash -c` / `eval`
//! payloads. It is a tokenizer, not a parser: input it cannot balance is reported as `unparsed`, and
//! whatever it found before the error is still reported.
//!
//! These tests state the contract from the outside: word texts, command counts, separator kinds,
//! here-doc fields, `dynamic`, `depth` and `unparsed`. Spans are checked only where they are
//! unambiguous (a top-level separator, a top-level word, a here-doc body).

use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use nostromo::approvals::shell::{parse, HereDoc, SepKind, ShellParse, SimpleCommand, MAX_DEPTH};

// ── helpers ───────────────────────────────────────────────────────────────────

/// The word texts of every command found, in order.
fn cmds(input: &str) -> Vec<Vec<String>> {
    parse(input)
        .commands
        .iter()
        .map(|c| c.texts().iter().map(|t| t.to_string()).collect())
        .collect()
}

/// The command whose words are exactly `texts`, if any.
fn find<'a>(p: &'a ShellParse, texts: &[&str]) -> Option<&'a SimpleCommand> {
    p.commands.iter().find(|c| c.texts() == texts)
}

/// Assert a command with exactly these word texts exists at exactly this depth.
#[track_caller]
fn assert_command_at(input: &str, texts: &[&str], depth: u32) {
    let p = parse(input);
    let hit = p.commands.iter().any(|c| c.texts() == texts && c.depth == depth);
    assert!(
        hit,
        "expected {texts:?} at depth {depth} in {input:?}, found {:?}",
        p.commands
            .iter()
            .map(|c| (c.texts(), c.depth))
            .collect::<Vec<_>>()
    );
}

/// The only command in `input`'s parse, failing if there is not exactly one.
#[track_caller]
fn only_command(input: &str) -> SimpleCommand {
    let mut p = parse(input);
    assert_eq!(
        p.commands.len(),
        1,
        "expected exactly one command in {input:?}, found {:?}",
        p.commands.iter().map(|c| c.texts()).collect::<Vec<_>>()
    );
    p.commands.remove(0)
}

fn sep_kinds(input: &str) -> Vec<SepKind> {
    parse(input).separators.iter().map(|s| s.kind).collect()
}

/// A here-doc's body as sliced out of the input.
fn body<'a>(input: &'a str, h: &HereDoc) -> &'a str {
    &input[h.body_span.clone()]
}

// ── 1. words and quoting ──────────────────────────────────────────────────────

#[test]
fn plain_words_are_split_on_whitespace() {
    assert_eq!(cmds("ls -la  /tmp\tfoo"), vec![vec!["ls", "-la", "/tmp", "foo"]]);
}

#[test]
fn single_quotes_are_literal_and_not_dynamic() {
    let c = only_command("echo 'single quoted' '$HOME' 'a\\b'");
    assert_eq!(c.texts(), vec!["echo", "single quoted", "$HOME", "a\\b"]);
    assert!(c.words.iter().all(|w| !w.dynamic), "single quotes never expand");
}

#[test]
fn double_quotes_keep_variable_text_verbatim_and_mark_the_word_dynamic() {
    let c = only_command(r#"echo "double $X""#);
    assert_eq!(c.texts(), vec!["echo", "double $X"]);
    assert!(!c.words[0].dynamic);
    assert!(c.words[1].dynamic);
}

#[test]
fn unquoted_variables_are_dynamic() {
    let c = only_command("echo $HOME ${X:-y} plain");
    assert_eq!(c.texts(), vec!["echo", "$HOME", "${X:-y}", "plain"]);
    assert!(!c.words[0].dynamic);
    assert!(c.words[1].dynamic);
    assert!(c.words[2].dynamic);
    assert!(!c.words[3].dynamic);
}

#[test]
fn backslash_outside_quotes_escapes_the_next_character() {
    let c = only_command(r"echo a\ b");
    assert_eq!(c.texts(), vec!["echo", "a b"], "an escaped space stays inside one word");

    let c = only_command(r"echo \$X");
    assert_eq!(c.texts(), vec!["echo", "$X"]);
    assert!(!c.words[1].dynamic, "an escaped dollar is not an expansion");

    let c = only_command(r"echo a\;b");
    assert_eq!(c.texts(), vec!["echo", "a;b"]);
    assert!(sep_kinds(r"echo a\;b").is_empty(), "an escaped semicolon is not a separator");
}

#[test]
fn inside_double_quotes_only_quote_backslash_and_dollar_are_escapes() {
    let c = only_command(r#"echo "a\"b" "a\\b" "a\$b" "a\nb""#);
    assert_eq!(c.texts(), vec!["echo", "a\"b", "a\\b", "a$b", "a\\nb"]);
    assert!(!c.words[3].dynamic, "an escaped dollar in double quotes is not an expansion");
}

#[test]
fn adjacent_quoted_and_unquoted_pieces_concatenate_into_one_word() {
    assert_eq!(cmds(r#"e"c"s_connect ap"#), vec![vec!["ecs_connect", "ap"]]);
    assert_eq!(cmds(r#"echo 'a'"b"c"#), vec![vec!["echo", "abc"]]);
    assert_eq!(cmds(r#"ec''ho hi"#), vec![vec!["echo", "hi"]]);
}

#[test]
fn ansi_c_quoting_resolves_escapes() {
    let cases: &[(&str, &str)] = &[
        (r"echo $'a\tb'", "a\tb"),
        (r"echo $'\x65cs'", "ecs"),
        (r"echo $'\145'", "e"),
        (r"echo $'it\'s'", "it's"),
        (r"echo $'a\nb'", "a\nb"),
    ];
    for (input, expected) in cases {
        let c = only_command(input);
        assert_eq!(c.texts(), vec!["echo", *expected], "input {input:?}");
        assert!(!c.words[1].dynamic, "ANSI-C text is literal: {input:?}");
    }
}

#[test]
fn ansi_c_quoting_can_spell_a_command_name() {
    assert_eq!(cmds(r"$'\x65cs_connect' ap"), vec![vec!["ecs_connect", "ap"]]);
}

#[test]
fn backslash_newline_joins_lines() {
    let input = "echo a\\\nb";
    assert_eq!(cmds(input), vec![vec!["echo", "ab"]]);
    assert!(sep_kinds(input).is_empty(), "a continuation is not a newline separator");
}

#[test]
fn empty_quotes_produce_an_empty_word() {
    assert_eq!(cmds("echo ''"), vec![vec!["echo", ""]]);
    assert_eq!(cmds(r#"echo """#), vec![vec!["echo", ""]]);
}

#[test]
fn a_top_level_word_span_slices_to_its_raw_source_text() {
    let input = r#"echo 'a b' "c"d plain"#;
    let c = only_command(input);
    let raw: Vec<&str> = c.words.iter().map(|w| &input[w.span.clone()]).collect();
    assert_eq!(raw, vec!["echo", "'a b'", r#""c"d"#, "plain"]);
}

// ── 2. separators and redirections ────────────────────────────────────────────

#[test]
fn every_separator_splits_commands_and_is_reported_in_order() {
    let input = "a && b || c; d | e & f\ng";
    assert_eq!(cmds(input).len(), 7);
    assert_eq!(
        sep_kinds(input),
        vec![
            SepKind::And,
            SepKind::Or,
            SepKind::Semi,
            SepKind::Pipe,
            SepKind::Background,
            SepKind::Newline
        ]
    );
}

#[test]
fn a_top_level_separator_span_slices_to_its_operator() {
    let input = "a && b || c; d | e & f\ng";
    let p = parse(input);
    let sliced: Vec<&str> = p.separators.iter().map(|s| &input[s.span.clone()]).collect();
    assert_eq!(sliced, vec!["&&", "||", ";", "|", "&", "\n"]);
}

#[test]
fn pipe_ampersand_is_a_pipe() {
    let input = "a |& b";
    let p = parse(input);
    assert_eq!(cmds(input), vec![vec!["a"], vec!["b"]]);
    assert_eq!(p.separators.len(), 1);
    assert_eq!(p.separators[0].kind, SepKind::Pipe);
    assert_eq!(&input[p.separators[0].span.clone()], "|&");
}

#[test]
fn separators_inside_quotes_are_not_separators() {
    let input = r#"echo "a && b" 'c; d' "e | f""#;
    assert_eq!(cmds(input), vec![vec!["echo", "a && b", "c; d", "e | f"]]);
    assert!(sep_kinds(input).is_empty());
}

#[test]
fn fd_duplication_and_combined_redirects_are_neither_separators_nor_words() {
    for input in [
        "cmd 2>&1 >/dev/null",
        "cmd &>/dev/null",
        "cmd >&2",
        "cmd 2>/dev/null",
    ] {
        assert_eq!(cmds(input), vec![vec!["cmd"]], "input {input:?}");
        assert!(sep_kinds(input).is_empty(), "no separator in {input:?}");
        assert!(!parse(input).unparsed, "{input:?} is balanced");
    }
}

#[test]
fn redirection_operators_and_their_targets_are_dropped_from_the_words() {
    assert_eq!(cmds("cat > out.txt"), vec![vec!["cat"]]);
    assert_eq!(cmds("cat >> out.txt"), vec![vec!["cat"]]);
    assert_eq!(cmds("cat < in.txt"), vec![vec!["cat"]]);
    assert_eq!(cmds("grep x < in.txt > out.txt file"), vec![vec!["grep", "x", "file"]]);
    assert_eq!(cmds("grep x >out.txt file"), vec![vec!["grep", "x", "file"]]);
}

#[test]
fn a_here_string_is_a_redirection_not_a_here_doc() {
    let input = "cat <<< foo";
    let p = parse(input);
    assert_eq!(cmds(input), vec![vec!["cat"]]);
    assert!(p.heredocs.is_empty());
    assert!(!p.unparsed);
}

// ── 3. comments ───────────────────────────────────────────────────────────────

#[test]
fn a_trailing_comment_hides_everything_after_it() {
    let input = "echo hi # comment && rm x";
    assert_eq!(cmds(input), vec![vec!["echo", "hi"]]);
    assert!(sep_kinds(input).is_empty());
}

#[test]
fn a_hash_inside_a_word_is_not_a_comment() {
    assert_eq!(cmds("echo a#b"), vec![vec!["echo", "a#b"]]);
}

#[test]
fn a_hash_inside_quotes_is_not_a_comment() {
    assert_eq!(cmds(r#"echo "a #b" '#c'"#), vec![vec!["echo", "a #b", "#c"]]);
}

#[test]
fn a_comment_on_its_own_line_between_commands_is_ignored() {
    let input = "echo a\n# rm -rf x && foo\necho b";
    assert_eq!(cmds(input), vec![vec!["echo", "a"], vec!["echo", "b"]]);
}

// ── 4. command substitution ───────────────────────────────────────────────────

#[test]
fn a_dollar_paren_substitution_exposes_the_inner_command_at_the_same_depth() {
    let p = parse("echo $(tmux send-keys -t %7 x)");
    let outer = find(&p, &["echo", "$(tmux send-keys -t %7 x)"]).expect("outer echo command");
    assert!(outer.words[1].dynamic);
    assert_eq!(outer.depth, 0);
    let inner = find(&p, &["tmux", "send-keys", "-t", "%7", "x"]).expect("inner tmux command");
    assert_eq!(inner.depth, 0, "a substitution is not a -c/eval payload");
}

#[test]
fn nested_substitutions_expose_every_level() {
    let p = parse("echo $(a $(b))");
    assert!(find(&p, &["a", "$(b)"]).is_some(), "found {:?}", cmds("echo $(a $(b))"));
    assert!(find(&p, &["b"]).is_some());
}

#[test]
fn a_substitution_inside_double_quotes_is_still_found() {
    let p = parse(r#"echo "x $(ls -la) y""#);
    assert!(find(&p, &["ls", "-la"]).is_some());
    let outer = find(&p, &["echo", "x $(ls -la) y"]).expect("outer echo command");
    assert!(outer.words[1].dynamic);
}

#[test]
fn backticks_expose_the_inner_command() {
    let p = parse("echo `ls -la`");
    assert!(find(&p, &["ls", "-la"]).is_some());
    let outer = find(&p, &["echo", "`ls -la`"]).expect("outer echo command");
    assert!(outer.words[1].dynamic);
}

#[test]
fn arithmetic_expansion_is_not_a_command() {
    let input = "echo $(( 1 + 2 ))";
    let p = parse(input);
    assert!(!p.unparsed);
    assert!(
        p.commands.iter().all(|c| c.texts()[0] != "1"),
        "arithmetic must not be read as a command: {:?}",
        cmds(input)
    );
    let outer = &p.commands[0];
    assert_eq!(outer.texts(), vec!["echo", "$(( 1 + 2 ))"]);
    assert!(outer.words[1].dynamic);
}

#[test]
fn separators_inside_a_substitution_are_not_top_level_separators() {
    for input in ["echo $(a; b)", "echo $(a && b | c)", "echo `a; b`"] {
        assert!(sep_kinds(input).is_empty(), "input {input:?}");
        assert!(cmds(input).len() >= 3, "inner commands found for {input:?}: {:?}", cmds(input));
    }
}

// ── 5. subshells, groups, process substitution ────────────────────────────────

#[test]
fn a_subshell_exposes_its_commands_and_has_no_top_level_separators() {
    let input = "(cd /tmp && ls)";
    let p = parse(input);
    assert!(find(&p, &["cd", "/tmp"]).is_some());
    assert!(find(&p, &["ls"]).is_some());
    assert!(p.separators.is_empty());
    assert!(!p.unparsed);
}

#[test]
fn a_brace_group_exposes_its_commands() {
    let p = parse("{ a; b; }");
    assert!(!p.unparsed);
    let first_real_word = |c: &SimpleCommand| {
        c.texts().into_iter().find(|t| *t != "{" && *t != "}").map(str::to_string)
    };
    let firsts: Vec<Option<String>> = p.commands.iter().map(first_real_word).collect();
    assert!(firsts.contains(&Some("a".to_string())), "found {firsts:?}");
    assert!(firsts.contains(&Some("b".to_string())), "found {firsts:?}");
}

#[test]
fn process_substitution_exposes_the_inner_commands() {
    let p = parse("diff <(ls a) <(ls b)");
    assert!(!p.unparsed);
    assert!(find(&p, &["ls", "a"]).is_some(), "found {:?}", cmds("diff <(ls a) <(ls b)"));
    assert!(find(&p, &["ls", "b"]).is_some());
    assert!(p.commands.iter().any(|c| c.texts()[0] == "diff"));
}

#[test]
fn output_process_substitution_exposes_the_inner_command() {
    let p = parse("tee >(wc -l)");
    assert!(!p.unparsed);
    assert!(find(&p, &["wc", "-l"]).is_some());
}

// ── 6. here-docs ──────────────────────────────────────────────────────────────

#[test]
fn an_unquoted_heredoc_reports_its_delimiter_and_body_and_hides_the_body_from_commands() {
    let input = "cat <<EOF\nline1\n$X\nEOF\necho after";
    let p = parse(input);
    assert!(!p.unparsed);
    assert_eq!(p.heredocs.len(), 1);
    let h = &p.heredocs[0];
    assert_eq!(h.delimiter, "EOF");
    assert!(!h.quoted);
    assert!(!h.strip_tabs);
    assert_eq!(body(input, h), "line1\n$X\n");
    assert_eq!(cmds(input), vec![vec!["cat"], vec!["echo", "after"]]);
}

#[test]
fn a_heredoc_with_no_lines_has_an_empty_body() {
    let input = "cat <<EOF\nEOF\n";
    let p = parse(input);
    assert!(!p.unparsed);
    assert_eq!(p.heredocs.len(), 1);
    assert_eq!(body(input, &p.heredocs[0]), "");
}

#[test]
fn a_heredoc_terminator_at_the_very_end_of_input_needs_no_trailing_newline() {
    let input = "cat <<EOF\nx\nEOF";
    let p = parse(input);
    assert!(!p.unparsed);
    assert_eq!(p.heredocs.len(), 1);
    assert_eq!(body(input, &p.heredocs[0]), "x\n");
}

#[test]
fn quoted_heredoc_delimiters_are_unquoted_and_flagged() {
    for (op, label) in [("<<'EOF'", "single"), ("<<\"EOF\"", "double"), ("<<\\EOF", "backslash")] {
        let input = format!("cat {op}\n$X\nEOF\n");
        let p = parse(&input);
        assert!(!p.unparsed, "{label}: {input:?}");
        assert_eq!(p.heredocs.len(), 1, "{label}");
        let h = &p.heredocs[0];
        assert_eq!(h.delimiter, "EOF", "{label}");
        assert!(h.quoted, "{label}");
        assert!(!h.strip_tabs, "{label}");
        assert_eq!(body(&input, h), "$X\n", "{label}");
    }
}

#[test]
fn a_dash_heredoc_accepts_a_tab_indented_terminator_and_strips_tabs() {
    let input = "cat <<-EOF\n\tline\n\tEOF\necho after";
    let p = parse(input);
    assert!(!p.unparsed);
    assert_eq!(p.heredocs.len(), 1);
    let h = &p.heredocs[0];
    assert!(h.strip_tabs);
    assert_eq!(h.delimiter, "EOF");
    assert_eq!(body(input, h), "\tline\n");
    assert_eq!(cmds(input), vec![vec!["cat"], vec!["echo", "after"]]);
}

#[test]
fn without_a_dash_an_indented_terminator_does_not_terminate() {
    let p = parse("cat <<EOF\nline\n\tEOF\n");
    assert!(p.unparsed);
}

#[test]
fn two_heredocs_on_one_line_are_reported_in_order() {
    let input = "cat <<A <<B\na\nA\nb\nB";
    let p = parse(input);
    assert!(!p.unparsed);
    assert_eq!(p.heredocs.len(), 2);
    assert_eq!(p.heredocs[0].delimiter, "A");
    assert_eq!(body(input, &p.heredocs[0]), "a\n");
    assert_eq!(p.heredocs[1].delimiter, "B");
    assert_eq!(body(input, &p.heredocs[1]), "b\n");
    assert_eq!(cmds(input), vec![vec!["cat"]]);
}

#[test]
fn an_unterminated_heredoc_is_unparsed() {
    assert!(parse("cat <<EOF\nline1\nline2\n").unparsed);
    assert!(parse("cat <<EOF").unparsed);
}

#[test]
fn a_heredoc_fed_to_a_shell_is_parsed_as_a_script_one_level_deeper() {
    for shell in ["bash", "sh", "zsh"] {
        let input = format!("{shell} <<EOF\necs_connect ap production portal\nEOF\n");
        let p = parse(&input);
        assert!(!p.unparsed, "{shell}");
        assert_command_at(&input, &["ecs_connect", "ap", "production", "portal"], 1);
        assert_command_at(&input, &[shell], 0);
        assert_eq!(p.heredocs.len(), 1, "{shell}: the here-doc is still reported");
    }
}

#[test]
fn a_quoted_heredoc_fed_to_a_shell_is_parsed_as_a_script_too() {
    let input = "bash <<'EOF'\necs_connect ap production portal\nEOF\n";
    assert_command_at(input, &["ecs_connect", "ap", "production", "portal"], 1);
    assert!(parse(input).heredocs[0].quoted);
}

#[test]
fn a_heredoc_fed_to_cat_is_data_not_commands() {
    let input = "cat <<EOF\nrm -rf /\necs_connect ap production portal\nEOF\n";
    assert_eq!(cmds(input), vec![vec!["cat"]]);
}

// ── 7. -c and eval payloads ───────────────────────────────────────────────────

#[test]
fn a_bash_dash_c_payload_is_parsed_one_level_deeper() {
    let input = "bash -c 'ecs_connect ap prod x'";
    assert_command_at(input, &["ecs_connect", "ap", "prod", "x"], 1);
    assert_command_at(input, &["bash", "-c", "ecs_connect ap prod x"], 0);
    assert!(!parse(input).unparsed);
}

#[test]
fn dash_c_payloads_are_found_for_every_shell_and_flag_spelling() {
    let cases = [
        "sh -c 'ecs_connect ap prod x'",
        "zsh -c 'ecs_connect ap prod x'",
        "/bin/bash -c 'ecs_connect ap prod x'",
        "bash -lc 'ecs_connect ap prod x'",
        "bash -ec 'ecs_connect ap prod x'",
        "bash -l -c 'ecs_connect ap prod x'",
        r#"bash -c "ecs_connect ap prod x""#,
        "env FOO=1 bash -c 'ecs_connect ap prod x'",
    ];
    for input in cases {
        assert_command_at(input, &["ecs_connect", "ap", "prod", "x"], 1);
        let p = parse(input);
        assert!(!p.unparsed, "{input:?}");
        assert_eq!(
            p.commands.iter().filter(|c| c.depth == 0).count(),
            1,
            "exactly one outer command in {input:?}"
        );
    }
}

#[test]
fn an_env_prefix_stays_in_the_outer_command() {
    let p = parse("env FOO=1 bash -c 'ls'");
    let outer = p.commands.iter().find(|c| c.depth == 0).expect("outer command");
    assert_eq!(outer.texts()[0], "env");
}

#[test]
fn a_dash_c_payload_with_several_commands_exposes_all_of_them() {
    let input = "bash -c 'cd /tmp && ecs_connect ap prod x; ls'";
    assert_command_at(input, &["cd", "/tmp"], 1);
    assert_command_at(input, &["ecs_connect", "ap", "prod", "x"], 1);
    assert_command_at(input, &["ls"], 1);
    assert!(
        parse(input).separators.is_empty(),
        "separators inside a payload are not top-level separators"
    );
}

#[test]
fn nested_dash_c_payloads_add_one_level_each() {
    let input = r#"bash -c "sh -c 'tmux send-keys -t %7 x'""#;
    assert_command_at(input, &["tmux", "send-keys", "-t", "%7", "x"], 2);
    assert_command_at(input, &["sh", "-c", "tmux send-keys -t %7 x"], 1);
    assert!(!parse(input).unparsed);
}

#[test]
fn an_eval_payload_is_parsed_one_level_deeper() {
    let input = r#"eval "tmux send-keys -t %7 x""#;
    assert_command_at(input, &["tmux", "send-keys", "-t", "%7", "x"], 1);
    assert!(!parse(input).unparsed);
}

#[test]
fn unquoted_eval_arguments_are_joined_with_spaces_and_parsed() {
    let input = "eval tmux send-keys -t %7 x";
    assert_command_at(input, &["tmux", "send-keys", "-t", "%7", "x"], 1);
    assert!(!parse(input).unparsed);
}

#[test]
fn chained_evals_add_one_level_each() {
    assert_command_at("eval eval eval ls", &["ls"], 3);
}

#[test]
fn an_unbalanced_dash_c_payload_makes_the_whole_parse_unparsed() {
    assert!(parse(r#"bash -c 'echo "abc'"#).unparsed);
    assert!(parse(r#"eval "echo 'abc""#).unparsed);
}

#[test]
fn nesting_beyond_max_depth_is_unparsed_and_terminates() {
    let input = "eval ".repeat(MAX_DEPTH as usize + 2) + "ls";
    let p = parse(&input);
    assert!(p.unparsed);
}

#[test]
fn nesting_within_max_depth_is_fine() {
    let input = "eval ".repeat(3) + "ls";
    let p = parse(&input);
    assert!(!p.unparsed);
}

#[test]
fn deeply_nested_substitutions_beyond_max_depth_are_unparsed_without_overflowing() {
    let n = MAX_DEPTH as usize + 2;
    let balanced = format!("{}ls{}", "echo $(".repeat(n), ")".repeat(n));
    assert!(parse(&balanced).unparsed);

    let hostile = "$(".repeat(20_000);
    assert!(parse(&hostile).unparsed);
    let hostile = "(".repeat(20_000);
    assert!(parse(&hostile).unparsed);
}

// ── 8. unbalanced input ───────────────────────────────────────────────────────

#[test]
fn unbalanced_input_is_unparsed() {
    let cases = [
        "echo 'abc",
        "echo \"abc",
        "echo $(ls",
        "echo `ls",
        "(ls",
        "ls)",
        "echo $'abc",
    ];
    for input in cases {
        assert!(parse(input).unparsed, "{input:?} should be unparsed");
    }
}

#[test]
fn balanced_input_is_not_unparsed() {
    let cases = [
        "echo 'abc'",
        "echo \"abc\"",
        "echo $(ls)",
        "echo `ls`",
        "(ls)",
        "echo $'abc'",
        "ls; echo hi",
    ];
    for input in cases {
        assert!(!parse(input).unparsed, "{input:?} should be parsed");
    }
}

#[test]
fn what_was_found_before_an_error_is_still_reported() {
    let p = parse("ls; echo 'oops");
    assert!(p.unparsed);
    assert!(find(&p, &["ls"]).is_some());
}

// ── 9. robustness ─────────────────────────────────────────────────────────────

#[test]
fn empty_and_whitespace_only_input_has_no_commands_and_is_not_unparsed() {
    for input in ["", " ", "   \t  ", "\t"] {
        let p = parse(input);
        assert!(p.commands.is_empty(), "{input:?}");
        assert!(!p.unparsed, "{input:?}");
    }
}

#[test]
fn non_ascii_text_yields_correct_words_and_char_boundary_valid_spans() {
    let input = "echo héllo ✓";
    let c = only_command(input);
    assert_eq!(c.texts(), vec!["echo", "héllo", "✓"]);
    let raw: Vec<&str> = c.words.iter().map(|w| &input[w.span.clone()]).collect();
    assert_eq!(raw, vec!["echo", "héllo", "✓"]);

    let input = "echo \"héllo ✓\" && ls 'ü'";
    let p = parse(input);
    assert_eq!(cmds(input), vec![vec!["echo", "héllo ✓"], vec!["ls", "ü"]]);
    for c in p.commands.iter().filter(|c| c.depth == 0) {
        for w in &c.words {
            let _ = &input[w.span.clone()];
        }
    }
    assert_eq!(&input[p.separators[0].span.clone()], "&&");
}

/// Pseudo-random strings (a fixed-seed LCG, no crates) over `tokens`; every parse must return, and
/// every top-level span it reports must slice the input without panicking.
fn fuzz(tokens: &[&str], iterations: usize, seed: u64) {
    let mut state = seed;
    let mut next = move || {
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (state >> 33) as usize
    };
    for _ in 0..iterations {
        let len = 1 + next() % 40;
        let input: String = (0..len).map(|_| tokens[next() % tokens.len()]).collect();
        let p = parse(&input);
        for c in p.commands.iter().filter(|c| c.depth == 0) {
            for w in &c.words {
                let _ = &input[w.span.clone()];
            }
        }
        for s in &p.separators {
            let _ = &input[s.span.clone()];
        }
        for h in &p.heredocs {
            let _ = &input[h.body_span.clone()];
        }
    }
}

/// Run `f` on its own thread and fail if it has not finished within `limit`.
fn must_finish_within(limit: Duration, f: impl FnOnce() + Send + 'static) {
    let (tx, rx) = mpsc::channel();
    let started = Instant::now();
    let handle = thread::spawn(move || {
        f();
        let _ = tx.send(());
    });
    match rx.recv_timeout(limit) {
        Ok(()) => {
            handle.join().expect("worker panicked");
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            // The worker dropped the sender without finishing: it panicked. Surface its message.
            handle.join().expect("worker panicked");
            panic!("worker ended without finishing");
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            panic!("did not finish within {limit:?} (ran {:?})", started.elapsed())
        }
    }
}

#[test]
fn random_shell_punctuation_never_panics_or_hangs() {
    let tokens = [
        "a", "b", "'", "\"", "\\", "$", "(", ")", "{", "}", ";", "&", "|", "<", ">", "#", "\n",
        "\t", " ", "-c",
    ];
    must_finish_within(Duration::from_secs(60), move || fuzz(&tokens, 5_000, 0x5eed));
}

#[test]
fn random_shell_fragments_with_payloads_heredocs_and_non_ascii_never_panic_or_hang() {
    let tokens = [
        "bash ", "sh ", "eval ", "-c ", "-lc ", "<<EOF\n", "<<-EOF\n", "<<'EOF'\n", "EOF", "\n",
        "$(", ")", "`", "'", "\"", "$'", "\\", " ", "é", "✓", "echo ", ";", "&&", "|&", "<(",
    ];
    must_finish_within(Duration::from_secs(60), move || fuzz(&tokens, 5_000, 0xbadc0de));
}
