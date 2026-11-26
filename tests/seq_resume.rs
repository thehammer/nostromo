//! W12 (`docs/plans/backplane/W12-seq-resume.md`): per-topic sequence numbers,
//! replay on resume, and a bounded queue per client, seen from outside the
//! daemon through real sockets (a Unix socket, the legacy TCP listener and the
//! WebSocket listener of the shared rig).
//!
//! What these pin:
//!
//! * every frame of a numbered topic carries a number, strictly increasing per
//!   topic and independent of the others; a frame with no topic is untouched
//!   (W12-3);
//! * `Subscribe.resume` replays exactly what a topic published after the number
//!   the client names, in order, without duplicates, also while frames are being
//!   published around the resubscribe (W12-4);
//! * a ring that does not reach back far enough gives the retained snapshot and
//!   one `Gap` (W12-5); each cap (frames, bytes, the client queue) has a test
//!   that fails when the cap is removed or moved;
//! * a replay never hands a peer what the live path withholds from it (W12-2);
//! * a client that stops reading costs only itself and is told what it missed
//!   (W12-6); replay memory is bounded and reported (W12-10).
//!
//! Synchronisation, since nothing here sleeps on the wall clock:
//!
//! * Producers send on `Server::tx`; a sequencer task numbers each frame some
//!   moments later, so every helper that publishes waits until the topic's
//!   counter has reached the number the frames should have (`publish`).
//! * Frames are published a hundred at a time: the raw channel holds 512 frames
//!   and the sequencer, on falling behind it, empties the rings (by design), so
//!   a burst larger than that without a yield would test the wrong thing.
//! * After `attach` (Hello, Subscribe, then a `Ping` answered with a `Pong`)
//!   every attach-time replay has been written, because the `Pong` comes from
//!   the main loop that starts after them. Live frames carry no such promise
//!   (the `Pong` and the broadcast queue are separate paths), so "nothing else
//!   arrived" is proven with a *barrier*: a frame with no topic that is sent
//!   after the others on the same ordered path (`barrier`).
//! * Timing (a client that stops reading for ten seconds) uses paused tokio
//!   time, and only for those ten seconds (`stalled_client`): with the clock
//!   paused tokio moves it on whenever the runtime is idle, which includes the
//!   moments a big frame's bytes are still on their way through a loopback
//!   socket, so a read with a timeout (as the rig's `Conn` has) would expire
//!   early. Nothing reads while the clock is paused.

use std::collections::BTreeMap;
use std::time::Duration;

use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::data::work::{WorkItem, WorkSource};
use nostromo::ipc::peer::SensitiveTags;
use nostromo::ipc::protocol::{
    ClientMsg, GapReason, NotificationLevel, ReplayUsage, ServerMsg, Topic,
};
use nostromo::ipc::seq::{self, Replay, SeqHub};
use nostromo::ipc::server::Server;
use nostromo::mother::decode::parse_jobs;
use nostromo::mother::MotherJob;
use serde_json::{json, Value};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── the contract's numbers, written down here (not read from the daemon) ──────

/// Frames one topic's ring keeps.
const SPEC_RING_MSGS: usize = 1000;
/// Bytes of serialized frames one topic's ring keeps.
const SPEC_RING_BYTES: usize = 8 * 1024 * 1024;
/// Frames a connection's outbound queue holds before it starts dropping.
const SPEC_QUEUE_CAP: u64 = 256;

// ── frames ────────────────────────────────────────────────────────────────────

fn job(marker: &str, title_bytes: usize) -> MotherJob {
    MotherJob {
        id: marker.to_string(),
        state: "running".to_string(),
        title: "x".repeat(title_bytes),
        ..Default::default()
    }
}

/// A `mother_jobs` frame carrying one job named `marker` (so a test can tell
/// frames apart on the wire). Retained by the daemon only when `host` is set.
fn jobs_frame(marker: &str, host: Option<&str>) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs: vec![job(marker, 0)],
        host: host.map(str::to_string),
    }
}

/// The same with a job whose title makes the frame about `bytes` long.
fn big_jobs_frame(marker: &str, bytes: usize, host: Option<&str>) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs: vec![job(marker, bytes)],
        host: host.map(str::to_string),
    }
}

/// The smallest `mother_jobs` frame.
fn tiny_jobs_frame(host: Option<&str>) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs: vec![],
        host: host.map(str::to_string),
    }
}

fn focuses_frame(host: Option<&str>) -> ServerMsg {
    ServerMsg::FocusRegistryUpdated {
        focuses: vec![],
        host: host.map(str::to_string),
    }
}

fn notification(tag: &str, message: &str) -> ServerMsg {
    ServerMsg::Notification {
        tag: tag.to_string(),
        level: NotificationLevel::Info,
        message: message.to_string(),
    }
}

/// A local-only frame of a numbered topic (`mother_jobs`): the operator's own
/// notice switches, never sent to a network peer.
fn notice_state() -> ServerMsg {
    ServerMsg::MotherNoticeState {
        enabled: true,
        focuses: vec![],
    }
}

fn activity(own_seq: u64) -> ServerMsg {
    serde_json::from_value(json!({
        "type": "activity",
        "ts": "2026-11-25T12:00:00Z",
        "agent": "cody",
        "kind": "tool_use",
        "summary": "reading a file",
        "focus_tag": "proj",
        "seq": own_seq,
    }))
    .expect("an activity frame")
}

fn activity_snapshot() -> ServerMsg {
    serde_json::from_value(json!({"type": "activity_snapshot", "tag": "proj", "streams": []}))
        .expect("an activity snapshot")
}

fn teri_state() -> ServerMsg {
    ServerMsg::TeriState {
        todos: TeriTodosSnapshot::default(),
    }
}

fn work_item(id: &str) -> WorkItem {
    serde_json::from_value(json!({
        "id": id,
        "source": "repo_docs",
        "kind": "plan",
        "title": format!("title of {id}"),
    }))
    .expect("a work item")
}

fn work_snapshot() -> ServerMsg {
    ServerMsg::WorkSnapshot {
        source: WorkSource::RepoDocs,
        group: Some("repo-a".into()),
        items: vec![work_item("doc:repo-a:plans/x.md")],
    }
}

fn approval_pending(tag: &str) -> ServerMsg {
    serde_json::from_value(json!({"type": "approval_pending", "tag": tag, "count": 2}))
        .expect("an approval count")
}

fn approval_request() -> ServerMsg {
    serde_json::from_value(json!({
        "type": "approval_request",
        "tag": "proj",
        "request": {
            "request_id": "r-1",
            "tag": "proj",
            "tool_use_id": "toolu_2",
            "agent": { "name": "cody" },
            "tool_name": "Bash",
            "display_name": "Bash",
            "tool_kind": "bash",
            "input": { "command": "rm -rf /tmp/secret-plan" },
            "display": { "lines": [], "invisible_count": 0, "non_ascii_count": 0, "unparsed": false },
            "reason": { "kind": "other", "text": "Claude Code asked for approval" },
            "flags": {
                "default_to_no": false,
                "suppress_always_allow_rule": false,
                "requires_user_interaction": false,
                "classifier_approvable": false
            },
            "options": ["allow_once", "deny"],
            "session_rule_candidates": [],
            "created_at_ms": 1,
            "deadline_at_ms": 2
        }
    }))
    .expect("an approval request")
}

// ── publishing and waiting ────────────────────────────────────────────────────

/// Let every task that has work run for a while.
async fn settle() {
    for _ in 0..30 {
        tokio::task::yield_now().await;
    }
}

