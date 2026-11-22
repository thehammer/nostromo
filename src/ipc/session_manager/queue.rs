//! The message queue's identity and view (`session_queue_v1`, `docs/message-queue.md`).
//!
//! Every user message sent to a session gets a stable id at send time, whether
//! it is written at once or queued behind a running turn. A client that opts in
//! (`session_queue_watch`) sees the queue live; the verified Mac app can take a
//! typed message back or remove it, and the daemon is the single judge of
//! whether it is still queued.
//!
//! Locking. `QueueState::publish` is taken, with nothing else held, around
//! building and broadcasting a snapshot: it is outside the `Shared` lock order
//! (`model_io -> state -> model -> pending`) and takes `pending` and the login
//! cell inside, so a caller never holds `state`, `model` or `pending` while
//! publishing. Every change to the queue is followed by a publish, so the last
//! snapshot always equals the queue.
//!
//! Logging. Nothing here logs message text, image paths or a message's content:
//! counts, ids, codes and durations only.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tracing::info;

use super::login::LoginLink;
use super::task_runtime::daemon_epoch;
use super::{advance, local_command, lock_recover, SessionManager, SessionState};
use super::{PendingMessage, Shared, WRITE_WAIT_LIMIT};
use crate::ipc::protocol::{
    HeldEntryWire, QueueChangeReason, QueueChangeWire, QueueEntryKindWire, QueueEntryWire,
    QueueResultCode, QueueReturnedEntry, ServerMsg,
};

/// How many recently delivered ids a session remembers, to answer
/// `already_delivered` rather than `not_found`.
const DELIVERED_RING: usize = 512;

/// Who composed an app message. The Mac maps these to words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppLabel {
    /// Tell notify, from the Mother overview.
    MotherOverview,
    /// A work-item send.
    WorkItem,
    /// A seeded first message (a new focus, Fred).
    AgentSeed,
}

impl AppLabel {
    pub fn as_str(self) -> &'static str {
        match self {
            AppLabel::MotherOverview => "mother_overview",
            AppLabel::WorkItem => "work_item",
            AppLabel::AgentSeed => "agent_seed",
        }
    }
}

/// What a queued entry is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum EntryKind {
    /// A person typed it into a client.
    Typed { client_ref: Option<String> },
    /// The app composed it.
    App { label: AppLabel },
    /// The daemon wrote it (terminal output, Mother notices). Never shown.
    Injected,
}

impl EntryKind {
    fn is_injected(&self) -> bool {
        matches!(self, EntryKind::Injected)
    }
}

/// The `client_ref` as the wire allows it: at most 64 printable ASCII
/// characters, otherwise dropped (never refused).
pub(super) fn sanitize_client_ref(client_ref: Option<String>) -> Option<String> {
    client_ref
        .filter(|r| !r.is_empty() && r.len() <= 64 && r.bytes().all(|b| (0x20..=0x7e).contains(&b)))
}

