//! Scrollback ring buffer for daemon-owned PTYs.
//!
//! Stores raw terminal byte chunks in a `VecDeque<Vec<u8>>`, bounded by:
//! - **Total bytes** ≤ `MAX_BYTES` (2 MiB)
//! - **Newline count** ≤ `MAX_NEWLINES` (10 000)
//!
//! When either limit is exceeded, old chunks are discarded from the front until
//! the buffer is back within bounds.
//!
//! On [`ScrollbackBuf::drain`] the entire buffer is concatenated into a single
//! `Vec<u8>` suitable for transmission as a `PtyScrollback` frame.

use std::collections::VecDeque;

/// Maximum total byte budget.
pub const MAX_BYTES: usize = 2 * 1024 * 1024; // 2 MiB

/// Maximum number of newline characters tracked.
pub const MAX_NEWLINES: usize = 10_000;

/// Bounded ring buffer of raw PTY output chunks.
#[derive(Default)]
pub struct ScrollbackBuf {
    chunks: VecDeque<Vec<u8>>,
    total_bytes: usize,
    total_newlines: usize,
}

impl ScrollbackBuf {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append `data` to the buffer, evicting old chunks if necessary.
    pub fn push(&mut self, data: Vec<u8>) {
        let new_bytes = data.len();
        let new_newlines = data.iter().filter(|&&b| b == b'\n').count();

        self.total_bytes += new_bytes;
        self.total_newlines += new_newlines;
        self.chunks.push_back(data);

        // Evict from front until within budget.
        while (self.total_bytes > MAX_BYTES || self.total_newlines > MAX_NEWLINES)
            && !self.chunks.is_empty()
        {
            if let Some(front) = self.chunks.pop_front() {
                let front_newlines = front.iter().filter(|&&b| b == b'\n').count();
                self.total_bytes = self.total_bytes.saturating_sub(front.len());
                self.total_newlines = self.total_newlines.saturating_sub(front_newlines);
            }
        }
    }

    /// Concatenate all buffered chunks into a single `Vec<u8>`.
    pub fn drain(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.total_bytes);
        for chunk in &self.chunks {
            out.extend_from_slice(chunk);
        }
        out
    }

    /// Current total byte count in the buffer.
    pub fn byte_len(&self) -> usize {
        self.total_bytes
    }

    /// Current tracked newline count.
    pub fn newline_count(&self) -> usize {
        self.total_newlines
    }

    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_drain_basic() {
        let mut buf = ScrollbackBuf::new();
        buf.push(b"hello\nworld\n".to_vec());
        let out = buf.drain();
        assert_eq!(out, b"hello\nworld\n");
        assert_eq!(buf.newline_count(), 2);
    }

    #[test]
    fn bounds_bytes() {
        let mut buf = ScrollbackBuf::new();
        // Push 1 KiB chunks until we're way over 2 MiB.
        let chunk = vec![b'x'; 1024];
        for _ in 0..(MAX_BYTES / 1024 + 100) {
            buf.push(chunk.clone());
        }
        assert!(buf.byte_len() <= MAX_BYTES, "byte_len={}", buf.byte_len());
    }

    #[test]
    fn bounds_newlines() {
        let mut buf = ScrollbackBuf::new();
        // Each chunk has 100 newlines; push until well over 10k.
        let chunk = b"x\n".repeat(100);
        for _ in 0..(MAX_NEWLINES / 100 + 100) {
            buf.push(chunk.clone());
        }
        assert!(
            buf.newline_count() <= MAX_NEWLINES,
            "newlines={}",
            buf.newline_count()
        );
    }
}
