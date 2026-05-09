//! Recursive layout tree for split-pane support.
//!
//! The tree is a binary tree of [`LayoutNode`]s.  Internal nodes hold a split
//! direction and a ratio (0–100, meaning percentage for child `a`).  Leaf nodes
//! hold a view index into `App::views`.
//!
//! Navigation through the tree is done via a `Vec<Side>` path — each element
//! is a left/right (A/B) turn.  An empty path identifies the root, or the only
//! leaf in a single-pane layout.

use ratatui::layout::Rect;
use serde::{Deserialize, Serialize};

// ── public types ──────────────────────────────────────────────────────────────

/// Which side of a split the focus path turns toward.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Side {
    A,
    B,
}

/// Axis of a split.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SplitDir {
    /// Left pane / right pane.
    Horizontal,
    /// Top pane / bottom pane.
    Vertical,
}

/// One node in the layout tree.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum LayoutNode {
    Leaf {
        view_idx: usize,
    },
    Split {
        dir: SplitDir,
        /// Percentage of the area given to child `a` (0–100).
        ratio: u16,
        a: Box<LayoutNode>,
        b: Box<LayoutNode>,
    },
}

impl LayoutNode {
    // ── geometry ──────────────────────────────────────────────────────────────

    /// Walk the tree and return `(view_idx, rect)` pairs for every leaf,
    /// calculated by subdividing `area` according to split ratios.
    pub fn rects(&self, area: Rect) -> Vec<(usize, Rect)> {
        match self {
            LayoutNode::Leaf { view_idx } => vec![(*view_idx, area)],
            LayoutNode::Split { dir, ratio, a, b } => {
                let (rect_a, rect_b) = split_rect(area, *dir, *ratio);
                let mut out = a.rects(rect_a);
                out.extend(b.rects(rect_b));
                out
            }
        }
    }

    // ── navigation ────────────────────────────────────────────────────────────

    /// Return the view index at the leaf identified by `path`.
    ///
    /// If `path` goes deeper than the tree or leads to a non-existent branch,
    /// we return the view index of the current node (defensive fallback).
    pub fn focused_view_idx(&self, path: &[Side]) -> usize {
        match (self, path.first()) {
            (LayoutNode::Leaf { view_idx }, _) => *view_idx,
            (LayoutNode::Split { a, b, .. }, Some(side)) => {
                let child = if *side == Side::A {
                    a.as_ref()
                } else {
                    b.as_ref()
                };
                child.focused_view_idx(&path[1..])
            }
            (LayoutNode::Split { a, .. }, None) => {
                // Path ended at an internal node — go left.
                a.focused_view_idx(&[])
            }
        }
    }

    /// Collect the view indices of all leaves in depth-first order.
    pub fn all_view_indices(&self) -> Vec<usize> {
        match self {
            LayoutNode::Leaf { view_idx } => vec![*view_idx],
            LayoutNode::Split { a, b, .. } => {
                let mut v = a.all_view_indices();
                v.extend(b.all_view_indices());
                v
            }
        }
    }

    /// Count the number of leaves.
    pub fn leaf_count(&self) -> usize {
        match self {
            LayoutNode::Leaf { .. } => 1,
            LayoutNode::Split { a, b, .. } => a.leaf_count() + b.leaf_count(),
        }
    }

    // ── mutation ──────────────────────────────────────────────────────────────

    /// Split the leaf at `path`, creating a new split node that holds the
    /// existing leaf in child `a` and a new leaf (with `new_view_idx`) in `b`.
    pub fn split(&mut self, path: &[Side], dir: SplitDir, new_view_idx: usize) {
        match self {
            LayoutNode::Leaf { view_idx } => {
                // Replace this leaf with a split.
                let existing = LayoutNode::Leaf {
                    view_idx: *view_idx,
                };
                let fresh = LayoutNode::Leaf {
                    view_idx: new_view_idx,
                };
                *self = LayoutNode::Split {
                    dir,
                    ratio: 50,
                    a: Box::new(existing),
                    b: Box::new(fresh),
                };
            }
            LayoutNode::Split { a, b, .. } => {
                match path.first() {
                    Some(Side::A) => a.split(&path[1..], dir, new_view_idx),
                    Some(Side::B) => b.split(&path[1..], dir, new_view_idx),
                    None => {
                        // Path exhausted at internal node — descend into A.
                        a.split(&[], dir, new_view_idx);
                    }
                }
            }
        }
    }

    /// Close the leaf at `path`, replacing its parent split with the *other*
    /// child.  If `path` is empty and `self` is already a leaf, this is a
    /// no-op (you cannot close the last pane).
    pub fn close(&mut self, path: &[Side]) {
        match path.first() {
            None => {
                // Already at root — cannot close.
            }
            Some(side) => {
                if let LayoutNode::Split { a, b, .. } = self {
                    // If the next step leads to a leaf at exactly path[1..],
                    // replace self with the sibling.
                    let target_is_leaf = match side {
                        Side::A => matches!(a.as_ref(), LayoutNode::Leaf { .. }) && path.len() == 1,
                        Side::B => matches!(b.as_ref(), LayoutNode::Leaf { .. }) && path.len() == 1,
                    };

                    if target_is_leaf {
                        let sibling = match side {
                            Side::A => *b.clone(),
                            Side::B => *a.clone(),
                        };
                        *self = sibling;
                    } else {
                        // Recurse deeper.
                        let child = if *side == Side::A {
                            a.as_mut()
                        } else {
                            b.as_mut()
                        };
                        child.close(&path[1..]);
                    }
                }
            }
        }
    }

