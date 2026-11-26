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
//! The rings hold frames *before* any peer's trust filter, plus, for each,
//! the copy a network peer was (or would have been) sent when it was published
//! (`RingEntry::network`: already trimmed, or absent when withheld). A replay to
//! a network peer is that copy, run through `peer::outbound` again with today's
//! sensitive tags, so a ring can never hand a peer what it would not have been
//! sent live: not what was withheld, not what was trimmed (a tag that stops
//! being sensitive later does not give its title back), and not what became
//! sensitive since.
//!
//! The rings are in memory only. A daemon restart starts every topic again at
//! 1, so every run of the daemon has an *epoch* (a random number, `Welcome.seq_epoch`):
//! a client that resumes under another epoch is not covered, whatever its
//! numbers are, and is told so with a `Gap { daemon_restarted }`.

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use tokio::sync::{broadcast, mpsc, oneshot};
use tracing::warn;

use super::peer::{outbound, PeerTrust, SensitiveTags};
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

/// Bytes (of serialized frames) one resume may have replayed to a network peer;
/// a topic whose replay would go past it is answered with its snapshot and a
/// `Gap` instead. A resume names about a dozen topics, each up to
/// [`MAX_RING_BYTES`], and a device may hold several sockets.
pub const RESUME_BUDGET_NETWORK: usize = 4 * 1024 * 1024;
/// The same for a local client (the operator's own app).
pub const RESUME_BUDGET_LOCAL: usize = 16 * 1024 * 1024;

/// How long a connection waits, before it writes a targeted reply, for the
/// frames published ahead of it to get through the sequencer and its own
/// forwarder. Bounded so a flood of broadcasts never holds a reply up for
/// good; a wait that runs out is counted ([`SeqHub::ordering_timeouts`]).
pub const ORDER_WAIT: Duration = Duration::from_millis(100);

/// Capacity of the stamped broadcast channel.
const STAMPED_CHANNEL_CAP: usize = 512;

/// Every topic that is numbered ([`Topic::is_sequenced`]).
pub const SEQUENCED_TOPICS: [Topic; 12] = [
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

/// Epochs are kept below 2^53 so a JSON reader that parses numbers as doubles
/// holds one exactly.
const EPOCH_MASK: u64 = (1 << 53) - 1;

fn new_epoch() -> u64 {
    loop {
        let epoch = uuid::Uuid::new_v4().as_u128() as u64 & EPOCH_MASK;
        if epoch != 0 {
            return epoch;
        }
    }
}

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

    /// Skip one number on every numbered topic (a topic that has none yet gets
    /// its first), so a frame lost before it was numbered shows as a jump rather
    /// than being invisible, and return what each topic skipped. A topic that
    /// has published nothing yet is included: the lost frames may have been its.
    fn skip_all(&mut self) -> Vec<(Topic, u64)> {
        SEQUENCED_TOPICS
            .iter()
            .map(|topic| {
                let n = self.last.entry(topic.clone()).or_insert(0);
                *n += 1;
                (topic.clone(), *n)
            })
            .collect()
    }
}

