//! The wire and surface contract of the per-focus activity counters.
//!
//! * `SessionInfo` carries `agent_turns`, `agent_messages`, `agent_problems`,
//!   `activity_epoch` and `last_problem` as ADDITIVE optional fields: absent
//!   keys when unknown, ignored by a build that does not know them, read as
//!   `None` from a daemon that does not send them;
//! * the daemon advertises `focus_activity_v1` and `PROTOCOL_VERSION` does not
//!   move;
//! * a network peer's session list is still filtered exactly as before, and
//!   the counters of the sessions it keeps ride along unchanged;
//! * agents never see the counters: nothing under `src/mcp/` knows about them
//!   and `get_self` does not report them.
//!
//! `tests/fixtures/focus_activity/frame-session-list-{with,without}-activity.json`
//! are the exact bytes serde produces (fixed values). After an intended change
//! to the wire shape regenerate them with
//!
//!   UPDATE_GOLDEN=1 cargo test --test focus_activity_wire
//!
//! and review the diff (the Swift side must still decode them).

use std::os::fd::BorrowedFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::focus_activity::ProblemKind;
use nostromo::ipc::peer::{redact_for_network, SensitiveTags};
use nostromo::ipc::peer_verify::testing::app_info;
use nostromo::ipc::peer_verify::{PeerInfo, PeerVerifier};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, SessionInfo, PROTOCOL_VERSION};
use nostromo::ipc::server::Server;
use nostromo::ipc::session_manager::SessionManager;
use nostromo::ipc::stream_json::SessionState;
use serde::{Deserialize, Serialize};
use tokio::net::UnixStream;

// ── fixtures ──────────────────────────────────────────────────────────────────

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/focus_activity")
        .join(name)
}

fn session(with_activity: bool) -> SessionInfo {
    SessionInfo {
        tag: "cody-fixture".into(),
        agent_name: "cody".into(),
        view_name: "Cody".into(),
        session_id: Some("5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11".into()),
        alive: true,
        remote_control: false,
        state: SessionState::Idle,
        stop_reason: None,
        mcp_bridge_connected: None,
        agent_turns: with_activity.then_some(12),
        agent_messages: with_activity.then_some(7),
        agent_problems: with_activity.then_some(3),
        activity_epoch: with_activity.then(|| "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f".to_owned()),
        last_problem: with_activity.then_some(ProblemKind::NoText),
    }
}

fn list(sessions: Vec<SessionInfo>) -> ServerMsg {
    ServerMsg::SessionListResp { sessions }
}

/// Pretty JSON with a trailing newline: the committed form.
fn rendered<T: Serialize>(msg: &T) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

/// Compares `msg`'s rendering with the committed file, or writes the file when
/// `UPDATE_GOLDEN=1`. The file's text.
fn check_golden<T: Serialize>(name: &str, msg: &T) -> String {
    let want = rendered(msg);
    let path = fixture_path(name);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &want).unwrap_or_else(|e| panic!("write {path:?}: {e}"));
        return want;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{path:?} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test focus_activity_wire")
    });
    assert!(
        have == want,
        "{name} drifted from what serde produces; if the change is intended, regenerate with \
         UPDATE_GOLDEN=1 cargo test --test focus_activity_wire and review the diff\n--- file\n{have}\n--- serde\n{want}"
    );
    have
}

const ACTIVITY_KEYS: [&str; 5] = [
    "agent_turns",
    "agent_messages",
    "agent_problems",
    "activity_epoch",
    "last_problem",
];

fn first_session(text: &str) -> serde_json::Value {
    let v: serde_json::Value = serde_json::from_str(text).unwrap();
    v["sessions"][0].clone()
}

// ── the frames ────────────────────────────────────────────────────────────────

#[test]
fn a_session_list_with_activity_matches_its_golden_file_and_carries_all_five_fields() {
    let text = check_golden(
        "frame-session-list-with-activity.json",
        &list(vec![session(true)]),
    );
    let s = first_session(&text);
    assert_eq!(s["agent_turns"], 12);
    assert_eq!(s["agent_messages"], 7);
    assert_eq!(s["agent_problems"], 3);
    assert_eq!(s["activity_epoch"], "0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f");
    assert_eq!(s["last_problem"], "no_text");
}

