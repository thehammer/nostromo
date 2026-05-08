//! Top-level application: view registry, global event loop, tick scheduling.
//!
//! Phase 3 additions:
//! - `AppState` holding modal state, right-panel visibility, and break-glass.
//! - Mother-specific pollers (statusline watcher + job-list poller).
//! - Break-glass sentinel watcher.
//! - Right-panel data source (AgentBus subscriber).
//! - `Ctrl-R` to toggle the right panel.
//! - `Ctrl-B` to open the break-glass modal (when sentinel present).
//! - Modal routing: modals receive key events first and short-circuit dispatch.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::{
    ViewArg,
    agent_bus::AgentBus,
    config::Config,
    data::{
        break_glass::{self, BreakGlassRequest},
        fred_calendar::FredCalendarSource,
        fred_mailbox::FredMailboxSource,
        mother_poll,
        perri_pr::PerriPrSource,
        perri_queue::PerriQueueSource,
        right_panel_source::{self, RightPanelSnapshot},
    },
    event::{self, AppEvent},
    mother,
    ui,
    ui::widgets::syntect_cache::SyntectCache,
    views::{
        self, BoxedView, ViewCtx,
        await_modal::{AwaitAction, AwaitModal},
        break_glass_modal::{BreakGlassAction, BreakGlassModal, ConfirmAction, ConfirmModal},
        mother::MotherAction,
    },
};

// ── modal state ───────────────────────────────────────────────────────────────

/// The single active modal (at most one at a time).
///
/// Large variants are boxed to keep enum size uniform.
pub enum ModalState {
    Await(Box<AwaitModal>),
    BreakGlass(Box<BreakGlassModal>),
    /// Confirm a `mother cancel <id>` operation.
    ConfirmCancel { job_id: String, modal: ConfirmModal },
    /// Confirm a `mother add --plan <path>` retry operation.
    ConfirmRetry {
        job_id: String,
        plan_path: String,
        modal: ConfirmModal,
    },
}

// ── app state ─────────────────────────────────────────────────────────────────

/// Shared application state passed into the render and event layers.
pub struct AppState {
    /// Whether the 25%-wide right context panel is visible.
    pub right_panel_visible: bool,
    /// The most recent break-glass sentinel (if present).
    pub break_glass: Option<BreakGlassRequest>,
    /// Per-agent right-panel snapshots keyed by agent id.
    pub right_panel_data: HashMap<String, RightPanelSnapshot>,
    /// Currently active modal overlay.
    pub modal: Option<ModalState>,
    /// Status bar note shown when retry is not possible.
    pub status_note: Option<String>,
}

impl AppState {
    fn new() -> Self {
        Self {
            right_panel_visible: false,
            break_glass: None,
            right_panel_data: HashMap::new(),
            modal: None,
            status_note: None,
        }
    }

    fn modal_active(&self) -> bool {
        self.modal.is_some()
    }
}

// ── run ───────────────────────────────────────────────────────────────────────

