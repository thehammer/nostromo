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
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// At most one history-changed nudge per this long.
const NUDGE_MIN_GAP: Duration = Duration::from_millis(500);
/// A tag reserved by a resume stands in for a registry entry this long (the
/// Mac pushes the new focus a moment after the reply).
const RESERVATION_WINDOW: Duration = Duration::from_secs(15);

/// Where a resumed tag runs when its conversation's worktree is gone, and what
/// to tell the agent about it. Kept per tag beside the stored session id and
/// read at every spawn of the tag (a restart included).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct ResumePlace {
    /// The folder the conversation runs in now (the main checkout).
    pub path: String,
    /// One paragraph: told to the agent through the spawn, and shown once as a note.
    pub notice: String,
    /// The note has been shown in the transcript.
    #[serde(default)]
    pub shown: bool,
    /// The conversation it was made for: a later conversation under the same
    /// tag (New Session) is not this one and gets no place.
    #[serde(default)]
    pub sid: String,
    /// What the history entry held before the move, put back when the resume
    /// is cancelled or fails.
    #[serde(default)]
    pub old_path: Option<String>,
    #[serde(default)]
    pub old_main: Option<String>,
    /// The entry was a no-codebase one before the move.
    #[serde(default)]
    pub old_no_codebase: bool,
    /// The place is a new no-codebase folder.
    #[serde(default)]
    pub no_codebase: bool,
    /// When it was made (ms), for pruning.
    #[serde(default)]
    pub at_ms: i64,
}

/// Places kept at most this many, newest first, and at most this old.
const PLACES_MAX: usize = 64;
const PLACES_MAX_AGE_MS: i64 = 90 * 24 * 60 * 60 * 1000;

/// The text of a resume into another place. Names both folders, and both
/// branches when they differ.
fn moved_notice(
    old_path: Option<&str>,
    new_path: &str,
    old_branch: Option<&str>,
    new_branch: Option<&str>,
) -> String {
    let mut text = match old_path {
        Some(old) => {
            format!("This conversation ran in {old}, which no longer exists. Now in {new_path}.")
        }
        None => format!("This conversation's folder no longer exists. Now in {new_path}."),
    };
    if let (Some(old), Some(new)) = (old_branch, new_branch) {
        if old != new {
            text.push_str(&format!(" It was on {old}; {new} is checked out here."));
        }
    }
    text
}

/// The text of a resume into a new no-codebase folder.
fn no_codebase_notice(old_path: Option<&str>) -> String {
    match old_path {
        Some(old) => format!(
            "This conversation ran in {old}, which no longer exists. Now in a no-codebase folder."
        ),
        None => {
            "This conversation's folder no longer exists. Now in a no-codebase folder.".to_owned()
        }
    }
}

/// The branch checked out in `dir` (from `.git/HEAD`); `None` when detached or unreadable.
fn current_branch(dir: &Path) -> Option<String> {
    let head = std::fs::read_to_string(dir.join(".git").join("HEAD")).ok()?;
    head.trim()
        .strip_prefix("ref: refs/heads/")
        .map(str::to_owned)
}

/// Add `extra` to the `--append-system-prompt` value in `args` (concatenated
/// after what is there, one paragraph apart), or add the flag when absent.
/// Never two flags.
pub(super) fn append_system_prompt_extra(args: &mut Vec<String>, extra: &str) {
    const FLAG: &str = "--append-system-prompt";
    match args.iter().position(|a| a == FLAG) {
        Some(i) if i + 1 < args.len() => {
            args[i + 1] = format!("{}\n\n{extra}", args[i + 1]);
        }
        _ => args.extend([FLAG.to_owned(), extra.to_owned()]),
    }
}

/// How a resume is asked for beyond the conversation id and new tag.
#[derive(Debug, Default, Clone, Copy)]
pub struct ResumeOptions<'a> {
    /// Resume in this folder instead of the original (only for a conversation
    /// whose worktree is gone, and only its own main checkout).
    pub place: Option<&'a str>,
    /// Resume in this new, empty no-codebase folder instead (only for a
    /// conversation whose folder is gone, and only a fresh child of the spaces root).
    pub no_codebase_folder: Option<&'a str>,
    /// The user chose "Resume anyway" for a conversation that may be open elsewhere.
    pub confirm_active_elsewhere: bool,
}

