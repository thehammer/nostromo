//! Mother focus v2, slice MF1: who queued a Mother job, as the daemon vouches
//! for it.
//!
//! Observed from the outside only:
//!
//! * the daemon-hosted MCP server over its Unix socket (`mother.enqueue_job`,
//!   `mother.list_jobs`, `mother.get_job`, `nostromo.create_focus`), with a fake
//!   `mother` on `MOTHER_BIN` that records its argv;
//! * `JobsFeed` with an `OriginBook` (what every reader of the job feed sees);
//! * the audit file, the book and history files on disk;
//! * the golden `MotherJobs` frame the Kit tests decode
//!   (`tests/fixtures/mother-v2/mother-jobs-annotated.json`).
//!
//! `MOTHER_BIN`, `NOSTROMO_TERI_DIR` and the sent ledger are process-global:
//! every test that needs them runs under `ENV_LOCK`.
//!
//! The wire form of the network redaction is in `tests/ipc_peer_gating.rs`;
//! Send to agent as the real work hub drives it is in `tests/work_send.rs`.

use std::collections::BTreeSet;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::data::work::sent::{install_ledger, SentLedger};
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{FocusMeta, ServerMsg};
use nostromo::ipc::session_manager::CLAUDE_BIN_ENV;
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::create_focus::{
    create_focus, create_focus_core, CreateFocusRequest, Destination, OutcomeKind, SourceItemRef,
};
use nostromo::mcp::{DaemonMcpBackend, DaemonSources, McpServer, McpSharedState, PerriDaemonState};
use nostromo::mother::audit::MotherAudit;
use nostromo::mother::origin::{JobAnnotation, NotifyLevel, OriginKind, OriginView, Stamp, Via};
use nostromo::mother::{JobsFeed, MotherJob, OriginBook, SessionHistory};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, watch};

/// A guard against a hung test, not a bound on how fast anything must be.
const HANG_GUARD: Duration = Duration::from_secs(120);

/// `MOTHER_BIN`, `NOSTROMO_TERI_DIR` and the sent ledger are process-global.
static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

// ═════════════════════════════════════════════════════════════════════════════
// fake `mother`
// ═════════════════════════════════════════════════════════════════════════════

/// Which `mother` is installed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mother {
    /// Takes `--origin-session` but dies "unknown flag" on `--origin-focus`,
    /// `--origin-focus-name` and on `add --help`.
    Old,
    /// Also takes `--origin-focus` / `--origin-focus-name`, and its `add --help`
    /// names them.
    New,
}

/// Every call's argv is logged one line each, the arguments joined by the ASCII
/// unit separator (so a value with spaces survives). `add` mints `job1`,
/// `job2`, ... and `list` prints every minted job (titled from the `title`
/// file when there is one, with the `origin` claim `add` was given: the
/// `--origin-focus` / `--origin-session` values). When a `hold` file exists,
/// `add` mints the job and then waits for a `release` file before it answers;
/// when a `fail` file exists, `add` exits 1 before it mints anything.
const FAKE_MOTHER: &str = r#"#!/bin/sh
here="$(dirname "$0")"
for a in "$@"; do printf '%s\037' "$a"; done >> "$here/argv.log"
printf '\n' >> "$here/argv.log"
sub="$1"
[ $# -gt 0 ] && shift
case "$sub" in
  add)
    for a in "$@"; do
      if [ "$a" = "--help" ]; then
        if [ -e "$here/new" ]; then
          echo "usage: mother add --plan-file PATH --repo NAME --branch BRANCH [--origin-session SID] [--origin-focus TAG] [--origin-focus-name NAME]"
          exit 0
        fi
        echo "add: unknown flag: --help" >&2
        exit 2
      fi
    done
    vflags=" --plan-file --repo --branch --repo-path --base --max-cost --depends-on --title --format --label --origin-session "
    if [ -e "$here/new" ]; then vflags="$vflags--origin-focus --origin-focus-name "; fi
    ofocus=""
    osession=""
    while [ $# -gt 0 ]; do
      case "$vflags" in
        *" $1 "*)
          [ $# -ge 2 ] || { echo "add: flag needs an argument: $1" >&2; exit 2; }
          [ "$1" = "--origin-focus" ] && ofocus="$2"
          [ "$1" = "--origin-session" ] && osession="$2"
          shift 2 ;;
        *) echo "add: unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    if [ -e "$here/fail" ]; then echo "add: boom" >&2; exit 1; fi
    n=$(wc -l < "$here/ids" | tr -d ' ')
    n=$((n+1))
    # What the job record claims, as `mother list` shows it (written before the
    # job is listed).
    if [ -n "$ofocus" ] || [ -n "$osession" ]; then
      sep=""
      printf '{' > "$here/origin.job$n"
      if [ -n "$ofocus" ]; then printf '"focus":"%s"' "$ofocus" >> "$here/origin.job$n"; sep=","; fi
      if [ -n "$osession" ]; then printf '%s"session":"%s"' "$sep" "$osession" >> "$here/origin.job$n"; fi
      printf '}' >> "$here/origin.job$n"
    fi
    echo "job$n" >> "$here/ids"
    # With a `hold` file the job exists (it is listed) but `add` has not
    # answered yet: it waits for a `release` file (at most two minutes).
    if [ -e "$here/hold" ]; then
      i=0
      while [ ! -e "$here/release" ] && [ $i -lt 2400 ]; do sleep 0.05; i=$((i+1)); done
    fi
    echo "job$n" ;;
  list)
    title="Fake title"
    if [ -e "$here/title" ]; then title="$(cat "$here/title")"; fi
    printf '['
    first=1
    while IFS= read -r id; do
      [ $first = 1 ] || printf ','
      first=0
      printf '{"id":"%s","state":"queued","title":"%s"' "$id" "$title"
      if [ -e "$here/origin.$id" ]; then printf ',"origin":%s' "$(cat "$here/origin.$id")"; fi
      printf '}'
    done < "$here/ids"
    printf ']\n' ;;
  *) echo "mother: unknown command: $sub" >&2; exit 2 ;;
esac
exit 0
"#;

fn install_fake_mother(dir: &Path, which: Mother) -> PathBuf {
    std::fs::create_dir_all(dir).unwrap();
    let script = dir.join("mother");
    std::fs::write(&script, FAKE_MOTHER).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(dir.join("ids"), "").unwrap();
    if which == Mother::New {
        std::fs::write(dir.join("new"), "").unwrap();
    }
    script
}

// ═════════════════════════════════════════════════════════════════════════════
// harness: a daemon-hosted MCP server with an origin book
// ═════════════════════════════════════════════════════════════════════════════

struct Rig {
    _server: McpServer,
    state: McpSharedState,
    mgr: Arc<Mutex<SessionManager>>,
    feed: JobsFeed,
    book: OriginBook,
    history: SessionHistory,
    socket: PathBuf,
    mother_dir: PathBuf,
    store_path: PathBuf,
    audit_path: PathBuf,
    saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    dir: TempDir,
    _guard: tokio::sync::MutexGuard<'static, ()>,
}

impl Rig {
    async fn new(which: Mother) -> Rig {
        let guard = ENV_LOCK.lock().await;
        let dir = TempDir::new().unwrap();
        let mother_dir = dir.path().join("fake-mother");
        let script = install_fake_mother(&mother_dir, which);
        let teri_dir = dir.path().join("teri");

        let mut saved = Vec::new();
        for (key, value) in [
            ("MOTHER_BIN", script.as_os_str()),
            ("NOSTROMO_TERI_DIR", teri_dir.as_os_str()),
        ] {
            saved.push((key, std::env::var_os(key)));
            std::env::set_var(key, value);
        }
        install_ledger(Arc::new(SentLedger::new(teri_dir.join("sent.json"))));

        let store_path = dir.path().join("sessions.json");
        let mut manager = SessionManager::with_store_path(store_path.clone());
        let history = manager.session_history();
        let audit_path = dir.path().join("audit").join("mother.jsonl");
        let audit = MotherAudit::open(&audit_path).expect("open the mother audit");
        let book = OriginBook::open(OriginBook::path_beside(&store_path), history.clone(), audit);
        manager.configure_origin_book(book.clone());
        let mgr = Arc::new(Mutex::new(manager));
        let feed = JobsFeed::new().with_origins(book.clone());

        let (tx, _rx) = broadcast::channel::<ServerMsg>(64);
        let backend = DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::with_store_path(
                dir.path().join("panes.json"),
            ))),
            session_mgr: Arc::clone(&mgr),
            broadcast_tx: tx,
            perri: PerriDaemonState {
                state_dir: Some(dir.path().join("perri-state")),
                pr_refresh_tx: None,
                queue_refresh_tx: None,
                selected_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
                settle_timeout: Duration::from_millis(100),
            },
            decisions: Arc::new(Mutex::new(
                nostromo::ipc::decisions::DecisionRegistry::default(),
            )),
            tickets: Default::default(),
            tracker: Default::default(),
            terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
        };
        let (_queue_tx, queue_rx) = watch::channel(None);
        let (pr_tx, pr_rx) = watch::channel(nostromo::data::perri_pr::no_prs());
        let (_mailbox_tx, mailbox_rx) = watch::channel(None);
        let (_calendar_tx, calendar_rx) = watch::channel(None);
        let (_todos_tx, todos_rx) = watch::channel(None);
        // A dropped PR sender is a verdict: keep it for the process.
        std::mem::forget(pr_tx);
        std::mem::forget(_queue_tx);
        std::mem::forget(_mailbox_tx);
        std::mem::forget(_calendar_tx);
        std::mem::forget(_todos_tx);
        let state = McpSharedState::for_daemon_with_sources(
            backend,
            DaemonSources {
                perri_queue_rx: queue_rx,
                perri_pr_rx: pr_rx,
                mother: feed.clone(),
                fred_mailbox_rx: mailbox_rx,
                fred_calendar_rx: calendar_rx,
                teri_todos_rx: todos_rx,
                work_hub: None,
                huey: None,
                huey_rx: watch::channel(nostromo::huey::HueyView::default()).1,
                enabled_agents: nostromo::agents::EnabledAgents::all(),
            },
        );
        let socket = dir.path().join("mcp.sock");
        let server = McpServer::bind(socket.clone(), state.clone())
            .await
            .expect("the MCP server binds");
        Rig {
            _server: server,
            state,
            mgr,
            feed,
            book,
            history,
            socket,
            mother_dir,
            store_path,
            audit_path,
            saved,
            dir,
            _guard: guard,
        }
    }

    async fn client(&self, pty_id: &str) -> Client {
        Client::connect(&self.socket, pty_id).await
    }

    /// Register focus `tag` named `name` (as the daemon does for a focus it
    /// created) and give it the running Claude session `sid`.
    fn add_focus(&self, tag: &str, name: &str, sid: &str) {
        self.mgr
            .lock()
            .unwrap()
            .add_or_update_focus(focus_meta(tag, name));
        self.store_session(tag, sid);
    }

    /// [`Rig::add_focus`] for a focus running `agent` (a Teri or Fred focus is
    /// sensitive from the moment it is registered).
    fn add_focus_as(&self, tag: &str, name: &str, sid: &str, agent: &str) {
        self.mgr
            .lock()
            .unwrap()
            .add_or_update_focus(focus_meta_for(tag, name, agent));
        self.store_session(tag, sid);
    }

    /// The manager's own registry of sensitive focuses (a shared handle).
    fn sensitive_tags(&self) -> nostromo::ipc::peer::SensitiveTags {
        self.mgr.lock().unwrap().sensitive_tags()
    }

    /// The daemon's `tag -> session id` store, as the daemon wrote it.
    fn store_session(&self, tag: &str, sid: &str) {
        let mut map: serde_json::Map<String, Value> = std::fs::read(&self.store_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        map.insert(tag.into(), json!(sid));
        std::fs::write(&self.store_path, serde_json::to_vec(&map).unwrap()).unwrap();
    }

    /// The Mac pushes its focus registry.
    fn push_registry(&self, focuses: Vec<FocusMeta>) {
        self.mgr.lock().unwrap().set_focus_registry(focuses);
    }

    fn plan(&self) -> PathBuf {
        self.plan_named("plan.md")
    }

    fn plan_named(&self, name: &str) -> PathBuf {
        let p = self.dir.path().join(name);
        std::fs::write(&p, "# plan\n").unwrap();
        p
    }

    /// Every `mother` call, one `Vec` of arguments each (the subcommand first).
    fn calls(&self) -> Vec<Vec<String>> {
        std::fs::read_to_string(self.mother_dir.join("argv.log"))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                l.split('\u{1f}')
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .collect()
    }

    /// The `mother add` calls that queued a job (not the `--help` probe).
    fn adds(&self) -> Vec<Vec<String>> {
        self.calls()
            .into_iter()
            .filter(|c| {
                c.first().map(String::as_str) == Some("add") && c.iter().any(|a| a == "--plan-file")
            })
            .collect()
    }

    fn the_add(&self) -> Vec<String> {
        let mut adds = self.adds();
        assert_eq!(
            adds.len(),
            1,
            "exactly one `mother add`: {:?}",
            self.calls()
        );
        adds.remove(0)
    }

    fn audit(&self) -> Vec<Value> {
        audit_lines(&self.audit_path)
    }

    /// A git repo named `portal` (a Send-to-agent job needs a working directory).
    fn repo(&self) -> PathBuf {
        let path = self.dir.path().join("portal");
        std::fs::create_dir_all(&path).unwrap();
        for args in [
            vec!["init", "-q"],
            vec![
                "remote",
                "add",
                "origin",
                "git@github.com:carefeed/portal.git",
            ],
        ] {
            let mut cmd = std::process::Command::new("git");
            for var in [
                "GIT_DIR",
                "GIT_WORK_TREE",
                "GIT_INDEX_FILE",
                "GIT_COMMON_DIR",
                "GIT_OBJECT_DIRECTORY",
                "GIT_PREFIX",
            ] {
                cmd.env_remove(var);
            }
            let out = cmd.arg("-C").arg(&path).args(&args).output().unwrap();
            assert!(out.status.success(), "git {args:?}");
        }
        path
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        for (key, prev) in self.saved.drain(..).rev() {
            match prev {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}

fn flag<'a>(argv: &'a [String], name: &str) -> Option<&'a str> {
    argv.iter()
        .position(|a| a == name)
        .and_then(|i| argv.get(i + 1))
        .map(String::as_str)
}

fn has_origin_flag(argv: &[String]) -> bool {
    argv.iter().any(|a| a.starts_with("--origin"))
}

fn focus_meta(tag: &str, name: &str) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: name.into(),
        agent_name: "claudia".into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
        initial_model: None,
        initial_effort: None,
    }
}