#[test]
fn a_session_list_without_activity_matches_its_golden_file_and_has_none_of_the_keys() {
    let text = check_golden(
        "frame-session-list-without-activity.json",
        &list(vec![session(false)]),
    );
    let s = first_session(&text);
    for key in ACTIVITY_KEYS {
        assert!(s.get(key).is_none(), "{key} must be absent when unknown");
    }
}

#[test]
fn a_frame_from_a_daemon_without_the_fields_decodes_with_all_five_unknown() {
    let path = fixture_path("frame-session-list-without-activity.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    let ServerMsg::SessionListResp { sessions } = serde_json::from_str(&text).unwrap() else {
        panic!("a session_list_resp");
    };
    let s = &sessions[0];
    assert_eq!(s.tag, "cody-fixture");
    assert_eq!(s.agent_turns, None);
    assert_eq!(s.agent_messages, None);
    assert_eq!(s.agent_problems, None);
    assert_eq!(s.activity_epoch, None);
    assert_eq!(s.last_problem, None);
}

#[test]
fn the_frame_with_activity_decodes_back_to_the_same_values() {
    let path = fixture_path("frame-session-list-with-activity.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    let ServerMsg::SessionListResp { sessions } = serde_json::from_str(&text).unwrap() else {
        panic!("a session_list_resp");
    };
    let s = &sessions[0];
    assert_eq!(
        (s.agent_turns, s.agent_messages, s.agent_problems),
        (Some(12), Some(7), Some(3))
    );
    assert_eq!(
        s.activity_epoch.as_deref(),
        Some("0b6c1c1e-3f0a-4d7e-8f21-6a1b2c3d4e5f")
    );
    assert_eq!(s.last_problem, Some(ProblemKind::NoText));
    assert_eq!(
        rendered(&serde_json::from_str::<ServerMsg>(&text).unwrap()),
        text
    );
}

/// `SessionInfo` as it was before the counters: what an older app decodes.
#[derive(Debug, Deserialize)]
struct OldSessionInfo {
    tag: String,
    agent_name: String,
    view_name: String,
    session_id: Option<String>,
    alive: bool,
    remote_control: bool,
    state: String,
    #[serde(default)]
    stop_reason: Option<String>,
    #[serde(default)]
    mcp_bridge_connected: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct OldList {
    sessions: Vec<OldSessionInfo>,
}

#[test]
fn an_older_app_ignores_the_new_keys_and_reads_the_rest_as_before() {
    let path = fixture_path("frame-session-list-with-activity.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    // The frame really carries every new key, so ignoring them is the test.
    let s = first_session(&text);
    for key in ACTIVITY_KEYS {
        assert!(s.get(key).is_some(), "{key} is in the frame");
    }

    let old: OldList = serde_json::from_str(&text).expect("an older build decodes the new frame");

    let o = &old.sessions[0];
    assert_eq!(o.tag, "cody-fixture");
    assert_eq!(o.agent_name, "cody");
    assert_eq!(o.view_name, "Cody");
    assert_eq!(
        o.session_id.as_deref(),
        Some("5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11")
    );
    assert!(o.alive);
    assert!(!o.remote_control);
    assert_eq!(o.state, "idle");
    assert_eq!(o.stop_reason, None);
    assert_eq!(o.mcp_bridge_connected, None);
}

// ── the handshake ─────────────────────────────────────────────────────────────

struct Operator;

impl PeerVerifier for Operator {
    fn inspect(&self, _fd: BorrowedFd<'_>, verify_code: bool) -> Option<PeerInfo> {
        let mut info = app_info();
        if !verify_code {
            info.code = nostromo::ipc::peer_verify::CodeIdentity::Unverified {
                reason: nostromo::ipc::peer_verify::UnverifiedReason::NotChecked,
            };
        }
        Some(info)
    }

    fn reinspect(&self, _fd: BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
        Some(accepted.clone())
    }
}

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn the_welcome_a_local_peer_receives_advertises_focus_activity_and_the_protocol_version_is_unchanged(
) {
    assert_eq!(
        PROTOCOL_VERSION, 4,
        "the counters are additive: the protocol version does not move"
    );
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let tmp = tempfile::TempDir::new().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::set_var(
            nostromo::approvals::APPROVALS_DIR_ENV,
            tmp.path().join("approvals"),
        );
        let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("daemon-sessions.json"),
        )));
        let socket = tmp.path().join("t.sock");
        let _server = Server::bind(
            &socket,
            Arc::clone(&mgr),
            tmp.path().join("perri-state"),
            Arc::new(Mutex::new(DecisionRegistry::new())),
            Arc::new(Operator),
            false,
            nostromo::terminal::TerminalManager::in_memory(),
        )
        .expect("bind the unix socket");

        let stream = UnixStream::connect(&socket).await.expect("connect");
        let (mut r, mut w) = stream.into_split();
        let hello = ClientMsg::Hello {
            client_id: "focus-activity-wire-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: Some("mac_app".into()),
        };
        write_frame(&mut w, &serde_json::to_vec(&hello).unwrap())
            .await
            .expect("write Hello");
        let welcome = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let bytes = read_frame(&mut r).await.expect("a frame");
                if let Ok(msg @ ServerMsg::Welcome { .. }) = serde_json::from_slice(&bytes) {
                    return msg;
                }
            }
        })
        .await
        .expect("a Welcome in time");
        let ServerMsg::Welcome {
            protocol_version,
            features,
            ..
        } = welcome
        else {
            unreachable!()
        };
        assert_eq!(protocol_version, PROTOCOL_VERSION);
        assert!(
            features.iter().any(|f| f == "focus_activity_v1"),
            "{features:?}"
        );
        mgr.lock().unwrap().kill_all_on_shutdown();
    });
}

