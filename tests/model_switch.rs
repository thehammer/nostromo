//! Model switching, daemon side (slice M1): which Claude model (and effort) each
//! focus's session runs on, how it is switched live, and what the user sees of it.
//!
//! Everything is observed from the outside: the argument vector and the stdin
//! frames a fake `claude` receives, the files the daemon keeps (focus model
//! store, per-agent defaults, notes ledger, activity log), the frames clients
//! receive, and the transcript. Nothing here looks inside the session manager.
//!
//! The fake `claude` (a POSIX sh script, installed once per test process) speaks
//! just enough of the stream-json control protocol: `initialize`, `set_model`,
//! `apply_flag_settings`, `get_settings`, user frames. It writes every argv and
//! every stdin line, in arrival order, to `events.log` in `$FAKE_DIR`, and marks
//! each turn's `result` and each control answer in that same file BEFORE writing
//! it to stdout, so "the daemon wrote X before the turn ended" is detectable.
//!
//! Knobs (all inside `$FAKE_DIR` unless an env var, so a test can change them
//! mid-run):
//! - `hold.<text>` / `release.<text>`: the turn for the user message `<text>`
//!   does not end until `release.<text>` exists.
//! - `hold.set_model` / `release.set_model`: the `set_model` answer waits for the
//!   release file (with `FAKE_SET_MODEL=exit` the process dies on release).
//! - `set_model_mode` file, else `$FAKE_SET_MODEL`: unset = switch for real;
//!   `error:<code>`; `hang` (never answer); `exit`; `noop` (success, no change).
//! - `$FAKE_REPORT_MODEL`: the model named in init / assistant events.
//! - `$FAKE_INITIAL_MODEL`: the model with no `--model` (default claude-sonnet-4-6).
//! - `$FAKE_FALLBACK_REASON`: emit a `model_fallback` system event each turn.
//! - `$FAKE_IGNORE_EFFORT`: `apply_flag_settings` succeeds but changes nothing.
//! - `hold.initialize` / `release.initialize`: the `initialize` answer (a catalogue probe) waits for the
//!   release file. `$FAKE_CATALOG` names the file the answer is read from.
//! - `stall.after.<text>`: after the turn for the user message `<text>` has been handled, the fake stops
//!   reading stdin: it takes the first 4 KiB of the NEXT frame (so the daemon is provably mid-write),
//!   logs `STALLED` to `events.log`, and reads on only once `release.stdin` exists.
//! - `phantom.before.<text>` / `release.phantom`: before it echoes the user message `<text>`, the fake
//!   replays a system entry in wording nothing in the daemon knows (`<new-wrapper>…</new-wrapper>`),
//!   logs `PHANTOM`, and stops reading and answering until `release.phantom` exists.
//! - every start appends `<pwd -P> <entries in it> <its permissions>` to `cwd.log`.
//!
//! No test asserts on wall-clock time. Waits are event-driven with generous
//! timeouts. Env vars are process-global, so every test holds one lock.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use chrono::Utc;
use nostromo::data::work::picks::{picks_restrictions, PICKS_TAG};
use nostromo::ipc::protocol::{
    EffortChoice, FocusMeta, ModelRequestStatus, ServerMsg, SessionModelState, SwitchPhase,
};
use nostromo::ipc::session_manager::{ModelRequestOutcome, SwitchRequest, SwitchTicket, CLAUDE_BIN_ENV};
use nostromo::ipc::stream_json::{transcript_from_jsonl, Turn, TurnBlock, TurnDelta};
use nostromo::ipc::SessionManager;
use nostromo::model::catalog::ModelCatalog;
use nostromo::model::hub::{refresh_catalog, ModelHub};
use nostromo::model::notes::{self, LedgerNote, NoteKind};
use nostromo::model::store::{self, FocusModelRecord, ModelSource};
use nostromo::model::{Actor, ModelPaths, ModelTarget};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc};

const WAIT: Duration = Duration::from_secs(30);
const TAG: &str = "focus-a";

// ── the fake claude ───────────────────────────────────────────────────────────

const FAKE_CLAUDE: &str = r##"#!/bin/sh
D="$FAKE_DIR"
printf '%s\t%s\t%s\n' "$(pwd -P)" "$(ls -A | wc -l | tr -d ' ')" "$(ls -ld . | cut -d' ' -f1)" >> "$D/cwd.log"
S="$D/state.$$"
mkdir -p "$S"
# Appended with one write (a shell's printf writes line by line), so two fakes started together
# never interleave their arguments.
A="$D/argv.$$"
{ for a in "$@"; do printf '%s\n' "$a"; done; printf '%s\n' '--END--'; } > "$A"
cat "$A" >> "$D/argv.log"
rm -f "$A"
printf 'START\n' >> "$D/events.log"

log() { printf '%s\t%s\n' "$1" "$2" >> "$D/events.log"; }

resolve() {
  case "$1" in
    opus) echo claude-opus-5-5 ;;
    fable) echo claude-fable-5-1 ;;
    sonnet|default) echo claude-sonnet-5-5 ;;
    haiku) echo claude-haiku-5-5 ;;
    *) echo "$1" ;;
  esac
}

model=""; effort=""; sid="sid-fake"; prev=""
for a in "$@"; do
  case "$prev" in
    --model) model="$a" ;;
    --effort) effort="$a" ;;
    --session-id|--resume) sid="$a" ;;
  esac
  prev="$a"
done
if [ -n "$model" ]; then cur=$(resolve "$model"); else cur="${FAKE_INITIAL_MODEL:-claude-sonnet-4-6}"; fi
printf '%s' "$cur" > "$S/cur"
printf '%s' "$effort" > "$S/effort"

wait_for() {
  i=0
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -gt 2400 ] && return 1
    kill -0 $$ 2>/dev/null || exit 0
    case "$(ps -o stat= -p $$ 2>/dev/null)" in Z*|"") exit 0 ;; esac
    sleep 0.05
  done
  return 0
}

ctl_ok() { log ANSWER "$2"; printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$1\"$3}}"; }
ctl_err() { log ANSWER "$2"; printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"$1\",\"error\":\"Model 'x' not found\",\"error_code\":\"$3\"}}"; }

do_set_model() {
  rid="$1"; req="$2"; mode="$3"
  case "$mode" in
    hang) return 0 ;;
    error:*) ctl_err "$rid" set_model "${mode#error:}" ;;
    noop) ctl_ok "$rid" set_model ;;
    *)
      res=$(resolve "$req")
      case "$res" in
        claude-*)
          printf '%s' "$res" > "$S/cur"
          printf '%s\n' '{"type":"user","isMeta":true,"isReplay":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"}}'
          printf '%s\n' '{"type":"user","isReplay":true,"message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>x</command-args>"}}'
          printf '%s\n' "{\"type\":\"user\",\"isReplay\":true,\"message\":{\"role\":\"user\",\"content\":\"<local-command-stdout>Set model to $req ($res)</local-command-stdout>\"}}"
          ctl_ok "$rid" set_model ;;
        *) ctl_err "$rid" set_model catalog_unknown ;;
      esac ;;
  esac
}

handle_set_model() {
  rid="$1"; req="$2"
  mode=$(cat "$D/set_model_mode" 2>/dev/null)
  [ -n "$mode" ] || mode="$FAKE_SET_MODEL"
  if [ -e "$D/hold.set_model" ]; then
    ( wait_for "$D/release.set_model"
      if [ "$mode" = exit ]; then kill -TERM $$; else do_set_model "$rid" "$req" "$mode"; fi ) </dev/null &
  else
    if [ "$mode" = exit ]; then exit 1; fi
    do_set_model "$rid" "$req" "$mode"
  fi
}

finish() {
  log RESULT "$1"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0}'
}

turn() {
  text="$1"
  cur=$(cat "$S/cur")
  rep="${FAKE_REPORT_MODEL:-$cur}"
  if [ -e "$D/phantom.before.$text" ]; then
    printf '%s\n' '{"type":"user","isReplay":true,"message":{"role":"user","content":"<new-wrapper>whatever</new-wrapper>"}}'
    log PHANTOM ""
    wait_for "$D/release.phantom"
  fi
  printf '%s\n' "{\"type\":\"user\",\"isReplay\":true,\"message\":{\"role\":\"user\",\"content\":\"$text\"}}"
  if [ -n "$FAKE_FALLBACK_REASON" ]; then
    printf '%s\n' "{\"type\":\"system\",\"subtype\":\"model_fallback\",\"original_model\":\"$cur\",\"fallback_model\":\"$rep\",\"content\":\"$FAKE_FALLBACK_REASON\",\"trigger\":\"overloaded\"}"
  fi
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"$rep\"}"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"$rep\",\"content\":[{\"type\":\"text\",\"text\":\"reply to $text\"}]}}"
  if [ -e "$D/hold.$text" ]; then
    ( wait_for "$D/release.$text"; finish "$text" ) </dev/null &
  else
    finish "$text"
  fi
}

STALL_NEXT=""
next_line() {
  if [ -n "$STALL_NEXT" ]; then
    STALL_NEXT=""
    head=$(dd bs=1 count=4096 2>/dev/null)
    log STALLED ""
    wait_for "$D/release.stdin"
    rest=""
    IFS= read -r rest
    line="$head$rest"
    return 0
  fi
  IFS= read -r line
}

