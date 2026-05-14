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
//!
//! Phase 5c additions:
//! - Split-pane layout system (`LayoutNode`, `Ctrl-W` chord).
//! - Command palette (`Ctrl-P`).
//! - Sweater status colours on tab bar (Perri PR count, Mother job runtime).
//!
//! Phase 4 MCP additions:
//! - `AppState::toasts` — transient toast queue, auto-expired on Tick.
//! - `AppState::mcp_status_segments` — per-view status-bar segments.
//! - `McpCommand::Notify`, `RegisterStatusSegment`, `ClearStatusSegment` handlers.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::{
    agent_bus::AgentBus,
    config::Config,
    data::{
        break_glass::{self, BreakGlassRequest},
        fred_calendar::{CalendarSnapshot, FredCalendarSource},
        fred_calendar_native::FredCalendarNativeSource,
        fred_mailbox::{FredMailboxSource, MailboxSnapshot},
        fred_mailbox_native::FredMailboxNativeSource,
        mother_poll,
        perri_pr::PerriPrSource,
        perri_pr_native::PerriPrNativeSource,
        perri_queue::PerriQueueSource,
        perri_queue_native::PerriQueueNativeSource,
        rate_limits::{BudgetPosture, RateLimits},
        rate_limits_watcher,
        right_panel_source::{self, RightPanelSnapshot},
        teri_todos::TeriTodosNativeSource,
    },
    event::{self, AppEvent},
    layout::{self, LayoutNode, Side, SplitDir},
    mcp::{McpServer, McpSharedState, ViewMeta},
    mother::{self, MotherJob},
    pty::{DaemonPtyFactory, InProcessPtyFactory, PtyFactory},
    ui,
    ui::widgets::syntect_cache::SyntectCache,
    views::{
        self,
        await_modal::{AwaitAction, AwaitModal},
        break_glass_modal::{BreakGlassAction, BreakGlassModal, ConfirmAction, ConfirmModal},
        command_palette::{build_items, CommandPalette, PaletteAction, PaletteOutcome},
        mother::MotherAction,
        BoxedView, ViewCtx,
    },
    ViewArg,
};

// ── MCP phase-4 types ─────────────────────────────────────────────────────────

/// A transient notification posted via `nostromo.notify`.
///
/// Displayed in the status bar and auto-expires after `TOAST_TTL_SECS` seconds.
pub struct Toast {
    pub text: String,
    pub level: crate::mcp::command::NotifyLevel,
    /// Unix epoch second at which this toast should stop rendering.
    pub expires_at: i64,
}

impl Toast {
    pub fn new(text: String, level: crate::mcp::command::NotifyLevel) -> Self {
        let expires_at = chrono::Utc::now().timestamp() + TOAST_TTL_SECS;
        Self { text, level, expires_at }
    }
}

/// How long a toast is displayed.
const TOAST_TTL_SECS: i64 = 5;

/// A status-bar segment registered by an MCP tool call.
pub struct McpStatusSegment {
    pub text: String,
    /// Optional named or hex color string.
    pub color: Option<String>,
}

// ── modal state ───────────────────────────────────────────────────────────────

/// The single active modal (at most one at a time).
///
/// Large variants are boxed to keep enum size uniform.
pub enum ModalState {
    Await(Box<AwaitModal>),
    BreakGlass(Box<BreakGlassModal>),
    /// Confirm a `mother cancel <id>` operation.
    ConfirmCancel {
        job_id: String,
        modal: ConfirmModal,
    },
    /// Confirm a `mother add --plan <path>` retry operation.
    ConfirmRetry {
        job_id: String,
        plan_path: String,
        modal: ConfirmModal,
    },
    /// Command palette overlay (Ctrl-P).
    Palette(Box<CommandPalette>),
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

    // ── Phase 5c additions ────────────────────────────────────────────────────
    /// Split-pane layout tree.
    pub layout: LayoutNode,
    /// Path from the root of `layout` to the currently-focused pane.
    pub focused_path: Vec<Side>,
    /// When `false`, single-view behaviour is identical to pre-5c.
    pub split_mode: bool,
    /// First key of a `Ctrl-W` chord while waiting for the second key.
    pub pending_chord: Option<KeyCode>,
    /// Most-recently-known Mother job list (populated via `AppEvent::MotherJobs`).
    pub mother_jobs: Vec<MotherJob>,
    /// Number of open PRs in Perri's review queue (for sweater-colour tab bar).
    pub perri_open_pr_count: usize,
    /// PR list snapshot for the command palette (url, title).
    pub open_pr_list: Vec<(String, String)>,

