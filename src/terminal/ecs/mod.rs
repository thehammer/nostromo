//! The remote-shell vocabulary: which projects, environments, services and
//! shell types exist, read from the carefeed layer's ECS data.
//!
//! The daemon reads that data itself, as data: `config.json` (clusters,
//! services, regions, shell commands), `ecs-local.json` (the user's profile
//! names) and the three alias tables in `ecs.sh`, which is scanned as **text**
//! and never sourced or run (T-2a-1). [`vocab`] talks to no one and starts no
//! process.
//!
//! Opening the shell is [`connect`] (the launcher), with [`aws`] (the CLI,
//! never through a shell), [`classify`] (argv and failure reasons, all pure)
//! and [`watch`] (what the daemon notices in the session's output).

pub mod aws;
pub(crate) mod classify;
pub(crate) mod connect;
pub mod vocab;
pub(crate) mod watch;

#[cfg(test)]
mod connect_tests;
#[cfg(test)]
mod tests;

pub use connect::AwsEcsLauncher;
pub use vocab::{
    EcsPaths, EcsTarget, EcsVocabulary, InvalidTarget, TargetField, VocabError, CONFIGURE_ME,
};
