//! Where the tracker pane goes in a focus's layout (contract §6).
//!
//! Placement is a product rule, never the agent's call: `nostromo.tracker`
//! names no position. These functions are pure over [`PaneTree`]: the tool
//! applies them (once, on a focus's first `open`), and `init_focus` uses
//! [`reattach_tracker`] so a fresh session keeps the pane where it was.
//!
//! The tracker is the leaf with the reserved pane id [`TRACKER_PANE_ID`]. Its
//! label, when it is a tab, is the literal [`TRACKER_LABEL`], never the board's
//! title: the tree reaches TCP peers.

use crate::ipc::protocol::{PaneTree, SplitDirection};

/// The reserved pane id of the tracker leaf.
pub const TRACKER_PANE_ID: &str = "tracker";

/// The tracker tab's label, in every tree.
pub const TRACKER_LABEL: &str = "Tracker";

/// `[transcript, tracker]`: the transcript keeps at least 62% of the width.
pub const TRACKER_SPLIT_RATIOS: [f32; 2] = [0.66, 0.34];

const REPL_PANE_ID: &str = "repl";
const QUEUE_PANE_ID: &str = "queue";
const DETAIL_REGION: &str = "detail";

/// Whether `tree` has the tracker leaf.
pub fn has_tracker(tree: &PaneTree) -> bool {
    tree.pane_ids().iter().any(|id| id == TRACKER_PANE_ID)
}

/// The tree with the tracker added, or `None` when it is already there (or the
/// tree has nowhere to put it: no detail region and no `repl` leaf).
///
/// - A `detail` tabs region gets a `Tracker` tab, right after the `queue` tab
///   when there is one, and it becomes the frontmost tab. This only ever runs
///   on a focus's first creation of the pane.
/// - Otherwise the `repl` leaf becomes `repl | tracker`, side by side, the
///   transcript on the left.
pub fn place_tracker(tree: &PaneTree) -> Option<PaneTree> {
    if has_tracker(tree) {
        return None;
    }
    let mut placed = tree.clone();
    if add_detail_tab(&mut placed)
        || split_beside_repl(
            &mut placed,
            TRACKER_SPLIT_RATIOS.to_vec(),
            SplitDirection::Horizontal,
        )
    {
        Some(placed)
    } else {
        None
    }
}

/// `baseline` (a fresh session's layout) with the tracker back where
/// `previous` had it.
///
/// When `previous` had `tracker` as the right-hand sibling of `repl` in a
/// split, the baseline gets that same split (direction and ratios), so the Mac's
/// topology-keyed saved ratio still applies. When it was anywhere else (a
/// detail tab: the clean rebuild drops the region), it falls back to the
/// default split. When `previous` had no tracker, the baseline is returned
/// unchanged.
pub fn reattach_tracker(baseline: &PaneTree, previous: &PaneTree) -> PaneTree {
    if !has_tracker(previous) || has_tracker(baseline) {
        return baseline.clone();
    }
    let (direction, ratios) = repl_tracker_split(previous)
        .unwrap_or((SplitDirection::Horizontal, TRACKER_SPLIT_RATIOS.to_vec()));
    let mut tree = baseline.clone();
    split_beside_repl(&mut tree, ratios, direction);
    tree
}

/// `tree` without the tracker, or `None` when it has none or removing it would
/// leave nothing. A split left with one child collapses into it and the
/// remaining ratios are renormalised.
pub fn remove_tracker(tree: &PaneTree) -> Option<PaneTree> {
    let mut out = tree.clone();
    if out.remove_tab(TRACKER_PANE_ID) {
        return Some(out);
    }
    remove_split_leaf(&mut out).then_some(out)
}

// ── tree surgery ─────────────────────────────────────────────────────────────

/// Adds the `Tracker` tab to the first `detail` tabs node.
fn add_detail_tab(node: &mut PaneTree) -> bool {
    match node {
        PaneTree::Tabs {
            children,
            labels,
            active,
            region: Some(name),
        } if name == DETAIL_REGION => {
            let after_queue = children
                .iter()
                .position(|c| matches!(c, PaneTree::Leaf { pane_id } if pane_id == QUEUE_PANE_ID))
                .map(|i| i + 1);
            let at = after_queue.unwrap_or(children.len());
            children.insert(
                at,
                PaneTree::Leaf {
                    pane_id: TRACKER_PANE_ID.to_string(),
                },
            );
            labels.insert(at.min(labels.len()), TRACKER_LABEL.to_string());
            *active = at;
            true
        }
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => {
            children.iter_mut().any(add_detail_tab)
        }
        PaneTree::Leaf { .. } => false,
    }
}