    /// Return the rect of the focused leaf identified by `path`.
    pub fn focused_rect(&self, area: Rect, path: &[Side]) -> Rect {
        for (idx, rect) in self.rects(area) {
            if idx == self.focused_view_idx(path) {
                return rect;
            }
        }
        area
    }
}

// ── geometry helpers ──────────────────────────────────────────────────────────

/// Split `area` along `dir` with `ratio` percent going to the first child.
fn split_rect(area: Rect, dir: SplitDir, ratio: u16) -> (Rect, Rect) {
    let ratio = ratio.min(100) as u32;
    match dir {
        SplitDir::Horizontal => {
            let w_a = ((area.width as u32 * ratio) / 100) as u16;
            let w_b = area.width.saturating_sub(w_a);
            let rect_a = Rect { width: w_a, ..area };
            let rect_b = Rect {
                x: area.x + w_a,
                width: w_b,
                ..area
            };
            (rect_a, rect_b)
        }
        SplitDir::Vertical => {
            let h_a = ((area.height as u32 * ratio) / 100) as u16;
            let h_b = area.height.saturating_sub(h_a);
            let rect_a = Rect {
                height: h_a,
                ..area
            };
            let rect_b = Rect {
                y: area.y + h_a,
                height: h_b,
                ..area
            };
            (rect_a, rect_b)
        }
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(w: u16, h: u16) -> Rect {
        Rect {
            x: 0,
            y: 0,
            width: w,
            height: h,
        }
    }

    #[test]
    fn single_leaf_rects() {
        let node = LayoutNode::Leaf { view_idx: 0 };
        let r = node.rects(rect(80, 24));
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].0, 0);
        assert_eq!(r[0].1, rect(80, 24));
    }

    #[test]
    fn three_pane_horizontal_split_rects() {
        // Root: horizontal 50/50
        //   a: leaf(0)
        //   b: horizontal 50/50
        //       ba: leaf(1)
        //       bb: leaf(2)
        let mut root = LayoutNode::Leaf { view_idx: 0 };
        root.split(&[], SplitDir::Horizontal, 1);
        root.split(&[Side::B], SplitDir::Horizontal, 2);

        let pairs = root.rects(rect(100, 24));
        assert_eq!(pairs.len(), 3);

        // Leaf 0 gets left half (0..50).
        let (idx0, r0) = pairs[0];
        assert_eq!(idx0, 0);
        assert_eq!(r0.x, 0);
        assert_eq!(r0.width, 50);

        // Leaf 1 and 2 share the right 50 columns.
        let (idx1, r1) = pairs[1];
        let (idx2, r2) = pairs[2];
        assert_eq!(idx1, 1);
        assert_eq!(idx2, 2);
        assert_eq!(r1.x, 50);
        assert_eq!(r2.x, 50 + r1.width);
        assert_eq!(r1.width + r2.width, 50);
    }

    #[test]
    fn l_shape_vertical_then_horizontal() {
        // Root: vertical 50/50
        //   a: leaf(0)
        //   b: horizontal 50/50 → leaf(1), leaf(2)
        let mut root = LayoutNode::Leaf { view_idx: 0 };
        root.split(&[], SplitDir::Vertical, 99); // leaf(99) is a placeholder
        root.split(&[Side::B], SplitDir::Horizontal, 2);

        // Fix: the first split puts view 0 in A and 99 in B.
        // Then the second split replaces B with a horizontal split of (99 → leaf(1?)) and 2.
        // Actually split(B, Horizontal, 2) on leaf(99) => Split{a=leaf(99), b=leaf(2)}.
        // So leaves are: 0, 99, 2.
        let pairs = root.rects(rect(80, 40));
        assert_eq!(pairs.len(), 3);
        // Top pane: leaf 0, height 20
        assert_eq!(pairs[0].0, 0);
        assert_eq!(pairs[0].1.y, 0);
        assert_eq!(pairs[0].1.height, 20);
        // Bottom two panes: y=20
        assert_eq!(pairs[1].1.y, 20);
        assert_eq!(pairs[2].1.y, 20);
    }

    #[test]
    fn split_and_close_round_trip() {
        let mut root = LayoutNode::Leaf { view_idx: 0 };
        // Split → 2 leaves.
        root.split(&[], SplitDir::Horizontal, 1);
        assert_eq!(root.leaf_count(), 2);

        // Close B → back to 1 leaf (view 0).
        root.close(&[Side::B]);
        assert_eq!(root.leaf_count(), 1);
        assert_eq!(root.focused_view_idx(&[]), 0);
    }

    #[test]
    fn close_a_keeps_b() {
        let mut root = LayoutNode::Leaf { view_idx: 5 };
        root.split(&[], SplitDir::Vertical, 7);
        // Now root = Split { a: leaf(5), b: leaf(7) }.
        root.close(&[Side::A]);
        // Root should now be leaf(7).
        assert_eq!(root.leaf_count(), 1);
        assert_eq!(root.focused_view_idx(&[]), 7);
    }

    #[test]
    fn focused_view_idx_after_split() {
        let mut root = LayoutNode::Leaf { view_idx: 0 };
        root.split(&[], SplitDir::Horizontal, 3);
        assert_eq!(root.focused_view_idx(&[Side::A]), 0);
        assert_eq!(root.focused_view_idx(&[Side::B]), 3);
    }
}
