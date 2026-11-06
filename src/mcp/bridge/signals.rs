//! Record the signal that ends the bridge.
//!
//! A bridge that exits on its own logs why (`stdin_closed` and friends). One
//! that its CLI kills (Claude Code stops a stdio MCP server with a signal) used
//! to leave nothing behind, so a session that lost its `mcp__nostromo__*`
//! tools could not be told apart from one whose bridge never logged at all.
//! [`install`] makes SIGTERM, SIGHUP and SIGINT append
//! `pty=<id> event=signal_<n>` to the bridge log (no timestamp: only
//! async-signal-safe calls are allowed in the handler; the file's mtime is the
//! time) and then die of the same signal as before. SIGKILL cannot be caught.

use std::os::fd::IntoRawFd;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::OnceLock;

const SIGNALS: [libc::c_int; 3] = [libc::SIGTERM, libc::SIGHUP, libc::SIGINT];

static LOG_FD: AtomicI32 = AtomicI32::new(-1);
static PREFIX: OnceLock<Box<[u8]>> = OnceLock::new();

/// Install the handlers, writing to a duplicate of `log`'s descriptor. Call
/// once; later calls do nothing.
pub fn install(log: &std::fs::File, pty_id: &str) {
    if PREFIX.get().is_some() {
        return;
    }
    let Ok(dup) = log.try_clone() else {
        return;
    };
    let prefix = format!("pty={pty_id} event=signal_")
        .into_bytes()
        .into_boxed_slice();
    if PREFIX.set(prefix).is_err() {
        return;
    }
    LOG_FD.store(dup.into_raw_fd(), Ordering::SeqCst);
    for sig in SIGNALS {
        // SAFETY: `on_signal` only calls async-signal-safe functions
        // (`write`, `signal`, `raise`) and reads statics set before this point.
        unsafe {
            libc::signal(
                sig,
                on_signal as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
            );
        }
    }
}

/// `sig` as decimal digits and a newline, without allocating (the handler's tail).
fn digits(sig: libc::c_int) -> ([u8; 12], usize) {
    let mut buf = [0u8; 12];
    let mut n = sig.unsigned_abs();
    let mut tmp = [0u8; 10];
    let mut i = 0;
    loop {
        tmp[i] = b'0' + (n % 10) as u8;
        i += 1;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    let mut len = 0;
    while i > 0 {
        i -= 1;
        buf[len] = tmp[i];
        len += 1;
    }
    buf[len] = b'\n';
    (buf, len + 1)
}

extern "C" fn on_signal(sig: libc::c_int) {
    let fd = LOG_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        if let Some(prefix) = PREFIX.get() {
            let (tail, tail_len) = digits(sig);
            // SAFETY: plain writes of initialised buffers to an owned fd.
            unsafe {
                libc::write(fd, prefix.as_ptr().cast(), prefix.len());
                libc::write(fd, tail.as_ptr().cast(), tail_len);
            }
        }
    }
    // SAFETY: restore the default action and re-raise so the exit status is
    // the same as without the handler.
    unsafe {
        libc::signal(sig, libc::SIG_DFL);
        libc::raise(sig);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signal_numbers_are_written_as_decimal_lines() {
        let (buf, len) = digits(15);
        assert_eq!(&buf[..len], b"15\n");
        let (buf, len) = digits(1);
        assert_eq!(&buf[..len], b"1\n");
        let (buf, len) = digits(2_147_483_647);
        assert_eq!(&buf[..len], b"2147483647\n");
    }
}