/// Wait until the sequencer has numbered `topic` up to `upto`.
async fn numbered_upto(server: &Server, topic: &Topic, upto: u64) {
    for i in 0..400_000u32 {
        if server.seq().latest(topic) >= upto {
            return;
        }
        tokio::task::yield_now().await;
        if i % 2_000 == 1_999 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    panic!(
        "{topic:?} was never numbered up to {upto} (it is at {})",
        server.seq().latest(topic)
    );
}

/// Publish `frames` the way a producer does, a hundred at a time, waiting for
/// each batch to be numbered (see the module comment for why).
async fn publish(server: &Server, frames: Vec<ServerMsg>) {
    for chunk in frames.chunks(100) {
        let base = server.seq().latest_all();
        let mut want: BTreeMap<Topic, u64> = BTreeMap::new();
        for frame in chunk {
            if let Some(topic) = frame.topic() {
                let n = want
                    .entry(topic.clone())
                    .or_insert_with(|| base.get(&topic).copied().unwrap_or(0));
                *n += 1;
            }
            server.broadcast(frame.clone());
        }
        for (topic, upto) in want {
            numbered_upto(server, &topic, upto).await;
        }
        settle().await;
    }
}

/// Send a frame with no topic and wait for it on `conn`: everything the
/// connection was going to be sent before it has been read by then.
async fn barrier(server: &Server, conn: &mut Conn, label: &str) {
    server.broadcast(ServerMsg::Error {
        message: label.to_string(),
    });
    let label = label.to_string();
    conn.next_matching(
        "the barrier frame",
        move |m| matches!(m, ServerMsg::Error { message } if *message == label),
    )
    .await;
}

fn is_jobs(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::MotherJobs { .. })
}

fn is_focuses(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::FocusRegistryUpdated { .. })
}

/// Read until `n` frames `is` accepts have been read (the inbox first).
async fn read_n(conn: &mut Conn, n: u64, is: impl Fn(&ServerMsg) -> bool) {
    let mut seen = 0;
    while seen < n {
        let m = conn.next_matching("the next frame", |_| true).await;
        if is(&m) {
            seen += 1;
        }
    }
}

// ── connections ───────────────────────────────────────────────────────────────

async fn hello(conn: &mut Conn) {
    conn.send(&Conn::hello(&[], false)).await;
    let welcome = conn
        .next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    conn.welcome = Some(welcome);
}

/// Hello, Welcome, Subscribe (with `resume`), then a sync: afterwards the
/// connection holds everything the daemon replayed on attach.
async fn attach(conn: &mut Conn, topics: &[Topic], resume: &[(Topic, u64)]) {
    hello(conn).await;
    subscribe(conn, topics, resume).await;
}

/// Subscribe (with `resume`) on a connection that has said Hello, then a sync.
async fn subscribe(conn: &mut Conn, topics: &[Topic], resume: &[(Topic, u64)]) {
    conn.send(&ClientMsg::Subscribe {
        topics: topics.to_vec(),
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec![],
        operator_nonce: None,
        resume: resume.iter().cloned().collect(),
    })
    .await;
    conn.sync().await;
}

/// An ordinary local process on the Unix socket (not the Mac app).
async fn local(rig: &Rig, topics: &[Topic], resume: &[(Topic, u64)]) -> Conn {
    let mut conn = rig.unix_raw().await;
    attach(&mut conn, topics, resume).await;
    conn
}

/// A peer on the legacy, unauthenticated TCP listener.
async fn tcp(rig: &Rig, topics: &[Topic], resume: &[(Topic, u64)]) -> Conn {
    let mut conn = rig.tcp_raw().await;
    attach(&mut conn, topics, resume).await;
    conn
}

/// A paired device on the WebSocket listener.
async fn paired(rig: &Rig, token: &str, topics: &[Topic], resume: &[(Topic, u64)]) -> Conn {
    let mut conn = rig.device_raw(token).await;
    attach(&mut conn, topics, resume).await;
    conn
}

// ── reading the wire ──────────────────────────────────────────────────────────

/// Every frame the connection has read, as JSON, in arrival order.
fn wire(conn: &Conn) -> Vec<Value> {
    conn.raw
        .iter()
        .map(|text| serde_json::from_str(text).expect("a JSON frame"))
        .collect()
}

fn ty(frame: &Value) -> &str {
    frame["type"].as_str().unwrap_or("")
}

/// The topic number a frame carries: `seq`, or `topic_seq` for `activity`
/// (whose own `seq` is the per-stream counter).
fn number(frame: &Value) -> Option<u64> {
    let key = if ty(frame) == "activity" {
        "topic_seq"
    } else {
        "seq"
    };
    frame.get(key).and_then(Value::as_u64)
}

/// Frames of one type, in arrival order.
fn of(conn: &Conn, frame_type: &str) -> Vec<Value> {
    wire(conn)
        .into_iter()
        .filter(|f| ty(f) == frame_type)
        .collect()
}

/// The numbers of the numbered frames of one type, in arrival order.
fn seqs_of(conn: &Conn, frame_type: &str) -> Vec<u64> {
    of(conn, frame_type).iter().filter_map(number).collect()
}

/// `(type, number)` of every numbered frame, in arrival order.
fn numbered(conn: &Conn) -> Vec<(String, u64)> {
    wire(conn)
        .iter()
        .filter_map(|f| number(f).map(|n| (ty(f).to_string(), n)))
        .collect()
}

/// The job a `mother_jobs` frame names.
fn marker(frame: &Value) -> String {
    frame["jobs"][0]["id"].as_str().unwrap_or("").to_string()
}

fn host(frame: &Value) -> Option<String> {
    frame
        .get("host")
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn range(from: u64, to: u64) -> Vec<u64> {
    (from..=to).collect()
}

/// `Gap` frames, decoded.
#[derive(Debug)]
struct Gap {
    topic: Topic,
    host: Option<String>,
    from: u64,
    to: u64,
    reason: GapReason,
}

fn gaps(conn: &Conn) -> Vec<Gap> {
    of(conn, "gap")
        .into_iter()
        .map(
            |v| match serde_json::from_value::<ServerMsg>(v.clone()).expect("a Gap decodes") {
                ServerMsg::Gap {
                    topic,
                    host,
                    from,
                    to,
                    reason,
                } => Gap {
                    topic,
                    host,
                    from,
                    to,
                    reason,
                },
                other => panic!("expected a Gap, got {other:?} from {v}"),
            },
        )
        .collect()
}

/// Where in the arrival order the first frame of `frame_type` is, if any.
fn first_index(conn: &Conn, frame_type: &str) -> Option<usize> {
    wire(conn).iter().position(|f| ty(f) == frame_type)
}

// ════════════════════════════════════════════════════════════════════════════
// W12-3: numbering
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_welcome_of_every_transport_advertises_seq() {
    let rig = Rig::new().await;
    let minted = rig.mint_device("phone");
    let on_unix = local(&rig, &[], &[]).await;
    let on_tcp = tcp(&rig, &[], &[]).await;
    let on_ws = paired(&rig, &minted.token, &[], &[]).await;
    for (name, conn) in [("unix", &on_unix), ("tcp", &on_tcp), ("websocket", &on_ws)] {
        assert!(
            conn.features().iter().any(|f| f == "seq"),
            "the {name} Welcome must advertise \"seq\": {:?}",
            conn.features()
        );
    }
}

#[tokio::test]
async fn every_topic_frame_is_numbered_strictly_increasing_per_topic_and_independently() {
    let rig = Rig::new().await;
    let mut client = local(
        &rig,
        &[Topic::MotherJobs, Topic::Focuses, Topic::Layout],
        &[],
    )
    .await;

    // Three topics interleaved, with a frame that has no topic in the middle.
    // `mother_notice_state` belongs to the `mother_jobs` topic: the topic, not
    // the frame type, is what is counted.
    publish(
        &rig.server,
        vec![
            jobs_frame("a", None),
            focuses_frame(None),
            jobs_frame("b", None),
            notice_state(),
            notification("proj", "n1"),
            ServerMsg::Pong,
            jobs_frame("c", None),
            focuses_frame(None),
            notification("proj", "n2"),
            jobs_frame("d", None),
        ],
    )
    .await;
    barrier(&rig.server, &mut client, "done").await;

    let frames = wire(&client);
    let seqs_in = |types: &[&str]| -> Vec<Option<u64>> {
        frames
            .iter()
            .filter(|f| types.contains(&ty(f)))
            .map(|f| f.get("seq").and_then(Value::as_u64))
            .collect()
    };
    assert_eq!(
        seqs_in(&["mother_jobs", "mother_notice_state"]),
        [1, 2, 3, 4, 5].map(Some),
        "one counter for the whole mother_jobs topic, in the order published"
    );
    assert_eq!(seqs_in(&["focus_registry_updated"]), [1, 2].map(Some));
    assert_eq!(
        seqs_in(&["notification"]),
        [1, 2].map(Some),
        "each topic counts from 1 on its own"
    );

    // No topic, no number: neither key.
    let pongs: Vec<&Value> = frames.iter().filter(|f| ty(f) == "pong").collect();
    assert!(pongs.len() >= 2, "the published Pong and the sync Pong");
    for pong in pongs {
        assert!(pong.get("seq").is_none() && pong.get("topic_seq").is_none());
    }
}

#[tokio::test]
async fn activity_frames_carry_their_topic_number_as_topic_seq_and_keep_their_own_seq() {
    let rig = Rig::new().await;
    let mut client = local(&rig, &[Topic::Activity], &[]).await;

    // The per-stream `seq` of an activity event is whatever the store gave it;
    // it must reach the client as it was, even when it is not increasing.
    publish(
        &rig.server,
        vec![
            activity(100),
            activity_snapshot(),
            activity(5),
            activity(100),
        ],
    )
    .await;
    barrier(&rig.server, &mut client, "done").await;

    let events = of(&client, "activity");
    assert_eq!(
        events.iter().map(|v| v["seq"].as_u64()).collect::<Vec<_>>(),
        [100, 5, 100].map(Some),
        "the activity stream's own seq is untouched"
    );
    assert_eq!(
        events
            .iter()
            .map(|v| v["topic_seq"].as_u64())
            .collect::<Vec<_>>(),
        [1, 3, 4].map(Some),
        "the topic's number is topic_seq, from one counter shared with the topic's other frames"
    );
    let snapshots = of(&client, "activity_snapshot");
    assert_eq!(
        snapshots[0]["seq"].as_u64(),
        Some(2),
        "a frame with no seq of its own gets the plain key"
    );
    assert!(snapshots[0].get("topic_seq").is_none());

    // What the typed decode makes of it: the event's own seq, as published.
    let mut typed = Vec::new();
    for m in client.take_all() {
        if let ServerMsg::Activity(ev) = m {
            typed.push(ev.seq);
        }
    }
    assert_eq!(typed, [100, 5, 100].map(Some));
}

#[tokio::test]
async fn a_frame_with_no_topic_goes_out_byte_for_byte_as_before() {
    let rig = Rig::new().await;
    let mut client = local(&rig, &[Topic::MotherJobs], &[]).await;
    let frames = [
        ServerMsg::Pong,
        ServerMsg::Error {
            message: "no topic here".into(),
        },
    ];
    publish(&rig.server, frames.to_vec()).await;
    barrier(&rig.server, &mut client, "done").await;

    for frame in &frames {
        let unnumbered = serde_json::to_string(frame).unwrap();
        assert!(
            client.raw.contains(&unnumbered),
            "{unnumbered} must reach the client exactly as serialized: {:?}",
            client.raw
        );
    }
}

#[tokio::test]
async fn a_client_that_never_sends_resume_is_replayed_nothing_from_the_rings() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), None))
            .collect(),
    )
    .await;

    let mut client = local(&rig, &[Topic::MotherJobs], &[]).await;
    assert!(
        of(&client, "mother_jobs").is_empty(),
        "no resume, no replay: {:?}",
        client.raw
    );
    assert!(gaps(&client).is_empty());

    // The topic's counter is the daemon's, not the connection's: the next
    // frame is number 6.
    client.take_all();
    publish(&rig.server, vec![jobs_frame("next", None)]).await;
    read_n(&mut client, 1, is_jobs).await;
    assert_eq!(seqs_of(&client, "mother_jobs"), vec![6]);
}

