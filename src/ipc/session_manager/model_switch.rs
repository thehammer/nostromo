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

use super::{
    advance, finish_apply, load_id_store, write_control_request, PendingMessage, SessionEvent,
    SessionManager, Shared,
};
use crate::ipc::protocol::{
    EffortChoice, ModelRequestStatus, PendingModel, RecordedModel, ReportedModel, ServerMsg,
    SessionModelState, SwitchPhase,
};
use crate::ipc::stream_json::{load_scrollback, SessionState, TurnBlock};
use crate::model::activity::{self as model_activity, ModelActivity, ModelActivityKind, Outcome};
use crate::model::catalog::{find_key, ModelCatalog};
use crate::model::hub::ModelHub;
use crate::model::notes::{self, LedgerNote, NoteKind};
use crate::model::store::{self as model_store, FocusModelRecord, ModelSource};
use crate::model::{copy, policy, Actor, ModelTarget};

/// Identity of one session, fixed for its life.
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

impl ModelRuntime {
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

/// A `control_response`, as handed to the task that sent the request.
#[derive(Debug, Clone)]
pub(super) struct ControlReply {
    pub(super) ok: bool,
    pub(super) error: Option<String>,
    pub(super) error_code: Option<String>,
    pub(super) body: serde_json::Value,
}

/// How long the daemon waits for the answer to one control request.
pub const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);

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
        match self.sessions.get(tag) {
            Some(session) => {
                let rt = session.shared.model.lock().unwrap();
                model_state(&self.model_hub, tag, Some(&rt), session.alive())
            }
            None => model_state(&self.model_hub, tag, None, false),
        }
    }

    /// Every tag that has a model state worth replaying to a client: live
    /// sessions, registered focuses and recorded focuses.
    pub fn model_state_tags(&self) -> Vec<String> {
        let mut tags = self.known_focus_tags();
        for tag in model_store::load_focus_models(&self.model_hub.paths.focus_models).into_keys() {
            if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
        tags.retain(|t| !self.restrictions.contains_key(t));
        tags
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
        let reported = session.and_then(|s| s.shared.model.lock().unwrap().reported.clone());
        let current = current_target(record.as_ref(), reported.as_deref(), &catalog);
        let session_id = session
            .and_then(|s| s.session_id.clone())
            .or_else(|| load_id_store(&self.store_path).get(tag).cloned());

        let ctx = SessionCtx::stopped(tag, agent.as_deref(), session_id.as_deref(), &hub);
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
    /// next start.
    pub(super) fn switch_not_running(
        &mut self,
        ctx: &SessionCtx,
        current: Option<ModelTarget>,
        target: ModelTarget,
        actor: Actor,
    ) -> SwitchTicket {
        let hub = Arc::clone(&self.model_hub);
        let tag = ctx.tag.as_str();
        if current.as_ref() == Some(&target) {
            return SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged));
        }
        let written = model_store::update_focus_record(&hub.paths.focus_models, tag, |_| {
            Some(FocusModelRecord {
                model: target.model.clone(),
                effort: target.effort.clone(),
                source: ModelSource::Focus,
                pending: None,
            })
        });
        if let Err(e) = written {
            warn!(tag, "could not record the focus's model: {e:#}");
            return SwitchTicket::ready(ModelRequestOutcome::failed(format!(
                "could not record the model: {e}"
            )));
        }
        let catalog = hub.catalog();
        let text = copy::stored(current.as_ref(), &target, &catalog);
        if let Some(session) = self.sessions.get(tag) {
            {
                // This choice supersedes a switch the dead process still had
                // waiting, which a crash recovery would otherwise apply.
                let mut rt = session.shared.model.lock().unwrap();
                rt.recorded = model_store::focus_record(&hub.paths.focus_models, tag);
                rt.waiting = None;
            }
            emit_note(&session.shared, NoteKind::ModelChanged, text.clone());
        } else if !ctx.session_id.is_empty() {
            note_while_stopped(
                &hub,
                tag,
                &ctx.session_id,
                NoteKind::ModelChanged,
                text.clone(),
            );
        }
        log_switch(
            ctx,
            current.as_ref(),
            &target,
            &actor,
            Outcome::Applied,
            None,
            text.clone(),
        );
        hub.record_request(tag, &actor, &target, ModelRequestStatus::Applied);
        hub.broadcast(ServerMsg::SessionModelState(self.session_model_state(tag)));
        SwitchTicket::ready(ModelRequestOutcome {
            status: ModelRequestStatus::Applied,
            code: None,
            message: Some(text),
            warning: None,
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

    /// The model a spawn of `tag` runs on, and the note to make about it.
    /// A recorded model the (fresh) catalogue no longer offers is replaced by
    /// the agent's default: per-agent default, else its declared model, else
    /// the CLI default (no record at all).
    pub(super) fn spawn_model(
        &self,
        tag: &str,
        agent: &str,
    ) -> (Option<ModelTarget>, Option<String>) {
        let hub = &self.model_hub;
        let Some(record) = model_store::focus_record(&hub.paths.focus_models, tag) else {
            return (None, None);
        };
        let catalog = hub.catalog();
        let offered = catalog.is_empty()
            || catalog.stale
            || record.model.starts_with("claude-")
            || catalog.entry(&record.model).is_some();
        if offered {
            return (Some(record.target()), None);
        }
        let replacement = model_store::load_defaults(&hub.paths.defaults)
            .remove(agent)
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
        let written = model_store::update_focus_record(&hub.paths.focus_models, tag, |_| {
            replacement
                .as_ref()
                .map(|(target, source)| FocusModelRecord {
                    model: target.model.clone(),
                    effort: target.effort.clone(),
                    source: *source,
                    pending: None,
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
        (replacement.map(|(t, _)| t), Some(note))
    }

    /// Take what a session's replacement must inherit: messages still queued
    /// and a switch still waiting for its turn to end.
    pub(super) fn take_carry(&self, tag: &str) -> Carry {
        match self.sessions.get(tag) {
            Some(s) => {
                // Same locks, in the same order, as `step`: a message is
                // either written by the old process or carried, never neither.
                let _state = s.shared.state.lock().unwrap();
                let waiting = s.shared.model.lock().unwrap().waiting.take();
                let messages = s.shared.pending.lock().unwrap().drain(..).collect();
                Carry { messages, waiting }
            }
            None => Carry::default(),
        }
    }

    /// Hand `carry` to `tag`'s (new) session and start on it.
    pub(super) fn resume_carry(&self, tag: &str, carry: Carry) {
        if carry.messages.is_empty() && carry.waiting.is_none() {
            return;
        }
        let Some(session) = self.sessions.get(tag) else {
            return;
        };
        session
            .shared
            .pending
            .lock()
            .unwrap()
            .extend(carry.messages);
        session.shared.model.lock().unwrap().waiting = carry.waiting;
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
    let (changed, needs_record, mismatch) = {
        let mut rt = shared.model.lock().unwrap();
        let changed = rt.reported.as_deref() != Some(model);
        rt.reported = Some(model.to_owned());
        let mut mismatch = None;
        if let Some(record) = &rt.recorded {
            match crate::model::runs_as(&record.model, model, &catalog) {
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
        (changed, rt.recorded.is_none(), mismatch)
    };
    if needs_record {
        let alias = catalog
            .family_for_resolved(model)
            .map(|e| e.value.clone())
            .unwrap_or_else(|| model.to_owned());
        let source = if policy::declared_model(&ctx.agent_name).is_some() {
            ModelSource::AgentDeclared
        } else {
            ModelSource::CliDefault
        };
        let written =
            model_store::update_focus_record(&ctx.hub.paths.focus_models, &ctx.tag, |existing| {
                existing.or(Some(FocusModelRecord {
                    model: alias,
                    effort: None,
                    source,
                    pending: None,
                }))
            });
        match written {
            Ok(record) => shared.model.lock().unwrap().recorded = record,
            Err(e) => warn!(tag = %ctx.tag, "could not record the session's model: {e:#}"),
        }
    }
    if let Some(text) = mismatch {
        emit_note(shared, NoteKind::ModelMismatch, text);
    }
    if changed || needs_record {
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
    let state = {
        let rt = shared.model.lock().unwrap();
        model_state(
            &shared.ctx.hub,
            &shared.ctx.tag,
            Some(&rt),
            !shared.exited.load(Ordering::SeqCst),
        )
    };
    shared
        .ctx
        .hub
        .broadcast(ServerMsg::SessionModelState(state));
}

/// Build a focus's model state: the store record, plus what its session (if
/// any) reports and is doing.
pub(super) fn model_state(
    hub: &ModelHub,
    tag: &str,
    rt: Option<&ModelRuntime>,
    running: bool,
) -> SessionModelState {
    let record = model_store::focus_record(&hub.paths.focus_models, tag);
    let catalog = hub.catalog();
    let reported = rt
        .and_then(|rt| rt.reported.clone())
        .map(|model| ReportedModel {
            family: catalog
                .family_for_resolved(&model)
                .map(|e| e.value.clone())
                .or_else(|| crate::model::cost::known_family_of(&model).map(str::to_owned)),
            model,
        });
    let pending = rt
        .and_then(|rt| {
            rt.applying
                .clone()
                .or_else(|| rt.waiting.as_ref().map(|(t, _)| t.clone()))
        })
        .map(|t| PendingModel {
            model: t.model,
            effort: t.effort,
        });
    SessionModelState {
        tag: tag.to_owned(),
        effective_effort: rt
            .and_then(|rt| rt.effective_effort.clone())
            .or_else(|| record.as_ref().and_then(|r| r.effort.clone())),
        recorded: record.map(|r| RecordedModel {
            model: r.model,
            effort: r.effort,
            source: r.source,
        }),
        reported,
        pending,
        phase: rt.map(ModelRuntime::phase).unwrap_or_default(),
        running,
        warnings: vec![],
        last_request: hub.last_request(tag),
        posture: model_activity::current_posture(),
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

/// Check `target` against the catalogue: `Err((code, message))` when the
/// model is not offered or the effort is not supported by it. A full
/// `claude-…` name the catalogue does not list is left to the CLI.
fn validate_target(
    target: &ModelTarget,
    catalog: &ModelCatalog,
) -> std::result::Result<(), (&'static str, String)> {
    let entry = catalog.entry(&target.model);
    if entry.is_none() && !catalog.is_empty() && !target.model.starts_with("claude-") {
        return Err((
            "unknown_model",
            format!(
                "{} is not offered by the installed Claude CLI",
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
        Wait,
    }
    // The pending record and note are written inside the critical section: a
    // turn ending now would otherwise start applying (and clear the persisted
    // pending, and note the change) before they were written.
    let plan = {
        let state = shared.state.lock().unwrap();
        let mut rt = shared.model.lock().unwrap();
        let same_as_current = current.as_ref() == Some(&target);
        let idle = *state == SessionState::Idle && rt.applying.is_none();
        if same_as_current && rt.applying.is_none() {
            if rt.waiting.take().is_some() {
                persist_pending(ctx, None);
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
            if new {
                persist_pending(ctx, Some(target.clone()));
                emit_note(
                    shared,
                    NoteKind::ModelPending,
                    copy::pending(&from, &target, &catalog),
                );
            }
            Plan::Wait
        }
    };
    match plan {
        Plan::Unchanged => {
            SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged))
        }
        Plan::Cancelled => {
            publish_model_state(shared);
            SwitchTicket::ready(ModelRequestOutcome::status(ModelRequestStatus::Unchanged))
        }
        Plan::Apply(rx, tx) => {
            spawn_apply(shared, target, actor, Some(tx));
            SwitchTicket(TicketInner::Later(rx))
        }
        Plan::Wait => {
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

/// Run [`apply_switch`] on the session's runtime. `rt.applying` is already set.
pub(super) fn spawn_apply(
    shared: &Shared,
    target: ModelTarget,
    actor: Actor,
    reply: Option<oneshot::Sender<ModelRequestOutcome>>,
) {
    let task_shared = shared.clone();
    shared.runtime.spawn(async move {
        let outcome = apply_switch(&task_shared, target, actor).await;
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
    persist_pending(ctx, None);
    let record = model_store::focus_record(&ctx.hub.paths.focus_models, &ctx.tag);
    let reported = shared.model.lock().unwrap().reported.clone();
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
                        pending: None,
                    })
                });
            {
                let mut rt = shared.model.lock().unwrap();
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

/// Why a control request failed: the reason shown to the user, and whether
/// the CLI answered with a refusal (so nothing took effect).
struct ControlFailure {
    reason: String,
    refused: bool,
}

impl From<ControlFailure> for String {
    fn from(f: ControlFailure) -> String {
        f.reason
    }
}

/// Send a control request and wait (≤ [`CONTROL_TIMEOUT`]) for its answer.
async fn control(
    shared: &Shared,
    request: serde_json::Value,
) -> std::result::Result<ControlReply, ControlFailure> {
    let failure = |reason: String, refused: bool| ControlFailure { reason, refused };
    const EXITED: &str = "the session exited";
    let id = format!("model-{}", Uuid::new_v4());
    let (tx, rx) = oneshot::channel();
    shared.waiters.lock().unwrap().insert(id.clone(), tx);
    // Checked after registering: the reader sets `exited` before it drops
    // every waiter, so one of the two always notices an exit.
    if shared.exited.load(Ordering::SeqCst)
        || write_control_request(&shared.stdin, &id, request).is_err()
    {
        shared.waiters.lock().unwrap().remove(&id);
        return Err(failure(EXITED.to_owned(), false));
    }
    match tokio::time::timeout(CONTROL_TIMEOUT, rx).await {
        Ok(Ok(reply)) if reply.ok => Ok(reply),
        Ok(Ok(reply)) => Err(failure(
            reply
                .error
                .or(reply.error_code)
                .unwrap_or_else(|| "the session refused the change".to_owned()),
            true,
        )),
        Ok(Err(_)) => Err(failure(EXITED.to_owned(), false)),
        Err(_) => {
            shared.waiters.lock().unwrap().remove(&id);
            Err(failure(
                format!(
                    "the session did not answer within {} s",
                    CONTROL_TIMEOUT.as_secs()
                ),
                false,
            ))
        }
    }
}

/// Queued work a session's replacement inherits (see
/// [`SessionManager::restart`]): nothing a crash or restart interrupts is lost.
#[derive(Default)]
pub(super) struct Carry {
    pub(super) messages: Vec<PendingMessage>,
    pub(super) waiting: Option<(ModelTarget, Actor)>,
}
