//! Per-topic sequence numbers, the replay ring and the bounded client queue's
//! drop log (W12, `docs/plans/backplane-sequencing.md`).
//!
//! Every frame a producer puts on the daemon's broadcast channel enters
//! [`SeqHub::publish`] through the *sequencer task* (see
//! [`spawn_sequencer`]): the one place a topic-bearing frame ([`ServerMsg::topic`])
//! is numbered (strictly increasing per topic, starting at 1, for the daemon's
//! lifetime), kept in the topic's [`ReplayRing`] and handed on to the stamped
//! channel the client connections read. A frame from a satellite is the
//! primary's like any other: it is numbered in its topic, whatever its `host`
//! says, and keeps its per-host retained key.
//!
//! The number rides on the wire as a top-level `"seq"` key
//! ([`encode_with_seq`]); `ServerMsg::Activity` already has a `seq` of its own
//! (the per-stream counter), so its topic number is `"topic_seq"` instead
//! ([`seq_key`]).
//!
//! A client that sends `Subscribe.resume` gets what its topic published after
//! the number it names ([`SeqHub::replay`]), or, when the ring no longer
//! reaches back that far, the retained snapshot and a `Gap`.
//!
//! The rings hold frames *before* any peer's trust filter. A replay goes
//! through the same `peer::outbound` gate as the live path, so a ring can
//! never hand a peer what it would not have been sent live. The rings are in
//! memory only: a daemon restart starts every topic again at 1, and a client
//! that resumes from a higher number is told so with a `Gap`.

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tracing::warn;

use super::protocol::{GapReason, ReplayUsage, ServerMsg, Topic};

/// The `Welcome.features` entry of a daemon that numbers its topics and
/// honours `Subscribe.resume`.
pub const FEATURE_SEQ: &str = "seq";

/// Frames one topic's ring keeps, whichever limit is reached first.
pub const MAX_RING_MSGS: usize = 1000;
/// Bytes (of the serialized frames) one topic's ring keeps.
pub const MAX_RING_BYTES: usize = 8 * 1024 * 1024;

/// Frames a connection's outbound queue holds before it starts dropping.
pub const CLIENT_QUEUE_CAP: usize = 256;
/// A dropped range is reported as a `Gap` once the queue is below this.
pub const CLIENT_QUEUE_RESUME_BELOW: usize = CLIENT_QUEUE_CAP / 2;

/// Capacity of the stamped broadcast channel.
const STAMPED_CHANNEL_CAP: usize = 512;

/// A broadcast frame with the number its topic gave it (`None`: the frame has
/// no topic, or was not numbered, and goes out as it is).
#[derive(Debug, Clone)]
pub struct Stamped {
    pub seq: Option<u64>,
    pub msg: ServerMsg,
}

impl Stamped {
    pub fn unsequenced(msg: ServerMsg) -> Self {
        Self { seq: None, msg }
    }
}

/// The JSON key a frame's topic number is written under: `"seq"`, except for
/// `activity`, whose own per-stream `seq` is already on the wire.
pub fn seq_key(msg: &ServerMsg) -> &'static str {
    match msg {
        ServerMsg::Activity(_) => "topic_seq",
        _ => "seq",
    }
}

/// The frame as JSON, with its topic number added when it has one.
pub fn encode_with_seq(msg: &ServerMsg, seq: Option<u64>) -> serde_json::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(msg)?;
    if let Some(seq) = seq {
        // Every `ServerMsg` is an object (`{"type": …}`), so it ends in `}`.
        if bytes.last() == Some(&b'}') {
            bytes.pop();
            bytes.extend_from_slice(format!(",\"{}\":{seq}}}", seq_key(msg)).as_bytes());
        }
    }
    Ok(bytes)
}

// ── numbering ────────────────────────────────────────────────────────────────

/// The last number given to each topic.
#[derive(Debug, Default)]
pub struct SeqStamper {
    last: BTreeMap<Topic, u64>,
}

