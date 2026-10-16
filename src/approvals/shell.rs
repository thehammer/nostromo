//! A small shell tokenizer. **Not a full parser**: it finds words, separators,
//! here-docs and nested command text, and it executes nothing.
//!
//! Supported: single and double quotes, backslash escapes, `$'…'` (ANSI-C
//! quoting), the separators `&&`, `||`, `;`, `|`, `|&`, `&` and newline,
//! `$( )`, backticks, `( )` subshells, `<( )` / `>( )`, here-docs (`<<`,
//! `<<-`, quoted and unquoted delimiters), here-strings, redirections,
//! comments, line continuations, and recursion into `bash|sh|zsh -c
//! '<payload>'` and `eval <args>` payloads.
//!
//! Unbalanced input (an open quote, `$(`, backtick or parenthesis, a stray
//! `)`, an unterminated here-doc) or nesting deeper than [`MAX_DEPTH`] sets
//! [`ShellParse::unparsed`]. What was found up to that point is still reported.

use std::ops::Range;

/// Maximum nesting before the input is reported as `unparsed`. Two separate
/// limits of this size: `-c` / `eval` / here-doc payloads, and `$( )` /
/// backticks / parentheses within one text.
pub const MAX_DEPTH: u32 = 16;

/// The result of [`parse`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShellParse {
    /// Every simple command found, in source order, including those inside
    /// `$( )`, backticks, subshells, process substitutions and `-c` / `eval`
    /// payloads (see [`SimpleCommand::depth`]).
    pub commands: Vec<SimpleCommand>,
    /// The separators at the top level of the input: outside quotes, `$( )`,
    /// backticks, parentheses and payloads.
    pub separators: Vec<Sep>,
    /// Here-docs in the input (not in payloads), in source order.
    pub heredocs: Vec<HereDoc>,
    /// True when the input (or a nested payload) could not be tokenized.
    pub unparsed: bool,
    /// A here-doc anywhere in the input (nested ones and payloads too) has an
    /// unquoted delimiter and a body with `$(` or a backtick: the shell runs
    /// that text, and the tokenizer does not parse it.
    pub expanding_heredoc: bool,
}

/// One simple command: its words after quote removal, without redirections
/// and without `#` comments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SimpleCommand {
    pub words: Vec<Word>,
    /// Byte range in the parsed input. For a command found inside a `-c` or
    /// `eval` payload, the range of the payload word(s) in the input.
    pub span: Range<usize>,
    /// 0 for the input itself; +1 for each enclosing `-c` / `eval` payload or
    /// here-doc fed to a shell.
    pub depth: u32,
}

impl SimpleCommand {
    /// The words' texts.
    pub fn texts(&self) -> Vec<&str> {
        self.words.iter().map(|w| w.text.as_str()).collect()
    }
}

/// One word after quote removal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word {
    /// The text with quotes removed and escapes resolved. Unexpanded `$VAR`,
    /// `${…}`, `$( )` and backtick text is kept verbatim.
    pub text: String,
    /// Byte range of the word in the text it was parsed from.
    pub span: Range<usize>,
    /// True if the word contains an expansion the tokenizer can't evaluate
    /// (`$VAR`, `${…}`, `$( )`, backticks, `$(( ))`) outside single quotes.
    pub dynamic: bool,
    /// [`Word::text`] with each unexpanded expansion (`$VAR`, `${…}`, `$( )`,
    /// backticks, `$(( ))`) replaced by [`WILDCARD`], so a quote boundary
    /// survives (`"ecs_"$U"connect"` is `ecs_␀connect`, not `ecs_$Uconnect`).
    /// Equal to `text` when the word has no expansion.
    pub pattern: String,
}

/// Stands for an unexpanded expansion in [`Word::pattern`].
pub const WILDCARD: char = '\u{0}';

/// A top-level separator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sep {
    pub kind: SepKind,
    pub span: Range<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SepKind {
    /// `&&`
    And,
    /// `||`
    Or,
    /// `;`
    Semi,
    /// `|` or `|&`
    Pipe,
    /// `&`
    Background,
    /// an unescaped newline
    Newline,
}

