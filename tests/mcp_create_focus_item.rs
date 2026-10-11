//! `create_focus_core` and `nostromo.create_focus` (FND-4): item-keyed
//! duplicate protection, tag collisions, org/label metadata, the Mother-job
//! destination and its brief, and the guarantee that no credential leaks into
//! a seeded context or brief.
//!
//! Behavioural only. A fake `claude` stands in for the real agent (so
//! `spawn_session` really spawns) and a fake `mother` for the CLI. Everything
//! that touches process-global state (CLAUDE_BIN, MOTHER_BIN,
//! NOSTROMO_TERI_DIR, the process-wide sent ledger) runs under one lock.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use nostromo::data::work::model::SentMarker;
use nostromo::data::work::sent::{install_ledger, SentLedger};
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{FocusMeta, ServerMsg};
use nostromo::ipc::session_manager::CLAUDE_BIN_ENV;
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::create_focus::{
    create_focus, create_focus_core, CreateFocusError, CreateFocusOutcome, CreateFocusRequest,
    Destination, OutcomeKind, SourceItemRef,
};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

// ── fake claude (one per test process) ────────────────────────────────────────

const FAKE_CLAUDE_SCRIPT: &str = r#"#!/bin/sh
name=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-n" ]; then name="$2"; fi
  shift
done
log="@LOGDIR@/$name.stdin"
echo START >> "$log"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$log"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
done
"#;

static FAKE_CLAUDE_DIR: OnceLock<PathBuf> = OnceLock::new();

fn install_fake_claude() {
    FAKE_CLAUDE_DIR.get_or_init(|| {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nostromo-fake-claude-cfi-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(
            &script,
            FAKE_CLAUDE_SCRIPT.replace("@LOGDIR@", dir.to_str().expect("utf8 temp dir")),
        )
        .expect("write fake claude");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        dir
    });
}

/// What the fake claude named `view` (the focus title) has received, plus `START` lines.
fn fake_log(view: &str) -> String {
    let dir = FAKE_CLAUDE_DIR.get().expect("install_fake_claude ran");
    std::fs::read_to_string(dir.join(format!("{view}.stdin"))).unwrap_or_default()
}

fn fake_starts(view: &str) -> usize {
    fake_log(view).lines().filter(|l| *l == "START").count()
}

async fn wait_for_log(view: &str, what: &str, pred: impl Fn(&str) -> bool) -> String {
    for _ in 0..400 {
        let log = fake_log(view);
        if pred(&log) {
            return log;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("fake claude `{view}` never saw {what}; its log was {:?}", fake_log(view));
}

// ── fake mother ───────────────────────────────────────────────────────────────

/// Accepts the `add`/`list` grammar the daemon uses, logs every call, fails
/// when a `fail` marker file exists, and keeps `list.json` current.
const FAKE_MOTHER: &str = r#"#!/bin/sh
here="$(dirname "$0")"
printf '%s\n' "$*" >> "$here/argv.log"
sub="$1"
[ $# -gt 0 ] && shift
case "$sub" in
  add)
    seen=" "
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan-file|--repo|--branch|--repo-path|--base|--max-cost|--depends-on|--title|--format|--label)
          [ $# -ge 2 ] || { echo "add: flag needs an argument: $1" >&2; exit 2; }
          seen="$seen$1 "; shift ;;
        *) echo "add: unknown flag: $1" >&2; exit 2 ;;
      esac
      shift
    done
    for f in --plan-file --repo --branch; do
      case "$seen" in *" $f "*) ;; *) echo "add: $f is required" >&2; exit 2 ;; esac
    done
    if [ -e "$here/fail" ]; then echo "boom: bad plan" >&2; exit 1; fi
    echo "abc123"
    printf '[{"id":"abc123","state":"queued"}]' > "$here/list.json" ;;
  list)
    if [ -e "$here/list.json" ]; then cat "$here/list.json"; else echo "[]"; fi ;;
  *) echo "mother: unknown command: $sub" >&2; exit 2 ;;
esac
exit 0
"#;

// ── harness ───────────────────────────────────────────────────────────────────

/// Serializes every test: env vars and the ledger are process-global.
static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct Env {
    _guard: tokio::sync::MutexGuard<'static, ()>,
    dir: TempDir,
    saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    state: McpSharedState,
    session_mgr: Arc<Mutex<SessionManager>>,
    rx: broadcast::Receiver<ServerMsg>,
    ledger: Arc<SentLedger>,
}

impl Env {
    async fn new() -> Env {
        let guard = ENV_LOCK.lock().await;
        install_fake_claude();
        let dir = TempDir::new().unwrap();

        let mother_dir = dir.path().join("fake-mother");
        std::fs::create_dir_all(&mother_dir).unwrap();
        let script = mother_dir.join("mother");
        std::fs::write(&script, FAKE_MOTHER).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        let mut env = Env::build(guard, dir);
        env.set_env("MOTHER_BIN", script.as_os_str());
        let teri = env.dir.path().join("teri");
        env.set_env("NOSTROMO_TERI_DIR", teri.as_os_str());
        env
    }

