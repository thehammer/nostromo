//! Filter / group / facet-count semantics of the Teri work list (design
//! contract §5), checked against the fixture the Swift app tests share
//! (`tests/fixtures/work_query_cases.json`). Both engines must agree with it.

use std::collections::BTreeMap;

use nostromo::data::work::query::{self, Facet, SortKey, WorkFilter};
use nostromo::data::work::{WorkItem, WorkSource};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    items: Vec<WorkItem>,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    op: String,
    #[serde(default)]
    filter: WorkFilter,
    #[serde(default)]
    source: Option<WorkSource>,
    #[serde(default)]
    sort: Option<SortKey>,
    #[serde(default)]
    facet: Option<Facet>,
    #[serde(default)]
    expected_ids: Vec<String>,
    #[serde(default)]
    expected_groups: Vec<ExpectedGroup>,
    #[serde(default)]
    expected_counts: BTreeMap<String, usize>,
}

#[derive(Deserialize)]
struct ExpectedGroup {
    key: Option<String>,
    ids: Vec<String>,
}

fn load() -> Fixture {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/work_query_cases.json");
    let text = std::fs::read_to_string(path).expect("fixture file is readable");
    serde_json::from_str(&text).expect("fixture parses as the work_query_cases format")
}

fn ids(items: &[WorkItem]) -> Vec<String> {
    items.iter().map(|i| i.id.clone()).collect()
}

#[test]
fn the_shared_fixture_covers_every_operation_with_enough_cases() {
    let f = load();
    assert!(f.cases.len() >= 12, "only {} cases", f.cases.len());
    for op in ["filter", "group", "facet_counts"] {
        assert!(f.cases.iter().any(|c| c.op == op), "no case uses op {op}");
    }
    assert!(!f.items.is_empty());
}

#[test]
fn every_shared_fixture_case_gives_the_expected_result() {
    let f = load();
    let mut failures = Vec::new();
    for case in &f.cases {
        match case.op.as_str() {
            "filter" => {
                let got = ids(&query::filter(&f.items, &case.filter));
                if got != case.expected_ids {
                    failures.push(format!(
                        "[{}] filter: expected {:?}, got {:?}",
                        case.name, case.expected_ids, got
                    ));
                }
            }
            "group" => {
                let source = case.source.expect("group cases name a source");
                let filtered = query::filter(&f.items, &case.filter);
                let groups = query::group(&filtered, source, case.sort.unwrap_or_default());
                let got: Vec<(Option<String>, Vec<String>)> =
                    groups.iter().map(|g| (g.key.clone(), ids(&g.items))).collect();
                let want: Vec<(Option<String>, Vec<String>)> = case
                    .expected_groups
                    .iter()
                    .map(|g| (g.key.clone(), g.ids.clone()))
                    .collect();
                if got != want {
                    failures.push(format!("[{}] group: expected {want:?}, got {got:?}", case.name));
                }
            }
            "facet_counts" => {
                let facet = case.facet.expect("facet cases name a facet");
                let got = query::facet_counts(&f.items, &case.filter, facet);
                if got != case.expected_counts {
                    failures.push(format!(
                        "[{}] facet_counts: expected {:?}, got {:?}",
                        case.name, case.expected_counts, got
                    ));
                }
            }
            other => panic!("unknown op {other} in case {}", case.name),
        }
    }
    assert!(failures.is_empty(), "{} case(s) failed:\n{}", failures.len(), failures.join("\n"));
}

#[test]
fn filtering_does_not_mutate_or_reorder_the_input() {
    let f = load();
    let before = ids(&f.items);
    let _ = query::filter(&f.items, &WorkFilter { query: "payment".into(), ..Default::default() });
    assert_eq!(ids(&f.items), before);
}
