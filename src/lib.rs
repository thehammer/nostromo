//! Library crate: the daemon, bridge and hook library behind `nostromd`,
//! `nostromo-mcp-bridge`, `nostromo-activity-hook` and `nostromo-guard`.

pub mod activity;
pub mod agent_bus;
pub mod approvals;
pub mod mdns;
pub mod config;
pub mod data;
pub mod event;
pub mod ipc;
pub mod markdown_blocks;
pub mod mcp;
pub mod model;
pub mod mother;
pub mod perri_cli;
pub mod pty;
pub mod sensitive_text;
pub mod tracker;