/// A new entry id: opaque, unique in this daemon run, and carrying the epoch
/// so a client can tell runs apart.
pub(super) fn next_entry_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let epoch = daemon_epoch();
    let short: String = epoch
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect();
    format!("q{short}-{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

impl PendingMessage {
    /// A message a person typed into a client.
    pub(super) fn typed(text: &str, images: &[String], client_ref: Option<String>) -> Self {
        let mut m = Self::user(text, images);
        m.kind = EntryKind::Typed {
            client_ref: sanitize_client_ref(client_ref),
        };
        m
    }

    /// A message the app composed.
    pub(super) fn app(text: &str, images: &[String], label: AppLabel) -> Self {
        let mut m = Self::user(text, images);
        m.kind = EntryKind::App { label };
        m
    }

    /// The text as it was sent, before any note was put in front of it.
    pub(super) fn original_text(&self) -> &str {
        self.original_text.as_deref().unwrap_or(&self.text)
    }

    /// This message with `text` as what is written (a note in front of it),
    /// remembering the text as sent.
    pub(super) fn framed_with(&self, text: String) -> Self {
        Self {
            text,
            original_text: Some(self.original_text().to_owned()),
            ..self.clone()
        }
    }
}

// ── per-session queue state ───────────────────────────────────────────────────

/// What a session's queue view remembers beyond `pending` itself. Kept per tag
/// by the manager for the daemon's lifetime, so a restart keeps the revision
/// counter, the delivered ring and who is watching.
#[derive(Default)]
pub(super) struct QueueState {
    rev: AtomicU64,
    /// Held while a snapshot is built and broadcast (see the module note).
    publish: Mutex<()>,
    /// Ids written to the CLI recently, oldest first.
    delivered: Mutex<VecDeque<String>>,
    /// The queued or just-written message the conversation's first-prompt
    /// candidate came from (see `conversation_history`).
    candidate: Mutex<Option<String>>,
    /// Per client: 0 is not watching, else `floor + 1`, where `floor` is the
    /// revision of the snapshot the watch was answered with. Snapshots at or
    /// below the floor are not forwarded.
    watchers: Mutex<HashMap<String, Arc<AtomicU64>>>,
}

impl QueueState {
    pub(super) fn record_delivered(&self, id: &str) {
        let mut ring = lock_recover(&self.delivered);
        if ring.len() >= DELIVERED_RING {
            ring.pop_front();
        }
        ring.push_back(id.to_owned());
        drop(ring);
        let mut candidate = lock_recover(&self.candidate);
        if candidate.as_deref() == Some(id) {
            *candidate = None;
        }
    }

    #[cfg(test)]
    pub(super) fn delivered_ids(&self) -> Vec<String> {
        lock_recover(&self.delivered).iter().cloned().collect()
    }

    fn was_delivered(&self, id: &str) -> bool {
        lock_recover(&self.delivered).iter().any(|d| d == id)
    }

    pub(super) fn set_candidate(&self, id: Option<String>) {
        *lock_recover(&self.candidate) = id;
    }

    fn candidate_is(&self, ids: &[String]) -> bool {
        lock_recover(&self.candidate)
            .as_ref()
            .is_some_and(|c| ids.contains(c))
    }

    /// The watch cell for `client`, made when absent (a forwarder holds it).
    pub(super) fn watch_cell(&self, client: &str) -> Arc<AtomicU64> {
        Arc::clone(
            lock_recover(&self.watchers)
                .entry(client.to_owned())
                .or_default(),
        )
    }

    pub(super) fn forget_client(&self, client: &str) {
        lock_recover(&self.watchers).remove(client);
    }

    fn watched(&self) -> bool {
        lock_recover(&self.watchers)
            .values()
            .any(|c| c.load(Ordering::SeqCst) != 0)
    }
}

/// Every tag's [`QueueState`].
#[derive(Default)]
pub(super) struct QueueBook(Mutex<HashMap<String, Arc<QueueState>>>);

impl QueueBook {
    pub(super) fn for_tag(&self, tag: &str) -> Arc<QueueState> {
        Arc::clone(lock_recover(&self.0).entry(tag.to_owned()).or_default())
    }
}

// ── the view ──────────────────────────────────────────────────────────────────

/// One snapshot of a session's queue (the `SessionQueue` frame without its tag).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueSnapshot {
    pub rev: u64,
    pub entries: Vec<QueueEntryWire>,
    pub held: Option<HeldEntryWire>,
    pub change: Option<QueueChangeWire>,
}

impl QueueSnapshot {
    pub(super) fn to_msg(&self, tag: &str) -> ServerMsg {
        ServerMsg::SessionQueue {
            tag: tag.to_owned(),
            daemon_epoch: daemon_epoch().to_owned(),
            rev: self.rev,
            entries: self.entries.clone(),
            held: self.held.clone(),
            change: self.change.clone(),
        }
    }
}

/// What a snapshot says changed.
pub(super) type Change = (QueueChangeReason, Vec<String>);

fn entry_wire(m: &PendingMessage) -> Option<QueueEntryWire> {
    let (kind, app_label, client_ref, can_take_back) = match &m.kind {
        EntryKind::Typed { client_ref } => {
            (QueueEntryKindWire::Typed, None, client_ref.clone(), true)
        }
        EntryKind::App { label } => (
            QueueEntryKindWire::App,
            Some(label.as_str().to_owned()),
            None,
            false,
        ),
        EntryKind::Injected => return None,
    };
    Some(QueueEntryWire {
        id: m.id.clone(),
        kind,
        text: m.text.clone(),
        image_count: m.images.len() as u32,
        command: local_command::split_typed_command(&m.text).is_some(),
        app_label,
        client_ref,
        can_take_back,
    })
}

/// What builds a session's snapshots: handles only, no back-reference to the
/// session's event channel (so a forwarder holding one never keeps it open).
#[derive(Clone)]
pub(super) struct QueueView {
    pending: Arc<Mutex<VecDeque<PendingMessage>>>,
    login: Arc<LoginLink>,
    queue: Arc<QueueState>,
}

