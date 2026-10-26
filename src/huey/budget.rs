//! Bishop's budget posture → Huey's run mode (D1).
//!
//! - **critical:** posture `critical`, or the 7-day window at 98% or more, or
//!   the family of the model Huey would use is in `exhausted_models`.
//! - **tight:** `Pump the brakes`, `conservative` or `elevated`; or the 7-day
//!   window at 90% or more; or `stale_input`; or a file older than 24 h; or
//!   `billing_mode: "metered"` (while metered Huey never runs in normal mode).
//! - **normal:** everything else, including a missing file (another Nostromo
//!   user may not run Bishop); the footer then says the posture was
//!   unavailable.
//!
//! Reads the posture file only; writes nothing.

use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::data::rate_limits::{BudgetPosture, PostureSnapshot};
use crate::huey::config::HueyConfig;
use crate::huey::context::collectors::{self, PostureFacts};

/// Shown in the digest's mode line and the footer when there is no posture.
pub const POSTURE_UNAVAILABLE: &str = "budget posture unavailable";
/// A posture file older than this is not trusted to say "normal".
pub const STALE_AFTER_HOURS: i64 = 24;
/// 7-day usage at or above this is tight.
pub const TIGHT_USED_PCT: f64 = 90.0;
/// 7-day usage at or above this is critical.
pub const CRITICAL_USED_PCT: f64 = 98.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Normal,
    Tight,
    Critical,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Normal => "normal",
            Mode::Tight => "tight",
            Mode::Critical => "critical",
        }
    }

    /// Normal and tight runs go through the model; critical runs do not.
    pub fn is_curated(self) -> bool {
        self != Mode::Critical
    }
}

/// The mode and what it was decided from, for the digest, `meta.json` and
/// the footer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PostureNote {
    pub mode: Mode,
    /// Bishop's numbers as one line (`Bishop: "Pump the brakes"; 7-day 72%
    /// used, pace 1.9; billing metered`), or `None` when there is no
    /// readable posture file.
    pub posture: Option<String>,
}

impl PostureNote {
    pub fn available(&self) -> bool {
        self.posture.is_some()
    }

    /// The digest's mode line: `tight (Bishop: "Pump the brakes"; …)`.
    pub fn mode_line(&self) -> String {
        let why = self.posture.as_deref().unwrap_or(POSTURE_UNAVAILABLE);
        format!("{} ({why})", self.mode.as_str())
    }
}

/// Read the posture file at `path` and decide the mode. `config` names the
/// models Huey would use (for `exhausted_models`).
pub fn assess(path: &Path, config: &HueyConfig, now: DateTime<Utc>) -> PostureNote {
    let snapshot = PostureSnapshot::load_from(path);
    let facts = collectors::posture(path);
    let (Some(snapshot), Some(facts)) = (snapshot, facts) else {
        return PostureNote {
            mode: Mode::Normal,
            posture: None,
        };
    };
    let written_at = snapshot.written_at.or_else(|| modified_at(path));
    PostureNote {
        mode: mode_for(&snapshot, &facts, written_at, config, now),
        posture: Some(facts.line()),
    }
}

/// D1, given a parsed posture file. `written_at` is when the file was
/// written (its `ts`, else its modification time).
pub fn mode_for(
    snapshot: &PostureSnapshot,
    facts: &PostureFacts,
    written_at: Option<DateTime<Utc>>,
    config: &HueyConfig,
    now: DateTime<Utc>,
) -> Mode {
    let used = facts.seven_day_used_pct.unwrap_or(0.0);
    let stale_file =
        written_at.is_some_and(|at| now - at > Duration::hours(STALE_AFTER_HOURS));
    let metered = snapshot
        .billing_mode
        .as_deref()
        .is_some_and(|m| m.trim().eq_ignore_ascii_case("metered"));
    let tight = matches!(
        snapshot.posture,
        BudgetPosture::PumpTheBrakes | BudgetPosture::Conservative | BudgetPosture::Elevated
    ) || used >= TIGHT_USED_PCT
        || snapshot.stale_input
        || stale_file
        || metered;
    let model = if tight {
        &config.tight_model
    } else {
        &config.model
    };
    let critical = snapshot.posture == BudgetPosture::Critical
        || used >= CRITICAL_USED_PCT
        || model_exhausted(&snapshot.exhausted_models, model);
    if critical {
        Mode::Critical
    } else if tight {
        Mode::Tight
    } else {
        Mode::Normal
    }
}

