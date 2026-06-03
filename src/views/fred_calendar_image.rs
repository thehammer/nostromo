//! Pixel-rendered calendar for the Fred view.
//!
//! Renders the same timeline data as `render_calendar_lines()` but into a
//! `DynamicImage` using `tiny-skia` (vector fill) and `fontdue` (glyph
//! rasterisation).  The image is passed to `ratatui-image`'s `Picker` so it
//! can be displayed via the Kitty graphics protocol (or halfblock fallback).

use chrono::{DateTime, Local, TimeZone};
use tiny_skia::{Paint, Pixmap, Rect as SkRect, Transform};

use crate::data::fred_calendar::CalendarSnapshot;
use crate::views::fred::assign_columns;

// ── Embedded font ────────────────────────────────────────────────────────────

static FONT_BYTES: &[u8] = include_bytes!("../../assets/font.ttf");

// ── Layout constants ─────────────────────────────────────────────────────────

/// Left-margin width in pixels for the time labels — computed dynamically from
/// font size; this constant is the fallback minimum.
const LABEL_PX_MIN: u32 = 50;
/// Working hours start (local, inclusive).
const WORK_START_HOUR: u32 = 8;
/// Working hours end (local, exclusive).
const WORK_END_HOUR: u32 = 18;
/// Minutes per visual slot row — must match `fred.rs::MINS_PER_ROW`.
const MINS_PER_ROW: u32 = 15;

// ── Colour palette (mirrors ui::theme) ───────────────────────────────────────

const BG: (u8, u8, u8, u8) = (20, 20, 28, 255);
const GRID_LINE: (u8, u8, u8, u8) = (45, 45, 58, 255);
const AMBER: (u8, u8, u8, u8) = (255, 191, 0, 255);
const AMBER_DIM: (u8, u8, u8, u8) = (100, 75, 0, 220);
const FG_MUTED: (u8, u8, u8, u8) = (140, 140, 140, 255);
const PAST_FILL: (u8, u8, u8, u8) = (38, 38, 50, 200);
const PAST_TEXT: (u8, u8, u8, u8) = (90, 90, 100, 200);
const NOW_FILL: (u8, u8, u8, u8) = (80, 60, 0, 230);
const NOW_BORDER: (u8, u8, u8, u8) = (255, 191, 0, 255);
const NOW_TEXT: (u8, u8, u8, u8) = (255, 210, 60, 255);
const FUTURE_FILL: (u8, u8, u8, u8) = (30, 52, 88, 230);
const FUTURE_BORDER: (u8, u8, u8, u8) = (80, 120, 200, 255);
const FUTURE_TEXT: (u8, u8, u8, u8) = (180, 200, 235, 255);
const CANCEL_FILL: (u8, u8, u8, u8) = (35, 35, 40, 190);
const CANCEL_TEXT: (u8, u8, u8, u8) = (90, 90, 96, 190);
const TENT_FILL: (u8, u8, u8, u8) = (35, 48, 58, 190);
const TENT_TEXT: (u8, u8, u8, u8) = (110, 140, 165, 200);

// ── Public entry point ────────────────────────────────────────────────────────

