//! News sources: configuration, one adapter per source kind, per-source
//! state, and `fetch_all`, which runs them together.
//!
//! GET only (T1, T2): nothing in this tree sends anything but a GET.

pub mod config;
pub mod feed;
pub mod fetch;
pub mod github_releases;
pub mod hn;
pub mod html_link_index;
pub mod http;
pub mod md_dated_sections;
pub mod npm_changelog;
pub mod state;

use chrono::{DateTime, Utc};

use crate::huey::items::{
    canonicalize, clean_line, clean_text, NewsItem, SourceClass, CURATED_TEXT_CAP,
    FIRST_PARTY_TEXT_CAP, OUTBOUND_LINK_CAP,
};
use config::{SourceConfig, SourceKind};
use http::{Conditional, Response};
use state::SourceState;

pub use config::{default_toml, SourcesConfig};
pub use fetch::{
    fetch_all, load_pool, prune_pool, save_pool, FetchOutcome, SourceOutcome, SourceStatus,
};
pub use http::{FetchError, HttpClient, HttpLimits};
pub use state::{eligible, Eligibility};

const TITLE_CAP: usize = 200;

/// What an adapter gets besides its source's configuration.
pub(crate) struct AdapterCtx<'a> {
    pub http: &'a HttpClient,
    pub now: DateTime<Utc>,
    /// The source's state before this fetch.
    pub state: &'a SourceState,
}

impl AdapterCtx<'_> {
    /// Validators from the last successful fetch, if the server gave any.
    pub fn conditional(&self) -> Option<Conditional> {
        let c = Conditional {
            etag: self.state.etag.clone(),
            last_modified: self.state.last_modified.clone(),
        };
        (!c.is_empty()).then_some(c)
    }
}

/// What a successful adapter run returns. `None` from an adapter means the
/// server said "not modified".
pub(crate) struct Fetch {
    pub items: Vec<NewsItem>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

/// An item as an adapter found it, before the common clean-up.
pub(crate) struct Draft {
    /// The source's own key; the item id is `<source id>:<key>`.
    pub key: String,
    pub title: String,
    pub url: String,
    pub published_at: Option<DateTime<Utc>>,
    pub text: String,
    pub outbound_links: Vec<String>,
}

impl Draft {
    pub fn into_item(self, src: &SourceConfig, now: DateTime<Utc>) -> NewsItem {
        let canonical_url = canonicalize(&self.url);
        let cap = match src.class {
            SourceClass::FirstParty => FIRST_PARTY_TEXT_CAP,
            _ => CURATED_TEXT_CAP,
        };
        let mut links: Vec<String> = Vec::new();
        for link in self.outbound_links {
            let is_http = link.starts_with("http://") || link.starts_with("https://");
            if is_http && canonicalize(&link) != canonical_url && !links.contains(&link) {
                links.push(link);
                if links.len() >= OUTBOUND_LINK_CAP {
                    break;
                }
            }
        }
        let mut title = clean_line(&self.title, TITLE_CAP);
        if title.is_empty() {
            title = clean_line(&self.key, TITLE_CAP);
        }
        NewsItem {
            id: format!("{}:{}", src.id, self.key),
            source_id: src.id.clone(),
            class: src.class,
            title,
            url: self.url,
            canonical_url,
            published_at: self.published_at,
            first_seen_at: now,
            text: clean_text(&self.text, cap),
            outbound_links: links,
        }
    }
}

/// Fetch one document with this source's validators and parse it.
pub(crate) async fn fetch_document(
    ctx: &AdapterCtx<'_>,
    url: &str,
    accept: Option<&str>,
    parse: impl FnOnce(&[u8]) -> Result<Vec<NewsItem>, FetchError>,
) -> Result<Option<Fetch>, FetchError> {
    let conditional = ctx.conditional();
    match ctx.http.get(url, accept, conditional.as_ref()).await? {
        Response::NotModified => Ok(None),
        Response::Body(body) => Ok(Some(Fetch {
            items: parse(&body.bytes)?,
            etag: body.etag,
            last_modified: body.last_modified,
        })),
    }
}

pub(crate) async fn fetch_source(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    match src.kind {
        SourceKind::NpmChangelog => npm_changelog::fetch(src, ctx).await,
        SourceKind::MdDatedSections => md_dated_sections::fetch(src, ctx).await,
        SourceKind::HtmlLinkIndex => html_link_index::fetch(src, ctx).await,
        SourceKind::GithubReleases => github_releases::fetch(src, ctx).await,
        SourceKind::Feed => feed::fetch(src, ctx).await,
        SourceKind::HnFrontPage => hn::fetch(src, ctx).await,
    }
}