/// Resume bookkeeping and the nudge debounce, kept in one place.
#[derive(Default)]
pub(super) struct ConversationState {
    /// sid → (tag, when) of the latest resume.
    pub reserved: HashMap<String, (String, Instant)>,
    pub nudged_revision: u64,
    pub nudged_at: Option<Instant>,
    pub background_running: Arc<AtomicBool>,
    pub operator_conns: std::collections::HashSet<String>,
}

impl SessionManager {
    fn places_path(&self) -> PathBuf {
        self.store_path.with_file_name("resume-places.json")
    }

    pub(super) fn load_places(&self) -> HashMap<String, ResumePlace> {
        crate::mother::origin::load_json(&self.places_path())
    }

    fn save_places(&self, places: &HashMap<String, ResumePlace>) {
        if crate::mother::origin::write_private(&self.places_path(), places).is_err() {
            tracing::warn!("resume places could not be written");
        }
    }

    /// Where `tag` runs because of a resume of conversation `sid`, if it does.
    pub(super) fn resume_place_for(&self, tag: &str, sid: &str) -> Option<ResumePlace> {
        self.load_places()
            .remove(tag)
            .filter(|p| !p.sid.is_empty() && p.sid == sid)
    }

    pub(super) fn insert_place(&self, tag: &str, place: ResumePlace) {
        let mut places = self.load_places();
        places.insert(tag.to_owned(), place);
        let now = now_ms();
        places.retain(|_, p| now - p.at_ms <= PLACES_MAX_AGE_MS);
        if places.len() > PLACES_MAX {
            let mut by_age: Vec<(String, i64)> =
                places.iter().map(|(t, p)| (t.clone(), p.at_ms)).collect();
            by_age.sort_by_key(|(_, at)| *at);
            for (t, _) in by_age.into_iter().take(places.len() - PLACES_MAX) {
                places.remove(&t);
            }
        }
        self.save_places(&places);
    }

    /// The note for `tag`'s place has been shown.
    pub(super) fn mark_place_shown(&self, tag: &str) {
        let mut places = self.load_places();
        if let Some(p) = places.get_mut(tag) {
            p.shown = true;
            self.save_places(&places);
        }
    }

    /// `tag` no longer runs in a resumed place (New Session, or its focus is gone).
    pub(super) fn forget_place(&self, tag: &str) {
        let mut places = self.load_places();
        if places.remove(tag).is_some() {
            self.save_places(&places);
        }
    }

    /// Reverse what a resume that never opened its conversation did beyond the
    /// tag: the entry's folder, the place record and the tracker binding.
    fn undo_resume_effects(&self, tag: &str, sid: &str) {
        let mut places = self.load_places();
        if let Some(p) = places.remove(tag) {
            if p.sid == sid {
                self.conversations.restore_place(
                    sid,
                    p.old_path,
                    p.old_main,
                    p.old_no_codebase,
                    now_ms(),
                );
            }
            self.save_places(&places);
        }
        if let Some(provider) = &self.tracker_frame_provider {
            provider.unbind_board(tag);
        }
    }

