//! The curated view vocabulary and its deterministic placement engine
//! (W5 — curated-agent-views).
//!
//! This module is the whole answer to the PRD's central question: *given that
//! an agent said "show this", where does it land?* It answers it with a pure
//! function over data — no `McpSharedState`, no sockets, no clock, no
//! randomness, and above all no model inference:
//!
//! ```text
//! place(&ViewPlacementConfig, &ViewState, &ShowRequest) -> Result<Placement, PlacementError>
//! ```
//!
//! Keeping the *decision* separate from the *mutation* is what makes the PRD's
//! determinism criterion — "the same sequence of shows from the same starting
//! state produces the same tab set, order and frontmost tab every time" — a
//! test rather than an aspiration. [`placement`] holds the decision;
//! `tools::show` holds the mutation.
//!
//! ## No new persisted state (B10)
//!
//! [`ViewState`] is *derived*, never stored. W2 gave every pane a persisted
//! `(source, params)` binding, and for the curated sources that pair **is**
//! `(view type, identity)` — so the live view set survives a daemon restart
//! for free, reconstructed from the tree and the bindings the registry already
//! keeps. The two things that genuinely aren't derivable are handled as
//! follows:
//!
//! - **LRU focus order** is in-memory only, seeded from left-to-right tab
//!   order. A restart therefore evicts in tab order rather than true recency.
//!   That is a bounded, stated imprecision, and much cheaper than persisting a
//!   third thing about panes.
//! - **Pinning** is fully derivable: the `pr_conversation` and `pr_diff` tabs
//!   of the PR currently under review are pinned, and nothing else ever is.

pub mod config;
pub mod derive;
pub mod placement;
pub mod tree;

use std::collections::BTreeSet;

pub use config::ViewPlacementConfig;
pub use placement::{place, Placement, RegionCreation};

// ── the closed vocabulary ────────────────────────────────────────────────────

/// The v1 view vocabulary. Closed by construction: an agent cannot invent a
/// view any more than it can invent a layout.
///
/// `activity` is deliberately **not** a variant. It is in the PRD's vocabulary
/// but is populated only by the ambient path — "an agent cannot push into it,
/// which is what keeps the ambient stream trustworthy as a record of what
/// actually happened" — so it is refused by name in [`ViewType::parse`] with
/// its own error rather than falling out as merely unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ViewType {
    ReviewQueue,
    PrConversation,
    PrDiff,
    File,
    Ticket,
}

/// The view type name reserved for the ambient path (W7).
const ACTIVITY: &str = "activity";

impl ViewType {
    /// Every type an agent may name, in vocabulary order. Used by the refusal
    /// messages, which the PRD requires to *name the valid types* rather than
    /// just say "no".
    pub const ALL: [ViewType; 5] = [
        ViewType::ReviewQueue,
        ViewType::PrConversation,
        ViewType::PrDiff,
        ViewType::File,
        ViewType::Ticket,
    ];

