//! Is a command word the tmux binary, whatever it is called?
//!
//! `ln -s $(which tmux) /tmp/t` makes `/tmp/t send-keys …` a tmux call that
//! the word `tmux` never appears in. This module answers from the word alone,
//! without running anything: by the name (a glob or an expansion that could
//! be `tmux`), and by the file the word names (symlinks and hard links
//! followed, globs expanded against the file system within a cap) compared
//! with the real tmux binary.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use super::expand::{brace_alternatives, glob_match};
use super::shell::{Word, WILDCARD};

/// Where tmux is installed. The guard's own probes use the first that exists.
pub const TMUX_INSTALL_PATHS: &[&str] = &[
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/usr/bin/tmux",
    "/opt/local/bin/tmux",
    "/run/current-system/sw/bin/tmux",
];

/// Most files one glob may match before the guard stops looking and says "could be tmux".
const MAX_GLOB_RESULTS: usize = 64;

/// Most directory entries read per glob component.
const MAX_DIR_ENTRIES: usize = 20_000;

/// Could `word`, used as a command (`command_position`) or as any argument
/// that names a path, be the tmux binary?
pub fn looks_like_tmux(word: &Word, cwd: &Path, command_position: bool) -> bool {
    // Past the brace cap nothing can be said: count it.
    let Some(candidates) = brace_alternatives(&word.pattern) else {
        return true;
    };
    candidates
        .iter()
        .any(|c| name_could_be_tmux(c) || resolves_to_tmux(c, cwd, command_position))
}

fn has_glob(s: &str) -> bool {
    s.contains(['*', '?', '['])
}

/// The last path component of `pattern` is `tmux`, or a glob / pattern that
/// can be it (with at least two literal characters, so `*` alone doesn't count).
fn name_could_be_tmux(pattern: &str) -> bool {
    let name = pattern.rsplit('/').next().unwrap_or(pattern);
    if !has_glob(name) && !name.contains(WILDCARD) {
        return name.eq_ignore_ascii_case("tmux");
    }
    let literal = name
        .chars()
        .filter(|c| !matches!(c, '*' | '?' | '[' | ']') && *c != WILDCARD)
        .count();
    literal >= 2 && glob_match(name, "tmux")
}

/// `pattern` names a file that is the real tmux (or, for a glob, too many
/// files to tell).
fn resolves_to_tmux(pattern: &str, cwd: &Path, command_position: bool) -> bool {
    if pattern.contains(WILDCARD) {
        return false;
    }
    let paths = if has_glob(pattern) {
        match glob_paths(pattern, cwd) {
            Some(paths) => paths,
            None => return true,
        }
    } else if pattern.contains('/') {
        vec![absolute(pattern, cwd)]
    } else if command_position {
        on_path(pattern).into_iter().collect()
    } else {
        Vec::new()
    };
    let ids = tmux_ids();
    paths
        .iter()
        .any(|p| file_id(p).is_some_and(|id| ids.contains(&id)))
}

fn absolute(path: &str, cwd: &Path) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        cwd.join(p)
    }
}

/// `(device, inode)` of what `path` names, symlinks followed.
fn file_id(path: &Path) -> Option<(u64, u64)> {
    let m = std::fs::metadata(path).ok()?;
    m.is_file().then(|| (m.dev(), m.ino()))
}

/// The first executable called `name` on this process's `PATH`.
fn on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
}

/// The real tmux binaries: the install locations and `tmux` on `PATH`.
fn tmux_ids() -> &'static Vec<(u64, u64)> {
    static IDS: OnceLock<Vec<(u64, u64)>> = OnceLock::new();
    IDS.get_or_init(|| {
        TMUX_INSTALL_PATHS
            .iter()
            .map(PathBuf::from)
            .chain(on_path("tmux"))
            .filter_map(|p| file_id(&p))
            .collect()
    })
}

/// The files `pattern` matches, `None` past the caps.
fn glob_paths(pattern: &str, cwd: &Path) -> Option<Vec<PathBuf>> {
    let mut bases = vec![if pattern.starts_with('/') {
        PathBuf::from("/")
    } else {
        cwd.to_path_buf()
    }];
    for component in pattern.split('/').filter(|c| !c.is_empty() && *c != ".") {
        let mut next = Vec::new();
        for base in &bases {
            if !has_glob(component) {
                next.push(base.join(component));
                continue;
            }
            let Ok(entries) = std::fs::read_dir(base) else {
                continue;
            };
            for (seen, entry) in entries.flatten().enumerate() {
                if seen >= MAX_DIR_ENTRIES {
                    return None;
                }
                if entry
                    .file_name()
                    .to_str()
                    .is_some_and(|n| glob_match(component, n))
                {
                    next.push(entry.path());
                    if next.len() > MAX_GLOB_RESULTS {
                        return None;
                    }
                }
            }
        }
        bases = next;
    }
    Some(bases)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str) -> Word {
        Word {
            text: text.to_owned(),
            span: 0..0,
            dynamic: false,
            pattern: text.to_owned(),
        }
    }

    #[test]
    fn names_that_can_be_tmux() {
        for name in [
            "tmux",
            "TMUX",
            "/usr/bin/tmux",
            "tm[u]x",
            "t?ux",
            "tmu?",
            "tm*",
            "./t?ux",
            "tm{u,u}x",
        ] {
            assert!(looks_like_tmux(&word(name), Path::new("/"), true), "{name}");
        }
        let wild = Word {
            pattern: format!("tm{WILDCARD}ux"),
            ..word("tm$Uux")
        };
        assert!(looks_like_tmux(&wild, Path::new("/"), true));
        for name in ["ls", "cargo", "t*", "*", "git", "x?y", "/bin/echo"] {
            assert!(
                !looks_like_tmux(&word(name), Path::new("/"), false),
                "{name}"
            );
        }
    }
}
