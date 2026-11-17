//! A private, Mac-only history of the conversations Nostromo focuses started.
//!
//! Distinct from `mother::origin::SessionHistory` (an authority record for
//! Mother job origins, ids only). This one holds what the Resume tab lists:
//! title, label, agent, project, branch, model, PR numbers, one first-prompt
//! line (never for a sensitive conversation or one the sensitive-text guard
//! flags) and what is needed to find and resume the conversation.
//!
//! Nothing here is logged (ids and fixed words only), sent to a network or
//! non-operator peer, or reachable by an MCP tool.

pub mod backfill;
pub mod first_prompt;
pub mod list;
pub mod outside;
pub mod store;
pub mod transcript;

#[cfg(test)]
mod outside_tests;

pub use first_prompt::{FirstPrompt, Reason};
pub use store::{ConversationEntry, ConversationHistory};

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The folder name under the home directory that holds every no-codebase
/// focus's private folder. Outside `~/.nostromo` (the daemon's own state, which
/// an agent must never work next to). The Mac names the same default.
pub const SPACES_DIR_NAME: &str = ".nostromo-spaces";

/// The environment variable that moves the spaces root (tests and the QA instance).
pub const SPACES_ROOT_ENV: &str = "NOSTROMO_SPACES_ROOT";

/// Set to `1` only by the QA launcher (and tests). The only mode in which
/// `NOSTROMO_SPACES_ROOT` is honoured: an installed daemon ignores a stray one.
const QA_DAEMON_ENV: &str = "NOSTROMO_QA_DAEMON";

/// Where no-codebase folders live: `~/.nostromo-spaces`, or
/// `NOSTROMO_SPACES_ROOT` when set and non-empty AND the daemon runs in QA mode
/// (`NOSTROMO_QA_DAEMON=1`). `None` when neither can be resolved.
pub fn spaces_root() -> Option<std::path::PathBuf> {
    spaces_root_with(|k| std::env::var_os(k))
}

