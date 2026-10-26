//! GitHub releases of one repository (`kind = "github_releases"`): one
//! release is one item with its notes as text.

use chrono::{DateTime, Utc};
use serde::Deserialize;

use super::config::SourceConfig;
use super::http::FetchError;
use super::{fetch_document, AdapterCtx, Draft, Fetch};
use crate::huey::items::{extract_urls, NewsItem, OUTBOUND_LINK_CAP};

/// Releases read per run; GitHub lists newest first.
const PER_PAGE: usize = 30;

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    name: Option<String>,
    html_url: Option<String>,
    body: Option<String>,
    published_at: Option<DateTime<Utc>>,
    created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
}

pub fn releases_url(src: &SourceConfig) -> String {
    format!(
        "{}/repos/{}/releases?per_page={PER_PAGE}",
        src.api_base,
        src.repo.as_deref().unwrap_or_default()
    )
}

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    fetch_document(
        ctx,
        &releases_url(src),
        Some("application/vnd.github+json"),
        |bytes| parse(src, bytes, ctx.now),
    )
    .await
}

pub fn parse(
    src: &SourceConfig,
    bytes: &[u8],
    now: DateTime<Utc>,
) -> Result<Vec<NewsItem>, FetchError> {
    let releases: Vec<Release> =
        serde_json::from_slice(bytes).map_err(|_| FetchError::parse("releases"))?;
    let repo = src.repo.as_deref().unwrap_or_default();
    Ok(releases
        .into_iter()
        .filter(|r| !r.draft && !r.tag_name.trim().is_empty())
        .map(|r| {
            let body = r.body.unwrap_or_default();
            let name = r.name.filter(|n| !n.trim().is_empty());
            let mut title = name.unwrap_or_else(|| r.tag_name.clone());
            if r.prerelease {
                title.push_str(" (pre-release)");
            }
            Draft {
                title,
                url: r.html_url.unwrap_or_else(|| {
                    format!("https://github.com/{repo}/releases/tag/{}", r.tag_name)
                }),
                published_at: r.published_at.or(r.created_at),
                outbound_links: extract_urls(&body, OUTBOUND_LINK_CAP),
                text: body,
                key: r.tag_name,
            }
            .into_item(src, now)
        })
        .collect())
}
