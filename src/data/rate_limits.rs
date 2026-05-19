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
///
/// Supports both Bishop's original lowercase vocabulary
/// (`flush/normal/elevated/conservative/critical`) and the newer
/// operator-action-oriented vocabulary
/// (`Pump the brakes / Ease up / Cruise / Push / Put the hammer down`).
/// Both are parsed; the original variants are deprecated but kept for
/// backward compatibility.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BudgetPosture {
    // Legacy lowercase vocabulary (kept for backward compat).
    Flush,
    Normal,
    Elevated,
    Conservative,
    Critical,
    // Current Bishop vocabulary (operator-action-oriented, by pace).
    /// Slowest pace bracket — over-spending, needs immediate restraint.
    PumpTheBrakes,
    /// Slightly above expected pace.
    EaseUp,
    /// At expected pace — sustainable.
    Cruise,
    /// Under-spending — has margin to push harder.
    Push,
    /// Way under-spending — plenty of budget left.
    PutTheHammerDown,
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

    /// Parse a posture string from either vocabulary.
    ///
    /// Case-insensitive on the lowercase tier and exact-match on the
    /// title-cased tier. Falls back to `Normal` for unrecognised strings
    /// (preferring a defensible default over a `None` that hides the
    /// pace bars entirely on the next vocabulary drift).
    fn from_str(s: &str) -> Option<Self> {
        let trimmed = s.trim();
        // Original lowercase vocabulary.
        match trimmed.to_lowercase().as_str() {
            "flush" => return Some(Self::Flush),
            "normal" => return Some(Self::Normal),
            "elevated" => return Some(Self::Elevated),
            "conservative" => return Some(Self::Conservative),
            "critical" => return Some(Self::Critical),
            _ => {}
        }
        // Current Bishop vocabulary (exact title-case match as emitted).
        match trimmed {
            "Pump the brakes" => Some(Self::PumpTheBrakes),
            "Ease up" => Some(Self::EaseUp),
            "Cruise" => Some(Self::Cruise),
            "Push" => Some(Self::Push),
            "Put the hammer down" => Some(Self::PutTheHammerDown),
            // Unknown vocabulary — fall back to Normal so the chrome pace
            // bars keep rendering and we don't silently lose the widget on
            // the next Bishop release.
            _ => Some(Self::Normal),
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Flush => "flush",
            Self::Normal => "normal",
            Self::Elevated => "elevated",
            Self::Conservative => "conservative",
            Self::Critical => "critical",
            Self::PumpTheBrakes => "Pump the brakes",
            Self::EaseUp => "Ease up",
            Self::Cruise => "Cruise",
            Self::Push => "Push",
            Self::PutTheHammerDown => "Put the hammer down",
        }
    }

    pub fn color(&self) -> Color {
        match self {
            // Legacy mapping (from low-budget-pressure → high).
            Self::Flush => Color::LightGreen,
            Self::Normal => Color::DarkGray,
            Self::Elevated => Color::Yellow,
            Self::Conservative => Color::Rgb(255, 165, 0),
            Self::Critical => Color::LightRed,
            // New vocabulary mapping (pace-oriented).
            // Pump the brakes = burning budget too fast = warn red.
            Self::PumpTheBrakes => Color::LightRed,
            Self::EaseUp => Color::Rgb(255, 165, 0),
            Self::Cruise => Color::DarkGray,
            Self::Push => Color::Yellow,
            Self::PutTheHammerDown => Color::LightGreen,
        }
    }
}

// ── PostureSnapshot ───────────────────────────────────────────────────────────

/// Per-window pace metrics from `~/.claude/budget-posture.json`.
///
/// `pace = used_pct / elapsed_pct`. Values > 1 mean spending faster than expected.
#[derive(Debug, Clone)]
pub struct WindowPace {
    /// Percentage of the window budget already consumed (0–100).
    pub used_pct: f32,
    /// Percentage of the window's time that has elapsed (0–100).
    pub elapsed_pct: f32,
    /// Spending rate relative to uniform consumption (used_pct / elapsed_pct).
    pub pace: f32,
    /// Unix epoch when the window resets.
    pub resets_at: i64,
    /// Bishop's level string for this window ("flush", "normal", …).
    pub level: String,
}

