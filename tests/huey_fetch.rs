//! Behavioural tests for Huey H2: fetching news from the configured sources.
//!
//! Everything is driven from the outside: a `sources.toml` text, a wiremock
//! server standing in for every site, a temp state directory and a fixed
//! clock (`now` is an argument; nothing here reads the wall clock). Fixtures
//! are trimmed samples of the real formats under `tests/fixtures/huey/sources/`.
//!
//! Test names start with the acceptance criterion they pin (`h2_1_` ...).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chrono::{DateTime, NaiveDate, Utc};
use wiremock::matchers::{header, method, path, path_regex, query_param};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

use nostromo::huey::items::{cluster, NewsItem, SourceClass};
use nostromo::huey::sources::config::{default_toml, load, SourceKind, SourcesConfig};
use nostromo::huey::sources::{
    fetch_all, load_pool, prune_pool, save_pool, FetchOutcome, HttpClient, HttpLimits,
    SourceOutcome,
};

// ── helpers ──────────────────────────────────────────────────────────────────

fn ts(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

/// The fixed clock for the "current" fetch.
fn now() -> DateTime<Utc> {
    ts("2026-10-25T12:00:00Z")
}

/// An earlier fetch, used to seed a source's state.
fn earlier() -> DateTime<Utc> {
    ts("2026-10-24T12:00:00Z")
}

fn window() -> DateTime<Utc> {
    ts("2026-10-18T00:00:00Z")
}

fn fixture(name: &str) -> String {
    let p = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/huey/sources")
        .join(name);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("fixture {}: {e}", p.display()))
}

fn limits(per_source_secs: u64, body_cap: usize) -> HttpLimits {
    HttpLimits {
        per_source: Duration::from_secs(per_source_secs),
        overall: Duration::from_secs(60),
        body_cap,
    }
}

fn client() -> HttpClient {
    HttpClient::new(limits(10, 1024 * 1024), None)
}

async fn run(
    cfg: &SourcesConfig,
    dir: &Path,
    window: DateTime<Utc>,
    at: DateTime<Utc>,
) -> FetchOutcome {
    fetch_all(cfg, dir, window, at, &client()).await
}

fn ids(out: &FetchOutcome) -> Vec<&str> {
    out.items.iter().map(|i| i.id.as_str()).collect()
}

fn item<'a>(out: &'a FetchOutcome, id: &str) -> &'a NewsItem {
    out.items
        .iter()
        .find(|i| i.id == id)
        .unwrap_or_else(|| panic!("no item {id}; have {:?}", ids(out)))
}

fn outcome<'a>(out: &'a FetchOutcome, id: &str) -> &'a SourceOutcome {
    &out.statuses
        .iter()
        .find(|s| s.id == id)
        .unwrap_or_else(|| panic!("no status for {id}"))
        .outcome
}

fn failure(out: &FetchOutcome, id: &str) -> String {
    match outcome(out, id) {
        SourceOutcome::Failed { reason } => reason.clone(),
        other => panic!("{id} should have failed, was {other:?}"),
    }
}

async fn serve(server: &MockServer, p: &str, body: impl Into<String>) {
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(ResponseTemplate::new(200).set_body_string(body.into()))
        .mount(server)
        .await;
}

async fn serve_status(server: &MockServer, p: &str, status: u16, body: &str) {
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(ResponseTemplate::new(status).set_body_string(body))
        .mount(server)
        .await;
}

async fn requests(server: &MockServer) -> Vec<Request> {
    server
        .received_requests()
        .await
        .expect("request recording is on")
}

async fn count_requests(server: &MockServer, path_prefix: &str) -> usize {
    requests(server)
        .await
        .iter()
        .filter(|r| r.url.path().starts_with(path_prefix))
        .count()
}

/// Parse a config built from source snippets; it must load without warnings.
fn cfg(parts: &[String]) -> SourcesConfig {
    let (cfg, warnings) = load(&parts.join("\n"));
    assert!(warnings.is_empty(), "config warnings: {warnings:?}");
    cfg
}

// Source snippets: one `[[source]]` table each, pointed at the mock server.

fn changelog_src(base: &str) -> String {
    format!(
        r#"[[source]]
id = "claude-code-changelog"
name = "Claude Code changelog"
kind = "npm_changelog"
class = "first_party"
url = "{base}/changelog/CHANGELOG.md"
registry_url = "{base}/npm/claude-code"
link_url = "{base}/blob/main/CHANGELOG.md"
"#
    )
}

fn notes_src(base: &str) -> String {
    format!(
        r#"[[source]]
id = "claude-docs-release-notes"
name = "Claude docs release notes"
kind = "md_dated_sections"
class = "first_party"
url = "{base}/en/release-notes/overview.md"
"#
    )
}

fn news_src(base: &str) -> String {
    format!(
        r#"[[source]]
id = "anthropic-news"
name = "Anthropic news"
kind = "html_link_index"
class = "first_party"
url = "{base}/news"
link_prefix = "/news/"
"#
    )
}

fn github_src(base: &str) -> String {
    format!(
        r#"[[source]]
id = "agent-sdk-releases"
name = "Agent SDK releases"
kind = "github_releases"
class = "first_party"
repo = "example-org/agent-sdk"
api_base = "{base}"
"#
    )
}

fn feed_src(id: &str, class: &str, url: &str) -> String {
    format!(
        r#"[[source]]
id = "{id}"
name = "{id}"
kind = "feed"
class = "{class}"
url = "{url}"
"#
    )
}

fn hn_src(base: &str) -> String {
    format!(
        r#"[[source]]
id = "hn-front-page"
name = "Hacker News front page"
kind = "hn_front_page"
class = "aggregator"
url = "{base}/v0/topstories.json"
"#
    )
}

const ATOM_ID: &str = "simon-willison";
const RSS_ID: &str = "latent-space";
const GH_URL: &str = "https://github.com/example-org/agent-sdk/releases/tag/v3.4.0";
const ATOM_RELEASE_POST: &str =
    "simon-willison:https://linkblog.example.test/2026/Oct/22/agent-sdk-340/";

