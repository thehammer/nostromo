//! MC1: Mother's headless-crew contract, as the daemon decodes it.
//!
//! The NDJSON fixtures in `tests/fixtures/mother-contract/` are byte-exact
//! copies of Mother's published contract (see `scripts/mother-contract.py`).
//! Every `snapshot` event's jobs must decode through the daemon's tolerant job
//! decoder with the concrete values Mother's contract promises, and every
//! `progress_updated` event must decode as a progress overlay.
//!
//! Leniency is per TOP-LEVEL job key (locked bet B2): a malformed `gates`
//! (or `review_wave`, `progress`, ...) costs that key only; the job and every
//! other key survive, and exactly one content-free warning names the key.
//! Unknown enum-like VALUES are not errors and survive verbatim.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use nostromo::ipc::protocol::ServerMsg;
use nostromo::mother::crew::*;
use nostromo::mother::decode::{decode_jobs, parse_jobs};
use nostromo::mother::MotherJob;
use serde_json::{json, Value};

const FIXTURES: [&str; 3] = ["gates_fix_pass", "lens_wave", "gate_hold_answered"];

/// Every key MC1 adds to a job, as it appears on the daemon's serialized form.
const NEW_KEYS: [&str; 11] = [
    "activity",
    "pr_url",
    "crew_opt_in",
    "gates",
    "review_wave",
    "decision",
    "attention",
    "attention_reasons",
    "last_answer",
    "progress",
    "criteria_source",
];

// ── fixture access ────────────────────────────────────────────────────────────

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mother-contract")
}

fn events(name: &str) -> Vec<Value> {
    let path = fixture_dir().join(format!("{name}.ndjson"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{name}: bad NDJSON line: {e}")))
        .collect()
}

/// The `jobs` arrays of every `snapshot` event in `name`, in file order.
fn snapshot_job_arrays(name: &str) -> Vec<Value> {
    events(name)
        .into_iter()
        .filter(|e| e["t"] == "snapshot")
        .map(|e| e["data"]["jobs"].clone())
        .collect()
}

/// Decode every snapshot in `name` through `parse_jobs`, asserting nothing is skipped.
fn snapshot_jobs(name: &str) -> Vec<MotherJob> {
    let arrays = snapshot_job_arrays(name);
    assert!(!arrays.is_empty(), "{name} has no snapshot event");
    let mut out = vec![];
    for jobs in arrays {
        let (decoded, skipped) = parse_jobs(&serde_json::to_vec(&jobs).unwrap()).expect("jobs array parses");
        assert_eq!(skipped, 0, "{name}: no fixture job may be skipped");
        out.extend(decoded);
    }
    out
}

fn fixture_job_json(name: &str, id: &str) -> Value {
    snapshot_job_arrays(name)
        .into_iter()
        .flat_map(|a| a.as_array().cloned().unwrap_or_default())
        .find(|j| j["id"] == id)
        .unwrap_or_else(|| panic!("{id} not in {name}"))
}

fn find<'a>(jobs: &'a [MotherJob], id: &str) -> &'a MotherJob {
    jobs.iter().find(|j| j.id == id).unwrap_or_else(|| panic!("{id} not decoded"))
}

fn job_from(v: Value) -> MotherJob {
    serde_json::from_value(v).expect("job decodes")
}

// ── tracing capture (same technique as src/mother/decode.rs tests) ────────────

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

fn warn_lines(log: &str) -> Vec<&str> {
    log.lines().filter(|l| l.contains("WARN")).collect()
}

/// The error classes the daemon's content-free warnings use (see `decode.rs`).
const ERROR_CLASSES: [&str; 4] = ["invalid type", "invalid value", "missing field", "decode error"];

// ── comparison helpers ────────────────────────────────────────────────────────

/// The MC1 keys of a job as seen on its serialized form; an absent key reads as `null`.
fn crew_view(job: &MotherJob) -> BTreeMap<&'static str, Value> {
    let v = serde_json::to_value(job).unwrap();
    NEW_KEYS.iter().map(|k| (*k, v.get(*k).cloned().unwrap_or(Value::Null))).collect()
}

/// Everything about a job EXCEPT its id and the MC1 keys.
fn legacy_view(job: &MotherJob) -> Value {
    let mut v = serde_json::to_value(job).unwrap();
    let obj = v.as_object_mut().unwrap();
    obj.remove("id");
    for k in NEW_KEYS {
        obj.remove(k);
    }
    v
}

fn set(v: &mut Value, pointer: &str, new: Value) {
    match v.pointer_mut(pointer) {
        Some(slot) => *slot = new,
        None => panic!("no {pointer} in the job"),
    }
}