/// Replaces the `repl` leaf with `[repl, tracker]`.
fn split_beside_repl(node: &mut PaneTree, ratios: Vec<f32>, direction: SplitDirection) -> bool {
    match node {
        PaneTree::Leaf { pane_id } if pane_id == REPL_PANE_ID => {
            *node = PaneTree::Split {
                direction,
                children: vec![
                    PaneTree::repl_leaf(),
                    PaneTree::Leaf {
                        pane_id: TRACKER_PANE_ID.to_string(),
                    },
                ],
                ratios,
            };
            true
        }
        PaneTree::Split { children, .. } | PaneTree::Tabs { children, .. } => children
            .iter_mut()
            .any(|c| split_beside_repl(c, ratios.clone(), direction)),
        PaneTree::Leaf { .. } => false,
    }
}

/// The direction and ratios of the split that holds `repl` with `tracker`
/// right after it.
fn repl_tracker_split(node: &PaneTree) -> Option<(SplitDirection, Vec<f32>)> {
    match node {
        PaneTree::Split {
            direction,
            children,
            ratios,
        } => {
            let is =
                |c: &PaneTree, id: &str| matches!(c, PaneTree::Leaf { pane_id } if pane_id == id);
            let beside = children
                .windows(2)
                .any(|w| is(&w[0], REPL_PANE_ID) && is(&w[1], TRACKER_PANE_ID));
            if beside {
                return Some((*direction, ratios.clone()));
            }
            children.iter().find_map(repl_tracker_split)
        }
        PaneTree::Tabs { children, .. } => children.iter().find_map(repl_tracker_split),
        PaneTree::Leaf { .. } => None,
    }
}

/// What removing the tracker leaf from a subtree did.
enum Gone {
    /// It is not in this subtree.
    NotFound,
    /// It was removed and the node still stands.
    Removed,
    /// It was the node's last child: the parent drops the node.
    NodeEmptied,
}

fn is_tracker(node: &PaneTree) -> bool {
    matches!(node, PaneTree::Leaf { pane_id } if pane_id == TRACKER_PANE_ID)
}

/// Removes the `tracker` leaf from wherever it sits: a split's child, a tab, or
/// any of those nested in any of those. A node left with nothing goes too, a
/// split left with one child collapses into it, and its ratios are renormalised.
/// A root that holds nothing but the tracker would be emptied: that is not a
/// removal (`false`), matching `remove_tracker`'s "would leave nothing". The
/// caller works on a copy it drops then, so no half-emptied tree escapes.
fn remove_split_leaf(node: &mut PaneTree) -> bool {
    matches!(remove_leaf(node), Gone::Removed)
}

fn remove_leaf(node: &mut PaneTree) -> Gone {
    match node {
        PaneTree::Leaf { .. } => Gone::NotFound,
        PaneTree::Split {
            children, ratios, ..
        } => {
            for i in 0..children.len() {
                let hit = if is_tracker(&children[i]) {
                    Gone::NodeEmptied
                } else {
                    remove_leaf(&mut children[i])
                };
                match hit {
                    Gone::NotFound => continue,
                    Gone::Removed => return Gone::Removed,
                    Gone::NodeEmptied => {
                        children.remove(i);
                        if i < ratios.len() {
                            ratios.remove(i);
                        }
                        let sum: f32 = ratios.iter().sum();
                        if sum > 0.0 {
                            ratios.iter_mut().for_each(|r| *r /= sum);
                        }
                        match children.len() {
                            0 => return Gone::NodeEmptied,
                            1 => {
                                let only = children.remove(0);
                                *node = only;
                            }
                            _ => {}
                        }
                        return Gone::Removed;
                    }
                }
            }
            Gone::NotFound
        }
        PaneTree::Tabs {
            children,
            labels,
            active,
            ..
        } => {
            for i in 0..children.len() {
                let hit = if is_tracker(&children[i]) {
                    Gone::NodeEmptied
                } else {
                    remove_leaf(&mut children[i])
                };
                match hit {
                    Gone::NotFound => continue,
                    Gone::Removed => return Gone::Removed,
                    Gone::NodeEmptied => {
                        children.remove(i);
                        if i < labels.len() {
                            labels.remove(i);
                        }
                        if children.is_empty() {
                            return Gone::NodeEmptied;
                        }
                        if i < *active {
                            *active -= 1;
                        }
                        *active = (*active).min(children.len() - 1);
                        return Gone::Removed;
                    }
                }
            }
            Gone::NotFound
        }
    }
}

