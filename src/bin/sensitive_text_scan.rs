//! Reads text on stdin and prints `line_no<TAB>class` for each sensitive-text
//! finding. Never prints any of the text itself, so its output is safe to
//! paste. Used by `scripts/tracker/guard_false_alarm_scan.py`.
//!
//! Line numbers are 1-based. Lines that are not valid UTF-8 are scanned
//! lossily. Exit status is 0 whether or not anything was found.

use std::io::{self, BufRead, Write};

use nostromo::sensitive_text::{scan, GuardConfig};

fn main() -> io::Result<()> {
    let cfg = GuardConfig::default();
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    let mut line_no = 0usize;
    let mut buf = Vec::new();
    let mut input = stdin.lock();
    loop {
        buf.clear();
        if input.read_until(b'\n', &mut buf)? == 0 {
            break;
        }
        line_no += 1;
        let line = String::from_utf8_lossy(&buf);
        for finding in scan(&line, &cfg) {
            writeln!(out, "{line_no}\t{}", finding.class)?;
        }
    }
    out.flush()
}
