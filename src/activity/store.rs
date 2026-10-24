//! `ActivityStore` — bounded, attributed, per-agent activity stream
//! buffering.
//!
//! The tailer (`agent_bus::tail_activity_jsonl`) produces a flat stream of
//! `ActivityEvent`s with no guaranteed attribution — a hook payload's
//! `focus_tag`/`session_id` may be unresolvable at ingest time (e.g. a
//! session spawned by a daemon that predates the reverse index). Attribution
//! *policy* (focus-tag lookup, session-id reverse lookup, "give up") lives
//! outside this module — the caller (`nostromd.rs`) resolves an [`Attribution`]
//! verdict per event and hands it to [`ActivityStore::ingest`].
//!
//! `ActivityStore` itself owns:
//! - assigning each event a per-stream monotonic `seq`,
//! - bucketing it into the right per-focus, per-subagent stream (or the
//!   focus's main stream, `agent_id: None`),
//! - re-applying [`redact::scrub`] defensively, so a line that reaches the
//!   store without having gone through the producer's own scrub is still
//!   safe,
//! - never dropping an event it can't attribute — it lands in
//!   [`ActivityStore::unattributed`] instead,
//! - bounding memory: [`MAX_EVENTS_PER_STREAM`] per stream,
//!   [`MAX_TOTAL_EVENTS`] store-wide — evicting the oldest *finished*
//!   subagent stream (one that has received a `subagent_stop` event) before
//!   ever touching the main stream or a still-running subagent stream.

use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Utc};

use crate::activity::redact;
use crate::agent_bus::ActivityEvent;

/// Per-stream retention cap. Ingesting past this evicts the oldest event in
/// that stream.
pub const MAX_EVENTS_PER_STREAM: usize = 200;

/// Store-wide retention cap across all streams combined.
pub const MAX_TOTAL_EVENTS: usize = 2000;

/// How an incoming raw event should be attributed. Resolved by the caller
/// before calling [`ActivityStore::ingest`] — the store only needs the
/// verdict, not the resolution policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attribution {
    /// Attributed to a known focus's main stream (`agent_id: None`).
    Focus { tag: String },
    /// Attributed to a known focus's specific subagent stream.
    Subagent { tag: String, agent_id: String },
    /// No focus tag or session id could be resolved for this event.
    Unattributed,
}

/// One per-focus-or-per-subagent event buffer.
#[derive(Debug, Clone, Default)]
pub struct ActivityStream {
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub parent_agent_id: Option<String>,
    pub events: VecDeque<ActivityEvent>,
    /// Set once a `kind == "subagent_stop"` event is ingested for this
    /// stream. A finished stream is preferred eviction fodder under the
    /// global cap.
    pub finished: bool,
    next_seq: u64,
}

/// Read-only snapshot of one stream, for wire serialization / display.
#[derive(Debug, Clone)]
pub struct ActivityStreamSnapshot {
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub parent_agent_id: Option<String>,
    pub events: Vec<ActivityEvent>,
    pub finished: bool,
}

/// Ingestion health verdict, surfaced to clients via
/// `ipc::protocol::ServerMsg::ActivityHealth`.
#[derive(Debug, Clone, PartialEq)]
pub struct ActivityHealth {
    pub ingesting: bool,
    pub last_event_at: Option<DateTime<Utc>>,
}

/// Bounded, attributed, per-agent activity stream store.
pub struct ActivityStore {
    /// focus tag -> (subagent id, or `None` for the main stream) -> stream.
    streams: HashMap<String, HashMap<Option<String>, ActivityStream>>,
    unattributed: VecDeque<ActivityEvent>,
    /// Ingest volume since the last successful reclaim — **not** a lifetime
    /// counter and **not** a "currently retained events" gauge. A live
    /// retained-events gauge would be structurally incapable of ever
    /// crossing [`MAX_TOTAL_EVENTS`]: the per-stream cap
    /// ([`MAX_EVENTS_PER_STREAM`]) already bounds any *single* stream, so the
    /// real unbounded-growth risk isn't how many events are retained at once
    /// — it's how many *finished* subagent streams accumulate over a long
    /// daemon uptime, each holding on to its (small, capped) history. This
    /// counter stands in for "how much ingest volume has passed through
    /// since we last reclaimed" as the trigger for reclaiming more history;
    /// crossing [`MAX_TOTAL_EVENTS`] triggers reclaiming the oldest finished
    /// stream(s) — see [`Self::evict_if_over_budget`], which reduces this by
    /// exactly the number of events each reclaim actually frees. Earlier this
    /// was never decremented at all, which meant the first crossing made the
    /// loop condition permanently true: every subsequent `ingest()` drained
    /// one more entry off `finished_eviction_order` on the spot, so a
    /// subagent's history was gone within one tool call of it finishing,
    /// defeating the "≥200 retained events" guarantee for exactly the stream
    /// an operator would actually want to inspect.
    ingest_pressure: u64,
    last_event_at: Option<DateTime<Utc>>,
    /// `(tag, agent_id)` of finished subagent streams, oldest-finished-first.
    /// Popped from the front by [`Self::evict_if_over_budget`].
    finished_eviction_order: VecDeque<(String, String)>,
}

