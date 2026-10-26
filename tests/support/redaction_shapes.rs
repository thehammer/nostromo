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
