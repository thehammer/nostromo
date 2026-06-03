//! Claude rate-limit and budget-posture data types with on-disk loaders.
//!
//! Rate limits are written to `/tmp/.claude-rate-limits` by external agents in
//! the format `p5h:reset5h_epoch:p7d:reset7d_epoch` (colon-delimited integers).
//! Percentages are 0–100, or -1 for unknown.  Reset epochs are Unix timestamps.
//!
//! Budget posture is written to `~/.claude/budget-posture.json` as
//! `{"posture": "<flush|normal|elevated|conservative|critical>"}`.
//!
//! Threshold events are written to `~/.claude/budget-posture.events.jsonl`
//! as append-only NDJSON lines by Bishop.

use std::collections::BTreeMap;

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

// ── AgentSpend ────────────────────────────────────────────────────────────────

/// Token spend attributed to a single Mother-tracked agent for both budget
/// windows, as emitted by Bishop in the `agents` map of `budget-posture.json`.
///
/// Counts are raw token integers, never 0–100 percentages.
#[derive(Debug, Clone)]
pub struct AgentSpend {
    /// Input tokens consumed in the 5-hour window.
    pub tokens_in_5h: u64,
    /// Output tokens consumed in the 5-hour window.
    pub tokens_out_5h: u64,
    /// Input tokens consumed in the 7-day window.
    pub tokens_in_7d: u64,
    /// Output tokens consumed in the 7-day window.
    pub tokens_out_7d: u64,
}

/// Which budget window to use when computing an agent's share of attributed
/// tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentWindow {
    FiveHour,
    SevenDay,
}

// ── ThresholdSeverity / PostureThresholdEvent ─────────────────────────────────

/// Display severity for a threshold-crossing event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThresholdSeverity {
    /// Non-alarming informational change (e.g. `pace_recovered`).
    Info,
    /// Notable but not critical (e.g. `pace_warning`).
    Warn,
    /// Immediate attention required (e.g. `overage_started`, `pace_critical`).
    Alert,
}

/// Map a Bishop `trigger` string to its display severity.
///
/// Unknown triggers default to `Warn` — visible but not alarm-fatigue-inducing
/// on future Bishop vocabulary expansions.
pub fn threshold_severity(trigger: &str) -> ThresholdSeverity {
    match trigger {
        "pace_recovered" => ThresholdSeverity::Info,
        "pace_warning" => ThresholdSeverity::Warn,
        "pace_critical" | "overage_started" | "exhaustion_imminent" => ThresholdSeverity::Alert,
        _ => ThresholdSeverity::Warn,
    }
}

/// A single `threshold_crossed` event from `~/.claude/budget-posture.events.jsonl`.
#[derive(Debug, Clone)]
pub struct PostureThresholdEvent {
    /// ISO-8601 timestamp as emitted by Bishop.
    pub ts: String,
    /// Budget window: `"five_hour"` | `"seven_day"` | `"account"`.
    pub window: String,
    /// Trigger type: `"pace_warning"` | `"pace_critical"` | `"pace_recovered"` |
    /// `"overage_started"` | `"exhaustion_imminent"`.
    pub trigger: String,
    /// Spend rate relative to uniform consumption (>1 = over-pacing).
    /// Present on `pace_warning` and `pace_critical` events.
    pub pace: Option<f64>,
    /// Minutes until window exhaustion.  Present on `exhaustion_imminent` events.
    pub minutes_remaining: Option<f64>,
}

