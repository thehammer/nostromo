//! The placement rules, as data (W5 — curated-agent-views, B10/D3).
//!
//! [`ViewPlacementConfig`] is the *entire* input the placement engine has
//! besides the current view state and the request. The PRD requires that
//! "placement rules are expressed as data resolvable from an on-disk override
//! … so changing them requires no rebuild", and names the signal that would
//! justify abandoning deterministic placement altogether: per-view-type
//! special cases accumulating in the rules. Keeping the rules in one small
//! serde type is what makes that signal observable — a rule that can't be said
//! here is a rule that has grown into code.
//!
//! ## Precedence
//!
//! [`load_from_dir`] checks `<dir>/views.yaml` first and falls back to the
//! compiled-in `src/mcp/views.yaml`, re-read on every call with no caching —
//! deliberately the same shape as [`crate::mcp::layout_schema::load_from_dir`],
//! so the two override stories are one story.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use super::PlacementError;

/// The compiled-in default rules. Only reached when no on-disk override
/// shadows them.
const COMPILED_IN: &str = include_str!("../views.yaml");

/// The whole rule set: which regions exist and what each view type's home is.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ViewPlacementConfig {
    /// Region name → its rule. `BTreeMap` rather than `HashMap` so any
    /// iteration over regions is in a stable order — determinism is a product
    /// criterion here, not a preference.
    pub regions: BTreeMap<String, RegionRule>,
    /// View-type name → where it goes.
    pub views: BTreeMap<String, ViewRule>,
}

/// One region's rule.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RegionRule {
    /// Whether this region hosts several views with one frontmost. A
    /// non-tabbed region holds at most one view, which is R1's "the queue
    /// region … never tabbed" expressed as data rather than as a check on the
    /// string `"queue"`.
    #[serde(default)]
    pub tabbed: bool,
    /// The pane id a non-tabbed region occupies. Required for a non-tabbed
    /// region (it *is* one pane); ignored for a tabbed one, whose pane ids are
    /// generated from [`RegionRule::pane_prefix`].
    #[serde(default)]
    pub pane: Option<String>,
    /// New-tab pane ids are `<pane_prefix>.<n>`.
    #[serde(default)]
    pub pane_prefix: Option<String>,
    /// R4's cap. `None` means unbounded.
    #[serde(default)]
    pub tab_cap: Option<usize>,
    /// R4's eviction policy. `None` means never evict (the cap, if any, is
    /// then simply exceeded rather than enforced).
    #[serde(default)]
    pub evict: Option<EvictPolicy>,
    /// Ordered candidates for creating this region when the focus's tree
    /// doesn't have it yet (D5). The first whose `relative_to` names a live
    /// leaf wins; if none do, the region can't be created and the show is
    /// refused rather than landing somewhere arbitrary.
    #[serde(default)]
    pub create: Vec<RegionCreateRule>,
}

/// How a full region picks its victim.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EvictPolicy {
    /// R4: the least-recently-focused tab that is neither frontmost nor
    /// pinned.
    LeastRecentlyFocusedUnpinned,
}

/// One candidate for bringing a region into existence: split `relative_to` and
/// put the region on the side `position` names.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RegionCreateRule {
    /// The pane id to split.
    pub relative_to: String,
    /// One of `split_left` / `split_right` / `split_above` / `split_below` —
    /// the same four `create_pane` already parses.
    pub position: String,
    /// Ratios for the resulting split, in child order. Must have exactly two
    /// entries; anything else is a malformed rule.
    pub ratios: Vec<f32>,
}

/// One view type's home region and tab order.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ViewRule {
    /// R1: the view type's one home region.
    pub region: String,
    /// R3: the type's position among the region's tabs. Lower sorts left.
    pub order: u32,
}

impl ViewPlacementConfig {
    /// The rule for `view_type`, or [`PlacementError::UnknownViewType`].
    ///
    /// Deliberately keyed on the *name* rather than on the [`ViewType`] enum:
    /// an override that omits a type the binary knows about is a
    /// configuration error the caller should see, not a silent fallback to a
    /// compiled-in default the operator thought they had replaced.
    ///
    /// [`ViewType`]: super::ViewType
    pub fn view(&self, view_type: &str) -> Result<&ViewRule, PlacementError> {
        self.views
            .get(view_type)
            .ok_or_else(|| PlacementError::UnknownViewType(view_type.to_string()))
    }

