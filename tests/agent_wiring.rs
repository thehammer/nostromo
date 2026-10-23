//! Daemon wiring guards for disabled agents. This file is its own test binary
//! (its own process), so the process-global work service is untouched by any
//! other test.

use nostromo::agents::ParkedSenders;
use nostromo::data::work::work_service;

/// With Teri disabled, nostromd never calls `install_work_service`, so the
/// Mac's work requests get `not_available` from the Null service rather than
/// a hub that is not running.
#[tokio::test]
async fn work_service_is_the_null_service_until_something_installs_one() {
    assert!(work_service().detail("any-item").await.is_err());
    assert!(work_service().refresh(None, false).await.is_err());
}

/// The receivers a disabled agent hands its consumers stay open (the pane
/// source broadcaster exits when one closes) and never carry data.
#[tokio::test]
async fn disabled_agent_receivers_stay_open_and_empty() {
    let mut parked = ParkedSenders::default();
    let rx = parked.channel::<Option<u8>>(None);
    assert!(rx.has_changed().is_ok());
    assert_eq!(*rx.borrow(), None);
}
