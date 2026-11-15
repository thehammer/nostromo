//! Jira ticket-key detection for queue rows.
//!
//! Pure text in, keys out. PR titles, branch names and bodies are untrusted and
//! can quote PHI, so nothing but the detected keys leaves this module: the body
//! is scanned (first [`BODY_SCAN_LIMIT`] bytes only) and dropped, never stored,
//! logged or sent.
//!
//! A key is a whole-word `[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,9}` (prefix of 2-10
//! characters, at most [`MAX_DIGITS`] digits), case-sensitive, found in the title, then the branch, then the
//! body, first appearance wins the order, at most [`MAX_KEYS`] returned.
//! Prefixes that are never tickets (`UTF-8`, `SHA-256`, `CVE-2025-1234` ...) are
//! always dropped; a [`ProjectFilter::Known`] list further keeps only the
//! site's own projects.

use std::collections::HashSet;
use std::sync::{Arc, RwLock};

/// The most keys one PR carries.
pub const MAX_KEYS: usize = 5;

/// How much of a PR body is scanned.
pub const BODY_SCAN_LIMIT: usize = 64 * 1024;

/// The most digits a key's number has (a longer one is not a key).
pub const MAX_DIGITS: usize = 10;

/// Prefixes that look like project keys but never are.
const NEVER_A_TICKET: &[&str] = &[
    "UTF", "SHA", "ISO", "CVE", "GPT", "RFC", "HTTP", "TLS", "SSL", "AES", "RSA", "MD", "PEP",
    "ECMA", "IEEE", "WCAG", "CWE", "GHSA", "LTS", "UTC", "GMT", "ARM", "COVID", "SARS", "HTTPS",
    "TCP", "UDP", "IPV", "WPA", "BCP",
];

/// Whether `prefix` is a deny-listed word, alone or with digits after it
/// (`SHA3`, `MD5`, `UTF16`, `HTTP2`).
fn never_a_ticket(prefix: &str) -> bool {
    let word = prefix.trim_end_matches(|c: char| c.is_ascii_digit());
    NEVER_A_TICKET.contains(&word)
}

/// Whether `key` is shaped like a ticket key: `[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,9}`.
pub fn is_valid_key(key: &str) -> bool {
    let Some((prefix, number)) = key.split_once('-') else {
        return false;
    };
    let p = prefix.as_bytes();
    (2..=10).contains(&p.len())
        && p[0].is_ascii_uppercase()
        && p.iter()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        && (1..=MAX_DIGITS).contains(&number.len())
        && number.as_bytes()[0] != b'0'
        && number.bytes().all(|b| b.is_ascii_digit())
}

/// Untrusted keys (from the wire): well-formed ones only, first appearance
/// wins, at most [`MAX_KEYS`].
pub fn sanitize_keys<I, S>(keys: I) -> Vec<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut out: Vec<String> = Vec::new();
    for k in keys {
        let k = k.as_ref();
        if is_valid_key(k) && !out.iter().any(|o| o == k) {
            out.push(k.to_owned());
            if out.len() == MAX_KEYS {
                break;
            }
        }
    }
    out
}

/// What is known about the Jira site's project list.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ProjectFilter {
    /// Never fetched and no cached copy.
    #[default]
    Unknown,
    /// The site's project keys.
    Known(HashSet<String>),
}

/// A key found in a PR body, with the host of the `/browse/` link it sat in
/// (lowercased), if it was inside one. The body itself is not kept.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BodyKey {
    pub key: String,
    pub link_host: Option<String>,
}

/// The site and project list detection runs against. Cheap to clone; the
/// project list is shared, so a refresh is seen by every holder.
#[derive(Debug, Clone, Default)]
pub struct TicketScope {
    site: Option<String>,
    projects: Arc<RwLock<ProjectFilter>>,
}

impl TicketScope {
    pub fn new(site: Option<String>, projects: Arc<RwLock<ProjectFilter>>) -> Self {
        Self { site, projects }
    }

