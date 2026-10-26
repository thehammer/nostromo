//! Every on-disk location Huey uses, derived from one root: `<state root>/huey`.
//!
//! Building a `HueyPaths` touches nothing on disk. Directories are created by
//! whoever first needs to write (never by the engine just for starting).

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HueyPaths {
    root: PathBuf,
}

impl HueyPaths {
    /// `state_root` is the daemon's per-machine state directory (`~/.nostromo`,
    /// or a QA daemon's own).
    pub fn new(state_root: &Path) -> Self {
        Self {
            root: state_root.join("huey"),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn setup_json(&self) -> PathBuf {
        self.root.join("setup.json")
    }

    pub fn interests(&self) -> PathBuf {
        self.root.join("interests.md")
    }

    pub fn sources_toml(&self) -> PathBuf {
        self.root.join("sources.toml")
    }

    pub fn state_dir(&self) -> PathBuf {
        self.root.join("state")
    }

    pub fn pool_dir(&self) -> PathBuf {
        self.root.join("pool")
    }

    pub fn reports_dir(&self) -> PathBuf {
        self.root.join("reports")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn everything_sits_under_huey_in_the_state_root() {
        let p = HueyPaths::new(Path::new("/state"));
        assert_eq!(p.root(), Path::new("/state/huey"));
        for path in [
            p.setup_json(),
            p.interests(),
            p.sources_toml(),
            p.state_dir(),
            p.pool_dir(),
            p.reports_dir(),
        ] {
            assert!(path.starts_with("/state/huey"), "{path:?}");
        }
    }
}
