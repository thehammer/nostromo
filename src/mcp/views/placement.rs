//! The deterministic placement engine (W5 — curated-agent-views, D2/D4).
//!
//! One pure function, [`place`], turns `(rules, current state, request)` into a
//! [`Placement`] — an *intent*, not a mutation. Nothing here touches
//! `McpSharedState`, a socket, the filesystem, the clock, or a random number
//! generator, and nothing here consults a model. That is not incidental
//! tidiness: the PRD's determinism criterion is "the same sequence of shows
//! from the same starting state produces the same tab set, order and frontmost
//! tab every time", and a function with those inputs and no others is the only
//! way to make that a test.
//!
//! ## Where each rule is enforced
//!
//! - **R1 (home region)** — `views.yaml`, resolved here. A view whose home
//!   region isn't in the tree causes the engine to describe how to create it
//!   ([`Placement::create_region`]); a non-tabbed region that already holds a
//!   different view refuses the show.
//! - **R2 (identity reuse)** — [`place`]: a live tab whose `(type, identity)`
//!   matches is reused, re-anchored and brought to front. Never a duplicate.
//! - **R3 (new identity, new tab)** — [`place`]: inserted at the position the
//!   configured `order` dictates, then by identity key, so tab position is a
//!   function of content and not of arrival order.
//! - **R4 (cap and eviction)** — [`place`]: at `tab_cap`, the
//!   least-recently-focused tab that is neither frontmost nor pinned is
//!   evicted and reported.
//! - **R5 (focus asymmetry)** — [`place`] always makes the target frontmost,
//!   new or reused. This is a settled PRD decision recorded in its "Decisions
//!   taken" section as a deliberate first cut. There is deliberately no knob.
//! - **R6 (no pointless motion)** — **not enforced here, and cannot be.** The
//!   daemon does not know the client's viewport, so it always sends the
//!   anchor and the client's `ScrollDecision` (W2) decides whether that means
//!   scrolling. This is the one rule that lives on the other side of the wire.
//! - **R7 (modals are not a content channel)** — enforced by omission:
//!   [`super::ViewType`] has no modal variant and `nostromo.show` has no
//!   free-text content field, so an agent cannot route a decision through it.
//!   W6 owns the decision surface.
//! - **R8 (PR change resets)** — [`place`] when the request carries a PR
//!   identity differing from the live ones, and [`reset_for_pr_change`] when
//!   `perri.load_pr` / `perri.clear_current_pr` move the PR under review.

use std::collections::BTreeSet;

use super::config::{EvictPolicy, RegionCreateRule, RegionRule, ViewPlacementConfig};
use super::{label_for, LiveView, PlacementError, ShowRequest, ViewState};

/// How a region that doesn't exist yet gets brought into being (D5): split
/// `relative_to` and put the region on the side `position` names.
///
/// Carried on the [`Placement`] rather than performed here, for the same
/// reason everything else is: the engine describes, the applier mutates.
#[derive(Debug, Clone, PartialEq)]
pub struct RegionCreation {
    /// The pane id to split.
    pub relative_to: String,
    /// One of `split_left` / `split_right` / `split_above` / `split_below`.
    pub position: String,
    /// Ratios for the resulting split, in child order.
    pub ratios: Vec<f32>,
}

/// Where a show lands, and everything that has to change for it to land there.
///
/// Deliberately describes the region's *whole* resulting state rather than a
/// diff: `tab_order` plus `labels` plus `active` is exactly what a
/// `PaneTree::Tabs` node needs, so the applier is a transcription rather than
/// a second implementation of the rules — and a determinism test can assert
/// the entire outcome in one comparison.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    /// The region the view landed in.
    pub region: String,
    /// The pane the view landed on — reused or newly named.
    pub pane_id: String,
    /// R2: true when an existing tab was re-anchored rather than a new one
    /// opened.
    pub reused: bool,
    /// R4: the pane id evicted to make room, if any.
    pub evicted: Option<String>,
    /// D5: how to create the region first, when it doesn't exist yet.
    pub create_region: Option<RegionCreation>,
    /// The region's resulting left-to-right tab order.
    pub tab_order: Vec<String>,
    /// Display labels, parallel to `tab_order`.
    pub labels: Vec<String>,
    /// Index of [`Placement::pane_id`] within `tab_order`. R5 makes this the
    /// frontmost tab unconditionally.
    pub tab_index: usize,
    /// R8: pane ids closed because the review context moved to another PR.
    /// Disjoint from [`Placement::evicted`], which is R4's cap pressure.
    pub reset_closed: Vec<String>,
    /// Whether the region is tabbed. A non-tabbed region is rendered as a
    /// plain leaf, not a one-tab tabs node.
    pub tabbed: bool,
}

impl Placement {
    /// Every pane the applier must unbind and drop from the tree — R4's
    /// victim and R8's reset, together, since both are "this pane is going
    /// away".
    pub fn closed_panes(&self) -> Vec<String> {
        let mut out = self.reset_closed.clone();
        out.extend(self.evicted.clone());
        out
    }
}

// ── the engine ───────────────────────────────────────────────────────────────