    /// The wire name, and the key `views.yaml` uses.
    pub fn as_str(self) -> &'static str {
        match self {
            ViewType::ReviewQueue => "review_queue",
            ViewType::PrConversation => "pr_conversation",
            ViewType::PrDiff => "pr_diff",
            ViewType::File => "file",
            ViewType::Ticket => "ticket",
        }
    }

    /// Parse a caller-supplied `type`.
    ///
    /// Two distinct refusals, because they mean different things to the agent
    /// that hit them: `activity` is a real view it may *read* but never
    /// *write*, and anything else is simply not a view at all.
    pub fn parse(s: &str) -> Result<Self, PlacementError> {
        match s {
            "review_queue" => Ok(ViewType::ReviewQueue),
            "pr_conversation" => Ok(ViewType::PrConversation),
            "pr_diff" => Ok(ViewType::PrDiff),
            "file" => Ok(ViewType::File),
            "ticket" => Ok(ViewType::Ticket),
            ACTIVITY => Err(PlacementError::ActivityNotPushable),
            other => Err(PlacementError::UnknownViewType(other.to_string())),
        }
    }

    /// The comma-separated vocabulary, for a refusal's `detail`.
    pub fn vocabulary() -> String {
        ViewType::ALL
            .iter()
            .map(|t| t.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// What makes two shows "the same view" — the type's key, per the PRD's
/// uniform addressing contract.
///
/// Deliberately excludes anchor, emphasis and reason: showing the same file at
/// a different line is the *same view*, re-anchored. That is R2, and it is the
/// difference between "one file, one tab" and a tab per line number Perri
/// happened to mention.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ViewIdentity {
    /// `review_queue` — there is one queue.
    Singleton,
    /// `pr_conversation` / `pr_diff`.
    Pr { repo: String, number: u64 },
    /// `file`. `revision` is the *requested* revision, not the resolved one —
    /// a caller cannot address a resolved SHA, so "the same file, resolve it
    /// for me" stays one identity across the review even as the head moves.
    File {
        path: String,
        revision: Option<String>,
    },
    /// `ticket`.
    Ticket { provider: String, key: String },
}

impl ViewIdentity {
    /// A canonical string key, used as R3's within-a-type tie-break so tab
    /// position is a function of content rather than of arrival order.
    pub fn key(&self) -> String {
        match self {
            ViewIdentity::Singleton => String::new(),
            ViewIdentity::Pr { repo, number } => format!("{repo}#{number}"),
            ViewIdentity::File { path, revision } => match revision {
                Some(r) => format!("{path}@{r}"),
                None => path.clone(),
            },
            ViewIdentity::Ticket { provider, key } => format!("{provider}:{key}"),
        }
    }

    /// The `(repo, number)` this identity names, when it names a PR at all.
    /// R8 keys on this: a show carrying a *different* PR identity resets the
    /// detail region's review context.
    pub fn pr(&self) -> Option<(&str, u64)> {
        match self {
            ViewIdentity::Pr { repo, number } => Some((repo.as_str(), *number)),
            _ => None,
        }
    }
}

/// One view an agent asked for: what, and which one. Anchor, emphasis and
/// reason are deliberately absent — they are not placement inputs, and letting
/// them into this struct would make it possible to write a placement rule that
/// depends on them.
#[derive(Debug, Clone, PartialEq)]
pub struct ShowRequest {
    pub view_type: ViewType,
    pub identity: ViewIdentity,
}

impl ShowRequest {
    pub fn new(view_type: ViewType, identity: ViewIdentity) -> Self {
        Self {
            view_type,
            identity,
        }
    }
}

/// The tab caption a view gets. Pure and total, so the applier and the tool
/// result can never label the same tab two different ways.
pub fn label_for(view_type: ViewType, identity: &ViewIdentity) -> String {
    match (view_type, identity) {
        (ViewType::ReviewQueue, _) => "Queue".to_string(),
        (ViewType::PrConversation, _) => "Conversation".to_string(),
        (ViewType::PrDiff, _) => "Diff".to_string(),
        (ViewType::Ticket, ViewIdentity::Ticket { key, .. }) => key.clone(),
        (ViewType::Ticket, _) => "Ticket".to_string(),
        (ViewType::File, ViewIdentity::File { path, .. }) => path
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or(path)
            .to_string(),
        (ViewType::File, _) => "File".to_string(),
    }
}

// ── the derived state the engine reasons over ────────────────────────────────

/// One live view in a region.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveView {
    pub pane_id: String,
    /// `None` for a pane the curated layer doesn't recognise — an
    /// agent-authored tab from the raw tools, or a binding to a source outside
    /// the vocabulary. Such a tab is never *reused* (it has no identity to
    /// match) but is still counted, ordered and evictable, because silently
    /// dropping it from the engine's view of the region would let the applier
    /// rebuild the tabs node without it.
    pub view: Option<LiveViewKind>,
    /// R4: pinned tabs are never evicted. Derived, never stored — see the
    /// module doc.
    pub pinned: bool,
    /// Higher is more recently focused. Seeded from left-to-right tab order on
    /// daemon start.
    pub lru_rank: u64,
}

/// A live view's `(type, identity)` pair.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveViewKind {
    pub view_type: ViewType,
    pub identity: ViewIdentity,
}

/// One region's current contents.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RegionState {
    /// Left-to-right tab order. A non-tabbed region holds at most one.
    pub tabs: Vec<LiveView>,
    /// Index into `tabs` of the frontmost one. `None` for an empty region.
    pub active: Option<usize>,
}

/// Everything the engine knows about a focus, derived from the pane registry.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ViewState {
    /// Region name → contents. A region *absent* from this map does not exist
    /// in the focus's tree yet and has to be created before anything can land
    /// in it (D5).
    pub regions: std::collections::BTreeMap<String, RegionState>,
    /// Every pane id live anywhere in the focus, including `repl` and panes
    /// outside any curated region. New tab ids are the smallest unused
    /// `<prefix>.<n>` against this set, which is what keeps id assignment a
    /// pure function of state.
    pub taken_pane_ids: BTreeSet<String>,
}

