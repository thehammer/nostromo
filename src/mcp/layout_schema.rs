//! Declarative pane-layout schema (DSL) for `nostromo.apply_layout`.
//!
//! A [`LayoutSchema`] names a layout, declares a [`SchemaNode`] tree in a
//! human-friendly YAML form (interior nodes carry `direction`/`ratios`/
//! `children`; leaves are `{ pane: <id> }`), and binds each non-repl pane to a
//! data `source` + `content_kind` (+ optional `placeholder`) via [`PaneSpec`].
//!
//! `SchemaNode::to_pane_tree` converts the DSL tree into the existing
//! [`crate::ipc::protocol::PaneTree`] wire type; the *existing*
//! `PaneRegistry::set_layout` validation path (exactly one `repl` leaf, unique
//! ids, well-formed splits) is reused rather than reimplemented here — this
//! module only validates what the registry can't know about: `content_kind`
//! and `source` legality.
//!
//! ## Precedence
//!
//! [`load`] resolves a named layout by checking `~/.nostromo/layouts/<name>.yaml`
//! first (an operator override, re-read on every call — no daemon rebuild
//! needed to edit it), falling back to the compiled-in default embedded via
//! `include_str!`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::ipc::pane_registry::REPL_PANE_ID;
use crate::ipc::protocol::{PaneTree, SplitDirection};
use crate::mcp::tools::apply_layout::{source_content_kind, source_is_known, ApplyLayoutError};

/// The `content_kind` names a `PaneSpec` may declare — one per
/// `PaneContentWire` variant.
const VALID_CONTENT_KINDS: [&str; 8] = [
    "text",
    "json_snapshot",
    "pr_list",
    "loading",
    "error",
    "code",
    "diff",
    "pr_conversation",
];

/// A named, declarative pane layout: a tree shape plus per-pane data bindings.
#[derive(Debug, Clone, Deserialize)]
pub struct LayoutSchema {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub tree: SchemaNode,
    #[serde(default)]
    pub panes: HashMap<String, PaneSpec>,
}

/// One entry in a `SchemaNode::Tabs`'s `tabs:` list — a pane reference plus
/// its display label. A struct (rather than a bare `{ pane: "x", label: "Y" }`
/// leaf-with-extra-field) so the DSL reads as "a list of (pane, label) pairs"
/// rather than overloading the leaf shape.
#[derive(Debug, Clone, Deserialize)]
pub struct SchemaTabEntry {
    pub pane: String,
    pub label: String,
}

/// A node in the DSL tree: an interior split, a tabbed region, or a leaf pane
/// reference.
///
/// Untagged: a leaf is `{ pane: "queue" }`; a split is `{ direction, ratios,
/// children }`; a tabbed region is `{ tabs: [{ pane, label }, ...], active:
/// "<pane id>" }`. Serde tries each variant in declaration order and falls
/// through to the next on a field mismatch — `Tabs` is listed first (it has
/// the most distinctive field, `tabs`), then `Split`, then `Leaf` last as the
/// catch-all shape.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum SchemaNode {
    Tabs {
        tabs: Vec<SchemaTabEntry>,
        /// The pane id (not index) of the frontmost tab — matching the DSL's
        /// pane-id-centric vocabulary elsewhere, rather than an index that
        /// would silently drift if `tabs` were reordered.
        active: String,
    },
    Split {
        direction: SplitDirection,
        ratios: Vec<f32>,
        children: Vec<SchemaNode>,
    },
    Leaf {
        pane: String,
    },
}

