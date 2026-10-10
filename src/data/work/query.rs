//! Filter / search / sort / group for work items (design contract §5).
//!
//! One definition, two engines: the Mac app has the same logic in
//! `Data/WorkQuery.swift`. Both are tested against
//! `tests/fixtures/work_query_cases.json`, so a change here needs the same
//! change there (and a new fixture case).

use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde::Deserialize;

use super::model::{WorkItem, WorkSource};

/// Filters. Values within one list are ORed; different filters are ANDed.
/// An empty list means "no constraint".
#[derive(Debug, Default, Clone, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct WorkFilter {
    pub sources: Vec<WorkSource>,
    pub kinds: Vec<String>,
    pub repos: Vec<String>,
    pub projects: Vec<String>,
    pub statuses: Vec<String>,
    pub environments: Vec<String>,
    /// `Some(true)`: only items that state a severity; `Some(false)`: only those that do not.
    pub has_severity: Option<bool>,
    /// Whitespace-separated terms; every term must match `title` or `search_text`.
    pub query: String,
}

/// Within-group order for repo docs.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SortKey {
    /// `created_at` newest first; undated last.
    #[default]
    Newest,
    /// `created_at` oldest first; undated last.
    Oldest,
    Title,
}

/// A facet whose values are counted for filter chips.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Facet {
    Source,
    Kind,
    Repo,
    Project,
    Status,
    Environment,
}

/// One group of the grouped list. `key` is `None` for sources that are one flat list.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkGroup {
    pub key: Option<String>,
    pub items: Vec<WorkItem>,
}

/// Items matching `f`, in input order.
pub fn filter(items: &[WorkItem], f: &WorkFilter) -> Vec<WorkItem> {
    let terms = search_terms(&f.query);
    items
        .iter()
        .filter(|item| matches(item, f, &terms))
        .cloned()
        .collect()
}

/// Sort and group already-filtered `items` of `source` for display.
pub fn group(items: &[WorkItem], source: WorkSource, sort: SortKey) -> Vec<WorkGroup> {
    if items.is_empty() {
        return Vec::new();
    }
    match source {
        WorkSource::Todos => vec![flat(items, cmp_todos)],
        WorkSource::Sentry => vec![flat(items, |a, b| cmp_date_desc(a.updated_at, b.updated_at))],
        WorkSource::Jira => group_jira(items),
        WorkSource::RepoDocs => group_repo_docs(items, sort),
    }
}

/// Value → count of `facet` over the items that match every filter except the
/// one on `facet` itself (the standard faceted-search behaviour). Items with no
/// value for the facet are not counted.
pub fn facet_counts(items: &[WorkItem], f: &WorkFilter, facet: Facet) -> BTreeMap<String, usize> {
    let mut relaxed = f.clone();
    match facet {
        Facet::Source => relaxed.sources.clear(),
        Facet::Kind => relaxed.kinds.clear(),
        Facet::Repo => relaxed.repos.clear(),
        Facet::Project => relaxed.projects.clear(),
        Facet::Status => relaxed.statuses.clear(),
        Facet::Environment => relaxed.environments.clear(),
    }
    let terms = search_terms(&relaxed.query);
    let mut counts = BTreeMap::new();
    for item in items {
        if !matches(item, &relaxed, &terms) {
            continue;
        }
        let value = match facet {
            Facet::Source => Some(item.source.as_str().to_string()),
            Facet::Kind => Some(item.kind.clone()),
            Facet::Repo => item.repo.clone(),
            Facet::Project => item.project.clone(),
            Facet::Status => item.status.clone(),
            Facet::Environment => item.environment.clone(),
        };
        if let Some(value) = value {
            *counts.entry(value).or_insert(0) += 1;
        }
    }
    counts
}

/// The default order of a source's items (all groups, flattened). Used by the
/// hub and the MCP tools so they list items as the UI does.
pub fn default_order(items: &[WorkItem], source: WorkSource) -> Vec<WorkItem> {
    group(items, source, SortKey::Newest).into_iter().flat_map(|g| g.items).collect()
}

// ── matching ──────────────────────────────────────────────────────────────────

fn matches(item: &WorkItem, f: &WorkFilter, terms: &[String]) -> bool {
    matches_fields(item, f) && matches_terms(item, terms)
}

fn matches_fields(item: &WorkItem, f: &WorkFilter) -> bool {
    fn one_of(wanted: &[String], have: Option<&str>) -> bool {
        wanted.is_empty() || have.is_some_and(|h| wanted.iter().any(|w| w == h))
    }
    (f.sources.is_empty() || f.sources.contains(&item.source))
        && (f.kinds.is_empty() || f.kinds.contains(&item.kind))
        && one_of(&f.repos, item.repo.as_deref())
        && one_of(&f.projects, item.project.as_deref())
        && one_of(&f.statuses, item.status.as_deref())
        && one_of(&f.environments, item.environment.as_deref())
        && f.has_severity.is_none_or(|want| item.severity.is_some() == want)
}

