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
    ClientMsg, FocusMeta, GapReason, NotificationLevel, ReplayUsage, ServerMsg, Topic,
};
use nostromo::ipc::seq::{self, Replay, SeqHub};
use nostromo::ipc::server::Server;
use nostromo::mother::decode::parse_jobs;
use nostromo::mother::origin::{OriginKind, OriginView};
use nostromo::mother::JobAnnotation;
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
/// No `seq_epoch`: the numbers are compared as they are, as a client that
/// predates the field does.
async fn subscribe(conn: &mut Conn, topics: &[Topic], resume: &[(Topic, u64)]) {
    subscribe_under(conn, topics, resume, None).await;
}

/// [`subscribe`] naming the daemon run (`Subscribe.seq_epoch`) the numbers in
/// `resume` were given under.
async fn subscribe_under(
    conn: &mut Conn,
    topics: &[Topic],
    resume: &[(Topic, u64)],
    seq_epoch: Option<u64>,
) {
    conn.send(&ClientMsg::Subscribe {
        topics: topics.to_vec(),
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec![],
        operator_nonce: None,
        resume: resume.iter().cloned().collect(),
        seq_epoch,
    })
    .await;
    conn.sync().await;
}

/// What a resuming client says about the daemon run its numbers come from.
#[derive(Clone, Copy, Debug)]
enum Epoch {
    /// Nothing: a client that predates the field.
    Absent,
    /// The epoch of the Welcome this very connection was just given: a client
    /// that kept the numbers it saw together with that Welcome's value and
    /// reconnects to the same daemon run.
    Echo,
    /// This value, which the test took from another daemon run's Welcome.
    Is(u64),
}

/// The `seq_epoch` of the connection's Welcome.
fn welcome_epoch(conn: &Conn) -> Option<u64> {
    match &conn.welcome {
        Some(ServerMsg::Welcome { seq_epoch, .. }) => *seq_epoch,
        other => panic!("no Welcome yet: {other:?}"),
    }
}

/// A Welcome's epoch, which every daemon that numbers its topics must give.
fn epoch_of(conn: &Conn) -> u64 {
    welcome_epoch(conn).expect("the Welcome carries a seq_epoch")
}

/// Hello, Welcome, Subscribe naming `epoch`, then a sync.
async fn attach_under(conn: &mut Conn, topics: &[Topic], resume: &[(Topic, u64)], epoch: Epoch) {
    hello(conn).await;
    let seq_epoch = match epoch {
        Epoch::Absent => None,
        Epoch::Echo => Some(epoch_of(conn)),
        Epoch::Is(n) => Some(n),
    };
    subscribe_under(conn, topics, resume, seq_epoch).await;
}

/// [`local`] naming the daemon run the numbers come from.
async fn local_under(rig: &Rig, topics: &[Topic], resume: &[(Topic, u64)], epoch: Epoch) -> Conn {
    let mut conn = rig.unix_raw().await;
    attach_under(&mut conn, topics, resume, epoch).await;
    conn
}

/// [`paired`] naming the daemon run the numbers come from.
async fn paired_under(
    rig: &Rig,
    token: &str,
    topics: &[Topic],
    resume: &[(Topic, u64)],
    epoch: Epoch,
) -> Conn {
    let mut conn = rig.device_raw(token).await;
    attach_under(&mut conn, topics, resume, epoch).await;
    conn
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
    assert!(
        gaps[0].from <= gaps[0].to,
        "a Gap never runs backwards: {:?}",
        gaps[0]
    );
    assert_eq!(
        (gaps[0].from, gaps[0].to),
        (0, 0),
        "to the topic's latest, which is 0, and from no later than that (the topic has no number 1 yet)"
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

// A frame that was *sent* to a network peer but trimmed (a sensitive focus's
// title and tag, a sensitive job's origin names) is trimmed again at replay.
// What it was trimmed of is decided when it is published: a tag that stops
// being sensitive afterwards must not make the replay show what the live
// stream hid.

const SECRET_TITLE: &str = "SECRET-HELD-TITLE";
const SECRET_TAG: &str = "secret-held-tag";

fn secret_meta() -> FocusMeta {
    FocusMeta {
        no_codebase: None,
        tag: SECRET_TAG.into(),
        display_name: SECRET_TITLE.into(),
        agent_name: "cody".into(),
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

/// A job queued by the (held-sensitive) focus, named on the wire by its title.
fn secret_job() -> MotherJob {
    MotherJob {
        id: "trim-job-1".to_string(),
        state: "running".to_string(),
        nostromo: Some(JobAnnotation {
            origin: OriginView {
                kind: OriginKind::Focus,
                focus_tag: Some(SECRET_TAG.into()),
                name_snapshot: Some(SECRET_TITLE.into()),
                focus_name: Some(SECRET_TITLE.into()),
                closed: None,
                session_prefix: None,
            },
            ..Default::default()
        }),
        ..Default::default()
    }
}

#[derive(Clone, Copy, Debug)]
enum Trimmed {
    FocusRegistryUpdated,
    FocusCreated,
    MotherJobs,
    MotherAwaitDetected,
}

impl Trimmed {
    fn frame(self) -> ServerMsg {
        match self {
            Trimmed::FocusRegistryUpdated => ServerMsg::FocusRegistryUpdated {
                focuses: vec![secret_meta()],
                host: None,
            },
            Trimmed::FocusCreated => ServerMsg::FocusCreated {
                meta: secret_meta(),
                host: None,
            },
            Trimmed::MotherJobs => ServerMsg::MotherJobs {
                jobs: vec![secret_job()],
                host: None,
            },
            Trimmed::MotherAwaitDetected => ServerMsg::MotherAwaitDetected(Box::new(secret_job())),
        }
    }

    fn topic(self) -> Topic {
        self.frame().topic().expect("a numbered topic")
    }
}

#[derive(Clone, Copy, Debug)]
enum Net {
    Paired,
    Tcp,
}

/// Hold the tag sensitive, publish the frame, release the hold. The live peer
/// (connected before) was sent the trimmed frame; a peer that then resumes
/// from 0 must not be handed what that frame hid.
async fn a_trimmed_frame_stays_trimmed_in_the_replay(variant: Trimmed, net: Net) {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let tags = rig.session_mgr.lock().unwrap().sensitive_tags();
    let topic = variant.topic();
    let topics = [topic.clone()];
    let resume = [(topic.clone(), 0)];

    let mut live = match net {
        Net::Paired => paired(&rig, &phone.token, &topics, &[]).await,
        Net::Tcp => tcp(&rig, &topics, &[]).await,
    };

    let hold = tags.hold_sensitive(SECRET_TAG);
    publish(&rig.server, vec![variant.frame()]).await;
    barrier(&rig.server, &mut live, "done").await;
    drop(hold);

    assert_eq!(
        numbered(&live).len(),
        1,
        "{variant:?} over {net:?}: the live peer is sent the (trimmed) frame: {:?}",
        live.raw
    );
    assert!(
        !live.raw.iter().any(|r| r.contains(SECRET_TITLE)),
        "{variant:?} over {net:?}: the live stream must hide the title: {:?}",
        live.raw
    );

    let resumed = match net {
        Net::Paired => paired(&rig, &phone.token, &topics, &resume).await,
        Net::Tcp => tcp(&rig, &topics, &resume).await,
    };
    assert!(
        !resumed.raw.iter().any(|r| r.contains(SECRET_TITLE)),
        "{variant:?} over {net:?}: the replay must not show what the live stream hid: {:?}",
        resumed.raw
    );
    if matches!(
        variant,
        Trimmed::FocusRegistryUpdated | Trimmed::FocusCreated
    ) {
        assert!(
            !resumed.raw.iter().any(|r| r.contains(SECRET_TAG)),
            "{variant:?} over {net:?}: nor the tag, which is a slug of the title: {:?}",
            resumed.raw
        );
    }
}

#[tokio::test]
async fn a_paired_device_is_not_replayed_the_title_a_focus_registry_update_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::FocusRegistryUpdated, Net::Paired).await;
}

#[tokio::test]
async fn a_tcp_peer_is_not_replayed_the_title_a_focus_registry_update_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::FocusRegistryUpdated, Net::Tcp).await;
}