/// Run the application until the user quits.
#[tokio::main]
pub async fn run(
    initial_view: ViewArg,
    config: Config,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    syntect: Arc<SyntectCache>,
    bus: Arc<AgentBus>,
) -> Result<()> {
    let mailbox_rx = FredMailboxSource::spawn(config.clone());
    let calendar_rx = FredCalendarSource::spawn(config.clone());
    let queue_rx = PerriQueueSource::spawn(config.clone());
    let pr_rx = PerriPrSource::spawn(config.clone());

    // Create the event channel before views so they can send AgentUpdate.
    let (tx, mut rx) = mpsc::unbounded_channel::<AppEvent>();
    event::spawn(tx.clone());

    // Spawn Mother pollers (statusline watcher + job-list poll every 2s).
    mother_poll::spawn(tx.clone());

    // Spawn break-glass sentinel watcher.
    break_glass::spawn(tx.clone());

    // Spawn right-panel data source (subscribes to AgentBus).
    right_panel_source::spawn(Arc::clone(&bus), tx.clone());

    let fred_ctx = ViewCtx { event_tx: tx.clone() };
    let perri_ctx = ViewCtx { event_tx: tx.clone() };
    let mother_ctx = ViewCtx { event_tx: tx.clone() };

    let mut views: Vec<BoxedView> = vec![
        Box::new(views::fred::FredView::new(mailbox_rx, calendar_rx, config.clone(), fred_ctx)),
        Box::new(views::perri::PerriView::new(queue_rx, pr_rx, config.clone(), perri_ctx, Arc::clone(&syntect))),
        Box::new(views::agent_generic::GenericView::new("claudia", "Claudia", ViewCtx { event_tx: tx.clone() })),
        Box::new(views::agent_generic::GenericView::new("cody",    "Cody",    ViewCtx { event_tx: tx.clone() })),
        Box::new(views::agent_generic::GenericView::new("kennedy", "Kennedy", ViewCtx { event_tx: tx.clone() })),
        Box::new(views::mother::MotherView::new(config.clone(), mother_ctx)),
    ];

    // Index of the Mother view within `views`.
    const MOTHER_IDX: usize = 5;
    // Index of the Perri view within `views`.
    const PERRI_IDX: usize = 1;

    let mut active: usize = match initial_view {
        ViewArg::Fred => 0,
        ViewArg::Perri => 1,
        ViewArg::All => 0,
    };

    let mut state = AppState::new();

    info!("event loop starting");

    loop {
        // Collect titles before the mutable borrow of views[active].
        let titles: Vec<String> = views.iter().map(|v| v.title().to_string()).collect();
        let title_refs: Vec<&str> = titles.iter().map(|s| s.as_str()).collect();

        // Snapshot recent bus events for the status bar.
        let recent = bus.recent_snapshot();

        // Active agent id for the right panel (use view id).
        let active_agent_id = views[active].id().to_string();

        {
            let v = &mut views[active];
            terminal.draw(|f| {
                ui::render(
                    f,
                    &mut **v,
                    active,
                    &title_refs,
                    recent.as_slice(),
                    &state,
                    &active_agent_id,
                );
            })?;
        }

        let ev = match rx.recv().await {
            Some(e) => e,
            None => break,
        };

        debug!(?ev, "event");

        // ── Modal events (highest priority) ──────────────────────────────────
        if state.modal_active() {
            if let AppEvent::Key(k) = &ev {
                let outcome = handle_modal_key(k, &mut state, &mut views, PERRI_IDX, active);
                if let Some(new_active) = outcome {
                    active = new_active;
                }
                continue;
            }
        }

        // ── Resize ───────────────────────────────────────────────────────────
        if let AppEvent::Resize(cols, rows) = &ev {
            terminal.resize(ratatui::layout::Rect::new(0, 0, *cols, *rows))?;
            let area = ratatui::layout::Rect::new(0, 0, *cols, *rows);
            views[active].on_resize(area);
            continue;
        }

        // ── AgentUpdate: just redraw ──────────────────────────────────────────
        if matches!(ev, AppEvent::AgentUpdate { .. }) {
            continue;
        }

        // ── Background data events ────────────────────────────────────────────
        match &ev {
            AppEvent::BreakGlassDetected(req) => {
                state.break_glass = Some(req.clone());
                // Forward to all views for completeness (no-op for most).
                views[active].on_event(&ev);
                continue;
            }
            AppEvent::RightPanelData(data) => {
                state.right_panel_data = data.clone();
                continue;
            }
            AppEvent::AwaitDetected(job) => {
                // Auto-open the await modal if no other modal is active.
                if state.modal.is_none() {
                    info!("auto-opening await modal for job {}", job.id);
                    state.modal =
                        Some(ModalState::Await(Box::new(AwaitModal::new(*job.clone()))));
                    // Also forward to Mother view so it can update its job list.
                }
                views[MOTHER_IDX].on_event(&ev);
                continue;
            }
            AppEvent::MotherJobs(_) | AppEvent::MotherStatusline(_) => {
                // Always forward to Mother view; it owns this state.
                views[MOTHER_IDX].on_event(&ev);
                continue;
            }
            _ => {}
        }

        // ── Key events ───────────────────────────────────────────────────────
        match &ev {
            AppEvent::Key(k) => {
                // Global: always quit on Ctrl-C.
                if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    break;
                }

                // Ctrl-R: toggle right panel.
                if k.code == KeyCode::Char('r') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    state.right_panel_visible = !state.right_panel_visible;
                    continue;
                }

                // Ctrl-B: open break-glass modal (only when sentinel present).
                if k.code == KeyCode::Char('b') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    if let Some(req) = state.break_glass.clone() {
                        if state.modal.is_none() {
                            state.modal =
                                Some(ModalState::BreakGlass(Box::new(BreakGlassModal::new(req))));
                        }
                    }
                    continue;
                }

                // Global tab switching (unless PTY focused).
                if !views[active].pty_focus() {
                    match k.code {
                        KeyCode::Char('q') => break,

                        KeyCode::Tab => {
                            active = (active + 1) % views.len();
                            continue;
                        }
                        KeyCode::BackTab => {
                            active = active.checked_sub(1).unwrap_or(views.len() - 1);
                            continue;
                        }
                        _ => {}
                    }
                }

                // Dispatch key to the active view.
                views[active].on_event(&ev);

                // ── Check if MotherView posted a pending action ───────────────
                if active == MOTHER_IDX {
                    if let Some(mv) = views[MOTHER_IDX]
                        .as_any_mut()
                        .downcast_mut::<views::mother::MotherView>()
                    {
                        if let Some(action) = mv.take_action() {
                            handle_mother_action(action, &mut state);
                        }
                    }
                }
            }

            AppEvent::Mouse(m) => {
                use crossterm::event::MouseEventKind;
                if matches!(m.kind, MouseEventKind::Down(_)) && m.row == 0 {
                    let idx = (m.column as usize) / 12;
                    if idx < views.len() {
                        active = idx;
                    }
                }
            }

            AppEvent::Tick => {
                views[active].on_tick();
            }

            _ => {
                views[active].on_event(&ev);
            }
        }
    }

    info!("event loop exiting");
    Ok(())
}

