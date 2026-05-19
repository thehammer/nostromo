//! Pixel-rendered pace bars and context-usage bar for the chrome strip.
//!
//! Renders a set of `BarSpec`-described horizontal bars using `tiny-skia`
//! (fills) and `fontdue` (labels).
//!
//! The bars are passed to `ratatui-image`'s `Picker` for display via the
//! Kitty graphics protocol (or halfblock fallback).
//!
//! # Bar types
//!
//! ## Pace bars (OKLab gradient)
//!
//! ```text
//! │  5h  ████████████████░░░░░░░░░░░░░░░░░░   1.18  │
//! │  7d  ██████████░░░░░░░░░░░░░░░░░░░░░░░░   1.06  │
//! ```
//!
//! - Fill: OKLab gradient green→tip colour based on pace value
//! - Right label: pace number
//!
//! ## Context bar (solid threshold colour)
//!
//! ```text
//! │  ctx ████████░░░░░░░░░░░░░░░░░░░░░░░░░░   57%   │
//! ```
//!
//! - Fill: solid blue (<70%), amber (70–90%), or red (≥90%)
//! - Right label: percentage

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
/// Padding between the top of a row and the bar, and between the bar and the bottom.
const V_PAD: u32 = 3;

// ── Bar specification types ───────────────────────────────────────────────────

/// How a bar's filled region should be rendered.
pub enum Fill {
    /// OKLab gradient from green→tip; tip RGB determined by `pace_color(pace)`.
    /// `elapsed_pct` controls the fill length (0–100).
    PaceGradient { pace: f32, elapsed_pct: f32 },
    /// Solid threshold colour based on `pct` (0–100).
    /// <70 → blue, 70–90 → amber, ≥90 → red.
    ContextSolid { pct: f32 },
}

/// Specification for a single rendered bar.
pub struct BarSpec<'a> {
    /// Short left-side label (e.g. "5h", "7d", "ctx").
    pub label: &'a str,
    /// How to fill the bar rail.  `None` draws only the label and an empty
    /// rail (no right-side text).
    pub fill: Option<Fill>,
    /// Text shown right-aligned inside the rail (e.g. "1.18" or "57%").
    pub right_text: Option<String>,
    /// Colour of `right_text`.  Falls back to `FG_MUTED` if `None`.
    pub right_text_color: Option<(u8, u8, u8)>,
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Render a set of `BarSpec` bars into a pixel image.
///
/// Bar height is distributed evenly across `specs.len()`.
/// Returns an RGBA `DynamicImage` ready for `Picker::new_resize_protocol()`.
pub fn render_pace_bars_to_image(
    specs: &[BarSpec<'_>],
    width_px: u32,
    height_px: u32,
) -> image::DynamicImage {
    let w = width_px.max(1);
    let h = height_px.max(1);
    let mut pixmap = Pixmap::new(w, h).unwrap_or_else(|| Pixmap::new(1, 1).unwrap());

    fill_rect(&mut pixmap, 0, 0, w, h, BG);

    if specs.is_empty() {
        return pixmap_to_dynamic_image(pixmap);
    }

    let font = match fontdue::Font::from_bytes(FONT_BYTES, fontdue::FontSettings::default()) {
        Ok(f) => f,
        Err(_) => return pixmap_to_dynamic_image(pixmap),
    };

    let n = specs.len() as u32;
    let bar_h = h / n;
    let font_px = (bar_h as f32 * 0.55).clamp(8.0, 14.0);

    for (i, spec) in specs.iter().enumerate() {
        let y_offset = bar_h * i as u32;
        // Last bar gets any leftover pixels to avoid gaps.
        let this_h = if i as u32 == n - 1 {
            h - y_offset
        } else {
            bar_h
        };
        render_bar(&mut pixmap, &font, font_px, spec, y_offset, w, this_h);
    }

    pixmap_to_dynamic_image(pixmap)
}

/// Build the 3 standard pace `BarSpec`s from a `PostureSnapshot`.
///
/// Convenience used by `chrome.rs` so it doesn't need to import
/// `WindowPace` directly.
pub fn pace_specs_from_snapshot(snap: &PostureSnapshot) -> [BarSpecOwned; 3] {
    [
        owned_pace_spec("5h", snap.five_hour.as_ref()),
        owned_pace_spec("7d", snap.seven_day.as_ref()),
        owned_pace_spec("son", snap.sonnet_seven_day.as_ref()),
    ]
}

/// An owned version of `BarSpec` used for the helper above (avoids lifetime
/// gymnastics when building specs dynamically).
pub struct BarSpecOwned {
    pub label: String,
    pub fill: Option<Fill>,
    pub right_text: Option<String>,
    pub right_text_color: Option<(u8, u8, u8)>,
}

impl BarSpecOwned {
    pub fn as_ref_spec(&self) -> BarSpec<'_> {
        BarSpec {
            label: &self.label,
            fill: self.fill.as_ref().map(|f| match f {
                Fill::PaceGradient { pace, elapsed_pct } => Fill::PaceGradient {
                    pace: *pace,
                    elapsed_pct: *elapsed_pct,
                },
                Fill::ContextSolid { pct } => Fill::ContextSolid { pct: *pct },
            }),
            right_text: self.right_text.clone(),
            right_text_color: self.right_text_color,
        }
    }
}

