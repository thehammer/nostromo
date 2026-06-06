//! Integration test for `views::pace_bars_image::render_pace_bars_to_image`.
//!
//! Synthesises a `PostureSnapshot` fixture and asserts pixel-level properties:
//! - Correct image dimensions.
//! - Background colour in a corner that is always BG.
//! - The leftmost filled pixel of the 5h bar is green-ish.
//! - The rightmost filled pixel of the 5h bar matches `pace_color(1.18)` ± 5.

use nostromo::{
    data::rate_limits::{BudgetPosture, PostureSnapshot, WindowPace},
    views::pace_bars_image::{pace_color, render_pace_bars_to_image},
};

fn make_snapshot() -> PostureSnapshot {
    PostureSnapshot {
        posture: BudgetPosture::Normal,
        five_hour: Some(WindowPace {
            used_pct: 14.0,
            elapsed_pct: 11.8,
            pace: 1.18,
            resets_at: 1_715_200_000,
            level: "normal".to_string(),
        }),
        seven_day: Some(WindowPace {
            used_pct: 7.0,
            elapsed_pct: 6.6,
            pace: 1.06,
            resets_at: 1_715_800_000,
            level: "normal".to_string(),
        }),
        sonnet_seven_day: None,
        loaded_at: std::time::Instant::now(),
        agents: std::collections::BTreeMap::new(),
    }
}

#[test]
fn render_returns_correct_dimensions() {
    let snap = make_snapshot();
    let img = render_pace_bars_to_image(&snap, 400, 48);
    assert_eq!(img.width(), 400, "image width");
    assert_eq!(img.height(), 48, "image height");
}

#[test]
fn top_left_pixel_is_background() {
    let snap = make_snapshot();
    let img = render_pace_bars_to_image(&snap, 400, 48);
    let rgba = img.to_rgba8();
    let p = rgba.get_pixel(0, 0);
    // BG = (20, 20, 28) — allow a tiny rounding margin.
    assert!(
        (p[0] as i32 - 20).abs() <= 2,
        "R: expected ~20, got {}",
        p[0]
    );
    assert!(
        (p[1] as i32 - 20).abs() <= 2,
        "G: expected ~20, got {}",
        p[1]
    );
    assert!(
        (p[2] as i32 - 28).abs() <= 2,
        "B: expected ~28, got {}",
        p[2]
    );
}

#[test]
fn leftmost_fill_pixel_is_dark_blue_anchor() {
    let snap = make_snapshot();
    let img = render_pace_bars_to_image(&snap, 400, 48);
    let rgba = img.to_rgba8();

    // The 5h bar is the top third. Rail starts at x = LABEL_PX + GAP_PX = 40.
    // third_h=16, V_PAD=3 → bar rows 3..12; row 7 is the midpoint.
    let label_and_gap = 40u32;
    let bar_row = 7u32;

    let p = rgba.get_pixel(label_and_gap, bar_row);
    // The gradient uses pace_color(t * pace). At t=0 (leftmost pixel) this is
    // pace_color(0.0) = #0A1460 (dark blue: R≈10, G≈20, B≈96).
    // Allow ±15 per channel for OKLab rounding.
    assert!(
        p[0] < 30,
        "leftmost fill R should be low (dark-blue anchor): {}",
        p[0]
    );
    assert!(
        p[2] > 60,
        "leftmost fill B should be high (dark-blue anchor): {}",
        p[2]
    );
}

#[test]
fn rightmost_fill_pixel_matches_pace_color() {
    let snap = make_snapshot();
    let width = 400u32;
    let img = render_pace_bars_to_image(&snap, width, 48);
    let rgba = img.to_rgba8();

    // Elapsed_pct = 11.8 → fill_w = (11.8/100) * (400 - 40) ≈ 42 px
    let rail_x = 40u32;
    let rail_w = width - rail_x;
    let fill_w = ((11.8f32 / 100.0) * rail_w as f32).round() as u32;
    if fill_w == 0 {
        return; // nothing to assert
    }

    let rightmost_x = rail_x + fill_w - 1;
    let bar_row = 12u32;
    let p = rgba.get_pixel(rightmost_x, bar_row);

    let (er, eg, eb) = pace_color(1.18);
    let tol = 5i32;
    assert!(
        (p[0] as i32 - er as i32).abs() <= tol,
        "R: expected ~{er}, got {}",
        p[0]
    );
    assert!(
        (p[1] as i32 - eg as i32).abs() <= tol,
        "G: expected ~{eg}, got {}",
        p[1]
    );
    assert!(
        (p[2] as i32 - eb as i32).abs() <= tol,
        "B: expected ~{eb}, got {}",
        p[2]
    );
}