// ── modal key dispatch ────────────────────────────────────────────────────────

/// Handle a key event when a modal is active.  Returns `Some(new_active)` when
/// the active view should change (e.g. "view diff" switches to Perri).
fn handle_modal_key(
    k: &crossterm::event::KeyEvent,
    state: &mut AppState,
    views: &mut [BoxedView],
    perri_idx: usize,
    current_active: usize,
) -> Option<usize> {
    let mut new_active: Option<usize> = None;

    let modal = state.modal.take()?;

    match modal {
        ModalState::Await(mut m) => {
            match m.on_key(k) {
                AwaitAction::Consumed => {
                    state.modal = Some(ModalState::Await(m));
                }
                AwaitAction::Approve(answer) => {
                    let id = m.job.id.clone();
                    tokio::spawn(async move {
                        if let Err(e) = mother::resume(&id, &answer).await {
                            warn!("mother resume failed: {e:#}");
                        }
                    });
                    // modal closed
                }
                AwaitAction::Deny => {
                    let id = m.job.id.clone();
                    tokio::spawn(async move {
                        if let Err(e) = mother::cancel(&id).await {
                            warn!("mother cancel failed: {e:#}");
                        }
                    });
                }
                AwaitAction::ViewDiff => {
                    // Close modal, switch to Perri, focus its diff.
                    if let Some(path) = worktree_path_for_job(&m.job) {
                        if let Some(pv) = views[perri_idx]
                            .as_any_mut()
                            .downcast_mut::<views::perri::PerriView>()
                        {
                            pv.focus_diff_for_worktree(&path);
                        }
                    }
                    new_active = Some(perri_idx);
                }
                AwaitAction::Dismiss => {
                    // modal closed, no action
                }
            }
        }

        ModalState::BreakGlass(m) => {
            match m.on_key(k) {
                BreakGlassAction::Consumed => {
                    state.modal = Some(ModalState::BreakGlass(m));
                }
                BreakGlassAction::Confirm => {
                    if let Err(e) = break_glass::respond(true) {
                        warn!("break-glass respond(approved) failed: {e:#}");
                    }
                    state.break_glass = None;
                }
                BreakGlassAction::Deny => {
                    if let Err(e) = break_glass::respond(false) {
                        warn!("break-glass respond(denied) failed: {e:#}");
                    }
                    state.break_glass = None;
                }
                BreakGlassAction::Dismiss => {}
            }
        }

        ModalState::ConfirmCancel { job_id, modal: m } => {
            match m.on_key(k) {
                ConfirmAction::Yes => {
                    tokio::spawn(async move {
                        if let Err(e) = mother::cancel(&job_id).await {
                            warn!("mother cancel failed: {e:#}");
                        }
                    });
                }
                ConfirmAction::No | ConfirmAction::Dismiss => {}
                ConfirmAction::Consumed => {
                    state.modal = Some(ModalState::ConfirmCancel { job_id, modal: m });
                }
            }
        }

        ModalState::ConfirmRetry { job_id, plan_path, modal: m } => {
            match m.on_key(k) {
                ConfirmAction::Yes => {
                    let path = PathBuf::from(plan_path);
                    let _job_id = job_id;
                    tokio::spawn(async move {
                        if let Err(e) = mother::add_plan(&path).await {
                            warn!("mother add --plan failed: {e:#}");
                        }
                    });
                }
                ConfirmAction::No | ConfirmAction::Dismiss => {}
                ConfirmAction::Consumed => {
                    state.modal = Some(ModalState::ConfirmRetry {
                        job_id,
                        plan_path,
                        modal: m,
                    });
                }
            }
        }
    }

    new_active.or(Some(current_active)).filter(|&v| v != current_active)
}

