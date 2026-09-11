import AppKit

// Extracted from `ReplView.swift` alongside `ChatTurnView.swift`, so the
// table's constraint count is assertable from the logic test bundle.

// MARK: - MarkdownTableView

/// Native grid renderer for markdown pipe tables.
///
/// ## Holds no Auto Layout constraints, on purpose
///
/// A table's geometry is pure arithmetic and never needed a solver: row heights
/// are constants, columns are equal width, and every cell is a single-line
/// truncating-tail label, so nothing wraps and no height depends on a width.
///
/// It used to be built out of ~23 constraints per row all the same — a chained
/// `row.top == previous.bottom`, and per cell a `leading == previous.trailing`,
/// a `width == labels[0].width` back-reference and a `centerY`. That is the
/// densest, most deeply chained shape `NSISEngine`'s simplex handles, and it is
/// where the 2026-09-09 main-thread freeze actually lived: measured against the
/// real views at a 900 pt pane, a 400-row × 5-col table carried 9 237
/// constraints and one `measure()` call took **three and a half minutes**. 200
/// rows took 15 s, 100 rows 4.9 s. Cost grew as roughly N^2.5–3 in the number
/// of constrained subviews inside one connected graph, and a table is one
/// `TurnBlock`, so all of that was reachable from a single agent message.
///
/// Frame layout makes a table O(1) in the constraint engine no matter how many
/// rows it has, and — unlike the row cap that was the other candidate — hides
/// nothing. See `.claude/wip/replview-measure-superlinear-autolayout/index.md`
/// for the measurements, and `ChatTurnView` for the same argument applied to
/// the blocks *around* the table.
///
/// The rendered result is unchanged: every constant below is the constraint
/// constant it replaced, and `ChatTurnViewLayoutTests` pins the heights.
class MarkdownTableView: NSView {

    // MARK: Geometry — each of these was a constraint constant

    static let headerRowHeight: CGFloat = 30
    static let bodyRowHeight:   CGFloat = 26
    /// Leading inset of the first cell and trailing inset of the last.
    private static let sideInset:  CGFloat = 10
    /// Gap between adjacent cells.
    private static let columnGap:  CGFloat = 12
    private static let separatorHeight: CGFloat = 1

    private let colCount: Int
    /// One entry per row, header first. Empty when there is nothing to draw.
    private let rows: [Row]

    private struct Row {
        let container: NSView
        let cells: [NSTextField]
        let height: CGFloat
    }

    init(headers: [String], rows tableRows: [[String]]) {
        colCount = max(headers.count, tableRows.map { $0.count }.max() ?? 1)

        // A table with no columns has nothing to render. Previously this
        // returned before building any row, leaving the view with no
        // constraints and therefore no height; the empty `rows` below is the
        // same statement, said in the new vocabulary.
        guard colCount > 0 else {
            rows = []
            super.init(frame: .zero)
            return
        }

        let allRows: [[String]] = [headers] + tableRows
        var built: [Row] = []
        built.reserveCapacity(allRows.count)

        for (rowIdx, rowData) in allRows.enumerated() {
            let isHeader = rowIdx == 0
            let isLast   = rowIdx == allRows.count - 1
            let bgAlpha: CGFloat = isHeader ? 0.14 : (rowIdx % 2 == 0 ? 0.09 : 0.105)
            let rowHeight: CGFloat = isHeader ? Self.headerRowHeight : Self.bodyRowHeight

            let rowView = FlippedView()
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = NSColor(white: bgAlpha, alpha: 1).cgColor

            var cells: [NSTextField] = []
            cells.reserveCapacity(colCount)
            for colIdx in 0..<colCount {
                let text  = colIdx < rowData.count ? rowData[colIdx] : ""
                let label = NSTextField(labelWithString: text)
                label.font = isHeader
                    ? .systemFont(ofSize: 11, weight: .semibold)
                    : .systemFont(ofSize: 11)
                label.textColor            = isHeader ? Theme.cornflower : Theme.fg
                label.lineBreakMode        = .byTruncatingTail
                label.maximumNumberOfLines = 1
                rowView.addSubview(label)
                cells.append(label)
            }

            // Row separator — one hairline along the bottom of every row but
            // the last, inside the row, so it costs no height. Positioned in
            // `layoutRow`.
            if !isLast {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.35).cgColor
                rowView.addSubview(sep)
            }

            built.append(Row(container: rowView, cells: cells, height: rowHeight))
        }