    fn build(guard: tokio::sync::MutexGuard<'static, ()>, dir: TempDir) -> Env {
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        )));
        let (tx, rx) = broadcast::channel::<ServerMsg>(256);
        let state = McpSharedState::for_daemon(DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
            session_mgr: Arc::clone(&session_mgr),
            broadcast_tx: tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
        });
        let ledger = Arc::new(SentLedger::new(dir.path().join("teri").join("sent.json")));
        install_ledger(Arc::clone(&ledger));
        Env { _guard: guard, dir, saved: Vec::new(), state, session_mgr, rx, ledger }
    }

    fn set_env(&mut self, key: &'static str, value: impl AsRef<std::ffi::OsStr>) {
        self.saved.push((key, std::env::var_os(key)));
        std::env::set_var(key, value);
    }

    fn daemon(&self) -> &DaemonMcpBackend {
        self.state.daemon.as_ref().expect("daemon backend")
    }

    fn ledger_path(&self) -> PathBuf {
        self.dir.path().join("teri").join("sent.json")
    }

    fn mother_dir(&self) -> PathBuf {
        self.dir.path().join("fake-mother")
    }

    fn teri_dir(&self) -> PathBuf {
        self.dir.path().join("teri")
    }

    fn mother_fail(&self) {
        std::fs::write(self.mother_dir().join("fail"), "").unwrap();
    }

    fn mother_list(&self, json: &str) {
        std::fs::write(self.mother_dir().join("list.json"), json).unwrap();
    }

    fn mother_calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.mother_dir().join("argv.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn mother_adds(&self) -> Vec<String> {
        self.mother_calls().into_iter().filter(|l| l.starts_with("add ")).collect()
    }

    /// A real git repo named `portal` with a Carefeed origin.
    fn repo(&self) -> PathBuf {
        self.repo_named("portal", Some("git@github.com:carefeed/portal.git"))
    }

    fn repo_named(&self, name: &str, origin: Option<&str>) -> PathBuf {
        let path = self.dir.path().join(name);
        std::fs::create_dir_all(&path).unwrap();
        git(&path, &["init", "-q"]);
        if let Some(url) = origin {
            git(&path, &["remote", "add", "origin", url]);
        }
        path
    }

    /// Everything broadcast since the last call.
    fn frames(&mut self) -> Vec<ServerMsg> {
        let mut out = Vec::new();
        loop {
            match self.rx.try_recv() {
                Ok(m) => out.push(m),
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => return out,
            }
        }
    }

    fn created_metas(&mut self) -> Vec<FocusMeta> {
        self.frames()
            .into_iter()
            .filter_map(|m| match m {
                ServerMsg::FocusCreated { meta } => Some(meta),
                _ => None,
            })
            .collect()
    }

    fn is_sensitive(&self, tag: &str) -> bool {
        self.session_mgr.lock().unwrap().sensitive_tags().tag_is_sensitive(tag)
    }

    fn is_alive(&self, tag: &str) -> bool {
        self.session_mgr.lock().unwrap().has_live_session(tag)
    }

    /// The ledger's live markers for `item`, judged the way the daemon judges
    /// a focus marker: its session must be alive.
    fn live_focus_markers(&self, item: &str) -> Vec<SentMarker> {
        let mgr = Arc::clone(&self.session_mgr);
        self.ledger.live_markers(item, &move |m| {
            m.kind == "focus" && mgr.lock().unwrap().has_live_session(&m.target_id)
        })
    }

    fn close_focus(&self, tag: &str) {
        self.session_mgr.lock().unwrap().stop(tag);
    }

    async fn core(&self, req: CreateFocusRequest) -> Result<CreateFocusOutcome, CreateFocusError> {
        create_focus_core(self.daemon(), req).await
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        // The sessions' reader threads live in the runtime's blocking pool: end
        // the children or dropping the runtime waits for them forever.
        self.session_mgr.lock().unwrap_or_else(|e| e.into_inner()).kill_all_on_shutdown();
        for (key, prev) in self.saved.drain(..).rev() {
            match prev {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert!(out.status.success(), "git {args:?} failed: {}", String::from_utf8_lossy(&out.stderr));
}

fn item(id: &str, title: &str) -> SourceItemRef {
    SourceItemRef { id: id.into(), title: title.into() }
}

fn req(agent: &str, title: &str) -> CreateFocusRequest {
    CreateFocusRequest { agent: agent.into(), title: title.into(), ..Default::default() }
}

fn item_req(agent: &str, title: &str, source: SourceItemRef) -> CreateFocusRequest {
    CreateFocusRequest { source_item: Some(source), ..req(agent, title) }
}

fn mother_req(title: &str, source: SourceItemRef, cwd: Option<&Path>) -> CreateFocusRequest {
    CreateFocusRequest {
        agent: "cody".into(),
        title: title.into(),
        label: Some("PORTAL-7".into()),
        working_directory: cwd.map(Path::to_path_buf),
        initial_context: Some("CONTEXT-LINE-ONE\nline two with `code` and a | pipe".into()),
        source_item: Some(source),
        destination: Destination::MotherJob { max_cost: None },
        ..Default::default()
    }
}

fn tag_of(o: &CreateFocusOutcome) -> String {
    o.focus_tag.clone().unwrap_or_else(|| panic!("expected a focus tag: {o:?}"))
}

/// The flags of one `mother add` call, e.g. `--repo` -> `portal`.
fn add_flags(line: &str) -> HashMap<String, String> {
    let toks: Vec<&str> = line.split_whitespace().collect();
    assert_eq!(toks[0], "add");
    let mut flags = HashMap::new();
    let mut i = 1;
    while i < toks.len() {
        if toks[i].starts_with("--") && i + 1 < toks.len() {
            flags.insert(toks[i].to_string(), toks[i + 1].to_string());
            i += 2;
        } else {
            i += 1;
        }
    }
    flags
}

fn briefs(env: &Env) -> Vec<PathBuf> {
    let dir = env.teri_dir().join("mother-briefs");
    let Ok(rd) = std::fs::read_dir(&dir) else { return vec![] };
    let mut v: Vec<PathBuf> = rd.map(|e| e.unwrap().path()).collect();
    v.sort();
    v
}

fn the_brief(env: &Env) -> (PathBuf, String) {
    let all = briefs(env);
    assert_eq!(all.len(), 1, "exactly one brief expected, got {all:?}");
    let text = std::fs::read_to_string(&all[0]).unwrap();
    (all[0].clone(), text)
}

/// Text of the section whose heading line contains `needle` (case-insensitive),
/// up to the next heading.
fn section(brief: &str, needle: &str) -> String {
    let mut out = String::new();
    let mut found = false;
    let mut inside = false;
    for line in brief.lines() {
        if line.starts_with('#') {
            if inside {
                break;
            }
            inside = line.to_lowercase().contains(&needle.to_lowercase());
            found |= inside;
            continue;
        }
        if inside {
            out.push_str(line);
            out.push('\n');
        }
    }
    assert!(found, "brief has no `{needle}` section:\n{brief}");
    out
}

// ═════════════════════════════════════════════════════════════════════════════
// Focus destination: duplicate protection
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn sending_the_same_item_twice_returns_the_existing_focus_and_spawns_once() {
    let env = Env::new().await;
    let title = "cfi-same-item";
    let first = env.core(item_req("cody", title, item("todo:1", title))).await.unwrap();
    assert_eq!(first.kind, OutcomeKind::Created);
    let tag = tag_of(&first);
    wait_for_log(title, "START", |l| l.contains("START")).await;

    let second = env.core(item_req("cody", title, item("todo:1", title))).await.unwrap();
    assert_eq!(second.kind, OutcomeKind::Existing);
    assert_eq!(second.focus_tag.as_deref(), Some(tag.as_str()));
    assert_eq!(fake_starts(title), 1, "no second agent may be spawned");
    assert_eq!(env.ledger.markers("todo:1").len(), 1, "an existing result records nothing new");
}

#[tokio::test]
async fn an_existing_result_registers_and_broadcasts_nothing_new() {
    let mut env = Env::new().await;
    let title = "cfi-existing-quiet";
    env.core(item_req("cody", title, item("todo:2", title))).await.unwrap();
    assert_eq!(env.created_metas().len(), 1);

    env.core(item_req("cody", title, item("todo:2", title))).await.unwrap();
    assert!(env.created_metas().is_empty(), "no FocusCreated for an existing focus");
}

#[tokio::test]
async fn the_same_item_is_found_even_when_the_second_request_uses_a_different_title() {
    let env = Env::new().await;
    let title = "cfi-retitled";
    let first = env.core(item_req("cody", title, item("jira:CORE-9", title))).await.unwrap();
    let second = env
        .core(item_req("cody", "cfi-retitled-again", item("jira:CORE-9", "cfi-retitled-again")))
        .await
        .unwrap();
    assert_eq!(second.kind, OutcomeKind::Existing);
    assert_eq!(second.focus_tag, first.focus_tag);
}

#[tokio::test]
async fn two_different_items_with_the_same_title_get_two_focuses_with_distinct_tags() {
    let env = Env::new().await;
    let title = "cfi-collide";
    let a = env.core(item_req("cody", title, item("todo:10", title))).await.unwrap();
    let b = env.core(item_req("cody", title, item("todo:11", title))).await.unwrap();

    assert_eq!(a.kind, OutcomeKind::Created);
    assert_eq!(b.kind, OutcomeKind::Created);
    let (ta, tb) = (tag_of(&a), tag_of(&b));
    assert_eq!(ta, "cody-cfi-collide");
    assert_eq!(tb, "cody-cfi-collide-2");
    assert!(env.is_alive(&ta) && env.is_alive(&tb));
    wait_for_log(title, "two starts", |l| l.lines().filter(|x| *x == "START").count() == 2).await;
    assert_eq!(env.live_focus_markers("todo:10")[0].target_id, ta);
    assert_eq!(env.live_focus_markers("todo:11")[0].target_id, tb);
}

#[tokio::test]
async fn allow_duplicate_creates_another_focus_for_the_same_item() {
    let env = Env::new().await;
    let title = "cfi-dup-ok";
    let a = env.core(item_req("cody", title, item("todo:20", title))).await.unwrap();
    let b = env.core(item_req("cody", title, item("todo:21", title))).await.unwrap();
    let c = env
        .core(CreateFocusRequest {
            allow_duplicate: true,
            ..item_req("cody", title, item("todo:20", title))
        })
        .await
        .unwrap();

    assert_eq!(c.kind, OutcomeKind::Created);
    let tags = [tag_of(&a), tag_of(&b), tag_of(&c)];
    assert_eq!(tags[2], "cody-cfi-dup-ok-3");
    let mut distinct = tags.to_vec();
    distinct.sort();
    distinct.dedup();
    assert_eq!(distinct.len(), 3, "{tags:?}");
    assert_eq!(env.ledger.markers("todo:20").len(), 2, "both sends are on record");
}

#[tokio::test]
async fn without_a_source_item_a_repeat_request_returns_the_existing_focus() {
    let env = Env::new().await;
    let title = "cfi-plain-repeat";
    let first = env.core(req("cody", title)).await.unwrap();
    wait_for_log(title, "START", |l| l.contains("START")).await;
    let second = env.core(req("cody", title)).await.unwrap();

    assert_eq!(first.kind, OutcomeKind::Created);
    assert_eq!(second.kind, OutcomeKind::Existing);
    assert_eq!(second.focus_tag, first.focus_tag);
    assert_eq!(fake_starts(title), 1);
    assert!(env.ledger.item_ids().is_empty(), "no source item, nothing recorded");
}

#[tokio::test]
async fn closing_the_focus_makes_its_marker_dead_and_a_repeat_creates_a_new_focus() {
    let env = Env::new().await;
    let title = "cfi-close-reopen";
    let first = env.core(item_req("cody", title, item("todo:30", title))).await.unwrap();
    let tag = tag_of(&first);
    assert_eq!(env.live_focus_markers("todo:30").len(), 1);

    env.close_focus(&tag);
    assert!(!env.is_alive(&tag));
    assert!(env.live_focus_markers("todo:30").is_empty(), "a closed focus is no longer live");

    let again = env.core(item_req("cody", title, item("todo:30", title))).await.unwrap();
    assert_eq!(again.kind, OutcomeKind::Created);
    assert!(env.is_alive(&tag_of(&again)));
    assert_eq!(env.live_focus_markers("todo:30").len(), 1);
}

// ═════════════════════════════════════════════════════════════════════════════
// Ledger
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_created_focus_is_recorded_with_its_tag_and_effective_label_and_survives_a_restart() {
    let env = Env::new().await;
    let a = env
        .core(CreateFocusRequest {
            label: Some("CORE-1".into()),
            ..item_req("cody", "cfi-ledger-labelled", item("jira:CORE-1", "cfi-ledger-labelled"))
        })
        .await
        .unwrap();
    let b = env
        .core(item_req("cody", "cfi-ledger-unlabelled", item("todo:40", "cfi-ledger-unlabelled")))
        .await
        .unwrap();

    let ma = &env.ledger.markers("jira:CORE-1")[0];
    assert_eq!(
        (ma.kind.as_str(), ma.target_id.as_str(), ma.label.as_str()),
        ("focus", tag_of(&a).as_str(), "CORE-1")
    );
    assert_eq!(a.label, "CORE-1");
    let mb = &env.ledger.markers("todo:40")[0];
    assert_eq!(mb.label, "cfi-ledger-unlabelled", "label defaults to the title");
    assert_eq!(b.label, "cfi-ledger-unlabelled");

    let reopened = SentLedger::new(env.ledger_path());
    assert_eq!(reopened.markers("jira:CORE-1")[0].target_id, tag_of(&a));
    assert_eq!(reopened.markers("todo:40")[0].target_id, tag_of(&b));
}

// ═════════════════════════════════════════════════════════════════════════════
// Focus metadata
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_broadcast_focus_meta_carries_label_org_project_path_and_selecting_client() {
    let mut env = Env::new().await;
    let repo = env.repo();
    let title = "cfi-meta";
    env.core(CreateFocusRequest {
        label: Some("PORTAL-5".into()),
        working_directory: Some(repo.clone()),
        select_for_client: Some("client-abc".into()),
        ..item_req("cody", title, item("jira:PORTAL-5", title))
    })
    .await
    .unwrap();

    let metas = env.created_metas();
    assert_eq!(metas.len(), 1);
    let m = &metas[0];
    assert_eq!(m.label.as_deref(), Some("PORTAL-5"));
    assert_eq!(m.display_name, title);
    assert_eq!(m.agent_name, "cody");
    assert_eq!(m.org.as_deref(), Some("Carefeed"), "inferred from the repo's origin");
    assert_eq!(m.select_for_client.as_deref(), Some("client-abc"));
    let path = m.project_path.as_deref().expect("project_path");
    assert_eq!(std::fs::canonicalize(path).unwrap(), std::fs::canonicalize(&repo).unwrap());
}

#[tokio::test]
async fn the_meta_label_is_absent_when_the_request_has_none() {
    let mut env = Env::new().await;
    env.core(req("cody", "cfi-meta-nolabel")).await.unwrap();
    let metas = env.created_metas();
    assert_eq!(metas[0].label, None);
    assert_eq!(metas[0].org, None);
    assert_eq!(metas[0].select_for_client, None);
}

#[tokio::test]
async fn an_explicit_org_wins_over_the_inferred_one() {
    let mut env = Env::new().await;
    let repo = env.repo();
    env.core(CreateFocusRequest {
        org: Some("Personal".into()),
        working_directory: Some(repo),
        ..req("cody", "cfi-org-explicit")
    })
    .await
    .unwrap();
    assert_eq!(env.created_metas()[0].org.as_deref(), Some("Personal"));
}

#[tokio::test]
async fn a_blank_org_is_treated_as_absent_and_inferred() {
    let mut env = Env::new().await;
    let repo = env.repo();
    env.core(CreateFocusRequest {
        org: Some("   ".into()),
        working_directory: Some(repo),
        ..req("cody", "cfi-org-blank")
    })
    .await
    .unwrap();
    assert_eq!(env.created_metas()[0].org.as_deref(), Some("Carefeed"));
}

#[tokio::test]
async fn a_repo_with_an_unknown_origin_or_none_gets_no_org() {
    let mut env = Env::new().await;
    let other = env.repo_named("elsewhere", Some("git@github.com:someoneelse/x.git"));
    let bare = env.repo_named("noremote", None);
    env.core(CreateFocusRequest { working_directory: Some(other), ..req("cody", "cfi-org-unknown") })
        .await
        .unwrap();
    env.core(CreateFocusRequest { working_directory: Some(bare), ..req("cody", "cfi-org-none") })
        .await
        .unwrap();
    let metas = env.created_metas();
    assert_eq!(metas.len(), 2);
    assert!(metas.iter().all(|m| m.org.is_none()), "{metas:?}");
}

#[tokio::test]
async fn a_working_directory_that_is_not_an_existing_absolute_dir_is_refused() {
    let env = Env::new().await;
    for bad in [PathBuf::from("relative/dir"), env.dir.path().join("does-not-exist")] {
        let err = env
            .core(CreateFocusRequest { working_directory: Some(bad.clone()), ..req("cody", "cfi-badwd") })
            .await
            .unwrap_err();
        assert_eq!(err.code(), "invalid_working_directory", "{bad:?}: {err}");
    }
    assert_eq!(fake_starts("cfi-badwd"), 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// Sensitivity
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_focus_seeded_with_context_is_sensitive_and_so_is_a_collision_suffixed_one() {
    let env = Env::new().await;
    let title = "cfi-sensitive";
    let a = env
        .core(CreateFocusRequest {
            initial_context: Some("seed one".into()),
            ..item_req("cody", title, item("todo:50", title))
        })
        .await
        .unwrap();
    let b = env
        .core(CreateFocusRequest {
            initial_context: Some("seed two".into()),
            ..item_req("cody", title, item("todo:51", title))
        })
        .await
        .unwrap();
    let (ta, tb) = (tag_of(&a), tag_of(&b));
    assert_eq!(tb, format!("{ta}-2"));
    assert!(env.is_sensitive(&ta), "{ta}");
    assert!(env.is_sensitive(&tb), "{tb} must be marked before anything else");
    wait_for_log(title, "both seeds", |l| l.contains("seed one") && l.contains("seed two")).await;
}

#[tokio::test]
async fn the_initial_context_is_the_first_message_the_agent_receives() {
    let env = Env::new().await;
    let title = "cfi-seed";
    env.core(CreateFocusRequest {
        initial_context: Some("SEED-TEXT-XYZ".into()),
        ..item_req("cody", title, item("todo:52", title))
    })
    .await
    .unwrap();
    wait_for_log(title, "the seed", |l| l.contains("SEED-TEXT-XYZ")).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// MCP adapter
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_mcp_response_has_focus_id_kind_and_label_and_a_repeat_reports_existing() {
    let env = Env::new().await;
    let title = "cfi-mcp-shape";
    let first =
        create_focus(&env.state, &json!({"agent": "cody", "title": title, "label": "My Label"}), None).await;
    assert_eq!(first["kind"], "created", "{first}");
    assert_eq!(first["label"], "My Label", "{first}");
    let id = first["focus_id"].as_str().expect("focus_id kept for compatibility").to_string();
    assert_eq!(id, "cody-cfi-mcp-shape");

    let again = create_focus(&env.state, &json!({"agent": "cody", "title": title}), None).await;
    assert_eq!(again["kind"], "existing", "{again}");
    assert_eq!(again["focus_id"], id.as_str());
    assert_eq!(again["label"], title, "label defaults to the title");
}

#[tokio::test]
async fn the_mcp_item_arguments_dedupe_and_collision_suffix_like_the_core() {
    let env = Env::new().await;
    let title = "cfi-mcp-items";
    let call = |item_id: &str, extra: Value| {
        let mut args = json!({
            "agent": "cody", "title": title,
            "source_item_id": item_id, "source_item_title": title,
        });
        args.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        args
    };
    let a = create_focus(&env.state, &call("todo:60", json!({})), None).await;
    let a2 = create_focus(&env.state, &call("todo:60", json!({})), None).await;
    let b = create_focus(&env.state, &call("todo:61", json!({})), None).await;
    let a3 = create_focus(&env.state, &call("todo:60", json!({"allow_duplicate": true})), None).await;

    assert_eq!(a["kind"], "created");
    assert_eq!(a2["kind"], "existing");
    assert_eq!(a2["focus_id"], a["focus_id"]);
    assert_eq!(b["kind"], "created");
    assert_eq!(b["focus_id"], "cody-cfi-mcp-items-2");
    assert_eq!(a3["kind"], "created");
    assert_eq!(a3["focus_id"], "cody-cfi-mcp-items-3");
}

#[tokio::test]
async fn the_mcp_handler_keeps_its_error_codes() {
    let env = Env::new().await;
    let s = &env.state;
    assert_eq!(create_focus(s, &json!({"title": "t"}), None).await["error"], "invalid_args");
    assert_eq!(create_focus(s, &json!({"agent": "cody"}), None).await["error"], "invalid_args");
    assert_eq!(
        create_focus(s, &json!({"agent": "cody", "title": "t", "working_directory": "nope/rel"}), None).await
            ["error"],
        "invalid_working_directory"
    );
    assert_eq!(
        create_focus(s, &json!({"agent": "cody", "title": "t", "destination": "mother_job"}), None).await
            ["error"],
        "project_required"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Mother destination
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_mother_destination_queues_a_job_with_the_expected_flags() {
    let env = Env::new().await;
    let repo = env.repo();
    let out = env
        .core(mother_req("Fix the login bug", item("jira:PORTAL-7", "Fix the login bug"), Some(&repo)))
        .await
        .unwrap();

    assert_eq!(out.kind, OutcomeKind::Queued);
    assert_eq!(out.job_id.as_deref(), Some("abc123"));
    assert_eq!(out.label, "PORTAL-7");

    let adds = env.mother_adds();
    assert_eq!(adds.len(), 1, "{:?}", env.mother_calls());
    let f = add_flags(&adds[0]);
    assert_eq!(f["--repo"], "portal");
    assert_eq!(
        std::fs::canonicalize(&f["--repo-path"]).unwrap(),
        std::fs::canonicalize(&repo).unwrap()
    );
    assert!(f["--branch"].starts_with("teri/") && f["--branch"].len() > "teri/".len(), "{f:?}");
    assert!(!f["--base"].is_empty(), "a base branch is always given: {f:?}");
    assert_eq!(f["--max-cost"], "10");
    assert_eq!(f["--label"], "teri-send");
    assert_eq!(f["--format"], "text");

    let (brief_path, _) = the_brief(&env);
    let plan = PathBuf::from(&f["--plan-file"]);
    assert!(plan.is_absolute(), "{plan:?}");
    assert_eq!(std::fs::canonicalize(plan).unwrap(), std::fs::canonicalize(&brief_path).unwrap());
    let slug = f["--branch"].trim_start_matches("teri/");
    let name = brief_path.file_name().unwrap().to_string_lossy().into_owned();
    assert!(name.starts_with(&format!("{slug}-")) && name.ends_with(".md"), "{name} vs {slug}");
}

#[tokio::test]
async fn a_custom_max_cost_is_passed_to_mother() {
    let env = Env::new().await;
    let repo = env.repo();
    let mut r = mother_req("Costly", item("todo:70", "Costly"), Some(&repo));
    r.destination = Destination::MotherJob { max_cost: Some(25.0) };
    env.core(r).await.unwrap();
    assert_eq!(add_flags(&env.mother_adds()[0])["--max-cost"], "25");
}

#[tokio::test]
async fn the_mother_brief_has_the_required_sections_and_a_suggested_config() {
    let env = Env::new().await;
    let repo = env.repo();
    let r = mother_req("Fix the login bug", item("jira:PORTAL-7", "Fix the login bug"), Some(&repo));
    let ctx = r.initial_context.clone().unwrap();
    env.core(r).await.unwrap();
    let (_, brief) = the_brief(&env);

    assert_eq!(brief.lines().next().unwrap(), "# PORTAL-7", "H1 is the label");
    assert!(section(&brief, "context").contains(&ctx), "context verbatim:\n{brief}");
    let approach = section(&brief, "approach").to_lowercase();
    assert!(approach.contains("investigate") && approach.contains("mother await"), "{approach}");
    assert!(
        section(&brief, "acceptance").contains("jira:PORTAL-7"),
        "PR must reference the item id:\n{brief}"
    );
    assert!(
        section(&brief, "out of scope").to_lowercase().contains("no changes outside the item's scope"),
        "{brief}"
    );

    let fence_start = brief.find("```yaml").expect("a yaml fence");
    let body = &brief[fence_start + "```yaml".len()..];
    let yaml = &body[..body.find("```").expect("closing fence")];
    let parsed: serde_yaml::Value = serde_yaml::from_str(yaml).expect("the fence is valid yaml");
    let config = &parsed["suggested_config"];
    for agent in ["cody", "redd", "marty", "perri"] {
        let a = &config[agent];
        assert_eq!(a["model"].as_str(), Some("sonnet"), "{agent}: {yaml}");
        assert_eq!(a["effort"].as_str(), Some("medium"), "{agent}: {yaml}");
        assert!(a["rationale"].as_str().is_some_and(|r| !r.trim().is_empty()), "{agent}: {yaml}");
    }
}

#[cfg(unix)]
#[tokio::test]
async fn the_brief_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let env = Env::new().await;
    let repo = env.repo();
    env.core(mother_req("Private", item("todo:71", "Private"), Some(&repo))).await.unwrap();
    let (path, _) = the_brief(&env);
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(path.parent().unwrap()), 0o700);
}

#[tokio::test]
async fn a_queued_job_is_recorded_under_the_item_and_survives_a_restart() {
    let env = Env::new().await;
    let repo = env.repo();
    env.core(mother_req("Recorded", item("jira:PORTAL-7", "Recorded"), Some(&repo))).await.unwrap();

    for ledger in [Arc::clone(&env.ledger), Arc::new(SentLedger::new(env.ledger_path()))] {
        let m = ledger.markers("jira:PORTAL-7");
        assert_eq!(m.len(), 1);
        assert_eq!(
            (m[0].kind.as_str(), m[0].target_id.as_str(), m[0].label.as_str()),
            ("mother_job", "abc123", "PORTAL-7")
        );
    }
}

#[tokio::test]
async fn a_mother_job_without_a_working_directory_is_refused_and_mother_is_never_called() {
    let env = Env::new().await;
    let err = env.core(mother_req("No dir", item("todo:72", "No dir"), None)).await.unwrap_err();
    assert_eq!(err, CreateFocusError::ProjectRequired);
    assert!(env.mother_calls().is_empty(), "{:?}", env.mother_calls());
    assert!(env.ledger.item_ids().is_empty());
    assert!(briefs(&env).is_empty());
}

#[tokio::test]
async fn a_mother_job_outside_a_git_repo_is_refused() {
    let env = Env::new().await;
    let plain = env.dir.path().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let err = env.core(mother_req("Not git", item("todo:73", "Not git"), Some(&plain))).await.unwrap_err();
    assert_eq!(err.code(), "not_a_git_repo", "{err}");
    assert!(env.mother_adds().is_empty());
    assert!(env.ledger.item_ids().is_empty());
}

#[tokio::test]
async fn a_failing_mother_add_is_mother_failed_with_its_stderr_and_records_nothing() {
    let env = Env::new().await;
    let repo = env.repo();
    env.mother_fail();
    let err = env.core(mother_req("Doomed", item("todo:74", "Doomed"), Some(&repo))).await.unwrap_err();

    assert_eq!(err.code(), "mother_failed");
    assert!(err.detail().contains("boom: bad plan"), "{}", err.detail());
    assert!(env.ledger.item_ids().is_empty(), "no marker for a job that was never queued");
    assert!(!env.ledger_path().exists() || SentLedger::new(env.ledger_path()).item_ids().is_empty());
}

#[tokio::test]
async fn the_mcp_handler_reports_a_mother_failure_and_a_queued_job() {
    let env = Env::new().await;
    let repo = env.repo();
    let args = json!({
        "agent": "cody", "title": "Via MCP", "working_directory": repo,
        "destination": "mother_job", "initial_context": "ctx", "label": "L-1",
        "source_item_id": "todo:75", "source_item_title": "Via MCP", "max_cost": 3,
    });

    env.mother_fail();
    let failed = create_focus(&env.state, &args, None).await;
    assert_eq!(failed["error"], "mother_failed", "{failed}");
    assert!(failed["detail"].as_str().unwrap().contains("boom: bad plan"), "{failed}");

    std::fs::remove_file(env.mother_dir().join("fail")).unwrap();
    let ok = create_focus(&env.state, &args, None).await;
    assert_eq!(ok["kind"], "queued", "{ok}");
    assert_eq!(ok["job_id"], "abc123");
    assert_eq!(ok["label"], "L-1");
    assert_eq!(add_flags(env.mother_adds().last().unwrap())["--max-cost"], "3");
}

#[tokio::test]
async fn a_live_mother_job_for_the_item_is_returned_instead_of_queueing_another() {
    let env = Env::new().await;
    let repo = env.repo();
    let src = || item("jira:PORTAL-7", "Dedupe");
    env.core(mother_req("Dedupe", src(), Some(&repo))).await.unwrap();

    let again = env.core(mother_req("Dedupe", src(), Some(&repo))).await.unwrap();
    assert_eq!(again.kind, OutcomeKind::Existing);
    assert_eq!(again.job_id.as_deref(), Some("abc123"));
    assert_eq!(env.mother_adds().len(), 1, "no second job");
    assert_eq!(briefs(&env).len(), 1, "no second brief");

    // A focus request for the same item also finds the live job.
    let as_focus = env.core(item_req("cody", "cfi-job-then-focus", src())).await.unwrap();
    assert_eq!(as_focus.kind, OutcomeKind::Existing);
    assert_eq!(as_focus.job_id.as_deref(), Some("abc123"));
    assert_eq!(fake_starts("cfi-job-then-focus"), 0);
}

#[tokio::test]
async fn once_mother_no_longer_lists_the_job_a_repeat_queues_a_new_one() {
    let env = Env::new().await;
    let repo = env.repo();
    let src = || item("jira:PORTAL-7", "Gone");
    env.core(mother_req("Gone", src(), Some(&repo))).await.unwrap();
    env.mother_list("[]");

    let again = env.core(mother_req("Gone", src(), Some(&repo))).await.unwrap();
    assert_eq!(again.kind, OutcomeKind::Queued);
    assert_eq!(env.mother_adds().len(), 2);
}

#[tokio::test]
async fn allow_duplicate_queues_another_job_even_while_the_first_is_listed() {
    let env = Env::new().await;
    let repo = env.repo();
    let src = || item("jira:PORTAL-7", "Twice");
    env.core(mother_req("Twice", src(), Some(&repo))).await.unwrap();
    let mut second = mother_req("Twice", src(), Some(&repo));
    second.allow_duplicate = true;
    let out = env.core(second).await.unwrap();
    assert_eq!(out.kind, OutcomeKind::Queued);
    assert_eq!(env.mother_adds().len(), 2);
}

// ═════════════════════════════════════════════════════════════════════════════
// Credentials never travel
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn no_credential_value_reaches_a_brief_a_seeded_message_a_broadcast_or_an_error() {
    let mut env = Env::new().await;
    const SENTINEL: &str = "SENTINEL-s3cr3t-9f8e7d6c";
    env.set_env("JIRA_API_TOKEN", SENTINEL);
    env.set_env("SENTRY_AUTH_TOKEN", SENTINEL);
    let repo = env.repo();
    std::fs::write(repo.join(".env"), format!("JIRA_API_TOKEN={SENTINEL}\n")).unwrap();
    std::fs::create_dir_all(env.teri_dir()).unwrap();
    std::fs::write(env.teri_dir().join("credentials.env"), format!("JIRA_API_TOKEN={SENTINEL}\n")).unwrap();

    let title = "cfi-sentinel";
    let mut focus = item_req("cody", title, item("jira:PORTAL-8", title));
    focus.working_directory = Some(repo.clone());
    focus.initial_context = Some("Jira PORTAL-8: the login page 500s. Reproduce and fix.".into());
    env.core(focus).await.unwrap();
    wait_for_log(title, "the seed", |l| l.contains("login page 500s")).await;

    let mut job = mother_req("Sentinel job", item("jira:PORTAL-9", "Sentinel job"), Some(&repo));
    job.initial_context = Some("Jira PORTAL-9: the signup page 500s. Reproduce and fix.".into());
    env.core(job.clone()).await.unwrap();
    env.mother_fail();
    job.source_item = Some(item("jira:PORTAL-10", "Sentinel failing job"));
    let mut errors = vec![env.core(job).await.unwrap_err().to_string()];
    errors.push(
        env.core(CreateFocusRequest {
            working_directory: Some(PathBuf::from("relative")),
            ..req("cody", "cfi-sentinel-err")
        })
        .await
        .unwrap_err()
        .to_string(),
    );
    let mcp_error = create_focus(
        &env.state,
        &json!({"agent": "cody", "title": "x", "destination": "mother_job"}),
        None,
    )
    .await;
    errors.push(mcp_error.to_string());

    let mut haystacks: Vec<(String, String)> = Vec::new();
    for p in briefs(&env) {
        haystacks.push((format!("brief {p:?}"), std::fs::read_to_string(p).unwrap()));
    }
    haystacks.push(("fake claude stdin".into(), fake_log(title)));
    for (i, f) in env.frames().into_iter().enumerate() {
        haystacks.push((format!("broadcast frame {i}"), serde_json::to_string(&f).unwrap()));
    }
    for (i, e) in errors.into_iter().enumerate() {
        haystacks.push((format!("error {i}"), e));
    }
    haystacks.push(("mother argv".into(), env.mother_calls().join("\n")));
    haystacks.push(("ledger".into(), std::fs::read_to_string(env.ledger_path()).unwrap_or_default()));

    assert!(haystacks.len() > 6, "the check must have had something to look at");
    for (what, text) in haystacks {
        assert!(!text.contains(SENTINEL), "credential leaked into {what}: {text}");
    }
}
