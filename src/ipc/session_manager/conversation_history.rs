//! The session manager's side of the conversation history: noting spawns,
//! sends and turns, answering the Resume tab's verbs, and the resume rules.
//!
//! Nothing here logs a title, label, path, branch or prompt: ids and fixed
//! words only.

use super::{load_id_store, save_id, SessionManager};
use crate::conversations::list::{self, status_now};
use crate::conversations::store::{MetaUpdate, SpawnNote};
use crate::conversations::{backfill, now_ms, ConversationHistory};
use crate::ipc::protocol::{ConversationResumeOutcome, ConversationStatus, ServerMsg};
use crate::model::store::{self as model_store, FocusModelRecord, ModelSource};
use crate::model::ModelTarget;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// At most one history-changed nudge per this long.
const NUDGE_MIN_GAP: Duration = Duration::from_millis(500);
/// A tag reserved by a resume stands in for a registry entry this long (the
/// Mac pushes the new focus a moment after the reply).
const RESERVATION_WINDOW: Duration = Duration::from_secs(15);

/// Bookkeeping for a conversation resumed into a new tag.
pub(super) struct ResumedTag {
    pub sid: String,
    pub old_tag: String,
}

/// Resume bookkeeping and the nudge debounce, kept in one place.
#[derive(Default)]
pub(super) struct ConversationState {
    /// New tags a resume handed a conversation to, until their first send.
    pub resumed: HashMap<String, ResumedTag>,
    /// sid → (tag, when) of the latest resume.
    pub reserved: HashMap<String, (String, Instant)>,
    pub nudged_revision: u64,
    pub nudged_at: Option<Instant>,
    pub background_running: Arc<AtomicBool>,
    pub operator_conns: std::collections::HashSet<String>,
}

impl SessionManager {
    /// The conversation history (a shared handle).
    pub fn conversations(&self) -> ConversationHistory {
        self.conversations.clone()
    }

    /// Use `history` instead of the one beside the store (tests).
    pub fn configure_conversations(&mut self, history: ConversationHistory) {
        self.conversations = history;
    }

    /// Counts only, for the daemon diagnostics.
    pub fn conversation_counts(&self) -> (usize, usize, bool) {
        self.conversations.counts()
    }

    /// Note that connection `conn_key` is the verified operator app: it alone
    /// hears that the history changed.
    pub fn mark_operator_conn(&mut self, conn_key: &str) {
        self.conv.operator_conns.insert(conn_key.to_owned());
    }

    /// Fill the history from the session-id history, once, on a background
    /// thread. Does nothing when already done or when the file was unreadable.
    pub fn start_conversation_backfill(&self) {
        if self.conversations.backfilled() || self.conversations.counts().2 {
            return;
        }
        let history = self.conversations.clone();
        let sources = self.session_history.entries();
        let sensitive = self.sensitive.clone();
        let restricted: Vec<String> = self.restrictions.keys().cloned().collect();
        std::thread::spawn(move || {
            backfill::run(&history, sources, &sensitive, |tag| {
                restricted.iter().any(|r| r == tag)
            });
        });
    }

    /// A session is being spawned for `tag`: note it (hidden until the first
    /// message). Never for a restricted tag.
    pub(super) fn note_conversation_spawn(
        &self,
        tag: &str,
        sid: &str,
        agent: &str,
        view_name: &str,
        cwd: Option<&Path>,
        model: Option<&ModelTarget>,
    ) {
        if self.restrictions.contains_key(tag) {
            return;
        }
        let focus = self.focus_registry.iter().find(|f| f.tag == tag);
        let title = focus.map_or(view_name, |f| f.display_name.as_str());
        self.conversations.note_spawn(
            SpawnNote {
                tag,
                sid,
                agent,
                cwd,
                title,
                label: focus.and_then(|f| f.label.as_deref()),
                model: model.map(|m| (m.model.as_str(), m.effort.as_deref())),
            },
            now_ms(),
        );
    }

    /// A user message was written into `tag`'s session.
    pub(super) fn note_conversation_send(&mut self, tag: &str, text: &str, has_images: bool) {
        // A first send ends a resumed tag's stale-id protection: the
        // conversation exists in Claude's eyes now.
        self.conv.resumed.remove(tag);
        let Some(session) = self.sessions.get(tag) else {
            return;
        };
        let Some(sid) = session.session_id.clone() else {
            return;
        };
        let agent = session.agent_name.clone();
        let sensitive = self.sensitive.focus_is_sensitive(tag, &agent);
        self.conversations
            .note_user_send(&sid, text, has_images, sensitive, now_ms());
        let meta = self.conversation_meta(tag, true);
        self.conversations.refresh_meta(&sid, meta, now_ms());
    }

