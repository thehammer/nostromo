//! What tmux `send-keys` / `paste-buffer` would type, rebuilt from their
//! arguments, so the guard can scan the *typed* text for the production-shell
//! markers (`tmux send-keys -t %0 ecs_c onnect Space ap Enter` types
//! `ecs_connect ap`).
//!
//! tmux joins `send-keys` arguments with nothing between them, turns key names
//! (`Space`, `Enter`, `BSpace`, `C-u`, …) into keys and types anything else
//! literally (`-l`: always literally; `-H`: hex bytes). A small line editor
//! applies the keys that edit the shell's input line (backspace, cursor
//! movement, kill), because text can be typed out of order and fixed up.
//!
//! Keys that move or rearrange text in ways that depend on the shell and its
//! key bindings (word motion `M-b` / `C-Left`, yank `C-y`, transpose `C-t`,
//! undo `C-_`, history recall `Up`, `Escape` sequences, …) are **not**
//! applied: they are [`Key::Inexact`]. A control byte in typed text is the key a
//! terminal sends for it ([`key_for_char`]): `connect\x01ecs_` types `ecs_connect`.
//! Text typed after a kill (`C-u`, `C-k`, `C-w`) is inexact too: a yank can restore
//! what was killed. A call that mixes typed text with one
//! is "can't tell" ([`Typed::inexact`]); the guard blocks it when a remote
//! pane is open, or when the text typed could still spell a marker
//! ([`could_spell_marker`]). Nothing here runs anything.

use std::collections::HashMap;

use super::shell::Word;

/// One key a `send-keys` call types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Enter,
    Tab,
    Backspace,
    Delete,
    Left,
    Right,
    Home,
    End,
    KillToStart,
    KillToEnd,
    KillWord,
    /// A key that leaves the typed text alone (`C-c`, `C-l`, function keys, page
    /// keys, …): it ends the text like a space.
    Inert,
    /// A key that moves or rearranges text in a way the guard does not apply
    /// (`M-b`, `C-Left`, `C-y`, `C-t`, `C-_`, `C-x`, `Up`, `Escape`, …): the line
    /// that results can't be told. It ends the text like a space.
    Inexact,
    /// An argument the guard can't read as tmux does (`0x` followed by something
    /// that is not a clean hex number, a `-H` value `strtol` would not accept,
    /// `-F` format text, a repeat count past [`MAX_TYPED`]): what is typed can't be
    /// told, with or without text next to it ([`Typed::unknown`]).
    Unknown,
}

/// The arguments of one `send-keys` call, split into flags and keys.
struct SendKeysArgs<'a> {
    literal: bool,
    hex: bool,
    /// `-X` / `-M`: the arguments are copy-mode commands or mouse events, not keys.
    not_keys: bool,
    /// `-F`: the arguments are tmux formats (`#{…}`), expanded before they are typed.
    format: bool,
    repeat: usize,
    keys: Vec<&'a str>,
}

/// The most keys one run of `send-keys` calls is modelled for (the keys of every
/// call, each repeated by its `-N`). Past it the line can't be told
/// ([`Key::Unknown`]).
pub const MAX_TYPED: usize = 100_000;

fn parse_send_keys(args: &[Word]) -> SendKeysArgs<'_> {
    let mut out = SendKeysArgs { literal: false, hex: false, not_keys: false, format: false, repeat: 1, keys: Vec::new() };
    let mut i = 0;
    while i < args.len() {
        let w = args[i].text.as_str();
        if w == "--" {
            i += 1;
            break;
        }
        if !w.starts_with('-') || w.len() < 2 {
            break;
        }
        i += 1;
        let cluster: Vec<char> = w[1..].chars().collect();
        let mut k = 0;
        while k < cluster.len() {
            match cluster[k] {
                'l' => out.literal = true,
                'H' => out.hex = true,
                'X' | 'M' => out.not_keys = true,
                'F' => out.format = true,
                c @ ('c' | 'N' | 't') => {
                    let rest: String = cluster[k + 1..].iter().collect();
                    let value = if rest.is_empty() {
                        i += 1;
                        args.get(i - 1).map(|w| w.text.clone()).unwrap_or_default()
                    } else {
                        rest
                    };
                    if c == 'N' {
                        // tmux refuses a count that is not a number >= 1 (nothing is sent):
                        // read as once, which types the most that call could.
                        out.repeat = value.trim().parse::<usize>().unwrap_or(1).max(1);
                    }
                    break;
                }
                _ => {}
            }
            k += 1;
        }
    }
    out.keys = args[i..].iter().map(|w| w.text.as_str()).collect();
    out
}

