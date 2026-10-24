//! Unified-diff parser: raw `git`/GitHub diff text → the structured
//! [`DiffFile`]/[`DiffHunk`]/[`DiffLine`] wire model (W2 — curated-agent-views).
//!
//! ## Why the daemon parses and the client renders (D3)
//!
//! A diff pane has to be *line-addressable*: `Anchor::Line { path, line }` must
//! resolve to exactly one row. Only something that has parsed the hunk headers
//! knows which side of a hunk a given new-file line number lives on, so the
//! resolution can't be a client-side string scan over `+`/`-` prefixes. Parsing
//! once, daemon-side, means every client (macOS, iOS, TUI) agrees about which
//! row line 412 of `session_manager.rs` is without three implementations of the
//! same arithmetic.
//!
//! ## What "never loses a line" means here
//!
//! Every input line between the first `diff --git` and the end of input ends up
//! either in a [`DiffHunk::lines`] vec or in a file's header metadata. Lines the
//! format doesn't give content meaning to — notably
//! `\ No newline at end of file` — are kept as [`DiffLineKind::Meta`] rather
//! than dropped, so a round-trip through this parser can't silently shorten a
//! file's rendered change.
//!
//! ## CRLF
//!
//! A single trailing `\r` is stripped from every line. A diff transmitted with
//! CRLF terminators is otherwise indistinguishable from a diff of a file whose
//! content genuinely ends each line with `\r`, and treating the terminator as
//! content would put a stray carriage return on the end of every rendered row.
//! Stripping uniformly is the choice that renders correctly in the common case
//! and never panics in the uncommon one.

use crate::ipc::protocol::{DiffFile, DiffHunk, DiffLine, DiffLineKind, DiffStatus};