fn focus_meta_for(tag: &str, name: &str, agent: &str) -> FocusMeta {
    FocusMeta {
        agent_name: agent.into(),
        ..focus_meta(tag, name)
    }
}

/// Wait for `condition` (polled, with the hang guard as the deadline).
async fn wait_until(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + HANG_GUARD;
    while !condition() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "gave up waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn audit_lines(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("audit line {l:?}: {e}")))
        .collect()
}

fn keys(v: &Value) -> BTreeSet<&str> {
    v.as_object()
        .expect("a JSON object")
        .keys()
        .map(String::as_str)
        .collect()
}

fn key_set(names: &[&'static str]) -> BTreeSet<&'static str> {
    names.iter().copied().collect()
}

// ── MCP client ───────────────────────────────────────────────────────────────

struct Client {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    next_id: i64,
}

async fn send_line<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

impl Client {
    /// Connect as the focus `pty_id` (the hello's `pty_id` is the focus tag).
    async fn connect(socket: &Path, pty_id: &str) -> Client {
        let stream = UnixStream::connect(socket).await.unwrap();
        let (r, mut writer) = stream.into_split();
        let mut reader = BufReader::new(r);
        send_line(&mut writer, &json!({"type":"hello","pty_id":pty_id})).await;
        send_line(
            &mut writer,
            &json!({
                "jsonrpc":"2.0","id":1,"method":"initialize",
                "params":{"protocolVersion":"2024-11-05","capabilities":{},
                          "clientInfo":{"name":"t","version":"0"}}
            }),
        )
        .await;
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        Client {
            reader,
            writer,
            next_id: 2,
        }
    }

    /// `tools/call`, returning the parsed tool-content JSON.
    async fn call(&mut self, name: &str, args: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        send_line(
            &mut self.writer,
            &json!({"jsonrpc":"2.0","id":id,"method":"tools/call",
                    "params":{"name":name,"arguments":args}}),
        )
        .await;
        let mut line = String::new();
        tokio::time::timeout(HANG_GUARD, self.reader.read_line(&mut line))
            .await
            .unwrap_or_else(|_| panic!("{name} never answered"))
            .unwrap();
        let resp: Value = serde_json::from_str(line.trim()).expect("response is JSON");
        assert!(resp.get("error").is_none(), "{name} JSON-RPC error: {resp}");
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        serde_json::from_str(text).expect("tool content should be JSON")
    }

    async fn enqueue(&mut self, plan: &Path, extra: Value) -> Value {
        let mut args = json!({ "plan_path": plan, "repo": "nostromo", "branch": "feat/x" });
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            args[k] = v;
        }
        self.call("mother.enqueue_job", args).await
    }

    async fn get_job(&mut self, id: &str) -> Value {
        self.call("mother.get_job", json!({ "id": id })).await
    }
}

// ── jobs and a feed without a daemon ─────────────────────────────────────────

fn job(id: &str, origin: Option<Value>) -> MotherJob {
    let mut v = json!({ "id": id, "state": "queued", "title": format!("title of {id}") });
    if let Some(o) = origin {
        v["origin"] = o;
    }
    serde_json::from_value(v).expect("a mother job")
}

/// A claim as a job record in Mother holds it.
fn claim(focus: &str, session: &str) -> Value {
    json!({ "focus": focus, "session": session })
}

fn kind_of(j: &MotherJob) -> OriginKind {
    j.nostromo
        .as_ref()
        .unwrap_or_else(|| panic!("job {} carries no annotation", j.id))
        .origin
        .kind
}

struct FeedRig {
    _dir: TempDir,
    history: SessionHistory,
    book: OriginBook,
    feed: JobsFeed,
    audit_path: PathBuf,
}

fn feed_rig() -> FeedRig {
    let dir = TempDir::new().unwrap();
    let history = SessionHistory::in_memory();
    let audit_path = dir.path().join("audit").join("mother.jsonl");
    let audit = MotherAudit::open(&audit_path).expect("open the mother audit");
    let book = OriginBook::in_memory(history.clone(), audit);
    let feed = JobsFeed::new().with_origins(book.clone());
    FeedRig {
        _dir: dir,
        history,
        book,
        feed,
        audit_path,
    }
}

impl FeedRig {
    fn audit(&self) -> Vec<Value> {
        audit_lines(&self.audit_path)
    }

    fn unverified_audits_of(&self, id: &str) -> usize {
        self.audit()
            .iter()
            .filter(|l| l["event"] == "job_origin_unverified" && l["job"] == id)
            .count()
    }
}

const FOCUS: &str = "claudia-AAAA1111";
const FOCUS_NAME: &str = "Fix the login flow";
const FOCUS_SID: &str = "5f3c9a10-aaaa-4bbb-8ccc-1234567890ab";

// ═════════════════════════════════════════════════════════════════════════════
// MF1-1  enqueue_job from a focus records that focus
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn enqueue_from_a_focus_passes_its_session_tag_and_name_to_a_mother_that_takes_them() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert_eq!(res["id"], "job1", "{res}");
    let add = rig.the_add();
    assert_eq!(flag(&add, "--origin-session"), Some(FOCUS_SID), "{add:?}");
    assert_eq!(flag(&add, "--origin-focus"), Some(FOCUS), "{add:?}");
    assert_eq!(
        flag(&add, "--origin-focus-name"),
        Some(FOCUS_NAME),
        "{add:?}"
    );
}

#[tokio::test]
async fn enqueue_from_a_focus_records_its_tag_name_and_session_prefix_before_anyone_reads_the_job()
{
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    let res = c.enqueue(&rig.plan(), json!({})).await;
    assert_eq!(
        res["origin"],
        json!({"kind": "focus", "focus_tag": FOCUS}),
        "{res}"
    );

    // The book holds it as soon as `mother add` has answered.
    let entry = rig.book.entry("job1").expect("the book holds the job");
    assert_eq!(entry.kind, OriginKind::Focus);
    assert_eq!(entry.focus_tag.as_deref(), Some(FOCUS));
    assert_eq!(entry.name_snapshot.as_deref(), Some(FOCUS_NAME));
    assert_eq!(entry.session_prefix.as_deref(), Some("5f3c9a10"));
    assert_eq!(entry.via, Via::Mcp);

    // And every reader sees it on the job.
    let job = c.get_job("job1").await;
    let origin = &job["nostromo"]["origin"];
    assert_eq!(origin["kind"], "focus", "{job}");
    assert_eq!(origin["focus_tag"], FOCUS, "{job}");
    assert_eq!(origin["name_snapshot"], FOCUS_NAME, "{job}");
    assert_eq!(origin["focus_name"], FOCUS_NAME, "{job}");
    assert_eq!(origin["session_prefix"], "5f3c9a10", "{job}");
}

#[tokio::test]
async fn enqueue_with_an_old_mother_passes_the_session_but_never_the_two_new_flags_and_still_succeeds(
) {
    let rig = Rig::new(Mother::Old).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert_eq!(
        res["id"], "job1",
        "an old mother must not break enqueue: {res}"
    );
    assert!(res.get("error").is_none(), "{res}");
    let add = rig.the_add();
    assert_eq!(flag(&add, "--origin-session"), Some(FOCUS_SID), "{add:?}");
    for call in rig.calls() {
        assert!(
            !call.iter().any(|a| a.starts_with("--origin-focus")),
            "an old mother is never handed --origin-focus*: {call:?}"
        );
    }
    // The daemon's own record does not depend on what Mother takes.
    let entry = rig.book.entry("job1").expect("the book holds the job");
    assert_eq!(
        (entry.kind, entry.focus_tag.as_deref()),
        (OriginKind::Focus, Some(FOCUS))
    );
    assert_eq!(
        c.get_job("job1").await["nostromo"]["origin"]["kind"],
        "focus"
    );
}

#[tokio::test]
async fn a_caller_that_is_not_a_focus_the_daemon_knows_passes_no_origin_flags_and_is_never_stamped()
{
    // The pty "teri" is what the existing mother-mutator tests connect as: no
    // focus of that tag is registered.
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client("teri").await;

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert_eq!(res["id"], "job1", "{res}");
    assert!(
        res.get("origin").is_none(),
        "no origin is claimed for it: {res}"
    );
    assert!(res.get("origin_overridden").is_none(), "{res}");
    let add = rig.the_add();
    assert!(!has_origin_flag(&add), "no origin flag at all: {add:?}");
    // Nothing is stamped: the job is just an unknown-origin job to the feed.
    let job = c.get_job("job1").await;
    assert_eq!(job["nostromo"]["origin"]["kind"], "unknown", "{job}");
    assert!(
        job["nostromo"]["origin"].get("focus_tag").is_none(),
        "{job}"
    );
    assert!(
        rig.audit()
            .iter()
            .all(|l| l["event"] != "job_origin_stamped"),
        "nothing was stamped: {:?}",
        rig.audit()
    );
}

#[tokio::test]
async fn a_connection_that_never_said_who_it_is_passes_no_origin_flags_either() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    // A hello with no pty id.
    let stream = UnixStream::connect(&rig.socket).await.unwrap();
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r);
    send_line(&mut w, &json!({"type":"hello"})).await;
    send_line(
        &mut w,
        &json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}),
    )
    .await;
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    let mut c = Client {
        reader,
        writer: w,
        next_id: 2,
    };

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert_eq!(res["id"], "job1", "{res}");
    assert!(!has_origin_flag(&rig.the_add()));
    assert!(rig
        .audit()
        .iter()
        .all(|l| l["event"] != "job_origin_stamped"));
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-2  a caller cannot name another origin
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn every_argument_that_names_another_focus_is_ignored_and_the_job_records_the_caller() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    rig.add_focus(
        "claudia-OTHER000",
        "Somebody else",
        "0ther000-0000-4000-8000-000000000000",
    );
    let mut c = rig.client(FOCUS).await;

    for (n, key) in [
        "origin_focus",
        "origin",
        "focus",
        "origin_session",
        "origin_focus_name",
    ]
    .into_iter()
    .enumerate()
    {
        let named = match key {
            "origin_session" => json!("0ther000-0000-4000-8000-000000000000"),
            "origin_focus_name" => json!("Somebody else"),
            "origin" => json!({"focus": "claudia-OTHER000", "session": "x"}),
            _ => json!("claudia-OTHER000"),
        };
        let res = c.enqueue(&rig.plan(), json!({ key: named })).await;

        let id = format!("job{}", n + 1);
        assert_eq!(res["id"], id.as_str(), "{key}: {res}");
        assert_eq!(res["origin_overridden"], true, "{key}: {res}");
        assert_eq!(res["origin"]["focus_tag"], FOCUS, "{key}: {res}");
        let entry = rig
            .book
            .entry(&id)
            .unwrap_or_else(|| panic!("{key}: no entry"));
        assert_eq!(entry.focus_tag.as_deref(), Some(FOCUS), "{key}");
        assert_eq!(entry.name_snapshot.as_deref(), Some(FOCUS_NAME), "{key}");
        let job = c.get_job(&id).await;
        assert_eq!(
            job["nostromo"]["origin"]["focus_tag"], FOCUS,
            "{key}: {job}"
        );
    }

    // Whatever the arguments said, Mother was only ever told the caller.
    for add in rig.adds() {
        assert_eq!(flag(&add, "--origin-focus"), Some(FOCUS), "{add:?}");
        assert_eq!(
            flag(&add, "--origin-focus-name"),
            Some(FOCUS_NAME),
            "{add:?}"
        );
        assert_eq!(flag(&add, "--origin-session"), Some(FOCUS_SID), "{add:?}");
        let line = add.join(" ");
        assert!(
            !line.contains("OTHER000") && !line.contains("0ther000") && !line.contains("Somebody"),
            "the other origin never reached mother: {line}"
        );
    }
}

#[tokio::test]
async fn without_an_origin_argument_the_result_has_no_origin_overridden_key() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert!(res.get("origin_overridden").is_none(), "{res}");
    assert_eq!(res["origin"]["focus_tag"], FOCUS, "{res}");
}

