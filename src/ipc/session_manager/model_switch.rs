//! The model-switching runtime of a session: what it runs, a switch in
//! progress, the control requests that apply one, and the notes and state
//! frames that report it. Switch logic lives here; `session_manager` keeps
//! the thin hooks (the reader's `on_model_report`, the queue discipline in
//! `step`, and spawn/restart carry-over).
//!
//! See the model-switching design contract, section 2.2.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use tokio::sync::{broadcast, oneshot};
use tracing::{info, warn};
use uuid::Uuid;

use super::control::{control, ControlFailure, ControlReply};
use super::{
    advance, finish_apply, load_id_store, lock_recover, write_control_request, PendingMessage,
    SessionEvent, SessionManager, Shared, WRITE_WAIT_LIMIT,
};
use crate::ipc::protocol::{
    EffortChoice, ModelRequestStatus, PendingModel, RecordedModel, ReportedModel, ServerMsg,
    SessionModelState, SwitchPhase,
};
use crate::ipc::stream_json::{load_scrollback, SessionState, TurnBlock};
use crate::model::activity::{self as model_activity, ModelActivity, ModelActivityKind, Outcome};
use crate::model::catalog::{find_key, ModelCatalog};
use crate::model::hub::{probe_before_use, ModelHub, FIRST_PROBE_WAIT};
use crate::model::notes::{self, LedgerNote, NoteKind};
use crate::model::store::{self as model_store, FocusModelRecord, ModelSource};
use crate::model::{copy, policy, Actor, ModelTarget};

/// Identity of one session, fixed for its life.
#[derive(Clone)]
pub(super) struct SessionCtx {
    pub(super) tag: String,
    pub(super) agent_name: String,
    pub(super) session_id: String,
    /// Restricted sessions have no model record and refuse switches.
    pub(super) restricted: bool,
    pub(super) hub: Arc<ModelHub>,
}

impl SessionCtx {
    /// The identity of a focus with no running session (so never restricted),
    /// for logging a switch made while it is down.
    pub(super) fn stopped(
        tag: &str,
        agent_name: Option<&str>,
        session_id: Option<&str>,
        hub: &Arc<ModelHub>,
    ) -> Self {
        Self {
            tag: tag.to_owned(),
            agent_name: agent_name.unwrap_or_default().to_owned(),
            session_id: session_id.unwrap_or_default().to_owned(),
            restricted: false,
            hub: Arc::clone(hub),
        }
    }
}

/// Per-session model state (see `Shared::model`).
#[derive(Default)]
pub(super) struct ModelRuntime {
    /// A switch being applied right now. No user frame is written meanwhile.
    pub(super) applying: Option<ModelTarget>,
    /// A switch waiting for the running turn to end (and its requester).
    pub(super) waiting: Option<(ModelTarget, Actor)>,
    /// The focus's store record as of the last write this session saw.
    pub(super) recorded: Option<FocusModelRecord>,
    /// The model the session last reported (init, assistant or get_settings).
    pub(super) reported: Option<String>,
    /// The effort the session last confirmed through `get_settings`.
    pub(super) effective_effort: Option<String>,
    /// Content of the latest `model_fallback` event, for the mismatch note.
    pub(super) fallback: Option<String>,
    /// The last (asked, running) mismatch a note was made for.
    pub(super) noted_mismatch: Option<(String, String)>,
}

/// What a model state needs of a [`ModelRuntime`], copied out so the rest of
/// the state can be built (and its files read) without holding the lock.
pub(super) struct RuntimeView {
    reported: Option<String>,
    effective_effort: Option<String>,
    pending: Option<ModelTarget>,
    phase: SwitchPhase,
}

impl ModelRuntime {
    pub(super) fn view(&self) -> RuntimeView {
        RuntimeView {
            reported: self.reported.clone(),
            effective_effort: self.effective_effort.clone(),
            pending: self
                .applying
                .clone()
                .or_else(|| self.waiting.as_ref().map(|(t, _)| t.clone())),
            phase: self.phase(),
        }
    }

    pub(super) fn phase(&self) -> SwitchPhase {
        if self.applying.is_some() {
            SwitchPhase::Applying
        } else if self.waiting.is_some() {
            SwitchPhase::Waiting
        } else {
            SwitchPhase::Steady
        }
    }
}

/// How long model state of a focus that no longer exists is kept.
pub const MODEL_STATE_RETENTION: chrono::Duration = chrono::Duration::days(30);

/// What [`SessionManager::sweep_model_state`] removed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ModelSweep {
    pub records_removed: usize,
    pub ledgers_removed: usize,
    pub request_state_removed: usize,
}

/// A request to change a focus's model and/or effort. `None` keeps the
/// current value.
#[derive(Debug, Clone)]
pub struct SwitchRequest {
    pub model: Option<String>,
    pub effort: Option<EffortChoice>,
    pub actor: Actor,
    /// Also make the result the default for new focuses of this agent.
    pub set_as_agent_default: bool,
    /// The client's id for this request, echoed in `last_request`.
    pub request_id: Option<String>,
}

/// What became of a model request (the body of `ModelRequestResult`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelRequestOutcome {
    pub status: ModelRequestStatus,
    pub code: Option<String>,
    pub message: Option<String>,
    pub warning: Option<String>,
}

impl ModelRequestOutcome {
    fn status(status: ModelRequestStatus) -> Self {
        Self {
            status,
            code: None,
            message: None,
            warning: None,
        }
    }

    fn failed(message: impl Into<String>) -> Self {
        Self {
            status: ModelRequestStatus::Failed,
            code: None,
            message: Some(message.into()),
            warning: None,
        }
    }

    fn refused(code: &str, message: impl Into<String>) -> Self {
        Self {
            status: ModelRequestStatus::Refused,
            code: Some(code.to_owned()),
            message: Some(message.into()),
            warning: None,
        }
    }
}

/// The answer to [`SessionManager::request_switch`]: known at once, or once
/// the switch has been applied to an idle session.
pub struct SwitchTicket(TicketInner);

enum TicketInner {
    Ready(ModelRequestOutcome),
    Later(oneshot::Receiver<ModelRequestOutcome>),
}

impl SwitchTicket {
    fn ready(outcome: ModelRequestOutcome) -> Self {
        Self(TicketInner::Ready(outcome))
    }

    /// The outcome, if it was known when the request was made.
    pub fn immediate(&self) -> Option<&ModelRequestOutcome> {
        match &self.0 {
            TicketInner::Ready(outcome) => Some(outcome),
            TicketInner::Later(_) => None,
        }
    }

    /// The outcome, waiting for the switch to be applied if need be.
    pub async fn outcome(self) -> ModelRequestOutcome {
        match self.0 {
            TicketInner::Ready(outcome) => outcome,
            TicketInner::Later(rx) => rx
                .await
                .unwrap_or_else(|_| ModelRequestOutcome::failed("the switch was abandoned")),
        }
    }
}

impl SessionManager {
    // ── model switching ───────────────────────────────────────────────────────

    /// Broadcast model frames (`SessionModelState`, `ModelCatalog`,
    /// `ModelDefaults`) on the daemon's client fan-out.
    pub fn configure_model_broadcast(&mut self, tx: broadcast::Sender<ServerMsg>) {
        self.model_hub.set_broadcast(tx);
    }