    /// The rule for `region`, or [`PlacementError::UnknownRegion`].
    pub fn region(&self, region: &str) -> Result<&RegionRule, PlacementError> {
        self.regions
            .get(region)
            .ok_or_else(|| PlacementError::UnknownRegion(region.to_string()))
    }
}

/// Parse and validate a `views.yaml` document.
pub fn parse(yaml: &str) -> Result<ViewPlacementConfig, PlacementError> {
    let cfg: ViewPlacementConfig =
        serde_yaml::from_str(yaml).map_err(|e| PlacementError::InvalidConfig(e.to_string()))?;
    validate(&cfg)?;
    Ok(cfg)
}

/// Refuse a rule set the engine could only act on by guessing: a view whose
/// home region isn't declared, a non-tabbed region with no pane id, a tabbed
/// region with no pane prefix, or a creation candidate whose split isn't
/// two-sided.
fn validate(cfg: &ViewPlacementConfig) -> Result<(), PlacementError> {
    for (name, view) in &cfg.views {
        if !cfg.regions.contains_key(&view.region) {
            return Err(PlacementError::InvalidConfig(format!(
                "view `{name}` names region `{}`, which is not declared",
                view.region
            )));
        }
    }
    for (name, region) in &cfg.regions {
        if region.tabbed {
            if region.pane_prefix.is_none() {
                return Err(PlacementError::InvalidConfig(format!(
                    "tabbed region `{name}` needs a `pane_prefix`"
                )));
            }
        } else if region.pane.is_none() {
            return Err(PlacementError::InvalidConfig(format!(
                "untabbed region `{name}` needs a `pane`"
            )));
        }
        for rule in &region.create {
            if rule.ratios.len() != 2 {
                return Err(PlacementError::InvalidConfig(format!(
                    "region `{name}`: a create rule needs exactly two ratios"
                )));
            }
            if crate::ipc::pane_registry::SplitPosition::parse(&rule.position).is_err() {
                return Err(PlacementError::InvalidConfig(format!(
                    "region `{name}`: `{}` is not a split position",
                    rule.position
                )));
            }
        }
    }
    Ok(())
}

/// Resolve the rules: an override at `<dir>/views.yaml` if present and
/// parseable, else the compiled-in default. Read fresh on every call.
///
/// A *present but malformed* override is an error rather than a silent
/// fallback — an operator who has edited the file wants to know their edit is
/// broken, and quietly reverting to the compiled-in rules would look exactly
/// like the edit having no effect.
pub fn load_from_dir(dir: &Path) -> Result<ViewPlacementConfig, PlacementError> {
    let override_path = dir.join("views.yaml");
    if let Ok(text) = std::fs::read_to_string(&override_path) {
        return parse(&text);
    }
    parse(COMPILED_IN)
}

/// Resolve the rules against the real `~/.nostromo` override directory.
pub fn load() -> Result<ViewPlacementConfig, PlacementError> {
    load_from_dir(&nostromo_dir())
}

