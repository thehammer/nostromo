//! What a shell could turn a piece of command text into, for the guard's
//! marker scan.
//!
//! The guard looks for `ecs_connect`, `aws ecs execute-command` and the like in
//! command text. A shell builds words that never appear in the text:
//! `ecs_{connect,}`, `ecs_${U}connect`, `ecs_$()connect`. This module gives the
//! scan more texts to look at. It never evaluates anything and it only adds
//! texts, so a scan of the original text still happens too.
//!
//! - [`strip_empty_expansions`]: expansions that are empty (or have a literal
//!   default) deleted or replaced by that default.
//! - [`expanded_texts`]: the stripped text, and the text with brace
//!   alternatives written out (bounded: past the caps the caller must block).
//! - [`wild_match`] / [`glob_match`]: match a [`WILDCARD`](super::shell::WILDCARD)
//!   word pattern, or a shell glob, against a name.

use super::shell::WILDCARD;

/// Most alternatives one word may expand to. Past this the scan can't be
/// complete, so the caller blocks.
pub const MAX_BRACE_ALTERNATIVES: usize = 4096;

/// A word longer than this that holds a brace group isn't expanded (blocked).
pub const MAX_EXPANDABLE_WORD: usize = 8 * 1024;

/// Most bytes of expanded text produced for one scan.
pub const MAX_EXPANDED_BYTES: usize = 512 * 1024;

/// Nesting limit for `${x:-${y:-…}}`.
const MAX_NESTING: u32 = 8;

/// The extra texts to scan for one command text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expanded {
    /// Texts that differ from the input: empty expansions removed, then brace
    /// alternatives written out (as separate words, as a shell would).
    pub texts: Vec<String>,
    /// A brace expansion went past a cap: the text can't be fully scanned.
    pub overflow: bool,
}

/// The extra texts a shell could build from `text` (see the module docs).
pub fn expanded_texts(text: &str) -> Expanded {
    let stripped = strip_empty_expansions(text);
    let mut out = Expanded::default();
    let braced = write_out_braces(&stripped, &mut out.overflow);
    if let Some(braced) = braced.filter(|b| *b != stripped) {
        out.texts.push(braced);
    }
    if stripped != text {
        out.texts.insert(0, stripped);
    }
    out
}

/// `text` with the expansions that are empty deleted and `${x:-lit}` /
/// `${x:=lit}` replaced by `lit`: `$VAR`, `$@`, `$*`, `$1`, `$#`, `$?`, `$$`,
/// `$!`, `$-`, `${…}` (except a literal default), `$(( ))`, `$()` with nothing
/// in it, and empty backticks. A `$( … )` or backtick pair with content is kept.
pub fn strip_empty_expansions(text: &str) -> String {
    strip(text, 0)
}

fn strip(text: &str, depth: u32) -> String {
    if depth > MAX_NESTING || !text.contains(['$', '`']) {
        return text.to_owned();
    }
    let c: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < c.len() {
        match c[i] {
            '$' => match c.get(i + 1).copied() {
                Some('{') => {
                    if let Some(end) = matching(&c, i + 1, '{', '}') {
                        out.push_str(&parameter_value(&c[i + 2..end].iter().collect::<String>(), depth));
                        i = end + 1;
                        continue;
                    }
                }
                Some('(') if c.get(i + 2) == Some(&'(') => {
                    if let Some(end) = matching(&c, i + 1, '(', ')') {
                        i = end + 1;
                        continue;
                    }
                }
                Some('(') => {
                    if let Some(end) = matching(&c, i + 1, '(', ')') {
                        if c[i + 2..end].iter().all(|ch| ch.is_whitespace()) {
                            i = end + 1;
                            continue;
                        }
                    }
                }
                Some('@' | '*' | '#' | '?' | '$' | '!' | '-') => {
                    i += 2;
                    continue;
                }
                Some(ch) if ch.is_ascii_digit() => {
                    i += 2;
                    continue;
                }
                Some(ch) if ch.is_ascii_alphabetic() || ch == '_' => {
                    i += 2;
                    while c.get(i).is_some_and(|ch| ch.is_ascii_alphanumeric() || *ch == '_') {
                        i += 1;
                    }
                    continue;
                }
                _ => {}
            },
            '`' => {
                if let Some(rel) = c[i + 1..].iter().position(|ch| *ch == '`') {
                    let end = i + 1 + rel;
                    if c[i + 1..end].iter().all(|ch| ch.is_whitespace()) {
                        i = end + 1;
                        continue;
                    }
                }
            }
            _ => {}
        }
        out.push(c[i]);
        i += 1;
    }
    out
}