    /// The daemon-wide model state (catalogue, files, broadcasts).
    pub fn model_hub(&self) -> Arc<ModelHub> {
        Arc::clone(&self.model_hub)
    }

    /// Install a model catalogue (cached on disk and broadcast).
    pub fn set_model_catalog(&mut self, catalog: ModelCatalog) {
        self.model_hub.set_catalog(catalog);
    }

    pub fn model_catalog(&self) -> ModelCatalog {
        self.model_hub.catalog()
    }

    /// `ServerMsg::ModelDefaults` as of now.
    pub fn model_defaults_msg(&self) -> ServerMsg {
        self.model_hub.defaults_msg()
    }

    /// `tag`'s model state: its record, and what its session reports.
    pub fn session_model_state(&self, tag: &str) -> SessionModelState {
        let record = model_store::focus_record(&self.model_hub.paths.focus_models, tag);
        self.model_state_of(tag, record, model_activity::current_posture())
    }

    /// The state of every tag in [`Self::model_state_tags`] (what a client
    /// subscribing to the model topic is replayed), reading the store and the
    /// posture once for all of them.
    pub fn model_state_replay(&self) -> Vec<SessionModelState> {
        let mut records = model_store::load_focus_models(&self.model_hub.paths.focus_models);
        let posture = model_activity::current_posture();
        let tags = self.tags_with_model_state(records.keys().cloned());
        tags.into_iter()
            .map(|tag| {
                let record = records.remove(&tag);
                self.model_state_of(&tag, record, posture.clone())
            })
            .collect()
    }

    /// Every tag that has a model state worth replaying to a client: live
    /// sessions, registered focuses and recorded focuses.
    pub fn model_state_tags(&self) -> Vec<String> {
        let recorded =
            model_store::load_focus_models(&self.model_hub.paths.focus_models).into_keys();
        self.tags_with_model_state(recorded)
    }