/// Decode `value` alone through `decode_jobs`, capturing the log.
fn decode_one(value: Value) -> (Vec<MotherJob>, usize, String) {
    let ((jobs, skipped), log) = captured(|| decode_jobs(vec![value]));
    (jobs, skipped, log)
}

/// Decode a one-job copy of `original` under the unique id `unique_id` with
/// `mutate` applied, and check the per-key leniency contract: the job is kept
/// (never skipped), `broken_key` fell back to its default while every other MC1
/// key and every legacy key is exactly what the unmodified job decodes to, and
/// the single warning names the key without echoing any of `poisons`.
fn assert_lenient(original: &Value, unique_id: &str, broken_key: &str, poisons: &[&str], mutate: impl FnOnce(&mut Value)) -> MotherJob {
    let (baseline, skipped, _) = decode_one(original.clone());
    assert_eq!(skipped, 0);
    let baseline = &baseline[0];

    let mut mutated = original.clone();
    mutated["id"] = json!(unique_id);
    mutate(&mut mutated);
    let (jobs, skipped, log) = decode_one(mutated);

    assert_eq!(skipped, 0, "a malformed `{broken_key}` must not skip the job; log: {log}");
    assert_eq!(jobs.len(), 1, "the job must be retained");
    let job = jobs.into_iter().next().unwrap();
    assert_eq!(job.id, unique_id);

    let (before, after) = (crew_view(baseline), crew_view(&job));
    for key in NEW_KEYS {
        if key == broken_key {
            assert_eq!(after[key], Value::Null, "`{key}` must fall back to its default");
        } else {
            assert_eq!(after[key], before[key], "`{key}` must be untouched by a broken `{broken_key}`");
        }
    }
    assert_eq!(legacy_view(&job), legacy_view(baseline), "legacy keys must be untouched");

    let warns = warn_lines(&log);
    assert_eq!(warns.len(), 1, "exactly one warning expected, got {warns:?}");
    assert!(warns[0].contains(broken_key), "the warning must name `{broken_key}`: {}", warns[0]);
    assert!(
        ERROR_CLASSES.iter().any(|c| warns[0].contains(c)),
        "the warning must carry an error class: {}",
        warns[0]
    );
    for poison in poisons {
        assert!(!log.contains(poison), "log leaked payload value `{poison}`: {log}");
    }
    job
}

/// A job carrying every MC1 key with realistic values, built from the fixtures.
fn kitchen_sink() -> Value {
    let mut j = fixture_job_json("gate_hold_answered", "j-hold1");
    j["review_wave"] = fixture_job_json("lens_wave", "j-wave1")["review_wave"].clone();
    j["progress"] = fixture_job_json("gates_fix_pass", "j-gates1")["progress"].clone();
    j["last_answer"] = json!({"source": "nostromo_app", "session": "s-1", "agent": "cody",
                              "option": "resume_with_guidance", "at": "2026-10-17T11:00:00.000Z"});
    j["attention_reasons"] = json!([{"reason": "decision_awaiting", "since": "2026-10-17T12:00:02.000Z", "acked": false}]);
    j["criteria_source"] = json!("checklist");
    j
}

// ── the vendored fixtures decode with the contract's values ──────────────────

#[test]
fn gates_fix_pass_snapshot_decodes_with_the_contract_values() {
    let jobs = snapshot_jobs("gates_fix_pass");
    let job = find(&jobs, "j-gates1");
    assert_eq!(job.state, "running");
    assert_eq!(job.activity.as_deref(), Some("gating"));
    assert!(job.crew_opt_in, "the fixture job carries a `crew` key");
    assert_eq!(job.pr_url.as_deref(), Some("https://github.com/Carefeed/admin-portal/pull/4321"));

    let gates = job.gates.as_ref().expect("gates");
    assert_eq!(gates.attempt, Some(1));
    assert_eq!(gates.max_attempts, Some(3));
    assert_eq!(gates.mode.as_deref(), Some("enforce"));
    assert_eq!(gates.status.as_deref(), Some("running"));
    assert_eq!(gates.head_sha.as_deref(), Some("9d1c4e7"));
    assert!(gates.results.is_empty() && gates.not_run.is_empty());
    assert!(!gates.overridden, "`override: null` is not an override");

    let progress = job.progress.as_ref().expect("progress");
    assert_eq!(progress.pct, Some(55));
    assert_eq!(progress.label.as_deref(), Some("Implementing"));
    assert_eq!(progress.stage.as_deref(), Some("implement"));
    assert!(!progress.paused);
    assert!(progress.flags.is_empty());
    let eta = progress.eta.as_ref().expect("eta");
    assert_eq!(eta.basis.as_deref(), Some("fleet"));
    assert_eq!(eta.label.as_deref(), Some("5-15 min"));
    assert_eq!((eta.lo_s, eta.hi_s), (Some(300), Some(900)));
    assert_eq!(progress.signals.as_ref().and_then(|s| s.elapsed_active_s), Some(420));

    assert!(job.review_wave.is_none() && job.decision.is_none());
    assert!(job.attention.is_empty() && job.attention_reasons.is_empty());
}

