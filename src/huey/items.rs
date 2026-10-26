//! News items: the one shape every source adapter produces, plus the pure
//! helpers around it (canonical URLs, stable hashes, clustering).
//!
//! Nothing here touches the network or the disk.

use std::collections::HashSet;
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use url::Url;

/// How much a source is trusted to be the origin of a story. Declared best
/// first, so the derived order is the order a cluster's primary link is
/// chosen in: an original or first-party page beats a curated blog, which
/// beats an aggregator page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceClass {
    FirstParty,
    Curated,
    Aggregator,
}

/// Text kept per item from a non-first-party source.
pub const CURATED_TEXT_CAP: usize = 1_200;
/// Text kept per item from a first-party source. A safety bound, not a
/// summary: first-party entries are read in full.
pub const FIRST_PARTY_TEXT_CAP: usize = 20_000;
/// Outbound links kept per item.
pub const OUTBOUND_LINK_CAP: usize = 20;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewsItem {
    /// Stable: `<source id>:<native key>`.
    pub id: String,
    pub source_id: String,
    pub class: SourceClass,
    pub title: String,
    pub url: String,
    /// [`canonicalize`] of `url`.
    pub canonical_url: String,
    /// `None` for an undated source or an undated entry. A source that only
    /// dates a whole day publishes the end of that day, so such an item is
    /// never missed by a window that starts later the same day (the ledger
    /// stops it being shown twice).
    pub published_at: Option<DateTime<Utc>>,
    /// The first time Huey fetched this item.
    pub first_seen_at: DateTime<Utc>,
    /// Full for a first-party source, at most [`CURATED_TEXT_CAP`] chars
    /// otherwise.
    pub text: String,
    pub outbound_links: Vec<String>,
}

impl NewsItem {
    /// The time the window is judged against: the publication date when the
    /// source gives one, else when Huey first saw the item.
    pub fn effective_time(&self) -> DateTime<Utc> {
        self.published_at.unwrap_or(self.first_seen_at)
    }
}

/// Items that are the same story, best source first.
#[derive(Debug, Clone, PartialEq)]
pub struct Cluster {
    pub items: Vec<NewsItem>,
}

impl Cluster {
    /// The member whose link the report leads with.
    pub fn primary(&self) -> &NewsItem {
        &self.items[0]
    }

    /// The rest, in the order "Also covered by" lists them.
    pub fn also_covered_by(&self) -> &[NewsItem] {
        &self.items[1..]
    }
}

/// `https://Host/path/?utm_source=x#frag` → `https://host/path`: lower-cased
/// host, no fragment, no `utm_*` parameters, no trailing slash. Text that is
/// not a URL comes back trimmed.
pub fn canonicalize(url: &str) -> String {
    canonical(url, false)
}

/// Like [`canonicalize`] but keeping the fragment. A fragment names one entry
/// inside a page (a changelog version), so clustering must not merge entries
/// that only differ by it.
fn cluster_key(url: &str) -> String {
    canonical(url, true)
}

fn canonical(url: &str, keep_fragment: bool) -> String {
    let url = url.trim();
    let Ok(mut u) = Url::parse(url) else {
        return url.to_string();
    };
    if !keep_fragment || u.fragment() == Some("") {
        u.set_fragment(None);
    }
    let kept: Vec<(String, String)> = u
        .query_pairs()
        .filter(|(k, _)| !k.to_ascii_lowercase().starts_with("utm_"))
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if kept.is_empty() {
        u.set_query(None);
    } else {
        u.query_pairs_mut().clear().extend_pairs(&kept);
    }
    let trimmed = u.path().trim_end_matches('/').to_string();
    u.set_path(&trimmed);
    let mut s = u.to_string();
    if s.ends_with('/') {
        s.pop();
    }
    s
}