/// The rule behind [`spaces_root`], with the environment injected.
pub fn spaces_root_with(
    env: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> Option<std::path::PathBuf> {
    let qa = env(QA_DAEMON_ENV).is_some_and(|v| v == "1");
    if qa {
        if let Some(v) = env(SPACES_ROOT_ENV).filter(|v| !v.is_empty()) {
            return Some(std::path::PathBuf::from(v));
        }
    }
    let home = env("HOME").filter(|v| !v.is_empty())?;
    Some(std::path::PathBuf::from(home).join(SPACES_DIR_NAME))
}

/// The spaces root as the app should compare it: canonical when it exists,
/// else as configured. Sent with the history so the app can refuse to sweep a
/// root other than its own.
pub fn spaces_root_for_wire() -> Option<String> {
    let root = spaces_root()?;
    let resolved = std::fs::canonicalize(&root).unwrap_or(root);
    Some(resolved.to_string_lossy().into_owned())
}

/// Is `path` a direct child of the spaces root? Decided by file identity (device
/// and inode of the root and of the path's parent, both followed through
/// symlinks, `..` and case folding), never by spelling alone. A raw-text match is
/// kept as a second way in: it can only add folders, never drop one, so the
/// answer errs toward "in use".
pub fn is_direct_space_child(path: &str) -> bool {
    spaces_root().is_some_and(|root| is_direct_space_child_of(&root, path))
}

/// A file's identity: device and inode.
#[derive(Clone, Copy, Debug)]
struct FileId {
    dev: u64,
    ino: u64,
}

impl FileId {
    fn of(m: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;
        Self {
            dev: m.dev(),
            ino: m.ino(),
        }
    }

    /// The same file only when device AND inode both match (inodes repeat across volumes).
    fn is_same_file(&self, other: &FileId) -> bool {
        self.dev == other.dev && self.ino == other.ino
    }
}

/// [`is_direct_space_child`] for an explicit root.
fn is_direct_space_child_of(root: &std::path::Path, path: &str) -> bool {
    let p = std::path::Path::new(path);
    let named = p
        .file_name()
        .is_some_and(|n| n != "." && n != ".." && !n.is_empty());
    let Some(parent) = p.parent().filter(|_| named) else {
        return false;
    };
    if parent == root {
        return true;
    }
    match (std::fs::metadata(root), std::fs::metadata(parent)) {
        (Ok(r), Ok(q)) => FileId::of(&r).is_same_file(&FileId::of(&q)),
        _ => false,
    }
}

/// What to tell the app about one history entry's folder, always erring toward
/// "in use". An entry whose parent is the root (by file identity) is named by its
/// resolved path. For a `no_codebase` entry that is not, two more things are
/// named, because its folder may still be sitting under the root behind a path
/// that no longer resolves (a symlink since removed or re-pointed):
/// the stored path as raw text when its parent cannot be read (the app then
/// resolves it itself and, failing that, declines the whole sweep), and the
/// root's child of the same UUID leaf. Other entries (repo worktrees) are not
/// held to this, so a deleted worktree never blocks the sweep.
pub fn space_folders_named_by(path: &str, no_codebase: bool) -> Vec<String> {
    match spaces_root() {
        Some(root) => space_folders_named_by_in(&root, path, no_codebase),
        None => Vec::new(),
    }
}

fn space_folders_named_by_in(root: &std::path::Path, path: &str, no_codebase: bool) -> Vec<String> {
    if is_direct_space_child_of(root, path) {
        return vec![space_folder_wire_name(path)];
    }
    if !no_codebase {
        return Vec::new();
    }
    let p = std::path::Path::new(path);
    let mut out = Vec::new();
    if p.parent().is_none_or(|d| std::fs::metadata(d).is_err()) {
        out.push(path.to_owned());
    }
    if let Some(leaf) = p.file_name().filter(|n| is_uuid_name(n)) {
        out.push(space_folder_wire_name(&root.join(leaf).to_string_lossy()));
    }
    out
}

/// The name the app is given for a folder the history uses: its parent resolved
/// with `canonicalize`, plus the leaf as stored; the raw text when the parent
/// cannot be resolved. The app then resolves that text itself: if it cannot
/// either, it declines the whole sweep, but if the text happens to name a folder
/// there (or names none under a parent that resolves) the app decides from that.
pub fn space_folder_wire_name(path: &str) -> String {
    let p = std::path::Path::new(path);
    match (
        p.parent().and_then(|d| std::fs::canonicalize(d).ok()),
        p.file_name(),
    ) {
        (Some(dir), Some(name)) => dir.join(name).to_string_lossy().into_owned(),
        _ => path.to_owned(),
    }
}

/// The hyphenated 36-character form the app names its folders with.
fn is_uuid_name(name: &std::ffi::OsStr) -> bool {
    name.to_str()
        .is_some_and(|n| n.len() == 36 && uuid::Uuid::parse_str(n).is_ok())
}

/// A folder a no-codebase resume may be placed in, validated on every use: a
/// direct child of the spaces root, named by a UUID, that exists, is a real
/// directory (never a symlink), is empty, has mode 0700 and belongs to the
/// daemon's own user; under a root that is itself a real directory (not a
/// symlink) owned by that user.
pub fn usable_space_folder(path: &str) -> bool {
    let Some(root) = spaces_root() else {
        return false;
    };
    // SAFETY: geteuid has no preconditions and cannot fail.
    let me = unsafe { libc::geteuid() };
    usable_space_folder_in(&root, path, me, me)
}

/// [`usable_space_folder`] for an explicit root and the user ids the root and the folder must belong to
/// (both the daemon's own; separate so a test can stand in for a foreign owner of either).
fn usable_space_folder_in(
    root: &std::path::Path,
    path: &str,
    root_owner: u32,
    folder_owner: u32,
) -> bool {
    use std::os::unix::fs::MetadataExt;
    let p = std::path::Path::new(path);
    if p.parent() != Some(root) || !p.file_name().is_some_and(is_uuid_name) {
        return false;
    }
    match std::fs::symlink_metadata(root) {
        Ok(m) if m.file_type().is_dir() && m.uid() == root_owner => {}
        _ => return false,
    }
    match std::fs::symlink_metadata(p) {
        Ok(m) if m.file_type().is_dir() && m.uid() == folder_owner && m.mode() & 0o777 == 0o700 => {
        }
        _ => return false,
    }
    std::fs::read_dir(p).is_ok_and(|mut d| d.next().is_none())
}

/// The longest title a user may give a conversation (the same as a focus label).
pub const MAX_TITLE_CHARS: usize = 60;

/// A user's title as stored: one line, with control, bidi, zero-width and
/// line-separator characters dropped, whitespace runs collapsed, cut at
/// [`MAX_TITLE_CHARS`] and trimmed again; `None` when nothing is left (which
/// clears the title).
pub fn normalized_title(raw: Option<&str>) -> Option<String> {
    let line = crate::data::work::untrusted::one_line(raw?, usize::MAX);
    let capped: String = line.chars().take(MAX_TITLE_CHARS).collect();
    let capped = capped.trim();
    (!capped.is_empty()).then(|| capped.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_loses_every_invisible_class_and_stays_on_one_line() {
        let classes: [(&str, &str); 8] = [
            ("control", "A\u{1}B\u{7f}C"),
            (
                "bidi override",
                "A\u{202A}B\u{202B}C\u{202C}\u{202D}\u{202E}",
            ),
            ("bidi isolate", "A\u{2066}B\u{2067}C\u{2068}\u{2069}"),
            ("direction mark", "A\u{200E}B\u{200F}C"),
            ("zero width", "A\u{200B}B\u{200C}C\u{200D}\u{FEFF}"),
            ("line separator", "A\u{2028}B\u{2029}C"),
            ("newline", "A\nB\r\nC"),
            ("tab", "A\tB\tC"),
        ];
        for (name, raw) in classes {
            let got = normalized_title(Some(raw)).unwrap();
            let visible: String = got.chars().filter(|c| !c.is_whitespace()).collect();
            assert_eq!(visible, "ABC", "{name}: {got:?}");
            assert!(
                got.chars()
                    .all(|c| !c.is_control() && !crate::data::work::untrusted::is_invisible(c)),
                "{name}: {got:?}"
            );
            assert!(!got.contains('\n'), "{name}");
        }
        assert_eq!(normalized_title(Some("\u{200B}\u{202E}\n")), None);
    }

    #[test]
    fn a_title_is_cut_after_cleaning_not_before() {
        let raw = format!("\u{200B}{}", "x".repeat(80));
        assert_eq!(normalized_title(Some(&raw)).unwrap().chars().count(), 60);
    }

    #[test]
    fn the_default_spaces_root_is_dot_nostromo_spaces_under_home() {
        // The Mac names the same default (NoCodebaseFolder.defaultDirectoryName).
        assert_eq!(SPACES_DIR_NAME, ".nostromo-spaces");
        let env = |k: &str| match k {
            "HOME" => Some("/home/u".into()),
            _ => None,
        };
        assert_eq!(
            spaces_root_with(env),
            Some(std::path::PathBuf::from("/home/u/.nostromo-spaces"))
        );
    }

    #[test]
    fn a_stray_spaces_root_variable_is_ignored_unless_the_daemon_is_a_qa_one() {
        let env = |qa: Option<&'static str>| {
            move |k: &str| match k {
                "HOME" => Some("/home/u".into()),
                "NOSTROMO_SPACES_ROOT" => Some("/elsewhere".into()),
                "NOSTROMO_QA_DAEMON" => qa.map(Into::into),
                _ => None,
            }
        };
        let home = Some(std::path::PathBuf::from("/home/u/.nostromo-spaces"));
        assert_eq!(spaces_root_with(env(None)), home, "real daemon");
        assert_eq!(spaces_root_with(env(Some("0"))), home, "QA flag off");
        assert_eq!(
            spaces_root_with(env(Some("1"))),
            Some(std::path::PathBuf::from("/elsewhere")),
            "QA daemon"
        );
    }

    mod usable {
        use super::super::usable_space_folder_in;
        use std::os::unix::fs::PermissionsExt;
        use std::path::{Path, PathBuf};

        const NAME: &str = "11111111-2222-4333-8444-555555555555";

        struct Spaces {
            _t: tempfile::TempDir,
            root: PathBuf,
            me: u32,
        }

        fn spaces() -> Spaces {
            let t = tempfile::tempdir().unwrap();
            let root = t.path().join("spaces");
            std::fs::create_dir(&root).unwrap();
            // The files really belong to whoever runs the test: stand in for "me".
            let me = std::fs::metadata(&root)
                .map(|m| std::os::unix::fs::MetadataExt::uid(&m))
                .unwrap();
            Spaces { _t: t, root, me }
        }

        fn make(root: &Path, name: &str, mode: u32) -> String {
            let p = root.join(name);
            std::fs::create_dir(&p).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(mode)).unwrap();
            p.to_string_lossy().into_owned()
        }

        #[test]
        fn a_uuid_named_empty_0700_folder_of_mine_under_a_real_root_is_usable() {
            let s = spaces();
            let f = make(&s.root, NAME, 0o700);
            assert!(usable_space_folder_in(&s.root, &f, s.me, s.me));
        }

        #[test]
        fn a_name_that_is_not_a_hyphenated_uuid_is_refused() {
            let s = spaces();
            for name in [
                "space-one",
                "11111111222243338444555555555555",
                "{11111111-2222-4333-8444-555555555555}",
            ] {
                let f = make(&s.root, name, 0o700);
                assert!(!usable_space_folder_in(&s.root, &f, s.me, s.me), "{name}");
            }
        }

        #[test]
        fn a_mode_other_than_0700_is_refused() {
            let s = spaces();
            for (i, mode) in [0o755, 0o750, 0o770, 0o500, 0o600].into_iter().enumerate() {
                let name = format!("11111111-2222-4333-8444-55555555555{i}");
                let f = make(&s.root, &name, mode);
                assert!(!usable_space_folder_in(&s.root, &f, s.me, s.me), "{mode:o}");
            }
        }

        #[test]
        fn a_folder_owned_by_someone_else_is_refused() {
            let s = spaces();
            let f = make(&s.root, NAME, 0o700);
            assert!(usable_space_folder_in(&s.root, &f, s.me, s.me));
            assert!(
                !usable_space_folder_in(&s.root, &f, s.me, s.me + 1),
                "folder owner"
            );
            assert!(
                !usable_space_folder_in(&s.root, &f, s.me + 1, s.me),
                "root owner"
            );
        }

        #[test]
        fn a_symlinked_root_is_refused() {
            let s = spaces();
            let real = s._t.path().join("real");
            std::fs::create_dir(&real).unwrap();
            let f_real = make(&real, NAME, 0o700);
            let link = s._t.path().join("link");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            let via_link = link.join(NAME).to_string_lossy().into_owned();
            assert!(usable_space_folder_in(&real, &f_real, s.me, s.me));
            assert!(!usable_space_folder_in(&link, &via_link, s.me, s.me));
        }

        #[test]
        fn a_symlinked_folder_a_file_and_a_non_empty_folder_are_refused() {
            let s = spaces();
            let target = make(&s.root, "aaaaaaaa-2222-4333-8444-555555555555", 0o700);
            let link = s.root.join(NAME);
            std::os::unix::fs::symlink(&target, &link).unwrap();
            assert!(!usable_space_folder_in(
                &s.root,
                link.to_str().unwrap(),
                s.me,
                s.me
            ));
            let file = s.root.join("bbbbbbbb-2222-4333-8444-555555555555");
            std::fs::write(&file, "x").unwrap();
            assert!(!usable_space_folder_in(
                &s.root,
                file.to_str().unwrap(),
                s.me,
                s.me
            ));
            let full = make(&s.root, "cccccccc-2222-4333-8444-555555555555", 0o700);
            std::fs::write(Path::new(&full).join("f"), "x").unwrap();
            assert!(!usable_space_folder_in(&s.root, &full, s.me, s.me));
        }

        #[test]
        fn a_folder_that_is_not_a_direct_child_is_refused() {
            let s = spaces();
            let group = make(&s.root, "group", 0o700);
            let nested = make(Path::new(&group), NAME, 0o700);
            assert!(!usable_space_folder_in(&s.root, &nested, s.me, s.me));
        }
    }
}

