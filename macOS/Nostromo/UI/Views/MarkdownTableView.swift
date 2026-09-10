import AppKit

// Extracted from `ReplView.swift` alongside `ChatTurnView.swift`, so the
// table's constraint count is assertable from the logic test bundle.

// MARK: - MarkdownTableView

/// Native grid renderer for markdown pipe tables.
///
/// Rows are pinned with explicit leading/trailing constraints (not NSStackView alignment)
/// so column widths are computed correctly from the table's actual width.
class MarkdownTableView: NSView {

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth  = 1
        layer?.borderColor  = Theme.borderInactive.withAlphaComponent(0.5).cgColor

        let colCount = max(headers.count, rows.map { $0.count }.max() ?? 1)
        guard colCount > 0 else { return }

        let allRows: [[String]] = [headers] + rows
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for (rowIdx, rowData) in allRows.enumerated() {
            let isHeader   = rowIdx == 0
            let isLast     = rowIdx == allRows.count - 1
            let bgAlpha: CGFloat = isHeader ? 0.14 : (rowIdx % 2 == 0 ? 0.09 : 0.105)
            let rowHeight: CGFloat = isHeader ? 30 : 26

            let rowView = NSView()
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = NSColor(white: bgAlpha, alpha: 1).cgColor
            rowView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rowView)

            // Pin row to full table width — this is what determines column widths
            NSLayoutConstraint.activate([
                rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
                rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
                rowView.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor),
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            prevAnchor = rowView.bottomAnchor

            // Build equal-width columns
            var labels: [NSTextField] = []
            for colIdx in 0..<colCount {
                let text  = colIdx < rowData.count ? rowData[colIdx] : ""
                let label = NSTextField(labelWithString: text)
                label.font                 = isHeader
                    ? .systemFont(ofSize: 11, weight: .semibold)
                    : .systemFont(ofSize: 11)
                label.textColor            = isHeader ? Theme.cornflower : Theme.fg
                label.lineBreakMode        = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rowView.addSubview(label)
                labels.append(label)
            }

            for (colIdx, label) in labels.enumerated() {
                label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor).isActive = true
                if colIdx == 0 {
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10).isActive = true
                } else {
                    label.leadingAnchor.constraint(equalTo: labels[colIdx - 1].trailingAnchor, constant: 12).isActive = true
                    label.widthAnchor.constraint(equalTo: labels[0].widthAnchor).isActive = true
                }
                if colIdx == colCount - 1 {
                    label.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10).isActive = true
                }
            }

            // Row separator
            if !isLast {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.35).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        }

        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
