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

/// First retry after a failed refresh; doubles per failure up to [`RETRY_MAX`].
pub const RETRY_BASE: Duration = Duration::from_secs(60);

/// The longest wait between retries after failures.
pub const RETRY_MAX: Duration = Duration::from_secs(30 * 60);

/// How long to wait after `failures` failures in a row (0 = last one succeeded).
pub fn next_delay(failures: u32) -> Duration {
    match failures {
        0 => REFRESH_EVERY,
        n => RETRY_BASE
            .saturating_mul(1u32 << (n - 1).min(10))
            .min(RETRY_MAX),
    }
}

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
        run_loop(|| refresh_once(&provider, &handle, &path)).await;
    });
    scope
}

/// Refresh forever: every [`REFRESH_EVERY`] after a success, sooner (bounded
/// backoff) after a failure so a bad start does not last six hours.
async fn run_loop<F, Fut>(mut refresh: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let mut failures = 0u32;
    loop {
        if refresh().await {
            failures = 0;
        } else {
            failures = failures.saturating_add(1);
        }
        tokio::time::sleep(next_delay(failures)).await;
    }
}

/// One refresh. On success the shared filter and the cache file are replaced;
/// on failure both are left as they were. An empty list counts as a failure.
/// Returns whether it succeeded.
pub async fn refresh_once(
    provider: &JiraProvider,
    handle: &RwLock<ProjectFilter>,
    path: &Path,
) -> bool {
    match provider.project_keys().await {
        Ok(keys) => {
            let set: HashSet<String> = keys.into_iter().collect();
            if set.is_empty() {
                warn!("perri tickets: Jira project list was empty; keeping the last list");
                return false;
            }
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

/// The persisted keys, if the file exists, parses and names at least one project.
/// An empty list is no cache: an old build could have saved one, and a `Known`
/// empty set would hide every ticket until a refresh succeeds.
pub fn load(path: &Path) -> Option<HashSet<String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let keys: Vec<String> = serde_json::from_str(&text).ok()?;
    (!keys.is_empty()).then(|| keys.into_iter().collect())
}

fn save(path: &Path, keys: &HashSet<String>) {
    let mut sorted: Vec<&String> = keys.iter().collect();
    sorted.sort();
    if let Err(e) = crate::mother::origin::write_private(path, &sorted) {
        debug!("perri tickets: could not persist the project list: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::tickets::jira::JiraCredentials;
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const TOKEN: &str = "s3cr3t-token-value";

    fn provider(server: &MockServer) -> JiraProvider {
        JiraProvider::for_test(
            Some(JiraCredentials::for_test(
                "acme.atlassian.net",
                "me@acme.com",
                TOKEN,
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
    async fn an_empty_list_is_a_failure_and_keeps_the_last_good_list() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(CACHE_FILE);
        let handle = RwLock::new(ProjectFilter::Unknown);
        let good = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(page(&["CORE"], true))
            .mount(&good)
            .await;
        assert!(refresh_once(&provider(&good), &handle, &file).await);

        let empty = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(page(&[], true))
            .mount(&empty)
            .await;
        assert!(!refresh_once(&provider(&empty), &handle, &file).await);
        let expected: HashSet<String> = ["CORE".to_owned()].into();
        assert_eq!(
            *handle.read().unwrap(),
            ProjectFilter::Known(expected.clone())
        );
        assert_eq!(load(&file), Some(expected));
    }

    #[test]
    fn an_empty_cache_file_is_no_cache() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(CACHE_FILE);
        std::fs::write(&file, "[]").unwrap();
        assert_eq!(load(&file), None);
        std::fs::write(&file, r#"["CORE"]"#).unwrap();
        assert_eq!(load(&file), Some(["CORE".to_owned()].into()));
    }

    #[tokio::test]
    async fn the_cache_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(CACHE_FILE);
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(page(&["CORE"], true))
            .mount(&server)
            .await;
        let handle = RwLock::new(ProjectFilter::Unknown);
        assert!(refresh_once(&provider(&server), &handle, &file).await);
        let mode = std::fs::metadata(&file).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        // A second write over it stays private.
        assert!(refresh_once(&provider(&server), &handle, &file).await);
        let mode = std::fs::metadata(&file).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn retry_delay_backs_off_and_is_bounded() {
        assert_eq!(next_delay(0), REFRESH_EVERY);
        assert_eq!(next_delay(1), Duration::from_secs(60));
        assert_eq!(next_delay(2), Duration::from_secs(120));
        assert_eq!(next_delay(3), Duration::from_secs(240));
        assert_eq!(next_delay(50), RETRY_MAX);
        assert_eq!(next_delay(u32::MAX), RETRY_MAX);
    }

    #[tokio::test(start_paused = true)]
    async fn the_loop_retries_in_minutes_after_a_failure_then_settles_to_six_hours() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let calls = Arc::new(AtomicUsize::new(0));
        let seen = Arc::clone(&calls);
        // The first two refreshes fail, then every one succeeds.
        tokio::spawn(run_loop(move || {
            let n = seen.fetch_add(1, Ordering::SeqCst);
            async move { n >= 2 }
        }));
        let calls = || calls.load(Ordering::SeqCst);
        let step = |secs: u64| async move {
            tokio::time::advance(Duration::from_secs(secs)).await;
            for _ in 0..20 {
                tokio::task::yield_now().await;
            }
        };

        step(0).await;
        assert_eq!(calls(), 1, "fetch at start");
        step(59).await;
        assert_eq!(calls(), 1, "no retry before a minute");
        step(2).await;
        assert_eq!(calls(), 2, "first retry after a minute");
        step(119).await;
        assert_eq!(calls(), 2, "backoff doubles");
        step(2).await;
        assert_eq!(
            calls(),
            3,
            "second retry after two minutes; this one succeeds"
        );
        step(60 * 60).await;
        assert_eq!(calls(), 3, "no refetch an hour after success");
        step(REFRESH_EVERY.as_secs()).await;
        assert_eq!(calls(), 4, "refetch after six hours");
    }

    #[tokio::test]
    async fn no_log_line_contains_the_token() {
        let logs = Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
        #[derive(Clone)]
        struct Capture(Arc<std::sync::Mutex<Vec<u8>>>);
        impl std::io::Write for Capture {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Capture {
            type Writer = Capture;
            fn make_writer(&'a self) -> Capture {
                self.clone()
            }
        }
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .with_writer(Capture(Arc::clone(&logs)))
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);

        let dir = tempfile::tempdir().unwrap();
        let handle = RwLock::new(ProjectFilter::Unknown);
        // Success, failure with the token echoed in the body, an empty list, and garbage.
        let bodies: Vec<ResponseTemplate> = vec![
            page(&["CORE"], true),
            ResponseTemplate::new(401).set_body_string(format!("bad credentials {TOKEN}")),
            page(&[], true),
            ResponseTemplate::new(200).set_body_string(format!("{TOKEN} not json")),
        ];
        for response in bodies {
            let server = MockServer::start().await;
            Mock::given(method("GET"))
                .respond_with(response)
                .mount(&server)
                .await;
            refresh_once(&provider(&server), &handle, &dir.path().join(CACHE_FILE)).await;
        }
        let text = String::from_utf8(logs.lock().unwrap().clone()).unwrap();
        assert!(!text.is_empty(), "the test must capture something");
        assert!(!text.contains(TOKEN), "a log line leaked the token: {text}");
        let basic = base64_basic("me@acme.com", TOKEN);
        assert!(!text.contains(&basic));
    }

    fn base64_basic(user: &str, pass: &str) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(format!("{user}:{pass}"))
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
