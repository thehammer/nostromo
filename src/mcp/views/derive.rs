//! Deriving [`ViewState`] from what the daemon already stores (W5 —
//! curated-agent-views, B10).
//!
//! The placement engine needs to know what is live. **Nothing new is persisted
//! to tell it.** W2 gave every pane a persisted `(source, params)` binding, and
//! for the curated sources that pair *is* `(view type, identity)`, so the live
//! view set is reconstructed here from the tree and the bindings the
//! `PaneRegistry` already keeps — which is also why it survives a daemon
//! restart for free.
//!
//! Two things aren't derivable and are handled explicitly:
//!
//! - **LRU focus order** comes in as a caller-supplied list (the daemon holds
//!   it in memory, seeded from left-to-right tab order). A restart therefore
//!   evicts in tab order rather than true recency — a bounded, stated
//!   imprecision, and much cheaper than persisting a third fact about panes.
//! - **Pinning** *is* derivable: the `pr_conversation` and `pr_diff` tabs of the
//!   PR under review are pinned, and nothing else ever is.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::ipc::pane_registry::SourceBinding;
use crate::ipc::protocol::PaneTree;
use crate::mcp::tools::apply_layout::{
    SOURCE_FILE, SOURCE_PR_CONVERSATION, SOURCE_PR_DIFF, SOURCE_PR_QUEUE, SOURCE_TICKET,
};

use super::config::ViewPlacementConfig;
use super::tree;
use super::{LiveView, LiveViewKind, RegionState, ViewIdentity, ViewState, ViewType};

/// The `(view type, identity)` a persisted binding represents, or `None` when
/// the binding isn't a curated view at all.
///
/// `perri.get_current_pr` — `perri-standard`'s diff pane — deliberately maps to
/// `None`: it is a plain-text PR summary, not a view in this vocabulary, and
/// treating it as one would let a curated show reuse and silently repurpose the
/// pane `perri-standard` depends on.
pub fn view_of_binding(
    binding: &SourceBinding,
    current_pr: Option<(&str, u64)>,
) -> Option<LiveViewKind> {
    let params = binding.params.as_ref();
    let (view_type, identity) = match binding.source.as_str() {
        SOURCE_PR_QUEUE => (ViewType::ReviewQueue, ViewIdentity::Singleton),
        SOURCE_PR_CONVERSATION => (ViewType::PrConversation, pr_identity(params, current_pr)?),
        SOURCE_PR_DIFF => (ViewType::PrDiff, pr_identity(params, current_pr)?),
        SOURCE_FILE => (ViewType::File, file_identity(params?)?),
        SOURCE_TICKET => (ViewType::Ticket, ticket_identity(params?)?),
        _ => return None,
    };
    Some(LiveViewKind {
        view_type,
        identity,
    })
}

/// A PR view's identity: its own `params`, falling back to whatever is under
/// review.
///
/// The fallback matters because `apply_layout` binds a schema-declared pane
/// with `params: None` — and both PR sources render the current PR regardless
/// of what their params say, so "the PR under review" is the honest identity
/// for such a pane rather than a reason to treat it as unrecognised.
fn pr_identity(params: Option<&Value>, current_pr: Option<(&str, u64)>) -> Option<ViewIdentity> {
    let from_params = params.and_then(|p| {
        let repo = p.get("repo")?.as_str()?.to_string();
        let number = p.get("number")?.as_u64()?;
        Some(ViewIdentity::Pr { repo, number })
    });
    from_params.or_else(|| {
        current_pr.map(|(repo, number)| ViewIdentity::Pr {
            repo: repo.to_string(),
            number,
        })
    })
}

fn file_identity(params: &Value) -> Option<ViewIdentity> {
    let path = params.get("path")?.as_str().filter(|s| !s.is_empty())?;
    let revision = params
        .get("revision")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());
    Some(ViewIdentity::File {
        path: path.to_string(),
        revision,
    })
}