// Mounting the fixtures.

async fn mount_changelog(server: &MockServer, changelog: &str, registry: Option<&str>) {
    serve(server, "/changelog/CHANGELOG.md", changelog).await;
    match registry {
        Some(r) => serve(server, "/npm/claude-code", r).await,
        None => serve_status(server, "/npm/claude-code", 500, "registry down").await,
    }
}

async fn mount_github(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/repos/example-org/agent-sdk/releases"))
        .and(query_param("per_page", "30"))
        .respond_with(ResponseTemplate::new(200).set_body_string(fixture("github-releases.json")))
        .mount(server)
        .await;
}

async fn mount_hn(server: &MockServer) {
    serve(server, "/v0/topstories.json", fixture("hn-topstories.json")).await;
    for id in [9001, 9002, 9003, 9004] {
        serve(
            server,
            &format!("/v0/item/{id}.json"),
            fixture(&format!("hn-item-{id}.json")),
        )
        .await;
    }
}

const NEW_SLUG: &str = "introducing-workspace-agents";
const OTHER_NEW_SLUG: &str = "open-sourcing-eval-harness";

/// The news index with the given slugs' links removed.
fn index_without(slugs: &[&str]) -> String {
    fixture("news-index.html")
        .lines()
        .filter(|l| !slugs.iter().any(|s| l.contains(&format!("/news/{s}\""))))
        .collect::<Vec<_>>()
        .join("\n")
}

async fn mount_news(server: &MockServer, index_html: &str) {
    serve(server, "/news", index_html).await;
    for slug in [NEW_SLUG, OTHER_NEW_SLUG] {
        serve(
            server,
            &format!("/news/{slug}"),
            fixture(&format!("article-{slug}.html")),
        )
        .await;
    }
}

/// Every source kind, each answering from its fixture.
async fn mount_world(server: &MockServer, index_html: &str) {
    mount_changelog(
        server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    serve(
        server,
        "/en/release-notes/overview.md",
        fixture("release-notes.md"),
    )
    .await;
    mount_news(server, index_html).await;
    mount_github(server).await;
    serve(server, "/atom.xml", fixture("atom.xml")).await;
    serve(server, "/rss.xml", fixture("rss.xml")).await;
    mount_hn(server).await;
}

fn world_cfg(base: &str) -> SourcesConfig {
    cfg(&[
        changelog_src(base),
        notes_src(base),
        news_src(base),
        github_src(base),
        feed_src(ATOM_ID, "curated", &format!("{base}/atom.xml")),
        feed_src(RSS_ID, "curated", &format!("{base}/rss.xml")),
        hn_src(base),
    ])
}

/// The non-blank lines of one version's section in the changelog fixture.
fn changelog_lines(version: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut inside = false;
    for l in fixture("CHANGELOG.md").lines() {
        if let Some(h) = l.strip_prefix("## ") {
            inside = h.trim() == version;
        } else if inside && !l.trim().is_empty() {
            lines.push(l.to_string());
        }
    }
    lines
}

fn registry_without(version: &str) -> String {
    let mut v: serde_json::Value = serde_json::from_str(&fixture("npm-registry.json")).unwrap();
    v["time"].as_object_mut().unwrap().remove(version);
    v.to_string()
}

// ── H2-1: an undated source is judged by when Huey first saw an item ─────────

#[tokio::test]
async fn h2_1_first_read_of_an_undated_source_offers_nothing_and_opens_no_articles() {
    let server = MockServer::start().await;
    mount_news(&server, &index_without(&[NEW_SLUG])).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), earlier()).await;

    assert!(
        out.items.is_empty(),
        "everything on the first read is baseline: {:?}",
        ids(&out)
    );
    assert_eq!(outcome(&out, "anthropic-news"), &SourceOutcome::Quiet);
    assert_eq!(
        count_requests(&server, "/news/").await,
        0,
        "no article page is opened on the first read"
    );
    assert!(
        dir.path().join("sources/anthropic-news.json").exists(),
        "state is kept per source"
    );
}

#[tokio::test]
async fn h2_1_a_link_that_appears_after_the_first_read_is_the_only_eligible_item() {
    let server = MockServer::start().await;
    mount_news(&server, &index_without(&[NEW_SLUG])).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(ids(&out), [format!("anthropic-news:{NEW_SLUG}")]);
    let it = &out.items[0];
    assert_eq!(it.title, "Introducing workspace agents");
    assert!(
        it.text.contains("repeatable tasks"),
        "og:description is the text: {:?}",
        it.text
    );
    assert_eq!(it.url, format!("{}/news/{NEW_SLUG}", server.uri()));
    assert_eq!(it.published_at, None);
    assert_eq!(it.first_seen_at, now());
    assert_eq!(it.class, SourceClass::FirstParty);
    assert_eq!(
        outcome(&out, "anthropic-news"),
        &SourceOutcome::Ok { new: 1 }
    );
    assert_eq!(
        count_requests(&server, "/news/").await,
        1,
        "only the new article is opened"
    );
}

#[tokio::test]
async fn h2_1_a_failed_fetch_between_does_not_lose_the_new_item() {
    let server = MockServer::start().await;
    mount_news(&server, &index_without(&[NEW_SLUG])).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    serve_status(&server, "/news", 500, "boom").await;
    let failed = run(&cfg, dir.path(), window(), ts("2026-10-24T18:00:00Z")).await;
    assert_eq!(failure(&failed, "anthropic-news"), "HTTP 500");
    assert!(failed.items.is_empty());

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(ids(&out), [format!("anthropic-news:{NEW_SLUG}")]);
}

