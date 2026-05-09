//! Acceptance test: scrollback ring buffer is bounded at ≤ 2 MiB and ≤ 10 000 newlines.

use nostromo::ipc::scrollback::{ScrollbackBuf, MAX_BYTES, MAX_NEWLINES};

#[test]
fn push_20k_lines_bytes_bounded() {
    let mut buf = ScrollbackBuf::new();

    // Each chunk: "x\n" repeated 20 times = 40 bytes, 20 newlines.
    // We push 1 100 chunks → 1 100 × 20 = 22 000 lines total attempted.
    let chunk = b"x\n".repeat(20);
    for _ in 0..1_100 {
        buf.push(chunk.clone());
    }

    assert!(
        buf.byte_len() <= MAX_BYTES,
        "byte_len {} exceeds MAX_BYTES {}",
        buf.byte_len(),
        MAX_BYTES
    );
    assert!(
        buf.newline_count() <= MAX_NEWLINES,
        "newline_count {} exceeds MAX_NEWLINES {}",
        buf.newline_count(),
        MAX_NEWLINES
    );
}

#[test]
fn push_large_binary_chunks_bytes_bounded() {
    let mut buf = ScrollbackBuf::new();

    // Push 4 KiB chunks with no newlines until well over 2 MiB.
    let chunk = vec![b'A'; 4096];
    let iterations = (MAX_BYTES / 4096) + 200;
    for _ in 0..iterations {
        buf.push(chunk.clone());
    }

    assert!(
        buf.byte_len() <= MAX_BYTES,
        "byte_len {} exceeds MAX_BYTES {}",
        buf.byte_len(),
        MAX_BYTES
    );
}

#[test]
fn drain_returns_correct_contents() {
    let mut buf = ScrollbackBuf::new();
    buf.push(b"hello ".to_vec());
    buf.push(b"world".to_vec());
    let out = buf.drain();
    assert_eq!(out, b"hello world");
}