while next_line; do
  log IN "$line"
  case "$line" in
    *'"type":"control_request"'*)
      rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      case "$line" in
        *'"subtype":"initialize"'*)
          [ -e "$D/hold.initialize" ] && wait_for "$D/release.initialize"
          log ANSWER initialize
          tr -d '\n' < "$FAKE_CATALOG" | sed "s/\"request_id\" *: *\"init-1\"/\"request_id\":\"$rid\"/"
          printf '\n' ;;
        *'"subtype":"set_model"'*)
          req=$(printf '%s' "$line" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
          handle_set_model "$rid" "$req" ;;
        *'"subtype":"apply_flag_settings"'*)
          e=$(printf '%s' "$line" | sed -n 's/.*"effortLevel":"\([^"]*\)".*/\1/p')
          [ -n "$FAKE_IGNORE_EFFORT" ] || printf '%s' "$e" > "$S/effort"
          ctl_ok "$rid" apply_flag_settings ;;
        *'"subtype":"get_settings"'*)
          cur=$(cat "$S/cur"); e=$(cat "$S/effort"); [ -n "$e" ] || e=medium
          ctl_ok "$rid" get_settings ",\"response\":{\"applied\":{\"model\":\"$cur\",\"effort\":\"$e\"}}" ;;
        *)
          ctl_ok "$rid" other ;;
      esac ;;
    *'"type":"user"'*)
      text=$(printf '%s' "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
      turn "$text"
      [ -e "$D/stall.after.$text" ] && STALL_NEXT=1 ;;
  esac
done
"##;

static FAKE_DIR_ROOT: OnceLock<PathBuf> = OnceLock::new();

/// Installs the fake `claude` once per test process; returns its path.
fn fake_claude_script() -> PathBuf {
    FAKE_DIR_ROOT
        .get_or_init(|| {
            use std::os::unix::fs::PermissionsExt;
            let dir = std::env::temp_dir().join(format!("nostromo-fake-claude-modelswitch-{}", std::process::id()));
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

fn fixture_json() -> Value {
    serde_json::from_slice(&std::fs::read(fixture_path()).expect("fixture")).expect("fixture is JSON")
}

fn fixture_catalog() -> ModelCatalog {
    ModelCatalog::from_initialize_response(&fixture_json(), Utc::now()).expect("fixture has models")
}

// ── the rig ───────────────────────────────────────────────────────────────────

/// One lock for the whole file: env vars and the fake's log directory are process-global.
static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct Rig {
    _guard: tokio::sync::MutexGuard<'static, ()>,
    _root: tempfile::TempDir,
    /// Where the fake claude keeps its logs and knob files.
    fake: PathBuf,
    /// The daemon's session-id store; every model file lives beside it.
    store_path: PathBuf,
    paths: ModelPaths,
    activity: PathBuf,
    agents: PathBuf,
    cwd: PathBuf,
    mgr: SessionManager,
    model_rx: broadcast::Receiver<ServerMsg>,
    saved: Vec<(&'static str, Option<OsString>)>,
    snaps: usize,
}

impl Drop for Rig {
    fn drop(&mut self) {
        // The sessions' blocking reader threads end only when their children do.
        self.mgr.kill_all_on_shutdown();
        for (key, prev) in self.saved.drain(..).rev() {
            match prev {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}

/// Every knob the fake reads from the environment.
const KNOBS: [&str; 5] =
    ["FAKE_SET_MODEL", "FAKE_REPORT_MODEL", "FAKE_INITIAL_MODEL", "FAKE_FALLBACK_REASON", "FAKE_IGNORE_EFFORT"];

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
        let (tx, model_rx) = broadcast::channel(256);
        mgr.configure_model_broadcast(tx);
        mgr.set_model_catalog(fixture_catalog());

        let mut rig = Rig {
            _guard: guard,
            paths: ModelPaths::beside(&store_path),
            _root: root,
            fake,
            store_path,
            activity,
            agents,
            cwd,
            mgr,
            model_rx,
            saved: Vec::new(),
            snaps: 0,
        };
        rig.env(CLAUDE_BIN_ENV, Some(fake_claude_script().into()));
        rig.env("FAKE_DIR", Some(rig.fake.clone().into()));
        rig.env("FAKE_CATALOG", Some(fixture_path().into()));
        rig.env("NOSTROMO_ACTIVITY_PATH", Some(rig.activity.clone().into()));
        rig.env("NOSTROMO_AGENTS_DIR", Some(rig.agents.clone().into()));
        for knob in KNOBS {
            rig.env(knob, None);
        }
        rig
    }

    /// Set (or clear) an env var for the rest of the test; restored on drop.
    fn env(&mut self, key: &'static str, value: Option<OsString>) {
        if !self.saved.iter().any(|(k, _)| *k == key) {
            self.saved.push((key, std::env::var_os(key)));
        }
        match value {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }

    // ── store / agents ────────────────────────────────────────────────────────

    fn seed(&self, tag: &str, model: &str, effort: Option<&str>) {
        let record = FocusModelRecord {
            model: model.to_owned(),
            effort: effort.map(str::to_owned),
            source: ModelSource::Focus,
            pending: None,
            ..FocusModelRecord::default()
        };
        store::update_focus_record(&self.paths.focus_models, tag, |_| Some(record)).unwrap();
    }

    fn record(&self, tag: &str) -> Option<FocusModelRecord> {
        store::focus_record(&self.paths.focus_models, tag)
    }

    /// An agent definition with front matter `model: <model>`.
    fn declare_agent(&self, agent: &str, model: &str) {
        std::fs::write(
            self.agents.join(format!("{agent}.md")),
            format!("---\nname: {agent}\ndescription: test agent\nmodel: {model}\n---\nYou are {agent}.\n"),
        )
        .unwrap();
    }

    // ── sessions ──────────────────────────────────────────────────────────────

    /// Starts the tag's session; returns the claude session id.
    fn spawn(&mut self, tag: &str, agent: &str) -> String {
        self.mgr
            .spawn_session(tag.into(), agent.into(), format!("view-{tag}"), Some(self.cwd.clone()), None, false)
            .expect("the session starts")
            .expect("a session id")
    }

    fn send(&mut self, tag: &str, text: &str) {
        self.mgr.send_user_message(tag, text, &[]).expect("message accepted");
    }

    fn request(&mut self, tag: &str, req: SwitchRequest) -> SwitchTicket {
        self.mgr.request_switch(tag, req)
    }

    fn state(&self, tag: &str) -> SessionModelState {
        self.mgr.session_model_state(tag)
    }

    // ── the fake's logs ───────────────────────────────────────────────────────

    /// Every argument vector the fake was started with, oldest first.
    fn runs(&self) -> Vec<Vec<String>> {
        let text = std::fs::read_to_string(self.fake.join("argv.log")).unwrap_or_default();
        text.split("--END--\n")
            .filter(|c| !c.is_empty())
            .map(|c| c.lines().map(String::from).collect())
            .collect()
    }

    async fn wait_for_runs(&self, n: usize) -> Vec<Vec<String>> {
        eventually(&format!("{n} process start(s)"), || {
            let runs = self.runs();
            (runs.len() >= n).then_some(runs)
        })
        .await
    }

    /// What the fake saw and did, in order: `start`, `user:<text>`,
    /// `set_model:<model>`, `effort:<level|null>`, `get_settings`, other control
    /// subtypes by name, `answer:<subtype>`, `result:<text>`.
    fn labels(&self) -> Vec<String> {
        let text = std::fs::read_to_string(self.fake.join("events.log")).unwrap_or_default();
        text.lines()
            .filter_map(|l| {
                let (kind, rest) = l.split_once('\t').unwrap_or((l, ""));
                Some(match kind {
                    "START" => "start".to_owned(),
                    "ANSWER" => format!("answer:{rest}"),
                    "RESULT" => format!("result:{rest}"),
                    "PHANTOM" => "phantom".to_owned(),
                    "IN" => {
                        let v: Value = serde_json::from_str(rest).ok()?;
                        match v["type"].as_str()? {
                            "user" => format!("user:{}", v["message"]["content"].as_str().unwrap_or("?")),
                            "control_request" => match v["request"]["subtype"].as_str()? {
                                "set_model" => format!("set_model:{}", v["request"]["model"].as_str().unwrap_or("?")),
                                "apply_flag_settings" => format!(
                                    "effort:{}",
                                    v["request"]["settings"]["effortLevel"].as_str().unwrap_or("null")
                                ),
                                other => other.to_owned(),
                            },
                            other => other.to_owned(),
                        }
                    }
                    _ => return None,
                })
            })
            .collect()
    }

    /// What the daemon wrote and what ended a turn: [`Self::labels`] without
    /// process starts, control answers, `initialize` and the phantom marker.
    fn wire(&self) -> Vec<String> {
        self.labels()
            .into_iter()
            .filter(|l| l != "start" && l != "initialize" && l != "phantom" && !l.starts_with("answer:"))
            .collect()
    }

    async fn wait_for(&self, label: &str) {
        eventually(label, || self.labels().iter().any(|l| l == label).then_some(())).await
    }

    fn hold(&self, what: &str) {
        std::fs::write(self.fake.join(format!("hold.{what}")), "").unwrap();
    }

    fn release(&self, what: &str) {
        std::fs::write(self.fake.join(format!("release.{what}")), "").unwrap();
    }

    /// Change how the fake answers `set_model` from now on.
    fn set_model_mode(&self, mode: &str) {
        std::fs::write(self.fake.join("set_model_mode"), mode).unwrap();
    }

    // ── what the daemon recorded ──────────────────────────────────────────────

    fn ledger(&self, sid: &str) -> Vec<LedgerNote> {
        notes::load(&self.paths.notes_dir, sid)
    }

    fn ledger_of_kind(&self, sid: &str, kind: NoteKind) -> Vec<LedgerNote> {
        self.ledger(sid).into_iter().filter(|n| n.kind == kind).collect()
    }

    fn activity_lines(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.activity)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    fn model_switch_lines(&self) -> Vec<Value> {
        self.activity_lines().into_iter().filter(|l| l["kind"] == "model_switch").collect()
    }

    /// Every `SessionModelState` broadcast so far, oldest first.
    fn state_broadcasts(&mut self) -> Vec<SessionModelState> {
        let mut out = Vec::new();
        loop {
            match self.model_rx.try_recv() {
                Ok(ServerMsg::SessionModelState(s)) => out.push(s),
                Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_)) => {}
                Err(_) => break,
            }
        }
        out
    }

    // ── what a client sees ────────────────────────────────────────────────────

    /// Attach a client to the tag and keep what it receives.
    fn observe(&mut self, tag: &str, client: &str) -> Observer {
        let (tx, rx) = mpsc::unbounded_channel();
        self.mgr.client_sender_registry().lock().unwrap().insert(client.to_owned(), tx);
        self.mgr.attach(tag, client).expect("attach");
        Observer { rx, seen: Vec::new() }
    }

    /// The transcript as a freshly attaching client receives it.
    fn snapshot(&mut self, tag: &str) -> Vec<Turn> {
        self.snaps += 1;
        let client = format!("snapshot-{}", self.snaps);
        let mut obs = self.observe(tag, &client);
        obs.drain();
        let turns = obs
            .seen
            .iter()
            .find_map(|m| match m {
                ServerMsg::SessionTurns { turns, .. } => Some(turns.clone()),
                _ => None,
            })
            .expect("attach sends the transcript");
        self.mgr.detach(tag, &client);
        turns
    }
}

struct Observer {
    rx: mpsc::UnboundedReceiver<ServerMsg>,
    seen: Vec<ServerMsg>,
}

impl Observer {
    fn drain(&mut self) {
        while let Ok(m) = self.rx.try_recv() {
            self.seen.push(m);
        }
    }

    /// Has a text block `text` been appended to a turn?
    fn saw_text(&mut self, text: &str) -> bool {
        self.drain();
        self.seen.iter().any(|m| {
            matches!(m, ServerMsg::SessionTurnDelta { delta: TurnDelta::BlockAppended { block: TurnBlock::Text { text: t }, .. }, .. } if t == text)
        })
    }

    /// Has a turn been closed as errored (a phantom, or a crash)?
    fn saw_a_turn_errored(&mut self) -> bool {
        self.drain();
        self.seen.iter().any(|m| matches!(m, ServerMsg::SessionTurnDelta { delta: TurnDelta::TurnErrored { .. }, .. }))
    }

    /// Note deltas received so far, in order.
    fn notes(&mut self) -> Vec<(NoteKind, String)> {
        self.drain();
        self.seen
            .iter()
            .filter_map(|m| match m {
                ServerMsg::SessionTurnDelta { delta: TurnDelta::Note { block: TurnBlock::Note { note_kind, text, .. }, .. }, .. } => {
                    Some((*note_kind, text.clone()))
                }
                _ => None,
            })
            .collect()
    }
}

/// Poll until `f` yields (30 s at most): events, not sleeps, decide when a test proceeds.
async fn eventually<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A ticket's outcome, bounded: a switch that never finishes fails the test instead of hanging it.
async fn settle(ticket: SwitchTicket) -> ModelRequestOutcome {
    tokio::time::timeout(WAIT, ticket.outcome()).await.expect("the switch never finished")
}

fn req(model: Option<&str>, effort: Option<EffortChoice>, actor: Actor) -> SwitchRequest {
    SwitchRequest { model: model.map(str::to_owned), effort, actor, set_as_agent_default: false, request_id: None }
}

fn to_model(model: &str) -> SwitchRequest {
    req(Some(model), None, Actor::User)
}

/// How many sessions the fake has been started as so far (catalogue probes not counted).
fn rig_starts(rig: &Rig) -> usize {
    rig.runs().iter().filter(|r| is_start_of_session(r)).count()
}

/// Is this argument vector the start of a focus's session (as opposed to a catalogue probe)?
fn is_start_of_session(args: &[String]) -> bool {
    args.iter().any(|a| a == "--session-id" || a == "--resume")
}

/// The argument following `flag`, if present.
fn arg_of<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let at = args.iter().position(|a| a == flag)?;
    args.get(at + 1).map(String::as_str)
}

/// A transcript flattened to `user:<input>`, `text:<text>`, `note:<kind>:<text>` in order.
fn flat(turns: &[Turn]) -> Vec<String> {
    let mut out = Vec::new();
    for t in turns {
        out.push(format!("user:{}", t.user_input));
        for b in &t.blocks {
            match b {
                TurnBlock::Text { text } => out.push(format!("text:{text}")),
                TurnBlock::Note { note_kind, text, .. } => out.push(format!("note:{note_kind:?}:{text}")),
                _ => {}
            }
        }
    }
    out
}

fn notes_of(turns: &[Turn], kind: NoteKind) -> Vec<String> {
    turns
        .iter()
        .flat_map(|t| t.blocks.iter())
        .filter_map(|b| match b {
            TurnBlock::Note { note_kind, text, .. } if *note_kind == kind => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn position(flat: &[String], needle: &str) -> usize {
    flat.iter().position(|l| l.contains(needle)).unwrap_or_else(|| panic!("{needle:?} not in transcript: {flat:#?}"))
}

// ── the catalogue ─────────────────────────────────────────────────────────────

#[test]
fn the_catalogue_lists_families_cheapest_first_without_default_and_splits_out_pinned_versions() {
    let catalog = fixture_catalog();

    let families: Vec<&str> = catalog.families.iter().map(|e| e.value.as_str()).collect();
    assert_eq!(families, ["haiku", "sonnet", "opus", "fable"], "cost order, `default` excluded");
    let mut pinned: Vec<&str> = catalog.pinned.iter().map(|e| e.value.as_str()).collect();
    pinned.sort();
    assert_eq!(pinned, ["claude-haiku-4-5-20251001", "claude-opus-4-6"]);
    assert!(!catalog.stale, "a catalogue parsed from a live answer is not stale");

    let opus = catalog.family("opus").expect("opus row");
    assert_eq!(opus.resolved_model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(opus.display_name.as_deref(), Some("Opus 5.5"));
    assert_eq!(opus.supported_effort_levels, ["low", "medium", "high", "xhigh", "max"]);
    assert!(opus.supports_effort);

    let old_haiku = catalog.entry("claude-haiku-4-5-20251001").expect("pinned row");
    assert!(!old_haiku.supports_effort);
    assert!(old_haiku.supported_effort_levels.is_empty());
    let old_opus = catalog.entry("claude-opus-4-6").expect("pinned row");
    assert_eq!(old_opus.supported_effort_levels, ["low", "medium", "high", "max"]);
}

#[test]
fn a_family_the_cli_starts_offering_appears_after_the_known_ones() {
    let mut answer = fixture_json();
    let models = answer["response"]["response"]["models"].as_array_mut().unwrap();
    models.push(json!({"value": "zeta", "resolvedModel": "claude-zeta-1", "displayName": "Zeta", "supportedEffortLevels": [], "supportsEffort": false}));
    models.insert(0, json!({"value": "alpha", "resolvedModel": "claude-alpha-1", "displayName": "Alpha", "supportedEffortLevels": [], "supportsEffort": false}));

    let catalog = ModelCatalog::from_initialize_response(&answer, Utc::now()).unwrap();

    let families: Vec<&str> = catalog.families.iter().map(|e| e.value.as_str()).collect();
    assert_eq!(families, ["haiku", "sonnet", "opus", "fable", "alpha", "zeta"]);
}

#[test]
fn an_answer_without_a_model_list_is_not_a_catalogue() {
    let answer = json!({"type": "control_response", "response": {"subtype": "success", "request_id": "x", "response": {"commands": []}}});
    assert!(ModelCatalog::from_initialize_response(&answer, Utc::now()).is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probing_the_cli_reads_its_initialize_answer() {
    let rig = Rig::new().await;

    let catalog = nostromo::model::catalog::probe(&fake_claude_script()).await.expect("the probe succeeds");

    let families: Vec<&str> = catalog.families.iter().map(|e| e.value.as_str()).collect();
    assert_eq!(families, ["haiku", "sonnet", "opus", "fable"]);
    assert!(!catalog.stale);
    drop(rig);
}

// ── spawn arguments ───────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_focus_with_no_model_record_starts_with_no_model_flag_at_all() {
    let mut rig = Rig::new().await;
    assert!(!rig.paths.focus_models.exists(), "no store file at all");

    rig.spawn(TAG, "");

    let runs = rig.wait_for_runs(1).await;
    assert!(!runs[0].iter().any(|a| a == "--model"), "unchanged argv for existing focuses: {:?}", runs[0]);
    assert!(!runs[0].iter().any(|a| a == "--effort"), "{:?}", runs[0]);
    let state = rig.state(TAG);
    assert!(state.recorded.is_none(), "nothing chosen yet and nothing reported");
    assert!(state.running);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_recorded_model_and_effort_are_passed_at_every_start() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "opus", Some("high"));
    rig.spawn(TAG, "");
    rig.wait_for_runs(1).await; // a child killed before its shell logged its start would leave no trace
    rig.mgr.restart(TAG).unwrap();
    rig.wait_for_runs(2).await;
    rig.seed("other", "haiku", None);
    rig.spawn("other", "");

    let runs = rig.wait_for_runs(3).await;

    for run in &runs[..2] {
        assert_eq!(arg_of(run, "--model"), Some("opus"), "{run:?}");
        assert_eq!(arg_of(run, "--effort"), Some("high"), "{run:?}");
    }
    assert_eq!(arg_of(&runs[2], "--model"), Some("haiku"), "{:?}", runs[2]);
    assert!(!runs[2].iter().any(|a| a == "--effort"), "--effort only when an effort is recorded: {:?}", runs[2]);
}

// ── (a) the idle switch ───────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_idle_switch_changes_the_model_live_records_one_note_and_survives_a_restart() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    let mut observer = rig.observe(TAG, "window-1");

    let outcome = settle(rig.request(TAG, to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    assert_eq!(rig.wire(), ["set_model:opus", "get_settings"], "one set_model, no effort change, one verification");
    let record = rig.record(TAG).expect("a record");
    assert_eq!((record.model.as_str(), record.effort.clone(), record.source), ("opus", None, ModelSource::Focus));
    assert_eq!(record.pending, None);

    let ledger = rig.ledger(&sid);
    assert_eq!(ledger.len(), 1, "{ledger:?}");
    assert_eq!(ledger[0].kind, NoteKind::ModelChanged);
    assert_eq!(ledger[0].text, "Model changed to Opus (from Sonnet) by you.");
    assert_eq!(ledger[0].after_prompt, 0);
    eventually("the note delta", || (!observer.notes().is_empty()).then_some(())).await;
    assert_eq!(observer.notes(), [(NoteKind::ModelChanged, "Model changed to Opus (from Sonnet) by you.".to_owned())]);

    let state = rig.state(TAG);
    assert_eq!(state.phase, SwitchPhase::Steady);
    assert_eq!(state.pending, None);
    assert!(state.running);
    assert_eq!(state.recorded.as_ref().map(|r| r.model.as_str()), Some("opus"));
    let reported = state.reported.expect("the switch confirmed what the session runs");
    assert_eq!(reported.model, "claude-opus-5-5");
    assert_eq!(reported.family.as_deref(), Some("opus"));
    eventually("a state broadcast for the new model", || {
        rig.state_broadcasts()
            .iter()
            .any(|s| s.tag == TAG && s.recorded.as_ref().map(|r| r.model.as_str()) == Some("opus") && s.phase == SwitchPhase::Steady)
            .then_some(())
    })
    .await;

    // The conversation goes on on the new model; the CLI's three /model replay frames made no turn.
    rig.send(TAG, "after-switch");
    rig.wait_for("result:after-switch").await;
    assert_eq!(rig.state(TAG).reported.unwrap().model, "claude-opus-5-5");
    let turns = rig.snapshot(TAG);
    assert_eq!(turns.len(), 1, "no bubble for the /model replay frames: {:?}", flat(&turns));
    assert_eq!(turns[0].user_input, "after-switch");

    // A restart (or crash recovery) starts on the switched model.
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_runs(2).await;
    assert_eq!(arg_of(&runs[1], "--model"), Some("opus"), "{:?}", runs[1]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_effort_change_goes_through_apply_flag_settings_only_when_the_effort_changes() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let first = settle(rig.request(TAG, req(Some("opus"), Some(EffortChoice::High), Actor::User))).await;

    assert_eq!(first.status, ModelRequestStatus::Applied);
    assert_eq!(rig.wire(), ["set_model:opus", "effort:high", "get_settings"]);
    assert_eq!(rig.ledger(&sid)[0].text, "Model changed to Opus · effort high (from Sonnet) by you.");
    assert_eq!(rig.record(TAG).unwrap().effort.as_deref(), Some("high"));
    assert_eq!(rig.state(TAG).effective_effort.as_deref(), Some("high"));

    // Effort alone: no set_model.
    let second = settle(rig.request(TAG, req(None, Some(EffortChoice::Low), Actor::User))).await;
    assert_eq!(second.status, ModelRequestStatus::Applied);
    assert_eq!(&rig.wire()[3..], ["effort:low", "get_settings"]);
    assert_eq!(rig.state(TAG).effective_effort.as_deref(), Some("low"));

    // Back to the model's default: null.
    let third = settle(rig.request(TAG, req(None, Some(EffortChoice::Default), Actor::User))).await;
    assert_eq!(third.status, ModelRequestStatus::Applied);
    assert_eq!(&rig.wire()[5..], ["effort:null", "get_settings"]);
    assert_eq!(rig.record(TAG).unwrap().effort, None);

    // Model alone with an unchanged effort: no apply_flag_settings.
    let fourth = settle(rig.request(TAG, to_model("haiku"))).await;
    assert_eq!(fourth.status, ModelRequestStatus::Applied);
    assert_eq!(&rig.wire()[7..], ["set_model:haiku", "get_settings"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_script_switch_is_attributed_to_the_script() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, req(Some("opus"), None, Actor::Script))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    assert_eq!(rig.ledger(&sid)[0].text, "Model changed to Opus (from Sonnet) by script.");
}

// Changed from "…the catalogue does not list…" (with a fresh catalogue): a fresh catalogue is the CLI's
// own list and no longer lets a full name it does not offer through (see the tests under "a full name
// is no longer accepted blindly"). A STALE catalogue still cannot say a full name is wrong.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_stale_catalogue_a_full_name_it_does_not_list_goes_to_the_cli_and_reads_as_the_family() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(stale_catalog());
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, to_model("claude-opus-4-1"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied, "{outcome:?}");
    assert_eq!(rig.wire(), ["set_model:claude-opus-4-1", "get_settings"]);
    assert_eq!(rig.record(TAG).unwrap().model, "claude-opus-4-1");
    assert_eq!(rig.ledger(&sid)[0].text, "Model changed to Opus (from Sonnet) by you.");
}

// ── (b) a switch during a turn waits for it ───────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_during_a_turn_waits_for_the_turn_then_the_queue_drains_one_message_per_turn_on_the_new_model() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    let mut observer = rig.observe(TAG, "window-1");
    rig.hold("user1");
    rig.send(TAG, "user1");
    rig.wait_for("user:user1").await;

    let ticket = rig.request(TAG, to_model("opus"));

    let immediate = ticket.immediate().expect("a mid-turn switch answers at once");
    assert_eq!(immediate.status, ModelRequestStatus::PendingTurnEnd);
    let state = rig.state(TAG);
    assert_eq!(state.phase, SwitchPhase::Waiting);
    assert_eq!(state.pending.as_ref().map(|p| p.model.as_str()), Some("opus"));
    assert_eq!(state.recorded.as_ref().map(|r| r.model.as_str()), Some("sonnet"), "still on the old model");
    assert_eq!(rig.record(TAG).unwrap().pending, Some(ModelTarget { model: "opus".into(), effort: None }));

    rig.send(TAG, "user2");
    rig.send(TAG, "user3");
    assert_eq!(rig.wire(), ["user:user1"], "nothing is written while the turn runs");

    rig.release("user1");
    rig.wait_for("result:user3").await;

    assert_eq!(
        rig.wire(),
        [
            "user:user1",
            "result:user1",
            "set_model:opus",
            "get_settings",
            "user:user2",
            "result:user2",
            "user:user3",
            "result:user3"
        ],
        "the switch lands between turns, then one queued message per turn, each exactly once"
    );
    let turns = rig.snapshot(TAG);
    assert_eq!(turns.iter().map(|t| t.user_input.as_str()).collect::<Vec<_>>(), ["user1", "user2", "user3"]);
    let flat = flat(&turns);
    assert_eq!(flat.iter().filter(|l| l.starts_with("text:reply to")).count(), 3, "{flat:#?}");
    assert_eq!(notes_of(&turns, NoteKind::ModelChanged), ["Model changed to Opus (from Sonnet) by you."]);
    assert_eq!(notes_of(&turns, NoteKind::ModelPending), ["Switching to Opus after this turn"]);
    assert!(position(&flat, "Model changed") < position(&flat, "user:user2"), "the note sits before the queued messages: {flat:#?}");
    let changed = rig.ledger_of_kind(&sid, NoteKind::ModelChanged);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].after_prompt, 1, "after the first prompt's turn");
    assert_eq!(rig.state(TAG).reported.unwrap().model, "claude-opus-5-5");
    assert_eq!(rig.state(TAG).phase, SwitchPhase::Steady);
    assert_eq!(rig.record(TAG).unwrap().pending, None);
    eventually("the pending note delta", || {
        observer.notes().iter().any(|(k, _)| *k == NoteKind::ModelPending).then_some(())
    })
    .await;
    let kinds: Vec<NoteKind> = observer.notes().into_iter().map(|(k, _)| k).collect();
    assert_eq!(kinds, [NoteKind::ModelPending, NoteKind::ModelChanged]);
}

// ── (c) re-selecting while waiting ────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn choosing_again_while_a_switch_waits_replaces_the_target() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    rig.hold("user1");
    rig.send(TAG, "user1");
    rig.wait_for("user:user1").await;

    let first = rig.request(TAG, to_model("opus"));
    let second = rig.request(TAG, to_model("fable"));

    assert_eq!(first.immediate().unwrap().status, ModelRequestStatus::PendingTurnEnd);
    assert_eq!(second.immediate().unwrap().status, ModelRequestStatus::PendingTurnEnd);
    assert_eq!(rig.state(TAG).pending.as_ref().map(|p| p.model.as_str()), Some("fable"));

    rig.release("user1");
    eventually("the switch to apply", || (!rig.ledger_of_kind(&sid, NoteKind::ModelChanged).is_empty()).then_some(())).await;

    assert_eq!(rig.wire(), ["user:user1", "result:user1", "set_model:fable", "get_settings"], "only the last choice is applied");
    assert_eq!(rig.record(TAG).unwrap().model, "fable");
    let changed = rig.ledger_of_kind(&sid, NoteKind::ModelChanged);
    assert_eq!(changed.len(), 1, "at most one Model changed note: {changed:?}");
    assert_eq!(changed[0].text, "Model changed to Fable (from Sonnet) by you.");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn choosing_the_current_model_while_a_switch_waits_cancels_it_silently() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    rig.hold("user1");
    rig.send(TAG, "user1");
    rig.wait_for("user:user1").await;
    assert_eq!(rig.request(TAG, to_model("opus")).immediate().unwrap().status, ModelRequestStatus::PendingTurnEnd);

    let cancel = settle(rig.request(TAG, to_model("sonnet"))).await;

    assert_eq!(cancel.status, ModelRequestStatus::Unchanged);
    let state = rig.state(TAG);
    assert_eq!(state.pending, None);
    assert_eq!(state.phase, SwitchPhase::Steady);
    assert_eq!(rig.record(TAG).unwrap().pending, None);

    rig.release("user1");
    rig.wait_for("result:user1").await;
    // A message after the turn: anything the daemon wrongly sent at turn end would sit before it.
    rig.send(TAG, "user2");
    rig.wait_for("result:user2").await;

    assert_eq!(rig.wire(), ["user:user1", "result:user1", "user:user2", "result:user2"], "nothing was sent for the cancelled switch");
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelChanged).is_empty());
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelFailed).is_empty());
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet");
    assert!(rig.model_switch_lines().is_empty(), "a cancel is not logged: {:?}", rig.activity_lines());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn choosing_the_model_already_in_use_does_nothing() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, to_model("sonnet"))).await;
    let effort_same = settle(rig.request(TAG, req(None, Some(EffortChoice::Default), Actor::User))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Unchanged);
    assert_eq!(effort_same.status, ModelRequestStatus::Unchanged);
    assert!(rig.wire().is_empty(), "nothing sent: {:?}", rig.wire());
    assert!(rig.ledger(&sid).is_empty(), "no note");
    assert!(rig.activity_lines().is_empty(), "no activity entry");
}