/// Is the family of `model` (`sonnet`, `claude-opus-4-5`, …) in `exhausted`?
fn model_exhausted(exhausted: &[String], model: &str) -> bool {
    let model = model.to_ascii_lowercase();
    exhausted.iter().any(|family| {
        let family = family.trim().to_ascii_lowercase();
        !family.is_empty() && model.contains(&family)
    })
}

fn modified_at(path: &Path) -> Option<DateTime<Utc>> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(DateTime::<Utc>::from(modified))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 25, 11, 0, 0).unwrap()
    }

    fn mode(json: serde_json::Value) -> Mode {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("budget-posture.json");
        std::fs::write(&path, json.to_string()).unwrap();
        assess(&path, &HueyConfig::default(), now()).mode
    }

    fn file(posture: &str) -> serde_json::Value {
        serde_json::json!({"ts": "2026-10-25T10:00:00Z", "posture": posture})
    }

    #[test]
    fn posture_words_map_per_d1() {
        for (word, want) in [
            ("Put the hammer down", Mode::Normal),
            ("Push", Mode::Normal),
            ("Cruise", Mode::Normal),
            ("Ease up", Mode::Normal),
            ("Pump the brakes", Mode::Tight),
            ("flush", Mode::Normal),
            ("normal", Mode::Normal),
            ("elevated", Mode::Tight),
            ("conservative", Mode::Tight),
            ("critical", Mode::Critical),
        ] {
            assert_eq!(mode(file(word)), want, "{word}");
        }
    }

    #[test]
    fn metered_billing_is_never_normal() {
        let mut f = file("Cruise");
        f["billing_mode"] = "metered".into();
        assert_eq!(mode(f), Mode::Tight);
        let mut f = file("critical");
        f["billing_mode"] = "metered".into();
        assert_eq!(mode(f), Mode::Critical);
    }

    #[test]
    fn thresholds_staleness_and_exhaustion() {
        let mut f = file("Cruise");
        f["seven_day"] = serde_json::json!({"used_pct": 89.9});
        assert_eq!(mode(f.clone()), Mode::Normal);
        f["seven_day"]["used_pct"] = 90.0.into();
        assert_eq!(mode(f.clone()), Mode::Tight);
        f["seven_day"]["used_pct"] = 98.0.into();
        assert_eq!(mode(f), Mode::Critical);

        let mut f = file("Cruise");
        f["stale_input"] = true.into();
        assert_eq!(mode(f), Mode::Tight);

        let mut f = file("Cruise");
        f["ts"] = "2026-10-24T10:59:00Z".into();
        assert_eq!(mode(f), Mode::Tight);

        let mut f = file("Cruise");
        f["exhausted_models"] = serde_json::json!(["Sonnet"]);
        assert_eq!(mode(f), Mode::Critical);
        let mut f = file("Cruise");
        f["exhausted_models"] = serde_json::json!(["opus"]);
        assert_eq!(mode(f), Mode::Normal);
    }

    #[test]
    fn a_missing_file_is_normal_and_says_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let note = assess(
            &dir.path().join("nope.json"),
            &HueyConfig::default(),
            now(),
        );
        assert_eq!(note.mode, Mode::Normal);
        assert!(!note.available());
        assert_eq!(note.mode_line(), "normal (budget posture unavailable)");
    }
}