/// Full snapshot of the Bishop budget-posture file.
///
/// Contains the global posture enum plus optional per-window pace data.
/// Both windows can be absent if the file only has `{"posture": "…"}`.
#[derive(Debug, Clone)]
pub struct PostureSnapshot {
    /// Global posture level (same as `BudgetPosture`).
    pub posture: BudgetPosture,
    /// Five-hour window metrics.
    pub five_hour: Option<WindowPace>,
    /// Seven-day window metrics.
    pub seven_day: Option<WindowPace>,
    /// Seven-day Sonnet-model metrics. Derived from `models.sonnet` —
    /// shares the seven-day window's elapsed_pct; pace = used_pct / elapsed_pct.
    pub sonnet_seven_day: Option<WindowPace>,
    /// When the file was loaded — used by the widget to detect fresh reads
    /// and trigger image re-encoding.
    pub loaded_at: std::time::Instant,
}

impl PostureSnapshot {
    /// Load from `~/.claude/budget-posture.json`.
    ///
    /// Returns `None` only if the file is absent/unreadable or the `posture`
    /// field is missing / unrecognised. Missing window objects result in
    /// `five_hour: None` / `seven_day: None` rather than a `None` return.
    pub fn load() -> Option<Self> {
        let home = dirs_next::home_dir()?;
        let path = home.join(".claude").join("budget-posture.json");
        let content = std::fs::read_to_string(path).ok()?;
        Self::parse_json(&content)
    }

    fn parse_json(s: &str) -> Option<Self> {
        let v: serde_json::Value = serde_json::from_str(s).ok()?;
        let posture = {
            let p_str = v.get("posture")?.as_str()?;
            BudgetPosture::from_str(p_str)?
        };
        let five_hour = parse_window_pace(&v, "five_hour");
        let seven_day = parse_window_pace(&v, "seven_day");
        let sonnet_seven_day = parse_sonnet_window(&v, seven_day.as_ref());
        Some(PostureSnapshot {
            posture,
            five_hour,
            seven_day,
            sonnet_seven_day,
            loaded_at: std::time::Instant::now(),
        })
    }
}

/// Build a `WindowPace` for the Sonnet model's 7-day window.
///
/// `models.sonnet` only carries `used_pct` and `resets_at`; we inherit
/// `elapsed_pct` from the shared 7-day window so the bar length means the
/// same thing as the other rails. `pace = used_pct / elapsed_pct`.
fn parse_sonnet_window(
    v: &serde_json::Value,
    seven_day: Option<&WindowPace>,
) -> Option<WindowPace> {
    let s = v.get("models")?.get("sonnet")?;
    if !s.is_object() {
        return None;
    }
    let used_pct = s.get("used_pct")?.as_f64()? as f32;
    let resets_at = s.get("resets_at")?.as_i64()?;
    let elapsed_pct = seven_day.map(|sd| sd.elapsed_pct).unwrap_or(0.0);
    let pace = if elapsed_pct > 0.0 {
        used_pct / elapsed_pct
    } else {
        0.0
    };
    let level = s
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("normal")
        .to_string();
    Some(WindowPace {
        used_pct,
        elapsed_pct,
        pace,
        resets_at,
        level,
    })
}