#[test]
fn lens_wave_snapshot_decodes_with_the_contract_values() {
    let jobs = snapshot_jobs("lens_wave");
    let job = find(&jobs, "j-wave1");
    assert_eq!(job.activity.as_deref(), Some("review_wave"));
    assert!(job.crew_opt_in);

    let wave = job.review_wave.as_ref().expect("review_wave");
    assert_eq!(wave.cycle, Some(1));
    assert_eq!(wave.cycle_cap, Some(2));
    assert_eq!(wave.status.as_deref(), Some("running"));
    assert_eq!(wave.budget_usd, Some(3.0));
    assert_eq!(wave.lenses.len(), 4);
    assert_eq!(
        wave.lenses.iter().map(|l| l.reviewer.as_str()).collect::<Vec<_>>(),
        ["archie:adherence", "perri:correctness", "perri:phi-security", "perri:ops-infra"],
        "lenses keep Mother's order"
    );
    let adherence = wave.lenses.iter().find(|l| l.reviewer == "archie:adherence").expect("adherence lens");
    assert_eq!((adherence.lens.as_str(), adherence.state.as_str()), ("adherence", "pending"));
    let ops = wave.lenses.iter().find(|l| l.reviewer == "perri:ops-infra").expect("ops-infra lens");
    assert_eq!(ops.lens, "ops-infra");
    assert_eq!(ops.state, "skipped");
    assert_eq!(ops.skip_reason.as_deref(), Some("path_scope"));
    assert_eq!(ops.findings, LensFindings { blocking: 0, advisory: 0 });
    assert_eq!(wave.adherence.as_ref().and_then(|a| a.state.as_deref()), Some("pending"));
    assert_eq!(wave.coverage_gaps, Some(0));
    assert_eq!(wave.claims, Some(ClaimCounts { verified: 0, refuted: 0, unverified: 0 }));
}

#[test]
fn gate_hold_snapshot_decodes_with_the_contract_values() {
    let jobs = snapshot_jobs("gate_hold_answered");
    let job = find(&jobs, "j-hold1");
    assert_eq!(job.state, "awaiting");
    assert_eq!(job.activity.as_deref(), Some("gate_hold"));
    assert_eq!(job.paused_reason.as_deref(), Some("gate_hold"));
    assert!(job.crew_opt_in);

    let decision = job.open_decision().expect("an open decision");
    assert_eq!(decision.id, "d-0001");
    assert_eq!(decision.kind, "gate_hold");
    assert_eq!(
        decision.options.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(),
        ["resume_with_guidance", "escalate", "override_open", "cancel"]
    );
    for option in &decision.options {
        assert_eq!(option.takes_text, option.id == "resume_with_guidance", "takes_text on {}", option.id);
        assert!(!option.label.is_empty() && !option.consequence.is_empty(), "{option:?}");
    }
    assert_eq!(decision.options[0].label, "Resume with guidance");

    assert_eq!(job.attention.len(), 1);
    assert_eq!(job.attention[0].reason, "decision_awaiting");
    assert_eq!(job.attention[0].acked, None);
    assert!(job.is_held_for_operator());
    let unacked: Vec<_> = job.unacked_attention().map(|a| a.reason.as_str()).collect();
    assert_eq!(unacked, ["decision_awaiting"]);

    let gates = job.gates.as_ref().expect("gates");
    assert_eq!(gates.status.as_deref(), Some("exhausted"));
    assert_eq!((gates.attempt, gates.max_attempts), (Some(3), Some(3)));
    assert_eq!(gates.results.len(), 1);
    let unit = &gates.results[0];
    assert_eq!((unit.name.as_str(), unit.result.as_str()), ("unit", "failed"));
    assert!(unit.blocking);
    assert_eq!((unit.duration_s, unit.exit_code), (Some(201), Some(1)));
    assert_eq!(unit.unavailable_reason, None);
}

