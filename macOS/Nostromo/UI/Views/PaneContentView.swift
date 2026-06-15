import SwiftUI
import NostromoKit

/// SwiftUI renderer for `PaneContentWire` pushed by `set_pane_content`.
///
/// Renders text as a monospaced/markdown-compatible scroll view, and
/// json_snapshot as a generic key-value list — sufficient for the built-in
/// panes (Mother job list, Perri PR queue, Fred inbox, Teri todos) to reach
/// visual parity without duplicating the hand-written NSView implementations.
///
/// `pr_list` renders bucket-grouped `PerriPRRow` components at parity with
/// the legacy `PerriPRList`. Action callbacks are injected by the caller so the
/// view remains dependency-free (no direct store coupling).
///
/// When `content` is nil the pane shows a subtle "waiting for content…" placeholder,
/// which is the normal initial state before an agent's first `set_pane_content` call.
struct PaneContentView: View {
    let content: PaneContentWire?
    /// Called when the user loads a PR from a `pr_list` row. `(repo, number)`
    var onLoadPR:   (String, Int) -> Void = { _, _ in }
    /// Called when the user approves a PR from a `pr_list` row. `(repo, number)`
    var onApprovePR: (String, Int) -> Void = { _, _ in }

    private let bucketOrder: [(label: String, key: String)] = [
        ("REVIEW REQUESTED", "requested"),
        ("NEEDS REVIEW",     "needs_review"),
        ("CHANGES REQUESTED","changes_req"),
        ("DEPENDABOT",       "dependabot"),
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .black)
            switch content {
            case nil:
                placeholder
            case .text(let text):
                textView(text)
            case .jsonSnapshot(let value):
                jsonView(value)
            case .prList(let items):
                prListView(items)
            case .unknown(let raw):
                jsonView(raw)
            }
        }
    }

    // MARK: - pr_list renderer

    @ViewBuilder
    private func prListView(_ items: [PrListItemModel]) -> some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("No PRs in queue")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(bucketOrder, id: \.key) { bucket in
                        let group = items.filter { $0.bucket == bucket.key }
                        if !group.isEmpty {
                            sectionHeader(bucket.label, count: group.count)
                            ForEach(group) { item in
                                NostromoKit.PerriPRRow(
                                    model:  item.toRowModel(),
                                    onLoad: { onLoadPR(item.repo, item.number) },
                                    onClear: {}
                                )
                                .contextMenu {
                                    Button("Approve") { onApprovePR(item.repo, item.number) }
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    // Overflow bucket — items with an unrecognised bucket string
                    let knownBuckets = Set(bucketOrder.map(\.key))
                    let overflow = items.filter { !knownBuckets.contains($0.bucket) }
                    if !overflow.isEmpty {
                        sectionHeader("OTHER", count: overflow.count)
                        ForEach(overflow) { item in
                            NostromoKit.PerriPRRow(
                                model:  item.toRowModel(),
                                onLoad: { onLoadPR(item.repo, item.number) },
                                onClear: {}
                            )
                            .contextMenu {
                                Button("Approve") { onApprovePR(item.repo, item.number) }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack {
            Text("\(label)  \(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
    }

    // MARK: - Sub-renderers

    @ViewBuilder
    private var placeholder: some View {
        VStack {
            Spacer()
            Text("waiting for content…")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(Color(nsColor: .labelColor))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func jsonView(_ value: Any) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(jsonRows(from: value), id: \.key) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .frame(minWidth: 80, alignment: .trailing)
                        Text(row.value)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(nsColor: .labelColor))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    // MARK: - JSON helpers

    private struct JsonRow { let key: String; let value: String }

    private func jsonRows(from value: Any) -> [JsonRow] {
        if let dict = value as? [String: Any] {
            return dict.map { k, v in JsonRow(key: k, value: jsonString(v)) }
                       .sorted { $0.key < $1.key }
        }
        if let arr = value as? [Any] {
            return arr.enumerated().map { i, v in JsonRow(key: "\(i)", value: jsonString(v)) }
        }
        return [JsonRow(key: "value", value: jsonString(value))]
    }

    private func jsonString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let b = value as? Bool   { return b ? "true" : "false" }
        if let i = value as? Int    { return "\(i)" }
        if let d = value as? Double { return "\(d)" }
        if let arr = value as? [Any] {
            return "[\(arr.map { jsonString($0) }.joined(separator: ", "))]"
        }
        if let dict = value as? [String: Any] {
            let pairs = dict.map { "\($0.key): \(jsonString($0.value))" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
        return "\(value)"
    }
}