#[tokio::test]
async fn a_paired_device_is_not_replayed_the_title_a_focus_created_hid_while_its_tag_was_sensitive()
{
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::FocusCreated, Net::Paired).await;
}

#[tokio::test]
async fn a_tcp_peer_is_not_replayed_the_title_a_focus_created_hid_while_its_tag_was_sensitive() {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::FocusCreated, Net::Tcp).await;
}

#[tokio::test]
async fn a_paired_device_is_not_replayed_the_origin_name_a_mother_jobs_frame_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::MotherJobs, Net::Paired).await;
}

#[tokio::test]
async fn a_tcp_peer_is_not_replayed_the_origin_name_a_mother_jobs_frame_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::MotherJobs, Net::Tcp).await;
}

#[tokio::test]
async fn a_paired_device_is_not_replayed_the_origin_name_a_mother_await_detected_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::MotherAwaitDetected, Net::Paired).await;
}

#[tokio::test]
async fn a_tcp_peer_is_not_replayed_the_origin_name_a_mother_await_detected_hid_while_its_tag_was_sensitive(
) {
    a_trimmed_frame_stays_trimmed_in_the_replay(Trimmed::MotherAwaitDetected, Net::Tcp).await;
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

/// What the stalled client is: an ordinary local process, or a paired device
/// (a network peer).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Transport {
    Local,
    Paired,
}

impl Transport {
    /// Blockers it takes to leave the writer waiting on the client: a Unix
    /// socket holds about 200 KiB; a WebSocket has the kernel's TCP buffers
    /// (several MiB each way) and a bridge (256 KiB, 16 frames) behind it.
    fn blockers(self) -> u64 {
        match self {
            Transport::Local => BLOCKERS,
            Transport::Paired => 120,
        }
    }
}

async fn stalled_client(small_jobs: u64, focus_frames: u64) -> Stalled {
    stalled_client_on(Transport::Local, small_jobs, focus_frames).await
}