// ── (d) a rejected switch ─────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_the_cli_rejects_leaves_the_session_on_the_old_model_and_delivers_queued_messages_once_after_the_note() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_SET_MODEL", Some("error:catalog_unknown".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    rig.hold("set_model");

    let ticket = rig.request(TAG, to_model("opus"));
    rig.wait_for("set_model:opus").await;
    assert_eq!(rig.state(TAG).phase, SwitchPhase::Applying);
    rig.send(TAG, "queued1");
    rig.release("set_model");
    let outcome = settle(ticket).await;

    assert_eq!(outcome.status, ModelRequestStatus::Failed);
    assert!(outcome.message.as_deref().unwrap_or("").contains("not found"), "the CLI's reason reaches the caller: {outcome:?}");
    rig.wait_for("result:queued1").await;
    assert_eq!(
        rig.wire().iter().filter(|l| l.starts_with("set_model:") || l.starts_with("user:") || l.starts_with("result:")).cloned().collect::<Vec<_>>(),
        ["set_model:opus", "user:queued1", "result:queued1"],
        "the queued message is written once, after the switch ended, never during it"
    );
    let events = rig.labels();
    assert!(
        position(&events, "answer:set_model") < position(&events, "user:queued1"),
        "the user frame was written only after the control answer: {events:?}"
    );
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.pending.clone()), ("sonnet", None), "the recorded choice did not change");
    let state = rig.state(TAG);
    assert_eq!(state.phase, SwitchPhase::Steady);
    assert_eq!(state.recorded.unwrap().model, "sonnet");
    let failed = rig.ledger_of_kind(&sid, NoteKind::ModelFailed);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].text.starts_with("Couldn't switch to Opus: "), "{}", failed[0].text);
    assert!(failed[0].text.contains("not found"), "{}", failed[0].text);
    assert!(failed[0].text.ends_with("Still on Sonnet."), "{}", failed[0].text);
    let transcript = flat(&rig.snapshot(TAG));
    assert!(position(&transcript, "Couldn't switch to Opus") < position(&transcript, "text:reply to queued1"), "note first, then the queued reply: {transcript:#?}");
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelChanged).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_the_cli_accepts_but_does_not_perform_is_a_failure_not_a_success() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_SET_MODEL", Some("noop".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Failed, "get_settings still says sonnet");
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet");
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelChanged).is_empty());
    let failed = rig.ledger_of_kind(&sid, NoteKind::ModelFailed);
    assert_eq!(failed.len(), 1);
    assert!(failed[0].text.ends_with("Still on Sonnet."), "{}", failed[0].text);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_effort_the_cli_silently_ignores_is_a_failure_and_the_recorded_effort_stays() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_IGNORE_EFFORT", Some("1".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, req(None, Some(EffortChoice::High), Actor::User))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Failed);
    assert_eq!(&rig.wire()[..2], ["effort:high", "get_settings"]);
    assert_eq!(rig.record(TAG).unwrap().effort, None);
    let failed = rig.ledger_of_kind(&sid, NoteKind::ModelFailed);
    assert_eq!(failed.len(), 1);
    assert!(failed[0].text.starts_with("Couldn't switch to"), "{}", failed[0].text);
    assert!(failed[0].text.ends_with("Still on Sonnet."), "{}", failed[0].text);
}

// ── (e) a CLI that never answers ──────────────────────────────────────────────

#[tokio::test]
async fn a_switch_the_cli_never_answers_times_out_after_ten_seconds_and_the_session_stays_usable() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_SET_MODEL", Some("hang".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");

    let ticket = rig.request(TAG, to_model("opus"));
    rig.wait_for("set_model:opus").await; // real time: the request really reached the CLI

    // Now the clock is ours. Time is advanced in steps until the ticket resolves; a real-time
    // pause between steps lets the daemon's tasks and the fake's process run.
    tokio::time::pause();
    let mut outcome = Box::pin(ticket.outcome());
    let started = Instant::now();
    let outcome = loop {
        tokio::select! {
            biased;
            o = &mut outcome => break o,
            _ = tokio::task::yield_now() => {}
        }
        assert!(started.elapsed() < WAIT, "the ten second timeout never fired");
        tokio::time::advance(Duration::from_secs(11)).await;
        std::thread::sleep(Duration::from_millis(5));
    };
    tokio::time::resume();

    assert_eq!(outcome.status, ModelRequestStatus::Failed);
    let failed = rig.ledger_of_kind(&sid, NoteKind::ModelFailed);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].text.starts_with("Couldn't switch to Opus: "), "{}", failed[0].text);
    assert!(failed[0].text.ends_with("Still on Sonnet."), "{}", failed[0].text);
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet");
    assert_eq!(rig.state(TAG).phase, SwitchPhase::Steady);
    rig.send(TAG, "after-timeout");
    rig.wait_for("result:after-timeout").await;
    assert_eq!(rig.wire().iter().filter(|l| *l == "user:after-timeout").count(), 1);
}

// ── (f) the process dies mid-switch ───────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_dies_mid_switch_comes_back_on_the_old_model_with_the_queued_message_delivered_once() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_SET_MODEL", Some("exit".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    let _window = rig.observe(TAG, "window-1");
    rig.hold("set_model");

    let ticket = rig.request(TAG, to_model("opus"));
    rig.wait_for("set_model:opus").await;
    rig.send(TAG, "queued1");
    assert_eq!(rig.state(TAG).phase, SwitchPhase::Applying);
    rig.release("set_model"); // the fake dies now
    let outcome = settle(ticket).await;

    assert_eq!(outcome.status, ModelRequestStatus::Failed);
    eventually("the Couldn't switch note", || (!rig.ledger_of_kind(&sid, NoteKind::ModelFailed).is_empty()).then_some(())).await;
    let failed = rig.ledger_of_kind(&sid, NoteKind::ModelFailed);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert!(failed[0].text.starts_with("Couldn't switch to Opus: "), "{}", failed[0].text);
    assert!(failed[0].text.ends_with("Still on Sonnet."), "{}", failed[0].text);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.pending.clone()), ("sonnet", None));

    // The supervisor tick brings the session back, on the model it was recorded on.
    let started = Instant::now();
    let runs = loop {
        rig.mgr.reap_and_recover();
        let runs = rig.runs();
        if runs.len() >= 2 {
            break runs;
        }
        assert!(started.elapsed() < WAIT, "the session was never respawned");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert_eq!(arg_of(&runs[1], "--model"), Some("sonnet"), "the respawn carries the OLD model: {:?}", runs[1]);
    assert!(runs[1].iter().any(|a| a == "--resume"), "{:?}", runs[1]);

    rig.wait_for("result:queued1").await;
    let delivered: Vec<String> = rig.wire().into_iter().filter(|l| l.starts_with("user:") || l.starts_with("result:")).collect();
    assert_eq!(delivered, ["user:queued1", "result:queued1"], "the message queued during the switch is neither lost nor duplicated");
    let events = rig.labels();
    let second_start = events.iter().enumerate().filter(|(_, l)| *l == "start").nth(1).map(|(i, _)| i).unwrap();
    assert!(position(&events, "user:queued1") > second_start, "it went to the respawned session: {events:?}");
}

// ── (g) the daemon restarts mid-switch ────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_still_waiting_when_the_daemon_restarts_is_dropped_and_the_ledger_says_so() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    rig.hold("user1");
    rig.send(TAG, "user1");
    rig.wait_for("user:user1").await;
    assert_eq!(rig.request(TAG, to_model("opus")).immediate().unwrap().status, ModelRequestStatus::PendingTurnEnd);
    assert!(rig.record(TAG).unwrap().pending.is_some(), "the waiting switch is persisted");

    // The daemon dies right now: what it left on disk is all a new daemon has.
    let crashed = rig._root.path().join("after-crash");
    std::fs::create_dir_all(&crashed).unwrap();
    for entry in std::fs::read_dir(rig.store_path.parent().unwrap()).unwrap().flatten() {
        if entry.path().is_file() {
            std::fs::copy(entry.path(), crashed.join(entry.file_name())).unwrap();
        }
    }
    rig.release("user1"); // let the held turn end so nothing is left holding the child's pipes
    let new_paths = ModelPaths::beside(&crashed.join("sessions.json"));
    assert!(store::focus_record(&new_paths.focus_models, TAG).unwrap().pending.is_some());

    let mut restarted = SessionManager::with_store_path(crashed.join("sessions.json"));
    restarted.set_model_catalog(fixture_catalog());
    restarted.clear_persisted_pending();

    let record = store::focus_record(&new_paths.focus_models, TAG).unwrap();
    assert_eq!(record.pending, None, "no pending switch survives a daemon start");
    assert_eq!(record.model, "sonnet");
    let ledger = notes::load(&new_paths.notes_dir, &sid);
    assert_eq!(ledger.len(), 1, "{ledger:?}");
    assert_eq!(ledger[0].kind, NoteKind::ModelFailed);
    assert_eq!(ledger[0].text, "Couldn't switch to Opus: nostromd restarted. Still on Sonnet.");
}

// ── (h) the session runs something else than asked ────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_running_another_model_than_recorded_gets_exactly_one_mismatch_note() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_REPORT_MODEL", Some("claude-sonnet-5-5".into()));
    rig.seed(TAG, "opus", None);
    let sid = rig.spawn(TAG, "");

    rig.send(TAG, "m1");
    rig.wait_for("result:m1").await;
    eventually("the mismatch note", || (!rig.ledger_of_kind(&sid, NoteKind::ModelMismatch).is_empty()).then_some(())).await;
    rig.send(TAG, "m2");
    rig.wait_for("result:m2").await;
    rig.send(TAG, "m3");
    rig.wait_for("result:m3").await;

    let mismatch = rig.ledger_of_kind(&sid, NoteKind::ModelMismatch);
    assert_eq!(mismatch.len(), 1, "once per distinct mismatch, not once per turn: {mismatch:?}");
    assert!(mismatch[0].text.starts_with("Asked for Opus; the session is running Sonnet"), "{}", mismatch[0].text);
    let state = rig.state(TAG);
    assert_eq!(state.reported.unwrap().model, "claude-sonnet-5-5", "the chip shows what is running");
    assert_eq!(state.recorded.unwrap().model, "opus", "the recorded choice is not rewritten by a fallback");
    assert_eq!(notes_of(&rig.snapshot(TAG), NoteKind::ModelMismatch).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fallback_reason_the_cli_gives_is_part_of_the_mismatch_note() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_REPORT_MODEL", Some("claude-sonnet-5-5".into()));
    rig.env("FAKE_FALLBACK_REASON", Some("Opus is overloaded".into()));
    rig.seed(TAG, "opus", None);
    let sid = rig.spawn(TAG, "");

    rig.send(TAG, "m1");
    rig.wait_for("result:m1").await;
    eventually("the mismatch note", || (!rig.ledger_of_kind(&sid, NoteKind::ModelMismatch).is_empty()).then_some(())).await;

    let mismatch = rig.ledger_of_kind(&sid, NoteKind::ModelMismatch);
    assert_eq!(mismatch.len(), 1);
    assert!(mismatch[0].text.starts_with("Asked for Opus; the session is running Sonnet"), "{}", mismatch[0].text);
    assert!(mismatch[0].text.contains("(Opus is overloaded)"), "{}", mismatch[0].text);
}

// ── (i) the recorded model is no longer offered ───────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_recorded_family_the_cli_no_longer_offers_starts_on_the_agents_model_with_a_note() {
    let mut rig = Rig::new().await;
    let mut answer = fixture_json();
    answer["response"]["response"]["models"].as_array_mut().unwrap().retain(|m| m["value"] != "fable");
    rig.mgr.set_model_catalog(ModelCatalog::from_initialize_response(&answer, Utc::now()).unwrap());
    rig.declare_agent("declarer", "sonnet");
    rig.seed(TAG, "fable", None);

    let sid = rig.spawn(TAG, "declarer");

    let runs = rig.wait_for_runs(1).await;
    // The fallback is the agent's own model: an observed record, not a choice, so no `--model` is passed
    // and the agent's front matter decides (chosen-vs-observed, review item 9).
    assert_eq!(arg_of(&runs[0], "--model"), None, "falls back to the agent's model, not a failing start: {:?}", runs[0]);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared));
    let unavailable = rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable);
    assert_eq!(unavailable.len(), 1, "{unavailable:?}");
    assert_eq!(unavailable[0].text, "Fable is no longer available; this focus now uses Sonnet.");
    assert_eq!(rig.state(TAG).recorded.unwrap().model, "sonnet");
}