impl ViewState {
    /// The region's contents, or an empty region when it doesn't exist yet.
    pub fn region(&self, name: &str) -> Option<&RegionState> {
        self.regions.get(name)
    }
}

// ── failure modes ────────────────────────────────────────────────────────────

/// Stable, machine-readable placement failures. Mirrors
/// [`crate::mcp::tools::apply_layout::ApplyLayoutError`]'s style: the tool
/// layer surfaces these as `{ "error": "<code>", "detail": "…" }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlacementError {
    /// A `type` outside the closed vocabulary. Never a fallback to a text
    /// pane — the PRD is explicit that an unknown view type is a refusal.
    UnknownViewType(String),
    /// `type: "activity"`. A real view, but one only the ambient path writes.
    ActivityNotPushable,
    /// The `target` object was absent, or the wrong shape for this type.
    InvalidTarget(String),
    /// The `anchor` was the wrong kind for this view type.
    InvalidAnchor(String),
    /// An `emphasis` entry was the wrong kind for this view type.
    InvalidEmphasis(String),
    /// A view's home region isn't declared in `views.yaml`.
    UnknownRegion(String),
    /// A non-tabbed region already holds a different view (R1: the queue
    /// region never becomes tabbed and never hosts a non-queue view).
    RegionNotTabbed(String),
    /// The region doesn't exist and none of its `create` candidates named a
    /// pane that does. Refused rather than landed somewhere arbitrary.
    RegionNotCreatable(String),
    /// Creating the region would need a pane id something else already holds.
    PaneIdTaken(String),
    /// `views.yaml` (compiled-in or override) is malformed.
    InvalidConfig(String),
}

