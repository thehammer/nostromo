//! Per-focus agent-authored pane-tree registry (Phase 1: agent-driven-pane-layout).
//!
//! The daemon is the single source of truth for every focus's pane structure.
//! A focus is keyed by its session `tag`; its layout is a [`PaneTree`] whose
//! leaves are panes. On a fresh (non-resume) spawn the tree is a single REPL
//! leaf; an agent grows it on its first turn via the `create_pane` /
//! `set_pane_layout` MCP tools, and tears it back down with `reset_panes`.
//!
//! This registry holds only **structure** (the tree) plus, since the
//! live-pane-sources feature, a **binding** table recording which server-side
//! `source` (if any) feeds each pane — three short strings per pane, not
//! content. Pane *content* itself travels as a separate `ServerMsg::PaneContent`
//! broadcast and is deliberately not stored here — keeping content out of the
//! structural model is what lets an operator's manual drag-resize survive a
//! content refresh (only a structural mutation re-declares geometry). A binding
//! is structural metadata in exactly that sense: it says which pane a source
//! feeds, never what the source last produced.
//!
//! ## Invariants (upheld by every mutation)
//!
//! 1. A focus's tree always contains **exactly one** `"repl"` leaf.
//! 2. Pane ids are **unique** within a focus.
//! 3. Every `Split` is well-formed: `children.len() == ratios.len()`,
//!    `children.len() >= 2`.
//! 4. A `reset` followed by the identical create sequence yields a
//!    **byte-identical** tree (deterministic 0.5/0.5 splits) — the idempotent
//!    rebuild the PRD requires.
//! 5. A pane is bound to **at most one** source at a time — re-binding replaces
//!    rather than accumulates — and every binding's pane id is always a live
//!    leaf of that tag's tree; any mutation that removes a pane (or the whole
//!    tag) drops its binding too. `"repl"` can never be bound.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::debug;

use super::protocol::{PaneTree, ServerMsg, SplitDirection};

/// The reserved pane id that is always present in a focus.
pub const REPL_PANE_ID: &str = "repl";

/// Supplies current pane content for attach replay (D8) — implemented over a
/// cloned `McpSharedState` in `crate::mcp::pane_sources`, and declared here
/// (rather than in `mcp`) so `ipc` doesn't have to depend on `mcp` to thread
/// this through `SessionManager`/`server.rs`.
pub trait PaneContentProvider: Send + Sync {
    /// Current content for every live binding, for replay to a new client.
    fn bound_pane_contents(&self) -> Vec<ServerMsg>;
}

// ── errors ──────────────────────────────────────────────────────────────────

/// Stable, machine-readable failure modes for pane operations.
///
/// [`PaneError::code`] returns the snake_case string the MCP tool layer surfaces
/// to agents (the stable error contract from `docs/mcp/panes.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneError {
    /// The targeted focus/view has no registered tree.
    UnknownView,
    /// `relative_to` (or the addressed pane) does not exist in the focus.
    UnknownPane,
    /// A pane with the requested `pane_id` already exists in the focus.
    DuplicatePane,
    /// The `position` value was not one of the four recognised splits.
    InvalidPosition,
    /// A supplied layout payload was structurally invalid (bad tree, missing or
    /// duplicated repl, mismatched ratios, …).
    InvalidLayout,
}

impl PaneError {
    /// The stable snake_case code for the wire.
    pub fn code(self) -> &'static str {
        match self {
            PaneError::UnknownView => "unknown_view",
            PaneError::UnknownPane => "unknown_pane",
            PaneError::DuplicatePane => "duplicate_pane",
            PaneError::InvalidPosition => "invalid_position",
            PaneError::InvalidLayout => "invalid_layout",
        }
    }
}

// ── split position ──────────────────────────────────────────────────────────

/// Where a new pane lands relative to the leaf it splits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitPosition {
    Left,
    Right,
    Above,
    Below,
}

impl SplitPosition {
    /// Parse the `position` enum string from the `create_pane` tool schema.
    pub fn parse(s: &str) -> Result<Self, PaneError> {
        match s {
            "split_left" => Ok(SplitPosition::Left),
            "split_right" => Ok(SplitPosition::Right),
            "split_above" => Ok(SplitPosition::Above),
            "split_below" => Ok(SplitPosition::Below),
            _ => Err(PaneError::InvalidPosition),
        }
    }

    fn direction(self) -> SplitDirection {
        match self {
            SplitPosition::Left | SplitPosition::Right => SplitDirection::Horizontal,
            SplitPosition::Above | SplitPosition::Below => SplitDirection::Vertical,
        }
    }

    /// True when the new pane is placed *before* the existing leaf in child order.
    fn new_pane_first(self) -> bool {
        matches!(self, SplitPosition::Left | SplitPosition::Above)
    }
}

// ── registry ────────────────────────────────────────────────────────────────

/// Daemon-side registry of per-focus pane trees, persisted to disk so a focus's
/// assembled layout survives a daemon restart (and is replayed to reconnecting
/// clients).
pub struct PaneRegistry {
    trees: HashMap<String, PaneTree>,
    /// tag → pane_id → source binding. Persisted (D3).
    bindings: HashMap<String, HashMap<String, SourceBinding>>,
    /// tag → pane_ids the daemon has broadcast any content to since this
    /// process started. NOT persisted — exists only to suppress a `Loading`
    /// broadcast over a pane that already has content (D5).
    painted: HashMap<String, HashSet<String>>,
    /// tag → curated-view focus order, least-recently-focused first (W5 —
    /// curated-agent-views). Read by the placement engine's eviction rule
    /// (R4) and written by every `nostromo.show`.
    ///
    /// **Deliberately not persisted**, and living here for exactly the reason
    /// `painted` does: it is process-lifetime state *about* panes rather than
    /// part of what a pane *is*. The consequence is stated rather than hidden
    /// — a restarted daemon evicts in left-to-right tab order rather than true
    /// recency, because that is what the order re-seeds to. Persisting it
    /// would be a third fact about every pane bought for a marginal
    /// improvement to one rule.
    view_focus_lru: HashMap<String, Vec<String>>,
    store_path: Option<PathBuf>,
}

impl Default for PaneRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl PaneRegistry {
    /// Construct with the default on-disk store and load any persisted trees.
    pub fn new() -> Self {
        Self::with_store_path(default_store_path())
    }

    /// Construct backed by a specific store path (used by tests).
    pub fn with_store_path(store_path: PathBuf) -> Self {
        let (trees, bindings) = load_store(&store_path);
        Self {
            trees,
            bindings,
            painted: HashMap::new(),
            view_focus_lru: HashMap::new(),
            store_path: Some(store_path),
        }
    }

    /// Construct an in-memory registry with no persistence (used by tests that
    /// don't care about disk round-trips).
    pub fn in_memory() -> Self {
        Self {
            trees: HashMap::new(),
            bindings: HashMap::new(),
            painted: HashMap::new(),
            view_focus_lru: HashMap::new(),
            store_path: None,
        }
    }

    // ── reads ────────────────────────────────────────────────────────────────

    /// The tree for `tag`, if the focus is registered.
    pub fn get(&self, tag: &str) -> Option<&PaneTree> {
        self.trees.get(tag)
    }

    /// Snapshot of every registered focus's tree, used to replay layout state
    /// to a newly connected or reconnecting client. `focused_pane` is `None`
    /// because the registry does not persist focus state — the agent's next
    /// `set_pane_focus` call will update it.
    pub fn all_layouts(&self) -> Vec<(String, PaneTree, Option<String>)> {
        self.trees
            .iter()
            .map(|(tag, tree)| (tag.clone(), tree.clone(), None))
            .collect()
    }

    /// Whether `tag` has a registered tree.
    pub fn contains(&self, tag: &str) -> bool {
        self.trees.contains_key(tag)
    }

    /// Pane ids for `tag` in tree order, or an empty vec when unregistered.
    pub fn pane_ids(&self, tag: &str) -> Vec<String> {
        self.trees
            .get(tag)
            .map(|t| t.pane_ids())
            .unwrap_or_default()
    }

    // ── source bindings (D1) ────────────────────────────────────────────────────

