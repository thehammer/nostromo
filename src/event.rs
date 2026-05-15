//! Normalised event stream for the application.
//!
//! A background tokio task polls crossterm for input events on a blocking
//! thread and emits `AppEvent` values through an unbounded channel.  A
//! periodic tick is also injected on a fixed interval so views can animate
//! without waiting for user input.

use std::collections::HashMap;
use std::time::Duration;

use crossterm::event::{self, Event as CtEvent, KeyCode, KeyEvent, MouseEvent};
use tokio::sync::mpsc;
use tracing::warn;

use crate::{
    data::{
        break_glass::BreakGlassRequest,
        rate_limits::{BudgetPosture, PostureSnapshot, RateLimits},
        right_panel_source::RightPanelSnapshot,
    },
    mcp::command::McpCommand,
    mother::{MotherJob, MotherStatus},
};

/// Normalised event enum consumed by `App` and `View` implementations.
///
/// Note: `Clone` is intentionally absent — the `McpCommand` variant carries
/// `oneshot::Sender`s which are not `Clone`.  Events are consumed once by the
/// event loop and never need to be cloned.
#[derive(Debug)]
pub enum AppEvent {
    /// A keyboard event (raw crossterm key event).
    Key(KeyEvent),
    /// A mouse event.
    Mouse(MouseEvent),
    /// Periodic tick (250 ms by default).
    Tick,
    /// Terminal was resized to (cols, rows).
    Resize(u16, u16),
    /// A data snapshot from an agent was updated — view should re-render.
    AgentUpdate { view_id: &'static str },
    /// Mother job list refreshed.
    MotherJobs(Vec<MotherJob>),
    /// Mother statusline cache changed.
    MotherStatusline(MotherStatus),
    /// A job transitioned into `awaiting` since the last poll.
    /// Boxed to keep enum size uniform (MotherJob is large).
    AwaitDetected(Box<MotherJob>),
    /// Break-glass sentinel appeared at `$HOME/.nostromo/break-glass.json`.
    BreakGlassDetected(BreakGlassRequest),
    /// Right-panel snapshots updated (keyed by agent id).
    RightPanelData(HashMap<String, RightPanelSnapshot>),
    /// Claude rate-limit window snapshot updated.
    RateLimitsChanged(RateLimits),
    /// Budget posture file updated (back-compat, posture string only).
    PostureChanged(BudgetPosture),
    /// Full posture snapshot including per-window pace data.
    PostureSnapshot(PostureSnapshot),
    /// A command from the MCP server intended for the main event loop.
    ///
    /// Boxed to keep `AppEvent` size uniform — `McpCommand` can carry large strings.
    McpCommand(Box<McpCommand>),
}

/// Tick interval for the event loop.
pub const TICK_INTERVAL: Duration = Duration::from_millis(250);

/// Start the background crossterm polling task and return the receiver end of
/// the event channel.  The sender is kept alive by the spawned task; dropping
/// it causes the channel to close.
pub fn spawn(tx: mpsc::UnboundedSender<AppEvent>) {
    // Crossterm event polling must run on a blocking thread (it calls
    // std::io blocking reads internally).
    tokio::task::spawn_blocking(move || {
        loop {
            // Block for up to TICK_INTERVAL so we can inject ticks ourselves.
            match event::poll(TICK_INTERVAL) {
                Ok(true) => match event::read() {
                    Ok(CtEvent::Key(k)) => {
                        if tx.send(AppEvent::Key(k)).is_err() {
                            break;
                        }
                    }
                    Ok(CtEvent::Mouse(m)) => {
                        if tx.send(AppEvent::Mouse(m)).is_err() {
                            break;
                        }
                    }
                    Ok(CtEvent::Resize(w, h)) => {
                        if tx.send(AppEvent::Resize(w, h)).is_err() {
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(e) => {
                        warn!("crossterm read error: {e}");
                    }
                },
                Ok(false) => {
                    // Timeout — inject tick
                    if tx.send(AppEvent::Tick).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    warn!("crossterm poll error: {e}");
                }
            }
        }
    });
}

/// Convenience: return true when a key event matches `code` (ignoring modifiers).
pub fn is_key(ev: &AppEvent, code: KeyCode) -> bool {
    matches!(ev, AppEvent::Key(k) if k.code == code)
}