impl PostureThresholdEvent {
    /// Parse a single NDJSON line from the posture events file.
    ///
    /// Returns `None` if:
    /// - The line is empty or not valid JSON.
    /// - The `"type"` field is absent or is not `"threshold_crossed"`.
    /// - Required fields (`ts`, `window`, `trigger`) are missing.
    ///
    /// Missing `pace` / `minutes_remaining` fields silently become `None`.
    pub fn parse_line(line: &str) -> Option<Self> {
        if line.is_empty() {
            return None;
        }
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        if v.get("type")?.as_str()? != "threshold_crossed" {
            return None;
        }
        let ts = v.get("ts")?.as_str()?.to_string();
        let window = v.get("window")?.as_str()?.to_string();
        let trigger = v.get("trigger")?.as_str()?.to_string();
        let pace = v.get("pace").and_then(|p| p.as_f64());
        let minutes_remaining = v.get("minutes_remaining").and_then(|m| m.as_f64());
        Some(Self {
            ts,
            window,
            trigger,
            pace,
            minutes_remaining,
        })
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
    /// Per-agent token spend keyed by agent name (e.g. `"cody"`, `"perri"`).
    ///
    /// Only Mother-attributable agents appear here; absent/empty → empty map.
    /// Raw token counts — never treat these as percentages.
    pub agents: BTreeMap<String, AgentSpend>,
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
        let sonnet_seven_day = parse_sonnet_window(&v);
        let agents = parse_agents_map(&v);
        Some(PostureSnapshot {
            posture,
            five_hour,
            seven_day,
            sonnet_seven_day,
            loaded_at: std::time::Instant::now(),
            agents,
        })
    }

    /// Return an agent's share of total attributed tokens for a given window.
    ///
    /// "Attributed" means the sum of ALL agents' tokens in the map for that
    /// window — not the window's total quota (which Bishop does not expose).
    /// This is honest: it never implies agents sum to 100% of window spend.
    ///
    /// Returns `None` when:
    /// - `self.agents` is empty (nothing to compare against).
    /// - `agent` is not present in the map.
    /// - All agents have zero tokens in that window (avoids 0/0).
    ///
    /// Returns `Some(0.0)` when the agent is present but has zero tokens and
    /// other agents have non-zero tokens.
    pub fn agent_share_of_attributed(&self, agent: &str, window: AgentWindow) -> Option<f32> {
        if self.agents.is_empty() {
            return None;
        }
        let spend = self.agents.get(agent)?;
        let window_tokens = |s: &AgentSpend| match window {
            AgentWindow::FiveHour => (s.tokens_in_5h + s.tokens_out_5h) as f64,
            AgentWindow::SevenDay => (s.tokens_in_7d + s.tokens_out_7d) as f64,
        };
        let agent_tokens = window_tokens(spend);
        let total: f64 = self.agents.values().map(window_tokens).sum();
        if total == 0.0 {
            return None;
        }
        Some((agent_tokens / total) as f32)
    }
}

/// Parse the `agents` object from a posture JSON value.
///
/// Returns an empty `BTreeMap` when the key is absent, not an object, or
/// contains malformed entries (defensive; never panics).
fn parse_agents_map(v: &serde_json::Value) -> BTreeMap<String, AgentSpend> {
    let mut map = BTreeMap::new();
    let Some(obj) = v.get("agents").and_then(|a| a.as_object()) else {
        return map;
    };
    for (name, entry) in obj {
        if let Some(spend) = parse_agent_spend(entry) {
            map.insert(name.clone(), spend);
        }
    }
    map
}

/// Parse a single `AgentSpend` entry from JSON.  Returns `None` if any of
/// the four required token fields is absent or not a valid u64.
fn parse_agent_spend(v: &serde_json::Value) -> Option<AgentSpend> {
    let tokens_in_5h = v.get("tokens_in_5h")?.as_u64()?;
    let tokens_out_5h = v.get("tokens_out_5h")?.as_u64()?;
    let tokens_in_7d = v.get("tokens_in_7d")?.as_u64()?;
    let tokens_out_7d = v.get("tokens_out_7d")?.as_u64()?;
    Some(AgentSpend {
        tokens_in_5h,
        tokens_out_5h,
        tokens_in_7d,
        tokens_out_7d,
    })
}