#[test]
fn every_progress_updated_event_decodes_as_a_progress_overlay() {
    let mut seen = 0;
    for name in FIXTURES {
        for event in events(name).into_iter().filter(|e| e["t"] == "progress_updated") {
            let mut data = event["data"].clone();
            let obj = data.as_object_mut().expect("data object");
            obj.remove("job");
            obj.remove("category");
            let p: CrewProgress = serde_json::from_value(data).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert!(p.pct.is_some() && p.eta.is_some() && p.signals.is_some(), "{name}: {p:?}");
            seen += 1;
        }
    }
    assert_eq!(seen, 4, "gates_fix_pass carries four progress_updated events");
}

#[test]
fn gates_fix_pass_progress_events_carry_the_documented_percentages_and_gate_signal() {
    let progress: Vec<CrewProgress> = events("gates_fix_pass")
        .into_iter()
        .filter(|e| e["t"] == "progress_updated")
        .map(|e| {
            let mut d = e["data"].clone();
            d.as_object_mut().unwrap().remove("job");
            d.as_object_mut().unwrap().remove("category");
            serde_json::from_value(d).expect("progress decodes")
        })
        .collect();
    assert_eq!(progress.iter().map(|p| p.pct).collect::<Vec<_>>(), [Some(70), Some(62), Some(90), Some(95)]);
    let first = progress[0].signals.as_ref().and_then(|s| s.gates.clone());
    assert_eq!(first, Some(GateSignal { passed: 1, failed: 1, total: 3 }));
    assert_eq!(progress[0].label.as_deref(), Some("Checking"));
    assert_eq!(progress[3].eta.as_ref().and_then(|e| e.label.as_deref()), Some("under 2 min"));
}

// ── per-key leniency (B2): mutation cases built from fixture jobs ────────────

#[test]
fn a_gates_value_that_is_a_string_costs_only_the_gates_key() {
    let original = kitchen_sink();
    let job = assert_lenient(&original, "mut-gates-string", "gates", &["SECRET-PAYLOAD-123"], |j| {
        j["gates"] = json!("SECRET-PAYLOAD-123");
    });
    assert!(job.gates.is_none());
    assert!(job.open_decision().is_some(), "the decision beside it survives");
    assert!(job.review_wave.is_some() && job.progress.is_some());
}

#[test]
fn review_wave_lenses_that_are_a_number_cost_only_the_review_wave_key() {
    let original = fixture_job_json("lens_wave", "j-wave1");
    let job = assert_lenient(&original, "mut-wave-lenses-number", "review_wave", &["SECRET-PAYLOAD-456"], |j| {
        set(j, "/review_wave/lenses", json!(7));
        set(j, "/review_wave/mode", json!("SECRET-PAYLOAD-456"));
    });
    assert!(job.review_wave.is_none());
    assert_eq!(job.activity.as_deref(), Some("review_wave"));
    assert_eq!(job.pr_url.as_deref(), Some("https://github.com/Carefeed/admin-portal/pull/4388"));
}

#[test]
fn progress_eta_that_is_an_empty_array_costs_only_the_progress_key() {
    let original = fixture_job_json("gates_fix_pass", "j-gates1");
    let job = assert_lenient(&original, "mut-progress-eta-array", "progress", &["SECRET-PAYLOAD-789"], |j| {
        set(j, "/progress/eta", json!([]));
        set(j, "/progress/label", json!("SECRET-PAYLOAD-789"));
    });
    assert!(job.progress.is_none());
    assert_eq!(job.gates.as_ref().and_then(|g| g.attempt), Some(1), "gates survive a broken progress overlay");
    assert_eq!(job.activity.as_deref(), Some("gating"));
}

#[test]
fn an_unknown_gate_result_value_is_not_an_error_and_survives_verbatim() {
    let original = fixture_job_json("gate_hold_answered", "j-hold1");
    let mut mutated = original.clone();
    mutated["id"] = json!("mut-gate-result-flaky");
    set(&mut mutated, "/gates/results/0/result", json!("flaky"));

    let (jobs, skipped, log) = decode_one(mutated);
    assert_eq!(skipped, 0);
    let job = &jobs[0];
    assert_eq!(job.gates.as_ref().unwrap().results[0].result, "flaky");
    assert!(warn_lines(&log).is_empty(), "an unknown value is not worth a warning: {log}");

    let (baseline, _, _) = decode_one(original);
    let (a, b) = (crew_view(job), crew_view(&baseline[0]));
    for key in NEW_KEYS.iter().filter(|k| **k != "gates") {
        assert_eq!(a[key], b[key], "`{key}`");
    }
    assert_eq!(job.gates.as_ref().unwrap().results[0].name, "unit", "the rest of the gate entry is intact");
}

