//! Daemon-side registry for decision-modal requests (W6: curated-views
//! decision modals).
//!
//! `DecisionRegistry` is the single shared source of truth for
//! `nostromo.ask_decision` (which creates requests and blocks on their
//! answer) and the IPC server (which routes `ClientMsg::DecisionAnswer` and
//! tracks `Topic::Decision` subscribers). Every method here is a pure,
//! synchronous state transition — no socket, no `.await` — which is what
//! makes the FIFO/answer-once/timeout/cancel behaviour unit-testable without
//! a running daemon.
//!
//! ## Invariants
//!
//! - **At most one outstanding request per tag on the wire.** A second
//!   `submit()` for a tag that already has an active request queues FIFO
//!   instead of broadcasting; it's promoted to active (and broadcast) only
//!   once the active one resolves.
//! - **Answer-once.** `answer()`/`timeout_request()` both funnel through
//!   [`resolve_active`], which removes the entry from `active` and records
//!   its id in `resolved` before firing the oneshot — so a second resolution
//!   attempt for the same id is recognisably `AlreadyAnswered`, not a silent
//!   no-op or a second delivery to the original waiter.
//! - **A request id is never reused.** [`DecisionRegistry::submit`] mints a
//!   fresh [`Uuid::new_v4`] every call.

use std::collections::{HashMap, HashSet, VecDeque};

use tokio::sync::oneshot;
use uuid::Uuid;

use crate::ipc::protocol::{DecisionChoice, ServerMsg};

// ── outcomes ──────────────────────────────────────────────────────────────────

/// How a decision request was ultimately resolved. Delivered exactly once
/// through the `oneshot::Receiver` [`DecisionRegistry::submit`] hands back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecisionOutcome {
    /// The operator picked this choice id.
    Answered(String),
    /// The operator dismissed the modal without choosing.
    Dismissed,
    /// Nobody answered within the caller's timeout.
    TimedOut,
    /// The owning session died while this request was outstanding.
    Cancelled,
}

/// Result of [`DecisionRegistry::answer`].
#[derive(Debug)]
pub enum AnswerOutcome {
    /// The active request was resolved. `promoted` is the next queued
    /// request for the same tag, if any — the caller must broadcast it.
    Answered { promoted: Option<Box<ServerMsg>> },
    /// `request_id` was issued by this registry but has already been
    /// resolved (answered, dismissed, timed out, or cancelled). The original
    /// resolution stands; this second attempt is not forwarded to anyone.
    AlreadyAnswered,
    /// `request_id` was never issued by this registry.
    UnknownRequest,
}

/// Outcome of [`DecisionRegistry::resolve_active`], the shared internal path
/// every termination route (`answer`, `timeout_request`, `cancel_tag`) funnels
/// through.
enum ResolveResult {
    Resolved { promoted: Option<Box<ServerMsg>> },
    AlreadyAnswered,
    UnknownRequest,
}

// ── registry ──────────────────────────────────────────────────────────────────

/// One outstanding (on-the-wire) decision request for a tag.
struct ActiveEntry {
    tag: String,
    reply: oneshot::Sender<DecisionOutcome>,
}

/// A decision request that arrived while its tag already had an active
/// request. Holds the full broadcast payload so it can be sent verbatim once
/// promoted — the tag's queue is FIFO, so this is what preserves arrival
/// order (D3).
struct QueuedEntry {
    msg: ServerMsg,
    reply: oneshot::Sender<DecisionOutcome>,
}