#[tokio::test]
async fn origin_arguments_from_a_caller_that_is_no_focus_are_ignored_too() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client("teri").await;

    let res = c
        .enqueue(
            &rig.plan(),
            json!({ "origin_focus": FOCUS, "origin_session": FOCUS_SID, "origin_focus_name": FOCUS_NAME }),
        )
        .await;

    assert_eq!(res["id"], "job1", "{res}");
    let add = rig.the_add();
    assert!(
        !has_origin_flag(&add),
        "a caller cannot claim a focus it is not: {add:?}"
    );
    assert_eq!(
        c.get_job("job1").await["nostromo"]["origin"]["kind"],
        "unknown"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-3  create_focus (mother_job) and Send to agent
// ═════════════════════════════════════════════════════════════════════════════

fn mother_job_args(repo: &Path, item: &str) -> Value {
    json!({
        "agent": "cody", "title": "Queue it", "working_directory": repo,
        "destination": "mother_job", "initial_context": "ctx", "label": "L-1",
        "source_item_id": item, "source_item_title": "Queue it",
    })
}

#[tokio::test]
async fn a_mother_job_queued_by_a_focus_through_create_focus_records_that_focus_via_mcp() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let repo = rig.repo();

    let out = create_focus(
        &rig.state,
        &mother_job_args(&repo, "todo:mf1-a"),
        Some(FOCUS),
    )
    .await;

    assert_eq!(out["kind"], "queued", "{out}");
    assert_eq!(out["job_id"], "job1", "{out}");
    let add = rig.the_add();
    assert_eq!(
        flag(&add, "--label"),
        Some("teri-send"),
        "the label is unchanged: {add:?}"
    );
    assert_eq!(flag(&add, "--origin-session"), Some(FOCUS_SID), "{add:?}");
    assert_eq!(flag(&add, "--origin-focus"), Some(FOCUS), "{add:?}");
    assert_eq!(
        flag(&add, "--origin-focus-name"),
        Some(FOCUS_NAME),
        "{add:?}"
    );
    let entry = rig.book.entry("job1").expect("the book holds the job");
    assert_eq!(entry.kind, OriginKind::Focus);
    assert_eq!(entry.focus_tag.as_deref(), Some(FOCUS));
    assert_eq!(entry.via, Via::Mcp);
    let stamped: Vec<Value> = rig
        .audit()
        .into_iter()
        .filter(|l| l["event"] == "job_origin_stamped")
        .collect();
    assert_eq!(stamped.len(), 1, "{stamped:?}");
    assert_eq!(
        (stamped[0]["focus"].as_str(), stamped[0]["via"].as_str()),
        (Some(FOCUS), Some("mcp"))
    );

    // The feed shows it once the job is listed.
    rig.feed.refresh().await.expect("list");
    let job = rig.client(FOCUS).await.get_job("job1").await;
    assert_eq!(job["nostromo"]["origin"]["kind"], "focus", "{job}");
    assert_eq!(job["nostromo"]["origin"]["focus_tag"], FOCUS, "{job}");
}

#[tokio::test]
async fn an_old_mother_still_takes_a_create_focus_job_from_a_focus() {
    let rig = Rig::new(Mother::Old).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let repo = rig.repo();

    let out = create_focus(
        &rig.state,
        &mother_job_args(&repo, "todo:mf1-old"),
        Some(FOCUS),
    )
    .await;

    assert_eq!(out["kind"], "queued", "{out}");
    let add = rig.the_add();
    assert_eq!(flag(&add, "--origin-session"), Some(FOCUS_SID), "{add:?}");
    assert!(
        !add.iter().any(|a| a.starts_with("--origin-focus")),
        "{add:?}"
    );
    assert_eq!(
        rig.book.entry("job1").map(|e| e.kind),
        Some(OriginKind::Focus)
    );
}

#[tokio::test]
async fn the_apps_send_to_agent_records_you_via_app_and_keeps_the_teri_send_label() {
    let rig = Rig::new(Mother::New).await;
    let repo = rig.repo();

    let out = create_focus_core(
        rig.state.daemon.as_ref().unwrap(),
        CreateFocusRequest {
            agent: "cody".into(),
            title: "Send it".into(),
            label: Some("L-2".into()),
            working_directory: Some(repo),
            initial_context: Some("ctx".into()),
            source_item: Some(SourceItemRef {
                id: "todo:mf1-app".into(),
                title: "Send it".into(),
            }),
            destination: Destination::MotherJob { max_cost: None },
            caller: None,
            queued_by_app: true,
            ..Default::default()
        },
    )
    .await
    .expect("queued");

    assert_eq!(out.kind, OutcomeKind::Queued);
    assert_eq!(out.job_id.as_deref(), Some("job1"));
    let add = rig.the_add();
    assert_eq!(flag(&add, "--label"), Some("teri-send"), "{add:?}");
    assert!(
        !has_origin_flag(&add),
        "the user has no session to name: {add:?}"
    );
    let entry = rig.book.entry("job1").expect("the book holds the job");
    assert_eq!((entry.kind, entry.via), (OriginKind::You, Via::App));
    assert_eq!(entry.focus_tag, None);
    let stamped: Vec<Value> = rig
        .audit()
        .into_iter()
        .filter(|l| l["event"] == "job_origin_stamped")
        .collect();
    assert_eq!(stamped.len(), 1, "{stamped:?}");
    assert_eq!(stamped[0]["via"], "app");
    assert!(
        stamped[0].get("focus").is_none(),
        "the app has no focus: {}",
        stamped[0]
    );

    rig.feed.refresh().await.expect("list");
    let job = rig.client("teri").await.get_job("job1").await;
    assert_eq!(job["nostromo"]["origin"]["kind"], "you", "{job}");
}

#[tokio::test]
async fn a_create_focus_job_from_a_caller_the_daemon_does_not_know_records_nothing_and_passes_no_origin_flags(
) {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let repo = rig.repo();

    let out = create_focus(
        &rig.state,
        &mother_job_args(&repo, "todo:mf1-ghost"),
        Some("ghost-1"),
    )
    .await;

    assert_eq!(out["kind"], "queued", "{out}");
    let add = rig.the_add();
    assert!(!has_origin_flag(&add), "{add:?}");
    assert_eq!(flag(&add, "--label"), Some("teri-send"), "{add:?}");
    assert!(rig.book.entry("job1").is_none(), "nothing was stamped");
    assert!(rig.audit().is_empty(), "{:?}", rig.audit());
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-5  evaluating a claim in the job feed
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_claim_whose_session_is_in_the_focus_history_is_a_focus_vouched_for_via_shell() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    let claim = json!({ "focus": FOCUS, "session": FOCUS_SID, "focus_name": FOCUS_NAME });

    let published = r.feed.publish_jobs(vec![job("j1", Some(claim))]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.kind, OriginKind::Focus);
    assert_eq!(origin.focus_tag.as_deref(), Some(FOCUS));
    assert_eq!(origin.session_prefix.as_deref(), Some("5f3c9a10"));
    assert_eq!(r.book.entry("j1").map(|e| e.via), Some(Via::Shell));
    assert_eq!(r.unverified_audits_of("j1"), 0);
}

#[test]
fn a_claim_with_another_missing_or_empty_session_is_unverified_and_audited_once() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    // The session is a real one of ANOTHER focus: still not this focus's.
    r.history
        .record("claudia-BBBB2222", "abababab-1111-2222-3333-444444444444");
    let cases = [
        ("other-session", claim(FOCUS, "not-a-session-of-this-focus")),
        ("empty-session", claim(FOCUS, "")),
        ("no-session", json!({ "focus": FOCUS })),
        (
            "session-of-another-focus",
            claim(FOCUS, "abababab-1111-2222-3333-444444444444"),
        ),
    ];
    for (id, origin) in &cases {
        let list = vec![job(id, Some(origin.clone()))];
        // The same list is polled over and over.
        for _ in 0..5 {
            let published = r.feed.publish_jobs(list.clone());
            assert_eq!(kind_of(&published[0]), OriginKind::Unverified, "{id}");
        }
        assert_eq!(
            r.unverified_audits_of(id),
            1,
            "{id}: audited once, not per poll"
        );
    }
    let lines = r.audit();
    let first = lines.iter().find(|l| l["job"] == "other-session").unwrap();
    assert_eq!(first["claimed_focus"], FOCUS);
}

#[test]
fn an_unverified_claim_stays_unverified_even_when_the_forged_session_later_enters_the_history() {
    let r = feed_rig();
    let forged = "forged-session-id-0000";
    let list = vec![job("j1", Some(claim(FOCUS, forged)))];
    assert_eq!(
        kind_of(&r.feed.publish_jobs(list.clone())[0]),
        OriginKind::Unverified
    );

    r.history.record(FOCUS, forged);

    assert_eq!(
        kind_of(&r.feed.publish_jobs(list.clone())[0]),
        OriginKind::Unverified
    );
    // Not even through the other publish paths.
    let ticket = r.feed.begin();
    assert!(r.feed.publish_jobs_at(ticket, list.clone()));
    assert_eq!(
        kind_of(&r.feed.jobs_rx().borrow()[0]),
        OriginKind::Unverified
    );
    assert_eq!(r.unverified_audits_of("j1"), 1);
}

#[test]
fn a_record_that_makes_no_claim_is_unknown_and_is_not_audited() {
    let r = feed_rig();

    let published = r.feed.publish_jobs(vec![
        job("bare", None),
        job("label-only", Some(json!({ "label": "nightly" }))),
        job("blank-focus", Some(json!({ "focus": "  " }))),
    ]);

    for j in &published {
        let origin = &j.nostromo.as_ref().unwrap().origin;
        assert_eq!(origin.kind, OriginKind::Unknown, "{}", j.id);
        assert_eq!(origin.focus_tag, None, "{}", j.id);
    }
    assert!(r.audit().is_empty(), "{:?}", r.audit());
}

#[test]
fn a_later_stamp_upgrades_an_unknown_or_unverified_job_to_focus() {
    let r = feed_rig();
    let list = vec![
        job("was-unknown", None),
        job("was-unverified", Some(claim(FOCUS, "forged"))),
    ];
    let before = r.feed.publish_jobs(list.clone());
    assert_eq!(kind_of(&before[0]), OriginKind::Unknown);
    assert_eq!(kind_of(&before[1]), OriginKind::Unverified);

    for id in ["was-unknown", "was-unverified"] {
        assert!(
            r.book.stamp(
                id,
                Stamp::focus(
                    "claudia-CCCC3333",
                    Some("The real one"),
                    Some("cccccccc-0000"),
                    Via::Mcp,
                    None
                )
            ),
            "{id}: the stamp is written"
        );
    }

    let after = r.feed.publish_jobs(list);
    for j in &after {
        let origin = &j.nostromo.as_ref().unwrap().origin;
        assert_eq!(origin.kind, OriginKind::Focus, "{}", j.id);
        assert_eq!(
            origin.focus_tag.as_deref(),
            Some("claudia-CCCC3333"),
            "{}",
            j.id
        );
        assert_eq!(
            origin.session_prefix.as_deref(),
            Some("cccccccc"),
            "{}",
            j.id
        );
    }
}

#[test]
fn nothing_downgrades_a_focus_or_a_you_job() {
    let r = feed_rig();
    assert!(r.book.stamp(
        "mine",
        Stamp::focus(FOCUS, Some(FOCUS_NAME), Some(FOCUS_SID), Via::Mcp, None)
    ));
    assert!(r.book.stamp("yours", Stamp::you(None)));

    // Another focus, "you", or a record that claims somebody else.
    assert!(!r.book.stamp(
        "mine",
        Stamp::focus("claudia-OTHER000", None, None, Via::Mcp, None)
    ));
    assert!(!r.book.stamp("mine", Stamp::you(None)));
    assert!(!r
        .book
        .stamp("yours", Stamp::focus(FOCUS, None, None, Via::Mcp, None)));
    let published = r.feed.publish_jobs(vec![
        job("mine", Some(claim("claudia-OTHER000", "forged"))),
        job("yours", Some(claim(FOCUS, "forged"))),
    ]);

    let mine = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(
        (mine.kind, mine.focus_tag.as_deref()),
        (OriginKind::Focus, Some(FOCUS))
    );
    let yours = &published[1].nostromo.as_ref().unwrap().origin;
    assert_eq!(
        (yours.kind, yours.focus_tag.as_deref()),
        (OriginKind::You, None)
    );
}

#[test]
fn a_record_that_carries_its_own_nostromo_key_cannot_vouch_for_itself() {
    let r = feed_rig();
    let forged: MotherJob = serde_json::from_value(json!({
        "id": "j1", "state": "queued", "title": "t",
        "nostromo": { "origin": { "kind": "focus", "focus_tag": "claudia-FORGED00", "name_snapshot": "Forged" } },
    }))
    .expect("a job record with a stray nostromo key still reads");

    let published = r.feed.publish_jobs(vec![forged]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.kind, OriginKind::Unknown);
    assert_eq!(origin.focus_tag, None);
    assert_eq!(origin.name_snapshot, None);
}