/// The text a `${inner}` yields when the variable is unset: the literal
/// default of `${x:-lit}` / `${x-lit}` / `${x:=lit}` / `${x=lit}`, else nothing.
fn parameter_value(inner: &str, depth: u32) -> String {
    // `${#x}` is a length and `${!x}` an indirection: no literal.
    if inner.starts_with(['#', '!']) {
        return String::new();
    }
    let rest = if inner.starts_with(|ch: char| ch.is_ascii_alphabetic() || ch == '_') {
        inner.trim_start_matches(|ch: char| ch.is_ascii_alphanumeric() || ch == '_')
    } else if inner.starts_with(|ch: char| ch.is_ascii_digit()) {
        inner.trim_start_matches(|ch: char| ch.is_ascii_digit())
    } else if inner.starts_with(['@', '*']) {
        &inner[1..]
    } else {
        return String::new();
    };
    let rest = rest.strip_prefix(':').unwrap_or(rest);
    match rest.strip_prefix(['-', '=']) {
        Some(default) => strip(default, depth + 1),
        None => String::new(),
    }
}

/// The index of the `close` matching the `open` at `at` (nesting counted).
fn matching(c: &[char], at: usize, open: char, close: char) -> Option<usize> {
    let mut depth = 0u32;
    for (i, ch) in c.iter().enumerate().skip(at) {
        if *ch == open {
            depth += 1;
        } else if *ch == close {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
    }
    None
}

/// `text` with each word that holds a brace group replaced by every word it
/// expands to, separated by a space. `None` when nothing needed expanding.
/// Sets `overflow` when a word went past a cap (the word is then left as is).
fn write_out_braces(text: &str, overflow: &mut bool) -> Option<String> {
    if !text.contains('{') {
        return None;
    }
    let mut out = String::with_capacity(text.len());
    let mut produced = 0usize;
    let mut changed = false;
    let mut rest = text;
    while !rest.is_empty() {
        let blank = rest.len() - rest.trim_start_matches(char::is_whitespace).len();
        out.push_str(&rest[..blank]);
        rest = &rest[blank..];
        let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let word = &rest[..end];
        rest = &rest[end..];
        if word.is_empty() {
            continue;
        }
        if !has_group(word) {
            out.push_str(word);
            continue;
        }
        let alternatives = (word.len() <= MAX_EXPANDABLE_WORD).then(|| expand_word(word)).flatten();
        match alternatives {
            Some(alts) => {
                let joined = alts.join(" ");
                produced += joined.len();
                if produced > MAX_EXPANDED_BYTES {
                    *overflow = true;
                    out.push_str(word);
                } else {
                    changed = true;
                    out.push_str(&joined);
                }
            }
            None => {
                *overflow = true;
                out.push_str(word);
            }
        }
    }
    changed.then_some(out)
}

/// Every word `word` expands to by brace expansion (itself when it has no
/// group). `None` when that is past the caps: the caller must treat it as "can't tell".
pub fn brace_alternatives(word: &str) -> Option<Vec<String>> {
    if !has_group(word) {
        return Some(vec![word.to_owned()]);
    }
    if word.len() > MAX_EXPANDABLE_WORD {
        return None;
    }
    expand_word(word)
}

/// Does the word contain a brace group (`{a,b}`, `{a..c}`)?
fn has_group(word: &str) -> bool {
    word.match_indices('{').any(|(open, _)| group_at(word, open).is_some())
}

/// Every word `word` expands to, `None` past [`MAX_BRACE_ALTERNATIVES`].
/// Numeric ranges (`{1..100}`) give their first number only: a marker has no digits.
fn expand_word(word: &str) -> Option<Vec<String>> {
    let mut from = 0;
    while let Some(rel) = word[from..].find('{') {
        let open = from + rel;
        if let Some((close, alternatives)) = group_at(word, open) {
            let (prefix, suffix) = (&word[..open], &word[close + 1..]);
            let suffixes = expand_word(suffix)?;
            let mut out = Vec::new();
            for alt in &alternatives {
                for a in expand_word(alt)? {
                    for s in &suffixes {
                        if out.len() >= MAX_BRACE_ALTERNATIVES {
                            return None;
                        }
                        out.push(format!("{prefix}{a}{s}"));
                    }
                }
            }
            return Some(out);
        }
        from = open + 1;
    }
    Some(vec![word.to_owned()])
}

/// The brace group opening at byte `open`: the index of its `}` and its
/// alternatives. `None` if it isn't one (unbalanced, `{}`, `{x}`).
fn group_at(word: &str, open: usize) -> Option<(usize, Vec<String>)> {
    let mut depth = 0u32;
    let mut pieces: Vec<&str> = Vec::new();
    let mut piece_start = open + 1;
    for (i, ch) in word[open..].char_indices().map(|(i, ch)| (open + i, ch)) {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let inner = &word[open + 1..i];
                    if !pieces.is_empty() {
                        pieces.push(&word[piece_start..i]);
                        return Some((i, pieces.into_iter().map(str::to_owned).collect()));
                    }
                    return sequence(inner).map(|alts| (i, alts));
                }
            }
            ',' if depth == 1 => {
                pieces.push(&word[piece_start..i]);
                piece_start = i + 1;
            }
            _ => {}
        }
    }
    None
}