/// Parse raw unified-diff text into per-file structure.
///
/// Returns an empty vec for empty/blank input. Text before the first
/// `diff --git` line (a commit message, a `From ` mail header) is ignored.
/// Malformed input never panics: an unparseable hunk header starts no hunk and
/// its body lines are attached to whatever hunk was already open, or dropped if
/// there is none.
pub fn parse_unified_diff(diff: &str) -> Vec<DiffFile> {
    let mut files: Vec<DiffFile> = Vec::new();
    // The file currently being accumulated, and its open hunk.
    let mut current: Option<DiffFile> = None;
    // Line cursors within the open hunk.
    let mut old_n: u32 = 0;
    let mut new_n: u32 = 0;

    // Drop the terminator of the final line before splitting: `"a\n".split('\n')`
    // yields a trailing empty element that is the *end of the text*, not an
    // empty last line of the diff, and treating it as one would append a
    // phantom blank context row to the last hunk of every well-formed diff.
    // An empty line genuinely *inside* a hunk body still parses as context.
    let body = diff.strip_suffix('\n').unwrap_or(diff);

    for raw in body.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);

        if let Some(rest) = line.strip_prefix("diff --git ") {
            if let Some(done) = current.take() {
                files.push(done);
            }
            let (a, b) = split_git_header_paths(rest);
            current = Some(DiffFile {
                path: b.or_else(|| a.clone()).unwrap_or_default(),
                old_path: None,
                status: DiffStatus::Modified,
                additions: 0,
                deletions: 0,
                hunks: Vec::new(),
            });
            continue;
        }

        let Some(file) = current.as_mut() else {
            // Preamble before the first `diff --git` — a commit message, a
            // `From ` header, or an empty string. Nothing to attach it to.
            continue;
        };

        // ── per-file metadata lines ─────────────────────────────────────────
        if file.hunks.is_empty() {
            if line.starts_with("new file mode") {
                file.status = DiffStatus::Added;
                continue;
            }
            if line.starts_with("deleted file mode") {
                file.status = DiffStatus::Removed;
                continue;
            }
            if let Some(from) = line.strip_prefix("rename from ") {
                file.status = DiffStatus::Renamed;
                file.old_path = Some(from.to_string());
                continue;
            }
            if let Some(to) = line.strip_prefix("rename to ") {
                file.status = DiffStatus::Renamed;
                file.path = to.to_string();
                continue;
            }
            if let Some(p) = line.strip_prefix("--- ") {
                if let Some(stripped) = strip_ab_prefix(p) {
                    // Only trust `---` for the path when the new side is
                    // /dev/null (a deletion), which the `+++` arm below
                    // handles by leaving `path` alone.
                    if file.path.is_empty() {
                        file.path = stripped;
                    }
                }
                continue;
            }
            if let Some(p) = line.strip_prefix("+++ ") {
                if let Some(stripped) = strip_ab_prefix(p) {
                    file.path = stripped;
                }
                continue;
            }
            // `index`, `similarity index`, `old mode`, `new mode`,
            // `Binary files ... differ`, `GIT binary patch` — recorded only as
            // "this file has no hunks", which is already true.
            if !line.starts_with("@@") {
                continue;
            }
        }

        // ── hunk header ─────────────────────────────────────────────────────
        if line.starts_with("@@") {
            match parse_hunk_header(line) {
                Some((o, n)) => {
                    old_n = o;
                    new_n = n;
                    file.hunks.push(DiffHunk {
                        header: line.to_string(),
                        old_start: o,
                        new_start: n,
                        lines: Vec::new(),
                    });
                }
                None => {
                    // Unparseable header — keep the text visible rather than
                    // dropping it, attached to the open hunk if there is one.
                    if let Some(hunk) = file.hunks.last_mut() {
                        hunk.lines.push(DiffLine {
                            kind: DiffLineKind::Meta,
                            old_n: None,
                            new_n: None,
                            text: line.to_string(),
                        });
                    }
                }
            }
            continue;
        }

        // ── hunk body ───────────────────────────────────────────────────────
        let Some(hunk) = file.hunks.last_mut() else {
            continue;
        };

        // `\ No newline at end of file` — not a content line on either side.
        if line.starts_with('\\') {
            hunk.lines.push(DiffLine {
                kind: DiffLineKind::Meta,
                old_n: None,
                new_n: None,
                text: line.to_string(),
            });
            continue;
        }

        match line.chars().next() {
            Some('+') => {
                hunk.lines.push(DiffLine {
                    kind: DiffLineKind::Added,
                    old_n: None,
                    new_n: Some(new_n),
                    text: line[1..].to_string(),
                });
                new_n += 1;
                file.additions += 1;
            }
            Some('-') => {
                hunk.lines.push(DiffLine {
                    kind: DiffLineKind::Removed,
                    old_n: Some(old_n),
                    new_n: None,
                    text: line[1..].to_string(),
                });
                old_n += 1;
                file.deletions += 1;
            }
            // A context line is " text"; git also emits a bare empty line for
            // an empty context line, which is the `None` arm here.
            Some(' ') | None => {
                let text = if line.is_empty() { "" } else { &line[1..] };
                hunk.lines.push(DiffLine {
                    kind: DiffLineKind::Context,
                    old_n: Some(old_n),
                    new_n: Some(new_n),
                    text: text.to_string(),
                });
                old_n += 1;
                new_n += 1;
            }
            // Anything else inside a hunk body is not unified-diff content
            // (a trailing `-- ` mail signature, a stray line from a
            // concatenated log). Keep it visible, consume no line number.
            Some(_) => {
                hunk.lines.push(DiffLine {
                    kind: DiffLineKind::Meta,
                    old_n: None,
                    new_n: None,
                    text: line.to_string(),
                });
            }
        }
    }

    if let Some(done) = current.take() {
        files.push(done);
    }
    files
}

/// Split `a/foo b/foo` from a `diff --git` header into its two paths.
///
/// Returns `(old, new)` with the `a/`/`b/` prefix stripped. Falls back to
/// `(None, None)` for a header with an embedded space it can't disambiguate —
/// the `---`/`+++` lines that follow carry the same information and are parsed
/// unambiguously, so guessing here would only produce a wrong answer faster.
fn split_git_header_paths(rest: &str) -> (Option<String>, Option<String>) {
    let mid = match rest.find(" b/") {
        Some(i) => i,
        None => return (None, None),
    };
    let a = strip_ab_prefix(&rest[..mid]);
    let b = strip_ab_prefix(&rest[mid + 1..]);
    (a, b)
}