    fn tags_with_model_state(&self, recorded: impl Iterator<Item = String>) -> Vec<String> {
        let mut tags = self.known_focus_tags();
        for tag in recorded {
            if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
        tags.retain(|t| !self.restrictions.contains_key(t));
        tags
    }

    fn model_state_of(
        &self,
        tag: &str,
        record: Option<FocusModelRecord>,
        posture: Option<String>,
    ) -> SessionModelState {
        // The runtime is read under its lock; the rest is built outside it.
        let (view, running) = match self.sessions.get(tag) {
            Some(session) => (
                Some(lock_recover(&session.shared.model).view()),
                session.alive(),
            ),
            None => (None, false),
        };
        model_state_from(&self.model_hub, tag, view, running, record, posture)
    }

    /// Put a one-line note for the agent in front of the next user message
    /// written to `tag`'s session (stripped from what clients display).
    pub fn set_next_message_note(&mut self, tag: &str, note: String) -> Result<()> {
        let session = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
        *session.shared.note_prefix.lock().unwrap() = Some(note);
        Ok(())
    }

    /// Change `tag`'s model and/or effort.
    ///
    /// - Restricted focuses refuse (`not_permitted`); an unknown model or an
    ///   effort the model does not support is refused before anything is sent.
    /// - The current model again: `Unchanged`, silently; it also cancels a
    ///   switch waiting for the turn to end.
    /// - Idle session: applied at once (the ticket resolves when it is).
    /// - Turn running: waits for the turn to end (`PendingTurnEnd`); choosing
    ///   again replaces the target.
    /// - No running session: only the record changes.
    pub fn request_switch(&mut self, tag: &str, req: SwitchRequest) -> SwitchTicket {
        let hub = Arc::clone(&self.model_hub);
        hub.begin_request(tag, req.request_id.clone());
        let catalog = hub.catalog();
        let agent = self.agent_of(tag);
        let record = model_store::focus_record(&hub.paths.focus_models, tag);
        let session = self.sessions.get(tag);
        let reported = session.and_then(|s| lock_recover(&s.shared.model).reported.clone());
        // A switch of a stopped focus still being written is what it runs now.
        let current = hub
            .stored_target(tag)
            .or_else(|| current_target(record.as_ref(), reported.as_deref(), &catalog));
        let session_id = session
            .and_then(|s| s.session_id.clone())
            .or_else(|| load_id_store(&self.store_path).get(tag).cloned());

        let ctx = SessionCtx::stopped(tag, agent.as_deref(), session_id.as_deref(), &hub);
        // A focus the daemon has never heard of: refusing keeps a typo'd or
        // departed tag from leaving a record that nothing will ever clean up.
        let known = session.is_some()
            || record.is_some()
            || session_id.is_some()
            || self.known_focus_tags().iter().any(|t| t == tag);
        let refuse = |to: &ModelTarget, code: &str, message: String| {
            log_switch(
                &ctx,
                current.as_ref(),
                to,
                &req.actor,
                Outcome::Refused,
                Some(code.to_owned()),
                message.clone(),
            );
            hub.record_request(tag, &req.actor, to, ModelRequestStatus::Refused);
            SwitchTicket::ready(ModelRequestOutcome::refused(code, message))
        };

        let model = req
            .model
            .clone()
            .or_else(|| current.as_ref().map(|c| c.model.clone()));
        let Some(model) = model else {
            return refuse(
                &default_target(),
                "unknown_model",
                "no model given and none recorded".into(),
            );
        };
        let effort = match req.effort {
            Some(choice) => choice.level().map(str::to_owned),
            // Keep the current effort if the new model takes it.
            None => current.as_ref().and_then(|c| c.effort.clone()).filter(|e| {
                catalog
                    .entry(&model)
                    .map(|m| m.supports_effort_level(e))
                    .unwrap_or(true)
            }),
        };
        let target = ModelTarget { model, effort };

        if !known {
            // A restarted daemon has heard of no focus until the Mac pushes
            // its registry, so a real focus looks exactly like a typo'd one.
            // Until then the caller is told to try again, not that the focus
            // does not exist.
            if !self.registry_known() {
                return refuse(
                    &target,
                    "registry_not_ready",
                    format!(
                        "nostromd is still learning which focuses exist; try again shortly ({tag})"
                    ),
                );
            }
            return refuse(&target, "unknown_focus", format!("no focus named {tag}"));
        }
        if self.restrictions.contains_key(tag) {
            return refuse(
                &target,
                "not_permitted",
                "this session's model can't be changed".into(),
            );
        }
        if let Err((code, message)) = validate_target(&target, &catalog) {
            return refuse(&target, code, message);
        }

        if req.set_as_agent_default {
            if let Some(agent) = agent.as_deref().filter(|a| !a.is_empty()) {
                self.write_agent_default(agent, Some(&target), &req.actor);
            }
        }

        match session.filter(|s| s.alive()) {
            Some(session) => begin_switch(&session.shared.clone(), current, target, req.actor),
            None => self.switch_not_running(&ctx, current, target, req.actor),
        }
    }

    /// A switch of a focus whose session is not running: record it for the
    /// next start. The store write, the note and the activity line are made
    /// on the hub's IO thread, not here (this runs under the manager lock,
    /// and a durable write is slow); the ticket resolves once they are done.
    /// Writes run in the order they were asked for.
    pub(super) fn switch_not_running(
        &mut self,
        ctx: &SessionCtx,
        current: Option<ModelTarget>,
        target: ModelTarget,
        actor: Actor,
    ) -> SwitchTicket {
        let Some(job) = self.stored_switch(ctx, current, target, actor) else {
            return SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged));
        };
        let (tx, rx) = oneshot::channel();
        self.model_hub.spawn_io(Box::new(move || {
            let _ = tx.send(job.run());
        }));
        SwitchTicket(TicketInner::Later(rx))
    }

    /// What recording a switch of a stopped focus takes, or `None` when the
    /// focus already has that model. Also drops the switch the dead process
    /// still had waiting: this choice supersedes it, and a crash recovery
    /// would otherwise apply it.
    fn stored_switch(
        &mut self,
        ctx: &SessionCtx,
        current: Option<ModelTarget>,
        target: ModelTarget,
        actor: Actor,
    ) -> Option<StoredSwitch> {
        if current.as_ref() == Some(&target) {
            return None;
        }
        let session = self.sessions.get(&ctx.tag).map(|s| s.shared.clone());
        if let Some(shared) = &session {
            lock_recover(&shared.model).waiting = None;
        }
        let seq = self.model_hub.note_stored(&ctx.tag, target.clone());
        Some(StoredSwitch {
            ctx: ctx.clone(),
            current,
            target,
            actor,
            session,
            seq,
        })
    }

    /// Set (or, with `clear`, remove) `agent`'s default model for new focuses.
    pub fn set_agent_default(
        &mut self,
        agent: &str,
        model: Option<String>,
        effort: Option<EffortChoice>,
        clear: bool,
    ) -> ModelRequestOutcome {
        if agent.trim().is_empty() {
            return ModelRequestOutcome::refused("not_permitted", "no agent named");
        }
        if clear {
            self.write_agent_default(agent, None, &Actor::User);
            return ModelRequestOutcome::status(ModelRequestStatus::Applied);
        }
        let Some(model) = model else {
            return ModelRequestOutcome::refused("unknown_model", "no model given");
        };
        let target = ModelTarget {
            model,
            effort: effort.and_then(EffortChoice::level).map(str::to_owned),
        };
        if let Err((code, message)) = validate_target(&target, &self.model_hub.catalog()) {
            return ModelRequestOutcome::refused(code, message);
        }
        self.write_agent_default(agent, Some(&target), &Actor::User);
        ModelRequestOutcome::status(ModelRequestStatus::Applied)
    }

    /// Write `agent`'s default, log it, and broadcast the defaults.
    ///
    /// This is a durable write under the manager lock, on purpose: the caller
    /// answers the client with the write's outcome (a failed write must not
    /// read as `Applied`), a client or the next `spawn_model` reads the
    /// default right after, and it is a rare, user-initiated change of one
    /// small file. Moving it to the IO thread would trade that for a
    /// shorter hold of a lock nothing contends for at that rate.
    fn write_agent_default(&self, agent: &str, target: Option<&ModelTarget>, actor: &Actor) {
        let hub = &self.model_hub;
        let previous = model_store::load_defaults(&hub.paths.defaults).remove(agent);
        let default = target.map(|t| model_store::AgentDefault {
            model: t.model.clone(),
            effort: t.effort.clone(),
        });
        if let Err(e) = model_store::set_default(&hub.paths.defaults, agent, default) {
            warn!(agent, "could not write the agent's default model: {e:#}");
            return;
        }
        let catalog = hub.catalog();
        let summary = match target {
            Some(t) => format!(
                "Default model for new {} focuses set to {}.",
                crate::model::catalog::family_display(agent),
                crate::model::label(t, t.effort.is_some(), &catalog)
            ),
            None => format!(
                "Default model for new {} focuses cleared.",
                crate::model::catalog::family_display(agent)
            ),
        };
        model_activity::append(
            &model_activity::activity_path(),
            &ModelActivity {
                agent: agent.to_owned(),
                kind: ModelActivityKind::ModelDefault,
                summary,
                session_id: None,
                agent_type: Some(agent.to_owned()),
                focus_tag: None,
                from: previous.map(|d| ModelTarget {
                    model: d.model,
                    effort: d.effort,
                }),
                to: target.cloned(),
                actor: actor.wire(),
                outcome: Outcome::Applied,
                reason: None,
                posture: model_activity::current_posture(),
            },
        );
        hub.broadcast(hub.defaults_msg());
    }

    /// At daemon start: a switch that was waiting for a turn to end when the
    /// daemon stopped will never apply. Clear it, and say so in the focus's
    /// transcript.
    pub fn clear_persisted_pending(&self) {
        let hub = &self.model_hub;
        let cleared = match model_store::clear_all_pending(&hub.paths.focus_models) {
            Ok(cleared) => cleared,
            Err(e) => {
                warn!("could not clear pending model switches: {e:#}");
                return;
            }
        };
        let ids = load_id_store(&self.store_path);
        let catalog = hub.catalog();
        for (tag, record) in cleared {
            let Some(pending) = &record.pending else {
                continue;
            };
            let text = copy::failed(&record.target(), pending, "nostromd restarted", &catalog);
            info!(
                tag,
                "dropped a model switch pending across a daemon restart"
            );
            let Some(sid) = ids.get(&tag) else { continue };
            note_while_stopped(hub, &tag, sid, NoteKind::ModelFailed, text.clone());
            let ctx = SessionCtx::stopped(&tag, None, Some(sid), hub);
            log_switch(
                &ctx,
                Some(&record.target()),
                pending,
                &Actor::User,
                Outcome::Failed,
                Some("nostromd restarted".into()),
                text,
            );
        }
    }

    /// Forget the model state of focuses that are long gone, so the files and
    /// maps do not grow without bound. Deliberately conservative: it does
    /// nothing until the focus registry is known (an unregistered tag may just
    /// be one not pushed yet), and only touches what is older than
    /// [`MODEL_STATE_RETENTION`] and belongs to no live or registered focus,
    /// nor one the daemon still holds a session id for (such a focus exists
    /// whether or not the Mac's registry lists it):
    /// store records (by `updated_at`), notes ledgers (by file age) and the
    /// last-request memory.
    pub fn sweep_model_state(&mut self, now: chrono::DateTime<chrono::Utc>) -> ModelSweep {
        let mut report = ModelSweep::default();
        if !self.registry_known() {
            return report;
        }
        let hub = Arc::clone(&self.model_hub);
        let cutoff = now - MODEL_STATE_RETENTION;
        // A focus the daemon still holds a session id for exists, whether or
        // not the Mac's registry lists it.
        let remembered = load_id_store(&self.store_path);
        let is_live = |tag: &str| {
            self.sessions.contains_key(tag)
                || self.focus_may_exist(tag)
                || remembered.contains_key(tag)
        };

        match model_store::sweep_focus_records(&hub.paths.focus_models, now, cutoff, is_live) {
            Ok(n) => report.records_removed = n,
            Err(e) => warn!("could not sweep the focus model store: {e:#}"),
        }

        report.ledgers_removed = self.sweep_ledgers(&hub, cutoff, is_live);

        report.request_state_removed = hub.forget_requests(is_live, cutoff);
        if report != ModelSweep::default() {
            info!(
                records = report.records_removed,
                ledgers = report.ledgers_removed,
                requests = report.request_state_removed,
                "swept stale model state"
            );
        }
        report
    }

    /// Delete the notes ledgers older than `cutoff` that no live focus resumes
    /// (a ledger is kept while any live focus resumes its session). Returns
    /// how many were deleted.
    fn sweep_ledgers(
        &self,
        hub: &ModelHub,
        cutoff: chrono::DateTime<chrono::Utc>,
        is_live: impl Fn(&str) -> bool,
    ) -> usize {
        let mut live_sessions: std::collections::HashSet<String> = load_id_store(&self.store_path)
            .into_iter()
            .filter(|(tag, _)| is_live(tag))
            .map(|(_, sid)| sid)
            .collect();
        live_sessions.extend(self.sessions.values().filter_map(|s| s.session_id.clone()));
        let Ok(entries) = std::fs::read_dir(&hub.paths.notes_dir) else {
            return 0;
        };
        let mut removed = 0;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(sid) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .map(|at| chrono::DateTime::<chrono::Utc>::from(at) < cutoff)
                .unwrap_or(false);
            if old && !live_sessions.contains(sid) && std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        removed
    }

    /// The agent a focus runs: its session's, else the pushed registry's.
    pub(super) fn agent_of(&self, tag: &str) -> Option<String> {
        self.sessions
            .get(tag)
            .map(|s| s.agent_name.clone())
            .or_else(|| {
                self.focus_registry
                    .iter()
                    .find(|f| f.tag == tag)
                    .map(|f| f.agent_name.clone())
            })
    }

    /// Write the model record of a **new** focus under `tag`, resolved by
    /// precedence (`explicit` > per-agent default > the agent's declared
    /// `model:` > CLI default; see [`model_store::resolve_for_new_focus`]).
    ///
    /// With `explicit` the focus is new by definition (a daemon-created one),
    /// so any stale record under the reused tag is replaced. Without it the
    /// record is written only when the tag has none, so an existing focus's
    /// record is never touched by a later change of a default.
    ///
    /// **`explicit` is a user's choice and nothing else.** Only the Mac's create
    /// sheet may supply one (it arrives as `FocusMeta.initial_*`, through
    /// [`Self::apply_initial_models`], from a local, non-network client). Nothing
    /// a tool, an agent, a script or a network peer sends may reach this
    /// parameter: a model it names could be a costlier upgrade that nobody
    /// approved. M5 adds that approval; until it lands, any other caller
    /// must pass `None`. (It is `pub` only because the integration tests drive
    /// it; production passes `None` at the one spawn site.)
    ///
    /// Returns the declared model when that is what was resolved: the record
    /// is then an observed one (a restart passes no `--model`), but the first
    /// start passes it. A CLI-default result writes nothing; the first report
    /// records what ran.
    pub fn record_new_focus_model(
        &self,
        tag: &str,
        agent: &str,
        explicit: Option<&ModelTarget>,
    ) -> Option<ModelTarget> {
        let hub = &self.model_hub;
        if explicit.is_none()
            && (hub.stored_target(tag).is_some()
                || model_store::focus_record(&hub.paths.focus_models, tag).is_some())
        {
            return None;
        }
        let (model, effort, source) =
            model_store::resolve_for_new_focus(&hub.paths.defaults, agent, explicit);
        let record = model.map(|model| FocusModelRecord {
            model,
            effort,
            source,
            ..FocusModelRecord::default()
        });
        if record.is_none() && explicit.is_none() {
            return None;
        }
        let target = record.as_ref().map(FocusModelRecord::target);
        if let Err(e) = model_store::update_focus_record(&hub.paths.focus_models, tag, |_| record) {
            warn!(tag, "could not record the new focus's model: {e:#}");
            return None;
        }
        target.filter(|_| source == ModelSource::AgentDeclared)
    }

    /// The model record a client chose for a focus it is creating
    /// (`FocusMeta.initial_*`), written when the tag has no record yet. A
    /// choice the CLI could never accept is ignored. Later pushes repeat the
    /// choice and find the record, so they change nothing.
    pub fn apply_initial_models(&self, focuses: &[crate::ipc::protocol::FocusMeta]) {
        for focus in focuses {
            let Some(model) = focus.initial_model.as_deref() else {
                continue;
            };
            let target = ModelTarget {
                model: model.to_owned(),
                effort: focus.initial_effort.clone(),
            };
            if !model_store::is_plausible_choice(&target) {
                warn!(tag = %focus.tag, "ignoring an unusable initial model choice");
                continue;
            }
            let hub = &self.model_hub;
            if hub.stored_target(&focus.tag).is_some()
                || model_store::focus_record(&hub.paths.focus_models, &focus.tag).is_some()
            {
                continue;
            }
            let written =
                model_store::update_focus_record(&hub.paths.focus_models, &focus.tag, |_| {
                    Some(FocusModelRecord {
                        model: target.model,
                        effort: target.effort,
                        source: ModelSource::Focus,
                        ..FocusModelRecord::default()
                    })
                });
            if let Err(e) = written {
                warn!(tag = %focus.tag, "could not record the chosen model: {e:#}");
            }
        }
    }

    /// The model a spawn of `tag` runs on, and the note to make about it.
    ///
    /// Only a *chosen* record (a switch, a creation choice, a per-agent
    /// default) is passed on: an observed one just remembers what the session
    /// ran, so the agent's front matter and the CLI default still apply.
    /// A switch of the stopped focus still being written counts as the record
    /// (the IO thread may not have reached it yet).
    ///
    /// Nothing stored is passed to `--model` until the installed CLI has
    /// vouched for the catalogue (a probe has succeeded in this daemon run):
    /// a catalogue read from the cache at start, or kept after a failed
    /// probe, can't say that a stored alias or name has not been retired, and
    /// the CLI rejects a start on one at every restart. So the first such
    /// spawn probes first (bounded wait); while no probe has succeeded the
    /// spawn passes no `--model` (the CLI's default applies, the record is
    /// left alone) and later spawns retry the probe in the background
    /// (throttled), passing the stored model as soon as one has succeeded.
    /// Once verified, a chosen model the catalogue no longer offers is
    /// replaced by the agent's default: per-agent default, else its declared
    /// model, else the CLI default (no record at all). An empty catalogue (no
    /// cache, nothing probed) can only vouch for the known aliases.
    pub(super) fn spawn_model(
        &self,
        tag: &str,
        agent: &str,
    ) -> (Option<ModelTarget>, Option<String>) {
        let hub = &self.model_hub;
        let record = match hub.stored_target(tag) {
            Some(target) => FocusModelRecord {
                model: target.model,
                effort: target.effort,
                source: ModelSource::Focus,
                ..FocusModelRecord::default()
            },
            None => match model_store::focus_record(&hub.paths.focus_models, tag) {
                Some(record) => record,
                None => return (None, None),
            },
        };
        if !record.source.is_chosen() {
            return (None, None);
        }
        let mut catalog = hub.catalog();
        if !catalog.is_empty() && !hub.verified_this_run() {
            probe_before_use(hub, FIRST_PROBE_WAIT);
            if !hub.verified_this_run() {
                warn!(tag, model = %record.model, "model catalogue not verified by the installed CLI yet: starting without --model");
                return (None, None);
            }
            catalog = hub.catalog();
        }
        // A stale catalogue here is one verified earlier in this run, so it
        // can't say a model went away; an empty one can't say anything but the
        // known aliases.
        let offered = (catalog.stale && !catalog.is_empty()) || is_offered(&record.model, &catalog);
        if offered {
            return (Some(record.target()), None);
        }
        let replacement = model_store::load_defaults(&hub.paths.defaults)
            .remove(agent)
            .filter(|d| is_offered(&d.model, &catalog))
            .map(|d| {
                (
                    ModelTarget {
                        model: d.model,
                        effort: d.effort,
                    },
                    ModelSource::AgentDefault,
                )
            })
            .or_else(|| {
                policy::declared_model(agent).map(|model| {
                    (
                        ModelTarget {
                            model,
                            effort: None,
                        },
                        ModelSource::AgentDeclared,
                    )
                })
            });
        // Written here, under the manager lock, rather than on the IO thread: the
        // session this spawn starts reports its model within moments, and that
        // report is judged against the record, which must already be the
        // replacement (not the retired model) by then. A start is a process
        // spawn already, and this happens once per retired model.
        let written = model_store::update_focus_record(&hub.paths.focus_models, tag, |_| {
            replacement
                .as_ref()
                .map(|(target, source)| FocusModelRecord {
                    model: target.model.clone(),
                    effort: target.effort.clone(),
                    source: *source,
                    ..FocusModelRecord::default()
                })
        });
        if let Err(e) = written {
            warn!(
                tag,
                "could not replace a model that is no longer offered: {e:#}"
            );
        }
        let now = replacement
            .as_ref()
            .map(|(t, _)| t.model.clone())
            .unwrap_or_else(|| "default".into());
        let note = copy::unavailable(&record.model, &now, &catalog);
        let target = replacement.and_then(|(t, source)| source.is_chosen().then_some(t));
        (target, Some(note))
    }

    /// Take what a session's replacement must inherit: messages still queued
    /// and a switch still waiting for its turn to end.
    pub(super) fn take_carry(&self, tag: &str) -> Carry {
        match self.sessions.get(tag) {
            Some(s) => {
                // Same locks, in the same order, as `step`. A message `step`
                // took off the queue and is still writing is neither queued
                // nor yet written: wait (state released) for its outcome, so
                // it is either delivered to the old process or back on the
                // queue for the carry, never neither. The caller has killed
                // or lost the process, so the write ends at once; the limit
                // only keeps a freak from wedging the manager.
                let deadline = std::time::Instant::now() + WRITE_WAIT_LIMIT;
                loop {
                    let state = lock_recover(&s.shared.state);
                    if s.shared.writing.load(Ordering::SeqCst)
                        && std::time::Instant::now() < deadline
                    {
                        drop(state);
                        std::thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    let waiting = lock_recover(&s.shared.model).waiting.take();
                    let messages = lock_recover(&s.shared.pending).drain(..).collect();
                    // A message held for a sign-in stays held, and the session
                    // stays paused, across the restart.
                    let login = s.shared.login.take_for_respawn();
                    break Carry {
                        messages,
                        waiting,
                        login,
                    };
                }
            }
            None => Carry::default(),
        }
    }

    /// Hand `carry` to `tag`'s (new) session and start on it.
    pub(super) fn resume_carry(&self, tag: &str, carry: Carry) {
        if carry.messages.is_empty() && carry.waiting.is_none() && carry.login.is_none() {
            return;
        }
        let Some(session) = self.sessions.get(tag) else {
            return;
        };
        // Before the queue is advanced, so `step` sees the pause.
        if let Some(hold) = carry.login {
            session.shared.login.restore(hold);
        }
        lock_recover(&session.shared.pending).extend(carry.messages);
        lock_recover(&session.shared.model).waiting = carry.waiting;
        if session.state() == SessionState::Idle {
            advance(&session.shared);
        }
    }
}