// ── mother action handling ────────────────────────────────────────────────────

fn handle_mother_action(action: MotherAction, state: &mut AppState) {
    match action {
        MotherAction::CancelJob(job) => {
            let prompt = format!("Cancel job \"{}\"? [y/n]", job.title);
            state.modal = Some(ModalState::ConfirmCancel {
                job_id: job.id,
                modal: ConfirmModal::new(prompt),
            });
        }

        MotherAction::RetryJob(job) => {
            match &job.plan_path {
                Some(path) if !path.is_empty() => {
                    let prompt =
                        format!("Retry job \"{}\" by re-adding its plan? [y/n]", job.title);
                    state.modal = Some(ModalState::ConfirmRetry {
                        job_id: job.id,
                        plan_path: path.clone(),
                        modal: ConfirmModal::new(prompt),
                    });
                }
                _ => {
                    // No plan_path — show status note, skip retry.
                    warn!(
                        "retry requested for job {} but plan_path absent; cannot retry",
                        job.id
                    );
                    state.status_note = Some(format!(
                        "⚠ Cannot retry {}: no plan_path in job record",
                        &job.id[..8.min(job.id.len())]
                    ));
                }
            }
        }

        MotherAction::OpenAwaitModal(job) => {
            state.modal = Some(ModalState::Await(Box::new(AwaitModal::new(job))));
        }
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Derive a worktree path for a job (used by "view diff").
///
/// Mother stores `work_dir` in the job JSON but `MotherJob` doesn't currently
/// deserialise it — we fall back to using the job's branch if available.
/// For now, returns `None` (Perri's `focus_diff_for_worktree` is a no-op when
/// path is absent).
fn worktree_path_for_job(_job: &crate::mother::MotherJob) -> Option<PathBuf> {
    // Phase 3: work_dir is present in the full job JSON but not yet in MotherJob.
    // Return None — PerriView::focus_diff_for_worktree handles None gracefully.
    None
}