/// Render the calendar snapshot into a pixel image.
///
/// - `width_px` / `height_px` — pixel dimensions of the target terminal pane.
/// - `scroll_offset_rows` — number of 15-minute slot rows scrolled from the
///   top; mirrors `FredView::calendar_scroll`.
/// - `cell_height_px` — height of one terminal cell in pixels (from
///   `Picker::font_size().1`).
///
/// Returns an RGBA `DynamicImage` ready to be handed to
/// `Picker::new_resize_protocol()`.
pub fn render_calendar_to_image(
    snap: &CalendarSnapshot,
    width_px: u32,
    height_px: u32,
    scroll_offset_rows: u16,
    cell_height_px: u16,
) -> image::DynamicImage {
    let w = width_px.max(1);
    let h = height_px.max(1);
    let mut pixmap = Pixmap::new(w, h).unwrap_or_else(|| Pixmap::new(1, 1).unwrap());

    // Background fill.
    fill_rect(&mut pixmap, 0, 0, w, h, BG);

    let font = match fontdue::Font::from_bytes(FONT_BYTES, fontdue::FontSettings::default()) {
        Ok(f) => f,
        Err(_) => return pixmap_to_dynamic_image(pixmap),
    };

    let row_h = cell_height_px as f32;
    let px_per_min = row_h / MINS_PER_ROW as f32;
    let scroll_px = scroll_offset_rows as f32 * row_h;
    let font_px = (row_h * 0.85).clamp(11.0, 22.0);
    // "HH:MM" is 5 chars; estimate ~0.6× font_px per char + a little padding.
    let label_px = ((font_px * 5.0 * 0.62) as u32 + 6).max(LABEL_PX_MIN);

    let now: DateTime<Local> = chrono::Local::now();
    let today = now.date_naive();
    let work_start = Local
        .from_local_datetime(&today.and_hms_opt(WORK_START_HOUR, 0, 0).unwrap())
        .earliest()
        .unwrap();
    let work_end = Local
        .from_local_datetime(&today.and_hms_opt(WORK_END_HOUR, 0, 0).unwrap())
        .earliest()
        .unwrap();
    let total_mins = (work_end - work_start).num_minutes() as f32;

    // Column assignment.
    let col_indices = assign_columns(&snap.events);
    let content_w = w.saturating_sub(label_px);

    // For each event, compute the local column count: how many columns are
    // needed among the group of events that overlap with it.  Events that don't
    // overlap with anything else get local_cols = 1 (full width).
    let local_cols: Vec<usize> = snap.events.iter().enumerate().map(|(i, ev_i)| {
        let max_col = snap.events.iter().enumerate()
            .filter(|&(j, ev_j)| {
                if j == i { return true; }
                // Check temporal overlap.
                let (s_i, e_i) = (ev_i.start, ev_i.end.or(ev_i.start));
                let (s_j, e_j) = (ev_j.start, ev_j.end.or(ev_j.start));
                match (s_i, e_i, s_j, e_j) {
                    (Some(si), Some(ei), Some(sj), Some(ej)) => si < ej && sj < ei,
                    _ => false,
                }
            })
            .map(|(j, _)| col_indices[j])
            .max()
            .unwrap_or(0);
        max_col + 1
    }).collect();

    // ── Hour grid lines & labels ───────────────────────────────────────────
    for hour in WORK_START_HOUR..=WORK_END_HOUR {
        let mins_from_start = (hour - WORK_START_HOUR) * 60;
        let y = mins_from_start as f32 * px_per_min - scroll_px;
        if y >= -(row_h) && y < h as f32 {
            let iy = y.round() as i32;
            hline(&mut pixmap, 0, w, iy, GRID_LINE);
            let label = format!("{hour:02}:00");
            draw_text(&mut pixmap, &font, &label, 2, iy + 1, font_px, FG_MUTED);
        }
    }

    // ── Events ────────────────────────────────────────────────────────────
    for (ev_idx, ev) in snap.events.iter().enumerate() {
        let start_utc = match ev.start {
            Some(s) => s,
            None => continue,
        };
        let end_utc = ev.end.unwrap_or(start_utc + chrono::Duration::minutes(30));
        let start_local: DateTime<Local> = start_utc.into();
        let end_local: DateTime<Local> = end_utc.into();

        // Skip events outside working hours.
        if start_local >= work_end || end_local <= work_start {
            continue;
        }

        let clamped_start = start_local.max(work_start);
        let clamped_end = end_local.min(work_end);

        let start_mins = (clamped_start - work_start).num_minutes() as f32;
        let end_mins = (clamped_end - work_start).num_minutes() as f32;
        let end_mins = end_mins.min(total_mins);

        let y_start = start_mins * px_per_min - scroll_px;
        let y_end = end_mins * px_per_min - scroll_px;

        // Skip if entirely outside viewport.
        if y_end < 0.0 || y_start > h as f32 {
            continue;
        }

        let col = col_indices[ev_idx];
        let n_cols = local_cols[ev_idx] as u32;
        let col_w = (content_w / n_cols).max(1);
        let x0 = label_px + col as u32 * col_w + 2;
        let x1 = (label_px + (col as u32 + 1) * col_w)
            .min(w)
            .saturating_sub(2);
        if x1 <= x0 {
            continue;
        }

        let y0 = y_start.max(0.0) as u32;
        let y1 = y_end.min(h as f32 - 1.0) as u32;
        if y1 <= y0 {
            continue;
        }

        let is_cancelled = ev.status == "cancelled" || ev.status == "declined";
        let is_tentative = ev.status == "tentativelyAccepted";
        let is_past = !ev.is_now && end_local < now;

        let (fill, border, text_color) = if is_cancelled {
            (CANCEL_FILL, CANCEL_TEXT, CANCEL_TEXT)
        } else if is_tentative {
            (TENT_FILL, TENT_TEXT, TENT_TEXT)
        } else if ev.is_now {
            (NOW_FILL, NOW_BORDER, NOW_TEXT)
        } else if is_past {
            (PAST_FILL, PAST_TEXT, PAST_TEXT)
        } else {
            (FUTURE_FILL, FUTURE_BORDER, FUTURE_TEXT)
        };

        fill_rect(&mut pixmap, x0, y0, x1 - x0, y1 - y0, fill);
        rect_outline(&mut pixmap, x0, y0, x1, y1, border);

        // Title text — only if there's room.
        let ev_height_px = (y1 - y0) as f32;
        if ev_height_px >= font_px + 2.0 {
            let prefix = if ev.is_now { "▶ " } else { "" };
            let title = format!("{prefix}{}", ev.title);
            let baseline_y = y0 as i32 + font_px as i32 + 1;
            draw_text(
                &mut pixmap,
                &font,
                &title,
                x0 as i32 + 3,
                baseline_y,
                font_px,
                text_color,
            );
        }
    }

    // ── "now" marker ──────────────────────────────────────────────────────
    let now_within = now >= work_start && now < work_end;
    if now_within {
        let now_mins = (now - work_start).num_minutes() as f32;
        let now_y = now_mins * px_per_min - scroll_px;
        if now_y >= 0.0 && now_y < h as f32 {
            let iy = now_y.round() as i32;
            // Thick amber line.
            hline(&mut pixmap, label_px, w, iy, AMBER);
            if iy + 1 < h as i32 {
                hline(&mut pixmap, label_px, w, iy + 1, AMBER_DIM);
            }
            // "now" label.
            draw_text(&mut pixmap, &font, "now", 2, iy + 1, font_px, AMBER);
        }
    }

    pixmap_to_dynamic_image(pixmap)
}