// ── the ring ─────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct RingEntry {
    seq: u64,
    size: usize,
    /// Shared, so a replay takes its copies after the hub's lock is released.
    msg: Arc<ServerMsg>,
    /// What a network peer was sent for this frame when it was published,
    /// trimmed as it was then (`peer::outbound`), or `None` when the frame was
    /// withheld from network peers. What was sensitive then is judged then: a
    /// tag that stops being sensitive later neither opens the frames it
    /// withheld nor gives back the title it had trimmed away. Shares the
    /// original when the trim changed nothing.
    network: Option<Arc<ServerMsg>>,
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
    /// byte limit is not kept at all. `network_ok`: a network peer is sent the
    /// frame as it is (see [`ReplayRing::push_trimmed`] for one that is trimmed).
    pub fn push(&mut self, seq: u64, size: usize, msg: Arc<ServerMsg>, network_ok: bool) {
        let network = network_ok.then(|| Arc::clone(&msg));
        self.push_trimmed(seq, size, msg, network);
    }

    /// [`ReplayRing::push`] with the copy a network peer was sent (`None`:
    /// withheld from network peers).
    pub fn push_trimmed(
        &mut self,
        seq: u64,
        size: usize,
        msg: Arc<ServerMsg>,
        network: Option<Arc<ServerMsg>>,
    ) {
        self.frames.push_back(RingEntry {
            seq,
            size,
            msg,
            network,
        });
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
    ///
    /// For a network peer (`network`) only the frames that could have been sent
    /// to one when they were published.
    #[cfg(test)]
    fn replay(&self, after: u64, latest: u64, network: bool) -> RingReplay {
        self.replay_within(after, latest, network, usize::MAX)
    }

    /// [`ReplayRing::replay`] that gives up (as if the ring did not reach back)
    /// when the frames to send come to more than `budget` serialized bytes.
    fn replay_within(&self, after: u64, latest: u64, network: bool, budget: usize) -> RingReplay {
        // The first number the ring would have to hold.
        let oldest = self.frames.front().map_or(latest + 1, |e| e.seq);
        if after > latest || after + 1 < oldest {
            return RingReplay::Exceeded { oldest, latest };
        }
        let mut entries = Vec::new();
        let mut bytes = 0usize;
        for e in self.frames.iter().filter(|e| e.seq > after) {
            let copy = if network {
                &e.network
            } else {
                &Some(Arc::clone(&e.msg))
            };
            let Some(copy) = copy else { continue };
            bytes = bytes.saturating_add(e.size);
            if bytes > budget {
                return RingReplay::Exceeded { oldest, latest };
            }
            entries.push((e.seq, Arc::clone(copy)));
        }
        RingReplay::Entries(entries, bytes)
    }
}

enum RingReplay {
    /// The frames, and their serialized size.
    Entries(Vec<(u64, Arc<ServerMsg>)>, usize),
    Exceeded {
        oldest: u64,
        latest: u64,
    },
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
    /// Frames handed to the stamped channel so far (numbered or not): where a
    /// connection's receiver starts, and what it must have got through for
    /// everything published before some moment to have reached its queue.
    published: u64,
}

/// A receiver of the numbered frames, with where the hub stood the moment it
/// was made: nothing published before is in it, everything after is.
pub struct HubSubscription {
    pub rx: broadcast::Receiver<Stamped>,
    /// [`SeqHub::published`] at that moment.
    pub published: u64,
    /// The last number of every topic at that moment.
    pub seen: BTreeMap<Topic, u64>,
}

/// Numbers and keeps every topic-bearing frame, and fans the numbered frames
/// out. One per daemon.
pub struct SeqHub {
    state: Mutex<HubState>,
    out: broadcast::Sender<Stamped>,
    tags: SensitiveTags,
    max_msgs: usize,
    max_bytes: usize,
    /// Which run of the daemon the numbers belong to (`Welcome.seq_epoch`).
    epoch: u64,
    /// How often a connection's receiver fell behind the stamped channel.
    lagged: AtomicU64,
    /// How often a reply stopped waiting for the frames ahead of it
    /// ([`ORDER_WAIT`]).
    ordering_timeouts: AtomicU64,
    /// Asks the sequencer task to catch up with the raw channel (see
    /// [`SeqHub::sync_point`]); set when the sequencer starts.
    sync: OnceLock<mpsc::UnboundedSender<oneshot::Sender<u64>>>,
}

impl SeqHub {
    /// `tags` is the daemon's record of which focuses and jobs are sensitive,
    /// consulted when a frame is published (see `RingEntry::network_ok`).
    pub fn new(tags: SensitiveTags) -> Arc<Self> {
        Self::with_limits(tags, MAX_RING_MSGS, MAX_RING_BYTES)
    }

    pub fn with_limits(tags: SensitiveTags, max_msgs: usize, max_bytes: usize) -> Arc<Self> {
        let (out, _) = broadcast::channel(STAMPED_CHANNEL_CAP);
        Arc::new(Self {
            state: Mutex::new(HubState {
                stamper: SeqStamper::default(),
                rings: BTreeMap::new(),
                published: 0,
            }),
            out,
            tags,
            max_msgs,
            max_bytes,
            epoch: new_epoch(),
            lagged: AtomicU64::new(0),
            ordering_timeouts: AtomicU64::new(0),
            sync: OnceLock::new(),
        })
    }