async fn stalled_client_on(transport: Transport, small_jobs: u64, focus_frames: u64) -> Stalled {
    let rig = Rig::new().await;
    let topics = [Topic::MotherJobs, Topic::Focuses];
    let slow = match transport {
        Transport::Local => local(&rig, &topics, &[]).await,
        Transport::Paired => {
            let phone = rig.mint_device("slow-phone");
            paired(&rig, &phone.token, &topics, &[]).await
        }
    };
    let mut fast = local(&rig, &topics, &[]).await;
    let blockers = transport.blockers();

    publish(
        &rig.server,
        (0..blockers)
            .map(|i| big_jobs_frame(&format!("blocker-{i}"), BLOCKER_BYTES, None))
            .collect(),
    )
    .await;
    read_n(&mut fast, blockers, is_jobs).await;

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
        jobs_published: blockers + small_jobs + 1,
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

    // The other client: every frame, in order, no Gap. (Synced with a Ping, not
    // a `barrier`: a frame with no topic would reach the stalled client too,
    // and a local client that cannot be sent one is closed, by design.)
    s.fast.sync().await;
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
    s.fast.sync().await; // not a `barrier`: see the first test of this scenario
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
    assert_eq!(
        s.rig.server.seq().ordering_timeouts(),
        0,
        "no reply stopped waiting for the frames ahead of it, flood or no flood"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// A reply never overtakes a broadcast frame sent before it, on a runtime with
// several worker threads (a broadcast crosses two tasks, the sequencer and the
// connection's forwarder, before it is in the connection's queue)
// ════════════════════════════════════════════════════════════════════════════

fn is_pong(text: &str) -> bool {
    serde_json::from_str::<Value>(text).is_ok_and(|v| ty(&v) == "pong")
}

/// A frame of a numbered topic that is rarely identical to another.
fn flood_frame(i: u64) -> ServerMsg {
    match i % 6 {
        0 => notification("flood", &format!("n-{i}")),
        1 => jobs_frame(&format!("flood-{i}"), None),
        2 => focuses_frame(None),
        3 => activity(i),
        4 => teri_state(),
        _ => work_snapshot(),
    }
}

/// Producers that never stop must not hold a reply back: it is written once the
/// frames already queued ahead of it are, not when the queue is quiet.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reply_arrives_within_2s_while_other_producers_publish_continuously() {
    let rig = Rig::new().await;
    let mut conn = local(&rig, &[], &[]).await; // every topic

    let tx = rig.server.tx.clone();
    let publisher = tokio::spawn(async move {
        let mut i = 0u64;
        loop {
            let _ = tx.send(flood_frame(i));
            i += 1;
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });

    // Let the flood reach this client's queue first.
    tokio::time::sleep(Duration::from_millis(200)).await;
    for round in 0..40 {
        tokio::time::timeout(Duration::from_secs(2), conn.sync())
            .await
            .unwrap_or_else(|_| panic!("round {round}: no Pong within 2s while frames flow"));
        conn.take_all();
    }
    publisher.abort();
    assert!(
        conn.raw.len() > 40,
        "the flood must have been reaching the client, or this proves nothing ({} frames)",
        conn.raw.len()
    );
}

/// The frame a producer published, then the reply the same connection asks for
/// at once: the frame first, every time. (A client's `Ping` is the reply; the
/// Pong comes from the main loop, the frame by way of the sequencer and the
/// forwarder, which on several threads can be late.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_broadcast_frame_is_on_the_wire_before_the_reply_asked_for_right_after_it() {
    let rig = Rig::new().await;
    let mut conn = local(&rig, &[Topic::Layout], &[]).await;

    let mut overtaken = Vec::new();
    for i in 0..200 {
        let label = format!("ord-{i}");
        let start = conn.raw.len();
        rig.server.broadcast(notification("ord", &label));
        conn.send(&ClientMsg::Ping).await;
        conn.next_matching("the Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
        conn.next_matching(
            "the broadcast frame",
            |m| matches!(m, ServerMsg::Notification { message, .. } if *message == label),
        )
        .await;
        let new = &conn.raw[start..];
        let frame_at = new.iter().position(|r| r.contains(&label)).unwrap();
        let pong_at = new.iter().position(|r| is_pong(r)).unwrap();
        if pong_at < frame_at {
            overtaken.push(i);
        }
    }
    assert!(
        overtaken.is_empty(),
        "the Pong came before the frame published ahead of it in {} of 200 rounds: {overtaken:?}",
        overtaken.len()
    );
}

// ════════════════════════════════════════════════════════════════════════════
// More frames and helpers for what follows
// ════════════════════════════════════════════════════════════════════════════

/// A frame of the `perri` topic; `site` tells frames apart on the wire, and a
/// `host` makes the daemon retain the latest one as a snapshot.
fn perri_frame(site: &str, host: Option<&str>) -> ServerMsg {
    ServerMsg::PerriState {
        tag: "t".into(),
        queue: vec![],
        current: None,
        jira_site: Some(site.into()),
        host: host.map(str::to_string),
    }
}

fn is_perri(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::PerriState { .. })
}

/// Every topic that has numbers, written down here (not read from the daemon).
fn numbered_topics() -> Vec<Topic> {
    vec![
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
    ]
}

fn serialized_len(msg: &ServerMsg) -> usize {
    serde_json::to_vec(msg).unwrap().len()
}

/// `n` (at most 9) `mother_jobs` frames, each exactly `each` bytes serialized.
fn jobs_frames_each(n: u64, each: usize, host: Option<&str>) -> Vec<ServerMsg> {
    let base = serialized_len(&big_jobs_frame("m1", 0, host));
    (1..=n)
        .map(|i| {
            let frame = big_jobs_frame(&format!("m{i}"), each - base, host);
            assert_eq!(serialized_len(&frame), each);
            frame
        })
        .collect()
}

/// An activity event with a summary of `bytes` bytes.
fn big_activity(own_seq: u64, bytes: usize) -> ServerMsg {
    serde_json::from_value(json!({
        "type": "activity",
        "ts": "2026-11-25T12:00:00Z",
        "agent": "cody",
        "kind": "tool_use",
        "summary": "x".repeat(bytes),
        "focus_tag": "proj",
        "seq": own_seq,
    }))
    .expect("a big activity frame")
}

/// Broadcast `count` frames that have no topic, a hundred at a time.
async fn flood_without_topic(server: &Server, count: u64, label: &str) {
    for batch in 0..count.div_ceil(100) {
        for i in 0..100.min(count - batch * 100) {
            server.broadcast(ServerMsg::Error {
                message: format!("{label}-{}", batch * 100 + i),
            });
        }
        settle().await;
    }
}

fn errors_labelled(conn: &Conn, label: &str) -> usize {
    wire(conn)
        .iter()
        .filter(|f| {
            ty(f) == "error"
                && f["message"]
                    .as_str()
                    .is_some_and(|m| m.starts_with(&format!("{label}-")))
        })
        .count()
}

// ════════════════════════════════════════════════════════════════════════════
// The daemon's epoch: numbers from another run of the daemon mean nothing
// ════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_welcome_of_every_transport_carries_the_daemons_epoch_nonzero_below_2_pow_53_and_another_daemon_has_another(
) {
    let rig = Rig::new().await;
    let minted = rig.mint_device("phone");
    let on_unix = local(&rig, &[], &[]).await;
    let on_tcp = tcp(&rig, &[], &[]).await;
    let on_ws = paired(&rig, &minted.token, &[], &[]).await;
    let epochs = [
        ("unix", epoch_of(&on_unix)),
        ("tcp", epoch_of(&on_tcp)),
        ("websocket", epoch_of(&on_ws)),
    ];
    for (name, epoch) in epochs {
        assert!(
            epoch != 0 && epoch < (1u64 << 53),
            "the {name} epoch {epoch} must be nonzero and below 2^53 (a JSON reader holds it exactly)"
        );
        assert_eq!(
            epoch, epochs[0].1,
            "one daemon run, one epoch, on {name} too"
        );
    }
    // It is a JSON number on the wire.
    assert!(
        wire(&on_unix)
            .iter()
            .any(|f| ty(f) == "welcome" && f["seq_epoch"].as_u64() == Some(epochs[0].1)),
        "seq_epoch is a plain number in the Welcome: {:?}",
        on_unix.raw
    );
    // Fixed for the life of the daemon.
    let later = local(&rig, &[], &[]).await;
    assert_eq!(epoch_of(&later), epochs[0].1);

    // Another run (another daemon) has another.
    let other = Rig::new().await;
    let on_other = local(&other, &[], &[]).await;
    assert_ne!(
        epoch_of(&on_other),
        epochs[0].1,
        "two daemons must not share an epoch, or a restart could not be told from a reconnect"
    );
}

