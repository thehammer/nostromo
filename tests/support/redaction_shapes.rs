//! Command-line shapes shared by `terminal_text_redaction.rs` (the `Redactor`
//! on raw text) and `terminal_text_delivery.rs` (bytes -> `LineAssembler` ->
//! `deliver`), so both paths are held to exactly the same cases.
//!
//! Every secret is built at RUNTIME from fragments: no secret-shaped literal
//! sits in the repo. A shape is one line of terminal text plus the strings that
//! must not be readable anywhere in what comes out.

#![allow(dead_code)]

/// One line of terminal text, and what must not survive redaction of it.
pub struct Shape {
    pub name: String,
    pub line: String,
    /// Strings that must not be readable in the redacted text (hidden
    /// characters ignored, fullwidth forms folded, markers removed).
    pub secrets: Vec<String>,
}

fn shape(name: impl Into<String>, line: String, secrets: &[&str]) -> Shape {
    Shape {
        name: name.into(),
        line,
        secrets: secrets.iter().map(|s| s.to_string()).collect(),
    }
}

fn cat(parts: &[&str]) -> String {
    parts.concat()
}

fn consonants(seed: u64, n: usize) -> String {
    const ALPHABET: &[u8] = b"BCDFGHJKLMNPQRSTVWXZ";
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..n)
        .map(|_| {
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            let r = x.wrapping_mul(0x2545_F491_4F6C_DD1D);
            ALPHABET[(r % ALPHABET.len() as u64) as usize] as char
        })
        .collect()
}

// ───────────────────────────── reading the output ────────────────────────────

fn is_filler(c: char) -> bool {
    matches!(c,
        '\u{ad}' | '\u{34f}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}'
        | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{2069}' | '\u{feff}'
        | '\u{e0000}'..='\u{e007f}')
}

/// `text` without its hidden characters and nothing else changed.
pub fn without_filler(text: &str) -> String {
    text.chars().filter(|c| !is_filler(*c)).collect()
}

/// What a reader sees: hidden characters gone, fullwidth forms and dash
/// look-alikes folded to ASCII, `[redacted: ...]` markers removed (so the
/// marker's own letters cannot be mistaken for a secret).
pub fn reader_view(text: &str) -> String {
    let mut unmarked = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("[redacted: ") {
        unmarked.push_str(&rest[..at]);
        rest = match rest[at..].find(']') {
            Some(end) => &rest[at + end + 1..],
            None => "",
        };
    }
    unmarked.push_str(rest);
    unmarked
        .chars()
        .filter(|c| !is_filler(*c))
        .map(|c| match c {
            '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap_or(c),
            '\u{2010}'..='\u{2015}' | '\u{2212}' => '-',
            _ => c,
        })
        .collect()
}

/// A readable piece of `secret` in `view`: the whole of a short secret, or the
/// whole or any five-character window of a longer one.
pub fn readable_piece(view: &str, secret: &str) -> Option<String> {
    if view.contains(secret) {
        return Some(secret.to_string());
    }
    let chars: Vec<char> = secret.chars().collect();
    if chars.len() < 8 {
        return None;
    }
    chars
        .windows(5)
        .map(|w| w.iter().collect::<String>())
        .find(|w| view.contains(w.as_str()))
}

/// Why `output` (the redacted text of `shape`) is not good enough, if it isn't:
/// a secret still readable, no marker, or no redaction reported.
pub fn verdict(shape: &Shape, output: &str, redactions: usize) -> Option<String> {
    let view = reader_view(output);
    for secret in &shape.secrets {
        if let Some(piece) = readable_piece(&view, secret) {
            return Some(format!("{piece:?} is readable in {output:?}"));
        }
    }
    if !output.contains("[redacted: ") {
        return Some(format!("no [redacted: ] marker in {output:?}"));
    }
    if redactions == 0 {
        return Some(format!("no redaction reported for {output:?}"));
    }
    None
}

// ───────────────────────────── hidden separators ─────────────────────────────

/// Hidden text that stands where a space would be: (name, text).
pub fn separators() -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = [
        '\u{200b}', '\u{200c}', '\u{200d}', '\u{2060}', '\u{feff}', '\u{ad}', '\u{200e}',
        '\u{202e}',
    ]
    .into_iter()
    .map(|c| (format!("U+{:04X}", c as u32), c.to_string()))
    .collect();
    out.push((
        "a run of mixed filler".into(),
        "\u{200b}\u{200d}\u{feff}\u{ad}\u{2060}\u{200c}".into(),
    ));
    out.push((
        "a bidi override and a zero-width space".into(),
        "\u{202e}\u{200b}".into(),
    ));
    out
}