/// `{a..e}` / `{1..9}` / `{a..e..2}`: the sequence (numbers collapse to the first).
fn sequence(inner: &str) -> Option<Vec<String>> {
    let mut parts = inner.split("..");
    let (from, to) = (parts.next()?, parts.next()?);
    let step = parts.next();
    if parts.next().is_some() || step.is_some_and(|s| s.parse::<i64>().is_err()) {
        return None;
    }
    if from.parse::<i64>().is_ok() && to.parse::<i64>().is_ok() {
        return Some(vec![from.to_owned()]);
    }
    let (mut f, mut t) = (single_char(from)?, single_char(to)?);
    if !(f.is_ascii_alphabetic() && t.is_ascii_alphabetic()) {
        return None;
    }
    let reverse = f > t;
    if reverse {
        std::mem::swap(&mut f, &mut t);
    }
    let mut chars: Vec<String> = (f..=t).map(String::from).collect();
    if reverse {
        chars.reverse();
    }
    Some(chars)
}

fn single_char(s: &str) -> Option<char> {
    let mut it = s.chars();
    let c = it.next()?;
    it.next().is_none().then_some(c)
}

// ── patterns ──────────────────────────────────────────────────────────────────

/// Could `pattern` (where [`WILDCARD`] stands for any text, empty included)
/// be exactly `name`? Compared without regard to case.
pub fn wild_match(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    matcher(&p, &n, false)
}

/// Does the shell glob `pattern` (`*`, `?`, `[…]`; [`WILDCARD`] as `*`) match
/// `name`? Compared without regard to case.
pub fn glob_match(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    matcher(&p, &n, true)
}

fn matcher(p: &[char], n: &[char], shell_glob: bool) -> bool {
    match p.first() {
        None => n.is_empty(),
        Some(&c) if c == WILDCARD || (shell_glob && c == '*') => {
            (0..=n.len()).any(|skip| matcher(&p[1..], &n[skip..], shell_glob))
        }
        Some('?') if shell_glob => !n.is_empty() && matcher(&p[1..], &n[1..], shell_glob),
        Some('[') if shell_glob => match class_end(p) {
            Some(end) => !n.is_empty() && class_matches(&p[1..end], n[0]) && matcher(&p[end + 1..], &n[1..], shell_glob),
            None => !n.is_empty() && n[0] == '[' && matcher(&p[1..], &n[1..], shell_glob),
        },
        Some(&c) => !n.is_empty() && n[0] == c && matcher(&p[1..], &n[1..], shell_glob),
    }
}

/// The index of the `]` closing the class that opens at `p[0]`.
fn class_end(p: &[char]) -> Option<usize> {
    let mut i = 1;
    if matches!(p.get(i), Some('!' | '^')) {
        i += 1;
    }
    if p.get(i) == Some(&']') {
        i += 1;
    }
    p[i..].iter().position(|c| *c == ']').map(|rel| i + rel)
}