    /// Bind `pane_id` in `tag` to `source`, replacing any existing binding for
    /// that pane. Silently refused (logged at `debug!`, no error) when
    /// `pane_id` is `"repl"` or is not currently a leaf of `tag`'s tree — this
    /// is the structural guard that makes "no automatic content for a pane
    /// that isn't in the tree" true by construction rather than by convention.
    pub fn bind_source(&mut self, tag: &str, pane_id: &str, source: &str) {
        self.bind_source_with_params(tag, pane_id, source, None);
    }

    /// [`bind_source`](Self::bind_source) plus the per-pane `params` the
    /// fetcher is invoked with (W2 — curated-agent-views).
    ///
    /// Params are what makes a source say *which* thing: `nostromo.get_file`
    /// is one source, but a pane bound to it also has to record which file it
    /// shows, or a daemon restart repaints it as some other file. They are
    /// persisted alongside the source name for exactly that reason.
    pub fn bind_source_with_params(
        &mut self,
        tag: &str,
        pane_id: &str,
        source: &str,
        params: Option<serde_json::Value>,
    ) {
        if pane_id == REPL_PANE_ID {
            debug!(tag, pane_id, "bind_source: refusing to bind the repl pane");
            return;
        }
        if !self.pane_ids(tag).iter().any(|id| id == pane_id) {
            debug!(
                tag,
                pane_id, "bind_source: pane is not a leaf of this tag's tree — refusing"
            );
            return;
        }
        self.bindings.entry(tag.to_string()).or_default().insert(
            pane_id.to_string(),
            SourceBinding {
                source: source.to_string(),
                params,
            },
        );
        self.persist();
    }

    /// Remove `pane_id`'s binding within `tag`, if any. A no-op (not an error)
    /// when there was no binding.
    pub fn unbind_source(&mut self, tag: &str, pane_id: &str) {
        let mut removed = false;
        if let Some(tag_bindings) = self.bindings.get_mut(tag) {
            removed = tag_bindings.remove(pane_id).is_some();
            if tag_bindings.is_empty() {
                self.bindings.remove(tag);
            }
        }
        if removed {
            self.persist();
        }
    }

    /// The source bound to `pane_id` within `tag`, if any.
    pub fn source_for(&self, tag: &str, pane_id: &str) -> Option<&str> {
        self.binding_for(tag, pane_id).map(|b| b.source.as_str())
    }

    /// The full binding (source + params) for `pane_id` within `tag`, if any.
    pub fn binding_for(&self, tag: &str, pane_id: &str) -> Option<&SourceBinding> {
        self.bindings.get(tag).and_then(|m| m.get(pane_id))
    }

    /// Every live binding as `(tag, pane_id, binding)`, in a stable sorted
    /// order. Sorted on `(tag, pane_id)` alone — a binding's `params` is
    /// arbitrary JSON with no total order, and `(tag, pane_id)` is already
    /// unique, so nothing is lost.
    pub fn all_bindings(&self) -> Vec<(String, String, SourceBinding)> {
        let mut out: Vec<(String, String, SourceBinding)> = self
            .bindings
            .iter()
            .flat_map(|(tag, panes)| {
                panes
                    .iter()
                    .map(move |(pane_id, binding)| (tag.clone(), pane_id.clone(), binding.clone()))
            })
            .collect();
        out.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
        out
    }

    /// Record that the daemon has broadcast content for `(tag, pane_id)` since
    /// this process started. Not persisted.
    pub fn mark_painted(&mut self, tag: &str, pane_id: &str) {
        self.painted
            .entry(tag.to_string())
            .or_default()
            .insert(pane_id.to_string());
    }

    /// Whether the daemon has broadcast content for `(tag, pane_id)` since
    /// this process started.
    pub fn has_been_painted(&self, tag: &str, pane_id: &str) -> bool {
        self.painted
            .get(tag)
            .map(|s| s.contains(pane_id))
            .unwrap_or(false)
    }

    // ── curated-view focus order (W5) ───────────────────────────────────────────

    /// `tag`'s curated-view focus order, least-recently-focused first, after
    /// re-seeding it against `live` (see [`Self::view_focus_lru`]'s doc).
    ///
    /// Re-seeding on read rather than on write is what makes a daemon restart
    /// mid-review degrade to tab order instead of to "nothing has ever been
    /// focused": the first show after a restart finds an empty order and fills
    /// it from the tabs that are actually there.
    pub fn view_focus_order(&mut self, tag: &str, live: &[String]) -> Vec<String> {
        let order = self.view_focus_lru.entry(tag.to_string()).or_default();
        crate::mcp::views::derive::seed(order, live);
        order.clone()
    }

    /// Record `pane_id` as `tag`'s most recently focused curated view,
    /// dropping any pane no longer in `live`.
    pub fn touch_view_focus(&mut self, tag: &str, live: &[String], pane_id: &str) {
        let order = self.view_focus_lru.entry(tag.to_string()).or_default();
        crate::mcp::views::derive::touch(order, live, pane_id);
    }

    // ── mutations ──────────────────────────────────────────────────────────────

    /// Initialise (or re-initialise) `tag` to a single REPL leaf and persist.
    /// Called on a fresh, non-resume session spawn.
    pub fn init_focus(&mut self, tag: &str) -> PaneTree {
        let tree = PaneTree::repl_leaf();
        self.trees.insert(tag.to_string(), tree.clone());
        self.prune_to_tree(tag);
        self.persist();
        tree
    }

    /// Ensure `tag` has a tree (a REPL leaf if absent) and return a clone.
    /// Used for the caller's own focus, which always exists once spawned but may
    /// not have been initialised if the session pre-dates this feature.
    pub fn get_or_init(&mut self, tag: &str) -> PaneTree {
        if !self.trees.contains_key(tag) {
            return self.init_focus(tag);
        }
        self.trees.get(tag).cloned().unwrap()
    }

    /// `create_pane`: split the `relative_to` leaf, inserting a new `pane_id` on
    /// the side implied by `position`. Returns the new tree on success.
    ///
    /// Errors: [`PaneError::UnknownView`] (tag absent),
    /// [`PaneError::DuplicatePane`] (`pane_id` already present),
    /// [`PaneError::UnknownPane`] (`relative_to` absent).
    pub fn create_pane(
        &mut self,
        tag: &str,
        pane_id: &str,
        position: SplitPosition,
        relative_to: &str,
    ) -> Result<PaneTree, PaneError> {
        let tree = self.trees.get_mut(tag).ok_or(PaneError::UnknownView)?;

        // Reject duplicate ids before mutating anything.
        if tree.pane_ids().iter().any(|id| id == pane_id) {
            return Err(PaneError::DuplicatePane);
        }

        let new_leaf = PaneTree::Leaf {
            pane_id: pane_id.to_string(),
        };
        let replaced = split_leaf(tree, relative_to, position, new_leaf);
        if !replaced {
            return Err(PaneError::UnknownPane);
        }
        let result = tree.clone();
        // create_pane only ever adds panes, so this can't drop a binding — but
        // calling it keeps every tree-mutating path going through the same
        // pruning choke point (D2).
        self.prune_to_tree(tag);
        self.persist();
        Ok(result)
    }

    /// `reset_panes`: collapse `tag` back to a single REPL leaf. Returns the
    /// new tree. Errors with [`PaneError::UnknownView`] when the tag is absent.
    pub fn reset(&mut self, tag: &str) -> Result<PaneTree, PaneError> {
        if !self.trees.contains_key(tag) {
            return Err(PaneError::UnknownView);
        }
        let tree = PaneTree::repl_leaf();
        self.trees.insert(tag.to_string(), tree.clone());
        self.prune_to_tree(tag);
        self.persist();
        Ok(tree)
    }