    /// Detection scope with a fixed project filter (tests, no refresh).
    pub fn fixed(site: Option<String>, filter: ProjectFilter) -> Self {
        Self::new(site, Arc::new(RwLock::new(filter)))
    }

    /// Detect keys for one PR. Empty when no Jira site is configured.
    pub fn resolve(&self, title: &str, branch: &str, body_keys: &[BodyKey]) -> Vec<String> {
        let Some(site) = self.site.as_deref() else {
            return Vec::new();
        };
        let projects = self.projects.read().unwrap_or_else(|e| e.into_inner());
        resolve(title, Some(branch), body_keys, site, &projects)
    }
}

/// Detect ticket keys. At most [`MAX_KEYS`], in title, branch, body order.
pub fn detect(
    title: &str,
    branch: Option<&str>,
    body: Option<&str>,
    site: &str,
    projects: &ProjectFilter,
) -> Vec<String> {
    let body_keys = body.map(scan_body).unwrap_or_default();
    resolve(title, branch, &body_keys, site, projects)
}

/// [`detect`] over an already-scanned body.
pub fn resolve(
    title: &str,
    branch: Option<&str>,
    body_keys: &[BodyKey],
    site: &str,
    projects: &ProjectFilter,
) -> Vec<String> {
    let site = site.to_ascii_lowercase();
    let mut found: Vec<String> = Vec::new();
    let mut push = |key: &str| {
        let allowed = match projects {
            ProjectFilter::Known(set) => set.contains(prefix_of(key)),
            ProjectFilter::Unknown => true,
        };
        if allowed && !found.iter().any(|k| k == key) {
            found.push(key.to_owned());
        }
    };

    for (key, _) in scan(title, false) {
        push(&key);
    }
    if let Some(branch) = branch {
        for (key, _) in scan(branch, true) {
            push(&key);
        }
    }
    for bk in body_keys {
        let linked = bk.link_host.as_deref() == Some(site.as_str());
        if matches!(projects, ProjectFilter::Unknown) && !linked {
            continue;
        }
        push(&bk.key);
    }
    found.truncate(MAX_KEYS);
    found
}

/// Scan a PR body (first [`BODY_SCAN_LIMIT`] bytes) for keys, remembering the
/// host of an enclosing `/browse/` link. Only keys leave this function.
pub fn scan_body(body: &str) -> Vec<BodyKey> {
    let mut end = body.len().min(BODY_SCAN_LIMIT);
    while !body.is_char_boundary(end) {
        end -= 1;
    }
    let text = &body[..end];
    // Every distinct key is kept (the 64 KB limit bounds how many there can
    // be): the project filter runs later, and the cap applies after it, so junk
    // keys cannot crowd real ones out.
    let mut out: Vec<BodyKey> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for (key, start) in scan(text, false) {
        let link_host = link_host_before(text, start);
        if let Some(&at) = index.get(&key) {
            // A later link occurrence upgrades a plain one.
            if out[at].link_host.is_none() {
                out[at].link_host = link_host;
            }
        } else {
            index.insert(key.clone(), out.len());
            out.push(BodyKey { key, link_host });
        }
    }
    out
}

fn prefix_of(key: &str) -> &str {
    key.split_once('-').map_or(key, |(p, _)| p)
}

/// A word byte. In a branch name `_` separates words (`feature/CORE-12_fix`).
fn is_word(b: u8, underscore_separates: bool) -> bool {
    b.is_ascii_alphanumeric() || (b == b'_' && !underscore_separates)
}