impl SchemaNode {
    /// Convert this DSL node into the wire [`PaneTree`] shape. Purely
    /// structural — the registry's own `set_layout` validates the result
    /// (including that `active` actually names one of `tabs`).
    pub fn to_pane_tree(&self) -> PaneTree {
        match self {
            SchemaNode::Leaf { pane } => PaneTree::Leaf {
                pane_id: pane.clone(),
            },
            SchemaNode::Split {
                direction,
                ratios,
                children,
            } => PaneTree::Split {
                direction: *direction,
                children: children.iter().map(SchemaNode::to_pane_tree).collect(),
                ratios: ratios.clone(),
            },
            SchemaNode::Tabs { tabs, active } => {
                let active_index = tabs.iter().position(|t| &t.pane == active).unwrap_or(0);
                PaneTree::Tabs {
                    children: tabs
                        .iter()
                        .map(|t| PaneTree::Leaf {
                            pane_id: t.pane.clone(),
                        })
                        .collect(),
                    labels: tabs.iter().map(|t| t.label.clone()).collect(),
                    active: active_index,
                }
            }
        }
    }
}

/// A single pane's data binding within a [`LayoutSchema`].
#[derive(Debug, Clone, Deserialize)]
pub struct PaneSpec {
    /// The fetcher source this pane is bound to (an allow-listed name from
    /// `apply_layout`'s closed dispatch table). `None` means the pane has no
    /// server-side fetch — the agent populates it itself via `set_pane_content`.
    #[serde(default)]
    pub source: Option<String>,
    /// One of the `PaneContentWire` variant surface names.
    pub content_kind: String,
    /// Shown (as `Text`) when the fetcher yields empty/null data.
    #[serde(default)]
    pub placeholder: Option<String>,
}

/// True when `kind` names one of the `PaneContentWire` variants.
pub fn content_kind_is_valid(kind: &str) -> bool {
    VALID_CONTENT_KINDS.contains(&kind)
}

/// Parse and validate a YAML layout schema document.
pub fn parse(yaml: &str) -> Result<LayoutSchema, ApplyLayoutError> {
    let schema: LayoutSchema =
        serde_yaml::from_str(yaml).map_err(|_| ApplyLayoutError::InvalidSchema)?;
    validate(&schema)?;
    Ok(schema)
}

/// Validate the parts of a schema the `PaneRegistry` doesn't know about:
/// the `repl` leaf must not appear in `panes`, no `tabs` region may contain
/// `repl` (a distinct check from the one above — the REPL is where the
/// operator's hands are, and hiding it behind a tab is never what an agent
/// means, so this fails loud rather than silently being caught later by the
/// registry's own repl-inside-tabs guard), every `content_kind` must be a
/// recognised `PaneContentWire` variant, every `source` must resolve against
/// the closed fetcher registry, and — for a pane that has a `source` — the
/// declared `content_kind` must match what that source actually produces.
///
/// That last check exists because `apply_layout::fetch` hardcodes the
/// `PaneContentWire` variant per `source` name; without it, a schema could
/// declare e.g. `content_kind: text` for `source: perri.list_pr_queue` and
/// pass validation while `fetch` silently ignored the declaration and pushed
/// `PrList` anyway. Failing loud here (`InvalidContentKind`) instead keeps the
/// two in sync rather than letting them drift apart silently.
pub fn validate(schema: &LayoutSchema) -> Result<(), ApplyLayoutError> {
    if schema.panes.contains_key(REPL_PANE_ID) {
        return Err(ApplyLayoutError::InvalidSchema);
    }
    validate_no_repl_in_tabs(&schema.tree)?;
    for spec in schema.panes.values() {
        if !content_kind_is_valid(&spec.content_kind) {
            return Err(ApplyLayoutError::InvalidContentKind);
        }
        if let Some(source) = &spec.source {
            if !source_is_known(source) {
                return Err(ApplyLayoutError::UnknownSource);
            }
            if let Some(expected) = source_content_kind(source) {
                if expected != spec.content_kind {
                    return Err(ApplyLayoutError::InvalidContentKind);
                }
            }
        }
    }
    Ok(())
}