fn owned_pace_spec(label: &str, window: Option<&WindowPace>) -> BarSpecOwned {
    match window {
        Some(wp) => {
            let tip = pace_color(wp.pace);
            BarSpecOwned {
                label: label.to_string(),
                fill: Some(Fill::PaceGradient {
                    pace: wp.pace,
                    elapsed_pct: wp.elapsed_pct,
                }),
                right_text: Some(format!("{:.2}", wp.pace)),
                right_text_color: Some(tip),
            }
        }
        None => BarSpecOwned {
            label: label.to_string(),
            fill: None,
            right_text: None,
            right_text_color: None,
        },
    }
}

// ── Per-bar renderer ─────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn render_bar(
    pixmap: &mut Pixmap,
    font: &fontdue::Font,
    font_px: f32,
    spec: &BarSpec<'_>,
    y_offset: u32,
    width: u32,
    height: u32,
) {
    // Label (vertically centred in this row).
    let label_baseline = y_offset as i32 + (height as f32 / 2.0 + font_px * 0.35) as i32;
    draw_text(pixmap, font, spec.label, 4, label_baseline, font_px, FG_MUTED);

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

    // Fill.
    match spec.fill {
        None => {
            // No fill — leave the empty rail.
        }
        Some(Fill::PaceGradient { pace, elapsed_pct }) => {
            let fill_w =
                ((elapsed_pct.clamp(0.0, 100.0) / 100.0) * rail_w as f32).round() as u32;
            if fill_w > 0 {
                let tip_rgb = pace_color(pace);
                let green = (0u8, 200u8, 83u8);
                for px in 0..fill_w {
                    let t = if fill_w <= 1 {
                        0.0f32
                    } else {
                        px as f32 / (fill_w - 1) as f32
                    };
                    let (r, g, b) = oklab_lerp(green, tip_rgb, t);
                    fill_rect(pixmap, rail_x + px, bar_y, 1, bar_h, (r, g, b, 255));
                }
            }
        }
        Some(Fill::ContextSolid { pct }) => {
            let fill_w = ((pct.clamp(0.0, 100.0) / 100.0) * rail_w as f32).round() as u32;
            if fill_w > 0 {
                let (r, g, b) = context_color(pct);
                fill_rect(pixmap, rail_x, bar_y, fill_w, bar_h, (r, g, b, 255));
            }
        }
    }

    // Right-side text — right-aligned inside the rail.
    if let Some(ref text) = spec.right_text {
        let (tr, tg, tb) = spec.right_text_color.unwrap_or((FG_MUTED.0, FG_MUTED.1, FG_MUTED.2));
        let approx_text_w = (text.len() as f32 * font_px * 0.6) as i32;
        let text_x = (width as i32) - approx_text_w - 4;
        let text_baseline = y_offset as i32 + (height as f32 / 2.0 + font_px * 0.35) as i32;
        draw_text(
            pixmap,
            font,
            text,
            text_x,
            text_baseline,
            font_px,
            (tr, tg, tb, 220),
        );
    }
}

// ── Colour helpers ────────────────────────────────────────────────────────────

/// Map a context-window usage percentage to a threshold colour.
///
/// - `pct < 70.0`   → cool blue  `(64, 156, 255)` — healthy headroom
/// - `70.0..90.0`   → amber      `(255, 176, 0)`  — getting full
/// - `pct >= 90.0`  → red        `(213, 0, 0)`    — critically full
///
/// Matches the same red anchor used by `pace_color` at pace = 1.5 so the
/// two bars share a visual language for "danger."
pub fn context_color(pct: f32) -> (u8, u8, u8) {
    if pct < 70.0 {
        (64, 156, 255) // cool blue
    } else if pct < 90.0 {
        (255, 176, 0) // amber
    } else {
        (213, 0, 0) // red
    }
}

