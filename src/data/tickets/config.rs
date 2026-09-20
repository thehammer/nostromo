//! Ticket section-heading alias table (D4 of the W4 plan) — "rules as data,
//! not code": a team's heading conventions (`## AC`, `## Definition of Done`,
//! …) live in YAML, not in a match arm, so adding one is a config edit rather
//! than a rebuild.
//!
//! Mirrors `crate::mcp::layout_schema`'s override-precedence shape
//! (`layout_schema.rs:219-251`): an on-disk override at
//! `~/.nostromo/tickets.yaml` if present, else the compiled-in default. Read
//! fresh on every call — no caching, no daemon rebuild needed to edit it.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

/// A canonical section name mapped to every raw heading-text variant that
/// should resolve to it (e.g. `"acceptance_criteria"` from `"AC"`,
/// `"Acceptance criterion"`, `"Definition of Done"`).
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
pub struct AliasTable {
    #[serde(default)]
    aliases: HashMap<String, Vec<String>>,
}

impl AliasTable {
    /// Resolve an already-normalized heading name (see
    /// `super::canonical_section_name`) against the alias table. Returns the
    /// canonical name if `normalized` matches one of its variants
    /// (variants are normalized the same way before comparison, so the YAML
    /// can be written in natural casing); otherwise returns `normalized`
    /// unchanged.
    pub fn resolve(&self, normalized: &str) -> String {
        for (canonical, variants) in &self.aliases {
            if super::normalize_name(canonical) == normalized {
                return canonical.clone();
            }
            if variants
                .iter()
                .any(|v| super::normalize_name(v) == normalized)
            {
                return canonical.clone();
            }
        }
        normalized.to_string()
    }
}

/// `~/.nostromo`, the on-disk override directory for ticket configuration —
/// mirrors `layout_schema::layouts_dir`.
pub fn tickets_config_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
}

/// Resolve the alias table: an on-disk override at `<dir>/tickets.yaml` if
/// present, else the compiled-in default. `pub(crate)` test seam — see
/// [`load`] for the real entry point.
pub fn load_from_dir(dir: &Path) -> AliasTable {
    let override_path = dir.join("tickets.yaml");
    if let Ok(text) = std::fs::read_to_string(&override_path) {
        if let Ok(table) = serde_yaml::from_str(&text) {
            return table;
        }
    }
    compiled_in()
}

/// Resolve the alias table against the real `~/.nostromo` override
/// directory.
pub fn load() -> AliasTable {
    load_from_dir(&tickets_config_dir())
}

fn compiled_in() -> AliasTable {
    serde_yaml::from_str(include_str!("../../mcp/tickets.yaml"))
        .expect("compiled-in tickets.yaml must parse")
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. compiled-in default resolves the documented D4 alias set ─────────

    #[test]
    fn compiled_in_default_resolves_every_documented_variant_to_acceptance_criteria() {
        let table = compiled_in();
        for variant in
            ["Acceptance Criteria", "Acceptance criterion", "AC", "Definition of Done"]
        {
            let normalized = super::super::canonical_section_name(variant, &table);
            assert_eq!(
                normalized, "acceptance_criteria",
                "variant {variant:?} must resolve to acceptance_criteria in the compiled-in default"
            );
        }
    }

    #[test]
    fn compiled_in_default_leaves_an_unlisted_heading_unchanged_but_normalized() {
        let table = compiled_in();
        assert_eq!(
            super::super::canonical_section_name("Steps to Reproduce", &table),
            "steps_to_reproduce"
        );
    }

    // ── 2. an on-disk override replaces the compiled-in table entirely ──────

    #[test]
    fn on_disk_override_replaces_the_compiled_in_table_entirely() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("tickets.yaml"),
            r#"
aliases:
  risks:
    - "Risks"
    - "Known Risks"
"#,
        )
        .unwrap();

        let table = load_from_dir(dir.path());
        assert_eq!(
            super::super::canonical_section_name("Known Risks", &table),
            "risks",
            "the override's own alias must resolve"
        );
        assert_eq!(
            super::super::canonical_section_name("AC", &table),
            "ac",
            "a name only present in the compiled-in default must no longer resolve once an \
             override file exists — the override replaces it entirely rather than merging"
        );
    }

    #[test]
    fn load_from_dir_falls_back_to_compiled_in_when_no_override_file_exists() {
        let dir = tempfile::tempdir().unwrap();
        // Directory itself doesn't even exist — must not panic, must fall
        // back to the compiled-in default.
        let table = load_from_dir(&dir.path().join("does-not-exist"));
        assert_eq!(
            super::super::canonical_section_name("AC", &table),
            "acceptance_criteria"
        );
    }

    // ── 3. the loader re-reads on every call, no caching ─────────────────────

    #[test]
    fn load_from_dir_re_reads_the_override_file_on_every_call() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tickets.yaml");
        std::fs::write(
            &path,
            r#"
aliases:
  risks:
    - "Risks"
"#,
        )
        .unwrap();

        let first = load_from_dir(dir.path());
        assert_eq!(super::super::canonical_section_name("Risks", &first), "risks");
        assert_eq!(super::super::canonical_section_name("Blockers", &first), "blockers");

        // Rewrite the file with a different alias set after the first load.
        std::fs::write(
            &path,
            r#"
aliases:
  blockers:
    - "Blockers"
"#,
        )
        .unwrap();

        let second = load_from_dir(dir.path());
        assert_eq!(
            super::super::canonical_section_name("Blockers", &second),
            "blockers",
            "the second load_from_dir call must pick up the rewritten file, not a cached result"
        );
        assert_eq!(
            super::super::canonical_section_name("Risks", &second),
            "risks",
            "the rewritten file no longer defines 'risks', so it must no longer resolve"
        );
    }
}
