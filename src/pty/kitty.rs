//! Kitty keyboard protocol tracker and encoder for PTY streams.
//!
//! # Overview
//!
//! The [kitty keyboard protocol] allows terminal applications to push a bitmask
//! of enhancement flags onto a per-terminal stack.  When an inner PTY process
//! (e.g. Claude Code) writes a push escape, Nostromo's PTY layer must track the
//! stack so it can encode outgoing key events in kitty form — otherwise keys
//! like Enter arrive as `\r` rather than the `\x1b[13u` that Claude expects.
//!
//! # Sequences tracked
//!
//! | Sequence       | Meaning                                    |
//! |----------------|--------------------------------------------|
//! | `ESC[>Nu`      | Push flags `N` onto the stack              |
//! | `ESC[<u`       | Pop one level from the stack               |
//! | `ESC[=Nu`      | Replace top-of-stack with `N`              |
//! | `ESC[?u`       | Query — passed through, not consumed       |
//!
//! `N` is one or more ASCII decimal digits; empty means `0`.
//!
//! # Chunk boundaries
//!
//! PTY reads arrive in arbitrary chunks.  The tracker is incremental: a
//! [`KittyFlagsTracker`] instance carries leftover bytes that look like a
//! partial sequence prefix across calls.  Feed each chunk through
//! [`KittyFlagsTracker::feed`]; the tracker updates its internal stack and
//! mirrors the top to a shared [`AtomicU32`] that the writer side reads
//! lock-free.
//!
//! [kitty keyboard protocol]: https://sw.kovidgoyal.net/kitty/keyboard-protocol/

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

// ── KittyFlagsTracker ────────────────────────────────────────────────────────

/// Maximum length of a kitty flag escape we recognise.
///
/// The longest possible sequence is `\x1b[>4294967295u` = 18 bytes.  We cap
/// pending at this so we don't buffer unboundedly on a lone ESC.
const MAX_KITTY_SEQ: usize = 20;

/// Stateful tracker for kitty keyboard protocol push/pop/replace escapes in a
/// PTY byte stream.
///
/// Feed each PTY read chunk through [`KittyFlagsTracker::feed`].  The tracker
/// maintains an internal stack and mirrors the top-of-stack flags to a shared
/// [`AtomicU32`] that can be read from the writer thread without locking.
pub struct KittyFlagsTracker {
    /// Bytes from a previous chunk that might be the start of a kitty escape.
    pending: Vec<u8>,
    /// Flag stack: `push` appends, `pop` removes last, `replace` overwrites last.
    stack: Vec<u32>,
    /// Shared mirror of `stack.last()`.  `0` when stack is empty (= legacy mode).
    flags: Arc<AtomicU32>,
}

