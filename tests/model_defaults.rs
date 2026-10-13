//! Model switching, slice M3: which model a NEW focus starts on.
//!
//! Precedence for a new focus: explicit choice (creation sheet / `create_focus` tool) >
//! per-agent default (`model-defaults.json`) > the agent's declared `model:` front matter >
//! the CLI's own default. An existing focus never follows a later change of a default.
//!
//! Observed from outside: the argv a fake `claude` receives, the files in the model store,
//! and the activity log. The fake is a minimal cousin of the one in `tests/model_switch.rs`
//! (it logs argv, answers `initialize` and control requests, and ends turns).
//! Env vars are process-global, so every test holds one lock.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use chrono::Utc;
use nostromo::ipc::protocol::{EffortChoice, FocusMeta, ModelRequestStatus};
use nostromo::ipc::session_manager::{SwitchRequest, CLAUDE_BIN_ENV};
use nostromo::ipc::SessionManager;
use nostromo::model::catalog::ModelCatalog;
use nostromo::model::store::{self, AgentDefault, FocusModelRecord, ModelSource};
use nostromo::model::{Actor, ModelPaths, ModelTarget};
use serde_json::Value;

const WAIT: Duration = Duration::from_secs(30);
const TAG: &str = "focus-a";

const FAKE_CLAUDE: &str = r##"#!/bin/sh
D="$FAKE_DIR"
S="$D/state.$$"
mkdir -p "$S"
A="$D/argv.$$"
{ for a in "$@"; do printf '%s\n' "$a"; done; printf '%s\n' '--END--'; } > "$A"
cat "$A" >> "$D/argv.log"
rm -f "$A"
resolve() {
  case "$1" in
    opus) echo claude-opus-5-5 ;;
    fable) echo claude-fable-5-1 ;;
    sonnet|default) echo claude-sonnet-5-5 ;;
    haiku) echo claude-haiku-5-5 ;;
    *) echo "$1" ;;
  esac
}
sid="sid-fake"; prev=""; model=""; effort=""
for a in "$@"; do
  case "$prev" in
    --session-id|--resume) sid="$a" ;;
    --model) model="$a" ;;
    --effort) effort="$a" ;;
  esac
  prev="$a"
done
if [ -n "$model" ]; then cur=$(resolve "$model"); else cur=claude-sonnet-4-6; fi
printf '%s' "$cur" > "$S/cur"
printf '%s' "$effort" > "$S/effort"
ctl_ok() { printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$1\"$2}}"; }
while IFS= read -r line; do
  case "$line" in
    *'"type":"control_request"'*)
      rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      case "$line" in
        *'"subtype":"initialize"'*)
          tr -d '\n' < "$FAKE_CATALOG" | sed "s/\"request_id\" *: *\"init-1\"/\"request_id\":\"$rid\"/"
          printf '\n' ;;
        *'"subtype":"set_model"'*)
          req=$(printf '%s' "$line" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
          printf '%s' "$(resolve "$req")" > "$S/cur"
          ctl_ok "$rid" ;;
        *'"subtype":"apply_flag_settings"'*)
          e=$(printf '%s' "$line" | sed -n 's/.*"effortLevel":"\([^"]*\)".*/\1/p')
          printf '%s' "$e" > "$S/effort"
          ctl_ok "$rid" ;;
        *'"subtype":"get_settings"'*)
          cur=$(cat "$S/cur"); e=$(cat "$S/effort"); [ -n "$e" ] || e=medium
          ctl_ok "$rid" ",\"response\":{\"applied\":{\"model\":\"$cur\",\"effort\":\"$e\"}}" ;;
        *) ctl_ok "$rid" ;;
      esac ;;
    *'"type":"user"'*)
      printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"claude-sonnet-4-6\"}"
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0}' ;;
  esac
done
"##;

static FAKE_DIR_ROOT: OnceLock<PathBuf> = OnceLock::new();

fn fake_claude_script() -> PathBuf {
    FAKE_DIR_ROOT
        .get_or_init(|| {
            use std::os::unix::fs::PermissionsExt;
            let dir = std::env::temp_dir().join(format!("nostromo-fake-claude-modeldefaults-{}", std::process::id()));
            std::fs::create_dir_all(&dir).expect("fake claude dir");
            let script = dir.join("claude");
            std::fs::write(&script, FAKE_CLAUDE).expect("write fake claude");
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
            dir
        })
        .join("claude")
}

