//! T1: the MCP surface never names anything that can drive a terminal.
//!
//! An agent's MCP code may open a terminal in its own focus
//! (`TerminalAgentApi`) and nothing else. The strongest guard against a future
//! change widening that is that nothing under `src/mcp/` can even name the
//! capability to write input (`OperatorCap`), the manager that holds the
//! terminals (`TerminalManager`), or the input verbs. This test reads every
//! `.rs` file under `src/mcp/` as text and fails if any of them mentions one.
//!
//! The scan is a function over `(path, contents)` pairs, so the test also
//! shows, against in-memory files, that it would fail the moment a forbidden
//! token is added under `src/mcp/`.

use std::path::{Path, PathBuf};

/// Words no file under `src/mcp/` may contain (`TerminalAgentApi` is the one
/// terminal name that is allowed there).
const FORBIDDEN: [&str; 6] = [
    "OperatorCap",
    "TerminalManager",
    "terminal_input",
    "TerminalInput",
    "write_input",
    ".input(",
];

/// One forbidden token found in one file.
#[derive(Debug, PartialEq, Eq)]
struct Violation {
    path: String,
    token: &'static str,
    line: usize,
}

/// Every forbidden token in every file.
fn scan<'a>(files: impl IntoIterator<Item = (&'a str, &'a str)>) -> Vec<Violation> {
    let mut found = Vec::new();
    for (path, contents) in files {
        for (index, text) in contents.lines().enumerate() {
            for token in FORBIDDEN {
                if text.contains(token) {
                    found.push(Violation {
                        path: path.to_string(),
                        token,
                        line: index + 1,
                    });
                }
            }
        }
    }
    found
}

/// Every `.rs` file under `dir`, recursively.
fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
        .map(|e| e.expect("directory entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn mcp_sources() -> Vec<(String, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("mcp");
    let mut paths = Vec::new();
    rust_files(&root, &mut paths);
    paths
        .into_iter()
        .map(|p| {
            let text = std::fs::read_to_string(&p)
                .unwrap_or_else(|e| panic!("cannot read {}: {e}", p.display()));
            let shown = p
                .strip_prefix(env!("CARGO_MANIFEST_DIR"))
                .unwrap_or(&p)
                .display()
                .to_string();
            (shown, text)
        })
        .collect()
}

#[test]
fn nothing_under_src_mcp_names_the_terminal_write_path() {
    let sources = mcp_sources();
    assert!(
        sources.len() > 10,
        "expected to scan the whole MCP tree, found {} files",
        sources.len()
    );
    assert!(
        sources
            .iter()
            .any(|(p, _)| p.ends_with("tools/terminal.rs")),
        "src/mcp/tools/terminal.rs should be part of the scan"
    );

    let violations = scan(sources.iter().map(|(p, c)| (p.as_str(), c.as_str())));

    assert!(
        violations.is_empty(),
        "src/mcp/ must not name the terminal write path (only `TerminalAgentApi` may be used there): {violations:#?}"
    );
}

#[test]
fn the_scan_fails_when_a_forbidden_token_is_added_under_src_mcp() {
    for token in FORBIDDEN {
        let contents = format!("fn sneaky() {{\n    let x = 1;\n    use_it({token});\n}}\n");

        let violations = scan([("src/mcp/tools/sneaky.rs", contents.as_str())]);

        assert_eq!(
            violations,
            vec![Violation {
                path: "src/mcp/tools/sneaky.rs".to_string(),
                token,
                line: 3,
            }],
            "a file containing {token:?} must be reported"
        );
    }
}

#[test]
fn the_scan_lets_the_agent_api_and_ordinary_code_through() {
    let clean = "use crate::terminal::TerminalAgentApi;\nfn f(api: &TerminalAgentApi) { api.open_local(\"t\", None); }\nlet y = x.input; let z = inputs();\n";

    assert!(scan([("src/mcp/tools/ok.rs", clean)]).is_empty());
}
