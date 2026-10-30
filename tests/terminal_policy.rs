//! T1: the MCP surface never names anything that can drive a terminal.
//!
//! An agent's MCP code may open a terminal in its own focus
//! (`TerminalAgentApi`) and nothing else. The strongest guard against a future
//! change widening that is that nothing under `src/mcp/` can even name the
//! capability to write input (`OperatorCap`), the manager that holds the
//! terminals (`TerminalManager`), or the input verbs. This test reads every
//! `.rs` file under `src/mcp/` as text and fails if any of them mentions one.
//!
//! The scan is a tripwire, not the guard: it catches a careless edit by name,
//! and a determined one could alias around it (`use ... as`, a re-export, a
//! macro). The real guard is structural: `TerminalAgentApi.manager` is a
//! private field, so MCP code holds no `TerminalManager` and no
//! `OperatorCap` unless some other module hands one over, and the only way to
//! get a cap is `terminal::access::mint`, which the scan also names.
//!
//! The scan is a function over `(path, contents)` pairs, so the test also
//! shows, against in-memory files, that it would fail the moment a forbidden
//! token is added under `src/mcp/`.

use std::path::{Path, PathBuf};

/// Words no file under `src/mcp/` may contain (`TerminalAgentApi` is the one
/// terminal name that is allowed there).
const FORBIDDEN: [&str; 23] = [
    "OperatorCap",
    "TerminalManager",
    "terminal_input",
    "TerminalInput",
    "write_input",
    ".input(",
    // The pane registry's own terminal-leaf plumbing is `pub`: a handler that
    // reached it through `pane_registry` would walk around every layout guard.
    // (`unregister_terminal_leaf` contains the first.)
    "register_terminal_leaf",
    "insert_terminal_leaf",
    "remove_terminal_leaf",
    // `terminal::access::mint(PeerTrust::OperatorApp)` is `pub(crate)`, so it
    // is reachable from `src/mcp/` and hands out the `OperatorCap` that
    // unlocks input, attach and close. It contains none of the tokens above.
    "access::",
    "mint(",
    // What opens a remote shell or answers its confirm sheet: an agent's MCP
    // code may only ask, through `TerminalAgentApi::request_remote`.
    "remote_request::run",
    "RemoteLauncher",
    "open_remote",
    "remote_answer",
    // The real launcher and what it starts: an `Arc<TerminalSession>` has
    // `write`, so code that could spawn one could also drive a production shell.
    "AwsEcsLauncher",
    "spawn_argv",
    "execute_command_argv",
    "TerminalSession",
    "ecs::connect",
    // What starts a follow: the follow manager itself and the proofs of an
    // operator's answer it acts on. An agent's MCP code may only ask, through
    // `TerminalAgentApi::request_follow`, and read through `read_screen_if_following`.
    "FollowManager",
    "FollowGrant",
    // The staging lists: an agent edits one only through
    // `TerminalAgentApi::staging`, which checks who follows the terminal.
    "StagingStore",
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

#[test]
fn the_scan_reports_a_line_under_src_mcp_that_mints_an_operator_cap() {
    // The realistic way to get a cap from `src/mcp/`: it names none of the
    // older tokens (no `OperatorCap`, no `TerminalManager`), only the path.
    let contents = "fn sneaky() {\n    let cap = crate::terminal::access::mint(PeerTrust::OperatorApp);\n    use_it(&cap);\n}\n";

    let violations = scan([("src/mcp/tools/sneaky.rs", contents)]);

    let mut tokens: Vec<&str> = violations.iter().map(|v| v.token).collect();
    tokens.sort_unstable();
    assert_eq!(
        tokens,
        vec!["access::", "mint("],
        "both tokens of the mint call must be reported: {violations:#?}"
    );
    assert!(
        violations
            .iter()
            .all(|v| v.path == "src/mcp/tools/sneaky.rs" && v.line == 2),
        "each must name the file and the line of the call: {violations:#?}"
    );
}

#[test]
fn the_real_src_mcp_tree_names_neither_the_access_module_nor_a_mint_call() {
    let sources = mcp_sources();
    assert!(sources.len() > 10, "expected the whole MCP tree");

    let violations: Vec<_> = scan(sources.iter().map(|(p, c)| (p.as_str(), c.as_str())))
        .into_iter()
        .filter(|v| v.token == "access::" || v.token == "mint(")
        .collect();

    assert!(
        violations.is_empty(),
        "src/mcp/ must not reach the way to get an OperatorCap: {violations:#?}"
    );
}
