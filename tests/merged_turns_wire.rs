//! Merged turns (S3, `merged_turns_v1`), end to end: a real `Server` on a temp Unix socket and a
//! real `SessionManager` running the hermetic fake `claude` (`tests/support/fake_claude_perm.py`:
//! the `HOLD:<path>` cue keeps a turn open until the file exists, and every stdin frame is
//! logged). Modelled on `session_queue_wire.rs`.
//!
//! What this pins, from outside the daemon:
//! - `Welcome.features` names `merged_turns_v1`;
//! - with only capable clients attached, typed messages queued behind a running turn reach the CLI
//!   as ONE frame whose parts parse back exactly, the client sees one started turn with
//!   `user_input` = the parts joined by a blank line and `user_parts` = the parts, and a client
//!   that attaches later sees the same in its snapshot;
//! - a connection whose Hello lacks the capability closes the gate (one frame per message, no
//!   `merge_group`); when its socket drops the gate reopens and the watchers' snapshot says so.
//!
//! Time is paused tokio time and never advances. Environment variables are process-wide, so every
//! test takes `ENV_LOCK`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::approvals::guard;
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::peer_verify::{PeerInfo, PeerVerifier};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, FEATURE_MERGED_TURNS, PROTOCOL_VERSION};
use nostromo::ipc::server::Server;
use nostromo::ipc::session_manager::{merge, SessionManager, CLAUDE_BIN_ENV};
use nostromo::ipc::stream_json::{Turn, TurnDelta};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::AsyncWrite;
use tokio::net::UnixStream;
use tokio::sync::mpsc;

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);

static ENV_LOCK: Mutex<()> = Mutex::new(());

struct NoPeers;

impl PeerVerifier for NoPeers {
    fn inspect(&self, _fd: std::os::fd::BorrowedFd<'_>, _verify: bool) -> Option<PeerInfo> {
        None
    }

    fn reinspect(&self, _fd: std::os::fd::BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
        Some(accepted.clone())
    }
}

struct KillOnDrop(Arc<Mutex<SessionManager>>);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

struct Rig {
    _kill: KillOnDrop,
    _server: Server,
    socket_path: PathBuf,
    tmp: TempDir,
    fake_dir: PathBuf,
}

fn run<Fut: std::future::Future<Output = ()>>(body: impl FnOnce(Rig) -> Fut) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    rt.block_on(async move {
        let rig = Rig::new().await;
        body(rig).await;
    });
}

