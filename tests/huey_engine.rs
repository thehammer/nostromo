//! H1: an unset-up Huey leaves no trace and makes no request.

use std::sync::Arc;
use std::time::Duration;

use chrono::TimeZone;
use nostromo::huey::{HueyConfig, HueyDeps, HueyEngine, SetupState};
use nostromo::tracker::clock::FakeClock;
use wiremock::matchers::any;
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn an_unset_up_engine_past_its_run_time_creates_no_files_and_makes_no_request() {
    let server = MockServer::start().await;
    Mock::given(any())
        .respond_with(ResponseTemplate::new(200))
        .expect(0)
        .mount(&server)
        .await;

    let root = tempfile::tempdir().unwrap();
    let clock = Arc::new(FakeClock::new(
        chrono::Utc.with_ymd_and_hms(2026, 10, 25, 3, 0, 0).unwrap(),
    ));
    let src = HueyEngine::spawn(HueyDeps {
        state_root: root.path().to_path_buf(),
        config: HueyConfig::default(),
        clock: clock.clone(),
        tick: Duration::from_millis(5),
    });
    // Well past 06:30 in any local time zone.
    clock.advance(chrono::Duration::hours(30));
    tokio::time::sleep(Duration::from_millis(100)).await;

    assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    assert!(server.received_requests().await.unwrap().is_empty());
}