/// Every whole-word key in `text` with its byte offset, deny-listed prefixes
/// removed, duplicates kept (callers dedupe).
fn scan(text: &str, branch: bool) -> Vec<(String, usize)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if !b[i].is_ascii_uppercase() || (i > 0 && is_word(b[i - 1], branch)) {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < b.len() && (b[j].is_ascii_uppercase() || b[j].is_ascii_digit()) {
            j += 1;
        }
        let prefix_len = j - i;
        let digits_start = j + 1;
        if (2..=10).contains(&prefix_len)
            && b.get(j) == Some(&b'-')
            && b.get(digits_start)
                .is_some_and(|d| (b'1'..=b'9').contains(d))
        {
            let mut k = digits_start;
            while k < b.len() && b[k].is_ascii_digit() {
                k += 1;
            }
            if !b.get(k).is_some_and(|c| is_word(*c, branch)) {
                let prefix = &text[i..j];
                if k - digits_start <= MAX_DIGITS && !never_a_ticket(prefix) {
                    out.push((text[i..k].to_owned(), i));
                }
                i = k;
                continue;
            }
        }
        // Skip the rest of this word so `ABC-` inside `XABC-1` can't restart.
        i = j.max(i + 1);
    }
    out
}

/// The host of the `https://<host>/browse/` that ends right before `start`.
fn link_host_before(text: &str, start: usize) -> Option<String> {
    let before = text[..start].strip_suffix("/browse/")?;
    let host_len = before
        .bytes()
        .rev()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == b'.' || *c == b'-')
        .count();
    let (head, host) = before.split_at(before.len() - host_len);
    if host.is_empty() || !head.ends_with("://") {
        return None;
    }
    Some(host.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SITE: &str = "carefeed.atlassian.net";

    fn known(keys: &[&str]) -> ProjectFilter {
        ProjectFilter::Known(keys.iter().map(|s| (*s).to_owned()).collect())
    }

    fn all() -> ProjectFilter {
        known(&["CORE", "PAYM", "INT", "APP", "UTF", "SHA", "CVE", "X"])
    }

    fn d(title: &str, branch: Option<&str>, body: Option<&str>, f: &ProjectFilter) -> Vec<String> {
        detect(title, branch, body, SITE, f)
    }

    #[test]
    fn title_key() {
        assert_eq!(d("CORE-2841 Fix dedupe", None, None, &all()), ["CORE-2841"]);
    }

    #[test]
    fn branch_key_when_title_has_none() {
        assert_eq!(
            d("Fix refunds", Some("feature/PAYM-77-refunds"), None, &all()),
            ["PAYM-77"]
        );
    }

    #[test]
    fn body_browse_link_key() {
        let body = format!("See https://{SITE}/browse/INT-9 for details");
        assert_eq!(d("Fix", None, Some(&body), &all()), ["INT-9"]);
    }

    #[test]
    fn title_first_then_body_order_and_dedupe() {
        assert_eq!(
            d("CORE-1", None, Some("CORE-1, CORE-2, APP-3"), &all()),
            ["CORE-1", "CORE-2", "APP-3"]
        );
    }

    #[test]
    fn never_a_ticket_prefixes_are_dropped_even_if_listed_by_the_site() {
        for t in [
            "UTF-8",
            "SHA-256",
            "ISO-8601",
            "CVE-2025-1234",
            "GPT-4",
            "RFC-7231",
            "X-123",
        ] {
            assert!(d(t, None, None, &all()).is_empty(), "{t}");
            assert!(d(t, None, None, &ProjectFilter::Unknown).is_empty(), "{t}");
        }
    }

    #[test]
    fn prefix_not_on_the_site_is_dropped() {
        assert!(d("ZZZZ-12 thing", None, None, &known(&["CORE"])).is_empty());
    }

    #[test]
    fn lowercase_and_glued_words_are_not_keys() {
        assert!(d("core-12", Some("feature/core-12"), None, &all()).is_empty());
        assert!(d("xCORE-12 CORE-12x CORE_1", None, None, &all()).is_empty());
        assert!(d("CORE-0", None, None, &all()).is_empty());
    }

    #[test]
    fn at_most_five_keys() {
        let t = "CORE-1 CORE-2 CORE-3 CORE-4 CORE-5 CORE-6 CORE-7";
        assert_eq!(
            d(t, None, None, &all()),
            ["CORE-1", "CORE-2", "CORE-3", "CORE-4", "CORE-5"]
        );
    }

    #[test]
    fn body_is_scanned_only_to_64kb() {
        let mut body = "a ".repeat(BODY_SCAN_LIMIT / 2);
        body.push_str(" CORE-9");
        assert!(d("t", None, Some(&body), &all()).is_empty());
        let inside = format!("CORE-9 {}", "a".repeat(2 * 1024 * 1024));
        assert_eq!(d("t", None, Some(&inside), &all()), ["CORE-9"]);
    }

    #[test]
    fn unknown_filter_drops_bare_body_keys_but_keeps_site_links() {
        let u = ProjectFilter::Unknown;
        assert!(d("t", None, Some("mentions CORE-5"), &u).is_empty());
        let linked = format!("https://{SITE}/browse/CORE-5");
        assert_eq!(d("t", None, Some(&linked), &u), ["CORE-5"]);
        // A link to some other host is just text.
        assert!(d("t", None, Some("https://evil.example/browse/CORE-5"), &u).is_empty());
        // Title and branch keys pass under Unknown.
        assert_eq!(
            d("CORE-1", Some("x/PAYM-2"), None, &u),
            ["CORE-1", "PAYM-2"]
        );
    }

    #[test]
    fn a_key_with_more_than_ten_digits_is_not_a_key() {
        let ten = format!("CORE-{}", "1".repeat(10));
        assert_eq!(d(&ten, None, None, &all()), std::slice::from_ref(&ten));
        let eleven = format!("CORE-{}", "1".repeat(11));
        assert!(d(&eleven, None, None, &all()).is_empty());
        let huge = format!("CORE-{}", "1".repeat(60_000));
        assert!(d(&huge, Some(&huge), Some(&huge), &all()).is_empty());
        assert!(!is_valid_key(&huge));
        assert!(!is_valid_key(&eleven));
        assert!(is_valid_key(&ten));
    }

    #[test]
    fn sanitize_keys_drops_malformed_dedupes_and_caps_at_five() {
        let junk = format!("CORE-{}", "9".repeat(60_000));
        let got = sanitize_keys([
            "core-1", "CORE-0", "CORE-1", "CORE-1", "<b>", &junk, "A-1", "CORE-2", "CORE-3",
            "CORE-4", "CORE-5", "CORE-6", "CORE-7",
        ]);
        assert_eq!(got, ["CORE-1", "CORE-2", "CORE-3", "CORE-4", "CORE-5"]);
    }

    #[test]
    fn deny_list_variants_are_dropped_before_the_list_loads() {
        let unknown = ProjectFilter::Unknown;
        for t in [
            "SHA3-256", "MD5-1", "UTF16-2", "HTTP2-3", "COVID-19", "SHA-3", "UTF-16", "TLS13-1",
        ] {
            assert!(d(t, None, None, &unknown).is_empty(), "{t}");
            assert!(d(t, None, None, &all()).is_empty(), "{t}");
        }
        // A real project that merely starts like a deny word is kept.
        assert_eq!(d("SHAPE-3", None, None, &unknown), ["SHAPE-3"]);
    }

    #[test]
    fn underscore_separates_words_in_branch_names_only() {
        assert_eq!(
            d("t", Some("feature/CORE-12_fix"), None, &all()),
            ["CORE-12"]
        );
        assert_eq!(d("t", Some("fix_CORE-12"), None, &all()), ["CORE-12"]);
        // Titles keep the whole-word rule.
        assert!(d("CORE-12_fix", None, None, &all()).is_empty());
    }

    #[test]
    fn junk_body_keys_cannot_crowd_out_a_real_project_key() {
        let mut body: String = (1..=1000).map(|n| format!("ZZ-{n} ")).collect();
        body.push_str("CORE-1");
        assert_eq!(d("t", None, Some(&body), &known(&["CORE"])), ["CORE-1"]);
    }

    #[test]
    fn scope_without_site_detects_nothing() {
        let scope = TicketScope::fixed(None, all());
        assert!(scope.resolve("CORE-1", "", &[]).is_empty());
    }
}
