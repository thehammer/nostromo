//! Offline proxy for tool search (PRD 27): a BM25 ranking (k1 = 1.2, b = 0.75) over
//! `name + description` of every descriptor puts `nostromo.tracker` in the top 3 for the
//! words an agent would search with.

use std::collections::HashMap;

use nostromo::mcp::tools::tool_descriptors;
use serde_json::Value;

fn tokens(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .collect()
}

/// Names of the descriptors, best match first.
fn rank(query: &str) -> Vec<String> {
    let docs: Vec<(String, Vec<String>)> = tool_descriptors()
        .iter()
        .map(|d| {
            let name = d["name"].as_str().unwrap().to_string();
            let text = format!("{} {}", name, d["description"].as_str().unwrap_or(""));
            (name, tokens(&text))
        })
        .collect();
    let n = docs.len() as f64;
    let avg_len = docs.iter().map(|(_, t)| t.len()).sum::<usize>() as f64 / n;
    let (k1, b) = (1.2, 0.75);
    let mut scored: Vec<(String, f64)> = docs
        .iter()
        .map(|(name, toks)| {
            let mut tf: HashMap<&str, f64> = HashMap::new();
            for t in toks {
                *tf.entry(t.as_str()).or_default() += 1.0;
            }
            let score = tokens(query)
                .iter()
                .map(|q| {
                    let df = docs.iter().filter(|(_, t)| t.contains(q)).count() as f64;
                    let idf = ((n - df + 0.5) / (df + 0.5) + 1.0).ln();
                    let f = tf.get(q.as_str()).copied().unwrap_or(0.0);
                    idf * f * (k1 + 1.0) / (f + k1 * (1.0 - b + b * toks.len() as f64 / avg_len))
                })
                .sum();
            (name.clone(), score)
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then_with(|| a.0.cmp(&b.0)));
    scored.into_iter().map(|(n, _)| n).collect()
}

#[test]
fn the_tracker_is_in_the_top_three_for_every_phrase_an_agent_would_search() {
    for query in [
        "tracker",
        "status board",
        "todo list pane",
        "keep track of tasks",
        "board",
        "checklist",
        "handoff",
        "where things stand",
    ] {
        let top: Vec<String> = rank(query).into_iter().take(3).collect();
        assert!(top.contains(&"nostromo.tracker".to_string()), "{query:?}: top 3 was {top:?}");
    }
}

#[test]
fn the_description_opens_with_the_search_words_and_the_descriptor_stays_in_budget() {
    let d = tool_descriptors().into_iter().find(|d| d["name"] == "nostromo.tracker").unwrap();
    assert!(d["description"].as_str().unwrap().starts_with(
        "Tracker (status board / todo list / checklist) pane: keep track of tasks and where things stand, as a markdown handoff file beside the transcript."
    ));
    let bytes = serde_json::to_string(&d as &Value).unwrap().len();
    assert!(bytes <= 3_600, "descriptor is {bytes} bytes");
    assert!((bytes as f64 / 2.5).ceil() as usize <= 1_500);
}