fn ticket_identity(params: &Value) -> Option<ViewIdentity> {
    let provider = params.get("provider")?.as_str().filter(|s| !s.is_empty())?;
    let key = params.get("key")?.as_str().filter(|s| !s.is_empty())?;
    Some(ViewIdentity::Ticket {
        provider: provider.to_string(),
        key: key.to_string(),
    })
}

/// Reconstruct a focus's [`ViewState`].
///
/// `lru` is the daemon's in-memory focus order for this tag, least-recently
/// focused first; pane ids absent from it are ranked below everything in it, in
/// tab order, which is the seeding rule stated in the module doc.
pub fn view_state(
    cfg: &ViewPlacementConfig,
    tree: &PaneTree,
    bindings: &BTreeMap<String, SourceBinding>,
    current_pr: Option<(&str, u64)>,
    lru: &[String],
) -> ViewState {
    let rank = |pane_id: &str| -> u64 {
        match lru.iter().position(|p| p == pane_id) {
            // +1 so a pane the LRU has never heard of (rank 0) always sorts
            // below every pane it has.
            Some(i) => i as u64 + 1,
            None => 0,
        }
    };
    let live_view = |pane_id: &str, pinned_pr: Option<(&str, u64)>| -> LiveView {
        let view = bindings
            .get(pane_id)
            .and_then(|b| view_of_binding(b, current_pr));
        let pinned = view.as_ref().is_some_and(|v| {
            matches!(v.view_type, ViewType::PrConversation | ViewType::PrDiff)
                && v.identity.pr() == pinned_pr
                && pinned_pr.is_some()
        });
        LiveView {
            pane_id: pane_id.to_string(),
            view,
            pinned,
            lru_rank: rank(pane_id),
        }
    };

    let mut regions = BTreeMap::new();
    for (name, rule) in &cfg.regions {
        if rule.tabbed {
            let Some(PaneTree::Tabs {
                children, active, ..
            }) = tree::tabs_region(tree, name)
            else {
                continue;
            };
            let tabs: Vec<LiveView> = children
                .iter()
                .flat_map(|c| c.pane_ids())
                .map(|id| live_view(&id, current_pr))
                .collect();
            if tabs.is_empty() {
                continue;
            }
            let active = (*active).min(tabs.len() - 1);
            regions.insert(
                name.clone(),
                RegionState {
                    tabs,
                    active: Some(active),
                },
            );
        } else {
            let Some(pane) = rule.pane.as_deref() else {
                continue;
            };
            if !tree::has_leaf(tree, pane) {
                continue;
            }
            regions.insert(
                name.clone(),
                RegionState {
                    tabs: vec![live_view(pane, current_pr)],
                    active: Some(0),
                },
            );
        }
    }

    ViewState {
        regions,
        taken_pane_ids: tree::taken_pane_ids(tree),
    }
}

/// Fold `pane_id` into `lru` as the most recently focused pane, dropping any
/// entry no longer live.
///
/// The one piece of mutable, non-derived state the engine leans on. Kept as a
/// free function over a plain `Vec` so it is as testable as everything else
/// here.
pub fn touch(lru: &mut Vec<String>, live: &[String], pane_id: &str) {
    lru.retain(|p| live.contains(p) && p != pane_id);
    lru.push(pane_id.to_string());
}

