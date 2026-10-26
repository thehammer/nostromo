//! A markdown page of dated sections, such as the docs release notes
//! (`kind = "md_dated_sections"`): one top-level bullet is one item, dated by
//! the `### October 22, 2026` heading above it.
//!
//! The page only gives a day, so a bullet is published at the end of that
//! day: a window that starts later the same day still sees it, and the
//! ledger stops it being shown twice.

use std::collections::HashSet;
use std::sync::LazyLock;

use chrono::{DateTime, NaiveDate, Utc};
use regex::Regex;
use url::Url;

use super::config::SourceConfig;
use super::http::FetchError;
use super::{fetch_document, AdapterCtx, Draft, Fetch};
use crate::huey::items::{extract_urls, stable_hash, NewsItem, OUTBOUND_LINK_CAP};

static HEADING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^#{1,6}\s+(.+?)\s*#*\s*$").unwrap());
static BULLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\s*)[-*+]\s+(.*)$").unwrap());
static MD_LINK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([^\]]*)\]\(([^)\s]+)[^)]*\)").unwrap());
const TITLE_CHARS: usize = 120;

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    fetch_document(
        ctx,
        &src.url,
        Some("text/markdown, text/plain, */*;q=0.5"),
        |bytes| parse(src, &String::from_utf8_lossy(bytes), ctx.now),
    )
    .await
}

pub fn parse(
    src: &SourceConfig,
    markdown: &str,
    now: DateTime<Utc>,
) -> Result<Vec<NewsItem>, FetchError> {
    let page = page_url(&src.url);
    let mut seen = HashSet::new();
    let items: Vec<NewsItem> = bullets(markdown)
        .into_iter()
        .filter_map(|(date, raw)| {
            let key = format!("{date}:{}", stable_hash(&normalize(&raw)));
            if !seen.insert(key.clone()) {
                return None;
            }
            let links = link_targets(&raw, &page);
            let url = links.first().cloned().unwrap_or_else(|| page.to_string());
            let text = strip_links(&raw);
            Some(
                Draft {
                    key,
                    title: first_line(&text),
                    url,
                    published_at: end_of_day(date),
                    text,
                    outbound_links: links,
                }
                .into_item(src, now),
            )
        })
        .collect();
    if items.is_empty() {
        return Err(FetchError::parse("release notes"));
    }
    Ok(items)
}

/// `(date, bullet markdown)` for every top-level bullet under a date heading.
/// Nested bullets and indented continuation lines belong to their parent.
fn bullets(markdown: &str) -> Vec<(NaiveDate, String)> {
    let mut out: Vec<(NaiveDate, String)> = Vec::new();
    let mut date: Option<NaiveDate> = None;
    let mut open = false;
    for line in markdown.lines() {
        if let Some(h) = HEADING.captures(line) {
            if let Some(d) = parse_date(&h[1]) {
                date = Some(d);
            }
            open = false;
            continue;
        }
        let Some(day) = date else { continue };
        if line.trim().is_empty() {
            continue;
        }
        if let Some(b) = BULLET.captures(line) {
            if b[1].len() < 2 {
                out.push((day, b[2].to_string()));
                open = true;
            } else if open {
                if let Some(last) = out.last_mut() {
                    last.1.push('\n');
                    last.1.push_str(b[2].trim());
                }
            }
        } else if open && line.starts_with(' ') {
            if let Some(last) = out.last_mut() {
                last.1.push('\n');
                last.1.push_str(line.trim());
            }
        } else {
            open = false;
        }
    }
    out
}

fn parse_date(heading: &str) -> Option<NaiveDate> {
    let text = heading
        .trim()
        .trim_matches(|c: char| c == '*' || c == '_')
        .trim();
    NaiveDate::parse_from_str(text, "%B %d, %Y")
        .or_else(|_| NaiveDate::parse_from_str(text, "%b %d, %Y"))
        .ok()
}

fn end_of_day(date: NaiveDate) -> Option<DateTime<Utc>> {
    date.and_hms_opt(23, 59, 59).map(|t| t.and_utc())
}

/// The page a reader opens: the `.md` rendering without its extension.
fn page_url(url: &str) -> String {
    url.strip_suffix(".md").unwrap_or(url).to_string()
}

fn normalize(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Link targets in the bullet, relative ones resolved against the page.
fn link_targets(raw: &str, page: &str) -> Vec<String> {
    let base = Url::parse(page).ok();
    let mut out: Vec<String> = Vec::new();
    for cap in MD_LINK.captures_iter(raw) {
        let target = &cap[2];
        let resolved = match &base {
            Some(b) => b.join(target).ok().map(String::from),
            None => Some(target.to_string()),
        };
        if let Some(u) = resolved.filter(|u| u.starts_with("http")) {
            if !out.contains(&u) {
                out.push(u);
            }
        }
    }
    for u in extract_urls(raw, OUTBOUND_LINK_CAP) {
        if !out.contains(&u) {
            out.push(u);
        }
    }
    out
}

fn strip_links(raw: &str) -> String {
    MD_LINK.replace_all(raw, "$1").into_owned()
}

fn first_line(text: &str) -> String {
    let line = text.lines().next().unwrap_or("");
    crate::huey::items::clean_line(&line.replace("**", "").replace('`', ""), TITLE_CHARS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_parse_in_both_month_forms() {
        assert_eq!(
            parse_date("October 5, 2026"),
            NaiveDate::from_ymd_opt(2026, 10, 5)
        );
        assert_eq!(
            parse_date("Oct 22, 2026"),
            NaiveDate::from_ymd_opt(2026, 10, 22)
        );
        assert_eq!(parse_date("Claude apps"), None);
    }

    #[test]
    fn nested_bullets_and_continuations_belong_to_the_parent() {
        let md = "### October 22, 2026\n\n- First **thing**\n  - nested\n  more text\n\n- Second\n\n### Other heading\n- Third\n";
        let found = bullets(md);
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].1, "First **thing**\nnested\nmore text");
        assert_eq!(found[2].0, NaiveDate::from_ymd_opt(2026, 10, 22).unwrap());
    }

    #[test]
    fn relative_links_resolve_against_the_page() {
        let links = link_targets(
            "See [the docs](/en/docs/x) and [news](https://a.test/n)",
            "https://docs.claude.com/en/release-notes/overview",
        );
        assert_eq!(
            links,
            ["https://docs.claude.com/en/docs/x", "https://a.test/n"]
        );
    }
}