    /// `set_pane_layout`: re-declare the layout for `tag`.
    ///
    /// Accepts two payload shapes (B3):
    /// - a full pane **tree** (an object with `"kind"`, or wrapped as
    ///   `{ "tree": <PaneTree> }`) — replaces the focus's tree wholesale after
    ///   validating the structural invariants; and
    /// - a flat **ratio map** `{ "<pane_id>": <ratio>, … }` (legacy sugar) —
    ///   updates the ratios of any split whose direct leaf children are named in
    ///   the map, leaving structure untouched.
    pub fn set_layout(&mut self, tag: &str, payload: &Value) -> Result<PaneTree, PaneError> {
        if !self.trees.contains_key(tag) {
            return Err(PaneError::UnknownView);
        }

        // Shape 1: a full tree (possibly wrapped in { "tree": ... }).
        let tree_value = payload.get("tree").unwrap_or(payload);
        if tree_value.get("kind").is_some() {
            let new_tree: PaneTree =
                serde_json::from_value(tree_value.clone()).map_err(|_| PaneError::InvalidLayout)?;
            validate_tree(&new_tree)?;
            self.trees.insert(tag.to_string(), new_tree.clone());
            self.prune_to_tree(tag);
            self.persist();
            return Ok(new_tree);
        }

        // Shape 2: a flat ratio map.
        let map = payload.as_object().ok_or(PaneError::InvalidLayout)?;
        let ratios: HashMap<String, f32> = map
            .iter()
            .filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f as f32)))
            .collect();
        if ratios.is_empty() {
            return Err(PaneError::InvalidLayout);
        }
        let tree = self.trees.get_mut(tag).unwrap();
        apply_ratio_map(tree, &ratios);
        let result = tree.clone();
        // A ratio map never touches structure, so this is a no-op — but going
        // through the same choke point as the full-tree shape means a future
        // change to pruning logic can't be applied to only one shape by accident.
        self.prune_to_tree(tag);
        self.persist();
        Ok(result)
    }

    // ── binding hygiene (D2) ────────────────────────────────────────────────────

    /// Drop any binding for `tag` whose pane id is no longer a leaf of `tag`'s
    /// current tree, and drop `tag`'s whole binding entry if the tag itself has
    /// no tree at all. Called at the end of every mutation that can change
    /// which panes exist for `tag` (`create_pane`, `reset`, `set_layout`).
    fn prune_to_tree(&mut self, tag: &str) {
        let Some(tag_bindings) = self.bindings.get_mut(tag) else {
            return;
        };
        match self.trees.get(tag) {
            Some(tree) => {
                let live: HashSet<String> = tree.pane_ids().into_iter().collect();
                tag_bindings.retain(|pane_id, _| live.contains(pane_id));
                if tag_bindings.is_empty() {
                    self.bindings.remove(tag);
                }
            }
            None => {
                self.bindings.remove(tag);
            }
        }
    }

    // ── persistence ────────────────────────────────────────────────────────────

    fn persist(&self) {
        if let Some(path) = &self.store_path {
            save_store(path, &self.trees, &self.bindings);
        }
    }
}

// ── tree algorithms ──────────────────────────────────────────────────────────

/// Find the leaf named `relative_to` and replace it with a 2-child split of the
/// original leaf and `new_leaf`. Returns true if the leaf was found.
fn split_leaf(
    node: &mut PaneTree,
    relative_to: &str,
    position: SplitPosition,
    new_leaf: PaneTree,
) -> bool {
    match node {
        PaneTree::Leaf { pane_id } => {
            if pane_id != relative_to {
                return false;
            }
            let original = PaneTree::Leaf {
                pane_id: pane_id.clone(),
            };
            let children = if position.new_pane_first() {
                vec![new_leaf, original]
            } else {
                vec![original, new_leaf]
            };
            *node = PaneTree::Split {
                direction: position.direction(),
                children,
                ratios: vec![0.5, 0.5],
            };
            true
        }
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
            for child in children.iter_mut() {
                // Move-out workaround: split_leaf needs `new_leaf` by value, but
                // we may recurse into multiple children. Clone is cheap (a leaf).
                if split_leaf(child, relative_to, position, new_leaf.clone()) {
                    return true;
                }
            }
            false
        }
    }
}

/// Apply a flat `pane_id -> ratio` map to every split whose direct children are
/// all leaves named in the map. Ratios are normalised to sum to 1.0. A `Tabs`
/// node has no ratios of its own — recurse into its children (in case one of
/// them is itself a split), but otherwise leave it untouched.
fn apply_ratio_map(node: &mut PaneTree, ratios: &HashMap<String, f32>) {
    match node {
        PaneTree::Split {
            children,
            ratios: r,
            ..
        } => {
            let direct: Option<Vec<f32>> = children
                .iter()
                .map(|c| match c {
                    PaneTree::Leaf { pane_id } => ratios.get(pane_id).copied(),
                    _ => None,
                })
                .collect();
            if let Some(values) = direct {
                let sum: f32 = values.iter().sum();
                if sum > 0.0 {
                    *r = values.iter().map(|v| v / sum).collect();
                }
            }
            for child in children.iter_mut() {
                apply_ratio_map(child, ratios);
            }
        }
        PaneTree::Tabs { children, .. } => {
            for child in children.iter_mut() {
                apply_ratio_map(child, ratios);
            }
        }
        PaneTree::Leaf { .. } => {}
    }
}

/// Validate the structural invariants of a tree supplied by an agent.
fn validate_tree(tree: &PaneTree) -> Result<(), PaneError> {
    // Exactly one repl leaf.
    let ids = tree.pane_ids();
    let repl_count = ids.iter().filter(|id| *id == REPL_PANE_ID).count();
    if repl_count != 1 {
        return Err(PaneError::InvalidLayout);
    }
    // Unique ids.
    let mut seen = std::collections::HashSet::new();
    for id in &ids {
        if !seen.insert(id) {
            return Err(PaneError::InvalidLayout);
        }
    }
    // Well-formed splits and tabs nodes.
    validate_node(tree)
}

/// Recursively validate every interior node's shape: a `Split` must have
/// `children.len() == ratios.len() >= 2`; a `Tabs` node must have at least one
/// child, `labels.len() == children.len()`, `active < children.len()`, and no
/// `repl` leaf among its (possibly nested) descendants — hiding the REPL
/// behind a tab is never what an agent means, since the REPL is where the
/// operator's hands are.
fn validate_node(node: &PaneTree) -> Result<(), PaneError> {
    match node {
        PaneTree::Leaf { .. } => Ok(()),
        PaneTree::Split {
            children, ratios, ..
        } => {
            if children.len() < 2 || children.len() != ratios.len() {
                return Err(PaneError::InvalidLayout);
            }
            for child in children {
                validate_node(child)?;
            }
            Ok(())
        }
        PaneTree::Tabs {
            children,
            labels,
            active,
            ..
        } => {
            if children.is_empty() || labels.len() != children.len() || *active >= children.len() {
                return Err(PaneError::InvalidLayout);
            }
            if children
                .iter()
                .any(|c| c.pane_ids().iter().any(|id| id == REPL_PANE_ID))
            {
                return Err(PaneError::InvalidLayout);
            }
            for child in children {
                validate_node(child)?;
            }
            Ok(())
        }
    }
}

// ── persistence helpers ──────────────────────────────────────────────────────

/// Default store path: `~/.nostromo/daemon-panes.json`, alongside the session
/// id store.
pub fn default_store_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("daemon-panes.json")
}

/// One pane's persisted data binding: which source feeds it, and with what
/// arguments (W2 — curated-agent-views).
///
/// `params` is the fetcher's own argument object, passed through verbatim —
/// `PaneRegistry` deliberately knows nothing about its shape, because the set
/// of sources is meant to grow without this file changing again. A binding
/// created before params existed round-trips as `params: None`, which is
/// exactly what every parameterless source wants.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceBinding {
    pub source: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub params: Option<serde_json::Value>,
}

impl SourceBinding {
    /// A binding with no params — the shape every pre-W2 binding loads as.
    pub fn new(source: impl Into<String>) -> Self {
        Self {
            source: source.into(),
            params: None,
        }
    }
}

/// On-disk store format (W2 — curated-agent-views). `version` is always 3 for
/// anything this code writes; `bindings` defaults to empty so a V3 file written
/// by an earlier build of this same version still loads.
///
/// The shape here needs no change for `PaneTree::Tabs` (W1) — the tree
/// serialises itself, tabs included. The one consequence: a store persisted by
/// a build with `Tabs` support, containing a focus whose tree has a tabs node,
/// is unreadable by a pre-W1 binary (the `kind: "tabs"` discriminator has no
/// matching variant there). `load_store`'s existing failure path already
/// degrades gracefully in that case — a parse failure falls through the ladder
/// to the V1 bare-`HashMap` shape, which also fails, and the registry simply
/// starts empty for that focus rather than crashing.
#[derive(Serialize, Deserialize)]
struct StoreV3 {
    version: u32,
    trees: HashMap<String, PaneTree>,
    #[serde(default)]
    bindings: HashMap<String, HashMap<String, SourceBinding>>,
}