// ── model reports, notes, state ────────────────────────────────────────────────

/// Record a model the session reported. The first report of a focus with no
/// record becomes its record (focuses that predate model switching keep what
/// they run); a report that differs from the record gets one note per
/// distinct mismatch.
pub(super) fn on_model_report(shared: &Shared, model: &str) {
    let ctx = &shared.ctx;
    if ctx.restricted {
        return;
    }
    let catalog = ctx.hub.catalog();
    let alias = catalog
        .family_for_resolved(model)
        .map(|e| e.value.clone())
        .unwrap_or_else(|| model.to_owned());
    let (changed, needs_record, follow, mismatch) = {
        let mut rt = lock_recover(&shared.model);
        let changed = rt.reported.as_deref() != Some(model);
        rt.reported = Some(model.to_owned());
        let mut mismatch = None;
        let mut follow = false;
        if let Some(record) = &rt.recorded {
            match crate::model::runs_as(&record.model, model, &catalog) {
                // Nobody chose the recorded model: the agent's front matter
                // or the CLI default moved on, and the record moves with it.
                Some(false) if !record.source.is_chosen() => {
                    follow = true;
                    rt.noted_mismatch = None;
                }
                Some(false) => {
                    let key = (record.model.clone(), model.to_owned());
                    if rt.noted_mismatch.as_ref() != Some(&key) {
                        mismatch = Some(copy::mismatch(
                            &record.model,
                            model,
                            rt.fallback.as_deref(),
                            &catalog,
                        ));
                        rt.noted_mismatch = Some(key);
                    }
                }
                Some(true) => rt.noted_mismatch = None,
                None => {}
            }
        }
        (changed, rt.recorded.is_none(), follow, mismatch)
    };
    if follow {
        let written =
            model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |existing| {
                existing.map(|mut record| {
                    if !record.source.is_chosen() {
                        record.model = alias.clone();
                    }
                    record
                })
            });
        match written {
            Ok(record) => lock_recover(&shared.model).recorded = record,
            Err(e) => warn!(tag = %ctx.tag, "could not update the observed model: {e:#}"),
        }
    }
    if needs_record {
        let source = if policy::declared_model(&ctx.agent_name).is_some() {
            ModelSource::AgentDeclared
        } else {
            ModelSource::CliDefault
        };
        let written =
            model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |existing| {
                existing.or(Some(FocusModelRecord {
                    model: alias,
                    source,
                    ..FocusModelRecord::default()
                }))
            });
        match written {
            Ok(record) => lock_recover(&shared.model).recorded = record,
            Err(e) => warn!(tag = %ctx.tag, "could not record the session's model: {e:#}"),
        }
    }
    if let Some(text) = mismatch {
        emit_note(shared, NoteKind::ModelMismatch, text);
    }
    if changed || needs_record || follow {
        publish_model_state(shared);
    }
}