#[tokio::test]
async fn h2_1_an_item_first_seen_before_a_failed_fetch_is_still_offered_and_keeps_its_first_seen_time(
) {
    let server = MockServer::start().await;
    mount_news(&server, &index_without(&[NEW_SLUG])).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let seen = run(&cfg, dir.path(), window(), now()).await;
    assert_eq!(ids(&seen), [format!("anthropic-news:{NEW_SLUG}")]);

    server.reset().await;
    serve_status(&server, "/news", 503, "").await;
    let failed = run(&cfg, dir.path(), window(), ts("2026-10-25T18:00:00Z")).await;
    assert_eq!(failure(&failed, "anthropic-news"), "HTTP 503");
    assert_eq!(
        ids(&failed),
        [format!("anthropic-news:{NEW_SLUG}")],
        "a bad day at the source loses nothing"
    );

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let later = run(&cfg, dir.path(), window(), ts("2026-10-26T12:00:00Z")).await;
    assert_eq!(ids(&later), [format!("anthropic-news:{NEW_SLUG}")]);
    assert_eq!(later.items[0].first_seen_at, now());
}

#[tokio::test]
async fn h2_1_refetching_later_with_the_same_window_still_offers_the_item_with_a_stable_first_seen_time(
) {
    let server = MockServer::start().await;
    mount_news(&server, &index_without(&[NEW_SLUG])).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let first = run(&cfg, dir.path(), window(), now()).await;
    assert_eq!(first.items[0].first_seen_at, now());

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let again = run(&cfg, dir.path(), window(), ts("2026-10-27T09:30:00Z")).await;

    assert_eq!(ids(&again), [format!("anthropic-news:{NEW_SLUG}")]);
    assert_eq!(
        again.items[0].first_seen_at,
        now(),
        "first_seen_at never moves"
    );
    assert_eq!(
        count_requests(&server, "/news/").await,
        0,
        "a known article is not opened again"
    );
}

#[tokio::test]
async fn h2_1_a_first_read_that_failed_does_not_count_as_the_baseline() {
    let server = MockServer::start().await;
    serve_status(&server, "/news", 500, "").await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    let failed = run(&cfg, dir.path(), window(), earlier()).await;
    assert_eq!(failure(&failed, "anthropic-news"), "HTTP 500");

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert!(
        out.items.is_empty(),
        "the first successful read is the baseline: {:?}",
        ids(&out)
    );
    assert_eq!(count_requests(&server, "/news/").await, 0);
}

#[tokio::test]
async fn h2_1_at_most_ten_articles_are_opened_per_run_and_the_rest_wait_for_the_next() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    mount_news(&server, &fixture("news-index.html")).await;
    run(&cfg, dir.path(), window(), earlier()).await;

    let fifteen: String = (1..=15)
        .map(|n| format!("<li><a href=\"/news/story-{n:02}\">Story {n}</a></li>\n"))
        .collect();
    let index = fixture("news-index.html").replace("<ul>\n", &format!("<ul>\n{fifteen}"));
    remount_stories(&server, &index).await;
    let second = run(&cfg, dir.path(), window(), now()).await;
    assert_eq!(
        count_requests(&server, "/news/").await,
        10,
        "T1: no more than 10 article fetches"
    );
    assert_eq!(second.items.len(), 10);
    assert!(second.items.iter().all(|i| i.title == "A story"));

    remount_stories(&server, &index).await;
    let third = run(&cfg, dir.path(), window(), ts("2026-10-25T13:00:00Z")).await;
    assert_eq!(
        count_requests(&server, "/news/").await,
        5,
        "the deferred five are read next time"
    );
    assert_eq!(third.items.len(), 15);
}

#[tokio::test]
async fn h2_1_an_unreadable_article_still_lists_the_link_and_does_not_fail_the_source() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    serve(&server, "/news", index_without(&[NEW_SLUG])).await;
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    serve(&server, "/news", fixture("news-index.html")).await;
    serve_status(&server, &format!("/news/{NEW_SLUG}"), 404, "").await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(
        outcome(&out, "anthropic-news"),
        &SourceOutcome::Ok { new: 1 }
    );
    let it = item(&out, &format!("anthropic-news:{NEW_SLUG}"));
    assert!(!it.title.is_empty());
    assert_eq!(it.url, format!("{}/news/{NEW_SLUG}", server.uri()));
}

#[tokio::test]
async fn h2_1_two_new_links_are_both_offered_with_their_own_titles() {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[news_src(&server.uri())]);
    mount_news(&server, &index_without(&[NEW_SLUG, OTHER_NEW_SLUG])).await;
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_news(&server, &fixture("news-index.html")).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(out.items.len(), 2);
    assert_eq!(
        item(&out, &format!("anthropic-news:{NEW_SLUG}")).title,
        "Introducing workspace agents"
    );
    assert_eq!(
        item(&out, &format!("anthropic-news:{OTHER_NEW_SLUG}")).title,
        "Open-sourcing our evaluation harness"
    );
}

/// Reset the server and serve `index` plus an article page for every `story-NN`.
async fn remount_stories(server: &MockServer, index: &str) {
    server.reset().await;
    serve(server, "/news", index).await;
    Mock::given(method("GET"))
        .and(path_regex(r"^/news/story-\d+$"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            r#"<meta property="og:title" content="A story"><meta property="og:description" content="Details.">"#,
        ))
        .mount(server)
        .await;
}

// ── H2-2: the changelog, dated through npm ───────────────────────────────────

#[tokio::test]
async fn h2_2_the_eight_versions_in_the_window_are_returned_with_their_full_entries() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    let expected: Vec<String> = (303..=310)
        .rev()
        .map(|v| format!("claude-code-changelog:2.1.{v}"))
        .collect();
    assert_eq!(
        ids(&out),
        expected,
        "eight versions, newest first; 2.1.302 and 2.1.301 are before the window"
    );
    assert_eq!(
        outcome(&out, "claude-code-changelog"),
        &SourceOutcome::Ok { new: 8 }
    );
    for it in &out.items {
        let version = it.id.rsplit(':').next().unwrap();
        assert_eq!(it.class, SourceClass::FirstParty);
        for line in changelog_lines(version) {
            assert!(it.text.contains(&line), "{} is missing {line:?}", it.id);
        }
    }
}

#[tokio::test]
async fn h2_2_a_deep_added_line_survives_in_its_version() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    let it = item(&out, "claude-code-changelog:2.1.303");
    assert!(
        it.text.contains("- Added the `--quiet-hours` flag to silence desktop notifications between two clock times"),
        "{:?}",
        it.text
    );
}