/// The pre-params store format (D3): bindings were a bare source name.
#[derive(Deserialize)]
struct StoreV2 {
    version: u32,
    trees: HashMap<String, PaneTree>,
    #[serde(default)]
    bindings: HashMap<String, HashMap<String, String>>,
}

/// Load the on-disk store, returning `(trees, bindings)`. Tries the current
/// versioned envelope first, then the pre-params V2 envelope (whose bindings
/// are bare source-name strings and load as `params: None`), then the
/// pre-binding V1 format (a bare `HashMap<String, PaneTree>`) — so an existing
/// `~/.nostromo/daemon-panes.json` from either earlier era loads with trees
/// intact and no data loss.
///
/// Bindings are additionally filtered on load: a binding whose `pane_id` is
/// not in the loaded tree, or whose `source` is not in
/// `apply_layout::known_sources()` (e.g. a source retired in a later daemon
/// version, or a hand-edited state file), is dropped. Both checks are cheap —
/// the source name comes from a closed, small registry — and this is the
/// entirety of the forward/backward-compatibility story for this field.
type LoadedStore = (
    HashMap<String, PaneTree>,
    HashMap<String, HashMap<String, SourceBinding>>,
);

fn load_store(path: &std::path::Path) -> LoadedStore {
    let Ok(bytes) = std::fs::read(path) else {
        return (HashMap::new(), HashMap::new());
    };

    let (trees, bindings) = match serde_json::from_slice::<StoreV3>(&bytes) {
        Ok(store) if store.version == 3 => (store.trees, store.bindings),
        _ => match serde_json::from_slice::<StoreV2>(&bytes) {
            Ok(store) if store.version == 2 => {
                let upgraded = store
                    .bindings
                    .into_iter()
                    .map(|(tag, panes)| {
                        let panes = panes
                            .into_iter()
                            .map(|(pane_id, source)| (pane_id, SourceBinding::new(source)))
                            .collect();
                        (tag, panes)
                    })
                    .collect();
                (store.trees, upgraded)
            }
            _ => {
                // V1 fallback: a bare `HashMap<String, PaneTree>`, no bindings.
                let trees =
                    serde_json::from_slice::<HashMap<String, PaneTree>>(&bytes).unwrap_or_default();
                (trees, HashMap::new())
            }
        },
    };

    let known_sources = crate::mcp::tools::apply_layout::known_sources();
    let filtered: HashMap<String, HashMap<String, SourceBinding>> = bindings
        .into_iter()
        .filter_map(|(tag, panes)| {
            let tree = trees.get(&tag)?;
            let live: HashSet<String> = tree.pane_ids().into_iter().collect();
            let kept: HashMap<String, SourceBinding> = panes
                .into_iter()
                .filter(|(pane_id, binding)| {
                    live.contains(pane_id) && known_sources.contains(&binding.source.as_str())
                })
                .collect();
            if kept.is_empty() {
                None
            } else {
                Some((tag, kept))
            }
        })
        .collect();

    (trees, filtered)
}

/// Serialise store writes so concurrent focus mutations can't clobber the file.
static SAVE_STORE_LOCK: Mutex<()> = Mutex::new(());