/// Add a note to the session's transcript (broadcast as a delta) and ledger.
pub(super) fn emit_note(shared: &Shared, kind: NoteKind, text: String) {
    let ts = chrono::Utc::now();
    let block = TurnBlock::Note {
        note_kind: kind,
        text: text.clone(),
        ts,
    };
    let (delta, after_prompt) = {
        let mut transcript = shared.transcript.lock().unwrap();
        let delta = transcript.add_note(block);
        (delta, transcript.prompt_count())
    };
    let ctx = &shared.ctx;
    append_ledger_note(
        &ctx.hub,
        &ctx.tag,
        &ctx.session_id,
        &LedgerNote {
            after_prompt,
            kind,
            text,
            ts,
        },
    );
    shared.broadcast(SessionEvent::Delta(delta));
}

/// Add a note to the ledger of a session that is not running, after the
/// prompts its stored transcript holds.
fn note_while_stopped(hub: &ModelHub, tag: &str, session_id: &str, kind: NoteKind, text: String) {
    let note = LedgerNote {
        after_prompt: prompt_count_of(session_id),
        kind,
        text,
        ts: chrono::Utc::now(),
    };
    append_ledger_note(hub, tag, session_id, &note);
}

fn append_ledger_note(hub: &ModelHub, tag: &str, session_id: &str, note: &LedgerNote) {
    if let Err(e) = notes::append(&hub.paths.notes_dir, session_id, note) {
        warn!(tag, "could not record a transcript note: {e:#}");
    }
}

