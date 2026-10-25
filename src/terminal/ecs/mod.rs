//! The remote-shell vocabulary: which projects, environments, services and
//! shell types exist, read from the carefeed layer's ECS data.
//!
//! The daemon reads that data itself, as data: `config.json` (clusters,
//! services, regions, shell commands), `ecs-local.json` (the user's profile
//! names) and the three alias tables in `ecs.sh`, which is scanned as **text**
//! and never sourced or run (T-2a-1). Nothing here talks to AWS or starts a
//! process. See [`vocab`].

pub mod vocab;

#[cfg(test)]
mod tests;

pub use vocab::{
    EcsPaths, EcsTarget, EcsVocabulary, InvalidTarget, TargetField, VocabError, CONFIGURE_ME,
};