    /// Title, label and (when asked) the model the focus runs on now.
    fn conversation_meta(&self, tag: &str, with_model: bool) -> MetaUpdate {
        let focus = self.focus_registry.iter().find(|f| f.tag == tag);
        let model = with_model
            .then(|| model_store::focus_record(&self.model_hub.paths.focus_models, tag))
            .flatten()
            .map(|r| (r.model, r.effort));
        MetaUpdate {
            title: focus.map(|f| f.display_name.clone()),
            label: focus.and_then(|f| f.label.clone()),
            model,
            sensitive: false,
        }
    }

    /// The focus registry changed: refresh the live conversations' titles.
    pub(super) fn refresh_conversation_titles(&self) {
        for (tag, session) in &self.sessions {
            if let Some(sid) = &session.session_id {
                let meta = self.conversation_meta(tag, false);
                if meta.title.is_some() {
                    self.conversations.refresh_meta(sid, meta, now_ms());
                }
            }
        }
    }

    /// Session id → `(tag, open)` for the sessions running now.
    fn live_conversations(&self) -> HashMap<String, (String, bool)> {
        self.sessions
            .iter()
            .filter(|(_, s)| s.alive())
            .filter_map(|(tag, s)| {
                let sid = s.session_id.clone()?;
                let open = self.focus_registry.iter().any(|f| &f.tag == tag);
                Some((sid, (tag.clone(), open)))
            })
            .collect()
    }

    /// The answer to `ConversationHistoryGet`.
    pub fn conversation_history_msg(&mut self, request_id: String) -> ServerMsg {
        let snap = self.conversations.snapshot();
        let live = self.live_conversations();
        let listing = list::build(&snap, &self.conversations, &live);
        if (!listing.to_check.is_empty() || !listing.to_locate.is_empty())
            && !self.conv.background_running.swap(true, Ordering::SeqCst)
        {
            let history = self.conversations.clone();
            let running = Arc::clone(&self.conv.background_running);
            std::thread::spawn(move || {
                list::run_background(&history, &listing.to_check, &listing.to_locate);
                running.store(false, Ordering::SeqCst);
            });
        }
        ServerMsg::ConversationHistory {
            request_id,
            entries: listing.entries,
            first_prompts_enabled: snap.first_prompts_enabled,
            degraded_kept: snap.degraded_kept,
            revision: snap.revision,
        }
    }

    /// Tell the operator app's connections, at most every 500 ms, that the
    /// history changed. Payload-free, and never on the broadcast channel.
    pub fn flush_conversation_nudge(&mut self) {
        let revision = self.conversations.revision();
        if revision == self.conv.nudged_revision {
            return;
        }
        if self.conv.nudged_at.is_some_and(|t| t.elapsed() < NUDGE_MIN_GAP) {
            return;
        }
        self.conv.nudged_at = Some(Instant::now());
        self.conv.nudged_revision = revision;
        let senders = self.client_senders.lock().unwrap();
        for (conn, tx) in senders.iter() {
            if self.conv.operator_conns.contains(conn) {
                let _ = tx.send(ServerMsg::ConversationHistoryChanged { revision });
            }
        }
    }

    /// Tell the operator app's connections that resumed focus `tag` could not
    /// open its conversation.
    fn notify_resume_failed(&self, tag: &str) {
        let senders = self.client_senders.lock().unwrap();
        for (conn, tx) in senders.iter() {
            if self.conv.operator_conns.contains(conn) {
                let _ = tx.send(ServerMsg::ConversationResumeFailed {
                    tag: tag.to_owned(),
                    reason: "not_found_here".to_owned(),
                });
            }
        }
    }

    /// `tag` was resumed from history and Claude says it has no such
    /// conversation here: leave no empty focus pretending. Stops the child,
    /// keeps the stored id, restores the entry's previous owner and tells the app.
    pub(super) fn fail_resumed_tag(&mut self, tag: &str) {
        let Some(info) = self.conv.resumed.remove(tag) else {
            return;
        };
        self.stop_session(tag);
        self.sessions.remove(tag);
        self.session_history.undo_move(&info.sid, &info.old_tag, tag);
        self.conversations.restore_tag(&info.sid, &info.old_tag, now_ms());
        self.conv.reserved.remove(&info.sid);
        self.notify_resume_failed(tag);
        tracing::warn!(tag, "a resumed conversation could not be opened");
    }

    /// Is `tag` a focus handed a conversation by a resume that has not spoken yet?
    pub(super) fn is_resumed_tag(&self, tag: &str) -> bool {
        self.conv.resumed.contains_key(tag)
    }

