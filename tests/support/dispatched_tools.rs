//! The tool names `src/mcp/tools/mod.rs` dispatches, read from the source of
//! `dispatch_inner`'s `match name { ... }` (the arms cannot be enumerated at
//! run time). The surface tests compare this set with the described one, so a
//! tool that is dispatched but not listed (and so never classified) fails.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

const MOD_RS: &str = include_str!("../../src/mcp/tools/mod.rs");

/// Every tool name `dispatch_inner` has an arm for.
pub fn dispatched_tool_names() -> BTreeSet<String> {
    let consts = string_consts();
    let start = MOD_RS
        .find("let content = match name {")
        .expect("dispatch_inner's `let content = match name {` moved: update this scan");
    let body = &MOD_RS[start..];
    let end = body
        .find("other => return ToolResult::UnknownTool")
        .expect("dispatch_inner's catch-all arm moved: update this scan");
    let names: BTreeSet<String> = body[..end]
        .lines()
        // Arms sit one level in from the match: eight spaces.
        .filter(|l| l.starts_with("        ") && !l.starts_with("         "))
        .filter_map(|l| l.trim().split_once(" =>").map(|(label, _)| label.trim()))
        .filter(|label| label.starts_with('"') || label.starts_with(char::is_uppercase))
        .map(|label| match label.strip_prefix('"') {
            Some(lit) => lit.trim_end_matches('"').to_string(),
            None => resolve(&consts, label),
        })
        .collect();
    assert!(
        names.len() > 40,
        "the scan found only {} dispatch arms: the arm layout changed, update this scan",
        names.len()
    );
    names
}

/// `const NAME: &str = <literal or path to another const>;` anywhere in the
/// tool and terminal sources: name to right-hand side.
fn string_consts() -> BTreeMap<String, String> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    for dir in ["mcp", "terminal"] {
        collect_rs(&root.join(dir), &mut files);
    }
    let mut out = BTreeMap::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        for line in text.lines() {
            let Some((head, rhs)) = line.split_once(": &str =") else {
                continue;
            };
            let Some(name) = head.trim().rsplit(' ').next() else {
                continue;
            };
            if head.contains("const ") {
                out.insert(
                    name.to_string(),
                    rhs.trim().trim_end_matches(';').to_string(),
                );
            }
        }
    }
    out
}

fn collect_rs(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_rs(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn resolve(consts: &BTreeMap<String, String>, label: &str) -> String {
    let mut name = label;
    for _ in 0..4 {
        let rhs = consts
            .get(name)
            .unwrap_or_else(|| panic!("dispatch arm `{name}` is not a const this scan can read"));
        match rhs.strip_prefix('"') {
            Some(lit) => return lit.trim_end_matches('"').to_string(),
            None => name = rhs.rsplit("::").next().unwrap().trim(),
        }
    }
    panic!("dispatch arm `{label}` aliases consts too deeply for this scan");
}
