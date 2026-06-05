//! Pixel-rendered pace bars for the Fred view.
//!
//! Renders two horizontal gradient bars — one for the 5-hour window and one
//! for the 7-day window — using `tiny-skia` (fills) and `fontdue` (labels).
//!
//! The bars are passed to `ratatui-image`'s `Picker` for display via the
//! Kitty graphics protocol (or halfblock fallback).
//!
//! # Visual layout (per bar)
//!
//! ```text
//! ┌──────────────────────────────────────────────────┐
//! │  5h  ████████████████░░░░░░░░░░░░░░░░░░   1.18  │
//! │  7d  ██████████░░░░░░░░░░░░░░░░░░░░░░░░   1.06  │
//! └──────────────────────────────────────────────────┘
//! ```
//!
//! - Left label column (36 px): "5h" / "7d"
//! - Rail: gradient from `#00C853` (left) → `pace_color(pace)` (right tip)
//! - Fill length encodes `elapsed_pct` (not `used_pct`)
//! - Pace number shown at the right in the tip color

use tiny_skia::{Paint, Pixmap, Rect as SkRect, Transform};

use crate::data::rate_limits::{PostureSnapshot, WindowPace};

// ── Embedded font ────────────────────────────────────────────────────────────

static FONT_BYTES: &[u8] = include_bytes!("../../assets/font.ttf");

// ── Colour constants ─────────────────────────────────────────────────────────

/// Background for the entire widget.
const BG: (u8, u8, u8, u8) = (20, 20, 28, 255);
/// Empty rail background (dim fill).
const RAIL_BG: (u8, u8, u8, u8) = (45, 45, 58, 255);
/// Muted foreground for the label text.
const FG_MUTED: (u8, u8, u8, u8) = (140, 140, 140, 255);

/// Width of the left label column in pixels.
const LABEL_PX: u32 = 36;
/// Horizontal padding between label and rail.
const GAP_PX: u32 = 4;
/// Padding between the top of a half and the bar, and between the bar and the bottom.
const V_PAD: u32 = 3;

// ── Public entry point ────────────────────────────────────────────────────────

/// Render pace bars for both windows into a pixel image.
///
/// - `snap` — the `PostureSnapshot` to render. Missing windows render as a
///   labelled dim rail without fill or pace number.
/// - `width_px` / `height_px` — pixel dimensions of the target widget area.
///
/// Returns an RGBA `DynamicImage` ready for `Picker::new_resize_protocol()`.
pub fn render_pace_bars_to_image(
    snap: &PostureSnapshot,
    width_px: u32,
    height_px: u32,
) -> image::DynamicImage {
    let w = width_px.max(1);
    let h = height_px.max(1);
    let mut pixmap = Pixmap::new(w, h).unwrap_or_else(|| Pixmap::new(1, 1).unwrap());

    fill_rect(&mut pixmap, 0, 0, w, h, BG);

    let font = match fontdue::Font::from_bytes(FONT_BYTES, fontdue::FontSettings::default()) {
        Ok(f) => f,
        Err(_) => return pixmap_to_dynamic_image(pixmap),
    };

    // Three bars stacked: 5h, 7d, sonnet 7d.
    let third_h = h / 3;
    let font_px = (third_h as f32 * 0.55).clamp(8.0, 14.0);

    render_bar(
        &mut pixmap,
        &font,
        font_px,
        "5h",
        snap.five_hour.as_ref(),
        0,
        w,
        third_h,
    );
    render_bar(
        &mut pixmap,
        &font,
        font_px,
        "7d",
        snap.seven_day.as_ref(),
        third_h,
        w,
        third_h,
    );
    // Third bar — Sonnet 7d. Use a shorter label that fits LABEL_PX.
    render_bar(
        &mut pixmap,
        &font,
        font_px,
        "son",
        snap.sonnet_seven_day.as_ref(),
        third_h * 2,
        w,
        h - (third_h * 2),
    );

    pixmap_to_dynamic_image(pixmap)
}