/// Extract a `WindowPace` from a JSON value under the given key.
///
/// Returns `None` silently if the key is absent or any required sub-field
/// is missing/malformed — matches the spec's "defensive" requirement.
fn parse_window_pace(v: &serde_json::Value, key: &str) -> Option<WindowPace> {
    let w = v.get(key)?;
    let used_pct = w.get("used_pct")?.as_f64()? as f32;
    let elapsed_pct = w.get("elapsed_pct")?.as_f64()? as f32;
    let pace = w.get("pace")?.as_f64()? as f32;
    let resets_at = w.get("resets_at")?.as_i64()?;
    let level = w.get("level")?.as_str()?.to_string();
    Some(WindowPace {
        used_pct,
        elapsed_pct,
        pace,
        resets_at,
        level,
    })
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
        // Unknown posture string no longer returns None — it falls back to
        // Normal (see `unknown_posture_falls_back_to_normal`). But missing
        // or malformed JSON still returns None.
        assert!(BudgetPosture::parse_json("{}").is_none());
        assert!(BudgetPosture::parse_json("not json").is_none());
    }

    #[test]
    fn all_postures_parse() {
        for (s, expected) in &[
            // Legacy lowercase vocabulary.
            ("flush", BudgetPosture::Flush),
            ("normal", BudgetPosture::Normal),
            ("elevated", BudgetPosture::Elevated),
            ("conservative", BudgetPosture::Conservative),
            ("critical", BudgetPosture::Critical),
            // Current Bishop vocabulary (Title Case with spaces).
            ("Pump the brakes", BudgetPosture::PumpTheBrakes),
            ("Ease up", BudgetPosture::EaseUp),
            ("Cruise", BudgetPosture::Cruise),
            ("Push", BudgetPosture::Push),
            ("Put the hammer down", BudgetPosture::PutTheHammerDown),
        ] {
            let json = format!(r#"{{"posture":"{}"}}"#, s);
            assert_eq!(BudgetPosture::parse_json(&json).unwrap(), *expected);
        }
    }

    #[test]
    fn unknown_posture_falls_back_to_normal() {
        // Defensive default so the chrome pace bars keep rendering when
        // Bishop introduces new vocabulary in a future release.
        let json = r#"{"posture":"BrandNewLevel"}"#;
        assert_eq!(
            BudgetPosture::parse_json(json).unwrap(),
            BudgetPosture::Normal
        );
    }

    // ── PostureSnapshot tests ─────────────────────────────────────────────────

    const RICH_JSON: &str = r#"{
        "posture": "normal",
        "five_hour": {
            "used_pct": 14.0,
            "elapsed_pct": 11.8,
            "pace": 1.18,
            "resets_at": 1715200000,
            "level": "normal"
        },
        "seven_day": {
            "used_pct": 7.0,
            "elapsed_pct": 6.6,
            "pace": 1.06,
            "resets_at": 1715800000,
            "level": "normal"
        },
        "models": {},
        "extra_usage": {}
    }"#;

    #[test]
    fn posture_snapshot_rich_json() {
        let snap = PostureSnapshot::parse_json(RICH_JSON).expect("should parse");
        assert_eq!(snap.posture, BudgetPosture::Normal);

        let fh = snap.five_hour.expect("5h should be present");
        assert!((fh.used_pct - 14.0).abs() < 0.01);
        assert!((fh.elapsed_pct - 11.8).abs() < 0.01);
        assert!((fh.pace - 1.18).abs() < 0.01);
        assert_eq!(fh.resets_at, 1715200000);
        assert_eq!(fh.level, "normal");

        let sd = snap.seven_day.expect("7d should be present");
        assert!((sd.used_pct - 7.0).abs() < 0.01);
        assert!((sd.elapsed_pct - 6.6).abs() < 0.01);
        assert!((sd.pace - 1.06).abs() < 0.01);
        assert_eq!(sd.resets_at, 1715800000);
        assert_eq!(sd.level, "normal");
    }

    #[test]
    fn posture_snapshot_posture_only() {
        let json = r#"{"posture":"elevated"}"#;
        let snap = PostureSnapshot::parse_json(json).expect("should parse");
        assert_eq!(snap.posture, BudgetPosture::Elevated);
        assert!(snap.five_hour.is_none(), "no 5h window in minimal JSON");
        assert!(snap.seven_day.is_none(), "no 7d window in minimal JSON");
    }

    #[test]
    fn posture_snapshot_missing_posture_returns_none() {
        assert!(PostureSnapshot::parse_json(r#"{"5h":{}}"#).is_none());
        assert!(PostureSnapshot::parse_json("not json").is_none());
    }

    #[test]
    fn posture_snapshot_partial_window_returns_none_for_that_window() {
        // 5h present but missing "pace" → five_hour is None, seven_day still parses.
        let json = r#"{
            "posture": "normal",
            "five_hour": { "used_pct": 14.0, "elapsed_pct": 11.8 },
            "seven_day": { "used_pct": 7.0, "elapsed_pct": 6.6, "pace": 1.06, "resets_at": 1715800000, "level": "normal" }
        }"#;
        let snap = PostureSnapshot::parse_json(json).unwrap();
        assert!(snap.five_hour.is_none());
        assert!(snap.seven_day.is_some());
    }
}