impl ActivityStore {
    /// A fresh, empty store.
    pub fn new() -> Self {
        Self {
            streams: HashMap::new(),
            unattributed: VecDeque::new(),
            ingest_pressure: 0,
            last_event_at: None,
            finished_eviction_order: VecDeque::new(),
        }
    }

    /// Ingest one raw event: attribute it per `attribution`, assign a
    /// per-stream monotonic `seq` (starting at 0), defensively re-scrub its
    /// summary via [`redact::scrub`], enforce retention, and return the
    /// finalized event.
    pub fn ingest(&mut self, mut event: ActivityEvent, attribution: Attribution) -> ActivityEvent {
        event.summary = redact::scrub(&event.summary);
        self.ingest_pressure += 1;
        self.last_event_at = Some(event.ts);

        let finalized = match attribution {
            Attribution::Unattributed => {
                event.seq = None;
                self.unattributed.push_back(event.clone());
                if self.unattributed.len() > MAX_EVENTS_PER_STREAM {
                    self.unattributed.pop_front();
                }
                event
            }
            Attribution::Focus { tag } => self.ingest_into(&tag, None, None, None, event),
            Attribution::Subagent { tag, agent_id } => {
                let agent_type = event.agent_type.clone();
                let parent_agent_id = event.parent_agent_id.clone();
                self.ingest_into(&tag, Some(agent_id), agent_type, parent_agent_id, event)
            }
        };

        self.evict_if_over_budget();
        finalized
    }

    /// Every stream (main + subagent) known for `tag`, in no particular
    /// order.
    pub fn streams_for_focus(&self, tag: &str) -> Vec<ActivityStreamSnapshot> {
        match self.streams.get(tag) {
            Some(by_agent) => by_agent
                .values()
                .map(|s| ActivityStreamSnapshot {
                    agent_id: s.agent_id.clone(),
                    agent_type: s.agent_type.clone(),
                    parent_agent_id: s.parent_agent_id.clone(),
                    events: s.events.iter().cloned().collect(),
                    finished: s.finished,
                })
                .collect(),
            None => Vec::new(),
        }
    }

    /// Events that could not be attributed to any focus. Never dropped.
    pub fn unattributed(&self) -> Vec<ActivityEvent> {
        self.unattributed.iter().cloned().collect()
    }

    /// Ingestion health verdict.
    ///
    /// This is a store-local primitive only — it knows whether *this store*
    /// has ever ingested an event, not whether the tailer is running or the
    /// hook is installed. The daemon combines this with that broader state
    /// (see `nostromd.rs`) to build the richer `ServerMsg::ActivityHealth`.
    pub fn health(&self) -> ActivityHealth {
        ActivityHealth {
            ingesting: self.last_event_at.is_some(),
            last_event_at: self.last_event_at,
        }
    }

    // ── private ────────────────────────────────────────────────────────────

