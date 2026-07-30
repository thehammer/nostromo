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
const VALID_CONTENT_KINDS: [&str; 5] = ["text", "json_snapshot", "pr_list", "loading", "error"];

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

/// A node in the DSL tree: either an interior split or a leaf pane reference.
///
/// Untagged: a leaf is `{ pane: "queue" }`; a split is `{ direction, ratios,
/// children }`. Serde tries `Split` first and falls back to `Leaf` when the
/// split fields are absent.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum SchemaNode {
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
    /// structural — the registry's own `set_layout` validates the result.
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
/// the `repl` leaf must not appear in `panes`, every `content_kind` must be a
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
}
