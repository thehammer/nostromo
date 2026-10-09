//! Teri/Fred work-item layer: the shared model, and the registry that lets
//! later slices plug real sources into the IPC server without touching it.
//!
//! - [`model`]   — wire/data types (`WorkItem`, `SourceStatus`, `WorkDetail`, …)
//! - [`service`] — `WorkService` / `FredDetailService` traits and the
//!   process-wide install/lookup registry

pub mod model;
pub mod service;

pub use model::*;
pub use service::{
    fred_detail_service, install_fred_detail_service, install_work_service, work_service,
    FredDetailService, NullFredDetailService, NullWorkService, SendRequest, WorkService,
};
