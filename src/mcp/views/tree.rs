//! Pane-tree surgery for the curated view surface (W5 — curated-agent-views).
//!
//! Everything here is a pure transformation of a [`PaneTree`]: no registry, no
//! broadcast, no state. `tools::show` builds a whole new tree with these and
//! hands it to the existing `PaneRegistry::set_layout`, which is what makes the
//! registry's own invariant checks (exactly one `repl`, unique ids, well-formed
//! splits and tabs) apply to a curated show for free rather than being
//! reimplemented — and what makes an invalid intermediate impossible, since the
//! registry only ever sees a finished tree.
//!
//! The tabs node created here carries a `region` name (see
//! [`PaneTree::Tabs`]), which is how the placement engine finds "the detail
//! region" again on the next show and after a daemon restart.

use crate::ipc::pane_registry::SplitPosition;
use crate::ipc::protocol::{PaneTree, SplitDirection};

/// The tabs node for `region`, if the tree has one.
pub fn tabs_region<'a>(tree: &'a PaneTree, region: &str) -> Option<&'a PaneTree> {
    match tree {
        PaneTree::Tabs {
            region: Some(name), ..
        } if name == region => Some(tree),
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
            children.iter().find_map(|c| tabs_region(c, region))
        }
        PaneTree::Leaf { .. } => None,
    }
}

/// True when `pane_id` is a leaf of `tree`.
pub fn has_leaf(tree: &PaneTree, pane_id: &str) -> bool {
    tree.pane_ids().iter().any(|id| id == pane_id)
}

/// Build a tabs node for `region` from an ordered `(pane_id, label)` list.
pub fn build_tabs(region: &str, tabs: &[(String, String)], active: usize) -> PaneTree {
    PaneTree::Tabs {
        children: tabs
            .iter()
            .map(|(pane_id, _)| PaneTree::Leaf {
                pane_id: pane_id.clone(),
            })
            .collect(),
        labels: tabs.iter().map(|(_, label)| label.clone()).collect(),
        active: active.min(tabs.len().saturating_sub(1)),
        region: Some(region.to_string()),
    }
}

/// Replace `region`'s tabs node with `replacement`. Returns false when the tree
/// has no such region.
pub fn replace_tabs_region(tree: &mut PaneTree, region: &str, replacement: PaneTree) -> bool {
    if matches!(tree, PaneTree::Tabs { region: Some(name), .. } if name == region) {
        *tree = replacement;
        return true;
    }
    match tree {
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
            for child in children.iter_mut() {
                if replace_tabs_region(child, region, replacement.clone()) {
                    return true;
                }
            }
            false
        }
        PaneTree::Leaf { .. } => false,
    }
}

/// Split the leaf `relative_to` and put `node` on the side `position` names,
/// with `ratios` in child order. Returns false when the leaf isn't in the tree.
///
/// The generalisation of `PaneRegistry`'s own private `split_leaf`: that one
/// always inserts a bare leaf at a fixed 0.5/0.5, and a region's creation rule
/// gets to say both what goes in and how the space is divided.
pub fn insert_beside(
    tree: &mut PaneTree,
    relative_to: &str,
    position: SplitPosition,
    ratios: &[f32],
    node: PaneTree,
) -> bool {
    match tree {
        PaneTree::Leaf { pane_id } => {
            if pane_id != relative_to {
                return false;
            }
            let original = PaneTree::Leaf {
                pane_id: pane_id.clone(),
            };
            let children = if position.new_pane_first() {
                vec![node, original]
            } else {
                vec![original, node]
            };
            *tree = PaneTree::Split {
                direction: position.direction(),
                children,
                ratios: ratios.to_vec(),
            };
            true
        }
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
            for child in children.iter_mut() {
                if insert_beside(child, relative_to, position, ratios, node.clone()) {
                    return true;
                }
            }
            false
        }
    }
}

/// Remove `region`'s tabs node from the tree, collapsing the split that held it
/// (D5 — "the detail region … [is] removed when its last tab closes"). Returns
/// false when the tree has no such region.
///
/// A split left with one child collapses into that child rather than staying a
/// one-child split, because a one-child split fails the registry's own
/// `children.len() >= 2` invariant — the removal has to leave a tree that is
/// still valid, not one that merely has the node gone.
pub fn remove_tabs_region(tree: &mut PaneTree, region: &str) -> bool {
    remove_where(tree, &|node| {
        matches!(node, PaneTree::Tabs { region: Some(name), .. } if name == region)
    })
}