#[test]
fn an_unknown_decision_option_id_is_not_an_error_and_survives_verbatim() {
    let original = fixture_job_json("gate_hold_answered", "j-hold1");
    let mut mutated = original.clone();
    mutated["id"] = json!("mut-option-future");
    set(&mut mutated, "/decision/options/1/id", json!("future_option"));

    let (jobs, skipped, log) = decode_one(mutated);
    assert_eq!(skipped, 0);
    let decision = jobs[0].open_decision().expect("decision survives");
    assert_eq!(
        decision.options.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(),
        ["resume_with_guidance", "future_option", "override_open", "cancel"]
    );
    assert!(warn_lines(&log).is_empty(), "an unknown value is not worth a warning: {log}");
    assert!(jobs[0].is_held_for_operator());
}

#[test]
fn progress_flags_decode_from_objects_and_ignore_their_extra_detail() {
    let original = fixture_job_json("gates_fix_pass", "j-gates1");
    let mut mutated = original.clone();
    mutated["id"] = json!("mut-flags-objects");
    set(
        &mut mutated,
        "/progress/flags",
        json!([{"reason": "burn_ahead", "since": "2026-10-17T12:00:00.000Z", "detail": "x"}]),
    );
    let (jobs, skipped, log) = decode_one(mutated);
    assert_eq!(skipped, 0);
    let progress = jobs[0].progress.as_ref().expect("progress survives object flags");
    assert_eq!(
        progress.flags,
        vec![ProgressFlag { reason: "burn_ahead".into(), since: Some("2026-10-17T12:00:00.000Z".into()) }]
    );
    assert_eq!(progress.pct, Some(55));
    assert!(warn_lines(&log).is_empty(), "{log}");
}

#[test]
fn progress_flags_decode_from_plain_strings() {
    let original = fixture_job_json("gates_fix_pass", "j-gates1");
    let mut mutated = original.clone();
    mutated["id"] = json!("mut-flags-strings");
    set(&mut mutated, "/progress/flags", json!(["stalled"]));
    let (jobs, skipped, log) = decode_one(mutated);
    assert_eq!(skipped, 0);
    let progress = jobs[0].progress.as_ref().expect("progress survives string flags");
    assert_eq!(progress.flags, vec![ProgressFlag { reason: "stalled".into(), since: None }]);
    assert_eq!(progress.pct, Some(55));
    assert!(warn_lines(&log).is_empty(), "{log}");
}

#[test]
fn every_new_key_is_lenient_on_its_own() {
    // (key, a value of the wrong shape for it, the poison hidden inside it).
    // A leaked payload value is detectable in the captured log.
    let cases: [(&str, Value, &str); 10] = [
        ("activity", json!({"x": "SECRET-PAYLOAD-K1"}), "SECRET-PAYLOAD-K1"),
        ("pr_url", json!(["SECRET-PAYLOAD-K2"]), "SECRET-PAYLOAD-K2"),
        ("gates", json!("SECRET-PAYLOAD-K3"), "SECRET-PAYLOAD-K3"),
        ("review_wave", json!("SECRET-PAYLOAD-K4"), "SECRET-PAYLOAD-K4"),
        ("decision", json!("SECRET-PAYLOAD-K5"), "SECRET-PAYLOAD-K5"),
        ("attention", json!("SECRET-PAYLOAD-K6"), "SECRET-PAYLOAD-K6"),
        ("attention_reasons", json!({"SECRET-PAYLOAD-K7": 1}), "SECRET-PAYLOAD-K7"),
        ("last_answer", json!("SECRET-PAYLOAD-K8"), "SECRET-PAYLOAD-K8"),
        ("progress", json!("SECRET-PAYLOAD-K9"), "SECRET-PAYLOAD-K9"),
        ("criteria_source", json!(["SECRET-PAYLOAD-K10"]), "SECRET-PAYLOAD-K10"),
    ];
    let original = kitchen_sink();
    let (baseline, _, _) = decode_one(original.clone());
    let base = crew_view(&baseline[0]);
    for key in NEW_KEYS {
        assert_ne!(base[key], Value::Null, "the kitchen-sink job must populate `{key}`");
    }

    for (key, bad, poison) in cases {
        let id = format!("mut-each-{key}");
        assert_lenient(&original, &id, key, &[poison], |j| j[key] = bad);
    }
}

