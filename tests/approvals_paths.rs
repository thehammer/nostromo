//! Where the approvals state lives (AP0g, design contract §7, T-AP0g-5).
//!
//! This file holds exactly ONE test. It mutates process-wide env (`NOSTROMO_APPROVALS_DIR`), and
//! cargo runs the tests of one file in parallel threads, so a second test here could race it.
//! Every other test file passes env to subprocesses with `Command::env` and never mutates its own.

use std::panic::{catch_unwind, AssertUnwindSafe};

use nostromo::approvals::{ApprovalsPaths, APPROVALS_DIR_ENV};

#[test]
fn the_approvals_dir_is_the_env_override_and_a_test_binary_can_never_reach_the_real_home() {
    assert_eq!(APPROVALS_DIR_ENV, "NOSTROMO_APPROVALS_DIR");

    // With the override set, that directory is used as given.
    let dir = tempfile::tempdir().unwrap();
    std::env::set_var(APPROVALS_DIR_ENV, dir.path());
    assert_eq!(ApprovalsPaths::resolve().dir(), dir.path());
    assert_eq!(ApprovalsPaths::resolve(), ApprovalsPaths::at(dir.path()));

    // Without it, a debug test binary must refuse to resolve `~/.nostromo/approvals`, and say why.
    std::env::remove_var(APPROVALS_DIR_ENV);
    if cfg!(debug_assertions) {
        let outcome = catch_unwind(AssertUnwindSafe(|| ApprovalsPaths::resolve()));
        let payload = outcome.expect_err("resolving the real home from a test binary must panic");
        let message = payload
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default();
        assert!(message.contains(APPROVALS_DIR_ENV), "the panic names the variable to set: {message:?}");
    }
}