/// Group items that are the same story. Items from different sources join
/// when they share a URL, or when one links to the other's URL. Items of one
/// source never join directly (a docs page whose bullets all link to the
/// page is not one story).
///
/// Clusters come out in order of their earliest input item; members best
/// source class first, then oldest first.
pub fn cluster(items: &[NewsItem]) -> Vec<Cluster> {
    let n = items.len();
    let mut parent: Vec<usize> = (0..n).collect();
    fn find(parent: &mut [usize], mut i: usize) -> usize {
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    let own: Vec<String> = items.iter().map(|i| cluster_key(&i.url)).collect();
    let links: Vec<HashSet<String>> = items
        .iter()
        .map(|i| i.outbound_links.iter().map(|l| cluster_key(l)).collect())
        .collect();
    for i in 0..n {
        for j in (i + 1)..n {
            if items[i].source_id == items[j].source_id {
                continue;
            }
            let same_page = own[i] == own[j];
            let i_links_j = links[i].contains(&own[j]);
            let j_links_i = links[j].contains(&own[i]);
            if same_page || i_links_j || j_links_i {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                if a != b {
                    parent[b.max(a)] = b.min(a);
                }
            }
        }
    }
    let mut groups: Vec<(usize, Vec<NewsItem>)> = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let root = find(&mut parent, i);
        match groups.iter_mut().find(|(r, _)| *r == root) {
            Some((_, members)) => members.push(item.clone()),
            None => groups.push((root, vec![item.clone()])),
        }
    }
    groups
        .into_iter()
        .map(|(_, mut members)| {
            members.sort_by(|a, b| {
                a.class
                    .cmp(&b.class)
                    .then(a.published_at.cmp(&b.published_at))
                    .then(a.id.cmp(&b.id))
            });
            Cluster { items: members }
        })
        .collect()
}

static URL_IN_TEXT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"https?://[^\s<>"'\)\]\}]+"#).unwrap());

/// The http(s) URLs found in `text` (HTML, markdown or plain), in order,
/// without duplicates, at most `max`.
pub fn extract_urls(text: &str, max: usize) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for m in URL_IN_TEXT.find_iter(text) {
        let url = m
            .as_str()
            .replace("&amp;", "&")
            .trim_end_matches(['.', ',', ';', ':', '!', '?'])
            .to_string();
        if Url::parse(&url).is_ok() && seen.insert(url.clone()) {
            out.push(url);
            if out.len() >= max {
                break;
            }
        }
    }
    out
}

