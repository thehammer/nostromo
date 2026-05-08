//! Split-pane layout system.
//!
//! A recursive binary tree where each leaf owns a view index and each
//! internal node splits its area either horizontally or vertically.

pub mod persist;
pub mod tree;

pub use tree::{LayoutNode, Side, SplitDir};