/// Remove the first node satisfying `pred`, collapsing its parent split. The
/// root itself is never removed — there would be nothing to leave behind.
fn remove_where(tree: &mut PaneTree, pred: &dyn Fn(&PaneTree) -> bool) -> bool {
    let children_ratios = match tree {
        PaneTree::Split {
            children, ratios, ..
        } => Some((children, Some(ratios))),
        PaneTree::Tabs { children, .. } => Some((children, None)),
        PaneTree::Leaf { .. } => None,
    };
    let Some((children, ratios)) = children_ratios else {
        return false;
    };

    if let Some(index) = children.iter().position(pred) {
        children.remove(index);
        if let Some(ratios) = ratios {
            if index < ratios.len() {
                ratios.remove(index);
            }
            normalise(ratios);
        }
        collapse_single_child(tree);
        return true;
    }

    let mut removed = false;
    for child in children.iter_mut() {
        if remove_where(child, pred) {
            removed = true;
            break;
        }
    }
    if removed {
        collapse_single_child(tree);
    }
    removed
}

/// A split or tabs node left holding exactly one child becomes that child.
fn collapse_single_child(node: &mut PaneTree) {
    let only = match node {
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } if children.len() == 1 => {
            Some(children.remove(0))
        }
        _ => None,
    };
    if let Some(child) = only {
        *node = child;
    }
}

/// Renormalise ratios to sum to 1.0, leaving them alone when they can't be
/// (an all-zero or empty list).
fn normalise(ratios: &mut [f32]) {
    let sum: f32 = ratios.iter().sum();
    if sum > 0.0 {
        for r in ratios.iter_mut() {
            *r /= sum;
        }
    }
}

/// Every pane id live in `tree`, as a set.
pub fn taken_pane_ids(tree: &PaneTree) -> std::collections::BTreeSet<String> {
    tree.pane_ids().into_iter().collect()
}

/// The direction / ordering helpers `insert_beside` needs from a
/// [`SplitPosition`], which `PaneRegistry` keeps private to itself.
trait SplitPositionExt {
    fn direction(self) -> SplitDirection;
    fn new_pane_first(self) -> bool;
}

impl SplitPositionExt for SplitPosition {
    fn direction(self) -> SplitDirection {
        match self {
            SplitPosition::Left | SplitPosition::Right => SplitDirection::Horizontal,
            SplitPosition::Above | SplitPosition::Below => SplitDirection::Vertical,
        }
    }

    fn new_pane_first(self) -> bool {
        matches!(self, SplitPosition::Left | SplitPosition::Above)
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(id: &str) -> PaneTree {
        PaneTree::Leaf {
            pane_id: id.to_string(),
        }
    }

    /// `perri-curated`'s starting tree.
    fn curated() -> PaneTree {
        PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![leaf("queue"), leaf("repl")],
            ratios: vec![0.6, 0.4],
        }
    }

    fn detail(tabs: &[&str], active: usize) -> PaneTree {
        build_tabs(
            "detail",
            &tabs
                .iter()
                .map(|t| (t.to_string(), t.to_uppercase()))
                .collect::<Vec<_>>(),
            active,
        )
    }

    // ── 1. build + find ───────────────────────────────────────────────────────

    #[test]
    fn a_built_tabs_node_carries_its_region_name_so_it_can_be_found_again() {
        let mut tree = curated();
        assert!(insert_beside(
            &mut tree,
            "queue",
            SplitPosition::Right,
            &[0.5, 0.5],
            detail(&["detail.0"], 0)
        ));
        assert!(tabs_region(&tree, "detail").is_some());
        assert!(tabs_region(&tree, "nope").is_none());
    }

    #[test]
    fn a_tabs_node_without_a_region_name_is_not_a_curated_region() {
        let tree = PaneTree::Tabs {
            children: vec![leaf("a"), leaf("b")],
            labels: vec!["A".into(), "B".into()],
            active: 0,
            region: None,
        };
        assert!(tabs_region(&tree, "detail").is_none());
    }

    #[test]
    fn build_tabs_clamps_an_out_of_range_active_index() {
        let node = build_tabs("detail", &[("a".into(), "A".into())], 7);
        assert!(matches!(node, PaneTree::Tabs { active: 0, .. }));
    }

    // ── 2. insert_beside ──────────────────────────────────────────────────────

    #[test]
    fn inserting_beside_the_queue_puts_the_region_on_the_named_side_with_the_named_ratios() {
        let mut tree = curated();
        insert_beside(
            &mut tree,
            "queue",
            SplitPosition::Right,
            &[0.4, 0.6],
            detail(&["detail.0"], 0),
        );
        let PaneTree::Split { children, .. } = &tree else {
            panic!("root stays a split")
        };
        let PaneTree::Split {
            direction,
            children: inner,
            ratios,
        } = &children[0]
        else {
            panic!("the queue leaf became a split")
        };
        assert_eq!(*direction, SplitDirection::Horizontal);
        assert_eq!(ratios, &vec![0.4, 0.6]);
        assert!(matches!(&inner[0], PaneTree::Leaf { pane_id } if pane_id == "queue"));
        assert!(tabs_region(&inner[1], "detail").is_some());
    }