#[tokio::test]
async fn a_resume_naming_this_daemons_epoch_replays_the_missed_frames_as_before() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    let back = local_under(
        &rig,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 2)],
        Epoch::Echo,
    )
    .await;
    let frames = of(&back, "mother_jobs");
    assert_eq!(
        frames.iter().filter_map(number).collect::<Vec<_>>(),
        range(3, 5)
    );
    assert_eq!(frames.len(), 3, "and no retained snapshot on top");
    assert!(gaps(&back).is_empty(), "the ring covered it: no Gap");
}

#[tokio::test]
async fn a_resume_with_no_epoch_is_compared_by_its_numbers_as_it_always_was() {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    let back = local_under(
        &rig,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 2)],
        Epoch::Absent,
    )
    .await;
    assert_eq!(seqs_of(&back, "mother_jobs"), range(3, 5));
    assert!(gaps(&back).is_empty());

    // And a number the ring does not reach is a Gap for the ring's usual reason.
    let ahead = local_under(
        &rig,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 9999)],
        Epoch::Absent,
    )
    .await;
    let g = gaps(&ahead);
    assert_eq!(g.len(), 1);
    assert_eq!(g[0].reason, GapReason::ReplayWindowExceeded);
}

/// Whatever numbers a client holds, if they were given by another run of the
/// daemon nothing is replayed: each resumed topic gets its retained snapshot
/// and exactly one `Gap { daemon_restarted }`.
#[tokio::test]
async fn a_resume_naming_another_daemon_run_gets_each_topics_snapshot_one_daemon_restarted_gap_and_no_replay(
) {
    let rig = Rig::new().await;
    publish(
        &rig.server,
        (1..=5)
            .map(|i| jobs_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    publish(
        &rig.server,
        (1..=3).map(|_| focuses_frame(Some("kobe"))).collect(),
    )
    .await;
    let phone = rig.mint_device("phone");
    let probe = local(&rig, &[], &[]).await;
    let foreign = epoch_of(&probe) ^ 1;
    assert_ne!(foreign, epoch_of(&probe));

    // Numbers below, at, and above this daemon's latest (5 and 3), and 0.
    for (jobs_after, focuses_after) in [(2, 1), (5, 3), (9999, 9999), (0, 0)] {
        let resume = [
            (Topic::MotherJobs, jobs_after),
            (Topic::Focuses, focuses_after),
        ];
        let topics = [Topic::MotherJobs, Topic::Focuses];
        let client = local_under(&rig, &topics, &resume, Epoch::Is(foreign)).await;
        let what = format!("resuming from {resume:?} under another run's epoch");
        assert!(
            numbered(&client).is_empty(),
            "{what}: nothing may be replayed from this run's rings: {:?}",
            client.raw
        );
        let snapshots = of(&client, "mother_jobs");
        assert_eq!(snapshots.len(), 1, "{what}: the retained snapshot, once");
        assert_eq!(marker(&snapshots[0]), "a5", "{what}: the latest state");
        assert_eq!(
            of(&client, "focus_registry_updated").len(),
            1,
            "{what}: the focuses snapshot, once"
        );
        let found = gaps(&client);
        assert_eq!(
            found.len(),
            2,
            "{what}: one Gap per resumed topic: {found:?}"
        );
        for (topic, latest) in [(Topic::MotherJobs, 5), (Topic::Focuses, 3)] {
            let named: Vec<&Gap> = found.iter().filter(|g| g.topic == topic).collect();
            assert_eq!(named.len(), 1, "{what}: exactly one Gap names {topic:?}");
            assert_eq!(named[0].reason, GapReason::DaemonRestarted, "{what}");
            assert!(named[0].from <= named[0].to, "{what}: {:?}", named[0]);
            assert_eq!(
                (named[0].from, named[0].to),
                (1, latest),
                "{what}: all of this run's numbers are news to the client"
            );
        }
        assert!(
            !found
                .iter()
                .any(|g| g.reason == GapReason::ReplayWindowExceeded),
            "{what}: the ring was not the reason"
        );
        let last_snapshot = ["mother_jobs", "focus_registry_updated"]
            .iter()
            .map(|t| first_index(&client, t).unwrap())
            .max()
            .unwrap();
        assert!(
            last_snapshot < first_index(&client, "gap").unwrap(),
            "{what}: the snapshots come before the Gaps"
        );
    }

    // A paired device is held to it as well (it has no `Withheld` surprise: the
    // resumed topics get their Gap, and no numbered frame).
    let device = paired_under(
        &rig,
        &phone.token,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 2)],
        Epoch::Is(foreign),
    )
    .await;
    assert!(numbered(&device).is_empty(), "{:?}", device.raw);
    let found = gaps(&device);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].reason, GapReason::DaemonRestarted);
    assert_eq!((found[0].from, found[0].to), (1, 5));
}

/// The case the epoch exists for: a daemon restarted, and (by chance) has
/// numbered the topic to just where the client was, below it, or above it.
/// By numbers alone the client would be "covered" (and its snapshot withheld),
/// or told it was ahead, or replayed frames that are not the ones it missed.
async fn a_client_of_one_daemon_run_resumes_on_another_that_numbered_perri_to(published_on_b: u64) {
    let a = Rig::new().await;
    let b = Rig::new().await;

    // Under daemon A the client was numbered `perri` 1..=3.
    let mut first = local(&a, &[Topic::Perri], &[]).await;
    publish(
        &a.server,
        (1..=3)
            .map(|i| perri_frame(&format!("a{i}"), Some("kobe")))
            .collect(),
    )
    .await;
    read_n(&mut first, 3, is_perri).await;
    assert_eq!(seqs_of(&first, "perri_state"), range(1, 3));
    let epoch_a = epoch_of(&first);
    drop(first);

    // Daemon B, started afresh, has published its own frames, and retains the
    // latest as its snapshot.
    publish(
        &b.server,
        (1..=published_on_b)
            .map(|i| perri_frame(&format!("b{i}"), Some("kobe")))
            .collect(),
    )
    .await;

    let back = local_under(
        &b,
        &[Topic::Perri],
        &[(Topic::Perri, 3)],
        Epoch::Is(epoch_a),
    )
    .await;
    assert_ne!(epoch_of(&back), epoch_a, "two daemons, two epochs");
    let what = format!("B numbered perri to {published_on_b}, the client to 3");
    assert!(
        numbered(&back).is_empty(),
        "{what}: no frame of B's may be replayed as if the client had missed it: {:?}",
        back.raw
    );
    let snapshots = of(&back, "perri_state");
    assert_eq!(
        snapshots.len(),
        1,
        "{what}: the snapshot is sent, never withheld: {:?}",
        back.raw
    );
    assert_eq!(
        snapshots[0]["jira_site"].as_str(),
        Some(format!("b{published_on_b}").as_str()),
        "{what}: B's latest state"
    );
    let found = gaps(&back);
    assert_eq!(found.len(), 1, "{what}: exactly one Gap: {found:?}");
    assert_eq!(found[0].topic, Topic::Perri);
    assert_eq!(found[0].reason, GapReason::DaemonRestarted, "{what}");
    assert!(found[0].from <= found[0].to);
    assert_eq!((found[0].from, found[0].to), (1, published_on_b), "{what}");

    if published_on_b == 3 {
        // What the epoch is for: without it these numbers look like "caught up",
        // so nothing would be sent and the client would show A's state.
        let blind = local_under(&b, &[Topic::Perri], &[(Topic::Perri, 3)], Epoch::Absent).await;
        assert!(
            of(&blind, "perri_state").is_empty() && gaps(&blind).is_empty(),
            "a client that names no epoch is compared by numbers alone, as it always was: {:?}",
            blind.raw
        );
    }
}

