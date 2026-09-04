//! Fixture-rot guard for `tests/fixtures/focus_layout_split.json` — the
//! committed wire frames `bin/nostromo-launch-smoke`'s fixture daemon serves
//! to reproduce the 2026-09-03 `RatioSplitView.layout()` reentrancy crash
//! (see `.claude/plans/launch-smoke-test.md` in the primary repo checkout).
//!
//! The launch smoke check's whole premise is that serving this fixture
//! forces the app through a real split-shaped layout. If `PaneTree` or
//! `ServerMsg` ever changes shape and this fixture silently stops describing
//! a real split (or stops deserializing at all), the Python driver would keep
//! serving stale bytes over the wire and the check could pass while measuring
//! nothing — the same "fixture rot" risk the PRD names explicitly. This test
//! is the wire-side half of the defence: `cargo test` fails in seconds,
//! before anyone has to notice a launch check quietly going green for the
//! wrong reason.
//!
//! Follows this repo's raw-socket/protocol-type integration test style (see
//! `tests/pane_source_liveness.rs`), though no socket is involved here — this
//! is a pure on-disk conformance check.

use std::fs;

use nostromo::ipc::protocol::{PaneTree, ServerMsg};
use serde_json::Value;

const FIXTURE_PATH: &str = "tests/fixtures/focus_layout_split.json";

fn load_fixture_text() -> String {
    fs::read_to_string(FIXTURE_PATH)
        .unwrap_or_else(|e| panic!("failed to read {FIXTURE_PATH}: {e}"))
}

fn load_fixture_frames() -> Vec<ServerMsg> {
    let text = load_fixture_text();
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("{FIXTURE_PATH} did not deserialize as Vec<ServerMsg>: {e}"))
}

/// Recurse into every `Split` node in the tree (not just the root — this
/// fixture nests a horizontal split inside a vertical one), calling `visit`
/// on each.
fn for_each_split<'a>(tree: &'a PaneTree, visit: &mut impl FnMut(&'a PaneTree)) {
    if let PaneTree::Split { children, .. } = tree {
        visit(tree);
        for child in children {
            for_each_split(child, visit);
        }
    }
    // Leaf and Tabs nodes: nothing to recurse into for this fixture's shape
    // (Tabs isn't used here, but walking only Split children is intentional —
    // a Tabs child inside a Split would still be visited as `child` in the
    // loop above via the `Leaf`/`Tabs` no-op case one level up; since this
    // fixture contains no Tabs nodes, this is exercised at Split/Leaf only).
}

fn collect_leaf_pane_ids<'a>(tree: &'a PaneTree, out: &mut Vec<&'a str>) {
    match tree {
        PaneTree::Leaf { pane_id } => out.push(pane_id.as_str()),
        PaneTree::Split { children, .. } => {
            for child in children {
                collect_leaf_pane_ids(child, out);
            }
        }
        PaneTree::Tabs { children, .. } => {
            for child in children {
                collect_leaf_pane_ids(child, out);
            }
        }
    }
}

#[test]
fn fixture_deserializes_as_focus_layout_frames() {
    let frames = load_fixture_frames();
    assert!(!frames.is_empty(), "fixture must carry at least one frame");
    for frame in &frames {
        assert!(
            matches!(frame, ServerMsg::FocusLayout { .. }),
            "every frame in {FIXTURE_PATH} must be a FocusLayout, got {frame:?}"
        );
    }
}

#[test]
fn every_frame_carries_a_split_whose_children_and_ratios_agree_and_sum_to_one() {
    let frames = load_fixture_frames();
    for frame in &frames {
        let ServerMsg::FocusLayout { tag, tree, .. } = frame else {
            panic!("expected FocusLayout, got {frame:?}");
        };

        let mut found_valid_split = false;
        for_each_split(tree, &mut |node| {
            let PaneTree::Split { children, ratios, .. } = node else {
                unreachable!("for_each_split only visits Split nodes");
            };
            // Daemon invariant (src/ipc/protocol.rs): every Split has
            // children.len() == ratios.len() >= 2.
            assert_eq!(
                children.len(),
                ratios.len(),
                "focus {tag:?}: split children/ratios length mismatch"
            );
            assert!(
                children.len() >= 2,
                "focus {tag:?}: split has fewer than 2 children"
            );
            let sum: f32 = ratios.iter().sum();
            assert!(
                (sum - 1.0).abs() < 0.01,
                "focus {tag:?}: split ratios {ratios:?} sum to {sum}, not ~1.0"
            );
            found_valid_split = true;
        });

        assert!(
            found_valid_split,
            "focus {tag:?}: tree contains no Split node at all — this fixture must \
             reproduce the split-shaped layout the launch smoke check depends on"
        );
    }
}

#[test]
fn every_frame_has_exactly_one_repl_leaf() {
    let frames = load_fixture_frames();
    for frame in &frames {
        let ServerMsg::FocusLayout { tag, tree, .. } = frame else {
            panic!("expected FocusLayout, got {frame:?}");
        };
        let mut leaves = Vec::new();
        collect_leaf_pane_ids(tree, &mut leaves);
        let repl_count = leaves.iter().filter(|id| **id == "repl").count();
        assert_eq!(
            repl_count, 1,
            "focus {tag:?}: expected exactly one 'repl' leaf, found {repl_count} \
             among {leaves:?}"
        );
    }
}