    /// Resume conversation `sid` as focus `new_tag`. Everything under the
    /// caller's one manager lock; idempotent per conversation.
    pub fn resume_conversation(&mut self, sid: &str, new_tag: &str) -> ServerMsg {
        let refuse = |reason: &str| ServerMsg::ConversationResumeResult {
            request_id: String::new(),
            outcome: ConversationResumeOutcome::Refused,
            tag: None,
            reason: Some(reason.to_owned()),
            agent: None,
            project_path: None,
            label: None,
            title: None,
        };
        let switch = |tag: &str| ServerMsg::ConversationResumeResult {
            request_id: String::new(),
            outcome: ConversationResumeOutcome::Switch,
            tag: Some(tag.to_owned()),
            reason: None,
            agent: None,
            project_path: None,
            label: None,
            title: None,
        };
        if self.awaiting_mcp_bridge {
            return refuse("starting");
        }
        let Some(entry) = self
            .conversations
            .get(sid)
            .filter(|e| e.has_turn && e.removed_at_ms.is_none())
        else {
            return refuse("not_found");
        };
        let live = self.live_conversations();
        let live_here = live.get(sid).cloned();
        match status_now(&entry, &self.conversations, live_here.as_ref()) {
            ConversationStatus::Running { tag, open: true } => return switch(&tag),
            ConversationStatus::UnavailableDeleted | ConversationStatus::UnavailableUnreadable => {
                return refuse("unavailable")
            }
            ConversationStatus::FolderGone { .. } => return refuse("folder_gone"),
            ConversationStatus::Running { open: false, .. } | ConversationStatus::Available => {}
        }
        // A resume already reserved a tag for it: that is the answer, live or not.
        if let Some((tag, at)) = self.conv.reserved.get(sid) {
            let in_registry = self.focus_registry.iter().any(|f| &f.tag == tag);
            if in_registry || at.elapsed() < RESERVATION_WINDOW {
                return switch(tag);
            }
        }
        // Running under a tag no focus has (a removed focus whose child lives
        // on): stop it first. Never two processes on one conversation.
        if let Some((old_tag, _)) = live_here {
            self.stop_session(&old_tag);
            self.sessions.remove(&old_tag);
            save_id(&self.store_path, &old_tag, None);
            self.login_changed();
        }
        if self.sessions.get(new_tag).is_some_and(|s| s.alive())
            || load_id_store(&self.store_path).contains_key(new_tag)
        {
            return refuse("unavailable");
        }
        save_id(&self.store_path, new_tag, Some(sid));
        // The conversation's model, unless the new tag already has a record.
        if let Some(model) = entry.model.clone() {
            let effort = entry.effort.clone();
            let _ = model_store::update_focus_record(
                &self.model_hub.paths.focus_models,
                new_tag,
                |existing| {
                    existing.or(Some(FocusModelRecord {
                        model,
                        effort,
                        source: ModelSource::Focus,
                        ..FocusModelRecord::default()
                    }))
                },
            );
        }
        // Sensitive before anything of it can exist under the new tag.
        // The live registry is asked too: the entry's flag can lag it.
        if entry.sensitive || self.sensitive.focus_is_sensitive(&entry.tag, &entry.agent) {
            self.sensitive.mark_tag(new_tag);
        }
        self.session_history.move_session(sid, &entry.tag, new_tag);
        self.conversations.move_to_tag(sid, new_tag, now_ms());
        self.conv.resumed.insert(
            new_tag.to_owned(),
            ResumedTag {
                sid: sid.to_owned(),
                old_tag: entry.tag.clone(),
            },
        );
        self.conv
            .reserved
            .insert(sid.to_owned(), (new_tag.to_owned(), Instant::now()));
        ServerMsg::ConversationResumeResult {
            request_id: String::new(),
            outcome: ConversationResumeOutcome::Ready,
            tag: Some(new_tag.to_owned()),
            reason: None,
            agent: Some(entry.agent.clone()),
            project_path: entry.project_path.clone(),
            label: entry.label.clone(),
            title: Some(entry.user_title.clone().unwrap_or(entry.title.clone())),
        }
    }
}

/// A turn completed in session `sid`: bump the entry's time and read what was
/// appended to its transcript on a thread of its own (never under a lock).
/// A conversation the history does not hold (a restricted session) costs nothing.
pub(super) fn turn_completed(history: &ConversationHistory, sid: &str) {
    if history.get(sid).is_none() {
        return;
    }
    history.turn_completed(sid, now_ms());
    let history = history.clone();
    let sid = sid.to_owned();
    std::thread::spawn(move || crate::conversations::transcript::refresh_tail(&history, &sid));
}