impl QueueView {
    /// Build the snapshot now. The caller holds `publish`.
    fn build(&self, change: Option<Change>) -> QueueSnapshot {
        let entries = lock_recover(&self.pending)
            .iter()
            .filter_map(entry_wire)
            .collect();
        QueueSnapshot {
            rev: self.queue.rev.fetch_add(1, Ordering::SeqCst) + 1,
            entries,
            held: self.login.held_entry(),
            change: change.map(|(reason, ids)| QueueChangeWire { reason, ids }),
        }
    }

    /// The current snapshot with a fresh revision (tests).
    #[cfg(test)]
    pub(super) fn current(&self) -> QueueSnapshot {
        let _order = lock_recover(&self.queue.publish);
        self.build(None)
    }

    /// Answer a watch: register `cell` and hand the current snapshot to
    /// `send`, before any later snapshot can be published.
    fn watch(&self, cell: &AtomicU64, send: impl FnOnce(QueueSnapshot)) {
        let _order = lock_recover(&self.queue.publish);
        let snap = self.build(None);
        cell.store(snap.rev + 1, Ordering::SeqCst);
        send(snap);
    }
}

/// What a client's forwarder needs to carry queue snapshots: whether the
/// client watches, and how to rebuild the snapshot after a gap.
pub(super) struct QueueFeed {
    pub(super) cell: Arc<AtomicU64>,
    pub(super) view: QueueView,
}

impl QueueFeed {
    /// Should a snapshot of revision `rev` go to this client?
    pub(super) fn forwards(&self, rev: u64) -> bool {
        let state = self.cell.load(Ordering::SeqCst);
        state != 0 && rev >= state
    }

    /// After a gap: the current snapshot for a watcher (and nothing older
    /// after it), `None` for a client that does not watch.
    pub(super) fn resend(&self) -> Option<QueueSnapshot> {
        if self.cell.load(Ordering::SeqCst) == 0 {
            return None;
        }
        let _order = lock_recover(&self.view.queue.publish);
        let snap = self.view.build(None);
        self.cell.store(snap.rev + 1, Ordering::SeqCst);
        Some(snap)
    }
}

impl Shared {
    pub(super) fn queue_view(&self) -> QueueView {
        QueueView {
            pending: Arc::clone(&self.pending),
            login: Arc::clone(&self.login),
            queue: Arc::clone(&self.queue),
        }
    }

    /// Tell the watchers the queue changed. Hold none of `state`, `model` or
    /// `pending`. Nothing is built when nobody watches.
    pub(super) fn publish_queue(&self, change: Option<Change>) {
        if !self.queue.watched() {
            return;
        }
        let view = self.queue_view();
        let _order = lock_recover(&self.queue.publish);
        let snap = view.build(change);
        self.broadcast(super::SessionEvent::Queue(Arc::new(snap)));
    }

    /// A typed or app message was written to the CLI: remember its id.
    pub(super) fn note_delivered(&self, msg: &PendingMessage) {
        if !msg.kind.is_injected() {
            self.queue.record_delivered(&msg.id);
        }
    }

    /// Queued entries left without being delivered (`left`): when one was the
    /// conversation's first-prompt candidate, hand candidacy to the oldest
    /// message still queued, or clear it.
    pub(super) fn candidate_left(&self, left: &[String]) {
        if !self.queue.candidate_is(left) {
            return;
        }
        let next = lock_recover(&self.pending)
            .iter()
            .find(|m| !m.kind.is_injected())
            .map(|m| (m.id.clone(), (m.text.clone(), !m.images.is_empty())));
        let (id, replacement) = match next {
            Some((id, replacement)) => (Some(id), Some(replacement)),
            None => (None, None),
        };
        self.queue.set_candidate(id);
        self.conversations
            .replace_candidate(&self.ctx.session_id, replacement);
    }
}

// ── take back and remove ──────────────────────────────────────────────────────

/// Which verb a client asked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueVerb {
    TakeBack,
    Remove,
}

/// The daemon's answer to a take-back or remove.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueAnswer {
    pub code: QueueResultCode,
    /// Present only for `taken_back`.
    pub text: Option<String>,
    pub images: Vec<String>,
}

impl QueueAnswer {
    fn code(code: QueueResultCode) -> Self {
        Self {
            code,
            text: None,
            images: Vec::new(),
        }
    }
}

/// What a Stop (or a user stop) took out of a session's queue.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DroppedQueue {
    /// The typed entries, held message first, then the queue in order.
    pub typed: Vec<QueueReturnedEntry>,
    /// Every typed or app entry dropped (the held typed message first); never
    /// an injected one.
    pub ids: Vec<String>,
}