#[test]
fn a_claimed_tag_that_is_not_a_tag_never_reaches_the_wire_or_the_audit_file() {
    let r = feed_rig();

    let published = r.feed.publish_jobs(vec![job(
        "j1",
        Some(claim("<script>alert('x')</script> not a tag", "sid")),
    )]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.kind, OriginKind::Unverified);
    assert_eq!(origin.focus_tag, None);
    let wire = serde_json::to_string(&published).unwrap();
    assert!(!wire.contains("script"), "{wire}");
    let audit = std::fs::read_to_string(&r.audit_path).unwrap_or_default();
    assert!(!audit.contains("script"), "{audit}");
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-6  every reader of the feed sees the origin; the claim stays private
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn every_publish_path_of_the_feed_annotates_every_job() {
    let r = feed_rig();
    let list = || vec![job("a", None), job("b", Some(claim(FOCUS, "forged")))];
    let annotated = |jobs: &[MotherJob]| {
        assert_eq!(jobs.len(), 2);
        assert!(jobs.iter().all(|j| j.nostromo.is_some()), "{jobs:?}");
    };

    annotated(&r.feed.publish_jobs(list()));
    annotated(&r.feed.jobs_rx().borrow());

    let t = r.feed.begin();
    assert!(r.feed.publish_jobs_at(t, list()));
    annotated(&r.feed.jobs_rx().borrow());

    let t = r.feed.begin();
    assert!(r.feed.publish_jobs_counted_at(t, list(), 0));
    annotated(&r.feed.jobs_rx().borrow());

    let t = r.feed.begin();
    let published = r
        .feed
        .publish_annotated_at(t, list(), 0)
        .expect("the newest ticket");
    annotated(&published);
    annotated(&r.feed.jobs_rx().borrow());

    // A ticket a newer list has overtaken publishes nothing at all.
    let stale = r.feed.begin();
    let newer = r.feed.begin();
    assert!(r.feed.publish_annotated_at(newer, list(), 0).is_some());
    assert!(r.feed.publish_annotated_at(stale, list(), 0).is_none());
}

#[tokio::test]
async fn a_refresh_publishes_and_returns_annotated_jobs() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    rig.client(FOCUS)
        .await
        .enqueue(&rig.plan(), json!({}))
        .await;
    rig.client("teri")
        .await
        .enqueue(&rig.plan_named("plan-2.md"), json!({}))
        .await;

    let listed = rig.feed.refresh().await.expect("list");

    assert_eq!(listed.len(), 2);
    assert!(listed.iter().all(|j| j.nostromo.is_some()), "{listed:?}");
    assert_eq!(kind_of(&listed[0]), OriginKind::Focus);
    assert_eq!(kind_of(&listed[1]), OriginKind::Unknown);
    assert!(rig
        .feed
        .jobs_rx()
        .borrow()
        .iter()
        .all(|j| j.nostromo.is_some()));
}

#[tokio::test]
async fn list_jobs_and_get_job_carry_the_origin_of_every_job() {
    let rig = Rig::new(Mother::New).await;
    rig.history.record(FOCUS, FOCUS_SID);
    assert!(rig.book.stamp("mine", Stamp::you(None)));
    rig.feed.publish_jobs(vec![
        job("verified", Some(claim(FOCUS, FOCUS_SID))),
        job("forged", Some(claim(FOCUS, "forged"))),
        job("anon", None),
        job("mine", None),
    ]);
    let mut c = rig.client("teri").await;

    let listed = c.call("mother.list_jobs", json!({})).await;

    let kinds: Vec<(String, String)> = listed
        .as_array()
        .expect("a list")
        .iter()
        .map(|j| {
            (
                j["id"].as_str().unwrap().to_owned(),
                j["nostromo"]["origin"]["kind"]
                    .as_str()
                    .unwrap_or_else(|| panic!("no origin kind on {j}"))
                    .to_owned(),
            )
        })
        .collect();
    let expected: Vec<(String, String)> = [
        ("verified", "focus"),
        ("forged", "unverified"),
        ("anon", "unknown"),
        ("mine", "you"),
    ]
    .iter()
    .map(|(a, b)| (a.to_string(), b.to_string()))
    .collect();
    assert_eq!(kinds, expected);
    for (id, kind) in &kinds {
        let one = c.get_job(id).await;
        assert_eq!(
            one["nostromo"]["origin"]["kind"],
            kind.as_str(),
            "{id}: {one}"
        );
    }
}

#[test]
fn the_names_shown_are_the_registrys_current_sanitised_and_capped() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    let list = vec![job("j1", Some(claim(FOCUS, FOCUS_SID)))];
    r.book.note_registry_push(&[focus_meta(FOCUS, FOCUS_NAME)]);
    let first = r.feed.publish_jobs(list.clone());
    let origin = &first[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.focus_name.as_deref(), Some(FOCUS_NAME));

    // The focus is renamed to something hostile and long.
    let hostile = format!("Pay\u{202e}roll\u{200b} fix{}", "x".repeat(300));
    r.book.note_registry_push(&[focus_meta(FOCUS, &hostile)]);
    let second = r.feed.publish_jobs(list);

    let origin = &second[0].nostromo.as_ref().unwrap().origin;
    let name = origin.focus_name.as_deref().expect("a current name");
    assert!(
        !name.contains('\u{202e}') && !name.contains('\u{200b}'),
        "{name:?}"
    );
    assert!(name.starts_with("Payroll fix"), "{name:?}");
    assert!(
        name.chars().count() <= 120,
        "{} chars",
        name.chars().count()
    );
    assert!(name.ends_with('…'), "a capped name says so: {name:?}");
    assert_eq!(
        origin.name_snapshot.as_deref(),
        Some(FOCUS_NAME),
        "the snapshot is the name when it was decided"
    );
}

#[test]
fn a_name_snapshot_is_sanitised_and_capped_too() {
    let r = feed_rig();
    let hostile = format!("Ba\u{202e}d\u{200b} name{}", "y".repeat(300));

    assert!(r.book.stamp(
        "j1",
        Stamp::focus(FOCUS, Some(hostile.as_str()), None, Via::Mcp, None)
    ));
    let published = r.feed.publish_jobs(vec![job("j1", None)]);

    let snapshot = published[0]
        .nostromo
        .as_ref()
        .unwrap()
        .origin
        .name_snapshot
        .clone()
        .expect("a snapshot");
    assert!(
        !snapshot.contains('\u{202e}') && !snapshot.contains('\u{200b}'),
        "{snapshot:?}"
    );
    assert!(
        snapshot.chars().count() <= 120 && snapshot.ends_with('…'),
        "{snapshot:?}"
    );
}

#[test]
fn closed_is_absent_before_a_registry_push_and_true_only_after_a_non_empty_push_without_the_tag() {
    let r = feed_rig();
    assert!(r.book.stamp(
        "j1",
        Stamp::focus("gone-focus", Some("Old name"), None, Via::Mcp, None)
    ));
    let origin = |feed: &JobsFeed| -> OriginView {
        feed.publish_jobs(vec![job("j1", None)])[0]
            .nostromo
            .clone()
            .unwrap()
            .origin
    };

    assert_eq!(origin(&r.feed).closed, None, "no registry push yet");

    // A registry that changed without a push is no evidence either.
    r.book.note_registry_update(&[focus_meta("other", "Other")]);
    assert_eq!(origin(&r.feed).closed, None);

    r.book.note_registry_push(&[focus_meta("other", "Other")]);
    let closed = origin(&r.feed);
    assert_eq!(closed.closed, Some(true));
    assert_eq!(
        closed.focus_name, None,
        "a closed focus has no current name"
    );
    assert_eq!(closed.name_snapshot.as_deref(), Some("Old name"));

    // An empty push is what a client sends before it has loaded anything.
    r.book.note_registry_push(&[]);
    assert_eq!(origin(&r.feed).closed, None);

    r.book
        .note_registry_push(&[focus_meta("gone-focus", "New name")]);
    let back = origin(&r.feed);
    assert_eq!(back.closed, Some(false));
    assert_eq!(back.focus_name.as_deref(), Some("New name"));
    assert_eq!(back.name_snapshot.as_deref(), Some("Old name"));
}

#[tokio::test]
async fn the_session_managers_registry_feeds_closed_and_the_current_name() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;
    c.enqueue(&rig.plan(), json!({})).await;
    let origin = |job: &Value| job["nostromo"]["origin"].clone();

    // The daemon created the focus: no push yet, so nothing says it is open or closed.
    assert!(origin(&c.get_job("job1").await).get("closed").is_none());

    // The Mac pushes a registry that names it.
    rig.push_registry(vec![
        focus_meta(FOCUS, "Renamed in the app"),
        focus_meta("claudia-OTHER000", "Other"),
    ]);
    rig.feed.refresh().await.unwrap();
    let o = origin(&c.get_job("job1").await);
    assert_eq!(o["closed"], false, "{o}");
    assert_eq!(o["focus_name"], "Renamed in the app", "{o}");
    assert_eq!(
        o["name_snapshot"], FOCUS_NAME,
        "the snapshot is the name at enqueue: {o}"
    );

    // One push that lacks it is not enough: a client can push a partial
    // registry (the session manager waits for a second push before it believes
    // a focus is gone), so the job still says the focus is open.
    rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
    rig.feed.refresh().await.unwrap();
    let o = origin(&c.get_job("job1").await);
    assert_eq!(
        o["closed"], false,
        "one push without the tag is not a close: {o}"
    );

    // A push that names it again starts the count over: lacking it once more
    // is, again, not a close.
    rig.push_registry(vec![
        focus_meta(FOCUS, "Renamed in the app"),
        focus_meta("claudia-OTHER000", "Other"),
    ]);
    rig.feed.refresh().await.unwrap();
    assert_eq!(origin(&c.get_job("job1").await)["closed"], false);
    rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
    rig.feed.refresh().await.unwrap();
    let o = origin(&c.get_job("job1").await);
    assert_eq!(
        o["closed"], false,
        "a push that named it in between reset the count: {o}"
    );

    // A second consecutive push without it: the focus is closed.
    rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
    rig.feed.refresh().await.unwrap();
    let o = origin(&c.get_job("job1").await);
    assert_eq!(o["closed"], true, "{o}");
    assert!(o.get("focus_name").is_none(), "{o}");
    assert_eq!(o["name_snapshot"], FOCUS_NAME, "{o}");

    // An empty push says nothing about what exists.
    rig.push_registry(vec![]);
    rig.feed.refresh().await.unwrap();
    assert!(origin(&c.get_job("job1").await).get("closed").is_none());
}

#[test]
fn the_serialised_job_never_carries_the_raw_claim_and_keeps_the_label() {
    let r = feed_rig();
    r.history.record(FOCUS, "VERIFIED-SESSION-SECRETREST-1111");
    let record = |focus: &str, session: &str| {
        json!({
            "label": "my-label",
            "focus": focus,
            "session": session,
            "focus_name": "SENTINEL-CLAIMED-NAME",
        })
    };

    let published = r.feed.publish_jobs(vec![
        job(
            "verified",
            Some(record(FOCUS, "VERIFIED-SESSION-SECRETREST-1111")),
        ),
        job(
            "forged",
            Some(record(FOCUS, "FORGED-SESSION-SECRETREST-2222")),
        ),
    ]);

    let wire = serde_json::to_string(&published).unwrap();
    assert!(
        !wire.contains("SECRETREST"),
        "no session id beyond its prefix: {wire}"
    );
    for (i, v) in serde_json::to_value(&published)
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        assert_eq!(
            v["origin"],
            json!({ "label": "my-label" }),
            "job {i}: origin.session, origin.focus and origin.focus_name stay in the daemon"
        );
    }
}

#[test]
fn a_job_without_any_claim_serialises_its_origin_label_exactly_as_before() {
    let r = feed_rig();

    let published = r
        .feed
        .publish_jobs(vec![job("j1", Some(json!({ "label": "teri-send" })))]);

    let v = serde_json::to_value(&published[0]).unwrap();
    assert_eq!(v["origin"], json!({ "label": "teri-send" }));
    assert!(published[0].is_work_send());
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-10  notify
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn notify_accepts_wake_quiet_and_off_and_shows_in_the_jobs_annotation() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    for (n, level) in ["wake", "quiet", "off"].into_iter().enumerate() {
        let res = c.enqueue(&rig.plan(), json!({ "notify": level })).await;
        let id = format!("job{}", n + 1);
        assert_eq!(res["id"], id.as_str(), "{level}: {res}");
        let job = c.get_job(&id).await;
        assert_eq!(job["nostromo"]["notify"], level, "{level}: {job}");
        assert_eq!(job["nostromo"]["origin"]["kind"], "focus", "{level}: {job}");
    }
    let entry = rig.book.entry("job3").unwrap();
    assert_eq!(entry.notify, Some(NotifyLevel::Off));
}

#[tokio::test]
async fn a_job_enqueued_without_notify_has_no_notify_in_its_annotation() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    c.enqueue(&rig.plan(), json!({})).await;

    let job = c.get_job("job1").await;
    assert!(job["nostromo"].get("notify").is_none(), "{job}");
}

#[tokio::test]
async fn any_other_notify_value_is_invalid_args_and_mother_add_never_runs() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;

    for bad in [
        json!("WAKE"),
        json!("Quiet"),
        json!("loud"),
        json!(""),
        json!(" wake"),
        json!(1),
        json!(0),
        json!(true),
        json!(["wake"]),
        json!({"level": "wake"}),
    ] {
        let res = c
            .enqueue(&rig.plan(), json!({ "notify": bad.clone() }))
            .await;
        assert_eq!(res["error"], "invalid_args", "notify {bad}: {res}");
        assert!(res.get("id").is_none(), "notify {bad}: {res}");
    }

    assert!(
        rig.adds().is_empty(),
        "no job was queued: {:?}",
        rig.calls()
    );
    assert!(rig.book.entry("job1").is_none());
}

// ═════════════════════════════════════════════════════════════════════════════
// persistence
// ═════════════════════════════════════════════════════════════════════════════