/// Shared decision-modal registry. See the module doc for the invariants
/// every method here upholds.
///
/// Cheap to construct (`HashMap`/`HashSet`/`VecDeque`, all empty); the daemon
/// wraps one instance in `Arc<Mutex<..>>` and hands clones of the `Arc` to
/// both `Server::bind` and `DaemonMcpBackend`.
#[derive(Default)]
pub struct DecisionRegistry {
    /// The single active (broadcast) request per tag, keyed by `request_id`.
    active: HashMap<String, ActiveEntry>,
    /// `tag` → its active request's id, for O(1) "is this tag busy" checks
    /// and for `active_request_id`.
    active_by_tag: HashMap<String, String>,
    /// FIFO queue of not-yet-broadcast requests, keyed by tag.
    queues: HashMap<String, VecDeque<QueuedEntry>>,
    /// Ids of every request this registry has ever resolved (answered,
    /// dismissed, timed out, or cancelled) — kept so a second resolution
    /// attempt is recognisably `AlreadyAnswered` rather than indistinguishable
    /// from an id that was never issued. Not bounded: decisions are rare,
    /// operator-paced events (not a firehose like activity events), so this
    /// does not grow the way an unbounded log of a high-frequency stream
    /// would.
    resolved: HashSet<String>,
    /// Connection keys currently subscribed to `Topic::Decision`.
    subscribers: HashSet<String>,
}