impl Rig {
    async fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::set_var(
            nostromo::approvals::APPROVALS_DIR_ENV,
            tmp.path().join("approvals"),
        );
        std::env::set_var(guard::GUARD_BIN_ENV, env!("CARGO_BIN_EXE_nostromo-guard"));
        let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("daemon-sessions.json"),
        )));
        let socket_path = tmp.path().join("test.sock");
        let server = Server::bind(
            &socket_path,
            Arc::clone(&mgr),
            tmp.path().join("perri-state"),
            Arc::new(Mutex::new(DecisionRegistry::new())),
            Arc::new(NoPeers),
            false,
            nostromo::terminal::TerminalManager::in_memory(),
        )
        .expect("bind the unix socket");
        let fake_dir = tmp.path().join("fake");
        std::fs::create_dir_all(&fake_dir).unwrap();
        let wrapper = fake_dir.join("claude");
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
                fake_dir.display()
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
        let work = tmp.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        mgr.lock()
            .unwrap()
            .spawn_session(
                "cody-1".into(),
                "cody".into(),
                "View".into(),
                Some(work),
                None,
                false,
            )
            .expect("the session starts");
        Self {
            _kill: KillOnDrop(Arc::clone(&mgr)),
            _server: server,
            socket_path,
            tmp,
            fake_dir,
        }
    }

    /// Everything the fake CLI read on stdin as user frames' contents.
    fn user_contents(&self) -> Vec<Value> {
        std::fs::read_to_string(self.fake_dir.join("stdin.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|f| f["type"] == "user")
            .map(|f| f["message"]["content"].clone())
            .collect()
    }

    fn release(&self) {
        std::fs::write(self.tmp.path().join("hold"), "").unwrap();
    }

    fn hold_cue(&self) -> String {
        format!("first HOLD:{}", self.tmp.path().join("hold").display())
    }

    async fn connect(&self, capable: bool) -> Conn {
        let s = UnixStream::connect(&self.socket_path).await.unwrap();
        let (mut r, w) = s.into_split();
        let (tx, rx) = mpsc::unbounded_channel();
        let reader = tokio::spawn(async move {
            while let Ok(bytes) = read_frame(&mut r).await {
                if tx.send(bytes).is_err() {
                    break;
                }
            }
        });
        let mut conn = Conn {
            tx: Some(Box::new(w)),
            rx,
            seen: Vec::new(),
            cursor: 0,
            reader,
        };
        conn.send(&ClientMsg::Hello {
            client_id: "merged-wire".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: None,
            capabilities: if capable {
                vec![FEATURE_MERGED_TURNS.to_owned()]
            } else {
                Vec::new()
            },
            role: None,
        })
        .await;
        conn.next("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await;
        conn.send(&ClientMsg::Subscribe {
            topics: Vec::new(),
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        })
        .await;
        conn
    }
}

struct Conn {
    tx: Option<Box<dyn AsyncWrite + Unpin + Send>>,
    rx: mpsc::UnboundedReceiver<Vec<u8>>,
    seen: Vec<ServerMsg>,
    cursor: usize,
    reader: tokio::task::JoinHandle<()>,
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Conn {
    async fn send(&mut self, msg: &ClientMsg) {
        let tx = self.tx.as_mut().expect("still connected");
        write_frame(tx, &serde_json::to_vec(msg).unwrap())
            .await
            .unwrap();
    }

    /// Drop the socket without a detach.
    fn hang_up(&mut self) {
        self.tx = None;
        self.reader.abort();
    }

    fn pump(&mut self) {
        while let Ok(bytes) = self.rx.try_recv() {
            self.seen
                .push(serde_json::from_slice(&bytes).expect("a decodable frame"));
        }
    }

    async fn next(&mut self, what: &str, pred: impl Fn(&ServerMsg) -> bool) -> ServerMsg {
        let start = Instant::now();
        loop {
            self.pump();
            if let Some(i) = (self.cursor..self.seen.len()).find(|&i| pred(&self.seen[i])) {
                self.cursor = i + 1;
                return self.seen[i].clone();
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out waiting for {what}; got {:#?}",
                self.seen
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    async fn sync(&mut self) {
        self.send(&ClientMsg::Ping).await;
        self.next("the Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
    }

    fn started_turns(&mut self) -> Vec<Turn> {
        self.pump();
        self.seen
            .iter()
            .filter_map(|m| match m {
                ServerMsg::SessionTurnDelta {
                    delta: TurnDelta::TurnStarted { turn },
                    ..
                } => Some(turn.clone()),
                _ => None,
            })
            .collect()
    }
}

async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "timed out waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

fn send(tag: &str, text: &str) -> ClientMsg {
    ClientMsg::SessionSend {
        tag: tag.into(),
        text: text.into(),
        images: Vec::new(),
        client_ref: None,
    }
}

#[test]
fn the_welcome_names_merged_turns() {
    run(|rig| async move {
        let mut conn = rig.connect(true).await;
        let welcome = conn.seen.iter().find_map(|m| match m {
            ServerMsg::Welcome { features, .. } => Some(features.clone()),
            _ => None,
        });
        assert!(welcome.unwrap().iter().any(|f| f == FEATURE_MERGED_TURNS));
        conn.sync().await;
    });
}

#[test]
fn typed_messages_queued_behind_a_turn_reach_the_cli_as_one_frame_and_show_as_two_parts() {
    run(|rig| async move {
        let mut conn = rig.connect(true).await;
        conn.send(&ClientMsg::SessionAttach {
            tag: "cody-1".into(),
            host: None,
        })
        .await;
        conn.sync().await;
        conn.send(&send("cody-1", &rig.hold_cue())).await;
        wait_until("the first frame", || {
            (rig.user_contents().len() == 1).then_some(())
        })
        .await;
        conn.send(&send("cody-1", "oh and backfill the rows")).await;
        conn.send(&send("cody-1", "use the new column name")).await;
        conn.sync().await;
        rig.release();

        wait_until("the merged frame", || {
            (rig.user_contents().len() == 2).then_some(())
        })
        .await;
        settle().await;
        let frames = rig.user_contents();
        assert_eq!(frames.len(), 2, "one frame for both: {frames:#?}");
        let parsed = merge::parse(frames[1].as_str().unwrap()).expect("a merged frame");
        assert_eq!(
            parsed.parts,
            ["oh and backfill the rows", "use the new column name"]
        );

        let turns = wait_until("two started turns", || {
            let t = conn.started_turns();
            (t.len() == 2).then_some(t)
        })
        .await;
        assert_eq!(
            turns[1].user_input,
            "oh and backfill the rows\n\nuse the new column name"
        );
        assert_eq!(
            turns[1].user_parts,
            ["oh and backfill the rows", "use the new column name"]
        );
        assert!(turns[0].user_parts.is_empty());

        // A client attaching now gets the same in its snapshot.
        let mut late = rig.connect(true).await;
        late.send(&ClientMsg::SessionAttach {
            tag: "cody-1".into(),
            host: None,
        })
        .await;
        let snapshot = late
            .next("the snapshot", |m| {
                matches!(m, ServerMsg::SessionTurns { .. })
            })
            .await;
        match snapshot {
            ServerMsg::SessionTurns { turns, .. } => {
                let merged = turns.iter().find(|t| !t.user_parts.is_empty()).unwrap();
                assert_eq!(merged.user_parts.len(), 2);
                assert_eq!(merged.user_input, turns[1].user_input);
            }
            _ => unreachable!(),
        }
    });
}

async fn settle() {
    for _ in 0..60 {
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

#[test]
fn a_connection_without_the_capability_closes_the_gate_until_its_socket_drops() {
    run(|rig| async move {
        let mut legacy = rig.connect(false).await;
        legacy
            .send(&ClientMsg::SessionAttach {
                tag: "cody-1".into(),
                host: None,
            })
            .await;
        legacy.sync().await;
        legacy.send(&send("cody-1", &rig.hold_cue())).await;
        wait_until("the first frame", || {
            (rig.user_contents().len() == 1).then_some(())
        })
        .await;
        legacy.send(&send("cody-1", "a")).await;
        legacy.send(&send("cody-1", "b")).await;
        legacy.sync().await;
        settle().await;
        // The gate is closed: a later release writes each message alone.
        rig.release();
        wait_until("two frames", || {
            (rig.user_contents().len() == 3).then_some(())
        })
        .await;
        settle().await;
        let frames = rig.user_contents();
        assert_eq!(frames[1], "a");
        assert_eq!(frames[2], "b");
        assert!(frames
            .iter()
            .all(|f| merge::parse(f.as_str().unwrap_or("")).is_none()));

        // A second turn: the legacy socket drops abruptly. The sender below never attaches, so
        // nothing but the disconnect itself can recount the gate: messages merge again.
        let hold2 = rig.tmp.path().join("hold2");
        legacy.hang_up();
        drop(legacy);
        settle().await;
        let mut capable = rig.connect(true).await;
        capable.sync().await;
        capable
            .send(&send("cody-1", &format!("second HOLD:{}", hold2.display())))
            .await;
        wait_until("the second turn", || {
            (rig.user_contents().len() == 4).then_some(())
        })
        .await;
        capable.send(&send("cody-1", "c")).await;
        capable.send(&send("cody-1", "d")).await;
        capable.sync().await;
        std::fs::write(&hold2, "").unwrap();
        wait_until("the merged frame", || {
            (rig.user_contents().len() == 5).then_some(())
        })
        .await;
        let frames = rig.user_contents();
        assert_eq!(
            merge::parse(frames[4].as_str().unwrap()).unwrap().parts,
            ["c", "d"]
        );
    });
}