    #[test]
    fn inserting_above_puts_the_new_node_first() {
        let mut tree = leaf("repl");
        insert_beside(
            &mut tree,
            "repl",
            SplitPosition::Above,
            &[0.6, 0.4],
            detail(&["detail.0"], 0),
        );
        let PaneTree::Split {
            direction, children, ..
        } = &tree
        else {
            panic!()
        };
        assert_eq!(*direction, SplitDirection::Vertical);
        assert!(tabs_region(&children[0], "detail").is_some());
        assert!(matches!(&children[1], PaneTree::Leaf { pane_id } if pane_id == "repl"));
    }

    #[test]
    fn inserting_beside_a_pane_that_is_not_in_the_tree_changes_nothing() {
        let mut tree = curated();
        let before = tree.clone();
        assert!(!insert_beside(
            &mut tree,
            "nope",
            SplitPosition::Right,
            &[0.5, 0.5],
            detail(&["detail.0"], 0)
        ));
        assert_eq!(tree, before);
    }

    // ── 3. replace ────────────────────────────────────────────────────────────

    #[test]
    fn replacing_a_region_swaps_only_that_node() {
        let mut tree = curated();
        insert_beside(
            &mut tree,
            "queue",
            SplitPosition::Right,
            &[0.5, 0.5],
            detail(&["detail.0"], 0),
        );
        assert!(replace_tabs_region(
            &mut tree,
            "detail",
            detail(&["detail.0", "detail.1"], 1)
        ));
        assert_eq!(tree.pane_ids(), vec!["queue", "detail.0", "detail.1", "repl"]);
        let PaneTree::Tabs { active, .. } = tabs_region(&tree, "detail").unwrap() else {
            panic!()
        };
        assert_eq!(*active, 1);
    }

    #[test]
    fn replacing_a_region_the_tree_does_not_have_changes_nothing() {
        let mut tree = curated();
        let before = tree.clone();
        assert!(!replace_tabs_region(
            &mut tree,
            "detail",
            detail(&["detail.0"], 0)
        ));
        assert_eq!(tree, before);
    }

    // ── 4. remove ─────────────────────────────────────────────────────────────

    #[test]
    fn removing_the_last_tab_region_collapses_the_split_that_held_it() {
        let mut tree = curated();
        insert_beside(
            &mut tree,
            "queue",
            SplitPosition::Right,
            &[0.5, 0.5],
            detail(&["detail.0"], 0),
        );
        assert!(remove_tabs_region(&mut tree, "detail"));
        assert_eq!(tree, curated(), "back to exactly the pre-show tree");
    }

    #[test]
    fn removing_a_region_renormalises_the_surviving_ratios() {
        let mut tree = PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![leaf("queue"), detail(&["detail.0"], 0), leaf("repl")],
            ratios: vec![0.3, 0.3, 0.4],
        };
        assert!(remove_tabs_region(&mut tree, "detail"));
        let PaneTree::Split { ratios, .. } = &tree else {
            panic!()
        };
        assert_eq!(ratios.len(), 2);
        assert!((ratios.iter().sum::<f32>() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn removing_a_region_the_tree_does_not_have_changes_nothing() {
        let mut tree = curated();
        let before = tree.clone();
        assert!(!remove_tabs_region(&mut tree, "detail"));
        assert_eq!(tree, before);
    }

    #[test]
    fn a_region_created_and_removed_leaves_the_repl_invariant_intact() {
        let mut tree = leaf("repl");
        insert_beside(
            &mut tree,
            "repl",
            SplitPosition::Above,
            &[0.6, 0.4],
            detail(&["detail.0"], 0),
        );
        assert_eq!(
            tree.pane_ids().iter().filter(|id| *id == "repl").count(),
            1
        );
        remove_tabs_region(&mut tree, "detail");
        assert_eq!(tree, leaf("repl"));
    }

    // ── 5. taken ids ──────────────────────────────────────────────────────────

    #[test]
    fn taken_pane_ids_includes_every_leaf_including_the_repl_and_tab_children() {
        let mut tree = curated();
        insert_beside(
            &mut tree,
            "queue",
            SplitPosition::Right,
            &[0.5, 0.5],
            detail(&["detail.0", "detail.1"], 0),
        );
        let ids = taken_pane_ids(&tree);
        for id in ["queue", "repl", "detail.0", "detail.1"] {
            assert!(ids.contains(id), "{id}");
        }
        assert!(has_leaf(&tree, "detail.1"));
        assert!(!has_leaf(&tree, "detail.2"));
    }
}