/// Seed `lru` from a region's left-to-right tab order for any pane it hasn't
/// heard of, and drop entries that are no longer live.
///
/// Called before every derive, so a daemon that restarted mid-review evicts in
/// tab order rather than treating every tab as equally unknown.
pub fn seed(lru: &mut Vec<String>, tab_order: &[String]) {
    lru.retain(|p| tab_order.contains(p));
    let missing: Vec<String> = tab_order
        .iter()
        .filter(|p| !lru.contains(p))
        .cloned()
        .collect();
    // Prepended, not appended: a pane we have never seen focused is *less*
    // recent than one we have.
    let mut seeded = missing;
    seeded.append(lru);
    *lru = seeded;
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::pane_registry::SplitPosition;
    use crate::ipc::protocol::SplitDirection;
    use crate::mcp::views::config;
    use serde_json::json;

    fn cfg() -> ViewPlacementConfig {
        config::parse(include_str!("../views.yaml")).unwrap()
    }

    fn binding(source: &str, params: Option<Value>) -> SourceBinding {
        SourceBinding {
            source: source.to_string(),
            params,
        }
    }

    fn leaf(id: &str) -> PaneTree {
        PaneTree::Leaf {
            pane_id: id.to_string(),
        }
    }

    /// `perri-curated`'s tree plus a detail region holding `tabs`.
    fn curated_with_detail(tabs: &[&str], active: usize) -> PaneTree {
        let mut root = PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![leaf("queue"), leaf("repl")],
            ratios: vec![0.6, 0.4],
        };
        if !tabs.is_empty() {
            tree::insert_beside(
                &mut root,
                "queue",
                SplitPosition::Right,
                &[0.5, 0.5],
                tree::build_tabs(
                    "detail",
                    &tabs
                        .iter()
                        .map(|t| (t.to_string(), t.to_string()))
                        .collect::<Vec<_>>(),
                    active,
                ),
            );
        }
        root
    }

    // ── 1. binding → view ─────────────────────────────────────────────────────

    #[test]
    fn the_pr_queue_source_is_the_review_queue_singleton() {
        let v = view_of_binding(&binding(SOURCE_PR_QUEUE, None), None).unwrap();
        assert_eq!(v.view_type, ViewType::ReviewQueue);
        assert_eq!(v.identity, ViewIdentity::Singleton);
    }

    #[test]
    fn a_file_binding_recovers_its_path_and_revision_as_the_identity() {
        let v = view_of_binding(
            &binding(
                SOURCE_FILE,
                Some(json!({"path": "src/a.rs", "revision": "abc"})),
            ),
            None,
        )
        .unwrap();
        assert_eq!(v.view_type, ViewType::File);
        assert_eq!(
            v.identity,
            ViewIdentity::File {
                path: "src/a.rs".into(),
                revision: Some("abc".into())
            }
        );
    }

    #[test]
    fn a_file_binding_with_an_empty_revision_is_the_resolve_it_for_me_identity() {
        let v = view_of_binding(
            &binding(
                SOURCE_FILE,
                Some(json!({"path": "src/a.rs", "revision": ""})),
            ),
            None,
        )
        .unwrap();
        assert_eq!(
            v.identity,
            ViewIdentity::File {
                path: "src/a.rs".into(),
                revision: None
            }
        );
    }

    #[test]
    fn a_ticket_binding_recovers_its_provider_and_key() {
        let v = view_of_binding(
            &binding(
                SOURCE_TICKET,
                Some(json!({"provider": "jira", "key": "CORE-1"})),
            ),
            None,
        )
        .unwrap();
        assert_eq!(
            v.identity,
            ViewIdentity::Ticket {
                provider: "jira".into(),
                key: "CORE-1".into()
            }
        );
    }

    #[test]
    fn a_pr_binding_without_params_falls_back_to_the_pr_under_review() {
        let v = view_of_binding(&binding(SOURCE_PR_DIFF, None), Some(("o/r", 94))).unwrap();
        assert_eq!(
            v.identity,
            ViewIdentity::Pr {
                repo: "o/r".into(),
                number: 94
            }
        );
    }

    #[test]
    fn a_pr_binding_with_no_params_and_no_pr_under_review_is_unrecognised() {
        assert!(view_of_binding(&binding(SOURCE_PR_DIFF, None), None).is_none());
    }

    #[test]
    fn perri_standards_current_pr_pane_is_not_a_curated_view() {
        assert!(
            view_of_binding(&binding("perri.get_current_pr", None), Some(("o/r", 94))).is_none()
        );
    }

    #[test]
    fn a_malformed_binding_is_unrecognised_rather_than_a_wrong_identity() {
        assert!(view_of_binding(&binding(SOURCE_FILE, Some(json!({}))), None).is_none());
        assert!(view_of_binding(&binding(SOURCE_FILE, None), None).is_none());
        assert!(view_of_binding(
            &binding(SOURCE_TICKET, Some(json!({"provider": "jira"}))),
            None
        )
        .is_none());
    }

    // ── 2. state derivation ───────────────────────────────────────────────────

    #[test]
    fn the_queue_region_is_derived_from_a_live_queue_pane_and_its_binding() {
        let tree = curated_with_detail(&[], 0);
        let mut bindings = BTreeMap::new();
        bindings.insert("queue".to_string(), binding(SOURCE_PR_QUEUE, None));
        let state = view_state(&cfg(), &tree, &bindings, None, &[]);
        let queue = state.region("queue").unwrap();
        assert_eq!(queue.tabs.len(), 1);
        assert_eq!(
            queue.tabs[0].view.as_ref().unwrap().view_type,
            ViewType::ReviewQueue
        );
        assert!(state.region("detail").is_none(), "no detail region yet");
    }

    #[test]
    fn the_detail_region_is_derived_from_its_tabs_node_in_left_to_right_order() {
        let tree = curated_with_detail(&["detail.0", "detail.1"], 1);
        let mut bindings = BTreeMap::new();
        bindings.insert(
            "detail.0".to_string(),
            binding(SOURCE_PR_DIFF, Some(json!({"repo": "o/r", "number": 94}))),
        );
        bindings.insert(
            "detail.1".to_string(),
            binding(SOURCE_FILE, Some(json!({"path": "a.rs"}))),
        );
        let state = view_state(&cfg(), &tree, &bindings, Some(("o/r", 94)), &[]);
        let detail = state.region("detail").unwrap();
        assert_eq!(
            detail
                .tabs
                .iter()
                .map(|t| t.pane_id.as_str())
                .collect::<Vec<_>>(),
            vec!["detail.0", "detail.1"]
        );
        assert_eq!(detail.active, Some(1));
    }

    #[test]
    fn a_tab_with_no_binding_is_kept_in_the_region_but_carries_no_view() {
        let tree = curated_with_detail(&["detail.0"], 0);
        let state = view_state(&cfg(), &tree, &BTreeMap::new(), None, &[]);
        let detail = state.region("detail").unwrap();
        assert_eq!(detail.tabs.len(), 1);
        assert!(detail.tabs[0].view.is_none());
    }

    #[test]
    fn the_view_set_is_recovered_from_persisted_bindings_alone_after_a_restart() {
        // Nothing in-memory survives a restart, so the LRU comes back empty —
        // the derived view set must not.
        let tree = curated_with_detail(&["detail.0", "detail.1"], 0);
        let mut bindings = BTreeMap::new();
        bindings.insert(
            "detail.0".to_string(),
            binding(
                SOURCE_TICKET,
                Some(json!({"provider": "jira", "key": "CORE-1"})),
            ),
        );
        bindings.insert(
            "detail.1".to_string(),
            binding(SOURCE_FILE, Some(json!({"path": "src/a.rs"}))),
        );
        let state = view_state(&cfg(), &tree, &bindings, None, &[]);
        let detail = state.region("detail").unwrap();
        assert_eq!(
            detail.tabs[0].view.as_ref().unwrap().identity,
            ViewIdentity::Ticket {
                provider: "jira".into(),
                key: "CORE-1".into()
            }
        );
        assert_eq!(
            detail.tabs[1].view.as_ref().unwrap().identity,
            ViewIdentity::File {
                path: "src/a.rs".into(),
                revision: None
            }
        );
    }

    // ── 3. pinning is derived, never stored ───────────────────────────────────

    #[test]
    fn the_pr_under_reviews_conversation_and_diff_tabs_are_pinned_and_nothing_else_is() {
        let tree = curated_with_detail(&["detail.0", "detail.1", "detail.2", "detail.3"], 0);
        let mut bindings = BTreeMap::new();
        bindings.insert(
            "detail.0".to_string(),
            binding(
                SOURCE_PR_CONVERSATION,
                Some(json!({"repo": "o/r", "number": 94})),
            ),
        );
        bindings.insert(
            "detail.1".to_string(),
            binding(SOURCE_PR_DIFF, Some(json!({"repo": "o/r", "number": 94}))),
        );
        bindings.insert(
            "detail.2".to_string(),
            binding(SOURCE_PR_DIFF, Some(json!({"repo": "o/r", "number": 95}))),
        );
        bindings.insert(
            "detail.3".to_string(),
            binding(SOURCE_FILE, Some(json!({"path": "a.rs"}))),
        );
        let state = view_state(&cfg(), &tree, &bindings, Some(("o/r", 94)), &[]);
        let pinned: Vec<bool> = state
            .region("detail")
            .unwrap()
            .tabs
            .iter()
            .map(|t| t.pinned)
            .collect();
        assert_eq!(pinned, vec![true, true, false, false]);
    }

    #[test]
    fn nothing_is_pinned_when_no_pr_is_under_review() {
        let tree = curated_with_detail(&["detail.0"], 0);
        let mut bindings = BTreeMap::new();
        bindings.insert(
            "detail.0".to_string(),
            binding(SOURCE_PR_DIFF, Some(json!({"repo": "o/r", "number": 94}))),
        );
        let state = view_state(&cfg(), &tree, &bindings, None, &[]);
        assert!(!state.region("detail").unwrap().tabs[0].pinned);
    }

    // ── 4. LRU ────────────────────────────────────────────────────────────────

    #[test]
    fn lru_rank_orders_a_pane_the_focus_order_knows_above_one_it_does_not() {
        let tree = curated_with_detail(&["detail.0", "detail.1"], 0);
        let state = view_state(
            &cfg(),
            &tree,
            &BTreeMap::new(),
            None,
            &["detail.1".to_string()],
        );
        let tabs = &state.region("detail").unwrap().tabs;
        assert_eq!(tabs[0].lru_rank, 0, "unknown to the LRU");
        assert!(tabs[1].lru_rank > tabs[0].lru_rank);
    }

    #[test]
    fn touch_makes_a_pane_the_most_recent_and_drops_panes_that_are_gone() {
        let mut lru = vec!["a".to_string(), "b".to_string(), "gone".to_string()];
        let live = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        touch(&mut lru, &live, "a");
        assert_eq!(lru, vec!["b", "a"]);
        touch(&mut lru, &live, "c");
        assert_eq!(lru, vec!["b", "a", "c"]);
    }

    #[test]
    fn seed_puts_never_focused_panes_below_everything_the_order_already_knows() {
        let mut lru = vec!["detail.2".to_string()];
        seed(
            &mut lru,
            &[
                "detail.0".to_string(),
                "detail.1".to_string(),
                "detail.2".to_string(),
            ],
        );
        assert_eq!(lru, vec!["detail.0", "detail.1", "detail.2"]);
    }

    #[test]
    fn seed_on_a_cold_start_reproduces_left_to_right_tab_order() {
        let mut lru = Vec::new();
        let order = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        seed(&mut lru, &order);
        assert_eq!(lru, order);
    }

    #[test]
    fn seed_drops_panes_that_are_no_longer_live() {
        let mut lru = vec!["gone".to_string(), "a".to_string()];
        seed(&mut lru, &["a".to_string()]);
        assert_eq!(lru, vec!["a"]);
    }
}
