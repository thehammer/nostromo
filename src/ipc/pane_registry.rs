//! Per-focus agent-authored pane-tree registry (Phase 1: agent-driven-pane-layout).
//!
//! The daemon is the single source of truth for every focus's pane structure.
//! A focus is keyed by its session `tag`; its layout is a [`PaneTree`] whose
//! leaves are panes. On a fresh (non-resume) spawn the tree is a single REPL
//! leaf; an agent grows it on its first turn via the `create_pane` /
//! `set_pane_layout` MCP tools, and tears it back down with `reset_panes`.
//!
//! This registry holds only **structure** (the tree). Pane *content* travels as
//! a separate `ServerMsg::PaneContent` broadcast and is deliberately not stored
//! here — keeping content out of the structural model is what lets an operator's
//! manual drag-resize survive a content refresh (only a structural mutation
//! re-declares geometry).
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

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::Value;

use super::protocol::{PaneTree, SplitDirection};

/// The reserved pane id that is always present in a focus.
pub const REPL_PANE_ID: &str = "repl";

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
        let trees = load_store(&store_path);
        Self {
            trees,
            store_path: Some(store_path),
        }
    }

    /// Construct an in-memory registry with no persistence (used by tests that
    /// don't care about disk round-trips).
    pub fn in_memory() -> Self {
        Self {
            trees: HashMap::new(),
            store_path: None,
        }
    }

    // ── reads ────────────────────────────────────────────────────────────────

    /// The tree for `tag`, if the focus is registered.
    pub fn get(&self, tag: &str) -> Option<&PaneTree> {
        self.trees.get(tag)
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

    // ── mutations ──────────────────────────────────────────────────────────────

    /// Initialise (or re-initialise) `tag` to a single REPL leaf and persist.
    /// Called on a fresh, non-resume session spawn.
    pub fn init_focus(&mut self, tag: &str) -> PaneTree {
        let tree = PaneTree::repl_leaf();
        self.trees.insert(tag.to_string(), tree.clone());
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
            let new_tree: PaneTree = serde_json::from_value(tree_value.clone())
                .map_err(|_| PaneError::InvalidLayout)?;
            validate_tree(&new_tree)?;
            self.trees.insert(tag.to_string(), new_tree.clone());
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
        self.persist();
        Ok(result)
    }

    // ── persistence ────────────────────────────────────────────────────────────

    fn persist(&self) {
        if let Some(path) = &self.store_path {
            save_store(path, &self.trees);
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
        PaneTree::Split { children, .. } => {
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
/// all leaves named in the map. Ratios are normalised to sum to 1.0.
fn apply_ratio_map(node: &mut PaneTree, ratios: &HashMap<String, f32>) {
    if let PaneTree::Split {
        children,
        ratios: r,
        ..
    } = node
    {
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
    // Well-formed splits.
    validate_splits(tree)
}

fn validate_splits(node: &PaneTree) -> Result<(), PaneError> {
    if let PaneTree::Split {
        children, ratios, ..
    } = node
    {
        if children.len() < 2 || children.len() != ratios.len() {
            return Err(PaneError::InvalidLayout);
        }
        for child in children {
            validate_splits(child)?;
        }
    }
    Ok(())
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

fn load_store(path: &std::path::Path) -> HashMap<String, PaneTree> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Serialise store writes so concurrent focus mutations can't clobber the file.
static SAVE_STORE_LOCK: Mutex<()> = Mutex::new(());

fn save_store(path: &std::path::Path, trees: &HashMap<String, PaneTree>) {
    let _guard = SAVE_STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(trees) {
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
            PaneTree::Split { direction, ratios, .. } => {
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
            PaneTree::Split { direction, ratios, children } => {
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
            PaneTree::Split { direction, children, .. } => {
                assert_eq!(*direction, SplitDirection::Horizontal);
                assert_eq!(children.len(), 2);
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "repl"));
                match &children[1] {
                    PaneTree::Split { direction: inner_dir, children: inner_children, .. } => {
                        assert_eq!(*inner_dir, SplitDirection::Vertical);
                        assert_eq!(inner_children.len(), 2);
                        assert!(matches!(&inner_children[0], PaneTree::Leaf { pane_id } if pane_id == "jobs"));
                        assert!(matches!(&inner_children[1], PaneTree::Leaf { pane_id } if pane_id == "diff"));
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
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl").unwrap();
        reg.create_pane("mother", "diff", SplitPosition::Below, "jobs").unwrap();
        reg.create_pane("mother", "log", SplitPosition::Right, "diff").unwrap();

        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);

        // After reset.
        reg.reset("mother").unwrap();
        let ids = reg.pane_ids("mother");
        assert_eq!(ids.iter().filter(|id| id.as_str() == "repl").count(), 1);

        // And again after re-building.
        reg.create_pane("mother", "jobs", SplitPosition::Right, "repl").unwrap();
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
        reg.set_layout(
            "mother",
            &serde_json::json!({"repl": 0.3, "jobs": 0.7}),
        )
        .unwrap();

        // Structure unchanged.
        assert_eq!(reg.pane_ids("mother"), panes_before);

        // Ratios updated: 0.3/1.0 and 0.7/1.0 (sum is 1.0, already normalised).
        let tree = reg.get("mother").unwrap();
        match tree {
            PaneTree::Split { ratios, .. } => {
                let tolerance = 1e-5_f32;
                assert!((ratios[0] - 0.3_f32).abs() < tolerance, "ratio[0] = {}", ratios[0]);
                assert!((ratios[1] - 0.7_f32).abs() < tolerance, "ratio[1] = {}", ratios[1]);
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
        reg.set_layout(
            "mother",
            &serde_json::json!({"repl": 1.0, "jobs": 3.0}),
        )
        .unwrap();

        let tree = reg.get("mother").unwrap();
        match tree {
            PaneTree::Split { ratios, .. } => {
                let tolerance = 1e-5_f32;
                // Normalised: 1/4 = 0.25, 3/4 = 0.75.
                assert!((ratios[0] - 0.25_f32).abs() < tolerance, "ratio[0] = {}", ratios[0]);
                assert!((ratios[1] - 0.75_f32).abs() < tolerance, "ratio[1] = {}", ratios[1]);
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
                PaneTree::Leaf { pane_id: "repl".into() },
                PaneTree::Leaf { pane_id: "dashboard".into() },
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
                PaneTree::Leaf { pane_id: "jobs".into() },
                PaneTree::Leaf { pane_id: "log".into() },
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
                PaneTree::Leaf { pane_id: "repl".into() },
                PaneTree::Leaf { pane_id: "repl".into() },
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
                PaneTree::Leaf { pane_id: "repl".into() },
                PaneTree::Split {
                    direction: SplitDirection::Vertical,
                    children: vec![
                        PaneTree::Leaf { pane_id: "jobs".into() },
                        PaneTree::Leaf { pane_id: "jobs".into() },
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
        assert_eq!(SplitPosition::parse("split_left").unwrap(), SplitPosition::Left);
        assert_eq!(SplitPosition::parse("split_right").unwrap(), SplitPosition::Right);
        assert_eq!(SplitPosition::parse("split_above").unwrap(), SplitPosition::Above);
        assert_eq!(SplitPosition::parse("split_below").unwrap(), SplitPosition::Below);
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
        assert!(reg2.contains("mother"), "focus 'mother' should survive reload");
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
}