#[tokio::test]
async fn after_a_daemon_restart_a_client_whose_perri_number_equals_the_new_daemons_latest_still_gets_the_snapshot_and_a_gap(
) {
    a_client_of_one_daemon_run_resumes_on_another_that_numbered_perri_to(3).await;
}

#[tokio::test]
async fn after_a_daemon_restart_a_client_whose_perri_number_is_above_the_new_daemons_latest_gets_the_snapshot_and_a_gap(
) {
    a_client_of_one_daemon_run_resumes_on_another_that_numbered_perri_to(2).await;
}

#[tokio::test]
async fn after_a_daemon_restart_a_client_whose_perri_number_is_below_the_new_daemons_latest_is_not_replayed_the_wrong_frames(
) {
    a_client_of_one_daemon_run_resumes_on_another_that_numbered_perri_to(7).await;
}

// ════════════════════════════════════════════════════════════════════════════
// A Gap never runs backwards
// ════════════════════════════════════════════════════════════════════════════

/// Each case: frames the topic has published, the number the client names, and
/// whether it names another daemon run's epoch. Whatever the case, the one Gap
/// has `from <= to` and ends at the topic's latest number.
#[tokio::test]
async fn a_gap_never_runs_backwards_and_always_ends_at_the_topics_latest_number() {
    // (published, after, foreign epoch, expected (from, to), expected reason)
    type Case = (u64, u64, bool, (u64, u64), GapReason);
    let cases: [Case; 11] = [
        // a client from before a restart, and the topic has said nothing yet
        (0, 5, false, (0, 0), GapReason::ReplayWindowExceeded),
        (0, 0, true, (0, 0), GapReason::DaemonRestarted),
        (0, 5, true, (0, 0), GapReason::DaemonRestarted),
        // from the future of a topic that has published
        (5, 6, false, (1, 5), GapReason::ReplayWindowExceeded),
        (5, 9, false, (1, 5), GapReason::ReplayWindowExceeded),
        // another run's numbers: below, at, above, and zero
        (5, 2, true, (1, 5), GapReason::DaemonRestarted),
        (5, 5, true, (1, 5), GapReason::DaemonRestarted),
        (5, 9, true, (1, 5), GapReason::DaemonRestarted),
        (5, 0, true, (1, 5), GapReason::DaemonRestarted),
        // evicted from the window (the ring keeps 1000)
        (1002, 1, false, (2, 1002), GapReason::ReplayWindowExceeded),
        (
            1002,
            5000,
            false,
            (1, 1002),
            GapReason::ReplayWindowExceeded,
        ),
    ];
    for (published, after, foreign, expected, reason) in cases {
        let rig = Rig::new().await;
        publish(
            &rig.server,
            (0..published).map(|_| tiny_jobs_frame(None)).collect(),
        )
        .await;
        let probe = local(&rig, &[], &[]).await;
        let epoch = if foreign {
            Epoch::Is(epoch_of(&probe) ^ 1)
        } else {
            Epoch::Absent
        };
        let client = local_under(
            &rig,
            &[Topic::MotherJobs],
            &[(Topic::MotherJobs, after)],
            epoch,
        )
        .await;
        let what = format!(
            "{published} published, the client at {after}, {}",
            if foreign {
                "another run's epoch"
            } else {
                "no epoch"
            }
        );
        let found = gaps(&client);
        assert_eq!(found.len(), 1, "{what}: exactly one Gap: {found:?}");
        let g = &found[0];
        assert!(g.from <= g.to, "{what}: a Gap runs backwards: {g:?}");
        assert_eq!(
            g.to, published,
            "{what}: it ends at the topic's latest: {g:?}"
        );
        assert_eq!((g.from, g.to), expected, "{what}");
        assert_eq!(g.reason, reason, "{what}");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// A resume replays at most so many bytes
// ════════════════════════════════════════════════════════════════════════════

/// Bytes of serialized frames one resume may have replayed to a network peer,
/// and to a local client.
const SPEC_RESUME_BUDGET_NETWORK: usize = 4 * 1024 * 1024;
const SPEC_RESUME_BUDGET_LOCAL: usize = 16 * 1024 * 1024;

#[test]
fn the_documented_resume_budgets_are_the_contract() {
    assert_eq!(seq::RESUME_BUDGET_NETWORK, SPEC_RESUME_BUDGET_NETWORK);
    assert_eq!(seq::RESUME_BUDGET_LOCAL, SPEC_RESUME_BUDGET_LOCAL);
}

const MIB: usize = 1024 * 1024;

#[tokio::test]
async fn a_paired_device_resuming_past_4_mib_of_replay_gets_the_snapshot_and_one_gap_and_no_frames()
{
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    // Five frames of 1 MiB: all five stay in the 8 MiB ring, and they are
    // more than a network peer is replayed in one resume.
    publish(&rig.server, jobs_frames_each(5, MIB, Some("kobe"))).await;
    assert_eq!(
        rig.server.seq().usage().frames,
        5,
        "the ring holds them all"
    );

    let device = paired(
        &rig,
        &phone.token,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 0)],
    )
    .await;
    assert!(
        numbered(&device).is_empty(),
        "no replayed frame: {} frames came",
        numbered(&device).len()
    );
    let snapshots = of(&device, "mother_jobs");
    assert_eq!(snapshots.len(), 1, "the retained snapshot, once");
    assert_eq!(marker(&snapshots[0]), "m5", "the latest state");
    let found = gaps(&device);
    assert_eq!(found.len(), 1, "exactly one Gap: {found:?}");
    assert_eq!(found[0].reason, GapReason::ReplayWindowExceeded);
    assert_eq!((found[0].from, found[0].to), (1, 5));
    assert!(
        first_index(&device, "mother_jobs") < first_index(&device, "gap"),
        "the snapshot comes first"
    );
}