// ── Drawing primitives ────────────────────────────────────────────────────────

fn rgba_color(c: (u8, u8, u8, u8)) -> tiny_skia::Color {
    tiny_skia::Color::from_rgba8(c.0, c.1, c.2, c.3)
}

fn fill_rect(pixmap: &mut Pixmap, x: u32, y: u32, w: u32, h: u32, color: (u8, u8, u8, u8)) {
    if w == 0 || h == 0 {
        return;
    }
    let mut paint = Paint::default();
    paint.set_color(rgba_color(color));
    paint.anti_alias = false;
    if let Some(rect) = SkRect::from_xywh(x as f32, y as f32, w as f32, h as f32) {
        pixmap.fill_rect(rect, &paint, Transform::identity(), None);
    }
}

fn rect_outline(pixmap: &mut Pixmap, x0: u32, y0: u32, x1: u32, y1: u32, color: (u8, u8, u8, u8)) {
    if x1 <= x0 || y1 <= y0 {
        return;
    }
    // top & bottom
    hline(pixmap, x0, x1, y0 as i32, color);
    hline(pixmap, x0, x1, (y1 - 1) as i32, color);
    // left & right (single pixel wide)
    vline(pixmap, x0, y0, y1, color);
    vline(pixmap, x1 - 1, y0, y1, color);
}

fn hline(pixmap: &mut Pixmap, x0: u32, x1: u32, y: i32, color: (u8, u8, u8, u8)) {
    if y < 0 || y >= pixmap.height() as i32 {
        return;
    }
    let y = y as u32;
    let x0 = x0.min(pixmap.width());
    let x1 = x1.min(pixmap.width());
    if x1 <= x0 {
        return;
    }
    fill_rect(pixmap, x0, y, x1 - x0, 1, color);
}

fn vline(pixmap: &mut Pixmap, x: u32, y0: u32, y1: u32, color: (u8, u8, u8, u8)) {
    if x >= pixmap.width() || y1 <= y0 {
        return;
    }
    fill_rect(pixmap, x, y0, 1, y1 - y0, color);
}

