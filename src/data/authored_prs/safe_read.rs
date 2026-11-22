//! Bounded, non-blocking reads of small files that something else controls.
//!
//! Used for the `.git` files of a focus's checkout, whose `gitdir:` can point
//! anywhere on disk.

use std::io::Read;
use std::path::Path;

/// The most of any such file (`.git`, `HEAD`, `commondir`, `config`) that is read.
pub const MAX_GIT_FILE: u64 = 256 * 1024;

/// Read a small regular file as text, or `None`. Never blocks and never reads
/// without bound: the file is opened without following a final symlink and
/// without waiting on a FIFO (`O_NONBLOCK`) or adopting a terminal as the
/// controlling one (`O_NOCTTY`), and is used only if it is a regular
/// file no larger than [`MAX_GIT_FILE`]. A `HEAD` that is a FIFO, a device, a
/// symlink or a huge file reads as nothing.
pub fn read_small_file(path: &Path) -> Option<String> {
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_NOCTTY);
    }
    let file = opts.open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_GIT_FILE {
        return None;
    }
    let mut buf = Vec::new();
    file.take(MAX_GIT_FILE + 1).read_to_end(&mut buf).ok()?;
    if buf.len() as u64 > MAX_GIT_FILE {
        return None;
    }
    String::from_utf8(buf).ok()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    #[test]
    fn a_regular_file_is_read() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("HEAD");
        std::fs::write(&p, "ref: refs/heads/main\n").unwrap();
        assert_eq!(
            read_small_file(&p).as_deref(),
            Some("ref: refs/heads/main\n")
        );
    }

    #[test]
    fn a_fifo_is_refused_not_read_as_empty() {
        // With `O_NONBLOCK` alone the open succeeds and a read returns nothing, so
        // only the regular-file check tells "not a file" from "an empty file".
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("HEAD");
        let c = CString::new(p.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert_eq!(read_small_file(&p), None);
    }

    #[test]
    fn an_empty_regular_file_is_empty_text_not_none() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("HEAD");
        std::fs::write(&p, "").unwrap();
        assert_eq!(read_small_file(&p).as_deref(), Some(""));
    }

    #[test]
    fn a_symlink_and_an_oversized_file_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        std::fs::write(&real, "x").unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(read_small_file(&link), None);

        let big = dir.path().join("big");
        std::fs::write(&big, vec![b'a'; MAX_GIT_FILE as usize + 1]).unwrap();
        assert_eq!(read_small_file(&big), None);
    }
}