// ── network peers ─────────────────────────────────────────────────────────────

#[test]
fn a_network_peer_still_gets_the_non_sensitive_sessions_with_their_counters_unchanged() {
    let tags = SensitiveTags::in_memory();
    tags.mark_tag("cody-secret");
    let mut open = session(true);
    open.tag = "cody-ok".into();
    let mut secret = session(true);
    secret.tag = "cody-secret".into();
    let mut quiet = session(false);
    quiet.tag = "cody-quiet".into();
    let sent = list(vec![secret, open.clone(), quiet.clone()]);

    let ServerMsg::SessionListResp { sessions } = redact_for_network(sent, &tags) else {
        panic!("a session_list_resp stays a session_list_resp");
    };

    assert_eq!(
        sessions.iter().map(|s| s.tag.as_str()).collect::<Vec<_>>(),
        vec!["cody-ok", "cody-quiet"],
        "the sensitive session is still dropped, the others kept in order"
    );
    for (got, want) in sessions.iter().zip([&open, &quiet]) {
        assert_eq!(
            serde_json::to_value(got).unwrap(),
            serde_json::to_value(want).unwrap(),
            "{}: the session, counters included, passes through untouched",
            want.tag
        );
    }
}

// ── agents never see the counters ─────────────────────────────────────────────

const FORBIDDEN: [&str; 7] = [
    "agent_turns",
    "agent_messages",
    "agent_problems",
    "activity_epoch",
    "last_problem",
    "ProblemKind",
    "focus_activity",
];

fn files_under(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files_under(&path, out);
        } else {
            out.push(path);
        }
    }
}

#[test]
fn nothing_on_the_mcp_surface_knows_about_the_activity_counters() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/mcp");
    let mut files = Vec::new();
    files_under(&root, &mut files);
    assert!(files.len() > 20, "the scan found the MCP sources");
    let mut hits = Vec::new();
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue; // not text
        };
        for needle in FORBIDDEN {
            if text.contains(needle) {
                hits.push(format!("{} mentions {needle}", file.display()));
            }
        }
    }
    assert!(
        hits.is_empty(),
        "agents must not read the counters:\n{}",
        hits.join("\n")
    );
}

#[test]
fn get_self_reports_none_of_the_activity_counters() {
    use nostromo::mcp::state::{McpSharedState, PtyIdentity, ViewMeta};
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let state = McpSharedState::for_test();
        state.views_meta.write().await.push(ViewMeta {
            id: "perri",
            title: "Perri".to_string(),
            pane_ids: vec!["pr_queue"],
        });
        state
            .register_pty(
                "test-pty-id".to_string(),
                PtyIdentity {
                    view_id: "perri",
                    session_id: "test-session-id".to_string(),
                    spawned_at: std::time::SystemTime::now(),
                },
            )
            .await;

        let result = nostromo::mcp::tools::get_self::handle(&state, Some("test-pty-id")).await;

        assert_eq!(result["pty_id"], "test-pty-id", "the call really answered");
        let text = result.to_string();
        for needle in FORBIDDEN {
            assert!(!text.contains(needle), "get_self leaks {needle}: {text}");
        }
    });
}