#[test]
fn every_frame_has_unique_leaf_pane_ids() {
    let frames = load_fixture_frames();
    for frame in &frames {
        let ServerMsg::FocusLayout { tag, tree, .. } = frame else {
            panic!("expected FocusLayout, got {frame:?}");
        };
        let mut leaves = Vec::new();
        collect_leaf_pane_ids(tree, &mut leaves);
        let mut sorted = leaves.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            leaves.len(),
            "focus {tag:?}: duplicate pane ids among leaves {leaves:?}"
        );
    }
}

#[test]
fn every_frame_renders_exactly_two_split_nodes_and_three_leaves() {
    let frames = load_fixture_frames();
    for frame in &frames {
        let ServerMsg::FocusLayout { tag, tree, .. } = frame else {
            panic!("expected FocusLayout, got {frame:?}");
        };
        let mut split_count = 0;
        for_each_split(tree, &mut |_node| split_count += 1);
        let mut leaves = Vec::new();
        collect_leaf_pane_ids(tree, &mut leaves);
        assert_eq!(split_count, 2, "focus {tag:?}: expected exactly 2 split nodes");
        assert_eq!(leaves.len(), 3, "focus {tag:?}: expected exactly 3 leaves");
    }
}

/// Strip JSON-null-valued object keys, recursively.
///
/// `ServerMsg::FocusLayout.focused_pane` is `#[serde(skip_serializing_if =
/// "Option::is_none")]`, so a real re-serialized frame omits the key entirely
/// when it's `None` rather than emitting `"focused_pane": null`. The
/// committed fixture spells that same "no focused pane" fact as an explicit
/// `null` (arguably the more readable committed form). Both are the same
/// fact on the wire — `Option<String>` deserializes a present `null` and an
/// absent key identically — so this normalization is applied to both sides
/// before comparing, and it does not weaken what the test actually guards:
/// a renamed field, a changed tag, or a shape drift still leaves a key
/// mismatch after stripping nulls on both sides.
fn strip_nulls(value: &mut Value) {
    match value {
        Value::Object(map) => {
            map.retain(|_, v| !v.is_null());
            for v in map.values_mut() {
                strip_nulls(v);
            }
        }
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                strip_nulls(v);
            }
        }
        _ => {}
    }
}

/// Structural JSON equality with a numeric tolerance.
///
/// `PaneTree::Split.ratios` is `Vec<f32>`. The committed fixture spells a
/// ratio as the f64 literal `0.6`; deserializing it into an `f32` and
/// serializing that `f32` back out (serde_json always writes JSON numbers as
/// f64) reproduces it as `0.6000000238418579` — the exact, correct f32
/// nearest-neighbor of `0.6`, not a shape drift. A plain `Value` equality
/// check would fail on every ratio in this fixture and catch nothing real,
/// so numbers are compared within a tolerance here while every other JSON
/// shape difference (a renamed key, a missing entry, a changed tag, a
/// different array length) is still exact.
fn approx_json_eq(a: &Value, b: &Value, epsilon: f64) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(x), Some(y)) => (x - y).abs() < epsilon,
            _ => x == y,
        },
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| approx_json_eq(v, w, epsilon)))
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len()
                && x.iter().zip(y.iter()).all(|(v, w)| approx_json_eq(v, w, epsilon))
        }
        _ => a == b,
    }
}

/// Re-serializing every parsed frame and comparing it, as a `serde_json::Value`
/// (not a string — field order must not matter), against the same committed
/// text parsed independently. If `PaneTree`/`ServerMsg`'s shape ever silently
/// drifts — a renamed field, a new required field with no default, a changed
/// tag — this fails instead of the fixture quietly ceasing to describe a real
/// split while everything still "compiles".
#[test]
fn round_tripping_every_frame_reproduces_the_committed_json_exactly() {
    let text = load_fixture_text();
    let committed: Vec<Value> =
        serde_json::from_str(&text).expect("fixture must parse as a JSON array of objects");
    let frames = load_fixture_frames();

    assert_eq!(
        committed.len(),
        frames.len(),
        "committed JSON array length and deserialized frame count must agree"
    );

    for (i, frame) in frames.iter().enumerate() {
        let mut reserialized = serde_json::to_value(frame)
            .unwrap_or_else(|e| panic!("failed to re-serialize frame {i}: {e}"));
        let mut committed_normalized = committed[i].clone();
        strip_nulls(&mut reserialized);
        strip_nulls(&mut committed_normalized);
        assert!(
            approx_json_eq(&reserialized, &committed_normalized, 1e-4),
            "frame {i} does not round-trip through ServerMsg/PaneTree (as JSON values, \
             null-valued keys stripped from both sides, numbers compared within 1e-4 for \
             f32 round-trip noise) — the wire shape has drifted from the committed fixture\n\
             reserialized: {reserialized}\n\
             committed:    {committed_normalized}"
        );
    }
}
