//! Filter that strips alt-screen enable/disable escape sequences from PTY
//! byte streams before they reach the vt100 parser.
//!
//! # Why
//!
//! `vt100`'s alternate screen grid is created with `scrollback_len = 0`.  Any
//! process (like the Claude TUI agent) that enters the alt screen gets no
//! scrollback history, so `Parser::set_scrollback(N)` becomes a no-op.
//!
//! By stripping the alt-screen switch sequences we keep all output on the
//! *main* screen, which has the configured 1000-row scrollback and therefore
//! supports the REPL scroll feature.  Absolute cursor positioning, clear-screen,
//! and colour sequences continue to work identically on the main screen.
//!
//! # Sequences stripped
//!
//! | Sequence       | Meaning                                         |
//! |----------------|-------------------------------------------------|
//! | `ESC[?1047h`   | Enter alt screen (DEC private mode 1047)        |
//! | `ESC[?1049h`   | Enter alt screen + save cursor (mode 1049)      |
//! | `ESC[?1047l`   | Exit alt screen                                 |
//! | `ESC[?1049l`   | Exit alt screen + restore cursor                |
//!
//! # Chunk boundaries
//!
//! PTY reads arrive in arbitrary chunks.  The filter is incremental: a
//! `AltScreenFilter` instance carries leftover bytes that look like a partial
//! sequence prefix across calls.

/// Maximum length of any alt-screen sequence we recognise (e.g. `\x1b[?1049h`
/// = 8 bytes).
const MAX_SEQ: usize = 8;

/// Alt-screen sequences to strip.
const STRIP: &[&[u8]] = &[
    b"\x1b[?1047h",
    b"\x1b[?1049h",
    b"\x1b[?1047l",
    b"\x1b[?1049l",
];

/// Stateful filter that strips alt-screen escape sequences from a PTY byte
/// stream.  Feed each chunk through [`AltScreenFilter::process`]; it returns
/// a `Vec<u8>` with the offending sequences removed.
#[derive(Default)]
pub struct AltScreenFilter {
    /// Bytes from a previous chunk that might be the start of a sequence.
    pending: Vec<u8>,
}

impl AltScreenFilter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Process one PTY read chunk.  Returns bytes safe to feed to vt100.
    pub fn process(&mut self, chunk: &[u8]) -> Vec<u8> {
        // Merge pending prefix with new chunk for uniform processing.
        let mut buf = Vec::with_capacity(self.pending.len() + chunk.len());
        buf.extend_from_slice(&self.pending);
        buf.extend_from_slice(chunk);
        self.pending.clear();

        let mut out = Vec::with_capacity(buf.len());
        let mut i = 0;

        while i < buf.len() {
            // Fast path: not an ESC byte.
            if buf[i] != 0x1b {
                out.push(buf[i]);
                i += 1;
                continue;
            }

            // ESC byte — check if it starts a known strip sequence.
            let remaining = &buf[i..];
            let mut matched = false;

            for seq in STRIP {
                if remaining.len() >= seq.len() {
                    if remaining.starts_with(seq) {
                        // Full match — skip the sequence.
                        i += seq.len();
                        matched = true;
                        break;
                    }
                } else if seq.starts_with(remaining) {
                    // Partial match at end of chunk — save for next call.
                    self.pending.extend_from_slice(remaining);
                    return out;
                }
            }

            if !matched {
                out.push(buf[i]);
                i += 1;
            }
        }

        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_full_sequences() {
        let mut f = AltScreenFilter::new();
        let input = b"hello\x1b[?1049hworld\x1b[?1049lgoodbye";
        let out = f.process(input);
        assert_eq!(out, b"helloworldgoodbye");
    }

    #[test]
    fn strips_across_chunk_boundary() {
        let mut f = AltScreenFilter::new();
        // Split `\x1b[?1049h` across two chunks.
        let out1 = f.process(b"hello\x1b[?10");
        let out2 = f.process(b"49hworld");
        let combined: Vec<u8> = out1.into_iter().chain(out2).collect();
        assert_eq!(combined, b"helloworld");
    }

    #[test]
    fn passes_other_escape_sequences() {
        let mut f = AltScreenFilter::new();
        // `\x1b[2J` (clear screen) should pass through unchanged.
        let input = b"\x1b[2Jhello";
        let out = f.process(input);
        assert_eq!(out, input as &[u8]);
    }
}