#[tokio::test]
async fn frames_with_no_topic_are_never_kept_for_replay() {
    let rig = Rig::new().await;
    let mut client = local(&rig, &[Topic::MotherJobs], &[]).await;
    publish(
        &rig.server,
        vec![
            ServerMsg::Pong,
            ServerMsg::Error {
                message: "x".into(),
            },
            ServerMsg::Hosts { hosts: vec![] },
            approval_request(),
        ],
    )
    .await;
    barrier(&rig.server, &mut client, "done").await;
    assert_eq!(
        rig.server.seq().usage(),
        ReplayUsage {
            topics: 0,
            frames: 0,
            bytes: 0
        },
        "a frame with no topic enters no ring"
    );
    assert!(rig.server.seq().latest_all().is_empty());
}

// ════════════════════════════════════════════════════════════════════════════
// W12-4: resume
// ════════════════════════════════════════════════════════════════════════════

/// Follow a topic, see five frames, go away, miss seven, come back with the
/// last number seen: exactly the seven, in order, nothing else. With a `host`
/// the daemon also retains the latest frame as a snapshot (per host); a client
/// that is replayed the ring must not be sent that snapshot as well.
async fn exactly_the_missed_frames_come_back(host: Option<&str>) {
    let rig = Rig::new().await;
    let mut first = local(&rig, &[Topic::MotherJobs], &[]).await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), host))
            .collect(),
    )
    .await;
    read_n(&mut first, 5, is_jobs).await;
    let seen = seqs_of(&first, "mother_jobs");
    assert_eq!(seen, range(1, 5));
    let last_seen = *seen.last().unwrap();
    drop(first);

    publish(
        &rig.server,
        (1..=7)
            .map(|i| jobs_frame(&format!("b{i}"), host))
            .collect(),
    )
    .await;

    let mut back = local(
        &rig,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, last_seen)],
    )
    .await;
    let replayed = of(&back, "mother_jobs");
    assert_eq!(
        replayed.iter().filter_map(number).collect::<Vec<_>>(),
        range(6, 12),
        "exactly the seven missed frames, by number and in order: {replayed:?}"
    );
    assert_eq!(
        replayed.len(),
        7,
        "no frame without a number: a retained snapshot of the topic must not be sent as well"
    );
    assert_eq!(
        replayed.iter().map(marker).collect::<Vec<_>>(),
        (1..=7).map(|i| format!("b{i}")).collect::<Vec<_>>()
    );
    assert!(gaps(&back).is_empty(), "the ring covered it: no Gap");

    // And the live stream carries on from there, without repeating the last one.
    back.take_all();
    publish(&rig.server, vec![jobs_frame("c1", host)]).await;
    read_n(&mut back, 1, is_jobs).await;
    barrier(&rig.server, &mut back, "done").await;
    assert_eq!(seqs_of(&back, "mother_jobs"), range(6, 13));
}

#[tokio::test]
async fn resume_replays_exactly_the_missed_frames_in_order_without_duplicates() {
    exactly_the_missed_frames_come_back(None).await;
}

#[tokio::test]
async fn resume_of_a_topic_with_a_retained_snapshot_replays_the_frames_and_not_the_snapshot() {
    exactly_the_missed_frames_come_back(Some("kobe")).await;
}

/// Races, so a real multi-threaded runtime: a burst is published while the
/// client resubscribes, at a different moment each round. Whatever the
/// interleaving, the client ends up with every number from the one it named to
/// the last, each exactly once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn frames_published_while_a_client_resubscribes_are_neither_lost_nor_duplicated() {
    let rig = Rig::new().await;
    let mut last = 0u64;
    for round in 0..20u64 {
        let missed = 5 + round % 4;
        let burst = 60;
        publish(
            &rig.server,
            (0..missed)
                .map(|i| jobs_frame(&format!("r{round}-m{i}"), None))
                .collect(),
        )
        .await;

        let tx = rig.server.tx.clone();
        let publisher = tokio::spawn(async move {
            for i in 0..burst {
                let _ = tx.send(jobs_frame(&format!("r{round}-b{i}"), None));
                tokio::task::yield_now().await;
            }
        });
        // A different head start for the resubscribe each round.
        for _ in 0..(round % 7) {
            tokio::task::yield_now().await;
        }

        let mut client = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, last)]).await;
        publisher.await.expect("the burst was published");
        let target = last + missed + burst;
        // Everything arrives: the replay plus whatever was live.
        read_n(&mut client, target - last, is_jobs).await;
        barrier(&rig.server, &mut client, &format!("done-{round}")).await;

        assert_eq!(
            seqs_of(&client, "mother_jobs"),
            range(last + 1, target),
            "round {round}: every number after {last} exactly once, in order"
        );
        assert!(
            gaps(&client).is_empty(),
            "round {round}: the ring covered it"
        );
        last = target;
    }
    assert_eq!(
        rig.server.seq().lag_count(),
        0,
        "no connection fell behind the stamped channel"
    );
}

