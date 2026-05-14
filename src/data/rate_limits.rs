//! Claude rate-limit and budget-posture data types with on-disk loaders.
//!
//! Rate limits are written to `/tmp/.claude-rate-limits` by external agents in
//! the format `p5h:reset5h_epoch:p7d:reset7d_epoch` (colon-delimited integers).
//! Percentages are 0–100, or -1 for unknown.  Reset epochs are Unix timestamps.
//!
//! Budget posture is written to `~/.claude/budget-posture.json` as
//! `{"posture": "<flush|normal|elevated|conservative|critical>"}`.

use ratatui::style::Color;

// ── RateLimits ────────────────────────────────────────────────────────────────

/// Snapshot of Claude's 5-hour and 7-day rate-limit windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct RateLimits {
    /// Percentage consumed in the 5-hour window (-1 = unknown).
    pub pct_5h: i32,
    /// Unix epoch when the 5-hour window resets.
    pub reset_5h: i64,
    /// Percentage consumed in the 7-day window (-1 = unknown).
    pub pct_7d: i32,
    /// Unix epoch when the 7-day window resets.
    pub reset_7d: i64,
}

impl RateLimits {
    /// Load from `/tmp/.claude-rate-limits`.
    ///
    /// Returns `None` if the file is absent or cannot be parsed.
    pub fn load() -> Option<Self> {
        let content = std::fs::read_to_string("/tmp/.claude-rate-limits").ok()?;
        Self::parse(content.trim())
    }

    fn parse(s: &str) -> Option<Self> {
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() < 4 {
            return None;
        }
        let pct_5h = parts[0].parse::<i32>().ok()?;
        let reset_5h = parts[1].parse::<i64>().ok()?;
        let pct_7d = parts[2].parse::<i32>().ok()?;
        let reset_7d = parts[3].parse::<i64>().ok()?;
        Some(Self {
            pct_5h,
            reset_5h,
            pct_7d,
            reset_7d,
        })
    }
}

// ── BudgetPosture ─────────────────────────────────────────────────────────────

/// Global budget posture level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BudgetPosture {
    Flush,
    Normal,
    Elevated,
    Conservative,
    Critical,
}

impl BudgetPosture {
    /// Load from `~/.claude/budget-posture.json`.
    ///
    /// Returns `None` if the file is absent, unreadable, or has an unknown posture.
    pub fn load() -> Option<Self> {
        let home = dirs_next::home_dir()?;
        let path = home.join(".claude").join("budget-posture.json");
        let content = std::fs::read_to_string(path).ok()?;
        Self::parse_json(&content)
    }

    fn parse_json(s: &str) -> Option<Self> {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        let posture = v.get("posture")?.as_str()?;
        Self::from_str(posture)
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "flush" => Some(Self::Flush),
            "normal" => Some(Self::Normal),
            "elevated" => Some(Self::Elevated),
            "conservative" => Some(Self::Conservative),
            "critical" => Some(Self::Critical),
            _ => None,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Flush => "flush",
            Self::Normal => "normal",
            Self::Elevated => "elevated",
            Self::Conservative => "conservative",
            Self::Critical => "critical",
        }
    }

    pub fn color(&self) -> Color {
        match self {
            Self::Flush => Color::LightGreen,
            Self::Normal => Color::DarkGray,
            Self::Elevated => Color::Yellow,
            Self::Conservative => Color::Rgb(255, 165, 0),
            Self::Critical => Color::LightRed,
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_rate_limits_valid() {
        let rl = RateLimits::parse("85:1715200000:42:1715800000").unwrap();
        assert_eq!(rl.pct_5h, 85);
        assert_eq!(rl.reset_5h, 1715200000);
        assert_eq!(rl.pct_7d, 42);
        assert_eq!(rl.reset_7d, 1715800000);
    }

    #[test]
    fn parse_rate_limits_malformed_returns_none() {
        assert!(RateLimits::parse("").is_none());
        assert!(RateLimits::parse("85:abc:42").is_none());
        assert!(RateLimits::parse("85:1715200000:42").is_none()); // only 3 fields
    }

    #[test]
    fn parse_budget_posture_elevated() {
        let bp = BudgetPosture::parse_json(r#"{"posture":"elevated"}"#).unwrap();
        assert_eq!(bp, BudgetPosture::Elevated);
    }

    #[test]
    fn parse_budget_posture_unknown_returns_none() {
        assert!(BudgetPosture::parse_json(r#"{"posture":"banana"}"#).is_none());
        assert!(BudgetPosture::parse_json("{}").is_none());
        assert!(BudgetPosture::parse_json("not json").is_none());
    }

    #[test]
    fn all_postures_parse() {
        for (s, expected) in &[
            ("flush", BudgetPosture::Flush),
            ("normal", BudgetPosture::Normal),
            ("elevated", BudgetPosture::Elevated),
            ("conservative", BudgetPosture::Conservative),
            ("critical", BudgetPosture::Critical),
        ] {
            let json = format!(r#"{{"posture":"{}"}}"#, s);
            assert_eq!(BudgetPosture::parse_json(&json).unwrap(), *expected);
        }
    }
}
