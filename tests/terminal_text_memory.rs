//! Memory-bound behaviour tests for `LineAssembler` (review fix-up T3F-4).
//!
//! The report that started this: 180 KB of `ESC[4096Cx\n` (cursor forward, one
//! character, newline) made the old assembler reach about 326 MB, because every
//! row materialised 4096 columns of padding. The assembler must hold a bounded
//! amount of memory for any input: at most `MAX_BUFFERED_ROWS` rows and
//! `MAX_BUFFERED_CELLS` columns between `take_committed` calls, reporting what
//! was dropped as one content-free `[… N lines dropped …]` line.
//!
//! Heap use is measured with a counting global allocator whose counters are
//! per thread (`thread_local!` with const-initialised `Cell`s: no allocation, no
//! destructor, so the allocator cannot recurse). Parallel tests therefore never
//! disturb each other's numbers.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::time::{Duration, Instant};

use nostromo::terminal::follow::{
    LineAssembler, MAX_BUFFERED_CELLS, MAX_BUFFERED_ROWS, MAX_LINE_COLUMNS,
};

// ───────────────────────────── counting allocator ────────────────────────────

struct Counting;

thread_local! {
    static CURRENT: Cell<usize> = const { Cell::new(0) };
    static PEAK: Cell<usize> = const { Cell::new(0) };
}

fn grow(bytes: usize) {
    CURRENT.with(|current| {
        let now = current.get() + bytes;
        current.set(now);
        PEAK.with(|peak| {
            if now > peak.get() {
                peak.set(now);
            }
        });
    });
}

fn shrink(bytes: usize) {
    CURRENT.with(|current| current.set(current.get().saturating_sub(bytes)));
}

// SAFETY: every method forwards to `System` unchanged; the counters are plain
// thread-local integers, so counting neither allocates nor re-enters the
// allocator.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            grow(layout.size());
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc_zeroed(layout);
        if !ptr.is_null() {
            grow(layout.size());
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        shrink(layout.size());
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_ptr = System.realloc(ptr, layout, new_size);
        if !new_ptr.is_null() {
            shrink(layout.size());
            grow(new_size);
        }
        new_ptr
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// Run `f` and report the most heap it held above where it started (this
/// thread only).
fn measure<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = CURRENT.with(Cell::get);
    PEAK.with(|peak| peak.set(base));
    let value = f();
    let peak = PEAK.with(Cell::get);
    (value, peak.saturating_sub(base))
}

const PEAK_LIMIT: usize = 16 * 1024 * 1024;
const MIB: usize = 1024 * 1024;

#[test]
fn the_counting_allocator_sees_a_one_mebibyte_allocation() {
    // Guards the rest of this file against a measurement that reads zero.
    let (_, peak) = measure(|| vec![7u8; MIB]);
    assert!(peak >= MIB, "peak {peak} did not see a 1 MiB vector");
    let (_, peak) = measure(|| {
        let small = "a".repeat(64);
        small.len()
    });
    assert!(peak < MIB, "peak {peak} for a 64 byte vector");
}

// ───────────────────────────── flood harness ─────────────────────────────────

/// `unit` repeated until at least `min_len` bytes.
fn repeated(unit: &[u8], min_len: usize) -> Vec<u8> {
    let copies = min_len.div_ceil(unit.len());
    unit.repeat(copies)
}

fn newlines(input: &[u8]) -> usize {
    input.iter().filter(|&&b| b == b'\n').count()
}

/// `N` of a `[… N lines dropped …]` line.
fn dropped_count(line: &str) -> Option<usize> {
    line.strip_prefix("[\u{2026} ")?
        .strip_suffix(" lines dropped \u{2026}]")?
        .parse()
        .ok()
}

#[derive(Debug, Default)]
struct Report {
    /// Lines returned that are not drop markers.
    returned: usize,
    /// Sum of `N` over the drop markers.
    dropped: usize,
    markers: usize,
    /// Whether a marker was anywhere but the first line of a take.
    misplaced_marker: bool,
    max_rows: usize,
    max_cells: usize,
    rows_at_end: usize,
    partial_at_end: Option<String>,
    peak: usize,
}

fn absorb(assembler: &mut LineAssembler, report: &mut Report) {
    for (i, line) in assembler.take_committed().into_iter().enumerate() {
        match dropped_count(&line) {
            Some(n) => {
                report.markers += 1;
                report.dropped += n;
                report.misplaced_marker |= i != 0;
            }
            None => report.returned += 1,
        }
    }
}