#[test]
fn unknown_enum_like_values_survive_verbatim_without_a_warning() {
    let mut j = kitchen_sink();
    j["id"] = json!("unknown-values-1");
    j["activity"] = json!("future_activity");
    j["criteria_source"] = json!("future_source");
    set(&mut j, "/gates/status", json!("weird_status"));
    set(&mut j, "/gates/mode", json!("weird_mode"));
    set(&mut j, "/decision/kind", json!("new_kind"));
    set(&mut j, "/review_wave/lenses/0/state", json!("teleporting"));
    set(&mut j, "/review_wave/lenses/3/skip_reason", json!("new_reason"));
    set(&mut j, "/progress/eta/basis", json!("weird_basis"));
    j["attention"] = json!([{"reason": "future_reason", "since": "2026-10-17T12:00:02.000Z"}]);
    j["attention_reasons"] = json!([]);

    let (jobs, skipped, log) = decode_one(j);
    assert_eq!(skipped, 0);
    let job = &jobs[0];
    assert!(warn_lines(&log).is_empty(), "{log}");
    assert_eq!(job.activity.as_deref(), Some("future_activity"));
    assert_eq!(job.criteria_source.as_deref(), Some("future_source"));
    let gates = job.gates.as_ref().unwrap();
    assert_eq!((gates.status.as_deref(), gates.mode.as_deref()), (Some("weird_status"), Some("weird_mode")));
    assert_eq!(job.decision.as_ref().unwrap().kind, "new_kind");
    let wave = job.review_wave.as_ref().unwrap();
    assert_eq!(wave.lenses[0].state, "teleporting");
    assert_eq!(wave.lenses[3].skip_reason.as_deref(), Some("new_reason"));
    assert_eq!(job.progress.as_ref().unwrap().eta.as_ref().unwrap().basis.as_deref(), Some("weird_basis"));
    assert_eq!(job.attention[0].reason, "future_reason");
    assert_eq!(job.unacked_attention().count(), 1, "an unknown reason is still attention");
}

#[test]
fn a_decision_resolution_decodes_from_a_plain_string_or_an_object() {
    let mut as_string = fixture_job_json("gate_hold_answered", "j-hold1");
    as_string["id"] = json!("resolution-string");
    set(&mut as_string, "/decision/resolved_at", json!("2026-10-17T12:05:00.000Z"));
    set(&mut as_string, "/decision/resolution", json!("resume_with_guidance"));
    let (jobs, skipped, log) = decode_one(as_string);
    assert_eq!(skipped, 0);
    assert!(warn_lines(&log).is_empty(), "{log}");
    let resolution = jobs[0].decision.as_ref().unwrap().resolution.clone().expect("resolution");
    assert_eq!(resolution.option.as_deref(), Some("resume_with_guidance"));

    let mut as_object = fixture_job_json("gate_hold_answered", "j-hold1");
    as_object["id"] = json!("resolution-object");
    set(&mut as_object, "/decision/resolved_at", json!("2026-10-17T12:05:00.000Z"));
    set(
        &mut as_object,
        "/decision/resolution",
        json!({"option": "escalate", "source": "nostromo_app", "at": "2026-10-17T12:05:00.000Z"}),
    );
    let (jobs, skipped, log) = decode_one(as_object);
    assert_eq!(skipped, 0);
    assert!(warn_lines(&log).is_empty(), "{log}");
    let resolution = jobs[0].decision.as_ref().unwrap().resolution.clone().expect("resolution");
    assert_eq!(resolution.option.as_deref(), Some("escalate"));
    assert_eq!(resolution.source.as_deref(), Some("nostromo_app"));
    assert_eq!(resolution.at.as_deref(), Some("2026-10-17T12:05:00.000Z"));
}

#[test]
fn an_overridden_gate_run_is_reported_and_survives_a_round_trip() {
    let mut j = fixture_job_json("gate_hold_answered", "j-hold1");
    j["id"] = json!("override-1");
    set(&mut j, "/gates/override", json!({"by": "nostromo_app", "at": "2026-10-17T12:05:00.000Z"}));
    let job = job_from(j);
    assert!(job.gates.as_ref().unwrap().overridden, "a non-null `override` means overridden");

    let again: MotherJob = serde_json::from_str(&serde_json::to_string(&job).unwrap()).unwrap();
    assert!(again.gates.as_ref().unwrap().overridden, "overridden must survive the daemon's own JSON");
    assert_eq!(again, job);
}

// ── the opaque `crew` blob ───────────────────────────────────────────────────