impl SeqStamper {
    /// The next number of `topic` (the first is 1).
    pub fn next(&mut self, topic: &Topic) -> u64 {
        let n = self.last.entry(topic.clone()).or_insert(0);
        *n += 1;
        *n
    }

    /// The last number given to `topic` (0: none yet).
    pub fn last(&self, topic: &Topic) -> u64 {
        self.last.get(topic).copied().unwrap_or(0)
    }

    /// Skip one number on every topic, so a frame lost before it was numbered
    /// shows as a jump rather than being invisible.
    fn skip_all(&mut self) {
        for n in self.last.values_mut() {
            *n += 1;
        }
    }
}

// ── the ring ─────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct RingEntry {
    seq: u64,
    size: usize,
    msg: ServerMsg,
}

/// The newest frames of one topic, bounded by count and by serialized size.
#[derive(Debug)]
pub struct ReplayRing {
    frames: VecDeque<RingEntry>,
    bytes: usize,
    max_msgs: usize,
    max_bytes: usize,
}

impl ReplayRing {
    pub fn with_limits(max_msgs: usize, max_bytes: usize) -> Self {
        Self {
            frames: VecDeque::new(),
            bytes: 0,
            max_msgs,
            max_bytes,
        }
    }

    /// Keep `msg` (numbered `seq`, `size` bytes serialized), dropping the
    /// oldest frames until both limits hold again. A frame larger than the
    /// byte limit is not kept at all.
    pub fn push(&mut self, seq: u64, size: usize, msg: ServerMsg) {
        self.frames.push_back(RingEntry { seq, size, msg });
        self.bytes += size;
        while self.frames.len() > self.max_msgs || self.bytes > self.max_bytes {
            match self.frames.pop_front() {
                Some(old) => self.bytes -= old.size,
                None => break,
            }
        }
    }

    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    pub fn bytes(&self) -> usize {
        self.bytes
    }

    fn clear(&mut self) {
        self.frames.clear();
        self.bytes = 0;
    }

    /// What a client that last saw `after` (of a topic whose last number is
    /// `latest`) missed, or why that is not known any more.
    pub fn replay(&self, after: u64, latest: u64) -> Replay {
        // The first number the ring would have to hold.
        let oldest = self.frames.front().map_or(latest + 1, |e| e.seq);
        if after > latest || after + 1 < oldest {
            return Replay::Exceeded { oldest, latest };
        }
        Replay::Messages(
            self.frames
                .iter()
                .filter(|e| e.seq > after)
                .map(|e| Stamped {
                    seq: Some(e.seq),
                    msg: e.msg.clone(),
                })
                .collect(),
        )
    }
}

/// The answer to a resume.
#[derive(Debug)]
pub enum Replay {
    /// Everything numbered after the client's number, in order (possibly none).
    Messages(Vec<Stamped>),
    /// The ring does not reach back to the client's number (or the client's
    /// number is from before a daemon restart). `oldest` is the first number
    /// the ring could serve, `latest` the topic's last.
    Exceeded { oldest: u64, latest: u64 },
}

// ── the hub ──────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct HubState {
    stamper: SeqStamper,
    rings: BTreeMap<Topic, ReplayRing>,
}

/// Numbers and keeps every topic-bearing frame, and fans the numbered frames
/// out. One per daemon.
#[derive(Debug)]
pub struct SeqHub {
    state: Mutex<HubState>,
    out: broadcast::Sender<Stamped>,
    max_msgs: usize,
    max_bytes: usize,
    /// How often a connection's receiver fell behind the stamped channel.
    lagged: AtomicU64,
}

impl SeqHub {
    pub fn new() -> Arc<Self> {
        Self::with_limits(MAX_RING_MSGS, MAX_RING_BYTES)
    }

    pub fn with_limits(max_msgs: usize, max_bytes: usize) -> Arc<Self> {
        let (out, _) = broadcast::channel(STAMPED_CHANNEL_CAP);
        Arc::new(Self {
            state: Mutex::new(HubState {
                stamper: SeqStamper::default(),
                rings: BTreeMap::new(),
            }),
            out,
            max_msgs,
            max_bytes,
            lagged: AtomicU64::new(0),
        })
    }