/// A here-doc.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HereDoc {
    /// The body's byte range (from the line after the operator up to, not
    /// including, the terminator line).
    pub body_span: Range<usize>,
    /// The delimiter with quotes removed.
    pub delimiter: String,
    /// The delimiter was quoted (`<<'EOF'`, `<<"EOF"`, `<<\EOF`): no expansion.
    pub quoted: bool,
    /// `<<-`: leading tabs are stripped.
    pub strip_tabs: bool,
}

/// Tokenize `cmd`.
pub fn parse(cmd: &str) -> ShellParse {
    parse_at_depth(cmd, 0)
}

/// Shells whose `-c` payload, here-doc or here-string is parsed as a script.
const SHELLS: &[&str] = &["bash", "sh", "zsh", "dash", "ksh", "fish"];

/// Words that may precede the real command word (`env X=1 bash -c …`).
const PREFIX_WORDS: &[&str] = &[
    "!", "{", "(", "if", "then", "else", "elif", "while", "until", "do", "time", "command", "builtin",
    "exec", "nohup", "env", "sudo", "nice", "timeout", "caffeinate",
];

fn parse_at_depth(src: &str, depth: u32) -> ShellParse {
    let mut p = Parser {
        src,
        b: src.as_bytes(),
        pos: 0,
        depth,
        nest: 0,
        pending: Vec::new(),
        out: ShellParse::default(),
        wild: Vec::new(),
    };
    if p.parse_list(false).is_err() {
        p.out.unparsed = true;
    }
    p.out
}

/// The input couldn't be tokenized (the parse stops; `unparsed` is set).
struct Unbalanced;

type Step<T> = Result<T, Unbalanced>;

/// A here-doc whose body hasn't been read yet (it starts after the next newline).
struct PendingHereDoc {
    delimiter: String,
    quoted: bool,
    strip_tabs: bool,
    /// The command it feeds is a shell reading a script from stdin.
    feeds_shell: bool,
    /// Index in `ShellParse::commands` of the command it feeds (meaningful
    /// only when `feeds_shell`); its span is reported for the body's commands.
    owner: usize,
}

/// The command being assembled.
#[derive(Default)]
struct Builder {
    words: Vec<Word>,
    start: Option<usize>,
    end: usize,
    /// Indexes into `Parser::pending` of here-docs this command opened.
    heredocs: Vec<usize>,
    herestrings: Vec<String>,
}

impl Builder {
    fn touch(&mut self, span: &Range<usize>) {
        self.start.get_or_insert(span.start);
        self.end = self.end.max(span.end);
    }
}