/// Decide where `req` lands.
///
/// Pure: `cfg` and `state` in, a decision out. See the module doc for which
/// rule is enforced where.
pub fn place(
    cfg: &ViewPlacementConfig,
    state: &ViewState,
    req: &ShowRequest,
) -> Result<Placement, PlacementError> {
    let view_rule = cfg.view(req.view_type.as_str())?;
    let region_name = view_rule.region.clone();
    let region_rule = cfg.region(&region_name)?;

    let existing = state.region(&region_name);
    let create_region = match existing {
        Some(_) => None,
        None => Some(creation_for(region_rule, state, &region_name)?),
    };

    if !region_rule.tabbed {
        return place_untabbed(state, req, region_name, region_rule, create_region);
    }

    // ── R8 — a show naming a different PR resets the review context ─────────
    //
    // The detail region exists to hold "what we are looking at about *this*
    // PR". A show that names another one is the moment that changes, so the
    // previous PR's conversation/diff and every `file`/`ticket` tab that
    // belonged to that review close. Keyed on the identity shape, not on a
    // list of view-type names — which is what keeps this a rule rather than a
    // per-view-type special case.
    let mut tabs: Vec<LiveView> = existing.map(|r| r.tabs.clone()).unwrap_or_default();
    let previously_active_pane = existing
        .and_then(|r| r.active.and_then(|i| r.tabs.get(i)))
        .map(|t| t.pane_id.clone());

    let mut reset_closed = Vec::new();
    if let Some(requested_pr) = req.identity.pr() {
        let displaced = tabs.iter().any(|t| {
            t.view
                .as_ref()
                .and_then(|v| v.identity.pr())
                .is_some_and(|pr| pr != requested_pr)
        });
        if displaced {
            let (kept, closed): (Vec<LiveView>, Vec<LiveView>) = tabs
                .into_iter()
                .partition(|t| match t.view.as_ref().map(|v| &v.identity) {
                    Some(id) => id.pr() == Some(requested_pr),
                    // A tab the curated layer doesn't recognise is not part of
                    // any review context, so a PR change leaves it alone.
                    None => true,
                });
            reset_closed = closed.into_iter().map(|t| t.pane_id).collect();
            tabs = kept;
        }
    }

    // ── R2 — identity reuse ─────────────────────────────────────────────────
    let matched = tabs.iter().position(|t| {
        t.view
            .as_ref()
            .is_some_and(|v| v.view_type == req.view_type && v.identity == req.identity)
    });

    let label = label_for(req.view_type, &req.identity);

    let mut evicted = None;
    let pane_id;

    if let Some(matched_index) = matched {
        pane_id = tabs[matched_index].pane_id.clone();
    } else {
        pane_id = new_pane_id(region_rule, state, &region_name)?;
        // ── R4 — cap and eviction ───────────────────────────────────────────
        //
        // Evaluated *before* the insert, against the tabs that were already
        // there, so "the frontmost tab" means the one the operator was reading
        // rather than the one about to steal focus.
        if let (Some(cap), Some(policy)) = (region_rule.tab_cap, region_rule.evict) {
            if tabs.len() + 1 > cap {
                evicted = pick_victim(&tabs, previously_active_pane.as_deref(), policy);
            }
        }
        // The victim leaves before the new tab's position is decided. Ordering
        // against the pre-eviction list instead would land the new tab one
        // place too far right whenever the evicted tab sat to its left.
        if let Some(victim) = &evicted {
            tabs.retain(|t| &t.pane_id != victim);
        }
    }

    let mut order: Vec<(String, String)> = tabs
        .iter()
        .map(|t| (t.pane_id.clone(), t.label()))
        .collect();
    let final_index = if matched.is_some() {
        order
            .iter()
            .position(|(id, _)| id == &pane_id)
            .expect("a reused tab is still in the order")
    } else {
        // ── R3 — new identity, new tab, at its type's position ──────────────
        let at = insertion_index(cfg, &tabs, req);
        order.insert(at, (pane_id.clone(), label.clone()));
        at
    };
    if matched.is_some() {
        // A reused tab's label follows its identity, not the label it was
        // created with — a file renamed on disk should not keep a stale
        // caption forever.
        order[final_index].1 = label;
    }

    Ok(Placement {
        region: region_name,
        pane_id,
        reused: matched.is_some(),
        evicted,
        create_region,
        tab_order: order.iter().map(|(id, _)| id.clone()).collect(),
        labels: order.into_iter().map(|(_, l)| l).collect(),
        tab_index: final_index,
        reset_closed,
        tabbed: region_rule.tabbed,
    })
}

/// R1 for a region that is not tabbed: it holds exactly one view, forever.
///
/// The queue region is the only one the compiled-in rules put here, and the
/// criterion it has to satisfy is "the queue region never becomes tabbed and
/// never hosts a non-queue view". Both fall out of one rule: a show for a
/// *different view type* than the one already there is refused, and everything
/// else takes the region's single pane over. Nothing here can grow a second
/// tab, because there is nowhere to put one.
fn place_untabbed(
    state: &ViewState,
    req: &ShowRequest,
    region_name: String,
    region_rule: &RegionRule,
    create_region: Option<RegionCreation>,
) -> Result<Placement, PlacementError> {
    let occupant = state.region(&region_name).and_then(|r| r.tabs.first());

    let (pane_id, reused) = match occupant {
        Some(tab) => match tab.view.as_ref() {
            Some(v) if v.view_type != req.view_type => {
                return Err(PlacementError::RegionNotTabbed(region_name))
            }
            // Same type (a re-show, possibly re-anchored), or a pane the
            // curated layer doesn't recognise: either way this pane *is* the
            // region, so the view takes it over rather than opening beside it.
            Some(v) => (tab.pane_id.clone(), v.identity == req.identity),
            None => (tab.pane_id.clone(), false),
        },
        None => (new_pane_id(region_rule, state, &region_name)?, false),
    };

    let label = label_for(req.view_type, &req.identity);
    Ok(Placement {
        region: region_name,
        pane_id: pane_id.clone(),
        reused,
        evicted: None,
        create_region,
        tab_order: vec![pane_id],
        labels: vec![label],
        tab_index: 0,
        reset_closed: Vec::new(),
        tabbed: false,
    })
}

