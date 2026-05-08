//! View trait and view registry.
//!
//! A `View` owns a region of the screen and handles input when active.  Phase
//! 1 has Fred, Perri, and generic stub views for the other agents.

pub mod agent_generic;
pub mod await_modal;
pub mod break_glass_modal;
pub mod fred;
pub mod mother;
pub mod perri;

use std::any::Any;

use ratatui::{layout::Rect, Frame};
use tokio::sync::mpsc;

use crate::event::AppEvent;

/// Shared wiring passed to every view that can host a PTY.
pub struct ViewCtx {
    /// Channel for sending app-level events (e.g. `AgentUpdate`) from async
    /// tasks back into the main event loop.
    pub event_tx: mpsc::UnboundedSender<AppEvent>,
}

/// What a view returns after handling an event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventOutcome {
    /// Event consumed; caller need not do anything further.
    Consumed,
    /// Event not handled by this view; propagate.
    Ignored,
}

/// The `View` trait.  All views implement this.  Views are `Send` so they can
/// be held across await points in the async event loop.
pub trait View: Send + Any {
    /// Stable string identifier (lowercase, no spaces).
    fn id(&self) -> &'static str;

    /// Human-readable tab label.
    fn title(&self) -> &str;

    /// Render the view into `area` on the current frame.
    fn render(&mut self, f: &mut Frame, area: Rect);

    /// Handle a normalised event.  Return `Consumed` to prevent propagation.
    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome;

    /// Called on every `Tick` while this view is active.
    fn on_tick(&mut self) {}

    /// Called when the terminal is resized. Views that own a PTY should
    /// forward the new inner dimensions to `PtyHost::resize`.
    fn on_resize(&mut self, _area: Rect) {}

    /// Returns `true` when this view's PTY is active **and** currently
    /// capturing keystrokes. The app loop uses this to decide whether to
    /// forward keys or keep them for global navigation.
    fn pty_capturing_input(&self) -> bool {
        false
    }

    /// Toggle whether this view should route keystrokes into its PTY.
    /// No-op for views without a PTY.
    fn set_pty_capturing_input(&mut self, _capturing: bool) {}

    /// Called when this view gains focus.
    fn focus(&mut self) {}

    /// Called when this view loses focus.
    fn blur(&mut self) {}

    /// Downcast support.
    fn as_any(&self) -> &dyn Any;

    /// Downcast support (mutable).
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

/// Type alias for heap-allocated views.
pub type BoxedView = Box<dyn View>;