/// The race above, made certain: a connection that has said Hello is already
/// following the daemon's stream, so a frame published before its `Subscribe`
/// is both in the ring (what the resume replays) and on its way live. It must
/// arrive once.
#[tokio::test]
async fn a_frame_published_between_connecting_and_subscribing_is_delivered_once() {
    let rig = Rig::new().await;
    let mut before = local(&rig, &[Topic::MotherJobs], &[]).await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), None))
            .collect(),
    )
    .await;
    read_n(&mut before, 5, is_jobs).await;
    drop(before);

    let mut client = rig.unix_raw().await;
    hello(&mut client).await;
    // Accepted and welcomed, not yet subscribed: three frames are published.
    publish(
        &rig.server,
        (1..=3)
            .map(|i| jobs_frame(&format!("b{i}"), None))
            .collect(),
    )
    .await;
    subscribe(&mut client, &[Topic::MotherJobs], &[(Topic::MotherJobs, 5)]).await;

    // One more, live, after the resume.
    client.take_all();
    publish(&rig.server, vec![jobs_frame("c1", None)]).await;
    read_n(&mut client, 1, is_jobs).await;
    barrier(&rig.server, &mut client, "done").await;
    assert_eq!(
        seqs_of(&client, "mother_jobs"),
        range(6, 9),
        "frames 6 to 8 once each (replayed, not repeated live), then the live 9"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// boundaries
// ════════════════════════════════════════════════════════════════════════════

/// The ring keeps the newest 1000 frames of a topic. Publish 1002: it holds
/// 3..=1002, so a client that last saw 2 is covered and one that last saw 1 is
/// not.
///
/// A mutation this catches: `MAX_RING_MSGS` raised, lowered or removed (the
/// frames are tiny, so the byte cap does not bind), and an off-by-one in
/// "does the ring reach back to `after`".
#[tokio::test]
async fn the_ring_keeps_exactly_the_newest_1000_frames_so_resume_is_covered_at_the_edge_and_a_gap_one_earlier(
) {
    let rig = Rig::new().await;
    let total = SPEC_RING_MSGS as u64 + 2;
    publish(
        &rig.server,
        (0..total).map(|_| tiny_jobs_frame(Some("kobe"))).collect(),
    )
    .await;
    let usage = rig.server.seq().usage();
    assert_eq!(
        (usage.topics, usage.frames),
        (1, SPEC_RING_MSGS),
        "one ring, holding the newest {SPEC_RING_MSGS} frames"
    );

    // After 2: the first frame it needs (3) is the oldest the ring holds.
    let at_the_edge = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 2)]).await;
    assert_eq!(
        seqs_of(&at_the_edge, "mother_jobs"),
        range(3, total),
        "covered: every frame from 3 to the last"
    );
    assert_eq!(
        of(&at_the_edge, "mother_jobs").len(),
        SPEC_RING_MSGS,
        "and no retained snapshot on top of them"
    );
    assert!(gaps(&at_the_edge).is_empty());

    // After 1: frame 2 was evicted. Snapshot, then one Gap.
    let one_too_far = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 1)]).await;
    let snapshots = of(&one_too_far, "mother_jobs");
    assert_eq!(
        snapshots.len(),
        1,
        "the retained snapshot, and no replayed frame (the numbers seen: {:?})",
        snapshots
            .iter()
            .filter_map(number)
            .take(5)
            .collect::<Vec<_>>()
    );
    assert_eq!(host(&snapshots[0]).as_deref(), Some("kobe"));
    let gaps = gaps(&one_too_far);
    assert_eq!(gaps.len(), 1, "exactly one Gap");
    assert_eq!(gaps[0].topic, Topic::MotherJobs);
    assert_eq!((gaps[0].from, gaps[0].to), (2, total));
    assert_eq!(gaps[0].reason, GapReason::ReplayWindowExceeded);
    assert!(
        first_index(&one_too_far, "mother_jobs") < first_index(&one_too_far, "gap"),
        "the snapshot comes first, the Gap after it"
    );
}

#[tokio::test]
async fn resume_from_the_latest_number_gets_no_frames_and_no_gap() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    let caught_up = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 5)]).await;
    assert!(
        of(&caught_up, "mother_jobs").is_empty(),
        "nothing was missed, so nothing is sent (not even the retained snapshot): {:?}",
        caught_up.raw
    );
    assert!(gaps(&caught_up).is_empty());
}

#[tokio::test]
async fn a_resume_for_a_topic_the_client_did_not_subscribe_to_is_ignored() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=3)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    // Subscribed to focuses only, but asks to resume mother_jobs from 0.
    let mut client = local(&rig, &[Topic::Focuses], &[(Topic::MotherJobs, 0)]).await;
    assert!(of(&client, "mother_jobs").is_empty());
    assert!(gaps(&client).is_empty());

    // Nor does it start receiving the topic live.
    client.take_all();
    publish(&rig.server, vec![jobs_frame("live", None)]).await;
    barrier(&rig.server, &mut client, "done").await;
    assert!(of(&client, "mother_jobs").is_empty());
}

#[tokio::test]
async fn an_unknown_topic_or_a_bad_number_in_resume_is_ignored_and_the_rest_still_works() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=6)
            .map(|i| jobs_frame(&format!("a{i}"), None))
            .collect(),
    )
    .await;
    publish(&rig.server, vec![focuses_frame(Some("kobe"))]).await;

    let mut client = rig.unix_raw().await;
    hello(&mut client).await;
    client
        .send_text(
            json!({
                "type": "subscribe",
                "topics": ["mother_jobs", "focuses"],
                "resume": {
                    "mother_jobs": 3,
                    // not a topic this daemon knows
                    "holograms": 9,
                    // not a number: this entry is dropped, so focuses is simply
                    // not resumed (and keeps its retained snapshot)
                    "focuses": "five",
                    "teri": -1,
                }
            })
            .to_string(),
        )
        .await;
    client.sync().await;

    assert_eq!(
        seqs_of(&client, "mother_jobs"),
        range(4, 6),
        "the well-formed entry is honoured"
    );
    assert_eq!(
        of(&client, "focus_registry_updated").len(),
        1,
        "the entry that could not be read resumed nothing: the retained snapshot as today"
    );
    assert!(gaps(&client).is_empty());
}

#[tokio::test]
async fn resume_from_the_future_gets_the_snapshot_and_a_gap_from_1_to_the_latest_number() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;

    // A client of a daemon that has since restarted names a number this daemon
    // has not reached: just past the latest, and far past it.
    for after in [6, 9999] {
        let client = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, after)]).await;
        let snapshots = of(&client, "mother_jobs");
        assert_eq!(
            snapshots.len(),
            1,
            "after {after}: the retained snapshot, and no replayed frame"
        );
        assert_eq!(marker(&snapshots[0]), "a5", "the latest state");
        let gaps = gaps(&client);
        assert_eq!(gaps.len(), 1, "after {after}: exactly one Gap");
        assert_eq!(gaps[0].topic, Topic::MotherJobs);
        assert_eq!(
            (gaps[0].from, gaps[0].to),
            (1, 5),
            "after {after}: everything this daemon has is news to the client"
        );
        assert_eq!(gaps[0].reason, GapReason::ReplayWindowExceeded);
    }
}

#[tokio::test]
async fn a_client_of_a_restarted_daemon_is_told_even_when_the_topic_has_published_nothing_yet() {
    let rig = Rig::new().await;
    // The client had seen 5 of `perri` before the daemon restarted.
    let client = local(&rig, &[Topic::Perri], &[(Topic::Perri, 5)]).await;
    let gaps = gaps(&client);
    assert_eq!(gaps.len(), 1, "one Gap so the client refreshes the topic");
    assert_eq!(gaps[0].topic, Topic::Perri);
    assert_eq!(gaps[0].reason, GapReason::ReplayWindowExceeded);
    assert_eq!(
        (gaps[0].from, gaps[0].to),
        (1, 0),
        "from 1 (the client's number is from before a restart), to the topic's latest, which is 0"
    );
}