/// The keys `send-keys` (with `args`, after its name) types: `-N` applied, as
/// tmux does, to all the keys that follow the options.
pub fn send_keys(args: &[Word]) -> Vec<Key> {
    let parsed = parse_send_keys(args);
    if parsed.not_keys {
        return Vec::new();
    }
    let mut once = Vec::new();
    for arg in &parsed.keys {
        if parsed.format && arg.contains('#') {
            // A format can expand to any text (`#{s/…/…/:…}`).
            once.push(Key::Unknown);
        }
        if parsed.hex {
            once.push(hex_byte(arg).map_or(Key::Unknown, key_for_char));
        } else if parsed.literal {
            once.extend(arg.chars().map(key_for_char));
        } else {
            push_arg(arg, &mut once);
        }
    }
    if once.len().saturating_mul(parsed.repeat) > MAX_TYPED {
        // One round is still scanned; the rest can't be told.
        once.push(Key::Unknown);
        return once;
    }
    let mut out = Vec::with_capacity(once.len() * parsed.repeat);
    for _ in 0..parsed.repeat {
        out.extend_from_slice(&once);
    }
    out
}

/// What `send-keys` types for one argument that is not `-l` / `-H`: the key it
/// names, else its characters.
fn push_arg(arg: &str, out: &mut Vec<Key>) {
    if let Some(key) = key_named(arg) {
        out.push(key);
    } else if let Some(hex) = arg.strip_prefix("0x") {
        // tmux reads `0x…` with `sscanf("%x")` (white space and a sign are skipped,
        // anything after the digits is ignored). Only `0x` and hex digits is taken as
        // written; anything else can't be told (and its text is kept).
        match hex_number(hex) {
            Some((value, true)) => out.extend(char::from_u32(value).map(key_for_char).or(Some(Key::Unknown))),
            _ => {
                out.push(Key::Unknown);
                out.extend(arg.chars().map(key_for_char));
            }
        }
    } else {
        // `0X65` is text to tmux 3.5 (and a key to a version that ignores case).
        if arg.len() > 2 && arg.as_bytes()[..2].eq_ignore_ascii_case(b"0x") {
            out.push(Key::Unknown);
        }
        out.extend(arg.chars().map(key_for_char));
    }
}

/// `digits` (after `0x`) as a number, and whether nothing but hex digits was
/// there. `None` when there is no digit.
fn hex_number(digits: &str) -> Option<(u32, bool)> {
    let n = digits.bytes().take_while(u8::is_ascii_hexdigit).count();
    if n == 0 {
        return None;
    }
    let value = u32::from_str_radix(&digits[..n], 16).ok()?;
    Some((value, n == digits.len()))
}

/// What `send-keys -H` types for one argument: tmux reads it with `strtol(s, &end,
/// 16)` and sends the byte if it is 0 to 255 and nothing follows the number. So
/// leading white space, a `+` and a `0x` / `0X` are fine; anything else is not typed
/// (here: `None`, a key the guard can't tell).
fn hex_byte(arg: &str) -> Option<char> {
    let s = arg.trim_start_matches([' ', '\t', '\n', '\x0b', '\x0c', '\r']);
    let s = s.strip_prefix('+').unwrap_or(s);
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    u32::from_str_radix(s, 16).ok().filter(|v| *v <= 0xff).and_then(char::from_u32)
}