#[test]
fn the_crew_blob_marks_opt_in_and_is_never_re_serialized() {
    let job = job_from(json!({
        "id": "crew-blob-1", "state": "running",
        "crew": {"mode": "enforce", "gate_commands": ["rm -rf SECRET"]}
    }));
    assert!(job.crew_opt_in);
    let wire = serde_json::to_string(&job).unwrap();
    assert!(!wire.contains("gate_commands"), "{wire}");
    assert!(!wire.contains("SECRET"), "{wire}");
    assert!(!wire.contains("\"crew\":"), "{wire}");
    assert!(wire.contains("\"crew_opt_in\":true"), "{wire}");
}

#[test]
fn an_empty_crew_object_still_marks_opt_in() {
    assert!(job_from(json!({"id": "crew-empty", "state": "running", "crew": {}})).crew_opt_in);
}

#[test]
fn a_null_or_absent_crew_key_means_not_opted_in() {
    assert!(!job_from(json!({"id": "crew-null", "state": "running", "crew": null})).crew_opt_in);
    assert!(!job_from(json!({"id": "crew-absent", "state": "running"})).crew_opt_in);
}

#[test]
fn the_daemons_own_crew_opt_in_key_is_accepted_on_input() {
    assert!(job_from(json!({"id": "optin-true", "state": "running", "crew_opt_in": true})).crew_opt_in);
    assert!(!job_from(json!({"id": "optin-false", "state": "running", "crew_opt_in": false})).crew_opt_in);
}

// ── serialization ────────────────────────────────────────────────────────────

#[test]
fn a_job_without_crew_data_serializes_none_of_the_new_keys() {
    let job = job_from(json!({"id": "plain-1", "state": "running", "title": "t", "pr_url": null}));
    let v = serde_json::to_value(&job).unwrap();
    let obj = v.as_object().unwrap();
    for key in NEW_KEYS {
        assert!(!obj.contains_key(key), "`{key}` must be absent for a job without crew data: {v}");
    }
    assert!(!obj.contains_key("crew"));
}

#[test]
fn every_fixture_job_survives_a_serialize_deserialize_round_trip() {
    for name in FIXTURES {
        for job in snapshot_jobs(name) {
            let wire = serde_json::to_string(&job).unwrap();
            let again: MotherJob = serde_json::from_str(&wire).unwrap_or_else(|e| panic!("{name}/{}: {e}", job.id));
            assert_eq!(again, job, "{name}/{} changed across the daemon's own JSON", job.id);
        }
    }
}

// ── helpers on MotherJob ─────────────────────────────────────────────────────

fn job_with(extra: Value) -> MotherJob {
    let mut base = json!({"id": "helper-job", "state": "running"});
    for (k, v) in extra.as_object().expect("object") {
        base[k] = v.clone();
    }
    job_from(base)
}

fn reasons(job: &MotherJob) -> Vec<String> {
    job.unacked_attention().map(|a| a.reason.clone()).collect()
}

#[test]
fn unacked_attention_prefers_attention_reasons_and_drops_acked_entries() {
    let job = job_with(json!({
        "attention": [{"reason": "from_attention", "since": "2026-10-17T12:00:00.000Z"}],
        "attention_reasons": [
            {"reason": "progress_stalled", "since": "2026-10-17T12:00:00.000Z", "acked": false},
            {"reason": "burn_ahead", "since": "2026-10-17T12:00:00.000Z", "acked": true},
            {"reason": "gates_incomplete", "since": "2026-10-17T12:00:00.000Z"}
        ]
    }));
    assert_eq!(reasons(&job), ["progress_stalled", "gates_incomplete"]);
}

#[test]
fn unacked_attention_falls_back_to_attention_when_attention_reasons_is_empty() {
    let job = job_with(json!({
        "attention": [
            {"reason": "decision_awaiting", "since": "2026-10-17T12:00:00.000Z"},
            {"reason": "burn_ahead", "since": "2026-10-17T12:00:00.000Z", "acked": true}
        ],
        "attention_reasons": []
    }));
    assert_eq!(reasons(&job), ["decision_awaiting"]);
    assert!(reasons(&job_with(json!({}))).is_empty());
}

#[test]
fn an_empty_attention_reasons_list_does_not_hide_attention() {
    let job = job_with(json!({"attention": [{"reason": "gates_incomplete"}]}));
    assert_eq!(reasons(&job), ["gates_incomplete"]);
}