#[tokio::test]
async fn a_local_client_is_replayed_the_same_5_mib_in_full() {
    let rig = Rig::new().await;
    publish(&rig.server, jobs_frames_each(5, MIB, Some("kobe"))).await;
    let mac = local(&rig, &[Topic::MotherJobs], &[(Topic::MotherJobs, 0)]).await;
    assert_eq!(seqs_of(&mac, "mother_jobs"), range(1, 5));
    assert_eq!(of(&mac, "mother_jobs").len(), 5, "and no snapshot on top");
    assert!(gaps(&mac).is_empty());
}

/// The budget is `RESUME_BUDGET_NETWORK` bytes of serialized frames: exactly
/// that is replayed, one byte more is a snapshot and a Gap.
#[tokio::test]
async fn a_resume_of_exactly_4_mib_is_replayed_and_one_byte_more_is_not() {
    let phone_of = |rig: &Rig| rig.mint_device("phone");

    // Four frames of exactly 1 MiB: 4 MiB in all.
    let rig = Rig::new().await;
    let phone = phone_of(&rig);
    publish(&rig.server, jobs_frames_each(4, MIB, Some("kobe"))).await;
    let at = paired(
        &rig,
        &phone.token,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 0)],
    )
    .await;
    assert_eq!(
        seqs_of(&at, "mother_jobs"),
        range(1, 4),
        "exactly at the budget: replayed"
    );
    assert!(gaps(&at).is_empty());

    // The same with the last frame one byte longer.
    let rig = Rig::new().await;
    let phone = phone_of(&rig);
    let mut frames = jobs_frames_each(3, MIB, Some("kobe"));
    let base = serialized_len(&big_jobs_frame("m4", 0, Some("kobe")));
    let last = big_jobs_frame("m4", MIB - base + 1, Some("kobe"));
    assert_eq!(serialized_len(&last), MIB + 1);
    frames.push(last);
    publish(&rig.server, frames).await;
    let over = paired(
        &rig,
        &phone.token,
        &[Topic::MotherJobs],
        &[(Topic::MotherJobs, 0)],
    )
    .await;
    assert!(
        numbered(&over).is_empty(),
        "one byte over the budget: no frame is replayed: {:?}",
        numbered(&over)
    );
    let found = gaps(&over);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].reason, GapReason::ReplayWindowExceeded);
}

/// The budget is for the whole resume, not for each topic.
#[tokio::test]
async fn the_network_budget_is_shared_across_the_topics_of_one_resume() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    // Each topic holds about 3 MiB (under the 4 MiB budget); together, 6.
    publish(&rig.server, jobs_frames_each(3, MIB, None)).await;
    publish(
        &rig.server,
        (1..=3)
            .map(|i| notification("proj", &format!("{i}{}", "y".repeat(MIB))))
            .collect(),
    )
    .await;

    let device = paired(
        &rig,
        &phone.token,
        &[Topic::MotherJobs, Topic::Layout],
        &[(Topic::MotherJobs, 0), (Topic::Layout, 0)],
    )
    .await;
    let found = gaps(&device);
    assert_eq!(
        found.len(),
        1,
        "exactly one of the two topics fell back to a Gap: {found:?}"
    );
    assert_eq!(found[0].reason, GapReason::ReplayWindowExceeded);
    let (replayed, fell_back) = if found[0].topic == Topic::MotherJobs {
        ("notification", "mother_jobs")
    } else {
        ("mother_jobs", "notification")
    };
    assert_eq!(
        seqs_of(&device, replayed),
        range(1, 3),
        "the other topic was replayed in full"
    );
    assert!(
        seqs_of(&device, fell_back).is_empty(),
        "the topic that went over has no replayed frame"
    );
}

#[tokio::test]
async fn the_local_budget_is_16_mib_for_the_whole_resume() {
    let rig = Rig::new().await;
    // Three topics of about 6 MiB each (each under the ring's 8 MiB): 18 MiB.
    let each = 2 * MIB;
    publish(&rig.server, jobs_frames_each(3, each, None)).await;
    publish(
        &rig.server,
        (1..=3)
            .map(|i| notification("proj", &format!("{i}{}", "y".repeat(each))))
            .collect(),
    )
    .await;
    publish(
        &rig.server,
        (1..=3).map(|i| big_activity(i, each)).collect(),
    )
    .await;

    let topics = [Topic::MotherJobs, Topic::Layout, Topic::Activity];
    let mac = local(
        &rig,
        &topics,
        &[
            (Topic::MotherJobs, 0),
            (Topic::Layout, 0),
            (Topic::Activity, 0),
        ],
    )
    .await;
    let found = gaps(&mac);
    assert_eq!(
        found.len(),
        1,
        "18 MiB is over the 16 MiB budget: exactly one topic falls back: {found:?}"
    );
    assert_eq!(found[0].reason, GapReason::ReplayWindowExceeded);
    let counts = [
        (Topic::MotherJobs, seqs_of(&mac, "mother_jobs").len()),
        (Topic::Layout, seqs_of(&mac, "notification").len()),
        (Topic::Activity, seqs_of(&mac, "activity").len()),
    ];
    for (topic, count) in counts {
        let expected = if topic == found[0].topic { 0 } else { 3 };
        assert_eq!(
            count, expected,
            "{topic:?}: the topic that went over has no replayed frame, the others all three"
        );
    }
}

// ════════════════════════════════════════════════════════════════════════════
// A local client that cannot be sent a frame with no topic is closed
// ════════════════════════════════════════════════════════════════════════════

