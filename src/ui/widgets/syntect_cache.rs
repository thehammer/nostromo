//! `SyntectCache` — built once at startup, shared via `Arc` across views.
//!
//! Holds the loaded `SyntaxSet` and the `base16-ocean.dark` theme so we don't
//! pay the initialisation cost on every diff render.

use anyhow::Result;
use syntect::highlighting::{Theme, ThemeSet};
use syntect::parsing::SyntaxSet;

pub struct SyntectCache {
    pub syntaxes: SyntaxSet,
    pub theme: Theme,
}

impl SyntectCache {
    /// Build the cache from syntect's bundled defaults.
    pub fn load() -> Result<Self> {
        let syntaxes = SyntaxSet::load_defaults_newlines();
        let theme_set = ThemeSet::load_defaults();
        let theme = theme_set
            .themes
            .get("base16-ocean.dark")
            .cloned()
            .unwrap_or_else(|| {
                // Graceful fallback: use whatever the first theme is.
                theme_set
                    .themes
                    .values()
                    .next()
                    .cloned()
                    .expect("syntect ships at least one theme")
            });
        Ok(Self { syntaxes, theme })
    }
}