fn search_terms(query: &str) -> Vec<String> {
    query.split_whitespace().map(fold).collect()
}

fn matches_terms(item: &WorkItem, terms: &[String]) -> bool {
    if terms.is_empty() {
        return true;
    }
    let title = fold(&item.title);
    let body = fold(&item.search_text);
    terms.iter().all(|t| title.contains(t.as_str()) || body.contains(t.as_str()))
}

/// Case- and diacritic-insensitive form of `s`.
fn fold(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    s.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| !('\u{0300}'..='\u{036f}').contains(c))
        .map(strip_accent)
        .collect()
}

fn strip_accent(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => 'c',
        'ď' | 'đ' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => 'g',
        'ĥ' | 'ħ' => 'h',
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ı' => 'i',
        'ĵ' => 'j',
        'ķ' => 'k',
        'ĺ' | 'ļ' | 'ľ' | 'ŀ' | 'ł' => 'l',
        'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' => 'o',
        'ŕ' | 'ŗ' | 'ř' => 'r',
        'ś' | 'ŝ' | 'ş' | 'š' => 's',
        'ţ' | 'ť' | 'ŧ' => 't',
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => 'u',
        'ŵ' => 'w',
        'ý' | 'ÿ' | 'ŷ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

// ── ordering ──────────────────────────────────────────────────────────────────

fn flat(items: &[WorkItem], cmp: impl Fn(&WorkItem, &WorkItem) -> Ordering) -> WorkGroup {
    let mut sorted = items.to_vec();
    sorted.sort_by(cmp);
    WorkGroup { key: None, items: sorted }
}

/// Rank ascending, items with no priority last.
fn cmp_rank(a: &WorkItem, b: &WorkItem) -> Ordering {
    let rank = |i: &WorkItem| i.priority.as_ref().map_or(u8::MAX, |p| p.rank);
    rank(a).cmp(&rank(b))
}

/// Ascending, `None` last.
fn cmp_none_last<T: Ord>(a: Option<T>, b: Option<T>) -> Ordering {
    cmp_present(a, b, |a, b| a.cmp(&b))
}

/// Newest first, `None` last.
fn cmp_date_desc<T: Ord>(a: Option<T>, b: Option<T>) -> Ordering {
    cmp_present(a, b, |a, b| b.cmp(&a))
}

/// Compare present values with `cmp`; a missing value sorts after a present one.
fn cmp_present<T>(a: Option<T>, b: Option<T>, cmp: impl FnOnce(T, T) -> Ordering) -> Ordering {
    match (a, b) {
        (Some(a), Some(b)) => cmp(a, b),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn cmp_title(a: &WorkItem, b: &WorkItem) -> Ordering {
    fold(&a.title).cmp(&fold(&b.title))
}

fn cmp_todos(a: &WorkItem, b: &WorkItem) -> Ordering {
    cmp_rank(a, b)
        .then_with(|| cmp_none_last(a.due, b.due))
        .then_with(|| cmp_title(a, b))
}

fn group_jira(items: &[WorkItem]) -> Vec<WorkGroup> {
    const ORDER: [&str; 3] = ["in_progress", "to_do", "other"];
    let category = |i: &WorkItem| match i.status_category.as_deref() {
        Some(c @ ("in_progress" | "to_do")) => c.to_string(),
        _ => "other".to_string(),
    };
    ORDER
        .iter()
        .filter_map(|key| {
            let members: Vec<WorkItem> =
                items.iter().filter(|i| category(i) == *key).cloned().collect();
            if members.is_empty() {
                return None;
            }
            let mut group = flat(&members, |a, b| {
                cmp_rank(a, b).then_with(|| cmp_date_desc(a.updated_at, b.updated_at))
            });
            group.key = Some((*key).to_string());
            Some(group)
        })
        .collect()
}

fn group_repo_docs(items: &[WorkItem], sort: SortKey) -> Vec<WorkGroup> {
    let mut by_repo: BTreeMap<String, Vec<WorkItem>> = BTreeMap::new();
    for item in items {
        by_repo.entry(item.repo.clone().unwrap_or_default()).or_default().push(item.clone());
    }
    let mut groups: Vec<WorkGroup> = by_repo
        .into_iter()
        .map(|(repo, members)| {
            let mut group = match sort {
                SortKey::Newest => flat(&members, |a, b| cmp_date_desc(a.created_at, b.created_at)),
                SortKey::Oldest => flat(&members, |a, b| cmp_none_last(a.created_at, b.created_at)),
                SortKey::Title => flat(&members, cmp_title),
            };
            group.key = Some(repo);
            group
        })
        .collect();
    // BTreeMap already ordered the repos by name; a stable sort by size keeps ties by name.
    groups.sort_by_key(|g| std::cmp::Reverse(g.items.len()));
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folding_is_case_and_diacritic_insensitive() {
        assert_eq!(fold("Café ÉCOLE"), "cafe ecole");
        assert_eq!(fold("plain ASCII"), "plain ascii");
        assert_eq!(fold("cafe\u{0301}"), "cafe", "combining marks are dropped");
    }
}
