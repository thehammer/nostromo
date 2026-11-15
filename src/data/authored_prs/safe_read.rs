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
/// without waiting on a FIFO (`O_NONBLOCK`), and is used only if it is a regular
/// file no larger than [`MAX_GIT_FILE`]. A `HEAD` that is a FIFO, a device, a
/// symlink or a huge file reads as nothing.
pub fn read_small_file(path: &Path) -> Option<String> {
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW);
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
