//! Colour palette — ported from ~/.claude/lib/fred/format.sh.
//!
//! The "sweater" metaphor: sage = calm, amber = warm/busy, red = hot.
//! These same colours are used for VIP highlights, calendar load, PR queue
//! depth, and job runtime indicators.

use ratatui::style::{Color, Modifier, Style};

// ── Base colours ────────────────────────────────────────────────────────────

/// Sage green — low-load / all-clear.
pub const SAGE: Color = Color::Rgb(143, 188, 143);
/// Warm amber — moderate load / attention.
pub const AMBER: Color = Color::Rgb(255, 191, 0);
/// Red sweater — high load / alert.
pub const RED_SWEATER: Color = Color::Rgb(205, 92, 92);

/// Foreground for content text.
pub const FG: Color = Color::Rgb(220, 220, 220);
/// Muted / secondary text.
pub const FG_MUTED: Color = Color::Rgb(140, 140, 140);
/// Highlighted / active border.
pub const BORDER_ACTIVE: Color = Color::Rgb(100, 149, 237); // cornflower
/// Inactive border.
pub const BORDER_INACTIVE: Color = Color::Rgb(70, 70, 80);
/// Background.
pub const BG: Color = Color::Reset;

/// VIP highlight colour.
pub const VIP: Color = Color::Rgb(255, 215, 0); // gold

/// Unread badge colour.
pub const UNREAD: Color = Color::Rgb(255, 100, 100);

// ── Sweater logic ────────────────────────────────────────────────────────────

/// Sweater level from the calendar/load signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sweater {
    #[default]
    Sage,
    Amber,
    Red,
}

impl Sweater {
    /// Parse from the string emitted by `fred-calendar-pane --json`.
    pub fn from_str(s: &str) -> Self {
        match s {
            "amber" => Self::Amber,
            "red" => Self::Red,
            _ => Self::Sage,
        }
    }

    /// The border / accent colour for this sweater level.
    pub fn color(self) -> Color {
        match self {
            Self::Sage => SAGE,
            Self::Amber => AMBER,
            Self::Red => RED_SWEATER,
        }
    }
}

// ── Style helpers ────────────────────────────────────────────────────────────

pub fn style_normal() -> Style {
    Style::default().fg(FG)
}

pub fn style_muted() -> Style {
    Style::default().fg(FG_MUTED)
}

pub fn style_vip() -> Style {
    Style::default().fg(VIP).add_modifier(Modifier::BOLD)
}

pub fn style_unread() -> Style {
    Style::default().fg(UNREAD).add_modifier(Modifier::BOLD)
}

pub fn style_sage() -> Style {
    Style::default().fg(SAGE)
}

pub fn style_amber() -> Style {
    Style::default().fg(AMBER)
}

pub fn style_red() -> Style {
    Style::default().fg(RED_SWEATER)
}

pub fn style_for_sweater(s: Sweater) -> Style {
    match s {
        Sweater::Sage => style_sage(),
        Sweater::Amber => style_amber(),
        Sweater::Red => style_red(),
    }
}