#[tokio::test]
async fn a_topic_with_no_numbers_gets_none_and_a_resume_for_it_is_ignored() {
    let rig = Rig::new().await;
    let mut client = local(&rig, &[Topic::Devices], &[(Topic::Devices, 7)]).await;
    assert!(gaps(&client).is_empty(), "no ring, so nothing to report");

    client.take_all();
    publish(
        &rig.server,
        vec![ServerMsg::Devices {
            devices: vec![],
            hosts: vec![],
        }],
    )
    .await;
    barrier(&rig.server, &mut client, "done").await;
    let lists = of(&client, "devices");
    assert_eq!(lists.len(), 1, "delivered as ever");
    assert!(
        lists[0].get("seq").is_none() && lists[0].get("topic_seq").is_none(),
        "but not numbered: {}",
        lists[0]
    );
}

// ════════════════════════════════════════════════════════════════════════════
// W12-5: past the window
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn resuming_past_the_window_gets_each_topics_snapshot_then_exactly_one_gap_per_topic() {
    let rig = Rig::new().await;
    let total = SPEC_RING_MSGS as u64 + 100;
    publish(
        &rig.server,
        (0..total).map(|_| tiny_jobs_frame(Some("kobe"))).collect(),
    )
    .await;
    publish(
        &rig.server,
        (0..total).map(|_| focuses_frame(Some("kobe"))).collect(),
    )
    .await;

    let client = local(
        &rig,
        &[Topic::MotherJobs, Topic::Focuses],
        &[(Topic::MotherJobs, 10), (Topic::Focuses, 10)],
    )
    .await;

    assert_eq!(of(&client, "mother_jobs").len(), 1, "the retained snapshot");
    assert_eq!(
        of(&client, "focus_registry_updated").len(),
        1,
        "the retained snapshot"
    );
    let gaps = gaps(&client);
    assert_eq!(gaps.len(), 2, "one Gap per topic, no more");
    for topic in [Topic::MotherJobs, Topic::Focuses] {
        let named: Vec<&Gap> = gaps.iter().filter(|g| g.topic == topic).collect();
        assert_eq!(named.len(), 1, "exactly one Gap names {topic:?}");
        assert_eq!((named[0].from, named[0].to), (11, total));
        assert_eq!(named[0].reason, GapReason::ReplayWindowExceeded);
    }
    let last_snapshot = ["mother_jobs", "focus_registry_updated"]
        .iter()
        .map(|t| first_index(&client, t).unwrap())
        .max()
        .unwrap();
    assert!(
        last_snapshot < first_index(&client, "gap").unwrap(),
        "every snapshot comes before the Gaps that say it is not the whole story"
    );
}

/// The byte cap, with frames big enough that it binds long before the frame
/// cap: 700 frames of about 16 KiB are 11 MiB, so the 8 MiB cap leaves about
/// 500 of them while 1000 frames would have fitted.
///
/// A mutation this catches: `MAX_RING_BYTES` raised (the ring then reaches back
/// to the start), lowered (it then cannot cover the last 350 frames) or removed.
#[tokio::test]
async fn the_ring_is_bounded_by_bytes_before_it_is_bounded_by_count() {
    let rig = Rig::new().await;
    let total = 700u64;
    publish(
        &rig.server,
        (1..=total)
            .map(|i| big_jobs_frame(&format!("m{i}"), 16 * 1024, Some("kobe")))
            .collect(),
    )
    .await;

    let usage = rig.server.seq().usage();
    assert!(
        usage.bytes <= SPEC_RING_BYTES,
        "the ring holds {} bytes, over the {SPEC_RING_BYTES} cap",
        usage.bytes
    );
    assert!(
        usage.bytes > SPEC_RING_BYTES - 1024 * 1024,
        "and it is nearly full ({} bytes): the cap is not lower than documented",
        usage.bytes
    );
    assert!(
        usage.frames < total as usize,
        "the byte cap evicted frames the frame cap would have kept ({} of {total})",
        usage.frames
    );

    // Covered where the ring still reaches (the newest 350 frames fit)...
    let covered = local(
        &rig,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, total - 350)],
    )
    .await;
    assert_eq!(
        seqs_of(&covered, "mother_jobs"),
        range(total - 349, total),
        "the newest 350 frames are all still there"
    );
    assert!(gaps(&covered).is_empty());

    // ...and not from the start, which the byte cap has long evicted.
    let too_far = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 1)]).await;
    let gaps = gaps(&too_far);
    assert_eq!(gaps.len(), 1);
    assert_eq!((gaps[0].from, gaps[0].to), (2, total));
    assert_eq!(gaps[0].reason, GapReason::ReplayWindowExceeded);
    assert_eq!(
        of(&too_far, "mother_jobs").len(),
        1,
        "the snapshot, and no replayed frame"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// W12-2: a replay never hands a peer what the live path withholds
// ════════════════════════════════════════════════════════════════════════════

/// The frames, in publish order, a device is *live* sent and a device that
/// resumes is *replayed*, must be the same, and neither may hold a frame the
/// gate withholds from a network peer.
#[tokio::test]
async fn a_paired_device_that_resumes_is_replayed_exactly_what_it_would_have_been_sent_live() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let topics = [Topic::MotherJobs, Topic::Teri, Topic::Work];
    let resume = [(Topic::MotherJobs, 0), (Topic::Teri, 0), (Topic::Work, 0)];

    let mut live = paired(&rig, &phone.token, &topics, &[]).await;
    publish(
        &rig.server,
        vec![
            jobs_frame("open-1", None), // mother_jobs 1: open
            notice_state(),             // mother_jobs 2: local only
            teri_state(),               // teri 1: sensitive
            work_snapshot(),            // work 1: sensitive
            jobs_frame("open-3", None), // mother_jobs 3: open
        ],
    )
    .await;
    barrier(&rig.server, &mut live, "done").await;
    let live_saw = numbered(&live);
    assert_eq!(
        live_saw,
        vec![
            ("mother_jobs".to_string(), 1),
            ("mother_jobs".to_string(), 3)
        ],
        "the live path withholds the local-only and the sensitive frames"
    );

    let resumed = paired(&rig, &phone.token, &topics, &resume).await;
    assert_eq!(
        numbered(&resumed),
        live_saw,
        "the replay is the live stream, no more and no less"
    );
    assert!(gaps(&resumed).is_empty(), "withheld frames are not a Gap");
    for withheld in ["mother_notice_state", "teri_state", "work_snapshot"] {
        assert!(
            of(&resumed, withheld).is_empty(),
            "{withheld} must never be replayed to a device: {:?}",
            resumed.raw
        );
    }

    // The same resume from a local process gets all of it.
    let mac = local(&rig, &topics, &resume).await;
    let mut got = numbered(&mac);
    got.sort();
    assert_eq!(
        got,
        vec![
            ("mother_jobs".to_string(), 1),
            ("mother_jobs".to_string(), 3),
            ("mother_notice_state".to_string(), 2),
            ("teri_state".to_string(), 1),
            ("work_snapshot".to_string(), 1),
        ],
        "a local client is replayed the local-only frame too"
    );
    assert_eq!(
        seqs_of(&mac, "mother_jobs"),
        vec![1, 3],
        "in order within the topic"
    );
}

#[tokio::test]
async fn a_tcp_peer_that_resumes_is_held_to_the_same_gate() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        vec![
            jobs_frame("open-1", None),
            notice_state(),
            teri_state(),
            jobs_frame("open-3", None),
        ],
    )
    .await;
    let peer = tcp(
        &rig,
        &[Topic::MotherJobs, Topic::Teri],
        &[(Topic::MotherJobs, 0), (Topic::Teri, 0)],
    )
    .await;
    assert_eq!(
        numbered(&peer),
        vec![
            ("mother_jobs".to_string(), 1),
            ("mother_jobs".to_string(), 3)
        ]
    );
    assert!(of(&peer, "teri_state").is_empty());
    assert!(of(&peer, "mother_notice_state").is_empty());
}