/// Recursively refuse a `tabs` region that names `repl` among its tab panes
/// (W1 — curated-agent-views). A separate check from the `panes` map lookup
/// above: `repl` is never declared in `panes` (it has no data binding), but it
/// is a perfectly normal `pane:` reference inside a `SchemaNode::Tabs`'s
/// `tabs:` list, so that shape needs its own walk.
fn validate_no_repl_in_tabs(node: &SchemaNode) -> Result<(), ApplyLayoutError> {
    match node {
        SchemaNode::Leaf { .. } => Ok(()),
        SchemaNode::Split { children, .. } => {
            for child in children {
                validate_no_repl_in_tabs(child)?;
            }
            Ok(())
        }
        SchemaNode::Tabs { tabs, .. } => {
            if tabs.iter().any(|t| t.pane == REPL_PANE_ID) {
                return Err(ApplyLayoutError::ReplInTabs);
            }
            Ok(())
        }
    }
}

/// Resolve a named layout: an on-disk override under `dir` if present, else
/// the compiled-in default. Read fresh on every call — no daemon rebuild is
/// needed to pick up an edited override file.
pub fn load_from_dir(name: &str, dir: &Path) -> Result<LayoutSchema, ApplyLayoutError> {
    let override_path = dir.join(format!("{name}.yaml"));
    if let Ok(text) = std::fs::read_to_string(&override_path) {
        return parse(&text);
    }
    compiled_in(name)
}

/// Resolve a named layout against the real `~/.nostromo/layouts` override
/// directory (see [`load_from_dir`]).
pub fn load(name: &str) -> Result<LayoutSchema, ApplyLayoutError> {
    load_from_dir(name, &layouts_dir())
}

/// The compiled-in layouts, embedded at build time. Only reached when no
/// on-disk override shadows `name`.
fn compiled_in(name: &str) -> Result<LayoutSchema, ApplyLayoutError> {
    match name {
        "perri-standard" => parse(include_str!("layouts/perri-standard.yaml")),
        _ => Err(ApplyLayoutError::UnknownLayout),
    }
}

