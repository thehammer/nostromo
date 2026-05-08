//! Library crate — exposes modules for integration tests.

use clap::ValueEnum;

pub mod agent_bus;
pub mod app;
pub mod config;
pub mod data;
pub mod event;
pub mod ipc;
pub mod layout;
pub mod mother;
pub mod pty;
pub mod ui;
pub mod views;

/// Which view to open on launch (clap arg).
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ViewArg {
    Fred,
    Perri,
    All,
}