#[tokio::test]
async fn h2_2_versions_take_their_dates_from_the_npm_time_map() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(
        item(&out, "claude-code-changelog:2.1.310").published_at,
        Some(ts("2026-10-23T21:20:46Z"))
    );
    assert_eq!(
        item(&out, "claude-code-changelog:2.1.303").published_at,
        Some(ts("2026-10-19T08:14:02.311Z"))
    );
}

#[tokio::test]
async fn h2_2_a_versions_link_is_the_configured_page_plus_githubs_heading_anchor() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    let it = item(&out, "claude-code-changelog:2.1.303");
    assert_eq!(
        it.url,
        format!("{}/blob/main/CHANGELOG.md#21303", server.uri())
    );
    assert!(it.url.ends_with("#21303"));
}

#[tokio::test]
async fn h2_2_a_version_npm_does_not_know_yet_is_dated_by_when_it_was_first_seen() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    let with_new = fixture("CHANGELOG.md").replacen(
        "## 2.1.310",
        "## 2.1.311\n\n- Fixed the session list showing a blank title for brand-new sessions\n\n## 2.1.310",
        1,
    );
    server.reset().await;
    mount_changelog(&server, &with_new, Some(&fixture("npm-registry.json"))).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(out.items.len(), 9, "{:?}", ids(&out));
    let new = item(&out, "claude-code-changelog:2.1.311");
    assert_eq!(new.published_at, None);
    assert_eq!(new.first_seen_at, now());
    assert!(new.text.contains("blank title"));
}

#[tokio::test]
async fn h2_2_a_version_npm_lacked_on_the_very_first_read_is_baseline_until_npm_dates_it() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&registry_without("2.1.310")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let first = run(&cfg, dir.path(), window(), earlier()).await;
    assert_eq!(
        first.items.len(),
        7,
        "undated 2.1.310 is baseline on the first read: {:?}",
        ids(&first)
    );
    assert!(!ids(&first).contains(&"claude-code-changelog:2.1.310"));

    server.reset().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let second = run(&cfg, dir.path(), window(), now()).await;
    assert_eq!(
        second.items.len(),
        8,
        "once npm dates it, it is judged by that date"
    );
    assert_eq!(
        item(&second, "claude-code-changelog:2.1.310").published_at,
        Some(ts("2026-10-23T21:20:46Z"))
    );
}

#[tokio::test]
async fn h2_2_an_npm_outage_does_not_hide_the_changelog() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_changelog(&server, &fixture("CHANGELOG.md"), None).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert!(
        !matches!(
            outcome(&out, "claude-code-changelog"),
            SourceOutcome::Failed { .. }
        ),
        "the changelog is fine, only npm is down: {:?}",
        outcome(&out, "claude-code-changelog")
    );
    for v in 303..=310 {
        let id = format!("claude-code-changelog:2.1.{v}");
        assert!(
            ids(&out).contains(&id.as_str()),
            "{id} lost during an npm outage"
        );
    }
}

#[tokio::test]
async fn h2_2_an_npm_outage_does_not_bring_back_versions_older_than_the_window() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        &fixture("CHANGELOG.md"),
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    mount_changelog(&server, &fixture("CHANGELOG.md"), None).await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    // 2.1.302 (Oct 10) and 2.1.301 (Oct 8) were dated by npm on the first read.
    // Losing npm for a day must not make them look new.
    let stale: Vec<&str> = ids(&out)
        .into_iter()
        .filter(|i| i.ends_with("2.1.302") || i.ends_with("2.1.301"))
        .collect();
    assert!(
        stale.is_empty(),
        "pre-window versions came back as new: {stale:?}"
    );
}

#[tokio::test]
async fn h2_2_with_npm_down_on_the_very_first_read_nothing_is_offered() {
    let server = MockServer::start().await;
    mount_changelog(&server, &fixture("CHANGELOG.md"), None).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert!(out.items.is_empty());
    assert_eq!(
        outcome(&out, "claude-code-changelog"),
        &SourceOutcome::Quiet
    );
}

#[tokio::test]
async fn h2_2_a_changelog_without_version_headings_fails_plainly() {
    let server = MockServer::start().await;
    mount_changelog(
        &server,
        "<html><body>SECRET-PAGE Sign in to continue</body></html>",
        Some(&fixture("npm-registry.json")),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[changelog_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(
        failure(&out, "claude-code-changelog"),
        "could not parse changelog"
    );
}

// ── H2-3: release notes, dated by day ────────────────────────────────────────

async fn notes_fixture() -> (MockServer, SourcesConfig) {
    let server = MockServer::start().await;
    serve(
        &server,
        "/en/release-notes/overview.md",
        fixture("release-notes.md"),
    )
    .await;
    let c = cfg(&[notes_src(&server.uri())]);
    (server, c)
}

#[tokio::test]
async fn h2_3_a_window_over_three_days_returns_each_days_bullets_and_not_the_older_day() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    let day = |d: &str| {
        out.items
            .iter()
            .filter(|i| {
                i.published_at
                    .map(|p| p.format("%Y-%m-%d").to_string())
                    .as_deref()
                    == Some(d)
            })
            .count()
    };
    assert_eq!(day("2026-10-22"), 2);
    assert_eq!(
        day("2026-10-21"),
        1,
        "a bullet with a nested sub-bullet is one item"
    );
    assert_eq!(day("2026-10-20"), 2);
    assert_eq!(
        out.items.len(),
        5,
        "the October 9 bullet is before the window: {:?}",
        ids(&out)
    );
    assert!(out
        .items
        .iter()
        .all(|i| i.id.starts_with("claude-docs-release-notes:")));
    assert!(out.items.iter().all(|i| i.class == SourceClass::FirstParty));
}

#[tokio::test]
async fn h2_3_item_ids_are_stable_and_unique_across_fetches() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let first = run(&cfg, dir.path(), window(), earlier()).await;
    let second = run(&cfg, dir.path(), window(), now()).await;

    let mut a: Vec<&str> = ids(&first);
    let mut b: Vec<&str> = ids(&second);
    a.sort_unstable();
    b.sort_unstable();
    assert_eq!(a, b, "the same bullets get the same ids on every fetch");
    let mut unique = b.clone();
    unique.dedup();
    assert_eq!(unique.len(), b.len(), "ids are unique");
}

