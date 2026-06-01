//! Per-view pane-split ratios, persisted to `~/.nostromo/pane_ratios.toml`.
//!
//! On any load failure (missing file, parse error, schema mismatch) we return
//! hardcoded defaults so the existing split behaviour is preserved transparently.

use std::path::PathBuf;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tracing::warn;

// ── storage path ──────────────────────────────────────────────────────────────

fn ratios_path() -> PathBuf {
    // Test/override hook: point the ratios file at an explicit path. Snapshot
    // tests set this to a nonexistent temp path so `load()` falls back to
    // hardcoded defaults instead of leaking the dev machine's dragged ratios
    // (a non-hermetic-snapshot footgun — see tests/snapshot_perri.rs).
    if let Ok(p) = std::env::var("NOSTROMO_PANE_RATIOS_PATH") {
        return PathBuf::from(p);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("pane_ratios.toml")
}

// ── wire format ───────────────────────────────────────────────────────────────

/// Wire format version — bump when the schema changes in a breaking way.
const CURRENT_VERSION: u32 = 1;

#[derive(Debug, Serialize, Deserialize)]
struct RatiosFile {
    version: u32,
    perri: PerriRatios,
    fred: FredRatios,
    mother: MotherRatios,
}

// ── per-view structs ──────────────────────────────────────────────────────────

/// Ratios for the Perri view.
///
/// - `top_row`: fraction of vertical space given to the queue+diff row (vs. REPL).
/// - `queue`: fraction of horizontal space given to the PR queue list (vs. diff).
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PerriRatios {
    pub top_row: f32,
    pub queue: f32,
}

impl Default for PerriRatios {
    fn default() -> Self {
        Self {
            top_row: 0.5,
            queue: 0.4,
        }
    }
}

/// Ratios for the Fred view.
///
/// - `col`: fraction of vertical space given to the top row (mailbox+calendar) vs. REPL.
/// - `row`: fraction of horizontal space given to the mailbox vs. calendar.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FredRatios {
    pub col: f32,
    pub row: f32,
}

impl Default for FredRatios {
    fn default() -> Self {
        Self { col: 0.5, row: 0.5 }
    }
}

/// Ratios for the Mother view.
///
/// - `list`: fraction of horizontal space given to the job list vs. detail pane.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct MotherRatios {
    pub list: f32,
}

impl Default for MotherRatios {
    fn default() -> Self {
        Self { list: 0.4 }
    }
}

/// Top-level container for all per-view ratios.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct PaneRatios {
    pub perri: PerriRatios,
    pub fred: FredRatios,
    pub mother: MotherRatios,
}

// ── public API ────────────────────────────────────────────────────────────────

/// Clamp a ratio to the `[0.1, 0.9]` range so panes never disappear.
pub fn clamp(r: f32) -> f32 {
    r.clamp(0.1, 0.9)
}

/// Load pane ratios from `~/.nostromo/pane_ratios.toml`.
///
/// Returns clamped defaults on any error (missing file, parse error, future version).
pub fn load() -> PaneRatios {
    match load_inner() {
        Ok(r) => r,
        Err(e) => {
            let path = ratios_path();
            if path.exists() {
                warn!("pane_ratios: load failed: {e:#}; using defaults");
            }
            PaneRatios::default()
        }
    }
}

fn load_inner() -> Result<PaneRatios> {
    let path = ratios_path();
    let raw = std::fs::read_to_string(&path)?;
    let file: RatiosFile = toml::from_str(&raw)?;
    if file.version != CURRENT_VERSION {
        anyhow::bail!("unsupported pane_ratios version {}", file.version);
    }
    // Clamp all values on load.
    Ok(PaneRatios {
        perri: PerriRatios {
            top_row: clamp(file.perri.top_row),
            queue: clamp(file.perri.queue),
        },
        fred: FredRatios {
            col: clamp(file.fred.col),
            row: clamp(file.fred.row),
        },
        mother: MotherRatios {
            list: clamp(file.mother.list),
        },
    })
}

/// Save `ratios` to `~/.nostromo/pane_ratios.toml`.
///
/// Silently warns on failure (non-fatal).
pub fn save(ratios: &PaneRatios) {
    if let Err(e) = save_inner(ratios) {
        warn!("pane_ratios: save failed: {e:#}");
    }
}

fn save_inner(ratios: &PaneRatios) -> Result<()> {
    let path = ratios_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = RatiosFile {
        version: CURRENT_VERSION,
        perri: PerriRatios {
            top_row: clamp(ratios.perri.top_row),
            queue: clamp(ratios.perri.queue),
        },
        fred: FredRatios {
            col: clamp(ratios.fred.col),
            row: clamp(ratios.fred.row),
        },
        mother: MotherRatios {
            list: clamp(ratios.mother.list),
        },
    };
    let toml_str = toml::to_string_pretty(&file)?;
    std::fs::write(&path, toml_str)?;
    Ok(())
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_values_match_hardcoded() {
        let r = PaneRatios::default();
        assert_eq!(r.perri.top_row, 0.5);
        assert_eq!(r.perri.queue, 0.4);
        assert_eq!(r.fred.col, 0.5);
        assert_eq!(r.fred.row, 0.5);
        assert_eq!(r.mother.list, 0.4);
    }

    #[test]
    fn clamp_pins_to_range() {
        assert_eq!(clamp(0.0), 0.1);
        assert_eq!(clamp(1.0), 0.9);
        assert_eq!(clamp(0.5), 0.5);
        assert_eq!(clamp(-1.0), 0.1);
        assert_eq!(clamp(2.0), 0.9);
    }

    #[test]
    fn round_trip() {
        use std::fs;
        use tempfile::tempdir;

        // Write a RatiosFile to a temp file, read it back, check values survive.
        let dir = tempdir().unwrap();
        let path = dir.path().join("pane_ratios.toml");

        let original = RatiosFile {
            version: CURRENT_VERSION,
            perri: PerriRatios {
                top_row: 0.6,
                queue: 0.35,
            },
            fred: FredRatios {
                col: 0.45,
                row: 0.55,
            },
            mother: MotherRatios { list: 0.3 },
        };

        let toml_str = toml::to_string_pretty(&original).unwrap();
        fs::write(&path, toml_str).unwrap();

        let raw = fs::read_to_string(&path).unwrap();
        let loaded: RatiosFile = toml::from_str(&raw).unwrap();

        assert_eq!(loaded.version, CURRENT_VERSION);
        assert!((loaded.perri.top_row - 0.6).abs() < 1e-5);
        assert!((loaded.perri.queue - 0.35).abs() < 1e-5);
        assert!((loaded.fred.col - 0.45).abs() < 1e-5);
        assert!((loaded.fred.row - 0.55).abs() < 1e-5);
        assert!((loaded.mother.list - 0.3).abs() < 1e-5);
    }
}
