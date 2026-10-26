//! H1: an unset-up Huey leaves no trace. (H1 has no network code at all, so
//! there is no request to assert on; later slices that add HTTP add their own
//! wired-in mock.)

use std::sync::Arc;
use std::time::Duration;

use chrono::TimeZone;
use nostromo::huey::context::ContextEnv;
use nostromo::huey::{HueyConfig, HueyDeps, HueyEngine, SetupState};
use nostromo::tracker::clock::FakeClock;

#[tokio::test]
async fn an_unset_up_engine_past_its_run_time_creates_no_files() {
    let root = tempfile::tempdir().unwrap();
    let clock = Arc::new(FakeClock::new(
        chrono::Utc.with_ymd_and_hms(2026, 10, 25, 3, 0, 0).unwrap(),
    ));
    let context = ContextEnv::for_home(
        root.path(),
        root.path().join("code"),
        root.path().to_path_buf(),
        "test".into(),
    );
    let src = HueyEngine::spawn(HueyDeps {
        clock: clock.clone(),
        tick: Duration::from_millis(5),
        ..HueyDeps::new(root.path().to_path_buf(), HueyConfig::default(), context)
    });
    // Well past 06:30 in any local time zone.
    clock.advance(chrono::Duration::hours(30));
    tokio::time::sleep(Duration::from_millis(100)).await;

    assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
}