/// The key a name stands for, `None` when the argument is plain text.
fn key_named(name: &str) -> Option<Key> {
    let lower = name.to_ascii_lowercase();
    // `^x` is `C-x`.
    let lower = match lower.strip_prefix('^') {
        Some(c) if c.chars().count() == 1 => format!("c-{c}"),
        _ => lower,
    };
    // Keypad keys type their character (`KP-` is `-`).
    if let Some(key) = keypad_key(&lower) {
        return Some(key);
    }
    Some(match lower.as_str() {
        "space" => Key::Char(' '),
        "enter" | "kpenter" | "c-m" | "c-j" => Key::Enter,
        "tab" | "c-i" => Key::Tab,
        "bspace" | "c-h" | "c-?" => Key::Backspace,
        "dc" | "delete" | "c-d" => Key::Delete,
        "left" | "c-b" => Key::Left,
        "right" | "c-f" => Key::Right,
        "home" | "c-a" => Key::Home,
        "end" | "c-e" => Key::End,
        "c-u" => Key::KillToStart,
        "c-k" => Key::KillToEnd,
        "c-w" => Key::KillWord,
        // History recall and escape sequences (`Escape b` is `M-b`).
        "escape" | "up" | "down" => Key::Inexact,
        "btab" | "ppage" | "npage" | "pageup" | "pagedown" | "pgup" | "pgdn" | "ic" | "insert" | "any" => Key::Inert,
        _ => return modified_key(&lower),
    })
}

/// The keypad keys tmux names, and what each types.
fn keypad_key(lower: &str) -> Option<Key> {
    let c = match lower.strip_prefix("kp")? {
        "/" => '/',
        "*" => '*',
        "-" => '-',
        "+" => '+',
        "." => '.',
        "enter" => return Some(Key::Enter),
        d if d.len() == 1 && d.as_bytes()[0].is_ascii_digit() => d.chars().next()?,
        _ => return None,
    };
    Some(Key::Char(c))
}

/// Mouse, focus and paste-marker keys: they type nothing.
fn no_text_key(lower: &str) -> bool {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(
            r"^(?:(?:mousedown|mouseup|mousedrag|mousedragend|mousemove|wheelup|wheeldown|secondclick|doubleclick|tripleclick)[1-3]?(?:pane|status|statusleft|statusright|statusdefault|border)|focusin|focusout|pastestart|pasteend)$",
        )
        .unwrap()
    })
    .is_match(lower)
}

/// `C-`, `M-` and `S-` keys (any mix, `C-M-b`), function keys and keypad keys.
/// Only a modifier on a real key counts: `c-note` is text.
fn modified_key(lower: &str) -> Option<Key> {
    let mut base = lower;
    let mut modified = false;
    while let Some(rest) = base.strip_prefix("c-").or_else(|| base.strip_prefix("m-")).or_else(|| base.strip_prefix("s-")) {
        base = rest;
        modified = true;
    }
    let single = base.chars().count() == 1;
    let named = matches!(
        base,
        "up" | "down" | "left" | "right" | "home" | "end" | "bspace" | "dc" | "delete" | "ic" | "insert" | "tab"
            | "btab" | "enter" | "escape" | "space" | "ppage" | "npage" | "pageup" | "pagedown"
    );
    let function = base.len() > 1 && base.starts_with('f') && base[1..].bytes().all(|b| b.is_ascii_digit());
    let keypad = keypad_key(base).is_some();
    if !modified {
        return (function || no_text_key(base)).then_some(Key::Inert);
    }
    if !(single || named || function || keypad) {
        return None;
    }
    // Keys the shell reads as no text change.
    Some(match lower {
        "c-c" | "c-g" | "c-l" | "c-z" | "c-\\" | "c-@" => Key::Inert,
        _ if function => Key::Inert,
        _ => Key::Inexact,
    })
}

/// The keys that type `text` (a pasted buffer): each newline is Enter.
pub fn keys_of_text(text: &str) -> Vec<Key> {
    text.chars().map(key_for_char).collect()
}

/// The key a character of typed text is. A control character is the key a
/// terminal sends for it, whatever way it got into the text (`send-keys -l
/// $'a\x01b'`, `-H 01`, a pasted buffer): `\x01` is `C-a`, so `connect\x01ecs_`
/// types `ecs_connect`. The same keys as [`key_named`] map to the same [`Key`];
/// every other control character (`ESC`, `C-t`, `C-y`, …) is [`Key::Inexact`].
pub fn key_for_char(c: char) -> Key {
    match c {
        '\r' | '\n' => Key::Enter,
        '\t' => Key::Tab,
        '\x08' | '\x7f' => Key::Backspace,
        '\x01' => Key::Home,
        '\x02' => Key::Left,
        '\x04' => Key::Delete,
        '\x05' => Key::End,
        '\x06' => Key::Right,
        '\x0b' => Key::KillToEnd,
        '\x15' => Key::KillToStart,
        '\x17' => Key::KillWord,
        // `C-@`, `C-c`, `C-g`, `C-l`, `C-z`, `C-\`: the line is left alone.
        '\x00' | '\x03' | '\x07' | '\x0c' | '\x1a' | '\x1c' => Key::Inert,
        c if (c as u32) < 0x20 => Key::Inexact,
        c => Key::Char(c),
    }
}