struct Parser<'a> {
    src: &'a str,
    b: &'a [u8],
    pos: usize,
    /// Payload depth (`-c`, `eval`, here-doc fed to a shell).
    depth: u32,
    /// `$( )` / backtick / parenthesis nesting inside this input.
    nest: u32,
    pending: Vec<PendingHereDoc>,
    out: ShellParse,
    /// Byte ranges of the word being read (in its `text`) that are expansions.
    wild: Vec<Range<usize>>,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.pos).copied()
    }

    fn peek_at(&self, off: usize) -> Option<u8> {
        self.b.get(self.pos + off).copied()
    }

    fn starts_with(&self, s: &str) -> bool {
        self.b[self.pos..].starts_with(s.as_bytes())
    }

    /// Length of the UTF-8 char starting at `pos` (1 for a stray byte).
    fn char_len(&self, pos: usize) -> usize {
        self.src[pos..].chars().next().map_or(1, char::len_utf8)
    }

    /// Copy the char at `pos` into `text` and step over it.
    fn copy_char(&mut self, text: &mut Vec<u8>) {
        let len = self.char_len(self.pos);
        text.extend_from_slice(&self.b[self.pos..self.pos + len]);
        self.pos += len;
    }

    /// After an opening `'`: the length of the quoted text, up to the closing quote.
    fn single_quoted_len(&self) -> Step<usize> {
        self.b[self.pos..].iter().position(|&c| c == b'\'').ok_or(Unbalanced)
    }

    /// Skip blanks, then read the word at `pos` if there is one (it is
    /// recorded in `cmd`'s span).
    fn optional_word(&mut self, cmd: &mut Builder) -> Step<Option<Word>> {
        self.skip_blanks();
        if self.peek().is_none_or(Self::is_meta) {
            return Ok(None);
        }
        let word = self.read_word()?;
        cmd.touch(&word.span);
        Ok(Some(word))
    }

    fn is_meta(c: u8) -> bool {
        matches!(c, b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>')
    }

    fn skip_blanks(&mut self) {
        loop {
            match self.peek() {
                Some(b' ' | b'\t' | b'\r') => self.pos += 1,
                Some(b'\\') if self.peek_at(1) == Some(b'\n') => self.pos += 2,
                _ => return,
            }
        }
    }

    fn sep(&mut self, kind: SepKind, len: usize) {
        if self.nest == 0 {
            self.out.separators.push(Sep { kind, span: self.pos..self.pos + len });
        }
        self.pos += len;
    }

    /// Parse commands until end of input (`in_parens == false`) or the `)`
    /// closing the current `( … )` / `$( … )` (consumed).
    fn parse_list(&mut self, in_parens: bool) -> Step<()> {
        let mut cmd = Builder::default();
        loop {
            self.skip_blanks();
            let Some(c) = self.peek() else {
                self.finish(&mut cmd);
                if in_parens || !self.pending.is_empty() {
                    return Err(Unbalanced);
                }
                return Ok(());
            };
            match c {
                b'#' => {
                    while self.peek().is_some_and(|c| c != b'\n') {
                        self.pos += 1;
                    }
                }
                b'\n' => {
                    self.finish(&mut cmd);
                    self.sep(SepKind::Newline, 1);
                    self.read_heredoc_bodies()?;
                }
                b';' => {
                    self.finish(&mut cmd);
                    // `;;` ends a `case` arm; `;&` / `;;&` too.
                    let len = if self.peek_at(1) == Some(b';') { 2 } else { 1 };
                    self.sep(SepKind::Semi, len);
                    if self.peek() == Some(b'&') {
                        self.pos += 1;
                    }
                }
                b'&' if self.peek_at(1) == Some(b'&') => {
                    self.finish(&mut cmd);
                    self.sep(SepKind::And, 2);
                }
                b'&' if self.peek_at(1) == Some(b'>') => {
                    let start = self.pos;
                    self.pos += if self.peek_at(2) == Some(b'>') { 3 } else { 2 };
                    cmd.touch(&(start..self.pos));
                    self.redirect_target(&mut cmd)?;
                }
                b'&' => {
                    self.finish(&mut cmd);
                    self.sep(SepKind::Background, 1);
                }
                b'|' if self.peek_at(1) == Some(b'|') => {
                    self.finish(&mut cmd);
                    self.sep(SepKind::Or, 2);
                }
                b'|' => {
                    self.finish(&mut cmd);
                    let len = if self.peek_at(1) == Some(b'&') { 2 } else { 1 };
                    self.sep(SepKind::Pipe, len);
                }
                b'(' => {
                    if !cmd.words.is_empty() && self.peek_at(1) == Some(b')') {
                        // `name()`: a function definition; its body follows.
                        self.pos += 2;
                        self.finish(&mut cmd);
                        continue;
                    }
                    self.finish(&mut cmd);
                    self.pos += 1;
                    self.nested(|p| p.parse_list(true))?;
                }
                b')' => {
                    self.finish(&mut cmd);
                    if !in_parens {
                        return Err(Unbalanced);
                    }
                    self.pos += 1;
                    return Ok(());
                }
                b'<' | b'>' => self.redirect(&mut cmd)?,
                _ => {
                    let word = self.read_word()?;
                    // `2>file`: a word of digits right before `<`/`>` is a file descriptor.
                    let fd = matches!(self.peek(), Some(b'<' | b'>'))
                        && self.src[word.span.clone()].bytes().all(|c| c.is_ascii_digit());
                    cmd.touch(&word.span);
                    if !fd {
                        cmd.words.push(word);
                    }
                }
            }
        }
    }

    /// Run `f` one `$( )` / backtick / parenthesis level deeper.
    fn nested(&mut self, f: impl FnOnce(&mut Self) -> Step<()>) -> Step<()> {
        if self.nest >= MAX_DEPTH {
            return Err(Unbalanced);
        }
        self.nest += 1;
        let r = f(self);
        self.nest -= 1;
        r
    }

    /// A redirection operator at `pos` (`<`, `>`, `>>`, `<<`, `<<-`, `<<<`,
    /// `<>`, `>|`, `<&`, `>&`, `<(`, `>(`).
    fn redirect(&mut self, cmd: &mut Builder) -> Step<()> {
        let start = self.pos;
        if self.starts_with("<(") || self.starts_with(">(") {
            // Process substitution: an argument word whose text runs commands.
            self.pos += 2;
            self.nested(|p| p.parse_list(true))?;
            let span = start..self.pos;
            cmd.touch(&span);
            let text = self.src[span.clone()].to_owned();
            cmd.words.push(Word { pattern: WILDCARD.to_string(), text, span, dynamic: true });
            return Ok(());
        }
        if self.starts_with("<<<") {
            self.pos += 3;
            cmd.touch(&(start..self.pos));
            if let Some(word) = self.optional_word(cmd)? {
                cmd.herestrings.push(word.text);
            }
            return Ok(());
        }
        if self.starts_with("<<") {
            let strip_tabs = self.peek_at(2) == Some(b'-');
            self.pos += if strip_tabs { 3 } else { 2 };
            self.skip_blanks();
            if self.peek().is_none_or(Self::is_meta) {
                return Err(Unbalanced);
            }
            let word = self.read_word()?;
            cmd.touch(&(start..word.span.end));
            let raw = &self.src[word.span.clone()];
            let quoted = raw.contains(['\'', '"', '\\']);
            cmd.heredocs.push(self.pending.len());
            self.pending.push(PendingHereDoc {
                delimiter: word.text,
                quoted,
                strip_tabs,
                feeds_shell: false,
                owner: 0,
            });
            return Ok(());
        }
        let op_len = [">>", ">|", ">&", "<&", "<>"].iter().find(|op| self.starts_with(op)).map_or(1, |op| op.len());
        let dup = self.b[self.pos + op_len - 1] == b'&';
        self.pos += op_len;
        cmd.touch(&(start..self.pos));
        if dup {
            self.skip_blanks();
            let digits = self.b[self.pos..].iter().take_while(|c| c.is_ascii_digit() || **c == b'-').count();
            if digits > 0 {
                self.pos += digits;
                cmd.touch(&(start..self.pos));
                return Ok(());
            }
        }
        self.redirect_target(cmd)
    }

    /// The word after a redirection operator: parsed (it may hold `$( )`) and dropped.
    fn redirect_target(&mut self, cmd: &mut Builder) -> Step<()> {
        self.optional_word(cmd)?;
        Ok(())
    }

    /// Read one word starting at `pos` (which is not a metacharacter).
    fn read_word(&mut self) -> Step<Word> {
        let start = self.pos;
        let mut text: Vec<u8> = Vec::new();
        let mut dynamic = false;
        // A nested word (inside `$( )`) must not see this word's ranges.
        let outer_wild = std::mem::take(&mut self.wild);
        let word = self.read_word_parts(&mut text, &mut dynamic);
        let wild = std::mem::replace(&mut self.wild, outer_wild);
        word?;
        let pattern = pattern_of(&text, &wild);
        Ok(Word { text: String::from_utf8_lossy(&text).into_owned(), span: start..self.pos, dynamic, pattern })
    }

    fn read_word_parts(&mut self, text: &mut Vec<u8>, dynamic: &mut bool) -> Step<()> {
        while let Some(c) = self.peek() {
            match c {
                _ if Self::is_meta(c) => break,
                b'\\' => match self.peek_at(1) {
                    Some(b'\n') => self.pos += 2,
                    Some(_) => {
                        let len = self.char_len(self.pos + 1);
                        text.extend_from_slice(&self.b[self.pos + 1..self.pos + 1 + len]);
                        self.pos += 1 + len;
                    }
                    None => {
                        text.push(b'\\');
                        self.pos += 1;
                    }
                },
                b'\'' => {
                    self.pos += 1;
                    let len = self.single_quoted_len()?;
                    text.extend_from_slice(&self.b[self.pos..self.pos + len]);
                    self.pos += len + 1;
                }
                b'"' => {
                    self.pos += 1;
                    *dynamic |= self.read_double_quoted(text)?;
                }
                b'$' if self.peek_at(1) == Some(b'\'') => {
                    self.pos += 2;
                    self.read_ansi_c(text)?;
                }
                b'$' if self.peek_at(1) == Some(b'"') => {
                    self.pos += 2;
                    *dynamic |= self.read_double_quoted(text)?;
                }
                b'$' | b'`' => *dynamic |= self.read_dollar_or_backtick(text)?,
                _ => self.copy_char(text),
            }
        }
        Ok(())
    }

    /// The rest of a `"…"` string (opening quote consumed). Returns whether it
    /// held an expansion.
    fn read_double_quoted(&mut self, text: &mut Vec<u8>) -> Step<bool> {
        let mut dynamic = false;
        loop {
            match self.peek().ok_or(Unbalanced)? {
                b'"' => {
                    self.pos += 1;
                    return Ok(dynamic);
                }
                b'\\' => match self.peek_at(1) {
                    Some(b'\n') => self.pos += 2,
                    Some(c @ (b'"' | b'\\' | b'$' | b'`')) => {
                        text.push(c);
                        self.pos += 2;
                    }
                    _ => {
                        text.push(b'\\');
                        self.pos += 1;
                    }
                },
                b'$' | b'`' => dynamic |= self.read_dollar_or_backtick(text)?,
                _ => self.copy_char(text),
            }
        }
    }

    /// `$…` or a backtick at `pos`: copies its raw text into `text` and parses
    /// any commands inside. Returns whether it is an expansion.
    fn read_dollar_or_backtick(&mut self, text: &mut Vec<u8>) -> Step<bool> {
        let start = self.pos;
        if self.peek() == Some(b'`') {
            self.read_backticks()?;
        } else if self.starts_with("$((") {
            self.pos += 3;
            self.skip_arithmetic()?;
        } else if self.starts_with("$(") {
            self.pos += 2;
            self.nested(|p| p.parse_list(true))?;
        } else if self.starts_with("${") {
            self.pos += 2;
            self.skip_braces()?;
        } else {
            self.pos += 1;
            match self.peek() {
                // `$1` takes one digit; `$VAR` takes its whole name.
                Some(c) if c.is_ascii_digit() => self.pos += 1,
                Some(c) if c.is_ascii_alphabetic() || c == b'_' => {
                    while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == b'_') {
                        self.pos += 1;
                    }
                }
                Some(c) if b"@*#?$!-".contains(&c) => self.pos += 1,
                // A lone `$` is literal.
                _ => {
                    text.push(b'$');
                    return Ok(false);
                }
            }
        }
        self.wild.push(text.len()..text.len() + (self.pos - start));
        text.extend_from_slice(&self.b[start..self.pos]);
        Ok(true)
    }

    /// `` `…` `` at `pos`: parses the commands inside.
    fn read_backticks(&mut self) -> Step<()> {
        let open = self.pos;
        self.pos += 1;
        let mut inner = String::new();
        let mut escaped = false;
        loop {
            match self.peek().ok_or(Unbalanced)? {
                b'`' => break,
                b'\\' if matches!(self.peek_at(1), Some(b'`' | b'\\' | b'$')) => {
                    inner.push(self.b[self.pos + 1] as char);
                    escaped = true;
                    self.pos += 2;
                }
                _ => {
                    let len = self.char_len(self.pos);
                    inner.push_str(&self.src[self.pos..self.pos + len]);
                    self.pos += len;
                }
            }
        }
        self.pos += 1;
        if self.nest >= MAX_DEPTH {
            return Err(Unbalanced);
        }
        let mut sub = Parser {
            src: &inner,
            b: inner.as_bytes(),
            pos: 0,
            depth: self.depth,
            nest: self.nest + 1,
            pending: Vec::new(),
            out: ShellParse::default(),
            wild: Vec::new(),
        };
        let ok = sub.parse_list(false).is_ok();
        self.out.expanding_heredoc |= sub.out.expanding_heredoc;
        // Map spans back onto this input when the text was copied verbatim.
        let close = self.pos;
        let shift = move |r: &Range<usize>| if escaped { open..close } else { r.start + open + 1..r.end + open + 1 };
        for mut c in sub.out.commands {
            c.span = shift(&c.span);
            for w in &mut c.words {
                w.span = shift(&w.span);
            }
            self.out.commands.push(c);
        }
        if !ok || sub.out.unparsed {
            return Err(Unbalanced);
        }
        Ok(())
    }

    /// After `$((`: skip to the matching `))`.
    fn skip_arithmetic(&mut self) -> Step<()> {
        let mut depth = 2u32;
        while depth > 0 {
            match self.peek().ok_or(Unbalanced)? {
                b'(' => depth += 1,
                b')' => depth -= 1,
                _ => {}
            }
            self.pos += 1;
        }
        Ok(())
    }

    /// After `${`: skip to the matching `}` (quotes inside are honoured).
    fn skip_braces(&mut self) -> Step<()> {
        let mut depth = 1u32;
        while depth > 0 {
            match self.peek().ok_or(Unbalanced)? {
                b'{' => depth += 1,
                b'}' => depth -= 1,
                b'\\' => self.pos += 1,
                b'\'' => {
                    self.pos += 1;
                    self.pos += self.single_quoted_len()?;
                }
                b'"' => {
                    self.pos += 1;
                    let seen = self.wild.len();
                    self.read_double_quoted(&mut Vec::new())?;
                    self.wild.truncate(seen);
                    continue;
                }
                _ => {}
            }
            self.pos += 1;
        }
        Ok(())
    }

    /// The rest of a `$'…'` string (`$'` consumed), with ANSI-C escapes resolved.
    fn read_ansi_c(&mut self, text: &mut Vec<u8>) -> Step<()> {
        loop {
            match self.peek().ok_or(Unbalanced)? {
                b'\'' => {
                    self.pos += 1;
                    return Ok(());
                }
                b'\\' => {
                    self.pos += 1;
                    let e = self.peek().ok_or(Unbalanced)?;
                    self.pos += 1;
                    match e {
                        b'a' => text.push(0x07),
                        b'b' => text.push(0x08),
                        b'e' | b'E' => text.push(0x1b),
                        b'f' => text.push(0x0c),
                        b'n' => text.push(b'\n'),
                        b'r' => text.push(b'\r'),
                        b't' => text.push(b'\t'),
                        b'v' => text.push(0x0b),
                        b'0'..=b'7' => {
                            let mut v = u32::from(e - b'0');
                            for _ in 0..2 {
                                match self.peek() {
                                    Some(d @ b'0'..=b'7') => {
                                        v = v * 8 + u32::from(d - b'0');
                                        self.pos += 1;
                                    }
                                    _ => break,
                                }
                            }
                            text.push(v as u8);
                        }
                        b'x' => match self.hex_digits(2) {
                            Some(v) => text.push(v as u8),
                            None => text.extend_from_slice(b"\\x"),
                        },
                        b'u' | b'U' => {
                            let max = if e == b'u' { 4 } else { 8 };
                            match self.hex_digits(max).and_then(char::from_u32) {
                                Some(ch) => text.extend_from_slice(ch.encode_utf8(&mut [0; 4]).as_bytes()),
                                None => text.extend_from_slice(&[b'\\', e]),
                            }
                        }
                        b'c' => {
                            let c = self.peek().ok_or(Unbalanced)?;
                            self.pos += self.char_len(self.pos);
                            text.push(c & 0x1f);
                        }
                        b'\\' | b'\'' | b'"' | b'?' => text.push(e),
                        _ => {
                            // Unknown escape: kept as written (the char whole, if multi-byte).
                            let len = self.char_len(self.pos - 1);
                            text.push(b'\\');
                            text.extend_from_slice(&self.b[self.pos - 1..self.pos - 1 + len]);
                            self.pos += len - 1;
                        }
                    }
                }
                _ => self.copy_char(text),
            }
        }
    }

    /// Up to `max` hex digits at `pos`, as a number; `None` if there are none.
    fn hex_digits(&mut self, max: usize) -> Option<u32> {
        let n = self.b[self.pos..].iter().take(max).take_while(|c| c.is_ascii_hexdigit()).count();
        if n == 0 {
            return None;
        }
        let v = u32::from_str_radix(&self.src[self.pos..self.pos + n], 16).ok();
        self.pos += n;
        v
    }

    /// After a newline: read the bodies of the here-docs opened on that line.
    fn read_heredoc_bodies(&mut self) -> Step<()> {
        for hd in std::mem::take(&mut self.pending) {
            let body_start = self.pos;
            let body_end = loop {
                if self.pos >= self.b.len() {
                    return Err(Unbalanced);
                }
                let line_start = self.pos;
                let line_end = self.b[line_start..].iter().position(|&c| c == b'\n').map_or(self.b.len(), |n| line_start + n);
                self.pos = (line_end + 1).min(self.b.len());
                let mut line = &self.src[line_start..line_end];
                if hd.strip_tabs {
                    line = line.trim_start_matches('\t');
                }
                if line == hd.delimiter {
                    break line_start;
                }
            };
            let body_span = body_start..body_end;
            let body = &self.src[body_span.clone()];
            if !hd.quoted && (body.contains('`') || body.contains("$(")) {
                self.out.expanding_heredoc = true;
            }
            if hd.feeds_shell {
                let body = &self.src[body_span.clone()];
                let body = if hd.strip_tabs {
                    body.lines().map(|l| l.trim_start_matches('\t')).collect::<Vec<_>>().join("\n")
                } else {
                    body.to_owned()
                };
                let owner = self.out.commands[hd.owner].span.clone();
                self.payload(&body, owner);
            }
            if self.nest == 0 {
                self.out.heredocs.push(HereDoc {
                    body_span,
                    delimiter: hd.delimiter,
                    quoted: hd.quoted,
                    strip_tabs: hd.strip_tabs,
                });
            }
        }
        Ok(())
    }

    /// End the command being built: record it and parse its payloads.
    fn finish(&mut self, cmd: &mut Builder) {
        let cmd = std::mem::take(cmd);
        let Some(start) = cmd.start else { return };
        if cmd.words.is_empty() {
            // Redirections only (`> file`): nothing runs, but here-docs still need reading.
            return;
        }
        let span = start..cmd.end;
        let index = self.out.commands.len();
        let payloads = command_payloads(&cmd.words);
        self.out.commands.push(SimpleCommand { words: cmd.words, span: span.clone(), depth: self.depth });
        match payloads {
            Payload::Text(text, at) => self.payload(&text, at),
            Payload::Stdin => {
                for i in cmd.heredocs {
                    self.pending[i].feeds_shell = true;
                    self.pending[i].owner = index;
                }
                for text in cmd.herestrings {
                    self.payload(&text, span.clone());
                }
            }
            Payload::None => {}
        }
    }

    /// Parse `text` as a script one payload level deeper; its commands are
    /// reported with `span` (where the payload sits in this input).
    fn payload(&mut self, text: &str, span: Range<usize>) {
        if self.depth >= MAX_DEPTH {
            self.out.unparsed = true;
            return;
        }
        let sub = parse_at_depth(text, self.depth + 1);
        self.out.unparsed |= sub.unparsed;
        self.out.expanding_heredoc |= sub.expanding_heredoc;
        self.out.commands.extend(sub.commands.into_iter().map(|c| SimpleCommand { span: span.clone(), ..c }));
    }
}