#[tokio::test]
async fn h2_3_a_dated_day_publishes_at_the_end_of_that_day_and_results_are_newest_first() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    let times: Vec<_> = out.items.iter().map(|i| i.published_at.unwrap()).collect();
    assert_eq!(times[0], ts("2026-10-22T23:59:59Z"));
    assert!(
        times.windows(2).all(|w| w[0] >= w[1]),
        "newest first: {times:?}"
    );
    // A window that opens at noon on the 22nd still sees that day's bullets.
    let later = run(&cfg, dir.path(), ts("2026-10-22T12:00:00Z"), now()).await;
    assert_eq!(later.items.len(), 2);
}

#[tokio::test]
async fn h2_3_bullet_links_resolve_to_absolute_urls_and_nested_text_stays_with_its_bullet() {
    let (server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    let relative = format!("{}/en/docs/build-with-claude/files", server.uri());
    assert!(
        out.items
            .iter()
            .any(|i| i.url == relative || i.outbound_links.contains(&relative)),
        "the relative link should resolve against the page"
    );
    assert!(out
        .items
        .iter()
        .any(|i| i.url == "https://example.com/guides/batch-mode"));
    let nested = out
        .items
        .iter()
        .find(|i| i.text.contains("Projects can be filtered by label"))
        .unwrap();
    assert!(nested.text.contains("per-project breakdowns"));
}

// ── H2-4: quiet is not failed ────────────────────────────────────────────────

#[tokio::test]
async fn h2_4_a_source_with_nothing_in_the_window_is_quiet_not_failed() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), ts("2026-10-26T00:00:00Z"), now()).await;

    assert!(out.items.is_empty());
    assert_eq!(
        outcome(&out, "claude-docs-release-notes"),
        &SourceOutcome::Quiet
    );
}

#[tokio::test]
async fn h2_4_a_source_with_items_in_the_window_reports_how_many() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(
        outcome(&out, "claude-docs-release-notes"),
        &SourceOutcome::Ok { new: 5 }
    );
}

#[tokio::test]
async fn h2_4_an_empty_but_valid_feed_is_quiet() {
    let server = MockServer::start().await;
    serve(
        &server,
        "/empty.xml",
        r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Quiet blog</title><id>https://quiet.example.test/</id><updated>2026-10-01T00:00:00Z</updated></feed>"#,
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[feed_src(
        "quiet-blog",
        "curated",
        &format!("{}/empty.xml", server.uri()),
    )]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(outcome(&out, "quiet-blog"), &SourceOutcome::Quiet);
}

#[tokio::test]
async fn h2_4_a_github_source_whose_only_release_in_reach_is_a_draft_or_old_is_quiet() {
    let server = MockServer::start().await;
    mount_github(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[github_src(&server.uri())]);

    let out = run(&cfg, dir.path(), ts("2026-10-23T00:00:00Z"), now()).await;

    assert_eq!(outcome(&out, "agent-sdk-releases"), &SourceOutcome::Quiet);
}

// ── H2-5: one bad source never hurts another ─────────────────────────────────

#[tokio::test]
async fn h2_5_a_timeout_a_garbage_body_and_a_server_error_each_fail_alone_with_plain_reasons() {
    let server = MockServer::start().await;
    let base = server.uri();
    serve(&server, "/good-atom.xml", fixture("atom.xml")).await;
    Mock::given(method("GET"))
        .and(path("/slow.xml"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(fixture("rss.xml"))
                .set_delay(Duration::from_secs(5)),
        )
        .mount(&server)
        .await;
    serve(
        &server,
        "/garbage.xml",
        "<html><body>SECRET-BODY-TEXT this is a login page</body></html>",
    )
    .await;
    serve_status(
        &server,
        "/broken.xml",
        500,
        "SECRET-BODY-TEXT internal error trace",
    )
    .await;
    serve(&server, "/good-rss.xml", fixture("rss.xml")).await;
    let cfg = cfg(&[
        feed_src("good-atom", "curated", &format!("{base}/good-atom.xml")),
        feed_src("slow-feed", "curated", &format!("{base}/slow.xml")),
        feed_src("garbage-feed", "curated", &format!("{base}/garbage.xml")),
        feed_src("broken-feed", "curated", &format!("{base}/broken.xml")),
        feed_src("good-rss", "curated", &format!("{base}/good-rss.xml")),
    ]);
    let dir = tempfile::tempdir().unwrap();
    let short = HttpClient::new(limits(1, 1024 * 1024), None);

    let started = Instant::now();
    let out = fetch_all(&cfg, dir.path(), window(), now(), &short).await;
    let took = started.elapsed();

    let order: Vec<&str> = out.statuses.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(
        order,
        [
            "good-atom",
            "slow-feed",
            "garbage-feed",
            "broken-feed",
            "good-rss"
        ],
        "sources.toml order"
    );
    assert_eq!(failure(&out, "slow-feed"), "timed out");
    assert_eq!(failure(&out, "garbage-feed"), "could not parse feed");
    assert_eq!(failure(&out, "broken-feed"), "HTTP 500");
    assert_eq!(outcome(&out, "good-atom"), &SourceOutcome::Ok { new: 2 });
    assert_eq!(outcome(&out, "good-rss"), &SourceOutcome::Ok { new: 1 });
    assert!(ids(&out).iter().any(|i| i.starts_with("good-atom:")));
    assert!(ids(&out).iter().any(|i| i.starts_with("good-rss:")));
    assert!(
        took < Duration::from_secs(4),
        "a slow source is cut off at its limit, took {took:?}"
    );

    for id in ["slow-feed", "garbage-feed", "broken-feed"] {
        let reason = failure(&out, id);
        assert!(
            !reason.contains("SECRET"),
            "{id}: reason leaks the body: {reason}"
        );
        assert!(
            !reason.contains("127.0.0.1") && !reason.contains("http"),
            "{id}: reason leaks the URL: {reason}"
        );
    }
}

#[tokio::test]
async fn h2_5_a_body_over_the_cap_fails_as_too_large_without_hurting_the_others() {
    let server = MockServer::start().await;
    let big = format!(
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>{}</channel></rss>",
        "<!-- padding -->".repeat(1000)
    );
    serve(&server, "/big.xml", big).await;
    serve(&server, "/small.xml", fixture("rss.xml")).await;
    let cfg = cfg(&[
        feed_src("big-feed", "curated", &format!("{}/big.xml", server.uri())),
        feed_src(
            "small-feed",
            "curated",
            &format!("{}/small.xml", server.uri()),
        ),
    ]);
    let dir = tempfile::tempdir().unwrap();
    let capped = HttpClient::new(limits(10, 4096), None);

    let out = fetch_all(&cfg, dir.path(), window(), now(), &capped).await;

    assert_eq!(failure(&out, "big-feed"), "response too large");
    assert_eq!(outcome(&out, "small-feed"), &SourceOutcome::Ok { new: 1 });
}

#[tokio::test]
async fn h2_5_a_failed_source_still_returns_what_it_gave_on_its_last_good_read() {
    let server = MockServer::start().await;
    serve(&server, "/atom.xml", fixture("atom.xml")).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[feed_src(
        ATOM_ID,
        "curated",
        &format!("{}/atom.xml", server.uri()),
    )]);
    let good = run(&cfg, dir.path(), window(), earlier()).await;
    assert_eq!(good.items.len(), 2);

    server.reset().await;
    serve_status(&server, "/atom.xml", 500, "").await;
    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(failure(&out, ATOM_ID), "HTTP 500");
    assert_eq!(ids(&out), ids(&good));
}

#[tokio::test]
async fn h2_5_a_server_that_is_down_fails_as_could_not_connect_without_naming_the_address() {
    let server = MockServer::start().await;
    let url = format!("{}/atom.xml", server.uri());
    drop(server);
    let cfg = cfg(&[feed_src(ATOM_ID, "curated", &url)]);
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    let reason = failure(&out, ATOM_ID);
    assert!(!reason.is_empty());
    assert!(
        !reason.contains("127.0.0.1") && !reason.contains("http"),
        "{reason}"
    );
}

// ── H2-6: the same release from three sources is one cluster ─────────────────

#[tokio::test]
async fn h2_6_a_release_its_blog_post_and_its_hn_story_cluster_with_the_release_as_primary() {
    let server = MockServer::start().await;
    mount_world(&server, &fixture("news-index.html")).await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&world_cfg(&server.uri()), dir.path(), window(), now()).await;
    for s in &out.statuses {
        assert!(!matches!(s.outcome, SourceOutcome::Failed { .. }), "{s:?}");
    }
    let clusters = cluster(&out.items);

    let gh = "agent-sdk-releases:v3.4.0";
    let c = clusters
        .iter()
        .find(|c| c.items.iter().any(|i| i.id == gh))
        .expect("the release is in a cluster");
    assert_eq!(c.primary().id, gh, "the first-party release leads");
    assert_eq!(c.primary().url, GH_URL);
    let also: Vec<&str> = c.also_covered_by().iter().map(|i| i.id.as_str()).collect();
    assert_eq!(
        also,
        [ATOM_RELEASE_POST, "hn-front-page:9001"],
        "the blog, then the aggregator"
    );
}