    // ── UX polish / debug overlay additions ──────────────────────────────────
    /// Whether the Ctrl-D debug overlay is currently shown.
    pub show_debug_overlay: bool,
    /// Per-tab (start_col_inclusive, end_col_exclusive) in terminal coordinates.
    /// Populated by `render_tab_bar` each frame for accurate mouse hit detection.
    pub tab_hitmap: Vec<(u16, u16)>,
    /// Per-status-bar-segment (start_col_inclusive, end_col_exclusive, view_id).
    /// Populated by `ui::status_bar::render` each frame for mouse hit detection.
    pub status_hitmap: Vec<(u16, u16, &'static str)>,
    /// Whether a daemon client was successfully connected at startup.
    pub daemon_connected: bool,
    /// Path to the nostromd Unix socket.
    pub daemon_socket_path: std::path::PathBuf,

    // ── Status bar data ───────────────────────────────────────────────────────
    /// Latest Claude rate-limit snapshot (populated via `AppEvent::RateLimitsChanged`).
    pub rate_limits: Option<RateLimits>,
    /// Latest budget posture (populated via `AppEvent::PostureChanged`).
    pub budget_posture: Option<BudgetPosture>,
    /// Watch receiver for mailbox snapshots (for the bottom status bar).
    pub mailbox_rx: tokio::sync::watch::Receiver<Option<MailboxSnapshot>>,
    /// Watch receiver for calendar snapshots (for the bottom status bar).
    pub calendar_rx: tokio::sync::watch::Receiver<Option<CalendarSnapshot>>,

    // ── Phase 4: MCP notifications & status segments ──────────────────────────
    /// Transient toast notifications posted via `nostromo.notify`.
    /// Expired entries are garbage-collected on every `AppEvent::Tick`.
    pub toasts: VecDeque<Toast>,
    /// MCP-registered status-bar segments keyed by `(view_id, segment_id)`.
    pub mcp_status_segments: HashMap<(String, String), McpStatusSegment>,
    /// Id of the currently active view — kept in sync each render frame so
    /// `status_bar::render` can filter segments to the active view without
    /// needing direct access to the `views` slice.
    pub active_view_id: String,
    /// Direct-push refresh sender for `PerriPrNativeSource` (Phase 4).
    /// Sending `()` triggers an immediate re-fetch, bypassing the dirty-file
    /// sentinel.  `None` when running in bash-fallback mode.
    pub perri_pr_refresh_tx: Option<tokio::sync::mpsc::UnboundedSender<()>>,
}

impl AppState {
    fn new(
        mailbox_rx: tokio::sync::watch::Receiver<Option<MailboxSnapshot>>,
        calendar_rx: tokio::sync::watch::Receiver<Option<CalendarSnapshot>>,
    ) -> Self {
        Self {
            right_panel_visible: false,
            break_glass: None,
            right_panel_data: HashMap::new(),
            modal: None,
            status_note: None,
            layout: layout::persist::load(),
            focused_path: Vec::new(),
            split_mode: false,
            pending_chord: None,
            mother_jobs: Vec::new(),
            perri_open_pr_count: 0,
            open_pr_list: Vec::new(),
            show_debug_overlay: false,
            tab_hitmap: Vec::new(),
            status_hitmap: Vec::new(),
            daemon_connected: false,
            daemon_socket_path: std::path::PathBuf::new(),
            rate_limits: None,
            budget_posture: None,
            mailbox_rx,
            calendar_rx,
            toasts: VecDeque::new(),
            mcp_status_segments: HashMap::new(),
            active_view_id: String::new(),
            perri_pr_refresh_tx: None,
        }
    }

