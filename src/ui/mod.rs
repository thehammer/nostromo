//! Root render function — lays out chrome and delegates to the active view.

pub mod chrome;
pub mod theme;
pub mod widgets;

use ratatui::Frame;

use crate::{agent_bus::ActivityEvent, views::View};

/// Render one frame.
///
/// `titles` is the list of view tab labels (pre-collected to avoid double-borrow).
/// `recent_activity` is the latest activity slice from the `AgentBus`.
pub fn render(
    f: &mut Frame,
    active_view: &mut dyn View,
    active_idx: usize,
    titles: &[&str],
    recent_activity: &[ActivityEvent],
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
    );

    active_view.render(f, content_area);
}