// ── Per-bar renderer ─────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn render_bar(
    pixmap: &mut Pixmap,
    font: &fontdue::Font,
    font_px: f32,
    label: &str,
    window: Option<&WindowPace>,
    y_offset: u32,
    width: u32,
    height: u32,
) {
    // Label (vertically centred in this half).
    let label_baseline = y_offset as i32 + (height as f32 / 2.0 + font_px * 0.35) as i32;
    draw_text(pixmap, font, label, 4, label_baseline, font_px, FG_MUTED);

    // Rail geometry.
    let rail_x = LABEL_PX + GAP_PX;
    if rail_x >= width {
        return;
    }
    let rail_w = width.saturating_sub(rail_x);

    let bar_h = height.saturating_sub(V_PAD * 2).max(4);
    let bar_y = y_offset + V_PAD;

    // Empty rail background.
    fill_rect(pixmap, rail_x, bar_y, rail_w, bar_h, RAIL_BG);

    let Some(wp) = window else { return };

    // Gradient fill: length encodes elapsed_pct.
    // Each pixel samples pace_color(t * pace) so the gradient always runs
    // from the dark anchor at the left edge to the pace colour at the right
    // edge, regardless of which bar is being drawn.
    let fill_w = ((wp.elapsed_pct.clamp(0.0, 100.0) / 100.0) * rail_w as f32).round() as u32;
    if fill_w > 0 {
        for px in 0..fill_w {
            let t = if fill_w <= 1 {
                0.0f32
            } else {
                px as f32 / (fill_w - 1) as f32
            };
            let (r, g, b) = pace_color(t * wp.pace);
            fill_rect(pixmap, rail_x + px, bar_y, 1, bar_h, (r, g, b, 255));
        }
    }

    // Pace number — right-aligned, overlaid in tip color at the right of the rail.
    // Ensure the text is always at least as bright as green so it's legible.
    let tip_rgb = pace_color(wp.pace.max(0.6));
    let pace_str = format!("{:.2}", wp.pace);
    // Estimate text width (~font_px * 0.6 per char) to right-align.
    let approx_text_w = (pace_str.len() as f32 * font_px * 0.6) as i32;
    let text_x = (width as i32) - approx_text_w - 4;
    let text_baseline = y_offset as i32 + (height as f32 / 2.0 + font_px * 0.35) as i32;
    draw_text(
        pixmap,
        font,
        &pace_str,
        text_x,
        text_baseline,
        font_px,
        (tip_rgb.0, tip_rgb.1, tip_rgb.2, 220),
    );
}

// ── Colour helpers ────────────────────────────────────────────────────────────

/// Map a pace value to an RGB colour via three-segment OKLab interpolation.
///
/// Anchors:
/// - `0.0` → `#0A1460` (dark blue — start anchor, same for every bar)
/// - `0.6` → `#00C853` (vivid green — on-pace)
/// - `1.0` → `#FFD600` (amber yellow — elevated)
/// - `1.5` → `#D50000` (vivid red — critical)
///
/// Using `pace_color(t * pace)` over a fill produces a gradient that always
/// starts from the dark anchor and ends at the colour for that bar's pace,
/// so every bar shares the same visual origin regardless of pace value.
///
/// Pace is clamped to `[0.0, 1.5]` before mapping.
pub fn pace_color(pace: f32) -> (u8, u8, u8) {
    let dark = (10u8, 20u8, 90u8); // dark blue anchor
    let green = (0u8, 200u8, 83u8);
    let yellow = (255u8, 214u8, 0u8);
    let red = (213u8, 0u8, 0u8);

    let pace = pace.clamp(0.0, 1.5);
    if pace <= 0.6 {
        oklab_lerp(dark, green, pace / 0.6)
    } else if pace <= 1.0 {
        oklab_lerp(green, yellow, (pace - 0.6) / 0.4)
    } else {
        oklab_lerp(yellow, red, (pace - 1.0) / 0.5)
    }
}

/// Interpolate between two sRGB colours in OKLab space.
///
/// `t = 0.0` returns `a`, `t = 1.0` returns `b`.
pub fn oklab_lerp(a: (u8, u8, u8), b: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    let (la, aa, ba_) = rgb_to_oklab(a);
    let (lb, ab, bb) = rgb_to_oklab(b);

    let lc = la + (lb - la) * t;
    let ac = aa + (ab - aa) * t;
    let bc = ba_ + (bb - ba_) * t;

    oklab_to_rgb((lc, ac, bc))
}