/// R8's other trigger: the PR under review moved, so close every tab whose
/// review context just went stale.
///
/// `new_pr` is `None` when the PR was cleared. Returns the pane ids to close,
/// in tab order. Retargeting the surviving `pr_conversation`/`pr_diff` tabs is
/// the applier's job and needs no decision — those two sources render whatever
/// the daemon currently has under review, so their content follows the change
/// on its own.
pub fn reset_for_pr_change(
    cfg: &ViewPlacementConfig,
    state: &ViewState,
    new_pr: Option<(&str, u64)>,
) -> Vec<String> {
    let mut closed = Vec::new();
    for region_name in cfg.regions.keys() {
        let Some(region) = state.region(region_name) else {
            continue;
        };
        for tab in &region.tabs {
            let Some(view) = &tab.view else {
                // Not a curated view — not part of any review context.
                continue;
            };
            let stale = match view.identity.pr() {
                // A PR tab survives only while it names the PR under review.
                Some(pr) => new_pr != Some(pr),
                // `file` / `ticket` / the queue: the queue is a singleton that
                // belongs to no PR, everything else belonged to the review
                // that just ended.
                None => matches!(
                    view.identity,
                    super::ViewIdentity::File { .. } | super::ViewIdentity::Ticket { .. }
                ),
            };
            if stale {
                closed.push(tab.pane_id.clone());
            }
        }
    }
    closed
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// R3's insertion point: `(order, identity key)` ascending, so a tab's
/// position is decided by what it holds rather than by when it arrived.
fn insertion_index(cfg: &ViewPlacementConfig, tabs: &[LiveView], req: &ShowRequest) -> usize {
    let key_of = |view: Option<&super::LiveViewKind>| -> (u32, String) {
        match view {
            Some(v) => (
                cfg.views
                    .get(v.view_type.as_str())
                    .map(|r| r.order)
                    // A live view whose type the *current* rules no longer
                    // place (an override that dropped it) sorts last rather
                    // than crashing or jumping to the front.
                    .unwrap_or(u32::MAX),
                v.identity.key(),
            ),
            // An unrecognised tab has no content-derived key; sort it last, on
            // its pane id, so it still has a stable position.
            None => (u32::MAX, String::new()),
        }
    };
    let mine = (
        cfg.views
            .get(req.view_type.as_str())
            .map(|r| r.order)
            .unwrap_or(u32::MAX),
        req.identity.key(),
    );
    tabs.iter()
        .position(|t| key_of(t.view.as_ref()) > mine)
        .unwrap_or(tabs.len())
}

/// R4's victim: the least-recently-focused tab that is neither frontmost nor
/// pinned. Ties break on tab position (leftmost first) so the choice is
/// reproducible rather than merely plausible.
///
/// `None` when every tab is pinned or frontmost — a cap must never turn a show
/// into a failure, so the region is simply allowed to run one over.
fn pick_victim(
    tabs: &[LiveView],
    frontmost: Option<&str>,
    policy: EvictPolicy,
) -> Option<String> {
    let EvictPolicy::LeastRecentlyFocusedUnpinned = policy;
    tabs.iter()
        .enumerate()
        .filter(|(_, t)| !t.pinned && Some(t.pane_id.as_str()) != frontmost)
        .min_by_key(|(i, t)| (t.lru_rank, *i))
        .map(|(_, t)| t.pane_id.clone())
}

/// The pane id a new tab gets: `<prefix>.<n>` for the smallest `n` no pane in
/// the focus already holds. A pure function of state, so replaying a show
/// sequence reproduces the same ids.
fn new_pane_id(
    rule: &RegionRule,
    state: &ViewState,
    region_name: &str,
) -> Result<String, PlacementError> {
    if !rule.tabbed {
        let pane = rule
            .pane
            .clone()
            .ok_or_else(|| PlacementError::UnknownRegion(region_name.to_string()))?;
        // The region is empty (we would have reused otherwise), so its one
        // pane id being taken means something outside the region holds it.
        if state.taken_pane_ids.contains(&pane) && state.region(region_name).is_none() {
            return Err(PlacementError::PaneIdTaken(pane));
        }
        return Ok(pane);
    }
    let prefix = rule
        .pane_prefix
        .as_deref()
        .ok_or_else(|| PlacementError::UnknownRegion(region_name.to_string()))?;
    for n in 0.. {
        let candidate = format!("{prefix}.{n}");
        if !state.taken_pane_ids.contains(&candidate) {
            return Ok(candidate);
        }
    }
    unreachable!("0.. is unbounded")
}

/// D5: the first creation candidate whose `relative_to` names a live pane.
fn creation_for(
    rule: &RegionRule,
    state: &ViewState,
    region_name: &str,
) -> Result<RegionCreation, PlacementError> {
    rule.create
        .iter()
        .find(|c| state.taken_pane_ids.contains(&c.relative_to))
        .map(|c: &RegionCreateRule| RegionCreation {
            relative_to: c.relative_to.clone(),
            position: c.position.clone(),
            ratios: c.ratios.clone(),
        })
        .ok_or_else(|| PlacementError::RegionNotCreatable(region_name.to_string()))
}

// ── LiveView convenience ─────────────────────────────────────────────────────

impl LiveView {
    /// This tab's caption, derived from its identity when it has one.
    fn label(&self) -> String {
        match &self.view {
            Some(v) => label_for(v.view_type, &v.identity),
            None => self.pane_id.clone(),
        }
    }
}

/// The set of pane ids a [`ViewState`] considers live. Small helper so tests
/// can build a state without spelling the set out twice.
pub fn taken(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::views::config;
    use crate::mcp::views::{LiveViewKind, RegionState, ViewIdentity, ViewType};
    use std::collections::BTreeMap;

    fn cfg() -> ViewPlacementConfig {
        config::parse(include_str!("../views.yaml")).unwrap()
    }

    fn pr(number: u64) -> ViewIdentity {
        ViewIdentity::Pr {
            repo: "thehammer/nostromo".into(),
            number,
        }
    }

    fn file(path: &str) -> ViewIdentity {
        ViewIdentity::File {
            path: path.into(),
            revision: None,
        }
    }

    fn ticket(key: &str) -> ViewIdentity {
        ViewIdentity::Ticket {
            provider: "jira".into(),
            key: key.into(),
        }
    }

    fn tab(pane_id: &str, view_type: ViewType, identity: ViewIdentity, lru: u64) -> LiveView {
        LiveView {
            pane_id: pane_id.into(),
            view: Some(LiveViewKind {
                view_type,
                identity,
            }),
            pinned: false,
            lru_rank: lru,
        }
    }

    fn pinned(mut t: LiveView) -> LiveView {
        t.pinned = true;
        t
    }

    /// A focus with `perri-curated`'s starting tree: a queue and a repl, no
    /// detail region yet.
    fn curated_start() -> ViewState {
        let mut regions = BTreeMap::new();
        regions.insert(
            "queue".to_string(),
            RegionState {
                tabs: vec![tab("queue", ViewType::ReviewQueue, ViewIdentity::Singleton, 0)],
                active: Some(0),
            },
        );
        ViewState {
            regions,
            taken_pane_ids: taken(&["queue", "repl"]),
        }
    }

    /// `curated_start` plus a detail region holding `tabs`, frontmost `active`.
    fn with_detail(mut state: ViewState, tabs: Vec<LiveView>, active: usize) -> ViewState {
        for t in &tabs {
            state.taken_pane_ids.insert(t.pane_id.clone());
        }
        state.regions.insert(
            "detail".to_string(),
            RegionState {
                tabs,
                active: Some(active),
            },
        );
        state
    }

    fn show(view_type: ViewType, identity: ViewIdentity) -> ShowRequest {
        ShowRequest::new(view_type, identity)
    }

    // ── 1. R1 — home region ───────────────────────────────────────────────────

    #[test]
    fn review_queue_lands_in_the_queue_region_and_the_others_land_in_detail() {
        let state = curated_start();
        assert_eq!(
            place(&cfg(), &state, &show(ViewType::ReviewQueue, ViewIdentity::Singleton))
                .unwrap()
                .region,
            "queue"
        );
        for (t, id) in [
            (ViewType::PrConversation, pr(94)),
            (ViewType::PrDiff, pr(94)),
            (ViewType::Ticket, ticket("CORE-1")),
            (ViewType::File, file("a.rs")),
        ] {
            assert_eq!(place(&cfg(), &state, &show(t, id)).unwrap().region, "detail");
        }
    }

    #[test]
    fn the_queue_region_is_never_tabbed() {
        let p = place(
            &cfg(),
            &curated_start(),
            &show(ViewType::ReviewQueue, ViewIdentity::Singleton),
        )
        .unwrap();
        assert!(!p.tabbed);
        assert_eq!(p.tab_order, vec!["queue"]);
    }

    #[test]
    fn a_non_queue_view_routed_to_the_queue_region_is_refused() {
        // Only reachable through an operator override — which is exactly the
        // case R1 has to hold for, since the compiled-in rules never do it.
        let cfg = config::parse(
            "regions:\n  queue: { tabbed: false, pane: queue }\nviews:\n  review_queue: { region: queue, order: 0 }\n  file: { region: queue, order: 1 }\n",
        )
        .unwrap();
        let err = place(&cfg, &curated_start(), &show(ViewType::File, file("a.rs"))).unwrap_err();
        assert_eq!(err.code(), "region_not_tabbed");
    }

    // ── 2. R2 — identity reuse ────────────────────────────────────────────────

    #[test]
    fn showing_the_same_type_and_identity_twice_produces_one_tab_not_two() {
        let cfg = cfg();
        let first = place(&cfg, &curated_start(), &show(ViewType::File, file("src/a.rs"))).unwrap();
        assert!(!first.reused);

        let state = with_detail(
            curated_start(),
            vec![tab(&first.pane_id, ViewType::File, file("src/a.rs"), 1)],
            0,
        );
        let second = place(&cfg, &state, &show(ViewType::File, file("src/a.rs"))).unwrap();
        assert!(second.reused);
        assert_eq!(second.pane_id, first.pane_id);
        assert_eq!(second.tab_order.len(), 1);
    }

    #[test]
    fn the_same_file_at_a_different_line_reuses_its_tab() {
        // Anchor and emphasis are not part of `ViewIdentity`, so this is true
        // by construction — the test pins the *contract*, which a later change
        // to the identity type could otherwise break silently.
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::File, file("src/a.rs"), 1)],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/a.rs"))).unwrap();
        assert!(p.reused);
        assert_eq!(p.pane_id, "detail.0");
    }

    #[test]
    fn a_different_file_does_not_reuse_another_files_tab() {
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::File, file("src/a.rs"), 1)],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/b.rs"))).unwrap();
        assert!(!p.reused);
        assert_eq!(p.tab_order.len(), 2);
    }

    #[test]
    fn the_conversation_and_the_diff_of_one_pr_are_two_tabs_not_one() {
        let cfg = cfg();
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::PrConversation, pr(94), 1)],
            0,
        );
        let p = place(&cfg, &state, &show(ViewType::PrDiff, pr(94))).unwrap();
        assert!(!p.reused);
        assert_eq!(p.tab_order, vec!["detail.0".to_string(), p.pane_id.clone()]);
    }

    // ── 3. R3 — new tab position is a function of content ─────────────────────

    #[test]
    fn tab_position_follows_type_order_regardless_of_arrival_order() {
        let cfg = cfg();
        // Arrive backwards: file, ticket, diff, conversation.
        let mut state = curated_start();
        let mut expected_types = Vec::new();
        for (t, id) in [
            (ViewType::File, file("a.rs")),
            (ViewType::Ticket, ticket("CORE-1")),
            (ViewType::PrDiff, pr(94)),
            (ViewType::PrConversation, pr(94)),
        ] {
            let p = place(&cfg, &state, &show(t, id.clone())).unwrap();
            let mut tabs = state
                .region("detail")
                .map(|r| r.tabs.clone())
                .unwrap_or_default();
            tabs.insert(p.tab_index, tab(&p.pane_id, t, id, 0));
            expected_types.push(t);
            state = with_detail(curated_start(), tabs, p.tab_index);
        }
        let got: Vec<ViewType> = state
            .region("detail")
            .unwrap()
            .tabs
            .iter()
            .map(|t| t.view.as_ref().unwrap().view_type)
            .collect();
        assert_eq!(
            got,
            vec![
                ViewType::PrConversation,
                ViewType::PrDiff,
                ViewType::Ticket,
                ViewType::File
            ]
        );
    }

    #[test]
    fn two_files_sort_by_identity_so_position_does_not_depend_on_arrival() {
        let cfg = cfg();
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::File, file("src/z.rs"), 1)],
            0,
        );
        let p = place(&cfg, &state, &show(ViewType::File, file("src/a.rs"))).unwrap();
        // `src/a.rs` sorts before `src/z.rs`, so it lands left of it even
        // though it arrived second.
        assert_eq!(p.tab_index, 0);
        assert_eq!(p.tab_order, vec![p.pane_id.clone(), "detail.0".to_string()]);
    }

    #[test]
    fn a_new_tab_pane_id_is_the_smallest_unused_index_for_the_region() {
        let cfg = cfg();
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(94), 1),
                tab("detail.2", ViewType::PrDiff, pr(94), 2),
            ],
            1,
        );
        let p = place(&cfg, &state, &show(ViewType::File, file("a.rs"))).unwrap();
        assert_eq!(p.pane_id, "detail.1");
    }

    // ── 4. R4 — cap and eviction ──────────────────────────────────────────────

    fn six_tabs() -> Vec<LiveView> {
        vec![
            pinned(tab("detail.0", ViewType::PrConversation, pr(94), 10)),
            pinned(tab("detail.1", ViewType::PrDiff, pr(94), 11)),
            tab("detail.2", ViewType::Ticket, ticket("CORE-1"), 3),
            tab("detail.3", ViewType::File, file("src/a.rs"), 1),
            tab("detail.4", ViewType::File, file("src/b.rs"), 2),
            tab("detail.5", ViewType::File, file("src/c.rs"), 12),
        ]
    }

    #[test]
    fn opening_a_seventh_tab_evicts_exactly_one_least_recently_focused_unpinned_tab() {
        let state = with_detail(curated_start(), six_tabs(), 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/d.rs"))).unwrap();
        assert_eq!(p.evicted.as_deref(), Some("detail.3"), "lowest lru_rank");
        assert_eq!(p.tab_order.len(), 6, "still at the cap, exactly one evicted");
        assert!(!p.tab_order.contains(&"detail.3".to_string()));
    }

    #[test]
    fn the_pr_under_reviews_conversation_and_diff_are_never_the_tab_evicted() {
        // Both pinned tabs carry a *lower* lru_rank than one unpinned tab, so
        // a policy that ignored pinning would pick one of them.
        let mut tabs = six_tabs();
        tabs[0].lru_rank = 0;
        tabs[1].lru_rank = 1;
        let state = with_detail(curated_start(), tabs, 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/d.rs"))).unwrap();
        assert_eq!(p.evicted.as_deref(), Some("detail.3"));
        assert!(p.tab_order.contains(&"detail.0".to_string()));
        assert!(p.tab_order.contains(&"detail.1".to_string()));
    }

    #[test]
    fn the_frontmost_tab_is_never_the_tab_evicted() {
        let mut tabs = six_tabs();
        tabs[3].lru_rank = 99; // no longer the least recent
        tabs[5].lru_rank = 0; // frontmost *and* least recent
        let state = with_detail(curated_start(), tabs, 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/d.rs"))).unwrap();
        assert_ne!(p.evicted.as_deref(), Some("detail.5"));
        assert_eq!(p.evicted.as_deref(), Some("detail.4"));
    }

    #[test]
    fn reusing_a_tab_at_the_cap_evicts_nothing() {
        let state = with_detail(curated_start(), six_tabs(), 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/a.rs"))).unwrap();
        assert!(p.reused);
        assert_eq!(p.evicted, None);
        assert_eq!(p.tab_order.len(), 6);
    }

    #[test]
    fn a_region_whose_every_tab_is_pinned_or_frontmost_runs_one_over_rather_than_refusing() {
        let mut tabs = six_tabs();
        for t in tabs.iter_mut() {
            t.pinned = true;
        }
        let state = with_detail(curated_start(), tabs, 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/d.rs"))).unwrap();
        assert_eq!(p.evicted, None);
        assert_eq!(p.tab_order.len(), 7, "a cap must not turn a show into a failure");
    }

    #[test]
    fn a_new_tab_lands_at_its_own_position_even_when_the_evicted_tab_was_left_of_it() {
        // The victim leaves before the new tab's position is decided. Ordering
        // against the pre-eviction list would put `m.rs` *after* `z.rs` here,
        // which would make tab position depend on which tab happened to be
        // evicted — exactly what R3 says it must not depend on.
        let cfg = config::parse(
            "regions:\n  detail: { tabbed: true, pane_prefix: detail, tab_cap: 2, evict: least_recently_focused_unpinned }\nviews:\n  file: { region: detail, order: 0 }\n",
        )
        .unwrap();
        let mut state = curated_start();
        state.regions.insert(
            "detail".to_string(),
            RegionState {
                tabs: vec![
                    tab("detail.0", ViewType::File, file("src/a.rs"), 1),
                    tab("detail.1", ViewType::File, file("src/z.rs"), 5),
                ],
                active: Some(1),
            },
        );
        state.taken_pane_ids.insert("detail.0".into());
        state.taken_pane_ids.insert("detail.1".into());

        let p = place(&cfg, &state, &show(ViewType::File, file("src/m.rs"))).unwrap();
        assert_eq!(p.evicted.as_deref(), Some("detail.0"));
        assert_eq!(p.tab_order, vec![p.pane_id.clone(), "detail.1".to_string()]);
        assert_eq!(p.tab_index, 0, "m.rs sorts before z.rs");
        assert_eq!(p.labels, vec!["m.rs", "z.rs"]);
    }

    #[test]
    fn eviction_ties_break_on_tab_position_so_the_victim_is_reproducible() {
        let mut tabs = six_tabs();
        tabs[2].lru_rank = 1;
        tabs[3].lru_rank = 1;
        tabs[4].lru_rank = 1;
        let state = with_detail(curated_start(), tabs, 5);
        let p = place(&cfg(), &state, &show(ViewType::File, file("src/d.rs"))).unwrap();
        assert_eq!(p.evicted.as_deref(), Some("detail.2"), "leftmost of the tie");
    }

    // ── 5. R5 — focus asymmetry ───────────────────────────────────────────────

    #[test]
    fn a_new_tab_comes_to_front() {
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::PrConversation, pr(94), 5)],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::File, file("a.rs"))).unwrap();
        assert_eq!(p.tab_order[p.tab_index], p.pane_id);
    }

    #[test]
    fn a_reused_tab_comes_to_front_even_when_another_tab_was_frontmost() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(94), 5),
                tab("detail.1", ViewType::File, file("a.rs"), 1),
            ],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::File, file("a.rs"))).unwrap();
        assert!(p.reused);
        assert_eq!(p.tab_index, 1);
        assert_eq!(p.tab_order[p.tab_index], "detail.1");
    }

    // ── 6. R8 — PR change resets ──────────────────────────────────────────────

    #[test]
    fn showing_another_prs_diff_closes_the_previous_prs_tabs_and_its_file_and_ticket_tabs() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(94), 4),
                tab("detail.1", ViewType::PrDiff, pr(94), 5),
                tab("detail.2", ViewType::Ticket, ticket("CORE-1"), 2),
                tab("detail.3", ViewType::File, file("a.rs"), 3),
            ],
            1,
        );
        let p = place(&cfg(), &state, &show(ViewType::PrDiff, pr(95))).unwrap();
        let mut closed = p.reset_closed.clone();
        closed.sort();
        assert_eq!(closed, vec!["detail.0", "detail.1", "detail.2", "detail.3"]);
        assert_eq!(p.tab_order, vec![p.pane_id.clone()]);
    }

    #[test]
    fn showing_the_same_prs_other_view_resets_nothing() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.1", ViewType::PrDiff, pr(94), 5),
                tab("detail.3", ViewType::File, file("a.rs"), 3),
            ],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::PrConversation, pr(94))).unwrap();
        assert!(p.reset_closed.is_empty());
        assert_eq!(p.tab_order.len(), 3);
    }

    #[test]
    fn a_file_or_ticket_show_never_resets_the_review_context() {
        let state = with_detail(
            curated_start(),
            vec![tab("detail.1", ViewType::PrDiff, pr(94), 5)],
            0,
        );
        for (t, id) in [
            (ViewType::File, file("a.rs")),
            (ViewType::Ticket, ticket("CORE-1")),
        ] {
            let p = place(&cfg(), &state, &show(t, id)).unwrap();
            assert!(p.reset_closed.is_empty());
            assert!(p.tab_order.contains(&"detail.1".to_string()));
        }
    }

    #[test]
    fn reset_for_pr_change_closes_file_and_ticket_tabs_and_leaves_the_new_prs_views() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(94), 4),
                tab("detail.1", ViewType::PrDiff, pr(94), 5),
                tab("detail.2", ViewType::Ticket, ticket("CORE-1"), 2),
                tab("detail.3", ViewType::File, file("a.rs"), 3),
            ],
            1,
        );
        // The applier retargets the surviving PR tabs; the engine only says
        // which tabs go. `pr(94)` is what those two tabs are bound to *now*,
        // and the new PR is 95, so both are stale.
        let closed = reset_for_pr_change(&cfg(), &state, Some(("thehammer/nostromo", 95)));
        assert_eq!(
            closed,
            vec!["detail.0", "detail.1", "detail.2", "detail.3"]
        );
    }

    #[test]
    fn reset_for_pr_change_keeps_the_tabs_of_the_pr_that_is_now_under_review() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(95), 4),
                tab("detail.3", ViewType::File, file("a.rs"), 3),
            ],
            0,
        );
        let closed = reset_for_pr_change(&cfg(), &state, Some(("thehammer/nostromo", 95)));
        assert_eq!(closed, vec!["detail.3"]);
    }

    #[test]
    fn clearing_the_pr_under_review_closes_every_review_tab_but_never_the_queue() {
        let state = with_detail(
            curated_start(),
            vec![
                tab("detail.0", ViewType::PrConversation, pr(94), 4),
                tab("detail.3", ViewType::File, file("a.rs"), 3),
            ],
            0,
        );
        let closed = reset_for_pr_change(&cfg(), &state, None);
        assert_eq!(closed, vec!["detail.0", "detail.3"]);
        assert!(!closed.contains(&"queue".to_string()));
    }

    #[test]
    fn a_reset_leaves_a_tab_the_curated_layer_does_not_recognise_alone() {
        let unknown = LiveView {
            pane_id: "detail.9".into(),
            view: None,
            pinned: false,
            lru_rank: 0,
        };
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::PrDiff, pr(94), 4), unknown],
            0,
        );
        assert_eq!(
            reset_for_pr_change(&cfg(), &state, None),
            vec!["detail.0"]
        );
        let p = place(&cfg(), &state, &show(ViewType::PrDiff, pr(95))).unwrap();
        assert_eq!(p.reset_closed, vec!["detail.0"]);
        assert!(p.tab_order.contains(&"detail.9".to_string()));
    }

    // ── 7. D5 — region creation ───────────────────────────────────────────────

    #[test]
    fn the_detail_region_is_created_by_splitting_the_queue_when_it_does_not_exist() {
        let p = place(
            &cfg(),
            &curated_start(),
            &show(ViewType::PrDiff, pr(94)),
        )
        .unwrap();
        assert_eq!(
            p.create_region,
            Some(RegionCreation {
                relative_to: "queue".into(),
                position: "split_right".into(),
                ratios: vec![0.5, 0.5],
            })
        );
    }

    #[test]
    fn an_existing_detail_region_is_not_recreated() {
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::PrDiff, pr(94), 1)],
            0,
        );
        let p = place(&cfg(), &state, &show(ViewType::File, file("a.rs"))).unwrap();
        assert_eq!(p.create_region, None);
    }

    #[test]
    fn a_bare_focus_bootstraps_both_regions_without_the_caller_touching_apply_layout() {
        let bare = ViewState {
            regions: BTreeMap::new(),
            taken_pane_ids: taken(&["repl"]),
        };
        let queue = place(
            &cfg(),
            &bare,
            &show(ViewType::ReviewQueue, ViewIdentity::Singleton),
        )
        .unwrap();
        assert_eq!(queue.pane_id, "queue");
        assert_eq!(
            queue.create_region,
            Some(RegionCreation {
                relative_to: "repl".into(),
                position: "split_above".into(),
                ratios: vec![0.6, 0.4],
            })
        );

        // With no queue pane yet, the detail region falls through to its
        // second creation candidate rather than refusing.
        let detail = place(&cfg(), &bare, &show(ViewType::PrDiff, pr(94))).unwrap();
        assert_eq!(
            detail.create_region.as_ref().map(|c| c.relative_to.as_str()),
            Some("repl")
        );
    }

    #[test]
    fn a_region_with_no_reachable_creation_candidate_is_refused() {
        let cfg = config::parse(
            "regions:\n  detail:\n    tabbed: true\n    pane_prefix: detail\n    create:\n      - { relative_to: nope, position: split_right, ratios: [0.5, 0.5] }\nviews:\n  file: { region: detail, order: 0 }\n",
        )
        .unwrap();
        let bare = ViewState {
            regions: BTreeMap::new(),
            taken_pane_ids: taken(&["repl"]),
        };
        assert_eq!(
            place(&cfg, &bare, &show(ViewType::File, file("a.rs")))
                .unwrap_err()
                .code(),
            "region_not_creatable"
        );
    }

    #[test]
    fn creating_an_untabbed_region_whose_pane_id_is_already_taken_is_refused() {
        let state = ViewState {
            regions: BTreeMap::new(),
            // `perri-standard`'s tree: a `queue` pane that isn't a curated
            // region.
            taken_pane_ids: taken(&["queue", "diff", "repl"]),
        };
        assert_eq!(
            place(
                &cfg(),
                &state,
                &show(ViewType::ReviewQueue, ViewIdentity::Singleton)
            )
            .unwrap_err()
            .code(),
            "pane_id_taken"
        );
    }

    // ── 8. determinism ────────────────────────────────────────────────────────

    /// Replay a whole show sequence against the engine, threading the result
    /// back into the state exactly as the applier would. Returns the final
    /// `(tab order, labels, frontmost pane id)` for the detail region.
    fn replay(sequence: &[(ViewType, ViewIdentity)]) -> (Vec<String>, Vec<String>, String) {
        let cfg = cfg();
        let mut state = curated_start();
        let mut frontmost = String::new();
        let mut lru: u64 = 100;
        for (t, id) in sequence {
            let p = place(&cfg, &state, &show(*t, id.clone())).unwrap();
            lru += 1;

            let mut by_id: BTreeMap<String, LiveView> = state
                .region("detail")
                .map(|r| r.tabs.clone())
                .unwrap_or_default()
                .into_iter()
                .map(|t| (t.pane_id.clone(), t))
                .collect();
            for closed in p.closed_panes() {
                by_id.remove(&closed);
            }
            by_id.insert(
                p.pane_id.clone(),
                LiveView {
                    pane_id: p.pane_id.clone(),
                    view: Some(LiveViewKind {
                        view_type: *t,
                        identity: id.clone(),
                    }),
                    pinned: false,
                    lru_rank: lru,
                },
            );
            let tabs: Vec<LiveView> = p
                .tab_order
                .iter()
                .map(|id| by_id.get(id).cloned().expect("tab order names a live tab"))
                .collect();
            frontmost = p.tab_order[p.tab_index].clone();
            let mut next = curated_start();
            // Only panes still in the order remain taken.
            next = with_detail(next, tabs, p.tab_index);
            state = next;
        }
        let region = state.region("detail").unwrap();
        (
            region.tabs.iter().map(|t| t.pane_id.clone()).collect(),
            region.tabs.iter().map(|t| t.label()).collect(),
            frontmost,
        )
    }

    #[test]
    fn the_same_show_sequence_from_the_same_state_produces_the_same_tabs_order_and_frontmost() {
        let sequences: Vec<Vec<(ViewType, ViewIdentity)>> = vec![
            vec![
                (ViewType::PrDiff, pr(94)),
                (ViewType::File, file("src/ipc/session_manager.rs")),
                (ViewType::File, file("src/ipc/session_manager.rs")),
                (ViewType::Ticket, ticket("CORE-2841")),
            ],
            vec![
                (ViewType::Ticket, ticket("CORE-2841")),
                (ViewType::File, file("src/z.rs")),
                (ViewType::PrConversation, pr(94)),
                (ViewType::File, file("src/a.rs")),
                (ViewType::PrDiff, pr(94)),
            ],
            vec![
                (ViewType::PrDiff, pr(94)),
                (ViewType::File, file("a.rs")),
                (ViewType::File, file("b.rs")),
                (ViewType::File, file("c.rs")),
                (ViewType::File, file("d.rs")),
                (ViewType::File, file("e.rs")),
                (ViewType::File, file("f.rs")),
                (ViewType::PrDiff, pr(95)),
            ],
        ];
        for seq in &sequences {
            let first = replay(seq);
            let second = replay(seq);
            assert_eq!(first, second, "sequence must be reproducible: {seq:?}");
        }
    }

    #[test]
    fn a_known_show_sequence_produces_a_known_tab_set_order_and_frontmost() {
        // The walking scenario, verbatim: pick up the PR, walk the diff, point
        // at a file, point at the same file again, then open the ticket.
        let (order, labels, frontmost) = replay(&[
            (ViewType::PrConversation, pr(94)),
            (ViewType::PrDiff, pr(94)),
            (ViewType::File, file("src/ipc/session_manager.rs")),
            (ViewType::File, file("src/ipc/session_manager.rs")),
            (ViewType::Ticket, ticket("CORE-2841")),
        ]);
        assert_eq!(order, vec!["detail.0", "detail.1", "detail.3", "detail.2"]);
        assert_eq!(
            labels,
            vec!["Conversation", "Diff", "CORE-2841", "session_manager.rs"]
        );
        assert_eq!(frontmost, "detail.3");
    }

    #[test]
    fn arrival_order_does_not_change_the_resulting_tab_order() {
        let forwards = replay(&[
            (ViewType::PrConversation, pr(94)),
            (ViewType::PrDiff, pr(94)),
            (ViewType::Ticket, ticket("CORE-1")),
            (ViewType::File, file("a.rs")),
        ]);
        let backwards = replay(&[
            (ViewType::File, file("a.rs")),
            (ViewType::Ticket, ticket("CORE-1")),
            (ViewType::PrDiff, pr(94)),
            (ViewType::PrConversation, pr(94)),
        ]);
        assert_eq!(forwards.1, backwards.1, "labels, left to right");
    }

    // ── 9. the engine takes no state it shouldn't ─────────────────────────────

    #[test]
    fn placing_the_same_request_twice_against_an_unchanged_state_is_idempotent() {
        let state = with_detail(
            curated_start(),
            vec![tab("detail.0", ViewType::PrDiff, pr(94), 3)],
            0,
        );
        let req = show(ViewType::File, file("a.rs"));
        assert_eq!(
            place(&cfg(), &state, &req).unwrap(),
            place(&cfg(), &state, &req).unwrap()
        );
    }
}
