//! Root render function — lays out chrome and delegates to the active view.
//!
//! Phase 3 additions:
//! - Horizontal right-panel split (25% wide) when `AppState::right_panel_visible`.
//! - Active modal drawn as centered overlay after the view content.
//! - Break-glass banner propagated to chrome via `AppState::break_glass`.

pub mod chrome;
pub mod theme;
pub mod widgets;

use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::{
    agent_bus::ActivityEvent,
    app::{AppState, ModalState},
    views::View,
};

/// Render one frame.
///
/// `titles` is the list of view tab labels (pre-collected to avoid double-borrow).
/// `recent_activity` is the latest activity slice from the `AgentBus`.
/// `state` is the shared application state (modals, right panel, break-glass).
/// `active_agent_id` is the view id of the currently-active view (for right panel lookup).
pub fn render(
    f: &mut Frame,
    active_view: &mut dyn View,
    active_idx: usize,
    titles: &[&str],
    recent_activity: &[ActivityEvent],
    state: &AppState,
    active_agent_id: &str,
) {
    let area = f.area();

    // Pull snapshot refs for the status bar from the Fred view if active.
    let mailbox_snap;
    let calendar_snap;

    if let Some(fred) = active_view
        .as_any()
        .downcast_ref::<crate::views::fred::FredView>()
    {
        mailbox_snap = fred.mailbox_snapshot_cloned();
        calendar_snap = fred.calendar_snapshot_cloned();
    } else {
        mailbox_snap = None;
        calendar_snap = None;
    }

    let content_area = chrome::render_chrome(
        f,
        area,
        titles,
        active_idx,
        mailbox_snap.as_ref(),
        calendar_snap.as_ref(),
        recent_activity,
        state.break_glass.as_ref(),
        state.status_note.as_deref(),
    );

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

    // Render the active view.
    active_view.render(f, view_area);

    // Render the right panel if visible.
    if let Some(rp_area) = right_area {
        let snap = state.right_panel_data.get(active_agent_id);
        if let Some(snap) = snap {
            widgets::right_panel::render(f, rp_area, snap);
        } else {
            // Empty panel with border when no data yet.
            use ratatui::{
                style::Style,
                widgets::{Borders, Paragraph},
                text::Span,
            };
            let block = ratatui::widgets::Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(theme::BORDER_INACTIVE))
                .title(Span::styled(" Context ", Style::default().fg(theme::FG_MUTED)));
            let inner = block.inner(rp_area);
            f.render_widget(block, rp_area);
            f.render_widget(
                Paragraph::new(Span::styled("(no data)", Style::default().fg(theme::FG_MUTED))),
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
fn render_modal(f: &mut Frame, area: ratatui::layout::Rect, modal: &ModalState) {
    match modal {
        ModalState::Await(m) => m.render(f, area),
        ModalState::BreakGlass(m) => m.render(f, area),
        ModalState::ConfirmCancel { modal: m, .. } => m.render(f, area),
        ModalState::ConfirmRetry { modal: m, .. } => m.render(f, area),
    }
}