/// Every command shape whose redaction rule needs a blank, with `f` (hidden
/// text) where the blank would be. All of them are secrets in plain text too.
pub fn filler_as_separator_shapes(label: &str, f: &str) -> Vec<Shape> {
    let pw = consonants(701, 12);
    let bearer = consonants(702, 24);
    let b64 = consonants(703, 20);
    let short = consonants(704, 10);
    let n = |what: &str| format!("{what} with {label}");
    vec![
        shape(
            n("curl, filler before -u"),
            format!("curl{f}-u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            n("curl -u, filler before the user"),
            format!("curl -u{f}admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            n("curl --user, filler before the user"),
            format!("curl --user{f}admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            n("curl --proxy-user, filler before the user"),
            format!("curl --proxy-user{f}ops:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            n("curl, filler before --user"),
            format!("curl{f}--user admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            n("--password, filler before the value"),
            format!("tool --password{f}{pw} run"),
            &[&pw],
        ),
        shape(
            n("--token, filler before the value"),
            format!("tool --token{f}{pw} run"),
            &[&pw],
        ),
        shape(
            n("Bearer, filler before the token"),
            format!("sent Bearer{f}{bearer} ok"),
            &[&bearer],
        ),
        shape(
            n("Authorization:, filler before the scheme"),
            format!("Authorization:{f}Basic {b64}=="),
            &[&b64],
        ),
        shape(
            n("Authorization: Basic, filler before the credentials"),
            format!("Authorization: Basic{f}{b64}=="),
            &[&b64],
        ),
        shape(
            n("mysql, filler before -p"),
            format!("mysql{f}-p{short} appdb"),
            &[&short],
        ),
        shape(
            n("mysql -u root, filler before -p"),
            format!("mysql -u root{f}-p{short} appdb"),
            &[&short],
        ),
        shape(
            n("sshpass, filler before -p"),
            format!("sshpass{f}-p {short} ssh deploy@host"),
            &[&short],
        ),
        shape(
            n("sshpass -p, filler before the password"),
            format!("sshpass -p{f}{short} ssh deploy@host"),
            &[&short],
        ),
        shape(
            n("docker login, filler before -u"),
            format!("docker login{f}-u user -p {pw}"),
            &[&pw],
        ),
        shape(
            n("docker, filler before login"),
            format!("docker{f}login -u user -p {pw}"),
            &[&pw],
        ),
        shape(
            n("docker login, filler before -p"),
            format!("docker login -u user{f}-p {pw}"),
            &[&pw],
        ),
        shape(
            n("docker login -p, filler before the password"),
            format!("docker login -u user -p{f}{pw}"),
            &[&pw],
        ),
        shape(
            n("redis-cli, filler before -a"),
            format!("redis-cli{f}-a {pw}"),
            &[&pw],
        ),
        shape(
            n("redis-cli -a, filler before the password"),
            format!("redis-cli -a{f}{pw}"),
            &[&pw],
        ),
        shape(
            n("export, filler before the name"),
            format!("export{f}PASSWORD={pw}"),
            &[&pw],
        ),
        shape(
            n("assignment, filler before the value"),
            format!("PASSWORD={f}{pw}"),
            &[&pw],
        ),
        shape(
            n("password: filler before the value"),
            format!("password:{f}{pw}"),
            &[&pw],
        ),
        shape(
            n("unzip, filler before -P"),
            format!("unzip{f}-P {short} a.zip"),
            &[&short],
        ),
        shape(
            n("ldapsearch, filler before -w"),
            format!("ldapsearch{f}-w {short} -b dc=x"),
            &[&short],
        ),
        shape(
            n("7z, filler before -p"),
            format!("7z{f}-p{short} x a.7z"),
            &[&short],
        ),
    ]
}

/// Ordinary commands with `f` standing where a space would be. They hold no
/// secret and must come back with nothing redacted.
pub fn ordinary_filler_lines(f: &str) -> Vec<String> {
    vec![
        format!("curl{f}-X GET https://example.com"),
        format!("curl{f}-sSL https://example.com/install.sh"),
        format!("curl{f}-u 'admin' https://example.com/x"),
        format!("curl{f}-u admin https://example.com"),
        format!("curl{f}https://example.com/a:b"),
        format!("mysql{f}-u root appdb"),
        format!("docker{f}login -u user"),
        format!("export{f}PATH=/usr/bin:/bin"),
        format!("mkdir{f}-p out/dir"),
        format!("ssh{f}-p 22 deploy@host"),
    ]
}

// ───────────────────────────── curl quoting ──────────────────────────────────

/// `curl -u` credentials in every quoting the shell allows. User `admin`.
pub fn curl_quote_shapes() -> Vec<Shape> {
    let hun = cat(&["hu", "n"]);
    let ter = cat(&["te", "r2"]);
    let tail = cat(&["Xy", "z9"]);
    let full = cat(&["Hun", "ter2", "Xyz9"]);
    let head = cat(&["Hun", "ter2"]);
    let glued = cat(&[&hun, &ter, &tail]);
    let first = cat(&["Fir", "st1", "Secret"]);
    let second = cat(&["Sec", "ond2", "Secret"]);
    let spaced = cat(&[&hun, " ", &ter]);
    vec![
        shape(
            "single-quoted credential with an escaped quote",
            format!("curl -u 'admin:{hun}'\\''{ter}{tail}' https://h/x"),
            &[&hun, &ter, &tail, &glued],
        ),
        shape(
            "double-quoted credential with a backslash-escaped quote",
            format!("curl -u \"admin:{hun}\\\"{ter}{tail}\" https://h/x"),
            &[&hun, &ter, &tail, &glued],
        ),
        shape(
            "space in a quoted user part",
            format!("curl -u 'ad min:{spaced}' https://h/x"),
            &[&spaced, &hun, &ter],
        ),
        shape(
            "double-quoted user, bare password",
            format!("curl -u \"admin\":{full} https://h/x"),
            &[&full, &head, &tail],
        ),
        shape(
            "single-quoted user, bare password, end of line",
            format!("curl -u 'admin':{full}"),
            &[&full, &head, &tail],
        ),
        shape(
            "double-quoted user and password",
            format!("curl -u \"admin\":\"{full}\""),
            &[&full, &head, &tail],
        ),
        shape(
            "--user with a spaced quoted user and a quoted spaced password",
            format!("curl --user \"ad min\":'{spaced}'"),
            &[&spaced, &hun, &ter],
        ),
        shape(
            "bare password holding a quote",
            format!("curl -u admin:{hun}'{ter}{tail}"),
            &[&hun, &ter, &tail],
        ),
        shape(
            "a quote glued after the closing quote",
            format!("curl -u 'admin:{hun}{ter}'\"{tail}\""),
            &[&hun, &ter, &tail],
        ),
        shape(
            "unterminated quote",
            format!("curl -u 'admin:{hun} {ter}{tail}"),
            &[&hun, &ter, &tail],
        ),
        shape(
            "unterminated double quote",
            format!("curl -u \"admin:{hun} {ter}{tail}"),
            &[&hun, &ter, &tail],
        ),
        shape(
            "two -u in one command",
            format!("curl -u a1:{first} -u b2:{second} https://h/x"),
            &[&first, &second],
        ),
        shape(
            "two -u, the second one quoted",
            format!("curl -u a1:{first} --user 'b2:{second}' https://h/x"),
            &[&first, &second],
        ),
        shape(
            "combined short flags",
            format!("curl -su admin:{full} https://h/x"),
            &[&full, &head, &tail],
        ),
        shape(
            "attached credentials",
            format!("curl -uadmin:{full} https://h/x"),
            &[&full, &head, &tail],
        ),
        shape(
            "--user= form",
            format!("curl --user=admin:{full} https://h/x"),
            &[&full, &head, &tail],
        ),
    ]
}

/// `curl` lines that carry no password (curl prompts for it, or there is no
/// credential at all) and must come back untouched.
pub fn curl_without_password_lines() -> Vec<&'static str> {
    vec![
        "curl -u 'admin' https://example.com/x",
        "curl -u admin https://example.com",
        "curl https://example.com/a:b",
    ]
}

/// `shape` with a hidden separator in the place of the first space after
/// `curl` (so it stands before the flag).
pub fn with_filler_before_the_flag(shape: &Shape, label: &str, f: &str) -> Shape {
    Shape {
        name: format!("{} with {label} before the flag", shape.name),
        line: shape.line.replacen("curl ", &format!("curl{f}"), 1),
        secrets: shape.secrets.clone(),
    }
}

// ───────────────────── separator filler plus in-secret filler ────────────────
//
// One line can hold hidden text in two roles: one run standing where a blank
// would be (`curl<ZWSP>-u`) and another inside the secret
// (`admin:QWKZ<ZWSP>XBNM`). Neither reading alone ("every run is a space",
// "no run is anything") finds the credential, so each template below is run
// with the separator filler in every slot that could hold one, crossed with the
// filler inside the secret at several places.

/// Fillers that sit inside a secret: (name, text).
pub fn secret_fillers() -> Vec<(String, String)> {
    vec![
        ("ZWSP".into(), "\u{200b}".into()),
        ("ZWJ".into(), "\u{200d}".into()),
        ("a soft hyphen".into(), "\u{ad}".into()),
        ("a BOM".into(), "\u{feff}".into()),
        (
            "a run of mixed filler".into(),
            "\u{200b}\u{2060}\u{ad}\u{200c}".into(),
        ),
    ]
}

/// A command with its places marked: `\x01` is a blank (a separator filler can
/// stand in for it), `\x02` is a place where no blank is written but a hidden
/// separator could still sit (between user and colon, after `=`), `\x03` is the
/// secret.
struct Template {
    name: &'static str,
    pattern: &'static str,
    secret_len: usize,
}

const BLANK: char = '\x01';
const NOTHING: char = '\x02';
const SECRET: char = '\x03';

fn templates() -> Vec<Template> {
    let t = |name, pattern, secret_len| Template {
        name,
        pattern,
        secret_len,
    };
    vec![
        t(
            "curl -u",
            "curl\x01-u\x01admin\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl --user",
            "curl\x01--user\x01admin\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl --proxy-user",
            "curl\x01--proxy-user\x01ops\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl -su",
            "curl\x01-su\x01admin\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl --user=",
            "curl\x01--user=\x02admin\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl -u with a double-quoted user",
            "curl\x01-u\x01\"admin\"\x02:\x02\x03 https://h/x",
            12,
        ),
        t(
            "curl -u with a single-quoted user",
            "curl\x01-u\x01'admin'\x02:\x02\x03 https://h/x",
            12,
        ),
        t("--password", "tool\x01--password\x01\x03 run", 12),
        t("--token", "tool\x01--token\x01\x03 run", 12),
        t("Bearer", "sent\x01Bearer\x01\x03 ok", 24),
        t(
            "Authorization: Basic",
            "Authorization:\x01Basic\x01\x03==",
            20,
        ),
        t("mysql -p", "mysql\x01-u root\x01-p\x03 appdb", 10),
        t("sshpass -p", "sshpass\x01-p\x01\x03 ssh deploy@host", 10),
        t(
            "docker login -p",
            "docker\x01login\x01-u user\x01-p\x01\x03",
            12,
        ),
        t("redis-cli -a", "redis-cli\x01-a\x01\x03", 12),
        t("unzip -P", "unzip\x01-P\x01\x03 a.zip", 10),
        t("ldapsearch -w", "ldapsearch\x01-w\x01\x03 -b dc=x", 10),
        t("7z -p", "7z\x01-p\x03 x a.7z", 10),
        t("export NAME=", "export\x01PASSWORD=\x02\x03", 12),
    ]
}

/// Where the filler inside the secret goes (char offsets into the secret).
fn secret_filler_places(len: usize) -> Vec<(&'static str, Vec<usize>)> {
    vec![
        ("after two characters", vec![2]),
        ("in the middle", vec![len / 2]),
        ("near the end", vec![len - 2]),
        ("three runs", vec![2, len / 2, len - 2]),
    ]
}

fn splice_at(secret: &str, places: &[usize], f: &str) -> String {
    let mut out = String::new();
    for (i, c) in secret.chars().enumerate() {
        if places.contains(&i) {
            out.push_str(f);
        }
        out.push(c);
    }
    out
}

/// Every template with the separator filler `sep` in each slot that can hold
/// one (and in all of them at once) and the filler `inner` inside the secret at
/// each place. The secrets are the whole secret and every tail that starts at
/// the filler (the tail is the part a half-done fix leaks), except a tail that
/// the command's own text already contains.
pub fn separator_and_secret_filler_shapes(
    sep_label: &str,
    sep: &str,
    inner_label: &str,
    inner: &str,
) -> Vec<Shape> {
    let mut out = Vec::new();
    for (index, t) in templates().iter().enumerate() {
        let secret = consonants(900 + index as u64, t.secret_len);
        let slots = t
            .pattern
            .chars()
            .filter(|c| *c == BLANK || *c == NOTHING)
            .count();
        let skeleton: String = reader_view(
            &t.pattern
                .chars()
                .filter(|c| *c != SECRET && *c != NOTHING)
                .map(|c| if c == BLANK { ' ' } else { c })
                .collect::<String>(),
        );
        for chosen in 0..=slots {
            for (place_name, places) in secret_filler_places(t.secret_len) {
                let in_secret = splice_at(&secret, &places, inner);
                let mut line = String::new();
                let mut slot = 0;
                for c in t.pattern.chars() {
                    match c {
                        BLANK | NOTHING => {
                            if chosen == slots || chosen == slot {
                                line.push_str(sep);
                            } else if c == BLANK {
                                line.push(' ');
                            }
                            slot += 1;
                        }
                        SECRET => line.push_str(&in_secret),
                        other => line.push(other),
                    }
                }
                let mut secrets = vec![secret.clone()];
                for &at in &places {
                    let tail: String = secret.chars().skip(at).collect();
                    if !skeleton.contains(&tail) && !secrets.contains(&tail) {
                        secrets.push(tail);
                    }
                }
                let which = if chosen == slots {
                    "every slot".to_string()
                } else {
                    format!("slot {chosen}")
                };
                out.push(Shape {
                    name: format!(
                        "{}: {sep_label} in {which}, {inner_label} {place_name} of the secret",
                        t.name
                    ),
                    line,
                    secrets,
                });
            }
        }
    }
    out
}

/// A deterministic sample of about one shape in `one_in`, chosen by the text of
/// the shape (so the choice survives reordering).
pub fn sample(all: Vec<Shape>, one_in: u64) -> Vec<Shape> {
    all.into_iter()
        .filter(|s| {
            let mut h: u64 = 0xcbf2_9ce4_8422_2325;
            for b in s.name.bytes().chain(s.line.bytes()) {
                h = (h ^ b as u64).wrapping_mul(0x0100_0000_01b3);
            }
            (h >> 17).is_multiple_of(one_in)
        })
        .collect()
}

/// The four lines the review named: a hidden character as the separator and
/// another inside the secret.
pub fn two_filler_role_examples(f: &str) -> Vec<Shape> {
    let pw = consonants(801, 12);
    let (head, tail) = pw.split_at(4);
    let user_pw = consonants(802, 8);
    let (uhead, utail) = user_pw.split_at(3);
    vec![
        shape(
            "curl, filler before -u and inside the password",
            format!("curl{f}-u admin:{head}{f}{tail} https://h/x"),
            &[&pw, tail],
        ),
        shape(
            "--password, filler before the value and inside it",
            format!("tool{f}--password {head}{f}{tail} run"),
            &[&pw, tail],
        ),
        shape(
            "--proxy-user, filler before the user and inside the password",
            format!("curl --proxy-user{f}admin:{head}{f}{tail} https://h/x"),
            &[&pw, tail],
        ),
        shape(
            "quoted user, filler before the colon and inside the password",
            format!("curl{f}-u \"admin\"{f}:{uhead}{f}{utail}"),
            &[&user_pw, utail],
        ),
        shape(
            "filler before -u, before the colon and inside the password",
            format!("curl{f}-u admin{f}:{head}{f}{tail} https://h/x"),
            &[&pw, tail],
        ),
    ]
}

/// Ordinary commands with `sep` standing where a blank would be and `inner`
/// inside a word. No secret: they come back as they are, minus the filler.
pub fn ordinary_two_role_filler_lines(sep: &str, inner: &str) -> Vec<String> {
    vec![
        format!("curl{sep}-X GET https://exam{inner}ple.com"),
        format!("curl{sep}-u admin https://ex{inner}ample.com"),
        format!("curl{sep}-u 'admin' https://exam{inner}ple.com/x"),
        format!("curl{sep}https://exam{inner}ple.com/a:b"),
        format!("mkdir{sep}-p out/di{inner}r"),
        format!("ssh{sep}-p 22 deploy@ho{inner}st"),
        format!("export{sep}PATH=/usr/b{inner}in:/bin"),
        format!("docker{sep}login -u us{inner}er"),
    ]
}

/// Lines whose credential has hidden runs past the ninth on the line: nine
/// hidden runs of `f` come first, then the credential with `f` inside the
/// secret (the separator in front of the flag is a plain blank).
pub fn credential_after_many_hidden_runs(f: &str) -> Vec<Shape> {
    let pw = consonants(811, 12);
    let (head, tail) = pw.split_at(5);
    let bearer = consonants(812, 24);
    let (bhead, btail) = bearer.split_at(9);
    let flood = format!("a{f}b{f}c{f}d{f}e{f}f{f}g{f}h{f}i{f}j ");
    vec![
        shape(
            "curl -u after nine hidden runs",
            format!("{flood}curl -u admin:{head}{f}{tail} https://h/x"),
            &[&pw, tail],
        ),
        shape(
            "--password after nine hidden runs",
            format!("{flood}tool --password {head}{f}{tail} run"),
            &[&pw, tail],
        ),
        shape(
            "Bearer after nine hidden runs",
            format!("{flood}sent Bearer {bhead}{f}{btail} ok"),
            &[&bearer, btail],
        ),
        shape(
            "export after nine hidden runs",
            format!("{flood}export PASSWORD={head}{f}{tail}"),
            &[&pw, tail],
        ),
    ]
}

/// Like [`credential_after_many_hidden_runs`] but the separator in front of the
/// flag is hidden text too, so it is past the eighth run as well.
pub fn separator_after_many_hidden_runs(f: &str) -> Vec<Shape> {
    let pw = consonants(821, 12);
    let (head, tail) = pw.split_at(5);
    let flood = format!("a{f}b{f}c{f}d{f}e{f}f{f}g{f}h{f}i{f}j ");
    vec![
        shape(
            "curl, hidden separator and hidden secret filler after nine runs",
            format!("{flood}curl{f}-u admin:{head}{f}{tail} https://h/x"),
            &[&pw, tail],
        ),
        shape(
            "--password, hidden separator and hidden secret filler after nine runs",
            format!("{flood}tool{f}--password{f}{head}{f}{tail} run"),
            &[&pw, tail],
        ),
    ]
}

// ───────────────────────── curl escapes and metacharacters ───────────────────

/// `curl -u` passwords with a backslash-escaped blank, in a bare word.
pub fn curl_escaped_blank_shapes() -> Vec<Shape> {
    let a = consonants(711, 6);
    let b = consonants(712, 6);
    let c = consonants(713, 6);
    let pw = consonants(714, 12);
    vec![
        shape(
            "escaped blank in a bare password",
            format!("curl -u admin:{a}\\ {b} https://h/x"),
            &[&a, &b],
        ),
        shape(
            "two escaped blanks in a bare password",
            format!("curl -u admin:{a}\\ {b}\\ {c} https://h/x"),
            &[&a, &b, &c],
        ),
        shape(
            "escaped blank in a bare password, --user",
            format!("curl --user admin:{a}\\ {b} https://h/x"),
            &[&a, &b],
        ),
        shape(
            "escaped blank in a bare password, end of line",
            format!("curl -u admin:{a}\\ {b}"),
            &[&a, &b],
        ),
        shape(
            "escaped blank in a bare password, glued -u",
            format!("curl -uadmin:{a}\\ {b} https://h/x"),
            &[&a, &b],
        ),
        shape(
            "escaped blank in the user part",
            format!("curl -u ad\\ min:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "escaped blank in the user part and in the password",
            format!("curl -u ad\\ min:{a}\\ {b} https://h/x"),
            &[&a, &b],
        ),
        shape(
            "password ending in an escaped blank at the end of the line",
            format!("curl -u admin:{a}\\ "),
            &[&a],
        ),
        shape(
            "password ending in a backslash at the end of the line",
            format!("curl -u admin:{a}\\"),
            &[&a],
        ),
        shape(
            "three backslashes make the blank escaped again",
            format!("curl -u admin:{a}\\\\\\ {b} https://h/x"),
            &[&a, &b],
        ),
    ]
}

/// A password that ends in an even run of backslashes ends there: the blank
/// after it is real, so the rest of the command stays readable
/// ([`KEPT_AFTER_EVEN_BACKSLASHES`]).
pub const KEPT_AFTER_EVEN_BACKSLASHES: &str = " https://h/x";

pub fn curl_even_backslash_shapes() -> Vec<Shape> {
    let a = consonants(721, 12);
    vec![
        shape(
            "two backslashes before the blank",
            format!("curl -u admin:{a}\\\\ https://h/x"),
            &[&a],
        ),
        shape(
            "four backslashes before the blank",
            format!("curl -u admin:{a}\\\\\\\\ https://h/x"),
            &[&a],
        ),
        shape(
            "two backslashes before the blank, --user",
            format!("curl --user admin:{a}\\\\ https://h/x"),
            &[&a],
        ),
    ]
}

/// `curl` commands with `&`, `;` or `|` inside quotes (or escaped) before the
/// credential flag. The quoted text does not end the command.
pub fn curl_metacharacter_shapes() -> Vec<Shape> {
    let pw = consonants(731, 12);
    let user_pw = consonants(732, 12);
    let n = |what: &str| format!("{what} before the flag");
    vec![
        shape(
            n("single-quoted & in a URL"),
            format!("curl 'https://h/?a=1&b=2' -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("single-quoted ; in a header"),
            format!("curl -H 'X: a;b' -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("single-quoted | in a header"),
            format!("curl -H 'X: a|b' -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("double-quoted & in a URL, --user"),
            format!("curl \"https://h/?a=1&b=2\" --user admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("double-quoted ; in a header"),
            format!("curl -H \"X: a;b\" -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("double-quoted | in a URL"),
            format!("curl \"https://h/?a=1|b\" -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("double-quoted ; after an escaped quote"),
            format!("curl -H \"X: \\\"a;b\\\"\" -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("backslash-escaped ;"),
            format!("curl https://h/a\\;b -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("backslash-escaped & and |"),
            format!("curl https://h/a\\&b\\|c -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("two quoted headers"),
            format!("curl -H 'X: a;b' -H \"Y: c&d\" -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            n("single-quoted & in a URL, --user="),
            format!("curl 'https://h/?a=1&b=2' --user=admin:{user_pw}"),
            &[&user_pw],
        ),
        shape(
            n("single-quoted & in a URL, -u with a quoted credential"),
            format!("curl 'https://h/?a=1&b=2' -u 'admin:{pw}'"),
            &[&pw],
        ),
        shape(
            "single-quoted ; before the flag, with a URL after the credential",
            format!("curl -H 'X: a;b' -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "multi-line single-quoted JSON body before the flag",
            format!("curl -X POST -d '{{\n  \"a\": 1\n}}' -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "multi-line single-quoted JSON body holding ; & |, then the flag",
            format!(
                "curl -X POST -d '{{\n  \"a\": \"x;y\",\n  \"b\": \"p&q|r\"\n}}' --user admin:{pw}"
            ),
            &[&pw],
        ),
    ]
}

/// A `curl` that a real (unquoted) break ends, then another command whose own
/// `-u user:pw` is not curl's. Nothing here is a secret.
pub fn after_a_real_break_lines() -> Vec<String> {
    vec![
        "curl https://h/x; ls -u foo:bar".into(),
        "curl https://h/x | sort -u a:b".into(),
        "curl https://h/x && ls -u foo:bar".into(),
        "curl https://h/x & ls -u foo:bar".into(),
        "curl 'https://h/?a=1&b=2'; ls -u foo:bar".into(),
        "curl -H 'X: a;b' https://h/x | sort -u a:b".into(),
    ]
}

// ─────────────────────────── backslash continuation ──────────────────────────

/// One command over several rows (`\n` between rows) whose credential flag
/// starts a row or sits inside one. Each row on its own is harmless.
pub fn curl_continuation_shapes() -> Vec<Shape> {
    let pw = consonants(741, 12);
    vec![
        shape(
            "-u on the row after a trailing backslash",
            format!("curl \\\n  -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "--user on the row after a trailing backslash",
            format!("curl -s \\\n--user admin:{pw}"),
            &[&pw],
        ),
        shape(
            "three rows, the flag on the last",
            format!("curl -s \\\n  -H 'X: 1' \\\n  -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "three rows, --user= on the last",
            format!("curl https://h/x \\\n  -s \\\n  --user=admin:{pw}"),
            &[&pw],
        ),
        shape(
            "quoted credential on the continued row",
            format!("curl \\\n -u 'admin:{pw}'"),
            &[&pw],
        ),
        shape(
            "double-quoted user on the continued row",
            format!("curl \\\n -u \"admin\":{pw}"),
            &[&pw],
        ),
        shape(
            "blanks after the backslash",
            format!("curl \\  \n  -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "CRLF after the backslash",
            format!("curl \\\r\n  -u admin:{pw} https://h/x"),
            &[&pw],
        ),
    ]
}

/// Continuations where the VALUE is on the row after the flag or after a
/// password's trailing backslash.
pub fn curl_value_on_next_row_shapes() -> Vec<Shape> {
    let pw = consonants(751, 12);
    let a = consonants(752, 6);
    let b = consonants(753, 6);
    vec![
        shape(
            "the credential on the row after -u and a backslash",
            format!("curl -u \\\nadmin:{pw}"),
            &[&pw],
        ),
        shape(
            "the credential indented on the row after --user and a backslash",
            format!("curl -s --user \\\n   admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "the rest of a password on the row after its trailing backslash",
            format!("curl -u admin:{a}\\\n{b} https://h/x"),
            &[&a, &b],
        ),
    ]
}

// ───────────── review round 3: many hidden runs, rows with two readings, ─────────
// ───────────── quoting forms, clipped rows, long carried continuations ───────────

const ZWSP: &str = "\u{200b}";

/// A credential with hidden runs standing in different roles, with padding
/// (`a<ZWSP>` repeated 8, 12 and 20 times) BEFORE it and, separately, AFTER it.
/// The first eight and the last eight hidden runs of a line are read in every
/// combination, so the credential's own runs are always among them.
pub fn credential_among_many_hidden_runs_shapes() -> Vec<Shape> {
    let z = ZWSP;
    let pw = consonants(831, 12);
    let (h1, h2) = pw.split_at(6);
    let pw2 = consonants(832, 12);
    let user_form = format!("curl --user{z}ad{z}min:{h1}{z}{h2} https://h/x");
    let quoted_form = format!("curl{z}-u \"admin\"{z}:{pw2}");
    let mut out = Vec::new();
    for n in [8, 12, 20] {
        let pad = format!("a{z}").repeat(n);
        out.push(shape(
            format!("--user with hidden runs in the user and password, {n} hidden runs before"),
            format!("{pad} {user_form}"),
            &[&pw, h1, h2],
        ));
        out.push(shape(
            format!("--user with hidden runs in the user and password, {n} hidden runs after"),
            format!("{user_form} {pad}"),
            &[&pw, h1, h2],
        ));
    }
    for n in [8, 12] {
        let pad = format!("a{z}").repeat(n);
        out.push(shape(
            format!(
                "-u with a quoted user and a hidden run before the colon, {n} hidden runs before"
            ),
            format!("{pad} {quoted_form}"),
            &[&pw2],
        ));
        out.push(shape(
            format!(
                "-u with a quoted user and a hidden run before the colon, {n} hidden runs after"
            ),
            format!("{quoted_form} {pad}"),
            &[&pw2],
        ));
    }
    out
}

/// A continued `curl` command (rows joined with `\n`) with a hidden run on each
/// row, the two needing different readings: a separator on row one
/// (`curl<ZWSP>-u`) and a character of the user on row two (`ad<ZWSP>min`).
pub fn continued_curl_with_hidden_runs_on_both_rows() -> Vec<Shape> {
    let z = ZWSP;
    let pw = consonants(841, 12);
    vec![
        shape(
            "-u, separator on row one, user split on row two",
            format!("curl{z}-u \\\nad{z}min:{pw}"),
            &[&pw],
        ),
        shape(
            "--user, separators on row one, user split on row two",
            format!("curl{z}--user{z}\\\nadm{z}in:{pw}"),
            &[&pw],
        ),
        shape(
            "-u, separator on row one, user split on row two, URL after",
            format!("curl{z}-u \\\nad{z}min:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "--user, separators on row one, user split on row two, URL after",
            format!("curl{z}--user{z}\\\nadm{z}in:{pw} https://h/x"),
            &[&pw],
        ),
    ]
}

/// `$'...'` strings have backslash escapes (an escaped `'` does not close
/// them) and can hold `;`, `&` and `|`.
pub fn dollar_quote_shapes() -> Vec<Shape> {
    let pw = consonants(851, 12);
    vec![
        shape(
            "$'..' with an escaped quote and ; before -u",
            format!("curl $'a\\'b;c' -u admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "$'..' with an escaped quote and & before --user",
            format!("curl $'a\\'b&c' --user admin:{pw} https://h/x"),
            &[&pw],
        ),
        shape(
            "$'..' with an escaped quote and | before a quoted credential",
            format!("curl $'a\\'b|c' -u 'admin:{pw}'"),
            &[&pw],
        ),
        shape(
            "$'..' header with two escaped quotes around ;",
            format!("curl -H $'X: \\'a;b\\'' -u admin:{pw}"),
            &[&pw],
        ),
    ]
}

/// A password that goes on over a backslash at the end of the row, quoted or
/// not: the glued-together rows are one word, so neither half may be readable.
pub fn credential_continued_onto_the_next_row_shapes() -> Vec<Shape> {
    let pw = consonants(861, 12);
    let (h1, h2) = pw.split_at(6);
    vec![
        shape(
            "single-quoted credential, then a continuation, URL after",
            format!("curl -u 'admin:{h1}'\\\n{h2} https://h/x"),
            &[&pw, h1, h2],
        ),
        shape(
            "single-quoted credential, then a continuation, end of text",
            format!("curl -u 'admin:{h1}'\\\n{h2}"),
            &[&pw, h1, h2],
        ),
        shape(
            "unquoted password, then a continuation, URL after",
            format!("curl -u admin:{h1}\\\n{h2} https://h/x"),
            &[&pw, h1, h2],
        ),
        shape(
            "unquoted password, then a continuation, end of text",
            format!("curl -u admin:{h1}\\\n{h2}"),
            &[&pw, h1, h2],
        ),
    ]
}

/// Several continuations in a row between the flag and its value.
pub fn repeated_continuations_before_the_value_shapes() -> Vec<Shape> {
    let pw = consonants(871, 12);
    vec![
        shape(
            "a row of just a backslash between the flag and the value",
            format!("curl -u \\\n\\\nadmin:{pw}"),
            &[&pw],
        ),
        shape(
            "indented rows of just a backslash, the value indented",
            format!("curl -u \\\n  \\\n  admin:{pw}"),
            &[&pw],
        ),
        shape(
            "three backslash-only rows, --user, URL after",
            format!("curl --user \\\n\\\n  \\\n\\\nadmin:{pw} https://h/x"),
            &[&pw],
        ),
    ]
}

/// A double-quoted password that is never closed and whose row ends in a
/// backslash: the next row continues it.
pub fn unterminated_double_quote_continuation_shapes() -> Vec<Shape> {
    let pw = consonants(881, 12);
    let (h1, h2) = pw.split_at(6);
    vec![
        shape(
            "double-quoted password continued onto the row that closes it",
            format!("curl -u \"admin:{h1}\\\n{h2}\""),
            &[&pw, h1, h2],
        ),
        shape(
            "double-quoted password continued onto the row that closes it, URL after",
            format!("curl -u \"admin:{h1}\\\n{h2}\" https://h/x"),
            &[&pw, h1, h2],
        ),
    ]
}

/// A row that ends in the line assembler's clip mark `…` (written by hand: the
/// raw redactor never sees an assembler). The cut-off rest of the row may have
/// held the flag, so the next row is part of the command.
pub fn rows_ending_in_the_clip_mark_shapes() -> Vec<Shape> {
    let pw = consonants(891, 12);
    let long = "x".repeat(4090);
    vec![
        shape(
            "a short curl row ending in the clip mark",
            format!("curl https://h/x…\n-u admin:{pw}"),
            &[&pw],
        ),
        shape(
            "a curl row with an unclosed single quote and the clip mark",
            format!("curl -H 'hhhhhhhhhh…\n  -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            "a curl row of 4096 characters ending in the clip mark",
            format!("curl {long}…\n-u admin:{pw}"),
            &[&pw],
        ),
        shape(
            "a clipped curl row, the value on the row after -u",
            format!("curl -u …\nadmin:{pw}"),
            &[&pw],
        ),
    ]
}

/// Rows wider than the assembler allows, so IT clips the first one (4096
/// columns, ended with `…`). The text carries a trailing backslash after the
/// cut, which the clip drops; the row still continues the command.
pub fn rows_the_assembler_clips_shapes() -> Vec<Shape> {
    let pw = consonants(895, 12);
    let hs = "h".repeat(4200);
    let xs = "x".repeat(4200);
    vec![
        shape(
            "a clipped curl row with an unclosed quote, the flag on the next row",
            format!("curl -H '{hs}' \\\n  -u admin:{pw}"),
            &[&pw],
        ),
        shape(
            "a clipped curl row without a quote, the flag on the next row",
            format!("curl {xs} \\\n-u admin:{pw}"),
            &[&pw],
        ),
    ]
}

/// How many `e \` rows follow `curl \` in [`long_continued_curl_rows`].
pub const CARRIED_ROWS: usize = 3000;

/// The rows of a `curl` command that goes on for thousands of rows, each ending
/// in a backslash: `curl \` and then `e \` repeated.
pub fn long_continued_curl_rows() -> Vec<String> {
    let mut rows = vec!["curl \\".to_string()];
    rows.extend((0..CARRIED_ROWS).map(|_| "e \\".to_string()));
    rows
}

/// The rows as one text, with or without a newline after the last one.
pub fn long_continued_curl_text(trailing_newline: bool) -> String {
    let mut text = long_continued_curl_rows().join("\n");
    if trailing_newline {
        text.push('\n');
    }
    text
}

/// What arrives in the next delivery after [`long_continued_curl_rows`]: the
/// flag and its credential.
pub fn credential_after_a_long_continued_curl() -> Shape {
    let pw = consonants(899, 12);
    shape(
        "-u on the first row after thousands of continued rows",
        format!("-u admin:{pw}"),
        &[&pw],
    )
}

/// Multi-row texts (rows joined with `\n`) that hold no credential: `curl`
/// appears, then a quote with no mate or a `-u` of another command. They must
/// come back unchanged with nothing redacted.
pub fn curl_lookalike_negative_texts() -> Vec<(&'static str, String)> {
    vec![
        (
            "a curl error message, then a docker command",
            "curl: (7) Failed to connect to localhost port 80 after 0 ms: Couldn't connect to server\n$ docker run -u 1000:1000 nginx"
                .to_string(),
        ),
        (
            "a sentence with an apostrophe after curl, then ls -u",
            "curl isn't installed\nls -u foo:bar".to_string(),
        ),
    ]
}

/// `curl` and a double quote with no mate anywhere, then other commands. The
/// quote is an ordinary character, so the rows after it are not curl's.
pub fn unmatched_quote_negative_text() -> String {
    "curl \"https://h/x\nls\ndocker run -u 1000:1000 nginx".to_string()
}