#[tokio::test]
async fn h2_6_unrelated_stories_stay_in_their_own_clusters() {
    let server = MockServer::start().await;
    mount_world(&server, &fixture("news-index.html")).await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&world_cfg(&server.uri()), dir.path(), window(), now()).await;
    let clusters = cluster(&out.items);

    for id in [
        "hn-front-page:9004",
        "hn-front-page:9002",
        "simon-willison:https://linkblog.example.test/2026/Oct/21/sqlite-wal-notes/",
        "latent-space:post-1001",
    ] {
        let c = clusters
            .iter()
            .find(|c| c.items.iter().any(|i| i.id == id))
            .unwrap_or_else(|| panic!("{id} is missing from the items: {:?}", ids(&out)));
        assert_eq!(
            c.items.len(),
            1,
            "{id} should stand alone, got {:?}",
            c.items.iter().map(|i| &i.id).collect::<Vec<_>>()
        );
    }
}

#[tokio::test]
async fn h2_6_entries_of_one_source_sharing_a_page_never_merge() {
    let server = MockServer::start().await;
    mount_world(&server, &fixture("news-index.html")).await;
    let dir = tempfile::tempdir().unwrap();

    let out = run(&world_cfg(&server.uri()), dir.path(), window(), now()).await;
    let clusters = cluster(&out.items);

    for it in out.items.iter().filter(|i| {
        i.source_id == "claude-code-changelog" || i.source_id == "claude-docs-release-notes"
    }) {
        let c = clusters
            .iter()
            .find(|c| c.items.iter().any(|m| m.id == it.id))
            .unwrap();
        assert_eq!(
            c.items.len(),
            1,
            "{} merged with {:?}",
            it.id,
            c.items.iter().map(|i| &i.id).collect::<Vec<_>>()
        );
    }
}

// ── H2-7: sources.toml ───────────────────────────────────────────────────────

#[test]
fn h2_7_the_default_sources_load_without_warnings_and_hn_is_off() {
    let (cfg, warnings) = load(default_toml());

    assert!(warnings.is_empty(), "{warnings:?}");
    let have: Vec<&str> = cfg.sources.iter().map(|s| s.id.as_str()).collect();
    for want in [
        "claude-code-changelog",
        "claude-docs-release-notes",
        "anthropic-news",
        "mcp-spec-releases",
        "agent-sdk-python",
        "agent-sdk-typescript",
        "simon-willison",
        "latent-space",
        "hn-front-page",
    ] {
        assert!(
            have.contains(&want),
            "default sources lack {want}: {have:?}"
        );
    }
    let hn = cfg
        .sources
        .iter()
        .find(|s| s.id == "hn-front-page")
        .unwrap();
    assert!(!hn.enabled);
    assert_eq!(hn.kind, SourceKind::HnFrontPage);
    assert!(cfg
        .sources
        .iter()
        .filter(|s| s.id != "hn-front-page")
        .all(|s| s.enabled));
}