/// Render `text` into `pixmap` with the given font, baseline at `baseline_y`.
///
/// `x` is the left edge of the text.  Glyphs are composited using their
/// coverage bitmap as alpha over the existing pixel colour.
fn draw_text(
    pixmap: &mut Pixmap,
    font: &fontdue::Font,
    text: &str,
    x: i32,
    baseline_y: i32,
    size_px: f32,
    color: (u8, u8, u8, u8),
) {
    // Cache dimensions before taking the mutable pixels slice.
    let pw = pixmap.width() as i32;
    let ph = pixmap.height() as i32;
    let stride = pixmap.width();
    let (cr, cg, cb) = (color.0, color.1, color.2);
    let global_alpha = color.3 as f32 / 255.0;
    let pixels = pixmap.pixels_mut();

    let mut cursor_x = x;

    for ch in text.chars() {
        // Skip non-printable / non-BMP characters that may be expensive.
        if ch < ' ' {
            continue;
        }
        let (metrics, bitmap) = font.rasterize(ch, size_px);
        if metrics.width == 0 || metrics.height == 0 {
            cursor_x += metrics.advance_width as i32;
            continue;
        }

        // Top-left pixel of this glyph's bounding box.
        let gx0 = cursor_x + metrics.xmin;
        let gy0 = baseline_y - metrics.ymin - metrics.height as i32;

        for row in 0..metrics.height {
            let py = gy0 + row as i32;
            if py < 0 || py >= ph {
                continue;
            }
            for col in 0..metrics.width {
                let px = gx0 + col as i32;
                if px < 0 || px >= pw {
                    continue;
                }

                let coverage = bitmap[row * metrics.width + col] as f32 / 255.0;
                if coverage < 0.005 {
                    continue;
                }
                let alpha = coverage * global_alpha;

                let idx = (py as u32 * stride + px as u32) as usize;
                // Tiny-skia stores premultiplied RGBA.  Since our background
                // is fully opaque we can treat it as straight for blending.
                let dst = pixels[idx];
                let dr = dst.red() as f32;
                let dg = dst.green() as f32;
                let db = dst.blue() as f32;

                let nr = (cr as f32 * alpha + dr * (1.0 - alpha)).round() as u8;
                let ng = (cg as f32 * alpha + dg * (1.0 - alpha)).round() as u8;
                let nb = (cb as f32 * alpha + db * (1.0 - alpha)).round() as u8;

                // Result is fully opaque (background was opaque).
                pixels[idx] =
                    tiny_skia::PremultipliedColorU8::from_rgba(nr, ng, nb, 255).unwrap_or(dst);
            }
        }

        cursor_x += metrics.advance_width as i32;
    }
}

// ── Pixmap → DynamicImage ─────────────────────────────────────────────────────

/// Convert a `tiny-skia` `Pixmap` (premultiplied RGBA) into an
/// `image::DynamicImage` (straight RGBA) for `ratatui-image`.
fn pixmap_to_dynamic_image(pixmap: Pixmap) -> image::DynamicImage {
    let w = pixmap.width();
    let h = pixmap.height();
    let raw = pixmap.take(); // Vec<u8>, RGBA premultiplied

    // Un-premultiply alpha for the image crate.
    let mut rgba = Vec::with_capacity(raw.len());
    for chunk in raw.chunks_exact(4) {
        let r = chunk[0];
        let g = chunk[1];
        let b = chunk[2];
        let a = chunk[3];
        if a == 0 {
            rgba.extend_from_slice(&[0, 0, 0, 0]);
        } else if a == 255 {
            rgba.extend_from_slice(&[r, g, b, 255]);
        } else {
            let af = a as f32 / 255.0;
            let ur = (r as f32 / af).round().min(255.0) as u8;
            let ug = (g as f32 / af).round().min(255.0) as u8;
            let ub = (b as f32 / af).round().min(255.0) as u8;
            rgba.extend_from_slice(&[ur, ug, ub, a]);
        }
    }

    let img = image::RgbaImage::from_raw(w, h, rgba).unwrap_or_else(|| image::RgbaImage::new(w, h));
    image::DynamicImage::ImageRgba8(img)
}