/// What a finished command runs as a nested script.
enum Payload {
    None,
    /// `sh -c <text>` or `eval <text>`, sitting at this span.
    Text(String, Range<usize>),
    /// A shell reading its script from stdin (here-docs, here-strings).
    Stdin,
}

/// `text` with each byte range in `wild` (ascending, disjoint) replaced by [`WILDCARD`].
fn pattern_of(text: &[u8], wild: &[Range<usize>]) -> String {
    let mut out = Vec::with_capacity(text.len());
    let mut at = 0;
    for r in wild {
        out.extend_from_slice(&text[at..r.start]);
        out.extend_from_slice(WILDCARD.encode_utf8(&mut [0; 4]).as_bytes());
        at = r.end;
    }
    out.extend_from_slice(&text[at..]);
    String::from_utf8_lossy(&out).into_owned()
}

/// The index of the word that is the command actually run, skipping
/// assignments and wrappers such as `env`, `sudo` or `nohup`.
pub(crate) fn command_word_index(words: &[Word]) -> Option<usize> {
    let mut i = 0;
    while i < words.len() {
        let w = words[i].text.as_str();
        if is_assignment(w) {
            i += 1;
            continue;
        }
        if PREFIX_WORDS.contains(&basename(w)) {
            i += 1;
            // Wrapper options (`env -i`, `sudo -u root`, `timeout 5`, `nice -n 5`).
            while i < words.len() {
                let o = words[i].text.as_str();
                if o.starts_with('-') && o.len() > 1 {
                    i += 1;
                    if matches!(o, "-u" | "-n" | "-g" | "-a" | "-C" | "-s" | "-k") && i < words.len() {
                        i += 1;
                    }
                } else if is_assignment(o) || (w == "timeout" && o.chars().next().is_some_and(|c| c.is_ascii_digit())) {
                    i += 1;
                } else {
                    break;
                }
            }
            continue;
        }
        return Some(i);
    }
    None
}