    /// Append `event` to the (focus, agent_id) stream, creating it on first
    /// use, assigning the stream's next `seq`, and enforcing the per-stream
    /// retention cap.
    fn ingest_into(
        &mut self,
        tag: &str,
        agent_id: Option<String>,
        agent_type: Option<String>,
        parent_agent_id: Option<String>,
        mut event: ActivityEvent,
    ) -> ActivityEvent {
        let by_agent = self.streams.entry(tag.to_string()).or_default();
        let stream = by_agent
            .entry(agent_id.clone())
            .or_insert_with(|| ActivityStream {
                agent_id: agent_id.clone(),
                agent_type: agent_type.clone(),
                parent_agent_id: parent_agent_id.clone(),
                events: VecDeque::new(),
                finished: false,
                next_seq: 0,
            });
        // A stream created before its type/parent were known (shouldn't
        // normally happen, but defensively) picks them up on a later event.
        if stream.agent_type.is_none() {
            stream.agent_type = agent_type;
        }
        if stream.parent_agent_id.is_none() {
            stream.parent_agent_id = parent_agent_id;
        }

        event.seq = Some(stream.next_seq);
        stream.next_seq += 1;

        if event.kind == "subagent_stop" {
            stream.finished = true;
            if let Some(aid) = &agent_id {
                self.finished_eviction_order
                    .push_back((tag.to_string(), aid.clone()));
            }
        }

        stream.events.push_back(event.clone());
        if stream.events.len() > MAX_EVENTS_PER_STREAM {
            stream.events.pop_front();
        }

        event
    }

    /// While accumulated ingest pressure exceeds [`MAX_TOTAL_EVENTS`],
    /// reclaim the oldest finished subagent stream's events, one stream at a
    /// time, reducing `ingest_pressure` by exactly what each reclaim frees.
    /// Never touches the main stream or a still-running subagent stream. A
    /// no-op once there are no more finished streams to reclaim from — pressure
    /// can stay over budget in that case, which is fine: memory is bounded
    /// per-stream regardless, and this only controls how long a finished
    /// stream's history lingers, not a hard ceiling.
    ///
    /// The subtraction is what keeps this from re-triggering on every single
    /// future `ingest()` once crossed once: without it, `ingest_pressure`
    /// only grows, so the loop condition would go permanently true the first
    /// time it's satisfied, draining `finished_eviction_order` to empty on
    /// the spot and then clearing any newly-finished stream again the moment
    /// it's pushed.
    fn evict_if_over_budget(&mut self) {
        while self.ingest_pressure > MAX_TOTAL_EVENTS as u64 {
            let Some((tag, agent_id)) = self.finished_eviction_order.pop_front() else {
                break;
            };
            if let Some(by_agent) = self.streams.get_mut(&tag) {
                if let Some(stream) = by_agent.get_mut(&Some(agent_id)) {
                    let reclaimed = stream.events.len() as u64;
                    stream.events.clear();
                    self.ingest_pressure = self.ingest_pressure.saturating_sub(reclaimed);
                }
            }
        }
    }
}

