//! The "Agent quick guide" in `docs/terminal.md` only names tools that exist.

use nostromo::mcp::tools::tool_descriptors;

#[test]
fn every_tool_named_in_the_agent_quick_guide_is_registered() {
    let doc =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/docs/terminal.md")).unwrap();
    let guide = doc
        .split("## Agent quick guide")
        .nth(1)
        .expect("docs/terminal.md has an Agent quick guide")
        .split("\n## ")
        .next()
        .unwrap();
    let registered: Vec<String> = tool_descriptors()
        .iter()
        .filter_map(|d| d["name"].as_str().map(str::to_string))
        .collect();
    let mut named = 0;
    for word in guide.split(|c: char| !(c.is_ascii_alphanumeric() || c == '.' || c == '_')) {
        let word = word.trim_end_matches('.');
        if word.starts_with("nostromo.") && word.len() > "nostromo.".len() {
            named += 1;
            assert!(registered.iter().any(|r| r == word), "unknown tool {word}");
        }
    }
    assert!(named >= 6, "the guide names {named} tools");
}