fn note_bounds(assembler: &LineAssembler, report: &mut Report) {
    report.max_rows = report.max_rows.max(assembler.buffered_rows());
    report.max_cells = report.max_cells.max(assembler.buffered_cells());
}

/// Feed `input` in `chunk`-byte pieces, noting the buffer sizes after every
/// piece, taking the committed lines after every piece or only at the end.
fn run_flood(input: &[u8], chunk: usize, take_each_chunk: bool) -> Report {
    let (mut report, peak) = measure(|| {
        let mut assembler = LineAssembler::new();
        let mut report = Report::default();
        for piece in input.chunks(chunk) {
            assembler.feed(piece);
            note_bounds(&assembler, &mut report);
            if take_each_chunk {
                absorb(&mut assembler, &mut report);
            }
        }
        absorb(&mut assembler, &mut report);
        report.rows_at_end = assembler.buffered_rows();
        report.partial_at_end = assembler.current_partial().map(str::to_owned);
        report
    });
    report.peak = peak;
    report
}

fn assert_bounded(name: &str, report: &Report) {
    assert!(
        report.peak < PEAK_LIMIT,
        "{name}: peak extra heap {} bytes, limit {PEAK_LIMIT}",
        report.peak
    );
    assert!(
        report.max_rows <= MAX_BUFFERED_ROWS,
        "{name}: {} rows buffered, limit {MAX_BUFFERED_ROWS}",
        report.max_rows
    );
    assert!(
        report.max_cells <= MAX_BUFFERED_CELLS,
        "{name}: {} cells buffered, limit {MAX_BUFFERED_CELLS}",
        report.max_cells
    );
    assert!(!report.misplaced_marker, "{name}: drop marker not first");
}

/// Every row fed ended in `\n`, so each is committed: the rows returned plus
/// the rows reported dropped must be exactly the newlines fed. (The empty live
/// row after the last newline is never returned.)
fn assert_row_accounting(name: &str, input: &[u8], report: &Report) {
    assert_eq!(
        report.returned + report.dropped,
        newlines(input),
        "{name}: {} returned + {} dropped != {} rows fed",
        report.returned,
        report.dropped,
        newlines(input)
    );
}

// ───────────────────────────── cursor-forward floods ─────────────────────────

const CURSOR_FORWARD_ROW: &[u8] = b"\x1b[4096Cx\n";

