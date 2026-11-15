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
pub mod store;
pub mod transcript;

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

/// Is `path` a direct child of the spaces root (lexically; no `..`)?
pub fn is_direct_space_child(path: &str) -> bool {
    let Some(root) = spaces_root() else {
        return false;
    };
    let p = std::path::Path::new(path);
    p.parent() == Some(root.as_path())
        && p.file_name()
            .is_some_and(|n| n != "." && n != ".." && !n.is_empty())
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