#[cfg(test)]
mod in_use_by_identity {
    use super::*;
    use std::os::unix::fs::symlink;

    const NAME: &str = "aaaaaaaa-1111-4222-8333-444444444444";

    /// A real root with one folder in it, in a temp dir.
    fn rig() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(dir.path()).unwrap();
        let root = base.join("spaces");
        std::fs::create_dir_all(root.join(NAME)).unwrap();
        (dir, base, root)
    }

    fn named(root: &std::path::Path, path: &std::path::Path) -> bool {
        is_direct_space_child_of(root, path.to_str().unwrap())
    }

    #[test]
    fn a_daemon_root_left_as_a_symlink_still_names_a_folder_stored_by_its_real_path() {
        let (_d, base, real_root) = rig();
        let link = base.join("home-link");
        symlink(&real_root, &link).unwrap();
        // The daemon's unresolved root is the link; the history stored the real path.
        assert!(named(&link, &real_root.join(NAME)));
        // And the other way round: root by real path, folder stored through the link.
        assert!(named(&real_root, &link.join(NAME)));
    }

    #[test]
    fn spellings_of_the_root_do_not_hide_a_folder() {
        let (_d, base, root) = rig();
        std::fs::create_dir_all(base.join("x")).unwrap();
        let folder = root.join(NAME);
        let root_s = root.to_str().unwrap();
        for spelled in [
            format!("{root_s}/"),
            format!("{}//spaces", base.display()),
            format!("{}/x/../spaces", base.display()),
        ] {
            assert!(
                is_direct_space_child_of(std::path::Path::new(&spelled), folder.to_str().unwrap()),
                "root spelled {spelled:?}"
            );
        }
        // The folder spelled oddly, against the plain root.
        for spelled in [
            format!("{root_s}//{NAME}"),
            format!("{}/x/../spaces/{NAME}", base.display()),
        ] {
            assert!(is_direct_space_child_of(&root, &spelled), "{spelled:?}");
        }
    }

    #[test]
    fn a_var_versus_private_var_pair_is_the_same_root() {
        let (_d, base, root) = rig();
        let alias = base.join("var");
        symlink(base.join("spaces"), &alias).unwrap(); // `/var` -> the real directory
        assert!(named(&alias, &root.join(NAME)));
        assert!(named(&root, &alias.join(NAME)));
    }

    #[test]
    fn a_case_difference_is_the_same_root_where_the_volume_ignores_case_and_a_symlink_stands_in_elsewhere(
    ) {
        let (_d, base, root) = rig();
        let upper = base.join("SPACES");
        if !upper.exists() {
            // Case-sensitive volume: simulate the aliasing with a link.
            symlink(&root, &upper).unwrap();
        }
        assert!(named(&upper, &root.join(NAME)));
        assert!(named(&root, &upper.join(NAME)));
    }

    #[test]
    fn a_folder_elsewhere_or_nested_or_the_root_itself_is_not_named() {
        let (_d, base, root) = rig();
        std::fs::create_dir_all(base.join("other").join(NAME)).unwrap();
        std::fs::create_dir_all(root.join("group").join(NAME)).unwrap();
        assert!(!named(&root, &base.join("other").join(NAME)));
        assert!(!named(&root, &root.join("group").join(NAME)));
        assert!(!named(&root, &root.join(NAME).join("..")));
        assert!(!named(&root, &root));
    }

    #[test]
    fn a_wire_name_resolves_the_parent_and_falls_back_to_the_raw_text() {
        let (_d, base, real_root) = rig();
        let link = base.join("home-link");
        symlink(&real_root, &link).unwrap();
        assert_eq!(
            space_folder_wire_name(link.join(NAME).to_str().unwrap()),
            real_root.join(NAME).to_str().unwrap()
        );
        let gone = base.join("no-such-dir").join(NAME);
        assert_eq!(
            space_folder_wire_name(gone.to_str().unwrap()),
            gone.to_str().unwrap()
        );
    }

    #[test]
    fn the_same_inode_on_another_device_is_not_the_same_file() {
        let a = FileId { dev: 1, ino: 42 };
        assert!(a.is_same_file(&FileId { dev: 1, ino: 42 }));
        assert!(!a.is_same_file(&FileId { dev: 2, ino: 42 }));
        assert!(!a.is_same_file(&FileId { dev: 1, ino: 43 }));
    }

    #[test]
    fn a_no_codebase_folder_stored_through_a_since_removed_symlink_is_still_named() {
        let (_d, base, root) = rig();
        let link = base.join("gone-link");
        symlink(&root, &link).unwrap();
        let stored = link.join(NAME).to_str().unwrap().to_owned();
        std::fs::remove_file(&link).unwrap();
        // The folder still exists under the root, but its stored path no longer resolves.
        assert!(!is_direct_space_child_of(&root, &stored));
        let named = space_folders_named_by_in(&root, &stored, true);
        assert!(
            named.contains(&stored),
            "raw text passed through: {named:?}"
        );
        assert!(
            named.contains(&root.join(NAME).to_str().unwrap().to_owned()),
            "the root's child of the same leaf: {named:?}"
        );
    }

    #[test]
    fn a_no_codebase_folder_stored_through_a_symlink_now_pointing_elsewhere_is_still_named() {
        let (_d, base, root) = rig();
        let elsewhere = base.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let link = base.join("moved-link");
        symlink(&root, &link).unwrap();
        let stored = link.join(NAME).to_str().unwrap().to_owned();
        std::fs::remove_file(&link).unwrap();
        symlink(&elsewhere, &link).unwrap();
        assert!(!is_direct_space_child_of(&root, &stored));
        let named = space_folders_named_by_in(&root, &stored, true);
        assert_eq!(named, vec![root.join(NAME).to_str().unwrap().to_owned()]);
    }

    #[test]
    fn an_entry_that_is_not_no_codebase_never_names_a_folder_it_cannot_resolve() {
        let (_d, base, root) = rig();
        let gone = base.join("deleted-worktree").join(NAME);
        assert!(space_folders_named_by_in(&root, gone.to_str().unwrap(), false).is_empty());
        // And a no-codebase entry whose leaf is not a folder of ours adds only the raw text.
        let other = base.join("deleted").join("not-a-uuid");
        assert_eq!(
            space_folders_named_by_in(&root, other.to_str().unwrap(), true),
            vec![other.to_str().unwrap().to_owned()]
        );
    }

    #[test]
    fn a_direct_child_is_named_once_by_its_resolved_path() {
        let (_d, _base, root) = rig();
        let p = root.join(NAME);
        assert_eq!(
            space_folders_named_by_in(&root, p.to_str().unwrap(), true),
            vec![p.to_str().unwrap().to_owned()]
        );
    }
}
