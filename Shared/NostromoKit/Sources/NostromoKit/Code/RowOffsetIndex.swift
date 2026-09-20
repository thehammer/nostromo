import Foundation

/// A UTF-16 offset-to-row lookup: which rendered row contains a given
/// character offset (W2 — curated-agent-views; ported into `NostromoKit` in
/// `ios-curated-view-parity` W7).
///
/// macOS's `CodeContentView` (finding the visible row range under scroll) and
/// `LineNumberRulerView` (finding the first row to number in the visible
/// glyph range) each need to answer the exact same question against the exact
/// same offsets, and used to carry two copies of this binary search — a
/// second implementation is exactly how the two would silently drift on an
/// edge case. A plain `Foundation` value type, not an AppKit or SwiftUI one,
/// so this arithmetic is testable with no host, no device, and no simulator.
///
/// A **port**, not a shared move — see `CodeDocument`'s doc comment.
public struct RowOffsetIndex: Equatable {
    /// UTF-16 offset each row starts at, in ascending order.
    private var offsets: [Int]

    public init(_ offsets: [Int] = []) {
        self.offsets = offsets
    }

    /// Build from each row's UTF-16 length, in the "\n"-terminator convention
    /// every rendered row uses: `+1` between rows for the newline that
    /// separates them.
    public init(rowLengths: [Int]) {
        var offsets: [Int] = []
        offsets.reserveCapacity(rowLengths.count)
        var running = 0
        for length in rowLengths {
            offsets.append(running)
            running += length + 1
        }
        self.offsets = offsets
    }

    public var isEmpty: Bool { offsets.isEmpty }
    public var count: Int { offsets.count }

    public subscript(row: Int) -> Int { offsets[row] }

    /// Binary search for the row containing `offset`: the last row whose
    /// start offset is `<= offset`. Returns `0` before any content has been
    /// loaded — there is no row to find yet, and `0` is the harmless default
    /// both callers already relied on.
    public func row(containingOffset offset: Int) -> Int {
        guard !offsets.isEmpty else { return 0 }
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
