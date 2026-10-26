//! Pure text engine for agent follow: turns terminal bytes into the plain
//! text an agent reads.
//!
//! No I/O lives here. The pieces are wired to live terminals elsewhere:
//!
//! * [`LineAssembler`]: a streaming byte-to-lines state machine (escapes
//!   stripped, `\r` redraws collapsed to their final state, memory bounded).
//! * [`screen_snapshot`]: a `vt100` screen as plain text (full-screen programs).
//!   Raw: send an agent [`deliver_snapshot`] instead.
//! * [`DeliveryPolicy`]: when to deliver, and when to pause following.
//! * [`deliver`] and [`deliver_snapshot`]: the ONLY public paths from terminal
//!   text (assembled lines, a screen) to agent text. They redact first and cap
//!   second, and fail closed ([`Delivery::Withheld`]). Everything else the
//!   assembler and `screen_snapshot` return is raw and never goes to an agent.
//!   The line and byte caps (`truncate`) are crate-private so nothing can
//!   truncate before redacting.
//!
//! Secret redaction is a sibling module, [`crate::terminal::redact`].

mod deliver;
mod lines;
mod policy;
mod snapshot;
mod truncate;

pub use deliver::{deliver, deliver_snapshot, Delivery, WITHHELD_MARKER};
pub use lines::{LineAssembler, MAX_BUFFERED_CELLS, MAX_BUFFERED_ROWS, MAX_LINE_COLUMNS};
pub use policy::{Decision, DeliveryKind, DeliveryPolicy, PauseReason};
pub use snapshot::screen_snapshot;