impl DecisionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    // ── submission ────────────────────────────────────────────────────────────

    /// Submit a new decision request for `tag`.
    ///
    /// Returns the fresh `request_id`, a receiver that resolves exactly once,
    /// and either `Some(ServerMsg::DecisionRequest)` — this request became
    /// `tag`'s active one and the caller must broadcast it immediately — or
    /// `None` — `tag` already had an active request, so this one was queued
    /// FIFO and must not be broadcast yet.
    pub fn submit(
        &mut self,
        tag: String,
        prompt: String,
        detail: Option<String>,
        choices: Vec<DecisionChoice>,
        context_pane_id: Option<String>,
    ) -> (String, oneshot::Receiver<DecisionOutcome>, Option<ServerMsg>) {
        let request_id = Uuid::new_v4().to_string();
        let (reply, rx) = oneshot::channel();
        let msg = ServerMsg::DecisionRequest {
            tag: tag.clone(),
            request_id: request_id.clone(),
            prompt,
            detail,
            choices,
            context_pane_id,
        };

        if self.active_by_tag.contains_key(&tag) {
            self.queues
                .entry(tag)
                .or_default()
                .push_back(QueuedEntry { msg, reply });
            (request_id, rx, None)
        } else {
            self.active_by_tag.insert(tag.clone(), request_id.clone());
            self.active.insert(request_id.clone(), ActiveEntry { tag, reply });
            (request_id, rx, Some(msg))
        }
    }

    // ── resolution ────────────────────────────────────────────────────────────

    /// Resolve the active request `request_id` with the operator's answer.
    /// `choice_id: None` means dismissed without choosing.
    pub fn answer(&mut self, request_id: &str, choice_id: Option<String>) -> AnswerOutcome {
        let outcome = match choice_id {
            Some(id) => DecisionOutcome::Answered(id),
            None => DecisionOutcome::Dismissed,
        };
        match self.resolve_active(request_id, outcome) {
            ResolveResult::Resolved { promoted } => AnswerOutcome::Answered { promoted },
            ResolveResult::AlreadyAnswered => AnswerOutcome::AlreadyAnswered,
            ResolveResult::UnknownRequest => AnswerOutcome::UnknownRequest,
        }
    }

    /// Called by the MCP tool handler once its own `tokio::time::timeout`
    /// wrapping the oneshot elapses. Returns the next queued request for the
    /// same tag, promoted to active, if any — the caller must broadcast it.
    ///
    /// A no-op (`None`) if `request_id` is no longer active — the real answer
    /// arrived in the small window between the timeout firing and this call.
    pub fn timeout_request(&mut self, request_id: &str) -> Option<ServerMsg> {
        match self.resolve_active(request_id, DecisionOutcome::TimedOut) {
            ResolveResult::Resolved { promoted } => promoted.map(|b| *b),
            ResolveResult::AlreadyAnswered | ResolveResult::UnknownRequest => None,
        }
    }

    /// The owning session for `tag` died. Every request for that tag — the
    /// active one and everything queued behind it — resolves as
    /// [`DecisionOutcome::Cancelled`]. No promotion/broadcast happens: the
    /// tag's queue is drained entirely, not advanced.
    pub fn cancel_tag(&mut self, tag: &str) {
        if let Some(request_id) = self.active_by_tag.remove(tag) {
            if let Some(entry) = self.active.remove(&request_id) {
                self.resolved.insert(request_id);
                let _ = entry.reply.send(DecisionOutcome::Cancelled);
            }
        }
        if let Some(queue) = self.queues.remove(tag) {
            for queued in queue {
                if let ServerMsg::DecisionRequest { request_id, .. } = &queued.msg {
                    self.resolved.insert(request_id.clone());
                }
                let _ = queued.reply.send(DecisionOutcome::Cancelled);
            }
        }
    }

    /// The shared resolution path for `answer`/`timeout_request`: remove the
    /// active entry (if any), record its id as resolved, fire its oneshot,
    /// then promote the next queued request for the same tag (if any) to
    /// active — returning it so the caller can broadcast it.
    fn resolve_active(&mut self, request_id: &str, outcome: DecisionOutcome) -> ResolveResult {
        let Some(entry) = self.active.remove(request_id) else {
            return if self.resolved.contains(request_id) {
                ResolveResult::AlreadyAnswered
            } else {
                ResolveResult::UnknownRequest
            };
        };
        self.active_by_tag.remove(&entry.tag);
        self.resolved.insert(request_id.to_string());
        let _ = entry.reply.send(outcome);

        let promoted = self.promote_next(&entry.tag);
        ResolveResult::Resolved { promoted: promoted.map(Box::new) }
    }

    /// Pop the next queued request for `tag` (if any), install it as the new
    /// active request, and return its `ServerMsg` for the caller to broadcast.
    fn promote_next(&mut self, tag: &str) -> Option<ServerMsg> {
        let queue = self.queues.get_mut(tag)?;
        let next = queue.pop_front()?;
        if queue.is_empty() {
            self.queues.remove(tag);
        }
        let request_id = match &next.msg {
            ServerMsg::DecisionRequest { request_id, .. } => request_id.clone(),
            _ => unreachable!("QueuedEntry::msg is always a DecisionRequest"),
        };
        self.active_by_tag.insert(tag.to_string(), request_id.clone());
        self.active.insert(
            request_id,
            ActiveEntry {
                tag: tag.to_string(),
                reply: next.reply,
            },
        );
        Some(next.msg)
    }

    // ── operator subscription ──────────────────────────────────────────────

    /// True iff at least one client is currently subscribed to
    /// `Topic::Decision`. `nostromo.ask_decision` checks this before
    /// submitting anything — an agent blocking on a closed GUI is a worse
    /// failure than an immediate refusal.
    pub fn has_operator(&self) -> bool {
        !self.subscribers.is_empty()
    }

    pub fn add_subscriber(&mut self, conn_key: &str) {
        self.subscribers.insert(conn_key.to_string());
    }

    pub fn remove_subscriber(&mut self, conn_key: &str) {
        self.subscribers.remove(conn_key);
    }

    // ── test/diagnostic visibility ────────────────────────────────────────────

    /// The active request id for `tag`, if any.
    pub fn active_request_id(&self, tag: &str) -> Option<String> {
        self.active_by_tag.get(tag).cloned()
    }

    /// How many requests are currently queued (not yet broadcast) for `tag`.
    pub fn queued_count(&self, tag: &str) -> usize {
        self.queues.get(tag).map(VecDeque::len).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::protocol::{DecisionChoice, ServerMsg};
    use std::time::Duration;
    use tokio::sync::oneshot;

    // ── test helpers ──────────────────────────────────────────────────────────

    /// The standard two-choice set most tests below don't care about beyond
    /// identity (approve/reject).
    fn sample_choices() -> Vec<DecisionChoice> {
        vec![
            DecisionChoice {
                id: "approve".into(),
                label: "Approve".into(),
                detail: None,
            },
            DecisionChoice {
                id: "reject".into(),
                label: "Reject".into(),
                detail: None,
            },
        ]
    }

    /// Submit a request for `tag`/`prompt` with the standard choice set and no
    /// detail/context pane — the common case.
    fn submit_simple(
        registry: &mut DecisionRegistry,
        tag: &str,
        prompt: &str,
    ) -> (String, oneshot::Receiver<DecisionOutcome>, Option<ServerMsg>) {
        registry.submit(
            tag.to_string(),
            prompt.to_string(),
            None,
            sample_choices(),
            None,
        )
    }

    /// Unwrap a `ServerMsg::DecisionRequest`'s `(tag, request_id, prompt)`,
    /// panicking (with `context`) on every other variant.
    fn as_decision_request<'a>(msg: &'a ServerMsg, context: &str) -> (&'a str, &'a str, &'a str) {
        match msg {
            ServerMsg::DecisionRequest {
                tag,
                request_id,
                prompt,
                ..
            } => (tag.as_str(), request_id.as_str(), prompt.as_str()),
            _ => panic!("{context}: expected ServerMsg::DecisionRequest, got a different variant"),
        }
    }

    /// Extract the promoted `ServerMsg::DecisionRequest` from an `Answered`
    /// outcome, panicking (with `context`) on every other shape.
    fn expect_promoted(outcome: AnswerOutcome, context: &str) -> ServerMsg {
        match outcome {
            AnswerOutcome::Answered { promoted: Some(msg) } => *msg,
            AnswerOutcome::Answered { promoted: None } => {
                panic!("{context}: expected a promoted request, got Answered {{ promoted: None }}")
            }
            AnswerOutcome::AlreadyAnswered => {
                panic!("{context}: expected Answered, got AlreadyAnswered")
            }
            AnswerOutcome::UnknownRequest => {
                panic!("{context}: expected Answered, got UnknownRequest")
            }
        }
    }

    /// Assert an `Answered` outcome carries no promotion (nothing was queued).
    fn expect_answered_with_no_promotion(outcome: AnswerOutcome, context: &str) {
        match outcome {
            AnswerOutcome::Answered { promoted: None } => {}
            AnswerOutcome::Answered { promoted: Some(_) } => {
                panic!("{context}: expected no promotion, but one was returned")
            }
            AnswerOutcome::AlreadyAnswered => {
                panic!("{context}: expected Answered, got AlreadyAnswered")
            }
            AnswerOutcome::UnknownRequest => {
                panic!("{context}: expected Answered, got UnknownRequest")
            }
        }
    }

    // ── 1. submit: idle tag broadcasts immediately, busy tag queues ─────────────

    #[test]
    fn submit_for_a_fresh_tag_broadcasts_immediately_with_a_fresh_request_id() {
        let mut registry = DecisionRegistry::new();
        let (request_id, _rx, broadcast) = registry.submit(
            "mother".into(),
            "Ship it?".into(),
            Some("careful, this touches prod".into()),
            sample_choices(),
            Some("diff".into()),
        );

        assert!(!request_id.is_empty());
        assert!(
            uuid::Uuid::parse_str(&request_id).is_ok(),
            "request_id must be a UUID string, got {request_id:?}"
        );

        let msg = broadcast.expect("an idle tag's first submit must broadcast immediately");
        match msg {
            ServerMsg::DecisionRequest {
                tag,
                request_id: wire_id,
                prompt,
                detail,
                choices,
                context_pane_id,
            } => {
                assert_eq!(tag, "mother");
                assert_eq!(wire_id, request_id);
                assert_eq!(prompt, "Ship it?");
                assert_eq!(detail, Some("careful, this touches prod".into()));
                assert_eq!(choices, sample_choices());
                assert_eq!(context_pane_id, Some("diff".into()));
            }
            other => panic!("expected DecisionRequest, got {other:?}"),
        }
    }

    #[test]
    fn a_second_submit_for_the_same_tag_queues_instead_of_broadcasting() {
        let mut registry = DecisionRegistry::new();
        let (first_id, _rx1, first_broadcast) = submit_simple(&mut registry, "mother", "First?");
        assert!(first_broadcast.is_some());

        let (_second_id, _rx2, second_broadcast) =
            submit_simple(&mut registry, "mother", "Second?");
        assert!(
            second_broadcast.is_none(),
            "a second submit while the first is outstanding must not broadcast"
        );

        assert_eq!(registry.queued_count("mother"), 1);
        assert_eq!(registry.active_request_id("mother"), Some(first_id));
    }

    #[test]
    fn two_submits_for_the_same_tag_produce_different_request_ids() {
        let mut registry = DecisionRegistry::new();
        let (first_id, _rx1, _b1) = submit_simple(&mut registry, "mother", "First?");
        let (second_id, _rx2, _b2) = submit_simple(&mut registry, "mother", "Second?");
        assert_ne!(first_id, second_id);
    }

    #[test]
    fn submit_for_a_different_tag_broadcasts_immediately_even_while_another_tag_is_active() {
        let mut registry = DecisionRegistry::new();
        let (_a_id, _rx_a, bcast_a) = submit_simple(&mut registry, "mother", "A?");
        assert!(bcast_a.is_some());

        // A second, unrelated tag must get its own active slot — "at most one
        // per tag" is per-tag, not global.
        let (_b_id, _rx_b, bcast_b) = submit_simple(&mut registry, "teri", "B?");
        assert!(
            bcast_b.is_some(),
            "an idle DIFFERENT tag must broadcast immediately regardless of another tag's state"
        );
    }

    // ── 2. answer: resolution + promotion ────────────────────────────────────────

    #[test]
    fn answering_the_active_request_resolves_the_oneshot_with_answered() {
        let mut registry = DecisionRegistry::new();
        let (id, mut rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let outcome = registry.answer(&id, Some("approve".into()));
        expect_answered_with_no_promotion(outcome, "answering the only outstanding request");

        assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("approve".into())));
    }

    #[test]
    fn answering_with_no_choice_resolves_the_oneshot_with_dismissed() {
        let mut registry = DecisionRegistry::new();
        let (id, mut rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let outcome = registry.answer(&id, None);
        expect_answered_with_no_promotion(outcome, "dismissing the only outstanding request");

        assert_eq!(
            rx.try_recv(),
            Ok(DecisionOutcome::Dismissed),
            "choice_id: None must resolve to Dismissed, not a default/empty choice"
        );
    }

    #[test]
    fn answering_the_active_request_when_something_is_queued_promotes_it() {
        let mut registry = DecisionRegistry::new();
        let (a_id, _rx_a, bcast_a) = submit_simple(&mut registry, "mother", "A?");
        assert!(bcast_a.is_some());
        let (b_id, _rx_b, bcast_b) = submit_simple(&mut registry, "mother", "B?");
        assert!(bcast_b.is_none());

        let outcome = registry.answer(&a_id, Some("approve".into()));
        let promoted = expect_promoted(outcome, "answering A while B is queued");

        let (tag, wire_id, prompt) = as_decision_request(&promoted, "promoted request");
        assert_eq!(tag, "mother");
        assert_eq!(wire_id, b_id, "the promoted request must be the QUEUED one, not the answered one");
        assert_eq!(prompt, "B?");

        assert_eq!(registry.active_request_id("mother"), Some(b_id));
        assert_eq!(registry.queued_count("mother"), 0);
    }

    #[test]
    fn answering_the_active_request_when_nothing_is_queued_promotes_nothing() {
        let mut registry = DecisionRegistry::new();
        let (id, _rx, _bcast) = submit_simple(&mut registry, "mother", "A?");

        let outcome = registry.answer(&id, Some("approve".into()));
        expect_answered_with_no_promotion(outcome, "answering with nothing queued");

        assert_eq!(registry.active_request_id("mother"), None);
    }

    #[test]
    fn a_second_answer_for_an_already_answered_request_returns_already_answered_and_does_not_disturb_the_original_resolution(
    ) {
        let mut registry = DecisionRegistry::new();
        let (id, mut rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let first = registry.answer(&id, Some("approve".into()));
        expect_answered_with_no_promotion(first, "the first, legitimate answer");

        let second = registry.answer(&id, Some("reject".into()));
        match second {
            AnswerOutcome::AlreadyAnswered => {}
            AnswerOutcome::Answered { .. } => {
                panic!("a second answer to an already-resolved request must not re-fire as Answered")
            }
            AnswerOutcome::UnknownRequest => {
                panic!("a known-but-resolved request_id must be AlreadyAnswered, not UnknownRequest")
            }
        }

        // The oneshot must carry the FIRST answer exactly once, unaffected by
        // the rejected second one.
        assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("approve".into())));
        assert!(
            rx.try_recv().is_err(),
            "the receiver must not carry a second value — it is spent after one resolution"
        );
    }

    #[test]
    fn an_answer_for_a_request_id_that_was_never_issued_returns_unknown_request() {
        let mut registry = DecisionRegistry::new();
        // Establish that the registry is non-empty/functioning, then probe an
        // id that was never handed out by `submit`.
        let (_id, _rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let outcome = registry.answer("not-a-real-request-id", Some("approve".into()));
        match outcome {
            AnswerOutcome::UnknownRequest => {}
            _ => panic!("an unissued request_id must return UnknownRequest"),
        }
    }

    // ── 3. timeout ────────────────────────────────────────────────────────────────

    #[test]
    fn timeout_request_resolves_timed_out_and_promotes_the_next_queued_request() {
        let mut registry = DecisionRegistry::new();
        let (a_id, mut rx_a, bcast_a) = submit_simple(&mut registry, "mother", "A?");
        assert!(bcast_a.is_some());
        let (b_id, mut rx_b, bcast_b) = submit_simple(&mut registry, "mother", "B?");
        assert!(bcast_b.is_none());
        assert_eq!(registry.queued_count("mother"), 1);

        let promoted = registry
            .timeout_request(&a_id)
            .expect("timing out the active request must promote the queued one");
        let (tag, wire_id, prompt) = as_decision_request(&promoted, "promoted after timeout");
        assert_eq!(tag, "mother");
        assert_eq!(wire_id, b_id);
        assert_eq!(prompt, "B?");

        assert_eq!(rx_a.try_recv(), Ok(DecisionOutcome::TimedOut));
        assert_eq!(registry.active_request_id("mother"), Some(b_id));
        assert_eq!(registry.queued_count("mother"), 0);

        // B was only broadcast (promoted), not itself resolved.
        assert!(rx_b.try_recv().is_err());
    }

    /// The end-to-end shape the real `nostromo.ask_decision` handler uses: it
    /// awaits the oneshot wrapped in `tokio::time::timeout`, and only calls
    /// `timeout_request()` itself once that wrapper elapses. This test proves
    /// the "elapses when nothing answers" half of that shape under a
    /// paused+advanced clock; `timeout_request` itself is exercised directly
    /// (not via a real timer) in the test above.
    #[tokio::test]
    async fn awaiting_the_oneshot_via_tokio_time_timeout_elapses_when_nothing_answers_before_the_deadline(
    ) {
        tokio::time::pause();
        let mut registry = DecisionRegistry::new();
        let (_id, rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let wait = tokio::time::timeout(Duration::from_secs(30), rx);
        tokio::time::advance(Duration::from_secs(31)).await;
        assert!(
            wait.await.is_err(),
            "nothing answered before the deadline — the handler would now call timeout_request()"
        );
    }

    #[test]
    fn timeout_request_for_an_already_answered_request_is_a_no_op() {
        let mut registry = DecisionRegistry::new();
        let (id, mut rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        let outcome = registry.answer(&id, Some("approve".into()));
        expect_answered_with_no_promotion(outcome, "answering before the timeout race lands");

        let promoted = registry.timeout_request(&id);
        assert!(
            promoted.is_none(),
            "a timeout racing an already-answered request must be a no-op"
        );

        // The original answer resolution must be untouched by the no-op.
        assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("approve".into())));
    }

    // ── 4. cancel_tag ───────────────────────────────────────────────────────────────

    #[test]
    fn cancel_tag_resolves_the_active_request_as_cancelled() {
        let mut registry = DecisionRegistry::new();
        let (_id, mut rx, _bcast) = submit_simple(&mut registry, "mother", "Ship it?");

        registry.cancel_tag("mother");

        assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Cancelled));
    }

    #[test]
    fn cancel_tag_resolves_every_queued_request_too_and_leaves_other_tags_untouched() {
        let mut registry = DecisionRegistry::new();
        let (_a_id, mut rx_a, _) = submit_simple(&mut registry, "mother", "A?");
        let (_b_id, mut rx_b, _) = submit_simple(&mut registry, "mother", "B?");
        let (_c_id, mut rx_c, _) = submit_simple(&mut registry, "mother", "C?");
        assert_eq!(registry.queued_count("mother"), 2);

        let (d_id, mut rx_d, bcast_d) = submit_simple(&mut registry, "teri", "D?");
        assert!(
            bcast_d.is_some(),
            "a different tag must have its own independent active slot"
        );

        registry.cancel_tag("mother");

        assert_eq!(rx_a.try_recv(), Ok(DecisionOutcome::Cancelled));
        assert_eq!(rx_b.try_recv(), Ok(DecisionOutcome::Cancelled));
        assert_eq!(rx_c.try_recv(), Ok(DecisionOutcome::Cancelled));
        assert_eq!(registry.queued_count("mother"), 0);
        assert_eq!(registry.active_request_id("mother"), None);

        // A wholly different tag is completely untouched by the cancellation.
        assert_eq!(registry.active_request_id("teri"), Some(d_id));
        assert!(
            rx_d.try_recv().is_err(),
            "teri's request must still be outstanding after mother's tag is cancelled"
        );
    }

    // ── 5. operator subscription ─────────────────────────────────────────────────

    #[test]
    fn has_operator_reflects_subscriber_add_and_remove() {
        let mut registry = DecisionRegistry::new();
        assert!(!registry.has_operator(), "a fresh registry has no operator");

        registry.add_subscriber("conn-1");
        assert!(registry.has_operator());

        registry.remove_subscriber("conn-1");
        assert!(!registry.has_operator());
    }

    #[test]
    fn removing_a_never_added_subscriber_is_a_noop_and_does_not_affect_a_different_subscriber() {
        let mut registry = DecisionRegistry::new();
        registry.add_subscriber("conn-real");

        // Must not panic, and must not disturb the real subscriber.
        registry.remove_subscriber("conn-never-added");
        assert!(
            registry.has_operator(),
            "removing an unknown conn_key must not affect an existing subscriber"
        );

        registry.remove_subscriber("conn-real");
        assert!(!registry.has_operator());
    }

    // ── 6. FIFO ordering ──────────────────────────────────────────────────────────

    #[test]
    fn fifo_ordering_holds_for_three_or_more_queued_requests() {
        let mut registry = DecisionRegistry::new();
        let (a_id, _rx_a, bcast_a) = submit_simple(&mut registry, "mother", "A?");
        assert!(bcast_a.is_some());
        let (_b_id, _rx_b, bcast_b) = submit_simple(&mut registry, "mother", "B?");
        assert!(bcast_b.is_none());
        let (_c_id, _rx_c, bcast_c) = submit_simple(&mut registry, "mother", "C?");
        assert!(bcast_c.is_none());
        let (_d_id, _rx_d, bcast_d) = submit_simple(&mut registry, "mother", "D?");
        assert!(bcast_d.is_none());
        assert_eq!(registry.queued_count("mother"), 3);

        // Answer A → must promote B (the FIRST queued), never C or D.
        let promoted = expect_promoted(registry.answer(&a_id, Some("approve".into())), "answering A");
        let (_, wire_id, prompt) = as_decision_request(&promoted, "promoted after A");
        assert_eq!(prompt, "B?", "A's promotion must be B — the first-queued request");
        let b_id = wire_id.to_string();

        // Answer B (using the id straight off the wire message, not a locally
        // cached one) → must promote C.
        let promoted = expect_promoted(registry.answer(&b_id, Some("approve".into())), "answering B");
        let (_, wire_id, prompt) = as_decision_request(&promoted, "promoted after B");
        assert_eq!(prompt, "C?", "B's promotion must be C, preserving arrival order");
        let c_id = wire_id.to_string();

        // Answer C → must promote D, the last one queued.
        let promoted = expect_promoted(registry.answer(&c_id, Some("approve".into())), "answering C");
        let (_, _wire_id, prompt) = as_decision_request(&promoted, "promoted after C");
        assert_eq!(prompt, "D?", "C's promotion must be D — the last-queued request, in order");

        assert_eq!(registry.queued_count("mother"), 0);
    }
}