/// Strip a leading `a/` or `b/`, and reject `/dev/null`.
///
/// A path with no `a/`/`b/` prefix (git's `--no-prefix`) is returned as-is.
fn strip_ab_prefix(p: &str) -> Option<String> {
    // Drop a trailing tab-separated timestamp (`--- a/foo\t2024-01-01 ...`),
    // which plain `diff -u` emits and `git diff` does not.
    let p = p.split('\t').next().unwrap_or(p);
    if p == "/dev/null" {
        return None;
    }
    let p = p
        .strip_prefix("a/")
        .or_else(|| p.strip_prefix("b/"))
        .unwrap_or(p);
    if p.is_empty() {
        None
    } else {
        Some(p.to_string())
    }
}

/// Parse `@@ -old_start[,old_count] +new_start[,new_count] @@ [context]` into
/// `(old_start, new_start)`.
///
/// A hunk whose start is `0` (git's encoding for "this side is empty", seen on
/// a new or deleted file) is normalised to `1`, so numbering a one-sided file
/// starts where a reader expects.
fn parse_hunk_header(line: &str) -> Option<(u32, u32)> {
    let body = line.strip_prefix("@@")?;
    let end = body.find("@@")?;
    let mut parts = body[..end].split_whitespace();
    let old = parts.next()?.strip_prefix('-')?;
    let new = parts.next()?.strip_prefix('+')?;
    let old_start: u32 = old.split(',').next()?.parse().ok()?;
    let new_start: u32 = new.split(',').next()?.parse().ok()?;
    Some((old_start.max(1), new_start.max(1)))
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. A multi-file diff produces one DiffFile per header, in order ──────

    #[test]
    fn a_multi_file_diff_produces_one_file_per_header_in_input_order() {
        let diff = r#"diff --git a/src/foo.rs b/src/foo.rs
index 1111111..2222222 100644
--- a/src/foo.rs
+++ b/src/foo.rs
@@ -1,3 +1,3 @@
 fn foo() {
-    old_line();
+    new_line();
 }
diff --git a/src/bar.rs b/src/bar.rs
index 3333333..4444444 100644
--- a/src/bar.rs
+++ b/src/bar.rs
@@ -1,2 +1,2 @@
-bar old
+bar new
"#;
        let files = parse_unified_diff(diff);
        let paths: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
        assert_eq!(
            paths,
            vec!["src/foo.rs", "src/bar.rs"],
            "expected one DiffFile per `diff --git` header, in input order"
        );
        assert_eq!(files.len(), 2);
    }

    // ── 2. A rename carries both old_path and path ────────────────────────────

    #[test]
    fn a_rename_carries_both_old_path_and_new_path() {
        let diff = r#"diff --git a/old/name.rs b/new/name.rs
similarity index 100%
rename from old/name.rs
rename to new/name.rs
"#;
        let files = parse_unified_diff(diff);
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.status, DiffStatus::Renamed);
        assert_eq!(file.old_path, Some("old/name.rs".to_string()));
        assert_eq!(file.path, "new/name.rs");
    }

    // ── 3. New/deleted files get the right status and path ────────────────────

    #[test]
    fn a_new_file_is_status_added_with_normalized_hunk_start() {
        let diff = r#"diff --git a/src/new_file.rs b/src/new_file.rs
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/src/new_file.rs
@@ -0,0 +1,2 @@
+line one
+line two
"#;
        let files = parse_unified_diff(diff);
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.status, DiffStatus::Added);
        assert_eq!(file.path, "src/new_file.rs");
        assert_eq!(file.old_path, None);
        // Git encodes "no old side" as start `0`; the parser normalizes to `1`
        // so a one-sided file numbers the way a reader expects.
        assert_eq!(file.hunks[0].old_start, 1);
        assert_eq!(file.hunks[0].new_start, 1);
    }

    #[test]
    fn a_deleted_file_is_status_removed_and_keeps_the_old_path() {
        let diff = r#"diff --git a/src/old_file.rs b/src/old_file.rs
deleted file mode 100644
index abc1234..0000000 100644
--- a/src/old_file.rs
+++ /dev/null
@@ -1,2 +0,0 @@
-line one
-line two
"#;
        let files = parse_unified_diff(diff);
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.status, DiffStatus::Removed);
        // A deletion has only one path — it must survive in `path`, not be
        // blanked out by the `+++ /dev/null` side.
        assert_eq!(file.path, "src/old_file.rs");
    }

    // ── 4. "\ No newline at end of file" is preserved as Meta, not dropped ────

    #[test]
    fn no_newline_marker_is_kept_as_a_meta_line_consuming_no_line_number() {
        let diff = r#"diff --git a/src/nofinal.rs b/src/nofinal.rs
index 1111111..2222222 100644
--- a/src/nofinal.rs
+++ b/src/nofinal.rs
@@ -1,2 +1,2 @@
 line one
-old last line
\ No newline at end of file
+new last line
\ No newline at end of file
"#;
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(
            hunk.lines.len(),
            5,
            "expected context, removed, meta, added, meta — none dropped"
        );

        assert_eq!(hunk.lines[2].kind, DiffLineKind::Meta);
        assert_eq!(hunk.lines[2].text, "\\ No newline at end of file");
        assert_eq!(hunk.lines[2].old_n, None);
        assert_eq!(hunk.lines[2].new_n, None);

        assert_eq!(hunk.lines[4].kind, DiffLineKind::Meta);
        assert_eq!(hunk.lines[4].text, "\\ No newline at end of file");
        assert_eq!(hunk.lines[4].old_n, None);
        assert_eq!(hunk.lines[4].new_n, None);

        // The meta lines must not have shifted the surrounding cursors: the
        // added line right before the trailing meta still lands on new_n=2.
        assert_eq!(hunk.lines[3].kind, DiffLineKind::Added);
        assert_eq!(hunk.lines[3].new_n, Some(2));
    }

    // ── 5. Hunk headers parse with/without function context and with omitted
    //       counts ────────────────────────────────────────────────────────────

    #[test]
    fn hunk_header_with_trailing_function_context_parses_start_positions() {
        let diff = "diff --git a/src/h.rs b/src/h.rs\nindex 1111111..2222222 100644\n--- a/src/h.rs\n+++ b/src/h.rs\n@@ -1,3 +1,4 @@ fn main() {\n line\n";
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.header, "@@ -1,3 +1,4 @@ fn main() {");
        assert_eq!(hunk.old_start, 1);
        assert_eq!(hunk.new_start, 1);
    }

    #[test]
    fn hunk_header_without_function_context_parses_start_positions() {
        let diff = "diff --git a/src/h.rs b/src/h.rs\nindex 1111111..2222222 100644\n--- a/src/h.rs\n+++ b/src/h.rs\n@@ -1,3 +1,4 @@\n line\n";
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.header, "@@ -1,3 +1,4 @@");
        assert_eq!(hunk.old_start, 1);
        assert_eq!(hunk.new_start, 1);
    }

    #[test]
    fn hunk_header_with_omitted_counts_parses_start_positions() {
        let diff = "diff --git a/src/h.rs b/src/h.rs\nindex 1111111..2222222 100644\n--- a/src/h.rs\n+++ b/src/h.rs\n@@ -1 +1 @@\n line\n";
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.old_start, 1);
        assert_eq!(hunk.new_start, 1);
    }

    // ── 6. CRLF input parses identically to LF, with no stray \r on any line ──

    #[test]
    fn crlf_input_parses_identically_to_lf_with_no_stray_carriage_returns() {
        let lf = "diff --git a/src/crlf.rs b/src/crlf.rs\nindex 1111111..2222222 100644\n--- a/src/crlf.rs\n+++ b/src/crlf.rs\n@@ -1,2 +1,2 @@\n-old value\n+new value\n";
        let crlf = lf.replace('\n', "\r\n");

        let parsed_lf = parse_unified_diff(lf);
        let parsed_crlf = parse_unified_diff(&crlf);

        assert_eq!(
            parsed_lf, parsed_crlf,
            "CRLF input should parse to the exact same structure as its LF equivalent"
        );
        for file in &parsed_crlf {
            for hunk in &file.hunks {
                for line in &hunk.lines {
                    assert!(
                        !line.text.contains('\r'),
                        "line text must never carry a stray CR: {:?}",
                        line.text
                    );
                }
            }
        }
    }

    // ── 7. Line numbering is correct within a hunk and across multiple hunks ──

    #[test]
    fn line_numbers_are_correct_within_and_across_hunks() {
        let diff = r#"diff --git a/src/multi.rs b/src/multi.rs
index 1111111..2222222 100644
--- a/src/multi.rs
+++ b/src/multi.rs
@@ -1,4 +1,5 @@
 line1
-line2
+line2a
+line2b
 line3
@@ -10,3 +11,4 @@
 line10
-line11
+line11-changed
 line12
\ No newline at end of file
"#;
        let files = parse_unified_diff(diff);
        let file = &files[0];
        assert_eq!(file.hunks.len(), 2);

        let h1 = &file.hunks[0];
        assert_eq!(
            h1.lines,
            vec![
                DiffLine {
                    kind: DiffLineKind::Context,
                    old_n: Some(1),
                    new_n: Some(1),
                    text: "line1".to_string(),
                },
                DiffLine {
                    kind: DiffLineKind::Removed,
                    old_n: Some(2),
                    new_n: None,
                    text: "line2".to_string(),
                },
                DiffLine {
                    kind: DiffLineKind::Added,
                    old_n: None,
                    new_n: Some(2),
                    text: "line2a".to_string(),
                },
                DiffLine {
                    kind: DiffLineKind::Added,
                    old_n: None,
                    new_n: Some(3),
                    text: "line2b".to_string(),
                },
                DiffLine {
                    kind: DiffLineKind::Context,
                    old_n: Some(3),
                    new_n: Some(4),
                    text: "line3".to_string(),
                },
            ]
        );

        let h2 = &file.hunks[1];
        assert_eq!(h2.old_start, 10);
        assert_eq!(h2.new_start, 11);
        assert_eq!(
            h2.lines[0],
            DiffLine {
                kind: DiffLineKind::Context,
                old_n: Some(10),
                new_n: Some(11),
                text: "line10".to_string(),
            },
            "the hunk cursor must reset from the new header, not continue from hunk 1"
        );
        assert_eq!(
            h2.lines[1],
            DiffLine {
                kind: DiffLineKind::Removed,
                old_n: Some(11),
                new_n: None,
                text: "line11".to_string(),
            }
        );
        assert_eq!(
            h2.lines[2],
            DiffLine {
                kind: DiffLineKind::Added,
                old_n: None,
                new_n: Some(12),
                text: "line11-changed".to_string(),
            }
        );
        // The last context line in a multi-hunk file carries the gutter
        // numbers git would print for it: old=12, new=13.
        assert_eq!(
            h2.lines[3],
            DiffLine {
                kind: DiffLineKind::Context,
                old_n: Some(12),
                new_n: Some(13),
                text: "line12".to_string(),
            }
        );
    }

    // ── 8. additions/deletions per file equal the count of +/- lines ─────────

    #[test]
    fn additions_and_deletions_equal_the_count_of_plus_and_minus_lines() {
        let diff = r#"diff --git a/src/counts.rs b/src/counts.rs
index 1111111..2222222 100644
--- a/src/counts.rs
+++ b/src/counts.rs
@@ -1,5 +1,6 @@
 context one
-removed one
-removed two
+added one
+added two
+added three
 context two
"#;
        let files = parse_unified_diff(diff);
        let file = &files[0];
        assert_eq!(file.additions, 3);
        assert_eq!(file.deletions, 2);
    }

    // ── 9. Never loses a line: every hunk-body input line becomes a DiffLine ──

    #[test]
    fn every_hunk_body_input_line_becomes_exactly_one_diff_line() {
        // Reuses the fixture from the line-numbering test: 5 body lines in
        // hunk 1 (context, removed, 2x added, context) and 5 in hunk 2
        // (context, removed, added, context, no-newline meta) — 10 total.
        let diff = r#"diff --git a/src/multi.rs b/src/multi.rs
index 1111111..2222222 100644
--- a/src/multi.rs
+++ b/src/multi.rs
@@ -1,4 +1,5 @@
 line1
-line2
+line2a
+line2b
 line3
@@ -10,3 +11,4 @@
 line10
-line11
+line11-changed
 line12
\ No newline at end of file
"#;
        let files = parse_unified_diff(diff);
        let file = &files[0];
        assert_eq!(file.hunks[0].lines.len(), 5);
        assert_eq!(file.hunks[1].lines.len(), 5);
        let total: usize = file.hunks.iter().map(|h| h.lines.len()).sum();
        assert_eq!(
            total, 10,
            "every line belonging to a hunk body must produce a DiffLine — none dropped"
        );
    }

    // ── 10. Robustness: malformed/empty/preamble input never panics ──────────

    #[test]
    fn empty_input_produces_no_files() {
        assert_eq!(parse_unified_diff(""), Vec::new());
    }

    #[test]
    fn input_with_no_diff_git_header_produces_no_files() {
        let diff = "just some notes\nabout nothing in particular\n";
        assert_eq!(parse_unified_diff(diff), Vec::new());
    }

    #[test]
    fn a_malformed_hunk_header_is_dropped_without_panicking_and_parsing_continues() {
        let diff = r#"diff --git a/src/weird.rs b/src/weird.rs
index 1111111..2222222 100644
--- a/src/weird.rs
+++ b/src/weird.rs
@@ garbage @@
@@ -1,2 +1,2 @@
-old
+new
"#;
        let files = parse_unified_diff(diff);
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.path, "src/weird.rs");
        // Only the well-formed header opens a hunk; the garbage header has
        // nothing to attach to yet and is dropped rather than panicking.
        assert_eq!(file.hunks.len(), 1);
        assert_eq!(file.hunks[0].lines[0].kind, DiffLineKind::Removed);
        assert_eq!(file.hunks[0].lines[0].old_n, Some(1));
        assert_eq!(file.hunks[0].lines[1].kind, DiffLineKind::Added);
        assert_eq!(file.hunks[0].lines[1].new_n, Some(1));
    }

    #[test]
    fn preamble_text_before_the_first_diff_git_header_is_ignored() {
        let diff = r#"From abcdef1234 Mon Sep 17 00:00:00 2001
From: Alice <alice@example.com>
Subject: [PATCH] Fix the thing

This commit fixes the thing described in TICKET-123.

diff --git a/src/thing.rs b/src/thing.rs
index 1111111..2222222 100644
--- a/src/thing.rs
+++ b/src/thing.rs
@@ -1,2 +1,2 @@
-broken
+fixed
"#;
        let files = parse_unified_diff(diff);
        assert_eq!(
            files.len(),
            1,
            "commit-message preamble must not produce a phantom file"
        );
        assert_eq!(files[0].path, "src/thing.rs");
        assert_eq!(files[0].additions, 1);
        assert_eq!(files[0].deletions, 1);
    }

    #[test]
    fn input_without_a_trailing_newline_still_parses_the_last_line() {
        let diff = "diff --git a/src/eof.rs b/src/eof.rs\nindex 1111111..2222222 100644\n--- a/src/eof.rs\n+++ b/src/eof.rs\n@@ -1,1 +1,1 @@\n-old\n+new";
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.lines[0].kind, DiffLineKind::Removed);
        assert_eq!(hunk.lines[0].text, "old");
        assert_eq!(hunk.lines[1].kind, DiffLineKind::Added);
        assert_eq!(hunk.lines[1].text, "new");
        assert_eq!(files[0].additions, 1);
        assert_eq!(files[0].deletions, 1);
    }

    // ── 11. A bare empty context line is Context with empty text, not dropped ─

    #[test]
    fn a_bare_empty_line_in_a_hunk_body_is_a_context_line_with_empty_text() {
        let diff = "diff --git a/src/blank.rs b/src/blank.rs\nindex 1111111..2222222 100644\n--- a/src/blank.rs\n+++ b/src/blank.rs\n@@ -1,3 +1,3 @@\n line1\n\n line3\n";
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(
            hunk.lines.len(),
            3,
            "the bare blank line must not be dropped"
        );
        assert_eq!(
            hunk.lines[1],
            DiffLine {
                kind: DiffLineKind::Context,
                old_n: Some(2),
                new_n: Some(2),
                text: String::new(),
            }
        );
    }

    // ── 12. Gutter numbers legitimately go backwards when new_n runs ahead ───

    /// Locks in E1 from the diagnostics plan: a gutter that reads
    /// `new_n.or(old_n)` (the same precedence `CodeContentView.swift` uses to
    /// pick which side's number to show) can legitimately produce a sequence
    /// that isn't monotonically increasing. When a hunk's new side has
    /// drifted ahead of the old side — here, three additions land with no
    /// matching removals before a later run of removed lines — the removed
    /// lines that follow carry `old_n: Some(_), new_n: None`, and `old_n` is
    /// numerically smaller than the `new_n` values that were just shown
    /// immediately above them. That "the numbers went backwards" reads as
    /// scrambled data if you don't know the parser is doing exactly what a
    /// unified diff says to do — two different people have looked at this
    /// exact gutter sequence and concluded the renderer was corrupting line
    /// numbers. It isn't: `DiffLine.old_n`/`new_n` are behaving precisely as
    /// designed. This test exists so nobody "fixes" it later.
    #[test]
    fn removed_lines_carry_old_side_numbers_so_the_gutter_is_legitimately_non_monotonic() {
        let diff = r#"diff --git a/src/drift.rs b/src/drift.rs
index 1111111..2222222 100644
--- a/src/drift.rs
+++ b/src/drift.rs
@@ -1,4 +1,5 @@
 line1
 line2
+added1
+added2
+added3
-line3
-line4
"#;
        let files = parse_unified_diff(diff);
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.lines.len(), 7);

        // The trailing removed lines carry old-side numbers only, increasing,
        // with no new-side number at all — the new side never advances for a
        // line that no longer exists on it.
        let removed: Vec<&DiffLine> = hunk
            .lines
            .iter()
            .filter(|l| l.kind == DiffLineKind::Removed)
            .collect();
        assert_eq!(removed.len(), 2);
        assert_eq!(removed[0].old_n, Some(3));
        assert_eq!(removed[0].new_n, None);
        assert_eq!(removed[1].old_n, Some(4));
        assert_eq!(removed[1].new_n, None);
        assert!(
            removed[0].old_n < removed[1].old_n,
            "old_n must increase across the run of removed lines"
        );

        // Compute the same "which number does the gutter show" precedence
        // CodeContentView.swift uses — prefer the new side, fall back to the
        // old side — across every content-bearing line in the hunk, and
        // prove the resulting sequence is NOT monotonically non-decreasing.
        let seq: Vec<u32> = hunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineKind::Meta)
            .map(|l| {
                l.new_n
                    .or(l.old_n)
                    .expect("every non-meta line has a number on some side")
            })
            .collect();
        assert_eq!(
            seq,
            vec![1, 2, 3, 4, 5, 3, 4],
            "sanity: the exact gutter sequence git would show"
        );
        assert!(
            !seq.windows(2).all(|w| w[0] <= w[1]),
            "the gutter sequence must contain a decrease (5 -> 3) — that decrease is correct behaviour, \
            not corruption, and this assertion is the proof, not an eyeballed comment"
        );
    }
}