impl KittyFlagsTracker {
    pub fn new() -> Self {
        Self {
            pending: Vec::new(),
            stack: Vec::new(),
            flags: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Returns a cheap clone of the shared flags handle.
    ///
    /// The writer side calls `flags.load(Ordering::Relaxed)` to decide between
    /// legacy and kitty key encoding.
    pub fn flags(&self) -> Arc<AtomicU32> {
        Arc::clone(&self.flags)
    }

    /// Process one PTY read chunk.
    ///
    /// The chunk is passed through **unchanged** — the tracker only reads it to
    /// update the stack.  Call this before (or in parallel with) the vt100
    /// parser; vt100 will harmlessly ignore the kitty escapes.
    pub fn feed(&mut self, chunk: &[u8]) {
        // Merge pending prefix with new chunk for uniform processing.
        let mut buf = Vec::with_capacity(self.pending.len() + chunk.len());
        buf.extend_from_slice(&self.pending);
        buf.extend_from_slice(chunk);
        self.pending.clear();

        let mut i = 0;
        while i < buf.len() {
            // Fast path: not an ESC byte.
            if buf[i] != 0x1b {
                i += 1;
                continue;
            }

            let remaining = &buf[i..];

            // Need at least `\x1b[Xu` (4 bytes) to identify a kitty sequence.
            if remaining.len() < 2 {
                // Could be the start of any escape — save for next chunk.
                if remaining.len() <= MAX_KITTY_SEQ {
                    self.pending.extend_from_slice(remaining);
                }
                return;
            }

            if remaining[1] != b'[' {
                // Not CSI — skip this ESC byte.
                i += 1;
                continue;
            }

            if remaining.len() < 3 {
                // Have `\x1b[` but no discriminator byte yet.
                self.pending.extend_from_slice(remaining);
                return;
            }

            let discriminator = remaining[2];
            match discriminator {
                b'>' | b'<' | b'=' => {
                    // Try to find the terminating `u`.
                    match self.try_parse_kitty(remaining) {
                        ParseResult::Consumed(len) => {
                            i += len;
                        }
                        ParseResult::Partial => {
                            // Save and wait for more data.
                            if remaining.len() <= MAX_KITTY_SEQ {
                                self.pending.extend_from_slice(remaining);
                            }
                            return;
                        }
                        ParseResult::NotKitty => {
                            i += 1;
                        }
                    }
                }
                // `?` = query — pass through without consuming.
                _ => {
                    i += 1;
                }
            }
        }
    }

    /// Attempt to parse a kitty flag escape starting at `buf[0]`.
    ///
    /// `buf[0]` is `\x1b`, `buf[1]` is `[`, `buf[2]` is the discriminator.
    fn try_parse_kitty(&mut self, buf: &[u8]) -> ParseResult {
        debug_assert!(buf.len() >= 3);
        let discriminator = buf[2];

        // Collect digits starting at index 3.
        let mut j = 3;
        while j < buf.len() {
            let b = buf[j];
            if b.is_ascii_digit() {
                j += 1;
                if j - 3 > 10 {
                    // Implausibly long digit run — not a real kitty sequence.
                    return ParseResult::NotKitty;
                }
            } else if b == b'u' {
                // Found the terminator.
                let digit_slice = &buf[3..j];
                let n: u32 = if digit_slice.is_empty() {
                    0
                } else {
                    // Safe: slice is all ASCII digits.
                    let s = std::str::from_utf8(digit_slice).unwrap_or("0");
                    s.parse().unwrap_or(0)
                };

                match discriminator {
                    b'>' => self.push(n),
                    b'<' => self.pop(),
                    b'=' => self.replace(n),
                    _ => {}
                }
                return ParseResult::Consumed(j + 1);
            } else {
                // Non-digit, non-`u` — not a kitty sequence.
                return ParseResult::NotKitty;
            }
        }

        // Ran off the end of the buffer without finding `u` — partial.
        ParseResult::Partial
    }

    fn push(&mut self, n: u32) {
        self.stack.push(n);
        self.sync();
    }

    fn pop(&mut self) {
        self.stack.pop();
        self.sync();
    }

    fn replace(&mut self, n: u32) {
        if let Some(top) = self.stack.last_mut() {
            *top = n;
        } else {
            self.stack.push(n);
        }
        self.sync();
    }

    fn sync(&self) {
        let top = self.stack.last().copied().unwrap_or(0);
        self.flags.store(top, Ordering::Relaxed);
    }
}

impl Default for KittyFlagsTracker {
    fn default() -> Self {
        Self::new()
    }
}

enum ParseResult {
    /// Sequence fully parsed; consumed this many bytes.
    Consumed(usize),
    /// Sequence is a valid prefix but incomplete — need more data.
    Partial,
    /// Bytes don't form a kitty sequence; caller should skip `ESC`.
    NotKitty,
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── KittyFlagsTracker ────────────────────────────────────────────────────

    fn flags(tracker: &KittyFlagsTracker) -> u32 {
        tracker.flags.load(Ordering::Relaxed)
    }

    #[test]
    fn push_sets_flags() {
        let mut t = KittyFlagsTracker::new();
        t.feed(b"\x1b[>1u");
        assert_eq!(flags(&t), 1);
    }

    #[test]
    fn push_push_pop_pop() {
        let mut t = KittyFlagsTracker::new();
        t.feed(b"\x1b[>1u");
        assert_eq!(flags(&t), 1);
        t.feed(b"\x1b[>5u");
        assert_eq!(flags(&t), 5);
        t.feed(b"\x1b[<u");
        assert_eq!(flags(&t), 1);
        t.feed(b"\x1b[<u");
        assert_eq!(flags(&t), 0);
    }

    #[test]
    fn replace_empty_stack() {
        let mut t = KittyFlagsTracker::new();
        // Push 0 then replace with 7.
        t.feed(b"\x1b[>0u");
        assert_eq!(flags(&t), 0);
        t.feed(b"\x1b[=7u");
        assert_eq!(flags(&t), 7);
    }

    #[test]
    fn split_sequence_across_chunks() {
        let mut t = KittyFlagsTracker::new();
        t.feed(b"\x1b[>");
        assert_eq!(flags(&t), 0); // Not yet parsed.
        t.feed(b"1u");
        assert_eq!(flags(&t), 1);
    }

    #[test]
    fn non_kitty_escape_does_not_corrupt_state() {
        let mut t = KittyFlagsTracker::new();
        t.feed(b"\x1b[>1u");
        assert_eq!(flags(&t), 1);
        // SGR clear-screen — not a kitty sequence.
        t.feed(b"\x1b[2J");
        assert_eq!(flags(&t), 1);
    }

    #[test]
    fn empty_push_means_zero() {
        let mut t = KittyFlagsTracker::new();
        // `\x1b[>u` = push 0 (empty digits).
        t.feed(b"\x1b[>u");
        assert_eq!(flags(&t), 0);
        // After pop, back to 0.
        t.feed(b"\x1b[<u");
        assert_eq!(flags(&t), 0);
    }

    #[test]
    fn multiple_sequences_in_one_chunk() {
        let mut t = KittyFlagsTracker::new();
        t.feed(b"\x1b[>3u\x1b[>7u\x1b[<u");
        // Push 3, push 7, pop → top is 3.
        assert_eq!(flags(&t), 3);
    }
}