/// Broadcast the session's current model state.
pub(super) fn publish_model_state(shared: &Shared) {
    let view = lock_recover(&shared.model).view();
    let ctx = &shared.ctx;
    let record = model_store::focus_record(&ctx.hub.paths.focus_models, &ctx.tag);
    let state = model_state_from(
        &ctx.hub,
        &ctx.tag,
        Some(view),
        !shared.exited.load(Ordering::SeqCst),
        record,
        model_activity::current_posture(),
    );
    ctx.hub.broadcast(ServerMsg::SessionModelState(state));
}

/// Build a focus's model state: the store record, plus what its session (if
/// any) reports and is doing.
fn model_state_from(
    hub: &ModelHub,
    tag: &str,
    view: Option<RuntimeView>,
    running: bool,
    record: Option<FocusModelRecord>,
    posture: Option<String>,
) -> SessionModelState {
    let catalog = hub.catalog();
    let (reported, effective_effort, pending, phase) = match view {
        Some(v) => (v.reported, v.effective_effort, v.pending, v.phase),
        None => (None, None, None, SwitchPhase::default()),
    };
    let reported = reported.map(|model| ReportedModel {
        family: catalog
            .family_for_resolved(&model)
            .map(|e| e.value.clone())
            .or_else(|| crate::model::cost::known_family_of(&model).map(str::to_owned)),
        model,
    });
    SessionModelState {
        tag: tag.to_owned(),
        effective_effort: effective_effort
            .or_else(|| record.as_ref().and_then(|r| r.effort.clone())),
        recorded: record.map(|r| RecordedModel {
            model: r.model,
            effort: r.effort,
            source: r.source,
        }),
        reported,
        pending: pending.map(|t| PendingModel {
            model: t.model,
            effort: t.effort,
        }),
        phase,
        running,
        warnings: vec![],
        last_request: hub.last_request(tag),
        posture,
    }
}

/// Append one `model_switch` activity line for `shared`'s focus.
fn log_switch(
    ctx: &SessionCtx,
    from: Option<&ModelTarget>,
    to: &ModelTarget,
    actor: &Actor,
    outcome: Outcome,
    reason: Option<String>,
    summary: String,
) {
    model_activity::append(
        &model_activity::activity_path(),
        &ModelActivity {
            agent: agent_label(&ctx.agent_name),
            kind: ModelActivityKind::ModelSwitch,
            summary,
            session_id: Some(ctx.session_id.clone()),
            agent_type: (!ctx.agent_name.is_empty()).then(|| ctx.agent_name.clone()),
            focus_tag: Some(ctx.tag.clone()),
            from: from.cloned(),
            to: Some(to.clone()),
            actor: actor.wire(),
            outcome,
            reason: actor.reason().or(reason),
            posture: model_activity::current_posture(),
        },
    );
}

/// The `agent` field of an activity line: the focus's agent, or `claude`.
fn agent_label(agent_name: &str) -> String {
    if agent_name.is_empty() {
        "claude".to_owned()
    } else {
        agent_name.to_owned()
    }
}

/// What a focus runs now: its record, else the family it reports.
fn current_target(
    record: Option<&FocusModelRecord>,
    reported: Option<&str>,
    catalog: &ModelCatalog,
) -> Option<ModelTarget> {
    record.map(FocusModelRecord::target).or_else(|| {
        reported.map(|r| ModelTarget {
            model: catalog
                .family_for_resolved(r)
                .map(|e| e.value.clone())
                .unwrap_or_else(|| r.to_owned()),
            effort: None,
        })
    })
}

/// `--model`/`--effort` for a spawn (nothing for `None`).
pub(super) fn model_args(target: Option<&ModelTarget>) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(target) = target {
        args.extend(["--model".to_owned(), target.model.clone()]);
        if let Some(effort) = &target.effort {
            args.extend(["--effort".to_owned(), effort.clone()]);
        }
    }
    args
}

/// May `model` be started or switched to?
///
/// - A fresh (not stale) catalogue is the CLI's own list: only a row it
///   lists, or the full name a row resolves to, is offered. A retired pinned
///   ID or a typo such as `claude-opus-9` is not, for a switch as for a start.
/// - A stale catalogue is what an earlier probe saw, which can't say a newer
///   name is wrong: a full `claude-…` name passes, an alias must be listed.
/// - With nothing in the catalogue (never probed, no cache) only the family
///   aliases Nostromo knows and full names pass: a typo'd name stored for the
///   next start would otherwise be passed to `--model` and the CLI would
///   reject it at every start.
fn is_offered(model: &str, catalog: &ModelCatalog) -> bool {
    if catalog.entry(model).is_some() {
        return true;
    }
    if catalog.is_empty() {
        return model.starts_with("claude-") || crate::model::cost::is_known_alias(model);
    }
    if catalog.stale {
        return model.starts_with("claude-");
    }
    catalog
        .families
        .iter()
        .chain(&catalog.pinned)
        .any(|e| e.resolved_model.as_deref() == Some(model))
}