fn class_matches(class: &[char], c: char) -> bool {
    let (negate, class) = match class.first() {
        Some('!' | '^') => (true, &class[1..]),
        _ => (false, class),
    };
    let mut hit = false;
    let mut i = 0;
    while i < class.len() {
        if class.get(i + 1) == Some(&'-') && i + 2 < class.len() {
            hit |= (class[i]..=class[i + 2]).contains(&c);
            i += 3;
        } else {
            hit |= class[i] == c;
            i += 1;
        }
    }
    hit != negate
}

/// Does the word pattern look like it could be built into one of `markers`
/// by an expansion? The pattern's literal parts must fit the marker in order
/// (the word's ends are anchored where it has literal text there), and there
/// must be enough literal text to mean it: 4 characters when both ends are
/// literal, 6 when the word starts or ends with an expansion, any `ecs_…`.
pub fn could_spell(pattern: &str, markers: &[&str]) -> bool {
    if !pattern.contains(WILDCARD) {
        return false;
    }
    let literal = pattern.chars().filter(|c| *c != WILDCARD).count();
    let open_end = pattern.starts_with(WILDCARD) || pattern.ends_with(WILDCARD);
    let enough = literal >= if open_end { 6 } else { 4 } || (literal >= 4 && pattern.to_lowercase().starts_with("ecs_"));
    enough && markers.iter().any(|m| wild_match(pattern, m))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn braces(word: &str) -> Vec<String> {
        expand_word(word).unwrap()
    }

    #[test]
    fn strips_empty_expansions() {
        for (input, want) in [
            ("ecs_${U}connect", "ecs_connect"),
            ("ecs_$@connect", "ecs_connect"),
            ("ecs_$*connect", "ecs_connect"),
            ("ecs_$()connect", "ecs_connect"),
            ("ecs_``connect", "ecs_connect"),
            ("ecs_c${x:-o}nnect", "ecs_connect"),
            ("a$1b$#c", "abc"),
            ("a${x:+y}b", "ab"),
            ("a$((1+2))b", "ab"),
            ("$(echo hi)", "$(echo hi)"),
        ] {
            assert_eq!(strip_empty_expansions(input), want, "{input}");
        }
    }

    #[test]
    fn expands_braces() {
        assert_eq!(braces("ecs_{connect,}"), ["ecs_connect", "ecs_"]);
        assert_eq!(braces("a{b,{c,d}}"), ["ab", "ac", "ad"]);
        assert_eq!(braces("{a..c}"), ["a", "b", "c"]);
        assert_eq!(braces("x{1..100000}"), ["x1"]);
        assert_eq!(braces("{x}"), ["{x}"]);
        assert_eq!(braces("{a{b,c}"), ["{ab", "{ac"]);
    }

    #[test]
    fn writes_alternatives_as_words() {
        let e = expanded_texts("aws ec{s,} execute-comman{d,}");
        assert!(!e.overflow);
        assert!(e.texts.last().unwrap().contains("ecs ec execute-command execute-comman"));
        assert!(expanded_texts("echo {a..z}{a..z}{a..z}").overflow);
        assert!(!expanded_texts("echo {1..100000}").overflow);
    }

    #[test]
    fn globs() {
        assert!(glob_match("t?ux", "tmux"));
        assert!(glob_match("tm[u]x", "tmux"));
        assert!(glob_match("t*", "tmux"));
        assert!(!glob_match("t?x", "tmux"));
        assert!(wild_match(&format!("tm{WILDCARD}ux"), "tmux"));
    }

    #[test]
    fn spells() {
        let w = WILDCARD;
        let m = ["ecs_connect", "execute-command"];
        assert!(could_spell(&format!("ecs_{w}connect"), &m));
        assert!(could_spell(&format!("ecs_{w}"), &m));
        assert!(could_spell(&format!("execute-{w}command"), &m));
        assert!(!could_spell(&format!("{w}-task"), &["run-task"]));
        assert!(!could_spell(&format!("{w}/ecs_tools"), &m));
        assert!(!could_spell(&w.to_string(), &m));
    }
}