/// What a run of keys leaves in the shell's input, in the ways it can be read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Typed {
    /// The input lines after the line editor ran, one per Enter, joined by `\n`.
    pub edited: String,
    /// Characters only, other keys as a space (Enter as a newline).
    pub spaced: String,
    /// Characters only, other keys dropped (Enter stays a newline).
    pub joined: String,
    /// The word before the cursor at each Tab (a shell completes it).
    pub tab_words: Vec<String>,
    /// A [`Key::Inexact`] was typed along with text: `edited` can't be trusted.
    pub inexact: bool,
    /// A [`Key::Unknown`] was typed: what the call types can't be told at all.
    pub unknown: bool,
}

impl Typed {
    /// What the keys type can't be told: an editing key the guard doesn't apply
    /// next to text, or a key it can't read.
    pub fn cant_tell(&self) -> bool {
        self.inexact || self.unknown
    }

    /// The distinct texts to scan.
    pub fn texts(&self) -> Vec<&str> {
        let mut out: Vec<&str> = Vec::new();
        for t in [&self.edited, &self.spaced, &self.joined] {
            if !t.is_empty() && !out.contains(&t.as_str()) {
                out.push(t);
            }
        }
        out
    }
}

/// Could `typed` (text typed along with keys that rearrange it) still be
/// reordered into one of `markers` (lowercase words)? Cheap and wide on
/// purpose: a marker's first four characters appear in it, or it holds every
/// distinct letter of a marker (a yank can repeat text, so counts don't matter).
pub fn could_spell_marker(typed: &str, markers: &[&str]) -> bool {
    let typed = typed.to_ascii_lowercase();
    markers.iter().any(|m| {
        typed.contains(&m[..m.len().min(4)]) || m.chars().all(|c| typed.contains(c))
    })
}

/// Run `keys` through the line editor.
pub fn type_keys(keys: &[Key]) -> Typed {
    let mut typed = Typed::default();
    let mut lines: Vec<String> = Vec::new();
    let mut line: Vec<char> = Vec::new();
    let mut cursor = 0usize;
    // Text was killed (`C-u`, `C-k`, `C-w`): it sits in the shell's kill ring,
    // and a yank (typed in this call or an earlier one) puts it back.
    let mut killed = false;
    for key in keys {
        match *key {
            Key::Char(c) => {
                // Text typed after a kill may be rejoined with the killed text.
                typed.inexact |= killed;
                line.insert(cursor, c);
                cursor += 1;
                typed.spaced.push(c);
                typed.joined.push(c);
            }
            Key::Enter => {
                lines.push(line.drain(..).collect());
                cursor = 0;
                typed.spaced.push('\n');
                typed.joined.push('\n');
            }
            Key::Tab => {
                let before: String = line[..cursor].iter().collect();
                typed.tab_words.push(before.rsplit(char::is_whitespace).next().unwrap_or_default().to_owned());
                typed.spaced.push(' ');
            }
            Key::Backspace => {
                if cursor > 0 {
                    line.remove(cursor - 1);
                    cursor -= 1;
                }
                typed.spaced.push(' ');
            }
            Key::Delete => {
                if cursor < line.len() {
                    line.remove(cursor);
                }
                typed.spaced.push(' ');
            }
            Key::Left => {
                cursor = cursor.saturating_sub(1);
                typed.spaced.push(' ');
            }
            Key::Right => {
                cursor = (cursor + 1).min(line.len());
                typed.spaced.push(' ');
            }
            Key::Home => {
                cursor = 0;
                typed.spaced.push(' ');
            }
            Key::End => {
                cursor = line.len();
                typed.spaced.push(' ');
            }
            Key::KillToStart => {
                killed |= line[..cursor].iter().any(|c| !c.is_whitespace());
                line.drain(..cursor);
                cursor = 0;
                typed.spaced.push(' ');
            }
            Key::KillToEnd => {
                killed |= line[cursor..].iter().any(|c| !c.is_whitespace());
                line.truncate(cursor);
                typed.spaced.push(' ');
            }
            Key::KillWord => {
                let mut start = cursor;
                while start > 0 && line[start - 1].is_whitespace() {
                    start -= 1;
                }
                while start > 0 && !line[start - 1].is_whitespace() {
                    start -= 1;
                }
                killed |= line[start..cursor].iter().any(|c| !c.is_whitespace());
                line.drain(start..cursor);
                cursor = start;
                typed.spaced.push(' ');
            }
            Key::Inert => typed.spaced.push(' '),
            Key::Unknown => {
                typed.unknown = true;
                typed.spaced.push(' ');
            }
            Key::Inexact => {
                typed.inexact = true;
                typed.spaced.push(' ');
            }
        }
    }
    // An editing key alone (`Up Enter`, `M-b`) has no typed text to mix up.
    typed.inexact &= typed.joined.chars().any(|c| !c.is_whitespace());
    lines.push(line.into_iter().collect());
    typed.edited = lines.join("\n");
    typed
}

