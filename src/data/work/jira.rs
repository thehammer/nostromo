//! Jira work source: placeholder until T2 (teri-fred-t2-jira) lands.
//!
//! Until then the source reports `not_configured` ("Coming soon") and has no
//! items, so the Teri surface shows an honest marker instead of an empty list.
//! The slice that implements it replaces this file (and its own tests) only:
//! keep `spawn` and `detail` as the hub's seam.

use std::sync::Arc;

use tokio::sync::{watch, Notify};

use super::hub::SourceUpdate;
use super::model::{SourceState, SourceStatus, WorkDetail, WorkError, WorkSource};

/// Start the source. `refresh` is poked by a manual refresh that passed the
/// hub's 15 s debounce; a real source fetches immediately when it fires.
pub fn spawn(_refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    let status = SourceStatus {
        source: WorkSource::Jira,
        state: SourceState::NotConfigured,
        updated_at: None,
        reason: Some("Coming soon".into()),
        retry_at: None,
        count: 0,
        group_errors: Vec::new(),
    };
    // The sender is dropped on purpose: the placeholder never changes.
    watch::channel((status, Vec::new())).1
}

/// Detail for one of this source's item ids.
pub async fn detail(_item_id: &str) -> Result<WorkDetail, WorkError> {
    Err(WorkError::not_available())
}
