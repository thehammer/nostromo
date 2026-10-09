//! Service seam between the IPC server and the work sources.
//!
//! The server never knows how work data is produced. Later slices install a
//! real [`WorkService`] / [`FredDetailService`] at daemon start; until then the
//! `Null*` defaults answer every request with `not_available`.

use std::sync::{Arc, RwLock};

use async_trait::async_trait;

use super::model::{SendOutcome, SendPreview, WorkDetail, WorkError, WorkSource};

/// Contract for Teri's work sources. Every method is only ever called for a
/// trusted (local) peer.
#[async_trait]
#[allow(clippy::double_must_use)]
pub trait WorkService: Send + Sync {
    /// Detail for a non-Fred item id (`todo:`, `doc:`, `jira:`, `sentry:`).
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError>;

    /// Manual refresh. `source: None` means every source; `fred` also asks
    /// Fred's sources to refresh.
    async fn refresh(&self, source: Option<WorkSource>, fred: bool) -> Result<(), WorkError>;

    /// Start (or ignore, if one is in flight) a picks generation.
    async fn refresh_picks(&self, reason: &str) -> Result<(), WorkError>;

    async fn send_preview(&self, item_id: &str) -> Result<SendPreview, WorkError>;

    async fn send(&self, request: SendRequest) -> Result<SendOutcome, WorkError>;
}

/// Parameters of `ClientMsg::WorkSend`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendRequest {
    pub item_id: String,
    /// `"focus"` or `"mother_job"`.
    pub destination: String,
    pub agent: String,
    pub working_directory: Option<String>,
    pub label: String,
    pub context: String,
    pub allow_duplicate: bool,
}

/// Detail provider for Fred mail (`mail:`) and calendar (`event:`) items.
#[async_trait]
#[allow(clippy::double_must_use)]
pub trait FredDetailService: Send + Sync {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError>;
}

/// Default [`WorkService`]: everything is `not_available`.
pub struct NullWorkService;

#[async_trait]
impl WorkService for NullWorkService {
    async fn detail(&self, _item_id: &str) -> Result<WorkDetail, WorkError> {
        Err(WorkError::not_available())
    }
    async fn refresh(&self, _source: Option<WorkSource>, _fred: bool) -> Result<(), WorkError> {
        Err(WorkError::not_available())
    }
    async fn refresh_picks(&self, _reason: &str) -> Result<(), WorkError> {
        Err(WorkError::not_available())
    }
    async fn send_preview(&self, _item_id: &str) -> Result<SendPreview, WorkError> {
        Err(WorkError::not_available())
    }
    async fn send(&self, _request: SendRequest) -> Result<SendOutcome, WorkError> {
        Err(WorkError::not_available())
    }
}

/// Default [`FredDetailService`]: `not_available`.
pub struct NullFredDetailService;

#[async_trait]
impl FredDetailService for NullFredDetailService {
    async fn detail(&self, _item_id: &str) -> Result<WorkDetail, WorkError> {
        Err(WorkError::not_available())
    }
}

static WORK_SERVICE: RwLock<Option<Arc<dyn WorkService>>> = RwLock::new(None);
static FRED_DETAIL_SERVICE: RwLock<Option<Arc<dyn FredDetailService>>> = RwLock::new(None);

/// Install the process-wide [`WorkService`], replacing any previous one.
pub fn install_work_service(service: Arc<dyn WorkService>) {
    *WORK_SERVICE.write().unwrap() = Some(service);
}

/// The installed [`WorkService`], or a [`NullWorkService`] if none is.
pub fn work_service() -> Arc<dyn WorkService> {
    WORK_SERVICE
        .read()
        .unwrap()
        .clone()
        .unwrap_or_else(|| Arc::new(NullWorkService))
}

/// Install the process-wide [`FredDetailService`], replacing any previous one.
pub fn install_fred_detail_service(service: Arc<dyn FredDetailService>) {
    *FRED_DETAIL_SERVICE.write().unwrap() = Some(service);
}

/// The installed [`FredDetailService`], or a [`NullFredDetailService`].
pub fn fred_detail_service() -> Arc<dyn FredDetailService> {
    FRED_DETAIL_SERVICE
        .read()
        .unwrap()
        .clone()
        .unwrap_or_else(|| Arc::new(NullFredDetailService))
}

/// Clear both registry slots. For tests only.
#[doc(hidden)]
pub fn reset_for_test() {
    *WORK_SERVICE.write().unwrap() = None;
    *FRED_DETAIL_SERVICE.write().unwrap() = None;
}
