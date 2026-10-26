//! The Hacker News front page (`kind = "hn_front_page"`): one top story is
//! one item, linking to the story's own page so it clusters with the same
//! story from other sources.

use chrono::DateTime;
use futures::StreamExt;
use serde::Deserialize;

use super::config::SourceConfig;
use super::http::FetchError;
use super::{AdapterCtx, Draft, Fetch};
use crate::data::google_detail::html_to_text;

/// Stories fetched at once.
const CONCURRENCY: usize = 8;

#[derive(Deserialize)]
struct Story {
    id: u64,
    title: Option<String>,
    url: Option<String>,
    text: Option<String>,
    time: Option<i64>,
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    dead: bool,
    #[serde(default)]
    deleted: bool,
}

pub(crate) async fn fetch(
    src: &SourceConfig,
    ctx: &AdapterCtx<'_>,
) -> Result<Option<Fetch>, FetchError> {
    let ids: Vec<u64> = ctx
        .http
        .get_json(&src.url, Some("application/json"), "front page")
        .await?;
    let ids: Vec<u64> = ids.into_iter().take(src.top).collect();
    let template = item_template(src);
    let stories: Vec<Option<Story>> = futures::stream::iter(ids.iter().map(|id| {
        let url = template.replace("{id}", &id.to_string());
        async move {
            ctx.http
                .get_json::<Option<Story>>(&url, Some("application/json"), "story")
                .await
                .ok()
                .flatten()
        }
    }))
    .buffered(CONCURRENCY)
    .collect()
    .await;
    if !ids.is_empty() && stories.iter().all(Option::is_none) {
        return Err(FetchError::Network);
    }
    Ok(Some(Fetch {
        items: stories
            .into_iter()
            .flatten()
            .filter_map(draft)
            .map(|d| d.into_item(src, ctx.now))
            .collect(),
        etag: None,
        last_modified: None,
    }))
}

/// One story's URL with `{id}` in it: the configured one, else the
/// `item/{id}.json` sibling of the front-page list.
fn item_template(src: &SourceConfig) -> String {
    src.item_url.clone().unwrap_or_else(|| {
        let base = src
            .url
            .rsplit_once('/')
            .map_or(src.url.as_str(), |(b, _)| b);
        format!("{base}/item/{{id}}.json")
    })
}

fn draft(story: Story) -> Option<Draft> {
    if story.dead || story.deleted || story.kind.as_deref().is_some_and(|k| k != "story") {
        return None;
    }
    let title = story.title.filter(|t| !t.trim().is_empty())?;
    let url = story
        .url
        .filter(|u| u.starts_with("http"))
        .unwrap_or_else(|| format!("https://news.ycombinator.com/item?id={}", story.id));
    Some(Draft {
        key: story.id.to_string(),
        title,
        url,
        published_at: story.time.and_then(|t| DateTime::from_timestamp(t, 0)),
        text: story.text.as_deref().map(html_to_text).unwrap_or_default(),
        outbound_links: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_story(bytes: &[u8]) -> Option<Draft> {
        serde_json::from_slice::<Option<Story>>(bytes)
            .ok()
            .flatten()
            .and_then(draft)
    }

    #[test]
    fn dead_deleted_and_non_story_entries_are_dropped() {
        for json in [
            r#"{"id":1,"type":"story","title":"t","dead":true}"#,
            r#"{"id":1,"type":"story","title":"t","deleted":true}"#,
            r#"{"id":1,"type":"comment","title":"t"}"#,
            r#"{"id":1,"type":"story"}"#,
            "null",
        ] {
            assert!(parse_story(json.as_bytes()).is_none(), "{json}");
        }
    }

    #[test]
    fn a_story_without_a_url_links_to_its_discussion() {
        let d = parse_story(br#"{"id":42,"type":"story","title":"Ask HN: x","time":1761350000}"#)
            .unwrap();
        assert_eq!(d.url, "https://news.ycombinator.com/item?id=42");
        assert_eq!(d.key, "42");
        assert!(d.published_at.is_some());
    }
}
