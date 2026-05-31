//! Render the pace bars at several heights into a single PNG preview.
//!
//! Loads `~/.claude/budget-posture.json`, renders the pace-bars widget at
//! various row heights (assuming ~12px×22px cells), stacks them with text
//! labels, and writes `/tmp/pace_bars_preview.png`.
//!
//! Usage:
//!     cargo run --bin preview_pace_bars
//!     open /tmp/pace_bars_preview.png

use image::{DynamicImage, Rgba, RgbaImage};
use nostromo::data::rate_limits::PostureSnapshot;
use nostromo::views::pace_bars_image::render_pace_bars_to_image;

const CELL_W: u32 = 12;
const CELL_H: u32 = 22;
const COLS: u32 = 200; // typical terminal width

fn main() {
    let snap = PostureSnapshot::load().unwrap_or_else(|| {
        eprintln!("Could not load ~/.claude/budget-posture.json — using zeros");
        std::process::exit(1)
    });

    println!(
        "posture: {:?}  5h: {:?}  7d: {:?}",
        snap.posture, snap.five_hour, snap.seven_day
    );

    let label_h: u32 = 18;
    let gap: u32 = 6;

    // Render at 1, 2, 3, 4 rows tall.
    let heights = [1u16, 2, 3, 4];
    let mut renders: Vec<(u16, DynamicImage)> = Vec::new();
    for h in heights {
        let img = render_pace_bars_to_image(&snap, COLS * CELL_W, (h as u32) * CELL_H);
        renders.push((h, img));
    }

    // Compose: text label + each rendering stacked vertically.
    let total_w = COLS * CELL_W;
    let total_h: u32 = renders
        .iter()
        .map(|(_, img)| label_h + img.height() + gap)
        .sum();

    let mut out = RgbaImage::from_pixel(total_w, total_h, Rgba([18, 18, 24, 255]));
    let mut y_cursor: u32 = 0;
    for (h, img) in &renders {
        // Crude text "stub" — draw an N-pixel-wide white block at the top-left
        // for visual reference of which rendering is which. Not pretty but
        // human-readable when paired with stdout output.
        for px in 0..(*h as u32) * 60 {
            for py in y_cursor..(y_cursor + 4).min(total_h) {
                out.put_pixel(4 + px % 60, py, Rgba([200, 200, 220, 255]));
            }
        }
        y_cursor += label_h;
        for (x, y, p) in img.to_rgba8().enumerate_pixels() {
            if x < total_w && y_cursor + y < total_h {
                out.put_pixel(x, y_cursor + y, *p);
            }
        }
        y_cursor += img.height() + gap;
    }

    // Also print info per rendering so the operator knows which is which.
    for (h, img) in &renders {
        println!("{} row(s): {}×{} pixels", h, img.width(), img.height());
    }

    let path = "/tmp/pace_bars_preview.png";
    DynamicImage::ImageRgba8(out).save(path).expect("save PNG");
    println!("wrote {path}");
}