fn fixture_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/model_catalog_initialize.json")
}

fn fixture_catalog() -> ModelCatalog {
    let json: Value = serde_json::from_slice(&std::fs::read(fixture_path()).unwrap()).unwrap();
    ModelCatalog::from_initialize_response(&json, Utc::now()).expect("fixture has models")
}

/// One lock for the whole file: env vars and the fake's log directory are process-global.
static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct Rig {
    _guard: tokio::sync::MutexGuard<'static, ()>,
    _root: tempfile::TempDir,
    fake: PathBuf,
    paths: ModelPaths,
    activity: PathBuf,
    agents: PathBuf,
    cwd: PathBuf,
    mgr: SessionManager,
    saved: Vec<(&'static str, Option<OsString>)>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.mgr.kill_all_on_shutdown();
        for (key, prev) in self.saved.drain(..).rev() {
            match prev {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}

impl Rig {
    async fn new() -> Rig {
        let guard = LOCK.lock().await;
        let root = tempfile::tempdir().unwrap();
        let fake = root.path().join("fake");
        let state = root.path().join("state");
        let agents = root.path().join("agents");
        let cwd = root.path().join("cwd");
        for d in [&fake, &state, &agents, &cwd] {
            std::fs::create_dir_all(d).unwrap();
        }
        let store_path = state.join("sessions.json");
        let activity = root.path().join("activity.jsonl");
        let mut mgr = SessionManager::with_store_path(store_path.clone());
        mgr.set_model_catalog(fixture_catalog());
        let mut rig = Rig {
            _guard: guard,
            paths: ModelPaths::beside(&store_path),
            _root: root,
            fake,
            activity,
            agents,
            cwd,
            mgr,
            saved: Vec::new(),
        };
        rig.env(CLAUDE_BIN_ENV, Some(fake_claude_script().into()));
        rig.env("FAKE_DIR", Some(rig.fake.clone().into()));
        rig.env("FAKE_CATALOG", Some(fixture_path().into()));
        rig.env("NOSTROMO_ACTIVITY_PATH", Some(rig.activity.clone().into()));
        rig.env("NOSTROMO_AGENTS_DIR", Some(rig.agents.clone().into()));
        rig
    }

    fn env(&mut self, key: &'static str, value: Option<OsString>) {
        if !self.saved.iter().any(|(k, _)| *k == key) {
            self.saved.push((key, std::env::var_os(key)));
        }
        match value {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }

    fn declare_agent(&self, agent: &str, model: &str) {
        std::fs::write(
            self.agents.join(format!("{agent}.md")),
            format!("---\nname: {agent}\ndescription: test agent\nmodel: {model}\n---\nYou are {agent}.\n"),
        )
        .unwrap();
    }

    fn set_default(&self, agent: &str, model: &str, effort: Option<&str>) {
        store::set_default(
            &self.paths.defaults,
            agent,
            Some(AgentDefault { model: model.into(), effort: effort.map(str::to_owned) }),
        )
        .unwrap();
    }

    fn clear_default(&self, agent: &str) {
        store::set_default(&self.paths.defaults, agent, None).unwrap();
    }

    fn record(&self, tag: &str) -> Option<FocusModelRecord> {
        store::focus_record(&self.paths.focus_models, tag)
    }

    fn spawn(&mut self, tag: &str, agent: &str) {
        self.mgr
            .spawn_session(tag.into(), agent.into(), format!("view-{tag}"), Some(self.cwd.clone()), None, false)
            .expect("the session starts")
            .expect("a session id");
    }

    /// Every focus-session start (catalogue probes excluded), oldest first.
    fn starts(&self) -> Vec<Vec<String>> {
        let text = std::fs::read_to_string(self.fake.join("argv.log")).unwrap_or_default();
        text.split("--END--\n")
            .filter(|c| !c.is_empty())
            .map(|c| c.lines().map(String::from).collect::<Vec<String>>())
            .filter(|a| a.iter().any(|x| x == "--session-id" || x == "--resume"))
            .collect()
    }

    async fn wait_for_starts(&self, n: usize) -> Vec<Vec<String>> {
        let deadline = Instant::now() + WAIT;
        loop {
            let s = self.starts();
            if s.len() >= n {
                return s;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {n} session start(s)");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    fn activity_lines(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.activity)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    fn lines_of_kind(&self, kind: &str) -> Vec<Value> {
        self.activity_lines().into_iter().filter(|l| l["kind"] == kind).collect()
    }
}

fn arg_of<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let at = args.iter().position(|a| a == flag)?;
    args.get(at + 1).map(String::as_str)
}

fn meta(tag: &str, agent: &str, model: Option<&str>, effort: Option<&str>) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: tag.into(),
        agent_name: agent.into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
        initial_model: model.map(str::to_owned),
        initial_effort: effort.map(str::to_owned),
    }
}

fn target(model: &str, effort: Option<&str>) -> ModelTarget {
    ModelTarget { model: model.into(), effort: effort.map(str::to_owned) }
}

// ── precedence at spawn ───────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_per_agent_default_beats_the_agents_declared_model() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("claudia", "haiku", None);

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("haiku"), "{:?}", runs[0]);
    let record = rig.record(TAG).expect("the new focus has a record");
    assert_eq!((record.model.as_str(), record.source), ("haiku", ModelSource::AgentDefault));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_per_agent_default_carries_its_effort() {
    let mut rig = Rig::new().await;
    rig.set_default("claudia", "opus", Some("high"));

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("opus"), "{:?}", runs[0]);
    assert_eq!(arg_of(&runs[0], "--effort"), Some("high"), "{:?}", runs[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_a_default_the_declared_model_is_used() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("sonnet"), "{:?}", runs[0]);
    assert!(!runs[0].iter().any(|a| a == "--effort"), "{:?}", runs[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_default_for_another_agent_does_not_apply() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("cody", "haiku", None);

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("sonnet"), "{:?}", runs[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_default_and_no_declared_model_the_cli_default_applies_and_nothing_is_written() {
    let mut rig = Rig::new().await;
    rig.declare_agent("other", "opus"); // some other agent declares one; claudia does not

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert!(!runs[0].iter().any(|a| a == "--model"), "{:?}", runs[0]);
    assert!(!runs[0].iter().any(|a| a == "--effort"), "{:?}", runs[0]);
    assert!(rig.record(TAG).is_none(), "nothing is recorded until the CLI reports what ran");
    assert!(!rig.paths.focus_models.exists(), "no store file at all");
    assert!(!rig.paths.defaults.exists(), "no defaults file either");
}

// ── explicit choices ──────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_initial_choice_on_the_focus_beats_the_default_and_the_declared_model() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("claudia", "haiku", None);

    rig.mgr.apply_initial_models(&[meta(TAG, "claudia", Some("opus"), Some("high"))]);
    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("opus"), "{:?}", runs[0]);
    assert_eq!(arg_of(&runs[0], "--effort"), Some("high"), "{:?}", runs[0]);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("opus", ModelSource::Focus));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn repeating_the_initial_choice_in_later_pushes_never_overwrites_the_record() {
    let rig = Rig::new().await;
    rig.mgr.apply_initial_models(&[meta(TAG, "claudia", Some("opus"), None)]);

    rig.mgr.apply_initial_models(&[meta(TAG, "claudia", Some("haiku"), Some("low"))]);

    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.effort), ("opus", None));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unusable_initial_choice_is_ignored_and_the_defaults_apply() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("claudia", "haiku", None);

    rig.mgr.apply_initial_models(&[
        meta(TAG, "claudia", Some("--evil"), None),
        meta("focus-b", "claudia", Some("opus"), Some("ludicrous")),
    ]);
    assert!(rig.record(TAG).is_none());
    assert!(rig.record("focus-b").is_none());
    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("haiku"), "{:?}", runs[0]);
    assert!(!runs[0].iter().any(|a| a == "--evil"), "{:?}", runs[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tool_created_focus_records_its_explicit_choice_before_the_spawn_and_it_beats_the_default() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("claudia", "haiku", None);

    rig.mgr.record_new_focus_model(TAG, "claudia", Some(&target("opus", Some("high"))));
    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("opus"), "{:?}", runs[0]);
    assert_eq!(arg_of(&runs[0], "--effort"), Some("high"), "{:?}", runs[0]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_explicit_effort_alone_rides_on_the_default_model() {
    let mut rig = Rig::new().await;
    rig.set_default("claudia", "haiku", None);

    rig.mgr.record_new_focus_model(TAG, "claudia", Some(&ModelTarget { model: String::new(), effort: Some("low".into()) }));
    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("haiku"), "{:?}", runs[0]);
    assert_eq!(arg_of(&runs[0], "--effort"), Some("low"), "{:?}", runs[0]);
}

// ── existing focuses are immune to default changes ────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn changing_or_clearing_a_default_never_changes_an_existing_focus_on_restart() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.set_default("claudia", "haiku", Some("low"));
    rig.spawn(TAG, "claudia");
    let first = rig.wait_for_starts(1).await.remove(0);
    let before = rig.record(TAG).unwrap();

    rig.set_default("claudia", "opus", Some("high"));
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_starts(2).await;
    assert_eq!(arg_of(&runs[1], "--model"), arg_of(&first, "--model"), "{:?} vs {:?}", runs[1], first);
    assert_eq!(arg_of(&runs[1], "--effort"), arg_of(&first, "--effort"));
    assert_eq!(arg_of(&runs[1], "--model"), Some("haiku"));

    rig.clear_default("claudia");
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_starts(3).await;
    assert_eq!(arg_of(&runs[2], "--model"), Some("haiku"), "{:?}", runs[2]);
    assert_eq!(arg_of(&runs[2], "--effort"), Some("low"), "{:?}", runs[2]);
    assert_eq!(rig.record(TAG).unwrap(), before, "the record is untouched");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_default_set_after_a_focus_started_on_its_declared_model_does_not_move_it() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.spawn(TAG, "claudia");
    rig.wait_for_starts(1).await;

    rig.set_default("claudia", "haiku", None);
    rig.mgr.restart(TAG).unwrap();

    let runs = rig.wait_for_starts(2).await;
    assert!(!runs[1].iter().any(|a| a == "haiku"), "{:?}", runs[1]);
    assert_ne!(rig.record(TAG).map(|r| r.model), Some("haiku".to_owned()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_focus_with_a_record_keeps_it_when_respawned_even_if_a_default_exists() {
    let mut rig = Rig::new().await;
    store::update_focus_record(&rig.paths.focus_models, TAG, |_| {
        Some(FocusModelRecord { model: "fable".into(), source: ModelSource::Focus, ..FocusModelRecord::default() })
    })
    .unwrap();
    rig.set_default("claudia", "haiku", None);

    rig.spawn(TAG, "claudia");

    let runs = rig.wait_for_starts(1).await;
    assert_eq!(arg_of(&runs[0], "--model"), Some("fable"), "{:?}", runs[0]);
    assert_eq!(rig.record(TAG).unwrap().model, "fable");
}

// ── "use for new focuses" ─────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn switching_with_use_for_new_focuses_writes_the_focus_record_and_the_agent_default_with_one_activity_line() {
    let mut rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");
    rig.spawn(TAG, "claudia");
    rig.wait_for_starts(1).await;

    let ticket = rig.mgr.request_switch(
        TAG,
        SwitchRequest {
            model: Some("opus".into()),
            effort: Some(EffortChoice::High),
            actor: Actor::User,
            set_as_agent_default: true,
            request_id: None,
        },
    );
    let outcome = tokio::time::timeout(WAIT, ticket.outcome()).await.expect("the switch finished");

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.effort.as_deref()), ("opus", Some("high")));
    let defaults = store::load_defaults(&rig.paths.defaults);
    let default = defaults.get("claudia").expect("the agent default was written");
    assert_eq!((default.model.as_str(), default.effort.as_deref()), ("opus", Some("high")));
    assert_eq!(rig.lines_of_kind("model_default").len(), 1, "{:#?}", rig.activity_lines());
    assert_eq!(rig.lines_of_kind("model_switch").len(), 1, "{:#?}", rig.activity_lines());

    // And the next focus of that agent starts there.
    rig.spawn("focus-b", "claudia");
    let runs = rig.wait_for_starts(2).await;
    assert_eq!(arg_of(&runs[1], "--model"), Some("opus"), "{:?}", runs[1]);
    assert_eq!(arg_of(&runs[1], "--effort"), Some("high"), "{:?}", runs[1]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn switching_without_use_for_new_focuses_leaves_the_agent_default_alone() {
    let mut rig = Rig::new().await;
    rig.set_default("claudia", "haiku", None);
    rig.spawn(TAG, "claudia");
    rig.wait_for_starts(1).await;

    let ticket = rig.mgr.request_switch(
        TAG,
        SwitchRequest { model: Some("opus".into()), effort: None, actor: Actor::User, set_as_agent_default: false, request_id: None },
    );
    tokio::time::timeout(WAIT, ticket.outcome()).await.expect("the switch finished");

    assert_eq!(store::load_defaults(&rig.paths.defaults).get("claudia").map(|d| d.model.as_str()), Some("haiku"));
    assert!(rig.lines_of_kind("model_default").is_empty());
}

// ── resolve_for_new_focus, unit level ─────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resolving_walks_explicit_then_default_then_declared_then_cli() {
    let rig = Rig::new().await; // holds the env lock and points NOSTROMO_AGENTS_DIR at the temp dir
    let defaults = &rig.paths.defaults;
    rig.declare_agent("claudia", "sonnet");

    let r = store::resolve_for_new_focus(defaults, "claudia", None);
    assert_eq!(r, (Some("sonnet".into()), None, ModelSource::AgentDeclared));

    rig.set_default("claudia", "haiku", Some("low"));
    let r = store::resolve_for_new_focus(defaults, "claudia", None);
    assert_eq!(r, (Some("haiku".into()), Some("low".into()), ModelSource::AgentDefault));

    let r = store::resolve_for_new_focus(defaults, "claudia", Some(&target("opus", Some("max"))));
    assert_eq!(r, (Some("opus".into()), Some("max".into()), ModelSource::Focus));

    // An explicit model with no effort does not inherit the default's effort.
    let r = store::resolve_for_new_focus(defaults, "claudia", Some(&target("opus", None)));
    assert_eq!(r, (Some("opus".into()), None, ModelSource::Focus));

    rig.clear_default("claudia");
    let r = store::resolve_for_new_focus(defaults, "nobody", None);
    assert_eq!(r, (None, None, ModelSource::CliDefault));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_explicit_effort_alone_rides_on_whatever_model_resolves_and_is_dropped_when_none_does() {
    let rig = Rig::new().await;
    let defaults = &rig.paths.defaults;
    let effort_only = ModelTarget { model: String::new(), effort: Some("high".into()) };
    rig.declare_agent("claudia", "sonnet");

    let r = store::resolve_for_new_focus(defaults, "claudia", Some(&effort_only));
    assert_eq!((r.0.as_deref(), r.1.as_deref()), (Some("sonnet"), Some("high")), "declared model + explicit effort");

    rig.set_default("claudia", "haiku", Some("low"));
    let r = store::resolve_for_new_focus(defaults, "claudia", Some(&effort_only));
    assert_eq!((r.0.as_deref(), r.1.as_deref()), (Some("haiku"), Some("high")), "explicit effort beats the default's");

    let r = store::resolve_for_new_focus(defaults, "nobody", Some(&effort_only));
    assert_eq!(r, (None, None, ModelSource::CliDefault), "no model to attach the effort to");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resolving_writes_nothing() {
    let rig = Rig::new().await;
    rig.declare_agent("claudia", "sonnet");

    store::resolve_for_new_focus(&rig.paths.defaults, "claudia", Some(&target("opus", None)));

    assert!(!rig.paths.defaults.exists());
    assert!(!rig.paths.focus_models.exists());
}

#[test]
fn only_plain_model_names_and_known_efforts_are_plausible_choices() {
    for ok in [target("opus", None), target("claude-opus-4-6", Some("high")), target("sonnet[1m]", None)] {
        assert!(store::is_plausible_choice(&ok), "{ok:?}");
    }
    for bad in [target("--evil", None), target("", None), target("a b", None), target("opus", Some("ludicrous")), target(&"x".repeat(65), None)] {
        assert!(!store::is_plausible_choice(&bad), "{bad:?}");
    }
}