fn save_store(
    path: &std::path::Path,
    trees: &HashMap<String, PaneTree>,
    bindings: &HashMap<String, HashMap<String, SourceBinding>>,
) {
    let _guard = SAVE_STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let store = StoreV3 {
        version: 3,
        trees: trees.clone(),
        bindings: bindings.clone(),
    };
    if let Ok(bytes) = serde_json::to_vec_pretty(&store) {
        let _ = std::fs::write(path, bytes);
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::protocol::{PaneTree, SplitDirection};

    // ── 1. Fresh focus has exactly one "repl" pane ───────────────────────────

    #[test]
    fn fresh_focus_has_exactly_repl_pane() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        assert_eq!(reg.pane_ids("mother"), vec!["repl".to_string()]);
    }

    // ── 2a. create_pane Right puts new pane AFTER split leaf ─────────────────

    #[test]
    fn create_pane_right_appends_new_pane_after_existing() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let tree = reg
            .create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["repl", "jobs"]);

        match tree {
            PaneTree::Split {
                direction,
                children,
                ratios,
            } => {
                assert_eq!(direction, SplitDirection::Horizontal);
                assert_eq!(children.len(), 2);
                assert_eq!(ratios, vec![0.5, 0.5]);
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "repl"));
                assert!(matches!(&children[1], PaneTree::Leaf { pane_id } if pane_id == "jobs"));
            }
            _ => panic!("expected Split root after create_pane"),
        }
    }

    // ── 2b. create_pane Left puts new pane BEFORE split leaf ─────────────────

    #[test]
    fn create_pane_left_inserts_new_pane_before_existing() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let tree = reg
            .create_pane("mother", "nav", SplitPosition::Left, "repl")
            .unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["nav", "repl"]);

        match tree {
            PaneTree::Split {
                direction,
                children,
                ratios,
            } => {
                assert_eq!(direction, SplitDirection::Horizontal);
                assert_eq!(ratios, vec![0.5, 0.5]);
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "nav"));
                assert!(matches!(&children[1], PaneTree::Leaf { pane_id } if pane_id == "repl"));
            }
            _ => panic!("expected Split root after create_pane Left"),
        }
    }

    // ── 2c. Above/Below produce Vertical splits ───────────────────────────────

    #[test]
    fn create_pane_below_produces_vertical_split_with_new_pane_after() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let tree = reg
            .create_pane("mother", "log", SplitPosition::Below, "repl")
            .unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["repl", "log"]);

        match tree {
            PaneTree::Split {
                direction, ratios, ..
            } => {
                assert_eq!(direction, SplitDirection::Vertical);
                assert_eq!(ratios, vec![0.5, 0.5]);
            }
            _ => panic!("expected Vertical Split for Below"),
        }
    }

    #[test]
    fn create_pane_above_produces_vertical_split_with_new_pane_before() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let tree = reg
            .create_pane("mother", "header", SplitPosition::Above, "repl")
            .unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["header", "repl"]);

        match tree {
            PaneTree::Split {
                direction,
                ratios,
                children,
            } => {
                assert_eq!(direction, SplitDirection::Vertical);
                assert_eq!(ratios, vec![0.5, 0.5]);
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "header"));
                assert!(matches!(&children[1], PaneTree::Leaf { pane_id } if pane_id == "repl"));
            }
            _ => panic!("expected Vertical Split for Above"),
        }
    }

    // ── 3. Splitting a non-root leaf works correctly ──────────────────────────

    #[test]
    fn create_pane_on_non_root_leaf_splits_that_leaf() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();
        // Now split "jobs" vertically by adding "diff" below it.
        reg.create_pane("mother", "diff", SplitPosition::Below, "jobs")
            .unwrap();

        // Tree order: repl, jobs, diff (repl is first leaf; jobs split with diff below).
        let ids = reg.pane_ids("mother");
        assert_eq!(ids, vec!["repl", "jobs", "diff"]);

        // Inspect structure: root is Horizontal [repl, Split(Vertical [jobs, diff])].
        let tree = reg.get("mother").unwrap();
        match tree {
            PaneTree::Split {
                direction,
                children,
                ..
            } => {
                assert_eq!(*direction, SplitDirection::Horizontal);
                assert_eq!(children.len(), 2);
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "repl"));
                match &children[1] {
                    PaneTree::Split {
                        direction: inner_dir,
                        children: inner_children,
                        ..
                    } => {
                        assert_eq!(*inner_dir, SplitDirection::Vertical);
                        assert_eq!(inner_children.len(), 2);
                        assert!(
                            matches!(&inner_children[0], PaneTree::Leaf { pane_id } if pane_id == "jobs")
                        );
                        assert!(
                            matches!(&inner_children[1], PaneTree::Leaf { pane_id } if pane_id == "diff")
                        );
                    }
                    _ => panic!("expected inner Vertical Split for jobs+diff"),
                }
            }
            _ => panic!("expected Horizontal Split at root"),
        }
    }

    // ── 4. create_pane with nonexistent relative_to → UnknownPane, tree unchanged

    #[test]
    fn create_pane_unknown_relative_to_returns_error_and_leaves_tree_unchanged() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let before = reg.pane_ids("mother").clone();

        let err = reg
            .create_pane("mother", "jobs", SplitPosition::Right, "nonexistent")
            .unwrap_err();

        assert_eq!(err, PaneError::UnknownPane);
        assert_eq!(reg.pane_ids("mother"), before);
    }

    // ── 5. create_pane with duplicate pane_id → DuplicatePane, tree unchanged ─

    #[test]
    fn create_pane_duplicate_id_returns_error_and_leaves_tree_unchanged() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();
        let before = reg.pane_ids("mother").clone();

        let err = reg
            .create_pane("mother", "jobs", SplitPosition::Left, "repl")
            .unwrap_err();

        assert_eq!(err, PaneError::DuplicatePane);
        assert_eq!(reg.pane_ids("mother"), before);
    }

    // ── 5b. Duplicate of "repl" is also rejected ─────────────────────────────

    #[test]
    fn create_pane_duplicate_repl_returns_error() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let err = reg
            .create_pane("mother", "repl", SplitPosition::Right, "repl")
            .unwrap_err();

        assert_eq!(err, PaneError::DuplicatePane);
        assert_eq!(reg.pane_ids("mother"), vec!["repl"]);
    }

    // ── 6. Operations on unregistered tag → UnknownView ──────────────────────

    #[test]
    fn create_pane_on_unregistered_tag_returns_unknown_view() {
        let mut reg = PaneRegistry::in_memory();
        let err = reg
            .create_pane("ghost", "jobs", SplitPosition::Right, "repl")
            .unwrap_err();
        assert_eq!(err, PaneError::UnknownView);
    }

    #[test]
    fn reset_on_unregistered_tag_returns_unknown_view() {
        let mut reg = PaneRegistry::in_memory();
        let err = reg.reset("ghost").unwrap_err();
        assert_eq!(err, PaneError::UnknownView);
    }

    #[test]
    fn set_layout_on_unregistered_tag_returns_unknown_view() {
        let mut reg = PaneRegistry::in_memory();
        let err = reg
            .set_layout("ghost", &serde_json::json!({"repl": 1.0}))
            .unwrap_err();
        assert_eq!(err, PaneError::UnknownView);
    }

    // ── 7. reset collapses to exactly ["repl"] ───────────────────────────────

    #[test]
    fn reset_collapses_multi_pane_layout_to_single_repl() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();
        reg.create_pane("mother", "diff", SplitPosition::Below, "jobs")
            .unwrap();
        reg.create_pane("mother", "log", SplitPosition::Right, "jobs")
            .unwrap();

        // Confirm we have more than one pane before reset.
        assert!(reg.pane_ids("mother").len() > 1);

        let tree = reg.reset("mother").unwrap();
        assert_eq!(reg.pane_ids("mother"), vec!["repl"]);
        assert!(matches!(tree, PaneTree::Leaf { pane_id } if pane_id == "repl"));
    }

    // ── 8. Invariant: exactly one "repl" leaf survives create + reset cycles ──

    #[test]
    fn exactly_one_repl_leaf_always_present() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // After init.
        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);

        // After several creates.
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();
        reg.create_pane("mother", "diff", SplitPosition::Below, "jobs")
            .unwrap();
        reg.create_pane("mother", "log", SplitPosition::Right, "diff")
            .unwrap();

        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);

        // After reset.
        reg.reset("mother").unwrap();
        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);

        // And again after re-building.
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();
        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);
    }

    // ── 9. Idempotent rebuild: reset + identical sequence → byte-identical tree

    #[test]
    fn identical_create_sequence_after_reset_produces_byte_identical_tree() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let build = |reg: &mut PaneRegistry| {
            reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
                .unwrap();
            reg.create_pane("mother", "log", SplitPosition::Below, "jobs")
                .unwrap();
            reg.get("mother").unwrap().clone()
        };

        let tree_a = build(&mut reg);

        reg.reset("mother").unwrap();
        let tree_b = build(&mut reg);

        // Structural equality via PartialEq.
        assert_eq!(tree_a, tree_b);
        // Byte-level equality via JSON serialization (as specified).
        assert_eq!(
            serde_json::to_string(&tree_a).unwrap(),
            serde_json::to_string(&tree_b).unwrap()
        );
    }

    // ── 10. set_layout with ratio map updates ratios, preserves structure ─────

    #[test]
    fn set_layout_ratio_map_updates_ratios_and_preserves_structure() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        let panes_before = reg.pane_ids("mother");
        reg.set_layout("mother", &serde_json::json!({"repl": 0.3, "jobs": 0.7}))
            .unwrap();

        // Structure unchanged.
        assert_eq!(reg.pane_ids("mother"), panes_before);

        // Ratios updated: 0.3/1.0 and 0.7/1.0 (sum is 1.0, already normalised).
        let tree = reg.get("mother").unwrap();
        match tree {
            PaneTree::Split { ratios, .. } => {
                let tolerance = 1e-5_f32;
                assert!(
                    (ratios[0] - 0.3_f32).abs() < tolerance,
                    "ratio[0] = {}",
                    ratios[0]
                );
                assert!(
                    (ratios[1] - 0.7_f32).abs() < tolerance,
                    "ratio[1] = {}",
                    ratios[1]
                );
            }
            _ => panic!("expected Split root"),
        }
    }

    // ── 10b. set_layout ratio map normalises values that don't sum to 1 ───────

    #[test]
    fn set_layout_ratio_map_normalises_non_unit_sum() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        // Supply un-normalised raw values (sum = 4.0).
        reg.set_layout("mother", &serde_json::json!({"repl": 1.0, "jobs": 3.0}))
            .unwrap();

        let tree = reg.get("mother").unwrap();
        match tree {
            PaneTree::Split { ratios, .. } => {
                let tolerance = 1e-5_f32;
                // Normalised: 1/4 = 0.25, 3/4 = 0.75.
                assert!(
                    (ratios[0] - 0.25_f32).abs() < tolerance,
                    "ratio[0] = {}",
                    ratios[0]
                );
                assert!(
                    (ratios[1] - 0.75_f32).abs() < tolerance,
                    "ratio[1] = {}",
                    ratios[1]
                );
            }
            _ => panic!("expected Split root"),
        }
    }

    // ── 11. set_layout with full tree payload replaces tree wholesale ─────────

    #[test]
    fn set_layout_full_tree_payload_replaces_tree_wholesale() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        // A valid replacement tree: repl on the left, new_pane on the right.
        let replacement = PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Leaf {
                    pane_id: "dashboard".into(),
                },
            ],
            ratios: vec![0.4, 0.6],
        };
        let payload = serde_json::to_value(&replacement).unwrap();

        reg.set_layout("mother", &payload).unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["repl", "dashboard"]);
        assert_eq!(reg.get("mother").unwrap(), &replacement);
    }

    // ── 12. set_layout with invalid full tree → InvalidLayout ─────────────────

    #[test]
    fn set_layout_full_tree_without_repl_returns_invalid_layout() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // A tree with zero repl leaves.
        let bad_tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "jobs".into(),
                },
                PaneTree::Leaf {
                    pane_id: "log".into(),
                },
            ],
            ratios: vec![0.5, 0.5],
        };
        let payload = serde_json::to_value(&bad_tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);

        // Tree should be unchanged.
        assert_eq!(reg.pane_ids("mother"), vec!["repl"]);
    }

    #[test]
    fn set_layout_full_tree_with_duplicate_repl_returns_invalid_layout() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // A tree with two repl leaves.
        let bad_tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
            ],
            ratios: vec![0.5, 0.5],
        };
        let payload = serde_json::to_value(&bad_tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn set_layout_full_tree_with_duplicate_non_repl_ids_returns_invalid_layout() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        // Tree has repl once but "jobs" twice — duplicate ids.
        let bad_tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Split {
                    direction: SplitDirection::Vertical,
                    children: vec![
                        PaneTree::Leaf {
                            pane_id: "jobs".into(),
                        },
                        PaneTree::Leaf {
                            pane_id: "jobs".into(),
                        },
                    ],
                    ratios: vec![0.5, 0.5],
                },
            ],
            ratios: vec![0.5, 0.5],
        };
        let payload = serde_json::to_value(&bad_tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    // ── 12b. PaneTree::Tabs validation (W1 — curated-agent-views) ────────────

    /// A well-formed tree with a tabs node: repl alongside a two-child tabs
    /// region.
    fn tree_with_tabs_region(
        tab_children: Vec<PaneTree>,
        labels: Vec<&str>,
        active: usize,
    ) -> PaneTree {
        PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Tabs {
                    children: tab_children,
                    labels: labels.into_iter().map(String::from).collect(),
                    active,
                    region: None,
                },
            ],
            ratios: vec![0.5, 0.5],
        }
    }

    #[test]
    fn set_layout_with_well_formed_tabs_node_is_accepted() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let tree = tree_with_tabs_region(
            vec![
                PaneTree::Leaf {
                    pane_id: "ticket".into(),
                },
                PaneTree::Leaf {
                    pane_id: "activity".into(),
                },
            ],
            vec!["Ticket", "Activity"],
            0,
        );
        let payload = serde_json::to_value(&tree).unwrap();
        let result = reg.set_layout("mother", &payload).unwrap();

        assert_eq!(reg.pane_ids("mother"), vec!["repl", "ticket", "activity"]);
        assert_eq!(result, tree);
    }

    #[test]
    fn set_layout_tabs_node_with_mismatched_labels_length_is_rejected() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let tree = tree_with_tabs_region(
            vec![
                PaneTree::Leaf {
                    pane_id: "ticket".into(),
                },
                PaneTree::Leaf {
                    pane_id: "activity".into(),
                },
            ],
            vec!["Ticket"],
            0,
        );
        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
        assert_eq!(
            reg.pane_ids("mother"),
            vec!["repl"],
            "tree must be left unchanged"
        );
    }

    #[test]
    fn set_layout_tabs_node_with_active_out_of_range_is_rejected() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let tree = tree_with_tabs_region(
            vec![
                PaneTree::Leaf {
                    pane_id: "ticket".into(),
                },
                PaneTree::Leaf {
                    pane_id: "activity".into(),
                },
            ],
            vec!["Ticket", "Activity"],
            2,
        );
        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn set_layout_tabs_node_with_zero_children_is_rejected() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        let tree = tree_with_tabs_region(vec![], vec![], 0);
        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn set_layout_tabs_node_containing_repl_leaf_is_rejected() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // The tabs region itself hosts "repl" — hiding the REPL behind a tab
        // is never valid, regardless of whether a repl leaf exists elsewhere.
        let tree = PaneTree::Tabs {
            children: vec![
                PaneTree::Leaf {
                    pane_id: "repl".into(),
                },
                PaneTree::Leaf {
                    pane_id: "ticket".into(),
                },
            ],
            labels: vec!["Repl".into(), "Ticket".into()],
            active: 0,
            region: None,
        };
        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn set_layout_tabs_node_nested_inside_a_split_still_rejects_a_nested_repl() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // "repl" appears nested two levels deep inside the tabs region's own
        // inner split — the repl-inside-tabs check must walk the tabs
        // subtree recursively, not just its direct children. (This also
        // means the tree has no repl leaf anywhere else, so a naive
        // "exactly one repl" check alone wouldn't catch this — it's the
        // tabs-specific rule that must fire.)
        let tree = PaneTree::Split {
            direction: SplitDirection::Horizontal,
            children: vec![
                PaneTree::Leaf {
                    pane_id: "other".into(),
                },
                PaneTree::Tabs {
                    children: vec![
                        PaneTree::Split {
                            direction: SplitDirection::Vertical,
                            children: vec![
                                PaneTree::Leaf {
                                    pane_id: "repl".into(),
                                },
                                PaneTree::Leaf {
                                    pane_id: "activity".into(),
                                },
                            ],
                            ratios: vec![0.5, 0.5],
                        },
                        PaneTree::Leaf {
                            pane_id: "ticket".into(),
                        },
                    ],
                    labels: vec!["Nested".into(), "Ticket".into()],
                    active: 0,
                    region: None,
                },
            ],
            ratios: vec![0.5, 0.5],
        };

        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn set_layout_tabs_node_with_nested_split_recurses_ratio_validation() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");

        // A tabs child that is itself a malformed split (mismatched ratio
        // count) must still be caught — validation recurses into tab children.
        let tree = tree_with_tabs_region(
            vec![PaneTree::Split {
                direction: SplitDirection::Horizontal,
                children: vec![
                    PaneTree::Leaf {
                        pane_id: "a".into(),
                    },
                    PaneTree::Leaf {
                        pane_id: "b".into(),
                    },
                ],
                ratios: vec![1.0], // wrong length
            }],
            vec!["Broken"],
            0,
        );
        let payload = serde_json::to_value(&tree).unwrap();
        let err = reg.set_layout("mother", &payload).unwrap_err();
        assert_eq!(err, PaneError::InvalidLayout);
    }

    #[test]
    fn tabs_node_pane_ids_are_reachable_through_create_pane_and_bindable() {
        // A tabs child is an ordinary leaf pane once installed — it can be
        // targeted by create_pane (splitting it further) and bound to a source
        // exactly like any other leaf.
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        let tree = tree_with_tabs_region(
            vec![PaneTree::Leaf {
                pane_id: "ticket".into(),
            }],
            vec!["Ticket"],
            0,
        );
        reg.set_layout("mother", &serde_json::to_value(&tree).unwrap())
            .unwrap();

        reg.bind_source("mother", "ticket", "perri.list_pr_queue");
        assert_eq!(
            reg.source_for("mother", "ticket"),
            Some("perri.list_pr_queue")
        );
    }

    // ── 13. PaneError::code() returns stable snake_case strings ──────────────

    #[test]
    fn pane_error_code_returns_stable_snake_case_strings() {
        assert_eq!(PaneError::UnknownView.code(), "unknown_view");
        assert_eq!(PaneError::UnknownPane.code(), "unknown_pane");
        assert_eq!(PaneError::DuplicatePane.code(), "duplicate_pane");
        assert_eq!(PaneError::InvalidPosition.code(), "invalid_position");
        assert_eq!(PaneError::InvalidLayout.code(), "invalid_layout");
    }

    // ── 13b. SplitPosition::parse maps the four recognised strings ────────────

    #[test]
    fn split_position_parse_maps_all_four_recognised_strings() {
        assert_eq!(
            SplitPosition::parse("split_left").unwrap(),
            SplitPosition::Left
        );
        assert_eq!(
            SplitPosition::parse("split_right").unwrap(),
            SplitPosition::Right
        );
        assert_eq!(
            SplitPosition::parse("split_above").unwrap(),
            SplitPosition::Above
        );
        assert_eq!(
            SplitPosition::parse("split_below").unwrap(),
            SplitPosition::Below
        );
    }

    #[test]
    fn split_position_parse_returns_invalid_position_for_garbage() {
        let err = SplitPosition::parse("sideways").unwrap_err();
        assert_eq!(err, PaneError::InvalidPosition);
        let err = SplitPosition::parse("").unwrap_err();
        assert_eq!(err, PaneError::InvalidPosition);
        let err = SplitPosition::parse("Left").unwrap_err();
        assert_eq!(err, PaneError::InvalidPosition);
    }

    // ── 14. PERSISTENCE: tree survives registry drop + reload ─────────────────

    #[test]
    fn layout_survives_registry_drop_and_reload() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_persistence_layout_survives_registry_drop_and_reload.json");

        // Clean up any leftover from a previous run.
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("mother");
            reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
                .unwrap();
            reg.create_pane("mother", "log", SplitPosition::Below, "jobs")
                .unwrap();
            // reg drops here, flushing to disk.
        }

        // Load a fresh registry from the same path.
        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        assert!(
            reg2.contains("mother"),
            "focus 'mother' should survive reload"
        );
        assert_eq!(reg2.pane_ids("mother"), vec!["repl", "jobs", "log"]);

        // Clean up.
        let _ = std::fs::remove_file(&tmp);
    }

    // ── get_or_init: returns existing tree without overwriting ────────────────

    #[test]
    fn get_or_init_returns_existing_tree_without_reinitialising() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl")
            .unwrap();

        // get_or_init should return the existing 2-pane tree, not a fresh repl.
        let tree = reg.get_or_init("mother");
        let ids: Vec<String> = tree.pane_ids();
        assert_eq!(ids, vec!["repl", "jobs"]);
    }

    #[test]
    fn get_or_init_initialises_absent_focus_to_single_repl() {
        let mut reg = PaneRegistry::in_memory();
        let tree = reg.get_or_init("brand_new");
        assert_eq!(tree.pane_ids(), vec!["repl"]);
        assert!(reg.contains("brand_new"));
    }

    // ── contains / get return expected state ──────────────────────────────────

    #[test]
    fn contains_returns_false_for_unregistered_tag() {
        let reg = PaneRegistry::in_memory();
        assert!(!reg.contains("ghost"));
    }

    #[test]
    fn get_returns_none_for_unregistered_tag() {
        let reg = PaneRegistry::in_memory();
        assert!(reg.get("ghost").is_none());
    }

    #[test]
    fn pane_ids_returns_empty_vec_for_unregistered_tag() {
        let reg = PaneRegistry::in_memory();
        assert!(reg.pane_ids("ghost").is_empty());
    }

    // ── 15. bind_source / unbind_source / source_for ──────────────────────────

    #[test]
    fn bind_source_on_repl_pane_is_silently_refused() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.bind_source("mother", REPL_PANE_ID, "perri.list_pr_queue");
        assert_eq!(reg.source_for("mother", REPL_PANE_ID), None);
        assert!(reg.all_bindings().is_empty());
    }

    #[test]
    fn bind_source_on_pane_not_in_tag_tree_is_silently_refused() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.bind_source("mother", "does_not_exist", "perri.list_pr_queue");
        assert_eq!(reg.source_for("mother", "does_not_exist"), None);
        assert!(reg.all_bindings().is_empty());
    }

    #[test]
    fn bind_source_on_unregistered_tag_is_silently_refused_and_does_not_panic() {
        let mut reg = PaneRegistry::in_memory();
        // No init_focus at all — "ghost" has no tree yet.
        reg.bind_source("ghost", "queue", "perri.list_pr_queue");
        assert_eq!(reg.source_for("ghost", "queue"), None);
        assert!(reg.all_bindings().is_empty());
    }

    #[test]
    fn bind_source_on_valid_leaf_pane_is_observable_via_source_for() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("perri");
        reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("perri", "queue", "perri.list_pr_queue");
        assert_eq!(
            reg.source_for("perri", "queue"),
            Some("perri.list_pr_queue")
        );
    }

    #[test]
    fn bind_source_rebinding_the_same_pane_replaces_the_old_source_with_one_entry() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("mother", "queue", "perri.list_pr_queue");
        reg.bind_source("mother", "queue", "perri.get_current_pr");

        assert_eq!(
            reg.source_for("mother", "queue"),
            Some("perri.get_current_pr")
        );
        let matching: Vec<_> = reg
            .all_bindings()
            .into_iter()
            .filter(|(tag, pane_id, _)| tag == "mother" && pane_id == "queue")
            .collect();
        assert_eq!(
            matching.len(),
            1,
            "rebinding must replace, not accumulate, entries for the same pane"
        );
    }

    #[test]
    fn unbind_source_removes_the_binding() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("mother", "queue", "perri.list_pr_queue");
        reg.unbind_source("mother", "queue");
        assert_eq!(reg.source_for("mother", "queue"), None);
    }

    #[test]
    fn unbind_source_on_pane_with_no_binding_is_a_noop() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.unbind_source("mother", "repl"); // must not panic
        assert_eq!(reg.source_for("mother", "repl"), None);
    }

    #[test]
    fn source_for_returns_none_for_unregistered_tag_or_pane() {
        let reg = PaneRegistry::in_memory();
        assert_eq!(reg.source_for("ghost", "queue"), None);
    }

    #[test]
    fn all_bindings_returns_stable_sorted_order_across_tags() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("b-tag");
        reg.create_pane("b-tag", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("b-tag", "queue", "perri.list_pr_queue");

        reg.init_focus("a-tag");
        reg.create_pane("a-tag", "diff", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("a-tag", "diff", "perri.get_current_pr");

        let bindings = reg.all_bindings();
        let keys: Vec<(String, String)> = bindings
            .iter()
            .map(|(tag, pane_id, _)| (tag.clone(), pane_id.clone()))
            .collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(
            keys, sorted,
            "all_bindings must already be returned in stable sorted order"
        );
        assert_eq!(
            bindings,
            vec![
                (
                    "a-tag".to_string(),
                    "diff".to_string(),
                    SourceBinding::new("perri.get_current_pr")
                ),
                (
                    "b-tag".to_string(),
                    "queue".to_string(),
                    SourceBinding::new("perri.list_pr_queue")
                ),
            ]
        );
    }

    // ── 16. Bindings are dropped alongside the pane that carried them ─────────

    #[test]
    fn reset_drops_all_bindings_for_that_tag() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.create_pane("mother", "diff", SplitPosition::Below, "queue")
            .unwrap();
        reg.bind_source("mother", "queue", "perri.list_pr_queue");
        reg.bind_source("mother", "diff", "perri.get_current_pr");

        reg.reset("mother").unwrap();

        assert_eq!(reg.source_for("mother", "queue"), None);
        assert_eq!(reg.source_for("mother", "diff"), None);
        assert!(reg.all_bindings().is_empty());
    }

    #[test]
    fn set_layout_full_tree_that_omits_a_bound_pane_drops_its_binding() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("mother", "queue", "perri.list_pr_queue");

        // Replace the tree wholesale with one that no longer has "queue".
        let replacement = PaneTree::repl_leaf();
        let payload = serde_json::to_value(&replacement).unwrap();
        reg.set_layout("mother", &payload).unwrap();

        assert_eq!(reg.source_for("mother", "queue"), None);
        assert!(reg.all_bindings().is_empty());
    }

    #[test]
    fn set_layout_ratio_map_that_keeps_a_bound_pane_preserves_its_binding() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        reg.create_pane("mother", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("mother", "queue", "perri.list_pr_queue");

        // A ratio-map payload never touches structure, so "queue" survives.
        reg.set_layout("mother", &serde_json::json!({"repl": 0.3, "queue": 0.7}))
            .unwrap();

        assert_eq!(
            reg.source_for("mother", "queue"),
            Some("perri.list_pr_queue")
        );
    }

    // ── 17. Bindings persist across drop + reload ─────────────────────────────

    #[test]
    fn bindings_survive_registry_drop_and_reload() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_bindings_survive_registry_drop_and_reload.json");
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source("perri", "queue", "perri.list_pr_queue");
            // reg drops here, flushing to disk.
        }

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        assert_eq!(
            reg2.source_for("perri", "queue"),
            Some("perri.list_pr_queue"),
            "a binding must survive a registry drop + reload just like the tree does"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 18. Backward compat: bare-HashMap store (pre-binding format) loads ────

    #[test]
    fn old_format_store_without_version_envelope_loads_trees_with_zero_bindings() {
        let tmp = std::env::temp_dir().join("pane_registry_test_old_format_store_loads.json");
        let _ = std::fs::remove_file(&tmp);

        // Exactly what `serde_json::to_vec_pretty(&some_hashmap)` produced
        // before this feature existed — a bare `HashMap<String, PaneTree>`,
        // no version envelope, no bindings field at all.
        let mut trees: HashMap<String, PaneTree> = HashMap::new();
        trees.insert("mother".to_string(), PaneTree::repl_leaf());
        let bytes = serde_json::to_vec_pretty(&trees).unwrap();
        std::fs::write(&tmp, bytes).unwrap();

        let reg = PaneRegistry::with_store_path(tmp.clone());
        assert!(reg.contains("mother"));
        assert_eq!(reg.pane_ids("mother"), vec!["repl".to_string()]);
        assert!(
            reg.all_bindings().is_empty(),
            "an old-format store has no bindings to recover, not a load failure"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 19. A persisted binding to a retired/unknown source is dropped ────────

    #[test]
    fn binding_with_unknown_source_is_dropped_on_load_but_pane_tree_survives() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_binding_unknown_source_dropped_on_load.json");
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source("perri", "queue", "perri.list_pr_queue");
        }

        // Corrupt the persisted binding's source to something outside the
        // closed fetcher registry — simulating a source retired in a later
        // daemon version, or a hand-edited state file. A raw string
        // substitution keeps this test decoupled from the exact on-disk
        // envelope shape (which is an implementation detail of the
        // persistence format, not part of the public contract).
        let raw = std::fs::read_to_string(&tmp).unwrap();
        assert!(
            raw.contains("perri.list_pr_queue"),
            "persisted store should contain the bound source literally: {raw}"
        );
        let corrupted = raw.replace("perri.list_pr_queue", "totally.unknown.source");
        std::fs::write(&tmp, corrupted).unwrap();

        assert!(
            !crate::mcp::tools::apply_layout::known_sources().contains(&"totally.unknown.source"),
            "sanity: the substituted source must actually be unknown"
        );

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        assert_eq!(
            reg2.source_for("perri", "queue"),
            None,
            "a binding to an unknown source must not survive a reload"
        );
        assert_eq!(
            reg2.pane_ids("perri"),
            vec!["repl".to_string(), "queue".to_string()],
            "the pane structure itself must be unaffected by dropping the stale binding"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 20. mark_painted / has_been_painted — transient, not persisted ───────

    #[test]
    fn mark_painted_sets_has_been_painted_true() {
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("mother");
        assert!(!reg.has_been_painted("mother", "repl"));
        reg.mark_painted("mother", "repl");
        assert!(reg.has_been_painted("mother", "repl"));
    }

    #[test]
    fn has_been_painted_is_false_for_never_marked_pane() {
        let reg = PaneRegistry::in_memory();
        assert!(!reg.has_been_painted("ghost", "queue"));
    }

    #[test]
    fn has_been_painted_is_false_for_every_pane_immediately_after_fresh_reload() {
        let tmp =
            std::env::temp_dir().join("pane_registry_test_painted_state_is_not_persisted.json");
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source("perri", "queue", "perri.list_pr_queue");
            reg.mark_painted("perri", "queue");
            assert!(reg.has_been_painted("perri", "queue"));
        }

        // A fresh reload must NOT remember that "queue" was ever painted —
        // painted state is a transient "have I sent this since daemon start"
        // bit, deliberately separate from the persisted binding.
        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        assert!(!reg2.has_been_painted("perri", "queue"));
        assert!(!reg2.has_been_painted("perri", "repl"));
        // The binding itself, unlike painted state, did survive the reload.
        assert_eq!(
            reg2.source_for("perri", "queue"),
            Some("perri.list_pr_queue")
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 21. bind_source (no params) persists and reloads as params: None ─────

    #[test]
    fn binding_created_without_params_persists_and_reloads_as_params_none() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_binding_without_params_reloads_as_none.json");
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source("perri", "queue", "perri.list_pr_queue");
        }

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        let binding = reg2
            .binding_for("perri", "queue")
            .expect("binding must survive reload");
        assert_eq!(binding.source, "perri.list_pr_queue");
        assert_eq!(
            binding.params, None,
            "a bind_source binding must reload with params: None, identical to before"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 22. bind_source_with_params round-trips its params through save/reload

    #[test]
    fn binding_created_with_params_round_trips_params_through_save_and_reload() {
        let tmp =
            std::env::temp_dir().join("pane_registry_test_binding_with_params_round_trips.json");
        let _ = std::fs::remove_file(&tmp);

        let params =
            serde_json::json!({ "path": "src/main.rs", "revision": "working", "anchor_line": 12 });

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("cody");
            reg.create_pane("cody", "file", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source_with_params("cody", "file", "nostromo.get_file", Some(params.clone()));
        }

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        let binding = reg2
            .binding_for("cody", "file")
            .expect("binding must survive reload");
        assert_eq!(binding.source, "nostromo.get_file");
        assert_eq!(binding.params, Some(params));

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 23. Hand-written V2 store (bare source-name bindings) loads correctly ─

    #[test]
    fn hand_written_v2_store_loads_trees_and_binding_as_params_none() {
        let tmp = std::env::temp_dir().join("pane_registry_test_hand_written_v2_store_loads.json");
        let _ = std::fs::remove_file(&tmp);

        // The exact pre-params (D3) wire shape: `bindings` maps
        // tag -> pane_id -> a bare source-name *string*, with no `params`
        // field anywhere — this literal is the migration criterion.
        let raw = r#"{
            "version": 2,
            "trees": {
                "perri": {
                    "kind": "split",
                    "direction": "horizontal",
                    "children": [
                        { "kind": "leaf", "pane_id": "repl" },
                        { "kind": "leaf", "pane_id": "queue" }
                    ],
                    "ratios": [0.5, 0.5]
                }
            },
            "bindings": {
                "perri": { "queue": "perri.list_pr_queue" }
            }
        }"#;
        std::fs::write(&tmp, raw).unwrap();

        let reg = PaneRegistry::with_store_path(tmp.clone());
        assert_eq!(
            reg.pane_ids("perri"),
            vec!["repl".to_string(), "queue".to_string()],
            "trees must load intact from a V2 store"
        );
        let binding = reg
            .binding_for("perri", "queue")
            .expect("a V2-shaped binding must load");
        assert_eq!(binding.source, "perri.list_pr_queue");
        assert_eq!(
            binding.params, None,
            "a V2 binding has no params field at all and must load as None"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 24. Hand-written V1 store (bare tag -> PaneTree map) loads trees only ─

    #[test]
    fn hand_written_v1_store_bare_map_loads_trees_with_zero_bindings() {
        let tmp = std::env::temp_dir().join("pane_registry_test_hand_written_v1_store_loads.json");
        let _ = std::fs::remove_file(&tmp);

        // The pre-binding wire shape: a bare `{ "<tag>": <PaneTree> }` map —
        // no version envelope, no "trees"/"bindings" keys at all.
        let raw = r#"{
            "mother": { "kind": "leaf", "pane_id": "repl" }
        }"#;
        std::fs::write(&tmp, raw).unwrap();

        let reg = PaneRegistry::with_store_path(tmp.clone());
        assert!(reg.contains("mother"));
        assert_eq!(reg.pane_ids("mother"), vec!["repl".to_string()]);
        assert!(
            reg.all_bindings().is_empty(),
            "a V1 store has no bindings to recover, not a load failure"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 25. A persisted binding with params to an unknown source is dropped ──

    #[test]
    fn binding_with_params_to_unknown_source_is_dropped_on_load_but_pane_tree_survives() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_binding_with_params_unknown_source_dropped.json");
        let _ = std::fs::remove_file(&tmp);

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("cody");
            reg.create_pane("cody", "file", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source_with_params(
                "cody",
                "file",
                "nostromo.get_file",
                Some(serde_json::json!({ "path": "src/main.rs" })),
            );
        }

        // Corrupt the persisted binding's source to something outside the
        // closed fetcher registry, the same way an already-established test
        // above does for a params-less binding — this is the params-carrying
        // counterpart of that guard.
        let raw = std::fs::read_to_string(&tmp).unwrap();
        assert!(raw.contains("nostromo.get_file"));
        let corrupted = raw.replace("nostromo.get_file", "totally.unknown.source");
        std::fs::write(&tmp, corrupted).unwrap();

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        assert_eq!(
            reg2.binding_for("cody", "file"),
            None,
            "a binding (with params) to an unknown source must not survive a reload"
        );
        assert_eq!(
            reg2.pane_ids("cody"),
            vec!["repl".to_string(), "file".to_string()],
            "the pane structure must be unaffected by dropping the stale binding"
        );

        let _ = std::fs::remove_file(&tmp);
    }

    // ── 26. nostromo.get_file is a known source — its binding is not dropped ─

    #[test]
    fn binding_to_nostromo_get_file_survives_reload_because_it_is_a_known_source() {
        let tmp = std::env::temp_dir()
            .join("pane_registry_test_get_file_binding_survives_because_known.json");
        let _ = std::fs::remove_file(&tmp);

        assert!(
            crate::mcp::tools::apply_layout::known_sources().contains(&"nostromo.get_file"),
            "sanity: nostromo.get_file must be a known source"
        );

        {
            let mut reg = PaneRegistry::with_store_path(tmp.clone());
            reg.init_focus("cody");
            reg.create_pane("cody", "file", SplitPosition::Right, "repl")
                .unwrap();
            reg.bind_source_with_params(
                "cody",
                "file",
                "nostromo.get_file",
                Some(serde_json::json!({ "path": "src/main.rs", "revision": "working" })),
            );
        }

        let reg2 = PaneRegistry::with_store_path(tmp.clone());
        let binding = reg2
            .binding_for("cody", "file")
            .expect("a known-source binding must survive reload, unlike an unknown one");
        assert_eq!(binding.source, "nostromo.get_file");

        let _ = std::fs::remove_file(&tmp);
    }
}