impl PlacementError {
    /// The stable snake_case code for the wire.
    pub fn code(&self) -> &'static str {
        match self {
            PlacementError::UnknownViewType(_) => "unknown_view_type",
            PlacementError::ActivityNotPushable => "activity_not_pushable",
            PlacementError::InvalidTarget(_) => "invalid_target",
            PlacementError::InvalidAnchor(_) => "invalid_anchor",
            PlacementError::InvalidEmphasis(_) => "invalid_emphasis",
            PlacementError::UnknownRegion(_) => "unknown_region",
            PlacementError::RegionNotTabbed(_) => "region_not_tabbed",
            PlacementError::RegionNotCreatable(_) => "region_not_creatable",
            PlacementError::PaneIdTaken(_) => "pane_id_taken",
            PlacementError::InvalidConfig(_) => "invalid_views_config",
        }
    }

    /// A human-readable, actionable detail beyond [`PlacementError::code`].
    /// Always populated: every refusal here is the agent naming something that
    /// doesn't resolve, and a bare code leaves it guessing which part.
    pub fn detail(&self) -> String {
        match self {
            PlacementError::UnknownViewType(t) => format!(
                "`{t}` is not a view type; valid types are: {}",
                ViewType::vocabulary()
            ),
            PlacementError::ActivityNotPushable => format!(
                "`activity` is populated only by the ambient activity path and cannot be shown \
                 deliberately; valid types are: {}",
                ViewType::vocabulary()
            ),
            PlacementError::InvalidTarget(d) => d.clone(),
            PlacementError::InvalidAnchor(d) => d.clone(),
            PlacementError::InvalidEmphasis(d) => d.clone(),
            PlacementError::UnknownRegion(r) => {
                format!("views.yaml declares no region named `{r}`")
            }
            PlacementError::RegionNotTabbed(r) => {
                format!("region `{r}` is not tabbed and already holds a different view")
            }
            PlacementError::RegionNotCreatable(r) => format!(
                "region `{r}` does not exist and none of its create rules names a live pane"
            ),
            PlacementError::PaneIdTaken(p) => {
                format!("pane id `{p}` is already in use in this focus")
            }
            PlacementError::InvalidConfig(d) => format!("views.yaml is invalid: {d}"),
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. the closed vocabulary ──────────────────────────────────────────────

    #[test]
    fn every_v1_view_type_round_trips_through_its_wire_name() {
        for t in ViewType::ALL {
            assert_eq!(ViewType::parse(t.as_str()).unwrap(), t);
        }
    }

    #[test]
    fn activity_is_refused_with_its_own_error_not_as_an_unknown_type() {
        assert_eq!(
            ViewType::parse("activity").unwrap_err(),
            PlacementError::ActivityNotPushable
        );
        assert_eq!(
            ViewType::parse("activity").unwrap_err().code(),
            "activity_not_pushable"
        );
    }

    #[test]
    fn a_type_outside_the_vocabulary_is_refused_with_an_error_naming_the_valid_types() {
        let err = ViewType::parse("terminal").unwrap_err();
        assert_eq!(err.code(), "unknown_view_type");
        for t in ViewType::ALL {
            assert!(
                err.detail().contains(t.as_str()),
                "detail must name `{}`: {}",
                t.as_str(),
                err.detail()
            );
        }
    }

    #[test]
    fn the_activity_refusal_also_names_the_valid_types() {
        let detail = PlacementError::ActivityNotPushable.detail();
        for t in ViewType::ALL {
            assert!(detail.contains(t.as_str()), "{detail}");
        }
    }

    // ── 2. identity ───────────────────────────────────────────────────────────

    #[test]
    fn a_file_identity_ignores_anchor_and_emphasis_by_construction() {
        // There is nowhere to *put* an anchor on a `ViewIdentity`, which is
        // the point: R2's "one file, one tab" can't be broken by a caller.
        let a = ViewIdentity::File {
            path: "src/a.rs".into(),
            revision: None,
        };
        let b = ViewIdentity::File {
            path: "src/a.rs".into(),
            revision: None,
        };
        assert_eq!(a, b);
        assert_eq!(a.key(), b.key());
    }

    #[test]
    fn a_file_identity_distinguishes_two_revisions_of_the_same_path() {
        let working = ViewIdentity::File {
            path: "src/a.rs".into(),
            revision: None,
        };
        let pinned = ViewIdentity::File {
            path: "src/a.rs".into(),
            revision: Some("deadbeef".into()),
        };
        assert_ne!(working, pinned);
        assert_ne!(working.key(), pinned.key());
    }

    #[test]
    fn only_a_pr_identity_reports_a_pr() {
        assert_eq!(
            ViewIdentity::Pr {
                repo: "o/r".into(),
                number: 94
            }
            .pr(),
            Some(("o/r", 94))
        );
        assert_eq!(ViewIdentity::Singleton.pr(), None);
        assert_eq!(
            ViewIdentity::Ticket {
                provider: "jira".into(),
                key: "CORE-1".into()
            }
            .pr(),
            None
        );
    }

    // ── 3. labels ─────────────────────────────────────────────────────────────

    #[test]
    fn a_file_view_is_labelled_by_its_basename() {
        assert_eq!(
            label_for(
                ViewType::File,
                &ViewIdentity::File {
                    path: "src/ipc/session_manager.rs".into(),
                    revision: None
                }
            ),
            "session_manager.rs"
        );
    }

    #[test]
    fn a_ticket_view_is_labelled_by_its_key() {
        assert_eq!(
            label_for(
                ViewType::Ticket,
                &ViewIdentity::Ticket {
                    provider: "jira".into(),
                    key: "CORE-2841".into()
                }
            ),
            "CORE-2841"
        );
    }

    #[test]
    fn the_pr_views_and_the_queue_have_fixed_labels() {
        assert_eq!(
            label_for(
                ViewType::PrConversation,
                &ViewIdentity::Pr {
                    repo: "o/r".into(),
                    number: 1
                }
            ),
            "Conversation"
        );
        assert_eq!(
            label_for(
                ViewType::PrDiff,
                &ViewIdentity::Pr {
                    repo: "o/r".into(),
                    number: 1
                }
            ),
            "Diff"
        );
        assert_eq!(
            label_for(ViewType::ReviewQueue, &ViewIdentity::Singleton),
            "Queue"
        );
    }

    // ── 4. error codes are all distinct ───────────────────────────────────────

    #[test]
    fn every_placement_error_has_its_own_code() {
        let all = [
            PlacementError::UnknownViewType("x".into()),
            PlacementError::ActivityNotPushable,
            PlacementError::InvalidTarget("x".into()),
            PlacementError::InvalidAnchor("x".into()),
            PlacementError::InvalidEmphasis("x".into()),
            PlacementError::UnknownRegion("x".into()),
            PlacementError::RegionNotTabbed("x".into()),
            PlacementError::RegionNotCreatable("x".into()),
            PlacementError::PaneIdTaken("x".into()),
            PlacementError::InvalidConfig("x".into()),
        ];
        let mut codes: Vec<&str> = all.iter().map(|e| e.code()).collect();
        codes.sort_unstable();
        let n = codes.len();
        codes.dedup();
        assert_eq!(codes.len(), n, "placement error codes must be distinct");
        for e in &all {
            assert!(!e.detail().is_empty());
        }
    }
}
