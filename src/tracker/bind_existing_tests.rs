//! `TrackerRegistry::bind_existing`: a resumed conversation's new tag takes
//! over the board file its old focus had, and never creates one.

use super::*;
use crate::tracker::clock::FakeClock;
use tempfile::TempDir;

struct Rig {
    _tmp: TempDir,
    reg: TrackerRegistry,
    repo: PathBuf,
}

impl Rig {
    fn new() -> Rig {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let (repo, home) = (base.join("repo"), base.join("home"));
        // A git checkout: the board's root is found from the board's own path.
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let reg = TrackerRegistry::new(RegistryParts::hermetic(
            base.join("state"),
            home,
            Arc::new(FakeClock::at_secs(1_760_540_000)),
        ));
        Rig {
            _tmp: tmp,
            reg,
            repo,
        }
    }

    /// A board opened by `tag`; its file's path.
    fn open_board(&self, tag: &str) -> PathBuf {
        let args = OpenArgs {
            topic: Some("work".into()),
            cwd: self.repo.clone(),
            ..Default::default()
        };
        self.reg.open(tag, "sess", &args).expect("open").path
    }
}

#[test]
fn a_new_tag_is_bound_to_the_board_the_old_focus_had() {
    let r = Rig::new();
    let path = r.open_board("old-tag");
    assert!(r.reg.bind_existing("new-tag", &path));
    assert_eq!(r.reg.bound_path("new-tag").as_deref(), Some(path.as_path()));
    assert!(r.reg.has_bound_board("new-tag"));
}

#[test]
fn a_board_that_is_gone_binds_nothing_and_is_not_created() {
    let r = Rig::new();
    let path = r.open_board("old-tag");
    std::fs::remove_file(&path).unwrap();
    assert!(!r.reg.bind_existing("new-tag", &path));
    assert!(r.reg.bound_path("new-tag").is_none());
    assert!(!path.exists(), "binding must never create the board");
}

#[test]
fn binding_leaves_the_board_file_byte_identical() {
    let r = Rig::new();
    let path = r.open_board("old-tag");
    let before = std::fs::read(&path).unwrap();
    assert!(r.reg.bind_existing("new-tag", &path));
    assert_eq!(std::fs::read(&path).unwrap(), before);
}