    /// A receiver of the numbered frames. Subscribe *before* asking for a
    /// replay, so nothing published in between is missed (a frame in both is
    /// dropped by its number).
    pub fn subscribe(&self) -> broadcast::Receiver<Stamped> {
        self.out.subscribe()
    }

    /// Number `msg` if it has a topic, keep it, and send it on. Frames are
    /// published one at a time (the sequencer task), in the order numbered.
    pub fn publish(&self, msg: ServerMsg) {
        let mut state = self.state.lock().unwrap();
        let seq = msg.topic().map(|topic| {
            let seq = state.stamper.next(&topic);
            let size = serde_json::to_vec(&msg).map_or(0, |b| b.len());
            let (max_msgs, max_bytes) = (self.max_msgs, self.max_bytes);
            state
                .rings
                .entry(topic)
                .or_insert_with(|| ReplayRing::with_limits(max_msgs, max_bytes))
                .push(seq, size, msg.clone());
            seq
        });
        // Sent under the lock: a replay taken after this returns sees every
        // frame the channel has been given, and the channel stays in order.
        let _ = self.out.send(Stamped { seq, msg });
    }

    /// What `topic` published after `after`, or that the ring cannot say.
    pub fn replay(&self, topic: &Topic, after: u64) -> Replay {
        let state = self.state.lock().unwrap();
        let latest = state.stamper.last(topic);
        match state.rings.get(topic) {
            Some(ring) => ring.replay(after, latest),
            None if after == latest => Replay::Messages(Vec::new()),
            None => Replay::Exceeded {
                oldest: latest + 1,
                latest,
            },
        }
    }

    /// The last number given to `topic`.
    pub fn latest(&self, topic: &Topic) -> u64 {
        self.state.lock().unwrap().stamper.last(topic)
    }

    /// The last number given to every topic that has one.
    pub fn latest_all(&self) -> BTreeMap<Topic, u64> {
        self.state.lock().unwrap().stamper.last.clone()
    }

    /// What the rings hold now.
    pub fn usage(&self) -> ReplayUsage {
        let state = self.state.lock().unwrap();
        ReplayUsage {
            topics: state.rings.len(),
            frames: state.rings.values().map(ReplayRing::len).sum(),
            bytes: state.rings.values().map(ReplayRing::bytes).sum(),
        }
    }

    /// Frames were lost before they were numbered (the sequencer fell behind
    /// the raw channel): the rings can no longer vouch for what they hold, so
    /// they are emptied and every topic skips a number. A resume from before
    /// now is answered with a `Gap`.
    fn lost_frames(&self) {
        let mut state = self.state.lock().unwrap();
        state.stamper.skip_all();
        state.rings.values_mut().for_each(ReplayRing::clear);
    }

    /// A connection's receiver fell behind the stamped channel.
    pub fn note_lagged(&self) {
        self.lagged.fetch_add(1, Ordering::Relaxed);
    }

    /// How often any connection's receiver fell behind the stamped channel.
    /// Stays 0 while every connection keeps up with its forwarder.
    pub fn lag_count(&self) -> u64 {
        self.lagged.load(Ordering::Relaxed)
    }
}