/// Build a `WindowPace` for the Sonnet model's 7-day window.
///
/// `models.sonnet` only carries `used_pct`, `resets_at`, and `status`; we
/// inherit `elapsed_pct` from the shared 7-day window so the bar length means
/// the same thing as the other rails. `pace = used_pct / elapsed_pct`.
///
/// Special case: when `status == "exhausted"` the window is fully consumed,
/// so we force `pace = 1.5` (red tip) while keeping `elapsed_pct` from the
/// rather than inheriting a partial elapsed percentage from the 7-day window
/// that would render the bar short and orange.
fn parse_sonnet_window(v: &serde_json::Value) -> Option<WindowPace> {
    let s = v.get("models")?.get("sonnet")?;
    if !s.is_object() {
        return None;
    }
    let used_pct = s.get("used_pct")?.as_f64()? as f32;
    let resets_at = s.get("resets_at")?.as_i64()?;
    let status = s.get("status").and_then(|v| v.as_str()).unwrap_or("normal");
    // Sonnet shares the 7-day window, so elapsed_pct (bar fill = time position)
    // is always inherited from that window — even when exhausted. This keeps
    // the Sonnet bar aligned with the 7d bar at "right now" on the timeline.
    let seven_day_elapsed = parse_window_pace(v, "seven_day")
        .map(|sd| sd.elapsed_pct)
        .unwrap_or(0.0);
    let pace = if status == "exhausted" {
        // Force pace to 1.5 so pace_color() renders the tip red (#D50000),
        // regardless of the arithmetic (which would give 1.0 or ∞).
        1.5_f32
    } else if seven_day_elapsed > 0.0 {
        used_pct / seven_day_elapsed
    } else {
        0.0
    };
    Some(WindowPace {
        used_pct,
        elapsed_pct: seven_day_elapsed,
        pace,
        resets_at,
        level: status.to_string(),
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
    fn parse_sonnet_window_exhausted_is_aligned_and_red() {
        // When status == "exhausted":
        // - elapsed_pct must equal the 7-day elapsed (bar position = "right now",
        //   aligned with the 7d bar, NOT forced to 100%)
        // - pace must be >= 1.5 (tip renders red in pace_color)
        let json = r#"{
            "posture": "normal",
            "seven_day": {
                "used_pct": 80.0,
                "elapsed_pct": 79.5,
                "pace": 1.006,
                "resets_at": 1715800000,
                "level": "normal"
            },
            "models": {
                "sonnet": {
                    "used_pct": 100.0,
                    "resets_at": 1715800000,
                    "status": "exhausted"
                }
            }
        }"#;
        let snap = PostureSnapshot::parse_json(json).expect("should parse");
        let sonnet = snap
            .sonnet_seven_day
            .expect("sonnet window should be present");
        assert!(
            (sonnet.elapsed_pct - 79.5).abs() < 0.01,
            "exhausted should inherit 7d elapsed_pct (79.5) not force 100.0, got {}",
            sonnet.elapsed_pct
        );
        assert!(
            sonnet.pace >= 1.5,
            "exhausted should force pace >= 1.5 (red), got {}",
            sonnet.pace
        );
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

    // ── Wedge A: AgentSpend + agent_share_of_attributed ──────────────────────

    const AGENTS_JSON: &str = r#"{
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
        "agents": {
            "cody": {
                "tokens_in_5h": 0,
                "tokens_out_5h": 0,
                "tokens_in_7d": 32892551,
                "tokens_out_7d": 9168
            },
            "perri": {
                "tokens_in_5h": 100,
                "tokens_out_5h": 50,
                "tokens_in_7d": 5000000,
                "tokens_out_7d": 2000
            }
        }
    }"#;

    #[test]
    fn agents_map_populated_from_json() {
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        assert_eq!(snap.agents.len(), 2, "should parse exactly two agents");
        let cody = snap.agents.get("cody").expect("cody should be present");
        assert_eq!(cody.tokens_in_7d, 32892551);
        assert_eq!(cody.tokens_out_7d, 9168);
        let perri = snap.agents.get("perri").expect("perri should be present");
        assert_eq!(perri.tokens_in_5h, 100);
        assert_eq!(perri.tokens_out_5h, 50);
        assert_eq!(perri.tokens_in_7d, 5000000);
        assert_eq!(perri.tokens_out_7d, 2000);
    }

    #[test]
    fn agents_token_counts_are_raw_u64_not_percentages() {
        // Counts must be stored as raw token integers, never 0–100 percentages.
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        let cody = snap.agents.get("cody").expect("cody should be present");
        // 32892551 is well above 100 — if it were treated as a percentage it
        // would have been clamped or rejected.
        assert!(
            cody.tokens_in_7d > 100,
            "tokens_in_7d should be raw token count, not a percentage; got {}",
            cody.tokens_in_7d
        );
    }

    #[test]
    fn agents_absent_from_json_gives_empty_map() {
        // JSON without an "agents" key must not panic and must yield an empty map.
        let json = r#"{"posture":"normal"}"#;
        let snap = PostureSnapshot::parse_json(json).expect("should parse");
        assert!(snap.agents.is_empty(), "absent agents key → empty map");
    }

    #[test]
    fn agents_empty_object_gives_empty_map() {
        let json = r#"{"posture":"normal","agents":{}}"#;
        let snap = PostureSnapshot::parse_json(json).expect("should parse");
        assert!(snap.agents.is_empty(), "empty agents object → empty map");
    }

    #[test]
    fn agent_share_7d_is_fraction_of_attributed() {
        // cody 7d total  = 32892551 + 9168   = 32901719
        // perri 7d total = 5000000  + 2000   = 5002000
        // all agents sum = 37903719
        // cody share     = 32901719 / 37903719 ≈ 0.8680
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        let share = snap
            .agent_share_of_attributed("cody", AgentWindow::SevenDay)
            .expect("cody 7d share should be Some");
        let cody_7d = (32892551u64 + 9168) as f64;
        let total_7d = cody_7d + (5000000u64 + 2000) as f64;
        let expected = (cody_7d / total_7d) as f32;
        assert!(
            (share - expected).abs() < 0.001,
            "cody 7d share should be ~{expected}, got {share}"
        );
    }

    #[test]
    fn agent_share_5h_is_fraction_of_attributed() {
        // cody 5h total  = 0   + 0   = 0
        // perri 5h total = 100 + 50  = 150
        // all agents sum = 150
        // cody share     = 0 / 150   = 0.0
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        let share = snap
            .agent_share_of_attributed("cody", AgentWindow::FiveHour)
            .expect("cody 5h share should be Some even when 0");
        assert!(
            share.abs() < 0.001,
            "cody 5h share should be 0.0, got {share}"
        );
    }

    #[test]
    fn agent_share_on_empty_map_returns_none() {
        let json = r#"{"posture":"normal"}"#;
        let snap = PostureSnapshot::parse_json(json).expect("should parse");
        assert!(
            snap.agent_share_of_attributed("cody", AgentWindow::SevenDay)
                .is_none(),
            "empty agents map must return None"
        );
    }

    #[test]
    fn agent_share_for_unknown_agent_returns_none() {
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        assert!(
            snap.agent_share_of_attributed("marty", AgentWindow::SevenDay)
                .is_none(),
            "unknown agent must return None"
        );
    }

    #[test]
    fn agent_share_is_not_share_of_window_quota() {
        // agent_share_of_attributed is the share of tokens among *known agents*,
        // not the agent's tokens as a fraction of the window budget.
        // Cody's 7d share must be < 1.0 (other agents also have tokens).
        let snap = PostureSnapshot::parse_json(AGENTS_JSON).expect("should parse");
        let share = snap
            .agent_share_of_attributed("cody", AgentWindow::SevenDay)
            .expect("should be Some");
        assert!(
            share < 1.0,
            "share must be < 1.0 when other agents are present, got {share}"
        );
        assert!(
            share > 0.0,
            "cody has nonzero 7d tokens, share must be > 0.0, got {share}"
        );
    }

    // ── Wedge B: PostureThresholdEvent parse + severity ───────────────────────

    #[test]
    fn parse_threshold_crossed_no_optional_fields() {
        let line = r#"{"ts":"2026-05-31T21:52:12Z","type":"threshold_crossed","window":"account","trigger":"overage_started"}"#;
        let ev = PostureThresholdEvent::parse_line(line).expect("should parse");
        assert_eq!(ev.ts, "2026-05-31T21:52:12Z");
        assert_eq!(ev.window, "account");
        assert_eq!(ev.trigger, "overage_started");
        assert!(ev.pace.is_none(), "pace should be None when absent");
        assert!(
            ev.minutes_remaining.is_none(),
            "minutes_remaining should be None when absent"
        );
    }

    #[test]
    fn parse_threshold_crossed_with_pace() {
        let line = r#"{"ts":"2026-06-01T02:22:48Z","type":"threshold_crossed","window":"seven_day","trigger":"pace_warning","pace":1.3}"#;
        let ev = PostureThresholdEvent::parse_line(line).expect("should parse");
        assert_eq!(ev.trigger, "pace_warning");
        let pace = ev.pace.expect("pace should be Some(1.3)");
        assert!((pace - 1.3).abs() < 0.001, "pace should be 1.3, got {pace}");
    }

    #[test]
    fn parse_threshold_crossed_with_minutes_remaining() {
        let line = r#"{"ts":"2026-06-01T02:22:48Z","type":"threshold_crossed","window":"seven_day","trigger":"exhaustion_imminent","minutes_remaining":8.5}"#;
        let ev = PostureThresholdEvent::parse_line(line).expect("should parse");
        let minutes = ev
            .minutes_remaining
            .expect("minutes_remaining should be Some(8.5)");
        assert!(
            (minutes - 8.5).abs() < 0.001,
            "minutes_remaining should be 8.5, got {minutes}"
        );
    }

    #[test]
    fn parse_line_unknown_type_returns_none() {
        // Lines with a "type" other than "threshold_crossed" must be ignored.
        let line = r#"{"ts":"2026-06-01T00:00:00Z","type":"budget_reset","window":"five_hour"}"#;
        assert!(
            PostureThresholdEvent::parse_line(line).is_none(),
            "non-threshold_crossed type must return None"
        );
    }

    #[test]
    fn parse_line_empty_string_returns_none() {
        assert!(
            PostureThresholdEvent::parse_line("").is_none(),
            "empty input must return None"
        );
    }

    #[test]
    fn parse_line_malformed_json_returns_none() {
        assert!(
            PostureThresholdEvent::parse_line("{not valid json}").is_none(),
            "malformed JSON must return None without panicking"
        );
    }

    #[test]
    fn parse_line_partial_json_returns_none() {
        // Truncated line (e.g. write in progress) must not panic.
        assert!(
            PostureThresholdEvent::parse_line(r#"{"ts":"2026-06"#).is_none(),
            "truncated JSON must return None without panicking"
        );
    }

    #[test]
    fn severity_pace_warning_is_warn() {
        assert_eq!(threshold_severity("pace_warning"), ThresholdSeverity::Warn);
    }

    #[test]
    fn severity_pace_critical_is_alert() {
        assert_eq!(
            threshold_severity("pace_critical"),
            ThresholdSeverity::Alert
        );
    }

    #[test]
    fn severity_overage_started_is_alert() {
        assert_eq!(
            threshold_severity("overage_started"),
            ThresholdSeverity::Alert
        );
    }

    #[test]
    fn severity_exhaustion_imminent_is_alert() {
        assert_eq!(
            threshold_severity("exhaustion_imminent"),
            ThresholdSeverity::Alert
        );
    }

    #[test]
    fn severity_pace_recovered_is_info() {
        // Recovery is explicitly non-alarming — must be Info, not Warn or Alert.
        assert_eq!(
            threshold_severity("pace_recovered"),
            ThresholdSeverity::Info
        );
    }

    #[test]
    fn severity_unknown_trigger_defaults_to_warn() {
        // Unknown triggers default to Warn (safe, visible, not alarm-fatigue-inducing).
        assert_eq!(
            threshold_severity("some_future_trigger"),
            ThresholdSeverity::Warn
        );
    }
}
