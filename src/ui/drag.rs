//! Shared drag-state types and math helpers for mouse-driven pane resizing.
//!
//! Each view holds a `DragState` and calls `hit_test` / `ratio_from_mouse`
//! from its `on_event` mouse handler.

use ratatui::layout::Rect;

// ── types ─────────────────────────────────────────────────────────────────────

/// Whether the divider runs left-right (splitting rows) or top-bottom (splitting columns).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DividerAxis {
    /// The divider is a horizontal line; dragging it changes the vertical split.
    Horizontal,
    /// The divider is a vertical line; dragging it changes the horizontal split.
    Vertical,
}

/// Tracks whether the user is currently dragging a pane divider.
#[derive(Clone, Copy, Debug, Default)]
pub enum DragState {
    #[default]
    Idle,
    Dragging {
        /// Which divider within this view (0, 1, …) is being dragged.
        divider_id: u8,
        /// The containing rect used to compute the new ratio.
        parent: Rect,
        /// Axis of the divider being dragged.
        axis: DividerAxis,
    },
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Returns `true` if the mouse position `(col, row)` is within ±1 cell of the
/// divider line and within the `parent` rect on the orthogonal axis.
///
/// For a `Horizontal` divider the "line" is the row at `divider_row`.
/// For a `Vertical`   divider the "line" is the column at `divider_col`.
///
/// `divider_col` / `divider_row` should be the first cell of the second sub-pane
/// (i.e. `split[1].x` for Vertical, `split[1].y` for Horizontal).
pub fn hit_test(
    col: u16,
    row: u16,
    divider_col: u16,
    divider_row: u16,
    axis: DividerAxis,
    parent: Rect,
) -> bool {
    // Guard: the mouse must be within the parent rect.
    if col < parent.x
        || col >= parent.x + parent.width
        || row < parent.y
        || row >= parent.y + parent.height
    {
        return false;
    }

    match axis {
        DividerAxis::Horizontal => {
            // Hit within ±1 row of the divider row.
            let dist = row.abs_diff(divider_row);
            dist <= 1
        }
        DividerAxis::Vertical => {
            // Hit within ±1 column of the divider column.
            let dist = col.abs_diff(divider_col);
            dist <= 1
        }
    }
}

/// Compute a new ratio in `[0.1, 0.9]` from the mouse position relative to `parent`.
///
/// For `Horizontal` axis the ratio = (row - parent.y) / parent.height.
/// For `Vertical`   axis the ratio = (col - parent.x) / parent.width.
pub fn ratio_from_mouse(parent: Rect, col: u16, row: u16, axis: DividerAxis) -> f32 {
    let raw = match axis {
        DividerAxis::Horizontal => {
            let span = parent.height as f32;
            if span <= 0.0 {
                return 0.5;
            }
            (row.saturating_sub(parent.y)) as f32 / span
        }
        DividerAxis::Vertical => {
            let span = parent.width as f32;
            if span <= 0.0 {
                return 0.5;
            }
            (col.saturating_sub(parent.x)) as f32 / span
        }
    };
    crate::ui::pane_ratios::clamp(raw)
}