    fn modal_active(&self) -> bool {
        self.modal.is_some()
    }
}

// ── run ───────────────────────────────────────────────────────────────────────

/// Run the application until the user quits.
#[allow(clippy::too_many_arguments)]
pub async fn run(
    initial_view: ViewArg,
    bash_fallback: bool,
    config: Config,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    syntect: Arc<SyntectCache>,
    bus: Arc<AgentBus>,
    daemon_client: Option<crate::ipc::DaemonClient>,
    picker: ratatui_image::picker::Picker,
) -> Result<()> {
    let mailbox_rx = if bash_fallback {
        FredMailboxSource::spawn(config.clone())
    } else {
        FredMailboxNativeSource::spawn(config.clone())
    };
    let calendar_rx = if bash_fallback {
        FredCalendarSource::spawn(config.clone())
    } else {
        FredCalendarNativeSource::spawn(config.clone())
    };

    // Clone receivers for AppState (status bar reads them directly).
    let mailbox_rx_state = mailbox_rx.clone();
    let calendar_rx_state = calendar_rx.clone();
    let queue_rx = if bash_fallback {
        PerriQueueSource::spawn(config.clone())
    } else {
        // Phase 4: the second element is the direct-push refresh sender.
        // The queue source is polled on an interval; MCP tools don't currently
        // trigger manual queue refreshes, so we discard the sender.
        let (rx, _queue_refresh_tx) = PerriQueueNativeSource::spawn(config.clone());
        rx
    };
    let (pr_rx, perri_pr_refresh_tx_opt) = if bash_fallback {
        (PerriPrSource::spawn(config.clone()), None)
    } else {
        let (rx, tx) = PerriPrNativeSource::spawn(config.clone());
        (rx, Some(tx))
    };

    // Clone queue_rx to monitor PR count for sweater status in the main loop.
    let mut queue_rx_for_count = queue_rx.clone();

    // Spawn Teri todos source early so its receiver is available for MCP state.
    let teri_todos_rx = TeriTodosNativeSource::spawn();

    // Record daemon connection state before daemon_client is consumed below.
    let daemon_was_connected = daemon_client.is_some();

    // Create the event channel before views so they can send AgentUpdate.
    let (tx, mut rx) = mpsc::unbounded_channel::<AppEvent>();
    event::spawn(tx.clone());

    // ── MCP mirror channels (Phase 2) ────────────────────────────────────────
    // Mother jobs, statusline, rate-limits, and budget posture flow through
    // AppEvent rather than watch channels.  We mirror them into watch channels
    // so MCP tool handlers can read them without touching the event loop.
    let (mother_jobs_mcp_tx, mother_jobs_mcp_rx) =
        tokio::sync::watch::channel::<Vec<MotherJob>>(vec![]);
    let (mother_status_mcp_tx, mother_status_mcp_rx) =
        tokio::sync::watch::channel::<Option<crate::mother::MotherStatus>>(None);
    let (rate_limits_mcp_tx, rate_limits_mcp_rx) =
        tokio::sync::watch::channel::<Option<RateLimits>>(None);
    let (budget_posture_mcp_tx, budget_posture_mcp_rx) =
        tokio::sync::watch::channel::<Option<BudgetPosture>>(None);

    // ── MCP shared state ─────────────────────────────────────────────────────
    let mcp_state = Arc::new(McpSharedState::new(
        tx.clone(),
        queue_rx.clone(),
        pr_rx.clone(),
        mailbox_rx.clone(),
        calendar_rx.clone(),
        teri_todos_rx.clone(),
        mother_jobs_mcp_rx,
        mother_status_mcp_rx,
        rate_limits_mcp_rx,
        budget_posture_mcp_rx,
    ));

    // Populate static view metadata once at startup.
    {
        let mut views_meta = mcp_state.views_meta.write().await;
        *views_meta = vec![
            ViewMeta { id: "fred",    title: "Fred".to_string(),    pane_ids: vec!["mailbox", "calendar", "repl"] },
            ViewMeta { id: "perri",   title: "Perri".to_string(),   pane_ids: vec!["pr_queue", "diff", "repl"] },
            ViewMeta { id: "claudia", title: "Claudia".to_string(), pane_ids: vec!["repl"] },
            ViewMeta { id: "cody",    title: "Cody".to_string(),    pane_ids: vec!["repl"] },
            ViewMeta { id: "kennedy", title: "Kennedy".to_string(), pane_ids: vec!["repl"] },
            ViewMeta { id: "teri",    title: "Teri".to_string(),    pane_ids: vec!["todos", "repl"] },
            ViewMeta { id: "mother",  title: "Mother".to_string(),  pane_ids: vec!["job_list", "log", "preview"] },
        ];
    }

    // Bind MCP server (best-effort: failure logs a warning but doesn't crash).
    let _mcp_server = match McpServer::bind(
        crate::mcp::default_socket_path(),
        (*mcp_state).clone(),
    ).await {
        Ok(srv) => {
            info!(socket = ?srv.socket_path(), "MCP server bound");
            Some(srv)
        }
        Err(e) => {
            warn!("MCP server bind failed (continuing without MCP): {e:#}");
            None
        }
    };

    // Construct PtyFactory; also spawn Mother pollers or daemon bridge.
    let pty_factory: Arc<dyn PtyFactory> = if let Some(client) = daemon_client {
        info!("using daemon bridge for Mother + activity events");
        crate::data::daemon_bridge::spawn(client.clone(), tx.clone(), Arc::clone(&bus));
        let factory = DaemonPtyFactory::new_with_refresh(client, Arc::clone(&mcp_state)).await;
        Arc::new(factory)
    } else {
        // In-process fallback: spawn Mother pollers as before.
        mother_poll::spawn(tx.clone());
        Arc::new(InProcessPtyFactory::new(Arc::clone(&mcp_state)))
    };

    // Spawn break-glass sentinel watcher.
    break_glass::spawn(tx.clone());

    // Spawn right-panel data source (subscribes to AgentBus).
    right_panel_source::spawn(Arc::clone(&bus), tx.clone());

    // Spawn rate-limit and budget-posture file watchers.
    rate_limits_watcher::spawn(tx.clone());

    let fred_ctx = ViewCtx {
        event_tx: tx.clone(),
        pty_factory: Arc::clone(&pty_factory),
        mcp_state: Arc::clone(&mcp_state),
    };
    let perri_ctx = ViewCtx {
        event_tx: tx.clone(),
        pty_factory: Arc::clone(&pty_factory),
        mcp_state: Arc::clone(&mcp_state),
    };
    let mother_ctx = ViewCtx {
        event_tx: tx.clone(),
        pty_factory: Arc::clone(&pty_factory),
        mcp_state: Arc::clone(&mcp_state),
    };

    let teri_ctx = ViewCtx {
        event_tx: tx.clone(),
        pty_factory: Arc::clone(&pty_factory),
        mcp_state: Arc::clone(&mcp_state),
    };

    let mut views: Vec<BoxedView> = vec![
        Box::new(views::fred::FredView::new(
            mailbox_rx,
            calendar_rx,
            config.clone(),
            fred_ctx,
            picker,
        )),
        Box::new(views::perri::PerriView::new(
            queue_rx,
            pr_rx,
            config.clone(),
            perri_ctx,
            Arc::clone(&syntect),
        )),
        Box::new(views::agent_generic::GenericView::new(
            "claudia",
            "Claudia",
            ViewCtx {
                event_tx: tx.clone(),
                pty_factory: Arc::clone(&pty_factory),
                mcp_state: Arc::clone(&mcp_state),
            },
        )),
        Box::new(views::agent_generic::GenericView::new(
            "cody",
            "Cody",
            ViewCtx {
                event_tx: tx.clone(),
                pty_factory: Arc::clone(&pty_factory),
                mcp_state: Arc::clone(&mcp_state),
            },
        )),
        Box::new(views::agent_generic::GenericView::new(
            "kennedy",
            "Kennedy",
            ViewCtx {
                event_tx: tx.clone(),
                pty_factory: Arc::clone(&pty_factory),
                mcp_state: Arc::clone(&mcp_state),
            },
        )),
        Box::new(views::teri::TeriView::new(teri_todos_rx, teri_ctx)),
        Box::new(views::mother::MotherView::new(config.clone(), mother_ctx)),
    ];

    // Index of the Mother view within `views`.
    const MOTHER_IDX: usize = 6;
    // Index of the Perri view within `views`.
    const PERRI_IDX: usize = 1;

    let mut active: usize = match initial_view {
        ViewArg::Fred => 0,
        ViewArg::Perri => 1,
        ViewArg::All => 0,
    };

    let mut state = AppState::new(mailbox_rx_state, calendar_rx_state);
    state.daemon_connected = daemon_was_connected;
    state.daemon_socket_path = crate::ipc::default_socket_path();
    state.perri_pr_refresh_tx = perri_pr_refresh_tx_opt;

    info!("event loop starting");

    loop {
        // Keep perri_open_pr_count in sync with the queue watch.
        if queue_rx_for_count.has_changed().unwrap_or(false) {
            if let Some(snap) = queue_rx_for_count.borrow_and_update().clone() {
                state.perri_open_pr_count = snap.items.len();
                state.open_pr_list = snap
                    .items
                    .iter()
                    .map(|it| (it.url.clone(), it.title.clone()))
                    .collect();
            }
        }

        // Collect titles before the mutable borrow of views[active].
        let titles: Vec<String> = views.iter().map(|v| v.title().to_string()).collect();
        let title_refs: Vec<&str> = titles.iter().map(|s| s.as_str()).collect();

        // Snapshot recent bus events for the status bar.
        let recent = bus.recent_snapshot();

        // Active view index: in split mode, use the focused pane's view idx.
        let focused_view_idx = if state.split_mode {
            state
                .layout
                .focused_view_idx(&state.focused_path)
                .min(views.len() - 1)
        } else {
            active
        };

        // Active agent id for the right panel (use view id).
        let active_agent_id = views[focused_view_idx].id().to_string();

        terminal.draw(|f| {
            use ratatui::layout::{Constraint, Layout};
            let full_area = f.area();
            let [content_area, status_area] =
                Layout::vertical([Constraint::Min(0), Constraint::Length(1)]).areas(full_area);
            ui::render(
                f,
                content_area,
                &mut views,
                active,
                focused_view_idx,
                &title_refs,
                recent.as_slice(),
                &mut state,
                &active_agent_id,
            );
            // Keep active_view_id in sync so status_bar can filter MCP segments.
            state.active_view_id = views[active].id().to_owned();
            ui::status_bar::render(f, status_area, &mut state);
            if state.show_debug_overlay {
                ui::debug_overlay::render(f, full_area, &state, &views, active);
            }
        })?;

        let ev = match rx.recv().await {
            Some(e) => e,
            None => break,
        };

        debug!(?ev, "event");

        // ── Modal events (highest priority) ──────────────────────────────────
        if state.modal_active() {
            if let AppEvent::Key(k) = &ev {
                let outcome = handle_modal_key(
                    k,
                    &mut state,
                    &mut views,
                    PERRI_IDX,
                    active,
                    focused_view_idx,
                );
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

        // ── MCP mutations ─────────────────────────────────────────────────────
        if let AppEvent::McpCommand(cmd) = ev {
            handle_mcp_command(
                *cmd,
                &mut views,
                &mut active,
                &mut state,
                PERRI_IDX,
                MOTHER_IDX,
            ).await;
            continue;
        }

        // ── Background data events ────────────────────────────────────────────
        match &ev {
            AppEvent::BreakGlassDetected(req) => {
                state.break_glass = Some(req.clone());
                views[active].on_event(&ev);
                continue;
            }
            AppEvent::RightPanelData(data) => {
                state.right_panel_data = data.clone();
                continue;
            }
            AppEvent::AwaitDetected(job) => {
                if state.modal.is_none() {
                    info!("auto-opening await modal for job {}", job.id);
                    state.modal = Some(ModalState::Await(Box::new(AwaitModal::new(*job.clone()))));
                }
                views[MOTHER_IDX].on_event(&ev);
                continue;
            }
            AppEvent::MotherJobs(jobs) => {
                state.mother_jobs = jobs.clone();
                let _ = mother_jobs_mcp_tx.send(jobs.clone());
                views[MOTHER_IDX].on_event(&ev);
                continue;
            }
            AppEvent::MotherStatusline(status) => {
                let _ = mother_status_mcp_tx.send(Some(status.clone()));
                views[MOTHER_IDX].on_event(&ev);
                continue;
            }
            AppEvent::RateLimitsChanged(rl) => {
                state.rate_limits = Some(*rl);
                let _ = rate_limits_mcp_tx.send(Some(*rl));
                continue;
            }
            AppEvent::PostureChanged(p) => {
                state.budget_posture = Some(*p);
                let _ = budget_posture_mcp_tx.send(Some(*p));
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

                // Ctrl-P: open command palette (before PTY guard).
                if k.code == KeyCode::Char('p') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    let items = build_items(&state, &state.mother_jobs.clone());
                    state.modal = Some(ModalState::Palette(Box::new(CommandPalette::new(items))));
                    continue;
                }

                // Ctrl-W: layout chord — intercepted before PTY-focus guard.
                if k.code == KeyCode::Char('w') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    state.pending_chord = Some(KeyCode::Char('w'));
                    continue;
                }

                // Consume the second key of a pending Ctrl-W chord.
                if let Some(KeyCode::Char('w')) = state.pending_chord.take() {
                    handle_ctrl_w_chord(k.code, &mut state, &mut views, &mut active);
                    continue;
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

                // Ctrl-]: toggle PTY input capture on the active view.
                // Ghostty (kitty protocol) encodes Ctrl-] as Char('5')+CONTROL.
                if (k.code == KeyCode::Char(']') || k.code == KeyCode::Char('5'))
                    && k.modifiers.contains(KeyModifiers::CONTROL)
                {
                    let cur = views[focused_view_idx].pty_capturing_input();
                    views[focused_view_idx].set_pty_capturing_input(!cur);
                    continue;
                }

                // Ctrl-D: toggle debug overlay.
                if k.code == KeyCode::Char('d') && k.modifiers.contains(KeyModifiers::CONTROL) {
                    state.show_debug_overlay = !state.show_debug_overlay;
                    continue;
                }

                // If debug overlay is up, any other key dismisses it (consumed).
                if state.show_debug_overlay {
                    state.show_debug_overlay = false;
                    continue;
                }

                // Global tab switching (unless PTY is capturing input).
                // Use Tab / Shift-Tab to cycle.  Ctrl-digit shortcuts are not used:
                // Ghostty (kitty protocol) only reliably delivers Ctrl-4..7 with the
                // CONTROL modifier; Ctrl-1/2/3/8/9/0 arrive as bare digits or Esc/BS.
                if !views[focused_view_idx].pty_capturing_input() {
                    match k.code {
                        KeyCode::Char('q') => break,

                        KeyCode::Tab => {
                            let old = active;
                            active = (active + 1) % views.len();
                            views[old].blur();
                            views[active].focus();
                            // In split mode, also update the focused leaf's view_idx.
                            if state.split_mode {
                                update_focused_leaf_view(
                                    &mut state.layout,
                                    &state.focused_path,
                                    active,
                                );
                                layout::persist::save(&state.layout);
                            }
                            continue;
                        }
                        KeyCode::BackTab => {
                            let old = active;
                            active = active.checked_sub(1).unwrap_or(views.len() - 1);
                            views[old].blur();
                            views[active].focus();
                            if state.split_mode {
                                update_focused_leaf_view(
                                    &mut state.layout,
                                    &state.focused_path,
                                    active,
                                );
                                layout::persist::save(&state.layout);
                            }
                            continue;
                        }
                        _ => {}
                    }
                }

                // Dispatch key to the active view.
                views[focused_view_idx].on_event(&ev);

                // ── Check if MotherView posted a pending action ───────────────
                if focused_view_idx == MOTHER_IDX {
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
                    if let Some(idx) = state
                        .tab_hitmap
                        .iter()
                        .position(|(s, e)| m.column >= *s && m.column < *e)
                    {
                        if idx < views.len() && idx != active {
                            views[active].blur();
                            active = idx;
                            views[active].focus();
                            if state.split_mode {
                                update_focused_leaf_view(
                                    &mut state.layout,
                                    &state.focused_path,
                                    active,
                                );
                                layout::persist::save(&state.layout);
                            }
                        }
                    }
                } else if matches!(m.kind, MouseEventKind::Down(_)) {
                    let term_h = terminal.size().map(|s| s.height).unwrap_or(0);
                    if term_h > 0 && m.row == term_h - 1 {
                        if let Some(&(_, _, view_id)) = state
                            .status_hitmap
                            .iter()
                            .find(|(s, e, _)| m.column >= *s && m.column < *e)
                        {
                            if let Some(idx) = views.iter().position(|v| v.id() == view_id) {
                                if idx != active {
                                    views[active].blur();
                                    active = idx;
                                    views[active].focus();
                                    if state.split_mode {
                                        update_focused_leaf_view(
                                            &mut state.layout,
                                            &state.focused_path,
                                            active,
                                        );
                                        layout::persist::save(&state.layout);
                                    }
                                }
                            }
                        }
                    }
                } else if matches!(
                    m.kind,
                    MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
                ) {
                    // Forward scroll events to the active view so each pane
                    // can handle them based on where the cursor is pointing.
                    views[focused_view_idx].on_event(&AppEvent::Mouse(*m));
                }
            }

            AppEvent::Tick => {
                views[focused_view_idx].on_tick();
                // Garbage-collect expired toasts.
                let now = chrono::Utc::now().timestamp();
                state.toasts.retain(|t| t.expires_at > now);
            }

            _ => {
                views[focused_view_idx].on_event(&ev);
            }
        }
    }

    info!("event loop exiting");
    Ok(())
}

// ── Ctrl-W chord handler ──────────────────────────────────────────────────────

fn handle_ctrl_w_chord(
    code: KeyCode,
    state: &mut AppState,
    views: &mut [BoxedView],
    active: &mut usize,
) {
    // Compute next unused view index for new splits.
    let next_view_idx = || -> usize {
        let used: std::collections::HashSet<usize> =
            state.layout.all_view_indices().into_iter().collect();
        (0..views.len()).find(|i| !used.contains(i)).unwrap_or(0)
    };

    match code {
        // s = vertical split (side-by-side)
        KeyCode::Char('s') => {
            let idx = next_view_idx();
            state
                .layout
                .split(&state.focused_path.clone(), SplitDir::Vertical, idx);
            state.split_mode = true;
            layout::persist::save(&state.layout);
        }

        // v = horizontal split (top/bottom)
        KeyCode::Char('v') => {
            let idx = next_view_idx();
            state
                .layout
                .split(&state.focused_path.clone(), SplitDir::Horizontal, idx);
            state.split_mode = true;
            layout::persist::save(&state.layout);
        }

        // q = close focused pane
        KeyCode::Char('q') => {
            if state.focused_path.is_empty() {
                // Last pane — toggle off split mode instead of closing.
                state.split_mode = false;
            } else {
                state.layout.close(&state.focused_path.clone());
                // Pop the last side off the path; the focus moves to the parent or sibling.
                state.focused_path.pop();
                layout::persist::save(&state.layout);
                if state.layout.leaf_count() <= 1 {
                    state.split_mode = false;
                }
            }
        }

        // h/j/k/l = move focus through the pane tree
        KeyCode::Char('h') | KeyCode::Char('k') => {
            // Move focus toward A (left/up).
            if let Some(last) = state.focused_path.last_mut() {
                *last = Side::A;
            }
        }
        KeyCode::Char('l') | KeyCode::Char('j') => {
            // Move focus toward B (right/down).
            if let Some(last) = state.focused_path.last_mut() {
                *last = Side::B;
            }
        }

        // t = toggle split mode
        KeyCode::Char('t') => {
            state.split_mode = !state.split_mode;
            if state.split_mode {
                // Restore layout; ensure active view matches focused leaf.
                *active = state
                    .layout
                    .focused_view_idx(&state.focused_path)
                    .min(views.len() - 1);
            }
        }

        // Any unrecognised key: reset chord, do not consume.
        _ => {}
    }
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
    _focused_view_idx: usize,
) -> Option<usize> {
    let mut new_active: Option<usize> = None;

    let modal = state.modal.take()?;

    match modal {
        ModalState::Palette(mut pal) => {
            match pal.on_key(k) {
                PaletteOutcome::Consumed => {
                    state.modal = Some(ModalState::Palette(pal));
                }
                PaletteOutcome::Dismiss => {
                    // modal closed
                }
                PaletteOutcome::Execute(action) => {
                    apply_palette_action(action, state, views, &mut new_active);
                }
            }
        }

        ModalState::Await(mut m) => match m.on_key(k) {
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
            AwaitAction::Dismiss => {}
        },

        ModalState::BreakGlass(m) => match m.on_key(k) {
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
        },

        ModalState::ConfirmCancel { job_id, modal: m } => match m.on_key(k) {
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
        },

        ModalState::ConfirmRetry {
            job_id,
            plan_path,
            modal: m,
        } => match m.on_key(k) {
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
        },
    }

    new_active
        .or(Some(current_active))
        .filter(|&v| v != current_active)
}

// ── palette action dispatch ───────────────────────────────────────────────────

fn apply_palette_action(
    action: PaletteAction,
    state: &mut AppState,
    views: &mut [BoxedView],
    new_active: &mut Option<usize>,
) {
    match action {
        PaletteAction::SwitchView(id) => {
            if let Some(idx) = views.iter().position(|v| v.id() == id) {
                *new_active = Some(idx);
            }
        }

        PaletteAction::SpawnFredRepl => {
            // Focus Fred view — it handles REPL spawning on focus.
            if let Some(idx) = views.iter().position(|v| v.id() == "fred") {
                *new_active = Some(idx);
            }
        }

        PaletteAction::SpawnAgentRepl(agent) => {
            if let Some(idx) = views.iter().position(|v| v.id() == agent) {
                *new_active = Some(idx);
            }
        }

        PaletteAction::OpenPrDiff(_url) => {
            // Switch to Perri; it will show the PR diff.
            if let Some(idx) = views.iter().position(|v| v.id() == "perri") {
                *new_active = Some(idx);
            }
        }

        PaletteAction::ApproveMotherJob(id) => {
            if let Some(job) = state.mother_jobs.iter().find(|j| j.id == id).cloned() {
                state.modal = Some(ModalState::Await(Box::new(AwaitModal::new(job))));
            }
        }

        PaletteAction::CancelMotherJob(job_id) => {
            let prompt = format!("Cancel job \"{}\"? [y/n]", &job_id[..8.min(job_id.len())]);
            state.modal = Some(ModalState::ConfirmCancel {
                job_id,
                modal: ConfirmModal::new(prompt),
            });
        }

        PaletteAction::SplitHorizontal => {
            let used: std::collections::HashSet<usize> =
                state.layout.all_view_indices().into_iter().collect();
            let idx = (0..views.len()).find(|i| !used.contains(i)).unwrap_or(0);
            state
                .layout
                .split(&state.focused_path.clone(), SplitDir::Horizontal, idx);
            state.split_mode = true;
            layout::persist::save(&state.layout);
        }

        PaletteAction::SplitVertical => {
            let used: std::collections::HashSet<usize> =
                state.layout.all_view_indices().into_iter().collect();
            let idx = (0..views.len()).find(|i| !used.contains(i)).unwrap_or(0);
            state
                .layout
                .split(&state.focused_path.clone(), SplitDir::Vertical, idx);
            state.split_mode = true;
            layout::persist::save(&state.layout);
        }

        PaletteAction::ClosePane => {
            if !state.focused_path.is_empty() {
                state.layout.close(&state.focused_path.clone());
                state.focused_path.pop();
                layout::persist::save(&state.layout);
                if state.layout.leaf_count() <= 1 {
                    state.split_mode = false;
                }
            }
        }

        PaletteAction::ToggleRightPanel => {
            state.right_panel_visible = !state.right_panel_visible;
        }

        PaletteAction::ToggleSplitMode => {
            state.split_mode = !state.split_mode;
        }
    }
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

        MotherAction::RetryJob(job) => match &job.plan_path {
            Some(path) if !path.is_empty() => {
                let prompt = format!("Retry job \"{}\" by re-adding its plan? [y/n]", job.title);
                state.modal = Some(ModalState::ConfirmRetry {
                    job_id: job.id,
                    plan_path: path.clone(),
                    modal: ConfirmModal::new(prompt),
                });
            }
            _ => {
                warn!(
                    "retry requested for job {} but plan_path absent; cannot retry",
                    job.id
                );
                state.status_note = Some(format!(
                    "⚠ Cannot retry {}: no plan_path in job record",
                    &job.id[..8.min(job.id.len())]
                ));
            }
        },

        MotherAction::OpenAwaitModal(job) => {
            state.modal = Some(ModalState::Await(Box::new(AwaitModal::new(job))));
        }
    }
}

// ── MCP command dispatcher ────────────────────────────────────────────────────

/// Dispatch an `McpCommand` from the MCP server to the correct view or system.
///
/// All reply channels are consumed here; if we can't find the reply receiver
/// (already dropped) we log a warning and move on.
async fn handle_mcp_command(
    cmd: crate::mcp::command::McpCommand,
    views: &mut Vec<BoxedView>,
    active: &mut usize,
    state: &mut AppState,
    perri_idx: usize,
    mother_idx: usize,
) {
    use crate::mcp::command::McpCommand;

    let _ = mother_idx; // used for context; Mother mutations are CLI-based

    match cmd {
        // ── SetPaneFocus ─────────────────────────────────────────────────────
        McpCommand::SetPaneFocus { view_id, pane_id: _, reply } => {
            // For now, interpret SetPaneFocus as switching the active view.
            match views.iter().position(|v| v.id() == view_id) {
                Some(idx) => {
                    let old = *active;
                    if old != idx {
                        views[old].blur();
                        *active = idx;
                        if state.split_mode {
                            update_focused_leaf_view(&mut state.layout, &state.focused_path, idx);
                            layout::persist::save(&state.layout);
                        }
                        views[*active].focus();
                    }
                    let _ = reply.send(Ok(()));
                }
                None => { let _ = reply.send(Err("unknown_view".into())); }
            }
        }

        // ── SetPaneContent ───────────────────────────────────────────────────
        McpCommand::SetPaneContent { view_id, pane_id, content, reply } => {
            match views.iter_mut().position(|v| v.id() == view_id.as_str()) {
                Some(idx) => {
                    let result = views[idx].apply_pane_content(&pane_id, &content);
                    let _ = reply.send(result);
                }
                None => { let _ = reply.send(Err("unknown_view".into())); }
            }
        }

        // ── SetPaneLayout ────────────────────────────────────────────────────
        McpCommand::SetPaneLayout { view_id, ratios, reply } => {
            match views.iter_mut().position(|v| v.id() == view_id.as_str()) {
                Some(idx) => {
                    let result = views[idx].apply_pane_layout(&ratios);
                    let _ = reply.send(result);
                }
                None => { let _ = reply.send(Err("unknown_view".into())); }
            }
        }

        // ── SwitchActiveView ─────────────────────────────────────────────────
        McpCommand::SwitchActiveView { view_id, reply } => {
            match views.iter().position(|v| v.id() == view_id) {
                Some(idx) => {
                    let old = *active;
                    if old != idx {
                        views[old].blur();
                        *active = idx;
                        if state.split_mode {
                            update_focused_leaf_view(&mut state.layout, &state.focused_path, idx);
                            layout::persist::save(&state.layout);
                        }
                        views[*active].focus();
                    }
                    let _ = reply.send(Ok(()));
                }
                None => { let _ = reply.send(Err("unknown_view".into())); }
            }
        }

        // ── PerriLoadPr ──────────────────────────────────────────────────────
        McpCommand::PerriLoadPr { number, repo, highlights, reply } => {
            if let Some(pv) = views[perri_idx]
                .as_any_mut()
                .downcast_mut::<views::perri::PerriView>()
            {
                let result = pv.load_pr(number, repo, highlights);
                // Phase 4: also trigger the direct-push refresh so the data
                // source re-fetches immediately without needing the dirty file.
                if let Some(tx) = &state.perri_pr_refresh_tx {
                    let _ = tx.send(());
                }
                let _ = reply.send(result);
            } else {
                let _ = reply.send(Err("internal_error: perri downcast failed".into()));
            }
        }

        // ── PerriClearCurrentPr ───────────────────────────────────────────────
        McpCommand::PerriClearCurrentPr { reply } => {
            if let Some(pv) = views[perri_idx]
                .as_any_mut()
                .downcast_mut::<views::perri::PerriView>()
            {
                let result = pv.clear_current_pr();
                let _ = reply.send(result);
            } else {
                let _ = reply.send(Err("internal_error: perri downcast failed".into()));
            }
        }

        // ── GetPerriSelectedIndex ─────────────────────────────────────────────
        McpCommand::GetPerriSelectedIndex { reply } => {
            if let Some(pv) = views[perri_idx]
                .as_any()
                .downcast_ref::<views::perri::PerriView>()
            {
                let _ = reply.send(Ok(pv.selected_pr_index()));
            } else {
                let _ = reply.send(Err("internal_error: perri downcast failed".into()));
            }
        }

        // ── SetPerriSelectedIndex ─────────────────────────────────────────────
        McpCommand::SetPerriSelectedIndex { index, reply } => {
            if let Some(pv) = views[perri_idx]
                .as_any_mut()
                .downcast_mut::<views::perri::PerriView>()
            {
                pv.set_selected_pr_index(index);
                let _ = reply.send(Ok(()));
            } else {
                let _ = reply.send(Err("internal_error: perri downcast failed".into()));
            }
        }

        // ── MotherEnqueue ─────────────────────────────────────────────────────
        McpCommand::MotherEnqueue { plan_path, reply } => {
            if !plan_path.exists() || !plan_path.is_file() {
                let _ = reply.send(Err(format!(
                    "plan_not_found: {}",
                    plan_path.display()
                )));
                return;
            }
            if let Err(e) = mother::add_plan(&plan_path).await {
                let _ = reply.send(Err(format!("mother_cli_error: {e}")));
                return;
            }
            // Re-list to find the new job (mother add doesn't return a job id).
            match mother::list_jobs().await {
                Ok(jobs) => {
                    // The most recently created job is probably our new one.
                    // Find a queued or ready job whose plan_path matches.
                    let path_str = plan_path.to_string_lossy();
                    let lite = jobs
                        .iter()
                        .find(|j| {
                            j.plan_path.as_deref() == Some(path_str.as_ref())
                                && (j.state == "queued" || j.state == "ready")
                        })
                        .or_else(|| jobs.iter().max_by_key(|j| j.created_at))
                        .map(|j| crate::mcp::command::MotherJobLite {
                            id: j.id.clone(),
                            title: j.title.clone(),
                            status: j.state.clone(),
                        })
                        .unwrap_or_else(|| crate::mcp::command::MotherJobLite {
                            id: String::new(),
                            title: String::new(),
                            status: "unknown".into(),
                        });
                    let _ = reply.send(Ok(lite));
                }
                Err(e) => {
                    // add_plan succeeded, but list failed — best-effort reply.
                    let _ = reply.send(Ok(crate::mcp::command::MotherJobLite {
                        id: String::new(),
                        title: format!("mother_list_error: {e}"),
                        status: "queued".into(),
                    }));
                }
            }
        }

        // ── MotherCancel ──────────────────────────────────────────────────────
        McpCommand::MotherCancel { job_id, reply } => {
            match mother::cancel(&job_id).await {
                Ok(()) => { let _ = reply.send(Ok(())); }
                Err(e) => { let _ = reply.send(Err(format!("mother_cli_error: {e}"))); }
            }
        }

        // ── MotherArchive ─────────────────────────────────────────────────────
        McpCommand::MotherArchive { job_id, reply } => {
            match mother::archive(&job_id).await {
                Ok(()) => { let _ = reply.send(Ok(())); }
                Err(e) => { let _ = reply.send(Err(format!("mother_cli_error: {e}"))); }
            }
        }

        // ── MotherResume ──────────────────────────────────────────────────────
        McpCommand::MotherResume { job_id, answer, reply } => {
            match mother::resume(&job_id, &answer).await {
                Ok(()) => { let _ = reply.send(Ok(())); }
                Err(e) => { let _ = reply.send(Err(format!("mother_cli_error: {e}"))); }
            }
        }

        // ── Phase 4: notifications & status segments ──────────────────────────

        // ── Notify ────────────────────────────────────────────────────────────
        McpCommand::Notify { message, level, source_view: _, reply } => {
            let toast = Toast::new(message, level);
            state.toasts.push_back(toast);
            let _ = reply.send(Ok(()));
        }

        // ── RegisterStatusSegment ─────────────────────────────────────────────
        McpCommand::RegisterStatusSegment { view_id, segment_id, text, color, reply } => {
            state.mcp_status_segments.insert(
                (view_id, segment_id),
                McpStatusSegment { text, color },
            );
            let _ = reply.send(Ok(()));
        }

        // ── ClearStatusSegment ────────────────────────────────────────────────
        McpCommand::ClearStatusSegment { view_id, segment_id, reply } => {
            state.mcp_status_segments.remove(&(view_id, segment_id));
            let _ = reply.send(Ok(()));
        }
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Derive a worktree path for a job (used by "view diff").
fn worktree_path_for_job(_job: &crate::mother::MotherJob) -> Option<PathBuf> {
    None
}

/// Update the view index stored in the focused leaf.
fn update_focused_leaf_view(layout: &mut LayoutNode, path: &[Side], view_idx: usize) {
    match (layout, path.first()) {
        (LayoutNode::Leaf { view_idx: v }, _) => *v = view_idx,
        (LayoutNode::Split { a, b, .. }, Some(side)) => {
            let child = if *side == Side::A {
                a.as_mut()
            } else {
                b.as_mut()
            };
            update_focused_leaf_view(child, &path[1..], view_idx);
        }
        (LayoutNode::Split { a, .. }, None) => {
            update_focused_leaf_view(a, &[], view_idx);
        }
    }
}