#[test]
fn open_decision_is_none_without_a_decision_or_once_it_is_resolved() {
    let open = fixture_job_json("gate_hold_answered", "j-hold1");
    assert_eq!(job_from(open.clone()).open_decision().map(|d| d.id.as_str()), Some("d-0001"));

    let mut resolved = open;
    set(&mut resolved, "/decision/resolved_at", json!("2026-10-17T12:05:00.000Z"));
    let resolved = job_from(resolved);
    assert!(resolved.decision.is_some(), "the resolved decision is still carried");
    assert!(resolved.open_decision().is_none());

    assert!(job_with(json!({})).open_decision().is_none());
}

fn open_decision_json() -> Value {
    json!({"id": "d-9", "kind": "review_hold",
           "options": [{"id": "cancel", "label": "Cancel", "consequence": "Stop.", "takes_text": false}],
           "opened_at": "2026-10-17T12:00:00.000Z", "resolved_at": null, "resolution": null})
}

#[test]
fn is_held_for_operator_follows_state_activity_and_open_decision() {
    // Awaiting with a hold activity: held.
    assert!(job_with(json!({"state": "awaiting", "activity": "gate_hold"})).is_held_for_operator());
    assert!(job_with(json!({"state": "awaiting", "activity": "review_hold"})).is_held_for_operator());
    // An open decision holds the job whatever its state says.
    assert!(job_with(json!({"state": "running", "decision": open_decision_json()})).is_held_for_operator());
    // Not held.
    assert!(!job_with(json!({"state": "running"})).is_held_for_operator());
    assert!(!job_with(json!({"state": "running", "activity": "gate_hold"})).is_held_for_operator(), "hold activity needs state awaiting");
    assert!(!job_with(json!({"state": "awaiting", "activity": "gating"})).is_held_for_operator());
    assert!(!job_with(json!({"state": "awaiting"})).is_held_for_operator(), "no activity and no decision");
    let mut resolved = open_decision_json();
    resolved["resolved_at"] = json!("2026-10-17T12:05:00.000Z");
    assert!(!job_with(json!({"state": "running", "decision": resolved})).is_held_for_operator());
}

// ── golden IPC frame ─────────────────────────────────────────────────────────

/// `serde_json::to_string_pretty` of the frame (same format as the plain golden
/// in `tests/mother_jobs_ipc_plain_golden.rs`); `UPDATE_GOLDEN=1` rewrites the
/// file. The Kit tests decode this file, which is the cross-language check.
#[test]
fn the_mother_jobs_frame_for_the_fixture_snapshots_matches_the_golden() {
    let mut jobs = vec![];
    for name in FIXTURES {
        jobs.extend(snapshot_jobs(name));
    }
    assert_eq!(jobs.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(), ["j-gates1", "j-wave1", "j-hold1"]);

    let frame = serde_json::to_string_pretty(&ServerMsg::MotherJobs { jobs }).unwrap();
    let path = fixture_dir().join("ipc_mother_jobs.golden.json");

    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::write(&path, &frame).expect("write golden");
        return;
    }

    let parsed: Value = serde_json::from_str(&frame).unwrap();
    assert_eq!(parsed["type"], "mother_jobs");
    assert!(!frame.contains("gate_commands") && !frame.contains("\"crew\":"), "the crew blob is never on the wire");

    let golden = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e} (UPDATE_GOLDEN=1 to create)", path.display()));
    assert_eq!(frame, golden, "the MotherJobs wire form changed; regenerate with UPDATE_GOLDEN=1 if intended");
}

// ── a Go producer writes nil slices and unset values as `null` ───────────────

#[test]
fn null_members_inside_a_key_are_read_as_missing_not_as_a_type_error() {
    let mut job = kitchen_sink();
    job["id"] = json!("null-members-1");
    job["gates"]["not_run"] = Value::Null;
    job["gates"]["results"][0]["blocking"] = Value::Null;
    job["review_wave"]["lenses"] = Value::Null;
    job["progress"]["flags"] = Value::Null;
    job["progress"]["paused"] = Value::Null;
    job["decision"]["options"][0]["takes_text"] = Value::Null;

    let (jobs, skipped, log) = decode_one(job);
    assert_eq!(skipped, 0, "{log}");
    assert!(warn_lines(&log).is_empty(), "null members are not malformed: {log}");
    let j = &jobs[0];
    let gates = j.gates.as_ref().expect("gates survives");
    assert!(gates.not_run.is_empty() && !gates.results[0].blocking);
    assert!(j.review_wave.as_ref().expect("review_wave survives").lenses.is_empty());
    let progress = j.progress.as_ref().expect("progress survives");
    assert!(progress.flags.is_empty() && !progress.paused);
    assert_eq!(progress.pct, Some(55));
    assert!(!j.decision.as_ref().expect("decision survives").options[0].takes_text);
}