/// The names a catalogue offers, for an error message.
fn offered_names(catalog: &ModelCatalog) -> String {
    catalog
        .families
        .iter()
        .chain(&catalog.pinned)
        .map(|e| e.value.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Check `target` against the catalogue: `Err((code, message))` when the
/// model is not offered or the effort is not supported by it.
fn validate_target(
    target: &ModelTarget,
    catalog: &ModelCatalog,
) -> std::result::Result<(), (&'static str, String)> {
    let entry = catalog.entry(&target.model);
    if !is_offered(&target.model, catalog) {
        let names = offered_names(catalog);
        let choices = if names.is_empty() {
            String::new()
        } else {
            format!("; choose one of {names}")
        };
        return Err((
            "unknown_model",
            format!(
                "{} is not offered by the installed CLI{choices}",
                target.model
            ),
        ));
    }
    if let (Some(entry), Some(effort)) = (entry, &target.effort) {
        if !entry.supports_effort_level(effort) {
            return Err((
                "unsupported_effort",
                format!("{} does not support effort {effort}", target.model),
            ));
        }
    }
    if let Some(effort) = &target.effort {
        if !crate::model::cost::EFFORT_LEVELS.contains(&effort.as_str()) {
            return Err((
                "unsupported_effort",
                format!("unknown effort level {effort}"),
            ));
        }
    }
    Ok(())
}

// ── switching ─────────────────────────────────────────────────────────────────

/// Start a switch of a running session (the caller has checked it is alive
/// and that the target is valid).
fn begin_switch(
    shared: &Shared,
    current: Option<ModelTarget>,
    target: ModelTarget,
    actor: Actor,
) -> SwitchTicket {
    let ctx = &shared.ctx;
    let catalog = ctx.hub.catalog();
    let from = current.clone().unwrap_or_else(default_target);
    enum Plan {
        Unchanged,
        Cancelled,
        Apply(
            oneshot::Receiver<ModelRequestOutcome>,
            oneshot::Sender<ModelRequestOutcome>,
        ),
        Wait {
            /// The target differs from the one already waiting.
            new: bool,
            /// A turn is running (as opposed to another switch being applied).
            turn_running: bool,
        },
    }
    // The decision is made under `state` + `model`, with no IO under them. The
    // pending record and note are written after, under `model_io` alone: a
    // turn ending meanwhile starts an apply whose first step takes `model_io`
    // too, so it can't clear the pending record or note the change before
    // they are written.
    let io = lock_recover(&shared.model_io);
    let plan = {
        let state = lock_recover(&shared.state);
        let mut rt = lock_recover(&shared.model);
        let same_as_current = current.as_ref() == Some(&target);
        let idle = *state == SessionState::Idle && rt.applying.is_none();
        if same_as_current && rt.applying.is_none() {
            if rt.waiting.take().is_some() {
                Plan::Cancelled
            } else {
                Plan::Unchanged
            }
        } else if idle {
            rt.applying = Some(target.clone());
            let (tx, rx) = oneshot::channel();
            Plan::Apply(rx, tx)
        } else {
            let new = rt.waiting.as_ref().map(|(t, _)| t) != Some(&target);
            rt.waiting = Some((target.clone(), actor.clone()));
            Plan::Wait {
                new,
                turn_running: *state != SessionState::Idle,
            }
        }
    };
    match plan {
        Plan::Unchanged => {
            SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged))
        }
        Plan::Cancelled => {
            persist_pending(ctx, None);
            publish_model_state(shared);
            SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged))
        }
        Plan::Apply(rx, tx) => {
            drop(io);
            spawn_apply(shared, target, actor, Some(tx));
            SwitchTicket(TicketInner::Later(rx))
        }
        Plan::Wait { new, turn_running } => {
            if new {
                persist_pending(ctx, Some(target.clone()));
                // "After this turn" is only true while a turn is running; behind
                // another switch being applied the next note is that switch's.
                if turn_running {
                    emit_note(
                        shared,
                        NoteKind::ModelPending,
                        copy::pending(&from, &target, &catalog),
                    );
                }
            }
            ctx.hub.record_request(
                &ctx.tag,
                &actor,
                &target,
                ModelRequestStatus::PendingTurnEnd,
            );
            publish_model_state(shared);
            SwitchTicket::ready(ModelRequestOutcome::status(
                ModelRequestStatus::PendingTurnEnd,
            ))
        }
    }
}

/// How many user prompts a (stopped) session's stored JSONL holds: where a
/// note made while it is not running belongs.
fn prompt_count_of(session_id: &str) -> u64 {
    load_scrollback(session_id, 1).prompt_count()
}

/// The "nothing recorded, nothing reported" model.
fn default_target() -> ModelTarget {
    ModelTarget {
        model: "default".to_owned(),
        effort: None,
    }
}

/// Persist (or clear) the switch waiting on `ctx`'s focus.
fn persist_pending(ctx: &SessionCtx, pending: Option<ModelTarget>) {
    let result =
        model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |record| {
            record.map(|mut r| {
                r.pending = pending;
                r
            })
        });
    if let Err(e) = result {
        warn!(tag = %ctx.tag, "could not persist the pending model switch: {e:#}");
    }
}

/// The switch to `target` starts being applied: its persisted `pending`
/// record (if any) is done with. Only that one: a different target waiting
/// since is not ours to clear. Takes `model_io` so a `begin_switch` still
/// writing that record has finished first.
fn clear_pending_for(ctx: &SessionCtx, shared: &Shared, target: &ModelTarget) {
    let _io = lock_recover(&shared.model_io);
    let result =
        model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |record| {
            record.map(|mut r| {
                if r.pending.as_ref() == Some(target) {
                    r.pending = None;
                }
                r
            })
        });
    if let Err(e) = result {
        warn!(tag = %ctx.tag, "could not clear the pending model switch: {e:#}");
    }
}

/// Run [`apply_switch`] on the session's runtime. `rt.applying` is already set.
pub(super) fn spawn_apply(
    shared: &Shared,
    target: ModelTarget,
    actor: Actor,
    reply: Option<oneshot::Sender<ModelRequestOutcome>>,
) {
    let task_shared = shared.clone();
    spawn_apply_task(shared, reply, async move {
        apply_switch(&task_shared, target, actor).await
    });
}

/// Run `task` (the switch) as its own task and, however it ends, answer
/// `reply` and leave `Applying` ([`finish_apply`]). A panic inside the switch
/// would otherwise leave `applying` set for good: every message would queue
/// and crash recovery would never fire.
pub(super) fn spawn_apply_task(
    shared: &Shared,
    reply: Option<oneshot::Sender<ModelRequestOutcome>>,
    task: impl std::future::Future<Output = ModelRequestOutcome> + Send + 'static,
) {
    let task_shared = shared.clone();
    let switch = shared.runtime.spawn(task);
    shared.runtime.spawn(async move {
        let outcome = match switch.await {
            Ok(outcome) => outcome,
            Err(e) => {
                warn!(tag = %task_shared.ctx.tag, "the model switch task failed: {e}");
                ModelRequestOutcome::failed("the model switch failed unexpectedly")
            }
        };
        if let Some(reply) = reply {
            let _ = reply.send(outcome);
        }
        finish_apply(&task_shared);
    });
    publish_model_state(shared);
}

/// What `get_settings` confirmed.
struct Applied {
    model: Option<String>,
    effort: Option<String>,
}

/// Apply a switch to an idle session: control requests, then the store, a
/// note, an activity line. On any failure the session is put back (best
/// effort) and nothing is recorded but the failure.
async fn apply_switch(shared: &Shared, target: ModelTarget, actor: Actor) -> ModelRequestOutcome {
    let ctx = &shared.ctx;
    let catalog = ctx.hub.catalog();
    clear_pending_for(ctx, shared, &target);
    let record = model_store::focus_record(&ctx.hub.paths.focus_models, &ctx.tag);
    let reported = lock_recover(&shared.model).reported.clone();
    let current = current_target(record.as_ref(), reported.as_deref(), &catalog);
    if current.as_ref() == Some(&target) {
        return ModelRequestOutcome::status(ModelRequestStatus::Unchanged);
    }
    let from = current.clone().unwrap_or_else(default_target);

    match run_switch_requests(shared, current.as_ref(), &target, &catalog).await {
        Ok(applied) => {
            let source = ModelSource::Focus;
            let written =
                model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |_| {
                    Some(FocusModelRecord {
                        model: target.model.clone(),
                        effort: target.effort.clone(),
                        source,
                        ..FocusModelRecord::default()
                    })
                });
            {
                let mut rt = lock_recover(&shared.model);
                match written {
                    Ok(record) => rt.recorded = record,
                    Err(e) => warn!(tag = %ctx.tag, "could not record the new model: {e:#}"),
                }
                if applied.model.is_some() {
                    rt.reported = applied.model;
                }
                rt.effective_effort = applied.effort;
                rt.noted_mismatch = None;
                rt.fallback = None;
            }
            let text = copy::changed(&from, &target, &actor, &catalog);
            emit_note(shared, NoteKind::ModelChanged, text.clone());
            log_switch(
                ctx,
                current.as_ref(),
                &target,
                &actor,
                Outcome::Applied,
                None,
                text,
            );
            ctx.hub
                .record_request(&ctx.tag, &actor, &target, ModelRequestStatus::Applied);
            ModelRequestOutcome::status(ModelRequestStatus::Applied)
        }
        Err(reason) => {
            let text = copy::failed(&from, &target, &reason, &catalog);
            emit_note(shared, NoteKind::ModelFailed, text.clone());
            log_switch(
                ctx,
                current.as_ref(),
                &target,
                &actor,
                Outcome::Failed,
                Some(reason.clone()),
                text,
            );
            ctx.hub
                .record_request(&ctx.tag, &actor, &target, ModelRequestStatus::Failed);
            ModelRequestOutcome::failed(reason)
        }
    }
}