/// A frame the live path withheld stays withheld: what a network peer could be
/// sent is judged when the frame is published, not when someone asks for it.
#[tokio::test]
async fn a_frame_withheld_when_published_is_not_replayed_after_its_tag_stops_being_sensitive() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let tags = rig.session_mgr.lock().unwrap().sensitive_tags();
    let mut live = paired(&rig, &phone.token, &[Topic::Layout], &[]).await;

    let hold = tags.hold_sensitive("proj-x");
    publish(&rig.server, vec![notification("proj-x", "secret-text")]).await; // layout 1
    drop(hold);
    publish(&rig.server, vec![notification("proj-x", "fine-now")]).await; // layout 2
    barrier(&rig.server, &mut live, "done").await;
    assert_eq!(
        numbered(&live),
        vec![("notification".to_string(), 2)],
        "live, the device was sent only what followed the release"
    );

    let resumed = paired(&rig, &phone.token, &[Topic::Layout], &[(Topic::Layout, 0)]).await;
    assert_eq!(
        numbered(&resumed),
        vec![("notification".to_string(), 2)],
        "the replay must not open what was withheld"
    );
    assert!(
        !resumed.raw.iter().any(|r| r.contains("secret-text")),
        "the withheld text must not be on the wire at all"
    );

    let mac = local(&rig, &[Topic::Layout], &[(Topic::Layout, 0)]).await;
    assert_eq!(
        seqs_of(&mac, "notification"),
        vec![1, 2],
        "a local client was always allowed both"
    );
}

/// The other direction: a tag registered sensitive *after* a frame was
/// published is judged by what is true now, like any frame sent now.
#[tokio::test]
async fn a_frame_of_a_tag_that_became_sensitive_since_is_not_replayed_to_a_device() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    publish(&rig.server, vec![notification("proj-y", "was-open")]).await; // layout 1
    rig.session_mgr
        .lock()
        .unwrap()
        .sensitive_tags()
        .mark_tag("proj-y");

    let resumed = paired(&rig, &phone.token, &[Topic::Layout], &[(Topic::Layout, 0)]).await;
    assert!(
        numbered(&resumed).is_empty(),
        "the tag is sensitive now: {:?}",
        resumed.raw
    );
    assert!(!resumed.raw.iter().any(|r| r.contains("was-open")));

    let mac = local(&rig, &[Topic::Layout], &[(Topic::Layout, 0)]).await;
    assert_eq!(seqs_of(&mac, "notification"), vec![1]);
}

/// The command-bearing approval frames have no topic, so no ring ever holds
/// one; the count (`approval_pending`) is the one approval frame a device may
/// be sent, for a focus that is not sensitive.
#[tokio::test]
async fn no_device_is_ever_replayed_an_approval_request() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let every_numbered_topic = [
        Topic::Activity,
        Topic::MotherJobs,
        Topic::MotherStatusline,
        Topic::Focuses,
        Topic::MotherPeek,
        Topic::Perri,
        Topic::Fred,
        Topic::Teri,
        Topic::Work,
        Topic::Layout,
        Topic::Decision,
        Topic::Model,
    ];
    let resume: Vec<(Topic, u64)> = every_numbered_topic
        .iter()
        .map(|t| (t.clone(), 0))
        .collect();

    publish(
        &rig.server,
        vec![
            approval_request(),
            approval_pending("proj"),
            approval_request(),
        ],
    )
    .await;
    assert_eq!(
        rig.server.seq().usage().frames,
        1,
        "only the count entered a ring (decision); the two requests entered none"
    );

    // Everything, by an empty topic list, and a resume for every topic.
    let resumed = paired(&rig, &phone.token, &[], &resume).await;
    assert!(
        !resumed
            .raw
            .iter()
            .any(|r| r.contains("approval_request") || r.contains("rm -rf")),
        "an approval request reached a device: {:?}",
        resumed.raw
    );
    assert_eq!(
        numbered(&resumed),
        vec![("approval_pending".to_string(), 1)],
        "the count, for a focus that is not sensitive, is replayed"
    );
}

/// The same judgment without a connection: `SeqHub::replay` for a network peer
/// holds back what was withheld *when published*, and never a local-only or a
/// sensitive frame.
#[test]
fn the_hub_replays_a_network_peer_only_what_a_network_peer_could_be_sent_when_published() {
    let tags = SensitiveTags::in_memory();
    let hub = SeqHub::new(tags.clone());
    let hold = tags.hold_sensitive("proj-x");
    hub.publish(notification("proj-x", "withheld")); // layout 1: sensitive focus
    hub.publish(notification("proj-z", "open")); // layout 2
    drop(hold);
    hub.publish(notification("proj-x", "open-now")); // layout 3
    hub.publish(notice_state()); // mother_jobs 1: local only
    hub.publish(jobs_frame("j", None)); // mother_jobs 2
    hub.publish(teri_state()); // teri 1: sensitive

    let replayed = |topic: &Topic, network: bool| -> Vec<u64> {
        match hub.replay(topic, 0, network) {
            Replay::Messages(frames) => frames.into_iter().filter_map(|f| f.seq).collect(),
            Replay::Exceeded { .. } => panic!("the rings cover this"),
        }
    };
    assert_eq!(replayed(&Topic::Layout, true), vec![2, 3]);
    assert_eq!(replayed(&Topic::Layout, false), vec![1, 2, 3]);
    assert_eq!(replayed(&Topic::MotherJobs, true), vec![2]);
    assert_eq!(replayed(&Topic::MotherJobs, false), vec![1, 2]);
    assert_eq!(replayed(&Topic::Teri, true), Vec::<u64>::new());
    assert_eq!(replayed(&Topic::Teri, false), vec![1]);
}

// ════════════════════════════════════════════════════════════════════════════
// satellite frames, and the bytes of a replayed frame
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn host_tagged_and_local_job_frames_share_one_counter_and_keep_their_retained_snapshots() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        vec![
            jobs_frame("d1", None),
            jobs_frame("k1", Some("kobe")),
            jobs_frame("s1", Some("sendai")),
            jobs_frame("d2", None),
            jobs_frame("k2", Some("kobe")),
        ],
    )
    .await;

    // One counter for the topic, whoever the frame came from; a resume carries
    // every one of them, in order, with its host intact.
    let resumed = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 0)]).await;
    let frames = of(&resumed, "mother_jobs");
    assert_eq!(
        frames.iter().filter_map(number).collect::<Vec<_>>(),
        range(1, 5)
    );
    assert_eq!(
        frames.iter().map(marker).collect::<Vec<_>>(),
        ["d1", "k1", "s1", "d2", "k2"]
    );
    assert_eq!(
        frames.iter().map(host).collect::<Vec<_>>(),
        [None, Some("kobe"), Some("sendai"), None, Some("kobe")].map(|h| h.map(str::to_string))
    );
    assert_eq!(frames.len(), 5, "and no retained snapshot on top");

    // Without a resume, the retained keys are as before: the latest frame of
    // each host that has one, and none for the daemon's own.
    let fresh = local(&rig, &[Topic::MotherJobs], &[]).await;
    let mut snapshots: Vec<(Option<String>, String)> = of(&fresh, "mother_jobs")
        .iter()
        .map(|f| (host(f), marker(f)))
        .collect();
    snapshots.sort();
    assert_eq!(
        snapshots,
        vec![
            (Some("kobe".to_string()), "k2".to_string()),
            (Some("sendai".to_string()), "s1".to_string()),
        ],
        "one snapshot per host, the daemon's own frames are not retained"
    );
}

/// A replayed frame is the frame, plus its number. A client that got frame N
/// live and a client that was replayed frame N must hold the same bytes, and
/// those bytes are the unnumbered frame with one key added (nested optional
/// fields, a host and the activity stream's own `seq` included).
#[tokio::test]
async fn a_replayed_frame_is_the_live_frame_with_its_number_and_nothing_else() {
    let rig = Rig::new().await;
    let topics = [Topic::MotherJobs, Topic::Layout, Topic::Activity];
    let mut live = local(&rig, &topics, &[]).await;

    let originals = vec![
        ServerMsg::MotherJobs {
            jobs: rich_jobs(),
            host: None,
        },
        ServerMsg::MotherJobs {
            jobs: rich_jobs(),
            host: Some("kobe".into()),
        },
        notification("proj", "hello"),
        activity(9),
    ];
    publish(&rig.server, originals.clone()).await;
    barrier(&rig.server, &mut live, "done").await;

    let resumed = local(
        &rig,
        &topics,
        &[
            (Topic::MotherJobs, 0),
            (Topic::Layout, 0),
            (Topic::Activity, 0),
        ],
    )
    .await;

    let live_numbered: BTreeMap<(String, u64), String> = numbered_raw(&live);
    let replayed_numbered: BTreeMap<(String, u64), String> = numbered_raw(&resumed);
    assert_eq!(
        live_numbered.len(),
        originals.len(),
        "all four were sent live: {live_numbered:?}"
    );
    assert_eq!(
        replayed_numbered, live_numbered,
        "the replay holds the very bytes the live path sent"
    );

    // Strip the number from the replayed bytes: the frame as the producer made it.
    let mut by_type: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for original in &originals {
        let value = serde_json::to_value(original).unwrap();
        by_type
            .entry(ty(&value).to_string())
            .or_default()
            .push(value);
    }
    let mut stripped: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for frame in of_numbered(&resumed) {
        let key = if ty(&frame) == "activity" {
            "topic_seq"
        } else {
            "seq"
        };
        let mut frame = frame;
        frame.as_object_mut().unwrap().remove(key).unwrap();
        stripped
            .entry(ty(&frame).to_string())
            .or_default()
            .push(frame);
    }
    assert_eq!(stripped, by_type, "nothing but the number was added");
    assert_eq!(
        of_numbered(&resumed)
            .iter()
            .find(|f| ty(f) == "activity")
            .map(|f| f["seq"].clone()),
        Some(json!(9)),
        "and the activity stream's own seq is as it was"
    );
}

