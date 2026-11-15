//! The Jira site's project list, kept fresh for ticket-key detection.
//!
//! Fetched once at daemon start and every [`REFRESH_EVERY`], through the
//! existing [`JiraProvider`] (the token never leaves it). A failed refresh keeps
//! the last good list. Keys only are persisted to `jira-projects.json` under the
//! Perri state dir, so a restart with no network still knows the list.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use tracing::{debug, info, warn};

use super::jira::JiraProvider;
use super::TicketProvider;
use crate::data::ticket_keys::{ProjectFilter, TicketScope};

/// How often the list is refreshed.
pub const REFRESH_EVERY: Duration = Duration::from_secs(6 * 60 * 60);

/// File name under the Perri state dir.
pub const CACHE_FILE: &str = "jira-projects.json";

/// Build the detection scope and, when credentials resolve, start the refresh
/// loop. With no site, `site` is `None` and nothing is detected; with a site but
/// no credentials the filter stays [`ProjectFilter::Unknown`] (or the persisted
/// list) and no request is ever made — logged once here, never per row.
pub fn spawn(provider: JiraProvider, site: Option<String>, path: PathBuf) -> TicketScope {
    let handle = Arc::new(RwLock::new(
        load(&path).map_or(ProjectFilter::Unknown, ProjectFilter::Known),
    ));
    let scope = TicketScope::new(site.clone(), Arc::clone(&handle));
    if site.is_none() {
        info!("perri tickets: no Jira site configured; ticket controls are off");
        return scope;
    }
    if !provider.is_configured() {
        info!("perri tickets: no Jira credentials; project list not fetched");
        return scope;
    }
    tokio::spawn(async move {
        loop {
            refresh_once(&provider, &handle, &path).await;
            tokio::time::sleep(REFRESH_EVERY).await;
        }
    });
    scope
}

/// One refresh. On success the shared filter and the cache file are replaced;
/// on failure both are left as they were. Returns whether it succeeded.
pub async fn refresh_once(
    provider: &JiraProvider,
    handle: &RwLock<ProjectFilter>,
    path: &Path,
) -> bool {
    match provider.project_keys().await {
        Ok(keys) => {
            let set: HashSet<String> = keys.into_iter().collect();
            debug!(
                projects = set.len(),
                "perri tickets: Jira project list refreshed"
            );
            save(path, &set);
            *handle.write().unwrap_or_else(|e| e.into_inner()) = ProjectFilter::Known(set);
            true
        }
        Err(e) => {
            warn!(
                "perri tickets: Jira project list refresh failed: {}",
                e.code()
            );
            false
        }
    }
}

/// The persisted keys, if the file exists and parses.
pub fn load(path: &Path) -> Option<HashSet<String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let keys: Vec<String> = serde_json::from_str(&text).ok()?;
    Some(keys.into_iter().collect())
}

fn save(path: &Path, keys: &HashSet<String>) {
    let mut sorted: Vec<&String> = keys.iter().collect();
    sorted.sort();
    let Ok(json) = serde_json::to_string(&sorted) else {
        return;
    };
    if let Err(e) = crate::data::perri_queue_native::write_json_atomic(path, &json) {
        debug!("perri tickets: could not persist the project list: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::tickets::jira::JiraCredentials;
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn provider(server: &MockServer) -> JiraProvider {
        JiraProvider::for_test(
            Some(JiraCredentials::for_test(
                "acme.atlassian.net",
                "me@acme.com",
                "tok",
            )),
            server.uri(),
        )
    }

    fn page(keys: &[&str], is_last: bool) -> ResponseTemplate {
        let values: Vec<_> = keys
            .iter()
            .map(|k| serde_json::json!({ "key": k }))
            .collect();
        ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "values": values, "isLast": is_last
        }))
    }

    #[tokio::test]
    async fn project_keys_pages_until_is_last() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/project/search"))
            .and(query_param("startAt", "0"))
            .and(query_param("maxResults", "50"))
            .respond_with(page(&["CORE", "PAYM"], false))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/rest/api/3/project/search"))
            .and(query_param("startAt", "2"))
            .respond_with(page(&["INT"], true))
            .expect(1)
            .mount(&server)
            .await;
        let keys = provider(&server).project_keys().await.unwrap();
        assert_eq!(keys, ["CORE", "PAYM", "INT"]);
    }

    #[tokio::test]
    async fn failed_refresh_keeps_the_last_good_list() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(CACHE_FILE);
        let handle = RwLock::new(ProjectFilter::Unknown);

        let good = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(page(&["CORE"], true))
            .mount(&good)
            .await;
        assert!(refresh_once(&provider(&good), &handle, &file).await);

        for status in [401u16, 500] {
            let bad = MockServer::start().await;
            Mock::given(method("GET"))
                .respond_with(ResponseTemplate::new(status))
                .mount(&bad)
                .await;
            assert!(!refresh_once(&provider(&bad), &handle, &file).await);
            let expected: HashSet<String> = ["CORE".to_owned()].into();
            assert_eq!(
                *handle.read().unwrap(),
                ProjectFilter::Known(expected.clone())
            );
            assert_eq!(load(&file), Some(expected));
        }
    }

    #[tokio::test]
    async fn cache_file_round_trips_across_a_restart_without_network() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(CACHE_FILE);
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(page(&["CORE", "APP"], true))
            .mount(&server)
            .await;
        let handle = RwLock::new(ProjectFilter::Unknown);
        assert!(refresh_once(&provider(&server), &handle, &file).await);

        // "Restart": no credentials, so no fetch, but the file is read.
        let scope = spawn(
            JiraProvider::for_test(None, "http://127.0.0.1:1".into()),
            Some("acme.atlassian.net".into()),
            file,
        );
        // CORE is known, ZZZZ is not.
        assert_eq!(scope.resolve("CORE-1 ZZZZ-2", "", &[]), ["CORE-1"]);
    }

    #[tokio::test]
    async fn no_credentials_means_unknown_and_no_request() {
        let server = MockServer::start().await;
        let dir = tempfile::tempdir().unwrap();
        let scope = spawn(
            JiraProvider::for_test(None, server.uri()),
            Some("acme.atlassian.net".into()),
            dir.path().join(CACHE_FILE),
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(server.received_requests().await.unwrap().is_empty());
        // Unknown: a title key still passes, a bare body key does not.
        let body = crate::data::ticket_keys::scan_body("mentions CORE-9");
        assert_eq!(scope.resolve("CORE-1", "", &body), ["CORE-1"]);
    }

    #[tokio::test]
    async fn no_site_detects_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let scope = spawn(
            JiraProvider::for_test(None, String::new()),
            None,
            dir.path().join(CACHE_FILE),
        );
        assert!(scope.resolve("CORE-1", "feature/CORE-2", &[]).is_empty());
    }
}
