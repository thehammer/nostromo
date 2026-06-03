//! Root render function — lays out chrome and delegates to the active view.
//!
//! Phase 3 additions:
//! - Horizontal right-panel split (25% wide) when `AppState::right_panel_visible`.
//! - Active modal drawn as centered overlay after the view content.
//! - Break-glass banner propagated to chrome via `AppState::break_glass`.
//!
//! Phase 5c additions:
//! - Split-pane layout: when `state.split_mode == true`, walk `state.layout.rects()`
//!   and render each leaf's view into its rect.
//! - Focused leaf gets a highlighted border (`theme::BORDER_ACTIVE`).
//! - Tab bar shows per-tab sweater-colour indicators.
//! - Command palette rendered as overlay (last, on top).

pub mod chrome;
pub mod debug_overlay;
pub mod drag;
pub mod pane_ratios;
pub mod status_bar;
pub mod theme;
pub mod widgets;

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::Style,
    widgets::{Block, Borders},
    Frame,
};

use crate::{
    agent_bus::ActivityEvent,
    app::{AppState, ModalState},
    views::BoxedView,
};

/// Render one frame.
///
/// `area` is the rect to render into — the caller is responsible for splitting
/// off any reserved rows (e.g. the 1-row bottom status bar) before calling.
/// `views` is the full view list (for split-mode rendering).
/// `active` is the single-view active index (used when `split_mode == false`).
/// `focused_view_idx` is the view index of the currently-focused pane.
#[allow(clippy::too_many_arguments)]
pub fn render(
    f: &mut Frame,
    area: Rect,
    views: &mut [BoxedView],
    active: usize,
    focused_view_idx: usize,
    titles: &[&str],
    recent_activity: &[ActivityEvent],
    state: &mut AppState,
    active_agent_id: &str,
) {
    // Pull snapshot refs for the chrome status bar from AppState receivers.
    let mailbox_snap = state.mailbox_rx.borrow().clone();
    let calendar_snap = state.calendar_rx.borrow().clone();

    let pty_capturing = views[focused_view_idx].pty_capturing_input();

    // Extract values that are immutably borrowed before passing `state` as &mut.
    let break_glass_snap = state.break_glass.clone();
    let status_note_snap: Option<String> = state.status_note.clone();

    let content_area = chrome::render_chrome(
        f,
        area,
        titles,
        active,
        pty_capturing,
        mailbox_snap.as_ref(),
        calendar_snap.as_ref(),
        recent_activity,
        break_glass_snap.as_ref(),
        status_note_snap.as_deref(),
        state,
    );
    // NOTE: state.tab_hitmap is now populated by render_chrome → render_tab_bar.

    // Split content area horizontally if the right panel is visible.
    let (view_area, right_area) = if state.right_panel_visible {
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(75), Constraint::Percentage(25)])
            .split(content_area);
        (chunks[0], Some(chunks[1]))
    } else {
        (content_area, None)
    };

    // Render views.
    if state.split_mode && state.layout.leaf_count() > 1 {
        // Split mode: render each leaf into its computed rect.
        let pane_rects = state.layout.rects(view_area);
        let focused_idx = state.layout.focused_view_idx(&state.focused_path);

        for (view_idx, pane_rect) in &pane_rects {
            let view_idx = (*view_idx).min(views.len() - 1);
            let is_focused = view_idx == focused_idx;

            // Draw a border around the pane; active pane gets BORDER_ACTIVE.
            let border_style = if is_focused {
                Style::default().fg(theme::BORDER_ACTIVE)
            } else {
                Style::default().fg(theme::BORDER_INACTIVE)
            };
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(border_style);
            let inner = block.inner(*pane_rect);
            f.render_widget(block, *pane_rect);

            // Safety: we split the &mut Vec borrow by index.
            views[view_idx].render(f, inner);
        }
    } else {
        // Single-pane: render only the active view (original behaviour).
        views[active].render(f, view_area);
    }

    // Render the right panel if visible.
    if let Some(rp_area) = right_area {
        let snap = state.right_panel_data.get(active_agent_id);
        if let Some(snap) = snap {
            widgets::right_panel::render(f, rp_area, snap);
        } else {
            use ratatui::{
                style::Style,
                text::Span,
                widgets::{Borders, Paragraph},
            };
            let block = ratatui::widgets::Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(theme::BORDER_INACTIVE))
                .title(Span::styled(
                    " Context ",
                    Style::default().fg(theme::FG_MUTED),
                ));
            let inner = block.inner(rp_area);
            f.render_widget(block, rp_area);
            f.render_widget(
                Paragraph::new(Span::styled(
                    "(no data)",
                    Style::default().fg(theme::FG_MUTED),
                )),
                inner,
            );
        }
    }

    // Render any active modal as a centered overlay (last, on top of everything).
    if let Some(modal) = &state.modal {
        render_modal(f, content_area, modal);
    }
}

/// Draw the active modal overlay on top of the given area.
fn render_modal(f: &mut Frame, area: Rect, modal: &ModalState) {
    match modal {
        ModalState::Await(m) => m.render(f, area),
        ModalState::BreakGlass(m) => m.render(f, area),
        ModalState::ConfirmCancel { modal: m, .. } => m.render(f, area),
        ModalState::ConfirmRetry { modal: m, .. } => m.render(f, area),
        ModalState::ConfirmForceStart { modal: m, .. } => m.render(f, area),
        ModalState::Palette(p) => p.render(f, area),
    }
}