/// Number every frame producers put on `raw`, until the channel closes.
pub fn spawn_sequencer(hub: Arc<SeqHub>, mut raw: broadcast::Receiver<ServerMsg>) {
    tokio::spawn(async move {
        loop {
            match raw.recv().await {
                Ok(msg) => hub.publish(msg),
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    warn!("sequencer lagged {n} broadcast messages; emptying the replay rings");
                    hub.lost_frames();
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

// ── what a slow client missed ────────────────────────────────────────────────

/// The numbers dropped for one connection while its queue was full, per topic.
#[derive(Debug, Default)]
pub struct DropLog {
    ranges: BTreeMap<Topic, (u64, u64)>,
    /// Frames with no topic dropped for want of room: nothing to name in a `Gap`.
    unsequenced: usize,
}

impl DropLog {
    /// `seq` of `topic` was dropped.
    pub fn record(&mut self, topic: Topic, seq: u64) {
        self.record_range(topic, seq, seq);
    }

    /// `from..=to` of `topic` was (or may have been) dropped.
    pub fn record_range(&mut self, topic: Topic, from: u64, to: u64) {
        self.ranges
            .entry(topic)
            .and_modify(|(first, last)| {
                *first = (*first).min(from);
                *last = (*last).max(to);
            })
            .or_insert((from, to));
    }

    /// A frame with no number was dropped.
    pub fn record_unsequenced(&mut self) {
        self.unsequenced += 1;
    }

    /// How many frames with no number were dropped so far.
    pub fn unsequenced(&self) -> usize {
        self.unsequenced
    }

    pub fn is_empty(&self) -> bool {
        self.ranges.is_empty()
    }

    /// Hand over what was dropped, one `Gap` per topic, and forget it.
    pub fn take_gaps(&mut self) -> Vec<ServerMsg> {
        std::mem::take(&mut self.ranges)
            .into_iter()
            .map(|(topic, (from, to))| ServerMsg::Gap {
                topic,
                host: None,
                from,
                to,
                reason: GapReason::ClientSlow,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jobs() -> ServerMsg {
        ServerMsg::MotherJobs {
            jobs: vec![],
            host: None,
        }
    }

    fn statusline_free_frame() -> ServerMsg {
        ServerMsg::Pong
    }

    fn seqs(replay: Replay) -> Vec<u64> {
        match replay {
            Replay::Messages(v) => v.into_iter().filter_map(|s| s.seq).collect(),
            Replay::Exceeded { .. } => panic!("expected messages, got exceeded"),
        }
    }

    #[test]
    fn numbers_are_strictly_increasing_per_topic_and_independent() {
        let mut s = SeqStamper::default();
        assert_eq!(s.next(&Topic::Perri), 1);
        assert_eq!(s.next(&Topic::Perri), 2);
        assert_eq!(s.next(&Topic::Fred), 1);
        assert_eq!(s.next(&Topic::Perri), 3);
        assert_eq!(s.last(&Topic::Perri), 3);
        assert_eq!(s.last(&Topic::Teri), 0);
    }

    #[test]
    fn the_ring_keeps_at_most_the_message_limit() {
        let mut ring = ReplayRing::with_limits(3, usize::MAX);
        for seq in 1..=5 {
            ring.push(seq, 10, jobs());
        }
        assert_eq!(ring.len(), 3);
        assert_eq!(seqs(ring.replay(2, 5)), vec![3, 4, 5]);
        assert!(matches!(
            ring.replay(1, 5),
            Replay::Exceeded {
                oldest: 3,
                latest: 5
            }
        ));
    }

    #[test]
    fn the_ring_keeps_at_most_the_byte_limit() {
        let mut ring = ReplayRing::with_limits(usize::MAX, 25);
        for seq in 1..=4 {
            ring.push(seq, 10, jobs());
        }
        // Two frames of 10 bytes fit in 25; the third does not.
        assert_eq!(ring.len(), 2);
        assert_eq!(ring.bytes(), 20);
        assert_eq!(seqs(ring.replay(2, 4)), vec![3, 4]);
        assert!(matches!(ring.replay(1, 4), Replay::Exceeded { .. }));
    }

    #[test]
    fn a_frame_larger_than_the_byte_limit_is_not_kept() {
        let mut ring = ReplayRing::with_limits(10, 5);
        ring.push(1, 6, jobs());
        assert!(ring.is_empty());
        assert_eq!(ring.bytes(), 0);
        // Nothing to serve and the client is behind: it is told.
        assert!(matches!(ring.replay(0, 1), Replay::Exceeded { .. }));
    }

    #[test]
    fn replay_boundaries_are_exact() {
        let mut ring = ReplayRing::with_limits(3, usize::MAX);
        for seq in 1..=6 {
            ring.push(seq, 1, jobs());
        }
        // The ring holds 4, 5, 6.
        // Last seen 3: the next one it needs (4) is the oldest held: covered.
        assert_eq!(seqs(ring.replay(3, 6)), vec![4, 5, 6]);
        // Last seen 2: 3 was evicted: not covered.
        assert!(matches!(
            ring.replay(2, 6),
            Replay::Exceeded { oldest: 4, .. }
        ));
        // Fully caught up: nothing, not a gap.
        assert_eq!(seqs(ring.replay(6, 6)), Vec::<u64>::new());
        // From the future (a client of a daemon that restarted): a gap.
        assert!(matches!(ring.replay(7, 6), Replay::Exceeded { .. }));
    }

    #[test]
    fn an_empty_ring_covers_a_client_that_is_caught_up() {
        let ring = ReplayRing::with_limits(3, 100);
        assert_eq!(seqs(ring.replay(0, 0)), Vec::<u64>::new());
        assert!(matches!(ring.replay(1, 0), Replay::Exceeded { .. }));
    }

    #[test]
    fn publish_numbers_topic_frames_and_leaves_others_unnumbered() {
        let hub = SeqHub::new();
        let mut rx = hub.subscribe();
        hub.publish(jobs());
        hub.publish(statusline_free_frame());
        hub.publish(jobs());
        assert_eq!(rx.try_recv().unwrap().seq, Some(1));
        assert_eq!(rx.try_recv().unwrap().seq, None);
        assert_eq!(rx.try_recv().unwrap().seq, Some(2));
        assert_eq!(hub.latest(&Topic::MotherJobs), 2);
        assert_eq!(seqs(hub.replay(&Topic::MotherJobs, 0)), vec![1, 2]);
    }

    #[test]
    fn a_hub_with_no_frames_for_a_topic_answers_by_the_counter() {
        let hub = SeqHub::new();
        assert_eq!(
            seqs(hub.replay(&Topic::Perri, 0)),
            Vec::<u64>::new(),
            "nothing published, nothing missed"
        );
        assert!(matches!(
            hub.replay(&Topic::Perri, 9),
            Replay::Exceeded { latest: 0, .. }
        ));
    }

    #[test]
    fn lost_frames_empty_the_rings_and_make_a_resume_a_gap() {
        let hub = SeqHub::new();
        hub.publish(jobs());
        hub.publish(jobs());
        hub.lost_frames();
        assert_eq!(hub.usage().frames, 0);
        assert!(matches!(
            hub.replay(&Topic::MotherJobs, 2),
            Replay::Exceeded { .. }
        ));
        hub.publish(jobs());
        assert_eq!(hub.latest(&Topic::MotherJobs), 4, "one number was skipped");
    }

    #[test]
    fn usage_sums_every_ring() {
        let hub = SeqHub::new();
        hub.publish(jobs());
        hub.publish(jobs());
        let usage = hub.usage();
        assert_eq!((usage.topics, usage.frames), (1, 2));
        assert!(usage.bytes > 0);
    }

    #[test]
    fn the_number_is_added_as_a_top_level_key() {
        let bytes = encode_with_seq(&jobs(), Some(7)).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["seq"], 7);
        assert_eq!(v["type"], "mother_jobs");
        let plain = encode_with_seq(&jobs(), None).unwrap();
        assert_eq!(plain, serde_json::to_vec(&jobs()).unwrap());
    }

    #[test]
    fn drop_log_merges_per_topic_and_reports_one_gap_each() {
        let mut log = DropLog::default();
        assert!(log.is_empty());
        log.record(Topic::Perri, 5);
        log.record(Topic::Perri, 9);
        log.record(Topic::Fred, 2);
        let gaps = log.take_gaps();
        assert_eq!(gaps.len(), 2);
        assert!(log.is_empty());
        assert!(gaps.iter().any(|g| matches!(
            g,
            ServerMsg::Gap {
                topic: Topic::Perri,
                from: 5,
                to: 9,
                reason: GapReason::ClientSlow,
                ..
            }
        )));
    }
}