fn mode_of(p: &Path) -> u32 {
    std::fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn the_book_and_the_history_are_private_files_that_survive_a_reopen() {
    let dir = TempDir::new().unwrap();
    let store = dir.path().join("daemon-sessions.json");
    let history_path = SessionHistory::path_beside(&store);
    let book_path = OriginBook::path_beside(&store);
    assert_eq!(
        history_path.file_name().unwrap(),
        "focus-session-history.json"
    );
    assert_eq!(history_path.parent(), store.parent());
    assert_eq!(book_path.parent(), store.parent());

    {
        let history = SessionHistory::open(history_path.clone());
        history.record(FOCUS, FOCUS_SID);
        let book = OriginBook::open(book_path.clone(), history, MotherAudit::disabled());
        assert!(book.stamp(
            "job1",
            Stamp::focus(
                FOCUS,
                Some(FOCUS_NAME),
                Some(FOCUS_SID),
                Via::Mcp,
                Some(NotifyLevel::Quiet)
            )
        ));
    }

    assert_eq!(mode_of(&history_path), 0o600, "history file mode");
    assert_eq!(mode_of(&book_path), 0o600, "book file mode");

    let history = SessionHistory::open(history_path);
    assert!(history.contains(FOCUS, FOCUS_SID));
    assert!(!history.contains("claudia-OTHER000", FOCUS_SID), "per tag");
    let book = OriginBook::open(book_path, history.clone(), MotherAudit::disabled());
    let entry = book.entry("job1").expect("the entry survives");
    assert_eq!(entry.kind, OriginKind::Focus);
    assert_eq!(entry.focus_tag.as_deref(), Some(FOCUS));
    assert_eq!(entry.name_snapshot.as_deref(), Some(FOCUS_NAME));
    assert_eq!(entry.session_prefix.as_deref(), Some("5f3c9a10"));
    assert_eq!(entry.notify, Some(NotifyLevel::Quiet));
    // And the reopened pair still vouches for a claim.
    let feed = JobsFeed::new().with_origins(book);
    let published = feed.publish_jobs(vec![job("job2", Some(claim(FOCUS, FOCUS_SID)))]);
    assert_eq!(kind_of(&published[0]), OriginKind::Focus);
}

#[test]
fn the_history_keeps_the_newest_64_sessions_per_tag_and_that_survives_a_reopen() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("history.json");
    {
        let h = SessionHistory::open(path.clone());
        for i in 0..70 {
            h.record_at("busy", &format!("s{i}"), 1_000 + i);
        }
        h.record_at("quiet", "only", 1_000);
    }

    for h in [
        SessionHistory::open(path.clone()),
        SessionHistory::open(path),
    ] {
        for i in 0..6 {
            assert!(
                !h.contains("busy", &format!("s{i}")),
                "s{i} is among the oldest 6"
            );
        }
        for i in 6..70 {
            assert!(
                h.contains("busy", &format!("s{i}")),
                "s{i} is among the newest 64"
            );
        }
        assert!(h.contains("quiet", "only"), "another tag keeps its own");
    }
}

#[test]
fn recording_the_same_session_again_is_not_a_second_entry() {
    let h = SessionHistory::in_memory();
    for _ in 0..200 {
        h.record_at("t", "same", 5);
    }
    h.record_at("t", "other", 6);
    assert!(h.contains("t", "same") && h.contains("t", "other"));
    assert!(
        !h.contains("t", ""),
        "an empty session is never in the history"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-8  audit
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn audit_lines_carry_the_job_the_tag_and_how_and_nothing_else() {
    let r = feed_rig();
    assert!(r.book.stamp(
        "job-focus",
        Stamp::focus(
            FOCUS,
            Some("A name that must not be audited"),
            Some("sessionid-that-must-not-be-audited"),
            Via::Mcp,
            Some(NotifyLevel::Wake),
        )
    ));
    assert!(r.book.stamp("job-you", Stamp::you(None)));
    r.feed.publish_jobs(vec![job(
        "job-forged",
        Some(json!({
            "focus": "claudia-BBBB2222",
            "session": "forged-session-that-must-not-be-audited",
            "focus_name": "A claimed name that must not be audited",
        })),
    )]);

    let lines = r.audit();

    assert_eq!(lines.len(), 3, "{lines:?}");
    let focus = &lines[0];
    assert_eq!(
        keys(focus),
        key_set(&["event", "ts", "job", "focus", "via"]),
        "{focus}"
    );
    assert_eq!(focus["event"], "job_origin_stamped");
    assert_eq!(
        (
            focus["job"].as_str(),
            focus["focus"].as_str(),
            focus["via"].as_str()
        ),
        (Some("job-focus"), Some(FOCUS), Some("mcp"))
    );
    let you = &lines[1];
    assert_eq!(keys(you), key_set(&["event", "ts", "job", "via"]), "{you}");
    assert_eq!(
        (
            you["event"].as_str(),
            you["job"].as_str(),
            you["via"].as_str()
        ),
        (Some("job_origin_stamped"), Some("job-you"), Some("app"))
    );
    let forged = &lines[2];
    assert_eq!(
        keys(forged),
        key_set(&["event", "ts", "job", "claimed_focus"]),
        "{forged}"
    );
    assert_eq!(forged["event"], "job_origin_unverified");
    assert_eq!(
        (forged["job"].as_str(), forged["claimed_focus"].as_str()),
        (Some("job-forged"), Some("claudia-BBBB2222"))
    );
    for line in &lines {
        let ts = line["ts"].as_str().expect("a timestamp");
        chrono::DateTime::parse_from_rfc3339(ts).unwrap_or_else(|e| panic!("ts {ts:?}: {e}"));
    }
}

#[test]
fn the_audit_file_is_private_in_a_private_directory() {
    let r = feed_rig();
    assert!(r.book.stamp("j1", Stamp::you(None)));

    let dir = r.audit_path.parent().unwrap();
    assert_eq!(mode_of(dir), 0o700, "audit directory mode");
    assert_eq!(mode_of(&r.audit_path), 0o600, "audit file mode");
}

// ── the canary: no content in logs or the audit file ─────────────────────────

#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl io::Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl LogBuf {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

/// Everything this process logs, at every level, from the first call on.
///
/// A global default rather than `set_default`: a thread-scoped subscriber loses
/// events whenever a parallel test thread has already registered the same
/// callsite with no subscriber (tracing caches that interest per callsite), so
/// the capture would be flaky. The canary strings below are unique to the one
/// test that looks for them, so other tests' output cannot interfere.
fn captured_logs() -> &'static LogBuf {
    static LOGS: std::sync::OnceLock<LogBuf> = std::sync::OnceLock::new();
    LOGS.get_or_init(|| {
        let buf = LogBuf::default();
        let sink = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .with_writer(move || sink.clone())
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other global tracing subscriber in this test binary");
        buf
    })
}

#[tokio::test(flavor = "current_thread")]
async fn no_title_name_session_or_plan_path_reaches_the_logs_or_the_audit_file() {
    const TITLE: &str = "CANARY-JOB-TITLE-88";
    const NAME: &str = "CANARY-FOCUS-NAME-77";
    const CLAIMED_NAME: &str = "CANARY-CLAIMED-NAME-55";
    // The first eight characters are what the annotation legitimately shows.
    const SID: &str = "CNRYSESS-1111-2222-3333";
    const FORGED_SID: &str = "CNRYFORG-4444-5555-6666";
    const PLAN: &str = "plan-CANARY-PLANPATH-99.md";
    let logs = captured_logs();

    let rig = Rig::new(Mother::New).await;
    std::fs::write(rig.mother_dir.join("title"), TITLE).unwrap();
    rig.add_focus(FOCUS, NAME, SID);
    let mut c = rig.client(FOCUS).await;

    // The stamp path: an enqueue from a focus, then every way of reading the job.
    let res = c
        .enqueue(&rig.plan_named(PLAN), json!({ "notify": "quiet" }))
        .await;
    assert_eq!(res["id"], "job1", "{res}");
    let fetched = c.get_job("job1").await;
    assert_eq!(fetched["nostromo"]["origin"]["kind"], "focus", "{fetched}");
    assert_eq!(
        fetched["title"], TITLE,
        "the canary title is on the job itself"
    );
    c.call("mother.list_jobs", json!({})).await;
    // The Mac pushes a registry (the focus is renamed, then gone).
    rig.push_registry(vec![
        focus_meta(FOCUS, NAME),
        focus_meta("claudia-OTHER000", "Other"),
    ]);
    rig.feed.refresh().await.unwrap();
    rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
    rig.feed.refresh().await.unwrap();

    // The evaluate path: a verified claim and a forged one.
    rig.history.record("claudia-BBBB2222", "bbbbbbbb-0000");
    let claimed = |id: &str, focus: &str, session: &str| {
        let mut j = job(
            id,
            Some(json!({ "focus": focus, "session": session, "focus_name": CLAIMED_NAME })),
        );
        j.title = TITLE.into();
        j
    };
    let verified = claimed("shell-verified", "claudia-BBBB2222", "bbbbbbbb-0000");
    let forged = claimed("shell-forged", "claudia-BBBB2222", FORGED_SID);
    for _ in 0..3 {
        rig.feed
            .publish_jobs(vec![verified.clone(), forged.clone()]);
    }
    assert_eq!(kind_of(&rig.feed.jobs_rx().borrow()[0]), OriginKind::Focus);

    let log_text = logs.text();
    let audit_text = std::fs::read_to_string(&rig.audit_path).unwrap_or_default();
    let book_text =
        std::fs::read_to_string(OriginBook::path_beside(&rig.store_path)).unwrap_or_default();

    assert!(
        log_text.contains("MCP server listening"),
        "the capture is live (it saw the server start): {log_text}"
    );
    assert!(
        audit_text.contains("job_origin_stamped"),
        "the stamp was audited: {audit_text}"
    );
    assert!(
        audit_text.contains("job_origin_unverified"),
        "the forgery was audited: {audit_text}"
    );
    for (what, canary) in [
        ("job title", TITLE),
        ("focus name", NAME),
        ("claimed focus name", CLAIMED_NAME),
        ("session id", "CNRYSESS"),
        ("forged session id", "CNRYFORG"),
        ("plan path", "CANARY-PLANPATH"),
    ] {
        assert!(
            !log_text.contains(canary),
            "the {what} reached the logs:\n{log_text}"
        );
        assert!(
            !audit_text.contains(canary),
            "the {what} reached the audit file:\n{audit_text}"
        );
    }
    // The book keeps the name and the 8-character prefix, nothing more of these.
    for (what, canary) in [
        ("job title", TITLE),
        ("rest of the session id", "1111-2222-3333"),
        ("rest of the forged session id", "4444-5555-6666"),
        ("plan path", "CANARY-PLANPATH"),
    ] {
        assert!(
            !book_text.contains(canary),
            "the {what} reached the book:\n{book_text}"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MF1-9  the golden `MotherJobs` frame the Kit decodes
// ═════════════════════════════════════════════════════════════════════════════

fn golden_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/mother-v2/mother-jobs-annotated.json")
}

/// A notice record that says the focus was told (serialises as
/// `{"status":"told"}`).
fn told_notice() -> nostromo::mother::notices::NoticeView {
    nostromo::mother::notices::NoticeView {
        status: nostromo::mother::notices::NoticeStatus::Told,
        ..Default::default()
    }
}

fn annotated(id: &str, title: &str, state: &str, annotation: Option<JobAnnotation>) -> MotherJob {
    let mut j: MotherJob = serde_json::from_value(json!({
        "id": id,
        "title": title,
        "state": state,
        "repo": "nostromo",
        "isolation": "worktree",
        "created_at": "2026-10-20T15:00:00Z",
        "origin": { "label": "nightly" },
    }))
    .expect("a mother job");
    j.nostromo = annotation;
    j
}

/// The frame the daemon broadcasts for five annotated jobs (every origin kind
/// Rust can write, plus an origin kind from a future daemon that it cannot) and
/// two jobs whose annotation is malformed. Built as JSON so the hand-written
/// jobs sit beside the serialised ones; keys come out in `serde_json`'s order.
fn golden_frame() -> String {
    let focus = annotated(
        "j-focus",
        "Fix the login flow",
        "running",
        Some(JobAnnotation {
            origin: OriginView {
                kind: OriginKind::Focus,
                focus_tag: Some("claudia-C9D6B773".into()),
                name_snapshot: Some("Fix login".into()),
                focus_name: Some("Fix the login flow".into()),
                closed: Some(false),
                session_prefix: Some("5f3c9a10".into()),
            },
            notify: Some(NotifyLevel::Quiet),
            notice: Some(told_notice()),
        }),
    );
    let unverified = annotated(
        "j-unverified",
        "Claims a focus",
        "queued",
        Some(JobAnnotation {
            origin: OriginView {
                kind: OriginKind::Unverified,
                focus_tag: Some("claudia-D00DFEED".into()),
                name_snapshot: Some("Claimed name".into()),
                focus_name: None,
                closed: None,
                session_prefix: None,
            },
            notify: None,
            notice: None,
        }),
    );
    let you = annotated(
        "j-you",
        "Sent from the app",
        "awaiting",
        Some(JobAnnotation {
            origin: OriginView {
                kind: OriginKind::You,
                focus_tag: None,
                name_snapshot: None,
                focus_name: None,
                closed: None,
                session_prefix: None,
            },
            notify: Some(NotifyLevel::Off),
            notice: None,
        }),
    );
    let unknown = annotated(
        "j-unknown",
        "Queued from a shell",
        "succeeded",
        Some(JobAnnotation::default()),
    );

    let mut frame = serde_json::to_value(ServerMsg::MotherJobs {
        jobs: vec![focus, unverified, you, unknown],
    })
    .expect("serialise the frame");
    assert_eq!(frame["type"], "mother_jobs", "the frame's tag");
    let jobs = frame["jobs"].as_array_mut().expect("jobs");
    // Hand-written: Rust cannot produce an origin kind it does not know, and a
    // malformed annotation is what a buggy or newer daemon could send.
    let template = jobs[3].clone();
    let with = |id: &str, title: &str, nostromo: Value| {
        let mut j = template.clone();
        j["id"] = json!(id);
        j["title"] = json!(title);
        j["nostromo"] = nostromo;
        j
    };
    jobs.push(with(
        "j-robot",
        "From a future daemon",
        json!({
            "origin": {
                "kind": "robot",
                "focus_tag": "claudia-CAFE0001",
                "name_snapshot": "Future focus",
                "focus_name": "Future focus",
            },
            "notify": "wake",
        }),
    ));
    jobs.push(with(
        "j-bad-string",
        "Annotation is a string",
        json!("oops"),
    ));
    jobs.push(with(
        "j-bad-origin",
        "Origin is a number",
        json!({ "origin": 7, "notify": "wake" }),
    ));

    serde_json::to_string_pretty(&frame).expect("print the frame")
}

#[test]
fn the_annotated_mother_jobs_frame_matches_the_golden_the_kit_decodes() {
    let path = golden_path();
    let frame = golden_frame();

    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().unwrap()).expect("create the fixture directory");
        std::fs::write(&path, &frame).expect("write golden");
        return;
    }

    let golden = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e} (UPDATE_GOLDEN=1 to create)", path.display()));
    assert_eq!(
        frame, golden,
        "the annotated MotherJobs wire form changed; the Kit decodes this file, regenerate with UPDATE_GOLDEN=1 only if intended"
    );
}