#[test]
fn h2_7_the_defaults_say_what_is_first_party() {
    let (cfg, _) = load(default_toml());

    let class = |id: &str| cfg.sources.iter().find(|s| s.id == id).unwrap().class;
    assert_eq!(class("claude-code-changelog"), SourceClass::FirstParty);
    assert_eq!(class("anthropic-news"), SourceClass::FirstParty);
    assert_eq!(class("simon-willison"), SourceClass::Curated);
    assert_eq!(class("hn-front-page"), SourceClass::Aggregator);
}

#[test]
fn h2_7_an_entry_with_an_unknown_kind_is_skipped_by_name_and_the_rest_load() {
    let text = r#"
[[source]]
id = "mystery"
kind = "carrier-pigeon"
url = "https://example.test/x"

[[source]]
id = "fine"
kind = "feed"
url = "https://example.test/feed.xml"
"#;

    let (cfg, warnings) = load(text);

    let have: Vec<&str> = cfg.sources.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(have, ["fine"]);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(
        warnings[0].contains("mystery"),
        "the warning names the source: {}",
        warnings[0]
    );
    assert!(
        !warnings[0].contains("carrier-pigeon"),
        "never the offending value: {}",
        warnings[0]
    );
}

#[test]
fn h2_7_an_id_that_could_climb_out_of_the_state_directory_is_rejected() {
    let text = r#"
[[source]]
id = "../x"
kind = "feed"
url = "https://example.test/feed.xml"

[[source]]
id = "fine"
kind = "feed"
url = "https://example.test/feed.xml"
"#;

    let (cfg, warnings) = load(text);

    let have: Vec<&str> = cfg.sources.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(have, ["fine"]);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
}

#[tokio::test]
async fn h2_7_a_disabled_source_is_never_requested() {
    let server = MockServer::start().await;
    mount_hn(&server).await;
    serve(&server, "/atom.xml", fixture("atom.xml")).await;
    let text = format!(
        "{}\n{}",
        hn_src(&server.uri()).replace(
            "class = \"aggregator\"",
            "class = \"aggregator\"\nenabled = false"
        ),
        feed_src(ATOM_ID, "curated", &format!("{}/atom.xml", server.uri())),
    );
    let cfg = cfg(&[text]);
    let dir = tempfile::tempdir().unwrap();

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(out.statuses.len(), 1, "one status per enabled source");
    assert_eq!(count_requests(&server, "/v0/").await, 0);
}

// ── H2-8: GET only (T1, T2) ──────────────────────────────────────────────────

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let p = entry.unwrap().path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|e| e == "rs") {
            out.push(p);
        }
    }
}

#[test]
fn h2_8_nothing_in_the_sources_tree_can_send_anything_but_a_get() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/huey/sources");
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    assert!(
        files.len() >= 10,
        "the walk should find the source adapters, found {}",
        files.len()
    );
    let needles: Vec<String> = ["post", "put", "patch", "delete", "request"]
        .iter()
        .map(|verb| format!(".{verb}("))
        .collect();

    for f in files {
        let text = std::fs::read_to_string(&f).unwrap();
        for n in &needles {
            assert!(!text.contains(n.as_str()), "{} contains `{n}`", f.display());
        }
    }
}

#[tokio::test]
async fn h2_8_every_request_in_a_full_multi_source_fetch_is_a_get_with_the_fixed_user_agent() {
    let server = MockServer::start().await;
    let cfg = world_cfg(&server.uri());
    let dir = tempfile::tempdir().unwrap();
    let mut seen: Vec<Request> = Vec::new();

    mount_world(&server, &index_without(&[NEW_SLUG])).await;
    run(&cfg, dir.path(), window(), earlier()).await;
    seen.extend(requests(&server).await);

    // A second run, with a new article to open, so every kind of request is made.
    server.reset().await;
    mount_world(&server, &fixture("news-index.html")).await;
    let out = run(&cfg, dir.path(), window(), now()).await;
    seen.extend(requests(&server).await);

    for s in &out.statuses {
        assert!(!matches!(s.outcome, SourceOutcome::Failed { .. }), "{s:?}");
    }
    let paths: Vec<&str> = seen.iter().map(|r| r.url.path()).collect();
    for expected in [
        "/changelog/CHANGELOG.md",
        "/npm/claude-code",
        "/en/release-notes/overview.md",
        "/news",
        "/news/introducing-workspace-agents",
        "/repos/example-org/agent-sdk/releases",
        "/atom.xml",
        "/rss.xml",
        "/v0/topstories.json",
        "/v0/item/9001.json",
    ] {
        assert!(
            paths.contains(&expected),
            "never requested {expected}: {paths:?}"
        );
    }
    let ua = format!(
        "Nostromo-Huey/{} (+https://github.com/thehammer/nostromo)",
        env!("CARGO_PKG_VERSION")
    );
    for r in &seen {
        assert_eq!(r.method.as_str(), "GET", "{}", r.url);
        assert_eq!(
            r.headers.get("user-agent").and_then(|v| v.to_str().ok()),
            Some(ua.as_str()),
            "{}",
            r.url
        );
        assert!(r.body.is_empty(), "{} carried a body", r.url);
        assert!(
            r.headers.get("authorization").is_none(),
            "no credentials without a token: {}",
            r.url
        );
    }
}

// ── Conditional GET ──────────────────────────────────────────────────────────

