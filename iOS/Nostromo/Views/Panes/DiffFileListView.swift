// Nostromo iOS — DiffFileListView.swift
//
// The file-list half of `pr_diff` (ios-curated-view-parity W8, D7): a list
// of facts, not a summary. Per file: the path (truncated from the LEADING
// end so the filename survives), the status as a leading glyph rather than
// a word, and the `+`/`-` counts, right-aligned and monospaced-digit so they
// form a column. A rename shows `oldPath → path`. Nothing here is derived
// or computed client-side — every count is on the wire (`DiffFileModel`).
//
// Takes identical parameters at both widths (D2) — this file never reads
// `WidthClass`; the container (`DiffSurfaceView`) is the only renderer
// permitted to, per memo B9's allowlist.
import SwiftUI
import NostromoKit

struct DiffFileListView: View {
    let files: [DiffFileModel]
    let onSelect: (String) -> Void

    var body: some View {
        if files.isEmpty {
            emptyState
        } else {
            List {
                ForEach(files, id: \.path) { file in
                    Button {
                        onSelect(file.path)
                    } label: {
                        fileRow(file)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 60)
            Text("No files changed")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - One row (D7)

    private func fileRow(_ file: DiffFileModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusGlyph(file.status))
                .foregroundStyle(statusColor(file.status))
                .frame(width: 16)
            Text(file.displayPath)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text("+\(file.additions)")
                    .foregroundStyle(.green)
                Text("-\(file.deletions)")
                    .foregroundStyle(.red)
            }
            .font(.system(size: 12, design: .monospaced).monospacedDigit())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func statusGlyph(_ status: DiffFileModel.Status) -> String {
        switch status {
        case .added:    return "plus.circle.fill"
        case .removed:  return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed:  return "arrow.triangle.branch"
        }
    }

    private func statusColor(_ status: DiffFileModel.Status) -> Color {
        switch status {
        case .added:    return .green
        case .removed:  return .red
        case .modified: return .blue
        case .renamed:  return .purple
        }
    }
}

// MARK: - DiffFileModel.displayPath (shared with DiffFileContentView, D7)
//
// `oldPath → path` for a rename (with a distinct old path), the plain path
// otherwise — the one rule for showing a renamed file's identity, shared
// between this row and `DiffFileContentView`'s open-file header rather than
// each view independently repeating the same rename check.
extension DiffFileModel {
    var displayPath: String {
        if status == .renamed, let old = oldPath, old != path {
            return "\(old) → \(path)"
        }
        return path
    }
}