/// tmux paste buffers as one command string fills them (`set-buffer`), so
/// `paste-buffer` can be read as the text it types.
#[derive(Debug, Default)]
pub struct Buffers {
    named: HashMap<String, String>,
    /// The name of the buffer `paste-buffer` takes without `-b`.
    top: Option<String>,
    automatic: usize,
}

impl Buffers {
    /// `set-buffer [-aw] [-b buffer-name] [-n new-buffer-name] data`.
    pub fn set(&mut self, args: &[Word]) {
        let (mut append, mut name, mut i) = (false, None::<String>, 0);
        while i < args.len() {
            let w = args[i].text.as_str();
            if w == "--" {
                i += 1;
                break;
            }
            if !w.starts_with('-') || w.len() < 2 {
                break;
            }
            i += 1;
            let cluster: Vec<char> = w[1..].chars().collect();
            for (k, c) in cluster.iter().enumerate() {
                match c {
                    'a' => append = true,
                    'b' | 'n' => {
                        let rest: String = cluster[k + 1..].iter().collect();
                        let value = if rest.is_empty() {
                            i += 1;
                            args.get(i - 1).map(|w| w.text.clone()).unwrap_or_default()
                        } else {
                            rest
                        };
                        if *c == 'b' {
                            name = Some(value);
                        }
                        break;
                    }
                    _ => {}
                }
            }
        }
        let Some(data) = args.get(i).map(|w| w.text.as_str()) else { return };
        let name = name.or_else(|| append.then(|| self.top.clone()).flatten()).unwrap_or_else(|| {
            self.automatic += 1;
            format!("buffer{:04}", self.automatic)
        });
        let slot = self.named.entry(name.clone()).or_default();
        if !append {
            slot.clear();
        }
        slot.push_str(data);
        self.top = Some(name);
    }

    /// What `paste-buffer [-dpr] [-b buffer-name] [-s separator] [-t target]` types.
    pub fn pasted(&self, args: &[Word]) -> Option<&str> {
        let mut name = None::<&str>;
        let mut i = 0;
        while i < args.len() {
            let w = args[i].text.as_str();
            if !w.starts_with('-') || w.len() < 2 {
                break;
            }
            i += 1;
            if let Some(rest) = w.strip_prefix("-b") {
                name = if rest.is_empty() {
                    i += 1;
                    args.get(i - 1).map(|w| w.text.as_str())
                } else {
                    Some(rest)
                };
            } else if w.ends_with(['s', 't']) && w.len() == 2 {
                i += 1;
            }
        }
        let key = name.map(str::to_owned).or_else(|| self.top.clone())?;
        self.named.get(&key).map(String::as_str)
    }

