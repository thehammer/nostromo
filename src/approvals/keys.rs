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
//! Nothing here runs anything.

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
    /// A key that edits nothing the guard models (arrows up and down, `Escape`,
    /// function keys, `C-c`, `M-x`, …): it ends the text like a space.
    Other,
}

/// The arguments of one `send-keys` call, split into flags and keys.
struct SendKeysArgs<'a> {
    literal: bool,
    hex: bool,
    /// `-X` / `-M`: the arguments are copy-mode commands or mouse events, not keys.
    not_keys: bool,
    repeat: usize,
    keys: Vec<&'a str>,
}

/// The most times `send-keys -N` repeats its keys that is modelled.
const MAX_REPEAT: usize = 64;

fn parse_send_keys(args: &[Word]) -> SendKeysArgs<'_> {
    let mut out = SendKeysArgs { literal: false, hex: false, not_keys: false, repeat: 1, keys: Vec::new() };
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
                c @ ('c' | 'N' | 't') => {
                    let rest: String = cluster[k + 1..].iter().collect();
                    let value = if rest.is_empty() {
                        i += 1;
                        args.get(i - 1).map(|w| w.text.clone()).unwrap_or_default()
                    } else {
                        rest
                    };
                    if c == 'N' {
                        out.repeat = value.parse::<usize>().unwrap_or(1).clamp(1, MAX_REPEAT);
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

/// The keys `send-keys` (with `args`, after its name) types.
pub fn send_keys(args: &[Word]) -> Vec<Key> {
    let parsed = parse_send_keys(args);
    if parsed.not_keys {
        return Vec::new();
    }
    let mut once = Vec::new();
    for arg in &parsed.keys {
        if parsed.hex {
            if let Some(c) = u32::from_str_radix(arg.trim_start_matches("0x"), 16).ok().and_then(char::from_u32) {
                once.push(Key::Char(c));
            }
        } else if parsed.literal {
            once.extend(arg.chars().map(Key::Char));
        } else if let Some(key) = key_named(arg) {
            once.push(key);
        } else {
            once.extend(arg.chars().map(Key::Char));
        }
    }
    let mut out = Vec::with_capacity(once.len() * parsed.repeat);
    for _ in 0..parsed.repeat {
        out.extend_from_slice(&once);
    }
    out
}

/// The key a name stands for, `None` when the argument is plain text.
fn key_named(name: &str) -> Option<Key> {
    let lower = name.to_ascii_lowercase();
    Some(match lower.as_str() {
        "space" => Key::Char(' '),
        "enter" | "kpenter" | "c-m" | "c-j" | "^m" | "^j" => Key::Enter,
        "tab" | "c-i" | "^i" => Key::Tab,
        "bspace" | "c-h" | "c-?" | "^h" | "^?" => Key::Backspace,
        "dc" | "delete" | "c-d" | "^d" => Key::Delete,
        "left" | "c-b" | "^b" => Key::Left,
        "right" | "c-f" | "^f" => Key::Right,
        "home" | "c-a" | "^a" => Key::Home,
        "end" | "c-e" | "^e" => Key::End,
        "c-u" | "^u" => Key::KillToStart,
        "c-k" | "^k" => Key::KillToEnd,
        "c-w" | "^w" => Key::KillWord,
        "escape" | "up" | "down" | "btab" | "ppage" | "npage" | "pageup" | "pagedown" | "ic" | "insert" => {
            Key::Other
        }
        _ => {
            let modifier = lower.len() > 2 && matches!(lower.as_bytes(), [b'c' | b'm' | b's', b'-', ..]);
            let caret = lower.len() == 2 && lower.starts_with('^');
            let function = lower.len() > 1 && lower.starts_with('f') && lower[1..].bytes().all(|b| b.is_ascii_digit());
            if modifier || caret || function || (lower.starts_with("kp") && name.len() > 2) {
                Key::Other
            } else {
                return None;
            }
        }
    })
}

/// The keys that type `text` (a pasted buffer): each newline is Enter.
pub fn keys_of_text(text: &str) -> Vec<Key> {
    text.chars().map(|c| if c == '\n' { Key::Enter } else { Key::Char(c) }).collect()
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
}

impl Typed {
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

/// Run `keys` through the line editor.
pub fn type_keys(keys: &[Key]) -> Typed {
    let mut typed = Typed::default();
    let mut lines: Vec<String> = Vec::new();
    let mut line: Vec<char> = Vec::new();
    let mut cursor = 0usize;
    for key in keys {
        match *key {
            Key::Char(c) => {
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
                line.drain(..cursor);
                cursor = 0;
                typed.spaced.push(' ');
            }
            Key::KillToEnd => {
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
                line.drain(start..cursor);
                cursor = start;
                typed.spaced.push(' ');
            }
            Key::Other => typed.spaced.push(' '),
        }
    }
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
}