/// `~/.nostromo/layouts`, the on-disk override directory for named layouts.
pub fn layouts_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("layouts")
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::pane_registry::PaneRegistry;

    #[test]
    fn perri_standard_round_trips() {
        let schema = compiled_in("perri-standard").expect("perri-standard should parse");
        assert_eq!(schema.name, "perri-standard");
        assert_eq!(schema.panes.len(), 2);
        assert!(schema.panes.contains_key("queue"));
        assert!(schema.panes.contains_key("diff"));
        assert_eq!(
            schema.panes["queue"].source.as_deref(),
            Some("perri.list_pr_queue")
        );
        assert_eq!(schema.panes["queue"].content_kind, "pr_list");
        assert_eq!(
            schema.panes["diff"].source.as_deref(),
            Some("perri.get_current_pr")
        );
        assert_eq!(schema.panes["diff"].content_kind, "text");
        assert!(schema.panes["diff"].placeholder.is_some());
    }

    #[test]
    fn dsl_to_pane_tree_is_structurally_correct() {
        let schema = compiled_in("perri-standard").unwrap();
        let tree = schema.tree.to_pane_tree();

        // vertical([ horizontal([queue, diff]), repl ])
        match tree.clone() {
            PaneTree::Split {
                direction,
                children,
                ratios,
            } => {
                assert_eq!(direction, SplitDirection::Vertical);
                assert_eq!(ratios, vec![0.6, 0.4]);
                assert_eq!(children.len(), 2);
                match &children[0] {
                    PaneTree::Split {
                        direction: inner_dir,
                        children: inner_children,
                        ratios: inner_ratios,
                    } => {
                        assert_eq!(*inner_dir, SplitDirection::Horizontal);
                        assert_eq!(*inner_ratios, vec![0.5, 0.5]);
                        assert!(
                            matches!(&inner_children[0], PaneTree::Leaf { pane_id } if pane_id == "queue")
                        );
                        assert!(
                            matches!(&inner_children[1], PaneTree::Leaf { pane_id } if pane_id == "diff")
                        );
                    }
                    other => panic!("expected inner Horizontal split, got {other:?}"),
                }
                assert!(matches!(&children[1], PaneTree::Leaf { pane_id } if pane_id == "repl"));
            }
            other => panic!("expected outer Vertical split, got {other:?}"),
        }

        // And the converted tree passes the registry's own invariant checks.
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("perri");
        reg.set_layout("perri", &serde_json::json!({ "tree": tree }))
            .expect("converted tree should satisfy PaneRegistry invariants");
    }

    #[test]
    fn invalid_content_kind_is_rejected() {
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: sidebar
    - pane: repl
panes:
  sidebar:
    content_kind: not_a_real_kind
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::InvalidContentKind);
    }

    #[test]
    fn content_kind_mismatched_with_known_source_is_rejected() {
        // `perri.list_pr_queue` always produces `PrList` (see
        // `apply_layout::source_content_kind`) — declaring `content_kind: text`
        // for it must fail validation rather than silently passing while
        // `fetch` ignores the declared kind.
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: sidebar
    - pane: repl
panes:
  sidebar:
    source: perri.list_pr_queue
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::InvalidContentKind);
    }

    #[test]
    fn unknown_source_is_rejected() {
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: sidebar
    - pane: repl
panes:
  sidebar:
    source: nonexistent.fetcher
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::UnknownSource);
    }

    #[test]
    fn repl_in_panes_is_rejected_as_invalid_schema() {
        let yaml = r#"
name: bad
tree:
  pane: repl
panes:
  repl:
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::InvalidSchema);
    }

    // ── SchemaNode::Tabs (W1 — curated-agent-views) ──────────────────────────

    #[test]
    fn tabs_form_parses_and_converts_to_a_pane_tree_tabs_node() {
        let yaml = r#"
name: with-tabs
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: repl
    - tabs:
        - pane: ticket
          label: Ticket
        - pane: activity
          label: Activity
      active: activity
panes:
  ticket:
    content_kind: text
  activity:
    content_kind: text
"#;
        let schema = parse(yaml).expect("a tabs region must parse");
        let tree = schema.tree.to_pane_tree();

        match &tree {
            PaneTree::Split { children, .. } => {
                assert!(matches!(&children[0], PaneTree::Leaf { pane_id } if pane_id == "repl"));
                match &children[1] {
                    PaneTree::Tabs {
                        children: tab_children,
                        labels,
                        active,
                    } => {
                        assert!(
                            matches!(&tab_children[0], PaneTree::Leaf { pane_id } if pane_id == "ticket")
                        );
                        assert!(
                            matches!(&tab_children[1], PaneTree::Leaf { pane_id } if pane_id == "activity")
                        );
                        assert_eq!(labels, &vec!["Ticket".to_string(), "Activity".to_string()]);
                        assert_eq!(*active, 1, "\"active: activity\" must resolve to index 1");
                    }
                    other => panic!("expected inner Tabs node, got {other:?}"),
                }
            }
            other => panic!("expected outer Split, got {other:?}"),
        }

        // And the converted tree passes the registry's own invariant checks.
        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("perri");
        reg.set_layout("perri", &serde_json::json!({ "tree": tree }))
            .expect("converted tabs tree should satisfy PaneRegistry invariants");
    }

    #[test]
    fn a_plain_split_still_parses_correctly_with_the_tabs_variant_listed_first() {
        // `SchemaNode` is `#[serde(untagged)]`, so variant order controls
        // fallthrough — `Tabs` is tried before `Split`/`Leaf`. A document with
        // no `tabs:` key at all must still fall through to `Split` correctly.
        let schema = compiled_in("perri-standard").expect("perri-standard should still parse");
        assert!(matches!(schema.tree, SchemaNode::Split { .. }));
    }

    #[test]
    fn a_plain_leaf_still_parses_correctly_with_the_tabs_variant_listed_first() {
        let yaml = r#"
name: just-repl
tree:
  pane: repl
panes: {}
"#;
        let schema = parse(yaml).expect("a bare leaf must still parse");
        assert!(matches!(schema.tree, SchemaNode::Leaf { pane } if pane == "repl"));
    }

    #[test]
    fn tabs_region_naming_repl_is_rejected_as_repl_in_tabs() {
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - tabs:
        - pane: repl
          label: Repl
        - pane: ticket
          label: Ticket
      active: repl
    - pane: sidebar
panes:
  ticket:
    content_kind: text
  sidebar:
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::ReplInTabs);
    }

    #[test]
    fn tabs_region_nested_inside_a_split_still_rejects_a_nested_repl() {
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: sidebar
    - direction: vertical
      ratios: [0.5, 0.5]
      children:
        - tabs:
            - pane: repl
              label: Repl
          active: repl
        - pane: ticket
panes:
  sidebar:
    content_kind: text
  ticket:
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(
            err,
            ApplyLayoutError::ReplInTabs,
            "the repl-in-tabs walk must recurse through nested splits"
        );
    }

    #[test]
    fn tree_with_two_repl_leaves_is_rejected_by_registry_validation() {
        // The DSL itself doesn't check for duplicate repl leaves — that's the
        // registry's job (reused, not reimplemented).
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: repl
    - pane: repl
panes: {}
"#;
        let schema = parse(yaml).expect("DSL-level parse succeeds; registry catches this");
        let tree = schema.tree.to_pane_tree();

        let mut reg = PaneRegistry::in_memory();
        reg.init_focus("perri");
        let err = reg
            .set_layout("perri", &serde_json::json!({ "tree": tree }))
            .unwrap_err();
        assert_eq!(err, crate::ipc::pane_registry::PaneError::InvalidLayout);
    }

    #[test]
    fn load_from_dir_prefers_on_disk_override() {
        let tmp = tempfile::TempDir::new().unwrap();
        let override_yaml = r#"
name: perri-standard
tree:
  pane: repl
panes: {}
"#;
        std::fs::write(tmp.path().join("perri-standard.yaml"), override_yaml).unwrap();

        let schema = load_from_dir("perri-standard", tmp.path()).unwrap();
        assert!(schema.panes.is_empty());
        assert!(matches!(schema.tree, SchemaNode::Leaf { .. }));
    }

    #[test]
    fn load_from_dir_falls_back_to_compiled_in_when_absent() {
        let tmp = tempfile::TempDir::new().unwrap();
        // No override file written; directory itself doesn't even exist.
        let schema = load_from_dir("perri-standard", tmp.path()).unwrap();
        assert_eq!(schema.panes.len(), 2);
    }

    #[test]
    fn load_from_dir_unknown_name_returns_unknown_layout() {
        let tmp = tempfile::TempDir::new().unwrap();
        let err = load_from_dir("does-not-exist", tmp.path()).unwrap_err();
        assert_eq!(err, ApplyLayoutError::UnknownLayout);
    }

    // ── pr_conversation content kind (W3 — curated-agent-views) ──────────────

    #[test]
    fn content_kind_is_valid_accepts_pr_conversation() {
        assert!(content_kind_is_valid("pr_conversation"));
    }

    #[test]
    fn a_schema_declaring_perri_get_pr_conversation_with_pr_conversation_content_kind_validates() {
        let yaml = r#"
name: ok
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: conversation
    - pane: repl
panes:
  conversation:
    source: perri.get_pr_conversation
    content_kind: pr_conversation
"#;
        let schema = parse(yaml).expect("a pr_conversation source/content_kind pair must validate");
        assert_eq!(schema.panes["conversation"].content_kind, "pr_conversation");
    }

    #[test]
    fn perri_get_pr_conversation_with_a_mismatched_content_kind_is_rejected() {
        let yaml = r#"
name: bad
tree:
  direction: horizontal
  ratios: [0.5, 0.5]
  children:
    - pane: conversation
    - pane: repl
panes:
  conversation:
    source: perri.get_pr_conversation
    content_kind: text
"#;
        let err = parse(yaml).unwrap_err();
        assert_eq!(err, ApplyLayoutError::InvalidContentKind);
    }
}
