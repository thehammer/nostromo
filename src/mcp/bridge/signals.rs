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
/// One complete log line per entry of [`SIGNALS`], built before any handler
/// is installed so the handler only has to `write` it in one call.
static LINES: OnceLock<[Box<[u8]>; 3]> = OnceLock::new();

/// The line logged when `sig` arrives.
fn line_for(pty_id: &str, sig: libc::c_int) -> Box<[u8]> {
    format!("pty={pty_id} event=signal_{sig}\n")
        .into_bytes()
        .into_boxed_slice()
}

/// `true` when `sig` is currently ignored (inherited `SIG_IGN`, e.g. under
/// `nohup`): such a signal is left alone, so the bridge does not start dying
/// of something its parent asked it to ignore.
fn is_ignored(sig: libc::c_int) -> bool {
    // SAFETY: a null new action only reads the current disposition into `old`.
    unsafe {
        let mut old: libc::sigaction = std::mem::zeroed();
        libc::sigaction(sig, std::ptr::null(), &mut old) == 0 && old.sa_sigaction == libc::SIG_IGN
    }
}

/// Install the handlers, writing to a duplicate of `log`'s descriptor. Call
/// once; later calls do nothing. Signals that are already ignored are skipped.
pub fn install(log: &std::fs::File, pty_id: &str) {
    if LINES.get().is_some() {
        return;
    }
    let Ok(dup) = log.try_clone() else {
        return;
    };
    let lines = SIGNALS.map(|sig| line_for(pty_id, sig));
    if LINES.set(lines).is_err() {
        return;
    }
    LOG_FD.store(dup.into_raw_fd(), Ordering::SeqCst);
    for sig in SIGNALS {
        if is_ignored(sig) {
            continue;
        }
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

extern "C" fn on_signal(sig: libc::c_int) {
    let fd = LOG_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        if let Some(lines) = LINES.get() {
            if let Some(i) = SIGNALS.iter().position(|&s| s == sig) {
                let line = &lines[i];
                // SAFETY: one write of an initialised buffer to an owned fd.
                unsafe {
                    libc::write(fd, line.as_ptr().cast(), line.len());
                }
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
    fn the_logged_line_names_the_pty_and_the_signal_number() {
        assert_eq!(
            &*line_for("careport-1", 15),
            b"pty=careport-1 event=signal_15\n"
        );
        assert_eq!(
            &*line_for("x", libc::SIGHUP),
            format!("pty=x event=signal_{}\n", libc::SIGHUP).as_bytes()
        );
    }

    #[test]
    fn a_signal_with_the_default_action_is_not_reported_as_ignored() {
        // SIGTERM's disposition is the default in the test process.
        assert!(!is_ignored(libc::SIGTERM));
    }
}