#[test]
fn the_golden_is_a_mother_jobs_frame_with_every_kind_a_malformed_annotation_and_a_notify() {
    // Independent of the comparison above: what the Kit tests rely on.
    let frame: Value = serde_json::from_str(&golden_frame()).unwrap();
    assert_eq!(frame["type"], "mother_jobs");
    let jobs = frame["jobs"].as_array().unwrap();
    let kind = |id: &str| {
        jobs.iter()
            .find(|j| j["id"] == id)
            .unwrap_or_else(|| panic!("{id} is in the golden"))["nostromo"]["origin"]["kind"]
            .clone()
    };
    assert_eq!(kind("j-focus"), "focus");
    assert_eq!(kind("j-unverified"), "unverified");
    assert_eq!(kind("j-you"), "you");
    assert_eq!(kind("j-unknown"), "unknown");
    assert_eq!(kind("j-robot"), "robot");
    assert!(jobs.iter().any(|j| j["nostromo"] == "oops"));
    assert!(jobs.iter().any(|j| j["nostromo"]["origin"] == 7));
    assert!(jobs.iter().any(|j| j["nostromo"]["notify"].is_string()));
}

// ═════════════════════════════════════════════════════════════════════════════
// review fix-ups
// ═════════════════════════════════════════════════════════════════════════════

// ── the registry push debounce ───────────────────────────────────────────────

#[tokio::test]
async fn a_focus_the_daemon_created_that_the_app_has_not_acknowledged_is_never_reported_closed() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let mut c = rig.client(FOCUS).await;
    c.enqueue(&rig.plan(), json!({})).await;

    // The app's pushes do not know the focus yet (it may not have heard of it):
    // no number of them says it is gone.
    for push in 1..=4 {
        rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
        rig.feed.refresh().await.unwrap();
        let o = c.get_job("job1").await["nostromo"]["origin"].clone();
        assert_eq!(o["closed"], false, "push {push}: {o}");
    }
}

// ── a session id is never logged, on the real spawn path ─────────────────────