/// Map a pace value to an RGB colour via two-segment OKLab interpolation.
///
/// Anchors:
/// - `0.0` → `#00C853` (vivid green)
/// - `1.0` → `#FFD600` (amber yellow)
/// - `1.5` → `#D50000` (vivid red)
///
/// Pace is clamped to `[0.0, 1.5]` before mapping.
pub fn pace_color(pace: f32) -> (u8, u8, u8) {
    let green = (0u8, 200u8, 83u8);
    let yellow = (255u8, 214u8, 0u8);
    let red = (213u8, 0u8, 0u8);

    let pace = pace.clamp(0.0, 1.5);
    if pace <= 1.0 {
        oklab_lerp(green, yellow, pace)
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

// ── Drawing primitives ────────────────────────────────────────────────────────

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

    // ── context_color threshold tests ─────────────────────────────────────────

    #[test]
    fn context_color_blue_under_70() {
        let (r, g, b) = context_color(0.0);
        assert_eq!((r, g, b), (64, 156, 255), "0% should be blue");

        let (r, g, b) = context_color(69.9);
        assert_eq!((r, g, b), (64, 156, 255), "69.9% should be blue");
    }

    #[test]
    fn context_color_amber_70_to_90() {
        let (r, g, b) = context_color(70.0);
        assert_eq!((r, g, b), (255, 176, 0), "70% should be amber");

        let (r, g, b) = context_color(89.9);
        assert_eq!((r, g, b), (255, 176, 0), "89.9% should be amber");
    }

    #[test]
    fn context_color_red_at_90() {
        let (r, g, b) = context_color(90.0);
        assert_eq!((r, g, b), (213, 0, 0), "90% should be red");

        let (r, g, b) = context_color(100.0);
        assert_eq!((r, g, b), (213, 0, 0), "100% should be red");
    }

    #[test]
    fn context_color_clamped() {
        // Negative value → treated as < 70 → blue.
        let (r, g, b) = context_color(-10.0);
        assert_eq!((r, g, b), (64, 156, 255), "negative should be blue");

        // Value > 100 → treated as ≥ 90 → red.
        let (r, g, b) = context_color(150.0);
        assert_eq!((r, g, b), (213, 0, 0), ">100 should be red");
    }

    // ── render smoke test ─────────────────────────────────────────────────────

    #[test]
    fn render_with_four_bars() {
        let specs: Vec<BarSpec<'_>> = vec![
            BarSpec {
                label: "ctx",
                fill: Some(Fill::ContextSolid { pct: 57.0 }),
                right_text: Some("57%".to_string()),
                right_text_color: Some(context_color(57.0)),
            },
            BarSpec {
                label: "5h",
                fill: Some(Fill::PaceGradient { pace: 0.8, elapsed_pct: 60.0 }),
                right_text: Some("0.80".to_string()),
                right_text_color: Some(pace_color(0.8)),
            },
            BarSpec {
                label: "7d",
                fill: Some(Fill::PaceGradient { pace: 1.1, elapsed_pct: 40.0 }),
                right_text: Some("1.10".to_string()),
                right_text_color: Some(pace_color(1.1)),
            },
            BarSpec {
                label: "son",
                fill: None,
                right_text: None,
                right_text_color: None,
            },
        ];

        let img = render_pace_bars_to_image(&specs, 400, 64);
        // Should produce a non-empty image at the requested size.
        assert_eq!(img.width(), 400);
        assert_eq!(img.height(), 64);
        // Image should not be all-black (background is BG=(20,20,28)).
        let rgba = img.to_rgba8();
        let first_pixel = rgba.get_pixel(0, 0);
        assert_eq!(first_pixel[0], 20, "background R");
        assert_eq!(first_pixel[1], 20, "background G");
        assert_eq!(first_pixel[2], 28, "background B");
    }

    // ── existing pace_color / oklab tests ─────────────────────────────────────

    #[test]
    fn pace_color_green_at_zero() {
        let (r, g, b) = pace_color(0.0);
        assert!(r < 50, "red should be low for green: {r}");
        assert!(g > 180, "green should be high for green: {g}");
        assert!(b < 110, "blue should be significantly lower than green: {b}");
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
        assert_eq!(pace_color(2.0), pace_color(1.5));
        assert_eq!(pace_color(-0.5), pace_color(0.0));
    }
}