#[cfg(test)]
thread_local! {
    /// Test-only mutation: decide without waiting for an in-flight write.
    pub(super) static SKIP_WRITE_WAIT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Test-only: how long the writer lingers in flight, in microseconds.
    pub(super) static IN_FLIGHT_PAUSE_US: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
fn wait_skipped() -> bool {
    SKIP_WRITE_WAIT.with(|c| c.get())
}

#[cfg(not(test))]
fn wait_skipped() -> bool {
    false
}

/// Test seam: a writer that has taken a message off the queue lingers here.
#[cfg(test)]
pub(super) fn in_flight_pause() {
    let us = IN_FLIGHT_PAUSE_US.with(|c| c.get());
    if us > 0 {
        std::thread::sleep(Duration::from_micros(us));
    }
}

#[cfg(not(test))]
pub(super) fn in_flight_pause() {}

/// Decide a take-back or remove of `id`. Waits (with `state` released) for an
/// in-flight write to settle, bounded like `interrupt`'s wait, then decides
/// under `state`: a message `step` took off the queue is either delivered or
/// back on it by then, never in between.
///
/// If the limit elapses with the write still in flight, the id being written
/// answers `already_delivered`: that message was off the queue, and its write
/// path decides the rest (it is not ours to undo). Any other id that is not
/// queued keeps its own answer (`not_found`, or `already_delivered` if it was).
pub(super) fn answer_verb(shared: &Shared, id: &str, verb: QueueVerb) -> QueueAnswer {
    let started = Instant::now();
    let deadline = started + WRITE_WAIT_LIMIT;
    let (answer, left, held_gone, idle) = loop {
        let state = lock_recover(&shared.state);
        let writing = shared.writing.load(Ordering::SeqCst);
        if writing && !wait_skipped() && Instant::now() < deadline {
            drop(state);
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        // Still writing after the limit (never under the test mutation, which
        // decides as if it had not looked).
        let in_flight = writing && !wait_skipped() && {
            lock_recover(&shared.writing_id).as_deref() == Some(id)
        };
        let mut pending = lock_recover(&shared.pending);
        let position = pending
            .iter()
            .position(|m| m.id == id && !m.kind.is_injected());
        if let Some(pos) = position {
            if matches!(pending[pos].kind, EntryKind::App { .. }) {
                break (
                    QueueAnswer::code(QueueResultCode::NotAllowed),
                    false,
                    false,
                    false,
                );
            }
            let m = pending.remove(pos).expect("position is in range");
            drop(pending);
            let answer = match verb {
                QueueVerb::TakeBack => QueueAnswer {
                    code: QueueResultCode::TakenBack,
                    text: Some(m.text),
                    images: m.images,
                },
                QueueVerb::Remove => QueueAnswer::code(QueueResultCode::Removed),
            };
            break (answer, true, false, false);
        }
        drop(pending);
        if let Some((text, images)) = shared
            .login
            .take_held(id, matches!(verb, QueueVerb::Remove))
        {
            let answer = match verb {
                QueueVerb::TakeBack => QueueAnswer {
                    code: QueueResultCode::TakenBack,
                    text: Some(text),
                    images,
                },
                QueueVerb::Remove => QueueAnswer::code(QueueResultCode::Removed),
            };
            break (answer, false, true, *state == SessionState::Idle);
        }
        let code = if shared.queue.was_delivered(id) || in_flight {
            QueueResultCode::AlreadyDelivered
        } else {
            QueueResultCode::NotFound
        };
        break (QueueAnswer::code(code), false, false, false);
    };

    let ids = vec![id.to_owned()];
    match answer.code {
        QueueResultCode::TakenBack | QueueResultCode::Removed => {
            let reason = if answer.code == QueueResultCode::TakenBack {
                QueueChangeReason::TakenBack
            } else {
                QueueChangeReason::Removed
            };
            if left {
                shared.candidate_left(&ids);
            }
            if held_gone {
                // The held message never opens the conversation, and what is
                // typed next may (as `discard_held` does).
                shared
                    .conversations
                    .discard_candidate(&shared.ctx.session_id);
                shared.queue.set_candidate(None);
                shared.login.notify();
                if idle && answer.code == QueueResultCode::Removed {
                    // Nothing is held now: the queue drains unless a turn runs.
                    advance(shared);
                }
            }
            shared.publish_queue(Some((reason, ids)));
            info!(
                tag = %shared.ctx.tag,
                id,
                code = ?answer.code,
                waited_ms = started.elapsed().as_millis() as u64,
                "queue entry left the queue"
            );
        }
        code => {
            info!(
                tag = %shared.ctx.tag,
                id,
                code = ?code,
                waited_ms = started.elapsed().as_millis() as u64,
                "queue verb answered"
            );
        }
    }
    answer
}

/// Take everything out of a session's queue for a Stop (or a user stop), with
/// the held typed message (already taken out of the hold) first. The caller
/// holds `state`, so a writer that pops afterwards finds nothing.
pub(super) fn drain_for_stop(shared: &Shared, held: Option<QueueReturnedEntry>) -> DroppedQueue {
    let mut dropped = DroppedQueue::default();
    if let Some(held) = held {
        dropped.ids.push(held.id.clone());
        dropped.typed.push(held);
    }
    for m in lock_recover(&shared.pending).drain(..) {
        match m.kind {
            EntryKind::Typed { .. } => {
                dropped.ids.push(m.id.clone());
                dropped.typed.push(QueueReturnedEntry {
                    id: m.id,
                    text: m.text,
                    images: m.images,
                });
            }
            EntryKind::App { .. } => dropped.ids.push(m.id),
            EntryKind::Injected => {}
        }
    }
    dropped
}

// ── the manager's side ────────────────────────────────────────────────────────

impl SessionManager {
    /// Start `client`'s watch of `tag`'s queue: the current snapshot is sent at
    /// once, then one on every change. The client is attached first if it is
    /// not, so the frames have a forwarder. The watch survives a restart of
    /// the session (see `attach`).
    pub fn queue_watch(&mut self, tag: &str, client: &str) -> anyhow::Result<()> {
        let attached = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow::anyhow!("unknown session tag: {tag}"))?
            .attached_clients
            .contains(client);
        if !attached {
            self.attach(tag, client)?;
        }
        let Some(session) = self.sessions.get(tag) else {
            return Ok(());
        };
        let cell = session.shared.queue.watch_cell(client);
        let view = session.shared.queue_view();
        view.watch(&cell, |snap| {
            self.send_to_client(client, snap.to_msg(tag));
        });
        info!(tag, client_id = client, "queue watch");
        Ok(())
    }

    /// Answer a take-back or remove of entry `id` of `tag`'s queue. Anything
    /// the verb cannot find (including an unknown session) is `not_found`.
    pub fn queue_verb(&self, tag: &str, id: &str, verb: QueueVerb) -> QueueAnswer {
        match self.sessions.get(tag) {
            Some(session) => answer_verb(&session.shared, id, verb),
            None => QueueAnswer::code(QueueResultCode::NotFound),
        }
    }

    /// Does `client` watch `tag`'s queue?
    pub fn queue_watching(&self, tag: &str, client: &str) -> bool {
        self.sessions
            .get(tag)
            .is_some_and(|s| s.shared.queue.watch_cell(client).load(Ordering::SeqCst) != 0)
    }

    /// A user stop or a new session is about to end `tag`'s session: take the
    /// typed entries (held first) out of it and discard the queue. Returns the
    /// ids lost, for [`Self::queue_session_stopped`].
    pub(super) fn discard_queue_for_session_stop(&self, tag: &str) -> Vec<String> {
        let Some(session) = self.sessions.get(tag) else {
            return Vec::new();
        };
        let shared = &session.shared;
        let state = lock_recover(&shared.state);
        let held = shared.login.held_entry().and_then(|h| {
            shared
                .login
                .take_held(&h.id, true)
                .map(|(text, images)| QueueReturnedEntry {
                    id: h.id,
                    text,
                    images,
                })
        });
        let dropped = drain_for_stop(shared, held);
        drop(state);
        shared.candidate_left(&dropped.ids);
        // Nothing is queued now, and the held message goes with the session.
        shared.queue.set_candidate(None);
        dropped.typed.into_iter().map(|e| e.id).collect()
    }

    /// The session ended for good: tell each watcher, straight on its own
    /// channel (the forwarders are gone), the queue is empty and which typed
    /// entries were lost.
    pub(super) fn queue_session_stopped(&self, tag: &str, clients: &[String], lost: Vec<String>) {
        let Some(session) = self.sessions.get(tag) else {
            return;
        };
        let view = session.shared.queue_view();
        let change = Some((QueueChangeReason::SessionStopped, lost.clone()));
        let _order = lock_recover(&view.queue.publish);
        let mut snap = view.build(change);
        snap.held = None;
        for client in clients {
            let watching = view.queue.watch_cell(client).load(Ordering::SeqCst) != 0;
            if watching {
                self.send_to_client(client, snap.to_msg(tag));
            }
        }
        info!(tag, lost = lost.len(), "queue ended with the session");
    }
}