#[tokio::test]
async fn the_session_id_never_reaches_the_logs_or_an_error_through_the_real_spawn_path() {
    // Four ids: one handed in, one minted, one found in the daemon's store (a
    // resume), one for a spawn that fails. The first eight characters are what
    // Mother jobs legitimately show, and are as telling as the id in a log.
    const EXPLICIT: &str = "SPAWNCNR-1111-2222-3333";
    const RESUMED: &str = "SPAWNRSM-4444-5555-6666";
    const FAILING: &str = "SPAWNERR-7777-8888-9999";
    let logs = captured_logs();

    let mut rig = Rig::new(Mother::New).await;
    // A claude that exits at once. The env var is put back by the rig on drop,
    // whether or not an assertion below fails.
    let stub = rig.dir.path().join("claude-stub");
    std::fs::write(&stub, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    rig.saved
        .push((CLAUDE_BIN_ENV, std::env::var_os(CLAUDE_BIN_ENV)));
    std::env::set_var(CLAUDE_BIN_ENV, &stub);
    let spawn = |tag: &str, sid: Option<&str>| {
        rig.mgr.lock().unwrap().spawn_session(
            tag.into(),
            "cody".into(),
            "Cody".into(),
            None,
            sid.map(str::to_owned),
            false,
        )
    };

    let explicit = spawn("spawn-explicit", Some(EXPLICIT))
        .expect("spawns")
        .expect("an id");
    assert_eq!(explicit, EXPLICIT);

    let minted = spawn("spawn-fresh", None).expect("spawns").expect("an id");
    assert_ne!(minted, EXPLICIT);
    assert_eq!(minted.len(), 36, "the daemon minted a uuid: {minted}");

    rig.store_session("spawn-resume", RESUMED);
    assert!(!rig.history.contains("spawn-resume", RESUMED));
    let resumed = spawn("spawn-resume", None).expect("spawns").expect("an id");
    assert_eq!(resumed, RESUMED, "a resume keeps the stored id");

    std::env::set_var(CLAUDE_BIN_ENV, rig.dir.path().join("no-such-dir/claude"));
    let failure = spawn("spawn-missing", Some(FAILING)).expect_err("no claude binary to run");
    let failure_text = format!("{failure:#} / {failure:?}");
    assert!(failure_text.contains("failed to spawn"), "{failure_text}");

    // The real path ran: each id the daemon spawned is in the focus's history.
    assert!(rig.history.contains("spawn-explicit", EXPLICIT));
    assert!(rig.history.contains("spawn-fresh", &minted));
    assert!(rig.history.contains("spawn-resume", RESUMED));

    let log_text = logs.text();
    for tag in ["spawn-explicit", "spawn-fresh", "spawn-resume"] {
        assert!(
            log_text
                .lines()
                .any(|l| l.contains("session spawned") && l.contains(tag)),
            "the capture is live and saw `{tag}` spawn:\n{log_text}"
        );
    }
    for (what, id) in [
        ("an explicit id", EXPLICIT),
        ("a minted id", minted.as_str()),
        ("a stored id", RESUMED),
        ("the id of a failed spawn", FAILING),
    ] {
        for secret in [id, &id[..8]] {
            assert!(
                !log_text.contains(secret),
                "{what} ({secret}) reached the logs:\n{log_text}"
            );
            assert!(
                !failure_text.contains(secret),
                "{what} ({secret}) reached the spawn error: {failure_text}"
            );
        }
    }
}

/// Does this source line print a `Command`? A `{:?}` of a std or tokio
/// `Command` shows the program, the arguments and the environment it was given,
/// and the session manager's commands carry the session id in `MOTHER_ORIGIN_SESSION`.
fn prints_a_command(line: &str) -> bool {
    let line = line.trim_start();
    if line.starts_with("//") {
        return false;
    }
    let mentions = |word: &str| {
        line.match_indices(word).any(|(at, _)| {
            let before = line[..at].chars().next_back();
            let after = line[at + word.len()..].chars().next();
            let is_ident = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
            !is_ident(before) && !is_ident(after)
        })
    };
    let names_a_command = mentions("cmd") || mentions("command");
    let debug_inline = ["{cmd:?}", "{command:?}", "{cmd:#?}", "{command:#?}"]
        .iter()
        .any(|p| line.contains(p));
    let debug_field = ["?cmd", "?command", "?&cmd", "?&command"].iter().any(|p| {
        line.match_indices(p).any(|(at, _)| {
            let after = line[at + p.len()..].chars().next();
            !after.is_some_and(|c| c.is_alphanumeric() || c == '_')
        })
    });
    let macros = [
        "info!",
        "warn!",
        "debug!",
        "error!",
        "trace!",
        "format!",
        "anyhow!",
        "println!",
        "eprintln!",
        "dbg!",
    ];
    let in_a_macro = macros.iter().any(|m| line.contains(m));
    let debug_arg = (line.contains("{:?}") || line.contains("{:#?}")) && names_a_command;
    debug_inline || debug_field || (in_a_macro && debug_arg)
}

#[test]
fn no_source_line_of_the_session_manager_prints_a_command() {
    // The runtime test above covers the paths it drives; this one guards every
    // other line, cheaply: nothing in the session manager formats a command
    // variable with `{:?}`, in a log line or in an error message.
    for leaks in [
        r#"info!("spawning {cmd:?}");"#,
        r#"warn!("could not start {:?}", cmd);"#,
        r#"let e = anyhow!("failed: {:#?}", command);"#,
        r#"debug!(?command, "starting");"#,
        r#"tracing::trace!(cmd = ?cmd, "x");"#,
    ] {
        assert!(prints_a_command(leaks), "the detector misses: {leaks}");
    }
    for fine in [
        r#"info!(tag, resume, "session spawned");"#,
        "let mut cmd = Command::new(&program);",
        r#"let e = anyhow!("failed to spawn {}: {e}", program.display());"#,
        r#"warn!("args {:?}", args);"#,
        r#"// info!("{cmd:?}") would leak"#,
        r#"debug!("{:?}", recommended);"#,
    ] {
        assert!(!prints_a_command(fine), "the detector flags: {fine}");
    }

    fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/ipc/session_manager");
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    assert!(
        files.iter().any(|f| f.ends_with("mod.rs")),
        "the scan found the session manager: {files:?}"
    );
    let mut offenders = Vec::new();
    for file in &files {
        let text = std::fs::read_to_string(file).unwrap();
        for (n, line) in text.lines().enumerate() {
            if prints_a_command(line) {
                offenders.push(format!("{}:{}: {}", file.display(), n + 1, line.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "a command (its environment holds the session id) is printed:\n{}",
        offenders.join("\n")
    );
}

// ── a poll between `mother add` and the stamp ────────────────────────────────

fn minted(rig: &Rig, job_id: &str) -> bool {
    std::fs::read_to_string(rig.mother_dir.join("ids"))
        .unwrap_or_default()
        .lines()
        .any(|l| l == job_id)
}

fn count_audits(audit: &[Value], event: &str) -> usize {
    audit.iter().filter(|l| l["event"] == event).count()
}

/// While a daemon enqueue's `mother add` has not answered, poll the feed: the
/// job is listed (its record claims `FOCUS` and a session the daemon has not
/// got in its history, so a poll that judged it would call it unverified), and
/// it is not judged. Then `add` answers, the stamp is written, and the job is
/// the focus's, via mcp. `start` begins the enqueue.
async fn poll_in_the_gap<F, Fut>(rig: &Rig, start: F) -> Fut::Output
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future,
{
    std::fs::write(rig.mother_dir.join("hold"), "").unwrap();
    let enqueue = start();
    let poller = async {
        wait_until("the fake mother to mint the job", || minted(rig, "job1")).await;

        let listed = rig.feed.refresh().await.expect("list");

        assert_eq!(listed.len(), 1, "{listed:?}");
        let origin = &listed[0].nostromo.as_ref().expect("annotated").origin;
        assert_eq!(
            (origin.kind, origin.focus_tag.as_deref()),
            (OriginKind::Unknown, None),
            "a job whose enqueue has not answered is undecided"
        );
        assert!(
            rig.book.entry("job1").is_none(),
            "an undecided job is not recorded"
        );
        assert_eq!(
            count_audits(&rig.audit(), "job_origin_unverified"),
            0,
            "the daemon's own enqueue was audited as a forgery: {:?}",
            rig.audit()
        );

        std::fs::write(rig.mother_dir.join("release"), "").unwrap();
    };
    let (out, ()) = tokio::join!(enqueue, poller);

    rig.feed.refresh().await.expect("list");
    let entry = rig.book.entry("job1").expect("the book holds the job now");
    assert_eq!(
        (entry.kind, entry.focus_tag.as_deref(), entry.via),
        (OriginKind::Focus, Some(FOCUS), Via::Mcp)
    );
    let audit = rig.audit();
    assert_eq!(count_audits(&audit, "job_origin_stamped"), 1, "{audit:?}");
    assert_eq!(
        count_audits(&audit, "job_origin_unverified"),
        0,
        "{audit:?}"
    );
    let shown = rig.feed.jobs_rx().borrow()[0].nostromo.clone().unwrap();
    assert_eq!(shown.origin.kind, OriginKind::Focus);
    assert_eq!(shown.origin.focus_tag.as_deref(), Some(FOCUS));
    out
}

/// A job whose record claims a focus the daemon never spawned that session for,
/// listed with nothing in flight: audited as unverified, once.
fn assert_a_forged_claim_is_still_audited_once(rig: &Rig) {
    let forged = vec![job("forged", Some(claim(FOCUS, "never-spawned-session")))];
    for _ in 0..3 {
        let published = rig.feed.publish_jobs(forged.clone());
        assert_eq!(kind_of(&published[0]), OriginKind::Unverified);
    }
    let audit = rig.audit();
    let forged_audits = audit
        .iter()
        .filter(|l| l["event"] == "job_origin_unverified" && l["job"] == "forged")
        .count();
    assert_eq!(forged_audits, 1, "{audit:?}");
}

#[tokio::test]
async fn a_poll_between_mother_add_and_the_stamp_does_not_judge_the_daemons_own_enqueue() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    assert!(
        !rig.history.contains(FOCUS, FOCUS_SID),
        "the session is not in the history: a poll that judged the claim would not verify it"
    );
    let mut c = rig.client(FOCUS).await;
    let plan = rig.plan();

    let res = poll_in_the_gap(&rig, || c.enqueue(&plan, json!({}))).await;

    assert_eq!(res["id"], "job1", "{res}");
    assert_a_forged_claim_is_still_audited_once(&rig);
}

#[tokio::test]
async fn a_poll_between_mother_add_and_the_stamp_does_not_judge_a_create_focus_job_either() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    let repo = rig.repo();
    let args = mother_job_args(&repo, "todo:mf1-gap");

    let out = poll_in_the_gap(&rig, || create_focus(&rig.state, &args, Some(FOCUS))).await;

    assert_eq!(out["kind"], "queued", "{out}");
    assert_eq!(out["job_id"], "job1", "{out}");
    assert_a_forged_claim_is_still_audited_once(&rig);
}

#[tokio::test]
async fn a_failed_enqueue_does_not_leave_later_forgeries_unjudged() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    std::fs::write(rig.mother_dir.join("fail"), "").unwrap();
    let mut c = rig.client(FOCUS).await;

    let res = c.enqueue(&rig.plan(), json!({})).await;

    assert!(res.get("id").is_none(), "mother add failed: {res}");
    assert!(res.get("error").is_some(), "{res}");
    assert_a_forged_claim_is_still_audited_once(&rig);
}

#[tokio::test]
async fn a_failed_create_focus_job_does_not_leave_later_forgeries_unjudged() {
    let rig = Rig::new(Mother::New).await;
    rig.add_focus(FOCUS, FOCUS_NAME, FOCUS_SID);
    std::fs::write(rig.mother_dir.join("fail"), "").unwrap();
    let repo = rig.repo();

    let out = create_focus(
        &rig.state,
        &mother_job_args(&repo, "todo:mf1-fail"),
        Some(FOCUS),
    )
    .await;

    assert_ne!(out["kind"], "queued", "mother add failed: {out}");
    assert_a_forged_claim_is_still_audited_once(&rig);
}

// ── a sensitive focus's name ─────────────────────────────────────────────────

const SECRET_NAME: &str = "Payroll fix";
const SECRET_FOCUS: &str = "claudia-5ECRE700";
const SECRET_SID: &str = "5ec0e700-aaaa-4bbb-8ccc-1234567890ab";
const PLAIN_FOCUS: &str = "claudia-91A1D000";
const PLAIN_NAME: &str = "Marketing plan";
const PLAIN_SID: &str = "91a1d000-aaaa-4bbb-8ccc-1234567890ab";

/// How a focus comes to be sensitive.
#[derive(Clone, Copy, Debug)]
enum Sensitivity {
    /// Registered as sensitive (it received Teri/Fred-derived content).
    Marked,
    /// It runs the Teri or Fred agent.
    Agent(&'static str),
}

const EVERY_SENSITIVITY: [Sensitivity; 3] = [
    Sensitivity::Marked,
    Sensitivity::Agent("teri"),
    Sensitivity::Agent("fred"),
];

/// Register `SECRET_FOCUS` ("Payroll fix") as sensitive in the manager, and
/// `PLAIN_FOCUS` ("Marketing plan") as an ordinary focus.
fn add_a_sensitive_and_a_plain_focus(rig: &Rig, how: Sensitivity) {
    match how {
        Sensitivity::Marked => {
            rig.add_focus(SECRET_FOCUS, SECRET_NAME, SECRET_SID);
            rig.sensitive_tags().mark_tag(SECRET_FOCUS);
        }
        Sensitivity::Agent(agent) => rig.add_focus_as(SECRET_FOCUS, SECRET_NAME, SECRET_SID, agent),
    }
    rig.add_focus(PLAIN_FOCUS, PLAIN_NAME, PLAIN_SID);
}

#[tokio::test]
async fn a_closed_sensitive_focus_shows_a_network_peer_neither_its_name_nor_its_snapshot() {
    for how in EVERY_SENSITIVITY {
        let rig = Rig::new(Mother::New).await;
        add_a_sensitive_and_a_plain_focus(&rig, how);
        rig.client(SECRET_FOCUS)
            .await
            .enqueue(&rig.plan(), json!({}))
            .await;
        rig.client(PLAIN_FOCUS)
            .await
            .enqueue(&rig.plan_named("plan-2.md"), json!({}))
            .await;

        // The app acknowledges both focuses, then two pushes in a row lack them.
        let secret = focus_meta_for(
            SECRET_FOCUS,
            SECRET_NAME,
            match how {
                Sensitivity::Marked => "claudia",
                Sensitivity::Agent(agent) => agent,
            },
        );
        rig.push_registry(vec![
            secret,
            focus_meta(PLAIN_FOCUS, PLAIN_NAME),
            focus_meta("claudia-OTHER000", "Other"),
        ]);
        for _ in 0..2 {
            rig.push_registry(vec![focus_meta("claudia-OTHER000", "Other")]);
        }
        let mut listed = rig.feed.refresh().await.expect("list");
        for j in &mut listed {
            let annotation = j.nostromo.as_mut().unwrap();
            assert_eq!(
                annotation.origin.closed,
                Some(true),
                "{how:?}: {} is closed",
                j.id
            );
            assert_eq!(
                annotation.origin.focus_name, None,
                "{how:?}: a closed focus has no name now"
            );
            // The notice is MF2's; it must not reach a network peer for a
            // sensitive focus whatever it holds.
            annotation.notice = Some(told_notice());
        }
        let tags = rig.sensitive_tags();
        assert!(tags.tag_is_sensitive(SECRET_FOCUS), "{how:?}");
        assert!(!tags.tag_is_sensitive(PLAIN_FOCUS), "{how:?}");

        let frame =
            nostromo::ipc::peer::redact_for_network(ServerMsg::MotherJobs { jobs: listed }, &tags);

        let wire = serde_json::to_string(&frame).unwrap();
        let ServerMsg::MotherJobs { jobs } = frame else {
            panic!("still a MotherJobs frame");
        };
        let origin_of = |id: &str| {
            jobs.iter()
                .find(|j| j.id == id)
                .unwrap_or_else(|| panic!("{how:?}: {id} is listed"))
                .nostromo
                .clone()
                .expect("annotated")
        };
        let secret_job = origin_of("job1");
        for (what, shown) in [
            ("name_snapshot", &secret_job.origin.name_snapshot),
            ("focus_name", &secret_job.origin.focus_name),
        ] {
            assert_eq!(
                shown.as_deref(),
                Some(nostromo::mother::origin::SENSITIVE_NAME),
                "{how:?}: {what}"
            );
        }
        assert_eq!(secret_job.origin.focus_tag, None, "{how:?}");
        assert_eq!(secret_job.origin.session_prefix, None, "{how:?}");
        assert_eq!(secret_job.notice, None, "{how:?}: the notice is removed");
        assert_eq!(secret_job.origin.closed, Some(true), "{how:?}");
        for leak in [SECRET_NAME, SECRET_FOCUS, "5ec0e700"] {
            assert!(
                !wire.contains(leak),
                "{how:?}: {leak} reached a network peer: {wire}"
            );
        }

        // An ordinary focus that is closed keeps what the job says it was.
        let plain_job = origin_of("job2");
        assert_eq!(plain_job.origin.name_snapshot.as_deref(), Some(PLAIN_NAME));
        assert_eq!(plain_job.origin.focus_tag, None, "{how:?}");
        assert!(wire.contains(PLAIN_NAME), "{how:?}: {wire}");
        assert!(
            plain_job.notice.is_some(),
            "{how:?}: an ordinary focus keeps its notice"
        );
    }
}

#[tokio::test]
async fn a_sensitive_focus_enqueues_without_its_name_in_mothers_record_and_the_daemon_keeps_it() {
    for how in EVERY_SENSITIVITY {
        let rig = Rig::new(Mother::New).await;
        add_a_sensitive_and_a_plain_focus(&rig, how);

        rig.client(SECRET_FOCUS)
            .await
            .enqueue(&rig.plan(), json!({}))
            .await;

        let add = rig.the_add();
        assert_eq!(
            flag(&add, "--origin-session"),
            Some(SECRET_SID),
            "{how:?}: {add:?}"
        );
        assert_eq!(
            flag(&add, "--origin-focus"),
            Some(SECRET_FOCUS),
            "{how:?}: {add:?}"
        );
        assert_eq!(
            flag(&add, "--origin-focus-name"),
            None,
            "{how:?}: a sensitive focus's name is not handed to mother: {add:?}"
        );
        assert!(
            !add.join(" ").contains(SECRET_NAME),
            "{how:?}: the name is nowhere in the arguments: {add:?}"
        );
        let entry = rig.book.entry("job1").expect("the daemon's own book");
        assert_eq!(
            (entry.kind, entry.focus_tag.as_deref(), entry.via),
            (OriginKind::Focus, Some(SECRET_FOCUS), Via::Mcp),
            "{how:?}"
        );
        assert_eq!(
            entry.name_snapshot.as_deref(),
            Some(SECRET_NAME),
            "{how:?}: the daemon keeps the name it never lets out"
        );
    }
}

#[tokio::test]
async fn a_plain_focus_still_passes_its_name_to_mother_beside_a_sensitive_one() {
    let rig = Rig::new(Mother::New).await;
    add_a_sensitive_and_a_plain_focus(&rig, Sensitivity::Agent("teri"));

    rig.client(PLAIN_FOCUS)
        .await
        .enqueue(&rig.plan(), json!({}))
        .await;

    let add = rig.the_add();
    assert_eq!(
        flag(&add, "--origin-focus-name"),
        Some(PLAIN_NAME),
        "{add:?}"
    );
    assert_eq!(flag(&add, "--origin-focus"), Some(PLAIN_FOCUS), "{add:?}");
}

#[tokio::test]
async fn a_create_focus_job_from_a_sensitive_focus_carries_no_name_either() {
    for how in EVERY_SENSITIVITY {
        let rig = Rig::new(Mother::New).await;
        add_a_sensitive_and_a_plain_focus(&rig, how);
        let repo = rig.repo();

        let out = create_focus(
            &rig.state,
            &mother_job_args(&repo, "todo:mf1-sensitive"),
            Some(SECRET_FOCUS),
        )
        .await;

        assert_eq!(out["kind"], "queued", "{how:?}: {out}");
        let add = rig.the_add();
        assert_eq!(
            flag(&add, "--origin-focus"),
            Some(SECRET_FOCUS),
            "{how:?}: {add:?}"
        );
        assert_eq!(
            flag(&add, "--origin-session"),
            Some(SECRET_SID),
            "{how:?}: {add:?}"
        );
        assert_eq!(flag(&add, "--origin-focus-name"), None, "{how:?}: {add:?}");
        assert!(!add.join(" ").contains(SECRET_NAME), "{how:?}: {add:?}");
        assert_eq!(
            rig.book
                .entry("job1")
                .and_then(|e| e.name_snapshot)
                .as_deref(),
            Some(SECRET_NAME),
            "{how:?}: the daemon's book keeps the name"
        );
    }

    // And an ordinary focus's create_focus job still names itself.
    let rig = Rig::new(Mother::New).await;
    add_a_sensitive_and_a_plain_focus(&rig, Sensitivity::Marked);
    let repo = rig.repo();
    let out = create_focus(
        &rig.state,
        &mother_job_args(&repo, "todo:mf1-plain"),
        Some(PLAIN_FOCUS),
    )
    .await;
    assert_eq!(out["kind"], "queued", "{out}");
    assert_eq!(
        flag(&rig.the_add(), "--origin-focus-name"),
        Some(PLAIN_NAME)
    );
}

// ── an unverified claim never borrows the registry's name ────────────────────

#[test]
fn an_unverified_claim_shows_the_name_it_claimed_never_the_registrys_for_that_tag() {
    let r = feed_rig();
    r.book.note_registry_push(&[focus_meta(FOCUS, "Real Name")]);
    let claimed = |name: Option<&str>| {
        let mut o = claim(FOCUS, "a-forged-session");
        if let Some(n) = name {
            o["focus_name"] = json!(n);
        }
        o
    };

    let published = r.feed.publish_jobs(vec![
        job("with-name", Some(claimed(Some("Claimed Name")))),
        job("no-name", Some(claimed(None))),
    ]);

    for (i, expected_snapshot) in [(0, Some("Claimed Name")), (1, None)] {
        let origin = &published[i].nostromo.as_ref().unwrap().origin;
        assert_eq!(origin.kind, OriginKind::Unverified, "job {i}");
        assert_eq!(origin.focus_tag.as_deref(), Some(FOCUS), "job {i}");
        assert_eq!(
            origin.focus_name, None,
            "job {i}: the registry does not speak for a claim nobody vouched for"
        );
        assert_eq!(
            origin.name_snapshot.as_deref(),
            expected_snapshot,
            "job {i}"
        );
    }
    let wire = serde_json::to_string(&published).unwrap();
    assert!(!wire.contains("Real Name"), "{wire}");
}

#[test]
fn a_verified_job_for_the_same_tag_still_gets_the_registrys_current_name() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    r.book.note_registry_push(&[focus_meta(FOCUS, "Real Name")]);
    let mut verified = claim(FOCUS, FOCUS_SID);
    verified["focus_name"] = json!("Claimed Name");

    let published = r.feed.publish_jobs(vec![
        job("verified", Some(verified)),
        job("forged", Some(claim(FOCUS, "a-forged-session"))),
    ]);

    let good = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(good.kind, OriginKind::Focus);
    assert_eq!(good.focus_name.as_deref(), Some("Real Name"));
    assert_eq!(good.name_snapshot.as_deref(), Some("Real Name"));
    let bad = &published[1].nostromo.as_ref().unwrap().origin;
    assert_eq!(
        (bad.kind, bad.focus_name.as_deref()),
        (OriginKind::Unverified, None)
    );
}

#[test]
fn a_verified_claim_for_a_tag_the_registry_lacks_keeps_the_name_it_claimed_as_its_snapshot() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    let mut verified = claim(FOCUS, FOCUS_SID);
    verified["focus_name"] = json!("Claimed Name");

    let published = r.feed.publish_jobs(vec![job("verified", Some(verified))]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.kind, OriginKind::Focus);
    assert_eq!(origin.name_snapshot.as_deref(), Some("Claimed Name"));
    assert_eq!(origin.focus_name, None, "no registry has named the focus");
}

// ── "by session match": a record with only a session ─────────────────────────

const OTHER_TAG: &str = "claudia-BBBB2222";

#[test]
fn a_record_with_only_a_session_that_one_focus_spawned_is_that_focus_via_shell() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    r.history
        .record(OTHER_TAG, "bbbbbbbb-0000-4000-8000-000000000000");
    r.book
        .note_registry_push(&[focus_meta(FOCUS, "Registry Name")]);

    let published = r.feed.publish_jobs(vec![
        job("no-focus-key", Some(json!({ "session": FOCUS_SID }))),
        job(
            "empty-focus",
            Some(json!({ "focus": "", "session": FOCUS_SID })),
        ),
        job(
            "blank-focus",
            Some(json!({ "focus": "  ", "session": FOCUS_SID })),
        ),
    ]);

    for j in &published {
        let origin = &j.nostromo.as_ref().unwrap().origin;
        assert_eq!(origin.kind, OriginKind::Focus, "{}", j.id);
        assert_eq!(origin.focus_tag.as_deref(), Some(FOCUS), "{}", j.id);
        assert_eq!(
            origin.session_prefix.as_deref(),
            Some("5f3c9a10"),
            "{}",
            j.id
        );
        assert_eq!(
            origin.focus_name.as_deref(),
            Some("Registry Name"),
            "{}",
            j.id
        );
        assert_eq!(origin.closed, Some(false), "{}", j.id);
        let entry = r.book.entry(&j.id).expect("recorded");
        assert_eq!(
            (entry.kind, entry.via),
            (OriginKind::Focus, Via::Shell),
            "{}",
            j.id
        );
        assert_eq!(r.unverified_audits_of(&j.id), 0, "{}", j.id);
    }
}

