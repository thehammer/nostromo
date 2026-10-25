//! Pure text engine for agent follow: turns terminal bytes into the plain
//! text an agent reads.
//!
//! No I/O lives here. The pieces are wired to live terminals elsewhere:
//!
//! * [`LineAssembler`]: a streaming byte-to-lines state machine (escapes
//!   stripped, `\r` redraws collapsed to their final state, memory bounded).
//! * [`screen_snapshot`]: a `vt100` screen as plain text (full-screen programs).
//! * [`DeliveryPolicy`]: when to deliver, and when to pause following.
//! * [`deliver`]: the ONLY public path from assembled lines to agent text. It
//!   redacts first and caps second, and fails closed ([`Delivery::Withheld`]).
//!   The line and byte caps (`truncate`) are crate-private so nothing can
//!   truncate before redacting.
//!
//! Secret redaction is a sibling module, [`crate::terminal::redact`].

mod deliver;
mod lines;
mod policy;
mod snapshot;
mod truncate;

pub use deliver::{deliver, Delivery, WITHHELD_MARKER};
pub use lines::{LineAssembler, MAX_BUFFERED_CELLS, MAX_BUFFERED_ROWS, MAX_LINE_COLUMNS};
pub use policy::{Decision, DeliveryKind, DeliveryPolicy, PauseReason};
pub use snapshot::screen_snapshot;