fn is_error_named(label: &'static str) -> impl Fn(&ServerMsg) -> bool {
    move |m| matches!(m, ServerMsg::Error { message } if message == label)
}

/// A frame with no topic (an approval, a reply) is in no Gap, so a local client
/// that could not be sent one is closed rather than left wrong; it reconnects
/// and is replayed what it needs. Nobody else is affected.
#[tokio::test]
async fn a_stalled_local_client_that_cannot_be_sent_a_frame_with_no_topic_is_closed_and_nobody_else_is_affected(
) {
    let mut s = stalled_client(600, 0).await;
    s.rig.server.broadcast(ServerMsg::Error {
        message: "for-everyone".into(),
    });
    settle().await;

    // The others are served as ever.
    s.fast
        .next_matching("the frame with no topic", is_error_named("for-everyone"))
        .await;
    let mut newcomer = local(&s.rig, &[Topic::Perri], &[]).await;
    newcomer.sync().await;
    assert!(s.fast.closed.is_none());

    // The stalled one is closed (it reads what was already on its way, then EOF).
    s.slow.expect_close_within(Duration::from_secs(20)).await;
    let last_seen = *seqs_of(&s.slow, "mother_jobs")
        .last()
        .expect("it was sent some frames before it was closed");

    // A fresh connection is fine, and is replayed what the closed one missed.
    let again = local(
        &s.rig,
        &[Topic::MotherJobs, Topic::Focuses],
        &[(Topic::MotherJobs, last_seen)],
    )
    .await;
    assert_eq!(
        seqs_of(&again, "mother_jobs"),
        range(last_seen + 1, s.jobs_published),
        "the reconnect gets everything after the last number the old connection saw"
    );
    assert!(gaps(&again).is_empty());
}

/// The same when it is frames with no topic that fill the queue.
#[tokio::test]
async fn a_local_client_whose_queue_fills_with_frames_that_have_no_topic_is_closed() {
    let rig = Rig::new().await;
    let mut slow = local(&rig, &[Topic::MotherJobs], &[]).await;
    publish(
        &rig.server,
        (0..BLOCKERS)
            .map(|i| big_jobs_frame(&format!("blocker-{i}"), BLOCKER_BYTES, None))
            .collect(),
    )
    .await;
    flood_without_topic(&rig.server, 300, "nt").await;

    slow.expect_close_within(Duration::from_secs(20)).await;
    assert!(
        errors_labelled(&slow, "nt") < 300,
        "it was closed, not sent all of them"
    );

    let mut newcomer = local(&rig, &[Topic::Perri], &[]).await;
    newcomer.sync().await;
}

/// A network peer keeps the Gap policy: a frame with no topic that does not fit
/// is dropped (it is nothing a network peer needs to be told about) and the
/// connection stays.
#[tokio::test]
async fn a_stalled_paired_device_is_not_closed_when_a_frame_with_no_topic_cannot_be_queued() {
    let mut s = stalled_client_on(Transport::Paired, 600, 0).await;
    s.rig.server.broadcast(ServerMsg::Error {
        message: "for-everyone".into(),
    });
    settle().await;

    drain_slow(&mut s, 1).await;
    settle().await;
    s.slow.sync().await;
    assert!(
        s.slow.closed.is_none(),
        "a network peer is told with a Gap, not closed"
    );
    assert!(s.slow.closed.is_none());
    let found = gaps(&s.slow);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].topic, Topic::MotherJobs);
    assert_eq!(found[0].reason, GapReason::ClientSlow);
}

