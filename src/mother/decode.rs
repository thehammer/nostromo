//! Tolerant decoding of Mother payloads.
//!
//! One job (or event) the daemon cannot read must not take the rest down with
//! it: each element is decoded on its own and an unreadable one is skipped.
//! A non-array / invalid-JSON top level stays a hard error, so a failed list
//! never reads as "no jobs".
//!
//! Logging is content-free by construction: serde error messages embed the
//! offending values, so the warning carries only the job id, the failing key
//! path and a short error class, never the serde message or any value.

use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

use serde_json::Value;

use super::protocol::EventData;
use super::MotherJob;

thread_local! {
    /// Id of the job being decoded on this thread, so a per-key warning raised
    /// deep inside serde (see [`super::crew::lenient`]) can name the job.
    static CURRENT_JOB: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Marks `id` as the job being decoded until dropped.
struct JobScope;

impl JobScope {
    fn enter(id: &str) -> Self {
        CURRENT_JOB.with(|c| *c.borrow_mut() = Some(id.to_owned()));
        JobScope
    }
}

impl Drop for JobScope {
    fn drop(&mut self) {
        CURRENT_JOB.with(|c| *c.borrow_mut() = None);
    }
}

/// Cap on remembered (id, path) pairs so a pathological stream can't grow the
/// dedupe set without bound.
const MAX_WARNED: usize = 4096;

/// Parse the body of `mother list --format json`. Returns the jobs that
/// decoded (in order) and how many were skipped.
pub fn parse_jobs(bytes: &[u8]) -> Result<(Vec<MotherJob>, usize), serde_json::Error> {
    let elements: Vec<Value> = serde_json::from_slice(bytes)?;
    Ok(decode_jobs(elements))
}

/// Decode each element on its own; skip (and count) the ones that fail.
pub fn decode_jobs(elements: Vec<Value>) -> (Vec<MotherJob>, usize) {
    let mut jobs = Vec::with_capacity(elements.len());
    let mut skipped = 0usize;
    for element in elements {
        let id = element.get("id").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
        let Some(id) = id else {
            skipped += 1;
            warn_once(None, "id", "missing field");
            continue;
        };
        let _scope = JobScope::enter(&id);
        match serde_path_to_error::deserialize::<_, MotherJob>(element) {
            Ok(job) => jobs.push(job),
            Err(e) => {
                skipped += 1;
                let (path, class) = describe(&e);
                warn_once(Some(&id), &path, class);
            }
        }
    }
    if skipped > 0 {
        tracing::debug!(skipped, decoded = jobs.len(), "mother: skipped unreadable jobs");
    }
    (jobs, skipped)
}

/// Decode an event's `data`; `None` (after a content-free warning) when it
/// cannot be read.
pub fn decode_event_data(kind: &str, data: &Value) -> Option<EventData> {
    match serde_path_to_error::deserialize::<_, EventData>(data) {
        Ok(d) => Some(d),
        Err(e) => {
            let (path, class) = describe(&e);
            let job = data.get("job").and_then(Value::as_str);
            warn_once(job, &format!("event {kind}: {path}"), class);
            None
        }
    }
}

/// Warn (content-free, deduped per job and path) that the new job key `key` could
/// not be read and was dropped to its default. `inner` is the failing path inside
/// that key (`.` for the key itself), as returned by [`describe`].
pub(super) fn warn_unreadable_key(key: &str, inner: &str, class: &'static str) {
    let path = if inner == "." { key.to_owned() } else { format!("{key}.{inner}") };
    let id = CURRENT_JOB.with(|c| c.borrow().clone());
    warn_once(id.as_deref(), &path, class);
}

/// (key path, error class) of a decode failure, with no values in either.
pub(super) fn describe(e: &serde_path_to_error::Error<serde_json::Error>) -> (String, &'static str) {
    let msg = e.inner().to_string();
    let class = if msg.starts_with("invalid type") {
        "invalid type"
    } else if msg.starts_with("invalid value") {
        "invalid value"
    } else if msg.starts_with("missing field") {
        "missing field"
    } else {
        "decode error"
    };
    let mut path = e.path().to_string();
    if class == "missing field" {
        // The field name comes from our own struct, not from the payload.
        if let Some(name) = msg.split('`').nth(1) {
            path = if path == "." { name.to_owned() } else { format!("{path}.{name}") };
        }
    }
    (path, class)
}

/// Warn once per (job id, key path) per daemon run.
fn warn_once(id: Option<&str>, path: &str, class: &'static str) {
    static WARNED: OnceLock<Mutex<HashSet<(String, String)>>> = OnceLock::new();
    let key = (id.unwrap_or("").to_owned(), path.to_owned());
    {
        let mut seen = WARNED.get_or_init(Default::default).lock().unwrap();
        if seen.len() >= MAX_WARNED || !seen.insert(key) {
            return;
        }
    }
    tracing::warn!(job = id.unwrap_or("<none>"), key_path = path, class, "mother: skipped unreadable payload");
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;
    use std::sync::Arc;

    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);
    impl Write for Capture {
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

    /// Run `f` capturing every tracing line (all levels) emitted on this thread.
    fn captured<T>(f: impl FnOnce() -> T) -> (T, String) {
        let cap = Capture::default();
        let sub = tracing_subscriber::fmt()
            .with_writer(cap.clone())
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .finish();
        let out = tracing::subscriber::with_default(sub, f);
        let text = String::from_utf8(cap.0.lock().unwrap().clone()).unwrap();
        (out, text)
    }

    fn job(id: &str) -> Value {
        json!({"id": id, "state": "running", "title": "t"})
    }

    #[test]
    fn middle_job_with_bad_timestamp_is_skipped_without_leaking_the_value() {
        let mut bad = job("mid-1");
        bad["created_at"] = json!("SECRET-yesterday");
        let body = serde_json::to_vec(&json!([job("a-1"), bad, job("c-1")])).unwrap();
        let ((jobs, skipped), log) = captured(|| parse_jobs(&body).unwrap());
        assert_eq!(jobs.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(), ["a-1", "c-1"]);
        assert_eq!(skipped, 1);
        assert_eq!(log.matches("skipped unreadable payload").count(), 1, "{log}");
        assert!(log.contains("mid-1") && log.contains("created_at"), "{log}");
        assert!(!log.contains("SECRET") && !log.contains("yesterday"), "{log}");
    }

    #[test]
    fn unknown_keys_and_nested_objects_are_ignored() {
        let v = json!({"id": "x-1", "state": "queued", "future": {"a": [1, {"b": null}]}, "n": 3});
        let (jobs, skipped) = decode_jobs(vec![v]);
        assert_eq!((jobs.len(), skipped), (1, 0));
    }

    #[test]
    fn job_without_a_usable_id_is_skipped_and_counted() {
        let els = vec![
            json!({"state": "queued"}),
            json!({"id": 7, "state": "queued"}),
            json!("not an object"),
            job("ok-1"),
        ];
        let (jobs, skipped) = decode_jobs(els);
        assert_eq!((jobs.len(), skipped), (1, 3));
    }

    #[test]
    fn missing_required_field_is_named_by_class_and_key() {
        let (r, log) = captured(|| decode_jobs(vec![json!({"id": "nostate-1"})]));
        assert_eq!(r.1, 1);
        assert!(log.contains("missing field") && log.contains("state") && log.contains("nostate-1"), "{log}");
    }

    #[test]
    fn hard_errors_stay_hard_and_empty_is_ok() {
        assert!(parse_jobs(b"{\"id\":\"x\"}").is_err());
        assert!(parse_jobs(b"not json").is_err());
        assert!(parse_jobs(b"").is_err());
        let (jobs, skipped) = parse_jobs(b"[]").unwrap();
        assert!(jobs.is_empty() && skipped == 0);
    }

    #[test]
    fn thousand_jobs_one_bad_is_one_warning() {
        let mut els: Vec<Value> = (0..1000).map(|i| job(&format!("bulk-{i}"))).collect();
        els[500]["started_at"] = json!(12345);
        let ((jobs, skipped), log) = captured(|| decode_jobs(els));
        assert_eq!((jobs.len(), skipped), (999, 1));
        assert_eq!(log.matches("skipped unreadable payload").count(), 1, "{log}");
    }

    #[test]
    fn same_job_and_path_warns_once_per_run() {
        let mut bad = job("dup-1");
        bad["finished_at"] = json!("nope");
        let (_, log) = captured(|| {
            decode_jobs(vec![bad.clone()]);
            decode_jobs(vec![bad.clone()])
        });
        assert_eq!(log.matches("skipped unreadable payload").count(), 1, "{log}");
    }

    #[test]
    fn forward_compat_fixtures_decode_with_new_keys_ignored() {
        let body = include_bytes!("../../tests/fixtures/mother_headless_jobs.json");
        let (jobs, skipped) = parse_jobs(body).unwrap();
        assert_eq!((jobs.len(), skipped), (2, 0));
        assert_eq!(jobs[0].id, "hc-fixture-1");
    }

    #[test]
    fn bad_event_data_is_skipped_content_free() {
        let data = json!({"job": "ev-1", "state": {"SECRET": 1}});
        let (r, log) = captured(|| decode_event_data("state_changed", &data));
        assert!(r.is_none());
        assert!(log.contains("ev-1") && log.contains("state"), "{log}");
        assert!(!log.contains("SECRET"), "{log}");
        assert!(decode_event_data("whatever_new_kind", &json!({"job": "j", "extra": [1]})).is_some());
    }
}
