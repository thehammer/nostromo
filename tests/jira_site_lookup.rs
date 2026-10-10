//! Where the Jira site used for todo links comes from: the configured
//! override, then the process environment, then the credentials file. A blank
//! value at any level counts as absent. No site anywhere is `None` (never an
//! empty string, never a panic).
//!
//! Own test binary = own process, so these may set the environment; they hold
//! a lock so they cannot race each other.

use std::path::PathBuf;
use std::sync::Mutex;

use nostromo::data::work::credentials::JiraSite;

const VAR: &str = "ATLASSIAN_SITE_NAME";
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Run `f` with the process env var set to `value` (`None` = unset).
fn with_env<T>(value: Option<&str>, f: impl FnOnce() -> T) -> T {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let saved = std::env::var(VAR).ok();
    match value {
        Some(v) => std::env::set_var(VAR, v),
        None => std::env::remove_var(VAR),
    }
    let out = f();
    match saved {
        Some(v) => std::env::set_var(VAR, v),
        None => std::env::remove_var(VAR),
    }
    out
}

fn env_file(dir: &tempfile::TempDir, contents: Option<&str>) -> PathBuf {
    let path = dir.path().join(".env");
    if let Some(c) = contents {
        std::fs::write(&path, c).unwrap();
    }
    path
}

#[test]
fn the_credentials_file_supplies_the_site_when_nothing_else_does() {
    let dir = tempfile::tempdir().unwrap();
    let path = env_file(&dir, Some("OTHER=1\nATLASSIAN_SITE_NAME=file.atlassian.net\n"));
    let got = with_env(None, || JiraSite::new(None, path).lookup());
    assert_eq!(got.as_deref(), Some("file.atlassian.net"));
}

#[test]
fn a_configured_site_wins_over_both_the_environment_and_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = env_file(&dir, Some("ATLASSIAN_SITE_NAME=file.atlassian.net\n"));
    let got = with_env(Some("env.atlassian.net"), || {
        JiraSite::new(Some("override.atlassian.net".into()), path).lookup()
    });
    assert_eq!(got.as_deref(), Some("override.atlassian.net"));
}

#[test]
fn the_environment_wins_over_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = env_file(&dir, Some("ATLASSIAN_SITE_NAME=file.atlassian.net\n"));
    let got = with_env(Some("env.atlassian.net"), || JiraSite::new(None, path).lookup());
    assert_eq!(got.as_deref(), Some("env.atlassian.net"));
}

#[test]
fn a_blank_configured_site_or_a_blank_environment_value_counts_as_absent() {
    let dir = tempfile::tempdir().unwrap();
    let path = env_file(&dir, Some("ATLASSIAN_SITE_NAME=file.atlassian.net\n"));
    for blank in ["", "   "] {
        let got = with_env(Some(blank), || JiraSite::new(Some(blank.into()), path.clone()).lookup());
        assert_eq!(got.as_deref(), Some("file.atlassian.net"), "blank {blank:?}");
    }
}

#[test]
fn no_site_anywhere_is_none() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("missing.env");
    assert_eq!(with_env(None, || JiraSite::new(None, missing).lookup()), None, "missing file");
    let blank = env_file(&dir, Some("ATLASSIAN_SITE_NAME=\n"));
    assert_eq!(with_env(None, || JiraSite::new(None, blank).lookup()), None, "blank value in the file");
}

#[test]
fn the_file_is_re_read_when_it_changes() {
    let dir = tempfile::tempdir().unwrap();
    let path = env_file(&dir, Some("ATLASSIAN_SITE_NAME=first.atlassian.net\n"));
    let site = JiraSite::new(None, path.clone());
    assert_eq!(with_env(None, || site.lookup()).as_deref(), Some("first.atlassian.net"));

    std::fs::write(&path, "ATLASSIAN_SITE_NAME=second.atlassian.net\n").unwrap();
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(5);
    std::fs::File::options().write(true).open(&path).unwrap().set_modified(later).unwrap();

    assert_eq!(with_env(None, || site.lookup()).as_deref(), Some("second.atlassian.net"));
}