#[tokio::test]
async fn a_paired_device_whose_queue_fills_with_frames_that_have_no_topic_stays_connected() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let mut slow = paired(&rig, &phone.token, &[Topic::MotherJobs], &[]).await;
    publish(
        &rig.server,
        (0..Transport::Paired.blockers())
            .map(|i| big_jobs_frame(&format!("blocker-{i}"), BLOCKER_BYTES, None))
            .collect(),
    )
    .await;
    flood_without_topic(&rig.server, 300, "nt").await;

    slow.sync().await;
    // A connection that is going to be closed is closed once its main loop is
    // back from answering that Ping: give it that, then ask again.
    settle().await;
    slow.sync().await;
    assert!(slow.closed.is_none(), "not closed");
    let got = errors_labelled(&slow, "nt");
    assert!(
        got > 0 && got < 300,
        "{got} of 300 frames with no topic were queued: some were dropped (or the \
         client was never stalled, which proves nothing)"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// Frames the daemon lost before numbering them
// ════════════════════════════════════════════════════════════════════════════

/// Each connection is told, once per topic *it follows*, that a number was
/// skipped; the Gap names exactly that number; and the topic's numbers go on
/// from it.
#[tokio::test]
async fn frames_lost_before_they_were_numbered_are_told_to_each_connection_once_per_followed_topic()
{
    let rig = Rig::new().await;
    let phone = rig.mint_device("phone");
    let mut a = local(&rig, &[Topic::MotherJobs, Topic::Focuses], &[]).await;
    let mut b = paired(&rig, &phone.token, &[Topic::Perri], &[]).await;
    let mut c = local(&rig, &[], &[]).await; // everything (but `model`, which is named)
    let mut d = local(&rig, &[Topic::Model, Topic::Fred], &[]).await;

    publish(
        &rig.server,
        vec![
            jobs_frame("j1", None),
            jobs_frame("j2", None),
            jobs_frame("j3", None),
            focuses_frame(None),
            focuses_frame(None),
            perri_frame("p1", None),
        ],
    )
    .await;
    for conn in [&mut a, &mut b, &mut c, &mut d] {
        conn.sync().await;
    }
    let before: BTreeMap<Topic, u64> = numbered_topics()
        .into_iter()
        .map(|t| {
            let n = rig.server.seq().latest(&t);
            (t, n)
        })
        .collect();
    assert_eq!(before[&Topic::MotherJobs], 3);
    assert_eq!(before[&Topic::Fred], 0, "a topic that published nothing");

    rig.server.seq().lost_frames();
    for conn in [&mut a, &mut b, &mut c, &mut d] {
        conn.sync().await;
    }

    let everything_but_model: Vec<Topic> = numbered_topics()
        .into_iter()
        .filter(|t| *t != Topic::Model)
        .collect();
    let followed_by = [
        (
            "a: mother_jobs, focuses",
            vec![Topic::MotherJobs, Topic::Focuses],
        ),
        ("b: perri (paired)", vec![Topic::Perri]),
        ("c: everything", everything_but_model),
        ("d: model, fred", vec![Topic::Model, Topic::Fred]),
    ];
    for ((who, followed), conn) in followed_by.iter().zip([&a, &b, &c, &d]) {
        let found = gaps(conn);
        let mut told: Vec<Topic> = found.iter().map(|g| g.topic.clone()).collect();
        told.sort();
        let mut want = followed.clone();
        want.sort();
        assert_eq!(
            told, want,
            "{who}: exactly one Gap for each topic it follows, and none for the others: {found:?}"
        );
        for g in &found {
            assert_eq!(g.reason, GapReason::Lagged, "{who}: {g:?}");
            assert_eq!(g.host, None);
            let skipped = before[&g.topic] + 1;
            assert_eq!(
                (g.from, g.to),
                (skipped, skipped),
                "{who}: the Gap names the one number {:?} skipped",
                g.topic
            );
        }
    }

    // The topics go on from the skipped number, and nothing at or below a Gap's
    // end follows it.
    publish(
        &rig.server,
        vec![
            jobs_frame("j4", None),
            focuses_frame(None),
            perri_frame("p2", None),
        ],
    )
    .await;
    for conn in [&mut a, &mut b, &mut c, &mut d] {
        conn.sync().await;
    }
    assert_eq!(seqs_of(&a, "mother_jobs"), vec![1, 2, 3, 5]);
    assert_eq!(seqs_of(&a, "focus_registry_updated"), vec![1, 2, 4]);
    assert_eq!(seqs_of(&b, "perri_state"), vec![1, 3]);
    assert_eq!(seqs_of(&c, "mother_jobs"), vec![1, 2, 3, 5]);
    assert_eq!(seqs_of(&c, "perri_state"), vec![1, 3]);
    for ((who, _), conn) in followed_by.iter().zip([&a, &b, &c, &d]) {
        for g in gaps(conn) {
            let frame_type = match g.topic {
                Topic::MotherJobs => "mother_jobs",
                Topic::Focuses => "focus_registry_updated",
                Topic::Perri => "perri_state",
                _ => continue, // nothing of these was published after the Gap
            };
            let at = wire(conn)
                .iter()
                .position(|f| ty(f) == "gap" && f["topic"] == json!(g.topic))
                .unwrap();
            let after: Vec<u64> = wire(conn)
                .iter()
                .skip(at + 1)
                .filter(|f| ty(f) == frame_type)
                .filter_map(number)
                .collect();
            assert_eq!(
                after,
                vec![g.to + 1],
                "{who}: after the Gap for {:?} the next number is the one after its end",
                g.topic
            );
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// The `client_slow` Gap is queued in order
// ════════════════════════════════════════════════════════════════════════════

/// A client stalls (it reads nothing while the daemon publishes enough to fill
/// its queue), then reads again while the daemon keeps publishing (several
/// frames for every one it reads, so frames are arriving at the very moment its
/// queue drains). On its wire the frames and the `Gap`s must partition the
/// numbers in order: each delivered frame is the next number, a Gap starts at
/// the next number and names exactly the ones that were dropped, and no
/// later-numbered frame comes before it.
///
/// Whether a frame arrives before or after the queue's "drained" signal is a
/// race, so the stall and the recovery are repeated: a Gap queued after a frame
/// that is numbered above it would show in one of the rounds.
#[tokio::test]
async fn the_client_slow_gap_is_queued_in_order_between_the_frames_before_it_and_the_frames_after_it(
) {
    const ROUNDS: u64 = 10;
    const PUBLISHED_PER_READ: u64 = 3;
    const EXTRA_PER_ROUND: u64 = 450;

    let rig = Rig::new().await;
    let mut slow = local(&rig, &[Topic::MotherJobs], &[]).await;
    let mut published = 0u64;
    for round in 0..ROUNDS {
        // The stall: the writer waits on the socket, then the queue fills.
        publish(
            &rig.server,
            (0..BLOCKERS)
                .map(|i| big_jobs_frame(&format!("blocker-{round}-{i}"), BLOCKER_BYTES, None))
                .collect(),
        )
        .await;
        published += BLOCKERS;
        publish(
            &rig.server,
            (0..600)
                .map(|i| jobs_frame(&format!("s{round}-{i}"), None))
                .collect(),
        )
        .await;
        published += 600;

        // It reads again; the daemon goes on publishing.
        let target = published + EXTRA_PER_ROUND;
        let mut extra = 0u64;
        let mut covered = 0u64;
        while covered < target {
            for _ in 0..PUBLISHED_PER_READ {
                if extra < EXTRA_PER_ROUND {
                    extra += 1;
                    rig.server
                        .broadcast(jobs_frame(&format!("x{round}-{extra}"), None));
                }
            }
            slow.next_matching("a frame or a Gap", |_| true).await;
            let last: Value = serde_json::from_str(slow.raw.last().unwrap()).unwrap();
            match ty(&last) {
                "mother_jobs" => covered = covered.max(number(&last).unwrap()),
                "gap" => covered = covered.max(last["to"].as_u64().unwrap()),
                _ => {}
            }
        }
        published = target;
    }

    let mut next = 1u64;
    let mut gap_count = 0;
    for frame in wire(&slow) {
        match ty(&frame) {
            "mother_jobs" => {
                let n = number(&frame).unwrap();
                assert_eq!(
                    n, next,
                    "frame {n} arrived where {next} was due (a frame must not overtake \
                     the Gap that names the numbers before it)"
                );
                next = n + 1;
            }
            "gap" => {
                gap_count += 1;
                let (from, to) = (
                    frame["from"].as_u64().unwrap(),
                    frame["to"].as_u64().unwrap(),
                );
                assert_eq!(from, next, "a Gap starts at the first number not delivered");
                assert!(from <= to);
                next = to + 1;
            }
            _ => {}
        }
    }
    assert_eq!(
        next,
        published + 1,
        "every number was delivered or named by a Gap"
    );
    assert!(
        gap_count >= ROUNDS as usize,
        "the client stalled in every round, so each has a Gap ({gap_count})"
    );
    assert_eq!(rig.server.seq().lag_count(), 0);
}
