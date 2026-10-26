//! Atom and RSS feeds (`kind = "feed"`): one entry is one item.

use chrono::{DateTime, Utc};
use feed_rs::model::{Entry, Link};

use super::config::SourceConfig;
use super::http::FetchError;
use super::{fetch_document, AdapterCtx, Draft, Fetch};
use crate::data::google_detail::html_to_text;
use crate::huey::items::{extract_urls, NewsItem, OUTBOUND_LINK_CAP};

/// Entries read per feed; a feed is newest first.
const MAX_ENTRIES: usize = 100;
const ACCEPT: &str =
    "application/atom+xml, application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5";

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    fetch_document(ctx, &src.url, Some(ACCEPT), |bytes| {
        parse(src, bytes, ctx.now)
    })
    .await
}

pub fn parse(
    src: &SourceConfig,
    bytes: &[u8],
    now: DateTime<Utc>,
) -> Result<Vec<NewsItem>, FetchError> {
    let feed = feed_rs::parser::parse(bytes).map_err(|_| FetchError::parse("feed"))?;
    Ok(feed
        .entries
        .iter()
        .take(MAX_ENTRIES)
        .filter_map(entry_draft)
        .map(|d| d.into_item(src, now))
        .collect())
}

fn entry_draft(entry: &Entry) -> Option<Draft> {
    let key = entry.id.trim();
    if key.is_empty() {
        return None;
    }
    let primary = primary_link(&entry.links);
    let url = match primary {
        Some(link) => link.href.clone(),
        None if key.starts_with("http://") || key.starts_with("https://") => key.to_string(),
        None => return None,
    };
    let html = entry
        .content
        .as_ref()
        .and_then(|c| c.body.clone())
        .or_else(|| entry.summary.as_ref().map(|s| s.content.clone()))
        .unwrap_or_default();
    let mut outbound_links = extract_urls(&html, OUTBOUND_LINK_CAP);
    outbound_links.extend(
        entry
            .links
            .iter()
            .filter(|l| !matches!(l.rel.as_deref(), None | Some("alternate" | "self")))
            .map(|l| l.href.clone()),
    );
    Some(Draft {
        key: key.to_string(),
        title: entry
            .title
            .as_ref()
            .map(|t| t.content.clone())
            .unwrap_or_default(),
        url,
        published_at: entry.published.or(entry.updated),
        text: html_to_text(&html),
        outbound_links,
    })
}

/// The entry's own page: the `alternate` link, or the first that is not a
/// feed-management link.
fn primary_link(links: &[Link]) -> Option<&Link> {
    links
        .iter()
        .find(|l| matches!(l.rel.as_deref(), None | Some("alternate")))
        .or_else(|| {
            links
                .iter()
                .find(|l| !matches!(l.rel.as_deref(), Some("self" | "enclosure")))
        })
}
