//! Teri/Fred work-item layer: the shared model, the hub that merges every
//! source, and the registry that plugs the hub into the IPC server.
//!
//! - [`model`]       — wire/data types (`WorkItem`, `SourceStatus`, `WorkDetail`, …)
//! - [`service`]     — `WorkService` / `FredDetailService` traits and the
//!   process-wide install/lookup registry
//! - [`hub`]         — `WorkHub`: owns every source's latest state, broadcasts
//!   changes, answers detail/refresh requests
//! - [`query`]       — filter/search/sort/group (§5), mirrored in `WorkQuery.swift`
//! - [`credentials`] — env + `~/.claude/credentials/.env` lookup
//! - [`todos`]       — Teri todo adapter
//! - [`repo_docs`], [`jira`], [`sentry`] — sources (placeholders until T1–T3)
//! - [`picks`], [`send`], [`sent`]        — T4/T5 seams (placeholders)

pub mod credentials;
pub mod hub;
pub mod jira;
pub mod model;
pub mod picks;
pub mod query;
pub mod repo_docs;
pub mod send;
pub mod sent;
pub mod sentry;
pub mod service;
pub mod todos;

pub use model::*;
pub use service::{
    fred_detail_service, install_fred_detail_service, install_work_service, work_service,
    FredDetailService, NullFredDetailService, NullWorkService, SendRequest, WorkService,
};