    /// Which run of the daemon the numbers belong to: random, fixed for the
    /// life of the hub, nonzero and below 2^53.
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// A receiver of the numbered frames. Subscribe *before* asking for a
    /// replay, so nothing published in between is missed (a frame in both is
    /// dropped by its number).
    pub fn subscribe(&self) -> broadcast::Receiver<Stamped> {
        self.out.subscribe()
    }

    /// [`SeqHub::subscribe`] together with where the hub stood at that very
    /// moment (taken under the lock `publish` sends under, so a frame is either
    /// in the receiver or counted in what was already there).
    pub fn subscribe_counted(&self) -> HubSubscription {
        let state = self.state.lock().unwrap();
        HubSubscription {
            rx: self.out.subscribe(),
            published: state.published,
            seen: state.stamper.last.clone(),
        }
    }

    /// How many frames have been handed to the stamped channel.
    pub fn published(&self) -> u64 {
        self.state.lock().unwrap().published
    }

    /// Wait (up to [`ORDER_WAIT`]) for the sequencer to number everything the
    /// producers had put on the raw channel by now, and return how many frames
    /// the stamped channel then holds ([`SeqHub::published`]): a connection that
    /// has got through that many of its own receiver's frames has seen every
    /// frame sent before this call. Falls back to the count as it stands when
    /// there is no sequencer or it does not answer in time.
    pub async fn sync_point(&self) -> u64 {
        let Some(sync) = self.sync.get() else {
            return self.published();
        };
        let (reply, answer) = oneshot::channel();
        if sync.send(reply).is_err() {
            return self.published();
        }
        match tokio::time::timeout(ORDER_WAIT, answer).await {
            Ok(Ok(published)) => published,
            _ => {
                self.note_ordering_timeout();
                self.published()
            }
        }
    }

    /// A reply stopped waiting for the frames published ahead of it.
    pub fn note_ordering_timeout(&self) {
        self.ordering_timeouts.fetch_add(1, Ordering::Relaxed);
    }

    /// How often a reply was written without every frame ahead of it having
    /// got through (the wait ran out). Stays 0 unless the daemon is flooded.
    pub fn ordering_timeouts(&self) -> u64 {
        self.ordering_timeouts.load(Ordering::Relaxed)
    }

    /// Number `msg` if it has a topic, keep it, and send it on. Frames are
    /// published one at a time (the sequencer task), in the order numbered.
    pub fn publish(&self, msg: ServerMsg) {
        let mut state = self.state.lock().unwrap();
        let seq = msg.topic().map(|topic| {
            let seq = state.stamper.next(&topic);
            let bytes = serde_json::to_vec(&msg).unwrap_or_default();
            let original = Arc::new(msg.clone());
            // What a network peer is sent for it, as it is sent now: withheld,
            // trimmed, or untouched (then the same copy as the original).
            let network = outbound(PeerTrust::Paired, msg.clone(), &self.tags).map(|sent| {
                if serde_json::to_vec(&sent).is_ok_and(|b| b == bytes) {
                    Arc::clone(&original)
                } else {
                    Arc::new(sent)
                }
            });
            let (max_msgs, max_bytes) = (self.max_msgs, self.max_bytes);
            state
                .rings
                .entry(topic)
                .or_insert_with(|| ReplayRing::with_limits(max_msgs, max_bytes))
                .push_trimmed(seq, bytes.len(), original, network);
            seq
        });
        self.send_locked(&mut state, Stamped { seq, msg });
    }

    /// Put a frame on the stamped channel. Under the state lock: a replay taken
    /// after this returns sees every frame the channel has been given, and the
    /// channel stays in order.
    fn send_locked(&self, state: &mut HubState, stamped: Stamped) {
        state.published += 1;
        let _ = self.out.send(stamped);
    }