/// `set_model` (if the model changes), `apply_flag_settings` (if the effort
/// changes), then `get_settings` to verify. On failure, undo what was sent
/// (without waiting for the answers) and return the reason.
async fn run_switch_requests(
    shared: &Shared,
    current: Option<&ModelTarget>,
    target: &ModelTarget,
    catalog: &ModelCatalog,
) -> std::result::Result<Applied, String> {
    let model_changes = current.map(|c| c.model != target.model).unwrap_or(true);
    let effort_changes = current
        .map(|c| c.effort != target.effort)
        .unwrap_or(target.effort.is_some());
    // Whether a change may have taken effect: it succeeded, or it got no
    // answer. A change the CLI refused needs no undoing.
    let mut model_sent = false;
    let mut effort_sent = false;
    let maybe_applied = |r: &std::result::Result<ControlReply, ControlFailure>| match r {
        Ok(_) => true,
        Err(f) => !f.refused,
    };

    let result = async {
        if model_changes {
            let r = control(shared, serde_json::json!({ "subtype": "set_model", "model": target.model })).await;
            model_sent = maybe_applied(&r);
            r?;
        }
        if effort_changes {
            let r = control(
                shared,
                serde_json::json!({ "subtype": "apply_flag_settings", "settings": { "effortLevel": target.effort } }),
            )
            .await;
            effort_sent = maybe_applied(&r);
            r?;
        }
        let reply = control(shared, serde_json::json!({ "subtype": "get_settings" })).await?;
        let applied = find_key(&reply.body, "applied").cloned().unwrap_or_default();
        let applied_model = applied.get("model").and_then(|m| m.as_str()).map(str::to_owned);
        let applied_effort = applied.get("effort").and_then(|e| e.as_str()).map(str::to_owned);
        let switched = match &applied_model {
            Some(applied) => crate::model::runs_as(&target.model, applied, catalog),
            None => catalog.resolved(&target.model).map(|_| false),
        };
        if switched == Some(false) {
            return Err(format!(
                "the session reports {}",
                applied_model.as_deref().unwrap_or("no model")
            ));
        }
        if let Some(effort) = &target.effort {
            if applied_effort.as_deref() != Some(effort.as_str()) {
                return Err(format!(
                    "the session reports effort {}",
                    applied_effort.as_deref().unwrap_or("default")
                ));
            }
        }
        Ok(Applied { model: applied_model, effort: applied_effort })
    }
    .await;

    if result.is_err() && !shared.exited.load(Ordering::SeqCst) {
        if let Some(current) = current {
            if effort_sent {
                let _ = send_control(
                    shared,
                    serde_json::json!({ "subtype": "apply_flag_settings", "settings": { "effortLevel": current.effort } }),
                );
            }
            if model_sent && current.model != "default" {
                let _ = send_control(
                    shared,
                    serde_json::json!({ "subtype": "set_model", "model": current.model }),
                );
            }
        }
    }
    result
}

/// Write a control request without waiting for its answer.
fn send_control(shared: &Shared, request: serde_json::Value) -> Result<()> {
    let id = format!("model-{}", Uuid::new_v4());
    write_control_request(&shared.stdin, &id, request)
}

/// A switch of a focus whose session is not running, ready to be recorded.
pub(super) struct StoredSwitch {
    ctx: SessionCtx,
    current: Option<ModelTarget>,
    target: ModelTarget,
    actor: Actor,
    /// The (dead) session the focus still has an entry for, if any.
    session: Option<Shared>,
    /// See [`ModelHub::note_stored`].
    seq: u64,
}

impl StoredSwitch {
    /// Write the record, then note it (in the dead session's transcript, or
    /// in the ledger after the prompts its stored conversation holds), log it
    /// and tell the clients.
    fn run(self) -> ModelRequestOutcome {
        // Retires the "not yet written" entry however `record` ends, even by a panic.
        let _guard = self.ctx.hub.guard_stored(
            &self.ctx.tag,
            self.seq,
            self.actor.clone(),
            self.target.clone(),
        );
        self.record()
    }

    fn record(self) -> ModelRequestOutcome {
        let Self {
            ctx,
            current,
            target,
            actor,
            session,
            ..
        } = self;
        let hub = Arc::clone(&ctx.hub);
        let tag = ctx.tag.as_str();
        let written = model_store::update_focus_record(&hub.paths.focus_models, tag, |_| {
            Some(FocusModelRecord {
                model: target.model.clone(),
                effort: target.effort.clone(),
                source: ModelSource::Focus,
                ..FocusModelRecord::default()
            })
        });
        let record = match written {
            Ok(record) => record,
            Err(e) => {
                warn!(tag, "could not record the focus's model: {e:#}");
                return ModelRequestOutcome::failed(format!("could not record the model: {e}"));
            }
        };
        let catalog = hub.catalog();
        let text = copy::stored(current.as_ref(), &target, &catalog);
        let mut view = None;
        if let Some(shared) = &session {
            {
                let mut rt = lock_recover(&shared.model);
                rt.recorded = record.clone();
                view = Some(rt.view());
            }
            emit_note(shared, NoteKind::ModelChanged, text.clone());
        }
        log_switch(
            &ctx,
            current.as_ref(),
            &target,
            &actor,
            Outcome::Applied,
            None,
            text.clone(),
        );
        hub.record_request(tag, &actor, &target, ModelRequestStatus::Applied);
        hub.broadcast(ServerMsg::SessionModelState(model_state_from(
            &hub,
            tag,
            view,
            false,
            record,
            model_activity::current_posture(),
        )));
        // A stopped session's note belongs after the prompts its stored JSONL
        // holds, which means parsing that file.
        if session.is_none() && !ctx.session_id.is_empty() {
            note_while_stopped(
                &hub,
                tag,
                &ctx.session_id,
                NoteKind::ModelChanged,
                text.clone(),
            );
        }
        ModelRequestOutcome {
            status: ModelRequestStatus::Applied,
            code: None,
            message: Some(text),
            warning: None,
        }
    }
}

/// Queued work a session's replacement inherits (see
/// [`SessionManager::restart`]): nothing a crash or restart interrupts is lost.
#[derive(Default)]
pub(super) struct Carry {
    pub(super) messages: Vec<PendingMessage>,
    pub(super) waiting: Option<(ModelTarget, Actor)>,
    /// A message held for a Claude sign-in (see `login.rs`).
    pub(super) login: Option<super::login::Hold>,
}