/// Jobs with the optional keys a real list has (origin, phases, cycles, an
/// adherence block), decoded the way the daemon decodes `mother list`.
fn rich_jobs() -> Vec<MotherJob> {
    let list = json!([
        {
            "id": "origin-1",
            "title": "queued from a work item",
            "repo": "nostromo",
            "isolation": "worktree",
            "state": "running",
            "created_at": "2026-05-09T10:00:00Z",
            "started_at": "2026-05-09T10:00:03Z",
            "finished_at": null,
            "plan_path": "/tmp/plan.md",
            "current_tier": "tier_2",
            "current_activity": "editing src/lib.rs",
            "kind": null,
            "origin": {"label": "teri-send"},
            "phases": [
                {"agent": "cody", "request_type": "implement", "state": "running",
                 "started_at": "2026-05-09T10:00:04Z", "finished_at": null, "findings": null},
                {"agent": "perri", "request_type": "review", "state": "done",
                 "started_at": "2026-05-09T10:30:00Z", "finished_at": "2026-05-09T10:40:00Z", "findings": 3}
            ]
        },
        {
            "id": "pipeline-1",
            "title": "pipeline job",
            "repo": "nostromo",
            "isolation": "worktree",
            "state": "awaiting",
            "created_at": "2026-05-09T11:00:00Z",
            "paused_reason": "adherence_blocked",
            "adherence_status": "blocked_for_human",
            "adherence_notes": "check the migration",
            "question": "Proceed with the migration?",
            "kind": "pipeline",
            "cycles": [
                {"cycle": 1, "phases": [
                    {"agent": "archie", "request_type": "plan", "state": "done",
                     "started_at": "2026-05-09T11:00:05Z", "finished_at": "2026-05-09T11:05:00Z", "findings": null}
                ]}
            ]
        }
    ]);
    let (jobs, skipped) = parse_jobs(&serde_json::to_vec(&list).unwrap()).expect("jobs parse");
    assert_eq!(skipped, 0);
    assert!(jobs
        .iter()
        .any(|j| j.origin.is_some() && !j.phases.is_empty()));
    jobs
}

/// `(type, number) -> raw text` of every numbered frame.
fn numbered_raw(conn: &Conn) -> BTreeMap<(String, u64), String> {
    conn.raw
        .iter()
        .filter_map(|text| {
            let v: Value = serde_json::from_str(text).ok()?;
            number(&v).map(|n| ((ty(&v).to_string(), n), text.clone()))
        })
        .collect()
}

fn of_numbered(conn: &Conn) -> Vec<Value> {
    wire(conn)
        .into_iter()
        .filter(|f| number(f).is_some())
        .collect()
}

// ════════════════════════════════════════════════════════════════════════════
// W12-10: memory
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn replay_memory_is_bounded_per_topic_and_reported_in_the_health_frame_at_attach() {
    let rig = Rig::new().await;
    // Two topics of big frames (each far past its 8 MiB), one of small ones.
    publish(
        &rig.server,
        (1..=700)
            .map(|i| big_jobs_frame(&format!("m{i}"), 16 * 1024, None))
            .collect(),
    )
    .await;
    publish(
        &rig.server,
        (1..=700)
            .map(|i| notification("proj", &format!("{i}{}", "y".repeat(16 * 1024))))
            .collect(),
    )
    .await;
    publish(&rig.server, (0..5).map(|_| focuses_frame(None)).collect()).await;

    let usage = rig.server.seq().usage();
    assert_eq!(usage.topics, 3);
    assert!(
        usage.bytes <= usage.topics * SPEC_RING_BYTES,
        "bounded by topics x 8 MiB: {usage:?}"
    );
    assert!(
        usage.bytes <= 2 * SPEC_RING_BYTES + 64 * 1024,
        "each of the two big topics holds at most 8 MiB (the small one a few bytes): {usage:?}"
    );
    assert!(
        usage.frames < 1400,
        "the big topics were trimmed: {usage:?}"
    );

    // The operator's health read-out on attach says the same.
    let client = local(&rig, &[Topic::Activity], &[]).await;
    let health = of(&client, "activity_health");
    assert_eq!(health.len(), 1, "one health verdict at attach");
    assert_eq!(
        health[0]["replay"],
        json!({"topics": usage.topics, "frames": usage.frames, "bytes": usage.bytes}),
        "replay usage in the health frame"
    );
}

#[test]
fn the_documented_ring_and_queue_limits_are_the_contract() {
    assert_eq!(seq::MAX_RING_MSGS, SPEC_RING_MSGS);
    assert_eq!(seq::MAX_RING_BYTES, SPEC_RING_BYTES);
    assert_eq!(seq::CLIENT_QUEUE_CAP as u64, SPEC_QUEUE_CAP);
    assert_eq!(seq::CLIENT_QUEUE_RESUME_BELOW as u64, SPEC_QUEUE_CAP / 2);
}

// ════════════════════════════════════════════════════════════════════════════
// W12-6: a client that stops reading
// ════════════════════════════════════════════════════════════════════════════

/// Frames big enough to block the slow client's socket write: a Unix socket
/// holds about 200 KiB, so the first of these is left half written, the writer
/// waits for the client to read, and everything after is the queue's problem.
const BLOCKER_BYTES: usize = 256 * 1024;
/// How many of them (4 MiB: more than any Unix socket buffer holds).
const BLOCKERS: u64 = 16;
/// Frames the kernel could still swallow on top of the one in flight.
const KERNEL_SLACK_FRAMES: u64 = 4;

/// One daemon with two clients on `mother_jobs` and `focuses`: `fast`, which
/// reads everything, and `slow`, which reads nothing, not even while ten
/// (paused) seconds pass. The daemon publishes `BLOCKERS` big frames, then
/// `small_jobs` small ones, then `focus_frames` frames of the other topic, then
/// one more `mother_jobs` frame after the ten seconds.
struct Stalled {
    rig: Rig,
    slow: Conn,
    fast: Conn,
    /// Frames published on `mother_jobs`: their numbers are 1..=this.
    jobs_published: u64,
    /// Frames published on `focuses`.
    focuses_published: u64,
}

async fn stalled_client(small_jobs: u64, focus_frames: u64) -> Stalled {
    let rig = Rig::new().await;
    let topics = [Topic::MotherJobs, Topic::Focuses];
    let slow = local(&rig, &topics, &[]).await;
    let mut fast = local(&rig, &topics, &[]).await;

    publish(
        &rig.server,
        (0..BLOCKERS)
            .map(|i| big_jobs_frame(&format!("blocker-{i}"), BLOCKER_BYTES, None))
            .collect(),
    )
    .await;
    read_n(&mut fast, BLOCKERS, is_jobs).await;

    let mut sent = 0;
    while sent < small_jobs {
        let n = (small_jobs - sent).min(100);
        publish(
            &rig.server,
            (0..n)
                .map(|i| jobs_frame(&format!("s{}", sent + i), None))
                .collect(),
        )
        .await;
        read_n(&mut fast, n, is_jobs).await;
        sent += n;
    }

    if focus_frames > 0 {
        publish(
            &rig.server,
            (0..focus_frames).map(|_| focuses_frame(None)).collect(),
        )
        .await;
        read_n(&mut fast, focus_frames, is_focuses).await;
    }

    // Ten seconds in which the slow client reads nothing (paused time, so they
    // cost none); the daemon goes on, and so does the slow client's stall.
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(10)).await;
    settle().await;
    tokio::time::resume();
    publish(&rig.server, vec![jobs_frame("late", None)]).await;
    read_n(&mut fast, 1, is_jobs).await;

    Stalled {
        rig,
        slow,
        fast,
        jobs_published: BLOCKERS + small_jobs + 1,
        focuses_published: focus_frames,
    }
}