/// Convert sRGB `(u8, u8, u8)` to OKLab `(L, a, b)`.
fn rgb_to_oklab(rgb: (u8, u8, u8)) -> (f32, f32, f32) {
    let r = to_linear(rgb.0 as f32 / 255.0);
    let g = to_linear(rgb.1 as f32 / 255.0);
    let b = to_linear(rgb.2 as f32 / 255.0);

    // Linear RGB → LMS
    let l = 0.412_221_47 * r + 0.536_332_54 * g + 0.051_445_99 * b;
    let m = 0.211_903_5 * r + 0.680_699_5 * g + 0.107_396_96 * b;
    let s = 0.088_302_46 * r + 0.281_718_84 * g + 0.629_978_7 * b;

    // LMS → LMS^(1/3)
    let l_ = l.max(0.0).cbrt();
    let m_ = m.max(0.0).cbrt();
    let s_ = s.max(0.0).cbrt();

    // LMS^(1/3) → OKLab
    let big_l = 0.210_454_26 * l_ + 0.793_617_8 * m_ - 0.004_072_05 * s_;
    let a = 1.977_998_5 * l_ - 2.428_592_2 * m_ + 0.450_593_7 * s_;
    let b_comp = 0.025_904_04 * l_ + 0.782_771_77 * m_ - 0.808_675_77 * s_;

    (big_l, a, b_comp)
}

/// Convert OKLab `(L, a, b)` back to sRGB `(u8, u8, u8)`.
fn oklab_to_rgb(lab: (f32, f32, f32)) -> (u8, u8, u8) {
    let (big_l, a, b_comp) = lab;

    // OKLab → LMS^(1/3)
    let l_ = big_l + 0.396_337_78 * a + 0.215_803_76 * b_comp;
    let m_ = big_l - 0.105_561_35 * a - 0.063_854_17 * b_comp;
    let s_ = big_l - 0.089_484_18 * a - 1.291_485_5 * b_comp;

    // LMS^(1/3) → LMS (cube)
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;

    // LMS → linear RGB
    let r_lin = 4.076_741_7 * l - 3.307_711_6 * m + 0.230_969_93 * s;
    let g_lin = -1.268_438 * l + 2.609_757_4 * m - 0.341_319_4 * s;
    let b_lin = -0.004_196_09 * l - 0.703_418_6 * m + 1.707_614_7 * s;

    // linear → sRGB, clamp
    let r = to_srgb(r_lin).clamp(0.0, 1.0);
    let g = to_srgb(g_lin).clamp(0.0, 1.0);
    let b = to_srgb(b_lin).clamp(0.0, 1.0);

    (
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8,
    )
}

/// Gamma-expand: sRGB component `[0,1]` → linear.
#[inline]
fn to_linear(c: f32) -> f32 {
    if c <= 0.040_45 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055_f32).powf(2.4)
    }
}