    /// What `topic` published after `after`, or that the ring cannot say. For a
    /// `network` peer only frames a network peer could have been sent when they
    /// were published; the caller still runs each through the peer's own gate.
    pub fn replay(&self, topic: &Topic, after: u64, network: bool) -> Replay {
        self.replay_within(topic, after, network, usize::MAX).0
    }

    /// [`SeqHub::replay`] that answers `Exceeded` instead when the frames would
    /// come to more than `budget` serialized bytes, and says how many bytes the
    /// frames it did return come to. A network peer's frames are the copies
    /// trimmed when they were published.
    pub fn replay_within(
        &self,
        topic: &Topic,
        after: u64,
        network: bool,
        budget: usize,
    ) -> (Replay, usize) {
        let found = {
            let state = self.state.lock().unwrap();
            let latest = state.stamper.last(topic);
            match state.rings.get(topic) {
                Some(ring) => ring.replay_within(after, latest, network, budget),
                None if after == latest => RingReplay::Entries(Vec::new(), 0),
                None => RingReplay::Exceeded {
                    oldest: latest + 1,
                    latest,
                },
            }
        };
        // Copied after the lock is released: publishing is never held up by it.
        match found {
            RingReplay::Entries(entries, bytes) => (
                Replay::Messages(
                    entries
                        .into_iter()
                        .map(|(seq, msg)| Stamped {
                            seq: Some(seq),
                            msg: (*msg).clone(),
                        })
                        .collect(),
                ),
                bytes,
            ),
            RingReplay::Exceeded { oldest, latest } => (Replay::Exceeded { oldest, latest }, 0),
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
    /// now is answered with a `Gap`, and so is every connection that is
    /// connected now: a `Gap { lagged }` naming the skipped number goes through
    /// the stamped channel, in its place, to each topic's followers (a
    /// connection queues it only for the topics it follows).
    pub fn lost_frames(&self) {
        let mut state = self.state.lock().unwrap();
        let skipped = state.stamper.skip_all();
        state.rings.values_mut().for_each(ReplayRing::clear);
        for (topic, n) in skipped {
            let gap = ServerMsg::Gap {
                topic,
                host: None,
                from: n,
                to: n,
                reason: GapReason::Lagged,
            };
            self.send_locked(&mut state, Stamped::unsequenced(gap));
        }
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

/// Number every frame producers put on `raw`, until the channel closes. Also
/// answers [`SeqHub::sync_point`]: it takes whatever is on `raw` at that moment
/// (no more) before it answers.
pub fn spawn_sequencer(hub: Arc<SeqHub>, mut raw: broadcast::Receiver<ServerMsg>) {
    let (sync_tx, mut sync_rx) = mpsc::unbounded_channel::<oneshot::Sender<u64>>();
    let _ = hub.sync.set(sync_tx);
    tokio::spawn(async move {
        loop {
            tokio::select! {
                Some(reply) = sync_rx.recv() => {
                    for _ in 0..raw.len() {
                        match raw.try_recv() {
                            Ok(msg) => hub.publish(msg),
                            Err(broadcast::error::TryRecvError::Lagged(n)) => {
                                warn!("sequencer lagged {n} broadcast messages; emptying the replay rings");
                                hub.lost_frames();
                            }
                            Err(_) => break,
                        }
                    }
                    let _ = reply.send(hub.published());
                }
                received = raw.recv() => match received {
                    Ok(msg) => hub.publish(msg),
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("sequencer lagged {n} broadcast messages; emptying the replay rings");
                        hub.lost_frames();
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                },
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

    fn ring_seqs(replay: RingReplay) -> Vec<u64> {
        match replay {
            RingReplay::Entries(v, _) => v.into_iter().map(|(seq, _)| seq).collect(),
            RingReplay::Exceeded { .. } => panic!("expected entries, got exceeded"),
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
            ring.push(seq, 10, Arc::new(jobs()), true);
        }
        assert_eq!(ring.len(), 3);
        assert_eq!(ring_seqs(ring.replay(2, 5, false)), vec![3, 4, 5]);
        assert!(matches!(
            ring.replay(1, 5, false),
            RingReplay::Exceeded {
                oldest: 3,
                latest: 5
            }
        ));
    }

    #[test]
    fn the_ring_keeps_at_most_the_byte_limit() {
        let mut ring = ReplayRing::with_limits(usize::MAX, 25);
        for seq in 1..=4 {
            ring.push(seq, 10, Arc::new(jobs()), true);
        }
        // Two frames of 10 bytes fit in 25; the third does not.
        assert_eq!(ring.len(), 2);
        assert_eq!(ring.bytes(), 20);
        assert_eq!(ring_seqs(ring.replay(2, 4, false)), vec![3, 4]);
        assert!(matches!(
            ring.replay(1, 4, false),
            RingReplay::Exceeded { .. }
        ));
    }

    #[test]
    fn a_frame_larger_than_the_byte_limit_is_not_kept() {
        let mut ring = ReplayRing::with_limits(10, 5);
        ring.push(1, 6, Arc::new(jobs()), true);
        assert!(ring.is_empty());
        assert_eq!(ring.bytes(), 0);
        // Nothing to serve and the client is behind: it is told.
        assert!(matches!(
            ring.replay(0, 1, false),
            RingReplay::Exceeded { .. }
        ));
    }

    #[test]
    fn a_network_peer_is_replayed_only_what_a_network_peer_could_have_been_sent() {
        let mut ring = ReplayRing::with_limits(10, usize::MAX);
        ring.push(1, 1, Arc::new(jobs()), true);
        ring.push(2, 1, Arc::new(jobs()), false);
        ring.push(3, 1, Arc::new(jobs()), true);
        assert_eq!(ring_seqs(ring.replay(0, 3, true)), vec![1, 3]);
        assert_eq!(ring_seqs(ring.replay(0, 3, false)), vec![1, 2, 3]);
    }

    #[test]
    fn replay_boundaries_are_exact() {
        let mut ring = ReplayRing::with_limits(3, usize::MAX);
        for seq in 1..=6 {
            ring.push(seq, 1, Arc::new(jobs()), true);
        }
        // The ring holds 4, 5, 6.
        // Last seen 3: the next one it needs (4) is the oldest held: covered.
        assert_eq!(ring_seqs(ring.replay(3, 6, false)), vec![4, 5, 6]);
        // Last seen 2: 3 was evicted: not covered.
        assert!(matches!(
            ring.replay(2, 6, false),
            RingReplay::Exceeded { oldest: 4, .. }
        ));
        // Fully caught up: nothing, not a gap.
        assert_eq!(ring_seqs(ring.replay(6, 6, false)), Vec::<u64>::new());
        // From the future (a client of a daemon that restarted): a gap.
        assert!(matches!(
            ring.replay(7, 6, false),
            RingReplay::Exceeded { .. }
        ));
    }

    #[test]
    fn an_empty_ring_covers_a_client_that_is_caught_up() {
        let ring = ReplayRing::with_limits(3, 100);
        assert_eq!(ring_seqs(ring.replay(0, 0, false)), Vec::<u64>::new());
        assert!(matches!(
            ring.replay(1, 0, false),
            RingReplay::Exceeded { .. }
        ));
    }

    #[test]
    fn publish_numbers_topic_frames_and_leaves_others_unnumbered() {
        let hub = SeqHub::new(SensitiveTags::in_memory());
        let mut rx = hub.subscribe();
        hub.publish(jobs());
        hub.publish(statusline_free_frame());
        hub.publish(jobs());
        assert_eq!(rx.try_recv().unwrap().seq, Some(1));
        assert_eq!(rx.try_recv().unwrap().seq, None);
        assert_eq!(rx.try_recv().unwrap().seq, Some(2));
        assert_eq!(hub.latest(&Topic::MotherJobs), 2);
        assert_eq!(seqs(hub.replay(&Topic::MotherJobs, 0, false)), vec![1, 2]);
    }

    #[test]
    fn a_hub_with_no_frames_for_a_topic_answers_by_the_counter() {
        let hub = SeqHub::new(SensitiveTags::in_memory());
        assert_eq!(
            seqs(hub.replay(&Topic::Perri, 0, false)),
            Vec::<u64>::new(),
            "nothing published, nothing missed"
        );
        assert!(matches!(
            hub.replay(&Topic::Perri, 9, false),
            Replay::Exceeded { latest: 0, .. }
        ));
    }

    #[test]
    fn lost_frames_empty_the_rings_and_make_a_resume_a_gap() {
        let hub = SeqHub::new(SensitiveTags::in_memory());
        hub.publish(jobs());
        hub.publish(jobs());
        hub.lost_frames();
        assert_eq!(hub.usage().frames, 0);
        assert!(matches!(
            hub.replay(&Topic::MotherJobs, 2, false),
            Replay::Exceeded { .. }
        ));
        hub.publish(jobs());
        assert_eq!(hub.latest(&Topic::MotherJobs), 4, "one number was skipped");
    }

    #[test]
    fn usage_sums_every_ring() {
        let hub = SeqHub::new(SensitiveTags::in_memory());
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

    // ── the hub, seen from outside: epoch, counted subscriptions, lost frames ──

    fn layout_frame() -> ServerMsg {
        ServerMsg::Notification {
            tag: "proj".into(),
            level: crate::ipc::protocol::NotificationLevel::Info,
            message: "n".into(),
        }
    }

    #[test]
    fn the_epoch_is_nonzero_below_2_pow_53_and_differs_between_hubs() {
        let epochs: Vec<u64> = (0..20)
            .map(|_| SeqHub::new(SensitiveTags::in_memory()).epoch())
            .collect();
        for epoch in &epochs {
            assert!(*epoch != 0 && *epoch < (1u64 << 53), "{epoch}");
        }
        let distinct: std::collections::BTreeSet<_> = epochs.iter().collect();
        assert!(distinct.len() > 1, "twenty hubs, one epoch: {epochs:?}");
        let hub = SeqHub::new(SensitiveTags::in_memory());
        hub.publish(jobs());
        assert_eq!(hub.epoch(), hub.epoch(), "fixed for the life of the hub");
    }

    #[test]
    fn a_counted_subscription_says_exactly_what_was_published_before_it_and_receives_what_follows()
    {
        let hub = SeqHub::new(SensitiveTags::in_memory());
        hub.publish(jobs());
        hub.publish(jobs());
        hub.publish(statusline_free_frame()); // counted though it has no number
        hub.publish(layout_frame());
        assert_eq!(hub.published(), 4);

        let mut sub = hub.subscribe_counted();
        assert_eq!(sub.published, 4, "every frame handed to the channel so far");
        assert_eq!(sub.seen.get(&Topic::MotherJobs), Some(&2));
        assert_eq!(sub.seen.get(&Topic::Layout), Some(&1));
        assert_eq!(sub.seen.get(&Topic::Perri).copied().unwrap_or(0), 0);
        assert!(
            matches!(
                sub.rx.try_recv(),
                Err(broadcast::error::TryRecvError::Empty)
            ),
            "nothing published before it is in its receiver"
        );

        hub.publish(jobs());
        assert_eq!(sub.rx.try_recv().unwrap().seq, Some(3));
        assert_eq!(hub.published(), 5, "and the count moves on");
    }

    /// A frame is either in the receiver of a counted subscription or counted in
    /// what it says came before, never both and never neither: the receiver is
    /// made under the lock `publish` sends under. Here a frame is sent (as
    /// `publish` sends it) while a subscription is waiting for that lock.
    #[test]
    fn a_counted_subscription_that_waits_for_a_frame_being_published_neither_loses_nor_repeats_it()
    {
        let hub = SeqHub::new(SensitiveTags::in_memory());
        hub.publish(jobs());
        let mut state = hub.state.lock().unwrap();
        let subscriber = {
            let hub = Arc::clone(&hub);
            std::thread::spawn(move || hub.subscribe_counted())
        };
        // Long enough for the subscriber to have reached the lock (or past it,
        // were it not to wait for it).
        std::thread::sleep(Duration::from_millis(100));
        let seq = state.stamper.next(&Topic::MotherJobs);
        hub.send_locked(
            &mut state,
            Stamped {
                seq: Some(seq),
                msg: jobs(),
            },
        );
        drop(state);

        let mut sub = subscriber.join().unwrap();
        let mut got = 0u64;
        while sub.rx.try_recv().is_ok() {
            got += 1;
        }
        assert_eq!(
            sub.published + got,
            2,
            "the frame published during the subscription is counted once: {} counted before, {got} received",
            sub.published
        );
        assert_eq!(
            sub.seen.get(&Topic::MotherJobs).copied().unwrap_or(0) + got,
            2,
            "the numbers it had seen and the frames it got make both"
        );
    }

    // What a network peer is replayed is what it was sent when the frame was
    // published, trimmed then: a tag that stops being sensitive afterwards must
    // not give back what the live frame hid. The same through the two network
    // gates, `Routed` (a satellite's requester) and `Paired` (a device).

    const SECRET_TITLE: &str = "SECRET-HELD-TITLE";
    const SECRET_TAG: &str = "secret-held-tag";

    fn secret_meta() -> crate::ipc::protocol::FocusMeta {
        crate::ipc::protocol::FocusMeta {
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

    fn secret_job() -> crate::mother::MotherJob {
        use crate::mother::origin::{OriginKind, OriginView};
        crate::mother::MotherJob {
            id: "trim-job-1".to_string(),
            state: "running".to_string(),
            nostromo: Some(crate::mother::JobAnnotation {
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

    #[test]
    fn a_network_replay_never_carries_what_the_live_frame_hid() {
        let variants: [(&str, ServerMsg, bool); 4] = [
            (
                "FocusRegistryUpdated",
                ServerMsg::FocusRegistryUpdated {
                    focuses: vec![secret_meta()],
                    host: None,
                },
                true,
            ),
            (
                "FocusCreated",
                ServerMsg::FocusCreated {
                    meta: secret_meta(),
                    host: None,
                },
                true,
            ),
            (
                "MotherJobs",
                ServerMsg::MotherJobs {
                    jobs: vec![secret_job()],
                    host: None,
                },
                false,
            ),
            (
                "MotherAwaitDetected",
                ServerMsg::MotherAwaitDetected(Box::new(secret_job())),
                false,
            ),
        ];
        for (name, frame, hides_tag) in variants {
            let tags = SensitiveTags::in_memory();
            let hub = SeqHub::new(tags.clone());
            let topic = frame.topic().expect("a numbered topic");
            let mentions_secret = |msg: &ServerMsg| {
                let json = serde_json::to_string(msg).unwrap();
                json.contains(SECRET_TITLE) || (hides_tag && json.contains(SECRET_TAG))
            };
            assert!(
                mentions_secret(&frame),
                "{name}: the frame carries the secret"
            );

            // Published while the tag is held sensitive: the live path trims it.
            let hold = tags.hold_sensitive(SECRET_TAG);
            let live = outbound(PeerTrust::Paired, frame.clone(), &tags)
                .unwrap_or_else(|| panic!("{name}: a paired device is sent the trimmed frame"));
            assert!(!mentions_secret(&live), "{name}: the live frame hides it");
            hub.publish(frame);
            drop(hold);

            let Replay::Messages(replayed) = hub.replay(&topic, 0, true) else {
                panic!("{name}: the ring covers it");
            };
            assert_eq!(replayed.len(), 1, "{name}");
            for trust in [PeerTrust::Routed, PeerTrust::Paired] {
                if let Some(sent) = outbound(trust, replayed[0].msg.clone(), &tags) {
                    assert!(
                        !mentions_secret(&sent),
                        "{name} over {trust:?}: the replay shows what the live frame hid: {sent:?}"
                    );
                }
            }
            assert!(
                outbound(PeerTrust::Paired, replayed[0].msg.clone(), &tags).is_some(),
                "{name}: a paired device is replayed the (trimmed) frame, not nothing"
            );
        }
    }

    #[tokio::test]
    async fn a_sequencer_that_falls_behind_empties_the_rings_skips_a_number_on_every_topic_and_says_so(
    ) {
        let (tx, raw) = broadcast::channel::<ServerMsg>(4);
        let hub = SeqHub::new(SensitiveTags::in_memory());
        hub.publish(jobs());
        hub.publish(jobs()); // mother_jobs is at 2, every other topic at 0
        let mut stamped = hub.subscribe();
        spawn_sequencer(Arc::clone(&hub), raw);
        // More than the channel holds, with no yield: the sequencer's first
        // receive reports that it lost frames.
        for _ in 0..10 {
            tx.send(ServerMsg::Pong).unwrap();
        }
        // The frames the sequencer put on the stamped channel: a Gap for every
        // topic, then the four frames that were not lost.
        let expected = SEQUENCED_TOPICS.len() + 4;
        let mut frames = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), async {
            while frames.len() < expected {
                match stamped.try_recv() {
                    Ok(frame) => frames.push(frame),
                    Err(_) => tokio::task::yield_now().await,
                }
            }
        })
        .await
        .expect("the sequencer handled the lost frames and the four that were left");

        assert_eq!(hub.usage().frames, 0, "the rings were emptied");
        assert!(
            matches!(
                hub.replay(&Topic::MotherJobs, 2, false),
                Replay::Exceeded { .. }
            ),
            "a resume from before the loss is a Gap"
        );
        for topic in &SEQUENCED_TOPICS {
            let skipped = if *topic == Topic::MotherJobs { 3 } else { 1 };
            assert_eq!(
                hub.latest(topic),
                skipped,
                "{topic:?} skipped a number (a topic that had published nothing included)"
            );
        }

        let mut told: BTreeMap<Topic, (u64, u64)> = BTreeMap::new();
        let mut pongs = 0;
        for frame in frames {
            assert_eq!(frame.seq, None, "neither a Gap nor a Pong is numbered");
            match frame.msg {
                ServerMsg::Gap {
                    topic,
                    host,
                    from,
                    to,
                    reason,
                } => {
                    assert_eq!((host, reason), (None, GapReason::Lagged));
                    assert!(
                        told.insert(topic, (from, to)).is_none(),
                        "one Gap per topic"
                    );
                }
                ServerMsg::Pong => pongs += 1,
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(pongs, 4, "the frames that were not lost went on");
        assert_eq!(told.len(), SEQUENCED_TOPICS.len());
        for topic in &SEQUENCED_TOPICS {
            let n = hub.latest(topic);
            assert_eq!(
                told[topic],
                (n, n),
                "{topic:?}: the Gap names the skipped number"
            );
        }
    }

    /// Which topics are numbered, written down here against `Topic` itself: a
    /// new variant does not compile until it is classified.
    #[test]
    fn the_numbered_topics_are_exactly_the_topics_that_are_sequenced() {
        fn numbered(topic: &Topic) -> bool {
            match topic {
                Topic::Activity
                | Topic::MotherJobs
                | Topic::MotherStatusline
                | Topic::Focuses
                | Topic::MotherPeek
                | Topic::Perri
                | Topic::Fred
                | Topic::Teri
                | Topic::Work
                | Topic::Layout
                | Topic::Decision
                | Topic::Model => true,
                Topic::Terminal | Topic::AuthoredPrs | Topic::Devices | Topic::Unknown => false,
            }
        }
        let every_variant = [
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
            Topic::Terminal,
            Topic::AuthoredPrs,
            Topic::Devices,
            Topic::Unknown,
        ];
        for topic in &every_variant {
            assert_eq!(topic.is_sequenced(), numbered(topic), "{topic:?}");
        }
        let spec: std::collections::BTreeSet<Topic> = every_variant
            .iter()
            .filter(|t| numbered(t))
            .cloned()
            .collect();
        let listed: std::collections::BTreeSet<Topic> = SEQUENCED_TOPICS.iter().cloned().collect();
        assert_eq!(
            listed, spec,
            "SEQUENCED_TOPICS lists every numbered topic and no other"
        );
        assert_eq!(SEQUENCED_TOPICS.len(), listed.len(), "and none twice");
    }
}