/// Read what the slow client was sent, now that it reads again: until `gaps`
/// `Gap`s have come and every `mother_jobs` frame before the first of them
/// has too, then until a barrier frame proves nothing else is on its way.
async fn drain_slow(s: &mut Stalled, gap_count: usize) {
    let mut jobs_seen = 0u64;
    let mut gaps_seen = 0;
    let mut jobs_from: Option<u64> = None;
    while gaps_seen < gap_count || jobs_from.is_some_and(|from| jobs_seen < from - 1) {
        let m = s.slow.next_matching("a frame or a Gap", |_| true).await;
        match m {
            ServerMsg::MotherJobs { .. } => jobs_seen += 1,
            ServerMsg::Gap {
                topic: Topic::MotherJobs,
                from,
                ..
            } => {
                gaps_seen += 1;
                jobs_from = Some(from);
            }
            ServerMsg::Gap { .. } => gaps_seen += 1,
            _ => {}
        }
    }
    barrier(&s.rig.server, &mut s.slow, "slow-done").await;
}

/// What the whole scenario shows from the outside:
/// * the other client gets every frame, in order, and no Gap;
/// * no connection lagged behind the stamped channel (`lag_count`);
/// * the daemon still accepts and serves a new client during the stall;
/// * the slow client, once it reads, is told once per topic what it missed,
///   with bounds that are exactly the numbers it was not sent.
///
/// The cap (`CLIENT_QUEUE_CAP`) is pinned by where the first drop happens:
/// the writer holds one frame, the queue holds 256, the 258th is the first
/// dropped. A cap raised or removed moves that number up (the slack allows
/// for the kernel's socket buffer only); a cap lowered moves it down.
#[tokio::test]
async fn a_client_that_stops_reading_for_10s_costs_only_itself_and_is_told_once_per_topic_what_it_missed(
) {
    let mut s = stalled_client(600, 50).await;

    // The other client: every frame, in order, no Gap.
    barrier(&s.rig.server, &mut s.fast, "fast-done").await;
    assert_eq!(
        seqs_of(&s.fast, "mother_jobs"),
        range(1, s.jobs_published),
        "the fast client missed nothing and saw it in order"
    );
    assert_eq!(
        seqs_of(&s.fast, "focus_registry_updated"),
        range(1, s.focuses_published)
    );
    assert!(gaps(&s.fast).is_empty());
    assert_eq!(
        s.rig.server.seq().lag_count(),
        0,
        "the stalled client did not make any other connection lag"
    );

    // The daemon is still serving: a new client attaches and is answered.
    let mut newcomer = local(&s.rig, &[Topic::Perri], &[]).await;
    newcomer.sync().await;

    // The slow client reads again.
    drain_slow(&mut s, 2).await;
    assert_eq!(
        s.rig.server.seq().lag_count(),
        0,
        "and its own forwarder never fell behind either"
    );

    let gaps = gaps(&s.slow);
    assert_eq!(
        gaps.len(),
        2,
        "exactly one Gap per affected topic: {gaps:?}"
    );
    let jobs_gap = gaps.iter().find(|g| g.topic == Topic::MotherJobs).unwrap();
    let focus_gap = gaps.iter().find(|g| g.topic == Topic::Focuses).unwrap();
    for g in &gaps {
        assert_eq!(g.reason, GapReason::ClientSlow);
        assert_eq!(g.host, None);
    }

    // mother_jobs: the writer held one frame and the queue 256; every frame
    // from the next one on was dropped, up to the last one published.
    let delivered_before_the_gap = jobs_gap.from - 1;
    assert!(
        delivered_before_the_gap >= SPEC_QUEUE_CAP,
        "the queue must fill before anything is dropped: the first dropped frame is {} \
         but at least {SPEC_QUEUE_CAP} frames were queued ahead of it",
        jobs_gap.from
    );
    assert!(
        delivered_before_the_gap <= SPEC_QUEUE_CAP + 1 + KERNEL_SLACK_FRAMES,
        "a queue of {SPEC_QUEUE_CAP} frames is all a client that does not read may cost; \
         it was sent {delivered_before_the_gap} before the first drop"
    );
    assert_eq!(
        jobs_gap.to, s.jobs_published,
        "the Gap runs to the last frame published"
    );

    // The bounds are exactly the numbers it was not sent.
    assert_eq!(
        seqs_of(&s.slow, "mother_jobs"),
        range(1, jobs_gap.from - 1),
        "everything before the Gap was delivered, in order, and nothing from the Gap's range"
    );
    // focuses: the queue was full from the start, so none was delivered.
    assert_eq!((focus_gap.from, focus_gap.to), (1, s.focuses_published));
    assert!(
        seqs_of(&s.slow, "focus_registry_updated").is_empty(),
        "no frame inside a Gap's range was delivered"
    );
}

/// Beyond the stated criteria, from the doc of `Gap` ("after it the client's
/// last `seq` for the topic is `to`"): a client that applies that rule must not
/// then be sent a frame of the topic numbered at or below `to`, or it would
/// take a frame older than the Gap for newer, or throw it away.
#[tokio::test]
async fn after_a_client_slow_gap_no_frame_of_its_topic_follows_numbered_at_or_below_its_end() {
    let mut s = stalled_client(600, 0).await;
    drain_slow(&mut s, 1).await;

    let gap_to = gaps(&s.slow)[0].to;
    let at = first_index(&s.slow, "gap").expect("a Gap");
    let after: Vec<u64> = wire(&s.slow)
        .iter()
        .skip(at + 1)
        .filter(|f| ty(f) == "mother_jobs")
        .filter_map(number)
        .collect();
    assert!(
        after.iter().all(|n| *n > gap_to),
        "frames numbered {after:?} came after a Gap that ends at {gap_to}"
    );
}

/// 10,000 frames for a client that never reads: its connection holds its queue
/// and no more, nothing the others do is slowed, and the Gap names the real
/// bounds. (Frames are published in batches the sequencer keeps up with; what
/// is bounded is the connection, not the producer.)
#[tokio::test]
async fn a_flood_to_a_client_that_never_reads_stays_bounded_and_the_daemon_stays_responsive() {
    let mut s = stalled_client(10_000, 0).await;

    // Responsive during the stall: another client attaches and is answered.
    let mut newcomer = local(&s.rig, &[Topic::Perri], &[]).await;
    newcomer.sync().await;
    assert_eq!(s.rig.server.seq().lag_count(), 0);
    barrier(&s.rig.server, &mut s.fast, "fast-done").await;
    assert_eq!(
        seqs_of(&s.fast, "mother_jobs"),
        range(1, s.jobs_published),
        "the other client saw every one of the {} frames, in order",
        s.jobs_published
    );

    drain_slow(&mut s, 1).await;
    let gaps = gaps(&s.slow);
    assert_eq!(gaps.len(), 1);
    let (from, to) = (gaps[0].from, gaps[0].to);
    assert_eq!(gaps[0].topic, Topic::MotherJobs);
    assert_eq!(gaps[0].reason, GapReason::ClientSlow);
    assert_eq!(to, s.jobs_published);

    // The connection held at most its queue (plus the frame in the writer and
    // what the kernel buffers hold), however many frames came.
    let delivered = seqs_of(&s.slow, "mother_jobs");
    assert!(
        delivered.len() as u64 <= SPEC_QUEUE_CAP + 1 + KERNEL_SLACK_FRAMES,
        "{} of {} frames were queued for a client that read none",
        delivered.len(),
        s.jobs_published
    );
    assert_eq!(delivered, range(1, from - 1));
    assert_eq!(
        delivered.len() as u64 + (to - from + 1),
        s.jobs_published,
        "delivered plus the Gap's range is every frame published"
    );
}
