//! Permission approvals: the production-shell guard (AP0g) and, in later
//! slices, the approval broker, display breakdown and rules.
//!
//! - [`shell`]: a small shell tokenizer (words, separators, here-docs, nested
//!   `$( )` / backticks / subshells and `bash -c` / `eval` payloads). It is
//!   shared by the guard and, later, by the display breakdown and the rule
//!   matcher, so they can never disagree about what a command line contains.
//! - [`guard`]: the production-shell policy. It runs as a PreToolUse hook
//!   (`nostromo-guard pre-tool-use`) in every daemon-hosted session and
//!   decides from the hook payload and a tmux/ps probe alone.
//! - [`audit`]: the append-only JSONL audit store under [`ApprovalsPaths`].
//! - [`request`]: a permission request from the CLI, typed and sanitized, and
//!   the "Why" line.
//! - [`display`]: the exact-text breakdown of a request (round-trip safe).
//! - [`broker`]: hears every permission request, logs it, and always answers it.

pub mod audit;
pub mod broker;
pub mod display;
pub mod guard;
pub mod request;
pub mod shell;

mod expand;
mod inert;
mod keys;
mod tmux_bin;

use std::path::{Path, PathBuf};

/// Env var overriding the approvals directory. Tests must set it.
pub const APPROVALS_DIR_ENV: &str = "NOSTROMO_APPROVALS_DIR";

/// Where the approvals state lives: `NOSTROMO_APPROVALS_DIR`, else
/// `~/.nostromo/approvals`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalsPaths {
    dir: PathBuf,
}

impl ApprovalsPaths {
    /// Resolve the approvals directory.
    ///
    /// In a debug cargo test binary this panics unless `NOSTROMO_APPROVALS_DIR`
    /// is set, so no test can ever reach the real `~/.nostromo/approvals`.
    pub fn resolve() -> Self {
        if let Some(dir) = std::env::var_os(APPROVALS_DIR_ENV).filter(|d| !d.is_empty()) {
            return Self::at(dir);
        }
        if cfg!(debug_assertions) && is_test_binary() {
            panic!("a test resolved the real approvals dir (~/.nostromo/approvals): set {APPROVALS_DIR_ENV}");
        }
        let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        Self::at(home.join(".nostromo").join("approvals"))
    }

    /// An explicit directory (tests, tools).
    pub fn at(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The approvals directory.
    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

/// Is this process a cargo test binary (they live in `target/<profile>/deps`)?
fn is_test_binary() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().and_then(Path::file_name).map(|n| n == "deps"))
        .unwrap_or(false)
}