// ── (j) existing focuses keep the model they run ──────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_focus_with_no_record_takes_the_model_its_session_first_reports_without_any_note() {
    let mut rig = Rig::new().await;
    let sid = rig.spawn(TAG, "plain-agent");

    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;

    let record = eventually("the migrated record", || rig.record(TAG)).await;
    assert_eq!(record.model, "claude-sonnet-4-6", "a name no family alias resolves to is kept in full");
    assert_eq!(record.source, ModelSource::CliDefault);
    assert_eq!(record.effort, None);
    assert_eq!(record.pending, None);
    assert!(rig.ledger(&sid).is_empty(), "shipping the feature changes nothing the user sees");
    assert!(rig.activity_lines().is_empty());
    assert!(!rig.runs()[0].iter().any(|a| a == "--model"), "the first start was unchanged");
    assert!(rig.wire() == ["user:hello", "result:hello"], "no control traffic: {:?}", rig.wire());
    assert_eq!(rig.state(TAG).recorded.unwrap().model, "claude-sonnet-4-6");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_migrated_focus_records_the_family_alias_and_that_its_agent_declared_the_model() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_INITIAL_MODEL", Some("claude-haiku-5-5".into()));
    rig.declare_agent("declarer", "haiku");
    let sid = rig.spawn(TAG, "declarer");

    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;

    let record = eventually("the migrated record", || rig.record(TAG)).await;
    assert_eq!((record.model.as_str(), record.source), ("haiku", ModelSource::AgentDeclared));
    assert!(rig.ledger(&sid).is_empty());
    assert!(rig.activity_lines().is_empty());
}

// ── (k) restricted sessions ───────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restricted_session_never_gets_a_model_flag_a_record_or_a_switch() {
    let mut rig = Rig::new().await;
    rig.mgr.restrict_tag("locked-tag", picks_restrictions());
    // Even a record someone wrote for the picks tag is not passed on.
    rig.seed(PICKS_TAG, "opus", None);
    rig.spawn(PICKS_TAG, "");
    let locked_sid = rig.spawn("locked-tag", "");

    let picks = settle(rig.request(PICKS_TAG, to_model("fable"))).await;
    let locked = settle(rig.request("locked-tag", to_model("opus"))).await;
    rig.send("locked-tag", "hello");
    rig.wait_for("result:hello").await;

    for outcome in [&picks, &locked] {
        assert_eq!(outcome.status, ModelRequestStatus::Refused);
        assert_eq!(outcome.code.as_deref(), Some("not_permitted"));
    }
    let runs = rig.wait_for_runs(2).await;
    for run in &runs {
        assert!(!run.iter().any(|a| a == "--model"), "no model flag for a restricted tag: {run:?}");
        assert!(!run.iter().any(|a| a == "--effort"), "{run:?}");
    }
    assert_eq!(rig.wire(), ["user:hello", "result:hello"], "nothing about models was written to either session");
    assert!(rig.record("locked-tag").is_none(), "no record created, not even by migration");
    assert_eq!(rig.record(PICKS_TAG).unwrap().model, "opus", "the refusal changed nothing");
    assert!(rig.ledger(&locked_sid).is_empty());
}

