//! An HTML page that links to articles but carries no dates, such as the
//! Anthropic news index (`kind = "html_link_index"`): one link is one item,
//! dated by when Huey first saw it.
//!
//! Only links not seen before are opened (at most [`MAX_ARTICLES`] per run,
//! newest-listed first) to read the article's `og:title` and
//! `og:description`. Further new links wait for the next run. The very first
//! read opens nothing: every link is baseline then.

use std::collections::HashSet;

use regex::Regex;
use url::Url;

use super::config::SourceConfig;
use super::http::{FetchError, HttpClient, Response};
use super::{AdapterCtx, Draft, Fetch};

/// Article pages opened per run (T1).
pub const MAX_ARTICLES: usize = 10;
const DESCRIPTION_CHARS: usize = 1_200;

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    let conditional = ctx.conditional();
    let body = match ctx
        .http
        .get(&src.url, Some("text/html, */*;q=0.5"), conditional.as_ref())
        .await?
    {
        Response::NotModified => return Ok(None),
        Response::Body(b) => b,
    };
    let html = String::from_utf8_lossy(&body.bytes);
    let slugs = parse_slugs(&html, &src.link_prefix);
    if slugs.is_empty() {
        return Err(FetchError::parse("news index"));
    }
    let origin = origin_of(&src.url).ok_or_else(|| FetchError::parse("news index"))?;

    // New links, in listed order; the rest wait for the next run.
    let is_new = |slug: &str| !ctx.state.items.contains_key(&format!("{}:{slug}", src.id));
    let read_now: Vec<&String> = if ctx.state.baseline_done {
        slugs
            .iter()
            .filter(|s| is_new(s))
            .take(MAX_ARTICLES)
            .collect()
    } else {
        Vec::new()
    };
    let articles = futures::future::join_all(read_now.iter().map(|slug| {
        let url = article_url(&origin, &src.link_prefix, slug);
        async move { read_article(ctx.http, &url).await }
    }))
    .await;

    let mut items = Vec::new();
    for slug in &slugs {
        let id = format!("{}:{slug}", src.id);
        let url = article_url(&origin, &src.link_prefix, slug);
        if let Some(prev) = ctx.state.recent.iter().find(|i| i.id == id) {
            items.push(prev.clone());
            continue;
        }
        let og = match read_now.iter().position(|s| *s == slug) {
            Some(i) => articles[i].clone(),
            None if is_new(slug) && ctx.state.baseline_done => continue, // deferred
            None => Og::default(),
        };
        items.extend(
            Draft {
                key: slug.clone(),
                title: og.title.unwrap_or_else(|| humanize(slug)),
                url,
                published_at: None,
                text: og.description.unwrap_or_default(),
                outbound_links: Vec::new(),
            }
            .into_item(src, ctx.now),
        );
    }
    Ok(Some(Fetch {
        items,
        etag: body.etag,
        last_modified: body.last_modified,
    }))
}

/// The distinct article slugs linked from the index, in page order. A link is
/// `href="<prefix><slug>"`, relative or on the same page's host.
pub fn parse_slugs(html: &str, prefix: &str) -> Vec<String> {
    let pattern = format!(
        r#"href\s*=\s*["'](?:https?://[^/"']+)?{}([a-z0-9][a-z0-9-]*)/?(?:[?#][^"']*)?["']"#,
        regex::escape(prefix)
    );
    let Ok(re) = Regex::new(&pattern) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    re.captures_iter(html)
        .map(|c| c[1].to_string())
        .filter(|slug| seen.insert(slug.clone()))
        .collect()
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Og {
    pub title: Option<String>,
    pub description: Option<String>,
}

/// `og:title` and `og:description` from a page's `<meta>` tags.
pub fn parse_og(html: &str) -> Og {
    let tag = Regex::new(r#"(?is)<meta\s[^>]*>"#).expect("static regex");
    let attr =
        Regex::new(r#"(?is)([a-z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#).expect("static regex");
    let mut og = Og::default();
    for m in tag.find_iter(html) {
        let (mut name, mut content) = (None, None);
        for a in attr.captures_iter(m.as_str()) {
            let value = a.get(2).or_else(|| a.get(3)).map_or("", |v| v.as_str());
            match a[1].to_ascii_lowercase().as_str() {
                "property" | "name" => name = Some(value.to_ascii_lowercase()),
                "content" => content = Some(decode_entities(value)),
                _ => {}
            }
        }
        match (name.as_deref(), content) {
            (Some("og:title"), Some(c)) if og.title.is_none() => og.title = Some(c),
            (Some("og:description"), Some(c)) if og.description.is_none() => {
                og.description = Some(crate::huey::items::clean_text(&c, DESCRIPTION_CHARS));
            }
            _ => {}
        }
    }
    og
}

async fn read_article(http: &HttpClient, url: &str) -> Og {
    match http.get_body(url, Some("text/html, */*;q=0.5")).await {
        Ok(bytes) => parse_og(&String::from_utf8_lossy(&bytes)),
        // One unreadable article never fails the index: it shows by its slug.
        Err(_) => Og::default(),
    }
}

fn origin_of(url: &str) -> Option<String> {
    let u = Url::parse(url).ok()?;
    Some(u.origin().ascii_serialization())
}

fn article_url(origin: &str, prefix: &str, slug: &str) -> String {
    format!("{origin}{prefix}{slug}")
}

fn humanize(slug: &str) -> String {
    let spaced = slug.replace('-', " ");
    let mut chars = spaced.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn decode_entities(text: &str) -> String {
    text.replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_come_back_once_in_page_order() {
        let html = r#"<a href="/news/b-post">B</a> <a href='/news/a-post/'>A</a>
            <a href="https://www.anthropic.com/news/c-post?x=1">C</a>
            <a href="/news/b-post">again</a> <a href="/news/">index</a>
            <a href="/news/a/b">deeper</a> <a href="/careers/x">no</a>"#;
        assert_eq!(parse_slugs(html, "/news/"), ["b-post", "a-post", "c-post"]);
    }

    #[test]
    fn og_tags_are_read_in_either_attribute_order() {
        let html = r#"<head><meta content="Big &amp; Bold" property="og:title">
            <meta property='og:description' content='It&#39;s new'>
            <meta name="twitter:title" content="no"></head>"#;
        assert_eq!(
            parse_og(html),
            Og {
                title: Some("Big & Bold".to_string()),
                description: Some("It's new".to_string())
            }
        );
    }

    #[test]
    fn a_slug_reads_as_a_title() {
        assert_eq!(humanize("claude-opus-5"), "Claude opus 5");
    }
}