/// Gamma-compress: linear component `[0,1]` → sRGB.
#[inline]
fn to_srgb(c: f32) -> f32 {
    if c <= 0.003_130_8 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

// ── Drawing primitives (mirrored from fred_calendar_image.rs) ─────────────────

fn fill_rect(pixmap: &mut Pixmap, x: u32, y: u32, w: u32, h: u32, color: (u8, u8, u8, u8)) {
    if w == 0 || h == 0 {
        return;
    }
    let mut paint = Paint::default();
    paint.set_color(tiny_skia::Color::from_rgba8(
        color.0, color.1, color.2, color.3,
    ));
    paint.anti_alias = false;
    if let Some(rect) = SkRect::from_xywh(x as f32, y as f32, w as f32, h as f32) {
        pixmap.fill_rect(rect, &paint, Transform::identity(), None);
    }
}

fn draw_text(
    pixmap: &mut Pixmap,
    font: &fontdue::Font,
    text: &str,
    x: i32,
    baseline_y: i32,
    size_px: f32,
    color: (u8, u8, u8, u8),
) {
    let pw = pixmap.width() as i32;
    let ph = pixmap.height() as i32;
    let stride = pixmap.width();
    let (cr, cg, cb) = (color.0, color.1, color.2);
    let global_alpha = color.3 as f32 / 255.0;
    let pixels = pixmap.pixels_mut();

    let mut cursor_x = x;

    for ch in text.chars() {
        if ch < ' ' {
            continue;
        }
        let (metrics, bitmap) = font.rasterize(ch, size_px);
        if metrics.width == 0 || metrics.height == 0 {
            cursor_x += metrics.advance_width as i32;
            continue;
        }

        let gx0 = cursor_x + metrics.xmin;
        let gy0 = baseline_y - metrics.ymin - metrics.height as i32;

        for row in 0..metrics.height {
            let py = gy0 + row as i32;
            if py < 0 || py >= ph {
                continue;
            }
            for col in 0..metrics.width {
                let px_x = gx0 + col as i32;
                if px_x < 0 || px_x >= pw {
                    continue;
                }
                let coverage = bitmap[row * metrics.width + col] as f32 / 255.0;
                if coverage < 0.005 {
                    continue;
                }
                let alpha = coverage * global_alpha;
                let idx = (py as u32 * stride + px_x as u32) as usize;
                let dst = pixels[idx];
                let dr = dst.red() as f32;
                let dg = dst.green() as f32;
                let db = dst.blue() as f32;
                let nr = (cr as f32 * alpha + dr * (1.0 - alpha)).round() as u8;
                let ng = (cg as f32 * alpha + dg * (1.0 - alpha)).round() as u8;
                let nb = (cb as f32 * alpha + db * (1.0 - alpha)).round() as u8;
                pixels[idx] =
                    tiny_skia::PremultipliedColorU8::from_rgba(nr, ng, nb, 255).unwrap_or(dst);
            }
        }
        cursor_x += metrics.advance_width as i32;
    }
}

// ── Pixmap → DynamicImage ─────────────────────────────────────────────────────

fn pixmap_to_dynamic_image(pixmap: Pixmap) -> image::DynamicImage {
    let w = pixmap.width();
    let h = pixmap.height();
    let raw = pixmap.take();
    let mut rgba = Vec::with_capacity(raw.len());
    for chunk in raw.chunks_exact(4) {
        let (r, g, b, a) = (chunk[0], chunk[1], chunk[2], chunk[3]);
        if a == 0 {
            rgba.extend_from_slice(&[0, 0, 0, 0]);
        } else if a == 255 {
            rgba.extend_from_slice(&[r, g, b, 255]);
        } else {
            let af = a as f32 / 255.0;
            rgba.extend_from_slice(&[
                (r as f32 / af).round().min(255.0) as u8,
                (g as f32 / af).round().min(255.0) as u8,
                (b as f32 / af).round().min(255.0) as u8,
                a,
            ]);
        }
    }
    let img = image::RgbaImage::from_raw(w, h, rgba).unwrap_or_else(|| image::RgbaImage::new(w, h));
    image::DynamicImage::ImageRgba8(img)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pace_color_dark_at_zero() {
        // pace=0 maps to the dark blue anchor — blue dominant, red/green low
        let (r, g, b) = pace_color(0.0);
        assert!(r < 40, "red should be low for dark anchor: {r}");
        assert!(g < 50, "green should be low for dark anchor: {g}");
        assert!(b > 60, "blue should be dominant for dark anchor: {b}");
    }

    #[test]
    fn pace_color_green_at_zero_point_six() {
        // pace=0.6 maps to vivid green
        let (r, g, b) = pace_color(0.6);
        assert!(r < 50, "red should be low for green: {r}");
        assert!(g > 180, "green should be high for green: {g}");
        assert!(b < 110, "blue should be lower than green: {b}");
    }

    #[test]
    fn pace_color_yellow_at_one() {
        let (r, g, b) = pace_color(1.0);
        assert!(r > 200, "red should be high for yellow: {r}");
        assert!(g > 180, "green should be high for yellow: {g}");
        assert!(b < 60, "blue should be low for yellow: {b}");
    }

    #[test]
    fn pace_color_red_at_one_point_five() {
        let (r, g, b) = pace_color(1.5);
        assert!(r > 180, "red should be high for red: {r}");
        assert!(g < 60, "green should be low for red: {g}");
        assert!(b < 60, "blue should be low for red: {b}");
    }

    #[test]
    fn oklab_lerp_identity() {
        // Lerp from A to A at t=0.5 should give A within ±2 per channel.
        let a = (120u8, 80u8, 200u8);
        let result = oklab_lerp(a, a, 0.5);
        assert!(
            (result.0 as i32 - a.0 as i32).abs() <= 2,
            "R mismatch: {} vs {}",
            result.0,
            a.0
        );
        assert!(
            (result.1 as i32 - a.1 as i32).abs() <= 2,
            "G mismatch: {} vs {}",
            result.1,
            a.1
        );
        assert!(
            (result.2 as i32 - a.2 as i32).abs() <= 2,
            "B mismatch: {} vs {}",
            result.2,
            a.2
        );
    }

    #[test]
    fn pace_color_clamped_beyond_one_five() {
        // Values > 1.5 should be clamped to the same as 1.5.
        assert_eq!(pace_color(2.0), pace_color(1.5));
        assert_eq!(pace_color(-0.5), pace_color(0.0));
    }
}