#[tokio::test]
async fn a_feed_that_answers_304_to_if_none_match_still_yields_its_earlier_items() {
    let server = MockServer::start().await;
    serve_with_etag(&server, "/atom.xml", &fixture("atom.xml"), "\"v1\"").await;
    let cfg = cfg(&[feed_src(
        ATOM_ID,
        "curated",
        &format!("{}/atom.xml", server.uri()),
    )]);
    let dir = tempfile::tempdir().unwrap();

    let first = run(&cfg, dir.path(), window(), earlier()).await;
    let second = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(first.items.len(), 2);
    assert_eq!(ids(&second), ids(&first), "a 304 loses nothing");
    assert_eq!(outcome(&second, ATOM_ID), &SourceOutcome::Ok { new: 2 });
    let reqs = requests(&server).await;
    assert_eq!(reqs.len(), 2);
    assert!(reqs[0].headers.get("if-none-match").is_none());
    assert_eq!(
        reqs[1]
            .headers
            .get("if-none-match")
            .and_then(|v| v.to_str().ok()),
        Some("\"v1\""),
        "the validator the server sent is sent back"
    );
}

#[tokio::test]
async fn an_undated_item_first_seen_earlier_survives_a_304_on_the_index() {
    let server = MockServer::start().await;
    let cfg = cfg(&[news_src(&server.uri())]);
    let dir = tempfile::tempdir().unwrap();
    serve_with_etag(&server, "/news", &index_without(&[NEW_SLUG]), "\"a1\"").await;
    run(&cfg, dir.path(), window(), earlier()).await;

    server.reset().await;
    serve_with_etag(&server, "/news", &fixture("news-index.html"), "\"b1\"").await;
    for slug in [NEW_SLUG, OTHER_NEW_SLUG] {
        serve(
            &server,
            &format!("/news/{slug}"),
            fixture(&format!("article-{slug}.html")),
        )
        .await;
    }
    let seen = run(&cfg, dir.path(), window(), now()).await;
    assert_eq!(seen.items.len(), 1);

    let again = run(&cfg, dir.path(), window(), ts("2026-10-25T15:00:00Z")).await;

    assert_eq!(
        ids(&again),
        ids(&seen),
        "the 304 reply carries no body, the item must not be lost"
    );
    assert_eq!(again.items[0].first_seen_at, now());
    assert_eq!(
        count_requests(&server, "/news/").await,
        1,
        "the article was opened once, not again after the 304"
    );
}

/// Answers 304 to a matching If-None-Match, else 200 with the ETag.
async fn serve_with_etag(server: &MockServer, p: &str, body: &str, etag: &str) {
    Mock::given(method("GET"))
        .and(path(p))
        .and(header("if-none-match", etag))
        .respond_with(ResponseTemplate::new(304))
        .with_priority(1)
        .mount(server)
        .await;
    Mock::given(method("GET"))
        .and(path(p))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("etag", etag)
                .set_body_string(body),
        )
        .with_priority(5)
        .mount(server)
        .await;
}

// ── GitHub releases and Hacker News ──────────────────────────────────────────

#[tokio::test]
async fn github_releases_skip_drafts_and_keep_the_notes_and_links() {
    let server = MockServer::start().await;
    mount_github(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[github_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    assert_eq!(
        ids(&out),
        ["agent-sdk-releases:v3.4.0"],
        "the draft is skipped; v3.3.2 is before the window"
    );
    let it = &out.items[0];
    assert_eq!(it.url, GH_URL);
    assert_eq!(it.published_at, Some(ts("2026-10-22T15:00:00Z")));
    assert!(it.text.contains("Added streaming for tool results"));
    assert!(it
        .outbound_links
        .iter()
        .any(|l| l == "https://github.com/example-org/agent-sdk/pull/412"));
}

#[tokio::test]
async fn hn_skips_dead_stories_and_points_ask_hn_at_its_discussion() {
    let server = MockServer::start().await;
    mount_hn(&server).await;
    let dir = tempfile::tempdir().unwrap();
    let cfg = cfg(&[hn_src(&server.uri())]);

    let out = run(&cfg, dir.path(), window(), now()).await;

    let mut have = ids(&out);
    have.sort_unstable();
    assert_eq!(
        have,
        [
            "hn-front-page:9001",
            "hn-front-page:9002",
            "hn-front-page:9004"
        ],
        "9003 is dead"
    );
    assert_eq!(item(&out, "hn-front-page:9001").url, GH_URL);
    assert_eq!(
        item(&out, "hn-front-page:9002").url,
        "https://news.ycombinator.com/item?id=9002"
    );
    assert_eq!(
        item(&out, "hn-front-page:9001").published_at,
        Some(ts("2026-10-23T09:00:00Z"))
    );
    assert!(out.items.iter().all(|i| i.class == SourceClass::Aggregator));
}

// ── The daily pool ───────────────────────────────────────────────────────────

fn day(y: i32, m: u32, d: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, d).unwrap()
}

#[tokio::test]
async fn a_saved_pool_loads_back_unchanged_and_a_missing_day_loads_as_nothing() {
    let (_server, cfg) = notes_fixture().await;
    let dir = tempfile::tempdir().unwrap();
    let out = run(&cfg, dir.path(), window(), now()).await;
    let pool = dir.path().join("pool");

    save_pool(&pool, day(2026, 10, 25), &out).unwrap();

    assert_eq!(load_pool(&pool, day(2026, 10, 25)), Some(out));
    assert_eq!(load_pool(&pool, day(2026, 10, 24)), None);
}

#[test]
fn pruning_removes_pools_older_than_the_keep_window_and_leaves_other_files_alone() {
    let dir = tempfile::tempdir().unwrap();
    let pool = dir.path();
    for d in ["2026-10-01", "2026-10-17", "2026-10-18", "2026-10-25"] {
        std::fs::write(pool.join(format!("{d}.json")), "{}").unwrap();
    }
    std::fs::write(pool.join("notes.json"), "keep me").unwrap();

    let removed = prune_pool(pool, day(2026, 10, 25), 7);

    assert_eq!(removed, 2, "Oct 1 and Oct 17 are more than 7 days old");
    assert!(!pool.join("2026-10-01.json").exists());
    assert!(!pool.join("2026-10-17.json").exists());
    assert!(
        pool.join("2026-10-18.json").exists(),
        "exactly 7 days old is kept"
    );
    assert!(pool.join("2026-10-25.json").exists());
    assert!(pool.join("notes.json").exists());
}
