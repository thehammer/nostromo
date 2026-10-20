//! The tracker engine: a markdown board file (`<repo>/.claude/wip/<topic>/index.md`)
//! that agents update item by item, the user edits in an editor or the pane,
//! and a pane renders beside the transcript.
//!
//! This module is pure: no file system, clock or wire. It parses a board
//! ([`format::parse`]), applies item operations atomically
//! ([`ops::apply_batch`]), splices the result back so every untouched byte is
//! identical ([`format::splice`]), diffs two boards into attributed
//! field-level changes ([`diff::diff`], [`diff::merge_external`]), keeps a
//! versioned change log with per-session cursors ([`changelog`]), and renders
//! what agents and the pane see ([`render`], [`view`]).
//!
//! The file format, tool surface and rules live in the design contract:
//! `.claude/plans/agent-tracker-pane-design-contract.md` (§2 format, §3
//! architecture, §4 renders, §7 quoted data).

pub mod changelog;
pub mod clock;
pub mod diff;
pub mod format;
pub mod model;
pub mod ops;
pub mod paths;
pub mod registry;
pub mod render;
pub mod view;
pub mod watch;

pub use changelog::{ChangeLog, ChangeLogError, Cursors, Since};
pub use clock::{Clock, FakeClock, SystemClock};
pub use diff::{diff, merge_external};
pub use format::{
    parse, splice, template, validate_command_text, CommandTextError, Malformed, MalformedReason,
    ParsedBoard, Unwritable,
};
pub use model::{
    Author, Board, Change, ChangeKind, Counts, Env, Item, Kind, Link, LinkKind, LogLine, Section,
    Stamp, Status,
};
pub use ops::{apply_batch, apply_to_file, Applied, Op, OpError, Upsert, WriteError};
pub use render::{compact_full, delta_entries, quote_untrusted};
pub use view::{TrackerBoardView, ViewFacts};
pub use registry::{
    CallerFacts, OpenArgs, OpenOutcome, ReadOutcome, RegistryParts, TrackerError, TrackerRegistry,
    TrackerSummary, WriteOutcome,
};