fn command_payloads(words: &[Word]) -> Payload {
    let Some(at) = command_word_index(words) else { return Payload::None };
    let name = basename(&words[at].text);
    let rest = &words[at + 1..];
    if name == "eval" {
        return match (rest.first(), rest.last()) {
            (Some(first), Some(last)) => Payload::Text(
                rest.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" "),
                first.span.start..last.span.end,
            ),
            _ => Payload::None,
        };
    }
    if !SHELLS.contains(&name) {
        return Payload::None;
    }
    let mut c_flag = false;
    let mut i = 0;
    while i < rest.len() {
        let w = rest[i].text.as_str();
        if w == "--" {
            i += 1;
            break;
        }
        if !(w.starts_with('-') || w.starts_with('+')) || w.len() < 2 {
            break;
        }
        if !w.starts_with("--") {
            let flags = &w[1..];
            c_flag |= w.starts_with('-') && flags.contains('c');
            if flags.contains('o') || flags.contains('O') {
                i += 1;
            }
        }
        i += 1;
    }
    match (c_flag, rest.get(i)) {
        (true, Some(script)) => Payload::Text(script.text.clone(), script.span.clone()),
        (false, None) => Payload::Stdin,
        _ => Payload::None,
    }
}

pub(crate) fn is_assignment(w: &str) -> bool {
    match w.split_once('=') {
        Some((name, _)) => {
            !name.is_empty()
                && !name.starts_with(|c: char| c.is_ascii_digit())
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        }
        None => false,
    }
}

/// The last path component (`/bin/bash` → `bash`).
pub(crate) fn basename(w: &str) -> &str {
    w.rsplit('/').next().unwrap_or(w)
}
