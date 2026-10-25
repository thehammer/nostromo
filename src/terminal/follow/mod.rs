//! Pure text engine for agent follow: turns terminal bytes into the plain
//! text an agent reads.
//!
//! No I/O lives here. The pieces are wired to live terminals elsewhere:
//!
//! * [`LineAssembler`]: a streaming byte-to-lines state machine (escapes
//!   stripped, `\r` redraws collapsed to their final state).
//! * [`screen_snapshot`]: a `vt100` screen as plain text (full-screen programs).
//! * [`DeliveryPolicy`]: when to deliver, and when to pause following.
//! * [`truncate`]: head-and-tail cap with an omitted-lines marker.
//!
//! Secret redaction is a sibling module, [`crate::terminal::redact`].

mod lines;
mod policy;
mod snapshot;
mod truncate;

pub use lines::{LineAssembler, MAX_LINE_COLUMNS};
pub use policy::{Decision, DeliveryKind, DeliveryPolicy, PauseReason};
pub use snapshot::screen_snapshot;
pub use truncate::{truncate, Truncated};