#[test]
fn a_record_with_only_a_session_two_focuses_spawned_vouches_for_nobody() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);
    r.history.record(OTHER_TAG, FOCUS_SID);

    let published = r.feed.publish_jobs(vec![job(
        "ambiguous",
        Some(json!({ "session": FOCUS_SID })),
    )]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(
        (origin.kind, origin.focus_tag.as_deref()),
        (OriginKind::Unknown, None)
    );
    assert_eq!(origin.session_prefix, None);
    assert!(r.audit().is_empty(), "{:?}", r.audit());
}

#[test]
fn a_record_with_only_a_session_nobody_spawned_is_unknown_and_not_called_a_forgery() {
    let r = feed_rig();
    r.history.record(FOCUS, FOCUS_SID);

    let list = vec![
        job(
            "stranger",
            Some(json!({ "session": "a-session-the-daemon-never-spawned" })),
        ),
        job("blank", Some(json!({ "session": "  " }))),
        job("neither", Some(json!({ "label": "nightly" }))),
        job("bare", None),
    ];
    for _ in 0..3 {
        let published = r.feed.publish_jobs(list.clone());
        for j in &published {
            assert_eq!(kind_of(j), OriginKind::Unknown, "{}", j.id);
        }
    }

    assert!(
        r.audit().is_empty(),
        "nothing here is audited: {:?}",
        r.audit()
    );
}

#[test]
fn a_focus_claim_is_never_rescued_by_the_session_lookup() {
    let r = feed_rig();
    // The session is a real one, but of another focus than the one claimed.
    r.history.record(FOCUS, FOCUS_SID);

    let published = r
        .feed
        .publish_jobs(vec![job("mismatch", Some(claim(OTHER_TAG, FOCUS_SID)))]);

    let origin = &published[0].nostromo.as_ref().unwrap().origin;
    assert_eq!(origin.kind, OriginKind::Unverified);
    assert_eq!(origin.focus_tag.as_deref(), Some(OTHER_TAG));
    assert_eq!(r.unverified_audits_of("mismatch"), 1);
}

// ── a file that cannot be read is kept, not written over ─────────────────────

/// Bytes that are no JSON, `len` of them, with `canary` inside.
fn corrupt_bytes(canary: &str, len: usize) -> Vec<u8> {
    let mut bytes = format!("{{\"t\":[{{\"sid\":\"{canary}\" ~garbage").into_bytes();
    assert!(bytes.len() < len);
    bytes.resize(len, b'~');
    bytes
}

/// The extra backups beside `path` (`<file>.bak.<ms>`).
fn numbered_backups(path: &Path) -> Vec<PathBuf> {
    let prefix = format!("{}.bak.", path.file_name().unwrap().to_string_lossy());
    let mut found: Vec<PathBuf> = std::fs::read_dir(path.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(&prefix)
        })
        .collect();
    found.sort();
    found
}

fn backup_of(path: &Path) -> PathBuf {
    path.with_file_name(format!(
        "{}.bak",
        path.file_name().unwrap().to_string_lossy()
    ))
}

/// The warnings the capture holds about `path`.
fn warnings_about(logs: &LogBuf, path: &Path) -> Vec<String> {
    let path = path.display().to_string();
    logs.text()
        .lines()
        .filter(|l| l.contains(&path) && l.contains("WARN"))
        .map(str::to_owned)
        .collect()
}

#[test]
fn a_corrupt_history_file_opens_empty_is_kept_as_a_backup_and_its_content_is_never_logged() {
    const CANARY: &str = "CORRUPT-CANARY-SID-123";
    let logs = captured_logs();
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("focus-session-history.json");
    let original = corrupt_bytes(CANARY, 1234);
    std::fs::write(&path, &original).unwrap();

    let history = SessionHistory::open(path.clone());

    assert!(!history.contains(FOCUS, FOCUS_SID), "opens empty");
    assert_eq!(
        std::fs::read(backup_of(&path)).unwrap(),
        original,
        "the unreadable file is kept exactly"
    );
    let warned = warnings_about(logs, &path);
    assert_eq!(warned.len(), 1, "one warning naming the file: {warned:?}");
    assert!(
        warned[0].contains("1234"),
        "it says how many bytes: {}",
        warned[0]
    );
    assert!(
        !logs.text().contains(CANARY),
        "the file's content reached the logs"
    );

    // Writing afterwards leaves the backup alone, and the file valid.
    history.record(FOCUS, FOCUS_SID);
    assert_eq!(std::fs::read(backup_of(&path)).unwrap(), original);
    serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap())
        .expect("the history file is valid JSON again");
    assert!(SessionHistory::open(path.clone()).contains(FOCUS, FOCUS_SID));
    assert!(numbered_backups(&path).is_empty());

    // A second corruption does not overwrite the backup of the first.
    let second = corrupt_bytes("CORRUPT-CANARY-SID-456", 2345);
    std::fs::write(&path, &second).unwrap();
    SessionHistory::open(path.clone());
    assert_eq!(
        std::fs::read(backup_of(&path)).unwrap(),
        original,
        "the first backup is still the first file"
    );
    let extra = numbered_backups(&path);
    assert_eq!(extra.len(), 1, "{extra:?}");
    assert_eq!(std::fs::read(&extra[0]).unwrap(), second);
    assert!(
        warnings_about(logs, &path)
            .iter()
            .any(|w| w.contains("2345")),
        "the second warning counts its own bytes"
    );
    assert!(!logs.text().contains("CORRUPT-CANARY-SID-456"));

    // A file that does not exist is an empty history, not a corrupt one.
    let missing = dir
        .path()
        .join("missing")
        .join("focus-session-history.json");
    std::fs::create_dir_all(missing.parent().unwrap()).unwrap();
    let empty = SessionHistory::open(missing.clone());
    assert!(!empty.contains(FOCUS, FOCUS_SID));
    assert!(!backup_of(&missing).exists());
    assert!(numbered_backups(&missing).is_empty());
    assert!(warnings_about(logs, &missing).is_empty());
}

#[test]
fn a_corrupt_origin_book_opens_empty_is_kept_as_a_backup_and_its_content_is_never_logged() {
    const CANARY: &str = "CORRUPT-CANARY-JOB-456";
    let logs = captured_logs();
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("mother-origins.json");
    let original = corrupt_bytes(CANARY, 1234);
    std::fs::write(&path, &original).unwrap();

    let book = OriginBook::open(
        path.clone(),
        SessionHistory::in_memory(),
        MotherAudit::disabled(),
    );

    assert!(book.entry("job1").is_none(), "opens empty");
    assert_eq!(std::fs::read(backup_of(&path)).unwrap(), original);
    let warned = warnings_about(logs, &path);
    assert_eq!(warned.len(), 1, "one warning naming the file: {warned:?}");
    assert!(
        warned[0].contains("1234"),
        "it says how many bytes: {}",
        warned[0]
    );
    assert!(
        !logs.text().contains(CANARY),
        "the file's content reached the logs"
    );

    // The next stamp rewrites the book; the backup stays what it was.
    assert!(book.stamp("job1", Stamp::you(None)));
    assert_eq!(std::fs::read(backup_of(&path)).unwrap(), original);
    let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap())
        .expect("the book is valid JSON again");
    assert!(written.get("job1").is_some(), "{written}");
    let reopened = OriginBook::open(
        path.clone(),
        SessionHistory::in_memory(),
        MotherAudit::disabled(),
    );
    assert_eq!(
        reopened.entry("job1").map(|e| e.kind),
        Some(OriginKind::You)
    );
    assert!(numbered_backups(&path).is_empty());

    // A second corruption does not overwrite the first backup.
    let second = corrupt_bytes("CORRUPT-CANARY-JOB-789", 2345);
    std::fs::write(&path, &second).unwrap();
    OriginBook::open(
        path.clone(),
        SessionHistory::in_memory(),
        MotherAudit::disabled(),
    );
    assert_eq!(std::fs::read(backup_of(&path)).unwrap(), original);
    let extra = numbered_backups(&path);
    assert_eq!(extra.len(), 1, "{extra:?}");
    assert_eq!(std::fs::read(&extra[0]).unwrap(), second);
    assert!(warnings_about(logs, &path)
        .iter()
        .any(|w| w.contains("2345")));
    assert!(!logs.text().contains("CORRUPT-CANARY-JOB-789"));

    // A missing file is an empty book and no backup.
    let missing = dir.path().join("missing").join("mother-origins.json");
    std::fs::create_dir_all(missing.parent().unwrap()).unwrap();
    let empty = OriginBook::open(
        missing.clone(),
        SessionHistory::in_memory(),
        MotherAudit::disabled(),
    );
    assert!(empty.entry("job1").is_none());
    assert!(!backup_of(&missing).exists());
    assert!(numbered_backups(&missing).is_empty());
    assert!(warnings_about(logs, &missing).is_empty());
}

// ── the history ages a session by when it was last spawned ───────────────────

const NOW_MS: i64 = 1_800_000_000_000;
const DAY: i64 = 24 * 60 * 60 * 1000;

#[test]
fn a_session_first_spawned_long_ago_but_resumed_recently_is_still_vouched_for() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("history.json");
    let h = SessionHistory::open(path.clone());
    h.record_at("t", "abandoned", NOW_MS - 100 * DAY);
    h.record_at("t", "long-lived", NOW_MS - 100 * DAY);
    h.record_at("t", "long-lived", NOW_MS - 10 * DAY);

    // Any later record is when old entries are dropped.
    h.record_at("other", "x", NOW_MS);

    assert!(
        h.contains("t", "long-lived"),
        "aged by last spawn, not first"
    );
    assert!(!h.contains("t", "abandoned"), "unseen for 100 days is gone");
    assert!(
        SessionHistory::open(path).contains("t", "long-lived"),
        "and the file agrees"
    );
}

#[test]
fn a_history_file_from_before_last_seen_loads_and_ages_by_when_each_session_was_first_seen() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("history.json");
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({
            "t": [{ "sid": "old", "first_seen_ms": NOW_MS - 100 * DAY }],
            "u": [{ "sid": "recent", "first_seen_ms": NOW_MS - 10 * DAY }],
        }))
        .unwrap(),
    )
    .unwrap();

    let h = SessionHistory::open(path.clone());
    assert!(
        h.contains("t", "old") && h.contains("u", "recent"),
        "it loads"
    );
    assert!(
        !backup_of(&path).exists(),
        "an older file is not a corrupt one"
    );

    h.record_at("z", "new", NOW_MS);

    assert!(
        !h.contains("t", "old"),
        "100 days old by its first sighting"
    );
    assert!(h.contains("u", "recent"), "10 days old stays");
    assert!(h.contains("z", "new"));
    let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        written["z"][0]["last_seen_ms"], NOW_MS,
        "the file records when each session was last seen: {written}"
    );
    assert_eq!(
        written["u"][0]["first_seen_ms"],
        NOW_MS - 10 * DAY,
        "{written}"
    );
    assert!(written.get("t").is_none(), "{written}");
}