/// A stable 64-bit FNV-1a hash as 16 hex digits. Used for ids, so it must
/// never change between builds (unlike `DefaultHasher`).
pub fn stable_hash(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// One trimmed line of at most `max` characters, invisible characters gone.
pub fn clean_line(text: &str, max: usize) -> String {
    crate::data::work::untrusted::one_line(text, max)
}

/// Multi-line text with invisible and control characters dropped (newlines
/// and tabs kept), at most `max` characters.
pub fn clean_text(text: &str, max: usize) -> String {
    let kept: String = text
        .replace("\r\n", "\n")
        .chars()
        .filter(|&c| c == '\n' || c == '\t' || !crate::data::work::untrusted::is_invisible(c))
        .collect();
    let kept = kept.trim();
    if kept.chars().count() <= max {
        return kept.to_string();
    }
    let mut cut: String = kept.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(day: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, day, 12, 0, 0).unwrap()
    }

    fn item(id: &str, source: &str, class: SourceClass, url: &str, links: &[&str]) -> NewsItem {
        NewsItem {
            id: id.to_string(),
            source_id: source.to_string(),
            class,
            title: id.to_string(),
            url: url.to_string(),
            canonical_url: canonicalize(url),
            published_at: Some(at(20)),
            first_seen_at: at(21),
            text: String::new(),
            outbound_links: links.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn canonicalize_lowercases_host_and_drops_noise() {
        assert_eq!(
            canonicalize("https://Example.COM/Path/?utm_source=x&b=1&UTM_medium=y#frag"),
            "https://example.com/Path?b=1"
        );
        assert_eq!(canonicalize("https://example.com/"), "https://example.com");
        assert_eq!(
            canonicalize("https://example.com/a/b/?utm_campaign=z"),
            "https://example.com/a/b"
        );
        assert_eq!(canonicalize("  not a url "), "not a url");
    }

    #[test]
    fn canonicalize_is_idempotent() {
        let once = canonicalize("https://Example.com/a/?utm_x=1&k=v#f");
        assert_eq!(canonicalize(&once), once);
    }

    #[test]
    fn items_sharing_a_url_across_sources_cluster() {
        let a = item(
            "a:1",
            "a",
            SourceClass::FirstParty,
            "https://x.test/r/1",
            &[],
        );
        let b = item(
            "b:1",
            "b",
            SourceClass::Aggregator,
            "https://X.test/r/1/?utm_source=hn",
            &[],
        );
        let c = item("c:1", "c", SourceClass::Curated, "https://other.test/", &[]);
        let clusters = cluster(&[b.clone(), c.clone(), a.clone()]);
        assert_eq!(clusters.len(), 2);
        assert_eq!(clusters[0].primary().id, "a:1");
        assert_eq!(clusters[0].also_covered_by()[0].id, "b:1");
        assert_eq!(clusters[1].items, vec![c]);
    }

    #[test]
    fn an_outbound_link_to_another_items_url_clusters_them() {
        let release = item(
            "gh:v1",
            "gh",
            SourceClass::FirstParty,
            "https://x.test/r/v1",
            &[],
        );
        let post = item(
            "blog:1",
            "blog",
            SourceClass::Curated,
            "https://blog.test/p",
            &["https://x.test/r/v1?utm_source=feed"],
        );
        let clusters = cluster(&[post, release]);
        assert_eq!(clusters.len(), 1);
        assert_eq!(clusters[0].primary().id, "gh:v1");
    }

    #[test]
    fn two_items_of_one_source_never_join_directly() {
        let a = item(
            "s:1",
            "s",
            SourceClass::FirstParty,
            "https://x.test/page",
            &[],
        );
        let b = item(
            "s:2",
            "s",
            SourceClass::FirstParty,
            "https://x.test/page",
            &[],
        );
        assert_eq!(cluster(&[a, b]).len(), 2);
    }

    #[test]
    fn a_fragment_names_an_entry_so_it_does_not_merge_entries() {
        let v1 = item(
            "cl:1",
            "cl",
            SourceClass::FirstParty,
            "https://x.test/C.md#1",
            &[],
        );
        let v2 = item(
            "cl:2",
            "cl",
            SourceClass::FirstParty,
            "https://x.test/C.md#2",
            &[],
        );
        let post = item(
            "blog:1",
            "blog",
            SourceClass::Curated,
            "https://blog.test/p",
            &["https://x.test/C.md#2"],
        );
        let clusters = cluster(&[v1, v2, post]);
        assert_eq!(clusters.len(), 2);
        assert_eq!(clusters[1].primary().id, "cl:2");
        assert_eq!(clusters[1].items.len(), 2);
        // The canonical URL itself never carries the fragment.
        assert_eq!(clusters[1].primary().canonical_url, "https://x.test/C.md");
    }

    #[test]
    fn extract_urls_finds_html_markdown_and_bare_links_once() {
        let text = r#"<a href="https://a.test/x?p=1&amp;q=2">a</a> see [b](https://b.test/y). Also https://a.test/x?p=1&q=2, and ftp://no.test"#;
        assert_eq!(
            extract_urls(text, 10),
            vec!["https://a.test/x?p=1&q=2", "https://b.test/y"]
        );
        assert_eq!(extract_urls(text, 1).len(), 1);
    }

    #[test]
    fn stable_hash_is_fixed() {
        assert_eq!(stable_hash(""), "cbf29ce484222325");
        assert_eq!(stable_hash("a"), "af63dc4c8601ec8c");
    }

    #[test]
    fn clean_text_drops_invisible_characters_and_caps() {
        assert_eq!(clean_text("a\u{202E}b\r\nc\u{0}", 50), "ab\nc");
        let capped = clean_text(&"x".repeat(30), 10);
        assert_eq!(capped.chars().count(), 10);
        assert!(capped.ends_with('…'));
    }

    #[test]
    fn effective_time_prefers_the_publication_date() {
        let mut i = item("a:1", "a", SourceClass::Curated, "https://x.test", &[]);
        assert_eq!(i.effective_time(), at(20));
        i.published_at = None;
        assert_eq!(i.effective_time(), at(21));
    }
}