/// `~/.nostromo`, the override directory `views.yaml` is looked up in.
pub fn nostromo_dir() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. the compiled-in default ────────────────────────────────────────────

    #[test]
    fn the_compiled_in_default_parses_and_declares_both_regions() {
        let cfg = parse(COMPILED_IN).expect("compiled-in views.yaml must parse");
        assert!(!cfg.regions["queue"].tabbed);
        assert!(cfg.regions["detail"].tabbed);
        assert_eq!(cfg.regions["detail"].tab_cap, Some(6));
        assert_eq!(
            cfg.regions["detail"].evict,
            Some(EvictPolicy::LeastRecentlyFocusedUnpinned)
        );
    }

    #[test]
    fn the_compiled_in_default_gives_every_v1_view_type_a_home_and_an_order() {
        let cfg = parse(COMPILED_IN).unwrap();
        assert_eq!(cfg.view("review_queue").unwrap().region, "queue");
        for t in ["pr_conversation", "pr_diff", "ticket", "file"] {
            assert_eq!(cfg.view(t).unwrap().region, "detail", "{t}");
        }
        let mut orders: Vec<u32> = cfg.views.values().map(|v| v.order).collect();
        orders.sort_unstable();
        orders.dedup();
        assert_eq!(orders.len(), cfg.views.len(), "orders must be distinct");
    }

    #[test]
    fn the_compiled_in_default_declares_a_creation_path_for_every_region() {
        let cfg = parse(COMPILED_IN).unwrap();
        for (name, region) in &cfg.regions {
            assert!(
                !region.create.is_empty(),
                "region `{name}` must be creatable"
            );
        }
    }

    // ── 2. lookups ────────────────────────────────────────────────────────────

    #[test]
    fn an_undeclared_view_type_is_an_unknown_view_type_error() {
        let cfg = parse(COMPILED_IN).unwrap();
        assert!(matches!(
            cfg.view("activity"),
            Err(PlacementError::UnknownViewType(t)) if t == "activity"
        ));
    }

    #[test]
    fn an_undeclared_region_is_an_unknown_region_error() {
        let cfg = parse(COMPILED_IN).unwrap();
        assert!(matches!(
            cfg.region("nowhere"),
            Err(PlacementError::UnknownRegion(r)) if r == "nowhere"
        ));
    }

    // ── 3. validation ─────────────────────────────────────────────────────────

    #[test]
    fn a_view_naming_an_undeclared_region_is_refused() {
        let err = parse(
            "regions:\n  detail: { tabbed: true, pane_prefix: detail }\nviews:\n  file: { region: nope, order: 1 }\n",
        )
        .unwrap_err();
        assert_eq!(err.code(), "invalid_views_config");
    }

    #[test]
    fn an_untabbed_region_without_a_pane_id_is_refused() {
        let err = parse("regions:\n  queue: { tabbed: false }\nviews: {}\n").unwrap_err();
        assert_eq!(err.code(), "invalid_views_config");
    }

    #[test]
    fn a_tabbed_region_without_a_pane_prefix_is_refused() {
        let err = parse("regions:\n  detail: { tabbed: true }\nviews: {}\n").unwrap_err();
        assert_eq!(err.code(), "invalid_views_config");
    }

    #[test]
    fn a_create_rule_with_an_unrecognised_position_is_refused() {
        let err = parse(
            "regions:\n  detail:\n    tabbed: true\n    pane_prefix: detail\n    create:\n      - { relative_to: repl, position: sideways, ratios: [0.5, 0.5] }\nviews: {}\n",
        )
        .unwrap_err();
        assert_eq!(err.code(), "invalid_views_config");
    }

    #[test]
    fn a_create_rule_without_exactly_two_ratios_is_refused() {
        let err = parse(
            "regions:\n  detail:\n    tabbed: true\n    pane_prefix: detail\n    create:\n      - { relative_to: repl, position: split_above, ratios: [0.5] }\nviews: {}\n",
        )
        .unwrap_err();
        assert_eq!(err.code(), "invalid_views_config");
    }

    #[test]
    fn malformed_yaml_is_refused_rather_than_silently_defaulted() {
        assert_eq!(
            parse("regions: [not, a, map]\n").unwrap_err().code(),
            "invalid_views_config"
        );
    }

    // ── 4. override precedence ────────────────────────────────────────────────

    #[test]
    fn an_absent_override_directory_resolves_to_the_compiled_in_default() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            load_from_dir(dir.path()).unwrap(),
            parse(COMPILED_IN).unwrap()
        );
    }

    #[test]
    fn an_on_disk_override_wins_over_the_compiled_in_default() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("views.yaml"),
            "regions:\n  detail: { tabbed: true, pane_prefix: d, tab_cap: 2 }\nviews:\n  file: { region: detail, order: 0 }\n",
        )
        .unwrap();
        let cfg = load_from_dir(dir.path()).unwrap();
        assert_eq!(cfg.regions["detail"].tab_cap, Some(2));
        assert!(!cfg.views.contains_key("review_queue"));
    }

    #[test]
    fn an_edited_override_takes_effect_on_the_next_call_with_no_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("views.yaml");
        let write = |cap: usize| {
            std::fs::write(
                &path,
                format!("regions:\n  detail: {{ tabbed: true, pane_prefix: d, tab_cap: {cap} }}\nviews:\n  file: {{ region: detail, order: 0 }}\n"),
            )
            .unwrap()
        };
        write(2);
        assert_eq!(
            load_from_dir(dir.path()).unwrap().regions["detail"].tab_cap,
            Some(2)
        );
        write(9);
        assert_eq!(
            load_from_dir(dir.path()).unwrap().regions["detail"].tab_cap,
            Some(9)
        );
    }

    #[test]
    fn a_present_but_malformed_override_is_an_error_not_a_silent_fallback() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("views.yaml"), "regions: 42\n").unwrap();
        assert_eq!(
            load_from_dir(dir.path()).unwrap_err().code(),
            "invalid_views_config"
        );
    }
}