#[test]
fn a_one_mebibyte_cursor_forward_flood_stays_bounded_and_accounts_for_every_row() {
    let input = repeated(CURSOR_FORWARD_ROW, MIB);
    for (chunk, take_each) in [(4096, false), (4096, true), (65_536, false), (7, false)] {
        let report = run_flood(&input, chunk, take_each);
        let name = format!("1 MiB cursor-forward, chunk {chunk}, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
        assert!(report.dropped > 0, "{name}: nothing was dropped");
        assert!(report.markers >= 1, "{name}: no drop marker");
        if !take_each {
            assert_eq!(report.markers, 1, "{name}: one take, one marker");
        }
    }
}

#[test]
fn the_original_180kb_cursor_forward_report_no_longer_costs_hundreds_of_megabytes() {
    let input = repeated(CURSOR_FORWARD_ROW, 180_000);
    for take_each in [false, true] {
        let report = run_flood(&input, 4096, take_each);
        let name = format!("180 KB cursor-forward, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
        assert!(report.dropped > 0, "{name}: nothing was dropped");
    }
}

#[test]
fn the_buffer_caps_hold_after_every_single_byte_of_the_180kb_flood() {
    let input = repeated(CURSOR_FORWARD_ROW, 180_000);
    let ((max_rows, max_cells, returned, dropped), peak) = measure(|| {
        let mut assembler = LineAssembler::new();
        let mut report = Report::default();
        let (mut max_rows, mut max_cells) = (0, 0);
        for (i, byte) in input.iter().enumerate() {
            assembler.feed(std::slice::from_ref(byte));
            max_rows = max_rows.max(assembler.buffered_rows());
            max_cells = max_cells.max(assembler.buffered_cells());
            if i % 5000 == 0 {
                absorb(&mut assembler, &mut report);
            }
        }
        absorb(&mut assembler, &mut report);
        (max_rows, max_cells, report.returned, report.dropped)
    });
    assert!(peak < PEAK_LIMIT, "peak {peak}");
    assert!(max_rows <= MAX_BUFFERED_ROWS, "{max_rows} rows");
    assert!(max_cells <= MAX_BUFFERED_CELLS, "{max_cells} cells");
    assert_eq!(returned + dropped, newlines(&input));
}

#[test]
fn a_drop_marker_is_reported_once_and_content_free() {
    let input = repeated(CURSOR_FORWARD_ROW, 180_000);
    let mut assembler = LineAssembler::new();
    assembler.feed(&input);
    let first = assembler.take_committed();
    let marker = &first[0];
    let n = dropped_count(marker).unwrap_or_else(|| {
        let head: String = marker.chars().take(40).collect();
        panic!("first line is not a drop marker: {head:?}")
    });
    assert!(n > 0);
    assert!(marker.len() < 64, "marker carries content: {marker:?}");
    assert_eq!(first.len() - 1 + n, newlines(&input));
    assert!(
        first[1..].iter().all(|l| dropped_count(l).is_none()),
        "more than one marker"
    );
    // The loss is reported once.
    assert!(assembler.take_committed().is_empty());
}

#[test]
fn a_flood_that_never_reaches_the_caps_reports_nothing_dropped() {
    let input = repeated(CURSOR_FORWARD_ROW, 9 * 50);
    let report = run_flood(&input, 4096, false);
    assert_eq!(report.markers, 0);
    assert_eq!(report.returned, 50);
}

// ───────────────────────────── other floods ──────────────────────────────────

#[test]
fn a_plain_row_flood_is_capped_by_the_row_limit() {
    let input = repeated(b"x\n", MIB);
    for take_each in [false, true] {
        let report = run_flood(&input, 4096, take_each);
        let name = format!("1 MiB of x rows, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
        if !take_each {
            assert!(report.max_rows > 1000, "{name}: rows never accumulated");
            assert!(report.dropped > 0, "{name}: nothing dropped");
        }
    }
}

#[test]
fn a_flood_of_mid_line_gaps_keeps_one_clipped_row() {
    // `a`, a 4000 column gap, `b`, over and over, never a newline: one live row.
    let input = repeated(b"a\x1b[4000Cb", MIB);
    let report = run_flood(&input, 4096, false);
    assert_bounded("mid-line gaps", &report);
    assert_eq!(report.rows_at_end, 1);
    assert_eq!(report.returned + report.dropped, 0);
    let row = report.partial_at_end.expect("the row has text");
    assert_eq!(row.chars().count(), MAX_LINE_COLUMNS);
    assert!(row.ends_with('\u{2026}'));
}

#[test]
fn mid_line_gaps_with_newlines_are_bounded_and_accounted() {
    let input = repeated(b"a\x1b[4000Cb\n", MIB);
    for take_each in [false, true] {
        let report = run_flood(&input, 4096, take_each);
        let name = format!("mid-line gaps with newlines, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
    }
}

#[test]
fn a_flood_of_cursor_forward_with_no_text_costs_nothing() {
    let input = repeated(b"\x1b[4096C", MIB);
    let report = run_flood(&input, 4096, false);
    assert_bounded("bare cursor-forward", &report);
    assert_eq!(report.rows_at_end, 1);
    assert_eq!(report.returned + report.dropped, 0);
    assert_eq!(report.partial_at_end, None);
}

#[test]
fn a_flood_of_empty_rows_with_cursor_forward_is_bounded() {
    let input = repeated(b"\x1b[4096C\n", MIB);
    for take_each in [false, true] {
        let report = run_flood(&input, 4096, take_each);
        let name = format!("empty rows with cursor-forward, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
    }
}

#[test]
fn a_flood_of_delete_characters_is_bounded() {
    let units: [&[u8]; 3] = [
        b"abc\x1b[4096D\x1b[4096P\n",
        b"\x1b[4096Cx\x1b[4096D\x1b[4096P\n",
        b"abc\x1b[99999999999999999999P\n",
    ];
    for unit in units {
        let input = repeated(unit, MIB);
        for take_each in [false, true] {
            let report = run_flood(&input, 4096, take_each);
            let name = format!("P flood {unit:?}, take each {take_each}");
            assert_bounded(&name, &report);
            assert_row_accounting(&name, &input, &report);
        }
    }
}

#[test]
fn a_flood_of_erase_in_line_with_gaps_is_bounded() {
    let units: [&[u8]; 3] = [
        b"\x1b[4096Cx\x1b[1K\x1b[K\x1b[2K\n",
        b"ab\x1b[4096Cc\x1b[4000D\x1b[K\n",
        b"ab\x1b[4096Cc\x1b[4000D\x1b[1K\n",
    ];
    for unit in units {
        let input = repeated(unit, MIB);
        for take_each in [false, true] {
            let report = run_flood(&input, 4096, take_each);
            let name = format!("K flood {unit:?}, take each {take_each}");
            assert_bounded(&name, &report);
            assert_row_accounting(&name, &input, &report);
        }
    }
}

#[test]
fn absurd_numeric_parameters_do_not_panic_or_blow_up() {
    // Parameters beyond usize, and the largest usize, on every movement.
    let unit: &[u8] =
        b"\x1b[18446744073709551616Cx\x1b[18446744073709551615D\x1b[18446744073709551615P\
\x1b[18446744073709551616G\x1b[99999999999999999999K\x1b[0Cy\n";
    let input = repeated(unit, MIB);
    for take_each in [false, true] {
        let report = run_flood(&input, 4096, take_each);
        let name = format!("absurd parameters, take each {take_each}");
        assert_bounded(&name, &report);
        assert_row_accounting(&name, &input, &report);
    }
}

// ───────────────────────────── random control soup ───────────────────────────

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn step(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.step() % n as u64) as usize
    }
}

/// Random mixes of text, newlines, `\r`, backspace, tab and CSI movements with
/// small, huge and absent parameters. `with_vertical` adds cursor up and down.
fn control_soup(seed: u64, min_len: usize, with_vertical: bool) -> Vec<u8> {
    const PARAMS: &[&str] = &[
        "",
        "0",
        "1",
        "7",
        "4096",
        "65535",
        "65536",
        "99999999999999999999",
    ];
    let mut finals = vec!['C', 'D', 'P', 'K', 'G'];
    if with_vertical {
        finals.extend(['A', 'B']);
    }
    let mut rng = Rng::new(seed);
    let mut out = Vec::new();
    while out.len() < min_len {
        match rng.below(8) {
            0 | 1 => out.extend_from_slice(b"x"),
            2 => out.extend_from_slice(b"\n"),
            3 => out.extend_from_slice(["\r", "\x08", "\t", "ab"][rng.below(4)].as_bytes()),
            _ => {
                let param = PARAMS[rng.below(PARAMS.len())];
                let last = finals[rng.below(finals.len())];
                out.extend_from_slice(format!("\x1b[{param}{last}").as_bytes());
            }
        }
    }
    out
}

#[test]
fn random_control_soup_never_exceeds_the_caps() {
    for seed in 0..12u64 {
        let input = control_soup(seed, MIB, seed % 2 == 0);
        for (chunk, take_each) in [(4096, false), (4096, true), (1500, false)] {
            let report = run_flood(&input, chunk, take_each);
            assert_bounded(
                &format!("soup seed {seed}, chunk {chunk}, take each {take_each}"),
                &report,
            );
        }
    }
}

#[test]
fn chunking_never_changes_what_the_assembler_produces() {
    // Guards cell storage and gap handling against refactors: the same bytes
    // must give the same lines however the stream is cut, and however often the
    // committed lines are taken. No cursor-up or down here (that would let a
    // take change what can still be rewritten), and small enough that no cap
    // bites.
    for seed in 0..60u64 {
        let input = control_soup(seed, 3000, false);
        let whole = {
            let mut a = LineAssembler::new();
            a.feed(&input);
            (a.take_committed(), a.current_partial().map(str::to_owned))
        };
        let mut rng = Rng::new(seed + 1000);
        let mut a = LineAssembler::new();
        let mut rest = &input[..];
        let mut lines = Vec::new();
        while !rest.is_empty() {
            let n = (1 + rng.below(300)).min(rest.len());
            a.feed(&rest[..n]);
            rest = &rest[n..];
            if rng.below(4) == 0 {
                lines.extend(a.take_committed());
            }
        }
        lines.extend(a.take_committed());
        let chunked = (lines, a.current_partial().map(str::to_owned));
        assert_eq!(whole, chunked, "seed {seed}");
    }
}

// ───────────────────────────── behaviour that must survive ───────────────────

fn assemble(input: &[u8]) -> Vec<String> {
    let mut a = LineAssembler::new();
    a.feed(input);
    a.take_committed()
}

#[test]
fn cursor_forward_then_a_character_gives_a_4096_column_line_ending_in_an_ellipsis() {
    let lines = assemble(b"\x1b[4096Cx\n");
    assert_eq!(lines.len(), 1);
    let line = &lines[0];
    assert_eq!(line.chars().count(), MAX_LINE_COLUMNS);
    assert!(line.ends_with('\u{2026}'), "{:?}", &line[line.len() - 8..]);
    assert!(line.chars().take(4095).all(|c| c == ' '));
}

#[test]
fn cursor_forward_padding_inside_a_short_line_is_still_spaces() {
    assert_eq!(assemble(b"ab\x1b[3Cc\n"), ["ab   c"]);
    assert_eq!(assemble(b"\x1b[2Cx\n"), ["  x"]);
    // Padding with nothing after it leaves no trailing spaces.
    assert_eq!(assemble(b"ab\x1b[3C\n"), ["ab"]);
    // A gap of exactly the cap minus one, then a character, is not clipped.
    let line = &assemble(b"\x1b[4095Cx\n")[0];
    assert_eq!(line.chars().count(), MAX_LINE_COLUMNS);
    assert!(line.ends_with('x'));
}

#[test]
fn delete_characters_still_shifts_text_left_with_and_without_gaps() {
    assert_eq!(assemble(b"abcdef\r\x1b[2C\x1b[2P\n"), ["abef"]);
    // Delete more than is left: everything from the cursor on goes.
    assert_eq!(assemble(b"abcdef\r\x1b[2C\x1b[99P\n"), ["ab"]);
    // Delete past the end of the text: nothing to delete.
    assert_eq!(assemble(b"abc\x1b[5C\x1b[2P\n"), ["abc"]);
    // `a b` with a gap: cells a@0, b@5; delete 2 at column 1 (spaces only)
    // pulls b left by two.
    assert_eq!(assemble(b"a\x1b[4Cb\r\x1b[1C\x1b[2P\n"), ["a  b"]);
    // Delete through a gap into text: `ab___c`, delete 3 at column 1 removes
    // `b` and two spaces, leaving `a c`.
    assert_eq!(assemble(b"ab\x1b[3Cc\r\x1b[1C\x1b[3P\n"), ["a c"]);
}

#[test]
fn erase_in_line_modes_still_work_with_gaps() {
    // Text `ab___c`, cursor moved back to column 3.
    assert_eq!(assemble(b"ab\x1b[3Cc\x1b[3D\x1b[K\n"), ["ab"]);
    assert_eq!(assemble(b"ab\x1b[3Cc\x1b[3D\x1b[0K\n"), ["ab"]);
    assert_eq!(assemble(b"ab\x1b[3Cc\x1b[3D\x1b[1K\n"), ["     c"]);
    assert_eq!(assemble(b"ab\x1b[3Cc\x1b[2K\n"), [""]);
    // Writing after an erase lands at the cursor, with the gap kept.
    assert_eq!(assemble(b"ab\x1b[3Cc\x1b[3D\x1b[Kz\n"), ["ab z"]);
}

#[test]
fn a_4096_column_row_fed_byte_by_byte_stays_cheap() {
    let mut assembler = LineAssembler::new();
    let start = Instant::now();
    for _ in 0..MAX_LINE_COLUMNS - 1 {
        assembler.feed(b"a");
        // A driver polls the cursor line as bytes arrive.
        assert!(assembler.current_partial().is_some());
    }
    for byte in b"\x1b[4096Cx" {
        assembler.feed(std::slice::from_ref(byte));
        let _ = assembler.current_partial();
    }
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_secs(10),
        "byte-by-byte feeding of one wide row took {elapsed:?}"
    );
    assembler.feed(b"\n");
    let lines = assembler.take_committed();
    assert_eq!(lines[0].chars().count(), MAX_LINE_COLUMNS);
    assert!(lines[0].ends_with('\u{2026}'));
}

#[test]
fn wide_characters_count_as_one_column() {
    // Documented gap: a terminal shows each of these in two columns, the
    // assembler counts one, so the redraw over them lands one column off.
    assert_eq!(assemble("\u{4f60}\u{597d}\rx\n".as_bytes()), ["x\u{597d}"]);
}