    /// Every buffer's final text.
    pub fn contents(&self) -> impl Iterator<Item = &str> {
        self.named.values().map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<Word> {
        args.iter()
            .map(|a| Word { text: (*a).to_owned(), span: 0..0, dynamic: false, pattern: (*a).to_owned() })
            .collect()
    }

    fn typed(args: &[&str]) -> Typed {
        type_keys(&send_keys(&words(args)))
    }

    #[test]
    fn joins_arguments_and_maps_names() {
        assert_eq!(typed(&["-t", "%0", "ecs_c", "onnect", "Space", "ap", "Enter"]).edited, "ecs_connect ap\n");
        assert_eq!(typed(&["a b", "Space", "c"]).edited, "a b c");
        assert_eq!(typed(&["-l", "Space", "Enter"]).edited, "SpaceEnter");
        assert_eq!(typed(&["-H", "65", "63", "73"]).edited, "ecs");
        assert_eq!(typed(&["-N", "2", "ab"]).edited, "abab");
    }

    #[test]
    fn edits_the_line() {
        assert_eq!(typed(&["ecs_cXBSpaceonnect"]).edited, "ecs_cXBSpaceonnect");
        assert_eq!(typed(&["ecs_cX", "BSpace", "onnect"]).edited, "ecs_connect");
        assert_eq!(typed(&["nnect", "Home", "ecs_co"]).edited, "ecs_connect");
        assert_eq!(typed(&["abc", "C-u", "x"]).edited, "x");
        assert_eq!(typed(&["a", "Left", "b", "End", "c"]).edited, "bac");
    }

    #[test]
    fn keys_that_rearrange_text_are_inexact_only_when_text_is_typed() {
        for keys in [
            &["connect", "M-b", "ecs_"][..],
            &["connect", "M-Left", "ecs_"],
            &["connect", "C-Left", "ecs_"],
            &["connect", "C-u", "ecs_", "C-y"],
            &["ecs_connetc", "C-t"],
            &["x", "C-_"],
            &["x", "C-x", "C-u"],
            &["x", "Escape", "b"],
            &["x", "Up"],
            &["x", "^y"],
        ] {
            assert!(typed(keys).inexact, "{keys:?}");
        }
        for keys in [&["M-b"][..], &["Up", "Enter"], &["C-y"], &["ls", "C-c"], &["ls", "C-l", "Enter"], &["ls", "F5"], &["a c-note"], &["m-ecs_", "connect"]] {
            assert!(!typed(keys).inexact, "{keys:?}");
        }
        // `m-ecs_` is not a key: the text is typed.
        assert_eq!(typed(&["m-ecs_", "connect"]).edited, "m-ecs_connect");
    }

    #[test]
    fn could_spell_marker_is_wide_on_purpose() {
        let markers = ["ecs_connect", "execute-command"];
        assert!(could_spell_marker("connectecs_", &markers));
        assert!(could_spell_marker("cesconnect_", &markers));
        assert!(could_spell_marker("execu", &markers));
        assert!(!could_spell_marker("ls", &markers));
        assert!(!could_spell_marker("git status", &markers));
    }

    #[test]
    fn tab_records_the_word() {
        assert_eq!(typed(&["echo ecs_c", "Tab"]).tab_words, ["ecs_c"]);
    }

    #[test]
    fn buffers() {
        let mut b = Buffers::default();
        b.set(&words(&["-b", "a", "ecs_"]));
        b.set(&words(&["-a", "-b", "a", "connect"]));
        assert_eq!(b.pasted(&words(&["-b", "a", "-t", "%0"])), Some("ecs_connect"));
        assert_eq!(b.pasted(&words(&["-t", "%0"])), Some("ecs_connect"));
    }

    // ── round 4 ──

    /// The keys of several `send-keys` calls, one after another (what a command string of
    /// `send-keys …; send-keys …` types).
    fn typed_calls(calls: &[&[&str]]) -> Typed {
        let keys: Vec<Key> = calls.iter().flat_map(|args| send_keys(&words(args))).collect();
        type_keys(&keys)
    }

    #[test]
    fn hex_key_names_type_the_character_they_name() {
        assert_eq!(typed(&["0x65", "0x63", "0x73"]).edited, "ecs");
        assert_eq!(typed(&["0x65", "cs_", "0x63", "onnect"]).edited, "ecs_connect");
        // `0x01` is C-a (Home), `0x0d` is Enter
        assert_eq!(typed(&["connect", "0x01", "ecs_"]).edited, "ecs_connect");
        assert_eq!(typed(&["ls", "0x0d"]).edited, "ls\n");
        assert!(!typed(&["0x65", "0x63", "0x6c", "0x73"]).cant_tell());
    }

    #[test]
    fn hex_key_names_that_are_not_clean_numbers_are_keys_the_guard_cannot_read() {
        // tmux types `e` for `0x65zz` and ignores the rest; `0X65` is text to one version of tmux
        // and a key to another: either way the guard can't tell what is typed.
        for key in ["0x65zz", "0xZZ", "0X65"] {
            assert!(typed(&[key]).unknown, "{key}");
            assert!(typed(&["ecs_", key, "connect"]).cant_tell(), "{key}");
        }
    }

    #[test]
    fn keypad_keys_type_their_character() {
        assert_eq!(typed(&["execute", "KP-", "command"]).edited, "execute-command");
        assert_eq!(typed(&["KP+", "KP*", "KP/", "KP.", "KP0", "KP5", "KP9"]).edited, "+*/.059");
        assert_eq!(typed(&["ls", "KPEnter"]).edited, "ls\n");
        assert!(!typed(&["KP-", "KP5"]).cant_tell());
    }

    #[test]
    fn any_and_nul_type_nothing_and_leave_the_line_alone() {
        for key in ["Any", "any", "ANY", "0x00"] {
            let t = typed(&["ecs_", key, "connect"]);
            assert_eq!(t.edited, "ecs_connect", "{key}");
            assert!(!t.cant_tell(), "{key}");
        }
    }

    #[test]
    fn hex_flag_reads_each_argument_as_strtol_does() {
        // leading white space, `0x` and `0X` are fine
        assert_eq!(typed(&["-H", "65", "63", "73"]).edited, "ecs");
        assert_eq!(typed(&["-H", "0x65", "0X63", " 73"]).edited, "ecs");
        assert_eq!(typed(&["-H", " 65", " 63", " 73", " 5f", " 63", " 6f", " 6e", " 6e", " 65", " 63", " 74"]).edited, "ecs_connect");
        assert!(!typed(&["-H", "0X65", " 63"]).cant_tell());
        // anything after the number, or no number, is not a key the guard can read
        for arg in ["65zz", "zz", ""] {
            assert!(typed(&["-H", arg]).unknown, "{arg:?}");
        }
    }

    #[test]
    fn a_repeat_count_applies_exactly_up_to_the_bound() {
        // 100 characters, then 100 BSpace in another call: the line is empty
        let x = "X".repeat(100);
        let t = typed_calls(&[&[x.as_str()], &["-N", "100", "BSpace"]]);
        assert_eq!(t.edited, "");
        assert!(!t.cant_tell());
        // …and 99 leave one
        assert_eq!(typed_calls(&[&[x.as_str()], &["-N", "99", "BSpace"]]).edited, "X");
        // `ecs_`, 100 characters, 100 BSpace, `connect`: a marker
        let first = format!("ecs_{x}");
        let t = typed_calls(&[&[first.as_str()], &["-N", "100", "BSpace"], &["connect"]]);
        assert_eq!(t.edited, "ecs_connect");
        // the count may be attached to the flag
        assert_eq!(typed_calls(&[&[x.as_str()], &["-N100", "BSpace"]]).edited, "");
        assert_eq!(typed(&["-N", "3", "ab"]).edited, "ababab");
    }

    #[test]
    fn a_run_of_keys_past_the_bound_is_one_the_guard_cannot_tell() {
        let at_bound = typed(&["-N", &MAX_TYPED.to_string(), "x"]);
        assert!(!at_bound.unknown, "exactly the bound is still followed");
        assert_eq!(at_bound.joined.len(), MAX_TYPED);

        for count in [MAX_TYPED + 1, 1_000_000, 1_000_000_000] {
            let past = typed(&["-N", &count.to_string(), "x"]);
            assert!(past.unknown, "-N {count}");
            assert!(past.cant_tell(), "-N {count}");
            // nothing like `count` characters was built for it
            assert!(past.joined.len() <= MAX_TYPED + 1, "-N {count}: {} characters", past.joined.len());
        }
    }
}