#[cfg(test)]
mod tests {
    //! Behaviour of the placement rules over plain trees (contract §6). Each
    //! test states a product rule; none looks at how the surgery is done.
    use super::*;

    fn leaf(id: &str) -> PaneTree {
        PaneTree::Leaf {
            pane_id: id.to_string(),
        }
    }

    fn split(direction: SplitDirection, children: Vec<PaneTree>, ratios: Vec<f32>) -> PaneTree {
        PaneTree::Split {
            direction,
            children,
            ratios,
        }
    }

    fn detail(tabs: &[(&str, &str)], active: usize) -> PaneTree {
        PaneTree::Tabs {
            children: tabs.iter().map(|(id, _)| leaf(id)).collect(),
            labels: tabs.iter().map(|(_, l)| l.to_string()).collect(),
            active,
            region: Some("detail".to_string()),
        }
    }

    /// The curated-Perri shape: the detail region above the REPL.
    fn curated(tabs: &[(&str, &str)], active: usize) -> PaneTree {
        split(
            SplitDirection::Vertical,
            vec![detail(tabs, active), leaf("repl")],
            vec![0.6, 0.4],
        )
    }

    fn repl_tracker() -> PaneTree {
        split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.66, 0.34],
        )
    }

    fn tabs_of(tree: &PaneTree) -> (&Vec<PaneTree>, &Vec<String>, usize) {
        match tree {
            PaneTree::Split { children, .. } => children.iter().find_map(|c| match c {
                PaneTree::Tabs {
                    children,
                    labels,
                    active,
                    ..
                } => Some((children, labels, *active)),
                _ => None,
            }),
            PaneTree::Tabs {
                children,
                labels,
                active,
                ..
            } => Some((children, labels, *active)),
            PaneTree::Leaf { .. } => None,
        }
        .expect("a tabs node")
    }

    fn ids(tree: &PaneTree) -> Vec<String> {
        tree.pane_ids()
    }

    fn assert_ratios(actual: &[f32], expected: &[f32]) {
        assert_eq!(actual.len(), expected.len(), "{actual:?} vs {expected:?}");
        for (a, e) in actual.iter().zip(expected) {
            assert!((a - e).abs() < 1e-5, "{actual:?} vs {expected:?}");
        }
    }

    // ── place_tracker ────────────────────────────────────────────────────────

    #[test]
    fn a_bare_repl_becomes_repl_beside_tracker_with_the_transcript_on_the_left() {
        let placed = place_tracker(&PaneTree::repl_leaf()).expect("placed");
        assert_eq!(placed, repl_tracker());
        let PaneTree::Split { ratios, .. } = &placed else {
            panic!("split")
        };
        assert!(
            ratios[0] >= 0.62,
            "the transcript keeps at least 62%: {ratios:?}"
        );
    }

    #[test]
    fn with_a_detail_region_the_tracker_is_a_labelled_tab_right_after_queue_and_frontmost() {
        let before = curated(
            &[
                ("queue", "Queue"),
                ("detail.0", "a.rs"),
                ("detail.1", "b.rs"),
            ],
            2,
        );
        let placed = place_tracker(&before).expect("placed");

        let (children, labels, active) = tabs_of(&placed);
        assert_eq!(
            children
                .iter()
                .flat_map(|c| c.pane_ids())
                .collect::<Vec<_>>(),
            ["queue", "tracker", "detail.0", "detail.1"]
        );
        assert_eq!(labels, &["Queue", "Tracker", "a.rs", "b.rs"]);
        assert_eq!(active, 1, "the tracker tab is frontmost on creation");
        // Everything outside the tab list is as it was.
        let PaneTree::Split {
            direction,
            ratios,
            children: top,
        } = &placed
        else {
            panic!("split")
        };
        assert_eq!(*direction, SplitDirection::Vertical);
        assert_ratios(ratios, &[0.6, 0.4]);
        assert_eq!(top[1], leaf("repl"));
        let PaneTree::Tabs { region, .. } = &top[0] else {
            panic!("tabs")
        };
        assert_eq!(region.as_deref(), Some("detail"));
    }

    #[test]
    fn the_tab_label_is_the_literal_tracker_and_nothing_else() {
        let placed = place_tracker(&curated(&[("queue", "Queue")], 0)).unwrap();
        let (_, labels, _) = tabs_of(&placed);
        assert_eq!(labels[1], "Tracker");
        assert_eq!(TRACKER_LABEL, "Tracker");
        assert_eq!(TRACKER_PANE_ID, "tracker");
    }

    #[test]
    fn a_detail_region_without_queue_gets_the_tracker_appended() {
        let before = curated(&[("detail.0", "a.rs"), ("detail.1", "b.rs")], 0);
        let placed = place_tracker(&before).expect("placed");
        let (children, labels, active) = tabs_of(&placed);
        assert_eq!(
            children
                .iter()
                .flat_map(|c| c.pane_ids())
                .collect::<Vec<_>>(),
            ["detail.0", "detail.1", "tracker"]
        );
        assert_eq!(labels, &["a.rs", "b.rs", "Tracker"]);
        assert_eq!(active, 2);
    }

    #[test]
    fn a_tree_that_already_has_the_tracker_is_left_alone() {
        assert_eq!(place_tracker(&repl_tracker()), None);
        let tab = curated(&[("queue", "Queue"), ("tracker", "Tracker")], 1);
        assert_eq!(place_tracker(&tab), None);
    }

    #[test]
    fn a_repl_nested_in_a_split_is_split_in_place_and_its_siblings_stay_put() {
        let before = split(
            SplitDirection::Vertical,
            vec![leaf("diff"), leaf("repl")],
            vec![0.7, 0.3],
        );
        let placed = place_tracker(&before).expect("placed");
        let expected = split(
            SplitDirection::Vertical,
            vec![leaf("diff"), repl_tracker()],
            vec![0.7, 0.3],
        );
        assert_eq!(placed, expected);
    }

    #[test]
    fn a_tree_with_neither_a_detail_region_nor_a_repl_has_nowhere_to_put_it() {
        assert_eq!(place_tracker(&leaf("mother")), None);
    }

    #[test]
    fn placing_never_disturbs_the_input_tree() {
        let before = curated(&[("queue", "Queue")], 0);
        let copy = before.clone();
        let _ = place_tracker(&before);
        assert_eq!(before, copy);
    }

    #[test]
    fn perris_compiled_in_layouts_take_the_tracker_and_give_it_back_unchanged() {
        let nowhere = std::path::Path::new("/nonexistent-nostromo-layouts-for-tests");
        for name in ["perri-curated", "perri-standard"] {
            let tree = crate::mcp::layout_schema::load_from_dir(name, nowhere)
                .unwrap_or_else(|_| panic!("{name} loads"))
                .tree
                .to_pane_tree();
            let placed = place_tracker(&tree).unwrap_or_else(|| panic!("{name} takes the tracker"));
            assert!(
                ids(&placed).contains(&"tracker".to_string()),
                "{name}: {placed:?}"
            );
            assert_eq!(remove_tracker(&placed), Some(tree), "{name} round-trips");
        }
    }

    #[test]
    fn perri_curated_gets_the_tracker_as_the_tab_after_queue() {
        let nowhere = std::path::Path::new("/nonexistent-nostromo-layouts-for-tests");
        let tree = crate::mcp::layout_schema::load_from_dir("perri-curated", nowhere)
            .unwrap()
            .tree
            .to_pane_tree();
        let placed = place_tracker(&tree).unwrap();
        let (children, labels, active) = tabs_of(&placed);
        assert_eq!(children[0].pane_ids(), ["queue"]);
        assert_eq!(children[1].pane_ids(), ["tracker"]);
        assert_eq!(labels[1], "Tracker");
        assert_eq!(active, 1);
    }

    // ── reattach_tracker ─────────────────────────────────────────────────────

    #[test]
    fn a_fresh_session_gets_the_same_split_ratios_the_user_dragged() {
        let previous = split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.5, 0.5],
        );
        assert_eq!(
            reattach_tracker(&PaneTree::repl_leaf(), &previous),
            previous
        );
    }

    #[test]
    fn a_fresh_session_keeps_the_previous_splits_direction() {
        let previous = split(
            SplitDirection::Vertical,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.3, 0.7],
        );
        assert_eq!(
            reattach_tracker(&PaneTree::repl_leaf(), &previous),
            previous
        );
    }

    #[test]
    fn the_split_is_found_when_it_was_nested_in_the_previous_tree() {
        let previous = split(
            SplitDirection::Vertical,
            vec![
                detail(&[("queue", "Queue")], 0),
                split(
                    SplitDirection::Horizontal,
                    vec![leaf("repl"), leaf("tracker")],
                    vec![0.7, 0.3],
                ),
            ],
            vec![0.6, 0.4],
        );
        let expected = split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.7, 0.3],
        );
        assert_eq!(
            reattach_tracker(&PaneTree::repl_leaf(), &previous),
            expected
        );
    }

    #[test]
    fn a_tracker_that_was_a_detail_tab_comes_back_as_the_default_split() {
        let previous = curated(&[("queue", "Queue"), ("tracker", "Tracker")], 1);
        assert_eq!(
            reattach_tracker(&PaneTree::repl_leaf(), &previous),
            repl_tracker()
        );
    }

    #[test]
    fn a_previous_tree_without_a_tracker_leaves_the_baseline_unchanged() {
        let previous = curated(&[("queue", "Queue")], 0);
        assert_eq!(
            reattach_tracker(&PaneTree::repl_leaf(), &previous),
            PaneTree::repl_leaf()
        );
        let baseline = curated(&[("queue", "Queue")], 0);
        assert_eq!(reattach_tracker(&baseline, &previous), baseline);
    }

    #[test]
    fn the_tracker_is_re_attached_beside_the_repl_of_a_richer_baseline() {
        let baseline = curated(&[("queue", "Queue")], 0);
        let previous = split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.55, 0.45],
        );
        let out = reattach_tracker(&baseline, &previous);
        let expected = split(
            SplitDirection::Vertical,
            vec![
                detail(&[("queue", "Queue")], 0),
                split(
                    SplitDirection::Horizontal,
                    vec![leaf("repl"), leaf("tracker")],
                    vec![0.55, 0.45],
                ),
            ],
            vec![0.6, 0.4],
        );
        assert_eq!(out, expected);
    }

    // ── remove_tracker: wherever the tracker sits ────────────────────────────

    #[test]
    fn a_tracker_tab_nested_in_another_tabs_node_is_removed() {
        let tree = PaneTree::Tabs {
            children: vec![
                leaf("queue"),
                PaneTree::Tabs {
                    children: vec![leaf("tracker"), leaf("notes")],
                    labels: vec!["Tracker".into(), "Notes".into()],
                    active: 0,
                    region: None,
                },
            ],
            labels: vec!["Queue".into(), "More".into()],
            active: 1,
            region: Some("detail".into()),
        };
        let out = remove_tracker(&tree).expect("removed");
        assert!(!has_tracker(&out));
        assert!(
            out.pane_ids().contains(&"notes".to_string()),
            "the rest stays: {out:?}"
        );
    }

    #[test]
    fn a_tabs_node_holding_only_the_tracker_goes_with_it_inside_a_tabs_node() {
        let tree = PaneTree::Tabs {
            children: vec![
                leaf("queue"),
                PaneTree::Tabs {
                    children: vec![leaf("tracker")],
                    labels: vec!["Tracker".into()],
                    active: 0,
                    region: None,
                },
            ],
            labels: vec!["Queue".into(), "Tracker".into()],
            active: 1,
            region: Some("detail".into()),
        };
        let out = remove_tracker(&tree).expect("removed");
        match out {
            PaneTree::Tabs {
                children,
                labels,
                active,
                ..
            } => {
                assert_eq!(children, vec![leaf("queue")]);
                assert_eq!(labels, vec!["Queue".to_string()]);
                assert_eq!(active, 0);
            }
            other => panic!("unexpected tree: {other:?}"),
        }
    }

    #[test]
    fn a_tracker_split_side_under_a_tabs_node_under_a_tabs_node_is_removed() {
        let inner = split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker")],
            vec![0.66, 0.34],
        );
        let tree = PaneTree::Tabs {
            children: vec![PaneTree::Tabs {
                children: vec![inner, leaf("queue")],
                labels: vec!["A".into(), "B".into()],
                active: 0,
                region: None,
            }],
            labels: vec!["Outer".into()],
            active: 0,
            region: None,
        };
        let out = remove_tracker(&tree).expect("removed");
        assert!(!has_tracker(&out));
        assert!(out.pane_ids().contains(&"repl".to_string()));
    }

    // ── remove_tracker ───────────────────────────────────────────────────────

    #[test]
    fn removing_the_tracker_from_a_two_way_split_collapses_to_the_repl() {
        assert_eq!(remove_tracker(&repl_tracker()), Some(PaneTree::repl_leaf()));
    }

    #[test]
    fn removing_the_tracker_from_a_nested_split_collapses_only_that_split() {
        let tree = split(
            SplitDirection::Vertical,
            vec![leaf("diff"), repl_tracker()],
            vec![0.7, 0.3],
        );
        let expected = split(
            SplitDirection::Vertical,
            vec![leaf("diff"), leaf("repl")],
            vec![0.7, 0.3],
        );
        assert_eq!(remove_tracker(&tree), Some(expected));
    }

    #[test]
    fn removing_a_split_child_renormalises_the_remaining_ratios() {
        let tree = split(
            SplitDirection::Horizontal,
            vec![leaf("repl"), leaf("tracker"), leaf("other")],
            vec![0.5, 0.3, 0.2],
        );
        let out = remove_tracker(&tree).expect("removed");
        let PaneTree::Split {
            children, ratios, ..
        } = &out
        else {
            panic!("still a split")
        };
        assert_eq!(children, &vec![leaf("repl"), leaf("other")]);
        assert_ratios(ratios, &[0.5 / 0.7, 0.2 / 0.7]);
        assert!((ratios.iter().sum::<f32>() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn removing_the_tracker_tab_leaves_the_other_tabs_and_labels_alone() {
        let tree = curated(
            &[
                ("queue", "Queue"),
                ("tracker", "Tracker"),
                ("detail.0", "a.rs"),
            ],
            1,
        );
        let out = remove_tracker(&tree).expect("removed");
        let (children, labels, active) = tabs_of(&out);
        assert_eq!(
            children
                .iter()
                .flat_map(|c| c.pane_ids())
                .collect::<Vec<_>>(),
            ["queue", "detail.0"]
        );
        assert_eq!(labels, &["Queue", "a.rs"]);
        assert!(active < 2);
    }

    #[test]
    fn removing_from_a_tree_without_a_tracker_changes_nothing() {
        assert_eq!(remove_tracker(&PaneTree::repl_leaf()), None);
        assert_eq!(remove_tracker(&curated(&[("queue", "Queue")], 0)), None);
    }

    #[test]
    fn a_root_split_holding_only_the_tracker_has_nothing_to_remove_it_into() {
        let tree = split(SplitDirection::Horizontal, vec![leaf("tracker")], vec![1.0]);
        let before = tree.clone();

        assert_eq!(remove_tracker(&tree), None);
        assert_eq!(tree, before, "the caller's tree is left as it was");
    }

    #[test]
    fn a_root_tabs_node_holding_only_the_tracker_has_nothing_to_remove_it_into() {
        let tree = detail(&[("tracker", "Tracker")], 0);
        let before = tree.clone();

        assert_eq!(remove_tracker(&tree), None);
        assert_eq!(tree, before, "the caller's tree is left as it was");
    }

    #[test]
    fn a_split_holding_only_the_tracker_inside_another_split_goes_and_the_outer_collapses() {
        let tree = split(
            SplitDirection::Vertical,
            vec![
                split(SplitDirection::Horizontal, vec![leaf("tracker")], vec![1.0]),
                leaf("repl"),
            ],
            vec![0.4, 0.6],
        );

        assert_eq!(remove_tracker(&tree), Some(PaneTree::repl_leaf()));
    }

    #[test]
    fn placing_then_removing_returns_the_original_tree() {
        for tree in [
            PaneTree::repl_leaf(),
            curated(&[("queue", "Queue"), ("detail.0", "a.rs")], 1),
            curated(&[("detail.0", "a.rs")], 0),
            split(
                SplitDirection::Vertical,
                vec![leaf("diff"), leaf("repl")],
                vec![0.7, 0.3],
            ),
        ] {
            let placed = place_tracker(&tree).expect("placed");
            assert_eq!(remove_tracker(&placed), Some(tree.clone()), "{tree:?}");
        }
    }
}
