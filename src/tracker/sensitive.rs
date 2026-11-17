//! Sensitive text the user (pane or file) brings onto a board (PRD 43).
//!
//! The pane and the file are never refused for it: the board file is the
//! user's. Instead an item with a guard finding in any text-bearing field is
//! *badged* in the pane and *withheld* from everything Nostromo hands an agent
//! (`compact_full`, `delta_entries`, conflict entries) until the user clears
//! it for that exact content. Both are computed from content, so they hold
//! for a board edited while the daemon was down and after a restart; only the
//! user's approvals are stored (as hashes, never the text).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::diff::field_value;
use super::model::{bounded, fnv1a64, Item};
use crate::sensitive_text::{scan, GuardConfig};

/// What an agent reads in place of a value with a guard finding.
pub const WITHHELD: &str = "[withheld: possible sensitive data]";

/// The text-bearing fields of an item (the guard's targets).
const TEXT_FIELDS: [&str; 5] = ["text", "note", "owner", "links", "command"];

/// The user's approvals: per item, the hashes of the strings they cleared.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Approvals {
    items: BTreeMap<String, BTreeSet<u64>>,
}

impl Approvals {
    /// Records the user's approval of `item`'s current content: the hash of
    /// every string in its text-bearing fields, in full and in the bounded
    /// form the change log keeps. Replaces any earlier approval of the item.
    pub fn approve(&mut self, item: &Item) {
        let mut hashes = BTreeSet::new();
        for field in TEXT_FIELDS {
            let value = field_value(item, field);
            for v in [value.clone(), bounded(value)] {
                leaves(&v, &mut |s| {
                    hashes.insert(hash(s));
                });
            }
        }
        self.items.insert(item.id.clone(), hashes);
    }

    /// Does `value` (a string, or a JSON value of strings) hold a string with
    /// a guard finding that the user has not approved for `item_id`?
    pub fn withholds(&self, item_id: Option<&str>, value: &Value) -> bool {
        let approved = item_id.and_then(|id| self.items.get(id));
        let mut withheld = false;
        leaves(value, &mut |s| {
            if has_finding(s) && !approved.is_some_and(|set| set.contains(&hash(s))) {
                withheld = true;
            }
        });
        withheld
    }

    /// [`Self::withholds`] for one string.
    pub fn withholds_str(&self, item_id: Option<&str>, text: &str) -> bool {
        self.withholds(item_id, &Value::String(text.to_string()))
    }

    /// The classes of the unapproved findings in `item`'s text-bearing
    /// fields, sorted and unique; empty when nothing is badged.
    pub fn badge(&self, item: &Item) -> Vec<String> {
        let approved = self.items.get(&item.id);
        let mut classes = BTreeSet::new();
        for field in TEXT_FIELDS {
            leaves(&field_value(item, field), &mut |s| {
                if approved.is_some_and(|set| set.contains(&hash(s))) {
                    return;
                }
                for finding in scan(s, &GuardConfig::default()) {
                    classes.insert(finding.class.as_str().to_string());
                }
            });
        }
        classes.into_iter().collect()
    }
}

/// Does the guard find anything in `text`?
pub fn has_finding(text: &str) -> bool {
    !scan(text, &GuardConfig::default()).is_empty()
}

fn hash(text: &str) -> u64 {
    fnv1a64(text.as_bytes())
}

/// Calls `f` on every string inside `value` (object keys excluded).
fn leaves(value: &Value, f: &mut impl FnMut(&str)) {
    match value {
        Value::String(s) => f(s),
        Value::Array(items) => items.iter().for_each(|v| leaves(v, f)),
        Value::Object(map) => map.values().for_each(|v| leaves(v, f)),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A synthetic US-format SSN: the guard's own tests use the same shape.
    const SSN: &str = "123-45-6789";

    fn item(text: &str) -> Item {
        Item::new("a", "now", text)
    }

    #[test]
    fn a_finding_withholds_until_the_exact_content_is_approved() {
        let mut approvals = Approvals::default();
        let it = item(&format!("call about {SSN}"));
        assert!(approvals.withholds_str(Some("a"), &it.text));
        assert_eq!(approvals.badge(&it), vec!["ssn".to_string()]);
        approvals.approve(&it);
        assert!(!approvals.withholds_str(Some("a"), &it.text));
        assert!(approvals.badge(&it).is_empty());
        // Other content with a finding is still withheld, as is the same
        // text under another item.
        assert!(approvals.withholds_str(Some("a"), "123-45-6788 too"));
        assert!(approvals.withholds_str(Some("b"), &it.text));
    }

    #[test]
    fn clean_text_is_never_withheld() {
        let approvals = Approvals::default();
        assert!(!approvals.withholds_str(None, "Check the deploy"));
        assert!(approvals.badge(&item("Check the deploy")).is_empty());
    }

    #[test]
    fn a_long_value_approved_in_full_is_approved_in_its_logged_form_too() {
        let long = format!("{SSN} {}", "x".repeat(400));
        let it = item(&long);
        let mut approvals = Approvals::default();
        approvals.approve(&it);
        let logged = bounded(Value::String(long));
        assert!(!approvals.withholds(Some("a"), &logged));
    }
}