impl Default for ActivityStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_event(agent: &str, kind: &str, summary: &str) -> ActivityEvent {
        ActivityEvent {
            ts: Utc::now(),
            agent: agent.into(),
            kind: kind.into(),
            summary: summary.into(),
            focus_tag: None,
            session_id: None,
            agent_id: None,
            agent_type: None,
            parent_agent_id: None,
            tool_name: None,
            tool_use_id: None,
            cwd: None,
            seq: None,
        }
    }

    // ── 1. per-agent stream isolation ─────────────────────────────────────────

    #[test]
    fn two_concurrent_subagents_produce_two_disjoint_streams() {
        let mut store = ActivityStore::new();
        store.ingest(
            raw_event("claude", "tool_use", "agent A reading a file"),
            Attribution::Subagent {
                tag: "cody-1".into(),
                agent_id: "agent-a".into(),
            },
        );
        store.ingest(
            raw_event("claude", "tool_use", "agent B editing a file"),
            Attribution::Subagent {
                tag: "cody-1".into(),
                agent_id: "agent-b".into(),
            },
        );

        let streams = store.streams_for_focus("cody-1");
        let stream_a = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-a"))
            .expect("agent-a must have its own stream");
        let stream_b = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-b"))
            .expect("agent-b must have its own stream");

        assert!(stream_a
            .events
            .iter()
            .all(|e| e.summary.contains("agent A")));
        assert!(stream_b
            .events
            .iter()
            .all(|e| e.summary.contains("agent B")));
        assert!(
            !stream_a
                .events
                .iter()
                .any(|e| e.summary.contains("agent B")),
            "agent A's stream must never contain agent B's events"
        );

        if let Some(main) = streams.iter().find(|s| s.agent_id.is_none()) {
            assert!(
                main.events.is_empty(),
                "neither subagent event should land in the main stream"
            );
        }
    }

    // ── 2. focus attribution ──────────────────────────────────────────────────

    #[test]
    fn an_event_attributed_to_a_known_focus_lands_in_that_focus_main_stream() {
        let mut store = ActivityStore::new();
        store.ingest(
            raw_event("claude", "tool_use", "reading a file"),
            Attribution::Focus { tag: "fred".into() },
        );
        let streams = store.streams_for_focus("fred");
        let main = streams
            .iter()
            .find(|s| s.agent_id.is_none())
            .expect("fred must have a main stream");
        assert_eq!(main.events.len(), 1);
        assert_eq!(main.events[0].summary, "reading a file");
    }

    // ── 3. unattributed events are never dropped ──────────────────────────────

    #[test]
    fn an_event_with_no_resolvable_attribution_lands_in_unattributed_never_dropped() {
        let mut store = ActivityStore::new();
        store.ingest(
            raw_event("claude", "tool_use", "mystery event"),
            Attribution::Unattributed,
        );
        let unattr = store.unattributed();
        assert_eq!(unattr.len(), 1);
        assert_eq!(unattr[0].summary, "mystery event");
        assert!(
            store.streams_for_focus("fred").is_empty(),
            "an unattributed event must never land on an arbitrary focus's streams"
        );
    }

    // ── 4. seq is monotonic within a stream ───────────────────────────────────

    #[test]
    fn seq_is_monotonically_increasing_within_one_stream() {
        let mut store = ActivityStore::new();
        for i in 0..3 {
            store.ingest(
                raw_event("claude", "tool_use", &format!("event {i}")),
                Attribution::Focus { tag: "fred".into() },
            );
        }
        let streams = store.streams_for_focus("fred");
        let main = streams.iter().find(|s| s.agent_id.is_none()).unwrap();
        let seqs: Vec<u64> = main
            .events
            .iter()
            .map(|e| e.seq.expect("seq must be assigned by ingest"))
            .collect();
        assert_eq!(
            seqs,
            vec![0, 1, 2],
            "seq must be assigned in ingestion order, starting at 0"
        );
    }

    // ── 5. per-stream retention ────────────────────────────────────────────────

    #[test]
    fn pushing_250_events_into_one_stream_retains_only_the_most_recent_200() {
        let mut store = ActivityStore::new();
        for i in 0..250 {
            store.ingest(
                raw_event("claude", "tool_use", &format!("event {i}")),
                Attribution::Focus { tag: "fred".into() },
            );
        }
        let streams = store.streams_for_focus("fred");
        let main = streams.iter().find(|s| s.agent_id.is_none()).unwrap();
        assert_eq!(main.events.len(), MAX_EVENTS_PER_STREAM);
        assert_eq!(
            main.events.first().unwrap().summary,
            "event 50",
            "the oldest 50 events must have been evicted"
        );
        assert_eq!(main.events.last().unwrap().summary, "event 249");
    }

    // ── 6. global cap prefers evicting a finished subagent stream ────────────

    #[test]
    fn global_cap_evicts_the_oldest_finished_subagent_stream_before_main_or_running_streams() {
        let mut store = ActivityStore::new();

        store.ingest(
            raw_event("claude", "tool_use", "main event 1"),
            Attribution::Focus { tag: "fred".into() },
        );
        store.ingest(
            raw_event("claude", "tool_use", "main event 2"),
            Attribution::Focus { tag: "fred".into() },
        );

        // A finished subagent stream — its subagent_stop lands before the
        // still-running subagent below, so it's the oldest *finished* stream
        // once the cap is exceeded.
        store.ingest(
            raw_event("claude", "subagent_start", "agent-old started"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-old".into(),
            },
        );
        store.ingest(
            raw_event("claude", "subagent_stop", "agent-old finished"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-old".into(),
            },
        );

        // A still-running subagent stream, started after agent-old finished.
        store.ingest(
            raw_event("claude", "subagent_start", "agent-new started"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-new".into(),
            },
        );

        for i in 0..MAX_TOTAL_EVENTS {
            store.ingest(
                raw_event("claude", "tool_use", &format!("agent-new event {i}")),
                Attribution::Subagent {
                    tag: "fred".into(),
                    agent_id: "agent-new".into(),
                },
            );
        }

        let streams = store.streams_for_focus("fred");
        let main = streams.iter().find(|s| s.agent_id.is_none()).unwrap();
        let old = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-old"));
        let new = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-new"))
            .unwrap();

        assert!(
            old.is_none() || old.unwrap().events.is_empty(),
            "the oldest finished subagent stream must be evicted before the main or a running stream is touched"
        );
        assert!(
            !main.events.is_empty(),
            "the main stream must survive eviction pressure from a finished subagent stream"
        );
        assert!(
            !new.events.is_empty(),
            "the still-running subagent stream must survive eviction pressure"
        );
    }

    #[test]
    fn crossing_the_budget_once_does_not_permanently_wipe_every_later_finished_stream() {
        // Regression test for the bug where ingest_pressure was never
        // decremented on eviction: the loop condition in
        // evict_if_over_budget stayed permanently true after the first
        // crossing, so every subsequently-finished subagent's history was
        // cleared on the very same ingest() call that recorded its
        // subagent_stop — before anyone had a chance to look at it.
        let mut store = ActivityStore::new();

        // A finished subagent stream, filled to exactly its per-stream cap —
        // the most a single reclaim can free — sitting in
        // finished_eviction_order ahead of anything else.
        store.ingest(
            raw_event("claude", "subagent_start", "agent-old started"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-old".into(),
            },
        );
        for i in 0..(MAX_EVENTS_PER_STREAM - 2) {
            store.ingest(
                raw_event("claude", "tool_use", &format!("agent-old event {i}")),
                Attribution::Subagent {
                    tag: "fred".into(),
                    agent_id: "agent-old".into(),
                },
            );
        }
        store.ingest(
            raw_event("claude", "subagent_stop", "agent-old finished"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-old".into(),
            },
        );

        // Push pressure just barely past the budget. Reclaiming agent-old's
        // full stream (MAX_EVENTS_PER_STREAM events) should land comfortably
        // back under it, not merely closer to it.
        let ingested_so_far = MAX_EVENTS_PER_STREAM as u64; // start + (cap-2) tool_use + stop
        let to_cross = MAX_TOTAL_EVENTS as u64 + 1 - ingested_so_far;
        for i in 0..to_cross {
            store.ingest(
                raw_event("claude", "tool_use", &format!("main event {i}")),
                Attribution::Focus { tag: "fred".into() },
            );
        }

        // Sanity check on the setup: agent-old should already be reclaimed —
        // otherwise the rest of this test isn't exercising what it claims to.
        let streams = store.streams_for_focus("fred");
        let old = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-old"));
        assert!(
            old.is_none() || old.unwrap().events.is_empty(),
            "setup error: agent-old should already be reclaimed once pressure crossed the budget"
        );

        // Now, well after that crossing and reclaim, a brand-new subagent
        // starts, does a little work, and finishes.
        store.ingest(
            raw_event("claude", "subagent_start", "agent-fresh started"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-fresh".into(),
            },
        );
        store.ingest(
            raw_event("claude", "tool_use", "agent-fresh did something"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-fresh".into(),
            },
        );
        store.ingest(
            raw_event("claude", "subagent_stop", "agent-fresh finished"),
            Attribution::Subagent {
                tag: "fred".into(),
                agent_id: "agent-fresh".into(),
            },
        );

        let streams = store.streams_for_focus("fred");
        let fresh = streams
            .iter()
            .find(|s| s.agent_id.as_deref() == Some("agent-fresh"))
            .expect("agent-fresh's stream must exist");

        assert!(
            !fresh.events.is_empty(),
            "a subagent that just finished must not have its history wiped purely because \
             ingest pressure crossed the budget at some earlier point in the session"
        );
    }

    // ── 7. defensive re-scrub ──────────────────────────────────────────────────

    #[test]
    fn ingest_defensively_rescrubs_a_summary_that_bypassed_the_producers_own_redaction() {
        let mut store = ActivityStore::new();
        let raw = raw_event(
            "claude",
            "tool_use",
            "leaked token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        );
        let finalized = store.ingest(raw, Attribution::Focus { tag: "fred".into() });
        assert!(
            !finalized
                .summary
                .contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            "ActivityStore::ingest must defensively re-scrub the summary: {}",
            finalized.summary
        );
    }
}
