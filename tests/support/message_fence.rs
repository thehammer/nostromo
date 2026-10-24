//! A strict, positional reader for the untrusted-data fence the daemon puts in
//! front of an agent (the focus seed) or Mother (the plan): shared by the
//! integration tests (`#[path]` include).
//!
//! It knows nothing about how the text is produced. It reads the message the
//! way the receiving agent does: the real fence is the one pair of marker
//! lines `<<<UNTRUSTED-{nonce}>>>` / `<<<END-UNTRUSTED-{nonce}>>>` that stand on
//! their own, and anything that is not between them is the daemon's own words.
//! It fails when there is not exactly one such pair, when the pair is not in
//! order, when a marker with any other nonce (or any `<<<` / `>>>` at all)
//! shows up inside the fence or after it, or when the nonce leaks into the
//! fenced text.
//!
//! Tests then assert on WHERE a piece of text is: `inside`, `before` or
//! `after`. `contains("hostile")` on the whole message proves nothing and is
//! not what these helpers are for.

const BEGIN: &str = "<<<UNTRUSTED-";
const END: &str = "<<<END-UNTRUSTED-";

/// A message cut at its one real fence.
#[derive(Debug, Clone)]
pub struct Split {
    /// The nonce both markers carry.
    pub nonce: String,
    /// Everything in front of the begin marker line (the daemon's own words:
    /// the user's instruction, the notice, a brief's config and headings).
    pub before: String,
    /// The lines strictly between the two markers.
    pub inside: String,
    /// Everything after the end marker line.
    pub after: String,
}

impl Split {
    /// What is not inside the fence: `before` then `after`.
    pub fn outside(&self) -> String {
        format!("{}\n{}", self.before, self.after)
    }
}

/// `text` as lines, the way CommonMark ends them: `\r\n`, `\n` and a lone `\r`.
pub fn lines(text: &str) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < bytes.len() {
        match bytes[i] {
            b'\n' => {
                out.push(&text[start..i]);
                i += 1;
                start = i;
            }
            b'\r' => {
                out.push(&text[start..i]);
                i += if bytes.get(i + 1) == Some(&b'\n') {
                    2
                } else {
                    1
                };
                start = i;
            }
            _ => i += 1,
        }
    }
    if start < bytes.len() {
        out.push(&text[start..]);
    }
    out
}

fn clip(text: &str) -> String {
    if text.chars().count() <= 2500 {
        text.to_owned()
    } else {
        format!(
            "{}... [{} chars]",
            text.chars().take(2500).collect::<String>(),
            text.chars().count()
        )
    }
}

/// Cut `text` at its one real fence, or fail saying what is wrong with it.
pub fn split(what: &str, text: &str) -> Split {
    let all = lines(text);
    let nonce_of = |line: &str, prefix: &str| {
        line.strip_prefix(prefix)
            .and_then(|r| r.strip_suffix(">>>"))
            .map(str::to_owned)
    };
    let begins: Vec<(usize, String)> = all
        .iter()
        .enumerate()
        .filter_map(|(i, l)| nonce_of(l, BEGIN).map(|n| (i, n)))
        .collect();
    let ends: Vec<(usize, String)> = all
        .iter()
        .enumerate()
        .filter_map(|(i, l)| nonce_of(l, END).map(|n| (i, n)))
        .collect();
    assert_eq!(
        begins.len(),
        1,
        "{what}: expected exactly one begin-marker line, got {begins:?}:\n{}",
        clip(text)
    );
    assert_eq!(
        ends.len(),
        1,
        "{what}: expected exactly one end-marker line, got {ends:?}:\n{}",
        clip(text)
    );
    let ((b, nonce), (e, end_nonce)) = (
        begins.into_iter().next().unwrap(),
        ends.into_iter().next().unwrap(),
    );
    assert_eq!(
        nonce,
        end_nonce,
        "{what}: the two markers carry different nonces:\n{}",
        clip(text)
    );
    assert!(
        nonce.len() >= 8 && nonce.chars().all(|c| c.is_ascii_alphanumeric()),
        "{what}: the nonce must be an unguessable token, got {nonce:?}"
    );
    assert!(
        b < e,
        "{what}: the end marker comes before the begin marker:\n{}",
        clip(text)
    );

    let before = all[..b].join("\n");
    let inside = all[b + 1..e].join("\n");
    let after = all[e + 1..].join("\n");

    // Nothing inside or after may look like a marker, and the nonce is not text
    // anyone could have written into the item.
    for (part_name, part) in [("inside the fence", &inside), ("after the fence", &after)] {
        assert!(
            !part.contains("<<<") && !part.contains(">>>"),
            "{what}: a marker delimiter survived {part_name}:\n{}",
            clip(part)
        );
        assert!(
            !part.contains(&nonce),
            "{what}: the nonce leaked {part_name}"
        );
    }
    // In front of the fence the notice may name the markers, but only with the real nonce.
    let mut rest = before.as_str();
    while let Some(at) = rest.find("<<<") {
        let tail = &rest[at + 3..];
        let real_begin = format!("UNTRUSTED-{nonce}>>>");
        let real_end = format!("END-UNTRUSTED-{nonce}>>>");
        assert!(
            tail.starts_with(&real_begin) || tail.starts_with(&real_end),
            "{what}: a marker with some other nonce stands in front of the fence: {:?}",
            clip(&rest[at..rest.len().min(at + 80)])
        );
        rest = tail;
    }
    Split {
        nonce,
        before,
        inside,
        after,
    }
}

/// Every byte offset of `needle` in `haystack`.
pub fn offsets(haystack: &str, needle: &str) -> Vec<usize> {
    haystack.match_indices(needle).map(|(i, _)| i).collect()
}

/// Assert each of `tokens` is inside the fence (at least once) and nowhere
/// outside it. Positional: both halves must hold.
pub fn assert_only_inside(what: &str, s: &Split, tokens: &[&str]) {
    for token in tokens {
        assert!(
            s.inside.contains(token),
            "{what}: `{token}` should be inside the fence, which holds:\n{}",
            clip(&s.inside)
        );
        assert!(
            !s.before.contains(token),
            "{what}: `{token}` is in front of the fence:\n{}",
            clip(&s.before)
        );
        assert!(
            !s.after.contains(token),
            "{what}: `{token}` is after the fence:\n{}",
            clip(&s.after)
        );
    }
}

/// Assert none of `tokens` is anywhere outside the fence.
pub fn assert_not_outside(what: &str, s: &Split, tokens: &[&str]) {
    for token in tokens {
        assert!(
            !s.before.contains(token),
            "{what}: `{token}` is in front of the fence:\n{}",
            clip(&s.before)
        );
        assert!(
            !s.after.contains(token),
            "{what}: `{token}` is after the fence:\n{}",
            clip(&s.after)
        );
    }
}