// ── (l) refusals that never reach the CLI ─────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_effort_the_model_does_not_support_is_refused_before_anything_is_sent() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "claude-haiku-4-5-20251001", None);
    let sid = rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, req(None, Some(EffortChoice::High), Actor::User))).await;
    let opus_old = settle(rig.request(TAG, req(Some("claude-opus-4-6"), Some(EffortChoice::Xhigh), Actor::User))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Refused);
    assert_eq!(outcome.code.as_deref(), Some("unsupported_effort"));
    assert_eq!(opus_old.status, ModelRequestStatus::Refused, "claude-opus-4-6 has no xhigh");
    assert_eq!(opus_old.code.as_deref(), Some("unsupported_effort"));
    assert!(rig.wire().is_empty(), "nothing sent: {:?}", rig.wire());
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.effort.clone()), ("claude-haiku-4-5-20251001", None));
    assert!(rig.ledger(&sid).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_alias_the_catalogue_does_not_list_is_refused_as_an_unknown_model() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn(TAG, "");

    let outcome = settle(rig.request(TAG, to_model("gemini"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Refused);
    assert_eq!(outcome.code.as_deref(), Some("unknown_model"));
    assert!(rig.wire().is_empty(), "{:?}", rig.wire());
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet");
}

// ── session not running ───────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_on_a_session_that_is_not_running_is_stored_for_its_next_start() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    rig.wait_for_runs(1).await;
    rig.mgr.stop(TAG);
    assert!(!rig.state(TAG).running);

    let outcome = settle(rig.request(TAG, to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    assert_eq!(rig.record(TAG).unwrap().model, "opus");
    let ledger = rig.ledger(&sid);
    assert_eq!(ledger.len(), 1, "{ledger:?}");
    assert_eq!(ledger[0].text, "Model set to Opus; takes effect when the session starts.");
    assert!(rig.wire().is_empty(), "nothing to send to a stopped session");
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_runs(2).await;
    assert_eq!(arg_of(&runs[1], "--model"), Some("opus"), "{:?}", runs[1]);
}

// ── per-agent defaults ────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn use_for_new_focuses_sets_the_agent_default_and_a_default_change_never_touches_existing_focuses() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.seed("sibling", "sonnet", None);
    rig.spawn(TAG, "cody");

    let ticket = rig.request(TAG, SwitchRequest { model: Some("opus".into()), effort: None, actor: Actor::User, set_as_agent_default: true, request_id: None });
    let switched = settle(ticket).await;

    assert_eq!(switched.status, ModelRequestStatus::Applied);
    let defaults = store::load_defaults(&rig.paths.defaults);
    assert_eq!(defaults.get("cody").map(|d| d.model.as_str()), Some("opus"));
    assert_eq!(rig.record("sibling").unwrap().model, "sonnet", "other focuses of the agent are unchanged");

    let changed = rig.mgr.set_agent_default("cody", Some("fable".into()), Some(EffortChoice::High), false);
    assert_eq!(changed.status, ModelRequestStatus::Applied);
    let defaults = store::load_defaults(&rig.paths.defaults);
    let cody = defaults.get("cody").unwrap();
    assert_eq!((cody.model.as_str(), cody.effort.as_deref()), ("fable", Some("high")));
    assert_eq!(rig.record(TAG).unwrap().model, "opus", "an existing focus keeps its model");
    assert_eq!(rig.wire(), ["set_model:opus", "get_settings"], "a running session is not switched under the user");

    let refused = rig.mgr.set_agent_default("cody", Some("gemini".into()), None, false);
    assert_eq!(refused.status, ModelRequestStatus::Refused);
    assert_eq!(refused.code.as_deref(), Some("unknown_model"));
    assert_eq!(store::load_defaults(&rig.paths.defaults).get("cody").unwrap().model, "fable");

    let cleared = rig.mgr.set_agent_default("cody", None, None, true);
    assert_eq!(cleared.status, ModelRequestStatus::Applied);
    assert!(!store::load_defaults(&rig.paths.defaults).contains_key("cody"));
}

// ── (n) the audit trail ───────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_applied_failed_or_refused_switch_appends_exactly_one_activity_line() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "cody");

    let applied = settle(rig.request(TAG, req(Some("opus"), None, Actor::User))).await;
    rig.set_model_mode("error:catalog_unknown");
    let failed = settle(rig.request(TAG, req(Some("fable"), None, Actor::Script))).await;
    let refused = settle(rig.request(TAG, req(Some("gemini"), None, Actor::User))).await;
    let unchanged = settle(rig.request(TAG, req(Some("opus"), None, Actor::User))).await;

    assert_eq!(applied.status, ModelRequestStatus::Applied);
    assert_eq!(failed.status, ModelRequestStatus::Failed);
    assert_eq!(refused.status, ModelRequestStatus::Refused);
    assert_eq!(unchanged.status, ModelRequestStatus::Unchanged);
    let lines = rig.model_switch_lines();
    assert_eq!(lines.len(), 3, "an unchanged request logs nothing: {lines:#?}");
    let outcomes: Vec<&str> = lines.iter().map(|l| l["outcome"].as_str().unwrap()).collect();
    assert_eq!(outcomes, ["applied", "failed", "refused"]);
    let actors: Vec<&str> = lines.iter().map(|l| l["actor"].as_str().unwrap()).collect();
    assert_eq!(actors, ["user", "script", "user"]);
    for line in &lines {
        assert_eq!(line["focus_tag"], TAG);
        assert_eq!(line["session_id"], sid.as_str());
        assert!(line["ts"].as_str().is_some_and(|t| t.ends_with('Z') || t.contains('+')), "UTC ISO-8601: {line}");
        assert!(line["summary"].as_str().is_some_and(|s| !s.is_empty()), "{line}");
    }
    assert_eq!((lines[0]["from"]["model"].as_str(), lines[0]["to"]["model"].as_str()), (Some("sonnet"), Some("opus")));
    assert_eq!((lines[1]["from"]["model"].as_str(), lines[1]["to"]["model"].as_str()), (Some("opus"), Some("fable")));
    assert_eq!((lines[2]["from"]["model"].as_str(), lines[2]["to"]["model"].as_str()), (Some("opus"), Some("gemini")));

    let before = rig.activity_lines().len();
    let default = rig.mgr.set_agent_default("cody", Some("haiku".into()), None, false);
    assert_eq!(default.status, ModelRequestStatus::Applied);
    let after = rig.activity_lines();
    assert_eq!(after.len(), before + 1);
    assert_eq!(after.last().unwrap()["kind"], "model_default");
    assert_eq!(rig.model_switch_lines().len(), 3);
}

// ── (m) hydration ─────────────────────────────────────────────────────────────

const CAVEAT: &str = "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>";

fn stored_session() -> String {
    let user = |text: &str| json!({"type": "user", "message": {"role": "user", "content": text}, "timestamp": "2026-10-12T10:00:00.000Z"}).to_string();
    let reply = |text: &str| {
        json!({"type": "assistant", "message": {"role": "assistant", "model": "claude-sonnet-5-5", "content": [{"type": "text", "text": text}]}}).to_string()
    };
    let caveat = json!({"type": "user", "isMeta": true, "message": {"role": "user", "content": CAVEAT}}).to_string();
    [
        user("first question"),
        reply("first answer"),
        caveat,
        user("<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>"),
        user("<local-command-stdout>Set model to opus (claude-opus-5-5)</local-command-stdout>"),
        user("second question"),
        reply("second answer"),
    ]
    .join("\n")
}

fn ledger_note(after_prompt: u64, kind: NoteKind, text: &str) -> LedgerNote {
    LedgerNote { after_prompt, kind, text: text.to_owned(), ts: Utc::now() }
}

#[test]
fn the_clis_three_model_command_entries_make_no_turn_when_a_transcript_is_rebuilt() {
    let transcript = transcript_from_jsonl(&stored_session(), 100);

    let turns = transcript.snapshot();
    assert_eq!(turns.iter().map(|t| t.user_input.as_str()).collect::<Vec<_>>(), ["first question", "second question"]);
    assert_eq!(transcript.prompt_count(), 2);
    assert!(
        turns.iter().all(|t| t.blocks.iter().all(|b| !matches!(b, TurnBlock::Note { .. }))),
        "the CLI's entries are not turned into notes either"
    );
}

#[test]
fn ledger_notes_are_put_back_after_the_turn_of_their_prompt_number() {
    let mut transcript = transcript_from_jsonl(&stored_session(), 100);

    transcript.merge_ledger_notes(&[
        ledger_note(1, NoteKind::ModelChanged, "Model changed to Opus (from Sonnet) by you."),
        ledger_note(2, NoteKind::ModelFailed, "Couldn't switch to Haiku: nope. Still on Opus."),
    ]);

    let turns = transcript.snapshot();
    assert_eq!(turns.len(), 2);
    assert_eq!(notes_of(&turns[..1], NoteKind::ModelChanged), ["Model changed to Opus (from Sonnet) by you."]);
    assert!(notes_of(&turns[1..], NoteKind::ModelChanged).is_empty());
    assert_eq!(notes_of(&turns[1..], NoteKind::ModelFailed), ["Couldn't switch to Haiku: nope. Still on Opus."]);
    assert_eq!(notes_of(&turns[..1], NoteKind::ModelFailed).len(), 0);
}

#[test]
fn a_note_made_before_any_prompt_leads_the_first_turn() {
    let mut transcript = transcript_from_jsonl("", 100);
    transcript.merge_ledger_notes(&[ledger_note(0, NoteKind::ModelChanged, "Model changed to Opus (from Sonnet) by you.")]);

    let delta = transcript.ingest_line(&json!({"type": "user", "message": {"role": "user", "content": "hello"}}).to_string());

    assert_eq!(delta.len(), 1);
    let turns = transcript.snapshot();
    assert_eq!(turns.len(), 1);
    assert_eq!(notes_of(&turns, NoteKind::ModelChanged).len(), 1, "{:?}", flat(&turns));
    assert!(matches!(turns[0].blocks.first(), Some(TurnBlock::Note { .. })), "the note leads the turn");
}

#[test]
fn a_leading_nostromo_note_is_not_part_of_the_prompt_the_user_sees() {
    let prompt = "<nostromo-note>Your request for Opus was approved.</nostromo-note>\n\nthird question";
    let jsonl = [stored_session(), json!({"type": "user", "message": {"role": "user", "content": prompt}}).to_string()].join("\n");

    let transcript = transcript_from_jsonl(&jsonl, 100);

    let turns = transcript.snapshot();
    assert_eq!(turns.last().unwrap().user_input, "third question");
}

// ══════════════════════════════════════════════════════════════════════════════
// Review fix-ups (PR #236): validation, probe hygiene, lock hygiene, robustness,
// housekeeping, and chosen-vs-observed records.
// ══════════════════════════════════════════════════════════════════════════════

// ── helpers for the review fix-up tests ───────────────────────────────────────

fn focus_meta(tag: &str) -> FocusMeta {
    FocusMeta {
        initial_model: None,
        initial_effort: None,
        tag: tag.into(),
        display_name: tag.into(),
        agent_name: "cody".into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
    }
}

/// The fixture catalogue, flagged as what an earlier probe saw.
fn stale_catalog() -> ModelCatalog {
    ModelCatalog { stale: true, ..fixture_catalog() }
}

fn family_names(catalog: &ModelCatalog) -> Vec<String> {
    catalog.families.iter().map(|f| f.value.clone()).collect()
}

impl Rig {
    /// A record with an explicit source, written straight to the store.
    fn seed_sourced(&self, tag: &str, model: &str, effort: Option<&str>, source: ModelSource) {
        let record =
            FocusModelRecord { model: model.to_owned(), effort: effort.map(str::to_owned), source, ..FocusModelRecord::default() };
        store::update_focus_record(&self.paths.focus_models, tag, |_| Some(record)).unwrap();
    }

    /// Tell the daemon about these focuses, twice, so it can vouch for the registry
    /// (`registry_known()` needs two non-empty pushes).
    fn register(&mut self, tags: &[&str]) {
        let metas: Vec<FocusMeta> = tags.iter().map(|t| focus_meta(t)).collect();
        self.mgr.set_focus_registry(metas.clone());
        self.mgr.set_focus_registry(metas);
    }

    /// Start `tag` and stop it again: a focus the daemon knows, that is not running and has no record.
    async fn spawn_and_stop(&mut self, tag: &str) -> String {
        let n = self.runs().len();
        let sid = self.spawn(tag, "");
        self.wait_for_runs(n + 1).await;
        self.mgr.stop(tag);
        sid
    }

    /// Start `tag` of `agent` on a stored (chosen) `model`; the argument vector of that start.
    async fn start_on_stored(&mut self, tag: &str, agent: &str, model: &str) -> (Vec<String>, String) {
        self.seed(tag, model, None);
        let n = self.runs().len();
        let sid = self.spawn(tag, agent);
        let runs = self.wait_for_runs(n + 1).await;
        (runs[n].clone(), sid)
    }

    /// Every `(directory, entries in it, permissions)` the fake was started in, oldest first.
    fn start_dirs(&self) -> Vec<(String, String, String)> {
        std::fs::read_to_string(self.fake.join("cwd.log"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let mut f = l.split('\t');
                Some((f.next()?.to_owned(), f.next()?.to_owned(), f.next()?.to_owned()))
            })
            .collect()
    }

    /// The daemon after a restart: a new manager over the same files, so its catalogue is what the
    /// cache holds (served stale, and unverified by any probe this run).
    fn restart_daemon(&mut self) {
        let mut mgr = SessionManager::with_store_path(self.store_path.clone());
        let (tx, rx) = broadcast::channel(256);
        mgr.configure_model_broadcast(tx);
        self.model_rx = rx;
        self.mgr = mgr;
    }

    /// Wait until every process the fake was started as has logged its start (it logs its argument
    /// vector first, so an argument vector alone does not say the start is in `events.log` yet).
    async fn wait_for_all_starts_logged(&self) -> Vec<Vec<String>> {
        eventually("every start to be logged", || {
            let runs = self.runs();
            (!runs.is_empty() && self.labels().iter().filter(|l| *l == "start").count() == runs.len()).then_some(runs)
        })
        .await
    }

    /// The fake has stopped reading stdin (see `stall.after.<text>`).
    fn stalled(&self) -> bool {
        std::fs::read_to_string(self.fake.join("events.log")).unwrap_or_default().lines().any(|l| l.starts_with("STALLED"))
    }

    async fn wait_for_stall(&self) {
        eventually("the fake to stop reading stdin", || self.stalled().then_some(())).await
    }

    fn stall_after(&self, text: &str) {
        std::fs::write(self.fake.join(format!("stall.after.{text}")), "").unwrap();
    }

    /// Wait until the session respawns (the supervisor tick), driving it as the daemon does.
    async fn recover(&mut self, runs: usize) -> Vec<Vec<String>> {
        let started = Instant::now();
        loop {
            self.mgr.reap_and_recover();
            let all = self.runs();
            if all.len() >= runs {
                return all;
            }
            assert!(started.elapsed() < WAIT, "the session was never respawned");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

/// Points the session at a (private) home directory for the rest of the test.
fn private_home(rig: &mut Rig) -> PathBuf {
    let home = rig._root.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    rig.env("HOME", Some(home.clone().into()));
    home
}

/// A stored session (see [`stored_session`]) under `home` as the CLI keeps it.
fn store_session(home: &Path, sid: &str, jsonl: &str) {
    let dir = home.join(".claude").join("projects").join("-some-project");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{sid}.jsonl")), jsonl).unwrap();
}

// ── (2) validation: a typo never reaches the store, whatever the catalogue holds ─

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_catalogue_a_typo_or_a_foreign_model_is_still_refused_and_nothing_is_stored() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(ModelCatalog::default());
    let sid = rig.spawn_and_stop(TAG).await;

    for bad in ["opuss", "gpt-4", "default"] {
        let outcome = settle(rig.request(TAG, to_model(bad))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Refused, "{bad}: {outcome:?}");
        assert_eq!(outcome.code.as_deref(), Some("unknown_model"), "{bad}");
        assert!(rig.record(TAG).is_none(), "{bad}: a refused model must leave no record behind");
    }
    assert!(rig.ledger(&sid).is_empty(), "nothing was changed, so nothing is noted");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_catalogue_a_known_family_or_a_full_model_name_is_still_accepted() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(ModelCatalog::default());
    rig.spawn_and_stop(TAG).await;

    for good in ["opus", "claude-opus-4-6", "fable", "haiku", "sonnet"] {
        let outcome = settle(rig.request(TAG, to_model(good))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Applied, "{good}: {outcome:?}");
        assert_eq!(rig.record(TAG).map(|r| r.model), Some(good.to_owned()), "{good}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_catalogue_a_typo_is_refused_and_default_is_never_a_model() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn_and_stop(TAG).await;

    for bad in ["opuss", "default"] {
        let outcome = settle(rig.request(TAG, to_model(bad))).await;
        assert_eq!((outcome.status, outcome.code.as_deref()), (ModelRequestStatus::Refused, Some("unknown_model")), "{bad}");
    }
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet");
}

#[test]
fn an_empty_model_list_is_not_a_catalogue() {
    let answer = json!({"type": "control_response", "response": {"subtype": "success", "request_id": "x", "response": {"models": []}}});
    assert!(ModelCatalog::from_initialize_response(&answer, Utc::now()).is_none());
    assert!(ModelCatalog::from_initialize_response(&json!({"response": {"models": []}}), Utc::now()).is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_probe_that_finds_no_models_keeps_the_previous_catalogue_and_flags_it_stale() {
    let mut rig = Rig::new().await;
    let mut empty = fixture_json();
    empty["response"]["response"]["models"] = json!([]);
    let empty_path = rig.fake.join("empty-catalog.json");
    std::fs::write(&empty_path, serde_json::to_vec(&empty).unwrap()).unwrap();
    rig.env("FAKE_CATALOG", Some(empty_path.into()));
    let hub = ModelHub::new(ModelPaths::beside(&rig._root.path().join("hub").join("sessions.json")));
    hub.set_catalog(fixture_catalog());
    assert!(!hub.catalog().stale);

    let result = refresh_catalog(&hub).await;

    assert!(result.is_err(), "no models is a failed probe, not an empty catalogue");
    assert_eq!(family_names(&hub.catalog()), ["haiku", "sonnet", "opus", "fable"], "the previous catalogue is kept");
    assert!(hub.catalog().stale, "and flagged as what an earlier probe saw");
    assert!(matches!(hub.catalog_msg(), ServerMsg::ModelCatalog { stale: true, ref families, .. } if families.len() == 4));
}

// ── (2) agents that inherit, and recorded models nobody offers ────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_agent_that_inherits_its_model_declares_none_and_its_focus_is_never_given_a_model_flag() {
    let mut rig = Rig::new().await;
    rig.declare_agent("inheritor", "inherit");

    rig.spawn(TAG, "inheritor");
    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;
    let record = eventually("the migrated record", || rig.record(TAG)).await;
    rig.mgr.restart(TAG).unwrap();
    rig.mgr.reap_and_recover();
    let runs = rig.wait_for_runs(2).await;

    assert_eq!(record.source, ModelSource::CliDefault, "`model: inherit` declares nothing, so the CLI's default is what ran");
    for run in &runs {
        assert!(!run.iter().any(|a| a == "--model"), "{run:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_focus_of_an_agent_that_declares_nothing_is_started_with_no_model_flag() {
    let mut rig = Rig::new().await;
    std::fs::write(rig.agents.join("silent.md"), "---\nname: silent\ndescription: no model line\n---\nYou are silent.\n").unwrap();

    rig.spawn(TAG, "silent");
    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;
    eventually("the migrated record", || rig.record(TAG)).await;
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_runs(2).await;

    assert_eq!(runs.iter().filter(|r| r.iter().any(|a| a == "--model")).count(), 0, "{runs:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_model_that_is_no_model_at_all_is_not_passed_when_there_is_no_catalogue() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(ModelCatalog::default());
    rig.declare_agent("declarer", "sonnet");

    let (argv, sid) = rig.start_on_stored(TAG, "declarer", "opuss").await;

    assert!(!argv.iter().any(|a| a == "opuss"), "a typo must not become a failing start: {argv:?}");
    assert_eq!(arg_of(&argv, "--model"), None, "the agent's own model applies through its front matter: {argv:?}");
    let unavailable = rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable);
    assert_eq!(unavailable.len(), 1, "{unavailable:?}");
    assert!(unavailable[0].text.contains("is no longer available"), "{}", unavailable[0].text);
    assert!(unavailable[0].text.ends_with("this focus now uses Sonnet."), "{}", unavailable[0].text);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_model_the_catalogue_does_not_list_is_not_passed_and_the_focus_falls_back_to_the_agents_model() {
    let mut rig = Rig::new().await;
    rig.declare_agent("declarer", "sonnet");

    let (argv, sid) = rig.start_on_stored(TAG, "declarer", "opuss").await;

    assert!(!argv.iter().any(|a| a == "opuss"), "{argv:?}");
    assert_eq!(arg_of(&argv, "--model"), None, "{argv:?}");
    assert_eq!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).len(), 1);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unlisted_stored_model_is_replaced_by_the_agents_default_which_is_a_choice_and_so_is_passed() {
    let mut rig = Rig::new().await;
    rig.declare_agent("declarer", "sonnet");
    assert_eq!(rig.mgr.set_agent_default("declarer", Some("haiku".into()), None, false).status, ModelRequestStatus::Applied);

    let (argv, sid) = rig.start_on_stored(TAG, "declarer", "opuss").await;

    assert_eq!(arg_of(&argv, "--model"), Some("haiku"), "the user's per-agent default beats the front matter: {argv:?}");
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("haiku", ModelSource::AgentDefault));
    let unavailable = rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable);
    assert_eq!(unavailable.len(), 1, "{unavailable:?}");
    assert!(unavailable[0].text.ends_with("this focus now uses Haiku."), "{}", unavailable[0].text);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_default_the_catalogue_does_not_offer_either_is_skipped_for_the_agents_declared_model() {
    let mut rig = Rig::new().await;
    rig.declare_agent("declarer", "sonnet");
    store::set_default(&rig.paths.defaults, "declarer", Some(store::AgentDefault { model: "gemini".into(), effort: None })).unwrap();

    let (argv, _sid) = rig.start_on_stored(TAG, "declarer", "opuss").await;

    assert!(!argv.iter().any(|a| a == "gemini" || a == "opuss"), "neither unoffered name is passed: {argv:?}");
    assert_eq!(arg_of(&argv, "--model"), None, "the declared model is observed, not chosen: {argv:?}");
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_default_and_no_declared_model_an_unlisted_stored_model_leaves_the_cli_default_and_a_note() {
    for catalog in [ModelCatalog::default(), fixture_catalog()] {
        let mut rig = Rig::new().await;
        rig.mgr.set_model_catalog(catalog);

        let (argv, sid) = rig.start_on_stored(TAG, "plain-agent", "opuss").await;

        assert!(!argv.iter().any(|a| a == "--model" || a == "opuss"), "{argv:?}");
        assert!(rig.record(TAG).is_none(), "nothing is recorded until the session reports what it runs");
        assert_eq!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).len(), 1);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_model_is_passed_through_unchanged_when_the_catalogue_is_only_stale() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(stale_catalog());

    let (argv, sid) = rig.start_on_stored(TAG, "", "opuss").await;

    assert_eq!(arg_of(&argv, "--model"), Some("opuss"), "a stale catalogue is no proof a model is gone: {argv:?}");
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).is_empty());
    assert_eq!(rig.record(TAG).unwrap().model, "opuss");
}

// Changed from `[ModelCatalog::default(), fixture_catalog()]`: with a FRESH catalogue a stored full name
// the CLI does not offer is no longer passed (see "a full name is no longer accepted blindly"); with no
// catalogue, or a stale one, it still is.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_full_model_name_and_a_known_family_are_passed_through_while_the_catalogue_is_missing_or_stale() {
    for catalog in [ModelCatalog::default(), stale_catalog()] {
        let mut rig = Rig::new().await;
        rig.mgr.set_model_catalog(catalog);

        let (pinned, _) = rig.start_on_stored("pinned", "", "claude-haiku-3-0").await;
        let (family, _) = rig.start_on_stored("family", "", "opus").await;

        assert_eq!(arg_of(&pinned, "--model"), Some("claude-haiku-3-0"), "{pinned:?}");
        assert_eq!(arg_of(&family, "--model"), Some("opus"), "{family:?}");
    }
}

// ── (3) the catalogue probe runs somewhere harmless ───────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_probe_runs_in_its_own_private_empty_directory_which_is_gone_when_it_returns() {
    let rig = Rig::new().await;

    nostromo::model::catalog::probe(&fake_claude_script()).await.expect("the first probe");
    nostromo::model::catalog::probe(&fake_claude_script()).await.expect("the second probe");

    let dirs = rig.start_dirs();
    assert_eq!(dirs.len(), 2, "{dirs:?}");
    let temp = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    for (dir, entries, permissions) in &dirs {
        assert_ne!(Path::new(dir), temp, "the CLI scans its cwd; the shared temp dir is not a place to run it");
        assert_eq!(entries, "0", "the directory it starts in is empty: {dir}");
        // `ls -ld` style `drwx------`, maybe with a trailing `@`/`+` marker.
        let mode: String = permissions.chars().take(10).collect();
        assert!(mode.ends_with("------"), "private to the daemon's user: {permissions} {dir}");
        assert!(!Path::new(dir).exists(), "removed when the probe returns: {dir}");
    }
    assert_ne!(dirs[0].0, dirs[1].0, "every probe gets a fresh one");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_probe_that_fails_still_cleans_up_its_directory() {
    let mut rig = Rig::new().await;
    let refusal = rig.fake.join("error-catalog.json"); // the CLI answers `initialize` with an error
    std::fs::write(&refusal, r#"{"type":"control_response","response":{"subtype":"error","request_id":"init-1","error":"boom"}}"#).unwrap();
    rig.env("FAKE_CATALOG", Some(refusal.into()));

    let result = nostromo::model::catalog::probe(&fake_claude_script()).await;

    assert!(result.is_err());
    let dirs = rig.start_dirs();
    assert_eq!(dirs.len(), 1, "{dirs:?}");
    assert!(!Path::new(&dirs[0].0).exists(), "removed even though the probe failed: {}", dirs[0].0);
}

// ── (4) lock hygiene: a CLI that stops reading must not wedge the daemon ──────
//
// A user message bigger than the pipe buffer, written to a CLI that has stopped reading its stdin,
// blocks the writer. Whatever blocks must not be something the rest of the daemon needs: listing
// sessions, reading a model state, sending another message and restarting the session all go
// through the same `Arc<Mutex<SessionManager>>` the daemon shares.

/// Far larger than any pipe buffer.
const BIG_BYTES: usize = 1 << 20;

fn big_text() -> String {
    format!("BIG{}", "x".repeat(BIG_BYTES))
}

/// The wire labels with the big message abbreviated to `…BIG`.
fn terse(labels: Vec<String>) -> Vec<String> {
    labels.into_iter().map(|l| if l.len() > 200 { format!("{}BIG", l.split("BIG").next().unwrap_or("")) } else { l }).collect()
}

/// The session manager behind the mutex a daemon shares it through. Every call runs on a
/// blocking thread under a deadline, so a wedged manager fails the test instead of hanging it.
struct Daemon {
    mgr: Arc<std::sync::Mutex<SessionManager>>,
    fake: PathBuf,
}

impl Daemon {
    /// Move the rig's manager behind a mutex.
    fn take(rig: &mut Rig) -> Daemon {
        let placeholder = SessionManager::with_store_path(rig._root.path().join("placeholder").join("sessions.json"));
        let mgr = std::mem::replace(&mut rig.mgr, placeholder);
        Daemon { mgr: Arc::new(std::sync::Mutex::new(mgr)), fake: rig.fake.clone() }
    }

    async fn call<T: Send + 'static>(&self, what: &str, f: impl FnOnce(&mut SessionManager) -> T + Send + 'static) -> T {
        let mgr = Arc::clone(&self.mgr);
        let task = tokio::task::spawn_blocking(move || {
            let mut guard = mgr.lock().unwrap_or_else(|e| e.into_inner());
            f(&mut guard)
        });
        tokio::time::timeout(WAIT, task)
            .await
            .unwrap_or_else(|_| panic!("{what} never returned: the session manager is wedged behind a write to a CLI that stopped reading"))
            .expect("the call did not panic")
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = std::fs::write(self.fake.join("release.stdin"), ""); // un-wedge anything still blocked
        self.mgr.lock().unwrap_or_else(|e| e.into_inner()).kill_all_on_shutdown();
    }
}

/// Lets a stalled fake read again when the test ends (or fails), before the daemon is torn down.
struct Unstick(PathBuf);

impl Drop for Unstick {
    fn drop(&mut self) {
        let _ = std::fs::write(self.0.join("release.stdin"), "");
    }
}

/// A turn is running, a huge message (and, with `queue_later`, a small one after it) is queued behind
/// it, the turn ends and the daemon starts writing the huge frame to a CLI that has stopped reading.
async fn stall_on_a_big_write(rig: &mut Rig, queue_later: bool) -> (Daemon, Unstick) {
    rig.seed(TAG, "sonnet", None);
    rig.spawn(TAG, "");
    rig.hold("turn1");
    rig.stall_after("turn1");
    rig.send(TAG, "turn1");
    rig.wait_for("user:turn1").await;
    let big = big_text();
    rig.send(TAG, &big);
    if queue_later {
        rig.send(TAG, "later");
    }
    let daemon = Daemon::take(rig);
    let unstick = Unstick(rig.fake.clone());

    rig.release("turn1");
    rig.wait_for_stall().await; // the CLI took the first bytes of the frame: the daemon is inside the write

    (daemon, unstick)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_message_stuck_in_a_full_pipe_does_not_wedge_the_session_manager_and_is_delivered_once_in_order() {
    let mut rig = Rig::new().await;
    let (daemon, _unstick) = stall_on_a_big_write(&mut rig, false).await;

    let listed = daemon.call("list()", |m| m.list().len()).await;
    let state = daemon.call("session_model_state()", |m| m.session_model_state(TAG)).await;
    let accepted = daemon.call("send_user_message()", |m| m.send_user_message(TAG, "later", &[])).await;

    assert_eq!(listed, 1);
    assert!(state.running);
    accepted.expect("a message sent while the CLI is slow to read is accepted, and queued");
    std::fs::write(rig.fake.join("release.stdin"), "").unwrap();
    rig.wait_for("result:later").await;
    assert_eq!(
        terse(rig.wire()),
        ["user:turn1", "result:turn1", "user:BIG", "result:BIG", "user:later", "result:later"],
        "the big message exactly once, then the one sent meanwhile exactly once, in order"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_while_a_write_is_stuck_hands_the_queued_messages_to_the_new_process_once_in_order() {
    let mut rig = Rig::new().await;
    let (daemon, _unstick) = stall_on_a_big_write(&mut rig, true).await;

    daemon.call("restart()", |m| m.restart(TAG)).await.expect("the session restarts");
    rig.wait_for("result:later").await;

    assert_eq!(
        terse(rig.wire()),
        ["user:turn1", "result:turn1", "user:BIG", "result:BIG", "user:later", "result:later"],
        "neither lost nor duplicated by the restart"
    );
    let events = rig.labels();
    let second_start = events.iter().enumerate().filter(|(_, l)| *l == "start").nth(1).map(|(i, _)| i).expect("a second process started");
    let first_big = events.iter().position(|l| l.starts_with("user:BIG")).unwrap();
    assert!(first_big > second_start, "the big message went to the new process, the old one never took it whole");
}

// ── (4) a client attaching is replayed every tag's model state, read once ─────

// [seam: SessionManager::model_state_replay]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_replay_a_subscriber_gets_is_exactly_the_state_of_every_tag_the_daemon_knows() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.seed("recorded-only", "opus", Some("high"));
    rig.seed("locked", "haiku", None);
    rig.mgr.restrict_tag("locked", picks_restrictions());
    rig.register(&["registered-only", TAG]);
    rig.spawn(TAG, "");
    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;

    let tags = rig.mgr.model_state_tags();
    let replay = rig.mgr.model_state_replay();

    let expected: Vec<SessionModelState> = tags.iter().map(|t| rig.mgr.session_model_state(t)).collect();
    assert_eq!(replay, expected, "same frames, same order");
    for tag in [TAG, "recorded-only", "registered-only"] {
        assert!(replay.iter().any(|s| s.tag == tag), "{tag} is replayed: {:?}", replay.iter().map(|s| &s.tag).collect::<Vec<_>>());
    }
    assert!(!replay.iter().any(|s| s.tag == "locked"), "a restricted focus has no model state to show");
    assert!(replay.iter().find(|s| s.tag == TAG).unwrap().running);
}

// ── (4) a switch on a focus that is not running is noted where its stored conversation stands ─

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_on_a_stopped_session_is_noted_after_the_prompts_of_its_stored_conversation_before_the_ticket_resolves() {
    let mut rig = Rig::new().await;
    let home = private_home(&mut rig);
    store_session(&home, "sid-two-prompts", &stored_session());
    rig.seed(TAG, "sonnet", None);
    rig.mgr
        .spawn_session(TAG.into(), "".into(), format!("view-{TAG}"), Some(rig.cwd.clone()), Some("sid-two-prompts".into()), false)
        .expect("resumes");
    rig.wait_for_runs(1).await;
    rig.mgr.stop(TAG);

    let outcome = settle(rig.request(TAG, to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    let ledger = rig.ledger("sid-two-prompts");
    assert_eq!(ledger.len(), 1, "the note is in the ledger by the time the caller is told: {ledger:?}");
    assert_eq!(ledger[0].kind, NoteKind::ModelChanged);
    assert_eq!(ledger[0].text, "Model set to Opus; takes effect when the session starts.");
    assert_eq!(ledger[0].after_prompt, 2, "after the two prompts the stored conversation holds");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_daemon_that_just_restarted_notes_a_switch_on_a_focus_it_has_no_session_for_after_its_stored_prompts() {
    let mut rig = Rig::new().await;
    let home = private_home(&mut rig);
    store_session(&home, "sid-two-prompts", &stored_session());
    rig.seed(TAG, "sonnet", None);
    std::fs::write(&rig.store_path, serde_json::to_vec(&json!({ TAG: "sid-two-prompts" })).unwrap()).unwrap();
    let mut restarted = SessionManager::with_store_path(rig.store_path.clone());
    restarted.set_model_catalog(fixture_catalog());

    let outcome = settle(restarted.request_switch(TAG, to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    let ledger = rig.ledger("sid-two-prompts");
    assert_eq!(ledger.len(), 1, "{ledger:?}");
    assert_eq!(ledger[0].after_prompt, 2);
    assert_eq!(rig.record(TAG).unwrap().model, "opus");
}

// ── (5) robustness: the queue and the switches behind a failed apply ──────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_asked_for_while_another_is_applied_survives_the_session_dying_and_lands_on_its_replacement() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_SET_MODEL", Some("exit".into()));
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    let _window = rig.observe(TAG, "window-1");
    rig.hold("set_model");

    let first = rig.request(TAG, to_model("opus"));
    rig.wait_for("set_model:opus").await;
    // The running process keeps the environment it started with (it will die on set_model); the one
    // that replaces it starts with this one.
    rig.env("FAKE_SET_MODEL", None);
    let second = rig.request(TAG, to_model("fable"));
    assert_eq!(second.immediate().expect("answered at once").status, ModelRequestStatus::PendingTurnEnd);
    rig.release("set_model"); // the first process dies now
    let first = settle(first).await;
    assert_eq!(first.status, ModelRequestStatus::Failed, "the switch that was in flight died with its process");

    rig.recover(2).await;
    eventually("the second switch to be applied on the new process", || {
        (rig.record(TAG).map(|r| r.model) == Some("fable".to_owned())).then_some(())
    })
    .await;

    let failed: Vec<String> = rig.ledger_of_kind(&sid, NoteKind::ModelFailed).into_iter().map(|n| n.text).collect();
    assert_eq!(failed.len(), 1, "only the switch that really failed is reported as failed: {failed:?}");
    assert!(failed[0].starts_with("Couldn't switch to Opus"), "{failed:?}");
    assert!(!failed.iter().any(|t| t.contains("Fable")), "the second switch did not fail: {failed:?}");
    let changed: Vec<String> = rig.ledger_of_kind(&sid, NoteKind::ModelChanged).into_iter().map(|n| n.text).collect();
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert!(changed[0].starts_with("Model changed to Fable"), "{changed:?}");
    let runs = rig.runs();
    assert!(runs[1].iter().any(|a| a == "--resume"), "{:?}", runs[1]);
    eventually("the new process to be asked", || rig.wire().iter().any(|l| l == "set_model:fable").then_some(())).await;
    eventually("the switch to settle", || (rig.state(TAG).phase == SwitchPhase::Steady).then_some(())).await;
    assert_eq!(rig.state(TAG).recorded.unwrap().model, "fable");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_asked_for_while_another_is_applied_and_no_turn_is_running_does_not_claim_to_wait_for_a_turn() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn(TAG, "");
    let mut window = rig.observe(TAG, "window-1");
    rig.hold("set_model");

    let first = rig.request(TAG, to_model("opus"));
    rig.wait_for("set_model:opus").await;
    let second = rig.request(TAG, to_model("fable"));

    assert_eq!(second.immediate().expect("answered at once").status, ModelRequestStatus::PendingTurnEnd);
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelPending).is_empty(), "\"after this turn\" is not true: no turn is running");
    assert!(window.notes().iter().all(|(k, _)| *k != NoteKind::ModelPending), "{:?}", window.notes());
    rig.release("set_model");
    assert_eq!(settle(first).await.status, ModelRequestStatus::Applied);
    // The record is written before the note, so wait for the note (the last thing the switch does).
    eventually("the waiting switch to be applied and noted", || {
        (rig.record(TAG).map(|r| r.model) == Some("fable".to_owned())
            && rig.ledger_of_kind(&sid, NoteKind::ModelChanged).len() == 2)
            .then_some(())
    })
    .await;

    assert_eq!(rig.wire(), ["set_model:opus", "get_settings", "set_model:fable", "get_settings"]);
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelPending).is_empty());
    assert!(notes_of(&rig.snapshot(TAG), NoteKind::ModelPending).is_empty());
    assert_eq!(rig.ledger_of_kind(&sid, NoteKind::ModelChanged).len(), 2);
}

// ── (8) a switch needs a focus ────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_for_a_tag_nobody_has_heard_of_is_refused_and_leaves_no_record_behind() {
    let mut rig = Rig::new().await;
    rig.spawn("someone-else", "");
    // `unknown_focus` is only said once the daemon can vouch for its registry; before that the refusal
    // is `registry_not_ready` (see the tests below).
    rig.register(&["someone-else"]);
    assert!(rig.mgr.registry_known(), "precondition");

    for tag in ["no-such-focus", "no-such-either"] {
        let outcome = settle(rig.request(tag, to_model("opus"))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Refused, "{tag}: {outcome:?}");
        assert_eq!(outcome.code.as_deref(), Some("unknown_focus"), "{tag}");
        assert!(rig.record(tag).is_none(), "{tag}: no phantom record");
    }
    assert!(!rig.paths.focus_models.exists(), "nothing was written to the store at all");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_for_a_registered_a_recorded_or_a_remembered_focus_is_still_stored_for_its_next_start() {
    let mut rig = Rig::new().await;
    rig.register(&["registered-only"]);
    rig.seed("recorded-only", "sonnet", None);
    std::fs::write(&rig.store_path, serde_json::to_vec(&json!({ "remembered-only": "sid-remembered" })).unwrap()).unwrap();

    for tag in ["registered-only", "recorded-only", "remembered-only"] {
        let outcome = settle(rig.request(tag, to_model("opus"))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Applied, "{tag}: {outcome:?}");
        assert_eq!(rig.record(tag).map(|r| r.model), Some("opus".to_owned()), "{tag}");
    }
}

// ── (8) the catalogue probe is throttled ──────────────────────────────────────

fn fresh_hub(rig: &Rig) -> Arc<ModelHub> {
    Arc::new(ModelHub::new(ModelPaths::beside(&rig._root.path().join("hub").join("sessions.json"))))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refresh_soon_after_a_probe_does_not_probe_again_nor_touch_the_catalogue() {
    let rig = Rig::new().await;
    let hub = fresh_hub(&rig);

    let first = refresh_catalog(&hub).await;
    let installed = hub.catalog();
    let second = refresh_catalog(&hub).await;

    assert!(first.is_ok(), "{first:?}");
    assert!(second.is_err(), "a probe so soon after the last is refused");
    assert_eq!(rig.runs().len(), 1, "one probe process, not two");
    assert_eq!(hub.catalog(), installed, "the catalogue is exactly what the first probe installed");
    assert!(!hub.catalog().stale, "declining to probe is not a failed probe");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_refreshes_at_once_start_exactly_one_probe() {
    let rig = Rig::new().await;
    let hub = fresh_hub(&rig);

    let (a, b) = tokio::join!(
        tokio::spawn({
            let hub = Arc::clone(&hub);
            async move { refresh_catalog(&hub).await.is_ok() }
        }),
        tokio::spawn({
            let hub = Arc::clone(&hub);
            async move { refresh_catalog(&hub).await.is_ok() }
        })
    );

    let succeeded = [a.unwrap(), b.unwrap()].into_iter().filter(|ok| *ok).count();
    assert!(succeeded >= 1, "the probe that ran succeeded");
    assert_eq!(rig.runs().len(), 1, "one probe process");
    assert!(!hub.catalog().stale);
}

// [seam: ModelHub::set_min_probe_interval]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refresh_while_a_probe_is_in_flight_does_not_start_a_second_one() {
    let rig = Rig::new().await;
    let hub = fresh_hub(&rig);
    hub.set_min_probe_interval(Duration::ZERO); // only the in-flight probe can stop the second
    rig.hold("initialize");
    let probing = tokio::spawn({
        let hub = Arc::clone(&hub);
        async move { refresh_catalog(&hub).await }
    });
    rig.wait_for_runs(1).await; // the first probe's process is up and holding its answer

    let second = refresh_catalog(&hub);
    tokio::pin!(second);
    let started = Instant::now();
    let second = loop {
        tokio::select! {
            r = &mut second => break r,
            _ = tokio::time::sleep(Duration::from_millis(25)) => {
                assert!(rig.runs().len() < 2, "a second probe process was started while the first was in flight");
                assert!(started.elapsed() < WAIT, "the second refresh waited for the first instead of declining");
            }
        }
    };
    rig.release("initialize");
    let first = tokio::time::timeout(WAIT, probing).await.expect("the first probe finishes").unwrap();

    assert!(first.is_ok(), "{first:?}");
    assert_eq!(rig.runs().len(), 1);
    drop(second); // declined (an error) or not, it did not probe
    assert!(!hub.catalog().stale);
}

// [seam: ModelHub::set_min_probe_interval]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_minimum_interval_every_refresh_probes() {
    let rig = Rig::new().await;
    let hub = fresh_hub(&rig);
    hub.set_min_probe_interval(Duration::ZERO);

    refresh_catalog(&hub).await.expect("first");
    refresh_catalog(&hub).await.expect("second");

    assert_eq!(rig.runs().len(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_catalogue_loaded_from_disk_is_stale_until_a_probe_succeeds() {
    let rig = Rig::new().await;
    let paths = ModelPaths::beside(&rig._root.path().join("hub").join("sessions.json"));
    fixture_catalog().save(&paths.catalog).unwrap(); // what an earlier daemon cached
    let hub = ModelHub::new(paths);

    assert_eq!(family_names(&hub.catalog()), ["haiku", "sonnet", "opus", "fable"], "the cache is served at once");
    assert!(hub.catalog().stale, "but it is only what an earlier daemon saw");
    assert!(matches!(hub.catalog_msg(), ServerMsg::ModelCatalog { stale: true, .. }), "clients are told so");

    refresh_catalog(&hub).await.expect("the probe succeeds");

    assert!(!hub.catalog().stale);
    assert!(matches!(hub.catalog_msg(), ServerMsg::ModelCatalog { stale: false, .. }));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_catalogue_installed_fresh_is_not_stale_and_an_empty_cache_is_not_flagged() {
    let rig = Rig::new().await;
    let hub = fresh_hub(&rig);
    assert!(hub.catalog().is_empty());

    hub.set_catalog(fixture_catalog());

    assert!(!hub.catalog().stale);
    assert!(matches!(hub.catalog_msg(), ServerMsg::ModelCatalog { stale: false, .. }));
}

// ── (8) housekeeping: what a long-gone focus left behind ──────────────────────

fn days_before(now: chrono::DateTime<Utc>, days: i64) -> chrono::DateTime<Utc> {
    now - chrono::Duration::days(days)
}

/// Write the focus-models store directly, each record stamped as given (`None`: no stamp at all).
fn write_records(rig: &Rig, records: &[(&str, Option<chrono::DateTime<Utc>>)]) {
    let mut all = serde_json::Map::new();
    for (tag, updated_at) in records {
        let mut record = json!({"model": "opus", "source": "focus"});
        if let Some(at) = updated_at {
            record["updated_at"] = json!(at.to_rfc3339());
        }
        all.insert((*tag).to_owned(), record);
    }
    std::fs::write(&rig.paths.focus_models, serde_json::to_vec_pretty(&Value::Object(all)).unwrap()).unwrap();
}

fn record_tags(rig: &Rig) -> Vec<String> {
    store::load_focus_models(&rig.paths.focus_models).into_keys().collect()
}

/// When the record was last stamped, read from the file itself.
fn stamp_of(rig: &Rig, tag: &str) -> Option<chrono::DateTime<Utc>> {
    let all: Value = serde_json::from_slice(&std::fs::read(&rig.paths.focus_models).unwrap()).unwrap();
    all[tag]["updated_at"].as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()).map(|t| t.with_timezone(&Utc))
}

/// A ledger file for `sid` last touched at `modified`.
fn write_ledger(rig: &Rig, sid: &str, modified: chrono::DateTime<Utc>) -> PathBuf {
    notes::append(
        &rig.paths.notes_dir,
        sid,
        &LedgerNote { after_prompt: 0, kind: NoteKind::ModelChanged, text: format!("a note of {sid}"), ts: Utc::now() },
    )
    .unwrap();
    let path = notes::ledger_path(&rig.paths.notes_dir, sid);
    std::fs::OpenOptions::new().write(true).open(&path).unwrap().set_modified(modified.into()).unwrap();
    path
}

/// Remember (in the daemon's id store) that `tag` runs claude session `sid`.
fn remember_session(rig: &Rig, tag: &str, sid: &str) {
    let mut ids: std::collections::BTreeMap<String, String> =
        std::fs::read(&rig.store_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    ids.insert(tag.to_owned(), sid.to_owned());
    std::fs::write(&rig.store_path, serde_json::to_vec(&ids).unwrap()).unwrap();
}

fn a_request(rig: &Rig, tag: &str, request_id: &str) {
    let hub = rig.mgr.model_hub();
    hub.begin_request(tag, Some(request_id.to_owned()));
    hub.record_request(tag, &Actor::User, &ModelTarget { model: "opus".into(), effort: None }, ModelRequestStatus::Applied);
}

// [seam: SessionManager::sweep_model_state]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_does_nothing_at_all_until_the_daemon_can_vouch_for_the_registry() {
    let mut rig = Rig::new().await;
    let now = Utc::now();
    rig.mgr.set_focus_registry(vec![focus_meta("registered")]); // one push is not enough
    assert!(!rig.mgr.registry_known(), "precondition");
    write_records(&rig, &[("long-gone", Some(days_before(now, 400))), ("undated", None)]);
    let ledger = write_ledger(&rig, "sid-long-gone", days_before(now, 400));
    a_request(&rig, "long-gone", "r1");
    let records_before = std::fs::read(&rig.paths.focus_models).unwrap();

    let sweep: nostromo::ipc::session_manager::ModelSweep = rig.mgr.sweep_model_state(now + chrono::Duration::days(1000));

    assert_eq!((sweep.records_removed, sweep.ledgers_removed, sweep.request_state_removed), (0, 0, 0));
    assert_eq!(std::fs::read(&rig.paths.focus_models).unwrap(), records_before, "not even an undated record is stamped");
    assert!(ledger.exists());
    assert!(rig.mgr.model_hub().last_request("long-gone").is_some());
}

// [seam: SessionManager::sweep_model_state]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_removes_only_the_records_of_gone_focuses_that_nobody_touched_for_thirty_days() {
    let mut rig = Rig::new().await;
    rig.spawn("live-focus", "");
    rig.register(&["registered-focus"]);
    let now = Utc::now();
    write_records(
        &rig,
        &[
            ("gone-old", Some(days_before(now, 40))),
            ("gone-young", Some(days_before(now, 5))),
            ("gone-undated", None),
            ("registered-focus", Some(days_before(now, 400))),
            ("live-focus", Some(days_before(now, 400))),
        ],
    );

    let first = rig.mgr.sweep_model_state(now);

    assert_eq!(first.records_removed, 1);
    assert_eq!(record_tags(&rig), ["gone-undated", "gone-young", "live-focus", "registered-focus"]);
    let stamped = stamp_of(&rig, "gone-undated").expect("a record with no stamp is stamped, and kept, so that it ages");
    assert!((stamped - now).num_seconds().abs() < 60, "stamped with now: {stamped}");

    // Time passes: the stamped record and the young one are now old; registered and live ones never are.
    let later = rig.mgr.sweep_model_state(now + chrono::Duration::days(40));

    assert_eq!(later.records_removed, 2);
    assert_eq!(record_tags(&rig), ["live-focus", "registered-focus"]);
}

// [seam: SessionManager::sweep_model_state]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_removes_stale_ledgers_nothing_live_or_registered_points_at() {
    let mut rig = Rig::new().await;
    let live_sid = rig.spawn("live-focus", "");
    rig.register(&["registered-focus"]);
    let now = Utc::now();
    let old = days_before(now, 40);
    remember_session(&rig, "registered-focus", "sid-registered");
    remember_session(&rig, "recorded-focus", "sid-recorded-only");
    rig.seed("recorded-focus", "opus", None);
    // Changed: `recorded-focus` is remembered in the daemon's id store, so it exists daemon-side whether
    // or not the Mac ever registered it, and its ledger is kept (it used to be swept).
    let removed = [write_ledger(&rig, "sid-orphan", old)];
    let kept = [
        write_ledger(&rig, "sid-recorded-only", old),
        write_ledger(&rig, "sid-registered", old),
        write_ledger(&rig, &live_sid, old),
        write_ledger(&rig, "sid-young-orphan", days_before(now, 3)),
    ];
    let stray = rig.paths.notes_dir.join("README.txt");
    std::fs::write(&stray, "not a ledger").unwrap();
    std::fs::OpenOptions::new().write(true).open(&stray).unwrap().set_modified(old.into()).unwrap();

    let sweep = rig.mgr.sweep_model_state(now);

    assert_eq!(sweep.ledgers_removed, 1);
    for path in &removed {
        assert!(!path.exists(), "{} should be gone", path.display());
    }
    for path in kept.iter().chain([&stray]) {
        assert!(path.exists(), "{} should be kept", path.display());
    }
}

// [seam: SessionManager::sweep_model_state]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_forgets_the_requests_of_gone_focuses_after_thirty_days_and_never_those_of_live_ones() {
    let mut rig = Rig::new().await;
    rig.spawn("live-focus", "");
    rig.register(&["registered-focus"]);
    a_request(&rig, "gone-focus", "rid-gone");
    a_request(&rig, "live-focus", "rid-live");
    let now = Utc::now();
    let hub = rig.mgr.model_hub();

    let soon = rig.mgr.sweep_model_state(now);
    assert_eq!(soon.request_state_removed, 0, "a request made just now is not old");
    assert!(hub.last_request("gone-focus").is_some());

    let later = rig.mgr.sweep_model_state(now + chrono::Duration::days(40));

    assert!(later.request_state_removed >= 1);
    assert!(hub.last_request("gone-focus").is_none(), "its last request is forgotten");
    assert!(hub.last_request("live-focus").is_some(), "a live session's is kept whatever its age");
    // The request id went with it: a new request for the tag no longer carries the old one.
    let to = ModelTarget { model: "haiku".into(), effort: None };
    hub.record_request("gone-focus", &Actor::User, &to, ModelRequestStatus::Applied);
    hub.record_request("live-focus", &Actor::User, &to, ModelRequestStatus::Applied);
    assert_eq!(hub.last_request("gone-focus").unwrap().request_id, None);
    assert_eq!(hub.last_request("live-focus").unwrap().request_id.as_deref(), Some("rid-live"));
}

// ── (9) chosen vs observed ────────────────────────────────────────────────────
//
// A record the user (or an agent default) CHOSE is passed to the CLI at every start. A record the
// daemon merely OBSERVED (the model a session reported, or the model an agent's own front matter
// declares) is not: the agent's front matter, or the CLI's default, keeps deciding, and the record
// follows what actually runs.

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_a_chosen_record_is_passed_to_the_cli_at_a_start() {
    let mut rig = Rig::new().await;
    rig.seed_sourced("t-focus", "opus", Some("high"), ModelSource::Focus);
    rig.seed_sourced("t-default", "haiku", Some("low"), ModelSource::AgentDefault);
    rig.seed_sourced("t-declared", "fable", Some("max"), ModelSource::AgentDeclared);
    rig.seed_sourced("t-cli", "sonnet", Some("medium"), ModelSource::CliDefault);
    for tag in ["t-focus", "t-default", "t-declared", "t-cli"] {
        rig.spawn(tag, "");
    }

    let runs = rig.wait_for_runs(4).await;

    let mut passed: Vec<(Option<&str>, Option<&str>)> = runs.iter().map(|r| (arg_of(r, "--model"), arg_of(r, "--effort"))).collect();
    passed.sort();
    assert_eq!(
        passed,
        [(None, None), (None, None), (Some("haiku"), Some("low")), (Some("opus"), Some("high"))],
        "--model and --effort for the two chosen records only: {runs:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_focus_that_reported_its_model_is_respawned_without_a_model_flag_so_the_agent_or_the_cli_still_decides() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_INITIAL_MODEL", Some("claude-haiku-5-5".into()));
    rig.declare_agent("declarer", "haiku");
    rig.spawn(TAG, "declarer");
    rig.spawn("plain", "plain-agent");
    for tag in [TAG, "plain"] {
        rig.send(tag, &format!("hello-{tag}"));
        rig.wait_for(&format!("result:hello-{tag}")).await;
    }
    let declared = eventually("the declarer's record", || rig.record(TAG)).await;
    let observed = eventually("the plain agent's record", || rig.record("plain")).await;
    assert_eq!((declared.model.as_str(), declared.source), ("haiku", ModelSource::AgentDeclared));
    assert_eq!((observed.model.as_str(), observed.source), ("haiku", ModelSource::CliDefault));

    rig.mgr.restart(TAG).unwrap();
    rig.wait_for_runs(3).await;
    rig.mgr.restart("plain").unwrap();
    let runs = rig.wait_for_runs(4).await;

    for run in &runs[2..] {
        assert!(!run.iter().any(|a| a == "--model" || a == "--effort"), "an observed record is not an instruction: {run:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_observed_record_follows_what_the_respawned_session_reports_without_a_note() {
    let mut rig = Rig::new().await;
    rig.env("FAKE_INITIAL_MODEL", Some("claude-haiku-5-5".into()));
    rig.declare_agent("declarer", "haiku");
    let sid = rig.spawn(TAG, "declarer");
    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;
    eventually("the migrated record", || rig.record(TAG)).await;
    rig.state_broadcasts(); // what happened so far is not what this test is about
    // The agent's front matter (or the CLI's default) changed while the session was down.
    rig.env("FAKE_INITIAL_MODEL", Some("claude-sonnet-5-5".into()));

    rig.mgr.restart(TAG).unwrap();
    rig.wait_for_runs(2).await;
    rig.send(TAG, "again");
    rig.wait_for("result:again").await;

    let record = eventually("the record to follow", || rig.record(TAG).filter(|r| r.model == "sonnet")).await;
    assert!(
        matches!(record.source, ModelSource::AgentDeclared | ModelSource::CliDefault),
        "it is still an observation, not a choice: {:?}",
        record.source
    );
    assert!(rig.ledger(&sid).is_empty(), "no mismatch note, no note at all: {:?}", rig.ledger(&sid));
    let state = rig.state(TAG);
    assert_eq!(state.recorded.as_ref().map(|r| r.model.as_str()), Some("sonnet"));
    assert_eq!(state.reported.as_ref().map(|r| r.model.as_str()), Some("claude-sonnet-5-5"));
    let mut seen = Vec::new();
    eventually("a state frame for the followed model", || {
        seen.extend(rig.state_broadcasts());
        seen.iter()
            .any(|s| s.tag == TAG && s.recorded.as_ref().map(|r| r.model.as_str()) == Some("sonnet"))
            .then_some(())
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_user_switch_turns_an_observed_record_into_a_choice_so_later_starts_pass_the_model() {
    let mut rig = Rig::new().await;
    rig.spawn(TAG, "plain-agent");
    rig.send(TAG, "hello");
    rig.wait_for("result:hello").await;
    let observed = eventually("the migrated record", || rig.record(TAG)).await;
    assert_eq!(observed.source, ModelSource::CliDefault);
    // The fake logs the result before it writes it: wait until the daemon has
    // seen the turn end, or the switch would (rightly) wait for it.
    eventually("the session to be idle", || {
        rig.mgr
            .list()
            .iter()
            .any(|s| s.tag == TAG && s.state == nostromo::ipc::stream_json::SessionState::Idle)
            .then_some(())
    })
    .await;

    let outcome = settle(rig.request(TAG, to_model("opus"))).await;
    rig.mgr.restart(TAG).unwrap();
    let runs = rig.wait_for_runs(2).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied);
    assert_eq!(rig.record(TAG).unwrap().source, ModelSource::Focus);
    assert!(!runs[0].iter().any(|a| a == "--model"), "{:?}", runs[0]);
    assert_eq!(arg_of(&runs[1], "--model"), Some("opus"), "{:?}", runs[1]);
}

// ── a phantom prompt must not be taken for the end of a turn ──────────────────
//
// The CLI replays some of its own commands as a user entry whose wording the daemon may not know. The
// transcript opens a turn for it and drops it when the next prompt arrives. Dropping it is not a turn
// ending: the reader must not carry on as after a turn (write the next queued message, start a waiting
// switch) while the prompt that just arrived is the turn that is running.

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_phantom_prompt_dropped_when_the_real_one_arrives_does_not_start_the_next_queued_message_mid_turn() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn(TAG, "");
    let mut window = rig.observe(TAG, "window-1");
    std::fs::write(rig.fake.join("phantom.before.first"), "").unwrap();
    rig.hold("first");
    rig.send(TAG, "first");
    rig.wait_for("phantom").await; // the phantom is open in the transcript; `first` is yet to be echoed
    rig.send(TAG, "second"); // queued: a turn is running
    rig.release("phantom");

    // The reader has handled everything up to the reply to `first`, so whatever it was going to do when
    // the phantom was dropped it has done by now.
    eventually("the reply to the real prompt", || window.saw_text("reply to first").then_some(())).await;
    assert!(window.saw_a_turn_errored(), "precondition: the phantom was dropped when `first` arrived");
    // A stop writes to the child's stdin after anything the reader wrote, and drops what is still queued:
    // once the child has logged it, it has logged everything written before it.
    rig.mgr.interrupt(TAG).expect("the session is alive");
    eventually("the child to log the stop (or the message that was written instead)", || {
        let wire = rig.wire();
        wire.iter().any(|l| l == "interrupt" || l == "user:second").then_some(())
    })
    .await;

    assert_eq!(
        rig.wire(),
        ["user:first", "interrupt"],
        "`second` waits for the turn of `first` to end; it was written into the running turn"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_phantom_prompt_dropped_when_the_real_one_arrives_does_not_start_a_waiting_switch_mid_turn() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn(TAG, "");
    let mut window = rig.observe(TAG, "window-1");
    std::fs::write(rig.fake.join("phantom.before.first"), "").unwrap();
    rig.hold("first");
    rig.hold("set_model"); // a switch started by mistake stays "Applying" and is plain to see
    rig.send(TAG, "first");
    rig.wait_for("phantom").await;
    let ticket = rig.request(TAG, to_model("opus"));
    assert_eq!(ticket.immediate().expect("answered at once").status, ModelRequestStatus::PendingTurnEnd);
    rig.release("phantom");

    eventually("the reply to the real prompt", || window.saw_text("reply to first").then_some(())).await;
    assert!(window.saw_a_turn_errored(), "precondition: the phantom was dropped when `first` arrived");

    assert_eq!(rig.state(TAG).phase, SwitchPhase::Waiting, "the turn of `first` is still running: the switch keeps waiting for it");
    // And it is applied once that turn ends, not lost.
    // (A switch that waited was answered `PendingTurnEnd` at once; its ticket says no more.)
    rig.release("first");
    rig.release("set_model");
    eventually("the waiting switch to be applied", || (rig.record(TAG).map(|r| r.model) == Some("opus".to_owned())).then_some(())).await;
    assert_eq!(rig.wire(), ["user:first", "result:first", "set_model:opus", "get_settings"]);
}

// ── a poisoned lock does not stop a model report ──────────────────────────────
// (see the in-crate tests in `session_manager`: the locks are not reachable from out here)

// ── a full name is no longer accepted blindly ─────────────────────────────────
//
// A fresh catalogue is the installed CLI's own list. A full `claude-…` name is offered only if a row
// lists it or a row currently resolves to it; a retired pinned ID or a typo is not, for a switch, for
// a per-agent default and for a start.

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_fresh_catalogue_a_retired_full_name_a_typo_or_a_foreign_model_is_refused_naming_what_is_offered() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn(TAG, "");
    rig.wait_for_runs(1).await;

    for bad in ["claude-opus-4-1", "claude-opus-9", "claude-haiku-3-0", "gemini"] {
        let outcome = settle(rig.request(TAG, to_model(bad))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Refused, "{bad}: {outcome:?}");
        assert_eq!(outcome.code.as_deref(), Some("unknown_model"), "{bad}");
        let message = outcome.message.unwrap_or_default();
        assert!(message.contains("not offered by the installed CLI"), "{bad}: {message}");
        let (_, offered) = message.split_once("choose one of").unwrap_or_else(|| panic!("{bad}: no list of choices in {message:?}"));
        for name in ["haiku", "sonnet", "opus", "fable"] {
            assert!(offered.contains(name), "{bad}: {name} is offered and the message should say so: {message}");
        }
    }
    assert!(rig.wire().is_empty(), "nothing was sent to the session: {:?}", rig.wire());
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet", "and nothing was recorded");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_fresh_catalogue_a_per_agent_default_is_judged_like_a_switch_target() {
    let mut rig = Rig::new().await;

    let retired = rig.mgr.set_agent_default("declarer", Some("claude-opus-9".into()), None, false);
    let current = rig.mgr.set_agent_default("declarer", Some("claude-opus-5-5".into()), None, false);

    assert_eq!((retired.status, retired.code.as_deref()), (ModelRequestStatus::Refused, Some("unknown_model")), "{retired:?}");
    assert_eq!(current.status, ModelRequestStatus::Applied, "{current:?}");
    assert_eq!(store::load_defaults(&rig.paths.defaults)["declarer"].model, "claude-opus-5-5");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_fresh_catalogue_the_full_name_a_family_resolves_to_or_a_pinned_row_is_still_accepted() {
    let mut rig = Rig::new().await;
    rig.spawn_and_stop(TAG).await;

    // opus resolves to claude-opus-5-5 and sonnet to claude-sonnet-5-5; the others are rows of their own.
    for good in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-4-6", "claude-haiku-4-5-20251001"] {
        let outcome = settle(rig.request(TAG, to_model(good))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Applied, "{good}: {outcome:?}");
        assert_eq!(rig.record(TAG).map(|r| r.model), Some(good.to_owned()), "{good}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_a_stale_catalogue_a_full_name_passes_but_an_alias_must_still_be_listed() {
    let mut rig = Rig::new().await;
    rig.mgr.set_model_catalog(stale_catalog());
    rig.spawn_and_stop(TAG).await;

    let full = settle(rig.request(TAG, to_model("claude-opus-9"))).await;
    assert_eq!(full.status, ModelRequestStatus::Applied, "a stale catalogue can't say a newer full name is wrong: {full:?}");
    assert_eq!(rig.record(TAG).unwrap().model, "claude-opus-9");

    for bad in ["gemini", "opuss"] {
        let outcome = settle(rig.request(TAG, to_model(bad))).await;
        assert_eq!((outcome.status, outcome.code.as_deref()), (ModelRequestStatus::Refused, Some("unknown_model")), "{bad}");
    }
    assert_eq!(rig.record(TAG).unwrap().model, "claude-opus-9", "the refusals changed nothing");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_full_name_the_fresh_catalogue_no_longer_offers_is_not_passed_and_the_focus_falls_back_to_the_agents_model() {
    let mut rig = Rig::new().await;
    rig.declare_agent("declarer", "sonnet");

    let (argv, sid) = rig.start_on_stored(TAG, "declarer", "claude-haiku-3-0").await;

    assert!(!argv.iter().any(|a| a == "claude-haiku-3-0"), "a retired ID must not become a failing start: {argv:?}");
    assert_eq!(arg_of(&argv, "--model"), None, "{argv:?}");
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared));
    let unavailable = rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable);
    assert_eq!(unavailable.len(), 1, "{unavailable:?}");
    assert!(unavailable[0].text.ends_with("this focus now uses Sonnet."), "{}", unavailable[0].text);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn with_no_default_and_no_declared_model_a_retired_full_name_leaves_the_cli_default_and_a_note() {
    let mut rig = Rig::new().await;

    let (argv, sid) = rig.start_on_stored(TAG, "plain-agent", "claude-opus-9").await;

    assert!(!argv.iter().any(|a| a == "--model" || a == "claude-opus-9"), "{argv:?}");
    assert_eq!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stored_full_name_a_family_currently_resolves_to_is_passed_through_under_a_fresh_catalogue() {
    let mut rig = Rig::new().await;

    let (argv, sid) = rig.start_on_stored(TAG, "", "claude-opus-5-5").await;

    assert_eq!(arg_of(&argv, "--model"), Some("claude-opus-5-5"), "{argv:?}");
    assert!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).is_empty());
}

// ── a catalogue read from the cache is verified before a start relies on it ───
//
// A daemon that has just started serves the cached catalogue, which only says what an earlier run saw.
// Before the first start that would pass a chosen `--model`, the start probes the CLI (the fake's
// `initialize` answer, `$FAKE_CATALOG`) and judges the model against what it says.

/// The fixture catalogue without the `fable` family: the CLI as installed after it retired Fable.
fn catalog_without_fable(rig: &mut Rig) {
    let mut answer = fixture_json();
    answer["response"]["response"]["models"].as_array_mut().unwrap().retain(|m| m["value"] != "fable");
    let path = rig.fake.join("catalog-without-fable.json");
    std::fs::write(&path, serde_json::to_vec(&answer).unwrap()).unwrap();
    rig.env("FAKE_CATALOG", Some(path.into()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_first_start_after_a_restart_probes_the_cli_before_passing_a_stored_model_and_drops_a_retired_alias() {
    let mut rig = Rig::new().await;
    catalog_without_fable(&mut rig); // the cache (the fixture) still lists fable; the CLI no longer does
    rig.declare_agent("declarer", "sonnet");
    rig.seed(TAG, "fable", None);
    rig.restart_daemon();
    assert!(rig.mgr.model_catalog().stale, "precondition: the cache is served stale");
    assert!(rig.runs().is_empty(), "precondition: no process has been started yet");

    let sid = rig.spawn(TAG, "declarer");

    let runs = eventually("the session's start", || {
        let runs = rig.runs();
        runs.iter().any(|r| is_start_of_session(r)).then_some(runs)
    })
    .await;
    let runs = if runs.len() > 1 { rig.wait_for_all_starts_logged().await } else { runs };
    assert_eq!(runs.len(), 2, "the CLI was probed, then the session started: {runs:?}");
    assert!(!is_start_of_session(&runs[0]) && is_start_of_session(&runs[1]), "the probe came first: {runs:?}");
    assert_eq!(
        rig.labels().into_iter().take(4).collect::<Vec<_>>(),
        ["start", "initialize", "answer:initialize", "start"],
        "the probe asked and was answered before the session's own process started"
    );
    assert_eq!(arg_of(&runs[1], "--model"), None, "the retired alias is not passed: {:?}", runs[1]);
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("sonnet", ModelSource::AgentDeclared), "judged against the fresh catalogue");
    assert_eq!(rig.ledger_of_kind(&sid, NoteKind::ModelUnavailable).len(), 1);
    assert!(!rig.mgr.model_catalog().stale, "and the probe's answer is now the catalogue");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_start_after_a_restart_judges_a_retired_full_name_against_the_probe_too() {
    let mut rig = Rig::new().await;
    // The cache lists a pinned row the CLI no longer offers.
    let mut cached = fixture_json();
    cached["response"]["response"]["models"]
        .as_array_mut()
        .unwrap()
        .push(json!({"value": "claude-haiku-3-0", "resolvedModel": "claude-haiku-3-0", "displayName": "Haiku 3", "supportedEffortLevels": [], "supportsEffort": false}));
    ModelCatalog::from_initialize_response(&cached, Utc::now()).unwrap().save(&rig.paths.catalog).unwrap();
    rig.seed(TAG, "claude-haiku-3-0", None);
    rig.restart_daemon();
    assert!(rig.mgr.model_catalog().entry("claude-haiku-3-0").is_some(), "precondition: the cache offers it");

    rig.spawn(TAG, "");

    eventually("the session's start", || rig.runs().iter().any(|r| is_start_of_session(r)).then_some(())).await;
    let runs = rig.wait_for_all_starts_logged().await;
    let start = runs.iter().find(|r| is_start_of_session(r)).expect("the session started");
    assert!(!start.iter().any(|a| a == "claude-haiku-3-0"), "the retired full name is not passed: {start:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn when_the_first_probe_fails_the_start_passes_no_model_flag_and_leaves_the_record_alone() {
    let mut rig = Rig::new().await;
    let mut empty = fixture_json();
    empty["response"]["response"]["models"] = json!([]);
    let path = rig.fake.join("empty-catalog.json");
    std::fs::write(&path, serde_json::to_vec(&empty).unwrap()).unwrap();
    rig.env("FAKE_CATALOG", Some(path.into()));
    rig.declare_agent("declarer", "sonnet");
    rig.seed(TAG, "opus", Some("high"));
    let before = rig.record(TAG).unwrap();
    rig.restart_daemon();
    rig.mgr.model_hub().set_min_probe_interval(Duration::ZERO);

    rig.spawn(TAG, "declarer");

    eventually("the session's start", || (rig_starts(&rig) >= 1).then_some(())).await;
    let runs = rig.wait_for_all_starts_logged().await;
    let start = runs.iter().find(|r| is_start_of_session(r)).expect("the session started");
    assert_eq!(runs.len(), 2, "a probe was attempted before the start: {runs:?}");
    assert_eq!(arg_of(start, "--model"), None, "nobody vouches for the stored model, so none is passed: {start:?}");
    assert_eq!(rig.record(TAG), Some(before), "the record is untouched: no replacement is written");
    assert!(rig.mgr.model_catalog().stale, "the cache is all there is, and it says so");

    // A probe has been attempted this run: later starts take the catalogue as it is (stale = pass-through).
    rig.seed("second", "opus", None);
    rig.spawn("second", "");
    eventually("the second start", || (rig_starts(&rig) >= 2).then_some(())).await;
    let runs = rig.wait_for_all_starts_logged().await;
    assert_eq!(runs.len(), 3, "no second probe: {runs:?}");
    assert_eq!(arg_of(&runs[2], "--model"), Some("opus"), "{:?}", runs[2]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_the_first_start_after_a_restart_probes_and_only_a_start_that_would_pass_a_model_does() {
    let mut rig = Rig::new().await;
    rig.seed("chosen-a", "opus", None);
    rig.seed("chosen-b", "haiku", None);
    rig.restart_daemon();

    rig.spawn("plain", "plain-agent"); // nothing recorded: no model to pass, so nothing to verify
    let runs = eventually("the start", || {
        let runs = rig.runs();
        runs.iter().any(|r| is_start_of_session(r)).then_some(runs)
    })
    .await;
    assert_eq!(runs.len(), 1, "a start that passes no model does not probe the CLI: {runs:?}");

    rig.spawn("chosen-a", "");
    eventually("the start of chosen-a", || (rig_starts(&rig) >= 2).then_some(())).await;
    rig.spawn("chosen-b", "");
    eventually("the start of chosen-b", || (rig_starts(&rig) >= 3).then_some(())).await;
    let runs = rig.wait_for_all_starts_logged().await;

    assert_eq!(runs.len(), 4, "one probe, for the first start that passed a model: {runs:?}");
    let starts: Vec<&Vec<String>> = runs.iter().filter(|r| is_start_of_session(r)).collect();
    assert_eq!(starts.len(), 3, "{runs:?}");
    assert_eq!(arg_of(starts[1], "--model"), Some("opus"));
    assert_eq!(arg_of(starts[2], "--model"), Some("haiku"));
}

// ── the files the stores keep are swept of what an interrupted write left ─────

/// Make `path` look like it was last written five minutes ago: a leftover, not a write in flight.
fn age(path: &Path) {
    let then = std::time::SystemTime::now() - Duration::from_secs(300);
    std::fs::File::options().write(true).open(path).unwrap().set_modified(then).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_leftover_temp_file_of_an_interrupted_store_write_is_gone_once_the_daemon_has_started() {
    let rig = Rig::new().await;
    let paths = ModelPaths::beside(&rig._root.path().join("restarted").join("sessions.json"));
    let dir = paths.focus_models.parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("focus-models.tmp-abc"), b"{\"cody-1\": {\"mo").unwrap();
    age(&dir.join("focus-models.tmp-abc"));
    std::fs::write(&paths.focus_models, b"{}").unwrap();
    std::fs::write(dir.join("focus-models.corrupt-20260101T000000Z"), b"kept for recovery").unwrap();

    let _hub = ModelHub::new(paths);

    let mut left: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    left.sort();
    assert_eq!(left, ["focus-models.corrupt-20260101T000000Z", "focus-models.json"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_at_start_covers_the_directory_of_each_store_file() {
    let rig = Rig::new().await;
    let root = rig._root.path().join("three-dirs");
    let (a, b, c) = (root.join("a"), root.join("b"), root.join("c"));
    for d in [&a, &b, &c] {
        std::fs::create_dir_all(d).unwrap();
    }
    let paths = ModelPaths {
        focus_models: a.join("focus-models.json"),
        defaults: b.join("model-defaults.json"),
        notes_dir: root.join("notes"),
        catalog: c.join("model-catalog.json"),
    };
    let leftovers = [a.join("focus-models.tmp-1"), b.join("model-defaults.tmp-2"), c.join("model-catalog.tmp-3")];
    for path in &leftovers {
        std::fs::write(path, b"half").unwrap();
        age(path);
    }
    let bystander = c.join("unrelated.txt");
    std::fs::write(&bystander, b"mine").unwrap();

    let _hub = ModelHub::new(paths);

    for path in &leftovers {
        assert!(!path.exists(), "{} should have been swept", path.display());
    }
    assert!(bystander.exists());
}

// ── a switch of a focus that is not running is recorded off the manager's lock ─

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_of_a_focus_with_no_session_is_answered_after_it_is_recorded_not_while_the_manager_is_asked() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.state_broadcasts(); // whatever came before is not what this test is about

    let ticket = rig.request(TAG, to_model("opus"));

    assert!(ticket.immediate().is_none(), "the write is not made by the caller (the manager lock is held): the ticket resolves after it");
    let outcome = settle(ticket).await;
    assert_eq!(outcome.status, ModelRequestStatus::Applied, "{outcome:?}");
    let record = rig.record(TAG).unwrap();
    assert_eq!((record.model.as_str(), record.source), ("opus", ModelSource::Focus));
    let lines = rig.model_switch_lines();
    assert_eq!(lines.len(), 1, "one activity line: {lines:?}");
    assert_eq!((lines[0]["focus_tag"].as_str(), lines[0]["to"]["model"].as_str(), lines[0]["outcome"].as_str()), (Some(TAG), Some("opus"), Some("applied")));
    let told: Vec<SessionModelState> = rig.state_broadcasts().into_iter().filter(|s| s.tag == TAG).collect();
    assert_eq!(told.len(), 1, "clients are told once: {told:?}");
    assert_eq!(told[0].recorded.as_ref().map(|r| r.model.as_str()), Some("opus"));
    assert!(!told[0].running);
    assert_eq!(rig.state(TAG).last_request.map(|l| l.status), Some(ModelRequestStatus::Applied));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_of_a_stopped_session_is_recorded_and_noted_exactly_once_when_its_ticket_resolves() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn_and_stop(TAG).await;
    eventually("the session to be down", || (!rig.state(TAG).running).then_some(())).await;

    let ticket = rig.request(TAG, to_model("opus"));

    assert!(ticket.immediate().is_none(), "answered after the record is written, not before");
    assert_eq!(settle(ticket).await.status, ModelRequestStatus::Applied);
    assert_eq!(rig.record(TAG).unwrap().model, "opus");
    let ledger = rig.ledger(&sid);
    assert_eq!(ledger.len(), 1, "{ledger:?}");
    assert_eq!(ledger[0].text, "Model set to Opus; takes effect when the session starts.");
    assert_eq!(rig.model_switch_lines().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_switches_of_a_stopped_focus_made_back_to_back_are_recorded_in_the_order_they_were_asked_for() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    let sid = rig.spawn_and_stop(TAG).await;
    eventually("the session to be down", || (!rig.state(TAG).running).then_some(())).await;

    let a = rig.request(TAG, to_model("opus"));
    let b = rig.request(TAG, to_model("haiku"));
    let (a, b) = (settle(a).await, settle(b).await);

    assert_eq!((a.status, b.status), (ModelRequestStatus::Applied, ModelRequestStatus::Applied), "{a:?} {b:?}");
    assert_eq!(rig.record(TAG).unwrap().model, "haiku", "the later request wins");
    let texts: Vec<String> = rig.ledger(&sid).into_iter().map(|n| n.text).collect();
    assert_eq!(
        texts,
        ["Model set to Opus; takes effect when the session starts.", "Model set to Haiku; takes effect when the session starts."],
        "in request order"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn switching_a_stopped_focus_away_and_straight_back_ends_on_the_model_it_was_switched_back_to() {
    let mut rig = Rig::new().await;
    rig.seed(TAG, "sonnet", None);
    rig.spawn_and_stop(TAG).await;
    eventually("the session to be down", || (!rig.state(TAG).running).then_some(())).await;

    // The second request is, by the time it is made, a request to leave opus; the record on disk may
    // not say so yet.
    let away = rig.request(TAG, to_model("opus"));
    let back = rig.request(TAG, to_model("sonnet"));
    let (away, back) = (settle(away).await, settle(back).await);

    assert_eq!(away.status, ModelRequestStatus::Applied, "{away:?}");
    assert_ne!(back.status, ModelRequestStatus::Failed, "{back:?}");
    assert_eq!(rig.record(TAG).unwrap().model, "sonnet", "the last thing the user asked for is what is recorded");
}

// ── a switch right after a restart, before the Mac has said which focuses exist ─

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn before_the_registry_is_known_a_switch_for_an_unheard_of_tag_is_told_to_try_again_and_leaves_no_record() {
    let mut rig = Rig::new().await;

    for pushes in 0..2 {
        if pushes == 1 {
            rig.mgr.set_focus_registry(vec![focus_meta("registered")]); // one push is not enough to vouch for it
        }
        assert!(!rig.mgr.registry_known(), "precondition ({pushes} push(es))");

        let outcome = settle(rig.request("not-pushed-yet", to_model("opus"))).await;

        assert_eq!(outcome.status, ModelRequestStatus::Refused, "{pushes}: {outcome:?}");
        assert_eq!(outcome.code.as_deref(), Some("registry_not_ready"), "{pushes}: a real focus looks just like a typo right now");
        let message = outcome.message.unwrap_or_default().to_lowercase();
        assert!(message.contains("try again"), "{pushes}: {message}");
        assert!(rig.record("not-pushed-yet").is_none(), "{pushes}: nothing is recorded");
        assert!(!rig.paths.focus_models.exists(), "{pushes}: nothing was written to the store at all");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn once_the_registry_is_known_an_unheard_of_tag_is_an_unknown_focus_not_a_retry() {
    let mut rig = Rig::new().await;
    rig.register(&["registered"]);
    assert!(rig.mgr.registry_known(), "precondition");

    let outcome = settle(rig.request("not-pushed-ever", to_model("opus"))).await;

    assert_eq!((outcome.status, outcome.code.as_deref()), (ModelRequestStatus::Refused, Some("unknown_focus")), "{outcome:?}");
    assert!(rig.record("not-pushed-ever").is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn before_the_registry_is_known_a_focus_the_daemon_does_know_is_still_switched() {
    let mut rig = Rig::new().await;
    rig.seed("recorded-only", "sonnet", None);
    assert!(!rig.mgr.registry_known(), "precondition");

    let outcome = settle(rig.request("recorded-only", to_model("opus"))).await;

    assert_eq!(outcome.status, ModelRequestStatus::Applied, "{outcome:?}");
    assert_eq!(rig.record("recorded-only").unwrap().model, "opus");
}

// ── the sweep keeps what a focus the daemon still holds a session for needs ───

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sweep_keeps_the_record_and_request_of_a_focus_the_daemon_remembers_a_session_for_though_the_mac_never_registered_it() {
    let mut rig = Rig::new().await;
    rig.register(&["registered-focus"]);
    assert!(rig.mgr.registry_known(), "precondition");
    let now = Utc::now();
    write_records(&rig, &[("daemon-only", Some(days_before(now, 40))), ("truly-gone", Some(days_before(now, 40)))]);
    remember_session(&rig, "daemon-only", "sid-daemon-only");
    a_request(&rig, "daemon-only", "rid-daemon-only");
    a_request(&rig, "truly-gone", "rid-truly-gone");

    let sweep = rig.mgr.sweep_model_state(now + chrono::Duration::days(40));

    assert_eq!(record_tags(&rig), ["daemon-only"], "the control (no id-store entry) is removed, the remembered focus is kept");
    assert_eq!(sweep.records_removed, 1);
    let hub = rig.mgr.model_hub();
    assert!(hub.last_request("daemon-only").is_some(), "its request state is kept too");
    assert!(hub.last_request("truly-gone").is_none(), "the control's is forgotten");
}