        rows = built
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth  = 1
        layer?.borderColor  = Theme.borderInactive.withAlphaComponent(0.5).cgColor
        for row in rows { addSubview(row.container) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    /// Rows stack downward from the top, so the view's own coordinates run the
    /// same way its content does.
    override var isFlipped: Bool { true }

    /// Height is the row heights summed — separators sit *inside* their row and
    /// add none, exactly as the `sep.bottom == row.bottom` constraint they
    /// replace did. Width is whatever the enclosing `TextBlockView` pins it to,
    /// which is why it stays `noIntrinsicMetric`: a table fills its block.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: rows.reduce(0) { $0 + $1.height })
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.01
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        for row in rows {
            let rect = NSRect(x: 0, y: y, width: width, height: row.height)
            if row.container.frame != rect { row.container.frame = rect }
            layoutRow(row)
            y += row.height
        }
    }

    /// Position one row's cells and its separator.
    ///
    /// Cell width solves the chain the constraints used to express: a leading
    /// inset, `colCount` equal-width cells, `colCount - 1` gaps, and a trailing
    /// inset must together span the row.
    private func layoutRow(_ row: Row) {
        let rowWidth = row.container.bounds.width
        let available = rowWidth - Self.sideInset * 2 - Self.columnGap * CGFloat(colCount - 1)
        let cellWidth = max(0, available / CGFloat(colCount))

        let cellHeight = Self.cellTextHeight(header: row.height == Self.headerRowHeight)
        for (colIdx, cell) in row.cells.enumerated() {
            // An **alignment** rect, converted to a frame — not a frame
            // directly. The constraints this replaces addressed each label's
            // alignment rect, and `NSTextField` insets its text two points on
            // each side, so writing these numbers straight into `frame` drew
            // every cell's text two points right of where the solver had put
            // it. `y` is deliberately unrounded for the same reason: it is the
            // `centerY == row.centerY` constraint, and AppKit backing-aligns
            // the result exactly as it did for the solved one.
            let alignmentRect = NSRect(
                x: Self.sideInset + CGFloat(colIdx) * (cellWidth + Self.columnGap),
                y: (row.height - cellHeight) / 2,
                width: cellWidth,
                height: cellHeight)
            // Backing-aligned, because the solver's output was: a cell whose
            // column width is not a whole number of points otherwise lands on
            // a fractional coordinate the constraint-based layout would have
            // snapped.
            let rect = cell.frame(forAlignmentRect:
                backingAlignedRect(alignmentRect, options: .alignAllEdgesNearest))
            if cell.frame != rect { cell.frame = rect }
        }

        // The separator, when this row has one, is the only non-cell subview.
        if row.container.subviews.count > row.cells.count,
           let sep = row.container.subviews.last {
            let rect = NSRect(x: 0, y: row.height - Self.separatorHeight,
                              width: rowWidth, height: Self.separatorHeight)
            if sep.frame != rect { sep.frame = rect }
        }
    }
}

// MARK: - Cell text height

extension MarkdownTableView {

    /// Height of one line of cell text, per font, computed once for the process.
    ///
    /// Every cell in a table is a single line in one of two fonts, so asking
    /// each of a 400-row table's 2 400 labels for its own
    /// `intrinsicContentSize` was 2 400 CoreText round-trips to learn two
    /// numbers — and it happened inside `layout()`, which runs on the
    /// measurement path.
    fileprivate static func cellTextHeight(header: Bool) -> CGFloat {
        if header { return headerTextHeight }
        return bodyTextHeight
    }

    private static let headerTextHeight: CGFloat = probeHeight(
        font: .systemFont(ofSize: 11, weight: .semibold))
    private static let bodyTextHeight: CGFloat = probeHeight(
        font: .systemFont(ofSize: 11))

    private static func probeHeight(font: NSFont) -> CGFloat {
        let probe = NSTextField(labelWithString: "Xg")
        probe.font                 = font
        probe.lineBreakMode        = .byTruncatingTail
        probe.maximumNumberOfLines = 1
        return probe.intrinsicContentSize.height
    }
}

// MARK: - FlippedView

/// A plain container whose origin is top-left, so frame-positioned children
/// read in the same direction as the content they carry.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
