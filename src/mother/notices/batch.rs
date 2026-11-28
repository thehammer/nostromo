//! Per-focus batching: what waits to be told, the batch window, and why a due
//! delivery is held. Jonesy's (`jonesy_core::batch`), over this module's
//! [`NoticeItem`].
//!
//! * The first waking change opens a window. Every change for the focus while
//!   it is open joins it (quiet ones too) and moves its end: it closes
//!   [`WINDOW_QUIET_MS`] after the last change or [`WINDOW_MAX_MS`] after the
//!   first, whichever is first.
//! * Changes are kept latest per job: a job's item gathers its states oldest
//!   first (the element's `since`), consecutive repeats collapsed.
//! * A quiet change with no window open is kept (the newest
//!   [`MAX_RIDE_ALONG_JOBS`] jobs) and rides along in the next delivery.
//! * Items handed to the session but not yet written are "in flight", tagged
//!   with the generation of the message that carries them.

pub use jonesy_core::batch::{
    Hold, HoldReason, Window, HOLD_MAX_MS, MAX_RIDE_ALONG as MAX_RIDE_ALONG_JOBS, WINDOW_MAX_MS,
    WINDOW_QUIET_MS,
};

use super::element::NoticeItem;

/// Everything waiting for one focus.
pub type Bucket = jonesy_core::batch::Bucket<NoticeItem>;
/// One job waiting to be told.
pub type Pending = jonesy_core::batch::Pending<NoticeItem>;
/// Items in a message handed to the session and not yet written.
pub type InFlight = jonesy_core::batch::InFlight<NoticeItem>;