    /// `place` when it is `entry`'s own main checkout and still a git checkout.
    fn usable_place(
        entry: &crate::conversations::ConversationEntry,
        place: Option<&str>,
    ) -> Option<String> {
        let place = place?;
        let main = entry.main_checkout.as_deref()?;
        (place == main && Path::new(place).is_dir() && Path::new(place).join(".git").exists())
            .then(|| place.to_owned())
    }

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
                no_codebase: focus.is_some_and(|f| f.no_codebase == Some(true)),
            },
            now_ms(),
        );
    }

    /// A user message was written into `tag`'s session.
    pub(super) fn note_conversation_send(&mut self, tag: &str, text: &str, has_images: bool) {
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
            no_codebase: focus.is_some_and(|f| f.no_codebase == Some(true)),
            tracker_board: self
                .tracker_frame_provider
                .as_ref()
                .and_then(|p| p.bound_board_path(tag))
                .map(|p| p.to_string_lossy().into_owned()),
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
        // A tag that became sensitive since its last send: purged before it is listed.
        self.conversations.sweep_sensitive(
            |tag, agent| self.sensitive.focus_is_sensitive(tag, agent),
            now_ms(),
        );
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
            referenced_space_folders: referenced_space_folders(
                self.conversations.all_project_paths(),
            ),
            spaces_root: crate::conversations::spaces_root_for_wire(),
        }
    }

    /// Tell the operator app's connections, at most every 500 ms, that the
    /// history changed. Payload-free, and never on the broadcast channel.
    pub fn flush_conversation_nudge(&mut self) {
        let revision = self.conversations.revision();
        if revision == self.conv.nudged_revision {
            return;
        }
        if self
            .conv
            .nudged_at
            .is_some_and(|t| t.elapsed() < NUDGE_MIN_GAP)
        {
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
        let Some((sid, old_tag)) = self.conversations.pending_resume_for_tag(tag) else {
            return;
        };
        self.stop_session(tag);
        self.sessions.remove(tag);
        // The new tag keeps no stored id: a later respawn must not start a
        // conversation of its own under it.
        save_id(&self.store_path, tag, None);
        self.session_history.undo_move(&sid, &old_tag, tag);
        self.conversations.restore_tag(&sid, &old_tag, now_ms());
        self.conv.reserved.remove(&sid);
        self.undo_resume_effects(tag, &sid);
        self.notify_resume_failed(tag);
        tracing::warn!(tag, "a resumed conversation could not be opened");
    }

    /// The app cancelled a resume before it made the focus: undo the reservation
    /// as a failed open would, minus the notice. Ignored when the tag is not a
    /// pending reservation, or a focus or session already holds it.
    pub fn release_resumed_tag(&mut self, tag: &str) {
        if self.sessions.contains_key(tag) || self.focus_registry.iter().any(|f| f.tag == tag) {
            return;
        }
        let Some((sid, old_tag)) = self.conversations.pending_resume_for_tag(tag) else {
            return;
        };
        if self.conv.reserved.get(&sid).map(|(t, _)| t.as_str()) != Some(tag) {
            return;
        }
        save_id(&self.store_path, tag, None);
        self.session_history.undo_move(&sid, &old_tag, tag);
        self.conversations.restore_tag(&sid, &old_tag, now_ms());
        self.conv.reserved.remove(&sid);
        self.undo_resume_effects(tag, &sid);
    }

    /// Is `tag` a focus handed a conversation by a resume whose first turn has
    /// not succeeded yet? (Kept in the history file: a daemon restart keeps it.)
    pub(super) fn is_resumed_tag(&self, tag: &str) -> bool {
        self.conversations.pending_resume_for_tag(tag).is_some()
    }

    /// Resume conversation `sid` as focus `new_tag`. Everything under the
    /// caller's one manager lock; idempotent per conversation.
    pub fn resume_conversation(&mut self, sid: &str, new_tag: &str) -> ServerMsg {
        self.resume_conversation_with(sid, new_tag, ResumeOptions::default())
    }

    /// [`Self::resume_conversation`] with the resume's options.
    pub fn resume_conversation_with(
        &mut self,
        sid: &str,
        new_tag: &str,
        options: ResumeOptions<'_>,
    ) -> ServerMsg {
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
        let mut moving: Option<String> = None;
        let mut moving_no_codebase = false;
        match status_now(&entry, &self.conversations, live_here.as_ref()) {
            ConversationStatus::Running { tag, open: true } => return switch(&tag),
            ConversationStatus::UnavailableDeleted | ConversationStatus::UnavailableUnreadable => {
                return refuse("unavailable")
            }
            // Only the conversation's own main checkout will do, and only when
            // the app asked for it.
            // The same two-minute rule as any other resume applies too: both
            // confirmations, enforced here, when both apply.
            ConversationStatus::FolderGone {
                active_elsewhere, ..
            } => {
                moving = Self::usable_place(&entry, options.place);
                if moving.is_none() {
                    moving = options
                        .no_codebase_folder
                        .filter(|f| crate::conversations::usable_space_folder(f))
                        .map(str::to_owned);
                    moving_no_codebase = moving.is_some();
                }
                if moving.is_none() {
                    return refuse("folder_gone");
                }
                if active_elsewhere && !options.confirm_active_elsewhere {
                    return refuse("active_elsewhere");
                }
            }
            // The daemon holds the line even for a client that skipped the prompt.
            ConversationStatus::ActiveElsewhere if !options.confirm_active_elsewhere => {
                return refuse("active_elsewhere")
            }
            ConversationStatus::Running { open: false, .. }
            | ConversationStatus::ActiveElsewhere
            | ConversationStatus::Available => {}
        }
        // The conversation's own focus is still open and still owns its stored
        // id (the daemon restarted, or the crash-loop guard gave up on it): that
        // focus is the answer. A second tag would be a second writer, and
        // opening the first later a second `--resume`.
        if self.focus_registry.iter().any(|f| f.tag == entry.tag)
            && load_id_store(&self.store_path)
                .get(&entry.tag)
                .map(String::as_str)
                == Some(sid)
        {
            return switch(&entry.tag);
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
        // The live registry is asked too: the entry's flag can lag it, so the
        // entry is marked here as well.
        if entry.sensitive || self.sensitive.focus_is_sensitive(&entry.tag, &entry.agent) {
            self.sensitive.mark_tag(new_tag);
            self.conversations.mark_sensitive(sid, now_ms());
        }
        // The tracker board follows the conversation: the old focus's binding
        // while it lasts, else the one last recorded. Nothing is created.
        if let Some(provider) = &self.tracker_frame_provider {
            let board = provider
                .bound_board_path(&entry.tag)
                .or_else(|| entry.tracker_board.as_deref().map(PathBuf::from));
            if let Some(board) = board {
                provider.bind_existing_board(new_tag, &board);
            }
        }
        // A conversation whose worktree is gone runs in its main checkout.
        let mut project_path = entry.project_path.clone();
        if let Some(place) = &moving {
            let notice = if moving_no_codebase {
                no_codebase_notice(entry.project_path.as_deref())
            } else {
                moved_notice(
                    entry.project_path.as_deref(),
                    place,
                    entry.branch.as_deref(),
                    current_branch(Path::new(place)).as_deref(),
                )
            };
            self.insert_place(
                new_tag,
                ResumePlace {
                    path: place.clone(),
                    notice,
                    shown: false,
                    sid: sid.to_owned(),
                    old_path: entry.project_path.clone(),
                    old_main: entry.main_checkout.clone(),
                    old_no_codebase: entry.no_codebase,
                    no_codebase: moving_no_codebase,
                    at_ms: now_ms(),
                },
            );
            self.conversations
                .set_place(sid, place, moving_no_codebase, now_ms());
            project_path = Some(place.clone());
        }
        self.session_history.move_session(sid, &entry.tag, new_tag);
        self.conversations.move_to_tag(sid, new_tag, now_ms());
        self.conv
            .reserved
            .insert(sid.to_owned(), (new_tag.to_owned(), Instant::now()));
        ServerMsg::ConversationResumeResult {
            request_id: String::new(),
            outcome: ConversationResumeOutcome::Ready,
            tag: Some(new_tag.to_owned()),
            reason: None,
            agent: Some(entry.agent.clone()),
            project_path,
            // The user's own name for it, when it has one, labels the new focus.
            label: entry.user_title.clone().or_else(|| entry.label.clone()),
            title: Some(entry.user_title.clone().unwrap_or(entry.title.clone())),
        }
    }
}

/// The folders under the spaces root that any entry not yet purged names, hidden
/// or visible, sensitive or not. The app trashes every other folder there, so
/// this errs toward listing: a path counts when its parent IS the root by file
/// identity (device and inode), however either is spelled.
fn referenced_space_folders(paths: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = paths
        .into_iter()
        .filter(|p| crate::conversations::is_direct_space_child(p))
        .map(|p| crate::conversations::space_folder_wire_name(&p))
        .collect();
    out.sort();
    out.dedup();
    out
}

/// A turn completed in the session `shared` belongs to: bump the entry's time,
/// commit a first message that was delivered, purge an entry whose focus is
/// sensitive now, and read what was appended to the transcript on a thread of
/// its own (never under a lock). `delivered` is false for a turn that failed to
/// sign in: its message is held, not delivered. A conversation the history does
/// not hold (a restricted session) costs nothing.
pub(super) fn turn_completed(shared: &super::Shared, delivered: bool) {
    let sid = &shared.ctx.session_id;
    let history = &shared.conversations;
    if history.get(sid).is_none() {
        return;
    }
    let sensitive = shared
        .sensitive
        .focus_is_sensitive(&shared.ctx.tag, &shared.ctx.agent_name);
    history.turn_completed(sid, delivered, sensitive, now_ms());
    let history = history.clone();
    let sid = sid.clone();
    std::thread::spawn(move || crate::conversations::transcript::refresh_tail(&history, &sid));
}
